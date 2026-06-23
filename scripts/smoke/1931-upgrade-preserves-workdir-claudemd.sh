#!/usr/bin/env bash
# Issue #1931 (DATA-LOSS): the upgrade-time migrate-agents rematerialize pass must
# never overwrite an operator-customized workdir CLAUDE.md / AGENTS.md with the
# placeholder template. The reproduction: an admin agent whose WORKDIR copy was
# customized (`# patch — Manager/admin role` + custom role/queue/rules) while the
# HOME/identity-source copy stayed the unrendered placeholder (`# <Agent Name> —
# <Role>`). The differ-then-copy gate silently clobbered the live operating
# contract with the placeholder.
#
# This smoke drives `bridge-upgrade.py migrate-agents` against an isolated
# BRIDGE_HOME and asserts:
#   1. REPRO: placeholder home + customized workdir -> workdir PRESERVED (custom
#      heading + custom sections survive) AND the managed DOC-MIGRATION block is
#      refreshed (the upgrade's new doc line still lands). Never the placeholder.
#   2. NO REGRESSION (refresh): a real authored home that differs from a stale
#      workdir still rematerializes home->workdir (the legitimate #1417 refresh).
#   3. NO REGRESSION (fresh): a placeholder home with NO workdir copy still gets
#      the normal create-if-absent scaffold (the fresh-agent path).
#   4. MUTATION: with the preserve guard neutralized, case 1 clobbers — proving
#      the assertions are non-vacuous.

set -euo pipefail

SMOKE_NAME="1931-upgrade-preserves-workdir-claudemd"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PLACEHOLDER_HEADING="# <Agent Name> — <Role>"
MANAGED_START="<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_END="<!-- END AGENT BRIDGE DOC MIGRATION -->"
# Issue #1816: the refreshed BEGIN marker now carries a ` v=<version>` stamp
# (`<!-- BEGIN AGENT BRIDGE DOC MIGRATION v=0.16.16-rc3 -->`). Post-refresh
# assertions match the stable PREFIX so they accept the stamped marker the
# renderer emits while the seed fixtures keep using the legacy unstamped
# MANAGED_START to prove the splice rewrites a stale block.
MANAGED_START_PREFIX="<!-- BEGIN AGENT BRIDGE DOC MIGRATION"

setup_bridge_fixture() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME"
  export BRIDGE_AGENT_ROOT_V2="$BRIDGE_HOME/agents"
  {
    printf '%s\n' 'BRIDGE_LAYOUT=v2'
    printf 'BRIDGE_DATA_ROOT=%q\n' "$BRIDGE_DATA_ROOT"
  } >"$BRIDGE_STATE_DIR/layout-marker.sh"
  mkdir -p "$BRIDGE_AGENT_ROOT_V2"
}

write_roster() {
  local agent=""
  {
    printf 'BRIDGE_AGENT_IDS=('
    for agent in "$@"; do
      printf '"%s" ' "$agent"
    done
    printf ')\n'
    for agent in "$@"; do
      printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
      printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
      printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$agent" "$agent"
      printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
      printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
    done
  } >"$BRIDGE_ROSTER_FILE"
}

