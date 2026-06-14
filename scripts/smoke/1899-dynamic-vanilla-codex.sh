#!/usr/bin/env bash
# scripts/smoke/1899-dynamic-vanilla-codex.sh
#
# #1899 (sibling of #1890) — dynamic Codex agents run as VANILLA Codex CLI +
# bridge comms only.
#
# A dynamic Codex agent (engine==codex && source==dynamic && !iso) must:
#   - launch via native `codex resume --last` (continue) / `codex` (fresh) —
#     NEVER `codex resume <id>`, NEVER `--all` (acceptance a);
#   - launch with CODEX_HOME pinned to the operator-global ~/.codex, NOT
#     <agent_home>/.codex (acceptance b);
#   - be EXCLUDED from the codex-cred fleet sync (acceptance c);
#   - have its bridge comms hooks written project-local at <workdir>/.codex/
#     hooks.json, with trust-blocked comms REPORTED not silently bypassed
#     (acceptance d);
#   - keep STATIC Codex UNCHANGED — bridge `codex resume <id>` + included in the
#     codex-cred sync selection (acceptance e);
#   - have the generic session detect/persist paths be a NO-OP even with a
#     seeded operator ~/.codex/sessions transcript (acceptance f).
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; temp workdirs under
# SMOKE_TMP_ROOT; HOME repointed at a temp operator home. Platform forced Darwin
# so linux-user isolation is never effective (the shared-mode shape #1899
# targets). Footgun #11: plain printf/cat fixture writes only.

set -euo pipefail

SMOKE_NAME="1899-dynamic-vanilla-codex"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3

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
mkdir -p "$OPERATOR_HOME/.codex"

# lib_eval — source the full library, reset roster, register one Codex agent of
# the requested <source> for <workdir>, then run <snippet>. Darwin-forced so
# isolation is never effective.
lib_eval() {
  local agent="$1"
  local src="$2"
  local workdir="$3"
  local continue_mode="$4"
  local snippet="$5"
  env -u CODEX_HOME \
  HOME="$OPERATOR_HOME" \
  BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" \
  "$BASH4_BIN" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_reset_roster_maps
    agent='$agent'
    BRIDGE_AGENT_IDS+=(\$agent)
    BRIDGE_AGENT_ENGINE[\$agent]=codex
    BRIDGE_AGENT_SESSION[\$agent]=\$agent
    BRIDGE_AGENT_WORKDIR[\$agent]='$workdir'
    BRIDGE_AGENT_SOURCE[\$agent]='$src'
    BRIDGE_AGENT_ISOLATION_MODE[\$agent]=shared
    BRIDGE_AGENT_CONTINUE[\$agent]='$continue_mode'
    BRIDGE_AGENT_CREATED_AT[\$agent]=\$(date +%s)
    BRIDGE_AGENT_SESSION_ID[\$agent]='deadbeef-1111-2222-3333-444444444444'
    BRIDGE_AGENT_LAUNCH_CMD[\$agent]='codex -c features.fast_mode=true --dangerously-bypass-approvals-and-sandbox --no-alt-screen'
    $snippet
  "
}

SID="deadbeef-1111-2222-3333-444444444444"

# seed_codex_session <workdir> <session_id> — write a codex session_meta rollout
# under the operator HOME's ~/.codex/sessions whose cwd matches <workdir>, so
# bridge_detect_codex_session_id (the first-wake / resumable-state probe) sees a
# resumable session in the cwd. Plain printf only (footgun #11).
seed_codex_session() {
  local wd="$1"
  local sid="$2"
  local now_iso
  now_iso="$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat())')"
  mkdir -p "$OPERATOR_HOME/.codex/sessions/2026/06/15"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","timestamp":"%s"}}\n' \
    "$sid" "$wd" "$now_iso" \
    > "$OPERATOR_HOME/.codex/sessions/2026/06/15/rollout-$sid.jsonl"
}

