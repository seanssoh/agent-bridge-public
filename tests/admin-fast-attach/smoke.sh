#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf '[admin-fast-attach][error] %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_no_marker() {
  local marker="$1"
  [[ ! -e "$marker" ]] || fail "unexpected marker exists: $marker"
}

HARNESS="$TMP_ROOT/harness"
WORKDIR="$TMP_ROOT/patch-workdir"
MARKER_DIR="$TMP_ROOT/markers"
mkdir -p "$HARNESS" "$WORKDIR" "$MARKER_DIR"
cp "$REPO_ROOT/agent-bridge" "$HARNESS/agent-bridge"

cat >"$HARNESS/bridge-lib.sh" <<EOF
#!/usr/bin/env bash
BRIDGE_BASH_BIN="${BASH}"
BRIDGE_TEST_WORKDIR="$WORKDIR"
BRIDGE_TEST_MARKER_DIR="$MARKER_DIR"
export BRIDGE_BASH_BIN BRIDGE_TEST_WORKDIR BRIDGE_TEST_MARKER_DIR
bridge_load_roster() { :; }
bridge_require_admin_agent() { printf '%s\n' patch; }
bridge_agent_engine() { printf '%s\n' claude; }
bridge_agent_workdir() { printf '%s\n' "\$BRIDGE_TEST_WORKDIR"; }
bridge_agent_session() { printf '%s\n' patch; }
bridge_tmux_session_exists() { [[ "\$1" == patch ]]; }
bridge_attach_tmux_session() { printf 'attach:%s\n' "\$1"; }
bridge_validate_agent_name() { return 0; }
bridge_agent_exists() { [[ "\$1" == patch ]]; }
bridge_agent_source() { printf '%s\n' static; }
bridge_die() { printf 'die:%s\n' "\$*" >&2; exit 1; }
EOF

cat >"$HARNESS/bridge-daemon.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$BRIDGE_TEST_MARKER_DIR/daemon"
EOF

cat >"$HARNESS/bridge-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$BRIDGE_TEST_MARKER_DIR/start"
EOF

cat >"$HARNESS/bridge-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$BRIDGE_TEST_MARKER_DIR/bridge-agent"
EOF

chmod +x "$HARNESS/agent-bridge" "$HARNESS/bridge-daemon.sh" "$HARNESS/bridge-start.sh" "$HARNESS/bridge-agent.sh"

OUT="$("$HARNESS/agent-bridge" admin --no-attach 2>&1)"
assert_contains "$OUT" "세션 'patch'이 이미 실행 중입니다."
assert_no_marker "$MARKER_DIR/daemon"
assert_no_marker "$MARKER_DIR/start"

OUT="$("$HARNESS/agent-bridge" admin 2>&1)"
assert_contains "$OUT" "세션 'patch'이 이미 실행 중입니다."
assert_contains "$OUT" "attach:patch"
assert_no_marker "$MARKER_DIR/daemon"
assert_no_marker "$MARKER_DIR/start"

OUT="$("$HARNESS/agent-bridge" admin --replace --no-attach 2>&1 || true)"
[[ -e "$MARKER_DIR/daemon" ]] || fail "--replace should bypass fast attach and reach daemon ensure"
[[ -e "$MARKER_DIR/start" ]] || fail "--replace should bypass fast attach and reach bridge-start"

rm -f "$MARKER_DIR/daemon" "$MARKER_DIR/start"
OUT="$("$HARNESS/agent-bridge" admin --safe-mode --no-attach --dry-run 2>&1 || true)"
assert_no_marker "$MARKER_DIR/daemon"
assert_no_marker "$MARKER_DIR/start"
[[ -e "$MARKER_DIR/bridge-agent" ]] || fail "--safe-mode should route to bridge-agent safe-mode"

printf '[admin-fast-attach] ok\n'
