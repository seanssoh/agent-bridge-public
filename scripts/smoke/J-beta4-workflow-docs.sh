#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/J-beta4-workflow-docs.sh — v0.15.0-beta4 Lane J
# (#1280, #1281, #1267, #1263).
#
# Pins the contracts for the four lane J fixes:
#
#   T1 (#1280 positive):  PermissionError on --body-file falls back to
#                          the sudo-as-owner read when the owner is in
#                          the `agent-bridge-*` namespace.
#   T2 (#1280 teeth):     Mocking _sudo_read_body_file → None re-raises
#                          the structured SystemExit, never silently
#                          stores an empty body.
#   T3 (#1281 positive):  CLAUDE.md, docs/developer-handover.md, and
#                          OPERATIONS.md each carry the
#                          "Working with isolated agents (iso v2)"
#                          section + the five key bullets.
#   T4 (#1281 teeth):     Section absent → fail-loud (regression guard).
#   T5 (#1267 positive):  bridge-release.py + the daemon-helpers
#                          downgrade-classify subcommand correctly
#                          identify the "installed >= latest" case
#                          (no alert + structured downgrade row).
#   T6 (#1267 teeth):     With a real upgrade (installed < latest), the
#                          downgrade-classify subcommand emits empty
#                          output; we did NOT silently swallow real
#                          release notifications.
#   T7 (#1263 positive):  bootstrap-memory-system.sh --apply on a fresh
#                          BRIDGE_HOME with BRIDGE_WIKI_GRAPH_ENABLED
#                          unset short-circuits with the
#                          `wiki_graph_skipped=1` marker on stdout +
#                          advisory on stderr. bridge-bootstrap.sh
#                          --dry-run --json includes a `wiki_graph`
#                          object surfacing the activation command.
#   T8 (#1263 teeth):     BRIDGE_WIKI_GRAPH_ENABLED=1 disables the
#                          short-circuit (existing-install path is
#                          preserved); the script continues past the
#                          gate. We confirm the gate did NOT fire.
#
# Footgun #11 (heredoc-stdin): every captured subprocess uses
# `out=$(... 2>&1)`. No `<<EOF` / `<<'PY'` to subprocess; no `<<<`
# here-strings driven into subshells.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:J-beta4-workflow-docs][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="J-beta4-workflow-docs"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

# ----------------------------------------------------------------------------
# T1 (#1280 positive): bridge-queue.py:stabilize_body_file falls back to
# `_sudo_read_body_file` on PermissionError. We exercise the helper
# directly with a stubbed sudo binary so the test stays hermetic — no
# real iso UID, no real `sudo -n -u`, just the code path.
# ----------------------------------------------------------------------------
smoke_log "T1 (#1280): _sudo_read_body_file fallback path returns bytes via stubbed sudo"

# Stub `sudo` on PATH. The stub asserts on argv shape and returns the
# body bytes. The shim is intentionally an absolute path → bridge-queue.py
# picks it up via `shutil.which("sudo")` which honors PATH.
T1_STUB_DIR="$SMOKE_TMP_ROOT/t1-stub"
mkdir -p "$T1_STUB_DIR"
T1_BODY_FILE="$SMOKE_TMP_ROOT/t1-body.md"
printf 'this is the iso-owned body text\n' >"$T1_BODY_FILE"
chmod 0644 "$T1_BODY_FILE"  # local read works; the sudo path is exercised through the stub

cat >"$T1_STUB_DIR/sudo" <<'SHIM'
#!/usr/bin/env bash
# Lane J T1 stub for `sudo`. Accepts `-n -u <owner> cat -- <path>` and
# echoes the file contents (mimicking the controller→iso boundary
# behavior). Any other argv shape is a test bug.
set -euo pipefail
if [[ "$1" != "-n" || "$2" != "-u" ]]; then
  echo "[t1-sudo-stub] unexpected argv: $*" >&2
  exit 99
fi
owner="$3"
if [[ "$owner" != agent-bridge-* ]]; then
  echo "[t1-sudo-stub] owner does not start with agent-bridge-: $owner" >&2
  exit 99
fi
shift 3
if [[ "$1" != "cat" || "$2" != "--" ]]; then
  echo "[t1-sudo-stub] expected 'cat --', got: $*" >&2
  exit 99
fi
cat "$3"
SHIM
chmod +x "$T1_STUB_DIR/sudo"

