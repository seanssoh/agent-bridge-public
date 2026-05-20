#!/usr/bin/env bash
# scripts/smoke/antigravity-settings-preseed.sh — Antigravity wave Track C1.
#
# Validates the agy launch-contract surface C1 owns:
#   - bridge_antigravity_settings_preseed performs an ATOMIC, key-preserving
#     mutation of the agy settings.json (trustedWorkspaces + permissions.allow
#     + altScreenMode), and is idempotent on re-run;
#   - bridge_antigravity_dynamic_launch_cmd emits the fresh form (`-i
#     <bootstrap>`) and the resume form (`--conversation <id>`);
#   - bridge_bootstrap_project_skill antigravity writes a non-empty SKILL.md
#     (proving the renderer arm is not a silent no-op).
#
# Assertions:
# T1: preseed preserves ALL pre-existing keys, adds the workdir to
#     trustedWorkspaces, adds both command(...) allow entries, sets
#     altScreenMode=inline.
# T2: preseed is idempotent — a second run adds nothing duplicate.
# T3: fresh launch cmd carries `agy --dangerously-skip-permissions -i
#     <bootstrap-prompt>`; resume launch cmd carries `--conversation <id>`
#     and drops `-i`.
# T4: bridge_bootstrap_project_skill antigravity writes a non-empty
#     SKILL.md under .agents/skills/agent-bridge/.

set -euo pipefail

SMOKE_NAME="antigravity-settings-preseed"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Load the bridge library in this isolated environment so the C1 helpers
# are callable directly.
load_bridge_lib() {
  export BRIDGE_SCRIPT_DIR="$SMOKE_REPO_ROOT"
  # shellcheck source=bridge-lib.sh
  source "$SMOKE_REPO_ROOT/bridge-lib.sh"
}

assert_preseed_preserves_and_adds() {
  local gemini_root="$SMOKE_TMP_ROOT/gemini"
  local cfg_dir="$gemini_root/antigravity-cli"
  local settings="$cfg_dir/settings.json"
  local workdir="$SMOKE_TMP_ROOT/agy-workdir"
  mkdir -p "$cfg_dir" "$workdir"

  # Pre-existing settings with keys the preseed must NOT clobber.
  cat >"$settings" <<'JSON'
{
  "colorScheme": "dark",
  "enableTelemetry": false,
  "trustedWorkspaces": ["/pre/existing/dir"],
  "permissions": {
    "allow": ["command(/usr/bin/git)"],
    "deny": ["command(/bin/rm)"]
  },
  "altScreenMode": "always"
}
JSON

  GEMINI_HOME="$gemini_root" bridge_antigravity_settings_preseed "$workdir" \
    || smoke_fail "T1: preseed exited non-zero"

  local dump
  dump="$(python3 - "$settings" "$workdir" <<'PY'
import json, sys
settings, workdir = sys.argv[1], sys.argv[2]
with open(settings, encoding="utf-8") as fh:
    data = json.load(fh)
checks = []
checks.append("colorScheme=%s" % data.get("colorScheme"))
checks.append("enableTelemetry=%s" % data.get("enableTelemetry"))
checks.append("preExistingTrust=%s" % ("/pre/existing/dir" in data.get("trustedWorkspaces", [])))
checks.append("workdirTrust=%s" % (workdir in data.get("trustedWorkspaces", [])))
allow = data.get("permissions", {}).get("allow", [])
checks.append("preExistingAllow=%s" % ("command(/usr/bin/git)" in allow))
checks.append("denyPreserved=%s" % ("command(/bin/rm)" in data.get("permissions", {}).get("deny", [])))
checks.append("agbAllow=%s" % any(e.endswith("/agb)") for e in allow))
checks.append("agentBridgeAllow=%s" % any(e.endswith("/agent-bridge)") for e in allow))
checks.append("altScreenMode=%s" % data.get("altScreenMode"))
print(" ".join(checks))
PY
)"

  smoke_assert_contains "$dump" "colorScheme=dark"        "T1: colorScheme preserved"
  smoke_assert_contains "$dump" "enableTelemetry=False"   "T1: enableTelemetry preserved"
  smoke_assert_contains "$dump" "preExistingTrust=True"   "T1: pre-existing trusted dir preserved"
  smoke_assert_contains "$dump" "workdirTrust=True"       "T1: workdir added to trustedWorkspaces"
  smoke_assert_contains "$dump" "preExistingAllow=True"   "T1: pre-existing allow entry preserved"
  smoke_assert_contains "$dump" "denyPreserved=True"      "T1: permissions.deny preserved"
  smoke_assert_contains "$dump" "agbAllow=True"           "T1: agb command(...) allow added"
  smoke_assert_contains "$dump" "agentBridgeAllow=True"   "T1: agent-bridge command(...) allow added"
  smoke_assert_contains "$dump" "altScreenMode=inline"    "T1: altScreenMode set to inline"
}

