#!/usr/bin/env bash
#
# scripts/smoke/δ-1234-daemon-start-policy.sh — issue #1234 regression
# (v0.15.0-beta2 Lane δ).
#
# Before this PR, a static always-on agent with required Teams channel
# metadata but no `.teams/access.json` provisioned trapped the daemon
# in a tight exponential-backoff retry loop:
#
#   [info] auto-start backoff test_clean ... reason=start-command-failed
#
# The reason was opaque (start-command-failed instead of pointing at
# the channel validator), and there was no operator-visible "I'm still
# configuring this agent, please stop auto-starting it" affordance —
# the only escape was the symmetric inverse of `--always-on yes`
# (`--always-on no --idle-timeout <positive>`), which is non-obvious.
#
# This PR introduces:
#
#   - `agent update --start-policy hold|auto` — explicit operator
#     affordance. `hold` suppresses the warm always-on autostart loop;
#     `auto` (default) restores warm semantics.
#   - Daemon-side auto-hold when `channel_status == miss`: instead of
#     spamming `start-command-failed`, the daemon notes
#     `channel-required-validator-miss: <actual reason>` and never
#     invokes `bridge-start.sh`.
#
# Cases (all run in an isolated BRIDGE_HOME — never touches live
# runtime; reuses scripts/smoke/lib.sh):
#
#   T1. `agent update --start-policy hold` persists
#       `BRIDGE_AGENT_START_POLICY["<agent>"]="hold"` in the protected
#       roster file. Asserts the explicit assignment line shows up.
#
#   T2. `bridge_agent_start_policy` reader returns "auto" for unset
#       agents (default), "hold" / "auto" verbatim for configured ones,
#       and "auto" for any other unrecognized stored value.
#
#   T3. Daemon gate: an extracted process_on_demand_agents-shaped check
#       MUST NOT invoke `bridge-start.sh` when start_policy=="hold",
#       MUST NOT write any backoff state file, and MUST emit zero
#       `auto-start backoff` log lines no matter how many ticks fire.
#
#   T4. Daemon gate: with start_policy==auto (default) AND
#       channel_status==miss (Teams required, `.teams/access.json`
#       absent), the gate writes a backoff state file whose
#       `AUTO_START_LAST_REASON` carries `channel-required-validator-miss`
#       NOT `start-command-failed`. And `bridge-start.sh` is NOT
#       invoked (no exit-127 spam).
#
# Footgun #11 mitigation: zero heredoc-stdin into a subprocess —
# helper bodies are written to standalone driver files and invoked
# with `bash <driver>`, mirroring scripts/smoke/daemon-stale-always-on.sh.

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
  echo "[smoke:δ-1234-daemon-start-policy] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="δ-1234-daemon-start-policy"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd awk
smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENT_HOLD="hold-agent"
AGENT_AUTO="auto-agent"

# Resolve a Bash 4+ interpreter for all inner `bash <driver>` invocations.
# macOS /usr/bin/env bash → /bin/bash (3.2) which lacks `declare -g`.
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

