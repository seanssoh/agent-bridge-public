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
# Scope: #1822 cross-agent FALSE-POSITIVE corrections ONLY — the four original
# fixes PLUS the quoted-heredoc BODY exclusion (Fix 6, codex re-review of PR
# #1838). The body exclusion reuses #1574's provably-inert shape
# (`_command_is_simple_inert_quoted_heredoc_write`: single cat/tee stage, NO
# shell metachars in the head, QUOTED delimiter, terminator-last) via
# `_inert_heredoc_cross_agent_scan_text`, which strips the proven-DATA body
# from the cross-agent scan surface while keeping the WHOLE command line
# (redirect target included) scanned. Everything that is not that one shape —
# unquoted/expanding delimiter, interpreter consumer, pipe route, unbalanced
# marker, in-body delimiter line — falls back to the raw scan (fail closed),
# and this driver carries DENY teeth for each of those routes.
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
#   Fix 6 — quoted-heredoc BODY exclusion (codex re-review of PR #1838):
#       a QUOTED-delimiter inert cat/tee heredoc body is pure data — a peer
#       home path inside it no longer denies (admin doc-note ALLOW + write
#       audit; non-admin own-file write ALLOW) — while every smuggle route
#       stays DENY: unquoted delimiter, unbalanced marker, interpreter-fed
#       stdin, pipe route, multi-EOF payload, and a protected redirect TARGET
#       (peer home for non-admin, shared/secrets for everyone).
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

    # --- Fix 6: QUOTED-heredoc BODY exclusion (codex re-review of PR #1838).
    #     A quoted-delimiter inert cat/tee heredoc body is pure DATA bash never
    #     expands and cat/tee never open as a path, so a protected-tree word
    #     inside the body must NOT deny — while the redirect TARGET and every
    #     smuggle route stay scanned (fail closed). `intruder` is a non-admin
    #     peer; `worker` (alias `legacy_peer`) is a different peer home; the
    #     driver runs as `worker`, so `intruder_home` is the caller's OWN tree.
    NL = chr(10)
    intruder_home = bridge_home / "agents" / nonadmin

    # 6a — the LIVE repro: admin doc-note `cat >> <peer>/CLAUDE.md <<'EOF' …
    #      <a path> … EOF`. Body mentions a peer path; redirect target is a peer
    #      home (admin write parity, #1711) -> ALLOW + intent=write audit row.
    before = audit_log.stat().st_size if audit_log.exists() else 0
    a6 = (
        f"cat >> {legacy_peer}/CLAUDE.md <<'EOF'{NL}"
        f"see {legacy_peer}/MEMORY.md for context{NL}EOF"
    )
    r = tp.protected_alias_reason(a6, admin, tool_input={"command": a6})
    check(
        "Fix6a admin quoted-heredoc peer doc-note (body has path) ALLOW",
        not is_deny(r),
        f"unexpected deny (the #1838 live false-positive): {r!r}",
    )
    rows = _new_audit_rows(audit_log, before)
    check(
        "Fix6a admin quoted-heredoc write emits "
        "admin_cross_agent_access_allowed intent=write",
        any(
            row.get("action") == "admin_cross_agent_access_allowed"
            and (row.get("detail") or {}).get("intent") == "write"
            for row in rows
        ),
        f"no matching write audit row in {len(rows)} new rows",
    )

    # 6b — non-admin write to OWN file, quoted-heredoc body mentions a PEER home
    #      path. Pre-fix the body word false-denied; the exclusion makes it
    #      ALLOW (the body is data, the OWN-file redirect target is not a peer).
    b6 = (
        f"cat >> {intruder_home}/MEMORY.md <<'EOF'{NL}"
        f"reminder: {legacy_peer}/CLAUDE.md exists{NL}EOF"
    )
    r = tp.protected_alias_reason(b6, nonadmin, tool_input={"command": b6})
    check(
        "Fix6b non-admin quoted-heredoc OWN-file write (peer path in body) "
        "ALLOW",
        not is_deny(r),
        f"unexpected deny: {r!r}",
    )

    # 6c TEETH — UNQUOTED delimiter: bash EXPANDS the body, so it is NOT data;
    #      no strip, the peer path in the body is scanned and DENIES.
    c6 = (
        f"cat >> {intruder_home}/MEMORY.md <<EOF{NL}"
        f"see {legacy_peer}/CLAUDE.md{NL}EOF"
    )
    r = tp.protected_alias_reason(c6, nonadmin, tool_input={"command": c6})
    check(
        "Fix6c TEETH non-admin UNQUOTED heredoc (peer path in body) DENY",
        is_deny(r),
        f"expected deny (expanding body must be scanned), got: {r!r}",
    )

    # 6d TEETH — UNBALANCED marker (no closing delimiter line): fails the
    #      shape's terminator check, no strip, fail closed -> DENY.
    d6 = (
        f"cat >> {intruder_home}/MEMORY.md <<'EOF'{NL}"
        f"see {legacy_peer}/CLAUDE.md{NL}NOTEOF"
    )
    r = tp.protected_alias_reason(d6, nonadmin, tool_input={"command": d6})
    check(
        "Fix6d TEETH non-admin UNBALANCED heredoc marker DENY (fail closed)",
        is_deny(r),
        f"expected deny (unbalanced marker), got: {r!r}",
    )

    # 6e TEETH — multi-EOF payload: bash ends the heredoc at the FIRST `EOF`
    #      line and EXECUTES the tail. The shape's end-anchored check + the
    #      strip's first-terminator semantics disagree, the surviving newline
    #      invariant falls back to the raw scan, and the executed tail (a peer
    #      read) stays visible -> DENY.
    e6 = (
        f"cat >> {intruder_home}/MEMORY.md <<'EOF'{NL}"
        f"body{NL}EOF{NL}cat {legacy_peer}/CLAUDE.md{NL}EOF"
    )
    r = tp.protected_alias_reason(e6, nonadmin, tool_input={"command": e6})
    check(
        "Fix6e TEETH non-admin multi-EOF payload (peer read in tail) DENY",
        is_deny(r),
        f"expected deny (executed tail must stay visible), got: {r!r}",
    )

    # 6f TEETH — quoted-heredoc whose redirect TARGET is a PEER home (non-admin).
    #      The body is excluded but the target stays on the scan surface, so a
    #      cross-agent WRITE destination still DENIES.
    f6 = f"cat >> {legacy_peer}/CLAUDE.md <<'EOF'{NL}hi{NL}EOF"
    r = tp.protected_alias_reason(f6, nonadmin, tool_input={"command": f6})
    check(
        "Fix6f TEETH non-admin quoted-heredoc TARGET=peer home DENY",
        is_deny(r),
        f"expected deny (redirect target stays scanned), got: {r!r}",
    )

    # 6g TEETH — quoted-heredoc whose redirect TARGET is shared/secrets (admin).
    #      Stage-A is off-limits for EVERY agent including admin (#1692
    #      invariant); the body exclusion must not loosen it -> DENY.
    g6 = f"cat >> {secrets} <<'EOF'{NL}hi{NL}EOF"
    r = tp.protected_alias_reason(g6, admin, tool_input={"command": g6})
    check(
        "Fix6g TEETH admin quoted-heredoc TARGET=shared/secrets DENY "
        "(#1692 Stage-A kept)",
        is_deny(r),
        f"expected deny (Stage-A invariant), got: {r!r}",
    )

    if FAILURES:
        print(f"\n[smoke:1822] {len(FAILURES)} assertion(s) FAILED")
        return 1
    print("\n[smoke:1822] PASS — all retained tool-policy cross-agent fixes verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
