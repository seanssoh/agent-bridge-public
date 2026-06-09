#!/usr/bin/env bash
#
# Issue #1652 — queue-gateway socket listener crash-loop regression smoke.
#
# Two compounding v0.16.0 bugs crash-looped the queue-gateway socket
# listener (~every 50-90s) on iso/socket installs:
#
#   Bug 1 (bridge-daemon.sh: clean_stale): a single transient connect-probe
#     miss against a LIVE listener caused `rm -f` of its bound socket. The
#     fix requires N *consecutive* probe failures before removal
#     (bridge_queue_gateway_socket_probe_persistently_dead).
#
#   Bug 2 (bridge-queue-gateway.py: _set_socket_group_mode /
#     _refresh_socket_perms): an unguarded os.chmod/os.chown on a missing
#     socket raised FileNotFoundError into the accept loop and crashed the
#     listener. The fix catches it and returns False (degrade, not crash).
#
#   Bug 3 (bridge-queue-gateway.py: _recv_json / _handle_socket_request):
#     the liveness connect-probe connects + closes with no payload, which
#     was logged per probe as `deny invalid_payload` + a BrokenPipeError
#     `send_failed`. The fix treats an empty recv as an expected _ProbeClose
#     (no deny log, no response attempt).
#
# This smoke proves all three. Parts A/B are Python-level and run on every
# platform; Part C needs a real bound SEQPACKET socket and is Linux-only
# (the same fail-closed gate as the other queue-gateway socket smokes).

set -euo pipefail

SMOKE_NAME="1652-queue-gateway-crashloop"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

# Bug 2: a missing socket path must NOT crash the perms refresh. The
# helpers must return False (degrade) instead of raising FileNotFoundError.
gateway_missing_socket_perms_no_crash() {
  local out
  out="$(
    python3 - "$SMOKE_REPO_ROOT" <<'PY' 2>&1 || true
import importlib.util
import sys
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("bqg", repo / "bridge-queue-gateway.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

missing = repo / "does-not-exist" / "queue-gateway.sock"

# _set_socket_group_mode on a missing path must return False, not raise.
# live=False so a missing ab-shared group degrades to the 0600 branch
# rather than SystemExit; either branch must still not raise on a missing
# path.
try:
    rv = mod._set_socket_group_mode(missing, live=False)
except FileNotFoundError:
    print("FAIL: _set_socket_group_mode raised FileNotFoundError")
    raise SystemExit(0)
if rv is not False:
    print(f"FAIL: _set_socket_group_mode returned {rv!r}, expected False")
    raise SystemExit(0)

# _refresh_socket_perms must propagate the False (degrade) without raising.
try:
    rv2 = mod._refresh_socket_perms(missing, {}, repo, live=False)
except FileNotFoundError:
    print("FAIL: _refresh_socket_perms raised FileNotFoundError")
    raise SystemExit(0)
if rv2 is not False:
    print(f"FAIL: _refresh_socket_perms returned {rv2!r}, expected False")
    raise SystemExit(0)

print("ok-missing-socket-degrades")
PY
  )"
  smoke_assert_contains "$out" "ok-missing-socket-degrades" \
    "bug2: missing-socket perms refresh degrades instead of crashing the listener"
}

# Bug 3: an empty recv (connect-probe / peer closed before send) must be a
# distinct _ProbeClose, NOT a malformed-payload ValueError. _ProbeClose must
# not be a ValueError subclass (so the deny/invalid_payload path is skipped).
gateway_probe_close_is_quiet() {
  local out
  out="$(
    python3 - "$SMOKE_REPO_ROOT" <<'PY' 2>&1 || true
import importlib.util
import socket
import sys
from pathlib import Path

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("bqg", repo / "bridge-queue-gateway.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

if issubclass(mod._ProbeClose, ValueError):
    print("FAIL: _ProbeClose must not subclass ValueError (would re-enter invalid_payload)")
    raise SystemExit(0)

# Drive _recv_json with a socketpair where the writer closes without
# sending anything — the reader's recv() returns b'' -> _ProbeClose.
a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
b.close()
try:
    mod._recv_json(a)
except mod._ProbeClose:
    print("ok-empty-recv-is-probeclose")
except ValueError as exc:
    print(f"FAIL: empty recv raised ValueError {exc!r}, expected _ProbeClose")
finally:
    a.close()
PY
  )"
  smoke_assert_contains "$out" "ok-empty-recv-is-probeclose" \
    "bug3: empty connect-probe recv is a quiet _ProbeClose, not invalid_payload"
}

