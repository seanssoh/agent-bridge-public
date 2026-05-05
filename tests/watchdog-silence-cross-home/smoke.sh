#!/usr/bin/env bash
# watchdog-silence cross-home smoke — issue #591.
#
# Verifies that bridge-watchdog-silence.py refuses to run when
# BRIDGE_DAEMON_PID_FILE resolves outside BRIDGE_HOME, while still accepting
# same-home, default, and symlinked-home configurations.
#
# Each case runs in an isolated mktemp BRIDGE_HOME — never touches the live
# install. The actual assertions live in test_cross_home.py alongside this
# wrapper so the Python validator can be exercised directly.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"
TEST_PY="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/test_cross_home.py"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi
if [[ ! -f "$TEST_PY" ]]; then
  printf '[smoke][error] test_cross_home.py missing alongside smoke.sh\n' >&2
  exit 2
fi
if [[ ! -f "$REPO_ROOT/bridge-watchdog-silence.py" ]]; then
  printf '[smoke][error] bridge-watchdog-silence.py not found at repo root\n' >&2
  exit 2
fi

# Scrub any inherited env so the "defaults accepted" case actually tests
# defaults rather than the operator's live install paths.
unset BRIDGE_HOME BRIDGE_DAEMON_PID_FILE BRIDGE_STATE_DIR BRIDGE_LOG_DIR BRIDGE_AUDIT_LOG

exec "$PYTHON" "$TEST_PY"
