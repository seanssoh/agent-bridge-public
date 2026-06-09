#!/usr/bin/env python3
"""Build a #1709-suffix-deny-stripped copy of hooks/tool-policy.py for the
revert-teeth proof in scripts/smoke/1709-shared-secret-suffix-guard.sh.

Removes the two #1709 suffix-deny call-site blocks (Stage-A shared + Stage-B
peer-home) so the brace / $BRIDGE_HOME / path-resolution cases revert to the
pre-fix ALLOW — proving the deny blocks are load-bearing.

Invoked file-as-argv (NOT heredoc-stdin) to honor footgun #11 / lint-heredoc-ban:
    python3 1709-shared-secret-suffix-guard-strip.py <real-hook> <out-stripped>
"""
import sys


def main() -> int:
    real, out = sys.argv[1], sys.argv[2]
    src = open(real, encoding="utf-8").read()

    # Stage-A: drop the `shared_suffix_hit` deny block.
    a_start = src.find(
        "    # Issue #1709 — prefix-spelling-agnostic Stage-A suffix deny."
    )
    a_end = src.find(
        "    # Issue #1692 — admin read-intent carve-out for the Bash PEER-HOME",
        a_start if a_start != -1 else 0,
    )
    if a_start == -1 or a_end == -1 or a_end < a_start:
        sys.stderr.write("could not locate #1709 Stage-A suffix-deny block\n")
        return 3
    src = src[:a_start] + src[a_end:]

    # Stage-B: drop the `peer_suffix_hit` block (between the matched_alias
    # assignment and the `if matched_alias is None: return None`).
    b_start = src.find(
        "    # Issue #1709 — prefix-spelling-agnostic Stage-B peer-home matcher."
    )
    b_end = src.find(
        "    if matched_alias is None:\n        return None",
        b_start if b_start != -1 else 0,
    )
    if b_start == -1 or b_end == -1 or b_end < b_start:
        sys.stderr.write("could not locate #1709 Stage-B peer-home block\n")
        return 4
    src = src[:b_start] + src[b_end:]

    if "_forbidden_suffix_in_command(\n            text, _peer_forbidden_suffixes" in src \
            or "shared_suffix_hit = _forbidden_suffix_in_command" in src:
        sys.stderr.write("a #1709 suffix-deny call site survived the strip\n")
        return 5
    open(out, "w", encoding="utf-8").write(src)
    return 0


if __name__ == "__main__":
    sys.exit(main())
