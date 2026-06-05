#!/usr/bin/env python3
"""bridge-auth.py - local credential registry helpers for Agent Bridge."""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import platform
import pwd
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator


REGISTRY_VERSION = 1
TOKEN_ENV_KEY = "CLAUDE_CODE_OAUTH_TOKEN"
# ─────────────────────────────────────────────────────────────────────
# Fleet-credential engine-auth seam (L0 → L1, #1470 Phase 1).
#
# The Python side of the engine-auth descriptor. The bash descriptor
# (lib/bridge-engine-descriptor.sh) owns the same table for shell
# callers; this mirror lets bridge-auth.py dispatch credential
# operations BY ENGINE instead of hardcoding Claude.
#
# Phase 1 is behavior-preserving: `claude` resolves to exactly what the
# auth stack already hardcodes (the `claudeAiOauth` payload key, the
# `.claude/.credentials.json` dest, rotating-pool model). Codex is a
# descriptor slot only — the adapter that fills `register`/`sync`/
# `verify` is Phase 2. Any engine that is not credential-managed answers
# `auth_supported = False` so callers degrade cleanly.
#
# `ENGINE_AUTH_DESCRIPTOR` is the single table. Keeping it data (not
# scattered conditionals) is the whole point of the seam — Phase 2 adds
# one row, no new branches in the sync writer.
DEFAULT_AUTH_ENGINE = "claude"
CLAUDE_CRED_PAYLOAD_KEY = "claudeAiOauth"
ENGINE_AUTH_DESCRIPTOR: dict[str, dict[str, Any]] = {
    "claude": {
        "auth_supported": True,
        "auth_model": "rotating-pool",
        "cred_dest_tail": ".claude/.credentials.json",
        "cred_source": "registry",
        "supports_rotation": True,
        "usage_source": "native-oauth-probe",
        # `None` payload key would mean opaque whole-file copy; Claude
        # extracts/writes under this key.
        "cred_payload_key": CLAUDE_CRED_PAYLOAD_KEY,
    },
    "codex": {
        "auth_supported": True,
        "auth_model": "single-source-sync",
        "cred_dest_tail": ".codex/auth.json",
        "cred_source": "agent-source",
        "supports_rotation": False,
        "usage_source": "codex-snapshots",
        # Opaque copy — no key extraction. The adapter (Phase 2) writes
        # the source auth.json verbatim through write_private_file_atomic.
        "cred_payload_key": None,
    },
    "antigravity": {
        "auth_supported": False,
        "auth_model": "none",
        "cred_dest_tail": None,
        "cred_source": "none",
        "supports_rotation": False,
        "usage_source": "none",
        "cred_payload_key": None,
    },
}


def engine_auth_descriptor(engine: str) -> dict[str, Any]:
    """Return the auth descriptor row for ``engine``.

    Raises ``ValueError`` for an unknown engine so a caller can never
    silently fall through to Claude behavior on a typo. The default
    engine for the Claude-token path is resolved by the *caller*
    (DEFAULT_AUTH_ENGINE), not by swallowing unknowns here.
    """
    row = ENGINE_AUTH_DESCRIPTOR.get(engine)
    if row is None:
        raise ValueError(f"unknown engine for auth descriptor: {engine!r}")
    return row


def engine_auth_supported(engine: str) -> bool:
    return bool(engine_auth_descriptor(engine)["auth_supported"])
TOKEN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
# #1437 — single source of truth for the usage-limit/429 substrings. Used by
# both ``classify_probe`` (the token-recovery probe) and the new
# ``classify-output`` subcommand the cron runner calls on a live run's
# captured stdout/stderr, so the reactive cron rotation path never forks the
# marker list.
QUOTA_LIMIT_MARKERS = ("hit your limit", "usage limit")
AUTH_FAILED_MARKERS = ("invalid api key", "unauthorized")
CLAUDE_OAUTH_EXPIRES_AT_MS = 4102444800000
CLAUDE_OAUTH_SCOPES = ["user:inference", "user:profile"]
CLAUDE_CONFIG_MIGRATION_VERSION = 13
ROOT = Path(__file__).resolve().parent
KEYCHAIN_FREE_CONFIG_KEY = "claude_keychain_free_auth"
API_KEY_HELPER_CONFIG_KEY = "claude_api_key_helper"
API_KEY_HELPER_TTL_CONFIG_KEY = "claude_api_key_helper_ttl_ms"
DEFAULT_API_KEY_HELPER_TTL_MS = 60000
TRUE_STRINGS = {"1", "true", "yes", "on"}
MONTHS = {
    "january": 1,
    "february": 2,
    "march": 3,
    "april": 4,
    "may": 5,
    "june": 6,
    "july": 7,
    "august": 8,
    "september": 9,
    "october": 10,
    "november": 11,
    "december": 12,
}


def now_utc() -> datetime:
    fixed = os.environ.get("BRIDGE_AUTH_NOW_UTC")
    if fixed:
        value = fixed.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    return datetime.now(timezone.utc)


def now_iso() -> str:
    return now_utc().isoformat(timespec="seconds")


def iso_to_utc(value: str) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def json_dump(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=True, indent=2))


def fail(message: str, json_mode: bool = False, rc: int = 1) -> int:
    if json_mode:
        json_dump({"status": "error", "error": message})
    else:
        print(f"[error] {message}", file=sys.stderr)
    return rc


def env_truthy(value: str | None) -> bool:
    return str(value or "").strip().lower() in TRUE_STRINGS


def runtime_config_path() -> Path | None:
    explicit = os.environ.get("BRIDGE_RUNTIME_CONFIG_FILE", "").strip()  # noqa: iso-helper-boundary - controller runtime config path
    if explicit:
        return Path(explicit).expanduser()

    runtime_root = os.environ.get("BRIDGE_RUNTIME_ROOT", "").strip()  # noqa: iso-helper-boundary - controller runtime root
    if runtime_root:
        root = Path(runtime_root).expanduser()
    else:
        bridge_home = os.environ.get("BRIDGE_HOME", "").strip()  # noqa: iso-helper-boundary - controller bridge home fallback
        if not bridge_home:
            return None
        root = Path(bridge_home).expanduser() / "runtime"

    canonical = root / "bridge-config.json"
    legacy = root / "openclaw.json"
    if canonical.is_file():  # noqa: raw-pathlib-controller-only - controller runtime config probe
        return canonical
    if legacy.is_file():  # noqa: raw-pathlib-controller-only - controller runtime config probe
        return legacy
    return canonical


def load_runtime_config() -> dict[str, Any]:
    path = runtime_config_path()
    if path is None or not path.is_file():  # noqa: raw-pathlib-controller-only - controller runtime config read
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def runtime_config_value(key: str) -> Any:
    return load_runtime_config().get(key)


def runtime_config_truthy(key: str) -> bool:
    value = runtime_config_value(key)
    if isinstance(value, bool):
        return value
    return env_truthy(str(value) if value is not None else "")


def host_platform() -> str:
    override = os.environ.get("BRIDGE_HOST_PLATFORM_OVERRIDE", "").strip()  # noqa: iso-helper-boundary - controller host-platform override
    if override:
        return override
    return platform.system()


def keychain_free_apikeyhelper_supported() -> bool:
    """True only where the keychain-free apiKeyHelper feature actually applies.

    #1444 BLOCKING 3 (Linux/iso-v2 leak): the apiKeyHelper feature is a
    macOS-keychain-only mechanism, and the cron-runner/bridge-run.sh preflights
    are already Darwin-gated. The settings WRITER
    (``ensure_claude_settings_file``) was NOT, so on Linux it rendered a
    controller helper path into an agent's ``settings.json`` — and under iso v2
    that controller path is not even reachable from the agent UID. Gate the
    write on the SAME platform check the preflights use so a non-Darwin agent
    never receives a controller helper path. ``BRIDGE_HOST_PLATFORM_OVERRIDE``
    lets the smoke drive both the Darwin and non-Darwin branches deterministically.
    """
    return host_platform() == "Darwin"


def claude_keychain_free_auth_enabled() -> bool:
    override = os.environ.get("BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH")  # noqa: iso-helper-boundary - controller feature gate
    if override is not None and override.strip():
        return env_truthy(override)
    return runtime_config_truthy(KEYCHAIN_FREE_CONFIG_KEY)


def claude_api_key_helper_path() -> str:
    raw = (
        os.environ.get("BRIDGE_CLAUDE_API_KEY_HELPER", "").strip()  # noqa: iso-helper-boundary - controller helper override
        or str(runtime_config_value(API_KEY_HELPER_CONFIG_KEY) or "").strip()
        or str(ROOT / "scripts" / "claude-oat-api-key-helper.sh")
    )
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = ROOT / path
    return str(path.resolve(strict=False))


def apikeyhelper_value_is_bridge_managed(value: Any) -> bool:
    """Return True if a settings.json ``apiKeyHelper`` value is one agent-bridge renders.

    Used by the disable/rollback path: when the keychain-free gate is turned
    off we must REMOVE the managed helper so Claude falls back to its normal
    keychain auth — but we must NEVER clobber an operator-owned helper. We
    only treat a value as "ours" when it equals the path
    ``claude_api_key_helper_path()`` would write, or the in-repo default helper
    (``scripts/claude-oat-api-key-helper.sh``). Anything else is operator state
    we leave untouched.

    #1444 SHOULD-FIX 4 (symlink edge): the comparison is on the RAW (absolutized
    but NOT symlink-resolved) value, deliberately. The value we WRITE on enable
    is already canonical (``claude_api_key_helper_path()`` calls
    ``resolve(strict=False)``), so a raw-vs-canonical comparison still matches
    our own writes and the disable cleanup stays idempotent. The contract we
    are choosing: an operator who points ``apiKeyHelper`` at *their own symlink*
    that happens to resolve onto the managed helper KEEPS that value across a
    disable — we only ever remove the literal managed path we wrote, never an
    operator-introduced symlink that merely dereferences to it. (The prior
    ``resolve()`` form removed such a symlink, surprising the operator.) Both
    ``current`` and the candidate set are absolutized via the same builtin
    ``ROOT``-anchoring, so a relative settings value still matches.
    """
    if not isinstance(value, str) or not value.strip():
        return False
    try:
        current = Path(value).expanduser()
        if not current.is_absolute():
            current = ROOT / current
        # RAW comparison (no resolve()): absolutize via os.path.normpath so a
        # relative or ``..``-laden value normalizes, but an operator symlink is
        # NOT dereferenced — it survives disable.
        current = Path(os.path.normpath(str(current)))
    except (OSError, ValueError):
        return False
    managed_candidates = {claude_api_key_helper_path()}
    # The in-repo default, independent of any operator override — so a value
    # we previously rendered with the default still matches after an operator
    # later points ``claude_api_key_helper`` at a custom path.
    default_helper = (ROOT / "scripts" / "claude-oat-api-key-helper.sh").resolve(
        strict=False
    )
    managed_candidates.add(str(default_helper))
    return str(current) in managed_candidates


def claude_api_key_helper_ttl_ms() -> int:
    raw = (
        os.environ.get("BRIDGE_CLAUDE_API_KEY_HELPER_TTL_MS", "").strip()  # noqa: iso-helper-boundary - controller helper TTL
        or str(runtime_config_value(API_KEY_HELPER_TTL_CONFIG_KEY) or "").strip()
    )
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_API_KEY_HELPER_TTL_MS
    return value if value > 0 else DEFAULT_API_KEY_HELPER_TTL_MS


def token_fingerprint(token: str) -> str:
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    tail = token[-4:] if len(token) >= 4 else token
    return f"sha256:{digest[:12]}...{tail}"


def validate_token_id(token_id: str) -> None:
    if not TOKEN_ID_RE.match(token_id):
        raise ValueError("token id must match [A-Za-z0-9][A-Za-z0-9_.-]{0,63}")


def validate_token(token: str) -> None:
    if not token:
        raise ValueError("token is empty")
    if token.startswith("<REDACTED"):
        raise ValueError("token looks redacted")
    if len(token) < 20:
        raise ValueError("token is too short")
    if "'" in token:
        raise ValueError("token cannot contain a single quote")
    if any(ch.isspace() for ch in token):
        raise ValueError("token cannot contain whitespace")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in token):
        raise ValueError("token cannot contain control characters")


def validate_threshold(value: float) -> float:
    value = float(value)
    if value <= 0 or value > 100:
        raise ValueError("threshold must be > 0 and <= 100")
    return value


def claude_oauth_credentials_payload(token: str) -> dict[str, Any]:
    # Fleet-credential Phase 1 (#1470): the payload key is sourced from
    # the engine-auth descriptor instead of an inline literal. For Claude
    # this resolves to `claudeAiOauth` — byte-identical to the prior
    # hardcoded shape.
    payload_key = engine_auth_descriptor(DEFAULT_AUTH_ENGINE)["cred_payload_key"]
    return {
        payload_key: {
            "accessToken": token,
            "expiresAt": CLAUDE_OAUTH_EXPIRES_AT_MS,
            "scopes": CLAUDE_OAUTH_SCOPES,
        }
    }


def claude_config_bootstrap_payload(
    existing: dict[str, Any] | None = None,
    trusted_workdirs: list[str] | None = None,
) -> dict[str, Any]:
    payload = dict(existing or {})
    now = now_utc()
    payload.setdefault("firstStartTime", now.isoformat(timespec="milliseconds").replace("+00:00", "Z"))
    payload.setdefault("hasCompletedOnboarding", True)
    payload.setdefault("opusProMigrationComplete", True)
    payload.setdefault("sonnet1m45MigrationComplete", True)
    payload.setdefault("seenNotifications", {})
    payload.setdefault("migrationVersion", CLAUDE_CONFIG_MIGRATION_VERSION)
    payload.setdefault("changelogLastFetched", int(now.timestamp() * 1000))
    payload.setdefault("userID", str(uuid.uuid4()))
    if trusted_workdirs:
        projects = payload.get("projects")
        if projects is None:
            projects = {}
            payload["projects"] = projects
        if not isinstance(projects, dict):
            raise ValueError("Claude config projects must contain a JSON object")
        for workdir in trusted_workdirs:
            project = projects.get(workdir)
            if not isinstance(project, dict):
                project = {}
                projects[workdir] = project
            project["hasTrustDialogAccepted"] = True
            project["hasCompletedProjectOnboarding"] = True
            project.setdefault("allowedTools", [])
            project.setdefault("mcpContextUris", [])
            project.setdefault("mcpServers", {})
            project.setdefault("enabledMcpjsonServers", [])
            project.setdefault("disabledMcpjsonServers", [])
    return payload


def read_token(args: argparse.Namespace) -> str:
    if bool(args.stdin) == bool(args.token_file):
        raise ValueError("choose exactly one token source: --stdin or --token-file")
    if args.stdin:
        token = sys.stdin.read().rstrip("\r\n")
    else:
        token = Path(args.token_file).expanduser().read_text(encoding="utf-8").rstrip("\r\n")
    validate_token(token)
    return token


def default_registry() -> dict[str, Any]:
    return {
        "version": REGISTRY_VERSION,
        "active_token_id": "",
        "auto_rotate_enabled": False,
        "rotation_threshold": 99.0,
        "tokens": [],
        "last_rotation": {},
    }