# Roster for a single CODEX agent (entrypoint = AGENTS.md, + CLAUDE.md compat).
write_roster_codex() {
  local agent="$1"
  {
    printf 'BRIDGE_AGENT_IDS=("%s")\n' "$agent"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$agent"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="codex"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]="%s"\n' "$agent" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  } >"$BRIDGE_ROSTER_FILE"
}

# Seed a v2 home identity-source tree carrying the UNRENDERED placeholder
# entrypoint (the operator never edited home), plus the required identity docs.
seed_placeholder_home() {
  local agent="$1"
  local home="$BRIDGE_AGENT_HOME_ROOT/$agent"
  mkdir -p "$home" "$BRIDGE_AGENT_ROOT_V2/$agent/home"
  {
    printf '%s\n\n' "$PLACEHOLDER_HEADING"
    printf '%s\n' "$MANAGED_START"
    printf 'managed canon line v2 (#1900 background subagent delegation)\n'
    printf '%s\n\n' "$MANAGED_END"
    printf '너는 **<Agent Name>**야. <한 줄 역할 설명>.\n'
  } >"$home/CLAUDE.md"
  printf '# <Agent Name> Soul\n\n너는 **<Agent Name>**다.\n' >"$home/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$home/SESSION-TYPE.md"
  printf 'memory\n' >"$home/MEMORY.md"
  printf 'schema\n' >"$home/MEMORY-SCHEMA.md"
  printf 'heartbeat\n' >"$home/HEARTBEAT.md"
  printf 'change\n' >"$home/CHANGE-POLICY.md"
  printf 'tools\n' >"$home/TOOLS.md"
}

# Seed an operator-CUSTOMIZED workdir entrypoint carrying a stale managed block.
seed_customized_workdir() {
  local agent="$1"
  local workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
  mkdir -p "$workdir"
  {
    printf '# %s — Manager/admin role\n\n' "$agent"
    printf '%s\n' "$MANAGED_START"
    printf 'managed canon line v1 (stale)\n'
    printf '%s\n\n' "$MANAGED_END"
    printf '## 핵심 정보\n- 이름: %s\n- 역할: admin\n\n' "$agent"
    printf '## 규칙\n- 큐를 source of truth로 삼는다.\n'
  } >"$workdir/CLAUDE.md"
  # Identity docs present so the rematerialize loop has a complete fixture.
  printf '# %s Soul\n' "$agent" >"$workdir/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$workdir/SESSION-TYPE.md"
  printf 'memory\n' >"$workdir/MEMORY.md"
}

run_migrate() {
  python3 "$REPO_ROOT/bridge-upgrade.py" migrate-agents \
    --source-root "$REPO_ROOT" \
    --target-root "$BRIDGE_HOME" \
    --admin-agent owner
}

# --- Case 1: #1931 reproduction -------------------------------------------------
test_customized_workdir_preserved() {
  setup_bridge_fixture
  write_roster patch
  seed_placeholder_home patch
  seed_customized_workdir patch
  local workdir_claude="$BRIDGE_AGENT_ROOT_V2/patch/workdir/CLAUDE.md"

  run_migrate >/dev/null

  local body
  body="$(cat "$workdir_claude")"
  smoke_assert_contains "$(head -n 1 "$workdir_claude")" "# patch — Manager/admin role" \
    "repro: operator-customized workdir heading was clobbered with the placeholder"
  smoke_assert_not_contains "$body" "$PLACEHOLDER_HEADING" \
    "repro: workdir CLAUDE.md now carries the placeholder heading (DATA LOSS)"
  smoke_assert_contains "$body" "## 핵심 정보" \
    "repro: operator custom section dropped from workdir CLAUDE.md"
  smoke_assert_contains "$body" "## 규칙" \
    "repro: operator rules section dropped from workdir CLAUDE.md"
  # The managed DOC-MIGRATION block IS refreshed from the current shipped
  # template (so the upgrade's new doc-migration line — e.g. the #1900
  # "Background Subagent Delegation" canon — still lands) even though the
  # operator's custom contract above/below it is preserved.
  smoke_assert_contains "$body" "Agent Bridge Runtime Canon" \
    "repro: managed DOC-MIGRATION block was not refreshed from the shipped template"
  smoke_assert_contains "$body" "Background Subagent Delegation" \
    "repro: the upgrade's new doc-migration line did not land in the workdir CLAUDE.md"
  smoke_assert_not_contains "$body" "managed canon line v1" \
    "repro: stale managed block survived (should be spliced out)"
  # The managed block lives between the markers; both must be present exactly once.
  # #1816: the refreshed BEGIN marker is stamped, so assert on the stable prefix.
  smoke_assert_contains "$body" "$MANAGED_START_PREFIX" \
    "repro: managed block start marker missing after preserve+refresh"
  smoke_assert_contains "$body" "$MANAGED_END" \
    "repro: managed block end marker missing after preserve+refresh"
}

# --- Case 2: legitimate home->workdir refresh still works ------------------------
test_real_home_still_rematerializes() {
  setup_bridge_fixture
  write_roster owner
  # Real AUTHORED home (no placeholders) that differs from a stale workdir.
  local home="$BRIDGE_AGENT_HOME_ROOT/owner"
  mkdir -p "$home" "$BRIDGE_AGENT_ROOT_V2/owner/home"
  {
    printf '# owner — Real Authored Role\n\n'
    printf '%s\n' "$MANAGED_START"
    printf 'managed canon line v2\n'
    printf '%s\n\n' "$MANAGED_END"
    printf 'AUTHORED HOME CONTRACT — refreshed identity\n'
  } >"$home/CLAUDE.md"
  printf '# owner Soul\n' >"$home/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$home/SESSION-TYPE.md"
  printf 'memory\n' >"$home/MEMORY.md"

  local workdir="$BRIDGE_AGENT_ROOT_V2/owner/workdir"
  mkdir -p "$workdir"
  printf '# owner — Real Authored Role\n\nSTALE WORKDIR COPY\n' >"$workdir/CLAUDE.md"
  printf '# owner Soul\n' >"$workdir/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$workdir/SESSION-TYPE.md"
  printf 'memory\n' >"$workdir/MEMORY.md"

  run_migrate >/dev/null

  local body
  body="$(cat "$workdir/CLAUDE.md")"
  smoke_assert_contains "$body" "AUTHORED HOME CONTRACT" \
    "no-regression: real authored home was not propagated to the stale workdir"
  smoke_assert_not_contains "$body" "STALE WORKDIR COPY" \
    "no-regression: stale workdir content survived a legitimate refresh"
}

# --- Case 3: fresh workdir (no entrypoint) still gets create-if-absent -----------
test_fresh_workdir_scaffolds() {
  setup_bridge_fixture
  write_roster fresh
  seed_placeholder_home fresh
  local workdir="$BRIDGE_AGENT_ROOT_V2/fresh/workdir"
  mkdir -p "$workdir"
  # No CLAUDE.md in the workdir yet.
  printf '# fresh Soul\n' >"$workdir/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-claude\n- Engine: claude\n' >"$workdir/SESSION-TYPE.md"
  printf 'memory\n' >"$workdir/MEMORY.md"

  run_migrate >/dev/null

  smoke_assert_file_exists "$workdir/CLAUDE.md" \
    "fresh: create-if-absent did not seed the workdir CLAUDE.md"
  # The placeholder scaffold is the legitimate initial copy here (no operator
  # content existed to protect).
  smoke_assert_contains "$(cat "$workdir/CLAUDE.md")" "$PLACEHOLDER_HEADING" \
    "fresh: workdir CLAUDE.md was not seeded from the home scaffold"
}

# --- Case 4: mutation test (guard removed -> clobber reappears) ------------------
test_mutation_guard_removed_clobbers() {
  setup_bridge_fixture
  write_roster patch
  seed_placeholder_home patch
  seed_customized_workdir patch
  local workdir_claude="$BRIDGE_AGENT_ROOT_V2/patch/workdir/CLAUDE.md"

  # Build a mutated copy of the helper with the entrypoint-preserve guard
  # neutralized (force _remat_preserve_customized_entrypoint to always decline),
  # so the copy gate clobbers exactly as it did before the fix.
  local mut_root="$SMOKE_TMP_ROOT/mutant"
  cp -R "$REPO_ROOT" "$mut_root"
  local mut_helper="$mut_root/lib/upgrade-helpers/rematerialize-agent-identity.sh"
  python3 -c 'import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
marker = "_remat_preserve_customized_entrypoint() {\n"
idx = text.index(marker) + len(marker)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text[:idx] + "  return 1\n" + text[idx:])
' "$mut_helper"

  python3 "$mut_root/bridge-upgrade.py" migrate-agents \
    --source-root "$mut_root" \
    --target-root "$BRIDGE_HOME" \
    --admin-agent owner >/dev/null

  # With the guard gone, the placeholder home clobbers the customized workdir.
  if ! grep -qF "$PLACEHOLDER_HEADING" "$workdir_claude"; then
    smoke_fail "mutation: removing the preserve guard did NOT clobber — the case-1 assertions are vacuous"
  fi
}

