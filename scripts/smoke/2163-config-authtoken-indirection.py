#!/usr/bin/env python3
# scripts/smoke/2163-config-authtoken-indirection.py — issue #2163
# (Security-Cycle-A PR 2/3: tight config / auth-token backstop).
#
# Unit + env layer for the two hardened surfaces in hooks/tool-policy.py. The
# end-to-end allow/deny verdict through the real PreToolUse hook rides the
# sibling config smokes (1738-config-caller-binding / v0166-lc-config-set-env);
# this file pins the unit invariants for the #2163 additions.
#
#   F3 — `_bridge_home_is_test_temp` now inspects BRIDGE_HOME *plus* every
#        explicitly-set runtime-identity anchor (BRIDGE_RUNTIME_CONFIG_FILE /
#        BRIDGE_STATE_DIR / BRIDGE_RUNTIME_ROOT). A confined fixer that spoofs
#        BRIDGE_HOME=/tmp/x so the predicate reads "sandbox" (and the
#        BRIDGE_GUARD_ADMIN_ROSTER_JSON seam trusts a forged admin roster)
#        while another anchor still points at the LIVE runtime no longer
#        qualifies — the split-root spoof (patch's v0.16.5 BRIDGE_STATE_DIR
#        override-leak class). ANY explicitly-set anchor resolving outside a
#        fixed temp root ⇒ not-sandbox (fail-closed). Unset/empty anchors
#        inherit BRIDGE_HOME (over-block-0).
#
#   C4a/C4b/C6 — `_config_mutation_via_indirection` now also denies an
#        AUTH-TOKEN mutation (`auth claude-token add/activate/sync/rotate`,
#        `global-auth-sync enable/disable`) hidden behind eval / a `-c` shell
#        (the FULL `_BASH_GIT_INTERPRETER_LEAVES` set — C6: +zsh/ksh/mksh/dash/
#        ash/fish/xargs) / an unresolved command-position `$var`, SYMMETRIC with
#        the existing #1738 config gate (patch criterion 3). The read-only
#        `global-auth-sync status` verb stays ALLOWED (C4a — patch criterion 2),
#        and the DIRECT literal verb form is intentionally NOT flagged here (the
#        wrapper's caller-trust gate owns that; this hook is indirection-only
#        defense-in-depth, exactly like the #1738 config gate).
#
# Criterion 4 (no plaintext secret leak) is asserted directly: the audit
# emitter's redacted `sample` must never carry the `sk-ant-o…` token bytes.
#
# file-as-argv (SMOKE_TMP_ROOT passed as argv[1]); NO heredoc-stdin to a
# subprocess (footgun #11 / lint-heredoc-ban).

import importlib.util
import os
import pathlib
import sys

# Runtime-identity anchors the F3 predicate must consider (kept local so this
# smoke pins the intended set independently of the module constant). The last
# two are the OAuth token-registry anchors (#2163 patch r1 BREAK2).
_ANCHORS = (
    "BRIDGE_HOME",
    "BRIDGE_RUNTIME_CONFIG_FILE",
    "BRIDGE_STATE_DIR",
    "BRIDGE_RUNTIME_ROOT",
    "BRIDGE_CLAUDE_TOKEN_REGISTRY",
    "BRIDGE_RUNTIME_SECRETS_DIR",
)

# A path that is NOT under any fixed temp root — stands in for the LIVE runtime.
_LIVE_ROOT = "/opt/agent-bridge-live"