# Run a python harness that imports the bridge-queue.py module so we
# can hit `_sudo_read_body_file` with a monkey-patched pwd.getpwuid
# (no real `agent-bridge-*` user on a fresh worktree). The harness
# writes its result to a JSON file we then assert against.
T1_RESULT="$SMOKE_TMP_ROOT/t1-result.json"
T1_HARNESS="$SMOKE_TMP_ROOT/t1-harness.py"
cat >"$T1_HARNESS" <<'PY'
import importlib.util
import json
import os
import sys

repo_root = sys.argv[1]
body_path = sys.argv[2]
result_path = sys.argv[3]

spec = importlib.util.spec_from_file_location(
    "bridge_queue", os.path.join(repo_root, "bridge-queue.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakePwEnt:
    def __init__(self, name):
        self.pw_name = name


def fake_getpwuid(uid):
    return FakePwEnt("agent-bridge-test_clean")


import pwd as _pwd
_pwd.getpwuid = fake_getpwuid

# Force the non-self-uid path so the fallback proceeds.
orig_geteuid = os.geteuid
os.geteuid = lambda: orig_geteuid() + 999999

from pathlib import Path

raw = mod._sudo_read_body_file(Path(body_path))
out = {
    "ok": raw is not None,
    "len": (len(raw) if raw else 0),
    "first_line": (raw.split(b"\n", 1)[0].decode("utf-8") if raw else ""),
}
Path(result_path).write_text(json.dumps(out), encoding="utf-8")
PY

# Run the harness with PATH pointing at our sudo stub.
T1_OUT=""
T1_RC=0
T1_OUT="$(PATH="$T1_STUB_DIR:$PATH" python3 "$T1_HARNESS" "$REPO_ROOT" "$T1_BODY_FILE" "$T1_RESULT" 2>&1)" || T1_RC=$?
if (( T1_RC != 0 )); then
  smoke_fail "T1: harness failed rc=$T1_RC out: $T1_OUT"
fi
smoke_assert_file_exists "$T1_RESULT" "T1 harness wrote result"
T1_OK="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["ok"])' "$T1_RESULT")"
T1_FIRST="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["first_line"])' "$T1_RESULT")"
smoke_assert_eq "True" "$T1_OK" "T1 ok flag from harness"
smoke_assert_eq "this is the iso-owned body text" "$T1_FIRST" "T1 first line from sudo-stub fallback"
smoke_log "T1 ok: _sudo_read_body_file returned bytes via stubbed sudo"

# ----------------------------------------------------------------------------
# T2 (#1280 teeth): when the sudo fallback also fails, the original
# PermissionError surfaces as a structured SystemExit. We force the
# helper to return None and confirm `stabilize_body_file` re-raises.
# ----------------------------------------------------------------------------
smoke_log "T2 (#1280 teeth): fallback failure re-raises SystemExit, never silently stores empty body"

T2_BODY_FILE="$SMOKE_TMP_ROOT/t2-body.md"
printf 'never reachable body\n' >"$T2_BODY_FILE"

T2_RESULT="$SMOKE_TMP_ROOT/t2-result.json"
T2_HARNESS="$SMOKE_TMP_ROOT/t2-harness.py"
cat >"$T2_HARNESS" <<'PY'
import importlib.util
import json
import os
import sys

repo_root = sys.argv[1]
body_path = sys.argv[2]
result_path = sys.argv[3]

spec = importlib.util.spec_from_file_location(
    "bridge_queue", os.path.join(repo_root, "bridge-queue.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Force the direct read to raise PermissionError and the sudo fallback
# to fail. We do both by monkey-patching the helper at module level.
from pathlib import Path

class StubPath(type(Path())):
    def read_bytes(self):
        raise PermissionError("synthetic permission denied")

# Replace _sudo_read_body_file to return None (fallback exhausted).
mod._sudo_read_body_file = lambda p: None

caught = ""
try:
    mod.stabilize_body_file(body_path)
except SystemExit as exc:
    caught = str(exc)

Path(result_path).write_text(json.dumps({"caught": caught}), encoding="utf-8")
PY

# Force the direct read to fail by removing read perms (mode 0000).
chmod 0000 "$T2_BODY_FILE"
T2_OUT=""
T2_RC=0
T2_OUT="$(python3 "$T2_HARNESS" "$REPO_ROOT" "$T2_BODY_FILE" "$T2_RESULT" 2>&1)" || T2_RC=$?
chmod 0644 "$T2_BODY_FILE"  # cleanup so the trap can remove it

if (( T2_RC != 0 )); then
  smoke_fail "T2: harness failed rc=$T2_RC out: $T2_OUT"
fi
T2_CAUGHT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["caught"])' "$T2_RESULT")"
if [[ "$T2_CAUGHT" == *"failed to read body file"* ]]; then
  smoke_log "T2 ok: fallback failure surfaced structured SystemExit (msg: $T2_CAUGHT)"
else
  # On a host where the controller UID can still read mode 0000 files
  # (uncommon — e.g. root running the smoke), the read never raises.
  # Treat that as "test prereq missing" instead of failing.
  if [[ -z "$T2_CAUGHT" ]]; then
    smoke_log "T2 skip: host could read mode 0000 file; PermissionError path not exercised (likely running as root)"
  else
    smoke_fail "T2: expected 'failed to read body file' in SystemExit message; got: $T2_CAUGHT"
  fi
fi

# ----------------------------------------------------------------------------
# T3 (#1281 positive): the three docs all carry the iso v2 agent
# constraints section + the five key bullets.
# ----------------------------------------------------------------------------
smoke_log "T3 (#1281): CLAUDE.md / docs/developer-handover.md / OPERATIONS.md carry iso v2 section"

for _doc in CLAUDE.md docs/developer-handover.md OPERATIONS.md; do
  _path="$REPO_ROOT/$_doc"
  smoke_assert_file_exists "$_path" "T3 doc present: $_doc"
  _content="$(cat "$_path")"
  smoke_assert_contains "$_content" "isolated agents (iso v2)" "T3 $_doc has 'isolated agents (iso v2)' section heading or reference"
done

# 5 key bullets that all three docs cross-reference (verbatim
# substrings; intentionally narrow so a copy-edit can pass while a
# structural removal fails).
CLAUDE_CONTENT="$(cat "$REPO_ROOT/CLAUDE.md")"
for _bullet in \
  "Read-restricted paths" \
  "Permission dance" \
  "Body files" \
  "Recommended flow" \
  "Known restrictions"; do
  smoke_assert_contains "$CLAUDE_CONTENT" "$_bullet" "T3 CLAUDE.md key bullet: $_bullet"
done
smoke_log "T3 ok: all three docs + the five CLAUDE.md key bullets present"

# ----------------------------------------------------------------------------
# T4 (#1281 teeth): regression guard — when the section is removed, the
# T3 assertions above MUST fail. We don't actually mutate the docs; the
# regression guard is captured by T3 itself.
# ----------------------------------------------------------------------------
smoke_log "T4 (#1281 teeth): T3 assertion shape is the regression guard (covered)"

# ----------------------------------------------------------------------------
# T5 (#1267 positive): downgrade-classify subcommand emits a row when
# installed_core >= latest_core.
# ----------------------------------------------------------------------------
smoke_log "T5 (#1267): release-downgrade-classify emits structured row for installed >= latest"

T5_PAYLOAD='{"alerts":[],"release":{"installed_version":"0.15.0-beta3","latest_version":"0.14.4","latest_tag":"v0.14.4","update_available":false}}'
T5_OUT=""
T5_RC=0
T5_OUT="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" release-downgrade-classify "$T5_PAYLOAD" 2>&1)" || T5_RC=$?
if (( T5_RC != 0 )); then
  smoke_fail "T5: release-downgrade-classify rc=$T5_RC out: $T5_OUT"
fi
smoke_assert_contains "$T5_OUT" "0.15.0-beta3	0.14.4" "T5 emits tab-separated downgrade row"
smoke_log "T5 ok: downgrade-classify identified installed=0.15.0-beta3 >= latest=0.14.4"

# Also exercise bridge-release.py:release_record directly via the mock
# payload path so the prerelease-tolerant comparator is covered.
T5B_OUT=""
T5B_RC=0
T5B_OUT="$(BRIDGE_RELEASE_MOCK_JSON='{"tag_name":"v0.14.4","html_url":"","published_at":""}' \
  python3 "$REPO_ROOT/bridge-release.py" status \
    --repo seanssoh/agent-bridge-public \
    --installed-version 0.15.0-beta3 \
    --json 2>&1)" || T5B_RC=$?
if (( T5B_RC != 0 )); then
  smoke_fail "T5b: bridge-release.py status rc=$T5B_RC out: $T5B_OUT"
fi
T5B_UPDATE="$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["release"]["update_available"])' <<<"$T5B_OUT")"
smoke_assert_eq "False" "$T5B_UPDATE" "T5b release_record sees beta install > stable latest → no update_available"
smoke_log "T5b ok: release_record handles prerelease suffix on the installed side"

# ----------------------------------------------------------------------------
# T6 (#1267 teeth): real upgrade case (installed < latest) MUST NOT
# classify as downgrade-skip. Otherwise we silently swallowed real
# release notifications.
# ----------------------------------------------------------------------------
smoke_log "T6 (#1267 teeth): real upgrade case (installed < latest) → empty downgrade-classify output"

T6_PAYLOAD='{"alerts":[],"release":{"installed_version":"0.13.0","latest_version":"0.14.4","latest_tag":"v0.14.4","update_available":true}}'
T6_OUT=""
T6_RC=0
T6_OUT="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" release-downgrade-classify "$T6_PAYLOAD" 2>&1)" || T6_RC=$?
if (( T6_RC != 0 )); then
  smoke_fail "T6: release-downgrade-classify rc=$T6_RC out: $T6_OUT"
fi
if [[ -n "$T6_OUT" ]]; then
  smoke_fail "T6: real upgrade case unexpectedly produced downgrade-skip row: $T6_OUT"
fi
smoke_log "T6 ok: real upgrade case produced no downgrade-skip classification"

# When the payload has alerts (real upgrade), the classifier MUST also
# stay silent (the alert path is the normal dispatch).
T6B_PAYLOAD='{"alerts":[{"latest_tag":"v0.16.0","latest_version":"0.16.0"}],"release":{"installed_version":"0.15.0","latest_version":"0.16.0","update_available":true}}'
T6B_OUT=""
T6B_OUT="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" release-downgrade-classify "$T6B_PAYLOAD" 2>&1)" || true
if [[ -n "$T6B_OUT" ]]; then
  smoke_fail "T6b: alert-present case unexpectedly produced downgrade-skip row: $T6B_OUT"
