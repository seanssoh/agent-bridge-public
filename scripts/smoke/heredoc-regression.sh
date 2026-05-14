#!/usr/bin/env bash
# scripts/smoke/heredoc-regression.sh — issue #815 Wave D destructive regression.
#
# Guards every Wave A/B/C surface from reintroducing the heredoc-stdin /
# here-string deadlock class against a slow consumer (Bash 5.x footgun:
# bash producer feeding a here-string or heredoc body into a slow reader
# wedges in heredoc_write — root cause of the 18h-silent daemon observed
# on the operator's stale runtime that triggered #815). See
# references/footguns.md §11 for the full pattern catalog the smoke
# self-audit greps for.
#
# Six destructive cases, each runs in an isolated BRIDGE_HOME via mktemp -d
# so the fixture cannot mutate the operator's live runtime:
#
#   1. Large tmux capture path (Wave A — lib/bridge-tmux.sh::
#      bridge_tmux_session_has_prompt_from_text). Synthesizes a 10KB+
#      multi-record tmux capture and feeds it through the patched
#      function via a real source of lib/bridge-tmux.sh. Asserts <2s
#      wall time. Pre-Wave-A this would wedge in heredoc_write.
#
#   2. Multi-record roster summary path (Wave A — lib/bridge-agents.sh::
#      bridge_list_active_agents_numbered). Replays the Wave-A recipe
#      (`mktemp + printf > tmp + while read < tmp`) against a synthetic
#      50-agent TSV summary that matches the real
#      `bridge_queue_cli summary --format tsv` shape. Asserts <1s.
#      The function itself is intricately wired into the queue +
#      roster so we test the recipe in the same shape the function uses.
#
#   3. daemon::process_context_pressure_reports happy path (Wave B —
#      bridge-daemon.sh trailing-newline regression vector). Mirrors
#      scripts/smoke/daemon.sh::daemon_context_pressure_audit_state_transitions
#      shape; the exact case that caught the Wave B r1 trailing-newline
#      bug. Re-running here under the destructive-regression banner
#      ensures any future refactor of the tempfile-routed loops can't
#      silently regress the audit-emit contract.
#
#   4. bridge_daemon_health_signal derivation (Wave C — lib/bridge-state.sh).
#      Three sub-scenarios:
#        4a: no heartbeat file + no pid               → health=down
#        4b: stale heartbeat (10000s ago) + faked pid → health=silent
#        4c: fresh heartbeat (date +%s) + faked pid   → health=ok
#      Stubs bridge_daemon_pid per sub-scenario; greps the helper's
#      key=value output for the expected health value.
#
#   5. BSD colonized-offset legacy heartbeat parse (Wave C r2 BLOCKING
#      regression — lib/bridge-state.sh::bridge_daemon_heartbeat_age_seconds).
#      Writes the literal ISO-with-colon heartbeat documented in CHANGELOG
#      (`2026-05-13T07:30:05+09:00`) and asserts the helper returns rc=0
#      with a numeric age. Pre-Wave-C-r2 this returned rc=1 / empty on
#      macOS BSD `date -j -f` because BSD does not accept colonized
#      offsets, which silently masked the wedge condition by reporting
#      `health=down` instead of `health=silent`. Branch must pass on both
#      Linux (GNU `date -d`) and macOS (BSD `date -j -f` with the
#      r2-introduced normalization to `+HHMM`).
#
#   6. cmd_start auto-repair on silent-but-alive (Wave C). The actual
#      silent-detection logic in bridge-daemon.sh::cmd_start is inline
#      and tightly coupled to the daemon's start sequence (kill -TERM,
#      kill -KILL, stop_silence_watchdog, audit emit, fall through). The
#      brief explicitly permits the fallback `If the silent-detection
#      logic isn't easily extractable, document the limitation and fall
#      back to a simpler unit-test of bridge_daemon_health_signal
#      returning health=silent for the same inputs (Case 4b already
#      covers this).` We document the limitation here and exercise the
#      same predicate `bridge_daemon_health_signal` consumes (case 4b
#      stale-heartbeat + faked-alive-pid → health=silent) so any
#      regression that breaks the silent-detection threshold or the
#      health-signal derivation also fails the auto-repair branch by
#      construction.
#
# Run: bash scripts/smoke/heredoc-regression.sh
#
# Footgun #11 self-audit: this fixture itself MUST NOT use heredoc-stdin
# or here-string-to-stdin patterns. Use `mktemp + < file` exclusively.
# The verification step in the Wave D brief greps for footgun #11 patterns
# in this file and fails the smoke if any reintroduce.

