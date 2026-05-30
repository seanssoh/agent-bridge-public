#!/usr/bin/env bash
# Regression smoke — bridge-watchdog-silence.py must (a) classify resolver
# `bridge_die` stderr into the three known v0.8.0 die paths, (b) preserve
# the full multi-line stderr block when the `daemon stop`/`start` call
# fails, and (c) persist the classifier + stderr preview into
# `state/silence-watchdog.json` so post-mortem readers can grep one file
# instead of re-running a wedged invocation.
#
# Background (issue #946 L3, 2026-05-17):
#   The silence watchdog's previous output capture kept only the last
#   line of stderr (`output.strip().splitlines()[-1]`). Every wedge
#   from 2026-05-15 onward then surfaced the same generic ACL-removal
#   sentence — `marker-legacy` / `markerless-existing` /
#   `markerless-fresh-candidate` were indistinguishable in the audit
#   trail. L3 fixes diagnostics only; the wedge itself is closed by L1
#   (BRIDGE_SCRIPT_DIR validation) + L2 (tick subshell guards).
#
# Coverage:
#   C1 — `_classify_resolver_die` returns the expected token for each of
#        the three known stderr shapes, the ambiguous ACL-only shape, and
#        the unrelated-stderr/empty negatives. Catches future re-ordering
#        of the substring checks.
#   C2 — `attempt_restart` writes `state/silence-watchdog.json` with the
#        `resolver_die` + `stderr_preview` keys populated when the stop
#        helper returns non-zero. Asserts the post-mortem state file
#        carries the disambiguator. Drives the call by replacing
#        DAEMON_SCRIPT with a tiny shim that emits the
#        `markerless(existing-install)` die shape on stderr.
#   C3 — the multi-line stderr block is preserved end-to-end (the
#        original truncation only kept the last line; this asserts the
#        first non-trivial line of the die message survives into the
#        preview).

set -uo pipefail

SMOKE_NAME="watchdog-silence-stderr-capture"
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

# Strip operator-shell overrides that would steer the watchdog module's
# import-time defaults outside this smoke's temp bridge home. The module
# resolves COOLDOWN_FILE / PIDLOCK from these env vars at import; an
# inherited override would mismatch our state-file assertions AND
# (worse) write into the operator's live state. Defence-in-depth alongside
# the module-resolved path checks below. Refs PR #950 codex review P2.
unset BRIDGE_DAEMON_SILENCE_COOLDOWN_FILE BRIDGE_DAEMON_SILENCE_PIDLOCK

WATCHDOG_SCRIPT="$REPO_ROOT/bridge-watchdog-silence.py"
smoke_assert_file_exists "$WATCHDOG_SCRIPT" "watchdog source"

# ---------------------------------------------------------------------------
# C1 — _classify_resolver_die token map
# ---------------------------------------------------------------------------
# Drive the helper directly via a sibling python script (no heredoc-stdin
# — keep the file-as-argv contract from lib/upgrade-helpers/ + footgun
# #11). The probe loads the watchdog as a module so we exercise the
# *real* function, not a paraphrase.
smoke_log "C1: _classify_resolver_die maps stderr shapes to known tokens"
c1_probe="$SMOKE_TMP_ROOT/c1-classify.py"
cat >"$c1_probe" <<PROBE
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("bws", "$WATCHDOG_SCRIPT")
mod = importlib.util.module_from_spec(spec)
sys.modules["bws"] = mod
spec.loader.exec_module(mod)
classify = mod._classify_resolver_die

