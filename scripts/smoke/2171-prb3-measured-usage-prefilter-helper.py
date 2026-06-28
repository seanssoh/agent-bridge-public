#!/usr/bin/env python3
"""Mock-only harness for the #2171 PR-B3 measured-usage candidate prefilter +
wrong-home cache-split diagnostic. Invoked by
scripts/smoke/2171-prb3-measured-usage-prefilter.sh.

NEVER touches the live registry / usage cache and NEVER makes a network call:
every fixture is a hand-written `.usage-cache.json` under a tmp dir, and every
token is a MOCK string (never a real credential). Only one-way digests are ever
written or compared — no token bytes.

Covers the six asserted plan-ok cases (1-6) plus a B2-dependency note (case 7):
  1. fresh matching digest at/over the 5h rotation threshold  -> candidate
     skipped with reason `measured_near_limit`.
  2. fresh matching digest at/over the weekly threshold        -> skipped via the
     `weekly_warn_threshold` (proved: 96% < the 99% 5h threshold, so only the
     weekly knob can mark it).
  3. STALE matching digest                                     -> fail-open
     (existing registry-stamp eligibility; candidate available).
  4. missing cache / missing `_token_digest`                   -> fail-open.
  5. digest MISMATCH                                           -> the candidate
     gate fails open (NOT misread as 0% / not a crossing) AND the monitor emits
     a `wrong_home_cache_split` diagnostic (no-signal, no rotation candidate).
  6. display-fingerprint-vs-active-digest                      -> the
     implementation uses `_token_signal_digest` (16-char SHA-256 prefix), NOT
     `token_fingerprint`; a cache keyed by the display fingerprint never matches.
  7. (B2-dependency note) daemon `--preflight` enablement is PR-B2; this unit
     smoke does not assert the worst-case live backstop, but it DOES assert the
     gate records that dependency so B3 cannot be silently reframed as standalone
     closure of the stale/missing-cache worst case.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _load(mod_name: str, filename: str):
    spec = importlib.util.spec_from_file_location(mod_name, str(REPO_ROOT / filename))
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    assert spec and spec.loader
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


auth = _load("bridge_auth", "bridge-auth.py")
probe = _load("bridge_usage_probe", "bridge-usage-probe.py")
usage = _load("bridge_usage", "bridge-usage.py")

MOCK_TOKEN_A = "sk-ant-oat-MOCK-prefilter-AAAA-aaaaaaaaaaaa"
MOCK_TOKEN_B = "sk-ant-oat-MOCK-prefilter-BBBB-bbbbbbbbbbbb"

DIGEST_A = probe._token_signal_digest(MOCK_TOKEN_A)
DIGEST_B = probe._token_signal_digest(MOCK_TOKEN_B)

NOW = datetime(2026, 6, 28, 12, 0, 0, tzinfo=timezone.utc)
FRESH = (NOW - timedelta(seconds=60)).isoformat()
STALE = (NOW - timedelta(seconds=7 * 3600)).isoformat()  # > 6h default max-age

ROTATION_THRESHOLD = 99.0
WEEKLY_WARN_THRESHOLD = 95.0
CACHE_MAX_AGE = 21600.0

_failures = 0


def check(cond: bool, msg: str) -> None:
    global _failures
    if cond:
        print(f"  ok   {msg}")
    else:
        _failures += 1
        print(f"  FAIL {msg}")


def write_cache(path: Path, *, five_hour, seven_day, written_at, digest) -> None:
    payload = {
        "data": {
            "planName": "subscription",
            "fiveHour": five_hour,
            "sevenDay": seven_day,
            "fiveHourResetAt": None,
            "sevenDayResetAt": None,
        },
        "_source": "native-probe",
        "_written_at": written_at,
    }
    if digest is not None:
        payload["_token_digest"] = digest
    path.write_text(json.dumps(payload), encoding="utf-8")


def candidate_row(token: str) -> dict:
    # No limited_until / disabled_until / last_check_status => registry-stamp
    # eligible, so any verdict change is purely from the measured prefilter.
    return {"id": "tok", "token": token, "enabled": True}


def build_index(paths) -> dict:
    return auth._build_measured_usage_index(
        [str(p) for p in paths],
        rotation_threshold=ROTATION_THRESHOLD,
        weekly_warn_threshold=WEEKLY_WARN_THRESHOLD,
        cache_max_age_seconds=CACHE_MAX_AGE,
        now=NOW,
    )


def gate(row, index):
    return auth.rotation_candidate_availability(
        row, NOW, adverse_check_max_age_seconds=21600.0, measured_usage_index=index
    )


def run_monitor(tmp: Path, *, claude_cache: Path, active_digest: str) -> dict:
    codex_dir = tmp / "codex-empty"
    codex_dir.mkdir(exist_ok=True)
    state = tmp / f"monitor-state-{claude_cache.stem}.json"
    argv = [
        "monitor",
        "--claude-usage-cache", str(claude_cache),
        "--codex-sessions-dir", str(codex_dir),
        "--state-file", str(state),
        "--rotation-threshold", str(ROTATION_THRESHOLD),
        "--weekly-warn-threshold", str(WEEKLY_WARN_THRESHOLD),
        "--active-token-digest", active_digest,
        "--json",
    ]
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = usage.main(argv)
    assert rc == 0, f"monitor exited {rc}"
    return json.loads(buf.getvalue())


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="prb3-prefilter-") as td:
        tmp = Path(td)

        # --- digest-format invariant (Case 6 core) --------------------------
        print("[digest-format] implementation uses _token_signal_digest, not token_fingerprint")
        check(
            auth._usage_cache_token_digest(MOCK_TOKEN_A) == DIGEST_A,
            "_usage_cache_token_digest == bridge-usage-probe _token_signal_digest (16-char SHA-256 prefix)",
        )
        check(len(DIGEST_A) == 16, "active-token digest is a 16-char prefix")
        check(
            auth._usage_cache_token_digest(MOCK_TOKEN_A) != auth.token_fingerprint(MOCK_TOKEN_A),
            "digest is NOT the display token_fingerprint (sha256:<12>...<tail>)",
        )

        # --- Case 1: fresh, 5h >= rotation_threshold -> measured_near_limit --
        print("[case 1] fresh matching digest >=5h threshold -> skip measured_near_limit")
        c1 = tmp / "c1.json"
        write_cache(c1, five_hour=99.5, seven_day=10.0, written_at=FRESH, digest=DIGEST_A)
        idx1 = build_index([c1])
        check(idx1.get(DIGEST_A, {}).get("5h") is True, "builder precomputed 5h near-limit boolean")
        avail, reset_at, reason = gate(candidate_row(MOCK_TOKEN_A), idx1)
        check(avail is False and reason == "measured_near_limit", "candidate skipped with reason measured_near_limit")
        check(reset_at is None, "measured skip carries no reset_at (not a window cooldown)")

        # --- Case 2: fresh, weekly >= weekly_warn_threshold -----------------
        print("[case 2] fresh matching digest >=weekly threshold -> weekly_warn_threshold governs")
        c2 = tmp / "c2.json"
        # 96% weekly is BELOW the 99% 5h threshold; only weekly_warn_threshold (95)
        # can mark it -> proves the weekly window uses the weekly knob.
        write_cache(c2, five_hour=10.0, seven_day=96.0, written_at=FRESH, digest=DIGEST_A)
        idx2 = build_index([c2])
        check(idx2.get(DIGEST_A, {}).get("weekly") is True, "weekly near-limit via weekly_warn_threshold (96 >= 95)")
        check(idx2.get(DIGEST_A, {}).get("5h") is False, "5h NOT near-limit (96 < 99 rotation_threshold)")
        avail, _r, reason = gate(candidate_row(MOCK_TOKEN_A), idx2)
        check(avail is False and reason == "measured_near_limit", "weekly near-limit skips the candidate")

        # --- Case 3: STALE matching digest -> fail-open ---------------------
        print("[case 3] stale matching digest -> fail-open (registry-stamp behavior)")
        c3 = tmp / "c3.json"
        write_cache(c3, five_hour=99.9, seven_day=99.9, written_at=STALE, digest=DIGEST_A)
        idx3 = build_index([c3])
        check(DIGEST_A not in idx3, "stale reading dropped from the index")
        avail, _r, reason = gate(candidate_row(MOCK_TOKEN_A), idx3)
        check(avail is True and reason == "", "stale cache fails OPEN (candidate available)")

        # --- Case 4: missing cache / missing digest -> fail-open ------------
        print("[case 4] missing cache and digest-less cache -> fail-open")
        idx4a = build_index([tmp / "does-not-exist.json"])
        check(idx4a == {}, "absent cache -> empty index")
        c4 = tmp / "c4-nodigest.json"
        write_cache(c4, five_hour=99.9, seven_day=99.9, written_at=FRESH, digest=None)
        idx4b = build_index([c4])
        check(idx4b == {}, "digest-less cache contributes nothing")
        avail, _r, reason = gate(candidate_row(MOCK_TOKEN_A), idx4b)
        check(avail is True and reason == "", "no digest match fails OPEN")

        # --- Case 5: digest MISMATCH -> gate fail-open + monitor diagnostic --
        print("[case 5] digest mismatch -> candidate fail-open; monitor emits wrong_home_cache_split")
        c5 = tmp / "c5.json"
        # Cache belongs to token B; candidate is token A.
        write_cache(c5, five_hour=99.9, seven_day=99.9, written_at=FRESH, digest=DIGEST_B)
        idx5 = build_index([c5])
        check(idx5.get(DIGEST_B, {}).get("5h") is True, "builder indexed the OTHER token's reading")
        avail, _r, reason = gate(candidate_row(MOCK_TOKEN_A), idx5)
        check(avail is True and reason == "", "candidate A is NOT skipped by token B's reading (not misread as its own 0%/crossing)")

        out = run_monitor(tmp, claude_cache=c5, active_digest=DIGEST_A)
        diags = out.get("cache_split_diagnostics") or []
        has_split = any(d.get("reason") == "wrong_home_cache_split" for d in diags)
        check(has_split, "monitor surfaces a wrong_home_cache_split diagnostic")
        if has_split:
            d0 = next(d for d in diags if d.get("reason") == "wrong_home_cache_split")
            check(
                d0.get("cache_digest") == DIGEST_B and d0.get("active_digest") == DIGEST_A,
                "diagnostic reports both one-way digests (no token bytes)",
            )
            # The envelope must not reintroduce the stripped internal field name.
            check("token_digest" not in json.dumps(out), "monitor envelope carries no literal token_digest field")
        check(not (out.get("rotation_candidates") or []), "mismatched reading drives NO rotation candidate (no-signal)")

        # control: matching digest -> no diagnostic key at all (byte-identical envelope)
        c5ok = tmp / "c5-match.json"
        write_cache(c5ok, five_hour=10.0, seven_day=10.0, written_at=FRESH, digest=DIGEST_A)
        out_ok = run_monitor(tmp, claude_cache=c5ok, active_digest=DIGEST_A)
        check("cache_split_diagnostics" not in out_ok, "matching digest -> NO cache_split_diagnostics key (inert envelope unchanged)")

        # malformed `_token_digest` (operator-writable, non-hex): the diagnostic
        # must REDACT it, never echo the raw value into monitor output.
        c5bad = tmp / "c5-malformed.json"
        bad_value = "NOT-A-DIGEST-rawish-leak"
        write_cache(c5bad, five_hour=99.9, seven_day=10.0, written_at=FRESH, digest=bad_value)
        out_bad = run_monitor(tmp, claude_cache=c5bad, active_digest=DIGEST_A)
        bad_diags = out_bad.get("cache_split_diagnostics") or []
        check(bool(bad_diags), "malformed-digest mismatch still surfaces the split (no-signal)")
        check(bad_value not in json.dumps(out_bad), "malformed cache digest is NOT echoed raw into monitor output")
        if bad_diags:
            check(bad_diags[0].get("cache_digest") == "<non-digest>", "malformed cache digest is redacted to <non-digest>")

        # --- Case 6: display-fingerprint-keyed cache never matches ----------
        print("[case 6] a cache keyed by the display token_fingerprint never matches the candidate")
        c6 = tmp / "c6.json"
        write_cache(
            c6, five_hour=99.9, seven_day=99.9, written_at=FRESH,
            digest=auth.token_fingerprint(MOCK_TOKEN_A),  # WRONG format on purpose
        )
        idx6 = build_index([c6])
        avail, _r, reason = gate(candidate_row(MOCK_TOKEN_A), idx6)
        check(
            avail is True and reason == "",
            "display-fingerprint-keyed cache does NOT skip the candidate (proves _token_signal_digest is used)",
        )

        # --- Case 7: B2-dependency note (asserted: the dependency is recorded) -
        print("[case 7] B2-dependency: gate records that the worst-case backstop is PR-B2's --preflight")
        auth_src = (REPO_ROOT / "bridge-auth.py").read_text(encoding="utf-8")
        check(
            "PR-B2" in auth_src and "--preflight" in auth_src and "backstop" in auth_src,
            "gate documents the PR-B2 --preflight backstop (B3 is not standalone worst-case closure)",
        )

    if _failures:
        print(f"[helper] {_failures} assertion(s) FAILED")
        return 1
    print("[helper] all assertions passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
