#!/usr/bin/env bash
# scripts/smoke/1766-iso-settings-readable.sh — issue #1766.
#
# On an iso v2 host every agent's `workdir/.claude/settings.json` is a symlink
# to the per-agent-root `agents/<a>/.claude/settings.effective.json`, which
# `bridge-hooks.py:save_json` renders controller-owned mode 0600 with the
# parent `.claude/` at controller-owned 0700. The iso UID `agent-bridge-<a>`
# is NOT the controller, so it EACCESes on its OWN project settings and Claude
# renders a blocking "Settings Error" picker on every (re)start — load-bearing
# during a restart storm.
#
# THE FIX (three directions):
#   (1) Publish readable: the per-agent effective file is group-published
#       `chgrp ab-agent-<a>` + 0640 (group READ only — file stays controller-
#       owned so the iso UID can never rewrite the hook contract), and the
#       parent `.claude/` dir made group-traversable at 0750. Never ab-shared,
#       never world. Applied at both the render site
#       (bridge_link_claude_settings_to_shared) and the prepare/reapply site
#       (bridge_linux_prepare_agent_isolation's content-tree publish).
#   (2) Reapply normalizes: the content-tree walker's planted-redirect guard
#       (isolation-normalize-content-tree.py) now ACCEPTS exactly the canonical
#       `settings.json -> settings.effective.json` self-target symlink (target-
#       VALIDATED, not name-validated) and chgrp's the LINK to the agent group
#       via lchown; every OTHER symlink target stays refused.
#   (3) Picker catalog: a "Settings Error" fingerprint (#1762 catalog) with
#       policy=auto_resolve -> option "3. Continue without these settings" so
#       startup is unblocked even if perms regress.
#
# Cases (all in a temp dir; never touches live runtime). The shell publish
# helpers are exercised on macOS by stubbing the v2-enforce gate ON and the
# agent-group resolver to the operator's primary group; the root walker runs
# the real fd-based path off Linux via bridge_linux_sudo_root's direct
# fall-through.
#
#   T1  publish: an iso-v2-flagged per-agent `.claude/settings.effective.json`
#       fixture (controller:0600) + parent `.claude/` is group-published —
#       file 0640 / dir 0750 / both to the agent group — by the lib chgrp
#       helpers (the same primitives the fix calls).
#   T2  walker ACCEPTS the canonical self-target symlink: a workdir fixture
#       whose `.claude/settings.json -> ../../.claude/settings.effective.json`
#       resolves to THIS agent's own effective file is accepted (status
#       `accepted-settings-symlink`), not refused.
#   T3  walker still REFUSES a `.claude/settings.json` link to ANOTHER agent's
#       effective file (target-validated, not name-validated).
#   T4  walker still REFUSES a `.claude/settings.json` link to an arbitrary
#       external path; the external target is never touched.
#   T5  walker WITHOUT the accept args refuses the canonical self-link too
#       (no behavior change when the fix is not engaged — regression guard).
#   T6  picker catalog: the shipped `claude-settings-error` entry parses, is
#       enabled, and MATCHES a fixture capture of the Settings Error picker via
#       the #1762 matcher (lib/bridge-picker.py classify) with policy
#       auto_resolve + the option-3 key sequence; an unrelated pane does NOT
#       match.
#
# Footgun #11 mitigation: zero heredoc-stdin to a subprocess; every python
# assertion runs via `python3 <file>` with argv-only arguments. Fixtures are
# written with printf to tempfiles.

set -uo pipefail

SMOKE_NAME="1766-iso-settings-readable"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

export BRIDGE_LAYOUT="v2"
export BRIDGE_DATA_ROOT="$SMOKE_TMP_ROOT/data"
mkdir -p "$BRIDGE_DATA_ROOT"

WALKER="$REPO_ROOT/scripts/python-helpers/isolation-normalize-content-tree.py"
[[ -f "$WALKER" ]] || smoke_fail "missing walker: $WALKER"
HELPER_DIR="$SCRIPT_DIR/1766-iso-settings-helpers"
ASSERT="$HELPER_DIR/assert-mode-group.py"
[[ -f "$ASSERT" ]] || smoke_fail "missing $ASSERT (#1766 helpers)"
PICKER_PY="$REPO_ROOT/lib/bridge-picker.py"
CATALOG="$REPO_ROOT/runtime-templates/shared/picker-catalog.json"
[[ -f "$PICKER_PY" ]] || smoke_fail "missing $PICKER_PY"
[[ -f "$CATALOG" ]] || smoke_fail "missing $CATALOG"

OPERATOR_GROUP="$(id -gn 2>/dev/null || printf '')"
[[ -n "$OPERATOR_GROUP" ]] || smoke_fail "could not resolve operator primary group"

# =====================================================================
# T1 — publish: lib chgrp helpers group-publish the per-agent effective
#      file (0640) + parent dir (0750) to the agent group. We invoke the
#      SAME primitives the fix calls, with the v2-enforce gate stubbed ON
#      and the agent-group resolver pinned to the operator's own group.
# =====================================================================
T1_ROOT="$SMOKE_TMP_ROOT/t1-agentroot"
mkdir -p "$T1_ROOT/.claude"
: >"$T1_ROOT/.claude/settings.effective.json"
chmod 0600 "$T1_ROOT/.claude/settings.effective.json"
chmod 0700 "$T1_ROOT/.claude"