cases = [
    # (label, stderr_shape, expected_substring)
    (
        "marker-legacy",
        "Agent Bridge v0.8.0 requires isolation-v2.\n"
        "  current_layout=legacy\n"
        "  marker=/some/path\n"
        "  background: ACL-based isolation (v1) was removed.",
        "marker-legacy",
    ),
    (
        "markerless-existing",
        "Agent Bridge v0.8.0 requires isolation-v2.\n"
        "  current_layout=markerless(existing-install)\n"
        "  background: ACL-based isolation (v1) was removed.",
        "markerless-existing",
    ),
    (
        "markerless-fresh-candidate",
        "Agent Bridge v0.8.0 requires isolation-v2.\n"
        "  current_layout=markerless(fresh-install-candidate)\n"
        "  background: ACL-based isolation (v1) was removed.",
        "markerless-fresh-candidate",
    ),
    (
        "markerless-invalid-fallback (alias of fresh-candidate)",
        "Agent Bridge v0.8.0 requires isolation-v2.\n"
        "  current_layout=markerless(invalid-marker(fallback))\n"
        "  background: ACL-based isolation (v1) was removed.",
        "markerless-fresh-candidate",
    ),
    (
        "marker-v1 alias",
        "Agent Bridge v0.8.0 requires isolation-v2.\n"
        "  current_layout=v1\n"
        "  background: ACL-based isolation (v1) was removed.",
        "marker-legacy",
    ),
    (
        "uncatalogued v0.8.0 hard-cut",
        "  background: ACL-based isolation (v1) was removed.\n"
        "  see docs/isolation-migration-guide.md",
        "isolation-hard-cut",
    ),
    ("unrelated stderr", "permission denied: /tmp/foo", "other"),
    ("empty stderr", "", "other"),
]

failures = []
for label, shape, expected in cases:
    got = classify(shape)
    if expected not in got:
        failures.append(f"  case {label!r}: expected substring {expected!r}, got {got!r}")

if failures:
    print("FAIL")
    for f in failures:
        print(f)
    sys.exit(1)

print("PASS")
PROBE

c1_out="$(python3 "$c1_probe" 2>&1)"
c1_rc=$?
if (( c1_rc != 0 )); then
  smoke_log "C1 output:"; printf '%s\n' "$c1_out"
  smoke_fail "C1: classifier did not match expected token map"
fi
smoke_log "C1 PASS"

# ---------------------------------------------------------------------------
# C2 — attempt_restart persists resolver_die + stderr_preview to state JSON
# ---------------------------------------------------------------------------
# Drive `attempt_restart` directly with a fake DAEMON_SCRIPT that emits a
# multi-line v0.8.0 die message on stderr and exits non-zero. We don't
# need a real audit log or live daemon — the test asserts on the cooldown
# state file, which is the post-mortem oracle.
smoke_log "C2: attempt_restart persists resolver_die + stderr_preview into silence-watchdog.json"

# Fake bridge-daemon.sh — emits the markerless(existing-install) die
# shape on stderr and exits 1. Mirrors the operator-host wedge shape
# (lib/bridge-layout-resolver.sh:406-410).
fake_daemon="$SMOKE_TMP_ROOT/fake-bridge-daemon.sh"
cat >"$fake_daemon" <<'FAKE'
#!/usr/bin/env bash
# Mimic `bridge_die` from lib/bridge-core.sh: write to stderr, exit 1.
cat >&2 <<'DIE'
Agent Bridge v0.8.0 requires isolation-v2 (POSIX group + setgid).
  current_layout=markerless(existing-install)
  remediation: run `agent-bridge upgrade --apply` to migrate this install to v2, or roll back to v0.7.x.
  background: ACL-based isolation (v1) was removed in v0.8.0. See https://github.com/seanssoh/agent-bridge-public/blob/main/docs/isolation-migration-guide.md for details.
DIE
exit 1
FAKE
chmod +x "$fake_daemon"

c2_probe="$SMOKE_TMP_ROOT/c2-restart.py"
cat >"$c2_probe" <<PROBE
import importlib.util
import json
import os
import sys
from pathlib import Path

# Pin BRIDGE_DAEMON_SCRIPT to the fake before loading the module so the
# resolver picks it up at import time (it reads the env var on first
# import of the module).
os.environ["BRIDGE_DAEMON_SCRIPT"] = "$fake_daemon"
# BRIDGE_HOME and friends are already exported by smoke_setup_bridge_home.

spec = importlib.util.spec_from_file_location("bws", "$WATCHDOG_SCRIPT")
mod = importlib.util.module_from_spec(spec)
sys.modules["bws"] = mod
spec.loader.exec_module(mod)

# Sanity: confirm the fake is wired.
assert str(mod.DAEMON_SCRIPT) == "$fake_daemon", \
    f"DAEMON_SCRIPT resolution drifted: got {mod.DAEMON_SCRIPT!r}"