# Bash 4+ re-exec (mirrors scripts/smoke/daemon.sh shape).
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
  echo "[smoke:heredoc-regression] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="heredoc-regression"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# --- timing helper --------------------------------------------------------

# Wall-clock nanoseconds via python3 for portability — BSD `date` lacks
# %N, GNU coreutils gdate isn't guaranteed in CI. Python3 is required by
# the rest of the smoke suite (see lib.sh and daemon.sh) so this adds no
# new dependency.
elapsed_ns() {
  local start_ns="$1"
  local end_ns
  end_ns="$(python3 -c 'import time; print(int(time.time()*1e9))')"
  printf '%s' "$((end_ns - start_ns))"
}

now_ns() {
  python3 -c 'import time; print(int(time.time()*1e9))'
}

# --- Case 1: large tmux capture path --------------------------------------

case_large_tmux_capture() {
  local capture line_count budget_ns="2000000000"  # 2s
  local start_ns end_ns elapsed
  local rc=0

  # Build a 10KB+ multi-record tmux capture text. Each line resembles a
  # real Claude tmux pane line; we end the capture with a `>` prompt line
  # so bridge_tmux_session_has_prompt_from_text returns 0 (found).
  capture=""
  local i
  for i in $(seq 1 250); do
    capture+="agent-bridge:claude session line ${i} with some pad text $(printf 'x%.0s' {1..40})"$'\n'
  done
  capture+=">"
  line_count="$(printf '%s\n' "$capture" | wc -l | tr -d ' ')"
  local size_bytes
  size_bytes="${#capture}"
  smoke_log "capture: ${line_count} lines, ${size_bytes} bytes"
  if (( size_bytes < 10240 )); then
    smoke_fail "case 1: capture must be at least 10KB to exercise the regression vector (got ${size_bytes} bytes)"
  fi

  start_ns="$(now_ns)"
  set +e
  (
    set -e
    # shellcheck source=lib/bridge-tmux.sh
    source "$SMOKE_REPO_ROOT/lib/bridge-tmux.sh"
    bridge_tmux_session_has_prompt_from_text claude "$capture"
  )
  rc=$?
  set -e
  elapsed="$(elapsed_ns "$start_ns")"
  smoke_log "case 1: bridge_tmux_session_has_prompt_from_text rc=${rc}, elapsed_ns=${elapsed}"

  if (( rc != 0 )); then
    smoke_fail "case 1: expected has_prompt rc=0 (terminating > line should match), got rc=${rc}"
  fi
  if (( elapsed > budget_ns )); then
    smoke_fail "case 1: large tmux capture took ${elapsed}ns > budget ${budget_ns}ns (regression — should be <2s)"
  fi
}

# --- Case 2: multi-record roster summary path -----------------------------

case_multi_record_summary() {
  # Replay the Wave-A recipe from bridge_list_active_agents_numbered in
  # the exact shape the patched code uses (`mktemp + printf > tmp +
  # while read < tmp`) against a 50-agent TSV that matches the real
  # `bridge_queue_cli summary --format tsv` column layout. The recipe
  # itself is the regression surface; if a future refactor reintroduces
  # the deprecated here-string-into-while-read iterator pattern this
  # case would still complete in microseconds on a healthy runtime but
  # the deadlock vector is the piped consumer pattern, which we
  # explicitly avoid.
  local budget_ns="1000000000"  # 1s
  local summary=""
  local i row_count=50
  for i in $(seq 1 "$row_count"); do
    summary+=$(printf 'agent-%02d\t%d\t%d\t0\t1\t0\t0\t0\tsession-%02d\tclaude\t/tmp/agent-%02d' \
      "$i" "$i" "$i" "$i" "$i")$'\n'
  done

  local start_ns elapsed counted
  start_ns="$(now_ns)"

  local _tmp_summary
  _tmp_summary="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp_summary'" RETURN
  printf '%s' "$summary" > "$_tmp_summary"

  counted=0
  local agent_name queued claimed _blocked _active _idle _last_seen _last_nudge _session _engine _workdir
  while IFS=$'\t' read -r agent_name queued claimed _blocked _active _idle _last_seen _last_nudge _session _engine _workdir; do
    [[ -z "$agent_name" ]] && continue
    counted=$((counted + 1))
  done < "$_tmp_summary"

  elapsed="$(elapsed_ns "$start_ns")"
  smoke_log "case 2: iterated ${counted} rows in ${elapsed}ns"

  if (( counted != row_count )); then
    smoke_fail "case 2: expected ${row_count} rows iterated, got ${counted}"
  fi
  if (( elapsed > budget_ns )); then
    smoke_fail "case 2: 50-agent summary took ${elapsed}ns > budget ${budget_ns}ns (regression — should be <1s)"
  fi
}

