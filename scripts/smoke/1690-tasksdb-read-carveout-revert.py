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
# The two tasks.db branches have DIFFERENT carve-out shapes:
#
#   Non-Bash (protected_path_reason):
#       if read_intent:
#           return None
#       return "direct queue DB access is blocked; …"
#     Revert = drop the `if read_intent:` + `return None` pair, leaving the
#     unconditional deny.
#
#   Bash (protected_alias_reason) — issue #1690 r2 changed this so the
#   read-intent case falls through to the later sibling gates instead of
#   short-circuiting to allow:
#       if not read_intent:
#           return "direct queue DB access is blocked; …"
#     Revert = make the deny UNCONDITIONAL: drop the `if not read_intent:`
#     guard line and de-indent its `return` body by one level. Under the
#     reverted policy a read of tasks.db is denied, so the smoke's revert
#     teeth see DENY (proving the carve-out is load-bearing).
#
# Both reverted shapes deny a tasks.db read. If neither expected shape is
# found above a deny line, the helper exits non-zero so the smoke fails
# loudly rather than silently producing a no-op revert.

import sys

DENY_MARKER = "direct queue DB access is blocked"
_INDENT = "    "


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
    dedent: dict[int, str] = {}
    reverted = 0
    for idx, line in enumerate(lines):
        if DENY_MARKER not in line or "return" not in line:
            continue
        if_read = idx - 2
        ret_none = idx - 1
        guard = idx - 1
        if (
            ret_none >= 0
            and if_read >= 0
            and lines[ret_none].strip() == "return None"
            and lines[if_read].strip() == "if read_intent:"
        ):
            # Non-Bash shape: drop the read-intent allow pair.
            drop.add(ret_none)
            drop.add(if_read)
            reverted += 1
        elif guard >= 0 and lines[guard].strip() == "if not read_intent:":
            # Bash shape: drop the `if not read_intent:` guard and de-indent
            # the deny `return` one level so the deny is unconditional.
            drop.add(guard)
            stripped = lines[idx]
            if stripped.startswith(_INDENT):
                dedent[idx] = stripped[len(_INDENT):]
            else:
                dedent[idx] = stripped
            reverted += 1
        else:
            print(
                f"[revert] tasks.db deny at line {idx + 1} does not match "
                f"either expected carve-out shape (non-Bash `if read_intent:"
                f"`/`return None` or Bash `if not read_intent:`)",
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

    out = []
    for i, ln in enumerate(lines):
        if i in drop:
            continue
        out.append(dedent.get(i, ln))
    with open(dest, "w", encoding="utf-8") as fh:
        fh.writelines(out)
    print(f"[revert] stripped {reverted} tasks.db read-intent carve-out(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