def _load_module():
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    policy_path = repo_root / "hooks" / "tool-policy.py"
    spec = importlib.util.spec_from_file_location("tool_policy_2163", policy_path)
    if spec is None or spec.loader is None:
        print(f"[smoke:2163] cannot load {policy_path}", file=sys.stderr)
        raise SystemExit(2)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _indirection_cases() -> list[tuple[str, "str | None"]]:
    """(command, expected `_config_mutation_via_indirection` reason-or-None)."""
    return [
        # ---- C4b/C6 auth-token DENY via a nested interpreter ----
        # sk-ant-o… token in the FIRST case proves the deny fires with a real
        # credential shape (its redaction is asserted separately below).
        ("eval 'agb auth claude-token add sk-ant-oTOKENVALUE'",
         "auth_token_mutation_via_eval"),
        ("bash -c 'agb auth claude-token rotate'", "auth_token_mutation_via_bash"),
        ("sh -c 'agent-bridge auth claude-token activate default'",
         "auth_token_mutation_via_sh"),
        # C6 — the widened interpreter set (previously ALLOWED for config too).
        ("zsh -c 'agb auth claude-token add x'", "auth_token_mutation_via_zsh"),
        ("ksh -c 'agb auth claude-token sync'", "auth_token_mutation_via_ksh"),
        ("mksh -c 'agb auth claude-token rotate'", "auth_token_mutation_via_mksh"),
        ("dash -c 'agb auth claude-token rotate'", "auth_token_mutation_via_dash"),
        ("ash -c 'agb auth claude-token add x'", "auth_token_mutation_via_ash"),
        ("fish -c 'agb auth claude-token add x'", "auth_token_mutation_via_fish"),
        ("xargs agb auth claude-token add", "auth_token_mutation_via_xargs"),
        # CLI hidden behind a var, run through eval (double-indirection).
        ('eval "$C auth claude-token add"', "auth_token_mutation_via_eval"),
        # global-auth-sync enable is a MUTATION even via indirection.
        ("bash -c 'agb auth claude-token global-auth-sync enable'",
         "auth_token_mutation_via_bash"),
        ("bash -c 'agb auth claude-token global-auth-sync disable'",
         "auth_token_mutation_via_bash"),
        # #2163 patch r1 BREAK1 — a co-located `global-auth-sync` /
        # `global-auth-sync-status` substring planted in a --note/--label must
        # NOT mask a real add/activate/sync/rotate (verb-check-first). These
        # were the four ALLOW escapes patch reproduced; they MUST deny now.
        ('eval "agb auth claude-token add sk-ant-oXXXXXX --note global-auth-sync"',
         "auth_token_mutation_via_eval"),
        ('bash -c "agb auth claude-token rotate --note global-auth-sync"',
         "auth_token_mutation_via_bash"),
        ('eval "agb auth claude-token add $TOK --label global-auth-sync-status"',
         "auth_token_mutation_via_eval"),
        ('$C auth claude-token add $TOK --label global-auth-sync-status',
         "auth_token_mutation_via_unresolved_var"),
        ("sh -c 'agb auth claude-token sync --note global-auth-sync'",
         "auth_token_mutation_via_sh"),
        ("eval 'agb auth claude-token activate x --label global-auth-sync'",
         "auth_token_mutation_via_eval"),
        # ---- C4b auth-token DENY via unresolved command-position $var ----
        ("agb auth claude-token $V", "auth_token_mutation_via_unresolved_var"),
        ("$C auth claude-token add x", "auth_token_mutation_via_unresolved_var"),
        ("agb auth claude-token global-auth-sync $ACTION",
         "auth_token_mutation_via_unresolved_var"),
        # literal verb + a $ token value still denies (conservative $-adjacency,
        # matching #1738's "privileged writes use literal argv" stance).
        ("agent-bridge auth claude-token add $TOKENVAR",
         "auth_token_mutation_via_unresolved_var"),
        # ---- #1738 config DENY still fires (regression) + C6 widen ----
        ("eval 'agb config set-env K=V'", "config_mutation_via_eval"),
        ("bash -c 'agb config set --path /x'", "config_mutation_via_bash"),
        ("sh -c 'agb config set-env K=V'", "config_mutation_via_sh"),
        # C6 — a config mutation through a widened interpreter now also denies
        # (additive-stricter; was ALLOWED before #2163).
        ("zsh -c 'agb config set-env K=V'", "config_mutation_via_zsh"),
        ("ksh -c 'agb config set --path /x'", "config_mutation_via_ksh"),
        ("agb config $V K=V", "config_mutation_via_unresolved_var"),
        # config takes precedence when a stage names both surfaces.
        ("eval 'agb config set-env AUTH_CLAUDE_TOKEN=x'",
         "config_mutation_via_eval"),
        # ---- C4a + over-block-0 ALLOW (must be None) ----
        # global-auth-sync status is READ-ONLY — allowed direct AND via a shell.
        ("agb auth claude-token global-auth-sync status", None),
        ("bash -c 'agb auth claude-token global-auth-sync status'", None),
        # a status read with an extra --note (no mutation verb) stays read-only.
        ("agb auth claude-token global-auth-sync status --note foo", None),
        # DIRECT literal mutation verb is NOT flagged here — the wrapper's
        # caller-trust gate owns it; this hook is indirection-only.
        ("agb auth claude-token add mytoken", None),
        ("agent-bridge auth claude-token add sk-ant-oLITERAL", None),
        # a token-free request verb is not a mutation.
        ("agent-bridge auth claude-token receive", None),
        # config reads, and unrelated commands that merely CONTAIN the
        # substrings "auth"/"config"/"$" (the #1690 false-positive class).
        ("agb config get foo", None),
        ("grep auth lib/x.py", None),
        ("awk '{print $token}' auth.log", None),
        ("awk '{print $1}' lib/system_config_paths.py", None),
        ("cat state/tasks.db", None),
        ("rg claude-token docs/", None),
    ]