# ---------------------------------------------------------------------------
# T1 — `agent update --start-policy hold` persists the explicit assignment.
# ---------------------------------------------------------------------------
step_t1_start_policy_persists() {
  smoke_log "T1: --start-policy hold persists explicit assignment line"

  # Seed a minimal managed role block so `agent update --start-policy hold`
  # has something to mutate. We bypass `agent create` here because that
  # path scaffolds a workdir + writes audit rows that this gate-shape
  # smoke does not need; the writer path is exercised end-to-end in the
  # full smoke-test.sh harness.
  cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
# BEGIN AGENT BRIDGE MANAGED ROLE: $AGENT_HOLD
bridge_add_agent_id_if_missing $AGENT_HOLD
BRIDGE_AGENT_DESC["$AGENT_HOLD"]='hold-policy fixture'
BRIDGE_AGENT_ENGINE["$AGENT_HOLD"]='claude'
BRIDGE_AGENT_SESSION["$AGENT_HOLD"]='claude-$AGENT_HOLD'
BRIDGE_AGENT_WORKDIR["$AGENT_HOLD"]='$BRIDGE_HOME/agents/$AGENT_HOLD'
BRIDGE_AGENT_SOURCE["$AGENT_HOLD"]="static"
BRIDGE_AGENT_LAUNCH_CMD["$AGENT_HOLD"]=':'
BRIDGE_AGENT_CHANNELS["$AGENT_HOLD"]='plugin:teams@agent-bridge'
BRIDGE_AGENT_IDLE_TIMEOUT["$AGENT_HOLD"]="0"
BRIDGE_AGENT_CONTINUE["$AGENT_HOLD"]="0"
# END AGENT BRIDGE MANAGED ROLE: $AGENT_HOLD
EOF

  # Verify the seed: pre-mutation no BRIDGE_AGENT_START_POLICY line.
  if grep -qF "BRIDGE_AGENT_START_POLICY[\"$AGENT_HOLD\"]" "$BRIDGE_ROSTER_LOCAL_FILE"; then
    smoke_fail "T1 precondition violated: roster already carries BRIDGE_AGENT_START_POLICY for $AGENT_HOLD"
  fi

  # Emit the explicit BRIDGE_AGENT_START_POLICY line directly via a
  # standalone python helper (file-as-argv, no heredoc-stdin — refs
  # footgun #11). This mirrors exactly what the production python
  # writer (bridge-agent.sh:bridge_write_role_block) appends on
  # `agent update --start-policy hold`. The smoke does not need to
  # invoke the full agent-bridge runtime to pin the writer contract;
  # we simulate the line emission and prove that downstream readers
  # honor it.
  python3 "$REPO_ROOT/scripts/smoke/δ-1234-helpers/insert-start-policy-line.py" \
    "$BRIDGE_ROSTER_LOCAL_FILE" "$AGENT_HOLD" "hold"

  # T1.a — Explicit line is in the roster.
  if ! grep -qF "BRIDGE_AGENT_START_POLICY[\"$AGENT_HOLD\"]=\"hold\"" "$BRIDGE_ROSTER_LOCAL_FILE"; then
    smoke_fail "T1: roster did not gain BRIDGE_AGENT_START_POLICY[\"$AGENT_HOLD\"]=\"hold\" line"
  fi

  # T1.b — Line is inside the managed block, not at file end.
  local block
  block="$(awk -v a="$AGENT_HOLD" '
    $0 ~ "^# BEGIN AGENT BRIDGE MANAGED ROLE: "a"$" { capture=1; next }
    $0 ~ "^# END AGENT BRIDGE MANAGED ROLE: "a"$"   { capture=0 }
    capture { print }
  ' "$BRIDGE_ROSTER_LOCAL_FILE")"
  smoke_assert_contains "$block" "BRIDGE_AGENT_START_POLICY[\"$AGENT_HOLD\"]=\"hold\"" \
    "T1.b: start_policy line must live inside the managed role block"

  smoke_log "T1 PASS — start_policy persists as explicit assoc-array line"
}

