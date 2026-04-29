#!/usr/bin/env python3
"""Disposable cron child runner for Agent Bridge."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


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


def validate_result(payload: dict[str, Any]) -> dict[str, Any]:
    result = normalize_result(payload)
    missing = [key for key in RESULT_SCHEMA["required"] if key not in result]
    if missing:
        raise ValueError(f"result missing required fields: {', '.join(missing)}")
    if not isinstance(result["summary"], str) or not result["summary"].strip():
        raise ValueError("result summary must be a non-empty string")
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
        "daemon",
        "--action",
        "cron_dispatch_deferred",
        "--target",
        target_agent or "daemon",
        "--detail",
        f"run_id={run_id}",
    ]
    for key, value in probe.items():
        cmd.extend(["--detail", f"{key}={value}"])
    try:
        subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


def disable_mcp_for_request(request: dict[str, Any]) -> bool:
    """#263 + #468: decide whether the disposable child should launch with MCP disabled.

    Order of precedence:
      1. ``request['disposable_needs_channels']`` — channel relays need MCP
         servers loaded to deliver, so we never disable in that case. Safety
         override; nothing below can flip it back.
      2. ``BRIDGE_CRON_DISPOSABLE_DISABLE_MCP`` env override (ops A/B switch).
         Set to ``1``/``true`` to force-disable MCP for every cron child;
         ``0``/``false`` to force-enable. Unset to defer to per-job config.
      3. ``request['disable_mcp']`` from the job's ``metadata.disableMcp``
         (or aliases) wired through ``bridge_cron_write_request``. When
         explicitly set (``True``/``False``) the per-job choice wins.
      4. **Default: True.** Non-channel cron disposables disable MCP unless
         opted in. Disabling MCP cuts cold-start cost (~22K tokens / run on
         the SYRS reference install) and prevents a cwd
         ``settings.local.json`` ``enabledPlugins`` entry (e.g. telegram)
         from auto-attaching in the disposable child and stealing the
         parent agent's MCP poller via plugin singleton-lock (issue #468).
         If a specific cron payload genuinely needs MCP tools, set
         ``metadata.disableMcp = False`` on that job.
    """
    if disposable_needs_channels(request):
        return False
    override = os.environ.get("BRIDGE_CRON_DISPOSABLE_DISABLE_MCP")
    if override is not None and override.strip():
        return bool_flag(override)
    raw = request.get("disable_mcp")
    if raw is None or (isinstance(raw, str) and not raw.strip()):
        return True
    return bool_flag(raw)


def build_prompt(request: dict[str, Any], payload_text: str) -> str:
    allow_channel_delivery = bool_flag(request.get("allow_channel_delivery"))
    child_channels_enabled = disposable_needs_channels(request)
    target_channels = csv_items(request.get("target_channels", ""))
    channel_name = str(request.get("job_delivery_channel") or "").strip()
    channel_target = str(request.get("job_delivery_target") or "").strip()
    lines = [
        "You are a disposable cron execution worker for Agent Bridge.",
        "",
        "Act on behalf of the parent agent below.",
        "Do the heavy cron work in this disposable run, then return JSON only.",
        "",
        "Hard rules:",
    ]
    if allow_channel_delivery:
        lines.extend(
            [
                "- Do not send user-facing messages directly from this disposable run.",
                "- If the cron needs a human-facing message, return it as a structured channel_relay object in the JSON result.",
                "- channel_relay must include a non-empty body field.",
                "- channel_relay transport/target are optional hints; request metadata remains the routing authority.",
                "- When channel_relay is present, treat needs_human_followup as true.",
            ]
        )
        if child_channels_enabled:
            lines.extend(
                [
                    "- Even if channel tools are available in this run, do not use them for human delivery.",
                    f"- Preferred relay transport: {channel_name or 'configured target agent channels'}",
                    f"- Preferred relay target: {channel_target or '(not specified)'}",
                    "- Do not use message/reply/send tools, direct webhook helpers, or agent-bridge urgent/task create/task done/handoff for delivery.",
                    "- The parent agent will review the relay payload and send it from the parent session.",
                    "- Keep the summary concise and operator-facing.",
                ]
            )
        else:
            lines.extend(
                [
                    "- Target agent channels are informational routing metadata in this disposable run.",
                    "- If delivery is needed, return channel_relay instead of describing a direct send in prose only.",
                    "- Do not use agent-bridge urgent/task create/task done/handoff for delivery.",
                    "- Keep the summary concise and operator-facing.",
                ]
            )
    else:
        lines.extend(
            [
                "- Do not send user-facing messages directly.",
                "- Do not post to Discord, Telegram, email, or any human channel.",
                "- Do not call agent-bridge urgent/task create/task done/handoff for delivery.",
                "- If the legacy cron would normally notify someone, record that in recommended_next_steps instead.",
                "- Set needs_human_followup=true only when the parent agent must review, decide, or act after this run, or when the run fails.",
                "- Routine monitoring with no material change should set needs_human_followup=false.",
                "- If you already completed the work and no parent follow-up is required, leave recommended_next_steps empty and set needs_human_followup=false.",
                "- Keep the summary concise and operator-facing.",
            ]
        )
    if target_channels:
        lines.extend(["", f"Target channels: {', '.join(target_channels)}"])
    lines.extend(
        [
            "",
            f"Parent agent: {request['target_agent']} ({request['target_engine']})",
            f"Job: {request['job_name']}",
            f"Family: {request['family']}",
            f"Slot: {request['slot']}",
            f"Run ID: {request['run_id']}",
            f"Payload file: {request['payload_file']}",
            "",
            "Legacy cron payload follows:",
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


def apply_channel_runtime_env(request: dict[str, Any], env: dict[str, str]) -> dict[str, str]:
    channels = csv_items(request.get("target_channels", ""))
    updated = dict(env)
    if channel_enabled(channels, "plugin:discord"):
        discord_dir = str(request.get("target_discord_state_dir") or "").strip()
        if discord_dir:
            updated["DISCORD_STATE_DIR"] = discord_dir
    if channel_enabled(channels, "plugin:telegram"):
        telegram_dir = str(request.get("target_telegram_state_dir") or "").strip()
        if telegram_dir:
            updated["TELEGRAM_STATE_DIR"] = telegram_dir
    return updated


def validate_channel_delivery_request(request: dict[str, Any]) -> None:
    if not bool_flag(request.get("allow_channel_delivery")):
        return

    channels = csv_items(request.get("target_channels", ""))
    if not channels:
        raise RuntimeError("channel delivery is allowed for this run, but target agent has no configured channels")

    preferred = str(request.get("job_delivery_channel") or "").strip().lower()
    if preferred:
        expected = f"plugin:{preferred}"
        if not channel_enabled(channels, expected):
            raise RuntimeError(
                f"channel delivery requested for {preferred}, but target agent channels are {', '.join(channels)}"
            )


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
    channels = csv_items(request.get("target_channels", ""))
    command = [
        claude_bin,
        "-p",
        "--no-session-persistence",
        "--output-format",
        "json",
        "--json-schema",
        json.dumps(RESULT_SCHEMA, ensure_ascii=True),
        "--permission-mode",
        "bypassPermissions",
        prompt,
    ]
    if channels and disposable_needs_channels(request):
        command[2:2] = ["--channels", ",".join(channels)]
    # #263: when MCP is opt-disabled, pass --strict-mcp-config without any
    # --mcp-config so the child loads zero MCP servers. Cuts cold-start cost
    # for cron payloads that do not use MCP tools (the common case).
    if disable_mcp_for_request(request):
        command[2:2] = ["--strict-mcp-config"]
    env = apply_channel_runtime_env(request, runner_env())
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
    write_json(status_file, payload)


def cmd_run(args: argparse.Namespace) -> int:
    request_file = Path(args.request_file).expanduser().resolve()
    if not request_file.is_file():
        print(f"error: request file not found: {request_file}", file=sys.stderr)
        return 2

    request = read_json(request_file)
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
    validate_channel_delivery_request(request)

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
        }

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
    }
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
    )

    print(f"status: {final_state}")
    print(f"run_id: {run_id}")
    print(f"engine: {engine}")
    print(f"result_file: {rel_for_output(str(result_file))}")
    print(f"status_file: {rel_for_output(str(status_file))}")
    print(f"summary: {child_result['summary']}")
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
