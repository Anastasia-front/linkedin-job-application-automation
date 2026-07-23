#!/usr/bin/env bash
# Build a clean PostgreSQL seed for the public n8n demo instance.
#
# Runs ON the demo EC2 host (delivered there by deploy/scripts/deploy-n8n-demo.sh,
# same pattern production uses for its nginx config). Never runs on, or
# contacts, the production instance: it only imports the sanitized workflow
# files that were already transferred into /opt/n8n-demo/imports by the CI
# pipeline after scripts/n8n/sanitize_workflows.py and
# scripts/n8n/validate_demo_workflows.py both passed.
#
# Produces /opt/n8n-demo/seed/demo-seed.dump (root:root, 0600), used every
# day by reset_demo.sh. Never touches production. Fails closed: any error
# leaves the previous valid seed untouched (we only overwrite it after the
# new dump has been created AND validated with `pg_restore --list`).
set -Eeuo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DEMO_DIR="/opt/n8n-demo"
COMPOSE_FILE="${DEMO_DIR}/docker-compose.yml"
ENV_FILE="${DEMO_DIR}/.env.demo"
COMPOSE_PROJECT="n8n-demo"
POSTGRES_SERVICE="postgres"
N8N_SERVICE="n8n"
IMPORTS_DIR="${DEMO_DIR}/imports"
SEED_DIR="${DEMO_DIR}/seed"
SEED_PATH="${SEED_DIR}/demo-seed.dump"
PREVIOUS_SEED_PATH="${SEED_DIR}/demo-seed.previous.dump"
METADATA_PATH="${SEED_DIR}/metadata.json"
LOCK_FILE="/var/lock/n8n-demo-build-seed.lock"
LOG_FILE="/var/log/n8n-demo-reset.log"
HEALTH_URL="http://127.0.0.1:5678/health"
SANITIZER_VERSION="1"
GIT_COMMIT="${GIT_COMMIT:-unknown}"
N8N_IMAGE_TAG="${N8N_IMAGE_TAG:-docker.n8n.io/n8nio/n8n:1.102.4}"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] build_demo_seed: $*"
}

