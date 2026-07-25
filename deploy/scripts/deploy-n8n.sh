#!/usr/bin/env bash
set -Eeuo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${N8N_IMAGE:?N8N_IMAGE is required}"
: "${N8N_IMAGE_PREVIOUS:=}"
: "${MIN_FREE_DISK_MB:=2500}"
: "${PRUNE_UNUSED_VOLUMES:=false}"

PROJECT_NAME="linkedin-job-application-automation"
HOSTNAME="n8n.ai-automation-platform.com"
CONTAINER_NAME="${PROJECT_NAME}-n8n"
NEXT_CONTAINER_NAME="${CONTAINER_NAME}-next"
PORT_MAPPING="127.0.0.1:5678:5678"
CANDIDATE_PORT_MAPPING="127.0.0.1:5679:5678"
DATA_VOLUME="${PROJECT_NAME}-n8n-data"
FILES_VOLUME="${PROJECT_NAME}-n8n-files"
SSM_PARAMETER_PATH="/${PROJECT_NAME}/env"
CERT_PARAMETER="/${PROJECT_NAME}/nginx/origin_certificate"
KEY_PARAMETER="/${PROJECT_NAME}/nginx/origin_private_key"
DEPLOY_DIR="/home/ubuntu/${PROJECT_NAME}-deploy"
SSL_DIR="/etc/nginx/ssl/${HOSTNAME}"
CERT_PATH="${SSL_DIR}/origin_certificate.pem"
KEY_PATH="${SSL_DIR}/origin_private_key.pem"
NGINX_SITE_NAME="${PROJECT_NAME}"
SITE_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
SITE_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
HEALTH_PATH="/health"
DEPLOY_LOCK_FILE="/tmp/${PROJECT_NAME}-deploy.lock"

N8N_IMAGE_REPOSITORY="${N8N_IMAGE%%@*}"
N8N_IMAGE_REPOSITORY="${N8N_IMAGE_REPOSITORY%%:*}"

if ! [[ "$MIN_FREE_DISK_MB" =~ ^[0-9]+$ ]]; then
  echo "MIN_FREE_DISK_MB must be a positive integer number of megabytes" >&2
  exit 1
fi

require_cmd() {
  local cmd="$1"
  local package="${2:-$1}"
  if command -v "$cmd" >/dev/null 2>&1; then
    return
  fi
  sudo apt-get update
  sudo apt-get install -y "$package"
}

# Ubuntu dropped the apt "awscli" package's v1 build for 22.04+/24.04, so
# `apt-get install awscli` has no installation candidate there. Install the
# official AWS CLI v2 bundle from Amazon instead: it is architecture-aware,
# self-contained (no system Python dependency), and is the vendor-supported
# path for Ubuntu 22.04/24.04 on both amd64 and arm64.
install_aws_cli() {
  if command -v aws >/dev/null 2>&1; then
    return 0
  fi

  local arch
  case "$(uname -m)" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *)
      echo "Unsupported architecture for AWS CLI installation: $(uname -m)" >&2
      return 1
      ;;
  esac

  require_cmd curl
  require_cmd unzip

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  curl --fail --silent --show-error --location \
    "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" \
    -o "${tmp_dir}/awscliv2.zip"
  unzip -q "${tmp_dir}/awscliv2.zip" -d "$tmp_dir"
  sudo "${tmp_dir}/aws/install" --update

  rm -rf "$tmp_dir"
  trap - RETURN

  aws --version
}

ensure_runtime() {
  install_aws_cli
  require_cmd curl
  require_cmd jq
  require_cmd nginx
  if ! command -v docker >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io
  fi
  sudo systemctl enable --now docker
}

install_secret_file() {
  local parameter_name="$1"
  local destination="$2"
  local mode="$3"
  local marker_regex="$4"
  local tmp_file
  local tmp_destination

  tmp_file="$(mktemp)"
  tmp_destination="${destination}.tmp"
  trap 'rm -f "$tmp_file"; sudo rm -f "$tmp_destination"' RETURN
  set +x
  aws ssm get-parameter \
    --name "$parameter_name" \
    --with-decryption \
    --region "$AWS_REGION" \
    --query 'Parameter.Value' \
    --output text > "$tmp_file"

  if [ ! -s "$tmp_file" ]; then
    echo "SSM parameter ${parameter_name} returned an empty value" >&2
    return 1
  fi
  if ! head -n 1 "$tmp_file" | grep -Eq "$marker_regex"; then
    echo "SSM parameter ${parameter_name} does not look like the expected PEM type" >&2
    return 1
  fi

  sudo install -d -m 700 -o root -g root "$(dirname "$destination")"
  sudo install -o root -g root -m "$mode" "$tmp_file" "$tmp_destination"
  sudo mv "$tmp_destination" "$destination"
  rm -f "$tmp_file"
  trap - RETURN
}

