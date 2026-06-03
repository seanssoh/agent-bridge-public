#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1067-codex-provisioning.sh — Issue #1067 CODEX-PROV smoke.
#
# Pins the end-to-end Codex static agent provisioning contract:
#
#   T1: bridge_scaffold_codex_entrypoint produces AGENTS.md in agent_home
#       from a CLAUDE.md-bearing identity source (S03).
#   T2: bridge_ensure_codex_agent_hooks renders .codex/hooks.json at the
#       descriptor-owned per-agent path with the required hook events (S08).
#   T3: bridge_upgrade_propagate_codex_hooks (lib/upgrade-helpers/codex-hooks-
#       propagate.sh) re-renders Codex hooks on upgrade for an existing codex
#       agent whose hooks.json is absent or stale (upgrade path S08).
#   T4: a static Claude agent is unaffected — no AGENTS.md, no .codex dir
#       written by CODEX-PROV helpers.
#
# Footgun #11: driver emitted via printf-to-file, no heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1067-codex-provisioning"
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
    'declare -F bridge_scaffold_codex_entrypoint >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_scaffold_codex_entrypoint not loaded"; exit 91; }' \
    'declare -F bridge_ensure_codex_agent_hooks >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_ensure_codex_agent_hooks not loaded"; exit 92; }' \
    'declare -A BRIDGE_AGENT_WORKDIR 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_ISOLATION_MODE 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_OS_USER 2>/dev/null || true' \
    'declare -A BRIDGE_AGENT_SOURCE 2>/dev/null || true' \
    'CODEX_AGENT="probe-codex"' \
    'CLAUDE_AGENT="probe-claude"' \
    'CODEX_HOME="$BRIDGE_AGENT_ROOT_V2/$CODEX_AGENT/home"' \
    'CLAUDE_HOME="$BRIDGE_AGENT_ROOT_V2/$CLAUDE_AGENT/home"' \
    'mkdir -p "$CODEX_HOME" "$CLAUDE_HOME"' \
    '# ---- T1: S03 + #8945 Track A — AGENTS.md scaffolded for codex from the' \
    '#       dedicated codex template (explicit Task Processing Protocol),' \
    '#       not for claude ----' \
    '# Codex identity source: place CLAUDE.md (as scaffold does), then call entrypoint helper.' \
    'printf "%s\n" "# codex role contract" > "$CODEX_HOME/CLAUDE.md"' \
    'bridge_scaffold_codex_entrypoint "$CODEX_HOME" codex 2>/dev/null || true' \
    'if [[ -f "$CODEX_HOME/AGENTS.md" ]]; then echo "T1_CODEX_AGENTS_MD: present"; else echo "T1_CODEX_AGENTS_MD: missing"; fi' \
    '# #8945 Track A: AGENTS.md now comes from agents/_template/codex/AGENTS.md,' \
    '# so it must carry the explicit Task Processing Protocol marker (the Claude' \
    '# CLAUDE.md leaves the protocol implicit — the exact wedge this closes).' \
    'if [[ -f "$CODEX_HOME/AGENTS.md" ]] && grep -qF "Task Processing Protocol" "$CODEX_HOME/AGENTS.md" 2>/dev/null; then echo "T1_AGENTS_MD_HAS_PROTOCOL: yes"; else echo "T1_AGENTS_MD_HAS_PROTOCOL: no"; fi' \
    'if [[ -f "$CODEX_HOME/AGENTS.md" ]] && grep -qF "agb done" "$CODEX_HOME/AGENTS.md" 2>/dev/null; then echo "T1_AGENTS_MD_HAS_DONE: yes"; else echo "T1_AGENTS_MD_HAS_DONE: no"; fi' \
    '# #8945 Track A: from the codex template, AGENTS.md is the protocol doc,' \
    '# NOT a byte copy of the role-stub CLAUDE.md.' \
    'if [[ -f "$CODEX_HOME/AGENTS.md" ]] && ! diff -q "$CODEX_HOME/CLAUDE.md" "$CODEX_HOME/AGENTS.md" >/dev/null 2>&1; then echo "T1_AGENTS_MD_FROM_TEMPLATE: yes"; else echo "T1_AGENTS_MD_FROM_TEMPLATE: no"; fi' \
    '# T1 teeth-check: with the codex template hidden (BRIDGE_SCRIPT_DIR pointed' \
    '# at a templateless tree), the helper falls back to the CLAUDE.md -> AGENTS.md' \
    '# copy (pre-#8945 behavior preserved on older source trees).' \
    'FALLBACK_HOME="$BRIDGE_AGENT_ROOT_V2/fallback-codex/home"' \
    'mkdir -p "$FALLBACK_HOME"' \
    'printf "%s\n" "# fallback codex role contract" > "$FALLBACK_HOME/CLAUDE.md"' \
    'NO_TEMPLATE_ROOT="$DRIVER_TMP_DIR/no-template-root"' \
    'mkdir -p "$NO_TEMPLATE_ROOT"' \
    '( BRIDGE_SCRIPT_DIR="$NO_TEMPLATE_ROOT"; bridge_scaffold_codex_entrypoint "$FALLBACK_HOME" codex 2>/dev/null || true )' \
    'if [[ -f "$FALLBACK_HOME/AGENTS.md" ]] && diff -q "$FALLBACK_HOME/CLAUDE.md" "$FALLBACK_HOME/AGENTS.md" >/dev/null 2>&1; then echo "T1_FALLBACK_COPY: yes"; else echo "T1_FALLBACK_COPY: no"; fi' \
    '# Claude identity source: place CLAUDE.md but do NOT call entrypoint helper (no-op for claude).' \
    'printf "%s\n" "# claude role contract" > "$CLAUDE_HOME/CLAUDE.md"' \
    'bridge_scaffold_codex_entrypoint "$CLAUDE_HOME" claude 2>/dev/null || true' \
    'if [[ -f "$CLAUDE_HOME/AGENTS.md" ]]; then echo "T1_CLAUDE_AGENTS_MD: present"; else echo "T1_CLAUDE_AGENTS_MD: missing"; fi' \
    '# ---- T2: S08 — Codex hooks rendered at descriptor-owned path ----' \
    'CODEX_HOOK_PATH="$(bridge_engine_hook_config_path "$CODEX_AGENT" codex 2>/dev/null || printf UNRESOLVED)"' \
    'echo "T2_HOOK_PATH: $CODEX_HOOK_PATH"' \
    'bridge_ensure_codex_agent_hooks "$CODEX_AGENT" "$CODEX_HOME" 2>/dev/null || true' \
    'if [[ -f "$CODEX_HOOK_PATH" ]]; then echo "T2_HOOKS_FILE: present"; else echo "T2_HOOKS_FILE: missing"; fi' \
    'if [[ -f "$CODEX_HOOK_PATH" ]] && grep -q "SessionStart" "$CODEX_HOOK_PATH" 2>/dev/null; then echo "T2_SESSION_START: present"; else echo "T2_SESSION_START: missing"; fi' \
    'if [[ -f "$CODEX_HOOK_PATH" ]] && grep -q "Stop" "$CODEX_HOOK_PATH" 2>/dev/null; then echo "T2_STOP: present"; else echo "T2_STOP: missing"; fi' \
    'if [[ -f "$CODEX_HOOK_PATH" ]] && grep -q "UserPromptSubmit" "$CODEX_HOOK_PATH" 2>/dev/null; then echo "T2_USER_PROMPT_SUBMIT: present"; else echo "T2_USER_PROMPT_SUBMIT: missing"; fi' \
    '# Idempotence: calling again must not error.' \
    'bridge_ensure_codex_agent_hooks "$CODEX_AGENT" "$CODEX_HOME" 2>/dev/null || true' \
    'if [[ -f "$CODEX_HOOK_PATH" ]]; then echo "T2_HOOKS_IDEMPOTENT: ok"; else echo "T2_HOOKS_IDEMPOTENT: fail"; fi' \
    '# ---- T3: Claude agent must NOT get .codex hooks (engine guard) ----' \
    'CLAUDE_HOOK_PATH="$(bridge_engine_hook_config_path "$CLAUDE_AGENT" codex 2>/dev/null || printf UNRESOLVED)"' \
    '# bridge_ensure_codex_agent_hooks is called by the create flow ONLY when engine==codex' \
    '# (see bridge-agent.sh). T3 verifies the descriptors resolve to separate paths.' \
    'if [[ "$CLAUDE_HOOK_PATH" == *"$CLAUDE_HOME"* ]]; then echo "T3_CLAUDE_HOOK_PATH_SCOPED: yes"; else echo "T3_CLAUDE_HOOK_PATH_SCOPED: no"; fi'
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

