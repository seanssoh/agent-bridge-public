#!/usr/bin/env python3
"""bridge-usage-probe.py — native Anthropic OAuth usage probe (#1437 PRIMARY).

On a headless cron host there is no Claude Code statusLine process, so
`hud-usage-tap.py` never runs and `.usage-cache.json` is never produced.
The token-rotation monitor (`bridge-usage.py`) therefore sees no Claude
`used_percent` and never rotates the OAT proactively — the account just
hard-limits. claude-hud is a *display* layer; it should not be the only
thing that knows the account's usage.

This module gives agent-bridge its own native usage source: a direct GET
to Anthropic's OAuth usage endpoint, mapped into the EXACT `.usage-cache.json`
shape the existing monitor/rotation path already consumes
(`data.fiveHour` / `sevenDay` / `fiveHourResetAt` / `sevenDayResetAt`,
0–100). No change to the rotation/threshold logic — this is purely a new
SOURCE that writes the cache the daemon already reads.

Endpoint (undocumented / internal — `anthropic-beta: oauth-2025-04-20`):

    GET https://api.anthropic.com/api/oauth/usage
    Authorization: Bearer <active OAT access token>
    anthropic-beta: oauth-2025-04-20
    User-Agent:   claude-code/<version>   # MANDATORY — omitting it 429s
    Accept:       application/json

Response (utilization on a 0–100 scale):

    { "five_hour": {"utilization": 33.0, "resets_at": "..Z"},
      "seven_day": {"utilization": 13.0, "resets_at": "..Z"}, ... }

Risk mitigations (the endpoint rate-limits the poll itself):
  - User-Agent always present.
  - ≥5min cache (CACHE_MAX_AGE): serve the cached file rather than re-probe.
  - Cooldown on failure (serve stale cache during the cooldown window).
  - Respect Retry-After on 429 (single capped retry, then serve stale).
  - Defensive parse: `five_hour` may be null/absent → fall back to seven_day;
    any window value may be null; extra windows are ignored.
  - Scope guard: empty/missing windows likely mean the token lacks the
    `user:profile` scope (not an outage) → one-line hint, degrade, no probe.
  - Graceful degrade: any failure leaves the existing cache untouched and
    exits 0 so the daemon's usage pass never blocks/crashes.

CREDENTIAL HANDLING: the OAT is read into memory and used ONLY in the
Authorization header. It is never logged, never written to any file by this
module, and never exported into a subprocess env. The probe makes the HTTP
call in-process (urllib) — there is no subprocess, so there is no env-leak
surface for an interpreter to pick the token up from.

The HTTP call is isolated behind ``_http_get_usage`` so tests inject a mock
and NEVER touch the network.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

USAGE_ENDPOINT = "https://api.anthropic.com/api/oauth/usage"
ANTHROPIC_BETA = "oauth-2025-04-20"
DEFAULT_USER_AGENT_VERSION = "2.1.0"

# Risk-mitigation knobs (operator-overridable via env in bridge-usage.sh).
DEFAULT_CACHE_MAX_AGE_SECONDS = 300  # ≥5min: do NOT probe per daemon tick.
DEFAULT_COOLDOWN_SECONDS = 60  # serve stale during this window after a failure.
DEFAULT_HTTP_TIMEOUT_SECONDS = 10
DEFAULT_RETRY_AFTER_CAP_SECONDS = 5  # max we honor a 429 Retry-After before bailing.

CACHE_SOURCE = "native-oauth-probe"
# Sidecar next to the cache that records the last *attempt* time (success OR
# failure) so the cooldown can be honored without re-reading the main cache's
# semantics. Never contains the token.
PROBE_STATE_BASENAME = ".usage-probe-state.json"

TOKEN_ENV_KEY = "CLAUDE_CODE_OAUTH_TOKEN"


# --------------------------------------------------------------------------- #
# Token source (read-only; never logged / persisted / env-exported)
# --------------------------------------------------------------------------- #
def _read_active_token_from_registry(registry_path: Path) -> str | None:
    """Read the active OAT from agent-bridge's rotation registry.

    Read-only: we open the registry, find the row whose ``id`` equals
    ``active_token_id``, and return its ``token``. We do NOT import or call
    any bridge-auth.py function (kept disjoint from the reactive #1441 lane)
    and we never mutate the registry.
    """
    try:
        payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    active_id = str(payload.get("active_token_id") or "")
    rows = payload.get("tokens")
    if not active_id or not isinstance(rows, list):
        return None
    for row in rows:
        if not isinstance(row, dict):
            continue
        if str(row.get("id") or "") == active_id:
            token = row.get("token")
            if isinstance(token, str) and token.strip():
                return token.strip()
    return None


def _read_token_from_fd(fd: int) -> str | None:
    """Read a bare OAT from a deliberately-inherited file descriptor.

    Issue #1437 r12 (codex BLOCKING): the wrapper (bridge-usage.sh) delivers the
    env-source token to the probe via an INHERITED fd on an UNLINKED 0600 file —
    NOT a ``--token-file <path>`` (the path is visible in argv / the process
    table, and the linked temp file is briefly readable). With an inherited fd
    there is no path in argv and no on-disk file to find. We read the fd once
    here; the wrapper owns the fd's lifecycle (closed right after the probe).
    """
    try:
        # os.read on the raw fd; the wrapper writes the bare token (no newline).
        chunks = []
        while True:
            buf = os.read(fd, 65536)
            if not buf:
                break
            chunks.append(buf)
        token = b"".join(chunks).decode("utf-8", errors="replace").strip()
    except Exception:
        return None
    return token or None


def _read_token_from_token_file(path: Path) -> str | None:
    """Read a bare OAT from a deliberately-supplied token file.

    Issue #1437 r2 (codex BLOCKER 2): the env source must be delivered
    DELIBERATELY, not inherited ambiently into unrelated subprocess envs. The
    wrapper writes the env-source token to a short-lived 0600 temp file and
    passes ``--token-file``; we read it once here. (Superseded by ``--token-fd``
    in r12 to avoid the argv-visible path; ``--token-file`` is retained for
    direct-CLI / back-compat use.) The probe never writes/persists the token.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return None
    token = text.strip()
    return token or None


def _read_token_from_credentials_file(path: Path) -> str | None:
    """Fallback: ``~/.claude/.credentials.json`` → ``claudeAiOauth.accessToken``."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    oauth = payload.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        return None
    token = oauth.get("accessToken")
    if isinstance(token, str) and token.strip():
        return token.strip()
    return None


def resolve_active_token(
    registry_path: Path | None,
    credentials_path: Path | None,
    token_file: Path | None = None,
    *,
    token_fd: int | None = None,
    allow_env: bool = True,
) -> str | None:
    """Resolve the currently-active OAT, in priority order.

    1. agent-bridge rotation registry (the pool's active token) — preferred,
       so the probe always sees whatever the rotation logic just activated.
    2. ``--token-fd`` — a deliberately-inherited fd on an unlinked 0600 file
       (#1437 r12: no argv-visible path, no on-disk file to find). The wrapper's
       primary daemon-path delivery.
    3. ``--token-file`` — a deliberately-supplied 0600 file (retained for direct
       CLI / back-compat; superseded by --token-fd on the daemon path).
    4. ``CLAUDE_CODE_OAUTH_TOKEN`` env (only when ``allow_env`` — the wrapper
       scrubs the env, so this is a fallback for direct CLI use, not the daemon).
    5. ``~/.claude/.credentials.json`` (claudeAiOauth.accessToken).

    Returns None when no source yields a token — the caller then degrades.
    macOS Keychain (`Claude Code-credentials`) is intentionally NOT shelled
    out to here: it would require exporting/printing the token through a
    subprocess boundary, which is exactly the env-leak anti-pattern we avoid.
    The credentials-file path covers the headless-host case this feature
    targets.
    """
    if registry_path is not None:
        token = _read_active_token_from_registry(registry_path)
        if token:
            return token

    if token_fd is not None:
        token = _read_token_from_fd(token_fd)
        if token:
            return token

    if token_file is not None:
        token = _read_token_from_token_file(token_file)
        if token:
            return token

    if allow_env:
        env_token = os.environ.get(TOKEN_ENV_KEY, "").strip()  # noqa: iso-helper-boundary — controller env read, not a .env file
        if env_token:
            return env_token

    if credentials_path is not None:
        token = _read_token_from_credentials_file(credentials_path)
        if token:
            return token

    return None


# --------------------------------------------------------------------------- #
# HTTP seam (mockable — tests inject this; production hits the network)
# --------------------------------------------------------------------------- #
class ProbeHTTPError(Exception):
    """Raised by the HTTP seam on a non-2xx response.

    ``status`` is the HTTP status code; ``retry_after`` is the parsed
    Retry-After header in seconds (or None); ``body`` is the response body
    text (token-free — it is the server's error JSON).
    """

    def __init__(
        self,
        status: int,
        body: str = "",
        retry_after: float | None = None,
    ) -> None:
        super().__init__(f"usage probe HTTP {status}")
        self.status = status
        self.body = body
        self.retry_after = retry_after


def _parse_retry_after(value: str | None) -> float | None:
    if not value:
        return None
    try:
        seconds = float(value.strip())
    except (TypeError, ValueError):
        return None
    if seconds < 0:
        return None
    return seconds


def _http_get_usage(
    url: str,
    headers: dict[str, str],
    timeout: float,
) -> str:
    """Perform the GET and return the response body as text.

    INJECTION SEAM: tests replace this symbol with a stub so no live request
    is ever made in CI. Raises ``ProbeHTTPError`` on non-2xx (with parsed
    Retry-After) and lets transport errors (urllib.error.URLError, socket
    timeouts) propagate to the caller's degrade path.
    """
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            charset = resp.headers.get_content_charset() or "utf-8"
            return resp.read().decode(charset, errors="replace")
    except urllib.error.HTTPError as exc:
        retry_after = _parse_retry_after(exc.headers.get("Retry-After") if exc.headers else None)
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            body = ""
        raise ProbeHTTPError(exc.code, body=body, retry_after=retry_after) from None


def _user_agent(version: str | None) -> str:
    ver = (version or "").strip() or DEFAULT_USER_AGENT_VERSION
    return f"claude-code/{ver}"


def _build_headers(token: str, user_agent_version: str | None) -> dict[str, str]:
    # MANDATORY: User-Agent must look like claude-code/<ver> or the endpoint
    # aggressively 429s the poll. The token lives ONLY in this dict, in-process.
    return {
        "Authorization": f"Bearer {token}",
        "anthropic-beta": ANTHROPIC_BETA,
        "User-Agent": _user_agent(user_agent_version),
        "Accept": "application/json",
        "Content-Type": "application/json",
    }


# --------------------------------------------------------------------------- #
# Parsing (defensive — utilization → cache shape)
# --------------------------------------------------------------------------- #
def _window_utilization(window: Any) -> float | None:
    """Extract a 0–100 utilization from one API window object, or None."""
    if not isinstance(window, dict):
        return None
    raw = window.get("utilization")
    if raw is None:
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


def _window_reset(window: Any) -> str | None:
    if not isinstance(window, dict):
        return None
    reset = window.get("resets_at")
    if isinstance(reset, str) and reset.strip():
        return reset
    return None


def map_payload_to_cache(payload: Any) -> dict[str, Any] | None:
    """Map a raw ``api/oauth/usage`` response to the `.usage-cache.json` shape.

    Returns None when neither the five_hour nor the seven_day window carries
    a usable utilization — the likely cause is a token without the
    ``user:profile`` scope (the endpoint returns empty/null windows), NOT a
    genuine 0% usage. Returning None lets the caller degrade and log a scope
    hint rather than spuriously writing a 0% cache (which could mask a real
    rotation trigger).
    """
    if not isinstance(payload, dict):
        return None

    five_hour = payload.get("five_hour")
    seven_day = payload.get("seven_day")

    fh = _window_utilization(five_hour)
    sd = _window_utilization(seven_day)

    # Defensive: if BOTH windows are null/absent, there is no signal. Treat as
    # "no usable data" rather than 0% so we don't fabricate a snapshot.
    if fh is None and sd is None:
        return None

    return {
        "data": {
            "planName": "subscription",
            "fiveHour": fh,
            "sevenDay": sd,
            "fiveHourResetAt": _window_reset(five_hour),
            "sevenDayResetAt": _window_reset(seven_day),
        },
        "_source": CACHE_SOURCE,
        "_written_at": datetime.now(timezone.utc).isoformat(),
    }


# --------------------------------------------------------------------------- #
# Atomic cache write (same path + temp-then-replace as hud-usage-tap.py)
# --------------------------------------------------------------------------- #
def default_cache_path() -> Path:
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")  # noqa: iso-helper-boundary — controller env read, not a .env file
    return Path(home) / "plugins" / "claude-hud" / ".usage-cache.json"


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    cache_dir = path.parent
    cache_dir.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(cache_dir), prefix=".usage-cache.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


# --------------------------------------------------------------------------- #
# Cache freshness + cooldown bookkeeping (no token ever written here)
# --------------------------------------------------------------------------- #
def cache_is_fresh(cache_path: Path, max_age_seconds: float, now: float) -> bool:
    """True when a native-sourced cache exists and is younger than max_age.

    Only a cache WE wrote (``_source == native-oauth-probe``) counts toward
    freshness — a stdin-tap cache from a previous statusLine run must not
    suppress the native probe on a headless host.
    """
    try:
        st = cache_path.stat()
    except OSError:
        return False
    age = now - st.st_mtime
    # A future-dated mtime (age < 0) means clock skew or a synthetic clock —
    # do NOT treat it as fresh (better to re-probe than to trust a cache we
    # cannot age). Anything older than max_age is stale.
    if age < 0 or age >= max_age_seconds:
        return False
    try:
        payload = json.loads(cache_path.read_text(encoding="utf-8"))
    except Exception:
        return False
    return isinstance(payload, dict) and payload.get("_source") == CACHE_SOURCE


def _probe_state_path(cache_path: Path) -> Path:
    return cache_path.parent / PROBE_STATE_BASENAME


def _read_last_attempt(cache_path: Path) -> float | None:
    try:
        payload = json.loads(_probe_state_path(cache_path).read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    ts = payload.get("last_attempt_epoch")
    try:
        return float(ts)
    except (TypeError, ValueError):
        return None


def _record_attempt(cache_path: Path, now: float, outcome: str) -> None:
    """Persist the last-attempt epoch (success or failure) for cooldown.

    Token-free: stores only an epoch + a coarse outcome string.
    """
    try:
        _atomic_write_json(
            _probe_state_path(cache_path),
            {"last_attempt_epoch": now, "outcome": outcome},
        )
    except Exception:
        pass


def in_cooldown(cache_path: Path, cooldown_seconds: float, now: float) -> bool:
    last = _read_last_attempt(cache_path)
    if last is None:
        return False
    return (now - last) < cooldown_seconds


# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #
def run_probe(
    *,
    cache_path: Path,
    registry_path: Path | None,
    credentials_path: Path | None,
    token_file: Path | None = None,
    token_fd: int | None = None,
    allow_env: bool = True,
    user_agent_version: str | None,
    max_age_seconds: float,
    cooldown_seconds: float,
    http_timeout: float,
    retry_after_cap: float,
    now: float | None = None,
    http_get=_http_get_usage,
    log=None,
) -> dict[str, Any]:
    """Refresh the native usage cache when due; otherwise serve stale.

    Returns a token-free result dict describing what happened
    (``status`` ∈ fresh/written/cooldown/degraded/no-token/scope-degraded).
    NEVER raises into the caller — every failure path degrades and returns.
    The existing cache is only ever REPLACED on a successful, parseable probe;
    any failure leaves whatever cache is on disk untouched (serve stale).
    """
    now = time.time() if now is None else now

    def _log(msg: str) -> None:
        if log is not None:
            log(msg)

    # 1. Freshness gate — within CACHE_MAX_AGE, do NOT re-probe.
    if cache_is_fresh(cache_path, max_age_seconds, now):
        return {"status": "fresh", "cache_path": str(cache_path)}

    # 2. Cooldown gate — a recent failure means serve stale, don't hammer.
    if in_cooldown(cache_path, cooldown_seconds, now):
        _log("[usage-probe] in cooldown after recent failure; serving stale cache")
        return {"status": "cooldown", "cache_path": str(cache_path)}

    # 3. Token (read-only; never logged).
    token = resolve_active_token(
        registry_path, credentials_path, token_file,
        token_fd=token_fd, allow_env=allow_env,
    )
    if not token:
        _log("[usage-probe] no active OAT available; native probe degraded")
        return {"status": "no-token", "cache_path": str(cache_path)}

    headers = _build_headers(token, user_agent_version)

    # 4. Probe with a single Retry-After-bounded retry on 429.
    body: str | None = None
    try:
        body = http_get(USAGE_ENDPOINT, headers, http_timeout)
    except ProbeHTTPError as exc:
        if exc.status == 429:
            wait = exc.retry_after
            if wait is not None and 0 <= wait <= retry_after_cap:
                _log(f"[usage-probe] 429; honoring Retry-After={wait:g}s (single retry)")
                time.sleep(wait)
                try:
                    body = http_get(USAGE_ENDPOINT, headers, http_timeout)
                except Exception:
                    body = None
            else:
                _log("[usage-probe] 429; Retry-After absent/too-long, serving stale")
        else:
            _log(f"[usage-probe] HTTP {exc.status}; serving stale cache")
    except Exception:
        # Transport error / timeout / unexpected — degrade silently (no token
        # could be in this message, but we don't echo it either).
        _log("[usage-probe] probe request failed; serving stale cache")
        body = None

    if body is None:
        _record_attempt(cache_path, now, "failure")
        return {"status": "degraded", "cache_path": str(cache_path)}

    # 5. Parse + map defensively.
    try:
        payload = json.loads(body)
    except Exception:
        _record_attempt(cache_path, now, "failure")
        _log("[usage-probe] response was not JSON; serving stale cache")
        return {"status": "degraded", "cache_path": str(cache_path)}

    cache = map_payload_to_cache(payload)
    if cache is None:
        # Likely a token without the user:profile scope (empty/null windows),
        # NOT a real outage. Degrade with a clear hint; do not write a 0% cache.
        _record_attempt(cache_path, now, "scope")
        _log(
            "[usage-probe] usage windows empty/null — the active OAT likely "
            "lacks the 'user:profile' scope; native probe degraded (no rotation "
            "signal). Re-issue the token with the usage scope to enable it."
        )
        return {"status": "scope-degraded", "cache_path": str(cache_path)}

    # 6. Atomic write — replaces the cache the monitor reads.
    try:
        _atomic_write_json(cache_path, cache)
    except Exception:
        _record_attempt(cache_path, now, "failure")
        _log("[usage-probe] cache write failed; serving stale cache")
        return {"status": "degraded", "cache_path": str(cache_path)}

    _record_attempt(cache_path, now, "success")
    return {
        "status": "written",
        "cache_path": str(cache_path),
        "fiveHour": cache["data"]["fiveHour"],
        "sevenDay": cache["data"]["sevenDay"],
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()  # noqa: iso-helper-boundary — controller env read, not a .env file
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if value >= 0 else default


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Native Anthropic OAuth usage probe (#1437).")
    sub = parser.add_subparsers(dest="command", required=True)

    probe = sub.add_parser("probe", help="probe usage and refresh .usage-cache.json")
    probe.add_argument("--cache-path", default=None)
    probe.add_argument("--registry-path", default=None)
    probe.add_argument("--credentials-path", default=None)
    # #1437 r2/r12: deliberate token delivery. --token-fd (r12) is the daemon
    # path: an inherited fd on an unlinked 0600 file (no argv-visible path, no
    # on-disk file). --token-file (r2) is retained for direct-CLI / back-compat.
    # --no-env-token disables the ambient-env source so the daemon path does not
    # depend on inherited environment.
    probe.add_argument("--token-fd", type=int, default=None)
    probe.add_argument("--token-file", default=None)
    probe.add_argument("--no-env-token", action="store_true")
    probe.add_argument("--user-agent-version", default=None)
    probe.add_argument("--max-age", type=float, default=None)
    probe.add_argument("--cooldown", type=float, default=None)
    probe.add_argument("--http-timeout", type=float, default=None)
    probe.add_argument("--json", action="store_true")
    probe.set_defaults(handler=cmd_probe)

    return parser


def cmd_probe(args: argparse.Namespace) -> int:
    cache_path = (
        Path(args.cache_path).expanduser() if args.cache_path else default_cache_path()
    )
    registry_path = (
        Path(args.registry_path).expanduser() if args.registry_path else None
    )
    credentials_path = (
        Path(args.credentials_path).expanduser()
        if args.credentials_path
        else Path(os.path.expanduser("~/.claude/.credentials.json"))
    )
    max_age = (
        args.max_age
        if args.max_age is not None
        else _env_float("BRIDGE_USAGE_PROBE_MAX_AGE", DEFAULT_CACHE_MAX_AGE_SECONDS)
    )
    cooldown = (
        args.cooldown
        if args.cooldown is not None
        else _env_float("BRIDGE_USAGE_PROBE_COOLDOWN", DEFAULT_COOLDOWN_SECONDS)
    )
    http_timeout = (
        args.http_timeout
        if args.http_timeout is not None
        else _env_float("BRIDGE_USAGE_PROBE_HTTP_TIMEOUT", DEFAULT_HTTP_TIMEOUT_SECONDS)
    )
    token_file = Path(args.token_file).expanduser() if args.token_file else None

    result = run_probe(
        cache_path=cache_path,
        registry_path=registry_path,
        credentials_path=credentials_path,
        token_file=token_file,
        token_fd=args.token_fd,
        allow_env=not args.no_env_token,
        user_agent_version=args.user_agent_version,
        max_age_seconds=max_age,
        cooldown_seconds=cooldown,
        http_timeout=http_timeout,
        retry_after_cap=DEFAULT_RETRY_AFTER_CAP_SECONDS,
        log=lambda m: print(m, file=sys.stderr),
    )
    if args.json:
        print(json.dumps(result, ensure_ascii=True))
    # Always exit 0: the probe is best-effort and must never block/crash the
    # daemon's usage pass (graceful degrade). The status field carries detail.
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
