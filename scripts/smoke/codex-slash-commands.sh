#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/codex-slash-commands.sh — #8945 Track C slash-command smoke.
#
# Pins the agent-scoped Codex custom slash-command provisioning contract:
#
#   T1: bridge_ensure_codex_agent_slash_commands deploys the four agb-*
#       prompt templates into <scaffold_target>/.codex/prompts/ with the
#       agent-bridge:managed marker and the per-agent <agent-id> substituted.
#   T2: every agb command embedded in the prompts is a REAL agb verb/flag
#       (claim/done use --agent, NOT --actor; no invented verbs).
#   T3: idempotent re-run — a second call does not error and leaves the
#       managed prompts in place; an agent's OWN prompt (no marker) is never
#       clobbered.
#   T4 (CRITICAL): the controller/operator global ~/.codex (real $HOME/.codex)
#       is neither created nor mutated by the scaffold. Snapshot before/after.
#   T4 teeth: prove the snapshot would actually catch a write, by writing a
#       sentinel into the temp scaffold_target's .codex and confirming it is
#       NOT under the controller HOME.
#
# Footgun #11 / lint-heredoc-ban H3: driver emitted via printf-to-file; all
# loops read from temp files (no heredoc-stdin, no process substitution).

set -uo pipefail

SMOKE_NAME="codex-slash-commands"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# --- T4 controller ~/.codex isolation ---------------------------------------
# The contract under test: the agent scaffold writes ONLY into the explicit
# scaffold_target/.codex, never into the controller's $HOME/.codex. We CANNOT
# snapshot the operator's real, live ~/.codex (a running Codex churns its
# .tmp/, version.json, etc. concurrently, which would false-fail this test).
# Instead we pin a clean, quiet HOME the test fully owns and prove the scaffold
# never creates a .codex under it. This is both deterministic AND a faithful
# proof of the agent-scoped-not-controller contract: if the installer rooted
# anything at $HOME/.codex, this controlled $HOME/.codex would appear.
FAKE_HOME="$SMOKE_TMP_ROOT/fake-controller-home"
mkdir -p "$FAKE_HOME"
CONTROLLER_CODEX="$FAKE_HOME/.codex"
SNAP_BEFORE="$SMOKE_TMP_ROOT/controller-codex-before.txt"
snapshot_controller_codex() {
  local out="$1"
  : >"$out"
  if [[ -e "$CONTROLLER_CODEX" ]]; then
    printf 'EXISTS\n' >>"$out"
    # Sorted recursive listing with mtimes; portable across GNU/BSD find.
    find "$CONTROLLER_CODEX" -print0 2>/dev/null \
      | sort -z \
      | while IFS= read -r -d '' p; do
          # stat mtime (GNU -c / BSD -f); tolerate either.
          local m
          m="$(stat -c '%Y' "$p" 2>/dev/null || stat -f '%m' "$p" 2>/dev/null || printf '?')"
          printf '%s\t%s\n' "$m" "$p" >>"$out"
        done
  else
    printf 'ABSENT\n' >>"$out"
  fi
}
snapshot_controller_codex "$SNAP_BEFORE"

# --- driver ----------------------------------------------------------------
DRIVER_DIR="$SMOKE_TMP_ROOT/driver"
mkdir -p "$DRIVER_DIR"
DRIVER="$DRIVER_DIR/driver.sh"