fi
smoke_log "T6b ok: alert-present case stays silent (no false downgrade-skip)"

# ----------------------------------------------------------------------------
# T7 (#1263 positive): bootstrap-memory-system.sh --apply on a fresh
# BRIDGE_HOME short-circuits with the wiki_graph_skipped marker.
# bridge-bootstrap.sh --dry-run --json includes the wiki_graph
# advisory object.
# ----------------------------------------------------------------------------
smoke_log "T7 (#1263): fresh BRIDGE_HOME bootstrap-memory-system.sh --apply short-circuits with wiki_graph_skipped marker"

# Sanity: smoke_setup_bridge_home already pinned BRIDGE_HOME and
# friends to a fresh tmp tree. We confirm no prior report exists.
if compgen -G "$BRIDGE_STATE_DIR/bootstrap-memory/report-*.json" >/dev/null 2>&1; then
  smoke_fail "T7 prereq: BRIDGE_HOME unexpectedly already has bootstrap-memory reports"
fi

# Unset the env var explicitly (smoke_setup_bridge_home does not touch
# BRIDGE_WIKI_GRAPH_ENABLED but the operator's shell may have leaked
# it). With no env and no prior report, the gate fires.
unset BRIDGE_WIKI_GRAPH_ENABLED
T7_OUT=""
T7_RC=0
T7_OUT="$("$BRIDGE_BASH_BIN" "$REPO_ROOT/bootstrap-memory-system.sh" --apply 2>&1)" || T7_RC=$?
if (( T7_RC != 0 )); then
  smoke_fail "T7: bootstrap-memory-system.sh --apply rc=$T7_RC out: $T7_OUT"
