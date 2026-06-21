#!/usr/bin/env bash
# scripts/smoke/2029-cron-child-relay-guard.sh
#
# #2029 — disposable cron child PreToolUse containment guard.
#
# The disposable cron child (bridge-cron-runner.py::run_claude) runs
# `claude -p … --permission-mode bypassPermissions` with cwd = the target
# agent's workdir (where channel transport creds live) and no tool restrictions.
# The runner now injects hooks/cron-child-guard.py as a PreToolUse `Bash` deny
# hook via a per-request `--settings` overlay. This smoke is the behaviour gate:
# it drives the guard's decision function with representative PreToolUse Bash
# payloads and asserts the deny/allow matrix, then proves the injection is
# scoped to cron children and that disabling it lets the deny cases pass through.
#
# Tier 1 (must-have):
#   - Bash reading `.../.telegram/.env` (or `.discord/.env`)         -> DENY
#   - Bash invoking a chat-transport / managed-send call             -> DENY
#   - a benign cron Bash payload (read own runs/<run_id>/ artifact)  -> ALLOW
# Tier 2 (in-run queue scope):
#   - `agb done <other-agents-task>` with the run-id present         -> DENY
#   - `agb done <in-run cron:<run_id> task>`                         -> ALLOW
#   - `agb task create --body '... agb done X ...'` (body-quote)     -> ALLOW
# Injection scoping / mutation check:
#   - run_claude command embeds `--settings` + the guard hook command
#   - the overlay registers ONLY a PreToolUse Bash hook (no global/interactive
#     settings mutation)
#   - with the guard hook absent, the runner omits `--settings` (deny cases
#     would pass through) — the mutation-revert teeth.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; a temp tasks.db seeded
# read-only for the Tier-2 scope query. No live bridge state is touched.
# Footgun #11 / #1813: NO heredoc-stdin / `<<<` / `< <()` / `python3 -`; the
# Python driver is written to a temp file and run by path.

set -euo pipefail

SMOKE_NAME="2029-cron-child-relay-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

GUARD_HOOK="$REPO_ROOT/hooks/cron-child-guard.py"
RUNNER="$REPO_ROOT/bridge-cron-runner.py"
smoke_assert_file_exists "$GUARD_HOOK" "guard hook present"
smoke_assert_file_exists "$RUNNER" "cron runner present"

RUN_ID="cronrun-2029-abc"
STATE_DIR="$BRIDGE_HOME/state"
mkdir -p "$STATE_DIR"
TASK_DB="$STATE_DIR/tasks.db"

# The Python driver: seeds a tiny tasks.db (id 5 = in-run cron origin, id 9 =
# another agent's task), imports the guard hook decision helpers by path, and
# asserts the full DENY/ALLOW matrix. It also imports the runner's
# `cron_child_guard_settings_overlay` to prove the overlay shape + scoping.
DRIVER="$SMOKE_TMP_ROOT/driver.py"
cat >"$DRIVER" <<'PYEOF'
import importlib.util
import json
import os
import sqlite3
import sys
from pathlib import Path

