#!/usr/bin/env bash
# Daily reset of the public n8n demo instance to the last validated clean
# seed. Installed on the demo EC2 host as /usr/local/sbin/reset-n8n-demo.sh,
# invoked by n8n-demo-reset.timer (systemd) once a day.
#
# Never contacts production and never exports anything: it only restores
# /opt/n8n-demo/seed/demo-seed.dump, the artifact build_demo_seed.sh already
# validated. If the restore fails, it retries once from
# demo-seed.previous.dump; if that also fails, it leaves the demo instance
# stopped and exits non-zero rather than serving an empty/partial database.
set -Eeuo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DEMO_DIR="/opt/n8n-demo"
COMPOSE_FILE="${DEMO_DIR}/docker-compose.yml"
ENV_FILE="${DEMO_DIR}/.env.demo"
COMPOSE_PROJECT="n8n-demo"
POSTGRES_SERVICE="postgres"
N8N_SERVICE="n8n"
SEED_DIR="${DEMO_DIR}/seed"
SEED_PATH="${SEED_DIR}/demo-seed.dump"
PREVIOUS_SEED_PATH="${SEED_DIR}/demo-seed.previous.dump"
METADATA_PATH="${SEED_DIR}/metadata.json"
LOCK_FILE="/var/lock/n8n-demo-reset.lock"
LOG_FILE="/var/log/n8n-demo-reset.log"
HEALTH_URL="http://127.0.0.1:5678/health"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] reset_demo: $*"
}

dc() {
  docker compose -p "$COMPOSE_PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

wait_for_health() {
  local attempts="${1:-40}"
  for _ in $(seq 1 "$attempts"); do
    if curl --fail --silent --show-error --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

capture_diagnostics() {
  log "capturing diagnostics (no secrets)"
  dc logs --tail=100 "$N8N_SERVICE" 2>&1 | tail -100 || true
  dc logs --tail=100 "$POSTGRES_SERVICE" 2>&1 | tail -100 || true
}

restore_from() {
  local dump_path="$1"
  pg_restore --list "$dump_path" >/dev/null || return 1

  dc exec -T "$POSTGRES_SERVICE" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" || true
  dc exec -T "$POSTGRES_SERVICE" dropdb -U "$DB_USER" --if-exists "$DB_NAME" || return 1
  dc exec -T "$POSTGRES_SERVICE" createdb -U "$DB_USER" --owner="$DB_USER" "$DB_NAME" || return 1
  dc exec -T "$POSTGRES_SERVICE" pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-privileges < "$dump_path" || return 1

  dc up -d "$N8N_SERVICE" || return 1
  wait_for_health 40
}

main() {
  {
    log "reset starting"

    for cmd in docker jq curl pg_restore flock; do
      command -v "$cmd" >/dev/null 2>&1 || { log "FAILED: required command '$cmd' not found"; exit 1; }
    done

    [ -f "$COMPOSE_FILE" ] || { log "FAILED: compose file not found: $COMPOSE_FILE"; exit 1; }
    [ -f "$ENV_FILE" ] || { log "FAILED: env file not found: $ENV_FILE"; exit 1; }
    [ -s "$SEED_PATH" ] || { log "FAILED: seed missing or empty: $SEED_PATH"; exit 1; }

    if ! pg_restore --list "$SEED_PATH" >/dev/null 2>&1; then
      log "FAILED: seed at $SEED_PATH is not a valid pg_dump custom-format archive"
      exit 1
    fi

    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
    : "${DB_POSTGRESDB_USER:?DB_POSTGRESDB_USER missing from $ENV_FILE}"
    : "${DB_POSTGRESDB_DATABASE:?DB_POSTGRESDB_DATABASE missing from $ENV_FILE}"
    DB_USER="$DB_POSTGRESDB_USER"
    DB_NAME="$DB_POSTGRESDB_DATABASE"

    if [ -f "$METADATA_PATH" ]; then
      log "restoring seed: $(jq -c '{created_at, git_commit, workflow_count}' "$METADATA_PATH" 2>/dev/null || echo '{}')"
    fi

    cd "$DEMO_DIR"

    log "stopping demo n8n (postgres stays up)"
    dc stop "$N8N_SERVICE"

    if restore_from "$SEED_PATH"; then
      log "reset succeeded from primary seed"
    else
      log "primary seed restore failed, attempting recovery from previous seed"
      capture_diagnostics

      if [ -s "$PREVIOUS_SEED_PATH" ] && restore_from "$PREVIOUS_SEED_PATH"; then
        log "recovery succeeded using previous seed; primary seed likely corrupt, investigate before next build"
      else
        log "FAILED: recovery from previous seed also failed; stopping demo n8n and leaving it unavailable"
        dc stop "$N8N_SERVICE" || true
        capture_diagnostics
        exit 1
      fi
    fi

    log "reset finished successfully"
  } >>"$LOG_FILE" 2>&1
}

(
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] reset_demo: another reset is already running, exiting" >>"$LOG_FILE"
    exit 1
  fi
  main "$@"
)