install_nginx_config() {
  : "${NGINX_CONF_BASE64:?NGINX_CONF_BASE64 is required}"

  echo "$NGINX_CONF_BASE64" | base64 -d > "${DEPLOY_DIR}/${NGINX_SITE_NAME}.conf"
  sudo install -d -m 755 -o root -g root /etc/nginx/sites-available /etc/nginx/sites-enabled
  sudo install -o root -g root -m 0644 "${DEPLOY_DIR}/${NGINX_SITE_NAME}.conf" "$SITE_AVAILABLE"
  sudo ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t
}

generate_env_file() {
  local params_json
  params_json="$(mktemp)"
  trap 'rm -f "$params_json"' RETURN

  aws ssm get-parameters-by-path \
    --path "$SSM_PARAMETER_PATH" \
    --with-decryption \
    --region "$AWS_REGION" \
    --recursive \
    --output json > "$params_json"

  jq -r --arg path "${SSM_PARAMETER_PATH}/" '
    .Parameters[]
    | select(.Name | startswith($path))
    | if (.Name | contains("/nginx/")) then error("Refusing nginx parameter in env path: " + .Name) else . end
    | if (.Value | test("[\r\n]")) then error("Refusing multiline SSM parameter in .env: " + .Name) else . end
    | ((.Name | split("/") | last) + "=" + .Value)
  ' "$params_json" > .env

  chmod 0600 .env
  rm -f "$params_json"
  trap - RETURN

  if grep -Eq 'origin_certificate|origin_private_key|BEGIN CERTIFICATE|BEGIN PRIVATE KEY|BEGIN RSA PRIVATE KEY|BEGIN EC PRIVATE KEY' .env; then
    echo "Refusing to deploy because TLS material was written to .env" >&2
    exit 1
  fi
}

wait_for() {
  local description="$1"
  local command="$2"
  local log_container="${3:-$CONTAINER_NAME}"

  for attempt in $(seq 1 30); do
    echo "${description} check attempt ${attempt}..."
    if bash -c "$command"; then
      echo "${description} is healthy"
      return 0
    fi
    docker logs --tail=50 "$log_container" || true
    sleep 3
  done

  echo "${description} check failed" >&2
  return 1
}

print_disk_diagnostics() {
  echo "--- disk usage ---"
  df -h || true
  df -i || true
  docker system df || true
  docker ps --all --no-trunc || true
  docker image ls --digests || true
  docker volume ls || true
  docker network ls || true
  sudo du -sh /var/lib/docker 2>/dev/null || true
  sudo du -sh /var/lib/containerd 2>/dev/null || true
}

get_runtime_root() {
  docker info --format '{{.DockerRootDir}}'
}

get_available_mb() {
  local path="$1"
  df -Pm "$path" | awk 'NR == 2 {print $4}'
}

image_id_for_ref() {
  local image_ref="$1"
  if [ -z "$image_ref" ]; then
    return 0
  fi
  docker image inspect "$image_ref" --format '{{.Id}}' 2>/dev/null || true
}

container_image_id() {
  local container="$1"
  docker inspect "$container" --format '{{.Image}}' 2>/dev/null || true
}

running_container_image_ids() {
  docker ps --format '{{.ID}}' |
    while IFS= read -r container_id; do
      [ -n "$container_id" ] || continue
      docker inspect "$container_id" --format '{{.Image}}' 2>/dev/null || true
    done |
    sort -u
}

retain_image_id() {
  local image_id="$1"
  local reason="$2"
  [ -n "$image_id" ] || return 0
  case " ${PROTECTED_IMAGE_IDS[*]} " in
    *" ${image_id} "*) ;;
    *) PROTECTED_IMAGE_IDS+=("$image_id") ;;
  esac
  echo "Retaining image ${image_id} (${reason})"
}

collect_protected_image_ids() {
  PROTECTED_IMAGE_IDS=()

  retain_image_id "$(container_image_id "$CONTAINER_NAME")" "current production container"
  retain_image_id "$(container_image_id "$NEXT_CONTAINER_NAME")" "candidate container"
  retain_image_id "$(image_id_for_ref "$N8N_IMAGE")" "new deployment image"
  retain_image_id "$(image_id_for_ref "$N8N_IMAGE_PREVIOUS")" "configured rollback image"
  retain_image_id "$(image_id_for_ref "$(cat previous_image.txt 2>/dev/null || true)")" "recorded previous image"

  while IFS= read -r image_id; do
    retain_image_id "$image_id" "running container"
  done < <(running_container_image_ids)
}

image_id_is_protected() {
  local image_id="$1"
  case " ${PROTECTED_IMAGE_IDS[*]} " in
    *" ${image_id} "*) return 0 ;;
    *) return 1 ;;
  esac
}