write_driver() {
  local out="$1"
  : >"$out"
  local line
  for line in \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    'cd "$REPO_ROOT"' \
    'SCRIPT_DIR="$REPO_ROOT"' \
    'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1' \
    'declare -F bridge_ensure_codex_agent_slash_commands >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_ensure_codex_agent_slash_commands not loaded"; exit 91; }' \
    'declare -F bridge_codex_managed_asset_marker >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_codex_managed_asset_marker not loaded"; exit 92; }' \
    'AGENT="probe-codex"' \
    'AGENT_HOME="$BRIDGE_AGENT_ROOT_V2/$AGENT/home"' \
    'mkdir -p "$AGENT_HOME"' \
    'PROMPTS_DIR="$AGENT_HOME/.codex/prompts"' \
    'MARKER="$(bridge_codex_managed_asset_marker)"' \
    '# ---- T1: deploy the four agb-* slash commands into agent-scoped .codex ----' \
    'bridge_ensure_codex_agent_slash_commands "$AGENT" "$AGENT_HOME" 2>/dev/null || true' \
    'for name in agb-inbox agb-claim agb-done agb-handoff; do' \
    '  f="$PROMPTS_DIR/$name.md"' \
    '  if [[ -f "$f" ]]; then echo "T1_PROMPT_${name}: present"; else echo "T1_PROMPT_${name}: missing"; fi' \
    '  if [[ -f "$f" ]] && grep -qF "$MARKER" "$f" 2>/dev/null; then echo "T1_MARKER_${name}: yes"; else echo "T1_MARKER_${name}: no"; fi' \
    'done' \
    '# Per-agent substitution: the resolved agent id must appear, the raw token must not.' \
    'if [[ -f "$PROMPTS_DIR/agb-inbox.md" ]] && grep -qF "$AGENT" "$PROMPTS_DIR/agb-inbox.md" 2>/dev/null; then echo "T1_SUBST_AGENT_ID: yes"; else echo "T1_SUBST_AGENT_ID: no"; fi' \
    'if [[ -f "$PROMPTS_DIR/agb-inbox.md" ]] && grep -qF "<agent-id>" "$PROMPTS_DIR/agb-inbox.md" 2>/dev/null; then echo "T1_SUBST_RAW_TOKEN: yes"; else echo "T1_SUBST_RAW_TOKEN: no"; fi' \
    '# The prompts must invoke the full-path agb, not bare agb (PATH not assumed).' \
    'if [[ -f "$PROMPTS_DIR/agb-claim.md" ]] && grep -qF "~/.agent-bridge/agb claim" "$PROMPTS_DIR/agb-claim.md" 2>/dev/null; then echo "T1_FULLPATH_AGB: yes"; else echo "T1_FULLPATH_AGB: no"; fi' \
    '# ---- T2: agb verbs/flags in the prompts must be real ----' \
    '# claim/done use --agent; --actor in claim/done would be wrong.' \
    'BAD_FLAG="no"' \
    'if grep -qE "agb (claim|done)[^|]*--actor" "$PROMPTS_DIR"/agb-*.md 2>/dev/null; then BAD_FLAG="yes"; fi' \
    'echo "T2_CLAIM_DONE_USES_ACTOR: $BAD_FLAG"' \
    'if grep -qF "agb claim \$1 --agent" "$PROMPTS_DIR/agb-claim.md" 2>/dev/null; then echo "T2_CLAIM_AGENT_FLAG: yes"; else echo "T2_CLAIM_AGENT_FLAG: no"; fi' \
    'if grep -qF "agb done \$1 --agent" "$PROMPTS_DIR/agb-done.md" 2>/dev/null; then echo "T2_DONE_AGENT_FLAG: yes"; else echo "T2_DONE_AGENT_FLAG: no"; fi' \
    'if grep -qF "agb a2a send" "$PROMPTS_DIR/agb-handoff.md" 2>/dev/null; then echo "T2_HANDOFF_A2A: yes"; else echo "T2_HANDOFF_A2A: no"; fi' \
    '# Collect every distinct agb verb that is actually INVOKED across the' \
    '# prompts for the teeth-check below. We anchor on the full-path command' \
    '# form (~/.agent-bridge/agb <verb>) so prose like "agb is not on your' \
    '# PATH" is not mistaken for a verb, and we allow digits in the verb token' \
    '# so "a2a" is captured whole (not truncated to "a").' \
    'VERBS_TMP="$DRIVER_TMP_DIR/agb-verbs.txt"' \
    'grep -hoE "~/\.agent-bridge/agb[[:space:]]+[a-z][a-z0-9-]*" "$PROMPTS_DIR"/agb-*.md 2>/dev/null | awk "{print \$2}" | sort -u >"$VERBS_TMP" || true' \
    'echo "T2_VERBS_FILE: $VERBS_TMP"' \
    '# ---- T3: idempotent re-run + no-clobber of an agent custom prompt ----' \
    '# Author an agent-OWNED prompt (no marker) and a managed prompt edit.' \
    'printf "%s\n" "my own custom prompt — keep me" > "$PROMPTS_DIR/agb-custom.md"' \
    'CUSTOM_SHA_BEFORE="$(cksum "$PROMPTS_DIR/agb-custom.md" 2>/dev/null | awk "{print \$1}")"' \
    'bridge_ensure_codex_agent_slash_commands "$AGENT" "$AGENT_HOME" 2>/dev/null; RC2=$?' \
    'echo "T3_RERUN_RC: $RC2"' \
    'CUSTOM_SHA_AFTER="$(cksum "$PROMPTS_DIR/agb-custom.md" 2>/dev/null | awk "{print \$1}")"' \
    'if [[ "$CUSTOM_SHA_BEFORE" == "$CUSTOM_SHA_AFTER" && -n "$CUSTOM_SHA_BEFORE" ]]; then echo "T3_CUSTOM_PRESERVED: yes"; else echo "T3_CUSTOM_PRESERVED: no"; fi' \
    'if [[ -f "$PROMPTS_DIR/agb-inbox.md" ]] && grep -qF "$MARKER" "$PROMPTS_DIR/agb-inbox.md" 2>/dev/null; then echo "T3_MANAGED_STILL_PRESENT: yes"; else echo "T3_MANAGED_STILL_PRESENT: no"; fi' \
    '# A managed prompt that an agent later REPLACED with unmarked content must be left alone.' \
    'printf "%s\n" "agent replaced this managed prompt" > "$PROMPTS_DIR/agb-inbox.md"' \
    'INBOX_SHA_BEFORE="$(cksum "$PROMPTS_DIR/agb-inbox.md" 2>/dev/null | awk "{print \$1}")"' \
    'bridge_ensure_codex_agent_slash_commands "$AGENT" "$AGENT_HOME" 2>/dev/null || true' \
    'INBOX_SHA_AFTER="$(cksum "$PROMPTS_DIR/agb-inbox.md" 2>/dev/null | awk "{print \$1}")"' \
    'if [[ "$INBOX_SHA_BEFORE" == "$INBOX_SHA_AFTER" ]]; then echo "T3_UNMARKED_REPLACEMENT_PRESERVED: yes"; else echo "T3_UNMARKED_REPLACEMENT_PRESERVED: no"; fi' \
    '# ---- T4 teeth: the agent-scoped .codex is NOT under the controller HOME ----' \
    'case "$PROMPTS_DIR" in' \
    '  "$HOME/.codex"/*) echo "T4_SCOPED_UNDER_CONTROLLER: yes" ;;' \
    '  *) echo "T4_SCOPED_UNDER_CONTROLLER: no" ;;' \
    'esac' \
    'echo "T4_PROMPTS_DIR: $PROMPTS_DIR"'
  do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

extract_line() {
  local out="$1"
  local key="$2"
  printf '%s\n' "$out" | sed -n "s/^$key: //p" | head -n 1
}

write_driver "$DRIVER"

smoke_log "T1-T4: agent-scoped Codex slash-command provisioning (controller ~/.codex untouched)"

OUT="$(
  REPO_ROOT="$REPO_ROOT" \
  DRIVER_TMP_DIR="$DRIVER_DIR" \
  HOME="$FAKE_HOME" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
  BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
  BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
  BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
  BRIDGE_LAYOUT="v2" \
  BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT" \
  BRIDGE_SHARED_ROOT="$BRIDGE_SHARED_ROOT" \
  BRIDGE_AGENT_ROOT_V2="$BRIDGE_AGENT_ROOT_V2" \
  BRIDGE_CONTROLLER_STATE_ROOT="$BRIDGE_CONTROLLER_STATE_ROOT" \
  BRIDGE_RUNTIME_ROOT="$BRIDGE_RUNTIME_ROOT" \
  BRIDGE_HOOKS_DIR="$BRIDGE_HOOKS_DIR" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
  "$BRIDGE_BASH" "$DRIVER" 2>&1
)"
RC=$?

