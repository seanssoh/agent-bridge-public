#!/usr/bin/env python3
"""Behavioral harness for scripts/smoke/17927-p2-statusline-usage-feed.sh.

Drives the REAL `bridge-usage.py monitor` subprocess (no live network, mock
caches only) to prove the #17927 P2 daemon-core contracts:

  E6/E8 — rotation eligibility is gated BEFORE candidate emit/latch. A monitored
          but NON-managed agent (not in --rotation-eligible-agents) crossing
          threshold drives an ALERT only: 0 rotation candidates, latch untouched.
          A managed-pool agent at threshold still produces a candidate.

  E10 Obs#1 — a stale cache (`_written_at` older than --cache-max-age-seconds)
          is "no signal": 0 rotation candidates, the rotation latch is NEITHER
          advanced NOR cleared (never read as 0% usage). A fresh cache rotates
          exactly once; a 2nd pass preserves the latch.

  E10 Obs#2 — every candidate carries rotation_trigger: `preemptive` for a fresh
          statusLine reading crossing threshold, `reactive` for a 429-signal
          cache. The controller-managed sentinel (empty agent) is always
          rotation-eligible even when a non-empty eligible set is supplied.

  E11 — the candidate carries ZERO token/credential bytes.

Exit 0 on all-pass, 1 otherwise.
"""
from __future__ import annotations

import json
import os
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


def cache(
    *,
    five_hour=None,
    seven_day=None,
    written_offset=0,
    reset_offset=86400,
    signal=False,
    signal_token=None,
):
    """Build a claude-hud .usage-cache.json-shaped payload dict."""
    reset_at = iso(reset_offset)
    payload = {
        "data": {
            "planName": "subscription",
            "fiveHour": five_hour,
            "sevenDay": seven_day,
            "fiveHourResetAt": reset_at,
            "sevenDayResetAt": reset_at,
        },
        "_source": "native-oauth-probe" if signal else "stdin-tap",
        "_written_at": iso(written_offset),
    }
    if signal:
        payload["_signal"] = "rate_limit_429"
    if signal_token:
        payload["_signal_token"] = signal_token
        payload["_token_digest"] = signal_token
    return payload, reset_at


def write_json(path: Path, obj) -> None:
    path.write_text(json.dumps(obj), encoding="utf-8")


def run_monitor(
    tmp: Path,
    *,
    per_agent=None,
    legacy_cache=None,
    native_cache=None,
    rotation_eligible=None,
    cache_max_age=None,
    state_file=None,
):
    """Invoke the real monitor; return (result_dict, state_dict)."""
    state_file = state_file or (tmp / "monitor-state.json")
    codex_dir = tmp / "codex-sessions"
    codex_dir.mkdir(exist_ok=True)
    claude_cache = tmp / "controller-cache.json"
    if legacy_cache is not None:
        write_json(claude_cache, legacy_cache)
    elif not claude_cache.exists():
        claude_cache.write_text("{}", encoding="utf-8")

    args = [
        sys.executable,
        str(USAGE_PY),
        "monitor",
        "--claude-usage-cache",
        str(claude_cache),
        "--codex-sessions-dir",
        str(codex_dir),
        "--state-file",
        str(state_file),
        "--json",
    ]
    if per_agent is not None:
        pa_path = tmp / "per-agent.json"
        write_json(pa_path, per_agent)
        args += ["--per-agent-cache-json", str(pa_path), "--legacy-single-path", str(claude_cache)]
    if native_cache is not None:
        nc_path = tmp / "native-cache.json"
        write_json(nc_path, native_cache)
        args += ["--native-usage-cache", str(nc_path)]
    if rotation_eligible is not None:
        args += ["--rotation-eligible-agents", rotation_eligible]
    if cache_max_age is not None:
        args += ["--cache-max-age-seconds", str(cache_max_age)]

    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    result = json.loads(out)
    state = json.loads(Path(state_file).read_text(encoding="utf-8"))
    return result, state


def per_agent_entry(agent: str, payload: dict, present: bool = True):
    return {
        "agent": agent,
        "path": f"/fake/{agent}/.claude/plugins/claude-hud/.usage-cache.json",
        "present": present,
        "payload": payload,
    }


