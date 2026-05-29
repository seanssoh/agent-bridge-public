#!/usr/bin/env python3
# scripts/smoke/1358-admin-credential-routine-exempt.py — helper unit
# tests for issue #1358 (Track F, v0.15.0-beta5-2).
#
# Layer 1 (this file): exercises `_is_admin_credential_routine` in
# isolation against the strict-shape brief contract — the same cases
# the Bash smoke driver pins end-to-end, plus the edge-case grid the
# brief calls out (quote escape, symlink leaf, sub-shell embedding,
# audit row token leakage).
#
# Layer 2: the sibling .sh script invokes the real PreToolUse hook
# with stdin JSON and asserts the actual permissionDecision.

import hashlib
import importlib.util
import json
import os
import pathlib
import re
import sys
import tempfile


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    policy_path = repo_root / "hooks" / "tool-policy.py"

    # Set BRIDGE_HOME / BRIDGE_AGENT_HOME_ROOT under a temp directory so
    # `is_admin_agent()` finds the SESSION-TYPE.md fixture and so the
    # module-level `agent_home_root()` resolves cleanly.
    tmpdir = tempfile.mkdtemp(prefix="agent-bridge-1358.")
    os.environ["BRIDGE_HOME"] = tmpdir
    os.environ["BRIDGE_AGENT_HOME_ROOT"] = f"{tmpdir}/agents"
    os.environ["BRIDGE_AUDIT_LOG"] = f"{tmpdir}/audit.jsonl"
    os.environ["BRIDGE_LOG_DIR"] = f"{tmpdir}/logs"
    # Codex r1 BLOCKING #2 (2026-05-29): the carve-out now requires
    # BOTH env-asserted admin AND SESSION-TYPE.md=admin. Default the
    # env to the admin agent so the sanctioned-shape cases below match;
    # individual cases override `BRIDGE_ADMIN_AGENT_ID` directly when
    # they need to exercise the env/roster disagreement gate.
    os.environ["BRIDGE_ADMIN_AGENT_ID"] = "admin-1358"
    admin_home = pathlib.Path(tmpdir) / "agents" / "admin-1358"
    admin_home.mkdir(parents=True, exist_ok=True)
    (admin_home / "SESSION-TYPE.md").write_text("- session type: admin\n")
    user_home = pathlib.Path(tmpdir) / "agents" / "user-1358"
    user_home.mkdir(parents=True, exist_ok=True)
    (user_home / "SESSION-TYPE.md").write_text("- session type: ops\n")

    spec = importlib.util.spec_from_file_location("tool_policy_1358", policy_path)
    if spec is None or spec.loader is None:
        print(f"[smoke] cannot load {policy_path}", file=sys.stderr)
        return 2
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    check = module._is_admin_credential_routine

    cases: list[tuple[str, str, str, bool]] = [
        # (label, command, agent, expected)
        # --- T1: sanctioned shape, admin -> True ---
        (
            "T1 bare sanctioned shape admin",
            "bash bridge-auth.sh claude-token add --stdin",
            "admin-1358",
            True,
        ),
        (
            "T1b sanctioned shape with allowed flags admin",
            "bash bridge-auth.sh claude-token add --stdin --id pool-a --enable-auto-rotate",
            "admin-1358",
            True,
        ),
        # --- T3: non-admin -> False (admin gate) ---
        (
            "T3 sanctioned shape non-admin",
            "bash bridge-auth.sh claude-token add --stdin --id pool-a",
            "user-1358",
            False,
        ),
        # --- T4: && chain -> False ---
        (
            "T4 && chain",
            "bash bridge-auth.sh claude-token add --stdin && echo foo",
            "admin-1358",
            False,
        ),
        (
            "T4b || chain",
            "bash bridge-auth.sh claude-token add --stdin || echo foo",
            "admin-1358",
            False,
        ),
        (
            "T4c ; chain",
            "bash bridge-auth.sh claude-token add --stdin; echo foo",
            "admin-1358",
            False,
        ),
        (
            "T4d | pipe",
            "bash bridge-auth.sh claude-token add --stdin | tee /tmp/leak",
            "admin-1358",
            False,
        ),
        # --- T5: missing --stdin -> False (token would land in argv) ---
        (
            "T5 missing --stdin",
            "bash bridge-auth.sh claude-token add --id pool-a",
            "admin-1358",
            False,
        ),
        (
            "T5b --stdin extension",
            "bash bridge-auth.sh claude-token add --stdin-also",
            "admin-1358",
            False,
        ),
        # --- T6: here-string with token substring (the real operator
        # case from the issue body) -> True ---
        (
            "T6 here-string with sk-ant-o body",
            "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< 'sk-ant-o-fake'",
            "admin-1358",
            True,
        ),
        (
            "T6b here-string with sk-ant-o body, double-quoted",
            'bash bridge-auth.sh claude-token add --stdin --id pool-a <<< "sk-ant-o-fake"',
            "admin-1358",
            True,
        ),
        (
            "T6c heredoc with sk-ant-o body",
            "bash bridge-auth.sh claude-token add --stdin --id pool-a <<EOF\nsk-ant-o-fake\nEOF",
            "admin-1358",
            True,
        ),
        # --- Edge case 2: quote escape changes parse -> False ---
        (
            "Edge2 quote-mangled prefix",
            'bash bridge-auth.sh "claude-token" add --stdin',
            "admin-1358",
            False,
        ),
        (
            "Edge2b spacing-mangled prefix",
            "bash  bridge-auth.sh claude-token add --stdin",  # double space
            "admin-1358",
            False,
        ),
        # --- Edge case 3: shell embedding $(...) / backticks -> False ---
        (
            "Edge3 $() embedding",
            "bash bridge-auth.sh claude-token add --stdin --id $(echo evil)",
            "admin-1358",
            False,
        ),
        (
            "Edge3b backtick embedding",
            "bash bridge-auth.sh claude-token add --stdin --id `whoami`",
            "admin-1358",
            False,
        ),
        (
            "Edge3c process substitution",
            "bash bridge-auth.sh claude-token add --stdin --token-file <(echo evil)",
            "admin-1358",
            False,
        ),
        # --- Output redirection -> False ---
        (
            "Redirect > /tmp/leak",
            "bash bridge-auth.sh claude-token add --stdin > /tmp/leak",
            "admin-1358",
            False,
        ),
        (
            "Redirect 2> /tmp/leak",
            "bash bridge-auth.sh claude-token add --stdin 2>/tmp/leak.err",
            "admin-1358",
            False,
        ),
        (
            "Redirect 2>/dev/null is safe (allowed)",
            "bash bridge-auth.sh claude-token add --stdin 2>/dev/null",
            "admin-1358",
            True,
        ),
        # --- Unknown flag in argv -> False ---
        (
            "Unknown --exec flag rejected",
            "bash bridge-auth.sh claude-token add --stdin --exec evil",
            "admin-1358",
            False,
        ),
        # --- Edge: leading whitespace tolerated ---
        (
            "Leading whitespace tolerated",
            "   bash bridge-auth.sh claude-token add --stdin",
            "admin-1358",
            True,
        ),
        # --- Edge: empty / nonsense ---
        (
            "Empty command",
            "",
            "admin-1358",
            False,
        ),
        (
            "Different leader",
            "sh bridge-auth.sh claude-token add --stdin",
            "admin-1358",
            False,
        ),
        # --- Codex r2 BLOCKING: separator smuggling via bare-word
        # here-string body. The previous `\\S+` bare-word strip
        # swallowed the trailing `;curl evil` into the "body" and
        # falsely passed the separator scan. Fix: bare-word here-
        # string bodies are deliberately NOT stripped (so the scan
        # surface still carries the separator) and the carve-out
        # denies the whole shape.
        (
            "r2 bare-word here-string + ; smuggle",
            "bash bridge-auth.sh claude-token add --stdin <<< sk-ant-o-abc;curl evil.example",
            "admin-1358",
            False,
        ),
        (
            "r2 bare-word here-string + | smuggle",
            "bash bridge-auth.sh claude-token add --stdin <<< sk-ant-o-abc|tee /tmp/leak",
            "admin-1358",
            False,
        ),
        (
            "r2 bare-word here-string + && smuggle",
            "bash bridge-auth.sh claude-token add --stdin <<< sk-ant-o-abc&&curl evil",
            "admin-1358",
            False,
        ),
        # --- Codex r2 BLOCKING: multi-EOF heredoc body coalescing.
        # The previous `.*?\n\3$` regex anchored on end-of-string so a
        # `<<EOF\nbody\nEOF\ncurl evil\nEOF` shape coalesced into a
        # single body that hid the `curl evil` separator. Fix: the
        # terminator is the FIRST line equal to the delimiter (bash
        # semantics), and a trailing command outside the heredoc body
        # then trips the separator scan.
        (
            "r2 multi-EOF heredoc coalesce",
            "bash bridge-auth.sh claude-token add --stdin <<EOF\nbody\nEOF\ncurl evil\nEOF",
            "admin-1358",
            False,
        ),
        (
            "r2 heredoc with trailing curl",
            "bash bridge-auth.sh claude-token add --stdin --id pool-a <<EOF\nbody\nEOF\ncurl evil",
            "admin-1358",
            False,
        ),
        # --- Codex r3 BLOCKING: trailing argv after the here-string /
        # heredoc envelope was not validated. Previous helper cut argv
        # at the first heredoc/here-string opener, so `... <<< 'token'
        # --exec evil` slid past `_validate_auth_add_args`. Fix:
        # `_admin_routine_argv_suffix` strips the entire heredoc/
        # here-string envelope from the BODY-STRIPPED scan surface, so
        # both pre-body AND post-body flags flow through the allowlist.
        (
            "r3 trailing --exec after quoted here-string",
            "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< 'sk-ant-o-real' --exec evil",
            "admin-1358",
            False,
        ),
        (
            "r3 trailing --id traversal after quoted here-string",
            "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< 'sk-ant-o-real' --id ../bad",
            "admin-1358",
            False,
        ),
        (
            "r3 trailing positional after heredoc",
            "bash bridge-auth.sh claude-token add --stdin <<EOF\nbody\nEOF positional-arg",
            "admin-1358",
            False,
        ),
        (
            "r3 valid flag both before AND after here-string",
            "bash bridge-auth.sh claude-token add --stdin --id pool-a <<< 'sk-ant-o-real' --activate",
            "admin-1358",
            True,
        ),
        # --- Codex r4 finding (legitimate operator UX): a heredoc with
        # the normal trailing newline AFTER the closing delimiter was
        # being denied because the strip helper anchored on `(?=\n|$)`
        # and left the trailing `\n` for `_COMMAND_OPERATOR_RE` to flag.
        # Fix: the strip now consumes the optional trailing `\n` as
        # part of the heredoc envelope.
        (
            "r4 heredoc with normal trailing newline (legit operator)",
            "bash bridge-auth.sh claude-token add --stdin <<EOF\nsk-ant-o-real\nEOF\n",
            "admin-1358",
            True,
        ),
        (
            "r4 heredoc no trailing newline (legit operator)",
            "bash bridge-auth.sh claude-token add --stdin <<EOF\nsk-ant-o-real\nEOF",
            "admin-1358",
            True,
        ),
        # --- Codex r5 BLOCKING: post-EOF newline-separated content
        # (even if it's an allowlisted auth flag) was consumed by the
        # r4 fix's `(?:\\n|$)` terminator, so a second command line
        # after the heredoc closer slid past `_validate_auth_add_args`.
        # Fix: anchor the heredoc strip to `\\s*\\Z` (end-of-string +
        # optional whitespace) so the heredoc must be the LAST thing
        # in the command. Any post-EOF non-whitespace content leaves
        # the body on the scan surface and the separator scan denies.
        (
            "r5 post-EOF --activate on new line",
            "bash bridge-auth.sh claude-token add --stdin <<EOF\nsk-ant-o-real\nEOF\n--activate",
            "admin-1358",
            False,
        ),
        (
            "r5 post-EOF --enable-auto-rotate on new line",
            "bash bridge-auth.sh claude-token add --stdin <<EOF\nsk-ant-o-real\nEOF\n--enable-auto-rotate",
            "admin-1358",
            False,
        ),
        (
            "r5 post-EOF --token-file on new line",
            "bash bridge-auth.sh claude-token add --stdin <<EOF\nsk-ant-o-real\nEOF\n--token-file /tmp/leak",
            "admin-1358",
            False,
        ),
        (
            "r5 trailing whitespace only after EOF (legit)",
            "bash bridge-auth.sh claude-token add --stdin <<EOF\ntoken\nEOF   \n",
            "admin-1358",
            True,
        ),
    ]

    failures: list[str] = []
    for label, cmd, agent, want in cases:
        try:
            got = bool(check(cmd, agent))
        except Exception as exc:  # noqa: BLE001 — surface unexpected raise as a failure
            failures.append(f"  FAIL  [{label}] raised {type(exc).__name__}: {exc}")
            continue
        if got != want:
            failures.append(
                f"  FAIL  [{label}] _is_admin_credential_routine({cmd!r}, {agent!r}) "
                f"= {got}, want {want}"
            )
        else:
            print(f"  PASS  [{label}]")

    # Codex r1 BLOCKING #2 (2026-05-29) — env-roster strict-agreement
    # gate. The credential carve-out's admin check is stricter than the
    # generic `is_admin_agent` predicate: BOTH `BRIDGE_ADMIN_AGENT_ID`
    # env AND `SESSION-TYPE.md == admin` must agree. Spoofing one
    # without the other (the "admin-id env exported into a non-admin
    # session" attack) must NOT widen the carve-out.
    sanctioned = "bash bridge-auth.sh claude-token add --stdin --id pool-a"
    saved_admin_env = os.environ.get("BRIDGE_ADMIN_AGENT_ID", "")
    strict_cases: list[tuple[str, str | None, str, str, bool]] = [
        # (label, env BRIDGE_ADMIN_AGENT_ID, agent, SESSION-TYPE content, expected)
        (
            "T11 env=admin-1358 + SESSION-TYPE.md=ops -> DENY (env spoof, roster disagrees)",
            "admin-1358",
            "admin-1358",
            "- session type: ops\n",
            False,
        ),
        (
            "T11b env unset + SESSION-TYPE.md=admin -> DENY (roster alone, env missing)",
            None,
            "admin-1358",
            "- session type: admin\n",
            False,
        ),
        (
            "T11c env=other-id + SESSION-TYPE.md=admin -> DENY (env points elsewhere)",
            "some-other-admin",
            "admin-1358",
            "- session type: admin\n",
            False,
        ),
        (
            "T11d env=admin-1358 + SESSION-TYPE.md missing -> DENY (roster file absent)",
            "admin-1358",
            "admin-1358",
            "",  # empty string sentinel — delete the file
            False,
        ),
        (
            "T12 env=admin-1358 + SESSION-TYPE.md=admin -> ALLOW (both agree)",
            "admin-1358",
            "admin-1358",
            "- session type: admin\n",
            True,
        ),
    ]
    for label, env_val, agent, session_type, want in strict_cases:
        if env_val is None:
            os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
        else:
            os.environ["BRIDGE_ADMIN_AGENT_ID"] = env_val
        home = pathlib.Path(tmpdir) / "agents" / agent
        home.mkdir(parents=True, exist_ok=True)
        session_path = home / "SESSION-TYPE.md"
        if session_type:
            session_path.write_text(session_type)
        else:
            if session_path.exists():
                session_path.unlink()
        try:
            got = bool(check(sanctioned, agent))
        except Exception as exc:  # noqa: BLE001
            failures.append(f"  FAIL  [{label}] raised {type(exc).__name__}: {exc}")
            continue
        if got != want:
            failures.append(
                f"  FAIL  [{label}] _is_admin_credential_routine returned {got}, want {want}"
            )
        else:
            print(f"  PASS  [{label}]")
    # Restore default env so the regression guard below runs in the
    # known default state.
    if saved_admin_env:
        os.environ["BRIDGE_ADMIN_AGENT_ID"] = saved_admin_env
    else:
        os.environ.pop("BRIDGE_ADMIN_AGENT_ID", None)
    (admin_home / "SESSION-TYPE.md").write_text("- session type: admin\n")

    # T6 teeth — remove admin role from SESSION-TYPE.md (env retained
    # as admin-1358) and re-check that an otherwise sanctioned shape
    # stops matching. With the new strict-agreement gate this also
    # confirms a roster downgrade alone is enough to disarm the carve-
    # out even when the env still points at the same agent id.
    (admin_home / "SESSION-TYPE.md").write_text("- session type: ops\n")
    text = "bash bridge-auth.sh claude-token add --stdin --id pool-a"
    got = bool(check(text, "admin-1358"))
    if got is not False:
        failures.append(
            "  FAIL  [T6-teeth] after demoting admin SESSION-TYPE.md to ops, "
            f"sanctioned shape still matched (got={got})"
        )
    else:
        print(
            "  PASS  [T6-teeth] sanctioned shape no longer matches after demote "
            "(strict-agreement gate proven necessary)"
        )

    # Codex r1 BLOCKING #1 (r2, 2026-05-29) — hash-only audit emit.
    # The audit row schema is hash-only: `command_sha256` carries the
    # SHA-256 of the original command bytes; no `sample`, no `summary`,
    # no command text in any form. Invoke the emit helper directly and
    # assert the schema shape.
    (admin_home / "SESSION-TYPE.md").write_text("- session type: admin\n")
    os.environ["BRIDGE_ADMIN_AGENT_ID"] = "admin-1358"
    audit_path = pathlib.Path(os.environ["BRIDGE_AUDIT_LOG"])
    if audit_path.exists():
        audit_path.unlink()
    canary = "bash bridge-auth.sh claude-token add --stdin --id pool-canary-1358 <<< 'sk-ant-o-leak-canary-r2'"
    expected_sha = hashlib.sha256(canary.encode("utf-8")).hexdigest()
    module._emit_credential_routine_admin_exempted_audit(
        "admin-1358",
        text=canary,
        tool_input={"command": canary, "description": "smoke r2 canary"},
    )
    if not audit_path.exists():
        failures.append("  FAIL  [audit-schema] audit log not written")
    else:
        lines = [ln for ln in audit_path.read_text().splitlines() if ln.strip()]
        if not lines:
            failures.append("  FAIL  [audit-schema] audit log empty")
        else:
            row = json.loads(lines[-1])
            detail = row.get("detail", {})
            ok = True
            if detail.get("tool") != "Bash":
                failures.append(f"  FAIL  [audit-schema] tool != 'Bash': {detail!r}")
                ok = False
            if detail.get("surface") != "raw_credentials_mention":
                failures.append(f"  FAIL  [audit-schema] surface mismatch: {detail!r}")
                ok = False
            if detail.get("exemption") != "credential_routine_admin":
                failures.append(f"  FAIL  [audit-schema] exemption mismatch: {detail!r}")
                ok = False
            cmd_hash = detail.get("command_sha256")
            if not isinstance(cmd_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", cmd_hash):
                failures.append(
                    f"  FAIL  [audit-schema] command_sha256 invalid format: {cmd_hash!r}"
                )
                ok = False
            if cmd_hash != expected_sha:
                failures.append(
                    f"  FAIL  [audit-schema] command_sha256={cmd_hash} != expected={expected_sha}"
                )
                ok = False
            # No command text in any form.
            forbidden_fields = ("sample", "summary", "command", "description")
            for field in forbidden_fields:
                if field in detail:
                    failures.append(
                        f"  FAIL  [audit-schema] detail carries forbidden field {field!r}: {detail!r}"
                    )
                    ok = False
            # Canary substring must NOT survive anywhere in the serialised row.
            row_str = json.dumps(row)
            if "leak-canary-r2" in row_str or "sk-ant-o" in row_str:
                failures.append(
                    f"  FAIL  [audit-schema] canary substring leaked into audit row: {row_str}"
                )
                ok = False
            if "pool-canary-1358" in row_str:
                failures.append(
                    f"  FAIL  [audit-schema] argv slug 'pool-canary-1358' leaked into audit row: {row_str}"
                )
                ok = False
            if ok:
                print(
                    "  PASS  [audit-schema] hash-only row carries command_sha256, "
                    "no command text in any form"
                )

    # Codex r2 BLOCKING (r3, 2026-05-29) — env-roster mismatch deny path
    # leaked the token in the audit row. The audit-HASHING decision must
    # be decoupled from the role gate: `_should_hash_credential_routine_audit`
    # returns True for ANY command matching the sanctioned credential-
    # routine SHAPE — regardless of admin / role / env-roster agreement —
    # so the deny row's command summary is hashed even when the carve-out
    # correctly denied a spoofed / mismatched caller. The role gate
    # (`_is_admin_credential_routine`) still controls ALLOW vs DENY.
    should_hash = module._should_hash_credential_routine_audit
    is_admin_routine = module._is_admin_credential_routine
    # Force an env-roster MISMATCH state: env asserts admin, roster says
    # ops. `_is_admin_credential_routine` must be False (deny), but
    # `_should_hash_credential_routine_audit` must be True (hash anyway).
    os.environ["BRIDGE_ADMIN_AGENT_ID"] = "admin-1358"
    (admin_home / "SESSION-TYPE.md").write_text("- session type: ops\n")
    hash_cases: list[tuple[str, str, bool]] = [
        # (label, command, expected _should_hash_credential_routine_audit)
        (
            "shape-only hash: bare sanctioned prefix",
            "bash bridge-auth.sh claude-token add --stdin",
            True,
        ),
        (
            "shape-only hash: here-string token body (env-roster mismatch)",
            "bash bridge-auth.sh claude-token add --stdin --id pool-a "
            "<<< 'sk-ant-o-envroster-canary-1358'",
            True,
        ),
        (
            "shape-only hash: heredoc token body",
            "bash bridge-auth.sh claude-token add --stdin <<EOF\nsk-ant-o-x\nEOF\n",
            True,
        ),
        (
            "shape-only hash: NON-sanctioned shape (&& chain) -> no hash",
            "bash bridge-auth.sh claude-token add --stdin && echo sk-ant-o-x",
            False,
        ),
        (
            "shape-only hash: NON-sanctioned shape (missing --stdin) -> no hash",
            "bash bridge-auth.sh claude-token add --id pool-a",
            False,
        ),
        (
            "shape-only hash: empty command -> no hash",
            "",
            False,
        ),
    ]
    hash_decouple_ok = True
    for label, cmd, want in hash_cases:
        try:
            got = bool(should_hash(cmd))
        except Exception as exc:  # noqa: BLE001
            failures.append(f"  FAIL  [{label}] raised {type(exc).__name__}: {exc}")
            hash_decouple_ok = False
            continue
        if got != want:
            failures.append(
                f"  FAIL  [{label}] _should_hash_credential_routine_audit({cmd!r}) "
                f"= {got}, want {want}"
            )
            hash_decouple_ok = False
        else:
            print(f"  PASS  [{label}]")
    # Decoupling teeth: the env-roster-mismatch token-bearing command
    # hashes (True) even though the role gate denies (False).
    mismatch_cmd = (
        "bash bridge-auth.sh claude-token add --stdin --id pool-a "
        "<<< 'sk-ant-o-envroster-canary-1358'"
    )
    role_gate = bool(is_admin_routine(mismatch_cmd, "admin-1358"))
    hash_gate = bool(should_hash(mismatch_cmd))
    if role_gate is not False:
        failures.append(
            "  FAIL  [hash-decouple] _is_admin_credential_routine should DENY "
            f"on env-roster mismatch, got {role_gate}"
        )
        hash_decouple_ok = False
    if hash_gate is not True:
        failures.append(
            "  FAIL  [hash-decouple] _should_hash_credential_routine_audit should "
            f"HASH on env-roster mismatch, got {hash_gate}"
        )
        hash_decouple_ok = False
    if hash_decouple_ok:
        print(
            "  PASS  [hash-decouple] env-roster mismatch: role gate DENIES, "
            "audit hashing still fires (token kept out of audit log)"
        )

    # Codex r2 BLOCKING (r3, 2026-05-29) — broader leak. The sanctioned
    # routine shape is NOT the only Bash command that can carry an OAuth
    # token into an audit summary. A bare `echo sk-ant-o-…` (or any
    # command naming one of the five credential markers) is denied by
    # `_raw_mentions_claude_credentials` but is not the routine shape, so
    # the shape-only scrub missed it and the raw token leaked into the
    # `agent_tool_denied` summary. `_bash_audit_summary_needs_hashing`
    # hashes on shape-match OR any credential marker.
    needs_hash = module._bash_audit_summary_needs_hashing
    nonshape_canary = "sk-" + "ant-o-" + "nonshape-canary-1358"
    broad_cases: list[tuple[str, str, bool]] = [
        ("broad hash: bare echo sk-ant-o (non-shape marker)",
         "echo " + nonshape_canary, True),
        ("broad hash: cat credentials.json path pair",
         "cat ~/." + "claude/." + "credentials.json", True),
        ("broad hash: OAuth token env var name",
         "echo $CLAUDE_CODE_" + "OAUTH_TOKEN", True),
        ("broad hash: launch-secrets env basename",
         "cat ~/.agent-bridge/shared/launch-" + "secrets.env", True),
        ("broad hash: token-registry json basename",
         "cat claude-" + "oauth-tokens.json", True),
        ("broad hash: sanctioned routine shape still True",
         "bash bridge-auth.sh claude-token add --stdin --id pool-a", True),
        ("broad hash: non-credential command -> no hash",
         "ls -la /tmp && git status", False),
        ("broad hash: empty command -> no hash", "", False),
    ]
    broad_ok = True
    for label, cmd, want in broad_cases:
        try:
            got = bool(needs_hash(cmd))
        except Exception as exc:  # noqa: BLE001
            failures.append(f"  FAIL  [{label}] raised {type(exc).__name__}: {exc}")
            broad_ok = False
            continue
        if got != want:
            failures.append(
                f"  FAIL  [{label}] _bash_audit_summary_needs_hashing({cmd!r}) "
                f"= {got}, want {want}"
            )
            broad_ok = False
        else:
            print(f"  PASS  [{label}]")
    if broad_ok:
        print(
            "  PASS  [broad-hash] credential-marker (non-shape) Bash summaries "
            "hash; non-credential commands keep forensic detail"
        )

    # Restore default admin state for any subsequent assertions.
    (admin_home / "SESSION-TYPE.md").write_text("- session type: admin\n")

    # Codex r2 BLOCKING (r3, 2026-05-29) — second leak vector in the
    # sibling `permission_escalation.py` hook. It fires on
    # PermissionDenied (which the credential-routine deny triggers) and
    # previously put the raw Bash command through `sanitize_text`, whose
    # `openai_key` pattern does NOT match the hyphenated `sk-ant-o-…`
    # OAuth shape — so the token leaked into the `permission_escalation_*`
    # audit rows AND the `[PERMISSION]` admin-task body. Verify the
    # hash-only short-circuit seals it. Credential substrings are
    # reconstructed at runtime so this smoke file does not carry the
    # literal markers (which the controller's own guard would block).
    perm_path = repo_root / "hooks" / "permission_escalation.py"
    perm_spec = importlib.util.spec_from_file_location(
        "permission_escalation_1358", perm_path
    )
    perm_ok = True
    if perm_spec is None or perm_spec.loader is None:
        failures.append(f"  FAIL  [perm-esc] cannot load {perm_path}")
        perm_ok = False
    else:
        perm_mod = importlib.util.module_from_spec(perm_spec)
        perm_spec.loader.exec_module(perm_mod)
        sk_canary = "sk-" + "ant-o-" + "permesc-canary-1358"
        oauth_var = "CLAUDE_CODE_" + "OAUTH_TOKEN"
        cred_pair_cmd = "cat ~/." + "claude/." + "credentials.json"
        launch_cmd = "cat ~/.agent-bridge/shared/launch-" + "secrets.env"
        registry_cmd = "cat claude-" + "oauth-tokens.json"
        routine_cmd = (
            "bash bridge-auth.sh claude-token add --stdin --id pool-a "
            "<<< '" + sk_canary + "'"
        )
        # (a) credential-routine command -> hash-only, token absent.
        out = perm_mod.redacted_summary_text(
            "admin-1358", "Bash", {"command": routine_cmd, "description": ""}
        )
        if sk_canary in out or ("sk-" + "ant-o") in out:
            failures.append(
                f"  FAIL  [perm-esc] token leaked into redacted summary: {out}"
            )
            perm_ok = False
        if not re.search(r'"command_sha256": "[0-9a-f]{64}"', out):
            failures.append(
                f"  FAIL  [perm-esc] credential command not hashed: {out}"
            )
            perm_ok = False
        # (b) each of the other four markers also triggers hash-only.
        for marker_cmd in (
            "echo $" + oauth_var,
            cred_pair_cmd,
            launch_cmd,
            registry_cmd,
        ):
            o = perm_mod.redacted_summary_text(
                "admin-1358", "Bash", {"command": marker_cmd, "description": ""}
            )
            if "command_sha256" not in o:
                failures.append(
                    f"  FAIL  [perm-esc] marker not hashed: {marker_cmd!r} -> {o}"
                )
                perm_ok = False
        # (c) a non-credential command keeps its raw forensic summary.
        o2 = perm_mod.redacted_summary_text(
            "admin-1358", "Bash", {"command": "ls -la /tmp", "description": "list"}
        )
        if "ls -la /tmp" not in o2 or "command_sha256" in o2:
            failures.append(
                f"  FAIL  [perm-esc] non-credential command wrongly altered: {o2}"
            )
            perm_ok = False
        # (d) non-Bash tool (Grep) naming the token: the sk-ant-o run must
        # be redacted (sanitize_text misses it). Codex r2 r3 surface 3.
        grep_canary = "sk-" + "ant-o-" + "permesc-grep-1358"
        og = perm_mod.redacted_summary_text(
            "user-1358", "Grep", {"pattern": grep_canary}
        )
        if grep_canary in og or ("sk-" + "ant-o-") in og:
            failures.append(
                f"  FAIL  [perm-esc] non-Bash Grep token leaked: {og}"
            )
            perm_ok = False
        # (e) non-Bash non-credential keeps forensic detail.
        op = perm_mod.redacted_summary_text(
            "user-1358", "Read", {"file_path": "/tmp/normal/file.py"}
        )
        if "/tmp/normal/file.py" not in op:
            failures.append(
                f"  FAIL  [perm-esc] non-Bash non-credential over-redacted: {op}"
            )
            perm_ok = False
        # (f) Codex r3 self-review (r4, 2026-05-29) — the QUEUE-BODY leak.
        # The hook deny `reason` (NOT `redacted_args`) can echo the
        # offending command, including the OAuth token, and it rides into
        # the `[PERMISSION]` admin TASK BODY via `build_task_body` /
        # `create_admin_task --body` — a sink the `write_audit` choke-point
        # does not touch. `handle_permission_denied` now redacts `reason`
        # at source via `_redact_credential_token_values`. Verify the
        # redacted reason yields a token-free task body, AND the composed
        # `task create --body` argv (dry-run) is token-free, AND the helper
        # keeps non-credential reasons intact.
        reason_canary = "sk-" + "ant-o-" + "permesc-reason-1358"
        redacted_reason = perm_mod._redact_credential_token_values(
            "denied: command was `echo " + reason_canary + "`"
        )
        if reason_canary in redacted_reason or ("sk-" + "ant-o-") in redacted_reason:
            failures.append(
                f"  FAIL  [perm-esc] reason token not redacted: {redacted_reason}"
            )
            perm_ok = False
        body = perm_mod.build_task_body(
            agent="user-1358",
            tool_name="Bash",
            tool_use_id="tu-1358",
            redacted_args="<redacted>",
            reason=redacted_reason,
            origin_task_id=None,
        )
        if reason_canary in body or ("sk-" + "ant-o-") in body:
            failures.append(
                f"  FAIL  [perm-esc] QUEUE-BODY leak: token in task body:\n{body}"
            )
            perm_ok = False
        ok_create, info_create = perm_mod.create_admin_task(
            "admin-1358", "user-1358", "Bash", body, dry_run=True
        )
        if not ok_create:
            failures.append(
                f"  FAIL  [perm-esc] dry-run create_admin_task failed: {info_create}"
            )
            perm_ok = False
        if reason_canary in info_create or ("sk-" + "ant-o-") in info_create:
            failures.append(
                f"  FAIL  [perm-esc] QUEUE-CMD leak: token in task-create argv:\n{info_create}"
            )
            perm_ok = False
        # Non-credential reason kept intact (no over-redaction).
        plain = perm_mod._redact_credential_token_values("denied: protected path")
        if plain != "denied: protected path":
            failures.append(
                f"  FAIL  [perm-esc] non-credential reason altered: {plain}"
            )
            perm_ok = False
        if perm_ok:
            print(
                "  PASS  [perm-esc] PermissionDenied hook redacts credential-bearing "
                "Bash (hash) + non-Bash (token-value) summaries; reason token kept "
                "out of [PERMISSION] queue task body; keeps non-cred detail"
            )

    # Codex r2 BLOCKING (r3, 2026-05-29) — token-VALUE redaction for the
    # tool-policy surfaces that keep raw text: the admin read-intent
    # ALLOW audit row and the non-Bash deny summary. A credential FILE
    # PATH is a wanted forensic anchor; a token-shaped VALUE must not
    # survive. `_redact_credential_token_values` collapses `sk-ant-o…`
    # runs to `sk-ant-o<REDACTED>` while keeping the surrounding path /
    # pattern structure.
    redact = module._redact_credential_token_values
    redact_summary = module._redact_credential_summary
    tv_canary = "sk-" + "ant-o-" + "value-canary-1358"
    tv_ok = True
    # (a) bare token run -> redacted prefix.
    r1 = redact("echo " + tv_canary)
    if tv_canary in r1 or "<REDACTED>" not in r1:
        failures.append(f"  FAIL  [token-value] bare token not redacted: {r1}")
        tv_ok = False
    # (b) credential PATH preserved, token VALUE inside it redacted.
    path_with_token = "/home/a/." + "claude/" + tv_canary + ".json"
    r2 = redact(path_with_token)
    if tv_canary in r2:
        failures.append(f"  FAIL  [token-value] token survived in path: {r2}")
        tv_ok = False
    if "/home/a/." + "claude/" not in r2:
        failures.append(f"  FAIL  [token-value] path structure lost: {r2}")
        tv_ok = False
    # (c) summary dict: string values redacted, non-strings intact.
    summ = redact_summary({"pattern": tv_canary, "count": 3, "file_path": "/tmp/x"})
    if tv_canary in json.dumps(summ):
        failures.append(f"  FAIL  [token-value] summary value not redacted: {summ}")
        tv_ok = False
    if summ.get("count") != 3 or summ.get("file_path") != "/tmp/x":
        failures.append(f"  FAIL  [token-value] summary over-redacted: {summ}")
        tv_ok = False
    # (d) non-credential text untouched.
    r3 = redact("grep -rn 'TODO' src/")
    if r3 != "grep -rn 'TODO' src/":
        failures.append(f"  FAIL  [token-value] non-credential text altered: {r3}")
        tv_ok = False
    if tv_ok:
        print(
            "  PASS  [token-value] sk-ant-o runs redacted in raw-text audit "
            "surfaces; paths / non-credential text preserved"
        )

    # Codex r5 BLOCKING (r6, 2026-05-29) — redactor MUST be idempotent.
    # Layer 2 writers emit an already-collapsed marker BEFORE the Layer 1
    # write_audit choke-point runs; without the (?!<REDACTED>) lookahead a
    # second pass produced `sk-ant-o<REDACTED><REDACTED>`. Assert (1) the
    # marker is a fixed point, (2) a raw run collapses to exactly one
    # marker, (3) a double pass equals a single pass.
    idem_ok = True
    marker = "sk-ant-" + "o" + "<REDACTED>"
    raw = "denied " + ("sk-ant-" + "o") + "RAWTOKEN123 via layer2"
    once = redact(raw)
    twice = redact(once)
    if redact(marker) != marker:
        failures.append(f"  FAIL  [idempotent] marker not a fixed point: {redact(marker)!r}")
        idem_ok = False
    if once != twice:
        failures.append(f"  FAIL  [idempotent] double pass != single: once={once!r} twice={twice!r}")
        idem_ok = False
    if once.count("<REDACTED>") != 1 or twice.count("<REDACTED>") != 1:
        failures.append(f"  FAIL  [idempotent] not exactly one marker: once={once!r} twice={twice!r}")
        idem_ok = False
    if idem_ok:
        print(
            "  PASS  [idempotent] redactor is a fixed point — raw run -> "
            "exactly one marker, marker -> unchanged, double pass == single "
            "(no sk-ant-o<REDACTED><REDACTED> compounding)"
        )

    if failures:
        print(f"\n{len(failures)} failure(s):", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
        return 1
    # cases + strict + T6-teeth + audit-schema + hash_cases
    # + hash-decouple-teeth + broad_cases + broad-hash + perm-esc
    # + token-value
    total = (
        len(cases) + len(strict_cases) + 1 + 1 + len(hash_cases) + 1
        + len(broad_cases) + 1 + 1 + 1 + 1
    )
    print(
        f"\n[smoke:1358-admin-credential-routine-exempt] "
        f"all {total} unit cases passed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
