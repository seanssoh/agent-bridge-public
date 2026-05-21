#!/usr/bin/env python3
# scripts/smoke/common-instructions-local-override.py — direct callee for
# scripts/smoke/common-instructions-local-override.sh. Kept as a standalone
# file (not inlined as heredoc-stdin to python3) so the smoke is immune to
# footgun #11 (Bash 5.3.9 read_comsub / heredoc_write deadlock) even if a
# future caller wraps it in `$()` capture.
#
# Loads bridge-docs.py via importlib (the hyphenated filename blocks a plain
# import) and exercises render_shared_common_instructions_md()'s machine-local
# override path: COMMON-INSTRUCTIONS.local.md is appended under explicit
# markers when present, and absent / empty / unreadable degrade to a
# byte-identical no-op so a doc render never aborts an upgrade.

import importlib.util
import os
import pathlib
import sys
import tempfile


def load_bridge_docs():
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    docs_path = repo_root / "bridge-docs.py"
    spec = importlib.util.spec_from_file_location("bridge_docs_under_test", docs_path)
    if spec is None or spec.loader is None:
        print(f"[smoke] cannot load {docs_path}", file=sys.stderr)
        return None
    module = importlib.util.module_from_spec(spec)
    # bridge-docs.py defines @dataclass types whose field-type resolution
    # walks sys.modules[cls.__module__]; register before exec_module so the
    # dataclass machinery can find the module under test.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    m = load_bridge_docs()
    if m is None:
        return 2

    failures: list[str] = []

    def check(label: str, cond: bool) -> None:
        if cond:
            print(f"  PASS  {label}")
        else:
            failures.append(label)
            print(f"  FAIL  {label}", file=sys.stderr)

    with tempfile.TemporaryDirectory() as td:
        bridge_home = pathlib.Path(td)
        (bridge_home / "shared").mkdir()
        local = bridge_home / "shared" / "COMMON-INSTRUCTIONS.local.md"
        render = m.render_shared_common_instructions_md

        # absent: no override file → no marker
        out_absent = render(bridge_home)
        check("absent: no local-override marker", m.LOCAL_OVERRIDE_BEGIN not in out_absent)

        # empty / whitespace-only → byte-identical to absent
        local.write_text("   \n\t\n", encoding="utf-8")
        check("empty: byte-identical to absent", render(bridge_home) == out_absent)

        # present → appended under explicit markers, content carried through
        local.write_text("## Local rule\n- do the thing on request", encoding="utf-8")
        out_present = render(bridge_home)
        check("present: begin marker", m.LOCAL_OVERRIDE_BEGIN in out_present)
        check("present: end marker", m.LOCAL_OVERRIDE_END in out_present)
        check("present: local content included", "do the thing on request" in out_present)
        check("present: base content preserved", out_present.startswith(out_absent.rstrip()))

        # idempotent: re-render with the same input is stable
        check("idempotent: re-render stable", render(bridge_home) == out_present)

        # unreadable → degrade to no-op (skipped when the run is privileged
        # enough that chmod 000 does not actually block the read)
        os.chmod(local, 0o000)
        try:
            if os.access(local, os.R_OK):
                print("  SKIP  unreadable: file still readable (privileged run)")
            else:
                check("unreadable: degrades to absent output", render(bridge_home) == out_absent)
        finally:
            os.chmod(local, 0o644)

    if failures:
        print(
            f"[smoke:common-instructions-local-override] {len(failures)} check(s) FAILED",
            file=sys.stderr,
        )
        return 1
    print("[smoke:common-instructions-local-override] all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