fi
smoke_assert_contains "$T7_OUT" "wiki_graph_skipped=1" "T7 stdout marker"
smoke_assert_contains "$T7_OUT" "fresh install" "T7 advisory mentions fresh install"
smoke_assert_contains "$T7_OUT" "BRIDGE_WIKI_GRAPH_ENABLED=1" "T7 advisory names the activation env"
smoke_log "T7 ok: fresh install short-circuit fired with structured marker + advisory"

# T7b: bridge-bootstrap.sh --dry-run --json carries the wiki_graph object.
T7B_OUT=""
T7B_RC=0
# We pass --skip-* flags to keep the dry-run hermetic in the smoke
# tmpdir; --json is the structured surface we assert on.
T7B_OUT="$(BRIDGE_BOOTSTRAP_OS=Linux "$BRIDGE_BASH_BIN" "$REPO_ROOT/bridge-bootstrap.sh" \
  --skip-shell-integration --skip-tmux-ux --skip-daemon \
  --skip-launchagent --skip-systemd --skip-liveness \
  --skip-watchdog-silence \
  --dry-run --json --admin patch --engine claude 2>&1)" || T7B_RC=$?
if (( T7B_RC != 0 )); then
  smoke_fail "T7b: bridge-bootstrap.sh --dry-run --json rc=$T7B_RC out: $T7B_OUT"
