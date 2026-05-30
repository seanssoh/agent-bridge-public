#!/usr/bin/env python3
"""Mid-write temp-permission probe for bridge-a2a.py:_write_config_atomic.

Spy on os.fsync: at fsync time the secret-bearing JSON is already written to the
temp, so the temp's mode at that instant is the worst-case exposure window. Assert
it carries no group/other bits even when the target pre-exists at a wide mode.

Usage: a2a-migrate-identity-midwrite-helper.py <path-to-bridge-a2a.py>
Exits 0 + prints the observed mode on success; nonzero on leak.
"""
import os
import stat
import sys
import tempfile
import importlib.util


def main() -> int:
    cli = sys.argv[1]
    spec = importlib.util.spec_from_file_location("bridge_a2a_midwrite_probe", cli)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    captured = {}
    real_fsync = os.fsync

    def spy_fsync(fd):
        try:
            captured["mode"] = stat.S_IMODE(os.fstat(fd).st_mode)
        except OSError as exc:
            captured["err"] = repr(exc)
        return real_fsync(fd)

    os.fsync = spy_fsync
    try:
        d = tempfile.mkdtemp()
        target = os.path.join(d, "handoff.local.json")
        # Pre-create the target at a WIDE mode (0644). The fix must create the
        # temp at 0o600 regardless, so this must NOT leak into the temp.
        with open(target, "w") as fh:
            fh.write("{}")
        os.chmod(target, 0o644)
        from pathlib import Path
        secret_cfg = {
            "bridge_id": "probe",
            "listen": {"address": "100.0.0.1", "port": 8787},
            "peers": [{"id": "p", "address": "100.0.0.2",
                       "secret": "deadbeef" * 8}],
        }
        mod._write_config_atomic(Path(target), secret_cfg, 0o600)
    finally:
        os.fsync = real_fsync

    mode = captured.get("mode")
    if mode is None:
        sys.stderr.write("midwrite-probe: did not observe a mid-write mode: %r\n"
                         % captured)
        return 2
    if mode & 0o077:
        sys.stderr.write("midwrite-probe: LEAK — group/other bits set during "
                         "write window: %s\n" % oct(mode))
        return 1
    print("midwrite temp mode = %s (no group/other bits)" % oct(mode))
    return 0


if __name__ == "__main__":
    sys.exit(main())