T1_LOG="$SMOKE_TMP_ROOT/t1.log"
(
  set +e
  # shellcheck disable=SC1090
  source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1
  # shellcheck disable=SC2329
  bridge_isolation_v2_enforce() { return 0; }
  # shellcheck disable=SC2329
  bridge_isolation_v2_agent_group_name() { printf '%s' "$OPERATOR_GROUP"; }
  bridge_isolation_v2_chgrp_dir_iso_group "test_agent" "$T1_ROOT/.claude" 0750
  printf 'dir_rc=%s\n' "$?"
  bridge_isolation_v2_chgrp_file_iso_group "test_agent" "$T1_ROOT/.claude/settings.effective.json" 0640
  printf 'file_rc=%s\n' "$?"
) >"$T1_LOG" 2>&1
smoke_assert_contains "$(cat "$T1_LOG")" "dir_rc=0" "T1 dir publish rc"
smoke_assert_contains "$(cat "$T1_LOG")" "file_rc=0" "T1 file publish rc"
"$PY_BIN" "$ASSERT" "$T1_ROOT/.claude" "$OPERATOR_GROUP" 0750 \
  || smoke_fail "T1 FAIL — parent .claude/ not group:0750 (iso UID cannot traverse)"
"$PY_BIN" "$ASSERT" "$T1_ROOT/.claude/settings.effective.json" "$OPERATOR_GROUP" 0640 \
  || smoke_fail "T1 FAIL — settings.effective.json not group:0640 (iso UID EACCES)"
smoke_log "T1 PASS — effective file 0640 + parent .claude/ 0750, both to agent group"

# =====================================================================
# Shared fixture for T2-T5: a per-agent root with a workdir whose
# `.claude/settings.json` symlinks to the per-agent-root effective file.
# =====================================================================
make_agent_fixture() {
  local root="$1"
  mkdir -p "$root/.claude" "$root/workdir/.claude"
  : >"$root/.claude/settings.effective.json"
  chmod 0600 "$root/.claude/settings.effective.json"
  ( cd "$root/workdir/.claude" \
      && ln -s "../../.claude/settings.effective.json" settings.json )
}

# =====================================================================
# T2 — walker ACCEPTS the canonical self-target symlink.
# =====================================================================
T2_ROOT="$SMOKE_TMP_ROOT/t2-agentroot"
make_agent_fixture "$T2_ROOT"
T2_OUT="$SMOKE_TMP_ROOT/t2.out"
"$PY_BIN" "$WALKER" "$OPERATOR_GROUP" 0660 2770 "" "$T2_ROOT/workdir" \
  --accept-settings-link-rel ".claude/settings.json" \
  --accept-settings-link-target "$T2_ROOT/.claude/settings.effective.json" \
  >"$T2_OUT" 2>&1
smoke_assert_contains "$(cat "$T2_OUT")" "accepted-settings-symlink	.claude/settings.json" \
  "T2 canonical self-target link ACCEPTED"
smoke_assert_not_contains "$(cat "$T2_OUT")" "refused-symlink	.claude/settings.json" \
  "T2 canonical link not also refused"
[[ -L "$T2_ROOT/workdir/.claude/settings.json" ]] \
  || smoke_fail "T2 FAIL — link was followed/replaced (must stay a symlink)"
smoke_log "T2 PASS — canonical settings.json self-target accepted"

# =====================================================================
# T3 — walker REFUSES a settings.json link to ANOTHER agent's effective
#      file (target-validated, not name-validated).
# =====================================================================
T3_ROOT="$SMOKE_TMP_ROOT/t3-agentroot"
make_agent_fixture "$T3_ROOT"
T3_OTHER="$SMOKE_TMP_ROOT/t3-other/.claude/settings.effective.json"
mkdir -p "$(dirname "$T3_OTHER")"; : >"$T3_OTHER"
T3_OUT="$SMOKE_TMP_ROOT/t3.out"
"$PY_BIN" "$WALKER" "$OPERATOR_GROUP" 0660 2770 "" "$T3_ROOT/workdir" \
  --accept-settings-link-rel ".claude/settings.json" \
  --accept-settings-link-target "$T3_OTHER" \
  >"$T3_OUT" 2>&1
smoke_assert_contains "$(cat "$T3_OUT")" "refused-symlink	.claude/settings.json" \
  "T3 link to ANOTHER agent's effective file REFUSED"
smoke_assert_not_contains "$(cat "$T3_OUT")" "accepted-settings-symlink" \
  "T3 wrong-target link NOT accepted (target-validated)"
smoke_log "T3 PASS — non-self-target settings.json link refused"