def _run_indirection(module, failures: list[str]) -> int:
    fn = module._config_mutation_via_indirection
    n = 0
    for cmd, want in _indirection_cases():
        n += 1
        got = fn(cmd)
        if got != want:
            tag = "missed-deny" if want else "over-block"
            failures.append(
                f"  FAIL  [{tag}] _config_mutation_via_indirection({cmd!r}) "
                f"= {got!r}, want {want!r}"
            )
        else:
            print(f"  PASS  _config_mutation_via_indirection({cmd!r}) = {got!r}")
    return n


def _run_stage_helpers(module, failures: list[str]) -> int:
    """Directly pin the read-only carve-out (C4a) + kind precedence."""
    auth = module._stage_reaches_auth_token_mutation
    cfg = module._stage_reaches_config_mutation
    kind = module._stage_protected_mutation_kind
    n = 0
    checks: list[tuple[str, bool, str]] = [
        # (label, predicate-result, "want")
    ]

    def add(label: str, got: object, want: object) -> None:
        nonlocal n
        n += 1
        if got != want:
            failures.append(f"  FAIL  {label}: got {got!r}, want {want!r}")
        else:
            print(f"  PASS  {label} = {got!r}")

    # C4a: status is read-only (never a mutation), enable/disable mutate.
    add("auth('agb auth claude-token global-auth-sync status')",
        auth("agb auth claude-token global-auth-sync status"), False)
    add("auth('agb auth claude-token global-auth-sync enable')",
        auth("agb auth claude-token global-auth-sync enable"), True)
    add("auth('agb auth claude-token global-auth-sync disable')",
        auth("agb auth claude-token global-auth-sync disable"), True)
    # status + a hidden $action → still a mutation (the action is concealed).
    add("auth('...global-auth-sync $A' hides action)",
        auth("agb auth claude-token global-auth-sync $A"), True)
    # direct mutation verbs.
    add("auth('...claude-token rotate')",
        auth("agb auth claude-token rotate"), True)
    # receive is not a mutation.
    add("auth('...claude-token receive')",
        auth("agb auth claude-token receive"), False)
    # #2163 patch r1 BREAK1 — a co-located global-auth-sync substring must NOT
    # mask a real add/rotate; and its own trailing "sync" must NOT flag a status
    # read as the `sync` mutation verb.
    add("auth('add ... --note global-auth-sync' not masked)",
        auth("agb auth claude-token add x --note global-auth-sync"), True)
    add("auth('rotate ... --label global-auth-sync-status' not masked)",
        auth("agb auth claude-token rotate --label global-auth-sync-status"), True)
    add("auth('global-auth-sync status' not sync-verb)",
        auth("agb auth claude-token global-auth-sync status"), False)
    add("auth('global-auth-sync status --note foo' read-only)",
        auth("agb auth claude-token global-auth-sync status --note foo"), False)
    # config predicate basics.
    add("cfg('agb config set-env K=V')",
        cfg("agb config set-env K=V"), True)
    add("cfg('agb config get x')", cfg("agb config get x"), False)
    # kind precedence: config wins when both surfaces present.
    add("kind(config+auth) == 'config'",
        kind("agb config set-env AUTH_CLAUDE_TOKEN=x"), "config")
    add("kind(auth only) == 'auth'",
        kind("agb auth claude-token rotate"), "auth")
    add("kind(neither) is None", kind("grep auth x"), None)
    return n


