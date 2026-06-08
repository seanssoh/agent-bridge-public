#!/usr/bin/env python3
# scripts/smoke/1690-tasksdb-read-carveout-revert.py — revert-teeth helper
# for the #1690 KEEP-invariant smoke.
#
# Produces a copy of hooks/tool-policy.py with the #1690 read-intent
# carve-out removed from BOTH tasks.db branches, so the smoke can prove the
# read it asserts as ALLOW is genuinely DENIED once the carve-out is gone
# (i.e. the smoke would FAIL the moment the fix is reverted — no false
# green). Standalone script (file-as-argv) so no interpreter heredoc-stdin
# is needed (footgun #11).
#
# Surgical revert: for every line that contains the tasks.db deny string,
# walk back over the two carve-out lines that immediately precede it —
#   if read_intent:
#       return None
# — and drop them. Nothing else in the file is touched. If the expected
# pair is not found above a deny, the helper exits non-zero so the smoke
# fails loudly rather than silently producing a no-op revert.

import sys

DENY_MARKER = "direct queue DB access is blocked"


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: 1690-tasksdb-read-carveout-revert.py <src> <dest>",
            file=sys.stderr,
        )
        return 2
    src, dest = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as fh:
        lines = fh.readlines()

    drop: set[int] = set()
    reverted = 0
    for idx, line in enumerate(lines):
        if DENY_MARKER not in line:
            continue
        # The deny line is `return "direct queue DB access is blocked…"`.
        # Walk back skipping the deny's own `return` line: the two lines
        # immediately above it (skipping the `return` that holds the
        # marker) must be the carve-out pair.
        ret_none = idx - 1
        if_read = idx - 2
        if (
            ret_none >= 0
            and if_read >= 0
            and lines[ret_none].strip() == "return None"
            and lines[if_read].strip() == "if read_intent:"
        ):
            drop.add(ret_none)
            drop.add(if_read)
            reverted += 1
        else:
            print(
                f"[revert] expected `if read_intent:` / `return None` carve-out "
                f"above the tasks.db deny at line {idx + 1}, not found",
                file=sys.stderr,
            )
            return 3

    if reverted != 2:
        print(
            f"[revert] expected to revert 2 tasks.db carve-outs "
            f"(non-Bash + Bash), reverted {reverted}",
            file=sys.stderr,
        )
        return 4

    out = [ln for i, ln in enumerate(lines) if i not in drop]
    with open(dest, "w", encoding="utf-8") as fh:
        fh.writelines(out)
    print(f"[revert] stripped {reverted} tasks.db read-intent carve-out(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
