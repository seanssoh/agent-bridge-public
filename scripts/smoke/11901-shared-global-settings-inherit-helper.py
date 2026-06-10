#!/usr/bin/env python3
"""Helper for scripts/smoke/11901-shared-global-settings-inherit.sh.

Queue request #11901 (operator-approved Option 1, 2026-06-10): a SHARED
(non-isolated) static Claude agent inherits the operator's system-global
`~/.claude/settings.json` as the bottom-most render layer.

This helper drives `bridge-hooks.py render-shared-settings` end to end in a
self-contained tempdir and asserts the six acceptance criteria plus the
safety filter and the fail-safe degrade. It is invoked with file-as-argv
arguments only — NO heredoc-stdin to Python (footgun #11). The orchestrating
shell smoke passes the repo root and a scratch dir; this helper builds every
fixture under that scratch dir and exits non-zero on the first failure with a
diagnostic on stderr.
"""

from __future__ import annotations

import json
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


def _render(
    hooks_py: Path,
    base: Path,
    overlay: Path,
    effective: Path,
    operator_global: Path | None,
    agent_class: str = "static",
    launch_cmd: str = "",
    channels_csv: str = "",
    preserved_effective: dict | None = None,
) -> tuple[subprocess.CompletedProcess[str], dict]:
    if preserved_effective is not None:
        _write(effective, preserved_effective)
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
        "--launch-cmd",
        launch_cmd,
        "--channels-csv",
        channels_csv,
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

    # Use the REAL tracked bridge base so the smoke also guards against a
    # base-side regression (the bridge hooks must survive global inheritance).
    real_base = repo_root / "agents" / ".claude" / "settings.json"
    base = _write(
        scratch / "base" / "settings.json",
        json.loads(real_base.read_text(encoding="utf-8")),
    )
    overlay = _write(scratch / "base" / "settings.local.json", {})

    def stop_hook_cmd(rendered: dict) -> str:
        try:
            return rendered["hooks"]["Stop"][0]["hooks"][0]["command"]
        except (KeyError, IndexError, TypeError):
            return ""

    bridge_stop_present = "mark-idle.sh" in stop_hook_cmd(
        json.loads(real_base.read_text(encoding="utf-8"))
    )
    if not bridge_stop_present:
        print(
            "FATAL: tracked base lacks the expected bridge Stop hook; "
            "fixture assumption broke",
            file=sys.stderr,
        )
        return 2

    # ---- AC1: operator-global key (NOT a managed default) propagates ----
    g1 = _write(
        scratch / "op1" / ".claude" / "settings.json",
        {"agentPushNotifEnabled": True},
    )
    _, eff = _render(hooks_py, base, overlay, scratch / "eff1.json", g1)
    _check(
        "AC1 global key agentPushNotifEnabled propagates to shared agent",
        eff.get("agentPushNotifEnabled") is True,
        detail=json.dumps(eff.get("agentPushNotifEnabled")),
    )
    _check(
        "AC1 bridge Stop hook still present after global inheritance",
        "mark-idle.sh" in stop_hook_cmd(eff),
    )

    # ---- AC2: per-class managed default wins over global ----
    g2 = _write(
        scratch / "op2" / ".claude" / "settings.json",
        {"autoCompactWindow": 1_000_000, "agentPushNotifEnabled": True},
    )
    _, eff = _render(
        hooks_py, base, overlay, scratch / "eff2.json", g2, agent_class="static"
    )
    _check(
        "AC2 static autoCompactWindow=400000 wins over global 1M",
        eff.get("autoCompactWindow") == 400_000,
        detail=str(eff.get("autoCompactWindow")),
    )
    _check(
        "AC2 bridge hooks preserved alongside per-class default",
        "mark-idle.sh" in stop_hook_cmd(eff),
    )
    _check(
        "AC2 a benign global key still propagates next to the preserved one",
        eff.get("agentPushNotifEnabled") is True,
    )

    # ---- AC3: per-agent plugin divergence preserved + independent ----
    _, effA = _render(
        hooks_py,
        base,
        overlay,
        scratch / "effA.json",
        g1,
        preserved_effective={"enabledPlugins": {"foo@mkt": True}},
    )
    _, effB = _render(
        hooks_py,
        base,
        overlay,
        scratch / "effB.json",
        g1,
        preserved_effective={"enabledPlugins": {"bar@mkt": True}},
    )
    _check(
        "AC3 agent A keeps its enabled plugin foo across re-render",
        effA.get("enabledPlugins", {}).get("foo@mkt") is True,
    )
    _check(
        "AC3 agent B is independent (no foo, keeps bar)",
        "foo@mkt" not in effB.get("enabledPlugins", {})
        and effB.get("enabledPlugins", {}).get("bar@mkt") is True,
    )

    # ---- AC4: dynamic agent class — no regression ----
    _, eff = _render(
        hooks_py,
        base,
        overlay,
        scratch / "eff_dyn.json",
        g2,
        agent_class="dynamic",
    )
    _check(
        "AC4 dynamic autoCompactWindow stays 1M (no regression)",
        eff.get("autoCompactWindow") == 1_000_000,
        detail=str(eff.get("autoCompactWindow")),
    )

    # AC5 (iso-v2 unaffected) is structurally guaranteed: the shared renderer
    # is only invoked on the shared path; iso-v2 agents render through
    # cmd_render_isolated_home_settings, which this change does not touch.
    # isolated-settings-rendering.sh is the dedicated guard for that path and
    # is pulled by the same hooks per-file group. We assert here only that the
    # isolated renderer subcommand carries NO --operator-global-settings-file
    # option, proving the inheritance cannot leak into the isolated path.
    help_proc = subprocess.run(
        [sys.executable, str(hooks_py), "render-isolated-home-settings", "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    _check(
        "AC5 isolated renderer has NO operator-global option (iso unaffected)",
        "--operator-global-settings-file" not in help_proc.stdout,
    )

    # ---- Safety filter: sensitive keys dropped, benign inherited ----
    g_sensitive = _write(
        scratch / "op_sens" / ".claude" / "settings.json",
        {
            "agentPushNotifEnabled": True,
            "apiKeyHelper": "/usr/local/bin/get-key.sh",
            "statusLine": {"type": "command", "command": "/Users/op/hud.sh"},
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "/Users/op/evil.sh"}]}
                ]
            },
            "permissions": {"allow": ["Bash(rm:*)"]},
            "env": {"SECRET_TOKEN": "xxx"},
            "awsAuthRefresh": "refresh-cmd",
            "myCustomApiKey": "leak-me",
            "someOauthThing": "leak-too",
        },
    )
    proc, eff = _render(hooks_py, base, overlay, scratch / "eff_sens.json", g_sensitive)
    _check(
        "FILTER benign agentPushNotifEnabled still inherited",
        eff.get("agentPushNotifEnabled") is True,
    )
    _check("FILTER apiKeyHelper dropped from global", "apiKeyHelper" not in eff)
    _check(
        "FILTER global statusLine (operator HUD) dropped",
        eff.get("statusLine", {}).get("command") != "/Users/op/hud.sh",
    )
    _check(
        "FILTER operator hooks did NOT replace bridge Stop hook",
        "mark-idle.sh" in stop_hook_cmd(eff)
        and "/Users/op/evil.sh" not in stop_hook_cmd(eff),
    )
    _check("FILTER permissions dropped", "permissions" not in eff)
    _check("FILTER env dropped", "env" not in eff)
    _check("FILTER awsAuthRefresh dropped", "awsAuthRefresh" not in eff)
    _check(
        "FILTER credential-shaped name myCustomApiKey dropped",
        "myCustomApiKey" not in eff,
    )
    _check(
        "FILTER credential-shaped name someOauthThing dropped",
        "someOauthThing" not in eff,
    )
    _check(
        "FILTER emits a single stderr info line naming the drop",
        "#11901 safety filter" in proc.stderr,
    )

    # ---- FILTER-ALL: an all-denied global still emits the [info] line ----
    # Regression guard for #11901 r2 (codex gate-1): when the operator global
    # contains ONLY denied/sensitive keys, every key is dropped and the
    # inheritable layer is empty — but the keys WERE filtered, so the helper
    # contract (one [info] stderr line naming them) must still fire. The
    # pre-fix code gated the warn on the surviving benign layer, so an
    # all-denied global dropped keys SILENTLY (STDERR_BYTES=0). Assert the
    # info line fires exactly once and the bridge base survives intact.
    g_all_filtered = _write(
        scratch / "op_allfilt" / ".claude" / "settings.json",
        {
            "apiKeyHelper": "/tmp/key",
            "env": {"SECRET_TOKEN": "x"},
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "/tmp/evil"}]}
                ]
            },
        },
    )
    proc, eff = _render(
        hooks_py, base, overlay, scratch / "eff_allfilt.json", g_all_filtered
    )
    info_lines = [
        ln for ln in proc.stderr.splitlines() if "#11901 safety filter" in ln
    ]
    _check(
        "FILTER-ALL apiKeyHelper dropped from all-denied global",
        "apiKeyHelper" not in eff,
    )
    _check(
        "FILTER-ALL env dropped from all-denied global",
        "env" not in eff,
    )
    _check(
        "FILTER-ALL emits EXACTLY ONE [info] line naming the dropped keys",
        len(info_lines) == 1
        and "apiKeyHelper" in info_lines[0]
        and "env" in info_lines[0],
        detail=f"info_lines={info_lines!r}",
    )
    _check(
        "FILTER-ALL bridge Stop hook intact (operator hooks did NOT win)",
        "mark-idle.sh" in stop_hook_cmd(eff)
        and "/tmp/evil" not in stop_hook_cmd(eff),
    )
    _check(
        "FILTER-ALL no denied key spuriously synthesized into base render",
        "agentPushNotifEnabled" not in eff,
    )

    # ---- AC6 / fail-safe: missing global -> degrade to bridge base ----
    _, eff = _render(
        hooks_py,
        base,
        overlay,
        scratch / "eff_missing.json",
        scratch / "does-not-exist" / ".claude" / "settings.json",
    )
    _check(
        "AC6 missing global -> bridge base intact (Stop hook present)",
        "mark-idle.sh" in stop_hook_cmd(eff),
    )
    _check(
        "AC6 missing global -> no key spuriously synthesized",
        "agentPushNotifEnabled" not in eff,
    )

    # Fail-safe: malformed (non-JSON-object) global -> degrade.
    bad = scratch / "op_bad" / ".claude" / "settings.json"
    bad.parent.mkdir(parents=True, exist_ok=True)
    bad.write_text("not json {", encoding="utf-8")
    _, eff = _render(hooks_py, base, overlay, scratch / "eff_bad.json", bad)
    _check(
        "AC6 malformed global -> bridge base intact (Stop hook present)",
        "mark-idle.sh" in stop_hook_cmd(eff),
    )

    # Fail-safe: empty operator-global arg (back-compat with callers that do
    # not pass it at all) renders cleanly.
    _, eff = _render(
        hooks_py, base, overlay, scratch / "eff_empty.json", operator_global=None
    )
    _check(
        "BACKCOMPAT no operator-global arg renders cleanly (Stop present)",
        "mark-idle.sh" in stop_hook_cmd(eff),
    )

    # Fail-safe: explicit empty-string arg behaves like absent (shell passes
    # "" when bridge_agent_operator_home_dir cannot resolve).
    _, eff = _render(
        hooks_py, base, overlay, scratch / "eff_emptystr.json", operator_global=Path("")
    )
    _check(
        "FAILSAFE empty-string global arg degrades cleanly (Stop present)",
        "mark-idle.sh" in stop_hook_cmd(eff),
    )

    if FAILURES:
        print(f"\n{len(FAILURES)} assertion(s) failed:", file=sys.stderr)
        for name in FAILURES:
            print(f"  - {name}", file=sys.stderr)
        return 1
    print("\nall #11901 acceptance + filter + fail-safe assertions passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
