#!/usr/bin/env python3
"""Claude tool policy hook for cross-agent isolation and audit trail."""

from __future__ import annotations

import json
import os
import pwd
import re
import shlex
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent

# Import bridge_hook_common from this hooks/ directory directly. ROOT (the
# bridge home) cannot be added to sys.path under linux-user isolation because
# the isolated UID may have only ``--x`` ACL on it, so listdir() based finders
# fail. hooks/ remains readable+executable for isolated UIDs.
_HOOKS_DIR = Path(__file__).resolve().parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from bridge_hook_common import (  # noqa: E402
    agent_home_root,
    bridge_home_dir,
    current_agent,
    current_agent_class,
    current_agent_workdir,
    emit_system_cross_agent_read,
    load_guard_module,
    path_within,
    truncate_text,
    write_audit,
)

_guard = load_guard_module(
    ROOT,
    required_attrs=(
        "analyze_text",
        "is_builtin_tool",
        "prompt_guard_enabled",
        "sanitize_text",
        "threshold_for_surface",
        "tool_output_text",
    ),
)
if _guard is None:
    # Guard module unavailable (missing/unreadable/syntax/missing-symbol).
    # Exit silently rather than tracebacking every hook invocation; a broken
    # guard module is a corrupt install state for the operator to diagnose,
    # not a reason to brick every Claude session.
    sys.exit(0)

analyze_text = _guard.analyze_text
is_builtin_tool = _guard.is_builtin_tool
prompt_guard_enabled = _guard.prompt_guard_enabled
sanitize_text = _guard.sanitize_text
threshold_for_surface = _guard.threshold_for_surface
tool_output_text = _guard.tool_output_text

# Importing the system-config protected-path SSOT requires lib/ on sys.path.
# Keep this scoped to tool-policy.py rather than mutating bridge_hook_common
# so the additional import surface stays auditable in one place.
_LIB_DIR = ROOT / "lib"
if _LIB_DIR.is_dir() and str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))

from system_config_paths import (  # noqa: E402
    is_protected_path,
    matched_pattern,
    protected_literal_suffixes,
)


def roster_local_path() -> Path:
    return bridge_home_dir() / "agent-roster.local.sh"


def task_db_path() -> Path:
    return bridge_home_dir() / "state" / "tasks.db"


CLAUDE_CREDENTIAL_DENY_REASON = (
    "Claude OAuth credentials are blocked inside tool calls; use a redacted "
    "diagnostic such as `claude auth status` instead"
)


def _resolve_existing(path: Path) -> Path:
    try:
        return path.expanduser().resolve()
    except OSError:
        return path.expanduser()


def _controller_home_dir() -> Path | None:
    try:
        return Path(pwd.getpwuid(bridge_home_dir().stat().st_uid).pw_dir)
    except (KeyError, OSError):
        return None


def claude_credential_paths() -> set[Path]:
    paths = {Path.home() / ".claude" / ".credentials.json"}
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if config_dir:
        paths.add(Path(config_dir).expanduser() / ".credentials.json")
    controller_home = _controller_home_dir()
    if controller_home is not None:
        paths.add(controller_home / ".claude" / ".credentials.json")
    # PR #799 r2 codex finding 2 — the Claude OAuth token registry honors
    # $BRIDGE_CLAUDE_TOKEN_REGISTRY (override) before falling back to
    # $BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json (see
    # bridge-auth.sh:27 bridge_auth_registry_path). Both surfaces must be
    # denied so Read/Glob/Grep/Bash-by-path access mirrors the raw-text
    # deny in `_raw_mentions_claude_credentials`.
    registry_override = os.environ.get("BRIDGE_CLAUDE_TOKEN_REGISTRY", "").strip()
    if registry_override:
        paths.add(Path(registry_override).expanduser())
    runtime_secrets = os.environ.get("BRIDGE_RUNTIME_SECRETS_DIR", "").strip()
    if runtime_secrets:
        paths.add(Path(runtime_secrets).expanduser() / "claude-oauth-tokens.json")
    return {_resolve_existing(path) for path in paths}


def _path_is_claude_credentials(path: Path) -> bool:
    expanded = _resolve_existing(path)
    if expanded in claude_credential_paths():
        return True
    parts = expanded.parts
    return len(parts) >= 2 and parts[-2:] == (".claude", ".credentials.json")


def _raw_mentions_claude_credentials(raw: str) -> bool:
    return (
        "sk-ant-o" in raw
        or (".credentials.json" in raw and ".claude" in raw)
        # PR #799 r2/r3 defense-in-depth — Path A no longer delivers the
        # active OAuth token through the tool-inherited environment, but
        # block the variable name so stale launch env files or manual
        # operator exports cannot be read through tool output.
        or "CLAUDE_CODE_OAUTH_TOKEN" in raw
        # PR #799 r2 codex finding 1 — block `launch-secrets.env`
        # mentions (defense-in-depth for any future env vars added to
        # the same file).
        or "launch-secrets.env" in raw
        # PR #799 r2 codex finding 2 — block reads of the token
        # registry JSON. The `claude_credential_paths()` set covers the
        # canonical and override paths for path-typed inputs; this
        # substring rule covers raw Bash text that names the file by
        # basename or a relative path.
        or "claude-oauth-tokens.json" in raw
    )


# PR #799 r3 codex finding 1 — match process-environment dump verbs
# that revealed the exported CLAUDE_CODE_OAUTH_TOKEN under the abandoned
# env-token delivery path. Path A now syncs Claude OAuth through
# .credentials.json instead, but keep this as a stale-env/manual-export
# guard; the r2 substring deny above only matches raw text containing the
# literal token-variable name.
#
# Coverage:
#   env [/options]            POSIX env, dumps everything when called with no
#                             positional COMMAND or piped
#   printenv [VAR...]         no-arg dump and `printenv CLAUDE_CODE_OAUTH_TOKEN`
#   set                       bash builtin with no args dumps all vars
#   compgen -e                completion list of exported vars
#   declare -p / declare -x   prints all / all exported vars
#   typeset -p / typeset -x   ksh-style alias for declare
#   export -p                 prints all exported vars
#   /proc/<pid>/environ       Linux env dump via procfs (also /proc/self/environ)
#
# Word-boundary patterns avoid matching legitimate token substrings
# such as `environment`, `setfacl`, `kubectl set image`, or `set -e`.
# Routed to the same CLAUDE_CREDENTIAL_DENY_REASON as the substring
# deny — no second reason constant.
# `env` and `printenv` regexes re-derived on 2026-05-16. Two rounds:
#
#   r1 (initial fix for operator-flagged false positive): the original
#       `(?<![A-Za-z0-9_/])env(?![A-Za-z0-9_])` matched every standalone
#       occurrence of the word `env` regardless of context, so task
#       titles or commit subjects containing natural language like
#       "stale env override" tripped the credential-deny path. r1
#       added `-` and `.` to the lookbehind and required a terminator
#       immediately after `env`.
#
#   r2 (codex PR #925 needs-more): r1 newly missed real dump shapes
#       where `env` carries options/assignments but no utility command:
#       `env VAR=value`, `env -u CLAUDE_CODE_OAUTH_TOKEN`, `env -0`,
#       `env --null`, `env 1>/tmp/dump`, `env 1>&2`, `env # comment`.
#       POSIX env prints the environment when no utility is given, so
#       each of those leaks the parent process env.
#
# Final semantics for `env`:
#   - Lookbehind excludes `[A-Za-z0-9_/.\-]` so `show-env`, `printenv`,
#     `.env` do NOT match (preserves the natural-language fix).
#   - After `env\b`, the regex consumes zero-or-more option/assignment
#     tokens — short opt `-X` (with optional packed value), separated
#     arg form `-u VAR` for short opts that take a follow-on arg (the
#     POSIX `-u/-S/-P/-C` set), long opt `--name`, or `VAR=value`
#     assignment.
#   - The match completes when after those tokens the next non-space
#     thing is a statement terminator, redirect (incl. FD-prefixed `1>`
#     / `2>&1` / `>>`), an inline comment `#`, a subshell-close `)`,
#     a backtick, or end-of-string.
#   - Crucially, if the next thing is a bare word (utility command),
#     the match fails — so `env -i bash`, `env VAR=val cmd`,
#     `env -u FOO cmd` still pass through.
#
# `printenv` is always a dump on invocation (with or without VAR
# args), so only the command-position precondition is enforced.
# Natural prose ("use printenv to check") passes; real invocations
# still trip.
_ENV_DUMP_PATTERNS = (
    re.compile(
        r"""
        (?<![A-Za-z0-9_/.\-]) env \b
        (?:
            # Long option with separated arg (GNU forms that print env
            # with no utility -- codex PR #925 r3+r4): --unset NAME,
            # --split-string ARG. The signal-control opts
            # (--ignore-signal / --default-signal / --block-signal) are
            # NOT in this list because GNU env treats the next token as
            # the COMMAND, not as the signal arg, in the separated form
            # (verified by codex r4 against /opt/homebrew/bin/genv,
            # exit 127 "No such file or directory"). Their =value form
            # is still a dump and is matched by the long-opt branch
            # below.
            \s+ --(?: unset | split-string )
              \s+ \S+
          | \s+ -- [A-Za-z0-9_-]* (?: = \S* )?   # long option, incl. GNU --name=value
          | \s+ -[uSPC] \s+ \S+                 # short opt that takes a separated arg
          | \s+ -[A-Za-z0-9][A-Za-z0-9]*        # short opt or packed -uVAR
          | \s+ [A-Za-z_][A-Za-z0-9_]* = \S*    # VAR=value assignment
        )*
        \s*
        (?:
            $                                    # end of string
          | \#                                   # inline comment
          | [\n;|&)]                            # statement terminator / subshell close
          | [0-9]* [<>]                         # redirect (FD-prefixed or bare)
          | `                                    # backtick close
        )
        """,
        re.VERBOSE,
    ),
    # `printenv` is always dangerous when invoked (with or without VAR
    # args), so only the command-position precondition is enforced — no
    # trailing terminator requirement. The prefix `(?:^|[\n;&|`()<>])`
    # consumes the separator, but re.search only cares about existence.
    # Natural-language "use printenv to check" (preceded by a space
    # which is not in the separator set) no longer matches.
    re.compile(r"(?:^|[\n;&|`()<>])\s*printenv\b"),
    # bare `set` with no args (dumps all vars). Same noise-reduction as
    # the env/printenv tightenings — natural language "the var was set"
    # used to match because the prior class `[;\s|&]` allowed a plain
    # whitespace prefix, which is indistinguishable from "verb at end of
    # an English sentence". The new prefix `[\n;|&` + subshell/backtick
    # delimiters` excludes pure whitespace, so `the var was set` falls
    # through. Dangerous shapes (`set`, `set | head`, `;set`, `$(set)`,
    # `set > file`) still match because the prefix is consumed and the
    # trailing terminator class is unchanged.
    re.compile(r"(?:^|[\n;|&`()<>])\s*set\s*(?=$|[\n;|&<>`)])"),
    re.compile(r"(?<![A-Za-z0-9_])compgen\s+-[A-Za-z]*e"),
    re.compile(r"(?<![A-Za-z0-9_])declare\s+-[A-Za-z]*[xp]"),
    re.compile(r"(?<![A-Za-z0-9_])typeset\s+-[A-Za-z]*[xp]"),
    re.compile(r"(?<![A-Za-z0-9_])export\s+-p(?![A-Za-z0-9_])"),
    re.compile(r"/proc/[^/\s]+/environ\b"),
)


