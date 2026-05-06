#!/usr/bin/env python3
"""Codex companion-role PreToolUse hook: enforce read-only mode for [plan]/[review] tasks.

Behavior:
- Reads the currently claimed task for ``BRIDGE_AGENT_ID``
  (`status='claimed' AND claimed_by=<agent>`). Fails-open with audit if
  none / ambiguous / DB error.
- If the claimed task title carries a companion-role prefix (`[plan]` / `[review]`)
  AND the tool call is write-shaped (Edit / Write / NotebookEdit / Bash matching
  write-shaped patterns) AND the target path is not in `/tmp/` AND not covered
  by an `implement-permission: <path>` grant in the task body, the hook
  decides per ``BRIDGE_CODEX_TASK_MODE_POLICY``:
    - ``audit`` (default, unset, or any non-block value): emit audit, allow.
    - ``block``: emit audit, return ``decision=block`` with a structured reason.

The audit envelope reuses ``bridge_hook_common.write_audit`` (per-agent
``logs/agents/<agent>/audit.jsonl``). Actions are namespaced
``codex_task_mode_policy.*`` so ``agent-bridge audit`` filters cleanly.

This hook is fail-soft: any internal error short-circuits to allow + audit.
Codex CLIs predating PreToolUse simply ignore the hook entry.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sqlite3
import sys
from pathlib import Path
from typing import Any

from bridge_hook_common import bridge_task_db, write_audit


COMPANION_PREFIXES = ("plan", "review")
WRITE_SHAPED_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
# Bash commands whose first non-flag arg is the write target (rm /file,
# mkdir /dir, touch /file, etc). cp/mv/install/ln/dd are handled separately
# below because their destination is the LAST positional arg (cp/mv/install/
# ln) or the `of=path` keyword (dd). git/make/pip/npm/yarn are mixed-mode
# (read OR write depending on subcommand) — see _GIT_WRITE_SUBCOMMANDS and
# _git_write_target. `patch` is its own shape (the diff content names the
# write targets, not the args) — see _patch_write_target. For [review] tasks
# `git status|diff|show|log|grep|ls-files|rev-parse` must remain allowed even
# in block mode, otherwise the reviewer cannot do their job.
WRITE_SHAPED_BASH_TOKEN_HEADS = {
    "rm", "mkdir", "touch", "tee", "chmod", "chown",
}
# git subcommands that mutate the worktree, index, refs, or remote. First
# non-flag arg after `git` is matched against this set.
_GIT_WRITE_SUBCOMMANDS = {
    "add", "am", "apply", "branch", "checkout", "cherry-pick", "clean",
    "commit", "fetch", "merge", "mv", "pull", "push", "rebase", "reset",
    "restore", "revert", "rm", "stash", "switch", "tag",
}
# Bash redirection markers that imply a write target.
#
# Matches plain `>`, `>>`, `&>` (stderr+stdout to file), `>&` (dup-fd), and
# explicit fd redirections `1>`, `2>`, `1>>`, `2>>`, etc. The trailing
# `(?!=)` negative lookahead keeps test-shape comparisons (`>=`) and dup-fd
# completions (`>&2`) from being read as write targets — the latter still
# matches via the `>&` alternative which is left intact.
_REDIR_RE = re.compile(r"(?:(?:[0-9]+|&)?>>?(?!=)|>&)")
# Closed allowlist of git long flags that DO take a separate-token value.
# `git --no-pager checkout main` would otherwise have `--no-pager` swallow
# `checkout` and hide the mutating subcommand. Anything not in this set is
# assumed no-arg, including `--paginate`, `--bare`, `--literal-pathspecs`,
# `--noglob-pathspecs`, etc. The `--flag=value` form is independent: the
# `=` keeps the value within a single token, so the value never leaks into
# the next token and no allowlist check is needed there.
_GIT_VALUE_TAKING_LONG_FLAGS = frozenset(
    {"--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
)


def _read_event() -> dict[str, Any]:
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _mode() -> str:
    raw = (os.environ.get("BRIDGE_CODEX_TASK_MODE_POLICY") or "").strip().lower()
    return "block" if raw == "block" else "audit"


def _title_is_companion(title: str) -> bool:
    s = (title or "").strip().lower()
    if not s.startswith("["):
        return False
    end = s.find("]")
    if end <= 0:
        return False
    inner = s[1:end].strip()
    if not inner:
        return False
    head = inner.split(None, 1)[0]
    return head in COMPANION_PREFIXES


def _claimed_task(agent: str) -> dict[str, Any] | None:
    """Return the deterministic single claimed task for ``agent`` or None.

    Fails-open with audit on db_error and ambiguous claim. Ambiguity is
    audited so operators can see a silent disable of the policy.
    """
    db = bridge_task_db()
    if not db.exists():
        return None
    try:
        with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2.0) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """
                SELECT id, title, body_text, body_path
                FROM tasks
                WHERE status = 'claimed' AND claimed_by = ?
                ORDER BY claimed_ts DESC, id DESC
                LIMIT 2
                """,
                (agent,),
            ).fetchall()
    except sqlite3.Error as exc:
        write_audit(
            "codex_task_mode_policy.db_error",
            agent,
            {"stage": "claimed_task_lookup", "error": str(exc)[:200]},
        )
        return None
    if not rows:
        return None
    if len(rows) > 1:
        write_audit(
            "codex_task_mode_policy.ambiguous_claimed_task",
            agent,
            {
                "claimed_count": len(rows),
                "task_ids": [r["id"] for r in rows],
            },
        )
        return None
    row = rows[0]
    # body_text (inline) and body_path (file-backed) are alternatives in
    # current bridge-queue.py, but treat them as additive so a brief that
    # carries a structured grant in either surface is honored.
    parts: list[str] = []
    inline_text = row["body_text"]
    if isinstance(inline_text, str) and inline_text.strip():
        parts.append(inline_text)
    body_path_value = row["body_path"]
    if body_path_value:
        try:
            parts.append(Path(body_path_value).read_text(encoding="utf-8"))
        except OSError:
            pass
    body_combined = "\n".join(parts)
    return {"id": row["id"], "title": row["title"] or "", "body": body_combined}


def _parse_grants(body: str) -> list[Path]:
    """Extract structured `implement-permission: <path>` grants."""
    grants: list[Path] = []
    for line in (body or "").splitlines():
        stripped = line.strip()
        # Tolerate leading list markers (`-`, `*`) and bold markdown.
        for prefix in ("- ", "* ", "** "):
            if stripped.startswith(prefix):
                stripped = stripped[len(prefix):].strip()
                break
        lowered = stripped.lower()
        marker = "implement-permission:"
        idx = lowered.find(marker)
        if idx == -1:
            continue
        rest = stripped[idx + len(marker):].strip()
        if not rest:
            continue
        # Strip trailing punctuation/quotes.
        rest = rest.strip("`\"'")
        rest = rest.split()[0] if rest.split() else rest
        try:
            grants.append(Path(rest).expanduser().resolve(strict=False))
        except (OSError, RuntimeError):
            continue
    return grants


def _path_in(target: Path, root: Path) -> bool:
    try:
        target.resolve(strict=False).relative_to(root.resolve(strict=False))
        return True
    except (ValueError, OSError):
        return False


def _classify_write(tool_name: str, tool_input: dict[str, Any]) -> Path | None:
    """Return the resolved write target Path, or None if not write-shaped."""
    if tool_name in WRITE_SHAPED_TOOLS:
        for key in ("file_path", "filePath", "path", "notebook_path"):
            value = tool_input.get(key)
            if isinstance(value, str) and value:
                try:
                    return Path(value).expanduser().resolve(strict=False)
                except (OSError, RuntimeError):
                    return None
        return None
    if tool_name == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str) or not command:
            return None
        return _classify_bash_write(command)
    return None


# Commands whose destination is the LAST positional argument (cp src dst,
# mv src dst, install src dst, ln src dst). Source goes first; destination
# goes last. Naively returning the first non-flag arg would misclassify
# `cp /tmp/source /repo/dest` as a /tmp write and false-allow it.
_WRITE_HEADS_LAST_ARG_DEST = {"cp", "mv", "install", "ln"}


def _last_positional(tokens: list[str]) -> str | None:
    """Return the last token that is not a flag and not a known flag value."""
    # Iterate from the end and skip flag-shaped tokens. Flag values that
    # require a separated arg (e.g. `-t target_dir`) are not handled here;
    # for cp/mv this is a rare shape and false-negative fails-open via the
    # outer caller.
    for token in reversed(tokens):
        if token == "--":
            continue
        if token.startswith("-"):
            continue
        return token
    return None


def _dd_of_target(tokens: list[str]) -> str | None:
    for token in tokens:
        if token.startswith("of="):
            return token[3:]
    return None


def _target_directory_flag(tokens: list[str]) -> str | None:
    """Return the value of `-t <dest>` / `-tDEST` / `--target-directory=<dest>`.

    Used by cp / mv / install. When `-t` (or its long form) appears, the
    write target is the FLAG VALUE, not the last positional arg — those
    positionals are sources. `install -t /etc/systemd /tmp/foo.service` would
    otherwise be misclassified by `_last_positional` as a /tmp write and
    false-allowed.

    Three short-flag shapes for `-t`:
    - separated: `-t /etc/dest` (consume next token)
    - attached:  `-t/etc/dest` (value baked into the same token; common in
      GNU coreutils because POSIX `getopt` accepts it)
    - The `--target-directory` long form takes the value either as the next
      token or after `=` in the same token.

    Without the attached-form branch, `install -t/etc/systemd /tmp/foo` falls
    through to `_last_positional` and `/tmp/foo` is reported as the write
    target (false allow via the /tmp carve-out).
    """
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-t" and i + 1 < len(tokens):
            return tokens[i + 1]
        # `-tDEST` attached short form. Guard against `--target-directory`
        # (also starts with `-t`) by excluding any token that begins with
        # the long-flag prefix `--`.
        if tok.startswith("-t") and not tok.startswith("--") and len(tok) > 2:
            return tok[2:]
        if tok == "--target-directory" and i + 1 < len(tokens):
            return tokens[i + 1]
        if tok.startswith("--target-directory="):
            return tok[len("--target-directory="):]
        i += 1
    return None


def _patch_write_target(tokens: list[str]) -> str:
    """Return the resolved write target for `patch <args>`.

    `patch` reads a diff (from `-i FILE` or stdin) and applies it to files
    named *inside the diff* — the diff path is INPUT, not the write target.
    The conservative target is therefore the cwd. Honor `-o <output>` /
    `-oFILE` (attached short form) / `--output=<output>` because those
    redirect the patched result to a single named file instead of touching
    cwd; if it points at /tmp the outer carve-out will allow it.

    Without the attached-form branch, `patch -p1 -i /tmp/diff -o/etc/result`
    falls through to the cwd default; if cwd is the /tmp BRIDGE_HOME (or any
    /tmp-rooted scratch dir) the global carve-out then false-allows the
    write to /etc/result. Recognizing `-oFILE` here forces the explicit
    target to be classified.
    """
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-o" and i + 1 < len(tokens):
            return tokens[i + 1]
        # `-oFILE` attached short form. Exclude `--output*` long flags
        # (those start with `--`, which by definition does not match `-o`
        # alone — `--output` starts with `--`, not `-o`-as-short-flag — but
        # the explicit `not startswith("--")` guard makes the intent clear
        # and is robust against future flag additions like a hypothetical
        # `--o…` long flag).
        if tok.startswith("-o") and not tok.startswith("--") and len(tok) > 2:
            return tok[2:]
        if tok == "--output" and i + 1 < len(tokens):
            return tokens[i + 1]
        if tok.startswith("--output="):
            return tok[len("--output="):]
        i += 1
    return str(Path.cwd())


def _git_write_subcommand(tokens: list[str]) -> str | None:
    """Return the git write subcommand name if `git <args>` mutates state.

    Skips `git`-level flags (`-C path`, `-c key=val`, `--git-dir=...`, etc)
    until the first bare token, which is the subcommand. Returns None for
    read-only subcommands (status, diff, show, log, grep, ls-files,
    rev-parse, blame, ...) — those must stay allowed in block mode so a
    [review] task can actually inspect the tree.

    Long flags use a closed allowlist (``_GIT_VALUE_TAKING_LONG_FLAGS``):
    only those flags consume a following token as a value. Other long
    flags like ``--no-pager`` or ``--paginate`` are no-arg, so the next
    positional really is the subcommand and is classified normally.
    """
    short_value_for = {"-C", "-c"}
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "--":
            i += 1
            continue
        if tok in short_value_for:
            # `-C path` / `-c key=val` — consume flag + value pair.
            i += 2
            continue
        if tok.startswith("--"):
            # `--flag=value` keeps the value within the same token; no
            # following-token consumption needed.
            if "=" in tok:
                i += 1
                continue
            if tok in _GIT_VALUE_TAKING_LONG_FLAGS:
                i += 2
                continue
            # Unknown long flag: assume no-arg so the next positional is
            # still classified. This is conservative for our use case
            # (block-mode write detection): if a hostile invocation tried
            # to use a fabricated `--frobnicate value` long flag whose
            # value happened to be a write subcommand name, we would
            # block — fail-closed in block mode is the correct posture.
            i += 1
            continue
        if tok.startswith("-"):
            # Short single-dash flags other than `-C`/`-c`: assume no-arg.
            i += 1
            continue
        return tok if tok in _GIT_WRITE_SUBCOMMANDS else None
    return None


def _classify_bash_write(command: str) -> Path | None:
    """Best-effort: detect a write-shaped Bash command and its target.

    Borrows the conservative shape of ``hooks/tool-policy.py``: tokenize with
    shlex, look at the first token, then scan for a redirection target. The
    aim is to catch the obvious cases without stalling on shell complexity.
    Ambiguous parses fail-open (return None).
    """
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        return None
    if not tokens:
        return None

    head = tokens[0]
    target_str: str | None = None

    if head in _WRITE_HEADS_LAST_ARG_DEST:
        # cp / mv / install / ln — destination is the LAST positional arg in
        # the bare form, but `cp -t <dir> <src>...`, `mv -t <dir> <src>...`,
        # and `install -t <dir> <src>...` (also `--target-directory=<dir>`)
        # put the destination in a flag value. Check the flag form first so
        # `install -t /etc/systemd /tmp/foo.service` is classified as a
        # write to /etc/systemd, not /tmp/foo.service.
        target_str = _target_directory_flag(tokens[1:])
        if target_str is None:
            target_str = _last_positional(tokens[1:])
    elif head == "patch":
        # `patch` reads a diff and writes to files named in the diff. The
        # diff path itself (`-i FILE` or stdin) is INPUT, never the target.
        # The conservative target is cwd; `-o <out>` overrides to a single
        # named output file (which the /tmp carve-out can still allow).
        target_str = _patch_write_target(tokens[1:])
    elif head == "dd":
        # `dd if=/tmp/src of=/repo/dst` — destination is the of= keyword.
        target_str = _dd_of_target(tokens[1:])
    elif head == "git":
        # git is mixed-mode: status/diff/show/log/grep/ls-files/rev-parse
        # are read-only and must stay allowed; checkout/reset/clean/add/
        # commit/merge/rebase/stash/apply/... mutate the worktree or repo.
        # We don't know the precise target path for most write subcommands
        # (e.g. `git checkout -- foo` could affect any number of files), so
        # we report the cwd as the conservative write target. The hook is
        # advisory: the operator chose [review]+block, so a write-shaped
        # `git <verb>` should be denied with a clear reason rather than
        # guessed away.
        if _git_write_subcommand(tokens[1:]) is None:
            return None
        return Path.cwd().resolve(strict=False)
    elif head in WRITE_SHAPED_BASH_TOKEN_HEADS:
        # rm / mkdir / touch / tee / chmod / chown — first non-flag token
        # after the head is the conventional target.
        for token in tokens[1:]:
            if token.startswith("-"):
                continue
            if token == "--":
                continue
            target_str = token
            break

    if target_str:
        try:
            return Path(target_str).expanduser().resolve(strict=False)
        except (OSError, RuntimeError):
            return None

    # Detect output redirection markers (`>`, `>>`, `&>`, `>&`).
    for i, token in enumerate(tokens):
        if _REDIR_RE.fullmatch(token):
            if i + 1 < len(tokens):
                target = tokens[i + 1]
                try:
                    return Path(target).expanduser().resolve(strict=False)
                except (OSError, RuntimeError):
                    return None
        # Compound token like `>>file`.
        match = _REDIR_RE.match(token)
        if match and len(token) > len(match.group(0)):
            target = token[len(match.group(0)):]
            try:
                return Path(target).expanduser().resolve(strict=False)
            except (OSError, RuntimeError):
                return None
    return None


def _block_payload(task_title: str, write_target: Path, tool_name: str) -> dict[str, Any]:
    reason = (
        f"This task title (`{task_title.strip()}`) carries a companion-role "
        f"prefix (`[plan]` / `[review]`), which is read-only by contract. "
        f"Tool `{tool_name}` attempted to write to `{write_target}`. "
        f"Carve-outs: `/tmp/*` is always allowed; explicit "
        f"`implement-permission: <path>` grants in the task body are allowed. "
        f"To bypass, restate this as an implementation task, or add an "
        f"`implement-permission:` grant naming the target path in the body."
    )
    return {"decision": "block", "reason": reason}


def main() -> int:
    event = _read_event()
    agent = (os.environ.get("BRIDGE_AGENT_ID") or "").strip()
    if not agent:
        return 0  # no agent context, no policy

    mode = _mode()

    try:
        task = _claimed_task(agent)
    except Exception:  # noqa: BLE001 - hook must never crash the engine
        write_audit(
            "codex_task_mode_policy.error",
            agent,
            {"mode": mode, "stage": "claimed_task_lookup"},
        )
        return 0
    if task is None:
        return 0
    if not _title_is_companion(task["title"]):
        return 0

    tool_name = (
        event.get("tool_name")
        or event.get("toolName")
        or ""
    )
    tool_input = event.get("tool_input") or event.get("toolInput") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}

    try:
        write_target = _classify_write(tool_name, tool_input)
    except Exception:  # noqa: BLE001
        write_audit(
            "codex_task_mode_policy.error",
            agent,
            {"mode": mode, "stage": "classify_write", "tool": tool_name},
        )
        return 0
    if write_target is None:
        return 0  # not write-shaped, allow

    tmp_root = Path("/tmp").resolve(strict=False)
    if _path_in(write_target, tmp_root):
        return 0  # /tmp/ carve-out

    grants = _parse_grants(task["body"])
    if any(_path_in(write_target, g) for g in grants):
        return 0  # explicit structured grant

    detail = {
        "mode": mode,
        "task_id": task["id"],
        "task_title": task["title"],
        "tool": tool_name,
        "write_target": str(write_target),
        "would_block": True,
    }
    write_audit("codex_task_mode_policy.deny", agent, detail)

    if mode == "block":
        sys.stdout.write(json.dumps(_block_payload(task["title"], write_target, tool_name)))
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