dc() {
  docker compose -p "$COMPOSE_PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

fail() {
  log "FAILED: $*"
  exit 1
}

wait_for_health() {
  local url="$1"
  local attempts="${2:-30}"
  for _ in $(seq 1 "$attempts"); do
    if curl --fail --silent --show-error --max-time 5 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

ensure_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "another build_demo_seed run is already in progress, exiting"
    exit 1
  fi
}

validate_prereqs() {
  for cmd in docker jq curl pg_restore flock; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command '$cmd' not found on PATH"
  done
  [ -f "$COMPOSE_FILE" ] || fail "compose file not found: $COMPOSE_FILE"
  [ -f "$ENV_FILE" ] || fail "env file not found: $ENV_FILE"
  install -d -m 0700 -o root -g root "$SEED_DIR"
}

main() {
  {
    ensure_lock
    validate_prereqs

    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
    : "${DB_POSTGRESDB_USER:?DB_POSTGRESDB_USER missing from $ENV_FILE}"
    : "${DB_POSTGRESDB_DATABASE:?DB_POSTGRESDB_DATABASE missing from $ENV_FILE}"
    : "${DEMO_USER_EMAIL:?DEMO_USER_EMAIL missing from $ENV_FILE}"
    : "${DEMO_USER_PASSWORD:?DEMO_USER_PASSWORD missing from $ENV_FILE}"
    local db_user="$DB_POSTGRESDB_USER"
    local db_name="$DB_POSTGRESDB_DATABASE"

    local import_count=0
    if compgen -G "${IMPORTS_DIR}/*.json" >/dev/null; then
      import_count=$(find "$IMPORTS_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
    fi
    log "found ${import_count} sanitized workflow file(s) to import"

    cd "$DEMO_DIR"

    log "starting postgres"
    dc up -d "$POSTGRES_SERVICE"
    postgres_healthy=""
    for _ in $(seq 1 30); do
      status="$(dc ps --format json "$POSTGRES_SERVICE" 2>/dev/null | jq -r '.Health // empty' 2>/dev/null || true)"
      if [ "$status" = "healthy" ]; then
        postgres_healthy=1
        break
      fi
      sleep 2
    done
    [ -n "$postgres_healthy" ] || fail "postgres did not become healthy"

    log "recreating a clean database: ${db_name}"
    dc exec -T "$POSTGRES_SERVICE" psql -U "$db_user" -d postgres -v ON_ERROR_STOP=1 -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${db_name}' AND pid <> pg_backend_pid();" || true
    dc exec -T "$POSTGRES_SERVICE" dropdb -U "$db_user" --if-exists "$db_name"
    dc exec -T "$POSTGRES_SERVICE" createdb -U "$db_user" --owner="$db_user" "$db_name"

    log "starting n8n to run migrations"
    dc up -d "$N8N_SERVICE"
    wait_for_health "$HEALTH_URL" 40 || fail "n8n did not become healthy after DB recreation"

    log "ensuring the shared demo owner account exists"
    owner_response="$(curl --silent --show-error --max-time 10 -o /dev/null -w '%{http_code}' \
      -X POST "http://127.0.0.1:5678/rest/owner/setup" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"${DEMO_USER_EMAIL}\",\"firstName\":\"Demo\",\"lastName\":\"User\",\"password\":\"${DEMO_USER_PASSWORD}\"}" || true)"
    case "$owner_response" in
      200|201) log "demo owner account created" ;;
      400|401|403) log "owner setup returned ${owner_response} (likely already configured), continuing" ;;
      *) log "owner setup returned unexpected status ${owner_response}, continuing (verify manually if seed looks wrong)" ;;
    esac

    if [ "$import_count" -gt 0 ]; then
      dc exec -T "$N8N_SERVICE" n8n import:workflow --help >/tmp/n8n-import-help.txt 2>&1 || true
      if ! grep -q -- '--separate' /tmp/n8n-import-help.txt || ! grep -q -- '--input' /tmp/n8n-import-help.txt; then
        fail "n8n import:workflow --help does not advertise --separate/--input on this pinned image; update this script for the current n8n version instead of guessing flags"
      fi
      log "importing sanitized workflows"
      dc exec -T "$N8N_SERVICE" n8n import:workflow --separate --input=/imports
    else
      log "no sanitized workflows to import, seeding an empty (but usable) demo instance"
    fi

    log "verifying every imported workflow is inactive"
    active_count="$(dc exec -T "$POSTGRES_SERVICE" psql -U "$db_user" -d "$db_name" -tA -c \
      "SELECT count(*) FROM workflow_entity WHERE active = true;")"
    [ "${active_count//[[:space:]]/}" = "0" ] || fail "found ${active_count} active workflow(s) after import; refusing to seed"

    log "verifying no credential records exist"
    cred_count="$(dc exec -T "$POSTGRES_SERVICE" psql -U "$db_user" -d "$db_name" -tA -c \
      "SELECT count(*) FROM credentials_entity;")"
    [ "${cred_count//[[:space:]]/}" = "0" ] || fail "found ${cred_count} credential record(s) after import; refusing to seed"

    log "removing execution history"
    dc exec -T "$POSTGRES_SERVICE" psql -U "$db_user" -d "$db_name" -v ON_ERROR_STOP=1 -c \
      "TRUNCATE execution_entity CASCADE;"

    log "removing temporary import files"
    find "$IMPORTS_DIR" -maxdepth 1 -name '*.json' -delete

    log "stopping n8n before taking the snapshot"
    dc stop "$N8N_SERVICE"

    local tmp_dump
    tmp_dump="$(mktemp "${SEED_DIR}/.demo-seed.XXXXXX.tmp")"
    trap 'rm -f "$tmp_dump"' RETURN

    log "creating pg_dump custom-format snapshot"
    dc exec -T "$POSTGRES_SERVICE" pg_dump -U "$db_user" -Fc -d "$db_name" > "$tmp_dump"

    [ -s "$tmp_dump" ] || fail "pg_dump produced an empty file"
    pg_restore --list "$tmp_dump" >/dev/null || fail "new dump failed pg_restore --list validation"

    if [ -f "$SEED_PATH" ]; then
      install -o root -g root -m 0600 "$SEED_PATH" "$PREVIOUS_SEED_PATH"
    fi
    install -o root -g root -m 0600 "$tmp_dump" "$SEED_PATH"
    rm -f "$tmp_dump"
    trap - RETURN

    node_count=0
    if [ "$import_count" -gt 0 ]; then
      node_count="$(jq -s '[.[].nodes[]?] | length' "${IMPORTS_DIR}"/*.json 2>/dev/null || echo 0)"
    fi

    cat > "$METADATA_PATH" <<EOF
{
  "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "git_commit": "${GIT_COMMIT}",
  "workflow_count": ${import_count},
  "node_count": ${node_count},
  "sanitizer_version": "${SANITIZER_VERSION}",
  "n8n_version": "${N8N_IMAGE_TAG}"
}
EOF
    chmod 0644 "$METADATA_PATH"
    chown root:root "$METADATA_PATH"

    log "restarting n8n"
    dc up -d "$N8N_SERVICE"
    wait_for_health "$HEALTH_URL" 40 || fail "n8n did not become healthy after seed build"

    log "seed build succeeded: workflows=${import_count} nodes=${node_count} commit=${GIT_COMMIT}"
  } >>"$LOG_FILE" 2>&1
}

on_error() {
  {
    log "seed build aborted, attempting to leave n8n running on the previous state"
    dc up -d "$N8N_SERVICE" || true
  } >>"$LOG_FILE" 2>&1
}
trap on_error ERR

main "$@"