def _raw_dumps_process_environment(raw: str) -> bool:
    return any(p.search(raw) for p in _ENV_DUMP_PATTERNS)


def claude_credentials_reason_for_path(path: Path) -> str | None:
    if _path_is_claude_credentials(path):
        return CLAUDE_CREDENTIAL_DENY_REASON
    return None


def admin_agent_id() -> str:
    return os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()


def _admin_agent_from_session_type(agent: str) -> bool:
    try:
        session_type_path = agent_home_root() / agent / "SESSION-TYPE.md"
        if not session_type_path.is_file():
            return False
        for raw_line in session_type_path.read_text(errors="replace").splitlines():
            line = raw_line.strip().lstrip("-").strip()
            if not line.lower().startswith("session type:"):
                continue
            value = line.split(":", 1)[1].strip().lower()
            return value == "admin"
    except Exception:
        return False
    return False


def is_admin_agent(agent: str) -> bool:
    admin = admin_agent_id()
    if admin and agent == admin:
        return True
    if agent and _admin_agent_from_session_type(agent):
        return True
    return False


def _emit_admin_credential_read_allowed(
    agent: str,
    *,
    tool: str,
    surface: str,
    sample: str = "",
    tool_input: dict[str, Any] | None = None,
) -> None:
    """Audit an admin agent's read-intent bypass of a credential-deny path.

    Admin agents (system agents acting as the operator's deputy) are
    allowed to perform diagnostic reads (``cat`` / ``ls`` / ``stat`` /
    ``grep`` / ``head`` / ``tail`` / Read / Glob / Grep / NotebookRead)
    against the Claude OAuth credential path and to inspect their own
    process environment. Mutation deny paths (roster local, system
    config, queue DB) stay enforced — admin still flows mutations
    through ``agent-bridge config set``.

    Every bypass writes an ``agent_admin_credential_read_allowed`` audit
    row so the operator retains a full ledger of admin credential
    reads. ``surface`` is the deny path that was bypassed
    (``raw_credentials_mention`` / ``raw_env_dump`` / ``argv_path`` /
    ``input_path``) and ``sample`` is a truncated copy of the offending
    text or path for post-hoc inspection.

    The audit row mirrors the deny-row shape (``agent_tool_denied``):
    when the caller supplies ``tool_input`` we emit the same
    ``summary`` block ``tool_input_summary`` would produce, so a single
    audit consumer can read allow + deny rows uniformly (codex PR #881
    r1 finding 3). Bash callers without ``tool_input`` can pass
    ``sample=text`` and it will be lifted into ``summary.command``.
    """
    detail: dict[str, Any] = {
        "tool": tool,
        "surface": surface,
    }
    if sample:
        detail["sample"] = truncate_text(sample, 200)
    # Mirror the deny-row `summary` field. Prefer the structured
    # `tool_input_summary` shape when caller has the full tool_input;
    # otherwise synthesize a minimal Bash summary from `sample` so the
    # audit row still carries the structured field deny consumers
    # expect.
    if tool_input is not None:
        detail["summary"] = tool_input_summary(tool, tool_input)
    elif sample and tool == "Bash":
        detail["summary"] = {
            "command": truncate_text(sample, 240),
            "description": "",
        }
    write_audit("agent_admin_credential_read_allowed", agent or "unknown", detail)


_NON_AGENT_ENTRIES: frozenset[str] = frozenset({
    # `shared` is the canonical symlink to BRIDGE_SHARED_DIR. Treating it
    # as a peer agent home used to collapse every shared-dir write into
    # the "cross-agent access blocked" rejection (issue #240).
    "shared",
    # Profile template shipped under agents/; never a real agent, but
    # `is_dir()` returns True for it so it used to false-positive as a
    # peer.
    "_template",
    # Framework-internal dotfile. `bridge-agent.sh create` does not
    # reserve leading-dot names today (Codex round-2 repro: `create
    # .real --dry-run` succeeds), so the exclusion has to be an exact
    # match, not a prefix rule — otherwise a legitimate `.real` agent
    # would silently lose cross-agent detection.
    ".claude",
})


def other_agent_homes(agent: str) -> list[Path]:
    """Return every sibling agent home under `agent_home_root()`.

    Excludes only entries that are never real agents on a standard
    install — an exact-name allowlist, no prefix heuristic:

    - The `shared` symlink alias (→ BRIDGE_SHARED_DIR). This was the
      direct trigger for issue #240 — `path.resolve()` collapsed the
      alias into the shared tree and blocked every legitimate write.
    - `_template`, the shipped agent profile template.
    - `.claude`, framework-internal runtime directory.

    Everything else — including agents whose names start with `_` or
    `.`, and non-alias symlink homes a site may legitimately
    introduce — stays in the list so cross-agent isolation continues
    to trigger on real peer paths. Codex rounds 1 and 2 on PR #242
    both landed on this over-filter class, so we deliberately avoid
    any prefix-based skip.
    """
    homes: list[Path] = []
    root = agent_home_root()
    if not root.exists():
        return homes
    for candidate in root.iterdir():
        if not candidate.is_dir():
            continue
        name = candidate.name
        if not name:
            continue
        if name == agent:
            continue
        if name in _NON_AGENT_ENTRIES:
            continue
        homes.append(candidate)
    return homes


def target_agent_for_path(path: Path, agent: str) -> str | None:
    for other_home in other_agent_homes(agent):
        if path_within(path, other_home):
            return other_home.name
    return None


def target_agent_for_text(text: str, agent: str) -> str | None:
    home_root = agent_home_root()
    for other in other_agent_homes(agent):
        name = other.name
        needles = [
            f"{home_root}/{name}/",
            f"{home_root}/{name}",
            f"~/.agent-bridge/agents/{name}/",
            f"~/.agent-bridge/agents/{name}",
            f"$HOME/.agent-bridge/agents/{name}/",
            f"$HOME/.agent-bridge/agents/{name}",
        ]
        for needle in needles:
            if needle in text:
                return name
    return None


def detect_target_agent(tool_name: str, tool_input: dict[str, Any], agent: str) -> str | None:
    if tool_name == "Bash":
        command = str(tool_input.get("command") or "")
        if command:
            return target_agent_for_text(command, agent)
        return None
    for key in ("file_path", "path"):
        raw = str(tool_input.get(key) or "").strip()
        if not raw:
            continue
        try:
            candidate = Path(raw).expanduser()
        except Exception:
            continue
        target = target_agent_for_path(candidate, agent)
        if target:
            return target
    return None


SYSTEM_CONFIG_DENY_REASON = (
    "system config path requires `agent-bridge config set` "
    "(direct Edit/Write blocked by issue #341 gating)"
)

ROSTER_LOCAL_DENY_REASON = (
    "agent-roster.local.sh is a protected system config path. "
    "Use `agent-bridge config set` instead. Admin role does not exempt "
    "this path — the wrapper preserves the audit chain."
)


# Read-intent Bash command names. The protected-path gate is about
# preserving the #341 write-audit chain; reads do not mutate state and
# should not be denied regardless of agent identity (issue #383).
#
# A command is treated as read-intent when ALL pipeline stages start
# with one of these tokens. A single write-intent (or unknown) leading
# command anywhere disqualifies the whole invocation — that keeps the
# bar at "this command provably does not mutate the protected path"
# rather than at "this command might be safe".
_READ_INTENT_BASH_COMMANDS = frozenset(
    {
        "cat",
        "grep",
        "egrep",
        "fgrep",
        "rg",
        "head",
        "tail",
        "less",
        "more",
        "view",
        "wc",
        "stat",
        "file",
        "md5sum",
        "sha256sum",
        "sha1sum",
        "xxd",
        "od",
        "diff",
        "cmp",
        "ls",
        "find",
        "awk",
        "cut",
        "sort",
        "uniq",
        "tr",
        "column",
        "jq",
        "yq",
        "tac",
        "nl",
        "readlink",
        "realpath",
        "basename",
        "dirname",
    }
)


# Issue #1014 C: provably non-mutating shell builtins that routinely
# appear as a *prelude* stage in a read pipeline — `cd ~/.agent-bridge &&
# grep BRIDGE agent-roster.local.sh`, `test -f roster && cat roster`,
# `echo "checking"; grep …`. None of these can mutate the filesystem:
# `cd`/`pwd` only move/print the working directory, `test`/`[` are
# read-only predicates, `echo`/`printf` write to stdout (any redirection
# is independently rejected by the per-token write-redirect check below),
# and `true`/`false`/`:` are no-ops. Before #1014 a neutral prelude stage
# disqualified the whole pipeline, so a routine `cd … && grep <protected>`
# read was mis-classified as a write and drew the write-oriented
# `config set` deny. Treating these stages as transparent does NOT widen
# the write surface — a genuine write stage (or any output redirection)
# anywhere in the pipeline still flips the classification to write-intent.
_NEUTRAL_PRELUDE_BASH_COMMANDS = frozenset(
    {
        "cd",
        "pushd",
        "popd",
        "pwd",
        "test",
        "[",
        "[[",
        "echo",
        "printf",
        "true",
        "false",
        ":",
    }
)


def _stage_first_token(stage: str) -> str:
    """Return the leading command word of a single pipeline stage.

    Strips a leading ``env`` invocation and any ``VAR=value`` assignment
    prefix so e.g. ``LC_ALL=C grep …`` still classifies as ``grep``.
    Returns ``""`` for an empty stage (which the caller skips).
    """
    parts = stage.strip().split()
    i = 0
    while i < len(parts):
        token = parts[i]
        if not token:
            i += 1
            continue
        # Strip leading-env style prefixes: `env`, `VAR=value`.
        if token == "env":
            i += 1
            continue
        if "=" in token and not token.startswith("-") and "/" not in token.split("=", 1)[0]:
            # Looks like `VAR=value`; skip.
            i += 1
            continue
        return token
    return ""


