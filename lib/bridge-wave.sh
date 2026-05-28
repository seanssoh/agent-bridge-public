#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/bridge-wave.sh — `agent-bridge wave` orchestration helpers.
#
# Phase 1.1 scope: dispatch (state + brief), list, show, templates,
# close-issue (placeholder). Worker startup, queue task creation, codex
# adapter, PR automation, main-agent feedback, policy loading, skill
# migration, and close-issue validation belong to Phases 1.2 - 1.6
# (see docs/design/wave-orchestration-plugin.md).
#
# Storage layout (per design §10):
#   $BRIDGE_STATE_DIR/waves/<wave-id>.json   — JSON SSOT
#   $BRIDGE_SHARED_DIR/waves/<wave-id>/      — briefs + README mirror
#     ├── README.md                          — auto-generated from JSON
#     └── <member-id>/brief.md               — per-member brief

bridge_wave_state_dir() {
  printf '%s/waves' "${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}"
}

bridge_wave_shared_dir() {
  printf '%s/waves' "${BRIDGE_SHARED_DIR:-$BRIDGE_HOME/shared}"
}

bridge_wave_python_helper() {
  printf '%s/bridge-wave.py' "$BRIDGE_SCRIPT_DIR"
}

bridge_wave_default_main_agent() {
  if [[ -n "${BRIDGE_AGENT_ID:-}" ]]; then
    printf '%s' "$BRIDGE_AGENT_ID"
    return 0
  fi
  if [[ -n "${BRIDGE_ADMIN_AGENT_ID:-}" ]]; then
    printf '%s' "$BRIDGE_ADMIN_AGENT_ID"
    return 0
  fi
  return 1
}

bridge_wave_close_keyword_lint() {
  # Block close-keyword (closes/fixes/resolves #N) in any of the given
  # files. Mechanical lint per design §5: the wave plugin never writes
  # close keywords; closing is gated through `wave close-issue`.
  local helper
  helper="$(bridge_wave_python_helper)"
  if [[ ! -x "$helper" && ! -r "$helper" ]]; then
    bridge_warn "wave_close_keyword_lint: bridge-wave.py not found at $helper"
    return 0
  fi
  python3 "$helper" close-keyword-scan "$@" >/dev/null
}

bridge_wave_dispatch() {
  local issue_or_brief=""
  local tracks=""
  local main_agent=""
  local worker_engine="claude"
  local reviewer="codex-rescue"
  local repo_root=""
  local dry_run=0
  local json_out=0

  while (( $# > 0 )); do
    case "$1" in
      --tracks)         tracks="${2:-}"; shift 2 ;;
      --tracks=*)       tracks="${1#--tracks=}"; shift ;;
      --main-agent)     main_agent="${2:-}"; shift 2 ;;
      --main-agent=*)   main_agent="${1#--main-agent=}"; shift ;;
      --worker-engine)  worker_engine="${2:-}"; shift 2 ;;
      --worker-engine=*) worker_engine="${1#--worker-engine=}"; shift ;;
      --reviewer)       reviewer="${2:-}"; shift 2 ;;
      --reviewer=*)     reviewer="${1#--reviewer=}"; shift ;;
      --repo-root)      repo_root="${2:-}"; shift 2 ;;
      --repo-root=*)    repo_root="${1#--repo-root=}"; shift ;;
      --dry-run)        dry_run=1; shift ;;
      --json)           json_out=1; shift ;;
      -h|--help)
        cat <<EOF