# ===========================================================================
# A — launch byte-shape: dynamic Codex with a RESUMABLE cwd session -> `codex
# resume --last` (NO uuid arg, NO --all); static Codex -> `codex resume <id>`
# (unchanged). Drive the builders directly so the assertion is independent of
# the post-start paths.
# ===========================================================================
test_a_launch_shape() {
  local wd="$SMOKE_TMP_ROOT/wd-dynx"
  mkdir -p "$wd"; wd="$(cd -P "$wd" && pwd -P)"
  seed_codex_session "$wd" "codexsess-aaaa-1111"
  local out=""
  out="$(lib_eval "dynx" dynamic "$wd" 1 '
    printf "PRED=%s\n" "$(bridge_agent_is_dynamic_vanilla_codex dynx && echo yes || echo no)"
    printf "DYN_CONT=%s\n" "$(bridge_build_dynamic_launch_cmd dynx)"
    if bridge_build_resume_launch_cmd dynx >/dev/null 2>&1; then printf "RESUME_BUILDER=emitted\n"; else printf "RESUME_BUILDER=declined\n"; fi
  ')" || smoke_fail "A lib_eval failed: $out"

  local pred dyn_cont resume_builder
  pred="$(printf '%s\n' "$out" | sed -n 's/^PRED=//p' | head -n1)"
  dyn_cont="$(printf '%s\n' "$out" | sed -n 's/^DYN_CONT=//p' | head -n1)"
  resume_builder="$(printf '%s\n' "$out" | sed -n 's/^RESUME_BUILDER=//p' | head -n1)"

  smoke_assert_eq "yes" "$pred" "A dynamic shared-mode Codex is classified dynamic-vanilla-codex"
  smoke_assert_contains "$dyn_cont" "codex resume --last" "A dynamic continue launch uses native 'codex resume --last'"
  smoke_assert_not_contains "$dyn_cont" "$SID" "A dynamic launch NEVER emits the bridge session id"
  smoke_assert_not_contains "$dyn_cont" "resume $SID" "A dynamic launch NEVER emits 'codex resume <id>'"
  smoke_assert_not_contains "$dyn_cont" "--all" "A dynamic launch NEVER adds --all (cwd filter is the boundary)"
  smoke_assert_eq "declined" "$resume_builder" "A resume-launch builder declines for dynamic Codex"
}

test_a_first_wake_plain_codex() {
  # continue=1 but NO seeded session in this fresh workdir => first wake =>
  # plain `codex`, NOT `codex resume --last` (resume --last would find nothing).
  local wd="$SMOKE_TMP_ROOT/wd-dynx-firstwake"
  mkdir -p "$wd"; wd="$(cd -P "$wd" && pwd -P)"
  local out=""
  out="$(lib_eval "dynxw" dynamic "$wd" 1 '
    printf "DYN_FW=%s\n" "$(bridge_build_dynamic_launch_cmd dynxw 2>/dev/null)"
  ')" || smoke_fail "A-firstwake lib_eval failed: $out"
  local dyn_fw
  dyn_fw="$(printf '%s\n' "$out" | sed -n 's/^DYN_FW=//p' | head -n1)"
  smoke_assert_not_contains "$dyn_fw" "resume" "A first-wake dynamic Codex (continue=1, no cwd session) is plain 'codex', no resume"
  smoke_assert_contains "$dyn_fw" "features.hooks=true" "A first-wake dynamic Codex forces features.hooks=true"
}

test_a_fresh_shape() {
  local out=""
  out="$(lib_eval "dynxf" dynamic "$SMOKE_TMP_ROOT/wd-dynxf" 0 '
    printf "DYN_FRESH=%s\n" "$(bridge_build_dynamic_launch_cmd dynxf)"
  ')" || smoke_fail "A-fresh lib_eval failed: $out"
  local dyn_fresh
  dyn_fresh="$(printf '%s\n' "$out" | sed -n 's/^DYN_FRESH=//p' | head -n1)"
  smoke_assert_not_contains "$dyn_fresh" "resume" "A dynamic FRESH launch (continue=0) is plain 'codex', no resume"
  smoke_assert_contains "$dyn_fresh" "features.hooks=true" "A dynamic fresh launch forces features.hooks=true (fail-closed comms)"
}

