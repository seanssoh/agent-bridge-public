#!/usr/bin/env python3
# scripts/smoke/1822-tool-policy-crossagent-falsepos.py — issue #1822
# tool-policy cross-agent false-positive fixes.
#
# Loaded as a module-file (file-as-argv, NO interpreter heredoc-stdin —
# footgun #11) by the `.sh` wrapper, which sets up an isolated BRIDGE_HOME
# fixture (smoke/lib.sh::smoke_setup_bridge_home) with one peer agent home in
# the legacy (`$BRIDGE_AGENT_HOME_ROOT/<peer>`) tree, plus a shared/wiki page
# and a shared/secrets file.
#
# Scope: #1822 cross-agent FALSE-POSITIVE corrections ONLY, and ONLY the FOUR
# fixes that shipped — the quoted-heredoc BODY STRIP optimisation was dropped
# (operator decision after 5 review rounds: proving a heredoc body is inert
# data vs executable needs full shell-pipeline parsing and a distinct bypass
# surfaced at every layer; not stripping is strictly safer — it only ever
# DENIES more). The narrow remaining false positive (an admin doc-note
# `cat >> peer/CLAUDE.md <<'EOF' … `path` … EOF` whose body contains a
# protected-tree word now DENIES) is accepted; the workaround is to write
# doc-notes with an editor/file tool instead of a Bash heredoc. This driver
# therefore asserts NONE of the removed strip's behaviour (no data-sink ALLOW,
# no interpreter-stdin DENY, no wrapper-option DENY, no pipe-route DENY).
#
# The v2 peer-home CONTAINMENT gap is issue #1823, owned by PR #1831 (its smoke
# coverage lives in scripts/smoke/1823-v2-peer-home-containment.sh); this driver
# deliberately does NOT assert v2 peer-home enumeration / containment.
#
# Each assertion exercises one retained Fix against the real
# `protected_alias_reason` entry point (or, for Fix 1b, its glob-containment
# helper directly):
#
#   Fix 1b — balanced-backtick UNWRAP: a `` `…/shared/wiki/…` `` code-span word
#       resolves to its literal and is NOT forbidden; a `` `…/shared/secrets/…`
#       `` word still IS forbidden. (Unit-level on the glob helper, because the
#       end-to-end backtick is otherwise dominated by the embedding guard.)
#   Fix 2 — component-wise glob containment: `<bridge>/*.sh` is too shallow to
#       reach the depth-2 shared/secrets dir -> ALLOW; `<bridge>/shared/*`
#       reaches the secrets dir -> DENY.
#   Fix 3 — obfuscation fail-close message names the offending word(s)
#       (`un-analyzable path expression near a protected tree (near: …)`)
#       instead of a fixed secrets path.
#   Fix 4 — admin Bash peer-home WRITE parity (#1711 follow-up): admin write
#       ALLOW + admin_cross_agent_access_allowed intent=write audit row; a
#       NON-admin peer-home write stays DENY (no carve-out for non-admin).
#   Fix 5 — macOS `md5` checksum read of a peer home (admin) -> ALLOW.
#
# Plus the one base invariant the admin carve-outs must not loosen:
#   - a Stage-A shared/secrets read by ADMIN stays DENY (#1692 invariant).
#
# Exit 0 on all-pass; non-zero (with a [FAIL] line) on any mismatch.

import importlib.util
import json
import os
import pathlib
import sys


def _load_tool_policy(repo_root: pathlib.Path):
    spec = importlib.util.spec_from_file_location(
        "tp", repo_root / "hooks" / "tool-policy.py"
    )
    tp = importlib.util.module_from_spec(spec)
    sys.modules["tp"] = tp
    spec.loader.exec_module(tp)
    return tp


FAILURES: list[str] = []


def check(label: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"[ok] {label}")
    else:
        FAILURES.append(f"{label}: {detail}")
        print(f"[FAIL] {label}: {detail}")


def is_deny(reason) -> bool:
    return isinstance(reason, str) and reason != ""


