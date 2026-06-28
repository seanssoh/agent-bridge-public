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
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone, tzinfo
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
# #18849 Part 2 (cascade): the ``last_check_status`` values that mark an INACTIVE
# candidate token unavailable for rotation. ``quota_limited`` (a read-only
# ``check`` saw a 429 but ran WITHOUT ``--disable-on-quota``, so the row stayed
# enabled) and ``auth_failed`` (``check`` never disables on auth errors) are the
# two HARD signals an enabled candidate can still carry. ``timeout``/``failed``
# are transient/ambiguous and stay optimistically AVAILABLE (fail-safe — a flaky
# probe must never strand a token). See ``classify_probe`` for the vocabulary.
ROTATION_ADVERSE_CHECK_STATUSES = frozenset({"quota_limited", "auth_failed"})
# Freshness window for the adverse-check cascade signal: a hard-error check older
# than this is treated as STALE and the candidate becomes optimistically
# available again, so a refreshed credential is never permanently stranded by a
# day-old ``auth_failed``. Overridable via env for tests / tuning.
ROTATION_ADVERSE_CHECK_MAX_AGE_SECONDS = 21600  # 6h
CLAUDE_OAUTH_EXPIRES_AT_MS = 4102444800000
# Declarative scopes seeded into a FRESH credential payload (sync-agent / a
# created operator-global file). This is the REQUESTED-scope metadata field, not
# an actual grant — the token's real scopes are fixed at mint time. ``user:profile``
# was only ever seeded here for the displayed-identity probe; #18849 Part 1b-v2
# (closes #2145) sources the displayed identity from the operator-provided
# ``account_email`` instead, so we no longer declare a scope the pool tokens do not
# actually carry (the profile endpoint 403s on them). The usage probe's real
# scope requirement is unaffected — it depends on the minted grant, not this field.
CLAUDE_OAUTH_SCOPES = ["user:inference"]
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


# ---------------------------------------------------------------------------
# Issue #2137 — keychain-free auth hardening (RCA of a live macOS incident
# where the keychain-free backfill silently moved the interactive admin onto
# API-key billing → `Invalid API key`).
#   - fix #4: a sanctioned single-key writer for the runtime-config gate so the
#     operator never raw-edits bridge-config.json (and is not blocked by the
#     set-env `KEY`-substring guard).
#   - fix #5: an enable-time, fail-closed preflight.
#   - fix #6: best-effort audit rows around settings/gate writes so RCA can
#     identify which subprocess wrote `apiKeyHelper` into a given agent.


def auth_audit_log_path() -> Path | None:
    """Resolve the bridge audit log for credential-side writes (#2137 fix #6).

    Honors ``BRIDGE_AUDIT_LOG`` (the rest of the audit chain + the smokes use
    it); else derives ``<runtime-root>/../logs/audit.jsonl`` from
    ``BRIDGE_RUNTIME_ROOT`` or ``<BRIDGE_HOME>/logs/audit.jsonl``. Returns None
    when no root resolves, so the audit write degrades to a no-op rather than
    guessing a path."""
    explicit = os.environ.get("BRIDGE_AUDIT_LOG", "").strip()  # noqa: iso-helper-boundary - controller audit log
    if explicit:
        return Path(explicit).expanduser()
    runtime_root = os.environ.get("BRIDGE_RUNTIME_ROOT", "").strip()  # noqa: iso-helper-boundary - controller runtime root
    if runtime_root:
        return Path(runtime_root).expanduser().parent / "logs" / "audit.jsonl"
    bridge_home = os.environ.get("BRIDGE_HOME", "").strip()  # noqa: iso-helper-boundary - controller bridge home
    if bridge_home:
        return Path(bridge_home).expanduser() / "logs" / "audit.jsonl"
    return None


def auth_write_audit(detail: dict[str, Any]) -> None:
    """Append a best-effort JSONL audit row for a credential-side mutation.

    Issue #2137 fix #6: future RCA must be able to identify WHICH subprocess
    wrote ``apiKeyHelper`` into a given agent (and which flipped the
    keychain-free gate). Records agent/writer/action plus the resolved pid+ppid —
    never a secret value. Best-effort: an unwritable log must never fail the auth
    op (the credential write is the source of truth, not the audit row)."""
    # The ENTIRE body is wrapped — including auth_audit_log_path()'s path
    # resolution and now_iso() — and catches Exception (not just OSError), so no
    # failure here (a malformed env path, an exotic now_iso() input, a serialize
    # error) can escape AFTER the credential/settings/gate write has already
    # succeeded. The audit row is strictly best-effort (codex r2 finding).
    try:
        log_path = auth_audit_log_path()
        if log_path is None:
            return
        log_path.parent.mkdir(parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only - controller audit dir
        record = {
            "ts": now_iso(),
            "actor": "bridge-auth",
            "action": str(detail.get("kind") or "claude_auth_event"),
            "pid": os.getpid(),
            "ppid": os.getppid(),
            "detail": detail,
        }
        with log_path.open("a", encoding="utf-8") as fh:  # noqa: raw-pathlib-controller-only - controller audit append
            fh.write(json.dumps(record, ensure_ascii=True) + "\n")
    except Exception:  # noqa: BLE001 - audit is best-effort; never fail the auth op
        return


def settings_writer_context() -> str:
    """Writer-context label for the settings audit row (#2137 fix #6).

    ``BRIDGE_SETTINGS_WRITER`` lets a caller name the originating pass; else the
    invoking script basename so the audit row is never anonymous."""
    explicit = os.environ.get("BRIDGE_SETTINGS_WRITER", "").strip()  # noqa: iso-helper-boundary - controller writer context
    if explicit:
        return explicit
    try:
        return Path(sys.argv[0]).name or "bridge-auth.py"
    except (IndexError, ValueError):
        return "bridge-auth.py"


def keychain_free_active_token_health(registry_path: Path) -> tuple[bool, str]:
    """Health of the active OAT the apiKeyHelper would serve, WITHOUT printing a
    secret (issue #2137 fix #5).

    Healthy = an active token is registered, enabled, and structurally valid
    (``active_registry_token``), and its last recorded probe is not an auth
    failure. Returns ``(ok, reason)`` where ``reason`` is a generic label, never
    the token value."""
    try:
        registry = load_registry(registry_path)
    except Exception as exc:  # noqa: BLE001 - unreadable registry → unhealthy
        return False, f"registry_unreadable: {exc}"
    try:
        active_id, _token = active_registry_token(registry)
    except ValueError as exc:
        return False, f"active_token_unhealthy: {exc}"
    row = find_token(registry, active_id) or {}
    last_status = str(row.get("last_check_status") or "")
    if last_status in ("auth_failed", "invalid", "expired"):
        return False, f"active_token_last_check_status={last_status}"
    return True, "active_token_healthy"


def keychain_free_preflight(registry_path: Path) -> dict[str, Any]:
    """Issue #2137 fix #5: enable-time preflight.

    Validates that flipping the keychain-free gate ON would NOT immediately break
    interactive Claude. Three checks — supported platform (macOS), an executable
    helper, and a healthy active registry OAT — and the aggregate ``ok`` is their
    conjunction. No secret is read into the result."""
    helper = claude_api_key_helper_path()
    platform_ok = keychain_free_apikeyhelper_supported()
    helper_exec = False
    helper_detail = helper
    try:
        helper_exec = os.path.isfile(helper) and os.access(helper, os.X_OK)  # noqa: raw-pathlib-controller-only - controller helper probe
    except OSError as exc:
        helper_detail = f"helper_probe_error: {exc}"
    if not helper_exec and helper_detail == helper:
        helper_detail = f"helper_not_executable: {helper}"
    token_ok, token_detail = keychain_free_active_token_health(registry_path)
    checks = [
        {"check": "platform_supported", "ok": platform_ok, "detail": host_platform()},
        {"check": "helper_executable", "ok": helper_exec, "detail": helper_detail},
        {"check": "active_token_health", "ok": token_ok, "detail": token_detail},
    ]
    return {
        "ok": bool(platform_ok and helper_exec and token_ok),
        "api_key_helper": helper,
        "checks": checks,
    }


def write_keychain_free_gate(enabled: bool) -> tuple[Path | None, str]:
    """Issue #2137 fix #4: sanctioned single-key writer for the
    ``claude_keychain_free_auth`` runtime-config boolean.

    The blessed admin path so the operator never raw-edits bridge-config.json
    (and is not blocked by the set-env ``KEY``-substring guard). Read-modify-write
    preserves every other config key; only the one boolean is set. Returns
    ``(path, "ok")`` or ``(None, reason)`` and never clobbers a malformed config."""
    path = runtime_config_path()
    if path is None:
        return None, "no_runtime_config_path (set BRIDGE_RUNTIME_ROOT or BRIDGE_HOME)"
    config: dict[str, Any] = {}
    mode = 0o600
    if path.is_file():  # noqa: raw-pathlib-controller-only - controller runtime config probe
        try:
            mode = path.stat().st_mode & 0o777  # noqa: raw-pathlib-controller-only - controller runtime config mode
            parsed = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001 - malformed config → refuse, do not clobber
            return None, f"runtime_config_unreadable: {exc}"
        if not isinstance(parsed, dict):
            return None, "runtime_config_not_object"
        config = parsed
    config[KEYCHAIN_FREE_CONFIG_KEY] = bool(enabled)
    text = json.dumps(config, ensure_ascii=True, indent=2) + "\n"
    try:
        write_private_file_atomic(path, text, mode=mode, prefix=".bridge-config.")
    except OSError as exc:
        return None, f"runtime_config_write_failed: {exc}"
    return path, "ok"


def keychain_free_env_override() -> str | None:
    """Return the set, non-empty ``BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH`` env value, or
    None (issue #2137 fix #4 hardening).

    ``claude_keychain_free_auth_enabled`` gives a non-empty env override
    precedence over the runtime config, so a `keychain-free enable/disable` that
    only writes config would be SHADOWED (silently no-op) when the override is
    set — the exact "looks applied but isn't" misconfiguration the incident was
    about. The verb refuses to write under a live override and surfaces it in
    `status` instead. An unset / empty override (the production default) returns
    None so the config write is authoritative."""
    raw = os.environ.get("BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH")  # noqa: iso-helper-boundary - controller feature gate
    if raw is not None and raw.strip():
        return raw.strip()
    return None


def token_fingerprint(token: str) -> str:
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    tail = token[-4:] if len(token) >= 4 else token
    return f"sha256:{digest[:12]}...{tail}"


def _usage_cache_token_digest(token: str) -> str:
    """One-way 16-char SHA-256 prefix that keys a token to its usage-cache reading.

    #2171 PR-B3: the measured-usage prefilter matches a rotation candidate against
    the `.usage-cache.json` `_token_digest` field, which the usage probe writes via
    ``bridge-usage-probe.py:_token_signal_digest`` — a 16-char SHA-256 hex prefix
    carrying NO token bytes. This MUST stay byte-for-byte identical to that digest
    (a single-char drift makes every candidate miss the cache → the prefilter goes
    silently inert). It is deliberately NOT ``token_fingerprint`` above, whose
    ``sha256:<12>...<tail>`` display form appends the last 4 raw token chars and
    would never match a cache key. Empty token → empty digest (no match)."""
    if not token:
        return ""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]


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


# RFC 5321 caps a forward-path (the whole address) at 254 chars; we only need a
# sane upper bound so an absurd value can never bloat the registry / a log line.
ACCOUNT_EMAIL_MAX_LEN = 254


def validate_account_email(value: str | None) -> str:
    """Local FORMAT-only validation of an operator-provided account email.

    #18849 Part 1b-v2 (closes #2145): the displayed Claude identity is sourced
    from the operator-provided account email captured in the token registry, not
    a ``user:profile`` probe. This is the gate for that value. It TRIMS and
    rejects empty, control/newline chars, internal whitespace, a missing or
    multiple ``@``, an empty local-part/domain, and an unreasonable length. It
    NEVER touches the network and NEVER infers the address from the token id —
    the whole point is to drop the probe dependency, not relocate the guess.
    Returns the trimmed, validated address.
    """
    email = str(value or "").strip()
    if not email:
        raise ValueError("account email is empty")
    if len(email) > ACCOUNT_EMAIL_MAX_LEN:
        raise ValueError(
            f"account email is too long (>{ACCOUNT_EMAIL_MAX_LEN} chars)"
        )
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in email):
        raise ValueError("account email cannot contain control characters")
    if any(ch.isspace() for ch in email):
        raise ValueError("account email cannot contain whitespace")
    if email.count("@") != 1:
        raise ValueError("account email must contain exactly one '@'")
    local, _, domain = email.partition("@")
    if not local or not domain:
        raise ValueError("account email must have a non-empty local part and domain")
    return email


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
        "weekly_warn_threshold": 95.0,
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
        # #18849 Part 1b-v2 (closes #2145) — per-token account identity (non-secret).
        # ``account_email`` is the displayed-identity source ONLY when
        # ``account_email_source == "operator"`` (the operator provided it at
        # add/receive/set). ``account_email_set_at`` stamps that capture. A
        # probe-sourced or unmarked-legacy ``account_email`` is NOT trusted for the
        # write (see ``operator_account_email``).
        #
        # The ``account_email_probe_*`` fields are an OPTIONAL, default-OFF
        # verify-only DIAGNOSTIC stored SEPARATELY from the operator source: the
        # probe never sets ``account_email`` and a mismatch only WARNs. ``status`` ∈
        # {verified, verify_skipped, mismatch, probe_failed}; ``reason`` is the
        # granular outcome; ``observed`` is the probe-seen email (diagnostic only).
        "account_email": row.get("account_email") or "",
        "account_email_source": row.get("account_email_source") or "",
        "account_email_set_at": row.get("account_email_set_at") or "",
        "account_email_verified_at": row.get("account_email_verified_at") or "",
        "account_subject": row.get("account_subject") or "",
        "account_email_probe_status": row.get("account_email_probe_status") or "",
        "account_email_probe_reason": row.get("account_email_probe_reason") or "",
        "account_email_probe_observed": row.get("account_email_probe_observed") or "",
    }


def public_registry(registry: dict[str, Any]) -> dict[str, Any]:
    active_id = str(registry.get("active_token_id") or "")
    return {
        "version": REGISTRY_VERSION,
        "active_token_id": active_id,
        "auto_rotate_enabled": bool(registry.get("auto_rotate_enabled", False)),
        "rotation_threshold": float(registry.get("rotation_threshold") or 99.0),
        "weekly_warn_threshold": float(registry.get("weekly_warn_threshold") or 95.0),
        "tokens": [public_token_row(row, active_id) for row in token_rows(registry)],
        "last_rotation": registry.get("last_rotation") or {},
    }


def enabled_token_ids(registry: dict[str, Any]) -> list[str]:
    ids = []
    for row in token_rows(registry):
        if bool(row.get("enabled", True)) and row.get("token"):
            ids.append(str(row.get("id") or ""))
    return [token_id for token_id in ids if token_id]


def token_limited_until(row: dict[str, Any]) -> datetime | None:
    """Parse a token row's ``limited_until`` stamp (#1789).

    The stamp is the 429-derived ``reset_at`` recorded when the token was
    rotated away at-limit — an ISO timestamp, never token bytes. Returns None
    when absent or unparseable (an unreadable stamp must never strand a token
    as permanently ineligible).
    """
    return iso_to_utc(str(row.get("limited_until") or ""))


def _rotation_adverse_check_max_age_seconds() -> float:
    """Freshness window (seconds) for the adverse-check cascade signal (#18849).

    Reads ``BRIDGE_CLAUDE_ROTATION_ADVERSE_CHECK_MAX_AGE_SECONDS`` when set to a
    positive number; otherwise the ``ROTATION_ADVERSE_CHECK_MAX_AGE_SECONDS``
    default. A non-positive / unparseable override falls back to the default so a
    bad value can never collapse the window to zero.
    """
    raw = os.environ.get("BRIDGE_CLAUDE_ROTATION_ADVERSE_CHECK_MAX_AGE_SECONDS")
    if raw:
        try:
            value = float(raw)
        except ValueError:
            value = 0.0
        if value > 0:
            return value
    return float(ROTATION_ADVERSE_CHECK_MAX_AGE_SECONDS)