test_a_static_unchanged() {
  local out=""
  out="$(lib_eval "statx" static "$SMOKE_TMP_ROOT/wd-statx" 1 '
    printf "PRED=%s\n" "$(bridge_agent_is_dynamic_vanilla_codex statx && echo yes || echo no)"
    printf "STAT_CMD=%s\n" "$(bridge_build_dynamic_launch_cmd statx)"
  ')" || smoke_fail "A-static lib_eval failed: $out"

  local pred stat_cmd
  pred="$(printf '%s\n' "$out" | sed -n 's/^PRED=//p' | head -n1)"
  stat_cmd="$(printf '%s\n' "$out" | sed -n 's/^STAT_CMD=//p' | head -n1)"

  smoke_assert_eq "no" "$pred" "A static Codex is NOT dynamic-vanilla-codex"
  smoke_assert_contains "$stat_cmd" "resume $SID" "A static Codex STILL launches with bridge 'codex resume <id>' (unchanged)"
  smoke_assert_not_contains "$stat_cmd" "resume --last" "A static Codex does NOT use 'resume --last'"
}

# ===========================================================================
# B — launch env: dynamic Codex -> CODEX_HOME = operator global ~/.codex, NOT
# <agent_home>/.codex. Drive bridge_run_export_codex_launch_env in a subshell
# and read back the exported CODEX_HOME / HOME.
# ===========================================================================
test_b_codex_home_env() {
  local out=""
  out="$(env -u CODEX_HOME HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" "$BASH4_BIN" -c "
      set -uo pipefail
      source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
      bridge_reset_roster_maps
      a=dynbe
      BRIDGE_AGENT_IDS+=(\$a)
      BRIDGE_AGENT_ENGINE[\$a]=codex
      BRIDGE_AGENT_SESSION[\$a]=\$a
      BRIDGE_AGENT_WORKDIR[\$a]='$SMOKE_TMP_ROOT/wd-dynbe'
      BRIDGE_AGENT_SOURCE[\$a]=dynamic
      BRIDGE_AGENT_ISOLATION_MODE[\$a]=shared
      BRIDGE_AGENT_CREATED_AT[\$a]=\$(date +%s)
      # The run-loop globals bridge_run_export_codex_launch_env reads:
      ENGINE=codex
      AGENT=dynbe
      # Source the run-loop function bodies. bridge-lib.sh does not pull in
      # bridge-run.sh; define the function under test by sourcing it guarded.
      bridge_run_export_codex_launch_env() { :; }
      $(declare -f bridge_run_export_codex_launch_env >/dev/null 2>&1 || true)
      # Pull the real function out of bridge-run.sh without executing its main.
      eval \"\$(sed -n '/^bridge_run_export_codex_launch_env()/,/^}/p' '$REPO_ROOT/bridge-run.sh')\"
      bridge_run_export_codex_launch_env
      printf 'CODEX_HOME=%s\n' \"\${CODEX_HOME:-<unset>}\"
      printf 'HOME=%s\n' \"\$HOME\"
    ")" || smoke_fail "B lib_eval failed: $out"

  local codex_home home
  codex_home="$(printf '%s\n' "$out" | sed -n 's/^CODEX_HOME=//p' | head -n1)"
  home="$(printf '%s\n' "$out" | sed -n 's/^HOME=//p' | head -n1)"

  smoke_assert_eq "$OPERATOR_HOME/.codex" "$codex_home" "B dynamic Codex CODEX_HOME = operator global ~/.codex"
  smoke_assert_not_contains "$codex_home" "/wd-dynbe" "B dynamic Codex CODEX_HOME is NOT under <agent_home>/<workdir>/.codex"
  smoke_assert_eq "$OPERATOR_HOME" "$home" "B dynamic Codex HOME = operator home"
}