agent-bridge wave dispatch <issue-or-brief> [--tracks A,B] [--main-agent <agent>] [--worker-engine claude|codex] [--reviewer <name>] [--repo-root <dir>] [--dry-run] [--json]
EOF
        return 0
        ;;
      --) shift; break ;;
      -*) bridge_die "wave dispatch: unknown option: $1" ;;
      *)
        if [[ -z "$issue_or_brief" ]]; then
          issue_or_brief="$1"
        else
          bridge_die "wave dispatch: extra positional arg: $1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$issue_or_brief" ]]; then
    bridge_die "wave dispatch: issue number or brief file required"
  fi

  if [[ -z "$main_agent" ]]; then
    if ! main_agent="$(bridge_wave_default_main_agent)"; then
      bridge_die "wave dispatch: --main-agent required (BRIDGE_AGENT_ID and BRIDGE_ADMIN_AGENT_ID both unset)"
    fi
  fi

  if [[ "$worker_engine" != "claude" && "$worker_engine" != "codex" ]]; then
    bridge_die "wave dispatch: --worker-engine must be claude or codex (got: $worker_engine)"
  fi

  local helper
  helper="$(bridge_wave_python_helper)"
  [[ -r "$helper" ]] || bridge_die "wave dispatch: bridge-wave.py missing at $helper"

  local wave_id
  wave_id="$(python3 "$helper" wave-id-generate "$issue_or_brief")" \
    || bridge_die "wave dispatch: wave-id-generate failed"

  local state_dir shared_dir state_file shared_wave_dir
  state_dir="$(bridge_wave_state_dir)"
  shared_dir="$(bridge_wave_shared_dir)"
  state_file="$state_dir/${wave_id}.json"
  shared_wave_dir="$shared_dir/$wave_id"

  if (( dry_run )); then
    cat <<EOF
[dry-run] would create wave: $wave_id
  state file: $state_file
  shared dir: $shared_wave_dir
  source:     $issue_or_brief
  main agent: $main_agent
  worker:     $worker_engine
  reviewer:   $reviewer
  tracks:     ${tracks:-(none — single member)}
  repo root:  ${repo_root:-(pwd at runtime)}
EOF
    return 0
  fi

  mkdir -p "$state_dir" "$shared_wave_dir"

  local brief_relpath=""
  if [[ -f "$issue_or_brief" && ! "$issue_or_brief" =~ ^[0-9]+$ ]]; then
    brief_relpath="waves/$wave_id/source-brief.md"
    cp "$issue_or_brief" "$shared_dir/$wave_id/source-brief.md"
  fi

  python3 "$helper" state-init \
    "$wave_id" \
    "$issue_or_brief" \
    "$main_agent" \
    "$worker_engine" \
    "$reviewer" \
    "$tracks" \
    "$state_file" \
    "$brief_relpath" \
    >/dev/null \
    || bridge_die "wave dispatch: state-init failed"

  local member_dir member_id member_brief track
  if [[ -n "$tracks" ]]; then
    while IFS=',' read -ra _tracks; do
      for track in "${_tracks[@]}"; do
        track="${track//[[:space:]]/}"
        [[ -n "$track" ]] || continue
        member_id="$(_bridge_wave_member_id_for_track "$state_file" "$track")"
        member_dir="$shared_wave_dir/$member_id"
        member_brief="$member_dir/brief.md"
        mkdir -p "$member_dir"
        _bridge_wave_emit_member_brief \
          "$wave_id" "$member_id" "$track" "$issue_or_brief" \
          "$main_agent" "$worker_engine" "$reviewer" \
          > "$member_brief"
      done
    done <<< "$tracks"
  else
    member_id="$(_bridge_wave_member_id_for_track "$state_file" "main")"
    member_dir="$shared_wave_dir/$member_id"
    member_brief="$member_dir/brief.md"
    mkdir -p "$member_dir"
    _bridge_wave_emit_member_brief \
      "$wave_id" "$member_id" "main" "$issue_or_brief" \
      "$main_agent" "$worker_engine" "$reviewer" \
      > "$member_brief"
  fi

  python3 "$helper" state-render-readme "$state_file" "$shared_wave_dir/README.md" \
    || bridge_warn "wave dispatch: README render failed (non-fatal)"

  # Phase 1.2: per-member worker spawn + queue task. Each pending member
  # gets an isolated worktree (--prefer new), a high-priority queue task
  # whose body is the member brief, and a state JSON transition to
  # `running`. A failure on one member is logged and skipped — remaining
  # members continue. Phase 1.3+ will layer codex plan/review and PR
  # automation on top of this handoff.
  local _repo_root="$repo_root"
  if [[ -z "$_repo_root" ]]; then
    _repo_root="$(pwd -P)"
  fi
  if [[ ! -d "$_repo_root/.git" ]] && ! git -C "$_repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    bridge_warn "wave dispatch: repo-root is not a git project ($_repo_root); workers cannot create isolated worktrees. Skipping Phase 1.2 spawn — members stay pending."
  else
    _repo_root="$(git -C "$_repo_root" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$_repo_root")"
    local _member_id _track _brief_abs
    local _spawned=0 _failed=0
    while IFS=$'\t' read -r _member_id _track _brief_abs; do
      [[ -n "$_member_id" ]] || continue
      if _bridge_wave_dispatch_member \
        "$wave_id" "$_member_id" "$_track" \
        "$main_agent" "$worker_engine" "$_repo_root" \
        "$_brief_abs" "$state_file"; then
        _spawned=$(( _spawned + 1 ))
      else
        _failed=$(( _failed + 1 ))
        bridge_warn "wave dispatch: member $_member_id failed to spawn (continuing)"
      fi
    done < <(python3 "$helper" state-list-members "$state_file" "$shared_dir" --state pending)

    # Re-render README so member rows reflect the new running state.
    python3 "$helper" state-render-readme "$state_file" "$shared_wave_dir/README.md" \
      || bridge_warn "wave dispatch: README re-render after dispatch failed (non-fatal)"
    if (( _failed > 0 )); then
      bridge_warn "wave dispatch: $_failed member(s) failed to spawn; $_spawned succeeded"
    fi
  fi

  if (( json_out )); then
    python3 "$helper" state-show "$state_file"
  else
    printf 'wave dispatched: %s\n' "$wave_id"
    printf 'state: %s\n' "$state_file"
    printf 'briefs: %s/<member-id>/brief.md\n' "$shared_wave_dir"
    printf 'workers: %s\n' "$_repo_root"
  fi
}

