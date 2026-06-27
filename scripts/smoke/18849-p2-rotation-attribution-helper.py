#!/usr/bin/env python3
"""Behavioral harness for scripts/smoke/18849-p2-rotation-attribution.sh.

#18849 Part 2 PR-1 — reproduce + lock down the "rotation fires at ~41% usage"
bug: the daemon rotates the Claude OAT while the ACTIVE token's real usage is
well below the rotation threshold.

Root cause (confirmed): after an A->B rotation, the native usage probe may keep
serving token A's not-yet-expired cache for the length of its freshness window.
That cache reports A's old >=threshold reading, so the monitor emitted a fresh
PREEMPTIVE rotation candidate for it — re-rotating the freshly-active B even
though B's real usage is ~41%. The parse-time stale-attribution guard only
dropped synthetic 429-signal caches; REAL preemptive readings were ungated.

Fix: cmd_monitor now carries each cache's `_token_digest` onto its snapshots and
drops a REAL reading from the rotation lane when its digest mismatches the live
`--active-token-digest` (mirrors the existing signal guard: suppress only when
BOTH digests are present and differ).

Drives the REAL `bridge-usage.py monitor` subprocess (no live network, mock
caches only). Exit 0 on all-pass, 1 otherwise.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
USAGE_PY = REPO_ROOT / "bridge-usage.py"

_failures = 0


def check(cond: bool, msg: str) -> None:
    global _failures
    if cond:
        print(f"  PASS  {msg}")
    else:
        _failures += 1
        print(f"  FAIL  {msg}", file=sys.stderr)


def iso(offset_seconds: int) -> str:
    return (datetime.now(timezone.utc) + timedelta(seconds=offset_seconds)).isoformat()


def native_cache(
    *,
    five_hour=None,
    seven_day=None,
    token_digest=None,
    written_offset=-30,
    reset_offset=7200,
    signal=False,
):
    """A `.usage-cache.json` payload tagged `_source == native-oauth-probe` (the
    only `_source` the additive native lane reads)."""
    payload = {
        "data": {
            "planName": "subscription",
            "fiveHour": five_hour,
            "sevenDay": seven_day,
            "fiveHourResetAt": iso(reset_offset),
            "sevenDayResetAt": iso(reset_offset),
        },
        "_source": "native-oauth-probe",
        "_written_at": iso(written_offset),
    }
    if token_digest:
        payload["_token_digest"] = token_digest
    if signal:
        payload["_signal"] = "rate_limit_429"
        if token_digest:
            payload["_signal_token"] = token_digest
    return payload


def per_agent_entry(agent: str, *, five_hour, seven_day):
    """A digest-less per-agent statusLine (stdin-tap) cache — the active token's
    real, current usage."""
    return {
        "agent": agent,
        "path": f"/fake/{agent}/.claude/plugins/claude-hud/.usage-cache.json",
        "present": True,
        "payload": {
            "data": {
                "planName": "subscription",
                "fiveHour": five_hour,
                "sevenDay": seven_day,
                "fiveHourResetAt": iso(7200),
                "sevenDayResetAt": iso(7200),
            },
            "_source": "stdin-tap",
        },
    }


def write_json(path: Path, obj) -> None:
    path.write_text(json.dumps(obj), encoding="utf-8")


def run_monitor(tmp: Path, name: str, *, native, per_agent, active_digest, eligible="managed-1",
                state_name=None):
    state_file = tmp / f"{state_name or name}-state.json"
    codex_dir = tmp / "codex-sessions"
    codex_dir.mkdir(exist_ok=True)
    controller = tmp / f"{name}-controller.json"
    write_json(controller, {})
    pa_path = tmp / f"{name}-per-agent.json"
    write_json(pa_path, per_agent)
    nc_path = tmp / f"{name}-native.json"
    write_json(nc_path, native)

    args = [
        sys.executable, str(USAGE_PY), "monitor",
        "--claude-usage-cache", str(controller),
        "--codex-sessions-dir", str(codex_dir),
        "--state-file", str(state_file),
        "--rotation-threshold", "99",
        "--weekly-warn-threshold", "95",
        "--cache-max-age-seconds", "21600",
        "--per-agent-cache-json", str(pa_path),
        "--legacy-single-path", str(controller),
        "--native-usage-cache", str(nc_path),
        "--json",
    ]
    if eligible is not None:
        args += ["--rotation-eligible-agents", eligible]
    if active_digest is not None:
        args += ["--active-token-digest", active_digest]

    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def n_candidates(result) -> int:
    return len(result["rotation_candidates"])


def native_rotation_latch(tmp: Path, state_name: str, window: str = "5h"):
    state = json.loads((tmp / f"{state_name}-state.json").read_text(encoding="utf-8"))
    key = f"claude::subscription::{window}::__native__"
    return state.get("entries", {}).get(key, {}).get("rotation_triggered_at")


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        # ── THE REPRO: active token = B ("bbb") at 41%, but the native probe is
        # still serving token A's ("aaa") not-yet-expired 99% cache. PRE-FIX this
        # emitted a preemptive candidate → the daemon re-rotated B while B was at
        # 41% (the operator-observed "rotation at ~41%"). POST-FIX: 0 candidates.
        repro = run_monitor(
            tmp, "repro",
            native=native_cache(five_hour=99, seven_day=41, token_digest="aaa"),
            per_agent=[per_agent_entry("managed-1", five_hour=41, seven_day=41)],
            active_digest="bbb",
        )
        check(n_candidates(repro) == 0,
              "REPRO: a stale native cache for a PREVIOUSLY-active token drives NO "
              f"rotation while the active token is at 41% (got {n_candidates(repro)})")
        # The stale reading is still visible to the operator as an ALERT — only the
        # ROTATION lane is gated (matches the existing staleness-guard scoping).
        check(len(repro["alerts"]) >= 1,
              "REPRO: the stale high reading still ALERTS the operator (rotation-lane-only gate)")

        # ── Legit: the native cache IS stamped for the active token at 99% — a
        # real at-limit reading must STILL rotate.
        legit = run_monitor(
            tmp, "legit",
            native=native_cache(five_hour=99, seven_day=41, token_digest="bbb"),
            per_agent=[per_agent_entry("managed-1", five_hour=41, seven_day=41)],
            active_digest="bbb",
        )
        check(n_candidates(legit) == 1,
              f"LEGIT: the active token at 99% still yields exactly 1 candidate (got {n_candidates(legit)})")

        # ── Back-compat: a registry-less install passes no --active-token-digest,
        # so the gate is OFF (ungated) and a digest-less native cache still rotates.
        # This is the exact shape of scripts/smoke/1437-native-usage-probe.sh.
        ungated = run_monitor(
            tmp, "ungated",
            native=native_cache(five_hour=99, seven_day=41, token_digest=None),
            per_agent=[per_agent_entry("managed-1", five_hour=41, seven_day=41)],
            active_digest=None,
        )
        check(n_candidates(ungated) == 1,
              f"BACK-COMPAT: no active digest ⇒ ungated, native 99% still rotates (got {n_candidates(ungated)})")

        # ── A digest-less native cache WITH an active digest fails OPEN (we only
        # suppress when both digests are present and differ — mirrors the signal
        # guard; an absent digest is "unknown", never "stale").
        failopen = run_monitor(
            tmp, "failopen",
            native=native_cache(five_hour=99, seven_day=41, token_digest=None),
            per_agent=[per_agent_entry("managed-1", five_hour=41, seven_day=41)],
            active_digest="bbb",
        )
        check(n_candidates(failopen) == 1,
              f"FAIL-OPEN: a digest-less native cache is NOT suppressed (got {n_candidates(failopen)})")

        # ── Reactive 429-signal for the active token is NOT subject to the gate
        # (it has its own parse-time attribution guard); it must still rotate.
        reactive = run_monitor(
            tmp, "reactive",
            native=native_cache(five_hour=100, seven_day=100, token_digest="bbb", signal=True),
            per_agent=[per_agent_entry("managed-1", five_hour=41, seven_day=41)],
            active_digest="bbb",
        )
        check(n_candidates(reactive) >= 1 and all(
            c.get("rotation_trigger") == "reactive" for c in reactive["rotation_candidates"]),
              f"REACTIVE: a 429-signal for the active token still rotates (got {n_candidates(reactive)})")

        # ── LATCH INTEGRITY (codex review item 3): a mismatched-digest reading
        # whose reset_at is ADVANCED must NOT clear the active token's rotation
        # latch. The reset-cycle latch clear is gated on `cache_fresh`, so the
        # attribution check is folded INTO cache_fresh (not a separate later gate)
        # to keep the stale reading fully inert (no candidate AND no latch mutation).
        # pass 1: token A active at 99% (reset R1) → __native__ latch set.
        run_monitor(
            tmp, "latch-p1", state_name="latch",
            native=native_cache(five_hour=99, seven_day=41, token_digest="aaa", reset_offset=3600),
            per_agent=[per_agent_entry("managed-1", five_hour=41, seven_day=41)],
            active_digest="aaa",
        )
        latch1 = native_rotation_latch(tmp, "latch")
        check(latch1 is not None,
              "LATCH: pass-1 active-token 99% sets the __native__ rotation latch")
        # pass 2: token B now active; the probe still serves A's stale 99% cache,
        # this time with an ADVANCED reset_at (R2 > R1 + grace). It must drive 0
        # candidates AND leave the latch untouched.
        p2 = run_monitor(
            tmp, "latch-p2", state_name="latch",
            native=native_cache(five_hour=99, seven_day=41, token_digest="aaa", reset_offset=99999),
            per_agent=[per_agent_entry("managed-1", five_hour=41, seven_day=41)],
            active_digest="bbb",
        )
        check(n_candidates(p2) == 0,
              f"LATCH: pass-2 mismatched advanced-reset reading drives no rotation (got {n_candidates(p2)})")
        check(native_rotation_latch(tmp, "latch") == latch1,
              "LATCH: a mismatched-digest advanced-reset reading does NOT clear the active token's latch")

        # ── No token bytes / digest in candidate OR snapshot output (item 5): the
        # internal `_token_digest` gate input must be stripped from monitor output.
        full = json.dumps(repro).lower() + json.dumps(legit).lower() + json.dumps(reactive).lower()
        leaky = [k for k in ("oauth_token", "access_token", "refresh_token",
                             "credentials", "api_key", "sk-ant") if k in full]
        check(not leaky, f"monitor JSON carries no token/credential bytes (found {leaky})")
        in_output = ["token_digest" in json.dumps(r) for r in (repro, legit, reactive)]
        check(not any(in_output),
              "token_digest is an internal gate input — never emitted in candidates or snapshots")

    return 1 if _failures else 0


if __name__ == "__main__":
    sys.exit(main())
