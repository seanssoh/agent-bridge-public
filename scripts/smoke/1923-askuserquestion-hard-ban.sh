#!/usr/bin/env bash
# scripts/smoke/1923-askuserquestion-hard-ban.sh
#
# #1923 — hard-ban AskUserQuestion for ALL bridge Claude agents (scope A:
# bridge-managed settings only, NEVER the operator-global ~/.claude).
#
# Two layers (codex spec verdict 1c):
#   1. a dedicated PreToolUse deny hook hooks/askuserquestion-ban.py — the
#      GUARANTEED mechanism under --dangerously-skip-permissions (a structured
#      `permissionDecision: deny` fires before the permission-prompt system);
#   2. a scoped `permissions.deny: ["AskUserQuestion(*)"]` entry as
#      defense-in-depth (UNVERIFIED against live Claude Code; the hook is SSOT).
#
# For a dynamic-vanilla Claude agent (#1890: comms hooks only, no tool-policy.py)
# the ban is written into <workdir>/.claude/settings.local.json — the ONLY
# AskUserQuestion safety surface that path gets. For hook-managed agents the
# scoped deny is re-asserted at the FINAL render invariant (post-merge), because
# merge_settings REPLACES lists.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; temp workdirs under
# SMOKE_TMP_ROOT; HOME repointed at a temp operator home. Platform forced Darwin
# so linux-user isolation is never effective (the shared-mode shape #1890/#1923
# target). Footgun #11 / #1813: NO heredoc-stdin / `<<<` / `< <()` / `| grep -q`;
# all JSON inspection via `python3 -c` (file-arg, never `python3 -`).

set -euo pipefail

SMOKE_NAME="1923-askuserquestion-hard-ban"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd git

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

BASH4_BIN="${BRIDGE_BASH_BIN:-${BASH:-bash}}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
mkdir -p "$OPERATOR_HOME"

# The bridge hooks resolve from $BRIDGE_HOME/hooks; seed the real hook there so
# the rendered command path points at a file that actually exists. Tolerant of
# absence so a teeth run against a pre-#1923 source tree fails on the behavior
# assertion (the ban helper is missing), not on this setup copy.
mkdir -p "$BRIDGE_HOME/hooks"
cp "$REPO_ROOT/hooks/askuserquestion-ban.py" "$BRIDGE_HOME/hooks/askuserquestion-ban.py" 2>/dev/null || true
cp "$REPO_ROOT/hooks/tool-policy.py" "$BRIDGE_HOME/hooks/tool-policy.py" 2>/dev/null || true

PY="$(command -v python3)"

# --- small python inspectors (file-arg only; never `python3 -`) -------------
# COUNT of PreToolUse groups whose matcher == AskUserQuestion in <file>.
auq_pretool_group_count() {
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
g=[x for x in d.get("hooks",{}).get("PreToolUse",[]) if isinstance(x,dict) and x.get("matcher")=="AskUserQuestion"]
print(len(g))' "$1"
}
# COUNT of askuserquestion-ban.py command hooks across ALL PreToolUse groups.
auq_ban_hook_count() {
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
n=0
for grp in d.get("hooks",{}).get("PreToolUse",[]):
    for h in (grp.get("hooks") or []):
        if "askuserquestion-ban.py" in str(h.get("command") or ""):
            n+=1
print(n)' "$1"
}
# COUNT of AskUserQuestion(*) entries in permissions.deny in <file>.
auq_deny_count() {
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
deny=(d.get("permissions") or {}).get("deny") or []
print(sum(1 for x in deny if x=="AskUserQuestion(*)"))' "$1"
}
# 'yes' if a tool-policy.py command hook is present in PreToolUse, else 'no'.
tool_policy_pretool_present() {
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for grp in d.get("hooks",{}).get("PreToolUse",[]):
    for h in (grp.get("hooks") or []):
        if "tool-policy.py" in str(h.get("command") or ""):
            print("yes"); raise SystemExit
print("no")' "$1"
}
# 'yes' if <file> permissions.deny contains <rule> arg2, else 'no'.
deny_contains() {
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
deny=(d.get("permissions") or {}).get("deny") or []
print("yes" if sys.argv[2] in deny else "no")' "$1" "$2"
}
# value of a top-level string key arg2 in <file>, or empty.
json_key() {
  "$PY" -c 'import json,sys
print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"
}