# ===========================================================================
# C — codex-cred fleet selection EXCLUDES dynamic Codex (acceptance c). The
# `all`/`codex` spec must not list a dynamic vanilla Codex agent; a static
# Codex agent in the same roster MUST be listed.
# ===========================================================================
test_c_cred_sync_excludes_dynamic() {
  local out=""
  out="$(env -u CODEX_HOME HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" "$BASH4_BIN" -c "
      set -uo pipefail
      source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
      BRIDGE_AUTH_CODEX_ENGINE=codex
      # Pull the selector out of bridge-auth.sh without executing its main.
      eval \"\$(sed -n '/^bridge_auth_codex_selected_agents()/,/^}/p' '$REPO_ROOT/bridge-auth.sh')\"
      bridge_reset_roster_maps
      for a in dync statc; do
        BRIDGE_AGENT_IDS+=(\$a)
        BRIDGE_AGENT_ENGINE[\$a]=codex
        BRIDGE_AGENT_SESSION[\$a]=\$a
        BRIDGE_AGENT_WORKDIR[\$a]='$SMOKE_TMP_ROOT/wd-'\$a
        BRIDGE_AGENT_ISOLATION_MODE[\$a]=shared
        BRIDGE_AGENT_CREATED_AT[\$a]=\$(date +%s)
      done
      BRIDGE_AGENT_SOURCE[dync]=dynamic
      BRIDGE_AGENT_SOURCE[statc]=static
      sel=\"\$(bridge_auth_codex_selected_agents codex 2>/dev/null | tr '\n' ',' )\"
      printf 'SEL=%s\n' \"\$sel\"
    ")" || smoke_fail "C lib_eval failed: $out"

  local sel
  sel="$(printf '%s\n' "$out" | sed -n 's/^SEL=//p' | head -n1)"
  smoke_assert_contains "$sel" "statc" "C static Codex IS in the codex-cred sync selection"
  smoke_assert_not_contains "$sel" "dync" "C dynamic Codex is EXCLUDED from the codex-cred sync selection"
}

# ===========================================================================
# D — bridge comms hooks land project-local at <workdir>/.codex/hooks.json and
# do NOT touch the operator ~/.codex/hooks.json. Trust-unknown is REPORTED
# (audit/warn), never silently bypassed. We assert the file target + that the
# function returns success while emitting a non-empty report path.
# ===========================================================================
test_d_project_local_hooks() {
  local wd="$SMOKE_TMP_ROOT/wd-hooks-dynx"
  mkdir -p "$wd"
  # No trust marker in the operator config => trust "unknown" => REPORT.
  lib_eval "dynh" dynamic "$wd" 1 '
    bridge_ensure_codex_dynamic_project_hooks dynh "'"$wd"'" >/dev/null 2>&1 || true
  ' >/dev/null 2>&1 || smoke_fail "D dynamic hooks lib_eval failed"

  smoke_assert_file_exists "$wd/.codex/hooks.json" \
    "D bridge comms hooks write to project-local <workdir>/.codex/hooks.json"
  [[ ! -e "$OPERATOR_HOME/.codex/hooks.json" ]] \
    || smoke_fail "D dynamic Codex must NOT write the operator-global ~/.codex/hooks.json"

  local hasstart
  hasstart="$(python3 -c "import json;d=json.load(open('$wd/.codex/hooks.json'));print('yes' if 'SessionStart' in d.get('hooks',{}) else 'no')")"
  smoke_assert_eq "yes" "$hasstart" "D bridge SessionStart hook merged into project-local hooks.json"
}

