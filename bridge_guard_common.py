#!/usr/bin/env python3
"""Shared prompt guard helpers for Agent Bridge."""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Operator-home SSOT (issue #1497 P2). This module lives at the repo root (and
# `~/.agent-bridge/` root in the deployed runtime), so the canonical resolver is
# `<this>/lib/operator_home.py`. Load it by its EXACT path via importlib — NOT
# through sys.path — so a same-named `operator_home` module elsewhere on the path
# can never shadow it and redirect the guard home (#1507 r2: a bare
# `from operator_home import` does NOT raise when lib/ is absent if some other
# operator_home is importable). When the exact file is absent (partial deploy /
# test overlay) the inline fallback is byte-identical to operator_home().
_OPERATOR_HOME_PY = Path(__file__).resolve().parent / "lib" / "operator_home.py"
operator_home = None
if _OPERATOR_HOME_PY.is_file():
    import importlib.util as _ilu
    _spec = _ilu.spec_from_file_location("_agb_operator_home", str(_OPERATOR_HOME_PY))
    if _spec is not None and _spec.loader is not None:
        _mod = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_mod)
        operator_home = getattr(_mod, "operator_home", None)
if not callable(operator_home):  # exact file absent — byte-identical inline SSOT
    def operator_home() -> Path:
        explicit = os.environ.get("BRIDGE_HOME", "").strip()  # noqa: iso-helper-boundary — os.environ (.environ) false-matches the .env boundary pattern; BRIDGE_HOME is the operator runtime root, not an isolated artifact
        if explicit:
            return Path(explicit).expanduser()
        return Path.home() / ".agent-bridge"

SEVERITY_ORDER = {
    "safe": 0,
    "low": 1,
    "medium": 2,
    "high": 3,
    "critical": 4,
}