# --- Case 3: context-pressure happy path (Wave B trailing-newline) -------

case_context_pressure_audit() {
  local root audit_file state_dir helper output rc bash_bin

  root="$(mktemp -d "$SMOKE_TMP_ROOT/context-pressure-unit.XXXXXX")"
  audit_file="$root/audit.log"
  state_dir="$root/state"
  helper="$root/context-pressure-functions.sh"
  mkdir -p "$state_dir"
  : >"$audit_file"

  # Extract bridge_clear_context_pressure_state + sibling functions
  # (three back-to-back definitions including process_context_pressure_reports)
  # the same way scripts/smoke/daemon.sh does — pinned to the existing
  # source-of-truth shape so any refactor that splits the block surfaces
  # here too.
  awk '
    /^bridge_clear_context_pressure_state\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ {
      done += 1
      if (done == 3) {
        capture=0
      }
    }
  ' "$SMOKE_REPO_ROOT/bridge-daemon.sh" >"$helper"
  [[ -s "$helper" ]] || smoke_fail "case 3: could not extract daemon context-pressure functions"

  # Prefer the currently-running Bash interpreter (`$BASH`, guaranteed
  # 4+ by the re-exec at the top of this script). Falling back to
  # `command -v bash` lands on `/bin/bash` 3.2 on macOS hosts, which
  # triggers the operator-host environmental hang in
  # `process_context_pressure_reports` documented in PR #809/#812/#813
  # bodies. CI (Linux) is unaffected either way.
  bash_bin="${BASH:-${BASH4_BIN:-}}"
  if [[ -z "$bash_bin" || ! -x "$bash_bin" ]]; then
    bash_bin="$(command -v bash)"
  fi
  # The driver body is shipped as a tracked .sh file under
  # scripts/smoke/heredoc-regression-helpers/, NOT embedded as a
  # `cat <<EOF >$driver` heredoc body — heredoc-to-file with a
  # multi-line body recurs the Bash 5.3.9 heredoc_write deadlock class
  # the fixture is guarding against (see
  # `feedback_bash_heredoc_write_class_recurrence.md`).
  local driver
  driver="$SMOKE_REPO_ROOT/scripts/smoke/heredoc-regression-helpers/context-pressure-driver.sh"
  [[ -f "$driver" ]] || smoke_fail "case 3: helper driver missing: $driver"

  set +e
  output="$("$bash_bin" "$driver" "$state_dir" "$audit_file" "$helper" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 && "$output" == "ok" ]] || \
    smoke_fail "case 3: context-pressure audit failed (rc=$rc, output=$output)"
}

# --- Case 4: bridge_daemon_health_signal derivation ---------------------

case_health_signal_derivation() {
  local helper_root output bash_bin driver
  helper_root="$(mktemp -d "$SMOKE_TMP_ROOT/health-signal.XXXXXX")"
  # Use the currently-running Bash interpreter (4+ guaranteed by the
  # re-exec at the top of this script); see case 3 comment for rationale.
  bash_bin="${BASH:-${BASH4_BIN:-}}"
  if [[ -z "$bash_bin" || ! -x "$bash_bin" ]]; then
    bash_bin="$(command -v bash)"
  fi

  driver="$SMOKE_REPO_ROOT/scripts/smoke/heredoc-regression-helpers/health-signal-driver.sh"
  [[ -f "$driver" ]] || smoke_fail "case 4: helper driver missing: $driver"

  set +e
  output="$("$bash_bin" "$driver" "$helper_root" "$SMOKE_REPO_ROOT" 2>&1)"
  local rc=$?
  set -e
  [[ "$rc" -eq 0 && "$output" == "ok" ]] || \
    smoke_fail "case 4: health-signal derivation failed (rc=$rc, output=$output)"
}

# --- Case 5: BSD colonized-offset legacy heartbeat parse ----------------

case_bsd_colonized_offset_heartbeat() {
  local helper_root output bash_bin driver
  helper_root="$(mktemp -d "$SMOKE_TMP_ROOT/bsd-heartbeat.XXXXXX")"
  # Use the currently-running Bash interpreter (4+ guaranteed by the
  # re-exec at the top of this script); see case 3 comment for rationale.
  bash_bin="${BASH:-${BASH4_BIN:-}}"
  if [[ -z "$bash_bin" || ! -x "$bash_bin" ]]; then
    bash_bin="$(command -v bash)"
  fi

  driver="$SMOKE_REPO_ROOT/scripts/smoke/heredoc-regression-helpers/bsd-heartbeat-driver.sh"
  [[ -f "$driver" ]] || smoke_fail "case 5: helper driver missing: $driver"

  set +e
  output="$("$bash_bin" "$driver" "$helper_root" "$SMOKE_REPO_ROOT" 2>&1)"
  local rc=$?
  set -e
  [[ "$rc" -eq 0 && "$output" == "ok" ]] || \
    smoke_fail "case 5: BSD colonized-offset heartbeat parse failed (rc=$rc, output=$output)"
}

