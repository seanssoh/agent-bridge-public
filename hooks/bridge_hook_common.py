#!/usr/bin/env python3
"""Shared Agent Bridge hook helpers for Claude Code and Codex."""

from __future__ import annotations

import functools
import hashlib
import importlib.util
import json
import os
import pwd
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Optional

PRIORITY_ORDER = {"urgent": 0, "high": 1, "normal": 2, "low": 3}

# Exact keys from bridge_render_template_string (bridge-agent.sh) that are
# substituted at scaffold time. Stored as frozenset for O(1) membership checks.
# Do NOT replace with a generic <…> regex — managed docs intentionally contain
# non-placeholder angle-bracket tokens such as <user-id>, <self>, <task_id>,
# <agent-home>, and <configured-admin-agent>.
IDENTITY_PLACEHOLDER_PATTERNS: frozenset[str] = frozenset({
    "<Agent Name>",
    "<agent-id>",
    "<Role>",
    "<Role Summary>",
    "<Runtime>",
    "<Boss>",
    "<한 줄 역할 설명>",
    "<표시 이름>",
    "<Session Type>",
    "<핵심 책임>",
    "<주 요청자>",
    "<Claude Code CLI | Codex CLI>",
    "<반드시 지킬 운영 규칙>",
    "<위험 작업 제한>",
    "<보고 방식>",
})