# Stderr-suppression / fd-dup forms that *look* like write redirection
# but cannot mutate the filesystem: `2>/dev/null` discards fd-2,
# `2>&1` merges fd-2 into fd-1, `&>/dev/null` discards both. These must
# not flip a read-intent classification (issue #574).
_SAFE_REDIRECT_PATTERNS = ("2>/dev/null", "2>&1", "&>/dev/null")

# Token-boundary regex used to strip the safe-redirect forms before
# operator splitting. Naive `str.replace` would also strip substrings
# like `2>/dev/null/extra` (a real write to a path *under* /dev/null/),
# turning a write into a fake read (issue #574 r2). The lookahead
# requires end-of-string or a true shell token-separator after the
# match — whitespace or one of `; & | ( ) < >`. `$` and backtick are
# excluded because they begin variable / command substitution and are
# not separators: `2>/dev/null$VAR` and ``2>/dev/null`cmd` `` are real
# writes to a substituted path, not stderr discards (issue #574 r3).
_SAFE_REDIRECT_RE = re.compile(
    r"(?:2>/dev/null|2>&1|&>/dev/null)(?=$|[\s;&|()<>])"
)

# Output-redirection token detector for `_is_read_intent_bash`.
#
# The prior `tok.startswith(("&>", "2>", ">>", ">"))` check missed numeric
# fd forms other than `2>`: e.g. `1>/tmp/leak`, `3>file`, `99>>log`. That
# let `cat ~/.claude/.credentials.json 1>/tmp/leak` slip through as
# read-intent and bypass the admin credential carve-out's deny mirror
# (codex PR #881 r1 finding 1).
#
# Match shape: optional digit run, then `>` or `>>`. Anchored to the
# start of the token because `_is_read_intent_bash` operates on the
# whitespace-split tokens of a stage; an embedded `2>` inside a quoted
# string never reaches this check.
_NUMERIC_FD_WRITE_RE = re.compile(r"^[0-9]+>>?")


def _is_read_intent_bash(command: str) -> bool:
    """Return True iff *command* is purely read-intent.

    Splits on shell command separators (``|``, ``||``, ``&&``, ``;``,
    newline) and requires every non-empty stage's leading command to be
    in :data:`_READ_INTENT_BASH_COMMANDS`. ``agent-bridge config get``
    (and the ``agb`` shorthand) is also recognised as read-intent.

    Conservative on purpose:

    - Any output redirection (``>``, ``>>``, ``&>``, ``2>``) appears as
      a token starting with that prefix and disqualifies the pipeline,
      even if the leading command is otherwise a read tool. ``cat >x``
      writes to *x* — the destination path could be the protected one.
      Stderr-suppression / fd-dup tokens in
      :data:`_SAFE_REDIRECT_PATTERNS` are exempt: they don't mutate the
      filesystem (issue #574).
    - Input redirection (``<``) is fine; it only opens the file for
      reading.
    - A single write-intent or unknown leading command anywhere in the
      pipeline disqualifies the whole thing. The bar is "this command
      provably does not mutate state".
    """
    if not command.strip():
        return False
    # Strip stderr-suppression / fd-dup tokens before splitting on shell
    # operators. `_COMMAND_OPERATOR_RE` would otherwise tear `2>&1` and
    # `&>/dev/null` on the embedded `&`, hiding them from the per-token
    # check below (issue #574). Matches must be token-boundary aware:
    # `2>/dev/null/extra` is a real write to a path under /dev/null/,
    # not a stderr discard, and must NOT be stripped (issue #574 r2).
    sanitized = _SAFE_REDIRECT_RE.sub(" ", command)
    # Split on shell operators with quote-awareness: a literal `|` / `;` /
    # `&` inside a quoted argument (e.g. the alternation in `grep -nE
    # 'format|codex' <path>`) must NOT start a new stage, or the read
    # would be misclassified as write-intent (issue #1054). A genuine
    # `... | tee <path>` still splits — the `tee` stage is unknown and
    # disqualifies the command, so the guard is not weakened.
    stages, balanced = _split_command_stages(sanitized)
    # Fail closed on an unterminated quote: an unbalanced quote masks
    # every operator after it, so a `... | tee <protected>` write would
    # hide behind the open quote. An un-parseable command is never a safe
    # read (issue #1054 codex r1).
    if not balanced:
        return False
    for stage in stages:
        stage_stripped = stage.strip()
        if not stage_stripped:
            continue
        # Reject output-redirection anywhere in the stage. Input redir
        # (`<file`) is fine; write redir (`>`, `>>`, `&>`, `2>`) is not.
        # Stderr-suppression forms (`2>/dev/null`, `2>&1`, `&>/dev/null`)
        # were stripped above and don't reach this loop (issue #574).
        for tok in stage_stripped.split():
            if tok in _SAFE_REDIRECT_PATTERNS:
                continue
            for prefix in ("&>", "2>", ">>", ">"):
                if tok.startswith(prefix):
                    return False
            # Numeric fd output redirections (`1>file`, `3>file`,
            # `99>>log`, …). The prefix tuple above only catches the
            # bare `>` / `>>` / `&>` / `2>` forms; other digit fds slip
            # through and would otherwise let
            # `cat ~/.claude/.credentials.json 1>/tmp/leak` classify as
            # read-intent (codex PR #881 r1 finding 1).
            if _NUMERIC_FD_WRITE_RE.match(tok):
                return False
        first = _stage_first_token(stage_stripped)
        if not first:
            continue
        # Strip any path component so `/usr/bin/cat` classifies as `cat`.
        leaf = first.rsplit("/", 1)[-1]
        # Issue #1014 C: a neutral prelude stage (`cd`, `test`, `echo`, …)
        # cannot mutate state — output redirection is already rejected by
        # the per-token check above — so it must not disqualify an
        # otherwise read-intent pipeline.
        if leaf in _NEUTRAL_PRELUDE_BASH_COMMANDS:
            continue
        if leaf in _READ_INTENT_BASH_COMMANDS:
            # Reject the in-place / write-mode flag forms even for tools
            # that are normally read-only (e.g. `sed -i`, `awk -i inplace`).
            stage_tokens = stage_stripped.split()
            if leaf == "sed" and any(t == "-i" or t.startswith("-i") for t in stage_tokens[1:]):
                return False
            if leaf == "awk" and "-i" in stage_tokens[1:]:
                return False
            continue
        # `agent-bridge config get …` / `agb config get …` are read-intent.
        if leaf in {"agent-bridge", "agb"}:
            stage_tokens = stage_stripped.split()
            try:
                cfg_idx = stage_tokens.index("config")
            except ValueError:
                return False
            if (
                len(stage_tokens) > cfg_idx + 1
                and stage_tokens[cfg_idx + 1] in {"get", "list-protected"}
            ):
                continue
            return False
        return False
    return True


def _is_read_intent_tool(tool_name: str, tool_input: dict[str, Any]) -> bool:
    """Return True iff a tool call is read-intent against any path.

    - Read / Glob / Grep / NotebookRead are read-intent.
    - Bash defers to :func:`_is_read_intent_bash`.
    - Edit / Write / MultiEdit / NotebookEdit and unknown tools are
      treated as write-intent (the safe default for novel surfaces).
    """
    if tool_name in {"Read", "Glob", "Grep", "NotebookRead"}:
        return True
    if tool_name == "Bash":
        return _is_read_intent_bash(str(tool_input.get("command") or ""))
    return False


# Issue #539: subpath allowlist that a class=system agent may read out of
# another agent's home. Only the operator-curated, ingestion-friendly
# memory subtrees are exposed; raw `state/`, `logs/`, `private/`,
# credentials, etc. stay denied even for system-class agents. Add a new
# subpath here ONLY when the bridge has a clear ingestion contract for
# it — every entry expands the cross-agent privilege surface.
_SYSTEM_CLASS_READABLE_AGENT_SUBPATHS: tuple[str, ...] = (
    "memory/projects/",
    "memory/decisions/",
    "memory/shared/",
)

# Issue #539: shared/* is broadly readable by class=system agents, with
# narrow exceptions for any operator-side curated secret/private prefix.
# Anything operators want to keep private even from system-class agents
# goes under one of these prefixes.
_SHARED_FORBIDDEN_PREFIXES: tuple[str, ...] = (
    "private/",
    "secrets/",
)


def _resolve_under(path: Path, root: Path) -> Path | None:
    """Return *path* expressed relative to *root*, or None if outside.

    Resolves both sides through ``Path.resolve()`` so symlinked aliases
    (e.g., the ``shared`` symlink under ``$BRIDGE_HOME/agents/``) and
    ``..`` traversal are normalized before the prefix check. Returning
    None signals "not under this root" to the caller — never an error.
    """
    try:
        rel = path.resolve().relative_to(root.resolve())
    except (ValueError, OSError):
        return None
    return rel


def _system_class_cross_agent_read_allowed(
    path: Path,
    self_agent: str,
) -> tuple[bool, str]:
    """Decide whether *path* is in the class=system Read allowlist.

    Returns ``(allowed, target_agent)``. ``target_agent`` is the peer
    whose home contains *path*, or ``""`` for shared/* matches; the
    caller uses it for the audit row. ``allowed=False`` means the path
    sits outside both the per-agent subpath allowlist and the shared
    allowlist, so the cross-agent gate must continue to deny — even for
    a system-class actor.

    The check is read-only by construction: the caller (the ``Read`` /
    ``Glob`` / ``Grep`` cross-agent gate) only invokes this for
    read-intent tools. Bash/Edit/Write paths never reach here, so a
    system-class agent cannot escalate to cross-agent writes through
    this carve-out.
    """
    bridge_home = bridge_home_dir()
    home_root = agent_home_root()

    # shared/* allowlist (with private/ and secrets/ explicitly excluded).
    shared_root = bridge_home / "shared"
    rel_shared = _resolve_under(path, shared_root)
    if rel_shared is not None:
        rel_str = rel_shared.as_posix()
        # Bare `shared/` (rel == ".") is allowed for directory-level reads.
        if rel_str == ".":
            return True, ""
        for forbidden in _SHARED_FORBIDDEN_PREFIXES:
            if rel_str == forbidden.rstrip("/") or rel_str.startswith(forbidden):
                return False, ""
        return True, ""

    # agents/<other>/memory/{projects,decisions,shared}/ allowlist.
    rel_agent = _resolve_under(path, home_root)
    if rel_agent is not None:
        parts = rel_agent.parts
        if len(parts) < 2:
            # `agents/` itself or `agents/<name>` — not enough structure
            # to be inside the memory allowlist.
            return False, ""
        other_agent = parts[0]
        # Self-home reads are allowed by the existing per-agent isolation;
        # this carve-out is specifically for *cross*-agent Read.
        if other_agent == self_agent:
            return False, ""
        rest = "/".join(parts[1:]) + "/"
        for sub in _SYSTEM_CLASS_READABLE_AGENT_SUBPATHS:
            if rest.startswith(sub):
                return True, other_agent
        return False, other_agent

    return False, ""