image_id_is_used_by_any_container() {
  local image_id="$1"
  docker ps --all --filter "ancestor=${image_id}" --format '{{.ID}}' | grep -q .
}

cleanup_stopped_containers() {
  echo "--- pruning stopped containers ---"
  docker container prune --force
}

cleanup_dangling_images() {
  echo "--- pruning dangling images ---"
  docker image prune --force
}

cleanup_build_cache() {
  echo "--- pruning Docker builder cache ---"
  docker builder prune --force
  if docker buildx version >/dev/null 2>&1; then
    docker buildx prune --force
  else
    echo "Buildx is unavailable; continuing."
  fi
}

cleanup_unused_networks() {
  echo "--- pruning unused networks ---"
  docker network prune --force
}

cleanup_old_n8n_images() {
  echo "--- cleaning old n8n images for repository ${N8N_IMAGE_REPOSITORY} ---"
  collect_protected_image_ids

  local image_ids
  image_ids="$(docker image ls "$N8N_IMAGE_REPOSITORY" --format '{{.ID}}' | sort -u)"
  if [ -z "$image_ids" ]; then
    echo "No local n8n images found for ${N8N_IMAGE_REPOSITORY}."
    return 0
  fi

  while IFS= read -r image_id; do
    [ -n "$image_id" ] || continue
    if image_id_is_protected "$image_id"; then
      echo "Keeping n8n image ${image_id}: protected."
      continue
    fi
    if image_id_is_used_by_any_container "$image_id"; then
      echo "Keeping n8n image ${image_id}: still used by a container."
      continue
    fi
    echo "Removing old n8n image ${image_id}."
    docker image rm "$image_id" || echo "Image ${image_id} was already removed or is still referenced; continuing."
  done <<< "$image_ids"
}

list_unused_volume_candidates() {
  echo "--- unused volume candidates (diagnostic only by default) ---"
  echo "Protected production volumes: ${DATA_VOLUME}, ${FILES_VOLUME}"
  docker volume ls --format '{{.Name}}' |
    while IFS= read -r volume_name; do
      [ -n "$volume_name" ] || continue
      case "$volume_name" in
        "$DATA_VOLUME"|"$FILES_VOLUME"|*n8n*data*|*postgres*|*db*)
          echo "Keeping volume ${volume_name}: protected by name/purpose."
          continue
          ;;
      esac
      if docker ps --all --filter "volume=${volume_name}" --format '{{.ID}}' | grep -q .; then
        echo "Keeping volume ${volume_name}: referenced by a container."
        continue
      fi
      echo "Unused volume candidate: ${volume_name}"
    done
}

cleanup_proven_obsolete_volumes() {
  list_unused_volume_candidates

  if [ "$PRUNE_UNUSED_VOLUMES" != "true" ]; then
    echo "PRUNE_UNUSED_VOLUMES is not true; no volumes will be removed."
    return 0
  fi

  echo "PRUNE_UNUSED_VOLUMES=true, but this repository has no exact obsolete production volume naming convention to prune safely."
  echo "Leaving volumes untouched."
}

assert_minimum_free_space() {
  local runtime_root
  local available_mb
  local minimum_available_mb
  runtime_root="$(get_runtime_root)"
  available_mb="$(get_available_mb "$runtime_root")"
  minimum_available_mb="$available_mb"

  echo "Docker runtime root: ${runtime_root}"
  echo "Available space on Docker filesystem: ${available_mb} MB"
  if [ -d /var/lib/containerd ]; then
    available_mb="$(get_available_mb /var/lib/containerd)"
    echo "Available space on containerd filesystem: ${available_mb} MB"
    if (( available_mb < minimum_available_mb )); then
      minimum_available_mb="$available_mb"
    fi
  fi

  if (( minimum_available_mb < MIN_FREE_DISK_MB )); then
    echo "ERROR: Only ${minimum_available_mb} MB is available on the Docker/containerd filesystem after cleanup." >&2
    echo "At least ${MIN_FREE_DISK_MB} MB is required before pulling the new n8n image." >&2
    echo "Increase the EBS volume or remove additional unused resources." >&2
    exit 1
  fi
}

cleanup_docker_resources() {
  print_disk_diagnostics
  collect_protected_image_ids
  cleanup_stopped_containers
  cleanup_dangling_images
  cleanup_build_cache
  cleanup_unused_networks
  cleanup_old_n8n_images
  cleanup_proven_obsolete_volumes
}

cleanup_after_failed_pull() {
  echo "Image pull failed; cleaning dangling Docker resources left by the failed pull."
  cleanup_dangling_images || true
  cleanup_build_cache || true
  print_disk_diagnostics
}

