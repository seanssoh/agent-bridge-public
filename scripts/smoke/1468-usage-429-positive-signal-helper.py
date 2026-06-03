#!/usr/bin/env python3
"""Mock-only harness for #1468 — usage-endpoint 429 as a POSITIVE signal.

Invoked by scripts/smoke/1468-usage-429-positive-signal.sh. NEVER makes a live
network call: every scenario injects a stub `http_get` into `run_probe` (the
seam exists precisely so CI stays offline). Uses ONLY mock token strings — never
a real credential — so the sandbox credential-redaction hook has nothing to
redact.

Coverage (maps to the brief's required smoke scenarios):
  (1) genuine 429 rate_limit_error (valid request, UA present) → the probe
      PERSISTS a near-limit usage cache (used_percent >= threshold, reset_at
      set, _source native-oauth-probe) instead of writing nothing.
  (2) the REAL monitor (bridge-usage.py) then surfaces that account as a
      rotation candidate at the operator's threshold.
  (3) TEETH — idempotence: a second 429 tick for the SAME window + SAME active
      token does NOT re-emit a re-rotating cache (status rate-limited-suppressed).
  (4) TEETH — failure classes do NOT produce a rotation signal:
        - a 429 whose body is NOT rate_limit_error (malformed/missing-UA proxy),
        - a 429 with an EMPTY body,
        - a 401,
        - a transport/network error.
      Each is a probe FAILURE (audited only) — the cache is left untouched.
  (5) reset_at is STABLE across ticks for the same window (no monitor latch
      churn that would re-rotate).
  (6) whole-pool case is BOUNDED: rotating to a NEW active token re-signals once
      (new token, same logical incident), but once a token is re-seen in the
      same window it is suppressed — so the pool is traversed at most once, not
      in a loop.
  (7) the daemon-helper result parser classifies the outcome for the audit row.
"""

from __future__ import annotations

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
usage = _load("bridge_usage", "bridge-usage.py")
helpers = _load("bridge_daemon_helpers", "bridge-daemon-helpers.py")

MOCK_TOKEN_A = "sk-ant-oat-MOCK-not-a-real-token-AAAA"
MOCK_TOKEN_B = "sk-ant-oat-MOCK-not-a-real-token-BBBB"

RATE_LIMIT_BODY = {"error": {"message": "Rate limited. Please try again later.", "type": "rate_limit_error"}}
# A 429 whose body is NOT rate_limit_error — the missing-UA / malformed-request
# reject the helper docstring warns about. Must NOT be a near-limit signal.
NOT_RATE_LIMIT_BODY = {"error": {"message": "User-Agent required.", "type": "invalid_request_error"}}

failures: list[str] = []


def check(cond: bool, label: str) -> None:
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}")
        failures.append(label)


def _stub_http_error(status, body_obj, retry_after):
    def _get(url, headers, timeout):
        # The probe always sends a valid UA — assert it so a "genuine" 429 in
        # these scenarios really is a valid request (distinguishes from missing-UA).
        assert headers.get("User-Agent", "").startswith("claude-code/"), "missing/bad UA"
        raise probe.ProbeHTTPError(
            status,
            body=("" if body_obj is None else json.dumps(body_obj)),
            retry_after=retry_after,
        )

    return _get


def _stub_network_error():
    def _get(url, headers, timeout):
        raise OSError("connection reset")

    return _get


def _stub_ok(body_obj):
    def _get(url, headers, timeout):
        return json.dumps(body_obj)

    return _get


def _registry(tmp: Path, active_token: str, *, name: str = "claude-oauth-tokens.json") -> Path:
    p = tmp / name
    p.write_text(
        json.dumps(
            {
                "active_token_id": "tok-a",
                "tokens": [
                    {"id": "tok-a", "token": active_token, "enabled": True},
                    {"id": "tok-b", "token": MOCK_TOKEN_B, "enabled": True},
                ],
            }
        ),
        encoding="utf-8",
    )
    return p


def _monitor_candidates_for(cache_path: Path, state_path: Path, *, rotation_threshold=99.0):
    """Drive the REAL bridge-usage.py monitor on a single cache + state file and
    return its rotation_candidates. Used to verify a 429-signal reaches the
    actual rotation path (not just a probe status)."""
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
    ns.state_file = str(state_path)
    ns.json = True
    import io
    import contextlib

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        usage.cmd_monitor(ns)
    return json.loads(buf.getvalue() or "{}").get("rotation_candidates") or []


