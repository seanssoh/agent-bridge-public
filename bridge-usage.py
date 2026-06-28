#!/usr/bin/env python3
"""bridge-usage.py - collect and monitor Claude/Codex usage windows.

Issue #831 — Claude usage caches live under each agent's own home in any
linux-user-isolated install. The monitor used to read the controller's
$HOME cache only, which on an isolated rig is empty. This module now
accepts ``--per-agent-cache-json <path>`` (an array built by
bridge-usage.sh from each agent's resolved cache path) and tags every
snapshot with ``agent_id``. The monitor's per-key latch is extended with
``agent`` so two agents sharing the same plan/account/window cannot mask
each other's rotation triggers.
"""

from __future__ import annotations

import argparse
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# #2171 PR-B3 Part 2: a one-way token digest is exactly 16 lowercase-hex chars
# (bridge-usage-probe.py `_token_signal_digest`). The cache's `_token_digest`
# field is operator-writable, so any value echoed into monitor output is
# validated against this shape first — a malformed / hand-edited cache must never
# leak arbitrary (or raw token) bytes through the cache-split diagnostic.
_TOKEN_DIGEST_RE = re.compile(r"\A[0-9a-f]{16}\Z")


def _safe_token_digest(value: Any) -> str:
    """Return a value only if it is a well-formed 16-char hex digest, else a fixed
    redaction marker (never the unvalidated value)."""
    return value if isinstance(value, str) and _TOKEN_DIGEST_RE.match(value) else "<non-digest>"


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def parse_iso(text: str | None) -> datetime | None:
    if not text:
        return None
    raw = text
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    return datetime.fromisoformat(raw)


def iso_from_epoch(epoch: Any) -> str | None:
    if epoch in (None, ""):
        return None
    try:
        value = int(epoch)
    except (TypeError, ValueError):
        return None
    return datetime.fromtimestamp(value, tz=timezone.utc).astimezone().isoformat(timespec="seconds")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def classify_health(
    used_percent: float | None,
    warn: float,
    critical: float,
    elevated: float | None = None,
) -> str:
    if used_percent is None:
        return "unknown"
    if used_percent >= critical:
        return "crit"
    if elevated is not None and used_percent >= elevated:
        return "elevated"
    if used_percent >= warn:
        return "warn"
    return "ok"


# Numeric ordering of alert buckets for latching. Higher rank = more severe.
# "unknown" is intentionally absent: unknown snapshots never fire alerts and
# never advance the high-water mark.
_BUCKET_RANK = {"ok": 0, "warn": 1, "elevated": 2, "crit": 3}


def bucket_rank(bucket: str | None) -> int:
    if not isinstance(bucket, str):
        return 0
    return _BUCKET_RANK.get(bucket, 0)


# Seconds of forward motion required before we treat a `reset_at` change as a
# genuine cycle rollover. Protects against upstream `resets_at` wobble that
# previously re-fired the same bucket's alert on every poll (see issue #215).
RESET_FORWARD_GRACE_SECONDS = 60


def reset_cycle_advanced(
    previous_reset: Any,
    current_reset: Any,
    grace_seconds: int = RESET_FORWARD_GRACE_SECONDS,
) -> bool:
    """Return True only when the reset window has moved forward by more than
    `grace_seconds`. Any other change — equal timestamps, backward drift,
    unparseable values — is treated as noise and does NOT clear the latch."""
    if previous_reset in (None, "") or current_reset in (None, ""):
        return False
    try:
        prev_dt = parse_iso(str(previous_reset))
        curr_dt = parse_iso(str(current_reset))
    except Exception:
        return False
    if prev_dt is None or curr_dt is None:
        return False
    return (curr_dt - prev_dt).total_seconds() > grace_seconds


def format_reset(reset_at: str | None) -> str:
    if not reset_at:
        return "unknown"
    try:
        reset_dt = parse_iso(reset_at)
    except Exception:
        return reset_at
    if reset_dt is None:
        return "unknown"
    delta = int((reset_dt - datetime.now(timezone.utc).astimezone()).total_seconds())
    if delta <= 0:
        return "resetting now"
    minutes = delta // 60
    hours, minutes = divmod(minutes, 60)
    if hours > 0:
        return f"in {hours}h {minutes}m"
    return f"in {minutes}m"


def normalize_window(name: str, minutes: Any) -> str:
    try:
        value = int(minutes)
    except (TypeError, ValueError):
        return name
    if value == 300:
        return "5h"
    if value == 10080:
        return "weekly"
    return f"{value}m"