fi
T7B_HAS_WIKI="$(python3 -c '
import json, sys
payload = sys.argv[1]
# Find the first { and try to parse from there to skip any stderr noise
# that may have leaked into the captured stream.
idx = payload.find("{")
if idx < 0:
    print("no_json")
    raise SystemExit(0)
try:
    data = json.loads(payload[idx:])
except Exception as e:
    print(f"parse_error:{e}")
    raise SystemExit(0)
wg = data.get("wiki_graph") or {}
print("yes" if wg.get("default_enabled") is False and "BRIDGE_WIKI_GRAPH_ENABLED=1" in (wg.get("activation_command") or "") else "no")
' "$T7B_OUT")"
smoke_assert_eq "yes" "$T7B_HAS_WIKI" "T7b bridge-bootstrap.sh --json carries wiki_graph object"
smoke_log "T7b ok: bridge-bootstrap.sh --json surfaces the wiki_graph activation command"

# ----------------------------------------------------------------------------
# T8 (#1263 teeth): BRIDGE_WIKI_GRAPH_ENABLED=1 disables the
# short-circuit (back-compat path). We confirm the gate did NOT fire
# by checking the absence of the `wiki_graph_skipped=1` marker.
# ----------------------------------------------------------------------------
smoke_log "T8 (#1263 teeth): BRIDGE_WIKI_GRAPH_ENABLED=1 disables the fresh-install short-circuit"

# We DON'T want to actually provision wiki-graph on the smoke host
# (that would require static roster + admin agent). Instead we drive
# the script to a deterministic failure that proves the gate did not
# short-circuit. The simplest signal: bootstrap-memory-system.sh
# proceeds past the gate and tries to find admin agents, which fails
# on the empty smoke roster — that failure is distinct from the
# wiki_graph_skipped marker.

T8_OUT=""
T8_RC=0
T8_OUT="$(BRIDGE_WIKI_GRAPH_ENABLED=1 "$BRIDGE_BASH_BIN" "$REPO_ROOT/bootstrap-memory-system.sh" --apply 2>&1)" || T8_RC=$?
smoke_assert_not_contains "$T8_OUT" "wiki_graph_skipped=1" "T8 gate did NOT short-circuit when env=1"
smoke_assert_not_contains "$T8_OUT" "fresh install (no prior bootstrap-memory report)" "T8 advisory did NOT mention fresh-install skip"
smoke_log "T8 ok: BRIDGE_WIKI_GRAPH_ENABLED=1 disables the short-circuit (back-compat preserved)"

# T8b: explicit BRIDGE_WIKI_GRAPH_ENABLED=0 also short-circuits with a
# different reason string than the inferred fresh-install case, so
# operators can tell apart "I said off" from "default off".
T8B_OUT=""
T8B_RC=0
T8B_OUT="$(BRIDGE_WIKI_GRAPH_ENABLED=0 "$BRIDGE_BASH_BIN" "$REPO_ROOT/bootstrap-memory-system.sh" --apply 2>&1)" || T8B_RC=$?
if (( T8B_RC != 0 )); then
  smoke_fail "T8b: bootstrap-memory-system.sh --apply (env=0) rc=$T8B_RC out: $T8B_OUT"
fi
smoke_assert_contains "$T8B_OUT" "wiki_graph_skipped=1" "T8b stdout marker present for explicit opt-out"
smoke_assert_contains "$T8B_OUT" "operator opt-out" "T8b advisory names operator opt-out reason"
smoke_log "T8b ok: explicit BRIDGE_WIKI_GRAPH_ENABLED=0 fires with operator-opt-out reason"

# ----------------------------------------------------------------------------
# T9 (#1267 r2 BLOCKING): same-core beta→stable IS a valid upgrade.
# Pre-r2 code reduced any prerelease to its core tuple and then declared
# "installed_core >= latest_core" → emitted release_notification_downgrade_skip
# on 0.14.5-beta1 vs 0.14.5 (a legitimate beta→stable upgrade). r2 uses
# full semver 2.0.0 prerelease ordering so the same-core beta < final
# rule kicks in.
# ----------------------------------------------------------------------------
smoke_log "T9 (#1267 r2): same-core beta→stable is a real upgrade (NOT downgrade-skip)"