# --- Case 5: codex engine — operator-customized workdir AGENTS.md preserved -----
test_codex_agents_md_preserved() {
  setup_bridge_fixture
  write_roster_codex pair
  local home="$BRIDGE_AGENT_HOME_ROOT/pair"
  mkdir -p "$home" "$BRIDGE_AGENT_ROOT_V2/pair/home"
  # Placeholder home AGENTS.md (codex entrypoint) + CLAUDE.md compat copy.
  local body=""
  body="$(printf '%s\n\n%s\nmanaged canon line v2 (#1900 background subagent delegation)\n%s\n\n너는 **<Agent Name>**야. <한 줄 역할 설명>.\n' \
    "$PLACEHOLDER_HEADING" "$MANAGED_START" "$MANAGED_END")"
  printf '%s\n' "$body" >"$home/AGENTS.md"
  printf '%s\n' "$body" >"$home/CLAUDE.md"
  printf '# <Agent Name> Soul\n\n너는 **<Agent Name>**다.\n' >"$home/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-codex\n- Engine: codex\n' >"$home/SESSION-TYPE.md"
  printf 'memory\n' >"$home/MEMORY.md"

  # Operator-customized workdir AGENTS.md (the codex contract the operator owns).
  local workdir="$BRIDGE_AGENT_ROOT_V2/pair/workdir"
  mkdir -p "$workdir"
  {
    printf '# pair — Codex Reviewer role\n\n'
    printf '%s\n' "$MANAGED_START"
    printf 'managed canon line v1 (stale)\n'
    printf '%s\n\n' "$MANAGED_END"
    printf '## 핵심 정보\n- 이름: pair\n- 역할: codex reviewer\n'
  } >"$workdir/AGENTS.md"
  printf '# pair Soul\n' >"$workdir/SOUL.md"
  printf '# Session Type\n\n- Session Type: static-codex\n- Engine: codex\n' >"$workdir/SESSION-TYPE.md"
  printf 'memory\n' >"$workdir/MEMORY.md"

  run_migrate >/dev/null

  local agents_body
  agents_body="$(cat "$workdir/AGENTS.md")"
  smoke_assert_contains "$(head -n 1 "$workdir/AGENTS.md")" "# pair — Codex Reviewer role" \
    "codex: operator-customized workdir AGENTS.md heading was clobbered with the placeholder"
  smoke_assert_not_contains "$agents_body" "$PLACEHOLDER_HEADING" \
    "codex: workdir AGENTS.md now carries the placeholder heading (DATA LOSS)"
  smoke_assert_contains "$agents_body" "## 핵심 정보" \
    "codex: operator custom section dropped from workdir AGENTS.md"
  # The managed DOC-MIGRATION block IS refreshed from the current shipped codex
  # template (the codex managed block differs from the claude one — assert on a
  # codex-template-stable marker, and that the stale block was spliced out).
  smoke_assert_contains "$agents_body" "Queue status semantics" \
    "codex: managed DOC-MIGRATION block was not refreshed from the shipped codex template"
  smoke_assert_not_contains "$agents_body" "managed canon line v1" \
    "codex: stale managed block survived (should be spliced out)"
}