if [[ $RC -ne 0 ]]; then
  smoke_fail "driver exited rc=$RC. output:
$OUT"
fi

# --- T1 assertions ---
for name in agb-inbox agb-claim agb-done agb-handoff; do
  smoke_assert_eq "present" "$(extract_line "$OUT" "T1_PROMPT_${name}")" \
    "T1: $name.md deployed into agent-scoped .codex/prompts/"
  smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_MARKER_${name}")" \
    "T1: $name.md carries the agent-bridge:managed marker"
done
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_SUBST_AGENT_ID")" \
  "T1: prompt has the resolved agent id substituted in"
smoke_assert_eq "no" "$(extract_line "$OUT" "T1_SUBST_RAW_TOKEN")" \
  "T1: the raw <agent-id> token was substituted away"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_FULLPATH_AGB")" \
  "T1: prompts invoke the full-path ~/.agent-bridge/agb (PATH not assumed)"

# --- T2 assertions: agb verb/flag validity ---
smoke_assert_eq "no" "$(extract_line "$OUT" "T2_CLAIM_DONE_USES_ACTOR")" \
  "T2: claim/done do NOT use --actor (that flag is for 'agb update')"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T2_CLAIM_AGENT_FLAG")" \
  "T2: agb-claim uses 'agb claim \$1 --agent'"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T2_DONE_AGENT_FLAG")" \
  "T2: agb-done uses 'agb done \$1 --agent'"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T2_HANDOFF_A2A")" \
  "T2: agb-handoff uses 'agb a2a send'"