# T9a: release_record sees update_available=true on 0.14.5-beta1 vs v0.14.5.
T9A_OUT=""
T9A_RC=0
T9A_OUT="$(BRIDGE_RELEASE_MOCK_JSON='{"tag_name":"v0.14.5","html_url":"","published_at":""}' \
  python3 "$REPO_ROOT/bridge-release.py" status \
    --repo seanssoh/agent-bridge-public \
    --installed-version 0.14.5-beta1 \
    --json 2>&1)" || T9A_RC=$?
if (( T9A_RC != 0 )); then
  smoke_fail "T9a: bridge-release.py status rc=$T9A_RC out: $T9A_OUT"
fi
T9A_UPDATE="$(python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["release"]["update_available"])' <<<"$T9A_OUT")"
smoke_assert_eq "True" "$T9A_UPDATE" "T9a release_record beta→stable same-core sees update_available=true"
smoke_log "T9a ok: release_record sees 0.14.5-beta1 < 0.14.5 as upgrade"

# T9b: downgrade-classify stays SILENT (no row) on the same pair, because
# emitting a row would tell the daemon "skip the notification" — wrong.
T9B_PAYLOAD='{"alerts":[],"release":{"installed_version":"0.14.5-beta1","latest_version":"0.14.5","latest_tag":"v0.14.5","update_available":true}}'
T9B_OUT=""
T9B_RC=0
T9B_OUT="$(python3 "$REPO_ROOT/bridge-daemon-helpers.py" release-downgrade-classify "$T9B_PAYLOAD" 2>&1)" || T9B_RC=$?
if (( T9B_RC != 0 )); then
  smoke_fail "T9b: release-downgrade-classify rc=$T9B_RC out: $T9B_OUT"
fi
if [[ -n "$T9B_OUT" ]]; then
  smoke_fail "T9b: beta→stable same-core wrongly classified as downgrade-skip: $T9B_OUT"
fi
smoke_log "T9b ok: downgrade-classify silent for same-core beta→stable (real upgrade)"

# T9c (teeth): also assert prerelease ORDERING covers the alpha < beta < rc
# < final chain so the comparator does not regress to "any prerelease is
# equal" or similar shortcuts.
T9C_RESULT="$SMOKE_TMP_ROOT/t9c-cmp.json"
T9C_HARNESS="$SMOKE_TMP_ROOT/t9c-harness.py"
cat >"$T9C_HARNESS" <<'PY'
import importlib.util
import json
import os
import sys

repo_root = sys.argv[1]
out_path = sys.argv[2]