def _claude_snapshots_from_payload(
    payload: Any,
    source: str,
    warn: float,
    critical: float,
    elevated: float | None,
    agent: str | None,
    active_token_digest: str | None = None,
) -> list[dict[str, Any]]:
    """Shared body for claude_snapshots() and the per-agent collector."""
    if not isinstance(payload, dict):
        return []
    data = payload.get("data") or payload.get("lastGoodData") or {}
    if not isinstance(data, dict):
        return []

    # Synthetic 429-signal marker (`_signal == rate_limit_429`): the cache is a
    # probe-fabricated near-limit SIGNAL, not a real reading. Carried into each
    # snapshot (``signal`` field) so the monitor can route it to the rotation
    # lane WITHOUT firing operator usage alerts (a synthetic 100% is a rotation
    # instruction, not a usage fact worth an alert storm).
    signal_marker = payload.get("_signal")
    signal_marker = (
        str(signal_marker) if isinstance(signal_marker, str) and signal_marker else None
    )

    # Stale-attribution guard: a SYNTHETIC signal cache attributed to a token
    # that is NO LONGER active is stale — after a rotation the freshly-active
    # token must not inherit the previous token's near-limit signal (that
    # re-trips the monitor and ping-pongs the pool). Real readings (no _signal)
    # are not dropped here. Fail-open: the guard only applies when BOTH the
    # cache attribution and the caller-supplied active digest are present.
    if signal_marker is not None and active_token_digest:
        payload_digest = payload.get("_token_digest") or payload.get("_signal_token")
        if (
            isinstance(payload_digest, str)
            and payload_digest
            and payload_digest != active_token_digest
        ):
            return []

    snapshots: list[dict[str, Any]] = []
    plan = data.get("planName") or "subscription"
    # Issue #1468: a native 429-signal cache carries `_signal_token` — the
    # one-way digest of the OAT that 429'd. It lets the rotation latch
    # distinguish one limited token's signal from the next so the daemon can
    # rotate ONCE PER newly-active token (walk A→B→C until a non-limited token)
    # even when a counting-down Retry-After lands two tokens on the SAME
    # reset_at. Absent on a real reading (None) → the latch keys on reset_at
    # only, exactly as before (no behavior change off the 429-signal path).
    signal_token = payload.get("_signal_token")
    signal_token = str(signal_token) if isinstance(signal_token, str) and signal_token else None
    # #17927 P2 (E10 Obs#1): the cache's self-reported write time. Carried into
    # each snapshot so cmd_monitor can suppress a stale reading from driving a
    # rotation decision (a stale cache = "no signal", never 0% usage). Absent on
    # a hand-seeded cache → the freshness gate fails open (treats as fresh).
    written_at = payload.get("_written_at")
    written_at = str(written_at) if isinstance(written_at, str) and written_at else None
    # #18849 Part 2: the one-way digest of the OAT this cache was written for (NO
    # token bytes). Carried onto every snapshot so cmd_monitor can extend the
    # parse-time stale-attribution guard above — which only drops synthetic
    # 429-signal caches — to REAL preemptive candidates: after an A->B rotation
    # the probe may still serve A's not-yet-expired cache, and A's >=threshold
    # reading must not re-rotate the freshly-active B (post-rotation ping-pong).
    # Absent on a hand-seeded / digest-less cache → the rotation guard fails open.
    token_digest = payload.get("_token_digest")
    token_digest = str(token_digest) if isinstance(token_digest, str) and token_digest else None
    windows = [
        ("5h", data.get("fiveHour"), data.get("fiveHourResetAt")),
        ("weekly", data.get("sevenDay"), data.get("sevenDayResetAt")),
    ]
    for window, used_percent, reset_at in windows:
        try:
            percent = float(used_percent)
        except (TypeError, ValueError):
            percent = None  # type: ignore[assignment]
        entry: dict[str, Any] = {
            "provider": "claude",
            "account": plan,
            "window": window,
            "used_percent": percent,
            "reset_at": reset_at,
            "health": classify_health(percent, warn, critical, elevated=elevated),
            "source": source,
        }
        if agent is not None:
            entry["agent"] = agent
        if signal_token is not None:
            entry["signal_token"] = signal_token
        if signal_marker is not None:
            entry["signal"] = signal_marker
        if written_at is not None:
            entry["written_at"] = written_at
        if token_digest is not None:
            entry["token_digest"] = token_digest
        snapshots.append(entry)
    return snapshots


def claude_snapshots(
    path: Path,
    warn: float,
    critical: float,
    elevated: float | None = None,
    active_token_digest: str | None = None,
) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    try:
        payload = load_json(path)
    except Exception:
        return []
    return _claude_snapshots_from_payload(
        payload, str(path), warn, critical, elevated, agent=None,
        active_token_digest=active_token_digest,
    )


def _per_agent_payload_is_present(per_agent_path: Path) -> bool:
    """Issue #831 r2 (review #2104 finding 1): treat per-agent mode as active
    as soon as the caller supplied a parseable list payload, even if every
    entry is `present=false` / unreadable. The earlier "fall through to
    controller cache when zero per-agent snapshots" path silently re-enabled
    the original #831 blind spot — caller's intent ("monitor THESE agents")
    must be honored even when none of them have data.
    """
    if not per_agent_path.is_file():
        return False
    try:
        entries = load_json(per_agent_path)
    except Exception:
        return False
    return isinstance(entries, list)