BUILTIN_SCAN_RULES: list[tuple[str, str, re.Pattern[str]]] = [
    (
        "critical",
        "prompt_injection_override",
        re.compile(
            r"\b(ignore|disregard|forget)\b.{0,40}\b(previous|prior|all)\b.{0,40}\b(instruction|system|rule)s?\b",
            re.IGNORECASE | re.DOTALL,
        ),
    ),
    (
        "critical",
        "secret_exfiltration_request",
        re.compile(
            r"\b(show|reveal|print|dump|exfiltrat|leak|send)\b.{0,50}\b(secret|token|password|api key|credential|system prompt)\b",
            re.IGNORECASE | re.DOTALL,
        ),
    ),
    # bridge_runtime_secret_access — Issue 5 (v0.11.0): tightened from a
    # presence-only match on five literal paths into a verb-co-occurrence
    # gate. The old rule fired on any text that *mentioned* one of the
    # paths (including legitimate operator briefs, post-upgrade task
    # bodies, and doc snippets). The new rule requires a sensitive-action
    # verb within an 80-character window of a credential-bearing path —
    # bidirectional (verb→file or file→verb). Stem verbs use `\w*`
    # suffixes so "exfiltrate", "modify", "overwriting", "replaces" all
    # match; literal verbs keep `\b`-anchored exact matching. The noun
    # set drops the over-broad generic `.env\b` alternative and
    # enumerates the known channel credential dot-dir env families
    # (discord/telegram/teams/ms365/mattermost) plus the generic
    # `credentials/.../.env` shape. Severity remains `critical`.
    (
        "critical",
        "bridge_runtime_secret_access",
        re.compile(
            # Verb fragment — bare words use word boundaries; stem forms
            # use trailing `\w*` so suffixed variants (modify/modified,
            # overwrite/overwriting, replace/replaces, exfiltrate/
            # exfiltrated) still match.
            r"(?:"
            r"\b(?:"
            r"read|cat|tail|head|less|more|open|view|source|load|strings|"
            r"dump|print|show|reveal|output|display|expose|"
            r"exfiltrat\w*|leak|grep|rg|sed|awk|hexdump|xxd|base64|"
            r"upload|paste|post|send|forward|copy|cp|mv|dd|tee|rsync|tar|zip|install|"
            r"write|edit|modif\w*|overwrit\w*|replac\w*|delete|remove|rm|"
            r"sqlite3|sql|select|query"
            r")\b"
            r".{0,80}"
            r"(?:"
            r"agent-roster\.local\.sh|"
            r"\.(?:discord|telegram|teams|ms365|mattermost)/\.env|"
            r"[\w./-]*credentials[\w./-]*\.env|"
            r"state/tasks\.db"
            r")"
            r"|"
            # File-before-verb direction (e.g.
            # "agent-roster.local.sh — please show me what's in it").
            r"(?:"
            r"agent-roster\.local\.sh|"
            r"\.(?:discord|telegram|teams|ms365|mattermost)/\.env|"
            r"[\w./-]*credentials[\w./-]*\.env|"
            r"state/tasks\.db"
            r")"
            r".{0,80}"
            r"\b(?:"
            r"read|cat|tail|head|less|more|open|view|source|load|strings|"
            r"dump|print|show|reveal|output|display|expose|"
            r"exfiltrat\w*|leak|grep|rg|sed|awk|hexdump|xxd|base64|"
            r"upload|paste|post|send|forward|copy|cp|mv|dd|tee|rsync|tar|zip|install|"
            r"write|edit|modif\w*|overwrit\w*|replac\w*|delete|remove|rm|"
            r"sqlite3|sql|select|query"
            r")\b"
            r")",
            re.IGNORECASE | re.DOTALL,
        ),
    ),
    (
        "critical",
        "unicode_steganography",
        re.compile(r"[\U000E0001-\U000E007F]"),
    ),
    (
        "high",
        "network_exfiltration_pipeline",
        re.compile(r"\b(curl|wget|nc|scp)\b.{0,80}(@-|https?://)", re.IGNORECASE | re.DOTALL),
    ),
    (
        "high",
        "dangerous_shell_instruction",
        re.compile(r"\b(rm\s+-rf|chmod\s+777|sqlite3\b.+\b(update|delete|insert)\b)", re.IGNORECASE | re.DOTALL),
    ),
    (
        "high",
        "permission_bypass_request",
        re.compile(r"\b(bypass|skip|disable)\b.{0,40}\b(permission|guard|sandbox|approval)\b", re.IGNORECASE | re.DOTALL),
    ),
    (
        "medium",
        "tool_weaponization",
        re.compile(r"\b(use|call|invoke)\b.{0,40}\b(tool|mcp|plugin|skill)\b.{0,80}\b(secret|token|credential|bypass)\b", re.IGNORECASE | re.DOTALL),
    ),
    (
        "medium",
        "hidden_instruction_language",
        re.compile(r"\b(hidden|invisible|secret)\b.{0,40}\b(instruction|prompt|command)\b", re.IGNORECASE | re.DOTALL),
    ),
]