# Bug 1: clean_stale must NOT rm a LIVE listener's socket on a transient
# probe miss. Spawn a real bound + accepting SEQPACKET listener, record its
# pid, and run clean_stale. The consecutive-probe gate must answer at least
# one probe and keep the socket. Then prove the false-positive case still
# works: an unbound socket + alive (unrelated) pid is still cleaned.
gateway_clean_stale_keeps_live_socket() {
  local pid_file socket_path sock_dir helper helper_out listener_pid

  # AF_UNIX sun_path is limited (~108 bytes); the deep SMOKE_TMP_ROOT mktemp
  # nesting can overflow it. Use a short dedicated socket dir under TMPDIR.
  sock_dir="$(mktemp -d "${TMPDIR:-/tmp}/agb1652.XXXXXX")"
  pid_file="$BRIDGE_STATE_DIR/queue-gateway-socket-1652.pid"
  socket_path="$sock_dir/gw.sock"
  mkdir -p "$BRIDGE_STATE_DIR"

  # A real listener: bind + listen + accept loop in a background process,
  # written to a file so its body is unambiguous under `set -e`. The accept()
  # flaps on a 1.0s timeout — exactly the window that produced the
  # transient-probe miss in the bug.
  cat >"$SMOKE_TMP_ROOT/live-listener.py" <<'PY'
import os
import socket
import sys
import time

path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.bind(path)
s.listen(64)
s.settimeout(1.0)
# Serve until the parent kills us. accept() flaps on the 1.0s timeout, which
# is exactly the window that produced the transient-probe miss in the bug.
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    try:
        conn, _ = s.accept()
    except (TimeoutError, socket.timeout):
        continue
    except OSError:
        break
    try:
        conn.close()
    except OSError:
        pass
PY
  python3 "$SMOKE_TMP_ROOT/live-listener.py" "$socket_path" >/dev/null 2>&1 &
  listener_pid="$!"
  printf '%s\n' "$listener_pid" >"$pid_file"

  # Wait for the listener to be bound + accepting before probing.
  local i
  for ((i = 0; i < 50; i++)); do
    if [[ -S "$socket_path" ]] \
        && python3 "$SMOKE_REPO_ROOT/lib/daemon-helpers/gateway-socket-connect-probe.py" "$socket_path" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  [[ -S "$socket_path" ]] || smoke_fail "bug1: pre-condition — live listener socket not bound"

  helper="$SMOKE_TMP_ROOT/clean-stale-live-driver.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nPID_FILE="$1"\nSOCKET_PATH="$2"\nSMOKE_REPO_ROOT="%s"\n' "$SMOKE_REPO_ROOT"
    # bridge_daemon_helper_python is used by connect_probe; stub it to call
    # the standalone helper directly so we do not source the whole daemon
    # (top-level command parsing).
    cat <<'BASH'
bridge_daemon_helper_python() {
  local helper_name="$1"; shift
  python3 "$SMOKE_REPO_ROOT/lib/daemon-helpers/${helper_name}.py" "$@"
}
BASH
    awk '/^bridge_queue_gateway_socket_pid_file\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_pid\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_connect_probe\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_probe_persistently_dead\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_clean_stale\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    cat <<'BASH'
bridge_queue_gateway_socket_pid_file() { printf "%s" "$PID_FILE"; }
bridge_queue_gateway_socket_path() { printf "%s" "$SOCKET_PATH"; }
# Bug 1: live listener + alive pid. clean_stale must NOT remove the bound,
# accepting socket — the consecutive-probe gate answers at least one probe.
bridge_queue_gateway_socket_clean_stale
if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "FAIL: clean_stale removed a LIVE listener socket"
  exit 1
fi
if [[ ! -f "$PID_FILE" ]]; then
  echo "FAIL: clean_stale removed a LIVE listener pid file"
  exit 1
fi
echo "ok-live-socket-kept"
BASH
  } >"$helper"
  chmod +x "$helper"
  helper_out="$(bash "$helper" "$pid_file" "$socket_path" 2>&1 || true)"
  smoke_assert_contains "$helper_out" "ok-live-socket-kept" \
    "bug1: clean_stale keeps a live listener socket through a transient probe flap"

  # The listener must still be alive + serving (clean_stale did not kill it).
  kill -0 "$listener_pid" 2>/dev/null \
    || smoke_fail "bug1: live listener was killed by clean_stale"
  [[ -S "$socket_path" ]] \
    || smoke_fail "bug1: live listener socket gone after clean_stale"

  kill "$listener_pid" >/dev/null 2>&1 || true
  wait "$listener_pid" >/dev/null 2>&1 || true
  rm -rf "$sock_dir" >/dev/null 2>&1 || true
}