def protected_path_reason(
    path: Path,
    agent: str,
    *,
    read_intent: bool = False,
) -> str | None:
    admin = is_admin_agent(agent)
    # Order matters: keep the more-specific error messages (roster
    # secrets / queue DB) ahead of the generic system-config deny so
    # existing assertions in scripts/smoke-test.sh continue to find the
    # narrower wording. The system-config gate (issue #341) catches the
    # additional protected paths that don't map to a specific helper —
    # access.json, cron job files, hooks settings, runtime config.
    #
    # Admin agents do NOT bypass roster_local_path (codex r1 #341 CP2):
    # the file is in PROTECTED_GLOBS and the wrapper is the only sound
    # mutation surface even for admin. The wrapper itself runs from
    # operator-TUI, so legitimate operator workflows still succeed —
    # only direct Edit/Write attempts are blocked.
    #
    # Issue #383: read-intent calls (Read tool, cat/grep/etc., `agent-
    # bridge config get`) bypass the protected-path block-all branch.
    # #341's audit chain is about WRITES; reads do not mutate state and
    # should not be denied regardless of agent identity. The queue DB
    # is the one exception — its block message points at `agb` queue
    # commands (the structured-read surface) rather than raw sqlite, so
    # we keep blocking direct reads of the DB to preserve the queue
    # contract.
    if path == roster_local_path():
        if read_intent:
            return None
        if admin:
            return ROSTER_LOCAL_DENY_REASON
        return "shared roster secrets are not available inside Claude tool calls"
    if path == task_db_path():
        return "direct queue DB access is blocked; use `agb` queue commands instead"
    # Issue #341: remaining system-config paths must flow through the
    # wrapper for writes. Read-intent is allowed for all agents — the
    # wrapper layers an operator-source check on top of writes only.
    if is_protected_path(path):
        if read_intent:
            return None
        return SYSTEM_CONFIG_DENY_REASON
    if admin:
        return None
    # Issue #539 r2: shared/* is NOT a peer-agent path, so
    # target_agent_for_path() returns None for it and the original
    # `if target:` block below never fired for shared reads. Evaluate
    # the system-class shared/* gate first, before peer-agent
    # resolution, so:
    #   - shared/private/*, shared/secrets/* → DENY for system class
    #     (operators may put credentials/secrets here that even
    #     ingestion agents must not see).
    #   - shared/<anything else> → ALLOW + audit for system class.
    # User class shared/* behavior is unchanged: target stays None,
    # the function returns None below, and the read passes without
    # audit (matches pre-#539 behavior — out of #539 scope).
    if read_intent and current_agent_class() == "system":
        rel_shared = _resolve_under(path, bridge_home_dir() / "shared")
        if rel_shared is not None:
            rel_str = rel_shared.as_posix()
            if rel_str != "." and any(
                rel_str == forbidden.rstrip("/") or rel_str.startswith(forbidden)
                for forbidden in _SHARED_FORBIDDEN_PREFIXES
            ):
                return (
                    "cross-agent access is blocked: shared/private and "
                    "shared/secrets are off-limits even for system-class agents"
                )
            emit_system_cross_agent_read(
                agent=agent,
                target_path=str(path),
                target_agent="",
                tool="Read",
            )
            return None
    target = target_agent_for_path(path, agent)
    if target:
        # Issue #539: class=system agents are allowed read-only access to
        # peer memory/{projects,decisions,shared}/ subtrees. The
        # carve-out fires only for read-intent tools (Read / Glob /
        # Grep / NotebookRead) — Bash/Edit/Write reach this branch with
        # read_intent=False and stay denied. Every allowed read emits a
        # `system_cross_agent_read` audit row so the operator retains a
        # full ledger of cross-agent access.
        if read_intent and current_agent_class() == "system":
            allowed, audit_target = _system_class_cross_agent_read_allowed(path, agent)
            if allowed:
                emit_system_cross_agent_read(
                    agent=agent,
                    target_path=str(path),
                    target_agent=audit_target or target,
                    tool="Read",
                )
                return None
        return f"cross-agent access is blocked: {target}"
    return None


# String-payload option flags: the next argv token (or the `=value` half of
# `--flag=value`) is a literal message body, not a filesystem path the command
# will open. These are the surfaces that fired #252 — a `--body` value that
# merely *mentions* the queue DB path should not be treated as an opener.
_STRING_PAYLOAD_FLAGS = frozenset(
    {
        "--body",
        "-m",
        "--message",
        "--title",
        "-t",
        "--description",
        "--notes",
        "--subject",
    }
)

# File-valued option flags: the next argv token (or `=value`) is the path of a
# file the command is going to read. Codex round-2 on PR #260 caught that
# treating these as skip-only unblocks `gh issue comment --body-file <db>` /
# `git commit -F <roster>`, which really do open the protected file. These
# values must flow through the same path check positional tokens get.
_FILE_VALUED_FLAGS = frozenset(
    {
        "--body-file",
        "-F",
        "--file",
        "--input",
    }
)

# Shell operators that separate commands. `shlex.split(…, posix=True)` does
# not treat `;` / `&&` / `||` / `|` / `&` / newlines as separators, so e.g.
# `sqlite3 /path/file&&echo ok` arrives as a single `/path/file&&echo` token.
# We split each token on these operators so a trailing operator doesn't hide
# a real path argv from the Path comparison below.
_COMMAND_OPERATOR_RE = re.compile(r"&&|\|\||\||;|&|\n")


def _split_command_stages(command: str) -> tuple[list[str], bool]:
    """Split *command* into shell stages, ignoring operators inside quotes.

    Returns ``(stages, balanced)``. ``balanced`` is ``False`` when the
    string ends while still inside an unterminated single or double
    quote — the command is not parseable as written.

    A bare :func:`_COMMAND_OPERATOR_RE.split` is not shell-quote aware: a
    literal operator character inside a single- or double-quoted argument
    — most commonly the ``|`` in an extended-regex alternation such as
    ``grep -nE 'format|codex' <path>`` — is torn into a spurious new
    stage, whose leading token (``codex'``) is unknown, so a read-only
    command is misclassified as write-intent (issue #1054).

    This walks the string once, tracking single/double quote state, and
    only honors an operator match that begins outside any quoted span.
    Quoting semantics match POSIX shells: a single quote is literal (a
    double quote inside it is not a quote), and vice versa; backslash
    escaping is not modelled because the operator regex never matches a
    backslash and an escaped quote inside the *other* quote style is
    already inert. Genuine pipelines / separators outside quotes still
    split exactly as before, so the guard is not weakened.

    An *unbalanced* quote masks every operator after it (the parser stays
    "inside" the quote to end-of-string), which would hide a real
    ``| tee <protected>`` write. The caller must fail closed on
    ``balanced=False`` — an un-parseable command is never a safe read
    (issue #1054 codex r1).
    """
    stages: list[str] = []
    start = 0
    quote: str | None = None
    i = 0
    n = len(command)
    while i < n:
        ch = command[i]
        if quote is not None:
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            i += 1
            continue
        match = _COMMAND_OPERATOR_RE.match(command, i)
        if match:
            stages.append(command[start:i])
            start = match.end()
            i = match.end()
            continue
        i += 1
    stages.append(command[start:])
    return stages, quote is None


# Redirection prefixes that can ride with the path token (`<file`, `>out`,
# `2>err`, `&>log`, `>>append`). We peel the prefix before the expanduser /
# expandvars step so `<{abs task db}>` classifies as a read of the DB, not
# of the literal `<…` string.
_REDIRECTION_PREFIXES = ("&>", "2>", ">>", ">", "<")


def _alias_path_fragments(token: str):
    """Yield filesystem-like fragments hidden inside *token*.

    Splits on shell control operators (`;` / `&&` / `||` / `|` / `&` /
    newline) so a trailing operator does not hide the real path argv.
    Peels a single redirection prefix (`<` / `>` / `>>` / `2>` / `&>`)
    from each resulting fragment so Bash redirection syntax is comparable
    against the protected path.
    """
    for raw in _COMMAND_OPERATOR_RE.split(token):
        fragment = raw.strip()
        if not fragment:
            continue
        for prefix in _REDIRECTION_PREFIXES:
            if fragment.startswith(prefix):
                fragment = fragment[len(prefix):]
                break
        if fragment:
            yield fragment


# Length below which a substring-fallback needle is considered too generic
# to fire on its own — e.g. `hooks/` and `state/cron/` are short enough
# that any heredoc body documenting the hook chain or cron layout will
# trigger them. For such needles we require the character immediately
# preceding the match to be a path-boundary / token-boundary character
# so the match looks like an actual argv-shaped path (``>hooks/foo``,
# ``"hooks/post.sh"``, ``FOO=hooks/x``, ``$(hooks/y)``, ``cmd|hooks/z``,
# or start-of-string) and not prose like ``See hooks/post.sh for
# details`` that follows whitespace. Whitespace is **deliberately
# excluded** from the prefix set: heredoc bodies are the dominant
# source of false-positive shlex failures, and prose mentions inside
# them are always preceded by a space. Real argv writes always have a
# non-whitespace boundary character (redirection ``>``, assignment
# ``=``, quote, parenthesis, separator). Longer needles
# (``.discord/access.json``, ``agent-roster.local.sh``, etc.) are
# specific enough that a plain substring hit is acceptable. Issue #509
# D2 follow-up; tightened for r2 after codex flagged
# ``cat >hooks/foo 'unterminated`` bypassing the original three-char
# prefix set.
_SHORT_NEEDLE_THRESHOLD = 12
_PATH_PREFIX_CHARS = frozenset({
    "/",        # absolute / relative path
    "~",        # home expansion
    "$",        # var expansion
    ">",        # output redirection target (`>hooks/foo`, `&>hooks/foo`)
    "<",        # input redirection target
    "'",        # single-quoted token boundary
    '"',        # double-quoted token boundary
    "(",        # subshell / `$(...)` inner
    "=",        # assignment value (`FOO=hooks/...`)
    "&",        # background / fd redirect prefix (`&>hooks/...`)
    "|",        # pipe boundary
    ";",        # statement separator
    ",",        # comma separator in some shell idioms
})


