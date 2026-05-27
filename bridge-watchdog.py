#!/usr/bin/env python3
"""bridge-watchdog.py — scan bridge-owned agent homes for drift and onboarding gaps."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

# Phase 2 lift: use the canonical isolation-aware helpers from
# lib/bridge_iso_paths.py rather than re-implementing the lstat-owner
# probe + sudo escalation. The local `_isolated_workdir_owner` /
# `_sudo_test` wrappers below delegate to these names.
_BRIDGE_WATCHDOG_LIB_DIR = Path(__file__).resolve().parent / "lib"
if _BRIDGE_WATCHDOG_LIB_DIR.is_dir() and str(_BRIDGE_WATCHDOG_LIB_DIR) not in sys.path:  # noqa: raw-pathlib-controller-only — import-time controller-side lib dir probe
    sys.path.insert(0, str(_BRIDGE_WATCHDOG_LIB_DIR))
try:
    from bridge_iso_paths import (
        isolated_workdir_owner as _isolated_workdir_owner_canonical,
        sudo_run_as as _sudo_run_as_canonical,
    )
except ImportError:
    _isolated_workdir_owner_canonical = None
    _sudo_run_as_canonical = None

MANAGED_START = "<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->"
MANAGED_END = "<!-- END AGENT BRIDGE DOC MIGRATION -->"
# Claude-runtime profile files. Codex agents don't read these — see #905.
CLAUDE_REQUIRED_FILES = ("CLAUDE.md", "SOUL.md", "MEMORY-SCHEMA.md", "MEMORY.md", "SESSION-TYPE.md")
# Backward-compat alias: legacy callers / tests reference REQUIRED_FILES.
REQUIRED_FILES = CLAUDE_REQUIRED_FILES
# #1237: Codex-runtime profile contract. Codex CLI reads ``AGENTS.md`` at
# the agent home root; it has no SOUL.md / MEMORY*.md / SESSION-TYPE.md
# equivalent (those are Claude-only conventions). ``.codex/hooks.json`` is
# the engine's hook-policy file when present, used as an *optional* probe
# below (a missing hooks.json is not drift — codex agents may legitimately
# run without hooks configured).
CODEX_REQUIRED_FILES = ("AGENTS.md",)
CODEX_OPTIONAL_PROBES = (".codex/hooks.json",)
# Known engine ids the watchdog has an explicit contract for. An engine
# string outside this set is a *truly unknown* engine — the scanner emits
# ``status="unsupported_engine_contract"`` for those rather than silently
# classifying them ``ok`` (the old NON_CONTRACT_ENGINES allowlist behavior
# for codex/antigravity). #1237 r1: "If no Codex-specific check is
# implemented yet, status must say `unsupported_engine_contract` rather
# than silently OK." The same principle applies to any future new engine
# until a contract is added here.
KNOWN_ENGINE_CONTRACTS = frozenset({"claude", "codex"})


@dataclass
class AgentWatch:
    agent: str
    session_type: str
    onboarding_state: str
    status: str
    missing_files: list[str]
    broken_links: list[str]
    missing_managed_claude_block: bool
    heartbeat_present: bool
    heartbeat_age_seconds: int | None
    # Provenance from the registry payload. `engine` defaults to "claude"
    # when the registry lookup is unavailable so legacy listing-only mode
    # continues to assert the Claude-profile set (no regression for
    # pre-#905 installs). `agent_source` defaults to "" (unknown) so the
    # #907 fresh-provision suppression only activates when the registry
    # explicitly tags the agent as dynamic.
    engine: str = "claude"
    agent_source: str = ""
    # #1119: structured fail-soft fields for the scan_error path. Empty
    # on every healthy row. When the watchdog cannot even reach the
    # scan target — e.g. a v2-linux-user-isolated workdir whose mode
    # denies the controller and the host has no passwordless sudo to
    # the isolated agent user — the per-agent try/except in ``main()``
    # constructs a ``status="scan_error"`` row with ``error_kind`` set
    # to a stable token (``permission_denied`` for ``PermissionError``,
    # ``not_found`` for ``FileNotFoundError``, ``os_error`` otherwise)
    # and ``error_path`` set to the path that raised. The librarian-
    # watchdog cron can then route the row to a different escalation
    # bucket than ``status=error`` drift instead of the whole pass
    # crashing on one isolated agent.
    error_kind: str = ""
    error_path: str = ""
    # #1254 (v0.15.0-beta4 Lane G): split the scan_error path into two
    # operator-actionable categories so the librarian-watchdog cron can
    # distinguish a transient controller-side cache miss (operator runs
    # `sg ab-agent-<a> -- $SHELL`, resolves itself on the next tick) from
    # a real iso-UID-side filesystem failure (operator must restore the
    # agent's workdir / re-apply isolation v2). Empty on healthy rows.
    # Values:
    #   - "controller-cache-stale": controller process credentials don't
    #     include the per-agent ab-agent-<a> supplementary group (the
    #     supp-group cache is stale on this shell). The iso UID owns the
    #     workdir mode 2770/ab-agent-<a> and a fresh shell would read it
    #     fine — no admin action required, operator runs `sg` or restarts
    #     the controller shell.
    #   - "iso-uid-side": the iso UID itself cannot read its own workdir
    #     (mode/ownership corruption, broken ACL, missing setgid bit).
    #     Genuine drift; admin action required.
    error_category: str = ""
    # #1266 (v0.15.0-beta4 Lane G): fresh-install detection. True when the
    # admin onboarding marker `state/agents/<a>/onboarding-pending` exists
    # OR the agent's home directory is younger than
    # BRIDGE_WATCHDOG_FRESH_INSTALL_WINDOW_SECS (default 600s = 10 min) and
    # no `onboarding-complete` marker is present. The daemon drift-task
    # writer (process_watchdog_report) lowers the task priority to `low`
    # when every problem row is fresh_install=True so first-run admins do
    # not see a "high priority drift" alert as their first impression.
    fresh_install: bool = False
    # #1254 (v0.15.0-beta4 Lane G): set when a `state/agents/<a>/restart.
    # in-progress` marker is active (state=in_progress, PID alive, within
    # TTL). The daemon drops drift tasks for these rows so an agent that
    # is currently mid-restart does not trigger a high-priority drift
    # alert that the next tick (60s later) will obsolete anyway.
    restart_in_progress: bool = False


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


# Directory basenames under $BRIDGE_AGENT_HOME_ROOT that are bridge-managed
# infrastructure rather than per-agent homes; the watchdog skips them.
# Mirrors bridge-doctor.py:ORPHAN_SKIP_NAMES — keep the two lists in lockstep.
WATCHDOG_SKIP_NAMES = frozenset({"_template", "shared"})


# Registry-provenance map shared between the loader and the scan loop.
# Keys are agent ids (basename of `agents/<name>`); values are dicts with
# the subset of registry fields the watchdog needs:
#   - "engine":       "claude" | "codex" | ""
#   - "agent_source": "static" | "dynamic" | ""
#   - "workdir":      absolute path to the per-agent runtime workdir
#                     (#1108). On v2 layouts this is
#                     `$BRIDGE_DATA_ROOT/agents/<a>/workdir`, the tree
#                     the materialization step authors the .md profile
#                     into. Empty for legacy/v1 installs where the
#                     tracked-tree dir IS the runtime profile.
# A dedicated type alias keeps the signatures readable without dragging
# the whole registry schema into the watchdog.
RegistryMeta = dict[str, dict[str, str]]


def list_agent_dirs(
    root: Path,
    selected: list[str],
    registry_ids: set[str] | None = None,
) -> tuple[list[Path], list[str]]:
    """Enumerate per-agent home directories to scan.

    Returns (scan_paths, orphan_names).

    When ``registry_ids`` is provided (registry-anchored mode, default), only
    directories whose basename appears in the registry are scanned. Directories
    on disk that are not in the registry are returned in ``orphan_names`` so
    the caller can surface them under a separate ``orphan_directories`` alert
    bucket — they no longer drive ``profile_drift`` warns (refs queue #4796).

    When ``registry_ids`` is ``None``, every directory is scanned (legacy
    behavior, used only when the caller passes ``--no-registry-anchored``).

    When ``selected`` is non-empty, both filters defer to the explicit
    selection so ``agent-bridge watchdog scan <agent>`` keeps working even
    if the registry lookup failed.
    """
    if not root.exists():
        return [], []
    paths: list[Path] = []
    orphans: list[str] = []
    selected_set = set(selected)
    for path in sorted(root.iterdir()):
        if not path.is_dir():
            continue
        if path.name.startswith(".") or path.name in WATCHDOG_SKIP_NAMES:
            continue
        if selected:
            if path.name in selected_set:
                paths.append(path)
            continue
        if registry_ids is not None and path.name not in registry_ids:
            orphans.append(path.name)
            continue
        paths.append(path)
    return paths, orphans


def load_registry_agent_ids(
    args: argparse.Namespace,
    bridge_home: Path,
) -> tuple[set[str] | None, RegistryMeta]:
    """Return ``(ids, meta)`` from ``agent registry --json``.

    ``ids`` is the set of registered agent ids used to anchor the directory
    enumeration. ``meta`` is a per-id provenance map (``engine`` +
    ``agent_source``) consumed by the scan loop to apply the engine-aware
    profile check (#905) and the dynamic-agent fresh-state suppression (#907).

    Returns ``(None, {})`` when registry-anchoring is disabled or the lookup
    fails; the caller falls back to the legacy listing-only mode in that case
    so the watchdog never goes silent because of a broken registry endpoint.
    The empty meta map then makes every agent default to ``engine=claude``
    (preserving pre-#905 behavior) and ``agent_source=""`` (so #907's
    dynamic-only suppression is never accidentally triggered for unknown
    provenance).

    Tests inject ``--agent-registry-json <file>`` to skip the subprocess; the
    file shape mirrors ``bridge-doctor.py`` (JSON array of objects with an
    ``id`` field, optionally ``engine`` + ``agent_source``) so the same
    fixtures work for both detectors.
    """
    if args.agent_registry_json:
        path = Path(args.agent_registry_json).expanduser()
        if not path.is_file():
            print(
                f"[bridge-watchdog] --agent-registry-json file not found: {path}",
                file=sys.stderr,
            )
            return None, {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(
                f"[bridge-watchdog] --agent-registry-json unreadable ({exc}); "
                "falling back to listing-only enumeration",
                file=sys.stderr,
            )
            return None, {}
        return _registry_ids_from_payload(data)

    binary = args.agent_bridge or os.environ.get("BRIDGE_AGENT_BRIDGE_BIN", "").strip()
    if not binary:
        sibling = Path(__file__).resolve().parent / "agent-bridge"
        if sibling.is_file():
            binary = str(sibling)
        else:
            located = shutil.which("agent-bridge")
            if not located:
                print(
                    "[bridge-watchdog] agent-bridge binary not found; "
                    "falling back to listing-only enumeration",
                    file=sys.stderr,
                )
                return None, {}
            binary = located
    env = os.environ.copy()
    env["BRIDGE_HOME"] = str(bridge_home)
    try:
        proc = subprocess.run(
            [binary, "agent", "registry", "--json"],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        stderr = getattr(exc, "stderr", "") or ""
        print(
            f"[bridge-watchdog] agent registry --json failed ({type(exc).__name__}: "
            f"{stderr.strip() or exc}); falling back to listing-only enumeration",
            file=sys.stderr,
        )
        return None, {}
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        print(
            f"[bridge-watchdog] agent registry --json returned invalid JSON ({exc}); "
            "falling back to listing-only enumeration",
            file=sys.stderr,
        )
        return None, {}
    return _registry_ids_from_payload(data)


def _registry_ids_from_payload(
    data: object,
) -> tuple[set[str] | None, RegistryMeta]:
    if not isinstance(data, list):
        print(
            "[bridge-watchdog] agent registry payload is not a JSON array; "
            "falling back to listing-only enumeration",
            file=sys.stderr,
        )
        return None, {}
    ids: set[str] = set()
    meta: RegistryMeta = {}
    for row in data:
        if not isinstance(row, dict):
            continue
        agent_id = str(row.get("id") or "").strip()
        if not agent_id:
            continue
        ids.add(agent_id)
        # Surface engine + agent_source so the scan loop can apply the
        # engine-aware profile check (#905) and the dynamic-agent
        # fresh-state suppression (#907). Missing fields → empty string;
        # the scan loop maps empty engine → "claude" (legacy behavior)
        # and empty source → no #907 suppression (conservative).
        # `workdir` (#1108): the v2 runtime profile path. The registry
        # producer (`bridge-agent.sh:run_registry`) populates this from
        # `bridge_agent_workdir`, which on a v2 install returns
        # `$BRIDGE_DATA_ROOT/agents/<a>/workdir` — the tree the
        # materialization step writes the canonical CLAUDE.md / SOUL.md
        # / SESSION-TYPE.md / MEMORY*.md into. Without this signal the
        # watchdog walked the tracked profile-template tree
        # ($BRIDGE_HOME/agents/<a>/) on v2 and reported every runtime
        # .md as `missing_files`. Empty string falls back to the legacy
        # `<root>/<name>` path so the v1 / no-registry path is unchanged.
        meta[agent_id] = {
            "engine": str(row.get("engine") or "").strip(),
            "agent_source": str(row.get("agent_source") or "").strip(),
            "workdir": str(row.get("workdir") or "").strip(),
        }
    return ids, meta


def _isolated_workdir_owner(workdir: Path) -> str | None:
    """Return the isolated-agent OS user that owns ``workdir``, or ``None``.

    Phase 2: delegates to the canonical
    ``bridge_iso_paths.isolated_workdir_owner`` so the lstat-owner +
    pwd-lookup + `agent-bridge-` prefix probe lives in one place. The
    canonical helper has additional recovery (gid-fallback via
    pwd.getpwall when stat.st_uid lookup returns the controller),
    which the watchdog now inherits for free.

    Returns None when the canonical helper is unavailable (import
    failed, non-Linux host, etc.).
    """
    if _isolated_workdir_owner_canonical is None:
        return None
    return _isolated_workdir_owner_canonical(workdir)


def _sudo_test(os_user: str, flag: str, path: Path) -> int | None:
    """Run ``sudo -n -u <os_user> test <flag> <path>``; return rc or ``None``.

    Phase 2: delegates to canonical ``bridge_iso_paths.sudo_run_as``.
    The wrapper translates the canonical's `rc=127 = sudo missing`
    contract back to `None` so existing watchdog callers (which map
    `None → structured scan_error`) keep working unchanged.
    """
    if _sudo_run_as_canonical is None:
        return None
    rc = _sudo_run_as_canonical(os_user, "test", flag, str(path))
    if rc == 127:
        return None
    return rc


def resolve_scan_path(
    agent_name: str,
    default_path: Path,
    registry_meta: RegistryMeta,
) -> Path:
    """Resolve the on-disk directory the watchdog should actually scan
    for ``agent_name`` (#1108).

    The watchdog used to scan the directory under
    ``$BRIDGE_AGENT_HOME_ROOT/<name>`` unconditionally. On a v2 layout
    install (`bridge_resolve_layout` → ``v2``) that path is the tracked
    profile-template tree — typically empty or holding only ``.claude/``
    + a handful of symlinks. The actual runtime profile (the canonical
    CLAUDE.md / SOUL.md / SESSION-TYPE.md / MEMORY*.md materialized by
    ``bridge_layout_materialize_identity``) lives at
    ``$BRIDGE_DATA_ROOT/agents/<name>/workdir/``. Scanning the wrong
    tree produced a false-positive ``status: error,
    missing_files: CLAUDE.md, SOUL.md, …`` on every v2 agent on every
    run, and the librarian-watchdog cron then enqueued phantom drift
    tasks to the admin inbox.

    Resolution rule:

      * If the registry payload exposes a ``workdir`` for this agent
        (``bridge_agent_workdir`` propagated via
        ``bridge-agent.sh:run_registry``) **and** that path exists on
        disk, scan it. On v2 that path is the runtime workdir; on a
        legacy install it equals the tracked-tree dir, so the behavior
        is unchanged.
      * Otherwise fall through to ``default_path`` — the legacy
        ``<agent_home_root>/<name>`` location the caller already
        computed from ``list_agent_dirs``. This preserves backward
        compat for v1 installs, the ``--no-registry-anchored`` legacy
        mode, and the fallback enumeration that fires when the registry
        endpoint is unavailable.

    Existence is checked because a registry ``workdir`` whose directory
    is missing is itself drift the watchdog must surface (status=error
    via ``missing_files``) — scanning the present-on-disk default is
    the closest signal in that case. The materialize step also runs at
    agent-create time on v2, so an existing v2 agent should always have
    a populated workdir directory; a missing one is genuine drift.

    Issue #1119: on a v2-linux-user-isolated install, the workdir is
    chowned to ``agent-bridge-<slug>:ab-agent-<slug>`` mode ``0700``
    (or ``2750`` with setgid + ACLs). Controller-side ``Path.is_dir()``
    walks every ancestor's ``x`` bit and raises ``PermissionError`` on
    a workdir whose mode denies the controller — which kills the whole
    watchdog walk before any agent's row is scanned. Two-stage
    resolution to avoid that:

      1. Try direct ``is_dir()``. On ``PermissionError``, drop down to
         step 2 instead of propagating.
      2. If the workdir's owner looks like an isolated agent account
         (``agent-bridge-<slug>``) and the host has passwordless
         ``sudo`` to that user available, shell out to
         ``sudo -n -u <iso> test -d <workdir>``. ``rc == 0`` means the
         workdir exists; we return it as the scan path (per-file reads
         inside ``scan_agent`` will fall through their own sudo-aware
         helpers / structured error path).
      3. Otherwise re-raise the ``PermissionError``. The caller wraps
         the resolve+scan in a per-agent try/except that maps that to
         a ``status: scan_error`` row, preserving the watchdog's
         "diagnostic of last resort never crashes" contract.
    """
    workdir_str = registry_meta.get(agent_name, {}).get("workdir", "")
    if workdir_str:
        candidate = Path(workdir_str).expanduser()
        try:
            if candidate.is_dir():
                return candidate
        except PermissionError:
            # #1119: the controller can't peek into a v2-isolated
            # workdir. Try a sudo-helper probe before giving up — if
            # the workdir does exist, scanning it (and surfacing the
            # per-file reads as structured errors) is more useful than
            # silently falling back to the empty tracked-tree default.
            os_user = _isolated_workdir_owner(candidate)
            if os_user is not None:
                rc = _sudo_test(os_user, "-d", candidate)
                if rc == 0:
                    return candidate
            raise
    return default_path


def collect_broken_links(agent_dir: Path) -> list[str]:
    broken = []
    for path in agent_dir.rglob("*"):
        if path.is_symlink() and not path.exists():
            broken.append(f"{path.relative_to(agent_dir)} -> {os.readlink(path)}")
    return broken


def parse_session_type(agent_dir: Path) -> tuple[str, str]:
    session_type = "unknown"
    onboarding_state = "missing"
    path = agent_dir / "SESSION-TYPE.md"
    if not path.exists():
        return session_type, onboarding_state
    text = read_text(path)
    session_match = re.search(r"Session Type:\s*([A-Za-z0-9._-]+)", text)
    onboarding_match = re.search(r"Onboarding State:\s*([A-Za-z0-9._-]+)", text)
    if session_match:
        session_type = session_match.group(1).strip()
    if onboarding_match:
        onboarding_state = onboarding_match.group(1).strip()
    return session_type, onboarding_state


def heartbeat_age_seconds(agent_dir: Path) -> tuple[bool, int | None]:
    path = agent_dir / "HEARTBEAT.md"
    if not path.exists():
        return False, None
    age = int(datetime.now(timezone.utc).timestamp() - path.stat().st_mtime)
    return True, max(age, 0)


# Session types that have no interactive first-session onboarding flow by
# design (see #241). `dynamic` agents are auto-provisioned promote-only /
# task-drain workers such as `librarian`; `cron` agents are scheduler-
# launched and never see a human. Leaving SESSION-TYPE.md at
# `Onboarding State: pending` is the steady-state for these classes, so
# flagging them as `warn` creates alert-fatigue on every scan.
NON_ONBOARDING_SESSION_TYPES = frozenset({"dynamic", "cron"})

# #1266 (v0.15.0-beta4 Lane G): static session types ship with the
# template-default ``Onboarding State: complete`` (see
# ``agents/_template/session-types/static-claude.md``) and therefore have
# no operator-actionable onboarding signal of their own. The markdown
# render suppresses the ``onboarding_state:`` line for these rows so the
# operator's eyes are not pulled to a field that will always say
# ``complete`` (or, in the SESSION-TYPE-missing edge case, ``missing`` —
# which is then surfaced via the missing_files / managed-block paths,
# NOT via a phantom ``onboarding_state: missing`` line). The JSON payload
# still carries the parsed value so downstream consumers (alert rules,
# audit) can read it.
STATIC_SESSION_TYPES = frozenset({"static", "static-claude", "static-codex"})


# #1266 (v0.15.0-beta4 Lane G): fresh-install detection window. The
# daemon's drift-task writer lowers the priority to `low` when every
# problem row carries `fresh_install=True`, so the first watchdog tick
# after an `agent-bridge init` does NOT enqueue a high-priority drift
# alert as the operator's first install impression. Tunable via env.
DEFAULT_FRESH_INSTALL_WINDOW_SECS = 600


def fresh_install_window_secs() -> int:
    """Resolve the fresh-install age window from the env, with a safe
    fall-through to ``DEFAULT_FRESH_INSTALL_WINDOW_SECS``. A
    non-integer / non-positive override is treated as the default so
    operator typos cannot disarm the gate entirely."""
    raw = os.environ.get("BRIDGE_WATCHDOG_FRESH_INSTALL_WINDOW_SECS", "")
    try:
        parsed = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_FRESH_INSTALL_WINDOW_SECS
    if parsed <= 0:
        return DEFAULT_FRESH_INSTALL_WINDOW_SECS
    return parsed


def detect_fresh_install(
    state_dir: Path | None,
    agent_name: str,
    agent_home_dir: Path,
) -> bool:
    """Return True when this agent looks like a fresh-install candidate
    (Lane G #1266).

    Decision matrix (any branch positive ⇒ True):

      1. ``state/agents/<a>/onboarding-pending`` marker file exists.
         (Authored by ``bridge-init.sh``'s fresh-install admin scaffold —
         see ``bridge_init_write_onboarding_marker``.)
      2. ``state/agents/<a>/onboarding-complete`` marker is ABSENT and
         the agent home directory's mtime is within
         ``fresh_install_window_secs()`` (default 600s = 10 min). This
         covers the case where ``bridge-init.sh`` did not write the
         marker (older install path, dry-run partial recovery) but the
         agent was clearly created in the last few minutes.

    Returns False when the state_dir is unknown (``None`` — caller could
    not resolve ``$BRIDGE_HOME/state``) so the detection is conservative:
    a missing state dir falls back to the legacy "every drift is high
    priority" behavior rather than silently downgrading every drift.
    """
    if state_dir is None:
        return False
    agent_state_dir = state_dir / "agents" / agent_name
    try:
        if (agent_state_dir / "onboarding-pending").is_file():
            return True
        if (agent_state_dir / "onboarding-complete").is_file():
            return False
    except (PermissionError, OSError):
        # Controller cannot reach the state dir for this agent — the
        # markerless mtime branch below is the fallback signal.
        pass
    try:
        home_mtime = agent_home_dir.stat().st_mtime
    except (PermissionError, FileNotFoundError, OSError):
        return False
    now_ts = datetime.now(timezone.utc).timestamp()
    age = int(now_ts - home_mtime)
    if age < 0:
        # Clock skew defense: a future mtime is treated as "not fresh"
        # rather than the alternative ("always fresh forever") so a
        # mis-set clock cannot disarm every drift task indefinitely.
        return False
    return age <= fresh_install_window_secs()


def detect_restart_in_progress(
    state_dir: Path | None,
    agent_name: str,
) -> bool:
    """Return True when ``state/agents/<a>/restart.in-progress`` is
    currently active (Lane G #1254, reusing the Lane C1 marker contract
    from ``lib/bridge-agents.sh:bridge_agent_restart_marker_active``).

    Marker schema (see ``lib/bridge-agents.sh`` §"Issue #1251"):
      pid=<orchestrator-pid>
      started=<unix-ts>
      ttl=<seconds>
      state=in_progress|rolled_back|completed
      reason=<structured>     # populated only on state=rolled_back

    Active = ``state=in_progress`` AND ``kill -0 <pid>`` succeeds AND
    ``now < started + ttl``. A terminal marker (state=rolled_back) is
    NOT active — the operator audit trail persists, but the drift-skip
    window has already closed and the watchdog should re-engage.

    Conservative on resolution failures: a missing state_dir, an
    unreadable marker file, or a malformed field returns False so the
    real drift signal is never suppressed by a false marker reading.
    """
    if state_dir is None:
        return False
    marker = state_dir / "agents" / agent_name / "restart.in-progress"
    try:
        if not marker.is_file():
            return False
        text = marker.read_text(encoding="utf-8", errors="ignore")
    except (PermissionError, FileNotFoundError, OSError):
        return False
    fields: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    if fields.get("state") != "in_progress":
        return False
    pid_raw = fields.get("pid", "")
    started_raw = fields.get("started", "")
    ttl_raw = fields.get("ttl", "")
    if not (pid_raw.isdigit() and started_raw.isdigit() and ttl_raw.isdigit()):
        return False
    pid = int(pid_raw)
    started = int(started_raw)
    ttl = int(ttl_raw)
    # PID liveness gate — mirror lib/bridge-agents.sh marker_active r1
    # finding 2: a crashed orchestrator should not hold the watchdog
    # hostage for the full TTL window.
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError, OSError):
        return False
    now_ts = int(datetime.now(timezone.utc).timestamp())
    return now_ts < started + ttl


def classify_scan_error_category(
    error_kind: str,
    error_path: str,
    workdir: Path | None,
) -> str:
    """Split the scan_error rows into operator-actionable buckets
    (Lane G #1254).

    Rules:
      * Empty ``error_kind`` (= no error) → empty string.
      * ``error_kind != "permission_denied"`` (e.g. ``not_found`` /
        ``os_error``) → "iso-uid-side". Those are genuine filesystem
        failures the operator must investigate; lumping them into the
        cache-stale bucket would mask real drift.
      * ``error_kind == "permission_denied"`` AND the controller can
        still ``stat`` the workdir's parent (i.e. the directory exists
        and is traversable) → "controller-cache-stale". This is the
        #1246 shape: the workdir was chgrp'd to ab-agent-<a> mode 2770
        but the controller process's supplementary-group cache does not
        include that group. A fresh shell would read it fine.
      * ``error_kind == "permission_denied"`` AND the controller cannot
        even ``stat`` the workdir / its parent → "iso-uid-side". The
        denial is structural (e.g. parent mode 0000, missing ancestor)
        and not something a supp-group refresh will fix.
    """
    if not error_kind:
        return ""
    if error_kind != "permission_denied":
        return "iso-uid-side"
    if workdir is None:
        return "iso-uid-side"
    try:
        # Can the controller see the workdir itself exist? `exists()`
        # walks ancestor x-bits, so a workdir under a 0000-mode parent
        # raises PermissionError or returns False — both signal
        # iso-uid-side. A True here means the workdir is present, the
        # parent is traversable, and the inability to read inside is
        # the controller-side group cache.
        if not workdir.exists():
            return "iso-uid-side"
    except (PermissionError, OSError):
        return "iso-uid-side"
    return "controller-cache-stale"


# #1237: Legacy alias for the "engines that get no required-file check
# under the Claude-default path." Pre-#1237 this set was
# ``frozenset({"codex", "antigravity"})``; codex has moved to its own
# engine-native contract and antigravity now surfaces as
# ``unsupported_engine_contract`` (see ``has_known_engine_contract``).
# Kept as an empty allowlist so any downstream import keeps resolving
# without behaviorally bringing back the silent-OK path.
NON_CONTRACT_ENGINES: frozenset[str] = frozenset()


def is_claude_engine(engine: str) -> bool:
    """True when the engine string maps to the Claude contract (Claude or
    the conservative empty-string default kept for legacy registry rows).
    """
    return engine in ("", "claude")


def is_codex_engine(engine: str) -> bool:
    """True when the engine string maps to the Codex contract (#1237)."""
    return engine == "codex"


def has_known_engine_contract(engine: str) -> bool:
    """True when the watchdog has an implemented engine-native contract for
    ``engine``. Engines outside this set are classified as
    ``unsupported_engine_contract`` in :func:`classify_status` rather than
    being silently held to the Claude default or silently classified ``ok``
    (#1237 r1).
    """
    return is_claude_engine(engine) or is_codex_engine(engine)


def has_home_profile_contract(engine: str, agent_source: str) -> bool:
    """Whether the watchdog should hold this agent to the Claude-style
    home-profile contract: the ``CLAUDE_REQUIRED_FILES`` set, the managed
    ``CLAUDE.md`` block, and the ``SESSION-TYPE.md`` onboarding state.

    Issues #905 / #907 each special-cased one slice of this. #1237 split
    the Codex case out into its own engine-native contract (see
    :func:`has_codex_profile_contract`) instead of leaving codex as a
    silent-OK allowlist entry. ``has_home_profile_contract`` now means
    *Claude-specific* contract.

    The contract holds for:

      - Claude agents, static or unknown-source.

    The contract is waived for:

      - ``agent_source == "dynamic"`` — a full exemption regardless of
        engine. Dynamic agents are ad-hoc spawns
        (``agent-bridge --<engine> --name``) that never run
        ``bridge_scaffold_agent_home``, so legitimately have no profile
        files, no managed block, and no SESSION-TYPE.md. The watchdog has
        no finer "scaffolded vs ad-hoc" signal than ``agent_source``.
      - Any non-Claude engine (codex has its own contract; unknown
        engines surface as ``unsupported_engine_contract`` and do not
        get the Claude-profile drift check overlaid on top).
    """
    if agent_source == "dynamic":
        return False
    return is_claude_engine(engine)


def has_codex_profile_contract(engine: str, agent_source: str) -> bool:
    """Whether the watchdog should hold this agent to the Codex contract
    (``CODEX_REQUIRED_FILES``). Mirrors ``has_home_profile_contract`` but
    gates on the codex engine string. Dynamic agents still get a full
    exemption — they may legitimately be bare ad-hoc spawns (#907).
    """
    if agent_source == "dynamic":
        return False
    return is_codex_engine(engine)


def required_profile_files(engine: str, agent_source: str = "") -> tuple[str, ...]:
    """Required profile-file set for an agent.

    Returns the engine-appropriate required-file tuple:

      - Claude under the home-profile contract → ``CLAUDE_REQUIRED_FILES``
      - Codex under the engine-native contract (#1237) →
        ``CODEX_REQUIRED_FILES``
      - Anything else (dynamic source, unknown engine, antigravity) →
        empty tuple so the missing-files check is a no-op.

    ``agent_source`` defaults to ``""`` so a legacy positional
    ``required_profile_files(engine)`` call keeps the conservative
    Claude-default behavior for an unknown source.
    """
    if has_home_profile_contract(engine, agent_source):
        return CLAUDE_REQUIRED_FILES
    if has_codex_profile_contract(engine, agent_source):
        return CODEX_REQUIRED_FILES
    return ()


def classify_status(
    missing_files: list[str],
    broken_links: list[str],
    onboarding_state: str,
    missing_block: bool,
    session_type: str = "",
    agent_source: str = "",
    engine: str = "claude",
) -> str:
    # Engine routing:
    #   - Claude under contract: required files + managed block +
    #     onboarding staleness drive error/warn (#905 / #907 gates apply).
    #   - Codex under contract (#1237): required Codex files drive error;
    #     managed-CLAUDE-block and onboarding signals are not part of the
    #     Codex contract and are ignored.
    #   - Dynamic source (any engine): the contract is waived (#907).
    #     Broken links still surface as warn — that is real drift, not a
    #     fresh-provision default.
    #   - Unknown engines with no implemented contract (e.g. antigravity
    #     until a contract is added): return ``unsupported_engine_contract``
    #     so the operator sees the row instead of a silent ok (#1237 r1).
    #     A dynamic agent on an unknown engine is still reported under
    #     ``unsupported_engine_contract`` — its mere presence is the
    #     watchdog signal here, not a per-file drift result.
    claude_contract = has_home_profile_contract(engine, agent_source)
    codex_contract = has_codex_profile_contract(engine, agent_source)
    if not has_known_engine_contract(engine):
        # Surface broken-link drift even on unknown-engine rows; that
        # signal is engine-agnostic and never lies.
        if broken_links:
            return "warn"
        return "unsupported_engine_contract"
    if missing_files and (claude_contract or codex_contract):
        return "error"
    # Claude-only signals: managed block + onboarding staleness.
    onboarding_stale = (
        claude_contract
        and onboarding_state in {"pending", "missing"}
        and session_type not in NON_ONBOARDING_SESSION_TYPES
    )
    effective_missing_block = missing_block if claude_contract else False
    if broken_links or effective_missing_block or onboarding_stale:
        return "warn"
    return "ok"


def scan_agent(
    agent_dir: Path,
    engine: str = "claude",
    agent_source: str = "",
    agent_name: str | None = None,
    state_dir: Path | None = None,
    fresh_install_home_dir: Path | None = None,
) -> AgentWatch:
    # `agent_name` (#1108) is the registry id, threaded through
    # explicitly because on v2 layouts ``agent_dir`` resolves to
    # ``$BRIDGE_DATA_ROOT/agents/<a>/workdir`` — so ``agent_dir.name``
    # is "workdir", not the agent id. Falling back to
    # ``agent_dir.name`` keeps every legacy caller (smoke tests,
    # ``watchdog scan <agent>`` ad-hoc invocations that pass a Path
    # directly) unchanged.
    resolved_name = agent_name if agent_name is not None else agent_dir.name
    # #1266 / #1254 (Lane G): probe the state-dir markers ONCE per agent
    # so both the success path and the structured scan_error path below
    # carry the same fresh_install / restart_in_progress signal. A
    # restart-in-progress agent with a passing scan still has the marker
    # — the daemon's task writer uses the flag to skip the drift task
    # enqueue regardless of which row branch we took.
    fresh_install_dir = fresh_install_home_dir if fresh_install_home_dir is not None else agent_dir
    is_fresh = detect_fresh_install(state_dir, resolved_name, fresh_install_dir)
    is_restarting = detect_restart_in_progress(state_dir, resolved_name)
    # v0.8.8 #715-B / #694: linux-user-isolated agents own
    # `agents/<name>/CLAUDE.md` as `agent-bridge-<name>:<group> 0640`.
    # When the controller process credentials don't include the new
    # group (typical post-migration / post-relogin window), `.exists()`
    # / `.read_text()` on that path raise `PermissionError` and the
    # outer list-comprehension in `main()` propagates the exception —
    # one isolated agent kills the whole watchdog walk and every other
    # agent's row stays stale. Same shape PR #688 handled in
    # `bridge-status.py::pending_upgrade_conflict_count` and PR #695's
    # follow-up `workdir_display`. Wrap the per-agent scan so the row
    # downgrades to a `warn` placeholder and the outer walk continues
    # for the rest of the roster. Missing-files / heartbeat / broken-
    # links fields default to "empty" because we genuinely don't know
    # — surfacing the `permission denied during scan` note on the
    # `broken_links` channel keeps the existing markdown render
    # unchanged (no new `AgentWatch` fields, per spec).
    try:
        required = required_profile_files(engine, agent_source)
        missing_files = [name for name in required if not (agent_dir / name).exists()]
        # The `missing_managed_claude_block` FIELD records actual file
        # state for engines that own a CLAUDE.md. Pre-#1237 this gated on
        # the legacy ``NON_CONTRACT_ENGINES`` allowlist; with the codex
        # contract now engine-native, the check is gated on the Claude
        # engine directly. A dynamic Claude agent still gets an accurate
        # field — #907 keeps the field truthful and suppresses only the
        # classification *signal*, which ``classify_status`` gates through
        # ``has_home_profile_contract``.
        if is_claude_engine(engine):
            claude_text = read_text(agent_dir / "CLAUDE.md") if (agent_dir / "CLAUDE.md").exists() else ""
            missing_block = MANAGED_START not in claude_text or MANAGED_END not in claude_text
        else:
            missing_block = False
        session_type, onboarding_state = parse_session_type(agent_dir)
        heartbeat_present, heartbeat_age = heartbeat_age_seconds(agent_dir)
        broken_links = collect_broken_links(agent_dir)
        status = classify_status(
            missing_files,
            broken_links,
            onboarding_state,
            missing_block,
            session_type,
            agent_source,
            engine,
        )
        return AgentWatch(
            agent=resolved_name,
            session_type=session_type,
            onboarding_state=onboarding_state,
            status=status,
            missing_files=missing_files,
            broken_links=broken_links,
            missing_managed_claude_block=missing_block,
            heartbeat_present=heartbeat_present,
            heartbeat_age_seconds=heartbeat_age,
            engine=engine or "claude",
            agent_source=agent_source,
            fresh_install=is_fresh,
            restart_in_progress=is_restarting,
        )
    except (PermissionError, FileNotFoundError, OSError) as exc:
        # #1119 r2: even when the outer `resolve_scan_path` sudo probe
        # succeeded, the inner file reads above can still raise (the
        # sudo probe only checked `test -d`, not per-file `read`).
        # Emit the structured `scan_error` row in that case too so the
        # contract holds end-to-end on Linux hosts where the controller
        # has sudo for `test -d` but not the named-pipe access the
        # actual reads need.
        if isinstance(exc, PermissionError):
            error_kind = "permission_denied"
        elif isinstance(exc, FileNotFoundError):
            error_kind = "not_found"
        else:
            error_kind = "os_error"
        error_path = getattr(exc, "filename", None) or str(agent_dir)
        print(
            f"[bridge-watchdog] {resolved_name}: "
            f"{type(exc).__name__} during scan ({exc.strerror or exc}); "
            f"path={error_path}",
            file=sys.stderr,
        )
        error_category = classify_scan_error_category(
            error_kind, str(error_path), agent_dir
        )
        return AgentWatch(
            agent=resolved_name,
            session_type="unknown",
            onboarding_state="unknown",
            status="scan_error",
            missing_files=[],
            broken_links=[],
            missing_managed_claude_block=False,
            heartbeat_present=False,
            heartbeat_age_seconds=None,
            engine=engine or "claude",
            agent_source=agent_source,
            error_kind=error_kind,
            error_path=str(error_path),
            error_category=error_category,
            fresh_install=is_fresh,
            restart_in_progress=is_restarting,
        )


def render_markdown(
    records: list[AgentWatch],
    bridge_home: Path,
    orphan_directories: list[str] | None = None,
) -> str:
    now_iso = datetime.now().astimezone().isoformat()
    problems = [item for item in records if item.status != "ok"]
    orphan_directories = orphan_directories or []
    lines = [
        "# Watchdog Report",
        "",
        f"- generated_at: {now_iso}",
        f"- bridge_home: {bridge_home}",
        f"- agents: {len(records)}",
        f"- problems: {len(problems)}",
        f"- orphan_directories: {len(orphan_directories)}",
        "",
    ]
    if orphan_directories:
        # Refs queue #4796: orphan dirs (smoke leaks, manual mkdir) used to
        # surface as profile_drift warns when the watchdog enumerated
        # `agents/` directly. Surface them under a separate bucket so
        # operators can triage with `agent-bridge doctor --detectors
        # orphan-agent-dir` instead of treating them as live-agent drift.
        lines.append("## orphan_directories")
        lines.extend(f"- {name}" for name in orphan_directories)
        lines.append("")
    if not records:
        lines.append("- no agents scanned")
        return "\n".join(lines) + "\n"
    for item in records:
        lines.append(f"## {item.agent}")
        lines.append(f"- status: {item.status}")
        lines.append(f"- engine: {item.engine}")
        if item.agent_source:
            lines.append(f"- agent_source: {item.agent_source}")
        lines.append(f"- session_type: {item.session_type}")
        # #1266 (v0.15.0-beta4 Lane G): suppress the onboarding_state line
        # for static session types in the markdown render. Static-claude /
        # static-codex ship with the template-default
        # ``Onboarding State: complete``; surfacing the field here adds
        # noise without operator signal. The JSON payload still carries
        # the parsed value so downstream consumers can read it.
        if item.session_type not in STATIC_SESSION_TYPES:
            lines.append(f"- onboarding_state: {item.onboarding_state}")
        lines.append(f"- heartbeat_present: {'yes' if item.heartbeat_present else 'no'}")
        if item.heartbeat_age_seconds is not None:
            lines.append(f"- heartbeat_age_seconds: {item.heartbeat_age_seconds}")
        if item.missing_files:
            lines.append(f"- missing_files: {', '.join(item.missing_files)}")
        if item.broken_links:
            lines.append("- broken_links:")
            lines.extend(f"  - {entry}" for entry in item.broken_links)
        if item.missing_managed_claude_block:
            lines.append("- missing_managed_claude_block: yes")
        # #1119: surface the scan_error fields directly under the agent
        # block so a markdown report (the shape `shared/watchdog/latest.md`
        # feeds the operator) names what went wrong and which path raised.
        if item.error_kind:
            lines.append(f"- error_kind: {item.error_kind}")
        # #1254 (Lane G): the operator-actionable error_category split.
        # Only emit when populated (= status=scan_error rows).
        if item.error_category:
            lines.append(f"- error_category: {item.error_category}")
        if item.error_path:
            lines.append(f"- error_path: {item.error_path}")
        # #1266 / #1254 (Lane G): emit fresh_install and restart_in_progress
        # only when true so a healthy row stays compact. The daemon's
        # process_watchdog_report consumes these via the JSON payload, not
        # the markdown body, so a missing line on a healthy row carries no
        # semantic difference for downstream automation.
        if item.fresh_install:
            lines.append("- fresh_install: yes")
        if item.restart_in_progress:
            lines.append("- restart_in_progress: yes")
        if item.status == "ok":
            lines.append("- issues: none")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    # #1233: ``rescan`` is the operator-facing on-demand verb. Both
    # commands run the same registry-anchored scanner; ``rescan`` adds
    # report-file write-back so ``shared/watchdog/latest.md`` refreshes
    # immediately (the daemon cooldown is in ``bridge-daemon.sh``'s
    # ``process_watchdog_report`` and is therefore bypassed by construction
    # when the operator drives the scanner directly). ``--agent <a>`` and
    # ``--json`` work for both. ``scan`` is preserved as compatibility for
    # the daemon tick + legacy ``watchdog scan <agent>`` callers.
    parser.add_argument("command", choices=("scan", "rescan"))
    parser.add_argument("agents", nargs="*")
    parser.add_argument(
        "--agent",
        action="append",
        default=[],
        dest="agent_flag",
        help="scope the scan to a specific agent (repeatable; #1233)",
    )
    parser.add_argument("--bridge-home", default=os.environ.get("BRIDGE_HOME", str(Path.home() / ".agent-bridge")))
    parser.add_argument("--agent-home-root", default=None)
    # #1266 / #1254 (Lane G): the state directory holds the per-agent
    # ``onboarding-pending`` / ``onboarding-complete`` markers and the
    # ``restart.in-progress`` marker. Default to ``<bridge_home>/state``
    # which matches ``$BRIDGE_STATE_DIR`` in ``bridge-lib.sh``; the env
    # var override lets a CI smoke pin a fixture dir.
    parser.add_argument(
        "--state-dir",
        default=os.environ.get("BRIDGE_STATE_DIR", ""),
        help=(
            "state directory holding state/agents/<a>/{onboarding-*,restart.in-progress} "
            "markers (default: $BRIDGE_HOME/state; #1266 / #1254)"
        ),
    )
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--apply",
        action="store_true",
        default=None,
        help=(
            "write the rendered report to <bridge_home>/shared/watchdog/latest.md "
            "(default: true for rescan, false for scan)"
        ),
    )
    # Refs queue #4796: registry-anchored enumeration is the default. Orphan
    # directories under $BRIDGE_AGENT_HOME_ROOT no longer drive profile_drift
    # warns; they surface in the separate `orphan_directories` bucket. Pass
    # --no-registry-anchored to restore the legacy listing-only behavior
    # (every dir is scanned as if it were a registered agent).
    parser.add_argument(
        "--registry-anchored",
        dest="registry_anchored",
        action="store_true",
        default=True,
        help="enumerate agents from `agent registry --json` (default)",
    )
    parser.add_argument(
        "--no-registry-anchored",
        dest="registry_anchored",
        action="store_false",
        help="legacy listing-only enumeration (scan every dir under agents/)",
    )
    parser.add_argument(
        "--agent-bridge",
        default=None,
        help="path to the agent-bridge binary used for the registry query",
    )
    parser.add_argument(
        "--agent-registry-json",
        default=None,
        help="path to a JSON file with the registry payload (test injection)",
    )
    args = parser.parse_args()

    # #1233: ``--agent <name>`` (repeatable) is an alias for the existing
    # positional ``agents`` selector. Merging here keeps the rest of the
    # pipeline single-source (``args.agents``) without reshuffling the
    # registry-anchored filter logic below.
    if args.agent_flag:
        args.agents = list(args.agents) + list(args.agent_flag)

    # #1233: ``--apply`` defaults to True for ``rescan`` (the operator
    # verb whose contract is "refresh latest.md right now"), and False for
    # ``scan`` (the daemon-tick caller that already redirects stdout to
    # the report file itself). An explicit ``--apply`` always wins.
    if args.apply is None:
        apply_to_report_file = args.command == "rescan"
    else:
        apply_to_report_file = bool(args.apply)

    bridge_home = Path(args.bridge_home).expanduser()
    agent_root = Path(args.agent_home_root).expanduser() if args.agent_home_root else bridge_home / "agents"
    # #1266 / #1254 (Lane G): resolve the state-dir marker root once and
    # pass it into each scan_agent. ``--state-dir`` (or
    # ``$BRIDGE_STATE_DIR``) wins; default is ``<bridge_home>/state`` to
    # match bridge-lib.sh's runtime layout. A non-existent state dir
    # falls through to ``None`` so the detection helpers stay
    # conservative (no false-positive fresh_install on a torn-down
    # install).
    state_dir: Path | None = None
    if args.state_dir:
        candidate = Path(args.state_dir).expanduser()
        if candidate.is_dir():
            state_dir = candidate
    else:
        candidate = bridge_home / "state"
        if candidate.is_dir():
            state_dir = candidate
    registry_ids: set[str] | None = None
    registry_meta: RegistryMeta = {}
    if args.registry_anchored:
        # Explicit agent args bypass the registry id filter (so the
        # operator can still scope-scan a single agent even when the
        # registry endpoint is broken), but we still consult the registry
        # for engine + agent_source metadata so #905 / #907 fixes apply
        # to scoped scans too.
        registry_ids, registry_meta = load_registry_agent_ids(args, bridge_home)
        if args.agents:
            # Disable the id filter; keep the meta map.
            registry_ids = None
    scan_paths, orphan_directories = list_agent_dirs(agent_root, args.agents, registry_ids)
    # #1108: redirect each registered agent's scan path to the registry's
    # `workdir` field when it exists on disk. On a v2 layout install that
    # path is `$BRIDGE_DATA_ROOT/agents/<a>/workdir` — the tree the
    # canonical .md profile is materialized into — instead of the
    # tracked-tree dir under `$BRIDGE_HOME/agents/<a>/` (which on v2 holds
    # only `.claude/` + symlinks and produces false-positive
    # `missing_files`). The agent name is threaded through `scan_agent`
    # explicitly so the `agent` field stays the registry id, not the
    # basename of the resolved workdir path (which is "workdir" on v2).
    #
    # #1119: wrap the per-agent resolve+scan in a try/except so a single
    # ``PermissionError`` from a v2-linux-user-isolated workdir does not
    # kill the whole pass. The watchdog is the diagnostic of last resort
    # — when the librarian-watchdog cron tick or an operator-typed
    # ``watchdog scan`` hits one unreadable workdir, every *other*
    # agent's row must still appear. Build a structured ``scan_error``
    # row for the unreachable agent and continue. ``scan_agent`` itself
    # already wraps the inside-the-workdir reads, but the outer
    # resolve_scan_path → list_dir bootstrap can raise before
    # ``scan_agent`` is even invoked (the original #1119 crash site at
    # ``resolve_scan_path``'s ``candidate.is_dir()``), and a future
    # caller of either helper outside ``scan_agent``'s try/except would
    # re-introduce the same crash class — the outer guard closes both.
    records: list[AgentWatch] = []
    for path in scan_paths:
        agent_name = path.name
        agent_meta = registry_meta.get(agent_name, {})
        engine = agent_meta.get("engine") or "claude"
        agent_source = agent_meta.get("agent_source", "")
        try:
            target = resolve_scan_path(agent_name, path, registry_meta)
            records.append(
                scan_agent(
                    target,
                    engine=engine,
                    agent_source=agent_source,
                    agent_name=agent_name,
                    state_dir=state_dir,
                    # The tracked-tree dir (`path`) is the most stable
                    # fresh-install signal: on v2 it is created during
                    # `bridge_scaffold_agent_home`, then the workdir
                    # materialization step writes the runtime profile
                    # into the v2 workdir. Both are touched in the same
                    # `agent create` call, but `path`'s mtime is
                    # preserved across watchdog ticks (the runtime
                    # workdir can be re-touched by hooks). Pass `path`
                    # explicitly so the fresh-install age window is
                    # measured against the scaffold mtime, not the
                    # potentially-younger materialize target.
                    fresh_install_home_dir=path,
                )
            )
        except (PermissionError, FileNotFoundError, OSError) as exc:
            # Structured fail-soft row. ``error_kind`` is a stable token
            # the librarian-watchdog cron and downstream alert rules can
            # branch on without parsing the human-readable summary.
            # ``error_path`` is the path that raised (when the exception
            # carries one) so the operator can find which workdir is
            # unreachable. Order matters: PermissionError and
            # FileNotFoundError are subclasses of OSError, so they must
            # be matched first.
            if isinstance(exc, PermissionError):
                error_kind = "permission_denied"
            elif isinstance(exc, FileNotFoundError):
                error_kind = "not_found"
            else:
                error_kind = "os_error"
            error_path = getattr(exc, "filename", "") or ""
            if not error_path:
                workdir_str = agent_meta.get("workdir", "")
                error_path = workdir_str or str(path)
            print(
                f"[bridge-watchdog] {agent_name}: scan_error "
                f"({error_kind}, path={error_path!r}); continuing with "
                f"the rest of the roster (#1119)",
                file=sys.stderr,
            )
            # #1254 (Lane G): classify the outer scan_error too. The
            # workdir candidate we hand to ``classify_scan_error_category``
            # is whichever of the registry workdir / on-disk path the
            # caller has — neither is guaranteed reachable, so the
            # helper itself is exception-tolerant. ``state_dir``
            # markers are probed the same way as the success path so
            # an agent that's mid-restart (or fresh-installed) still
            # gets the matching flags on its scan_error row.
            workdir_candidate: Path | None
            workdir_str_for_check = agent_meta.get("workdir", "")
            if workdir_str_for_check:
                workdir_candidate = Path(workdir_str_for_check).expanduser()
            else:
                workdir_candidate = path
            error_category = classify_scan_error_category(
                error_kind, error_path, workdir_candidate
            )
            is_fresh = detect_fresh_install(state_dir, agent_name, path)
            is_restarting = detect_restart_in_progress(state_dir, agent_name)
            records.append(
                AgentWatch(
                    agent=agent_name,
                    session_type="unknown",
                    onboarding_state="unknown",
                    status="scan_error",
                    missing_files=[],
                    broken_links=[],
                    missing_managed_claude_block=False,
                    heartbeat_present=False,
                    heartbeat_age_seconds=None,
                    engine=engine,
                    agent_source=agent_source,
                    error_kind=error_kind,
                    error_path=error_path,
                    error_category=error_category,
                    fresh_install=is_fresh,
                    restart_in_progress=is_restarting,
                )
            )
    # #1254 (Lane G): an agent whose `restart.in-progress` marker is
    # active is intentionally mid-restart — the snapshot+marker contract
    # from #1251 expects the next watchdog tick (after the TTL window) to
    # see the fresh state. Suppress those rows from the problem count
    # entirely so the daemon's process_watchdog_report does NOT enqueue
    # a drift task for a transient mid-restart window. ``problem_count``
    # remains the authoritative signal the daemon reads.
    #
    # #1266 (Lane G): the ``fresh_install_only`` derived flag tells the
    # daemon "every problem row in this report is a fresh-install
    # candidate — file at priority=low instead of high". When mixed
    # (some fresh, some not), the high-priority path is preserved.
    effective_problems = [
        item for item in records
        if item.status != "ok" and not item.restart_in_progress
    ]
    payload = {
        "generated_at": datetime.now().astimezone().isoformat(),
        "bridge_home": str(bridge_home),
        "agent_home_root": str(agent_root),
        "agent_count": len(records),
        "problem_count": len(effective_problems),
        "fresh_install_only": bool(effective_problems) and all(
            item.fresh_install for item in effective_problems
        ),
        "restart_in_progress_count": sum(
            1 for item in records if item.restart_in_progress
        ),
        "orphan_directory_count": len(orphan_directories),
        "orphan_directories": orphan_directories,
        "agents": [asdict(item) for item in records],
    }
    rendered_markdown = render_markdown(records, bridge_home, orphan_directories)
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(rendered_markdown, end="")
    # #1233: write the markdown report to the canonical
    # ``<bridge_home>/shared/watchdog/latest.md`` location so the operator
    # who typed ``agent-bridge watchdog rescan`` sees the refresh
    # immediately, without waiting for the next daemon tick. The daemon
    # tick path (``bridge-daemon.sh:process_watchdog_report``) keeps
    # writing the same file via stdout redirect, so steady-state behavior
    # is unchanged. Existence of the parent directory is ensured here so
    # the verb works on a fresh BRIDGE_HOME where the daemon has never
    # ticked.
    if apply_to_report_file:
        report_path = bridge_home / "shared" / "watchdog" / "latest.md"
        try:
            report_path.parent.mkdir(parents=True, exist_ok=True)
            report_path.write_text(rendered_markdown, encoding="utf-8")
        except OSError as exc:
            print(
                f"[bridge-watchdog] failed to write report file {report_path}: {exc}",
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