def _run_redaction(module, failures: list[str]) -> int:
    """patch criterion 4 — the audit emitter must never write the token bytes.

    Captures the audit `detail` by monkeypatching `write_audit`, then asserts
    the redacted `sample` retains the `sk-ant-o` prefix but NOT the secret run,
    and that the `verb` field reflects auth vs config.
    """
    captured: dict[str, object] = {}

    def _capture(event: str, agent: str, detail: dict) -> None:
        captured["event"] = event
        captured["detail"] = detail

    orig = module.write_audit
    module.write_audit = _capture  # type: ignore[assignment]
    n = 0
    try:
        secret = "sk-ant-oSUPERSECRETVALUE123"
        text = f"eval 'agb auth claude-token add {secret}'"
        module._emit_config_mutation_via_indirection_audit(
            "fixer",
            text=text,
            tool_input={"command": text},
            reason="auth_token_mutation_via_eval",
        )
        detail = captured.get("detail") or {}
        sample = str(detail.get("sample", ""))
        n += 1
        if "SUPERSECRETVALUE123" in sample:
            failures.append(
                "  FAIL  audit sample LEAKED the plaintext token run: "
                f"{sample!r}"
            )
        elif "sk-ant-o<REDACTED>" not in sample:
            failures.append(
                "  FAIL  audit sample did not redact to sk-ant-o<REDACTED>: "
                f"{sample!r}"
            )
        else:
            print(f"  PASS  audit sample redacted: {sample!r}")
        n += 1
        if detail.get("verb") != "auth claude-token":
            failures.append(
                f"  FAIL  auth-reason verb = {detail.get('verb')!r}, "
                "want 'auth claude-token'"
            )
        else:
            print("  PASS  auth-reason audit verb = 'auth claude-token'")

        # config reason keeps the config verb label.
        module._emit_config_mutation_via_indirection_audit(
            "fixer",
            text="eval 'agb config set-env K=V'",
            tool_input={"command": "eval 'agb config set-env K=V'"},
            reason="config_mutation_via_eval",
        )
        detail = captured.get("detail") or {}
        n += 1
        if detail.get("verb") != "config set/set-env":
            failures.append(
                f"  FAIL  config-reason verb = {detail.get('verb')!r}, "
                "want 'config set/set-env'"
            )
        else:
            print("  PASS  config-reason audit verb = 'config set/set-env'")
    finally:
        module.write_audit = orig  # type: ignore[assignment]
    return n


