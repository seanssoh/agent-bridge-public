#!/usr/bin/env python3
"""Mock-only harness — usage-probe edge classification + per-token backoff.

Invoked by scripts/smoke/usage-probe-edge-classification.sh. NEVER makes a
live network call: every scenario injects a stub ``http_get`` into
``run_probe`` (the seam exists precisely so CI stays offline). Uses ONLY mock
token strings — never a real credential.

Background (field incident): every probe response was served by the CDN EDGE
(``Server: cloudflare``, NO ``request-id`` / ``anthropic-*`` origin headers,
Retry-After pinned at exactly 3600, the same token flapping 403<->429 minute
to minute) while 20+ live sessions on the SAME account ran fine. The old
``is_rate_limit_429`` looked ONLY at the body's ``rate_limit_error`` type, so
the edge block was misread as account quota → a synthetic at-limit cache →
usage-alert storms (18 rows/tick) + rotation ping-pong. The old fixed 60s
cooldown also re-struck the edge every ~6 minutes, permanently renewing the
edge ban window.

Coverage:
  (A) 429/403 3-way classification:
      - CF edge 429/403 (Server: cloudflare / no origin headers) → status
        ``edge-blocked``; NO synthetic cache is fabricated.
      - anthropic-origin 429 rate_limit_error → the existing #1468
        near-limit signal path is PRESERVED.
      - headerless legacy seam (headers=None) → pre-headers body-only
        behavior preserved (back-compat for older callers).
      - anthropic-origin 403 → plain probe failure (degraded), not edge.
  (B) per-token exponential backoff: 5min → 15min → 60min cap on consecutive
      edge blocks, min(Retry-After, cap) honored, in-cooldown ticks make NO
      network call, a rotated-in token probes immediately, success clears
      the streak.
  (C) synthetic-signal alert isolation: a 429-signal cache reaches the
      rotation-candidate lane but NEVER the operator alert lane; real
      readings still alert.
  (D) cache token attribution: a cache attributed to a previously-active
      token is stale for BOTH the probe freshness gate (re-probe now) and
      the monitor (drop the synthetic, no ping-pong); real readings are
      fail-open; the active-token-digest CLI prints the digest, never the
      token.
  (E) statusLine-tap priority: a FRESH stdin-tap cache satisfies the probe
      freshness gate (real measured data is never overwritten); a STALE tap
      cache does not suppress the probe.
  (F) audit TSV sentinel: empty middle columns are emitted as `-` so the
      bash consumer's IFS=$'\\t' read cannot collapse fields (http_status no
      longer shifts into the reset_at slot).
"""

from __future__ import annotations

import importlib.util
import json
import os
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
usage = _load("bridge_usage", "bridge-usage.py")
helpers = _load("bridge_daemon_helpers", "bridge-daemon-helpers.py")

MOCK_TOKEN_A = "sk-ant-oat-MOCK-not-a-real-token-AAAA"
MOCK_TOKEN_B = "sk-ant-oat-MOCK-not-a-real-token-BBBB"

RATE_LIMIT_BODY = {"error": {"message": "Rate limited.", "type": "rate_limit_error"}}
CF_BLOCK_BODY = {"error": {"message": "Rate limited.", "type": "rate_limit_error"}}
CF_403_BODY = "<!DOCTYPE html><html><body>Access denied | api.anthropic.com used Cloudflare to restrict access</body></html>" + ("x" * 300)

# Edge responses: Server: cloudflare, NO request-id / anthropic-* headers.
CF_HEADERS = {"Server": "cloudflare", "CF-RAY": "8f2mock-NRT", "Content-Type": "application/json"}
# Origin responses: request-id / anthropic-* present.
ANTHROPIC_HEADERS = {
    "request-id": "req_mock_0123456789",
    "anthropic-organization-id": "org-mock",
    "Content-Type": "application/json",
    "Server": "cloudflare",  # the origin ALSO transits cloudflare; origin headers win
}

