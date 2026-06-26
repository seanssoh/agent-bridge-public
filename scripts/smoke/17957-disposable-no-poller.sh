#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/17957-disposable-no-poller.sh — #17957 path B.
#
# Pins the GLOBAL invariant that EVERY bridge-spawned disposable / short
# `claude -p` that runs in (or inherits) the agent's real config-dir launches
# WITHOUT the singleton channel plugins (telegram@claude-plugins-official,
# discord@claude-plugins-official) so it cannot SIGTERM-steal the admin's live
# `getUpdates` poller — WHILE preserving every other plugin and every MCP server
# the spawn legitimately needs.
#
# Channel-off mechanisms recognised as valid (any ONE per spawn-site):
#   - the singleton-only `--settings` overlay
#     (lib/bridge_disposable_claude.py:singleton_channel_suppression_argv for
#      Python; runtime-templates/scripts/lib/singleton-channel-suppression.sh's
#      SINGLETON_CHANNEL_SUPPRESSION_ARGS for bash; baked literal for the
#      create-agent generated runner),
#   - `--strict-mcp-config` (no-MCP child, e.g. the cron runner), or
#   - a fully isolated CLAUDE_CONFIG_DIR (e.g. the token probe).
# `--strict-mcp-config` must NOT appear on the knowledge/memory overlay spawns
# (it would over-broadly drop the functional MCP those helpers need).
#
# Cases (all in a temp tree + a fake `claude` on PATH; never runs the real CLI,
# never touches live runtime):
#   T1. bridge-knowledge.py lint --llm-review  → spawn argv carries the overlay
#   T2. bridge-memory.py summarize weekly --llm → spawn argv carries the overlay
#   T3. per-spawn source guard: every `[claude, "-p"` spawn in knowledge/memory
#       carries the suppression splice (fine-grained regression guard)
#   T4. GLOBAL spawn-OCCURRENCE scan: every claude `-p` spawn repo-wide carries a
#       channel-off path WITHIN its own command span; a NEW naked spawn — whether
#       a brand-new file OR a second spawn appended to an already-approved file —
#       and a removed channel-off path both FAIL. The occurrence-level (not
#       file-level) check is what keeps the spawn set from silently growing back
#       into path B; environmental-isolation spawns (token probe) are allowlisted
#       with a pinned count so they can't absorb a new naked spawn.
#   T5. DRY/sync: the bash helper overlay + the create-agent baked overlay +
#       the Python helper all disable EXACTLY the canonical singleton channels.

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
smoke_require_cmd git

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

# --- file-as-argv python helpers (NO heredoc-stdin; footgun #11 / heredoc-ban
#     compliant — every helper is written to a file then invoked file-as-argv) -
HELPERS="$SMOKE_TMP_ROOT/helpers"
mkdir -p "$HELPERS"

# argv-overlay assertion: the recorded spawn argv carries the singleton-channel
# suppression overlay and nothing broader; a simulated per-key merge keeps other
# plugins + MCP.
cat >"$HELPERS/assert_overlay.py" <<'PYEOF'
#!/usr/bin/env python3
"""Usage: assert_overlay.py <argv_dump.json> <label>"""
import json
import sys

dump, label = sys.argv[1], sys.argv[2]


def fail(msg):
    sys.stderr.write(f"[smoke:17957-disposable-no-poller][error] {label}: {msg}\n")
    sys.exit(1)


with open(dump, encoding="utf-8") as fh:
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
merged_ep = dict(base["enabledPlugins"])
merged_ep.update(ep)

if merged_ep["telegram@claude-plugins-official"] is not False:
    fail("merge did not disable telegram singleton")
if merged_ep["discord@claude-plugins-official"] is not False:
    fail("merge did not disable discord singleton")
if merged_ep["teams@claude-plugins-official"] is not True:
    fail("merge disabled a non-singleton plugin (teams)")
if merged_ep["example-tool@example-marketplace"] is not True:
    fail("merge disabled a non-singleton plugin (example-tool)")
# The overlay carries no mcpServers key, so the merge cannot touch them.
if "mcpServers" in overlay:
    fail("overlay must not carry an mcpServers key")

print(f"[smoke:17957-disposable-no-poller] {label}: OK — singleton channels "
      "suppressed; other plugins + MCP preserved")
PYEOF

# Seed the previous ISO week of memory notes + print its `YYYY-Www` label.
cat >"$HELPERS/mkweek.py" <<'PYEOF'
#!/usr/bin/env python3
"""Usage: mkweek.py <mem_home>  -> prints the previous ISO week as YYYY-Www."""
import datetime
import pathlib
import sys

home = pathlib.Path(sys.argv[1])
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

