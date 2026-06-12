#!/usr/bin/env python3
# scripts/smoke/1844-plugin-liveness-probe.py — direct callee for
# scripts/smoke/1844-plugin-liveness-probe.sh. Standalone .py (not
# heredoc-stdin to python3) so the smoke is immune to footgun #11
# (Bash 5.3.9 read_comsub / heredoc_write deadlock) even if a future
# caller wraps it in `$()` capture.
#
# Issue #1844: bridge-status.py's Plugin Liveness section emitted
# "<channel>=unknown" for every agent on every host because
# plugins_for_agent() hardcoded "status": "unknown" and no probe was
# ever wired. This smoke pins the now-wired discord-relay probe and the
# "make it real or make it silent" contract: a channel type with no
# probe is omitted, a probed channel reflects real ok/stale/issue state.
#
# Loads bridge-status.py via importlib (the file name has a hyphen so a
# plain import won't work).

import importlib.util
import json
import pathlib
import sys
import tempfile
import time


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    status_path = repo_root / "bridge-status.py"
    spec = importlib.util.spec_from_file_location(
        "bridge_status_under_test", status_path
    )
    if spec is None or spec.loader is None:
        print(f"[smoke] cannot load {status_path}", file=sys.stderr)
        return 2
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    discord_liveness_by_agent = module.discord_liveness_by_agent
    plugin_liveness_sources = module.plugin_liveness_sources
    plugins_for_agent = module.plugins_for_agent
    stale_seconds = int(module.DISCORD_RELAY_STALE_SECONDS)

    failures: list[str] = []

    def check(label: str, got: object, want: object) -> None:
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")
        else:
            print(f"  PASS  {label} = {got!r}")

    now = int(time.time())
    fresh = now - 30
    stale = now - (stale_seconds + 120)

    with tempfile.TemporaryDirectory() as tmp:
        state_dir = pathlib.Path(tmp)
        relay = {
            "channels": {
                # agent-a: a healthy recently-polled channel -> ok
                "111": {"agent": "agent-a", "last_seen_ts": fresh},
                # agent-b: last_error newer than last_seen -> issue(reason)
                "222": {
                    "agent": "agent-b",
                    "last_seen_ts": stale,
                    "last_error_ts": now,
                    "last_suppressed_reason": "enqueue_failed",
                },
                # agent-c: polled long ago, no error -> stale(age)
                "333": {"agent": "agent-c", "last_seen_ts": stale},
                # agent-d two channels: one ok, one issue -> worst (issue) wins
                "444": {"agent": "agent-d", "last_seen_ts": fresh},
                "555": {
                    "agent": "agent-d",
                    "last_seen_ts": fresh,
                    "last_error_ts": now,
                    "last_suppressed_reason": "cooldown",
                },
            }
        }
        (state_dir / "discord-relay.json").write_text(
            json.dumps(relay), encoding="utf-8"
        )

        probe = discord_liveness_by_agent(str(state_dir))
        check("agent-a discord ok", probe.get("agent-a", {}).get("status"), "ok")
        check(
            "agent-b discord issue",
            probe.get("agent-b", {}).get("status"),
            "issue",
        )
        check(
            "agent-b issue reason surfaced",
            probe.get("agent-b", {}).get("detail"),
            "enqueue_failed",
        )
        check(
            "agent-c discord stale",
            probe.get("agent-c", {}).get("status"),
            "stale",
        )
        # worst-status-wins collapse for a multi-channel agent
        check(
            "agent-d worst status wins (issue over ok)",
            probe.get("agent-d", {}).get("status"),
            "issue",
        )

        sources = plugin_liveness_sources(str(state_dir))
        check("liveness sources expose discord", "discord" in sources, True)

        # plugins_for_agent: discord plugin gets the probed status (NOT
        # "unknown"); a channel type with no probe (telegram) is omitted.
        row_a = {
            "agent": "agent-a",
            "configured_channels": "plugin:discord,plugin:telegram",
            "workdir": "/nonexistent",
        }
        plugins_a = plugins_for_agent(row_a, sources)
        names_a = sorted(str(p["name"]) for p in plugins_a)
        check("agent-a omits unprobed telegram", names_a, ["discord"])
        discord_a = next(p for p in plugins_a if p["name"] == "discord")
        check("agent-a discord not unknown", discord_a["status"], "ok")
        check(
            "no 'unknown' status leaks through",
            all(p["status"] != "unknown" for p in plugins_a),
            True,
        )

        # An agent whose only configured channel has no probe yields no
        # rows at all -> the renderer's "suppress when empty" path keeps
        # the section silent instead of printing all-unknown noise.
        row_silent = {
            "agent": "agent-z",
            "configured_channels": "plugin:telegram",
            "workdir": "/nonexistent",
        }
        check(
            "unprobed-only agent yields no plugin rows",
            plugins_for_agent(row_silent, sources),
            [],
        )

    # Malformed timestamps (string / dict) must NOT crash the probe — a
    # truncated or hand-edited discord-relay.json should degrade to a verdict,
    # not take down the whole dashboard + --json render.
    with tempfile.TemporaryDirectory() as tmp2:
        state_dir2 = pathlib.Path(tmp2)
        bad = {
            "channels": {
                # string timestamp -> coerced to 0 -> stale(no_poll), no crash
                "777": {"agent": "agent-bad", "last_seen_ts": "not-a-number"},
                # dict timestamp on the error field -> coerced to 0
                "888": {
                    "agent": "agent-bad2",
                    "last_seen_ts": now,
                    "last_error_ts": {},
                },
                # JSON 1e400 parses to float('inf'); int(inf) raises
                # OverflowError -> must coerce to 0 (stale), not crash.
                "999": {"agent": "agent-inf", "last_seen_ts": 1e400},
            }
        }
        (state_dir2 / "discord-relay.json").write_text(
            json.dumps(bad), encoding="utf-8"
        )
        bad_probe = discord_liveness_by_agent(str(state_dir2))
        check(
            "malformed last_seen_ts degrades to stale (no crash)",
            bad_probe.get("agent-bad", {}).get("status"),
            "stale",
        )
        check(
            "malformed last_error_ts ignored -> ok (no crash)",
            bad_probe.get("agent-bad2", {}).get("status"),
            "ok",
        )
        check(
            "non-finite (1e400/inf) last_seen_ts -> stale (no OverflowError)",
            bad_probe.get("agent-inf", {}).get("status"),
            "stale",
        )

    # Outright invalid JSON -> empty probe map (silent), not a crash.
    with tempfile.TemporaryDirectory() as tmp3:
        bad_json = pathlib.Path(tmp3) / "discord-relay.json"
        bad_json.write_text("{not valid json", encoding="utf-8")
        check(
            "invalid JSON -> empty probe",
            discord_liveness_by_agent(str(tmp3)),
            {},
        )

    # No relay file at all -> empty probe map (silent), not a crash.
    with tempfile.TemporaryDirectory() as empty:
        check(
            "missing relay file -> empty probe",
            discord_liveness_by_agent(empty),
            {},
        )
    check("empty state_dir -> empty probe", discord_liveness_by_agent(""), {})

    if failures:
        for f in failures:
            print(f"  FAIL  {f}", file=sys.stderr)
        return 1
    print("[smoke:1844-plugin-liveness-probe] all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