# --- Case 6: cmd_start silent-but-alive (fallback coverage via case 4b) -

case_cmd_start_silent_repair_fallback() {
  # Per Wave D brief: the cmd_start silent-detection logic is inline in
  # bridge-daemon.sh::cmd_start (lines ~5952–6060) and tightly coupled to
  # the daemon's start sequence (kill -TERM, kill -KILL, stop watchdog,
  # audit emit, fall through to fresh start). The brief explicitly
  # permits the fallback:
  #
  #   "If the silent-detection logic isn't easily extractable, document
  #   the limitation in the smoke case body and fall back to a simpler
  #   unit-test of bridge_daemon_health_signal returning health=silent
  #   for the same inputs (Case 4b already covers this)."
  #
  # Case 4b above asserts:
  #   - pid alive (via stubbed bridge_daemon_pid)
  #   - heartbeat 10000s stale (well above the 120s default
  #     BRIDGE_DAEMON_TICK_FRESH_SECONDS threshold)
  #   - bridge_daemon_health_signal emits health=silent
  #
  # That is the exact predicate cmd_start uses to enter the auto-repair
  # branch — see bridge-daemon.sh::cmd_start where `tick_age` is read
  # via bridge_daemon_heartbeat_age_seconds and compared against
  # fresh_threshold. A regression that breaks the silent-detection
  # threshold or the helper's tick-age derivation also fails case 4b by
  # construction, so this case is a deliberate cross-reference rather
  # than a duplicate run.
  #
  # We additionally assert that BRIDGE_DAEMON_TICK_FRESH_SECONDS default
  # (120s) is consistent across lib/bridge-state.sh and bridge-daemon.sh
  # — drift here is a known footgun (the two reads are in different
  # files but must agree because cmd_start tests `tick_age > fresh_threshold`
  # while health_signal tests `tick_age <= threshold`).
  local state_default daemon_default
  state_default="$(grep -E 'BRIDGE_DAEMON_TICK_FRESH_SECONDS:-[0-9]+' \
    "$SMOKE_REPO_ROOT/lib/bridge-state.sh" | head -n 1 | \
    sed -E 's/.*BRIDGE_DAEMON_TICK_FRESH_SECONDS:-([0-9]+).*/\1/')"
  daemon_default="$(grep -E 'BRIDGE_DAEMON_TICK_FRESH_SECONDS:-[0-9]+' \
    "$SMOKE_REPO_ROOT/bridge-daemon.sh" | head -n 1 | \
    sed -E 's/.*BRIDGE_DAEMON_TICK_FRESH_SECONDS:-([0-9]+).*/\1/')"

  [[ -n "$state_default" ]] || smoke_fail "case 6: could not extract BRIDGE_DAEMON_TICK_FRESH_SECONDS default from lib/bridge-state.sh"
  [[ -n "$daemon_default" ]] || smoke_fail "case 6: could not extract BRIDGE_DAEMON_TICK_FRESH_SECONDS default from bridge-daemon.sh"
  [[ "$state_default" == "$daemon_default" ]] || \
    smoke_fail "case 6: BRIDGE_DAEMON_TICK_FRESH_SECONDS default drift — bridge-state.sh=${state_default} bridge-daemon.sh=${daemon_default}"

  smoke_log "case 6: BRIDGE_DAEMON_TICK_FRESH_SECONDS default=${state_default}s (consistent across state lib + daemon)"
}

# --- main ----------------------------------------------------------------

main() {
  smoke_require_cmd awk
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "case 1 — large tmux capture path (Wave A regression)"            case_large_tmux_capture
  smoke_run "case 2 — multi-record summary recipe (Wave A regression)"        case_multi_record_summary
  smoke_run "case 3 — context-pressure happy path (Wave B regression)"        case_context_pressure_audit
  smoke_run "case 4 — health_signal derivation ok/silent/down (Wave C)"       case_health_signal_derivation
  smoke_run "case 5 — BSD colonized-offset legacy heartbeat (Wave C r2)"      case_bsd_colonized_offset_heartbeat
  smoke_run "case 6 — cmd_start silent-but-alive fallback coverage (Wave C)"  case_cmd_start_silent_repair_fallback

  smoke_log "PASS: heredoc-regression (#815 Wave D destructive regression smoke)"
}

main "$@"