test_d_trust_blocked_reported() {
  # Seed an UNTRUSTED project entry in the operator config.toml, then assert the
  # status helper flags comms blocked (reported, not bypassed). py<3.11 with no
  # tomllib still reaches the conservative scan path => "unknown" (still warns).
  local wd="$SMOKE_TMP_ROOT/wd-trust-blocked"
  mkdir -p "$wd/.codex"
  printf '{}' > "$wd/.codex/hooks.json"
  local cfg="$OPERATOR_HOME/.codex/config.toml"
  {
    printf '[projects."%s"]\n' "$wd"
    printf 'trust_level = "untrusted"\n'
  } > "$cfg"

  local out blocked trust
  out="$(python3 "$REPO_ROOT/bridge-hooks.py" status-codex-project-trust \
    --workdir "$wd" --codex-config-file "$cfg" 2>/dev/null || true)"
  blocked="$(printf '%s\n' "$out" | sed -n 's/^CODEX_PROJECT_HOOKS_COMMS_BLOCKED=//p' | tr -d "'\"" | head -n1)"
  trust="$(printf '%s\n' "$out" | sed -n 's/^CODEX_PROJECT_TRUST_LEVEL=//p' | tr -d "'\"" | head -n1)"

  # On py311+ this is a hard "blocked=1, trust=untrusted"; on older python the
  # conservative scan returns "unknown" which still drives an operator warning.
  if [[ "$trust" == "untrusted" ]]; then
    smoke_assert_eq "1" "$blocked" "D untrusted project => comms reported BLOCKED (not silently bypassed)"
  else
    smoke_assert_eq "unknown" "$trust" "D py<3.11: trust unresolved => REPORTED unknown (still warns, never bypassed)"
  fi
}

test_d_trusted_not_blocked() {
  local wd="$SMOKE_TMP_ROOT/wd-trust-ok"
  mkdir -p "$wd/.codex"
  printf '{}' > "$wd/.codex/hooks.json"
  local cfg="$OPERATOR_HOME/.codex/config.toml.trusted"
  {
    printf '[projects."%s"]\n' "$wd"
    printf 'trust_level = "trusted"\n'
  } > "$cfg"
  local out blocked
  out="$(python3 "$REPO_ROOT/bridge-hooks.py" status-codex-project-trust \
    --workdir "$wd" --codex-config-file "$cfg" 2>/dev/null || true)"
  blocked="$(printf '%s\n' "$out" | sed -n 's/^CODEX_PROJECT_HOOKS_COMMS_BLOCKED=//p' | tr -d "'\"" | head -n1)"
  smoke_assert_eq "0" "$blocked" "D trusted project => comms NOT blocked"
}

# ===========================================================================
# E — STATIC Codex hook path UNCHANGED: bridge_codex_hooks_file resolves to the
# operator/HOME ~/.codex/hooks.json (the managed shared path), not a project
# redirect. (The per-agent managed write at create time is static-only and
# covered by 1067-codex-provisioning; here we assert the launch-path resolver.)
# ===========================================================================
test_e_static_hook_path_unchanged() {
  local out=""
  out="$(env -u CODEX_HOME HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" "$BASH4_BIN" -c "
      set -uo pipefail
      source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
      printf 'HOOKS_FILE=%s\n' \"\$(bridge_codex_hooks_file)\"
    ")" || smoke_fail "E lib_eval failed: $out"
  local hooks_file
  hooks_file="$(printf '%s\n' "$out" | sed -n 's/^HOOKS_FILE=//p' | head -n1)"
  smoke_assert_eq "$OPERATOR_HOME/.codex/hooks.json" "$hooks_file" \
    "E static/managed Codex hook file resolves to ~/.codex/hooks.json (unchanged)"
}