def normalize_registry(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        payload = {}
    result = default_registry()
    result.update(payload)
    if not isinstance(result.get("tokens"), list):
        result["tokens"] = []
    result["tokens"] = [row for row in result["tokens"] if isinstance(row, dict)]
    if not isinstance(result.get("last_rotation"), dict):
        result["last_rotation"] = {}
    result["version"] = REGISTRY_VERSION
    return result


def load_registry(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return default_registry()
    try:
        return normalize_registry(json.loads(path.read_text(encoding="utf-8")))
    except Exception:
        raise ValueError(f"cannot parse registry: {path}")


def save_registry(path: Path, payload: dict[str, Any]) -> None:
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    text = json.dumps(normalize_registry(payload), ensure_ascii=True, indent=2) + "\n"
    fd = -1
    tmp_name = ""
    try:
        fd, tmp_name = tempfile.mkstemp(prefix=".claude-oauth-tokens.", suffix=".tmp", dir=str(path.parent))
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fd = -1
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
        os.chmod(path, 0o600)
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass


REGISTRY_LOCK_SUFFIX = ".lock"
REGISTRY_LOCK_DEFAULT_TIMEOUT_SECONDS = 30


@contextmanager
def registry_lock(
    registry_path: Path,
    *,
    timeout_seconds: int = REGISTRY_LOCK_DEFAULT_TIMEOUT_SECONDS,
) -> Iterator[None]:
    """Inter-process exclusive lock for the token registry.

    PR #799 r2 codex finding 3 — every mutating cmd_* path performs a
    read-modify-write (``load_registry`` -> mutate -> ``save_registry``).
    Concurrent invocations (e.g. the daemon's rotate loop racing an
    operator ``activate`` or the recovery probe re-persisting state)
    can drop one writer's changes because ``save_registry`` uses
    ``os.replace`` for atomicity but not concurrency.

    Implementation notes:
    - Uses ``fcntl.flock`` on a sibling ``.lock`` file (Linux + macOS
      both honor it; the registry tree is POSIX-only).
    - ``flock`` has no native timeout, so we poll non-blockingly until
      ``timeout_seconds`` elapses to avoid an unbounded blocker.
    - The lock guards the load->mutate->save critical section ONLY.
      Slow operations (``probe_claude_token``, a 45 s network call)
      MUST be lifted OUT of the lock by reading state under the lock,
      releasing, probing, then re-acquiring to persist results — see
      ``cmd_recover_due`` for the canonical pattern.
    """
    registry_path = Path(registry_path).expanduser()
    lock_path = registry_path.with_suffix(
        registry_path.suffix + REGISTRY_LOCK_SUFFIX
    )
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    # Open the lock file with O_RDWR | O_CREAT so flock owns a real fd
    # even on a fresh registry tree. 0o600 keeps the sibling restricted
    # to the operator UID, matching the registry file itself.
    fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
    acquired = False
    try:
        deadline = time.monotonic() + max(1, int(timeout_seconds))
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                pass
            except OSError as exc:
                # EWOULDBLOCK comes through as BlockingIOError on
                # Python 3.3+, but some old kernels surface EACCES on
                # the very first non-blocking attempt. Treat both as
                # transient, anything else fails fast.
                if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
                    raise
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    f"registry_lock timeout after {timeout_seconds}s on {lock_path}"
                )
            time.sleep(0.1)
        yield
    finally:
        if acquired:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        try:
            os.close(fd)
        except OSError:
            pass


def token_rows(registry: dict[str, Any]) -> list[dict[str, Any]]:
    return registry.setdefault("tokens", [])


def find_token(registry: dict[str, Any], token_id: str) -> dict[str, Any] | None:
    for row in token_rows(registry):
        if row.get("id") == token_id:
            return row
    return None


def active_registry_token(registry: dict[str, Any]) -> tuple[str, str]:
    active_id = str(registry.get("active_token_id") or "")
    if not active_id:
        raise ValueError("no active Claude OAuth token registered")
    row = find_token(registry, active_id)
    if row is None:
        raise ValueError("active Claude OAuth token id is missing from registry")
    if not bool(row.get("enabled", True)):
        raise ValueError("active Claude OAuth token is disabled")
    token = str(row.get("token") or "")
    validate_token(token)
    return active_id, token


def public_token_row(row: dict[str, Any], active_id: str) -> dict[str, Any]:
    token = str(row.get("token") or "")
    return {
        "id": row.get("id") or "",
        "active": row.get("id") == active_id,
        "enabled": bool(row.get("enabled", True)),
        "fingerprint": token_fingerprint(token) if token else "",
        "created_at": row.get("created_at") or "",
        "updated_at": row.get("updated_at") or "",
        "last_activated_at": row.get("last_activated_at") or "",
        "last_checked_at": row.get("last_checked_at") or "",
        "last_check_status": row.get("last_check_status") or "",
        "disabled_reason": row.get("disabled_reason") or "",
        "disabled_until": row.get("disabled_until") or "",
        "next_check_at": row.get("next_check_at") or "",
        "note": row.get("note") or "",
    }


def public_registry(registry: dict[str, Any]) -> dict[str, Any]:
    active_id = str(registry.get("active_token_id") or "")
    return {
        "version": REGISTRY_VERSION,
        "active_token_id": active_id,
        "auto_rotate_enabled": bool(registry.get("auto_rotate_enabled", False)),
        "rotation_threshold": float(registry.get("rotation_threshold") or 99.0),
        "tokens": [public_token_row(row, active_id) for row in token_rows(registry)],
        "last_rotation": registry.get("last_rotation") or {},
    }


def enabled_token_ids(registry: dict[str, Any]) -> list[str]:
    ids = []
    for row in token_rows(registry):
        if bool(row.get("enabled", True)) and row.get("token"):
            ids.append(str(row.get("id") or ""))
    return [token_id for token_id in ids if token_id]


def redact_token(text: str, token: str) -> str:
    if not text or not token:
        return text
    return text.replace(token, "<redacted-token>")


def collect_json_value(payload: Any, key: str) -> Any:
    if isinstance(payload, dict):
        if key in payload:
            return payload[key]
        for value in payload.values():
            found = collect_json_value(value, key)
            if found is not None:
                return found
    elif isinstance(payload, list):
        for value in payload:
            found = collect_json_value(value, key)
            if found is not None:
                return found
    return None


def parse_reset_at(text: str, reference: datetime | None = None) -> str:
    if not text:
        return ""
    reference = reference or now_utc()
    absolute = re.search(
        r"\bresets?\s+([A-Za-z]+)\s+(\d{1,2}),\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(UTC\)",
        text,
        re.IGNORECASE,
    )
    if absolute:
        month = MONTHS.get(absolute.group(1).lower())
        if month:
            day = int(absolute.group(2))
            hour = int(absolute.group(3))
            minute = int(absolute.group(4) or "0")
            meridiem = absolute.group(5).lower()
            if meridiem == "pm" and hour != 12:
                hour += 12
            if meridiem == "am" and hour == 12:
                hour = 0
            candidate = datetime(reference.year, month, day, hour, minute, tzinfo=timezone.utc)
            if candidate < reference - timedelta(days=1):
                candidate = candidate.replace(year=reference.year + 1)
            return candidate.isoformat(timespec="seconds")

    relative = re.search(r"\bresets?\s+in\s+(\d+)h(?:\s+(\d+)m)?", text, re.IGNORECASE)
    if relative:
        hours = int(relative.group(1))
        minutes = int(relative.group(2) or "0")
        return (reference + timedelta(hours=hours, minutes=minutes)).isoformat(timespec="seconds")

    return ""


def classify_probe(stdout: str, stderr: str, returncode: int) -> tuple[str, dict[str, Any]]:
    raw = "\n".join(part for part in (stdout, stderr) if part)
    payload: Any = None
    if stdout.strip():
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError:
            payload = None

    api_status = collect_json_value(payload, "api_error_status") if payload is not None else None
    result = collect_json_value(payload, "result") if payload is not None else ""
    if isinstance(result, (dict, list)):
        result_text = json.dumps(result, ensure_ascii=True)
    else:
        result_text = str(result or "")
    combined = "\n".join(part for part in (result_text, raw) if part)
    reset_at = parse_reset_at(combined)

    api_status_text = str(api_status or "")
    lower = combined.lower()
    detail: dict[str, Any] = {
        "api_error_status": api_status_text,
        "reset_at": reset_at,
        "returncode": returncode,
    }

    if api_status_text == "429" or any(marker in lower for marker in QUOTA_LIMIT_MARKERS):
        return "quota_limited", detail
    if api_status_text in {"401", "403"} or any(marker in lower for marker in AUTH_FAILED_MARKERS):
        return "auth_failed", detail

    if payload is not None:
        is_error = bool(collect_json_value(payload, "is_error"))
        if returncode == 0 and not is_error:
            return "available", detail
    elif returncode == 0:
        return "available", detail

    return "failed", detail


def probe_claude_token(token: str, timeout_seconds: int) -> dict[str, Any]:
    claude_bin = os.environ.get("BRIDGE_CLAUDE_TOKEN_CHECK_BIN", "claude")
    prompt = os.environ.get("BRIDGE_CLAUDE_TOKEN_CHECK_PROMPT", "Return exactly OK.")
    command = [claude_bin, "-p", prompt, "--output-format", "json"]
    try:
        with tempfile.TemporaryDirectory(prefix="agb-claude-token-check.") as config_dir:
            config_path = Path(config_dir)
            os.chmod(config_path, 0o700)
            write_claude_credentials_file(config_path / ".credentials.json", token)
            ensure_claude_config_file(config_path)
            env = os.environ.copy()
            env.pop(TOKEN_ENV_KEY, None)
            env.pop("ANTHROPIC_API_KEY", None)
            env.pop("ANTHROPIC_AUTH_TOKEN", None)
            env["CLAUDE_CONFIG_DIR"] = str(config_path)
            proc = subprocess.run(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout_seconds,
                env=env,
                check=False,
            )
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "returncode": 124, "api_error_status": "", "reset_at": ""}
    except FileNotFoundError:
        return {"status": "failed", "returncode": 127, "api_error_status": "", "reset_at": "", "error": "claude_not_found"}

    stdout = redact_token(proc.stdout or "", token)
    stderr = redact_token(proc.stderr or "", token)
    status, detail = classify_probe(stdout, stderr, proc.returncode)
    detail["status"] = status
    return detail


def clear_quota_disable_fields(row: dict[str, Any]) -> None:
    for key in ("disabled_reason", "disabled_until", "next_check_at"):
        row.pop(key, None)


def update_row_from_probe(
    row: dict[str, Any],
    probe: dict[str, Any],
    *,
    enable_on_ok: bool,
    disable_on_quota: bool,
    retry_seconds: int,
) -> dict[str, Any]:
    timestamp = now_iso()
    status = str(probe.get("status") or "failed")
    reset_at = str(probe.get("reset_at") or "")
    row["last_checked_at"] = timestamp
    row["last_check_status"] = status
    row["last_check_api_error_status"] = str(probe.get("api_error_status") or "")
    row["last_check_returncode"] = int(probe.get("returncode") or 0)

    if status == "available" and enable_on_ok:
        row["enabled"] = True
        clear_quota_disable_fields(row)
    elif status == "quota_limited" and disable_on_quota:
        row["enabled"] = False
        row["disabled_reason"] = "quota_limited"
        if reset_at:
            row["disabled_until"] = reset_at
            row["next_check_at"] = reset_at
        else:
            row["next_check_at"] = (now_utc() + timedelta(seconds=retry_seconds)).isoformat(timespec="seconds")
    elif status not in {"available", "quota_limited"}:
        row["next_check_at"] = (now_utc() + timedelta(seconds=retry_seconds)).isoformat(timespec="seconds")

    row["updated_at"] = timestamp
    return public_token_row(row, "")


def quota_recheck_due(row: dict[str, Any], reference: datetime) -> bool:
    if bool(row.get("enabled", True)):
        return False
    if str(row.get("disabled_reason") or "") != "quota_limited":
        return False
    due_values = [str(row.get("next_check_at") or ""), str(row.get("disabled_until") or "")]
    for value in due_values:
        due_at = iso_to_utc(value)
        if due_at is not None and due_at <= reference:
            return True
    return not any(due_values)


def _apply_token_to_registry(
    registry_path: Path,
    token_id: str,
    token: str,
    *,
    note: str = "",
    activate: bool = False,
    replace: bool = False,
    enable_auto_rotate: bool = False,
    threshold: float | None = None,
) -> dict[str, Any]:
    """Write *token* into the locked registry under *token_id*.

    Shared core for ``cmd_add`` and ``cmd_receive`` (#1367). The token
    is already in process memory (read from ``--stdin``/``--token-file``
    for ``add``, or echo-off from ``/dev/tty`` for ``receive``); this
    helper performs the locked read-modify-write only. Token validation
    is the caller's responsibility (done OUTSIDE the lock so the
    critical section stays narrow, per PR #799 r2 codex finding 3).

    Returns the result payload (``status``/``id``/``active_token_id``/
    ``fingerprint``/``registry``). Raises ``ValueError`` on a duplicate
    id without ``replace``.
    """
    with registry_lock(registry_path):
        registry = load_registry(registry_path)

        rows = token_rows(registry)
        existing = find_token(registry, token_id)
        timestamp = now_iso()
        row = {
            "id": token_id,
            "token": token,
            "enabled": True,
            "created_at": timestamp,
            "updated_at": timestamp,
            "last_activated_at": "",
            "note": note or "",
        }
        if existing is not None:
            if not replace:
                raise ValueError(f"token id already exists: {token_id}")
            row["created_at"] = existing.get("created_at") or timestamp
            row["last_activated_at"] = existing.get("last_activated_at") or ""
            rows[rows.index(existing)] = row
        else:
            rows.append(row)

        if activate or not registry.get("active_token_id"):
            registry["active_token_id"] = token_id
            row["last_activated_at"] = timestamp
        if enable_auto_rotate:
            registry["auto_rotate_enabled"] = True
        if threshold is not None:
            registry["rotation_threshold"] = validate_threshold(threshold)

        save_registry(registry_path, registry)

    return {
        "status": "added" if existing is None else "replaced",
        "id": token_id,
        "active_token_id": registry.get("active_token_id") or "",
        "fingerprint": token_fingerprint(token),
        "registry": str(registry_path),
    }


