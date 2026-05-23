#!/usr/bin/env python3
"""bridge-auth.py - local credential registry helpers for Agent Bridge."""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
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
TOKEN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
CLAUDE_OAUTH_EXPIRES_AT_MS = 4102444800000
CLAUDE_OAUTH_SCOPES = ["user:inference", "user:profile"]
CLAUDE_CONFIG_MIGRATION_VERSION = 13
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
    return {
        "claudeAiOauth": {
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

    if api_status_text == "429" or "hit your limit" in lower or "usage limit" in lower:
        return "quota_limited", detail
    if api_status_text in {"401", "403"} or "invalid api key" in lower or "unauthorized" in lower:
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
        with registry_lock(registry_path):
            registry = load_registry(registry_path)

            rows = token_rows(registry)
            existing = find_token(registry, args.id)
            timestamp = now_iso()
            row = {
                "id": args.id,
                "token": token,
                "enabled": True,
                "created_at": timestamp,
                "updated_at": timestamp,
                "last_activated_at": "",
                "note": args.note or "",
            }
            if existing is not None:
                if not args.replace:
                    return fail(f"token id already exists: {args.id}", json_mode)
                row["created_at"] = existing.get("created_at") or timestamp
                row["last_activated_at"] = existing.get("last_activated_at") or ""
                rows[rows.index(existing)] = row
            else:
                rows.append(row)

            if args.activate or not registry.get("active_token_id"):
                registry["active_token_id"] = args.id
                row["last_activated_at"] = timestamp
            if args.enable_auto_rotate:
                registry["auto_rotate_enabled"] = True
            if args.threshold is not None:
                registry["rotation_threshold"] = validate_threshold(args.threshold)

            save_registry(registry_path, registry)
    except Exception as exc:
        return fail(str(exc), json_mode)

    payload = {
        "status": "added" if existing is None else "replaced",
        "id": args.id,
        "active_token_id": registry.get("active_token_id") or "",
        "fingerprint": token_fingerprint(token),
        "registry": str(registry_path),
    }
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


def cmd_sync_agent(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
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
            write_claude_credentials_payload(
                credential_file,
                controller_payload,
                owner_uid=owner_uid,
                owner_gid=owner_gid,
                allowed_root=allowed_root,
            )
            fingerprint = token_fingerprint(
                str(controller_payload["claudeAiOauth"]["accessToken"])
            )
        else:
            write_claude_credentials_file(
                credential_file,
                token,
                owner_uid=owner_uid,
                owner_gid=owner_gid,
                allowed_root=allowed_root,
            )
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
    }
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

    sync_parser = sub.add_parser("sync-agent")
    sync_parser.add_argument("--agent", required=True)
    sync_parser.add_argument("--file", required=True)
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

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