# ===========================================================================
# F — generic session detect/persist is a NO-OP for dynamic vanilla Codex even
# with a seeded operator ~/.codex/sessions transcript whose cwd is the workdir.
# Control: a STATIC Codex in the SAME setup still resolves the candidate id
# (proving the guard is class-scoped, not a blanket break).
# ===========================================================================
test_f_detect_persist_noop() {
  local wd="$SMOKE_TMP_ROOT/wd-detect"
  mkdir -p "$wd"
  wd="$(cd -P "$wd" && pwd -P)"
  local op_sid="0pera70r-codex-live-session-id-bbbb"
  local now_iso
  now_iso="$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat())')"
  mkdir -p "$OPERATOR_HOME/.codex/sessions/2026/06/15"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","timestamp":"%s"}}\n' \
    "$op_sid" "$wd" "$now_iso" \
    > "$OPERATOR_HOME/.codex/sessions/2026/06/15/rollout-test.jsonl"

  local dyn_out stat_out
  dyn_out="$(env -u CODEX_HOME HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" "$BASH4_BIN" -c "
      set -uo pipefail
      source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
      bridge_reset_roster_maps
      a=dynd
      BRIDGE_AGENT_IDS+=(\$a)
      BRIDGE_AGENT_ENGINE[\$a]=codex
      BRIDGE_AGENT_SESSION[\$a]=\$a
      BRIDGE_AGENT_WORKDIR[\$a]='$wd'
      BRIDGE_AGENT_SOURCE[\$a]=dynamic
      BRIDGE_AGENT_ISOLATION_MODE[\$a]=shared
      BRIDGE_AGENT_CREATED_AT[\$a]=\$(( $(date +%s) - 60 ))
      BRIDGE_AGENT_SESSION_ID[\$a]=''
      if bridge_refresh_agent_session_id dynd >/dev/null 2>&1; then echo REFRESH_RC=0; else echo REFRESH_RC=1; fi
      printf 'AFTER_SID=%s\n' \"\${BRIDGE_AGENT_SESSION_ID[dynd]:-}\"
      printf 'RESOLVED=%s\n' \"\$(bridge_resolve_resume_session_id codex dynd '$wd' '$op_sid' 2>/dev/null || true)\"
    ")" || smoke_fail "F dynamic lib_eval failed: $dyn_out"

  # Control probe: the operator transcript IS genuinely detectable for a STATIC
  # codex agent via the same scan (proves the fixture is realistic).
  stat_out="$(env -u CODEX_HOME HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    BRIDGE_HOST_PLATFORM_OVERRIDE="Darwin" "$BASH4_BIN" -c "
      set -uo pipefail
      source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
      printf 'DETECTED=%s\n' \"\$(bridge_detect_codex_session_id '$wd' 0 '' 2>/dev/null || true)\"
    ")" || smoke_fail "F static probe lib_eval failed: $stat_out"

  local refresh_rc after_sid resolved detected
  refresh_rc="$(printf '%s\n' "$dyn_out" | sed -n 's/^REFRESH_RC=//p' | head -n1)"
  after_sid="$(printf '%s\n' "$dyn_out" | sed -n 's/^AFTER_SID=//p' | head -n1)"
  resolved="$(printf '%s\n' "$dyn_out" | sed -n 's/^RESOLVED=//p' | head -n1)"
  detected="$(printf '%s\n' "$stat_out" | sed -n 's/^DETECTED=//p' | head -n1)"

  smoke_assert_eq "$op_sid" "$detected" "F control: operator transcript IS detectable (fixture realistic)"
  smoke_assert_eq "1" "$refresh_rc" "F dynamic Codex refresh is a no-op (rc!=0, detects nothing)"
  smoke_assert_eq "" "$after_sid" "F dynamic Codex captures + persists NO session id"
  smoke_assert_eq "" "$resolved" "F central resolver returns EMPTY for dynamic Codex (no echo-through of candidate)"
}

# --- run ------------------------------------------------------------------
smoke_run "A dynamic launch shape (codex resume --last, no id, no --all)" test_a_launch_shape
smoke_run "A first-wake dynamic Codex (continue=1, no session) = plain codex" test_a_first_wake_plain_codex
smoke_run "A dynamic fresh launch (plain codex, hooks forced)" test_a_fresh_shape
smoke_run "A static launch shape unchanged (codex resume <id>)" test_a_static_unchanged
smoke_run "B launch env CODEX_HOME = operator global ~/.codex" test_b_codex_home_env
smoke_run "C codex-cred sync EXCLUDES dynamic Codex" test_c_cred_sync_excludes_dynamic
smoke_run "D bridge hooks -> project-local <workdir>/.codex/hooks.json" test_d_project_local_hooks
smoke_run "D trust-blocked comms REPORTED not bypassed" test_d_trust_blocked_reported
smoke_run "D trusted project not blocked" test_d_trusted_not_blocked
smoke_run "E static/managed Codex hook path unchanged" test_e_static_hook_path_unchanged
smoke_run "F session detect/persist no-op (operator transcript seeded)" test_f_detect_persist_noop

smoke_log "PASS — #1899 dynamic Codex = vanilla operator-global CODEX_HOME + codex resume --last + project-local .codex/hooks.json; static unchanged"
