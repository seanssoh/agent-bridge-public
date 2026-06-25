#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/17957-disposable-no-poller.sh — #17957 path B.
#
# Pins the invariant that every bridge-spawned disposable / non-interactive
# `claude -p` that runs in the agent's real config-dir launches WITHOUT the
# singleton channel plugins (telegram@claude-plugins-official,
# discord@claude-plugins-official) so it cannot SIGTERM-steal the admin's live
# `getUpdates` poller — WHILE preserving every other plugin and every MCP server
# the spawn legitimately needs.
#
# Mechanism under test: a per-invocation `--settings` JSON overlay
# (lib/bridge_disposable_claude.py:singleton_channel_suppression_argv) spliced
# after `-p`. The overlay carries ONLY `enabledPlugins` with the two singleton
# channels set false and no `mcpServers` key, so a per-key settings merge (the
# same contract scripts/apply-channel-policy.sh relies on) disables just the
# singletons and leaves the rest intact. `--strict-mcp-config` must NOT appear
# (it would over-broadly drop the functional MCP knowledge/memory need).
#
# Cases (all in a temp tree + a fake `claude` on PATH; never runs the real CLI,
# never touches live runtime):
#   T1. bridge-knowledge.py lint --llm-review  → spawn argv carries the overlay
#   T2. bridge-memory.py summarize weekly --llm → spawn argv carries the overlay
#   T3. source guard: every `[claude, "-p"` spawn in knowledge/memory carries
#       the suppression splice (regression guard for a future un-hardened spawn)

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:17957-disposable-no-poller][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="17957-disposable-no-poller"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_make_temp_root
REPO_ROOT="$SMOKE_REPO_ROOT"

# --- fake `claude` that records its argv and exits 0 ------------------------
FAKE_BIN="$SMOKE_TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
ARGV_DUMP="$SMOKE_TMP_ROOT/argv.json"
cat >"$FAKE_BIN/claude" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["AGB_FAKE_CLAUDE_ARGV"], "w", encoding="utf-8") as fh:
    json.dump(sys.argv[1:], fh)
# Valid for both callers: knowledge json.loads()es it; memory returns the text.
sys.stdout.write('{"findings": [], "suggestions": []}')
PYEOF
chmod +x "$FAKE_BIN/claude"
export AGB_FAKE_CLAUDE_ARGV="$ARGV_DUMP"
export PATH="$FAKE_BIN:$PATH"

# Shared assertion: the recorded spawn argv carries the singleton-channel
# suppression overlay and nothing broader; the resulting merge keeps other
# plugins + MCP. Driven from python so the merge mirrors the documented
# per-key settings-merge contract.
assert_overlay() {
  local label="$1" dump="$2"
  AGB_ASSERT_LABEL="$label" python3 - "$dump" <<'PYEOF'
import json
import os
import sys

label = os.environ["AGB_ASSERT_LABEL"]


def fail(msg):
    sys.stderr.write(f"[smoke:17957-disposable-no-poller][error] {label}: {msg}\n")
    sys.exit(1)


with open(sys.argv[1], encoding="utf-8") as fh:
    argv = json.load(fh)

# Over-broad MCP kill must NOT be used on these spawns.
if "--strict-mcp-config" in argv:
    fail("argv carries --strict-mcp-config (would drop functional MCP)")

if "--settings" not in argv:
    fail(f"no --settings overlay in spawned argv: {argv}")

overlay = json.loads(argv[argv.index("--settings") + 1])

if set(overlay.keys()) != {"enabledPlugins"}:
    fail(f"overlay must touch only enabledPlugins, got keys {sorted(overlay.keys())}")

ep = overlay["enabledPlugins"]
expected = {
    "telegram@claude-plugins-official": False,
    "discord@claude-plugins-official": False,
}
if ep != expected:
    fail(f"overlay enabledPlugins must disable exactly the singletons, got {ep}")

# Simulate the per-key settings merge Claude applies (apply-channel-policy.sh
# contract): a synthetic agent config with the singletons ON, other plugins ON,
# and live MCP servers. The overlay must flip ONLY the singletons.
base = {
    "enabledPlugins": {
        "telegram@claude-plugins-official": True,
        "discord@claude-plugins-official": True,
        "teams@claude-plugins-official": True,
        "example-tool@example-marketplace": True,
    },
    "mcpServers": {
        "example-tool": {"command": "proxy"},
        "teams": {"command": "proxy"},
    },
}
merged = dict(base)
merged_ep = dict(base["enabledPlugins"])
merged_ep.update(ep)
merged["enabledPlugins"] = merged_ep

if merged["enabledPlugins"]["telegram@claude-plugins-official"] is not False:
    fail("merge did not disable telegram singleton")
if merged["enabledPlugins"]["discord@claude-plugins-official"] is not False:
    fail("merge did not disable discord singleton")
if merged["enabledPlugins"]["teams@claude-plugins-official"] is not True:
    fail("merge disabled a non-singleton plugin (teams)")
if merged["enabledPlugins"]["example-tool@example-marketplace"] is not True:
    fail("merge disabled a non-singleton plugin (example-tool)")
if merged["mcpServers"] != base["mcpServers"]:
    fail("merge mutated mcpServers (functional MCP must be preserved)")

print(f"[smoke:17957-disposable-no-poller] {label}: OK — singleton channels "
      "suppressed; other plugins + MCP preserved")
PYEOF
}