smoke_log "T1: S03 — bridge_scaffold_codex_entrypoint places AGENTS.md in codex identity source, not in claude"

OUT="$(
  REPO_ROOT="$REPO_ROOT" \
  DRIVER_TMP_DIR="$DRIVER_DIR" \
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

# T1: S03 + #8945 Track A assertions.
smoke_assert_eq "present" "$(extract_line "$OUT" "T1_CODEX_AGENTS_MD")" \
  "T1: AGENTS.md present in codex identity source after bridge_scaffold_codex_entrypoint"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_AGENTS_MD_HAS_PROTOCOL")" \
  "T1 (#8945 A): AGENTS.md carries the explicit Task Processing Protocol marker (from codex template)"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_AGENTS_MD_HAS_DONE")" \
  "T1 (#8945 A): AGENTS.md encodes the 'agb done' close step"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_AGENTS_MD_FROM_TEMPLATE")" \
  "T1 (#8945 A): AGENTS.md is the protocol doc, not a byte copy of the role-stub CLAUDE.md"
smoke_assert_eq "yes" "$(extract_line "$OUT" "T1_FALLBACK_COPY")" \
  "T1 teeth (#8945 A): codex template absent => helper falls back to CLAUDE.md -> AGENTS.md copy"
smoke_assert_eq "missing" "$(extract_line "$OUT" "T1_CLAUDE_AGENTS_MD")" \
  "T1: AGENTS.md NOT written for claude agent (no-op for claude engine)"