# =====================================================================
# T4 — walker REFUSES a settings.json link to an arbitrary external path;
#      the external target is untouched.
# =====================================================================
T4_ROOT="$SMOKE_TMP_ROOT/t4-agentroot"
mkdir -p "$T4_ROOT/workdir/.claude"
T4_EXT="$SMOKE_TMP_ROOT/t4-external.json"; : >"$T4_EXT"; chmod 0600 "$T4_EXT"
( cd "$T4_ROOT/workdir/.claude" && ln -s "$T4_EXT" settings.json )
T4_OUT="$SMOKE_TMP_ROOT/t4.out"
"$PY_BIN" "$WALKER" "$OPERATOR_GROUP" 0660 2770 "" "$T4_ROOT/workdir" \
  --accept-settings-link-rel ".claude/settings.json" \
  --accept-settings-link-target "$T4_ROOT/.claude/settings.effective.json" \
  >"$T4_OUT" 2>&1
smoke_assert_contains "$(cat "$T4_OUT")" "refused-symlink	.claude/settings.json" \
  "T4 arbitrary external-path link REFUSED"
smoke_assert_not_contains "$(cat "$T4_OUT")" "accepted-settings-symlink" \
  "T4 external link NOT accepted"
T4_EXT_MODE="$(stat -c '%a' "$T4_EXT" 2>/dev/null || stat -f '%Lp' "$T4_EXT" 2>/dev/null)"
smoke_assert_eq "600" "$T4_EXT_MODE" "T4 external target untouched (still 0600)"
smoke_log "T4 PASS — arbitrary external-path link refused; target untouched"

# =====================================================================
# T5 — WITHOUT the accept args the canonical self-link stays refused (no
#      behavior change when the fix is not engaged — regression guard).
# =====================================================================
T5_ROOT="$SMOKE_TMP_ROOT/t5-agentroot"
make_agent_fixture "$T5_ROOT"
T5_OUT="$SMOKE_TMP_ROOT/t5.out"
"$PY_BIN" "$WALKER" "$OPERATOR_GROUP" 0660 2770 "" "$T5_ROOT/workdir" \
  >"$T5_OUT" 2>&1
smoke_assert_contains "$(cat "$T5_OUT")" "refused-symlink	.claude/settings.json" \
  "T5 no-accept-args: canonical link still refused (unchanged default)"
smoke_assert_not_contains "$(cat "$T5_OUT")" "accepted-settings-symlink" \
  "T5 no-accept-args: nothing accepted"
smoke_log "T5 PASS — default (no accept args) refuses the link as before"

# =====================================================================
# T6 — picker catalog: the shipped claude-settings-error entry parses, is
#      enabled, and MATCHES a Settings Error capture via the #1762 matcher.
# =====================================================================
"$PY_BIN" -c "import json,sys; json.load(open(sys.argv[1]))" "$CATALOG" \
  || smoke_fail "T6 FAIL — shipped picker-catalog.json is not valid JSON"

# The entry must be present + enabled + claude-engine + auto_resolve.
CAT_CHECK="$SMOKE_TMP_ROOT/cat-check.out"
"$PY_BIN" "$HELPER_DIR/assert-catalog-entry.py" "$CATALOG" claude-settings-error \
  >"$CAT_CHECK" 2>&1 \
  || smoke_fail "T6 FAIL — claude-settings-error catalog entry invalid: $(cat "$CAT_CHECK")"
smoke_log "T6a PASS — claude-settings-error entry present/enabled/auto_resolve/option-3 keys"

# A fixture capture of the live Settings Error picker MUST match.
T6_PANE="$SMOKE_TMP_ROOT/t6-pane.txt"
printf '%s\n' \
  'Settings Error' \
  '  /home/agent-bridge-cosmax-sales/workdir/.claude/settings.json' \
  '   └ Settings file could not be read: EACCES: permission denied, open' \
  '  ❯ 1. Fix with Claude   2. Exit and fix manually   3. Continue without these settings' \
  '  Enter to confirm · Esc to cancel' \
  >"$T6_PANE"
T6_DECISION="$("$PY_BIN" "$PICKER_PY" classify --engine claude \
  --pane-file "$T6_PANE" --catalog "$CATALOG")"
smoke_assert_contains "$T6_DECISION" '"matched": true' "T6 Settings Error capture matches"
smoke_assert_contains "$T6_DECISION" '"picker_id": "claude-settings-error"' \
  "T6 matched picker_id is claude-settings-error"
smoke_assert_contains "$T6_DECISION" '"policy": "auto_resolve"' "T6 policy auto_resolve"

# A pane that lacks the Settings Error strings must NOT match this entry.
T6_NEG="$SMOKE_TMP_ROOT/t6-neg.txt"
printf '%s\n' 'Running tests...' 'All 42 passed.' '> ' >"$T6_NEG"
T6_NEG_DECISION="$("$PY_BIN" "$PICKER_PY" classify --engine claude \
  --pane-file "$T6_NEG" --catalog "$CATALOG")"
smoke_assert_not_contains "$T6_NEG_DECISION" '"picker_id": "claude-settings-error"' \
  "T6 ordinary pane does NOT match claude-settings-error"
smoke_log "T6 PASS — Settings Error picker fingerprint matches; ordinary pane does not"

smoke_log "ALL PASS"
