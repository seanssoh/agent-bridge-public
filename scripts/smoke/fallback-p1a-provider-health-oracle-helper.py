#!/usr/bin/env python3
"""Mutator for the provider-health oracle smoke (#2066 P1a).

Builds a MUTATED copy of bridge-provider-health.py with the DNS/internet sanity
guard neutered, so the smoke can prove that guard is load-bearing (non-vacuous):
with the guard gone, a DNS-fail FALSELY stamps DOWN; the real guard prevents it.

Invoked file-as-argv (NO heredoc-stdin — footgun #11):
    fallback-p1a-provider-health-oracle-helper.py mutate-dns-guard <src> <dst>

Exit 0 on success; non-zero if the guard anchor is not found (its shape drifted
— the smoke then fails loudly rather than silently testing a vacuous mutant).
"""

import sys

ANCHOR = "    if not dns_ok:\n"
REPLACEMENT = "    if not dns_ok and False:  # MUTATED: DNS guard neutered\n"


def mutate_dns_guard(src_path: str, dst_path: str) -> int:
    with open(src_path, encoding="utf-8") as fh:
        src = fh.read()
    if ANCHOR not in src:
        sys.stderr.write("mutate-dns-guard: anchor not found — guard shape changed\n")
        return 3
    mutated = src.replace(ANCHOR, REPLACEMENT, 1)
    with open(dst_path, "w", encoding="utf-8") as fh:
        fh.write(mutated)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 1:
        sys.stderr.write("usage: helper.py mutate-dns-guard <src> <dst>\n")
        return 2
    cmd = argv[0]
    if cmd == "mutate-dns-guard":
        if len(argv) != 3:
            sys.stderr.write("usage: helper.py mutate-dns-guard <src> <dst>\n")
            return 2
        return mutate_dns_guard(argv[1], argv[2])
    sys.stderr.write(f"unknown command: {cmd}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