OK_BODY = {
    "five_hour": {"utilization": 42.0, "resets_at": "2026-06-12T18:00:00+00:00"},
    "seven_day": {"utilization": 13.0, "resets_at": "2026-06-18T00:00:00+00:00"},
}
AT_LIMIT_BODY = {
    "five_hour": {"utilization": 100.0, "resets_at": "2026-06-12T18:00:00+00:00"},
    "seven_day": {"utilization": 100.0, "resets_at": "2026-06-12T18:00:00+00:00"},
}

failures: list[str] = []


def check(cond: bool, label: str) -> None:
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}")
        failures.append(label)


def _stub_http_error(status, body_obj, retry_after, headers="__omit__", calls=None):
    """Stub raising ProbeHTTPError. headers='__omit__' builds a LEGACY
    (pre-headers) exception so back-compat callers are exercised too."""

    def _get(url, headers_req, timeout):
        if calls is not None:
            calls["n"] = calls.get("n", 0) + 1
        assert headers_req.get("User-Agent", "").startswith("claude-code/"), "missing/bad UA"
        body = body_obj if isinstance(body_obj, str) else ("" if body_obj is None else json.dumps(body_obj))
        if headers == "__omit__":
            raise probe.ProbeHTTPError(status, body=body, retry_after=retry_after)
        raise probe.ProbeHTTPError(status, body=body, retry_after=retry_after, headers=headers)

    return _get


def _stub_ok(body_obj, calls=None):
    def _get(url, headers_req, timeout):
        if calls is not None:
            calls["n"] = calls.get("n", 0) + 1
        return json.dumps(body_obj)

    return _get


def _registry(tmp: Path, active_token: str) -> Path:
    p = tmp / "claude-oauth-tokens.json"
    p.write_text(
        json.dumps(
            {
                "active_token_id": "tok-active",
                "tokens": [
                    {"id": "tok-active", "token": active_token, "enabled": True},
                ],
            }
        ),
        encoding="utf-8",
    )
    return p


def _run(tmp: Path, *, http_get, registry=None, now=1000.0, max_age=0.0, cooldown=0.0):
    cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
    return probe.run_probe(
        cache_path=cache_path,
        registry_path=registry,
        credentials_path=None,
        user_agent_version="2.1.0",
        max_age_seconds=max_age,
        cooldown_seconds=cooldown,
        http_timeout=10.0,
        retry_after_cap=5.0,
        now=now,
        http_get=http_get,
        log=lambda m: None,
    )


def _monitor_run(cache_path: Path, state_path: Path, *, active_token_digest=None, rotation_threshold=99.0):
    """Drive the REAL bridge-usage.py monitor on a single cache and return its
    full result envelope (snapshots / alerts / rotation_candidates)."""

    class _NS:
        pass

    ns = _NS()
    ns.claude_usage_cache = str(cache_path)
    ns.codex_sessions_dir = str(cache_path.parent / "no-codex")
    ns.warn_threshold = 90.0
    ns.elevated_threshold = 95.0
    ns.critical_threshold = 100.0
    ns.rotation_threshold = rotation_threshold
    ns.per_agent_cache_json = None
    ns.legacy_single_path = None
    ns.native_usage_cache = None
    ns.active_token_digest = active_token_digest
    ns.state_file = str(state_path)
    ns.json = True
    import contextlib
    import io

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        usage.cmd_monitor(ns)
    return json.loads(buf.getvalue() or "{}")


