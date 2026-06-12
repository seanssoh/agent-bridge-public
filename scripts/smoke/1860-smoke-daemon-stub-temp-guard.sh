#!/usr/bin/env bash
# scripts/smoke/1860-smoke-daemon-stub-temp-guard.sh — issue #1860.
#
# Pins the defence-in-depth added after a daemon/watchdog-supervision smoke
# overwrote the LIVE ~/.agent-bridge/bridge-daemon.sh with a 29-byte
# `#!/usr/bin/env bash` + `sleep 60` stub even under an isolated BRIDGE_HOME,
# silently killing the production daemon for ~4h. Two independent teeth:
#
#   T1 — scripts/smoke/lib.sh:smoke_assert_path_in_temp / smoke_write_runtime_stub
#        REFUSE to write a stub to a path outside $SMOKE_TMP_ROOT / $BRIDGE_HOME
#        (a sentinel "live" bridge-daemon.sh stays byte-for-byte intact), and
#        ACCEPT a temp-rooted write (the stub lands under SMOKE_TMP_ROOT).
#
#   T2 — bridge-watchdog-silence.py _default_daemon_script() resolves
#        DAEMON_SCRIPT strictly INSIDE an explicitly-set BRIDGE_HOME and never
#        falls through to the live ~/.agent-bridge/bridge-daemon.sh, even when
#        the in-home daemon script does not exist yet. The pre-fix behaviour
#        (continue to the ~/.agent-bridge fallback) is the cross-home bridge
#        that let a temp-home watchdog drive a restart against the live daemon.
#
# Footgun #11 self-audit: no <<EOF/<<'PY' heredoc-stdin captured into $().
# The python probe is written to a file and run with file-as-argv.

set -uo pipefail

SMOKE_NAME="1860-smoke-daemon-stub-temp-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
smoke_require_cmd python3

WATCHDOG_SCRIPT="$REPO_ROOT/bridge-watchdog-silence.py"
smoke_assert_file_exists "$WATCHDOG_SCRIPT" "watchdog source"

STUB_CONTENT='#!/usr/bin/env bash
sleep 60'

# ---------------------------------------------------------------------------
# T1a — the guard REFUSES a write to a fake "live" path outside the temp root.
# ---------------------------------------------------------------------------
# Build a fake "live" home under a SEPARATE mktemp tree that is NOT under
# SMOKE_TMP_ROOT or BRIDGE_HOME, seed a sentinel bridge-daemon.sh, and assert
# the guarded writer refuses to clobber it.
smoke_log "T1a: smoke_write_runtime_stub refuses a target outside the temp root"
FAKE_LIVE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agb-1860-fakelive.XXXXXX")"
FAKE_LIVE_ROOT="$(cd -P "$FAKE_LIVE_ROOT" && pwd -P)"
FAKE_LIVE_DAEMON="$FAKE_LIVE_ROOT/.agent-bridge/bridge-daemon.sh"
mkdir -p "$(dirname "$FAKE_LIVE_DAEMON")"
SENTINEL='# SENTINEL-LIVE-DAEMON-DO-NOT-OVERWRITE'
printf '%s\n' "$SENTINEL" >"$FAKE_LIVE_DAEMON"
SENTINEL_BEFORE="$(cat "$FAKE_LIVE_DAEMON")"

# The guard calls smoke_fail (which `exit 1`s) on refusal, so invoke it in a
# subshell and assert the non-zero exit + that the sentinel survived.
if ( smoke_write_runtime_stub "$FAKE_LIVE_DAEMON" "$STUB_CONTENT" ) >/dev/null 2>&1; then
  rm -rf "$FAKE_LIVE_ROOT" 2>/dev/null || true
  smoke_fail "T1a: smoke_write_runtime_stub wrote OUTSIDE the temp root (the #1860 guard failed to fire)"
fi
SENTINEL_AFTER="$(cat "$FAKE_LIVE_DAEMON" 2>/dev/null || true)"
if [[ "$SENTINEL_AFTER" != "$SENTINEL_BEFORE" ]]; then
  rm -rf "$FAKE_LIVE_ROOT" 2>/dev/null || true
  smoke_fail "T1a: the fake-live bridge-daemon.sh was mutated despite the guard (got: $SENTINEL_AFTER)"
fi
rm -rf "$FAKE_LIVE_ROOT" 2>/dev/null || true
smoke_log "T1a PASS — guard refused the out-of-temp write, sentinel intact"

