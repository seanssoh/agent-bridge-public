#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1894-iso-transcript-harvest-run-as-iso.sh — Issue #1894.
#
# The controller-run cron `scripts/memory-daily-harvest.sh` needs r-X into each
# iso agent's transcript tree `<iso-home>/.claude/projects` to scan sessions.
# A stale comment claimed an ACL "added by bridge_linux_prepare_agent_isolation"
# granted the controller that read, but in the field there is NO setfacl —
# `.claude` is group-setgid 3770 (group `ab-agent-<a>`) while Claude creates
# `projects/` at runtime under the iso UID's umask 077 → mode 2700, no group
# read. So the controller's `[[ -r && -x ]]` test always failed and every iso
# agent landed in `--skipped-permission` permanently (stale transcript index).
#
# Fix (issue's run-as-iso narrow helper, lowest blast radius): run ONLY the
# bounded transcript scan AS the iso UID via the sanctioned sudoers `bash`
# allowlist (`bridge_isolation_run_as_agent_user_via_bash`), marshal the JSON
# list back to the controller-UID harvest via `--transcripts-json`, and keep
# every queue-DB / aggregate write in the controller context (Design A, #786).
# The prepare-isolation path (which carries #1891's index.sqlite 0600 carve-out
# and the #1506/#1533 publisher ordering) is NOT touched — no recursive chmod.
#
# Two layers:
#
#   T1..T9 — Source-structure assertions (host-agnostic, no sudo, no useradd):
#     T1: the stub sources $BRIDGE_HOME/bridge-lib.sh (loads the iso helpers).
#     T2: bridge_load_roster is called after that source AND inside the
#         _BRIDGE_ISO_HELPERS_LOADED guard (without the loader the predicate is
#         always-false dead code — the #1222 r1 BLOCKING regression class).
#     T3: the linux-user branch probes bridge_isolation_can_sudo_to_agent.
#     T4: the iso branch runs the scan via
#         bridge_isolation_run_as_agent_user_via_bash.
#     T5: the inline scan body runs `bridge-memory.py scan-transcripts` (so it
#         is the scan that crosses the boundary, not a no-op).
#     T6: scan-success exec's harvest-daily with --transcripts-json (the
#         marshal-back path), and the legacy --skipped-permission exec survives
#         as the fallback (no regression).
#     T7: the prepare-isolation path is untouched — the stub does NOT contain a
#         chmod/setfacl on .claude/projects (the forbidden broad-relaxation).
#     T8: no heredoc / here-string inside the inline scan body (footgun #11).
#     T9: bridge-memory.py exposes the `scan-transcripts` subcommand and the
#         harvest-daily `--transcripts-json` arg the stub depends on.
#
#   T10..T11 — Behavioral repro. Drive the real stub against a mocked iso
#     layout (a `projects/` dir under a fake os_user home) with a stub
#     bridge-lib.sh whose `bridge_isolation_*` helpers run the scan inline as
#     the current user (no real sudo/useradd needed) and a toggle for the sudo
#     probe:
#       T10: probe SUCCEEDS → run-as-iso scan path → harvest classifies the
#            transcript as strong activity (queue-backfill), NOT skipped.
#       T11: probe FAILS → --skipped-permission fallback (state=skipped-permission).
#
# Footgun #11: every structural assertion uses grep/awk over the source; no
# heredoc/here-string is introduced by the path under test.

set -uo pipefail

SMOKE_NAME="1894-iso-transcript-harvest-run-as-iso"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
STUB="$REPO_ROOT/scripts/memory-daily-harvest.sh"
MEMPY="$REPO_ROOT/bridge-memory.py"

# shellcheck disable=SC2329  # invoked via trap below
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"
smoke_require_cmd bash

[[ -r "$STUB" ]] || smoke_fail "cannot read harvest stub at $STUB"
[[ -r "$MEMPY" ]] || smoke_fail "cannot read bridge-memory.py at $MEMPY"

