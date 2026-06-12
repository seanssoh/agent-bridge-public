#!/usr/bin/env python3
# scripts/smoke/1692-admin-bash-symmetry-strip.py — revert-teeth helper for
# the #1692 admin Bash read carve-out AND the #1711 admin Bash peer-home WRITE
# parity carve-out.
#
# Produces a copy of hooks/tool-policy.py with BOTH admin peer-home carve-outs
# removed, so the smoke can prove that the admin peer-home ALLOW verdicts
# (read via #1692, write via #1711) are caused by those carve-outs and nothing
# else: against the stripped copy an admin peer-home read AND write both flip
# to DENY. Standalone file-as-argv (NO interpreter heredoc-stdin — footgun
# #11).
#
# Two contiguous blocks are removed:
#
#   1. #1692 READ carve-out — from
#        "    # Issue #1692 — admin read-intent carve-out for the Bash PEER-HOME"
#      up to (not including)
#        "    # Stage B: peer-agent-home substring deny"
#      Runtime-guard sanity signature: "admin_peer_read_audited".
#
#   2. #1711 WRITE-parity carve-out — from
#        "    # Issue #1711 follow-up — admin Bash peer-home WRITE parity."
#      up to (not including)
#        "    if not (read_intent and current_agent_class() == \"system\"):"
#      Runtime-guard sanity signature: "_emit_admin_cross_agent_access_allowed("
#      (the CALL site inside the block; the function DEFINITION elsewhere is
#      left intact — stripping the call is what disables the carve-out).
#
# The Stage-A block also MENTIONS #1692/#1711 (it documents the deliberate
# omission of an admin Stage-A carve-out), so each block is anchored on its own
# header + the following structural marker rather than on the bare issue
# number. If either block cannot be located, exit non-zero so the smoke fails
# loudly rather than silently producing a no-op revert.

import sys


def _strip_block(src: str, start: str, end: str, what: str) -> str:
    i = src.find(start)
    j = src.find(end, i + 1 if i != -1 else 0)
    if i == -1 or j == -1 or j < i:
        sys.stderr.write(
            f"could not locate {what} carve-out block to strip "
            f"(start found={i != -1}, end found={j != -1})\n"
        )
        sys.exit(3)
    return src[:i] + src[j:]


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(
            "usage: 1692-admin-bash-symmetry-strip.py <real_hook> <out>\n"
        )
        return 2
    real, out = sys.argv[1], sys.argv[2]
    with open(real, encoding="utf-8") as fh:
        src = fh.read()

    # Block 1 — #1692 admin READ carve-out.
    src = _strip_block(
        src,
        "    # Issue #1692 — admin read-intent carve-out for the Bash PEER-HOME",
        "    # Stage B: peer-agent-home substring deny",
        "#1692 admin read",
    )
    if "admin_peer_read_audited" in src:
        sys.stderr.write("#1692 read carve-out runtime guard still present after strip\n")
        return 4

    # Block 2 — #1711 admin WRITE-parity carve-out (the in-gate block, not the
    # _emit_* function DEFINITION near the top of the module, which stays).
    src = _strip_block(
        src,
        "    # Issue #1711 follow-up — admin Bash peer-home WRITE parity.",
        '    if not (read_intent and current_agent_class() == "system"):',
        "#1711 admin write-parity",
    )
    # Sanity-check on a CALL-site-unique fragment (the read/write intent
    # selector argument) so the surviving function DEFINITION does not look
    # like an un-stripped call.
    if 'intent="read" if read_intent else "write"' in src:
        sys.stderr.write(
            "#1711 write-parity carve-out call site still present after strip\n"
        )
        return 5

    with open(out, "w", encoding="utf-8") as fh:
        fh.write(src)
    print("[strip] removed #1692 read + #1711 write admin peer-home carve-outs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