# --- T1: knowledge LLM review spawn ----------------------------------------
SHARED_ROOT="$SMOKE_TMP_ROOT/shared"
TEMPLATE_ROOT="$SMOKE_TMP_ROOT/templates"
mkdir -p "$SHARED_ROOT" "$TEMPLATE_ROOT"
rm -f "$ARGV_DUMP"
python3 "$REPO_ROOT/bridge-knowledge.py" init \
  --shared-root "$SHARED_ROOT" --template-root "$TEMPLATE_ROOT" --json >/dev/null
python3 "$REPO_ROOT/bridge-knowledge.py" lint \
  --shared-root "$SHARED_ROOT" --llm-review --json >/dev/null || true
smoke_assert_file_exists "$ARGV_DUMP" "T1: knowledge lint --llm-review did not spawn claude"
assert_overlay "T1 knowledge" "$ARGV_DUMP"

# --- T2: memory weekly summary spawn ---------------------------------------
MEM_HOME="$SMOKE_TMP_ROOT/mem-home"
mkdir -p "$MEM_HOME"
WEEK="$(AGB_MEM_HOME="$MEM_HOME" python3 - <<'PYEOF'
import datetime
import os
import pathlib

home = pathlib.Path(os.environ["AGB_MEM_HOME"])
base = home / "memory"
base.mkdir(parents=True, exist_ok=True)
# A day exactly 7 days ago always lands in the previous ISO week.
prev = datetime.date.today() - datetime.timedelta(days=7)
year, week, _ = prev.isocalendar()
monday = datetime.date.fromisocalendar(year, week, 1)
for offset in range(7):
    day = monday + datetime.timedelta(days=offset)
    (base / f"{day.isoformat()}.md").write_text(
        f"# Note {day}\n\n- worked on item {offset} on {day}\n", encoding="utf-8"
    )
print(f"{year}-W{week:02d}")
PYEOF
)"
rm -f "$ARGV_DUMP"
python3 "$REPO_ROOT/bridge-memory.py" summarize weekly \
  --agent smoke-agent --home "$MEM_HOME" --week "$WEEK" --llm --json >/dev/null || true
smoke_assert_file_exists "$ARGV_DUMP" "T2: memory summarize weekly --llm did not spawn claude"
assert_overlay "T2 memory" "$ARGV_DUMP"

# --- T3: source guard — no un-hardened `claude -p` spawn slips back in ------
for f in bridge-knowledge.py bridge-memory.py; do
  spawn_count="$(grep -cE '\[claude, "-p"' "$REPO_ROOT/$f" || true)"
  splice_count="$(grep -E '\[claude, "-p"' "$REPO_ROOT/$f" \
    | grep -c 'singleton_channel_suppression_argv' || true)"
  [[ "$spawn_count" -ge 1 ]] \
    || smoke_fail "T3: expected >=1 disposable claude -p spawn in $f, found none (pattern moved?)"
  [[ "$spawn_count" == "$splice_count" ]] \
    || smoke_fail "T3: $f has $spawn_count claude -p spawns but only $splice_count carry the suppression splice"
  smoke_log "T3 $f: all $spawn_count disposable claude -p spawns carry the suppression splice"
done

smoke_log "PASS"