# lib_eval — source the full library, reset roster, register one Claude agent of
# the requested <source> for <workdir>, then run <snippet>. Darwin-forced.
lib_eval() {
  local agent="$1" src="$2" workdir="$3" snippet="$4"
  HOME="$OPERATOR_HOME" \
  BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  "$BASH4_BIN" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_reset_roster_maps
    agent='$agent'
    BRIDGE_AGENT_IDS+=(\$agent)
    BRIDGE_AGENT_ENGINE[\$agent]=claude
    BRIDGE_AGENT_SESSION[\$agent]=\$agent
    BRIDGE_AGENT_WORKDIR[\$agent]='$workdir'
    BRIDGE_AGENT_SOURCE[\$agent]='$src'
    BRIDGE_AGENT_ISOLATION_MODE[\$agent]=shared
    BRIDGE_AGENT_CREATED_AT[\$agent]=\$(date +%s)
    $snippet
  "
}

# ===========================================================================
# Case 1 — dynamic-vanilla render: settings.local.json gets EXACTLY one
# AskUserQuestion PreToolUse group + one AskUserQuestion(*) deny, the operator
# key is preserved, and the file is git-excluded.
# ===========================================================================
test_1_vanilla_local() {
  local wd="$SMOKE_TMP_ROOT/wd-vanilla"
  mkdir -p "$wd/.claude"
  ( cd "$wd" && git init -q && git config core.excludesfile /dev/null )
  printf '{"operatorKey":"keepme"}\n' > "$wd/.claude/settings.local.json"

  lib_eval "v1" dynamic "$wd" '
    bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v1" >/dev/null 2>&1 || exit 9
  ' >/dev/null 2>&1 || smoke_fail "1 vanilla ban lib_eval failed"

  local sf="$wd/.claude/settings.local.json"
  smoke_assert_file_exists "$sf" "1 ban writes to <workdir>/.claude/settings.local.json"
  [[ ! -e "$wd/.claude/settings.json" ]] \
    || smoke_fail "1 vanilla agent must NOT create a managed settings.json"

  smoke_assert_eq "1" "$(auq_pretool_group_count "$sf")" "1 exactly one AskUserQuestion PreToolUse group"
  smoke_assert_eq "1" "$(auq_ban_hook_count "$sf")" "1 exactly one askuserquestion-ban.py command hook"
  smoke_assert_eq "1" "$(auq_deny_count "$sf")" "1 exactly one AskUserQuestion(*) deny entry"
  smoke_assert_eq "keepme" "$(json_key "$sf" operatorKey)" "1 operator key preserved"
  grep -qxF ".claude/settings.local.json" "$wd/.git/info/exclude" \
    || smoke_fail "1 .git/info/exclude must list .claude/settings.local.json"
}

# ===========================================================================
# Case 2 — idempotent: running ensure twice does not duplicate the hook group
# or the deny entry.
# ===========================================================================
test_2_idempotent() {
  local wd="$SMOKE_TMP_ROOT/wd-idem"
  mkdir -p "$wd/.claude"
  ( cd "$wd" && git init -q && git config core.excludesfile /dev/null )

  lib_eval "v2" dynamic "$wd" '
    bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v2" >/dev/null 2>&1 || exit 9
    bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v2" >/dev/null 2>&1 || exit 9
  ' >/dev/null 2>&1 || smoke_fail "2 idempotent lib_eval failed"

  local sf="$wd/.claude/settings.local.json"
  smoke_assert_eq "1" "$(auq_pretool_group_count "$sf")" "2 still exactly one AskUserQuestion group after 2 runs"
  smoke_assert_eq "1" "$(auq_ban_hook_count "$sf")" "2 still exactly one ban hook after 2 runs"
  smoke_assert_eq "1" "$(auq_deny_count "$sf")" "2 still exactly one deny entry after 2 runs"
}

