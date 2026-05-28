#!/usr/bin/env python3
"""iso-helper-smoke-py-roundtrip.py — Python adapter round-trip for the
iso-helper smoke (scripts/iso-helper-smoke.sh).

Invocation contract (file-as-argv, no heredoc-stdin — footgun #11):
    sys.argv[1] = REPO_ROOT
    sys.argv[2] = SANDBOX (writable temp dir under the iso UID)
    sys.argv[3] = AGENT (synthetic agent slug staged by the smoke)

Exits 0 on success, non-zero on any assertion failure. Stderr carries
the failure message; stdout prints "py-smoke: OK" on the success path
so the caller can grep for it.

Extracted from scripts/iso-helper-smoke.sh:380 in PR #1216 r2 (codex r1
needs-more "migrate or baseline" — chose migration so the
lint-heredoc-ban baseline does not grow). The previous heredoc shape
was:

    python3 - "$REPO_ROOT" "$SANDBOX" "$AGENT" <<'PY_SMOKE'
    ...
    PY_SMOKE

which is the same C3 interpreter-heredoc class the
`lib/upgrade-helpers/` migration was created to eliminate (#896 /
v0.13.9). The body has been moved verbatim into this standalone file;
the only behavioural diff is that argv slot 0 is now the file path
rather than the shell's '-' placeholder, which is exactly the
file-as-argv shape `lib/upgrade-helpers/` already uses.
"""

import sys
from pathlib import Path

if len(sys.argv) != 4:
    print(
        "iso-helper-smoke-py-roundtrip.py: expected 3 args "
        "(REPO_ROOT SANDBOX AGENT), got " + str(len(sys.argv) - 1),
        file=sys.stderr,
    )
    sys.exit(2)

repo_root = sys.argv[1]
sandbox = sys.argv[2]
agent = sys.argv[3]
sys.path.insert(0, str(Path(repo_root) / "lib"))

from bridge_iso_paths import iso_run  # noqa: E402

# Stat the file we wrote earlier.
result = iso_run(agent, "stat", path=f"{sandbox}/present.txt", test="exists")
if result.returncode != 0:
    print(f"py-smoke: stat exists FAIL rc={result.returncode}", file=sys.stderr)
    sys.exit(1)

# Read it back.
result = iso_run(agent, "read-file", path=f"{sandbox}/present.txt")
if result.returncode != 0 or result.stdout.strip() != "hello":
    print(
        f"py-smoke: read-file FAIL rc={result.returncode} out={result.stdout!r}",
        file=sys.stderr,
    )
    sys.exit(1)

# Write via stdin.
result = iso_run(
    agent, "atomic-write",
    path=f"{sandbox}/py-write.out", mode="0644", stdin="py-payload\n",
)
if result.returncode != 0:
    print(
        f"py-smoke: atomic-write FAIL rc={result.returncode} stderr={result.stderr!r}",
        file=sys.stderr,
    )
    sys.exit(1)
written = Path(f"{sandbox}/py-write.out").read_text()
if written != "py-payload\n":
    print(f"py-smoke: payload mismatch {written!r}", file=sys.stderr)
    sys.exit(1)

# Unsafe path → 40.
result = iso_run(agent, "stat", path="/etc/passwd", test="exists")
if result.returncode != 40:
    print(f"py-smoke: unsafe path FAIL rc={result.returncode}", file=sys.stderr)
    sys.exit(1)

print("py-smoke: OK")
