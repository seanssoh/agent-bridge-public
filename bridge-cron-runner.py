#!/usr/bin/env python3
"""Disposable cron child runner for Agent Bridge."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pwd
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# PR1 (cron inbox-only reporting) — RESULT_SCHEMA carries the structured
# reporting contract. The cron child must NOT send to external channels;
# instead it declares its `delivery_intent` and the runner relays the result
# to the parent agent's inbox. `channel_relay` remains as a deprecated alias
# (audit-warn on use) for one minor; replaced by `delivery_intent` +
# `forward_target` + `summary_short`.
DELIVERY_INTENT_VALUES = ("silent", "main_session_only", "forward_to_user")
FORWARD_CHANNEL_VALUES = ("telegram", "discord", "mattermost")
FORWARD_FORMAT_VALUES = ("markdown", "text")
SUMMARY_SHORT_MAX = 200

# PR1.5 — direct-send marker substrings the LLM should never emit at action
# position (forward_target / summary_short). v1 behaviour: emit a one-line
# `cron_audit` event with up to 80 chars of the offending substring; do NOT
# reject (Sean Q-C 2026-05-02). Hard reject deferred to v2 once we measure
# whether LLMs actually try this.
DIRECT_SEND_MARKERS = (
    "tg_send",
    "telegram_send",
    "discord_send",
    "webhook_url",
    "https://api.telegram.org",
    "https://discord.com/api/webhooks",
    "agb urgent",
    "agb task create",
    "agb task done",
    "agb handoff",
)
MARKER_EXCERPT_LIMIT = 80

RESULT_SCHEMA = {
    "type": "object",
    "properties": {
        "status": {"type": "string"},
        "summary": {"type": "string"},
        "findings": {"type": "array", "items": {"type": "string"}},
        "actions_taken": {"type": "array", "items": {"type": "string"}},
        "needs_human_followup": {"type": "boolean"},
        "recommended_next_steps": {"type": "array", "items": {"type": "string"}},
        "artifacts": {"type": "array", "items": {"type": "string"}},
        "confidence": {"type": "string"},
        "delivery_intent": {
            "type": "string",
            "enum": list(DELIVERY_INTENT_VALUES),
        },
        "forward_target": {
            "type": "object",
            "properties": {
                "channel": {"type": "string", "enum": list(FORWARD_CHANNEL_VALUES)},
                "target_ref": {"type": "string"},
                "format": {"type": "string", "enum": list(FORWARD_FORMAT_VALUES)},
            },
            "required": ["channel", "target_ref", "format"],
            "additionalProperties": False,
        },
        "summary_short": {"type": "string", "maxLength": SUMMARY_SHORT_MAX},
        "channel_relay": {
            "type": "object",
            "properties": {
                "body": {"type": "string"},
                "urgency": {"type": "string"},
                "transport": {"type": "string"},
                "target": {"type": "string"},
                "subject": {"type": "string"},
            },
            "required": ["body"],
            "additionalProperties": False,
        },
    },
    "required": [
        "status",
        "summary",
        "findings",
        "actions_taken",
        "needs_human_followup",
        "recommended_next_steps",
        "artifacts",
        "confidence",
        "delivery_intent",
    ],
    "additionalProperties": False,
}

COMMON_BIN_DIRS = [
    Path.home() / ".local" / "bin",
    Path.home() / ".nix-profile" / "bin",
    Path.home() / "bin",
    Path("/opt/homebrew/bin"),
    Path("/usr/local/bin"),
]
SHELL_RESULT_STATUS_VALUES = {"success", "error"}
SHELL_PAYLOAD_ENV_PREFIXES = ("POLL_", "SCRIPT_")
SHELL_PROTECTED_ENV_EXACT = {"HOME", "PATH"}
SHELL_PROTECTED_ENV_PREFIXES = ("BRIDGE_", "CRON_")


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def bridge_home() -> Path | None:
    value = os.environ.get("BRIDGE_HOME")
    if not value:
        return None
    return Path(value).expanduser().resolve()


def rel_for_output(path_value: str) -> str:
    path = Path(path_value).expanduser().resolve()
    home = bridge_home()
    if home is not None:
        try:
            return str(path.relative_to(home))
        except ValueError:
            pass
    return str(path)


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def run_dir_id(run_dir: Path) -> str:
    return run_dir.name


def mode_has_group_or_other_write(path: Path) -> bool:
    try:
        mode = path.stat().st_mode
    except OSError:
        return True
    return bool(mode & (stat.S_IWGRP | stat.S_IWOTH))


def path_acl_has_write_exposure(path: Path, *, include_default: bool = True) -> bool:
    getfacl = shutil.which("getfacl")
    if not getfacl:
        return False
    try:
        completed = subprocess.run(
            [getfacl, "-cp", str(path)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return False
    if completed.returncode != 0:
        return False
    for raw_line in completed.stdout.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split(":")
        is_default = fields[0] == "default"
        if is_default and not include_default:
            continue
        if is_default:
            fields = fields[1:]
        if len(fields) < 3:
            continue
        tag, qualifier, perms = fields[0], fields[1], fields[2]
        effective = perms
        if "#effective:" in line:
            effective = line.rsplit("#effective:", 1)[1].strip()
        if tag == "user" and qualifier == "":
            continue
        if tag in {"user", "group", "mask", "other"} and "w" in effective:
            if tag == "mask":
                continue
            return True
    return False


def validate_shell_request_artifacts(request_file: Path) -> tuple[bool, str | None]:
    run_dir = request_file.parent
    controller_uid = os.getuid()
    for path in (run_dir, request_file):
        try:
            st = path.stat()
        except OSError as exc:
            return False, f"request_artifact_tampered: stat failed for {path}: {exc}"
        if st.st_uid != controller_uid:
            return False, f"request_artifact_tampered: owner uid mismatch for {path}"
        if mode_has_group_or_other_write(path):
            return False, f"request_artifact_tampered: group/other writable mode on {path}"
        if path_acl_has_write_exposure(path, include_default=path.is_dir()):
            return False, f"request_artifact_tampered: ACL write exposure on {path}"
    return True, None


def truncate_output(data: bytes, cap: int) -> tuple[str, bool]:
    if len(data) <= cap:
        return data.decode("utf-8", errors="replace"), False
    truncated = data[:cap].decode("utf-8", errors="replace")
    return truncated + f"\n[agent-bridge] output truncated at {cap} bytes\n", True


def cron_state_dir_from_env(run_dir: Path) -> Path:
    value = os.environ.get("BRIDGE_CRON_STATE_DIR")
    if value:
        return Path(value).expanduser().resolve()
    return run_dir.parent.parent


def shell_payload_env(payload: dict[str, Any]) -> dict[str, str]:
    env = payload.get("env") or {}
    if not isinstance(env, dict):
        raise ValueError("payload.env must be an object")
    clean: dict[str, str] = {}
    for raw_key, raw_value in env.items():
        key = str(raw_key)
        if key in SHELL_PROTECTED_ENV_EXACT or key.startswith(SHELL_PROTECTED_ENV_PREFIXES):
            raise ValueError(f"protected env var cannot be set by shell cron payload: {key}")
        if not key.startswith(SHELL_PAYLOAD_ENV_PREFIXES):
            raise ValueError(f"shell cron env var must start with POLL_ or SCRIPT_: {key}")
        clean[key] = str(raw_value)
    return clean


def shell_command_for_execution(execution: dict[str, Any], env: dict[str, str], script: str, args: list[str]) -> list[str]:
    os_user = str(execution.get("os_user") or "")
    uid = int(execution.get("uid"))
    gid = int(execution.get("gid"))
    env_parts = [f"{key}={value}" for key, value in sorted(env.items())]
    current_uid = os.geteuid()
    try:
        current_name = pwd.getpwuid(current_uid).pw_name
    except KeyError:
        current_name = ""
    if current_uid == uid and (not os_user or os_user == current_name):
        return ["env", "-i", *env_parts, script, *args]
    sudo = shutil.which("sudo")
    if sudo and os_user:
        return [sudo, "-n", "-H", "-u", os_user, "env", "-i", *env_parts, script, *args]
    setpriv = shutil.which("setpriv")
    if setpriv:
        return [setpriv, "--reuid", str(uid), "--regid", str(gid), "--init-groups", "env", "-i", *env_parts, script, *args]
    raise RuntimeError("no supported UID drop helper found (sudo or setpriv)")


def redact_shell_command(command: list[str]) -> list[str]:
    redacted: list[str] = []
    for part in command:
        if "=" in part and not part.startswith(("/", "./")):
            key = part.split("=", 1)[0]
            if key and all(ch.isalnum() or ch == "_" for ch in key):
                redacted.append(f"{key}=<redacted>")
                continue
        redacted.append(part)
    return redacted


def write_shell_status(
    status_file: Path,
    *,
    run_id: str,
    state: str,
    request_file: Path,
    result_file: Path,
    started_at: str | None = None,
    completed_at: str | None = None,
    duration_ms: int | None = None,
    exit_code: int | None = None,
    runner_error: str | None = None,
) -> None:
    payload: dict[str, Any] = {
        "run_id": run_id,
        "state": state,
        "engine": "shell",
        "updated_at": now_iso(),
        "request_file": str(request_file),
        "result_file": str(result_file),
        "delivery_intent": "silent",
        "reporting_decision": "silent",
    }
    if started_at:
        payload["started_at"] = started_at
    if completed_at:
        payload["completed_at"] = completed_at
    if duration_ms is not None:
        payload["duration_ms"] = duration_ms
    if exit_code is not None:
        payload["exit_code"] = exit_code
    if runner_error:
        payload["runner_error"] = runner_error
        payload["error"] = runner_error
    write_json(status_file, payload)


def write_shell_result(
    result_file: Path,
    *,
    run_id: str,
    status: str,
    summary: str,
    request_file: Path,
    stdout_log: Path,
    stderr_log: Path,
    started_at: str | None = None,
    completed_at: str | None = None,
    duration_ms: int | None = None,
    exit_code: int | None = None,
    runner_error: str | None = None,
    command: list[str] | None = None,
    stdout_truncated: bool = False,
    stderr_truncated: bool = False,
) -> None:
    if status not in SHELL_RESULT_STATUS_VALUES:
        status = "error"
    payload: dict[str, Any] = {
        "run_id": run_id,
        "engine": "shell",
        "status": status,
        "summary": summary,
        "findings": [],
        "actions_taken": [],
        "needs_human_followup": False,
        "recommended_next_steps": [],
        "artifacts": [str(stdout_log), str(stderr_log)],
        "confidence": "high" if status == "success" else "medium",
        "delivery_intent": "silent",
        "reporting_decision": "silent",
        "request_file": str(request_file),
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
        "stdout_truncated": stdout_truncated,
        "stderr_truncated": stderr_truncated,
    }
    if started_at:
        payload["started_at"] = started_at
    if completed_at:
        payload["completed_at"] = completed_at
    if duration_ms is not None:
        payload["duration_ms"] = duration_ms
    if exit_code is not None:
        payload["child_exit_code"] = exit_code
    if runner_error:
        payload["runner_error"] = runner_error
    if command:
        safe_command = redact_shell_command(command)
        payload["command"] = safe_command
        payload["command_pretty"] = " ".join(shlex.quote(part) for part in safe_command)
    write_json(result_file, payload)


def normalize_result(payload: dict[str, Any]) -> dict[str, Any]:
    result = dict(payload)
    result.setdefault("findings", [])
    result.setdefault("actions_taken", [])
    result.setdefault("needs_human_followup", False)
    result.setdefault("recommended_next_steps", [])
    result.setdefault("artifacts", [])
    result.setdefault("confidence", "medium")
    return result


def normalize_channel_relay(value: Any) -> dict[str, str] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("channel_relay must be an object when present")

    allowed = {"body", "urgency", "transport", "target", "subject"}
    extras = sorted(set(value.keys()) - allowed)
    if extras:
        raise ValueError(f"channel_relay contains unsupported fields: {', '.join(extras)}")

    body = str(value.get("body", "")).strip()
    if not body:
        raise ValueError("channel_relay.body must be a non-empty string")

    relay = {"body": body}
    for key in ("urgency", "transport", "target", "subject"):
        raw = value.get(key)
        if raw is None:
            continue
        text = str(raw).strip()
        if text:
            relay[key] = text
    return relay


def normalize_forward_target(value: Any) -> dict[str, str] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("forward_target must be an object when present")
    allowed = {"channel", "target_ref", "format"}
    extras = sorted(set(value.keys()) - allowed)
    if extras:
        raise ValueError(f"forward_target contains unsupported fields: {', '.join(extras)}")
    channel = str(value.get("channel", "")).strip().lower()
    if channel not in FORWARD_CHANNEL_VALUES:
        raise ValueError(
            f"forward_target.channel must be one of {', '.join(FORWARD_CHANNEL_VALUES)}; got {channel!r}"
        )
    target_ref = str(value.get("target_ref", "")).strip()
    if not target_ref:
        raise ValueError("forward_target.target_ref must be a non-empty string")
    fmt = str(value.get("format", "")).strip().lower()
    if fmt not in FORWARD_FORMAT_VALUES:
        raise ValueError(
            f"forward_target.format must be one of {', '.join(FORWARD_FORMAT_VALUES)}; got {fmt!r}"
        )
    return {"channel": channel, "target_ref": target_ref, "format": fmt}


def detect_direct_send_markers(result: dict[str, Any]) -> list[dict[str, str]]:
    """Return one entry per detected direct-send marker at action position.

    PR1.5 (Sean Q-C 2026-05-02): v1 logs only — no rejection. We sample only
    `forward_target.target_ref` and `summary_short` because legitimate cron
    bodies frequently quote URLs/IDs in narrative text. Markers found in
    `summary` or `findings` would create false-positives.
    """
    detections: list[dict[str, str]] = []
    sources: list[tuple[str, str]] = []
    forward_target = result.get("forward_target") or {}
    if isinstance(forward_target, dict):
        ref = str(forward_target.get("target_ref") or "")
        if ref:
            sources.append(("forward_target.target_ref", ref))
    summary_short = str(result.get("summary_short") or "")
    if summary_short:
        sources.append(("summary_short", summary_short))
    for field, text in sources:
        lowered = text.lower()
        for marker in DIRECT_SEND_MARKERS:
            idx = lowered.find(marker)
            if idx < 0:
                continue
            start = max(0, idx - 8)
            excerpt = text[start : start + MARKER_EXCERPT_LIMIT]
            detections.append({"field": field, "marker": marker, "excerpt": excerpt})
    return detections


def validate_result(payload: dict[str, Any]) -> dict[str, Any]:
    result = normalize_result(payload)
    missing = [key for key in RESULT_SCHEMA["required"] if key not in result]
    if missing:
        raise ValueError(f"result missing required fields: {', '.join(missing)}")
    if not isinstance(result["summary"], str) or not result["summary"].strip():
        raise ValueError("result summary must be a non-empty string")

    intent = str(result.get("delivery_intent") or "").strip()
    if intent not in DELIVERY_INTENT_VALUES:
        raise ValueError(
            f"delivery_intent must be one of {', '.join(DELIVERY_INTENT_VALUES)}; got {intent!r}"
        )
    result["delivery_intent"] = intent

    forward_target = normalize_forward_target(result.get("forward_target"))
    if intent == "forward_to_user":
        if forward_target is None:
            raise ValueError("forward_target is required when delivery_intent=forward_to_user")
        result["forward_target"] = forward_target
    else:
        # Drop forward_target on silent / main_session_only — it's meaningless
        # and would otherwise confuse the parent's routing.
        result.pop("forward_target", None)

    summary_short_raw = result.get("summary_short")
    if intent == "silent":
        # Empty / unset is fine. Anything non-empty is silently dropped so a
        # cron child can fill it without breaking the silent contract.
        result.pop("summary_short", None)
    else:
        if summary_short_raw is None:
            raise ValueError(
                f"summary_short is required when delivery_intent={intent}"
            )
        text = str(summary_short_raw).strip()
        if not text:
            raise ValueError(
                f"summary_short must be a non-empty string when delivery_intent={intent}"
            )
        if len(text) > SUMMARY_SHORT_MAX:
            raise ValueError(
                f"summary_short exceeds {SUMMARY_SHORT_MAX} chars (was {len(text)})"
            )
        result["summary_short"] = text

    relay = normalize_channel_relay(result.get("channel_relay"))
    if relay is not None:
        result["channel_relay"] = relay
        result["needs_human_followup"] = True
    else:
        result.pop("channel_relay", None)
    return result


def csv_items(raw: str) -> list[str]:
    values: list[str] = []
    seen: set[str] = set()
    for chunk in str(raw or "").split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        values.append(item)
    return values


def channel_enabled(channels: list[str], prefix: str) -> bool:
    return any(item == prefix or item.startswith(f"{prefix}@") for item in channels)


def bool_flag(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return bool(value)


def disposable_needs_channels(request: dict[str, Any]) -> bool:
    return bool_flag(request.get("disposable_needs_channels"))


# Issue #263 Track B — pre-flight memory guard for the disposable child spawn.
# The actual subprocess.run() of the Claude CLI cold-loads the binary plus
# every wired MCP server. On a pressured host that cold-load is what tips
# `event-reminder-30min` past its 1800s timeout. We probe vm.swapusage on
# Darwin and /proc/meminfo MemAvailable on Linux, returning True only when
# we have positive evidence the host is constrained. Any probe glitch is
# treated as "healthy" so a scheduling pass never wedges on a transient.
DEFAULT_SWAP_PCT_LIMIT = 80
DEFAULT_MIN_AVAIL_MB = 512
PRESSURE_DEFER_SECONDS = 900  # +15 min

# Issue #397: macOS uses a pressure tier as its real signal. The kernel
# exposes `kern.memorystatus_vm_pressure_level` with the following values
# (per <sys/kern_memorystatus.h>):
#   1 = Normal (no pressure)
#   2 = Warn   (Activity Monitor "yellow")
#   4 = Critical (Activity Monitor "red"; jetsam imminent)
# We default to deferring only when level >= Warn (>= 2). swap_pct on
# darwin is NOT a pressure signal — macOS uses swap as a normal tier of
# the memory hierarchy, so a laptop sitting at 90%+ swap can be
# perfectly healthy. Operators on hosts where the kernel sysctl isn't
# available can fall back to the legacy swap_pct probe via
# BRIDGE_CRON_DARWIN_PRESSURE_FALLBACK=swap_pct.
DEFAULT_DARWIN_PRESSURE_LEVEL = 2  # Warn


def _swap_pct_limit() -> int:
    raw = os.environ.get("BRIDGE_CRON_SWAP_PCT_LIMIT", "").strip()
    if not raw:
        return DEFAULT_SWAP_PCT_LIMIT
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_SWAP_PCT_LIMIT
    return value if value > 0 else DEFAULT_SWAP_PCT_LIMIT


def _darwin_pressure_level_limit() -> int:
    raw = os.environ.get("BRIDGE_CRON_DARWIN_PRESSURE_LEVEL", "").strip()
    if not raw:
        return DEFAULT_DARWIN_PRESSURE_LEVEL
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_DARWIN_PRESSURE_LEVEL
    return value if value in (2, 4) else DEFAULT_DARWIN_PRESSURE_LEVEL


def _min_avail_mb() -> int:
    raw = os.environ.get("BRIDGE_CRON_MIN_AVAIL_MB", "").strip()
    if not raw:
        return DEFAULT_MIN_AVAIL_MB
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_MIN_AVAIL_MB
    return value if value > 0 else DEFAULT_MIN_AVAIL_MB


def check_memory_pressure() -> dict[str, Any] | None:
    """Return a probe dict when the host is pressured, else None.

    The dict is shaped for direct merge into audit / status / notify payloads:
      {"reason": "memory_pressure", "kind": "darwin"|"linux",
       "metric": "<name>", "value": <int>, "limit": <int>}
    """
    kind = "unknown"
    try:
        kind = (subprocess.check_output(["uname", "-s"], text=True) or "").strip().lower()
    except (OSError, subprocess.SubprocessError):
        return None

    if kind == "darwin":
        # Issue #397: probe the kernel pressure tier rather than swap_pct.
        # macOS swaps as part of normal operation; a host at 90%+ swap can
        # still report Normal pressure level when the OS is healthy. The
        # legacy swap_pct probe stays available as a deliberate fallback
        # via BRIDGE_CRON_DARWIN_PRESSURE_FALLBACK=swap_pct (and is the
        # ONLY way to fire on hosts where the sysctl is unreadable, e.g.
        # sandboxed test environments).
        fallback = (
            os.environ.get("BRIDGE_CRON_DARWIN_PRESSURE_FALLBACK", "").strip().lower()
        )
        if fallback != "swap_pct":
            try:
                level_raw = subprocess.check_output(
                    ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
                    text=True,
                    timeout=5,
                ).strip()
            except (OSError, subprocess.SubprocessError):
                # Sysctl not available (older macOS / sandboxed env) — fall
                # through to the legacy swap-based probe so the host still
                # has *some* pressure signal rather than zero.
                level_raw = ""
            if level_raw:
                try:
                    level = int(level_raw)
                except ValueError:
                    level = 0
                limit = _darwin_pressure_level_limit()
                if level >= limit:
                    return {
                        "reason": "memory_pressure",
                        "kind": "darwin",
                        "metric": "pressure_level",
                        "value": level,
                        "limit": limit,
                    }
                # Healthy path on darwin — sysctl read OK, level below
                # threshold. Skip the swap probe entirely; swap usage on
                # macOS is not a pressure signal.
                return None
        # Either operator opted into the legacy swap probe, or the
        # sysctl was unreadable. Fall through to the original swap_pct
        # path so we still defer on hosts where pressure_level isn't
        # available.
        try:
            usage_line = subprocess.check_output(
                ["sysctl", "-n", "vm.swapusage"], text=True, timeout=5
            ).strip()
        except (OSError, subprocess.SubprocessError):
            return None
        if not usage_line:
            return None
        # Format: "total = 4096.00M  used = 3500.00M  free = 596.00M  (encrypted)"
        tokens = usage_line.split()
        used_raw = total_raw = None
        for idx, token in enumerate(tokens):
            if token == "used" and idx + 2 < len(tokens):
                used_raw = tokens[idx + 2]
            elif token == "total" and idx + 2 < len(tokens):
                total_raw = tokens[idx + 2]
        if not used_raw or not total_raw:
            return None
        try:
            used_mb = float(used_raw.rstrip("M"))
            total_mb = float(total_raw.rstrip("M"))
        except ValueError:
            return None
        if total_mb <= 0:
            return None
        pct = int(used_mb * 100 / total_mb)
        limit = _swap_pct_limit()
        if pct >= limit:
            return {
                "reason": "memory_pressure",
                "kind": "darwin",
                "metric": "swap_pct",
                "value": pct,
                "limit": limit,
                "swap_used_mb": int(used_mb),
                "swap_total_mb": int(total_mb),
            }
        return None

    if kind == "linux":
        meminfo_path = Path("/proc/meminfo")
        if not meminfo_path.is_file():
            return None
        try:
            text = meminfo_path.read_text(encoding="utf-8")
        except OSError:
            return None
        avail_kb: int | None = None
        for line in text.splitlines():
            if line.startswith("MemAvailable:"):
                parts = line.split()
                if len(parts) >= 2 and parts[1].isdigit():
                    avail_kb = int(parts[1])
                break
        if avail_kb is None:
            return None
        threshold_mb = _min_avail_mb()
        threshold_kb = threshold_mb * 1024
        if avail_kb < threshold_kb:
            return {
                "reason": "memory_pressure",
                "kind": "linux",
                "metric": "available_mb",
                "value": avail_kb // 1024,
                "limit": threshold_mb,
            }
        return None

    # Other platforms: no probe; assume healthy.
    return None


def emit_pressure_audit(run_id: str, target_agent: str, probe: dict[str, Any]) -> None:
    """Best-effort audit row for a deferred dispatch. Failure is non-fatal."""
    emit_audit_row(
        action="cron_dispatch_deferred",
        actor="daemon",
        target_agent=target_agent or "daemon",
        run_id=run_id,
        details=probe,
    )


def emit_audit_row(
    *,
    action: str,
    actor: str,
    target_agent: str,
    run_id: str,
    details: dict[str, Any],
) -> None:
    """Best-effort one-line audit emission via bridge-audit.py.

    Failure is non-fatal: if BRIDGE_AUDIT_LOG is unset or the helper script
    is missing, we silently skip. The cron run itself must not be blocked
    on audit plumbing.
    """
    audit_log = os.environ.get("BRIDGE_AUDIT_LOG")
    if not audit_log:
        return
    audit_script = Path(__file__).resolve().parent / "bridge-audit.py"
    if not audit_script.is_file():
        return
    cmd = [
        sys.executable,
        str(audit_script),
        "write",
        "--file",
        audit_log,
        "--actor",
        actor,
        "--action",
        action,
        "--target",
        target_agent or "daemon",
        "--detail",
        f"run_id={run_id}",
    ]
    for key, value in details.items():
        cmd.extend(["--detail", f"{key}={value}"])
    try:
        subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


def emit_legacy_key_audit(request: dict[str, Any], run_id: str, *, target_agent: str) -> None:
    """PR1.3 + PR1.4 + PR1.10 — one-line audit when a job still wires the
    deprecated `allow_channel_delivery`, `disposable_needs_channels`, or
    `payload_kind=agentTurn`. The runner honors none of these for behavior;
    the audit gives operators a way to find and remove them.

    Codex r1 P2 — `lib/bridge-cron.sh` writes both `allow_channel_delivery`
    and `allow_structured_relay` for every request as a false-default
    alias, so flagging on key-presence alone fires for normal no-relay
    jobs. We now flag only the legacy enable-asymmetry: legacy key truthy
    AND new key falsy (i.e., a request that opted into the deprecated
    behavior without the new equivalent). Same logic for the other two:
    only flag when the value is genuinely truthy / agentTurn-shaped.
    """
    flagged: list[str] = []
    if bool_flag(request.get("allow_channel_delivery")) and not bool_flag(request.get("allow_structured_relay")):
        flagged.append("allow_channel_delivery")
    if bool_flag(request.get("disposable_needs_channels")):
        flagged.append("disposable_needs_channels")
    if str(request.get("payload_kind") or "").strip().lower() == "agentturn":
        flagged.append("payload_kind=agentTurn")
    if not flagged:
        return
    emit_audit_row(
        action="cron_legacy_key_used",
        actor="cron-runner",
        target_agent=target_agent,
        run_id=run_id,
        details={"keys": ",".join(flagged)},
    )


def apply_reporting_policy(result: dict[str, Any], policy: str) -> tuple[dict[str, Any], str | None]:
    """PR1.2 — Per-job override on delivery_intent.

    Returns (possibly-mutated result, override_note). override_note is None
    when the policy did not change the intent, otherwise a short string
    describing the demotion ("forced_silent", "demoted_forward_to_main", …)
    suitable for cron_audit details.
    """
    if policy == "default":
        return result, None
    intent = str(result.get("delivery_intent") or "").strip()
    if policy == "always_silent" and intent != "silent":
        result = dict(result)
        result["delivery_intent"] = "silent"
        result.pop("forward_target", None)
        result.pop("summary_short", None)
        return result, f"forced_silent_from_{intent}"
    if policy == "always_main_session" and intent != "main_session_only":
        result = dict(result)
        result["delivery_intent"] = "main_session_only"
        result.pop("forward_target", None)
        # Preserve summary_short if the child set one — still useful as a
        # main-session digest. The main_session_only path requires it; if
        # missing, fall back to the long summary truncated.
        if not str(result.get("summary_short") or "").strip():
            short = str(result.get("summary") or "")[:SUMMARY_SHORT_MAX].strip()
            if short:
                result["summary_short"] = short
        return result, f"forced_main_session_from_{intent}"
    return result, None


def cron_followup_title(job_name: str, intent: str, run_id: str) -> str:
    """PR1.6 dedupe-friendly title.

    `main_session_only` collapses to `[cron-followup] <job> [main_session_only]`
    so refresh-by-job dedupe (PR1.7) works on a stable prefix.
    `forward_to_user` carries the run_id so each distinct alert is unique
    and the per-run lookup mode never collapses two alerts.
    """
    safe_job = job_name or "cron"
    if intent == "forward_to_user":
        return f"[cron-followup] {safe_job} (run={run_id})"
    return f"[cron-followup] {safe_job} [{intent}]"


def write_followup_body(
    body_path: Path,
    *,
    schema_version: int,
    run_id: str,
    job_id: str,
    job_name: str,
    family: str,
    target_agent: str,
    delivery_intent: str,
    forward_target: dict[str, str] | None,
    summary_short: str,
    summary: str,
    findings: list[str],
    actions_taken: list[str],
    recommended_next_steps: list[str],
    artifacts: list[str],
    reporting_policy_value: str,
    structured_relay_legacy: bool,
) -> None:
    """PR1.6 — strict JSON-frontmatter body (parsed without PyYAML).

    Frontmatter shape is part of the contract; PR2 will add a parser helper
    in `lib/bridge_cron_followup.py` that consumes it.
    """
    frontmatter = {
        "schema_version": schema_version,
        "kind": "cron-followup",
        "delivery_intent": delivery_intent,
        "run_id": run_id,
        "job_id": job_id,
        "job_name": job_name,
        "family": family,
        "target_agent": target_agent,
        "reporting_policy": reporting_policy_value,
    }
    if forward_target:
        frontmatter["forward_target"] = forward_target
    if summary_short:
        frontmatter["summary_short"] = summary_short
    if structured_relay_legacy:
        frontmatter["legacy_structured_relay"] = True

    lines = [
        "---",
        json.dumps(frontmatter, ensure_ascii=False, indent=2),
        "---",
        "",
        f"# [cron-followup] {job_name or run_id}",
        "",
        f"- run_id: {run_id}",
        f"- job: {job_name}",
        f"- family: {family}",
        f"- delivery_intent: {delivery_intent}",
    ]
    if summary_short:
        lines.append(f"- summary_short: {summary_short}")
    if forward_target:
        lines.extend(
            [
                f"- forward_target.channel: {forward_target.get('channel', '')}",
                f"- forward_target.target_ref: {forward_target.get('target_ref', '')}",
                f"- forward_target.format: {forward_target.get('format', '')}",
            ]
        )

    if summary.strip():
        lines.extend(["", "## Summary", "", summary.rstrip()])

    for label, items in (
        ("Findings", findings),
        ("Actions Taken", actions_taken),
        ("Recommended Next Steps", recommended_next_steps),
        ("Artifacts", artifacts),
    ):
        if items:
            lines.extend(["", f"## {label}", ""])
            for item in items:
                lines.append(f"- {item}")

    if delivery_intent == "main_session_only":
        lines.extend(
            [
                "",
                "## Action Required (main session)",
                "",
                "Absorb the above into your context. Update your mental model of this monitor.",
                "Close this task with `agb done <id> --note 'absorbed'` or equivalent.",
                "Do NOT forward to a user-facing channel — this run did not opt into user delivery.",
            ]
        )
    elif delivery_intent == "forward_to_user":
        lines.extend(
            [
                "",
                "## Action Required (forward to user)",
                "",
                "Forward the summary above through your own channel plugin (telegram/discord/mattermost).",
                "Resolve `forward_target.target_ref` against your routing config.",
                "Close this task with `agb done <id> --note 'forwarded ts=...'`.",
            ]
        )

    body_path.parent.mkdir(parents=True, exist_ok=True)
    body_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def queue_cli_path() -> Path:
    return Path(__file__).resolve().parent / "bridge-queue.py"


def find_open_followup_task(
    *, target_agent: str, title_prefix: str, mode: str
) -> int | None:
    """Invoke bridge-queue.py find-open. Returns task_id or None.

    `mode` is `refresh-by-job` (existing prefix lookup) or `per-run`
    (always returns None — the caller will create a fresh task). PR1.7
    extends bridge-queue.py with a `--mode` selector that returns nothing
    for `per-run`, so this wrapper stays consistent with that contract.
    """
    if mode == "per-run":
        return None
    cmd = [
        sys.executable,
        str(queue_cli_path()),
        "find-open",
        "--agent",
        target_agent,
        "--title-prefix",
        title_prefix,
        "--mode",
        mode,
        "--format",
        "id",
    ]
    try:
        completed = subprocess.run(
            cmd, capture_output=True, text=True, timeout=15, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    text = completed.stdout.strip()
    if not text:
        return None
    try:
        return int(text)
    except ValueError:
        return None


def queue_create_task(
    *,
    target_agent: str,
    actor: str,
    title: str,
    body_path: Path,
    priority: str,
) -> int | None:
    cmd = [
        sys.executable,
        str(queue_cli_path()),
        "create",
        "--to",
        target_agent,
        "--from",
        actor,
        "--title",
        title,
        "--priority",
        priority,
        "--body-file",
        str(body_path),
        "--format",
        "shell",
    ]
    try:
        completed = subprocess.run(
            cmd, capture_output=True, text=True, timeout=20, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    for line in completed.stdout.splitlines():
        if line.startswith("TASK_ID="):
            try:
                return int(line.split("=", 1)[1].strip().strip("'\""))
            except ValueError:
                return None
    return None


def queue_update_task(
    *,
    task_id: int,
    actor: str,
    title: str,
    body_path: Path,
    priority: str,
    note: str,
) -> bool:
    cmd = [
        sys.executable,
        str(queue_cli_path()),
        "update",
        str(task_id),
        "--actor",
        actor,
        "--title",
        title,
        "--priority",
        priority,
        "--body-file",
        str(body_path),
        "--note",
        note,
    ]
    try:
        completed = subprocess.run(
            cmd, capture_output=True, text=True, timeout=20, check=False
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return completed.returncode == 0


def upsert_inbox_task(
    *,
    target_agent: str,
    actor: str,
    title: str,
    body_path: Path,
    priority: str,
    intent: str,
    job_name: str,
) -> tuple[int | None, str]:
    """Create or refresh the inbox task per PR1.7 dedupe semantics.

    Returns (task_id_or_none, action) where action is one of
    `created | refreshed | failed`.
    """
    if intent == "main_session_only":
        prefix = f"[cron-followup] {job_name or 'cron'} [main_session_only]"
        existing = find_open_followup_task(
            target_agent=target_agent,
            title_prefix=prefix,
            mode="refresh-by-job",
        )
        if existing is not None:
            ok = queue_update_task(
                task_id=existing,
                actor=actor,
                title=title,
                body_path=body_path,
                priority=priority,
                note=f"refreshed by cron-runner (intent={intent})",
            )
            return (existing if ok else None, "refreshed" if ok else "failed")
    task_id = queue_create_task(
        target_agent=target_agent,
        actor=actor,
        title=title,
        body_path=body_path,
        priority=priority,
    )
    return (task_id, "created" if task_id is not None else "failed")


def disable_mcp_for_request(request: dict[str, Any]) -> bool:
    """PR1.3 — cron child runs in `--strict-mcp-config` mode unconditionally.

    Pre-PR1 logic gated MCP loading on `disposable_needs_channels` /
    `BRIDGE_CRON_DISPOSABLE_DISABLE_MCP` / `metadata.disableMcp`. Post-PR1
    that gating is gone: the cron child can no longer reach external
    channels, so there is nothing for MCP plugins to do here, and loading
    them risks the singleton-lock collisions that #468 worked around.
    The legacy keys are still honored as audit-only signals — see
    `cmd_run` for the audit-warn emit when a job sets them.
    """
    del request  # signature retained for callers / future per-job opt-in
    return True


def read_structured_relay_flag(request: dict[str, Any]) -> bool:
    """PR1.4 — `allow_structured_relay` is the new name. The old key
    `allow_channel_delivery` is honored for one minor as an alias; callers
    that still emit it get an audit-warn path in cmd_run.
    """
    if "allow_structured_relay" in request:
        return bool_flag(request.get("allow_structured_relay"))
    return bool_flag(request.get("allow_channel_delivery"))


def reporting_policy(request: dict[str, Any]) -> str:
    """PR1.2 — per-job override on the default-silent policy. Allowed:
    `default | always_main_session | always_silent` (Sean Q-B). Anything
    else falls back to `default` and is audit-warned upstream.
    """
    raw = str(request.get("cron_reporting_policy") or request.get("reporting_policy") or "default").strip().lower()
    if raw not in {"default", "always_main_session", "always_silent"}:
        return "default"
    return raw


def build_prompt(request: dict[str, Any], payload_text: str) -> str:
    parent_agent = request.get("target_agent", "")
    parent_engine = request.get("target_engine", "")
    policy = reporting_policy(request)
    structured_relay = read_structured_relay_flag(request)

    # PR1.2 — Policy preamble. The cron child cannot reach external channels
    # (PR1.3 strips MCP plugins; the runner rejects results that lack a
    # delivery_intent). The child decides intent here; the runner relays it
    # to the parent's inbox.
    lines: list[str] = [
        "You are a disposable cron execution worker for Agent Bridge.",
        "",
        "## Reporting policy (binding — overrides any legacy operator prompt below)",
        "",
        "- This run has NO access to Discord, Telegram, Mattermost, email, or any human channel.",
        "- Do NOT call agb urgent / agb task create / agb task done / agb handoff for delivery.",
        "- Do NOT call message/reply/send tools or post to webhook URLs.",
        "- Decide a `delivery_intent` and return it in the JSON result. Allowed values:",
        "    - `silent` — default. The work was done; the parent does not need to be told. No inbox task is created.",
        "    - `main_session_only` — the parent agent must absorb this into context. No user-facing send. The parent updates its mental model and closes the inbox task.",
        "    - `forward_to_user` — the run produced a human-facing alert. The parent will forward it through its own first-party channel plugin.",
        f"- Pick `silent` when routine monitoring has no material change. Pick `main_session_only` only when the parent must know something. Pick `forward_to_user` only when a human must see it.",
        f"- Parent agent (= main session): `{parent_agent}` ({parent_engine}).",
        "",
        "## Required JSON fields (in addition to the schema's existing keys)",
        "",
        "- `delivery_intent`: one of `silent | main_session_only | forward_to_user`. Required.",
        "- `summary_short`: ≤ 200 chars, operator-facing summary. Required when `delivery_intent != silent`.",
        "- `forward_target`: required when `delivery_intent = forward_to_user`. Object with:",
        "    - `channel`: one of `telegram | discord | mattermost`.",
        "    - `target_ref`: a logical target name (NOT a chat id, NOT a webhook URL). The parent resolves it against its own routing config.",
        "    - `format`: `markdown` or `text`.",
        "- For `silent`, leave `summary_short` empty/unset and do not set `forward_target`.",
    ]

    if policy == "always_silent":
        lines.extend(
            [
                "",
                "## Per-job override",
                "",
                "- This job's reporting_policy is `always_silent`. Choose `delivery_intent = silent` regardless of what you find unless the run itself errored.",
            ]
        )
    elif policy == "always_main_session":
        lines.extend(
            [
                "",
                "## Per-job override",
                "",
                "- This job's reporting_policy is `always_main_session`. Choose `delivery_intent = main_session_only` so the parent always receives a heartbeat-style update.",
            ]
        )

    if structured_relay:
        lines.extend(
            [
                "",
                "## Legacy structured relay (deprecated)",
                "",
                "- This job opted into the legacy `channel_relay` field. You MAY still populate it, but `delivery_intent` + `forward_target` is the authoritative contract going forward.",
                "- If you set `channel_relay`, also set `delivery_intent = forward_to_user` and a matching `forward_target` so the parent can route consistently.",
            ]
        )

    lines.extend(
        [
            "",
            "## Run metadata",
            "",
            f"- Job: {request.get('job_name', '')}",
            f"- Family: {request.get('family', '')}",
            f"- Slot: {request.get('slot', '')}",
            f"- Run ID: {request.get('run_id', '')}",
            f"- Payload file: {request.get('payload_file', '')}",
            "",
            "## Operator prompt (scoped task — runs under the policy above)",
            "",
            payload_text.rstrip(),
            "",
            "Return JSON only matching the provided schema.",
        ]
    )
    return "\n".join(lines).strip() + "\n"


def augmented_path() -> str:
    entries: list[str] = []
    seen: set[str] = set()
    for raw_entry in os.environ.get("PATH", "").split(os.pathsep):
        entry = raw_entry.strip()
        if not entry or entry in seen:
            continue
        seen.add(entry)
        entries.append(entry)
    for candidate in COMMON_BIN_DIRS:
        entry = str(candidate)
        if candidate.is_dir() and entry not in seen:
            seen.add(entry)
            entries.insert(0, entry)
    return os.pathsep.join(entries)


def runner_env() -> dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = augmented_path()
    return env


# PR1.3 — `apply_channel_runtime_env` and `validate_channel_delivery_request`
# are removed: the cron child no longer ever loads channel plugins, so
# wiring DISCORD_STATE_DIR / TELEGRAM_STATE_DIR into its env, or validating
# that a target's channels match `job_delivery_channel`, is meaningless.
# The legacy `allow_channel_delivery` / `disposable_needs_channels` keys
# are honored only for audit-warn (see `cmd_run`).


def resolve_binary(name: str, override_env: str) -> str:
    override = os.environ.get(override_env, "").strip()
    if override:
        path = Path(override).expanduser()
        if not path.is_file():
            raise FileNotFoundError(f"{override_env} points to a missing file: {path}")
        return str(path.resolve())

    resolved = shutil.which(name, path=augmented_path())
    if resolved:
        return resolved

    searched = [str(path) for path in COMMON_BIN_DIRS]
    raise FileNotFoundError(f"{name} binary not found; searched PATH and common dirs: {', '.join(searched)}")


def run_codex(request: dict[str, Any], prompt: str, schema_path: Path, timeout: int, request_file: Path | None = None) -> tuple[list[str], subprocess.CompletedProcess[str]]:
    workdir = request["target_workdir"]
    codex_bin = resolve_binary("codex", "BRIDGE_CODEX_BIN")
    command = [
        codex_bin,
        "exec",
        "--ephemeral",
        "--json",
        "--output-schema",
        str(schema_path),
        "-C",
        workdir,
        "--skip-git-repo-check",
        "--dangerously-bypass-approvals-and-sandbox",
        prompt,
    ]
    env = runner_env()
    if request_file is not None:
        env["CRON_REQUEST_DIR"] = str(request_file.parent)
    completed = subprocess.run(
        command,
        cwd=workdir,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    return command, completed


def run_claude(request: dict[str, Any], prompt: str, timeout: int, request_file: Path | None = None) -> tuple[list[str], subprocess.CompletedProcess[str]]:
    workdir = request["target_workdir"]
    claude_bin = resolve_binary("claude", "BRIDGE_CLAUDE_BIN")
    # PR1.3 — cron child never loads channel plugins or MCP servers. The
    # `--channels` injection and `apply_channel_runtime_env` paths are gone.
    # `--strict-mcp-config` is unconditional (see disable_mcp_for_request).
    command = [
        claude_bin,
        "-p",
        "--no-session-persistence",
        "--strict-mcp-config",
        "--output-format",
        "json",
        "--json-schema",
        json.dumps(RESULT_SCHEMA, ensure_ascii=True),
        "--permission-mode",
        "bypassPermissions",
        prompt,
    ]
    env = runner_env()
    if request_file is not None:
        env["CRON_REQUEST_DIR"] = str(request_file.parent)
    completed = subprocess.run(
        command,
        cwd=workdir,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    return command, completed


def parse_codex_output(stdout_text: str) -> dict[str, Any]:
    agent_message: str | None = None
    for raw_line in stdout_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        item = event.get("item")
        if event.get("type") == "item.completed" and isinstance(item, dict) and item.get("type") == "agent_message":
            text = item.get("text")
            if isinstance(text, str) and text.strip():
                agent_message = text
    if not agent_message:
        raise ValueError("codex output did not contain a final agent_message event")
    return validate_result(json.loads(agent_message))


def parse_claude_output(stdout_text: str) -> dict[str, Any]:
    text = stdout_text.strip()
    if not text:
        raise ValueError("claude output was empty")

    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = json.loads(text.splitlines()[-1])

    if isinstance(payload, list):
        for event in reversed(payload):
            if isinstance(event, dict) and isinstance(event.get("structured_output"), dict):
                return validate_result(event["structured_output"])
        raise ValueError("claude output array did not contain structured_output")

    if not isinstance(payload, dict):
        raise ValueError("claude output was not a JSON object")

    structured = payload.get("structured_output")
    if isinstance(structured, dict):
        return validate_result(structured)

    result_text = payload.get("result")
    if isinstance(result_text, str):
        result_text = result_text.strip()
        if result_text:
            try:
                parsed_result = json.loads(result_text)
            except json.JSONDecodeError:
                parsed_result = None
            if isinstance(parsed_result, dict):
                return validate_result(parsed_result)

            if payload.get("subtype") == "success" and not payload.get("is_error", False):
                return validate_result(
                    {
                        "status": "completed",
                        "summary": result_text,
                        "findings": [],
                        "actions_taken": ["Claude returned plain-text result instead of structured_output"],
                        "needs_human_followup": False,
                        "recommended_next_steps": [],
                        "artifacts": [],
                        "confidence": "low",
                    }
                )

    raise ValueError("claude output did not contain structured_output")


def write_status(
    status_file: Path,
    *,
    run_id: str,
    state: str,
    engine: str,
    request_file: Path,
    result_file: Path,
    started_at: str | None = None,
    completed_at: str | None = None,
    exit_code: int | None = None,
    error: str | None = None,
    delivery_intent: str | None = None,
    reporting_decision: str | None = None,
    inbox_task_id: int | None = None,
) -> None:
    payload: dict[str, Any] = {
        "run_id": run_id,
        "state": state,
        "engine": engine,
        "updated_at": now_iso(),
        "request_file": str(request_file),
        "result_file": str(result_file),
    }
    if started_at:
        payload["started_at"] = started_at
    if completed_at:
        payload["completed_at"] = completed_at
    if exit_code is not None:
        payload["exit_code"] = exit_code
    if error:
        payload["error"] = error
    # PR1.8 — silent-exit audit fields. Emitted even when the cron is
    # silent so operators can see "we ran, decided silent, no inbox task".
    if delivery_intent is not None:
        payload["delivery_intent"] = delivery_intent
    if reporting_decision is not None:
        payload["reporting_decision"] = reporting_decision
    if inbox_task_id is not None:
        payload["inbox_task_id"] = inbox_task_id
    write_json(status_file, payload)


def cmd_run_shell(request: dict[str, Any], request_file: Path, args: argparse.Namespace) -> int:
    run_dir = request_file.parent
    run_id = str(request.get("run_id") or run_dir_id(run_dir))
    result_file = (run_dir / "result.json").resolve()
    status_file = (run_dir / "status.json").resolve()
    stdout_log = (run_dir / "stdout.log").resolve()
    stderr_log = (run_dir / "stderr.log").resolve()

    if args.dry_run:
        print("status: dry_run")
        print(f"run_id: {run_id}")
        print("engine: shell")
        print(f"request_file: {rel_for_output(str(request_file))}")
        print(f"result_file: {rel_for_output(str(result_file))}")
        print(f"status_file: {rel_for_output(str(status_file))}")
        return 0

    trusted, trust_error = validate_shell_request_artifacts(request_file)
    if not trusted:
        error_message = trust_error or "request_artifact_tampered"
        completed_at = now_iso()
        write_text(stdout_log, "")
        write_text(stderr_log, error_message + "\n")
        write_shell_result(
            result_file,
            run_id=run_id,
            status="error",
            summary=error_message,
            request_file=request_file,
            stdout_log=stdout_log,
            stderr_log=stderr_log,
            completed_at=completed_at,
            exit_code=1,
            runner_error="request_artifact_tampered",
        )
        write_shell_status(
            status_file,
            run_id=run_id,
            state="error",
            request_file=request_file,
            result_file=result_file,
            completed_at=completed_at,
            exit_code=1,
            runner_error="request_artifact_tampered",
        )
        print("status: error")
        print(f"run_id: {run_id}")
        print("engine: shell")
        print("runner_error: request_artifact_tampered")
        return 1

    payload = request.get("payload") or {}
    if not isinstance(payload, dict):
        raise RuntimeError("shell request payload must be an object")
    execution = request.get("execution") or {}
    if not isinstance(execution, dict):
        raise RuntimeError("shell request execution block must be an object")
    script = str(payload.get("script") or "")
    if not script:
        raise RuntimeError("shell request missing payload.script")
    script_path = Path(script).expanduser().resolve()
    if not script_path.is_file() or not os.access(script_path, os.X_OK):
        raise RuntimeError(f"shell script is not executable: {script_path}")
    run_uid = int(execution.get("uid"))
    script_stat = script_path.stat()
    if script_stat.st_uid not in {os.getuid(), run_uid}:
        raise RuntimeError(f"shell script owner must be controller uid or run-as uid: {script_path}")
    if script_stat.st_mode & 0o022:
        raise RuntimeError(f"shell script must not be group/other writable: {script_path}")
    script_args = payload.get("args") or []
    if not isinstance(script_args, list):
        raise RuntimeError("payload.args must be an array")
    argv = [str(item) for item in script_args]
    timeout_seconds = int(payload.get("timeoutSeconds") or 900)
    output_cap_bytes = int(payload.get("outputCapBytes") or 65536)
    if timeout_seconds <= 0:
        raise RuntimeError("payload.timeoutSeconds must be positive")
    if output_cap_bytes <= 0:
        raise RuntimeError("payload.outputCapBytes must be positive")

    env_snapshot = execution.get("env_snapshot") or {}
    if not isinstance(env_snapshot, dict):
        raise RuntimeError("execution.env_snapshot must be an object")
    child_env = {str(key): str(value) for key, value in env_snapshot.items()}
    child_env.update(shell_payload_env(payload))
    child_env["HOME"] = str(execution.get("home") or child_env.get("HOME") or str(Path.home()))
    child_env["CRON_RUN_ID"] = run_id
    child_env["CRON_JOB_ID"] = str(request.get("job_id") or "")
    child_env["CRON_JOB_NAME"] = str(request.get("job_name") or "")
    child_env["CRON_SLOT"] = str(request.get("slot") or "")
    child_env["CRON_REQUEST_FILE"] = str(request_file)
    child_env["CRON_RUN_DIR"] = str(run_dir)

    command = shell_command_for_execution(execution, child_env, str(script_path), argv)
    lock_dir = cron_state_dir_from_env(run_dir) / "locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    lock_file = lock_dir / f"{str(request.get('job_id') or run_id)}.lock"

    with lock_file.open("w", encoding="utf-8") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            completed_at = now_iso()
            write_text(stdout_log, "")
            write_text(stderr_log, "lock_held\n")
            write_shell_result(
                result_file,
                run_id=run_id,
                status="success",
                summary="lock_held",
                request_file=request_file,
                stdout_log=stdout_log,
                stderr_log=stderr_log,
                completed_at=completed_at,
                exit_code=0,
                runner_error="lock_held",
                command=command,
            )
            write_shell_status(
                status_file,
                run_id=run_id,
                state="success",
                request_file=request_file,
                result_file=result_file,
                completed_at=completed_at,
                exit_code=0,
                runner_error="lock_held",
            )
            print("status: success")
            print(f"run_id: {run_id}")
            print("engine: shell")
            print("summary: lock_held")
            return 0

        started_at = now_iso()
        start_monotonic = time.monotonic()
        write_shell_status(
            status_file,
            run_id=run_id,
            state="running",
            request_file=request_file,
            result_file=result_file,
            started_at=started_at,
        )

        process = subprocess.Popen(
            command,
            cwd=str(run_dir),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        timed_out = False
        try:
            stdout_bytes, stderr_bytes = process.communicate(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except OSError:
                pass
            try:
                stdout_bytes, stderr_bytes = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    pass
                stdout_bytes, stderr_bytes = process.communicate()

        completed_at = now_iso()
        duration_ms = int((time.monotonic() - start_monotonic) * 1000)
        stdout_text, stdout_truncated = truncate_output(stdout_bytes or b"", output_cap_bytes)
        stderr_text, stderr_truncated = truncate_output(stderr_bytes or b"", output_cap_bytes)
        if stdout_truncated or stderr_truncated:
            stderr_text += "[agent-bridge] one or more streams were truncated\n"
        write_text(stdout_log, stdout_text)
        write_text(stderr_log, stderr_text)

        if timed_out:
            final_state = "timed_out"
            result_status = "error"
            error_message = f"timed out after {timeout_seconds}s"
            exit_code = 124
        else:
            exit_code = int(process.returncode)
            if exit_code == 0:
                final_state = "success"
                result_status = "success"
                error_message = None
            else:
                final_state = "error"
                result_status = "error"
                error_message = f"script exited {exit_code}"

        write_shell_result(
            result_file,
            run_id=run_id,
            status=result_status,
            summary="shell cron completed" if result_status == "success" else (error_message or "shell cron failed"),
            request_file=request_file,
            stdout_log=stdout_log,
            stderr_log=stderr_log,
            started_at=started_at,
            completed_at=completed_at,
            duration_ms=duration_ms,
            exit_code=exit_code,
            runner_error=error_message,
            command=command,
            stdout_truncated=stdout_truncated,
            stderr_truncated=stderr_truncated,
        )
        write_shell_status(
            status_file,
            run_id=run_id,
            state=final_state,
            request_file=request_file,
            result_file=result_file,
            started_at=started_at,
            completed_at=completed_at,
            duration_ms=duration_ms,
            exit_code=exit_code,
            runner_error=error_message,
        )

    print(f"status: {final_state}")
    print(f"run_id: {run_id}")
    print("engine: shell")
    print(f"result_file: {rel_for_output(str(result_file))}")
    print(f"status_file: {rel_for_output(str(status_file))}")
    if error_message:
        print(f"runner_error: {error_message}")
    return 0 if final_state == "success" else 1


def cmd_run(args: argparse.Namespace) -> int:
    request_file = Path(args.request_file).expanduser().resolve()
    if not request_file.is_file():
        print(f"error: request file not found: {request_file}", file=sys.stderr)
        return 2

    request = read_json(request_file)
    request_payload = request.get("payload") if isinstance(request.get("payload"), dict) else {}
    if request.get("payload_kind") == "shell" or request_payload.get("kind") == "shell":
        return cmd_run_shell(request, request_file, args)

    engine = request.get("target_engine", "")
    run_id = request.get("run_id", "")
    workdir = request.get("target_workdir", "")
    payload_file = Path(request["payload_file"]).expanduser().resolve()
    result_file = Path(request["result_file"]).expanduser().resolve()
    status_file = Path(request["status_file"]).expanduser().resolve()
    stdout_log = Path(request["stdout_log"]).expanduser().resolve()
    stderr_log = Path(request["stderr_log"]).expanduser().resolve()
    run_dir = request_file.parent
    schema_file = run_dir / "result-schema.json"
    prompt_file = run_dir / "prompt.txt"

    if args.dry_run:
        print("status: dry_run")
        print(f"run_id: {run_id}")
        print(f"engine: {engine}")
        print(f"workdir: {workdir}")
        print(f"request_file: {rel_for_output(str(request_file))}")
        print(f"payload_file: {rel_for_output(str(payload_file))}")
        print(f"result_file: {rel_for_output(str(result_file))}")
        print(f"status_file: {rel_for_output(str(status_file))}")
        print(f"stdout_log: {rel_for_output(str(stdout_log))}")
        print(f"stderr_log: {rel_for_output(str(stderr_log))}")
        return 0

    # Issue #263 Track B — pre-flight memory guard.
    # Probe BEFORE materialising prompt artifacts or spawning the child. On a
    # pressured host the child cold-load is what tips the disposable run past
    # its timeout (see issue body for the event-reminder-30min stall). We skip
    # the spawn, mark the run deferred, and audit the decision. The next
    # scheduler tick re-fires the slot once memory recovers; no admin queue
    # nudge is emitted (issue #472).
    pressure = check_memory_pressure()
    if pressure is not None:
        deferred_at = now_iso()
        target_agent = str(request.get("target_agent") or "")
        deferred_payload: dict[str, Any] = {
            "run_id": run_id,
            "state": "deferred",
            "engine": engine,
            "updated_at": deferred_at,
            "request_file": str(request_file),
            "result_file": str(result_file),
            "deferred_at": deferred_at,
            "deferred_reason": "memory_pressure",
            "deferred_seconds": PRESSURE_DEFER_SECONDS,
            "memory_probe": pressure,
        }
        write_json(status_file, deferred_payload)
        emit_pressure_audit(run_id, target_agent, pressure)
        print(f"status: deferred")
        print(f"run_id: {run_id}")
        print(f"engine: {engine}")
        print(f"reason: memory_pressure")
        for key, value in pressure.items():
            print(f"{key}: {value}")
        # Return 0: this is an intentional defer, not a failure. The cron
        # worker that invoked us closes the queue task with a deferred note;
        # the scheduler enqueues the next slot on its next pass.
        return 0

    payload_text = payload_file.read_text(encoding="utf-8")
    prompt = build_prompt(request, payload_text)
    write_text(prompt_file, prompt)
    write_json(schema_file, RESULT_SCHEMA)
    # PR1 — emit audit-warn for legacy keys before the child runs so that
    # operators see exactly which deprecated knobs are still wired in
    # production cron jobs.
    emit_legacy_key_audit(request, run_id, target_agent=str(request.get("target_agent") or ""))

    timeout = int(os.environ.get("BRIDGE_CRON_SUBAGENT_TIMEOUT_SECONDS", "900"))
    started_at = now_iso()
    write_status(
        status_file,
        run_id=run_id,
        state="running",
        engine=engine,
        request_file=request_file,
        result_file=result_file,
        started_at=started_at,
    )

    start_monotonic = time.monotonic()
    command: list[str]
    completed: subprocess.CompletedProcess[str]
    final_state = "error"
    child_result: dict[str, Any] | None = None
    error_message: str | None = None
    # Default audit values; overridden per-engine and on sidecar recovery.
    child_result_source = "child"
    sidecar_error_note: str | None = None
    family = request.get("family", "")
    sidecar_path = run_dir / "authoritative-memory-daily.json"

    try:
        if engine == "codex":
            command, completed = run_codex(request, prompt, schema_file, timeout, request_file=request_file)
            write_text(stdout_log, completed.stdout)
            write_text(stderr_log, completed.stderr)
            if completed.returncode != 0:
                raise RuntimeError(f"codex exec failed with exit code {completed.returncode}")
            child_result = parse_codex_output(completed.stdout)
            final_state = "success" if child_result.get("status") != "error" else "error"
        elif engine == "claude":
            command, completed = run_claude(request, prompt, timeout, request_file=request_file)
            write_text(stdout_log, completed.stdout)
            write_text(stderr_log, completed.stderr)
            if completed.returncode != 0:
                raise RuntimeError(f"claude -p failed with exit code {completed.returncode}")

            # memory-daily: authoritative sidecar written by the harvester is
            # preferred source. Attempt it BEFORE parse_claude_output so a child
            # relay that drops/rewrites structured_output cannot override the
            # harvester's authoritative actions_taken.
            if family == "memory-daily" and sidecar_path.is_file():
                try:
                    authoritative = json.loads(sidecar_path.read_text(encoding="utf-8"))
                    child_result = validate_result(authoritative)
                    child_result_source = "authoritative-sidecar"
                except (OSError, json.JSONDecodeError, ValueError) as exc:
                    sidecar_error_note = f"sidecar invalid: {exc!r}"
                    child_result = None

            if child_result is None:
                child_result = parse_claude_output(completed.stdout)
                if family == "memory-daily":
                    child_result_source = "child-fallback"

            final_state = "success" if child_result.get("status") != "error" else "error"
        else:
            raise RuntimeError(f"unsupported engine for cron subagent: {engine}")
    except subprocess.TimeoutExpired as exc:
        command = exc.cmd if isinstance(exc.cmd, list) else [str(exc.cmd)]
        write_text(stdout_log, exc.stdout or "")
        write_text(stderr_log, exc.stderr or "")
        error_message = f"timed out after {timeout}s"
        final_state = "timed_out"
        completed = subprocess.CompletedProcess(command, 124, exc.stdout or "", exc.stderr or "")
    except Exception as exc:  # noqa: BLE001
        error_message = str(exc)
        if "completed" not in locals():
            completed = subprocess.CompletedProcess([], 1, "", "")
        if "command" not in locals():
            command = []
        # memory-daily: if the parse path threw but harvester wrote a valid
        # sidecar, recover so a structured harvester result is preserved even
        # when the child relay JSON was malformed / missing.
        if engine == "claude" and family == "memory-daily" and sidecar_path.is_file():
            try:
                authoritative = json.loads(sidecar_path.read_text(encoding="utf-8"))
                child_result = validate_result(authoritative)
                child_result_source = "authoritative-sidecar-after-parse-error"
                final_state = "success" if child_result.get("status") != "error" else "error"
                error_message = None
            except (OSError, json.JSONDecodeError, ValueError) as sidecar_exc:
                sidecar_error_note = f"sidecar recovery failed: {sidecar_exc!r}"
                child_result = None

    completed_at = now_iso()
    duration_ms = int((time.monotonic() - start_monotonic) * 1000)

    if child_result is None:
        child_result = {
            "status": "error",
            "summary": error_message or "cron subagent failed",
            "findings": [],
            "actions_taken": [],
            "needs_human_followup": True,
            "recommended_next_steps": ["Inspect stdout.log and stderr.log"],
            "artifacts": [],
            "confidence": "low",
            # PR1 — invalid result drops to silent so we don't accidentally
            # spam the parent's inbox with malformed alerts. The audit log
            # records the failure separately via reporting_decision=invalid.
            "delivery_intent": "silent",
        }

    # PR1.2 — apply per-job reporting_policy override (always_silent /
    # always_main_session) and capture any demotion for the audit log.
    policy_value = reporting_policy(request)
    child_result, policy_override_note = apply_reporting_policy(child_result, policy_value)

    delivery_intent = str(child_result.get("delivery_intent") or "silent").strip()
    if delivery_intent not in DELIVERY_INTENT_VALUES:
        delivery_intent = "silent"

    # PR1.5 — direct-send marker detection (audit-only per Sean Q-C).
    markers = detect_direct_send_markers(child_result)

    # PR1.4 — record whether the legacy `allow_channel_delivery` key was
    # used (vs the new `allow_structured_relay`) so the audit can quantify
    # remaining migration work.
    structured_relay_legacy = (
        "allow_channel_delivery" in request and "allow_structured_relay" not in request
    )

    forward_target = child_result.get("forward_target") if delivery_intent == "forward_to_user" else None
    summary_short = str(child_result.get("summary_short") or "") if delivery_intent != "silent" else ""

    # PR1.6 — write the inbox-task body to the cron run's followup file
    # and create / refresh the queue task. Failure is non-fatal here; the
    # cron run itself succeeded. We mark reporting_decision accordingly.
    inbox_task_id: int | None = None
    inbox_action = "skipped"
    target_agent = str(request.get("target_agent") or "")
    cron_urgency = str(request.get("cron_urgency") or "").strip().lower()
    if cron_urgency not in {"normal", "high", "urgent"}:
        cron_urgency = "normal"
    followup_body_path = run_dir / "cron-followup.md"

    # Codex r2 P1 / r3 P1 — compute the failure predicate BEFORE the inbox
    # upsert so a structurally-valid child result with `status:"error"`
    # (or any other non-success final state) cannot create a runner-owned
    # inbox task that the daemon then duplicates via its failure-followup
    # path. `silent` is reserved exclusively for clean-success-no-signal;
    # everything else surfaces as `invalid` and is left to the existing
    # daemon-side failure-followup path.
    child_status_error = str(child_result.get("status", "")).strip().lower() == "error"
    run_failed = (
        bool(error_message)
        or final_state != "success"
        or child_status_error
    )

    if not run_failed and delivery_intent != "silent":
        write_followup_body(
            followup_body_path,
            schema_version=1,
            run_id=run_id,
            job_id=str(request.get("job_id") or ""),
            job_name=str(request.get("job_name") or ""),
            family=family,
            target_agent=target_agent,
            delivery_intent=delivery_intent,
            forward_target=forward_target if isinstance(forward_target, dict) else None,
            summary_short=summary_short,
            summary=str(child_result.get("summary") or ""),
            findings=list(child_result.get("findings") or []),
            actions_taken=list(child_result.get("actions_taken") or []),
            recommended_next_steps=list(child_result.get("recommended_next_steps") or []),
            artifacts=list(child_result.get("artifacts") or []),
            reporting_policy_value=policy_value,
            structured_relay_legacy=structured_relay_legacy,
        )
        title = cron_followup_title(
            str(request.get("job_name") or ""), delivery_intent, run_id
        )
        inbox_task_id, inbox_action = upsert_inbox_task(
            target_agent=target_agent,
            actor=f"cron:{request.get('source_agent', 'cron')}",
            title=title,
            body_path=followup_body_path,
            priority=cron_urgency,
            intent=delivery_intent,
            job_name=str(request.get("job_name") or ""),
        )

    if run_failed:
        reporting_decision = "invalid"
    elif delivery_intent == "silent":
        reporting_decision = "silent"
    elif inbox_action == "failed" or inbox_task_id is None:
        reporting_decision = "invalid"
    else:
        reporting_decision = "reported"

    # PR1.5 — emit one cron_audit line per run summarizing the reporting
    # decision and any direct-send markers detected. Disk-volume rule
    # (Sean 2026-05-02): keep it to a single line, ≤80-char marker excerpt.
    audit_details: dict[str, Any] = {
        "intent": delivery_intent,
        "decision": reporting_decision,
        "task": inbox_task_id if inbox_task_id is not None else "null",
        "markers": len(markers),
        "policy": policy_value,
        "inbox_action": inbox_action,
    }
    if policy_override_note:
        audit_details["policy_override"] = policy_override_note
    if markers:
        first = markers[0]
        excerpt = first["excerpt"][:MARKER_EXCERPT_LIMIT]
        audit_details["marker_field"] = first["field"]
        audit_details["marker_excerpt"] = excerpt
    if structured_relay_legacy:
        audit_details["legacy_relay_key"] = "allow_channel_delivery"
    emit_audit_row(
        action="cron_audit",
        actor="cron-runner",
        target_agent=target_agent or "daemon",
        run_id=run_id,
        details=audit_details,
    )

    result_payload = {
        "run_id": run_id,
        "engine": engine,
        "status": child_result["status"],
        "summary": child_result["summary"],
        "findings": child_result["findings"],
        "actions_taken": child_result["actions_taken"],
        "needs_human_followup": child_result["needs_human_followup"],
        "recommended_next_steps": child_result["recommended_next_steps"],
        "artifacts": child_result["artifacts"],
        "confidence": child_result["confidence"],
        "child_result_source": child_result_source,
        "started_at": started_at,
        "completed_at": completed_at,
        "duration_ms": duration_ms,
        "request_file": str(request_file),
        "payload_file": str(payload_file),
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
        "prompt_file": str(prompt_file),
        "command": command,
        "command_pretty": " ".join(shlex.quote(part) for part in command),
        "child_exit_code": completed.returncode,
        # PR1.8 — silent-exit audit fields (always emitted, even on silent).
        "delivery_intent": delivery_intent,
        "reporting_decision": reporting_decision,
        "inbox_task_id": inbox_task_id,
        "reporting_policy": policy_value,
    }
    if forward_target:
        result_payload["forward_target"] = forward_target
    if summary_short:
        result_payload["summary_short"] = summary_short
    if structured_relay_legacy:
        result_payload["legacy_structured_relay_key_used"] = True
    if markers:
        result_payload["direct_send_markers_count"] = len(markers)
    if sidecar_error_note:
        result_payload["sidecar_error_note"] = sidecar_error_note
    if error_message:
        result_payload["runner_error"] = error_message

    write_json(result_file, result_payload)
    write_status(
        status_file,
        run_id=run_id,
        state=final_state,
        engine=engine,
        request_file=request_file,
        result_file=result_file,
        started_at=started_at,
        completed_at=completed_at,
        exit_code=completed.returncode,
        error=error_message,
        delivery_intent=delivery_intent,
        reporting_decision=reporting_decision,
        inbox_task_id=inbox_task_id,
    )

    print(f"status: {final_state}")
    print(f"run_id: {run_id}")
    print(f"engine: {engine}")
    print(f"result_file: {rel_for_output(str(result_file))}")
    print(f"status_file: {rel_for_output(str(status_file))}")
    print(f"summary: {child_result['summary']}")
    print(f"reporting_decision: {reporting_decision}")
    print(f"delivery_intent: {delivery_intent}")
    if inbox_task_id is not None:
        print(f"inbox_task_id: {inbox_task_id}")
    # PR1.5 — schema-required reject (e.g., bad delivery_intent payload)
    # surfaces here as reporting_decision=invalid AND error_message set;
    # exit non-zero so the daemon's existing health path picks it up.
    if reporting_decision == "invalid" and not error_message:
        # We landed in "invalid" because inbox writeback failed. The cron
        # body itself ran fine, so we still return 1 to ensure the dispatch
        # task gets retried/raised by the daemon.
        return 1
    return 0 if final_state == "success" else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("run")
    run.add_argument("--request-file", required=True)
    run.add_argument("--dry-run", action="store_true")
    run.set_defaults(func=cmd_run)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
