#!/usr/bin/env python3
"""Helper for scripts/smoke/1759-selfref-global-loop-guard.sh.

Issue #1759: on shared-admin layouts the operator's `~/.claude/settings.json`
is a bridge-managed SYMLINK to an agent's own `settings.effective.json`
(created by `link-shared-settings`). The #11901 operator-global base-read then
becomes SELF-REFERENTIAL for that one agent — its render reads its own
previous output as the bottom layer, a self-sustaining loop (benign-key
resurrection, decay inversion, operator hand-edits surviving only by accident
of the loop rather than via #1756's preserve contract).

This helper drives `bridge-hooks.py render-shared-settings` end to end in a
self-contained tempdir and asserts the loop-guard contract. It is invoked with
file-as-argv arguments only — NO heredoc-stdin to Python (footgun #11). The
orchestrating shell smoke passes the repo root and a scratch dir; this helper
builds every fixture under that scratch dir and exits non-zero on the first
failure with a diagnostic on stderr.

Sub-tests (mapped to the issue's 3-part fix + the brief's smoke matrix):
  (a) SELF-REF: agent whose operator-global resolves to its OWN effective ->
      base = bridge base (loop broken), render succeeds, the seeded benign
      loop key does NOT resurrect, and the PRESERVED user key (`model`) STILL
      SURVIVES via the preserve pass over the existing effective file (#1756).
  (b) NON-SELF-REF: a different agent on the SAME install still inherits the
      global key (AC1 shape) — the one-directional read is untouched.
  (c) NESTED symlink + indeterminate ownership -> safe degrade (loop broken).
  (e) MISSING-GLOBAL degrade unchanged (pre-#11901 / pre-#1759 behavior).

(Sub-test (d) — drift-apply through the self-ref symlink refused without the
explicit flag — is pinned in the shell smoke via the
`bridge_agent_rerender_writes_operator_global` resolver, which reuses this same
detection.)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

FAILURES: list[str] = []


def _check(name: str, cond: bool, detail: str = "") -> None:
    status = "PASS" if cond else "FAIL"
    line = f"{status} - {name}"
    if not cond and detail:
        line += f" :: {detail}"
    print(line)
    if not cond:
        FAILURES.append(name)


def _write(path: Path, obj: object) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2), encoding="utf-8")
    return path


def _stop_hook_cmd(rendered: dict) -> str:
    try:
        return rendered["hooks"]["Stop"][0]["hooks"][0]["command"]
    except (KeyError, IndexError, TypeError):
        return ""


def _render(
    hooks_py: Path,
    base: Path,
    overlay: Path,
    effective: Path,
    operator_global: Path | None,
    agent_class: str = "static",
) -> tuple[subprocess.CompletedProcess[str], dict]:
    cmd = [
        sys.executable,
        str(hooks_py),
        "render-shared-settings",
        "--base-settings-file",
        str(base),
        "--overlay-settings-file",
        str(overlay),
        "--effective-settings-file",
        str(effective),
        "--agent-class",
        agent_class,
    ]
    if operator_global is not None:
        cmd += ["--operator-global-settings-file", str(operator_global)]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise SystemExit(
            f"render-shared-settings exited {proc.returncode}: {proc.stderr}"
        )
    rendered = json.loads(effective.read_text(encoding="utf-8"))
    return proc, rendered


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: helper.py <repo-root> <scratch-dir>", file=sys.stderr)
        return 2
    repo_root = Path(argv[1])
    scratch = Path(argv[2])
    hooks_py = repo_root / "bridge-hooks.py"

    real_base = repo_root / "agents" / ".claude" / "settings.json"
    base = _write(
        scratch / "base" / "settings.json",
        json.loads(real_base.read_text(encoding="utf-8")),
    )
    overlay = _write(scratch / "base" / "settings.local.json", {})

    if "mark-idle.sh" not in _stop_hook_cmd(
        json.loads(real_base.read_text(encoding="utf-8"))
    ):
        print(
            "FATAL: tracked base lacks the expected bridge Stop hook; "
            "fixture assumption broke",
            file=sys.stderr,
        )
        return 2

    # ---- (a) SELF-REF: operator-global symlink -> agent A's own effective ----
    # The effective file at the per-agent render target shape so the detection
    # pattern (leaf settings.effective.json under .claude) matches.
    effA = scratch / "agents" / "A" / ".claude" / "settings.effective.json"
    effA.parent.mkdir(parents=True, exist_ok=True)
    # Seed the EXISTING effective file with (1) a benign key that ONLY ever
    # entered via the loop and (2) a PRESERVED_USER_KEY (`model`) that the
    # operator pinned. The loop-break must drop the former (no resurrection)
    # while the latter SURVIVES the rerender via the preserve pass.
    effA.write_text(
        json.dumps(
            {
                "benignResurrect": "should-not-survive-the-loop-break",
                "model": "claude-opus-4-8[1m]",
            }
        ),
        encoding="utf-8",
    )
    op_home = scratch / "op-home" / ".claude"
    op_home.mkdir(parents=True, exist_ok=True)
    op_global = op_home / "settings.json"
    os.symlink(effA, op_global)

    proc, eff = _render(hooks_py, base, overlay, effA, op_global)
    _check(
        "SELF-REF loop-break info line names #1759",
        "#1759" in proc.stderr,
        detail=proc.stderr,
    )
    _check(
        "SELF-REF benign loop key did NOT resurrect (decay not inverted)",
        "benignResurrect" not in eff,
        detail=json.dumps(sorted(eff.keys())),
    )
    _check(
        "SELF-REF preserved user key `model` STILL survives via preserve pass (#1756)",
        eff.get("model") == "claude-opus-4-8[1m]",
        detail=json.dumps(eff.get("model")),
    )
    _check(
        "SELF-REF bridge Stop hook intact (degraded to bridge base, render ok)",
        "mark-idle.sh" in _stop_hook_cmd(eff),
    )

    # ---- (b) NON-SELF-REF: a DIFFERENT agent on the SAME install inherits ----
    # Point the SAME operator-global symlink target at a benign global-only
    # key, then render agent B (whose effective file is a different path). B's
    # one-directional read through the symlink must still inherit it (AC1).
    effA.write_text(
        json.dumps(
            {"agentPushNotifEnabled": True, "model": "claude-opus-4-8[1m]"}
        ),
        encoding="utf-8",
    )
    effB = scratch / "agents" / "B" / ".claude" / "settings.effective.json"
    effB.parent.mkdir(parents=True, exist_ok=True)
    procB, effBr = _render(hooks_py, base, overlay, effB, op_global)
    _check(
        "NON-SELF-REF agent B inherits operator-global key (AC1 shape intact)",
        effBr.get("agentPushNotifEnabled") is True,
        detail=json.dumps(effBr.get("agentPushNotifEnabled")),
    )
    _check(
        "NON-SELF-REF agent B render emits NO #1759 loop-break line",
        "#1759" not in procB.stderr,
        detail=procB.stderr,
    )

    # ---- (c) NESTED symlink chain -> still detected as self-ref for owner ----
    effC = scratch / "agents" / "C" / ".claude" / "settings.effective.json"
    effC.parent.mkdir(parents=True, exist_ok=True)
    effC.write_text(json.dumps({"model": "claude-opus-4-8[1m]"}), encoding="utf-8")
    inter = scratch / "intermediate.json"
    os.symlink(effC, inter)
    op_home_c = scratch / "op-home-c" / ".claude"
    op_home_c.mkdir(parents=True, exist_ok=True)
    op_global_nested = op_home_c / "settings.json"
    os.symlink(inter, op_global_nested)
    procC, effCr = _render(hooks_py, base, overlay, effC, op_global_nested)
    _check(
        "NESTED self-ref (settings.json -> X -> effective) -> loop broken",
        "#1759" in procC.stderr,
        detail=procC.stderr,
    )
    _check(
        "NESTED self-ref preserved `model` still survives",
        effCr.get("model") == "claude-opus-4-8[1m]",
        detail=json.dumps(effCr.get("model")),
    )

    # ---- (e) MISSING-GLOBAL degrade unchanged ----
    effD = scratch / "agents" / "D" / ".claude" / "settings.effective.json"
    procD, effDr = _render(
        hooks_py,
        base,
        overlay,
        effD,
        scratch / "does-not-exist" / ".claude" / "settings.json",
    )
    _check(
        "MISSING-GLOBAL degrade: bridge base intact (Stop hook present)",
        "mark-idle.sh" in _stop_hook_cmd(effDr),
    )
    _check(
        "MISSING-GLOBAL degrade: no #1759 loop-break line (not output-shaped)",
        "#1759" not in procD.stderr,
        detail=procD.stderr,
    )

    if FAILURES:
        print(f"\n{len(FAILURES)} assertion(s) failed:", file=sys.stderr)
        for name in FAILURES:
            print(f"  - {name}", file=sys.stderr)
        return 1
    print("\nall #1759 self-ref loop-guard assertions passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
