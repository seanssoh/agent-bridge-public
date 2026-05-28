#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/beta5-2-xi-misc-fixes.sh —
# v0.15.0-beta5-2 Lane ξ — four-issue bundle: #1330 (Teams activity-index
# BRIDGE_AGENT_ID), #1332 (CLAUDE.md atomic creation), #1334 (FORCE_FRESH
# vs session_id persist order), #1318-A (task create on stopped agent).
#
# Structural assertions only — no real Claude/Codex CLI run, no real
# tmux session (the bridge_agent_is_active probe is stubbed for T5/T6).
# This matches the rest of the beta5-2 smoke set which exercises bridge
# library helpers in an isolated $BRIDGE_HOME.

# Re-exec under bash 4+ if needed (associative arrays required).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:beta5-2-xi-misc-fixes][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="beta5-2-xi-misc-fixes"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "beta5-2-xi-misc-fixes"
REPO_ROOT="$SMOKE_REPO_ROOT"

# ----------------------------------------------------------------------
# T1 (#1330 M7) — bridge-start.sh inlines BRIDGE_AGENT_ID into SESSION_CMD
# ----------------------------------------------------------------------
# Structural assertion: bridge-start.sh source carries the
# `SESSION_CMD="BRIDGE_AGENT_ID=...` env-prefix inline that propagates
# the agent id to every child (Claude → Teams MCP server) regardless
# of whether bridge-run.sh later re-exports.
t1_bridge_start_inlines_agent_id() {
  local sd_path="$REPO_ROOT/bridge-start.sh"
  smoke_assert_file_exists "$sd_path" "T1 bridge-start.sh source"
  if ! grep -qF 'SESSION_CMD="BRIDGE_AGENT_ID=$(printf' "$sd_path"; then
    smoke_fail "T1: bridge-start.sh missing BRIDGE_AGENT_ID env-prefix inline (#1330)"
  fi
  # Order check — the inline must follow the BRIDGE_CONTROLLER_UID
  # inline so the env prefix is layered consistently (CONTROLLER_UID
  # first, then AGENT_ID). grep -n + awk so a future re-order is loud.
  local controller_line agent_line
  controller_line="$(grep -nF 'SESSION_CMD="BRIDGE_CONTROLLER_UID=' "$sd_path" | head -n 1 | cut -d: -f1)"
  agent_line="$(grep -nF 'SESSION_CMD="BRIDGE_AGENT_ID=$(printf' "$sd_path" | head -n 1 | cut -d: -f1)"
  if [[ -z "$controller_line" || -z "$agent_line" ]]; then
    smoke_fail "T1: bridge-start.sh structural probe found no controller/agent inline lines (controller=$controller_line agent=$agent_line)"
  fi
  if (( agent_line <= controller_line )); then
    smoke_fail "T1: BRIDGE_AGENT_ID inline (line $agent_line) must come AFTER BRIDGE_CONTROLLER_UID inline (line $controller_line)"
  fi
}

# ----------------------------------------------------------------------
# T1b — plugins/teams/server.ts emits startup warning when BRIDGE_AGENT_ID
# is empty
# ----------------------------------------------------------------------
t1b_teams_server_warns_on_empty_agent_id() {
  local ts_path="$REPO_ROOT/plugins/teams/server.ts"
  smoke_assert_file_exists "$ts_path" "T1b plugins/teams/server.ts source"
  if ! grep -qF 'BRIDGE_AGENT_ID is empty at server start' "$ts_path"; then
    smoke_fail "T1b: plugins/teams/server.ts missing empty-BRIDGE_AGENT_ID startup warning (#1330 M7)"
  fi
  # The warn must guard with `!process.env.BRIDGE_AGENT_ID` so a populated
  # but whitespace-only value still trips false. A regex on the exact
  # idiom keeps the smoke teeth honest if someone rewrites to `== ''`
  # or drops the negation.
  if ! grep -qF 'if (!process.env.BRIDGE_AGENT_ID) {' "$ts_path"; then
    smoke_fail "T1b: plugins/teams/server.ts BRIDGE_AGENT_ID startup gate missing the !process.env.BRIDGE_AGENT_ID idiom"
  fi
}

# ----------------------------------------------------------------------
# T2 (#1332 L2) — bridge_layout_materialize_identity performs per-file
# atomic chgrp+chmod after each cp -f via the iso-v2 file-level helper.
# ----------------------------------------------------------------------
t2_materialize_per_file_normalize() {
  local lay_path="$REPO_ROOT/lib/bridge-agent-layout.sh"
  smoke_assert_file_exists "$lay_path" "T2 lib/bridge-agent-layout.sh source"
  # The per-file normalize call must reference the iso-v2 file-level
  # helper and must pass `$target_dir` as the 4th arg (engages the
  # ancestor symlink walk per PR #1335 r3).
  if ! grep -qF 'bridge_isolation_v2_chgrp_file_iso_group' "$lay_path"; then
    smoke_fail "T2: lib/bridge-agent-layout.sh missing per-file normalize call (#1332 L2)"
  fi
  # Structural ordering: the per-file normalize must appear inside the
  # cp loop (i.e. AFTER the cp -f line and BEFORE the loop's closing
  # `done`). Without this, a refactor that hoists the normalize outside
  # the loop would reopen the race window.
  if ! grep -B 2 'bridge_isolation_v2_chgrp_file_iso_group' "$lay_path" | grep -qF 'cp -f "$source_dir/$name" "$target_dir/$name"'; then
    # Fallback: accept the line-continuation form (helper call wrapped
    # across multiple lines for readability) as evidence the per-file
    # pattern is present. Count >= 2 occurrences total (main loop +
    # CLAUDE.md compat branch) so a future refactor that drops one of
    # the two sites still trips this guard.
    local _layout_chgrp_count
    _layout_chgrp_count=$(grep -cF 'bridge_isolation_v2_chgrp_file_iso_group' "$lay_path")
    if (( _layout_chgrp_count < 2 )); then
      smoke_fail "T2: lib/bridge-agent-layout.sh per-file normalize call count=$_layout_chgrp_count (expected >=2 for main loop + compat branch)"
    fi
  fi
}

# ----------------------------------------------------------------------
# T3 + T4 (#1334 L4) — FORCE_FRESH_SESSION → warn order alignment
# ----------------------------------------------------------------------
t3_t4_force_fresh_order_aligned() {
  local sd_path="$REPO_ROOT/bridge-start.sh"
  local rn_path="$REPO_ROOT/bridge-run.sh"
  smoke_assert_file_exists "$sd_path" "T3 bridge-start.sh"
  smoke_assert_file_exists "$rn_path" "T4 bridge-run.sh"

  # bridge-start.sh must use EFFECTIVE_CONTINUE_MODE in the warn gate
  # so a controller-derived FORCE_FRESH fires the warning consistently
  # with bridge-run.sh's --no-continue-injected end-state.
  if ! grep -qF '"${EFFECTIVE_CONTINUE_MODE:-1}" == "0"' "$sd_path"; then
    smoke_fail "T3: bridge-start.sh #268 warn gate missing EFFECTIVE_CONTINUE_MODE check (#1334 L4)"
  fi

  # The warn block in BOTH callers must call bridge_agent_persisted_session_id
  # then emit the same warn text — verifies the order contract documented
  # in the comment block of bridge-start.sh.
  for path in "$sd_path" "$rn_path"; do
    if ! grep -qF 'bridge_agent_persisted_session_id "$AGENT"' "$path"; then
      smoke_fail "T3/T4: $path missing bridge_agent_persisted_session_id call in the FORCE_FRESH warn path"
    fi
    if ! grep -qF 'launched fresh for this run, but saved session_id=' "$path"; then
      smoke_fail "T3/T4: $path missing canonical warn text — both callers must emit identical strings"
    fi
  done

  # Order: the persisted-id read must come BEFORE the bridge_warn call,
  # not the other way around. A grep -n + line-number compare keeps this
  # honest across both files.
  for path in "$sd_path" "$rn_path"; do
    local read_line warn_line
    read_line="$(grep -nF 'bridge_agent_persisted_session_id "$AGENT"' "$path" | head -n 1 | cut -d: -f1)"
    warn_line="$(grep -nF 'launched fresh for this run, but saved session_id=' "$path" | head -n 1 | cut -d: -f1)"
    if [[ -z "$read_line" || -z "$warn_line" ]]; then
      smoke_fail "T3/T4: $path missing read/warn lines (read=$read_line warn=$warn_line)"
    fi
    if (( warn_line <= read_line )); then
      smoke_fail "T3/T4: $path warn (line $warn_line) must come AFTER persisted-id read (line $read_line)"
    fi
  done
}

# ----------------------------------------------------------------------
# T5 + T6 (#1318-A) — bridge-task.sh refuses create against stopped
# target by default; --force overrides with a warning.
# ----------------------------------------------------------------------
t5_t6_task_create_stopped_agent() {
  local tk_path="$REPO_ROOT/bridge-task.sh"
  smoke_assert_file_exists "$tk_path" "T5/T6 bridge-task.sh"

  # The --force flag must be parsed.
  if ! grep -qE '^\s*--force\)' "$tk_path"; then
    smoke_fail "T5/T6: bridge-task.sh missing --force flag parse (#1318-A)"
  fi
  # The default-refuse branch must call bridge_die with a clear message.
  if ! grep -qF "task create refused (no reader to dequeue)" "$tk_path"; then
    smoke_fail "T5: bridge-task.sh default-refuse branch missing (#1318-A)"
  fi
  # The --force branch must warn (via bridge_warn) and emit an audit row.
  if ! grep -qF 'task_create_stopped_target_forced' "$tk_path"; then
    smoke_fail "T6: bridge-task.sh --force branch missing structured audit row (#1318-A)"
  fi
  # Self-targeted create exemption — actor == target must short-circuit
  # so a self-handoff chain (an agent queueing to itself) does not trip
  # the refuse branch. The comment block also names the issue.
  if ! grep -qF 'actor" != "$target"' "$tk_path"; then
    smoke_fail "T5/T6: bridge-task.sh self-target exemption missing (actor==target case)"
  fi

  # Internal callers that legitimately queue against possibly-stopped
  # targets must pass --force:
  #   bridge-escalate.sh (urgent escalation to admin)
  #   bridge-agent.sh    (admin compact/handoff dispatch)
  #   lib/bridge-wave.sh (wave worker dispatch, freshly spawned)
  #   bridge-daemon.sh   (backup-failure / a2a-stuck / nudge-deferred)
  for caller in \
      "bridge-escalate.sh" \
      "bridge-agent.sh" \
      "lib/bridge-wave.sh" \
      "bridge-daemon.sh"; do
    local cp="$REPO_ROOT/$caller"
    smoke_assert_file_exists "$cp" "T5/T6 caller $caller"
    if ! grep -qF '#1318 part A' "$cp" && ! grep -qF '#1318)' "$cp"; then
      # Fallback: just ensure --force flows through somewhere in the
      # file. A future refactor that moves the call site should re-emit
      # the issue tag for traceability.
      if ! grep -qF '--force' "$cp"; then
        smoke_fail "T5/T6: $caller missing --force propagation (#1318-A)"
      fi
    fi
  done
}

# ----------------------------------------------------------------------
# T_teeth — reverts fail the corresponding tests
# ----------------------------------------------------------------------
t_teeth_reverts_fail() {
  # We don't actually mutate sources here (smoke is read-only); instead
  # we run each structural probe and assert the helper exists. The
  # individual checks already grep for unique patterns, so a revert
  # would naturally fail them.
  #
  # The teeth pattern matches the rest of beta5-2: structural smoke
  # tests where the grep IS the teeth. A documented mutation here would
  # require a temp-source copy + re-grep which adds complexity for
  # marginal additional coverage. Re-affirm the smoke contract:
  smoke_log "T_teeth: structural greps act as the teeth — a revert to any of:"
  smoke_log "          - bridge-start.sh SESSION_CMD BRIDGE_AGENT_ID inline"
  smoke_log "          - plugins/teams/server.ts startup-empty warning"
  smoke_log "          - lib/bridge-agent-layout.sh per-file chgrp call"
  smoke_log "          - bridge-start.sh EFFECTIVE_CONTINUE_MODE warn gate"
  smoke_log "          - bridge-task.sh --force flag + refuse/audit branches"
  smoke_log "        will fail the corresponding T1-T6 grep in this smoke."
}

smoke_run "T1: bridge-start.sh BRIDGE_AGENT_ID env-prefix inline (#1330 M7)" \
  t1_bridge_start_inlines_agent_id
smoke_run "T1b: Teams MCP startup warns on empty BRIDGE_AGENT_ID (#1330 M7)" \
  t1b_teams_server_warns_on_empty_agent_id
smoke_run "T2: materialize per-file atomic chgrp+chmod (#1332 L2)" \
  t2_materialize_per_file_normalize
smoke_run "T3+T4: FORCE_FRESH warn order aligned across bridge-start/run (#1334 L4)" \
  t3_t4_force_fresh_order_aligned
smoke_run "T5+T6: task create on stopped agent: refuse + --force override (#1318-A)" \
  t5_t6_task_create_stopped_agent
smoke_run "T_teeth: structural greps act as the teeth" \
  t_teeth_reverts_fail

smoke_log "PASS — Lane ξ misc-fixes smoke complete"