smoke_log "T2: S08 — bridge_ensure_codex_agent_hooks renders .codex/hooks.json at descriptor path"

# T2: S08 assertions.
HOOK_PATH="$(extract_line "$OUT" "T2_HOOK_PATH")"
if [[ -z "$HOOK_PATH" || "$HOOK_PATH" == "UNRESOLVED" ]]; then
  smoke_fail "T2: hook path must resolve via descriptor; got '$HOOK_PATH'"
fi
smoke_assert_eq "present" "$(extract_line "$OUT" "T2_HOOKS_FILE")" \
  "T2: .codex/hooks.json rendered at descriptor-owned per-agent path"
smoke_assert_eq "present" "$(extract_line "$OUT" "T2_SESSION_START")" \
  "T2: hooks.json contains SessionStart hook entry"
smoke_assert_eq "present" "$(extract_line "$OUT" "T2_STOP")" \
  "T2: hooks.json contains Stop hook entry"
smoke_assert_eq "present" "$(extract_line "$OUT" "T2_USER_PROMPT_SUBMIT")" \
  "T2: hooks.json contains UserPromptSubmit hook entry"
smoke_assert_eq "ok" "$(extract_line "$OUT" "T2_HOOKS_IDEMPOTENT")" \
  "T2: ensure-codex-hooks is idempotent (safe to call on upgrade)"

smoke_log "T3: upgrade propagation — codex-hooks-propagate.sh helper invokes hooks render for codex agents"

# T3: upgrade propagation via lib/upgrade-helpers/codex-hooks-propagate.sh.
# Pre-condition: seed a minimal codex agent roster + identity home without
# hooks.json (simulates pre-#1067 state).
UPGRADE_CODEX_AGENT="upg-probe-codex"
UPGRADE_CODEX_HOME="$BRIDGE_AGENT_ROOT_V2/$UPGRADE_CODEX_AGENT/home"
mkdir -p "$UPGRADE_CODEX_HOME"
printf '%s\n' "# upg-probe-codex role" >"$UPGRADE_CODEX_HOME/CLAUDE.md"

# Seed a minimal roster entry for the upgrade codex agent.
{
  printf 'BRIDGE_AGENT_IDS+=(%s)\n' "$UPGRADE_CODEX_AGENT"
  printf 'BRIDGE_AGENT_ENGINE[%s]=%s\n' "$UPGRADE_CODEX_AGENT" "codex"
  printf 'BRIDGE_AGENT_SOURCE[%s]=%s\n' "$UPGRADE_CODEX_AGENT" "static"
  printf 'BRIDGE_AGENT_WORKDIR[%s]=%s\n' "$UPGRADE_CODEX_AGENT" "$UPGRADE_CODEX_HOME"
} >>"$BRIDGE_ROSTER_LOCAL_FILE"

HELPER="$REPO_ROOT/lib/upgrade-helpers/codex-hooks-propagate.sh"
if [[ ! -f "$HELPER" ]]; then
  smoke_fail "T3: lib/upgrade-helpers/codex-hooks-propagate.sh not found — did CODEX-PROV ship it?"
fi

UPGRADE_HOOK_PATH="$UPGRADE_CODEX_HOME/.codex/hooks.json"
if [[ -f "$UPGRADE_HOOK_PATH" ]]; then
  smoke_fail "T3 pre-condition: hooks.json must not exist before propagation (got: $UPGRADE_HOOK_PATH)"
fi

# All BRIDGE_* vars are already exported by smoke_setup_bridge_home; the
# helper inherits them directly via the subprocess environment without
# inline reassignment (which shellcheck SC2097/SC2098 flags as seen-only-
# by-forked-process style noise when they match the already-exported names).
set +e
PROPAGATE_OUT="$("$BRIDGE_BASH" "$HELPER" "$REPO_ROOT" "$BRIDGE_HOME" 2>&1)"
PROPAGATE_RC=$?
set -e

