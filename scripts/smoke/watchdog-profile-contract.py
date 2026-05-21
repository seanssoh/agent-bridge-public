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
    required_profile_files = module.required_profile_files
    classify_status = module.classify_status
    claude_required = module.CLAUDE_REQUIRED_FILES

    failures: list[str] = []

    def check(label: str, got: object, want: object) -> None:
        if got != want:
            failures.append(f"{label}: got {got!r}, want {want!r}")
        else:
            print(f"  PASS  {label} = {got!r}")

    # --- has_home_profile_contract --------------------------------------
    check("contract: claude+static", has_contract("claude", "static"), True)
    check("contract: claude+unknown-source", has_contract("claude", ""), True)
    check("contract: claude+dynamic", has_contract("claude", "dynamic"), False)
    check("contract: codex+static", has_contract("codex", "static"), False)
    check("contract: codex+dynamic", has_contract("codex", "dynamic"), False)
    # The antigravity regression: a newer engine must be exempt by
    # construction, not fall through to the Claude default.
    check("contract: antigravity+static", has_contract("antigravity", "static"), False)
    check("contract: antigravity+dynamic", has_contract("antigravity", "dynamic"), False)

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
    check("required: codex+static -> ()", required_profile_files("codex", "static"), ())
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

    # --- classify_status: antigravity exemptions (the fix) --------------
    # antigravity static with no profile files reported (required is now
    # empty so missing_files is []), missing managed block, pending
    # onboarding -> ok, not warn/error.
    check(
        "classify: antigravity+static+missing-block -> ok",
        classify_status(
            [], [], "missing", True,
            session_type="unknown", agent_source="static", engine="antigravity",
        ),
        "ok",
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

    # --- classify_status: dynamic / codex exemptions (no regression) ----
    check(
        "classify: claude+dynamic+missing-block -> ok",
        classify_status(
            [], [], "pending", True,
            session_type="dynamic", agent_source="dynamic", engine="claude",
        ),
        "ok",
    )
    check(
        "classify: codex+static+missing-block -> ok",
        classify_status(
            [], [], "missing", True,
            session_type="unknown", agent_source="static", engine="codex",
        ),
        "ok",
    )

    # broken_links is not gated by the contract — a genuine drift signal
    # for any agent.
    check(
        "classify: antigravity+static+broken-links -> warn",
        classify_status(
            [], ["MEMORY.md -> missing"], "missing", False,
            session_type="unknown", agent_source="static", engine="antigravity",
        ),
        "warn",
    )

    if failures:
        for f in failures:
            print(f"  FAIL  {f}", file=sys.stderr)
        return 1
    print("[smoke:watchdog-profile-contract] all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