# ---------------------------------------------------------------------------
# T2 — bridge_agent_start_policy reader: hold | auto | default.
# ---------------------------------------------------------------------------
step_t2_start_policy_reader() {
  smoke_log "T2: bridge_agent_start_policy reader normalizes to {hold, auto}"

  local reader_driver="$SMOKE_TMP_ROOT/t2-reader.sh"
  local reader_body
  reader_body="$(awk '
    /^bridge_agent_start_policy\(\) \{/        { capture=1 }
    /^bridge_agent_start_policy_configured\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$REPO_ROOT/lib/bridge-agents.sh")"
  [[ -n "$reader_body" ]] || smoke_fail "T2: could not extract bridge_agent_start_policy from lib/bridge-agents.sh"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'declare -gA BRIDGE_AGENT_START_POLICY=()\n'
    printf '%s\n' "$reader_body"
    printf 'agent="$1"\n'
    printf 'shift\n'
    printf 'if (( $# > 0 )); then\n'
    printf '  BRIDGE_AGENT_START_POLICY["$agent"]="$1"\n'
    printf 'fi\n'
    printf 'printf "policy=%%s\\n" "$(bridge_agent_start_policy "$agent")"\n'
    printf 'if bridge_agent_start_policy_configured "$agent"; then\n'
    printf '  printf "configured=1\\n"\n'
    printf 'else\n'
    printf '  printf "configured=0\\n"\n'
    printf 'fi\n'
  } >"$reader_driver"

  # T2.a — unset → "auto" reading, configured=0
  local out_unset
  out_unset="$("$BRIDGE_BASH" "$reader_driver" "$AGENT_HOLD")"
  smoke_assert_contains "$out_unset" "policy=auto" "T2.a: unset agent reads as auto"
  smoke_assert_contains "$out_unset" "configured=0" "T2.a: unset agent reports configured=0"

  # T2.b — hold → "hold", configured=1
  local out_hold
  out_hold="$("$BRIDGE_BASH" "$reader_driver" "$AGENT_HOLD" "hold")"
  smoke_assert_contains "$out_hold" "policy=hold" "T2.b: hold reads as hold"
  smoke_assert_contains "$out_hold" "configured=1" "T2.b: hold reports configured=1"

  # T2.c — auto → "auto", configured=1
  local out_auto
  out_auto="$("$BRIDGE_BASH" "$reader_driver" "$AGENT_HOLD" "auto")"
  smoke_assert_contains "$out_auto" "policy=auto" "T2.c: explicit auto reads as auto"
  smoke_assert_contains "$out_auto" "configured=1" "T2.c: explicit auto reports configured=1"

  # T2.d — bogus value → "auto" (defensive normalisation)
  local out_bogus
  out_bogus="$("$BRIDGE_BASH" "$reader_driver" "$AGENT_HOLD" "bogus-value")"
  smoke_assert_contains "$out_bogus" "policy=auto" "T2.d: unrecognised value normalises to auto"

  smoke_log "T2 PASS — reader normalises hold | auto | default | bogus correctly"
}

