#!/usr/bin/env python3
"""Behavioral harness for scripts/smoke/2171-rotate-preflight-budget.sh.

#2171 PR-B2 (incident #19460 M4 fleet-down) extends `rotate --preflight` (PR-B1)
with a GLOBAL probe budget so the daemon's reactive rotation can LIVE-probe
candidates without an unbounded ring of slow probes — and FAILS CLOSED when the
budget is spent:

  * ``--preflight-budget <total_sec>`` caps the SUMMED live-probe time across the
    whole ring pass; each candidate's actual probe timeout is
    ``min(--preflight-timeout, remaining_budget)``.
  * A candidate the budget never reached is EXCLUDED with the stable trace reason
    ``preflight_budget_exhausted`` and is NEVER committed from stale registry
    availability — the only commit path stays a parseable live ``available``
    probe.
  * If no candidate clears a live probe before the budget is spent, the result is
    the EXISTING ``skipped:all_tokens_limited`` envelope (active token unchanged,
    sync would NOT trigger), which the daemon already routes through the #1789 D2
    pool-exhausted path. The budget-expiry path NEVER emits a truncated/invalid
    rotate JSON — proven here by feeding every envelope through the real
    ``bridge-daemon-helpers.py rotation-status-parse`` and asserting the daemon
    NEVER classifies it as ``error:invalid_rotation_output``.

The probe is injected — NOT a real network call (same fixture shape as the PR-B1
helper). ``probe_claude_token`` runs ``$BRIDGE_CLAUDE_TOKEN_CHECK_BIN`` with a
per-call ``CLAUDE_CONFIG_DIR``; we point that at a fake ``claude`` that looks up a
per-token verdict and (for the ``timeout`` verdict) sleeps past the candidate's
probe timeout so the budget is genuinely consumed. No heredoc-stdin anywhere
(footgun #11): every file is invoked by path.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BRIDGE_AUTH = REPO_ROOT / "bridge-auth.py"
DAEMON_HELPERS = REPO_ROOT / "bridge-daemon-helpers.py"

# OAT-prefixed so classify_token_kind() returns oauth_oat — the only kind the
# native .credentials.json preflight probe is allowed to judge.
TOK = {
    "A": "sk-ant-oat-aaaaaaaaaaaaaaaa",
    "B": "sk-ant-oat-bbbbbbbbbbbbbbbb",
    "C": "sk-ant-oat-cccccccccccccccc",
    "D": "sk-ant-oat-dddddddddddddddd",
}

_failures: list[str] = []


def check(cond: bool, label: str) -> None:
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}")
        _failures.append(label)


def fp12(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]


def write_registry(path: Path, rows: list[dict], active: str) -> None:
    payload = {
        "version": 1,
        "active_token_id": active,
        "auto_rotate_enabled": True,
        "rotation_threshold": 99.0,
        "weekly_warn_threshold": 95.0,
        "tokens": rows,
        "last_rotation": {},
    }
    path.write_text(json.dumps(payload), encoding="utf-8")


def row(token_id: str, token: str, **extra) -> dict:
    base = {"id": token_id, "token": token, "enabled": True}
    base.update(extra)
    return base


def write_fake_claude(path: Path) -> None:
    """Injected probe binary.

    Reads its handed token from ``$CLAUDE_CONFIG_DIR/.credentials.json``, records
    the probed-token fingerprint to ``$AGB_PROBE_LOG`` (BEFORE any sleep, so a
    timed-out probe still counts as "ran"), looks up ``$AGB_PREFLIGHT_VERDICTS``
    (JSON token->verdict), then emits classify-able JSON. ``timeout`` sleeps past
    the candidate's probe timeout so the global budget is genuinely consumed.
    """
    script = r'''#!/usr/bin/env python3
import json, os, sys, time, hashlib

cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
token = ""
try:
    with open(os.path.join(cfg, ".credentials.json"), encoding="utf-8") as fh:
        token = ((json.load(fh) or {}).get("claudeAiOauth") or {}).get("accessToken") or ""
except Exception:
    token = ""

log = os.environ.get("AGB_PROBE_LOG", "")
if log:
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]
    with open(log, "a", encoding="utf-8") as fh:
        fh.write("probed:" + digest + "\n")

verdicts = json.loads(os.environ.get("AGB_PREFLIGHT_VERDICTS", "{}"))
v = verdicts.get(token, {"status": "available"})
status = v.get("status", "available")

if status == "timeout":
    # Sleep past the candidate's probe timeout; bridge-auth.py SIGKILLs the
    # subprocess at min(--preflight-timeout, remaining_budget), consuming budget.
    time.sleep(int(v.get("sleep", 30)))
    print(json.dumps({"is_error": False, "result": "OK"}))
    sys.exit(0)
if status == "auth_failed":
    print(json.dumps({
        "is_error": True,
        "api_error_status": v.get("api_error_status", "403"),
        "result": "unauthorized",
    }))
    sys.exit(1)
# available
print(json.dumps({"is_error": False, "result": "OK"}))
sys.exit(0)
'''
    path.write_text(script, encoding="utf-8")
    path.chmod(0o755)


def daemon_parse(stdout: str) -> list[str]:
    """Feed a rotate envelope through the REAL daemon-side parser.

    Proves the daemon classification: a valid envelope yields its true
    status/reason; a truncated/invalid JSON would degrade to
    ``error\\tinvalid_rotation_output`` (bridge-daemon-helpers.py:972-1004).
    """
    proc = subprocess.run(
        [sys.executable, str(DAEMON_HELPERS), "rotation-status-parse", stdout],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
    )
    return proc.stdout.rstrip("\n").split("\t")


def run_rotate(workdir: Path, registry: Path, verdicts: dict, *, budget: int, per_candidate: int):
    fake = workdir / "fake-claude"
    write_fake_claude(fake)
    probe_log = workdir / f"{registry.stem}.probe.log"
    env = dict(os.environ)
    for leak in ("BRIDGE_HOME", "BRIDGE_RUNTIME_CONFIG_FILE", "BRIDGE_RUNTIME_ROOT", "BRIDGE_STATE_DIR"):
        env.pop(leak, None)
    env["BRIDGE_CLAUDE_TOKEN_CHECK_BIN"] = str(fake)
    env["AGB_PREFLIGHT_VERDICTS"] = json.dumps(verdicts)
    env["AGB_PROBE_LOG"] = str(probe_log)
    cmd = [
        sys.executable, str(BRIDGE_AUTH), "--registry", str(registry), "rotate",
        "--reason", "smoke", "--preflight",
        "--preflight-budget", str(budget),
        "--preflight-timeout", str(per_candidate),
        "--json",
    ]
    # Wrap in the daemon's default rotate ceiling (30s) to PROVE a budgeted
    # multi-candidate ring finishes well inside it (never SIGKILLed mid-write).
    proc = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=30)
    out = json.loads(proc.stdout) if proc.stdout.strip() else {}
    probes = []
    if probe_log.is_file():
        probes = [ln.split(":", 1)[1] for ln in probe_log.read_text().splitlines() if ln.startswith("probed:")]
    parsed = daemon_parse(proc.stdout) if proc.stdout.strip() else []
    return proc.returncode, out, json.loads(registry.read_text()), probes, parsed


def trace_by_id(out: dict) -> dict:
    return {e.get("id"): e for e in out.get("preflight", [])}


def case1_budget_expires_before_probe(work: Path) -> None:
    print("[case 1] budget expires before a registry-available candidate is probed -> fail-CLOSED")
    reg = work / "c1.json"
    # Ring after active A = [B, C]. B's probe is slow and eats the whole budget;
    # C (registry-available, no adverse stamp) is never reached -> fail-closed.
    write_registry(reg, [row("A", TOK["A"]), row("B", TOK["B"]), row("C", TOK["C"])], active="A")
    rc, out, final, probes, parsed = run_rotate(
        work, reg, {TOK["B"]: {"status": "timeout", "sleep": 30}}, budget=2, per_candidate=2,
    )
    check(out.get("status") == "skipped", "status=skipped (no candidate cleared a live probe)")
    check(out.get("reason") == "all_tokens_limited", "reason=all_tokens_limited (existing envelope)")
    check(final["active_token_id"] == "A", "active token UNCHANGED (never committed off the budget)")
    check(not final.get("last_rotation"), "no last_rotation -> wrapper sync would NOT trigger")
    trace = trace_by_id(out)
    check(trace.get("C", {}).get("reason") == "preflight_budget_exhausted",
          "C trace reason=preflight_budget_exhausted (unprobed, fail-closed)")
    check(trace.get("C", {}).get("outcome") == "skipped", "C outcome=skipped (excluded, not committed)")
    check(trace.get("B", {}).get("reason") == "probe_timeout", "B trace reason=probe_timeout (consumed the budget)")
    check(probes == [fp12(TOK["B"])], "ONLY B was live-probed; C never reached the network (budget bound)")
    check(parsed[:2] == ["skipped", "all_tokens_limited"],
          "daemon parser classifies skipped:all_tokens_limited (NOT error:invalid_rotation_output)")


def case2_three_alternate_ring(work: Path) -> None:
    print("[case 2] 3-alternate ring: earlier probes timeout/fail, last succeeds within budget")
    reg = work / "c2.json"
    # Ring after active A = [B, C, D]. B times out (consumes a slice of budget),
    # C auth-fails fast, D is available within the remaining budget -> commit D.
    write_registry(
        reg,
        [row("A", TOK["A"]), row("B", TOK["B"]), row("C", TOK["C"]), row("D", TOK["D"])],
        active="A",
    )
    rc, out, final, probes, parsed = run_rotate(
        work, reg,
        {TOK["B"]: {"status": "timeout", "sleep": 30},
         TOK["C"]: {"status": "auth_failed", "api_error_status": "403"}},
        budget=6, per_candidate=2,
    )
    check(out.get("status") == "rotated", "status=rotated (last candidate cleared within budget)")
    check(final["active_token_id"] == "D", "committed to D (the live-available candidate)")
    check(final.get("last_rotation", {}).get("to") == "D", "last_rotation.to=D")
    trace = trace_by_id(out)
    check(trace.get("B", {}).get("reason") == "probe_timeout", "B excluded for probe_timeout")
    check(trace.get("C", {}).get("reason") == "probe_auth_failed", "C excluded for probe_auth_failed")
    check(trace.get("D", {}).get("outcome") == "committed", "D outcome=committed")
    check(probes == [fp12(TOK["B"]), fp12(TOK["C"]), fp12(TOK["D"])], "probed B then C then D (bounded one pass)")
    check(parsed[0] == "rotated", "daemon parser classifies rotated (NOT killed -> NOT invalid_rotation_output)")
    check(rc == 0, "rotate exited 0 inside the 30s daemon ceiling (never SIGKILLed)")


def case3_all_fail_and_budget_exhausted(work: Path) -> None:
    print("[case 3] mixed fail (auth) + timeout + budget-exhausted available -> #1789 all_tokens_limited")
    reg = work / "c3.json"
    # Ring after active A = [B, C, D]. B auth-fails fast, C times out and drains
    # the rest of the budget, and D — though registry-AVAILABLE — is then
    # budget-exhausted and FAIL-CLOSED (never committed off the stale flag). The
    # whole pool refusing routes to the existing all_tokens_limited envelope.
    write_registry(
        reg,
        [row("A", TOK["A"]), row("B", TOK["B"]), row("C", TOK["C"]), row("D", TOK["D"])],
        active="A",
    )
    # budget=2: B auth-fails fast (~0.2s), leaving ~1.8s; C's timeout probe is
    # capped to that ~1.8s remainder and consumes ALL of it (a timeout always
    # runs for its full capped budget), so the remainder is < 0 before D is
    # reached -> D is budget-exhausted deterministically regardless of B's exact
    # cost (the invariant: a final timeout candidate drains exactly the budget
    # handed to it).
    rc, out, final, probes, parsed = run_rotate(
        work, reg,
        {TOK["B"]: {"status": "auth_failed", "api_error_status": "401"},
         TOK["C"]: {"status": "timeout", "sleep": 30},
         TOK["D"]: {"status": "available"}},
        budget=2, per_candidate=2,
    )
    check(out.get("status") == "skipped", "status=skipped")
    check(out.get("reason") == "all_tokens_limited", "reason=all_tokens_limited (#1789 D2 path preserved)")
    check(final["active_token_id"] == "A", "active token UNCHANGED")
    check(not final.get("last_rotation"), "no last_rotation -> wrapper sync would NOT trigger")
    trace = trace_by_id(out)
    check(trace.get("B", {}).get("reason") == "probe_auth_failed", "B excluded for probe_auth_failed")
    check(trace.get("C", {}).get("reason") == "probe_timeout", "C excluded for probe_timeout (drained budget)")
    check(trace.get("D", {}).get("reason") == "preflight_budget_exhausted",
          "D fail-closed (preflight_budget_exhausted) — registry-available but never committed")
    check(fp12(TOK["D"]) not in probes, "D was NEVER live-probed (budget spent before it)")
    check(probes == [fp12(TOK["B"]), fp12(TOK["C"])], "probed B then C only (bounded one pass)")
    check(parsed[:2] == ["skipped", "all_tokens_limited"],
          "daemon parser classifies skipped:all_tokens_limited (feeds #1789 pool-exhausted)")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="agb-2171-budget.") as tmp:
        work = Path(tmp)
        case1_budget_expires_before_probe(work)
        case2_three_alternate_ring(work)
        case3_all_fail_and_budget_exhausted(work)
    if _failures:
        print(f"[helper] {len(_failures)} assertion(s) FAILED")
        return 1
    print("[helper] all budget assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
