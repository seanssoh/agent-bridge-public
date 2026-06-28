#!/usr/bin/env python3
"""Mock ``security(1)`` for the #2171 keychain-shadow self-heal smoke.

Stands in for the macOS ``security`` binary via the ``BRIDGE_SECURITY_BIN`` seam
so the smoke NEVER touches the real login keychain. State lives under
``$MOCK_KC_DIR``:

  - ``services``      newline-separated service names ``dump-keychain`` emits.
  - ``tok-<service>`` the secret blob ``find-generic-password -s <svc> -w``
                      returns for that service (absent => not-found, rc 44).
  - ``deleted.log``   appended (one service per line) on each
                      ``delete-generic-password -s <svc>``.

Subcommands implemented (the only three the reconcile path shells out to):
  dump-keychain
  find-generic-password -s <service> -w
  delete-generic-password -s <service>
"""

import os
import sys


def _svc_arg(rest: list[str]) -> str:
    i = 0
    while i < len(rest):
        if rest[i] == "-s" and i + 1 < len(rest):
            return rest[i + 1]
        i += 1
    return ""


def main(argv: list[str]) -> int:
    kc = os.environ.get("MOCK_KC_DIR", "")
    if not kc:
        sys.stderr.write("mock security: MOCK_KC_DIR unset\n")
        return 2
    sub = argv[0] if argv else ""
    rest = argv[1:]

    if sub == "dump-keychain":
        services = os.path.join(kc, "services")
        if os.path.exists(services):
            with open(services, encoding="utf-8") as fh:
                for line in fh:
                    name = line.strip()
                    if name:
                        sys.stdout.write('    "svce"<blob>="%s"\n' % name)
        return 0

    if sub == "find-generic-password":
        service = _svc_arg(rest)
        path = os.path.join(kc, "tok-" + service)
        if not os.path.exists(path):
            return 44
        with open(path, encoding="utf-8") as fh:
            sys.stdout.write(fh.read())
        return 0

    if sub == "delete-generic-password":
        service = _svc_arg(rest)
        with open(os.path.join(kc, "deleted.log"), "a", encoding="utf-8") as fh:
            fh.write(service + "\n")
        path = os.path.join(kc, "tok-" + service)
        if os.path.exists(path):
            os.remove(path)
        return 0

    sys.stderr.write("mock security: unsupported subcommand %r\n" % sub)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