run_n8n_container() {
  local name="$1"
  local image="$2"
  local port_mapping="$3"

  docker run -d \
    --name "$name" \
    --env-file .env \
    -v "${DATA_VOLUME}:/home/node/.n8n" \
    -v "${FILES_VOLUME}:/home/node/.n8n-files" \
    -p "$port_mapping" \
    --health-cmd "wget -qO- http://127.0.0.1:5678${HEALTH_PATH} >/dev/null 2>&1 || exit 1" \
    --health-interval 30s \
    --health-timeout 10s \
    --health-retries 5 \
    --health-start-period 60s \
    --log-driver json-file \
    --log-opt max-size=10m \
    --log-opt max-file=3 \
    --restart unless-stopped \
    "$image"
}

restore_previous_container() {
  local previous_image
  previous_image="$(cat previous_image.txt 2>/dev/null || true)"
  if [ -z "$previous_image" ]; then
    previous_image="$N8N_IMAGE_PREVIOUS"
  fi
  if [ -z "$previous_image" ]; then
    echo "No previous image available for rollback" >&2
    return 1
  fi

  docker stop "$CONTAINER_NAME" "$NEXT_CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" "$NEXT_CONTAINER_NAME" 2>/dev/null || true
  run_n8n_container "$CONTAINER_NAME" "$previous_image" "$PORT_MAPPING"
  wait_for "Rollback n8n container" "curl --fail --silent --show-error --max-time 10 http://127.0.0.1:5678${HEALTH_PATH} >/dev/null"
  sudo nginx -t
  sudo systemctl enable nginx
  sudo systemctl reload nginx || sudo systemctl restart nginx
  wait_for "Rollback n8n HTTPS" "curl -k --fail --silent --show-error --max-time 10 --resolve ${HOSTNAME}:443:127.0.0.1 https://${HOSTNAME}${HEALTH_PATH} >/dev/null"
}

main() {
  exec 9>"$DEPLOY_LOCK_FILE"
  flock 9

  mkdir -p "$DEPLOY_DIR"
  cd "$DEPLOY_DIR"

  ensure_runtime
  generate_env_file

  install_secret_file "$CERT_PARAMETER" "$CERT_PATH" 0644 '^-----BEGIN CERTIFICATE-----$'
  install_secret_file "$KEY_PARAMETER" "$KEY_PATH" 0600 '^-----BEGIN (RSA |EC )?PRIVATE KEY-----$'
  install_nginx_config

  docker volume create "$DATA_VOLUME" >/dev/null
  docker volume create "$FILES_VOLUME" >/dev/null

  PREVIOUS_IMAGE="$(docker inspect "$CONTAINER_NAME" --format='{{.Config.Image}}' 2>/dev/null || true)"
  echo "$PREVIOUS_IMAGE" > previous_image.txt

  cleanup_docker_resources
  assert_minimum_free_space

  if ! docker pull "$N8N_IMAGE"; then
    cleanup_after_failed_pull
    exit 1
  fi

  docker stop "$NEXT_CONTAINER_NAME" 2>/dev/null || true
  docker rm "$NEXT_CONTAINER_NAME" 2>/dev/null || true
  run_n8n_container "$NEXT_CONTAINER_NAME" "$N8N_IMAGE" "$CANDIDATE_PORT_MAPPING"

  if ! wait_for "n8n candidate container" "curl --fail --silent --show-error --max-time 10 http://127.0.0.1:5679${HEALTH_PATH} >/dev/null" "$NEXT_CONTAINER_NAME"; then
    docker ps -a
    docker logs --tail=100 "$NEXT_CONTAINER_NAME" || true
    docker stop "$NEXT_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$NEXT_CONTAINER_NAME" 2>/dev/null || true
    exit 1
  fi

  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
  docker stop "$NEXT_CONTAINER_NAME"
  docker rm "$NEXT_CONTAINER_NAME"
  run_n8n_container "$CONTAINER_NAME" "$N8N_IMAGE" "$PORT_MAPPING"

  if ! wait_for "n8n container" "curl --fail --silent --show-error --max-time 10 http://127.0.0.1:5678${HEALTH_PATH} >/dev/null"; then
    echo "Final n8n container failed after replacement. Restoring previous image..." >&2
    restore_previous_container
    exit 1
  fi

  sudo nginx -t
  sudo systemctl enable nginx
  if ! sudo systemctl reload nginx; then
    sudo systemctl restart nginx
  fi

  if ! wait_for "n8n HTTPS" "curl -k --fail --silent --show-error --max-time 10 --resolve ${HOSTNAME}:443:127.0.0.1 https://${HOSTNAME}${HEALTH_PATH} >/dev/null"; then
    echo "Nginx HTTPS verification failed after replacement. Restoring previous image..." >&2
    restore_previous_container
    exit 1
  fi

  cleanup_dangling_images
  cleanup_old_n8n_images
  print_disk_diagnostics
}

main "$@"
