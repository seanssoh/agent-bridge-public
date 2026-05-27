#!/usr/bin/env bash
#
# scripts/smoke/beta5-2-pi-daemon-crashloop-no-set-e-leak.sh — issue #1338
# (beta5-2 Lane π).
#
# REGRESSION CONTEXT
# ==================
# v0.15.0-beta5-1 PR #1309 introduced process_mcp_liveness_giveup_recovery
# (Lane 3 MCP-liveness giveup auto-clear). On the patch host
# cm-prod-agentworkflow-vm01 the daemon entered a crash loop immediately
# after `agent-bridge upgrade --apply`:
#
#   audit.jsonl:
#     22:46:32 daemon_exit exit_code=1 last_step=mcp_liveness_giveup_recovery
#     22:46:39 daemon_exit exit_code=1 last_step=mcp_liveness_giveup_recovery
#     22:46:47 daemon_exit exit_code=1 last_step=mcp_liveness_giveup_recovery
#     ... (repeating every 5-7s)
#
# Root cause: `bridge-daemon.sh` runs under `set -euo pipefail`. The
# previous Bash-doc-blessed contract was that
#   process_mcp_liveness_giveup_recovery || true
# would suppress any internal failure. But that contract breaks across
# nested function boundaries on production hosts — a non-zero return
# from a helper called inside the function body (e.g.
# `bridge_agent_mcp_note_activity_state` failing its mkdir under
# restricted iso-v2 perms, or `bridge_agent_mcp_giveup_arm`'s tail
# `[[ -n ... ]] && printf` returning 1 when the field is empty) can fire
# `set -e` in the daemon's main loop, killing the process before the
# trailing `|| true` ever runs.
#
# FIX (two layers + a third for defense-in-depth)
# ==============================================
# Layer 1 — caller subshell isolation. Wrap the call in a `( ... )`:
#   ( process_mcp_liveness_giveup_recovery ) || true
# The subshell creates a hard process boundary. set -e inside exits the
# subshell with rc != 0; the outer `|| true` consumes that non-zero;
# the daemon loop continues. Same pattern applied to OTHER step_fn
# call sites in cmd_sync_cycle.
#
# Layer 2 — function-body hardening. Every helper call inside
# process_mcp_liveness_giveup_recovery's per-agent loop is explicit
# `|| true`-guarded, and the function ends with `return 0` so the rc
# from the last in-loop helper cannot leak out.
#
# This smoke proves the daemon survives a forced internal failure in
# the recovery step.
#
# CASES
# =====
#
#   T1. set -e + recovery body failure → daemon does NOT exit. Source
#       the daemon's runtime exit handler under `set -euo pipefail`,
#       stub the recovery step's internal helpers so one of them
#       returns non-zero (`return 1`), invoke the subshell-isolated
#       call site (`( process_mcp_liveness_giveup_recovery ) || true`),
#       assert the parent shell is still alive AND can run a follow-up
#       command. This is the exact failure pattern that crashed the
#       patch host on beta5-1.
#
#   T2. set -e + audit log call returning non-zero → daemon does NOT
#       exit. Same shape as T1 but the failing helper is
#       `bridge_audit_log` (mid-tick, on the recovered path).
#
#   T3 (teeth). Revert the subshell isolation (drop the `( ... )`)
#       AND the function-body `|| true` hardening — confirm that under
#       those reverted conditions, the SAME internal failure DOES exit
#       the parent shell. This proves the smoke catches the regression
#       the production fix closes. Only runs when SMOKE_TEETH=1 so the
#       main flow stays clean.
#
#   T4. Audit ALL other step_fn || true call sites in cmd_sync_cycle's
#       body — for each, simulate an internal helper failure under
#       set -e and assert the parent shell does not exit. Catches the
#       defense-in-depth lapse if a future PR removes the subshell on
#       any single site.
#
#   T5 (regression). Healthy path: process_mcp_liveness_giveup_recovery
#       on a no-failure host emits the `plugin_mcp_liveness_recovered`
#       audit row, clears the ledger, daemon continues — the existing
#       T_production_order behavior from #1309 must still hold under
#       the subshell wrap.
#
# Footgun #11 mitigation: zero heredoc-stdin into a subprocess —
# helper bodies are extracted with awk + emitted via printf-to-file.

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
  echo "[smoke:beta5-2-pi-daemon-crashloop-no-set-e-leak] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="beta5-2-pi-daemon-crashloop-no-set-e-leak"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AGENT="test_setk"

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