# Bug 1 inverse: a genuinely-dead socket (unbound file + alive unrelated pid)
# must STILL be cleaned — the consecutive-probe gate fails all N attempts.
# This guards against the fix over-correcting into never-clean.
gateway_clean_stale_still_removes_dead_socket() {
  local pid_file socket_path sock_dir helper helper_out alive_pid

  # Short socket dir (AF_UNIX sun_path limit — see keeps-live-socket above).
  sock_dir="$(mktemp -d "${TMPDIR:-/tmp}/agb1652d.XXXXXX")"
  pid_file="$BRIDGE_STATE_DIR/queue-gateway-socket-1652-dead.pid"
  socket_path="$sock_dir/gw.sock"
  mkdir -p "$BRIDGE_STATE_DIR"

  # Alive but unrelated pid (the smoke runner), plus an unbound socket file.
  alive_pid="$$"
  printf '%s\n' "$alive_pid" >"$pid_file"
  python3 - "$socket_path" >/dev/null <<'PY'
import os, socket, sys
p = sys.argv[1]
try:
    os.unlink(p)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.bind(p)
s.close()
PY
  [[ -S "$socket_path" ]] || smoke_fail "bug1-inverse: pre-condition — unbound socket file should exist"

  helper="$SMOKE_TMP_ROOT/clean-stale-dead-driver.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nPID_FILE="$1"\nSOCKET_PATH="$2"\nSMOKE_REPO_ROOT="%s"\n' "$SMOKE_REPO_ROOT"
    cat <<'BASH'
bridge_daemon_helper_python() {
  local helper_name="$1"; shift
  python3 "$SMOKE_REPO_ROOT/lib/daemon-helpers/${helper_name}.py" "$@"
}
BASH
    awk '/^bridge_queue_gateway_socket_pid_file\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_pid\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_connect_probe\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_probe_persistently_dead\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    awk '/^bridge_queue_gateway_socket_clean_stale\(\) \{/,/^}$/' "$SMOKE_REPO_ROOT/bridge-daemon.sh"
    cat <<'BASH'
bridge_queue_gateway_socket_pid_file() { printf "%s" "$PID_FILE"; }
bridge_queue_gateway_socket_path() { printf "%s" "$SOCKET_PATH"; }
bridge_queue_gateway_socket_clean_stale
if [[ -e "$SOCKET_PATH" ]]; then
  echo "FAIL: clean_stale did not remove a genuinely-dead socket"
  exit 1
fi
if [[ -f "$PID_FILE" ]]; then
  echo "FAIL: clean_stale did not remove the stale pid file"
  exit 1
fi
echo "ok-dead-socket-removed"
BASH
  } >"$helper"
  chmod +x "$helper"
  helper_out="$(bash "$helper" "$pid_file" "$socket_path" 2>&1 || true)"
  smoke_assert_contains "$helper_out" "ok-dead-socket-removed" \
    "bug1-inverse: clean_stale still removes a genuinely-dead (unbound) socket"

  # The unrelated alive pid must survive (clean_stale must not signal it).
  kill -0 "$alive_pid" 2>/dev/null \
    || smoke_fail "bug1-inverse: clean_stale signaled an unrelated alive pid"
  rm -rf "$sock_dir" >/dev/null 2>&1 || true
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd awk
  smoke_setup_bridge_home "1652-queue-gateway-crashloop"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null

  # Parts A/B are Python-level and platform-independent.
  smoke_run "missing-socket perms refresh degrades (bug2)" gateway_missing_socket_perms_no_crash
  smoke_run "empty connect-probe recv is quiet (bug3)" gateway_probe_close_is_quiet

  # Part C needs a real bound SEQPACKET socket — Linux-only fail-closed gate.
  if smoke_is_linux; then
    smoke_run "clean_stale keeps a live listener socket (bug1)" gateway_clean_stale_keeps_live_socket
    smoke_run "clean_stale still removes a dead socket (bug1 inverse)" gateway_clean_stale_still_removes_dead_socket
  else
    smoke_skip "clean_stale keeps a live listener socket (bug1)" "non-Linux"
    smoke_skip "clean_stale still removes a dead socket (bug1 inverse)" "non-Linux"
  fi

  smoke_log "passed"
}

main "$@"
