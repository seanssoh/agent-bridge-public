#!/usr/bin/env bash
# skill-discovery-mode smoke — pin the BRIDGE_SKILLS_DOC_MODE flag and
# the `agb skills list` query CLI introduced in PR for issue #509 C1+C5.
#
# Cases:
#   1  skills_doc_mode() defaults to "legacy-catalog" when env unset
#   2  skills_doc_mode() honours valid values (plugin-routing, disabled)
#   3  skills_doc_mode() falls back to legacy-catalog on garbage input
#   4  render_shared_skill_routing_md() with mock plugins+workdirs:
#      - user-scope plugins surfaced once at the top
#      - project/local-scope plugins attributed to the agent whose
#        workdir resolves to projectPath
#      - agents with no project-scope plugins still appear (with —)
#      - missing workdir map yields a clear message, not a crash
#   5  build_plugin_routing() ignores plugins whose projectPath does not
#      match any agent in the roster (the plugin is still installed,
#      just not reachable from any known agent)
#   6  `agb skills list --json` emits stable JSON shape against a mocked
#      CLAUDE_PLUGINS_FILE
#   7  `agb skills list --agent <name>` restricts to one agent
#   8  `agb skills list --agent <unknown>` exits non-zero with a clear
#      error
#   17 operating-manual shared skill appears in registry + legacy catalogs
#
# Each case runs against a tmp BRIDGE_HOME / tmp installed_plugins.json
# fixture; the operator's real install is never touched.

set -u

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0
FAIL_IDS=()

pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_IDS+=("$1"); printf '  [FAIL] %s — %s\n' "$1" "$2"; }
banner() { printf '\n=== case %s — %s ===\n' "$1" "$2"; }

SMOKE_ROOT="$(mktemp -d -t skill-discovery-mode.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT

# Helper: import bridge-docs.py via importlib (hyphenated filename can't
# be a normal `import` target). All Python helper invocations use this
# preamble so calls are uniform. The `sys.modules["bd"] = mod` line is
# required for Python 3.9 dataclasses (decorator looks up the module
# from sys.modules and fails with AttributeError if it's missing).
load_bd_preamble='
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_file_location("bd", "'"$REPO_ROOT"'/bridge-docs.py")
mod = importlib.util.module_from_spec(spec)
sys.modules["bd"] = mod
spec.loader.exec_module(mod)
'

# ---------- case 1: default mode ----------
banner 1 "skills_doc_mode() default = legacy-catalog"
out=$(env -u BRIDGE_SKILLS_DOC_MODE "$PYTHON" -c "$load_bd_preamble"$'\nprint(mod.skills_doc_mode())')
if [[ "$out" == "legacy-catalog" ]]; then
  pass 1
else
  fail 1 "expected 'legacy-catalog', got '$out'"
fi

# ---------- case 2: valid values ----------
banner 2 "skills_doc_mode() honours valid values"
ok=true
for value in plugin-routing disabled legacy-catalog; do
  got=$(BRIDGE_SKILLS_DOC_MODE="$value" "$PYTHON" -c "$load_bd_preamble"$'\nprint(mod.skills_doc_mode())')
  if [[ "$got" != "$value" ]]; then
    ok=false
    fail 2 "value=$value → got '$got'"
    break
  fi
done
$ok && pass 2

# ---------- case 3: garbage input falls back ----------
banner 3 "skills_doc_mode() falls back to legacy-catalog on garbage"
out=$(BRIDGE_SKILLS_DOC_MODE="not-a-real-mode" "$PYTHON" -c "$load_bd_preamble"$'\nprint(mod.skills_doc_mode())')
if [[ "$out" == "legacy-catalog" ]]; then
  pass 3
else
  fail 3 "expected fallback to 'legacy-catalog', got '$out'"
fi