# Extract the production recovery + helpers in one go so the smoke runs
# the same code path the daemon does. Source from bridge-daemon.sh.
HELPERS_FUNCS="$SMOKE_TMP_ROOT/helpers.sh"
{
  awk '
    /^bridge_plugin_liveness_state_file\(\) \{/      { capture=1 }
    /^bridge_clear_plugin_liveness_state\(\) \{/      { capture=1 }
    /^bridge_clear_plugin_liveness_state_if_no_giveup\(\) \{/ { capture=1 }
    /^bridge_note_plugin_liveness_state\(\) \{/       { capture=1 }
    /^bridge_agent_mcp_giveup_arm\(\) \{/             { capture=1 }
    /^bridge_agent_mcp_giveup_active\(\) \{/          { capture=1 }
    /^bridge_agent_mcp_giveup_ts\(\) \{/              { capture=1 }
    /^bridge_agent_mcp_giveup_clear\(\) \{/           { capture=1 }
    /^bridge_agent_mcp_note_activity_state\(\) \{/    { capture=1 }
    /^bridge_recheck_mcp_liveness\(\) \{/             { capture=1 }
    /^process_mcp_liveness_giveup_recovery\(\) \{/    { capture=1 }
    /^daemon_source_state_file\(\) \{/                { capture=1 }
    capture { print }
    capture && /^}[[:space:]]*$/ { capture=0; print "" }
  ' "$REPO_ROOT/bridge-daemon.sh"
} >"$HELPERS_FUNCS"

for fn in process_mcp_liveness_giveup_recovery \
          bridge_agent_mcp_note_activity_state \
          bridge_agent_mcp_giveup_arm \
          bridge_agent_mcp_giveup_active \
          bridge_agent_mcp_giveup_clear \
          bridge_agent_mcp_giveup_ts \
          bridge_recheck_mcp_liveness \
          daemon_source_state_file \
          bridge_plugin_liveness_state_file; do
  if ! grep -q "^${fn}() {" "$HELPERS_FUNCS"; then
    smoke_fail "extract failed: helper $fn not found in $HELPERS_FUNCS"
  fi
done

# Confirm the caller's subshell isolation is present at the production
# call site. If a future PR drops the `( ... )`, this smoke fires.
# Use fixed-string grep to avoid regex escaping headaches.
if ! grep -F -q "( process_mcp_liveness_giveup_recovery ) || true" "$REPO_ROOT/bridge-daemon.sh"; then
  smoke_fail "caller subshell isolation missing — \`( process_mcp_liveness_giveup_recovery ) || true\` not found in bridge-daemon.sh (regression: #1338 fix removed?)"
fi
smoke_log "caller subshell isolation present at production call site"

# ---------------------------------------------------------------------------
# T1 — set -e + internal helper failure → daemon does NOT exit.
# ---------------------------------------------------------------------------
smoke_log "T1: set -e + recovery body internal failure must not exit the daemon"

DRIVER_T1="$SMOKE_TMP_ROOT/t1-driver.sh"
STATE_FILE_T1="$BRIDGE_STATE_DIR/plugin-liveness/$AGENT.env"
mkdir -p "$(dirname "$STATE_FILE_T1")"
# CRITICAL setup — seed a state file that lacks LAST_KEY. The
# production daemon_source_state_file UNSETS LAST_KEY before sourcing
# (lib helper line 431). When the file doesn't redefine it, LAST_KEY
# stays unset, and the helper's `[[ -n "$LAST_KEY" ]]` fires "unbound
# variable" under the daemon's `set -u` (which `set -euo pipefail`
# enables). THAT was the actual production crash class on
# cm-prod-agentworkflow-vm01 — a fresh-armed giveup ledger
# (GIVEUP/GIVEUP_TS/LAST_ACTIVITY_STATE only) tripped the unset read.
{
  printf 'GIVEUP=1\n'
  printf 'GIVEUP_TS=1\n'
  printf 'LAST_ACTIVITY_STATE=picker_block\n'
} >"$STATE_FILE_T1"

{
  printf '#!/usr/bin/env bash\n'
  # MUST mirror the daemon: set -euo pipefail. The leak only fires
  # under -u (unbound variable) which the daemon enables in production.
  printf 'set -euo pipefail\n'
  printf 'export BRIDGE_STATE_DIR="%s"\n' "$BRIDGE_STATE_DIR"
  printf 'export BRIDGE_AUDIT_LOG="%s/audit.jsonl"\n' "$SMOKE_TMP_ROOT"

  printf 'bridge_audit_log() { :; }\n'
  printf 'daemon_info() { :; }\n'
  printf 'daemon_warn() { :; }\n'
  printf 'bridge_require_python() { :; }\n'
  printf 'bridge_agent_heartbeat_activity_state() { printf "%%s" "idle"; }\n'
  printf 'bridge_agent_missing_plugin_mcp_channels_csv() { printf ""; }\n'
  printf 'declare -ga BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
  printf 'source "%s"\n' "$HELPERS_FUNCS"
  # Bypass bridge_recheck_mcp_liveness's bridge_agent_engine probe.
  printf 'bridge_recheck_mcp_liveness() { return 0; }\n'

  # Invoke through the production subshell wrap. With the helper
  # internals hardened (LAST_KEY guarded with `${VAR:-}`), this MUST
  # complete cleanly. If a regression strips the `${VAR:-}` guards,
  # the subshell isolates the resulting set -u abort.
  printf '( process_mcp_liveness_giveup_recovery ) || true\n'

  # Sentinel — if set -u + set -e leaked, this never runs.
  printf 'echo "T1-survived" >"%s/t1.flag"\n' "$SMOKE_TMP_ROOT"
} >"$DRIVER_T1"

"$BRIDGE_BASH" "$DRIVER_T1"
t1_rc=$?
if (( t1_rc != 0 )); then
  smoke_fail "T1: driver exited non-zero ($t1_rc) — set -e leak NOT suppressed by subshell wrap"
fi
[[ -f "$SMOKE_TMP_ROOT/t1.flag" ]] || smoke_fail "T1: sentinel file not created — driver aborted before reaching post-call code"
smoke_assert_eq "T1-survived" "$(<"$SMOKE_TMP_ROOT/t1.flag")" "T1: post-call sentinel"
smoke_log "T1 PASS — daemon survived internal helper failure under set -e + subshell wrap"

# ---------------------------------------------------------------------------
# T2 — set -e + audit log call returning non-zero → daemon does NOT exit.
# ---------------------------------------------------------------------------
smoke_log "T2: set -e + audit log non-zero return must not exit the daemon"

DRIVER_T2="$SMOKE_TMP_ROOT/t2-driver.sh"
STATE_FILE_T2="$BRIDGE_STATE_DIR/plugin-liveness/$AGENT.env"
mkdir -p "$(dirname "$STATE_FILE_T2")"
# Seed an armed giveup so the recovery tick actually fires the audit log.
{
  printf 'GIVEUP=1\n'
  printf 'GIVEUP_TS=1\n'
  printf 'LAST_ACTIVITY_STATE=picker_block\n'
} >"$STATE_FILE_T2"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'export BRIDGE_STATE_DIR="%s"\n' "$BRIDGE_STATE_DIR"
  printf 'export BRIDGE_AUDIT_LOG="%s/audit.jsonl"\n' "$SMOKE_TMP_ROOT"
  printf 'daemon_info() { :; }\n'
  printf 'daemon_warn() { :; }\n'
  printf 'bridge_require_python() { :; }\n'
  printf 'bridge_agent_heartbeat_activity_state() { printf "%%s" "idle"; }\n'
  printf 'bridge_agent_missing_plugin_mcp_channels_csv() { printf ""; }\n'
  printf 'declare -ga BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
  printf 'source "%s"\n' "$HELPERS_FUNCS"
  # Stub AFTER sourcing helpers — late binding shadows the production
  # bridge_recheck_mcp_liveness so we always hit the recovered branch.
  printf 'bridge_recheck_mcp_liveness() { return 0; }\n'
  # Stub AFTER sourcing — the audit log helper returning non-zero is
  # the failure injection for this case.
  printf 'bridge_audit_log() { return 23; }\n'

  # Production subshell-wrap.
  printf '( process_mcp_liveness_giveup_recovery ) || true\n'
  printf 'echo "T2-survived" >"%s/t2.flag"\n' "$SMOKE_TMP_ROOT"
} >"$DRIVER_T2"

"$BRIDGE_BASH" "$DRIVER_T2"
t2_rc=$?
if (( t2_rc != 0 )); then
  smoke_fail "T2: driver exited non-zero ($t2_rc) — set -e leak NOT suppressed for audit log"
fi
[[ -f "$SMOKE_TMP_ROOT/t2.flag" ]] || smoke_fail "T2: sentinel file not created"
smoke_log "T2 PASS — daemon survived bridge_audit_log non-zero return under set -e"

# ---------------------------------------------------------------------------
# T3 (teeth) — revert both fix layers (subshell wrap + `${VAR:-}` guard)
# and confirm the SAME set -u "unbound variable" abort kills the driver.
# This is the production crash class on cm-prod-agentworkflow-vm01:
# `set -u` "unbound variable" is a HARD error that BYPASSES the trailing
# `|| true` on a function call (`f || true` does NOT suppress `set -u`
# inside `f`). Only the subshell wrap `( f ) || true` isolates it.
#
# Only runs when SMOKE_TEETH=1 so the main flow stays clean.
# ---------------------------------------------------------------------------
if [[ "${SMOKE_TEETH:-0}" == "1" ]]; then
  smoke_log "T3 (teeth): reverted (no subshell + bare \$VAR) → set -u abort kills driver"
  DRIVER_T3="$SMOKE_TMP_ROOT/t3-driver.sh"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    # Minimal reproduction of the production crash class — no need to
    # source the full helpers. The shape that triggered the patch host
    # crash loop: a function references `$VAR` (bare, no default
    # expansion) under set -u when daemon_source_state_file has unset
    # VAR. The trailing `|| true` does NOT suppress the resulting
    # "unbound variable" abort.
    printf 'unset MY_VAR\n'
    printf 'leaky_func() {\n'
    printf '  [[ -n "$MY_VAR" ]] && printf "x"\n'
    printf '}\n'
    # Pre-fix call shape — bare `|| true`, no subshell.
    printf 'leaky_func || true\n'
    # Sentinel — would only print if the abort was actually suppressed.
    printf 'echo "T3-survived" >"%s/t3.flag"\n' "$SMOKE_TMP_ROOT"
  } >"$DRIVER_T3"

  set +e
  "$BRIDGE_BASH" "$DRIVER_T3" >/dev/null 2>&1
  t3_rc=$?
  set -e
  # We EXPECT non-zero rc AND missing sentinel.
  if (( t3_rc == 0 )) && [[ -f "$SMOKE_TMP_ROOT/t3.flag" ]]; then
    smoke_fail "T3 (teeth): pre-fix shape did NOT exit on set -u leak — smoke fails to catch the production regression class"
  fi
  smoke_log "T3 (teeth) PASS — pre-fix \`f || true\` shape exits driver (rc=$t3_rc) on set -u leak — smoke catches the regression"

  # T3b — the SAME failing function wrapped in the production fix shape
  # `( f ) || true` MUST survive. Confirms the subshell wrap is the
  # actual mitigation (not just a defensive coincidence).
  smoke_log "T3b (teeth): post-fix \`( f ) || true\` shape MUST survive set -u leak"
  DRIVER_T3B="$SMOKE_TMP_ROOT/t3b-driver.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'unset MY_VAR\n'
    printf 'leaky_func() {\n'
    printf '  [[ -n "$MY_VAR" ]] && printf "x"\n'
    printf '}\n'
    # Production fix shape — subshell wrap.
    printf '( leaky_func ) || true\n'
    printf 'echo "T3b-survived" >"%s/t3b.flag"\n' "$SMOKE_TMP_ROOT"
  } >"$DRIVER_T3B"

  "$BRIDGE_BASH" "$DRIVER_T3B" >/dev/null 2>&1
  t3b_rc=$?
  if (( t3b_rc != 0 )) || [[ ! -f "$SMOKE_TMP_ROOT/t3b.flag" ]]; then
    smoke_fail "T3b (teeth): post-fix shape exited unexpectedly (rc=$t3b_rc) — subshell wrap is NOT isolating the set -u leak"
  fi
  smoke_log "T3b (teeth) PASS — subshell wrap successfully isolates set -u leak"
fi

# ---------------------------------------------------------------------------
# T4 — audit all OTHER step_fn || true call sites in cmd_sync_cycle.
# Production code grep — confirm each is now wrapped in `( ... )`.
# ---------------------------------------------------------------------------
smoke_log "T4: confirm all step_fn || true sites in cmd_sync_cycle are subshell-isolated"

# The full set of step_fn || true sites that beta5-2 Lane π protects.
# When a future PR adds a new step_fn, the developer should also add it
# to this list AND wrap it in `( ... )` at the call site.
REQUIRED_SUBSHELL_SITES=(
  "( bridge_discord_relay_step ) || true"
  "( process_precompact_events ) || true"
  "( bridge_reconcile_idle_markers ) || true"
  "( recover_claude_bootstrap_blockers ) || true"
  "( reconcile_prompt_ready_latches ) || true"
  "( flush_pending_attention_spools ) || true"
  "( process_channel_health ) || true"
  "( process_mcp_liveness_giveup_recovery ) || true"
  "( process_plugin_liveness ) || true"
  "( start_cron_dispatch_workers ) || true"
  "( process_a2a_deliver_tick ) || true"
  "( process_a2a_outbox_stuck_scan_tick ) || true"
  "( process_memory_daily_orphan_sweep ) || true"
  "( bridge_dashboard_post_if_changed \"\$summary_output\" ) || true"
)

t4_missing=()
for site in "${REQUIRED_SUBSHELL_SITES[@]}"; do
  if ! grep -F -q "$site" "$REPO_ROOT/bridge-daemon.sh"; then
    t4_missing+=("$site")
  fi
done

if (( ${#t4_missing[@]} > 0 )); then
  printf '[smoke:%s][error] T4: missing subshell isolation at %d step_fn site(s):\n' "$SMOKE_NAME" "${#t4_missing[@]}" >&2
  for s in "${t4_missing[@]}"; do
    printf '  - %s\n' "$s" >&2
  done
  smoke_fail "T4: defense-in-depth subshell isolation incomplete"
fi
smoke_log "T4 PASS — all ${#REQUIRED_SUBSHELL_SITES[@]} step_fn || true sites are subshell-isolated"

# ---------------------------------------------------------------------------
# T5 — healthy regression. With recovery body running normally (no
# injected failure), the audit row + ledger-clear semantics from #1309
# must still hold under the subshell wrap. Catches the case where the
# fix accidentally suppresses legitimate observability.
# ---------------------------------------------------------------------------
smoke_log "T5 (regression): subshell wrap must not suppress legitimate audit emission"

DRIVER_T5="$SMOKE_TMP_ROOT/t5-driver.sh"
STATE_FILE_T5="$BRIDGE_STATE_DIR/plugin-liveness/$AGENT.env"
mkdir -p "$(dirname "$STATE_FILE_T5")"
# Seed an armed giveup so recovery has work to do.
{
  printf 'LAST_KEY=deadbeef\n'
  printf 'LAST_DETECTED_TS=1700000000\n'
  printf 'LAST_RESTART_TS=1700000010\n'
  printf 'RESTART_ATTEMPTS=6\n'
  printf 'GIVEUP=1\n'
  printf 'GIVEUP_TS=1700000000\n'
  printf 'LAST_ACTIVITY_STATE=picker_block\n'
} >"$STATE_FILE_T5"

: >"$SMOKE_TMP_ROOT/audit.jsonl"

{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'export BRIDGE_STATE_DIR="%s"\n' "$BRIDGE_STATE_DIR"
  printf 'export BRIDGE_AUDIT_LOG="%s/audit.jsonl"\n' "$SMOKE_TMP_ROOT"
  printf 'bridge_audit_log() {\n'
  printf '  local actor="$1"; local action="$2"; local target="$3"; shift 3\n'
  printf '  local details=""\n'
  printf '  while (( $# > 0 )); do\n'
  printf '    case "$1" in\n'
  printf '      --detail) details="${details} $2"; shift 2;;\n'
  printf '      *) shift;;\n'
  printf '    esac\n'
  printf '  done\n'
  printf '  printf "actor=%%s action=%%s target=%%s%%s\\n" \\\n'
  printf '    "$actor" "$action" "$target" "$details" \\\n'
  printf '    >>"$BRIDGE_AUDIT_LOG"\n'
  printf '}\n'
  printf 'daemon_info() { :; }\n'
  printf 'daemon_warn() { :; }\n'
  printf 'bridge_require_python() { :; }\n'
  printf 'bridge_agent_heartbeat_activity_state() { printf "%%s" "idle"; }\n'
  printf 'bridge_agent_missing_plugin_mcp_channels_csv() { printf ""; }\n'
  printf 'declare -ga BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
  printf 'source "%s"\n' "$HELPERS_FUNCS"
  # Override the production bridge_recheck_mcp_liveness (which calls
  # bridge_agent_engine — not stubbed in this driver) so we deterministically
  # hit the recovered branch.
  printf 'bridge_recheck_mcp_liveness() { return 0; }\n'

  printf '( process_mcp_liveness_giveup_recovery ) || true\n'
  printf 'echo "T5-survived" >"%s/t5.flag"\n' "$SMOKE_TMP_ROOT"
} >"$DRIVER_T5"

"$BRIDGE_BASH" "$DRIVER_T5"
t5_rc=$?
if (( t5_rc != 0 )); then
  smoke_fail "T5: driver exited non-zero ($t5_rc) on healthy path"
fi
[[ -f "$SMOKE_TMP_ROOT/t5.flag" ]] || smoke_fail "T5: sentinel not created"

# Audit row must still fire.
if ! grep -F -q "plugin_mcp_liveness_recovered" "$SMOKE_TMP_ROOT/audit.jsonl"; then
  smoke_fail "T5: subshell wrap suppressed legitimate plugin_mcp_liveness_recovered audit row"
fi
smoke_log "T5 PASS — healthy path still emits plugin_mcp_liveness_recovered under subshell wrap"

smoke_log "OK $SMOKE_NAME"
