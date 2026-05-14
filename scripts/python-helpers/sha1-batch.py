#!/usr/bin/env python3
"""Batch SHA1 digester for `bridge_sha1_batch`.

Reads one input per line from stdin, prints the hex digest of each input
to stdout in the same order. One newline per output digest. Avoids the
per-call ``python3`` cold-start that ``bridge_sha1`` pays when the caller
already knows the full set of inputs (e.g. roster hydration hashing one
key per agent). Refs issue #848.
"""

import hashlib
import sys


def main() -> None:
    out = sys.stdout
    for line in sys.stdin:
        # The wire format strips exactly one trailing newline per input.
        # `rstrip("\n")` (not bare `rstrip()`) preserves trailing spaces
        # and other whitespace that the per-call `bridge_sha1` would
        # otherwise hash verbatim. Matches the encoding used by
        # `bridge_sha1` (utf-8, no trailing newline).
        out.write(
            hashlib.sha1(line.rstrip("\n").encode("utf-8")).hexdigest()
        )
        out.write("\n")


if __name__ == "__main__":
    main()