if [[ $PROPAGATE_RC -ne 0 ]]; then
  smoke_fail "T3: codex-hooks-propagate.sh exited rc=$PROPAGATE_RC. output:
$PROPAGATE_OUT"
fi

if [[ ! -f "$UPGRADE_HOOK_PATH" ]]; then
  smoke_fail "T3: codex-hooks-propagate.sh did not create hooks.json at $UPGRADE_HOOK_PATH. propagate output:
$PROPAGATE_OUT"
fi
if ! grep -q "SessionStart" "$UPGRADE_HOOK_PATH" 2>/dev/null; then
  smoke_fail "T3: hooks.json created by propagate helper is missing SessionStart entry"
fi

smoke_log "T3_UPGRADE_PROPAGATE: hooks.json created at $UPGRADE_HOOK_PATH"

# ---- T4 (#8945 Track A): every agb verb/flag in the codex AGENTS.md template
#      must match the real CLI contract ----
#
# The codex AGENTS.md template is the literal command source a Codex agent
# copy-pastes. A non-existent verb (e.g. the removed `agb whoami`) or a
# wrong-per-verb flag (e.g. `agb update --agent` — update takes `--actor`,
# while claim/done take `--agent`) makes the agent's recovery commands fail at
# runtime. This block pins the contract against the SAME template the scaffold
# ships, so a future edit that re-introduces an unsupported verb or the wrong
# flag fails CI at PR time. The contract is hardcoded (hermetic — CI has no
# live `agb`), validated against `agb <verb> --help` while authoring #8945
# Track A r2.
CODEX_TEMPLATE="$REPO_ROOT/agents/_template/codex/AGENTS.md"
smoke_assert_file_exists "$CODEX_TEMPLATE" "T4: codex AGENTS.md template must exist"

# T4a: the removed verb `agb whoami` must never reappear (it does not exist;
# `agb whoami` → `[오류] 지원하지 않는 명령입니다: whoami`). The id source is
# the $BRIDGE_AGENT_ID env var, not a lookup verb.
if grep -nE '\bagb[[:space:]]+whoami\b' "$CODEX_TEMPLATE" >/dev/null 2>&1; then
  smoke_fail "T4a (#8945 A): codex AGENTS.md references the non-existent 'agb whoami' verb — use \$BRIDGE_AGENT_ID instead"
fi

# T4b: `agb update` takes `--actor`, NOT `--agent`. Flag a same-line pairing of
# an `agb update ...` invocation with `--agent` (the exact codex-flagged bug).
if grep -nE '\bagb[[:space:]]+update\b[^`]*--agent\b' "$CODEX_TEMPLATE" >/dev/null 2>&1; then
  smoke_fail "T4b (#8945 A): codex AGENTS.md uses 'agb update ... --agent' — update takes --actor (claim/done take --agent)"
fi

# T4c: every agb verb invoked in the template must be a real agb verb. The
# allowlist is the documented queue + task surface a worker legitimately uses.
# An unknown verb (typo or a renamed CLI) fails here. `agb task <sub>` is
# validated as the `task` verb (the sub-verb is task's own arg).
T4_VALID_AGB_VERBS=" inbox show claim done update task handoff summary create cancel "
# shellcheck disable=SC2013
# Extract `agb <verb>` pairs from fenced/inline command spans. We scan the raw
# file; the "Note:" prose line that names verbs descriptively (agb claim / agb
# done / agb update) is covered too — those are all valid verbs, so it passes.
T4_BAD_VERBS=""
while IFS= read -r verb; do
  [[ -n "$verb" ]] || continue
  case "$T4_VALID_AGB_VERBS" in
    *" $verb "*) ;;
    *) T4_BAD_VERBS="$T4_BAD_VERBS $verb" ;;
  esac
done < <(grep -oE '\bagb[[:space:]]+[a-z][a-z-]*' "$CODEX_TEMPLATE" | awk '{print $2}' | sort -u)
if [[ -n "$T4_BAD_VERBS" ]]; then
  smoke_fail "T4c (#8945 A): codex AGENTS.md invokes unknown agb verb(s):$T4_BAD_VERBS (not in: $T4_VALID_AGB_VERBS)"
fi

smoke_log "T4_AGB_CONTRACT: all agb verbs/flags in codex AGENTS.md match the CLI contract"

smoke_log "all tests PASS — issue #1067 CODEX-PROV: S02/S03/S08 full provisioning + upgrade propagation + #8945 A agb-contract"
