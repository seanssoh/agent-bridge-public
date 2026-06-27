#!/usr/bin/env python3
# scripts/smoke/19146-bash-git-primary-checkout-guard.py — issue #19146.
#
# Loaded as a module-file (file-as-argv, NO interpreter heredoc-stdin —
# footgun #11) by the `.sh` wrapper, which sets up an isolated BRIDGE_HOME
# fixture (smoke/lib.sh::smoke_setup_bridge_home). This driver builds a repo
# fixture under the smoke temp root:
#
#   <tmp>/repo                        operator's PRIMARY checkout (.git is a DIR)
#   <tmp>/repo/.claude/worktrees/agent-x   a dispatched fixer's worktree
#                                          (.git is a FILE — a linked worktree)
#   <tmp>/repo/.claude/worktrees/agent-x/subdir   a real sub-directory
#   <tmp>/repo/.claude/worktrees/agent-x/link-primary -> <tmp>/repo  (poisoned)
#   <tmp>/bridge-wt                   a bridge --prefer new linked worktree
#                                     (NOT under .claude/worktrees; .git is FILE)
#
# It then drives the FULL accumulated bypass matrix against the real guard
# (`_bash_git_primary_checkout_guard_reason`) with os.chdir per case (in
# production the hook process cwd == the session cwd), plus two end-to-end
# `handle_pretool` assertions (deny RESPONSE shape + audit row; and a
# canonical-safe ALLOW emits no deny response).
#
# DENY  (confined fixer): env GIT_* bare/wrapper/-S/-C/--chdir, --git-dir/
#   --work-tree/--git-common-dir flag, git -C primary, function/alias redef,
#   symlink cwd (start + via cd), cd-primary, var/interpreter obfuscation,
#   unbalanced quote, command-level BRIDGE_BASH_GIT_GUARD=0, every shared-repo
#   verb (branch -D/-d/-m, worktree remove|prune, stash drop|clear, reflog
#   delete|expire, gc --prune).
# ALLOW (canonical-safe + over-block-0): worktree bare reset/checkout/clean,
#   cd real-subdir && checkout, stash push / branch create / worktree list /
#   read-only status|log|diff (incl. `-C primary log`), add/commit/push;
#   operator session (cwd = primary root) — every command above ALLOWED
#   (structural exemption); process-level BRIDGE_BASH_GIT_GUARD=0 disables.
#
# Exit 0 on all-pass; non-zero (with a [FAIL] line) on any mismatch.

import importlib.util
import io
import json
import os
import pathlib
import sys
from contextlib import redirect_stdout


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


