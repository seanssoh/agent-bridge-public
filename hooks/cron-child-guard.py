#!/usr/bin/env python3
"""PreToolUse containment guard for disposable cron children (#2029).

A disposable cron child spawned by ``bridge-cron-runner.py`` ``run_claude`` runs
``claude -p … --permission-mode bypassPermissions`` with ``cwd`` = the target
agent's workdir (which holds that agent's channel transport credentials, e.g.
``.telegram/.env`` / ``.discord/.env``) and no tool allow/deny restrictions. Two
abuse paths follow (#2029):

  1. **No-relay bypass / direct channel send** (higher severity — reached a
     human): the child has ``Bash`` + ``bypassPermissions`` and the token sits in
     its cwd, so it can read the token and POST to the chat transport directly,
     outside the no-direct-send relay. Observed live as a double-send to the
     operator (child posted directly AND the parent forwarded the followup).
  2. **Out-of-run queue mutation**: a child that drops ``BRIDGE_CRON_RUN_ID``
     from the queue CLI's subprocess env falls back to normal interactive
     behaviour and can claim/done/update OTHER agents' tasks.

This hook is injected ONLY into cron children, via the per-request
``--settings`` overlay the runner controls — never the agent's interactive
``.claude/settings.json`` and never operator-global ``~/.claude`` (cf. #1981).
It fires for ``Bash`` PreToolUse events; everything else passes through.

Why a hook (the issue verified these facts):
- A PreToolUse hook returning ``permissionDecision: "deny"`` is one of the few
  mechanisms that still fires under ``--permission-mode bypassPermissions`` —
  Claude Code runs PreToolUse hooks BEFORE the permission-prompt system, so the
  deny survives even when prompts are disabled. ``--disallowed-tools`` is both
  leaky (alternate binaries/interpreters) and weak under bypass.
- The hook process INHERITS the claude process env (which the runner sets, incl.
  ``BRIDGE_CRON_RUN_ID``). The model can strip env only from subprocesses IT
  spawns, NOT from the hook's own inherited env — so the hook is a
  non-child-strippable anchor for the cron-run identity. That is what makes the
  Tier-2 queue-scope check sound: it reads the TRUE run-id from its own env, not
  the (strippable) subprocess env the queue CLI sees.

HONEST RESIDUAL (not airtight): this is a STRING-MATCHING guard over the Bash
command text. It robustly mitigates the realistic prompt-injection / naive-
command class, but a determined obfuscator can still evade it (variable-built
paths, IP-literal endpoints, alternate interpreters, base64/compound commands,
a fresh script written then executed). On macOS "shared" isolation there is no
UID drop, so a child with arbitrary code execution cannot be airtight-contained
by ANY in-process hook — airtight containment needs OS-level isolation (UID
drop / sandbox), which exists on iso-v2 / Linux hosts but not macOS "shared".
Treat this as defense-in-depth for the common case, NOT a sandbox.

Contract (matches ``hooks/askuserquestion-ban.py`` / ``tool-policy.py``):
- read the PreToolUse JSON payload from stdin;
- if ``tool_name`` is not ``Bash``, exit 0 with no output (pass-through);
- on a denied command, print the structured deny JSON and exit 0 (NOT exit 2 —
  Claude Code ignores JSON output when a hook exits 2);
- never raise out: any unexpected error exits 0 (fail-open), exactly like the
  other standalone bridge hooks. A hook crash must never wedge a cron run.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
from pathlib import Path

# --- Tier 1: channel-credential read + direct channel send -----------------

# Canonical per-agent channel credential dirs (mirrors the
# `discord telegram teams ms365 mattermost` set in
# lib/bridge-isolation-v3-channel-dotenv.sh). A cron child reports via
# structured output and NEVER needs to read a transport cred file, so denying a
# Bash command that references one of these `.env` paths is behavior-conflict-
# free. Matched as a path SUBSTRING so `.telegram/.env`, `./.discord/.env`,
# `<workdir>/.teams/.env`, etc. all trip regardless of the absolute prefix.
_CHANNEL_CRED_PATH_RE = re.compile(
    r"\.(?:discord|telegram|teams|ms365|mattermost)/\.env\b"
)

# Direct chat-transport / managed-send call shapes a cron child must never run.
# Superset of bridge-cron-runner.py::DIRECT_SEND_MARKERS (the audit-only marker
# list) — kept here as the ENFORCING copy. Matched case-insensitively as
# substrings of the command text. These are the realistic naive shapes; the
# residual note above covers obfuscated variants.
_DIRECT_SEND_MARKERS = (
    "api.telegram.org",
    "discord.com/api/webhooks",
    "discordapp.com/api/webhooks",
    "tg_send",
    "telegram_send",
    "discord_send",
    "send-managed-message",
    "send_managed_message",
    "agb urgent",
    "agb send",
    "agent-bridge urgent",
    "agent-bridge send",
    "bridge-send.sh",
    "bridge-action.sh",
    "bridge-notify",
    "bridge-channels.py send",
    "bridge-discord-relay",
)

_CRED_REASON = (
    "Reading channel transport credentials is denied for cron children "
    "(#2029). A disposable cron job reports via its structured output; it never "
    "reads `.telegram/.env` / `.discord/.env` or any per-agent channel cred. "
    "If the result needs to reach a human, set needs_human_followup=true / "
    "delivery_intent in your structured result and let the relay deliver it."
)

_SEND_REASON = (
    "Direct channel sends are denied for cron children (#2029). A cron job must "
    "NOT call a chat transport API or a managed-send CLI directly — that "
    "bypasses the no-direct-send relay (observed: a duplicate message to a "
    "human). Report via your structured result with needs_human_followup / "
    "delivery_intent instead; the parent session delivers through the relay."
)

# --- Tier 2: in-run queue-scope enforcement --------------------------------

# Queue mutation verbs. A cron child may legitimately CREATE tasks (delegation)
# and create-bodies that merely quote `agb done …` are NOT mutations — so
# `create` is deliberately absent. `handoff` reassigns a task's owner/status
# (bridge-queue.py::cmd_handoff) so it IS a mutation of the target task and
# belongs here (#2029 codex r1 finding 2). It is deliberately Tier-2 (scope-
# checked), NOT a Tier-1 unconditional deny: handing off an IN-RUN task is a
# legitimate delegation pattern, exactly parallel to the `task create`
# delegation the issue allows — only a handoff of an OUT-OF-RUN task (another
# agent's) is denied. Only a claim/done/update/cancel/handoff that targets a
# task OUTSIDE this run's scope is denied.
_QUEUE_MUTATION_VERBS = frozenset(
    {"claim", "done", "update", "cancel", "handoff"}
)

# The argv entry points that reach the queue mutation verbs.
_QUEUE_ENTRYPOINT_BASENAMES = frozenset(
    {"agb", "agent-bridge", "bridge-task.sh", "bridge-queue.py"}
)

_SCOPE_REASON_TEMPLATE = (
    "Queue mutation outside this cron run's scope is denied (#2029). This run "
    "may only claim/done/update/cancel/handoff tasks it owns — i.e. origin "
    "`cron:{run_id}` or a body under `runs/{run_id}/`. Task #{task_id} is "
    "outside that scope. To hand work to another agent, use `task create` "
    "(delegation), which is allowed."
)


def _deny(reason: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
                "additionalContext": reason,
            }
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")


def _command_text(payload: dict) -> str:
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return ""
    command = tool_input.get("command")
    return command if isinstance(command, str) else ""


def _violates_channel_cred_read(command: str) -> bool:
    return bool(_CHANNEL_CRED_PATH_RE.search(command))


def _violates_direct_send(command: str) -> bool:
    lowered = command.lower()
    return any(marker in lowered for marker in _DIRECT_SEND_MARKERS)


# --- Tier 2 helpers --------------------------------------------------------


def _queue_db_path() -> Path | None:
    """Resolve the live task DB path the way bridge-queue.py does.

    Mirrors ``bridge-queue.py::get_db_path`` (BRIDGE_TASK_DB → BRIDGE_STATE_DIR
    → BRIDGE_HOME/state/tasks.db). Read-only: we never create or mutate. Returns
    None if no DB can be located, in which case the scope check FAILS OPEN (the
    child is no worse off than before this guard existed, and the Tier-1 denies
    still stand).
    """
    explicit = os.environ.get("BRIDGE_TASK_DB", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    state = os.environ.get("BRIDGE_STATE_DIR", "").strip()
    if state:
        return Path(state).expanduser() / "tasks.db"
    home = os.environ.get("BRIDGE_HOME", "").strip()
    if home:
        return Path(home).expanduser() / "state" / "tasks.db"
    return None


def _tokenize(command: str) -> list[str]:
    import shlex

    try:
        return shlex.split(command)
    except ValueError:
        # Unbalanced quotes etc. — fall back to whitespace split so an
        # obvious `agb done <id>` is still seen (fail-toward-detect for the
        # scope verbs; an unparseable command that ISN'T a queue mutation is
        # simply not matched below).
        return command.split()


def _queue_mutation_targets(command: str) -> list[int]:
    """Return the task ids a queue claim/done/update/cancel/handoff targets.

    Matches the REAL CLI argv shape, not body substrings: it requires a queue
    entry-point basename followed (possibly via the `task` group word) by a
    mutation verb, then collects the integer task-id operands. A `task create`
    whose body merely QUOTES `agb done 5` never reaches here because `create` is
    not a mutation verb and the quoted text is a single argv operand of
    `create`, not a fresh entry-point+verb pair.

    Conservative: only the FIRST entry-point→verb occurrence in the token stream
    is inspected. Compound commands (`&&`, `;`, pipes) that smuggle a second
    invocation are part of the documented residual, not silently allowed-by-
    design — Tier 1 already denies the high-severity send path, and the queue's
    own ``--from`` ownership check (#1792) remains the backstop.
    """
    tokens = _tokenize(command)
    n = len(tokens)
    for i, tok in enumerate(tokens):
        base = os.path.basename(tok)
        if base not in _QUEUE_ENTRYPOINT_BASENAMES:
            continue
        # Find the verb: skip an optional `task` group word and any flags
        # between the entry point and the verb.
        j = i + 1
        while j < n and (tokens[j] == "task" or tokens[j].startswith("-")):
            j += 1
        if j >= n or tokens[j] not in _QUEUE_MUTATION_VERBS:
            continue
        # Collect integer operands after the verb (the task id positional). The
        # queue mutation verbs (claim/done/update/cancel/handoff) all take the
        # task id as the ONLY bare positional; every option carries a value. So
        # we skip flags and their values, leaving the bare integer(s):
        #   - `--flag=value`  is self-contained (one token) → skip 1;
        #   - `--flag value`  is two tokens                  → skip 2.
        # The earlier `k += 2`-for-every-flag form wrongly consumed the task-id
        # positional after a `--flag=value` token (e.g. `done --note=x 9`),
        # silently letting an out-of-run `--flag=value` mutation through (#2029
        # codex r1 finding 1).
        ids: list[int] = []
        k = j + 1
        while k < n:
            t = tokens[k]
            if t.startswith("-"):
                if "=" in t:
                    k += 1  # `--flag=value`: value is in this same token.
                else:
                    k += 2  # `--flag value`: the value is the next token.
                continue
            if t.isdigit():
                ids.append(int(t))
            k += 1
        return ids
    return []


def _task_in_run_scope(db_path: Path, task_id: int, run_id: str) -> bool:
    """True iff task #task_id belongs to cron run `run_id`.

    In scope when origin == ``cron:<run_id>`` OR body_path is under
    ``runs/<run_id>/``. Read-only query. On ANY error (missing DB, missing
    column on a legacy row, task not found) returns True → FAIL OPEN, so this
    guard never false-denies a legitimate admin cron on a query glitch. The
    Tier-1 denies and the queue's own ``--from`` ownership check are unaffected.
    """
    try:
        uri = f"file:{db_path}?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=2.0) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT origin, body_path FROM tasks WHERE id = ?", (task_id,)
            ).fetchone()
    except sqlite3.Error:
        return True
    if row is None:
        # Task not found in this DB: not our place to deny a no-op/typo here;
        # the queue CLI will report "no such task". Fail open.
        return True
    try:
        origin = str(row["origin"] or "").strip()
    except (IndexError, KeyError):
        origin = ""
    try:
        body_path = str(row["body_path"] or "").strip()
    except (IndexError, KeyError):
        body_path = ""
    if origin == f"cron:{run_id}":
        return True
    # body_path under runs/<run_id>/ (the cron run's artifact dir).
    if f"runs/{run_id}/" in body_path.replace("\\", "/"):
        return True
    return False


def _violates_queue_scope(command: str) -> tuple[bool, int, str]:
    """Tier 2: is `command` an out-of-run queue mutation?

    Returns (violates, task_id, run_id). Fails open (False) whenever the run-id
    is absent or the DB cannot be resolved — Tier 2 only ADDS denials on top of
    a sound, available signal; it never blocks when its inputs are missing.
    """
    run_id = os.environ.get("BRIDGE_CRON_RUN_ID", "").strip()
    if not run_id:
        return (False, 0, "")
    targets = _queue_mutation_targets(command)
    if not targets:
        return (False, 0, run_id)
    db_path = _queue_db_path()
    if db_path is None:
        return (False, 0, run_id)
    for task_id in targets:
        if not _task_in_run_scope(db_path, task_id, run_id):
            return (True, task_id, run_id)
    return (False, 0, run_id)


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except (ValueError, TypeError):
        return 0
    if not isinstance(payload, dict):
        return 0
    if str(payload.get("tool_name") or "") != "Bash":
        return 0

    command = _command_text(payload)
    if not command:
        return 0

    # Tier 1 — channel-credential read.
    if _violates_channel_cred_read(command):
        _deny(_CRED_REASON)
        return 0

    # Tier 1 — direct channel send.
    if _violates_direct_send(command):
        _deny(_SEND_REASON)
        return 0

    # Tier 2 — out-of-run queue mutation.
    violates, task_id, run_id = _violates_queue_scope(command)
    if violates:
        _deny(_SCOPE_REASON_TEMPLATE.format(run_id=run_id, task_id=task_id))
        return 0

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 — a hook crash must never wedge a cron run; fail-open.
        sys.exit(0)
