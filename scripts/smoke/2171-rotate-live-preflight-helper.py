#!/usr/bin/env python3
"""Behavioral harness for scripts/smoke/2171-rotate-live-preflight.sh.

#2171 (incident #19460 M4 fleet-down): `bridge-auth.py rotate --preflight`
LIVE-probes the selected rotation candidate before committing the active
pointer, instead of trusting stale registry health flags (the fail-open
cascade that could pick a dead token and sync it fleet-wide).

The probe is injected — NOT a real network call. ``probe_claude_token`` runs
``$BRIDGE_CLAUDE_TOKEN_CHECK_BIN -p ... --output-format json`` with a per-call
``CLAUDE_CONFIG_DIR``; we point that env at a fake ``claude`` that reads the
candidate token it was handed (from ``$CLAUDE_CONFIG_DIR/.credentials.json``),
looks up a per-token verdict, optionally mutates the registry mid-probe (to
exercise the unlocked-window race), then emits the canned classify-able JSON.

No heredoc-stdin anywhere (footgun #11): every helper file is invoked by path,
and the fake claude is written with ``printf``-style Python string writes.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BRIDGE_AUTH = REPO_ROOT / "bridge-auth.py"

# OAT-prefixed (sk-ant-oat) so classify_token_kind() returns oauth_oat — the
# only kind the native .credentials.json preflight probe is allowed to judge.
TOK = {
    "A": "sk-ant-oat-aaaaaaaaaaaaaaaa",
    "B": "sk-ant-oat-bbbbbbbbbbbbbbbb",
    "C": "sk-ant-oat-cccccccccccccccc",
    "B2": "sk-ant-oat-bbbbbbbb22222222",
}

_failures: list[str] = []


def check(cond: bool, label: str) -> None:
    if cond:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}")
        _failures.append(label)


def write_registry(path: Path, rows: list[dict], active: str, auto_rotate: bool = True) -> None:
    payload = {
        "version": 1,
        "active_token_id": active,
        "auto_rotate_enabled": auto_rotate,
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


def fingerprint(token: str) -> str:
    import hashlib

    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    tail = token[-4:] if len(token) >= 4 else token
    return f"sha256:{digest[:12]}...{tail}"


def write_fake_claude(path: Path) -> None:
    """Write the injected probe binary.

    Reads its handed token from ``$CLAUDE_CONFIG_DIR/.credentials.json``, looks
    up ``$AGB_PREFLIGHT_VERDICTS`` (JSON token->verdict), optionally mutates the
    registry at ``$AGB_PREFLIGHT_REGISTRY`` (the unlocked-window race), records
    the probed-token fingerprint to ``$AGB_PROBE_LOG``, then emits classify-able
    JSON. verdict.status in {available, quota_limited, auth_failed, timeout}.
    """
    script = r'''#!/usr/bin/env python3
import fcntl, json, os, sys, time, hashlib

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

# Prove the probe runs with the registry lock RELEASED: try to grab the sibling
# .lock non-blocking; success => rotate is not holding it during the probe.
if v.get("assert_unlocked"):
    marker = os.environ.get("AGB_LOCK_MARKER", "")
    reg = os.environ.get("AGB_PREFLIGHT_REGISTRY", "")
    result = "unknown"
    if marker and reg:
        lock_path = os.path.splitext(reg)[0] + ".lock"
        lfd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = "unlocked"
            fcntl.flock(lfd, fcntl.LOCK_UN)
        except BlockingIOError:
            result = "locked"
        finally:
            os.close(lfd)
        with open(marker, "w", encoding="utf-8") as fh:
            fh.write(result)

# Unlocked-window race injection: mutate the registry while rotate has released
# the lock for this probe (replace a candidate's token value, or move active).
mutate = v.get("mutate")
if mutate:
    reg_path = os.environ.get("AGB_PREFLIGHT_REGISTRY", "")
    if reg_path:
        with open(reg_path, encoding="utf-8") as fh:
            reg = json.load(fh)
        if "active_token_id" in mutate:
            reg["active_token_id"] = mutate["active_token_id"]
        if "replace_id" in mutate:
            for r in reg.get("tokens", []):
                if r.get("id") == mutate["replace_id"]:
                    r["token"] = mutate["replace_token"]
        with open(reg_path, "w", encoding="utf-8") as fh:
            json.dump(reg, fh)

status = v.get("status", "available")
if status == "timeout":
    time.sleep(int(v.get("sleep", 3)))
    print(json.dumps({"is_error": False, "result": "OK"}))
    sys.exit(0)
if status == "quota_limited":
    print(json.dumps({
        "is_error": True,
        "api_error_status": "429",
        "result": "You have hit your limit. resets Jul 1 at 12pm (UTC)",
    }))
    sys.exit(1)
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


def run_rotate(workdir: Path, registry: Path, verdicts: dict, *, preflight: bool, timeout: int = 12):
    fake = workdir / "fake-claude"
    write_fake_claude(fake)
    # Per-registry probe log (fresh per case) so the accumulating "which tokens
    # were probed" assertion is not polluted by a prior case in the same tmpdir.
    probe_log = workdir / f"{registry.stem}.probe.log"
    env = dict(os.environ)
    # Hermetic: no live runtime, no real claude, no network.
    for leak in ("BRIDGE_HOME", "BRIDGE_RUNTIME_CONFIG_FILE", "BRIDGE_RUNTIME_ROOT", "BRIDGE_STATE_DIR"):
        env.pop(leak, None)
    lock_marker = workdir / f"{registry.stem}.lockcheck"
    env["BRIDGE_CLAUDE_TOKEN_CHECK_BIN"] = str(fake)
    env["AGB_PREFLIGHT_VERDICTS"] = json.dumps(verdicts)
    env["AGB_PREFLIGHT_REGISTRY"] = str(registry)
    env["AGB_PROBE_LOG"] = str(probe_log)
    env["AGB_LOCK_MARKER"] = str(lock_marker)
    cmd = [sys.executable, str(BRIDGE_AUTH), "--registry", str(registry), "rotate",
           "--reason", "smoke", "--json"]
    if preflight:
        cmd += ["--preflight", "--preflight-timeout", str(timeout)]
    proc = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=120)
    out = json.loads(proc.stdout) if proc.stdout.strip() else {}
    probes = []
    if probe_log.is_file():
        probes = [ln.split(":", 1)[1] for ln in probe_log.read_text().splitlines() if ln.startswith("probed:")]
    lock_state = lock_marker.read_text().strip() if lock_marker.is_file() else ""
    return proc.returncode, out, json.loads(registry.read_text()), probes, lock_state


def fp12(token: str) -> str:
    import hashlib

    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]


def case1_available(work: Path) -> None:
    print("[case 1] selected candidate available -> commit")
    reg = work / "c1.json"
    write_registry(reg, [row("A", TOK["A"]), row("B", TOK["B"])], active="A")
    rc, out, final, probes, lock_state = run_rotate(
        work, reg, {TOK["B"]: {"status": "available", "assert_unlocked": True}}, preflight=True
    )
    check(out.get("status") == "rotated", "status=rotated")
    check(out.get("active_token_id") == "B", "active_token_id=B in payload")
    check(final["active_token_id"] == "B", "registry active committed to B")
    check(final.get("last_rotation", {}).get("to") == "B", "last_rotation.to=B")
    check(out.get("fingerprint") == fingerprint(TOK["B"]), "payload fingerprint matches B")
    check(probes == [fp12(TOK["B"])], "exactly B was live-probed")
    check(lock_state == "unlocked", "probe ran with registry lock RELEASED (never probes under lock)")


def case2_adverse_cascade(work: Path) -> None:
    print("[case 2] adverse candidate (quota/auth/403/timeout) excluded -> next ring candidate")
    for label, bverdict, expect_status in (
        ("quota", {"status": "quota_limited"}, "quota_limited"),
        ("auth403", {"status": "auth_failed", "api_error_status": "403"}, "auth_failed"),
        ("timeout", {"status": "timeout", "sleep": 2}, "timeout"),
    ):
        reg = work / f"c2-{label}.json"
        write_registry(reg, [row("A", TOK["A"]), row("B", TOK["B"]), row("C", TOK["C"])], active="A")
        rc, out, final, probes, _ = run_rotate(
            work, reg, {TOK["B"]: bverdict, TOK["C"]: {"status": "available"}},
            preflight=True, timeout=1,
        )
        check(out.get("status") == "rotated", f"[{label}] rotated past adverse B")
        check(final["active_token_id"] == "C", f"[{label}] committed to C (not adverse B)")
        brow = next(r for r in final["tokens"] if r["id"] == "B")
        check(brow.get("last_check_status") == expect_status, f"[{label}] B evidence last_check_status={expect_status}")
        check(brow.get("enabled") is True, f"[{label}] B never permanently disabled (enabled stays True)")
        if label == "quota":
            check(bool(brow.get("limited_until")), "[quota] B limited_until persisted from probe reset")
        check(probes == [fp12(TOK["B"]), fp12(TOK["C"])], f"[{label}] probed B then C (bounded one pass)")


def case3_all_limited(work: Path) -> None:
    print("[case 3] every candidate adverse -> skipped:all_tokens_limited, no mutation, no sync")
    reg = work / "c3.json"
    write_registry(reg, [row("A", TOK["A"]), row("B", TOK["B"]), row("C", TOK["C"])], active="A")
    rc, out, final, probes, _ = run_rotate(
        work, reg,
        {TOK["B"]: {"status": "quota_limited"}, TOK["C"]: {"status": "auth_failed", "api_error_status": "401"}},
        preflight=True, timeout=1,
    )
    check(out.get("status") == "skipped", "status=skipped")
    check(out.get("reason") == "all_tokens_limited", "reason=all_tokens_limited")
    check(final["active_token_id"] == "A", "active UNCHANGED (no mutation)")
    check(not final.get("last_rotation"), "no last_rotation recorded (sync would NOT trigger)")
    check(sorted(probes) == sorted([fp12(TOK["B"]), fp12(TOK["C"])]), "both candidates probed once (bounded)")


def case4_revalidation_discard(work: Path) -> None:
    print("[case 4] candidate replaced mid-probe -> stale probe DISCARDED, wrong-row commit 0")
    reg = work / "c4.json"
    write_registry(reg, [row("A", TOK["A"]), row("B", TOK["B"]), row("C", TOK["C"])], active="A")
    # B probes "available" but DURING the unlocked probe its token value is
    # replaced (fingerprint changes). Commit revalidation must discard B and
    # advance to C — B must NEVER be committed on the stale probe.
    rc, out, final, probes, _ = run_rotate(
        work, reg,
        {
            TOK["B"]: {"status": "available", "mutate": {"replace_id": "B", "replace_token": TOK["B2"]}},
            TOK["C"]: {"status": "available"},
        },
        preflight=True,
    )
    check(out.get("status") == "rotated", "status=rotated (recovered to a valid candidate)")
    check(final["active_token_id"] == "C", "committed to C, NOT the replaced B")
    check(final.get("last_rotation", {}).get("to") == "C", "last_rotation.to=C")
    trace = {e["id"]: e for e in out.get("preflight", [])}
    check(trace.get("B", {}).get("outcome") == "discarded", "B trace outcome=discarded")
    check(trace.get("B", {}).get("reason") == "revalidation_failed", "B discarded for revalidation_failed")
    brow = next(r for r in final["tokens"] if r["id"] == "B")
    check(brow.get("last_activated_at") in (None, ""), "replaced B was never activated")


def regression_off(work: Path) -> None:
    print("[regression] --preflight OFF -> legacy stale-flag cascade, NO live probe")
    reg = work / "off.json"
    write_registry(reg, [row("A", TOK["A"]), row("B", TOK["B"])], active="A")
    # Verdict says B would FAIL a probe; OFF mode must ignore it (no probe) and
    # still rotate to B on the stale-flag cascade (B has no adverse stamp).
    rc, out, final, probes, _ = run_rotate(work, reg, {TOK["B"]: {"status": "auth_failed"}}, preflight=False)
    check(out.get("status") == "rotated", "OFF: rotated to B on stale-flag cascade")
    check(final["active_token_id"] == "B", "OFF: active committed to B")
    check(probes == [], "OFF: candidate was NEVER live-probed (legacy behavior)")
    check("preflight" not in out, "OFF: no additive preflight trace in payload")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="agb-2171.") as tmp:
        work = Path(tmp)
        case1_available(work)
        case2_adverse_cascade(work)
        case3_all_limited(work)
        case4_revalidation_discard(work)
        regression_off(work)
    if _failures:
        print(f"[helper] {len(_failures)} assertion(s) FAILED")
        return 1
    print("[helper] all assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