def main() -> int:
    repo_root = pathlib.Path(sys.argv[1]).resolve()
    tmp = pathlib.Path(sys.argv[2]).resolve()
    tp = _load_tool_policy(repo_root)

    # ---- fixture -------------------------------------------------------------
    primary = tmp / "repo"
    wt = primary / ".claude" / "worktrees" / "agent-x"
    sub = wt / "subdir"
    sub.mkdir(parents=True)
    (primary / ".git").mkdir()  # PRIMARY checkout: .git is a DIRECTORY
    (wt / ".git").write_text(
        "gitdir: " + str(primary / ".git" / "worktrees" / "agent-x") + "\n"
    )  # linked worktree: .git is a FILE
    link_primary = wt / "link-primary"
    os.symlink(primary, link_primary)  # poisoned: worktree path -> primary

    # bridge --prefer new worktree (NOT under .claude/worktrees; .git is a FILE)
    bridge_wt = tmp / "bridge-wt"
    bridge_wt.mkdir()
    (bridge_wt / ".git").write_text("gitdir: " + str(primary / ".git") + "\n")

    P = str(primary)
    WT = str(wt)
    SUB = str(sub)
    LINK = str(link_primary)
    BWT = str(bridge_wt)

    # Ensure the bridge-workdir env cover is OFF for every non-bridge case so the
    # operator/worktree cwd checks are decided purely by cwd.
    for k in ("BRIDGE_AGENT_WORKDIR_RESOLVED", "BRIDGE_AGENT_WORKDIR"):
        os.environ.pop(k, None)
    os.environ.pop("BRIDGE_BASH_GIT_GUARD", None)

    def reason(cwd: str, cmd: str):
        # In production the hook process cwd == the session cwd.
        os.chdir(cwd)
        payload = {"cwd": cwd, "tool_input": {"command": cmd}}
        return tp._bash_git_primary_checkout_guard_reason(
            cmd, payload, "fixer", tool_input=payload["tool_input"]
        )

    def expect(label: str, cwd: str, cmd: str, want_deny: bool) -> None:
        r = reason(cwd, cmd)
        denied = isinstance(r, str) and r != ""
        check(label, denied == want_deny, f"deny={denied} want={want_deny} reason={r!r}")

    # ---- DENY: confined fixer, accumulated bypass matrix ---------------------
    expect("cd-primary && reset --hard", WT, f"cd {P} && git reset --hard", True)
    expect("git -C primary reset", WT, f"git -C {P} reset", True)
    expect("--git-dir flag reset", WT, f"git --git-dir={P}/.git reset --hard", True)
    expect("--work-tree flag checkout", WT, f"git --work-tree={P} checkout .", True)
    expect(
        "--git-common-dir flag clean",
        WT,
        f"git --git-common-dir={P}/.git clean -fdx",
        True,
    )
    expect(
        "GIT_INDEX_FILE env-assign prefix",
        WT,
        f"GIT_INDEX_FILE={P}/.git/index git reset",
        True,
    )
    expect("env GIT_DIR wrapper", WT, f"env GIT_DIR={P}/.git git reset", True)
    expect(
        "/usr/bin/env -S packed GIT_*",
        WT,
        f"/usr/bin/env -S 'GIT_DIR={P}/.git git' reset",
        True,
    )
    expect("/usr/bin/env -C primary", WT, f"/usr/bin/env -C {P} git reset", True)
    expect(
        "nested env -S packing",
        WT,
        f"""env -S 'env -S "GIT_DIR={P}/.git git" reset'""",
        True,
    )
    expect("env --chdir=primary", WT, f"env --chdir={P} git reset", True)
    expect(
        "function redef git()",
        WT,
        'git(){ cd ' + P + '&&command git "$@";}; git reset --hard',
        True,
    )
    expect("symlink cwd via cd", WT, f"cd {LINK} && git reset --hard HEAD", True)
    expect("symlink as START cwd (poisoned)", LINK, "git reset --hard", True)
    expect("var-indirection verb", WT, "g=reset; git $g --hard", True)
    expect("bash -c indirection", WT, f"bash -c 'cd {P} && git reset --hard'", True)
    expect("eval indirection", WT, "eval 'git reset --hard'", True)
    expect("subshell cd-primary", WT, f"(cd {P} && git reset --hard)", True)
    expect("brace-group git -C primary", WT, f"{{ git -C {P} reset --hard; }}", True)
    expect("brace-group fn call escape", WT, f"f(){{ cd {P} && git reset; }}; f", True)
    expect("command-level escape-hatch", WT, "BRIDGE_BASH_GIT_GUARD=0 git reset", True)
    expect("unbalanced quote masks ops", WT, f"git reset 'x && git -C {P} reset", True)
    expect(
        "line-continuation hides -C",
        WT,
        f"git -C \\\n{P} reset --hard",
        True,
    )
    expect(
        "line-continuation cd-primary",
        WT,
        f"cd {P} &&\\\ngit reset --hard",
        True,
    )
    expect("ansi-c quoted -C flag", WT, f"git $'\\x2dC' {P} reset --hard", True)
    expect("net-escape cd then reset", WT, f"cd {P} && git reset && cd {WT}", True)
    expect(
        "config-alias shell injection",
        WT,
        f"git -c alias.x='!cd {P} && git reset --hard' x",
        True,
    )
    # shared-repo verbs (denied unconditionally in confined context)
    expect("shared branch -D", WT, "git branch -D main", True)
    expect("shared branch -d", WT, "git branch -d feature/x", True)
    expect("shared branch -m rename", WT, "git branch -m old new", True)
    expect(
        "shared worktree remove", WT, f"git worktree remove {P}/.claude/worktrees/y", True
    )
    expect("shared worktree prune", WT, "git worktree prune", True)
    expect("shared stash drop", WT, "git stash drop", True)
    expect("shared stash clear", WT, "git stash clear", True)
    expect("shared reflog expire", WT, "git reflog expire --all", True)
    expect("shared reflog delete", WT, "git reflog delete HEAD@{0}", True)
    expect("shared gc --prune=now", WT, "git gc --prune=now", True)
    # working-tree verbs reached via escape are denied too
    expect("stash pop via -C primary", WT, f"git -C {P} stash pop", True)
    expect("switch via cd-primary", WT, f"cd {P} && git switch main", True)
    expect("restore via env wrapper", WT, f"env GIT_DIR={P}/.git git restore .", True)

    # ---- ALLOW: canonical-safe shape (over-block regression = 0) -------------
    expect("worktree bare reset --hard", WT, "git reset --hard", False)
    expect("worktree bare checkout file", WT, "git checkout .", False)
    expect("worktree bare clean -fdx", WT, "git clean -fdx", False)
    expect("worktree bare switch", WT, "git switch main", False)
    expect("worktree bare restore", WT, "git restore .", False)
    expect("worktree bare stash pop", WT, "git stash pop", False)
    expect("cd real-subdir && checkout", WT, f"cd {SUB} && git checkout .", False)
    expect("path-form /usr/bin/git reset", WT, "/usr/bin/git reset --hard", False)
    # NON-goals — never blocked even in a confined fixer
    expect("non-goal stash push", WT, "git stash push -m x", False)
    expect("non-goal bare stash", WT, "git stash", False)
    expect("non-goal branch create", WT, "git branch feature/x", False)
    expect("non-goal branch list", WT, "git branch -a", False)
    expect("non-goal worktree list", WT, "git worktree list", False)
    expect("non-goal worktree add", WT, f"git worktree add {WT}/wt2", False)
    expect("read-only status", WT, "git status", False)
    expect("read-only log (-C primary)", WT, f"git -C {P} log --oneline", False)
    expect("read-only diff", WT, "git diff HEAD~1", False)
    expect("read-only rev-parse", WT, "git rev-parse HEAD", False)
    expect("non-goal add+commit+push", WT, "git add -A && git commit -m x && git push", False)
    expect("non-goal fetch", WT, "git fetch origin", False)
    expect("benign -c commit (no bang)", WT, "git -c user.name=fixer commit -m x", False)
    expect("non-goal reflog show", WT, "git reflog show", False)
    expect("non-goal gc (no --prune)", WT, "git gc", False)
    expect("non-git command", WT, "echo git reset is just text", False)

    # ---- ALLOW: operator structural exemption (cwd = primary repo root) ------
    expect("operator cd-primary reset", P, f"cd {P} && git reset --hard", False)
    expect("operator -C reset", P, f"git -C {P} reset --hard", False)
    expect("operator bare reset", P, "git reset --hard", False)
    expect("operator branch -D", P, "git branch -D main", False)
    expect("operator function redef", P, 'git(){ command git "$@";}; git reset', False)
    expect("operator gc --prune", P, "git gc --prune=now", False)

    # ---- 2nd cover: bridge --prefer new linked worktree ----------------------
    os.environ["BRIDGE_AGENT_WORKDIR_RESOLVED"] = BWT
    expect("bridge-wt escape -C primary DENY", BWT, f"git -C {P} reset --hard", True)
    expect("bridge-wt cd-primary DENY", BWT, f"cd {P} && git reset --hard", True)
    expect("bridge-wt bare reset ALLOW", BWT, "git reset --hard", False)
    os.environ.pop("BRIDGE_AGENT_WORKDIR_RESOLVED", None)

    # ---- escape hatch: PROCESS-level env disables the guard ------------------
    os.environ["BRIDGE_BASH_GIT_GUARD"] = "0"
    expect("process-env hatch disables guard", WT, f"git -C {P} reset --hard", False)
    os.environ.pop("BRIDGE_BASH_GIT_GUARD", None)

    # ---- end-to-end handle_pretool: deny RESPONSE + audit row ----------------
    audit_log = pathlib.Path(os.environ["BRIDGE_AUDIT_LOG"])
    os.chdir(WT)

    def audit_actions(before: int) -> list[str]:
        if not audit_log.exists():
            return []
        acts = []
        for ln in audit_log.read_text().splitlines()[before:]:
            try:
                acts.append(json.loads(ln).get("action", ""))
            except json.JSONDecodeError:
                pass
        return acts

    before = (
        len(audit_log.read_text().splitlines()) if audit_log.exists() else 0
    )
    payload = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "cwd": WT,
        "tool_input": {"command": f"git -C {P} reset --hard"},
        "tool_use_id": "t1",
        "session_id": "s1",
    }
    buf = io.StringIO()
    with redirect_stdout(buf):
        tp.handle_pretool(payload, "fixer")
    out = buf.getvalue()
    parsed = {}
    try:
        parsed = json.loads(out)
    except json.JSONDecodeError:
        pass
    decision = (parsed.get("hookSpecificOutput") or {}).get("permissionDecision")
    check("e2e deny response = deny", decision == "deny", f"out={out!r}")
    acts = audit_actions(before)
    check(
        "e2e audit rows written",
        "tool_policy_bash_git_primary_checkout_denied" in acts
        and "agent_tool_denied" in acts,
        f"actions={acts}",
    )

    # canonical-safe ALLOW emits no deny response
    payload2 = {
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "cwd": WT,
        "tool_input": {"command": "git reset --hard"},
        "tool_use_id": "t2",
        "session_id": "s1",
    }
    buf2 = io.StringIO()
    with redirect_stdout(buf2):
        tp.handle_pretool(payload2, "fixer")
    check("e2e canonical-safe = no deny", buf2.getvalue().strip() == "", f"out={buf2.getvalue()!r}")

    if FAILURES:
        print("\n[smoke:19146] FAIL")
        for f in FAILURES:
            print("  - " + f)
        return 1
    print("\n[smoke:19146] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
