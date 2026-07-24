#!/usr/bin/env bash
# Idempotent, repository-driven n8n workflow seeding.
#
# Reused by both production (deploy/scripts/deploy-n8n.sh, called directly
# against the running container) and demo (scripts/n8n/build_demo_seed.sh,
# called against the compose-managed n8n container) so import/verify logic
# exists in exactly one place.
#
# Runs standalone on the remote EC2 host (delivered by the same base64/SSM
# mechanism as the rest of deploy/scripts/*.sh — no repo checkout on the
# host), so it only depends on tools ensure_runtime() already installs
# there: docker, jq. Manifest *schema* validation (duplicate ids, missing
# files, id/file mismatches) runs earlier, on the GitHub runner where the
# full repo and Python are available (scripts/n8n/validate_workflow_manifest.py,
# called from the CI `validate` job) — by the time this script runs, the
# manifest is already known-good; this script only has to trust and apply it.
#
# Strategy (n8n 1.102.4 CLI):
#   - `n8n import:workflow --separate --input=<dir>` imports every *.json
#     file in a directory in one call (confirmed via
#     `n8n import:workflow --help` on the pinned image, not guessed).
#   - Workflow JSON files in this repo carry a stable top-level "id". n8n's
#     import command persists entities via an upsert keyed on that id: an
#     existing workflow with a matching id is updated in place rather than
#     duplicated. This script does NOT blindly trust that behavior — it
#     re-exports every managed id after import and fails if any manifest id
#     is missing or appears more than once, so a wrong assumption about CLI
#     upsert semantics is caught here rather than silently duplicating
#     workflows in production.
#   - Only files listed in the manifest are touched. Non-managed workflows
#     already in the instance (e.g. anything a human created by hand) are
#     never imported over, exported, or deleted by this script.
#
# This script never creates/modifies credentials and never deletes
# executions; it only calls `n8n import:workflow` / `n8n export:workflow`.
set -Eeuo pipefail

usage() {
  cat <<'USAGE' >&2
Usage: seed-n8n-workflows.sh --container <name> --workflow-dir <host-dir> \
         --manifest <host-manifest-path> --environment <production|demo> \
         [--health-timeout-seconds N]

When called with no arguments (the case when this file is transferred and
run standalone via deploy/scripts/ssm-run.sh, which has no way to pass CLI
args to the remote script) the same options are read from the environment
instead: SEED_CONTAINER, SEED_WORKFLOW_DIR, SEED_MANIFEST, SEED_ENVIRONMENT,
SEED_HEALTH_TIMEOUT_SECONDS.
USAGE
}

CONTAINER="${SEED_CONTAINER:-}"
WORKFLOW_DIR="${SEED_WORKFLOW_DIR:-}"
MANIFEST="${SEED_MANIFEST:-}"
ENVIRONMENT="${SEED_ENVIRONMENT:-}"
HEALTH_TIMEOUT_SECONDS="${SEED_HEALTH_TIMEOUT_SECONDS:-120}"

while [ $# -gt 0 ]; do
  case "$1" in
    --container) CONTAINER="${2:?}"; shift 2 ;;
    --workflow-dir) WORKFLOW_DIR="${2:?}"; shift 2 ;;
    --manifest) MANIFEST="${2:?}"; shift 2 ;;
    --environment) ENVIRONMENT="${2:?}"; shift 2 ;;
    --health-timeout-seconds) HEALTH_TIMEOUT_SECONDS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$CONTAINER" ] || { echo "ERROR: --container is required" >&2; usage; exit 1; }
[ -n "$WORKFLOW_DIR" ] || { echo "ERROR: --workflow-dir is required" >&2; usage; exit 1; }
[ -n "$MANIFEST" ] || { echo "ERROR: --manifest is required" >&2; usage; exit 1; }
[ -n "$ENVIRONMENT" ] || { echo "ERROR: --environment is required" >&2; usage; exit 1; }

log() {
  echo "[seed-n8n-workflows:${ENVIRONMENT}] $*"
}

fail() {
  echo "[seed-n8n-workflows:${ENVIRONMENT}] FAILED: $*" >&2
  exit 1
}

wait_for_container_health() {
  local status="unknown"
  for _ in $(seq 1 "$HEALTH_TIMEOUT_SECONDS"); do
    status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER" 2>/dev/null || true)"
    if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
      return 0
    fi
    sleep 1
  done
  fail "container '$CONTAINER' did not report healthy/running within ${HEALTH_TIMEOUT_SECONDS}s (last status: ${status})"
}

