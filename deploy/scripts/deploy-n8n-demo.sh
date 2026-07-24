#!/usr/bin/env bash
# Deploys the public n8n demo stack to the demo EC2 host. Runs ON that host,
# delivered and invoked over SSM Run Command the same way
# deploy/scripts/deploy-n8n.sh deploys production — never over SSH, and
# never on the production instance. Mirrors production's pattern for
# pulling SSM parameters into an env file and installing TLS/nginx config,
# but targets the completely separate /linkedin-job-application-automation/demo
# SSM path and demo-only IAM role.
set -Eeuo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${N8N_IMAGE:?N8N_IMAGE is required}"

PROJECT_NAME="linkedin-job-application-automation"
HOSTNAME="demo-n8n.ai-automation-platform.com"
DEMO_DIR="/opt/n8n-demo"
ENV_FILE="${DEMO_DIR}/.env.demo"
COMPOSE_FILE="${DEMO_DIR}/docker-compose.yml"
COMPOSE_PROJECT="n8n-demo"
SSM_PARAMETER_PATH="/${PROJECT_NAME}/demo/env"
CERT_PARAMETER="/${PROJECT_NAME}/demo/nginx/origin_certificate"
KEY_PARAMETER="/${PROJECT_NAME}/demo/nginx/origin_private_key"
SSL_DIR="/etc/nginx/ssl/${HOSTNAME}"
CERT_PATH="${SSL_DIR}/origin_certificate.pem"
KEY_PATH="${SSL_DIR}/origin_private_key.pem"
NGINX_SITE_NAME="n8n-demo"
SITE_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
SITE_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
HEALTH_PATH="/health"

require_cmd() {
  local cmd="$1"
  local package="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return
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
  require_cmd pg_restore postgresql-client
  if ! command -v docker >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io
  fi
  sudo systemctl enable --now docker
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
    | if (.Value | test("[\r\n]")) then error("Refusing multiline SSM parameter in .env.demo: " + .Name) else . end
    | ((.Name | split("/") | last) + "=" + .Value)
  ' "$params_json" > "$ENV_FILE"

  chmod 0600 "$ENV_FILE"
  rm -f "$params_json"
  trap - RETURN

  if grep -Eq 'origin_certificate|origin_private_key|BEGIN CERTIFICATE|BEGIN PRIVATE KEY|BEGIN RSA PRIVATE KEY|BEGIN EC PRIVATE KEY' "$ENV_FILE"; then
    echo "Refusing to deploy because TLS material was written to .env.demo" >&2
    exit 1
  fi
}

install_secret_file() {
  local parameter_name="$1"
  local destination="$2"
  local mode="$3"
  local marker_regex="$4"
  local tmp_file tmp_destination

  tmp_file="$(mktemp)"
  tmp_destination="${destination}.tmp"
  trap 'rm -f "$tmp_file"; sudo rm -f "$tmp_destination"' RETURN

  aws ssm get-parameter \
    --name "$parameter_name" \
    --with-decryption \
    --region "$AWS_REGION" \
    --query 'Parameter.Value' \
    --output text > "$tmp_file"

  [ -s "$tmp_file" ] || { echo "SSM parameter ${parameter_name} returned an empty value" >&2; return 1; }
  head -n 1 "$tmp_file" | grep -Eq "$marker_regex" || {
    echo "SSM parameter ${parameter_name} does not look like the expected PEM type" >&2
    return 1
  }

  sudo install -d -m 700 -o root -g root "$(dirname "$destination")"
  sudo install -o root -g root -m "$mode" "$tmp_file" "$tmp_destination"
  sudo mv "$tmp_destination" "$destination"
  rm -f "$tmp_file"
  trap - RETURN
}

