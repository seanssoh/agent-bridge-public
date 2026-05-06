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

Bash classification (issue #639 redesign - Option C):
- Default-deny block-mode allow-list of read-only command shapes (git read-only
  verbs, ls/cat/head/tail/grep/find/wc/python -c read-only AST, etc).
- Common-shape write-target extractor for the closed write-shape verb set
  (rm/cp/mv/install/touch/sed -i/chmod/chown/dd/mkdir/rmdir/tee/patch/git
  mutating verbs/redirection writes).
- Grant grammar: legacy `implement-permission: <path>` plus proposed
  `[grants] write: <path-or-shape>` and `shell: <exact command>` lines.
- PR #636 r1-r5 fixes preserved (fd redirection, git long-flag mutating
  subcommands, patch -i / install -t target rules, attached -tDEST/-oFILE,
  combined-cluster -rt).

The audit envelope reuses ``bridge_hook_common.write_audit`` (per-agent
``logs/agents/<agent>/audit.jsonl``). Actions are namespaced
``codex_task_mode_policy.*`` so ``agent-bridge audit`` filters cleanly.

This hook is fail-soft: any internal error short-circuits to allow + audit.
Codex CLIs predating PreToolUse simply ignore the hook entry.
"""

from __future__ import annotations

import ast
import json
import os
import re
import sqlite3
import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any

from bridge_hook_common import bridge_task_db, write_audit


COMPANION_PREFIXES = ("plan", "review")
WRITE_SHAPED_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}

# Bash redirection markers that imply a write target.
#
# Matches plain `>`, `>>`, `&>` (stderr+stdout to file), `>&` (dup-fd), and
# explicit fd redirections `1>`, `2>`, `1>>`, `2>>`, etc. The trailing
# `(?!=)` negative lookahead keeps test-shape comparisons (`>=`) and dup-fd
# completions (`>&2`) from being read as write targets.
_REDIR_RE = re.compile(r"(?:(?:[0-9]+|&)?>>?(?!=)|>&)")

# Closed allowlist of git long flags that DO take a separate-token value.
_GIT_VALUE_TAKING_LONG_FLAGS = frozenset(
    {"--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
)

# git subcommands that mutate the worktree, index, refs, or remote.
_GIT_WRITE_SUBCOMMANDS = {
    "add", "am", "apply", "branch", "checkout", "cherry-pick", "clean",
    "commit", "fetch", "merge", "mv", "pull", "push", "rebase", "reset",
    "restore", "revert", "rm", "stash", "switch", "tag",
}

# Closed read-only allow-list (block-mode default-deny boundary).
_READ_ONLY_HEADS = frozenset({
    "git", "pwd", "ls", "cat", "head", "tail", "wc", "stat", "file", "du",
    "rg", "grep", "find", "python", "python3", "echo", "printf", "true",
    "false", "test", "[",
})

# Common-shape write commands.
_WRITE_HEADS_FIRST_POS = {"rm", "touch", "tee", "chmod", "chown", "mkdir",
                          "rmdir", "truncate"}
_WRITE_HEADS_LAST_ARG_DEST = {"cp", "mv", "install", "ln"}

# git read-only subcommands.
_GIT_READ_ONLY_SUBCOMMANDS = frozenset({
    "status", "diff", "log", "show", "grep", "ls-files", "rev-parse",
    "blame", "config", "describe", "for-each-ref", "ls-tree", "cat-file",
    "name-rev", "remote", "shortlog", "symbolic-ref",
})

# Recursion depth limit for `exec` / `bash -c` / `sh -c` unwrap.
_MAX_RECURSION_DEPTH = 4

# Python AST node names that indicate a write/effectful operation.
_PYTHON_WRITE_NAMES = frozenset({
    "open", "exec", "eval", "compile", "__import__",
})
_PYTHON_WRITE_ATTRS = frozenset({
    "write", "writelines", "write_text", "write_bytes", "remove", "rmtree",
    "system", "rename", "replace", "mkdir", "rmdir", "chmod", "chown",
    "touch", "unlink", "popen", "spawn", "spawnl", "spawnv", "fork",
    "execv", "execvp", "putenv",
})


class ShellClass(Enum):
    """Classification verdict for a Bash command line."""

    ALLOW_READONLY = "allow_readonly"
    WRITE_KNOWN = "write_known"
    UNKNOWN_SHELL = "unknown_shell"
    DENY_POLICY = "deny_policy"


@dataclass
class WriteTarget:
    """A single resolved write target."""

    path: Path | None
    raw: str
    reason: str = ""


@dataclass
class ShellVerdict:
    """Result of classifying a shell command line."""

    cls: ShellClass
    command: str
    targets: list[WriteTarget] = field(default_factory=list)
    head: str | None = None
    reason: str = ""


@dataclass
class Grant:
    """A parsed task-body grant.

    ``head_required`` is set for shape grants (`write: rm /path`) so the
    grant only matches when the runtime command's head equals this value.
    Plain path grants leave it None.
    """

    kind: str  # "path", "write", "shell"
    raw: str
    path: Path | None = None
    command: str | None = None
    head_required: str | None = None


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
    """Return the deterministic single claimed task for ``agent`` or None."""
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


# ----------------------------------------------------------------------------
# Grant grammar
# ----------------------------------------------------------------------------

_GRANT_EXPAND_NAMES = ("WORKDIR", "PWD", "TMPDIR")
_GRANT_VAR_RE = re.compile(r"\$(\{)?([A-Z_][A-Z0-9_]*)(\})?")


def _expand_grant_path(raw: str) -> str | None:
    """Expand a closed set of env vars in a grant path string."""

    def _resolve(match: re.Match[str]) -> str:
        name = match.group(2)
        if name not in _GRANT_EXPAND_NAMES:
            raise KeyError(name)
        if name == "WORKDIR":
            return os.environ.get("WORKDIR") or str(Path.cwd())
        return os.environ.get(name, "")

    try:
        return _GRANT_VAR_RE.sub(_resolve, raw)
    except KeyError:
        return None


def _strip_markdown_prefix(stripped: str) -> str:
    for prefix in ("- ", "* ", "** "):
        if stripped.startswith(prefix):
            return stripped[len(prefix):].strip()
    return stripped


def _parse_path_token(token: str) -> Path | None:
    token = token.strip("`\"'")
    if not token:
        return None
    expanded = _expand_grant_path(token)
    if expanded is None:
        return None
    try:
        return Path(expanded).expanduser().resolve(strict=False)
    except (OSError, RuntimeError):
        return None


def _parse_grants(body: str) -> list[Grant]:
    """Extract structured grants from a task body."""
    grants: list[Grant] = []
    for line in (body or "").splitlines():
        stripped = _strip_markdown_prefix(line.strip())
        if not stripped:
            continue
        lowered = stripped.lower()

        # 1) Legacy implement-permission: <path>
        marker = "implement-permission:"
        idx = lowered.find(marker)
        if idx != -1:
            rest = stripped[idx + len(marker):].strip()
            if not rest:
                continue
            first = rest.split()[0] if rest.split() else rest
            path = _parse_path_token(first)
            if path is not None:
                grants.append(Grant(kind="path", raw=stripped, path=path))
            continue

        # 2) write: <path-or-shape>
        if lowered.startswith("write:"):
            rest = stripped[len("write:"):].strip()
            if not rest:
                continue
            head = rest.split()[0] if rest.split() else ""
            if head in (
                _WRITE_HEADS_FIRST_POS
                | _WRITE_HEADS_LAST_ARG_DEST
                | {"sed", "patch", "dd", "git"}
            ):
                shape_verdict = _classify_bash_command(rest, depth=0)
                if shape_verdict.cls == ShellClass.WRITE_KNOWN:
                    for target in shape_verdict.targets:
                        if target.path is None:
                            continue
                        grants.append(Grant(
                            kind="write", raw=stripped, path=target.path,
                            command=rest, head_required=head,
                        ))
                continue
            path = _parse_path_token(head)
            if path is not None:
                grants.append(Grant(kind="write", raw=stripped, path=path))
            continue

        # 3) shell: <exact command>
        if lowered.startswith("shell:"):
            cmd = stripped[len("shell:"):].strip()
            if cmd:
                grants.append(Grant(kind="shell", raw=stripped, command=cmd))
            continue

    return grants


def _path_in(target: Path, root: Path) -> bool:
    try:
        target.resolve(strict=False).relative_to(root.resolve(strict=False))
        return True
    except (ValueError, OSError):
        return False


def _normalize_command_for_match(cmd: str) -> str:
    """Normalize whitespace for `shell:` exact-grant comparison."""
    return " ".join(cmd.strip().split())


def _match_bash_write_grants(verdict: "ShellVerdict", grants: list[Grant]) -> bool:
    """Check whether ``verdict`` is covered by any grant in ``grants``."""
    cmd_norm = _normalize_command_for_match(verdict.command)
    has_resolved_targets = bool(verdict.targets) and all(
        t.path is not None for t in verdict.targets
    )
    for grant in grants:
        if grant.kind == "shell" and grant.command is not None:
            if cmd_norm == _normalize_command_for_match(grant.command):
                return True
        if grant.kind in {"path", "write"} and grant.path is not None and has_resolved_targets:
            # Shape grants (head_required set) only match when the runtime
            # command's head equals the grant's head. This prevents
            # `write: rm /path` from authorizing `cp .. /path`.
            if grant.head_required is not None and verdict.head != grant.head_required:
                continue
            if all(_path_in(t.path, grant.path) for t in verdict.targets if t.path is not None):
                return True
    return False


# ----------------------------------------------------------------------------
# Shell scanner
# ----------------------------------------------------------------------------


class ShellScanError(Exception):
    """Raised when a shell command has unsupported / unparseable syntax."""


@dataclass
class _ShellWord:
    """A single shell-level word with metadata."""

    text: str
    has_substitution: bool = False
    quoted: bool = False
    redir_op: str = ""
    redir_attached_target: str = ""
    is_heredoc: bool = False


def _read_quoted_word(s: str, start: int) -> tuple[str, int]:
    """Read one shell word starting at ``start``, honoring quotes/escapes."""
    n = len(s)
    out: list[str] = []
    i = start
    while i < n:
        c = s[i]
        if c in (" ", "\t", "\n", ";", "|", "&", "<", ">"):
            break
        if c == "'":
            j = i + 1
            while j < n and s[j] != "'":
                j += 1
            out.append(s[i + 1:j])
            i = j + 1 if j < n else j
            continue
        if c == '"':
            j = i + 1
            buf: list[str] = []
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n and s[j + 1] in ('"', "\\", "$", "`", "\n"):
                    buf.append(s[j + 1])
                    j += 2
                    continue
                buf.append(s[j])
                j += 1
            out.append("".join(buf))
            i = j + 1 if j < n else j
            continue
        if c == "\\" and i + 1 < n:
            out.append(s[i + 1])
            i += 2
            continue
        if c == "$" and i + 1 < n and s[i + 1] == "(":
            break
        if c == "`":
            break
        out.append(c)
        i += 1
    return "".join(out), i


def _read_word_with_substitution(s: str, start: int) -> tuple[str, int, bool]:
    """Read a word that begins with `$(`/`<(`/`>(`, balancing parens."""
    n = len(s)
    depth = 0
    i = start
    out: list[str] = []
    while i < n:
        c = s[i]
        if c in ("$", "<", ">") and i + 1 < n and s[i + 1] == "(":
            out.append(s[i:i + 2])
            i += 2
            depth += 1
            continue
        if c == "(" and depth > 0:
            out.append(c)
            i += 1
            depth += 1
            continue
        if c == ")":
            out.append(c)
            i += 1
            depth -= 1
            if depth == 0:
                while i < n and s[i] not in (" ", "\t", "\n", ";", "|", "&", "<", ">"):
                    out.append(s[i])
                    i += 1
                return "".join(out), i, True
            continue
        if c == "'":
            j = i + 1
            while j < n and s[j] != "'":
                j += 1
            out.append(s[i:j + 1])
            i = j + 1 if j < n else j
            continue
        if c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                j += 1
            out.append(s[i:j + 1])
            i = j + 1 if j < n else j
            continue
        out.append(c)
        i += 1
    return "".join(out), i, True


def _scan_shell_words(command: str) -> list[_ShellWord]:
    """Tokenize a shell command line into words, preserving structure."""
    words: list[_ShellWord] = []
    n = len(command)
    i = 0

    while i < n:
        c = command[i]

        if c in (" ", "\t"):
            i += 1
            continue

        if c == "\n":
            words.append(_ShellWord(text="\n"))
            i += 1
            continue

        if command.startswith("&&", i):
            words.append(_ShellWord(text="&&"))
            i += 2
            continue
        if command.startswith("||", i):
            words.append(_ShellWord(text="||"))
            i += 2
            continue
        if c == ";":
            words.append(_ShellWord(text=";"))
            i += 1
            continue
        if c == "|":
            words.append(_ShellWord(text="|"))
            i += 1
            continue

        # Heredoc marker
        if command.startswith("<<", i):
            j = i + 2
            if j < n and command[j] == "-":
                j += 1
            while j < n and command[j] in (" ", "\t"):
                j += 1
            mark_start = j
            if j < n and command[j] in ("'", '"'):
                quote = command[j]
                j += 1
                while j < n and command[j] != quote:
                    j += 1
                if j < n:
                    j += 1
            else:
                while j < n and command[j] not in (" ", "\t", "\n", ";", "&", "|", "<", ">"):
                    j += 1
            words.append(_ShellWord(
                text=command[i:j] if j > mark_start else "<<",
                redir_op="<<",
                is_heredoc=True,
            ))
            i = j
            continue

        # Output redirections
        redir_match = _REDIR_RE.match(command, i)
        if redir_match:
            op = redir_match.group(0)
            j = i + len(op)
            attached = ""
            if j < n and command[j] not in (" ", "\t", "\n", ";", "&", "|", "<", ">"):
                attached, j = _read_quoted_word(command, j)
            words.append(_ShellWord(
                text=op + attached,
                redir_op=op,
                redir_attached_target=attached,
            ))
            i = j
            continue

        # Input redirection `<`
        if c == "<":
            j = i + 1
            attached = ""
            if j < n and command[j] not in (" ", "\t", "\n", ";", "&", "|", "<", ">"):
                attached, j = _read_quoted_word(command, j)
            words.append(_ShellWord(
                text="<" + attached,
                redir_op="<",
                redir_attached_target=attached,
            ))
            i = j
            continue

        # Substitution
        if (
            command.startswith("$(", i)
            or command.startswith("<(", i)
            or command.startswith(">(", i)
        ):
            text, j, _has_sub = _read_word_with_substitution(command, i)
            words.append(_ShellWord(text=text, has_substitution=True))
            i = j
            continue

        # Backtick substitution
        if c == "`":
            j = i + 1
            while j < n and command[j] != "`":
                if command[j] == "\\" and j + 1 < n:
                    j += 2
                    continue
                j += 1
            if j < n:
                j += 1
            words.append(_ShellWord(text=command[i:j], has_substitution=True))
            i = j
            continue

        # Regular word
        word_text, j = _read_quoted_word(command, i)
        has_sub = "$(" in word_text or "`" in word_text
        words.append(_ShellWord(
            text=word_text,
            has_substitution=has_sub,
            quoted=("'" in command[i:j] or '"' in command[i:j]),
        ))
        i = j

    return words


@dataclass
class _SimpleCommand:
    """One simple command (head + args + redirections)."""

    raw: str
    argv: list[str]
    redirections: list[_ShellWord]
    has_substitution: bool
    has_heredoc: bool


def _split_simple_commands(words: list[_ShellWord]) -> list[_SimpleCommand]:
    """Split a flat shell-word list into per-simple-command groups."""
    commands: list[_SimpleCommand] = []
    current: list[_ShellWord] = []
    raw_parts: list[str] = []

    def flush() -> None:
        if not current:
            return
        argv: list[str] = []
        redirs: list[_ShellWord] = []
        has_sub = False
        has_hd = False
        i = 0
        while i < len(current):
            w = current[i]
            if w.has_substitution:
                has_sub = True
            if w.is_heredoc:
                has_hd = True
                redirs.append(w)
                i += 1
                continue
            if w.redir_op:
                redirs.append(w)
                if not w.redir_attached_target and i + 1 < len(current):
                    nxt = current[i + 1]
                    redirs.append(nxt)
                    i += 2
                    continue
                i += 1
                continue
            argv.append(w.text)
            i += 1
        commands.append(_SimpleCommand(
            raw=" ".join(raw_parts).strip(),
            argv=argv,
            redirections=redirs,
            has_substitution=has_sub,
            has_heredoc=has_hd,
        ))

    for w in words:
        if w.text in (";", "&&", "||", "|", "\n"):
            flush()
            current = []
            raw_parts = []
            continue
        current.append(w)
        raw_parts.append(w.text)
    flush()
    return commands


# ----------------------------------------------------------------------------
# Common-shape write-target extractors (preserving PR #636 r1-r5 fixes)
# ----------------------------------------------------------------------------


def _resolve_path_str(raw: str) -> Path | None:
    if not raw:
        return None
    try:
        return Path(raw).expanduser().resolve(strict=False)
    except (OSError, RuntimeError):
        return None


def _last_positional(tokens: list[str]) -> str | None:
    """Return the last token that is not a flag and not a known flag value."""
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
    """Return value of `-t <dest>` / `-tDEST` / `--target-directory=<dest>`.

    Preserves PR #636 r3-r5 fixes:
    - separated `-t /etc/dest`
    - attached `-t/etc/dest`
    - long form `--target-directory[=<dest>]`
    - combined cluster `-rt /etc/dest` / `-rvt /etc/dest` / `-rt/etc/dest`
    """
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-t" and i + 1 < len(tokens):
            return tokens[i + 1]
        if tok.startswith("-t") and not tok.startswith("--") and len(tok) > 2:
            return tok[2:]
        if tok == "--target-directory" and i + 1 < len(tokens):
            return tokens[i + 1]
        if tok.startswith("--target-directory="):
            return tok[len("--target-directory="):]
        if (
            tok.startswith("-")
            and not tok.startswith("--")
            and len(tok) > 2
            and "t" in tok[1:]
        ):
            t_idx = tok.index("t", 1)
            if t_idx == len(tok) - 1:
                if i + 1 < len(tokens):
                    return tokens[i + 1]
            else:
                return tok[t_idx + 1:]
        i += 1
    return None


def _patch_write_target(tokens: list[str]) -> str:
    """Return the resolved write target for `patch <args>`.

    Preserves PR #636 r3-r4 fixes: `-i FILE` is INPUT; `-o FILE` / `-oFILE` /
    `--output[=FILE]` names output; otherwise cwd.
    """
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-o" and i + 1 < len(tokens):
            return tokens[i + 1]
        if tok.startswith("-o") and not tok.startswith("--") and len(tok) > 2:
            return tok[2:]
        if tok == "--output" and i + 1 < len(tokens):
            return tokens[i + 1]
        if tok.startswith("--output="):
            return tok[len("--output="):]
        i += 1
    return str(Path.cwd())


def _git_subcommand(tokens: list[str]) -> tuple[str | None, bool]:
    """Return (subcommand-name, is_write).

    Preserves PR #636 r1-r2 fixes: closed allowlist of value-taking long
    flags; unknown long flags assumed no-arg.
    """
    short_value_for = {"-C", "-c"}
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok == "--":
            i += 1
            continue
        if tok in short_value_for:
            i += 2
            continue
        if tok.startswith("--"):
            if "=" in tok:
                i += 1
                continue
            if tok in _GIT_VALUE_TAKING_LONG_FLAGS:
                i += 2
                continue
            i += 1
            continue
        if tok.startswith("-"):
            i += 1
            continue
        if tok in _GIT_WRITE_SUBCOMMANDS:
            return (tok, True)
        if tok in _GIT_READ_ONLY_SUBCOMMANDS:
            return (tok, False)
        return (tok, False)
    return (None, False)


def _sed_is_in_place(args: list[str]) -> bool:
    """Detect `sed -i` / `-iSUFFIX` / `--in-place[=suffix]`."""
    for tok in args:
        if tok == "-i" or tok == "--in-place":
            return True
        if tok.startswith("-i") and not tok.startswith("--") and len(tok) > 1:
            return True
        if tok.startswith("--in-place="):
            return True
    return False


def _sed_file_operands(args: list[str]) -> list[str]:
    """Extract file operand(s) for `sed -i ... <files>`.

    Heuristic: skip flags, the script argument; remaining positionals are files.
    """
    files: list[str] = []
    skip_next = False
    saw_script = False
    for tok in args:
        if skip_next:
            skip_next = False
            continue
        if tok in ("-e", "-f"):
            skip_next = True
            continue
        if tok.startswith("-"):
            continue
        if not saw_script:
            saw_script = True
            continue
        files.append(tok)
    return files


def _classify_common_write(cmd: _SimpleCommand) -> ShellVerdict | None:
    """Detect common write shapes; return None if not a known write."""
    if not cmd.argv:
        return None
    head = cmd.argv[0]
    args = cmd.argv[1:]

    if head in _WRITE_HEADS_FIRST_POS:
        targets: list[WriteTarget] = []
        for tok in args:
            if tok == "--":
                continue
            if tok.startswith("-"):
                continue
            path = _resolve_path_str(tok)
            targets.append(WriteTarget(path=path, raw=tok, reason="first-positional"))
        if not targets:
            return None
        return ShellVerdict(
            cls=ShellClass.WRITE_KNOWN,
            command=cmd.raw,
            targets=targets,
            head=head,
            reason="first-positionals",
        )

    if head in _WRITE_HEADS_LAST_ARG_DEST:
        target_str = _target_directory_flag(args) or _last_positional(args)
        if target_str is None:
            return None
        path = _resolve_path_str(target_str)
        return ShellVerdict(
            cls=ShellClass.WRITE_KNOWN,
            command=cmd.raw,
            targets=[WriteTarget(path=path, raw=target_str, reason="destination")],
            head=head,
            reason="destination",
        )

    if head == "patch":
        target_str = _patch_write_target(args)
        path = _resolve_path_str(target_str)
        return ShellVerdict(
            cls=ShellClass.WRITE_KNOWN,
            command=cmd.raw,
            targets=[WriteTarget(path=path, raw=target_str, reason="patch-output")],
            head=head,
            reason="patch",
        )

    if head == "dd":
        target_str = _dd_of_target(args)
        if target_str is None:
            return None
        path = _resolve_path_str(target_str)
        return ShellVerdict(
            cls=ShellClass.WRITE_KNOWN,
            command=cmd.raw,
            targets=[WriteTarget(path=path, raw=target_str, reason="dd-of")],
            head=head,
            reason="dd",
        )

    if head == "sed" and _sed_is_in_place(args):
        files = _sed_file_operands(args)
        if not files:
            return None
        targets = [
            WriteTarget(path=_resolve_path_str(f), raw=f, reason="sed-in-place")
            for f in files
        ]
        return ShellVerdict(
            cls=ShellClass.WRITE_KNOWN,
            command=cmd.raw,
            targets=targets,
            head=head,
            reason="sed",
        )

    if head == "git":
        sub, is_write = _git_subcommand(args)
        if sub is None:
            return None
        if is_write:
            cwd_path = Path.cwd().resolve(strict=False)
            return ShellVerdict(
                cls=ShellClass.WRITE_KNOWN,
                command=cmd.raw,
                targets=[WriteTarget(path=cwd_path, raw=str(cwd_path),
                                     reason="git-mutates-cwd")],
                head="git",
                reason=f"git-{sub}",
            )
        return None

    return None


# ----------------------------------------------------------------------------
# Read-only allow-list validators
# ----------------------------------------------------------------------------


def _validate_git_readonly(args: list[str]) -> bool:
    sub, is_write = _git_subcommand(args)
    if sub is None:
        return True  # bare `git` (help) — read-only
    if is_write:
        return False
    return sub in _GIT_READ_ONLY_SUBCOMMANDS


def _validate_find_args(args: list[str]) -> bool:
    """`find` is allow-listed only if no action writes/executes."""
    forbidden = {
        "-delete", "-exec", "-execdir", "-ok", "-okdir",
        "-fprint", "-fprint0", "-fprintf",
    }
    for tok in args:
        if tok in forbidden:
            return False
    return True


def _python_dash_c_code(argv: list[str]) -> str | None:
    """Extract code string from `python[3] [-IBS] -c <code>`."""
    args = argv[1:]
    i = 0
    while i < len(args):
        tok = args[i]
        if tok == "-c" and i + 1 < len(args):
            return args[i + 1]
        if tok.startswith("-c") and len(tok) > 2 and not tok.startswith("--"):
            return tok[2:]
        if tok in ("-I", "-S", "-B", "-O", "-OO", "-q", "-u", "-v"):
            i += 1
            continue
        if tok.startswith("-"):
            return None
        return None
    return None


def _validate_python_readonly_ast(code: str) -> bool:
    """Walk the AST of `python -c <code>` and reject write-shaped nodes."""
    try:
        tree = ast.parse(code, mode="exec")
    except (SyntaxError, ValueError):
        return False
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Name) and func.id in _PYTHON_WRITE_NAMES:
                return False
            if isinstance(func, ast.Attribute) and func.attr in _PYTHON_WRITE_ATTRS:
                return False
        if isinstance(node, ast.Name) and node.id in _PYTHON_WRITE_NAMES:
            return False
    return True


def _is_allowlisted_readonly(cmd: _SimpleCommand) -> bool:
    if not cmd.argv:
        return False
    head = cmd.argv[0]
    if head not in _READ_ONLY_HEADS:
        return False
    if head == "git":
        return _validate_git_readonly(cmd.argv[1:])
    if head == "find":
        return _validate_find_args(cmd.argv[1:])
    if head in ("python", "python3"):
        code = _python_dash_c_code(cmd.argv)
        if code is None:
            return False
        return _validate_python_readonly_ast(code)
    return True


# ----------------------------------------------------------------------------
# Top-level classification flow
# ----------------------------------------------------------------------------


def _shell_c_argument(argv: list[str]) -> tuple[str | None, bool]:
    """Extract the literal string argument of `bash -c <STR>` / `sh -c` / `zsh -c`.

    Returns (code, is_literal). is_literal=False if the string contains
    parameter expansion or substitution.
    """
    args = argv[1:]
    i = 0
    while i < len(args):
        tok = args[i]
        if tok == "-c" and i + 1 < len(args):
            inner = args[i + 1]
            non_literal = (
                "$(" in inner or "`" in inner
                or _GRANT_VAR_RE.search(inner) is not None
            )
            return (inner, not non_literal)
        if tok.startswith("-"):
            i += 1
            continue
        return (None, False)
    return (None, False)


def _classify_simple_command(
    cmd: _SimpleCommand, depth: int,
) -> ShellVerdict:
    """Classify one simple command into a single ShellVerdict."""

    # Walk redirection list for write targets.
    redir_targets: list[WriteTarget] = []
    redir_idx = 0
    while redir_idx < len(cmd.redirections):
        r = cmd.redirections[redir_idx]
        if r.is_heredoc:
            redir_idx += 1
            continue
        op = r.redir_op
        if op and ">" in op:
            target_text = r.redir_attached_target
            if not target_text and redir_idx + 1 < len(cmd.redirections):
                nxt = cmd.redirections[redir_idx + 1]
                if not nxt.redir_op:
                    target_text = nxt.text
                    redir_idx += 1
            if target_text:
                redir_targets.append(WriteTarget(
                    path=_resolve_path_str(target_text),
                    raw=target_text,
                    reason="redirect",
                ))
        redir_idx += 1

    if redir_targets:
        return ShellVerdict(
            cls=ShellClass.WRITE_KNOWN,
            command=cmd.raw,
            targets=redir_targets,
            head=(cmd.argv[0] if cmd.argv else None),
            reason="redirect",
        )

    # Heredoc with no write-redirect: opaque body.
    if cmd.has_heredoc and cmd.argv:
        head = cmd.argv[0]
        if head in ("python", "python3", "awk", "perl", "ruby", "node", "tcl",
                    "bash", "sh", "zsh"):
            return ShellVerdict(
                cls=ShellClass.UNKNOWN_SHELL, command=cmd.raw, head=head,
                reason="interpreter-heredoc",
            )

    # Substitution → DENY_POLICY.
    if cmd.has_substitution:
        return ShellVerdict(
            cls=ShellClass.DENY_POLICY, command=cmd.raw,
            head=(cmd.argv[0] if cmd.argv else None),
            reason="substitution",
        )

    # Recurse through `exec` and shell-c wrappers.
    if cmd.argv:
        head = cmd.argv[0]
        if head == "exec" and len(cmd.argv) > 1:
            inner_cmd = " ".join(cmd.argv[1:])
            return _classify_bash_command(inner_cmd, depth=depth + 1)
        if head in ("bash", "sh", "zsh"):
            inner, literal = _shell_c_argument(cmd.argv)
            if inner is None:
                return ShellVerdict(
                    cls=ShellClass.UNKNOWN_SHELL, command=cmd.raw, head=head,
                    reason="shell-no-dash-c",
                )
            if not literal:
                return ShellVerdict(
                    cls=ShellClass.UNKNOWN_SHELL, command=cmd.raw, head=head,
                    reason="dynamic-shell-c",
                )
            return _classify_bash_command(inner, depth=depth + 1)

        # Common-shape write detection (preserves PR #636 r1-r5).
        write_verdict = _classify_common_write(cmd)
        if write_verdict is not None:
            return write_verdict

        # Brace expansion in argv → UNKNOWN_SHELL.
        for tok in cmd.argv[1:]:
            if "{" in tok and "}" in tok and "," in tok:
                return ShellVerdict(
                    cls=ShellClass.UNKNOWN_SHELL, command=cmd.raw, head=head,
                    reason="brace-expansion",
                )

        # Read-only allow-list check.
        if _is_allowlisted_readonly(cmd):
            return ShellVerdict(
                cls=ShellClass.ALLOW_READONLY, command=cmd.raw, head=head,
            )

        # Known WRITE interpreters not in common-shape detector.
        if head in ("awk", "perl", "ruby", "node"):
            return ShellVerdict(
                cls=ShellClass.UNKNOWN_SHELL, command=cmd.raw, head=head,
                reason="interpreter-write-surface",
            )

    return ShellVerdict(
        cls=ShellClass.UNKNOWN_SHELL,
        command=cmd.raw,
        head=(cmd.argv[0] if cmd.argv else None),
        reason="not-allowlisted",
    )


def _classify_bash_command(command: str, depth: int) -> ShellVerdict:
    """Classify a Bash command line into one ShellVerdict.

    For statement lists, returns a single aggregated verdict over all simple
    commands. ALLOW_READONLY only when EVERY simple command is allow-readonly.
    """
    if depth > _MAX_RECURSION_DEPTH:
        return ShellVerdict(
            cls=ShellClass.UNKNOWN_SHELL, command=command,
            reason="recursion-depth",
        )
    try:
        words = _scan_shell_words(command)
    except (ShellScanError, ValueError, IndexError) as exc:
        return ShellVerdict(
            cls=ShellClass.UNKNOWN_SHELL, command=command,
            reason=f"scan-error:{exc}",
        )
    simple_cmds = _split_simple_commands(words)
    if not simple_cmds:
        return ShellVerdict(cls=ShellClass.ALLOW_READONLY, command=command)

    aggregate_targets: list[WriteTarget] = []
    aggregate_head: str | None = None
    aggregate_reason = ""
    worst_cls = ShellClass.ALLOW_READONLY
    for sc in simple_cmds:
        v = _classify_simple_command(sc, depth)
        if v.cls == ShellClass.ALLOW_READONLY:
            continue
        if worst_cls == ShellClass.ALLOW_READONLY:
            worst_cls = v.cls
            aggregate_head = v.head
            aggregate_reason = v.reason
        aggregate_targets.extend(v.targets)
        if v.cls == ShellClass.DENY_POLICY:
            worst_cls = ShellClass.DENY_POLICY
        if worst_cls != ShellClass.DENY_POLICY and v.cls == ShellClass.WRITE_KNOWN:
            worst_cls = ShellClass.WRITE_KNOWN
    if worst_cls == ShellClass.ALLOW_READONLY:
        return ShellVerdict(cls=ShellClass.ALLOW_READONLY, command=command)
    return ShellVerdict(
        cls=worst_cls,
        command=command,
        targets=aggregate_targets,
        head=aggregate_head,
        reason=aggregate_reason,
    )


def _classify_write(
    tool_name: str, tool_input: dict[str, Any],
) -> tuple[Path | None, ShellVerdict | None]:
    """Return (resolved-write-target, shell-verdict) for the tool call."""
    if tool_name in WRITE_SHAPED_TOOLS:
        for key in ("file_path", "filePath", "path", "notebook_path"):
            value = tool_input.get(key)
            if isinstance(value, str) and value:
                try:
                    return (Path(value).expanduser().resolve(strict=False), None)
                except (OSError, RuntimeError):
                    return (None, None)
        return (None, None)
    if tool_name == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str) or not command:
            return (None, None)
        verdict = _classify_bash_command(command, depth=0)
        if verdict.cls == ShellClass.ALLOW_READONLY:
            return (None, verdict)
        first_target: Path | None = None
        for t in verdict.targets:
            if t.path is not None:
                first_target = t.path
                break
        if first_target is None:
            first_target = Path.cwd().resolve(strict=False)
        return (first_target, verdict)
    return (None, None)


# ----------------------------------------------------------------------------
# Outer hook surface
# ----------------------------------------------------------------------------


def _block_payload(
    task_title: str, write_target: Path, tool_name: str,
    verdict: ShellVerdict | None,
) -> dict[str, Any]:
    if verdict is not None and verdict.cls == ShellClass.UNKNOWN_SHELL:
        reason = (
            f"This task title (`{task_title.strip()}`) carries a companion-role "
            f"prefix (`[plan]` / `[review]`), which is read-only by contract. "
            f"Tool `{tool_name}` ran a Bash command that is not in the read-only "
            f"allow-list and is not a recognized write shape. "
            f"In block mode, unknown shell requires an exact `shell: <command>` "
            f"grant in the task body, or the command must be reshaped into one "
            f"of the allow-listed read-only forms."
        )
    elif verdict is not None and verdict.cls == ShellClass.DENY_POLICY:
        reason = (
            f"This task title (`{task_title.strip()}`) carries a companion-role "
            f"prefix (`[plan]` / `[review]`), which is read-only by contract. "
            f"Tool `{tool_name}` ran a Bash command containing command/process "
            f"substitution. In block mode this requires an exact `shell:` grant "
            f"in the task body."
        )
    else:
        reason = (
            f"This task title (`{task_title.strip()}`) carries a companion-role "
            f"prefix (`[plan]` / `[review]`), which is read-only by contract. "
            f"Tool `{tool_name}` attempted to write to `{write_target}`. "
            f"Carve-outs: `/tmp/*` is always allowed; explicit "
            f"`implement-permission: <path>` (or `write: <path>`) grants in the "
            f"task body are allowed. To bypass, restate this as an "
            f"implementation task, or add a grant naming the target path or an "
            f"exact `shell: <command>` line in the body."
        )
    return {"decision": "block", "reason": reason}


def main() -> int:
    event = _read_event()
    agent = (os.environ.get("BRIDGE_AGENT_ID") or "").strip()
    if not agent:
        return 0

    mode = _mode()

    try:
        task = _claimed_task(agent)
    except Exception:  # noqa: BLE001
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
        write_target, verdict = _classify_write(tool_name, tool_input)
    except Exception:  # noqa: BLE001
        write_audit(
            "codex_task_mode_policy.error",
            agent,
            {"mode": mode, "stage": "classify_write", "tool": tool_name},
        )
        return 0
    if write_target is None and verdict is None:
        return 0  # not write-shaped

    if verdict is not None and verdict.cls == ShellClass.ALLOW_READONLY:
        return 0

    grants = _parse_grants(task["body"])

    tmp_root = Path("/tmp").resolve(strict=False)
    if verdict is None:
        # Structured tool path
        if write_target is not None and _path_in(write_target, tmp_root):
            return 0
        if write_target is not None:
            for g in grants:
                if g.path is not None and _path_in(write_target, g.path):
                    return 0
    else:
        if verdict.cls == ShellClass.WRITE_KNOWN and verdict.targets:
            all_resolved = all(t.path is not None for t in verdict.targets)
            if all_resolved and all(_path_in(t.path, tmp_root) for t in verdict.targets):
                return 0
        if _match_bash_write_grants(verdict, grants):
            return 0

    detail: dict[str, Any] = {
        "mode": mode,
        "task_id": task["id"],
        "task_title": task["title"],
        "tool": tool_name,
        "write_target": str(write_target) if write_target is not None else "",
        "would_block": True,
    }
    if verdict is not None:
        detail["shell_class"] = verdict.cls.value
        detail["shell_reason"] = verdict.reason
    write_audit("codex_task_mode_policy.deny", agent, detail)

    if mode == "block":
        sys.stdout.write(json.dumps(
            _block_payload(task["title"], write_target or Path.cwd(), tool_name, verdict)
        ))
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