# GLOBAL spawn-site audit (T4) + DRY/sync check (T5).
cat >"$HELPERS/audit.py" <<'PYEOF'
#!/usr/bin/env python3
"""Usage: audit.py <repo_root>

GLOBAL #17957 path-B invariant enforcer — SPAWN-OCCURRENCE level.

Scans every claude headless `-p` spawn OCCURRENCE repo-wide (production surface;
test scaffolds under scripts/smoke and tests are excluded). For EACH occurrence
it requires a channel-off path WITHIN that spawn's own command/argv span:
  - the singleton-only `--settings` overlay (singleton_channel_suppression_argv
    / SINGLETON_CHANNEL_SUPPRESSION_ARGS / a baked enabledPlugins overlay), or
  - `--strict-mcp-config` (no-MCP child).
A spawn whose span carries no argv marker is "uncovered" and is allowed ONLY in a
file whose channel-off is ENVIRONMENTAL (a fully isolated CLAUDE_CONFIG_DIR), and
ONLY up to that file's PINNED uncovered-spawn count. Any other uncovered spawn —
a brand-new naked spawn-site, OR a SECOND naked spawn appended to an
already-approved file — FAILS (occurrence-level, so it cannot ride an unrelated
marker elsewhere in the same file). T5 then checks the bash helper /
create-agent / Python overlays all agree on the canonical singleton set.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1]).resolve()


def fail(msg):
    sys.stderr.write(f"[smoke:17957-disposable-no-poller][error] {msg}\n")
    sys.exit(1)


# Canonical singleton set — single source of truth in the Python helper.
sys.path.insert(0, str(repo / "lib"))
try:
    from bridge_disposable_claude import (  # noqa: E402
        SINGLETON_CHANNEL_PLUGINS,
        singleton_channel_suppression_overlay,
    )
except ImportError as exc:  # pragma: no cover
    fail(f"cannot import lib/bridge_disposable_claude.py: {exc}")

CANON = {plugin: False for plugin in SINGLETON_CHANNEL_PLUGINS}

# Discovery: every claude headless `-p` launch shape, one match per spawn line.
# Covers the python argv-list forms (single-line + multiline list element), the
# bash `$CLAUDE_BIN` / `${CLAUDE_BIN}` / `"$CLAUDE_BIN"` / `"${CLAUDE_BIN}"`
# spellings, and the bare `claude -p` of a generated runner.
DISCOVERY = re.compile(
    r'\[\s*claude(_bin)?\s*,\s*"-p"'                    # python list (one line)
    r'|"?\$\{?CLAUDE_BIN\}?"?\s+(-c\s+)?-p(\s|\\|$)'    # bash $CLAUDE_BIN/"${CLAUDE_BIN}"
    r'|(^|\s)claude\s+-p(\s|\\|$)'                      # bare `claude -p`
    r'|^\s*claude(_bin)?\s*,\s*$'                       # python list element (multiline)
)

# An argv-level channel-off marker present in the spawn's OWN command span. The
# inline-baked form must be the REAL `--settings` overlay that disables the
# telegram singleton — NOT a bare `enabledPlugins` token, which a prompt string
# could contain and false-pass.
ARGV_MARKER = re.compile(
    r'singleton_channel_suppression_argv'
    r'|SINGLETON_CHANNEL_SUPPRESSION_ARGS'
    r'|--strict-mcp-config'
    r'|--settings[^\n]*"telegram@claude-plugins-official"\s*:\s*false'
)

# Files whose channel-off is ENVIRONMENTAL (a fully isolated CLAUDE_CONFIG_DIR,
# so the spawn argv legitimately carries no overlay) — allowlisted up to a
# PINNED uncovered-spawn count so a SECOND naked spawn cannot hide behind the
# isolation. The file must still actually isolate the config dir.
ISOLATION_ALLOWLIST = {"bridge-auth.py": 1}


def command_span(lines, idx):
    """Text of the spawn's OWN command span, scanning DOWNWARD ONLY from the
    matched line. Channel-off markers sit on the spawn line itself or BELOW it
    (the splice / `--strict-mcp-config` / overlay inside the same list or
    backslash-continuation) — never above — so refusing to scan upward means an
    unrelated bracketed value ABOVE the spawn can never bleed a marker in. The
    span is bounded to the spawn itself, which is what makes the marker check
    occurrence-level rather than file-level."""
    cur = lines[idx]
    stripped = cur.rstrip()
    if stripped.endswith("\\"):                       # bash backslash-continuation block
        end = idx
        while end < len(lines) - 1 and lines[end].rstrip().endswith("\\"):
            end += 1
        return "\n".join(lines[idx:end + 1])
    if stripped.endswith(",") and "[" not in cur:     # python multiline list element
        end, down = idx, 0
        while end < len(lines) - 1 and "]" not in lines[end] and down < 12:
            end += 1
            down += 1
        return "\n".join(lines[idx:end + 1])
    return cur                                        # single-line list / bare line


tracked = subprocess.run(
    ["git", "-C", str(repo), "ls-files", "*.py", "*.sh"],
    check=True,
    capture_output=True,
    text=True,
).stdout.splitlines()

discovered = []           # (rel, 1-based line)
uncovered_by_file = {}    # rel -> [line, ...] (spawns with no argv marker)
for rel in tracked:
    if rel.startswith("scripts/smoke/") or rel.startswith("tests/"):
        continue
    try:
        lines = (repo / rel).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        continue
    for i, line in enumerate(lines):
        # Skip comment-only lines (bash/python `#`) — a comment that merely
        # mentions `claude -p` is not a spawn-site.
        if line.lstrip().startswith("#"):
            continue
        if not DISCOVERY.search(line):
            continue
        discovered.append((rel, i + 1))
        if not ARGV_MARKER.search(command_span(lines, i)):
            uncovered_by_file.setdefault(rel, []).append(i + 1)

if not discovered:
    fail("T4: discovery found ZERO claude -p spawn-sites — the scan pattern is broken.")

for rel, line_nos in sorted(uncovered_by_file.items()):
    allowed = ISOLATION_ALLOWLIST.get(rel)
    if allowed is None:
        fail(
            f"T4: naked claude -p spawn at {rel}:{line_nos[0]} carries NO channel-off "
            "path in its command span. A bridge-spawned disposable `claude -p` that "
            "inherits the agent's config-dir auto-loads the telegram/discord plugin and "
            "steals the admin's live poller. Add a channel-off path (singleton "
            "--settings overlay / SINGLETON_CHANNEL_SUPPRESSION_ARGS / --strict-mcp-config) "
            "at the spawn, or — if it fully isolates CLAUDE_CONFIG_DIR — register it in "
            "this guard's ISOLATION_ALLOWLIST."
        )
    if len(line_nos) > allowed:
        fail(
            f"T4: {rel} has {len(line_nos)} uncovered claude -p spawn(s) at lines "
            f"{line_nos} but only {allowed} is isolation-allowlisted. A new spawn here "
            "must carry its OWN channel-off path — it cannot ride the existing "
            "CLAUDE_CONFIG_DIR isolation."
        )
    if "CLAUDE_CONFIG_DIR" not in (repo / rel).read_text(encoding="utf-8", errors="replace"):
        fail(
            f"T4: {rel} is isolation-allowlisted but no longer sets an isolated "
            "CLAUDE_CONFIG_DIR — its disposable claude -p would inherit the live config."
        )

# T5 — the bash helper, the create-agent baked overlay, and the Python helper
# must all disable EXACTLY the canonical singletons and nothing else.
def parse_overlay(text, where):
    m = (
        re.search(r"--settings\s+'(\{.*?\})'", text)
        or re.search(r'--settings\s+"(\{.*?\})"', text)
        or re.search(r"SINGLETON_CHANNEL_SUPPRESSION_OVERLAY='(\{.*?\})'", text)
    )
    if not m:
        fail(f"T5: could not find a singleton-channel overlay literal in {where}")
    try:
        return json.loads(m.group(1))
    except json.JSONDecodeError as exc:
        fail(f"T5: overlay in {where} is not valid JSON: {exc}")


def assert_canonical(overlay, where):
    if set(overlay.keys()) != {"enabledPlugins"}:
        fail(f"T5: {where} overlay must touch only enabledPlugins, got {sorted(overlay)}")
    if overlay["enabledPlugins"] != CANON:
        fail(f"T5: {where} overlay {overlay['enabledPlugins']} != canonical {CANON}")


assert_canonical(json.loads(singleton_channel_suppression_overlay()), "lib/bridge_disposable_claude.py")
assert_canonical(
    parse_overlay(
        (repo / "runtime-templates/scripts/lib/singleton-channel-suppression.sh").read_text(encoding="utf-8"),
        "bash helper",
    ),
    "bash helper",
)
assert_canonical(
    parse_overlay(
        (repo / "runtime-templates/skills/agent-factory/scripts/create-agent.sh").read_text(encoding="utf-8"),
        "create-agent baked runner",
    ),
    "create-agent baked runner",
)

_uncovered = sum(len(v) for v in uncovered_by_file.values())
_files = sorted({rel for rel, _ in discovered})
print(
    "[smoke:17957-disposable-no-poller] T4: repo-wide spawn-occurrence scan — "
    f"{len(discovered)} spawn(s) across {len(_files)} file(s); "
    f"{len(discovered) - _uncovered} argv-covered, "
    f"{_uncovered} isolation-allowlisted. Files: " + ", ".join(_files)
)
print(
    "[smoke:17957-disposable-no-poller] T5: bash helper + create-agent baked overlay "
    "+ Python helper all disable exactly the singleton channels "
    + ", ".join(sorted(CANON))
)
PYEOF

assert_overlay() {
  local label="$1" dump="$2"
  python3 "$HELPERS/assert_overlay.py" "$dump" "$label"
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
WEEK="$(python3 "$HELPERS/mkweek.py" "$MEM_HOME")"
rm -f "$ARGV_DUMP"
python3 "$REPO_ROOT/bridge-memory.py" summarize weekly \
  --agent smoke-agent --home "$MEM_HOME" --week "$WEEK" --llm --json >/dev/null || true
smoke_assert_file_exists "$ARGV_DUMP" "T2: memory summarize weekly --llm did not spawn claude"
assert_overlay "T2 memory" "$ARGV_DUMP"

# --- T3: per-spawn source guard — no un-hardened `claude -p` slips back in --
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

# --- T4 (GLOBAL spawn-site scan) + T5 (DRY/sync) ---------------------------
python3 "$HELPERS/audit.py" "$REPO_ROOT"

smoke_log "PASS"