def bridge_task_db() -> Path:
    explicit = os.environ.get("BRIDGE_TASK_DB", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()
    if bridge_home:
        return Path(bridge_home).expanduser() / "state" / "tasks.db"
    return Path.home() / ".agent-bridge" / "state" / "tasks.db"


def bridge_state_dir() -> Path:
    explicit = os.environ.get("BRIDGE_STATE_DIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()
    if bridge_home:
        return Path(bridge_home).expanduser() / "state"
    return Path.home() / ".agent-bridge" / "state"


def bridge_active_agent_dir() -> Path:
    # Matches bridge-lib.sh:32 —
    #   BRIDGE_ACTIVE_AGENT_DIR="${BRIDGE_ACTIVE_AGENT_DIR:-$BRIDGE_STATE_DIR/agents}"
    # Any bash helper that reaches runtime_state_dir goes through this root,
    # so Python must honour the same override to land files where the bash
    # reader will look.
    explicit = os.environ.get("BRIDGE_ACTIVE_AGENT_DIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return bridge_state_dir() / "agents"


def bridge_home_dir() -> Path:
    explicit = os.environ.get("BRIDGE_HOME", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return Path.home() / ".agent-bridge"


def bridge_script_dir() -> Path:
    return Path(__file__).resolve().parent.parent


def audit_log_path() -> Path:
    explicit = os.environ.get("BRIDGE_AUDIT_LOG", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    agent = current_agent()
    if agent:
        return bridge_home_dir() / "logs" / "agents" / agent / "audit.jsonl"
    return bridge_home_dir() / "logs" / "audit.jsonl"


def agent_home_root() -> Path:
    explicit = os.environ.get("BRIDGE_AGENT_HOME_ROOT", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    return bridge_home_dir() / "agents"


def agent_root_v2() -> Path | None:
    """The v2 split-layout per-agent root (``data/agents``), if active.

    Issue #1497: on a v2 split layout install the bash launcher exports
    ``BRIDGE_AGENT_ROOT_V2`` (= ``$BRIDGE_DATA_ROOT/agents``) into every
    agent session, and ``bridge_agent_default_home`` (lib/bridge-agents.sh)
    resolves an agent's identity home to ``$BRIDGE_AGENT_ROOT_V2/<a>/home``
    — NOT the legacy ``$BRIDGE_AGENT_HOME_ROOT/<a>``. The Python hook layer
    was v2-blind and read only the legacy root, so it mis-resolved the home
    (and, downstream, the NEXT-SESSION.md handoff candidate list) to the
    stale legacy tree. Honour the same signal bash uses, with the same
    ``BRIDGE_DATA_ROOT`` fallback the bash anchor uses
    (lib/bridge-isolation-v2.sh:101). Returns ``None`` when no v2 signal is
    present so callers fall back to the exact legacy behaviour.
    """
    root = os.environ.get("BRIDGE_AGENT_ROOT_V2", "").strip()
    if root:
        return Path(root).expanduser()
    data_root = os.environ.get("BRIDGE_DATA_ROOT", "").strip()
    if data_root:
        return Path(data_root).expanduser() / "agents"
    return None


def agent_default_home(agent: str) -> Path:
    # Issue #1497: mirror bash bridge_agent_default_home exactly — on a v2
    # split layout the identity home is <root_v2>/<agent>/home; only fall
    # back to the legacy <home_root>/<agent> when no v2 signal is present.
    if agent:
        root_v2 = agent_root_v2()
        if root_v2 is not None:
            return root_v2 / agent / "home"
    return agent_home_root() / agent


@functools.lru_cache(maxsize=None)
def _resolve_workdir_via_roster(agent: str) -> Path | None:
    """Best-effort lookup of an agent's live workdir via the roster CLI.

    Used by :func:`agent_workdir` when neither the explicit env var nor
    the static-home directory is available — i.e. for dynamic claude
    agents whose workdir lives outside ``$BRIDGE_HOME/agents/<name>/``.
    Hooks invoked from cron / external surfaces lack the env that
    ``bridge-run.sh`` would export, so without this fallback the
    candidate list in :func:`bootstrap_artifact_context` misses the
    real ``<project-workdir>/NEXT-SESSION.md`` and the handoff is
    silently dropped.

    Any subprocess / parse / lookup failure returns ``None`` so the
    caller can fall back to the prior default-home behaviour. The
    result is memoised for the duration of the hook process.
    """
    cli = bridge_script_dir() / "agent-bridge"
    try:
        proc = subprocess.run(
            [str(cli), "agent", "list", "--json"],
            cwd=str(bridge_script_dir()),
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    rows: list[dict[str, Any]]
    if isinstance(payload, list):
        rows = [row for row in payload if isinstance(row, dict)]
    elif isinstance(payload, dict):
        candidates = payload.get("agents") or payload.get("rows") or []
        rows = [row for row in candidates if isinstance(row, dict)]
    else:
        return None
    for row in rows:
        if row.get("agent") != agent:
            continue
        workdir = row.get("workdir")
        if isinstance(workdir, str) and workdir.strip():
            return Path(workdir).expanduser()
    return None


def agent_workdir(agent: str) -> Path:
    # Issue #1497 (fast path): bridge-run.sh exports the already-resolved
    # workdir under the distinctly-named BRIDGE_AGENT_WORKDIR_RESOLVED
    # scalar (the bare BRIDGE_AGENT_WORKDIR is the name of a bash
    # associative array, so its scalar export silently no-ops — mirroring
    # the #1217 BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED fix). $WORK_DIR was
    # computed via the authoritative bridge_agent_workdir, so this is the
    # exact v2/iso/admin-pair-aware answer. Read it first; fall back to the
    # legacy bare name for manual / non-bridge launches.
    resolved = os.environ.get("BRIDGE_AGENT_WORKDIR_RESOLVED", "").strip()
    if resolved:
        return Path(resolved).expanduser()
    explicit = os.environ.get("BRIDGE_AGENT_WORKDIR", "").strip()
    if explicit:
        return Path(explicit).expanduser()
    # Issue #1497 (split-brain immunity): on a migrated v2 install the
    # legacy agents/<a> dir physically still exists, so the legacy-default
    # .is_dir() short-circuit below would win and return the stale legacy
    # tree BEFORE the roster fallback recovers the real workdir. When a v2
    # signal is present, prefer the v2 workdir <root_v2>/<a>/workdir if it
    # exists on disk — matching the bash bridge_agent_workdir v2 anchor —
    # ahead of the legacy short-circuit.
    if agent:
        root_v2 = agent_root_v2()
        if root_v2 is not None:
            v2_workdir = root_v2 / agent / "workdir"
            if v2_workdir.is_dir():
                return v2_workdir
    default = agent_default_home(agent)
    if default.is_dir():
        return default
    # Dynamic-agent fallback (issue #509 D wave): the env that
    # bridge-run.sh exports may not be available on cron / external
    # invocations, and the static default home does not exist for
    # agents whose workdir is a project directory.
    roster_workdir = _resolve_workdir_via_roster(agent)
    if roster_workdir is not None:
        return roster_workdir
    return default


def current_agent() -> str:
    return os.environ.get("BRIDGE_AGENT_ID", "").strip()


# Issue #539: the calling agent's privilege class. The closed value space
# is {"user", "system"}; missing or unknown values normalize to "user" so
# the default-deny posture for cross-agent reads is preserved. The bash
# roster loader (lib/bridge-state.sh::bridge_load_roster) hard-fails on
# unknown class values, so seeing one here means an out-of-band shell
# corrupted the env file — fall back conservatively rather than escalate.
#
# The exported env var is BRIDGE_AGENT_CLASS_FOR_HOOK (a scalar alias);
# the bare name BRIDGE_AGENT_CLASS in bash is the associative array of
# every agent's class, which would collide with a scalar export.
# bridge-run.sh:178-184 sets the alias for the calling agent.
@functools.lru_cache(maxsize=1)
def current_agent_class() -> str:
    raw = os.environ.get("BRIDGE_AGENT_CLASS_FOR_HOOK", "").strip().lower()
    if raw in {"user", "system"}:
        return raw
    return "user"


# Issue #539: standardized audit event for every cross-agent file read by
# a class=system agent. Mirrors the write_audit envelope (ts/host/uid/etc.)
# but exposes a stable detail shape — `target_path` (the absolute or
# bridge-relative path the agent attempted to read), `target_agent` (the
# peer whose home contains the path, or "" for shared/* reads), and
# `tool` (the Claude tool name that drove the access). Operators audit
# every system-class read by grepping audit.jsonl for
# `"action":"system_cross_agent_read"`.
def emit_system_cross_agent_read(
    *,
    agent: str,
    target_path: str,
    target_agent: str,
    tool: str,
) -> None:
    write_audit(
        "system_cross_agent_read",
        agent or "unknown",
        {
            "agent": agent or "unknown",
            "target_path": target_path,
            "target_agent": target_agent,
            "tool": tool,
        },
    )


def _current_agent_under_foreign_uid() -> str | None:
    """Return the calling agent slug iff this process is actually
    running as a non-controller UID under the agent's env.

    Issue #1213 root cause: ``BRIDGE_AGENT_ISOLATION_MODE`` is declared
    as an associative array in ``lib/bridge-agents.sh:3410`` /
    ``lib/bridge-state.sh:1008``. When ``bridge-run.sh:212`` later runs
    ``export BRIDGE_AGENT_ISOLATION_MODE="linux-user"``, bash silently
    no-ops the export (a scalar export of a name bound to an assoc
    array is structurally impossible). The variable shows up "set" in
    the current shell, but is absent from the child process's
    ``/proc/<pid>/environ``. The same name-collision hits
    ``BRIDGE_AGENT_OS_USER`` (also an assoc array exported as a scalar
    on line 213). The pre-#1213 ``current_isolated_agent`` predicate
    gated on this missing env var → returned ``None`` under iso v2 →
    every PermissionError fail-open in ``_under_isolated_uid`` and
    ``queue_cli`` was silently bypassed.

    The new predicate proves the iso shape from the data we *can* see:
    ``BRIDGE_AGENT_ID`` (singular scalar, propagates fine) +
    ``BRIDGE_CONTROLLER_UID`` (scalar) + ``os.geteuid() !=
    controller_uid``. The UID-differs-from-controller check defends
    against a controller process inheriting ``BRIDGE_AGENT_ID`` and
    being mis-attributed — the original #1167 codex BLOCKING scenario
    — strictly more rigorously than the mode-string check did, because
    a controller re-exporting the env still runs as the controller UID.

    Returns the agent slug when the process is provably under a
    foreign UID, ``None`` otherwise (no controller UID, malformed
    controller UID, or matching UID).
    """
    agent = current_agent()
    if not agent:
        return None
    controller_uid_raw = os.environ.get("BRIDGE_CONTROLLER_UID", "").strip()
    if not controller_uid_raw:
        # Fail-closed: without the controller UID we cannot prove the
        # caller is the isolated UID. Treat as controller.
        return None
    try:
        controller_uid = int(controller_uid_raw)
    except ValueError:
        return None
    if os.geteuid() == controller_uid:
        return None
    return agent


def current_isolated_agent() -> str | None:
    # Issue #1213: use the UID-based predicate instead of the
    # ``BRIDGE_AGENT_ISOLATION_MODE`` mode-string check. The mode-string
    # check structurally cannot survive the bash assoc-array name
    # collision in ``bridge-run.sh:212``; the UID check proves the
    # same property (foreign-UID iso shape) more strictly. See
    # :func:`_current_agent_under_foreign_uid` for the rationale.
    #
    # This function is consumed by ``queue_cli()`` (this file, below)
    # to route hook queue traffic through ``bridge-queue-gateway.py``
    # — without this fix, iso v2 sessions stayed on the controller
    # ``bridge-queue.py`` path and could not route through the
    # gateway, leaving hook queue commands silently misrouted.
    return _current_agent_under_foreign_uid()


def current_agent_workdir() -> Path:
    agent = current_agent()
    if not agent:
        return Path.cwd()
    return agent_workdir(agent)


def queue_cli_cwd() -> Path:
    candidates: list[Path] = []
    explicit_workdir = os.environ.get("BRIDGE_AGENT_WORKDIR", "").strip()
    if explicit_workdir:
        candidates.append(Path(explicit_workdir).expanduser())

    agent = current_agent()
    if agent:
        candidates.append(agent_default_home(agent))

    try:
        candidates.append(Path.cwd())
    except OSError:
        pass
    candidates.append(bridge_script_dir())

    for path in candidates:
        try:
            if path.is_dir():
                return path
        except OSError:
            continue
    return Path("/")


def path_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def truncate_text(text: str, limit: int = 400) -> str:
    cleaned = " ".join(str(text).split())
    if len(cleaned) <= limit:
        return cleaned
    return cleaned[: limit - 3].rstrip() + "..."


def _acting_os_user() -> str:
    try:
        return pwd.getpwuid(os.geteuid()).pw_name
    except (KeyError, OSError):
        pass
    try:
        return os.getlogin()
    except OSError:
        return ""


def _current_isolation_mode() -> str:
    # Issue #1213: ``BRIDGE_AGENT_ISOLATION_MODE`` is silently absent
    # from iso v2 child environs because of the assoc-array name
    # collision on the bash side (see
    # :func:`_current_agent_under_foreign_uid`). When the env var is
    # missing but the UID-based predicate proves the foreign-UID iso
    # shape, return ``"linux-user"`` so diagnostics (audit envelopes,
    # status reasons) do not lie and say ``"shared"`` under a proven
    # iso process. Operator-supplied ``BRIDGE_AGENT_ISOLATION_MODE``
    # still wins when set (back-compat for explicit mode overrides).
    mode = os.environ.get("BRIDGE_AGENT_ISOLATION_MODE", "").strip()
    if mode:
        return mode
    if _current_agent_under_foreign_uid() is not None:
        return "linux-user"
    return "shared"


def _under_isolated_uid() -> bool:
    """True only when the process is actually running as a non-controller
    UID under an isolated agent's env.

    Issue #1213: keys on the UID-side predicate
    (``_current_agent_under_foreign_uid``) rather than the
    mode-string ``BRIDGE_AGENT_ISOLATION_MODE`` env var. The mode
    string was previously gated through ``current_isolated_agent()``
    but cannot survive the assoc-array name collision in
    ``bridge-run.sh:212`` (silently no-ops the scalar export). The
    UID-based predicate proves the same property — the caller is
    actually running as a non-controller UID under the agent's env —
    strictly more rigorously, since a controller process re-exporting
    ``BRIDGE_AGENT_ID`` still runs as the controller UID.

    History: this was originally codified as the #1165 Track C r2
    codex BLOCKING fix where the env-only predicate (``BRIDGE_AGENT_ID``
    + ``BRIDGE_AGENT_ISOLATION_MODE=linux-user``) was caught swallowing
    controller-side failures whenever the iso env happened to be
    inherited. The UID-side guard was already added then; #1213
    completes the contract by removing the mode-string dependency
    so iso v2 itself can satisfy the gate.
    """
    return _current_agent_under_foreign_uid() is not None


def under_isolated_uid() -> bool:
    """Public wrapper for :func:`_under_isolated_uid`.

    Hook modules outside ``bridge_hook_common`` (e.g. ``tool-policy.py``)
    need the same effective-UID gate when they encounter a PermissionError
    that is part of the iso v2 contract (controller-only-readable agent
    home root, controller-only-writable state tree). Re-exporting the
    private helper as a public symbol keeps the gate behind a single
    SSOT — callers must NOT roll their own env-only predicate, which is
    exactly the regression codex caught on issue #1167 (#1165 Track C r2).
    See :func:`_under_isolated_uid` for the rationale on every branch.
    """
    return _under_isolated_uid()


# Issue #1358 — SSOT audit-detail credential choke-point.
#
# The OAuth setup-token prefix is `sk-ant-o`; the run continues with
# `[A-Za-z0-9_-]`. This is the SAME regex carried locally in
# ``tool-policy.py`` (`_CREDENTIAL_TOKEN_VALUE_RE`) and
# ``permission_escalation.py``. Defined here so it can guard EVERY audit
# row at the single write point regardless of which hook module emitted
# it (#1358 r4 class closure).
# Issue #1358 r6 (codex r5 BLOCKING): the redactor MUST be idempotent.
# Layer 2 writers (tool-policy.py / permission_escalation.py) emit values
# already collapsed to ``sk-ant-o<REDACTED>`` BEFORE this Layer 1
# choke-point runs. Without the negative lookahead, the bare prefix inside
# an already-redacted marker re-matches and yields ``sk-ant-o<REDACTED><REDACTED>``.
# The ``(?!<REDACTED>)`` guard skips an already-collapsed marker so a
# double pass is a no-op (raw run -> single marker; marker -> unchanged).
_AUDIT_CREDENTIAL_TOKEN_VALUE_RE = re.compile(r"sk-ant-o(?!<REDACTED>)[A-Za-z0-9_-]*")


def _redact_audit_detail_credentials(value: Any) -> Any:
    """Recursively collapse OAuth token runs in any audit-detail value.

    Issue #1358 r4 (2026-05-29) — class closure. R1–R3 sealed the token
    leak at three individual audit writers in ``tool-policy.py``
    (``agent_tool_denied``, the PostToolUse rows, the credential-routine
    exemption row) and in ``permission_escalation.py``. R3's codex review
    then found a FOURTH independent writer — ``system_config_mutation``
    via ``_write_system_config_audit_row`` — whose non-Bash ``operation``
    JSON embedded the raw ``tool_input`` values (e.g. an admin ``Write``
    to ``agent-roster.local.sh`` with ``content`` carrying an
    ``sk-ant-o…`` token) without passing through any redactor.

    Rather than whack-a-mole each writer, this is the **single
    choke-point**: ``write_audit`` runs every ``detail`` dict through
    here before persisting, so any current OR future audit writer that
    embeds ``tool_input``-derived text inherits the token-value scrub for
    free. The contract for new audit writers is therefore: *you do not
    need to remember to redact token values — the write point already
    does it.* Writers that need a STRONGER guarantee (hash-only command
    substitution, where even the redacted command text must not survive)
    still apply that substitution at their own call site BEFORE calling
    ``write_audit``; this pass only collapses ``sk-ant-o…`` runs, so a
    hash-only ``detail`` (which carries no token run) is untouched.

    The redaction is surgical and value-only: it replaces the
    ``sk-ant-o…`` run with ``sk-ant-o<REDACTED>`` and leaves the
    surrounding structure (credential file paths, grep pattern
    skeletons, dict keys) intact so the audit row keeps its forensic
    anchor. Walks dicts, lists, and tuples recursively; non-string
    scalars pass through unchanged.
    """
    if isinstance(value, str):
        return _AUDIT_CREDENTIAL_TOKEN_VALUE_RE.sub("sk-ant-o<REDACTED>", value)
    if isinstance(value, dict):
        return {key: _redact_audit_detail_credentials(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_redact_audit_detail_credentials(item) for item in value]
    return value


def write_audit(action: str, target: str, detail: dict[str, Any]) -> None:
    path = audit_log_path()
    # Issue #1358 r4: final-line defense — collapse any OAuth token run
    # in the detail dict regardless of which writer built it. Individual
    # writers in tool-policy.py / permission_escalation.py still redact at
    # source (explicit + hash-only where required); this choke-point
    # guarantees no audit row can persist a raw token even if a writer
    # forgot, used a new field, or is added later. Best-effort: a malformed
    # detail must never block the audit append, so fall back to the raw
    # detail on any unexpected error.
    try:
        detail = _redact_audit_detail_credentials(detail)
    except Exception:  # noqa: BLE001 — never let redaction break audit emit
        pass
    record = {
        "ts": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "actor": "hook",
        "action": action,
        "target": target,
        "detail": detail,
        "pid": os.getpid(),
        "host": socket.gethostname(),
        "acting_os_uid": os.geteuid(),
        "acting_os_user": _acting_os_user(),
        "isolation_mode": _current_isolation_mode(),
    }
    # Issue #1165 Gap 7: under linux-user isolation the audit log path
    # resolves to ``$BRIDGE_HOME/logs/agents/<agent>/audit.jsonl`` —
    # a controller-owned tree the isolated UID cannot mkdir into or
    # append to. Without a guard, every PostToolUse hook from inside the
    # isolated Claude REPL ends with a PermissionError traceback that
    # Claude surfaces as a ``PostToolUseFailure`` flood per tool call.
    # Same "check-then-skip rather than fail-with-traceback" pattern as
    # the recent v2-isolation fixes (#1145, #1151, #1155): when the
    # writer cannot satisfy the controller-only path AND the calling UID
    # is actually a non-controller isolated UID, silently no-op.
    # Controller-side callers retain the original raise-on-error
    # behavior so a genuine logs-dir permission regression is still
    # surfaced (the controller is supposed to own the tree).
    #
    # r2 hardening: the gate is the *effective UID vs controller UID*,
    # not just env presence. See ``_under_isolated_uid`` for the
    # rationale — codex BLOCKING review #1167 caught the original
    # env-only predicate swallowing controller-side failures whenever
    # the iso env happened to be inherited.
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=True) + "\n")
    except (PermissionError, OSError):
        if _under_isolated_uid():
            return
        raise


def queue_gateway_root() -> Path:
    return bridge_state_dir() / "queue-gateway"


def queue_cli(args: list[str]) -> subprocess.CompletedProcess[str]:
    isolated_agent = current_isolated_agent()
    if isolated_agent:
        cmd = [
            sys.executable,
            str(bridge_script_dir() / "bridge-queue-gateway.py"),
            "client",
            "--root",
            str(queue_gateway_root()),
            "--agent",
            isolated_agent,
            "--timeout",
            os.environ.get("BRIDGE_QUEUE_GATEWAY_TIMEOUT_SECONDS", "45"),
            "--poll",
            os.environ.get("BRIDGE_QUEUE_GATEWAY_POLL_SECONDS", "0.2"),
            *args,
        ]
    else:
        cmd = [sys.executable, str(bridge_script_dir() / "bridge-queue.py"), *args]
    return subprocess.run(
        cmd,
        cwd=str(queue_cli_cwd()),
        capture_output=True,
        text=True,
        check=False,
    )


def first_existing_path(candidates: list[Path]) -> Path | None:
    for path in candidates:
        if path.is_file():
            return path
    return None


def short_file_excerpt(path: Path, limit: int = 600) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    if not lines:
        return ""
    excerpt = "\n".join(lines[:6]).strip()
    if len(excerpt) > limit:
        excerpt = excerpt[: limit - 3].rstrip() + "..."
    return excerpt


def onboarding_state_from_file(path: Path | None) -> str:
    if path is None:
        return "missing"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return "missing"
    match = re.search(r"Onboarding\s+State:\s*([A-Za-z0-9._-]+)", text)
    if not match:
        return "missing"
    return match.group(1)


def _residual_placeholders_in(path: Path | None) -> list[str]:
    """Return sorted list of scaffold placeholder strings still present in path.

    Returns [] when the file is absent, unreadable, or clean.
    Uses IDENTITY_PLACEHOLDER_PATTERNS — an explicit audited set from
    bridge_render_template_string — to avoid false-positives on intentional
    angle-bracket tokens like <user-id> or <configured-admin-agent>.
    """
    if not path or not path.exists():
        return []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    return sorted(p for p in IDENTITY_PLACEHOLDER_PATTERNS if p in text)


def _stamp_next_session_delivered(agent: str, next_session: Path) -> str | None:
    """Persist the SHA-1 digest of NEXT-SESSION.md into the per-agent marker.

    The bash-side `bridge_agent_maybe_expire_next_session` gates on
    `bridge_agent_next_session_is_delivered` (marker file equals the current
    file digest). Without this writer the auto-archive path is dead code — a
    regression introduced when `bridge_run_schedule_next_session_prompt` was
    removed in b38e584 in favour of the SessionStart hook. We restore the
    marker here so `bridge-run.sh`'s reconcile step can age out a stale
    handoff file the next time a Claude agent restarts.

    Returns the digest string on success so callers (e.g. the queue-route
    handoff path in #409 Track A) can use it as an idempotency key. Returns
    None when the file cannot be read or the marker cannot be written.

    Best-effort: any IO failure is swallowed so the hook never blocks agent
    startup over marker bookkeeping.
    """
    try:
        content = next_session.read_bytes()
    except OSError:
        return None
    # bridge_agent_next_session_digest (bash) pipes the file through
    # `bridge_sha1 "$(cat $file)"`. Command substitution strips trailing
    # newlines before the argument reaches Python's hashlib, so hashing
    # the raw bytes here would produce a different digest whenever
    # NEXT-SESSION.md ends in `\n` — which is virtually always. Strip
    # trailing newlines to match.
    content = content.rstrip(b"\n")
    digest = hashlib.sha1(content).hexdigest()
    # Mirror lib/bridge-state.sh::bridge_agent_next_session_marker_file,
    # which resolves to bridge_agent_runtime_state_dir/next-session.sha and
    # runtime_state_dir is BRIDGE_ACTIVE_AGENT_DIR/<agent>. Honour the env
    # override so a deployment that reroots its active-agent dir (e.g. for
    # linux-user isolation) gets the marker where bash will actually look.
    marker_file = bridge_active_agent_dir() / agent / "next-session.sha"
    try:
        # v0.9.7 RC2 (refs #781): the matrix grants the isolated UID
        # rwx on state/agents/<X>/ via group ab-agent-<X> + setgid 2770.
        # Use exist_ok=True so we don't override the parent's setgid bit
        # with mode 0755 (which Python's mkdir defaults to when
        # creating). When the parent already exists with the v2
        # contract the call is a no-op; when it doesn't, a default-mode
        # mkdir from this hook would land as 0755 owned by the isolated
        # UID, which is acceptable for the leaf but loses the setgid
        # inheritance for sibling state files. The matrix-aware writer
        # in lib/bridge-isolation-v2.sh is the canonical path; this
        # branch is the hot-path inside an already-running Claude
        # session so we keep it minimal and rely on the matrix grant
        # being applied at start time.
        marker_file.parent.mkdir(parents=True, exist_ok=True)
        marker_file.write_text(digest, encoding="utf-8")
    except OSError as exc:
        # r11 codex BUG #5 — EACCES (and other OSError variants) was
        # silently returning None. The hook is a hot-path (runs on every
        # prompt) so raising would spam, but completely silencing made
        # it impossible to detect when the matrix's state-agent-dir
        # grant was missing. Emit a one-line stderr warning so operator
        # sees the failure mode in the session output AND the daemon
        # log, then return None to keep the prompt usable.
        try:
            sys.stderr.write(
                "[bridge-hook] WARNING: cannot write next-session.sha at "
                f"{marker_file}: {exc.__class__.__name__}: {exc}\n"
            )
            sys.stderr.flush()
        except Exception:
            pass
        return None
    return digest


def _enqueue_handoff_pending(agent: str, next_session: Path, digest: str) -> None:
    """Self-enqueue an urgent task so the queue contract enforces handoff priority.

    The hook's stdout-as-context surface (current behaviour) puts the handoff
    instruction on equal footing with whatever the operator types as the first
    user message. Empirically the operator's intent wins and the handoff is
    silently skipped. By creating a queued task on the agent's own inbox at
    the same time, the existing "claim highest-priority queued task first"
    contract turns the handoff into a hard precondition for any other work.

    Idempotency: title carries the digest so re-running for the same handoff
    file produces a duplicate-title task that bridge-task.sh's find-open path
    refuses to re-create. A new digest (handoff content changed) yields a new
    task; an unchanged digest is a no-op.

    Best-effort: any IO/subprocess failure is swallowed so the hook never
    blocks agent startup over enqueue bookkeeping. The stdout-as-context path
    still runs as a fallback regardless.
    """
    title = f"[bridge:handoff-pending] {next_session.name} ({digest[:8]})"
    body = (
        f"NEXT-SESSION.md handoff detected at {next_session}.\n"
        f"\n"
        f"Read this file in full and execute its checklist before any other work. "
        f"Reply briefly to the operator (\"handoff 처리부터 하겠습니다\") if a user "
        f"message is also pending; resume normal flow only after the file is "
        f"deleted by the agent.\n"
        f"\n"
        f"Auto-enqueued by bridge_hook_common._enqueue_handoff_pending.\n"
    )
    # find-open guard: skip if a same-digest handoff task is already open.
    # bridge-queue.py find-open --title-prefix uses SQL LIKE; passing the FULL
    # digest-bearing title as the prefix is the exact-match form (no other
    # title starts with this exact string since digest8 + ")" is terminal).
    # Codex r1 flagged the LIMIT 1 trap: a generic prefix like
    # "[bridge:handoff-pending]" matches an older different-digest row first
    # and suppresses the new enqueue, missing the current handoff.
    try:
        existing = queue_cli([
            "find-open",
            "--agent", agent,
            "--title-prefix", title,
            "--format", "json",
        ])
        if existing.returncode == 0 and existing.stdout.strip():
            try:
                row = json.loads(existing.stdout)
            except (json.JSONDecodeError, ValueError):
                row = None
            if isinstance(row, dict) and row.get("title", "") == title:
                return  # already enqueued for this exact digest
    except Exception:
        pass
    try:
        queue_cli([
            "create",
            "--to", agent,
            "--from", agent,
            "--priority", "urgent",
            "--title", title,
            "--body", body,
        ])
    except Exception:
        # Hook must not block agent startup on enqueue failure.
        return


DEFAULT_COMPACT_RECOVERY_FILES: tuple[str, ...] = (
    "SOUL.md",
    "SESSION-TYPE.md",
    "COMMON-INSTRUCTIONS.md",
    "TOOLS.md",
    "MEMORY.md",
)
_COMPACT_RECOVERY_DEFAULT_CAP = 8192  # raised from 5120 (issue #509 follow-up):
_COMPACT_RECOVERY_MIN_CAP = 256       # patch's SESSION-TYPE.md is 5607 bytes,
                                      # so 5120 truncated the admin
                                      # bootstrap content. 8192 covers all
                                      # observed canonical files on the SYRS
                                      # install. Total worst-case payload
                                      # remains 5×8192 = 40 KB / ~16k tokens
                                      # at the post-compact turn.


def compact_recovery_enabled() -> bool:
    raw = os.environ.get("BRIDGE_COMPACT_RECOVERY", "").strip().lower()
    if not raw:
        return True
    return raw not in {"0", "false", "no", "off"}


def compact_recovery_files() -> tuple[str, ...]:
    raw = os.environ.get("BRIDGE_COMPACT_RECOVERY_FILES", "").strip()
    if not raw:
        return DEFAULT_COMPACT_RECOVERY_FILES
    parts = [piece.strip() for piece in raw.split(",") if piece.strip()]
    return tuple(parts) if parts else DEFAULT_COMPACT_RECOVERY_FILES


def compact_recovery_per_file_cap() -> int:
    raw = os.environ.get("BRIDGE_COMPACT_RECOVERY_MAX_BYTES", "").strip()
    if not raw:
        return _COMPACT_RECOVERY_DEFAULT_CAP
    try:
        value = int(raw)
    except ValueError:
        return _COMPACT_RECOVERY_DEFAULT_CAP
    return max(value, _COMPACT_RECOVERY_MIN_CAP)


def compact_snapshot_path(agent: str) -> Path:
    return bridge_state_dir() / "agents" / agent / "compact-snapshot.json"


def _read_canonical_file(home: Path, name: str, cap: int) -> str:
    candidate = home / name
    try:
        # read_text follows symlinks, so SHARED-symlinked files resolve
        # transparently (TOOLS.md → shared/TOOLS.md, etc.).
        if not candidate.exists():
            return ""
        text = candidate.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    text = text.strip("\n")
    encoded = text.encode("utf-8")
    if len(encoded) <= cap:
        return text
    # Cap is named/documented as a UTF-8 BYTE cap, so truncate on a byte
    # window. `errors="ignore"` drops a partial trailing byte sequence so
    # we never emit a half-character; the suffix marker tells the reader
    # the section was clipped. This matters for non-ASCII (Korean,
    # Japanese, etc.) where 1 character = 2–4 bytes — a character-count
    # cap would let the payload silently grow several times past the
    # documented budget. (Codex r1 / PR #510.)
    truncated = encoded[:cap].decode("utf-8", errors="ignore").rstrip()
    return truncated + "\n[…truncated by compact-recovery cap…]"


def gather_canonical_files(agent: str) -> dict[str, str]:
    """Return ordered mapping of canonical filename → text content.

    Reads from the agent workdir first, then falls back to the agent
    default home for installations where the two diverge. Missing or
    unreadable files yield empty strings — the caller decides whether to
    skip or substitute a snapshot.
    """
    files = compact_recovery_files()
    cap = compact_recovery_per_file_cap()
    workdir = agent_workdir(agent)
    default_home = agent_default_home(agent)
    out: dict[str, str] = {}
    for name in files:
        text = _read_canonical_file(workdir, name, cap)
        if not text and workdir != default_home:
            text = _read_canonical_file(default_home, name, cap)
        out[name] = text
    return out


def write_compact_snapshot(agent: str, payload: dict[str, str]) -> Path | None:
    """Atomically persist canonical-file contents next to the agent state.

    The session-start hook reads this file as a fallback when the live
    canonical files have been moved/cleared between pre-compact and the
    post-compact session resume. Best-effort — IO failures are swallowed
    because pre-compact must never block compaction.
    """
    path = compact_snapshot_path(agent)
    envelope = {
        "agent": agent,
        "captured_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "files": payload,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(
            json.dumps(envelope, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        os.chmod(tmp, 0o600)
        tmp.replace(path)
        os.chmod(path, 0o600)
        return path
    except OSError:
        return None


def load_compact_snapshot(agent: str) -> dict[str, str]:
    path = compact_snapshot_path(agent)
    if not path.exists():
        return {}
    try:
        envelope = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(envelope, dict):
        return {}
    files = envelope.get("files")
    if not isinstance(files, dict):
        return {}
    return {str(k): str(v) for k, v in files.items() if isinstance(v, str)}


def compact_recovery_context(agent: str) -> str:
    """Return the `## Restored Context` block for compaction recovery.

    Reads canonical files live (resolves symlinks). When a file is missing
    or empty, falls back to the most recent pre-compact snapshot. Returns
    an empty string when the feature is disabled or no content survived.
    """
    if not compact_recovery_enabled():
        return ""
    live = gather_canonical_files(agent)
    snapshot = load_compact_snapshot(agent) if any(not v for v in live.values()) else {}
    sections: list[str] = []
    for name, text in live.items():
        if not text and snapshot.get(name):
            text = snapshot[name].rstrip() + "\n[restored from pre-compact snapshot]"
        if not text:
            continue
        sections.append(f"### {name}\n{text}")
    if not sections:
        return ""
    body = "\n\n".join(sections)
    return (
        "## Restored Context (post-compact)\n"
        "These canonical agent files were re-injected because the previous\n"
        "conversation was compacted. Treat them as the load-bearing identity\n"
        "anchors for this turn before reading queue/handoff state below.\n\n"
        + body
    )


def bootstrap_artifact_context(agent: str) -> str:
    workdir = agent_workdir(agent)
    default_home = agent_default_home(agent)
    lines: list[str] = []

    next_session = first_existing_path(
        [
            workdir / "NEXT-SESSION.md",
            default_home / "NEXT-SESSION.md",
        ]
    )
    if next_session is not None:
        lines.append(
            f"Handoff present: {next_session.name} exists at {next_session}. "
            "Read this file first and execute its checklist before anything else."
        )
        excerpt = short_file_excerpt(next_session)
        if excerpt:
            lines.append("Handoff excerpt:")
            lines.append(excerpt)
        digest = _stamp_next_session_delivered(agent, next_session)
        if digest is not None:
            _enqueue_handoff_pending(agent, next_session, digest)

    session_type = first_existing_path(
        [
            workdir / "SESSION-TYPE.md",
            default_home / "SESSION-TYPE.md",
        ]
    )
    if onboarding_state_from_file(session_type) == "pending":
        lines.append(
            f"Onboarding pending: {session_type} says Onboarding State: pending. "
            "Stay in onboarding flow until it is complete before doing unrelated work."
        )

    # Detect scaffold placeholder residue in SOUL.md / CLAUDE.md.
    # An agent can have SESSION-TYPE.md marked 'complete' while still
    # carrying unfilled template tokens — e.g. when scaffolded before
    # bridge_render_template_string existed or without explicit identity args.
    # Warn independently of onboarding_state so the agent self-corrects even
    # when SESSION-TYPE.md already says complete.
    for _fname in ("SOUL.md", "CLAUDE.md"):
        _candidate = first_existing_path(
            [workdir / _fname, default_home / _fname]
        )
        _residual = _residual_placeholders_in(_candidate)
        if _residual:
            lines.append(
                f"Template placeholder residue: {_candidate} still contains "
                f"unfilled scaffold tokens: {', '.join(_residual)}. "
                "Fill the 핵심 정보 block in SOUL.md and CLAUDE.md before "
                "proceeding with normal work."
            )

    # Issue #132a: surface any pending-attention spool entries queued while the
    # agent was busy so the operator knows replays will follow once the input
    # box becomes idle. The spool path mirrors lib/bridge-state.sh.
    spool_path = (
        bridge_state_dir() / "agents" / agent / "pending-attention.env"
    )
    try:
        pending_count = sum(
            1
            for line in spool_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        )
    except (OSError, UnicodeDecodeError):
        pending_count = 0
    if pending_count > 0:
        lines.append(
            f"Agent Bridge has {pending_count} queued external event(s); "
            "they will replay into this session as the input box becomes idle."
        )

    if not lines:
        return ""
    return "\n".join(lines)


def next_session_required_prompt_context(agent: str) -> str:
    workdir = agent_workdir(agent)
    default_home = agent_default_home(agent)
    next_session = first_existing_path(
        [
            workdir / "NEXT-SESSION.md",
            default_home / "NEXT-SESSION.md",
        ]
    )
    if next_session is None:
        return ""

    lines = [
        "<agent_bridge_next_session_required>",
        f"NEXT-SESSION.md is still present at {next_session}.",
        "Before answering the current user prompt or doing any other work, read this file in full and execute its checklist.",
        "If the current user prompt conflicts with the handoff, acknowledge that the handoff is being processed first.",
    ]
    excerpt = short_file_excerpt(next_session)
    if excerpt:
        lines.append("Handoff excerpt:")
        lines.append(excerpt)
    digest = _stamp_next_session_delivered(agent, next_session)
    if digest is not None:
        _enqueue_handoff_pending(agent, next_session, digest)
    lines.append("</agent_bridge_next_session_required>")
    return "\n".join(lines)


def timestamp_state_path(agent: str) -> Path:
    return bridge_state_dir() / "agents" / agent / "timestamp.json"


def load_timestamp_state(agent: str) -> dict[str, int]:
    path = timestamp_state_path(agent)
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(payload, dict):
        return {}
    state: dict[str, int] = {}
    for key in ("session_started_at", "last_prompt_at"):
        value = payload.get(key)
        if isinstance(value, int):
            state[key] = value
    return state


def save_timestamp_state(agent: str, payload: dict[str, int]) -> None:
    # Issue #1205 Family B: the timestamp state path resolves to
    # ``$BRIDGE_HOME/state/agents/<agent>/timestamp.json`` (parent mode
    # ``drwx--x--x`` under iso v2). The isolated UID has no permission to
    # mkdir / write into that controller-owned tree, so the entire write
    # sequence (mkdir + temp write + chmod + replace + final chmod) can
    # raise PermissionError or OSError at any step. Wrap the whole
    # sequence and fail-open only when the calling UID is actually a
    # non-controller iso UID — controller-side callers still raise so a
    # genuine permission regression continues to surface. The advisory
    # timestamp context (prompt_timestamp_context, remember_session_start)
    # is intentionally non-critical; silently no-op under iso is the
    # correct behavior until the controller-proxy gateway wave lands.
    path = timestamp_state_path(agent)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.chmod(tmp, 0o600)
        tmp.replace(path)
        os.chmod(path, 0o600)
    except (PermissionError, OSError):
        if _under_isolated_uid():
            # Opportunistic audit attempt — best-effort, no stderr noise.
            # write_audit() is already iso-UID-aware (#1165 Gap 7) so
            # this call is safe to make under iso: it will no-op silently
            # if the audit log path is also unwritable. No re-raise.
            try:
                write_audit(
                    "hook_permission_fail_open.timestamp_state",
                    str(path),
                    {
                        "operation": "save_timestamp_state",
                        "isolation_mode": _current_isolation_mode(),
                    },
                )
            except Exception:  # noqa: BLE001 — best-effort, never block hooks
                pass
            return
        raise


def agent_timestamp_enabled(agent: str) -> bool:
    # Issue #1217 (beta27 Track D): bridge-run.sh exports
    # BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED as a distinctly-named scalar
    # alias because the bare BRIDGE_AGENT_INJECT_TIMESTAMP collides with
    # the assoc array of the same name in lib/bridge-core.sh:867 (bash
    # silently no-ops a scalar export of a name bound to an assoc array).
    # Read RESOLVED first; fall back to the bare name so manual /
    # non-bridge launches (where the collision does not exist) keep
    # working unchanged.
    raw = (
        os.environ.get("BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED")
        or os.environ.get("BRIDGE_AGENT_INJECT_TIMESTAMP")
        or ""
    ).strip().lower()
    if not raw:
        return True
    return raw not in {"0", "false", "no", "off"}


def format_duration(seconds: int | None) -> str:
    if seconds is None:
        return "(first message)"
    if seconds < 0:
        seconds = 0
    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    parts: list[str] = []
    if hours:
        parts.append(f"{hours}h")
    if minutes or hours:
        parts.append(f"{minutes}m")
    parts.append(f"{secs}s")
    return " ".join(parts)


def remember_session_start(agent: str, now_epoch: int | None = None) -> None:
    if not agent_timestamp_enabled(agent):
        return
    now_epoch = now_epoch or int(datetime.now(timezone.utc).timestamp())
    state = load_timestamp_state(agent)
    changed = False
    if "session_started_at" not in state:
        state["session_started_at"] = now_epoch
        changed = True
    if changed:
        save_timestamp_state(agent, state)


def prompt_timestamp_context(agent: str, now: datetime | None = None) -> str:
    now_dt = now or datetime.now().astimezone()
    now_epoch = int(now_dt.timestamp())
    state = load_timestamp_state(agent)
    session_started_at = state.get("session_started_at", now_epoch)
    last_prompt_at = state.get("last_prompt_at")
    context = (
        "<timestamp>\n"
        f"now: {now_dt.strftime('%Y-%m-%d %H:%M:%S %Z (%a)')}\n"
        f"since_last: {format_duration(None if last_prompt_at is None else now_epoch - last_prompt_at)}\n"
        f"session_age: {format_duration(now_epoch - session_started_at)}\n"
        "</timestamp>\n"
        "<question_escalation>\n"
        "If you are about to ask the user the same unanswered question a second time, escalate before asking again.\n"
        f"Run exactly: ~/.agent-bridge/agent-bridge escalate question --agent {agent} --question \"<question>\" --context \"<why you need the answer>\"\n"
        "Use --wait-seconds when the elapsed wait materially matters.\n"
        "</question_escalation>"
    )
    state["session_started_at"] = session_started_at
    state["last_prompt_at"] = now_epoch
    save_timestamp_state(agent, state)
    return context


def admin_blocked_self_cleanup_context(agent: str) -> str:
    """Return a single-line self-cleanup pressure note when admin starts a session
    with blocked tasks in its own queue. Empty string for non-admin agents or when
    the admin has no blocked tasks. Filename contract for the role spec is in
    docs/agent-runtime/handoff-protocol.md.
    """
    admin_id = os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()
    if not admin_id or agent != admin_id:
        return ""
    summary_proc = queue_cli(["summary", "--agent", agent, "--format", "json"])
    if summary_proc.returncode != 0 or not summary_proc.stdout.strip():
        return ""
    try:
        rows = json.loads(summary_proc.stdout)
    except json.JSONDecodeError:
        return ""
    if not isinstance(rows, list) or not rows or not isinstance(rows[0], dict):
        return ""
    blocked = int(rows[0].get("blocked_count", 0) or 0)
    if blocked <= 0:
        return ""
    return (
        f"[Self-cleanup] {blocked} blocked task(s) in your queue. "
        "Self-cleanup contract requires evaluating each per the role spec "
        "(CLAUDE.md `## Admin Self-Cleanup of Own Queue`) before any other work. "
        "If you cannot reach a close decision today, refresh with a verifiable trigger."
    )


def session_start_context(agent: str) -> str:
    queue_context = (
        f"Agent Bridge queue protocol applies to {agent}. "
        f"Queue DB is source of truth. "
        f"When a task boundary is reached or Agent Bridge asks for attention, "
        f"run exactly: ~/.agent-bridge/agb inbox {agent}. "
        f"If a task is queued, claim the highest-priority one first. "
        f"If a task is already claimed by you, continue that task."
    )
    self_cleanup = admin_blocked_self_cleanup_context(agent)
    if self_cleanup:
        queue_context = f"{self_cleanup}\n\n{queue_context}"
    bootstrap_context = bootstrap_artifact_context(agent)
    if bootstrap_context:
        return f"{bootstrap_context}\n\n{queue_context}"
    return queue_context


def queue_summary(agent: str) -> tuple[int, dict[str, Any] | None]:
    """Return (queued_pending, top_queued_row) for the ACTION REQUIRED nudge.

    Issue #1199: the ACTION REQUIRED nudge is a "you have QUEUED work — claim
    the highest-priority one now" call-to-action. It must count ONLY
    `status == 'queued'` tasks. A `claimed` task is already being handled by
    the agent, and a `blocked` task waits on an external unblock — neither is
    actionable-via-claim, so neither belongs in the pending count or the
    "Highest priority" line.

    Before this fix `pending` summed queued + claimed, so the moment an agent
    (or the operator) ran `agb claim` on a freshly-delivered `[task-complete]`
    task, the very next turn-boundary Stop hook (`mark-idle.sh` →
    `check-inbox.py --format text`) re-injected
    `… ACTION REQUIRED … claim the first one immediately` for the task it had
    JUST claimed — the operator's exact "immediate re-nudge after claim"
    symptom. `blocked` was already excluded (PR #516/#518) to stop
    block-update re-fires; this drops the residual `claimed` term.

    The "Highest priority" row is now fetched with `--status-filter queued`
    so it can never cite a claimed/blocked task even when one outranks the
    queued head by priority. The codex Stop-hook anti-abandonment gate ("you
    still have open claimed work, continue it") is preserved separately in
    `check_inbox.py` via `open_claimed_count` — it is NOT an ACTION REQUIRED
    nudge and does not tell the agent to re-claim.
    """
    summary_proc = queue_cli(["summary", "--agent", agent, "--format", "json"])
    if summary_proc.returncode != 0 or not summary_proc.stdout.strip():
        return 0, None
    try:
        rows = json.loads(summary_proc.stdout)
    except json.JSONDecodeError:
        return 0, None
    if not isinstance(rows, list) or not rows:
        return 0, None
    row = rows[0] if isinstance(rows[0], dict) else None
    if not row:
        return 0, None
    pending = int(row.get("queued_count", 0))
    if pending <= 0:
        return 0, None

    top_proc = queue_cli(
        ["find-open", "--agent", agent, "--status-filter", "queued", "--format", "json"]
    )
    if top_proc.returncode != 0 or not top_proc.stdout.strip():
        return pending, None
    try:
        top_row = json.loads(top_proc.stdout)
    except json.JSONDecodeError:
        return pending, None
    if not isinstance(top_row, dict):
        return pending, None
    return pending, top_row


def open_claimed_count(agent: str) -> int:
    """Return the number of tasks currently `claimed` by ``agent``.

    Used by the codex Stop hook to keep its anti-abandonment gate — "you
    still have open claimed work, continue it instead of ending the session" —
    after issue #1199 dropped `claimed` from the ACTION REQUIRED pending
    count. This is intentionally NOT an ACTION REQUIRED nudge: it never tells
    the agent to re-claim a task it already holds.
    """
    summary_proc = queue_cli(["summary", "--agent", agent, "--format", "json"])
    if summary_proc.returncode != 0 or not summary_proc.stdout.strip():
        return 0
    try:
        rows = json.loads(summary_proc.stdout)
    except json.JSONDecodeError:
        return 0
    if not isinstance(rows, list) or not rows or not isinstance(rows[0], dict):
        return 0
    return int(rows[0].get("claimed_count", 0) or 0)


def top_claimed_row(agent: str) -> dict[str, Any] | None:
    """Return the highest-priority open `claimed` task row for ``agent``.

    Companion to ``open_claimed_count`` for the codex Stop-hook "continue your
    claimed work" message. Returns None when the agent holds no claimed task.
    """
    top_proc = queue_cli(
        ["find-open", "--agent", agent, "--status-filter", "claimed", "--format", "json"]
    )
    if top_proc.returncode != 0 or not top_proc.stdout.strip():
        return None
    try:
        top_row = json.loads(top_proc.stdout)
    except json.JSONDecodeError:
        return None
    return top_row if isinstance(top_row, dict) else None


def queue_attention_message(agent: str, pending: int, row: dict[str, Any] | None) -> str:
    lines = [f"[Agent Bridge] {pending} pending task(s) for {agent}."]
    if row is not None:
        lines.append(
            f"Highest priority: Task #{int(row.get('id', 0))} [{str(row.get('priority') or 'normal')}] {str(row.get('title') or '')}"
        )
    lines.append("ACTION REQUIRED: Use your Bash tool now. Do not acknowledge or reply conversationally first.")
    lines.append(f"Run exactly: ~/.agent-bridge/agb inbox {agent}")
    lines.append("If tasks are listed, show and claim the first one immediately.")
    lines.append("Queue DB is source of truth.")
    return "\n".join(lines)


def codex_stop_reason(agent: str, row: dict[str, Any]) -> str:
    task_id = int(row.get("id", 0))
    title = str(row.get("title") or "")
    priority = str(row["priority"] or "normal")
    status = str(row["status"] or "")
    if status == "claimed":
        return (
            f"Agent Bridge still has open claimed work for you: task #{task_id} "
            f"[{priority}] {title}. "
            f"Run ~/.agent-bridge/agb inbox {agent} now, inspect the open tasks, "
            f"and continue the claimed task instead of ending the session."
        )
    return (
        f"Agent Bridge queued work is waiting: task #{task_id} "
        f"[{priority}] {title}. "
        f"Run ~/.agent-bridge/agb inbox {agent} now, inspect the open tasks, "
        f"and claim the highest-priority queued task before ending the session."
    )


_GUARD_MODULE_NAME = "bridge_guard_common"


def load_guard_module(
    bridge_root: Path,
    required_attrs: Iterable[str],
) -> Optional[Any]:
    # Absolute-path module loader for ``bridge_guard_common.py``. Used by hooks
    # that must keep functioning under linux-user isolation, where the parent
    # ``BRIDGE_HOME`` directory may have only ``--x`` ACL traversal for the
    # isolated UID and Python's path-based finder fails to listdir it.
    #
    # Returns the loaded module on success. Returns ``None`` (silent no-op)
    # when the guard module cannot be located, read, parsed, or is missing one
    # of ``required_attrs``. Silent fallback is the safer posture for hooks:
    # if the guard is unreachable the Claude session keeps running without the
    # extra guard layer rather than failing every hook invocation.
    name = _GUARD_MODULE_NAME
    guard_path = bridge_root / "bridge_guard_common.py"
    required = tuple(required_attrs)

    cached = sys.modules.get(name)
    if cached is not None:
        try:
            for attr in required:
                getattr(cached, attr)
            return cached
        except AttributeError:
            sys.modules.pop(name, None)

    try:
        spec = importlib.util.spec_from_file_location(name, guard_path)
        if spec is None or spec.loader is None:
            return None
        module = importlib.util.module_from_spec(spec)
    except (OSError, ImportError, ValueError):
        return None

    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(name, None)
        return None

    try:
        for attr in required:
            getattr(module, attr)
    except AttributeError:
        sys.modules.pop(name, None)
        return None

    return module