def _command_substring_hits_protected_needle(command: str) -> bool:
    """Return True iff *command* contains any protected literal suffix in
    a plausible path-argument position.

    Long needles (>= :data:`_SHORT_NEEDLE_THRESHOLD` chars) match on a
    plain substring scan. Short needles fire when the needle sits at
    start-of-string OR is preceded by a token/path-boundary character
    (see :data:`_PATH_PREFIX_CHARS`). Whitespace is intentionally NOT a
    boundary character so heredoc prose like ``It's hooks/post.sh``
    pass — that prose is what triggered the regression operator-side on
    2026-05-03 (issue #509 D2). Real argv writes such as
    ``cat >hooks/foo 'unterminated`` still deny because ``>`` is in the
    prefix set (#509 D2 r2 codex follow-up).
    """
    for needle in protected_literal_suffixes():
        if not needle:
            continue
        if len(needle) >= _SHORT_NEEDLE_THRESHOLD:
            if needle in command:
                return True
            continue
        start = 0
        while True:
            idx = command.find(needle, start)
            if idx < 0:
                break
            if idx == 0:
                # Needle at start-of-string is path-shaped by construction.
                return True
            if command[idx - 1] in _PATH_PREFIX_CHARS:
                return True
            start = idx + 1
    return False


def _command_cd_base_dir(command: str) -> Path | None:
    """Resolve the working directory established by a leading ``cd`` stage.

    Issue #1014 C: a routine diagnostic prelude — ``cd $BRIDGE_HOME &&
    grep BRIDGE agent-roster.local.sh`` — names the protected roster
    file with a CWD-relative path. The argv path check compares each
    token against the protected *absolute* path, so the relative
    ``agent-roster.local.sh`` token never matches and the roster
    allow(read)/deny(write) branch never fires — reads pass by accident
    and, worse, writes pass too (a protected-path bypass).

    This resolves a *simple* leading ``cd <dir>`` prelude so the caller
    can also test relative path fragments against ``<dir>``. Deliberately
    conservative: only a ``cd`` that is the first command stage and has
    exactly one directory argument is honored. A `cd` buried later in
    the pipeline, a `cd` with options, or a `cd -`/`cd ~`-with-no-arg is
    not resolved — those are not the #1014 shape and resolving them would
    widen surface for no benefit. Returns the absolute directory Path or
    None.

    Stage detection uses the raw command string and ``_COMMAND_OPERATOR_RE``
    — the same shell-operator model ``_is_read_intent_bash`` uses — so the
    first stage is recognized regardless of the separator form: ``&&``,
    ``;``, ``||``, ``|``, ``&``, or a newline, with or without surrounding
    whitespace. ``shlex.split`` does NOT emit ``;`` / newline as standalone
    operator tokens in the no-space form (``cd $X;echo`` arrives as a
    single ``$X;echo`` token), so relying on token equality missed those
    shapes (codex r2 catch on PR #1019).
    """
    if not command.strip():
        return None
    # First shell stage = text before the first &&/;/|/||/&/newline.
    first_stage = _COMMAND_OPERATOR_RE.split(command, maxsplit=1)[0].strip()
    if not first_stage:
        return None
    try:
        stage_tokens = shlex.split(first_stage, posix=True, comments=False)
    except ValueError:
        return None
    if len(stage_tokens) < 2 or stage_tokens[0] != "cd":
        return None
    # Exactly one argument: `cd <dir>`. Reject `cd -`, option flags, and
    # multi-arg forms — none are the #1014 prelude shape.
    dir_args = [t for t in stage_tokens[1:] if t]
    if len(dir_args) != 1:
        return None
    raw_dir = dir_args[0]
    if raw_dir.startswith("-"):
        return None
    expanded = os.path.expandvars(os.path.expanduser(raw_dir))
    if not expanded:
        return None
    try:
        candidate = Path(expanded)
    except Exception:
        return None
    if not candidate.is_absolute():
        return None
    return candidate


def _token_matches_protected(
    token: str, protected: Path, base_dir: Path | None = None
) -> bool:
    for fragment in _alias_path_fragments(token):
        expanded = os.path.expandvars(os.path.expanduser(fragment))
        if not expanded:
            continue
        try:
            candidate = Path(expanded)
        except Exception:
            continue
        if candidate == protected:
            return True
        # Issue #1014 C: a CWD-relative fragment under a resolved `cd`
        # prelude — `cd $BRIDGE_HOME && … agent-roster.local.sh` — must
        # also be tested against the prelude directory so a relative
        # reference to the protected file is detected (and the
        # read/write branch then fires correctly).
        if base_dir is not None and not candidate.is_absolute():
            try:
                if (base_dir / candidate) == protected:
                    return True
            except Exception:
                pass
    return False


# === Issue #539 follow-up: Bash carve-out for system-class read-intent ===

# Shell-language constructs that can hide text from shlex argv
# decomposition. When *any* of these is present we refuse to apply the
# system-class peer/shared read carve-out, because a visible allowed
# peer path could mask a smuggled forbidden read inside a `$(...)` body
# or here-string. patch-dev review of plan r3/r4 (2026-05-06) — see PR
# body for the detailed `cat <<< "$(cat .../private/secret.md)"` vector.
#
# Pipes / `&&` / `||` / `;` are deliberately NOT considered embeddings:
# each shell stage stays individually visible to shlex (and to
# `_is_read_intent_bash`, which already classifies stage-by-stage).
_SHELL_EMBEDDING_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"\$\("),       # command substitution `$(...)`
    re.compile(r"`"),          # backticks
    re.compile(r"<\("),        # process substitution (read)
    re.compile(r">\("),        # process substitution (write)
    re.compile(r"<<"),         # heredoc / here-string (covers <<-, <<<)
)


def _command_has_shell_embedding(text: str) -> bool:
    """True iff *text* contains shell-language constructs that can hide
    text from shlex argv decomposition.

    The check runs against the raw text — the embedding tokens (``<<``,
    ``<<<``, ``<(``, ``>(``) are themselves the signals we want to
    catch, so we deliberately do NOT pre-strip safe redirect noise.
    """
    return any(pat.search(text) for pat in _SHELL_EMBEDDING_PATTERNS)


def _peer_alias_list(agent: str) -> list[str]:
    """Return the substring-deny needle list for cross-agent home
    references. Each peer agent contributes six variants (with/without
    trailing slash, expanded vs ``~`` vs ``$HOME``). Stable order so
    deny messages are deterministic.
    """
    home_root = agent_home_root()
    aliases: list[str] = []
    for other in other_agent_homes(agent):
        aliases.extend(
            (
                f"{home_root}/{other.name}/",
                f"{home_root}/{other.name}",
                f"~/.agent-bridge/agents/{other.name}/",
                f"~/.agent-bridge/agents/{other.name}",
                f"$HOME/.agent-bridge/agents/{other.name}/",
                f"$HOME/.agent-bridge/agents/{other.name}",
            )
        )
    return aliases


def _shared_forbidden_aliases() -> list[str]:
    """Return the substring-deny list for ``shared/private/`` and
    ``shared/secrets/``. Includes absolute, ``~``, and ``$HOME``
    variants — both with and without a trailing slash — so a bare
    directory reference (``ls $BRIDGE_HOME/shared/private``) cannot
    bypass the gate. patch-dev review of 94711d3 caught the
    no-slash variant gap.
    """
    bridge_home = bridge_home_dir()
    aliases: list[str] = []
    for forbidden in _SHARED_FORBIDDEN_PREFIXES:
        rel = forbidden.rstrip("/")
        aliases.extend(
            (
                f"{bridge_home}/shared/{rel}/",
                f"{bridge_home}/shared/{rel}",
                f"~/.agent-bridge/shared/{rel}/",
                f"~/.agent-bridge/shared/{rel}",
                f"$HOME/.agent-bridge/shared/{rel}/",
                f"$HOME/.agent-bridge/shared/{rel}",
            )
        )
    return aliases


def _bash_token_resolved_paths(token: str) -> list[Path]:
    """Return resolved Paths for the path-shaped fragments of *token*.

    Mirrors `_token_matches_protected`'s expansion logic but yields
    Path objects instead of running an equality check, so the caller
    can run any decision against them.
    """
    out: list[Path] = []
    for fragment in _alias_path_fragments(token):
        expanded = os.path.expandvars(os.path.expanduser(fragment))
        if not expanded:
            continue
        try:
            out.append(Path(expanded))
        except Exception:
            continue
    return out


def _bash_argv_protected_decisions(
    text: str,
    agent: str,
) -> tuple[list[tuple[Path, str, str]], bool] | None:
    """Walk shlex tokens in *text* with the same skip / treat-as-value
    rules as `_bash_argv_references_path`. For every non-skipped token,
    resolve to one or more Paths. For Paths that land in another
    agent's home, run `_system_class_cross_agent_read_allowed` and
    record the decision.

    Returns ``None`` when shlex.split() raises (caller falls through to
    the substring deny). Otherwise returns ``(decisions, all_allowed)``:

    - ``decisions`` is a list of ``(path, audit_target, peer_key)``
      triples for every peer-agent token the carve-out admits.
      ``peer_key`` is the peer agent name — a stable string used by the
      text-occurrence proof step to compare counts without depending on
      symlink-resolved absolute paths (e.g. macOS ``/var`` →
      ``/private/var``).
    - ``all_allowed`` is False as soon as one resolved peer token sits
      outside the carve-out (peer outside ``memory/{projects,decisions,
      shared}/``).

    Shared/* tokens are deliberately NOT collected: shared/non-forbidden
    is broadly readable across classes (the file-tool carve-out emits
    audits for system-class shared reads — Bash-side shared audits are
    follow-up scope). Shared/private|shared/secrets are caught earlier
    by the unconditional Stage A substring deny.
    """
    home_root = agent_home_root()

    try:
        tokens = shlex.split(text, posix=True, comments=False)
    except ValueError:
        return None

    decisions: list[tuple[Path, str, str]] = []
    all_allowed = True

    def _classify_peer(path: Path) -> tuple[bool, str, str] | None:
        """Return (allowed, audit_target, peer_key) for cross-agent peer
        paths; None for paths outside the cross-agent territory."""
        rel_agent = _resolve_under(path, home_root)
        if rel_agent is None:
            return None
        parts = rel_agent.parts
        if not parts:
            return None
        peer = parts[0]
        if peer == agent:
            return None  # self-home, not a cross-agent reference
        allowed, audit_target = _system_class_cross_agent_read_allowed(
            path, agent
        )
        return allowed, audit_target, peer

    def _process_value(value: str) -> None:
        nonlocal all_allowed
        for path in _bash_token_resolved_paths(value):
            verdict = _classify_peer(path)
            if verdict is None:
                continue
            allowed, audit_target, peer_key = verdict
            if not allowed:
                all_allowed = False
                continue
            decisions.append((path, audit_target, peer_key))

    skip_next_payload = False
    treat_next_as_value = False
    for tok in tokens:
        if skip_next_payload:
            skip_next_payload = False
            continue
        if treat_next_as_value:
            treat_next_as_value = False
            _process_value(tok)
            continue
        if tok in _STRING_PAYLOAD_FLAGS:
            skip_next_payload = True
            continue
        if tok in _FILE_VALUED_FLAGS:
            treat_next_as_value = True
            continue
        if tok.startswith("--") and "=" in tok:
            flag, _, value = tok.partition("=")
            if flag in _STRING_PAYLOAD_FLAGS:
                continue
            _process_value(value)
            continue
        _process_value(tok)

    return decisions, all_allowed


