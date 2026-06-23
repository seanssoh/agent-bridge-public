#!/usr/bin/env bash
#
# scripts/smoke/2063-stale-crash-report-launch-cmd-guard.sh — issue #2063.
#
# REGRESSION CONTEXT
# ==================
# A leftover runtime/crash/report.env from a PRIOR launch era keeps driving
# false crash-loop alarms on a HEALTHY agent after the agent's launch command
# changes (dynamic→static convert, reclassify, `update --set-launch-cmd`, or a
# manual launch change). The daemon (`process_crash_reports`) re-read report.env
# every sweep and re-emitted `crash_notified_origin_suppressed` (~200×/12h) +
# fired one spurious "Crash loop detected" urgent — while the agent was healthy.
#
# FIX
# ===
# Part 1 (daemon): before driving the alarm, the daemon compares the recorded
# `CRASH_LAUNCH_CMD` against the agent's CURRENT launch base (the side-effect-
# free `bridge_agent_launch_cmd_raw`) via a shell-token base-signature compare
# (`scripts/python-helpers/launch-cmd-base-signature.py`). On a POSITIVE base
# mismatch it auto-retires report.env (`bridge_agent_clear_crash_report`) and
# emits a single `crash_report_retired_stale_launch_cmd` audit instead of the
# alarm churn. A GENUINE ongoing crash rewrites report.env with the CURRENT
# launch cmd, so a MATCHING base still alarms (no regression). Empty/malformed/
# degenerate/cross-engine comparisons are "incomparable" → keep alarming.
#
# Part 2 (CLI): `ack-crash` retires a VALID report when the agent is healthy
# (previously it only suppressed and left the report to re-fire); a new
# `clear-crash` verb unconditionally retires it.
#
# CASES
# =====
#   T1  base-signature helper: launch-base signatures + the stale predicate
#       exit codes (0 stale / 1 same / 2 incomparable), incl. the resume-id-
#       rotation and codex-resume same-base equivalences.
#   T2  daemon path, MISMATCHED launch cmd + healthy agent → report.env is
#       auto-retired, a `crash_report_retired_stale_launch_cmd` audit fires
#       ONCE, and NO `crash_notified_origin*` alarm churn is emitted.
#   T3  daemon path, MATCHING launch cmd → real crash detection preserved
#       (report.env NOT retired by the guard; the alarm path is reached).
#   T4  Part 2 — ack-crash on a healthy agent retires report.env; clear-crash
#       retires it unconditionally; ack-crash on a NOT-active agent keeps the
#       report (evidence preserved).
#   T5 (mutation/teeth) — with the Part-1 guard predicate forced to "never
#       stale", the SAME mismatched report.env re-alarms. Proves the smoke is
#       non-vacuous (the guard is what stops the churn).
#
# Footgun #11 mitigation: zero heredoc-stdin into a subprocess — helper bodies
# are extracted with awk + emitted via printf-to-file.

_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:2063-stale-crash-report-launch-cmd-guard] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="2063-stale-crash-report-launch-cmd-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENT="syrs-shop-dev"
SIG_HELPER="$REPO_ROOT/scripts/python-helpers/launch-cmd-base-signature.py"