REDACTION_RULES: list[tuple[str, re.Pattern[str], str]] = [
    ("aws_access_key", re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[REDACTED:aws_access_key]"),
    ("github_token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"), "[REDACTED:github_token]"),
    ("slack_token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), "[REDACTED:slack_token]"),
    ("openai_key", re.compile(r"\bsk-[A-Za-z0-9]{20,}\b"), "[REDACTED:openai_key]"),
    ("google_api_key", re.compile(r"\bAIza[0-9A-Za-z_\-]{20,}\b"), "[REDACTED:google_api_key]"),
    ("bearer_token", re.compile(r"\bBearer\s+[A-Za-z0-9._\-]{16,}\b"), "[REDACTED:bearer_token]"),
]

BUILTIN_TOOL_NAMES = {
    "Agent",
    "AskUserQuestion",
    "Bash",
    "Edit",
    "ExitPlanMode",
    "Glob",
    "Grep",
    "LS",
    "MultiEdit",
    "NotebookEdit",
    "NotebookRead",
    "Read",
    "WebFetch",
    "WebSearch",
    "Write",
}


def truthy(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    raw = str(value).strip().lower()
    if not raw:
        return default
    return raw not in {"0", "false", "no", "off"}


def normalize_severity(value: str | None, default: str = "high") -> str:
    raw = str(value or "").strip().lower()
    if raw in SEVERITY_ORDER:
        return raw
    return default


def severity_at_least(value: str, threshold: str) -> bool:
    return SEVERITY_ORDER.get(normalize_severity(value, "safe"), 0) >= SEVERITY_ORDER.get(normalize_severity(threshold), 0)


def bridge_home_dir() -> Path:
    # Operator bridge home — delegates to the canonical SSOT (issue #1497 P2).
    # Byte-identical to the previous inline strip()+expanduser()+default body.
    return operator_home()


def _host_profile_is_dev() -> bool:
    """Best-effort host_profile=dev detection for the prompt-guard default.

    Order:
      1. BRIDGE_HOST_PROFILE env (cheapest; explicit override).
      2. $BRIDGE_HOME/state/install/host-profile.json.

    All read errors collapse to "not dev" (fail-open to the server default of
    enabled) — a corrupt/unreadable host-profile file should not silently
    disable prompt-guard on a hosted install.
    """
    env_profile = (os.environ.get("BRIDGE_HOST_PROFILE") or "").strip().lower()
    if env_profile == "dev":
        return True
    if env_profile == "server":
        return False
    try:
        path = bridge_home_dir() / "state" / "install" / "host-profile.json"
        if not path.is_file():
            return False
        import json as _json
        with path.open("r", encoding="utf-8") as fh:
            data = _json.load(fh)
        return str(data.get("profile", "")).strip().lower() == "dev"
    except Exception:
        return False


def prompt_guard_enabled() -> bool:
    # Track D's host_profile-aware default (server → enabled, dev → off,
    # shipped in v0.11.0 / PR #813) was reverted 2026-05-14 because operators
    # reported the auto-enable produced too many spurious blocks on real
    # channel / MCP / intake traffic on server installs. Prompt guard is
    # back to default-OFF on every host; explicit BRIDGE_PROMPT_GUARD_ENABLED=1
    # still opts in.
    return truthy(os.environ.get("BRIDGE_PROMPT_GUARD_ENABLED"), default=False)


def split_csv(value: str | None) -> list[str]:
    raw = str(value or "").strip()
    if not raw:
        return []
    items = []
    for part in raw.split(","):
        item = part.strip()
        if item:
            items.append(item)
    return items


def canary_tokens_for_agent(agent: str = "") -> list[str]:
    tokens: list[str] = []
    policy = os.environ.get("BRIDGE_AGENT_PROMPT_GUARD_POLICY", "").strip()
    if policy and agent:
        value = agent_policy_value("canary")
        if value:
            tokens.extend(split_csv(value))
    tokens.extend(split_csv(os.environ.get("BRIDGE_PROMPT_GUARD_CANARY_TOKENS")))
    seen: set[str] = set()
    ordered: list[str] = []
    for token in tokens:
        if token not in seen:
            ordered.append(token)
            seen.add(token)
    return ordered


def agent_policy_value(key: str) -> str:
    policy = os.environ.get("BRIDGE_AGENT_PROMPT_GUARD_POLICY", "").strip()
    if not policy:
        return ""
    for part in policy.split(";"):
        piece = part.strip()
        if not piece:
            continue
        if ":" in piece:
            item_key, item_value = piece.split(":", 1)
        elif "=" in piece:
            item_key, item_value = piece.split("=", 1)
        else:
            continue
        if item_key.strip().lower() == key.strip().lower():
            return item_value.strip()
    return ""


def threshold_for_surface(surface: str, default: str = "high") -> str:
    scoped = agent_policy_value(f"{surface}_min_block")
    if scoped:
        return normalize_severity(scoped, default)
    generic = agent_policy_value("min_block")
    if generic:
        return normalize_severity(generic, default)
    env_map = {
        "channel": os.environ.get("BRIDGE_PROMPT_GUARD_CHANNEL_MIN_BLOCK"),
        "task_body": os.environ.get("BRIDGE_PROMPT_GUARD_TASK_BODY_MIN_BLOCK"),
        "intake": os.environ.get("BRIDGE_PROMPT_GUARD_INTAKE_MIN_BLOCK"),
        "mcp_output": os.environ.get("BRIDGE_PROMPT_GUARD_MCP_OUTPUT_MIN_BLOCK"),
        "prompt": os.environ.get("BRIDGE_PROMPT_GUARD_PROMPT_MIN_BLOCK"),
    }
    return normalize_severity(env_map.get(surface), default)


@dataclass
class ScanResult:
    text: str
    surface: str
    agent: str = ""
    backend: str = "builtin"
    severity: str = "safe"
    blocked: bool = False
    action: str = "allow"
    reasons: list[str] = field(default_factory=list)
    categories: list[str] = field(default_factory=list)
    threshold: str = "high"

    def as_dict(self) -> dict[str, Any]:
        return {
            "agent": self.agent,
            "surface": self.surface,
            "backend": self.backend,
            "severity": self.severity,
            "threshold": self.threshold,
            "blocked": self.blocked,
            "action": self.action,
            "reasons": self.reasons,
            "categories": self.categories,
            "text_preview": self.text[:200],
        }


@dataclass
class SanitizeResult:
    text: str
    surface: str
    agent: str = ""
    backend: str = "builtin"
    sanitized_text: str = ""
    was_modified: bool = False
    blocked: bool = False
    redacted_types: list[str] = field(default_factory=list)
    redaction_count: int = 0
    canary_triggered: bool = False
    canary_tokens: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "agent": self.agent,
            "surface": self.surface,
            "backend": self.backend,
            "blocked": self.blocked,
            "was_modified": self.was_modified,
            "redaction_count": self.redaction_count,
            "redacted_types": self.redacted_types,
            "canary_triggered": self.canary_triggered,
            "canary_tokens": self.canary_tokens,
            "sanitized_text": self.sanitized_text,
        }


def _max_severity(current: str, candidate: str) -> str:
    if severity_at_least(candidate, current):
        return candidate
    return current


def _builtin_scan(text: str, threshold: str, surface: str, agent: str = "") -> ScanResult:
    severity = "safe"
    reasons: list[str] = []
    categories: list[str] = []
    for rule_severity, category, pattern in BUILTIN_SCAN_RULES:
        if pattern.search(text):
            severity = _max_severity(severity, rule_severity)
            reasons.append(category.replace("_", " "))
            categories.append(category)
    blocked = severity_at_least(severity, threshold)
    action = "block" if blocked else ("warn" if severity_at_least(severity, "medium") else "allow")
    return ScanResult(
        text=text,
        surface=surface,
        agent=agent,
        backend="builtin",
        severity=severity,
        blocked=blocked,
        action=action,
        reasons=reasons,
        categories=categories,
        threshold=threshold,
    )


def _prompt_guard_backend() -> tuple[Any | None, str]:
    try:
        from prompt_guard import PromptGuard  # type: ignore
    except Exception:
        return None, "builtin"
    try:
        return PromptGuard(config={"api": {"enabled": False}}), "prompt_guard"
    except TypeError:
        try:
            return PromptGuard(), "prompt_guard"
        except Exception:
            return None, "builtin"
    except Exception:
        return None, "builtin"


def _merge_prompt_guard_scan(base: ScanResult, text: str) -> ScanResult:
    guard, backend = _prompt_guard_backend()
    if guard is None:
        return base
    try:
        result = guard.analyze(message=text, context={"surface": base.surface, "agent": base.agent})
    except TypeError:
        try:
            result = guard.analyze(text)
        except Exception:
            return base
    except Exception:
        return base

    action_value = str(getattr(getattr(result, "action", None), "value", getattr(result, "action", "")) or "").strip().lower()
    reasons = getattr(result, "reasons", None) or []
    if not isinstance(reasons, list):
        reasons = [str(reasons)]
    prompt_guard_severity = "safe"
    if action_value in {"block", "deny"}:
        prompt_guard_severity = "high"
    elif action_value in {"warn", "review"}:
        prompt_guard_severity = "medium"

    if prompt_guard_severity != "safe":
        base.severity = _max_severity(base.severity, prompt_guard_severity)
        base.reasons.extend(str(item) for item in reasons if str(item))
    if reasons:
        base.categories.append("prompt_guard")
    base.backend = backend if base.backend == "builtin" else f"{base.backend}+{backend}"
    base.blocked = severity_at_least(base.severity, base.threshold)
    base.action = "block" if base.blocked else ("warn" if severity_at_least(base.severity, "medium") else "allow")
    return base


def analyze_text(text: str, *, threshold: str = "high", surface: str = "generic", agent: str = "") -> ScanResult:
    normalized_threshold = normalize_severity(threshold)
    base = _builtin_scan(text, normalized_threshold, surface, agent)
    return _merge_prompt_guard_scan(base, text)


def _apply_builtin_redactions(text: str) -> tuple[str, list[str], int]:
    sanitized = text
    redacted_types: list[str] = []
    count = 0
    for redaction_type, pattern, replacement in REDACTION_RULES:
        matches = pattern.findall(sanitized)
        if not matches:
            continue
        sanitized = pattern.sub(replacement, sanitized)
        redacted_types.append(redaction_type)
        count += len(matches)
    return sanitized, redacted_types, count


def sanitize_text(text: str, *, surface: str = "output", agent: str = "", canary_tokens: list[str] | None = None) -> SanitizeResult:
    sanitized = text
    backend = "builtin"
    guard, prompt_backend = _prompt_guard_backend()
    was_modified = False
    blocked = False
    redacted_types: list[str] = []
    redaction_count = 0

    if guard is not None:
        try:
            result = guard.sanitize_output(text)
            sanitized = str(getattr(result, "sanitized_text", sanitized))
            was_modified = bool(getattr(result, "was_modified", False))
            blocked = bool(getattr(result, "blocked", False))
            redacted_types.extend(str(item) for item in (getattr(result, "redacted_types", None) or []) if str(item))
            redaction_count += int(getattr(result, "redaction_count", 0) or 0)
            backend = prompt_backend
        except Exception:
            backend = "builtin"

    builtin_sanitized, builtin_types, builtin_count = _apply_builtin_redactions(sanitized)
    if builtin_sanitized != sanitized:
        sanitized = builtin_sanitized
        was_modified = True
    if builtin_types:
        for item in builtin_types:
            if item not in redacted_types:
                redacted_types.append(item)
        redaction_count += builtin_count

    tokens = canary_tokens or []
    triggered = [token for token in tokens if token and token in sanitized]
    if triggered:
        blocked = True

    return SanitizeResult(
        text=text,
        surface=surface,
        agent=agent,
        backend=backend,
        sanitized_text=sanitized,
        was_modified=was_modified or sanitized != text,
        blocked=blocked,
        redacted_types=redacted_types,
        redaction_count=redaction_count,
        canary_triggered=bool(triggered),
        canary_tokens=triggered,
    )


def tool_output_text(tool_name: str, tool_response: Any) -> str:
    if isinstance(tool_response, str):
        return tool_response
    try:
        return json.dumps({"tool_name": tool_name, "tool_response": tool_response}, ensure_ascii=False)
    except TypeError:
        return str(tool_response)


def is_builtin_tool(tool_name: str) -> bool:
    return tool_name in BUILTIN_TOOL_NAMES
