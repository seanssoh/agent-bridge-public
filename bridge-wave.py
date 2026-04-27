#!/usr/bin/env python3
"""bridge-wave.py — JSON state + render helpers for `agent-bridge wave`.

Phase 1.1: state file read/write, README render, close-keyword lint, member-id
generation. Phase 1.2 adds per-member state mutation (`state-list-members`,
`state-mark-running`) so dispatch can record worker / worktree / branch /
queue-task wiring once a worker is spawned.

Subcommands invoked from `lib/bridge-wave.sh`:

  bridge-wave.py state-init <wave-id> <issue-or-brief> <main-agent> <worker-engine> <reviewer> <tracks-csv> <state-file> [<brief-file-relative-to-shared-root>]
  bridge-wave.py state-show  <state-file>
  bridge-wave.py state-list  <state-dir>
  bridge-wave.py state-render-readme <state-file> <readme-out>
  bridge-wave.py state-list-members <state-file> [--state pending|running|...]
  bridge-wave.py state-mark-running <state-file> <member-id> --worker <name> --worktree-root <path> --branch <name> --task-id <int>
  bridge-wave.py member-id-generate <wave-id> <track>
  bridge-wave.py wave-id-generate <issue-or-brief>
  bridge-wave.py close-keyword-scan <file>...
"""
from __future__ import annotations

import json
import os
import re
import secrets
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

KST = timezone(timedelta(hours=9))


def _now_iso() -> str:
    return datetime.now(KST).isoformat(timespec="seconds")


def _short_token(n: int = 4) -> str:
    return secrets.token_hex(n)


def _wave_id_for(issue_or_brief: str) -> str:
    """Compose a wave id. `<issue-or-brief>` is a GitHub issue number or a
    brief path. Uses YYYYMMDD-HHMM + 8-char random suffix for uniqueness."""
    stamp = datetime.now(KST).strftime("%Y%m%d-%H%M")
    if issue_or_brief.isdigit():
        return f"wave-{issue_or_brief}-{stamp}-{_short_token(4)}"
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", Path(issue_or_brief).stem.lower())[:24]
    return f"wave-{slug}-{stamp}-{_short_token(4)}"


def _member_id_for(wave_id: str, track: str) -> str:
    track_clean = re.sub(r"[^a-zA-Z0-9]+", "-", track).strip("-") or "main"
    return f"{wave_id}-{track_clean}-{_short_token(4)}"


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)


def cmd_wave_id_generate(args: list[str]) -> int:
    if len(args) != 1:
        print("usage: wave-id-generate <issue-or-brief>", file=sys.stderr)
        return 2
    print(_wave_id_for(args[0]))
    return 0


def cmd_member_id_generate(args: list[str]) -> int:
    if len(args) != 2:
        print("usage: member-id-generate <wave-id> <track>", file=sys.stderr)
        return 2
    print(_member_id_for(args[0], args[1]))
    return 0