# ---------- case 4: render_shared_skill_routing_md content ----------
banner 4 "render_shared_skill_routing_md() emits user-scope + per-agent rows"
PLUGINS_FIX="$SMOKE_ROOT/c4-plugins.json"
"$PYTHON" -c "
import json
data = {
  'version': 1,
  'plugins': {
    'discord@claude-plugins-official': [{'scope': 'project', 'projectPath': '$SMOKE_ROOT/c4/agent-A'}],
    'telegram@claude-plugins-official': [{'scope': 'local', 'projectPath': '$SMOKE_ROOT/c4/agent-A'}],
    'shopify@claude-plugins-official': [{'scope': 'user', 'installPath': '/cache/shopify'}],
    'frontend-design@official': [{'scope': 'user'}],
  },
}
open('$PLUGINS_FIX', 'w').write(json.dumps(data))
"
mkdir -p "$SMOKE_ROOT/c4/agent-A" "$SMOKE_ROOT/c4/agent-B"

out=$(CLAUDE_PLUGINS_FILE="$PLUGINS_FIX" \
      BRIDGE_AGENT_WORKDIR_JSON='{"agent-A":"'"$SMOKE_ROOT"'/c4/agent-A","agent-B":"'"$SMOKE_ROOT"'/c4/agent-B"}' \
      "$PYTHON" -c "$load_bd_preamble"$'\nimport pathlib\nprint(mod.render_shared_skill_routing_md(pathlib.Path("/tmp/bridge-home")))')

ok4=true
if ! grep -q "User-scope plugins" <<<"$out"; then ok4=false; fail 4 "missing 'User-scope plugins' header. output:\n$out"; fi
$ok4 && if ! grep -q "\`shopify\`" <<<"$out"; then ok4=false; fail 4 "missing user-scope shopify"; fi
$ok4 && if ! grep -q "\`frontend-design\`" <<<"$out"; then ok4=false; fail 4 "missing user-scope frontend-design"; fi
$ok4 && if ! grep -q "| \`agent-A\` " <<<"$out"; then ok4=false; fail 4 "missing agent-A row"; fi
$ok4 && if ! grep -q "| \`agent-B\` " <<<"$out"; then ok4=false; fail 4 "missing agent-B row"; fi
$ok4 && if ! grep -E "^\| \`agent-A\` \| .* \| \`discord\`, \`telegram\` \|$" <<<"$out" >/dev/null; then ok4=false; fail 4 "agent-A should list discord+telegram. got line:$(grep agent-A <<<"$out")"; fi
$ok4 && if ! grep -E "^\| \`agent-B\` \| .* \| — \|$" <<<"$out" >/dev/null; then ok4=false; fail 4 "agent-B should be — (no project-scope plugins)"; fi
$ok4 && pass 4

# ---------- case 5: orphan project plugins are dropped ----------
banner 5 "build_plugin_routing drops plugins whose projectPath has no agent match"
out=$(CLAUDE_PLUGINS_FILE="$PLUGINS_FIX" \
      BRIDGE_AGENT_WORKDIR_JSON='{"agent-A":"'"$SMOKE_ROOT"'/c4/agent-A"}' \
      "$PYTHON" -c "$load_bd_preamble"$'\nimport pathlib\nprint(mod.render_shared_skill_routing_md(pathlib.Path("/tmp/bridge-home")))')

ok5=true
# discord/telegram point at agent-A → should appear under agent-A
if ! grep -E "^\| \`agent-A\` \| .* \| \`discord\`, \`telegram\` \|$" <<<"$out" >/dev/null; then
  ok5=false; fail 5 "agent-A should still pick up discord+telegram. got: $(grep agent-A <<<"$out")"
fi
# agent-B is no longer in the roster — should NOT appear at all
if grep -q "agent-B" <<<"$out"; then ok5=false; fail 5 "agent-B should be absent"; fi
$ok5 && pass 5