# ---------------------------------------------------------------------
# T1..T8 — structural assertions over the stub source.
# ---------------------------------------------------------------------
no_comments="$SMOKE_TMP_ROOT/stub.no-comments.txt"
grep -nv '^[[:space:]]*#' "$STUB" >"$no_comments"

# T1 — sources $BRIDGE_HOME/bridge-lib.sh.
grep -Eq 'source[[:space:]]+"\$BRIDGE_HOME/bridge-lib\.sh"' "$STUB" \
  || smoke_fail "T1 stub does not source \$BRIDGE_HOME/bridge-lib.sh"
smoke_log "ok: T1 stub sources bridge-lib.sh"

# T2 — bridge_load_roster after the source, inside the guard.
grep -q "bridge_load_roster" "$no_comments" \
  || smoke_fail "T2 bridge_load_roster not called (predicate gate would always fail)"
grep -q "_BRIDGE_ISO_HELPERS_LOADED" "$no_comments" \
  || smoke_fail "T2 no _BRIDGE_ISO_HELPERS_LOADED guard"
source_line="$(grep 'source[[:space:]]\+"\$BRIDGE_HOME/bridge-lib\.sh"' "$no_comments" | head -1 | cut -d: -f1)"
loader_line="$(grep "bridge_load_roster" "$no_comments" | head -1 | cut -d: -f1)"
if [[ -z "$source_line" || -z "$loader_line" ]] || (( loader_line <= source_line )); then
  smoke_fail "T2 bridge_load_roster not after source bridge-lib.sh (source=$source_line loader=$loader_line)"
fi
smoke_log "ok: T2 bridge_load_roster called after source, inside the guard"

# T3 — linux-user branch probes the sudo capability.
grep -q "bridge_isolation_can_sudo_to_agent" "$no_comments" \
  || smoke_fail "T3 no bridge_isolation_can_sudo_to_agent probe"
smoke_log "ok: T3 iso branch probes bridge_isolation_can_sudo_to_agent"

# T4 — iso branch runs the scan via the run-as helper.
grep -q "bridge_isolation_run_as_agent_user_via_bash" "$no_comments" \
  || smoke_fail "T4 no bridge_isolation_run_as_agent_user_via_bash call"
smoke_log "ok: T4 iso branch invokes bridge_isolation_run_as_agent_user_via_bash"

# T5 — extract the single-quoted iso_scan_script body; assert it runs
#      `bridge-memory.py scan-transcripts`.
body="$SMOKE_TMP_ROOT/stub.iso-scan-body.txt"
awk "
  /iso_scan_script=\x27\$/ {inb=1; next}
  inb==1 && /^\x27\$/ {inb=0; next}
  inb==1 {print}
" "$STUB" >"$body"
[[ -s "$body" ]] || smoke_fail "T5 could not extract iso_scan_script body (empty)"
grep -Eq "bridge-memory\.py.* scan-transcripts" "$body" \
  || smoke_fail "T5 iso body does not run scan-transcripts inside the boundary"
smoke_log "ok: T5 iso body runs scan-transcripts as the iso UID"

# T6 — marshal-back path + preserved fallback.
grep -q -- "--transcripts-json" "$no_comments" \
  || smoke_fail "T6 harvest-daily is not fed --transcripts-json (marshal-back missing)"
grep -q -- "--skipped-permission" "$no_comments" \
  || smoke_fail "T6 --skipped-permission fallback disappeared (regression risk)"
smoke_log "ok: T6 marshal-back via --transcripts-json + --skipped-permission fallback preserved"

# T7 — prepare-isolation path untouched: the stub must NOT broadly relax the
#      transcript tree (no chmod/setfacl on .claude/projects). That broad
#      relaxation is the forbidden alternative (#1891 index.sqlite 0600 +
#      #1506/#1533 publisher ordering live in the prepare path, not here).
if grep -nE '(chmod|setfacl)[^#]*\.claude/projects' "$no_comments"; then
  smoke_fail "T7 stub relaxes perms on .claude/projects (forbidden broad relaxation)"