def cmd_state_init(args: list[str]) -> int:
    if len(args) < 7:
        print(
            "usage: state-init <wave-id> <issue-or-brief> <main-agent> "
            "<worker-engine> <reviewer-policy> <tracks-csv> <state-file> [<brief-file>]",
            file=sys.stderr,
        )
        return 2
    (
        wave_id,
        issue_or_brief,
        main_agent,
        worker_engine,
        reviewer_policy,
        tracks_csv,
        state_file,
    ) = args[:7]
    brief_file = args[7] if len(args) > 7 else ""

    tracks = [t.strip() for t in tracks_csv.split(",") if t.strip()]
    if not tracks:
        tracks = ["main"]

    members = []
    for t in tracks:
        # Generate the member id ONCE per member; reusing the helper for the
        # brief_path would mint a new random suffix and disagree with
        # member_id (codex r1 finding on PR #373).
        member_id = _member_id_for(wave_id, t)
        members.append(
            {
                "member_id": member_id,
                "track": t,
                "branch": None,
                "worktree_root": None,
                "task_id": None,
                "pr_url": None,
                "state": "pending",
                "codex_plan_status": None,
                "codex_review_status": None,
                "verification_status": None,
                "cleanup_status": None,
                "brief_path": f"waves/{wave_id}/{member_id}/brief.md",
            }
        )

    state = {
        "wave_id": wave_id,
        "issue": issue_or_brief if issue_or_brief.isdigit() else None,
        "brief_source": issue_or_brief,
        "brief_file": brief_file or None,
        "main_agent": main_agent,
        "worker_engine": worker_engine,
        "reviewer_policy": reviewer_policy or "codex-rescue",
        "tracks": tracks,
        "created_at": _now_iso(),
        "updated_at": _now_iso(),
        "members": members,
        "audit": ["wave_dispatched"],
    }

    _atomic_write(Path(state_file), json.dumps(state, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(state, indent=2, ensure_ascii=False))
    return 0


def cmd_state_show(args: list[str]) -> int:
    if len(args) != 1:
        print("usage: state-show <state-file>", file=sys.stderr)
        return 2
    path = Path(args[0])
    if not path.exists():
        print(f"state file not found: {path}", file=sys.stderr)
        return 1
    state = json.loads(path.read_text(encoding="utf-8"))
    print(json.dumps(state, indent=2, ensure_ascii=False))
    return 0


def cmd_state_list(args: list[str]) -> int:
    if len(args) != 1:
        print("usage: state-list <state-dir>", file=sys.stderr)
        return 2
    state_dir = Path(args[0])
    if not state_dir.is_dir():
        print(json.dumps({"waves": []}, indent=2))
        return 0

    waves = []
    for f in sorted(state_dir.glob("*.json")):
        try:
            s = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        member_states: dict[str, int] = {}
        for m in s.get("members", []):
            member_states[m["state"]] = member_states.get(m["state"], 0) + 1
        waves.append(
            {
                "wave_id": s.get("wave_id"),
                "issue": s.get("issue"),
                "main_agent": s.get("main_agent"),
                "tracks": s.get("tracks", []),
                "member_states": member_states,
                "created_at": s.get("created_at"),
                "updated_at": s.get("updated_at"),
            }
        )
    print(json.dumps({"waves": waves}, indent=2, ensure_ascii=False))
    return 0


def cmd_state_list_members(args: list[str]) -> int:
    """List members from a wave state file as TSV rows.

    Output: one row per matching member, tab-separated:
      <member_id>\t<track>\t<absolute_brief_path>

    The brief path stored in state is relative to BRIDGE_SHARED_DIR; this
    helper joins it with the supplied shared-dir to give the bash caller an
    absolute path it can pass to `bridge-task.sh create --body-file`.

    Args (positional):
      <state-file> <shared-dir>
    Args (optional):
      --state <name>   only emit members in this state (default: pending)
    """
    state_filter = "pending"
    positional: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--state":
            if i + 1 >= len(args):
                print("usage: state-list-members <state-file> <shared-dir> [--state <name>]", file=sys.stderr)
                return 2
            state_filter = args[i + 1]
            i += 2
            continue
        if a.startswith("--state="):
            state_filter = a.split("=", 1)[1]
            i += 1
            continue
        positional.append(a)
        i += 1
    if len(positional) != 2:
        print("usage: state-list-members <state-file> <shared-dir> [--state <name>]", file=sys.stderr)
        return 2
    state_file, shared_dir = positional
    state = json.loads(Path(state_file).read_text(encoding="utf-8"))
    shared_root = Path(shared_dir)
    for m in state.get("members", []):
        if state_filter and m.get("state") != state_filter:
            continue
        brief_rel = m.get("brief_path") or ""
        brief_abs = str(shared_root / brief_rel) if brief_rel else ""
        print(f"{m['member_id']}\t{m.get('track', '')}\t{brief_abs}")
    return 0


def cmd_state_mark_running(args: list[str]) -> int:
    """Atomically transition a wave member from `pending` → `running`.

    Sets state="running" and the four wiring fields (worker / worktree_root /
    branch / task_id) on the member identified by --member-id. Appends a
    `wave_member_queued:<member-id>` audit row and bumps `updated_at`. Atomic
    write via _atomic_write so a partial failure can't leave the JSON
    half-written.

    Args:
      <state-file> --member-id <id> --worker <name> --worktree-root <path>
                   --branch <name> --task-id <int>
    """
    if not args:
        print(
            "usage: state-mark-running <state-file> --member-id <id> "
            "--worker <name> --worktree-root <path> --branch <name> --task-id <int>",
            file=sys.stderr,
        )
        return 2
    state_file = args[0]
    rest = args[1:]

    fields: dict[str, str] = {}
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("--member-id", "--worker", "--worktree-root", "--branch", "--task-id"):
            if i + 1 >= len(rest):
                print(f"missing value for {a}", file=sys.stderr)
                return 2
            fields[a.lstrip("-")] = rest[i + 1]
            i += 2
            continue
        if "=" in a and a.startswith("--"):
            k, v = a[2:].split("=", 1)
            fields[k] = v
            i += 1
            continue
        print(f"unknown arg: {a}", file=sys.stderr)
        return 2

    required = ("member-id", "worker", "worktree-root", "branch", "task-id")
    for r in required:
        if r not in fields:
            print(f"missing required: --{r}", file=sys.stderr)
            return 2

    try:
        task_id = int(fields["task-id"])
    except ValueError:
        print(f"--task-id must be an integer, got: {fields['task-id']!r}", file=sys.stderr)
        return 2

    path = Path(state_file)
    if not path.exists():
        print(f"state file not found: {path}", file=sys.stderr)
        return 1
    state = json.loads(path.read_text(encoding="utf-8"))

    target_id = fields["member-id"]
    matched = None
    for m in state.get("members", []):
        if m["member_id"] == target_id:
            matched = m
            break
    if matched is None:
        print(f"member not found in state: {target_id}", file=sys.stderr)
        return 1

    matched["state"] = "running"
    matched["worker"] = fields["worker"]
    matched["worktree_root"] = fields["worktree-root"]
    matched["branch"] = fields["branch"]
    matched["task_id"] = task_id

    state["updated_at"] = _now_iso()
    audit = state.setdefault("audit", [])
    audit.append(f"wave_member_queued:{target_id}")

    _atomic_write(path, json.dumps(state, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(matched, indent=2, ensure_ascii=False))
    return 0


def cmd_state_render_readme(args: list[str]) -> int:
    if len(args) != 2:
        print("usage: state-render-readme <state-file> <readme-out>", file=sys.stderr)
        return 2
    state = json.loads(Path(args[0]).read_text(encoding="utf-8"))
    out: list[str] = []
    out.append(f"# {state['wave_id']}")
    out.append("")
    out.append(f"- **Issue**: {state.get('issue') or '(no issue, brief-only)'}")
    out.append(f"- **Main agent**: `{state['main_agent']}`")
    out.append(f"- **Worker engine**: `{state['worker_engine']}`")
    out.append(f"- **Reviewer policy**: `{state.get('reviewer_policy', 'codex-rescue')}`")
    out.append(f"- **Created**: {state['created_at']}")
    out.append(f"- **Tracks**: {', '.join(state['tracks'])}")
    out.append("")
    out.append("## Members")
    out.append("")
    out.append("| member id | track | state | PR | branch | task | brief |")
    out.append("|---|---|---|---|---|---|---|")
    for m in state["members"]:
        out.append(
            "| `{member_id}` | {track} | `{state}` | {pr} | {branch} | {task} | {brief} |".format(
                member_id=m["member_id"],
                track=m["track"],
                state=m["state"],
                pr=m.get("pr_url") or "—",
                branch=f"`{m['branch']}`" if m.get("branch") else "—",
                task=m.get("task_id") or "—",
                brief=f"[brief]({m['brief_path']})" if m.get("brief_path") else "—",
            )
        )
    out.append("")
    out.append("## Audit")
    out.append("")
    for a in state.get("audit", []):
        out.append(f"- {a}")
    out.append("")
    out.append("> Auto-generated from `state/waves/<wave-id>.json`. Single source of truth is the JSON.")
    out.append("")
    _atomic_write(Path(args[1]), "\n".join(out))
    return 0


# Close-keyword regex matches GitHub's parser:
# https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue
# (close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved) #<num>
_CLOSE_KEYWORD = re.compile(
    r"(?i)\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)\s+#\d+"
)


def cmd_state_show_pretty(args: list[str]) -> int:
    if len(args) != 1:
        print("usage: state-show-pretty <state-file>", file=sys.stderr)
        return 2
    s = json.loads(Path(args[0]).read_text(encoding="utf-8"))
    print(f"wave: {s['wave_id']}")
    print(f"  issue:        {s.get('issue') or '(brief-only)'}")
    print(f"  brief source: {s.get('brief_source')}")
    print(f"  main agent:   {s['main_agent']}")
    print(f"  worker:       {s['worker_engine']}")
    print(f"  reviewer:     {s.get('reviewer_policy', '-')}")
    print(f"  tracks:       {', '.join(s['tracks'])}")
    print(f"  created:      {s['created_at']}")
    print(f"  updated:      {s['updated_at']}")
    print()
    print("members:")
    for m in s["members"]:
        print(
            f"  {m['member_id']}  track={m['track']}  state={m['state']}  "
            f"pr={m.get('pr_url') or '-'}  branch={m.get('branch') or '-'}"
        )
    print()
    print(f"audit: {', '.join(s.get('audit', []))}")
    return 0


def cmd_state_list_pretty(args: list[str]) -> int:
    if len(args) != 1:
        print("usage: state-list-pretty <state-dir>", file=sys.stderr)
        return 2
    state_dir = Path(args[0])
    print(f"{'wave id':<48}  {'issue':<8}  {'main agent':<22}  {'members':<7}  states")
    print(f"{'-' * 48}  {'-' * 8}  {'-' * 22}  {'-' * 7}  {'-' * 30}")
    if not state_dir.is_dir():
        return 0
    for f in sorted(state_dir.glob("*.json")):
        try:
            s = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        member_states: dict[str, int] = {}
        for m in s.get("members", []):
            member_states[m["state"]] = member_states.get(m["state"], 0) + 1
        states_str = " ".join(f"{k}={v}" for k, v in member_states.items()) or "-"
        wid = s.get("wave_id") or ""
        iss = str(s.get("issue") or "-")[:8]
        ma = str(s.get("main_agent") or "-")[:22]
        n = sum(member_states.values())
        print(f"{wid:<48}  {iss:<8}  {ma:<22}  {n:<7}  {states_str}")
    return 0


def cmd_close_keyword_scan(args: list[str]) -> int:
    if not args:
        print("usage: close-keyword-scan <file>...", file=sys.stderr)
        return 2
    hits: list[tuple[str, int, str]] = []
    for f in args:
        path = Path(f)
        if not path.exists():
            continue
        for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            for m in _CLOSE_KEYWORD.finditer(line):
                hits.append((f, i, m.group(0)))
    if hits:
        print(json.dumps({"close_keyword_hits": [
            {"file": h[0], "line": h[1], "match": h[2]} for h in hits
        ]}, indent=2))
        return 1
    print(json.dumps({"close_keyword_hits": []}, indent=2))
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    sub = argv[0]
    rest = argv[1:]
    handlers = {
        "wave-id-generate": cmd_wave_id_generate,
        "member-id-generate": cmd_member_id_generate,
        "state-init": cmd_state_init,
        "state-show": cmd_state_show,
        "state-list": cmd_state_list,
        "state-list-members": cmd_state_list_members,
        "state-mark-running": cmd_state_mark_running,
        "state-render-readme": cmd_state_render_readme,
        "state-show-pretty": cmd_state_show_pretty,
        "state-list-pretty": cmd_state_list_pretty,
        "close-keyword-scan": cmd_close_keyword_scan,
    }
    fn = handlers.get(sub)
    if fn is None:
        print(f"unknown subcommand: {sub}", file=sys.stderr)
        return 2
    return fn(rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