main() {
  [ -d "$WORKFLOW_DIR" ] || fail "workflow directory not found: $WORKFLOW_DIR"
  [ -f "$MANIFEST" ] || fail "manifest not found: $MANIFEST"

  local manifest_json
  manifest_json="$(cat "$MANIFEST")"

  echo "$manifest_json" | jq -e '.workflows | type == "array" and length > 0' >/dev/null \
    || fail "manifest has no workflow entries: $MANIFEST"

  local expected_count
  expected_count="$(echo "$manifest_json" | jq '.workflows | length')"
  log "manifest declares ${expected_count} managed workflow(s)"

  local dup_ids
  dup_ids="$(echo "$manifest_json" | jq -r '[.workflows[].id] | group_by(.) | map(select(length > 1)) | .[][0]' | sort -u)"
  if [ -n "$dup_ids" ]; then
    fail "duplicate workflow id(s) in manifest: $(echo "$dup_ids" | tr '\n' ' ')"
  fi

  wait_for_container_health

  log "checking n8n import:workflow CLI supports --separate/--input on this image"
  local help_output
  help_output="$(docker exec "$CONTAINER" n8n import:workflow --help 2>&1 || true)"
  echo "$help_output" | grep -q -- '--separate' || fail "n8n import:workflow --help does not advertise --separate on this image"
  echo "$help_output" | grep -q -- '--input' || fail "n8n import:workflow --help does not advertise --input on this image"

  local remote_import_dir="/tmp/seed-workflows-${ENVIRONMENT}"
  local remote_export_dir="/tmp/seed-workflows-${ENVIRONMENT}-verify"

  docker exec "$CONTAINER" rm -rf "$remote_import_dir" "$remote_export_dir"
  docker exec "$CONTAINER" mkdir -p "$remote_import_dir"

  log "copying ${expected_count} manifest-managed workflow file(s) into the container"
  local wid file
  while IFS=$'\t' read -r wid file; do
    if [ -z "$wid" ] || [ -z "$file" ]; then
      fail "manifest entry missing id or file"
    fi

    if [ ! -f "${WORKFLOW_DIR}/${file}" ]; then
      fail "workflow file not found: ${WORKFLOW_DIR}/${file}"
    fi

    docker cp \
      "${WORKFLOW_DIR}/${file}" \
      "${CONTAINER}:${remote_import_dir}/${file}"
  done < <(
    echo "$manifest_json" |
      jq -r '.workflows[] | [.id, .file] | @tsv'
  )

  log "importing workflows via n8n CLI (upsert by deterministic id)"
  if ! docker exec "$CONTAINER" n8n import:workflow --separate --input="$remote_import_dir"; then
    docker exec "$CONTAINER" rm -rf "$remote_import_dir" || true
    fail "n8n import:workflow failed"
  fi
  docker exec "$CONTAINER" rm -rf "$remote_import_dir"

  log "verifying seeded workflows via n8n export:workflow --all"
  docker exec "$CONTAINER" mkdir -p "$remote_export_dir"
  if ! docker exec "$CONTAINER" n8n export:workflow --all --separate --output="$remote_export_dir"; then
    docker exec "$CONTAINER" rm -rf "$remote_export_dir" || true
    fail "n8n export:workflow --all failed during verification"
  fi

  local local_export_dir
  local_export_dir="$(mktemp -d)"
  trap 'rm -rf "$local_export_dir"' RETURN
  docker cp "${CONTAINER}:${remote_export_dir}/." "$local_export_dir"
  docker exec "$CONTAINER" rm -rf "$remote_export_dir"

  local seeded_count=0
  local missing=""
  local duplicated=""

  while IFS=$'\t' read -r wid file; do
    local matches=0
    local exported_file
    for exported_file in "$local_export_dir"/*.json; do
      [ -f "$exported_file" ] || continue
      if [ "$(jq -r --arg id "$wid" 'select(.id == $id) | .id' "$exported_file" 2>/dev/null)" = "$wid" ]; then
        matches=$((matches + 1))
      fi
    done
    if [ "$matches" -eq 0 ]; then
      missing="${missing}${missing:+, }${wid}"
    elif [ "$matches" -gt 1 ]; then
      duplicated="${duplicated}${duplicated:+, }${wid} (x${matches})"
    else
      seeded_count=$((seeded_count + 1))
    fi
  done < <(echo "$manifest_json" | jq -r '.workflows[] | [.id, .file] | @tsv')

  rm -rf "$local_export_dir"
  trap - RETURN

  if [ -n "$missing" ]; then
    fail "expected workflow id(s) missing after import: ${missing}"
  fi

  if [ -n "$duplicated" ]; then
    fail "duplicate workflow id(s) found after import (n8n did not upsert as expected): ${duplicated}"
  fi

  if [ "$seeded_count" -ne "$expected_count" ]; then
    fail "seeded count (${seeded_count}) does not match manifest count (${expected_count})"
  fi

  log "seed verification passed: ${seeded_count}/${expected_count} managed workflow(s) present, no duplicates"
  echo "SEEDED_WORKFLOW_COUNT=${seeded_count}"
}

main "$@"