def candidate_agents(result):
    return sorted(str(c.get("worst_case_agent") or c.get("agent") or "") for c in result["rotation_candidates"])


def latch_for(state, agent, window="weekly"):
    key = f"claude::subscription::{window}::{agent}"
    return state.get("entries", {}).get(key, {}).get("rotation_triggered_at")


def main() -> int:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        # ---- E6/E8: eligibility gate (managed rotates, non-managed alert-only)
        managed_payload, _ = cache(five_hour=10, seven_day=96)
        dyn_payload, _ = cache(five_hour=10, seven_day=96)
        per_agent = [
            per_agent_entry("managed-1", managed_payload),
            per_agent_entry("dyn-1", dyn_payload),
        ]
        sf = tmp / "e68-state.json"
        result, state = run_monitor(
            tmp, per_agent=per_agent, rotation_eligible="managed-1", state_file=sf
        )
        cands = candidate_agents(result)
        check(cands == ["managed-1"],
              f"E6/E8: only the managed agent yields a rotation candidate (got {cands})")
        alert_agents = sorted(str(a.get("agent") or "") for a in result["alerts"])
        check("dyn-1" in alert_agents and "managed-1" in alert_agents,
              f"E6/E8: BOTH agents still alert (monitored, got {alert_agents})")
        check(latch_for(state, "dyn-1") is None,
              "E6/E8: the non-managed agent's rotation latch is UNTOUCHED (alert-only)")
        check(latch_for(state, "managed-1") is not None,
              "E6/E8: the managed agent's rotation latch IS advanced")

        # ---- E10 Obs#2: the managed candidate is tagged preemptive
        trig = [c.get("rotation_trigger") for c in result["rotation_candidates"]]
        check(trig == ["preemptive"],
              f"E10 Obs#2: a fresh reading crossing threshold tags preemptive (got {trig})")

        # ---- E10 Obs#1 fresh: exactly one rotate, 2nd pass preserves the latch
        sf2 = tmp / "e10-fresh-state.json"
        pa_fresh = [per_agent_entry("managed-1", cache(five_hour=10, seven_day=96)[0])]
        r1, _ = run_monitor(tmp, per_agent=pa_fresh, rotation_eligible="managed-1", state_file=sf2)
        check(len(r1["rotation_candidates"]) == 1,
              f"E10: a fresh cache at threshold yields exactly 1 rotation candidate (got {len(r1['rotation_candidates'])})")
        # 2nd pass: same fresh cache → latch already set → no new candidate.
        pa_fresh2 = [per_agent_entry("managed-1", cache(five_hour=10, seven_day=96)[0])]
        r2, s2 = run_monitor(tmp, per_agent=pa_fresh2, rotation_eligible="managed-1", state_file=sf2)
        check(len(r2["rotation_candidates"]) == 0,
              f"E10: 2nd pass on the same cache preserves the latch (0 new candidates, got {len(r2['rotation_candidates'])})")
        check(latch_for(s2, "managed-1") is not None,
              "E10: the rotation latch survives the 2nd pass")

        # ---- E10 Obs#1 stale: no-op, latch NEITHER advanced NOR cleared
        sf3 = tmp / "e10-stale-state.json"
        # 48h-old _written_at, 96% weekly. With a 6h max-age this is provably stale.
        stale_payload = cache(five_hour=10, seven_day=96, written_offset=-172800)[0]
        rs, ss = run_monitor(
            tmp,
            per_agent=[per_agent_entry("managed-1", stale_payload)],
            rotation_eligible="managed-1",
            cache_max_age=21600,
            state_file=sf3,
        )
        check(len(rs["rotation_candidates"]) == 0,
              f"E10 Obs#1: a STALE cache drives no rotation candidate (got {len(rs['rotation_candidates'])})")
        check(latch_for(ss, "managed-1") is None,
              "E10 Obs#1: a stale cache does NOT advance the rotation latch")
        # The stale cache must also not be read as a fresh 0%/below-threshold
        # reading (which would CLEAR a pre-existing latch). Seed a latch first,
        # then a stale reading must leave it intact.
        sf4 = tmp / "e10-stale-noclear-state.json"
        run_monitor(tmp,
                    per_agent=[per_agent_entry("managed-1", cache(five_hour=10, seven_day=96)[0])],
                    rotation_eligible="managed-1", state_file=sf4)
        pre = latch_for(json.loads(sf4.read_text()), "managed-1")
        _, ss4 = run_monitor(
            tmp,
            per_agent=[per_agent_entry("managed-1", cache(five_hour=10, seven_day=96, written_offset=-172800)[0])],
            rotation_eligible="managed-1", cache_max_age=21600, state_file=sf4,
        )
        check(pre is not None and latch_for(ss4, "managed-1") == pre,
              "E10 Obs#1: a stale cache does NOT CLEAR a pre-existing latch (no false 0% read)")

        # ---- E10 Obs#1 (codex r2 regression): a STALE cache whose reset_at is
        # bogusly ADVANCED (> grace) must NOT clear the rotation latch. Otherwise
        # the next fresh reading at the REAL (unchanged) reset re-emits a
        # duplicate preemptive candidate for the same incident. The stale
        # advanced reset_at is not authoritative.
        sf6 = tmp / "e10-stale-advanced-reset-state.json"
        # pass1: fresh 96% at reset R1 -> 1 candidate, latch at R1.
        r1a, _ = run_monitor(
            tmp,
            per_agent=[per_agent_entry("managed-1", cache(five_hour=10, seven_day=96, reset_offset=86400)[0])],
            rotation_eligible="managed-1", state_file=sf6,
        )
        check(len(r1a["rotation_candidates"]) == 1,
              f"E10 Obs#1(adv): pass1 fresh at R1 rotates once (got {len(r1a['rotation_candidates'])})")
        latch_r1 = latch_for(json.loads(sf6.read_text()), "managed-1")
        # pass2: STALE cache (48h old) reporting an ADVANCED reset R2 (> R1 + grace).
        r2a, s2a = run_monitor(
            tmp,
            per_agent=[per_agent_entry("managed-1", cache(five_hour=10, seven_day=96, reset_offset=200000, written_offset=-172800)[0])],
            rotation_eligible="managed-1", cache_max_age=21600, state_file=sf6,
        )
        check(len(r2a["rotation_candidates"]) == 0,
              f"E10 Obs#1(adv): pass2 stale-advanced-reset drives no candidate (got {len(r2a['rotation_candidates'])})")
        check(latch_r1 is not None and latch_for(s2a, "managed-1") == latch_r1,
              "E10 Obs#1(adv): a STALE cache's advanced reset_at does NOT clear the rotation latch")
        # pass3: fresh 96% at the REAL (unchanged) reset R1 -> latch still held -> no duplicate.
        r3a, _ = run_monitor(
            tmp,
            per_agent=[per_agent_entry("managed-1", cache(five_hour=10, seven_day=96, reset_offset=86400)[0])],
            rotation_eligible="managed-1", state_file=sf6,
        )
        check(len(r3a["rotation_candidates"]) == 0,
              f"E10 Obs#1(adv): next fresh reading at the real reset emits NO duplicate (got {len(r3a['rotation_candidates'])})")

        # ---- E10 Obs#2 reactive: a 429-signal cache is tagged reactive and the
        # controller-managed sentinel (empty agent) is eligible despite a
        # non-empty eligible set.
        sig_payload, _ = cache(five_hour=100, seven_day=100, signal=True, signal_token="deadbeef")
        sf5 = tmp / "e10-reactive-state.json"
        rsig, _ = run_monitor(
            tmp, legacy_cache=sig_payload, rotation_eligible="managed-1", state_file=sf5
        )
        sig_trig = [c.get("rotation_trigger") for c in rsig["rotation_candidates"]]
        check(len(sig_trig) >= 1 and all(t == "reactive" for t in sig_trig),
              f"E10 Obs#2: a 429-signal cache tags reactive (got {sig_trig})")

        # ---- E11: zero token/credential bytes in any candidate
        blob = json.dumps(result["rotation_candidates"] + rsig["rotation_candidates"]).lower()
        leaky = [k for k in ("oauth_token", "access_token", "refresh_token", "credentials", "api_key", "sk-ant") if k in blob]
        check(not leaky,
              f"E11: candidate JSON carries no token/credential bytes (found {leaky})")

    return 1 if _failures else 0


if __name__ == "__main__":
    sys.exit(main())
