#!/usr/bin/env python3
"""bridge-auth.py - local credential registry helpers for Agent Bridge."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


REGISTRY_VERSION = 1
TOKEN_ENV_KEY = "CLAUDE_CODE_OAUTH_TOKEN"
TOKEN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
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


def shell_single_quote(value: str) -> str:
    if "'" in value:
        raise ValueError("single quotes are not supported in launch secret values")
    return "'" + value + "'"


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
    env = os.environ.copy()
    env[TOKEN_ENV_KEY] = token
    command = [claude_bin, "-p", prompt, "--output-format", "json"]
    try:
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
    try:
        validate_token_id(args.id)
        token = read_token(args)
        registry = load_registry(registry_path)
    except Exception as exc:
        return fail(str(exc), json_mode)

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

    try:
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
    try:
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
    try:
        registry = load_registry(registry_path)
        if args.if_auto_enabled and not bool(registry.get("auto_rotate_enabled", False)):
            payload = {"status": "skipped", "reason": "auto_rotate_disabled"}
            if json_mode:
                json_dump(payload)
            else:
                print("skipped: auto_rotate_disabled")
            return 0
        ids = enabled_token_ids(registry)
        if len(ids) < 2:
            payload = {"status": "skipped", "reason": "no_alternate_token", "active_token_id": registry.get("active_token_id") or ""}
            if json_mode:
                json_dump(payload)
            else:
                print("skipped: no_alternate_token")
            return 0
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
    try:
        registry = load_registry(registry_path)
        row = find_token(registry, args.id)
        if row is None:
            raise ValueError(f"unknown token id: {args.id}")
        token = str(row.get("token") or "")
        validate_token(token)
        probe = probe_claude_token(token, timeout_seconds)
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
        "token": public_token_row(row, active_id),
    }
    if json_mode:
        json_dump(payload)
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
    try:
        registry = load_registry(registry_path)
        active_id = str(registry.get("active_token_id") or "")
        candidates = [row for row in token_rows(registry) if quota_recheck_due(row, reference)]
        for row in candidates:
            token_id = str(row.get("id") or "")
            token = str(row.get("token") or "")
            if not token_id or not token:
                continue
            validate_token(token)
            probe = probe_claude_token(token, timeout_seconds)
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

    payload = {
        "status": "ok" if checked else "skipped",
        "reason": "" if checked else "no_due_tokens",
        "active_token_id": registry.get("active_token_id") or "",
        "checked_count": len(checked),
        "recovered_count": len(recovered),
        "still_disabled_count": len(still_disabled),
        "recovered": recovered,
        "checked": checked,
        "sync_recommended": active_id in recovered,
    }
    if json_mode:
        json_dump(payload)
    else:
        if checked:
            print(f"checked={len(checked)} recovered={len(recovered)} still_disabled={len(still_disabled)}")
        else:
            print("skipped: no_due_tokens")
    return 0


def cmd_auto_rotate(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    try:
        registry = load_registry(registry_path)
        if args.action == "enable":
            registry["auto_rotate_enabled"] = True
            if args.threshold is not None:
                registry["rotation_threshold"] = validate_threshold(args.threshold)
            save_registry(registry_path, registry)
        elif args.action == "disable":
            registry["auto_rotate_enabled"] = False
            save_registry(registry_path, registry)
        elif args.action != "status":
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


def update_launch_secret_file(path: Path, token: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    rendered = f"{TOKEN_ENV_KEY}={shell_single_quote(token)}"
    output: list[str] = []
    replaced = False
    key_prefix = TOKEN_ENV_KEY + "="
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(key_prefix) or line.startswith(key_prefix):
            if not replaced:
                output.append(rendered)
                replaced = True
            continue
        output.append(line)
    if not replaced:
        output.append(rendered)
    text = "\n".join(output) + "\n"
    fd = -1
    tmp_name = ""
    try:
        fd, tmp_name = tempfile.mkstemp(prefix=".launch-secrets.", suffix=".tmp", dir=str(path.parent))
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


def cmd_sync_agent(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    try:
        registry = load_registry(Path(args.registry).expanduser())
        active_id = str(registry.get("active_token_id") or "")
        if not active_id:
            raise ValueError("no active token id")
        row = find_token(registry, active_id)
        if row is None:
            raise ValueError(f"active token id is missing from registry: {active_id}")
        if not bool(row.get("enabled", True)):
            raise ValueError(f"active token id is disabled: {active_id}")
        token = str(row.get("token") or "")
        validate_token(token)
        update_launch_secret_file(Path(args.file).expanduser(), token)
    except Exception as exc:
        return fail(str(exc), json_mode)
    payload = {
        "status": "synced",
        "agent": args.agent,
        "file": str(Path(args.file).expanduser()),
        "active_token_id": active_id,
        "fingerprint": token_fingerprint(token),
    }
    if json_mode:
        json_dump(payload)
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
    sync_parser.add_argument("--json", action="store_true")
    sync_parser.set_defaults(handler=cmd_sync_agent)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