def main() -> int:
    # ================= (A) 429/403 3-way classification ====================
    print("[A1] CF edge 429 (cloudflare, no origin headers) → edge-blocked, NO synthetic cache")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(429, CF_BLOCK_BODY, 3600.0, headers=CF_HEADERS), registry=reg)
        check(res["status"] == "edge-blocked", "status is edge-blocked (NOT rate-limited-signal)")
        check(res["http_status"] == 429, "http_status carried")
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        check(not cache_path.is_file(), "no synthetic near-limit cache fabricated")
        check(res["cooldown_seconds"] == 3600.0, "Retry-After=3600 honored in full (max(backoff, capped RA))")
        check(bool(res.get("detail")), "body snippet carried as detail for the audit row")

    print("[A2] CF edge 403 (cloudflare HTML block, no Retry-After) → edge-blocked")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(403, CF_403_BODY, None, headers=CF_HEADERS), registry=reg)
        check(res["status"] == "edge-blocked", "403 from the edge classifies edge-blocked too")
        check(not (tmp / "plugins" / "claude-hud" / ".usage-cache.json").is_file(), "no cache fabricated on 403")
        check(len(res.get("detail") or "") <= 200, "detail snippet capped at 200 chars")
        check(res["cooldown_seconds"] == 300.0, "no Retry-After → first-failure backoff floor (5min)")

    print("[A3] anthropic-origin 429 rate_limit_error → #1468 signal path PRESERVED")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0, headers=ANTHROPIC_HEADERS), registry=reg)
        check(res["status"] == "rate-limited-signal", "origin-proven 429 still emits the near-limit signal")
        cache = json.loads((tmp / "plugins" / "claude-hud" / ".usage-cache.json").read_text())
        check(cache["data"]["fiveHour"] == 100.0, "synthetic at-limit cache persisted")
        check(cache["_token_digest"] == probe._token_signal_digest(MOCK_TOKEN_A), "signal cache attributed to the active token digest")

    print("[A3b] origin 429 ALSO arms a Retry-After-based backoff window (not the fixed 60s knob)")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        dig_a = probe._token_signal_digest(MOCK_TOKEN_A)
        # cooldown=60.0 is the operator's fixed knob. An account-quota 429 must
        # NOT settle for it: the token is unusable for the reset window, so the
        # backoff must follow the same span contract as an edge block
        # (max(EDGE_BACKOFF_SCHEDULE[streak], min(Retry-After, cap))). With
        # Retry-After=3600 the first strike → 3600s, NOT 60s.
        res = _run(
            tmp,
            http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3600.0, headers=ANTHROPIC_HEADERS),
            registry=reg, now=1000.0, cooldown=60.0,
        )
        check(res["status"] == "rate-limited-signal", "still emits the #1468 near-limit signal (contract unchanged)")
        cooldowns = probe._token_cooldowns(tmp / "plugins" / "claude-hud" / ".usage-cache.json")
        entry = cooldowns.get(dig_a) or {}
        until = probe.token_cooldown_until(tmp / "plugins" / "claude-hud" / ".usage-cache.json", dig_a)
        span = until - 1000.0
        check(span >= min(3600.0, probe.EDGE_RETRY_AFTER_CAP_SECONDS), f"backoff honors Retry-After (got span={span:g}s)")
        check(abs(span - 3600.0) < 1e-6, "first account-quota strike → 3600s (Retry-After), NOT the 60s knob")
        check(span != 60.0, "explicitly NOT the fixed 60s cooldown")
        check(int(entry.get("streak") or 0) == 1, "escalate=True bumped the consecutive-failure streak to 1")
        check(entry.get("outcome") == "rate-limited", "cooldown outcome tagged rate-limited")
        # A second strike on the SAME still-limited token escalates the streak.
        res2 = _run(
            tmp,
            http_get=_stub_http_error(429, RATE_LIMIT_BODY, 300.0, headers=ANTHROPIC_HEADERS),
            registry=reg, now=5000.0, cooldown=60.0,
        )
        check(res2["status"] in ("rate-limited-signal", "rate-limited-suppressed"), "second strike still on the signal lane")
        entry2 = probe._token_cooldowns(tmp / "plugins" / "claude-hud" / ".usage-cache.json").get(dig_a) or {}
        until2 = probe.token_cooldown_until(tmp / "plugins" / "claude-hud" / ".usage-cache.json", dig_a)
        check(int(entry2.get("streak") or 0) == 2, "consecutive account-quota strike escalated streak to 2")
        # streak 2 → EDGE_BACKOFF_SCHEDULE[1]=900s vs min(RA=300, cap)=300 → 900s wins.
        check(abs((until2 - 5000.0) - 900.0) < 1e-6, "streak-2 backoff = max(900s schedule, 300s RA) = 900s")

    print("[A3c] a clean reading clears the account-quota backoff streak (success contract preserved)")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        dig_a = probe._token_signal_digest(MOCK_TOKEN_A)
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        # Strike once (arms streak=1, 3600s window), then a clean reading after
        # the window must clear the cooldown so a later genuine limit re-arms
        # from streak 1 — not inherit the prior streak.
        _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3600.0, headers=ANTHROPIC_HEADERS), registry=reg, now=1000.0, cooldown=60.0)
        ok_res = _run(tmp, http_get=_stub_ok(OK_BODY), registry=reg, now=5000.0, cooldown=60.0)
        check(ok_res["status"] == "written", "clean reading after the window writes a real cache")
        check(probe.token_cooldown_until(cache_path, dig_a) == 0.0, "success cleared the account-quota cooldown/streak entry")

    print("[A4] headerless legacy seam (headers=None) → pre-headers behavior preserved")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg)
        check(res["status"] == "rate-limited-signal", "legacy headerless 429 rate_limit_error still signals (back-compat)")

    print("[A5] anthropic-origin 403 → plain failure (degraded), not edge, not signal")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(403, {"error": {"type": "permission_error"}}, None, headers=ANTHROPIC_HEADERS), registry=reg)
        check(res["status"] == "degraded", "origin 403 degrades (probe failure, no edge backoff escalation)")
        check(not (tmp / "plugins" / "claude-hud" / ".usage-cache.json").is_file(), "no cache fabricated")

    print("[A6] headers PRESENT but empty (no origin proof) → edge-blocked")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3600.0, headers={}), registry=reg)
        check(res["status"] == "edge-blocked", "a 429 with NO anthropic origin headers is an edge block, not quota")

    print("[A7] classifier units")
    exc_edge = probe.ProbeHTTPError(429, body=json.dumps(RATE_LIMIT_BODY), retry_after=3600.0, headers=CF_HEADERS)
    exc_origin = probe.ProbeHTTPError(429, body=json.dumps(RATE_LIMIT_BODY), retry_after=3143.0, headers=ANTHROPIC_HEADERS)
    exc_legacy = probe.ProbeHTTPError(429, body=json.dumps(RATE_LIMIT_BODY), retry_after=3143.0)
    exc_401 = probe.ProbeHTTPError(401, body="{}", headers=ANTHROPIC_HEADERS)
    exc_origin_403 = probe.ProbeHTTPError(403, body="{}", headers=ANTHROPIC_HEADERS)
    check(probe.classify_probe_http_error(exc_edge) == "edge-blocked", "classify: CF edge 429 → edge-blocked")
    check(probe.classify_probe_http_error(exc_origin) == "account-rate-limit", "classify: origin 429 rate_limit_error → account")
    check(
        probe.classify_probe_http_error(exc_origin_403) == "failure",
        "classify: origin 403 (request-id present, Server: cloudflare transit) → failure, NOT edge",
    )
    check(probe.classify_probe_http_error(exc_legacy) == "account-rate-limit", "classify: headerless legacy 429 → account (back-compat)")
    check(probe.classify_probe_http_error(exc_401) == "failure", "classify: 401 → failure")
    check(probe.is_rate_limit_429(exc_origin) is True, "is_rate_limit_429 wrapper: origin 429 → True")
    check(probe.is_rate_limit_429(exc_edge) is False, "is_rate_limit_429 wrapper: edge 429 → False")

    # ================= (B) per-token exponential backoff ====================
    print("[B1] consecutive edge blocks escalate 5min → 15min → 60min cap; cooldown ticks make NO call")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        edge_403 = _stub_http_error(403, CF_403_BODY, None, headers=CF_HEADERS)
        r1 = _run(tmp, http_get=edge_403, registry=reg, now=1000.0)
        check(r1["cooldown_seconds"] == 300.0, "1st edge block → 300s")
        calls = {"n": 0}
        r_gate = _run(tmp, http_get=_stub_http_error(403, CF_403_BODY, None, headers=CF_HEADERS, calls=calls), registry=reg, now=1100.0)
        check(r_gate["status"] == "cooldown", "tick inside the window → cooldown (serving stale)")
        check(calls["n"] == 0, "in-cooldown tick made NO network call (edge ban not renewed)")
        r2 = _run(tmp, http_get=edge_403, registry=reg, now=1400.0)
        check(r2["cooldown_seconds"] == 900.0, "2nd consecutive edge block → 900s")
        r3 = _run(tmp, http_get=edge_403, registry=reg, now=2400.0)
        check(r3["cooldown_seconds"] == 3600.0, "3rd consecutive edge block → 3600s (cap)")
        r4 = _run(tmp, http_get=edge_403, registry=reg, now=6100.0)
        check(r4["cooldown_seconds"] == 3600.0, "4th+ stays at the 60min cap")

    print("[B2] rotated-in token probes immediately (per-token map, not global)")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg_a = _registry(tmp, MOCK_TOKEN_A)
        _run(tmp, http_get=_stub_http_error(429, CF_BLOCK_BODY, 3600.0, headers=CF_HEADERS), registry=reg_a, now=1000.0)
        # Rotation lands token B 10s later — B has NO cooldown entry.
        reg_b = _registry(tmp, MOCK_TOKEN_B)
        calls = {"n": 0}
        res_b = _run(tmp, http_get=_stub_ok(OK_BODY, calls=calls), registry=reg_b, now=1010.0)
        check(calls["n"] == 1, "token B's first probe goes out immediately (no inherited cooldown)")
        check(res_b["status"] == "written", "token B writes a real reading")

    print("[B3] a clean reading clears the token's cooldown streak")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        edge_403 = _stub_http_error(403, CF_403_BODY, None, headers=CF_HEADERS)
        _run(tmp, http_get=edge_403, registry=reg, now=1000.0)   # streak 1 → 300s
        ok_res = _run(tmp, http_get=_stub_ok(OK_BODY), registry=reg, now=1400.0)
        check(ok_res["status"] == "written", "clean reading after the window writes")
        r_next = _run(tmp, http_get=edge_403, registry=reg, now=1500.0)
        check(r_next["cooldown_seconds"] == 300.0, "streak restarted after success (back to 300s, not 900s)")

    # ================= (C) synthetic-signal alert isolation =================
    print("[C1] 429-signal cache → rotation candidate YES, operator alert NO")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0, headers=ANTHROPIC_HEADERS), registry=reg)
        check(res["status"] == "rate-limited-signal", "signal cache persisted")
        cache_path = Path(res["cache_path"])
        out = _monitor_run(cache_path, tmp / "monitor-state.json")
        check(len(out.get("rotation_candidates") or []) >= 1, "monitor still surfaces the rotation candidate")
        check(out.get("alerts") == [], "monitor emits ZERO operator alerts for the synthetic signal (no alert storm)")
        snaps = [s for s in out.get("snapshots") or [] if s.get("provider") == "claude"]
        check(all(s.get("signal") == "rate_limit_429" for s in snaps), "snapshots carry the signal marker")

    print("[C2] positive control: a REAL at-limit reading still alerts")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_ok(AT_LIMIT_BODY), registry=reg)
        check(res["status"] == "written", "real at-limit reading written")
        out = _monitor_run(Path(res["cache_path"]), tmp / "monitor-state.json")
        check(len(out.get("alerts") or []) >= 1, "real readings still produce operator alerts")
        check(len(out.get("rotation_candidates") or []) >= 1, "and still rotate")

    # ================= (D) cache token attribution ==========================
    print("[D1] probe freshness gate: a fresh cache from a PREVIOUS token is stale → re-probe")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg_a = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0, headers=ANTHROPIC_HEADERS), registry=reg_a, now=1000.0)
        cache_path = Path(res["cache_path"])
        os.utime(cache_path, (1000.0, 1000.0))
        # Same token, within max_age → fresh (no call).
        calls = {"n": 0}
        r_same = _run(tmp, http_get=_stub_ok(OK_BODY, calls=calls), registry=reg_a, now=1100.0, max_age=300.0)
        check(r_same["status"] == "fresh", "same active token → cache is fresh")
        check(calls["n"] == 0, "no call while fresh")
        # Rotated to B: digest mismatch → NOT fresh → re-probe NOW.
        reg_b = _registry(tmp, MOCK_TOKEN_B)
        calls = {"n": 0}
        r_rot = _run(tmp, http_get=_stub_ok(OK_BODY, calls=calls), registry=reg_b, now=1100.0, max_age=300.0)
        check(calls["n"] == 1, "rotated-in token re-probes immediately (stale attribution)")
        check(r_rot["status"] == "written", "and replaces the inherited synthetic with a real reading")

    print("[D2] monitor: a synthetic signal from a previously-active token is DROPPED; real readings fail open")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        dig_a = probe._token_signal_digest(MOCK_TOKEN_A)
        dig_b = probe._token_signal_digest(MOCK_TOKEN_B)
        cache_path = tmp / ".usage-cache.json"
        signal_cache = probe.build_rate_limit_signal_cache("2026-06-12T18:00:00+00:00", dig_a)
        cache_path.write_text(json.dumps(signal_cache), encoding="utf-8")
        out_stale = _monitor_run(cache_path, tmp / "ms1.json", active_token_digest=dig_b)
        claude_stale = [s for s in out_stale.get("snapshots") or [] if s.get("provider") == "claude"]
        check(claude_stale == [], "mismatched digest → synthetic snapshots dropped (no ping-pong)")
        check(out_stale.get("rotation_candidates") == [], "no rotation candidate from the stale synthetic")
        out_match = _monitor_run(cache_path, tmp / "ms2.json", active_token_digest=dig_a)
        check(len(out_match.get("rotation_candidates") or []) >= 1, "matching digest → the signal still rotates")
        # Real reading (no _signal) attributed to A while B is active → kept.
        real_cache = probe.map_payload_to_cache(AT_LIMIT_BODY, token_digest=dig_a)
        cache_path.write_text(json.dumps(real_cache), encoding="utf-8")
        out_real = _monitor_run(cache_path, tmp / "ms3.json", active_token_digest=dig_b)
        claude_real = [s for s in out_real.get("snapshots") or [] if s.get("provider") == "claude"]
        check(len(claude_real) >= 1, "real readings are NOT dropped on digest mismatch (fail-open)")

    print("[D3] active-token-digest CLI prints the digest, never the token")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        import contextlib
        import io

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            probe.main(["active-token-digest", "--registry-path", str(reg)])
        out = buf.getvalue().strip()
        check(out == probe._token_signal_digest(MOCK_TOKEN_A), "CLI digest matches _token_signal_digest")
        check(MOCK_TOKEN_A not in out and MOCK_TOKEN_A[-4:] not in out, "no token material on stdout")
        buf2 = io.StringIO()
        with contextlib.redirect_stdout(buf2):
            probe.main(["active-token-digest", "--registry-path", str(tmp / "missing.json")])
        check(buf2.getvalue().strip() == "", "absent registry prints nothing (caller skips the guard)")

    # ================= (E) statusLine-tap priority ==========================
    print("[E] a FRESH stdin-tap cache satisfies the freshness gate; a STALE one does not")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        tap_cache = {
            "data": {"planName": "subscription", "fiveHour": 37.0, "sevenDay": 12.0,
                     "fiveHourResetAt": "2026-06-12T18:00:00+00:00", "sevenDayResetAt": None},
            "_source": "stdin-tap",
        }
        cache_path.write_text(json.dumps(tap_cache), encoding="utf-8")
        os.utime(cache_path, (5000.0, 5000.0))
        calls = {"n": 0}
        r_fresh = _run(tmp, http_get=_stub_ok(OK_BODY, calls=calls), registry=reg, now=5100.0, max_age=300.0)
        check(r_fresh["status"] == "fresh", "live tap data (age 100s < 300s) → probe stands down")
        check(calls["n"] == 0, "probe did not overwrite the real measured tap reading")
        check(json.loads(cache_path.read_text())["data"]["fiveHour"] == 37.0, "tap reading intact")
        # Stale tap (statusLine gone / headless) → probe takes over.
        calls = {"n": 0}
        r_stale = _run(tmp, http_get=_stub_ok(OK_BODY, calls=calls), registry=reg, now=5500.0, max_age=300.0)
        check(calls["n"] == 1, "stale tap cache (age 500s) no longer suppresses the probe")
        check(r_stale["status"] == "written", "probe refreshed the cache on the headless path")

    # ================= (F) audit TSV `-` sentinel ===========================
    print("[F] usage-probe-result-parse emits `-` for empty columns (no field collapse)")

    class _A:
        pass

    def _parse(obj):
        ns = _A()
        ns.probe_json = json.dumps(obj)
        import contextlib
        import io

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            helpers.cmd_usage_probe_result_parse(ns)
        return buf.getvalue().rstrip("\n")

    row = _parse({"status": "degraded", "http_status": 403})
    check(row == "degraded\t-\t-\t403\t-", f"degraded row uses `-` sentinels (got {row!r})")
    cols = row.split("\t")
    check(len(cols) == 5 and cols[3] == "403", "http_status stays in column 4 (no shift into reset_at)")
    edge_row = _parse({
        "status": "edge-blocked", "http_status": 429, "retry_after": 3600.0,
        "detail": json.dumps(RATE_LIMIT_BODY),
    })
    edge_cols = edge_row.split("\t")
    check(edge_cols[0] == "edge-blocked", "edge-blocked is a noteworthy audit status")
    check(len(edge_cols) == 5 and edge_cols[3] == "429", "edge row carries http_status in place")
    check("rate_limit_error" in edge_cols[4], "edge row carries the body snippet detail")
    sig_row = _parse({"status": "rate-limited-signal", "reset_at": "2026-06-12T18:00:00+00:00", "retry_after": 3143.0})
    check(sig_row.split("\t")[0] == "rate-limited-signal" and len(sig_row.split("\t")) == 5, "signal row keeps 5 columns")
    check(_parse({"status": "written"}) == "", "healthy ticks stay audit-silent")
    tabby = _parse({"status": "edge-blocked", "http_status": 403, "detail": "a\tb\nc"})
    check("\t".join(tabby.split("\t")[4:]) == "a b c", "tabs/newlines in detail are sanitized to spaces")

    # ============ credential safety on the new paths ========================
    print("[G] credential safety: token absent from edge results, cooldown state, digest output")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(429, CF_BLOCK_BODY, 3600.0, headers=CF_HEADERS), registry=reg)
        state_text = (tmp / "plugins" / "claude-hud" / probe.PROBE_STATE_BASENAME).read_text()
        for blob, name in ((json.dumps(res), "edge result"), (state_text, "probe-state (cooldown map)")):
            check(MOCK_TOKEN_A not in blob, f"token absent from the {name}")
            check(MOCK_TOKEN_A[-4:] not in blob, f"token tail absent from the {name}")

    if failures:
        print(f"[edge-classification-helper] {len(failures)} FAILED: {failures}")
        return 1
    print("[edge-classification-helper] all assertions PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