def _run(tmp: Path, *, http_get, registry=None, now=1000.0, max_age=0.0, cooldown=0.0, retry_cap=5.0):
    cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
    return probe.run_probe(
        cache_path=cache_path,
        registry_path=registry,
        credentials_path=None,
        user_agent_version="2.1.0",
        max_age_seconds=max_age,
        cooldown_seconds=cooldown,
        http_timeout=10.0,
        retry_after_cap=retry_cap,
        now=now,
        http_get=http_get,
        log=lambda m: None,
    )


def main() -> int:
    rot_thr = 99.0  # the default operator rotation threshold

    # ---- (1) genuine 429 rate_limit_error → near-limit cache persisted -------
    print("[1] genuine 429 rate_limit_error → near-limit cache persisted")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        # Retry-After far above the 5s cap (the original bail trigger).
        res = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg, now=1000.0)
        check(res["status"] == "rate-limited-signal", "status is rate-limited-signal")
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        check(cache_path.is_file(), "a cache file was written (was: nothing)")
        cache = json.loads(cache_path.read_text())
        check(cache["data"]["fiveHour"] >= rot_thr, f"fiveHour {cache['data']['fiveHour']} >= threshold {rot_thr}")
        check(cache["_source"] == "native-oauth-probe", "_source is native-oauth-probe (monitor consumes it)")
        check(cache["_signal"] == "rate_limit_429", "_signal marks it as a 429-derived signal")
        check(bool(cache["data"]["fiveHourResetAt"]), "reset_at is set (derived from Retry-After)")
        # reset_at = now + retry_after (quantized to whole seconds).
        check(cache["data"]["fiveHourResetAt"] == res["reset_at"], "result reset_at == cache reset_at")

    # ---- (2) the REAL monitor surfaces it as a rotation candidate ------------
    print("[2] real monitor (bridge-usage.py) surfaces the 429 signal as a rotation candidate")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg, now=1000.0)
        cache_path = Path(res["cache_path"])
        # native_snapshots only reads a _source==native-oauth-probe cache.
        snaps = usage.native_snapshots(cache_path, warn=90.0, critical=100.0)
        check(len(snaps) >= 1, "monitor produced native snapshots from the signal cache")
        worst = max((s["used_percent"] for s in snaps if isinstance(s["used_percent"], (int, float))), default=-1)
        check(worst >= rot_thr, f"a window crosses the rotation threshold ({worst} >= {rot_thr})")
        # Every native snapshot is tagged so the monitor latches it independently.
        check(all(s["source"] == "native-oauth-probe" for s in snaps), "snapshots tagged native-oauth-probe")

    # ---- (3) TEETH idempotence: 2nd 429 same window+token → suppressed -------
    print("[3] TEETH: a 2nd 429 for the SAME window + active token does NOT re-rotate")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        # Tick 1 — emits the signal.
        r1 = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg, now=1000.0)
        check(r1["status"] == "rate-limited-signal", "tick1 emits the signal")
        reset1 = r1["reset_at"]
        # Tick 2 — SAME active token, the window reset_at recomputes to the SAME
        # value only if `now` is unchanged; advance `now` slightly to prove the
        # dedupe keys on the window, not on exact equality. Use the same Retry-
        # After so the window lands in the same logical incident. The probe must
        # SUPPRESS the re-emit (idempotent per window+token).
        # First, make tick2 land in the SAME window: reuse now so reset_at matches.
        r2 = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg, now=1000.0)
        check(r2["status"] == "rate-limited-suppressed", "tick2 (same window+token) is suppressed")
        check(r2["reset_at"] == reset1, "tick2 resolves the same window reset_at")

    # ---- (3b) TEETH idempotence under a CONSTANT Retry-After (drift) ---------
    # The hard case: a server that returns a CONSTANT Retry-After (does NOT count
    # it down). A naive `now + retry_after` would drift forward each tick and the
    # monitor's reset-cycle latch would re-fire rotation — the pool-loop hazard.
    # The probe must REUSE the still-future recorded window for the same token,
    # so the second tick (now ADVANCED, same constant Retry-After) is suppressed.
    print("[3b] TEETH: same token, CONSTANT Retry-After, now advanced → still suppressed")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        r1 = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg, now=1000.0)
        check(r1["status"] == "rate-limited-signal", "tick1 emits the signal")
        reset1 = r1["reset_at"]
        # Tick 2: now advanced by 600s (a later daemon tick), SAME constant
        # Retry-After. A naive recompute would give a window 600s later (a new
        # cycle) → re-rotate. The probe must reuse the still-future window.
        r2 = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg, now=1600.0)
        check(r2["status"] == "rate-limited-suppressed", "tick2 (now+600, const Retry-After) is suppressed")
        check(r2["reset_at"] == reset1, "tick2 reuses the still-future window (no drift)")

    # ---- (4) TEETH failure classes: NO rotation signal -----------------------
    print("[4] TEETH: failure classes produce NO rotation signal (probe failure, cache untouched)")
    failure_cases = [
        ("429 non-rate-limit body (malformed/missing-UA proxy)", _stub_http_error(429, NOT_RATE_LIMIT_BODY, 3143.0)),
        ("429 empty body", _stub_http_error(429, None, 3143.0)),
        ("401 unauthorized", _stub_http_error(401, {"error": {"type": "authentication_error"}}, None)),
        ("transport/network error", _stub_network_error()),
    ]
    for label, stub in failure_cases:
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            reg = _registry(tmp, MOCK_TOKEN_A)
            res = _run(tmp, http_get=stub, registry=reg, now=1000.0)
            check(res["status"] == "degraded", f"{label} → degraded (probe failure)")
            cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
            check(not cache_path.is_file(), f"{label} → NO cache fabricated (no rotation signal)")

    # ---- (5) reset_at stability across ticks (same window) -------------------
    print("[5] reset_at is STABLE across ticks for the same window (no latch churn)")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        a = probe._signal_reset_at(3143.0, 1000.0)
        b = probe._signal_reset_at(3143.0, 1000.0)
        check(a == b, "same (retry_after, now) → identical reset_at")
        # whole-second quantization: sub-second now jitter does not move reset_at.
        c = probe._signal_reset_at(3143.0, 1000.4)
        check(a == c, "sub-second now jitter is quantized away (stable reset_at)")

    # ---- (6) whole-pool case is BOUNDED (rotate-once-per-token, then stop) ----
    # codex r1+r2 BLOCKING: the pool MUST be traversed AT MOST ONCE even with
    # ADVANCING `now` + a CONSTANT Retry-After (the realistic daemon cadence: the
    # native cache is fresh for 5min, so each rotated-to token's 429 is observed
    # at a LATER `now`). Two halves:
    #   - r2: each DISTINCT (rotated-to) token must signal once so the daemon can
    #     walk A→B→C until it lands on a non-limited token (B's signal must reach
    #     the REAL monitor as a NEW rotation candidate, not just a probe status).
    #   - r1: the SAME token re-seen on the loop-back must be SUPPRESSED — a
    #     constant Retry-After must not drift ITS window forward and re-rotate it.
    print("[6] whole-pool 429, advancing now + constant Retry-After: A signals, B signals (NEW monitor candidate), A loop-back suppressed")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg_a = _registry(tmp, MOCK_TOKEN_A)
        stub = _stub_http_error(429, RATE_LIMIT_BODY, 3143.0)  # CONSTANT Retry-After
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        mon_state = tmp / "monitor-state.json"

        # Token A 429 at t0 → signal. Then a monitor pass rotates A (latches).
        ra = _run(tmp, http_get=stub, registry=reg_a, now=1000.0)
        check(ra["status"] == "rate-limited-signal", "token A signals once (t0)")
        win_a = ra["reset_at"]
        cand_a = _monitor_candidates_for(cache_path, mon_state)
        check(len(cand_a) >= 1, "monitor emits a rotation candidate for token A (latches)")
        # Daemon rotates A→B; B's 429 observed ~300s LATER. B must anchor its OWN
        # window (distinct, advanced) so the monitor clears the latch + rotates B.
        reg_b = _registry(tmp, MOCK_TOKEN_B)
        rb = _run(tmp, http_get=stub, registry=reg_b, now=1300.0)
        check(rb["status"] == "rate-limited-signal", "token B (new active) signals once (t0+300)")
        check(rb["reset_at"] != win_a, "token B anchors its OWN distinct window (so the monitor rotates B)")
        cand_b = _monitor_candidates_for(cache_path, mon_state)
        check(len(cand_b) >= 1, "monitor emits a NEW rotation candidate for token B (latch cleared by advanced reset_at)")
        # Pool loops back to A (re-activated) ANOTHER ~300s later → A still has a
        # FUTURE window → SUPPRESS (no write) → the monitor sees B's latched cache
        # → NO new candidate. The pool is traversed at most once.
        ra2 = _run(tmp, http_get=stub, registry=reg_a, now=1600.0)
        check(ra2["status"] == "rate-limited-suppressed", "re-seen token A (t0+600) → suppressed (no loop)")
        cand_loop = _monitor_candidates_for(cache_path, mon_state)
        check(len(cand_loop) == 0, "loop-back produces NO new monitor candidate (pool traversed at most once)")

    # ---- (6c) codex r3: COUNTING-DOWN Retry-After → EQUAL reset_at, B still rotates
    # The hard case codex r3 caught: a well-behaved server COUNTS DOWN Retry-After
    # so two tokens 429'd at different `now` land on the SAME real reset time →
    # the same synthetic reset_at. The monitor's reset_at-advance rule alone would
    # NOT clear the latch → token B would never rotate. The `_signal_token`
    # discriminator must clear the latch when the SIGNAL TOKEN changes, so B
    # rotates once even at an equal reset_at — while loop-back to A stays bounded.
    print("[6c] codex r3: COUNTING-DOWN Retry-After (EQUAL reset_at) → token B STILL rotates once via signal_token")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        mon_state = tmp / "monitor-state.json"
        # A at t0 with retry=3143 → reset 4143. B at t0+300 with retry=2843 →
        # reset 4143 (EQUAL). Counting down: same real reset window.
        reg_a = _registry(tmp, MOCK_TOKEN_A)
        ra = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg_a, now=1000.0)
        check(ra["status"] == "rate-limited-signal", "token A signals (t0)")
        win_a = ra["reset_at"]
        check(len(_monitor_candidates_for(cache_path, mon_state)) >= 1, "monitor rotates A (latches)")
        reg_b = _registry(tmp, MOCK_TOKEN_B)
        rb = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 2843.0), registry=reg_b, now=1300.0)
        check(rb["status"] == "rate-limited-signal", "token B signals (t0+300)")
        check(rb["reset_at"] == win_a, "B lands on the SAME reset_at as A (counting-down server)")
        cand_b = _monitor_candidates_for(cache_path, mon_state)
        check(len(cand_b) >= 1, "monitor STILL rotates B at the EQUAL reset_at (signal_token discriminator)")
        # Loop-back to A at the same reset window → A still has a future window →
        # suppressed at the probe → monitor sees B's latched cache → no candidate.
        ra2 = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 2543.0), registry=reg_a, now=1600.0)
        check(ra2["status"] == "rate-limited-suppressed", "loop-back to A suppressed (no re-rotate)")
        check(len(_monitor_candidates_for(cache_path, mon_state)) == 0, "no new candidate on loop-back (bounded)")

    # ---- (6d) codex r4: REAL-reading rotation (signal_token=None) then a 429 ---
    # signal for a NEW token at the SAME reset_at must STILL rotate. The hazard:
    # a prior monitor rotation triggered by a REAL reading records
    # rotation_triggered_signal_token=None; if A→B rotates and B then 429s at the
    # SAME reset_at, the token-change clear must still fire (None differs from B's
    # real digest) so B rotates — it must NOT require a non-None prior token.
    print("[6d] codex r4: real-reading latch (signal_token=None) then 429 for a new token at SAME reset_at → STILL rotates")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        mon_state = tmp / "monitor-state.json"
        reset_iso = "2026-06-03T18:00:00+00:00"
        # A REAL reading already AT-limit (a real 100% reading, not a 429-signal)
        # at reset R → the monitor rotates with signal_token=None.
        real_at_limit = {"five_hour": {"utilization": 100.0, "resets_at": reset_iso},
                         "seven_day": {"utilization": 100.0, "resets_at": reset_iso}}
        reg_a = _registry(tmp, MOCK_TOKEN_A)
        r_real = _run(tmp, http_get=_stub_ok(real_at_limit), registry=reg_a, now=1000.0)
        check(r_real["status"] == "written", "real at-limit reading written (signal_token absent)")
        cand_real = _monitor_candidates_for(cache_path, mon_state)
        check(len(cand_real) >= 1, "monitor rotates on the real reading (latch token=None)")
        # Daemon rotates A→B; B then 429s. resolve_token_window anchors B's window
        # from now+Retry-After — to force the EQUAL-reset_at case, make B's window
        # equal R by choosing retry_after so now(1300)+retry == reset R.
        # Compute retry so the synthetic reset_at == reset_iso.
        from datetime import datetime as _dt, timezone as _tz
        r_epoch = int(_dt.fromisoformat(reset_iso).timestamp())
        retry_b = float(r_epoch - 1300)
        reg_b = _registry(tmp, MOCK_TOKEN_B)
        r_b = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, retry_b), registry=reg_b, now=1300.0)
        check(r_b["status"] == "rate-limited-signal", "token B 429-signals after the real-reading rotation")
        check(r_b["reset_at"] == reset_iso, "B's 429 window == the real reading's reset_at (equal-reset case)")
        cand_b = _monitor_candidates_for(cache_path, mon_state)
        check(len(cand_b) >= 1, "monitor STILL rotates B at the equal reset_at after a real-reading latch (codex r4)")

    # ---- (6b) a clean reading clears the dedupe (later window can re-signal) --
    print("[6b] a clean reading clears the per-window dedupe")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        r1 = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg, now=1000.0)
        check(r1["status"] == "rate-limited-signal", "tick1 signals")
        # A clean reading on the active token (it is no longer limited).
        ok_body = {"five_hour": {"utilization": 5.0, "resets_at": "2026-06-01T18:00:00+00:00"},
                   "seven_day": {"utilization": 2.0, "resets_at": "2026-06-07T00:00:00+00:00"}}
        r2 = _run(tmp, http_get=_stub_ok(ok_body), registry=reg, now=1000.0)
        check(r2["status"] == "written", "tick2 reads cleanly and writes the real cache")
        # A subsequent 429 (new incident) re-signals because the dedupe was cleared.
        r3 = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg, now=1000.0)
        check(r3["status"] == "rate-limited-signal", "after a clean reading a later 429 re-signals")

    # ---- (7) the daemon-helper classifies the outcome for the audit row ------
    print("[7] usage-probe-result-parse classifies noteworthy outcomes for the audit row")

    class _A:
        pass

    def _parse(obj):
        ns = _A()
        ns.probe_json = json.dumps(obj)
        import io
        import contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            helpers.cmd_usage_probe_result_parse(ns)
        return buf.getvalue().strip()

    sig_row = _parse({"status": "rate-limited-signal", "reset_at": "2026-06-01T00:00:00+00:00", "retry_after": 3143.0})
    check(sig_row.split("\t")[0] == "rate-limited-signal", "429-signal → noteworthy audit row")
    sup_row = _parse({"status": "rate-limited-suppressed", "reset_at": "x", "retry_after": 3143.0})
    check(sup_row.split("\t")[0] == "rate-limited-suppressed", "suppressed → noteworthy audit row")
    deg_row = _parse({"status": "degraded", "http_status": 401})
    check(deg_row.split("\t")[0] == "degraded", "probe failure → noteworthy audit row")
    # Healthy ticks produce NO audit row (audit-silent on the common path).
    check(_parse({"status": "written", "fiveHour": 5.0}) == "", "written → no audit row (silent)")
    check(_parse({"status": "fresh"}) == "", "fresh → no audit row (silent)")
    check(_parse({"status": "cooldown"}) == "", "cooldown → no audit row (silent)")

    # ---- (8) credential safety: token never persisted in cache/state/result --
    print("[8] credential safety: the token never appears in cache, probe-state, or result")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        res = _run(tmp, http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3143.0), registry=reg, now=1000.0)
        cache_text = (tmp / "plugins" / "claude-hud" / ".usage-cache.json").read_text()
        state_text = (tmp / "plugins" / "claude-hud" / ".usage-probe-state.json").read_text()
        result_text = json.dumps(res)
        for blob, name in ((cache_text, "cache"), (state_text, "probe-state"), (result_text, "result")):
            check(MOCK_TOKEN_A not in blob, f"token absent from the {name}")
            # The token's last-4 must not appear either (the digest is hash-only).
            check(MOCK_TOKEN_A[-4:] not in blob, f"token tail absent from the {name} (digest is hash-only)")

    if failures:
        print(f"[1468-helper] {len(failures)} FAILED: {failures}")
        return 1
    print("[1468-helper] all assertions PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