def _new_audit_rows(audit_log: pathlib.Path, before: int) -> list[dict]:
    rows: list[dict] = []
    if audit_log.exists():
        with open(audit_log, encoding="utf-8") as fh:
            fh.seek(before)
            for line in fh:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: 1822-tool-policy-crossagent-falsepos.py "
            "<repo_root> <bridge_home> <data_root>",
            file=sys.stderr,
        )
        return 2
    repo_root = pathlib.Path(sys.argv[1])
    bridge_home = pathlib.Path(sys.argv[2])
    # data_root retained for wrapper signature compatibility; #1822 scope does
    # NOT exercise the v2 data root (that is #1831's territory).
    _data_root = pathlib.Path(sys.argv[3])

    # The wrapper exports BRIDGE_ADMIN_AGENT_ID=admin and creates peer `worker`
    # in the legacy root; `admin` is the admin agent, `worker` a non-admin peer.
    admin = "admin"
    peer = "worker"
    nonadmin = "intruder"  # a non-admin agent writing at `worker`

    legacy_peer = bridge_home / "agents" / peer
    wiki = bridge_home / "shared" / "wiki" / "operating-rules.md"
    secrets = bridge_home / "shared" / "secrets" / "token.txt"

    tp = _load_tool_policy(repo_root)
    audit_log = pathlib.Path(os.environ["BRIDGE_AUDIT_LOG"])

    # --- Fix 1b: balanced-backtick UNWRAP. A word wholly wrapped in a balanced
    #     pair of backticks whose interior is a single literal path resolves to
    #     that interior; the helper then re-runs the SAME glob containment test.
    #     A `shared/wiki` inner path is NOT forbidden; a `shared/secrets` inner
    #     path IS. (Exercised on the glob helper directly: an end-to-end backtick
    #     is dominated by the embedding guard, so the unwrap's job — keep a
    #     benign `shared/wiki` code-span from fail-closing the obfuscation path —
    #     is verified where it actually runs.)
    check(
        "Fix1b unwrap balanced backtick wiki path -> inner literal",
        tp._unwrap_balanced_backtick_path(f"`{wiki}`") == str(wiki),
        f"unwrap returned {tp._unwrap_balanced_backtick_path(f'`{wiki}`')!r}",
    )
    check(
        "Fix1b unwrap rejects a backtick command (embedded space) -> None",
        tp._unwrap_balanced_backtick_path("`ls -la`") is None,
        "expected None for a non-path backtick span",
    )
    check(
        "Fix1b unwrap rejects an UNbalanced backtick -> None",
        tp._unwrap_balanced_backtick_path(f"`{wiki}") is None,
        "expected None for an unbalanced backtick",
    )
    check(
        "Fix1b backtick `shared/wiki` glob word NOT forbidden",
        tp._glob_prefix_reaches_forbidden_dir(
            f"`{wiki}`", tp._shared_forbidden_suffixes()
        )
        is False,
        "wiki inner path should not reach a forbidden dir",
    )
    check(
        "Fix1b backtick `shared/secrets` glob word IS forbidden",
        tp._glob_prefix_reaches_forbidden_dir(
            f"`{secrets}`", tp._shared_forbidden_suffixes()
        )
        is True,
        "secrets inner path should reach the forbidden dir",
    )

    # --- Fix 2: top-level `<bridge>/*.sh` glob is too shallow to reach the
    #     depth-2 shared/secrets dir -> ALLOW; `<bridge>/shared/*` reaches the
    #     secrets dir at depth -> DENY.
    r = tp.protected_alias_reason(f"grep -n foo {bridge_home}/*.sh", admin)
    check(
        "Fix2 admin top-level <bridge>/*.sh glob ALLOW",
        not is_deny(r),
        f"unexpected deny: {r!r}",
    )
    r = tp.protected_alias_reason(f"ls {bridge_home}/shared/*", admin)
    check(
        "Fix2 admin <bridge>/shared/* glob DENY (reaches secrets dir)",
        is_deny(r),
        f"expected deny, got: {r!r}",
    )

    # --- Fix 3: the obfuscation fail-close (a glob / command-sub / surviving
    #     `$var` near a protected tree) now NAMES the offending word instead of
    #     pointing at a fixed secrets path. A `shared/secr*` glob is
    #     un-analyzable, so the deny message is the obfuscation form with a
    #     `(near: …)` sample, NOT the literal "shared/private and shared/secrets"
    #     wording.
    r = tp.protected_alias_reason(
        f"cat {bridge_home}/shared/secr*/token.txt", admin
    )
    check(
        "Fix3 obfuscation deny message names the offending word",
        is_deny(r)
        and "un-analyzable path expression" in r
        and "(near:" in r,
        f"expected obfuscation message, got: {r!r}",
    )

    # --- Fix 4 (#1711 follow-up): admin Bash WRITE to a peer home -> ALLOW
    #     + admin_cross_agent_access_allowed intent=write audit row.
    before = audit_log.stat().st_size if audit_log.exists() else 0
    write_cmd = f"printf 'plain\\n' >> {legacy_peer}/CLAUDE.md"
    r = tp.protected_alias_reason(
        write_cmd, admin, tool_input={"command": write_cmd}
    )
    check(
        "Fix4 admin Bash write to peer home ALLOW",
        not is_deny(r),
        f"unexpected deny: {r!r}",
    )
    rows = _new_audit_rows(audit_log, before)
    got_write_audit = any(
        row.get("action") == "admin_cross_agent_access_allowed"
        and (row.get("detail") or {}).get("intent") == "write"
        for row in rows
    )
    check(
        "Fix4 admin peer-home write emits admin_cross_agent_access_allowed "
        "intent=write",
        got_write_audit,
        f"no matching audit row in {len(rows)} new rows",
    )

    # --- Fix 4 KEEP-teeth: NON-admin write to a peer home stays DENY (no write
    #     carve-out exists for non-admin; only admin gets the #1711 parity).
    r = tp.protected_alias_reason(
        f"printf 'x\\n' >> {legacy_peer}/CLAUDE.md", nonadmin
    )
    check(
        "Fix4 KEEP non-admin Bash write to peer home DENY",
        is_deny(r),
        f"expected deny, got: {r!r}",
    )

    # --- #1692 invariant: Stage-A secrets read by ADMIN stays DENY. The admin
    #     carve-outs only ever grant a PEER-HOME access, never a shared-secret
    #     one (Stage A denies above for every agent including admin).
    r = tp.protected_alias_reason(f"cat {secrets}", admin)
    check(
        "StageA admin direct secrets read DENY (#1692 invariant kept)",
        is_deny(r),
        f"expected deny, got: {r!r}",
    )

    # --- Fix 5: macOS `md5` checksum read of a peer home (admin) -> ALLOW.
    r = tp.protected_alias_reason(f"md5 -q {legacy_peer}/MEMORY.md", admin)
    check(
        "Fix5 admin `md5 -q` peer read ALLOW (read-intent)",
        not is_deny(r),
        f"unexpected deny: {r!r}",
    )

    if FAILURES:
        print(f"\n[smoke:1822] {len(FAILURES)} assertion(s) FAILED")
        return 1
    print("\n[smoke:1822] PASS — all retained tool-policy cross-agent fixes verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