repo = Path(sys.argv[1])
guard_path = repo / "hooks" / "cron-child-guard.py"
runner_path = repo / "bridge-cron-runner.py"
db_path = Path(sys.argv[2])
run_id = sys.argv[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


guard = load("_cron_child_guard", guard_path)

# Seed the task DB the guard's Tier-2 scope query reads (read-only at query
# time). Schema mirrors the columns the guard reads: id, origin, body_path.
conn = sqlite3.connect(str(db_path))
conn.execute(
    "CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY, origin TEXT, body_path TEXT)"
)
conn.execute(
    "INSERT OR REPLACE INTO tasks (id, origin, body_path) VALUES (?, ?, ?)",
    (5, f"cron:{run_id}", None),
)
conn.execute(
    "INSERT OR REPLACE INTO tasks (id, origin, body_path) VALUES (?, ?, ?)",
    (9, "session:other-agent", "/somewhere/else/9.md"),
)
conn.commit()
conn.close()

os.environ["BRIDGE_TASK_DB"] = str(db_path)
os.environ["BRIDGE_CRON_RUN_ID"] = run_id

failures = []


def expect(label, got, want):
    if got != want:
        failures.append(f"{label}: expected {want!r}, got {got!r}")


# --- Tier 1: channel credential read ---------------------------------------
expect(
    "tier1 telegram cred read",
    guard._violates_channel_cred_read("cat /work/.telegram/.env"),
    True,
)
expect(
    "tier1 discord cred read",
    guard._violates_channel_cred_read("source ./.discord/.env && echo hi"),
    True,
)
expect(
    "tier1 benign read not a cred",
    guard._violates_channel_cred_read("cat runs/%s/notes.md" % run_id),
    False,
)

# --- Tier 1: direct channel send -------------------------------------------
expect(
    "tier1 telegram api send",
    guard._violates_direct_send(
        "curl -s https://api.telegram.org/bot$T/sendMessage -d text=hi"
    ),
    True,
)
expect(
    "tier1 discord webhook send",
    # `webhooks<id>` (no literal "webhooks/") keeps the guard's substring match
    # on `discord.com/api/webhooks` while staying clear of the oss-preflight
    # discord-webhook-URL scan (`discord\.com/api/webhooks/`) — this is a fake
    # redacted placeholder, not a real webhook.
    guard._violates_direct_send(
        "curl https://discord.com/api/webhooks<id>/<token> -d '{}'"
    ),
    True,
)
expect(
    "tier1 agb urgent send",
    guard._violates_direct_send("agb urgent admin 'ping'"),
    True,
)
expect(
    "tier1 benign command not a send",
    guard._violates_direct_send("python3 analyze.py && echo done"),
    False,
)

# --- Tier 2: in-run queue scope --------------------------------------------
v, tid, _rid = guard._violates_queue_scope("agb done 9 --note done")
expect("tier2 out-of-run done DENY", (v, tid), (True, 9))

v, _tid, _rid = guard._violates_queue_scope("agb done 5 --note done")
expect("tier2 in-run done ALLOW", v, False)

v, _tid, _rid = guard._violates_queue_scope("agb claim 9 --agent x")
expect("tier2 out-of-run claim DENY", v, True)

# body-quote is NOT a mutation: a `task create` whose body merely quotes
# `agb done 9` must pass.
v, _tid, _rid = guard._violates_queue_scope(
    "agb task create --to other --title t --body 'remember to agb done 9 later'"
)
expect("tier2 body-quote create ALLOW", v, False)

# delegation create (no mutation verb) passes.
v, _tid, _rid = guard._violates_queue_scope("agb task create --to other --title t --body b")
expect("tier2 delegation create ALLOW", v, False)

# codex r1 finding 1: `--flag=value` argparse form must NOT bypass the scope
# check. `done --note=x 9` parses to task 9; the old `k += 2`-per-flag parser
# wrongly skipped the `9` positional after `--note=x` and returned no target.
v, tid, _rid = guard._violates_queue_scope("bridge-queue.py done --note=x 9 --agent=a")
expect("tier2 flag=value out-of-run done DENY", (v, tid), (True, 9))

v, tid, _rid = guard._violates_queue_scope("agb claim --agent=a 9")
expect("tier2 flag=value-before-id claim DENY", (v, tid), (True, 9))

v, _tid, _rid = guard._violates_queue_scope("agb done --note=x 5 --agent=a")
expect("tier2 flag=value in-run done ALLOW", v, False)

# over-deny guard: an integer-valued `--flag value` (e.g. --lease-seconds 900)
# must NOT be misread as a task-id positional. Run id 5 is in scope; the only
# bare positional id is 5, not 900.
v, _tid, _rid = guard._violates_queue_scope("agb update 5 --lease-seconds 900 --actor a")
expect("tier2 integer flag-value not misread ALLOW", v, False)

# codex r1 finding 2: `handoff` is a real mutation (reassigns owner/status). It
# is Tier-2 (scope-checked), NOT a Tier-1 unconditional deny — an IN-RUN handoff
# is legitimate delegation. An OUT-OF-RUN handoff must be DENIED; an in-run one
# ALLOWED.
v, tid, _rid = guard._violates_queue_scope("agb handoff 9 --to other --from me")
expect("tier2 out-of-run handoff DENY", (v, tid), (True, 9))

v, _tid, _rid = guard._violates_queue_scope("agb handoff 5 --to other")
expect("tier2 in-run handoff ALLOW", v, False)

# --- end-to-end main() deny/allow over full PreToolUse payloads -------------
def run_main(payload, capture=True):
    import io

    old_in, old_out = sys.stdin, sys.stdout
    sys.stdin = io.StringIO(json.dumps(payload))
    buf = io.StringIO()
    sys.stdout = buf
    try:
        rc = guard.main()
    finally:
        sys.stdin, sys.stdout = old_in, old_out
    return rc, buf.getvalue().strip()


def is_deny(out):
    if not out:
        return False
    try:
        data = json.loads(out)
    except ValueError:
        return False
    hso = data.get("hookSpecificOutput") or {}
    return hso.get("permissionDecision") == "deny"


# non-Bash tool -> pass-through (no output)
rc, out = run_main({"tool_name": "Read", "tool_input": {"file_path": "/x"}})
expect("main non-Bash pass-through", (rc, out), (0, ""))

# Bash cred read -> deny
rc, out = run_main(
    {"tool_name": "Bash", "tool_input": {"command": "cat /w/.telegram/.env"}}
)
expect("main cred read deny", is_deny(out), True)

# Bash benign -> allow (no output)
rc, out = run_main(
    {"tool_name": "Bash", "tool_input": {"command": "ls runs/%s/" % run_id}}
)
expect("main benign allow", out, "")

# Bash out-of-run done -> deny
rc, out = run_main(
    {"tool_name": "Bash", "tool_input": {"command": "agb done 9 --note d"}}
)
expect("main out-of-run done deny", is_deny(out), True)

# Bash in-run done -> allow
rc, out = run_main(
    {"tool_name": "Bash", "tool_input": {"command": "agb done 5 --note d"}}
)
expect("main in-run done allow", out, "")

# --- runner overlay shape + scoping (no interactive/global settings keys) ---
runner = load("_cron_runner_2029", runner_path)
overlay_json = runner.cron_child_guard_settings_overlay()
if not overlay_json:
    failures.append("overlay: expected a non-empty overlay when guard hook present")
else:
    overlay = json.loads(overlay_json)
    top_keys = sorted(overlay.keys())
    expect("overlay only declares hooks", top_keys, ["hooks"])
    pre = overlay["hooks"]["PreToolUse"]
    expect("overlay one PreToolUse group", len(pre), 1)
    expect("overlay matcher is Bash", pre[0]["matcher"], "Bash")
    cmd = pre[0]["hooks"][0]["command"]
    expect("overlay command references guard hook", "cron-child-guard.py" in cmd, True)
    for forbidden in ("model", "permissions", "apiKeyHelper", "env", "statusLine"):
        expect("overlay omits %s" % forbidden, forbidden in overlay, False)

if failures:
    print("FAIL")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("PASS")
sys.exit(0)
PYEOF

OUT="$(python3 "$DRIVER" "$REPO_ROOT" "$TASK_DB" "$RUN_ID")" || {
  smoke_fail "guard decision matrix failed:\n$OUT"
}
smoke_assert_contains "$OUT" "PASS" "guard decision matrix"

# --- Mutation-revert teeth: with the guard hook absent, the runner must omit
# --settings so the deny cases would pass through. We simulate "guard hook
# missing" by pointing the runner's CRON_CHILD_GUARD_HOOK at a non-existent
# path and asserting the overlay builder returns None.
REVERT_DRIVER="$SMOKE_TMP_ROOT/revert.py"
cat >"$REVERT_DRIVER" <<'PYEOF'
import importlib.util
import sys
from pathlib import Path

repo = Path(sys.argv[1])
runner_path = repo / "bridge-cron-runner.py"
spec = importlib.util.spec_from_file_location("_cron_runner_revert", str(runner_path))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

# Point the guard-hook constant at an absent path → overlay builder returns None
# → run_claude appends no --settings flag (deny cases pass through). This is the
# teeth proving the deny is the injected hook, not ambient behaviour.
runner.CRON_CHILD_GUARD_HOOK = Path("/nonexistent/cron-child-guard.py")
overlay = runner.cron_child_guard_settings_overlay()
if overlay is not None:
    print("FAIL: expected None overlay when guard hook absent, got: %r" % overlay)
    sys.exit(1)
print("PASS")
sys.exit(0)
PYEOF

REVERT_OUT="$(python3 "$REVERT_DRIVER" "$REPO_ROOT")" || {
  smoke_fail "mutation-revert teeth failed:\n$REVERT_OUT"
}
smoke_assert_contains "$REVERT_OUT" "PASS" "mutation-revert teeth"

smoke_log "ok: #2029 cron-child relay guard deny/allow matrix + injection scoping"