def _run_f3(module, tmp_root: str, failures: list[str]) -> int:
    """F3 — the all-env sandbox predicate. Manipulate os.environ and re-call
    `_bridge_home_is_test_temp` (operator_home() re-reads BRIDGE_HOME every
    call, so there is no cache to defeat).

    The tilde-spelled-anchor cases (#2163 codex r1 regression guard) are REAL
    teeth only when cwd sits under a fixed temp root AND HOME resolves to a
    non-temp (live) path: on the pre-fix `realpath` code a `~/…` anchor
    canonicalizes as the temp-cwd-relative `<cwd>/~/…` (reads "sandbox"), while
    the fixed `realpath(expanduser(...))` resolves it to `<HOME>/…` (live). So
    this layer chdir's into the temp root and pins HOME to a fixed non-temp
    home for the duration; both are restored in `finally`."""
    tt = module._bridge_home_is_test_temp
    home_tmp = f"{tmp_root}/home"
    state_tmp = f"{tmp_root}/state"
    # A fixed non-temp HOME so `expanduser("~/…")` lands live regardless of the
    # CI runner's real HOME (which lib.sh / a sibling smoke may point at a temp
    # BRIDGE_HOME). `~/…` then expands to a `/opt/agent-bridge-live/.agent-bridge`
    # LIVE path — outside every fixed temp root.
    live_home = f"{_LIVE_ROOT}/home"
    n = 0

    cases: list[tuple[str, dict[str, str], bool]] = [
        ("all-temp home only", {"BRIDGE_HOME": home_tmp}, True),
        ("all-temp home+state",
         {"BRIDGE_HOME": home_tmp, "BRIDGE_STATE_DIR": state_tmp}, True),
        # per-anchor split-root spoof — home temp, one anchor LIVE ⇒ not sandbox.
        ("spoof via BRIDGE_STATE_DIR",
         {"BRIDGE_HOME": home_tmp, "BRIDGE_STATE_DIR": f"{_LIVE_ROOT}/state"},
         False),
        ("spoof via BRIDGE_RUNTIME_CONFIG_FILE",
         {"BRIDGE_HOME": home_tmp,
          "BRIDGE_RUNTIME_CONFIG_FILE": "/srv/agent-bridge/config.json"},
         False),
        ("spoof via BRIDGE_RUNTIME_ROOT",
         {"BRIDGE_HOME": home_tmp, "BRIDGE_RUNTIME_ROOT": _LIVE_ROOT}, False),
        # #2163 codex r1 — TILDE-spelled LIVE anchors. The real writers
        # (bridge-auth.py / bridge-config.py) expanduser() these; the predicate
        # must too, else a `~/…` anchor reads temp-cwd-relative (sandbox) while
        # the write lands live. These MUST be not-sandbox (False).
        ("tilde spoof via BRIDGE_STATE_DIR",
         {"BRIDGE_HOME": home_tmp, "BRIDGE_STATE_DIR": "~/.agent-bridge/state"},
         False),
        ("tilde spoof via BRIDGE_RUNTIME_CONFIG_FILE",
         {"BRIDGE_HOME": home_tmp,
          "BRIDGE_RUNTIME_CONFIG_FILE": "~/.agent-bridge/runtime/bridge-config.json"},
         False),
        ("tilde spoof via BRIDGE_RUNTIME_ROOT",
         {"BRIDGE_HOME": home_tmp,
          "BRIDGE_RUNTIME_ROOT": "~/.agent-bridge/runtime"}, False),
        # #2163 patch r1 BREAK2 — the OAuth token-registry anchors must be in
        # the enumerated set, else a fixer points the config anchors at /tmp
        # (predicate "sandbox") while repointing the registry LIVE → forged-admin
        # token mutation lands in the live registry. Live abs + tilde variants.
        ("spoof via BRIDGE_CLAUDE_TOKEN_REGISTRY",
         {"BRIDGE_HOME": home_tmp,
          "BRIDGE_CLAUDE_TOKEN_REGISTRY": f"{_LIVE_ROOT}/registry.json"}, False),
        ("spoof via BRIDGE_RUNTIME_SECRETS_DIR",
         {"BRIDGE_HOME": home_tmp,
          "BRIDGE_RUNTIME_SECRETS_DIR": f"{_LIVE_ROOT}/secrets"}, False),
        ("tilde spoof via BRIDGE_CLAUDE_TOKEN_REGISTRY",
         {"BRIDGE_HOME": home_tmp,
          "BRIDGE_CLAUDE_TOKEN_REGISTRY":
              "~/.agent-bridge/secrets/claude-oauth-tokens.json"}, False),
        ("tilde spoof via BRIDGE_RUNTIME_SECRETS_DIR",
         {"BRIDGE_HOME": home_tmp,
          "BRIDGE_RUNTIME_SECRETS_DIR": "~/.agent-bridge/secrets"}, False),
        # all anchors temp (incl. the registry pair) ⇒ sandbox.
        ("all-temp incl token-registry anchors",
         {"BRIDGE_HOME": home_tmp,
          "BRIDGE_CLAUDE_TOKEN_REGISTRY": f"{tmp_root}/reg.json",
          "BRIDGE_RUNTIME_SECRETS_DIR": f"{tmp_root}/secrets"}, True),
        # prod home (not temp) ⇒ not sandbox even with no anchors.
        ("prod home", {"BRIDGE_HOME": _LIVE_ROOT}, False),
        # tilde-spelled prod home ⇒ not sandbox (BRIDGE_HOME is expanduser'd by
        # operator_home() already; guards that path too).
        ("tilde prod home", {"BRIDGE_HOME": "~/.agent-bridge"}, False),
        # empty anchor is treated as unset ⇒ inherits (temp) home (over-block-0).
        ("empty anchor inherits home",
         {"BRIDGE_HOME": home_tmp, "BRIDGE_STATE_DIR": ""}, True),
    ]

    saved = {k: os.environ.get(k) for k in _ANCHORS}
    saved_home = os.environ.get("HOME")
    saved_cwd = os.getcwd()
    try:
        os.chdir(tmp_root)  # cwd under a fixed temp root (confined-fixer shape)
        os.environ["HOME"] = live_home  # `~` ⇒ live, deterministic
        for label, env, want in cases:
            n += 1
            for k in _ANCHORS:
                os.environ.pop(k, None)
            for k, v in env.items():
                os.environ[k] = v
            got = tt()
            if got != want:
                failures.append(
                    f"  FAIL  [F3] _bridge_home_is_test_temp({label}) "
                    f"= {got}, want {want}  env={env}"
                )
            else:
                print(f"  PASS  [F3] {label} = {got}")
    finally:
        os.chdir(saved_cwd)
        if saved_home is not None:
            os.environ["HOME"] = saved_home
        else:
            os.environ.pop("HOME", None)
        for k in _ANCHORS:
            os.environ.pop(k, None)
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v
    return n


def main() -> int:
    tmp_root = sys.argv[1] if len(sys.argv) > 1 else "/tmp/smoke-2163"
    module = _load_module()
    failures: list[str] = []

    total = 0
    print("[smoke:2163] --- indirection allow/deny matrix ---")
    total += _run_indirection(module, failures)
    print("[smoke:2163] --- stage-helper / C4a carve-out ---")
    total += _run_stage_helpers(module, failures)
    print("[smoke:2163] --- criterion 4: audit redaction + verb ---")
    total += _run_redaction(module, failures)
    print("[smoke:2163] --- F3 all-env sandbox predicate ---")
    total += _run_f3(module, tmp_root, failures)

    if failures:
        print(f"\n[smoke:2163] {len(failures)} failure(s):", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
        return 1
    print(f"\n[smoke:2163] PASS — all {total} assertions held")
    return 0


if __name__ == "__main__":
    sys.exit(main())