# ---------------------------------------------------------------------------
# T1b — the guard ACCEPTS a temp-rooted write (the legitimate path).
# ---------------------------------------------------------------------------
smoke_log "T1b: smoke_write_runtime_stub accepts a target under BRIDGE_HOME"
TEMP_DAEMON="$BRIDGE_HOME/bridge-daemon.sh"
smoke_write_runtime_stub "$TEMP_DAEMON" "$STUB_CONTENT"
smoke_assert_file_exists "$TEMP_DAEMON" "T1b temp-rooted stub written"
if [[ ! -x "$TEMP_DAEMON" ]]; then
  smoke_fail "T1b: temp-rooted stub was written but not made executable"
fi
smoke_assert_eq "$STUB_CONTENT" "$(cat "$TEMP_DAEMON")" "T1b stub content"
smoke_log "T1b PASS — temp-rooted write accepted"

# ---------------------------------------------------------------------------
# T2 — _default_daemon_script() never resolves to the live install when
#      BRIDGE_HOME is set (even if BRIDGE_HOME/bridge-daemon.sh is absent).
# ---------------------------------------------------------------------------
smoke_log "T2: watchdog _default_daemon_script() pins inside an explicit BRIDGE_HOME"
T2_PROBE="$SMOKE_TMP_ROOT/t2-resolver.py"
T2_FAKE_HOME="$SMOKE_TMP_ROOT/fake-os-home"
T2_FAKE_LIVE="$T2_FAKE_HOME/.agent-bridge/bridge-daemon.sh"
mkdir -p "$(dirname "$T2_FAKE_LIVE")"
printf '%s\n' '# SENTINEL-FAKE-LIVE-DAEMON' >"$T2_FAKE_LIVE"

# Isolated BRIDGE_HOME that deliberately has NO bridge-daemon.sh in it — the
# exact pre-condition that triggered the live fallback before the #1860 fix.
T2_ISO_HOME="$SMOKE_TMP_ROOT/iso-home-no-daemon"
mkdir -p "$T2_ISO_HOME"

cat >"$T2_PROBE" <<PROBE
import importlib.util
import os
import sys
from pathlib import Path

# Point Path.home() at the fake OS home so the live ~/.agent-bridge fallback,
# if it ever fired, would resolve to the sentinel (never the operator's real
# install). HOME drives Path.home() on POSIX.
os.environ["HOME"] = "$T2_FAKE_HOME"
os.environ["BRIDGE_HOME"] = "$T2_ISO_HOME"
os.environ.pop("BRIDGE_DAEMON_SCRIPT", None)

spec = importlib.util.spec_from_file_location("bws", "$WATCHDOG_SCRIPT")
mod = importlib.util.module_from_spec(spec)
sys.modules["bws"] = mod
spec.loader.exec_module(mod)

resolved = Path(mod.DAEMON_SCRIPT)
expected = Path("$T2_ISO_HOME") / "bridge-daemon.sh"
fake_live = Path("$T2_FAKE_LIVE")

errors = []
if resolved != expected:
    errors.append(f"  DAEMON_SCRIPT={resolved!r}, expected in-home {expected!r}")
if resolved == fake_live:
    errors.append(f"  DAEMON_SCRIPT resolved to the live ~/.agent-bridge fallback {fake_live!r} (cross-home leak)")

if errors:
    print("FAIL")
    for e in errors:
        print(e)
    sys.exit(1)
print("PASS")
PROBE

T2_OUT="$(python3 "$T2_PROBE" 2>&1)"
T2_RC=$?
if (( T2_RC != 0 )); then
  smoke_log "T2 output:"; printf '%s\n' "$T2_OUT"
  smoke_fail "T2: _default_daemon_script() resolved outside the explicit BRIDGE_HOME (cross-home #1860 regression)"
fi
# Sentinel fake-live daemon must be untouched (resolution is read-only, but
# assert anyway — defence-in-depth for the whole class).
if [[ "$(cat "$T2_FAKE_LIVE")" != '# SENTINEL-FAKE-LIVE-DAEMON' ]]; then
  smoke_fail "T2: the fake-live bridge-daemon.sh was mutated during resolver import"
fi
smoke_log "T2 PASS — resolver pinned inside BRIDGE_HOME, live fallback never reached"

smoke_log "PASS — #1860 smoke daemon-stub temp guard + watchdog cross-home resolution pinned"
exit 0