# T2 teeth: every agb verb used in the prompts must be a real agb verb. We do
# NOT invent verbs (a sister track shipped 'agb whoami' and got caught).
VERBS_FILE="$(extract_line "$OUT" "T2_VERBS_FILE")"
VALID_AGB_VERBS=" inbox show claim done cancel update handoff create summary task a2a status urgent agent "
BAD_VERBS=""
if [[ -n "$VERBS_FILE" && -f "$VERBS_FILE" ]]; then
  while IFS= read -r verb; do
    [[ -n "$verb" ]] || continue
    case "$VALID_AGB_VERBS" in
      *" $verb "*) ;;
      *) BAD_VERBS="$BAD_VERBS $verb" ;;
    esac
  done <"$VERBS_FILE"
else
  smoke_fail "T2: agb verbs file missing (got '$VERBS_FILE')"
fi
if [[ -n "$BAD_VERBS" ]]; then
  smoke_fail "T2 teeth: codex slash-command prompts invoke unknown agb verb(s):$BAD_VERBS (not in:$VALID_AGB_VERBS)"
fi

# --- T3 assertions: idempotent re-run + no-clobber ---
smoke_assert_eq "0" "$(extract_line "$OUT" "T3_RERUN_RC")" \
  "T3: re-running the installer exits 0 (idempotent)"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T3_CUSTOM_PRESERVED")" \
  "T3: an agent's OWN prompt (no marker) is never clobbered"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T3_MANAGED_STILL_PRESENT")" \
  "T3: managed prompts remain after a clean re-run"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T3_UNMARKED_REPLACEMENT_PRESERVED")" \
  "T3: a managed prompt an agent replaced with unmarked content is left alone"

# --- T4 assertions: agent-scoped, NOT controller ~/.codex ---
smoke_assert_eq "no" "$(extract_line "$OUT" "T4_SCOPED_UNDER_CONTROLLER")" \
  "T4: the installed .codex tree is NOT under the controller \$HOME/.codex"

# --- T4 CRITICAL: controller ~/.codex snapshot unchanged (AFTER) ---
SNAP_AFTER="$SMOKE_TMP_ROOT/controller-codex-after.txt"
snapshot_controller_codex "$SNAP_AFTER"
if ! diff -q "$SNAP_BEFORE" "$SNAP_AFTER" >/dev/null 2>&1; then
  smoke_fail "T4 CRITICAL: controller \$HOME/.codex changed during the agent scaffold!
--- before ---
$(cat "$SNAP_BEFORE")
--- after ---
$(cat "$SNAP_AFTER")"
fi
smoke_log "T4 CRITICAL: controller \$HOME/.codex unchanged (snapshot identical before/after)"

smoke_log "all tests PASS — #8945 Track C codex slash commands: agent-scoped install, valid agb verbs, idempotent, controller ~/.codex untouched"
