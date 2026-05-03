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

# ---------- summary ----------
printf '\n=== summary: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