fi
smoke_log "ok: T7 stub does not chmod/setfacl .claude/projects (prepare-isolation path untouched)"

# T8 — no heredoc / here-string in the inline scan body (footgun #11).
if grep -Eq '[<][<]-?[A-Za-z_'"'"'"]|[<][<][<]' "$body"; then
  grep -nE '[<][<]-?[A-Za-z_'"'"'"]|[<][<][<]' "$body" >&2
  smoke_fail "T8 iso_scan_script contains a heredoc/here-string (footgun #11)"
fi
smoke_log "ok: T8 no heredoc/here-string in the inline scan body"

# T9 — the Python surface the stub depends on actually exists.
"$PY_BIN" "$MEMPY" scan-transcripts --help >/dev/null 2>&1 \
  || smoke_fail "T9 bridge-memory.py lacks the scan-transcripts subcommand"
"$PY_BIN" "$MEMPY" harvest-daily --help 2>/dev/null | grep -q -- "--transcripts-json" \
  || smoke_fail "T9 harvest-daily lacks the --transcripts-json arg"
smoke_log "ok: T9 bridge-memory.py exposes scan-transcripts + harvest-daily --transcripts-json"

# ---------------------------------------------------------------------
# T10..T11 — behavioral repro against the real stub.
# ---------------------------------------------------------------------
# Mock layout: a workdir, an agent profile home, and an "iso" home whose
# .claude/projects holds a yesterday-dated transcript. The stub bridge-lib.sh
# below defines the iso helpers so the scan runs inline as the current user
# (no real sudo); BRIDGE_SCAN_SUDO_OK toggles the probe outcome.
BH="$BRIDGE_HOME"
WD="$SMOKE_TMP_ROOT/work"
AHOME="$SMOKE_TMP_ROOT/agenthome"
ISOHOME="$SMOKE_TMP_ROOT/isohome"
mkdir -p "$WD" "$AHOME"

SLUG="$(printf '%s' "$WD" | sed 's:/:-:g; s:\.:-:g')"
PROJ="$ISOHOME/.claude/projects/$SLUG"
mkdir -p "$PROJ"
# Emulate the field bug: projects/ is unreadable to "others" (mode 0700). The
# stub's scan runs as the iso UID so this does not block it; a controller-side
# direct read would. We do not need a real second UID for the control-flow test.
chmod 0700 "$PROJ" 2>/dev/null || true
YDAY="$("$PY_BIN" -c "import datetime,zoneinfo; print((datetime.datetime.now(zoneinfo.ZoneInfo('Asia/Seoul')).date()-datetime.timedelta(days=1)).isoformat())")"
TS="${YDAY}T10:00:00+09:00"
printf '%s\n%s\n' \
  "{\"type\":\"user\",\"timestamp\":\"$TS\"}" \
  "{\"type\":\"assistant\",\"timestamp\":\"$TS\"}" >"$PROJ/sess1.jsonl"

# Real bridge-memory.py reachable at $BRIDGE_HOME/bridge-memory.py.
cp "$MEMPY" "$BH/bridge-memory.py"

# Fake agb: returns the agent-show JSON the stub parses.
AGB_BIN="$SMOKE_TMP_ROOT/fake-agb"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'if [[ "$1" == "agent" && "$2" == "show" ]]; then'
  printf '  printf %s "{\\"source\\":\\"static\\",\\"workdir\\":\\"%s\\",\\"profile\\":{\\"home\\":\\"%s\\"},\\"isolation\\":{\\"mode\\":\\"linux-user\\",\\"os_user\\":\\"agent-bridge-w1894\\"}}"\n' "'%s'" "$WD" "$AHOME"
  printf '%s\n' '  exit 0'
  printf '%s\n' 'fi'
  printf '%s\n' 'exit 0'
} >"$AGB_BIN"
chmod +x "$AGB_BIN"

