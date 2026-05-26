#!/usr/bin/env python3
"""auth-legacy-claude-config-env.py — rewrite the legacy launch-secrets.env
to pin `CLAUDE_CONFIG_DIR=<config_dir>` and strip any prior
`CLAUDE_CODE_OAUTH_TOKEN=` / `CLAUDE_CONFIG_DIR=` lines.

Invocation contract (file-as-argv, NEVER stdin):
    sys.argv[1] = path to launch-secrets.env (may not exist yet)
    sys.argv[2] = CLAUDE_CONFIG_DIR value (must not contain a single quote)

Side effect: atomic rewrite of sys.argv[1] using a sibling tempfile +
`os.replace`. The tempfile is unlinked in the `finally` block on any
mid-write error so the original file is never left half-written.

Footgun #11 / codex r1 BLOCKING on PR #1239 (issue #1238): this body
used to live as a `python3 - <<'PY' … PY` heredoc-stdin inside
`bridge_auth_update_legacy_claude_config_env`. The shell helper
`bridge_auth_run_privileged` (and its `_bridge_isolation_v2_run_root_or_
sudo` core) retries the command on failure — first invocation direct,
second invocation via `sudo -n`. With heredoc-stdin the FIRST Python
child consumes the entire script from the heredoc fd before raising
`PermissionError`; the sudo fallback then reads EOF and silently
exits 0 with no script side effect. Net result: the wrapper would
report success without actually executing the privileged update.

Moving the body to a real file with file-as-argv removes the stdin
dependency entirely — every retry by the wrapper re-reads the script
from disk, so the privileged fallback runs the same code as the
direct attempt. Mirrors the existing `lib/upgrade-helpers/` pattern
used by `channel-guard-json.py`, `recorded-source-root.py`, etc.
"""

import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
config_dir = sys.argv[2]
key = "CLAUDE_CODE_OAUTH_TOKEN="
config_key = "CLAUDE_CONFIG_DIR="
lines = path.read_text(encoding="utf-8", errors="ignore").splitlines() if path.exists() else []
filtered = [
    line
    for line in lines
    if not line.strip().startswith(key)
    and not line.strip().startswith(config_key)
]
if "'" in config_dir:
    raise SystemExit("CLAUDE_CONFIG_DIR path cannot contain single quote")
filtered.append(f"CLAUDE_CONFIG_DIR='{config_dir}'")
text = "\n".join(filtered)
if text:
    text += "\n"
fd = -1
tmp_name = ""
try:
    fd, tmp_name = tempfile.mkstemp(prefix=".launch-secrets.", suffix=".tmp", dir=str(path.parent))
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fd = -1
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp_name, path)
finally:
    if fd >= 0:
        os.close(fd)
    if tmp_name:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