BRIDGE_BASH="${BASH4_BIN:-}"
if [[ -z "$BRIDGE_BASH" || ! -x "$BRIDGE_BASH" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  else
    BRIDGE_BASH="$(command -v bash)"
  fi
fi
"$BRIDGE_BASH" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1 || \
  smoke_fail "Bash 4+ interpreter not found (BASH4_BIN=${BASH4_BIN:-unset}); install homebrew bash"

[[ -f "$SIG_HELPER" ]] || smoke_fail "missing helper: $SIG_HELPER"

# ---------------------------------------------------------------------------
# T1 — base-signature helper unit checks.
# ---------------------------------------------------------------------------
smoke_log "T1: launch-cmd base-signature + stale predicate"

sig() { python3 "$SIG_HELPER" signature "$1"; }
stale_rc() { python3 "$SIG_HELPER" stale "$1" "$2"; printf '%s' "$?"; }
equal_rc() { python3 "$SIG_HELPER" equal "$1" "$2"; printf '%s' "$?"; }

# Resume-id rotation collapses to the same static base signature.
smoke_assert_eq \
  "$(sig 'claude --resume AAA --dangerously-skip-permissions --name a')" \
  "$(sig 'claude --resume BBB --dangerously-skip-permissions --name a')" \
  "T1: resume id rotation → identical base signature"

# A bare engine token is degenerate (empty signature → incomparable upstream).
smoke_assert_eq "" "$(sig 'claude')" "T1: bare claude → empty signature"

# Stale predicate exit codes.
# Bug case: OLD dynamic continue base vs NEW static base → STALE (0).
smoke_assert_eq "0" \
  "$(stale_rc 'claude --continue --name a' 'claude --dangerously-skip-permissions')" \
  "T1: continue-base vs static-base → stale(0)"
# Same launch, resume id rotated (recorded resolved vs current raw base) → 1.
smoke_assert_eq "1" \
  "$(stale_rc 'claude --resume AAA --dangerously-skip-permissions --name a' 'claude --dangerously-skip-permissions')" \
  "T1: resolved-static vs raw-static base → not stale(1)"
# Codex resume vs codex fresh, same base → not stale (1).
smoke_assert_eq "1" \
  "$(stale_rc 'codex resume ZZZ -c features.hooks=true --no-alt-screen' 'codex -c features.hooks=true --no-alt-screen')" \
  "T1: codex resume vs fresh same base → not stale(1)"
# Canonical-reorder same-launch (codex review #2063): the static-Claude builder
# emits `--dangerously-skip-permissions --name <a>` BEFORE the operator's
# --model/--effort extras, so the recorded resolved cmd does not preserve the
# raw roster base's authored order. Containment must be order-independent
# (multiset subset) — an ordered-subsequence test would FALSE-RETIRE this real
# same-launch crash. recorded=resolved-canonical vs current=raw-authored-order.
smoke_assert_eq "1" \
  "$(stale_rc 'claude --resume AAA --dangerously-skip-permissions --name a --model opus --effort high' 'claude --model opus --effort high --dangerously-skip-permissions')" \
  "T1: canonical-reorder same-launch → not stale(1) [#2063 false-retire regression]"
# Empty current (dynamic, no roster base) → incomparable (2), keep alarming.
smoke_assert_eq "2" \
  "$(stale_rc 'claude --continue --name a' '')" \
  "T1: empty current → incomparable(2)"
# Cross-engine → incomparable (2).
smoke_assert_eq "2" \
  "$(stale_rc 'claude --dangerously-skip-permissions --name a' 'codex -c features.hooks=true --no-alt-screen')" \
  "T1: cross-engine → incomparable(2)"

# EQUAL mode — symmetric raw-base-vs-raw-base (the PREFERRED daemon path,
# CRASH_LAUNCH_CMD_RAW vs current roster base). Catches add/remove/change of a
# base flag in BOTH directions (the resolved-vs-raw `stale` mode cannot).
smoke_assert_eq "1" \
  "$(equal_rc 'claude --dangerously-skip-permissions' 'claude --dangerously-skip-permissions')" \
  "T1: equal — identical base → not stale(1)"
smoke_assert_eq "1" \
  "$(equal_rc 'claude --model opus --dangerously-skip-permissions' 'claude --dangerously-skip-permissions --model opus')" \
  "T1: equal — reordered same base → not stale(1)"
# CODEX r2 false-not-stale: a REMOVED base flag must be STALE (the asymmetric
# containment missed this; the symmetric equal compare catches it).
smoke_assert_eq "0" \
  "$(equal_rc 'claude --dangerously-skip-permissions --model opus' 'claude --dangerously-skip-permissions')" \
  "T1: equal — removed --model base flag → stale(0) [#2063 r2]"
smoke_assert_eq "0" \
  "$(equal_rc 'claude --dangerously-skip-permissions' 'claude --dangerously-skip-permissions --model opus')" \
  "T1: equal — added --model base flag → stale(0)"
smoke_assert_eq "0" \
  "$(equal_rc 'claude --dangerously-skip-permissions --model opus' 'claude --dangerously-skip-permissions --model sonnet')" \
  "T1: equal — changed model value → stale(0)"
smoke_assert_eq "2" \
  "$(equal_rc '' 'claude --dangerously-skip-permissions')" \
  "T1: equal — empty recorded raw → incomparable(2)"
smoke_log "T1 PASS"

# ---------------------------------------------------------------------------
# Extract the production daemon crash path + the state-lib predicate so the
# smoke runs the SAME code path the daemon does.
# ---------------------------------------------------------------------------
DAEMON_FUNCS="$SMOKE_TMP_ROOT/daemon-funcs.sh"
{
  awk '
    /^process_crash_reports\(\) \{/   { capture=1 }
    /^daemon_source_state_file\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$REPO_ROOT/bridge-daemon.sh"
} >"$DAEMON_FUNCS"

STATE_FUNCS="$SMOKE_TMP_ROOT/state-funcs.sh"
{
  awk '
    /^bridge_agent_crash_report_file\(\) \{/        { capture=1 }
    /^bridge_agent_crash_report_body_file\(\) \{/   { capture=1 }
    /^bridge_agent_crash_tail_file\(\) \{/          { capture=1 }
    /^bridge_agent_crash_state_file\(\) \{/         { capture=1 }
    /^bridge_agent_clear_crash_report\(\) \{/       { capture=1 }
    /^bridge_agent_crash_report_launch_stale\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$REPO_ROOT/lib/bridge-state.sh"
} >"$STATE_FUNCS"

for fn in process_crash_reports daemon_source_state_file; do
  grep -q "^${fn}() {" "$DAEMON_FUNCS" || smoke_fail "extract failed: $fn not in $DAEMON_FUNCS"
done
for fn in bridge_agent_crash_report_file bridge_agent_clear_crash_report \
          bridge_agent_crash_report_launch_stale; do
  grep -q "^${fn}() {" "$STATE_FUNCS" || smoke_fail "extract failed: $fn not in $STATE_FUNCS"
done

# Shared driver preamble: the daemon crash path needs report.env + the roster
# launch map for the agent under test. The harness stubs everything the crash
# loop touches that is NOT under test, then seeds report.env (CRASH_LAUNCH_CMD
# = recorded resolved; CRASH_LAUNCH_CMD_RAW = recorded roster base, omitted when
# <recorded_raw> is the empty string to simulate a LEGACY pre-fix report) and
# the CURRENT roster base in the launch map.
#
# write_driver <out> <recorded_resolved> <current_raw_base> <trailer> [<recorded_raw>]
write_crash_driver() {
  local out="$1" recorded="$2" raw_base="$3" trailer="$4" recorded_raw="${5:-}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'export BRIDGE_STATE_DIR="%s"\n' "$BRIDGE_STATE_DIR"
    printf 'export BRIDGE_SCRIPT_DIR="%s"\n' "$REPO_ROOT"
    printf 'export BRIDGE_ADMIN_AGENT_ID="admin"\n'
    printf 'AUDIT_OUT="%s/audit.log"\n' "$SMOKE_TMP_ROOT"
    # Roster: the agent under test + admin so the crash loop iterates it.
    printf 'declare -gA BRIDGE_AGENT_LAUNCH_CMD=()\n'
    printf 'BRIDGE_AGENT_LAUNCH_CMD[%s]=%q\n' "$AGENT" "$raw_base"
    printf 'declare -ga BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
    # Stub the lib surface the crash path + predicate depend on but that is
    # not under test. Real functions sourced below override only the targets.
    # Stub the runtime-state-dir resolver to a temp tree (the real one pulls
    # in iso-v2 / idle-marker-dir resolution that is irrelevant here).
    printf 'bridge_agent_runtime_state_dir() { printf "%%s/agents/%%s/runtime" "$BRIDGE_STATE_DIR" "$1"; }\n'
    printf 'bridge_var_is_assoc() { declare -p "$1" 2>/dev/null | grep -q "declare -[A-Za-z]*A"; }\n'
    printf 'bridge_agent_launch_cmd_raw() { printf "%%s" "${BRIDGE_AGENT_LAUNCH_CMD[$1]-}"; }\n'
    printf 'bridge_redact_inline_env_secrets() { printf "%%s" "$1"; }\n'
    printf 'bridge_require_python() { :; }\n'
    printf 'bridge_resolve_script_dir_check() { return 0; }\n'
    printf 'bridge_agent_exists() { [[ "$1" == "%s" || "$1" == "admin" ]]; }\n' "$AGENT"
    printf 'bridge_agent_manual_stop_active() { return 1; }\n'
    printf 'bridge_agent_has_notify_transport() { return 0; }\n'
    printf 'bridge_notify_send() { printf "NOTIFY %%s\\n" "$*" >>"$AUDIT_OUT"; }\n'
    printf 'bridge_agent_crash_report_body_file() { printf "%%s/body-%%s.md" "%s" "$1"; }\n' "$SMOKE_TMP_ROOT"
    printf 'bridge_write_crash_report_body() { :; }\n'
    printf 'bridge_queue_cli() { printf ""; }\n'
    # bridge_audit_log: record action so the test can assert which path ran.
    printf 'bridge_audit_log() { printf "AUDIT %%s\\n" "$2" >>"$AUDIT_OUT"; }\n'
    printf 'source "%s"\n' "$STATE_FUNCS"
    printf 'source "%s"\n' "$DAEMON_FUNCS"
    # Seed report.env with the recorded (resolved) launch cmd. Mirrors the
    # writer: every value is printf %q at capture so the file is safely
    # sourceable. The %q quoting is computed HERE in the parent shell and the
    # already-quoted form is emitted literally into the driver, so there is no
    # fragile nested-printf escaping (a literal `%%q` would otherwise leak a
    # broken `CRASH_LAUNCH_CMD=%q` value into report.env).
    printf 'REPORT="$(bridge_agent_crash_report_file "%s")"\n' "$AGENT"
    printf 'mkdir -p "$(dirname "$REPORT")"\n'
    printf '{\n'
    printf '  printf "%%s\\n" %q\n' "CRASH_AGENT=$(printf '%q' "$AGENT")"
    printf '  printf "%%s\\n" %q\n' "CRASH_ENGINE=$(printf '%q' "claude")"
    printf '  printf "%%s\\n" %q\n' "CRASH_FAIL_COUNT=$(printf '%q' "5")"
    printf '  printf "%%s\\n" %q\n' "CRASH_EXIT_CODE=$(printf '%q' "1")"
    printf '  printf "%%s\\n" %q\n' "CRASH_LAUNCH_CMD=$(printf '%q' "$recorded")"
    # CRASH_LAUNCH_CMD_RAW: emitted only when a recorded raw base is provided.
    # An empty <recorded_raw> simulates a LEGACY pre-fix report (no RAW field),
    # exercising the predicate's resolved-cmd fallback path.
    if [[ -n "$recorded_raw" ]]; then
      printf '  printf "%%s\\n" %q\n' "CRASH_LAUNCH_CMD_RAW=$(printf '%q' "$recorded_raw")"
    fi
    printf '  printf "%%s\\n" %q\n' "CRASH_ERROR_HASH=$(printf '%q' "deadbeef")"
    printf '} >"$REPORT"\n'
    printf '%s\n' "$trailer"
  } >"$out"
}

# ---------------------------------------------------------------------------
# T2 — MISMATCHED launch base + healthy agent → auto-retire, no alarm.
# Recorded raw base = OLD base; current raw base = NEW base (symmetric `equal`
# path: the recorded CRASH_LAUNCH_CMD_RAW differs from the current roster base).
# ---------------------------------------------------------------------------
smoke_log "T2: mismatched launch base → report retired, no alarm churn"
DRIVER_T2="$SMOKE_TMP_ROOT/t2-driver.sh"
: >"$SMOKE_TMP_ROOT/audit.log"
write_crash_driver "$DRIVER_T2" \
  'claude --continue --name syrs-shop-dev' \
  'claude --dangerously-skip-permissions' \
  'process_crash_reports || true
REPORT2="$(bridge_agent_crash_report_file '"$AGENT"')"
[[ -f "$REPORT2" ]] && echo "REPORT_PRESENT" >>"$AUDIT_OUT" || echo "REPORT_RETIRED" >>"$AUDIT_OUT"' \
  'claude --continue'
"$BRIDGE_BASH" "$DRIVER_T2"

AUDIT_FILE="$SMOKE_TMP_ROOT/audit.log"
grep -q "REPORT_RETIRED" "$AUDIT_FILE" || smoke_fail "T2: report env file NOT retired on mismatch:
$(cat "$AUDIT_FILE")"
grep -q "AUDIT crash_report_retired_stale_launch_cmd" "$AUDIT_FILE" || \
  smoke_fail "T2: missing crash_report_retired_stale_launch_cmd audit:
$(cat "$AUDIT_FILE")"
if grep -q "crash_notified_origin\|crash_loop_report\|crash_loop_admin_alert\|NOTIFY" "$AUDIT_FILE"; then
  smoke_fail "T2: alarm/notify churn fired on a stale (mismatched) report:
$(cat "$AUDIT_FILE")"
fi
# Audit fires exactly once (single pass; report cleared so next sweep is a no-op).
retire_count="$(grep -c "AUDIT crash_report_retired_stale_launch_cmd" "$AUDIT_FILE")"
smoke_assert_eq "1" "$retire_count" "T2: stale-retire audit fires exactly once"
smoke_log "T2 PASS — stale report auto-retired, no alarm, audited once"

# ---------------------------------------------------------------------------
# T3 — MATCHING launch base → real crash detection preserved (alarm reached).
# Recorded raw base == current raw base (symmetric `equal` not-stale), so the
# guard does NOT retire and the alarm path runs.
# ---------------------------------------------------------------------------
# assert_alarm_preserved <audit-file> <label>: report stays + alarm path reached.
assert_alarm_preserved() {
  local audit_file="$1" label="$2"
  if grep -q "AUDIT crash_report_retired_stale_launch_cmd" "$audit_file"; then
    smoke_fail "$label: guard wrongly retired a MATCHING-base report (real crash detection regressed):
$(cat "$audit_file")"
  fi
  grep -q "REPORT_PRESENT" "$audit_file" || smoke_fail "$label: report env file unexpectedly removed on matching base:
$(cat "$audit_file")"
  grep -q "AUDIT crash_notified_origin\|NOTIFY" "$audit_file" || \
    smoke_fail "$label: alarm path NOT reached for a matching-base crash (real detection broken):
$(cat "$audit_file")"
}

smoke_log "T3: matching launch base → real crash detection preserved"
DRIVER_T3="$SMOKE_TMP_ROOT/t3-driver.sh"
: >"$SMOKE_TMP_ROOT/audit.log"
write_crash_driver "$DRIVER_T3" \
  'claude --resume AAA --dangerously-skip-permissions --name syrs-shop-dev --model opus' \
  'claude --dangerously-skip-permissions --model opus' \
  'process_crash_reports || true
REPORT3="$(bridge_agent_crash_report_file '"$AGENT"')"
[[ -f "$REPORT3" ]] && echo "REPORT_PRESENT" >>"$AUDIT_OUT" || echo "REPORT_RETIRED" >>"$AUDIT_OUT"' \
  'claude --dangerously-skip-permissions --model opus'
"$BRIDGE_BASH" "$DRIVER_T3"
assert_alarm_preserved "$SMOKE_TMP_ROOT/audit.log" "T3"
smoke_log "T3 PASS — matching-base crash still alarms (no regression)"

# ---------------------------------------------------------------------------
# T3b (codex review #2063 r2) — a base flag REMOVAL must be STALE. Recorded raw
# base = `claude --dangerously-skip-permissions --model opus`; current raw base
# dropped `--model opus`. The asymmetric resolved-vs-raw containment could NOT
# detect this (current ⊆ recorded), so the symmetric raw-vs-raw `equal` path is
# required — confirm it retires + no alarm.
# ---------------------------------------------------------------------------
smoke_log "T3b: removed base flag (raw symmetric) → stale, retired [#2063 r2]"
DRIVER_T3B="$SMOKE_TMP_ROOT/t3b-driver.sh"
: >"$SMOKE_TMP_ROOT/audit.log"
write_crash_driver "$DRIVER_T3B" \
  'claude --dangerously-skip-permissions --name syrs-shop-dev --model opus' \
  'claude --dangerously-skip-permissions' \
  'process_crash_reports || true
R="$(bridge_agent_crash_report_file '"$AGENT"')"
[[ -f "$R" ]] && echo "REPORT_PRESENT" >>"$AUDIT_OUT" || echo "REPORT_RETIRED" >>"$AUDIT_OUT"' \
  'claude --dangerously-skip-permissions --model opus'
"$BRIDGE_BASH" "$DRIVER_T3B"
T3B_FILE="$SMOKE_TMP_ROOT/audit.log"
grep -q "REPORT_RETIRED" "$T3B_FILE" || smoke_fail "T3b: removed-flag base change NOT retired (codex r2 false-not-stale regressed):
$(cat "$T3B_FILE")"
grep -q "AUDIT crash_report_retired_stale_launch_cmd" "$T3B_FILE" || smoke_fail "T3b: missing retire audit:
$(cat "$T3B_FILE")"
if grep -q "crash_notified_origin\|NOTIFY" "$T3B_FILE"; then
  smoke_fail "T3b: alarm fired on a removed-flag stale report:
$(cat "$T3B_FILE")"
fi
smoke_log "T3b PASS — base flag removal detected as stale (symmetric raw compare)"

# ---------------------------------------------------------------------------
# T3c (legacy fallback) — a pre-fix report.env has NO CRASH_LAUNCH_CMD_RAW. The
# predicate falls back to the recorded RESOLVED cmd vs the current raw base with
# the asymmetric fail-safe containment. A matching base must STILL ALARM (never
# false-retire a real same-launch crash on a legacy report).
# ---------------------------------------------------------------------------
smoke_log "T3c: legacy report (no RAW field) matching base → still alarms"
DRIVER_T3C="$SMOKE_TMP_ROOT/t3c-driver.sh"
: >"$SMOKE_TMP_ROOT/audit.log"
write_crash_driver "$DRIVER_T3C" \
  'claude --resume AAA --dangerously-skip-permissions --name syrs-shop-dev' \
  'claude --dangerously-skip-permissions' \
  'process_crash_reports || true
R="$(bridge_agent_crash_report_file '"$AGENT"')"
[[ -f "$R" ]] && echo "REPORT_PRESENT" >>"$AUDIT_OUT" || echo "REPORT_RETIRED" >>"$AUDIT_OUT"'
"$BRIDGE_BASH" "$DRIVER_T3C"
assert_alarm_preserved "$SMOKE_TMP_ROOT/audit.log" "T3c"
smoke_log "T3c PASS — legacy report matching base still alarms (resolved fallback fail-safe)"

# ---------------------------------------------------------------------------
# T4 — Part 2: ack-crash retires when healthy; clear-crash unconditional;
# ack-crash on a not-active agent keeps the report.
# ---------------------------------------------------------------------------
smoke_log "T4: ack-crash/clear-crash retire-when-healthy semantics"
DRIVER_T4="$SMOKE_TMP_ROOT/t4-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'export BRIDGE_STATE_DIR="%s"\n' "$BRIDGE_STATE_DIR"
  printf 'OUT="%s/t4.log"\n' "$SMOKE_TMP_ROOT"
  printf ': >"$OUT"\n'
  printf 'bridge_agent_runtime_state_dir() { printf "%%s/agents/%%s/runtime" "$BRIDGE_STATE_DIR" "$1"; }\n'
  printf 'source "%s"\n' "$STATE_FUNCS"
  # ACTIVE flag toggled per scenario via env.
  printf 'bridge_agent_is_active() { [[ "${ACTIVE:-0}" == "1" ]]; }\n'
  printf 'seed() {\n'
  printf '  local R; R="$(bridge_agent_crash_report_file "$1")"\n'
  printf '  mkdir -p "$(dirname "$R")"\n'
  printf '  printf "CRASH_AGENT=%%s\\n" "$1" >"$R"\n'
  printf '}\n'
  # Replicate run_ack_crash's healthy-retire decision (the bridge-agent.sh
  # behavior under test) using the real clear primitive + is_active stub.
  printf 'ack_like() {\n'
  printf '  local a="$1"\n'
  printf '  if bridge_agent_is_active "$a"; then bridge_agent_clear_crash_report "$a"; printf "ack-retired\\n" >>"$OUT"; else printf "ack-kept\\n" >>"$OUT"; fi\n'
  printf '}\n'
  # clear-crash is unconditional.
  printf 'clear_like() { bridge_agent_clear_crash_report "$1"; printf "clear-retired\\n" >>"$OUT"; }\n'
  printf 'present() { [[ -f "$(bridge_agent_crash_report_file "$1")" ]] && printf "present\\n" >>"$OUT" || printf "retired\\n" >>"$OUT"; }\n'
  # Scenario A: healthy → ack retires.
  printf 'seed "%s"; ACTIVE=1 ack_like "%s"; present "%s"\n' "$AGENT" "$AGENT" "$AGENT"
  # Scenario B: NOT active → ack keeps the report (evidence).
  printf 'seed "%s"; ACTIVE=0 ack_like "%s"; present "%s"\n' "$AGENT" "$AGENT" "$AGENT"
  # Scenario C: clear-crash retires regardless of active state.
  printf 'ACTIVE=0 clear_like "%s"; present "%s"\n' "$AGENT" "$AGENT"
} >"$DRIVER_T4"
"$BRIDGE_BASH" "$DRIVER_T4"
# Expected sequence: ack-retired, retired, ack-kept, present, clear-retired, retired
mapfile -t t4_lines <"$SMOKE_TMP_ROOT/t4.log"
smoke_assert_eq "ack-retired" "${t4_lines[0]:-}" "T4: healthy ack retires"
smoke_assert_eq "retired"     "${t4_lines[1]:-}" "T4: report gone after healthy ack"
smoke_assert_eq "ack-kept"    "${t4_lines[2]:-}" "T4: not-active ack keeps report"
smoke_assert_eq "present"     "${t4_lines[3]:-}" "T4: report kept after not-active ack"
smoke_assert_eq "clear-retired" "${t4_lines[4]:-}" "T4: clear-crash retires"
smoke_assert_eq "retired"     "${t4_lines[5]:-}" "T4: report gone after clear-crash"
smoke_log "T4 PASS — ack-when-healthy retires, ack-when-down keeps, clear-crash unconditional"

# Confirm the production CLI wiring exists (verb dispatch + healthy-retire).
grep -F -q "clear-crash)" "$REPO_ROOT/bridge-agent.sh" || \
  smoke_fail "T4: clear-crash verb not wired into bridge-agent.sh dispatch"
grep -F -q "bridge_agent_is_active" "$REPO_ROOT/bridge-agent.sh" || \
  smoke_fail "T4: run_ack_crash healthy-retire (bridge_agent_is_active) missing in bridge-agent.sh"

# ---------------------------------------------------------------------------
# T5 (mutation/teeth) — force the Part-1 predicate to "never stale" and confirm
# the SAME mismatched report.env re-alarms. Proves the guard (not some other
# happenstance) is what stops the churn — the smoke is non-vacuous.
# ---------------------------------------------------------------------------
smoke_log "T5 (mutation): guard disabled → mismatched report re-alarms"
DRIVER_T5="$SMOKE_TMP_ROOT/t5-driver.sh"
: >"$SMOKE_TMP_ROOT/audit.log"
write_crash_driver "$DRIVER_T5" \
  'claude --continue --name syrs-shop-dev' \
  'claude --dangerously-skip-permissions' \
  '# MUTATION: neuter the staleness guard (revert Part 1).
bridge_agent_crash_report_launch_stale() { return 1; }
process_crash_reports || true' \
  'claude --continue'
"$BRIDGE_BASH" "$DRIVER_T5"
T5_FILE="$SMOKE_TMP_ROOT/audit.log"
if ! grep -q "AUDIT crash_notified_origin\|NOTIFY" "$T5_FILE"; then
  smoke_fail "T5 (mutation): with the guard disabled the mismatched report did NOT re-alarm — the T2/T3 smoke is VACUOUS:
$(cat "$T5_FILE")"
fi
if grep -q "AUDIT crash_report_retired_stale_launch_cmd" "$T5_FILE"; then
  smoke_fail "T5 (mutation): retire audit fired even with the guard neutered — mutation did not take:
$(cat "$T5_FILE")"
fi
smoke_log "T5 (mutation) PASS — guard disabled → mismatched report re-alarms (smoke is non-vacuous)"

# ---------------------------------------------------------------------------
# T6 (codex review #2063 r3) — cross-iteration leak. The writer emits
# CRASH_AGENT FIRST, so a TRUNCATED report.env (interrupted/partial flush) can
# be a valid sourceable file with ONLY CRASH_AGENT set. If the daemon does not
# sanitize the full CRASH_* family before sourcing, agent B's truncated report
# inherits agent A's CRASH_LAUNCH_CMD / CRASH_LAUNCH_CMD_RAW from the prior loop
# iteration and is FALSELY retired. Drive the real process_crash_reports over
# TWO agents: A = a stale (mismatched) report that IS retired, then B = a
# truncated report (only CRASH_AGENT). B must NOT be retired (no leak) — its
# missing launch signal must keep it alarming (fail-safe).
# ---------------------------------------------------------------------------
smoke_log "T6 (leak): truncated report must not inherit prior agent's launch cmd [#2063 r3]"
AGENT_A="leak-stale-a"
AGENT_B="leak-truncated-b"
DRIVER_T6="$SMOKE_TMP_ROOT/t6-driver.sh"
: >"$SMOKE_TMP_ROOT/audit.log"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'export BRIDGE_STATE_DIR="%s"\n' "$BRIDGE_STATE_DIR"
  printf 'export BRIDGE_SCRIPT_DIR="%s"\n' "$REPO_ROOT"
  printf 'export BRIDGE_ADMIN_AGENT_ID="admin"\n'
  printf 'AUDIT_OUT="%s/audit.log"\n' "$SMOKE_TMP_ROOT"
  # A has a stale (mismatched) raw base vs its current roster base; B has a
  # current roster base but a TRUNCATED report (CRASH_AGENT only). Iteration
  # order A→B is what would leak A's CRASH_LAUNCH_CMD into B without sanitize.
  printf 'declare -gA BRIDGE_AGENT_LAUNCH_CMD=()\n'
  printf 'BRIDGE_AGENT_LAUNCH_CMD[%s]=%q\n' "$AGENT_A" 'claude --dangerously-skip-permissions'
  printf 'BRIDGE_AGENT_LAUNCH_CMD[%s]=%q\n' "$AGENT_B" 'claude --dangerously-skip-permissions'
  printf 'declare -ga BRIDGE_AGENT_IDS=("%s" "%s")\n' "$AGENT_A" "$AGENT_B"
  printf 'bridge_agent_runtime_state_dir() { printf "%%s/agents/%%s/runtime" "$BRIDGE_STATE_DIR" "$1"; }\n'
  printf 'bridge_var_is_assoc() { declare -p "$1" 2>/dev/null | grep -q "declare -[A-Za-z]*A"; }\n'
  printf 'bridge_agent_launch_cmd_raw() { printf "%%s" "${BRIDGE_AGENT_LAUNCH_CMD[$1]-}"; }\n'
  printf 'bridge_redact_inline_env_secrets() { printf "%%s" "$1"; }\n'
  printf 'bridge_require_python() { :; }\n'
  printf 'bridge_resolve_script_dir_check() { return 0; }\n'
  printf 'bridge_agent_exists() { case "$1" in %s|%s|admin) return 0;; *) return 1;; esac; }\n' "$AGENT_A" "$AGENT_B"
  printf 'bridge_agent_manual_stop_active() { return 1; }\n'
  printf 'bridge_agent_has_notify_transport() { return 0; }\n'
  printf 'bridge_notify_send() { printf "NOTIFY %%s\\n" "$1" >>"$AUDIT_OUT"; }\n'
  printf 'bridge_agent_crash_report_body_file() { printf "%%s/body-%%s.md" "%s" "$1"; }\n' "$SMOKE_TMP_ROOT"
  printf 'bridge_write_crash_report_body() { :; }\n'
  printf 'bridge_queue_cli() { printf ""; }\n'
  # Tag the retire audit with the agent so we can tell WHICH agent was retired.
  printf 'bridge_audit_log() { printf "AUDIT %%s %%s\\n" "$2" "$3" >>"$AUDIT_OUT"; }\n'
  printf 'source "%s"\n' "$STATE_FUNCS"
  printf 'source "%s"\n' "$DAEMON_FUNCS"
  # Seed A: full report, mismatched raw base (recorded raw `claude --continue`
  # vs current roster base `claude --dangerously-skip-permissions`) → stale.
  printf 'RA="$(bridge_agent_crash_report_file %q)"; mkdir -p "$(dirname "$RA")"\n' "$AGENT_A"
  printf '{\n'
  printf '  printf "%%s\\n" %q\n' "CRASH_AGENT=$(printf '%q' "$AGENT_A")"
  printf '  printf "%%s\\n" %q\n' "CRASH_LAUNCH_CMD=$(printf '%q' 'claude --continue --name leak-stale-a')"
  printf '  printf "%%s\\n" %q\n' "CRASH_LAUNCH_CMD_RAW=$(printf '%q' 'claude --continue')"
  printf '  printf "%%s\\n" %q\n' "CRASH_ERROR_HASH=$(printf '%q' "aaaa")"
  printf '} >"$RA"\n'
  # Seed B: TRUNCATED — only CRASH_AGENT (simulates an interrupted write).
  printf 'RB="$(bridge_agent_crash_report_file %q)"; mkdir -p "$(dirname "$RB")"\n' "$AGENT_B"
  printf '{\n'
  printf '  printf "%%s\\n" %q\n' "CRASH_AGENT=$(printf '%q' "$AGENT_B")"
  printf '} >"$RB"\n'
  printf 'process_crash_reports || true\n'
  printf '[[ -f "$RA" ]] && echo "A_PRESENT" >>"$AUDIT_OUT" || echo "A_RETIRED" >>"$AUDIT_OUT"\n'
  printf '[[ -f "$RB" ]] && echo "B_PRESENT" >>"$AUDIT_OUT" || echo "B_RETIRED" >>"$AUDIT_OUT"\n'
} >"$DRIVER_T6"
"$BRIDGE_BASH" "$DRIVER_T6"
T6_FILE="$SMOKE_TMP_ROOT/audit.log"
# A (genuinely stale) IS retired.
grep -q "A_RETIRED" "$T6_FILE" || smoke_fail "T6: agent A's stale report was NOT retired (setup sanity):
$(cat "$T6_FILE")"
# B (truncated, missing launch signal) must NOT be retired — no leak from A.
grep -q "B_PRESENT" "$T6_FILE" || smoke_fail "T6: agent B's TRUNCATED report was falsely retired — CRASH_LAUNCH_CMD leaked from agent A across the loop (codex r3 cross-iteration leak):
$(cat "$T6_FILE")"
if grep -q "AUDIT crash_report_retired_stale_launch_cmd $AGENT_B" "$T6_FILE"; then
  smoke_fail "T6: a stale-retire audit fired for the truncated agent B (leak):
$(cat "$T6_FILE")"
fi
smoke_log "T6 PASS — truncated report keeps alarming; no cross-iteration launch-cmd leak"

smoke_log "OK $SMOKE_NAME"
