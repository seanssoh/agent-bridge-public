#!/usr/bin/env python3
# scripts/smoke/classify-stale-dynamic-exemption.py — direct callee for
# scripts/smoke/classify-stale-dynamic-exemption.sh. Kept as a standalone
# file (not inlined as heredoc-stdin to python3) so the smoke is immune
# to footgun #11 (Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock)
# even if a future caller wraps it in `$()` capture.
#
# Loads bridge-status.py via importlib (the file name has a hyphen so a
# plain import won't work) and runs the classify_stale truth table for
# dynamic-source exemption.

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