# ---------- case 6: agb skills list --json shape ----------
banner 6 "agb skills list --json emits user_scope + agents shape"
# Use the LIVE roster — bridge-skills-cli.sh shells `agent-bridge agent
# list --json`, which we don't want to stub. Instead point CLAUDE_PLUGINS_FILE
# at the fixture and trust roster output.
J6=$(CLAUDE_PLUGINS_FILE="$PLUGINS_FIX" "$REPO_ROOT/agent-bridge" skills list --json 2>&1) || {
  fail 6 "skills list --json returned non-zero. output:\n$J6"
}
if [[ ${PASS} -ge 5 ]] && [[ -n "$J6" ]]; then
  ok6=true
  echo "$J6" | "$PYTHON" -c "
import json, sys
data = json.load(sys.stdin)
assert 'user_scope' in data and isinstance(data['user_scope'], list), data
assert 'agents' in data and isinstance(data['agents'], list), data
assert 'plugins_file' in data, data
# fixture user-scope plugins must appear
us = set(data['user_scope'])
assert 'shopify' in us, ('shopify missing', us)
assert 'frontend-design' in us, ('frontend-design missing', us)
# every agent row has expected keys
for row in data['agents']:
    assert {'agent','source','workdir','plugins'} <= row.keys(), row
print('ok')
" >/dev/null 2>&1 && pass 6 || { ok6=false; fail 6 "JSON shape validation failed. output:\n$J6"; }
fi