def cmd_add(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    # PR #799 r2 codex finding 3 — ``read_token`` reads --stdin /
    # --token-file and does no IO on the registry. Validate it OUTSIDE
    # the lock so the critical section stays narrow.
    try:
        validate_token_id(args.id)
        token = read_token(args)
    except Exception as exc:
        return fail(str(exc), json_mode)

    try:
        payload = _apply_token_to_registry(
            registry_path,
            args.id,
            token,
            note=args.note or "",
            activate=bool(args.activate),
            replace=bool(args.replace),
            enable_auto_rotate=bool(args.enable_auto_rotate),
            threshold=args.threshold,
        )
    except Exception as exc:
        return fail(str(exc), json_mode)

    if json_mode:
        json_dump(payload)
    else:
        print(f"{payload['status']}: {args.id} ({payload['fingerprint']})")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    try:
        registry = load_registry(Path(args.registry).expanduser())
    except Exception as exc:
        return fail(str(exc), json_mode)
    payload = public_registry(registry)
    if json_mode:
        json_dump({"status": "ok", **payload})
        return 0
    print(f"active_token_id: {payload['active_token_id'] or '-'}")
    print(f"auto_rotate_enabled: {'yes' if payload['auto_rotate_enabled'] else 'no'}")
    print(f"rotation_threshold: {payload['rotation_threshold']:.0f}%")
    for row in payload["tokens"]:
        active = "*" if row["active"] else " "
        enabled = "enabled" if row["enabled"] else "disabled"
        print(f"{active} {row['id']}\t{enabled}\t{row['fingerprint']}\t{row['note']}")
    return 0


def cmd_activate(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    # PR #799 r2 codex finding 3 — registry lock around the load->mutate->save.
    try:
        with registry_lock(registry_path):
            registry = load_registry(registry_path)
            row = find_token(registry, args.id)
            if row is None:
                raise ValueError(f"unknown token id: {args.id}")
            if not bool(row.get("enabled", True)):
                raise ValueError(f"token id is disabled: {args.id}")
            registry["active_token_id"] = args.id
            row["last_activated_at"] = now_iso()
            save_registry(registry_path, registry)
    except Exception as exc:
        return fail(str(exc), json_mode)
    payload = {
        "status": "activated",
        "active_token_id": args.id,
        "fingerprint": token_fingerprint(str(row.get("token") or "")),
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"activated: {args.id} ({payload['fingerprint']})")
    return 0


def cmd_rotate(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    # PR #799 r2 codex finding 3 — registry lock around the load->mutate->save.
    old_id = ""
    new_id = ""
    row: dict[str, Any] | None = None
    skipped_payload: dict[str, Any] | None = None
    try:
        with registry_lock(registry_path):
            registry = load_registry(registry_path)
            if args.if_auto_enabled and not bool(registry.get("auto_rotate_enabled", False)):
                skipped_payload = {"status": "skipped", "reason": "auto_rotate_disabled"}
            else:
                ids = enabled_token_ids(registry)
                if len(ids) < 2:
                    skipped_payload = {
                        "status": "skipped",
                        "reason": "no_alternate_token",
                        "active_token_id": registry.get("active_token_id") or "",
                    }
                else:
                    old_id = str(registry.get("active_token_id") or "")
                    if old_id not in ids:
                        new_id = ids[0]
                    else:
                        new_id = ids[(ids.index(old_id) + 1) % len(ids)]
                    row = find_token(registry, new_id)
                    if row is None:
                        raise ValueError(f"rotation selected missing token id: {new_id}")
                    timestamp = now_iso()
                    registry["active_token_id"] = new_id
                    row["last_activated_at"] = timestamp
                    registry["last_rotation"] = {
                        "rotated_at": timestamp,
                        "from": old_id,
                        "to": new_id,
                        "reason": args.reason or "",
                    }
                    save_registry(registry_path, registry)
    except Exception as exc:
        return fail(str(exc), json_mode)

    if skipped_payload is not None:
        if json_mode:
            json_dump(skipped_payload)
        else:
            print(f"skipped: {skipped_payload['reason']}")
        return 0
    payload = {
        "status": "rotated",
        "old_active_token_id": old_id,
        "active_token_id": new_id,
        "fingerprint": token_fingerprint(str(row.get("token") or "")),
        "reason": args.reason or "",
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"rotated: {old_id or '-'} -> {new_id} ({payload['fingerprint']})")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    retry_seconds = int(args.retry_seconds or 1800)
    timeout_seconds = int(args.timeout or 45)
    # PR #799 r2 codex finding 3 — split into a locked read, an
    # unlocked probe (45 s network op), and a locked persist. Holding
    # the lock across ``probe_claude_token`` would block every other
    # registry mutation (the daemon's rotate loop, operator activate,
    # recovery sweep) for the duration of the network call.
    #
    # PR #799 r3 codex finding 2 — also snapshot the token fingerprint
    # during the locked read and re-verify it during the locked
    # persist. Without that check a concurrent ``cmd_add --replace``
    # (or any other mutator that swaps the row's token value while
    # keeping the row id) would have the stale probe persisted onto
    # the new token. Fingerprint comparison keeps the raw token off
    # the diff and audit log.
    skipped_stale_reason = ""
    try:
        with registry_lock(registry_path):
            registry = load_registry(registry_path)
            row = find_token(registry, args.id)
            if row is None:
                raise ValueError(f"unknown token id: {args.id}")
            token = str(row.get("token") or "")
            validate_token(token)
            snapshot_fingerprint = token_fingerprint(token)

        probe = probe_claude_token(token, timeout_seconds)

        with registry_lock(registry_path):
            registry = load_registry(registry_path)
            row = find_token(registry, args.id)
            if row is None:
                # Token was deleted between the probe and the persist.
                # Surface the probe result without persisting; the
                # caller will see the result but no row update.
                skipped_stale_reason = "row_deleted"
            else:
                current_token = str(row.get("token") or "")
                current_fingerprint = (
                    token_fingerprint(current_token) if current_token else ""
                )
                if current_fingerprint != snapshot_fingerprint:
                    # Token VALUE was replaced (cmd_add --replace,
                    # cmd_rotate, etc.) during the unlocked probe
                    # window. Discard the stale probe rather than
                    # persisting it onto the new token.
                    skipped_stale_reason = "token_replaced"
                    row = None
                else:
                    update_row_from_probe(
                        row,
                        probe,
                        enable_on_ok=bool(args.enable_on_ok),
                        disable_on_quota=bool(args.disable_on_quota),
                        retry_seconds=retry_seconds,
                    )
                    save_registry(registry_path, registry)
    except Exception as exc:
        return fail(str(exc), json_mode)

    active_id = str(registry.get("active_token_id") or "")
    payload = {
        "status": str(probe.get("status") or "failed"),
        "id": args.id,
        "active_token_id": active_id,
        "api_error_status": str(probe.get("api_error_status") or ""),
        "reset_at": str(probe.get("reset_at") or ""),
        "token": public_token_row(row, active_id) if row is not None else {},
    }
    if skipped_stale_reason:
        # Surface the skip so machine-readable callers can distinguish
        # "probe persisted" from "probe discarded due to mid-probe row
        # mutation." Backwards-compatible additions only.
        payload["status"] = "skipped"
        payload["reason"] = skipped_stale_reason
    if json_mode:
        json_dump(payload)
    else:
        if skipped_stale_reason:
            print(f"skipped: {args.id} reason={skipped_stale_reason}")
        else:
            reset = f" reset_at={payload['reset_at']}" if payload["reset_at"] else ""
            print(f"{payload['status']}: {args.id}{reset}")
    return 0


def cmd_classify_output(args: argparse.Namespace) -> int:
    """#1437 — classify a *live run's* captured output (no network probe).

    The cron runner feeds the already-captured stdout/stderr (and the child
    exit code) of a real ``claude -p`` run here, via files to stay clear of
    the Bash 5.3.9 heredoc-stdin deadlock (footgun #11). We reuse the exact
    ``classify_probe`` logic — the same ``QUOTA_LIMIT_MARKERS`` /
    ``"429"`` markers the recovery probe uses — so the reactive cron rotation
    path never forks the marker list. Output is JSON only:
    ``{"status": "quota_limited"|"auth_failed"|"available"|"failed", ...}``.
    """
    def _read(path: str | None) -> str:
        if not path:
            return ""
        try:
            return Path(path).expanduser().read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    stdout = _read(args.stdout_file)
    stderr = _read(args.stderr_file)
    returncode = int(args.returncode)
    status, detail = classify_probe(stdout, stderr, returncode)
    detail["status"] = status
    json_dump(detail)
    return 0


def cmd_mark_quota(args: argparse.Namespace) -> int:
    """#1437 — explicitly force a token to ``quota_limited`` / disabled.

    The reactive cron path rotates FIRST (so ``rotate`` still sees >=2 enabled
    tokens), then must guarantee the vacated quota-hit token does NOT stay
    ``enabled``. ``check --disable-on-quota`` re-probes the network and can be
    inconclusive (timeout / transient error), which would leave the token
    enabled and let the next rotation pick it straight back. This deterministic
    helper disables it without a network probe so the existing recovery sweep
    (``recover-due``) is the only thing that re-enables it once the limit
    resets.
    """
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    reset_at = str(args.reset_at or "")
    retry_seconds = int(args.retry_seconds or 1800)
    try:
        with registry_lock(registry_path):
            registry = load_registry(registry_path)
            row = find_token(registry, args.id)
            if row is None:
                raise ValueError(f"unknown token id: {args.id}")
            timestamp = now_iso()
            row["enabled"] = False
            row["disabled_reason"] = "quota_limited"
            row["last_checked_at"] = timestamp
            row["last_check_status"] = "quota_limited"
            if reset_at:
                row["disabled_until"] = reset_at
                row["next_check_at"] = reset_at
            else:
                row["next_check_at"] = (
                    now_utc() + timedelta(seconds=retry_seconds)
                ).isoformat(timespec="seconds")
            row["updated_at"] = timestamp
            save_registry(registry_path, registry)
    except Exception as exc:
        return fail(str(exc), json_mode)
    active_id = str(registry.get("active_token_id") or "")
    payload = {
        "status": "quota_limited",
        "id": args.id,
        "active_token_id": active_id,
        "reset_at": reset_at,
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"quota_limited: {args.id}")
    return 0


def cmd_recover_due(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    retry_seconds = int(args.retry_seconds or 1800)
    timeout_seconds = int(args.timeout or 45)
    reference = now_utc()
    checked: list[dict[str, Any]] = []
    recovered: list[str] = []
    still_disabled: list[str] = []
    skipped_stale: list[dict[str, str]] = []
    active_id = ""
    # PR #799 r2 codex finding 3 — split into THREE phases:
    #   1. Locked read: snapshot candidates and the active_token_id.
    #   2. Unlocked probes: ``probe_claude_token`` is a 45 s network
    #      op per token; holding the lock across the entire recovery
    #      sweep would freeze every other registry mutation for
    #      minutes when several tokens are due at once.
    #   3. Locked persist: re-read the registry (another mutator may
    #      have run in between), re-match by token id, apply the
    #      probe result, save.
    # If a token has been deleted mid-probe the re-match returns
    # ``None`` and we skip cleanly — no row update, no error.
    #
    # PR #799 r3 codex finding 3 — also snapshot the token fingerprint
    # AND the due-state markers (``disabled_until``, ``next_check_at``).
    # During the locked persist, skip any row whose token value was
    # swapped or whose due-state was updated by a concurrent
    # ``cmd_check`` / ``cmd_add --replace`` / ``cmd_rotate`` while the
    # probe was running. Surface the skip via ``skipped_stale`` so
    # operators reading ``--json`` see what was dropped and why.
    try:
        with registry_lock(registry_path):
            registry = load_registry(registry_path)
            active_id = str(registry.get("active_token_id") or "")
            snapshots: list[dict[str, Any]] = []
            for row in token_rows(registry):
                if not quota_recheck_due(row, reference):
                    continue
                token_id = str(row.get("id") or "")
                token = str(row.get("token") or "")
                if not token_id or not token:
                    continue
                snapshots.append({
                    "id": token_id,
                    "token": token,
                    "fingerprint": token_fingerprint(token),
                    "disabled_until": str(row.get("disabled_until") or ""),
                    "next_check_at": str(row.get("next_check_at") or ""),
                })

        probes: list[tuple[dict[str, Any], dict[str, Any]]] = []
        for snap in snapshots:
            token = snap["token"]
            validate_token(token)
            probe = probe_claude_token(token, timeout_seconds)
            probes.append((snap, probe))

        if probes:
            with registry_lock(registry_path):
                registry = load_registry(registry_path)
                active_id = str(registry.get("active_token_id") or "")
                for snap, probe in probes:
                    token_id = snap["id"]
                    row = find_token(registry, token_id)
                    if row is None:
                        # Token was deleted between the probe and the
                        # persist phase — drop it from the report.
                        skipped_stale.append({"id": token_id, "reason": "row_deleted"})
                        continue
                    current_token = str(row.get("token") or "")
                    current_fingerprint = (
                        token_fingerprint(current_token) if current_token else ""
                    )
                    if current_fingerprint != snap["fingerprint"]:
                        # Token VALUE was replaced — stale probe.
                        skipped_stale.append({"id": token_id, "reason": "token_replaced"})
                        continue
                    if str(row.get("disabled_until") or "") != snap["disabled_until"]:
                        # Due-state changed (another check/recovery
                        # already updated this row) — stale probe.
                        skipped_stale.append({"id": token_id, "reason": "disabled_until_changed"})
                        continue
                    if str(row.get("next_check_at") or "") != snap["next_check_at"]:
                        skipped_stale.append({"id": token_id, "reason": "next_check_at_changed"})
                        continue
                    update_row_from_probe(
                        row,
                        probe,
                        enable_on_ok=True,
                        disable_on_quota=True,
                        retry_seconds=retry_seconds,
                    )
                    status = str(probe.get("status") or "failed")
                    reset_at = str(probe.get("reset_at") or "")
                    checked.append(
                        {
                            "id": token_id,
                            "status": status,
                            "api_error_status": str(probe.get("api_error_status") or ""),
                            "reset_at": reset_at,
                            "enabled": bool(row.get("enabled", True)),
                        }
                    )
                    if status == "available" and bool(row.get("enabled", True)):
                        recovered.append(token_id)
                    elif not bool(row.get("enabled", True)):
                        still_disabled.append(token_id)
                if checked:
                    registry["last_recovery_check"] = {
                        "checked_at": now_iso(),
                        "checked_count": len(checked),
                        "recovered_count": len(recovered),
                    }
                    save_registry(registry_path, registry)
    except Exception as exc:
        return fail(str(exc), json_mode)

    reason = ""
    if checked:
        status = "ok"
    else:
        status = "skipped"
        reason = "all_skipped_stale" if skipped_stale else "no_due_tokens"
    payload = {
        "status": status,
        "reason": reason,
        "active_token_id": active_id,
        "checked_count": len(checked),
        "recovered_count": len(recovered),
        "still_disabled_count": len(still_disabled),
        "recovered": recovered,
        "checked": checked,
        "sync_recommended": active_id in recovered,
        # PR #799 r3 codex finding 3 — backwards-compatible addition.
        # Empty list when nothing was discarded; populated entries
        # carry {"id": ..., "reason": ...}. The daemon caller in
        # bridge-daemon.sh ignores this field; operators reading
        # ``--json`` get the diagnostic.
        "skipped_stale": skipped_stale,
    }
    if json_mode:
        json_dump(payload)
    else:
        if checked:
            print(f"checked={len(checked)} recovered={len(recovered)} still_disabled={len(still_disabled)}")
        else:
            print(f"skipped: {reason}")
    return 0


def cmd_auto_rotate(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    # PR #799 r2 codex finding 3 — ``status`` is a pure read and stays
    # outside the lock. ``enable`` and ``disable`` mutate the registry
    # and need the lock around their load->mutate->save.
    try:
        if args.action in ("enable", "disable"):
            with registry_lock(registry_path):
                registry = load_registry(registry_path)
                if args.action == "enable":
                    registry["auto_rotate_enabled"] = True
                    if args.threshold is not None:
                        registry["rotation_threshold"] = validate_threshold(args.threshold)
                else:
                    registry["auto_rotate_enabled"] = False
                save_registry(registry_path, registry)
        elif args.action == "status":
            registry = load_registry(registry_path)
        else:
            raise ValueError(f"unsupported auto-rotate action: {args.action}")
    except Exception as exc:
        return fail(str(exc), json_mode)
    payload = {
        "status": "ok",
        "auto_rotate_enabled": bool(registry.get("auto_rotate_enabled", False)),
        "rotation_threshold": float(registry.get("rotation_threshold") or 99.0),
        "active_token_id": registry.get("active_token_id") or "",
        "enabled_token_count": len(enabled_token_ids(registry)),
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"auto_rotate_enabled: {'yes' if payload['auto_rotate_enabled'] else 'no'}")
        print(f"rotation_threshold: {payload['rotation_threshold']:.0f}%")
        print(f"enabled_token_count: {payload['enabled_token_count']}")
    return 0


def _ensure_claude_dir_safe(path: Path, allowed_root: Path | None) -> None:
    """Verify ``path``'s parent is a real directory inside ``allowed_root``.

    The credential parent directory (``~/.claude/`` in the isolated home) is
    owned by the agent UID, so an attacker that controls the agent can plant
    a symlink to anywhere on disk and trick a root-run ``os.replace`` into
    clobbering the symlink target. This helper rejects any non-real directory
    before any privileged write happens.

    Raises ``PermissionError`` if:
      - the parent exists and is a symlink, or
      - the parent exists and is not a directory, or
      - the parent's resolved real path is not inside ``allowed_root``.

    Does NOT create the directory — callers decide whether to ``mkdir`` it,
    and creating directly via ``os.mkdir`` (not ``mkdir -p`` shell expansion)
    avoids walking through agent-controlled symlink chains.

    Passing ``allowed_root=None`` disables the root-prefix check entirely; the
    helper still rejects symlinks and non-directories at the parent. That mode
    is intended for non-isolated dev installs where the credential dir lives
    inside the controller's own home and is not agent-controlled.
    """
    parent = path.parent
    try:
        st = os.lstat(str(parent))
    except FileNotFoundError:
        # Parent does not exist yet; safe — the caller will mkdir it.
        return
    if stat.S_ISLNK(st.st_mode):
        raise PermissionError(
            f"refusing to write through symlinked credential dir: {parent}"
        )
    if not stat.S_ISDIR(st.st_mode):
        raise PermissionError(f"credential dir is not a directory: {parent}")
    if allowed_root is None:
        return
    try:
        resolved = parent.resolve(strict=True)
        allowed = allowed_root.resolve(strict=True)
    except FileNotFoundError as exc:
        raise PermissionError(
            f"cannot resolve credential dir or allowed root: {exc}"
        ) from exc
    resolved_str = str(resolved)
    allowed_str = str(allowed)
    if resolved != allowed and not resolved_str.startswith(allowed_str + os.sep):
        raise PermissionError(
            f"credential dir resolves outside isolated home: {resolved} not under {allowed}"
        )


def write_claude_credentials_file(
    path: Path,
    token: str,
    *,
    owner_uid: int | None = None,
    owner_gid: int | None = None,
    allowed_root: Path | None = None,
) -> None:
    _ensure_claude_dir_safe(path, allowed_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(claude_oauth_credentials_payload(token), ensure_ascii=True, indent=2) + "\n"
    write_private_file_atomic(
        path,
        text,
        mode=0o600,
        prefix=".credentials.",
        owner_uid=owner_uid,
        owner_gid=owner_gid,
    )


def write_claude_credentials_payload(
    path: Path,
    payload: dict[str, Any],
    *,
    owner_uid: int | None = None,
    owner_gid: int | None = None,
    allowed_root: Path | None = None,
) -> None:
    """Write a pre-parsed Claude OAuth credential payload to ``path``.

    Used by the controller-credentials fallback in ``cmd_sync_agent`` so
    fields like ``refreshToken`` carried by a real ``claude.ai`` login
    survive the copy into the per-agent ``CLAUDE_CONFIG_DIR``. The
    token-based path ``write_claude_credentials_file`` synthesizes a
    minimal payload from a setup-token string; this helper preserves
    whatever the controller already has.
    """
    _ensure_claude_dir_safe(path, allowed_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload, ensure_ascii=True, indent=2) + "\n"
    write_private_file_atomic(
        path,
        text,
        mode=0o600,
        prefix=".credentials.",
        owner_uid=owner_uid,
        owner_gid=owner_gid,
    )


# #1261 (v0.15.0-beta4): minimum remaining lifetime, in milliseconds,
# under which the controller-credentials fallback refuses to propagate
# the token. Claude CLI lazily refreshes the controller credentials —
# only when the controller itself makes an API call. If the daemon
# propagates a token within 5 minutes of expiry, agents inherit it,
# start running, and 401 a few minutes later. 30 minutes is a balance
# between "long enough that the operator can do something about it"
# and "short enough that the propagation isn't blocked unnecessarily".
# Operators can override via ``BRIDGE_CONTROLLER_CRED_MIN_TTL_MS`` for
# CI / test fixtures.
CONTROLLER_CRED_MIN_TTL_MS = 30 * 60 * 1000  # 30 minutes


def _controller_credentials_min_ttl_ms() -> int:
    raw = os.environ.get("BRIDGE_CONTROLLER_CRED_MIN_TTL_MS", "").strip()
    if not raw:
        return CONTROLLER_CRED_MIN_TTL_MS
    try:
        value = int(raw)
    except ValueError:
        return CONTROLLER_CRED_MIN_TTL_MS
    return value if value >= 0 else CONTROLLER_CRED_MIN_TTL_MS


def controller_credentials_aliveness(
    payload: dict[str, Any],
    *,
    now_ms: int | None = None,
) -> tuple[str, int]:
    """Return ``(status, remaining_ms)`` for the controller token.

    Status values (codex r1 SHOULD-FIX 2026-05-27: standardized to
    underscore-JSON-friendly tokens — the previous ``alive`` / ``near-expiry``
    / ``no-expires-at`` shape was a mix of literals that did not round-trip
    cleanly through structured consumers and disagreed with the lane brief.
    The new tokens use underscores so JSON callers + jq pipelines can name
    fields without quoting; ``fresh`` is also semantically clearer than
    ``alive`` for a credential whose state is "valid AND has comfortable
    headroom"):

      - ``"fresh"``           — ``expiresAt`` is in the future by at least
                                ``_controller_credentials_min_ttl_ms()``.
                                Propagation is safe.
      - ``"expired"``         — ``expiresAt`` is at or before ``now_ms``.
                                The token will 401 the moment any agent
                                tries to use it.
      - ``"near_expiry"``     — ``expiresAt`` is in the future but within
                                the minimum-TTL window. Propagating it is
                                a single-point-of-failure: agents will all
                                401 within the remaining lifetime.
      - ``"no_expires_at"``   — payload lacks an ``expiresAt`` field. We
                                cannot prove aliveness, so we defer to
                                the caller's policy (currently: propagate
                                with a warning — Claude CLI's own format
                                always carries expiresAt today, so this
                                branch is a backstop, not the common path).

    Issue #1261: this is the daemon-side aliveness gate the
    controller-credentials fallback was missing. Claude CLI refreshes the
    controller token LAZILY (only when the controller itself makes an API
    call). On hosts where the operator's day-to-day work happens INSIDE
    agents (the typical agent-bridge deployment), the controller is idle
    and its token expires unnoticed. The daemon's periodic sync then
    propagated the stale token to every agent, and all agents 401'd at
    once after a single idle window.
    """
    if now_ms is None:
        now_ms = int(time.time() * 1000)
    oauth = payload.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        return ("no_expires_at", 0)
    expires_raw = oauth.get("expiresAt")
    if expires_raw is None:
        return ("no_expires_at", 0)
    try:
        expires_at_ms = int(expires_raw)
    except (TypeError, ValueError):
        return ("no_expires_at", 0)
    remaining_ms = expires_at_ms - now_ms
    if remaining_ms <= 0:
        return ("expired", remaining_ms)
    if remaining_ms < _controller_credentials_min_ttl_ms():
        return ("near_expiry", remaining_ms)
    return ("fresh", remaining_ms)


def read_controller_claude_credentials_payload(path: Path) -> dict[str, Any]:
    """Read and validate the controller's ``~/.claude/.credentials.json``.

    Returns the parsed JSON payload (a dict containing at least
    ``claudeAiOauth.accessToken``). Raises ``ValueError`` /
    ``FileNotFoundError`` / ``PermissionError`` on the obvious problems so
    ``cmd_sync_agent`` can surface a clean failure to the caller.

    Used by the #1075 fallback when no Claude setup-token is registered:
    the operator is logged in via ``claude.ai`` OAuth (Max subscription)
    and per-agent ``CLAUDE_CONFIG_DIR`` dirs need credentials seeded from
    that login so channel agents do not start up ``Not logged in``.
    """
    if path.is_symlink():
        raise PermissionError(
            f"refusing to read symlinked controller credentials: {path}"
        )
    # Codex r1 BLOCKING / r2 over-reject: the file-level symlink check
    # is bypassable via a symlinked `.claude` parent (parent-swap). The
    # r2 ancestor-walk-to-$HOME over-rejected legitimate paths under
    # symlinked system roots (e.g. macOS /var/folders/... test temp paths
    # where /var is itself a symlink) — `Path.home()` is the wrong
    # boundary when the controller home is an explicit override
    # (BRIDGE_CONTROLLER_HOME / sudo / test). Check ONLY the immediate
    # `.claude` parent (the swap vector); anything beyond that is the
    # caller's responsibility — the caller (bridge-auth.sh) already
    # resolved + validated the controller home root.
    if path.parent.is_symlink():
        raise PermissionError(
            f"refusing to read controller credentials under symlinked "
            f"parent: {path.parent}"
        )
    if not path.is_file():
        raise FileNotFoundError(f"controller credentials not found: {path}")
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"controller credentials file is not valid JSON: {path}: {exc}"
        ) from exc
    if not isinstance(parsed, dict):
        raise ValueError(
            f"controller credentials file must contain a JSON object: {path}"
        )
    oauth = parsed.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        raise ValueError(
            f"controller credentials missing 'claudeAiOauth' object: {path}"
        )
    access_token = oauth.get("accessToken")
    if not isinstance(access_token, str) or not access_token.strip():
        raise ValueError(
            f"controller credentials missing 'claudeAiOauth.accessToken': {path}"
        )
    return parsed


def resolve_controller_claude_credentials_path(
    explicit: str | os.PathLike[str] | None = None,
) -> Path:
    """Resolve the controller's ``~/.claude/.credentials.json`` path.

    Precedence:
      1. The ``explicit`` argument (passed in via ``--controller-credentials``
         from ``bridge-auth.sh``, which resolves the controller user the same
         way ``bridge_isolation_v2_controller_user`` does).
      2. ``$BRIDGE_CONTROLLER_HOME/.claude/.credentials.json`` when set.
      3. ``$SUDO_USER``'s home (when running under sudo for isolated agents).
      4. ``Path.home() / '.claude' / '.credentials.json'`` as the final fallback.
    """
    if explicit:
        return Path(os.fspath(explicit)).expanduser()
    explicit_home = os.environ.get("BRIDGE_CONTROLLER_HOME", "").strip()
    if explicit_home:
        return Path(explicit_home).expanduser() / ".claude" / ".credentials.json"
    sudo_user = os.environ.get("SUDO_USER", "").strip()
    if sudo_user:
        try:
            entry = pwd.getpwnam(sudo_user)
            return Path(entry.pw_dir) / ".claude" / ".credentials.json"
        except KeyError:
            pass
    return Path.home() / ".claude" / ".credentials.json"


def write_private_file_atomic(
    path: Path,
    text: str,
    *,
    mode: int = 0o600,
    prefix: str = ".tmp.",
    owner_uid: int | None = None,
    owner_gid: int | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = -1
    tmp_name = ""
    try:
        fd, tmp_name = tempfile.mkstemp(prefix=prefix, suffix=".tmp", dir=str(path.parent))
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fd = -1
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_name, mode)
        # PR #799 r2 codex finding 3 — chown the tempfile to the target UID
        # BEFORE ``os.replace`` so the credential file is never root-owned at
        # its final path. Avoids the window where Claude can't read its own
        # credential because the post-sync ``chown`` repair has not run yet.
        if owner_uid is not None:
            gid = owner_gid if owner_gid is not None else -1
            os.chown(tmp_name, owner_uid, gid)
        os.replace(tmp_name, path)
        # r5 codex r4: removed redundant post-replace `os.chmod(path, mode)`.
        # The tempfile was chmodded to `mode` at the line above before replace,
        # and `os.replace` is `rename(2)` which preserves mode bits via
        # inode rename. The post-replace chmod was defensive redundancy
        # and the only remaining final-path TOCTOU surface in
        # write_private_file_atomic.
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass


# macOS F_GETPATH fcntl constant (defined in <sys/fcntl.h> as 50). The `fcntl`
# module only exposes it as `fcntl.F_GETPATH` on Darwin builds; fall back to the
# numeric constant so the lookup is robust across CPython builds.
_DARWIN_F_GETPATH = getattr(fcntl, "F_GETPATH", 50)


def _dir_fd_real_path(dir_fd: int) -> str:
    """Resolve the real filesystem path of an OPEN directory fd — by IDENTITY.

    codex Phase-4 BLOCKING: the allowed-root containment check MUST be made
    against the identity of the fd that was actually opened (and that the
    subsequent dir_fd-relative write USES), NOT a re-resolution of the string
    path. A live parent-swap (rename the opened ``.codex`` outside the root,
    drop an in-root decoy) defeats any string re-resolution but cannot fool the
    fd's own identity.

    Per platform:
      * Linux  → ``os.readlink('/proc/self/fd/<n>')``.
      * Darwin → ``fcntl.fcntl(dir_fd, F_GETPATH)`` (the kernel returns the
                 fd's current real path into the buffer).
    If NEITHER is available, raise ``PermissionError`` — FAIL CLOSED. We never
    fall back to ``parent.resolve()`` / a string re-resolution, which is exactly
    the hole codex found on non-procfs hosts.
    """
    # Linux procfs first (cheap, no buffer dance).
    proc_link = f"/proc/self/fd/{dir_fd}"
    if os.path.exists(proc_link):  # noqa: raw-pathlib-controller-only - controller-side procfs fd-identity probe
        try:
            return os.readlink(proc_link)  # noqa: raw-pathlib-controller-only - controller-side fd-identity realpath via procfs
        except OSError:
            pass
    # Darwin / BSD F_GETPATH: the kernel writes the fd's real path into the
    # buffer. fcntl.fcntl with an int arg returns the (possibly mutated) int on
    # most platforms, so use a bytes buffer arg form which returns the buffer.
    if platform.system() == "Darwin":
        try:
            buf = bytes(1024)  # PATH_MAX-ish; F_GETPATH writes a NUL-terminated path
            ret = fcntl.fcntl(dir_fd, _DARWIN_F_GETPATH, buf)
            # When passed a bytes buffer, fcntl returns the buffer's bytes.
            if isinstance(ret, (bytes, bytearray)):
                return ret.split(b"\x00", 1)[0].decode("utf-8", "surrogateescape")
        except (OSError, ValueError):
            pass
    # Neither fd-identity API worked → fail closed (no string fallback).
    raise PermissionError(
        "cannot resolve the opened directory fd's real identity on this platform "
        "(no /proc/self/fd and no F_GETPATH) — refusing the privileged write "
        "rather than re-resolving a swappable string path"
    )


def write_private_file_atomic_dirfd(
    path: Path,
    text: str,
    *,
    mode: int = 0o600,
    prefix: str = ".tmp.",
    owner_uid: int | None = None,
    owner_gid: int | None = None,
    allowed_root: Path | None = None,
) -> None:
    """TOCTOU-hardened atomic private write (codex r2 BLOCKING).

    ``write_private_file_atomic`` re-opens ``path.parent`` by STRING for
    ``mkstemp`` / ``os.replace``. A live agent that swaps ``.codex`` AFTER a
    pre-check but BEFORE that string re-open can still redirect the
    privileged write out of the allowed root (a live parent-swap TOCTOU,
    distinct from the pre-placed-symlink case). This variant pins the parent
    by a single fd opened ``O_DIRECTORY|O_NOFOLLOW`` and does ALL filesystem
    ops (create tempfile, fsync, chmod, chown, rename) relative to that fd via
    ``dir_fd=`` — so the directory the writer USES is byte-for-byte the
    directory it CHECKED, with no second path resolution in between.

    - ``O_NOFOLLOW`` makes the open FAIL if the final component (``.codex``)
      is a symlink — closing the symlinked-parent case at open time.
    - When ``allowed_root`` is given, the OPENED FD's real IDENTITY
      (``/proc/self/fd/<n>`` on Linux, ``F_GETPATH`` on Darwin) is verified to
      stay inside ``allowed_root`` BEFORE any write — never a re-resolution of
      the string path (codex Phase-4 BLOCKING: a live parent-swap defeats a
      string re-resolution but not the fd's own identity). On a platform with
      NEITHER fd-identity API, the write FAILS CLOSED.
    - The parent dir is NOT created here (the bash layer / iso prepare creates
      it owner-correct first); a missing parent fails loud rather than racing a
      mkdir through a swappable path.
    """
    parent = path.parent
    name = path.name
    dir_fd = -1
    fd = -1
    tmp_name = ""
    try:
        try:
            dir_fd = os.open(
                str(parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            )
        except OSError as exc:
            raise PermissionError(
                f"refusing to open Codex dest parent {parent} "
                f"(O_DIRECTORY|O_NOFOLLOW failed — symlinked/missing parent?): {exc}"
            ) from exc
        # Verify the OPENED directory is inside the allowed root BY THE FD's OWN
        # IDENTITY (not a string re-resolution). A live parent-swap — rename the
        # opened `.codex` outside the root, drop an in-root decoy — would pass a
        # string-path check but the fd still points at the moved-out directory,
        # so `_dir_fd_real_path` returns the escaped path and the prefix check
        # rejects it. On a non-procfs / non-Darwin host the resolver raises and
        # we fail closed.
        if allowed_root is not None:
            real_parent = _dir_fd_real_path(dir_fd)
            try:
                allowed = str(allowed_root.resolve(strict=True))
            except OSError as exc:
                raise PermissionError(
                    f"cannot resolve allowed root {allowed_root}: {exc}"
                ) from exc
            if real_parent != allowed and not real_parent.startswith(allowed + os.sep):
                raise PermissionError(
                    f"Codex dest parent resolves outside allowed root: "
                    f"{real_parent} not under {allowed}"
                )
        # All ops below are relative to the pinned dir_fd — no second path
        # resolution, so the checked dir IS the used dir. mkstemp does not
        # accept dir_fd, so create the tempfile manually relative to dir_fd
        # with O_CREAT|O_EXCL|O_NOFOLLOW (uuid name avoids a predictable path).
        tmp_name = f"{prefix}{uuid.uuid4().hex}.tmp"
        fd = os.open(
            tmp_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            mode,
            dir_fd=dir_fd,
        )
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fd = -1
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        # chmod/chown the tempfile by name relative to dir_fd (BEFORE rename),
        # so the credential is never world-readable or root-owned at its final
        # path. follow_symlinks=False so a raced symlink at tmp_name is not
        # followed.
        os.chmod(tmp_name, mode, dir_fd=dir_fd, follow_symlinks=False)
        if owner_uid is not None:
            gid = owner_gid if owner_gid is not None else -1
            os.chown(
                tmp_name, owner_uid, gid, dir_fd=dir_fd, follow_symlinks=False
            )
        # Atomic rename within the pinned directory.
        os.replace(tmp_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        tmp_name = ""  # replaced; nothing to clean up
    finally:
        if fd >= 0:
            os.close(fd)
        if tmp_name:
            try:
                os.unlink(tmp_name, dir_fd=dir_fd)  # noqa: raw-pathlib-controller-only - controller-side dir_fd-relative tempfile cleanup
            except (FileNotFoundError, OSError):
                pass
        if dir_fd >= 0:
            os.close(dir_fd)


# ─────────────────────────────────────────────────────────────────────
# Credential-generation state (Q4 groundwork, #1469 enabler, #1470 P1).
#
# A later #1469 set-scoped re-wake must answer "which agents were running
# under the credential generation a rotation just vacated?" The queue /
# daemon state record no such field today, so Phase 1 lays the schema +
# a stamp-at-sync hook; it does NOT wire the full re-wake yet.
#
# The store is a single JSON document mapping agent → a small record:
#   {
#     "version": 1,
#     "agents": {
#       "<agent>": {
#         "engine":        "claude",        # which engine descriptor row
#         "source_digest": "<sha256-hex>",  # one-way digest of the synced
#                                           #   credential material (NEVER
#                                           #   the secret itself)
#         "cred_generation": 7,             # monotone per-agent counter,
#                                           #   bumps only when the digest
#                                           #   changes (idempotent re-sync
#                                           #   does NOT bump)
#         "synced_at":      "<iso8601>"
#       }
#     }
#   }
#
# Design constraints honored:
#   * idempotent migration — load tolerates a missing / legacy / corrupt
#     file by returning a fresh default; it never raises on read.
#   * fail-closed write — the writer routes through
#     ``write_private_file_atomic`` (0600, atomic replace, chown-before-
#     replace) so a partial write can never leave a half-written or
#     world-readable state file. A write failure propagates (caller
#     decides), it is never silently swallowed.
#   * one-way digest only — the recorded ``source_digest`` is a SHA-256
#     of the credential material; the secret is never written to state.
CRED_STATE_VERSION = 1


def cred_state_path() -> Path:
    """Resolve the per-agent credential-generation state file path.

    Precedence mirrors the rest of the auth stack's state resolution:
      1. ``$BRIDGE_AUTH_CRED_STATE_FILE`` (explicit override, tests).
      2. ``$BRIDGE_STATE_DIR/auth/cred-state.json``.
      3. ``$BRIDGE_HOME/state/auth/cred-state.json``.
      4. ``./state/auth/cred-state.json`` (last-resort cwd-relative; only
         reached when neither env var is set, e.g. a bare unit test).
    """
    explicit = os.environ.get("BRIDGE_AUTH_CRED_STATE_FILE", "").strip()  # noqa: iso-helper-boundary - controller cred-state override
    if explicit:
        return Path(explicit).expanduser()
    state_dir = os.environ.get("BRIDGE_STATE_DIR", "").strip()  # noqa: iso-helper-boundary - controller state dir
    if state_dir:
        return Path(state_dir).expanduser() / "auth" / "cred-state.json"
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()  # noqa: iso-helper-boundary - controller bridge home fallback
    if bridge_home:
        return Path(bridge_home).expanduser() / "state" / "auth" / "cred-state.json"
    return Path("state") / "auth" / "cred-state.json"


def default_cred_state() -> dict[str, Any]:
    return {"version": CRED_STATE_VERSION, "agents": {}}


def load_cred_state(path: Path) -> dict[str, Any]:
    """Load the cred-state document, tolerating absence / corruption.

    Idempotent migration: an unreadable, non-JSON, wrong-shape, or
    legacy file degrades to a fresh default rather than raising. This is
    the read side of the fail-closed contract — a corrupt state file must
    never block a credential sync (the sync is the source of truth; the
    state is a derived stamp).
    """
    if not path.exists():  # noqa: raw-pathlib-controller-only - controller cred-state probe
        return default_cred_state()
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default_cred_state()
    if not isinstance(parsed, dict):
        return default_cred_state()
    agents = parsed.get("agents")
    if not isinstance(agents, dict):
        agents = {}
    # Normalize: drop any non-dict per-agent rows defensively so a later
    # consumer can rely on the shape without re-validating each field.
    normalized: dict[str, Any] = {}
    for name, row in agents.items():
        if isinstance(row, dict):
            normalized[str(name)] = row
    return {"version": CRED_STATE_VERSION, "agents": normalized}


def save_cred_state(
    path: Path,
    payload: dict[str, Any],
    *,
    owner_uid: int | None = None,
    owner_gid: int | None = None,
) -> None:
    """Persist the cred-state document fail-closed (atomic, 0600).

    Routes through ``write_private_file_atomic`` so the state file lands
    at mode 0600 via an atomic ``os.replace`` (chown-before-replace when
    an owner is supplied). A write error propagates — the stamp is
    best-effort at the *call site* (see ``stamp_cred_generation``), but
    the primitive itself never leaves a partial / world-readable file.
    """
    text = json.dumps(payload, ensure_ascii=True, indent=2) + "\n"
    write_private_file_atomic(
        path,
        text,
        mode=0o600,
        prefix=".cred-state.",
        owner_uid=owner_uid,
        owner_gid=owner_gid,
    )


def cred_source_digest(material: str) -> str:
    """One-way digest of credential material for generation tracking.

    SHA-256 hex — the same family as ``token_fingerprint`` but full-width
    so two distinct credentials never collide on the truncated prefix.
    The secret is NEVER recorded; only this digest is.
    """
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def stamp_cred_generation(
    agent: str,
    engine: str,
    source_material: str,
    *,
    state_path: Path | None = None,
    owner_uid: int | None = None,
    owner_gid: int | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Record the credential generation for ``agent`` at sync time.

    Idempotent: the per-agent ``cred_generation`` counter bumps ONLY when
    the ``source_digest`` changes. A re-sync of the same credential
    leaves the generation untouched (so a no-op periodic sync does not
    inflate the counter and spuriously look like a rotation to #1469).

    Returns the per-agent record that was written (or the unchanged
    existing one). Fail-closed at the boundary: a write failure raises so
    the caller can decide — ``cmd_sync_agent`` treats the stamp as
    best-effort and never lets a stamp failure abort an otherwise
    successful credential sync.
    """
    path = state_path if state_path is not None else cred_state_path()
    when = (now or now_utc()).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    digest = cred_source_digest(source_material)
    state = load_cred_state(path)
    agents = state["agents"]
    existing = agents.get(agent)
    prev_gen = 0
    prev_digest = ""
    if isinstance(existing, dict):
        try:
            prev_gen = int(existing.get("cred_generation", 0) or 0)
        except (TypeError, ValueError):
            prev_gen = 0
        prev_digest = str(existing.get("source_digest", "") or "")
    if prev_digest == digest and prev_gen > 0:
        # Idempotent re-sync: digest unchanged → do not bump, do not
        # rewrite. Refresh synced_at only would churn the file on every
        # periodic tick; we keep the record stable so the digest is the
        # sole rotation signal.
        return existing if isinstance(existing, dict) else {}
    generation = prev_gen + 1
    record = {
        "engine": engine,
        "source_digest": digest,
        "cred_generation": generation,
        "synced_at": when,
    }
    agents[agent] = record
    save_cred_state(path, state, owner_uid=owner_uid, owner_gid=owner_gid)
    return record


# ─────────────────────────────────────────────────────────────────────
# Codex fleet-sync adapter (#1470 Phase 2, #1467).
#
# Codex auth is a SINGLE subscription `auth.json` the `codex` binary
# self-refreshes in place — there is nothing to rotate. The adapter is
# therefore `register` (point at a source agent) / `sync` (write-through
# the source auth.json to every managed Codex agent home) / `verify`
# (offline well-formedness). `rotate`/`recover`/`activate` are clean
# no-ops (the descriptor's supports_rotation=False).
#
# Security contracts (codex-agreed, fleet-credential-design.md §6/§7):
#   * Source binding (Q1): the source agent is persisted here in a
#     protected 0600 state file, NOT hardcoded and NOT env-overridable.
#     The bash layer validates it is an existing, non-stopped Codex
#     agent before calling register; this module stores the validated
#     name.
#   * Refresh detection (Q2): the source auth.json is read as an atomic
#     snapshot, validated as well-formed JSON, and a content digest is
#     computed. The sync propagates ONLY when the digest changes vs the
#     dest's recorded generation (the Phase-1 cred-generation store).
#   * Aliveness (Q3): OFFLINE well-formedness / expiry / path checks
#     only. There is NO side-effect-free live Codex probe; this module
#     never shells out to `codex`.
#   * Delivery (§6.6): write-through copy via write_private_file_atomic
#     (chown-before-replace, 0600), NEVER a symlink. The iso published
#     write preserves owner agent-bridge-<a>:ab-agent-<a> mode 0600.
#   * Rollback (Q-extra): a same-owner/same-mode last-known-good auth.json
#     is kept keyed by source-digest; on a failed write the dest is
#     restored from it — but only if that backup is itself well-formed
#     and not from a different/expired source.
#   * No cross-engine misdelivery (§8): the codex sync path NEVER writes
#     a Claude credential; the engine is fail-closed-gated to `codex`.
CODEX_SOURCE_BINDING_VERSION = 1
# The opaque whole-file copy must still be RECOGNIZABLY a Codex auth.json
# before we fan it out — a malformed / wrong-shape file fails loud and is
# never propagated. Codex 0.135.0 writes a top-level JSON object whose
# subscription material lives under `tokens` (access/refresh/id token) or,
# for the API-key login, an `OPENAI_API_KEY` field. We accept either shape
# but require a JSON object with at least one recognized credential key.
CODEX_AUTH_TOKENS_KEY = "tokens"
CODEX_AUTH_APIKEY_KEY = "OPENAI_API_KEY"


def codex_source_binding_path() -> Path:
    """Resolve the protected Codex source-binding state file path.

    Q1 (codex r1 BLOCKING): the selected source Codex agent is persisted in
    protected state (mode 0600) and the binding is **NOT env-overridable** —
    there is deliberately NO dedicated `BRIDGE_AUTH_CODEX_SOURCE_FILE`
    file-level override (an earlier draft had one; codex flagged it as a
    way for caller env to select alternate protected state). The path is
    derived ONLY from the runtime root the whole auth stack already trusts:
      1. ``$BRIDGE_STATE_DIR/auth/codex-source.json``.
      2. ``$BRIDGE_HOME/state/auth/codex-source.json``.
      3. ``./state/auth/codex-source.json`` (last-resort, bare unit test).
    A test points `BRIDGE_STATE_DIR`/`BRIDGE_HOME` at a temp root (the same
    way every other state file is redirected); it cannot redirect the
    binding file independently of the rest of the runtime state.
    """
    state_dir = os.environ.get("BRIDGE_STATE_DIR", "").strip()  # noqa: iso-helper-boundary - controller state dir
    if state_dir:
        return Path(state_dir).expanduser() / "auth" / "codex-source.json"
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()  # noqa: iso-helper-boundary - controller bridge home fallback
    if bridge_home:
        return Path(bridge_home).expanduser() / "state" / "auth" / "codex-source.json"
    return Path("state") / "auth" / "codex-source.json"


def load_codex_source_binding(path: Path | None = None) -> dict[str, Any]:
    """Load the persisted Codex source-agent binding, tolerating absence.

    Returns ``{"version": 1, "source_agent": "<name>"|""}``. A missing /
    corrupt / wrong-shape file degrades to an empty binding rather than
    raising — the caller treats an empty source as "not configured" and
    fails loud at sync time.
    """
    p = path if path is not None else codex_source_binding_path()
    default = {"version": CODEX_SOURCE_BINDING_VERSION, "source_agent": ""}
    if not p.exists():  # noqa: raw-pathlib-controller-only - controller codex source binding probe
        return default
    try:
        parsed = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return default
    if not isinstance(parsed, dict):
        return default
    source = parsed.get("source_agent")
    if not isinstance(source, str):
        source = ""
    return {"version": CODEX_SOURCE_BINDING_VERSION, "source_agent": source.strip()}


def save_codex_source_binding(
    source_agent: str,
    *,
    path: Path | None = None,
) -> None:
    """Persist the validated Codex source-agent binding fail-closed (0600).

    The bash layer has already validated ``source_agent`` is an existing,
    non-stopped Codex agent before calling here — this writer only stamps
    the protected state. Routed through ``write_private_file_atomic`` so
    the binding never lands world-readable or half-written.
    """
    p = path if path is not None else codex_source_binding_path()
    payload = {
        "version": CODEX_SOURCE_BINDING_VERSION,
        "source_agent": source_agent.strip(),
        "registered_at": now_iso(),
    }
    text = json.dumps(payload, ensure_ascii=True, indent=2) + "\n"
    write_private_file_atomic(p, text, mode=0o600, prefix=".codex-source.")


def codex_auth_wellformed(payload: Any) -> tuple[bool, str]:
    """Offline well-formedness gate for a Codex auth.json payload (Q3).

    Returns ``(ok, reason)``. ``ok`` is True only when ``payload`` is a
    JSON object carrying at least one recognized Codex credential key
    (``tokens`` subscription object or an ``OPENAI_API_KEY`` string). No
    network, no `codex` subprocess — Codex L4 is intentionally weaker
    than Claude (there is no side-effect-free live probe).
    """
    if not isinstance(payload, dict):
        return (False, "auth.json is not a JSON object")
    tokens = payload.get(CODEX_AUTH_TOKENS_KEY)
    apikey = payload.get(CODEX_AUTH_APIKEY_KEY)
    has_tokens = isinstance(tokens, dict) and bool(tokens)
    has_apikey = isinstance(apikey, str) and bool(apikey.strip())
    if not (has_tokens or has_apikey):
        return (
            False,
            "auth.json missing a recognized Codex credential "
            f"({CODEX_AUTH_TOKENS_KEY!r} object or {CODEX_AUTH_APIKEY_KEY!r})",
        )
    return (True, "")


def read_codex_auth_snapshot(path: Path) -> tuple[str, dict[str, Any], str]:
    """Read + validate the source Codex auth.json as an atomic snapshot (Q2).

    Returns ``(raw_text, parsed, digest)``. Raises ``ValueError`` on any
    of: unreadable file, non-JSON, malformed/unrecognized shape. The
    digest is a one-way SHA-256 over the RAW file bytes (so a refresh the
    `codex` binary writes in place is detected the moment a single byte
    changes). Invalid / unstable reads fail loud here — the caller never
    propagates a credential it could not validate.

    No advisory lock is taken against the `codex` binary (it will not
    take one). A single ``read_text`` is the atomic snapshot; the digest
    over the exact bytes read guards against a torn write being fanned
    out (a torn write fails JSON parse → ValueError → no propagation).
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise ValueError(f"source Codex auth.json not found: {path}") from exc
    except OSError as exc:
        raise ValueError(f"source Codex auth.json unreadable: {path}: {exc}") from exc
    try:
        parsed = json.loads(raw)
    except Exception as exc:
        raise ValueError(
            f"source Codex auth.json is not valid JSON ({path}): {exc}"
        ) from exc
    ok, reason = codex_auth_wellformed(parsed)
    if not ok:
        raise ValueError(f"source Codex auth.json rejected ({path}): {reason}")
    digest = cred_source_digest(raw)
    return (raw, parsed, digest)


def codex_dest_generation_digest(agent: str, *, state_path: Path | None = None) -> str:
    """Return the source_digest recorded for ``agent`` in the cred-state.

    Empty string when the agent has no Codex record yet (first sync) or
    the recorded engine is not codex. Used by the digest gate so an
    idempotent re-sync of the same source auth.json is a NO-OP (the
    generation is not bumped and the dest is not rewritten).
    """
    path = state_path if state_path is not None else cred_state_path()
    state = load_cred_state(path)
    row = state["agents"].get(agent)
    if not isinstance(row, dict):
        return ""
    if str(row.get("engine", "")) != "codex":
        return ""
    return str(row.get("source_digest", "") or "")


def codex_rollback_backup_path(dest_file: Path) -> Path:
    """Sidecar last-known-good backup path for a Codex dest auth.json.

    Same directory as the dest so it inherits the dest's iso ownership
    contract and an atomic rename never crosses a filesystem boundary.
    """
    return dest_file.parent / (dest_file.name + ".agb-lkg")


def ensure_claude_config_file(
    config_dir: Path,
    trusted_workdirs: list[str] | None = None,
    *,
    owner_uid: int | None = None,
    owner_gid: int | None = None,
    allowed_root: Path | None = None,
) -> Path:
    path = config_dir / ".claude.json"
    _ensure_claude_dir_safe(path, allowed_root)
    config_dir.mkdir(parents=True, exist_ok=True)
    existing: dict[str, Any] | None = None
    if path.exists():
        try:
            parsed = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"Claude config file is not valid JSON: {path}: {exc}") from exc
        if not isinstance(parsed, dict):
            raise ValueError(f"Claude config file must contain a JSON object: {path}")
        existing = parsed
    payload = claude_config_bootstrap_payload(existing, trusted_workdirs)
    # PR #799 r4 codex finding 1 — always route through write_private_file_atomic.
    # The previous "existing == payload" fast path returned without atomic rewrite,
    # doing final-path os.chmod/os.chown on a path the agent UID can swap to a
    # symlink between check and op. That is the same TOCTOU symlink-follow class
    # as the bash helper r3 removed. Atomic rewrite carries the
    # _ensure_claude_dir_safe parent-symlink check and the chown-before-replace
    # ordering, so there is no privileged-op-on-final-path window. Perf hit is
    # negligible — .claude.json is small and sync is infrequent.
    text = json.dumps(payload, ensure_ascii=True, indent=2) + "\n"
    write_private_file_atomic(
        path,
        text,
        mode=0o600,
        prefix=".claude.",
        owner_uid=owner_uid,
        owner_gid=owner_gid,
    )
    return path


def claude_settings_write_path(config_dir: Path) -> Path:
    path = config_dir / "settings.json"
    if not path.is_symlink():
        return path
    target = path.resolve(strict=False)
    config_root = config_dir.resolve(strict=False)
    try:
        target.relative_to(config_root)
    except ValueError as exc:
        raise ValueError(f"Claude settings symlink must stay inside config dir: {path} -> {target}") from exc
    return target


def ensure_claude_settings_file(
    config_dir: Path,
    *,
    owner_uid: int | None = None,
    owner_gid: int | None = None,
    allowed_root: Path | None = None,
) -> Path:
    _ensure_claude_dir_safe(config_dir / "settings.json", allowed_root)
    config_dir.mkdir(parents=True, exist_ok=True)
    path = claude_settings_write_path(config_dir)
    payload: dict[str, Any] = {}
    mode = 0o600
    if path.exists():
        mode = path.stat().st_mode & 0o777
        try:
            parsed = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"Claude settings file is not valid JSON: {path}: {exc}") from exc
        if not isinstance(parsed, dict):
            raise ValueError(f"Claude settings file must contain a JSON object: {path}")
        payload = parsed
    payload.setdefault("skipDangerousModePermissionPrompt", True)
    # #1444 BLOCKING 3 (Linux/iso-v2 leak): only RENDER the managed apiKeyHelper
    # when the gate is enabled AND we are on the platform the feature targets
    # (macOS — matching the Darwin-gated cron-runner/bridge-run.sh preflights).
    # On Linux/iso-v2 the controller helper path is wrong for the agent (and
    # under iso v2 not even reachable from the agent UID), so we must NEVER
    # write it there. The cleanup branch below still runs on non-Darwin so a
    # stale managed value (e.g. left by a pre-fix sync, or after the gate is
    # turned off) gets removed regardless of platform.
    if claude_keychain_free_auth_enabled() and keychain_free_apikeyhelper_supported():
        payload["apiKeyHelper"] = claude_api_key_helper_path()
    elif apikeyhelper_value_is_bridge_managed(payload.get("apiKeyHelper")):
        # Disable/rollback/non-Darwin cleanup: the gate is off (or we are not on
        # a supported platform) but a prior sync left our managed helper in
        # settings.json. Claude would still invoke it, and the helper now exits
        # "disabled" — breaking the intended fallback to normal keychain auth.
        # Remove ONLY our managed value; an operator's own apiKeyHelper is
        # preserved (apikeyhelper_value_is_bridge_managed returns False for it).
        # Idempotent: once removed, the key is absent so this branch is a no-op
        # on the next sync.
        payload.pop("apiKeyHelper", None)
    # PR #799 r4 codex finding 1 — always route through write_private_file_atomic.
    # The previous "payload == before" fast path returned without atomic rewrite,
    # doing final-path os.chown on a path the agent UID can swap to a symlink
    # between check and op. Same TOCTOU symlink-follow class as the bash helper
    # r3 removed. Atomic rewrite carries the _ensure_claude_dir_safe parent-symlink
    # check and the chown-before-replace ordering, so there is no privileged-op-
    # on-final-path window. Perf hit is negligible — settings.json is small and
    # sync is infrequent.
    text = json.dumps(payload, ensure_ascii=True, indent=2) + "\n"
    write_private_file_atomic(
        path,
        text,
        mode=mode,
        prefix=".settings.",
        owner_uid=owner_uid,
        owner_gid=owner_gid,
    )
    return path


def cmd_api_key_helper(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    if json_mode and not bool(args.check):
        return fail("--json is only supported with --check", json_mode)
    if not claude_keychain_free_auth_enabled():
        return fail("Claude keychain-free auth is disabled", json_mode)

    registry_path = Path(args.registry).expanduser()
    try:
        with registry_lock(registry_path):
            registry = load_registry(registry_path)
            active_id, token = active_registry_token(registry)
    except Exception as exc:
        return fail(str(exc), json_mode)

    if bool(args.check):
        payload = {"status": "ok", "active_token_id": active_id}
        if json_mode:
            json_dump(payload)
        else:
            print("ok: active Claude OAuth token available")
        return 0

    sys.stdout.write(token)
    sys.stdout.write("\n")
    return 0


def cmd_sync_agent(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    # Fleet-credential Phase 1 (#1470): fail-closed engine gate. The body
    # of cmd_sync_agent IS the Claude registry/controller-credentials
    # write path. Phase 1 only supports `claude` through this command —
    # Codex/Gemini are descriptor SLOTS, their `register`/`sync`/`verify`
    # adapter is Phase 2. Reject any non-Claude `--engine` BEFORE touching
    # the registry or writing a credential so a caller can never run the
    # Claude write body for another engine (codex r1 BLOCKING). An unknown
    # engine raises through engine_auth_descriptor; a known-but-non-Claude
    # engine is refused here with an explicit "Phase 2" message.
    #
    # codex r2 BLOCKING: distinguish OMITTED from EXPLICITLY-EMPTY. The
    # argparse default is None (NOT DEFAULT_AUTH_ENGINE), so:
    #   --engine omitted entirely → args.engine is None → Claude (allowed).
    #   --engine "" / "   "       → args.engine is a blank string → REJECT.
    # Using `args.engine or DEFAULT_AUTH_ENGINE` would coerce the explicit
    # empty string back to Claude (falsy `""` collapses to the default),
    # which is exactly the cross-engine credential-misdelivery hole codex
    # found: Phase 2 passing an empty engine var would write a Claude
    # credential into the Codex dest. Treat None (omitted) as Claude;
    # treat a provided-but-blank value as an explicit, refused engine.
    raw_engine = getattr(args, "engine", None)
    if raw_engine is None:
        engine = DEFAULT_AUTH_ENGINE
    else:
        engine = raw_engine.strip()
        if not engine:
            return fail(
                "sync-agent --engine was given an empty/whitespace value; "
                "omit --engine for the default Claude credential sync or "
                "pass an explicit engine name",
                json_mode,
            )
    try:
        engine_auth_descriptor(engine)  # raises ValueError on unknown engine
    except ValueError as exc:
        return fail(str(exc), json_mode)
    if engine != DEFAULT_AUTH_ENGINE:
        return fail(
            f"sync-agent does not support engine {engine!r} in Phase 1 — "
            f"only {DEFAULT_AUTH_ENGINE!r} credential sync is implemented "
            "(the Codex adapter is Phase 2 of #1470)",
            json_mode,
        )
    # #1261 (v0.15.0-beta4): track the controller-credentials aliveness
    # so the JSON payload carries a structured signal. Daemon-side
    # callers (bridge-daemon.sh periodic sync tick) emit this into
    # audit.jsonl alongside ``sync_status`` so the operator's log shows
    # WHY a sync ended up propagating a near-expiry token.
    aliveness = ""
    remaining_ms = 0
    try:
        registry = load_registry(Path(args.registry).expanduser())
        active_id = str(registry.get("active_token_id") or "")
        token = ""
        source = "claude_token_registry"
        row: dict[str, Any] | None = None
        if active_id:
            row = find_token(registry, active_id)
            if row is None:
                raise ValueError(
                    f"active token id is missing from registry: {active_id}"
                )
            if not bool(row.get("enabled", True)):
                raise ValueError(f"active token id is disabled: {active_id}")
            token = str(row.get("token") or "")
            validate_token(token)
        else:
            # #1075 fallback — no Claude setup-token is registered, but the
            # controller is logged in via ``claude.ai`` OAuth. Provision the
            # per-agent ``CLAUDE_CONFIG_DIR/.credentials.json`` from the
            # controller's ``~/.claude/.credentials.json`` so channel agents
            # do not start up ``Not logged in``. Preserves the full payload
            # (refreshToken etc.) instead of synthesizing a minimal one.
            source = "controller_credentials"
        credential_file = Path(args.file).expanduser()
        trusted_workdirs = [str(Path(item).expanduser()) for item in (args.workdir or []) if item]
        owner_uid = args.owner_uid if args.owner_uid is not None and args.owner_uid >= 0 else None
        owner_gid = args.owner_gid if args.owner_gid is not None and args.owner_gid >= 0 else None
        allowed_root = (
            Path(args.allowed_root).expanduser() if args.allowed_root else None
        )
        if source == "controller_credentials":
            controller_path = resolve_controller_claude_credentials_path(
                args.controller_credentials
            )
            controller_payload = read_controller_claude_credentials_payload(
                controller_path
            )
            # #1261 (v0.15.0-beta4): aliveness gate. The prior
            # controller-credentials fallback unconditionally propagated
            # whatever the controller had on disk — including a long-
            # expired token. Claude CLI refreshes controller credentials
            # LAZILY (only when the controller itself makes an API call),
            # so on hosts where the operator's day-to-day work happens
            # inside agents the controller token sits stale and every
            # daemon-driven sync silently distributed an expired token.
            # Outcome: all agents 401'd at once after a single idle
            # window (~8h on a Max plan). The probe is offline-cheap —
            # we already have ``expiresAt`` on the parsed payload.
            #
            # On the "expired" branch we refuse to propagate and surface
            # a structured error so the daemon's audit row records the
            # cause; the operator's `agent-bridge status` row will then
            # flag the controller as the single-point-of-failure rather
            # than the agent inheriting a bad credential and failing on
            # its first /tokens use.
            #
            # Codex r1 / patch r2 comment angle 4: the prior fallback's
            # silent propagation meant the iso-UID agent then saw a
            # "Please run /login" banner — that banner is misleading
            # because the agent CANNOT fix the problem from inside its
            # own session. The right surface is the controller's
            # ``claude /login``, surfaced via the audit row + the
            # operator-facing status. We keep the agent-side error
            # specific so KNOWN_ISSUES.md can link the audit reason to
            # the operator action.
            #
            # Aliveness tuple is captured into the enclosing-scope
            # ``aliveness`` / ``remaining_ms`` (declared at the top of
            # cmd_sync_agent) so the final JSON payload below carries
            # the structured signal.
            (aliveness, remaining_ms) = controller_credentials_aliveness(
                controller_payload
            )
            if aliveness == "expired":
                raise ValueError(
                    "controller token expired "
                    f"({-remaining_ms}ms past expiry at {controller_path}). "
                    "Run `claude /login` on the controller host, OR register a "
                    "Claude OAuth Setup Token via `bridge-auth.sh claude-token "
                    "add --id <id> --stdin --activate --sync --agents all "
                    "--enable-auto-rotate` to avoid the lazy-refresh dependency."
                )
            # near_expiry / no_expires_at: emit a structured warning to
            # stderr so the audit row at the daemon side records the
            # near-expiry signal alongside the sync_status. We still
            # propagate (the token is technically valid right now) but
            # the operator gets a loud heads-up. JSON callers see the
            # warning on stderr; the JSON payload below carries the
            # ``aliveness`` field so structured consumers can branch.
            if aliveness in ("near_expiry", "no_expires_at"):
                ttl_min = _controller_credentials_min_ttl_ms() // 60000
                print(
                    f"warning: controller token {aliveness} "
                    f"(remaining_ms={remaining_ms}, min_ttl_ms_threshold="
                    f"{_controller_credentials_min_ttl_ms()}). All agents "
                    f"using the controller-credentials fallback will 401 "
                    f"within ~{ttl_min} minutes. Run `claude /login` on the "
                    f"controller host or register a Claude OAT (bridge-auth.sh "
                    f"claude-token add ...) to break the single-point-of-failure.",
                    file=sys.stderr,
                )
            write_claude_credentials_payload(
                credential_file,
                controller_payload,
                owner_uid=owner_uid,
                owner_gid=owner_gid,
                allowed_root=allowed_root,
            )
            payload_key = engine_auth_descriptor(DEFAULT_AUTH_ENGINE)["cred_payload_key"]
            synced_material = str(controller_payload[payload_key]["accessToken"])
            fingerprint = token_fingerprint(synced_material)
        else:
            write_claude_credentials_file(
                credential_file,
                token,
                owner_uid=owner_uid,
                owner_gid=owner_gid,
                allowed_root=allowed_root,
            )
            synced_material = token
            fingerprint = token_fingerprint(token)
        config_file = ensure_claude_config_file(
            credential_file.parent,
            trusted_workdirs,
            owner_uid=owner_uid,
            owner_gid=owner_gid,
            allowed_root=allowed_root,
        )
        settings_file = ensure_claude_settings_file(
            credential_file.parent,
            owner_uid=owner_uid,
            owner_gid=owner_gid,
            allowed_root=allowed_root,
        )
    except Exception as exc:
        return fail(str(exc), json_mode)
    # Fleet-credential Phase 1 (#1470, Q4 groundwork): stamp the per-agent
    # credential generation so a later #1469 set-scoped re-wake can target
    # only agents running under a vacated generation. Best-effort — the
    # credential sync above already succeeded and is the source of truth;
    # a stamp failure (e.g. an unwritable state dir) must never turn a
    # good sync into a reported failure. The bump is idempotent: a re-sync
    # of the same credential leaves cred_generation unchanged. `engine` is
    # the fail-closed-validated value resolved at the top of cmd_sync_agent
    # (Phase 1: always `claude` here, since non-Claude engines were
    # already refused before any write).
    cred_generation = 0
    cred_state_file = ""
    try:
        record = stamp_cred_generation(
            args.agent,
            engine,
            synced_material,
            owner_uid=owner_uid,
            owner_gid=owner_gid,
        )
        cred_generation = int(record.get("cred_generation", 0) or 0)
        cred_state_file = str(cred_state_path())
    except Exception as exc:  # noqa: BLE001 - stamp is best-effort, never fatal
        print(
            f"warning: cred-generation stamp failed for {args.agent}: {exc}",
            file=sys.stderr,
        )
    payload = {
        "status": "synced",
        "agent": args.agent,
        "file": str(credential_file),
        "config_file": str(config_file),
        "settings_file": str(settings_file),
        "delivery": "claude_credentials_file",
        "trusted_workdirs": trusted_workdirs,
        "active_token_id": active_id,
        "source": source,
        "fingerprint": fingerprint,
        # #1261 (v0.15.0-beta4): structured aliveness signal for
        # daemon-side audit. Empty for the claude_token_registry source
        # (the OAT path has its own aliveness handling via recover-due);
        # populated for the controller_credentials fallback.
        "aliveness": aliveness,
        "remaining_ms": remaining_ms,
        # Fleet-credential Phase 1 (#1470): the engine this sync ran for
        # and the credential generation stamped at sync time. `engine` is
        # `claude` on the existing path (byte-compatible additive field);
        # `cred_generation` is 0 when the best-effort stamp could not be
        # written.
        "engine": engine,
        "cred_generation": cred_generation,
        "cred_state_file": cred_state_file,
    }
    if claude_keychain_free_auth_enabled():
        payload["api_key_helper"] = claude_api_key_helper_path()
        payload["api_key_helper_ttl_ms"] = claude_api_key_helper_ttl_ms()
    if json_mode:
        json_dump(payload)
    else:
        if source == "controller_credentials":
            print(
                f"synced: {args.agent} <- controller-credentials "
                f"({payload['fingerprint']})"
            )
        else:
            print(f"synced: {args.agent} <- {active_id} ({payload['fingerprint']})")
    return 0


# ─────────────────────────────────────────────────────────────────────
# Codex fleet-sync CLI handlers (#1470 Phase 2). Invoked by bridge-auth.sh
# `codex-cred {register,sync,verify,source}` after the bash layer has
# resolved iso ownership / source-agent validation.
CODEX_ENGINE = "codex"


def cmd_codex_register(args: argparse.Namespace) -> int:
    """Persist the validated Codex source-agent binding (Q1).

    The bash layer (``bridge-auth.sh codex-cred register``) has already
    validated ``--source`` is an existing, non-stopped Codex agent. This
    handler only stamps the protected 0600 state file. Refuses an empty
    source (the binding must name a concrete agent).
    """
    json_mode = bool(args.json)
    source = (args.source or "").strip()
    if not source:
        return fail("codex-cred register requires a non-empty --source agent", json_mode)
    try:
        save_codex_source_binding(source)
    except Exception as exc:  # noqa: BLE001 - surface as a clean CLI error
        return fail(f"failed to persist Codex source binding: {exc}", json_mode)
    payload = {
        "status": "registered",
        "engine": CODEX_ENGINE,
        "source_agent": source,
        "binding_file": str(codex_source_binding_path()),
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"codex source registered: {source} -> {payload['binding_file']}")
    return 0


def cmd_codex_source(args: argparse.Namespace) -> int:
    """Print the persisted Codex source-agent binding (Q1 read side)."""
    json_mode = bool(args.json)
    binding = load_codex_source_binding()
    source = binding.get("source_agent", "")
    payload = {
        "status": "ok" if source else "unconfigured",
        "engine": CODEX_ENGINE,
        "source_agent": source,
        "binding_file": str(codex_source_binding_path()),
    }
    if json_mode:
        json_dump(payload)
    else:
        print(source if source else "(no codex source configured)")
    return 0


def cmd_codex_verify(args: argparse.Namespace) -> int:
    """Offline well-formedness/expiry verify of a Codex auth.json (Q3).

    NO network, NO `codex` subprocess. Reports ``ok``/``rejected`` plus
    the content digest so a caller can compare generations. Codex L4 is
    documented as weaker than Claude — this is a path/shape/parse check,
    not proof the remote subscription is live.
    """
    json_mode = bool(args.json)
    path = Path(args.file).expanduser()
    try:
        _raw, _parsed, digest = read_codex_auth_snapshot(path)
    except ValueError as exc:
        payload = {
            "status": "rejected",
            "engine": CODEX_ENGINE,
            "file": str(path),
            "reason": str(exc),
        }
        if json_mode:
            json_dump(payload)
        else:
            print(f"codex auth REJECTED ({path}): {exc}", file=sys.stderr)
        return 1
    payload = {
        "status": "ok",
        "engine": CODEX_ENGINE,
        "file": str(path),
        "source_digest": digest,
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"codex auth ok ({path}) digest={digest[:12]}…")
    return 0


def cmd_codex_sync(args: argparse.Namespace) -> int:
    """Write-through the source Codex auth.json to a managed dest (L4).

    The bash layer passes the resolved ``--source-file`` (read out of the
    source agent home, via ``sudo -n -u <owner> cat`` when iso-owned),
    the ``--file`` dest path, and the dest's iso ``--owner-uid``/
    ``--owner-gid``. This handler:

      1. Validates the source snapshot (fail loud on malformed — NEVER
         propagate; §6.5 / Q2).
      2. Cross-engine gate: refuses any engine != codex BEFORE any write
         so a Codex sync can never write a Claude credential (§8).
      3. Digest gate (Q2): if the dest already recorded this exact
         source_digest, it is a NO-OP — no rewrite, no generation bump
         (idempotent re-sync). Force with ``--force``.
      4. Write-through (§6.6): delivers the source bytes VERBATIM via
         ``write_private_file_atomic`` (chown-before-replace, 0600).
         NEVER a symlink. Refuses to write through a pre-existing symlink
         at the dest (the agent could pre-place one to redirect the
         write out of its home).
      5. Rollback (Q-extra): captures a same-owner last-known-good
         backup BEFORE the write; on a write failure restores it, but
         only if that backup is itself well-formed (never roll back to a
         malformed/empty file).
      6. Stamps the Phase-1 cred-generation under engine=codex.
    """
    json_mode = bool(args.json)
    # Fail-closed engine gate (§8): this command body writes a Codex
    # credential. Refuse any non-codex engine BEFORE touching the dest so
    # the Codex write path can never be driven for another engine, and an
    # unknown engine raises through the descriptor (never silent Claude).
    #
    # codex r1 BLOCKING: distinguish OMITTED (None → codex, byte-compatible)
    # from EXPLICITLY-EMPTY (`--engine ""` / `"  "` → REFUSE). A naive
    # `args.engine or CODEX_ENGINE` would coerce an explicit empty string
    # back to codex — but worse, an empty string is an attacker-shaped value
    # that must be rejected, not silently accepted as the default. Mirror the
    # Phase-1 cmd_sync_agent gate exactly.
    raw_engine_arg = getattr(args, "engine", None)
    if raw_engine_arg is None:
        raw_engine = CODEX_ENGINE
    else:
        raw_engine = raw_engine_arg.strip()
        if not raw_engine:
            return fail(
                "codex-cred sync --engine was given an empty/whitespace value; "
                "omit --engine for the default Codex sync or pass an explicit "
                "engine name",
                json_mode,
            )
    try:
        engine_auth_descriptor(raw_engine)
    except ValueError as exc:
        return fail(str(exc), json_mode)
    if raw_engine != CODEX_ENGINE:
        return fail(
            f"codex-cred sync only supports engine {CODEX_ENGINE!r}, got {raw_engine!r}",
            json_mode,
        )

    source_path = Path(args.source_file).expanduser()
    dest_path = Path(args.file).expanduser()
    owner_uid = args.owner_uid if args.owner_uid is not None and args.owner_uid >= 0 else None
    owner_gid = args.owner_gid if args.owner_gid is not None and args.owner_gid >= 0 else None
    allowed_root = (
        Path(args.allowed_root).expanduser() if args.allowed_root else None
    )

    # 1. Validate the source snapshot — fail loud, never propagate a bad cred.
    try:
        source_raw, _parsed, source_digest = read_codex_auth_snapshot(source_path)
    except ValueError as exc:
        return fail(str(exc), json_mode)

    # 2. Refuse to write through a symlink at the dest OR a symlinked PARENT
    #    (codex r1 BLOCKING: the agent owns its home and could pre-place
    #    `.codex` itself — not just `.codex/auth.json` — as a symlink to
    #    redirect a privileged write out of its home; write_private_file_atomic
    #    creates its tempfile in `dest.parent` and replaces THROUGH that
    #    parent, so a symlinked parent escapes the home even when the final
    #    name is not yet a symlink). Reuse the Claude path's `_ensure_claude_dir_safe`
    #    realpath-stays-inside guard for the PARENT, plus a final-name symlink
    #    reject.
    if dest_path.is_symlink():  # noqa: raw-pathlib-controller-only - controller-side final-name symlink reject on the bash-resolved dest
        return fail(
            f"refusing to write through a symlink at the Codex dest: {dest_path}",
            json_mode,
        )
    try:
        _ensure_claude_dir_safe(dest_path, allowed_root)
    except PermissionError as exc:
        return fail(str(exc), json_mode)

    # 3. Digest gate (Q2): idempotent re-sync is a no-op unless --force.
    prior_digest = codex_dest_generation_digest(args.agent)
    if not args.force and prior_digest and prior_digest == source_digest:
        cred_generation = 0
        state = load_cred_state(cred_state_path())
        row = state["agents"].get(args.agent)
        if isinstance(row, dict):
            try:
                cred_generation = int(row.get("cred_generation", 0) or 0)
            except (TypeError, ValueError):
                cred_generation = 0
        payload = {
            "status": "unchanged",
            "engine": CODEX_ENGINE,
            "agent": args.agent,
            "file": str(dest_path),
            "source_digest": source_digest,
            "cred_generation": cred_generation,
            "cred_state_file": str(cred_state_path()),
        }
        if json_mode:
            json_dump(payload)
        else:
            print(f"codex unchanged: {args.agent} (digest stable)")
        return 0

    # 4. Capture a last-known-good backup of the CURRENT dest BEFORE the
    #    write, so a failed write can roll back. codex r1 BLOCKING: roll back
    #    ONLY to a credential the bridge KNOWS is good — i.e. one whose digest
    #    matches the generation cred-state recorded for THIS agent (the last
    #    one the bridge itself successfully synced). A current dest the agent
    #    may have swapped in (wrong-source / expired / hand-placed) does NOT
    #    match the recorded digest and is NEVER eligible as a rollback target.
    #    The backup is therefore gated on `current_dest_digest == prior_digest`
    #    where prior_digest is the recorded cred-generation digest. If the
    #    recorded digest is absent (first sync) there is nothing trusted to
    #    roll back to, and that is correct: a first-sync failure leaves no
    #    dest, never an attacker-chosen one.
    backup_path = codex_rollback_backup_path(dest_path)
    have_backup = False
    backup_digest = ""
    if (
        prior_digest
        and dest_path.exists()  # noqa: raw-pathlib-controller-only - controller-side last-known-good probe on the bash-resolved dest
        and not dest_path.is_symlink()  # noqa: raw-pathlib-controller-only - controller-side symlink reject before backing up the dest
    ):
        try:
            prev_raw, _prev_parsed, prev_digest = read_codex_auth_snapshot(dest_path)
        except ValueError:
            prev_raw = None  # current dest is malformed — do NOT back it up.
            prev_digest = ""
        # Only trust the current dest as a rollback target when its digest
        # equals the generation cred-state recorded (the bridge's own LKG).
        if prev_raw is not None and prev_digest == prior_digest:
            try:
                # codex r2 BLOCKING: the parent-pinned (dir_fd) writer so a
                # live `.codex` swap cannot redirect even the backup write.
                write_private_file_atomic_dirfd(
                    backup_path,
                    prev_raw,
                    mode=0o600,
                    prefix=".codex-lkg.",
                    owner_uid=owner_uid,
                    owner_gid=owner_gid,
                    allowed_root=allowed_root,
                )
                have_backup = True
                backup_digest = prev_digest
            except Exception:  # noqa: BLE001 - backup is best-effort; a failure
                have_backup = False  # just means rollback is unavailable.

    # 5. Write-through the source bytes VERBATIM (no key extraction, no
    #    re-serialization) so a byte-for-byte copy lands at the dest.
    #    codex r2 BLOCKING: use the parent-pinned (dir_fd) writer so a live
    #    parent-swap TOCTOU between the _ensure_claude_dir_safe check and the
    #    write cannot redirect the privileged write out of allowed_root — the
    #    directory the writer USES is the fd it opened O_DIRECTORY|O_NOFOLLOW.
    rolled_back = False
    try:
        write_private_file_atomic_dirfd(
            dest_path,
            source_raw,
            mode=0o600,
            prefix=".codex-auth.",
            owner_uid=owner_uid,
            owner_gid=owner_gid,
            allowed_root=allowed_root,
        )
    except Exception as exc:  # noqa: BLE001 - attempt rollback then fail loud
        if have_backup:
            try:
                # Restore only the backup we captured above, AND only if it
                # STILL re-validates as well-formed AND its digest still
                # equals the recorded last-known-good (never roll back to a
                # malformed/expired/wrong-source file, and never to a backup
                # tampered between capture and restore).
                restore_raw, _rp, restore_digest = read_codex_auth_snapshot(backup_path)
                if restore_digest != backup_digest:
                    raise ValueError(
                        "rollback backup digest changed since capture — refusing to restore"
                    )
                write_private_file_atomic_dirfd(
                    dest_path,
                    restore_raw,
                    mode=0o600,
                    prefix=".codex-auth.",
                    owner_uid=owner_uid,
                    owner_gid=owner_gid,
                    allowed_root=allowed_root,
                )
                rolled_back = True
            except Exception:  # noqa: BLE001 - rollback failed too; report both
                rolled_back = False
        _cleanup_codex_backup(backup_path)
        return fail(
            f"codex auth write failed for {args.agent} ({dest_path}): {exc}"
            + ("; rolled back to last-known-good" if rolled_back else ""),
            json_mode,
        )

    # Write succeeded — the backup is no longer needed.
    _cleanup_codex_backup(backup_path)

    # 6. Stamp the cred-generation under engine=codex (best-effort, never
    #    turns a good write into a reported failure). The digest is over
    #    the same source material so an idempotent re-sync of the same
    #    auth.json does not bump the generation.
    cred_generation = 0
    try:
        record = stamp_cred_generation(
            args.agent,
            CODEX_ENGINE,
            source_raw,
            owner_uid=owner_uid,
            owner_gid=owner_gid,
        )
        cred_generation = int(record.get("cred_generation", 0) or 0)
    except Exception as exc:  # noqa: BLE001 - stamp is best-effort
        print(
            f"warning: cred-generation stamp failed for {args.agent}: {exc}",
            file=sys.stderr,
        )

    payload = {
        "status": "synced",
        "engine": CODEX_ENGINE,
        "agent": args.agent,
        "file": str(dest_path),
        "delivery": "codex_auth_file",
        "source_digest": source_digest,
        "cred_generation": cred_generation,
        "cred_state_file": str(cred_state_path()),
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"codex synced: {args.agent} <- source (digest={source_digest[:12]}…)")
    return 0


def _cleanup_codex_backup(backup_path: Path) -> None:
    try:
        backup_path.unlink()  # noqa: raw-pathlib-controller-only - controller-side cleanup of the same-dir last-known-good sidecar
    except FileNotFoundError:
        pass
    except OSError:
        pass


# ─────────────────────────────────────────────────────────────────────
# Sealed-paste operator-terminal receive (#1367).
#
# #1358 closed the tactical scope: the admin agent runs `bash
# bridge-auth.sh claude-token add --stdin …` and the operator pastes the
# raw OAuth token into the agent's Bash tool. The audit row is redacted,
# but the admin agent's TRANSCRIPT/tool-input is NOT — so the raw token
# lands in the admin transcript.
#
# `receive` is the root path (codex-agreed Option B): the echo-off read
# happens in the OPERATOR's terminal process via `/dev/tty`, NEVER inside
# an agent process. The token exists only in this process's memory and
# then in the intended 0600 registry output. It is never an argv, env
# var, queue body, audit detail, note text, prompt text, or named
# temp file. Fail CLOSED when there is no controlling TTY — never
# downgrade to stdin/argv/env/file input.
#
# `receive --request` is the token-FREE admin-agent UX: an admin agent
# can INITIATE the flow (emit a pending request id + nonce + requested
# agents) without ever touching the token. The operator terminal later
# fulfills that request id with the echo-off read.

SEALED_RECEIVE_PROMPT = (
    "paste your Claude OAuth token (input will NOT echo and will NOT be "
    "logged), then press Enter: "
)


def _sealed_receive_audit(action: str, detail: dict[str, Any]) -> None:
    """Best-effort redacted audit row for the sealed-paste path (#1367).

    Routes through the hooks' ``write_audit`` choke-point (which runs the
    SSOT credential redactor over the detail dict) so a sealed-receive
    audit row inherits the same token-value scrub as every PreToolUse /
    PostToolUse row. The detail must already be token-free by
    construction here (id, safe flags, fingerprint tail, redacted
    summary only); the choke-point is belt-and-suspenders.

    Lazy import of the hooks module keeps the rest of bridge-auth.py
    free of a hard dependency on the hooks dir, and a missing/unusable
    audit sink NEVER blocks the registry write — the operator-side
    receive must not fail because an audit append could not be made.
    """
    try:
        hooks_dir = ROOT / "hooks"
        if str(hooks_dir) not in sys.path:
            sys.path.insert(0, str(hooks_dir))
        from bridge_hook_common import write_audit as _write_audit  # type: ignore

        target = (
            os.environ.get("BRIDGE_AGENT_ID", "").strip()  # noqa: iso-helper-boundary - controller-side audit-target label for the operator-run receive
            or os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()  # noqa: iso-helper-boundary - controller-side audit-target label fallback
            or "operator"
        )
        _write_audit(action, target, detail)
    except Exception:  # noqa: BLE001 - audit emit is best-effort, never fatal
        pass


def read_token_from_controlling_tty(prompt: str = SEALED_RECEIVE_PROMPT) -> str:
    """Read a token echo-off from the controlling terminal (#1367).

    Opens ``/dev/tty`` directly (NOT stdin) so the read provably happens
    in the operator's terminal process. Echo is disabled via ``termios``
    for the duration of the read; the prompt is written to the tty, not
    to stdout (so a captured stdout never contains the prompt either).

    Fails CLOSED — raises ``RuntimeError`` — when there is no controlling
    terminal (``/dev/tty`` cannot be opened or is not a tty). The caller
    MUST NOT downgrade to stdin/argv/env/file on this failure; that is the
    whole point of the sealed path.
    """
    import termios

    try:
        tty_fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError as exc:
        raise RuntimeError(
            "no controlling terminal — run `receive` from an operator "
            "terminal (the token read needs an interactive tty and will "
            f"not fall back to stdin/argv/env/file): {exc}"
        ) from exc

    # Raw fd I/O only — a tty is not seekable, so `os.fdopen` with a
    # buffered text wrapper fails. We prompt + read echo-off directly on
    # the fd. The token bytes live only in this frame's local.
    old_attrs = None
    try:
        if not os.isatty(tty_fd):
            raise RuntimeError(
                "/dev/tty is not a terminal — run `receive` from an "
                "interactive operator terminal"
            )
        old_attrs = termios.tcgetattr(tty_fd)
        new_attrs = list(old_attrs)
        # lflags index 3: clear ECHO so the token is not displayed.
        new_attrs[3] = new_attrs[3] & ~termios.ECHO
        termios.tcsetattr(tty_fd, termios.TCSADRAIN, new_attrs)
        os.write(tty_fd, prompt.encode("utf-8", errors="replace"))
        # Read one line (up to a newline) byte-by-byte so we stop exactly
        # at the operator's Enter without slurping anything beyond it.
        chunks: list[bytes] = []
        while True:
            ch = os.read(tty_fd, 1)
            if not ch or ch in (b"\n", b"\r"):
                break
            chunks.append(ch)
        raw = b"".join(chunks)
    finally:
        if old_attrs is not None:
            try:
                termios.tcsetattr(tty_fd, termios.TCSADRAIN, old_attrs)
                # Echo the newline the operator typed (it was suppressed).
                os.write(tty_fd, b"\n")
            except Exception:  # noqa: BLE001
                pass
        os.close(tty_fd)

    token = raw.decode("utf-8", errors="replace").rstrip("\r\n")
    validate_token(token)
    return token


def cmd_receive(args: argparse.Namespace) -> int:
    """Sealed-paste operator-terminal token receive (#1367).

    Two shapes:
      * ``receive --request`` — token-FREE: emit a pending request record
        (id, safe flags, nonce, requested agents). No token is read or
        touched. An admin agent may run this to initiate the flow.
      * ``receive --id <id> [flags]`` — operator-terminal echo-off read
        from ``/dev/tty``; writes through the existing locked-registry
        add path. Fails closed with no controlling tty.
    """
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()

    if args.request:
        return _cmd_receive_request(args, registry_path, json_mode)

    # ── agent-context refusal (the runtime boundary, #1367 r4) ───────
    # The token-ACCEPTING receive must run ONLY in the OPERATOR's own
    # terminal, never from inside an agent. An agent's process carries
    # BRIDGE_AGENT_ID; the operator's own shell does not (a legit
    # operator-run receive is audited under the "operator" label). Refuse
    # affirmatively HERE so the guarantee does NOT depend on the PreToolUse
    # hook enumerating every shell spelling — `env`/`command`/`/usr/bin/env`
    # /`bash -opt`/`sh -c`/symlink/… are unbounded, so the hook is only
    # best-effort defense-in-depth; this runtime gate is the real boundary.
    # The token-free `--request` shape returned above is unaffected, so an
    # admin agent can still INITIATE the flow without touching a token.
    agent_ctx = os.environ.get("BRIDGE_AGENT_ID", "").strip()  # noqa: iso-helper-boundary - agent-context gate for the operator-only token-accepting receive
    if agent_ctx:
        _sealed_receive_audit(
            "tool_policy_credential_sealed_receive_refused_agent_context",
            {
                "surface": "sealed_paste_receive",
                "id": args.id or "",
                "reason": "agent_context_token_accepting_receive",
            },
        )
        return fail(
            "token-accepting `receive` must be run by the OPERATOR from a "
            "terminal, not from an agent (BRIDGE_AGENT_ID is set). Use "
            "`receive --request ... --json` to initiate; the operator then "
            "completes it from their own terminal.",
            json_mode,
        )

    # ── operator-terminal echo-off receive ──────────────────────────
    if not args.id:
        return fail("receive requires --id <id> (or --request)", json_mode)
    try:
        validate_token_id(args.id)
    except Exception as exc:
        return fail(str(exc), json_mode)

    request_record: dict[str, Any] | None = None
    if args.fulfill:
        try:
            request_record = _load_and_consume_request(registry_path, args.fulfill)
        except Exception as exc:
            return fail(str(exc), json_mode)

    try:
        token = read_token_from_controlling_tty()
    except RuntimeError as exc:
        # Fail closed — NO token read, nothing written anywhere.
        _sealed_receive_audit(
            "tool_policy_credential_sealed_receive_failed",
            {
                "surface": "sealed_paste_receive",
                "id": args.id,
                "reason": "no_controlling_tty",
            },
        )
        return fail(str(exc), json_mode)
    except Exception as exc:
        # validate_token / termios error — the token never reached the
        # registry. The message from validate_token is generic (e.g.
        # "token is too short"); it never echoes the token value.
        return fail(str(exc), json_mode)

    try:
        result = _apply_token_to_registry(
            registry_path,
            args.id,
            token,
            note=args.note or "",
            activate=bool(args.activate),
            replace=bool(args.replace),
            enable_auto_rotate=bool(args.enable_auto_rotate),
            threshold=args.threshold,
        )
    except Exception as exc:
        return fail(str(exc), json_mode)
    finally:
        # Drop the token reference promptly; Python cannot zero the bytes
        # but we minimise the window it stays bound in this frame.
        token = ""

    # Audit: redacted-only. The fingerprint is the SAME forensic anchor
    # the registry stores (sha256 prefix + 4-char tail), never the raw
    # token. The summary is a fixed-shape redacted record.
    _sealed_receive_audit(
        "tool_policy_credential_sealed_receive",
        {
            "surface": "sealed_paste_receive",
            "id": result["id"],
            "status": result["status"],
            "fingerprint": result["fingerprint"],
            "activated": result["active_token_id"] == result["id"],
            "fulfilled_request": (request_record or {}).get("request_id", ""),
            "summary": (
                f"sealed receive: id={result['id']} status={result['status']} "
                f"fingerprint={result['fingerprint']}"
            ),
        },
    )

    payload = {
        "status": result["status"],
        "id": result["id"],
        "active_token_id": result["active_token_id"],
        "fingerprint": result["fingerprint"],
        "registry": result["registry"],
        "delivery": "sealed_paste_receive",
    }
    if request_record is not None:
        payload["fulfilled_request"] = request_record.get("request_id", "")
    if json_mode:
        json_dump(payload)
    else:
        print(
            f"sealed receive: {result['status']} {result['id']} "
            f"({result['fingerprint']})"
        )
    return 0


def sealed_request_dir(registry_path: Path) -> Path:
    """Directory holding token-FREE pending sealed-receive requests.

    Sibling to the registry so it inherits the controller-owned, 0700
    secrets-dir contract. The request records carry NO token, but they
    are controller-owned/restricted regardless (they name agent ids and
    a nonce).
    """
    return registry_path.expanduser().parent / "sealed-receive-requests"


def _write_sealed_request_record(
    registry_path: Path, record: dict[str, Any]
) -> Path:
    request_dir = sealed_request_dir(registry_path)
    request_dir.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only - controller secrets-dir sibling of the registry
    os.chmod(request_dir, 0o700)
    path = request_dir / f"{record['request_id']}.json"
    text = json.dumps(record, ensure_ascii=True, indent=2) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=".sealed-req.", suffix=".tmp", dir=str(request_dir))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
        os.chmod(path, 0o600)
        tmp_name = ""
    finally:
        if tmp_name:
            try:
                os.unlink(tmp_name)  # noqa: raw-pathlib-controller-only - controller-side tempfile cleanup in the secrets dir
            except FileNotFoundError:
                pass
    return path


def _cmd_receive_request(
    args: argparse.Namespace, registry_path: Path, json_mode: bool
) -> int:
    """Emit a token-FREE pending sealed-receive request (#1367)."""
    if not args.id:
        return fail("receive --request requires --id <id>", json_mode)
    try:
        validate_token_id(args.id)
    except Exception as exc:
        return fail(str(exc), json_mode)

    agents = ""
    if args.agents is not None:
        agents = str(args.agents).strip()
        # The request record only carries safe slug/csv values. Reject any
        # shell-metachar so the record stays a clean data file.
        if agents and not re.match(r"^[A-Za-z0-9_.,-]+$", agents):
            return fail("--agents must be a safe slug/csv", json_mode)

    request_id = uuid.uuid4().hex
    nonce = uuid.uuid4().hex
    record = {
        "request_id": request_id,
        "id": args.id,
        "nonce": nonce,
        "agents": agents,
        "activate": bool(args.activate),
        "enable_auto_rotate": bool(args.enable_auto_rotate),
        "replace": bool(args.replace),
        "created_at": now_iso(),
        "status": "pending",
    }
    try:
        path = _write_sealed_request_record(registry_path, record)
    except Exception as exc:
        return fail(f"cannot write sealed request record: {exc}", json_mode)

    _sealed_receive_audit(
        "tool_policy_credential_sealed_request",
        {
            "surface": "sealed_paste_request",
            "id": args.id,
            "request_id": request_id,
            "agents": agents,
            "summary": (
                f"sealed request: id={args.id} request_id={request_id} "
                f"agents={agents or '(default)'}"
            ),
        },
    )

    payload = {
        "status": "pending",
        "request_id": request_id,
        "id": args.id,
        "nonce": nonce,
        "agents": agents,
        "activate": bool(args.activate),
        "enable_auto_rotate": bool(args.enable_auto_rotate),
        "replace": bool(args.replace),
        "record": str(path),
        "delivery": "sealed_paste_request",
        "next": (
            "operator: run `bridge-auth.sh claude-token receive "
            f"--id {args.id} --fulfill {request_id}` from an operator terminal"
        ),
    }
    # The request is token-free, so JSON is always safe to emit even when
    # the admin agent requested it (this is the whole point — the agent
    # observes only the redacted request shape).
    if json_mode:
        json_dump(payload)
    else:
        print(
            f"sealed request pending: id={args.id} request_id={request_id}"
        )
    return 0


def _load_and_consume_request(
    registry_path: Path, request_id: str
) -> dict[str, Any]:
    """Load + remove a pending sealed-receive request by id (#1367).

    The fulfill path is operator-driven; this only reconciles the
    request id so the audit row can link request → receive. The token is
    NEVER stored in the request record, so nothing secret is read here.
    """
    if not re.match(r"^[0-9a-f]{32}$", str(request_id or "")):
        raise ValueError("invalid request id")
    path = sealed_request_dir(registry_path) / f"{request_id}.json"
    if not path.is_file():  # noqa: raw-pathlib-controller-only - controller secrets-dir request probe
        raise ValueError(f"no pending sealed request: {request_id}")
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ValueError(f"cannot parse sealed request {request_id}: {exc}") from exc
    try:
        path.unlink()  # noqa: raw-pathlib-controller-only - controller-side consume of the token-free request record
    except OSError:
        pass
    return record if isinstance(record, dict) else {}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", required=True)
    sub = parser.add_subparsers(dest="command", required=True)

    add_parser = sub.add_parser("add")
    add_parser.add_argument("--id", required=True)
    add_parser.add_argument("--stdin", action="store_true")
    add_parser.add_argument("--token-file")
    add_parser.add_argument("--activate", action="store_true")
    add_parser.add_argument("--replace", action="store_true")
    add_parser.add_argument("--note", default="")
    add_parser.add_argument("--enable-auto-rotate", action="store_true")
    add_parser.add_argument("--threshold", type=float)
    add_parser.add_argument("--sync", action="store_true", help=argparse.SUPPRESS)
    add_parser.add_argument("--agents", help=argparse.SUPPRESS)
    add_parser.add_argument("--json", action="store_true")
    add_parser.set_defaults(handler=cmd_add)

    # #1367 — sealed-paste operator-terminal receive. NOTE: there is NO
    # --stdin / --token-file here by design — the ONLY token source is the
    # echo-off read from the controlling tty. A token-FREE request shape
    # (`receive --request`) lets an admin agent initiate the flow.
    receive_parser = sub.add_parser("receive")
    receive_parser.add_argument("--id")
    receive_parser.add_argument(
        "--request",
        action="store_true",
        help="emit a token-FREE pending request record (admin-agent UX) and exit",
    )
    receive_parser.add_argument(
        "--fulfill",
        default=None,
        help="reconcile a pending request id created by --request",
    )
    receive_parser.add_argument("--activate", action="store_true")
    receive_parser.add_argument("--replace", action="store_true")
    receive_parser.add_argument("--note", default="")
    receive_parser.add_argument("--enable-auto-rotate", action="store_true")
    receive_parser.add_argument("--threshold", type=float)
    receive_parser.add_argument("--agents", default=None)
    receive_parser.add_argument("--json", action="store_true")
    receive_parser.set_defaults(handler=cmd_receive)

    list_parser = sub.add_parser("list")
    list_parser.add_argument("--json", action="store_true")
    list_parser.set_defaults(handler=cmd_list)

    activate_parser = sub.add_parser("activate")
    activate_parser.add_argument("id")
    activate_parser.add_argument("--sync", action="store_true", help=argparse.SUPPRESS)
    activate_parser.add_argument("--agents", help=argparse.SUPPRESS)
    activate_parser.add_argument("--json", action="store_true")
    activate_parser.set_defaults(handler=cmd_activate)

    rotate_parser = sub.add_parser("rotate")
    rotate_parser.add_argument("--if-auto-enabled", action="store_true")
    rotate_parser.add_argument("--reason", default="")
    rotate_parser.add_argument("--sync", action="store_true", help=argparse.SUPPRESS)
    rotate_parser.add_argument("--agents", help=argparse.SUPPRESS)
    rotate_parser.add_argument("--json", action="store_true")
    rotate_parser.set_defaults(handler=cmd_rotate)

    check_parser = sub.add_parser("check")
    check_parser.add_argument("id")
    check_parser.add_argument("--enable-on-ok", action="store_true")
    check_parser.add_argument("--disable-on-quota", action="store_true")
    check_parser.add_argument("--timeout", type=int, default=45)
    check_parser.add_argument("--retry-seconds", type=int, default=1800)
    check_parser.add_argument("--json", action="store_true")
    check_parser.set_defaults(handler=cmd_check)

    # #1437 — classify a live cron run's captured output (no network probe).
    classify_parser = sub.add_parser("classify-output")
    classify_parser.add_argument("--stdout-file", default=None)
    classify_parser.add_argument("--stderr-file", default=None)
    classify_parser.add_argument("--returncode", type=int, default=0)
    classify_parser.add_argument("--json", action="store_true", help=argparse.SUPPRESS)
    classify_parser.set_defaults(handler=cmd_classify_output)

    # #1437 — deterministically disable a quota-hit token (inconclusive-check
    # fallback for the reactive cron rotation path).
    mark_quota_parser = sub.add_parser("mark-quota")
    mark_quota_parser.add_argument("id")
    mark_quota_parser.add_argument("--reset-at", default="")
    mark_quota_parser.add_argument("--retry-seconds", type=int, default=1800)
    mark_quota_parser.add_argument("--json", action="store_true")
    mark_quota_parser.set_defaults(handler=cmd_mark_quota)

    recover_parser = sub.add_parser("recover-due")
    recover_parser.add_argument("--timeout", type=int, default=45)
    recover_parser.add_argument("--retry-seconds", type=int, default=1800)
    recover_parser.add_argument("--json", action="store_true")
    recover_parser.set_defaults(handler=cmd_recover_due)

    auto_parser = sub.add_parser("auto-rotate")
    auto_parser.add_argument("action", choices=("enable", "disable", "status"))
    auto_parser.add_argument("--threshold", type=float)
    auto_parser.add_argument("--json", action="store_true")
    auto_parser.set_defaults(handler=cmd_auto_rotate)

    helper_parser = sub.add_parser("api-key-helper")
    helper_parser.add_argument("--check", action="store_true")
    helper_parser.add_argument("--json", action="store_true")
    helper_parser.set_defaults(handler=cmd_api_key_helper)

    sync_parser = sub.add_parser("sync-agent")
    sync_parser.add_argument("--agent", required=True)
    sync_parser.add_argument("--file", required=True)
    # Fleet-credential Phase 1 (#1470): which engine descriptor row this
    # sync runs for. The default is None (NOT DEFAULT_AUTH_ENGINE) so
    # cmd_sync_agent's fail-closed gate can distinguish "--engine omitted"
    # (→ Claude, every existing caller is byte-compatible) from "--engine
    # given an empty string" (→ refused). codex r2 BLOCKING: a literal
    # default of `claude` here combined with `args.engine or DEFAULT` in
    # the gate let an explicit `--engine ""` collapse back to Claude.
    # Phase 2's Codex adapter passes `--engine codex`.
    sync_parser.add_argument("--engine", default=None)
    sync_parser.add_argument("--workdir", action="append", default=[])
    sync_parser.add_argument(
        "--owner-uid",
        type=int,
        default=None,
        help="chown credential/config/settings files to this UID before os.replace (PR #799 r2 atomic chown)",
    )
    sync_parser.add_argument(
        "--owner-gid",
        type=int,
        default=None,
        help="chown credential/config/settings files to this GID before os.replace",
    )
    sync_parser.add_argument(
        "--allowed-root",
        default=None,
        help="require resolved credential dir to stay under this real path (PR #799 r2 symlink hardening)",
    )
    sync_parser.add_argument(
        "--controller-credentials",
        default=None,
        help=(
            "explicit path to the controller's .claude/.credentials.json — used "
            "for the #1075 fallback when no Claude setup-token is registered"
        ),
    )
    sync_parser.add_argument("--json", action="store_true")
    sync_parser.set_defaults(handler=cmd_sync_agent)

    # ── Codex fleet-sync adapter (#1470 Phase 2) ──────────────────────
    # register/sync/verify/source only — Codex has no rotation/recover/
    # activate (descriptor supports_rotation=False). bridge-auth.sh
    # `codex-cred <sub>` resolves iso ownership + source validation, then
    # calls these.
    codex_reg = sub.add_parser("codex-register")
    codex_reg.add_argument("--source", required=True)
    codex_reg.add_argument("--json", action="store_true")
    codex_reg.set_defaults(handler=cmd_codex_register)

    codex_src = sub.add_parser("codex-source")
    codex_src.add_argument("--json", action="store_true")
    codex_src.set_defaults(handler=cmd_codex_source)

    codex_ver = sub.add_parser("codex-verify")
    codex_ver.add_argument("--file", required=True)
    codex_ver.add_argument("--json", action="store_true")
    codex_ver.set_defaults(handler=cmd_codex_verify)

    codex_sync = sub.add_parser("codex-sync")
    codex_sync.add_argument("--agent", required=True)
    codex_sync.add_argument(
        "--source-file",
        required=True,
        help="resolved path/bytes of the source agent's .codex/auth.json (read by the bash layer, via sudo -n -u <owner> cat for iso source)",
    )
    codex_sync.add_argument("--file", required=True, help="dest agent's .codex/auth.json")
    # Engine is fail-closed to codex; default codex so an omitted arg is
    # byte-compatible, but an explicit non-codex value is refused.
    codex_sync.add_argument("--engine", default=None)
    codex_sync.add_argument(
        "--owner-uid",
        type=int,
        default=None,
        help="chown the dest auth.json to this UID before os.replace (iso owner agent-bridge-<a>)",
    )
    codex_sync.add_argument(
        "--owner-gid",
        type=int,
        default=None,
        help="chown the dest auth.json to this GID before os.replace (iso group ab-agent-<a>)",
    )
    codex_sync.add_argument(
        "--force",
        action="store_true",
        help="re-write the dest even when the source digest is unchanged (bypass the idempotent no-op gate)",
    )
    codex_sync.add_argument(
        "--allowed-root",
        default=None,
        help="require the resolved dest .codex dir to stay under this real path (symlinked-parent hardening, mirrors the Claude sync-agent --allowed-root)",
    )
    codex_sync.add_argument("--json", action="store_true")
    codex_sync.set_defaults(handler=cmd_codex_sync)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