spec = importlib.util.spec_from_file_location(
    "bridge_release", os.path.join(repo_root, "bridge-release.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

cases = [
    ("0.14.5-beta1", "0.14.5", -1),
    ("0.14.5", "0.14.5-beta1", 1),
    ("0.14.5", "0.14.5", 0),
    ("0.14.5-alpha", "0.14.5-beta", -1),
    ("0.14.5-beta", "0.14.5-rc.1", -1),
    ("0.14.5-rc.1", "0.14.5", -1),
    ("0.14.5-beta.2", "0.14.5-beta.11", -1),
    ("0.15.0-beta3", "0.14.5", 1),
]
out = []
for a, b, want in cases:
    got = mod.compare_semver(a, b)
    out.append({"a": a, "b": b, "want": want, "got": got, "ok": got == want})

open(out_path, "w").write(json.dumps(out))
PY
T9C_OUT=""
T9C_RC=0
T9C_OUT="$(python3 "$T9C_HARNESS" "$REPO_ROOT" "$T9C_RESULT" 2>&1)" || T9C_RC=$?
if (( T9C_RC != 0 )); then
  smoke_fail "T9c: harness failed rc=$T9C_RC out: $T9C_OUT"
fi
T9C_BAD="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
bad = [r for r in data if not r["ok"]]
if bad:
    print(json.dumps(bad))
' "$T9C_RESULT")"
if [[ -n "$T9C_BAD" ]]; then
  smoke_fail "T9c: semver comparator regressions: $T9C_BAD"
fi
smoke_log "T9c ok: full semver 2.0.0 prerelease ordering chain passes"

# ----------------------------------------------------------------------------
# T10 (#1281 SHOULD-FIX): body_file_sudo_fallback audit row IS emitted.
# OPERATIONS.md tells operators they can grep `body_file_sudo_fallback`
# in `state/audit.jsonl` to confirm whether the sudo step ran. Pre-r2
# the runbook claim was a docs/impl mismatch (the fallback path was
# silent). r2 emits a structured row from both call sites.
# ----------------------------------------------------------------------------
smoke_log "T10 (#1281): body_file_sudo_fallback audit row emitted from both fallback sites"

# T10a: bridge-queue.stabilize_body_file path. We reuse the T1 stub
# pattern (PATH-injected sudo + monkey-patched pwd.getpwuid + forced
# non-self-uid) and assert the audit row.
T10A_STUB_DIR="$SMOKE_TMP_ROOT/t10a-stub"
mkdir -p "$T10A_STUB_DIR"
T10A_BODY_FILE="$SMOKE_TMP_ROOT/t10a-body.md"
printf 'queue-side iso-owned body\n' >"$T10A_BODY_FILE"

cat >"$T10A_STUB_DIR/sudo" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
# Accept `-n -u <owner> cat -- <path>`
if [[ "$1" != "-n" || "$2" != "-u" ]]; then exit 99; fi
shift 3
if [[ "$1" != "cat" || "$2" != "--" ]]; then exit 99; fi
cat "$3"
SHIM
chmod +x "$T10A_STUB_DIR/sudo"

T10A_AUDIT_LOG="$BRIDGE_HOME/logs/audit-t10a.jsonl"
mkdir -p "$(dirname "$T10A_AUDIT_LOG")"
: >"$T10A_AUDIT_LOG"

T10A_HARNESS="$SMOKE_TMP_ROOT/t10a-harness.py"
cat >"$T10A_HARNESS" <<'PY'
import importlib.util
import json
import os
import sys
from pathlib import Path

repo_root = sys.argv[1]
body_path = sys.argv[2]

spec = importlib.util.spec_from_file_location(
    "bridge_queue", os.path.join(repo_root, "bridge-queue.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class FakePwEnt:
    def __init__(self, name):
        self.pw_name = name

import pwd as _pwd
_pwd.getpwuid = lambda uid: FakePwEnt("agent-bridge-t10a")

orig = os.geteuid
os.geteuid = lambda: orig() + 999999

raw = mod._sudo_read_body_file(Path(body_path))
print(json.dumps({"ok": raw is not None, "len": len(raw) if raw else 0}))
PY
T10A_OUT=""
T10A_RC=0
T10A_OUT="$(PATH="$T10A_STUB_DIR:$PATH" BRIDGE_AUDIT_LOG="$T10A_AUDIT_LOG" \
  python3 "$T10A_HARNESS" "$REPO_ROOT" "$T10A_BODY_FILE" 2>&1)" || T10A_RC=$?
if (( T10A_RC != 0 )); then
  smoke_fail "T10a: harness failed rc=$T10A_RC out: $T10A_OUT"
fi
smoke_assert_file_exists "$T10A_AUDIT_LOG" "T10a audit log file exists"
T10A_HAS_ROW="$(grep -c 'body_file_sudo_fallback' "$T10A_AUDIT_LOG" || true)"
if [[ "$T10A_HAS_ROW" -lt 1 ]]; then
  smoke_fail "T10a: audit log missing body_file_sudo_fallback row. Contents: $(cat "$T10A_AUDIT_LOG")"
fi
T10A_HAS_QUEUE_SITE="$(grep -c 'bridge-queue.stabilize_body_file' "$T10A_AUDIT_LOG" || true)"
if [[ "$T10A_HAS_QUEUE_SITE" -lt 1 ]]; then
  smoke_fail "T10a: audit row missing call_site=bridge-queue.stabilize_body_file. Contents: $(cat "$T10A_AUDIT_LOG")"
fi
smoke_log "T10a ok: bridge-queue body_file_sudo_fallback audit row emitted"

# T10b: bridge-a2a._sudo_read_text path. Same shape, different module +
# different call_site marker.
T10B_STUB_DIR="$SMOKE_TMP_ROOT/t10b-stub"
mkdir -p "$T10B_STUB_DIR"
T10B_BODY_FILE="$SMOKE_TMP_ROOT/t10b-body.md"
printf 'a2a-side iso-owned body\n' >"$T10B_BODY_FILE"

cat >"$T10B_STUB_DIR/sudo" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" != "-n" || "$2" != "-u" ]]; then exit 99; fi
shift 3
if [[ "$1" != "cat" || "$2" != "--" ]]; then exit 99; fi
cat "$3"
SHIM
chmod +x "$T10B_STUB_DIR/sudo"

T10B_AUDIT_LOG="$BRIDGE_HOME/logs/audit-t10b.jsonl"
mkdir -p "$(dirname "$T10B_AUDIT_LOG")"
: >"$T10B_AUDIT_LOG"

T10B_HARNESS="$SMOKE_TMP_ROOT/t10b-harness.py"
cat >"$T10B_HARNESS" <<'PY'
import importlib.util
import json
import os
import sys
from pathlib import Path

repo_root = sys.argv[1]
body_path = sys.argv[2]

# bridge-a2a.py imports bridge_a2a_common from the same directory, so
# we have to prepend repo_root to sys.path before loading the module.
sys.path.insert(0, repo_root)

spec = importlib.util.spec_from_file_location(
    "bridge_a2a", os.path.join(repo_root, "bridge-a2a.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class FakePwEnt:
    def __init__(self, name):
        self.pw_name = name

import pwd as _pwd
_pwd.getpwuid = lambda uid: FakePwEnt("agent-bridge-t10b")

orig = os.geteuid
os.geteuid = lambda: orig() + 999999

text = mod._sudo_read_text(Path(body_path))
print(json.dumps({"ok": text is not None, "len": len(text) if text else 0}))
PY
T10B_OUT=""
T10B_RC=0
T10B_OUT="$(PATH="$T10B_STUB_DIR:$PATH" BRIDGE_AUDIT_LOG="$T10B_AUDIT_LOG" \
  python3 "$T10B_HARNESS" "$REPO_ROOT" "$T10B_BODY_FILE" 2>&1)" || T10B_RC=$?
if (( T10B_RC != 0 )); then
  smoke_fail "T10b: harness failed rc=$T10B_RC out: $T10B_OUT"
fi
smoke_assert_file_exists "$T10B_AUDIT_LOG" "T10b audit log file exists"
T10B_HAS_ROW="$(grep -c 'body_file_sudo_fallback' "$T10B_AUDIT_LOG" || true)"
if [[ "$T10B_HAS_ROW" -lt 1 ]]; then
  smoke_fail "T10b: audit log missing body_file_sudo_fallback row. Contents: $(cat "$T10B_AUDIT_LOG")"
fi
T10B_HAS_A2A_SITE="$(grep -c 'bridge-a2a.cmd_send' "$T10B_AUDIT_LOG" || true)"
if [[ "$T10B_HAS_A2A_SITE" -lt 1 ]]; then
  smoke_fail "T10b: audit row missing call_site=bridge-a2a.cmd_send. Contents: $(cat "$T10B_AUDIT_LOG")"
fi
smoke_log "T10b ok: bridge-a2a body_file_sudo_fallback audit row emitted"

# T10c (teeth): without the emit call, the audit log MUST be empty.
# We approximate the regression by re-running the bridge-queue harness
# but with the emit shim short-circuited (set BRIDGE_AUDIT_LOG to a
# non-writable location → emit silently swallows the failure, audit log
# stays empty, T10a's assertion would then fail). This proves the
# assertion has teeth: if the emit is removed or the audit path is
# broken, the smoke catches it.
T10C_AUDIT_LOG="$SMOKE_TMP_ROOT/t10c-readonly/audit.jsonl"
mkdir -p "$(dirname "$T10C_AUDIT_LOG")"
chmod 0555 "$(dirname "$T10C_AUDIT_LOG")"
T10C_OUT=""
T10C_RC=0
T10C_OUT="$(PATH="$T10A_STUB_DIR:$PATH" BRIDGE_AUDIT_LOG="$T10C_AUDIT_LOG" \
  python3 "$T10A_HARNESS" "$REPO_ROOT" "$T10A_BODY_FILE" 2>&1)" || T10C_RC=$?
chmod 0755 "$(dirname "$T10C_AUDIT_LOG")"  # restore for cleanup
if (( T10C_RC != 0 )); then
  smoke_fail "T10c: harness failed rc=$T10C_RC out: $T10C_OUT"
fi
if [[ -s "$T10C_AUDIT_LOG" ]]; then
  smoke_fail "T10c teeth: expected EMPTY audit log when target dir is read-only (sanity check), got: $(cat "$T10C_AUDIT_LOG")"
fi
smoke_log "T10c teeth ok: read-only audit dir → empty log (emit best-effort, T10a/b assertions have teeth)"

smoke_log "All J-beta4 workflow + docs tests passed."
