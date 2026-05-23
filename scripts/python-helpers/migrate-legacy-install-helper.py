#!/usr/bin/env python3
"""
scripts/python-helpers/migrate-legacy-install-helper.py

Python core for the legacy-install migrator (scripts/migrate-legacy-install.sh).
Implements: export, plan, apply, verify subcommands.

Design constraints:
- Never called from bridge-upgrade.sh / bridge-init.sh / bridge-bootstrap.sh.
- apply is explicit / off-by-default; refuses a non-empty target.
- Secrets are never copied; apply prompts / reads via file or env.
- No heredoc-stdin or process-substitution-into-reader (footgun #11).
- Classification: portable / non-portable / secret; cross-class moves refused.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MIGRATOR_SCHEMA_VERSION = 1

# Canonical per-agent identity files — portable, written into agent_home.
IDENTITY_FILES = (
    "SOUL.md",
    "SESSION-TYPE.md",
    "MEMORY.md",
    "MEMORY-SCHEMA.md",
    "HEARTBEAT.md",
    "CHANGE-POLICY.md",
    "TOOLS.md",
    "CLAUDE.md",
    "AGENTS.md",
    "NEXT-SESSION.md",
    "active-prefs.json",
    "active-prefs.md",
)

# Per-agent memory subtree.
MEMORY_SUBDIR = "memory"

# Per-agent per-user subtree.
USERS_SUBDIR = "users"

# Non-portable patterns — NEVER include in bundle.
NON_PORTABLE_NAMES = frozenset({
    "session_id",
    "state.json",
    "pid",
    "pid.lock",
    "daemon.pid",
    "heartbeat",
})

NON_PORTABLE_EXTENSIONS = frozenset({
    ".lock",
    ".pid",
    ".sock",
    ".tmp",
})

NON_PORTABLE_SUBDIRS = frozenset({
    "logs",
    "log",
    "state",
    "shared",
    "runtime",
    "worktrees",
    "tmp",
    "temp",
    "backup",
    "backups",
    ".git",
    "__pycache__",
})

# Secret file patterns — export MUST NOT include; apply prompts for re-entry.
SECRET_FILE_NAMES = frozenset({
    "handoff.local.json",    # A2A HMAC peer keys
    ".env",                  # any channel .env with tokens
    "channel.env",
    "bot-token",
    "client-secret",
})

SECRET_EXTENSIONS = frozenset({
    ".pem",
    ".key",
})

# Roster keys that carry runtime state (non-portable, drop from export).
ROSTER_RUNTIME_KEYS = frozenset({
    "BRIDGE_AGENT_SESSION",     # live tmux session name
    "BRIDGE_AGENT_LOOP",
    "BRIDGE_AGENT_CONTINUE",
})

# Roster keys that may contain secrets (never export verbatim).
ROSTER_SECRET_KEYS = frozenset({
    "BRIDGE_AGENT_LAUNCH_CMD",  # may embed tokens via env injection
})

# Target MUST be fresh/clean if these dirs/files are absent or empty
# (issue #1087: codex r1 BLOCKING #1 — beta6 list checked only
# state/agents / state/tasks.db / data/agents, but apply also writes
# to target/agents/<a>, agent-roster.sh, agent-roster.local.sh,
# cron/jobs.json, state/cron, handoff.local.json, .env. A target whose
# state/* was empty could still hold a legacy-shape agents/admin tree
# that apply would silently overwrite.)
#
# This is the inclusive-list option from the brief (option (a)): every
# path apply may write to is added here. _target_is_clean treats a
# non-empty file or non-empty directory at any listed path as a hard
# refusal blocker, and _backup_target_contents captures the real file
# bytes (not just hashes) for atomic-apply rollback.
CLEAN_TARGET_REQUIRED_ABSENT = (
    # v2 (canonical) state.
    "state/agents",
    "state/tasks.db",
    "state/cron",
    "state/layout-marker.sh",
    # v2 agent root.
    "data/agents",
    # Legacy-shape agent root — apply may still write here when the
    # resolver classifies the target as legacy.
    "agents",
    # Roster files — apply rewrites identity metadata into these.
    "agent-roster.sh",
    "agent-roster.local.sh",
    # Cron home — apply writes jobs.json here.
    "cron/jobs.json",
    # Secret files apply may author when --a2a-secret-file /
    # --app-password-file is supplied.
    "handoff.local.json",
    ".env",
    # Migrator's own apply-result + backup tree — a populated
    # backup tree means a previous apply ran; refuse to clobber it.
    ".migrator-apply-result.json",
    ".migrator-pre-apply-backup",
    # r2 (codex #5723 SHOULD-FIX): scratch staging tree — apply
    # silently rmtrees this BEFORE writing, so a populated tree is a
    # prior-failed apply we must NOT clobber without operator review.
    # Production code paths only land here via the apply staged-publish
    # pattern; finding it pre-apply means the previous apply crashed
    # before rollback completed.
    ".migrator-apply-staging",
)

# Verification checks.
VERIFY_CHECKS = (
    "layout-marker",
    "roster-load",
    "agent-homes",
    "memory-dirs",
    "cron-definitions",
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _die(msg: str, code: int = 1) -> None:
    print(f"[migrator][error] {msg}", file=sys.stderr)
    sys.exit(code)


def _info(msg: str) -> None:
    print(f"[migrator] {msg}")


def _warn(msg: str) -> None:
    print(f"[migrator][warn] {msg}", file=sys.stderr)


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def _is_secret_file(name: str) -> bool:
    lower = name.lower()
    if lower in SECRET_FILE_NAMES:
        return True
    _, ext = os.path.splitext(lower)
    return ext in SECRET_EXTENSIONS


def _is_non_portable(name: str) -> bool:
    lower = name.lower()
    if lower in NON_PORTABLE_NAMES:
        return True
    _, ext = os.path.splitext(lower)
    return ext in NON_PORTABLE_EXTENSIONS


def _classify_item(rel_path: str) -> str:
    """Return 'portable', 'secret', or 'non-portable'."""
    parts = Path(rel_path).parts
    name = parts[-1] if parts else ""
    # Top-level non-portable dirs.
    if parts and parts[0] in NON_PORTABLE_SUBDIRS:
        return "non-portable"
    if _is_secret_file(name):
        return "secret"
    if _is_non_portable(name):
        return "non-portable"
    return "portable"


def _run_cmd(args: List[str], cwd: Optional[str] = None) -> Tuple[int, str, str]:
    """Run a subprocess without heredoc/pipe. Returns (rc, stdout, stderr)."""
    result = subprocess.run(
        args,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.returncode, result.stdout, result.stderr


# ---------------------------------------------------------------------------
# Source inspector: read a legacy BRIDGE_HOME
# ---------------------------------------------------------------------------

class LegacyInstall:
    """Read-only view of a legacy BRIDGE_HOME."""

    def __init__(self, bridge_home: Path) -> None:
        self.root = bridge_home
        self.state_dir = bridge_home / "state"
        self.agents_home_root = bridge_home / "agents"  # old per-agent homes
        self.cron_home = bridge_home / "cron"
        self.cron_native_jobs = bridge_home / "cron" / "jobs.json"
        self.roster_file = bridge_home / "agent-roster.sh"
        self.roster_local_file = bridge_home / "agent-roster.local.sh"
        self.host_profile = bridge_home / "state" / "host-profile.json"

        # v2 layout (data/agents/<agent>/home)
        self.data_root = bridge_home / "data"
        self.agent_root_v2 = bridge_home / "data" / "agents"

        # layout marker
        self.layout_marker = bridge_home / "state" / "layout-marker.sh"

    def is_v2_layout(self) -> bool:
        if not self.layout_marker.exists():
            return False
        try:
            text = self.layout_marker.read_text()
            return "BRIDGE_LAYOUT=v2" in text
        except OSError:
            return False

    def agent_home_path(self, agent_id: str) -> Path:
        """Resolve per-agent home: v2 data/agents/<agent>/home, else agents/<agent>."""
        if self.is_v2_layout():
            return self.agent_root_v2 / agent_id / "home"
        return self.agents_home_root / agent_id

    def list_agent_ids(self) -> List[str]:
        """Return agent IDs inferred from on-disk homes."""
        ids: List[str] = []
        for root in (self.agents_home_root, self.agent_root_v2):
            if not root.is_dir():
                continue
            for entry in sorted(root.iterdir()):
                if entry.is_dir() and not entry.name.startswith("."):
                    ids.append(entry.name)
        # Deduplicate, preserve order.
        seen: set = set()
        result: List[str] = []
        for a in ids:
            if a not in seen:
                seen.add(a)
                result.append(a)
        return result

    def read_cron_jobs(self) -> List[Dict[str, Any]]:
        """Read the native cron jobs file; return empty list on missing/invalid."""
        candidates = [
            self.cron_native_jobs,
            self.root / "state" / "cron" / "jobs.json",
        ]
        for path in candidates:
            if path.is_file():
                try:
                    data = json.loads(path.read_text())
                    if isinstance(data, list):
                        return data
                    if isinstance(data, dict) and "jobs" in data:
                        return data["jobs"]
                except (json.JSONDecodeError, OSError):
                    _warn(f"cron jobs file unreadable or invalid JSON: {path}")
        return []

    def read_host_profile(self) -> Optional[Dict[str, Any]]:
        if not self.host_profile.is_file():
            return None
        try:
            return json.loads(self.host_profile.read_text())
        except (json.JSONDecodeError, OSError):
            return None


# ---------------------------------------------------------------------------
# Bundle writer
# ---------------------------------------------------------------------------

def _collect_agent_identity(
    agent_id: str,
    home_path: Path,
) -> Dict[str, Any]:
    """
    Collect portable identity for one agent. Returns a dict with:
      - files: list of {rel_path, sha256, size_bytes}
      - memory_dir_exists: bool
      - users_dir_exists: bool
    Excludes secrets and non-portable items.
    """
    files: List[Dict[str, Any]] = []

    if not home_path.is_dir():
        return {"files": files, "memory_dir_exists": False, "users_dir_exists": False}

    # Top-level identity files.
    for fname in IDENTITY_FILES:
        fpath = home_path / fname
        if fpath.is_file():
            files.append({
                "rel_path": fname,
                "sha256": _sha256_file(fpath),
                "size_bytes": fpath.stat().st_size,
                "classification": "portable",
            })

    # Memory subtree.
    mem_path = home_path / MEMORY_SUBDIR
    mem_exists = mem_path.is_dir()
    if mem_exists:
        for mem_file in sorted(mem_path.rglob("*")):
            if not mem_file.is_file():
                continue
            rel = mem_file.relative_to(home_path)
            rel_str = str(rel)
            cls = _classify_item(rel_str)
            if cls == "non-portable":
                continue
            if cls == "secret":
                _warn(f"  skipping secret file in memory: {rel_str}")
                continue
            files.append({
                "rel_path": rel_str,
                "sha256": _sha256_file(mem_file),
                "size_bytes": mem_file.stat().st_size,
                "classification": cls,
            })

    # Per-user subtree.
    users_path = home_path / USERS_SUBDIR
    users_exists = users_path.is_dir()
    if users_exists:
        for u_file in sorted(users_path.rglob("*")):
            if not u_file.is_file():
                continue
            rel = u_file.relative_to(home_path)
            rel_str = str(rel)
            cls = _classify_item(rel_str)
            if cls in ("non-portable", "secret"):
                continue
            files.append({
                "rel_path": rel_str,
                "sha256": _sha256_file(u_file),
                "size_bytes": u_file.stat().st_size,
                "classification": cls,
            })

    return {
        "files": files,
        "memory_dir_exists": mem_exists,
        "users_dir_exists": users_exists,
    }


# Cron payload.env allowlist (issue #1087: codex r1 BLOCKING #3 — replaces
# the beta6 keyword heuristic `TOKEN/SECRET/PASSWORD/KEY/PASS` which
# silently passed org-specific names like AUTHORIZATION, COOKIE, PAT).
#
# Anything NOT in this allowlist is dropped. The allowlist is intentionally
# tiny — anything that smells like a credential or a host-private path is
# off the list, and a cron job that needs custom env must have it
# re-entered by the operator post-apply.
CRON_ENV_ALLOWLIST = frozenset({
    # Locale and shell PATH — needed for the cron job to find binaries
    # and render UTF-8 correctly. These never carry credentials.
    "PATH",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TZ",
    # Bridge runtime — the daemon already sets these per-process; the
    # cron payload carries them as a hint and they are safe to import
    # because the target install resets them at run time.
    "BRIDGE_HOME",
    "BRIDGE_AGENT_ID",
})


def _scrub_cron_env(
    env_block: Dict[str, Any],
    job_label: str,
) -> Dict[str, Any]:
    """
    Apply CRON_ENV_ALLOWLIST to a cron payload's env map. Returns the
    allowlisted subset; everything else is dropped with a warning so the
    operator knows custom keys did not survive the migration.
    """
    if not isinstance(env_block, dict):
        return {}
    kept: Dict[str, Any] = {}
    for k, v in env_block.items():
        if k in CRON_ENV_ALLOWLIST:
            kept[k] = v
        else:
            _warn(
                f"  cron job '{job_label}': env key '{k}' not in allowlist — dropped from bundle "
                "(re-enter via cron edit after apply if intentional)"
            )
    return kept


def _sanitize_cron_job(job: Dict[str, Any]) -> Dict[str, Any]:
    """
    Keep portable cron definition fields; strip runtime state.
    Schedule, target, title, payload_kind, enabled, timezone, followup_policy.
    Active run leases, run ids, last_run_* fields are non-portable.

    payload.env is filtered through CRON_ENV_ALLOWLIST (not a keyword
    heuristic) so org-specific credential keys cannot leak.
    """
    keep = (
        "id", "name", "title", "target", "schedule", "timezone",
        "payload_kind", "payload", "enabled",
        "followup_policy", "model", "effort", "description",
        "tags", "created_at",
    )
    sanitized: Dict[str, Any] = {}
    for key in keep:
        if key in job:
            sanitized[key] = job[key]
    # payload.env allowlist — drop everything not explicitly safe.
    if "payload" in sanitized and isinstance(sanitized["payload"], dict):
        env_block = sanitized["payload"].get("env", {})
        if isinstance(env_block, dict):
            sanitized["payload"]["env"] = _scrub_cron_env(
                env_block,
                sanitized.get("name") or sanitized.get("id") or "?",
            )
    return sanitized


def _read_roster_agents(roster_path: Path) -> List[Dict[str, Any]]:
    """
    Parse roster shell file to extract agent metadata.
    Only reads BRIDGE_AGENT_DESC, ENGINE, MODEL, EFFORT, PERMISSION_MODE,
    PROFILE_HOME, WEBHOOK_PORT, IDLE_TIMEOUT, NOTIFY_KIND, NOTIFY_TARGET,
    NOTIFY_ACCOUNT maps. Skips runtime keys and secret keys.
    Returns list of dicts with agent_id and metadata.
    """
    if not roster_path.is_file():
        return []

    agents: Dict[str, Dict[str, str]] = {}

    # Simple grep-style extraction: look for map assignments.
    # Pattern: BRIDGE_AGENT_DESC["agentid"]="..."
    map_pattern = re.compile(
        r'BRIDGE_AGENT_([A-Z_]+)\["([^"]+)"\]\s*=\s*"([^"]*)"'
    )

    text = roster_path.read_text(errors="replace")
    for m in map_pattern.finditer(text):
        key_suffix, agent_id, value = m.group(1), m.group(2), m.group(3)
        full_key = f"BRIDGE_AGENT_{key_suffix}"
        if full_key in ROSTER_SECRET_KEYS:
            continue  # never export launch cmd (may embed tokens)
        if full_key in ROSTER_RUNTIME_KEYS:
            continue  # runtime state, not portable
        agents.setdefault(agent_id, {})
        agents[agent_id][key_suffix] = value

    # Also extract BRIDGE_AGENT_IDS array.
    ids_pattern = re.compile(r'BRIDGE_AGENT_IDS\s*=\s*\(([^)]*)\)')
    ids_match = ids_pattern.search(text)
    declared_ids: List[str] = []
    if ids_match:
        raw = ids_match.group(1)
        declared_ids = re.findall(r'"([^"]+)"', raw)

    result: List[Dict[str, Any]] = []
    seen: set = set()
    for aid in declared_ids + sorted(agents.keys()):
        if aid in seen:
            continue
        seen.add(aid)
        result.append({
            "agent_id": aid,
            "metadata": agents.get(aid, {}),
        })
    return result


# ---------------------------------------------------------------------------
# export subcommand
# ---------------------------------------------------------------------------

def cmd_export(args: argparse.Namespace) -> int:
    source = Path(args.source).expanduser().resolve()
    bundle_dir = Path(args.bundle).expanduser().resolve()

    if not source.is_dir():
        _die(f"source BRIDGE_HOME does not exist: {source}")

    _info(f"source: {source}")
    _info(f"bundle: {bundle_dir}")

    install = LegacyInstall(source)
    layout = "v2" if install.is_v2_layout() else "legacy"
    _info(f"detected layout: {layout}")

    agent_ids = install.list_agent_ids()
    _info(f"agents found: {', '.join(agent_ids) if agent_ids else '(none)'}")

    bundle_dir.mkdir(parents=True, exist_ok=True)
    agents_bundle = bundle_dir / "agents"
    agents_bundle.mkdir(exist_ok=True)

    manifest: Dict[str, Any] = {
        "schema_version": MIGRATOR_SCHEMA_VERSION,
        "migrator_tag": args.migrator_tag,
        "exported_at": _now_iso(),
        "source_bridge_home": str(source),
        "source_layout": layout,
        "agents": [],
        "cron_jobs": [],
        "host_profile": None,
        "secrets_stripped": [],
    }

    # Export per-agent identity.
    for agent_id in agent_ids:
        home_path = install.agent_home_path(agent_id)
        identity = _collect_agent_identity(agent_id, home_path)
        agent_bundle_dir = agents_bundle / agent_id
        agent_bundle_dir.mkdir(exist_ok=True)

        # Copy portable files into bundle.
        for finfo in identity["files"]:
            src = home_path / finfo["rel_path"]
            dst = agent_bundle_dir / finfo["rel_path"]
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(src), str(dst))

        # Read roster metadata.
        roster_meta: List[Dict[str, Any]] = []
        for roster_path in (install.roster_file, install.roster_local_file):
            for entry in _read_roster_agents(roster_path):
                if entry["agent_id"] == agent_id:
                    roster_meta = [entry]
                    break

        manifest["agents"].append({
            "agent_id": agent_id,
            "source_home": str(home_path),
            "file_count": len(identity["files"]),
            "files": identity["files"],
            "memory_dir_exists": identity["memory_dir_exists"],
            "users_dir_exists": identity["users_dir_exists"],
            "roster_metadata": roster_meta[0]["metadata"] if roster_meta else {},
        })
        _info(f"  agent {agent_id}: {len(identity['files'])} identity files exported")

    # Export cron definitions (portable, secrets stripped).
    raw_jobs = install.read_cron_jobs()
    portable_jobs: List[Dict[str, Any]] = []
    for job in raw_jobs:
        portable_jobs.append(_sanitize_cron_job(job))
    manifest["cron_jobs"] = portable_jobs
    _info(f"cron definitions: {len(portable_jobs)} exported")

    # Export host-profile snapshot (portable capability facts only).
    hp = install.read_host_profile()
    if hp is not None:
        # Strip any secret-looking keys.
        for k in list(hp.keys()):
            if any(kw in k.upper() for kw in ("TOKEN", "SECRET", "PASSWORD", "KEY")):
                del hp[k]
                manifest["secrets_stripped"].append(f"host_profile.{k}")
        manifest["host_profile"] = hp

    # Note secrets that were NOT exported.
    secret_notes: List[str] = []
    for sname in SECRET_FILE_NAMES:
        for candidate in (
            source / sname,
            source / "runtime" / sname,
        ):
            if candidate.exists():
                secret_notes.append(str(candidate.relative_to(source)))
                manifest["secrets_stripped"].append(f"source:{candidate.relative_to(source)}")
    if secret_notes:
        _warn("secrets present in source — NOT included in bundle (re-enter at apply):")
        for s in secret_notes:
            _warn(f"  {s}")

    # Write manifest.
    manifest_path = bundle_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    _info(f"manifest written: {manifest_path}")
    _info("export complete")
    return 0


# ---------------------------------------------------------------------------
# plan subcommand
# ---------------------------------------------------------------------------

def cmd_plan(args: argparse.Namespace) -> int:
    bundle_dir = Path(args.bundle).expanduser().resolve()
    target = Path(args.target).expanduser().resolve()

    if not bundle_dir.is_dir():
        _die(f"bundle directory does not exist: {bundle_dir}")
    manifest_path = bundle_dir / "manifest.json"
    if not manifest_path.is_file():
        _die(f"manifest not found in bundle: {manifest_path}")

    manifest = json.loads(manifest_path.read_text())
    _info(f"bundle: {bundle_dir}")
    _info(f"target: {target}")
    _info(f"schema_version: {manifest.get('schema_version')}")
    _info(f"exported_at: {manifest.get('exported_at')}")
    _info(f"source_layout: {manifest.get('source_layout')}")

    # Detect target layout.
    target_marker = target / "state" / "layout-marker.sh"
    if target_marker.is_file():
        _info(f"target layout marker: {target_marker}")
    else:
        _info("target: no layout marker found (fresh install expected)")

    print()
    print("=== APPLY PLAN ===")

    for agent_entry in manifest.get("agents", []):
        aid = agent_entry["agent_id"]
        n = agent_entry["file_count"]
        mem = agent_entry.get("memory_dir_exists", False)
        users = agent_entry.get("users_dir_exists", False)
        print(f"\nagent: {aid}")
        print(f"  identity files: {n}")
        if mem:
            print("  memory dir: yes (will import)")
        if users:
            print("  users dir: yes (will import)")
        meta = agent_entry.get("roster_metadata", {})
        if meta:
            for k, v in sorted(meta.items()):
                print(f"  roster.{k}: {v}")

    crons = manifest.get("cron_jobs", [])
    print(f"\ncron definitions: {len(crons)}")
    for job in crons:
        name = job.get("name") or job.get("id") or "?"
        target_agent = job.get("target", "?")
        enabled = job.get("enabled", True)
        print(f"  cron: {name} → {target_agent} (enabled={enabled})")

    stripped = manifest.get("secrets_stripped", [])
    if stripped:
        print(f"\nsecrets NOT exported (will need re-entry at apply): {len(stripped)}")
        for s in stripped:
            print(f"  {s}")

    print()
    print("NON-PORTABLE items (excluded from apply):")
    print("  tmux sessions, pid files, queue leases, daemon state,")
    print("  generated hooks/settings, plugin caches, logs, worktrees, backups")

    print()
    print("=== TARGET CLEANLINESS CHECK ===")
    is_clean, blockers = _target_is_clean(target)
    if not is_clean:
        for rel in blockers:
            print(f"  WARN: target already has: {rel} — apply will REFUSE")
    else:
        print("  target appears clean/fresh — apply may proceed")

    return 0


# ---------------------------------------------------------------------------
# apply subcommand
# ---------------------------------------------------------------------------

def _find_bash() -> str:
    """
    Locate a Bash 4+ binary suitable for invoking the layout shim.
    bridge-lib.sh's re-exec into Homebrew bash 5.x trips when called via
    /bin/bash on macOS (Bash 3.2), so we prefer the same candidate list
    bridge-lib.sh checks itself before falling back to PATH.
    """
    for candidate in (
        "/opt/homebrew/bin/bash",
        "/usr/local/bin/bash",
        shutil.which("bash"),
    ):
        if not candidate:
            continue
        if not Path(candidate).is_file():
            continue
        try:
            rc, out, _err = _run_cmd([candidate, "-c", "echo $BASH_VERSION"])
        except OSError:
            continue
        if rc != 0:
            continue
        version = (out or "").strip()
        # Accept Bash 4+ (the layout shim requires associative arrays).
        if not version:
            continue
        try:
            major = int(version.split(".", 1)[0])
        except ValueError:
            continue
        if major >= 4:
            return candidate
    _die(
        "no Bash 4+ binary available — install Homebrew Bash and ensure "
        "/opt/homebrew/bin/bash or /usr/local/bin/bash exists, or put a "
        "Bash 4+ shell ahead of /bin in PATH."
    )
    return ""  # unreachable; keeps mypy/pyright happy.


def _run_layout_shim(
    repo_root: Path,
    target: Path,
    agent_ids: List[str],
) -> Dict[str, Any]:
    """
    Invoke `scripts/python-helpers/migrate-layout-shim.sh` to get the
    canonical per-agent layout paths for a target install. Returns a
    dict with:
      - layout: "v2" | "legacy"
      - data_root, agent_root_v2, agent_home_root
      - agents: { <agent_id>: { home_dir, workspace_dir, memory_dir } }
    Aborts the process on shim failure — apply/verify cannot proceed
    without canonical paths (issue #1087 BLOCKING #2: refuse to fall
    back to local path math, which is what the resolver bypass was).
    """
    shim_path = repo_root / "scripts" / "python-helpers" / "migrate-layout-shim.sh"
    if not shim_path.is_file():
        _die(f"layout shim missing: {shim_path}")
    bash_bin = _find_bash()
    cmd = [bash_bin, str(shim_path), str(target)] + list(agent_ids)
    rc, stdout, stderr = _run_cmd(cmd)
    if rc != 0:
        _die(
            "layout shim failed — refusing to fall back to in-process path "
            f"math (issue #1087 layout-resolver-bypass contract).\n"
            f"  cmd: {' '.join(cmd)}\n"
            f"  stderr: {(stderr or '').strip()}"
        )

    top: Dict[str, Any] = {}
    agents: Dict[str, Dict[str, str]] = {}
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        fields = line.split("\t")
        rec: Dict[str, str] = {}
        for field in fields:
            if "=" in field:
                k, _, v = field.partition("=")
                rec[k] = v
        rec_type = rec.get("type")
        if rec_type == "top":
            top = {
                "layout": rec.get("layout", ""),
                "target": rec.get("target", ""),
                "data_root": rec.get("data_root", ""),
                "agent_root_v2": rec.get("agent_root_v2", ""),
                "agent_home_root": rec.get("agent_home_root", ""),
            }
        elif rec_type == "agent":
            aid = rec.get("id")
            if aid:
                agents[aid] = {
                    "home_dir": rec.get("home_dir", ""),
                    "workspace_dir": rec.get("workspace_dir", ""),
                    "memory_dir": rec.get("memory_dir", ""),
                }

    if not top:
        _die(f"layout shim returned no top record:\nstdout: {stdout}\nstderr: {stderr}")

    top["agents"] = agents
    return top


def _target_is_clean(target: Path) -> Tuple[bool, List[str]]:
    """Return (is_clean, list_of_blocking_paths)."""
    blockers: List[str] = []
    for rel in CLEAN_TARGET_REQUIRED_ABSENT:
        p = target / rel
        if not p.exists():
            continue
        if p.is_file():
            blockers.append(str(rel))
            continue
        if p.is_dir():
            # Non-empty directory is a blocker.
            try:
                if any(True for _ in p.iterdir()):
                    blockers.append(str(rel))
            except PermissionError:
                blockers.append(str(rel) + " (permission denied)")
    return (len(blockers) == 0, blockers)


def _backup_target_contents(target: Path, backup_dir: Path) -> Dict[str, Any]:
    """
    Capture the actual file contents of the target before apply (issue
    #1087 BLOCKING #1 — beta6 only wrote a hash manifest, which cannot
    be replayed on rollback). Returns a manifest dict that
    _restore_target_from_backup consumes; the file bodies live under
    `backup_dir/files/<relpath>`.
    """
    backup_files_root = backup_dir / "files"
    backup_files_root.mkdir(parents=True, exist_ok=True)

    entries: List[Dict[str, str]] = []
    if target.is_dir():
        for p in sorted(target.rglob("*")):
            if not p.is_file():
                continue
            rel = p.relative_to(target)
            # Skip the backup tree itself — recursion would balloon.
            if rel.parts and rel.parts[0] == ".migrator-pre-apply-backup":
                continue
            sha = _sha256_file(p)
            dst = backup_files_root / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(p), str(dst))
            entries.append({
                "rel_path": str(rel),
                "sha256": sha,
                "size_bytes": str(p.stat().st_size),
            })

    manifest = {
        "backup_at": _now_iso(),
        "target": str(target),
        "file_count": len(entries),
        "files": entries,
        "files_root": str(backup_files_root),
    }
    mpath = backup_dir / "pre-apply-backup-manifest.json"
    mpath.write_text(json.dumps(manifest, indent=2))
    return manifest


def _restore_target_from_backup(target: Path, backup_dir: Path) -> int:
    """
    On apply failure, restore the target's pre-mutation file contents
    from the backup tree (issue #1087 SHOULD-FIX — atomic apply with
    rollback). New files written by apply that did not exist before
    are removed; pre-existing files are restored byte-for-byte.
    Returns the number of files restored.
    """
    manifest_path = backup_dir / "pre-apply-backup-manifest.json"
    if not manifest_path.is_file():
        _warn(f"no backup manifest at {manifest_path} — cannot rollback")
        return 0
    try:
        manifest = json.loads(manifest_path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        _warn(f"backup manifest unreadable: {e}")
        return 0

    files_root = Path(manifest.get("files_root", str(backup_dir / "files")))
    pre_apply_relpaths = {entry["rel_path"] for entry in manifest.get("files", [])}

    # Step 1: remove any file in target that was NOT present pre-apply.
    if target.is_dir():
        for p in list(target.rglob("*")):
            if not p.is_file():
                continue
            rel = str(p.relative_to(target))
            if rel.startswith(".migrator-pre-apply-backup"):
                continue
            if rel not in pre_apply_relpaths:
                try:
                    p.unlink()
                except OSError as e:
                    _warn(f"  rollback: could not unlink {rel}: {e}")

    # Step 2: restore pre-apply file contents.
    restored = 0
    for entry in manifest.get("files", []):
        rel = entry["rel_path"]
        src = files_root / rel
        dst = target / rel
        if not src.is_file():
            _warn(f"  rollback: backup file missing for {rel} — skipping")
            continue
        try:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(src), str(dst))
            restored += 1
        except OSError as e:
            _warn(f"  rollback: could not restore {rel}: {e}")

    return restored


def _read_secret_file(path: str) -> str:
    """Read a secret from a file; strip trailing newlines."""
    p = Path(path).expanduser()
    if not p.is_file():
        _die(f"secret file not found: {p}")
    return p.read_text().strip()


def _prompt_secret(prompt: str) -> str:
    """Prompt operator for a secret on stdin; hide echo."""
    try:
        return getpass.getpass(prompt)
    except EOFError:
        return ""


def _atomic_write_file(
    path: Path,
    content: bytes,
    mode: int = 0o600,
) -> None:
    """
    Write `content` to `path` atomically: write to a temp file in the
    same directory, fchmod to `mode`, then os.replace into place.
    Used for credential files (issue #1087 BLOCKING #3) and for files
    that must survive a partial-apply abort.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path_str = tempfile.mkstemp(
        prefix="." + path.name + ".",
        suffix=".tmp",
        dir=str(path.parent),
    )
    try:
        os.write(fd, content)
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.chmod(tmp_path_str, mode)
        os.replace(tmp_path_str, str(path))
    except Exception:
        try:
            os.unlink(tmp_path_str)
        except OSError:
            pass
        raise


def _staging_root(target: Path) -> Path:
    """Return the temp staging tree path used for atomic apply."""
    return target / ".migrator-apply-staging"


def _move_staging_into_target(staging_root: Path, target: Path) -> List[str]:
    """
    Move every file from the staging tree into its final location under
    target. Returns the list of relative paths actually moved. Caller is
    responsible for `staging_root.exists()` and for removing the staging
    root afterward.
    """
    moved: List[str] = []
    for src in sorted(staging_root.rglob("*")):
        if not src.is_file():
            continue
        rel = src.relative_to(staging_root)
        dst = target / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.replace(str(src), str(dst))
        moved.append(str(rel))
    return moved


def _write_a2a_handoff_local(staging_root: Path, secret: str) -> Path:
    """
    Author a minimal handoff.local.json with the operator-supplied A2A
    HMAC peer key. Schema mirrors what `agb a2a init` writes (bridge_id +
    peers[]); apply seeds an empty peers list because cross-bridge peer
    pairing requires both bridges' bridge-ids, which the migrator does
    not own.
    """
    path = staging_root / "handoff.local.json"
    payload = {
        "bridge_id": "",
        "peers": [],
        "hmac_secret": secret,
        "migrator_seeded": True,
    }
    body = json.dumps(payload, indent=2).encode("utf-8")
    _atomic_write_file(path, body, mode=0o600)
    return path


def _write_teams_env(staging_root: Path, password: str) -> Path:
    """
    Author a minimal .env carrying the operator-supplied Teams app
    password. The target install's bridge-setup teams path will overwrite
    everything else (client id, tenant id, channel mapping); the
    password is the one credential the operator must re-enter.
    """
    path = staging_root / ".env"
    body = f"TEAMS_APP_PASSWORD={password}\n".encode("utf-8")
    _atomic_write_file(path, body, mode=0o600)
    return path


def cmd_apply(args: argparse.Namespace) -> int:
    # Issue #1087: apply ships as the user-facing default. The beta6
    # opt-in env-var gate is gone — apply now closes the three codex r1
    # contract gaps:
    #
    #   1. clean-target gate covers every apply write path (not just
    #      state/agents / state/tasks.db / data/agents). See
    #      CLEAN_TARGET_REQUIRED_ABSENT.
    #   2. canonical per-agent paths come from the layout shim
    #      (scripts/python-helpers/migrate-layout-shim.sh) which sources
    #      the live resolver — no hardcoded `data/agents/<a>/home` path
    #      inference. Apply and verify consume the same shim, closing the
    #      verify ↔ layout seam from PR #1111.
    #   3. operator-supplied secrets (--a2a-secret-file, --app-password-
    #      file, or the equivalent env vars) ARE written to the target
    #      as `handoff.local.json` / `.env` with mode 0600. Source-side
    #      secrets remain stripped at export — the "never copy from
    #      source" contract is preserved.
    #
    # Apply is also wrapped in a write-to-staging + atomic rename + rollback
    # pattern: every file authored during apply lands in
    # `.migrator-apply-staging/` first, and only the final move step
    # publishes the changes into the canonical layout. If anything
    # fails mid-flight, the rollback path restores file contents from
    # the pre-apply backup tree (Gap 1 + SHOULD-FIX from the brief).

    bundle_dir = Path(args.bundle).expanduser().resolve()
    target = Path(args.target).expanduser().resolve()
    repo_root = Path(args.repo_root).expanduser().resolve()

    if not bundle_dir.is_dir():
        _die(f"bundle directory does not exist: {bundle_dir}")
    manifest_path = bundle_dir / "manifest.json"
    if not manifest_path.is_file():
        _die(f"manifest not found in bundle: {manifest_path}")

    manifest = json.loads(manifest_path.read_text())

    _info(f"bundle: {bundle_dir}")
    _info(f"target: {target}")

    # --- Gate 1: target must be clean/fresh ---
    target.mkdir(parents=True, exist_ok=True)
    is_clean, blockers = _target_is_clean(target)
    if not is_clean:
        _die(
            "target is not clean/fresh — apply refused.\n"
            "  blocking paths: " + ", ".join(blockers) + "\n"
            "  Use 'plan' to inspect, or point apply at a clean fresh-install target."
        )
    _info("target cleanliness: PASS")

    # --- Gate 2: mandatory content backup + manifest ---
    # Beta6 wrote a hash manifest only, which cannot be replayed on
    # rollback. We now copy the actual file bytes into the backup tree
    # so _restore_target_from_backup can byte-for-byte restore.
    backup_dir = target / ".migrator-pre-apply-backup"
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup_manifest = _backup_target_contents(target, backup_dir)
    _info(
        f"pre-apply backup: {backup_manifest['file_count']} files → {backup_dir}/files/ "
        f"(manifest: pre-apply-backup-manifest.json)"
    )

    # --- Gate 3: operator-supplied secrets (never copied from source) ---
    a2a_secret: Optional[str] = None
    teams_secret: Optional[str] = None

    if args.a2a_secret_file:
        a2a_secret = _read_secret_file(args.a2a_secret_file)
        _info("A2A HMAC secret: loaded from file")
    elif os.environ.get("BRIDGE_A2A_SHARED_SECRET"):
        a2a_secret = os.environ["BRIDGE_A2A_SHARED_SECRET"].strip()
        _info("A2A HMAC secret: loaded from BRIDGE_A2A_SHARED_SECRET env")

    if args.app_password_file:
        teams_secret = _read_secret_file(args.app_password_file)
        _info("Teams app password: loaded from file")
    elif os.environ.get("BRIDGE_TEAMS_APP_PASSWORD"):
        teams_secret = os.environ["BRIDGE_TEAMS_APP_PASSWORD"].strip()
        _info("Teams app password: loaded from BRIDGE_TEAMS_APP_PASSWORD env")
    else:
        # The user-prompt re-entry path is only useful when the source
        # actually had Teams secrets configured AND we are running on a
        # TTY. Otherwise stay silent — apply will simply skip secret
        # writes, the operator runs `bridge-setup teams` post-apply.
        stripped = manifest.get("secrets_stripped", [])
        teams_present = any("client-secret" in s or "teams" in s.lower() for s in stripped)
        if teams_present and sys.stdin.isatty():
            _warn("Teams client secret detected in source — not copied.")
            teams_secret_input = _prompt_secret(
                "[migrator] Enter Teams app password (or press Enter to skip): "
            )
            if teams_secret_input:
                teams_secret = teams_secret_input
                _info("Teams app password: entered interactively")

    # --- Resolve canonical per-agent paths via the layout shim ---
    agent_ids = [entry["agent_id"] for entry in manifest.get("agents", [])]
    layout_info = _run_layout_shim(repo_root, target, agent_ids)
    _info(f"resolved layout: {layout_info.get('layout')}")

    # --- Apply, staged: every write lands under target/.migrator-apply-staging ---
    staging_root = _staging_root(target)
    if staging_root.exists():
        shutil.rmtree(str(staging_root))
    staging_root.mkdir(parents=True, exist_ok=True)

    agents_bundle = bundle_dir / "agents"
    applied_agents: List[str] = []
    move_failure: Optional[BaseException] = None

    try:
        # --- Stage: agent identity ---
        for agent_entry in manifest.get("agents", []):
            aid = agent_entry["agent_id"]
            agent_bundle_dir = agents_bundle / aid
            if not agent_bundle_dir.is_dir():
                _warn(f"  agent {aid}: bundle dir missing — skipping")
                continue

            # Canonical path from the resolver — never local math.
            paths = layout_info.get("agents", {}).get(aid)
            if not paths:
                _die(
                    f"layout shim returned no record for agent '{aid}'. "
                    "This is a contract violation — refusing to apply."
                )
            agent_home_target = Path(paths["home_dir"])
            try:
                rel_home = agent_home_target.relative_to(target)
            except ValueError:
                _die(
                    f"layout shim returned out-of-target home for '{aid}': {agent_home_target}"
                )
            staged_home = staging_root / rel_home
            staged_home.mkdir(parents=True, exist_ok=True)

            copied = 0
            for finfo in agent_entry.get("files", []):
                rel = finfo["rel_path"]
                cls = finfo.get("classification", "portable")
                if cls != "portable":
                    continue
                src = agent_bundle_dir / rel
                dst = staged_home / rel
                if not src.is_file():
                    continue
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(str(src), str(dst))
                copied += 1

            applied_agents.append(aid)
            _info(f"  agent {aid}: {copied} identity files → {agent_home_target} (staged)")

        # --- Stage: cron definitions ---
        cron_jobs = manifest.get("cron_jobs", [])
        if cron_jobs:
            staged_cron_home = staging_root / "cron"
            staged_cron_home.mkdir(parents=True, exist_ok=True)
            staged_jobs_path = staged_cron_home / "jobs.json"
            # Cleanliness gate already refused if the live jobs.json
            # existed, so there is no merge case to consider here.
            staged_jobs_path.write_text(json.dumps(cron_jobs, indent=2))
            _info(f"cron definitions: {len(cron_jobs)} staged → cron/jobs.json")
            # Reference copy in the backup dir (the live backup tree is
            # NOT inside staging; write it directly).
            ref_path = backup_dir / "cron-definitions-from-bundle.json"
            ref_path.write_text(json.dumps(cron_jobs, indent=2))

        # --- Stage: operator-supplied secrets, mode 0600 ---
        secret_files_written: List[str] = []
        if a2a_secret:
            handoff_path = _write_a2a_handoff_local(staging_root, a2a_secret)
            secret_files_written.append(str(handoff_path.relative_to(staging_root)))
            _info("A2A handoff.local.json: staged (mode 0600)")
        if teams_secret:
            env_path = _write_teams_env(staging_root, teams_secret)
            secret_files_written.append(str(env_path.relative_to(staging_root)))
            _info("Teams .env: staged (mode 0600)")

        # --- Stage: layout marker so the migrated target is startable ---
        # Codex r2 finding 1: without this, apply publishes the agent
        # tree but the resolver dies on next startup because the target
        # is markerless. The migrator IS the init flow for a legacy →
        # clean-cut handoff, so it must author the marker.
        staged_marker_dir = staging_root / "state"
        staged_marker_dir.mkdir(parents=True, exist_ok=True)
        marker_body = (
            "# Managed by agent-bridge. Regenerated by migrate-legacy-install.\n"
            "BRIDGE_LAYOUT=v2\n"
            f"BRIDGE_DATA_ROOT={target}/data\n"
        )
        (staged_marker_dir / "layout-marker.sh").write_text(marker_body)
        _info("layout marker: staged (BRIDGE_LAYOUT=v2)")

        # Test-only hook: simulate a mid-apply failure before publish so
        # smoke can exercise the rollback path. Never set this in
        # production — the migrator deliberately leaves no production
        # code path that triggers a forced failure.
        if os.environ.get("BRIDGE_MIGRATOR_TEST_FAIL_BEFORE_PUBLISH"):
            raise RuntimeError(
                "BRIDGE_MIGRATOR_TEST_FAIL_BEFORE_PUBLISH set — "
                "simulated mid-apply failure for rollback smoke"
            )

        # --- Atomic publish: move staging into the live tree ---
        moved = _move_staging_into_target(staging_root, target)
        _info(f"atomic publish: {len(moved)} files moved into target")

        # --- Re-assert secret-file modes post-publish ---
        # The mode survives os.replace because we set it on the source,
        # but defense-in-depth: confirm explicitly.
        for rel in secret_files_written:
            try:
                os.chmod(str(target / rel), 0o600)
            except OSError as e:
                _warn(f"  secret {rel}: chmod 0600 failed post-publish: {e}")

        # r2 (codex #5723 BLOCKING #3): apply-result manifest must be
        # written INSIDE the rollback-protected try, so a write failure
        # here triggers full rollback rather than leaving a half-migrated
        # target. The manifest is the final atomic "apply succeeded"
        # marker — if we can't write it, the apply is not actually
        # complete.
        apply_manifest = {
            "schema_version": MIGRATOR_SCHEMA_VERSION,
            "migrator_tag": args.migrator_tag,
            "applied_at": _now_iso(),
            "source_bundle": str(bundle_dir),
            "target": str(target),
            "applied_agents": applied_agents,
            "cron_jobs_imported": len(manifest.get("cron_jobs", [])),
            "a2a_secret_supplied": a2a_secret is not None,
            "a2a_secret_written": a2a_secret is not None,
            "teams_secret_supplied": teams_secret is not None,
            "teams_secret_written": teams_secret is not None,
            "layout": layout_info.get("layout"),
            "agent_paths": {
                aid: layout_info.get("agents", {}).get(aid, {})
                for aid in applied_agents
            },
        }
        apply_result_path = target / ".migrator-apply-result.json"
        # Use atomic-rename for the manifest write so even a partial
        # write doesn't leave a torn file.
        _atomic_write_file(
            apply_result_path,
            json.dumps(apply_manifest, indent=2).encode("utf-8"),
            mode=0o644,
        )
        _info(f"apply result: {apply_result_path}")

    except BaseException as exc:  # noqa: BLE001 (intentional: rollback any failure)
        move_failure = exc
        _warn(f"apply failure mid-flight: {exc}")
        _warn("rolling back from pre-apply backup …")
        restored = _restore_target_from_backup(target, backup_dir)
        _warn(f"rollback restored {restored} files from backup")
        if staging_root.exists():
            try:
                shutil.rmtree(str(staging_root))
            except OSError:
                pass
        # Codex r2 finding 2: the cleanliness gate treats
        # .migrator-pre-apply-backup/ as a blocker (see
        # CLEAN_TARGET_REQUIRED_ABSENT), so leaving it in place after a
        # rollback would brick the retry. Move it to a timestamped
        # `.migrator-failed-backup-<ts>/` instead so the operator still
        # has the audit trail and the cleanliness gate stops blocking.
        # The failed-backup name is intentionally NOT in
        # CLEAN_TARGET_REQUIRED_ABSENT — apply tolerates leftover
        # diagnostics from prior aborted runs.
        if backup_dir.exists():
            failed_name = f".migrator-failed-backup-{int(time.time())}"
            failed_dir = target / failed_name
            try:
                os.replace(str(backup_dir), str(failed_dir))
                _warn(f"pre-apply backup preserved as {failed_name}/ for inspection")
            except OSError as e:
                _warn(f"could not rename backup dir for retry: {e}")
        _die(f"apply failed and rolled back: {exc}")
    finally:
        # Whether success or failure, the staging tree should be gone.
        if staging_root.exists():
            try:
                shutil.rmtree(str(staging_root))
            except OSError:
                pass

    if move_failure is not None:
        # Defensive — _die above should have already exited.
        return 1

    _info("apply complete")
    print()
    print("NEXT STEPS after apply:")
    print("  1. Run 'verify --target <target>' to check the migrated install.")
    print("  2. If Teams or A2A secrets were skipped, enter them now via:")
    print("     bridge-setup.sh / agb setup, or edit channel .env files.")
    print("  3. Hooks/settings are NOT imported — regenerate via:")
    print("     agb hooks render  (or bridge-hooks.py render ...)")
    print("  4. Review applied_agents and cron definitions.")
    return 0


# ---------------------------------------------------------------------------
# verify subcommand
# ---------------------------------------------------------------------------

def cmd_verify(args: argparse.Namespace) -> int:
    # Issue #1087: verify consumes the same layout shim as apply, closing
    # the verify ↔ layout seam codex r1 flagged in PR #1111 (verify and
    # apply must agree on where the per-agent home lives, or a successful
    # apply can still trip a verify FAIL on the next leap step).
    #
    # apply-result.json records the applied_agents list and the canonical
    # paths the shim returned at apply time. Verify re-runs the shim to
    # pick up any layout drift since apply, then asserts every agent's
    # identity is present at the canonical home.
    target = Path(args.target).expanduser().resolve()
    repo_root = Path(args.repo_root).expanduser().resolve()

    _info(f"verify target: {target}")

    failures: List[str] = []
    passes: List[str] = []

    # --- Check 1: layout marker ---
    marker = target / "state" / "layout-marker.sh"
    if marker.is_file():
        text = marker.read_text()
        if "BRIDGE_LAYOUT" in text:
            passes.append("layout-marker: found and parseable")
        else:
            failures.append("layout-marker: present but BRIDGE_LAYOUT missing")
    else:
        # Not a hard failure — a fresh install may not have a marker yet.
        passes.append("layout-marker: absent (fresh install before marker write)")

    # --- Check 2: apply result manifest ---
    apply_result = target / ".migrator-apply-result.json"
    applied_agent_ids: List[str] = []
    if apply_result.is_file():
        try:
            ar = json.loads(apply_result.read_text())
            applied_agent_ids = list(ar.get("applied_agents", []))
            passes.append(f"apply-result: found ({len(applied_agent_ids)} agents)")
        except (json.JSONDecodeError, OSError):
            failures.append("apply-result: unreadable")
    else:
        failures.append("apply-result: .migrator-apply-result.json not found (apply not run?)")

    # --- Check 3: agent homes exist (via layout shim) ---
    # Drive path resolution through the same shim apply used so verify
    # cannot drift from the canonical contract. Fail closed when the shim
    # itself errors — that's a target the operator cannot trust.
    if applied_agent_ids:
        try:
            layout_info = _run_layout_shim(repo_root, target, applied_agent_ids)
        except SystemExit:
            failures.append("layout-shim: failed to resolve canonical paths (target unusable)")
            layout_info = {"agents": {}}
    else:
        layout_info = {"agents": {}}

    agent_paths = layout_info.get("agents", {})
    if applied_agent_ids and agent_paths:
        passes.append(
            f"agent-homes (via resolver): {len(applied_agent_ids)} agents — "
            f"{', '.join(applied_agent_ids)}"
        )
        for aid in applied_agent_ids:
            home_str = agent_paths.get(aid, {}).get("home_dir")
            if not home_str:
                failures.append(f"  agent {aid}: layout shim returned no home_dir")
                continue
            home = Path(home_str)
            if not home.is_dir():
                failures.append(f"  agent {aid}: home_dir missing on disk: {home}")
                continue
            has_identity = any((home / f).is_file() for f in IDENTITY_FILES)
            if has_identity:
                passes.append(f"  agent {aid}: identity files present at {home}")
            else:
                failures.append(f"  agent {aid}: no identity files found in {home}")
    elif applied_agent_ids:
        failures.append("agent-homes: layout shim returned no per-agent records")
    else:
        passes.append("agent-homes: none (no agents migrated)")

    # --- Check 4: cron definitions ---
    cron_jobs_path = target / "cron" / "jobs.json"
    if cron_jobs_path.is_file():
        try:
            jobs = json.loads(cron_jobs_path.read_text())
            passes.append(f"cron-definitions: {len(jobs)} jobs present")
        except (json.JSONDecodeError, OSError):
            failures.append("cron-definitions: jobs.json unreadable")
    else:
        passes.append("cron-definitions: absent (no cron jobs migrated or not yet created)")

    # --- Check 5: roster files exist ---
    roster = target / "agent-roster.sh"
    if roster.is_file():
        passes.append("roster: agent-roster.sh present")
    else:
        passes.append("roster: agent-roster.sh absent (fresh install will create on first start)")

    # --- Report ---
    print()
    print("=== VERIFY RESULTS ===")
    for p in passes:
        print(f"  PASS  {p}")
    for f in failures:
        print(f"  FAIL  {f}")

    if failures:
        print(f"\nverify: {len(failures)} failure(s)")
        return 1

    print(f"\nverify: all {len(passes)} checks passed")
    return 0


# ---------------------------------------------------------------------------
# Argument parsing + dispatch
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Legacy-install migrator core (invoked from migrate-legacy-install.sh).",
        add_help=True,
    )
    parser.add_argument("subcommand", choices=["export", "plan", "apply", "verify"])
    parser.add_argument("--repo-root", required=True, help="Agent Bridge source root")
    parser.add_argument("--migrator-tag", required=True, help="Migrator version tag")

    # export
    parser.add_argument("--source", help="Source BRIDGE_HOME (export)")
    parser.add_argument("--bundle", help="Bundle directory (export/plan/apply)")

    # plan / apply
    parser.add_argument("--target", help="Target BRIDGE_HOME (plan/apply/verify)")

    # apply secrets (never copied from source)
    parser.add_argument("--app-password-file", help="File containing Teams app password (apply)")
    parser.add_argument("--a2a-secret-file", help="File containing A2A HMAC key JSON (apply)")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.subcommand == "export":
        if not args.source:
            parser.error("export requires --source")
        if not args.bundle:
            parser.error("export requires --bundle")
        return cmd_export(args)

    elif args.subcommand == "plan":
        if not args.bundle:
            parser.error("plan requires --bundle")
        if not args.target:
            parser.error("plan requires --target")
        return cmd_plan(args)

    elif args.subcommand == "apply":
        if not args.bundle:
            parser.error("apply requires --bundle")
        if not args.target:
            parser.error("apply requires --target")
        return cmd_apply(args)

    elif args.subcommand == "verify":
        if not args.target:
            parser.error("verify requires --target")
        return cmd_verify(args)

    return 0


if __name__ == "__main__":
    sys.exit(main())
