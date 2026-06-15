#!/usr/bin/env python3
"""Mock-only test harness for the native usage probe (#1437 PRIMARY).

Invoked by scripts/smoke/1437-native-usage-probe.sh. NEVER makes a live
network call: every scenario injects a stub `http_get` into `run_probe`
(the seam exists precisely so CI stays offline). Uses ONLY mock token
strings — never a real credential — so the sandbox credential-redaction
hook has nothing to redact.

Coverage (maps to the brief's smoke scenarios a–e):
  a) Fixture-1 raw → mapped cache shape correct (utilization → fiveHour,
     0–100 preserved, resets_at carried through).
  b) a 92% five_hour flags a rotation candidate at a 90% threshold through
     the REAL bridge-usage.py monitor path, while a 47.5% seven_day does not.
  c) degraded payload (null five_hour) → no crash, seven_day still emitted.
  d) 429 body → backoff/cooldown honored, stale cache served, no crash.
  e) cache freshness (within CACHE_MAX_AGE → no re-probe).
Plus:
  f) token resolution: registry active token preferred; credentials-file
     fallback; missing-token degrade.
  g) scope guard: empty/null windows → scope-degraded, NO cache written.
  h) credential safety: the token never appears in the written cache, the
     probe-state sidecar, or the returned result dict.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Import the probe module by file path (hyphenated filename → not importable
# by name). Mirrors how the other smokes load hyphenated bridge-*.py modules.
_spec = importlib.util.spec_from_file_location(
    "bridge_usage_probe", str(REPO_ROOT / "bridge-usage-probe.py")
)
probe = importlib.util.module_from_spec(_spec)  # type: ignore[arg-type]
assert _spec and _spec.loader
_spec.loader.exec_module(probe)  # type: ignore[union-attr]

# Import the REAL monitor module too, so scenario (b) exercises the actual
# consumer path (no re-implementation of the threshold logic).
_uspec = importlib.util.spec_from_file_location(
    "bridge_usage", str(REPO_ROOT / "bridge-usage.py")
)
usage = importlib.util.module_from_spec(_uspec)  # type: ignore[arg-type]
assert _uspec and _uspec.loader
_uspec.loader.exec_module(usage)  # type: ignore[union-attr]

MOCK_TOKEN = "sk-ant-oat-MOCK-not-a-real-token-0000"

# Brief-provided fixtures (verbatim).
FIXTURE_1 = {
    "five_hour": {"utilization": 92.0, "resets_at": "2026-06-01T18:00:00.000000+00:00"},
    "seven_day": {"utilization": 47.5, "resets_at": "2026-06-07T00:00:00.000000+00:00"},
    "seven_day_opus": None,
    "seven_day_sonnet": {"utilization": 12.0, "resets_at": "2026-06-06T03:00:00.000000+00:00"},
    "extra_usage": {"is_enabled": False, "monthly_limit": None, "used_credits": None, "utilization": None},
}
FIXTURE_3 = {
    "five_hour": None,
    "seven_day": {"utilization": 5.0, "resets_at": "2026-06-07T00:00:00.000000+00:00"},
    "extra_usage": {"is_enabled": False},
}
FIXTURE_4_429 = {"error": {"message": "Rate limited. Please try again later.", "type": "rate_limit_error"}}

# Empty-windows payload → user:profile scope guard (g).
FIXTURE_SCOPE = {"five_hour": None, "seven_day": None, "extra_usage": {"is_enabled": False}}

failures: list[str] = []


def check(cond: bool, label: str) -> None:
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}")
        failures.append(label)


def _stub_ok(body_obj):
    def _get(url, headers, timeout):
        # Assert the mandatory headers are present on every request.
        assert headers.get("User-Agent", "").startswith("claude-code/"), "missing/bad User-Agent"
        assert headers.get("anthropic-beta") == "oauth-2025-04-20", "missing anthropic-beta"
        assert headers.get("Authorization", "").startswith("Bearer "), "missing Authorization"
        return json.dumps(body_obj)

    return _get


def _stub_429(retry_after, then_obj=None):
    state = {"calls": 0}

    def _get(url, headers, timeout):
        state["calls"] += 1
        if state["calls"] == 1:
            raise probe.ProbeHTTPError(429, body=json.dumps(FIXTURE_4_429), retry_after=retry_after)
        if then_obj is not None:
            return json.dumps(then_obj)
        raise probe.ProbeHTTPError(429, body=json.dumps(FIXTURE_4_429), retry_after=retry_after)

    return _get, state


def _run(tmp: Path, *, http_get, registry=None, credentials=None, now=1000.0, max_age=300.0, cooldown=60.0):
    cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
    return probe.run_probe(
        cache_path=cache_path,
        registry_path=registry,
        credentials_path=credentials,
        user_agent_version="2.1.0",
        max_age_seconds=max_age,
        cooldown_seconds=cooldown,
        http_timeout=10.0,
        retry_after_cap=5.0,
        now=now,
        http_get=http_get,
        log=lambda m: None,
    )


def _registry_with_active(tmp: Path, token: str) -> Path:
    p = tmp / "claude-oauth-tokens.json"
    p.write_text(
        json.dumps(
            {
                "active_token_id": "tok-a",
                "tokens": [
                    {"id": "tok-b", "token": "OTHER-mock", "enabled": True},
                    {"id": "tok-a", "token": token, "enabled": True},
                ],
            }
        ),
        encoding="utf-8",
    )
    return p


def _credentials_file(tmp: Path, token: str) -> Path:
    p = tmp / ".credentials.json"
    p.write_text(json.dumps({"claudeAiOauth": {"accessToken": token}}), encoding="utf-8")
    return p


def main() -> int:
    # ---- (a) raw → mapped cache shape ------------------------------------
    print("[a] Fixture-1 raw → mapped cache shape")
    cache = probe.map_payload_to_cache(FIXTURE_1)
    check(cache is not None, "map returns a cache")
    data = (cache or {}).get("data", {})
    check(data.get("fiveHour") == 92.0, "utilization 92 → fiveHour 92 (no scaling)")
    check(data.get("sevenDay") == 47.5, "utilization 47.5 → sevenDay 47.5 (no scaling)")
    check(data.get("fiveHourResetAt") == FIXTURE_1["five_hour"]["resets_at"], "five_hour resets_at carried")
    check(data.get("sevenDayResetAt") == FIXTURE_1["seven_day"]["resets_at"], "seven_day resets_at carried")
    check((cache or {}).get("_source") == "native-oauth-probe", "_source tag set")

    # ---- (b) monitor flags a rotation candidate at 92% / 90% threshold ----
    print("[b] real monitor path: 92% five_hour rotates @90%, 47.5% does not")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry_with_active(tmp, MOCK_TOKEN)
        res = _run(tmp, http_get=_stub_ok(FIXTURE_1), registry=reg)
        check(res["status"] == "written", "probe wrote the cache")
        cache_path = Path(res["cache_path"])
        snaps = usage.claude_snapshots(cache_path, warn=90.0, critical=100.0)
        by_window = {s["window"]: s for s in snaps}
        check(by_window["5h"]["used_percent"] == 92.0, "monitor reads 5h used_percent 92")
        # rotation candidate logic: used_percent >= rotation_threshold.
        rot_thr = 90.0
        five_rotates = by_window["5h"]["used_percent"] >= rot_thr
        seven_rotates = by_window["weekly"]["used_percent"] >= rot_thr
        check(five_rotates is True, "5h @92 is a rotation candidate at 90% threshold")
        check(seven_rotates is False, "weekly @47.5 is NOT a rotation candidate at 90%")

    # ---- (c) degraded payload (null five_hour) ---------------------------
    print("[c] null five_hour → no crash, seven_day still emitted")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry_with_active(tmp, MOCK_TOKEN)
        res = _run(tmp, http_get=_stub_ok(FIXTURE_3), registry=reg)
        check(res["status"] == "written", "degraded payload still writes (seven_day present)")
        written = json.loads(Path(res["cache_path"]).read_text())
        check(written["data"]["fiveHour"] is None, "fiveHour is null (skipped)")
        check(written["data"]["sevenDay"] == 5.0, "sevenDay carried through")

    # ---- (d) genuine 429 rate_limit_error → near-limit SIGNAL (#1468) -----
    # Behavior change (#1468): a 429 whose body is a genuine `rate_limit_error`
    # (valid request, UA present) is no longer "serve stale / give up" — it is a
    # POSITIVE near-limit signal. The probe PERSISTS a synthetic near-limit cache
    # (AT-LIMIT, _source native-oauth-probe) so proactive rotation fires, instead
    # of going blind (the catch-22 break). The cooldown still applies after the
    # signalled attempt. The dedicated 1468 smoke covers idempotence + the
    # failure-class teeth; here we pin the core contract + the cooldown.
    print("[d] 429 rate_limit_error → near-limit SIGNAL persisted, cooldown holds (#1468)")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry_with_active(tmp, MOCK_TOKEN)
        # Seed a stale low-% native cache; the 429 signal must OVERWRITE it with
        # the at-limit reading (it is now evidence the account is limited).
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        stale = {"data": {"fiveHour": 10.0, "sevenDay": 1.0}, "_source": "native-oauth-probe"}
        cache_path.write_text(json.dumps(stale), encoding="utf-8")
        os.utime(cache_path, (1900.0, 1900.0))
        # 429 with NO usable Retry-After → still a genuine rate_limit_error →
        # near-limit signal with a fallback window.
        get429, _ = _stub_429(retry_after=None)
        res = _run(tmp, http_get=get429, registry=reg, now=2000.0, max_age=0.0)
        check(res["status"] == "rate-limited-signal", "429 rate_limit_error → rate-limited-signal")
        after = json.loads(cache_path.read_text())
        check(after["data"]["fiveHour"] == 100.0, "near-limit (100%) signal cache persisted on 429")
        check(after["_source"] == "native-oauth-probe", "signal cache carries the native source marker")
        check(after["_signal"] == "rate_limit_429", "signal cache marked as a 429 signal")
        check(bool(after["data"]["fiveHourResetAt"]), "signal cache carries a reset_at window")
        # Now a SECOND probe within the cooldown window must NOT re-probe.
        marker = {"called": False}

        def _should_not_run(url, headers, timeout):
            marker["called"] = True
            return "{}"

        res2 = _run(tmp, http_get=_should_not_run, registry=reg, now=2030.0, max_age=0.0, cooldown=60.0)
        # The account-quota 429 now arms the same Retry-After-bounded backoff as
        # an edge block AND leaves a live near-limit signal window, so the next
        # in-window tick is reported with the #1468 suppression status (it still
        # serves stale and makes NO network call — the property under test).
        check(res2["status"] == "rate-limited-suppressed", "second probe within the backoff window is suppressed (live signal window)")
        check(marker["called"] is False, "the in-window tick prevented a second network call")

    # ---- (d2) 429 WITH a short Retry-After → single capped retry succeeds -
    print("[d2] 429 + Retry-After=0 → single retry then success")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry_with_active(tmp, MOCK_TOKEN)
        get429, state = _stub_429(retry_after=0.0, then_obj=FIXTURE_1)
        res = _run(tmp, http_get=get429, registry=reg, max_age=0.0)
        check(res["status"] == "written", "retry after 429 wrote the cache")
        check(state["calls"] == 2, "exactly one retry was made")

    # ---- (e) cache freshness → no re-probe -------------------------------
    print("[e] fresh native cache within CACHE_MAX_AGE → no re-probe")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry_with_active(tmp, MOCK_TOKEN)
        # First probe writes a fresh native cache at now=5000.
        res1 = _run(tmp, http_get=_stub_ok(FIXTURE_1), registry=reg, now=5000.0, max_age=300.0)
        check(res1["status"] == "written", "initial probe wrote cache")
        # Align the written cache's mtime with the synthetic clock so the
        # freshness gate ages it against `now` consistently (production uses a
        # real clock for both mtime and now, so this only matters under the
        # synthetic test clock).
        os.utime(Path(res1["cache_path"]), (5000.0, 5000.0))
        marker = {"called": False}

        def _should_not_run(url, headers, timeout):
            marker["called"] = True
            return "{}"

        # Second probe 100s later (< 300s max-age) must serve fresh, no call.
        res2 = _run(tmp, http_get=_should_not_run, registry=reg, now=5100.0, max_age=300.0)
        check(res2["status"] == "fresh", "within max-age → fresh (served from cache)")
        check(marker["called"] is False, "fresh cache prevented a network call")

    # ---- (f) token resolution priority -----------------------------------
    print("[f] token source: registry active preferred; cred-file fallback; missing degrades")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry_with_active(tmp, MOCK_TOKEN)
        cred = _credentials_file(tmp, "CRED-mock")
        # Registry active token wins.
        tok = probe.resolve_active_token(reg, cred)
        check(tok == MOCK_TOKEN, "registry active token preferred over cred-file")
        # No registry → cred-file fallback.
        tok2 = probe.resolve_active_token(None, cred)
        check(tok2 == "CRED-mock", "cred-file used when registry absent")
        # Neither → None (and run_probe degrades).
        res = _run(tmp, http_get=_stub_ok(FIXTURE_1), registry=tmp / "nope.json", credentials=tmp / "nope.json", max_age=0.0)
        check(res["status"] == "no-token", "missing token → no-token degrade, no crash")

    # ---- (g) scope guard: empty windows → scope-degraded, NO cache written
    print("[g] empty/null windows (user:profile scope missing) → scope-degraded, no write")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry_with_active(tmp, MOCK_TOKEN)
        res = _run(tmp, http_get=_stub_ok(FIXTURE_SCOPE), registry=reg, max_age=0.0)
        check(res["status"] == "scope-degraded", "both windows null → scope-degraded")
        check(not Path(res["cache_path"]).exists(), "no 0% cache fabricated on scope failure")

    # ---- (h) credential safety: token never persisted / returned ---------
    print("[h] credential safety: token absent from cache, sidecar, result dict")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry_with_active(tmp, MOCK_TOKEN)
        res = _run(tmp, http_get=_stub_ok(FIXTURE_1), registry=reg, max_age=0.0)
        check(MOCK_TOKEN not in json.dumps(res), "token NOT in result dict")
        cache_text = Path(res["cache_path"]).read_text()
        check(MOCK_TOKEN not in cache_text, "token NOT in written cache")
        sidecar = Path(res["cache_path"]).parent / probe.PROBE_STATE_BASENAME
        if sidecar.exists():
            check(MOCK_TOKEN not in sidecar.read_text(), "token NOT in probe-state sidecar")
        else:
            check(True, "probe-state sidecar absent (token trivially absent)")

    # ---- (i) BLOCKER 1: native cache is consumed ADDITIVELY in per-agent mode
    print("[i] #1437 r2 BLOCKER 1: native controller cache reaches rotation in per-agent mode")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        # Native controller cache: a 92% five_hour (what the probe would write).
        native_cache = tmp / "native" / ".usage-cache.json"
        native_cache.parent.mkdir(parents=True, exist_ok=True)
        native_cache.write_text(
            json.dumps(probe.map_payload_to_cache(FIXTURE_1)), encoding="utf-8"
        )
        # Per-agent payload with ONE isolated agent whose cache is ABSENT
        # (present=false) — this is the exact codex repro that previously
        # suppressed the controller cache and returned snapshots:[].
        per_agent = tmp / "per-agent.json"
        per_agent.write_text(
            json.dumps(
                [{"agent": "iso-a", "path": str(tmp / "iso-a.json"), "present": False, "payload": None}]
            ),
            encoding="utf-8",
        )
        import argparse as _argparse

        args = _argparse.Namespace(
            claude_usage_cache=str(native_cache),
            codex_sessions_dir=str(tmp / "nocodex"),
            warn_threshold=90.0,
            elevated_threshold=95.0,
            critical_threshold=100.0,
            per_agent_cache_json=str(per_agent),
            legacy_single_path=str(native_cache),
            native_usage_cache=str(native_cache),
        )
        snaps = usage.collect_snapshots(args)
        claude_snaps = [s for s in snaps if s.get("provider") == "claude"]
        check(len(claude_snaps) > 0, "per-agent mode no longer returns zero Claude snapshots")
        five = next((s for s in claude_snaps if s.get("window") == "5h"), None)
        check(five is not None and five.get("used_percent") == 92.0, "native 92% 5h snapshot present")
        check(
            five is not None and five.get("agent") == usage.NATIVE_PROBE_AGENT,
            "native snapshot tagged __native__ (independent latch key)",
        )
        # Drive the REAL monitor at a 90% rotation threshold → candidate appears.
        state_file = tmp / "monitor-state.json"
        margs = _argparse.Namespace(
            **vars(args),
            state_file=str(state_file),
            rotation_threshold=90.0,
            json=True,
        )
        import io
        import contextlib

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            usage.cmd_monitor(margs)
        out = json.loads(buf.getvalue())
        rot = out.get("rotation_candidates", [])
        check(len(rot) >= 1, "monitor emits a rotation candidate for the native 92% at 90% threshold")
        check(
            any(c.get("used_percent") == 92.0 for c in rot),
            "the rotation candidate is the native 92% 5h window",
        )

    # ---- (i2) dedupe: native path == a present per-agent path → no double-count
    print("[i2] dedupe: native cache that equals a present per-agent path is not double-counted")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        controller_cache = tmp / ".usage-cache.json"
        controller_cache.write_text(
            json.dumps(probe.map_payload_to_cache(FIXTURE_1)), encoding="utf-8"
        )
        # A non-isolated agent whose resolved cache path IS the controller cache.
        per_agent = tmp / "per-agent.json"
        per_agent.write_text(
            json.dumps(
                [
                    {
                        "agent": "shared-a",
                        "path": str(controller_cache),
                        "present": True,
                        "payload": probe.map_payload_to_cache(FIXTURE_1),
                    }
                ]
            ),
            encoding="utf-8",
        )
        import argparse as _argparse

        args = _argparse.Namespace(
            claude_usage_cache=str(controller_cache),
            codex_sessions_dir=str(tmp / "nocodex"),
            warn_threshold=90.0,
            elevated_threshold=95.0,
            critical_threshold=100.0,
            per_agent_cache_json=str(per_agent),
            legacy_single_path=str(controller_cache),
            native_usage_cache=str(controller_cache),
        )
        snaps = usage.collect_snapshots(args)
        five = [s for s in snaps if s.get("provider") == "claude" and s.get("window") == "5h"]
        check(len(five) == 1, "controller cache counted once (per-agent path == native path deduped)")

    # ---- (i3) _source guard: a STALE stdin-tap cache must NOT rotate as native
    # (codex r2 BLOCKING 1: the additive source must consume ONLY a cache the
    # native probe wrote, else a stale 99% stdin-tap cache the probe fail-opened
    # past would spuriously rotate through the new arg — the #831 fallback again).
    print("[i3] _source guard: a stale stdin-tap cache is NOT consumed as the native source")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        # A 99.5% cache the probe did NOT write (statusLine/stdin-tap residue).
        stale = tmp / "stale" / ".usage-cache.json"
        stale.parent.mkdir(parents=True, exist_ok=True)
        stale.write_text(
            json.dumps(
                {
                    "data": {"planName": "subscription", "fiveHour": 99.5, "sevenDay": 80.0},
                    "_source": "stdin-tap",
                }
            ),
            encoding="utf-8",
        )
        check(
            usage._cache_is_native_probe(stale) is False,
            "_cache_is_native_probe rejects a stdin-tap cache",
        )
        check(
            usage.native_snapshots(stale, warn=90.0, critical=100.0) == [],
            "native_snapshots returns [] for a non-native cache",
        )
        # End-to-end: per-agent all-absent + a stale stdin-tap controller cache →
        # NO __native__ rotation candidate (the exact codex repro of the leak).
        per_agent = tmp / "per-agent.json"
        per_agent.write_text(
            json.dumps(
                [{"agent": "iso-a", "path": str(tmp / "iso-a.json"), "present": False, "payload": None}]
            ),
            encoding="utf-8",
        )
        import argparse as _argparse

        args = _argparse.Namespace(
            claude_usage_cache=str(stale),
            codex_sessions_dir=str(tmp / "nocodex"),
            warn_threshold=90.0,
            elevated_threshold=95.0,
            critical_threshold=100.0,
            per_agent_cache_json=str(per_agent),
            legacy_single_path=str(stale),
            native_usage_cache=str(stale),
        )
        snaps = usage.collect_snapshots(args)
        native = [s for s in snaps if s.get("agent") == usage.NATIVE_PROBE_AGENT]
        check(len(native) == 0, "stale stdin-tap cache does NOT produce a __native__ snapshot (no false rotate)")
        # And the genuine native cache still works (positive control).
        native_cache = tmp / "native" / ".usage-cache.json"
        native_cache.parent.mkdir(parents=True, exist_ok=True)
        native_cache.write_text(json.dumps(probe.map_payload_to_cache(FIXTURE_1)), encoding="utf-8")
        args.claude_usage_cache = str(native_cache)
        args.legacy_single_path = str(native_cache)
        args.native_usage_cache = str(native_cache)
        snaps2 = usage.collect_snapshots(args)
        native2 = [s for s in snaps2 if s.get("agent") == usage.NATIVE_PROBE_AGENT and s.get("window") == "5h"]
        check(
            len(native2) == 1 and native2[0].get("used_percent") == 92.0,
            "a genuine native-oauth-probe cache IS consumed (positive control)",
        )

    # ---- (j) BLOCKER 2: deliberate token-file delivery + env-source disable --
    print("[j] #1437 r2 BLOCKER 2: token-file source + --no-env-token (deliberate delivery)")
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        tf = tmp / "oat.token"
        tf.write_text(MOCK_TOKEN, encoding="utf-8")
        # token-file source resolves the token.
        tok = probe.resolve_active_token(None, None, tf)
        check(tok == MOCK_TOKEN, "token-file source resolves the OAT")
        # registry still wins over token-file.
        reg = _registry_with_active(tmp, "REG-mock")
        check(
            probe.resolve_active_token(reg, None, tf) == "REG-mock",
            "registry active token still preferred over token-file",
        )
        # with allow_env=False, the env source is NOT consulted even if set.
        os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "ENV-should-be-ignored"  # noqa: iso-helper-boundary — test-only env set
        try:
            tok2 = probe.resolve_active_token(None, None, None, allow_env=False)
            check(tok2 is None, "allow_env=False ignores the ambient env token")
            tok3 = probe.resolve_active_token(None, None, tf, allow_env=False)
            check(tok3 == MOCK_TOKEN, "token-file used while env source disabled")
        finally:
            os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)  # noqa: iso-helper-boundary — test-only env cleanup

    print("")
    if failures:
        print(f"[1437-helper] {len(failures)} FAILED: {failures}")
        return 1
    print("[1437-helper] all assertions PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