# ===========================================================================
# Case 3 — tracked settings.local.json: ensure FAILS LOUD (rc!=0) and leaves
# the committed operator file byte-for-byte untouched.
# ===========================================================================
test_3_tracked_loud_fail() {
  local wd="$SMOKE_TMP_ROOT/wd-tracked"
  mkdir -p "$wd/.claude"
  (
    cd "$wd" && git init -q && git config core.excludesfile /dev/null
    printf '{"operatorKey":"committed"}\n' > .claude/settings.local.json
    git add -f .claude/settings.local.json
    git -c user.email=a@b.c -c user.name=x commit -qm init
  )
  local before after rc=0
  before="$(cat "$wd/.claude/settings.local.json")"
  lib_eval "v3" dynamic "$wd" '
    if bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v3" >/dev/null 2>&1; then exit 0; else exit 7; fi
  ' >/dev/null 2>&1 || rc=$?
  after="$(cat "$wd/.claude/settings.local.json")"

  smoke_assert_eq "7" "$rc" "3 ensure ABORTS (rc!=0) when settings.local.json is git-tracked"
  smoke_assert_eq "$before" "$after" "3 tracked operator file is byte-for-byte unchanged"
}

# ===========================================================================
# Case 3b — invalid operator permissions.deny shape (non-list): ensure FAILS
# LOUD and leaves the file untouched (never clobbers operator data).
# ===========================================================================
test_3b_invalid_deny_shape_loud_fail() {
  local wd="$SMOKE_TMP_ROOT/wd-baddeny"
  mkdir -p "$wd/.claude"
  ( cd "$wd" && git init -q && git config core.excludesfile /dev/null )
  printf '{"permissions":{"deny":"Bash(rm *)"}}' > "$wd/.claude/settings.local.json"

  local before after rc=0
  before="$(cat "$wd/.claude/settings.local.json")"
  lib_eval "v3b" dynamic "$wd" '
    if bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v3b" >/dev/null 2>&1; then exit 0; else exit 8; fi
  ' >/dev/null 2>&1 || rc=$?
  after="$(cat "$wd/.claude/settings.local.json")"

  smoke_assert_eq "8" "$rc" "3b ensure ABORTS on a non-list permissions.deny (operator data)"
  smoke_assert_eq "$before" "$after" "3b invalid-shape operator file is byte-for-byte unchanged"
}

# ===========================================================================
# Case 3c — explicit JSON null permissions.deny is NOT a dict/list: ensure
# FAILS LOUD and leaves the file untouched (a `null` is invalid operator data,
# not an absent key — never silently materialize managed structure into it).
# ===========================================================================
test_3c_null_deny_loud_fail() {
  local wd="$SMOKE_TMP_ROOT/wd-nulldeny"
  mkdir -p "$wd/.claude"
  ( cd "$wd" && git init -q && git config core.excludesfile /dev/null )
  printf '{"permissions":{"deny":null}}' > "$wd/.claude/settings.local.json"

  local before after rc=0
  before="$(cat "$wd/.claude/settings.local.json")"
  lib_eval "v3c" dynamic "$wd" '
    if bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v3c" >/dev/null 2>&1; then exit 0; else exit 8; fi
  ' >/dev/null 2>&1 || rc=$?
  after="$(cat "$wd/.claude/settings.local.json")"

  smoke_assert_eq "8" "$rc" "3c ensure ABORTS on an explicit null permissions.deny"
  smoke_assert_eq "$before" "$after" "3c null-deny operator file is byte-for-byte unchanged"
}