def _argv_occurrences_explain_text(
    text: str,
    peer_aliases: list[str],
    decisions: list[tuple[Path, str, str]],
) -> bool:
    """Return True iff every peer-alias substring occurrence in *text*
    is exactly accounted for by a decision in *decisions*.

    Both sides key on the peer agent name (the last segment of the
    alias, also `decisions[*][2]`). Multiple alias variants pointing at
    the same peer collapse to the same key. Counts must match — if
    text mentions peer X twice but only one argv token resolved to
    peer X, a smuggle (e.g. second occurrence inside a quoted blob the
    argv parser cannot surface) is suspected.

    Variants overlap (the no-trailing-slash form is a prefix of the
    trailing-slash form). We sort by length descending and "consume"
    matched ranges with NUL so the shorter form doesn't double-count.
    """
    sorted_aliases = sorted(peer_aliases, key=len, reverse=True)

    def _peer_for_alias(alias: str) -> str:
        return alias.rstrip("/").rsplit("/", 1)[-1]

    consumed = list(text)
    text_count: dict[str, int] = {}
    for alias in sorted_aliases:
        peer = _peer_for_alias(alias)
        if not peer:
            continue
        n = len(alias)
        i = 0
        while True:
            joined = "".join(consumed)
            idx = joined.find(alias, i)
            if idx < 0:
                break
            for k in range(idx, idx + n):
                consumed[k] = "\0"
            text_count[peer] = text_count.get(peer, 0) + 1
            i = idx + n

    decision_count: dict[str, int] = {}
    for _path, _audit, peer_key in decisions:
        decision_count[peer_key] = decision_count.get(peer_key, 0) + 1

    for peer in set(text_count) | set(decision_count):
        if text_count.get(peer, 0) != decision_count.get(peer, 0):
            return False
    return True


def _bash_argv_references_path(command: str, protected: Path) -> bool:
    """Return True if *command*, interpreted as shell argv, names
    *protected* as a filesystem argument — either positionally or as the
    value of a file-valued option flag like ``--body-file`` / ``-F``.

    Behaviour contract (round-2 of PR #260 review):

    - shlex-split the command into tokens.
    - Skip tokens consumed by string-payload option flags
      (``--body`` / ``-m`` / ``--message`` / ``--description`` /
      ``--title`` / ``--notes`` / ``--subject``) — these are message
      bodies the command sends somewhere else, not paths it opens.
      The ``--flag=value`` packed form is skipped whole for the same
      reason.
    - Treat file-valued option flags (``--body-file`` / ``-F`` /
      ``--file`` / ``--input``) as if the next token (or ``=value``
      half) were positional: run the same path check over it.
      Codex r2 caught that skipping these unblocked direct reads of
      the protected file.
    - Normalise every remaining positional token via
      :func:`_alias_path_fragments` (strip trailing shell operators,
      peel redirection prefixes) before the ``expanduser + expandvars
      + Path ==`` comparison. ``sqlite3 /db;``, ``cat <db``, and
      ``sqlite3 /db&& echo ok`` all surface the protected path.
    - A ``shlex.split`` ``ValueError`` (unbalanced quotes etc.) falls
      back to a substring match against the absolute path so an
      evasion attempt via malformed shell is not strictly weaker than
      the pre-#252 check.
    """
    protected_str = str(protected)
    if not protected_str:
        return False
    try:
        tokens = shlex.split(command, posix=True, comments=False)
    except ValueError:
        return protected_str in command

    # Issue #1014 C: resolve a leading `cd <dir>` prelude so a CWD-relative
    # reference to the protected file (`cd $BRIDGE_HOME && … agent-roster
    # .local.sh`) is detected, not silently missed. Pass the RAW command —
    # the prelude detector splits on the shell-operator model so `;` /
    # newline separators (no-space forms) are recognized too.
    cd_base_dir = _command_cd_base_dir(command)

    def _check_value_token(value: str) -> bool:
        return _token_matches_protected(value, protected, cd_base_dir)

    skip_next_payload = False
    treat_next_as_value = False
    for tok in tokens:
        if skip_next_payload:
            skip_next_payload = False
            continue
        if treat_next_as_value:
            treat_next_as_value = False
            if _check_value_token(tok):
                return True
            continue
        if tok in _STRING_PAYLOAD_FLAGS:
            skip_next_payload = True
            continue
        if tok in _FILE_VALUED_FLAGS:
            # Next argv word is the file path the command will read.
            treat_next_as_value = True
            continue
        if tok.startswith("--") and "=" in tok:
            flag, _, value = tok.partition("=")
            if flag in _STRING_PAYLOAD_FLAGS:
                # --body=foo: value is a literal message body, skip.
                continue
            if flag in _FILE_VALUED_FLAGS:
                # --body-file=<path>: value is a filesystem read, check it.
                if _check_value_token(value):
                    return True
                continue
            # Unknown --flag=value: fall through and check the value as if
            # it were positional. Safer to block a real opener than to let
            # a novel gh/git flag escape the check.
            if _check_value_token(value):
                return True
            continue
        if _token_matches_protected(tok, protected, cd_base_dir):
            return True
    return False


def _bash_argv_references_system_config(command: str) -> bool:
    """Return True if any positional/file-valued argv token in *command*
    points at a path that :func:`is_protected_path` matches.

    Uses the same skip/treat rules as ``_bash_argv_references_path`` so a
    `--body "agents/foo/.discord/access.json"` mention does not trigger.
    A `shlex.split` ``ValueError`` (unbalanced quotes etc.) falls back to
    a substring scan of the literal suffixes derived from
    :func:`system_config_paths.protected_literal_suffixes` — the single
    source of truth. The fallback is weaker than the structural argv
    check but keeps us no worse than the pre-#341 baseline, and it
    cannot drift from ``PROTECTED_GLOBS`` because the suffix list is
    derived at call time.
    """
    if not command:
        return False
    try:
        tokens = shlex.split(command, posix=True, comments=False)
    except ValueError:
        # Substring fallback: shlex rejected the command (commonly an
        # unbalanced apostrophe inside a heredoc body — `It's foo` etc.).
        # The shorter needles in protected_literal_suffixes (`hooks/`,
        # `state/cron/`) match too eagerly when prose mentions them
        # mid-sentence (e.g. a handoff body that documents the hook
        # chain). Require each needle to sit at a path-boundary:
        # start-of-string or preceded by a token-boundary character
        # (redirection `>`/`<`, quote, paren, assignment `=`, fd `&`,
        # pipe `|`, separator `;`/`,`, plus the original `/`, `~`, `$`).
        # Whitespace is deliberately excluded so heredoc prose preceded
        # by a space still passes — see _PATH_PREFIX_CHARS for rationale.
        return _command_substring_hits_protected_needle(command)

    # Issue #1014 C: resolve a leading `cd <dir>` prelude so a CWD-relative
    # reference to a protected system-config file is detected — same
    # bypass class as the roster path in _bash_argv_references_path. Pass
    # the RAW command so `;` / newline separators are recognized.
    cd_base_dir = _command_cd_base_dir(command)

    def _check_value(value: str) -> bool:
        for fragment in _alias_path_fragments(value):
            expanded = os.path.expandvars(os.path.expanduser(fragment))
            if not expanded:
                continue
            try:
                candidate = Path(expanded)
            except Exception:
                continue
            if is_protected_path(candidate):
                return True
            if cd_base_dir is not None and not candidate.is_absolute():
                try:
                    if is_protected_path(cd_base_dir / candidate):
                        return True
                except Exception:
                    pass
        return False

    skip_next_payload = False
    treat_next_as_value = False
    for tok in tokens:
        if skip_next_payload:
            skip_next_payload = False
            continue
        if treat_next_as_value:
            treat_next_as_value = False
            if _check_value(tok):
                return True
            continue
        if tok in _STRING_PAYLOAD_FLAGS:
            skip_next_payload = True
            continue
        if tok in _FILE_VALUED_FLAGS:
            treat_next_as_value = True
            continue
        if tok.startswith("--") and "=" in tok:
            flag, _, value = tok.partition("=")
            if flag in _STRING_PAYLOAD_FLAGS:
                continue
            if flag in _FILE_VALUED_FLAGS:
                if _check_value(value):
                    return True
                continue
            if _check_value(value):
                return True
            continue
        if _check_value(tok):
            return True
    return False


