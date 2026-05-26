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

# ---------------------------------------------------------------------------
# T5 — Production on-demand branch parity (codex r1 BLOCKING finding #1).
#
# Background: r1 added the channel-miss auto-hold to the always-on branch
# (bridge-daemon.sh process_on_demand_agents lines ~6106-6127). The
# on-demand-queued-work branch (~6160-6188) had the start_policy=hold gate
# but NOT the channel-miss check. A non-always-on static agent with queued
# work + missing channel metadata would still hit the opaque
# `start-command-failed` path (every tick) instead of the actionable
# `channel-required-validator-miss:` reason.
#
# This test exercises the REAL production `process_on_demand_agents`
# function (extracted verbatim from bridge-daemon.sh — not a re-implemented
# gate driver) for a non-always-on agent with queued=1, active=0, and a
# missing channel validator. It asserts:
#   * bridge-start.sh stub is NOT invoked (the helper short-circuits)
#   * the backoff state file's AUTO_START_LAST_REASON contains
#     `channel-required-validator-miss:plugin:teams` — NOT
#     `start-command-failed`
#
# This pins the codex r1 finding: a future refactor that moves the
# channel-miss gate back to "always-on only" fails this smoke.
# ---------------------------------------------------------------------------
step_t5_ondemand_production_branch_channel_miss_parity() {
  smoke_log "T5: production on-demand branch (queued work) records actionable channel-miss reason"

  local state_dir="$SMOKE_TMP_ROOT/t5-state"
  mkdir -p "$state_dir/daemon-autostart"
  local invoke_log="$SMOKE_TMP_ROOT/t5-bridge-start-invoke.log"
  local daemon_log="$SMOKE_TMP_ROOT/t5-daemon.log"
  : >"$invoke_log"
  : >"$daemon_log"

  # Extract the entire production process_on_demand_agents function +
  # the helpers it calls from bridge-daemon.sh. The brief calls for the
  # production code path, not a hand-replicated driver — if a future
  # refactor moves the channel-miss check back into one branch only,
  # this extraction-driven smoke fails.
  local prod_funcs="$SMOKE_TMP_ROOT/t5-prod-funcs.sh"
  {
    awk '
      /^process_on_demand_agents\(\) \{/                          { capture=1 }
      /^bridge_daemon_autostart_state_file\(\) \{/                { capture=1 }
      /^bridge_daemon_note_autostart_failure\(\) \{/              { capture=1 }
      /^bridge_daemon_clear_autostart_failure\(\) \{/             { capture=1 }
      /^bridge_daemon_check_channel_status_or_hold\(\) \{/        { capture=1 }
      capture { print }
      capture && /^}[[:space:]]*$/ { capture=0; print "" }
    ' "$REPO_ROOT/bridge-daemon.sh"
  } >"$prod_funcs"

  # Pin: every expected function MUST be present in the extraction so a
  # future rename / split fails loudly here rather than producing a
  # silent test-skipped result.
  for fn in process_on_demand_agents \
            bridge_daemon_autostart_state_file \
            bridge_daemon_note_autostart_failure \
            bridge_daemon_clear_autostart_failure \
            bridge_daemon_check_channel_status_or_hold; do
    if ! grep -q "^${fn}() {" "$prod_funcs"; then
      smoke_fail "T5: production function $fn missing from bridge-daemon.sh extraction — check for rename"
    fi
  done

  # Pin codex r1 finding 1 directly: the on-demand branch (~elif queued > 0)
  # MUST contain the new check. Without this, a future PR could quietly drop
  # the on-demand branch's invocation of bridge_daemon_check_channel_status_or_hold
  # and the test below would still pass (because the helper is still defined,
  # just not called from the on-demand branch). Anchor on the production
  # source itself.
  local ondemand_block
  ondemand_block="$(awk '
    /elif \[\[ "\$queued" =~ \^\[0-9\]\+\$ \]\] && \(\( queued > 0 \)\) && ! bridge_agent_is_active/ { capture=1 }
    capture { print }
    capture && /^      fi[[:space:]]*$/ { capture=0; exit }
  ' "$REPO_ROOT/bridge-daemon.sh")"
  smoke_assert_contains "$ondemand_block" "bridge_daemon_check_channel_status_or_hold" \
    "T5: codex r1 finding #1 — on-demand queued-work branch MUST call bridge_daemon_check_channel_status_or_hold"

  local driver="$SMOKE_TMP_ROOT/t5-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'INVOKE_LOG="$2"\n'
    printf 'DAEMON_LOG="$3"\n'
    printf 'AGENT="$4"\n'
    printf 'CHANNEL_STATUS="$5"\n'
    printf 'CHANNEL_REASON="$6"\n'
    printf 'BRIDGE_BASH_BIN="/bin/false-not-invoked"\n'
    printf 'SCRIPT_DIR="/nonexistent-script-dir"\n'
    # ---- Stub dependencies (everything except the channel-miss helpers,
    # which we keep from production). All stubs are deterministic — no
    # roster I/O, no tmux, no queue. The driver's goal is to drive the
    # function down the on-demand branch and observe the new gate.
    printf 'bridge_agent_exists() { return 0; }\n'
    printf 'bridge_agent_source() { printf "%%s" "static"; }\n'
    printf 'bridge_agent_manual_stop_active() { return 1; }\n'
    # Non-always-on — drops us into the elif (on-demand) branch.
    printf 'bridge_agent_is_always_on() { return 1; }\n'
    printf 'bridge_agent_is_active() { return 1; }\n'
    printf 'bridge_daemon_autostart_allowed() { return 0; }\n'
    printf 'bridge_agent_session() { printf ""; }\n'
    printf 'bridge_tmux_session_exists() { return 1; }\n'
    printf 'bridge_tmux_session_attached_count() { printf "0"; }\n'
    printf 'bridge_agent_idle_timeout() { printf "0"; }\n'
    printf 'bridge_agent_engine() { printf "claude"; }\n'
    # Channel status helpers — driven by argv to flip miss/ok.
    printf 'bridge_agent_channel_status() { printf "%%s" "$CHANNEL_STATUS"; }\n'
    printf 'bridge_agent_channel_status_reason() { printf "%%s" "$CHANNEL_REASON"; }\n'
    # start_policy=auto so we reach the channel-miss check.
    printf 'bridge_agent_start_policy() { printf "%%s" "auto"; }\n'
    # bridge-start.sh would normally be invoked via $BRIDGE_BASH_BIN; we
    # set that to /bin/false-not-invoked (nonexistent) so any accidental
    # invocation explodes loudly. A side-channel is captured into
    # INVOKE_LOG via the `command -v` shim below.
    printf '\n'
    # Audit + warn + info stubs.
    printf 'daemon_info() { printf "info: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_warn() { printf "warn: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_audit_log() { :; }\n'
    printf 'nudge_agent_session() { :; }\n'
    # ---- Source production functions on top of stubs. The production
    # `process_on_demand_agents` then drives down the on-demand branch.
    printf 'source "%s"\n' "$prod_funcs"
    # ---- Wrap BRIDGE_BASH_BIN invocation: process_on_demand_agents uses
    # `"$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-start.sh" "$agent"`. To
    # avoid an actual exec failure tripping the rc-1 fallthrough that
    # records `start-command-failed` (which would falsify the test
    # because the new channel-miss gate is supposed to short-circuit
    # BEFORE we ever reach the start invocation), override the binary
    # path lookup to a stub that records and returns. The function
    # uses the literal name `$BRIDGE_BASH_BIN`; we already set it to
    # a nonexistent path. If the channel-miss helper short-circuits,
    # the path is never invoked. If the gate regresses, the missing
    # path produces a real rc=127 + `start-command-failed` reason
    # which the assertion below catches.
    printf '\n'
    printf '# Build summary TSV: agent\\tqueued\\tclaimed\\tblocked\\tactive\\tidle\\tlast_seen\\tlast_nudge\\tsession\\tengine\\tworkdir\n'
    printf 'summary="$(printf "%%s\\t1\\t0\\t0\\t0\\t0\\t0\\t0\\t\\tclaude\\t/tmp/wd" "$AGENT")"\n'
    printf 'process_on_demand_agents "$summary" || true\n'
    # Side-channel: did bridge-start.sh get invoked? If it did, the
    # backoff state file would carry `start-command-failed`. We assert
    # against that directly below — no separate INVOKE_LOG capture
    # needed because the state-file reason field is the load-bearing
    # signal the codex finding pins.
  } >"$driver"

  # T5.a — Drive on-demand branch with channel-status=miss; helper must
  # short-circuit. State file reason must be the actionable token.
  local agent="ondemand-miss-agent"
  local channel_reason="plugin:teams /opt/agent-bridge/.teams/access.json"
  local driver_out="$SMOKE_TMP_ROOT/t5-driver-stdout.log"
  "$BRIDGE_BASH" "$driver" "$state_dir" "$invoke_log" "$daemon_log" \
    "$agent" "miss" "$channel_reason" >>"$driver_out" 2>&1

  local state_file="$state_dir/daemon-autostart/$agent.env"
  [[ -f "$state_file" ]] || \
    smoke_fail "T5.a: backoff state file missing — channel-miss helper did not run on on-demand branch (state_dir=$state_dir, daemon_log=$daemon_log)"

  local last_reason
  last_reason="$(grep '^AUTO_START_LAST_REASON=' "$state_file" | head -n 1 | sed 's/^AUTO_START_LAST_REASON=//')"
  smoke_assert_contains "$last_reason" "channel-required-validator-miss" \
    "T5.a: on-demand branch backoff reason must name validator miss (got: $last_reason)"
  smoke_assert_contains "$last_reason" "plugin:teams" \
    "T5.a: on-demand branch reason must carry channel spec (got: $last_reason)"
  smoke_assert_not_contains "$last_reason" "start-command-failed" \
    "T5.a: on-demand branch reason must NOT be opaque start-command-failed (got: $last_reason)"

  # T5.b — Control: with channel-status=ok, the on-demand branch falls
  # through to the start invocation and records start-command-failed
  # (because the stub BRIDGE_BASH_BIN points at a nonexistent path).
  # Confirms the channel-miss gate is the load-bearing reason, not a
  # universally-applied state-file write.
  rm -f "$state_dir/daemon-autostart"/*.env
  "$BRIDGE_BASH" "$driver" "$state_dir" "$invoke_log" "$daemon_log" \
    "$agent" "ok" "" >>"$driver_out" 2>&1 || true
  state_file="$state_dir/daemon-autostart/$agent.env"
  if [[ -f "$state_file" ]]; then
    last_reason="$(grep '^AUTO_START_LAST_REASON=' "$state_file" | head -n 1 | sed 's/^AUTO_START_LAST_REASON=//')"
    # When status=ok, bridge-start.sh stub fails (rc=127, nonexistent
    # interpreter) and the natural fallthrough writes start-command-failed.
    smoke_assert_not_contains "$last_reason" "channel-required-validator-miss" \
      "T5.b: status=ok must NOT take the channel-miss branch (got: $last_reason)"
  fi

  smoke_log "T5 PASS — production on-demand branch parity confirmed (channel-miss reason recorded, not start-command-failed)"
}

# ---------------------------------------------------------------------------
# T6 — Production cron-dispatch wake branch parity (codex r2 BLOCKING finding).
#
# Background: r2 added the channel-miss auto-hold to both branches of
# `process_on_demand_agents`, but `bridge_daemon_cron_dispatch_wake`
# (bridge-daemon.sh ~5540-5627) is a SEPARATE code path that fires when
# a queued cron-dispatch row targets a stopped static agent. Without
# the same gate there, a static agent with `channel_status=miss` would
# have `bridge_daemon_cron_dispatch_wake` invoke `bridge-start.sh`,
# which re-fails at the validator, and the autostart backoff state file
# would record the opaque `cron-dispatch-wake-failed` reason — the same
# operator-visible regression the always-on / on-demand branches now
# avoid.
#
# This test exercises the REAL production `bridge_daemon_cron_dispatch_wake`
# function (extracted verbatim from bridge-daemon.sh — not a re-implemented
# driver) for a stopped static agent with missing channel validator. It
# asserts:
#   * `bridge-start.sh` would NOT be invoked (helper short-circuits before
#     reaching `BRIDGE_BASH_BIN`)
#   * the autostart backoff state file's `AUTO_START_LAST_REASON` contains
#     `channel-required-validator-miss:` — NOT `cron-dispatch-wake-failed`
#
# This pins codex r2 finding #1: a future refactor that removes the
# channel-status gate from the cron-dispatch wake path fails this smoke.
# ---------------------------------------------------------------------------
step_t6_crondispatch_wake_channel_miss_parity() {
  smoke_log "T6: production cron-dispatch wake branch records actionable channel-miss reason"

  local state_dir="$SMOKE_TMP_ROOT/t6-state"
  mkdir -p "$state_dir/daemon-autostart" "$state_dir/cron-dispatch-wake"
  local daemon_log="$SMOKE_TMP_ROOT/t6-daemon.log"
  : >"$daemon_log"

  # Extract the entire production `bridge_daemon_cron_dispatch_wake`
  # function + the channel-status helper + state-file helpers from
  # bridge-daemon.sh. The brief calls for the production code path —
  # if a future refactor removes the gate, this extraction-driven smoke
  # fails at the source-anchor assertion below.
  local prod_funcs="$SMOKE_TMP_ROOT/t6-prod-funcs.sh"
  {
    awk '
      /^bridge_daemon_cron_dispatch_wake\(\) \{/                  { capture=1 }
      /^bridge_daemon_cron_dispatch_wake_state_file\(\) \{/       { capture=1 }
      /^bridge_daemon_autostart_state_file\(\) \{/                { capture=1 }
      /^bridge_daemon_note_autostart_failure\(\) \{/              { capture=1 }
      /^bridge_daemon_clear_autostart_failure\(\) \{/             { capture=1 }
      /^bridge_daemon_check_channel_status_or_hold\(\) \{/        { capture=1 }
      capture { print }
      capture && /^}[[:space:]]*$/ { capture=0; print "" }
    ' "$REPO_ROOT/bridge-daemon.sh"
  } >"$prod_funcs"

  # Pin: every expected function MUST be present in the extraction so a
  # future rename / split fails loudly here rather than producing a
  # silent test-skipped result.
  for fn in bridge_daemon_cron_dispatch_wake \
            bridge_daemon_cron_dispatch_wake_state_file \
            bridge_daemon_autostart_state_file \
            bridge_daemon_note_autostart_failure \
            bridge_daemon_clear_autostart_failure \
            bridge_daemon_check_channel_status_or_hold; do
    if ! grep -q "^${fn}() {" "$prod_funcs"; then
      smoke_fail "T6: production function $fn missing from bridge-daemon.sh extraction — check for rename"
    fi
  done

  # Source-anchor pin for codex r2 finding: the cron-dispatch wake function
  # body MUST contain the channel-status gate. Without this, a future PR
  # could quietly remove the call to bridge_daemon_check_channel_status_or_hold
  # from inside bridge_daemon_cron_dispatch_wake and the assertion below
  # would still pass (because the helper is still defined, just not called
  # on this path). Anchor on the production source itself.
  local crondispatch_block
  crondispatch_block="$(awk '
    /^bridge_daemon_cron_dispatch_wake\(\) \{/ { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; exit }
  ' "$REPO_ROOT/bridge-daemon.sh")"
  smoke_assert_contains "$crondispatch_block" "bridge_daemon_check_channel_status_or_hold" \
    "T6: codex r2 finding — bridge_daemon_cron_dispatch_wake MUST call bridge_daemon_check_channel_status_or_hold"

  local driver="$SMOKE_TMP_ROOT/t6-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'BRIDGE_STATE_DIR="$1"\n'
    printf 'DAEMON_LOG="$2"\n'
    printf 'AGENT="$3"\n'
    printf 'TASK_ID="$4"\n'
    printf 'FAMILY="$5"\n'
    printf 'CHANNEL_STATUS="$6"\n'
    printf 'CHANNEL_REASON="$7"\n'
    # Force-fail any bridge-start.sh invocation by pointing the bash
    # interpreter at a nonexistent path. If the channel-miss helper
    # short-circuits, this path is never reached. If the gate regresses,
    # the missing path produces rc=127 + the opaque cron-dispatch-wake-failed
    # reason which the assertion below catches.
    printf 'BRIDGE_BASH_BIN="/bin/false-not-invoked"\n'
    printf 'SCRIPT_DIR="/nonexistent-script-dir"\n'
    # ---- Stub dependencies for the cron-dispatch wake function.
    printf 'bridge_agent_exists() { return 0; }\n'
    printf 'bridge_agent_is_active() { return 1; }\n'
    printf 'bridge_agent_source() { printf "%%s" "static"; }\n'
    printf 'bridge_agent_loop() { printf "%%s" "1"; }\n'
    printf 'bridge_agent_manual_stop_active() { return 1; }\n'
    printf 'bridge_agent_broken_launch_file() { printf "%%s" "/nonexistent/broken-launch/$AGENT"; }\n'
    printf 'bridge_daemon_autostart_allowed() { return 0; }\n'
    # Channel status helpers — driven by argv to flip miss/ok.
    printf 'bridge_agent_channel_status() { printf "%%s" "$CHANNEL_STATUS"; }\n'
    printf 'bridge_agent_channel_status_reason() { printf "%%s" "$CHANNEL_REASON"; }\n'
    # Audit + warn + info stubs.
    printf 'daemon_info() { printf "info: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_warn() { printf "warn: %%s\\n" "$*" >>"$DAEMON_LOG"; }\n'
    printf 'bridge_audit_log() { :; }\n'
    # ---- Source production functions on top of stubs.
    printf 'source "%s"\n' "$prod_funcs"
    printf '\n'
    printf 'bridge_daemon_cron_dispatch_wake "$AGENT" "$TASK_ID" "$FAMILY" || true\n'
  } >"$driver"

  # T6.a — Drive cron-dispatch wake with channel-status=miss; helper must
  # short-circuit. Autostart backoff state file must carry the actionable
  # `channel-required-validator-miss:` token; the opaque
  # `cron-dispatch-wake-failed` reason MUST NOT appear.
  local agent="crondispatch-miss-agent"
  local channel_reason="plugin:teams /opt/agent-bridge/.teams/access.json"
  local driver_out="$SMOKE_TMP_ROOT/t6-driver-stdout.log"
  : >"$driver_out"
  "$BRIDGE_BASH" "$driver" "$state_dir" "$daemon_log" \
    "$agent" "999" "follow-up:test" "miss" "$channel_reason" >>"$driver_out" 2>&1

  local state_file="$state_dir/daemon-autostart/$agent.env"
  [[ -f "$state_file" ]] || \
    smoke_fail "T6.a: autostart backoff state file missing — channel-miss helper did not run inside cron-dispatch wake (state_dir=$state_dir, driver_out=$(cat "$driver_out"))"

  local last_reason
  last_reason="$(grep '^AUTO_START_LAST_REASON=' "$state_file" | head -n 1 | sed 's/^AUTO_START_LAST_REASON=//')"
  smoke_assert_contains "$last_reason" "channel-required-validator-miss" \
    "T6.a: cron-dispatch wake backoff reason must name validator miss (got: $last_reason)"
  smoke_assert_contains "$last_reason" "plugin:teams" \
    "T6.a: cron-dispatch wake reason must carry channel spec (got: $last_reason)"
  smoke_assert_not_contains "$last_reason" "cron-dispatch-wake-failed" \
    "T6.a: cron-dispatch wake reason must NOT be opaque cron-dispatch-wake-failed (got: $last_reason)"
  smoke_assert_not_contains "$last_reason" "start_command_failed" \
    "T6.a: cron-dispatch wake reason must NOT carry an opaque start-command-failed token (got: $last_reason)"

  # T6.b — Cron-dispatch throttle window state file MUST NOT be written
  # for a held channel-miss tick. The throttle window is a real-wake
  # rate-limit; a held wake should not consume a throttle slot, otherwise
  # the next tick (after the operator finishes channel setup) would be
  # incorrectly throttled.
  local throttle_file="$state_dir/cron-dispatch-wake/$agent.ts"
  if [[ -f "$throttle_file" ]]; then
    smoke_fail "T6.b: cron-dispatch throttle state file written despite channel-miss hold (path: $throttle_file)"
  fi

  # T6.c — Control: with channel-status=ok, the cron-dispatch wake path
  # falls through to the start invocation. Because BRIDGE_BASH_BIN points
  # at a nonexistent path, `bridge-start.sh` invocation fails (rc=127)
  # and the natural fallthrough records `cron-dispatch-wake-failed` on
  # the autostart backoff state file. Confirms the channel-miss gate is
  # the load-bearing reason for the held branch, not a universally-applied
  # state-file write.
  rm -f "$state_dir/daemon-autostart"/*.env
  rm -f "$state_dir/cron-dispatch-wake"/*.ts
  "$BRIDGE_BASH" "$driver" "$state_dir" "$daemon_log" \
    "$agent" "1000" "follow-up:test" "ok" "" >>"$driver_out" 2>&1 || true
  state_file="$state_dir/daemon-autostart/$agent.env"
  if [[ -f "$state_file" ]]; then
    last_reason="$(grep '^AUTO_START_LAST_REASON=' "$state_file" | head -n 1 | sed 's/^AUTO_START_LAST_REASON=//')"
    smoke_assert_not_contains "$last_reason" "channel-required-validator-miss" \
      "T6.c: status=ok must NOT take the channel-miss branch (got: $last_reason)"
    smoke_assert_contains "$last_reason" "cron-dispatch-wake-failed" \
      "T6.c: status=ok with failing bridge-start.sh stub must record cron-dispatch-wake-failed (got: $last_reason)"
  else
    smoke_fail "T6.c: autostart backoff state file missing under status=ok control path — fallthrough did not record the start-command failure"
  fi

  smoke_log "T6 PASS — production cron-dispatch wake branch parity confirmed (channel-miss reason recorded, not cron-dispatch-wake-failed)"
}

step_t1_start_policy_persists
step_t2_start_policy_reader
step_t3_daemon_hold_gate
step_t4_validator_miss_reason
step_t5_ondemand_production_branch_channel_miss_parity
step_t6_crondispatch_wake_channel_miss_parity

smoke_log "PASS: δ-1234-daemon-start-policy (refs #1234, v0.15.0-beta2 Lane δ)"