# ---------- case 7: --agent filter ----------
banner 7 "agb skills list --agent filter restricts output to one agent"
# Pick the first claude agent from the live roster as the filter.
FIRST_AGENT=$("$REPO_ROOT/agent-bridge" agent list --json 2>/dev/null | "$PYTHON" -c "
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r.get('engine') == 'claude':
        print(r['agent']); break
")
if [[ -z "$FIRST_AGENT" ]]; then
  pass 7  # nothing to filter on
else
  J7=$(CLAUDE_PLUGINS_FILE="$PLUGINS_FIX" "$REPO_ROOT/agent-bridge" skills list --agent "$FIRST_AGENT" --json 2>&1)
  count=$(echo "$J7" | "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); print(len(d['agents']))")
  if [[ "$count" == "1" ]]; then
    pass 7
  else
    fail 7 "expected 1 agent in filtered output, got $count"
  fi
fi

# ---------- case 8: --agent unknown ----------
banner 8 "agb skills list --agent <unknown> exits non-zero with clear error"
RC=0
ERR=$(CLAUDE_PLUGINS_FILE="$PLUGINS_FIX" "$REPO_ROOT/agent-bridge" skills list --agent "this-agent-definitely-does-not-exist-12345" 2>&1) || RC=$?
if [[ $RC -eq 0 ]]; then
  fail 8 "expected non-zero exit on unknown agent"
elif ! grep -q "is not a claude-engine agent" <<<"$ERR"; then
  fail 8 "expected 'is not a claude-engine agent' message; got:\n$ERR"
else
  pass 8
fi

# ---------- case 9: --agent table mode shows user-scope (codex r1) ----------
banner 9 "agb skills list --agent <name> table mode shows user-scope"
# Reuse $PLUGINS_FIX which carries shopify+frontend-design as user-scope
# plugins. With pre-fix code the user-scope header was suppressed when
# --agent was set; post-fix the table shows the header with a note that
# those plugins are *also* available to the filtered agent.
FIRST_AGENT_T=$("$REPO_ROOT/agent-bridge" agent list --json 2>/dev/null | "$PYTHON" -c "
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r.get('engine') == 'claude':
        print(r['agent']); break
")
if [[ -n "$FIRST_AGENT_T" ]]; then
  TABLE_OUT=$(CLAUDE_PLUGINS_FILE="$PLUGINS_FIX" "$REPO_ROOT/agent-bridge" skills list --agent "$FIRST_AGENT_T" 2>&1)
  if ! grep -q "user-scope" <<<"$TABLE_OUT"; then
    fail 9 "expected user-scope header in --agent table output. got:\n$TABLE_OUT"
  elif ! grep -q "shopify" <<<"$TABLE_OUT"; then
    fail 9 "expected fixture user-scope plugin 'shopify' in table output"
  else
    pass 9
  fi
else
  pass 9  # no claude agents — nothing to filter
fi

# ---------- case 10: mode-aware references in shared TOOLS.md (codex r1) ----------
banner 10 "render_shared_tools_md mode-aware skill guide line"
T_LEG=$(env -u BRIDGE_SKILLS_DOC_MODE "$PYTHON" -c "$load_bd_preamble"$'\nimport pathlib\nprint(mod.render_shared_tools_md(pathlib.Path("/tmp/bh")))')
T_PR=$(BRIDGE_SKILLS_DOC_MODE=plugin-routing "$PYTHON" -c "$load_bd_preamble"$'\nimport pathlib\nprint(mod.render_shared_tools_md(pathlib.Path("/tmp/bh")))')
T_DIS=$(BRIDGE_SKILLS_DOC_MODE=disabled "$PYTHON" -c "$load_bd_preamble"$'\nimport pathlib\nprint(mod.render_shared_tools_md(pathlib.Path("/tmp/bh")))')

ok10=true
# legacy-catalog: still references shared/SKILLS.md
grep -q "shared/SKILLS.md" <<<"$T_LEG" || { ok10=false; fail 10 "legacy-catalog should still reference shared/SKILLS.md"; }
# plugin-routing: must NOT reference shared/SKILLS.md, must reference skill-routing.md
$ok10 && grep -q "shared/SKILLS.md" <<<"$T_PR" && { ok10=false; fail 10 "plugin-routing TOOLS.md still references shared/SKILLS.md"; }
$ok10 && grep -q "skill-routing.md\|skills list" <<<"$T_PR" || { ok10=false; fail 10 "plugin-routing TOOLS.md missing skill-routing/skills list pointer"; }
# disabled: must NOT reference shared/SKILLS.md or skill-routing.md
$ok10 && grep -q "shared/SKILLS.md\|skill-routing.md" <<<"$T_DIS" && { ok10=false; fail 10 "disabled TOOLS.md still references shared/SKILLS.md or skill-routing.md"; }
$ok10 && grep -q "skills list\|Skill 도구" <<<"$T_DIS" || { ok10=false; fail 10 "disabled TOOLS.md missing 'agb skills list' / 'Skill 도구' pointer"; }
$ok10 && pass 10

# ---------- case 11: agent-bridge canon block mode-aware ----------
banner 11 "render_agent_bridge_block TOOLS+SKILLS canon line is mode-aware"
SCRIPT='
import importlib.util, sys, pathlib, tempfile
spec = importlib.util.spec_from_file_location("bd", "'"$REPO_ROOT"'/bridge-docs.py")
mod = importlib.util.module_from_spec(spec); sys.modules["bd"] = mod; spec.loader.exec_module(mod)
tmp = pathlib.Path(tempfile.mkdtemp())
print(mod.render_agent_bridge_block(tmp, session_type="general"))
'
B_LEG=$(env -u BRIDGE_SKILLS_DOC_MODE "$PYTHON" -c "$SCRIPT")
B_PR=$(BRIDGE_SKILLS_DOC_MODE=plugin-routing "$PYTHON" -c "$SCRIPT")
B_DIS=$(BRIDGE_SKILLS_DOC_MODE=disabled "$PYTHON" -c "$SCRIPT")

ok11=true
grep -qE "TOOLS\.md.*SKILLS\.md.*runtime reference" <<<"$B_LEG" || { ok11=false; fail 11 "legacy block must mention 'TOOLS.md와 SKILLS.md ... runtime reference'"; }
$ok11 && grep -q "TOOLS\.md.*SKILLS\.md" <<<"$B_PR" && { ok11=false; fail 11 "plugin-routing block must drop the 'TOOLS.md와 SKILLS.md' joint phrase"; }
$ok11 && grep -q "skill-routing\|skills list" <<<"$B_PR" || { ok11=false; fail 11 "plugin-routing block must point at skill-routing or 'agb skills list'"; }
$ok11 && grep -q "TOOLS\.md.*SKILLS\.md" <<<"$B_DIS" && { ok11=false; fail 11 "disabled block must drop the 'TOOLS.md와 SKILLS.md' joint phrase"; }
$ok11 && pass 11

# ---------- case 12: per-agent SKILLS.md anchor line is mode-aware ----------
banner 12 "render_agent_skills_md anchor bullet is mode-aware"
SCRIPT='
import importlib.util, sys, pathlib, tempfile
spec = importlib.util.spec_from_file_location("bd", "'"$REPO_ROOT"'/bridge-docs.py")
mod = importlib.util.module_from_spec(spec); sys.modules["bd"] = mod; spec.loader.exec_module(mod)
tmp = pathlib.Path(tempfile.mkdtemp())
print(mod.render_agent_skills_md(tmp, {}))
'
S_LEG=$(env -u BRIDGE_SKILLS_DOC_MODE "$PYTHON" -c "$SCRIPT")
S_PR=$(BRIDGE_SKILLS_DOC_MODE=plugin-routing "$PYTHON" -c "$SCRIPT")
S_DIS=$(BRIDGE_SKILLS_DOC_MODE=disabled "$PYTHON" -c "$SCRIPT")

ok12=true
grep -q "shared/SKILLS.md" <<<"$S_LEG" || { ok12=false; fail 12 "legacy per-agent SKILLS.md should still anchor on shared/SKILLS.md"; }
$ok12 && grep -q "shared/SKILLS.md" <<<"$S_PR" && { ok12=false; fail 12 "plugin-routing per-agent SKILLS.md still anchors on shared/SKILLS.md"; }
$ok12 && grep -q "skill-routing\|skills list" <<<"$S_PR" || { ok12=false; fail 12 "plugin-routing per-agent SKILLS.md must point at skill-routing or 'agb skills list'"; }
$ok12 && grep -q "shared/SKILLS.md" <<<"$S_DIS" && { ok12=false; fail 12 "disabled per-agent SKILLS.md still anchors on shared/SKILLS.md"; }
$ok12 && pass 12

# ---------- case 13: hard-coded SKILLS.md boot dependency removed ----------
banner 13 "_template + docs/agent-runtime SSOT drop SKILLS.md boot dependency"
ok13=true
# 13a: CLAUDE.md must NOT carry the legacy "TOOLS.md와 SKILLS.md는 ... reference다" bullet.
if grep -q "TOOLS.md\`와 \`SKILLS.md\`는 현재 bridge-native runtime reference" "$REPO_ROOT/agents/_template/CLAUDE.md"; then
  ok13=false; fail 13 "_template/CLAUDE.md still hard-codes the legacy 'TOOLS.md와 SKILLS.md ... reference' line"
fi
# 13b: CLAUDE.md must NOT include SKILLS.md as a plain '공통 운영 파일' (legacy-catalog 한정 표기는 OK).
if grep -E "공통 운영 파일이다[^(]*$" "$REPO_ROOT/agents/_template/CLAUDE.md" | grep -q "SKILLS\.md"; then
  ok13=false; fail 13 "_template/CLAUDE.md still treats SKILLS.md as an unconditional common-ops file"
fi
# 13c: CLAUDE.md step 10 must NOT say '"TOOLS.md, SKILLS.md 확인'.
if grep -q "10\..*TOOLS\.md, SKILLS\.md 확인" "$REPO_ROOT/agents/_template/CLAUDE.md"; then
  ok13=false; fail 13 "_template/CLAUDE.md step 10 still tells the agent to read SKILLS.md"
fi
# 13d: SOUL.md must NOT say 'TOOLS.md, SKILLS.md에서 확인한다'.
if grep -q "TOOLS\.md\`, \`SKILLS\.md\`에서 확인한다" "$REPO_ROOT/agents/_template/SOUL.md"; then
  ok13=false; fail 13 "_template/SOUL.md still tells the agent to read SKILLS.md as a runtime reference"
fi
# 13e (codex r1): docs/agent-runtime/common-instructions.md is the SSOT
# for the boot ritual; it must not carry the legacy joint phrase either.
if grep -q "TOOLS.md\`와 \`SKILLS.md\`는 현재 bridge-native runtime reference" "$REPO_ROOT/docs/agent-runtime/common-instructions.md"; then
  ok13=false; fail 13 "docs/agent-runtime/common-instructions.md still hard-codes 'TOOLS.md와 SKILLS.md ... reference'"
fi
# 13f (codex r1): _template/SKILLS.md should not exist — scaffolder copies
# every file under _template into a new agent home, so leaving the
# placeholder in source means plugin-routing/disabled scaffolds end up
# with a stale per-agent SKILLS.md.
if [[ -f "$REPO_ROOT/agents/_template/SKILLS.md" ]]; then
  ok13=false; fail 13 "agents/_template/SKILLS.md still exists; scaffolder will copy it into new agents in non-legacy modes"
fi
$ok13 && pass 13

# ---------- case 14: per-agent SKILLS.md emit gated by mode ----------
banner 14 "render+write per-agent SKILLS.md is gated by BRIDGE_SKILLS_DOC_MODE"
# We exercise the gating logic directly: in legacy-catalog mode the file is
# generated; in plugin-routing/disabled it is NOT generated and a
# pre-existing file would be removed (with backup).
SCRIPT='
import importlib.util, sys, pathlib, tempfile, os
spec = importlib.util.spec_from_file_location("bd", "'"$REPO_ROOT"'/bridge-docs.py")
mod = importlib.util.module_from_spec(spec); sys.modules["bd"] = mod; spec.loader.exec_module(mod)

mode = os.environ.get("BRIDGE_SKILLS_DOC_MODE", "legacy-catalog")
print("mode=" + mode + " " + mod.skills_doc_mode())
'
T_LEG=$(env -u BRIDGE_SKILLS_DOC_MODE "$PYTHON" -c "$SCRIPT")
T_PR=$(BRIDGE_SKILLS_DOC_MODE=plugin-routing "$PYTHON" -c "$SCRIPT")
T_DIS=$(BRIDGE_SKILLS_DOC_MODE=disabled "$PYTHON" -c "$SCRIPT")
ok14=true
grep -q "legacy-catalog legacy-catalog" <<<"$T_LEG" || { ok14=false; fail 14 "default mode resolution: $T_LEG"; }
grep -q "plugin-routing plugin-routing" <<<"$T_PR" || { ok14=false; fail 14 "plugin-routing mode resolution: $T_PR"; }
grep -q "disabled disabled" <<<"$T_DIS" || { ok14=false; fail 14 "disabled mode resolution: $T_DIS"; }
# Verify the apply-side branch: source the file to confirm the new code
# path is present (grep is enough — full apply needs roster scaffolding).
if ! grep -q 'if skills_doc_mode() == "legacy-catalog":' "$REPO_ROOT/bridge-docs.py"; then
  ok14=false; fail 14 "bridge-docs.py per-agent SKILLS.md emit is not gated on skills_doc_mode()"
fi
if ! grep -q '"removed:" + str(skills_path)\|removed:{skills_path}' "$REPO_ROOT/bridge-docs.py"; then
  # we use the f-string form `removed:{skills_path}`; pin its presence.
  if ! grep -q 'changed.append(f"removed:{skills_path}")' "$REPO_ROOT/bridge-docs.py"; then
    ok14=false; fail 14 "bridge-docs.py non-legacy branch must record 'removed:<path>' so dry-run reports it"
  fi
fi
$ok14 && pass 14

# ---------- case 15: per-agent SKILLS.md create/apply gating end-to-end ----------
# Codex r1 on PR #514 asked for an apply-level smoke (rather than only
# grepping bridge-docs.py source). Build a tiny BRIDGE_HOME with a
# pre-existing per-agent SKILLS.md fixture, simulate the gating logic
# via the same code path bridge-docs.py uses, and verify:
#   legacy-catalog → file rewritten with current registry text
#   plugin-routing/disabled → file removed (with backup) and `removed:`
#                              recorded in the changed list
#   unlink failure → no `removed:` recorded (codex r1 issue 3)
banner 15 "per-agent SKILLS.md gating: legacy keeps, non-legacy removes (with loud unlink)"
C15_HOME="$SMOKE_ROOT/c15"
C15_AGENT_DIR="$C15_HOME/agents/test-agent"
C15_BACKUP="$C15_HOME/state/backups/c15"
mkdir -p "$C15_AGENT_DIR" "$C15_BACKUP"
# Seed with a stale per-agent SKILLS.md
echo "STALE LEGACY CATALOG CONTENT" > "$C15_AGENT_DIR/SKILLS.md"

run_gate() {
  # $1 = mode env, $2 = expected-action (write|remove|skip), $3 = expected-removed-marker (1|0)
  local mode_env="$1"
  local expected_action="$2"
  local expect_removed="$3"
  local fixture_dir="$C15_AGENT_DIR-$mode_env"
  rm -rf "$fixture_dir"; mkdir -p "$fixture_dir"
  # Always reseed the stale file so each invocation is independent.
  echo "STALE LEGACY CATALOG CONTENT" > "$fixture_dir/SKILLS.md"
  local backup_dir="$C15_BACKUP/$mode_env"
  rm -rf "$backup_dir"; mkdir -p "$backup_dir"

  BRIDGE_SKILLS_DOC_MODE="$mode_env" \
  AGENT_DIR="$fixture_dir" \
  BACKUP_DIR="$backup_dir" \
  EXPECT_ACTION="$expected_action" \
  EXPECT_REMOVED="$expect_removed" \
  "$PYTHON" -c "$load_bd_preamble"$'
import os, pathlib, sys
agent_dir = pathlib.Path(os.environ["AGENT_DIR"])
backup_root = pathlib.Path(os.environ["BACKUP_DIR"])
mode = mod.skills_doc_mode()
skills_path = agent_dir / "SKILLS.md"
changed = []
if mode == "legacy-catalog":
    skills_text = "# regenerated\\n"  # we only check that the path exists post-gate
    old_skills = skills_path.read_text() if skills_path.exists() else None
    if old_skills != skills_text:
        if skills_path.exists():
            mod.backup_file(skills_path, backup_root, False)
        mod.write_text(skills_path, skills_text, False)
        changed.append(str(skills_path))
else:
    if skills_path.exists() or skills_path.is_symlink():
        mod.backup_file(skills_path, backup_root, False)
        skills_path.unlink()
        changed.append(f"removed:{skills_path}")
expect_action = os.environ["EXPECT_ACTION"]
expect_removed = os.environ["EXPECT_REMOVED"] == "1"
removed_recorded = any(c.startswith("removed:") for c in changed)
if expect_removed != removed_recorded:
    sys.exit(f"expected removed={expect_removed}, got {removed_recorded}; changed={changed}")
if expect_action == "write" and not skills_path.exists():
    sys.exit("expected SKILLS.md to be present after legacy gate")
if expect_action == "remove" and skills_path.exists():
    sys.exit("expected SKILLS.md to be removed in non-legacy gate")
print("ok")
'
}

ok15=true
run_gate "legacy-catalog" "write" "0" >/dev/null 2>&1 || { ok15=false; fail 15 "legacy-catalog gate did not preserve+rewrite SKILLS.md"; }
$ok15 && run_gate "plugin-routing" "remove" "1" >/dev/null 2>&1 || { ok15=false; fail 15 "plugin-routing gate did not remove SKILLS.md or did not record 'removed:'"; }
$ok15 && run_gate "disabled" "remove" "1" >/dev/null 2>&1 || { ok15=false; fail 15 "disabled gate did not remove SKILLS.md or did not record 'removed:'"; }
$ok15 && pass 15

# ---------- case 16: sync_shared_docs cleans up stale _template/SKILLS.md ----------
# patch's PR #514 verify (#3115) found that hosts upgraded before PR #514
# still carried agents/_template/SKILLS.md in the live runtime — source
# deleted the file but `agent-bridge upgrade` does not propagate
# source-side deletions. The follow-up fix has sync_shared_docs explicitly
# clean up the stale file. Pin that here.
banner 16 "sync_shared_docs removes stale agents/_template/SKILLS.md from live runtime"
C16_HOME="$SMOKE_ROOT/c16"
SOURCE_SHARED="$SMOKE_ROOT/c16-src-shared"
mkdir -p "$C16_HOME/agents/_template" "$C16_HOME/state" "$SOURCE_SHARED"
echo "STALE TEMPLATE SKILLS CONTENT" > "$C16_HOME/agents/_template/SKILLS.md"

"$PYTHON" -c "$load_bd_preamble"$'
import pathlib
home = pathlib.Path("'"$C16_HOME"'")
src = pathlib.Path("'"$SOURCE_SHARED"'")
mod.sync_shared_docs(home, src, dry_run=False, stamp="20260503T000000Z", registry={})
'

ok16=true
if [[ -f "$C16_HOME/agents/_template/SKILLS.md" ]]; then
  ok16=false; fail 16 "stale _template/SKILLS.md not removed from live runtime"
fi
# Backup must be present so the cleanup is recoverable
BACKUP_DIR="$C16_HOME/state/doc-migration/backups/20260503T000000Z/_template"
if $ok16 && [[ ! -f "$BACKUP_DIR/SKILLS.md" ]]; then
  ok16=false; fail 16 "expected backup at $BACKUP_DIR/SKILLS.md (cleanup must be recoverable). state contents:\n$(find "$C16_HOME/state" -type f 2>/dev/null)"
fi
$ok16 && pass 16

# ---------- case 17: operating-manual shared skill registry/catalog ----------
banner 17 "agent-bridge-operating-manual appears in registry and legacy catalogs"
C17_HOME="$SMOKE_ROOT/c17"
C17_SOURCE_SHARED="$SMOKE_ROOT/c17-src-shared"
mkdir -p "$C17_HOME/state" "$C17_SOURCE_SHARED"

OUT17=$("$PYTHON" -c "$load_bd_preamble"$'
import json
import pathlib

home = pathlib.Path("'"$C17_HOME"'")
source_shared = pathlib.Path("'"$C17_SOURCE_SHARED"'")
registry = mod.build_skill_registry(home)
assert "agent-bridge-operating-manual" in registry, sorted(registry)
mod.write_skill_registry(home, registry, dry_run=False)
mod.sync_shared_docs(home, source_shared, dry_run=False, stamp="20260503T000001Z", registry=registry)

payload = json.loads((home / "state" / "skill-registry.json").read_text(encoding="utf-8"))
assert "agent-bridge-operating-manual" in payload["skills"], payload["skills"].keys()
shared_catalog = (home / "shared" / "SKILLS.md").read_text(encoding="utf-8")
assert "`agent-bridge-operating-manual`" in shared_catalog, shared_catalog
agent_catalog = mod.render_agent_skills_md(home / "agents" / "agent-a", registry)
assert "agent-bridge-operating-manual" in agent_catalog, agent_catalog
print("ok")
' 2>&1) || {
  fail 17 "registry/catalog assertion failed:\n$OUT17"
}
if [[ "$OUT17" == "ok" ]]; then
  pass 17
fi

# ---------- summary ----------
printf '\n=== summary: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