def claude_snapshots_per_agent(
    per_agent_path: Path,
    warn: float,
    critical: float,
    elevated: float | None = None,
    active_token_digest: str | None = None,
) -> list[dict[str, Any]]:
    """Issue #831: read the per-agent cache payload array (built by
    bridge-usage.sh) and emit one snapshot set per agent. Each snapshot is
    tagged with `agent` so the monitor latch key can include agent identity.
    """
    if not per_agent_path.is_file():
        return []
    try:
        entries = load_json(per_agent_path)
    except Exception:
        return []
    if not isinstance(entries, list):
        return []

    snapshots: list[dict[str, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        agent = str(entry.get("agent") or "").strip()
        if not agent:
            continue
        if not entry.get("present"):
            continue  # U3: agent's cache missing entirely → skip silently.
        payload = entry.get("payload")
        source = str(entry.get("path") or "")
        snapshots.extend(
            _claude_snapshots_from_payload(
                payload, source, warn, critical, elevated, agent=agent,
                active_token_digest=active_token_digest,
            )
        )
    return snapshots


def iter_codex_rate_limits(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return records
    for line in reversed(lines):
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        entry = payload.get("payload")
        if not isinstance(entry, dict):
            continue
        rate_limits = entry.get("rate_limits")
        if not isinstance(rate_limits, dict):
            continue
        record = dict(rate_limits)
        record["_source_file"] = str(path)
        record["_timestamp"] = payload.get("timestamp")
        records.append(record)
    return records


def codex_snapshots(
    root: Path,
    warn: float,
    critical: float,
    elevated: float | None = None,
) -> list[dict[str, Any]]:
    if not root.is_dir():
        return []

    files = sorted(root.rglob("*.jsonl"), reverse=True)
    latest: dict[str, dict[str, Any]] = {}
    for path in files[:200]:
        for record in iter_codex_rate_limits(path):
            limit_id = str(record.get("limit_id") or "codex")
            # The global codex window is the actionable subscription limit.
            if limit_id != "codex":
                continue
            if limit_id in latest:
                continue
            latest[limit_id] = record
        if "codex" in latest:
            break

    snapshots: list[dict[str, Any]] = []
    for limit_id, record in latest.items():
        for field_name, default_name in (("primary", "5h"), ("secondary", "weekly")):
            window_payload = record.get(field_name)
            if not isinstance(window_payload, dict):
                continue
            try:
                used_percent = float(window_payload.get("used_percent"))
            except (TypeError, ValueError):
                used_percent = None  # type: ignore[assignment]
            window_name = normalize_window(default_name, window_payload.get("window_minutes"))
            snapshots.append(
                {
                    "provider": "codex",
                    "account": limit_id,
                    "window": window_name,
                    "used_percent": used_percent,
                    "reset_at": iso_from_epoch(window_payload.get("resets_at")),
                    "health": classify_health(used_percent, warn, critical, elevated=elevated),
                    "source": record.get("_source_file"),
                }
            )
    return snapshots


# Issue #1437 PRIMARY: the native usage probe writes a controller-side cache
# tagged with this sentinel agent id so its snapshots latch on an independent
# key (provider::account::window::agent) and never collide with a real agent's
# per-agent latch. It is an ADDITIVE source — it represents the
# controller/non-isolated account's usage and must reach rotation even when
# per-agent (isolated) caches are present, without re-introducing the #831
# blind spot (isolated agents stay independently monitored).
NATIVE_PROBE_AGENT = "__native__"
NATIVE_PROBE_SOURCE = "native-oauth-probe"


def _cache_is_native_probe(path: Path) -> bool:
    """True only when the cache on disk was written BY the native probe.

    Codex r2 BLOCKING: the additive native source must consume ONLY a cache the
    native probe actually produced (``_source == native-oauth-probe``). A
    statusLine/stdin-tap cache (``_source == stdin-tap``) — or any other cache
    the probe left untouched after fail-opening — must NOT be read as the native
    source, otherwise it reintroduces the #831 legacy-controller fallback through
    the new arg (a stale 99% stdin-tap cache would spuriously rotate even when
    every selected per-agent cache is present=false). Absent/unreadable/foreign
    caches return False so the additive source contributes nothing.
    """
    if not path.is_file():
        return False
    try:
        payload = load_json(path)
    except Exception:
        return False
    return isinstance(payload, dict) and payload.get("_source") == NATIVE_PROBE_SOURCE


def native_snapshots(
    path: Path,
    warn: float,
    critical: float,
    elevated: float | None = None,
    active_token_digest: str | None = None,
) -> list[dict[str, Any]]:
    """Read the native-probe controller cache and tag it as the native source.

    ONLY reads a cache whose ``_source == native-oauth-probe`` (see
    ``_cache_is_native_probe``) — a foreign/stale cache is ignored so the
    additive source cannot re-create the #831 legacy-controller fallback. On a
    match, reuses the standard cache parser and stamps ``agent=__native__`` /
    ``source=native-oauth-probe`` so the monitor latches it independently of any
    per-agent snapshot. Returns [] when the file is absent/unreadable/foreign.
    """
    if not _cache_is_native_probe(path):
        return []
    snaps = claude_snapshots(
        path, warn, critical, elevated=elevated,
        active_token_digest=active_token_digest,
    )
    for snap in snaps:
        snap["agent"] = NATIVE_PROBE_AGENT
        snap["source"] = NATIVE_PROBE_SOURCE
    return snaps


def collect_snapshots(args: argparse.Namespace) -> list[dict[str, Any]]:
    warn = float(args.warn_threshold)
    critical = float(args.critical_threshold)
    elevated = _parse_elevated(args, warn, critical)
    snapshots: list[dict[str, Any]] = []

    # Stale-attribution guard input: the one-way digest of the CURRENTLY-active
    # rotation-registry token (supplied by bridge-usage.sh on registry
    # installs). A synthetic 429-signal cache attributed to a DIFFERENT token
    # is dropped at parse time — see _claude_snapshots_from_payload.
    active_token_digest = getattr(args, "active_token_digest", None) or None

    # Issue #831: when --per-agent-cache-json is supplied, the caller is in
    # explicit per-agent mode. Per-agent mode latches on flag presence + a
    # parseable/list-shaped payload, NOT on snapshot count. If selected agents
    # all have present=false or unreadable caches, the correct answer is "no
    # signal from those agents" — NOT "fall back to controller cache" (which
    # would silently reintroduce the original #831 blind spot, where one
    # isolated agent's hidden rate-limit went un-rotated).
    #
    # The legacy single-controller path is only used when --per-agent-cache-json
    # is absent (true legacy invocation, e.g. an older operator script).
    per_agent_path_raw = getattr(args, "per_agent_cache_json", None)
    per_agent_mode_active = False
    per_agent_resolved_paths: set[str] = set()
    if per_agent_path_raw:
        per_agent_path = Path(per_agent_path_raw).expanduser()
        per_agent_mode_active = _per_agent_payload_is_present(per_agent_path)
        if per_agent_mode_active:
            per_agent_snaps = claude_snapshots_per_agent(
                per_agent_path, warn, critical, elevated=elevated,
                active_token_digest=active_token_digest,
            )
            snapshots.extend(per_agent_snaps)
            per_agent_resolved_paths = _per_agent_cache_paths(per_agent_path)

    if not per_agent_mode_active:
        # True legacy single-controller cache (back-compat). `--legacy-single-path`
        # is accepted as a synonym for `--claude-usage-cache` so the wrapper
        # can always pass both without disturbing existing semantics. In this
        # mode the legacy path already reads the controller cache the native
        # probe wrote, so #1437's native signal flows without extra wiring.
        legacy_raw = getattr(args, "legacy_single_path", None) or args.claude_usage_cache
        snapshots.extend(
            claude_snapshots(
                Path(legacy_raw).expanduser(), warn, critical, elevated=elevated,
                active_token_digest=active_token_digest,
            )
        )

    # Issue #1437 PRIMARY: in per-agent mode the controller/native cache is
    # otherwise suppressed (the #831 isolation guard). Read it ADDITIVELY here
    # as its own `__native__`-tagged source so a headless host's native probe
    # signal reaches rotation in the DEFAULT `--agents static` daemon path —
    # without weakening the #831 per-agent suppression (isolated agents are
    # still independently monitored above). Dedupe against any per-agent path
    # that already resolved to the same file (a non-isolated agent's cache IS
    # the controller cache), so we never double-count the same window.
    native_raw = getattr(args, "native_usage_cache", None)
    if per_agent_mode_active and native_raw:
        native_path = Path(native_raw).expanduser()
        if _resolve_str(native_path) not in per_agent_resolved_paths:
            snapshots.extend(
                native_snapshots(
                    native_path, warn, critical, elevated=elevated,
                    active_token_digest=active_token_digest,
                )
            )

    snapshots.extend(
        codex_snapshots(Path(args.codex_sessions_dir).expanduser(), warn, critical, elevated=elevated)
    )
    return snapshots


def _resolve_str(path: Path) -> str:
    """Best-effort absolute-path string for dedupe (does not require existence)."""
    try:
        return str(path.resolve())
    except Exception:
        return str(path)


def _per_agent_cache_paths(per_agent_path: Path) -> set[str]:
    """Resolved set of cache file paths the per-agent payload already consumed.

    Used by #1437 to avoid double-counting the controller cache when a
    non-isolated agent's resolved cache path IS the controller/native path.
    Only ``present`` entries count — an absent per-agent cache did not
    contribute a snapshot, so the native cache is not a duplicate of it.
    """
    paths: set[str] = set()
    try:
        entries = load_json(per_agent_path)
    except Exception:
        return paths
    if not isinstance(entries, list):
        return paths
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if not entry.get("present"):
            continue
        raw = entry.get("path")
        if isinstance(raw, str) and raw.strip():
            paths.add(_resolve_str(Path(raw).expanduser()))
    return paths


def _parse_elevated(args: argparse.Namespace, warn: float, critical: float) -> float:
    """Resolve the elevated threshold, defaulting to the midpoint of warn/critical
    if the caller did not supply one. Clamped to `warn < elevated < critical`
    so the three-tier ladder stays monotonic."""
    raw = getattr(args, "elevated_threshold", None)
    elevated = float(raw) if raw is not None else (warn + critical) / 2.0
    if elevated <= warn:
        elevated = warn + 1.0
    if elevated >= critical:
        elevated = critical - 1.0
    if elevated <= warn:
        # warn and critical collapsed (e.g. warn=99, critical=100); fall back to
        # disabling the middle tier by setting elevated > critical so it never fires.
        elevated = critical + 1.0
    return elevated


def bucket_for_snapshot(
    snapshot: dict[str, Any],
    warn: float,
    critical: float,
    elevated: float | None = None,
) -> str:
    used_percent = snapshot.get("used_percent")
    if not isinstance(used_percent, (int, float)):
        return "unknown"
    if used_percent >= critical:
        return "crit"
    if elevated is not None and used_percent >= elevated:
        return "elevated"
    if used_percent >= warn:
        return "warn"
    return "ok"


def alert_message(snapshot: dict[str, Any], bucket: str) -> str:
    provider = str(snapshot.get("provider", "")).capitalize()
    window = snapshot.get("window") or "unknown"
    used_percent = snapshot.get("used_percent")
    reset_at = snapshot.get("reset_at")
    if isinstance(used_percent, (int, float)):
        percent_text = f"{used_percent:.0f}%"
    else:
        percent_text = "unknown"
    level = {
        "crit": "critical",
        "elevated": "elevated",
        "warn": "warning",
    }.get(bucket, "warning")
    return (
        f"{provider} usage {level}: {window} window at {percent_text}, "
        f"resets {format_reset(reset_at)}. Consider switching the active subscription account."
    )


def load_monitor_state(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {"entries": {}}
    try:
        payload = load_json(path)
    except Exception:
        return {"entries": {}}
    if not isinstance(payload, dict):
        return {"entries": {}}
    entries = payload.get("entries")
    if not isinstance(entries, dict):
        payload["entries"] = {}
    return payload


def save_monitor_state(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def cmd_status(args: argparse.Namespace) -> int:
    snapshots = collect_snapshots(args)
    # #18849 Part 2: `token_digest` is an internal rotation-attribution gate input
    # only (consumed by cmd_monitor); never surface it in the status output.
    for snapshot in snapshots:
        snapshot.pop("token_digest", None)
    result = {"generated_at": now_iso(), "snapshots": snapshots}
    if args.json:
        print(json.dumps(result, ensure_ascii=True, indent=2))
        return 0
    for snapshot in snapshots:
        # Issue #831: include agent column so isolated-per-agent runs are
        # legible in tab output. Empty for legacy controller-cache rows.
        print(
            "\t".join(
                [
                    str(snapshot.get("provider", "")),
                    str(snapshot.get("account", "")),
                    str(snapshot.get("window", "")),
                    str(snapshot.get("used_percent", "")),
                    str(snapshot.get("reset_at", "")),
                    str(snapshot.get("health", "")),
                    str(snapshot.get("source", "")),
                    str(snapshot.get("agent", "")),
                ]
            )
        )
    return 0


def _parse_rotation_eligible(args: argparse.Namespace) -> set[str] | None:
    """#17927 P2 (E6/E8): the rotation-eligible agent set, or None when ungated.

    None  → the flag was not passed (legacy / non-daemon caller): rotation is
            ungated, every candidate is eligible (pre-#17927 behavior).
    set   → the flag was passed (the daemon always passes it). Only agents in
            this set may DRIVE a rotation; an empty set means "no per-agent
            agent is eligible" (only the controller-managed sentinels rotate).
    """
    raw = getattr(args, "rotation_eligible_agents", None)
    if raw is None:
        return None
    return {a.strip() for a in str(raw).split(",") if a.strip()}


def _agent_rotation_eligible(snapshot_agent: str, eligible: set[str] | None) -> bool:
    """True when ``snapshot_agent`` may drive a managed-token rotation.

    ``eligible is None`` ⇒ ungated (legacy). Otherwise the controller-managed
    sentinels — the native-probe source (``__native__``) and the legacy
    empty-agent single-controller cache — are ALWAYS eligible (they represent
    the controller's own managed token, which IS the rotation target). A real
    per-agent id is eligible only when it is in the managed pool. statusLine
    caches carry no token/account identity, so a non-managed agent's high-usage
    reading must never re-point the managed pool (multi-account mis-attribution
    + the P3 global-login-respect invariant).
    """
    if eligible is None:
        return True
    if snapshot_agent == "" or snapshot_agent == NATIVE_PROBE_AGENT:
        return True
    return snapshot_agent in eligible


def _cache_is_fresh(
    written_at: str | None,
    max_age_seconds: float,
    now: datetime | None = None,
) -> bool:
    """#17927 P2 (E10 Obs#1): conservative staleness-guard.

    Returns True (fresh / usable) UNLESS ``written_at`` is present, parseable,
    and older than ``max_age_seconds``. A missing/unparseable timestamp fails
    OPEN (treated as fresh) so a hand-seeded cache or a future producer variant
    is never silently dropped — the gate only suppresses a reading when its
    staleness is PROVABLE. A non-positive ``max_age_seconds`` disables the gate.
    """
    if max_age_seconds <= 0:
        return True
    if not written_at:
        return True
    try:
        written_dt = parse_iso(written_at)
    except Exception:
        return True
    if written_dt is None:
        return True
    if now is None:
        now = datetime.now(timezone.utc)
    if written_dt.tzinfo is None:
        written_dt = written_dt.replace(tzinfo=timezone.utc)
    age = (now - written_dt).total_seconds()
    return age <= max_age_seconds


def cmd_monitor(args: argparse.Namespace) -> int:
    snapshots = collect_snapshots(args)
    state_path = Path(args.state_file).expanduser()
    state = load_monitor_state(state_path)
    entries = state.setdefault("entries", {})
    alerts: list[dict[str, Any]] = []
    rotation_candidates: list[dict[str, Any]] = []
    warn = float(args.warn_threshold)
    critical = float(args.critical_threshold)
    elevated = _parse_elevated(args, warn, critical)
    rotation_threshold = float(args.rotation_threshold)
    # 5h stays on the hard rotation threshold; the 7d window gets a lower
    # proactive threshold so the daemon can rotate or escalate before the
    # account hard-limits.
    weekly_warn_threshold = float(getattr(args, "weekly_warn_threshold", 95.0))
    # #17927 P2 (E6/E8) rotation-eligibility gate + (E10 Obs#1) staleness gate.
    rotation_eligible = _parse_rotation_eligible(args)
    cache_max_age_seconds = float(getattr(args, "cache_max_age_seconds", 21600) or 0)
    # #18849 Part 2: the one-way digest of the CURRENTLY-active rotation token
    # (supplied by bridge-usage.sh on registry installs). Used to drop a REAL
    # native-probe reading still attributed to a PREVIOUSLY-active token from the
    # rotation lane (post-rotation ping-pong guard). None/empty ⇒ ungated.
    active_token_digest = getattr(args, "active_token_digest", None) or None
    now_dt = datetime.now(timezone.utc)
    # Track the worst-case agent so the aggregate rotation row tells the
    # operator which agent triggered. Per #831 patch-dev r2 §4: a 99% on
    # agent-A must NOT be masked by a 60% on agent-B sharing the same plan.
    worst_case_agent: str | None = None
    worst_case_percent: float = -1.0
    # #2171 PR-B3 Part 2 (wrong-home cache-split diagnostic): a resolved claude
    # cache whose one-way `_token_digest` does NOT match the live active-token
    # digest is a cache the resolver read from the WRONG home (a different token's
    # reading), not a usable signal for the active token. The rotation lane already
    # treats it as no-signal (rotation_attribution_ok below); collect each such
    # mismatch here so the split is VISIBLE in the monitor output instead of
    # silently dropped. Digests only — never token bytes. No alternate-home search.
    cache_split_diagnostics: list[dict[str, Any]] = []

    for snapshot in snapshots:
        # Issue #831 patch-dev r2 §4: include agent identity in the latching
        # key. Two isolated agents on the same Claude plan/account/window must
        # have independent rotation_triggered_at state so one cannot mask the
        # other. Non-agent snapshots (codex, legacy controller cache) latch
        # with an empty agent field — order-independent and back-compat.
        snapshot_agent = str(snapshot.get("agent") or "")
        key = "::".join(
            [
                str(snapshot.get("provider", "")),
                str(snapshot.get("account", "")),
                str(snapshot.get("window", "")),
                snapshot_agent,
            ]
        )
        bucket = bucket_for_snapshot(snapshot, warn, critical, elevated=elevated)
        # Synthetic 429-signal snapshots (`signal` set by the cache parser) are
        # a ROTATION instruction, not a usage fact: route them to their own
        # `signal` bucket class so the operator-alert ladder below never fires
        # on them (a probe-fabricated 100% used to emit a full warn/elevated/
        # crit alert storm every tick) while the rotation-candidate lane —
        # which keys on used_percent, not bucket — still sees them. `signal`
        # is absent from _BUCKET_RANK (rank 0), so it can never out-rank a
        # latch, and it is neither "ok" nor "unknown", so it never clears or
        # advances the alert latch either.
        if snapshot.get("signal"):
            bucket = "signal"
        reset_at = snapshot.get("reset_at")
        used_percent = snapshot.get("used_percent")
        previous = entries.get(key, {}) if isinstance(entries.get(key), dict) else {}
        previous_reset = previous.get("reset_at")
        previous_latch = previous.get("last_alert_bucket")
        rotation_triggered_at = previous.get("rotation_triggered_at")
        rotation_triggered_reset_at = previous.get("rotation_triggered_reset_at")
        rotation_triggered_signal_token = previous.get("rotation_triggered_signal_token")
        # Issue #1468: identity of the OAT behind a native 429-signal snapshot
        # (token-free one-way digest). None on a real reading.
        signal_token = snapshot.get("signal_token")

        # #18849 Part 2: post-rotation stale-attribution for REAL readings. A
        # native-probe reading whose one-way `_token_digest` mismatches the live
        # --active-token-digest was written for a PREVIOUSLY-active token — a
        # leftover the probe is still serving after an A->B rotation. Folding it
        # into `cache_fresh` makes the reading INERT for the ENTIRE rotation lane:
        # it can neither emit a candidate NOR clear/advance the rotation latch (the
        # latch reset-cycle clear below is gated on cache_fresh). Mirrors the
        # parse-time signal guard EXACTLY — suppress only when BOTH digests are
        # present and differ; a 429-signal (its own guard), a digest-less cache, or
        # a registry-less install (no active digest) all fail open. The digest is
        # an internal gate input only (the daemon never consumes it, unlike
        # signal_token), so it is popped here and never reaches the candidate /
        # monitor JSON output.
        rotation_attribution_ok = True
        if active_token_digest and not snapshot.get("signal"):
            snap_digest = snapshot.get("token_digest")
            if isinstance(snap_digest, str) and snap_digest and snap_digest != active_token_digest:
                rotation_attribution_ok = False
                # #2171 PR-B3 Part 2: surface the wrong-home cache-split. This
                # reading stays inert for the rotation lane (folded into
                # cache_fresh below = no-signal, never read as 0% and never a
                # threshold crossing); the diagnostic only makes the mismatch
                # observable. Digests are one-way — safe to emit; no token bytes.
                cache_split_diagnostics.append(
                    {
                        "agent": snapshot_agent or "",
                        "provider": "claude",
                        "window": str(snapshot.get("window") or ""),
                        # One-way digests only (NO token bytes). Keys deliberately
                        # avoid the literal ``token_digest`` so the internal-gate
                        # strip contract (no ``token_digest`` field in the monitor
                        # envelope) is preserved. The cache value is operator-
                        # writable, so it is validated to a 16-char hex shape
                        # before emit — a malformed cache yields a redaction
                        # marker, never raw bytes.
                        "cache_digest": _safe_token_digest(snap_digest),
                        "active_digest": _safe_token_digest(active_token_digest),
                        "source": str(snapshot.get("source") or ""),
                        "reason": "wrong_home_cache_split",
                    }
                )
        snapshot.pop("token_digest", None)

        # #17927 P2 (E10 Obs#1): freshness of THIS reading, computed BEFORE any
        # reset-cycle latch mutation. A 429-signal (#1468) is a live rotation
        # instruction and a non-claude provider has no statusLine cache, so both
        # count as fresh; a claude REAL reading is fresh only when its cache
        # `written_at` is within the max-age window AND it is attributed to the
        # active token (#18849). Reused by the claude rotation staleness-guard below.
        cache_fresh = (
            snapshot.get("provider") != "claude"
            or bool(snapshot.get("signal"))
            or (
                _cache_is_fresh(snapshot.get("written_at"), cache_max_age_seconds, now=now_dt)
                and rotation_attribution_ok
            )
        )

        # Cycle rollover: if reset_at has moved forward by more than the grace
        # window, this is a new cycle — clear the latch so alerts can fire again.
        # Equal or wobbling reset_at values are intentionally treated as noise
        # (see RESET_FORWARD_GRACE_SECONDS). This was the #215 noise source.
        if reset_cycle_advanced(previous_reset, reset_at):
            previous_latch = None
        # #17927 P2 (E10 Obs#1 — codex r2): gate the ROTATION-latch reset-cycle
        # clear on freshness. A provably stale real reading can carry an advanced
        # reset_at; clearing the rotation latch on it would let the NEXT fresh
        # reading at that same reset re-emit a duplicate preemptive candidate (the
        # exact double-rotation the staleness-guard must prevent). Only a fresh
        # reading or a 429-signal may advance the rotation cycle here.
        if cache_fresh and reset_cycle_advanced(rotation_triggered_reset_at, reset_at):
            rotation_triggered_at = None
            rotation_triggered_reset_at = None
        # Issue #1468 (codex r3+r4): a native 429-signal whose token DIFFERS from
        # the one we last rotated on must clear the rotation latch so the newly-
        # active token rotates ONCE — even when a counting-down Retry-After lands
        # the new token on the SAME reset_at (so reset_cycle_advanced does not
        # fire). We only require the CURRENT snapshot to be a 429-signal
        # (signal_token present); a prior latch with no signal token (it was
        # triggered by a REAL reading → rotation_triggered_signal_token is None)
        # still differs from an actual token digest, so the clear must fire there
        # too (codex r4: otherwise B is wrongly suppressed after a real-reading
        # rotation at the same reset_at). The probe bounds this to one signal per
        # token per incident, so this cannot loop: a loop-back to an
        # already-signalled token is suppressed at the probe (no fresh cache), so
        # the monitor never re-sees a stale token's signal. Real readings carry no
        # signal_token (None) → this whole branch is skipped → #215/#831 latch
        # behavior is unchanged off the 429-signal path.
        if signal_token is not None and signal_token != rotation_triggered_signal_token:
            rotation_triggered_at = None
            rotation_triggered_reset_at = None

        next_latch = previous_latch
        alerted_at = previous.get("alerted_at")
        candidate_threshold = (
            weekly_warn_threshold if snapshot.get("window") == "weekly" else rotation_threshold
        )
        candidate_threshold_name = (
            "weekly_warn_threshold" if snapshot.get("window") == "weekly" else "rotation_threshold"
        )

        if bucket == "ok":
            # Operator has room again; clear the latch so a future climb to warn
            # re-alerts once, per issue #215 "ok transition resets the latch".
            next_latch = None
        elif bucket == "unknown":
            # Don't alert on unparseable snapshots; don't touch the latch either.
            pass
        elif bucket_rank(bucket) > bucket_rank(previous_latch):
            # Strict ascent only — same-bucket re-entries stay silent, which is
            # the "latched one-shot per cycle" contract. Three alerts per cycle
            # maximum: warn → elevated → crit.
            alert = {
                **snapshot,
                "bucket": bucket,
                "message": alert_message(snapshot, bucket),
            }
            alerts.append(alert)
            next_latch = bucket
            alerted_at = now_iso()

        if snapshot.get("provider") == "claude":
            # #17927 P2 (E10 Obs#1): `cache_fresh` was computed above (BEFORE the
            # reset-cycle latch clear) so a stale reading's advanced reset_at can
            # never clear the rotation latch. A synthetic 429-signal (#1468)
            # bypasses the staleness-guard; only REAL readings are subject to it.
            # #18849 Part 2: cache_fresh also folds in token attribution, so a
            # post-rotation leftover reading (digest mismatch) is inert here too.
            if not isinstance(used_percent, (int, float)) or not cache_fresh:
                # No usable signal this tick (absent/null reading OR a provably
                # stale cache). Leave the rotation latch EXACTLY as-is — do not
                # advance it and do not clear it. A stale/absent cache must never
                # be read as 0% usage (which would re-arm rotation) nor as a
                # threshold crossing (which would rotate on a dead reading).
                pass
            elif used_percent >= candidate_threshold:
                # Track worst-case across this monitor pass — used for aggregate
                # attribution in the output envelope.
                if used_percent > worst_case_percent:
                    worst_case_percent = float(used_percent)
                    worst_case_agent = snapshot_agent or None
                if not _agent_rotation_eligible(snapshot_agent, rotation_eligible):
                    # #17927 P2 (E6/E8): a monitored but non-managed agent
                    # (global-login / dynamic) crossing threshold drives an ALERT
                    # only — never a rotation candidate and never the latch. Its
                    # statusLine cache carries no token/account identity, so
                    # rotating the managed pool on it would mis-attribute across
                    # accounts. Latch stays untouched (alert-only).
                    pass
                elif not rotation_triggered_at:
                    candidate = {
                        **snapshot,
                        "rotation_threshold": candidate_threshold,
                        "rotation_threshold_name": candidate_threshold_name,
                        "worst_case_agent": snapshot_agent or None,
                        # #17927 P2 (E10 Obs#2): rotation-path provenance so the
                        # daemon audit can distinguish Option-C preemptive (a
                        # fresh statusLine/native reading crossing threshold) from
                        # P2-B reactive (a 429/limited-response signal cache).
                        "rotation_trigger": "reactive" if snapshot.get("signal") else "preemptive",
                        "message": (
                            f"Claude usage rotation candidate: {snapshot.get('window') or 'unknown'} "
                            f"window at {used_percent:.0f}% "
                            f"({candidate_threshold_name} {candidate_threshold:.0f}%)"
                            + (f" on agent {snapshot_agent}" if snapshot_agent else "")
                            + "."
                        ),
                    }
                    rotation_candidates.append(candidate)
                    rotation_triggered_at = now_iso()
                    rotation_triggered_reset_at = reset_at
                    # #1468: remember which token's signal this rotation was for,
                    # so a later DIFFERENT-token 429-signal clears the latch
                    # (rotate the new token once) even at the same reset_at.
                    rotation_triggered_signal_token = signal_token
            else:
                # Fresh, parseable, below threshold → operator has room; clear
                # the latch so a future climb re-arms once (#215/#831 contract).
                rotation_triggered_at = None
                rotation_triggered_reset_at = None
                rotation_triggered_signal_token = None

        entries[key] = {
            "last_alert_bucket": next_latch,
            "reset_at": reset_at,
            "used_percent": used_percent,
            "alerted_at": alerted_at,
            "rotation_triggered_at": rotation_triggered_at,
            "rotation_triggered_reset_at": rotation_triggered_reset_at,
            "rotation_triggered_signal_token": rotation_triggered_signal_token,
        }

    state["updated_at"] = now_iso()
    save_monitor_state(state_path, state)
    # Per-agent breakdown: one entry per (agent, provider, window) with the
    # latest used_percent so operator-facing output can show "agent-A 99%,
    # agent-B 60%". Sorted by used_percent desc so the worst-case row is
    # first.
    per_agent_breakdown = sorted(
        (
            {
                "agent": str(s.get("agent") or ""),
                "provider": s.get("provider"),
                "account": s.get("account"),
                "window": s.get("window"),
                "used_percent": s.get("used_percent"),
                "health": s.get("health"),
            }
            for s in snapshots
            if s.get("agent")
        ),
        key=lambda r: (-(r["used_percent"] if isinstance(r["used_percent"], (int, float)) else -1)),
    )
    result = {
        "generated_at": now_iso(),
        "snapshots": snapshots,
        "alerts": alerts,
        "rotation_candidates": rotation_candidates,
        "state_file": str(state_path),
        "worst_case_agent": worst_case_agent,
        "per_agent_breakdown": per_agent_breakdown,
    }
    # #2171 PR-B3 Part 2: only add the diagnostics key when a split was actually
    # observed, so the steady-state monitor envelope is byte-identical to before.
    if cache_split_diagnostics:
        result["cache_split_diagnostics"] = cache_split_diagnostics
    if args.json:
        print(json.dumps(result, ensure_ascii=True, indent=2))
        return 0
    for alert in alerts:
        print(alert["message"])
    return 0


def cmd_alerts(args: argparse.Namespace) -> int:
    audit_file = Path(args.audit_file).expanduser()
    if not audit_file.is_file():
        payload: list[dict[str, Any]] = []
    else:
        payload = []
        for line in audit_file.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict) or record.get("action") != "usage_alert":
                continue
            payload.append(record)
    limit = max(0, int(args.limit))
    if limit:
        payload = payload[-limit:]
    if args.json:
        print(json.dumps(payload, ensure_ascii=True, indent=2))
        return 0
    for record in payload:
        print(json.dumps(record, ensure_ascii=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    common_kwargs = {
        "help": argparse.SUPPRESS,
    }

    def add_source_args(cmd: argparse.ArgumentParser) -> None:
        cmd.add_argument("--claude-usage-cache", required=True, **common_kwargs)
        cmd.add_argument("--codex-sessions-dir", required=True, **common_kwargs)
        cmd.add_argument("--warn-threshold", type=float, default=90.0, **common_kwargs)
        cmd.add_argument("--elevated-threshold", type=float, default=95.0, **common_kwargs)
        cmd.add_argument("--critical-threshold", type=float, default=100.0, **common_kwargs)
        # Issue #831 per-agent collection. Both optional; back-compat is
        # preserved (U5) when neither is supplied or per-agent payload is
        # empty.
        cmd.add_argument("--per-agent-cache-json", default=None, **common_kwargs)
        cmd.add_argument("--legacy-single-path", default=None, **common_kwargs)
        # Issue #1437 PRIMARY: the native-probe controller cache, read
        # additively in per-agent mode (deduped against per-agent paths) so the
        # native usage signal reaches rotation in the default daemon path.
        cmd.add_argument("--native-usage-cache", default=None, **common_kwargs)
        # Stale-attribution guard: one-way digest of the currently-active
        # rotation-registry token. When set, a synthetic 429-signal cache
        # attributed to a DIFFERENT token is treated as stale (dropped) so a
        # freshly rotated-in token never inherits the previous token's
        # near-limit signal (rotation ping-pong guard). Optional; absent →
        # no attribution check (back-compat).
        cmd.add_argument("--active-token-digest", default=None, **common_kwargs)

    status_parser = sub.add_parser("status")
    add_source_args(status_parser)
    status_parser.add_argument("--json", action="store_true")
    status_parser.set_defaults(handler=cmd_status)

    monitor_parser = sub.add_parser("monitor")
    add_source_args(monitor_parser)
    monitor_parser.add_argument("--state-file", required=True)
    monitor_parser.add_argument("--rotation-threshold", type=float, default=99.0)
    # 7d proactive threshold. Separate from rotation_threshold so the 5h
    # window keeps its 99% behavior while weekly usage can trigger earlier.
    monitor_parser.add_argument("--weekly-warn-threshold", type=float, default=95.0)
    # #17927 P2 (E6/E8): CSV of agents whose usage may DRIVE a token rotation
    # (the managed-token pool). Default None = ungated (legacy behavior — every
    # candidate is rotation-eligible). An empty string ENABLES the gate with an
    # empty set so only the controller-managed sentinels (__native__ / legacy
    # empty-agent cache) rotate. A monitored but non-managed agent's high-usage
    # statusLine cache then drives an ALERT only — never a rotation/latch.
    monitor_parser.add_argument("--rotation-eligible-agents", default=None)
    # #17927 P2 (E10 Obs#1): a cache whose `_written_at` is older than this many
    # seconds is "no signal → defer to reactive", never read as a fresh reading.
    # Fail-open: a cache with no/unparseable `_written_at` is treated as fresh
    # (the gate only suppresses when staleness is PROVABLE).
    monitor_parser.add_argument(
        "--cache-max-age-seconds",
        type=float,
        default=float(os.environ.get("BRIDGE_USAGE_CACHE_MAX_AGE_SECONDS") or 21600),
    )
    monitor_parser.add_argument("--json", action="store_true")
    monitor_parser.set_defaults(handler=cmd_monitor)

    alerts_parser = sub.add_parser("alerts")
    alerts_parser.add_argument("--audit-file", required=True)
    alerts_parser.add_argument("--limit", type=int, default=20)
    alerts_parser.add_argument("--json", action="store_true")
    alerts_parser.set_defaults(handler=cmd_alerts)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