# --- Case 6: fail-safe — preserve helper missing must NOT fail open to clobber ---
test_helper_missing_fails_safe() {
  setup_bridge_fixture
  write_roster patch
  seed_placeholder_home patch
  seed_customized_workdir patch
  local workdir_claude="$BRIDGE_AGENT_ROOT_V2/patch/workdir/CLAUDE.md"

  # Copy the source and REMOVE the python decision helper, simulating a partial
  # / corrupted upgrade source. The inline fail-safe must still preserve the
  # operator-customized workdir entrypoint (the bug this whole fix is about must
  # not reopen when the helper is absent).
  local src_root="$SMOKE_TMP_ROOT/no-helper-src"
  cp -R "$REPO_ROOT" "$src_root"
  rm -f "$src_root/lib/upgrade-helpers/preserve-customized-entrypoint.py"

  python3 "$src_root/bridge-upgrade.py" migrate-agents \
    --source-root "$src_root" \
    --target-root "$BRIDGE_HOME" \
    --admin-agent owner >/dev/null

  smoke_assert_contains "$(head -n 1 "$workdir_claude")" "# patch — Manager/admin role" \
    "fail-safe: helper-missing path clobbered the customized workdir entrypoint"
  smoke_assert_not_contains "$(cat "$workdir_claude")" "$PLACEHOLDER_HEADING" \
    "fail-safe: workdir CLAUDE.md got the placeholder when the helper was absent"
  smoke_assert_contains "$(cat "$workdir_claude")" "## 핵심 정보" \
    "fail-safe: operator custom section dropped when the helper was absent"
}

main() {
  smoke_require_cmd python3
  smoke_run "operator-customized workdir CLAUDE.md preserved (managed-block refreshed)" test_customized_workdir_preserved
  smoke_run "real authored home still rematerializes to stale workdir" test_real_home_still_rematerializes
  smoke_run "fresh workdir still gets create-if-absent scaffold" test_fresh_workdir_scaffolds
  smoke_run "mutation: removing the guard reintroduces the clobber" test_mutation_guard_removed_clobbers
  smoke_run "codex engine: operator-customized workdir AGENTS.md preserved" test_codex_agents_md_preserved
  smoke_run "fail-safe: preserve helper missing does not fail open to clobber" test_helper_missing_fails_safe
  smoke_log "PASS: $SMOKE_NAME"
}

main "$@"
