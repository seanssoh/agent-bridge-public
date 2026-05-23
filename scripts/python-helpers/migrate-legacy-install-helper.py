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

# Target MUST be fresh/clean if these dirs are absent or empty.
CLEAN_TARGET_REQUIRED_ABSENT = (
    "state/agents",
    "state/tasks.db",
    "data/agents",
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


def _sanitize_cron_job(job: Dict[str, Any]) -> Dict[str, Any]:
    """
    Keep portable cron definition fields; strip runtime state.
    Schedule, target, title, payload_kind, enabled, timezone, followup_policy.
    Active run leases, run ids, last_run_* fields are non-portable.
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
    # Payload env vars may contain secrets — warn and strip.
    if "payload" in sanitized and isinstance(sanitized["payload"], dict):
        env_block = sanitized["payload"].get("env", {})
        secret_keys: List[str] = []
        for k in list(env_block.keys()):
            if any(kw in k.upper() for kw in ("TOKEN", "SECRET", "PASSWORD", "KEY", "PASS")):
                secret_keys.append(k)
        for k in secret_keys:
            del env_block[k]
            _warn(f"  cron job '{sanitized.get('name','?')}': env key '{k}' looks like a secret — stripped from bundle")
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
    target_ok = True
    for rel in CLEAN_TARGET_REQUIRED_ABSENT:
        p = target / rel
        if p.exists():
            if p.is_file() or any(True for _ in p.iterdir() if p.is_dir()):
                print(f"  WARN: target already has: {rel} — apply will REFUSE")
                target_ok = False
    if target_ok:
        print("  target appears clean/fresh — apply may proceed")

    return 0


# ---------------------------------------------------------------------------
# apply subcommand
# ---------------------------------------------------------------------------

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


def _write_backup_manifest(backup_dir: Path, target: Path) -> Path:
    """Write a manifest of what existed in the target before apply."""
    entries: List[Dict[str, str]] = []
    if target.is_dir():
        for p in sorted(target.rglob("*")):
            if p.is_file():
                rel = str(p.relative_to(target))
                entries.append({"rel_path": rel, "sha256": _sha256_file(p)})
    manifest = {
        "backup_at": _now_iso(),
        "target": str(target),
        "file_count": len(entries),
        "files": entries,
    }
    mpath = backup_dir / "pre-apply-backup-manifest.json"
    mpath.write_text(json.dumps(manifest, indent=2))
    return mpath


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


def cmd_apply(args: argparse.Namespace) -> int:
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

    # --- Gate 1: target must be clean/fresh ---
    is_clean, blockers = _target_is_clean(target)
    if not is_clean:
        _die(
            "target is not clean/fresh — apply refused.\n"
            "  blocking paths: " + ", ".join(blockers) + "\n"
            "  Use 'plan' to inspect, or point apply at a clean fresh-install target."
        )
    _info("target cleanliness: PASS")

    # --- Gate 2: mandatory backup + manifest ---
    backup_dir = target / ".migrator-pre-apply-backup"
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup_manifest_path = _write_backup_manifest(backup_dir, target)
    _info(f"pre-apply backup manifest: {backup_manifest_path}")

    # --- Gate 3: secrets are never copied; re-enter ---
    # A2A secret (from file, env, or skip).
    a2a_secret: Optional[str] = None
    teams_secret: Optional[str] = None

    if args.a2a_secret_file:
        a2a_secret = _read_secret_file(args.a2a_secret_file)
        _info("A2A HMAC secret: loaded from file")
    elif os.environ.get("BRIDGE_A2A_SHARED_SECRET"):
        a2a_secret = os.environ["BRIDGE_A2A_SHARED_SECRET"].strip()
        _info("A2A HMAC secret: loaded from BRIDGE_A2A_SHARED_SECRET env")
    else:
        _warn("A2A HMAC secret not supplied. A2A peer config will not be written.")
        _warn("  Supply via --a2a-secret-file or BRIDGE_A2A_SHARED_SECRET env.")

    if args.app_password_file:
        teams_secret = _read_secret_file(args.app_password_file)
        _info("Teams app password: loaded from file")
    elif os.environ.get("BRIDGE_TEAMS_APP_PASSWORD"):
        teams_secret = os.environ["BRIDGE_TEAMS_APP_PASSWORD"].strip()
        _info("Teams app password: loaded from BRIDGE_TEAMS_APP_PASSWORD env")
    else:
        # Check if source had Teams config — if so, prompt.
        stripped = manifest.get("secrets_stripped", [])
        teams_present = any("client-secret" in s or "teams" in s.lower() for s in stripped)
        if teams_present:
            _warn("Teams client secret detected in source — not copied.")
            if sys.stdin.isatty():
                teams_secret_input = _prompt_secret("[migrator] Enter Teams app password (or press Enter to skip): ")
                if teams_secret_input:
                    teams_secret = teams_secret_input
                    _info("Teams app password: entered interactively")
                else:
                    _info("Teams app password: skipped (enter manually after apply)")
            else:
                _warn("Non-interactive: Teams app password skipped. Enter manually after apply.")

    # --- Apply: write agent identity into target ---
    agents_bundle = bundle_dir / "agents"
    applied_agents: List[str] = []

    for agent_entry in manifest.get("agents", []):
        aid = agent_entry["agent_id"]
        agent_bundle_dir = agents_bundle / aid
        if not agent_bundle_dir.is_dir():
            _warn(f"  agent {aid}: bundle dir missing — skipping")
            continue

        # Determine target agent_home.
        # On a v2 target: data/agents/<agent>/home
        # On a legacy target: agents/<agent>
        target_marker = target / "state" / "layout-marker.sh"
        if target_marker.is_file() and "BRIDGE_LAYOUT=v2" in target_marker.read_text():
            agent_home_target = target / "data" / "agents" / aid / "home"
        else:
            agent_home_target = target / "agents" / aid

        agent_home_target.mkdir(parents=True, exist_ok=True)

        # Copy identity files.
        copied = 0
        for finfo in agent_entry.get("files", []):
            rel = finfo["rel_path"]
            cls = finfo.get("classification", "portable")
            if cls != "portable":
                continue  # never apply non-portable or secret items
            src = agent_bundle_dir / rel
            dst = agent_home_target / rel
            if not src.is_file():
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(src), str(dst))
            copied += 1

        applied_agents.append(aid)
        _info(f"  agent {aid}: {copied} identity files → {agent_home_target}")

    # --- Apply: cron definitions ---
    cron_jobs = manifest.get("cron_jobs", [])
    if cron_jobs:
        cron_home = target / "cron"
        cron_home.mkdir(parents=True, exist_ok=True)
        jobs_path = cron_home / "jobs.json"
        if jobs_path.is_file():
            _warn("target cron/jobs.json already exists — merging not supported; skipping cron import")
            _warn("  Manually merge from bundle/cron-definitions.json after apply.")
        else:
            jobs_path.write_text(json.dumps(cron_jobs, indent=2))
            _info(f"cron definitions: {len(cron_jobs)} imported → {jobs_path}")
        # Write a reference copy regardless.
        ref_path = backup_dir / "cron-definitions-from-bundle.json"
        ref_path.write_text(json.dumps(cron_jobs, indent=2))

    # --- Apply: write apply-result manifest ---
    apply_manifest = {
        "schema_version": MIGRATOR_SCHEMA_VERSION,
        "migrator_tag": args.migrator_tag,
        "applied_at": _now_iso(),
        "source_bundle": str(bundle_dir),
        "target": str(target),
        "applied_agents": applied_agents,
        "cron_jobs_imported": len(cron_jobs),
        "a2a_secret_supplied": a2a_secret is not None,
        "teams_secret_supplied": teams_secret is not None,
    }
    apply_result_path = target / ".migrator-apply-result.json"
    apply_result_path.write_text(json.dumps(apply_manifest, indent=2))
    _info(f"apply result: {apply_result_path}")

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
    if apply_result.is_file():
        try:
            ar = json.loads(apply_result.read_text())
            applied_agents = ar.get("applied_agents", [])
            passes.append(f"apply-result: found ({len(applied_agents)} agents)")
        except (json.JSONDecodeError, OSError):
            failures.append("apply-result: unreadable")
    else:
        failures.append("apply-result: .migrator-apply-result.json not found (apply not run?)")

    # --- Check 3: agent homes exist ---
    is_v2 = marker.is_file() and "BRIDGE_LAYOUT=v2" in (marker.read_text() if marker.is_file() else "")
    agent_home_root = (target / "data" / "agents") if is_v2 else (target / "agents")

    agent_dirs: List[str] = []
    if agent_home_root.is_dir():
        agent_dirs = [e.name for e in sorted(agent_home_root.iterdir()) if e.is_dir() and not e.name.startswith(".")]

    if agent_dirs:
        passes.append(f"agent-homes: {len(agent_dirs)} found: {', '.join(agent_dirs)}")
        # Check each has at least one identity file.
        for aid in agent_dirs:
            home = agent_home_root / aid / "home" if is_v2 else agent_home_root / aid
            has_identity = any((home / f).is_file() for f in IDENTITY_FILES)
            if has_identity:
                passes.append(f"  agent {aid}: identity files present")
            else:
                failures.append(f"  agent {aid}: no identity files found in {home}")
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
