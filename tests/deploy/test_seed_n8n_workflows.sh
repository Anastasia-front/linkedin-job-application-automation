#!/usr/bin/env bash
# Lightweight, dependency-free tests for deploy/scripts/seed-n8n-workflows.sh.
#
# There is no real Docker/n8n available in CI or locally for these tests, so
# this harness puts fake `docker` and `n8n` executables on PATH:
#   - fake docker: `docker exec <container> <cmd...>` just runs <cmd...>
#     directly (no real container namespace), `docker cp` copies between
#     plain paths after stripping the `container:` prefix, and
#     `docker inspect` reports $FAKE_DOCKER_HEALTH ("healthy" by default).
#   - fake n8n: persists "imported" workflows as one JSON file per id under
#     $FAKE_DB_DIR, so re-importing the same id overwrites (upserts) rather
#     than duplicating — the same behavior the real n8n CLI is assumed (and
#     independently verified by seed-n8n-workflows.sh) to have.
#
# Run: tests/deploy/test_seed_n8n_workflows.sh
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
SEED_SCRIPT="${REPO_ROOT}/deploy/scripts/seed-n8n-workflows.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  ok: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  FAIL: $1"; }

assert_success() {
  local desc="$1"; shift
  if "$@" >/tmp/seed-test-stdout.txt 2>/tmp/seed-test-stderr.txt; then
    pass "$desc"
  else
    fail "$desc (exit $?, stderr: $(cat /tmp/seed-test-stderr.txt))"
  fi
}

assert_failure() {
  local desc="$1"; shift
  if "$@" >/tmp/seed-test-stdout.txt 2>/tmp/seed-test-stderr.txt; then
    fail "$desc (expected non-zero exit, got 0)"
  else
    pass "$desc"
  fi
}

assert_true() {
  local desc="$1"; shift
  if "$@"; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

# --- fake docker/n8n fixture setup ------------------------------------

FIXTURE_ROOT=""

setup_fixture() {
  FIXTURE_ROOT="$(mktemp -d)"
  mkdir -p "${FIXTURE_ROOT}/bin" "${FIXTURE_ROOT}/db" "${FIXTURE_ROOT}/workflows"

  cat > "${FIXTURE_ROOT}/bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail

strip_container_prefix() {
  # "container:/path" -> "/path"; plain "/path" -> "/path" unchanged.
  case "$1" in
    *:*) echo "${1#*:}" ;;
    *) echo "$1" ;;
  esac
}

case "$1" in
  inspect)
    echo "${FAKE_DOCKER_HEALTH:-healthy}"
    ;;
  exec)
    shift 2 # drop "exec <container>"
    "$@"
    ;;
  cp)
    src="$(strip_container_prefix "$2")"
    dest="$(strip_container_prefix "$3")"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    cp -r "$src" "$dest"
    ;;
  *)
    echo "fake docker: unhandled subcommand: $1" >&2
    exit 1
    ;;
esac
FAKE_DOCKER
  chmod +x "${FIXTURE_ROOT}/bin/docker"

  cat > "${FIXTURE_ROOT}/bin/n8n" <<FAKE_N8N
#!/usr/bin/env bash
set -Eeuo pipefail
DB_DIR="${FIXTURE_ROOT}/db"