assert_preseed_idempotent() {
  local gemini_root="$SMOKE_TMP_ROOT/gemini"
  local settings="$gemini_root/antigravity-cli/settings.json"
  local workdir="$SMOKE_TMP_ROOT/agy-workdir"

  # Second run on the already-seeded file from T1.
  GEMINI_HOME="$gemini_root" bridge_antigravity_settings_preseed "$workdir" \
    || smoke_fail "T2: second preseed exited non-zero"

  local counts
  counts="$(python3 - "$settings" "$workdir" <<'PY'
import json, sys
settings, workdir = sys.argv[1], sys.argv[2]
with open(settings, encoding="utf-8") as fh:
    data = json.load(fh)
trusted = data.get("trustedWorkspaces", [])
allow = data.get("permissions", {}).get("allow", [])
print("trustWorkdir=%d allowAgb=%d allowBridge=%d" % (
    trusted.count(workdir),
    sum(1 for e in allow if e.endswith("/agb)")),
    sum(1 for e in allow if e.endswith("/agent-bridge)")),
))
PY
)"

  smoke_assert_contains "$counts" "trustWorkdir=1"  "T2: workdir trusted exactly once"
  smoke_assert_contains "$counts" "allowAgb=1"      "T2: agb allow entry present exactly once"
  smoke_assert_contains "$counts" "allowBridge=1"   "T2: agent-bridge allow entry present exactly once"
}

assert_launch_builder_fresh_and_resume() {
  local fresh resume prompt
  fresh="$(bridge_antigravity_dynamic_launch_cmd agyrole 0 "")"
  smoke_assert_contains "$fresh" "agy --dangerously-skip-permissions" \
    "T3: fresh launch cmd uses agy --dangerously-skip-permissions"
  smoke_assert_contains "$fresh" " -i " \
    "T3: fresh launch cmd carries the -i bootstrap flag"
  smoke_assert_not_contains "$fresh" "--conversation" \
    "T3: fresh launch cmd has no --conversation"

  # The -i argument is %q-quoted into the argv; assert on the raw
  # bootstrap-prompt string so whitespace escaping is not in the way.
  prompt="$(bridge_antigravity_bootstrap_prompt agyrole)"
  smoke_assert_contains "$prompt" "agb inbox agyrole" \
    "T3: fresh -i bootstrap prompt points the agent at its inbox"
  smoke_assert_contains "$prompt" "SOUL.md and CLAUDE.md" \
    "T3: fresh -i bootstrap prompt points the agent at its context files"

  resume="$(bridge_antigravity_dynamic_launch_cmd agyrole 1 conv-abc123)"
  smoke_assert_contains "$resume" "--conversation conv-abc123" \
    "T3: resume launch cmd carries --conversation <id>"
  smoke_assert_not_contains "$resume" " -i " \
    "T3: resume launch cmd drops the -i bootstrap"
}

assert_project_skill_written() {
  local workdir="$SMOKE_TMP_ROOT/agy-skill"
  mkdir -p "$workdir"
  bridge_bootstrap_project_skill antigravity "$workdir" \
    || smoke_fail "T4: bridge_bootstrap_project_skill antigravity exited non-zero"
  local skill_file="$workdir/.agents/skills/agent-bridge/SKILL.md"
  smoke_assert_file_exists "$skill_file" "T4: antigravity SKILL.md written"
  [[ -s "$skill_file" ]] || smoke_fail "T4: antigravity SKILL.md is empty"
  smoke_assert_contains "$(cat "$skill_file")" "name: agent-bridge" \
    "T4: antigravity SKILL.md has the skill frontmatter"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  load_bridge_lib

  smoke_run "T1: preseed preserves keys + adds entries" assert_preseed_preserves_and_adds
  smoke_run "T2: preseed idempotent on re-run"          assert_preseed_idempotent
  smoke_run "T3: launch builder fresh + resume forms"   assert_launch_builder_fresh_and_resume
  smoke_run "T4: project-skill writes SKILL.md"         assert_project_skill_written

  smoke_log "PASS"
}

main "$@"
