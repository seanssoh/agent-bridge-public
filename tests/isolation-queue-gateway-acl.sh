#!/usr/bin/env bash
# tests/isolation-queue-gateway-acl.sh
#
# Targeted regression test for the queue-gateway ACL fix in
# bridge_linux_prepare_agent_isolation + bridge_migration_unisolate.
#
# Verifies:
#   1. After isolate, the queue-gateway root has controller r-x and isolated
#      UID --x (traverse-only). The per-agent gateway dir has both UIDs at
#      rwX with default ACL.
#   2. The isolated UID cannot enumerate the gateway root (cross-agent
#      directory-name leak), but its own subtree is reachable.
#   3. bridge-queue-gateway.py serve-once consumes a synthetic request from
#      <root>/<agent>/requests and writes a response to
#      <root>/<agent>/responses.
#   4. After unisolate, both the access and default ACL entries for the
#      target os_user are stripped from the gateway root and the per-agent
#      directory, while the controller's ACLs remain intact.
#
# Skip preconditions: Linux, passwordless sudo, setfacl, useradd available.
# This test creates a temporary system user (default agent-bridge-test-uX)
# and removes it at the end. Run on a host where you can do that safely.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

log() { printf '[isolate-acl] %s\n' "$*"; }
die() { printf '[isolate-acl][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[isolate-acl][skip] %s\n' "$*"; exit 0; }

# Preconditions.
[[ "$(uname -s)" == "Linux" ]] || skip "Linux-only test"
command -v sudo >/dev/null 2>&1 || skip "sudo required"
sudo -n true >/dev/null 2>&1 || skip "passwordless sudo required"
command -v setfacl >/dev/null 2>&1 || skip "setfacl (acl package) required"
command -v useradd >/dev/null 2>&1 || skip "useradd required"
command -v userdel >/dev/null 2>&1 || skip "userdel required"

