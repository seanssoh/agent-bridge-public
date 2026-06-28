#!/usr/bin/env python3
"""Behavioral harness for scripts/smoke/2171-daemon-active-dead-recover.sh.

#2171 PR-B2 Part2 (incident #19460 M4 fleet-down): Option-B auth-dead marker.
The native usage probe is the SOLE writer — it classifies a 401 / origin-served
403 on the active token as auth-death and stamps a token-free marker; the daemon
nudge fanout does ZERO network, it only READS + identity-validates the marker.

Covers the writer (probe → marker) and the read-only validator gate via the
in-process seam: ``run_probe(http_get=<stub>)`` (the same offline seam #1437/#1468
use) and ``auth_dead_marker_verdict(...)``. ONLY mock token strings — never a real
token, never a network call. No heredoc-stdin (footgun #11): invoked by path.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _load(mod_name: str, filename: str):
    spec = importlib.util.spec_from_file_location(mod_name, str(REPO_ROOT / filename))
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    assert spec and spec.loader
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


probe = _load("bridge_usage_probe", "bridge-usage-probe.py")

# Mock OAT strings (sk-ant-oat… so they look like real OATs; never real).
TOK_ACTIVE = "sk-ant-oat-MOCK-active-dead-0001"
TOK_REPLACED = "sk-ant-oat-MOCK-replaced-tok-0002"

failures: list[str] = []


def check(cond: bool, label: str) -> None:
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}")
        failures.append(label)


def display_fp(token: str) -> str:
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    tail = token[-4:] if len(token) >= 4 else token
    return f"sha256:{digest[:12]}...{tail}"


def digest16(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]


def write_registry(path: Path, active_id: str, token: str) -> None:
    path.write_text(
        json.dumps(
            {
                "version": 1,
                "active_token_id": active_id,
                "tokens": [{"id": active_id, "token": token, "enabled": True}],
            }
        ),
        encoding="utf-8",
    )


def stub_http_error(status, *, headers=None, body=""):
    def _get(url, hdrs, timeout):
        raise probe.ProbeHTTPError(status, body=body, retry_after=None, headers=headers)

    return _get


def stub_ok(payload):
    def _get(url, hdrs, timeout):
        return json.dumps(payload)

    return _get


def run(tmp: Path, *, http_get, marker: Path | None, registry: Path, now=1000.0):
    cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
    return probe.run_probe(
        cache_path=cache_path,
        registry_path=registry,
        credentials_path=None,
        allow_env=False,
        user_agent_version="2.1.0",
        max_age_seconds=0.0,
        cooldown_seconds=0.0,
        http_timeout=10.0,
        retry_after_cap=5.0,
        now=now,
        http_get=http_get,
        log=lambda m: None,
        auth_dead_marker=marker,
    )


# --- Writer ---------------------------------------------------------------- #
def w1_401_writes_marker(tmp: Path) -> None:
    print("[W1] 401 on the active token -> auth-dead marker (token-free, registry-bound)")
    d = tmp / "w1"
    d.mkdir()
    reg = d / "reg.json"
    write_registry(reg, "t1", TOK_ACTIVE)
    marker = d / "auth-dead.json"
    res = run(d, http_get=stub_http_error(401, body=json.dumps({"error": {"type": "authentication_error"}})), marker=marker, registry=reg)
    check(res.get("status") == "degraded", "probe degrades (serves stale, no usage cache)")
    check(marker.is_file(), "marker FILE written")
    spec = json.loads(marker.read_text())
    check(spec.get("active_token_id") == "t1", "marker active_token_id=t1")
    check(spec.get("token_fingerprint") == display_fp(TOK_ACTIVE), "marker display token_fingerprint matches bridge-auth form")
    check(spec.get("_token_signal_digest") == digest16(TOK_ACTIVE), "marker _token_signal_digest (16-char) matches")
    check(spec.get("http_status") == 401, "marker http_status=401")
    check(spec.get("source") == "usage-probe", "marker source=usage-probe (sole writer)")
    check(bool(spec.get("written_at")), "marker written_at stamped")
    # Token-free: no raw token bytes in the marker.
    check(TOK_ACTIVE not in marker.read_text(), "marker carries NO raw token bytes")
    # The usage cache must NOT have been written (auth-death is not a usage signal).
    cache = d / "plugins" / "claude-hud" / ".usage-cache.json"
    check(not cache.is_file(), "usage cache NOT written on auth-death (kept separate)")


def w2_origin_403_writes_marker(tmp: Path) -> None:
    print("[W2] origin-served 403 -> auth-dead marker (edge-403 diverges below)")
    d = tmp / "w2"
    d.mkdir()
    reg = d / "reg.json"
    write_registry(reg, "t1", TOK_ACTIVE)
    marker = d / "auth-dead.json"
    # request-id header => anthropic origin => FAILURE classification => marker.
    res = run(d, http_get=stub_http_error(403, headers={"request-id": "abc"}, body="{}"), marker=marker, registry=reg)
    check(res.get("status") == "degraded", "probe degrades")
    check(marker.is_file(), "origin-403 writes the marker")
    check(json.loads(marker.read_text()).get("http_status") == 403, "marker http_status=403")


def w3_edge_403_no_marker(tmp: Path) -> None:
    print("[W3] CDN edge-blocked 403 (no anthropic origin headers) -> NO marker")
    d = tmp / "w3"
    d.mkdir()
    reg = d / "reg.json"
    write_registry(reg, "t1", TOK_ACTIVE)
    marker = d / "auth-dead.json"
    # server: cloudflare, no origin headers => EDGE_BLOCKED, never auth-death.
    res = run(d, http_get=stub_http_error(403, headers={"server": "cloudflare"}, body="{}"), marker=marker, registry=reg)
    check(res.get("status") == "edge-blocked", "edge-blocked classification (not auth-death)")
    check(not marker.is_file(), "edge-403 writes NO auth-dead marker")


def w4_clean_read_clears_marker(tmp: Path) -> None:
    print("[W4] a clean read on the active token CLEARS its stale marker")
    d = tmp / "w4"
    d.mkdir()
    reg = d / "reg.json"
    write_registry(reg, "t1", TOK_ACTIVE)
    marker = d / "auth-dead.json"
    # Seed a marker that blames the active token, then a healthy 200 reading.
    marker.write_text(json.dumps({
        "active_token_id": "t1",
        "token_fingerprint": display_fp(TOK_ACTIVE),
        "_token_signal_digest": digest16(TOK_ACTIVE),
        "http_status": 401,
        "source": "usage-probe",
        "written_at": "2026-01-01T00:00:00+00:00",
    }), encoding="utf-8")
    payload = {"five_hour": {"utilization": 12, "resets_at": "2026-07-01T00:00:00Z"},
               "seven_day": {"utilization": 5, "resets_at": "2026-07-07T00:00:00Z"}}
    res = run(d, http_get=stub_ok(payload), marker=marker, registry=reg)
    check(res.get("status") == "written", "clean reading written")
    check(not marker.is_file(), "healthy active token CLEARS the auth-dead marker (no spurious recover)")


# --- Validator gate -------------------------------------------------------- #
def _marker_for(token: str, active_id: str, written_at: str, http_status=401) -> dict:
    return {
        "active_token_id": active_id,
        "token_fingerprint": display_fp(token),
        "_token_signal_digest": digest16(token),
        "http_status": http_status,
        "source": "usage-probe",
        "written_at": written_at,
    }


def v_verdict(tmp: Path, name: str, marker_obj, reg_active_id, reg_token, *, now=1000.0, max_age=300.0):
    d = tmp / name
    d.mkdir()
    reg = d / "reg.json"
    write_registry(reg, reg_active_id, reg_token)
    marker = d / "auth-dead.json"
    if marker_obj == "ABSENT":
        pass
    elif marker_obj == "GARBAGE":
        marker.write_text("}{ not json", encoding="utf-8")
    else:
        marker.write_text(json.dumps(marker_obj), encoding="utf-8")
    return probe.auth_dead_marker_verdict(marker, reg, max_age, now)


def validator_cases(tmp: Path) -> None:
    iso_fresh = "1970-01-01T00:00:00+00:00"  # epoch 0; we drive `now` to bound age

    print("[V1] fresh + full identity match -> consume")
    # written_at = now-10s (fresh within max_age=300).
    from datetime import datetime, timezone
    now = 1_000_000.0
    fresh = datetime.fromtimestamp(now - 10, tz=timezone.utc).isoformat()
    v = v_verdict(tmp, "v1", _marker_for(TOK_ACTIVE, "t1", fresh), "t1", TOK_ACTIVE, now=now)
    check(v.get("verdict") == "consume", "V1 verdict=consume")
    check(v.get("active_token_id") == "t1", "V1 returns active_token_id=t1 (for mark-adverse id)")
    check(v.get("fingerprint") == display_fp(TOK_ACTIVE), "V1 returns current display fingerprint (for --fingerprint)")
    check(v.get("http_status") == "401", "V1 surfaces http_status")

    print("[V2] stale written_at (age > max_age) -> no-signal:stale")
    stale = datetime.fromtimestamp(now - 5000, tz=timezone.utc).isoformat()
    v = v_verdict(tmp, "v2", _marker_for(TOK_ACTIVE, "t1", stale), "t1", TOK_ACTIVE, now=now, max_age=300.0)
    check(v.get("verdict") == "no-signal", "V2 verdict=no-signal")
    check(v.get("reason") == "stale", "V2 reason=stale (does NOT suppress the nudge)")

    print("[V3a] active token VALUE replaced -> no-signal (fingerprint/digest mismatch)")
    fresh3 = datetime.fromtimestamp(now - 10, tz=timezone.utc).isoformat()
    # Marker blames the OLD token; registry active id stays t1 but its token value changed.
    v = v_verdict(tmp, "v3a", _marker_for(TOK_ACTIVE, "t1", fresh3), "t1", TOK_REPLACED, now=now)
    check(v.get("verdict") == "no-signal", "V3a verdict=no-signal after token replacement")
    check(v.get("reason") in ("fingerprint_mismatch", "digest_mismatch"), "V3a reason=identity mismatch (stamps NOTHING)")

    print("[V3b] active token ID changed -> no-signal:active_id_mismatch")
    v = v_verdict(tmp, "v3b", _marker_for(TOK_ACTIVE, "t1", fresh3), "t2", TOK_ACTIVE, now=now)
    check(v.get("verdict") == "no-signal", "V3b verdict=no-signal after active id change")
    check(v.get("reason") == "active_id_mismatch", "V3b reason=active_id_mismatch")

    print("[V4] marker absent -> no-signal:marker_absent")
    v = v_verdict(tmp, "v4", "ABSENT", "t1", TOK_ACTIVE, now=now)
    check(v.get("verdict") == "no-signal", "V4 verdict=no-signal")
    check(v.get("reason") == "marker_absent", "V4 reason=marker_absent")

    print("[V5] marker unreadable -> no-signal:marker_unreadable")
    v = v_verdict(tmp, "v5", "GARBAGE", "t1", TOK_ACTIVE, now=now)
    check(v.get("verdict") == "no-signal", "V5 verdict=no-signal")
    check(v.get("reason") == "marker_unreadable", "V5 reason=marker_unreadable")

    # Use iso_fresh to silence the unused-var linter intent (documents epoch base).
    _ = iso_fresh


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="agb-2171-authdead.") as tmp:
        work = Path(tmp)
        w1_401_writes_marker(work)
        w2_origin_403_writes_marker(work)
        w3_edge_403_no_marker(work)
        w4_clean_read_clears_marker(work)
        validator_cases(work)
    if failures:
        print(f"[helper] {len(failures)} assertion(s) FAILED")
        return 1
    print("[helper] all assertions passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