install_nginx_config() {
  : "${NGINX_CONF_BASE64:?NGINX_CONF_BASE64 is required}"
  echo "$NGINX_CONF_BASE64" | base64 -d > "${DEMO_DIR}/${NGINX_SITE_NAME}.conf"
  sudo install -d -m 755 -o root -g root /etc/nginx/sites-available /etc/nginx/sites-enabled
  sudo install -o root -g root -m 0644 "${DEMO_DIR}/${NGINX_SITE_NAME}.conf" "$SITE_AVAILABLE"
  sudo ln -sfn "$SITE_AVAILABLE" "$SITE_ENABLED"
  sudo nginx -t
}

install_compose_file() {
  : "${COMPOSE_FILE_BASE64:?COMPOSE_FILE_BASE64 is required}"
  echo "$COMPOSE_FILE_BASE64" | base64 -d > "$COMPOSE_FILE"
  chmod 0644 "$COMPOSE_FILE"
}

install_sanitized_workflows() {
  # Optional: a tar of already-sanitized, already-validated workflow JSON
  # files produced by the sanitize-and-validate CI job. Never raw production
  # exports. Safe to skip entirely (WORKFLOWS_TAR_BASE64 unset) when this
  # step only needs to refresh infra/nginx/compose without touching workflows.
  if [ -n "${WORKFLOWS_TAR_BASE64:-}" ]; then
    rm -rf "${DEMO_DIR}/imports"
    mkdir -p "${DEMO_DIR}/imports"
    echo "$WORKFLOWS_TAR_BASE64" | base64 -d | tar -x -C "${DEMO_DIR}/imports"
  fi
}

install_operational_scripts() {
  : "${BUILD_SEED_SCRIPT_BASE64:?BUILD_SEED_SCRIPT_BASE64 is required}"
  : "${RESET_SCRIPT_BASE64:?RESET_SCRIPT_BASE64 is required}"

  sudo install -d -m 0750 -o root -g root "${DEMO_DIR}/scripts"
  echo "$BUILD_SEED_SCRIPT_BASE64" | base64 -d | sudo tee "${DEMO_DIR}/scripts/build_demo_seed.sh" >/dev/null
  sudo chown root:root "${DEMO_DIR}/scripts/build_demo_seed.sh"
  sudo chmod 0750 "${DEMO_DIR}/scripts/build_demo_seed.sh"

  echo "$RESET_SCRIPT_BASE64" | base64 -d | sudo tee /usr/local/sbin/reset-n8n-demo.sh >/dev/null
  sudo chown root:root /usr/local/sbin/reset-n8n-demo.sh
  sudo chmod 0750 /usr/local/sbin/reset-n8n-demo.sh
}

dc() {
  docker compose -p "$COMPOSE_PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

wait_for_health() {
  for _ in $(seq 1 40); do
    curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:5678${HEALTH_PATH}" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

main() {
  mkdir -p "$DEMO_DIR" "${DEMO_DIR}/imports" "${DEMO_DIR}/tmp"
  cd "$DEMO_DIR"

  ensure_runtime
  generate_env_file

  install_secret_file "$CERT_PARAMETER" "$CERT_PATH" 0644 '^-----BEGIN CERTIFICATE-----$'
  install_secret_file "$KEY_PARAMETER" "$KEY_PATH" 0600 '^-----BEGIN (RSA |EC )?PRIVATE KEY-----$'
  install_nginx_config
  install_compose_file
  install_operational_scripts
  install_sanitized_workflows

  docker pull "$N8N_IMAGE"

  dc up -d postgres
  for _ in $(seq 1 30); do
    status="$(dc ps --format json postgres 2>/dev/null | jq -r '.Health // empty' 2>/dev/null || true)"
    [ "$status" = "healthy" ] && break
    sleep 2
  done

  dc up -d n8n

  if ! wait_for_health; then
    echo "Demo n8n did not become healthy after deploy" >&2
    dc logs --tail=100 n8n || true
    exit 1
  fi

  sudo nginx -t
  sudo systemctl enable nginx
  sudo systemctl reload nginx || sudo systemctl restart nginx

  systemctl daemon-reload || true
  systemctl enable --now n8n-demo-reset.timer || true

  docker image prune -f
}

main "$@"
