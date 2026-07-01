#!/usr/bin/env python3
# scripts/smoke/classify-stale-dynamic-exemption.py — direct callee for
# scripts/smoke/classify-stale-dynamic-exemption.sh. Kept as a standalone
# file (not inlined as heredoc-stdin to python3) so the smoke is immune
# to footgun #11 (Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock)
# even if a future caller wraps it in `$()` capture.
#
# Loads bridge-status.py via importlib (the file name has a hyphen so a
# plain import won't work) and runs the classify_stale truth table for
# the idle-staleness carve-outs: dynamic-source exemption plus the
# Issue #2100 codex-engine static exemption (idle codex agents have no
# heartbeat to refresh, so their long idle must not read as stale=crit).

import importlib.util
import pathlib
import sys
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
    classify_stale = module.classify_stale

    now = int(time.time())
    fresh = now - 60
    warn_age = now - 3700
    crit_age = now - 14500

    failures: list[str] = []

    def check(label: str, got: object, want: object) -> None:
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")
        else:
            print(f"  PASS  {label} = {got!r}")

    # static + active + crit-age -> crit (must not regress)
    check(
        "static-crit-stays-crit",
        classify_stale(True, crit_age, 3600, 14400, source="static"),
        "crit",
    )

    # dynamic + active + crit-age -> "-" (the new exemption)
    check(
        "dynamic-crit-becomes-na",
        classify_stale(True, crit_age, 3600, 14400, source="dynamic"),
        "-",
    )

    # dynamic + active + missing activity_ts -> "-"
    check(
        "dynamic-missing-ts-becomes-na",
        classify_stale(True, None, 3600, 14400, source="dynamic"),
        "-",
    )

    # dynamic + inactive -> "-" (early return still wins)
    check(
        "dynamic-inactive-stays-na",
        classify_stale(False, crit_age, 3600, 14400, source="dynamic"),
        "-",
    )

    # Issue #2100: a codex-engine STATIC agent (e.g. patch-dev) has no
    # idle-heartbeat mechanism, so a long idle window with a stale/absent
    # session-activity ts is the healthy normal — it must NOT be flagged
    # crit. Mirror the dynamic carve-out on the engine signal.
    check(
        "codex-static-crit-age-becomes-na",
        classify_stale(True, crit_age, 3600, 14400, source="static", engine="codex"),
        "-",
    )
    # codex-static + missing activity_ts (the observed #2100 shape: no idle
    # heartbeat at all) -> "-" (this is the exact false-positive path).
    check(
        "codex-static-missing-ts-becomes-na",
        classify_stale(True, None, 3600, 14400, source="static", engine="codex"),
        "-",
    )
    # A claude-engine STATIC agent with the same crit-age must STILL be crit —
    # the exemption is engine-scoped, not a blanket static carve-out. Reverting
    # the fix flips codex-static back to crit and turns the two codex cases
    # above RED (mutation proof), while this case is unaffected either way.
    check(
        "claude-static-crit-stays-crit",
        classify_stale(True, crit_age, 3600, 14400, source="static", engine="claude"),
        "crit",
    )

    # static + fresh -> ok
    check(
        "static-fresh-stays-ok",
        classify_stale(True, fresh, 3600, 14400, source="static"),
        "ok",
    )

    # static + warn-age -> warn
    check(
        "static-warn-stays-warn",
        classify_stale(True, warn_age, 3600, 14400, source="static"),
        "warn",
    )

    # legacy positional call (no source kwarg) keeps the old behavior so
    # external diagnostic scripts that imported this function don't
    # silently change semantics.
    check(
        "legacy-no-source-crit",
        classify_stale(True, crit_age, 3600, 14400),
        "crit",
    )
    check(
        "legacy-no-source-warn",
        classify_stale(True, warn_age, 3600, 14400),
        "warn",
    )
    check(
        "legacy-no-source-ok",
        classify_stale(True, fresh, 3600, 14400),
        "ok",
    )

    # source="" (unknown source) -> same as legacy (do not exempt)
    check(
        "empty-source-treated-as-static-like",
        classify_stale(True, crit_age, 3600, 14400, source=""),
        "crit",
    )

    if failures:
        for f in failures:
            print(f"  FAIL  {f}", file=sys.stderr)
        return 1
    print("[smoke:classify-stale-dynamic-exemption] all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
