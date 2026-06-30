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
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
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

# Issue #1468: a GENUINE usage-endpoint 429 (rate_limit_error, valid request /
# UA present) is itself strong evidence the ACTIVE account is rate-limited —
# the catch-22 is that the endpoint refuses the usage reading precisely when the
# account is near/at its limit. Treat that 429 as a POSITIVE near-limit signal:
# persist a synthetic near-limit cache (at the AT-LIMIT mark, so it clears any
# reasonable rotation threshold) carrying the standard native-oauth-probe source
# marker so the existing monitor/rotation path consumes it and rotates the OAT
# proactively — instead of writing nothing and going blind. The marker fields
# below distinguish a 429-signal cache from a real reading for observability.
RATE_LIMIT_ERROR_TYPE = "rate_limit_error"
# The synthetic near-limit utilization. 100.0 == AT-LIMIT: >= any sane rotation
# threshold (default 99) without assuming the probe knows the operator's knob.
RATE_LIMIT_SIGNAL_PERCENT = 100.0
# Floor for the synthetic window when Retry-After is absent/unparseable: a
# 429 with no honored Retry-After still means "limited now" — anchor the window
# a conservative span out so the monitor has a stable reset_at to latch on.
RATE_LIMIT_SIGNAL_FALLBACK_WINDOW_SECONDS = 300
# Marker keys written into the cache + probe-state so a 429-signal is auditable
# and idempotent (see _signal_window_key / run_probe).
SIGNAL_MARKER = "rate_limit_429"

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
    text (token-free — it is the server's error JSON). ``headers`` carries the
    RESPONSE headers (token-free; the request Authorization header is never
    echoed back) so the caller can distinguish an anthropic-origin error
    (``request-id`` / ``anthropic-*`` present) from a CDN edge block
    (``Server: cloudflare``, no origin headers). ``None`` means the seam did
    not supply headers (legacy/back-compat callers) — classification then
    falls back to body-only semantics.
    """

    def __init__(
        self,
        status: int,
        body: str = "",
        retry_after: float | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(f"usage probe HTTP {status}")
        self.status = status
        self.body = body
        self.retry_after = retry_after
        self.headers = headers


def _parse_retry_after(value: str | None) -> float | None:
    # RFC 7231: Retry-After is EITHER a delta-seconds integer OR an HTTP-date.
    # The delta-seconds form is the common case; the HTTP-date form (e.g.
    # "Fri, 12 Jun 2026 06:46:49 GMT") must also be honored — converted to a
    # non-negative seconds-from-now — or a server-stated window sent as a date is
    # silently dropped (#1832 review finding; falls back to schedule backoff).
    if not value:
        return None
    value = value.strip()
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        seconds = None
    if seconds is not None:
        return seconds if seconds >= 0 else None
    # HTTP-date form.
    try:
        when = parsedate_to_datetime(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if when is None:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    delta = (when - datetime.now(timezone.utc)).total_seconds()
    return delta if delta >= 0 else 0.0


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
        # Carry the RESPONSE headers (token-free) so the error classifier can
        # tell an anthropic-origin error from a CDN edge block. Defensive: a
        # header iteration failure must never mask the original HTTP error.
        headers_map: dict[str, str] = {}
        try:
            if exc.headers is not None:
                headers_map = {str(k): str(v) for k, v in exc.headers.items()}
        except Exception:
            headers_map = {}
        raise ProbeHTTPError(
            exc.code, body=body, retry_after=retry_after, headers=headers_map
        ) from None


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


def map_payload_to_cache(payload: Any, token_digest: str = "") -> dict[str, Any] | None:
    """Map a raw ``api/oauth/usage`` response to the `.usage-cache.json` shape.

    Returns None when neither the five_hour nor the seven_day window carries
    a usable utilization — the likely cause is a token without the
    ``user:profile`` scope (the endpoint returns empty/null windows), NOT a
    genuine 0% usage. Returning None lets the caller degrade and log a scope
    hint rather than spuriously writing a 0% cache (which could mask a real
    rotation trigger).

    ``token_digest`` (optional) is the one-way SHA-256 prefix of the OAT that
    produced this reading (NO token bytes — same digest as
    ``_token_signal_digest``). Persisted as ``_token_digest`` so the freshness
    gate and the monitor can detect a cache attributed to a PREVIOUSLY-active
    token after a rotation (stale-attribution guard).
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

    cache: dict[str, Any] = {
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
    if token_digest:
        cache["_token_digest"] = token_digest
    return cache


# --------------------------------------------------------------------------- #
# Issue #1468 — usage-endpoint 429 as a POSITIVE near-limit rotation signal
# 429/403 3-way classification — account quota vs CDN edge block vs failure
# --------------------------------------------------------------------------- #
# A 429/403 served by the CDN EDGE (observed: ``Server: cloudflare`` and NO
# anthropic origin headers — no ``request-id``, no ``anthropic-*``; Retry-After
# pinned at exactly 3600; the same token flapping 403<->429 minute to minute
# while live sessions on the SAME account run fine) is an infrastructure block
# of the POLL, not evidence about the account's quota. Treating it as an
# account-quota signal fabricates a synthetic at-limit cache for an account
# that is NOT limited → usage-alert storms + rotation ping-pong. Classify it
# as ``edge-blocked`` instead: never write a synthetic cache, audit the
# outcome, and back off per-token (see record_token_cooldown) so the probe
# stops refreshing the edge ban window.
CLASSIFICATION_ACCOUNT_RATE_LIMIT = "account-rate-limit"
CLASSIFICATION_EDGE_BLOCKED = "edge-blocked"
CLASSIFICATION_FAILURE = "failure"
# Issue #2066 (v0.17 fallback oracle, P1a): a provider-side OUTAGE bucket,
# distinct from account-quota (429) / edge-block / generic failure. An outage
# is a server-side capacity/availability failure — a 5xx, Anthropic's 529
# "overloaded", or an `overloaded_error` body — NOT something the client did
# wrong (auth/quota/prompt). The provider-health oracle (bridge-provider-health.py)
# consumes this bucket to decide an Anthropic outage may be underway; nothing in
# the usage-probe rotation path acts on it (an outage classification falls
# through to the SAME degrade-serve-stale path a 5xx already took before this
# bucket existed — see run_probe — so adding it cannot regress rotation).
CLASSIFICATION_OUTAGE = "outage"
# The HTTP status family that signals a provider-side outage (vs a client error).
# 529 is Anthropic's documented "overloaded" status; 500/502/503/504 are the
# generic upstream-failure 5xx family. 429/403 are deliberately EXCLUDED — those
# are quota/edge and stay owned by the 3-way classify_probe_http_error logic.
OUTAGE_HTTP_STATUSES = frozenset({500, 502, 503, 504, 520, 521, 522, 523, 524, 529})
# Substrings in an error body that mark a provider overload even when the
# numeric status is ambiguous (e.g. a 200-wrapped JSON error envelope).
OUTAGE_BODY_MARKERS = ("overloaded_error", "overloaded")
# Probe result status emitted for an edge-blocked response (also the audit
# status string the wrapper records).
EDGE_BLOCKED_STATUS = "edge-blocked"
# Cap on the response body snippet carried into the result/audit detail.
ERROR_DETAIL_MAX_CHARS = 200


def _body_is_rate_limit_error(exc: "ProbeHTTPError") -> bool:
    """True when the error body parses to ``error.type == rate_limit_error``.

    An empty body is indistinguishable from a malformed / missing-UA reject —
    do NOT treat it as a rate-limit body.
    """
    body = exc.body or ""
    if not body.strip():
        return False
    try:
        payload = json.loads(body)
    except Exception:
        return False
    if not isinstance(payload, dict):
        return False
    error = payload.get("error")
    if not isinstance(error, dict):
        return False
    return str(error.get("type") or "") == RATE_LIMIT_ERROR_TYPE


def _normalized_error_headers(exc: "ProbeHTTPError") -> dict[str, str] | None:
    """Lower-cased response-header map from the exception, or None.

    None means the seam did not supply headers at all (a legacy caller built
    the exception without them) — the classifier then falls back to the
    pre-headers body-only behavior instead of guessing.
    """
    headers = getattr(exc, "headers", None)
    if headers is None:
        return None
    if not isinstance(headers, dict):
        return None
    return {str(k).lower(): str(v) for k, v in headers.items()}


def _has_anthropic_origin_headers(headers: dict[str, str]) -> bool:
    """True when the response demonstrably came from the anthropic origin.

    Origin responses carry ``request-id`` and/or ``anthropic-*`` headers; an
    edge block strips them (the edge answers before the request reaches the
    origin).
    """
    for key in headers:
        if key == "request-id" or key.startswith("anthropic-"):
            return True
    return False


# --------------------------------------------------------------------------- #
# Outage-class classification (#2066 P1a — shared by the provider-health oracle)
# --------------------------------------------------------------------------- #
# Text signatures that mark an OUTAGE-CLASS failure in free-form output — a cron
# child's stderr/stdout or a live pane's scrollback. Deliberately ALIGNED with
# bridge-stall.py's `network` group (econnreset / 502 / 503 / upstream connect /
# context deadline) PLUS the provider-overload markers (529 / overloaded_error).
# These are the failures that mean "the provider/server is unavailable", as
# opposed to auth/quota/prompt/local-fs failures which must NEVER be misread as
# an outage (that would falsely strand the fleet on the Codex fallback).
_OUTAGE_TEXT_PATTERNS = (
    r"\boverloaded_error\b",
    r"\boverloaded\b",
    r"\bhttp[/ ]?1\.[01]?\s*5\d\d\b",
    r"\b5\d\d\s+(?:internal server error|bad gateway|service unavailable|gateway time-?out)\b",
    r"\b502\s+bad gateway\b",
    r"\b503\s+service unavailable\b",
    r"\b504\s+gateway time-?out\b",
    r"\b529\b",
    r"\beconnreset\b",
    r"\beconnrefused\b",
    r"\bconnection\s+refused\b",
    r"\bconnection\s+reset\s+by\s+peer\b",
    r"\bconnection\s+aborted\b",
    r"\bcontext\s+deadline\s+exceeded\b",
    r"\bupstream\s+connect\s+error\b",
    r"\bupstream\s+request\s+timeout\b",
    # A timeout only classifies as outage when an explicit network/provider
    # subject word is adjacent — mirrors bridge-stall.py #161 narrowing so a
    # benign "(timeout 5m)" tool-budget hint never trips a false outage.
    r"\b(?:connection|request|socket|upstream|gateway|api|server|provider)\s+timed?\s*out\b",
)
_OUTAGE_TEXT_RE = re.compile("|".join(_OUTAGE_TEXT_PATTERNS), re.IGNORECASE)


def _http_status_is_outage(status: int) -> bool:
    """True for a server-side outage HTTP status (5xx family + 529)."""
    try:
        code = int(status)
    except (TypeError, ValueError):
        return False
    return code in OUTAGE_HTTP_STATUSES or (500 <= code <= 599)


def _body_marks_outage(body: str | None) -> bool:
    """True when a response body carries an `overloaded_error` / overload marker."""
    if not body:
        return False
    lowered = body.lower()
    return any(marker in lowered for marker in OUTAGE_BODY_MARKERS)


def classify_outage_class_text(text: str | None) -> bool:
    """True when free-form text (cron stderr/stdout or a live pane) signals an
    OUTAGE-class failure: a 5xx / 529 / overloaded / connection-reset/refused.

    Shared by the provider-health oracle's report paths (cron exit+stderr and
    live pane/stall text). Returns False for auth/quota/prompt/local errors so a
    bad-prompt or 401 is never misread as an Anthropic outage (#2066 §4).
    """
    if not text:
        return False
    return bool(_OUTAGE_TEXT_RE.search(text))


def classify_probe_http_error(exc: "ProbeHTTPError") -> str:
    """4-way classify a probe HTTP error: outage / account quota / edge / failure.

    - ``account-rate-limit``: a 429 whose body is the endpoint's
      ``error.type == rate_limit_error`` AND whose response headers prove the
      anthropic ORIGIN answered (``request-id`` / ``anthropic-*`` present).
      This is the genuine #1468 near-limit signal (synthetic cache path).
    - ``edge-blocked``: a 429/403 WITHOUT any anthropic origin header — the
      CDN edge answered before the request reached the origin. NOT an account
      signal; the caller must never fabricate a synthetic cache here.
      Note: ``Server: cloudflare`` alone is deliberately NOT the
      discriminator — GENUINE origin responses also transit Cloudflare and
      carry that header; the decisive edge evidence is the ABSENCE of the
      origin headers (field-observed: edge blocks carry ``Server:
      cloudflare`` and nothing else).
    - ``failure``: everything else (401, an origin-served 403, a 429 whose
      body is not a rate-limit error, ...) — the existing degrade path.

    Back-compat: when the exception carries NO header information at all
    (``headers is None`` — a legacy seam), fall back to the pre-headers
    body-only rule: a 429 ``rate_limit_error`` is an account signal.

    Issue #2066 (P1a): a provider-side OUTAGE (5xx / 529 / ``overloaded_error``)
    classifies as ``CLASSIFICATION_OUTAGE`` BEFORE the 429/403 logic. This is the
    only behavior change to this function — and it is safe for the usage-probe
    rotation path: an outage status formerly returned ``CLASSIFICATION_FAILURE``
    and fell through to the degrade-serve-stale arm in run_probe, which is
    exactly where ``CLASSIFICATION_OUTAGE`` also falls through (run_probe only
    special-cases ACCOUNT_RATE_LIMIT and EDGE_BLOCKED). The 429/403 quota/edge
    discrimination below is untouched.
    """
    if _http_status_is_outage(exc.status) or _body_marks_outage(exc.body):
        return CLASSIFICATION_OUTAGE
    if exc.status not in (429, 403):
        return CLASSIFICATION_FAILURE
    headers = _normalized_error_headers(exc)
    if headers is None:
        if exc.status == 429 and _body_is_rate_limit_error(exc):
            return CLASSIFICATION_ACCOUNT_RATE_LIMIT
        return CLASSIFICATION_FAILURE
    anthropic_origin = _has_anthropic_origin_headers(headers)
    if anthropic_origin and exc.status == 429 and _body_is_rate_limit_error(exc):
        return CLASSIFICATION_ACCOUNT_RATE_LIMIT
    if not anthropic_origin:
        return CLASSIFICATION_EDGE_BLOCKED
    return CLASSIFICATION_FAILURE


def is_rate_limit_429(exc: "ProbeHTTPError") -> bool:
    """True only for a GENUINE account rate-limit 429 we act on as near-limit.

    We always send the mandatory User-Agent, so a 429 whose body is the
    endpoint's ``error.type == rate_limit_error`` AND whose headers prove the
    anthropic origin answered is a real rate-limit (the account is near/at its
    limit). A 401, a 429 with a non-rate-limit body, a body we cannot parse,
    or a CDN edge block (see classify_probe_http_error) is NOT a rotation
    signal, so this returns False there and the caller degrades / serves stale.
    """
    return classify_probe_http_error(exc) == CLASSIFICATION_ACCOUNT_RATE_LIMIT


def _token_signal_digest(token: str) -> str:
    """Token-free, one-way digest used ONLY to dedupe the 429-signal per token.

    A SHA-256 hex prefix — irreversible and carrying NO token material (unlike
    bridge-auth's fingerprint, which appends the last 4 chars). Persisted into
    the probe-state sidecar so we never write token bytes to disk.
    """
    if not token:
        return ""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]


def _signal_reset_at(retry_after: float | None, now: float) -> str:
    """Derive the synthetic window ``reset_at`` from a 429 Retry-After.

    Quantized to whole seconds (drop sub-second jitter) so the SAME limit window
    yields a STABLE reset_at across ticks — the monitor's reset-cycle latch
    (RESET_FORWARD_GRACE_SECONDS) must not see per-tick drift as a new cycle and
    re-fire rotation. Absent/unparseable Retry-After falls back to a conservative
    fixed span (still "limited now").
    """
    span = retry_after if (retry_after is not None and retry_after >= 0) else None
    if span is None:
        span = float(RATE_LIMIT_SIGNAL_FALLBACK_WINDOW_SECONDS)
    reset_epoch = int(now) + int(span)
    return datetime.fromtimestamp(reset_epoch, tz=timezone.utc).isoformat()


def build_rate_limit_signal_cache(reset_at: str, token_digest: str = "") -> dict[str, Any]:
    """Build the synthetic near-limit ``.usage-cache.json`` for a 429 signal.

    Matches the EXACT shape the monitor consumes (``data.fiveHour`` etc., 0–100)
    with ``_source == native-oauth-probe`` so the existing rotation path latches
    it — plus ``_signal`` markers so this is auditable as a 429-derived signal
    (not a real reading). The five-hour window carries the AT-LIMIT mark; the
    seven-day window mirrors it (we have no granular split from a 429, and the
    monitor rotates on either window crossing the threshold).

    ``_signal_token`` carries the one-way digest of the OAT that 429'd (token-
    FREE — a SHA-256 prefix, NO token bytes). The monitor uses it to rotate ONCE
    PER newly-active token even when a counting-down Retry-After lands two tokens
    on the same reset_at (#1468 codex r3). The probe's per-token suppression
    bounds it to one signal per token per incident, so this cannot loop.
    """
    return {
        "data": {
            "planName": "subscription",
            "fiveHour": RATE_LIMIT_SIGNAL_PERCENT,
            "sevenDay": RATE_LIMIT_SIGNAL_PERCENT,
            "fiveHourResetAt": reset_at,
            "sevenDayResetAt": reset_at,
        },
        "_source": CACHE_SOURCE,
        "_signal": SIGNAL_MARKER,
        "_signal_token": token_digest,
        # Uniform attribution field (mirrors _signal_token): lets the
        # freshness gate + monitor stale-check read ONE field for both real
        # readings and 429-signal caches.
        "_token_digest": token_digest,
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
# The statusLine tap (scripts/hud-usage-tap.py) writes the SAME cache shape
# with this source marker. A tap reading is a REAL measurement straight from
# Claude Code's own rate_limits stdin — strictly better data than a probe of
# the (rate-limited, edge-blockable) usage endpoint. A FRESH tap cache (age <
# max_age, i.e. a statusLine is live RIGHT NOW) therefore satisfies the probe's
# freshness gate so the probe never overwrites live tap data. The headless
# concern the original guard targeted (a tap cache from a PREVIOUS statusLine
# run suppressing the probe forever) is handled by the age gate: a leftover
# tap cache goes stale within max_age and the probe takes over.
TAP_CACHE_SOURCE = "stdin-tap"
FRESH_CACHE_SOURCES = (CACHE_SOURCE, TAP_CACHE_SOURCE)


def cache_is_fresh(
    cache_path: Path,
    max_age_seconds: float,
    now: float,
    active_token_digest: str = "",
) -> bool:
    """True when a bridge-sourced cache exists and is younger than max_age.

    Only a cache written by the native probe (``_source == native-oauth-probe``)
    or by the live statusLine tap (``_source == stdin-tap``) counts toward
    freshness — any other/foreign cache never suppresses the probe.

    ``active_token_digest`` (optional): when the cache carries a token
    attribution (``_token_digest`` / ``_signal_token``) that does NOT match the
    currently-active token, the cache is STALE regardless of age — a token
    rotated in moments ago must not inherit the previous token's reading
    (especially a synthetic near-limit signal, which would instantly re-rotate
    the fresh token: the rotation ping-pong bug). Tap caches carry no digest
    and are unaffected.

    Freshness is judged by CONTENT age (the payload's ``_written_at`` stamp),
    NOT the file mtime. The statusLine tap (hud-usage-tap.py) stamps
    ``_written_at`` only when it writes a REAL rate_limits measurement, but the
    cache file's mtime can be touched far more often (re-renders, re-reads),
    so an mtime-first gate trusts a body that is hours/days stale and PERMANENTLY
    suppresses the native probe — the #20832 sean-mac live bug: a 9h-old (and a
    16-day-old) ``stdin-tap`` body with a fresh mtime blocked rotation-on-cap, so
    the active token hard-capped with no proactive rotation. ``_written_at`` is
    the authoritative content-freshness signal; mtime is only a fallback for a
    legacy cache that predates the stamp (missing / unparseable).
    """
    try:
        st = cache_path.stat()
    except OSError:
        return False
    try:
        payload = json.loads(cache_path.read_text(encoding="utf-8"))
    except Exception:
        return False
    if not isinstance(payload, dict):
        return False
    if payload.get("_source") not in FRESH_CACHE_SOURCES:
        return False
    # Content age from `_written_at` (authoritative); fall back to the file
    # mtime ONLY when the stamp is missing/unparseable (legacy caches).
    age: float | None = None
    written_at = payload.get("_written_at")
    if isinstance(written_at, str) and written_at:
        try:
            written_dt = datetime.fromisoformat(written_at.replace("Z", "+00:00"))
            if written_dt.tzinfo is None:
                written_dt = written_dt.replace(tzinfo=timezone.utc)
            age = now - written_dt.timestamp()
        except Exception:
            age = None
    if age is None:
        age = now - st.st_mtime
    # A future-dated stamp (age < 0) means clock skew or a synthetic clock —
    # do NOT treat it as fresh (better to re-probe than to trust a cache we
    # cannot age). Anything older than max_age is stale.
    if age < 0 or age >= max_age_seconds:
        return False
    if active_token_digest:
        cache_digest = payload.get("_token_digest") or payload.get("_signal_token")
        if (
            isinstance(cache_digest, str)
            and cache_digest
            and cache_digest != active_token_digest
        ):
            return False
    return True


def _probe_state_path(cache_path: Path) -> Path:
    return cache_path.parent / PROBE_STATE_BASENAME


def _read_probe_state(cache_path: Path) -> dict[str, Any]:
    """Read the whole probe-state sidecar dict (token-free); {} on any error."""
    try:
        payload = json.loads(_probe_state_path(cache_path).read_text(encoding="utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def _record_attempt(cache_path: Path, now: float, outcome: str) -> None:
    """Persist the last-attempt epoch (success or failure) for observability.

    Token-free: stores only an epoch + a coarse outcome string. The 429-signal
    idempotence block (``signal_429``, see _read_signal_state) and the
    per-token cooldown map (``token_cooldowns``) are PRESERVED across attempts
    so a success/failure does not erase the per-window dedupe or another
    token's backoff — a successful probe on the NEW token after rotation
    clears its own entries explicitly, not as a side effect of recording the
    attempt.
    """
    state = _read_probe_state(cache_path)
    state["last_attempt_epoch"] = now
    state["outcome"] = outcome
    try:
        _atomic_write_json(_probe_state_path(cache_path), state)
    except Exception:
        pass


# --------------------------------------------------------------------------- #
# Per-token cooldown / exponential backoff (token-free, on the sidecar)
# --------------------------------------------------------------------------- #
# State shape: ``token_cooldowns: {<token_digest>: {until, streak, outcome}}``.
# The old FIXED last-attempt cooldown re-probed every (cooldown + max_age)
# ≈ 6 minutes regardless of what the server said — inside a CDN edge ban
# window that cadence permanently RENEWS the ban (every strike restarts the
# Retry-After=3600 clock). The replacement is per-token:
#   - edge-blocked / rate-limited responses honor min(Retry-After, cap) AND an
#     exponential consecutive-failure backoff (5min → 15min → 60min cap),
#     whichever is LONGER, so the probe goes quiet for the whole ban window;
#   - generic failures keep the operator's fixed cooldown knob
#     (BRIDGE_USAGE_PROBE_COOLDOWN, default 60s) as before;
#   - the map is keyed by the one-way token digest, so a freshly rotated-in
#     token has NO entry and probes immediately (rotation stays responsive).
TOKEN_COOLDOWN_STATE_KEY = "token_cooldowns"
EDGE_BACKOFF_SCHEDULE_SECONDS = (300.0, 900.0, 3600.0)  # 5min → 15min → 60min cap
EDGE_RETRY_AFTER_CAP_SECONDS = 3600.0
# Entries whose cooldown elapsed more than this long ago are pruned on write
# (bounds the map to the recent pool; an entry inside the grace keeps its
# streak so consecutive edge failures escalate across elapsed cooldowns).
COOLDOWN_PRUNE_GRACE_SECONDS = 7200.0


def _token_cooldowns(cache_path: Path) -> dict[str, Any]:
    block = _read_probe_state(cache_path).get(TOKEN_COOLDOWN_STATE_KEY)
    return block if isinstance(block, dict) else {}


def token_cooldown_until(cache_path: Path, token_digest: str) -> float:
    """Epoch until which THIS token's probing is paused; 0.0 when none."""
    entry = _token_cooldowns(cache_path).get(token_digest)
    if not isinstance(entry, dict):
        return 0.0
    try:
        return float(entry.get("until"))
    except (TypeError, ValueError):
        return 0.0


def token_in_cooldown(cache_path: Path, token_digest: str, now: float) -> bool:
    if not token_digest:
        return False
    return now < token_cooldown_until(cache_path, token_digest)


def record_token_cooldown(
    cache_path: Path,
    token_digest: str,
    now: float,
    *,
    outcome: str,
    retry_after: float | None = None,
    base_seconds: float = 0.0,
    escalate: bool = False,
) -> float:
    """Record a cooldown window for THIS token; returns the applied span.

    ``escalate=True`` (edge-blocked / limited responses) bumps the token's
    consecutive-failure streak and applies
    ``max(backoff_schedule[streak], min(Retry-After, cap))`` so a server-stated
    ban window is honored in full and repeat offenders back off exponentially.
    ``escalate=False`` (generic failures) applies the fixed ``base_seconds``
    without touching the streak. Token-free: only the one-way digest is keyed.
    """
    if not token_digest:
        return 0.0
    state = _read_probe_state(cache_path)
    raw = state.get(TOKEN_COOLDOWN_STATE_KEY)
    cooldowns: dict[str, Any] = dict(raw) if isinstance(raw, dict) else {}
    # Prune entries long past their window (keeps the map ≤ recent pool size).
    pruned: dict[str, Any] = {}
    for digest, entry in cooldowns.items():
        if not isinstance(entry, dict):
            continue
        try:
            until = float(entry.get("until"))
        except (TypeError, ValueError):
            continue
        if (now - until) > COOLDOWN_PRUNE_GRACE_SECONDS:
            continue
        pruned[digest] = entry
    cooldowns = pruned
    prev = cooldowns.get(token_digest)
    streak = 0
    if isinstance(prev, dict):
        try:
            streak = max(int(prev.get("streak") or 0), 0)
        except (TypeError, ValueError):
            streak = 0
    if escalate:
        streak += 1
        backoff = EDGE_BACKOFF_SCHEDULE_SECONDS[
            min(streak, len(EDGE_BACKOFF_SCHEDULE_SECONDS)) - 1
        ]
        capped_retry = 0.0
        if retry_after is not None and retry_after > 0:
            capped_retry = min(float(retry_after), EDGE_RETRY_AFTER_CAP_SECONDS)
        span = max(backoff, capped_retry)
    else:
        span = max(float(base_seconds or 0.0), 0.0)
    cooldowns[token_digest] = {"until": now + span, "streak": streak, "outcome": outcome}
    state[TOKEN_COOLDOWN_STATE_KEY] = cooldowns
    try:
        _atomic_write_json(_probe_state_path(cache_path), state)
    except Exception:
        pass
    return span


def clear_token_cooldown(cache_path: Path, token_digest: str) -> None:
    """Drop THIS token's cooldown entry (called after a clean reading)."""
    if not token_digest:
        return
    state = _read_probe_state(cache_path)
    cooldowns = state.get(TOKEN_COOLDOWN_STATE_KEY)
    if isinstance(cooldowns, dict) and token_digest in cooldowns:
        cooldowns.pop(token_digest, None)
        state[TOKEN_COOLDOWN_STATE_KEY] = cooldowns
        try:
            _atomic_write_json(_probe_state_path(cache_path), state)
        except Exception:
            pass


# --------------------------------------------------------------------------- #
# Issue #1468 — PER-TOKEN 429-signal idempotence (token-free, on the sidecar)
# --------------------------------------------------------------------------- #
# State shape: ``signal_429: {"windows": {<token_digest>: <reset_at_iso>}}``.
# One window per ENABLED token (keyed by its one-way digest). This is the design
# that satisfies BOTH halves of the #1468 over-rotation contract simultaneously
# (codex r1+r2):
#   - Each DISTINCT token that 429s anchors ITS OWN window once, so the monitor
#     (which rotates when a window's reset_at advances) rotates ONCE PER NEW
#     token — the daemon can walk A→B→C until it lands on a non-limited token.
#   - The SAME token re-signalling (its window still in the future) is SUPPRESSED
#     — including under a CONSTANT Retry-After where `now + Retry-After` would
#     otherwise drift forward (codex r1). So a token rotates at most once per
#     incident, and looping back to an already-signalled token stops (codex r2).
# Elapsed windows are pruned on every write, so a genuinely NEW incident
# re-signals each token once. A clean reading clears the whole block.
def _read_signal_state(cache_path: Path) -> dict[str, Any]:
    block = _read_probe_state(cache_path).get("signal_429")
    return block if isinstance(block, dict) else {}


def _signal_windows(cache_path: Path) -> dict[str, str]:
    block = _read_signal_state(cache_path)
    windows = block.get("windows")
    if not isinstance(windows, dict):
        return {}
    return {str(k): str(v) for k, v in windows.items() if isinstance(v, str)}


def _reset_in_future(reset_at: str, now: float) -> bool:
    try:
        reset_dt = datetime.fromisoformat(reset_at)
    except Exception:
        return False
    now_dt = datetime.fromtimestamp(now, tz=timezone.utc)
    return reset_dt > now_dt


def signal_already_emitted(cache_path: Path, token_digest: str, now: float) -> bool:
    """True when THIS token already has a still-future 429-signal window.

    The loop-stopper (#1468 over-rotation guard). A token whose recorded window
    is still in the FUTURE has already been signalled for the current incident
    and must NOT re-emit a fresh near-limit cache (which would re-trip the
    monitor). This bounds each token to one signal per incident — and once the
    pool loops back to an already-signalled token it is suppressed, so the pool
    is traversed at most once. An ELAPSED window (or none) is not a current
    signal → returns False so a new incident re-signals.
    """
    win = _signal_windows(cache_path).get(token_digest)
    if not win:
        return False
    return _reset_in_future(win, now)


def resolve_token_window(
    cache_path: Path, token_digest: str, retry_after: float | None, now: float
) -> str:
    """Resolve the STABLE per-token window reset_at for a 429-signal.

    If THIS token already has a recorded window still in the FUTURE, REUSE it —
    so a CONSTANT Retry-After (which would drift `now + Retry-After` forward each
    tick) cannot move this token's window and re-rotate it (codex r1). Otherwise
    anchor a FRESH window from the current Retry-After (a new incident for this
    token). A DISTINCT token has no recorded window (or an elapsed one) → it
    anchors its OWN window, so the monitor rotates once per new token.
    """
    win = _signal_windows(cache_path).get(token_digest)
    if win and _reset_in_future(win, now):
        return win
    return _signal_reset_at(retry_after, now)


def record_signal_emitted(
    cache_path: Path, token_digest: str, reset_at: str, now: float
) -> None:
    """Record this token's 429-signal window; prune elapsed windows.

    Token-free: persists only the one-way digest → reset_at map. Pruning every
    elapsed window on write keeps the map bounded (≤ pool size) and lets a
    genuinely new incident (all prior windows elapsed) re-signal each token once.
    """
    state = _read_probe_state(cache_path)
    windows = _signal_windows(cache_path)
    # Prune windows whose reset has already passed (stale incidents).
    windows = {d: r for d, r in windows.items() if _reset_in_future(r, now)}
    if token_digest:
        windows[token_digest] = reset_at
    state["signal_429"] = {"windows": windows, "last_signal_epoch": now}
    try:
        _atomic_write_json(_probe_state_path(cache_path), state)
    except Exception:
        pass


def _clear_signal_state(cache_path: Path) -> None:
    """Drop the 429-signal dedupe block (called after a clean usage reading).

    A normal reading on the active token means it is NOT limited, so its window
    no longer applies. We clear the whole block — a clean reading is strong
    evidence the incident is over for the active account. Best-effort; never
    raises.
    """
    state = _read_probe_state(cache_path)
    if "signal_429" in state:
        state.pop("signal_429", None)
        try:
            _atomic_write_json(_probe_state_path(cache_path), state)
        except Exception:
            pass


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

    Returns a token-free result dict describing what happened (``status`` ∈
    fresh/written/cooldown/degraded/no-token/scope-degraded/rate-limited-signal/
    rate-limited-suppressed/edge-blocked). NEVER raises into the caller — every
    failure path degrades and returns. The existing cache is only ever REPLACED
    on a successful, parseable probe OR a genuine 429 near-limit signal (#1468);
    any other failure — including a CDN edge block — leaves whatever cache is
    on disk untouched (serve stale).
    """
    now = time.time() if now is None else now

    def _log(msg: str) -> None:
        if log is not None:
            log(msg)

    # 0. Token (read-only; never logged). Resolved BEFORE the freshness gate so
    #    the gate can compare the cache's token attribution against the
    #    CURRENTLY-active token — a cache written for a previously-active token
    #    is stale regardless of age (rotation ping-pong guard).
    token = resolve_active_token(
        registry_path, credentials_path, token_file,
        token_fd=token_fd, allow_env=allow_env,
    )
    active_digest = _token_signal_digest(token) if token else ""

    # 1. Freshness gate — within CACHE_MAX_AGE (and attributed to the active
    #    token, when attributable), do NOT re-probe. A fresh statusLine-tap
    #    cache also satisfies this gate: live tap data is a real measurement
    #    and the probe must not overwrite it.
    if cache_is_fresh(cache_path, max_age_seconds, now, active_token_digest=active_digest):
        return {"status": "fresh", "cache_path": str(cache_path)}

    # 2. Per-token cooldown gate — a recent failure for THIS token means serve
    #    stale, don't hammer (and never keep refreshing a CDN edge ban window).
    #    A freshly rotated-in token has no entry and probes immediately.
    if token and token_in_cooldown(cache_path, active_digest, now):
        # An account-quota 429 now arms the SAME backoff window as an edge block
        # (escalate=True, Retry-After-bounded). The very next daemon tick lands
        # inside that window, so this gate — not the rate-limit branch below —
        # is what suppresses the re-emit for an already-signalled token. When a
        # still-future 429 signal window exists for THIS token, report the #1468
        # suppression contract (status + the stable window reset_at) so the
        # over-rotation guard is observably unchanged; otherwise this is a plain
        # edge/failure cooldown.
        if signal_already_emitted(cache_path, active_digest, now):
            _log("[usage-probe] active token in cooldown with a live near-limit signal window; suppressing re-emit, serving stale")
            return {
                "status": "rate-limited-suppressed",
                "cache_path": str(cache_path),
                "reset_at": _signal_windows(cache_path).get(active_digest, ""),
                "cooldown_until": token_cooldown_until(cache_path, active_digest),
            }
        _log("[usage-probe] active token in cooldown after recent failure; serving stale cache")
        return {
            "status": "cooldown",
            "cache_path": str(cache_path),
            "cooldown_until": token_cooldown_until(cache_path, active_digest),
        }

    # 3. No token → degrade.
    if not token:
        _log("[usage-probe] no active OAT available; native probe degraded")
        return {"status": "no-token", "cache_path": str(cache_path)}

    headers = _build_headers(token, user_agent_version)

    # 4. Probe with a single Retry-After-bounded retry on 429. We retain the
    # last HTTPError so the #1468 429-signal path can inspect it after the
    # bounded retry has been exhausted.
    body: str | None = None
    last_http_error: ProbeHTTPError | None = None
    try:
        body = http_get(USAGE_ENDPOINT, headers, http_timeout)
    except ProbeHTTPError as exc:
        last_http_error = exc
        if exc.status == 429:
            wait = exc.retry_after
            if wait is not None and 0 <= wait <= retry_after_cap:
                _log(f"[usage-probe] 429; honoring Retry-After={wait:g}s (single retry)")
                time.sleep(wait)
                try:
                    body = http_get(USAGE_ENDPOINT, headers, http_timeout)
                    last_http_error = None
                except ProbeHTTPError as exc2:
                    last_http_error = exc2
                    body = None
                except Exception:
                    body = None
            else:
                _log("[usage-probe] 429; Retry-After absent/too-long")
        else:
            _log(f"[usage-probe] HTTP {exc.status}; serving stale cache")
    except Exception:
        # Transport error / timeout / unexpected — degrade silently (no token
        # could be in this message, but we don't echo it either).
        _log("[usage-probe] probe request failed; serving stale cache")
        body = None

    if body is None:
        classification = (
            classify_probe_http_error(last_http_error)
            if last_http_error is not None
            else CLASSIFICATION_FAILURE
        )
        # #1468: a GENUINE rate_limit 429 (valid request, UA present, anthropic
        # origin headers) is a POSITIVE near-limit signal — the catch-22 break.
        # Persist a synthetic near-limit cache so proactive rotation fires,
        # instead of going blind. Idempotent per (active-token, window): rotate
        # AT MOST once per token per limit window (no pool-loop). A CDN edge
        # block, a non-rate-limit 429, a 401, or a transport error is NOT a
        # rotation signal — handled below.
        if classification == CLASSIFICATION_ACCOUNT_RATE_LIMIT:
            token_digest = active_digest
            # The account told us it is limited — back off THIS token on the SAME
            # window contract as an edge block (300/900/3600 escalation + the
            # server-stated Retry-After up to the cap). An account-quota 429 means
            # the token is unusable for the reset window; honoring only the fixed
            # base_seconds cooldown would let the probe re-hammer a limited token
            # after the 5-minute cache-freshness window and leave measurement
            # thrash, so escalate the streak and respect Retry-After here too.
            record_token_cooldown(
                cache_path, token_digest, now,
                outcome="rate-limited",
                retry_after=last_http_error.retry_after,
                escalate=True,
            )
            # Suppress if THIS token already has a still-future signal window:
            # rotate this token at most once per incident, and stop on a pool
            # loop-back (codex r1+r2). A DISTINCT (rotated-to) token has no
            # still-future window → it falls through and signals once.
            if signal_already_emitted(cache_path, token_digest, now):
                _record_attempt(cache_path, now, "rate_limited")
                _log(
                    "[usage-probe] 429 rate_limit_error; this token already has a "
                    "live near-limit signal window — suppressing re-rotate"
                )
                return {
                    "status": "rate-limited-suppressed",
                    "cache_path": str(cache_path),
                    "retry_after": last_http_error.retry_after,
                    "reset_at": _signal_windows(cache_path).get(token_digest, ""),
                }
            # Resolve a STABLE per-token window (reuse this token's still-future
            # window so a constant Retry-After cannot drift it; otherwise anchor
            # fresh — a new token / new incident). #1468 idempotence.
            reset_at = resolve_token_window(
                cache_path, token_digest, last_http_error.retry_after, now
            )
            signal_cache = build_rate_limit_signal_cache(reset_at, token_digest)
            try:
                _atomic_write_json(cache_path, signal_cache)
            except Exception:
                _record_attempt(cache_path, now, "failure")
                _log("[usage-probe] 429 signal cache write failed; serving stale")
                return {"status": "degraded", "cache_path": str(cache_path)}
            record_signal_emitted(cache_path, token_digest, reset_at, now)
            _record_attempt(cache_path, now, "rate_limited")
            _log(
                "[usage-probe] 429 rate_limit_error on a valid request — the active "
                f"account is rate-limited; persisting a near-limit signal (reset_at={reset_at}) "
                "to trigger PROACTIVE rotation (#1468)"
            )
            return {
                "status": "rate-limited-signal",
                "cache_path": str(cache_path),
                "fiveHour": RATE_LIMIT_SIGNAL_PERCENT,
                "sevenDay": RATE_LIMIT_SIGNAL_PERCENT,
                "retry_after": last_http_error.retry_after,
                "reset_at": reset_at,
            }
        if classification == CLASSIFICATION_EDGE_BLOCKED:
            # The CDN edge blocked the POLL itself (Server: cloudflare / no
            # anthropic origin headers). This says NOTHING about the account's
            # quota: never fabricate a synthetic near-limit cache (that caused
            # usage-alert storms + rotation ping-pong while live sessions on
            # the same account ran fine). Back off per-token — honoring the
            # edge's Retry-After up to the cap, escalating on consecutive
            # blocks — so the probe stops refreshing the edge ban window.
            span = record_token_cooldown(
                cache_path, active_digest, now,
                outcome=EDGE_BLOCKED_STATUS,
                retry_after=last_http_error.retry_after,
                escalate=True,
            )
            _record_attempt(cache_path, now, "edge_blocked")
            _log(
                f"[usage-probe] HTTP {last_http_error.status} blocked at the CDN "
                "edge (no anthropic origin headers) — NOT an account-quota "
                f"signal; backing off {span:g}s for this token and serving stale"
            )
            return {
                "status": EDGE_BLOCKED_STATUS,
                "cache_path": str(cache_path),
                "http_status": last_http_error.status,
                "retry_after": last_http_error.retry_after,
                "cooldown_seconds": span,
                "detail": (last_http_error.body or "")[:ERROR_DETAIL_MAX_CHARS],
            }
        # Not a near-limit signal: a malformed/missing-UA 429, a 401, or a
        # transport error → probe FAILURE. Audited by the wrapper; serve stale.
        _record_attempt(cache_path, now, "failure")
        record_token_cooldown(
            cache_path, active_digest, now,
            outcome="failure", base_seconds=cooldown_seconds,
        )
        result: dict[str, Any] = {"status": "degraded", "cache_path": str(cache_path)}
        if last_http_error is not None:
            result["http_status"] = last_http_error.status
            result["detail"] = (last_http_error.body or "")[:ERROR_DETAIL_MAX_CHARS]
        return result

    # 5. Parse + map defensively.
    try:
        payload = json.loads(body)
    except Exception:
        _record_attempt(cache_path, now, "failure")
        record_token_cooldown(
            cache_path, active_digest, now,
            outcome="failure", base_seconds=cooldown_seconds,
        )
        _log("[usage-probe] response was not JSON; serving stale cache")
        return {"status": "degraded", "cache_path": str(cache_path)}

    cache = map_payload_to_cache(payload, token_digest=active_digest)
    if cache is None:
        # Likely a token without the user:profile scope (empty/null windows),
        # NOT a real outage. Degrade with a clear hint; do not write a 0% cache.
        _record_attempt(cache_path, now, "scope")
        record_token_cooldown(
            cache_path, active_digest, now,
            outcome="scope", base_seconds=cooldown_seconds,
        )
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
        record_token_cooldown(
            cache_path, active_digest, now,
            outcome="failure", base_seconds=cooldown_seconds,
        )
        _log("[usage-probe] cache write failed; serving stale cache")
        return {"status": "degraded", "cache_path": str(cache_path)}

    _record_attempt(cache_path, now, "success")
    # #1468: a clean reading means the active token is NOT limited → drop the
    # per-window 429-signal dedupe so a later genuine limit window can re-signal,
    # and clear this token's cooldown/backoff streak (it is healthy again).
    _clear_signal_state(cache_path)
    clear_token_cooldown(cache_path, active_digest)
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

    # Stale-attribution guard: print the token-FREE one-way digest (SHA-256
    # hex prefix — NO token bytes) of the rotation registry's ACTIVE token so
    # the wrapper can tell the monitor which token is current. Registry-only on
    # purpose: the rotation lane this guard protects only exists on registry
    # installs, and a registry-only read never touches env/credential sources.
    digest = sub.add_parser(
        "active-token-digest",
        help="print the one-way digest of the rotation registry's active OAT",
    )
    digest.add_argument("--registry-path", required=True)
    digest.set_defaults(handler=cmd_active_token_digest)

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


def cmd_active_token_digest(args: argparse.Namespace) -> int:
    """Print the one-way digest of the registry's active token (or nothing).

    The token itself is read in-process and NEVER printed/logged — only the
    SHA-256 hex prefix (the same digest persisted as ``_token_digest`` /
    ``_signal_token``) lands on stdout. Always exits 0 (best-effort: an absent
    or unreadable registry prints nothing and the caller skips the guard).
    """
    token = _read_active_token_from_registry(Path(args.registry_path).expanduser())
    if token:
        print(_token_signal_digest(token))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