# Stub bridge-lib.sh: defines the iso helpers so _BRIDGE_ISO_HELPERS_LOADED=1
# and the iso branch engages. The scan helper runs the inline script directly
# as the current user (stand-in for the iso UID); the probe honors the toggle.
cat >"$BH/bridge-lib.sh" <<'LIBEOF'
bridge_load_roster() { return 0; }
bridge_agent_linux_user_isolation_effective() { [[ "${1:-}" == "w1894" ]]; }
bridge_isolation_can_sudo_to_agent() {
  [[ "${BRIDGE_SCAN_SUDO_OK:-1}" == "1" ]]
}
bridge_isolation_run_as_agent_user_via_bash() {
  local agent="$1"; local script="$2"; shift 2 || true
  bash -c "$script" bridge-isolation "$@"
}
LIBEOF

run_stub() {
  # $1 = BRIDGE_SCAN_SUDO_OK ; prints harvest JSON on stdout.
  BRIDGE_HOME="$BH" \
  BRIDGE_AGB="$AGB_BIN" \
  BRIDGE_PYTHON="$PY_BIN" \
  BRIDGE_SCAN_SUDO_OK="$1" \
  BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$SMOKE_TMP_ROOT/iso-home-root" \
  CRON_REQUEST_DIR="$SMOKE_TMP_ROOT/cron-req-$1" \
    bash "$STUB" --agent w1894 2>"$SMOKE_TMP_ROOT/stub-$1.err"
}

# The stub resolves transcripts under $BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/<os_user>.
mkdir -p "$SMOKE_TMP_ROOT/iso-home-root" "$SMOKE_TMP_ROOT/cron-req-1" "$SMOKE_TMP_ROOT/cron-req-0"
ln -s "$ISOHOME" "$SMOKE_TMP_ROOT/iso-home-root/agent-bridge-w1894"

# T10 — probe succeeds → run-as-iso scan path → strong activity (queue-backfill).
OUT10="$(run_stub 1 || true)"
STATE10="$("$PY_BIN" -c "import json,sys
try: d=json.loads(sys.argv[1])
except Exception: print('PARSE_FAIL'); sys.exit(0)
print(d.get('status',''))" "$OUT10" 2>/dev/null || true)"
if [[ "$STATE10" != "queued" ]]; then
  printf '[T10] expected status=queued (strong activity via run-as-iso scan), got %q\n' "$STATE10" >&2
  printf '[T10] stub stderr:\n' >&2; tail -5 "$SMOKE_TMP_ROOT/stub-1.err" >&2 || true
  printf '[T10] stub stdout: %s\n' "$OUT10" >&2
  smoke_fail "T10 run-as-iso scan path did not surface the transcript (no queue-backfill)"
fi
smoke_log "ok: T10 sudo probe success → run-as-iso scan → queue-backfill (transcript seen)"

# T11 — probe fails → --skipped-permission fallback.
OUT11="$(run_stub 0 || true)"
STATE11="$("$PY_BIN" -c "import json,sys
try: d=json.loads(sys.argv[1])
except Exception: print('PARSE_FAIL'); sys.exit(0)
print(d.get('status',''))" "$OUT11" 2>/dev/null || true)"
# harvest-daily --skipped-permission emits status=skipped in the result payload.
if [[ "$STATE11" != "skipped" ]]; then
  printf '[T11] expected status=skipped (--skipped-permission fallback), got %q\n' "$STATE11" >&2
  printf '[T11] stub stderr:\n' >&2; tail -5 "$SMOKE_TMP_ROOT/stub-0.err" >&2 || true
  printf '[T11] stub stdout: %s\n' "$OUT11" >&2
  smoke_fail "T11 sudo-probe-fail did not take the --skipped-permission fallback"
fi
smoke_log "ok: T11 sudo probe fail → --skipped-permission fallback"

smoke_log "all assertions passed"
exit 0
