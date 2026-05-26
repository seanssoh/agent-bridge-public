#!/usr/bin/env python3
# scripts/smoke/watchdog-profile-contract.py — direct callee for
# scripts/smoke/watchdog-profile-contract.sh. Kept as a standalone file
# (not inlined as heredoc-stdin to python3) so the smoke is immune to
# footgun #11 (Bash 5.3.9 `read_comsub` / `heredoc_write` deadlock).
#
# Loads bridge-watchdog.py via importlib (the file name has a hyphen so a
# plain import won't work) and pins the home-profile-contract truth table:
# has_home_profile_contract, required_profile_files, and the classify_status
# signals it gates. The regression of record is the antigravity engine
# (v0.14.5) surfacing as a false status=error, plus the guard that a Claude
# static agent with missing files must still classify as error.
#
# #1237 (v0.15.0-beta2 lane ε): Codex now has its own engine-native
# contract — has_codex_profile_contract returns True for codex+static and
# the required-file set is CODEX_REQUIRED_FILES (AGENTS.md). Engines that
# have NO implemented contract (antigravity, any future engine string)
# classify as ``unsupported_engine_contract`` instead of the pre-#1237
# silent-OK or conservative-Claude-default behaviors — codex r1 directive:
# "Unknown engines should remain conservative … status must say
# `unsupported_engine_contract` rather than silently OK".