def _is_config_set_wrapper(text: str) -> bool:
    """True iff *text* is the sanctioned ``agent-bridge config set`` /
    ``agb config set`` wrapper invocation as a single, side-effect-free
    shell command.

    The hook normally denies any Bash command whose argv mentions a
    protected path. That blocks the very wrapper #341 prescribes:
    ``agent-bridge config set --path <protected> --change ...`` was
    routed through `_bash_argv_references_path()` and rejected because
    the protected path appears as the wrapper's argument — wrapper
    self-block deadlock, even for admin (the deny message itself points
    operators back at the same wrapper they were trying to call).

    The wrapper layers its own gate (`bridge-config.py:detect_caller_source`
    + before/after sha256 audit row), so once we let it through the hook
    the only thing that changes is "audit chain stops being doubled".
    A non-operator caller still gets denied at the wrapper.

    Match shape (strict — codex r2 #726):

    - The text contains *no* shell separators (`;` / `&&` / `||` / `|` /
      `&` / newline). Multi-command pipelines drop straight back to the
      regular path-argv gate so a trailing `; sqlite3 .../tasks.db
      .dump` cannot ride through.
    - The text contains *no* shell embeddings — command substitution
      (``$(...)`` / backticks), process substitution (``<(...)`` /
      ``>(...)``), heredoc / here-string (``<<`` / ``<<<``).
      ``--change foo=$(sqlite3 .../tasks.db .dump)`` would otherwise
      let the shell read the queue DB before the wrapper even starts.
    - The text contains *no* I/O redirection tokens (``>`` / ``>>`` /
      ``<`` / ``&>``, 2>`` other than the SAFE stderr-discard forms).
      ``... > ~/.agent-bridge/agent-roster.local.sh`` would otherwise
      let the shell open/truncate the protected file before any
      argv-side gate runs.
    - shlex tokens[0] leaf is ``agent-bridge`` or ``agb`` (path prefix
      tolerated).
    - Subcommand sits at the strict positional ``tokens[1] == "config"``
      and ``tokens[2] == "set"``. A later embedded ``config set`` inside
      a different subcommand's argv (e.g. ``agent-bridge wave run config
      set``) does not fire the carve-out.

    ``config get`` / ``config list-protected`` keep the existing
    read-intent carve-out — this helper is only for the write surface
    that the path-argv gate would otherwise self-block.
    """
    # Reject shell embeddings on raw text first. `_command_has_shell_embedding`
    # catches `$(...)`, backticks, `<(...)`, `>(...)`, `<<` / `<<<` — these
    # are the signals we want, so we deliberately don't pre-sanitize. Same
    # threat shape as multi-command pipelines: the shell evaluates the
    # embedded command before the wrapper process even runs, so
    # bridge-config.py cannot guard the file the subshell opens (codex
    # r2 #726).
    if _command_has_shell_embedding(text):
        return False
    # Strip the safe stderr-suppression / fd-dup tokens BEFORE the
    # multi-command and redirection checks. `2>&1` legitimately contains
    # the `&` token-boundary character that `_COMMAND_OPERATOR_RE` would
    # otherwise read as a backgrounding signal, and `2>/dev/null` looks
    # like output redirection but cannot mutate the filesystem. The safe
    # forms must remain allowed for the carve-out to be useful in
    # `2>/dev/null`-suffixed wrapper invocations.
    sanitized = _SAFE_REDIRECT_RE.sub(" ", text)
    # Reject *any* remaining `<` / `>` after the safe-redirect strip.
    # bash accepts arbitrary numeric file-descriptor prefixes
    # (`1>`, `0<`, `3<`, `9>>`, `3<>`, ...) — the codex r3 #726 review
    # caught that the previous per-token `tok.startswith(">")` check
    # missed `1>`, `0<`, etc. and let the shell open/truncate/read a
    # protected path before the wrapper started. Any `<` or `>` outside
    # the safe-redirect forms means the shell is doing I/O the wrapper
    # cannot guard.
    if "<" in sanitized or ">" in sanitized:
        return False
    # Reject multi-command pipelines. shlex does not treat shell
    # operators as separators — `agent-bridge config set --path X;
    # sqlite3 .../tasks.db .dump` arrives as one shlex run, and a naive
    # leaf check would hand the whole text a None reason and let the
    # second command bypass the queue-DB / system-config gates. The
    # carve-out only applies when the wrapper invocation stands alone.
    if _COMMAND_OPERATOR_RE.search(sanitized):
        return False
    try:
        tokens = shlex.split(sanitized, posix=True, comments=False)
    except ValueError:
        return False
    if len(tokens) < 3:
        return False
    leaf = tokens[0].rsplit("/", 1)[-1]
    if leaf not in {"agent-bridge", "agb"}:
        return False
    return tokens[1] == "config" and tokens[2] == "set"


def protected_alias_reason(
    text: str,
    agent: str,
    tool_input: dict[str, Any] | None = None,
) -> str | None:
    admin = is_admin_agent(agent)
    # The two checks below use shlex argv matching rather than substring
    # matching (closes #252). A Bash invocation that actually opens the
    # protected file still has to name the real path as a positional
    # argument; a mention inside a message body (`--body "…"`, `-m "…"`,
    # `--description "…"`, etc.) is skipped. `protected_path_reason`
    # continues to guard the non-Bash tool surfaces (Read/Write) with the
    # structurally-correct `Path ==` check.
    #
    # Order mirrors `protected_path_reason`: narrow roster / queue DB
    # messages first so existing smoke tests find their specific wording,
    # then the issue #341 generic system-config gate.
    #
    # Issue #383: classify the whole pipeline once. Read-intent (cat /
    # grep / head / tail / `agent-bridge config get` / etc.) bypasses
    # the roster + system-config gates; #341's audit chain only
    # protects WRITES, so a read should never be denied. The queue DB
    # gate stays unconditional — `agb` queue commands are the
    # structured-read surface and direct sqlite reads still bypass that
    # contract.
    # Classify read-intent once, up front: the admin-credential-read
    # carve-out below needs the same classification the protected-path
    # gate uses, and there's no benefit to recomputing it after each
    # deny. Read-intent means every pipeline stage's leading command is
    # in `_READ_INTENT_BASH_COMMANDS` (cat / ls / stat / grep / head /
    # tail / etc.) — `sed -i` / `awk -i inplace` / any output
    # redirection disqualifies the whole invocation. See
    # `_is_read_intent_bash` for the full contract.
    read_intent = _is_read_intent_bash(text)
    if _raw_mentions_claude_credentials(text):
        # Admin agents are the operator's deputy: their read-intent
        # diagnostic commands (e.g. `ls ~/.claude/.credentials.json`,
        # `stat $BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json`)
        # need to succeed for credential-state triage. The deny stays
        # in force for write-intent commands and for non-admin agents.
        # Every bypass writes an audit row.
        if admin and read_intent:
            _emit_admin_credential_read_allowed(
                agent,
                tool="Bash",
                surface="raw_credentials_mention",
                sample=text,
                tool_input=tool_input,
            )
        else:
            return CLAUDE_CREDENTIAL_DENY_REASON
    # PR #799 r3 codex finding 1 — env-dump verbs revealed exported
    # OAuth tokens under the abandoned env-token path, bypassing the
    # substring deny above. Kept as a stale-env/manual-export guard.
    if _raw_dumps_process_environment(text):
        # Admin diagnostics may legitimately `env | grep BRIDGE_` or
        # `printenv` to inspect runtime state. Allowed only when the
        # pipeline is purely read-intent — the same gate keeps a
        # compromised admin from `env > /tmp/leak.txt`-style writes
        # because output redirection drops the read-intent flag.
        if admin and read_intent:
            _emit_admin_credential_read_allowed(
                agent,
                tool="Bash",
                surface="raw_env_dump",
                sample=text,
                tool_input=tool_input,
            )
        else:
            return CLAUDE_CREDENTIAL_DENY_REASON
    for credential_path in claude_credential_paths():
        if _bash_argv_references_path(text, credential_path):
            # Admin read-intent argv reference to a credential file
            # (e.g. `cat ~/.claude/.credentials.json | jq .`) — allow
            # with an audit row. Non-admin / write-intent stay denied.
            if admin and read_intent:
                _emit_admin_credential_read_allowed(
                    agent,
                    tool="Bash",
                    surface="argv_path",
                    sample=str(credential_path),
                    tool_input=tool_input,
                )
                break
            return CLAUDE_CREDENTIAL_DENY_REASON
    # Wrapper self-block carve-out: the sanctioned `agent-bridge config
    # set` wrapper layers its own caller-source + audit gate
    # (bridge-config.py). Without this carve-out the path-argv check
    # below denies the wrapper invocation because the protected path
    # appears as the wrapper's --path argument — leaving operators in a
    # deadlock where the deny message points back at the same wrapper
    # they just tried to call. Letting the wrapper through here only
    # delegates audit responsibility to the wrapper itself; non-operator
    # callers still get rejected at bridge-config.py.
    if _is_config_set_wrapper(text):
        return None
    if _bash_argv_references_path(text, roster_local_path()):
        if read_intent:
            return None
        # Admin no longer bypasses the roster path (codex r1 #341 CP2);
        # mutations route through `agent-bridge config set`.
        if admin:
            return ROSTER_LOCAL_DENY_REASON
        return "shared roster secrets are not available inside Claude tool calls"
    if _bash_argv_references_path(text, task_db_path()):
        return "direct queue DB access is blocked; use `agb` queue commands instead"
    # Issue #341: system-config paths get the same argv-based check; the
    # wrapper command is the only normal mutation surface for writes.
    # Read-intent is allowed for all agents — see #383.
    if _bash_argv_references_system_config(text):
        if read_intent:
            return None
        return SYSTEM_CONFIG_DENY_REASON
    if admin:
        return None

    # Issue #539 follow-up — Stage A: shared/private/ and shared/secrets/
    # are off-limits for every non-admin agent regardless of class.
    # Substring deny because the path can ride inside a heredoc body or
    # a quoted blob the argv parser cannot surface as a clean token.
    for forbidden_alias in _shared_forbidden_aliases():
        if forbidden_alias in text:
            return (
                "cross-agent access is blocked: shared/private and "
                "shared/secrets are off-limits"
            )

    # Stage B: peer-agent-home substring deny with a system-class
    # read-intent exception path. The default stance is deny: a system-
    # class agent earns the carve-out only when (1) the command is
    # smuggle-free and (2) every alias substring in raw text is
    # explained by a clean argv token whose resolved Path satisfies
    # `_system_class_cross_agent_read_allowed`.
    peer_aliases = _peer_alias_list(agent)
    matched_alias = next((a for a in peer_aliases if a in text), None)
    if matched_alias is None:
        return None

    if not (read_intent and current_agent_class() == "system"):
        return f"cross-agent access is blocked: {matched_alias}"

    if _command_has_shell_embedding(text):
        return f"cross-agent access is blocked: {matched_alias}"

    decisions_and_flag = _bash_argv_protected_decisions(text, agent)
    if decisions_and_flag is None:
        return f"cross-agent access is blocked: {matched_alias}"

    decisions, all_allowed = decisions_and_flag
    if not all_allowed:
        return f"cross-agent access is blocked: {matched_alias}"

    if not _argv_occurrences_explain_text(text, peer_aliases, decisions):
        return f"cross-agent access is blocked: {matched_alias}"

    for path, audit_target, _peer_key in decisions:
        emit_system_cross_agent_read(
            agent=agent,
            target_path=str(path),
            target_agent=audit_target,
            tool="Bash",
        )
    return None