# Drive attempt_restart with a fixed reason payload. The fake stops with
# rc=1 -> stop_failed branch -> writes silence-watchdog.json detail with
# resolver_die populated.
mod.attempt_restart({"age_seconds": 9999, "threshold_seconds": 600,
                     "last_tick_ts": "2026-05-17T00:00:00+00:00",
                     "daemon_pid": 1})

# Use the module's resolved COOLDOWN_FILE rather than re-deriving from
# BRIDGE_STATE_DIR. The watchdog honors BRIDGE_DAEMON_SILENCE_COOLDOWN_FILE
# at import time, so a shell that inherits that override would mismatch a
# hard-coded path here and (worse) the write could land outside the
# smoke's temp bridge home. Asserting on mod.COOLDOWN_FILE pins the
# isolation invariant. Refs PR #950 codex review P2.
state_path = Path(mod.COOLDOWN_FILE)
if not state_path.exists():
    print(f"FAIL: state file not written at {state_path}")
    sys.exit(1)

payload = json.loads(state_path.read_text("utf-8"))
detail = payload.get("detail") or {}

errors = []
if detail.get("outcome") != "stop_failed":
    errors.append(f"  outcome: expected 'stop_failed', got {detail.get('outcome')!r}")
if detail.get("stop_exit") != 1:
    errors.append(f"  stop_exit: expected 1, got {detail.get('stop_exit')!r}")
resolver_die = detail.get("resolver_die", "")
if "markerless-existing" not in resolver_die:
    errors.append(f"  resolver_die: expected 'markerless-existing' substring, got {resolver_die!r}")
stderr_preview = detail.get("stderr_preview", "")
if "current_layout=markerless(existing-install)" not in stderr_preview:
    errors.append(f"  stderr_preview missing current_layout discriminator: got {stderr_preview!r}")
if "ACL-based isolation" not in stderr_preview:
    errors.append(f"  stderr_preview missing ACL background line: got {stderr_preview!r}")
# Newlines should be escaped (single-line for grep-friendliness).
if "\n" in stderr_preview:
    errors.append(f"  stderr_preview should be single-line (newlines as \\\\n): got {stderr_preview!r}")

if errors:
    print("FAIL")
    for e in errors:
        print(e)
    print(f"  full detail: {detail!r}")
    sys.exit(1)

print("PASS")
print(f"  resolver_die={resolver_die!r}")
print(f"  stderr_preview_len={len(stderr_preview)}")
PROBE

c2_out="$(python3 "$c2_probe" 2>&1)"
c2_rc=$?
if (( c2_rc != 0 )); then
  smoke_log "C2 output:"; printf '%s\n' "$c2_out"
  smoke_fail "C2: attempt_restart did not persist resolver_die + stderr_preview"
fi
smoke_log "C2 PASS"
printf '%s\n' "$c2_out" | sed 's/^/  /'

# ---------------------------------------------------------------------------
# C3 — full stderr block preserved end-to-end (no last-line truncation)
# ---------------------------------------------------------------------------
# The original bug was that only the *last* line of stderr survived, which
# always happened to be the ACL background line. Assert that the FIRST
# non-trivial line of the multi-line die message ("Agent Bridge v0.8.0
# requires isolation-v2") also reaches the preview — that's the
# regression catch for the truncation behaviour.
smoke_log "C3: full multi-line stderr survives end-to-end (was truncated to last line)"
state_path="$BRIDGE_STATE_DIR/silence-watchdog.json"
if ! python3 - "$state_path" >/dev/null 2>"$SMOKE_TMP_ROOT/c3.err" <<'CHECK'
import json
import sys

state = json.loads(open(sys.argv[1], "r", encoding="utf-8").read())
preview = (state.get("detail") or {}).get("stderr_preview", "")
expected_first_line_marker = "Agent Bridge v0.8.0 requires isolation-v2"
if expected_first_line_marker not in preview:
    raise SystemExit(f"first-line marker missing from preview: {preview!r}")
CHECK
then
  smoke_log "C3 check stderr:"; cat "$SMOKE_TMP_ROOT/c3.err"
  smoke_fail "C3: stderr_preview lost the first non-trivial line of the die message (regression to last-line truncation)"
fi
smoke_log "C3 PASS"

smoke_log "PASS — bridge-watchdog-silence.py captures + classifies + persists resolver die diagnostics (#946 L3)"
exit 0