# ===========================================================================
# Case 4 — backfill: a pre-#1923 vanilla agent (settings.local.json with NO
# AskUserQuestion deny) gets the ban via the start-path ensure AND via the
# upgrade propagation helper (same helper, both call sites). Assert idempotent
# across the two passes.
# ===========================================================================
test_4_backfill() {
  local wd="$SMOKE_TMP_ROOT/wd-backfill"
  mkdir -p "$wd/.claude"
  ( cd "$wd" && git init -q && git config core.excludesfile /dev/null )
  # Pre-#1923 shape: a comms hook present, no AskUserQuestion ban.
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}\n' \
    > "$wd/.claude/settings.local.json"

  local sf="$wd/.claude/settings.local.json"
  smoke_assert_eq "0" "$(auq_ban_hook_count "$sf")" "4 pre-state: no ban hook yet"

  lib_eval "v4" dynamic "$wd" '
    bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v4" >/dev/null 2>&1 || exit 9
    bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v4" >/dev/null 2>&1 || exit 9
  ' >/dev/null 2>&1 || smoke_fail "4 backfill lib_eval failed"

  smoke_assert_eq "1" "$(auq_ban_hook_count "$sf")" "4 backfill installs exactly one ban hook"
  smoke_assert_eq "1" "$(auq_deny_count "$sf")" "4 backfill installs exactly one deny entry"
  local hasstop
  hasstop="$("$PY" -c 'import json,sys;print("yes" if "Stop" in json.load(open(sys.argv[1])).get("hooks",{}) else "no")' "$sf")"
  smoke_assert_eq "yes" "$hasstop" "4 pre-existing comms hook preserved through backfill"
}

# ===========================================================================
# Case 5 — hook-managed (shared) render: the scoped deny lands at the FINAL
# render invariant, and an existing tool-policy.py PreToolUse hook in the base
# is preserved in the effective file.
# ===========================================================================
test_5_render_invariant() {
  local base="$SMOKE_TMP_ROOT/render5-base.json"
  local overlay="$SMOKE_TMP_ROOT/render5-overlay.json"
  local eff="$SMOKE_TMP_ROOT/render5-eff.json"
  # Base carries the managed tool-policy.py PreToolUse hook (hook-managed agent).
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"python3 /x/hooks/tool-policy.py","timeout":3}]}]}}' > "$base"
  printf '{}\n' > "$overlay"

  "$PY" "$REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$base" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$eff" \
    --launch-cmd "" >/dev/null

  smoke_assert_file_exists "$eff" "5 effective file rendered"
  smoke_assert_eq "yes" "$(tool_policy_pretool_present "$eff")" "5 tool-policy.py PreToolUse hook preserved in effective render"
  smoke_assert_eq "yes" "$(deny_contains "$eff" "AskUserQuestion(*)")" "5 scoped deny asserted at final render invariant"
}

# ===========================================================================
# Case 6 — overlay/preserved collision: an existing permissions.deny entry
# (Bash(rm *)) renders to an effective file containing BOTH it and
# AskUserQuestion(*) (the post-merge ensure appends, never replaces).
# ===========================================================================
test_6_overlay_collision() {
  local base="$SMOKE_TMP_ROOT/render6-base.json"
  local overlay="$SMOKE_TMP_ROOT/render6-overlay.json"
  local eff="$SMOKE_TMP_ROOT/render6-eff.json"
  printf '{}\n' > "$base"
  printf '%s\n' '{"permissions":{"deny":["Bash(rm *)"]}}' > "$overlay"

  "$PY" "$REPO_ROOT/bridge-hooks.py" render-shared-settings \
    --base-settings-file "$base" \
    --overlay-settings-file "$overlay" \
    --effective-settings-file "$eff" \
    --launch-cmd "" >/dev/null

  smoke_assert_eq "yes" "$(deny_contains "$eff" "Bash(rm *)")" "6 pre-existing Bash(rm *) deny preserved"
  smoke_assert_eq "yes" "$(deny_contains "$eff" "AskUserQuestion(*)")" "6 AskUserQuestion(*) deny added alongside"
  smoke_assert_eq "1" "$(auq_deny_count "$eff")" "6 AskUserQuestion(*) appears exactly once (no dup)"
}