import importlib.util
import pathlib
import sys


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    watchdog_path = repo_root / "bridge-watchdog.py"
    spec = importlib.util.spec_from_file_location(
        "bridge_watchdog_under_test", watchdog_path
    )
    if spec is None or spec.loader is None:
        print(f"[smoke] cannot load {watchdog_path}", file=sys.stderr)
        return 2
    module = importlib.util.module_from_spec(spec)
    # Register before exec_module so dataclass field resolution
    # (AgentWatch) can look the module up via sys.modules.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    has_contract = module.has_home_profile_contract
    has_codex_contract = module.has_codex_profile_contract
    required_profile_files = module.required_profile_files
    classify_status = module.classify_status
    claude_required = module.CLAUDE_REQUIRED_FILES
    codex_required = module.CODEX_REQUIRED_FILES

    failures: list[str] = []

    def check(label: str, got: object, want: object) -> None:
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")
        else:
            print(f"  PASS  {label} = {got!r}")

    # --- has_home_profile_contract (Claude only post-#1237) -------------
    check("contract: claude+static", has_contract("claude", "static"), True)
    check("contract: claude+unknown-source", has_contract("claude", ""), True)
    check("contract: claude+dynamic", has_contract("claude", "dynamic"), False)
    # has_home_profile_contract is the *Claude*-specific predicate. Codex
    # under #1237 has its own engine-native contract (see
    # has_codex_profile_contract below); it MUST return False from the
    # Claude predicate so a codex agent does not get the Claude-profile
    # drift overlay applied on top of its Codex check.
    check("contract: codex+static (claude-side)", has_contract("codex", "static"), False)
    check("contract: codex+dynamic (claude-side)", has_contract("codex", "dynamic"), False)
    # antigravity and any future-unknown engine: not Claude — same path
    # as codex from the Claude-predicate's POV. They differ in
    # classify_status (codex has a contract; antigravity / future-engine
    # surface as `unsupported_engine_contract`).
    check("contract: antigravity+static", has_contract("antigravity", "static"), False)
    check("contract: antigravity+dynamic", has_contract("antigravity", "dynamic"), False)
    check("contract: unknown-engine+static", has_contract("future-engine", "static"), False)
    check("contract: unknown-engine+dynamic", has_contract("future-engine", "dynamic"), False)

    # --- has_codex_profile_contract (#1237) ------------------------------
    check("codex-contract: codex+static", has_codex_contract("codex", "static"), True)
    check("codex-contract: codex+unknown-source", has_codex_contract("codex", ""), True)
    # Dynamic codex is still waived (#907 fresh-provision rule applies
    # regardless of engine).
    check("codex-contract: codex+dynamic", has_codex_contract("codex", "dynamic"), False)
    check("codex-contract: claude+static", has_codex_contract("claude", "static"), False)
    check(
        "codex-contract: antigravity+static",
        has_codex_contract("antigravity", "static"),
        False,
    )

    # --- required_profile_files -----------------------------------------
    check(
        "required: claude+static -> CLAUDE_REQUIRED_FILES",
        required_profile_files("claude", "static"),
        claude_required,
    )
    check(
        "required: claude legacy positional -> CLAUDE_REQUIRED_FILES",
        required_profile_files("claude"),
        claude_required,
    )
    # #1237: codex now has its own required-file set.
    check(
        "required: codex+static -> CODEX_REQUIRED_FILES",
        required_profile_files("codex", "static"),
        codex_required,
    )
    check(
        "required: codex+dynamic -> ()",
        required_profile_files("codex", "dynamic"),
        (),
    )
    check(
        "required: antigravity+static -> ()",
        required_profile_files("antigravity", "static"),
        (),
    )
    check(
        "required: claude+dynamic -> ()",
        required_profile_files("claude", "dynamic"),
        (),
    )
    # An unknown engine has no required-file set — it surfaces as
    # `unsupported_engine_contract` in classify_status rather than being
    # held to a conservative Claude default it has no business satisfying.
    check(
        "required: unknown-engine+static -> ()",
        required_profile_files("future-engine", "static"),
        (),
    )

    # --- classify_status: regression guard ------------------------------
    # A Claude static agent missing profile files must still be error.
    check(
        "classify: claude+static+missing-files -> error",
        classify_status(
            ["CLAUDE.md"], [], "complete", False,
            session_type="admin", agent_source="static", engine="claude",
        ),
        "error",
    )
    # #1237: a codex static agent missing its Codex-required file must
    # error. Pre-#1237 codex was a silent-OK allowlist entry; the
    # engine-native contract means a real missing AGENTS.md now surfaces.
    check(
        "classify: codex+static+missing-files -> error",
        classify_status(
            ["AGENTS.md"], [], "missing", False,
            session_type="unknown", agent_source="static", engine="codex",
        ),
        "error",
    )
    # #1237: a codex static agent with no missing required files
    # classifies ok. Claude-only signals (missing managed block, pending
    # onboarding) are explicitly ignored for codex.
    check(
        "classify: codex+static+missing-block -> ok (claude-only signal)",
        classify_status(
            [], [], "missing", True,
            session_type="unknown", agent_source="static", engine="codex",
        ),
        "ok",
    )
    # Dynamic agent of any engine: contract is fully waived (#907),
    # caller-supplied missing_files passed in MUST NOT escalate.
    check(
        "classify: claude+dynamic+missing-files -> ok",
        classify_status(
            ["CLAUDE.md"], [], "pending", False,
            session_type="dynamic", agent_source="dynamic", engine="claude",
        ),
        "ok",
    )
    check(
        "classify: codex+dynamic+missing-files -> ok",
        classify_status(
            ["AGENTS.md"], [], "pending", False,
            session_type="dynamic", agent_source="dynamic", engine="codex",
        ),
        "ok",
    )

    # --- classify_status: unsupported-engine path (#1237 r1) -------------
    # An engine with no implemented contract MUST classify as
    # `unsupported_engine_contract` rather than silently OK or as an
    # error against a contract it has no business being held to. The two
    # call sites of record: antigravity (known but no contract yet) and
    # any future-unknown engine.
    check(
        "classify: antigravity+static+missing-block -> unsupported_engine_contract",
        classify_status(
            [], [], "missing", True,
            session_type="unknown", agent_source="static", engine="antigravity",
        ),
        "unsupported_engine_contract",
    )
    check(
        "classify: unknown-engine+static -> unsupported_engine_contract",
        classify_status(
            [], [], "complete", False,
            session_type="", agent_source="static", engine="future-engine",
        ),
        "unsupported_engine_contract",
    )
    # Broken links are an engine-agnostic drift signal — even on an
    # unsupported engine they surface as warn so a real misconfig is
    # never silently dropped.
    check(
        "classify: antigravity+static+broken-links -> warn",
        classify_status(
            [], ["MEMORY.md -> missing"], "missing", False,
            session_type="unknown", agent_source="static", engine="antigravity",
        ),
        "warn",
    )

    # --- classify_status: claude contract still enforced ----------------
    check(
        "classify: claude+static+missing-block -> warn",
        classify_status(
            [], [], "complete", True,
            session_type="admin", agent_source="static", engine="claude",
        ),
        "warn",
    )
    check(
        "classify: claude+static+pending-onboarding -> warn",
        classify_status(
            [], [], "pending", False,
            session_type="admin", agent_source="static", engine="claude",
        ),
        "warn",
    )

    # --- classify_status: dynamic exemptions (no regression) -------------
    check(
        "classify: claude+dynamic+missing-block -> ok",
        classify_status(
            [], [], "pending", True,
            session_type="dynamic", agent_source="dynamic", engine="claude",
        ),
        "ok",
    )

    if failures:
        for f in failures:
            print(f"  FAIL  {f}", file=sys.stderr)
        return 1
    print("[smoke:watchdog-profile-contract] all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
