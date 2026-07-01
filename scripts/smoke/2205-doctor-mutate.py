#!/usr/bin/env python3
"""scripts/smoke/2205-doctor-mutate.py — #2205 doctor-source mutation helper.

File-as-argv helper for scripts/smoke/2205-disabled-drift-selfheal.sh. Each of the
doctor mutation cases (D3 / MD4 / MD5 / MD6) needs to produce a MUTATED copy of
bridge-doctor.py that neuters exactly ONE guard, so the smoke can prove the guard
is load-bearing (revert it → the corresponding case flips and the smoke fails).

The transforms used to live in `python3 - <<'PY'` heredoc-stdin blocks inside the
smoke. Those are footgun #11 (the Bash 5.3.9 heredoc-stdin-into-an-interpreter
deadlock) and the lint-heredoc-ban C3 ratchet flags any NEW one. This standalone
helper takes the mutation name + src + dst entirely via argv (no stdin), the same
file-as-argv pattern as lib/upgrade-helpers/.

Usage:
    2205-doctor-mutate.py <mutation> <src-doctor.py> <dst-mutated.py>

<mutation> is one of: carveout | wellformed | pid_dead | readable_disabled.
The transform is a single deterministic string-replace so the mutated source is
BYTE-IDENTICAL to what the prior inline heredoc produced; a missing needle is a
hard error (exit 2) so a doctor refactor that moves the guard fails loudly rather
than silently producing a vacuous (non-mutating) test.
"""

from __future__ import annotations

import sys

# mutation-name -> (needle, replacement). Each needle is the exact guard the
# corresponding smoke case proves load-bearing; the replacement neuters just that
# guard. Kept verbatim from the original inline heredoc transforms.
_MUTATIONS: dict[str, tuple[str, str]] = {
    # D3: neuter the marker carve-out (force the matching test to never hold) →
    # a recoverable matching-marker drift must START reporting.
    "carveout": (
        "    if recoverable:\n"
        "        # The watcher can prove + recover this; not an unprovable drift.\n"
        "        return None",
        "    if False and recoverable:\n        return None",
    ),
    # MD4: force marker_well_formed True unconditionally → an off-schema marker
    # must START suppressing.
    "wellformed": (
        "                marker_well_formed = False\n                continue",
        "                marker_well_formed = True  # MUT\n                continue",
    ),
    # MD5: drop the _pid_dead(marker_pid) term → a LIVE-writer marker must START
    # suppressing.
    "pid_dead": (
        "        and _pid_dead(marker_pid)\n",
        "        and True  # MUT _pid_dead dropped\n",
    ),
    # MD6: drop the positive-readable-disabled terms → an unknown-probe drift must
    # START suppressing.
    "readable_disabled": (
        "        disabled_readable\n        and disabled\n        and marker_well_formed",
        "        True  # MUT readable+disabled dropped\n        and marker_well_formed",
    ),
}


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        sys.stderr.write(
            "usage: 2205-doctor-mutate.py <mutation> <src> <dst>\n"
        )
        return 2
    mutation, src, dst = argv[1], argv[2], argv[3]
    if mutation not in _MUTATIONS:
        sys.stderr.write(
            f"unknown mutation {mutation!r}; "
            f"expected one of {sorted(_MUTATIONS)}\n"
        )
        return 2
    needle, replacement = _MUTATIONS[mutation]
    with open(src, encoding="utf-8") as fh:
        text = fh.read()
    if needle not in text:
        sys.stderr.write(
            f"mutation {mutation!r}: needle not found in {src} "
            "(a doctor refactor moved the guard — fix this helper, "
            "do NOT let the smoke pass vacuously)\n"
        )
        return 2
    text = text.replace(needle, replacement, 1)
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