# ===========================================================================
# Case 7 — SCOPE A guard: the operator-global ~/.claude/settings.json is
# byte-for-byte unchanged, and no ~/.claude/managed-settings.json is written,
# by the whole vanilla ensure + render flow.
# ===========================================================================
test_7_scope_a_operator_global_untouched() {
  mkdir -p "$OPERATOR_HOME/.claude"
  local opglobal="$OPERATOR_HOME/.claude/settings.json"
  printf '{"operatorGlobalKey":"sacred","model":"opus"}\n' > "$opglobal"
  local before; before="$(cat "$opglobal")"
  [[ ! -e "$OPERATOR_HOME/.claude/managed-settings.json" ]] \
    || smoke_fail "7 pre-state: managed-settings.json must not pre-exist"

  local wd="$SMOKE_TMP_ROOT/wd-scopea"
  mkdir -p "$wd/.claude"
  ( cd "$wd" && git init -q && git config core.excludesfile /dev/null )
  lib_eval "v7" dynamic "$wd" '
    bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v7" >/dev/null 2>&1 || exit 9
  ' >/dev/null 2>&1 || smoke_fail "7 scope-a lib_eval failed"

  local after; after="$(cat "$opglobal")"
  smoke_assert_eq "$before" "$after" "7 operator-global ~/.claude/settings.json bytes UNCHANGED"
  [[ ! -e "$OPERATOR_HOME/.claude/managed-settings.json" ]] \
    || smoke_fail "7 ~/.claude/managed-settings.json must NOT be written (scope A)"
}

# ===========================================================================
# Case 8 — Codex guard: the AskUserQuestion ban is Claude-only; a dynamic
# vanilla Codex agent's project-local <workdir>/.codex/hooks.json (and any
# .codex settings) is NOT touched by the Claude ban helper.
# ===========================================================================
test_8_codex_untouched() {
  local wd="$SMOKE_TMP_ROOT/wd-codex"
  mkdir -p "$wd/.codex"
  printf '{"codexKey":"untouched"}\n' > "$wd/.codex/hooks.json"
  local before; before="$(cat "$wd/.codex/hooks.json")"

  # Run the Claude ban helper against a Claude agent sharing the workdir; the
  # Codex sidecar must remain byte-for-byte unchanged.
  mkdir -p "$wd/.claude"
  ( cd "$wd" && git init -q && git config core.excludesfile /dev/null )
  lib_eval "v8" dynamic "$wd" '
    bridge_ensure_claude_askuserquestion_ban "'"$wd"'" "" "v8" >/dev/null 2>&1 || exit 9
  ' >/dev/null 2>&1 || smoke_fail "8 codex-guard lib_eval failed"

  local after; after="$(cat "$wd/.codex/hooks.json")"
  smoke_assert_eq "$before" "$after" "8 dynamic vanilla Codex .codex/hooks.json is unchanged (Claude-only ban)"
}

# --- run ------------------------------------------------------------------
smoke_run "1 vanilla render -> settings.local.json (group+deny, operator key, exclude)" test_1_vanilla_local
smoke_run "2 idempotent (no dup hook/deny on second run)" test_2_idempotent
smoke_run "3 tracked settings.local.json -> loud fail, unchanged" test_3_tracked_loud_fail
smoke_run "3b invalid permissions.deny shape -> loud fail, unchanged" test_3b_invalid_deny_shape_loud_fail
smoke_run "3c explicit null permissions.deny -> loud fail, unchanged" test_3c_null_deny_loud_fail
smoke_run "4 backfill pre-#1923 vanilla agent (start ensure + idempotent)" test_4_backfill
smoke_run "5 hook-managed render: tool-policy preserved + deny at final invariant" test_5_render_invariant
smoke_run "6 overlay collision: Bash(rm *) + AskUserQuestion(*) both present, once" test_6_overlay_collision
smoke_run "7 SCOPE A: operator-global ~/.claude untouched + no managed-settings.json" test_7_scope_a_operator_global_untouched
smoke_run "8 Codex guard: dynamic vanilla .codex/hooks.json unchanged" test_8_codex_untouched

smoke_log "PASS — #1923 AskUserQuestion hard-ban: dedicated PreToolUse deny hook in vanilla settings.local.json + scoped AskUserQuestion(*) deny at the final render invariant; idempotent, fail-loud on operator data, scope A (operator-global untouched), Codex unaffected. NOTE: scoped AskUserQuestion(*) specifier + no-picker behavior need a LIVE Claude Code check (spec case 9)."
