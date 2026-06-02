#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/8807-mcp-reaper-patterns.sh — incident #8807 P0b.
#
# The periodic MCP-orphan cleanup (process_mcp_orphan_cleanup →
# bridge-mcp-cleanup.py) already existed; the fork-storm incident happened
# because its DEFAULT_PATTERNS MISSED the bridge MCP types that piled up. P0b
# tightens the generic patterns to bridge-owned identities/paths and EXTENDS
# them to the missing bridge signatures, WITHOUT ever matching lethal
# collateral (Pencil.app `mcp-server-darwin-arm64`, desktop helpers, live
# `codex resume` agents). It also adds PID-reuse revalidation before each
# signal and moves the cleanup to the top of the daemon sync cycle.
#
# This smoke is CI-faithful and self-contained: it drives the pattern set +
# PID-reuse logic via the real bridge-mcp-cleanup.py module, and grep-pins the
# daemon ordering move. It spawns only short-lived /bin/sleep children with
# crafted argv (no tmux, no live agents) so it is safe to run in CI and
# locally.

set -euo pipefail

SMOKE_NAME="8807-mcp-reaper-patterns"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REAPER_PY="$SMOKE_REPO_ROOT/bridge-mcp-cleanup.py"
DAEMON_SH="$SMOKE_REPO_ROOT/bridge-daemon.sh"

smoke_log "A1: bridge-mcp-cleanup.py compiles"
python3 -c "import py_compile; py_compile.compile('$REAPER_PY', doraise=True)" || \
  smoke_fail "bridge-mcp-cleanup.py failed py_compile"

smoke_log "A2: bridge-daemon.sh is syntactically valid"
bash -n "$DAEMON_SH" || smoke_fail "bridge-daemon.sh failed bash -n"

# ---------------------------------------------------------------------------
# Pattern controls — positive (bridge MCP identities MUST match) + negative
# (lethal collateral MUST NOT match), driven against the REAL DEFAULT_PATTERNS.
# ---------------------------------------------------------------------------
smoke_log "B: DEFAULT_PATTERNS positive + negative control matrix"
python3 - "$REAPER_PY" <<'PY' || smoke_fail "DEFAULT_PATTERNS control matrix failed"
import ast, re, sys
src = open(sys.argv[1]).read()
tree = ast.parse(src)
patterns = None
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name) and t.id == "DEFAULT_PATTERNS":
                patterns = [ast.literal_eval(e) for e in node.value.elts]
assert patterns, "could not extract DEFAULT_PATTERNS"
pats = [re.compile(p) for p in patterns]
def hit(cmd): return any(p.search(cmd) for p in pats)

POSITIVE = [
    "npm exec @upstash/context7-mcp",
    "npm exec @playwright/mcp@latest",
    "npm exec @shopify/dev-mcp@latest",
    "node /Users/x/.npm/_npx/abc/node_modules/.bin/shopify-dev-mcp",
    "node /Users/x/.npm/_npx/abc/node_modules/@shopify/dev-mcp/dist/index.js",
    "node /Users/x/.claude/plugins/cache/cosmax-marketplace/cosmax-crm/0.19.3-3/scripts/crm-mcp-proxy.mjs",
    "node /home/u/.npm/_npx/abc/node_modules/.bin/context7-mcp",
    "bun /home/u/.agent-bridge/plugins/teams/server.ts",
    "bun run --cwd /home/u/.agent-bridge/plugins/telegram --silent start",
    "bun run --cwd /home/u/.bun/install/claude-plugins-official/telegram/0.0.6 start",
]
NEGATIVE = [
    # Lethal collateral on the live host — none are Agent Bridge MCP servers.
    "/Applications/Pencil.app/Contents/Resources/mcp-server-darwin-arm64 --stdio",
    "/usr/local/bin/mcp-server --port 9000",
    "/Applications/Telegram.app/Contents/MacOS/Telegram",
    "/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams",
    "/Applications/Figma.app/Contents/MacOS/Figma",
    # Bare interpreters / unrelated same-uid projects.
    "node /Users/x/code/myapp/index.js",
    "/home/u/.bun/bin/bun server.ts",
    "bun /Users/x/Projects/mywebapp/src/server.ts",
    "bun run --cwd /home/user/myproject build",
    # codex orphans are NOT reaped by the MCP cleaner.
    "codex resume 9f3a2b1c --cwd /home/agent",
    "codex exec --ephemeral --skip-git-repo-check -C crm-dev",
]
bad = []
for c in POSITIVE:
    if not hit(c):
        bad.append(("MISS positive", c))
for c in NEGATIVE:
    if hit(c):
        bad.append(("LETHAL negative", c))
if bad:
    for kind, c in bad:
        print(f"{kind}: {c}", file=sys.stderr)
    sys.exit(1)
print(f"[ok] {len(POSITIVE)} positive + {len(NEGATIVE)} negative controls correct")
PY

