#!/usr/bin/env python3
"""Cross-layer auto-rotate decision-chain helper (#2217 roadmap step 5).

Invoked by scripts/smoke/2217-rotate-decision-chain.sh. This is the PROBE+TAP
half of the chain: it drives the REAL shipped ``bridge-usage-probe.py`` (the
content-freshness gate ``cache_is_fresh`` + ``run_probe`` edge classifier) and
the REAL ``bridge-usage.py`` monitor (cache → rotation-candidate). The shell
driver owns the INFERENCE/PICKER half (the daemon's reactive-429 rotate
trigger). Together they prove the WHOLE decision chain routes correctly:

    HUD stdin-tap  →  native usage-probe  →  inference/picker reactive-429

NEVER makes a live network call — every probe injects a stub ``http_get`` into
``run_probe`` (the seam that keeps CI offline). Uses ONLY mock token strings.

The step-4 smoke (2217-reactive-429-rotate.sh) already pins the TRIGGER-level
reactive-429 gate in isolation. This helper's distinct value is the LAYER
CROSSING the trigger smoke never exercises:

  L1 (tap)   — a FRESH at-cap stdin-tap cache makes the probe stand down AND
               yields a proactive rotation candidate (rotate via the tap, native
               probe not consulted). A STALE-CONTENT tap (`_written_at` old) no
               longer suppresses the probe (#2214 content-freshness gate).
  L2 (probe) — when the tap is blind, the native probe runs; an EDGE-BLOCKED
               429 (no anthropic origin headers) classifies edge-blocked and
               writes NO synthetic near-limit cache → the monitor surfaces NO
               proactive candidate (the probe is correctly silent, NOT a
               fabricated 100%). This is the precise condition the reactive
               backstop must cover.

The shell driver consumes a `verdict <scenario>` subcommand: each prints a
single machine-readable status token the bash side asserts, plus the mutation
hooks (env-driven) so the driver can prove each layer's fix-condition has teeth.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
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

MOCK_TOKEN_A = "sk-ant-oat-MOCK-not-a-real-token-AAAA"

# Edge response: Server: cloudflare, NO request-id / anthropic-* origin headers.
CF_HEADERS = {"Server": "cloudflare", "CF-RAY": "8f2mock-NRT", "Content-Type": "application/json"}
# Origin response: request-id / anthropic-* present (the genuine #1468 signal).
ANTHROPIC_HEADERS = {
    "request-id": "req_mock_0123456789",
    "anthropic-organization-id": "org-mock",
    "Content-Type": "application/json",
    "Server": "cloudflare",
}
RATE_LIMIT_BODY = {"error": {"message": "Rate limited.", "type": "rate_limit_error"}}
OK_BODY = {
    "five_hour": {"utilization": 42.0, "resets_at": "2026-06-12T18:00:00+00:00"},
    "seven_day": {"utilization": 13.0, "resets_at": "2026-06-18T00:00:00+00:00"},
}


def _registry(tmp: Path, active_token: str) -> Path:
    p = tmp / "claude-oauth-tokens.json"
    p.write_text(
        json.dumps(
            {
                "active_token_id": "tok-active",
                "tokens": [{"id": "tok-active", "token": active_token, "enabled": True}],
            }
        ),
        encoding="utf-8",
    )
    return p


def _stub_http_error(status, body_obj, retry_after, headers, calls):
    def _get(url, headers_req, timeout):
        calls["n"] = calls.get("n", 0) + 1
        body = body_obj if isinstance(body_obj, str) else json.dumps(body_obj)
        raise probe.ProbeHTTPError(status, body=body, retry_after=retry_after, headers=headers)

    return _get


def _stub_ok(body_obj, calls):
    def _get(url, headers_req, timeout):
        calls["n"] = calls.get("n", 0) + 1
        return json.dumps(body_obj)

    return _get


def _written(now_clock: float, age_s: float) -> str:
    return datetime.fromtimestamp(now_clock - age_s, timezone.utc).isoformat()


def _run_probe(tmp: Path, *, http_get, registry, now, max_age):
    cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
    return probe.run_probe(
        cache_path=cache_path,
        registry_path=registry,
        credentials_path=None,
        user_agent_version="2.1.0",
        max_age_seconds=max_age,
        cooldown_seconds=0.0,
        http_timeout=10.0,
        retry_after_cap=5.0,
        now=now,
        http_get=http_get,
        log=lambda m: None,
    )


def _monitor_candidates(cache_path: Path, state_path: Path) -> int:
    """Drive the REAL monitor on a single cache; return the candidate count."""

    class _NS:
        pass

    ns = _NS()
    ns.claude_usage_cache = str(cache_path)
    ns.codex_sessions_dir = str(cache_path.parent / "no-codex")
    ns.warn_threshold = 90.0
    ns.elevated_threshold = 95.0
    ns.critical_threshold = 100.0
    ns.rotation_threshold = 95.0
    ns.per_agent_cache_json = None
    ns.legacy_single_path = None
    ns.native_usage_cache = None
    ns.active_token_digest = None
    ns.state_file = str(state_path)
    # Pin the monitor's content-age window explicitly (the default is 21600s /
    # 6h) so the stale-tap age below is deterministically past it.
    ns.cache_max_age_seconds = MONITOR_CACHE_MAX_AGE_SECONDS
    ns.json = True
    import contextlib
    import io

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        usage.cmd_monitor(ns)
    out = json.loads(buf.getvalue() or "{}")
    return len(out.get("rotation_candidates") or [])


NOW = 1_700_000_000.0
# The monitor's content-freshness window (default 21600s / 6h). A tap body whose
# `_written_at` is older than this is inert for the rotation lane.
MONITOR_CACHE_MAX_AGE_SECONDS = 21600.0
# Content-age of the tap body. Mutation hook: the shell driver re-runs L1 with
# CHAIN_TAP_CONTENT_AGE pushed past max_age to prove the content-freshness gate
# (#2214) is what falls the chain through to the probe layer.
TAP_CONTENT_AGE = float(os.environ.get("CHAIN_TAP_CONTENT_AGE", "10"))
MAX_AGE = 300.0


def _tap_cache_at_cap(now_clock: float, content_age: float) -> dict:
    """A live statusLine stdin-tap cache pinned at the rotation cap (100%)."""
    return {
        "data": {
            "planName": "subscription",
            "fiveHour": 100.0,
            "sevenDay": 100.0,
            "fiveHourResetAt": "2026-06-12T18:00:00+00:00",
            "sevenDayResetAt": "2026-06-12T18:00:00+00:00",
        },
        "_source": "stdin-tap",
        "_written_at": _written(now_clock, content_age),
    }


def verdict_l1_tap_fresh() -> str:
    """L1 — a FRESH at-cap stdin-tap cache: probe stands down (no HTTP) AND the
    monitor yields a proactive rotation candidate. Rotation fires from the tap;
    the native probe is never consulted. Mutation: push CHAIN_TAP_CONTENT_AGE
    past max_age → the body is content-stale → the probe RUNS (falls through to
    L2) and the at-cap tap reading no longer drives the candidate.

    The two assertions use different clocks on purpose: the probe stand-down
    gate (``run_probe``) takes an injectable ``now`` (anchored at the synthetic
    NOW), but the monitor ages ``_written_at`` against the REAL wall clock
    (``datetime.now()`` — not injectable). So the probe-side cache is written at
    content-age ``TAP_CONTENT_AGE`` relative to NOW, and the monitor-side cache
    is written at the SAME content-age relative to real wall time."""
    probe_content_age = TAP_CONTENT_AGE
    # --- assertion 1: the probe stands down on a content-fresh tap (no HTTP) ---
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(json.dumps(_tap_cache_at_cap(NOW, probe_content_age)), encoding="utf-8")
        # Fresh mtime regardless of content age (the live bug: a touched mtime
        # over a stale body). Content age is what the gate must judge.
        os.utime(cache_path, (NOW - 1, NOW - 1))
        calls = {"n": 0}
        res = _run_probe(tmp, http_get=_stub_ok(OK_BODY, calls), registry=reg, now=NOW, max_age=MAX_AGE)
        probe_ran = calls["n"] > 0
        if probe_ran:
            # Content-stale tap → the gate fell through to the probe (the #2214
            # fix / the mutation). The chain proceeds to L2.
            return "tap-fellthrough"
        if res["status"] != "fresh":
            return f"unexpected:status={res['status']}:probe_ran={probe_ran}"

    # --- assertion 2: the at-cap tap drives a proactive rotation candidate -----
    import time

    real_now = time.time()
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        cache_path = tmp / ".usage-cache.json"
        cache_path.write_text(json.dumps(_tap_cache_at_cap(real_now, probe_content_age)), encoding="utf-8")
        candidates = _monitor_candidates(cache_path, tmp / "ms.json")
        if candidates >= 1:
            return "tap-rotate"
        return f"unexpected:probe_stood_down_but_no_candidate:cand={candidates}"


def verdict_l2_edge_blocked() -> str:
    """L2 — tap blind, native probe runs into an EDGE-BLOCKED 429 (no anthropic
    origin headers): the probe classifies edge-blocked, writes NO synthetic
    near-limit cache, and the REAL monitor surfaces NO proactive candidate from
    the on-disk cache. This is the precise blind condition the reactive backstop
    must cover. Mutation: swapping the edge headers for anthropic-origin headers
    (CHAIN_PROBE_ORIGIN=1) makes the SAME 429 a #1468 account signal → a
    synthetic at-cap cache IS written → the SAME real monitor now surfaces a
    proactive candidate (NOT the sean-mac blind mode).

    The 0-vs-≥1 distinction is produced by the REAL bridge-usage.py monitor on
    the cache the probe leaves on disk — NEVER a hardcoded constant. To give the
    monitor a non-empty cache to (correctly) reject in the blind case, we seed a
    STALE at-cap stdin-tap body on the SAME cache_path BEFORE the probe: the
    edge-blocked probe leaves it untouched (serve-stale), and the monitor must
    still emit 0 candidates because the tap body is content-stale (`_written_at`
    past the max-age window → `cache_fresh=False` → inert for the rotation lane).
    A monitor that instead read that stale at-cap body as a live 100% reading
    would emit a candidate, so the 0 assertion has real teeth on the monitor's
    staleness gate. The origin mutation overwrites the stale tap with a FRESH
    synthetic near-limit cache, so the monitor emits ≥1."""
    origin = os.environ.get("CHAIN_PROBE_ORIGIN", "0") == "1"
    headers = ANTHROPIC_HEADERS if origin else CF_HEADERS
    import time

    real_now = time.time()
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        reg = _registry(tmp, MOCK_TOKEN_A)
        cache_path = tmp / "plugins" / "claude-hud" / ".usage-cache.json"
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        # Seed a STALE at-cap stdin-tap body (the sean-mac headless state: a tap
        # body that is on disk but content-stale). `_written_at` is anchored to
        # the REAL wall clock the monitor ages against, pushed well past the
        # monitor's max-age window so a correct monitor treats it as inert.
        stale_age = MONITOR_CACHE_MAX_AGE_SECONDS + 86_400
        cache_path.write_text(
            json.dumps(_tap_cache_at_cap(real_now, stale_age)), encoding="utf-8"
        )
        # Fresh mtime over the stale content (the live bug shape): content age,
        # not mtime, is what the gate must judge.
        os.utime(cache_path, (real_now - 1, real_now - 1))
        calls = {"n": 0}
        res = _run_probe(
            tmp,
            http_get=_stub_http_error(429, RATE_LIMIT_BODY, 3600.0, headers, calls),
            registry=reg,
            now=NOW,
            max_age=MAX_AGE,
        )
        # ALWAYS drive the REAL monitor on whatever cache is on disk now — the
        # candidate count is the monitor's verdict, never a hardcoded constant.
        candidates = _monitor_candidates(cache_path, tmp / "ms.json")
        synthetic_written = res["status"] == "rate-limited-signal"
        if origin:
            # Mutation control: an origin 429 IS the #1468 signal path — a FRESH
            # synthetic at-cap cache replaces the stale tap → the monitor rotates.
            if synthetic_written and candidates >= 1:
                return "probe-signal"
            return f"unexpected-origin:status={res['status']}:written={synthetic_written}:cand={candidates}"
        # The real sean-mac condition: edge-blocked, no synthetic cache; the real
        # monitor surfaces NO candidate from the content-stale tap left on disk.
        if res["status"] == "edge-blocked" and not synthetic_written and candidates == 0:
            return "probe-blind"
        return f"unexpected:status={res['status']}:written={synthetic_written}:cand={candidates}"


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[0] != "verdict":
        sys.stderr.write("usage: 2217-rotate-decision-chain-helper.py verdict <l1-tap-fresh|l2-edge-blocked>\n")
        return 2
    scenario = argv[1]
    if scenario == "l1-tap-fresh":
        sys.stdout.write(verdict_l1_tap_fresh() + "\n")
        return 0
    if scenario == "l2-edge-blocked":
        sys.stdout.write(verdict_l2_edge_blocked() + "\n")
        return 0
    sys.stderr.write(f"unknown scenario: {scenario}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