# Sandbox under a temp BRIDGE_HOME so we never touch a live install.
TMP_ROOT="$(mktemp -d -t isolate-acl-test.XXXXXX)"
export BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=1
SAFE_TMP_PREFIX=""
for _candidate in "${TMPDIR%/}" "/tmp" "/var/tmp"; do
  [[ -n "$_candidate" ]] || continue
  case "$TMP_ROOT" in
    "$_candidate"|"$_candidate"/*) SAFE_TMP_PREFIX="$_candidate"; break ;;
  esac
done
[[ -n "$SAFE_TMP_PREFIX" ]] || die "TMP_ROOT did not land under a recognised tempdir prefix: $TMP_ROOT"

export BRIDGE_HOME="$TMP_ROOT/bridge-home"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
mkdir -p "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR"
: > "$BRIDGE_ROSTER_FILE"
: > "$BRIDGE_ROSTER_LOCAL_FILE"

# Pick a unique temp user. If a previous run left the user behind, reuse it.
TEST_AGENT="qg-acl-test"
TEST_OS_USER="agent-bridge-${TEST_AGENT}"
TEST_OS_HOME="/home/${TEST_OS_USER}"

cleanup_test_user_locked=0

cleanup() {
  set +e
  if [[ "$cleanup_test_user_locked" -eq 0 ]] && id "$TEST_OS_USER" >/dev/null 2>&1; then
    sudo -n userdel "$TEST_OS_USER" >/dev/null 2>&1 || true
    sudo -n rm -rf "$TEST_OS_HOME" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Make sure the test user exists. If it already exists, we won't delete it
# at the end (it could belong to a manual run); just clean up the home tree.
if id "$TEST_OS_USER" >/dev/null 2>&1; then
  cleanup_test_user_locked=1
  log "reusing existing OS user $TEST_OS_USER"
else
  sudo -n useradd --system --home-dir "$TEST_OS_HOME" --shell /usr/sbin/nologin "$TEST_OS_USER" >/dev/null \
    || die "useradd failed for $TEST_OS_USER"
fi
sudo -n mkdir -p "$TEST_OS_HOME"
sudo -n chown "$TEST_OS_USER:$TEST_OS_USER" "$TEST_OS_HOME"
sudo -n chmod 0700 "$TEST_OS_HOME"

# Write a minimal roster entry so bridge_linux_prepare_agent_isolation finds
# the agent. This emulates what bridge_migration_isolate would have written.
TEST_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$TEST_AGENT"
mkdir -p "$TEST_WORKDIR"
cat > "$BRIDGE_ROSTER_LOCAL_FILE" <<ROSTER
#!/usr/bin/env bash
bridge_add_agent_id_if_missing() { :; }
declare -gA BRIDGE_AGENT_ENGINE BRIDGE_AGENT_SESSION BRIDGE_AGENT_WORKDIR BRIDGE_AGENT_LAUNCH_CMD
declare -gA BRIDGE_AGENT_ISOLATION_MODE BRIDGE_AGENT_OS_USER
BRIDGE_AGENT_IDS=("$TEST_AGENT")
BRIDGE_AGENT_ENGINE[$TEST_AGENT]=claude
BRIDGE_AGENT_SESSION[$TEST_AGENT]=$TEST_AGENT
BRIDGE_AGENT_WORKDIR[$TEST_AGENT]=$TEST_WORKDIR
BRIDGE_AGENT_LAUNCH_CMD[$TEST_AGENT]='true'
BRIDGE_AGENT_ISOLATION_MODE[$TEST_AGENT]=linux-user
BRIDGE_AGENT_OS_USER[$TEST_AGENT]=$TEST_OS_USER
ROSTER

# Run the isolate prepare directly, in the same way bridge_migration_isolate
# does at the end of its first-time path.
log "running bridge_linux_prepare_agent_isolation"
# shellcheck source=../bridge-lib.sh
source "$REPO_ROOT/bridge-lib.sh"
bridge_load_roster
bridge_linux_prepare_agent_isolation "$TEST_AGENT" "$TEST_OS_USER" "$TEST_WORKDIR" "$(id -un)"

# Locate the gateway dirs the prepare function set up.
QG_ROOT="$(bridge_queue_gateway_root)"
QG_AGENT_DIR="$(bridge_queue_gateway_agent_dir "$TEST_AGENT")"
QG_REQUESTS="$(bridge_queue_gateway_requests_dir "$TEST_AGENT")"
QG_RESPONSES="$(bridge_queue_gateway_responses_dir "$TEST_AGENT")"

# Helper that asserts a getfacl line exists.
assert_acl_has() {
  local target="$1" expected="$2"
  sudo -n getfacl --no-effective "$target" 2>/dev/null | grep -Fq -- "$expected" \
    || die "expected ACL '$expected' on $target"
}
assert_acl_lacks() {
  local target="$1" forbidden="$2"
  if sudo -n getfacl --no-effective "$target" 2>/dev/null | grep -Fq -- "$forbidden"; then
    die "unexpected ACL '$forbidden' present on $target"
  fi
}

log "verifying queue-gateway root ACL shape"
assert_acl_has "$QG_ROOT" "user:$(id -un):r-x"
assert_acl_has "$QG_ROOT" "user:${TEST_OS_USER}:--x"

log "verifying per-agent dir ACL shape"
for path in "$QG_AGENT_DIR" "$QG_REQUESTS" "$QG_RESPONSES"; do
  assert_acl_has "$path" "user:${TEST_OS_USER}:rwx"
  assert_acl_has "$path" "user:$(id -un):rwx"
  assert_acl_has "$path" "default:user:${TEST_OS_USER}:rwx"
  assert_acl_has "$path" "default:user:$(id -un):rwx"
done

log "verifying isolated UID cannot enumerate the gateway root"
if sudo -n -u "$TEST_OS_USER" ls "$QG_ROOT" >/dev/null 2>&1; then
  die "isolated UID should not be able to ls $QG_ROOT"
fi

log "verifying isolated UID can write+read its own request path"
sudo -n -u "$TEST_OS_USER" bash -c "echo probe > '$QG_REQUESTS/probe.tmp' && cat '$QG_REQUESTS/probe.tmp' >/dev/null" \
  || die "isolated UID should be able to write+read its own requests/"
sudo -n -u "$TEST_OS_USER" rm -f "$QG_REQUESTS/probe.tmp"

log "running bridge-queue-gateway.py serve-once with a Python stub"
QSTUB="$TMP_ROOT/queue-stub.py"
cat > "$QSTUB" <<'PY'
#!/usr/bin/env python3
import sys
print("[stub] argv:", sys.argv[1:])
sys.exit(0)
PY
chmod +x "$QSTUB"

# Synthesize a minimal request file the gateway will consume.
REQ_ID="probe-$(date +%s)"
REQ_FILE="$QG_REQUESTS/${REQ_ID}.request.json"
cat > "$REQ_FILE" <<JSON
{"id": "$REQ_ID", "argv": ["inbox", "$TEST_AGENT"], "agent": "$TEST_AGENT"}
JSON

PROCESSED="$(python3 "$REPO_ROOT/bridge-queue-gateway.py" serve-once \
  --root "$QG_ROOT" \
  --queue-script "$QSTUB" \
  --max-requests 5 2>&1 || true)"
[[ "$PROCESSED" == *"1"* ]] || die "serve-once should have processed exactly 1 request, got: $PROCESSED"
[[ ! -e "$REQ_FILE" ]] || die "serve-once should have consumed $REQ_FILE"
RESP_FILE="$QG_RESPONSES/${REQ_ID}.json"
[[ -f "$RESP_FILE" ]] || die "expected serve-once to write response file at $RESP_FILE"

log "running bridge_migration_unisolate to verify the strip path"
# shellcheck source=../lib/bridge-migration.sh
source "$REPO_ROOT/lib/bridge-migration.sh"
bridge_migration_unisolate "$TEST_AGENT" 0

log "verifying gateway root has no leftover entries for the test os_user"
assert_acl_lacks "$QG_ROOT" "user:${TEST_OS_USER}:"
assert_acl_lacks "$QG_ROOT" "default:user:${TEST_OS_USER}:"
assert_acl_has "$QG_ROOT" "user:$(id -un):r-x"

log "verifying per-agent dir has no leftover entries for the test os_user"
for path in "$QG_AGENT_DIR" "$QG_REQUESTS" "$QG_RESPONSES"; do
  [[ -d "$path" ]] || continue
  assert_acl_lacks "$path" "user:${TEST_OS_USER}:"
  assert_acl_lacks "$path" "default:user:${TEST_OS_USER}:"
done

log "isolation queue-gateway ACL test passed"