def tool_input_summary(tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
    if tool_name == "Bash":
        return {
            "command": truncate_text(str(tool_input.get("command") or ""), 240),
            "description": truncate_text(str(tool_input.get("description") or ""), 120),
        }
    for key in ("file_path", "path", "pattern", "url", "subagent_type", "description"):
        value = tool_input.get(key)
        if value:
            return {key: truncate_text(str(value), 240)}
    return {"summary": truncate_text(json.dumps(tool_input, ensure_ascii=False, sort_keys=True), 240)}


def pretool_block_response(reason: str, detail: dict[str, Any]) -> None:
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


def _system_config_path_from_input(tool_name: str, tool_input: dict[str, Any]) -> Path | None:
    """Return the protected-path argument that triggered the hook deny.

    Read from `file_path` / `path` for non-Bash tools; for Bash, scan the
    shlex-tokenised command for the first token that resolves under the
    protected list. Returns None when no protected path is identifiable —
    in that case the audit row falls back to a path-less detail.
    """
    if tool_name != "Bash":
        for key in ("file_path", "path"):
            raw = str(tool_input.get(key) or "").strip()
            if not raw:
                continue
            try:
                candidate = Path(raw).expanduser()
            except Exception:
                continue
            if is_protected_path(candidate):
                return candidate
        return None
    command = str(tool_input.get("command") or "")
    try:
        tokens = shlex.split(command, posix=True, comments=False)
    except ValueError:
        return None
    for tok in tokens:
        for fragment in _alias_path_fragments(tok):
            expanded = os.path.expandvars(os.path.expanduser(fragment))
            if not expanded:
                continue
            try:
                candidate = Path(expanded)
            except Exception:
                continue
            if is_protected_path(candidate):
                return candidate
    return None


def _path_sha256(path: Path) -> str:
    """sha256 of *path* contents, or empty string if unreadable.

    The hook records the at-rest sha as `before_sha256`. There is
    intentionally no `after_sha256` on hook-deny rows — the change was
    prevented, so there is no "after" state to record (codex r1 #341
    CP3). The wrapper-apply row is the only place `after_sha256` is
    meaningful.
    """
    try:
        import hashlib
        with path.open("rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return ""


def _write_system_config_audit_row(
    agent: str,
    tool_name: str,
    tool_input: dict[str, Any],
    target_path: Path | None,
) -> None:
    """Write the issue #341 `system_config_mutation` audit row.

    Shape mirrors the brief: actor, actor_source, trigger, path,
    before_sha256, operation. ``after_sha256`` is intentionally omitted
    on hook-deny — no mutation occurred, so an "after" hash would
    misrepresent the audit chain (codex r1 #341 CP3). Hook-side
    actor_source is always `agent-direct` — the hook fires before any
    caller-source promotion that the wrapper would otherwise apply.
    """
    if target_path is None:
        path_str = ""
        before = ""
    else:
        path_str = str(target_path)
        before = _path_sha256(target_path)
    if tool_name == "Bash":
        operation = truncate_text(str(tool_input.get("command") or ""), 240)
    else:
        operation = json.dumps(
            {
                key: truncate_text(str(value), 120)
                for key, value in tool_input.items()
                if value
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    detail = {
        "kind": "system_config_mutation",
        "actor": agent or "unknown",
        "actor_source": "agent-direct",
        "trigger": "hook-deny",
        "path": path_str,
        "before_sha256": before,
        "operation": truncate_text(operation, 240),
        "tool_name": tool_name,
        "matched_pattern": matched_pattern(target_path) or "" if target_path else "",
    }
    write_audit("system_config_mutation", agent or "unknown", detail)


def handle_pretool(payload: dict[str, Any], agent: str) -> int:
    tool_name = str(payload.get("tool_name") or "")
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        return 0

    reason: str | None = None
    detail = {
        "agent": agent,
        "tool_name": tool_name,
        "tool_use_id": str(payload.get("tool_use_id") or ""),
        "session_id": str(payload.get("session_id") or ""),
        "summary": tool_input_summary(tool_name, tool_input),
    }
    target_agent = detect_target_agent(tool_name, tool_input, agent)
    if target_agent:
        detail["target_agent"] = target_agent

    if tool_name == "Bash":
        reason = protected_alias_reason(
            str(tool_input.get("command") or ""),
            agent,
            tool_input=tool_input,
        )
    else:
        # Classify read-intent once for the whole non-Bash branch — both
        # the credential carve-out below and the protected-path gate
        # that follows need the same classification. Read / Glob / Grep
        # / NotebookRead are read-intent; Edit / Write / MultiEdit /
        # NotebookEdit and unknown tools are write-intent.
        read_intent = _is_read_intent_tool(tool_name, tool_input)
        admin = is_admin_agent(agent)
        for key in ("file_path", "path", "pattern"):
            raw = str(tool_input.get(key) or "").strip()
            if not raw:
                continue
            if _raw_mentions_claude_credentials(raw):
                # Admin + read-intent (Read / Glob / Grep /
                # NotebookRead) diagnostic on a credential surface —
                # allow with an audit row. Mutating tools (Edit / Write
                # / NotebookEdit) and non-admin agents stay denied.
                if admin and read_intent:
                    _emit_admin_credential_read_allowed(
                        agent,
                        tool=tool_name,
                        surface="input_path",
                        sample=raw,
                        tool_input=tool_input,
                    )
                    continue
                reason = CLAUDE_CREDENTIAL_DENY_REASON
                break
            if key in ("file_path", "path"):
                try:
                    candidate = Path(raw).expanduser()
                except Exception:
                    continue
                credential_reason = claude_credentials_reason_for_path(candidate)
                if credential_reason:
                    # Same carve-out logic for the path-typed credential
                    # check: admin diagnostic Read of `.credentials.json`
                    # (or any path resolved by `claude_credential_paths`)
                    # is allowed and audited; mutations stay denied.
                    if admin and read_intent:
                        _emit_admin_credential_read_allowed(
                            agent,
                            tool=tool_name,
                            surface="input_path",
                            sample=str(candidate),
                            tool_input=tool_input,
                        )
                        continue
                    reason = credential_reason
                    break

        if reason is None:
            # Issue #383: Read / Glob / Grep / NotebookRead tools get the
            # read-intent allowance on protected paths. Edit / Write /
            # NotebookEdit and unknown tools stay write-intent.
            # `read_intent` was already classified above for the
            # credential carve-out — reuse it.
            for key in ("file_path", "path"):
                raw = str(tool_input.get(key) or "").strip()
                if not raw:
                    continue
                try:
                    candidate = Path(raw).expanduser()
                except Exception:
                    continue
                reason = protected_path_reason(candidate, agent, read_intent=read_intent)
                if reason:
                    break

    if reason:
        detail["reason"] = reason
        write_audit("agent_tool_denied", agent or "unknown", detail)
        # Both the generic system-config deny and the more-specific
        # roster-local deny (codex r1 #341 CP2) are protected-path
        # mutations and need a `system_config_mutation` audit row so
        # the operator can attribute the attempt.
        if reason in (SYSTEM_CONFIG_DENY_REASON, ROSTER_LOCAL_DENY_REASON):
            _write_system_config_audit_row(
                agent,
                tool_name,
                tool_input,
                _system_config_path_from_input(tool_name, tool_input),
            )
        pretool_block_response(reason, detail)
        return 0
    return 0


def handle_posttool_common(payload: dict[str, Any], agent: str, action: str) -> None:
    tool_name = str(payload.get("tool_name") or "")
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    detail = {
        "agent": agent,
        "tool_name": tool_name,
        "tool_use_id": str(payload.get("tool_use_id") or ""),
        "session_id": str(payload.get("session_id") or ""),
        "cwd": str(payload.get("cwd") or current_agent_workdir()),
        "summary": tool_input_summary(tool_name, tool_input),
    }
    target_agent = detect_target_agent(tool_name, tool_input, agent)
    if target_agent:
        detail["target_agent"] = target_agent
    if action == "agent_tool_failure":
        detail["error"] = truncate_text(str(payload.get("error") or ""), 240)
        detail["is_interrupt"] = bool(payload.get("is_interrupt"))
    write_audit(action, agent or "unknown", detail)


def handle_posttool(payload: dict[str, Any], agent: str) -> int:
    handle_posttool_common(payload, agent, "agent_tool_use")
    tool_name = str(payload.get("tool_name") or "")
    if is_builtin_tool(tool_name):
        return 0
    if not prompt_guard_enabled():
        return 0

    threshold = threshold_for_surface("mcp_output", "high")
    text = tool_output_text(tool_name, payload.get("tool_response"))
    scan = analyze_text(text, threshold=threshold, surface="mcp_output", agent=agent)
    if scan.blocked:
        write_audit(
            "prompt_guard_blocked",
            agent or "unknown",
            {
                "surface": "mcp_output",
                "tool_name": tool_name,
                "severity": scan.severity,
                "threshold": scan.threshold,
                "reasons": scan.reasons[:5],
            },
        )
        json.dump(
            {
                "decision": "block",
                "reason": f"Prompt guard blocked MCP output ({scan.severity}): {', '.join(scan.reasons[:3]) or 'policy match'}",
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": "The MCP tool output was blocked before entering Claude context.",
                },
            },
            sys.stdout,
            ensure_ascii=False,
        )
        sys.stdout.write("\n")
        return 0

    sanitize = sanitize_text(text, surface="mcp_output", agent=agent)
    if sanitize.blocked:
        write_audit(
            "prompt_guard_canary_triggered",
            agent or "unknown",
            {
                "surface": "mcp_output",
                "tool_name": tool_name,
                "canary_tokens": sanitize.canary_tokens,
            },
        )
        json.dump(
            {
                "decision": "block",
                "reason": "Prompt guard blocked MCP output due to canary token leakage.",
            },
            sys.stdout,
            ensure_ascii=False,
        )
        sys.stdout.write("\n")
        return 0

    if sanitize.was_modified and isinstance(payload.get("tool_response"), str):
        write_audit(
            "prompt_guard_sanitized",
            agent or "unknown",
            {
                "surface": "mcp_output",
                "tool_name": tool_name,
                "redacted_types": sanitize.redacted_types,
                "redaction_count": sanitize.redaction_count,
            },
        )
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": "Prompt guard sanitized sensitive MCP output before it entered context.",
                    "updatedMCPToolOutput": sanitize.sanitized_text,
                }
            },
            sys.stdout,
            ensure_ascii=False,
        )
        sys.stdout.write("\n")
    return 0


def handle_posttool_failure(payload: dict[str, Any], agent: str) -> int:
    handle_posttool_common(payload, agent, "agent_tool_failure")
    return 0


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    agent = current_agent()
    event = str(payload.get("hook_event_name") or "")
    if not agent or not event:
        return 0

    if event == "PreToolUse":
        return handle_pretool(payload, agent)
    if event == "PostToolUse":
        return handle_posttool(payload, agent)
    if event == "PostToolUseFailure":
        return handle_posttool_failure(payload, agent)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
