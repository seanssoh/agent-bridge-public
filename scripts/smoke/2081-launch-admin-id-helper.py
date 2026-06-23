#!/usr/bin/env python3
"""Helper for scripts/smoke/2081-launch-admin-id.sh — #2081 receiver-launch
fail-open fix.

The #2079 cross-node admin↔admin authz predicate recomputes a LOCAL endpoint's
admin status from `$BRIDGE_ADMIN_AGENT_ID` (rooms.classify_local_admin). The
receiver LAUNCH paths (systemd handoffd unit, `agb a2a daemon start`, direct
`bridge-handoff-daemon.sh start`) did NOT provide that var, so a LOCAL admin
classified as UNKNOWN and a `non-admin@remote -> admin@local` cross-node
delivery flipped from the intended DENY (`sender_not_admin`) to ALLOW
(`not_admin_involved`) — a fail-OPEN of the admin boundary.

This helper proves the launch-path RESOLUTION fix in the exact lifecycle/systemd
shape: the admin id lives ONLY in the on-disk roster (NOT in the process env),
and `rooms.ensure_admin_agent_id_in_env()` (the resolver `bridge-handoffd.py
serve` calls at startup) is what makes the LOCAL admin classify correctly so the
delivery is DENIED.

MUTATION PROOF (printed as two paired teeth):
  * resolved=ON  (env populated from the on-disk roster by the startup resolver)
    -> `non-admin@remote -> admin@local` is DENIED (sender_not_admin).
  * resolved=OFF (the pre-fix world: env stays empty at serve time)
    -> the SAME delivery is ALLOWED (not_admin_involved) — the fail-open the fix
       closes. Asserting this branch is what proves the DENY in the ON case is
       caused by the resolution, not by something else.

It runs IN-PROCESS against the real modules. No network, no live tick. The
caller (the .sh) provides an isolated BRIDGE_HOME and writes the roster file; we
NEVER set BRIDGE_ADMIN_AGENT_ID in the process env ourselves except via the real
resolver under test.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)

import bridge_rooms_common as rooms  # noqa: E402

_FAILURES: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"RESULT {name} PASS")
    else:
        print(f"RESULT {name} FAIL: {detail}")
        _FAILURES.append(name)


def _member(agent: str, node: str, role: str = "member", admin: str = "unknown") -> dict:
    m: dict = {"agent": agent, "node": node, "role": role}
    if admin == "admin":
        m["bridge_admin"] = True
    elif admin == "non_admin":
        m["bridge_admin"] = False
    # admin == "unknown" -> key absent (the tri-state unknown encoding)
    return m


def _seed_cache(db: str, room_id: str, epoch: int, leader_node: str,
                members: list[dict]) -> None:
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db
    conn = rooms.open_rooms()
    try:
        members_json = json.dumps(rooms._canonical_member_list(members),
                                  separators=(",", ":"))
        conn.execute(
            "INSERT OR REPLACE INTO room_roster_cache (room_id, epoch, "
            "members_json, from_node, mac, fetched_ts) VALUES (?,?,?,?,?,?)",
            (room_id, epoch, members_json, leader_node, "", rooms.now_ts()),
        )
        conn.commit()
    finally:
        conn.close()


def _receiver_authz(db: str, *, room_id: str, epoch: int, this_node: str,
                    sender_agent: str, sender_node: str,
                    target_agent: str, target_node: str) -> tuple[bool, str]:
    """Run the receiver-side admin authz over a seeded cache, reading whatever
    `BRIDGE_ADMIN_AGENT_ID` is CURRENTLY in os.environ (we deliberately do NOT
    set it here — the test controls it only via the real resolver)."""
    os.environ["BRIDGE_A2A_ROOMS_DB"] = db
    conn = rooms.open_rooms_readonly()
    try:
        mem = rooms.roster_cache_membership_check(
            conn, room_id=room_id, room_epoch=epoch,
            sender_agent=sender_agent, sender_node=sender_node,
            target_agent=target_agent, target_node=target_node)
        if mem != rooms.ROOM_TALK_OK:
            return False, "membership:" + mem
        return rooms.room_admin_authz_check(
            conn, room_id=room_id, room_epoch=epoch,
            sender_agent=sender_agent, sender_node=sender_node,
            target_agent=target_agent, target_node=target_node,
            this_node=this_node)
    finally:
        conn.close()


def decode_case_line(raw: str) -> str:
    r"""Decode the TSV roster-line escapes shared by the Python + shell drivers.

    Supports \t \v \f \r \n and \\ (literal backslash). Kept deliberately small
    and identical to the shell decoder in scripts/smoke/2081-launch-admin-id.sh
    so both drivers write byte-identical roster lines from the shared table.
    """
    out = []
    i = 0
    while i < len(raw):
        c = raw[i]
        if c == "\\" and i + 1 < len(raw):
            nxt = raw[i + 1]
            out.append({"t": "\t", "v": "\v", "f": "\f", "r": "\r",
                        "n": "\n", "\\": "\\"}.get(nxt, "\\" + nxt))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def run_parity_table(table_path: str, roster_path: str) -> int:
    """Drive the PYTHON parser over the shared parity table (r5-round5 F2).

    For each row, write the decoded roster line to `roster_path`, run
    `_parse_admin_id_from_roster`, and assert the outcome equals the bash-verified
    EXPECTED column (FOUND:<v> / MALFORMED / NONE). The shell wrapper runs the
    SAME table against the shell parser, so the two stay provably in lock-step.
    """
    os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
    os.environ["BRIDGE_ROSTER_LOCAL_FILE"] = roster_path
    os.environ.pop("BRIDGE_ROSTER_FILE", None)
    with open(table_path, encoding="utf-8") as fh:
        rows = fh.read().splitlines()
    seen_header = False
    for row in rows:
        if not row.strip() or row.lstrip().startswith("#"):
            continue
        parts = row.split("\t")
        if not seen_header:
            # the first non-comment row is the `id roster_line expected` header
            seen_header = True
            continue
        if len(parts) != 3:
            check(f"parity_row_malformed_table_line", False,
                  f"expected 3 TAB fields, got {len(parts)}: {row!r}")
            continue
        case_id, line_esc, expected = parts
        with open(roster_path, "w", encoding="utf-8") as rf:
            rf.write("#!/usr/bin/env bash\n")
            rf.write(decode_case_line(line_esc) + "\n")
        try:
            found, val = rooms._parse_admin_id_from_roster(Path(roster_path))
            got = ("FOUND:" + val) if found else "NONE"
        except ValueError:
            got = "MALFORMED"
        except FileNotFoundError:
            got = "NONE"
        check(f"parity_py_{case_id}", got == expected,
              f"py parser got {got!r}, expected {expected!r} (bash ground truth)")
    if _FAILURES:
        print("OVERALL FAIL: " + ", ".join(_FAILURES))
        return 1
    print("OVERALL PASS")
    return 0


def main() -> int:
    tmp = os.environ.get("BRIDGE_STATE_DIR", "")
    db = os.path.join(tmp, "handoff", "2081-launch.db")
    os.makedirs(os.path.dirname(db), exist_ok=True)

    NA, NB = "nodeA", "nodeB"
    ROOM, EPOCH = "launch-room", 4
    # padmin is THIS node's (nodeA) configured admin; worker on nodeB is a remote
    # non-admin. The cache carries worker's known-non-admin bit; padmin's local
    # bit is RECOMPUTED from this node's configured admin id, so the cache value
    # for padmin is irrelevant (we leave it unknown to prove the local recompute
    # is what decides).
    members = [_member("padmin", NA, "leader", "unknown"),
               _member("worker", NB, "member", "non_admin")]
    _seed_cache(db, ROOM, EPOCH, NA, members)

    ADMIN_ID = os.environ.get("SMOKE_EXPECT_ADMIN_ID", "padmin")

    # PRECONDITION — the launch shape: the admin id is present ONLY on disk, NOT
    # in the process env. If our harness leaked it, the mutation proof is void.
    env_admin_at_start = os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip()
    check("precondition_admin_id_absent_from_env",
          env_admin_at_start == "",
          f"BRIDGE_ADMIN_AGENT_ID unexpectedly present at start: {env_admin_at_start!r}")
    # And the resolver CAN see it on disk (sanity: the roster file is wired).
    on_disk = rooms.resolve_admin_agent_id()
    check("precondition_admin_id_resolvable_from_disk",
          on_disk == ADMIN_ID,
          f"resolve_admin_agent_id()={on_disk!r}, expected {ADMIN_ID!r} from the roster file")

    # ---- MUTATION PROOF, branch OFF (pre-fix world) -----------------------
    # Without the startup resolution, the env stays empty at serve time, the
    # local admin classifies UNKNOWN, and the predicate FAILS OPEN (ALLOWED).
    os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
    off_ok, off_reason = _receiver_authz(
        db, room_id=ROOM, epoch=EPOCH, this_node=NA,
        sender_agent="worker", sender_node=NB,
        target_agent="padmin", target_node=NA)
    check("mutation_off_unresolved_env_is_failopen",
          off_ok and off_reason == rooms.ADMIN_AUTHZ_NOT_ADMIN_INVOLVED,
          f"expected ALLOW/not_admin_involved with env unset, got ok={off_ok} reason={off_reason}")

    # ---- THE FIX, branch ON ----------------------------------------------
    # Call the REAL launch-path resolver the serve entrypoint uses. It reads the
    # admin id from the on-disk roster and stamps it into os.environ.
    resolved = rooms.ensure_admin_agent_id_in_env()
    check("resolver_populated_env_from_disk",
          resolved == ADMIN_ID
          and os.environ.get("BRIDGE_ADMIN_AGENT_ID", "").strip() == ADMIN_ID,
          f"resolver returned {resolved!r}, env now "
          f"{os.environ.get('BRIDGE_ADMIN_AGENT_ID', '')!r}")

    on_ok, on_reason = _receiver_authz(
        db, room_id=ROOM, epoch=EPOCH, this_node=NA,
        sender_agent="worker", sender_node=NB,
        target_agent="padmin", target_node=NA)
    check("launch_resolution_denies_nonadmin_to_admin",
          (not on_ok) and on_reason == rooms.ADMIN_AUTHZ_SENDER_NOT_ADMIN,
          f"expected DENY/sender_not_admin after launch resolution, got ok={on_ok} reason={on_reason}")

    # ---- env-FIRST precedence: a pre-set env value is NOT clobbered -------
    # (a managed-agent launch via bridge-run.sh already exports the value;
    # resolution must not override it with a stale on-disk read.)
    os.environ["BRIDGE_ADMIN_AGENT_ID"] = "preset_admin"
    kept = rooms.ensure_admin_agent_id_in_env()
    check("resolver_env_first_does_not_clobber",
          kept == "preset_admin"
          and os.environ.get("BRIDGE_ADMIN_AGENT_ID") == "preset_admin",
          f"env-first precedence violated: returned {kept!r}, "
          f"env={os.environ.get('BRIDGE_ADMIN_AGENT_ID')!r}")

    # ---- F2: stale-export-before-current — LAST assignment wins -----------
    # A roster can carry a stale `export BRIDGE_ADMIN_AGENT_ID="old_admin"`
    # above setup's later canonical `BRIDGE_ADMIN_AGENT_ID="padmin"`. Bash
    # `source` keeps the LAST value; a first-match resolver would read the stale
    # `old_admin` and misclassify padmin as non-admin, ALLOWING a non-admin
    # remote delivery. The resolver must match bash and return the LAST value.
    roster = os.environ.get("SMOKE_ROSTER_FILE", "")
    if roster:
        os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
        with open(roster, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\n")
            fh.write('export BRIDGE_ADMIN_AGENT_ID="old_admin"\n')
            fh.write(f'BRIDGE_ADMIN_AGENT_ID="{ADMIN_ID}"\n')
        stale = rooms.resolve_admin_agent_id()
        check("f2_last_assignment_wins_over_stale_export",
              stale == ADMIN_ID,
              f"expected the LAST assignment {ADMIN_ID!r} (bash source semantics), "
              f"got {stale!r} — a stale earlier export would misclassify the admin")
    else:
        check("f2_last_assignment_wins_over_stale_export", False,
              "SMOKE_ROSTER_FILE not provided by the wrapper")

    # ---- F1: an existing-but-UNREADABLE roster fail-CLOSES, not silent '' --
    # If the roster exists but cannot be read/decoded, returning '' would leave
    # the admin id UNKNOWN and re-open the fail-open. The resolver must RAISE
    # AdminIdResolveError so the serve entrypoint refuses to serve.
    if roster:
        os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
        # Write bytes that are not valid UTF-8 so read_text() raises
        # UnicodeDecodeError on an EXISTING file (a partial write / corruption).
        with open(roster, "wb") as fh:
            fh.write(b'BRIDGE_ADMIN_AGENT_ID="\xff\xfe not utf8"\n')
        raised = False
        try:
            rooms.resolve_admin_agent_id()
        except rooms.AdminIdResolveError:
            raised = True
        except Exception as exc:  # any other exception is the WRONG signal
            check("f1_unreadable_roster_failcloses", False,
                  f"expected AdminIdResolveError, got {type(exc).__name__}: {exc}")
            raised = None
        if raised is True:
            check("f1_unreadable_roster_failcloses", True)
        elif raised is False:
            check("f1_unreadable_roster_failcloses", False,
                  "an existing-but-unreadable roster resolved to '' (silent "
                  "fail-OPEN) instead of raising AdminIdResolveError")
        # And the serve-entrypoint helper PROPAGATES it (so cmd_serve fail-closes).
        os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
        propagated = False
        try:
            rooms.ensure_admin_agent_id_in_env()
        except rooms.AdminIdResolveError:
            propagated = True
        except Exception:
            propagated = None
        check("f1_ensure_env_propagates_resolve_error",
              propagated is True,
              f"ensure_admin_agent_id_in_env must propagate AdminIdResolveError "
              f"(got propagated={propagated})")
    else:
        check("f1_unreadable_roster_failcloses", False,
              "SMOKE_ROSTER_FILE not provided by the wrapper")
        check("f1_ensure_env_propagates_resolve_error", False,
              "SMOKE_ROSTER_FILE not provided by the wrapper")

    # ---- F1 (corollary): a READABLE no-admin roster still resolves '' ------
    # The fail-close must NOT over-reach: a readable roster with no admin line
    # (a node that never configured an admin) must keep resolving '' so non-
    # admin traffic stays open — NOT raise.
    if roster:
        os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
        with open(roster, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\n# no admin configured here\n")
        try:
            empty = rooms.resolve_admin_agent_id()
            check("f1_readable_no_admin_still_open",
                  empty == "",
                  f"a readable no-admin roster must resolve '' (open), got {empty!r}")
        except Exception as exc:
            check("f1_readable_no_admin_still_open", False,
                  f"a readable no-admin roster must NOT raise, got "
                  f"{type(exc).__name__}: {exc}")

    # ---- F3 (r3 review F1 + round-3 F1): a MALFORMED value RAISES, never -----
    # exports garbage NOR a TRUNCATED-to-valid-looking prefix. A truncated/partial
    # write or a tampered roster can leave an unbalanced quote
    # (`...="padmin`), an invalid-charset value, junk fused to the closing quote
    # (`...="padmin"evil` — bash would concat to `padminevil`, we must not
    # truncate to `padmin`), a non-whitespace `#` in a bare value (`...=padmin#evil`
    # — bash keeps the literal `padmin#evil`, we must not truncate to `padmin`),
    # or extra bare words. Each MUST fail-closed (AdminIdResolveError), never
    # resolve to a wrong-but-valid-looking id that misclassifies the real admin.
    if roster:
        for label, bad_line in (
            ("unbalanced_quote", 'BRIDGE_ADMIN_AGENT_ID="padmin\n'),
            ("invalid_charset", 'BRIDGE_ADMIN_AGENT_ID="bad name!"\n'),
            ("junk_after_close_quote", 'BRIDGE_ADMIN_AGENT_ID="padmin"evil\n'),
            ("bare_hash_not_comment", 'BRIDGE_ADMIN_AGENT_ID=padmin#evil\n'),
            ("extra_bare_words", 'BRIDGE_ADMIN_AGENT_ID=padmin evil\n'),
            # r5 review (codex design consult): bash concatenates a `#` fused to
            # a closing quote (`"padmin"#evil` -> padmin#evil), so it is NOT a
            # comment and must not truncate to `padmin`.
            ("hash_fused_after_quote", 'BRIDGE_ADMIN_AGENT_ID="padmin"#evil\n'),
            # `+=` append into a single-name admin id is a tamper signal.
            ("plus_equals_append", 'BRIDGE_ADMIN_AGENT_ID+=padmin\n'),
            # adjacent quote/bare concatenation (`pa"d"min` -> padmin in bash) —
            # never a real id shape; fail closed rather than mimic bash concat.
            ("mixed_quote_concat", 'BRIDGE_ADMIN_AGENT_ID=pa"d"min\n'),
            # command substitution MUST be rejected as malformed and NEVER
            # executed (the zero-eval property of the pure parser).
            ("command_substitution", 'BRIDGE_ADMIN_AGENT_ID="$(echo PWNED)"\n'),
        ):
            os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
            with open(roster, "w", encoding="utf-8") as fh:
                fh.write("#!/usr/bin/env bash\n")
                fh.write(bad_line)
            raised = False
            try:
                got = rooms.resolve_admin_agent_id()
            except rooms.AdminIdResolveError:
                raised = True
            except Exception as exc:
                check(f"f3_malformed_{label}_failcloses", False,
                      f"expected AdminIdResolveError, got {type(exc).__name__}: {exc}")
                raised = None
            if raised is True:
                check(f"f3_malformed_{label}_failcloses", True)
            elif raised is False:
                check(f"f3_malformed_{label}_failcloses", False,
                      f"a malformed value resolved to {got!r} instead of raising "
                      "AdminIdResolveError (would export garbage / fall open)")

    # ---- F4 (r3 review F2): a PRESENT-BUT-EMPTY local stops the search -------
    # bash sources the SHARED roster first, the LOCAL roster last, so a local
    # `BRIDGE_ADMIN_AGENT_ID=` (empty) is the effective value (no admin). The
    # resolver must NOT fall through to a stale `="admin"` in the shared roster.
    shared = os.environ.get("SMOKE_SHARED_ROSTER_FILE", "")
    if roster and shared:
        os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
        with open(shared, "w", encoding="utf-8") as fh:
            fh.write('BRIDGE_ADMIN_AGENT_ID="stale_shared_admin"\n')
        with open(roster, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\nBRIDGE_ADMIN_AGENT_ID=\n")
        try:
            blank = rooms.resolve_admin_agent_id()
            check("f4_blank_local_stops_fallthrough",
                  blank == "",
                  f"a present-but-empty LOCAL assignment must yield '' (bash "
                  f"sources local last), NOT fall through to the stale shared "
                  f"admin; got {blank!r}")
        except Exception as exc:
            check("f4_blank_local_stops_fallthrough", False,
                  f"unexpected raise on present-but-empty local: "
                  f"{type(exc).__name__}: {exc}")
        # And the legit fallthrough still works: NO local assignment -> shared.
        os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
        with open(roster, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\n# local has no admin assignment\n")
        try:
            ft = rooms.resolve_admin_agent_id()
            check("f4_no_local_assignment_falls_through_to_shared",
                  ft == "stale_shared_admin",
                  f"with NO local assignment the shared admin must be used; got {ft!r}")
        except Exception as exc:
            check("f4_no_local_assignment_falls_through_to_shared", False,
                  f"unexpected raise on legit fallthrough: "
                  f"{type(exc).__name__}: {exc}")
    else:
        check("f4_blank_local_stops_fallthrough", False,
              "SMOKE_ROSTER_FILE / SMOKE_SHARED_ROSTER_FILE not provided")
        check("f4_no_local_assignment_falls_through_to_shared", False,
              "SMOKE_ROSTER_FILE / SMOKE_SHARED_ROSTER_FILE not provided")

    # ---- F5 (r3 round-4 review F1): leading whitespace after `=` is EMPTY ----
    # In bash `KEY= padmin` assigns KEY="" and runs `padmin` as a separate word,
    # so the effective value is EMPTY (no admin). A resolver that strips the RHS
    # would wrongly read `padmin` and could classify a real admin from a tampered
    # leading-space line. The value must resolve EMPTY ('' / no-admin), never the
    # trailing word. Covers a space, a tab, and a space-before-quote.
    if roster:
        for label, bad_line in (
            ("space_after_eq", "BRIDGE_ADMIN_AGENT_ID= padmin\n"),
            ("tab_after_eq", "BRIDGE_ADMIN_AGENT_ID=\tpadmin\n"),
            ("space_before_quote", 'BRIDGE_ADMIN_AGENT_ID= "padmin"\n'),
        ):
            os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
            with open(roster, "w", encoding="utf-8") as fh:
                fh.write("#!/usr/bin/env bash\n")
                fh.write(bad_line)
            try:
                got = rooms.resolve_admin_agent_id()
                check(f"f5_leading_ws_{label}_is_empty",
                      got == "",
                      f"leading whitespace after '=' must yield '' (bash value is "
                      f"empty), NOT the trailing word; got {got!r}")
            except Exception as exc:
                check(f"f5_leading_ws_{label}_is_empty", False,
                      f"unexpected raise on a leading-ws RHS: "
                      f"{type(exc).__name__}: {exc}")
        # SECURITY corollary: a leading-ws LOCAL line must NOT fall through to a
        # stale shared admin either (it is a found-but-empty local assignment).
        if shared:
            os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
            with open(shared, "w", encoding="utf-8") as fh:
                fh.write('BRIDGE_ADMIN_AGENT_ID="stale_shared_admin"\n')
            with open(roster, "w", encoding="utf-8") as fh:
                fh.write("#!/usr/bin/env bash\nBRIDGE_ADMIN_AGENT_ID= padmin\n")
            try:
                got = rooms.resolve_admin_agent_id()
                check("f5_leading_ws_local_stops_fallthrough",
                      got == "",
                      f"a leading-ws (empty) LOCAL assignment must yield '' and "
                      f"NOT fall through to the stale shared admin; got {got!r}")
            except Exception as exc:
                check("f5_leading_ws_local_stops_fallthrough", False,
                      f"unexpected raise: {type(exc).__name__}: {exc}")

    if _FAILURES:
        print("OVERALL FAIL: " + ", ".join(_FAILURES))
        return 1
    print("OVERALL PASS")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "parity-table":
        # parity-table <table.tsv> <roster_path>
        sys.exit(run_parity_table(sys.argv[2], sys.argv[3]))
    sys.exit(main())