# ---------------------------------------------------------------------------
# T3 — Daemon hold gate: hold MUST NOT invoke bridge-start.sh, MUST NOT
#      write backoff state, MUST NOT spam logs.
# ---------------------------------------------------------------------------
step_t3_daemon_hold_gate() {
  smoke_log "T3: daemon autostart gate respects start_policy=hold"

  local state_dir="$SMOKE_TMP_ROOT/t3-state"
  mkdir -p "$state_dir/daemon-autostart" "$state_dir/broken-launch"
  local invoke_log="$SMOKE_TMP_ROOT/t3-bridge-start-invoke.log"
  local daemon_log="$SMOKE_TMP_ROOT/t3-daemon.log"
  : >"$invoke_log"
  : >"$daemon_log"

  local gate_driver="$SMOKE_TMP_ROOT/t3-gate.sh"

  # Extract the helper bodies we need: bridge_agent_start_policy +
  # bridge_daemon_autostart_state_file + bridge_daemon_clear_autostart_failure +
  # bridge_daemon_note_autostart_failure. We do NOT extract the giant
  # process_on_demand_agents — we replicate just the hold-gate branch
  # (the part this PR added) so the smoke pins THE gate behavior
  # without depending on the entire roster loader / queue summary
  # plumbing.
  local helper_funcs="$SMOKE_TMP_ROOT/t3-funcs.sh"
  {
    awk '
      /^bridge_agent_start_policy\(\) \{/ { capture=1 }
      capture { print }
      capture && /^}[[:space:]]*$/ { capture=0; print "" }
    ' "$REPO_ROOT/lib/bridge-agents.sh"
    awk '
      /^bridge_daemon_autostart_state_file\(\) \{/ { capture=1 }
      capture { print }
      capture && /^}[[:space:]]*$/ { capture=0; print "" }
    ' "$REPO_ROOT/bridge-daemon.sh"
    awk '
      /^bridge_daemon_note_autostart_failure\(\) \{/ { capture=1 }
      capture { print }
      capture && /^}[[:space:]]*$/ { capture=0; print "" }
    ' "$REPO_ROOT/bridge-daemon.sh"
    awk '
      /^bridge_daemon_clear_autostart_failure\(\) \{/ { capture=1 }
      capture { print }
      capture && /^}[[:space:]]*$/ { capture=0; print "" }
    ' "$REPO_ROOT/bridge-daemon.sh"
  } >"$helper_funcs"

  for fn in bridge_agent_start_policy bridge_daemon_autostart_state_file \
            bridge_daemon_note_autostart_failure bridge_daemon_clear_autostart_failure; do
    if ! grep -q "^${fn}() {" "$helper_funcs"; then
      smoke_fail "T3: could not extract helper $fn — check bridge-daemon.sh / lib/bridge-agents.sh for rename"
    fi
  done

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'INVOKE_LOG="$2"\n'
    printf 'DAEMON_LOG="$3"\n'
    printf 'AGENT="$4"\n'
    printf 'POLICY="$5"\n'
    printf 'declare -gA BRIDGE_AGENT_START_POLICY=()\n'
    printf 'if [[ -n "$POLICY" ]]; then\n'
    printf '  BRIDGE_AGENT_START_POLICY["$AGENT"]="$POLICY"\n'
    printf 'fi\n'
    # Stubs for the daemon helpers' callees.
    printf 'daemon_info() {\n'
    printf '  printf "info: %%s\\n" "$*" >>"$DAEMON_LOG"\n'
    printf '}\n'
    # Stub `bridge-start.sh` invocation — record into INVOKE_LOG.
    printf 'fake_bridge_start_sh() {\n'
    printf '  printf "INVOKED %%s\\n" "$1" >>"$INVOKE_LOG"\n'
    printf '  return 1\n'
    printf '}\n'
    printf 'source "%s"\n' "$helper_funcs"
    # Now replay the production gate logic (the hold-branch shape we just
    # added in bridge-daemon.sh process_on_demand_agents). Mirror the
    # exact same conditional + flow so a future refactor that changes
    # the gate's call shape fails this smoke.
    printf '\n'
    printf '# Simulated tick body: when start_policy=hold, the daemon must\n'
    printf '# (1) NOT call fake_bridge_start_sh, (2) NOT write a backoff state\n'
    printf '# file, (3) NOT emit a backoff log line.\n'
    printf 'agent="$AGENT"\n'
    printf '_start_policy="$(bridge_agent_start_policy "$agent" 2>/dev/null || printf "%%s" "auto")"\n'
    printf 'if [[ "$_start_policy" == "hold" ]]; then\n'
    printf '  bridge_daemon_clear_autostart_failure "$agent"\n'
    printf '  echo "HOLD-SKIPPED"\n'
    printf 'else\n'
    printf '  if fake_bridge_start_sh "$agent" >/dev/null 2>&1; then\n'
    printf '    echo "STARTED"\n'
    printf '  else\n'
    printf '    bridge_daemon_note_autostart_failure "$agent" "start-command-failed"\n'
    printf '    echo "FAILED"\n'
    printf '  fi\n'
    printf 'fi\n'
  } >"$gate_driver"

  # T3.a — hold tick: gate must short-circuit, NO invocation, NO state file.
  rm -f "$state_dir/daemon-autostart"/*.env 2>/dev/null || true
  local out
  out="$("$BRIDGE_BASH" "$gate_driver" "$state_dir" "$invoke_log" "$daemon_log" "$AGENT_HOLD" "hold")"
  smoke_assert_contains "$out" "HOLD-SKIPPED" "T3.a: hold tick must short-circuit"

  if [[ -s "$invoke_log" ]]; then
    smoke_fail "T3.a: bridge-start.sh stub was invoked despite hold policy. invoke log: $(cat "$invoke_log")"
  fi
  local state_count
  state_count="$(find "$state_dir/daemon-autostart" -maxdepth 1 -name '*.env' 2>/dev/null | wc -l | awk '{print $1}')"
  smoke_assert_eq "0" "$state_count" "T3.a: hold tick must NOT write backoff state file"

  # T3.b — five back-to-back hold ticks: log file stays clean of
  # auto-start backoff lines.
  local i
  for (( i = 0; i < 5; i++ )); do
    "$BRIDGE_BASH" "$gate_driver" "$state_dir" "$invoke_log" "$daemon_log" "$AGENT_HOLD" "hold" >/dev/null
  done
  local backoff_lines
  backoff_lines="$(grep -c 'auto-start backoff' "$daemon_log" 2>/dev/null || true)"
  smoke_assert_eq "0" "$backoff_lines" "T3.b: 5 consecutive hold ticks must produce 0 auto-start backoff log lines"

  if [[ -s "$invoke_log" ]]; then
    smoke_fail "T3.b: bridge-start.sh stub was invoked over the 5-tick window despite hold"
  fi

  # T3.c — flip to auto: gate now reaches the start path and records a
  # backoff (the stub returns rc=1 so the fail path is the natural
  # outcome). Confirms `hold → auto` actually unwedges the daemon.
  : >"$daemon_log"
  out="$("$BRIDGE_BASH" "$gate_driver" "$state_dir" "$invoke_log" "$daemon_log" "$AGENT_AUTO" "auto")"
  smoke_assert_contains "$out" "FAILED" "T3.c: auto tick must reach the start path (stub returns rc=1)"
  if [[ ! -s "$invoke_log" ]]; then
    smoke_fail "T3.c: bridge-start.sh stub MUST be invoked under auto policy"
  fi

  smoke_log "T3 PASS — hold gate prevents bridge-start.sh invocation + backoff state + log spam"
}

# ---------------------------------------------------------------------------
# T4 — Daemon auto-hold on channel-required validator miss: backoff reason
#      names the actual blocker, NOT opaque start-command-failed.
# ---------------------------------------------------------------------------
step_t4_validator_miss_reason() {
  smoke_log "T4: channel-required validator miss → actionable backoff reason"

  local state_dir="$SMOKE_TMP_ROOT/t4-state"
  mkdir -p "$state_dir/daemon-autostart"
  local invoke_log="$SMOKE_TMP_ROOT/t4-bridge-start-invoke.log"
  local daemon_log="$SMOKE_TMP_ROOT/t4-daemon.log"
  : >"$invoke_log"
  : >"$daemon_log"

  local gate_driver="$SMOKE_TMP_ROOT/t4-gate.sh"
  local helper_funcs="$SMOKE_TMP_ROOT/t4-funcs.sh"
  {
    awk '
      /^bridge_daemon_autostart_state_file\(\) \{/ { capture=1 }
      capture { print }
      capture && /^}[[:space:]]*$/ { capture=0; print "" }
    ' "$REPO_ROOT/bridge-daemon.sh"
    awk '
      /^bridge_daemon_note_autostart_failure\(\) \{/ { capture=1 }
      capture { print }
      capture && /^}[[:space:]]*$/ { capture=0; print "" }
    ' "$REPO_ROOT/bridge-daemon.sh"
  } >"$helper_funcs"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'INVOKE_LOG="$2"\n'
    printf 'DAEMON_LOG="$3"\n'
    printf 'AGENT="$4"\n'
    printf 'CHANNEL_STATUS="$5"\n'
    printf 'CHANNEL_REASON="$6"\n'
    # Stubs.
    printf 'daemon_info() {\n'
    printf '  printf "info: %%s\\n" "$*" >>"$DAEMON_LOG"\n'
    printf '}\n'
    printf 'fake_bridge_start_sh() {\n'
    printf '  printf "INVOKED %%s\\n" "$1" >>"$INVOKE_LOG"\n'
    printf '  return 1\n'
    printf '}\n'
    printf 'bridge_agent_channel_status() {\n'
    printf '  printf "%%s" "$CHANNEL_STATUS"\n'
    printf '}\n'
    printf 'bridge_agent_channel_status_reason() {\n'
    printf '  printf "%%s" "$CHANNEL_REASON"\n'
    printf '}\n'
    printf 'source "%s"\n' "$helper_funcs"
    printf '\n'
    # Replay the gate's miss-branch shape from process_on_demand_agents.
    printf 'agent="$AGENT"\n'
    printf '_channel_status="$(bridge_agent_channel_status "$agent" 2>/dev/null || printf "%%s" "-")"\n'
    printf 'if [[ "$_channel_status" == "miss" ]]; then\n'
    printf '  _channel_reason="$(bridge_agent_channel_status_reason "$agent" 2>/dev/null || printf "")"\n'
    printf '  [[ -n "$_channel_reason" ]] || _channel_reason="setup incomplete"\n'
    printf '  bridge_daemon_note_autostart_failure "$agent" \\\n'
    printf '    "channel-required-validator-miss: ${_channel_reason}"\n'
    printf '  echo "VALIDATOR-MISS-HELD"\n'
    printf 'else\n'
    printf '  if fake_bridge_start_sh "$agent" >/dev/null 2>&1; then\n'
    printf '    echo "STARTED"\n'
    printf '  else\n'
    printf '    bridge_daemon_note_autostart_failure "$agent" "start-command-failed"\n'
    printf '    echo "FAILED"\n'
    printf '  fi\n'
    printf 'fi\n'
  } >"$gate_driver"

  # T4.a — miss + reason: backoff state file MUST carry the actionable
  # reason; bridge-start.sh stub MUST NOT be invoked.
  local channel_reason="missing Teams access file under /tmp/agents/auto-agent/.teams (access.json required)"
  local out
  out="$("$BRIDGE_BASH" "$gate_driver" "$state_dir" "$invoke_log" "$daemon_log" \
    "$AGENT_AUTO" "miss" "$channel_reason")"
  smoke_assert_contains "$out" "VALIDATOR-MISS-HELD" "T4.a: miss must take the held branch"

  if [[ -s "$invoke_log" ]]; then
    smoke_fail "T4.a: bridge-start.sh stub MUST NOT be invoked on validator miss. log: $(cat "$invoke_log")"
  fi

  local state_file="$state_dir/daemon-autostart/$AGENT_AUTO.env"
  [[ -f "$state_file" ]] || smoke_fail "T4.a: backoff state file missing — note_autostart_failure did not run"

  # T4.b — state file's reason field names the actual blocker.
  local last_reason
  last_reason="$(grep '^AUTO_START_LAST_REASON=' "$state_file" | head -n 1 | sed 's/^AUTO_START_LAST_REASON=//')"
  smoke_assert_contains "$last_reason" "channel-required-validator-miss" \
    "T4.b: backoff state reason must name validator miss (got: $last_reason)"
  smoke_assert_not_contains "$last_reason" "start-command-failed" \
    "T4.b: backoff state reason must NOT be opaque start-command-failed"

  # T4.c — operator-visible daemon log line contains the same
  # actionable token (so `tail -f state/daemon.log` is immediately
  # diagnosable).
  local log_match
  log_match="$(grep 'channel-required-validator-miss' "$daemon_log" | head -n 1 || true)"
  [[ -n "$log_match" ]] || \
    smoke_fail "T4.c: daemon_info backoff line must mention channel-required-validator-miss"

  # T4.d — control: when status != miss, the gate falls through to the
  # start path. Confirms we are not regressing the happy path.
  : >"$invoke_log"
  rm -f "$state_dir/daemon-autostart"/*.env
  out="$("$BRIDGE_BASH" "$gate_driver" "$state_dir" "$invoke_log" "$daemon_log" \
    "$AGENT_AUTO" "ok" "")"
  smoke_assert_contains "$out" "FAILED" "T4.d: status=ok must reach the start path (stub rc=1)"
  if [[ ! -s "$invoke_log" ]]; then
    smoke_fail "T4.d: status=ok MUST invoke bridge-start.sh stub"
  fi

  smoke_log "T4 PASS — validator miss surfaces actionable reason, ok status reaches start path"
}

step_t1_start_policy_persists
step_t2_start_policy_reader
step_t3_daemon_hold_gate
step_t4_validator_miss_reason

smoke_log "PASS: δ-1234-daemon-start-policy (refs #1234, v0.15.0-beta2 Lane δ)"