case "\$1" in
  import:workflow)
    if [ "\${2:-}" = "--help" ]; then
      echo "Options: --separate  --input=<value>"
      exit 0
    fi
    [ "\${FAKE_IMPORT_FAIL:-0}" = "1" ] && { echo "fake import failure" >&2; exit 1; }
    input_dir=""
    for arg in "\$@"; do
      case "\$arg" in
        --input=*) input_dir="\${arg#--input=}" ;;
      esac
    done
    [ -n "\$input_dir" ] || { echo "no --input given" >&2; exit 1; }
    mkdir -p "\$DB_DIR"
    for f in "\$input_dir"/*.json; do
      [ -f "\$f" ] || continue
      wid="\$(jq -r '.id' "\$f")"
      [ "\$wid" = "\${FAKE_DROP_ID:-}" ] && continue
      cp "\$f" "\${DB_DIR}/\${wid}.json"
    done
    ;;
  export:workflow)
    [ "\${FAKE_EXPORT_FAIL:-0}" = "1" ] && { echo "fake export failure" >&2; exit 1; }
    output_dir=""
    for arg in "\$@"; do
      case "\$arg" in
        --output=*) output_dir="\${arg#--output=}" ;;
      esac
    done
    [ -n "\$output_dir" ] || { echo "no --output given" >&2; exit 1; }
    mkdir -p "\$output_dir"
    if compgen -G "\${DB_DIR}/*.json" >/dev/null; then
      cp "\${DB_DIR}"/*.json "\$output_dir"/
    fi
    ;;
  *)
    echo "fake n8n: unhandled subcommand: \$1" >&2
    exit 1
    ;;
esac
FAKE_N8N
  chmod +x "${FIXTURE_ROOT}/bin/n8n"

  export PATH="${FIXTURE_ROOT}/bin:${PATH}"
  export FAKE_DOCKER_HEALTH="healthy"
  unset FAKE_IMPORT_FAIL FAKE_EXPORT_FAIL FAKE_DROP_ID || true
  # Force bash to re-resolve `docker`/`n8n` against the new PATH entry rather
  # than a cached (and, after teardown_fixture, deleted) path from a prior
  # fixture directory.
  hash -r
}

teardown_fixture() {
  rm -rf "$FIXTURE_ROOT"
  hash -r
}

write_workflow() {
  local dir="$1" file="$2" id="$3" name="$4"
  jq -n --arg id "$id" --arg name "$name" '{id: $id, name: $name, nodes: []}' > "${dir}/${file}"
}

write_manifest() {
  local manifest_path="$1"; shift
  # remaining args: "id:file:name" triples
  python3 - "$manifest_path" "$@" <<'PY'
import json, sys
manifest_path = sys.argv[1]
entries = []
for triple in sys.argv[2:]:
    wid, file, name = triple.split(":", 2)
    entries.append({"id": wid, "file": file, "name": name})
json.dump({"environment": "test", "workflows": entries}, open(manifest_path, "w"))
PY
}

run_seed() {
  "$SEED_SCRIPT" \
    --container fake-container \
    --workflow-dir "${FIXTURE_ROOT}/workflows" \
    --manifest "${FIXTURE_ROOT}/manifest.json" \
    --environment test \
    --health-timeout-seconds "${1:-5}"
}

echo "=== test_seed_n8n_workflows.sh ==="

# --- 5. First-time import ------------------------------------------------
echo "5. first-time import"
setup_fixture
write_workflow "${FIXTURE_ROOT}/workflows" "one.json" "id-one" "One"
write_manifest "${FIXTURE_ROOT}/manifest.json" "id-one:one.json:One"
assert_success "first import succeeds" run_seed
if grep -q '^SEEDED_WORKFLOW_COUNT=1$' /tmp/seed-test-stdout.txt; then
  pass "reports seeded count 1"
else
  fail "reports seeded count 1 (got: $(cat /tmp/seed-test-stdout.txt))"
fi
assert_true "workflow persisted in fake db" [ -f "${FIXTURE_ROOT}/db/id-one.json" ]
teardown_fixture

# --- 6. Repeated import without duplicates -------------------------------
echo "6. repeated import without duplicates"
setup_fixture
write_workflow "${FIXTURE_ROOT}/workflows" "one.json" "id-one" "One"
write_manifest "${FIXTURE_ROOT}/manifest.json" "id-one:one.json:One"
assert_success "first import succeeds" run_seed
assert_success "second import succeeds" run_seed
count_files="$(find "${FIXTURE_ROOT}/db" -name '*.json' | wc -l | tr -d ' ')"
assert_true "still exactly one db file after repeat import (got $count_files)" [ "$count_files" -eq 1 ]
teardown_fixture

# --- 7. Updated workflow replacing the managed version --------------------
echo "7. updated workflow replaces managed version"
setup_fixture
write_workflow "${FIXTURE_ROOT}/workflows" "one.json" "id-one" "Original Name"
write_manifest "${FIXTURE_ROOT}/manifest.json" "id-one:one.json:Original Name"
assert_success "first import succeeds" run_seed
write_workflow "${FIXTURE_ROOT}/workflows" "one.json" "id-one" "Updated Name"
assert_success "second import (updated content) succeeds" run_seed
persisted_name="$(jq -r '.name' "${FIXTURE_ROOT}/db/id-one.json")"
assert_true "db reflects updated content (got: $persisted_name)" [ "$persisted_name" = "Updated Name" ]
count_files="$(find "${FIXTURE_ROOT}/db" -name '*.json' | wc -l | tr -d ' ')"
assert_true "no duplicate created on update (got $count_files)" [ "$count_files" -eq 1 ]
teardown_fixture

# --- 8. Existing non-managed workflow remains untouched --------------------
echo "8. existing non-managed workflow untouched"
setup_fixture
mkdir -p "${FIXTURE_ROOT}/db"
write_workflow "${FIXTURE_ROOT}/db" "unmanaged.json" "id-unmanaged" "Hand Made"
write_workflow "${FIXTURE_ROOT}/workflows" "one.json" "id-one" "One"
write_manifest "${FIXTURE_ROOT}/manifest.json" "id-one:one.json:One"
assert_success "import succeeds" run_seed
assert_true "unmanaged workflow file still present" [ -f "${FIXTURE_ROOT}/db/unmanaged.json" ]
unmanaged_name="$(jq -r '.name' "${FIXTURE_ROOT}/db/unmanaged.json")"
assert_true "unmanaged workflow content unchanged (got: $unmanaged_name)" [ "$unmanaged_name" = "Hand Made" ]
teardown_fixture

# --- 9. Import command failure ---------------------------------------------
echo "9. import command failure"
setup_fixture
write_workflow "${FIXTURE_ROOT}/workflows" "one.json" "id-one" "One"
write_manifest "${FIXTURE_ROOT}/manifest.json" "id-one:one.json:One"
export FAKE_IMPORT_FAIL=1
assert_failure "seed fails when n8n import:workflow fails" run_seed
unset FAKE_IMPORT_FAIL
teardown_fixture

# --- 10. Container not healthy ----------------------------------------------
echo "10. container not healthy"
setup_fixture
write_workflow "${FIXTURE_ROOT}/workflows" "one.json" "id-one" "One"
write_manifest "${FIXTURE_ROOT}/manifest.json" "id-one:one.json:One"
export FAKE_DOCKER_HEALTH="starting"
assert_failure "seed fails when container never becomes healthy" run_seed 2
unset FAKE_DOCKER_HEALTH
teardown_fixture

# --- 11. Missing expected workflow after import -----------------------------
echo "11. missing expected workflow after import"
setup_fixture
write_workflow "${FIXTURE_ROOT}/workflows" "one.json" "id-one" "One"
write_workflow "${FIXTURE_ROOT}/workflows" "two.json" "id-two" "Two"
write_manifest "${FIXTURE_ROOT}/manifest.json" "id-one:one.json:One" "id-two:two.json:Two"
export FAKE_DROP_ID="id-two"
assert_failure "seed fails when an expected id is missing after import" run_seed
assert_true "error message names the missing id" grep -q "missing after import" /tmp/seed-test-stderr.txt
unset FAKE_DROP_ID
teardown_fixture

echo ""
echo "=== ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="
[ "$FAIL_COUNT" -eq 0 ]