# ---------------------------------------------------------------------------
# PID-reuse revalidation — the kill path must refuse a pid whose live identity
# changed since classification.
# ---------------------------------------------------------------------------
smoke_log "C: PID-reuse revalidation (pre-TERM + pre-KILL guards)"
python3 - "$REAPER_PY" <<'PY' || smoke_fail "PID-reuse revalidation failed"
import importlib.util, re, subprocess, sys, time
spec = importlib.util.spec_from_file_location("bridge_mcp_cleanup", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

child = subprocess.Popen(["/bin/sleep", "30"])
try:
    for _ in range(50):
        if mod.read_proc_identity(child.pid) is not None:
            break
        time.sleep(0.05)
    ident = mod.read_proc_identity(child.pid)
    assert ident is not None, "could not read live child identity"
    cmd, ppid, age = ident
    sp = re.compile(r"sleep")
    assert mod.still_killable(child.pid, cmd, sp, ppid, 0), "exact identity must be killable"
    assert not mod.still_killable(child.pid, cmd, re.compile("nomatch"), ppid, 0), "pattern-mismatch must refuse"
    assert not mod.still_killable(child.pid, "different", sp, ppid, 0), "command-change must refuse"
    assert not mod.still_killable(child.pid, cmd, sp, ppid + 99999, 0), "ppid-change must refuse"
    assert not mod.still_killable(child.pid, cmd, sp, ppid, age + 100000), "younger-than-snapshot must refuse"
    child.terminate(); child.wait()
    ok, status = mod.kill_pid(child.pid, 0.2, cmd, sp, ppid, 0)
    assert ok and status == "skipped-pid-reuse", f"vanished pid must skip, got ({ok},{status})"
    print("[ok] PID-reuse revalidation enforced")
finally:
    if child.poll() is None:
        child.kill(); child.wait()
PY

# ---------------------------------------------------------------------------
# Runtime control: a Pencil.app-style mcp-server name survives a real
# default-pattern --kill, while a bridge crm-mcp-proxy orphan is reaped; the
# dry-run kills nothing.
# ---------------------------------------------------------------------------
smoke_log "D: runtime default-pattern kill — Pencil.app survives, bridge orphan reaped, dry-run kills none"
TMP_D="$(mktemp -d "${TMPDIR:-/tmp}/agb-8807p0b-XXXXXX")"
neg_argv="/Applications/Pencil.app/Contents/Resources/mcp-server-darwin-arm64-smoke-$$"
pos_argv="node /tmp/agent-bridge-8807-smoke-$$/crm-mcp-proxy.mjs"
spawn_argv() {
  python3 - "$1" "$2" <<'PY'
import subprocess, sys
from pathlib import Path
argv0, pid_file = sys.argv[1], sys.argv[2]
proc = subprocess.Popen([argv0, "600"], executable="/bin/sleep",
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        start_new_session=True)
Path(pid_file).write_text(str(proc.pid), encoding="utf-8")
PY
}
spawn_argv "$neg_argv" "$TMP_D/neg.pid"
spawn_argv "$pos_argv" "$TMP_D/pos.pid"
neg_pid="$(cat "$TMP_D/neg.pid")"
pos_pid="$(cat "$TMP_D/pos.pid")"
cleanup_d() {
  kill "$neg_pid" >/dev/null 2>&1 || true
  kill "$pos_pid" >/dev/null 2>&1 || true
  rm -rf "$TMP_D"
}
trap cleanup_d EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$neg_pid" 2>/dev/null && kill -0 "$pos_pid" 2>/dev/null && break
  sleep 0.1
done
kill -0 "$neg_pid" 2>/dev/null || smoke_fail "negative-control process did not start"
kill -0 "$pos_pid" 2>/dev/null || smoke_fail "positive-control process did not start"

dry_json="$(python3 "$REAPER_PY" cleanup --dry-run --min-age 0 --json)"
printf '%s' "$dry_json" | grep -q '"killed_count": 0' || smoke_fail "dry-run reported a non-zero killed_count"
kill -0 "$pos_pid" 2>/dev/null || smoke_fail "dry-run killed the positive control (must audit-only)"

python3 "$REAPER_PY" cleanup --kill --min-age 0 --json >/dev/null
sleep 0.4
kill -0 "$neg_pid" 2>/dev/null || smoke_fail "default cleanup killed the Pencil.app-style process (lethal collateral!)"
if kill -0 "$pos_pid" 2>/dev/null; then
  smoke_fail "default cleanup did NOT reap the bridge crm-mcp-proxy orphan"
fi

# ---------------------------------------------------------------------------
# Pressure-relief ordering: the cleanup must run at the TOP of cmd_sync_cycle
# (before the spawn-heavy surfaces), not after them.
# ---------------------------------------------------------------------------
smoke_log "E: MCP cleanup runs early in cmd_sync_cycle (before spawn surfaces)"
grep -q 'BRIDGE_DAEMON_LAST_STEP="mcp_orphan_cleanup_early"' "$DAEMON_SH" || \
  smoke_fail "daemon does not run the MCP cleanup early (mcp_orphan_cleanup_early step missing)"
# Exactly one in-cycle invocation (the early one) — the late call was removed.
inv="$(grep -c '( process_mcp_orphan_cleanup ) || true' "$DAEMON_SH")"
[[ "$inv" -eq 1 ]] || smoke_fail "expected exactly 1 process_mcp_orphan_cleanup invocation, found $inv"
# The early step must precede the cron-dispatch + on-demand spawn steps.
early_ln="$(grep -n 'BRIDGE_DAEMON_LAST_STEP="mcp_orphan_cleanup_early"' "$DAEMON_SH" | head -n1 | cut -d: -f1)"
cron_ln="$(grep -n 'BRIDGE_DAEMON_LAST_STEP="cron_dispatch_workers"' "$DAEMON_SH" | head -n1 | cut -d: -f1)"
ondemand_ln="$(grep -n 'BRIDGE_DAEMON_LAST_STEP="on_demand_agents"' "$DAEMON_SH" | head -n1 | cut -d: -f1)"
[[ -n "$early_ln" && -n "$cron_ln" && -n "$ondemand_ln" ]] || smoke_fail "could not locate cycle step markers"
(( early_ln < cron_ln )) || smoke_fail "MCP cleanup not before cron_dispatch_workers"
(( early_ln < ondemand_ln )) || smoke_fail "MCP cleanup not before on_demand_agents"

neg_pid=""; pos_pid=""
smoke_log "PASS: $SMOKE_NAME"