def _coerce_usage_percent(value: Any) -> float | None:
    """Coerce a usage-cache window value to a float percent, else None.

    Mirrors the monitor's ``float(used_percent)`` try/except (bridge-usage.py) so
    a non-numeric / absent window contributes no near-limit signal. ``bool`` is
    rejected explicitly (``isinstance(True, int)`` is True in Python) so a stray
    JSON boolean can never be read as 0%/1%."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _build_measured_usage_index(
    cache_paths: "list[str | Path]",
    *,
    rotation_threshold: float,
    weekly_warn_threshold: float,
    cache_max_age_seconds: float,
    now: datetime,
) -> dict[str, dict[str, bool]]:
    """Token-free measured-usage prefilter index, built OUTSIDE ``registry_lock``.

    #2171 PR-B3: ``rotation_candidate_availability`` selects from LIGHT registry
    stamps and never the candidate's own measured usage, so a near-limit-but-
    unstamped token can still be chosen (the #19460 M4 fleet-down selection gap).
    This builder reads each ``.usage-cache.json`` (the shape
    ``bridge-usage-probe.py:map_payload_to_cache`` writes — ``data.fiveHour`` /
    ``data.sevenDay`` used %, ``_token_digest``, ``_written_at``) and precomputes,
    per token digest, whether each window is at/over its threshold:

        {token_digest: {"5h": near_limit_bool, "weekly": near_limit_bool}}

    The near-limit BOOLEANS are precomputed HERE so the eligibility predicate
    hard-codes no threshold. Freshness + thresholds REUSE the monitor's semantics
    (no new knobs): ``rotation_threshold`` for 5h, ``weekly_warn_threshold`` for
    weekly, and the conservative ``_cache_is_fresh`` rule — a reading is dropped
    ONLY when its ``_written_at`` is present, parseable, and older than
    ``cache_max_age_seconds`` (a non-positive max-age disables the gate). EVERY
    error path FAILS OPEN: an absent / unreadable / malformed cache, a non-dict
    payload, a missing/empty ``_token_digest``, a provably-stale reading, or a
    non-numeric window contributes nothing, so the candidate falls back to the
    existing registry-stamp eligibility (additive, no regression; an install with
    no usage cache is a no-op). NEVER returns token bytes — only digest keys.

    All cache file IO lives here (outside the lock); the predicate reads only the
    returned in-memory index."""
    index: dict[str, dict[str, bool]] = {}
    for raw_path in cache_paths:
        try:
            payload = json.loads(Path(str(raw_path)).expanduser().read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        digest = payload.get("_token_digest")
        if not isinstance(digest, str) or not digest:
            continue
        if cache_max_age_seconds > 0:
            written_at = payload.get("_written_at")
            if isinstance(written_at, str) and written_at:
                written_dt = iso_to_utc(written_at)
                if written_dt is not None and (now - written_dt).total_seconds() > cache_max_age_seconds:
                    continue
        data = payload.get("data")
        if not isinstance(data, dict):
            data = payload.get("lastGoodData")
        if not isinstance(data, dict):
            continue
        five_hour = _coerce_usage_percent(data.get("fiveHour"))
        seven_day = _coerce_usage_percent(data.get("sevenDay"))
        entry = index.setdefault(digest, {"5h": False, "weekly": False})
        if five_hour is not None and five_hour >= rotation_threshold:
            entry["5h"] = True
        if seven_day is not None and seven_day >= weekly_warn_threshold:
            entry["weekly"] = True
    return index


def _measured_usage_index_from_args(
    args: argparse.Namespace, now: datetime
) -> dict[str, dict[str, bool]]:
    """Build the measured-usage prefilter index from the rotate args (or empty).

    No ``--measured-usage-cache`` paths (the default until PR-B2 wires the daemon)
    => empty index => the eligibility gate is a no-op (byte-identical to before)."""
    cache_paths = list(getattr(args, "measured_usage_cache", None) or [])
    if not cache_paths:
        return {}
    return _build_measured_usage_index(
        cache_paths,
        rotation_threshold=float(getattr(args, "rotation_threshold", 99.0)),
        weekly_warn_threshold=float(getattr(args, "weekly_warn_threshold", 95.0)),
        cache_max_age_seconds=float(getattr(args, "cache_max_age_seconds", 21600)),
        now=now,
    )


def rotation_candidate_availability(
    row: dict[str, Any],
    now: datetime,
    *,
    adverse_check_max_age_seconds: float,
    measured_usage_index: dict[str, dict[str, bool]] | None = None,
) -> tuple[bool, datetime | None, str]:
    """Cascade availability of an enabled candidate token (#18849 Part 2).

    Returns ``(available, reset_at, reason)`` — ``reason`` is ``""`` when
    available, ``"registry_stamp"`` for a light-signal block (the legacy cascade /
    preflight Step A trace folds this into its existing ``stale_flag_unavailable``
    string), or ``"measured_near_limit"`` for the #2171 PR-B3 prefilter block
    below. The candidate is UNAVAILABLE when it is
    inside a known cooldown window — ``limited_until`` (#1789, the 429-derived
    rotate-away stamp) or ``disabled_until`` (the quota cooldown) still in the
    future — OR its most-recent ``last_check_status`` is a hard limit/auth error
    (:data:`ROTATION_ADVERSE_CHECK_STATUSES`) WITHIN the freshness window.

    An INACTIVE token has no live usage %, so cascade judges availability from
    these light registry signals only — never a per-candidate usage probe in the
    rotate loop (an API call per token = expensive + rate-limit risk, and the
    loop runs under the registry lock). Fail-safe: an absent/unparseable stamp, a
    STALE adverse check, a FUTURE-dated check stamp (clock skew / hand-edit), or a
    missing/non-adverse ``last_check_status`` is treated as AVAILABLE
    ("available-but-unverified"). That never strands a token; a
    genuinely-capped optimistic pick self-corrects on its next real 429 (the
    reactive path re-stamps ``limited_until`` and the PR-1 ``_token_digest`` gate
    suppresses the post-rotation ping-pong), so the residual thrash is bounded.

    ``reset_at`` is the soonest cooldown expiry for a WINDOW-based block (drives
    the daemon's pool-exhausted suppression/notice cadence). It is ``None`` for an
    adverse-check block (an auth error carries no reset), so an adverse-only
    exhaustion falls back to the daemon's short floor cooldown.

    #2171 PR-B3: ``measured_usage_index`` (default empty ⇒ no-op) adds a cheap
    selection-time prefilter AFTER the registry-stamp checks: a candidate that
    otherwise looks available is still skipped when its OWN most-recent measured
    usage is at/over a window threshold (the #19460 M4 gap where a near-limit-but-
    unstamped token was chosen, then synced fleet-wide). The index is built OUTSIDE
    the registry lock (``_build_measured_usage_index``) and injected here; this
    predicate does NO cache IO — it only computes the candidate's one-way digest
    and reads the precomputed near-limit booleans. Absent / no-digest-match ⇒
    FAIL OPEN to the registry-stamp verdict (additive; LTS / no-cache installs are
    a no-op). It does NOT close the stale/missing-cache worst case on its own — the
    daemon's PR-B1 ``--preflight`` live probe (enabled by PR-B2) is that backstop.
    """
    reset_at: datetime | None = None
    for stamp in (
        token_limited_until(row),
        iso_to_utc(str(row.get("disabled_until") or "")),
    ):
        if stamp is not None and stamp > now:
            if reset_at is None or stamp < reset_at:
                reset_at = stamp
    if reset_at is not None:
        return False, reset_at, "registry_stamp"
    if str(row.get("last_check_status") or "") in ROTATION_ADVERSE_CHECK_STATUSES:
        checked_at = iso_to_utc(str(row.get("last_checked_at") or ""))
        if checked_at is not None:
            age_seconds = (now - checked_at).total_seconds()
            # Only a check whose age is within ``[0, max_age]`` blocks the
            # candidate. A FUTURE stamp (clock skew / hand-edit) yields a
            # NEGATIVE age — untrusted, so it fails OPEN (available); honoring it
            # would strand the token until the future time + window, which the
            # fail-safe model forbids.
            if 0 <= age_seconds <= adverse_check_max_age_seconds:
                return False, None, "registry_stamp"
    # #2171 PR-B3 measured-usage prefilter (additive; fail-open). The candidate
    # passed the registry-stamp checks; reject it ONLY when its own digest maps to
    # a precomputed near-limit reading in the injected index. No index / no digest
    # match ⇒ available, exactly as before.
    if measured_usage_index:
        token = str(row.get("token") or "")
        if token:
            entry = measured_usage_index.get(_usage_cache_token_digest(token))
            if entry and (entry.get("5h") or entry.get("weekly")):
                return False, None, "measured_near_limit"
    return True, None, ""


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


def _resolve_month(token: str) -> int | None:
    """Resolve a month token to its number (#17927).

    Accepts a full name (``July``) or a 3+ letter abbreviation (``Jul``,
    ``Sept``) — the real weekly-429 string uses the abbreviated form, which
    the full-name-only ``MONTHS`` map never matched. The 3-letter prefixes of
    the twelve months are all distinct, so the prefix match is unambiguous.
    """
    key = (token or "").strip().lower()
    if not key:
        return None
    if key in MONTHS:
        return MONTHS[key]
    if len(key) >= 3:
        for name, num in MONTHS.items():
            if name[:3] == key[:3]:
                return num
    return None


def _resolve_reset_tz(label: str) -> tzinfo | None:
    """Resolve a 429 reset-string timezone label to a ``tzinfo`` (#17927).

    Anthropic's weekly-limit message stamps a NAMED zone — e.g.
    ``resets Jul 1 at 12pm (Asia/Seoul)`` — not always ``(UTC)``. ``UTC`` /
    ``GMT`` / ``Z`` map to ``timezone.utc``; any other label is treated as an
    IANA key and resolved via stdlib ``zoneinfo``. An unknown key or missing
    tzdata returns ``None`` so the caller skips the stamp gracefully instead
    of raising.
    """
    name = (label or "").strip()
    if not name:
        return None
    if name.upper() in {"UTC", "GMT", "Z"}:
        return timezone.utc
    try:
        from zoneinfo import ZoneInfo

        return ZoneInfo(name)
    except (KeyError, ValueError, OSError, ImportError):
        # ZoneInfoNotFoundError subclasses KeyError; a malformed key raises
        # ValueError; missing tzdata raises OSError/ImportError. All mean
        # "cannot resolve" → fall back rather than crash the probe.
        return None


def parse_reset_at(text: str, reference: datetime | None = None) -> str:
    if not text:
        return ""
    reference = reference or now_utc()
    # The weekly-429 string is ``resets Jul 1 at 12pm (Asia/Seoul)`` — an
    # "at" separator (no comma) and a NAMED timezone — while the older form
    # is ``resets May 13, 3am (UTC)``. Tolerate the three real separators
    # between the day and the hour — a comma (``1, 12pm``), `` at `` (``1 at
    # 12pm``), or a bare space (``1 12pm``) — but REQUIRE one of them: the
    # separator must not be fully optional or ``resets Jul 112pm (UTC)``
    # over-matches as ``Jul 11`` + ``2pm`` (#17927 codex r1). Accept either
    # ``UTC`` or an IANA zone name in the parens.
    absolute = re.search(
        r"\bresets?\s+([A-Za-z]+)\s+(\d{1,2})(?:\s*,\s*|\s+at\s+|\s+)"
        r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(\s*([A-Za-z0-9_+\-/]+)\s*\)",
        text,
        re.IGNORECASE,
    )
    if absolute:
        month = _resolve_month(absolute.group(1))
        zone = _resolve_reset_tz(absolute.group(6))
        if month and zone is not None:
            day = int(absolute.group(2))
            hour = int(absolute.group(3))
            minute = int(absolute.group(4) or "0")
            meridiem = absolute.group(5).lower()
            if meridiem == "pm" and hour != 12:
                hour += 12
            if meridiem == "am" and hour == 12:
                hour = 0
            # Build the reset instant in the stated zone, then normalize to
            # UTC. For ``(UTC)`` this is byte-identical to the legacy
            # direct-UTC construction.
            local = datetime(reference.year, month, day, hour, minute, tzinfo=zone)
            candidate = local.astimezone(timezone.utc)
            if candidate < reference - timedelta(days=1):
                candidate = local.replace(year=reference.year + 1).astimezone(timezone.utc)
            return candidate.isoformat(timespec="seconds")

    relative = re.search(r"\bresets?\s+in\s+(\d+)h(?:\s+(\d+)m)?", text, re.IGNORECASE)
    if relative:
        hours = int(relative.group(1))
        minutes = int(relative.group(2) or "0")
        return (reference + timedelta(hours=hours, minutes=minutes)).isoformat(timespec="seconds")

    return ""


# Token-kind classification (#18696 / #2141) — backported to the v0.16 LTS line
# for the #2171 PR-B1 live-preflight, which gates OAT-native probing on the kind
# (the classifier shipped on mainline via #2141 but was not on the v0.16 line).
CLAUDE_API_KEY_TOKEN_PREFIX = "sk-ant-api"
CLAUDE_OAT_TOKEN_PREFIX = "sk-ant-oat"
TOKEN_KIND_API_KEY = "api_key"
TOKEN_KIND_OAUTH_OAT = "oauth_oat"
TOKEN_KIND_UNKNOWN = "unknown"


def classify_token_kind(token: str) -> str:
    """Classify a Claude credential by prefix (#18696).

    Returns one of ``api_key`` | ``oauth_oat`` | ``unknown``. FAIL-CLOSED: an
    empty / malformed / unrecognized token classifies as ``unknown`` — NEVER
    ``api_key``. The kind is always derived from the token bytes, never trusted
    from a schema field (legacy rows carry no kind).
    """
    if not isinstance(token, str):
        return TOKEN_KIND_UNKNOWN
    candidate = token.strip()
    if candidate.startswith(CLAUDE_API_KEY_TOKEN_PREFIX):
        return TOKEN_KIND_API_KEY
    if candidate.startswith(CLAUDE_OAT_TOKEN_PREFIX):
        return TOKEN_KIND_OAUTH_OAT
    return TOKEN_KIND_UNKNOWN


def active_registry_token_kind(registry_path: Path) -> str:
    """Kind of the active registry token, FAIL-CLOSED (#18696).

    ``classify_token_kind(active_token)`` — or ``unknown`` when there is no
    active token, it is disabled/missing/invalid, or the registry is unreadable.
    """
    try:
        registry = load_registry(registry_path)
        _active_id, token = active_registry_token(registry)
    except Exception:  # noqa: BLE001 - any failure → fail-closed unknown
        return TOKEN_KIND_UNKNOWN
    return classify_token_kind(token)


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
        # #2171 PR-B1: whether stdout parsed as JSON. The legacy fallback below
        # treats unparseable stdout with rc0 as ``available`` (fail-OPEN, kept
        # for the existing reactive paths); a strict caller (cmd_rotate
        # live-preflight) must reject that "available" as parse-unknown.
        "json_ok": payload is not None,
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


def probe_claude_token(token: str, timeout_seconds: float) -> dict[str, Any]:
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


def recover_apply_clock_or_probe(
    row: dict[str, Any],
    probe: dict[str, Any],
    *,
    reference: datetime,
    retry_seconds: int,
) -> None:
    """Re-enable a due quota_limited row on the clock, not the probe (#17927).

    When the row carries a 429-derived reset stamp — ``limited_until``
    (#1789), or ``disabled_until`` as the fallback gate — that stamp, not the
    cheap ``claude -p`` probe, decides recovery:

      * stamp elapsed  -> re-enable even when the probe is unavailable or
        failing. A weekly-capped token can still pass a tiny probe, and a
        healthy token can fail one transiently, so the probe is an unreliable
        quota oracle. If the token is somehow still capped, the next real use
        429s and the reactive path re-disables + re-stamps it (self-correcting).
      * stamp in the future -> stay disabled even if the probe says
        ``available`` (kills the over-recovery thrash that forced a manual
        hold list); recheck only once the stamp passes.

    A row with NO reset stamp at all (legacy/orphan, pre-#17927) keeps the
    original probe-driven behavior so existing installs do not regress.
    """
    reset_stamp = token_limited_until(row)
    if reset_stamp is None:
        reset_stamp = iso_to_utc(str(row.get("disabled_until") or ""))
    if reset_stamp is None:
        update_row_from_probe(
            row,
            probe,
            enable_on_ok=True,
            disable_on_quota=True,
            retry_seconds=retry_seconds,
        )
        return
    timestamp = now_iso()
    row["last_checked_at"] = timestamp
    row["last_check_status"] = str(probe.get("status") or "failed")
    row["last_check_api_error_status"] = str(probe.get("api_error_status") or "")
    row["last_check_returncode"] = int(probe.get("returncode") or 0)
    if reset_stamp <= reference:
        row["enabled"] = True
        clear_quota_disable_fields(row)
        row.pop("limited_until", None)
    else:
        stamp_iso = reset_stamp.isoformat(timespec="seconds")
        row["enabled"] = False
        row["disabled_reason"] = "quota_limited"
        row["disabled_until"] = stamp_iso
        row["next_check_at"] = stamp_iso
    row["updated_at"] = timestamp


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
    weekly_warn_threshold: float | None = None,
    account_email: str = "",
) -> dict[str, Any]:
    """Write *token* into the locked registry under *token_id*.

    Shared core for ``cmd_add`` and ``cmd_receive`` (#1367). The token
    is already in process memory (read from ``--stdin``/``--token-file``
    for ``add``, or echo-off from ``/dev/tty`` for ``receive``); this
    helper performs the locked read-modify-write only. Token + account_email
    validation is the caller's responsibility (done OUTSIDE the lock so the
    critical section stays narrow, per PR #799 r2 codex finding 3).

    ``account_email`` (#18849 Part 1b-v2) is the operator-provided, already-
    validated displayed-identity source. Each call rebuilds the row from
    scratch, so a ``--replace`` that does NOT carry an explicit account_email
    DROPS any prior ``account_email`` / source / probe metadata — a replaced
    token can never silently inherit the old identity (the stale-email gate).

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

        # Operator-provided displayed-identity source (non-secret), already
        # format-validated by the caller. Stamping it onto the freshly-rebuilt
        # row is what makes a replace WITHOUT an explicit email clear the stale
        # identity, and a replace WITH one write the new operator identity.
        if account_email:
            row["account_email"] = account_email
            row["account_email_source"] = "operator"
            row["account_email_set_at"] = timestamp

        if activate or not registry.get("active_token_id"):
            registry["active_token_id"] = token_id
            row["last_activated_at"] = timestamp
        if enable_auto_rotate:
            registry["auto_rotate_enabled"] = True
        if threshold is not None:
            registry["rotation_threshold"] = validate_threshold(threshold)
        if weekly_warn_threshold is not None:
            registry["weekly_warn_threshold"] = validate_threshold(weekly_warn_threshold)

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
        account_email = (
            validate_account_email(args.account_email)
            if getattr(args, "account_email", None)
            else ""
        )
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
            weekly_warn_threshold=args.weekly_warn_threshold,
            account_email=account_email,
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
    print(f"weekly_warn_threshold: {payload['weekly_warn_threshold']:.0f}%")
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
            # #1789 (PR #1790 r2): explicit activation is an operator
            # override — drop any limit-window stamp so the token is not
            # hiddenly skipped by future rotations until the old timestamp
            # expires. Mirrors the rotate-path cleanup.
            row.pop("limited_until", None)
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


def cmd_set(args: argparse.Namespace) -> int:
    """Set per-token operator metadata (#18849 Part 1b-v2, closes #2145).

    Currently the operator-provided ``--account-email`` — the displayed-identity
    source. The marker ``account_email_source="operator"`` is what makes the
    value BINDING for the ~/.claude.json identity write. Setting it supersedes
    any stale probe diagnostic on the row (the probe is verify-only and its
    findings are meaningless against a freshly configured value). The address is
    format-validated OUTSIDE the lock; the row is mutated under ``registry_lock``.
    """
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    try:
        validate_token_id(args.id)
        account_email = validate_account_email(args.account_email)
    except Exception as exc:
        return fail(str(exc), json_mode)
    try:
        with registry_lock(registry_path):
            registry = load_registry(registry_path)
            row = find_token(registry, args.id)
            if row is None:
                raise ValueError(f"unknown token id: {args.id}")
            timestamp = now_iso()
            row["account_email"] = account_email
            row["account_email_source"] = "operator"
            row["account_email_set_at"] = timestamp
            row["updated_at"] = timestamp
            # An operator (re)configuration invalidates any prior verify-probe
            # diagnostic (it was cross-checked against the OLD value). This
            # includes the LEGACY probe-era ``account_email_verified_at`` /
            # ``account_subject`` keys: an operator-source row must NEVER carry
            # "verified" metadata, or a freshly configured email inherits a
            # stale verification it does not have. All "verified" metadata is
            # reserved for the optional-probe path only.
            for stale in (
                "account_email_verified_at",
                "account_subject",
                "account_email_probe_status",
                "account_email_probe_reason",
                "account_email_probe_observed",
                "account_email_last_probe_at",
            ):
                row.pop(stale, None)
            save_registry(registry_path, registry)
    except Exception as exc:
        return fail(str(exc), json_mode)
    payload = {
        "status": "set",
        "id": args.id,
        "account_email": account_email,
        "account_email_source": "operator",
        "registry": str(registry_path),
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"set: {args.id} account_email={account_email} (source=operator)")
    return 0


def _cmd_rotate_preflight(
    args: argparse.Namespace, registry_path: Path, json_mode: bool
) -> int:
    """#2171 selected-candidate LIVE preflight rotation (opt-in ``--preflight``).

    The default cmd_rotate selects a rotation candidate from STALE registry
    health flags (``rotation_candidate_availability``, fail-open). On the #19460
    M4 fleet-down incident that can pick a token that is itself stale/limited —
    the daemon then syncs a dead credential fleet-wide. With ``--preflight`` the
    selected candidate is LIVE-probed (``probe_claude_token`` — the exact probe
    ``cmd_check`` uses) BEFORE the active pointer is committed: authorize ONLY on
    ``available``; ``quota_limited`` / ``auth_failed`` / ``timeout`` / ``failed``
    / a 403 / parse-``unknown`` ALL EXCLUDE the candidate (a 403 is an auth
    error, never healthy evidence).

    Mirrors the ``cmd_check`` lock dance PER candidate — locked snapshot →
    UNLOCKED probe (NEVER under ``registry_lock``) → locked revalidate + commit
    — and is bounded to ONE ring pass. Failed-candidate probe evidence is
    persisted (bounded; an auth failure is recorded as a freshness-windowed
    ``last_check_status``, NEVER a permanent disable) before the next candidate.
    With ``--preflight`` OFF the legacy stale-flag cascade runs unchanged
    (cmd_rotate), so this path is fully additive and backward-compatible.
    """
    retry_seconds = 1800
    preflight_timeout = int(getattr(args, "preflight_timeout", 12) or 12)
    # #2171 PR-B2: optional GLOBAL probe budget (total live-probe seconds across
    # the whole ring pass). 0 / unset = unbounded — the legacy PR-B1 behavior,
    # byte-identical. When > 0, each candidate's live probe is capped to
    # ``min(preflight_timeout, remaining_budget)`` and a spent budget FAILS
    # CLOSED for the still-unprobed candidates (the per-candidate gate below):
    # the daemon's reactive rotate can never run the whole ring unbounded, and a
    # candidate the budget never reached is excluded, never committed from stale
    # registry availability alone.
    preflight_budget = int(getattr(args, "preflight_budget", 0) or 0)
    budget_enabled = preflight_budget > 0
    budget_remaining = float(preflight_budget)
    adverse_max_age = _rotation_adverse_check_max_age_seconds()
    # #2171 PR-B3: build the token-free measured-usage prefilter index BEFORE any
    # registry_lock (all cache IO happens here, never under the lock). Empty when
    # no --measured-usage-cache is supplied ⇒ the eligibility gate is a no-op.
    measured_index = _measured_usage_index_from_args(args, now_utc())

    old_id = ""
    new_id = ""
    committed_row: dict[str, Any] | None = None
    skipped_payload: dict[str, Any] | None = None
    soonest_reset: datetime | None = None
    preflight_trace: list[dict[str, Any]] = []
    ring: list[str] = []

    def _note_reset(stamp: datetime | None) -> None:
        nonlocal soonest_reset
        if stamp is not None and (soonest_reset is None or stamp < soonest_reset):
            soonest_reset = stamp

    try:
        # Phase 1 (locked): gate, snapshot the active token, durably stamp the
        # rotating-away token's known 429 window (#1789), and build the ring.
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
                    if args.limited_until and old_id:
                        old_row = find_token(registry, old_id)
                        if old_row is not None and iso_to_utc(args.limited_until) is not None:
                            old_row["limited_until"] = args.limited_until
                            save_registry(registry_path, registry)
                    if old_id in ids:
                        start = ids.index(old_id) + 1
                        ring = [ids[(start + i) % len(ids)] for i in range(len(ids) - 1)]
                    else:
                        ring = list(ids)

        # Phase 2 (bounded ONE ring pass): per-candidate lock dance. ``ring`` is
        # populated only on the >=2-enabled branch, so gating on it (not on a
        # non-empty old_id) keeps parity with the OFF path when the active
        # pointer is empty (the ring already excludes the active token).
        if skipped_payload is None and ring:
            for candidate in ring:
                # Step A (locked): stale-flag gate + snapshot token/fp/kind.
                now = now_utc()
                with registry_lock(registry_path):
                    registry = load_registry(registry_path)
                    candidate_row = find_token(registry, candidate)
                    if candidate_row is None:
                        preflight_trace.append(
                            {"id": candidate, "outcome": "skipped", "reason": "row_absent"}
                        )
                        continue
                    available, reset_at, skip_reason = rotation_candidate_availability(
                        candidate_row,
                        now,
                        adverse_check_max_age_seconds=adverse_max_age,
                        measured_usage_index=measured_index,
                    )
                    if not available:
                        _note_reset(reset_at)
                        preflight_trace.append(
                            {
                                "id": candidate,
                                "outcome": "skipped",
                                # A measured-usage prefilter skip carries its own
                                # stable reason; every registry-stamp block keeps
                                # the legacy ``stale_flag_unavailable`` string.
                                "reason": (
                                    "measured_near_limit"
                                    if skip_reason == "measured_near_limit"
                                    else "stale_flag_unavailable"
                                ),
                            }
                        )
                        continue
                    candidate_token = str(candidate_row.get("token") or "")
                    try:
                        validate_token(candidate_token)
                    except ValueError:
                        preflight_trace.append(
                            {"id": candidate, "outcome": "excluded", "reason": "invalid_token"}
                        )
                        continue
                    candidate_fp = token_fingerprint(candidate_token)
                    candidate_kind = classify_token_kind(candidate_token)

                # Credential contract: ``probe_claude_token`` is the NATIVE OAuth
                # (.credentials.json) probe. Probing an api-key / unknown token
                # through it would be a silent wrong-protocol probe whose result
                # is meaningless, so FAIL CLOSED for any non-OAT candidate with an
                # explicit reason rather than committing on misleading evidence.
                if candidate_kind != TOKEN_KIND_OAUTH_OAT:
                    preflight_trace.append(
                        {
                            "id": candidate,
                            "outcome": "excluded",
                            "reason": f"preflight_unsupported_kind:{candidate_kind}",
                            "fingerprint": candidate_fp,
                        }
                    )
                    continue

                # #2171 PR-B2 global-budget gate (fail-CLOSED). Cap THIS
                # candidate's live probe to whatever of the ``--preflight-budget``
                # remains (the FRACTIONAL remainder — ``subprocess`` accepts a
                # float timeout — so a sub-second budget tail is honored, never
                # floored to 0 and starved). Once the budget is spent the
                # still-unprobed candidates are excluded with the stable trace
                # reason ``preflight_budget_exhausted`` and NEVER committed from
                # stale registry availability — the only commit path stays a
                # parseable live ``available`` probe. A fully budget-exhausted
                # pass falls through to the ``all_tokens_limited`` envelope below.
                probe_timeout: float = preflight_timeout
                if budget_enabled:
                    probe_timeout = min(float(preflight_timeout), budget_remaining)
                    if probe_timeout <= 0:
                        preflight_trace.append(
                            {
                                "id": candidate,
                                "outcome": "skipped",
                                "reason": "preflight_budget_exhausted",
                                "fingerprint": candidate_fp,
                            }
                        )
                        continue

                # Step B (UNLOCKED): live probe. NEVER under registry_lock —
                # holding the lock across the network op would block the daemon's
                # rotate loop, operator activate, and the recovery sweep.
                probe_started = time.monotonic()
                probe = probe_claude_token(candidate_token, probe_timeout)
                if budget_enabled:
                    budget_remaining -= time.monotonic() - probe_started
                status = str(probe.get("status") or "failed")
                # #2171 PR-B1 gate: parse-unknown fails CLOSED. classify_probe's
                # legacy fallback returns ``available`` for non-JSON stdout with
                # rc0; that is NOT well-formed healthy evidence for committing a
                # rotation candidate. Only a parseable JSON success may authorize
                # — anything else is excluded (selection guard, not a permanent
                # account verdict). Override the local + the probe dict so the
                # downstream commit gate, evidence write, and trace all see it.
                if status == "available" and not bool(probe.get("json_ok")):
                    status = "failed"
                    probe["status"] = "failed"
                probe_reset = str(probe.get("reset_at") or "")
                probe_api = str(probe.get("api_error_status") or "")

                # Step C (locked): revalidate against a FRESH view + commit on
                # ``available``; otherwise persist bounded failure evidence and
                # advance to the next candidate.
                now2 = now_utc()
                with registry_lock(registry_path):
                    registry = load_registry(registry_path)
                    live_row = find_token(registry, candidate)
                    active_now = str(registry.get("active_token_id") or "")
                    live_fp = (
                        token_fingerprint(str(live_row.get("token") or ""))
                        if live_row is not None and live_row.get("token")
                        else ""
                    )
                    if status == "available":
                        # Discard the probe DETERMINISTICALLY if anything moved
                        # under us during the unlocked window — a concurrent
                        # rotation (active changed), the candidate row vanished,
                        # its token value was replaced (fingerprint mismatch), it
                        # was disabled, or a fresh adverse signal landed. Never
                        # commit a stale probe onto a moved/replaced row.
                        revalidate_ok = (
                            active_now == old_id
                            and live_row is not None
                            and live_fp == candidate_fp
                            and bool(live_row.get("enabled", True))
                            and rotation_candidate_availability(
                                live_row,
                                now2,
                                adverse_check_max_age_seconds=adverse_max_age,
                                measured_usage_index=measured_index,
                            )[0]
                        )
                        if revalidate_ok:
                            live_row.pop("limited_until", None)
                            timestamp = now_iso()
                            registry["active_token_id"] = candidate
                            live_row["last_activated_at"] = timestamp
                            registry["last_rotation"] = {
                                "rotated_at": timestamp,
                                "from": old_id,
                                "to": candidate,
                                "reason": args.reason or "",
                            }
                            save_registry(registry_path, registry)
                            new_id = candidate
                            committed_row = live_row
                            preflight_trace.append(
                                {"id": candidate, "outcome": "committed", "fingerprint": candidate_fp}
                            )
                            break
                        preflight_trace.append(
                            {
                                "id": candidate,
                                "outcome": "discarded",
                                "reason": "revalidation_failed",
                                "fingerprint": candidate_fp,
                            }
                        )
                        if active_now != old_id:
                            # Someone else rotated the pool; this pass is moot.
                            break
                        continue

                    # Adverse / inconclusive probe → EXCLUDE this candidate.
                    # Persist bounded evidence ONLY onto the SAME token we probed
                    # (fingerprint guard mirrors cmd_check): quota / auth →
                    # last_check_status within the freshness window so a later
                    # pass skips it; never enabled=False (no permanent disable).
                    if live_row is not None and live_fp == candidate_fp:
                        update_row_from_probe(
                            live_row,
                            probe,
                            enable_on_ok=False,
                            disable_on_quota=False,
                            retry_seconds=retry_seconds,
                        )
                        if status == "quota_limited" and probe_reset and iso_to_utc(probe_reset) is not None:
                            live_row["limited_until"] = probe_reset
                        save_registry(registry_path, registry)
                    if status == "quota_limited" and probe_reset:
                        _note_reset(iso_to_utc(probe_reset))
                    preflight_trace.append(
                        {
                            "id": candidate,
                            "outcome": "excluded",
                            "reason": f"probe_{status}",
                            "api_error_status": probe_api,
                            "fingerprint": candidate_fp,
                        }
                    )
    except Exception as exc:
        return fail(str(exc), json_mode)

    if skipped_payload is None and not new_id:
        # No candidate cleared the live probe (every alternate is limited,
        # adverse, un-probeable, or raced). Route to the existing
        # ``all_tokens_limited`` refusal so the daemon's #1789 D2 pool-exhausted
        # latch behaves exactly as before.
        skipped_payload = {
            "status": "skipped",
            "reason": "all_tokens_limited",
            "active_token_id": old_id,
            "soonest_reset": (
                soonest_reset.isoformat(timespec="seconds")
                if soonest_reset is not None
                else ""
            ),
        }

    if skipped_payload is not None:
        if preflight_trace:
            skipped_payload["preflight"] = preflight_trace
        if json_mode:
            json_dump(skipped_payload)
        else:
            print(f"skipped: {skipped_payload['reason']}")
        return 0

    payload = {
        "status": "rotated",
        "old_active_token_id": old_id,
        "active_token_id": new_id,
        "fingerprint": token_fingerprint(str((committed_row or {}).get("token") or "")),
        "reason": args.reason or "",
        "preflight": preflight_trace,
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"rotated: {old_id or '-'} -> {new_id} ({payload['fingerprint']})")
    return 0


def cmd_rotate(args: argparse.Namespace) -> int:
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    # #2171: opt-in selected-candidate live preflight. Default OFF preserves the
    # legacy stale-flag cascade below verbatim (backward-compatible).
    if bool(getattr(args, "preflight", False)):
        return _cmd_rotate_preflight(args, registry_path, json_mode)
    # #2171 PR-B3: build the token-free measured-usage prefilter index BEFORE the
    # registry_lock (all cache IO out of the lock). Empty without
    # --measured-usage-cache ⇒ the eligibility gate stays byte-identical.
    measured_index = _measured_usage_index_from_args(args, now_utc())
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
                    # #1789: persist the rotating-away token's known limit
                    # window so future selections can avoid still-limited
                    # tokens. The caller (daemon usage monitor) passes the
                    # 429-derived reset_at it already holds.
                    registry_dirty = False
                    if args.limited_until and old_id:
                        old_row = find_token(registry, old_id)
                        if old_row is not None and iso_to_utc(args.limited_until) is not None:
                            old_row["limited_until"] = args.limited_until
                            registry_dirty = True
                    # Ring order after the active token (legacy round-robin),
                    # but skip candidates still inside a known limit window —
                    # rotating into one buys nothing and thrashes the pool
                    # (#1789: median same-token return was 1.2h vs a 5h
                    # window). An expired or absent stamp keeps the token
                    # eligible.
                    if old_id in ids:
                        start = ids.index(old_id) + 1
                        ring = [ids[(start + i) % len(ids)] for i in range(len(ids) - 1)]
                    else:
                        ring = list(ids)
                    now = now_utc()
                    new_id = ""
                    soonest_reset: datetime | None = None
                    # #18849 Part 2 (cascade): advance past EVERY unavailable
                    # candidate — inside a known limit window (#1789
                    # ``limited_until`` / quota ``disabled_until``) OR carrying a
                    # recent hard limit/auth ``last_check_status`` — to the next
                    # AVAILABLE token, refusing (``all_tokens_limited``) only when
                    # the whole ring is exhausted. The ring is traversed at most
                    # once per call (bounded), and availability comes from light
                    # registry signals — never a per-candidate usage probe
                    # (rate-limit + lock-hold safe). Fail-safe: no/stale signal =>
                    # available, so a fresh / unchecked pool still rotates.
                    adverse_max_age = _rotation_adverse_check_max_age_seconds()
                    for candidate in ring:
                        candidate_row = find_token(registry, candidate) or {}
                        available, reset_at, _skip_reason = rotation_candidate_availability(
                            candidate_row,
                            now,
                            adverse_check_max_age_seconds=adverse_max_age,
                            measured_usage_index=measured_index,
                        )
                        if not available:
                            if reset_at is not None and (
                                soonest_reset is None or reset_at < soonest_reset
                            ):
                                soonest_reset = reset_at
                            continue
                        new_id = candidate
                        break
                    if not new_id:
                        # Every alternate is still rate-limited: refusing is
                        # the truthful outcome. The caller surfaces ONE
                        # actionable state instead of a saturated-pool
                        # musical-chairs loop.
                        skipped_payload = {
                            "status": "skipped",
                            "reason": "all_tokens_limited",
                            "active_token_id": old_id,
                            "soonest_reset": (
                                soonest_reset.isoformat(timespec="seconds")
                                if soonest_reset is not None
                                else ""
                            ),
                        }
                        if registry_dirty:
                            save_registry(registry_path, registry)
                    else:
                        row = find_token(registry, new_id)
                        if row is None:
                            raise ValueError(f"rotation selected missing token id: {new_id}")
                        # The selected token's window (if any) has expired —
                        # drop the stale stamp so list/status output stays
                        # truthful.
                        row.pop("limited_until", None)
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
                # #17927: also stamp the #1789 limit-window field so the
                # clock-authoritative recovery sweep (and rotate-selection
                # skip) read the real reset, not just the disable gate.
                row["limited_until"] = reset_at
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
            try:
                probe = probe_claude_token(token, timeout_seconds)
            except Exception as exc:  # noqa: BLE001
                # #17927: clock-authoritative recovery must not hinge on the
                # probe. ``probe_claude_token`` only catches TimeoutExpired /
                # FileNotFoundError; a harder failure (e.g. an OSError while
                # setting up the temp config dir) would otherwise abort the
                # whole sweep and strand every due token — including ones whose
                # reset window has already elapsed. Degrade to a ``failed``
                # probe so the locked-persist phase still re-enables a
                # clock-elapsed row (and the legacy probe path simply retries).
                probe = {
                    "status": "failed",
                    "returncode": 1,
                    "api_error_status": "",
                    "reset_at": "",
                    "error": f"probe_exception: {type(exc).__name__}",
                }
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
                    recover_apply_clock_or_probe(
                        row,
                        probe,
                        reference=reference,
                        retry_seconds=retry_seconds,
                    )
                    status = str(probe.get("status") or "failed")
                    reset_at = str(probe.get("reset_at") or "")
                    enabled_now = bool(row.get("enabled", True))
                    checked.append(
                        {
                            "id": token_id,
                            "status": status,
                            "api_error_status": str(probe.get("api_error_status") or ""),
                            "reset_at": reset_at,
                            "enabled": enabled_now,
                        }
                    )
                    # A due token starts disabled, so "enabled now" == it was
                    # re-enabled this pass — true whether recovery came from the
                    # clock (#17927) or the legacy probe path.
                    if enabled_now:
                        recovered.append(token_id)
                    else:
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
                    if getattr(args, "weekly_warn_threshold", None) is not None:
                        registry["weekly_warn_threshold"] = validate_threshold(
                            args.weekly_warn_threshold
                        )
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
        "weekly_warn_threshold": float(registry.get("weekly_warn_threshold") or 95.0),
        "active_token_id": registry.get("active_token_id") or "",
        "enabled_token_count": len(enabled_token_ids(registry)),
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"auto_rotate_enabled: {'yes' if payload['auto_rotate_enabled'] else 'no'}")
        print(f"rotation_threshold: {payload['rotation_threshold']:.0f}%")
        print(f"weekly_warn_threshold: {payload['weekly_warn_threshold']:.0f}%")
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


def _write_text_at_dirfd(
    dir_fd: int,
    name: str,
    text: str,
    *,
    mode: int = 0o600,
    prefix: str = ".tmp.",
    owner_uid: int | None = None,
    owner_gid: int | None = None,
) -> None:
    """Atomic private write of ``name`` relative to an ALREADY-OPEN parent fd.

    #18887 r3 (codex review): the caller owns ``dir_fd``'s lifetime AND its
    containment proof (it was opened ``O_DIRECTORY|O_NOFOLLOW`` and, for the
    global-credential path, validated by fd-identity and is held under the
    credential flock). Every op here — tempfile create, fsync, chmod, chown,
    rename — is ``dir_fd``-relative, so the directory written IS the directory
    the caller checked and locked. There is NO second ``os.open(str(parent))``,
    which is exactly the residual parent-swap-after-lock TOCTOU r2 still had:
    the lock pinned one fd while the writer re-resolved the parent by string,
    so a rename of the parent between lock-acquire and write redirected the
    write to an unlocked directory. Threading the single fd closes that window.
    Does NOT open or close ``dir_fd``.
    """
    fd = -1
    # mkstemp does not accept dir_fd, so create the tempfile manually relative
    # to dir_fd with O_CREAT|O_EXCL|O_NOFOLLOW (uuid name avoids a predictable
    # path).
    tmp_name = f"{prefix}{uuid.uuid4().hex}.tmp"
    try:
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
        # All ops are relative to the pinned, validated dir_fd — delegated to
        # the shared fd-relative writer, so the directory we CHECKED is exactly
        # the directory we WRITE (no second string resolution).
        _write_text_at_dirfd(
            dir_fd,
            name,
            text,
            mode=mode,
            prefix=prefix,
            owner_uid=owner_uid,
            owner_gid=owner_gid,
        )
    finally:
        if dir_fd >= 0:
            os.close(dir_fd)


# ─────────────────────────────────────────────────────────────────────
# Operator-global credential sync (#18849 Part 1) — seamless file-based
# rotation for dynamic-vanilla Claude agents.
#
# A dynamic vanilla Claude agent (#1890: engine=claude, source=dynamic, NOT
# linux-user-isolated) runs with HOME = the operator's home and NO private
# CLAUDE_CONFIG_DIR, so it reads the operator-global
# ``~/.claude/.credentials.json``. The per-agent rotation sync never touches
# that file, so dynamic agents stay pinned to whatever (often quota-exhausted)
# token the operator was logged in under. This module writes the active token
# into that operator-global file so a running dynamic agent picks it up
# seamlessly on its next prompt boundary (the same file-reread Claude already
# does for static per-agent credentials).
#
# This is a HIGH-RISK surface: the target is the operator's PERSONAL login
# state. Every write therefore:
#   * is double-gated default-OFF (registry ``auto_rotate_enabled`` AND the
#     persisted ``BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC`` opt-in) — an existing
#     auto-rotate install never starts touching ``~/.claude`` after upgrade;
#   * PATCHes rather than overwrites: it reads the existing payload and
#     replaces ONLY ``claudeAiOauth.accessToken`` (+ ``expiresAt``), preserving
#     ``refreshToken`` and every unknown field (a fresh login carries more than
#     the synthetic minimal writer emits — clobbering it would break /login);
#   * writes via the fd-pinned/no-follow atomic writer, which stages a temp
#     under the validated parent dir and ``rename()``s into place — the final
#     file's inode is never touched until the atomic swap, so a failed write
#     leaves the existing credential byte-identical (no rollback-rewrite that
#     could itself change the inode on a containment failure);
#   * FAILS CLOSED when the effective writer is root (``geteuid()==0``) — the
#     operator file must be written by the operator UID, never root;
#   * holds a real ``~/.claude/.credentials.json.lock`` flock for the whole
#     read-patch-write so it cannot race an operator ``claude /login``.
#
# Account identity (``oauthAccount`` email) is NOT synced here — the registry
# carries no identity field (Part 1 = token-sync + identity DETECTION only;
# identity-sync is the #18849 Part 2 follow-up). The detection surface WARNS
# when the displayed identity may not match the freshly-synced credential.
GLOBAL_AUTH_SYNC_OPT_IN_ENV = "BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC"
# Test-only seam: force the root guard's "is root" branch ON regardless of the
# real euid. It can only ever make the guard STRICTER (it never relaxes the
# real ``os.geteuid()==0`` check), so it cannot be used to bypass the
# fail-closed-as-root contract — only to exercise the fail path from a
# non-root test runner.
GLOBAL_AUTH_SYNC_FORCE_ROOT_ENV = "BRIDGE_AUTH_GLOBAL_SYNC_FORCE_ROOT"
# Persisted runtime-config boolean backing the opt-in, mirroring
# ``KEYCHAIN_FREE_CONFIG_KEY``. The sanctioned writer is
# ``global-auth-sync enable|disable``; the env override stays a secondary,
# precedence-bearing path (see ``global_auth_sync_opt_in_enabled``).
GLOBAL_AUTH_SYNC_CONFIG_KEY = "claude_global_auth_sync"


def global_auth_sync_persisted_enabled() -> bool:
    """True iff the persisted ``claude_global_auth_sync`` runtime-config bool is ON."""
    return runtime_config_truthy(GLOBAL_AUTH_SYNC_CONFIG_KEY)


def global_auth_sync_env_override_enabled() -> bool:
    """True iff the ``BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC`` env override is the
    canonical enabling literal ``"1"``.

    Deliberately strict equality on the RAW value (``== "1"``): the only value
    that turns the gate ON is the exact string ``"1"``; ``"0"``/``"true"``/empty
    are NOT enabling, and a whitespace-padded form (``" 1 "``/``"1 "``/``" 1"``)
    is NOT enabling either — the comparison does NOT ``.strip()``, so a padded
    value falls through to OFF rather than silently activating a personal-
    credential writer the operator did not type exactly. To clear an enabling
    override the operator removes the key (manual edit / unset).
    """
    return os.environ.get(GLOBAL_AUTH_SYNC_OPT_IN_ENV, "") == "1"


def global_auth_sync_opt_in_enabled() -> bool:
    """True iff the global-auth-sync opt-in is EFFECTIVELY ON.

    Default OFF. This is the SECOND gate of the default-OFF double-gate (the
    first being the registry's ``auto_rotate_enabled``). It is a separate knob
    precisely so an install that already enabled auto-rotate does NOT begin
    writing the operator's personal credential file after an upgrade — the
    operator must explicitly opt in.

    Effective state is ``persisted OR env``: the persisted runtime-config bool
    (set by ``agent-bridge auth claude-token global-auth-sync enable``) OR a
    live ``BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1`` env override. The verb is the
    primary, headless-safe path; the env override is a secondary route that
    takes precedence so a value left in the environment is never silently
    ignored (and is surfaced by ``global-auth-sync status``).
    """
    return (
        global_auth_sync_persisted_enabled()
        or global_auth_sync_env_override_enabled()
    )


def write_global_auth_sync_gate(enabled: bool) -> tuple[Path | None, str]:
    """Sanctioned single-key writer for the ``claude_global_auth_sync``
    runtime-config boolean (mirrors ``write_keychain_free_gate``).

    The blessed admin path so the operator never raw-edits bridge-config.json
    (and is not blocked by the set-env ``KEY``-substring guard). Read-modify-write
    preserves every other config key; only the one boolean is set. Returns
    ``(path, "ok")`` or ``(None, reason)`` and never clobbers a malformed config."""
    path = runtime_config_path()
    if path is None:
        return None, "no_runtime_config_path (set BRIDGE_RUNTIME_ROOT or BRIDGE_HOME)"
    config: dict[str, Any] = {}
    mode = 0o600
    if path.is_file():  # noqa: raw-pathlib-controller-only - controller runtime config probe
        try:
            mode = path.stat().st_mode & 0o777  # noqa: raw-pathlib-controller-only - controller runtime config mode
            parsed = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001 - malformed config → refuse, do not clobber
            return None, f"runtime_config_unreadable: {exc}"
        if not isinstance(parsed, dict):
            return None, "runtime_config_not_object"
        config = parsed
    config[GLOBAL_AUTH_SYNC_CONFIG_KEY] = bool(enabled)
    text = json.dumps(config, ensure_ascii=True, indent=2) + "\n"
    try:
        write_private_file_atomic(path, text, mode=mode, prefix=".bridge-config.")
    except OSError as exc:
        return None, f"runtime_config_write_failed: {exc}"
    return path, "ok"


def global_auth_sync_effective_source() -> str:
    """Classify WHY ``global_auth_sync_opt_in_enabled`` is what it is.

    One of ``runtime-config`` | ``env`` | ``both`` | ``default`` — so ``status``
    can tell the operator which knob is in force (and whether a ``disable`` will
    leave a live env override behind)."""
    persisted = global_auth_sync_persisted_enabled()
    env = global_auth_sync_env_override_enabled()
    if persisted and env:
        return "both"
    if persisted:
        return "runtime-config"
    if env:
        return "env"
    return "default"


def _global_credential_writer_is_root() -> bool:
    """True when the global credential write must FAIL CLOSED on root.

    Real root (``os.geteuid()==0``) always returns True. The test seam can only
    ADD a forced-root result — it can never report non-root while actually
    root — so it cannot be abused to defeat the guard.
    """
    if os.geteuid() == 0:
        return True
    return os.environ.get(GLOBAL_AUTH_SYNC_FORCE_ROOT_ENV, "").strip() == "1"


@contextmanager
def claude_global_credentials_lock(
    credentials_path: Path,
    *,
    allowed_root: Path | None = None,
    timeout_seconds: int = REGISTRY_LOCK_DEFAULT_TIMEOUT_SECONDS,
) -> Iterator[None]:
    """Exclusive flock around the operator-global credential read-patch-write.

    The operator may run ``claude /login`` against the same
    ``~/.claude/.credentials.json`` at any moment. A real ``.credentials.json.lock``
    flock (gate 4) guards the whole load->patch->atomic-write critical section so
    a concurrent login and a daemon-driven token sync cannot interleave into a
    torn write. Mirrors ``registry_lock``: a sibling ``<path>.lock`` file,
    non-blocking poll until ``timeout_seconds``, 0600 so it stays operator-only.

    #18887 finding 1 (codex review): NO filesystem write — not even the lock
    file — happens before the parent is opened ``O_DIRECTORY|O_NOFOLLOW`` (which
    FAILS on a symlinked parent) and, when ``allowed_root`` is given, verified
    inside the root BY THE FD's OWN IDENTITY (procfs / ``F_GETPATH``, never a
    string re-resolution). The lock is then created ``dir_fd``-relative inside
    that pinned, validated directory, so a symlinked / out-of-root parent can
    never leak a ``.lock`` file outside the operator home. Mirrors
    ``write_private_file_atomic_dirfd``. The parent is NOT created here: a
    missing parent fails loud rather than racing a mkdir through a swappable path.
    """
    credentials_path = Path(credentials_path).expanduser()
    parent = credentials_path.parent
    lock_name = credentials_path.name + REGISTRY_LOCK_SUFFIX
    dir_fd = -1
    fd = -1
    acquired = False
    try:
        try:
            dir_fd = os.open(
                str(parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            )
        except OSError as exc:
            raise PermissionError(
                f"refusing to lock operator-global credentials under a "
                f"symlinked/missing parent {parent}: {exc}"
            ) from exc
        if allowed_root is not None:
            real_parent = _dir_fd_real_path(dir_fd)
            try:
                allowed = str(allowed_root.resolve(strict=True))
            except OSError as exc:
                raise PermissionError(
                    f"cannot resolve allowed root {allowed_root}: {exc}"
                ) from exc
            if real_parent != allowed and not real_parent.startswith(
                allowed + os.sep
            ):
                raise PermissionError(
                    f"operator-global credentials parent resolves outside "
                    f"allowed root: {real_parent} not under {allowed}"
                )
        # Create the lock fd-relative in the pinned, validated directory
        # (O_NOFOLLOW so a pre-placed lock-name symlink is refused too).
        fd = os.open(
            lock_name,
            os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
            0o600,
            dir_fd=dir_fd,
        )
        deadline = time.monotonic() + max(1, int(timeout_seconds))
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except BlockingIOError:
                pass
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
                    raise
            if time.monotonic() >= deadline:
                raise TimeoutError(
                    f"claude_global_credentials_lock timeout after "
                    f"{timeout_seconds}s on {parent}/{lock_name}"
                )
            time.sleep(0.1)
        # #18887 r3: yield the SAME pinned, validated parent fd the lock holds,
        # so the caller does its whole read->check->write critical section
        # dir_fd-relative against this exact directory — never a second string
        # resolution that a parent-swap-after-lock could redirect.
        yield dir_fd
    finally:
        if acquired:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        if dir_fd >= 0:
            try:
                os.close(dir_fd)
            except OSError:
                pass


def resolve_operator_claude_config_path(credentials_path: Path) -> Path:
    """Resolve the operator's ``~/.claude.json`` sibling of the credential file.

    ``oauthAccount.emailAddress`` (the DISPLAYED Claude identity) lives in
    ``<home>/.claude.json``, NOT in ``.credentials.json``. Given the global
    credentials path ``<home>/.claude/.credentials.json`` the config is
    ``<home>/.claude.json`` (parent of the ``.claude`` dir).
    """
    return Path(credentials_path).expanduser().parent.parent / ".claude.json"


def read_oauth_account_email(config_path: Path) -> str:
    """Best-effort read of ``oauthAccount.emailAddress`` from ``~/.claude.json``.

    DETECTION ONLY (#18849 Part 1, gate 7). Returns the displayed account email
    or ``""`` when the file is absent / unreadable / lacks the field. Never
    raises and never writes — identity is surfaced, never mutated, in Part 1.
    """
    config_path = Path(config_path).expanduser()
    try:
        if config_path.is_symlink() or not config_path.is_file():  # noqa: raw-pathlib-controller-only - controller-side read of the operator-global ~/.claude.json (never an isolated-agent path); detection-only, never mutates
            return ""
        parsed = json.loads(config_path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 - detection must never raise
        return ""
    if not isinstance(parsed, dict):
        return ""
    account = parsed.get("oauthAccount")
    if not isinstance(account, dict):
        return ""
    email = account.get("emailAddress")
    return email.strip() if isinstance(email, str) else ""


def patch_global_claude_credentials(
    path: Path,
    access_token: str,
    *,
    expires_at_ms: int | None = None,
    owner_uid: int | None = None,
    allowed_root: Path | None = None,
) -> dict[str, Any]:
    """PATCH the operator-global credential file with a new access token.

    Read the existing ``~/.claude/.credentials.json`` payload and replace ONLY
    ``claudeAiOauth.accessToken`` (and ``expiresAt`` when supplied), preserving
    ``refreshToken`` and every other field. Atomic, fd-pinned/no-follow write at
    0600 via ``write_private_file_atomic_dirfd``: the new payload is staged under
    the dirfd-validated parent and ``rename()``d into place, so the existing
    credential file's inode is never mutated until the atomic swap. A failed
    write therefore leaves the prior credential byte-identical with no
    rollback-rewrite — the unhardened restore path that could itself re-touch
    the inode on a containment failure has been removed. Fails closed as root,
    holds the credential flock for the whole read-patch-write.

    Returns a result dict with ``changed`` (False when the file already carried
    this exact access token — idempotent no-op), ``created`` (the file was
    absent and a fresh minimal payload was written), and ``fingerprint``.
    Raises on root, symlinked target/parent, unparseable existing payload, or
    write failure (existing file left intact by the atomic writer).
    """
    if _global_credential_writer_is_root():
        raise PermissionError(
            "refusing to write the operator-global credential file as root "
            "(geteuid==0) — global auth sync must run as the operator UID, not "
            "root; --owner-uid only chowns the tempfile, it does not change the "
            "effective writer"
        )
    path = Path(path).expanduser()
    # #18887 finding 1 + r3: the lock opens the parent O_DIRECTORY|O_NOFOLLOW +
    # allowed-root-validates (by fd identity) BEFORE creating the lock fd-relative
    # — a symlinked parent is refused at lock time and no .lock leaks out of the
    # operator home — and it YIELDS that pinned, validated fd so the entire
    # read->check->write critical section runs dir_fd-relative against the exact
    # directory the lock holds. A parent-swap after the lock is acquired cannot
    # redirect the read or the write (the r2 residual TOCTOU).
    name = path.name
    with claude_global_credentials_lock(path, allowed_root=allowed_root) as dir_fd:
        # Read + existence-check FD-RELATIVE against the locked directory.
        # O_NOFOLLOW refuses a symlinked final component (the old
        # path.is_symlink() check); the parent symlink/containment case is
        # already closed by the lock's O_NOFOLLOW parent open + fd-identity
        # allowed-root validation. No string re-resolution of path/path.parent.
        existed = False
        preimage: bytes | None = None
        try:
            cred_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
        except OSError as exc:  # ELOOP on a symlinked final component → refuse
            raise PermissionError(
                f"refusing to read operator-global credentials via a symlinked "
                f"final component: {path}: {exc}"
            ) from exc
        else:
            existed = True
            with os.fdopen(cred_fd, "rb") as fh:
                preimage = fh.read()
        if existed:
            try:
                payload = json.loads(preimage.decode("utf-8"))
            except Exception as exc:  # noqa: BLE001 - corrupt → refuse, never clobber
                raise ValueError(
                    f"operator-global credentials are not valid JSON; refusing to "
                    f"overwrite a possibly mid-login file: {path}: {exc}"
                ) from exc
            if not isinstance(payload, dict):
                raise ValueError(
                    f"operator-global credentials must contain a JSON object: {path}"
                )
        else:
            payload = {}

        existing_oauth = payload.get("claudeAiOauth")
        # An EXISTING credential file is expected to carry a ``claudeAiOauth``
        # object (the only shape Claude writes). If it parses as JSON but lacks
        # one, refuse rather than reshape an unrecognized file (a corrupt or
        # attacker-planted file) — PATCH only a recognized credential. The
        # absent-file case below is the sole create path.
        if existed and not isinstance(existing_oauth, dict):
            raise ValueError(
                "existing operator-global credentials lack a 'claudeAiOauth' "
                f"object; refusing to reshape an unrecognized credential file: {path}"
            )
        old_token = (
            existing_oauth.get("accessToken")
            if isinstance(existing_oauth, dict)
            else None
        )
        fingerprint = token_fingerprint(access_token)
        # Idempotent: the file already carries this exact token → no rewrite.
        if existed and old_token == access_token:
            return {
                "changed": False,
                "created": False,
                "fingerprint": fingerprint,
                "path": str(path),
            }

        oauth = dict(existing_oauth) if isinstance(existing_oauth, dict) else {}
        oauth["accessToken"] = access_token
        if expires_at_ms is not None:
            oauth["expiresAt"] = expires_at_ms
        # Only seed scopes when creating a fresh payload; never override an
        # existing login's scopes.
        if not existed and "scopes" not in oauth:
            oauth["scopes"] = CLAUDE_OAUTH_SCOPES
        payload["claudeAiOauth"] = oauth

        text = json.dumps(payload, ensure_ascii=True, indent=2) + "\n"
        # #18887 finding 2 + r3: write FD-RELATIVE via the lock's pinned dir_fd —
        # NO second os.open(str(parent)), which is what let a parent-swap after
        # the lock redirect the write to an unlocked directory in r2. Containment
        # was already proven once, at lock time, against this same fd. The atomic
        # dir_fd writer stages a tempfile and renames within the locked directory,
        # chowning BEFORE the rename, so ANY pre-rename failure leaves the original
        # final path byte- AND inode-identical: there is no half-write and no
        # rollback-rewrite (the r2 rollback used the OLDER string-path writer,
        # which bypassed the hardening AND changed the inode on a rejected write).
        # Let the error propagate; the operator's login file is untouched on failure.
        _write_text_at_dirfd(
            dir_fd,
            name,
            text,
            mode=0o600,
            prefix=".credentials.",
            owner_uid=owner_uid,
        )
        return {
            "changed": True,
            "created": not existed,
            "fingerprint": fingerprint,
            "path": str(path),
        }


# ─────────────────────────────────────────────────────────────────────
# Identity sync (#18849 Part 1b-v2, closes #2145) — sync the DISPLAYED Claude
# account to the active token's OPERATOR-CONFIGURED account on a gated global
# token sync.
#
# Part 1a syncs the active TOKEN into ~/.claude/.credentials.json and only
# DETECTS the identity shadow (oauthAccount.emailAddress in ~/.claude.json can
# stay stale → /status / statusLine misreport the account). Part 1b closes that
# by, after a gated credential PATCH, PATCHing ~/.claude.json's displayed email
# to the account the active token belongs to.
#
# SOURCE (Part 1b-v2): the email is the OPERATOR-PROVIDED ``account_email`` from
# the active token's registry row — captured at ``claude-token add`` / ``receive``
# / ``set`` and BINDING only when ``account_email_source == "operator"``. The
# original Part 1b probed a ``user:profile`` endpoint that 403s on the pool's
# inference-purposed tokens (#2145), so identity-sync shipped permanently inert.
# v2 drops that dependency: the operator already provides the account email when
# they hand over a setup token, so we use it directly. Empty / absent /
# non-operator ``account_email`` ⇒ NO WRITE (never guessed, never id-derived).
# An OPTIONAL, default-OFF verify-only probe (``_run_identity_verify_probe``)
# survives purely as a diagnostic — it never sources the write and never blocks.
#
# RACE-FIX preserved WITHOUT a probe: the write re-reads the active row under the
# registry lock, verifies the active token fingerprint is unchanged AND the
# source is still operator, and holds that SAME lock through the fd-pinned
# ~/.claude.json PATCH — closing the Part 1b r2 token-replace window.
#
# The ~/.claude.json writer reuses the Part 1a r3 single-pinned-dir_fd discipline
# verbatim (``claude_global_credentials_lock`` yields the validated parent fd;
# the read + the write run dir_fd-relative on that SAME fd via
# ``_write_text_at_dirfd`` — no second ``os.open(str(parent))``), so the
# parent-swap-after-lock TOCTOU stays closed. It PATCHes only
# ``oauthAccount.emailAddress`` (the operator path supplies no subject) and
# preserves ``projects`` / ``mcpServers`` / every unknown key — ~/.claude.json is
# large and load-bearing. Same double-gate default-OFF + the SAME
# ``BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC`` opt-in; fails closed as root.
CLAUDE_PROFILE_ENDPOINT = "https://api.anthropic.com/api/oauth/profile"
CLAUDE_OAUTH_BETA = "oauth-2025-04-20"
CLAUDE_PROFILE_PROBE_UA_VERSION = "2.1.0"
CLAUDE_PROFILE_PROBE_TIMEOUT_SECONDS = 10
# Bound re-probing when the gate is on but no identity has ever verified (e.g. a
# down network): re-probe at most once per this window. A real credential
# rotation always forces a fresh probe regardless.
CLAUDE_IDENTITY_PROBE_COOLDOWN_SECONDS = 300
# Test-only injection seam (mirrors bridge-usage-probe's HTTP seam): a JSON
# fixture file that simulates the profile HTTP response so smokes never touch
# the network. Shape: {"transport_error": true} → a simulated transport failure;
# or {"http_status": <int>, "body": <obj|str>} → a fake response the classifier
# then maps. Honored ONLY when the env var is set; production always probes live.
CLAUDE_PROFILE_PROBE_FIXTURE_ENV = "BRIDGE_CLAUDE_PROFILE_PROBE_FIXTURE"
# Test-only seam: force the keychain-exists guard's result without a real
# `security(1)` call. Accepts a truthy/falsey string; absent → real detection.
KEYCHAIN_PRESENT_FORCE_ENV = "BRIDGE_AUTH_FORCE_KEYCHAIN_PRESENT"


def _identity_probe_timeout_seconds() -> int:
    raw = os.environ.get("BRIDGE_CLAUDE_IDENTITY_PROBE_TIMEOUT_SECONDS", "").strip()
    try:
        value = int(raw)
    except ValueError:
        return CLAUDE_PROFILE_PROBE_TIMEOUT_SECONDS
    return value if value > 0 else CLAUDE_PROFILE_PROBE_TIMEOUT_SECONDS


def _identity_probe_cooldown_seconds() -> int:
    raw = os.environ.get("BRIDGE_CLAUDE_IDENTITY_PROBE_COOLDOWN_SECONDS", "").strip()
    try:
        value = int(raw)
    except ValueError:
        return CLAUDE_IDENTITY_PROBE_COOLDOWN_SECONDS
    return value if value >= 0 else CLAUDE_IDENTITY_PROBE_COOLDOWN_SECONDS


def _load_profile_probe_fixture(path: str) -> tuple[int, str]:
    """Resolve a test fixture into a ``(http_status, body_text)`` pair.

    Raises ``urllib.error.URLError`` for a ``transport_error`` fixture so the
    probe's transport-degrade path is exercised exactly as a real socket error
    would. Never touches the network.
    """
    with open(path, encoding="utf-8") as fh:  # noqa: raw-pathlib-controller-only - controller-side test fixture read (never an isolated-agent path)
        spec = json.loads(fh.read())
    if not isinstance(spec, dict):
        raise ValueError("profile probe fixture must be a JSON object")
    if spec.get("transport_error"):
        raise urllib.error.URLError("profile probe fixture transport error")
    status = int(spec.get("http_status", 200))
    body = spec.get("body", "")
    body_text = body if isinstance(body, str) else json.dumps(body)
    return status, body_text


def _http_get_claude_profile(token: str, *, timeout: float) -> tuple[int, str]:
    """Perform the `user:profile` GET and return ``(http_status, body_text)``.

    INJECTION SEAM: when ``BRIDGE_CLAUDE_PROFILE_PROBE_FIXTURE`` is set the call
    is served from a local fixture so no live request is ever made in CI. The
    token lives ONLY in the in-process Authorization header — there is no
    subprocess, so there is no env-leak surface, and it is never logged.
    """
    fixture = os.environ.get(CLAUDE_PROFILE_PROBE_FIXTURE_ENV, "").strip()
    if fixture:
        return _load_profile_probe_fixture(fixture)
    headers = {
        "Authorization": f"Bearer {token}",
        "anthropic-beta": CLAUDE_OAUTH_BETA,
        "User-Agent": f"claude-code/{CLAUDE_PROFILE_PROBE_UA_VERSION}",
        "Accept": "application/json",
    }
    req = urllib.request.Request(CLAUDE_PROFILE_ENDPOINT, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            charset = resp.headers.get_content_charset() or "utf-8"
            return int(getattr(resp, "status", 200) or 200), resp.read().decode(
                charset, errors="replace"
            )
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001 - error body is best-effort context only
            body = ""
        return int(exc.code), body


def _extract_profile_identity(payload: Any) -> tuple[str, str]:
    """Pull ``(email, subject)`` from a `user:profile` response, defensively.

    Accepts the common Anthropic shapes (``account.email_address`` /
    ``account.uuid``) plus camelCase / top-level variants so a minor response
    rename does not silently degrade to "no email". Returns ``("", "")`` when no
    email can be found — the caller treats that as ``no_email`` (no write).
    """
    if not isinstance(payload, dict):
        return "", ""
    account = payload.get("account")
    account = account if isinstance(account, dict) else payload
    email = ""
    for key in ("email_address", "emailAddress", "email"):
        value = account.get(key)
        if isinstance(value, str) and value.strip():
            email = value.strip()
            break
    subject = ""
    for key in ("uuid", "account_uuid", "accountUuid", "id"):
        value = account.get(key)
        if isinstance(value, str) and value.strip():
            subject = value.strip()
            break
    return email, subject


def classify_profile_response(http_status: int, body_text: str) -> dict[str, Any]:
    """Classify a profile probe response into a fail-safe identity outcome.

    Status values:
      - ``verified``     — HTTP 200 carrying a non-empty account email.
      - ``no_email``     — HTTP 200 but the profile carries no email (unknown).
      - ``no_scope``     — HTTP 403: the token authenticated but lacks
                           ``user:profile`` access (unknown).
      - ``probe_failed`` — any other status / unparseable body (keep last
                           verified, mark stale; NEVER write a guess).
    """
    if http_status == 403:
        return {"status": "no_scope", "email": "", "subject": "",
                "detail": "http 403 — token lacks user:profile scope"}
    if http_status != 200:
        return {"status": "probe_failed", "email": "", "subject": "",
                "detail": f"http {http_status}"}
    try:
        payload = json.loads(body_text)
    except Exception:  # noqa: BLE001 - unparseable body → degrade, never guess
        return {"status": "probe_failed", "email": "", "subject": "",
                "detail": "unparseable profile body"}
    email, subject = _extract_profile_identity(payload)
    if not email:
        return {"status": "no_email", "email": "", "subject": subject,
                "detail": "profile carried no account email"}
    return {"status": "verified", "email": email, "subject": subject,
            "detail": "verified via user:profile"}


def probe_claude_account_identity(token: str, *, timeout_seconds: int) -> dict[str, Any]:
    """Verified-source account identity probe (#18849 Part 1b).

    Returns ``{"status", "email", "subject", "detail"}``. The ONLY path that
    yields ``status == "verified"`` with a non-empty email is a 200 response
    carrying an account email; every transport error / timeout / non-200 /
    no-email outcome degrades to a no-write result, so the displayed identity is
    never set to a guessed value.
    """
    try:
        http_status, body_text = _http_get_claude_profile(token, timeout=timeout_seconds)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        return {"status": "probe_failed", "email": "", "subject": "",
                "detail": f"transport: {type(exc).__name__}"}
    return classify_profile_response(http_status, body_text)


def operator_keychain_credentials_present() -> bool:
    """Detect whether the operator's Claude auth lives in the macOS keychain.

    When the operator logged in with the keychain credential store (not the
    ``.credentials.json`` file), the keychain — not us — owns the displayed
    identity, so Part 1b must NOT silently diverge ~/.claude.json from it. This
    is the detection half of the keychain-exists guard (the caller warns + skips
    the identity write when this is True).

    Best-effort + fail-OPEN-to-absent: a `security(1)` error / non-Darwin host /
    missing binary all report ``False`` (the gated, fd-pinned write then
    proceeds — a missed detection is not a divergence, since the write only ever
    lands a freshly VERIFIED email). The test seam forces the result without a
    real keychain call.
    """
    forced = os.environ.get(KEYCHAIN_PRESENT_FORCE_ENV, "").strip().lower()
    if forced in ("1", "true", "yes", "on"):
        return True
    if forced in ("0", "false", "no", "off"):
        return False
    if host_platform() != "Darwin":
        return False
    # Full-enumerate base + hashed ``Claude Code-credentials*`` services. The old
    # base-only ``find-generic-password -s 'Claude Code-credentials'`` MISSED the
    # hashed-service variant (``Claude Code-credentials-<hash>``, Claude Code
    # v2.1.195) — the exact M4 class this guard must catch (#2171 PR-D review F2).
    # Fail-OPEN-to-absent is preserved: an enumeration error yields no services →
    # False (a missed detection is not a divergence; the gated write only ever
    # lands a freshly VERIFIED email — see docstring).
    services, _enum_error = keychain_claude_service_names(_security_binary())
    return len(services) > 0


# ─────────────────────────────────────────────────────────────────────
# #2171 (incident #19460 M4 fleet-down) PR-D — Claude Code keychain shadow
# self-heal. macOS-only. Claude Code (v2.1.195, confirmed on sean-m4) stores its
# OAuth credential in the login keychain under a HASHED service name
# (``Claude Code-credentials-<hash>``) alongside / instead of the base
# ``Claude Code-credentials``. A keychain entry whose access token DIVERGES from
# the agent's active pool token SHADOWS the per-agent ``.credentials.json`` — the
# session authenticates with the stale keychain token (e.g. a personal
# ``Claude Max`` subscription that hit a weekly limit → 429) even though
# ``.credentials.json`` holds the correct rotating pool token. The base-only
# ``find-generic-password -s 'Claude Code-credentials'`` MISSES the hashed
# variant, so reconcile must FULL-ENUMERATE via ``dump-keychain``.
#
# Default = FAIL-CLOSED diagnostic (report the stale shadow, delete NOTHING,
# non-zero exit so a health gate notices). Deletion happens only on the
# operator-approved ``--apply`` path. Tokens are compared / logged by
# FINGERPRINT (sha256 prefix) only — the raw secret never reaches stdout, the
# diff, or the audit log.
CLAUDE_KEYCHAIN_BASE_SERVICE = "Claude Code-credentials"


def _security_binary() -> str:
    """The ``security(1)`` binary to shell out to.

    Honors the ``BRIDGE_SECURITY_BIN`` test seam (an injected mock keychain
    tool) so the keychain smokes never touch the real login keychain; defaults
    to the system ``security``.
    """
    return os.environ.get("BRIDGE_SECURITY_BIN", "").strip() or "security"


def _extract_oauth_access_token(secret: str) -> str:
    """The OAuth access token inside a keychain secret blob.

    Claude Code stores ``{"claudeAiOauth": {"accessToken": "..."}}`` (also seen
    with the token at top level); return that access token. A bare-token secret
    (not JSON) is returned as-is so an older credential shape still fingerprints.
    Never logs the secret.
    """
    try:
        parsed = json.loads(secret)
    except (ValueError, TypeError):
        return secret
    if isinstance(parsed, dict):
        oauth = parsed.get("claudeAiOauth")
        if isinstance(oauth, dict) and isinstance(oauth.get("accessToken"), str):
            return oauth["accessToken"]
        if isinstance(parsed.get("accessToken"), str):
            return parsed["accessToken"]
        return ""
    return secret


def keychain_claude_service_names(security_bin: str) -> tuple[list[str], str]:
    """Full-enumerate every ``Claude Code-credentials*`` keychain service name.

    Returns ``(services, error)``. Claude Code uses a HASHED service name, so a
    base-only ``find-generic-password -s 'Claude Code-credentials'`` is
    insufficient — this parses ``dump-keychain``'s ``"svce"<blob>="..."`` lines
    and returns every service whose name is the base service OR a
    ``<base>-<suffix>`` hashed variant, de-duplicated and order-preserved.

    ``error`` is ``""`` on a successful enumeration (``services`` may still be
    empty = genuinely no entries). A ``security(1)`` exception / missing binary /
    non-zero exit returns ``([], "enumeration_failed:...")`` so the caller can
    FAIL CLOSED — an enumeration that never ran must NOT look like "no shadow"
    (#2171 PR-D review F1). The service NAME is not a secret (the operator's
    working fix prints it); the token it guards never leaves this module
    un-fingerprinted.
    """
    try:
        proc = subprocess.run(
            [security_bin, "dump-keychain"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=20,
            check=False,
            text=True,
        )
    except Exception as exc:  # noqa: BLE001 - enumeration failure is SIGNALED, not swallowed
        return [], f"enumeration_failed:{type(exc).__name__}"
    if proc.returncode != 0:
        # security(1) could not read the keychain (locked / denied / failing or
        # stub binary). This is NOT "no entries" — signal it so the caller fails
        # closed rather than reporting a vacuous clean (#2171 PR-D review F1).
        return [], f"enumeration_failed:rc{proc.returncode}"
    services: list[str] = []
    seen: set[str] = set()
    for line in (proc.stdout or "").splitlines():
        if '"svce"' not in line:
            continue
        match = re.search(r'"svce"<blob>="(.+?)"\s*$', line)
        if not match:
            continue
        value = match.group(1)
        if value != CLAUDE_KEYCHAIN_BASE_SERVICE and not value.startswith(
            CLAUDE_KEYCHAIN_BASE_SERVICE + "-"
        ):
            continue
        if value in seen:
            continue
        seen.add(value)
        services.append(value)
    return services, ""


def keychain_entry_fingerprint(security_bin: str, service: str) -> tuple[str, str]:
    """``(fingerprint, error)`` for a keychain entry's OAuth access token.

    Reads the generic-password secret with ``find-generic-password -s <svc> -w``,
    extracts the OAuth access token, and returns its ``token_fingerprint`` — never
    the raw secret. On any failure returns ``("", reason)`` so the caller reports
    the entry as unreadable without crashing the reconcile.
    """
    try:
        proc = subprocess.run(
            [security_bin, "find-generic-password", "-s", service, "-w"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=20,
            check=False,
            text=True,
        )
    except Exception as exc:  # noqa: BLE001 - read is best-effort, never fatal
        return "", f"read_failed:{type(exc).__name__}"
    if proc.returncode != 0:
        return "", "read_failed"
    secret = (proc.stdout or "").strip()
    if not secret:
        return "", "empty"
    token = _extract_oauth_access_token(secret)
    if not token:
        return "", "no_access_token"
    return token_fingerprint(token), ""


def keychain_delete_service(security_bin: str, service: str) -> tuple[bool, str]:
    """Delete a keychain generic-password entry by service name (``--apply`` only).

    Returns ``(deleted, error)``. Never raises; a ``security(1)`` failure is
    reported so the reconcile can mark the cleanup incomplete (fail-closed).
    """
    try:
        proc = subprocess.run(
            [security_bin, "delete-generic-password", "-s", service],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=20,
            check=False,
        )
    except Exception as exc:  # noqa: BLE001 - delete is best-effort, never fatal
        return False, f"delete_failed:{type(exc).__name__}"
    if proc.returncode != 0:
        return False, "delete_failed"
    return True, ""


def _probe_cooldown_elapsed(row: dict[str, Any]) -> bool:
    last = iso_to_utc(str(row.get("account_email_last_probe_at") or ""))
    if last is None:
        return True
    return (now_utc() - last).total_seconds() >= _identity_probe_cooldown_seconds()


# Human-readable labels for the granular last-probe outcome, surfaced on the
# read-only ``global-auth-status`` doctor line so an operator can see WHY the
# displayed identity never converged (e.g. a pool token that lacks
# ``user:profile`` 403s → ``no_scope`` → identity-sync is a permanent no-op).
_IDENTITY_PROBE_REASON_LABELS = {
    "verified": "verified (optional probe matched the configured email)",
    "mismatch": "mismatch (probe email != configured — WARN only, kept configured)",
    "no_scope": "verify_skipped (token lacks user:profile — not a blocker)",
    "no_email": "verify_skipped (profile carried no account email)",
    "probe_failed": "probe_failed (network/timeout/429 — diagnostic only)",
}


def _identity_probe_reason_label(reason: str) -> str:
    if not reason:
        return "not_probed"
    return _IDENTITY_PROBE_REASON_LABELS.get(reason, reason)


def operator_account_email(row: dict[str, Any] | None) -> str:
    """The OPERATOR-CONFIGURED account email, or ``""`` (#18849 Part 1b-v2).

    The ``account_email_source`` marker is BINDING: this returns ``account_email``
    ONLY when the operator provided it (``source == "operator"``). A probe-sourced
    or unmarked-legacy ``account_email`` is never returned, so a non-operator
    value can never drive the displayed-identity write (#2145). Empty/absent ⇒
    ``""`` ⇒ the caller writes nothing.
    """
    if not isinstance(row, dict):
        return ""
    if str(row.get("account_email_source") or "") != "operator":
        return ""
    return str(row.get("account_email") or "").strip()


def _identity_row_token_skip_reason(
    row: dict[str, Any] | None, probed_fingerprint: str
) -> str:
    """Token-replace recheck guarding the identity persist + the config write.

    The displayed-identity write is based on ``active_token`` — snapshotted
    BEFORE the registry lock was released in ``_global_auth_gate_state`` — so a
    concurrent ``cmd_add --replace`` / rotation can swap the active row's token
    value (same id) before the write lands. Returns ``""`` if ``row``'s CURRENT
    token still matches ``probed_fingerprint``, else the skip reason
    (``"row_deleted"`` / ``"token_replaced"``). The caller MUST hold the
    registry lock around this check so the verdict stays valid through the write
    it guards. The fingerprint compare keeps the raw token off disk / the audit
    log (mirrors ``cmd_check``'s PR #799 r3 recheck).
    """
    if row is None:
        return "row_deleted"
    current_token = str(row.get("token") or "")
    current_fingerprint = token_fingerprint(current_token) if current_token else ""
    if current_fingerprint != probed_fingerprint:
        return "token_replaced"
    return ""


IDENTITY_VERIFY_PROBE_ENV = "BRIDGE_CLAUDE_IDENTITY_VERIFY_PROBE"


def _identity_verify_probe_enabled() -> bool:
    """True iff the OPTIONAL verify-only identity probe is opted in (default-OFF).

    #18849 Part 1b-v2: the probe is no longer the identity SOURCE (the operator-
    provided ``account_email`` is). It survives only as an OPTIONAL, default-OFF
    diagnostic that cross-checks a scoped token's profile against the configured
    email. Steady state therefore makes NO network call — the whole point of
    #2145's closure is to drop the probe dependency.
    """
    return env_truthy(os.environ.get(IDENTITY_VERIFY_PROBE_ENV))


def _run_identity_verify_probe(
    registry_path: Path,
    token_id: str,
    active_token: str,
    probed_fingerprint: str,
    configured_email: str,
) -> str:
    """OPTIONAL verify-only identity probe (#18849 Part 1b-v2). Diagnostic only.

    NEVER the source and NEVER a blocker: it cross-checks the active token's
    ``user:profile`` profile against the operator-configured email and records a
    diagnostic into SEPARATE ``account_email_probe_*`` fields. A 403 / missing
    scope / no-email is a benign ``verify_skipped``; a verified MISMATCH WARNs
    only and NEVER overwrites ``account_email`` or rolls back the displayed
    identity. The diagnostic is dropped if the active token was swapped mid-probe
    (fingerprint recheck under the registry lock). Returns the recorded probe
    status (``""`` when dropped) for the result surface.
    """
    probe = probe_claude_account_identity(
        active_token, timeout_seconds=_identity_probe_timeout_seconds()
    )
    pstatus = str(probe.get("status") or "probe_failed")
    observed = str(probe.get("email") or "")
    if pstatus == "verified":
        if configured_email and observed and observed != configured_email:
            status, reason = "mismatch", "mismatch"
            print(
                "warning: optional identity verify-probe saw an account email "
                "that does NOT match the operator-configured account email; "
                "keeping the operator-configured identity (verify-only, no "
                "overwrite)",
                file=sys.stderr,
            )
        else:
            status, reason = "verified", "verified"
    elif pstatus in ("no_scope", "no_email"):
        status, reason = "verify_skipped", pstatus
    else:
        status, reason = "probe_failed", pstatus
    with registry_lock(registry_path):
        registry = load_registry(registry_path)
        row = find_token(registry, token_id)
        if _identity_row_token_skip_reason(row, probed_fingerprint):
            return ""  # token swapped mid-probe — drop the stale diagnostic
        # Record ONLY the separate probe-diagnostic fields. The configured
        # ``account_email`` / ``account_email_source`` are never touched here.
        row["account_email_probe_status"] = status
        row["account_email_probe_reason"] = reason
        row["account_email_last_probe_at"] = now_iso()
        if observed:
            row["account_email_probe_observed"] = observed
        save_registry(registry_path, registry)
    return status


def patch_global_claude_identity(
    config_path: Path,
    *,
    email: str,
    subject: str = "",
    owner_uid: int | None = None,
    allowed_root: Path | None = None,
) -> dict[str, Any]:
    """PATCH ~/.claude.json's displayed identity to a VERIFIED account email.

    Reuses the Part 1a r3 single-pinned-dir_fd hardening verbatim:
    ``claude_global_credentials_lock`` opens the parent ``O_DIRECTORY|O_NOFOLLOW``,
    fd-identity-validates it against ``allowed_root``, and YIELDS that fd; the
    existing file is read fd-relative (``O_RDONLY|O_NOFOLLOW``) and the new
    payload is written via ``_write_text_at_dirfd`` on the SAME fd — there is NO
    second ``os.open(str(parent))``, so a parent-swap after the lock cannot
    redirect the read or the write.

    PATCH-not-overwrite: replaces ONLY ``oauthAccount.emailAddress`` (+
    ``accountUuid`` when a verified subject is supplied) and preserves
    ``projects`` / ``mcpServers`` / every unknown key and the file's existing
    mode. Fails closed as root; an unparseable existing file is refused (never
    clobbered); an ABSENT ~/.claude.json is a skip (we never synthesize a
    degenerate config that would lose onboarding/projects).

    Returns ``{"changed", "created", "skipped", "reason"}``.
    """
    if not email:
        raise ValueError("refusing to write an empty/unverified identity email")
    if _global_credential_writer_is_root():
        raise PermissionError(
            "refusing to write the operator-global ~/.claude.json as root "
            "(geteuid==0) — identity sync must run as the operator UID, not root"
        )
    config_path = Path(config_path).expanduser()
    name = config_path.name
    with claude_global_credentials_lock(config_path, allowed_root=allowed_root) as dir_fd:
        try:
            cfg_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)
        except FileNotFoundError:
            # ~/.claude.json is large + load-bearing; a degenerate file carrying
            # only oauthAccount would lose onboarding/projects, so an absent
            # config is a no-op skip (there is no stale identity to correct).
            return {"changed": False, "created": False, "skipped": True,
                    "reason": "config_absent"}
        except OSError as exc:  # ELOOP on a symlinked final component → refuse
            raise PermissionError(
                f"refusing to read ~/.claude.json via a symlinked final "
                f"component: {config_path}: {exc}"
            ) from exc
        existing_mode = stat.S_IMODE(os.fstat(cfg_fd).st_mode) or 0o600
        with os.fdopen(cfg_fd, "rb") as fh:
            preimage = fh.read()
        try:
            payload = json.loads(preimage.decode("utf-8"))
        except Exception as exc:  # noqa: BLE001 - corrupt → refuse, never clobber
            raise ValueError(
                f"~/.claude.json is not valid JSON; refusing to overwrite a "
                f"possibly mid-login file: {config_path}: {exc}"
            ) from exc
        if not isinstance(payload, dict):
            raise ValueError(f"~/.claude.json must contain a JSON object: {config_path}")

        account = payload.get("oauthAccount")
        account = dict(account) if isinstance(account, dict) else {}
        already = account.get("emailAddress") == email and (
            not subject or account.get("accountUuid") == subject
        )
        if already:
            return {"changed": False, "created": False, "skipped": False,
                    "reason": "already_current"}
        account["emailAddress"] = email
        if subject:
            account["accountUuid"] = subject
        payload["oauthAccount"] = account

        text = json.dumps(payload, ensure_ascii=True, indent=2) + "\n"
        # Write FD-RELATIVE via the lock's pinned dir_fd — NO second
        # os.open(str(parent)). Preserve the operator's existing file mode rather
        # than force a new one (we are PATCHing one field of a personal file).
        _write_text_at_dirfd(
            dir_fd,
            name,
            text,
            mode=existing_mode,
            prefix=".claude.json.",
            owner_uid=owner_uid,
        )
        return {"changed": True, "created": False, "skipped": False,
                "reason": "identity_synced"}


def run_global_identity_sync(
    registry_path: Path,
    active_id: str,
    active_token: str,
    config_path: Path,
    *,
    credential_changed: bool,
    allowed_root: Path | None,
) -> dict[str, Any]:
    """Sync the displayed identity to the active token's OPERATOR-CONFIGURED account.

    Called from ``cmd_sync_global`` AFTER a gated credential PATCH. Best-effort:
    every failure path returns a structured result and NEVER raises, so an
    identity hiccup can never demote the token-sync convergence the daemon
    reports. #18849 Part 1b-v2 (closes #2145): the source is the operator-provided
    ``account_email`` (``source == "operator"``), NOT a network probe — steady
    state makes NO network call.

    Result ``status`` ∈ ``{synced, converged, unconfigured, skipped, write_failed}``
    with ``converged`` (displayed == configured) + ``configured_email`` /
    ``displayed_email`` / ``probe_status`` for the doctor surface. ``unconfigured``
    means the active row carries no operator ``account_email`` ⇒ NO WRITE (the
    fail-safe — never a guess). ``skipped`` with reason ``token_replaced`` /
    ``row_deleted`` / ``source_changed`` means a concurrent token replace / id
    drop / source change was detected under the write lock and the ~/.claude.json
    write was skipped.

    The OPTIONAL verify-only probe (default-OFF) is a pure diagnostic recorded
    into separate ``account_email_probe_*`` fields; it never sources the write.
    """
    displayed_email = read_oauth_account_email(config_path)
    # Keychain-exists guard: when auth is keychain-backed, the keychain owns the
    # displayed identity — detect + warn + skip rather than diverge the JSON.
    if operator_keychain_credentials_present():
        print(
            "warning: operator Claude auth is keychain-backed; skipping "
            "~/.claude.json identity sync to avoid diverging the displayed "
            "identity from the keychain login",
            file=sys.stderr,
        )
        return {"status": "skipped", "reason": "keychain_present", "synced": False,
                "converged": False, "displayed_email": displayed_email,
                "configured_email": "", "source": "", "probe_status": "keychain"}

    registry = load_registry(registry_path)
    row = find_token(registry, active_id) or {}
    configured_email = operator_account_email(row)
    # ``active_token`` was snapshotted under the registry lock in
    # ``_global_auth_gate_state`` and the lock then released. Carry its
    # fingerprint into the write path so a concurrent token replace (same id, new
    # value) before the write lands skips the displayed-identity write.
    probed_fingerprint = token_fingerprint(active_token)

    # OPTIONAL verify-only probe (default-OFF). Pure diagnostic — never source,
    # never blocker. Bounded to a real rotation or the re-probe cooldown so an
    # opted-in install does not probe every tick.
    probe_status = ""
    if _identity_verify_probe_enabled() and (
        credential_changed or _probe_cooldown_elapsed(row)
    ):
        probe_status = _run_identity_verify_probe(
            registry_path, active_id, active_token, probed_fingerprint,
            configured_email,
        )

    if not configured_email:
        # No operator-configured identity → fail-safe NO WRITE (never a guess,
        # never id-derived). A probe-sourced / unmarked-legacy ``account_email``
        # lands here too: ``operator_account_email`` already rejected it.
        return {"status": "unconfigured", "reason": "no_operator_account_email",
                "synced": False, "converged": False,
                "displayed_email": displayed_email, "configured_email": "",
                "source": str(row.get("account_email_source") or ""),
                "probe_status": probe_status
                or str(row.get("account_email_probe_status") or "")}

    # Re-read the active row under the registry lock, verify the active token
    # fingerprint is UNCHANGED and the source is STILL operator, and hold that
    # SAME lock through the fd-pinned ~/.claude.json PATCH. A concurrent
    # cmd_add --replace must take the same registry lock to swap the active
    # token, so it cannot interleave between the recheck and the write — this
    # preserves the Part 1b r2 token-replace-race fix WITHOUT a probe. Lock
    # order is always registry_lock -> claude_global_credentials_lock (the
    # config writer takes the latter internally); the config write is a fast
    # LOCAL op (not a network call), so the nesting neither deadlocks nor holds
    # the registry lock across slow I/O.
    skip_reason = ""
    locked_email = ""
    write_result: dict[str, Any] | None = None
    try:
        with registry_lock(registry_path):
            registry = load_registry(registry_path)
            row = find_token(registry, active_id)
            skip_reason = _identity_row_token_skip_reason(row, probed_fingerprint)
            if not skip_reason:
                locked_email = operator_account_email(row)
                if not locked_email:
                    # The operator source was cleared (e.g. a replace without an
                    # account email) between the unlocked read and the lock —
                    # never write a stale identity.
                    skip_reason = "source_changed"
                else:
                    write_result = patch_global_claude_identity(
                        config_path, email=locked_email, subject="",
                        allowed_root=allowed_root,
                    )
    except Exception as exc:  # noqa: BLE001 - identity write is best-effort on top of token sync
        print(f"warning: ~/.claude.json identity sync write failed: {exc}",
              file=sys.stderr)
        return {"status": "write_failed", "reason": str(exc), "synced": False,
                "converged": False, "displayed_email": displayed_email,
                "configured_email": configured_email, "source": "operator",
                "probe_status": probe_status}
    if skip_reason:
        # The active row was deleted / its token replaced / its operator source
        # cleared between the snapshot and the locked write: the configured
        # email no longer belongs to the active row. NO ~/.claude.json write.
        return {"status": "skipped", "reason": skip_reason, "synced": False,
                "converged": False, "displayed_email": displayed_email,
                "configured_email": "", "source": "operator",
                "probe_status": probe_status or skip_reason}
    if write_result.get("skipped"):
        return {"status": "skipped", "reason": write_result.get("reason"),
                "synced": False, "converged": False,
                "displayed_email": displayed_email, "configured_email": locked_email,
                "source": "operator", "probe_status": probe_status}
    synced = bool(write_result.get("changed"))
    return {"status": "synced" if synced else "converged",
            "reason": write_result.get("reason"), "synced": synced, "converged": True,
            "displayed_email": locked_email, "configured_email": locked_email,
            "source": "operator", "probe_status": probe_status}


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
    agent: str = "",
    writer: str = "",
    allow_apikeyhelper: bool = True,
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
    # Issue #2137 fix #6: snapshot the on-disk apiKeyHelper BEFORE the gate logic
    # so the audit row below fires only when this writer actually adds / removes /
    # changes the managed helper (not on every settings rewrite).
    before_helper = payload.get("apiKeyHelper")
    # #1444 BLOCKING 3 (Linux/iso-v2 leak): only RENDER the managed apiKeyHelper
    # when the gate is enabled AND we are on the platform the feature targets
    # (macOS — matching the Darwin-gated cron-runner/bridge-run.sh preflights).
    # On Linux/iso-v2 the controller helper path is wrong for the agent (and
    # under iso v2 not even reachable from the agent UID), so we must NEVER
    # write it there. The cleanup branch below still runs on non-Darwin so a
    # stale managed value (e.g. left by a pre-fix sync, or after the gate is
    # turned off) gets removed regardless of platform.
    if not allow_apikeyhelper:
        # Issue #2137 fix #3 (sync-path vector): the admin/interactive agent under
        # a BROAD selection scope (default / static / all / claude). Leave the
        # apiKeyHelper field EXACTLY as-is — the broad path must neither ADD the
        # managed helper (the live-incident hijack via the daemon's broad
        # `--agents static` sync) nor fight an explicit operator opt-in by
        # removing one. The admin's managed helper is only ever written / removed
        # when an explicit `--agents <admin>` targets it (allow_apikeyhelper=True).
        pass
    elif claude_keychain_free_auth_enabled() and keychain_free_apikeyhelper_supported():
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
    after_helper = payload.get("apiKeyHelper")
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
    # Issue #2137 fix #6: emit the forensic audit row AFTER the atomic write
    # SUCCEEDS (write_private_file_atomic raises on failure and propagates), so a
    # failed write never leaves a dangling row describing a change that did not
    # land. Fires only when this writer actually added / removed / changed the
    # managed apiKeyHelper — identifies which subprocess (writer-context label +
    # pid/ppid) touched which agent, the missing signal the live RCA needed.
    if before_helper != after_helper:
        if after_helper is None:
            apikeyhelper_action = "apikeyhelper_removed"
        elif before_helper is None:
            apikeyhelper_action = "apikeyhelper_added"
        else:
            apikeyhelper_action = "apikeyhelper_changed"
        auth_write_audit(
            {
                "kind": "claude_settings_apikeyhelper_write",
                "agent": agent,
                "writer": writer or settings_writer_context(),
                "apikeyhelper_action": apikeyhelper_action,
                "api_key_helper": after_helper or "",
                "settings_file": str(path),
                "gate_enabled": claude_keychain_free_auth_enabled(),
                "platform": host_platform(),
            }
        )
    return path


def settings_apikeyhelper_coherent(config_dir: Path) -> bool:
    """True when ``settings.json`` already points at the managed apiKeyHelper.

    Used by the #1855 backfill to decide create-if-absent vs no-op (and by
    cmd_sync_agent's cred-state honesty check). Mirrors the bridge-run.sh
    keychain-free preflight predicate: the value must be the exact path
    ``claude_api_key_helper_path()`` would write (canonical resolve). Any other
    value — absent, operator-owned, or a stale managed path — is NOT coherent.
    Never raises: an unreadable / malformed settings.json reads as not-coherent
    so the backfill repairs it.
    """
    try:
        path = claude_settings_write_path(config_dir)
    except Exception:  # noqa: BLE001 - symlink-escape etc. → repair
        return False
    if not path.exists():  # noqa: raw-pathlib-controller-only - controller settings-coherence probe on the resolved write path
        return False
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 - malformed → repair
        return False
    if not isinstance(parsed, dict):
        return False
    actual = parsed.get("apiKeyHelper")
    if not isinstance(actual, str) or not actual:
        return False
    actual_path = Path(actual).expanduser()
    if not actual_path.is_absolute():
        return False
    return str(actual_path.resolve(strict=False)) == claude_api_key_helper_path()


def cmd_backfill_settings(args: argparse.Namespace) -> int:
    """Issue #1855: create-if-absent backfill of the keychain-free apiKeyHelper
    contract for a single pre-#1520 shared Claude agent.

    Pre-#1520 shared static admins were provisioned before
    ``ensure_claude_settings_file`` learned to wire ``apiKeyHelper`` — so their
    per-agent ``settings.json`` carries no apiKeyHelper, the #1520 keychain-free
    gate (Darwin + executable helper + settings wired + active registry OAT)
    can never pass, and the shared launch silently degrades to the operator
    keychain instead of consuming the claude-token OAT pool. Same create-time-
    only materialization gap as #1809 (AGENTS.md backfill): nothing ever
    backfilled the older agents.

    This reuses the EXACT provision-time writer (``ensure_claude_settings_file``)
    so the backfilled end-state is byte-identical to a fresh-install scaffold.
    Idempotent + gated:
      - gate disabled / non-Darwin → no-op (``status: skipped``). Mirrors the
        ``keychain_free_apikeyhelper_supported`` platform guard the writer and
        the bridge-run.sh preflight both honor — never render a controller
        helper path into a non-macOS agent's settings.
      - already coherent (settings.json already points at the managed helper)
        → no-op (``changed: false``).
      - missing / incoherent → write via the shared atomic writer
        (``changed: true``, ``backfilled: true``).
    """
    json_mode = bool(args.json)
    check_only = bool(getattr(args, "check", False))
    config_dir = Path(args.config_dir).expanduser()
    agent = (args.agent or "").strip()
    owner_uid = args.owner_uid if args.owner_uid is not None and args.owner_uid >= 0 else None
    owner_gid = args.owner_gid if args.owner_gid is not None and args.owner_gid >= 0 else None
    allowed_root = Path(args.allowed_root).expanduser() if args.allowed_root else None

    if not (claude_keychain_free_auth_enabled() and keychain_free_apikeyhelper_supported()):
        payload = {
            "status": "skipped",
            "agent": agent,
            "reason": "keychain_free_disabled_or_unsupported_platform",
            "changed": False,
            "coherent": True,
        }
        if json_mode:
            json_dump(payload)
        else:
            print(f"skipped: {agent or config_dir} (keychain-free off or non-Darwin)")
        return 0

    already = settings_apikeyhelper_coherent(config_dir)

    if check_only:
        # Issue #1855 deliverable 3 (credential-coherence drift): read-only —
        # report whether this keychain-free Darwin agent's settings.json points
        # at the managed apiKeyHelper, WITHOUT writing. `coherent: false` is the
        # provisioning-generation-drift / credential-coherence signal: the agent
        # is on the legacy keychain fallback while the runtime ships the
        # keychain-free contract. The daemon/doctor surface this so a registry
        # "synced" stamp can be cross-checked against the launch path's true
        # auth source instead of silently diverging from a fresh install.
        payload = {
            "status": "ok",
            "agent": agent,
            "coherent": already,
            "drift": (not already),
            "changed": False,
            "api_key_helper": claude_api_key_helper_path(),
        }
        if json_mode:
            json_dump(payload)
        elif already:
            print(f"ok: {agent or config_dir} keychain-free coherent")
        else:
            print(f"drift: {agent or config_dir} settings.json does not point at managed apiKeyHelper")
        return 0

    # codex review (PR #1858) MAJOR 2: a coherent agent must be a TRUE no-op —
    # do NOT call the writer. ensure_claude_settings_file always rewrites
    # settings.json atomically (PR #799 r4 removed its same-payload fast path),
    # so calling it on an already-contracted agent thrashes the file (and, under
    # iso v2, a fresh chown/replace) on every daily cadence tick while reporting
    # `changed:false`. Short-circuit here so the hygiene pass touches disk ONLY
    # when it actually has a backfill to apply. `settings.json` already exists in
    # the coherent case (settings_apikeyhelper_coherent returned True), so the
    # reported settings_file is the real on-disk path the launch reads.
    if already:
        settings_path = claude_settings_write_path(config_dir)
        payload = {
            "status": "ok",
            "agent": agent,
            "settings_file": str(settings_path),
            "api_key_helper": claude_api_key_helper_path(),
            "changed": False,
            "backfilled": False,
            "coherent": True,
        }
        if json_mode:
            json_dump(payload)
        else:
            print(f"ok: {agent or config_dir} already keychain-free coherent")
        return 0

    try:
        settings_file = ensure_claude_settings_file(
            config_dir,
            owner_uid=owner_uid,
            owner_gid=owner_gid,
            allowed_root=allowed_root,
            agent=agent,
            writer="backfill-settings",
        )
    except Exception as exc:
        return fail(str(exc), json_mode)

    payload = {
        "status": "ok",
        "agent": agent,
        "settings_file": str(settings_file),
        "api_key_helper": claude_api_key_helper_path(),
        "changed": True,
        "backfilled": True,
        "coherent": True,
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"backfilled: {agent or config_dir} <- apiKeyHelper ({settings_file})")
    return 0


def cmd_keychain_free(args: argparse.Namespace) -> int:
    """Issue #2137 fixes #4 & #5: sanctioned enable/disable/status for the
    keychain-free apiKeyHelper gate, with a FAIL-CLOSED enable preflight.

    ``enable`` runs ``keychain_free_preflight`` first; if any check fails the gate
    is left UNCHANGED and nothing is written — so a broken/expired registry OAT
    (or an unreachable helper) can never silently move interactive Claude onto
    API-key billing (the live #2137 incident). ``disable`` flips the gate off;
    the subsequent sync/backfill removes the managed helpers. ``status`` reports
    the current gate + a (non-mutating) preflight snapshot."""
    action = args.action
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    env_override = keychain_free_env_override()

    if action == "status":
        enabled = claude_keychain_free_auth_enabled()
        preflight = keychain_free_preflight(registry_path)
        payload = {
            "status": "ok",
            "action": "status",
            "enabled": enabled,
            "env_override": env_override,
            "preflight": preflight,
        }
        if json_mode:
            json_dump(payload)
        else:
            gate = "enabled" if enabled else "disabled"
            pf = "ok" if preflight["ok"] else "would-fail"
            shadow = f" [env override {env_override!r} in effect]" if env_override is not None else ""
            print(f"keychain-free: {gate} (enable preflight: {pf}){shadow}")
        return 0

    # Mutating actions (enable / disable): a live env override would SHADOW the
    # config write, so the verb reports success while the effective gate stays
    # unchanged. Refuse fail-closed and tell the operator to unset it (issue
    # #2137 fix #4 — never report a silent false-success).
    if env_override is not None:
        return fail(
            "BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH env override is set "
            f"({env_override!r}) and takes precedence over runtime config; a "
            f"`keychain-free {action}` would be shadowed and not take effect. "
            "Unset BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH to manage the gate via config.",
            json_mode,
        )

    if action == "disable":
        path, reason = write_keychain_free_gate(False)
        if path is None:
            return fail(f"keychain-free disable failed: {reason}", json_mode)
        auth_write_audit(
            {
                "kind": "claude_keychain_free_gate",
                "action": "disable",
                "config_file": str(path),
            }
        )
        payload = {
            "status": "ok",
            "action": "disable",
            "enabled": False,
            "config_file": str(path),
        }
        if json_mode:
            json_dump(payload)
        else:
            print(
                f"keychain-free disabled ({path}); run a sync/backfill to "
                "remove the managed apiKeyHelper from agent settings"
            )
        return 0

    # action == "enable" (argparse `choices` guarantees the third value).
    preflight = keychain_free_preflight(registry_path)
    if not preflight["ok"]:
        # FAIL CLOSED — do NOT flip the gate; write nothing. Enabling now would
        # move interactive Claude onto a broken API key (the #2137 incident).
        failed = [c["check"] for c in preflight["checks"] if not c["ok"]]
        auth_write_audit(
            {
                "kind": "claude_keychain_free_gate",
                "action": "enable_refused",
                "reason": "preflight_failed",
                "failed_checks": failed,
            }
        )
        payload = {
            "status": "refused",
            "action": "enable",
            "reason": "preflight_failed",
            "enabled": claude_keychain_free_auth_enabled(),
            "preflight": preflight,
        }
        if json_mode:
            json_dump(payload)
        else:
            print(
                "refused: keychain-free enable preflight failed "
                f"({', '.join(failed)}) — gate left unchanged, no managed helper "
                "written into interactive agents",
                file=sys.stderr,
            )
        return 1

    path, reason = write_keychain_free_gate(True)
    if path is None:
        return fail(f"keychain-free enable failed: {reason}", json_mode)
    auth_write_audit(
        {
            "kind": "claude_keychain_free_gate",
            "action": "enable",
            "config_file": str(path),
        }
    )
    payload = {
        "status": "ok",
        "action": "enable",
        "enabled": True,
        "config_file": str(path),
        "preflight": preflight,
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"keychain-free enabled ({path})")
    return 0


def cmd_global_auth_sync(args: argparse.Namespace) -> int:
    """#18849 — sanctioned enable/disable/status for the operator-global
    seamless-token-sync opt-in (``BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC``).

    Mirrors ``keychain-free``: a persisted runtime-config boolean, written via
    ``write_global_auth_sync_gate``, so the operator never raw-edits
    bridge-config.json. The effective gate is ``persisted OR env=="1"`` — the
    env override is an INDEPENDENT, precedence-bearing contributor, so (unlike
    ``keychain-free``) a live override does NOT shadow the persisted write and a
    mutation is never refused under it. ``disable`` clears the persisted bool but
    can only WARN when a live env override keeps the gate on — it cannot remove
    an env value (unset it manually)."""
    action = args.action
    json_mode = bool(args.json)
    persisted = global_auth_sync_persisted_enabled()
    env_override_enabled = global_auth_sync_env_override_enabled()
    effective = persisted or env_override_enabled
    effective_source = global_auth_sync_effective_source()

    if getattr(args, "check", False):
        # #19260 — exit-code-only effective-state probe for the daemon early-skip.
        # NEVER mutates and prints nothing: returns 0 iff EFFECTIVELY enabled so
        # the bash early-skip reuses THIS persisted-OR-env predicate as the single
        # source of truth (an env-only bash gate would skip a verb-enabled
        # persisted opt-in and kill the feature at the daemon).
        return 0 if effective else 1

    if action == "status":
        # The status --json schema is exactly the four effective-state fields
        # and no envelope (no status/action wrapper).
        payload = {
            "enabled": effective,
            "persisted_enabled": persisted,
            "env_override_enabled": env_override_enabled,
            "effective_source": effective_source,
        }
        if json_mode:
            json_dump(payload)
        else:
            gate = "enabled" if effective else "disabled"
            print(
                f"global-auth-sync: {gate} "
                f"(persisted={persisted}, env_override={env_override_enabled}, "
                f"source={effective_source})"
            )
        return 0

    if action == "disable":
        path, reason = write_global_auth_sync_gate(False)
        if path is None:
            return fail(f"global-auth-sync disable failed: {reason}", json_mode)
        auth_write_audit(
            {
                "kind": "claude_global_auth_sync_gate",
                "action": "disable",
                "config_file": str(path),
            }
        )
        # The persisted bool is cleared, but the env override is independent and
        # precedence-bearing — if it is still "1" the gate stays EFFECTIVELY ON,
        # so we must not claim a full disable (the "looks applied but isn't"
        # trap). Re-read the override post-write (env is process-stable here).
        still_on_by_env = global_auth_sync_env_override_enabled()
        payload = {
            "status": "ok",
            "action": "disable",
            "enabled": still_on_by_env,
            "persisted_enabled": False,
            "env_override_enabled": still_on_by_env,
            "config_file": str(path),
        }
        if still_on_by_env:
            payload["warning"] = (
                "still enabled by env override: BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1 "
                "is set and takes precedence; remove it to fully disable "
                "(unset BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC in the environment)"
            )
        if json_mode:
            json_dump(payload)
        else:
            print(f"global-auth-sync persisted opt-in cleared ({path})")
            if still_on_by_env:
                print(
                    "warning: still enabled by env override "
                    "(BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=1 takes precedence); remove "
                    "it to fully disable — unset BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC "
                    "in the environment",
                    file=sys.stderr,
                )
        return 0

    # action == "enable" (argparse `choices` guarantees the third value).
    path, reason = write_global_auth_sync_gate(True)
    if path is None:
        return fail(f"global-auth-sync enable failed: {reason}", json_mode)
    auth_write_audit(
        {
            "kind": "claude_global_auth_sync_gate",
            "action": "enable",
            "config_file": str(path),
        }
    )
    payload = {
        "status": "ok",
        "action": "enable",
        "enabled": True,
        "persisted_enabled": True,
        "env_override_enabled": env_override_enabled,
        "config_file": str(path),
    }
    if json_mode:
        json_dump(payload)
    else:
        print(f"global-auth-sync enabled ({path})")
    return 0


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
            agent=args.agent,
            writer="sync-agent",
            # Issue #2137 fix #3 (sync-path vector): the bash sync loop passes
            # `--no-apikeyhelper` for the admin/interactive agent under a broad
            # selection scope, so a broad daemon sync distributes the OAT
            # credential to the admin WITHOUT moving it onto the managed
            # apiKeyHelper. The admin's helper is only managed via an explicit
            # `--agents <admin>`.
            allow_apikeyhelper=not bool(getattr(args, "no_apikeyhelper", False)),
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
        # Issue #1855 cred-state honesty: on a keychain-free Darwin install the
        # launched shared agent authenticates via the apiKeyHelper wired into
        # its per-agent settings.json — NOT the .credentials.json we just wrote.
        # If settings.json does not point at the managed helper (a pre-#1520
        # agent the apiKeyHelper backfill never reached), the #1520 gate can
        # never pass and the launch silently degrades to the operator keychain:
        # the agent never consumes the rendered per-agent credential even though
        # we stamped it `synced`. Surface that incoherence as a structured field
        # (and a stderr warning) instead of asserting a delivery that cannot
        # happen, so the daemon sync-tick audit and watchdog/doctor can see it.
        # Best-effort + non-fatal: the credential write itself already succeeded.
        if keychain_free_apikeyhelper_supported():
            try:
                coherent = settings_apikeyhelper_coherent(credential_file.parent)
            except Exception:  # noqa: BLE001 - never turn a good sync into a failure
                coherent = True
            payload["keychain_free_settings_coherent"] = coherent
            if not coherent:
                payload["status"] = "synced_incoherent"
                print(
                    f"warning: {args.agent} synced a per-agent credential its "
                    "launch path cannot consume — settings.json does not point "
                    "at the managed apiKeyHelper (pre-#1520 agent). Run "
                    f"`agent-bridge upgrade` or `agent-bridge auth claude-token "
                    f"backfill-settings --agents {args.agent}` to wire the "
                    "keychain-free contract so this agent joins the OAT pool.",
                    file=sys.stderr,
                )
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


def _global_auth_gate_state(registry_path: Path) -> tuple[bool, bool, str, str]:
    """Read the default-OFF double-gate + active token under the registry lock.

    Returns ``(auto_rotate, opt_in, active_id, active_token)``. Both gate bits
    are read together so the daemon and the doctor surface agree on WHY a global
    write is (not) eligible. ``active_id`` / ``active_token`` are ``""`` when no
    healthy active token is registered. The registry read is the only locked
    work — the slower credential write happens afterwards (cmd_recover_due
    pattern), and the opt-in env is process-constant so there is no second file
    to race.
    """
    auto_rotate = False
    active_id = ""
    active_token = ""
    with registry_lock(registry_path):
        registry = load_registry(registry_path)
        auto_rotate = bool(registry.get("auto_rotate_enabled", False))
        try:
            active_id, active_token = active_registry_token(registry)
        except ValueError:
            active_id, active_token = "", ""
    return auto_rotate, global_auth_sync_opt_in_enabled(), active_id, active_token


def cmd_sync_global(args: argparse.Namespace) -> int:
    """Write the active registry token into the operator-global credential file.

    #18849 Part 1: the seamless dynamic-vanilla rotation step. Double-gated
    default-OFF (``auto_rotate_enabled`` AND ``BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC``);
    PATCHes (never overwrites) ``~/.claude/.credentials.json`` so a running
    dynamic agent re-reads the new token at its next prompt boundary. Part 1b
    then ALSO syncs the displayed ``oauthAccount`` identity in ~/.claude.json to
    the active token's VERIFIED account (``run_global_identity_sync``).
    """
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    global_path = resolve_controller_claude_credentials_path(
        getattr(args, "global_credentials", None)
    )
    config_path = (
        Path(args.claude_config).expanduser()
        if getattr(args, "claude_config", None)
        else resolve_operator_claude_config_path(global_path)
    )

    try:
        auto_rotate, opt_in, active_id, active_token = _global_auth_gate_state(
            registry_path
        )
    except Exception as exc:  # noqa: BLE001 - registry unreadable → fail closed
        return fail(f"global auth sync: registry read failed: {exc}", json_mode)

    # Default-OFF double gate. A disabled gate is a NO-WRITE skip, never an
    # error — an install that has not opted in must converge to "nothing
    # happened" without touching the operator credential file.
    if not opt_in or not auto_rotate:
        reason = (
            "global_auth_sync_opt_in_disabled"
            if not opt_in
            else "auto_rotate_disabled"
        )
        payload = {
            "status": "skipped",
            "reason": reason,
            "converged": False,
            "gate": {"auto_rotate_enabled": auto_rotate, "opt_in_enabled": opt_in},
            "global_path": str(global_path),
        }
        if json_mode:
            print(json.dumps(payload, ensure_ascii=True, indent=2))
        else:
            print(f"skipped: {reason}")
        return 0

    if not active_id or not active_token:
        return fail(
            "global auth sync is enabled but no healthy active Claude token is "
            "registered; refusing to touch the operator credential file",
            json_mode,
        )

    # We run as the operator (the bash layer never escalates this path and
    # patch_global_claude_credentials fails closed on root). Do NOT pass
    # --owner-uid: a chown to a foreign uid would EPERM, and chowning to our own
    # uid is a no-op — the writer already lands the file owned by the operator.
    allowed_root = (
        Path(args.allowed_root).expanduser()
        if getattr(args, "allowed_root", None)
        else None
    )
    try:
        result = patch_global_claude_credentials(
            global_path,
            active_token,
            expires_at_ms=CLAUDE_OAUTH_EXPIRES_AT_MS,
            allowed_root=allowed_root,
        )
    except Exception as exc:  # noqa: BLE001 - any write failure → fail closed
        # gate 5: on failure the preimage was rolled back inside the writer and
        # we report NO convergence so the daemon does not claim the dynamic
        # fleet picked up the new token.
        return fail(f"global auth sync write failed: {exc}", json_mode)

    # Identity SYNC (#18849 Part 1b): the token write above only converges the
    # active TOKEN; the DISPLAYED oauthAccount identity in ~/.claude.json can be
    # stale. Sync it to the active token's VERIFIED account (probe-verified, never
    # guessed). Best-effort — run_global_identity_sync never raises, so an
    # identity hiccup cannot demote the token-sync convergence the daemon reports.
    identity_shadow = run_global_identity_sync(
        registry_path,
        active_id,
        active_token,
        config_path,
        credential_changed=bool(result["changed"]),
        allowed_root=allowed_root,
    )

    status = "synced" if result["changed"] else "converged"
    payload = {
        "status": status,
        "reason": "rotated_token" if result["changed"] else "already_current",
        "converged": True,
        "changed": bool(result["changed"]),
        "created": bool(result["created"]),
        "active_token_id": active_id,
        "fingerprint": result["fingerprint"],
        "global_path": str(global_path),
        "gate": {"auto_rotate_enabled": auto_rotate, "opt_in_enabled": opt_in},
        "identity_shadow": identity_shadow,
    }
    if json_mode:
        print(json.dumps(payload, ensure_ascii=True, indent=2))
    else:
        print(f"{status}: operator-global <- {active_id} ({result['fingerprint']})")
    return 0


def cmd_global_auth_status(args: argparse.Namespace) -> int:
    """Read-only doctor/status surface for the operator-global auth sync (#18849).

    Reports the default-OFF double-gate state, whether the operator-global
    credential currently converges on the active registry token (by
    fingerprint), and the Part 1b identity convergence (displayed oauthAccount
    email vs the last VERIFIED account email). Never writes / never probes —
    this is the read-only doctor surface for
    ``agent-bridge auth claude-token global-auth-status``.
    """
    json_mode = bool(args.json)
    registry_path = Path(args.registry).expanduser()
    global_path = resolve_controller_claude_credentials_path(
        getattr(args, "global_credentials", None)
    )
    config_path = (
        Path(args.claude_config).expanduser()
        if getattr(args, "claude_config", None)
        else resolve_operator_claude_config_path(global_path)
    )

    try:
        auto_rotate, opt_in, active_id, active_token = _global_auth_gate_state(
            registry_path
        )
    except Exception as exc:  # noqa: BLE001 - status must surface, never crash
        return fail(f"global auth status: registry read failed: {exc}", json_mode)

    enabled = bool(opt_in and auto_rotate)
    active_fp = token_fingerprint(active_token) if active_token else ""

    global_fp = ""
    global_present = False
    try:
        if not global_path.is_symlink() and global_path.is_file():  # noqa: raw-pathlib-controller-only - controller-side read of the operator-global credential file for status; read-only, never mutates
            global_present = True
            parsed = json.loads(global_path.read_text(encoding="utf-8"))
            if isinstance(parsed, dict):
                oauth = parsed.get("claudeAiOauth")
                if isinstance(oauth, dict) and isinstance(oauth.get("accessToken"), str):
                    global_fp = token_fingerprint(oauth["accessToken"])
    except Exception:  # noqa: BLE001 - unreadable global file → report absent fp
        global_fp = ""

    converged = bool(enabled and active_fp and global_fp and active_fp == global_fp)
    displayed_email = read_oauth_account_email(config_path)

    # #18849 Part 1b-v2: report the OPERATOR-CONFIGURED account identity from the
    # active token row + whether the displayed identity has CONVERGED on it.
    # Read-only — the status surface NEVER probes / never writes; it reflects the
    # operator-configured ``account_email`` (source==operator) and the last
    # OPTIONAL verify-probe diagnostic sync-global recorded. ``verified`` is
    # reserved for that probe diagnostic; CONVERGENCE is configured-identity-based.
    identity_row: dict[str, Any] = {}
    try:
        identity_row = find_token(load_registry(registry_path), active_id) or {}
    except Exception:  # noqa: BLE001 - status must surface even on a bad registry
        identity_row = {}
    configured_email = operator_account_email(identity_row)
    identity_converged = bool(configured_email) and displayed_email == configured_email
    probe_reason = str(identity_row.get("account_email_probe_reason") or "")
    identity_shadow = {
        "displayed_email": displayed_email,
        "configured_email": configured_email,
        "source": str(identity_row.get("account_email_source") or ""),
        "set_at": str(identity_row.get("account_email_set_at") or ""),
        # OPTIONAL verify-only probe diagnostic (default-OFF), stored SEPARATELY
        # from the configured source: status ∈ {verified, verify_skipped,
        # mismatch, probe_failed}; reason is granular; observed is the probe-seen
        # email. It NEVER drives convergence — a 403/no_scope is a benign
        # verify_skipped, a mismatch only WARNs.
        "probe_status": str(identity_row.get("account_email_probe_status") or ""),
        "probe_reason": probe_reason,
        "probe_observed": str(identity_row.get("account_email_probe_observed") or ""),
        "synced": identity_converged,
        "converged": identity_converged,
    }
    # Warn ONLY when the displayed identity is OUT OF SYNC with the operator-
    # configured identity (configured set but displayed != configured). A
    # converged identity — or one with no operator email configured yet — is the
    # quiet state, not a warning.
    if enabled and configured_email and displayed_email and not identity_converged:
        identity_shadow["warning"] = (
            "displayed oauthAccount identity does not match the operator-configured "
            "account — re-run sync-global to converge the displayed identity"
        )

    payload = {
        "status": "ok",
        "enabled": enabled,
        "gate": {"auto_rotate_enabled": auto_rotate, "opt_in_enabled": opt_in},
        "active_token_id": active_id,
        "active_fingerprint": active_fp,
        "global_present": global_present,
        "global_fingerprint": global_fp,
        "converged": converged,
        "identity_converged": identity_converged,
        "identity_shadow": identity_shadow,
        "global_path": str(global_path),
    }
    if json_mode:
        print(json.dumps(payload, ensure_ascii=True, indent=2))
    else:
        state = "enabled" if enabled else "disabled"
        conv = "converged" if converged else "not-converged"
        ident = "identity-converged" if identity_converged else "identity-unsynced"
        print(
            f"global auth sync: {state} (auto_rotate={auto_rotate} "
            f"opt_in={opt_in}); {conv}; {ident}; identity verify-probe: "
            f"{_identity_probe_reason_label(probe_reason)}; displayed_identity="
            f"{displayed_email or '<none>'}; configured_identity="
            f"{configured_email or '<none>'}"
        )
    return 0


def cmd_reconcile_keychain(args: argparse.Namespace) -> int:
    """Diagnose (and with ``--apply``, clean) a Claude Code keychain shadow (#2171).

    macOS-only. Full-enumerates ``Claude Code-credentials*`` keychain entries
    (base + hashed-service variants) and compares each entry's OAuth access-token
    fingerprint with the EXPECTED active pool token. A matching entry is healthy;
    a MISMATCHING entry is a stale shadow that makes a session ignore its rotating
    ``.credentials.json`` and authenticate with the wrong (e.g. limit-hit
    personal) token — the confirmed sean-m4 M4 fleet-down RCA.

    Default = fail-closed diagnostic: report the shadow, delete NOTHING, exit 3
    on a detected shadow so a health gate notices. ``--apply`` is the
    operator-approved cleanup path that deletes ONLY the stale entries.
    Fingerprint-only — the raw secret never reaches stdout / the audit log.
    """
    json_mode = bool(args.json)
    apply_cleanup = bool(getattr(args, "apply", False))
    registry_path = Path(args.registry).expanduser()
    security_bin = _security_binary()
    claude_config_dir = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()

    # Non-Darwin hosts have no login keychain to shadow — report a clean no-op
    # without shelling out to security(1).
    if host_platform() != "Darwin":
        payload = {
            "status": "skipped_non_darwin",
            "platform": host_platform(),
            "applied": False,
            "claude_config_dir": claude_config_dir,
            "expected_fingerprint": "",
            "expected_source": "",
            "entries": [],
            "stale_count": 0,
            "stale_services": [],
            "deleted": [],
            "delete_errors": [],
        }
        if json_mode:
            json_dump(payload)
        else:
            print(f"reconcile-keychain: skipped (non-Darwin host: {host_platform()})")
        return 0

    # The EXPECTED (good) fingerprint: a specific agent's `.credentials.json`
    # OAuth access token when `--expected-credentials` is given, else the active
    # registry pool token. With no determinable expected fingerprint every entry
    # is INDETERMINATE — never classified stale, never deleted (fail-closed).
    expected_fp = ""
    expected_source = ""
    expected_creds = getattr(args, "expected_credentials", None)
    if expected_creds:
        creds_path = Path(expected_creds).expanduser()
        try:
            secret = creds_path.read_text(encoding="utf-8").strip()
        except Exception as exc:  # noqa: BLE001 - unreadable expected source is fatal
            return fail(
                f"reconcile-keychain: unreadable --expected-credentials: {exc}",
                json_mode,
            )
        token = _extract_oauth_access_token(secret)
        expected_fp = token_fingerprint(token) if token else ""
        expected_source = f"credentials:{creds_path}"
    else:
        try:
            registry = load_registry(registry_path)
            active_id, active_token = active_registry_token(registry)
            expected_fp = token_fingerprint(active_token)
            expected_source = f"registry-active:{active_id}"
        except Exception:  # noqa: BLE001 - no active token → indeterminate, never stale
            expected_fp = ""
            expected_source = "registry-active:<none>"

    services, enum_error = keychain_claude_service_names(security_bin)
    if enum_error:
        # Fail-CLOSED (#2171 PR-D review F1): enumeration never ran, so we CANNOT
        # claim "no shadow". Report an explicit failure, delete NOTHING even
        # under --apply, and exit non-zero so a health gate notices the gap.
        payload = {
            "status": "keychain_enumeration_failed",
            "platform": "Darwin",
            "applied": False,
            "claude_config_dir": claude_config_dir,
            "expected_fingerprint": expected_fp,
            "expected_source": expected_source,
            "entries": [],
            "stale_count": 0,
            "stale_services": [],
            "deleted": [],
            "delete_errors": [],
            "error": enum_error,
        }
        if json_mode:
            json_dump(payload)
        else:
            print(
                f"reconcile-keychain: keychain_enumeration_failed ({enum_error}); "
                "deleted nothing (cannot inspect keychain — fail-closed)"
            )
        return 2
    entries: list[dict[str, str]] = []
    stale_services: list[str] = []
    unreadable_services: list[str] = []
    for service in services:
        fingerprint, err = keychain_entry_fingerprint(security_bin, service)
        if err:
            match_state = "unreadable"
            unreadable_services.append(service)
        elif not expected_fp:
            match_state = "indeterminate"
        elif fingerprint == expected_fp:
            match_state = "match"
        else:
            match_state = "stale"
            stale_services.append(service)
        entries.append(
            {
                "service": service,
                "fingerprint": fingerprint,
                "match": match_state,
                "error": err,
            }
        )

    deleted: list[str] = []
    delete_errors: list[dict[str, str]] = []
    # Fail-closed: never MUTATE the keychain while ANY enumerated entry could not
    # be read (#2171 PR-D review r3). With a mix of confirmed-stale + unreadable
    # entries we cannot prove the unreadable one is not the active token, so we
    # delete nothing until every relevant entry is classifiable — the operator
    # resolves the unreadable entry (e.g. unlock the keychain) and re-runs --apply.
    if apply_cleanup and stale_services and not unreadable_services:
        for service in stale_services:
            ok, derr = keychain_delete_service(security_bin, service)
            if ok:
                deleted.append(service)
            else:
                delete_errors.append({"service": service, "error": derr})

    stale_count = len(stale_services)
    unreadable_count = len(unreadable_services)
    if not services:
        status = "clean_no_entries"
    elif not expected_fp:
        # Entries exist but no active pool token / expected source is readable —
        # nothing can be CLASSIFIED (let alone deleted). Report honestly rather
        # than a false "clean"; fail-closed leaves every entry untouched.
        status = "indeterminate_no_active"
    elif unreadable_count:
        # An enumerated Claude Code entry could not be READ, so we cannot tell
        # whether it is the active token or a stale shadow. Fail-closed REGARDLESS
        # of stale_count (#2171 PR-D review r2+r3): a mix of confirmed-stale +
        # unreadable must NOT report "cleaned"/rc0 while an un-inspected entry
        # remains. The cleanup block above is gated on zero unreadable, so nothing
        # was deleted here.
        status = "indeterminate_unreadable"
    elif stale_count == 0:
        status = "clean"
    elif apply_cleanup:
        status = "cleanup_incomplete" if delete_errors else "cleaned"
    else:
        status = "shadow_detected"

    payload = {
        "status": status,
        "platform": "Darwin",
        "applied": apply_cleanup,
        "claude_config_dir": claude_config_dir,
        "expected_fingerprint": expected_fp,
        "expected_source": expected_source,
        "entries": entries,
        "stale_count": stale_count,
        "stale_services": stale_services,
        "unreadable_count": unreadable_count,
        "unreadable_services": unreadable_services,
        "deleted": deleted,
        "delete_errors": delete_errors,
        # Remediation note (brief item 7): a plain `restart --no-continue` is NOT
        # enough — a static/admin pane can still resolve `Claude Max`. After
        # cleanup, restart the affected agent and verify the pane auth-mode flips
        # to `Claude API`. Live pane-title detection is the restart/health path's
        # job, not this auth helper's.
        "remediation": (
            "after cleanup, restart the affected agent and verify the pane "
            "auth-mode reads 'Claude API' (not 'Claude Max'); a plain "
            "restart --no-continue alone may not flip a shadowed pane"
        ),
    }

    if json_mode:
        json_dump(payload)
    else:
        cfg = claude_config_dir or "<operator-global>"
        print(
            f"reconcile-keychain: {status} (entries={len(entries)} "
            f"stale={stale_count} applied={apply_cleanup}); "
            f"expected_fp={expected_fp or '<none>'} ({expected_source}); "
            f"CLAUDE_CONFIG_DIR={cfg}"
        )
        for entry in entries:
            detail = entry["error"] or entry["fingerprint"] or "<none>"
            print(f"  - {entry['service']}: {entry['match']} ({detail})")
        if deleted:
            print(f"  deleted: {', '.join(deleted)}")
        if delete_errors:
            failed = ", ".join(e["service"] for e in delete_errors)
            print(f"  delete FAILED: {failed}")

    if delete_errors:
        return 1
    if unreadable_count:
        # Fail-closed: a relevant entry was found but could not be inspected
        # (#2171 PR-D review r2+r3) — non-zero regardless of stale_count, and the
        # cleanup block above already declined to mutate the keychain.
        return 2
    if stale_count and not apply_cleanup:
        return 3
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

    # ── agent-context refusal (BEST-EFFORT deterrent, #1367 r4/r5) ───
    # #1367's SECURITY GUARANTEE is narrow and holds BY CONSTRUCTION: when
    # the OPERATOR runs `receive` from THEIR OWN terminal, the token is read
    # echo-off from /dev/tty (below) and never transits an agent's
    # transcript / argv / env / queue / audit. That guarantee does NOT
    # depend on this check.
    #
    # This refusal is a BEST-EFFORT DETERRENT, NOT an airtight boundary. An
    # agent process carries BRIDGE_AGENT_ID and the operator's own shell
    # does not, so we refuse affirmatively when it is set. But
    # BRIDGE_AGENT_ID is CALLER-CONTROLLED: on a SHARED-UID host (e.g.
    # macOS) an agent has the same powers as the operator and can clear it
    # (`env -u BRIDGE_AGENT_ID` / `unset` / invoke this entrypoint directly)
    # and attach a pty to reach the token-accepting write (codex #1367 r4
    # proof). That residual is acceptable because such an agent can only
    # store ITS OWN token — it does not possess the operator's — so it is
    # OUTSIDE #1367's threat model; and per CLAUDE.md the hook/runtime are a
    # containment+audit layer, NOT a sandbox. On iso-v2 (UID-separated
    # Linux) the locked registry's controller-UID ownership is the real FS
    # boundary an iso agent cannot cross. The PreToolUse hook
    # (_is_bash_wrapper_receive) is a parallel best-effort deterrent for the
    # common bash-wrapper spellings. The token-free `--request` shape
    # returned above is unaffected, so an admin agent can still INITIATE the
    # flow without touching a token.
    agent_ctx = os.environ.get("BRIDGE_AGENT_ID", "").strip()  # noqa: iso-helper-boundary - best-effort agent-context deterrent for the operator-only token-accepting receive
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

    # #18849 Part 1b-v2: the operator-provided displayed-identity source. An
    # explicit --account-email wins; otherwise a fulfilled request may carry the
    # (non-secret) email captured by `receive --request --account-email`. Validate
    # BEFORE the token is read so a bad value fails closed with nothing written.
    account_email_raw = getattr(args, "account_email", None) or ""
    if not account_email_raw and request_record is not None:
        account_email_raw = str(request_record.get("account_email") or "")
    account_email = ""
    if account_email_raw:
        try:
            account_email = validate_account_email(account_email_raw)
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
            account_email=account_email,
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
    request_dir.mkdir(mode=0o700, parents=True, exist_ok=True)  # noqa: raw-pathlib-controller-only - controller secrets-dir sibling of the registry
    path = request_dir / f"{record['request_id']}.json"
    text = json.dumps(record, ensure_ascii=True, indent=2) + "\n"
    write_private_file_atomic(path, text, mode=0o600, prefix=".sealed-req.")
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

    # #18849 Part 1b-v2: the request record may carry the NON-SECRET operator
    # account email so the operator's `receive --fulfill` lands the displayed
    # identity without re-typing it. Format-validated; never a token.
    account_email = ""
    if getattr(args, "account_email", None):
        try:
            account_email = validate_account_email(args.account_email)
        except Exception as exc:
            return fail(str(exc), json_mode)

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
        "account_email": account_email,
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
        "account_email": account_email,
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


def _nonnegative_int(raw: str) -> int:
    """argparse ``type`` that rejects negative integers.

    Used for ``--preflight-budget``: a negative value (only reachable via a
    fat-fingered env override) must NOT silently fall through the
    ``budget > 0`` gate and disable the budget — that would re-open the
    unbounded ring the budget exists to close. Fail closed at parse time.
    """
    parsed = int(raw)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return parsed


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
    # #18849 Part 1b-v2 (closes #2145): operator-provided displayed-identity
    # source (non-secret). On --replace, omitting it CLEARS any prior identity.
    add_parser.add_argument("--account-email", dest="account_email", default=None)
    add_parser.add_argument("--enable-auto-rotate", action="store_true")
    add_parser.add_argument("--threshold", type=float)
    add_parser.add_argument("--weekly-warn-threshold", type=float, dest="weekly_warn_threshold")
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
    # #18849 Part 1b-v2: the non-secret operator account email. On the token-FREE
    # `--request` shape it is stored in the request record; on the token-accepting
    # `--fulfill`/direct shape it is captured onto the row (explicit wins over the
    # fulfilled request's stored value).
    receive_parser.add_argument("--account-email", dest="account_email", default=None)
    receive_parser.add_argument("--enable-auto-rotate", action="store_true")
    receive_parser.add_argument("--threshold", type=float)
    receive_parser.add_argument("--agents", default=None)
    receive_parser.add_argument("--json", action="store_true")
    receive_parser.set_defaults(handler=cmd_receive)

    list_parser = sub.add_parser("list")
    list_parser.add_argument("--json", action="store_true")
    list_parser.set_defaults(handler=cmd_list)

    # #18849 Part 1b-v2 (closes #2145): set per-token operator metadata. Today
    # the operator-provided account email — the BINDING displayed-identity source.
    set_parser = sub.add_parser("set")
    set_parser.add_argument("--id", required=True)
    set_parser.add_argument("--account-email", dest="account_email", required=True)
    set_parser.add_argument("--json", action="store_true")
    set_parser.set_defaults(handler=cmd_set)

    activate_parser = sub.add_parser("activate")
    activate_parser.add_argument("id")
    activate_parser.add_argument("--sync", action="store_true", help=argparse.SUPPRESS)
    activate_parser.add_argument("--agents", help=argparse.SUPPRESS)
    activate_parser.add_argument("--json", action="store_true")
    activate_parser.set_defaults(handler=cmd_activate)

    rotate_parser = sub.add_parser("rotate")
    rotate_parser.add_argument("--if-auto-enabled", action="store_true")
    rotate_parser.add_argument("--reason", default="")
    # #1789: ISO reset_at of the rotating-away token's 429 limit window.
    # Recorded as the old row's `limited_until` so selection can skip
    # still-limited tokens. Timestamp only — never token bytes.
    rotate_parser.add_argument("--limited-until", default="")
    # #2171 selected-candidate live preflight (opt-in, default OFF for backward
    # compatibility). When set, the selected rotation candidate is LIVE-probed
    # before the active pointer is committed — see cmd_rotate / _cmd_rotate_preflight.
    rotate_parser.add_argument("--preflight", action="store_true")
    # Short probe budget for the preflight so the new network op fits inside the
    # daemon's rotate timeout (probe_claude_token's own default is 45s).
    rotate_parser.add_argument("--preflight-timeout", type=int, default=12)
    # #2171 PR-B2: GLOBAL preflight budget (total live-probe seconds across the
    # whole ring pass). 0 (default) = unbounded — the legacy per-candidate-timeout
    # behavior. The daemon passes a small positive budget so a multi-candidate
    # ring can never out-run the rotate timeout, and a spent budget fail-closes
    # the unprobed candidates (see _cmd_rotate_preflight). Non-negative only: a
    # negative value would silently disable the budget gate (fail OPEN), so it is
    # rejected at parse time.
    rotate_parser.add_argument("--preflight-budget", type=_nonnegative_int, default=0)
    # #2171 PR-B3: token-free measured-usage prefilter. Repeatable path(s) to the
    # `.usage-cache.json` readings; the candidate-selection gate skips a token
    # whose own digest maps to a near-limit reading. Absent ⇒ the prefilter is a
    # no-op (the default until the daemon wires the cache paths through).
    rotate_parser.add_argument(
        "--measured-usage-cache", action="append", default=None, help=argparse.SUPPRESS
    )
    # Reuse the monitor's thresholds + freshness window for the prefilter (no new
    # knobs): 5h ≥ --rotation-threshold or weekly ≥ --weekly-warn-threshold marks
    # a window near-limit; a reading older than --cache-max-age-seconds is dropped.
    rotate_parser.add_argument("--rotation-threshold", type=float, default=99.0, help=argparse.SUPPRESS)
    rotate_parser.add_argument("--weekly-warn-threshold", type=float, default=95.0, help=argparse.SUPPRESS)
    rotate_parser.add_argument(
        "--cache-max-age-seconds", type=float, default=21600.0, help=argparse.SUPPRESS
    )
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
    # Set the weekly preemptive warn threshold alongside rotation_threshold.
    auto_parser.add_argument("--weekly-warn-threshold", type=float, dest="weekly_warn_threshold")
    auto_parser.add_argument("--json", action="store_true")
    auto_parser.set_defaults(handler=cmd_auto_rotate)

    helper_parser = sub.add_parser("api-key-helper")
    helper_parser.add_argument("--check", action="store_true")
    helper_parser.add_argument("--json", action="store_true")
    helper_parser.set_defaults(handler=cmd_api_key_helper)

    # Issue #2137 fixes #4 & #5: sanctioned enable/disable/status for the
    # keychain-free apiKeyHelper gate, with a fail-closed enable preflight.
    keychain_free_parser = sub.add_parser("keychain-free")
    keychain_free_parser.add_argument("action", choices=("enable", "disable", "status"))
    keychain_free_parser.add_argument("--json", action="store_true")
    keychain_free_parser.set_defaults(handler=cmd_keychain_free)

    # #18849: sanctioned enable/disable/status for the operator-global seamless
    # token-sync opt-in (persisted runtime-config bool; env override is a
    # secondary, precedence-bearing path surfaced by `status`).
    global_auth_sync_parser = sub.add_parser("global-auth-sync")
    global_auth_sync_parser.add_argument(
        "action", choices=("enable", "disable", "status")
    )
    global_auth_sync_parser.add_argument("--json", action="store_true")
    global_auth_sync_parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "exit-code-only effective-state probe (no stdout/mutation): exit 0 "
            "iff the opt-in is EFFECTIVELY enabled (persisted runtime-config bool "
            "OR BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC=='1'), exit 1 otherwise. The daemon "
            "early-skip calls `global-auth-sync status --check` so the cheap bash "
            "skip reuses THIS single python predicate — never re-deriving the gate "
            "in bash, which is the source-of-truth drift behind #19260."
        ),
    )
    global_auth_sync_parser.set_defaults(handler=cmd_global_auth_sync)

    # Issue #1855: create-if-absent keychain-free settings backfill for a single
    # pre-#1520 shared Claude agent (driven per-agent by the upgrade / daemon
    # hygiene roster loop). Reuses ensure_claude_settings_file so the end state
    # is byte-identical to a fresh-install scaffold.
    backfill_settings_parser = sub.add_parser("backfill-settings")
    backfill_settings_parser.add_argument("--config-dir", required=True)
    backfill_settings_parser.add_argument("--agent", default="")
    backfill_settings_parser.add_argument("--owner-uid", type=int, default=None)
    backfill_settings_parser.add_argument("--owner-gid", type=int, default=None)
    backfill_settings_parser.add_argument("--allowed-root", default=None)
    backfill_settings_parser.add_argument(
        "--check",
        action="store_true",
        help="Issue #1855: read-only credential-coherence drift report — never writes settings.json",
    )
    backfill_settings_parser.add_argument("--json", action="store_true")
    backfill_settings_parser.set_defaults(handler=cmd_backfill_settings)

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
    sync_parser.add_argument(
        "--no-apikeyhelper",
        action="store_true",
        help=(
            "Issue #2137 fix #3: sync the OAT credential but do NOT add/remove "
            "the managed keychain-free apiKeyHelper for this agent. The bash sync "
            "loop sets it for the admin/interactive agent under a broad selection "
            "scope so a broad daemon sync can never move the admin onto API-key "
            "billing without an explicit --agents <admin>."
        ),
    )
    sync_parser.add_argument("--json", action="store_true")
    sync_parser.set_defaults(handler=cmd_sync_agent)

    # ── Operator-global seamless rotation (#18849 Part 1) ─────────────
    # Double-gated default-OFF PATCH of ~/.claude/.credentials.json so a
    # dynamic-vanilla Claude agent re-reads the rotated token seamlessly.
    sync_global_parser = sub.add_parser("sync-global")
    sync_global_parser.add_argument(
        "--global-credentials",
        default=None,
        help="explicit path to the operator-global ~/.claude/.credentials.json",
    )
    sync_global_parser.add_argument(
        "--claude-config",
        default=None,
        help="explicit path to the operator ~/.claude.json (oauthAccount detection)",
    )
    sync_global_parser.add_argument(
        "--allowed-root",
        default=None,
        help="require the resolved global credential dir to stay under this real path",
    )
    sync_global_parser.add_argument("--json", action="store_true")
    sync_global_parser.set_defaults(handler=cmd_sync_global)

    global_status_parser = sub.add_parser(
        "global-auth-status",
        help="report operator-global auth + configured-identity convergence",
        description=(
            "Read-only doctor surface for the gated operator-global auth sync "
            "(#18849). Default-OFF: needs BRIDGE_CLAUDE_GLOBAL_AUTH_SYNC AND "
            "auto_rotate. The Part 1b-v2 displayed-identity sync (closes #2145) "
            "converges ~/.claude.json's oauthAccount.emailAddress onto the active "
            "token's OPERATOR-CONFIGURED account_email (source==operator, set via "
            "claude-token add/receive/set --account-email). With no operator email "
            "configured it is a fail-safe no-op (configured_identity=<none>); it "
            "never guesses or id-derives. The optional verify-only probe is a "
            "default-OFF diagnostic surfaced as identity_shadow.probe_* — never a "
            "source and never a blocker (a 403 is a benign verify_skipped)."
        ),
    )
    global_status_parser.add_argument("--global-credentials", default=None)
    global_status_parser.add_argument("--claude-config", default=None)
    global_status_parser.add_argument("--json", action="store_true")
    global_status_parser.set_defaults(handler=cmd_global_auth_status)

    # #2171 (incident #19460 M4 fleet-down) PR-D: macOS-only keychain shadow
    # self-heal. Default = fail-closed diagnostic; --apply is the operator-
    # approved cleanup that deletes ONLY the stale hashed-service shadow entries.
    reconcile_kc_parser = sub.add_parser(
        "reconcile-keychain",
        help="diagnose (and with --apply, clean) a Claude Code keychain shadow (#2171, macOS-only)",
        description=(
            "Full-enumerate 'Claude Code-credentials*' login-keychain entries "
            "(base + the hashed service-name variant Claude Code uses) and compare "
            "each entry's OAuth access-token fingerprint with the EXPECTED active "
            "pool token (the active registry token, or --expected-credentials's "
            ".credentials.json). A mismatching entry is a stale shadow that makes a "
            "session authenticate with the wrong token despite a correct "
            ".credentials.json (the sean-m4 M4 RCA). Default is a FAIL-CLOSED "
            "diagnostic (report, delete nothing, exit 3 on a detected shadow); "
            "--apply is the operator-approved cleanup that deletes only the stale "
            "entries. Fingerprint-only — the raw secret never reaches stdout."
        ),
    )
    reconcile_kc_parser.add_argument(
        "--apply",
        action="store_true",
        help="operator-approved cleanup: DELETE the stale shadow keychain entries (default: diagnostic only)",
    )
    reconcile_kc_parser.add_argument(
        "--expected-credentials",
        dest="expected_credentials",
        default=None,
        help="path to a per-agent .credentials.json whose accessToken is the EXPECTED fingerprint (default: active registry pool token)",
    )
    reconcile_kc_parser.add_argument("--json", action="store_true")
    reconcile_kc_parser.set_defaults(handler=cmd_reconcile_keychain)

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