_bridge_wave_dispatch_member() {
  # Phase 1.2 per-member dispatch: spawn an isolated worker via
  # `agent-bridge --<engine> --prefer new --no-attach`, look up the
  # WORKTREE_ROOT/BRANCH metadata the dispatcher writes, create a queue
  # task whose body is the member brief, and atomically transition the
  # state JSON to `running` with all four wiring fields (worker,
  # worktree_root, branch, task_id). A `wave_member_queued` audit row is
  # emitted on success.
  #
  # Args (positional, all required):
  #   1: wave_id
  #   2: member_id (also used as the worker agent name; one-to-one)
  #   3: track
  #   4: main_agent
  #   5: worker_engine (claude|codex)
  #   6: repo_root (absolute path to the source repo)
  #   7: brief_abs_path
  #   8: state_file
  local wave_id="$1"
  local member_id="$2"
  local track="$3"
  local main_agent="$4"
  local worker_engine="$5"
  local repo_root="$6"
  local brief_path="$7"
  local state_file="$8"

  local worker_name="$member_id"
  if ! bridge_validate_agent_name "$worker_name"; then
    bridge_warn "wave dispatch: member $member_id resolves to invalid worker name ($worker_name); skipping"
    return 1
  fi

  local spawn_log
  spawn_log="$(mktemp "${TMPDIR:-/tmp}/wave-spawn-${member_id}.XXXXXX")"

  local ab_bin="$BRIDGE_SCRIPT_DIR/agent-bridge"
  if [[ ! -x "$ab_bin" ]]; then
    bridge_warn "wave dispatch: agent-bridge dispatcher not executable: $ab_bin"
    rm -f "$spawn_log"
    return 1
  fi

  # 1. Spawn the worker. --prefer new builds an isolated worktree under
  #    BRIDGE_WORKTREE_ROOT and records metadata under state/worktrees/.
  if ! "$BRIDGE_BASH_BIN" "$ab_bin" \
        "--${worker_engine}" \
        --name "$worker_name" \
        --workdir "$repo_root" \
        --prefer new \
        --no-attach \
        >"$spawn_log" 2>&1; then
    bridge_warn "wave dispatch: worker spawn failed for $member_id (engine=$worker_engine, see $spawn_log)"
    return 1
  fi

  # 2. Resolve the worktree metadata the dispatcher just wrote.
  local meta_file
  meta_file="$(bridge_worktree_meta_file_for "$repo_root" "$worker_name")"
  if [[ ! -r "$meta_file" ]]; then
    bridge_warn "wave dispatch: worktree metadata missing for $worker_name at $meta_file"
    return 1
  fi

  # Source in a subshell so the dispatcher's metadata vars don't leak
  # into the caller; capture the two we care about via printf.
  local meta_payload worktree_root branch
  # shellcheck disable=SC1090
  meta_payload="$(set +u; source "$meta_file"; printf '%s\t%s\n' "${WORKTREE_ROOT:-}" "${WORKTREE_BRANCH:-}")"
  IFS=$'\t' read -r worktree_root branch <<<"$meta_payload"
  if [[ -z "$worktree_root" || -z "$branch" ]]; then
    bridge_warn "wave dispatch: worktree metadata missing WORKTREE_ROOT/WORKTREE_BRANCH for $worker_name (file: $meta_file)"
    return 1
  fi

  # 3. Create the queue task assigned to the new worker. Body = brief.
  if [[ ! -r "$brief_path" ]]; then
    bridge_warn "wave dispatch: brief not readable for $member_id at $brief_path"
    return 1
  fi
  local task_create_out task_id
  # Issue #1318 part A (v0.14.5-beta5-2 Lane ξ): a freshly-spawned wave
  # worker may not yet be reported as active by bridge_agent_is_active
  # (tmux session-existence probe — there is a brief race between the
  # spawn call above and the tmux registry settling). Use --force so the
  # task lands even if the active-state probe misses; the worker
  # consumes the queued task on its first dequeue tick.
  if ! task_create_out="$("$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-task.sh" create \
        --to "$worker_name" \
        --from "$main_agent" \
        --priority high \
        --title "[wave $wave_id track $track] $member_id" \
        --body-file "$brief_path" \
        --force 2>&1)"; then
    # codex r1 item 3 (atomicity): the worker was spawned successfully but
    # queue-task creation failed. Hard-killing the tmux session from here
    # would race with the operator's own attach, so we leave the worker
    # alive and emit a `wave_member_dispatch_partial` audit row so the
    # leak is observable and the operator can clean it up manually
    # (`agent-bridge worktree remove <worker>` + tmux kill-session).
    bridge_warn "wave dispatch: queue task create failed for $member_id: $task_create_out"
    bridge_audit_log wave-orchestration wave_member_dispatch_partial "$main_agent" \
      --detail wave_id="$wave_id" \
      --detail member_id="$member_id" \
      --detail track="$track" \
      --detail worker="$worker_name" \
      --detail worktree_root="$worktree_root" \
      --detail branch="$branch" \
      --detail stage="queue_task_create" \
      --detail error="$task_create_out" \
      || true
    return 1
  fi
  if [[ "$task_create_out" =~ created\ task\ \#([0-9]+) ]]; then
    task_id="${BASH_REMATCH[1]}"
  else
    bridge_warn "wave dispatch: could not parse task id from create output: $task_create_out"
    bridge_audit_log wave-orchestration wave_member_dispatch_partial "$main_agent" \
      --detail wave_id="$wave_id" \
      --detail member_id="$member_id" \
      --detail track="$track" \
      --detail worker="$worker_name" \
      --detail worktree_root="$worktree_root" \
      --detail branch="$branch" \
      --detail stage="task_id_parse" \
      --detail error="$task_create_out" \
      || true
    return 1
  fi

  # 4. Detailed bridge_audit_log BEFORE state-mark-running write
  #    (codex r1 item 5). The contract is: audit is written first, the
  #    state file is the durable record of the transition. If the audit
  #    write fails (`|| true`) we still proceed with the state mutation;
  #    if the state write fails we attempt to roll the queue task back
  #    and emit a `_rollback` audit row so the partial state is
  #    observable.
  bridge_audit_log wave-orchestration wave_member_queued "$main_agent" \
    --detail wave_id="$wave_id" \
    --detail member_id="$member_id" \
    --detail track="$track" \
    --detail worker="$worker_name" \
    --detail worktree_root="$worktree_root" \
    --detail branch="$branch" \
    --detail task_id="$task_id" \
    || true

  # 5. Atomic state transition pending -> running.
  local mr_rc=0
  python3 "$(bridge_wave_python_helper)" state-mark-running \
      "$state_file" \
      --member-id "$member_id" \
      --worker "$worker_name" \
      --worktree-root "$worktree_root" \
      --branch "$branch" \
      --task-id "$task_id" >/dev/null || mr_rc=$?
  if (( mr_rc == 3 )); then
    # codex r1 items 4 + 10: the member is already advanced past pending
    # (e.g. a prior dispatch round handled it). Treat as a no-op skip:
    # close the duplicate queue task we just opened so the worker isn't
    # double-assigned, and consider the dispatch successful for this
    # member.
    bridge_warn "wave dispatch: member $member_id already advanced past 'pending'; skipping (rc=3)"
    "$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-task.sh" done "$task_id" \
      --agent "$worker_name" \
      --note "wave dispatch skipped: member already advanced past pending" \
      >/dev/null 2>&1 || bridge_warn "wave dispatch: could not close duplicate task #$task_id (member $member_id)"
    rm -f "$spawn_log"
    return 0
  fi
  if (( mr_rc != 0 )); then
    # codex r1 item 3 (atomicity rollback): queue task succeeded but the
    # state-mark-running write failed. Best-effort close the queue task
    # so the worker doesn't pick up an orphaned brief, then emit a
    # `wave_member_dispatch_rollback` audit row.
    bridge_warn "wave dispatch: state-mark-running failed for $member_id (rc=$mr_rc); attempting queue-task rollback"
    local rollback_out=""
    if ! rollback_out="$("$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-task.sh" done "$task_id" \
          --agent "$worker_name" \
          --note "wave dispatch state-mark-running failed; rolled back" 2>&1)"; then
      bridge_warn "wave dispatch: rollback close of task #$task_id failed: $rollback_out (member $member_id)"
    fi
    bridge_audit_log wave-orchestration wave_member_dispatch_rollback "$main_agent" \
      --detail wave_id="$wave_id" \
      --detail member_id="$member_id" \
      --detail track="$track" \
      --detail worker="$worker_name" \
      --detail worktree_root="$worktree_root" \
      --detail branch="$branch" \
      --detail task_id="$task_id" \
      --detail stage="state_mark_running" \
      --detail mr_rc="$mr_rc" \
      || true
    return 1
  fi

  # 6. Console row (per design §10). Audit was emitted in step 4.
  printf '  %s -> worker=%s task=#%s worktree=%s\n' \
    "$member_id" "$worker_name" "$task_id" "$worktree_root"

  rm -f "$spawn_log"
  return 0
}

_bridge_wave_member_id_for_track() {
  # Read the member id for a given track from the state file. Used after
  # state-init has written the wave so we don't regenerate ids.
  local state_file="$1" track="$2"
  python3 -c '
import json, sys
state = json.loads(open(sys.argv[1]).read())
for m in state["members"]:
    if m["track"] == sys.argv[2]:
        print(m["member_id"]); break
' "$state_file" "$track"
}

_bridge_wave_emit_member_brief() {
  # Emit a generic brief skeleton per member. Phase 1.1 ships a minimal
  # template; Phase 1.2+ will expand to the 11-section shape from
  # references/brief-template.md once we land that asset.
  local wave_id="$1" member_id="$2" track="$3" issue_or_brief="$4"
  local main_agent="$5" worker_engine="$6" reviewer="$7"

  cat <<EOF
# Wave member brief — ${wave_id} / track ${track}

> Auto-generated by \`agent-bridge wave dispatch\` (Phase 1.1 skeleton).
> Operator should expand sections 3-7 below before Phase 1.2 dispatches a
> worker against this brief.

- **Wave id**: \`${wave_id}\`
- **Member id**: \`${member_id}\`
- **Track**: \`${track}\`
- **Source**: \`${issue_or_brief}\`
- **Main agent**: \`${main_agent}\`
- **Worker engine**: \`${worker_engine}\`
- **Reviewer policy**: \`${reviewer}\`

## 1. Repo / branch / scope

- Branch: \`fix/${track,,}-...\` or \`feat/${track,,}-...\` (operator to fill)

## 2. Read first (do not skip)

- Operator: enumerate files + commands the worker must inspect before editing.

## 3. What to change

- Per-file recipe.

## 4. Out of scope

- Items the worker MUST NOT touch.

## 5. Verification

\`\`\`bash
PATH="/opt/homebrew/bin:\$PATH"
bash -n <files>
shellcheck <files>
\`\`\`

## 6. CI status

- Pre-existing failures the worker should not chase.

## 7. PR opening

- Title format: \`<type>: <subject> (#${issue_or_brief//[!0-9]/} Track ${track})\`
- Body: Summary, Changes, Verification, Related, Out of scope.

## 8. CRITICAL — close-keyword footgun

**Do NOT use \`closes #N\`, \`fixes #N\`, \`resolves #N\` in the PR title, body, or commit subject.**
Use \`(#N Track ${track})\` for citation. Issue close is gated through \`agent-bridge wave close-issue\`.

## 9. Stop point

Stop after PR open. Return JSON.

## 10. Reminders

- Worktree-relative paths only.
- Single commit per member.
- No VERSION/CHANGELOG bumps.

## 11. Output JSON

\`\`\`json
{
  "branch": "<head-branch>",
  "pr_number": <int>,
  "pr_url": "<url>",
  "files_touched": [],
  "loc_added": 0,
  "loc_deleted": 0,
  "verification": {
    "bash_n": "pass|fail",
    "shellcheck": "pass|fail"
  }
}
\`\`\`
EOF
}

bridge_wave_list() {
  local json_out=0
  local include_all=0
  while (( $# > 0 )); do
    case "$1" in
      --json) json_out=1; shift ;;
      --all)  include_all=1; shift ;;
      -h|--help) printf 'agent-bridge wave list [--all] [--json]\n'; return 0 ;;
      *) bridge_die "wave list: unknown arg: $1" ;;
    esac
  done

  local state_dir
  state_dir="$(bridge_wave_state_dir)"

  local helper
  helper="$(bridge_wave_python_helper)"
  [[ -r "$helper" ]] || bridge_die "wave list: bridge-wave.py missing at $helper"

  if (( json_out )); then
    python3 "$helper" state-list "$state_dir"
    return 0
  fi

  if [[ ! -d "$state_dir" ]]; then
    printf 'no waves dispatched yet. state dir: %s\n' "$state_dir"
    return 0
  fi

  python3 "$helper" state-list-pretty "$state_dir"
}

bridge_wave_show() {
  local wave_id="" json_out=0
  while (( $# > 0 )); do
    case "$1" in
      --json) json_out=1; shift ;;
      -h|--help) printf 'agent-bridge wave show <wave-id> [--json]\n'; return 0 ;;
      -*) bridge_die "wave show: unknown option: $1" ;;
      *)
        if [[ -z "$wave_id" ]]; then
          wave_id="$1"
        else
          bridge_die "wave show: extra positional arg: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$wave_id" ]] || bridge_die "wave show: <wave-id> required"

  local state_dir state_file
  state_dir="$(bridge_wave_state_dir)"
  state_file="$state_dir/${wave_id}.json"
  [[ -r "$state_file" ]] || bridge_die "wave show: state file not found: $state_file"

  local helper
  helper="$(bridge_wave_python_helper)"

  if (( json_out )); then
    python3 "$helper" state-show "$state_file"
    return 0
  fi

  python3 "$helper" state-show-pretty "$state_file"
}

bridge_wave_templates() {
  cat <<EOF
Available brief templates (Phase 1.1 ships a single skeleton):

  default     — auto-generated 11-section skeleton (operator fills sections 3-7)

Phase 1.2+ will expand the catalog with templates derived from
references/brief-template.md (issue-fixer, doc-only, release-bump, etc).
EOF
}

bridge_wave_close_issue() {
  local issue="" wave_id="" force=0
  while (( $# > 0 )); do
    case "$1" in
      --wave)  wave_id="${2:-}"; shift 2 ;;
      --wave=*) wave_id="${1#--wave=}"; shift ;;
      --force) force=1; shift ;;
      -h|--help) printf 'agent-bridge wave close-issue <issue> [--wave <wave-id>] [--force]\n'; return 0 ;;
      -*) bridge_die "wave close-issue: unknown option: $1" ;;
      *)
        if [[ -z "$issue" ]]; then
          issue="$1"
        else
          bridge_die "wave close-issue: extra positional arg: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$issue" ]] || bridge_die "wave close-issue: <issue> required"

  if (( force )); then
    bridge_warn "wave close-issue: --force is operator-only and reserved for Phase 1.6 implementation."
  fi

  cat >&2 <<EOF
wave close-issue is implemented in Phase 1.6 (per design §11).
For Phase 1.1 this command is a placeholder. Validation logic (every
wave member tagged \`issue=#${issue}\` is MERGED, every dispatched track
has a merged member, no recent codex needs-more) is not yet wired.

Operator flow until Phase 1.6:
  1. Verify all wave member PRs are merged.
  2. Run \`gh issue comment ${issue} --body ...\` to summarize.
  3. Run \`gh issue close ${issue}\` after live verification (if applicable).

(Wave context: $wave_id)
EOF
  return 64  # EX_USAGE-style — operator must do it manually for now.
}
