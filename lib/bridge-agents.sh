#!/usr/bin/env bash
# shellcheck shell=bash

bridge_agent_project_root() {
  local agent="$1"
  bridge_project_root_for_path "$(bridge_agent_workdir "$agent")"
}

bridge_history_file_for_agent() {
  local agent="$1"
  bridge_history_file_for "$(bridge_agent_engine "$agent")" "$agent" "$(bridge_agent_workdir "$agent")"
}

bridge_agent_history_exists() {
  local agent="$1"
  local file

  file="$(bridge_history_file_for_agent "$agent")"
  [[ -f "$file" ]]
}

bridge_worktree_slug_for_project() {
  local project_root="$1"
  local base
  local hash

  base="$(basename "$project_root")"
  base="${base//[^A-Za-z0-9._-]/-}"
  hash="$(bridge_sha1 "$project_root")"
  printf '%s-%s' "$base" "${hash:0:8}"
}

bridge_worktree_branch_for_agent() {
  local agent="$1"
  local branch

  branch="$agent"
  branch="${branch//[^A-Za-z0-9._-]/-}"
  printf 'agent-bridge/%s' "$branch"
}

bridge_worktree_root_for() {
  local project_root="$1"
  local agent="$2"
  local slug

  slug="$(bridge_worktree_slug_for_project "$project_root")"
  printf '%s/%s/%s' "$BRIDGE_WORKTREE_ROOT" "$slug" "$agent"
}

bridge_worktree_launch_dir_for() {
  local source_workdir="$1"
  local agent="$2"
  local project_root relpath worktree_root

  project_root="$(bridge_project_root_for_path "$source_workdir")"
  relpath="$(bridge_path_relative_to_root "$source_workdir" "$project_root")"
  worktree_root="$(bridge_worktree_root_for "$project_root" "$agent")"

  if [[ "$relpath" == "." ]]; then
    printf '%s' "$worktree_root"
  else
    printf '%s/%s' "$worktree_root" "$relpath"
  fi
}

bridge_worktree_meta_key() {
  local project_root="$1"
  local agent="$2"
  bridge_sha1 "${project_root}|${agent}"
}

bridge_worktree_meta_file_for() {
  local project_root="$1"
  local agent="$2"
  local key

  key="$(bridge_worktree_meta_key "$project_root" "$agent")"
  printf '%s/%s--%s.env' "$BRIDGE_WORKTREE_META_DIR" "$agent" "${key:0:12}"
}

bridge_write_worktree_metadata() {
  local engine="$1"
  local agent="$2"
  local source_workdir="$3"
  local project_root="$4"
  local worktree_root="$5"
  local worktree_workdir="$6"
  local branch="$7"
  local meta_file
  local relpath
  local created_at
  local updated_at

  meta_file="$(bridge_worktree_meta_file_for "$project_root" "$agent")"
  relpath="$(bridge_path_relative_to_root "$source_workdir" "$project_root")"
  created_at="$(date +%s)"
  updated_at="$(bridge_now_iso)"

  mkdir -p "$(dirname "$meta_file")"
  cat >"$meta_file" <<EOF
WORKTREE_AGENT=$(printf '%q' "$agent")
WORKTREE_ENGINE=$(printf '%q' "$engine")
WORKTREE_SOURCE_WORKDIR=$(printf '%q' "$source_workdir")
WORKTREE_PROJECT_ROOT=$(printf '%q' "$project_root")
WORKTREE_RELATIVE_DIR=$(printf '%q' "$relpath")
WORKTREE_ROOT=$(printf '%q' "$worktree_root")
WORKTREE_WORKDIR=$(printf '%q' "$worktree_workdir")
WORKTREE_BRANCH=$(printf '%q' "$branch")
WORKTREE_CREATED_AT=$(printf '%q' "$created_at")
WORKTREE_UPDATED_AT=$(printf '%q' "$updated_at")
EOF
}

bridge_list_worktrees() {
  local file
  local WORKTREE_AGENT=""
  local WORKTREE_ENGINE=""
  local WORKTREE_PROJECT_ROOT=""
  local WORKTREE_ROOT=""
  local WORKTREE_WORKDIR=""
  local WORKTREE_BRANCH=""
  local active
  local printed=0

  shopt -s nullglob
  for file in "$BRIDGE_WORKTREE_META_DIR"/*.env; do
    WORKTREE_AGENT=""
    WORKTREE_ENGINE=""
    WORKTREE_PROJECT_ROOT=""
    WORKTREE_ROOT=""
    WORKTREE_WORKDIR=""
    WORKTREE_BRANCH=""
    # shellcheck source=/dev/null
    source "$file"
    [[ -z "$WORKTREE_AGENT" ]] && continue
    printed=1
    active="no"
    if bridge_agent_exists "$WORKTREE_AGENT" && bridge_agent_is_active "$WORKTREE_AGENT"; then
      active="yes"
    fi
    printf '%s | engine=%s | active=%s | branch=%s | repo=%s | root=%s | workdir=%s\n' \
      "$WORKTREE_AGENT" \
      "${WORKTREE_ENGINE:-unknown}" \
      "$active" \
      "${WORKTREE_BRANCH:--}" \
      "${WORKTREE_PROJECT_ROOT:--}" \
      "${WORKTREE_ROOT:--}" \
      "${WORKTREE_WORKDIR:--}"
  done
  shopt -u nullglob

  if [[ "$printed" == "0" ]]; then
    echo "(등록된 agent-bridge worktree 없음)"
  fi
}

# bridge_worktree_doctor — reap stale .claude/worktrees/<agent-*|ab-*> worktrees.
#
# Scans `git worktree list --porcelain` from the current repo and classifies each
# fixer-style worktree (matching the `.claude/worktrees/agent-*` or
# `.claude/worktrees/ab-*` pattern) into one of:
#
#   REMOVE  — branch is merged into the target branch (default `main`) AND the
#             worktree has no stash entries.
#   STALE   — branch is NOT merged but its last commit is older than
#             --max-age-days (default 14). Reported but only removed under
#             --apply --include-stale (operator opts in twice).
#   SKIP    — worktree has 1+ stash entries. Refuse to touch (shared
#             .git/refs/stash means popping in the wrong worktree can pull
#             another lane's WIP — see feedback_worktree_stash_shared_git_dir).
#   KEEP    — branch unmerged AND last commit is recent. Untouched.
#
# Default is --dry-run: prints the classification table and would-be actions.
# --apply actually runs `git worktree remove -f <path>`. --prune-branches also
# deletes the local branch ref via `git branch -D` once the worktree is gone.
#
# Stash safety is checked ONCE at the repo level (`git -C <repo_root> stash list`)
# BEFORE the per-worktree classification loop. Because all worktrees in a repo
# share refs/stash, any stash entry anywhere blocks all removal — the doctor
# refuses to touch any worktree until the operator handles the stashes first.
# Doing the check at repo-level (rather than per-worktree) is load-bearing: a
# porcelain-listed worktree whose directory is missing on disk would otherwise
# read stash_count=0 and fall through to REMOVE, silently bypassing the policy.
#
# Args: doctor [--dry-run] [--apply] [--max-age-days N] [--target-branch ref]
#              [--include-stale] [--prune-branches] [--repo PATH]
bridge_worktree_doctor() {
  local mode="dry-run"
  local max_age_days=14
  local target_branch="main"
  local include_stale=0
  local prune_branches=0
  local repo_root=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        mode="dry-run"
        shift
        ;;
      --apply)
        mode="apply"
        shift
        ;;
      --max-age-days)
        [[ $# -lt 2 ]] && bridge_die "--max-age-days 뒤에 숫자를 지정하세요."
        if [[ ! "$2" =~ ^[0-9]+$ ]]; then
          bridge_die "--max-age-days 값은 정수여야 합니다: $2"
        fi
        max_age_days="$2"
        shift 2
        ;;
      --target-branch)
        [[ $# -lt 2 ]] && bridge_die "--target-branch 뒤에 ref 이름을 지정하세요."
        target_branch="$2"
        shift 2
        ;;
      --include-stale)
        include_stale=1
        shift
        ;;
      --prune-branches)
        prune_branches=1
        shift
        ;;
      --repo)
        [[ $# -lt 2 ]] && bridge_die "--repo 뒤에 경로를 지정하세요."
        repo_root="$2"
        shift 2
        ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  agent-bridge worktree doctor [--dry-run|--apply]
                               [--max-age-days N] [--target-branch ref]
                               [--include-stale] [--prune-branches]
                               [--repo PATH]

Reap stale .claude/worktrees/(agent-*|ab-*) worktrees safely.

  --dry-run         (default) print classification + intended actions only
  --apply           actually run `git worktree remove -f` on REMOVE rows
  --max-age-days N  STALE threshold for unmerged branches (default: 14)
  --target-branch R branch to test "merged into" against (default: main)
  --include-stale   also remove STALE rows under --apply (operator opts in)
  --prune-branches  also delete the local branch ref via `git branch -D`
  --repo PATH       repo root to inspect (default: current working directory)

Stash safety: any worktree with `git stash list` non-empty is SKIPped — the
shared refs/stash store across worktrees means removing one can orphan stash
refs that another lane might pop and inadvertently mix in WIP.
USAGE
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 doctor 옵션입니다: $1"
        ;;
    esac
  done

  if [[ -z "$repo_root" ]]; then
    repo_root="$(pwd -P)"
  fi
  if ! repo_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
    bridge_die "현재 경로는 git 저장소가 아닙니다: ${repo_root:-$(pwd -P)}"
  fi

  local porcelain
  if ! porcelain="$(git -C "$repo_root" worktree list --porcelain 2>/dev/null)"; then
    bridge_die "git worktree list 실행 실패: $repo_root"
  fi

  # Repo-level stash check. refs/stash is shared across every worktree in the
  # repo, so a single `git stash list` at the repo root captures the global
  # count. ANY non-zero count blocks removal for every worktree — even ones
  # whose on-disk directory has gone missing (the prior per-worktree check
  # silently returned 0 in that case and let REMOVE fire, which violated the
  # "any stash anywhere blocks all" policy).
  local repo_stash_count=0
  repo_stash_count="$(git -C "$repo_root" stash list 2>/dev/null | wc -l | tr -d ' ')"
  [[ -z "$repo_stash_count" ]] && repo_stash_count=0

  local now_epoch
  now_epoch="$(date +%s)"
  local age_threshold_secs=$(( max_age_days * 86400 ))

  # Counters for summary — read/written by _bridge_worktree_doctor_classify_one
  # via Bash dynamic scope (intentional: keeps the porcelain parse loop simple).
  local total_scanned=0
  local n_remove=0
  local n_stale=0
  local n_skip=0
  local n_keep=0
  local n_removed=0
  local n_remove_failed=0

  # Iterate porcelain blocks. Each block starts with `worktree <path>` and
  # ends at a blank line. Fields we care about: worktree, branch.
  #
  # NOTE: we deliberately use a temp-file fd redirection rather than a
  # `<<<"$porcelain"` here-string or `done < <(printf ...)` process
  # substitution. macOS Homebrew Bash 5.3.9 has a heredoc_write bug where
  # write(2) into the parent's heredoc anon-pipe deadlocks when the body
  # contains multiple `worktree`/`branch`/empty-line records — observed
  # on this repo's own checkout (~152 fixer worktrees) and reproduced in
  # the smoke fixture with 3 fixture worktrees plus merge commits. A
  # temp file decouples the producer from the read loop entirely.
  local porcelain_tmp
  porcelain_tmp="$(mktemp "${TMPDIR:-/tmp}/bridge-worktree-doctor.XXXXXX")"
  printf '%s\n' "$porcelain" >"$porcelain_tmp"

  local wt_path="" wt_branch="" line
  printf '%-7s | %-7s | %-7s | %s\n' "STATUS" "STASH" "AGE" "WORKTREE"
  printf -- '--------+---------+---------+----------------------------------------\n'
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "worktree "*)
        wt_path="${line#worktree }"
        wt_branch=""
        ;;
      "branch "*)
        wt_branch="${line#branch }"
        ;;
      "")
        if [[ -n "$wt_path" ]]; then
          _bridge_worktree_doctor_classify_one \
            "$repo_root" "$wt_path" "$wt_branch" \
            "$target_branch" "$now_epoch" "$age_threshold_secs" \
            "$mode" "$include_stale" "$prune_branches" \
            "$repo_stash_count"
        fi
        wt_path=""
        wt_branch=""
        ;;
    esac
  done <"$porcelain_tmp"
  rm -f "$porcelain_tmp"
  # Trailing entry without blank line terminator.
  if [[ -n "$wt_path" ]]; then
    _bridge_worktree_doctor_classify_one \
      "$repo_root" "$wt_path" "$wt_branch" \
      "$target_branch" "$now_epoch" "$age_threshold_secs" \
      "$mode" "$include_stale" "$prune_branches" \
      "$repo_stash_count"
  fi

  echo ""
  echo "Summary (mode=$mode, target-branch=$target_branch, max-age-days=$max_age_days):"
  printf '  scanned    : %d\n' "$total_scanned"
  printf '  REMOVE     : %d (merged into %s, no stash)\n' "$n_remove" "$target_branch"
  printf '  STALE      : %d (unmerged, >%d days old)\n' "$n_stale" "$max_age_days"
  printf '  SKIP       : %d (stash entries present)\n' "$n_skip"
  printf '  KEEP       : %d (recent/unmerged)\n' "$n_keep"
  if [[ "$mode" == "apply" ]]; then
    printf '  removed    : %d\n' "$n_removed"
    if (( n_remove_failed > 0 )); then
      printf '  failed     : %d\n' "$n_remove_failed"
    fi
  else
    echo "  (dry-run; rerun with --apply to actually remove REMOVE rows)"
  fi
}

# Helper used only by bridge_worktree_doctor. Lives outside the main function
# so the counter mutations stay in one place. Reads/writes the n_* and
# total_scanned counters from the calling function's scope via Bash dynamic
# scope.
_bridge_worktree_doctor_classify_one() {
  local repo_root="$1"
  local wt_path="$2"
  local wt_branch="$3"
  local target_branch="$4"
  local now_epoch="$5"
  local age_threshold_secs="$6"
  local mode="$7"
  local include_stale="$8"
  local prune_branches="$9"
  local repo_stash_count="${10:-0}"

  # Match only fixer-style worktree paths: */.claude/worktrees/agent-*
  # or */.claude/worktrees/ab-*. Operator's primary checkout and ad-hoc
  # locations are NOT in scope — this is intentional, doctor is a focused
  # reaper, not a general worktree cleaner.
  if [[ "$wt_path" != *"/.claude/worktrees/agent-"* ]] \
     && [[ "$wt_path" != *"/.claude/worktrees/ab-"* ]]; then
    return 0
  fi

  total_scanned=$(( total_scanned + 1 ))

  local short_branch=""
  if [[ "$wt_branch" == refs/heads/* ]]; then
    short_branch="${wt_branch#refs/heads/}"
  else
    short_branch="$wt_branch"
  fi

  # Stash count is the GLOBAL repo-level count captured once by
  # bridge_worktree_doctor before the porcelain loop. Using the global value
  # (rather than a per-worktree `git -C <wt> stash list`) is what makes
  # "any stash anywhere blocks all removal" actually hold: a porcelain-listed
  # worktree whose on-disk directory is missing would previously read 0 here
  # and fall through to REMOVE under --apply, silently bypassing the policy.
  local stash_count="$repo_stash_count"

  # Last commit age on the branch (epoch seconds). Fall back to 0 if the
  # ref is gone — that itself is a signal the worktree is stale.
  local last_commit_epoch=0
  if [[ -n "$short_branch" ]]; then
    last_commit_epoch="$(git -C "$repo_root" log -1 --format=%ct "$short_branch" 2>/dev/null || printf '0')"
  fi
  local age_secs=0
  if [[ "$last_commit_epoch" =~ ^[0-9]+$ ]] && (( last_commit_epoch > 0 )); then
    age_secs=$(( now_epoch - last_commit_epoch ))
  fi
  local age_days=$(( age_secs / 86400 ))

  # Merged check: branch reachable from target_branch tip.
  local is_merged=0
  if [[ -n "$short_branch" ]]; then
    if git -C "$repo_root" merge-base --is-ancestor "$short_branch" "$target_branch" 2>/dev/null; then
      is_merged=1
    fi
  fi

  local status="KEEP"
  if (( stash_count > 0 )); then
    status="SKIP"
    n_skip=$(( n_skip + 1 ))
  elif (( is_merged == 1 )); then
    status="REMOVE"
    n_remove=$(( n_remove + 1 ))
  elif (( age_secs > age_threshold_secs )); then
    status="STALE"
    n_stale=$(( n_stale + 1 ))
  else
    status="KEEP"
    n_keep=$(( n_keep + 1 ))
  fi

  printf '%-7s | %-7s | %3dd    | %s\n' \
    "$status" "${stash_count}" "$age_days" "$wt_path"

  # Dry-run surfaces which orphaned children WOULD be reaped on REMOVE
  # rows so the operator sees the full picture before opting into --apply.
  # MUST run BEFORE the early `mode != apply` return below — the r1 of
  # PR #927 put this call inside the apply branch and codex caught it as
  # unreachable. Smoke `worktree-doctor-reap-zombies-dry-run.sh` is the
  # integration regression guard.
  if [[ "$mode" == "dry-run" && "$status" == "REMOVE" ]]; then
    _bridge_worktree_doctor_reap_children "$wt_path" "dry-run"
  fi

  if [[ "$mode" != "apply" ]]; then
    return 0
  fi

  # Apply mode — REMOVE always, STALE only with --include-stale.
  local should_remove=0
  if [[ "$status" == "REMOVE" ]]; then
    should_remove=1
  elif [[ "$status" == "STALE" && "$include_stale" == "1" ]]; then
    should_remove=1
  fi

  if (( should_remove == 1 )); then
    # Before removing the worktree directory itself, reap any leftover
    # daemonized child processes whose argv references the worktree path.
    # Operator-observed (Sean, 2026-05-16): 7 bridge-watchdog-silence.py
    # processes parented to init(1), alive 8-12 days, scripts pointing at
    # worktree dirs that had been pruned long ago. `git worktree remove -f`
    # does NOT cascade to such children — it only touches metadata and the
    # filesystem. We must do it ourselves.
    _bridge_worktree_doctor_reap_children "$wt_path" "$mode"
    if git -C "$repo_root" worktree remove -f "$wt_path" >/dev/null 2>&1; then
      n_removed=$(( n_removed + 1 ))
      printf '         [apply] removed: %s\n' "$wt_path"
      if [[ "$prune_branches" == "1" && -n "$short_branch" ]]; then
        if git -C "$repo_root" branch -D "$short_branch" >/dev/null 2>&1; then
          printf '         [apply] deleted branch: %s\n' "$short_branch"
        fi
      fi
    else
      n_remove_failed=$(( n_remove_failed + 1 ))
      printf '         [apply] FAILED to remove: %s\n' "$wt_path" >&2
    fi
  fi
}

# _bridge_worktree_doctor_reap_children — terminate any process whose argv
# references the given worktree path. Used by the doctor BEFORE removing a
# worktree directory so daemonized children (e.g. python helpers) that were
# reparented to init(1) don't outlive their worktree.
#
# Args: wt_path mode
#   wt_path  absolute path of the worktree about to be removed
#   mode     "apply" → actually send SIGTERM then SIGKILL after a short wait
#            anything else (including "dry-run") → report PIDs only, no signals
#
# Anchor policy (the critical correctness call):
#   Match a process if any whitespace-delimited token in its `ps` `command`
#   field starts with "<wt_path>/". This is anchored (NOT a naive substring
#   "contains"), so:
#     - It catches direct-exec children where argv[0] is the worktree
#       binary path (e.g. `/path/to/.claude/worktrees/agent-X/foo.sh ...`).
#     - It catches interpreter-exec children where argv[0] is the
#       interpreter and argv[1+] is a script path under the worktree
#       (e.g. `Python /path/to/.claude/worktrees/agent-X/bridge-watchdog-silence.py run`
#       — the exact shape of the 7 zombie processes Sean observed on
#       2026-05-16).
#     - It does NOT catch a `git` process running against the worktree
#       (git's argv doesn't include the worktree path as a path token —
#       paths are passed via `-C` separately).
#     - It does NOT catch the doctor itself (this function's argv is the
#       caller's argv, which doesn't include "<wt_path>/" as a token).
#   We also defensively skip our own PID and any `git` basename.
#
# Cross-platform `ps` contract:
#   We invoke `ps -eo pid=,command=` (= suppresses headers). This flag set
#   works identically on macOS BSD `ps` and Linux procps `ps`. We avoid
#   `pgrep -f` because the `-f` flag's argv-matching semantics drift between
#   BSD pgrep (matches against process name only by default) and Linux
#   pgrep (matches full command line); using `ps` + a pure-bash token scan
#   keeps the behavior identical on both.
#
# Signal ordering: TERM → wait up to ~2s (polling at 100ms) → KILL.
_bridge_worktree_doctor_reap_children() {
  local wt_path="$1"
  local mode="$2"

  # Refuse to operate on an empty path or "/" (defense in depth — a bug
  # upstream that passed wt_path="" would otherwise match every process
  # whose command line contains "/").
  if [[ -z "$wt_path" || "$wt_path" == "/" ]]; then
    return 0
  fi

  local self_pid=$$
  # Path prefix we anchor against. We anchor on "<wt_path>/" specifically
  # (trailing slash mandatory) so we never match a sibling worktree whose
  # name happens to start with the same prefix (e.g. agent-foo vs
  # agent-foo-bar).
  local anchor="${wt_path%/}/"

  # Snapshot the process table once. Output format: "<pid> <command...>".
  # ps -eo pid=,command= works on both macOS BSD ps and Linux procps ps;
  # the trailing = suppresses the header.
  local ps_out
  if ! ps_out="$(ps -eo pid=,command= 2>/dev/null)"; then
    return 0
  fi

  local -a matched_pids=()
  local line pid cmd token
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Split into pid + command. Leading whitespace from BSD ps is stripped
    # by the read.
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%%[[:space:]]*}"
    cmd="${line#"$pid"}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"

    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # Skip self and our parent (the caller). Safer than only skipping $$.
    if [[ "$pid" == "$self_pid" || "$pid" == "$PPID" ]]; then
      continue
    fi
    # Skip git plumbing. The doctor itself runs git subprocesses that
    # happen during/after this scan; we don't want to ever target them.
    local first_token="${cmd%%[[:space:]]*}"
    local first_basename="${first_token##*/}"
    if [[ "$first_basename" == "git" ]]; then
      continue
    fi

    # Token-level anchor: does any whitespace-separated token in the
    # command line start with the worktree path + "/"?
    local matched=0
    # shellcheck disable=SC2086  # intentional word-splitting on the cmd line
    for token in $cmd; do
      if [[ "$token" == "$anchor"* ]]; then
        matched=1
        break
      fi
    done
    if (( matched == 1 )); then
      matched_pids+=("$pid")
    fi
  done <<<"$ps_out"

  if (( ${#matched_pids[@]} == 0 )); then
    return 0
  fi

  if [[ "$mode" != "apply" ]]; then
    printf '         [dry-run] would reap %d orphaned child PID(s) under %s: %s\n' \
      "${#matched_pids[@]}" "$wt_path" "${matched_pids[*]}"
    return 0
  fi

  # Apply mode: SIGTERM, poll up to ~2s, then SIGKILL stragglers.
  local p
  for p in "${matched_pids[@]}"; do
    kill -TERM "$p" 2>/dev/null || true
  done
  printf '         [apply] sent SIGTERM to %d orphan(s) under %s: %s\n' \
    "${#matched_pids[@]}" "$wt_path" "${matched_pids[*]}"

  # Poll for exit. 20 iterations × 0.1s = ~2s budget.
  local iter
  local -a still_alive=()
  for (( iter = 0; iter < 20; iter++ )); do
    still_alive=()
    for p in "${matched_pids[@]}"; do
      if kill -0 "$p" 2>/dev/null; then
        still_alive+=("$p")
      fi
    done
    if (( ${#still_alive[@]} == 0 )); then
      break
    fi
    sleep 0.1
  done

  if (( ${#still_alive[@]} > 0 )); then
    for p in "${still_alive[@]}"; do
      kill -KILL "$p" 2>/dev/null || true
    done
    printf '         [apply] SIGKILL escalation for %d straggler(s): %s\n' \
      "${#still_alive[@]}" "${still_alive[*]}" >&2
  fi
}

bridge_static_agents_for_project_engine() {
  local project_root="$1"
  local engine="$2"
  local agent
  local agent_root

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    [[ "$(bridge_agent_engine "$agent")" == "$engine" ]] || continue
    agent_root="$(bridge_agent_project_root "$agent")"
    [[ "$agent_root" == "$project_root" ]] || continue
    printf '%s\n' "$agent"
  done
}

bridge_source_repo_is_dirty() {
  local project_root="$1"
  [[ -n "$(git -C "$project_root" status --short 2>/dev/null || true)" ]]
}

bridge_prepare_isolated_worktree() {
  local engine="$1"
  local agent="$2"
  local source_workdir="$3"
  local project_root worktree_root worktree_workdir branch

  project_root="$(bridge_project_root_for_path "$source_workdir")"
  if ! git -C "$project_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    bridge_die "git 프로젝트에서만 isolated worktree를 만들 수 있습니다: $source_workdir"
  fi

  worktree_root="$(bridge_worktree_root_for "$project_root" "$agent")"
  worktree_workdir="$(bridge_worktree_launch_dir_for "$source_workdir" "$agent")"
  branch="$(bridge_worktree_branch_for_agent "$agent")"

  if [[ -d "$worktree_root/.git" || -f "$worktree_root/.git" ]]; then
    bridge_write_worktree_metadata "$engine" "$agent" "$source_workdir" "$project_root" "$worktree_root" "$worktree_workdir" "$branch"
    printf '%s' "$worktree_workdir"
    return 0
  fi

  mkdir -p "$(dirname "$worktree_root")"
  if bridge_source_repo_is_dirty "$project_root"; then
    bridge_warn "원본 작업트리에 미커밋 변경이 있습니다. 새 worktree는 현재 HEAD 기준으로 생성됩니다: $project_root"
  fi

  if git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$project_root" worktree add "$worktree_root" "$branch" >/dev/null
  else
    git -C "$project_root" worktree add -b "$branch" "$worktree_root" HEAD >/dev/null
  fi

  bridge_write_worktree_metadata "$engine" "$agent" "$source_workdir" "$project_root" "$worktree_root" "$worktree_workdir" "$branch"
  printf '%s' "$worktree_workdir"
}

bridge_infer_current_agent() {
  local session=""
  local current_dir
  local agent
  local match=""

  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || return 1

  if [[ -n "${BRIDGE_AGENT_ID:-}" ]] && bridge_agent_exists "$BRIDGE_AGENT_ID"; then
    printf '%s' "$BRIDGE_AGENT_ID"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]]; then
    session="$(tmux display-message -p '#S' 2>/dev/null || true)"
    if [[ -n "$session" ]] && bridge_agent_exists "$session"; then
      printf '%s' "$session"
      return 0
    fi
  fi

  current_dir="$(pwd -P)"
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_workdir "$agent")" == "$current_dir" ]]; then
      if [[ -n "$match" ]]; then
        return 1
      fi
      match="$agent"
    fi
  done

  if [[ -n "$match" ]]; then
    printf '%s' "$match"
    return 0
  fi

  return 1
}

bridge_resolve_agent() {
  local requested="${1:-}"
  local resolved=""

  if [[ -n "$requested" ]]; then
    bridge_require_agent "$requested"
    printf '%s' "$requested"
    return 0
  fi

  if resolved="$(bridge_infer_current_agent)"; then
    printf '%s' "$resolved"
    return 0
  fi

  bridge_die "에이전트를 자동 추론할 수 없습니다. --agent 또는 명시적 agent 인자를 사용하세요."
}

bridge_admin_agent_id() {
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-}"
}

bridge_agent_is_admin() {
  local agent="$1"
  local admin_agent=""

  admin_agent="$(bridge_admin_agent_id)"
  [[ -n "$admin_agent" && "$agent" == "$admin_agent" ]]
}

bridge_agent_exists() {
  local agent="$1"
  declare -p BRIDGE_AGENT_SESSION >/dev/null 2>&1 || return 1
  [[ -n "${BRIDGE_AGENT_SESSION[$agent]+x}" ]]
}

bridge_agent_is_static() {
  local agent="$1"
  [[ "$(bridge_agent_source "$agent")" == "static" ]]
}

bridge_agent_is_launchable_static() {
  local agent="$1"
  bridge_agent_exists "$agent" && bridge_agent_is_static "$agent"
}

bridge_agent_is_cron_delivery_target() {
  local agent="$1"

  bridge_agent_exists "$agent" || return 1
  if bridge_agent_is_static "$agent"; then
    return 0
  fi
  bridge_profile_has_source "$agent"
}

bridge_require_agent() {
  local agent="$1"

  if bridge_agent_exists "$agent"; then
    return 0
  fi

  echo "등록된 에이전트:"
  bridge_list_agents >&2
  bridge_die "'$agent'은(는) 등록된 에이전트가 아닙니다."
}

bridge_require_static_agent() {
  local agent="$1"

  bridge_require_agent "$agent"
  if ! bridge_agent_is_static "$agent"; then
    bridge_die "'$agent'은(는) 정적 역할이 아닙니다. 관리자 에이전트는 정적 역할로 설정하세요."
  fi
}

bridge_require_launchable_static_agent() {
  local agent="$1"

  bridge_require_agent "$agent"
  if ! bridge_agent_is_launchable_static "$agent"; then
    bridge_die "'$agent'은(는) cron delivery 대상이 될 수 있는 정적 역할이 아닙니다."
  fi
}

bridge_require_cron_delivery_target() {
  local agent="$1"

  bridge_require_agent "$agent"
  if ! bridge_agent_is_cron_delivery_target "$agent"; then
    bridge_die "'$agent'은(는) cron delivery 대상이 될 수 있는 등록된 장기 역할이 아닙니다."
  fi
}

bridge_require_admin_agent() {
  local agent

  agent="$(bridge_admin_agent_id)"
  if [[ -z "$agent" ]]; then
    bridge_die "관리자 에이전트가 설정되지 않았습니다. 'agent-bridge setup admin <agent>' 또는 BRIDGE_ADMIN_AGENT_ID를 설정하세요."
  fi

  bridge_require_static_agent "$agent"
  printf '%s' "$agent"
}

bridge_agent_id_for_session() {
  local requested_session="$1"
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_session "$agent")" == "$requested_session" ]]; then
      printf '%s' "$agent"
      return 0
    fi
  done

  return 1
}

bridge_agent_desc() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_DESC[$agent]-}"
}

bridge_agent_engine() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_ENGINE[$agent]-unknown}"
}

bridge_agent_source() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_SOURCE[$agent]-static}"
}

# Issue #598 Track 1: which loader path made this agent id known.
# Closed value space: {static-roster, dynamic-active-env,
# dynamic-history-live-session, dynamic-tmux-recovered}. Falls back to
# `static-roster` when the loader did not tag the agent — that matches
# the historical implicit behavior of any id in BRIDGE_AGENT_IDS that
# only has BRIDGE_AGENT_SOURCE=static.
bridge_agent_provenance() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_PROVENANCE[$agent]-static-roster}"
}

# Issue #597 Track B: PreCompact channel auto-notify opt-in.
#
# Returns 0 (success) when the agent is opted in, 1 otherwise. The daemon
# observer should consult this rather than reading BRIDGE_AGENT_PRECOMPACT_NOTIFY
# directly so any future normalization (e.g. yes/on/true acceptance) lands in
# one place. Default is OFF — only the literal value "1" enables the notice.
bridge_agent_precompact_notify_enabled() {
  local agent="$1"
  local val="${BRIDGE_AGENT_PRECOMPACT_NOTIFY[$agent]-0}"
  [[ "$val" == "1" ]]
}

# Issue #597 Track B: PreCompact notice language (en|ko).
#
# Resolution order: per-agent map → global BRIDGE_PRECOMPACT_NOTIFY_LANG env
# → "en" fallback. Unknown values pass through; the Python template renderer
# normalizes anything outside {en, ko} back to "en".
bridge_agent_precompact_notify_lang() {
  local agent="$1"
  local lang="${BRIDGE_AGENT_PRECOMPACT_NOTIFY_LANG[$agent]-${BRIDGE_PRECOMPACT_NOTIFY_LANG:-en}}"
  [[ -n "$lang" ]] || lang="en"
  printf '%s' "$lang"
}

# Issue #539: agent class is the privilege boundary consumed by
# hooks/tool-policy.py. The closed value space is {user, system}; any
# unknown value (including the empty string written by older roster
# snapshots) is normalized to "user" so the default-deny posture for
# cross-agent reads is preserved on rosters that predate this field.
# Validation of operator-supplied class= values happens at roster-load
# time via bridge_validate_agent_class — this getter is the read-side
# fallback.
bridge_agent_class() {
  local agent="$1"
  local cls="${BRIDGE_AGENT_CLASS[$agent]-user}"
  case "$cls" in
    user|system) ;;
    *) cls="user" ;;
  esac
  printf '%s' "$cls"
}

# Validate every BRIDGE_AGENT_CLASS entry currently present in the roster
# maps. Called from bridge_load_roster after sourcing the roster files so
# typos like `class=admin` or `class=System` surface as a hard error
# rather than silently falling back to user-class. The closed value space
# matches bridge_agent_class above; future classes must extend both the
# value list AND the tool-policy gate.
bridge_validate_agent_classes() {
  declare -p BRIDGE_AGENT_CLASS >/dev/null 2>&1 || return 0
  local agent cls
  for agent in "${!BRIDGE_AGENT_CLASS[@]}"; do
    cls="${BRIDGE_AGENT_CLASS[$agent]}"
    [[ -n "$cls" ]] || continue
    case "$cls" in
      user|system) ;;
      *) bridge_die "unknown agent class '$cls' for agent '$agent'; valid: user, system" ;;
    esac
  done
}

bridge_agent_session() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_SESSION[$agent]-}"
}

bridge_agent_isolation_mode() {
  # Issue #412 Track A: cross-check roster vs runtime evidence and
  # normalize the value space to {shared, linux-user, unknown}. When the
  # agent has an os_user set, the launcher (bridge-run.sh) wraps the
  # session in `sudo -n -u agent-bridge-<slug>` and the runtime is
  # genuinely linux-user-isolated regardless of what the roster declares
  # — return linux-user so `agent show` and downstream consumers reflect
  # the runtime, not stale roster intent. Otherwise normalize the
  # roster-declared value: empty/shared → shared; linux-user → linux-user;
  # anything else → unknown (was previously rendered as the raw value or
  # `-`, leading to `no` / `-` / `shared` drift across same-install agents).
  local agent="$1"
  local roster_mode="${BRIDGE_AGENT_ISOLATION_MODE[$agent]-}"
  local os_user="${BRIDGE_AGENT_OS_USER[$agent]-}"
  if [[ -n "$os_user" ]]; then
    printf 'linux-user'
    return 0
  fi
  case "$roster_mode" in
    linux-user) printf 'linux-user' ;;
    shared|"") printf 'shared' ;;
    *) printf 'unknown' ;;
  esac
}

bridge_agent_os_user() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_OS_USER[$agent]-}"
}

bridge_agent_os_user_display() {
  # Issue #412 Track A: stable display value for the `os_user` field in
  # `agent show` output. Always print the actual value when set, or `-`
  # when unset — never `no`, never empty. The legacy renderer used
  # `${os_user:--}` which collapsed empty to `-` but other callers
  # passed `no` through unchanged, producing the three-different-shapes
  # drift the issue documents.
  local agent="$1"
  local v="${BRIDGE_AGENT_OS_USER[$agent]-}"
  if [[ -n "$v" ]]; then
    printf '%s' "$v"
  else
    printf '%s' '-'
  fi
}

bridge_agent_default_os_user() {
  local agent="$1"

  bridge_require_python
  python3 - "$agent" <<'PY'
import re
import sys

agent = sys.argv[1].strip().lower()
slug = re.sub(r"[^a-z0-9_-]+", "-", agent).strip("-")
slug = slug or "agent"
prefix = "agent-bridge-"
max_len = 32
keep = max_len - len(prefix)
if keep < 1:
    keep = 1
print(prefix + slug[:keep])
PY
}

bridge_agent_linux_user_isolation_requested() {
  local agent="$1"
  [[ "$(bridge_agent_isolation_mode "$agent")" == "linux-user" ]]
}

bridge_host_platform() {
  if [[ -n "${BRIDGE_HOST_PLATFORM_OVERRIDE:-}" ]]; then
    printf '%s' "$BRIDGE_HOST_PLATFORM_OVERRIDE"
    return 0
  fi
  uname -s 2>/dev/null || printf 'unknown'
}

bridge_agent_linux_user_isolation_effective() {
  local agent="$1"

  bridge_agent_linux_user_isolation_requested "$agent" || return 1
  [[ "$(bridge_host_platform)" == "Linux" ]] || return 1
  [[ -n "$(bridge_agent_os_user "$agent")" ]] || return 1
  return 0
}

bridge_current_user() {
  id -un
}

bridge_agent_linux_user_home() {
  local os_user="$1"
  printf '%s/%s' "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT" "$os_user"
}

bridge_agent_linux_env_file() {
  local agent="$1"
  # Scoped per-agent roster snapshot at a stable controller-owned path.
  # Must NOT live under the workdir — workdir is chowned to $os_user, which
  # would make the file writable by the isolated UID. Placing it under
  # $runtime_state_dir keeps controller ownership while still letting the
  # isolated UID read it (via u:$os_user:r-- ACL). The path is derivable
  # from BRIDGE_AGENT_ID alone, so bridge_load_roster can find it without
  # a roster lookup — closes issue #116.
  printf '%s/agent-env.sh' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_linux_sudo_root() {
  # Linux-user isolation only escalates via sudo on Linux. On other
  # platforms (notably macOS), the helper falls through to a direct
  # invocation as the controller user. Without this guard `sudo -n` runs
  # under the calling user's policy and silently fails non-interactively
  # on hosts with no passwordless sudoers entry — which is the macOS
  # default — so callers like `agent delete --purge-home` would log
  # `best-effort rm failed` and leak paths. Issue #620.
  if [[ "$(uname -s)" != "Linux" ]]; then
    "$@"
    return $?
  fi

  if [[ "$(id -u)" == "0" ]]; then
    "$@"
    return $?
  fi

  command -v sudo >/dev/null 2>&1 || bridge_die "linux-user isolation requires sudo"
  sudo -n "$@"
}

bridge_linux_can_sudo_to() {
  local os_user="$1"

  [[ -n "$os_user" ]] || return 1
  if [[ "$(id -u)" == "0" ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  # Probe via `bash -c 'exit 0'` — matches the sudoers entry installed by
  # bridge_migration_sudoers_entry (which whitelists tmux + bash only, not
  # /usr/bin/true). Using the canonical BRIDGE_BASH_BIN when available so
  # the path also matches the entry's `command -v bash`.
  local bash_bin="${BRIDGE_BASH_BIN:-$(command -v bash 2>/dev/null || printf '/bin/bash')}"
  sudo -n -u "$os_user" -- "$bash_bin" -c 'exit 0' 2>/dev/null
}

# Internal: non-fatal sudo presence probe. Returns 0 if the helper can
# safely call bridge_linux_sudo_root, 1 if sudo is absent (so the helper
# must early-return and the daemon is not killed by bridge_die).
bridge_linux_have_sudo_or_skip() {
  if [[ "$(id -u)" == "0" ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1
}

bridge_agent_preserved_env_vars() {
  # Intentionally conservative: the ENV_PREFIX inlined in the SESSION_CMD
  # re-exports all BRIDGE_* runtime paths inside the bash -c child, so sudo
  # only needs to pass through the terminal/locale bits and the two
  # launch-time markers that are not in ENV_PREFIX.
  printf '%s' "TERM,LANG,LC_ALL,BRIDGE_AGENT_ENV_FILE,BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS,BRIDGE_ENGINE_BIN"
}

# Issue #1118: resolve the engine binary's absolute path on the controller.
#
# v2 linux-user isolation runs the agent's launch_cmd under a sudo wrap
# (`sudo -n -u <service_user> -H -- bash -lc "<cmd>"`). The service user
# is auto-provisioned and its PATH is sudo's default
# (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`). The
# controller's per-user `claude` install (typically `~/.local/bin/claude`
# from `npm i -g` or the official installer) is not on that PATH, so the
# `bash -lc "claude ..."` child dies with `claude: command not found`
# and the daemon reports the opaque `start-command-failed`.
#
# This helper resolves the engine binary via `command -v` against the
# CONTROLLER's PATH (i.e. the PATH inherited by the bridge daemon /
# `agent-bridge` invocation). Callers propagate the result into the
# sudo'd child via the `BRIDGE_ENGINE_BIN` env var (added to
# `bridge_agent_preserved_env_vars` above); `bridge-run.sh` then
# rewrites the leading bare `claude`/`codex` token in `LAUNCH_CMD` to
# this absolute path before execution.
#
# Returns the absolute path on stdout (rc=0) when resolved; prints
# nothing and returns rc=1 when the binary is missing from the
# controller's PATH (caller decides whether to warn or fall through
# to the legacy bare-name behavior).
bridge_resolve_engine_binary() {
  local engine="$1"
  local resolved=""
  case "$engine" in
    claude|codex) : ;;
    *) return 1 ;;
  esac
  resolved="$(command -v "$engine" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 1
  # `command -v` may return a shell function/alias name on some hosts;
  # require an absolute path on disk to avoid propagating a token the
  # service user cannot resolve.
  [[ "$resolved" == /* && -x "$resolved" ]] || return 1
  printf '%s' "$resolved"
}

# Issue #1118: rewrite a launch_cmd so its engine token uses the absolute
# binary path resolved by bridge_resolve_engine_binary.
#
# Accepts the launch_cmd on stdin OR as $1, and the engine binary
# absolute path as $2. Walks past any leading `KEY=VALUE` env-prefix
# tokens (matching the regex used by launch-cmd-static-claude-build.py)
# and replaces the first non-assignment token IFF it equals the bare
# `claude` or `codex` engine name. Tokens that already look absolute
# (start with `/`) are left untouched so an operator who pinned a
# specific binary via `BRIDGE_AGENT_LAUNCH_CMD` retains their override.
#
# This is intentionally a Python helper rather than inline shell — the
# parsing must handle shell-quoted KEY=VALUE prefixes the same way the
# existing launch-cmd builders do, and the Python `shlex` module is the
# only parser the rest of bridge-state.sh already trusts for this job
# (see scripts/python-helpers/launch-cmd-*-build.py).
bridge_rewrite_launch_cmd_engine_bin() {
  local launch_cmd="$1"
  local engine_bin="$2"
  [[ -n "$launch_cmd" && -n "$engine_bin" ]] || {
    printf '%s' "$launch_cmd"
    return 0
  }
  bridge_require_python
  if ! bridge_resolve_script_dir_check; then
    printf '%s' "$launch_cmd"
    return 0
  fi
  python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/launch-cmd-engine-bin-rewrite.py" \
    "$engine_bin" "$launch_cmd"
}

bridge_linux_require_setfacl() {
  if command -v setfacl >/dev/null 2>&1; then
    return 0
  fi
  bridge_linux_sudo_root bash -lc 'command -v setfacl >/dev/null 2>&1' || bridge_die "linux-user isolation requires setfacl"
}

bridge_linux_user_exists() {
  local os_user="$1"
  id -u "$os_user" >/dev/null 2>&1
}

bridge_linux_ensure_os_user() {
  local os_user="$1"
  local user_home="$2"

  bridge_linux_user_exists "$os_user" && return 0
  bridge_linux_sudo_root useradd -r -d "$user_home" -s /bin/bash "$os_user"
}

bridge_linux_ensure_user_home() {
  local os_user="$1"
  local user_home="$2"

  bridge_linux_sudo_root mkdir -p "$user_home"
  bridge_linux_sudo_root chown "$os_user" "$user_home"
  bridge_linux_sudo_root chmod 700 "$user_home"
}

bridge_linux_install_agent_bridge_symlink() {
  local os_user="$1"
  local user_home="$2"
  local bridge_home="$3"
  local target="$user_home/.agent-bridge"
  local current=""

  # Issue #403 P0: NEVER rm -rf a path that resolves to the controller's
  # own BRIDGE_HOME. The realpath check catches both literal-equality
  # and symlink-to-controller-home cases. Any caller passing
  # os_user==<controller-login> hits this gate, which is the right
  # behavior — the controller's login is not an isolated agent and
  # should never have its ~/.agent-bridge wiped.
  local _resolved_target _resolved_bridge_home _controller_user
  _resolved_target="$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")"
  _resolved_bridge_home="$(readlink -f "$bridge_home" 2>/dev/null || printf '%s' "${bridge_home:-}")"
  if [[ -n "$_resolved_bridge_home" && "$_resolved_target" == "$_resolved_bridge_home" ]]; then
    bridge_die "install_agent_bridge_symlink: refusing to rm -rf controller BRIDGE_HOME at $target (would wipe live install — issue #403). Caller must pass an isolated UID's os_user, not the controller login."
  fi
  # Also reject when os_user is empty or matches the controller's login
  # directly, even if BRIDGE_HOME isn't yet set in this scope.
  _controller_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
  if [[ -z "$os_user" || "$os_user" == "$_controller_user" ]]; then
    bridge_die "install_agent_bridge_symlink: os_user '$os_user' equals controller login or is empty — refusing to operate on controller-side path $target (issue #403)."
  fi

  current="$(bridge_linux_sudo_root python3 - "$target" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
if not path.exists() and not path.is_symlink():
    print("")
elif path.is_symlink():
    print(os.readlink(path))
else:
    print("__nonlink__")
PY
)"

  if [[ "$current" == "$bridge_home" ]]; then
    return 0
  fi

  bridge_linux_sudo_root rm -rf "$target"
  bridge_linux_sudo_root ln -s "$bridge_home" "$target"
  bridge_linux_sudo_root chown -h "$os_user" "$target" >/dev/null 2>&1 || true
}

# Resolve the absolute path of an engine CLI (claude/codex) on the
# controller's PATH. Returns empty string if not found.
bridge_resolve_engine_cli() {
  local engine="$1"
  case "$engine" in
    claude|codex) command -v "$engine" 2>/dev/null || true ;;
    *) printf '' ;;
  esac
}

bridge_linux_traverse_stop_for() {
  # Return a safe stop_path for traversing ancestors of $target. Prefers
  # the operator's home when $target sits under it (that's the case that
  # actually needs traversal help — chmod 0700 on the controller home
  # blocks base-perm search for everyone else). Returns empty for system
  # paths (/usr/bin/..., /opt/..., etc.) so callers can skip the grant
  # entirely — `other::r-x` already covers those.
  local target="$1"
  local controller_user="${2:-$(bridge_current_user)}"
  local controller_home=""
  controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -n "$controller_home" && "$target" == "$controller_home"/* ]]; then
    printf '%s' "$controller_home"
    return 0
  fi
  # No safe stop_path — caller must skip the grant. Never return '/',
  # '/home', or similar shared roots (issue #233).
  return 0
}

# Emit ACL metadata (not file contents) for each declared channel state
# dir + its .env, suitable for inclusion in a channel-health miss task
# body. Bounded by design:
#   - declared channels only (discord/telegram/teams/ms365);
#   - per-target output capped at 12 lines via head;
#   - never reads .env content; only `getfacl -p` metadata;
#   - graceful when getfacl is missing, target is missing, or sudo fails.
bridge_agent_channel_acl_diagnostics_text() {
  local agent="$1"

  if ! bridge_linux_have_sudo_or_skip; then
    printf '_ACL diagnostics unavailable: sudo not present_\n'
    return 0
  fi

  command -v getfacl >/dev/null 2>&1 || {
    printf '_getfacl unavailable; skipping ACL diagnostics_\n'
    return 0
  }

  local workdir
  workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
  [[ -n "$workdir" ]] || return 0

  local channels_csv
  channels_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
  [[ -n "$channels_csv" ]] || return 0

  local IFS=',' tokens=()
  read -ra tokens <<<"$channels_csv"

  local token id state_dir env_file
  local emitted=0
  for token in "${tokens[@]}"; do
    token="${token// /}"
    [[ "$token" == plugin:* ]] || continue
    id="${token#plugin:}"
    id="${id%%@*}"
    case "$id" in
      discord|telegram|teams|ms365) ;;
      *) continue ;;
    esac
    state_dir="$workdir/.$id"
    env_file="$state_dir/.env"

    if ! bridge_linux_sudo_root test -d "$state_dir" 2>/dev/null; then
      printf '_state_dir missing: %s_\n\n' "$state_dir"
      emitted=1
      continue
    fi

    printf '### %s state-dir ACL\n\n' "$id"
    printf '```\n'
    ( bridge_linux_sudo_root getfacl -p "$state_dir" 2>&1 || true ) | head -12
    printf '```\n\n'
    emitted=1

    if bridge_linux_sudo_root test -f "$env_file" 2>/dev/null; then
      printf '### %s .env ACL\n\n' "$id"
      printf '```\n'
      ( bridge_linux_sudo_root getfacl -p "$env_file" 2>&1 || true ) | head -12
      printf '```\n\n'
    fi
  done

  if (( emitted == 0 )); then
    printf '_no declared channel state dirs to diagnose_\n'
  fi
}

bridge_linux_revoke_traverse_chain() {
  # v2 hard-cut: per-agent group + setgid layout has no named-user ACLs to
  # revoke. Retained as a no-op stub so v1-era callers (lib/bridge-migration.sh
  # unisolate path, lib/bridge-agents.sh:bridge_linux_revoke_plugin_channel_grants)
  # link cleanly without each caller having to be re-plumbed in this PR.
  return 0
}

bridge_resolve_plugin_install_path() {
  # Resolve <plugin>@<marketplace> to its on-disk install directory.
  # Tries installed_plugins.json's installPath first; falls back to the
  # marketplace's source.path/plugins/<plugin> for directory-source
  # marketplaces (used by Agent Bridge's own teams/ms365 plugins, where
  # installed_plugins.json may carry a stale cache path). The fallback
  # is only used for directory-source marketplaces — non-directory
  # sources (git, http, etc.) resolve solely via installed_plugins.json
  # so we don't accidentally synthesise a path that does not match how
  # the controller actually fetched the plugin (Risk 2 in PR #302 r1).
  local plugin_id="$1"
  local plugins_root="$2"
  local manifest="$plugins_root/installed_plugins.json"
  local marketplaces_json="$plugins_root/known_marketplaces.json"

  bridge_require_python
  python3 - "$plugin_id" "$manifest" "$marketplaces_json" <<'PY'
import json, os, sys

plugin_id = sys.argv[1]
manifest_path = sys.argv[2]
marketplaces_path = sys.argv[3]


def warn(msg):
    sys.stderr.write("[bridge-isolate] " + msg + "\n")


resolved = ""

if os.path.isfile(manifest_path):
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except (OSError, ValueError) as exc:
        # Loud failure: corrupt controller manifest is operator-actionable
        # state. Refuse to resolve from it and let the caller fall back to
        # the directory marketplace path (which is independent of the
        # broken manifest); if that also fails the caller will skip the
        # grant rather than silently degrade.
        warn(
            "controller installed_plugins.json unreadable (%s): %s — refusing to resolve %s from manifest"
            % (type(exc).__name__, manifest_path, plugin_id)
        )
        manifest = None
    if isinstance(manifest, dict):
        for entry in manifest.get("plugins", {}).get(plugin_id, []):
            ip = entry.get("installPath")
            if ip and os.path.isdir(ip):
                resolved = ip
                break

if not resolved and "@" in plugin_id and os.path.isfile(marketplaces_path):
    try:
        with open(marketplaces_path) as f:
            markets = json.load(f)
    except (OSError, ValueError) as exc:
        # known_marketplaces.json is not strictly required (manifest path
        # already failed; the directory-marketplace fallback only applies
        # when this file is parseable). Log it but don't escalate.
        warn(
            "controller known_marketplaces.json unreadable (%s): %s — directory-marketplace fallback skipped for %s"
            % (type(exc).__name__, marketplaces_path, plugin_id)
        )
        markets = None
    if isinstance(markets, dict):
        plugin_name, marketplace = plugin_id.split("@", 1)
        entry = markets.get(marketplace, {})
        if isinstance(entry, dict):
            src = entry.get("source")
            candidate = ""
            # Risk 2 (PR #302 r1): the installLocation/plugins/<name>
            # fallback only matches reality for directory-source
            # marketplaces. For git/http/etc. sources, installLocation
            # is the cache root, not the source-of-truth, so synthesising
            # a path there would mis-grant ACLs.
            if isinstance(src, dict) and src.get("source") == "directory":
                candidate = src.get("path", "") or entry.get("installLocation", "")
            if candidate:
                guess = os.path.join(candidate, "plugins", plugin_name)
                if os.path.isdir(guess):
                    resolved = guess

print(resolved or "")
PY
}

bridge_known_marketplaces_lookup() {
  # Inspect `known_marketplaces.json` and return whether a marketplace is
  # registered. Mirrors the lookup shape used by the manifest writer's
  # `:1092` block (and the directory-source fallback at `:894` in
  # bridge_resolve_plugin_install_path) so the symlink path in
  # bridge_linux_share_plugin_catalog gates on the same source-of-truth.
  #
  # Output protocol — exactly one line:
  #   present:directory   — registered with a directory source
  #   present:git         — registered with a git source
  #   present:other       — registered with another source kind (http, etc.)
  #   missing             — not registered (caller should silently skip)
  #   unparseable         — JSON missing / unreadable / not an object
  #                         (caller should skip the whole 5b' block;
  #                          this helper stays silent because the
  #                          manifest writer at :1183 already emitted
  #                          the canonical warning earlier in the same
  #                          share pass — see #348 r3).
  #
  # The `<source-kind>` half of `present:*` is informational — current
  # callers symlink `<plugins_root>/marketplaces/<mkt>` regardless of
  # source kind because that mirror tree is what Claude actually reads
  # at runtime; the source-kind disclosure exists so a future caller
  # that wants to special-case directory vs git can do so without
  # re-parsing the JSON. (#348 r2.)
  local marketplace_id="$1"
  local plugins_root="$2"
  local marketplaces_json="$plugins_root/known_marketplaces.json"

  bridge_require_python
  python3 - "$marketplace_id" "$marketplaces_json" <<'PY'
import json, os, sys

marketplace_id = sys.argv[1]
marketplaces_path = sys.argv[2]


if not os.path.isfile(marketplaces_path):
    # Treat missing as unparseable for caller-side simplicity: the
    # whole 5b' block is a no-op without it. Mirrors the manifest
    # writer's behaviour (it also short-circuits the directory-
    # marketplace fallback when the JSON is absent).
    print("unparseable")
    sys.exit(0)

try:
    with open(marketplaces_path) as f:
        markets = json.load(f)
    if not isinstance(markets, dict):
        raise ValueError("expected JSON object at root, got %r" % type(markets).__name__)
except (OSError, ValueError):
    # Stay silent on the corrupt-JSON branch: the manifest writer
    # (`bridge_write_isolated_installed_plugins_manifest`, step 4 of
    # bridge_linux_share_plugin_catalog) always runs before this
    # helper (step 5b') and already emitted the canonical
    # `[bridge-isolate] controller known_marketplaces.json unparseable …`
    # warning at :1183-1186 for the same file. Re-emitting here would
    # log the same condition twice (once per share pass, plus once per
    # `_mkt_id` iteration before the 5b' loop short-circuits on
    # `unparseable`). Returning `unparseable` is sufficient — the
    # caller's `case` arm sets `_mkt_block_disabled=1` and skips the
    # symlink path silently. (#348 r3.)
    print("unparseable")
    sys.exit(0)

entry = markets.get(marketplace_id)
if not isinstance(entry, dict):
    print("missing")
    sys.exit(0)

src = entry.get("source")
if isinstance(src, dict):
    kind = src.get("source")
    if kind == "directory":
        print("present:directory")
        sys.exit(0)
    if kind == "git":
        print("present:git")
        sys.exit(0)
print("present:other")
PY
}

bridge_isolation_alias_rejection_reason() {
  # Bash-side mirror of `_alias_rejection_reason` in
  # bridge-dev-plugin-cache.py. Returns the empty string on stdout when
  # the alias is safe to plant as a `marketplaces/<alias>` symlink under
  # the isolated home (root is the writer, so an unsafe alias is a
  # privilege-escalation surface). Otherwise prints a short reason.
  #
  # Acceptance criteria (must match the Python helpers):
  #   - non-empty, length <= 200
  #   - matches ^[A-Za-z0-9._-]+$ (no slash, no control char, no whitespace)
  #   - does not contain '..'
  #   - not '.' / '..'
  #   - not a Windows reserved name (CON/PRN/AUX/NUL/COM1-9/LPT1-9)
  #   - if it starts with '.', must equal '.git'
  local alias="$1"
  local upper=""
  if [[ -z "$alias" ]]; then
    printf 'empty'
    return 0
  fi
  if (( ${#alias} > 200 )); then
    printf 'length exceeds 200'
    return 0
  fi
  if ! [[ "$alias" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf "contains characters outside [A-Za-z0-9._-]"
    return 0
  fi
  if [[ "$alias" == *..* ]]; then
    printf "contains '..'"
    return 0
  fi
  if [[ "$alias" == "." || "$alias" == ".." ]]; then
    printf 'reserved name'
    return 0
  fi
  upper="$(printf '%s' "$alias" | tr '[:lower:]' '[:upper:]')"
  case "$upper" in
    CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])
      printf 'reserved Windows name'
      return 0
      ;;
  esac
  if [[ "$alias" == .* && "$alias" != ".git" ]]; then
    printf 'leading dot disallowed'
    return 0
  fi
  printf ''
  return 0
}

bridge_isolation_alias_safe() {
  # Convenience wrapper: returns 0 when the alias is safe, 1 otherwise.
  local reason
  reason="$(bridge_isolation_alias_rejection_reason "$1")"
  [[ -z "$reason" ]]
}

bridge_known_marketplace_info() {
  # Return marketplace source information from known_marketplaces.json.
  #
  # Output protocol:
  #   present:<kind>\t<source-dir>\t<alias>[ \t<alias>...]
  #   missing
  #   unparseable
  #   unsafe                    (alias rejected by the safe-alias validator)
  #
  # `source-dir` is the controller-side marketplace tree to expose read-only
  # to the isolated UID. Aliases include the marketplace id plus Claude Code's
  # newer github `<org>-<repo>` clone dirname when source.repo is present.
  local marketplace_id="$1"
  local plugins_root="$2"
  local marketplaces_json="$plugins_root/known_marketplaces.json"

  bridge_require_python
  python3 - "$marketplace_id" "$plugins_root" "$marketplaces_json" <<'PY'
import json
import os
import re
import sys

marketplace_id, plugins_root, marketplaces_path = sys.argv[1:]


# Mirror of `_github_repo_slug` in bridge-dev-plugin-cache.py. Keep the
# accepted URL forms in sync — the bash side here and the dev-cache
# helper must produce identical aliases for the same input or Claude
# will land on different marketplace dirs in the controller and isolated
# trees.
_GITHUB_URL_PREFIXES = (
    "https://github.com/",
    "http://github.com/",
    "git://github.com/",
)
_GITHUB_SSH_PREFIX = "git@github.com:"


def github_repo_slug(source):
    s = (source or "").strip()
    if not s:
        return ""
    lowered = s.lower()
    matched = ""
    for prefix in _GITHUB_URL_PREFIXES:
        if lowered.startswith(prefix):
            matched = prefix
            break
    if matched:
        s = s[len(matched):]
    elif lowered.startswith(_GITHUB_SSH_PREFIX):
        s = s[len(_GITHUB_SSH_PREFIX):]
    elif "://" in s or "@" in s.split("/", 1)[0]:
        # Looks like a URL or SSH spec but not GitHub — refuse rather
        # than producing a slug like `https:-gitlab.com`.
        return ""
    elif s.startswith("/"):
        # Looks like a filesystem path — refuse so the simple-slugify
        # fallback handles the path-style input rather than producing a
        # misleading `<root>-<dir>` alias.
        return ""
    s = s.strip().strip("/")
    if s.endswith(".git"):
        s = s[: -len(".git")]
    parts = [p for p in s.split("/") if p]
    if len(parts) < 2:
        return ""
    org, repo = parts[0], parts[1]
    if not org or not repo:
        return ""
    return "%s-%s" % (org, repo)


def repo_slug(repo):
    slug = github_repo_slug(repo)
    if slug:
        return slug
    repo = (repo or "").strip().strip("/")
    if "/" not in repo:
        return ""
    return repo.replace("/", "-")


# Mirror of `_alias_rejection_reason` in bridge-dev-plugin-cache.py.
# `fullmatch` (vs `match(... + "$")`) is the security-relevant choice:
# `$` in default mode matches just before a trailing `\n`, so an alias
# like "foo\n" would otherwise slip through the regex gate. `fullmatch`
# requires the entire string to match, no trailing-newline tolerance.
_SAFE_ALIAS_RE = re.compile(r"[A-Za-z0-9._-]+")
_ALIAS_RESERVED_NAMES = {".", ".."}
_ALIAS_WINDOWS_RESERVED = (
    {"CON", "PRN", "AUX", "NUL"}
    | {"COM%d" % i for i in range(1, 10)}
    | {"LPT%d" % i for i in range(1, 10)}
)


def alias_rejection_reason(alias):
    if not isinstance(alias, str):
        return "not a string"
    if alias == "":
        return "empty"
    if len(alias) > 200:
        return "length exceeds 200"
    if not _SAFE_ALIAS_RE.fullmatch(alias):
        return "contains characters outside [A-Za-z0-9._-]"
    if ".." in alias:
        return "contains '..'"
    if alias in _ALIAS_RESERVED_NAMES:
        return "reserved name"
    if alias.upper() in _ALIAS_WINDOWS_RESERVED:
        return "reserved Windows name"
    if alias.startswith(".") and alias != ".git":
        return "leading dot disallowed"
    return ""


def emit(*parts):
    print("\t".join(parts))


if not os.path.isfile(marketplaces_path):
    emit("unparseable")
    raise SystemExit(0)

try:
    with open(marketplaces_path) as f:
        markets = json.load(f)
    if not isinstance(markets, dict):
        raise ValueError("expected JSON object")
except (OSError, ValueError):
    emit("unparseable")
    raise SystemExit(0)

entry = markets.get(marketplace_id)
if not isinstance(entry, dict):
    emit("missing")
    raise SystemExit(0)

source = entry.get("source")
kind = "other"
repo = ""
if isinstance(source, dict):
    kind = source.get("source") or "other"
    repo = source.get("repo") or ""

slug = repo_slug(repo)
aliases = []
for item in (marketplace_id, slug):
    if not item or item in aliases:
        continue
    reason = alias_rejection_reason(item)
    if reason:
        sys.stderr.write(
            "[bridge-isolate] marketplace %r alias %r rejected: %s — refusing to plant unsafe symlink\n"
            % (marketplace_id, item, reason)
        )
        emit("unsafe", "", "")
        raise SystemExit(2)
    aliases.append(item)

candidates = []
if marketplace_id:
    candidates.append(os.path.join(plugins_root, "marketplaces", marketplace_id))
if slug:
    candidates.append(os.path.join(plugins_root, "marketplaces", slug))

install_location = entry.get("installLocation")
source_path = source.get("path") if isinstance(source, dict) else ""
for candidate in (install_location, source_path):
    if not isinstance(candidate, str) or not candidate.strip():
        continue
    candidate = candidate.strip()
    # Directory-source marketplaces can point at a broad source checkout
    # (for example a repo root containing multiple plugins). Do not expose
    # that whole tree as the marketplace alias unless it is Agent Bridge's
    # own marketplace; third-party directory marketplaces should provide a
    # mirror under ~/.claude/plugins/marketplaces/<id>.
    if kind == "directory" and marketplace_id != "agent-bridge":
        continue
    candidates.append(candidate)

source_dir = ""
for candidate in candidates:
    if os.path.isdir(candidate):
        source_dir = os.path.abspath(candidate)
        break

emit("present:%s" % kind, source_dir, *aliases)
PY
}

bridge_write_isolated_known_marketplaces_catalog() {
  # Write a filtered per-UID known_marketplaces.json instead of symlinking the
  # controller's full file. This keeps undeclared marketplaces out of isolated
  # Claude's loader and rewrites installLocation/source.path to isolated-home
  # aliases that bridge controls read-only.
  local os_user="$1"
  local isolated_plugins="$2"
  local controller_plugins="$3"
  local channels_csv="$4"
  local plugins_csv="${5-}"
  local agent="${6-}"
  local catalog="$isolated_plugins/known_marketplaces.json"
  local catalog_tmp=""

  bridge_require_python
  catalog_tmp="$(bridge_linux_sudo_root mktemp "${catalog}.tmp.XXXXXX")"
  if ! bridge_linux_sudo_root python3 - "$controller_plugins" "$isolated_plugins" "$channels_csv" "$plugins_csv" "$catalog_tmp" <<'PY'
import copy
import json
import os
import re
import sys

controller_plugins, isolated_plugins, channels_csv, plugins_csv, out_path = sys.argv[1:]
markets_path = os.path.join(controller_plugins, "known_marketplaces.json")


def warn(msg):
    sys.stderr.write("[bridge-isolate] " + msg + "\n")


def fail(msg):
    sys.stderr.write("[bridge-isolate] " + msg + "\n")
    raise SystemExit(2)


# Mirror of `_github_repo_slug` in bridge-dev-plugin-cache.py. Keep
# accepted forms in sync.
_GITHUB_URL_PREFIXES = (
    "https://github.com/",
    "http://github.com/",
    "git://github.com/",
)
_GITHUB_SSH_PREFIX = "git@github.com:"


def github_repo_slug(source):
    s = (source or "").strip()
    if not s:
        return ""
    lowered = s.lower()
    matched = ""
    for prefix in _GITHUB_URL_PREFIXES:
        if lowered.startswith(prefix):
            matched = prefix
            break
    if matched:
        s = s[len(matched):]
    elif lowered.startswith(_GITHUB_SSH_PREFIX):
        s = s[len(_GITHUB_SSH_PREFIX):]
    elif "://" in s or "@" in s.split("/", 1)[0]:
        # Looks like a URL or SSH spec but not GitHub — refuse rather
        # than producing a slug like `https:-gitlab.com`.
        return ""
    elif s.startswith("/"):
        # Looks like a filesystem path — refuse so the simple-slugify
        # fallback handles the path-style input rather than producing a
        # misleading `<root>-<dir>` alias.
        return ""
    s = s.strip().strip("/")
    if s.endswith(".git"):
        s = s[: -len(".git")]
    parts = [p for p in s.split("/") if p]
    if len(parts) < 2:
        return ""
    org, repo = parts[0], parts[1]
    if not org or not repo:
        return ""
    return "%s-%s" % (org, repo)


def repo_slug(repo):
    slug = github_repo_slug(repo)
    if slug:
        return slug
    repo = (repo or "").strip().strip("/")
    if "/" not in repo:
        return ""
    return repo.replace("/", "-")


# Mirror of `_alias_rejection_reason` in bridge-dev-plugin-cache.py.
# `fullmatch` (vs `match(... + "$")`) closes the trailing-newline bypass:
# in default mode `$` matches before a trailing `\n`, so "foo\n" would
# otherwise satisfy the regex and reach the symlink-plant step. The whole
# alias must consume the entire string with no implicit newline tolerance.
_SAFE_ALIAS_RE = re.compile(r"[A-Za-z0-9._-]+")
_ALIAS_RESERVED_NAMES = {".", ".."}
_ALIAS_WINDOWS_RESERVED = (
    {"CON", "PRN", "AUX", "NUL"}
    | {"COM%d" % i for i in range(1, 10)}
    | {"LPT%d" % i for i in range(1, 10)}
)


def alias_rejection_reason(alias):
    if not isinstance(alias, str):
        return "not a string"
    if alias == "":
        return "empty"
    if len(alias) > 200:
        return "length exceeds 200"
    if not _SAFE_ALIAS_RE.fullmatch(alias):
        return "contains characters outside [A-Za-z0-9._-]"
    if ".." in alias:
        return "contains '..'"
    if alias in _ALIAS_RESERVED_NAMES:
        return "reserved name"
    if alias.upper() in _ALIAS_WINDOWS_RESERVED:
        return "reserved Windows name"
    if alias.startswith(".") and alias != ".git":
        return "leading dot disallowed"
    return ""


def marketplace_source_info(marketplace, entry):
    source = entry.get("source")
    kind = source.get("source") if isinstance(source, dict) else ""
    slug = repo_slug(str(source.get("repo") or "")) if isinstance(source, dict) else ""
    candidates = [
        os.path.join(controller_plugins, "marketplaces", marketplace),
    ]
    if slug:
        candidates.append(os.path.join(controller_plugins, "marketplaces", slug))
    for candidate in candidates:
        if os.path.isdir(candidate):
            return candidate, slug
    if marketplace == "agent-bridge":
        for candidate in (
            entry.get("installLocation"),
            source.get("path") if isinstance(source, dict) else "",
        ):
            if isinstance(candidate, str) and candidate.strip() and os.path.isdir(candidate.strip()):
                return candidate.strip(), slug
    warn("marketplace %s is declared but no controller-side mirror exists under %s/marketplaces — omitting from isolated catalog" % (marketplace, controller_plugins))
    return "", slug


def declared_marketplaces():
    declared = set()
    for raw in (channels_csv + "," + plugins_csv).split(","):
        token = raw.strip()
        if token.startswith("plugin:"):
            token = token[len("plugin:"):]
        if "@" not in token:
            continue
        _plugin, marketplace = token.split("@", 1)
        if marketplace:
            declared.add(marketplace)
    return declared


try:
    with open(markets_path) as f:
        source_markets = json.load(f)
    if not isinstance(source_markets, dict):
        raise ValueError("expected JSON object at root, got %r" % type(source_markets).__name__)
except (OSError, ValueError) as exc:
    warn("controller known_marketplaces.json unparseable (%s): %s — writing empty per-UID marketplace catalog" % (type(exc).__name__, markets_path))
    source_markets = {}

out = {}
marketplaces_root = os.path.join(isolated_plugins, "marketplaces")

# Pre-pass: validate every alias and detect collisions across declared
# marketplaces before writing anything. Two distinct marketplace ids that
# reduce to the same alias would silently overwrite each other on the
# symlink-plant step (root is the writer, so no permission failure
# stops it). Fail-loud here is the only way to surface the input bug.
alias_owners = {}  # alias -> list of marketplace ids that claim it
declared_entries = []
for marketplace in sorted(declared_marketplaces()):
    # Reject the marketplace id itself before anything else — it will
    # become an alias under marketplaces/ and an unsafe id is a
    # privilege-escalation surface (root plants the symlink).
    reason = alias_rejection_reason(marketplace)
    if reason:
        fail(
            "marketplace id %r rejected: %s — refusing to write per-UID catalog. "
            "Rename the marketplace upstream or remove it from the agent's channel/plugins set."
            % (marketplace, reason)
        )
    entry = source_markets.get(marketplace)
    if not isinstance(entry, dict):
        continue
    source_dir, slug = marketplace_source_info(marketplace, entry)
    if not source_dir:
        continue
    alias = slug or marketplace
    reason = alias_rejection_reason(alias)
    if reason:
        fail(
            "marketplace %r derived alias %r rejected: %s — refusing to write per-UID catalog"
            % (marketplace, alias, reason)
        )
    alias_owners.setdefault(alias, []).append(marketplace)
    declared_entries.append((marketplace, entry, source_dir, slug, alias))

collisions = {a: owners for a, owners in alias_owners.items() if len(owners) > 1}
if collisions:
    detail = "; ".join(
        "%r ← %s" % (alias, ", ".join(repr(o) for o in sorted(owners)))
        for alias, owners in sorted(collisions.items())
    )
    fail(
        "marketplace alias collision detected — multiple marketplaces would land at "
        "the same `marketplaces/<alias>` symlink and silently overwrite each other. "
        "Rename or namespace the colliding marketplaces upstream. Colliders: " + detail
    )

for marketplace, entry, source_dir, slug, alias in declared_entries:
    rewritten = copy.deepcopy(entry)
    source = rewritten.get("source")
    isolated_location = os.path.join(marketplaces_root, alias)
    rewritten["installLocation"] = isolated_location
    if isinstance(source, dict) and source.get("source") == "directory":
        source["path"] = isolated_location
    out[marketplace] = rewritten

with open(out_path, "w") as f:
    json.dump(out, f, indent=2)
PY
  then
    bridge_linux_sudo_root rm -f "$catalog_tmp" >/dev/null 2>&1 || true
    # Fail-loud: the catalog generator surfaces alias collisions and
    # unsafe alias inputs (regex / `..` / reserved name / control char)
    # via SystemExit(2). Silent skip would leave isolated agents running
    # against an outdated/empty catalog while the underlying input bug
    # stays hidden. Operator must rename the colliding marketplace or
    # remove the offending entry before re-running isolation prepare.
    bridge_die "bridge_write_isolated_known_marketplaces_catalog: refused to write per-UID catalog for $os_user (see [bridge-isolate] errors above)"
  fi

  bridge_linux_sudo_root chown root:root "$catalog_tmp"
  bridge_linux_sudo_root chmod 0640 "$catalog_tmp"
  if [[ -n "$agent" ]]; then
    local _v2_grp
    _v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')" \
      || _v2_grp=""
    if [[ -n "$_v2_grp" ]]; then
      bridge_linux_sudo_root chgrp "$_v2_grp" "$catalog_tmp" \
        || bridge_die "isolation v2: chgrp '$_v2_grp' on marketplace catalog '$catalog_tmp' failed"
    else
      bridge_die "isolation v2: cannot resolve agent group for marketplace catalog '$catalog_tmp'"
    fi
  else
    bridge_die "isolation v2: bridge_write_isolated_known_marketplaces_catalog requires agent id"
  fi
  bridge_linux_sudo_root mv "$catalog_tmp" "$catalog"
}

bridge_isolated_plugin_grants_state_dir() {
  # Controller-owned ledger root for plugin-share ACL grants. Keep this out
  # of $BRIDGE_ACTIVE_AGENT_DIR/<agent>: in legacy mode that path is also the
  # runtime state directory, which needs the normal isolated/controller write
  # ACL contract for agent-env.sh and session state.
  printf '%s/isolated-plugin-grants' "$BRIDGE_STATE_DIR"
}

bridge_isolated_plugin_grants_state_file() {
  # State file recording the channel set last granted plugin-share ACLs to an
  # isolated agent. Used by bridge_linux_share_plugin_catalog (to compute
  # added/removed channels across reapply) and by bridge_migration_unisolate
  # (to revoke channels the live roster may already have dropped).
  local agent="$1"
  printf '%s/%s.json' "$(bridge_isolated_plugin_grants_state_dir)" "$agent"
}

bridge_isolated_plugin_grants_legacy_state_file() {
  # v0.6.28 wrote the grant ledger under the agent runtime state directory.
  # Keep a fallback reader/remover so upgrades can revoke stale grants and
  # migrate the ledger without leaving the old file behind.
  local agent="$1"
  printf '%s/%s/isolated-plugin-grants.json' "$BRIDGE_ACTIVE_AGENT_DIR" "$agent"
}

bridge_isolated_plugin_grants_read() {
  # Read the persisted plugin-channel set for $1. Emits a CSV (channel
  # ids without the `plugin:` prefix would lose round-trip fidelity, so
  # we store the full `plugin:<id>` form). Returns the empty string when
  # the file is missing or unreadable. Channels are deduped + sorted on
  # write so callers can rely on stable ordering.
  local agent="$1"
  local state_file=""
  local legacy_state_file=""
  state_file="$(bridge_isolated_plugin_grants_state_file "$agent")"
  legacy_state_file="$(bridge_isolated_plugin_grants_legacy_state_file "$agent")"
  if bridge_linux_sudo_root test -e "$state_file"; then
    :
  elif bridge_linux_sudo_root test -e "$legacy_state_file"; then
    state_file="$legacy_state_file"
  else
    printf ''
    return 0
  fi
  bridge_require_python
  bridge_linux_sudo_root python3 - "$state_file" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (OSError, ValueError) as exc:
    sys.stderr.write(
        "[bridge-isolate] isolated-plugin-grants.json unreadable (%s): %s — treating as empty grant set\n"
        % (type(exc).__name__, path)
    )
    sys.exit(0)
channels = data.get("channels", []) if isinstance(data, dict) else []
print(",".join(c for c in channels if isinstance(c, str)))
PY
}

bridge_isolated_plugin_grants_write() {
  # Persist the channel set as JSON, root-owned 0640 so the isolated UID
  # cannot tamper with the recorded grant set (a tamper there could trick
  # a future unisolate into skipping a still-granted channel).
  local agent="$1"
  local channels_csv="$2"
  local state_file=""
  local state_dir=""
  local legacy_state_file=""
  local tmp_file=""
  state_file="$(bridge_isolated_plugin_grants_state_file "$agent")"
  state_dir="$(dirname "$state_file")"
  legacy_state_file="$(bridge_isolated_plugin_grants_legacy_state_file "$agent")"
  bridge_linux_sudo_root mkdir -p "$state_dir"
  # Place the temp file in the destination dir so the mv is always within
  # one filesystem (atomic rename); see Blocking 2 in PR #302 r1.
  tmp_file="$(bridge_linux_sudo_root mktemp "${state_file}.tmp.XXXXXX")"
  bridge_require_python
  bridge_linux_sudo_root python3 - "$tmp_file" "$channels_csv" <<'PY'
import json, sys
out_path, csv = sys.argv[1], sys.argv[2]
channels = sorted({c.strip() for c in csv.split(",") if c.strip()})
with open(out_path, "w") as f:
    json.dump({"channels": channels}, f, indent=2)
PY
  bridge_linux_sudo_root mv "$tmp_file" "$state_file"
  bridge_linux_sudo_root chown root:root "$state_file"
  bridge_linux_sudo_root chmod 0640 "$state_file"
  bridge_linux_sudo_root chown root:root "$state_dir" >/dev/null 2>&1 || true
  bridge_linux_sudo_root chmod 0750 "$state_dir" >/dev/null 2>&1 || true
  if [[ "$legacy_state_file" != "$state_file" ]]; then
    bridge_linux_sudo_root rm -f "$legacy_state_file" >/dev/null 2>&1 || true
  fi
}

bridge_isolated_plugin_grants_remove() {
  # Delete the persisted grant-set file (called from unisolate after the
  # ACL strip completes successfully).
  local agent="$1"
  local state_file=""
  local legacy_state_file=""
  state_file="$(bridge_isolated_plugin_grants_state_file "$agent")"
  legacy_state_file="$(bridge_isolated_plugin_grants_legacy_state_file "$agent")"
  if bridge_linux_sudo_root test -e "$state_file"; then
    bridge_linux_sudo_root rm -f "$state_file" >/dev/null 2>&1 || true
  fi
  if [[ "$legacy_state_file" != "$state_file" ]] \
      && bridge_linux_sudo_root test -e "$legacy_state_file"; then
    bridge_linux_sudo_root rm -f "$legacy_state_file" >/dev/null 2>&1 || true
  fi
}

bridge_linux_revoke_plugin_channel_grants() {
  # v2 hard-cut: per-agent group + setgid layout has no named-user ACL grants
  # to revoke; the per-channel strip step in unisolate is now handled entirely
  # by group-membership teardown. Retained as a no-op stub so existing callers
  # (bridge_migration_unisolate, reapply path) link cleanly.
  return 0
}

bridge_write_isolated_installed_plugins_manifest() {
  # Write a per-isolated-UID installed_plugins.json containing only the
  # plugins this agent declared via BRIDGE_AGENT_CHANNELS (transport
  # plugins) and BRIDGE_AGENT_PLUGINS (#272 per-agent allowlist of
  # non-channel domain plugins), with installPath rewritten to the
  # actually-existing location resolved by
  # bridge_resolve_plugin_install_path. The file is owned by root so the
  # isolated UID cannot tamper with which plugins it loads.
  #
  # Arguments:
  #   os_user             — isolated UID
  #   isolated_plugins    — destination ~/.claude/plugins root for the UID
  #   controller_plugins  — controller's ~/.claude/plugins (read-only source)
  #   channels_csv        — CSV of `plugin:<id>` (and other) channel tokens
  #   plugins_csv         — CSV of bare `<id>` (or `<id>@<mkt>`) tokens from
  #                         BRIDGE_AGENT_PLUGINS["<agent>"]; may be empty.
  #   agent               — agent id (PR-E: required to resolve the v2 group
  #                         for chgrp ab-agent-<name>). Optional in legacy
  #                         mode for backwards compatibility.
  local os_user="$1"
  local isolated_plugins="$2"
  local controller_plugins="$3"
  local channels_csv="$4"
  local plugins_csv="${5-}"
  local agent="${6-}"
  local manifest="$isolated_plugins/installed_plugins.json"
  local manifest_tmp=""

  bridge_require_python
  # Place the temp file in the destination dir so the subsequent mv is
  # always within one filesystem and therefore an atomic rename. Plain
  # mktemp(1) honours $TMPDIR, which can land on /tmp while $manifest is
  # under /home/<user>/.claude/plugins/ — across mounts mv degrades to
  # copy+unlink and a concurrent reader can see a half-written or
  # transiently missing manifest. (Blocking 2 in PR #302 r1.)
  manifest_tmp="$(bridge_linux_sudo_root mktemp "${manifest}.tmp.XXXXXX")"
  if ! bridge_linux_sudo_root python3 - "$controller_plugins" "$isolated_plugins" "$channels_csv" "$manifest_tmp" "$plugins_csv" <<'PY'
import json, os, re, sys

controller_plugins, isolated_plugins, channels_csv, out_path, plugins_csv = sys.argv[1:]
controller_manifest = os.path.join(controller_plugins, "installed_plugins.json")
markets_path = os.path.join(controller_plugins, "known_marketplaces.json")


def warn(msg):
    sys.stderr.write("[bridge-isolate] " + msg + "\n")


# Mirror of `_alias_rejection_reason` in bridge-dev-plugin-cache.py.
# `fullmatch` (vs `match(... + "$")`) closes the trailing-newline bypass.
# In the normal share flow upstream gates already validate marketplace
# id and slug aliases before this helper runs; the validator here is
# defense-in-depth for the path components this helper itself joins
# (`isolated_plugins/cache/<marketplace>/<plugin>/<version>`). An
# unsafe component reaching here means an upstream gate failed; we
# refuse the lookup rather than silently reading from a poisoned path.
_SAFE_ALIAS_RE = re.compile(r"[A-Za-z0-9._-]+")
_ALIAS_RESERVED_NAMES = {".", ".."}
_ALIAS_WINDOWS_RESERVED = (
    {"CON", "PRN", "AUX", "NUL"}
    | {"COM%d" % i for i in range(1, 10)}
    | {"LPT%d" % i for i in range(1, 10)}
)


def alias_rejection_reason(alias):
    if not isinstance(alias, str):
        return "not a string"
    if alias == "":
        return "empty"
    if len(alias) > 200:
        return "length exceeds 200"
    if not _SAFE_ALIAS_RE.fullmatch(alias):
        return "contains characters outside [A-Za-z0-9._-]"
    if ".." in alias:
        return "contains '..'"
    if alias in _ALIAS_RESERVED_NAMES:
        return "reserved name"
    if alias.upper() in _ALIAS_WINDOWS_RESERVED:
        return "reserved Windows name"
    if alias.startswith(".") and alias != ".git":
        return "leading dot disallowed"
    return ""


# Distinguish "controller manifest exists but is corrupt" (operator-
# actionable; refuse to proceed for that plugin entry) from "controller
# manifest absent" (legitimate — fresh install or pre-plugin Claude;
# directory-marketplace fallback is acceptable).
source = {}
manifest_present = os.path.isfile(controller_manifest)
if manifest_present:
    try:
        with open(controller_manifest) as f:
            source = json.load(f)
        if not isinstance(source, dict):
            raise ValueError("expected JSON object at root, got %r" % type(source).__name__)
    except (OSError, ValueError) as exc:
        warn(
            "controller installed_plugins.json unparseable (%s): %s — refusing to write per-UID manifest"
            % (type(exc).__name__, controller_manifest)
        )
        sys.exit(2)

markets = {}
if os.path.isfile(markets_path):
    try:
        with open(markets_path) as f:
            markets = json.load(f)
        if not isinstance(markets, dict):
            raise ValueError("expected JSON object at root, got %r" % type(markets).__name__)
    except (OSError, ValueError) as exc:
        # Marketplace data missing/corrupt is informational: the manifest
        # write can still succeed for entries whose installPath is valid
        # in the controller manifest. The directory-marketplace fallback
        # is the only thing we lose.
        warn(
            "controller known_marketplaces.json unparseable (%s): %s — directory-marketplace fallback disabled"
            % (type(exc).__name__, markets_path)
        )
        markets = {}


def directory_marketplace_path(plugin_id):
    if "@" not in plugin_id:
        return ""
    plugin_name, marketplace = plugin_id.split("@", 1)
    # Defense-in-depth: plugin_name is about to be joined into a path.
    # marketplace is used only as a dict key so doesn't need path-safety,
    # but reject it too — an unsafe id here means an upstream parser bug.
    for role, value in (("plugin name", plugin_name), ("marketplace id", marketplace)):
        reason = alias_rejection_reason(value)
        if reason:
            sys.stderr.write(
                "[bridge-isolate] directory_marketplace_path rejected %s %r (plugin_id=%r): %s\n"
                % (role, value, plugin_id, reason)
            )
            raise SystemExit(2)
    entry = markets.get(marketplace, {})
    if not isinstance(entry, dict):
        return ""
    candidate = ""
    src = entry.get("source")
    # Risk 2 (PR #302 r1): match bridge_resolve_plugin_install_path —
    # only fall back for directory-source marketplaces.
    if isinstance(src, dict) and src.get("source") == "directory":
        candidate = src.get("path", "") or entry.get("installLocation", "")
    if not candidate:
        return ""
    guess = os.path.join(candidate, "plugins", plugin_name)
    return guess if os.path.isdir(guess) else ""


def isolated_cache_path(plugin_id, entry):
    if "@" not in plugin_id:
        return ""
    plugin_name, marketplace = plugin_id.split("@", 1)
    version = str((entry or {}).get("version") or "").strip()
    if not version:
        install_path = str((entry or {}).get("installPath") or "").rstrip("/")
        version = os.path.basename(install_path)
    if not version:
        return ""
    # Defense-in-depth: every component is about to be joined into
    # `<isolated_plugins>/cache/<marketplace>/<plugin>/<version>`. An
    # unsafe component (newline / `..` / slash) could escape the cache
    # root; in the normal share flow the catalog writer already filters
    # marketplace ids upstream, but this helper runs separately and must
    # hold the gate on its own. Fail loud — silently returning "" would
    # mask an upstream bug.
    for role, value in (
        ("marketplace id", marketplace),
        ("plugin name", plugin_name),
        ("plugin version", version),
    ):
        reason = alias_rejection_reason(value)
        if reason:
            sys.stderr.write(
                "[bridge-isolate] isolated_cache_path rejected %s %r (plugin_id=%r): %s\n"
                % (role, value, plugin_id, reason)
            )
            raise SystemExit(2)
    candidate = os.path.join(isolated_plugins, "cache", marketplace, plugin_name, version)
    return candidate if os.path.isdir(candidate) else ""


def resolve(plugin_id):
    # Preserve controller entry metadata (version, gitCommitSha, etc.) when
    # we can; only rewrite installPath if it is missing or stale.
    for entry in source.get("plugins", {}).get(plugin_id, []):
        isolated_path = isolated_cache_path(plugin_id, entry)
        if isolated_path:
            return entry, isolated_path
        ip = entry.get("installPath")
        if ip and os.path.isdir(ip):
            return entry, ip
        fallback = directory_marketplace_path(plugin_id)
        if fallback:
            return entry, fallback
    fallback = directory_marketplace_path(plugin_id)
    if fallback:
        return {"scope": "user", "installPath": fallback}, fallback
    return None, None


declared = set()
for chan in channels_csv.split(","):
    chan = chan.strip()
    if chan.startswith("plugin:"):
        declared.add(chan[len("plugin:"):])

# BRIDGE_AGENT_PLUGINS allowlist (#272) — bare plugin ids, optionally
# `<plugin>@<marketplace>`. Merged here so the isolated manifest covers
# the union of channel-declared transport plugins AND domain plugins
# the operator allowlisted per-agent. Dedupe via the shared `declared`
# set so an entry that lives in both arrays appears once. (#348)
for token in plugins_csv.split(","):
    token = token.strip()
    if token.startswith("plugin:"):
        token = token[len("plugin:"):]
    if token:
        declared.add(token)

out = {"version": source.get("version", 2), "plugins": {}}
for plugin_id in sorted(declared):
    entry, real_path = resolve(plugin_id)
    if not entry or not real_path:
        continue
    new_entry = dict(entry)
    new_entry["installPath"] = real_path
    out["plugins"][plugin_id] = [new_entry]

with open(out_path, "w") as f:
    json.dump(out, f, indent=2)
PY
  then
    bridge_linux_sudo_root rm -f "$manifest_tmp" >/dev/null 2>&1 || true
    # Fail-loud: SystemExit(2) covers both controller-state-unparseable
    # and the new defense-in-depth path-component rejection in
    # `directory_marketplace_path`/`isolated_cache_path`. The Python
    # heredoc emits a `[bridge-isolate]` stderr line naming the offending
    # component before exiting; surface that to the operator log.
    bridge_warn "bridge_write_isolated_installed_plugins_manifest: refused to write per-UID manifest for $os_user (see [bridge-isolate] errors above; either controller state unparseable or a path component failed safe-alias gate)"
    return 1
  fi

  # Set final ownership/perm/ACL on the temp file BEFORE the atomic rename
  # so the destination never exists with the wrong metadata even
  # momentarily. Readers see either the previous manifest or the new one
  # with correct ownership/perm/ACL — never an in-between state.
  # (Blocking 2 in PR #302 r2.)
  bridge_linux_sudo_root chown root:root "$manifest_tmp"
  bridge_linux_sudo_root chmod 0640 "$manifest_tmp"
  # v2: chgrp ab-agent-<name>. The isolated UID is a member of that group
  # (PR-C ensure_user_in_group) and the manifest mode 0640 grants group r--.
  # Owner stays root so the agent cannot tamper with which plugins it loads.
  if [[ -n "$agent" ]]; then
    local _v2_grp
    _v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')" \
      || _v2_grp=""
    if [[ -n "$_v2_grp" ]]; then
      bridge_linux_sudo_root chgrp "$_v2_grp" "$manifest_tmp" \
        || bridge_die "isolation v2: chgrp '$_v2_grp' on manifest '$manifest_tmp' failed"
    else
      bridge_die "isolation v2: cannot resolve agent group for manifest '$manifest_tmp'"
    fi
  else
    bridge_die "isolation v2: bridge_write_isolated_installed_plugins_manifest requires agent id (PR-E signature change)"
  fi
  bridge_linux_sudo_root mv "$manifest_tmp" "$manifest"
}

bridge_linux_share_plugin_catalog() {
  # Channel-ownership-aware plugin sharing for an isolated agent.
  # Grants the isolated UID read-only access to:
  #   - the controller's catalog metadata files (audit-level disclosure),
  #   - a per-UID generated installed_plugins.json that only lists the
  #     plugins declared in BRIDGE_AGENT_CHANNELS for this agent,
  #   - each declared plugin's install-path tree, with a traverse chain
  #     up to the controller home (#233 stop guard).
  # Leaves the isolated UID's plugins/ root and the per-UID manifest
  # root-owned (the agent cannot tamper with what it loads), and leaves
  # plugins/data/ writable so plugins can persist runtime state.
  #
  # Reapply contract: the helper is rerun on every isolate refresh. To
  # keep the isolation boundary tight, the previously-granted channel
  # set is persisted under a root-owned controller ledger and diffed
  # against the current channels — channels removed from the roster
  # have their ACLs and catalog symlinks revoked here, not just at
  # unisolate. (Blocking 1 in PR #302 r1.)
  local os_user="$1"
  local user_home="$2"
  local controller_user="$3"
  local agent="$4"

  local controller_home=""
  # Test-only seam: BRIDGE_CONTROLLER_HOME_OVERRIDE replaces the getent
  # passwd lookup so the regression test in tests/isolation-plugin-sharing.sh
  # can drive the helper against a fake controller plugin tree without
  # touching the operator's real ~/.claude/plugins/. The override is
  # ignored unless BRIDGE_HOME points under a recognised tempdir prefix
  # (/tmp, /var/tmp, or $TMPDIR), which guards against accidental
  # production use.
  if [[ -n "${BRIDGE_CONTROLLER_HOME_OVERRIDE:-}" ]]; then
    local _override_ok=0
    local _bridge_home_norm="${BRIDGE_HOME:-}"
    case "$_bridge_home_norm" in
      /tmp/*|/var/tmp/*) _override_ok=1 ;;
    esac
    if [[ "$_override_ok" -eq 0 && -n "${TMPDIR:-}" ]]; then
      local _tmpdir_trimmed="${TMPDIR%/}"
      case "$_bridge_home_norm" in
        "$_tmpdir_trimmed"/*) _override_ok=1 ;;
      esac
    fi
    if [[ "$_override_ok" -eq 1 ]]; then
      controller_home="$BRIDGE_CONTROLLER_HOME_OVERRIDE"
    else
      bridge_warn "bridge_linux_share_plugin_catalog: ignoring BRIDGE_CONTROLLER_HOME_OVERRIDE because BRIDGE_HOME is not under a tempdir prefix (got '${BRIDGE_HOME:-<unset>}')"
    fi
  fi
  if [[ -z "$controller_home" ]]; then
    controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  fi

  # Resolve the canonical Claude plugins root for this share pass:
  #   1. v2 layout (BRIDGE_LAYOUT=v2 + populated BRIDGE_SHARED_ROOT/plugins-cache)
  #      takes precedence — migrated installs may have no controller_home/.claude/plugins
  #      directory at all, so the legacy-only guard would silently no-op the
  #      whole isolated-share pipeline (manifest write, marketplace symlinks,
  #      per-plugin grants) and the agent would start with no MCP servers.
  #   2. Legacy controller_home/.claude/plugins as fallback.
  #   3. Neither present → no-op (return 0).
  #
  # The v2 root contract is encapsulated in
  # `bridge_isolation_v2_shared_plugins_root` (see lib/bridge-isolation-v2.sh).
  # This function consumes that helper directly so the path lives in one
  # place. controller_home is still recorded for the traverse-chain helper
  # below — for v2 paths that live outside controller_home the traverse
  # walk no-ops, which is intentional (group-mediated access takes over
  # from named-ACL traversal once the operator migrates).
  local controller_plugins=""
  if controller_plugins="$(bridge_isolation_v2_shared_plugins_root 2>/dev/null)"; then
    :
  else
    # v2 hard-cut: shared plugin cache is the only supported source of plugin
    # catalog metadata. The legacy controller_home/.claude/plugins fallback is
    # unsafe in v2 because the per-agent group has no traverse path under
    # controller_home. BUT: if the agent has nothing to share (empty channel-plugin
    # union and empty plugin allowlist), there is no symlink to plant and no
    # manifest to write. Codex / no-plugin Claude agents must not be blocked
    # by an empty cache. Compute the union here and short-circuit before
    # failing loud.
    local _v2_pcg_channels="" _v2_pcg_plugins=""
    _v2_pcg_channels="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
    _v2_pcg_plugins="$(bridge_agent_plugins_csv "$agent" 2>/dev/null || true)"
    # plugin-shaped channels are `plugin:<id>`; non-plugin channels
    # (discord, telegram, ms365) do not need this catalog at all.
    if [[ "$_v2_pcg_channels" != *plugin:* ]] \
        && [[ -z "$_v2_pcg_plugins" ]]; then
      return 0
    fi
    bridge_die "isolation v2 plugin catalog: \$BRIDGE_SHARED_ROOT/plugins-cache is not populated (no installed_plugins.json) but agent '$agent' declares plugin: channels or BRIDGE_AGENT_PLUGINS allowlist entries. Run \`agb plugins seed\` to populate the shared plugin catalog from the bundled agent-bridge marketplace, then retry. (For an external marketplace: \`agb plugins seed --marketplace-root <path>\`.)"
  fi

  local isolated_plugins="$user_home/.claude/plugins"

  # Resolve the v2 agent group once for plugin root + marketplaces + manifest writer.
  local _v2_grp=""
  _v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')" \
    || _v2_grp=""
  [[ -n "$_v2_grp" ]] || bridge_die "isolation v2: cannot resolve agent group for plugin catalog of '$agent'"

  # 1. plugins/ root: root-owned, group-traversable + group-writable.
  #    chown root:ab-agent-<name>, chmod 2770. Issue #864 R3: the dev-
  #    plugin-cache sync (`bridge-dev-plugin-cache.py` invoked under the
  #    isolated UID via the bridge-start.sh sudo wrap) needs to take a
  #    flock on `installed_plugins.json.lock` here. Mode 2750 (group
  #    r-x only, no write) caused flock() to EACCES and aborted launch
  #    with `channel-required plugin cache failed`. 2770 gives the
  #    agent's own group write access so flock + manifest merge work;
  #    the setgid bit is preserved so new children inherit
  #    ab-agent-<name>.
  bridge_linux_sudo_root mkdir -p "$isolated_plugins"
  bridge_linux_sudo_root chown "root:${_v2_grp}" "$isolated_plugins" \
    || bridge_die "isolation v2: chown root:${_v2_grp} on '$isolated_plugins' failed"
  bridge_linux_sudo_root chmod 2770 "$isolated_plugins" \
    || bridge_die "isolation v2: chmod 2770 on '$isolated_plugins' failed"

  # 2. plugins/data/: isolated UID owns this so plugin runtime state writes work.
  local os_group=""
  os_group="$(id -gn "$os_user" 2>/dev/null || printf '%s' "$os_user")"
  bridge_linux_sudo_root mkdir -p "$isolated_plugins/data"
  bridge_linux_sudo_root chown "$os_user:$os_group" "$isolated_plugins/data"
  bridge_linux_sudo_root chmod 0700 "$isolated_plugins/data"

  local channels_csv=""
  local plugins_csv=""
  channels_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
  plugins_csv="$(bridge_agent_plugins_csv "$agent" 2>/dev/null || true)"

  # 3. Read-only catalog metadata symlinks. Always remove the prior dst
  #    first (independent of source presence) so a controller-side delete
  #    invalidates the isolated symlink rather than leaving it dangling at
  #    a now-stale target. (Risk 1 in PR #302 r1.)
  #
  #    known_marketplaces.json is intentionally excluded from this symlink
  #    loop. Claude Code now tries to clone every visible marketplace when
  #    rendering `/plugin`; exposing the controller's full marketplace file
  #    makes isolated agents attempt writes under their root-owned
  #    marketplaces/ dir. Step 4 writes a filtered per-UID copy instead.
  local catalog_file=""
  local src=""
  local dst=""
  for catalog_file in "${BRIDGE_ISOLATION_SHARED_CATALOG_READ_FILES[@]}"; do
    [[ "$catalog_file" == "known_marketplaces.json" ]] && continue
    src="$controller_plugins/$catalog_file"
    dst="$isolated_plugins/$catalog_file"
    bridge_linux_sudo_root rm -f "$dst" >/dev/null 2>&1 || true
    [[ -e "$src" ]] || continue
    bridge_linux_sudo_root ln -s "$src" "$dst"
    bridge_linux_sudo_root chown -h root:root "$dst" >/dev/null 2>&1 || true
    # v2: shared-plugins-cache root is base-readable (`other::r-x`); no
    # named-user ACL needed. Group r-X on the source dir + setgid layout
    # already covers the isolated UID.
  done

  # 4. Filtered per-UID known_marketplaces.json — declared marketplaces only,
  #    with installLocation/source.path rewritten to isolated-home aliases.
  bridge_write_isolated_known_marketplaces_catalog \
    "$os_user" "$isolated_plugins" "$controller_plugins" \
    "$channels_csv" "$plugins_csv" "$agent"

  # 5. Per-UID installed_plugins.json — declared plugins only (union of
  #    BRIDGE_AGENT_CHANNELS plugin entries and BRIDGE_AGENT_PLUGINS allowlist
  #    per #348 / #272), real install paths.
  bridge_write_isolated_installed_plugins_manifest \
    "$os_user" "$isolated_plugins" "$controller_plugins" \
    "$channels_csv" "$plugins_csv" "$agent"

  # 6. Compute the channel diff against the persisted grant set so we can
  #    revoke channels that were previously granted but are no longer in
  #    the roster (Blocking 1 in PR #302 r1). The "current" set is the
  #    union of BRIDGE_AGENT_CHANNELS `plugin:<id>` tokens and
  #    BRIDGE_AGENT_PLUGINS bare ids (#348). Allowlist entries are
  #    promoted to `plugin:<id>` form here so they share the same
  #    persisted-state shape and revoke pipeline as channel-declared
  #    plugins. Non-plugin channel tokens are ignored on both sides.
  local prior_channels_csv=""
  prior_channels_csv="$(bridge_isolated_plugin_grants_read "$agent" 2>/dev/null || true)"
  local -a _current_plugin_channels=()
  local -a _prior_plugin_channels=()
  local _seen_marker=$'\x1f'
  local _seen=""
  if [[ -n "$channels_csv" ]]; then
    local _cur_split=()
    local _cur_chan=""
    IFS=',' read -ra _cur_split <<<"$channels_csv"
    for _cur_chan in "${_cur_split[@]}"; do
      _cur_chan="${_cur_chan// /}"
      [[ "$_cur_chan" == plugin:* ]] || continue
      case "$_seen" in
        *"${_seen_marker}${_cur_chan}${_seen_marker}"*) continue ;;
      esac
      _seen="${_seen}${_seen_marker}${_cur_chan}${_seen_marker}"
      _current_plugin_channels+=("$_cur_chan")
    done
  fi
  if [[ -n "$plugins_csv" ]]; then
    local _plg_split=()
    local _plg_token=""
    local _plg_full=""
    IFS=',' read -ra _plg_split <<<"$plugins_csv"
    for _plg_token in "${_plg_split[@]}"; do
      _plg_token="${_plg_token// /}"
      [[ -n "$_plg_token" ]] || continue
      _plg_full="plugin:${_plg_token}"
      case "$_seen" in
        *"${_seen_marker}${_plg_full}${_seen_marker}"*) continue ;;
      esac
      _seen="${_seen}${_seen_marker}${_plg_full}${_seen_marker}"
      _current_plugin_channels+=("$_plg_full")
    done
  fi
  if [[ -n "$prior_channels_csv" ]]; then
    local _prior_split=()
    local _prior_chan=""
    IFS=',' read -ra _prior_split <<<"$prior_channels_csv"
    for _prior_chan in "${_prior_split[@]}"; do
      _prior_chan="${_prior_chan// /}"
      [[ "$_prior_chan" == plugin:* ]] || continue
      _prior_plugin_channels+=("$_prior_chan")
    done
  fi

  # 6a. Revoke removed entries (in prior set but not in current set).
  #     This covers both channel removals and BRIDGE_AGENT_PLUGINS
  #     removals — both are persisted in the same `plugin:<id>` form.
  local _prior_entry=""
  local _cur_entry=""
  local _found=0
  for _prior_entry in "${_prior_plugin_channels[@]+"${_prior_plugin_channels[@]}"}"; do
    _found=0
    for _cur_entry in "${_current_plugin_channels[@]+"${_current_plugin_channels[@]}"}"; do
      [[ "$_cur_entry" == "$_prior_entry" ]] && { _found=1; break; }
    done
    if [[ "$_found" -eq 0 ]]; then
      bridge_linux_revoke_plugin_channel_grants \
        "$os_user" "${_prior_entry#plugin:}" "$controller_plugins" "$controller_home"
    fi
  done

  # 6b. v2: plugin install paths live under the shared plugins cache
  # (group ab-shared, base-readable), so the isolated UID reaches them
  # via group r-x without any per-plugin named-user ACL or traverse-chain
  # grant. Iterate the channels purely so the persisted grant-set in step
  # 6c stays accurate.
  local channel=""
  local plugin_id=""
  local install_path=""
  for channel in "${_current_plugin_channels[@]+"${_current_plugin_channels[@]}"}"; do
    plugin_id="${channel#plugin:}"
    install_path="$(bridge_resolve_plugin_install_path "$plugin_id" "$controller_plugins")"
    [[ -n "$install_path" && -d "$install_path" ]] || continue
  done

  # 6b'. Marketplace symlinks (#348). For every union plugin in
  #     `<plugin>@<marketplace>` form whose marketplace is registered
  #     in the controller's `known_marketplaces.json` AND whose mirror
  #     tree exists at `~/.claude/plugins/marketplaces/<marketplace>`,
  #     plant a read-only symlink under the isolated UID's plugins root
  #     so Claude can resolve the marketplace reference recorded in
  #     installed_plugins.json. The `known_marketplaces.json` lookup is
  #     the source-of-truth gate (matches the issue spec wording and the
  #     manifest writer's :1092 / `:894` directory-source fallback);
  #     the on-disk `marketplaces/<mkt>` dir is the symlink target, so
  #     git-source marketplaces whose tree has not been cached yet
  #     silently skip rather than synthesising a broken symlink.
  #     Symlink + traverse + recursive r-X mirrors the channel install-
  #     path pattern (5b). (#348 r2.)
  local _isolated_marketplaces="$isolated_plugins/marketplaces"
  local _marketplaces_root_created=0
  local _mkt_seen=""
  local _channel_full=""
  local _mkt_id=""
  local _mkt_src=""
  local _mkt_dst=""
  local _mkt_info=""
  local _mkt_status=""
  local _mkt_alias=""
  local _mkt_alias_reason=""
  local -a _mkt_info_parts=()
  local _mkt_block_disabled=0
  # Collision-detection ledger for the symlink pre-pass. Each alias keeps
  # a `\x1f`-separated list of marketplace ids that resolved to it; if
  # any list grows past one entry, we fail loudly before planting any
  # symlink. Without this gate, two marketplace ids that reduce to the
  # same alias (e.g. `foo/bar-baz` and `foo-bar/baz` both → `foo-bar-baz`)
  # would silently overwrite each other under the root-owned
  # marketplaces/ dir — the catalog would end up pointing the wrong repo
  # for one of them with zero error signal.
  local _alias_collision_marker=$'\x1f'
  declare -A _alias_owners=()
  declare -A _mkt_resolved_src=()
  declare -A _mkt_resolved_aliases=()
  local _alias_collision_detail=""
  local -a _mkt_unique_ids=()
  bridge_linux_sudo_root bash -c "if [[ -d \"$_isolated_marketplaces\" || -L \"$_isolated_marketplaces\" ]]; then shopt -s nullglob dotglob; for entry in \"$_isolated_marketplaces\"/*; do [[ -L \"\$entry\" ]] && rm -f \"\$entry\"; done; fi" >/dev/null 2>&1 || true

  # Pass 1 — discovery + validation. Collect (mkt_id, src, aliases) for
  # every unique marketplace the agent declares, validate each alias
  # (defense in depth: bridge_known_marketplace_info also rejects unsafe
  # aliases), and build the alias-owner map for collision detection.
  for _channel_full in "${_current_plugin_channels[@]+"${_current_plugin_channels[@]}"}"; do
    (( _mkt_block_disabled == 0 )) || break
    plugin_id="${_channel_full#plugin:}"
    [[ "$plugin_id" == *@* ]] || continue
    _mkt_id="${plugin_id#*@}"
    [[ -n "$_mkt_id" ]] || continue
    case "$_mkt_seen" in
      *"${_seen_marker}${_mkt_id}${_seen_marker}"*) continue ;;
    esac
    _mkt_seen="${_mkt_seen}${_seen_marker}${_mkt_id}${_seen_marker}"
    # Source-of-truth gate: marketplace must be registered in
    # known_marketplaces.json. The helper also returns Claude Code's newer
    # github repo-slug alias (`org-repo`) so bridge can preplant both names
    # without making the isolated marketplaces/ root writable.
    _mkt_info="$(bridge_known_marketplace_info "$_mkt_id" "$controller_plugins")" || {
      # The Python helper exits 2 when an alias fails the safety check.
      # Surface that as a fail-loud condition rather than a silent skip:
      # an unsafe alias is operator input that escapes the marketplaces/
      # namespace under root's write authority.
      bridge_die "marketplace ${_mkt_id}: known_marketplaces.json lookup rejected an unsafe alias (see [bridge-isolate] errors above). Refusing to plant any marketplace symlink for this agent until the input is fixed."
    }
    IFS=$'\t' read -r -a _mkt_info_parts <<<"$_mkt_info"
    _mkt_status="${_mkt_info_parts[0]:-}"
    _mkt_src="${_mkt_info_parts[1]:-}"
    case "$_mkt_status" in
      unparseable)
        _mkt_block_disabled=1
        break
        ;;
      unsafe)
        # Defense in depth: the helper also exits 0 with `unsafe` when
        # the safety check trips. Treat it the same as the SystemExit(2)
        # path above.
        bridge_die "marketplace ${_mkt_id}: known_marketplaces.json carries an unsafe alias (see [bridge-isolate] errors above)."
        ;;
      missing|"")
        # marketplace not registered → silent skip, no broken symlink.
        continue
        ;;
      present:*) ;;  # fall through to the symlink path
      *) continue ;;
    esac
    # Even when known_marketplaces.json carries an entry, the on-disk
    # mirror tree may not yet exist (common for git-source marketplaces
    # on a fresh checkout, or directory-source marketplaces whose cache
    # has been pruned). Surface a warn so operators can act on the
    # diagnostic — the alternative is silent plugin drop at session
    # start with zero log signal (#362).
    if [[ ! -d "$_mkt_src" ]]; then
      bridge_warn "marketplace ${_mkt_id} is in known_marketplaces.json but the controller-side tree at ${_mkt_src} is missing — declared plugins from this marketplace will not load. Operator must run \`/plugin marketplace add\` once with credentials, then re-run isolation prepare."
      continue
    fi
    # Defense-in-depth alias validation. The Python helper rejected
    # unsafe aliases above; if a future caller bypasses that path the
    # symlink loop must still refuse to plant a name that escapes the
    # marketplaces/ namespace.
    local _mkt_alias_list=""
    for _mkt_alias in "${_mkt_info_parts[@]:2}"; do
      [[ -n "$_mkt_alias" ]] || continue
      _mkt_alias_reason="$(bridge_isolation_alias_rejection_reason "$_mkt_alias")"
      if [[ -n "$_mkt_alias_reason" ]]; then
        bridge_die "marketplace ${_mkt_id}: alias '${_mkt_alias}' rejected (${_mkt_alias_reason}). Refusing to plant unsafe symlink under ${_isolated_marketplaces}/."
      fi
      # Append owner to the per-alias ledger.
      local _existing="${_alias_owners[$_mkt_alias]:-}"
      if [[ -n "$_existing" ]]; then
        _alias_owners[$_mkt_alias]="${_existing}${_alias_collision_marker}${_mkt_id}"
      else
        _alias_owners[$_mkt_alias]="${_mkt_id}"
      fi
      if [[ -n "$_mkt_alias_list" ]]; then
        _mkt_alias_list="${_mkt_alias_list}${_alias_collision_marker}${_mkt_alias}"
      else
        _mkt_alias_list="$_mkt_alias"
      fi
    done
    if [[ -z "$_mkt_alias_list" ]]; then
      # No usable alias — bridge_known_marketplace_info already filters
      # this case (the marketplace id itself goes in first), but guard
      # anyway so downstream pass-2 always has at least one alias.
      continue
    fi
    _mkt_resolved_src[$_mkt_id]="$_mkt_src"
    _mkt_resolved_aliases[$_mkt_id]="$_mkt_alias_list"
    _mkt_unique_ids+=("$_mkt_id")
  done

  # Pass 1.5 — collision detection. Two distinct marketplace ids that
  # reduce to the same alias would each plant a symlink at
  # `<isolated>/marketplaces/<alias>`; the second `ln -s` (with `rm -f`
  # in front) silently overwrites the first under root's write authority,
  # so the catalog ends up pointing the wrong source for one of them.
  # Fail-loud listing every collider lets the operator rename or
  # namespace upstream rather than chase a silent misroute.
  if (( ${#_alias_owners[@]} > 0 )); then
    local _coll_alias=""
    for _coll_alias in "${!_alias_owners[@]}"; do
      local _coll_owners="${_alias_owners[$_coll_alias]}"
      if [[ "$_coll_owners" == *"${_alias_collision_marker}"* ]]; then
        local _coll_pretty="${_coll_owners//${_alias_collision_marker}/, }"
        if [[ -n "$_alias_collision_detail" ]]; then
          _alias_collision_detail="${_alias_collision_detail}; '${_coll_alias}' ← ${_coll_pretty}"
        else
          _alias_collision_detail="'${_coll_alias}' ← ${_coll_pretty}"
        fi
      fi
    done
  fi
  if [[ -n "$_alias_collision_detail" ]]; then
    bridge_die "marketplace alias collision detected — multiple marketplaces would land at the same '<isolated>/marketplaces/<alias>' symlink and silently overwrite each other under root's write authority. Rename or namespace the colliding marketplaces upstream. Colliders: ${_alias_collision_detail}"
  fi

  # Pass 2 — plant symlinks + ACLs. By this point every (mkt_id, src,
  # alias) triple has been validated and proven collision-free.
  for _mkt_id in "${_mkt_unique_ids[@]+"${_mkt_unique_ids[@]}"}"; do
    _mkt_src="${_mkt_resolved_src[$_mkt_id]}"
    if (( _marketplaces_root_created == 0 )); then
      bridge_linux_sudo_root mkdir -p "$_isolated_marketplaces"
      # v2: same group-mode contract as the plugins/ root above —
      # root:ab-agent-<name> 2750 + setgid for new children.
      bridge_linux_sudo_root chown "root:${_v2_grp}" "$_isolated_marketplaces" \
        || bridge_die "isolation v2: chown root:${_v2_grp} on '$_isolated_marketplaces' failed"
      bridge_linux_sudo_root chmod 2750 "$_isolated_marketplaces" \
        || bridge_die "isolation v2: chmod 2750 on '$_isolated_marketplaces' failed"
      _marketplaces_root_created=1
    fi
    local -a _alias_arr=()
    IFS="${_alias_collision_marker}" read -ra _alias_arr <<<"${_mkt_resolved_aliases[$_mkt_id]}"
    for _mkt_alias in "${_alias_arr[@]}"; do
      [[ -n "$_mkt_alias" ]] || continue
      _mkt_dst="$_isolated_marketplaces/$_mkt_alias"
      bridge_linux_sudo_root rm -f "$_mkt_dst" >/dev/null 2>&1 || true
      bridge_linux_sudo_root ln -s "$_mkt_src" "$_mkt_dst"
      bridge_linux_sudo_root chown -h root:root "$_mkt_dst" >/dev/null 2>&1 || true
    done
    # v2: marketplace source dirs live under $BRIDGE_SHARED_ROOT/plugins-cache
    # (base-readable, group-readable). The setgid/group-mode chain on the
    # shared cache root covers read access for the isolated UID without any
    # named-user ACL or ancestor traverse grant.
  done

  # 6c. Persist the new grant set so the next reapply / unisolate sees
  #     exactly what we touched here. Persisted entries cover both the
  #     channel-derived and BRIDGE_AGENT_PLUGINS-derived plugins (both
  #     stored in `plugin:<id>` form), so the unisolate revoke loop in
  #     bridge_migration_unisolate strips the union without further
  #     wiring.
  local _persist_csv=""
  if [[ "${#_current_plugin_channels[@]}" -gt 0 ]]; then
    _persist_csv="$(IFS=','; printf '%s' "${_current_plugin_channels[*]}")"
  fi
  bridge_isolated_plugin_grants_write "$agent" "$_persist_csv"

  # 6d. Audit row so operators can confirm exactly which plugins landed
  #     on the isolated UID after each reapply (#348). The detail rows
  #     carry the union list (channel + allowlist) and its size so a
  #     follow-up `bridge-audit` query can surface domain-plugin
  #     propagation gaps without a manual sudo into the UID's home.
  local _audit_csv="$_persist_csv"
  local _audit_count="${#_current_plugin_channels[@]}"
  bridge_audit_log daemon isolated_plugin_manifest_written "$agent" \
    --detail os_user="$os_user" \
    --detail plugin_count="$_audit_count" \
    --detail plugins="$_audit_csv" >/dev/null 2>&1 || true
}

bridge_linux_unshare_plugin_catalog() {
  # Tear down the isolated-side artifacts created by
  # bridge_linux_share_plugin_catalog: catalog symlinks under
  # $user_home/.claude/plugins/, the per-UID installed_plugins.json,
  # and the plugins/ directory itself if it ends up empty after the
  # symlink + manifest cleanup. plugins/data/ is preserved on purpose —
  # it is owned by the isolated UID and contains plugin-runtime state
  # the agent has produced; resetting that is a separate concern. The
  # function is dry-run aware so it can compose with
  # bridge_migration_unisolate's existing dry_run gate. (Blocking 4 in
  # PR #302 r1.)
  local os_user="$1"
  local user_home="$2"
  local dry_run="$3"

  local isolated_plugins="$user_home/.claude/plugins"
  [[ -n "$user_home" ]] || return 0
  bridge_linux_sudo_root test -d "$isolated_plugins" || return 0

  local catalog_file=""
  local link=""
  for catalog_file in "${BRIDGE_ISOLATION_SHARED_CATALOG_READ_FILES[@]}"; do
    link="$isolated_plugins/$catalog_file"
    bridge_linux_sudo_root test -e "$link" 2>/dev/null \
      || bridge_linux_sudo_root test -L "$link" 2>/dev/null \
      || continue
    bridge_migration_print_step "$dry_run" "rm $link (isolated catalog symlink)"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root rm -f "$link" >/dev/null 2>&1 || true
    fi
  done

  local manifest="$isolated_plugins/installed_plugins.json"
  if bridge_linux_sudo_root test -e "$manifest" 2>/dev/null; then
    bridge_migration_print_step "$dry_run" "rm $manifest (per-UID installed_plugins.json)"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root rm -f "$manifest" >/dev/null 2>&1 || true
    fi
  fi

  # Marketplaces/ symlinks (#348) — created by share for plugins in
  # `<plugin>@<marketplace>` form whose marketplace tree exists at the
  # controller. Strip the symlinks the share path planted, then rmdir the
  # marketplaces/ dir if it ends up empty so the outer rmdir below can
  # also tear down plugins/. plugins/data/ remains untouched.
  local isolated_marketplaces="$isolated_plugins/marketplaces"
  if bridge_linux_sudo_root test -d "$isolated_marketplaces" 2>/dev/null \
      || bridge_linux_sudo_root test -L "$isolated_marketplaces" 2>/dev/null; then
    bridge_migration_print_step "$dry_run" "rm $isolated_marketplaces/* symlinks (isolated marketplace symlinks)"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root bash -c "shopt -s nullglob dotglob; for entry in \"$isolated_marketplaces\"/*; do [[ -L \"\$entry\" ]] && rm -f \"\$entry\"; done" >/dev/null 2>&1 || true
      bridge_linux_sudo_root rmdir "$isolated_marketplaces" >/dev/null 2>&1 || true
    fi
  fi

  # Only rmdir plugins/ when it ends up empty after the strip. If
  # plugins/data/ (or anything else the agent has produced) still
  # exists, leave the directory alone — its contents belong to the
  # isolated UID, not to bridge isolation.
  if [[ "$dry_run" != "1" ]]; then
    if bridge_linux_sudo_root bash -c "shopt -s nullglob dotglob; entries=(\"$isolated_plugins\"/*); ((\${#entries[@]} == 0))" >/dev/null 2>&1; then
      bridge_migration_print_step "$dry_run" "rmdir $isolated_plugins (empty)"
      bridge_linux_sudo_root rmdir "$isolated_plugins" >/dev/null 2>&1 || true
    else
      bridge_migration_print_step "$dry_run" "$isolated_plugins not empty (preserving plugins/data/ etc.)"
    fi
  else
    bridge_migration_print_step "$dry_run" "rmdir $isolated_plugins if empty (skipped in dry-run)"
  fi
}

bridge_tmp_ephemeral_path_is() {
  local path="${1:-}"
  local tmpdir="${TMPDIR:-}"
  local tmpdir_real=""

  [[ -n "$path" ]] || return 1
  case "$path" in
    /tmp/tmp.*|/tmp/tmp.*/*|/var/tmp/tmp.*|/var/tmp/tmp.*/*|/private/tmp/tmp.*|/private/tmp/tmp.*/*)
      return 0
      ;;
  esac
  if [[ -n "$tmpdir" ]]; then
    tmpdir="${tmpdir%/}"
    case "$path" in
      "$tmpdir"/tmp.*|"$tmpdir"/tmp.*/*)
        return 0
        ;;
    esac
    if [[ -d "$tmpdir" ]]; then
      tmpdir_real="$(cd -P "$tmpdir" 2>/dev/null && pwd -P || true)"
      tmpdir_real="${tmpdir_real%/}"
      if [[ -n "$tmpdir_real" && "$tmpdir_real" != "$tmpdir" ]]; then
        case "$path" in
          "$tmpdir_real"/tmp.*|"$tmpdir_real"/tmp.*/*)
            return 0
            ;;
        esac
      fi
    fi
  fi
  return 1
}

bridge_reject_ephemeral_controller_env_for_agent_env() {
  local name=""
  local value=""
  local -a path_vars=(
    BRIDGE_HOME
    BRIDGE_ROSTER_FILE
    BRIDGE_ROSTER_LOCAL_FILE
    BRIDGE_STATE_DIR
    BRIDGE_LAYOUT_MARKER_DIR
    BRIDGE_ACTIVE_AGENT_DIR
    BRIDGE_HISTORY_DIR
    BRIDGE_WORKTREE_META_DIR
    BRIDGE_ACTIVE_ROSTER_TSV
    BRIDGE_ACTIVE_ROSTER_MD
    BRIDGE_DAEMON_PID_FILE
    BRIDGE_DAEMON_LOG
    BRIDGE_DAEMON_CRASH_LOG
    BRIDGE_TASK_DB
    BRIDGE_PROFILE_STATE_DIR
    BRIDGE_CRON_STATE_DIR
    BRIDGE_CRON_HOME_DIR
    BRIDGE_WORKTREE_ROOT
    BRIDGE_AGENT_HOME_ROOT
    BRIDGE_RUNTIME_ROOT
    BRIDGE_RUNTIME_SCRIPTS_DIR
    BRIDGE_RUNTIME_SKILLS_DIR
    BRIDGE_RUNTIME_SHARED_DIR
    BRIDGE_RUNTIME_SHARED_TOOLS_DIR
    BRIDGE_RUNTIME_SHARED_REFERENCES_DIR
    BRIDGE_RUNTIME_MEMORY_DIR
    BRIDGE_RUNTIME_CREDENTIALS_DIR
    BRIDGE_RUNTIME_SECRETS_DIR
    BRIDGE_RUNTIME_CONFIG_FILE
    BRIDGE_HOOKS_DIR
    BRIDGE_SHARED_DIR
    BRIDGE_TASK_NOTE_DIR
    BRIDGE_LOG_DIR
    BRIDGE_DATA_ROOT
    BRIDGE_SHARED_ROOT
    BRIDGE_AGENT_ROOT_V2
    BRIDGE_CONTROLLER_STATE_ROOT
  )

  [[ "${BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV:-0}" == "1" ]] && return 0

  for name in "${path_vars[@]}"; do
    value="${!name:-}"
    [[ -n "$value" ]] || continue
    if bridge_tmp_ephemeral_path_is "$value"; then
      bridge_die "refusing to write isolated agent-env.sh from ephemeral controller path ${name}=${value}; unset stale BRIDGE_* variables before running isolate/start, or set BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=1 for a deliberate temp test install"
    fi
  done
}

bridge_write_linux_agent_env_file() {
  local agent="$1"
  local file="${2:-$(bridge_agent_linux_env_file "$agent")}"
  local description=""
  local engine=""
  local session=""
  local workdir=""
  local profile_home=""
  local launch_cmd=""
  local channels=""
  local discord_channel=""
  local notify_kind=""
  local notify_target=""
  local notify_account=""
  local loop_mode=""
  local continue_mode=""
  local idle_timeout=""
  local session_id=""
  local history_key=""
  local created_at=""
  local updated_at=""
  local isolation_mode=""
  local os_user=""
  local admin_agent=""
  local agent_log_dir=""
  local agent_audit_log=""

  description="$(bridge_agent_desc "$agent")"
  engine="$(bridge_agent_engine "$agent")"
  session="$(bridge_agent_session "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  profile_home="$(bridge_agent_profile_home "$agent")"
  launch_cmd="$(bridge_agent_launch_cmd_raw "$agent")"
  channels="$(bridge_agent_channels_csv "$agent")"
  discord_channel="$(bridge_agent_discord_channel_id "$agent")"
  notify_kind="$(bridge_agent_notify_kind "$agent")"
  notify_target="$(bridge_agent_notify_target "$agent")"
  notify_account="$(bridge_agent_notify_account "$agent")"
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  idle_timeout="$(bridge_agent_idle_timeout "$agent")"
  session_id="$(bridge_agent_session_id "$agent")"
  history_key="${BRIDGE_AGENT_HISTORY_KEY[$agent]-}"
  created_at="${BRIDGE_AGENT_CREATED_AT[$agent]-}"
  updated_at="${BRIDGE_AGENT_UPDATED_AT[$agent]-}"
  isolation_mode="$(bridge_agent_isolation_mode "$agent")"
  os_user="$(bridge_agent_os_user "$agent")"
  admin_agent="$(bridge_admin_agent_id)"
  agent_log_dir="$(bridge_agent_log_dir "$agent")"
  agent_audit_log="$(bridge_agent_audit_log_file "$agent")"

  bridge_reject_ephemeral_controller_env_for_agent_env

  # Issue #1025: when the agent is linux-user isolated, the final env
  # file lives under `$BRIDGE_AGENT_ROOT_V2/<agent>/runtime/` — a tree
  # the isolation-v2 scaffold leaves `root:ab-agent-<name>` (per-agent
  # root 2750, `runtime/` 2770). The controller IS added to the
  # `ab-agent-<name>` group during prepare, but a `usermod -aG` does not
  # refresh the *running* controller process's supplementary group set,
  # so within the same `agent create --isolate` invocation the
  # controller can neither `mkdir -p` nor `cat >` into that tree (no
  # `other` bits, stale group). A plain write aborts the create with
  # `Permission denied`, leaving a half-created agent.
  #
  # Stage the whole file build into a controller-owned tempfile, then
  # hand the finished file off to the per-agent `runtime/` via sudo
  # (`install`, which the rest of the v2 scaffold/handoff paths already
  # rely on). The non-isolated path is unchanged: it builds directly at
  # `$file` exactly as before. `_env_stage_target` is the path every
  # `cat >`/`cat >>`/`printf >>`/`chmod` below writes to; `_env_final`
  # is the real destination.
  local _env_final="$file"
  local _env_stage_target="$file"
  local _env_isolated_write=0
  # Only stage+install when the destination is genuinely under the
  # agent-group-owned per-agent root. Callers that pass an explicit
  # tempfile path (the idempotency probe in
  # bridge_ensure_isolated_agent_env_current) write to a controller-
  # writable location already and must keep the direct-write path.
  if [[ "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]] \
      && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null \
      && command -v bridge_linux_sudo_root >/dev/null 2>&1 \
      && [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" \
            && "$_env_final" == "$BRIDGE_AGENT_ROOT_V2/"* ]]; then
    _env_isolated_write=1
    _env_stage_target="$(mktemp "${TMPDIR:-/tmp}/agent-env.stage.XXXXXX")" \
      || bridge_die "bridge_write_linux_agent_env_file: cannot stage temp env file for '$agent'"
    # #771 symlink defense for the real destination: when staging, the
    # `[[ -L "$file" ]]` check below only sees the fresh tempfile. The
    # final `install` would still write through a symlink planted at
    # `_env_final` by the isolated UID. Clear any symlink at the
    # destination here (via sudo — the dir is agent-group-owned) so the
    # install lands on a regular file.
    if bridge_linux_sudo_root test -L "$_env_final" 2>/dev/null; then
      bridge_linux_sudo_root rm -f "$_env_final" 2>/dev/null || true
      if bridge_linux_sudo_root test -L "$_env_final" 2>/dev/null; then
        rm -f "$_env_stage_target"
        bridge_warn "bridge_write_linux_agent_env_file: refusing to write — symlink at $_env_final survived rm attempt. Investigate and remove manually before retry."
        return 1
      fi
    fi
  fi
  # `file` is repurposed as the write target for the build below so the
  # rest of the function body needs no edits; `_env_final` keeps the
  # real destination for the sudo install at the end.
  file="$_env_stage_target"
  mkdir -p "$(dirname "$file")"
  # Issue #771 v0.9.5 r2/r3 hardening (codex destructive-probe finding 1):
  # `runtime/agent-env.sh` lives inside `agents/<X>/runtime/` which is
  # mode 2770 + agent-UID-writable. An isolated agent could plant a
  # SYMLINK at this path pointing to a controller-owned file (e.g.
  # `/home/ec2-user/.claude/.credentials.json` or another agent's
  # env file). Without a symlink check, `[[ -O "$file" ]]` returns
  # true on the link's target (which the controller owns), the rm
  # branch skips, and the subsequent `cat >"$file"` writes through
  # the symlink — corrupting the controller's file. Refuse symlinks
  # explicitly: if `runtime/agent-env.sh` is a symlink (regardless
  # of target), `bridge_linux_sudo_root rm -f` it (or plain rm if
  # not on Linux) so the redirect creates a fresh regular file.
  # r3: if rm fails (sudo unavailable + caller doesn't own parent
  # dir → permission denied) the symlink survives. Without an
  # explicit fail-loud here, the fall-through `[[ -e && ! -O ]]`
  # self-heal block + `cat >"$file"` would still write through the
  # surviving symlink → original corruption vector reopened. Verify
  # post-rm and return 1 with bridge_warn rather than write through.
  if [[ -L "$file" ]]; then
    if [[ "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]] \
        && command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      bridge_linux_sudo_root rm -f "$file" 2>/dev/null || rm -f "$file"
    else
      rm -f "$file"
    fi
    if [[ -L "$file" ]]; then
      bridge_warn "bridge_write_linux_agent_env_file: refusing to write — symlink at $file survived rm attempt (need root or passwordless sudo to clear). Investigate and remove manually before retry."
      return 1
    fi
  fi
  # Self-heal ownership: when an earlier isolate cycle chowned the file to the
  # isolated os_user, `cat >` preserves ownership and the trailing `chmod 600`
  # fails with EPERM for the operator. Drop the stale inode (via sudo when
  # linux-user isolation is active) so the redirect creates a fresh one owned
  # by the current UID. See issue #112 retest.
  if [[ -e "$file" && ! -O "$file" ]]; then
    if [[ "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]] \
        && command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      bridge_linux_sudo_root rm -f "$file" 2>/dev/null || rm -f "$file"
    else
      rm -f "$file"
    fi
  fi
  # Issue #1014 B: the launch envelope must not bake a stale BRIDGE_LAYOUT
  # value into the per-agent env file. When a valid v2 layout marker exists
  # the marker is authoritative — the child re-resolves the layout at startup
  # via bridge_resolve_layout. Baking `BRIDGE_LAYOUT=legacy` here (the old
  # `${BRIDGE_LAYOUT:-legacy}` default) made the stale value self-perpetuate
  # through the daemon → agent-env → CLI process tree, so every restart
  # re-injected it and the resolver's "stale pre-v0.8.0 env override" warning
  # never cleared. Normalize to the marker value when a marker is present;
  # only fall back to an explicit ambient BRIDGE_LAYOUT (no marker case).
  local _agent_env_layout=""
  local _agent_env_marker_path
  _agent_env_marker_path="$(bridge_isolation_v2_marker_path 2>/dev/null || true)"
  if [[ -n "$_agent_env_marker_path" && -f "$_agent_env_marker_path" ]] \
      && bridge_isolation_v2_marker_validate "$_agent_env_marker_path" >/dev/null 2>&1; then
    # Marker present and valid — it is the source of truth. Emit the
    # marker-pinned value so the child never sees a stale legacy override.
    _agent_env_layout="v2"
  else
    # No valid marker — preserve the prior behavior so markerless installs
    # still carry an explicit layout, but never invent a stale `legacy`
    # default: only propagate a BRIDGE_LAYOUT the caller actually set.
    _agent_env_layout="${BRIDGE_LAYOUT:-}"
  fi

  cat >"$file" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_HOME=$(printf '%q' "$BRIDGE_HOME")
BRIDGE_STATE_DIR=$(printf '%q' "$BRIDGE_STATE_DIR")
BRIDGE_ACTIVE_AGENT_DIR=$(printf '%q' "$BRIDGE_ACTIVE_AGENT_DIR")
BRIDGE_HISTORY_DIR=$(printf '%q' "$BRIDGE_HISTORY_DIR")
BRIDGE_WORKTREE_META_DIR=$(printf '%q' "$BRIDGE_WORKTREE_META_DIR")
BRIDGE_ACTIVE_ROSTER_TSV=$(printf '%q' "$BRIDGE_ACTIVE_ROSTER_TSV")
BRIDGE_ACTIVE_ROSTER_MD=$(printf '%q' "$BRIDGE_ACTIVE_ROSTER_MD")
BRIDGE_DAEMON_PID_FILE=$(printf '%q' "$BRIDGE_DAEMON_PID_FILE")
BRIDGE_DAEMON_LOG=$(printf '%q' "$BRIDGE_DAEMON_LOG")
BRIDGE_DAEMON_CRASH_LOG=$(printf '%q' "$BRIDGE_DAEMON_CRASH_LOG")
# BRIDGE_TASK_DB is sentineled (not the live path) for isolated UIDs: every
# queue read/write must route through the gateway proxy when
# BRIDGE_GATEWAY_PROXY=1. Emitting the real path would disclose operator state
# layout (#287 / #294 r1 finding 4) and re-open a direct-DB code path. Setting
# /dev/null fails loudly if any caller bypasses the gateway and tries sqlite.
BRIDGE_TASK_DB=/dev/null
BRIDGE_PROFILE_STATE_DIR=$(printf '%q' "$BRIDGE_PROFILE_STATE_DIR")
BRIDGE_CRON_STATE_DIR=$(printf '%q' "$BRIDGE_CRON_STATE_DIR")
BRIDGE_CRON_HOME_DIR=$(printf '%q' "$BRIDGE_CRON_HOME_DIR")
BRIDGE_WORKTREE_ROOT=$(printf '%q' "$BRIDGE_WORKTREE_ROOT")
BRIDGE_AGENT_HOME_ROOT=$(printf '%q' "$BRIDGE_AGENT_HOME_ROOT")
BRIDGE_RUNTIME_ROOT=$(printf '%q' "$BRIDGE_RUNTIME_ROOT")
BRIDGE_RUNTIME_SCRIPTS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SCRIPTS_DIR")
BRIDGE_RUNTIME_SKILLS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SKILLS_DIR")
BRIDGE_RUNTIME_SHARED_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SHARED_DIR")
BRIDGE_RUNTIME_SHARED_TOOLS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SHARED_TOOLS_DIR")
BRIDGE_RUNTIME_SHARED_REFERENCES_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SHARED_REFERENCES_DIR")
BRIDGE_RUNTIME_MEMORY_DIR=$(printf '%q' "$BRIDGE_RUNTIME_MEMORY_DIR")
BRIDGE_RUNTIME_CREDENTIALS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_CREDENTIALS_DIR")
BRIDGE_RUNTIME_SECRETS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SECRETS_DIR")
BRIDGE_RUNTIME_CONFIG_FILE=$(printf '%q' "$BRIDGE_RUNTIME_CONFIG_FILE")
BRIDGE_HOOKS_DIR=$(printf '%q' "$BRIDGE_HOOKS_DIR")
BRIDGE_SHARED_DIR=$(printf '%q' "$BRIDGE_SHARED_DIR")
BRIDGE_LAYOUT=$(printf '%q' "$_agent_env_layout")
BRIDGE_DATA_ROOT=$(printf '%q' "${BRIDGE_DATA_ROOT:-}")
BRIDGE_SHARED_ROOT=$(printf '%q' "${BRIDGE_SHARED_ROOT:-}")
BRIDGE_AGENT_ROOT_V2=$(printf '%q' "${BRIDGE_AGENT_ROOT_V2:-}")
BRIDGE_CONTROLLER_STATE_ROOT=$(printf '%q' "${BRIDGE_CONTROLLER_STATE_ROOT:-}")
BRIDGE_SHARED_GROUP=$(printf '%q' "${BRIDGE_SHARED_GROUP:-ab-shared}")
BRIDGE_CONTROLLER_GROUP=$(printf '%q' "${BRIDGE_CONTROLLER_GROUP:-ab-controller}")
BRIDGE_AGENT_GROUP_PREFIX=$(printf '%q' "${BRIDGE_AGENT_GROUP_PREFIX:-ab-agent-}")
# Marker dir is anchored separately so children resolve the marker even if
# BRIDGE_STATE_DIR is rebased (controller-state relocation, future PR).
BRIDGE_LAYOUT_MARKER_DIR=$(printf '%q' "${BRIDGE_LAYOUT_MARKER_DIR:-${BRIDGE_HOME}/state}")
export BRIDGE_LAYOUT BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT BRIDGE_SHARED_GROUP BRIDGE_CONTROLLER_GROUP BRIDGE_AGENT_GROUP_PREFIX BRIDGE_LAYOUT_MARKER_DIR
BRIDGE_LOG_DIR=$(printf '%q' "$agent_log_dir")
BRIDGE_AUDIT_LOG=$(printf '%q' "$agent_audit_log")
BRIDGE_ROSTER_FILE=""
BRIDGE_ROSTER_LOCAL_FILE=""
BRIDGE_ADMIN_AGENT_ID=$(printf '%q' "$admin_agent")
BRIDGE_AGENT_ID=$(printf '%q' "$agent")
export BRIDGE_AGENT_ID
BRIDGE_AGENT_IDS=()
declare -g -A BRIDGE_AGENT_DESC=()
declare -g -A BRIDGE_AGENT_ENGINE=()
declare -g -A BRIDGE_AGENT_SESSION=()
declare -g -A BRIDGE_AGENT_WORKDIR=()
declare -g -A BRIDGE_AGENT_PROFILE_HOME=()
declare -g -A BRIDGE_AGENT_LAUNCH_CMD=()
declare -g -A BRIDGE_AGENT_SOURCE=()
declare -g -A BRIDGE_AGENT_LOOP=()
declare -g -A BRIDGE_AGENT_CONTINUE=()
declare -g -A BRIDGE_AGENT_SESSION_ID=()
declare -g -A BRIDGE_AGENT_HISTORY_KEY=()
declare -g -A BRIDGE_AGENT_CREATED_AT=()
declare -g -A BRIDGE_AGENT_UPDATED_AT=()
declare -g -A BRIDGE_AGENT_IDLE_TIMEOUT=()
declare -g -A BRIDGE_AGENT_NOTIFY_KIND=()
declare -g -A BRIDGE_AGENT_NOTIFY_TARGET=()
declare -g -A BRIDGE_AGENT_NOTIFY_ACCOUNT=()
declare -g -A BRIDGE_AGENT_DISCORD_CHANNEL_ID=()
declare -g -A BRIDGE_AGENT_CHANNELS=()
declare -g -A BRIDGE_AGENT_PLUGINS=()
declare -g -A BRIDGE_AGENT_ISOLATION_MODE=()
declare -g -A BRIDGE_AGENT_OS_USER=()
declare -g -A BRIDGE_AGENT_MODEL=()
declare -g -A BRIDGE_AGENT_EFFORT=()
declare -g -A BRIDGE_AGENT_PERMISSION_MODE=()
declare -g -A BRIDGE_AGENT_PROMPT_GUARD=()
declare -g -A BRIDGE_AGENT_CLASS=()
EOF
  # Self entry first: full record including LAUNCH_CMD (the calling agent's
  # own launch command may legitimately carry tokens; ACLs already restrict
  # the file to the calling UID + controller).
  cat >>"$file" <<EOF
bridge_add_agent_id_if_missing $(printf '%q' "$agent")
BRIDGE_AGENT_DESC[$(printf '%q' "$agent")]=$(printf '%q' "$description")
BRIDGE_AGENT_ENGINE[$(printf '%q' "$agent")]=$(printf '%q' "$engine")
BRIDGE_AGENT_SESSION[$(printf '%q' "$agent")]=$(printf '%q' "$session")
BRIDGE_AGENT_WORKDIR[$(printf '%q' "$agent")]=$(printf '%q' "$workdir")
BRIDGE_AGENT_PROFILE_HOME[$(printf '%q' "$agent")]=$(printf '%q' "$profile_home")
BRIDGE_AGENT_LAUNCH_CMD[$(printf '%q' "$agent")]=$(printf '%q' "$launch_cmd")
BRIDGE_AGENT_SOURCE[$(printf '%q' "$agent")]="static"
BRIDGE_AGENT_LOOP[$(printf '%q' "$agent")]=$(printf '%q' "$loop_mode")
BRIDGE_AGENT_CONTINUE[$(printf '%q' "$agent")]=$(printf '%q' "$continue_mode")
BRIDGE_AGENT_SESSION_ID[$(printf '%q' "$agent")]=$(printf '%q' "$session_id")
BRIDGE_AGENT_HISTORY_KEY[$(printf '%q' "$agent")]=$(printf '%q' "$history_key")
BRIDGE_AGENT_CREATED_AT[$(printf '%q' "$agent")]=$(printf '%q' "$created_at")
BRIDGE_AGENT_UPDATED_AT[$(printf '%q' "$agent")]=$(printf '%q' "$updated_at")
BRIDGE_AGENT_IDLE_TIMEOUT[$(printf '%q' "$agent")]=$(printf '%q' "$idle_timeout")
BRIDGE_AGENT_NOTIFY_KIND[$(printf '%q' "$agent")]=$(printf '%q' "$notify_kind")
BRIDGE_AGENT_NOTIFY_TARGET[$(printf '%q' "$agent")]=$(printf '%q' "$notify_target")
BRIDGE_AGENT_NOTIFY_ACCOUNT[$(printf '%q' "$agent")]=$(printf '%q' "$notify_account")
BRIDGE_AGENT_DISCORD_CHANNEL_ID[$(printf '%q' "$agent")]=$(printf '%q' "$discord_channel")
BRIDGE_AGENT_CHANNELS[$(printf '%q' "$agent")]=$(printf '%q' "$channels")
BRIDGE_AGENT_ISOLATION_MODE[$(printf '%q' "$agent")]=$(printf '%q' "$isolation_mode")
BRIDGE_AGENT_OS_USER[$(printf '%q' "$agent")]=$(printf '%q' "$os_user")
BRIDGE_AGENT_PROMPT_GUARD[$(printf '%q' "$agent")]=$(printf '%q' "${BRIDGE_AGENT_PROMPT_GUARD[$agent]-}")
BRIDGE_AGENT_CLASS[$(printf '%q' "$agent")]=$(printf '%q' "$(bridge_agent_class "$agent")")
EOF
  # Peer entries: id + non-secret metadata. NEVER emit a peer's LAUNCH_CMD
  # (token-bearing) or PROMPT_GUARD policy (canary tokens at
  # lib/bridge-guard.sh:123 are sensitive — see #294 r1 finding 3). The empty
  # LAUNCH_CMD / PROMPT_GUARD entries are written explicitly so the array shape
  # stays consistent across map keys; downstream callers that require the
  # launch command for a peer must fall through to the controller (queue
  # gateway path). Client-side guard parity for peers is intentionally dropped:
  # gateway-side enforcement remains, and a follow-up issue covers the case if
  # peer-targeted prompt blocking before queue submission is actually needed.
  local peer=""
  for peer in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$peer" == "$agent" ]] && continue
    [[ "$(bridge_agent_source "$peer")" == "static" ]] || continue
    local peer_desc peer_engine peer_session peer_workdir peer_isolation
    local peer_source
    peer_desc="$(bridge_agent_desc "$peer")"
    peer_engine="$(bridge_agent_engine "$peer")"
    peer_session="$(bridge_agent_session "$peer")"
    peer_workdir="$(bridge_agent_workdir "$peer")"
    peer_isolation="$(bridge_agent_isolation_mode "$peer")"
    peer_source="$(bridge_agent_source "$peer")"
    cat >>"$file" <<EOF
bridge_add_agent_id_if_missing $(printf '%q' "$peer")
BRIDGE_AGENT_DESC[$(printf '%q' "$peer")]=$(printf '%q' "$peer_desc")
BRIDGE_AGENT_ENGINE[$(printf '%q' "$peer")]=$(printf '%q' "$peer_engine")
BRIDGE_AGENT_SESSION[$(printf '%q' "$peer")]=$(printf '%q' "$peer_session")
BRIDGE_AGENT_WORKDIR[$(printf '%q' "$peer")]=$(printf '%q' "$peer_workdir")
BRIDGE_AGENT_SOURCE[$(printf '%q' "$peer")]=$(printf '%q' "$peer_source")
BRIDGE_AGENT_ISOLATION_MODE[$(printf '%q' "$peer")]=$(printf '%q' "$peer_isolation")
BRIDGE_AGENT_LAUNCH_CMD[$(printf '%q' "$peer")]=''
BRIDGE_AGENT_PROMPT_GUARD[$(printf '%q' "$peer")]=''
EOF
  done
  # Explicit gateway-proxy signal for isolated agents. Decouples gateway
  # routing from `${#BRIDGE_AGENT_IDS[@]}` so the peer-id additions above do
  # not accidentally drop the agent off the gateway. See issue #294 +
  # bridge_queue_gateway_proxy_agent.
  #
  # BRIDGE_CONTROLLER_UID is the writer's UID (this function runs in the
  # controller context). The bin/agb shim uses it to confirm a strict UID
  # mismatch before applying the isolated-CLI allowlist (issue #544 PR4) —
  # the gateway-proxy flag alone could be spoofed by an operator who
  # manually exports it in their own shell.
  if [[ "$isolation_mode" == "linux-user" ]]; then
    local _controller_uid
    _controller_uid="$(id -u)"
    cat >>"$file" <<EOF
BRIDGE_GATEWAY_PROXY=1
export BRIDGE_GATEWAY_PROXY
BRIDGE_CONTROLLER_UID=$(printf '%q' "$_controller_uid")
export BRIDGE_CONTROLLER_UID
EOF
    # Propagate non-default queue-gateway env to the isolated agent
    # (finding 7, r2 review). Without this, an isolated agent inherits
    # the hard-coded /run/agent-bridge default for the runtime root and
    # cannot find the daemon's socket when the operator has overridden
    # BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT (smoke tests, multi-instance
    # installs, alt-mount runtimes). Same for the socket timeout and
    # the transport selection. We only emit overrides when they differ
    # from the bridge-lib.sh defaults so the env file stays minimal.
    if [[ -n "${BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT:-}" \
          && "${BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT}" != "/run/agent-bridge" ]]; then
      printf 'BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT=%s\nexport BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT\n' \
        "$(printf '%q' "$BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT")" >>"$file"
    fi
    if [[ -n "${BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS:-}" \
          && "${BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS}" != "5" ]]; then
      printf 'BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS=%s\nexport BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS\n' \
        "$(printf '%q' "$BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS")" >>"$file"
    fi
    if [[ -n "${BRIDGE_GATEWAY_TRANSPORT:-}" \
          && "${BRIDGE_GATEWAY_TRANSPORT}" != "file" ]]; then
      printf 'BRIDGE_GATEWAY_TRANSPORT=%s\nexport BRIDGE_GATEWAY_TRANSPORT\n' \
        "$(printf '%q' "$BRIDGE_GATEWAY_TRANSPORT")" >>"$file"
    fi
  fi
  # Inject engine CLI directory into PATH for sudo-wrapped launchers when
  # isolation is active. Under sudo, PATH falls back to secure_path which
  # almost never contains the operator's per-user bin (e.g.
  # ~/.local/bin/claude), so the launcher's bare `claude` / `codex` call
  # would die with "command not found". Resolving on every start picks up
  # CLI upgrades automatically. v2 still requires the engine CLI to
  # live in a base-readable path (`other::r-x`); controller-home
  # symlinks fail at runtime with `command not found` (no prepare-time
  # check post-v0.8.0 — see KNOWN_ISSUES #17).
  if [[ "$isolation_mode" == "linux-user" ]]; then
    if [[ -n "$engine" ]]; then
      local _engine_cli _engine_dir
      _engine_cli="$(bridge_resolve_engine_cli "$engine" 2>/dev/null || printf '')"
      if [[ -n "$_engine_cli" ]]; then
        _engine_dir="$(dirname "$_engine_cli")"
        printf '\nexport PATH=%s:"${PATH:-/usr/local/bin:/usr/bin:/bin}"\n' \
          "$(printf '%q' "$_engine_dir")" >>"$file"
      fi
    fi
    # Curated bridge bin dir (issue #544 PR1). Lets the isolated UID call
    # `agb` bare from a Bash tool subprocess. Only the curated shim at
    # ${BRIDGE_HOME}/bin/agb is exposed here — broader agent-bridge
    # subcommand surface stays gated behind PR4's default-deny design.
    # v2: $BRIDGE_HOME/bin is base-readable, no per-agent ACL needed.
    printf '\nexport PATH=%s:"${PATH:-/usr/local/bin:/usr/bin:/bin}"\n' \
      "$(printf '%q' "$BRIDGE_HOME/bin")" >>"$file"
  fi
  chmod 600 "$file"

  # Issue #1025: when the build was staged into a controller-owned
  # tempfile, hand the finished file off to its real destination under
  # the per-agent `runtime/` via sudo in a SINGLE privileged `install`
  # invocation that sets owner, group, and mode atomically. The
  # isolation-v2 matrix contract for `agent-env-sh` is
  # `controller:<agent_grp>` mode `0640` (lib/bridge-isolation-v2.sh
  # `agent-env-sh` row). Doing the metadata in one `install -o -g -m`
  # — rather than `install` then a separate sudo `chgrp`/`chmod` —
  # closes a TOCTOU window: `runtime/` is isolated-UID-owned and
  # group-writable (2770), so a live isolated agent could swap
  # `agent-env.sh` for a symlink between a bare install and a
  # follow-prone second metadata touch. With no second touch, the file
  # lands at the correct owner/group/mode in one step and the v2
  # chgrp/chmod block below is skipped for the staged path.
  if [[ $_env_isolated_write -eq 1 ]]; then
    local _env_install_owner _env_install_group
    _env_install_owner="$(bridge_current_user 2>/dev/null || id -un 2>/dev/null || printf '')"
    _env_install_group="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
    if [[ -z "$_env_install_owner" || -z "$_env_install_group" ]]; then
      rm -f "$_env_stage_target"
      bridge_die "bridge_write_linux_agent_env_file: cannot resolve controller user / agent group for '$agent' — refusing to install env file without the v2 owner:group contract"
    fi
    # Ensure the parent `runtime/` exists via sudo (prepare normally
    # created it 2770 already — this is an idempotent safety net and
    # also the operation that gets past the stale-group traversal block
    # that is the #1025 root cause). `mkdir -p` is not used with
    # `install -D` because BSD `install` does not create parent dirs;
    # an explicit sudo `mkdir -p` is portable and keeps the file
    # creation a single atomic `install`.
    bridge_linux_sudo_root mkdir -p "$(dirname "$_env_final")" \
      || {
        rm -f "$_env_stage_target"
        bridge_die "bridge_write_linux_agent_env_file: sudo mkdir of runtime dir for '$_env_final' failed"
      }
    # Single privileged `install` lands the file with owner, group, and
    # mode set atomically — the isolation-v2 `agent-env-sh` matrix
    # contract is `controller:<agent_grp>` mode 0640. No separate
    # post-install chgrp/chmod (that second touch would reopen a TOCTOU
    # symlink window on the group-writable 2770 `runtime/` dir).
    bridge_linux_sudo_root install \
        -o "$_env_install_owner" -g "$_env_install_group" -m 0640 \
        "$_env_stage_target" "$_env_final" \
      || {
        rm -f "$_env_stage_target"
        bridge_die "bridge_write_linux_agent_env_file: sudo install of staged env file to '$_env_final' (owner=$_env_install_owner group=$_env_install_group mode=0640) failed"
      }
    rm -f "$_env_stage_target"
    file="$_env_final"
  fi
  # PR-E: in v2 mode, replace the named-user ACL grant pair with a
  # group-mode contract — chgrp ab-agent-<name> + chmod 0640. The agent
  # group has both the isolated UID (read) and the controller (read+
  # owner write) as members per PR-C, so 0640 covers both without ACL.
  # Skipped entirely for the staged-write path above (#1025): the single
  # `install -o -g -m` already set owner:group:mode atomically, and a
  # separate post-install chgrp/chmod would reopen a TOCTOU symlink
  # window on the group-writable `runtime/` dir. This block remains the
  # contract enforcer ONLY for the direct (non-staged) write path —
  # e.g. macOS, or callers passing an explicit controller-writable
  # tempfile destination.
  if [[ $_env_isolated_write -eq 0 \
        && "$isolation_mode" == "linux-user" \
        && -n "$os_user" \
        && "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]]; then
    local _v2_grp
    _v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')" \
      || _v2_grp=""
    if [[ -n "$_v2_grp" ]]; then
      bridge_linux_sudo_root chgrp "$_v2_grp" "$file" \
        || bridge_die "isolation v2: chgrp '$_v2_grp' on env file '$file' failed"
      bridge_linux_sudo_root chmod 0640 "$file" \
        || bridge_die "isolation v2: chmod 0640 on env file '$file' failed"
    else
      bridge_die "isolation v2: cannot resolve agent group for env file '$file'"
    fi
  fi
}

# Issue #989: refresh the cached `runtime/agent-env.sh` for a linux-user
# isolated agent so a roster mutation (channel-add / channel-remove /
# launch-cmd edit) can never leave the cached `BRIDGE_AGENT_LAUNCH_CMD`
# pointing at a pre-v2 channel state path.
#
# Background. `runtime/agent-env.sh` is the ONLY roster snapshot an
# isolated UID can read (the real roster files are not group-reachable;
# `bridge_write_linux_agent_env_file` sets BRIDGE_ROSTER_FILE="" inside
# the emitted file). The cached launch cmd embeds `TEAMS_STATE_DIR` and
# the sibling `*_STATE_DIR` assignments. For a v0.7->v0.8-migrated agent
# the raw roster launch cmd still carries the pre-v2 path
# `agents/<X>/.teams` (owned ec2-user mode 700); the v2-correct
# `agents/<X>/workdir/.teams` is injected at launch by
# `bridge_claude_launch_with_channel_state_dirs`, but ONLY for channels
# still present in the effective channel set. `agent update --channels-*`
# rewrites the roster yet never regenerated this cache, so the stale
# snapshot survived until the next full `bridge-start.sh` run — and a
# channel server that bound the pre-v2 path got EACCES and silently
# stopped delivering inbound messages (the #771 regression this closes).
#
# This is the same recompute `isolation-v2-reapply` performs (see
# lib/bridge-isolation-v2-reapply.sh:448-528). Calling it eagerly after
# a roster mutation keeps the cache v2-correct without waiting for a
# reapply pass.
#
# NO-OP contract: returns 0 immediately for non-isolated (shared-mode /
# non-linux-user) agents — only linux-user isolation has the cached
# `runtime/agent-env.sh`. Also a no-op when isolation is disabled by env
# or when the writer / path helpers are not loaded in the current entry
# path (load-order guard mirrors isolation-v2-reapply.sh:471).
bridge_ensure_isolated_agent_env_current() {
  local agent="$1"

  [[ -n "$agent" ]] || return 0
  if command -v bridge_isolation_disabled_by_env >/dev/null 2>&1 \
      && bridge_isolation_disabled_by_env; then
    return 0
  fi
  bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null || return 0

  # Load-order guard: these helpers may not be sourced in every entry
  # path. A silent skip would mask the regression, so warn loudly —
  # mirrors the isolation-v2-reapply contract.
  if ! command -v bridge_write_linux_agent_env_file >/dev/null 2>&1 \
      || ! command -v bridge_agent_linux_env_file >/dev/null 2>&1; then
    bridge_warn "bridge_ensure_isolated_agent_env_current: writer/path helper not loaded for '$agent' (load-order regression?); cached agent-env.sh left stale — channel servers may bind pre-v2 state paths"
    return 1
  fi

  local env_file=""
  env_file="$(bridge_agent_linux_env_file "$agent" 2>/dev/null || true)"
  [[ -n "$env_file" ]] || return 0

  # Idempotency: generate to a temp path first; if the existing file is
  # a regular file already byte-identical to what the writer produces,
  # skip the rewrite to preserve mtime/ctime (matches the reapply
  # tool's already-canonical short-circuit).
  local tmp_env=""
  tmp_env="$(mktemp "${TMPDIR:-/tmp}/agent-env.regen.XXXXXX" 2>/dev/null || true)"
  if [[ -n "$tmp_env" ]] \
      && bridge_write_linux_agent_env_file "$agent" "$tmp_env" 2>/dev/null; then
    if [[ -f "$env_file" && ! -L "$env_file" ]] \
        && cmp -s "$tmp_env" "$env_file" 2>/dev/null; then
      rm -f "$tmp_env"
      return 0
    fi
    rm -f "$tmp_env"
    if bridge_write_linux_agent_env_file "$agent" "$env_file" 2>/dev/null; then
      return 0
    fi
    bridge_warn "bridge_ensure_isolated_agent_env_current: failed to regenerate $env_file for '$agent' (next agent start will use stale BRIDGE_AGENT_LAUNCH_CMD — channel servers may bind pre-v2 state paths)"
    return 1
  fi
  [[ -n "$tmp_env" ]] && rm -f "$tmp_env"
  bridge_warn "bridge_ensure_isolated_agent_env_current: failed to stage temp agent-env.sh for '$agent'"
  return 1
}

# Issue #989: shared post-mutation refresh for the channel-list / launch-cmd
# write paths. A mutator that rewrites agent-roster.local.sh (run_update's
# bridge_write_role_block, or bridge-setup.sh's bridge_setup_write_local_assoc)
# leaves the per-process roster cache stale: bridge_load_roster short-circuits
# on BRIDGE_ROSTER_CACHE_LOADED=1 (issue #848 memo), so a bare reload replays
# the pre-mutation in-memory maps and bridge_ensure_isolated_agent_env_current
# would regenerate runtime/agent-env.sh from the OLD channel set. Invalidate
# the cache first so the reload re-reads disk, then regenerate. NO-OP for
# non-isolated agents (the inner helper gates on isolation).
#
# Call this from EVERY roster-mutation path that touches BRIDGE_AGENT_CHANNELS
# or BRIDGE_AGENT_LAUNCH_CMD, after the on-disk write completes.
bridge_refresh_isolated_agent_env_after_channel_mutation() {
  local agent="$1"

  [[ -n "$agent" ]] || return 0
  if command -v bridge_roster_cache_invalidate >/dev/null 2>&1; then
    bridge_roster_cache_invalidate
  fi
  if command -v bridge_load_roster >/dev/null 2>&1; then
    bridge_load_roster
  fi
  bridge_ensure_isolated_agent_env_current "$agent" \
    || bridge_warn "channel mutation: cached agent-env.sh regeneration reported a problem for '$agent'; run 'agent-bridge migrate isolation v2 --apply --agent $agent' before the next restart"
}

bridge_linux_prepare_agent_isolation() {
  local agent="$1"
  local os_user="$2"
  local workdir="$3"
  local controller_user="${4:-$(bridge_current_user)}"
  local user_home=""
  local env_file=""
  local runtime_state_dir=""
  local log_dir=""
  local audit_file=""
  local history_file=""
  local request_dir=""
  local response_dir=""

  [[ "$(bridge_host_platform)" == "Linux" ]] || return 0
  [[ -n "$os_user" ]] || bridge_die "linux-user isolation requires os_user"

  # v2: channel symlink + workdir mutations downstream perform
  # check-then-mutate sequences on paths whose parent is owned by the
  # isolated UID. A running agent could win a swap race between guard and
  # mutation. Require the agent's tmux session to be quiesced before
  # prepare/reapply so the isolated UID cannot race.
  # Install path (fresh agent) has no session yet → loop no-ops.
  # Reapply / migration path (running agent) → operator must stop first.
  # BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING is an opt-out for sandboxed
  # smoke fixtures that simulate isolation prepare without a real tmux
  # binary on the host.
  if [[ "${BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING:-0}" != "1" ]]; then
    local _quiesce_session=""
    _quiesce_session="$(bridge_agent_session "$agent" 2>/dev/null || printf '')"
    if [[ -n "$_quiesce_session" ]] \
        && command -v tmux >/dev/null 2>&1 \
        && bridge_tmux_session_exists "$_quiesce_session"; then
      bridge_die "isolation v2 prepare requires the agent session to be stopped: tmux session '$_quiesce_session' is alive (channel/workdir mutations are not race-safe on a live isolated UID). Run \`agb agent stop $agent\` first, then retry."
    fi
  fi

  # v2: all isolation surfaces use group setgid; no named-user ACLs are
  # applied during prepare. setfacl is no longer a hard prereq here.
  user_home="$(bridge_agent_linux_user_home "$os_user")"
  env_file="$(bridge_agent_linux_env_file "$agent")"
  runtime_state_dir="$(bridge_agent_runtime_state_dir "$agent")"
  log_dir="$(bridge_agent_log_dir "$agent")"
  audit_file="$(bridge_agent_audit_log_file "$agent")"
  history_file="$(bridge_history_file_for_agent "$agent")"
  request_dir="$(bridge_queue_gateway_requests_dir "$agent")"
  response_dir="$(bridge_queue_gateway_responses_dir "$agent")"
  local queue_gateway_root=""
  local queue_gateway_agent_dir=""
  queue_gateway_root="$(bridge_queue_gateway_root)"
  queue_gateway_agent_dir="$(bridge_queue_gateway_agent_dir "$agent")"

  bridge_linux_ensure_os_user "$os_user" "$user_home"
  bridge_linux_ensure_user_home "$os_user" "$user_home"
  bridge_linux_install_agent_bridge_symlink "$os_user" "$user_home" "$BRIDGE_HOME"

  # v2 layout: lay down the per-agent private root before any ACL grants
  # touch its children. The contract is:
  #   $BRIDGE_AGENT_ROOT_V2/<agent>            owner=root, group=ab-agent-<name>, mode 2750
  #   ├── home/, workdir/, runtime/, logs/,
  #   │   requests/, responses/                 owner=isolated, group=ab-agent-<name>, mode 2770
  #   └── credentials/                          owner=controller, group=ab-agent-<name>, mode 2750
  #       └── launch-secrets.env                owner=controller, group=ab-agent-<name>, mode 0640
  # Root mode 2750 (group r-x, no group write) is load-bearing: the
  # isolated UID is in the agent group, so any group-write at the root
  # would let it `rmdir credentials/` or `mv credentials creds.bak`
  # regardless of credentials/'s own mode (POSIX requires write on the
  # *parent* directory to delete or rename an entry inside it). 2750
  # blocks that. The credentials/ subdir's own 2750 + controller-owner
  # then prevents writes *inside* credentials/.
  # Trade-off: the controller — also a group member, but not the owner —
  # cannot directly `mkdir runtime/` from non-prepare codepaths under
  # 2750 either. Controller writes that must land under the per-agent
  # root (notably `runtime/history.env` via
  # `bridge_load_static_agent_history` ->
  # `bridge_write_agent_state_file`) therefore go through a sudo-handoff
  # helper in lib/bridge-state.sh, mirroring the
  # `bridge_install_isolated_home_settings` cross-UID write pattern in
  # lib/bridge-hooks.sh.
  local _v2_agent_group _v2_agent_root _v2_credentials_dir _v2_subdir
  _v2_agent_group="$(bridge_isolation_v2_agent_group_name "$agent")" \
    || bridge_die "isolation v2: invalid agent name '$agent' for group composition"
  bridge_isolation_v2_ensure_group "$_v2_agent_group" \
    || bridge_die "isolation v2: cannot ensure group '$_v2_agent_group'"
  bridge_isolation_v2_ensure_user_in_group "$os_user" "$_v2_agent_group" \
    || bridge_die "isolation v2: cannot add '$os_user' to '$_v2_agent_group'"
  bridge_isolation_v2_ensure_user_in_group "$controller_user" "$_v2_agent_group" \
    || bridge_die "isolation v2: cannot add controller '$controller_user' to '$_v2_agent_group'"

  # Shared-group membership. PR-C migration adds existing agents to
  # ab-shared, but a new/reapplied agent through prepare must also join so
  # bridge_linux_share_plugin_catalog can read the shared plugin cache.
  # ensure_group is idempotent. Controller missing from ab-shared is
  # recoverable iff the operator's own context can still read the shared
  # plugin cache, so escalate the warn to die only when readability fails.
  local _v2_shared_grp="${BRIDGE_SHARED_GROUP:-ab-shared}"
  bridge_isolation_v2_ensure_group "$_v2_shared_grp" \
    || bridge_die "isolation v2: cannot ensure shared group '$_v2_shared_grp'"
  bridge_isolation_v2_ensure_user_in_group "$os_user" "$_v2_shared_grp" \
    || bridge_die "isolation v2: cannot add '$os_user' to shared group '$_v2_shared_grp'"
  if ! bridge_isolation_v2_ensure_user_in_group "$controller_user" "$_v2_shared_grp"; then
    bridge_warn "isolation v2: controller '$controller_user' membership update for '$_v2_shared_grp' failed; verifying shared plugin cache readability"
    local _v2_shared_plugins_root
    _v2_shared_plugins_root="$(bridge_isolation_v2_shared_plugins_root 2>/dev/null || printf '')"
    if [[ -n "$_v2_shared_plugins_root" && -e "$_v2_shared_plugins_root" \
          && ! -r "$_v2_shared_plugins_root" ]]; then
      bridge_die "isolation v2: controller cannot read shared plugin cache '$_v2_shared_plugins_root'; group membership update for '$_v2_shared_grp' must succeed (re-login the controller after manual usermod, then retry)"
    fi
  fi

  _v2_agent_root="$(bridge_isolation_v2_agent_root "$agent")" \
    || bridge_die "isolation v2: cannot resolve per-agent root for '$agent'"
  bridge_linux_sudo_root mkdir -p "$_v2_agent_root"
  bridge_linux_sudo_root chown root: "$_v2_agent_root"
  bridge_linux_sudo_root chgrp "$_v2_agent_group" "$_v2_agent_root"
  # 2750 (root-owner, group r-x, no group write at the root level): the
  # isolated UID — in the agent group — cannot rmdir/rename
  # credentials/ here, so the credentials isolation contract holds.
  # Controller writes under per-agent root that previously relied on
  # group write at the root (mkdir runtime/, etc.) now go through the
  # sudo-handoff helpers (see lib/bridge-state.sh
  # bridge_state_sudo_install_v2_file). See the layout comment above.
  bridge_linux_sudo_root chmod 2750 "$_v2_agent_root"
  for _v2_subdir in home workdir runtime logs requests responses; do
    bridge_linux_sudo_root mkdir -p "$_v2_agent_root/$_v2_subdir"
    bridge_linux_sudo_root chown "$os_user" "$_v2_agent_root/$_v2_subdir"
    bridge_linux_sudo_root chgrp "$_v2_agent_group" "$_v2_agent_root/$_v2_subdir"
    bridge_linux_sudo_root chmod 2770 "$_v2_agent_root/$_v2_subdir"
  done
  _v2_credentials_dir="$(bridge_isolation_v2_agent_credentials_dir "$agent")"
  bridge_linux_sudo_root mkdir -p "$_v2_credentials_dir"
  bridge_linux_sudo_root chown "$controller_user" "$_v2_credentials_dir"
  bridge_linux_sudo_root chgrp "$_v2_agent_group" "$_v2_credentials_dir"
  bridge_linux_sudo_root chmod 2750 "$_v2_credentials_dir"
  # If a launch-secrets.env already exists (carried over from a previous
  # prepare cycle or seeded by migration), normalize its ownership/mode.
  # We do not create it here — the operator/migration tool plants it.
  local _v2_secrets_file
  _v2_secrets_file="$(bridge_isolation_v2_agent_secret_env_file "$agent")"
  if bridge_linux_sudo_root test -f "$_v2_secrets_file"; then
    bridge_linux_sudo_root chown "$controller_user" "$_v2_secrets_file"
    bridge_linux_sudo_root chgrp "$_v2_agent_group" "$_v2_secrets_file"
    bridge_linux_sudo_root chmod 0640 "$_v2_secrets_file"
  fi

  bridge_linux_sudo_root mkdir -p "$runtime_state_dir" "$log_dir" "$queue_gateway_root" "$queue_gateway_agent_dir" "$request_dir" "$response_dir" "$(dirname "$history_file")"
  bridge_linux_sudo_root touch "$audit_file" "$history_file"

  # memory-daily state trees for the harvester (issue #219):
  # v2 layout: per-agent memory-daily lives inside the per-agent root
  # (group-isolated), shared aggregate lives under BRIDGE_SHARED_ROOT so
  # other agents' harvesters can read it via ab-shared. Group setgid +
  # 2770 covers both isolated UID writes to the per-agent dir and
  # controller reads of the shared aggregate; no named-user ACL needed.
  local memory_daily_agent_dir memory_daily_shared_aggregate_dir
  memory_daily_agent_dir="$(bridge_isolation_v2_agent_memory_daily_root "$agent")"
  memory_daily_shared_aggregate_dir="$(bridge_isolation_v2_memory_daily_shared_aggregate_dir)"
  bridge_linux_sudo_root mkdir -p "$memory_daily_agent_dir" "$memory_daily_shared_aggregate_dir"

  bridge_linux_sudo_root chown -R "$os_user" "$workdir"
  bridge_linux_sudo_root chown -R "$os_user" "$runtime_state_dir" "$log_dir"
  bridge_linux_sudo_root chown "$os_user" "$audit_file" "$history_file"

  # memory-daily transcripts read-access (issue #219 v1.3): grant the
  # controller user r-X on the isolated user's ~/.claude/projects/ so the
  # (controller-UID) harvester can _scan_transcripts under the target.
  # We intentionally do NOT grant write — this is a strict read lens.
  #
  # We pre-create $user_home/.claude (owned by the isolated UID, 0700) so
  # the default ACL lands before the first Claude session runs. Otherwise a
  # fresh agent's first `.claude/projects/` directory would be created
  # without the controller r-X inheritance, and the next harvester run
  # would fall back to --skipped-permission until the next reapply.
  local isolated_claude_dir="$user_home/.claude"
  bridge_linux_sudo_root mkdir -p "$isolated_claude_dir"
  bridge_linux_sudo_root chown "$os_user" "$isolated_claude_dir" >/dev/null 2>&1 || true
  # v2: chgrp ab-agent-<name> + chmod 2750 (setgid so new subdirs like
  # projects/ inherit the group) so the controller (group member of
  # ab-agent-<name>) can reach ~/.claude/projects/ for the memory-daily
  # harvester without any named-user ACL.
  local _claude_v2_grp=""
  _claude_v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
  [[ -n "$_claude_v2_grp" ]] \
    || bridge_die "isolation v2: cannot resolve agent group for ~/.claude of '$agent'"
  bridge_linux_sudo_root chgrp "$_claude_v2_grp" "$isolated_claude_dir" \
    || bridge_die "isolation v2: chgrp $_claude_v2_grp on '$isolated_claude_dir' failed"
  bridge_linux_sudo_root chmod 2750 "$isolated_claude_dir" \
    || bridge_die "isolation v2: chmod 2750 on '$isolated_claude_dir' failed"
  # Channel-ownership-aware plugin sharing. Without this the isolated UID's
  # ~/.claude/plugins/ is empty and Claude starts with no MCP servers loaded
  # (Teams/ms365/cosmax-* all silently missing). The helper writes a per-UID
  # installed_plugins.json that lists only this agent's declared channel
  # plugins, grants r-X on each declared plugin's install path, and exposes
  # catalog metadata read-only. plugins/data/ stays writable by the isolated
  # UID so plugin runtime state still works.
  bridge_linux_share_plugin_catalog "$os_user" "$user_home" "$controller_user" "$agent"

  # Channel state-dir symlinks. Without this, MCP plugin servers running
  # under the isolated UID write to a brand-new empty `~/.<channel>` tree
  # and the controller-side webhook dispatcher (which writes to the
  # controller-side `$workdir/.<channel>/`) never reaches the plugin.
  # Symptom: inbound Teams/Discord/Telegram/ms365 messages silently disappear
  # and operators discover the gap only by trying to send a test message.
  #
  # For each declared `plugin:<id>[@<mkt>]` channel in the agent's roster
  # entry that has a known state-dir helper, plant a root-owned symlink at
  # `$user_home/.claude/channels/<id>` -> `$workdir/.<id>/`. The symlink
  # itself is root-owned (the isolated UID cannot relink it elsewhere); the
  # target dir is 2770/agent-group for traversal; dotenv/state files inside
  # are 0600/isolated-UID (v3 contract). The controller reads them via
  # passwordless sudo, not group visibility.
  local _ch_csv=""
  local _ch_token=""
  local _ch_id=""
  local _ch_target=""
  _ch_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
  if [[ -n "$_ch_csv" ]]; then
    local -a _ch_split=()
    IFS=',' read -ra _ch_split <<<"$_ch_csv"
    for _ch_token in "${_ch_split[@]}"; do
      _ch_token="${_ch_token// /}"
      [[ "$_ch_token" == plugin:* ]] || continue
      _ch_id="${_ch_token#plugin:}"
      _ch_id="${_ch_id%%@*}"
      case "$_ch_id" in
        discord)  _ch_target="$(bridge_agent_default_discord_state_dir "$agent")"  ;;
        telegram) _ch_target="$(bridge_agent_default_telegram_state_dir "$agent")" ;;
        teams)    _ch_target="$(bridge_agent_default_teams_state_dir "$agent")"    ;;
        ms365)    _ch_target="$(bridge_agent_default_ms365_state_dir "$agent")"    ;;
        *) continue ;;
      esac
      if ! bridge_linux_install_isolated_channel_symlink \
              "$os_user" "$user_home" "$controller_user" "$_ch_id" "$_ch_target" "$agent"; then
        bridge_die "isolation channel symlink: failed to install '$_ch_id' symlink for agent '$agent'; inspect/quarantine $user_home/.claude/channels/ before retrying"
      fi
    done
  fi

  # v2: ~/.claude is chgrp'd to ab-agent-<name> + chmod 2750 above, and
  # the isolated UID is the directory owner. The controller is a member
  # of ab-agent-<name> per PR-C, so it reaches user_home/.claude/projects/
  # via group r-x without any named-user ACL or ancestor traverse grant.
  bridge_write_linux_agent_env_file "$agent" "$env_file"
  # env_file ownership: chgrp/chmod is handled inside bridge_write_linux_agent_env_file's
  # v2 branch (chown controller, chgrp ab-agent-<name>, chmod 0640).

  # v0.9.7 (refs #781): the matrix is the single ownership/mode contract
  # for the v2 layout. The structural prerequisites above (group/user
  # creation, mkdir, initial chown/chgrp on the writable subdirs, agent
  # env file, channel symlinks) remain unchanged — but applying the
  # matrix at the END of prepare ensures every row the migrate/reapply
  # tools assert is also asserted at create time. This closes the RC1
  # window where the per-agent state/agents/<X>/ leaf was created
  # outside prepare's purview and inherited the daemon's controller
  # group, then drifted from the v2 contract for the lifetime of the
  # install. Idempotent and silent on a clean tree.
  if command -v bridge_isolation_v2_apply_grant_matrix_for_agent >/dev/null 2>&1; then
    # r10 codex catch — was `|| true`. Propagate matrix-apply failure
    # so prepare's caller (bridge-agent.sh, bridge-start.sh) returns
    # non-zero. Operator otherwise sees a green agent create that
    # immediately fails the first verify.
    if ! bridge_isolation_v2_apply_grant_matrix_for_agent "$agent" --apply >/dev/null 2>&1; then
      bridge_warn "bridge_linux_prepare_agent_isolation: grant-matrix apply FAIL agent=$agent"
      return 1
    fi
  fi
}
bridge_linux_install_isolated_channel_symlink() {
  # Plant a root-owned symlink at $user_home/.claude/channels/<channel>
  # pointing to the controller-side per-agent state dir for that channel.
  # Idempotent: replaces a stale symlink at the link path; refuses to clobber
  # a real file/directory at either the parent root or the link itself, and
  # creates the controller-side target dir (chowned to the isolated UID, ACL
  # granted to the controller user) when it does not yet exist.
  #
  # Returns non-zero on any unsafe state so the caller (
  # bridge_linux_prepare_agent_isolation) can bridge_die instead of leaving
  # a split-state isolated-local channel dir behind.
  local os_user="$1"
  local user_home="$2"
  local controller_user="$3"
  local channel="$4"
  local target="$5"
  local agent="${6-}"

  [[ -n "$os_user" && -n "$user_home" && -n "$controller_user" && -n "$channel" && -n "$target" ]] \
    || { bridge_warn "bridge_linux_install_isolated_channel_symlink: missing arg"; return 1; }
  if [[ -z "$agent" ]]; then
    bridge_warn "bridge_linux_install_isolated_channel_symlink: v2 mode requires the agent argument"
    return 1
  fi

  local channels_root="$user_home/.claude/channels"
  local link_path="$channels_root/$channel"

  # Parent guard: refuse to follow a pre-existing symlink at $channels_root,
  # and refuse to clobber a non-directory there. Without this, a malicious
  # or stale `~/.claude/channels` symlink would let the subsequent
  # `mkdir/chown/chmod` walk into an attacker-chosen target.
  if bridge_linux_sudo_root test -L "$channels_root"; then
    bridge_warn "isolation channel symlink: $channels_root is a symlink, refusing to follow"
    return 1
  fi
  if bridge_linux_sudo_root test -e "$channels_root" \
      && ! bridge_linux_sudo_root test -d "$channels_root"; then
    bridge_warn "isolation channel symlink: $channels_root exists and is not a directory, refusing to clobber"
    return 1
  fi

  # Critical install steps explicitly propagate non-zero. The caller
  # (bridge_linux_prepare_agent_isolation) is invoked under `||`-disabled
  # errexit on the migration/reapply path, so silent `|| true` suffixes
  # would cause the helper to report success while a stale or partial
  # symlink remains. ACL add is best-effort because earlier helpers
  # (recursive_read_paths/recursive_write_paths) already cover access.
  bridge_linux_sudo_root mkdir -p "$channels_root" || {
    bridge_warn "isolation channel symlink: mkdir $channels_root failed"
    return 1
  }
  # r2 TOCTOU re-check: the initial guard only proves the path was not a
  # symlink at guard time. Between the guard and each mutation below, the
  # isolated UID could race a symlink swap if it owns the parent (`.claude`).
  # bridge_die hard-stops the isolation prepare loop, which is correct: we
  # cannot proceed if the path was tampered with mid-setup.
  if bridge_linux_sudo_root test -L "$channels_root"; then
    bridge_die "channels parent: raced into a symlink between guard and mkdir at $channels_root"
  fi
  bridge_linux_sudo_root chown root:root "$channels_root" || {
    bridge_warn "isolation channel symlink: chown $channels_root failed"
    return 1
  }
  if bridge_linux_sudo_root test -L "$channels_root"; then
    bridge_die "channels parent: raced into a symlink after chown at $channels_root"
  fi
  bridge_linux_sudo_root chmod 0755 "$channels_root" || {
    bridge_warn "isolation channel symlink: chmod $channels_root failed"
    return 1
  }
  if bridge_linux_sudo_root test -L "$channels_root"; then
    bridge_die "channels parent: raced into a symlink after chmod at $channels_root"
  fi
  # v2: $channels_root is mode 0755 root-owned; isolated UID reaches it
  # via base-readable `other::r-x`. No named-user ACL needed.

  # Target dir: create on demand for declared channels whose `.<channel>`
  # has not yet been initialized (typical for fresh isolated agents that
  # never opened the channel). Owned by the isolated UID so the plugin
  # server can write its own state; controller user gets rwX so the
  # webhook dispatcher and channel-health probe can see it.
  #
  # Reject a non-directory at the target path: a stray file there means
  # something else owns the path and we must not chmod/chown it or symlink
  # to it. The caller bridge_die's on our return 1, so the operator has to
  # quarantine the file before reapply continues.
  if bridge_linux_sudo_root test -e "$target" \
      && ! bridge_linux_sudo_root test -d "$target"; then
    bridge_warn "isolation channel symlink: target $target exists and is not a directory, refusing to clobber"
    return 1
  fi
  if ! bridge_linux_sudo_root test -d "$target"; then
    bridge_linux_sudo_root mkdir -p "$target" || {
      bridge_warn "isolation channel symlink: mkdir target $target failed"
      return 1
    }
    # PR-E r4.4: TOCTOU re-check after mkdir. mkdir -p on an existing
    # symlink succeeds and walks into the symlink target; reject before
    # any further chown/chmod/chgrp.
    if bridge_linux_sudo_root test -L "$target"; then
      bridge_warn "isolation channel symlink: $target became a symlink between guard and mkdir, refusing to mutate"
      return 1
    fi
    bridge_linux_sudo_root chown "$os_user" "$target" || {
      bridge_warn "isolation channel symlink: chown target $target failed"
      return 1
    }
    # v2 mode/group/setgid is normalized in the dedicated block below.
  fi

  # v2 normalize block — applies whether $target was just created or
  # already existed. setgid (2770) ensures new files inside inherit
  # ab-agent-<name>; combined with the agent-launch umask 007 wired into
  # bridge-run.sh (`bridge_run_apply_v2_umask_if_needed`), most files
  # created by the isolated process land at 0660/group=ab-agent-<name>.
  # Exception: channel dotenv/state files (.env, access.json, etc.) land
  # at 0600/isolated-UID (v3 contract); the controller reads them via
  # passwordless sudo, not the group bit.
  # r4.4 TOCTOU guard: refuse to mutate a symlink even though `test -d`
  # earlier passed (a symlink-to-dir slips through that check).
  if bridge_linux_sudo_root test -L "$target"; then
    bridge_warn "isolation v2 channel target: $target is a symlink, refusing to chgrp/chmod (target may be attacker-controlled)"
    return 1
  fi
  if ! bridge_linux_sudo_root test -d "$target"; then
    bridge_warn "isolation v2 channel target: $target disappeared between checks"
    return 1
  fi
  local _v2_grp
  _v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')" \
    || _v2_grp=""
  [[ -n "$_v2_grp" ]] || bridge_die "isolation v2: cannot resolve agent group for channel target '$target'"
  bridge_linux_sudo_root chown "$os_user" "$target" \
    || bridge_die "isolation v2: chown $os_user on channel target '$target' failed"
  bridge_linux_sudo_root chgrp "$_v2_grp" "$target" \
    || bridge_die "isolation v2: chgrp $_v2_grp on channel target '$target' failed"
  bridge_linux_sudo_root chmod 2770 "$target" \
    || bridge_die "isolation v2: chmod 2770 on channel target '$target' failed"

  # Link path: only replace a pre-existing symlink. A real file or directory
  # at this path likely contains uncommitted state (e.g. an isolated-local
  # `.<channel>/` that the plugin started writing into before the operator
  # noticed the missing symlink) and silently overwriting it would lose
  # that state. Bail and require manual quarantine.
  if bridge_linux_sudo_root test -L "$link_path"; then
    bridge_linux_sudo_root rm -f "$link_path" || {
      bridge_warn "isolation channel symlink: rm stale link $link_path failed"
      return 1
    }
  elif bridge_linux_sudo_root test -e "$link_path"; then
    bridge_warn "isolation channel symlink: $link_path is not a symlink, refusing to clobber (move it aside and rerun)"
    return 1
  fi

  bridge_linux_sudo_root ln -s "$target" "$link_path" || {
    bridge_warn "isolation channel symlink: ln -s $target $link_path failed"
    return 1
  }
  bridge_linux_sudo_root chown -h root:root "$link_path" >/dev/null 2>&1 || true
}

bridge_agent_default_home() {
  local agent="$1"
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" && -n "$agent" ]]; then
    printf '%s/%s/home' "$BRIDGE_AGENT_ROOT_V2" "$agent"
    return 0
  fi
  printf '%s/%s' "$BRIDGE_AGENT_HOME_ROOT" "$agent"
}

bridge_agent_claude_home_dir() {
  local agent="$1"
  local os_user=""

  if ! bridge_isolation_disabled_by_env && bridge_agent_linux_user_isolation_effective "$agent"; then
    os_user="$(bridge_agent_os_user "$agent")"
    if [[ -n "$os_user" ]]; then
      bridge_agent_linux_user_home "$os_user"
      return 0
    fi
  fi

  bridge_agent_default_home "$agent"
}

bridge_agent_claude_config_dir() {
  local agent="$1"
  printf '%s/.claude' "$(bridge_agent_claude_home_dir "$agent")"
}

# bridge_ensure_claude_first_run_config <agent>
#
# Issue #1073 — pre-seed a Claude agent's per-agent ``CLAUDE_CONFIG_DIR``
# so the CLI skips first-run interactive prompts (theme picker,
# onboarding, project-trust dialog). Without this, a fresh non-admin
# Claude channel agent that has its own ``CLAUDE_CONFIG_DIR`` cannot
# start: the picker blocks the tmux session, ``bridge-run.sh``'s
# foreground detection kills the session, and relaunch loops
# indefinitely (admin agents reuse the controller's already-onboarded
# ``~/.claude`` and never trip this).
#
# Writes ``<config_dir>/.claude.json`` with the same bootstrap payload
# ``auth claude-token sync`` uses (``hasCompletedOnboarding``,
# ``firstStartTime``, project ``hasTrustDialogAccepted`` etc.). The
# companion ``skipDangerousModePermissionPrompt`` key for the Bypass
# Permissions warning is a managed default in ``settings.json``
# (`bridge-hooks.py::managed_claude_settings_defaults`) — that side
# rides through the existing render path.
#
# Idempotent: ``setdefault`` semantics on every bootstrap key. Safe to
# call from both ``agent create`` (first-run wire-up) and
# ``bridge-start.sh`` (defensive seed for agents created before this
# fix). No-op when the agent is not a Claude agent.
#
# For linux-user isolated agents: this runs as controller BEFORE
# ``bridge_linux_prepare_agent_isolation`` chowns the home tree, so the
# seeded file naturally inherits the isolated UID with the rest of the
# scaffold. For start-path defensive seeding on an already-isolated
# agent, the seed becomes a no-op when the file already exists with the
# bootstrap keys (or skips when the controller cannot write).
bridge_ensure_claude_first_run_config() {
  local agent="$1"
  local workdir="${2-}"
  local engine=""
  local config_dir=""
  local helper=""

  [[ -n "$agent" ]] || return 0

  engine="$(bridge_agent_engine "$agent" 2>/dev/null || true)"
  [[ "$engine" == "claude" ]] || return 0

  config_dir="$(bridge_agent_claude_config_dir "$agent" 2>/dev/null || true)"
  [[ -n "$config_dir" ]] || return 0

  if [[ -z "$workdir" ]]; then
    workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
  fi

  helper="${BRIDGE_SCRIPT_DIR:-}/scripts/python-helpers/seed-claude-first-run-config.py"
  if [[ ! -f "$helper" ]]; then
    # Source-checkout / bridge-home divergence — silently skip rather
    # than abort the create / start path. The seeded keys are a
    # defense-in-depth layer; existing `auth claude-token sync` flows
    # still cover the operator-driven case.
    return 0
  fi

  # Codex r2 BLOCKING: post-`bridge_linux_prepare_agent_isolation`,
  # the isolated agent's `<home>/.claude/` is owned `iso_user:iso_grp`
  # mode 2750 (`lib/bridge-agents.sh:3745-3759`). The controller is only
  # a group member (r-x), NOT a group writer — a plain controller
  # python3 write into that dir FAILS, gets swallowed by `|| return 0`,
  # and the chown step never repairs anything. The seed has to be
  # written through the privileged handoff.
  #
  # For linux-user isolated agents: run the helper via
  # `bridge_linux_sudo_root sudo -u <iso_user>` so the write happens AS
  # the isolated UID — file lands `iso_user:iso_grp` mode 0644 naturally
  # readable by Claude CLI launched under that UID. For non-isolated
  # agents: plain controller python3.
  local _seed_isolated=0
  local _iso_user=""
  if ! bridge_isolation_disabled_by_env 2>/dev/null \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    _iso_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    [[ -n "$_iso_user" ]] && command -v bridge_linux_sudo_root >/dev/null 2>&1 \
      && _seed_isolated=1
  fi

  if (( _seed_isolated == 1 )); then
    # Codex r3 BLOCKING fix: the project's sudoers contract whitelists
    # operator → isolated user for `tmux` + `bash` ONLY (see
    # `lib/bridge-migration.sh:773-783` + `bridge-agent.sh:492-499`).
    # Direct `sudo -u <iso> python3 ...` is NOT covered; existing
    # isolated-user helpers (`lib/bridge-isolation-helpers.sh:104-112`)
    # wrap the inner command in `bash -c '...'` so the whitelist matches.
    # Also call `sudo` directly (no `bridge_linux_sudo_root` wrap) so we
    # don't end up with `sudo -n sudo -n -u <iso> ...` (double sudo).
    local _bash_bin="${BRIDGE_BASH_BIN:-bash}"
    sudo -n -u "$_iso_user" "$_bash_bin" -c \
      'exec python3 "$1" "$2" "$3"' -- "$helper" "$config_dir" "$workdir" \
      >/dev/null 2>&1 || return 0
  else
    python3 "$helper" "$config_dir" "$workdir" >/dev/null 2>&1 || return 0
  fi
  return 0
}

bridge_agent_onboarding_state() {
  local agent="$1"
  local path=""
  local line=""

  for path in "$(bridge_agent_workdir "$agent")/SESSION-TYPE.md" "$(bridge_agent_default_home "$agent")/SESSION-TYPE.md"; do
    [[ -f "$path" ]] || continue
    line="$(grep -E 'Onboarding State:[[:space:]]*[A-Za-z0-9._-]+' "$path" 2>/dev/null | head -n 1 || true)"
    if [[ "$line" =~ Onboarding[[:space:]]+State:[[:space:]]*([A-Za-z0-9._-]+) ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done

  printf '%s' "missing"
}

bridge_agent_onboarding_complete() {
  local agent="$1"
  [[ "$(bridge_agent_onboarding_state "$agent")" == "complete" ]]
}

bridge_agent_should_stop_on_attached_clean_exit() {
  local agent="$1"

  bridge_agent_is_admin "$agent" || return 1
  bridge_agent_onboarding_complete "$agent" && return 1
  return 0
}

bridge_agent_default_profile_home() {
  local agent="$1"
  # v2: profile lives under workdir, not home. Every runtime resolver
  # (bridge-skills.sh:230, bridge-setup.sh:90/823, bridge-agent.sh:1275)
  # reads CLAUDE.md from workdir, so the deploy target (this function)
  # must point at workdir too, otherwise `agent-bridge profile deploy`
  # would land in v2 home/ where nothing reads it.
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" && -n "$agent" ]]; then
    printf '%s/%s/workdir' "$BRIDGE_AGENT_ROOT_V2" "$agent"
    return 0
  fi
  bridge_agent_default_home "$agent"
}

bridge_agent_default_discord_state_dir() {
  local agent="$1"
  printf '%s/.discord' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_discord_state_dir() {
  local agent="$1"
  bridge_agent_default_discord_state_dir "$agent"
}

bridge_agent_default_telegram_state_dir() {
  local agent="$1"
  printf '%s/.telegram' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_telegram_state_dir() {
  local agent="$1"
  bridge_agent_default_telegram_state_dir "$agent"
}

bridge_agent_default_teams_state_dir() {
  local agent="$1"
  printf '%s/.teams' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_teams_state_dir() {
  local agent="$1"
  bridge_agent_default_teams_state_dir "$agent"
}

bridge_agent_default_ms365_state_dir() {
  local agent="$1"
  printf '%s/.ms365' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_ms365_state_dir() {
  local agent="$1"
  bridge_agent_default_ms365_state_dir "$agent"
}

bridge_agent_default_mattermost_state_dir() {
  local agent="$1"
  printf '%s/.mattermost' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_mattermost_state_dir() {
  local agent="$1"
  bridge_agent_default_mattermost_state_dir "$agent"
}

bridge_agent_workdir() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_WORKDIR[$agent]-}"

  # v2 anchor precedence is conditional on isolation mode (issue #895,
  # ymprince WSL2 report, v0.13.8):
  #
  #   * linux-user isolation — the per-agent private root (root-owned,
  #     group r-x, mode 2750) IS the isolation contract. An explicit
  #     workdir outside that root would launch the agent into a
  #     directory the per-agent group cannot reach, or worse, a
  #     directory that other isolated UIDs can reach, silently breaking
  #     per-agent privacy. Static rosters that need a non-default
  #     location should set BRIDGE_DATA_ROOT (which moves the v2 anchor
  #     for every agent), not BRIDGE_AGENT_WORKDIR per-agent.
  #
  #   * shared isolation (default for `agb --claude --name <agent>`
  #     dynamic spawn) — no per-UID privacy invariant to enforce. The
  #     launcher captures the operator's cwd into
  #     BRIDGE_AGENT_WORKDIR[<agent>] (agent-bridge:1199), and
  #     unconditionally rewriting that to the v2 anchor leaves the
  #     agent in an empty stub with the operator's project invisible.
  #     Fall through to the explicit-then-default resolution so the
  #     operator's cwd is honored for shared dynamic agents.
  local _isolation_mode=""
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" && -n "$agent" ]]; then
    _isolation_mode="$(bridge_agent_isolation_mode "$agent" 2>/dev/null || printf '')"
    if [[ "$_isolation_mode" == "linux-user" ]]; then
      printf '%s/%s/workdir' "$BRIDGE_AGENT_ROOT_V2" "$agent"
      return 0
    fi
    # Static shared agents created before the v2 anchor split still keep
    # their real state/cwd under <agent>/workdir while roster workdir may
    # point at the base agent dir. Preserve explicit custom shared cwd for
    # dynamic agents and static project overrides; only align legacy
    # default-home static rows to the existing v2 workdir.
    if [[ "$(bridge_agent_source "$agent")" == "static" ]]; then
      local _legacy_v2_workdir="$BRIDGE_AGENT_ROOT_V2/$agent/workdir"
      local _default_home=""
      local _legacy_base_home="$BRIDGE_AGENT_HOME_ROOT/$agent"
      _default_home="$(bridge_agent_default_home "$agent")"
      if [[ -d "$_legacy_v2_workdir" && ( -z "$explicit" || "$explicit" == "$_default_home" || "$explicit" == "$_legacy_base_home" ) ]]; then
        printf '%s' "$_legacy_v2_workdir"
        return 0
      fi
    fi
    # Other non-linux-user modes (shared dynamic, unknown, "") fall through.
  fi

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  bridge_agent_default_home "$agent"
}

bridge_agent_profile_home() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_PROFILE_HOME[$agent]-}"
}

bridge_agent_launch_cmd_raw() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
}

bridge_trim_whitespace() {
  local raw="${1-}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s' "$raw"
}

bridge_append_csv_unique() {
  local csv="${1-}"
  local value="${2-}"
  local item=""

  value="$(bridge_trim_whitespace "$value")"
  [[ -n "$value" ]] || {
    printf '%s' "$csv"
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if [[ "$item" == "$value" ]]; then
      printf '%s' "$csv"
      return 0
    fi
  done

  if [[ -n "$csv" ]]; then
    printf '%s,%s' "$csv" "$value"
  else
    printf '%s' "$value"
  fi
}

bridge_merge_channels_csv() {
  local base="${1-}"
  local extra="${2-}"
  local merged="$base"
  local item=""
  local -a items=()

  [[ -n "$extra" ]] || {
    printf '%s' "$base"
    return 0
  }

  IFS=',' read -r -a items <<<"$extra"
  for item in "${items[@]}"; do
    merged="$(bridge_append_csv_unique "$merged" "$item")"
  done

  printf '%s' "$merged"
}

bridge_qualify_channel_item() {
  local item="${1-}"
  local plugin_name=""

  item="$(bridge_trim_whitespace "$item")"
  [[ -n "$item" ]] || {
    printf '%s' ""
    return 0
  }

  case "$item" in
    plugin:discord@claude-plugins-official|plugin:telegram@claude-plugins-official)
      printf '%s' "$item"
      return 0
      ;;
  esac

  if [[ "$item" == plugin:* && "$item" != *@* ]]; then
    plugin_name="${item#plugin:}"
    case "$plugin_name" in
      telegram|discord)
        printf 'plugin:%s@claude-plugins-official' "$plugin_name"
        return 0
        ;;
      teams)
        printf 'plugin:%s@agent-bridge' "$plugin_name"
        return 0
        ;;
    esac
  fi

  printf '%s' "$item"
}

bridge_channel_item_marketplace() {
  local item="${1-}"

  item="$(bridge_qualify_channel_item "$item")"
  [[ "$item" == plugin:*@* ]] || {
    printf '%s' ""
    return 0
  }

  printf '%s' "${item#*@}"
}

bridge_channel_item_is_development() {
  local item="${1-}"
  local marketplace=""

  item="$(bridge_qualify_channel_item "$item")"
  [[ "$item" == plugin:*@* ]] || return 1
  marketplace="$(bridge_channel_item_marketplace "$item")"
  [[ -n "$marketplace" && "$marketplace" != "claude-plugins-official" ]]
}

bridge_normalize_channels_csv() {
  local raw="${1:-}"
  local normalized=""
  local chunk=""
  local item=""
  local -a chunks=()

  raw="${raw//$'\n'/,}"
  IFS=',' read -r -a chunks <<<"$raw"
  for chunk in "${chunks[@]}"; do
    item="$(bridge_qualify_channel_item "$chunk")"
    normalized="$(bridge_append_csv_unique "$normalized" "$item")"
  done

  printf '%s' "$normalized"
}

bridge_extract_channels_from_command() {
  local command="${1:-}"
  local rest="$command"
  local value=""
  local csv=""

  while [[ "$rest" =~ --channels=([^[:space:]]+) ]]; do
    value="${BASH_REMATCH[1]}"
    csv="$(bridge_merge_channels_csv "$csv" "$(bridge_normalize_channels_csv "$value")")"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done

  rest="$command"
  while [[ "$rest" =~ --channels[[:space:]]+([^[:space:]]+) ]]; do
    value="${BASH_REMATCH[1]}"
    csv="$(bridge_merge_channels_csv "$csv" "$(bridge_normalize_channels_csv "$value")")"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done

  printf '%s' "$csv"
}

# Issue #835 Wave A' — body lives in scripts/python-helpers/. The
# previous in-line Python body was read through bash stdin redirection;
# on Homebrew Bash 5.3.9 that read can wedge in `heredoc_write` when
# this wrapper is invoked inside a command substitution from an
# absolute-path-sourced shell — same class that closed #800 / #815 /
# #827 / #840 for daemon, CLI, status, and session-id hot paths, and
# that Wave A flagged as upstream of the `bridge_agent_launch_cmd
# patch` wedge on the launch-cmd hot path. Moving the body into a real
# script bypasses the bash read entirely. (Forbidden pattern strings
# intentionally omitted from this comment so the footgun #11
# self-audit grep recipe does not flag a textual mention as a real
# callsite.)
bridge_extract_development_channels_from_command() {
  local command="${1:-}"

  bridge_require_python
  # #946 L1 (r2 codex P1 #2): use the substitution-safe check helper
  # instead of `bridge_resolve_script_dir_or_die`. This wrapper is called
  # from inside `$(...)` substitutions (e.g.
  # bridge_claude_launch_with_channel_state_dirs at lib/bridge-state.sh,
  # and the channel-health path in bridge-daemon.sh). If we called
  # `_or_die` here the parent's `bridge_die` would exit only the
  # substitution subshell — the caller would see an empty value and
  # continue, leaving the daemon-hang cascade #946 reproducible. The
  # `_check` form returns non-zero + writes one de-duplicated audit
  # line to BRIDGE_DAEMON_LOG so the failure is visible whether or not
  # the caller's context suppresses errexit, and the substitution
  # collapses to empty without ever forking python3 against a stale
  # path. bridge_with_timeout caps the subprocess at 15s so a hung
  # child (FS deadlock, slow disk) cannot wedge the parent tick.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  bridge_with_timeout 15 extract_dev_channels_from_command \
    python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/extract-dev-channels-from-command.py" \
    "$command"
}

bridge_channel_csv_contains() {
  local csv="${1:-}"
  local needle="${2:-}"
  local item=""
  local -a items=()

  [[ -n "$csv" && -n "$needle" ]] || return 1

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if [[ "$item" == "$needle" || "$item" == "$needle@"* ]]; then
      return 0
    fi
  done

  return 1
}

bridge_channel_item_requires_claude_plugin() {
  local item="${1:-}"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:*|server:*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_filter_claude_plugin_channels_csv() {
  local csv="${1:-}"
  local item=""
  local filtered=""
  local -a items=()

  [[ -n "$csv" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    item="$(bridge_qualify_channel_item "$item")"
    if bridge_channel_item_requires_claude_plugin "$item"; then
      filtered="$(bridge_append_csv_unique "$filtered" "$item")"
    fi
  done

  printf '%s' "$filtered"
}

bridge_filter_development_channels_csv() {
  local csv="${1:-}"
  local item=""
  local filtered=""
  local -a items=()

  [[ -n "$csv" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    item="$(bridge_qualify_channel_item "$item")"
    if bridge_channel_item_is_development "$item"; then
      filtered="$(bridge_append_csv_unique "$filtered" "$item")"
    fi
  done

  printf '%s' "$filtered"
}

bridge_filter_approved_channels_csv() {
  local csv="${1:-}"
  local item=""
  local filtered=""
  local -a items=()

  [[ -n "$csv" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    item="$(bridge_qualify_channel_item "$item")"
    if ! bridge_channel_item_is_development "$item"; then
      filtered="$(bridge_append_csv_unique "$filtered" "$item")"
    fi
  done

  printf '%s' "$filtered"
}

bridge_filter_server_channels_csv() {
  local csv="${1:-}"
  local item=""
  local filtered=""
  local -a items=()

  [[ -n "$csv" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    item="$(bridge_qualify_channel_item "$item")"
    if [[ "$item" == server:* ]]; then
      filtered="$(bridge_append_csv_unique "$filtered" "$item")"
    fi
  done

  printf '%s' "$filtered"
}

bridge_plugin_source_dir_for_channel_item() {
  local item="${1:-}"
  local plugin_id=""
  local plugin_name=""
  local marketplace=""
  local source_dir=""
  local plugins_root=""

  item="$(bridge_qualify_channel_item "$item")"
  [[ "$item" == plugin:*@* ]] || {
    printf '%s' ""
    return 0
  }

  plugin_id="${item#plugin:}"
  plugin_name="${plugin_id%@*}"
  marketplace="${plugin_id#*@}"

  if [[ "$marketplace" == "agent-bridge" && -d "$BRIDGE_SCRIPT_DIR/plugins/$plugin_name" ]]; then
    printf '%s' "$BRIDGE_SCRIPT_DIR/plugins/$plugin_name"
    return 0
  fi

  if plugins_root="$(bridge_isolation_v2_shared_plugins_root 2>/dev/null)" && [[ -n "$plugins_root" ]]; then
    source_dir="$(bridge_resolve_plugin_install_path "$plugin_id" "$plugins_root" 2>/dev/null || true)"
    if [[ -n "$source_dir" && -d "$source_dir" ]]; then
      printf '%s' "$source_dir"
      return 0
    fi
  fi

  if [[ -n "${HOME:-}" && -d "$HOME/.claude/plugins" ]]; then
    source_dir="$(bridge_resolve_plugin_install_path "$plugin_id" "$HOME/.claude/plugins" 2>/dev/null || true)"
    if [[ -n "$source_dir" && -d "$source_dir" ]]; then
      printf '%s' "$source_dir"
      return 0
    fi
  fi

  printf '%s' ""
}

bridge_plugin_mcp_server_selectors_csv_for_item() {
  local item="${1:-}"
  local source_dir=""
  local manifest=""

  item="$(bridge_qualify_channel_item "$item")"
  [[ "$item" == plugin:*@* ]] || {
    printf '%s' ""
    return 0
  }

  source_dir="$(bridge_plugin_source_dir_for_channel_item "$item")"
  manifest="$source_dir/.mcp.json"
  [[ -n "$source_dir" && -f "$manifest" ]] || {
    printf '%s' ""
    return 0
  }

  bridge_require_python
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/mcp-server-selectors-from-manifest.py" "$manifest"
}

bridge_dev_channel_server_selectors_csv() {
  local csv="${1:-}"
  local item=""
  local selectors=""
  local item_selectors=""
  local -a items=()

  [[ -n "$csv" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    item="$(bridge_qualify_channel_item "$item")"
    bridge_channel_item_is_development "$item" || continue
    bridge_plugin_mcp_is_probeable_item "$item" || continue
    item_selectors="$(bridge_plugin_mcp_server_selectors_csv_for_item "$item")"
    selectors="$(bridge_merge_channels_csv "$selectors" "$item_selectors")"
  done

  printf '%s' "$selectors"
}

bridge_channel_csv_is_subset() {
  local required_csv="${1:-}"
  local actual_csv="${2:-}"
  local need=""
  local have=""
  local matched=0

  IFS=',' read -r -a required_items <<<"$required_csv"
  IFS=',' read -r -a actual_items <<<"$actual_csv"

  for need in "${required_items[@]}"; do
    need="$(bridge_trim_whitespace "$need")"
    [[ -n "$need" ]] || continue
    matched=1
    for have in "${actual_items[@]}"; do
      have="$(bridge_trim_whitespace "$have")"
      [[ -n "$have" ]] || continue
      if [[ "$have" == "$need" || "$have" == "$need@"* || "$need" == "$have@"* ]]; then
        matched=0
        break
      fi
    done
    (( matched == 0 )) || return 1
  done

  return 0
}

bridge_agent_channels_csv() {
  local agent="$1"
  local explicit=""
  local inferred=""
  local inferred_dev=""

  explicit="${BRIDGE_AGENT_CHANNELS[$agent]-}"
  if [[ -n "$explicit" ]]; then
    bridge_normalize_channels_csv "$explicit"
    return 0
  fi

  inferred="$(bridge_extract_channels_from_command "$(bridge_agent_launch_cmd_raw "$agent")")"
  inferred_dev="$(bridge_extract_development_channels_from_command "$(bridge_agent_launch_cmd_raw "$agent")")"
  inferred="$(bridge_merge_channels_csv "$inferred" "$inferred_dev")"
  if [[ -n "$inferred" ]]; then
    printf '%s' "$inferred"
    return 0
  fi

  printf '%s' ""
}

bridge_agent_dev_channels_csv() {
  local agent="$1"
  bridge_filter_development_channels_csv "$(bridge_agent_channels_csv "$agent")"
}

bridge_agent_plugins_csv() {
  # Emit the per-agent BRIDGE_AGENT_PLUGINS allowlist (#272) as a normalized
  # CSV of plugin ids (no `plugin:` prefix). Tokens in the roster value may be
  # space- or comma-separated and may carry an optional `plugin:` prefix; both
  # forms are accepted and normalised here so isolation helpers can treat the
  # output as a flat plugin-id list (`<plugin>` or `<plugin>@<marketplace>`).
  # Returns the empty string when the entry is unset or contains no tokens.
  local agent="$1"
  local raw="${BRIDGE_AGENT_PLUGINS[$agent]-}"
  [[ -n "$raw" ]] || { printf ''; return 0; }

  local -a tokens=()
  local seen_marker=$'\x1f'
  local seen=""
  local token=""
  # shellcheck disable=SC2206 # split on whitespace+comma is intentional here.
  local IFS_orig="$IFS"
  IFS=$' \t\n,'
  read -ra _split <<<"$raw"
  IFS="$IFS_orig"
  for token in "${_split[@]}"; do
    token="${token## }"
    token="${token%% }"
    [[ -n "$token" ]] || continue
    # Accept `plugin:<id>` and `<id>` interchangeably; normalise to `<id>`.
    [[ "$token" == plugin:* ]] && token="${token#plugin:}"
    [[ -n "$token" ]] || continue
    case "$seen" in
      *"${seen_marker}${token}${seen_marker}"*) continue ;;
    esac
    seen="${seen}${seen_marker}${token}${seen_marker}"
    tokens+=("$token")
  done

  if (( ${#tokens[@]} == 0 )); then
    printf ''
    return 0
  fi
  (IFS=','; printf '%s' "${tokens[*]}")
}

bridge_agent_auto_accept_dev_channels_csv() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_AUTO_ACCEPT_DEV_CHANNELS[$agent]-}"

  if [[ -n "$explicit" ]]; then
    bridge_normalize_channels_csv "$explicit"
    return 0
  fi

  bridge_normalize_channels_csv "${BRIDGE_AUTO_ACCEPT_DEV_CHANNELS_DEFAULT:-plugin:teams@agent-bridge,plugin:mattermost@agent-bridge}"
}

bridge_agent_uses_discord_plugin() {
  local agent="$1"
  bridge_channel_csv_contains "$(bridge_agent_channels_csv "$agent")" "plugin:discord"
}

bridge_agent_uses_teams_plugin() {
  local agent="$1"
  bridge_channel_csv_contains "$(bridge_agent_channels_csv "$agent")" "plugin:teams"
}

bridge_agent_uses_mattermost_plugin() {
  local agent="$1"
  bridge_channel_csv_contains "$(bridge_agent_channels_csv "$agent")" "plugin:mattermost"
}

bridge_agent_discord_channel_from_access() {
  local agent="$1"
  local access_file=""

  access_file="$(bridge_agent_workdir "$agent")/.discord/access.json"
  [[ -f "$access_file" ]] || return 1

  bridge_require_python
  python3 - "$access_file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

groups = payload.get("groups") or {}
for key in groups.keys():
    if key:
        print(str(key))
        raise SystemExit(0)

raise SystemExit(1)
PY
}

bridge_agent_discord_channel_id() {
  local agent="$1"
  local explicit=""
  local inferred=""

  explicit="${BRIDGE_AGENT_DISCORD_CHANNEL_ID[$agent]-}"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  if bridge_agent_uses_discord_plugin "$agent"; then
    inferred="$(bridge_agent_discord_channel_from_access "$agent" 2>/dev/null || true)"
    if [[ -n "$inferred" ]]; then
      printf '%s' "$inferred"
      return 0
    fi
  fi

  printf '%s' ""
}

bridge_env_file_has_any_nonempty_key() {
  local file="$1"
  shift || true
  local key=""

  [[ -f "$file" ]] || return 1
  for key in "$@"; do
    if grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=[^[:space:]#].*" "$file"; then
      return 0
    fi
  done

  return 1
}

# Issue #534: isolation-aware readiness probe for channel `.env` files.
#
# Returns one of "present" | "missing" | "unreadable" | "controller-blind"
# via stdout. Suppresses raw grep stderr (which previously leaked
# `Permission denied` to the daemon log on every channel-health cycle in
# linux-user isolation). Distinguishes:
#
#   - "present"         — file readable and at least one of the requested
#                         keys has a non-empty value.
#   - "missing"         — file absent OR file readable but no requested key
#                         is present with a non-empty value.
#   - "unreadable"      — file exists but controller cannot read it AND the
#                         sudo-as-agent probe also fails (ownership/mode
#                         drift or sudo/probe drift); caller surfaces as
#                         channel-health miss.
#   - "controller-blind"— isolated agent + passwordless sudo unavailable;
#                         caller degrades to status=unknown (fail-open) to
#                         avoid a false channel_health_miss row.
#
# rc=1 vs rc=2 from grep:
#   The internal grep helper returns 1 on "no match" and 2 on file/permission
#   error. Bash conflates these into a single non-zero exit, so we
#   distinguish via a `[[ -r "$file" ]]` probe after the helper fails.
#
# Usage:
#   case "$(bridge_channel_env_file_readiness <agent> <item> <file> <key>...)" in
#     present)          ... ;;
#     missing)          ... ;;
#     unreadable)       ... ;;   # caller may then call bridge_channel_env_file_acl_diagnostic
#     controller-blind) ... ;;   # issue #832: isolated dotenv, controller cannot sudo to verify
#   esac
#
# Issue #832: when the controller cannot `[[ -r ]]` the file AND the agent
# is linux-user isolated AND passwordless sudo to the agent's os_user is
# unavailable, returns `"controller-blind"` instead of `"unreadable"`.
# That distinct state lets the caller emit a controller-blind reason and
# the status mapping degrade to `"unknown"` (fail-open) rather than
# firing a false channel_health_miss audit row.
bridge_channel_env_file_readiness() {
  local agent="$1"
  local item="$2"
  local file="$3"
  shift 3 || true
  local rc=0
  local sudo_rc=0
  local probe_rc=0

  if [[ ! -e "$file" ]]; then
    printf 'missing'
    return 0
  fi

  # First read attempt as the controller; suppress stderr so EACCES does
  # not leak to the daemon log. rc captured separately.
  rc=0
  bridge_env_file_has_any_nonempty_key "$file" "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    printf 'present'
    return 0
  fi

  if [[ -r "$file" ]]; then
    # File readable; helper just didn't find a non-empty matching key.
    printf 'missing'
    return 0
  fi

  # Issue #832: controller cannot read the file. Before declaring unreadable,
  # see if we can probe via the agent's isolated UID (linux-user mode only).
  # The agent's own UID can read its own dotenv when ACL drift left the
  # controller unable to, and operators have correctly configured tokens.
  # Without this branch the daemon would emit a false channel_health_miss
  # for a healthy isolated agent.
  if declare -F bridge_isolation_can_sudo_to_agent >/dev/null 2>&1; then
    sudo_rc=0
    bridge_isolation_can_sudo_to_agent "$agent" 2>/dev/null || sudo_rc=$?
    case "$sudo_rc" in
      0)
        # Agent isolated AND we can sudo to its UID — probe via that UID.
        # Self-contained inline script: tests readability and key presence
        # without sourcing bridge-lib.sh inside the isolated UID.
        # Exit codes from the inline script:
        #   0 — readable and at least one nonempty matching KEY=value line
        #   1 — readable but no matching nonempty key
        #   2 — not readable even to the isolated UID
        local probe_script
        probe_script='
file="$1"
shift
keys=("$@")
[[ -r "$file" ]] || exit 2
if [[ ${#keys[@]} -eq 0 ]]; then
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=[^[:space:]#]" "$file" && exit 0 || exit 1
fi
for k in "${keys[@]}"; do
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?${k}=[^[:space:]#].*" "$file" && exit 0
done
exit 1
'
        probe_rc=0
        bridge_isolation_run_as_agent_user_via_bash "$agent" "$probe_script" "$file" "$@" >/dev/null 2>&1 || probe_rc=$?
        # The helper preserves script's exit code shifted into the 3+ band
        # when nonzero (rc=0 stays 0; script-rc 1 -> 3; script-rc 2 -> 4).
        # See lib/bridge-isolation-helpers.sh docstring.
        case "$probe_rc" in
          0)
            : "${item}"
            printf 'present'
            return 0
            ;;
          3)
            : "${item}"
            printf 'missing'
            return 0
            ;;
          4)
            : "${item}"
            printf 'unreadable'
            return 0
            ;;
          *)
            # Probe itself failed unexpectedly (e.g. sudoers raced) —
            # fall through to the standard unreadable path.
            ;;
        esac
        ;;
      2)
        # Agent IS isolated but passwordless sudo is unavailable. Controller
        # cannot determine readiness either way — degrade to controller-blind
        # rather than firing a false miss. Caller maps this to status=unknown.
        : "${item}"
        printf 'controller-blind'
        return 0
        ;;
      *)
        # rc=1 — agent not in linux-user isolation. Fall through to the
        # standard unreadable path (true ACL drift on a controller-managed
        # file).
        ;;
    esac
  fi

  # v3: the sudo-as-agent probe handled the isolated case above.
  # Reaching here means the file is genuinely unreadable to both the
  # controller and the isolated UID probe, indicating ownership/mode or
  # sudo drift — not something fixable via group/ACL grants.

  # Suppress unused-warning shellcheck when item is reserved for future
  # per-channel scoped repair; ms365/teams currently share the agent-wide
  # repair surface so item is logged rather than dispatched on.
  : "${item}"
  printf 'unreadable'
  return 0
}

# Issue #534: produce a single-line diagnostic blob for an unreadable
# channel `.env` file. Composed from `stat` and `getfacl` (Linux only;
# Darwin lacks both POSIX named-user ACLs and a compatible getfacl).
# Suppresses all stderr — output is one line so it fits in the existing
# status_reason format.
#
# Output shape (single line):
#   {"mode":"600","owner":"<uid>:<gid>","getfacl":"...","repair_attempts":N}
#
# When the file is missing or running on macOS, emits a minimal blob with
# what is available; never returns non-zero.
bridge_channel_env_file_acl_diagnostic() {
  local file="$1"
  local repair_attempts="${2:-${BRIDGE_ENV_READINESS_REPAIR_ATTEMPTS:-2}}"
  local mode="-" owner="-" facl="-"

  if [[ -e "$file" ]]; then
    case "$(uname -s 2>/dev/null || printf '')" in
      Linux)
        mode="$(stat -c '%a' "$file" 2>/dev/null || printf -- '-')"
        owner="$(stat -c '%U:%G' "$file" 2>/dev/null || printf -- '-')"
        if command -v getfacl >/dev/null 2>&1; then
          facl="$(getfacl --omit-header --no-effective "$file" 2>/dev/null \
            | tr '\n' '/' | sed 's:/$::' || printf -- '-')"
          [[ -n "$facl" ]] || facl="-"
        fi
        ;;
      Darwin)
        mode="$(stat -f '%Lp' "$file" 2>/dev/null || printf -- '-')"
        owner="$(stat -f '%Su:%Sg' "$file" 2>/dev/null || printf -- '-')"
        facl="darwin-acl-not-applicable"
        ;;
      *)
        ;;
    esac
  fi

  printf '{"mode":"%s","owner":"%s","getfacl":"%s","repair_attempts":%s}' \
    "$mode" "$owner" "$facl" "$repair_attempts"
}

bridge_agent_channel_runtime_ready_for_item() {
  local agent="$1"
  local item="$2"
  local dir=""
  local port=""

  item="$(bridge_trim_whitespace "$item")"
  [[ -n "$item" ]] || return 1

  # Issue #534: route through the readiness enum so unreadable .env (linux-user
  # ACL drift) does not collapse into the same "not ready" signal as missing
  # keys. Both unreadable and missing return 1 here (downstream readiness is
  # boolean), but the structured reason path uses the same helper to emit a
  # distinct status_reason.
  #
  # Issue #779: for inbound listener channels (teams), also probe the TCP
  # LISTEN port so file-present-but-server-silent-exited does NOT report
  # runtime_ready=true, and so a stale state report does not survive a
  # rebind. discord/telegram are outbound bot connections — no LISTEN
  # socket — and ms365 shares the teams HTTP listener for the OAuth
  # callback, so neither gets a separate LISTEN probe here.
  case "$item" in
    plugin:discord|plugin:discord@*)
      dir="$(bridge_agent_discord_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" DISCORD_BOT_TOKEN BOT_TOKEN TOKEN)" == "present" ]]
      ;;
    plugin:telegram|plugin:telegram@*)
      dir="$(bridge_agent_telegram_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TELEGRAM_BOT_TOKEN BOT_TOKEN TOKEN)" == "present" ]]
      ;;
    plugin:teams|plugin:teams@*)
      dir="$(bridge_agent_teams_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TEAMS_APP_ID MicrosoftAppId)" == "present" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TEAMS_APP_PASSWORD MicrosoftAppPassword)" == "present" ]] || return 1
      # Issue #779: confirm the webhook listener is actually bound.
      # bridge_read_port_from_env_file returns 0 with empty stdout when
      # the key is missing — treat that as "no probe available, accept
      # file-check result" rather than a hard failure.
      port="$(bridge_read_port_from_env_file "$dir/.env" TEAMS_WEBHOOK_PORT 2>/dev/null || true)"
      if [[ -n "$port" ]] && declare -F bridge_port_is_listening >/dev/null 2>&1; then
        bridge_port_is_listening "$port" || return 1
      fi
      return 0
      ;;
    plugin:ms365|plugin:ms365@*)
      dir="$(bridge_agent_ms365_state_dir "$agent")"
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_CLIENT_ID)" == "present" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_CLIENT_SECRET)" == "present" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_TENANT_ID)" == "present" ]]
      ;;
    plugin:mattermost|plugin:mattermost@*)
      dir="$(bridge_agent_mattermost_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MATTERMOST_BOT_TOKEN MATTERMOST_PERSONAL_TOKEN)" == "present" ]]
      ;;
    *)
      return 0
      ;;
  esac
}

# bridge_port_is_listening — portable Linux + macOS TCP LISTEN probe.
# Issue #779. Used by bridge_agent_channel_runtime_ready_for_item (teams)
# and reusable for other channel readiness paths (e.g. Track E).
#
# Returns 0 if a process is bound and LISTEN-ing on the local TCP port,
# 1 if not, and fail-open (0) if neither `ss` nor `lsof` is available so
# we never make pre-existing file-check behavior strictly worse on a
# stripped-down host. Sub-100ms typical (well under the <500ms
# `agent-bridge show` latency budget).
bridge_port_is_listening() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1

  # Linux: ss is fast, batch-friendly, and ships with iproute2.
  if command -v ss >/dev/null 2>&1; then
    ss -tln "sport = :$port" 2>/dev/null | grep -q "LISTEN" && return 0
    return 1
  fi
  # macOS / BSD: lsof is the portable fallback.
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q "LISTEN" && return 0
    return 1
  fi
  # No probe tool available — fail-open so we preserve prior file-check
  # behavior on minimal hosts. Callers treat 0 as "ready"; this means
  # status reports remain accurate to within what we can actually test.
  return 0
}

bridge_channel_provider_for_item() {
  local item="$1"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:discord|plugin:discord@*)
      printf '%s' "discord"
      ;;
    plugin:telegram|plugin:telegram@*)
      printf '%s' "telegram"
      ;;
    plugin:teams|plugin:teams@*)
      printf '%s' "teams"
      ;;
    plugin:ms365|plugin:ms365@*)
      printf '%s' "ms365"
      ;;
    plugin:*)
      printf '%s' "${item#plugin:}"
      ;;
    server:*)
      printf '%s' "${item#server:}"
      ;;
    *)
      printf '%s' "unknown"
      ;;
  esac
}

bridge_channel_state_dir_for_item() {
  local agent="$1"
  local item="$2"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:discord|plugin:discord@*|server:discord)
      bridge_agent_discord_state_dir "$agent"
      ;;
    plugin:telegram|plugin:telegram@*|server:telegram)
      bridge_agent_telegram_state_dir "$agent"
      ;;
    plugin:teams|plugin:teams@*|server:teams)
      bridge_agent_teams_state_dir "$agent"
      ;;
    plugin:ms365|plugin:ms365@*|server:ms365)
      bridge_agent_ms365_state_dir "$agent"
      ;;
    plugin:mattermost|plugin:mattermost@*|server:mattermost)
      bridge_agent_mattermost_state_dir "$agent"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_channel_credentials_status_for_item() {
  local agent="$1"
  local item="$2"
  local dir=""
  local r1="" r2="" r3=""

  item="$(bridge_qualify_channel_item "$item")"
  dir="$(bridge_channel_state_dir_for_item "$agent" "$item")"
  # Issue #534: surface "unreadable" distinctly from "missing". When ANY
  # required key probe reports unreadable, the overall status is unreadable
  # (operators need to know the controller cannot read the file at all,
  # which is actionable via ACL repair, vs. truly missing keys).
  #
  # Issue #832: also propagate "controller-blind" — emitted by the readiness
  # function when the controller cannot read the file AND the agent is
  # linux-user isolated AND we cannot sudo to its UID to verify. unreadable
  # takes precedence (a real ACL drift somewhere is more actionable than
  # any single controller-blind path).
  case "$item" in
    plugin:discord|plugin:discord@*)
      r1="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" DISCORD_BOT_TOKEN BOT_TOKEN TOKEN)"
      printf '%s' "$r1"
      ;;
    plugin:telegram|plugin:telegram@*)
      r1="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TELEGRAM_BOT_TOKEN BOT_TOKEN TOKEN)"
      printf '%s' "$r1"
      ;;
    plugin:teams|plugin:teams@*)
      r1="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TEAMS_APP_ID MicrosoftAppId)"
      r2="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TEAMS_APP_PASSWORD MicrosoftAppPassword)"
      if [[ "$r1" == "unreadable" || "$r2" == "unreadable" ]]; then
        printf '%s' "unreadable"
      elif [[ "$r1" == "controller-blind" || "$r2" == "controller-blind" ]]; then
        printf '%s' "controller-blind"
      elif [[ "$r1" == "present" && "$r2" == "present" ]]; then
        printf '%s' "present"
      else
        printf '%s' "missing"
      fi
      ;;
    plugin:ms365|plugin:ms365@*)
      r1="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_CLIENT_ID)"
      r2="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_CLIENT_SECRET)"
      r3="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_TENANT_ID)"
      if [[ "$r1" == "unreadable" || "$r2" == "unreadable" || "$r3" == "unreadable" ]]; then
        printf '%s' "unreadable"
      elif [[ "$r1" == "controller-blind" || "$r2" == "controller-blind" || "$r3" == "controller-blind" ]]; then
        printf '%s' "controller-blind"
      elif [[ "$r1" == "present" && "$r2" == "present" && "$r3" == "present" ]]; then
        printf '%s' "present"
      else
        printf '%s' "missing"
      fi
      ;;
    *)
      printf '%s' "n/a"
      ;;
  esac
}

bridge_channel_access_status_for_item() {
  local agent="$1"
  local item="$2"
  local provider=""
  local dir=""
  local access_file=""

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:ms365|plugin:ms365@*)
      printf '%s' "n/a"
      return 0
      ;;
  esac
  provider="$(bridge_channel_provider_for_item "$item")"
  dir="$(bridge_channel_state_dir_for_item "$agent" "$item")"
  [[ -n "$dir" ]] || {
    printf '%s' "n/a"
    return 0
  }

  access_file="$dir/access.json"
  [[ -f "$access_file" ]] || {
    printf '%s' "missing"
    return 0
  }

  bridge_require_python
  python3 - "$access_file" "$provider" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider = sys.argv[2]

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("invalid")
    raise SystemExit(0)

def nonempty_list(value):
    if not isinstance(value, list):
        return 0
    return sum(1 for item in value if str(item).strip())

def nonempty_groups(value):
    if not isinstance(value, dict):
        return 0
    return sum(1 for key in value.keys() if str(key).strip())

count = 0
if provider == "discord":
    count += nonempty_groups(payload.get("groups"))
    count += nonempty_list(payload.get("allowFrom"))
elif provider == "telegram":
    count += nonempty_list(payload.get("allowFrom"))
    if str(payload.get("defaultChatId") or "").strip():
        count += 1
elif provider == "teams":
    count += nonempty_groups(payload.get("groups"))
    count += nonempty_list(payload.get("allowFrom"))
else:
    count += nonempty_groups(payload.get("groups"))
    count += nonempty_list(payload.get("allowFrom"))

print("present" if count > 0 else "empty")
PY
}

bridge_agent_channel_launch_allowlisted_for_item() {
  local agent="$1"
  local item="$2"
  local generated=""
  local effective=""
  local effective_dev=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || {
    printf '%s' "n/a"
    return 0
  }

  item="$(bridge_qualify_channel_item "$item")"
  # Mirror the real launch-builder path: bridge_agent_launch_cmd() applies
  # bridge_claude_launch_with_channels then bridge_claude_launch_with_development_channels
  # using bridge_agent_required_dev_channels_csv. Use the same arg here so the
  # diagnostic surface (launch_allowlisted) matches what `claude` actually receives.
  generated="$(bridge_claude_launch_with_channels "$agent" "$(bridge_agent_launch_cmd_raw "$agent")")"
  generated="$(bridge_claude_launch_with_development_channels "$generated" "$(bridge_agent_required_dev_channels_csv "$agent")")"
  effective="$(bridge_extract_channels_from_command "$generated")"
  effective_dev="$(bridge_extract_development_channels_from_command "$generated")"
  if bridge_channel_item_is_development "$item"; then
    if bridge_channel_csv_is_subset "$item" "$effective_dev"; then
      printf '%s' "yes"
      return 0
    fi
    printf '%s' "no"
    return 0
  fi

  if bridge_channel_csv_is_subset "$item" "$effective"; then
    printf '%s' "yes"
    return 0
  fi

  printf '%s' "no"
}

bridge_agent_channel_diagnostics_tsv() {
  local agent="$1"
  local required=""
  local item=""
  local provider=""
  local plugin_spec=""
  local plugin_status=""
  local plugin_installed=""
  local plugin_enabled=""
  local launch_allowlisted=""
  local access_status=""
  local credentials_status=""
  local runtime_ready=""
  local state_dir_status=""
  local -a items=()

  printf 'channel\tprovider\tplugin_spec\tplugin_status\tplugin_installed\tplugin_enabled\tlaunch_allowlisted\taccess_status\tcredentials_status\truntime_ready\tstate_dir\n'

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || return 0

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_qualify_channel_item "$item")"
    [[ -n "$item" ]] || continue

    provider="$(bridge_channel_provider_for_item "$item")"
    plugin_spec="-"
    plugin_status="n/a"
    plugin_installed="n/a"
    plugin_enabled="n/a"
    if [[ "$item" == plugin:* ]]; then
      plugin_spec="${item#plugin:}"
      # #852: thread the agent through so the status probe can trust the
      # isolation-aware short-circuit instead of false-failing on os.access
      # across the isolation boundary.
      plugin_status="$(bridge_claude_plugin_status "$plugin_spec" "$agent")"
      case "$plugin_status" in
        enabled)
          plugin_installed="yes"
          plugin_enabled="yes"
          ;;
        disabled)
          plugin_installed="yes"
          plugin_enabled="no"
          ;;
        *)
          plugin_installed="no"
          plugin_enabled="no"
          ;;
      esac
    fi

    launch_allowlisted="$(bridge_agent_channel_launch_allowlisted_for_item "$agent" "$item")"
    access_status="$(bridge_channel_access_status_for_item "$agent" "$item")"
    credentials_status="$(bridge_channel_credentials_status_for_item "$agent" "$item")"
    # Issue #832: when credentials probe is controller-blind the runtime
    # readiness is indeterminate, not yes/no. Render a distinct
    # `indeterminate` so `agent show` can tell the operator
    # "we cannot verify" apart from "we verified and it's missing".
    if [[ "$credentials_status" == "controller-blind" ]]; then
      runtime_ready="indeterminate"
    elif bridge_agent_channel_runtime_ready_for_item "$agent" "$item"; then
      runtime_ready="yes"
    else
      runtime_ready="no"
    fi
    state_dir_status="n/a"
    if [[ -n "$(bridge_channel_state_dir_for_item "$agent" "$item")" ]]; then
      if [[ -d "$(bridge_channel_state_dir_for_item "$agent" "$item")" ]]; then
        state_dir_status="present"
      else
        state_dir_status="missing"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$item" \
      "$provider" \
      "$plugin_spec" \
      "$plugin_status" \
      "$plugin_installed" \
      "$plugin_enabled" \
      "$launch_allowlisted" \
      "$access_status" \
      "$credentials_status" \
      "$runtime_ready" \
      "$state_dir_status"
  done
}

bridge_agent_channel_diagnostics_json() {
  local agent="$1"
  local tsv=""

  tsv="$(bridge_agent_channel_diagnostics_tsv "$agent")"
  bridge_require_python
  python3 - "$tsv" <<'PY'
import csv
import io
import json
import sys

rows = list(csv.DictReader(io.StringIO(sys.argv[1]), delimiter="\t"))

def yn(value):
    if value == "yes":
        return True
    if value == "no":
        return False
    return None

payload = []
for row in rows:
    payload.append({
        "channel": row["channel"],
        "provider": row["provider"],
        "plugin_spec": None if row["plugin_spec"] == "-" else row["plugin_spec"],
        "plugin_status": row["plugin_status"],
        "plugin_installed": yn(row["plugin_installed"]),
        "plugin_enabled": yn(row["plugin_enabled"]),
        "launch_allowlisted": yn(row["launch_allowlisted"]),
        "access_status": row["access_status"],
        "credentials_status": row["credentials_status"],
        "runtime_ready": yn(row["runtime_ready"]),
        "state_dir": row["state_dir"],
    })

print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
}

bridge_agent_channel_diagnostics_text() {
  local agent="$1"
  local tsv=""
  local row_count=0

  tsv="$(bridge_agent_channel_diagnostics_tsv "$agent")"
  # Issue #815 Wave A: stage multi-record TSV through a tempfile instead
  # of `done <<<` to avoid `heredoc_write` hangs on stale runtimes.
  local _tmp
  _tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f -- '$_tmp'" RETURN
  printf '%s\n' "$tsv" > "$_tmp"
  while IFS=$'\t' read -r channel provider plugin_spec plugin_status plugin_installed plugin_enabled launch_allowlisted access_status credentials_status runtime_ready state_dir; do
    [[ "$channel" == "channel" ]] && continue
    [[ -n "$channel" ]] || continue
    row_count=$((row_count + 1))
    printf -- '- channel: %s\n' "$channel"
    printf '  provider: %s\n' "$provider"
    printf '  plugin: installed=%s enabled=%s status=%s spec=%s\n' "$plugin_installed" "$plugin_enabled" "$plugin_status" "$plugin_spec"
    printf '  launch_allowlisted: %s\n' "$launch_allowlisted"
    printf '  runtime: state_dir=%s access=%s credentials=%s ready=%s\n' "$state_dir" "$access_status" "$credentials_status" "$runtime_ready"
  done < "$_tmp"

  if [[ "$row_count" == "0" ]]; then
    printf '%s\n' "- channels: (none)"
  fi
}

bridge_agent_broken_launch_file() {
  local agent="$1"
  printf '%s/agents/%s/broken-launch' "$BRIDGE_STATE_DIR" "$agent"
}

bridge_agent_session_health_json() {
  local agent="$1"
  local session=""
  local active="no"
  local loop_mode=""
  local continue_mode=""
  local onboarding_state=""
  local attached_exit_behavior="exit"
  local restart_readiness="not-looped"
  local broken_launch_file=""

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  onboarding_state="$(bridge_agent_onboarding_state "$agent")"
  broken_launch_file="$(bridge_agent_broken_launch_file "$agent")"

  if [[ -f "$broken_launch_file" ]]; then
    restart_readiness="broken-launch"
  elif [[ "$loop_mode" == "1" ]]; then
    if bridge_agent_should_stop_on_attached_clean_exit "$agent"; then
      attached_exit_behavior="stop-until-next-admin-command"
      restart_readiness="onboarding-pending"
    else
      attached_exit_behavior="detach-client-and-restart-loop"
      if bridge_agent_channel_setup_complete "$agent"; then
        restart_readiness="ready"
      else
        restart_readiness="channel-setup-incomplete"
      fi
    fi
  fi

  bridge_require_python
  python3 - "$agent" "$session" "$active" "$loop_mode" "$continue_mode" "$onboarding_state" "$attached_exit_behavior" "$restart_readiness" "$broken_launch_file" <<'PY'
import json
import sys

agent, session, active, loop_mode, continue_mode, onboarding_state, attached_exit_behavior, restart_readiness, broken_launch_file = sys.argv[1:]
payload = {
    "session": session or None,
    "tmux_active": active == "yes",
    "loop": loop_mode == "1",
    "continue": continue_mode == "1",
    "onboarding_state": onboarding_state,
    "attached_exit_behavior": attached_exit_behavior,
    "restart_readiness": restart_readiness,
    "detach_hint": "Ctrl-b then d",
    "stop_command": f"agent-bridge kill {agent}",
}
if broken_launch_file:
    payload["broken_launch_file"] = broken_launch_file
if session:
    payload["attach_command"] = f"tmux attach -t ={session}"
print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
}

bridge_agent_session_guidance_text() {
  local agent="$1"
  local session=""
  local active="no"
  local loop_mode=""
  local continue_mode=""
  local onboarding_state=""
  local exit_behavior=""
  local restart_readiness=""
  local broken_launch_file=""

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  onboarding_state="$(bridge_agent_onboarding_state "$agent")"
  broken_launch_file="$(bridge_agent_broken_launch_file "$agent")"
  exit_behavior="exit"
  restart_readiness="not-looped"
  if [[ -f "$broken_launch_file" ]]; then
    restart_readiness="broken-launch"
  elif [[ "$loop_mode" == "1" ]]; then
    if bridge_agent_should_stop_on_attached_clean_exit "$agent"; then
      exit_behavior="stop-until-next-admin-command"
      restart_readiness="onboarding-pending"
    else
      exit_behavior="detach-client-and-restart-loop"
      if bridge_agent_channel_setup_complete "$agent"; then
        restart_readiness="ready"
      else
        restart_readiness="channel-setup-incomplete"
      fi
    fi
  fi

  printf -- '- tmux_session: %s\n' "${session:--}"
  printf -- '- tmux_active: %s\n' "$active"
  printf -- '- loop: %s\n' "$loop_mode"
  printf -- '- continue: %s\n' "$continue_mode"
  printf -- '- onboarding_state: %s\n' "$onboarding_state"
  printf -- '- attached_exit_behavior: %s\n' "$exit_behavior"
  printf -- '- restart_readiness: %s\n' "$restart_readiness"
  if [[ -f "$broken_launch_file" ]]; then
    printf -- '- broken_launch_file: %s\n' "$broken_launch_file"
    printf -- '- recovery: agent-bridge agent safe-mode %s\n' "$agent"
  fi
  if [[ -n "$session" ]]; then
    printf -- '- attach: tmux attach -t =%s\n' "$session"
  fi
  printf -- '- detach_to_shell: Ctrl-b then d\n'
  printf -- '- fully_stop: agent-bridge kill %s\n' "$agent"
}

bridge_agent_ready_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local ready=""
  local -a items=()

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    # Issue #832: controller-blind channels are indeterminate, not ready.
    # Skip them here — they surface via
    # bridge_agent_controller_blind_channels_csv.
    if [[ "$(bridge_channel_credentials_status_for_item "$agent" "$item")" == "controller-blind" ]]; then
      continue
    fi
    if bridge_agent_channel_runtime_ready_for_item "$agent" "$item"; then
      ready="$(bridge_append_csv_unique "$ready" "$item")"
    fi
  done

  printf '%s' "$ready"
}

# Issue #832: enumerate channels whose credentials probe returned
# `controller-blind` — the controller cannot determine readiness because
# the dotenv is unreadable AND we cannot sudo to the agent's UID to verify.
# These channels MUST NOT appear in missing_channels_csv (no false miss)
# and MUST NOT appear in ready_channels_csv (we have not verified them).
# `bridge_agent_launch_channels_csv` re-includes them under
# `BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1` so dev-mode launches do not
# drop the channel just because the controller could not introspect it.
bridge_agent_controller_blind_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local blind=""
  local -a items=()

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if [[ "$(bridge_channel_credentials_status_for_item "$agent" "$item")" == "controller-blind" ]]; then
      blind="$(bridge_append_csv_unique "$blind" "$item")"
    fi
  done

  printf '%s' "$blind"
}

bridge_agent_missing_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local missing=""
  local -a items=()

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    # Issue #832: controller-blind channels are indeterminate, not missing.
    # Excluding them here is what makes the suppress-missing-channels
    # launch path keep them in the launch flags instead of dropping them.
    if [[ "$(bridge_channel_credentials_status_for_item "$agent" "$item")" == "controller-blind" ]]; then
      continue
    fi
    if ! bridge_agent_channel_runtime_ready_for_item "$agent" "$item"; then
      missing="$(bridge_append_csv_unique "$missing" "$item")"
    fi
  done

  printf '%s' "$missing"
}

bridge_agent_channel_runtime_drift_reason() {
  local agent="$1"
  local required=""
  local missing=""
  local ready=""

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  missing="$(bridge_agent_missing_channels_csv "$agent")"
  [[ -n "$missing" ]] || {
    printf '%s' ""
    return 0
  }

  ready="$(bridge_agent_ready_channels_csv "$agent")"
  printf 'declared channels (%s) do not match configured runtime (ready=%s missing=%s)' \
    "$required" \
    "${ready:--}" \
    "$missing"
}

bridge_agent_launch_channels_csv() {
  local agent="$1"
  local channels=""
  local source_channels=""

  if [[ "${BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS:-0}" == "1" ]]; then
    # Issue #832: under suppress-missing-channels, fold controller-blind
    # channels back in alongside ready ones. We cannot verify their
    # credentials from the controller, but we also cannot prove they are
    # broken — dropping them would silently strip a working channel from
    # an isolated agent's launch flags.
    source_channels="$(bridge_merge_channels_csv "$(bridge_agent_ready_channels_csv "$agent")" "$(bridge_agent_controller_blind_channels_csv "$agent")")"
    channels="$(bridge_filter_approved_channels_csv "$source_channels")"
  else
    source_channels="$(bridge_agent_channels_csv "$agent")"
    channels="$(bridge_filter_approved_channels_csv "$source_channels")"
  fi
  bridge_filter_claude_plugin_channels_csv "$channels"
}

bridge_agent_effective_dev_channels_csv() {
  local agent="$1"
  local channels=""

  if [[ "${BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS:-0}" == "1" ]]; then
    # Issue #832: same controller-blind merge as launch_channels_csv —
    # keep the dev channel set inclusive of indeterminate channels under
    # suppression so the merged plugin set still loads.
    channels="$(bridge_merge_channels_csv "$(bridge_agent_ready_channels_csv "$agent")" "$(bridge_agent_controller_blind_channels_csv "$agent")")"
    bridge_filter_development_channels_csv "$channels"
    return 0
  fi

  bridge_agent_dev_channels_csv "$agent"
}

bridge_agent_effective_launch_plugin_channels_csv() {
  local agent="$1"
  local merged=""

  merged="$(bridge_merge_channels_csv "$(bridge_agent_launch_channels_csv "$agent")" "$(bridge_agent_effective_dev_channels_csv "$agent")")"
  bridge_filter_claude_plugin_channels_csv "$merged"
}

bridge_plugin_mcp_identity_for_item() {
  local item="$1"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:discord|plugin:discord@*)
      printf '%s' "discord"
      ;;
    plugin:telegram|plugin:telegram@*)
      printf '%s' "telegram"
      ;;
    plugin:teams|plugin:teams@*)
      printf '%s' "teams"
      ;;
    plugin:mattermost|plugin:mattermost@*)
      printf '%s' "mattermost"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

# Returns 0 if the channel item has a probeable plugin MCP identity
# (currently the 4 chat providers we ship a `ps`-descendant probe for).
# Returns 1 for plugins we ship without a probe (HTTP MCPs, marketplace
# plugins, ms365 / generic command-MCPs, etc.) — these are reported as
# unknown/skipped rather than missing so they cannot drive restart loops.
# See issue #542; per-plugin-class probes (command-MCP, HTTP MCP) are
# tracked as follow-ups and will extend this classifier.
bridge_plugin_mcp_is_probeable_item() {
  local item="$1"
  local identity=""

  identity="$(bridge_plugin_mcp_identity_for_item "$item")"
  [[ -n "$identity" ]]
}

# NOTE: an empty identity from bridge_plugin_mcp_identity_for_item means
# the plugin is *unprobeable* (we have no descendant probe for it), not
# that it is missing. Callers should gate on bridge_plugin_mcp_is_probeable_item
# *before* invoking this probe so unprobeable plugins do not get flagged
# as missing and trigger restart loops (issue #542).
bridge_plugin_mcp_descendant_ready_for_item() {
  local root_pid="$1"
  local item="$2"
  local identity=""

  [[ "$root_pid" =~ ^[0-9]+$ ]] || return 1
  identity="$(bridge_plugin_mcp_identity_for_item "$item")"
  [[ -n "$identity" ]] || return 1

  bridge_require_python
  python3 - "$root_pid" "$identity" <<'PY'
import re
import subprocess
import sys
from collections import defaultdict

root_pid = int(sys.argv[1])
identity = sys.argv[2].strip().lower()

try:
    completed = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,command="],
        check=True,
        text=True,
        capture_output=True,
    )
except subprocess.CalledProcessError:
    raise SystemExit(1)

procs = {}
children = defaultdict(list)
for raw in completed.stdout.splitlines():
    parts = raw.strip().split(None, 2)
    if len(parts) < 3:
        continue
    try:
        pid = int(parts[0])
        ppid = int(parts[1])
    except ValueError:
        continue
    command = parts[2]
    procs[pid] = (ppid, command)
    children[ppid].append(pid)

descendants = set()
stack = list(children.get(root_pid, []))
while stack:
    pid = stack.pop()
    if pid in descendants:
        continue
    descendants.add(pid)
    stack.extend(children.get(pid, []))

def command_has_identity_path_segment(command: str, identity: str) -> bool:
    for match in re.finditer(r"/[^\s]+", command):
        token = match.group(0)
        segments = [segment for segment in token.split("/") if segment]
        if identity in segments:
            return True
    return False

for pid in descendants:
    _ppid, command = procs.get(pid, (None, ""))
    lowered = command.lower()
    if "bun" not in lowered:
        continue
    if command_has_identity_path_segment(lowered, identity):
        raise SystemExit(0)

raise SystemExit(1)
PY
}

bridge_agent_plugin_mcp_alive_for_item() {
  local agent="$1"
  local item="$2"
  local session=""
  local pane_pid=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1
  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || return 1
  bridge_tmux_session_exists "$session" || return 1
  pane_pid="$(bridge_tmux_session_pane_pid "$session")"
  [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
  bridge_plugin_mcp_descendant_ready_for_item "$pane_pid" "$item"
}

bridge_agent_missing_plugin_mcp_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local missing=""
  local -a items=()

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  required="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
  [[ -n "$required" ]] || return 0

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    # Skip plugins we cannot probe (HTTP MCPs, marketplace plugins, ms365,
    # etc.). They are reported as unknown/skipped — not missing — so they
    # cannot drive restart loops. See issue #542.
    bridge_plugin_mcp_is_probeable_item "$item" || continue
    if ! bridge_agent_plugin_mcp_alive_for_item "$agent" "$item"; then
      missing="$(bridge_merge_channels_csv "$missing" "$item")"
    fi
  done

  printf '%s' "$missing"
}

bridge_agent_required_launch_channels_csv() {
  local agent="$1"

  bridge_agent_launch_channels_csv "$agent"
}

bridge_agent_required_dev_channels_csv() {
  local agent="$1"
  local dev_channels=""
  local server_channels=""

  dev_channels="$(bridge_agent_dev_channels_csv "$agent")"
  server_channels="$(bridge_filter_server_channels_csv "$(bridge_agent_launch_channels_csv "$agent")")"
  bridge_filter_claude_plugin_channels_csv "$(bridge_merge_channels_csv "$dev_channels" "$server_channels")"
}

bridge_agent_required_runtime_channels_csv() {
  local agent="$1"

  bridge_agent_channels_csv "$agent"
}

bridge_claude_channel_banner_present_from_text() {
  local channels="$1"
  local recent="$2"
  local item=""
  local found=0
  local -a items=()

  channels="$(bridge_filter_claude_plugin_channels_csv "$channels")"
  [[ -n "$channels" ]] || return 0
  [[ "$recent" == *"Listening for channel messages from:"* ]] || return 1

  IFS=',' read -r -a items <<<"$channels"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    [[ "$recent" == *"$item"* ]] || return 1
    found=1
  done

  [[ "$found" == "1" ]]
}

bridge_tmux_session_has_claude_channel_banner() {
  local session="$1"
  local channels="$2"
  local recent=""

  channels="$(bridge_filter_claude_plugin_channels_csv "$channels")"
  [[ -n "$channels" ]] || return 0
  recent="$(bridge_capture_recent "$session" 80 2>/dev/null || true)"
  [[ -n "$recent" ]] || return 1
  bridge_claude_channel_banner_present_from_text "$channels" "$recent"
}

bridge_tmux_wait_for_claude_channel_banner() {
  local session="$1"
  local channels="$2"
  local timeout="${3:-12}"
  local start_ts=0
  local elapsed=0

  channels="$(bridge_filter_claude_plugin_channels_csv "$channels")"
  [[ -n "$channels" ]] || return 0
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=12
  (( timeout > 0 )) || timeout=12

  if bridge_tmux_session_has_claude_channel_banner "$session" "$channels"; then
    return 0
  fi

  start_ts="$(date +%s)"
  while true; do
    if bridge_tmux_session_has_claude_channel_banner "$session" "$channels"; then
      return 0
    fi
    sleep 0.2
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

# bridge_tmux_wait_for_claude_plugin_mcp_alive — descendant-based readiness
# verifier for required Claude plugin MCP channels. Issue #143.
#
# The banner-based verifier (bridge_tmux_wait_for_claude_channel_banner)
# scans the last 80 tmux lines for a startup-only banner; busy sessions
# scroll the banner off-window in seconds, so restart verify keeps
# failing even when every plugin bun process is healthy. The daemon's
# steady-state liveness already uses a descendant process probe
# (bridge_agent_missing_plugin_mcp_channels_csv → *_alive_for_item →
# bridge_plugin_mcp_descendant_ready_for_item); route restart verify
# through the same signal for consistency.
#
# Polls until every required plugin MCP is alive under the pane PID or
# timeout elapses. Returns 0 when no channels are required, when
# liveness is already clean, or when the loop observes it cleanly.
# Returns 1 if timeout expires with at least one channel still missing.
bridge_tmux_wait_for_claude_plugin_mcp_alive() {
  local agent="$1"
  local timeout="${2:-12}"
  local required=""
  local missing=""
  local start_ts=0
  local elapsed=0

  [[ -n "$agent" ]] || return 0
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  required="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
  [[ -n "$required" ]] || return 0
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=12
  (( timeout > 0 )) || timeout=12

  missing="$(bridge_agent_missing_plugin_mcp_channels_csv "$agent")"
  [[ -z "$missing" ]] && return 0

  start_ts="$(date +%s)"
  while true; do
    sleep 0.5
    missing="$(bridge_agent_missing_plugin_mcp_channels_csv "$agent")"
    [[ -z "$missing" ]] && return 0
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

bridge_agent_launch_channel_status_reason() {
  local agent="$1"
  local required=""
  local required_dev=""
  local effective=""
  local effective_dev=""
  local generated=""

  required="$(bridge_agent_required_launch_channels_csv "$agent")"
  required_dev="$(bridge_agent_required_dev_channels_csv "$agent")"
  generated="$(bridge_claude_launch_with_channels "$agent" "$(bridge_agent_launch_cmd_raw "$agent")")"
  generated="$(bridge_claude_launch_with_development_channels "$generated" "$required_dev")"
  effective_dev="$(bridge_extract_development_channels_from_command "$generated")"
  [[ -n "$required" ]] || {
    if [[ -z "$required_dev" ]]; then
      printf '%s' ""
      return 0
    fi
  }

  effective="$(bridge_extract_channels_from_command "$generated")"
  if [[ -n "$required" ]] && ! bridge_channel_csv_is_subset "$required" "$effective"; then
    printf 'launch command missing required Claude --channels (%s)' "$required"
    return 0
  fi
  if [[ -n "$required_dev" ]] && ! bridge_channel_csv_is_subset "$required_dev" "$effective_dev"; then
    printf 'launch command missing required development channels (%s)' "$required_dev"
    return 0
  fi

  printf '%s' ""
}

bridge_agent_runtime_channel_status_reason() {
  local agent="$1"
  local required=""
  local discord_dir=""
  local telegram_dir=""
  local teams_dir=""
  local readiness=""
  local repair_attempts="${BRIDGE_ENV_READINESS_REPAIR_ATTEMPTS:-2}"

  required="$(bridge_agent_required_runtime_channels_csv "$agent")"
  if [[ -z "$required" ]]; then
    printf '%s' ""
    return 0
  fi

  if bridge_channel_csv_contains "$required" "plugin:discord"; then
    discord_dir="$(bridge_agent_discord_state_dir "$agent")"
    if [[ ! -f "$discord_dir/access.json" ]]; then
      printf 'missing Discord access file under %s (access.json required)' "$discord_dir"
      return 0
    fi
    # Issue #534: route through readiness enum so unreadable .env emits a
    # distinct, actionable status_reason instead of the false-negative
    # "missing token" message.
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:discord" "$discord_dir/.env" DISCORD_BOT_TOKEN BOT_TOKEN TOKEN)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Discord .env under %s (ACL repair failed %s times; %s)' \
        "$discord_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$discord_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" == "controller-blind" ]]; then
      printf 'controller-blind:plugin:discord:%s/.env:no-passwordless-sudo (set BRIDGE_AGENT_SUDOERS; run: agent-bridge migrate isolation v3 --check) %s' \
        "$discord_dir" "$(bridge_channel_env_file_acl_diagnostic "$discord_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Discord bot token under %s (.env with DISCORD_BOT_TOKEN required)' "$discord_dir"
      return 0
    fi
  fi

  if bridge_channel_csv_contains "$required" "plugin:telegram"; then
    telegram_dir="$(bridge_agent_telegram_state_dir "$agent")"
    if [[ ! -f "$telegram_dir/access.json" ]]; then
      printf 'missing Telegram access file under %s (access.json required)' "$telegram_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:telegram" "$telegram_dir/.env" TELEGRAM_BOT_TOKEN BOT_TOKEN TOKEN)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Telegram .env under %s (ACL repair failed %s times; %s)' \
        "$telegram_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$telegram_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" == "controller-blind" ]]; then
      printf 'controller-blind:plugin:telegram:%s/.env:no-passwordless-sudo (set BRIDGE_AGENT_SUDOERS; run: agent-bridge migrate isolation v3 --check) %s' \
        "$telegram_dir" "$(bridge_channel_env_file_acl_diagnostic "$telegram_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Telegram bot token under %s (.env with TELEGRAM_BOT_TOKEN required)' "$telegram_dir"
      return 0
    fi
  fi

  if bridge_channel_csv_contains "$required" "plugin:teams"; then
    teams_dir="$(bridge_agent_teams_state_dir "$agent")"
    if [[ ! -f "$teams_dir/access.json" ]]; then
      printf 'missing Teams access file under %s (access.json required)' "$teams_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:teams" "$teams_dir/.env" TEAMS_APP_ID MicrosoftAppId)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Teams .env under %s (ACL repair failed %s times; %s)' \
        "$teams_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$teams_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" == "controller-blind" ]]; then
      printf 'controller-blind:plugin:teams:%s/.env:no-passwordless-sudo (set BRIDGE_AGENT_SUDOERS; run: agent-bridge migrate isolation v3 --check) %s' \
        "$teams_dir" "$(bridge_channel_env_file_acl_diagnostic "$teams_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Teams app id under %s (.env with TEAMS_APP_ID required)' "$teams_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:teams" "$teams_dir/.env" TEAMS_APP_PASSWORD MicrosoftAppPassword)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Teams .env under %s (ACL repair failed %s times; %s)' \
        "$teams_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$teams_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" == "controller-blind" ]]; then
      printf 'controller-blind:plugin:teams:%s/.env:no-passwordless-sudo (set BRIDGE_AGENT_SUDOERS; run: agent-bridge migrate isolation v3 --check) %s' \
        "$teams_dir" "$(bridge_channel_env_file_acl_diagnostic "$teams_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Teams app password under %s (.env with TEAMS_APP_PASSWORD required)' "$teams_dir"
      return 0
    fi
  fi

  # Issue #534: ms365 branch added here. Previously absent — meant ACL
  # diagnostics for ms365 channels could never surface even with the
  # readiness enum in place.
  if bridge_channel_csv_contains "$required" "plugin:ms365"; then
    local ms365_dir=""
    ms365_dir="$(bridge_agent_ms365_state_dir "$agent")"
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:ms365" "$ms365_dir/.env" MS365_CLIENT_ID)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: MS365 .env under %s (ACL repair failed %s times; %s)' \
        "$ms365_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$ms365_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" == "controller-blind" ]]; then
      printf 'controller-blind:plugin:ms365:%s/.env:no-passwordless-sudo (set BRIDGE_AGENT_SUDOERS; run: agent-bridge migrate isolation v3 --check) %s' \
        "$ms365_dir" "$(bridge_channel_env_file_acl_diagnostic "$ms365_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing MS365 client id under %s (.env with MS365_CLIENT_ID required)' "$ms365_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:ms365" "$ms365_dir/.env" MS365_CLIENT_SECRET)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: MS365 .env under %s (ACL repair failed %s times; %s)' \
        "$ms365_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$ms365_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" == "controller-blind" ]]; then
      printf 'controller-blind:plugin:ms365:%s/.env:no-passwordless-sudo (set BRIDGE_AGENT_SUDOERS; run: agent-bridge migrate isolation v3 --check) %s' \
        "$ms365_dir" "$(bridge_channel_env_file_acl_diagnostic "$ms365_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing MS365 client secret under %s (.env with MS365_CLIENT_SECRET required)' "$ms365_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:ms365" "$ms365_dir/.env" MS365_TENANT_ID)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: MS365 .env under %s (ACL repair failed %s times; %s)' \
        "$ms365_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$ms365_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" == "controller-blind" ]]; then
      printf 'controller-blind:plugin:ms365:%s/.env:no-passwordless-sudo (set BRIDGE_AGENT_SUDOERS; run: agent-bridge migrate isolation v3 --check) %s' \
        "$ms365_dir" "$(bridge_channel_env_file_acl_diagnostic "$ms365_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing MS365 tenant id under %s (.env with MS365_TENANT_ID required)' "$ms365_dir"
      return 0
    fi
  fi

  if bridge_channel_csv_contains "$required" "plugin:mattermost"; then
    local mattermost_dir=""
    mattermost_dir="$(bridge_agent_mattermost_state_dir "$agent")"
    if [[ ! -f "$mattermost_dir/access.json" ]]; then
      printf 'missing Mattermost access file under %s (access.json required)' "$mattermost_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:mattermost" "$mattermost_dir/.env" MATTERMOST_BOT_TOKEN MATTERMOST_PERSONAL_TOKEN)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Mattermost .env under %s (ACL repair failed %s times; %s)' \
        "$mattermost_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$mattermost_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" == "controller-blind" ]]; then
      printf 'controller-blind:plugin:mattermost:%s/.env:no-passwordless-sudo (set BRIDGE_AGENT_SUDOERS; run: agent-bridge migrate isolation v3 --check) %s' \
        "$mattermost_dir" "$(bridge_channel_env_file_acl_diagnostic "$mattermost_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Mattermost bot token under %s (.env with MATTERMOST_BOT_TOKEN required)' "$mattermost_dir"
      return 0
    fi
  fi

  printf '%s' ""
}

bridge_agent_channel_setup_guidance() {
  local agent="$1"
  local reason="${2:-$(bridge_agent_channel_status_reason "$agent")}"
  local required=""
  local cli="$BRIDGE_HOME/agent-bridge"
  local roster_local="$BRIDGE_HOME/agent-roster.local.sh"

  required="$(bridge_agent_channels_csv "$agent")"
  printf "Channel runtime is not configured for '%s': %s" "$agent" "$reason"
  if bridge_channel_csv_contains "$required" "plugin:discord"; then
    printf "\nRun: %s setup discord %s --token <DISCORD_BOT_TOKEN> --channel <DISCORD_CHANNEL_ID>" "$cli" "$agent"
  fi
  if bridge_channel_csv_contains "$required" "plugin:telegram"; then
    printf "\nRun: %s setup telegram %s --token <TELEGRAM_BOT_TOKEN> --allow-from <TELEGRAM_USER_ID> --default-chat <TELEGRAM_CHAT_ID>" "$cli" "$agent"
  fi
  if bridge_channel_csv_contains "$required" "plugin:teams"; then
    printf "\nRun: BRIDGE_TEAMS_APP_PASSWORD=<TEAMS_APP_PASSWORD> %s setup teams %s --app-id <TEAMS_APP_ID> --allow-from <TEAMS_USER_ID>" "$cli" "$agent"
  fi
  if bridge_channel_csv_contains "$required" "plugin:mattermost"; then
    printf "\nRun: %s setup mattermost %s --url <MATTERMOST_URL> --bot-token <BOT_TOKEN> --allow-from <USER_ID>" "$cli" "$agent"
  fi
  printf "\nIf this agent intentionally runs with fewer channels, update %s so BRIDGE_AGENT_CHANNELS[\"%s\"] matches the live runtime before restarting." "$roster_local" "$agent"
}

bridge_agent_channel_status_reason() {
  local agent="$1"
  local reason=""

  reason="$(bridge_agent_launch_channel_status_reason "$agent")"
  if [[ -n "$reason" ]]; then
    printf '%s' "$reason"
    return 0
  fi

  reason="$(bridge_agent_runtime_channel_status_reason "$agent")"
  if [[ -n "$reason" ]]; then
    printf '%s' "$reason"
    return 0
  fi

  printf '%s' ""
}

bridge_agent_restart_preflight_reason() {
  local agent="$1"
  local session=""
  local reason=""
  local drift=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || {
    printf '%s' ""
    return 0
  }

  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || {
    printf '%s' ""
    return 0
  }
  bridge_tmux_session_exists "$session" || {
    printf '%s' ""
    return 0
  }

  reason="$(bridge_agent_channel_status_reason "$agent")"
  [[ -n "$reason" ]] || {
    printf '%s' ""
    return 0
  }

  drift="$(bridge_agent_channel_runtime_drift_reason "$agent")"
  if [[ -n "$drift" ]]; then
    printf '%s' "$drift"
    return 0
  fi

  printf '%s' "$reason"
}

bridge_agent_restart_preflight_guidance() {
  local agent="$1"
  local reason="${2:-$(bridge_agent_restart_preflight_reason "$agent")}"

  [[ -n "$reason" ]] || {
    printf '%s' ""
    return 0
  }

  printf "Restart is blocked for '%s': %s" "$agent" "$reason"
  printf "\nThe running session was left intact to avoid downtime."
  printf "\n%s" "$(bridge_agent_channel_setup_guidance "$agent" "$reason")"
}

bridge_agent_channel_status() {
  local agent="$1"
  local required=""
  local reason=""

  required="$(bridge_agent_channels_csv "$agent")"
  if [[ -z "$required" ]]; then
    printf '%s' "-"
    return 0
  fi

  reason="$(bridge_agent_channel_status_reason "$agent")"
  if [[ -n "$reason" ]]; then
    # Issue #832: a controller-blind dotenv is an indeterminate state, not
    # a confirmed mismatch. Degrade to `unknown` so the daemon does not
    # fire a false channel_health_miss audit row and so operators can
    # tell "we cannot verify" apart from "we verified and it's broken".
    case "$reason" in
      controller-blind:*)
        printf '%s' "unknown"
        return 0
        ;;
    esac
    printf '%s' "miss"
    return 0
  fi

  printf '%s' "ok"
}

bridge_claude_plugin_status() {
  local plugin_spec="$1"
  # #852 controller-blind plugin trust: optional agent id lets isolation-
  # aware callers gate the controller-side filesystem probe. Existing
  # single-arg callers (and the BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE test
  # path) keep their previous behavior — only the isolation-trust early
  # return below changes when this arg is non-empty.
  local agent="${2-}"
  local registry="${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}"
  local default_manifest=""
  local manifest_owner=""
  local manifest_has_spec=""
  local output=""

  if [[ -n "$registry" && -f "$registry" ]]; then
    bridge_require_python
    python3 - "$registry" "$plugin_spec" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
spec = sys.argv[2]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("missing")
    raise SystemExit(0)

plugins = payload.get("plugins") or {}
print("enabled" if spec in plugins else "missing")
PY
    return 0
  fi

  # #852 controller-blind plugin trust: when an isolated agent declares
  # a third-party marketplace plugin, the controller's HOME's
  # installed_plugins.json holds the spec but the entry's installPath
  # points into the isolated UID's mode-700 home. The os.access probe
  # below runs as the controller UID, fails to traverse the isolated
  # home, and false-reports "missing" — triggering a redundant
  # `claude plugin install` that fails on the controller's own
  # marketplace drift (#853). Skip the filesystem probe entirely when
  # the agent is linux-user-isolated: the manifest's key set is the
  # source of truth (written by bridge_write_isolated_installed_plugins_
  # manifest at isolation-prepare time). The legacy single-arg callers
  # (no agent in scope) and the existing root-owned isolated-side
  # short-circuit below remain in effect.
  default_manifest="${HOME:-}/.claude/plugins/installed_plugins.json"
  if [[ -n "$agent" && -n "${HOME:-}" && -f "$default_manifest" ]]; then
    if bridge_agent_linux_user_isolation_requested "$agent"; then
      bridge_require_python
      manifest_has_spec="$(python3 \
        "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/claude-plugin-manifest-has-spec.py" \
        "$default_manifest" "$plugin_spec" 2>/dev/null || printf 'absent')"
      if [[ "$manifest_has_spec" == "present" ]]; then
        printf '%s' "enabled"
        return 0
      fi
    fi
  fi

  # #346 isolate: when bridge-run.sh executes under an isolated linux-user
  # UID and the per-UID installed_plugins.json is root-owned, that file
  # was written by bridge_write_isolated_installed_plugins_manifest as the
  # authoritative declared-plugin-only catalog. Trusting it here lets a
  # third-party marketplace plugin (whose marketplace metadata is not
  # exposed inside the isolated home) pass preflight without an install
  # attempt that would otherwise crash bridge-run.sh and trigger a tmux
  # respawn loop. Controller (non-root) UIDs do not match the
  # owner==root guard, so the existing claude-plugin-list fallback
  # remains in effect for the controller side.
  if [[ -n "${HOME:-}" && "$(id -u 2>/dev/null || echo 0)" != "0" && -f "$default_manifest" ]]; then
    manifest_owner="$(stat -c '%u' "$default_manifest" 2>/dev/null || echo -1)"
    if [[ "$manifest_owner" == "0" ]]; then
      bridge_require_python
      python3 - "$default_manifest" "$plugin_spec" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
spec = sys.argv[2]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("missing")
    raise SystemExit(0)

entries = (payload.get("plugins") or {}).get(spec) or []
for entry in entries:
    install_path = entry.get("installPath", "")
    if install_path and os.access(install_path, os.R_OK | os.X_OK):
        print("enabled")
        raise SystemExit(0)
print("missing")
PY
      return 0
    fi
  fi

  if ! command -v claude >/dev/null 2>&1; then
    printf '%s' "missing"
    return 0
  fi

  output="$(claude plugin list 2>/dev/null || true)"
  bridge_require_python
  BRIDGE_PLUGIN_LIST_OUTPUT="$output" python3 - "$plugin_spec" <<'PY'
import os
import sys

spec = sys.argv[1]
lines = os.environ.get("BRIDGE_PLUGIN_LIST_OUTPUT", "").splitlines()
current = False

for raw in lines:
    line = raw.strip()
    if spec in line:
        current = True
        continue
    if current and line.startswith("Status:"):
        if "enabled" in line:
            print("enabled")
        elif "disabled" in line:
            print("disabled")
        else:
            print("missing")
        raise SystemExit(0)
    if current and line.startswith("❯ "):
        break

print("missing")
PY
}

bridge_claude_plugin_marketplace() {
  local plugin_spec="$1"

  if [[ "$plugin_spec" == *@* ]]; then
    printf '%s' "${plugin_spec#*@}"
  else
    printf '%s' ""
  fi
}

bridge_claude_marketplace_source() {
  local marketplace="$1"

  case "$marketplace" in
    claude-plugins-official)
      printf '%s' "anthropics/claude-plugins-official"
      ;;
    agent-bridge)
      printf '%s' "$BRIDGE_SCRIPT_DIR"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_claude_plugin_install_missing_from_marketplace() {
  local output="$1"

  [[ "$output" == *"not found in marketplace"* || "$output" == *"not found"* ]]
}

bridge_force_refresh_claude_marketplace() {
  local marketplace="$1"
  local source=""

  [[ -n "$marketplace" ]] || return 1
  source="$(bridge_claude_marketplace_source "$marketplace")"
  [[ -n "$source" ]] || return 1

  bridge_info "[info] Refreshing Claude plugin marketplace: $marketplace"
  claude plugin marketplace remove "$marketplace" >/dev/null 2>&1 || true
  claude plugin marketplace add "$source" >/dev/null
}

# #853 controller-side marketplace silent-drift self-heal. Before
# `claude plugin install <plugin>@<marketplace>` runs for an isolated
# agent, verify the controller's live `claude plugin marketplace list`
# still enumerates the marketplace. If it does not but the controller's
# known_marketplaces.json declares a github source for it, run
# `claude plugin marketplace add <repo>` inline so the subsequent
# install resolves the spec instead of failing with `Plugin "<name>"
# not found in marketplace "<mkt>"`.
#
# Returns 0 when the marketplace is present (already, or after a
# successful re-add). Returns non-zero when the self-heal could not
# proceed (no claude binary, marketplace not in known_marketplaces.json,
# no github repo to add from, or the add command failed). Callers
# treat non-zero as "degrade to the existing legacy install attempt and
# warn loudly" — never `bridge_die` here, the install path retains its
# own error handling.
#
# Gated on `bridge_agent_linux_user_isolation_requested` because non-
# isolated installs already work without this step: the controller is
# both the marketplace enumerator and the install consumer, so the
# `claude plugin install` retry-after-refresh path that already exists
# in bridge_ensure_claude_plugin_enabled is sufficient. The gap this
# helper closes is the isolated-agent case where the controller does
# the install but its marketplace state has silently drifted away from
# the row it once added.
bridge_claude_marketplace_ensure_present_for_isolated() {
  local marketplace="$1"
  local agent="${2-}"
  local catalog=""
  local repo=""
  local list_output=""

  [[ -n "$marketplace" ]] || return 1
  [[ -n "$agent" ]] || return 1
  bridge_agent_linux_user_isolation_requested "$agent" || return 1
  command -v claude >/dev/null 2>&1 || return 1

  list_output="$(claude plugin marketplace list 2>/dev/null || true)"
  # `claude plugin marketplace list` formats each row as a header line
  # followed by a `Source:` / `Path:` block. Use a word-boundary grep so
  # a substring match (e.g. "foo-bar" matching "foo-bar-baz") cannot
  # false-positive — the marketplace id is ASCII-safe per upstream
  # validation rules.
  if printf '%s\n' "$list_output" | grep -Eq "(^|[[:space:]])${marketplace}([[:space:]]|\$)"; then
    return 0
  fi

  catalog="${HOME:-}/.claude/plugins/known_marketplaces.json"
  [[ -f "$catalog" ]] || return 1

  bridge_require_python
  repo="$(python3 \
    "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/claude-known-marketplaces-extract-repo.py" \
    "$catalog" "$marketplace" 2>/dev/null || printf '')"
  [[ -n "$repo" ]] || return 1

  bridge_info "[info] Re-adding drifted Claude plugin marketplace: $marketplace ($repo)"
  if ! claude plugin marketplace add "$repo" >/dev/null 2>&1; then
    bridge_warn "Failed to re-add Claude plugin marketplace '$marketplace' (repo=$repo); install will proceed and may fail loudly."
    return 1
  fi
  return 0
}

bridge_ensure_claude_plugin_enabled() {
  local plugin_spec="$1"
  # #852: optional agent id lets the controller-side status probe trust
  # the isolated UID's per-agent installed_plugins.json instead of
  # crossing the isolation boundary with os.access. Existing
  # single-arg callers continue to work.
  local agent="${2-}"
  local status=""
  local output=""
  local marketplace=""

  status="$(bridge_claude_plugin_status "$plugin_spec" "$agent")"
  case "$status" in
    enabled)
      bridge_info "[info] Claude plugin ready: $plugin_spec"
      return 0
      ;;
    disabled)
      if [[ -n "${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}" ]]; then
        bridge_die "Claude plugin registry marks '$plugin_spec' disabled/missing in test mode."
      fi
      bridge_info "[info] Enabling Claude plugin: $plugin_spec"
      claude plugin enable --scope user "$plugin_spec" >/dev/null
      ;;
    missing)
      if [[ -n "${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}" ]]; then
        bridge_die "Claude plugin registry is missing '$plugin_spec' in test mode."
      fi
      # #853: self-heal a silently-drifted controller marketplace before
      # the install shell-out. Non-zero return = "could not self-heal,
      # proceed with install as before"; the existing
      # bridge_force_refresh_claude_marketplace retry path below still
      # catches the directory-source agent-bridge marketplace case.
      marketplace="$(bridge_claude_plugin_marketplace "$plugin_spec")"
      if [[ -n "$marketplace" && -n "$agent" ]]; then
        # codex r1 (#858): drop the stdout/stderr suppression so the
        # helper's own bridge_warn on `claude plugin marketplace add`
        # failure surfaces to the operator. `|| true` is retained
        # because the caller intentionally continues into the legacy
        # install path on any non-zero rc — the helper documents that
        # contract in its banner comment.
        bridge_claude_marketplace_ensure_present_for_isolated "$marketplace" "$agent" \
          || true
      fi
      bridge_info "[info] Installing Claude plugin: $plugin_spec"
      if ! output="$(claude plugin install --scope user "$plugin_spec" 2>&1)"; then
        if bridge_claude_plugin_install_missing_from_marketplace "$output" && bridge_force_refresh_claude_marketplace "$marketplace"; then
          bridge_info "[info] Retrying Claude plugin install after marketplace refresh: $plugin_spec"
          claude plugin install --scope user "$plugin_spec" >/dev/null
        else
          printf '%s\n' "$output" >&2
          bridge_die "Claude plugin install failed: $plugin_spec"
        fi
      fi
      ;;
    *)
      bridge_die "Unknown Claude plugin status for '$plugin_spec': $status"
      ;;
  esac

  status="$(bridge_claude_plugin_status "$plugin_spec" "$agent")"
  [[ "$status" == "enabled" ]] || bridge_die "Claude plugin '$plugin_spec' is not enabled after install/setup (status=$status). Run: claude plugin install --scope user $plugin_spec"
}

bridge_claude_channel_plugins_ready_for_csv() {
  local channels="$1"
  # #852: optional agent id threads through to the status probe so the
  # readiness check trusts the isolation-aware short-circuit instead of
  # false-failing on cross-boundary os.access. Single-arg callers keep
  # the legacy behavior.
  local agent="${2-}"
  local item=""
  local plugin_spec=""
  local status=""
  local -a items=()

  [[ -n "$channels" ]] || return 0

  IFS=',' read -r -a items <<<"$(bridge_filter_claude_plugin_channels_csv "$channels")"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ "$item" == plugin:* ]] || continue
    plugin_spec="${item#plugin:}"
    status="$(bridge_claude_plugin_status "$plugin_spec" "$agent")"
    [[ "$status" == "enabled" ]] || return 1
  done

  return 0
}

bridge_agent_channel_setup_complete() {
  local agent="$1"
  local plugins=""

  [[ "$(bridge_agent_channel_status "$agent")" == "ok" || "$(bridge_agent_channel_status "$agent")" == "-" ]] || return 1
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  plugins="$(bridge_merge_channels_csv "$(bridge_agent_required_launch_channels_csv "$agent")" "$(bridge_agent_required_dev_channels_csv "$agent")")"
  bridge_claude_channel_plugins_ready_for_csv "$plugins" "$agent"
}

bridge_ensure_agent_bridge_claude_marketplace() {
  local output=""

  [[ -z "${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}" ]] || return 0
  command -v claude >/dev/null 2>&1 || return 0

  output="$(claude plugin marketplace list 2>/dev/null || true)"
  if printf '%s\n' "$output" | grep -Fq "agent-bridge"; then
    return 0
  fi

  bridge_info "[info] Adding Claude plugin marketplace: agent-bridge"
  claude plugin marketplace add --scope user "$BRIDGE_SCRIPT_DIR" >/dev/null
}

bridge_ensure_claude_channel_plugins_for_csv() {
  local channels="$1"
  # #852/#853: optional agent id threads through to
  # bridge_ensure_claude_plugin_enabled so the controller-side status
  # probe can trust the isolated manifest and the marketplace self-heal
  # can gate on isolation. Existing single-arg callers (none in the
  # tree at time of fix, but the signature stays back-compatible)
  # continue to work — when agent is empty, the downstream calls take
  # the pre-fix code path.
  local agent="${2-}"
  local item=""
  local plugin_spec=""
  local -a items=()

  [[ -n "$channels" ]] || return 0

  IFS=',' read -r -a items <<<"$(bridge_filter_claude_plugin_channels_csv "$channels")"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ "$item" == plugin:* ]] || continue
    plugin_spec="${item#plugin:}"
    if [[ "$plugin_spec" == *@agent-bridge ]]; then
      bridge_ensure_agent_bridge_claude_marketplace
    fi
    bridge_ensure_claude_plugin_enabled "$plugin_spec" "$agent"
  done
}

bridge_ensure_claude_channel_plugins() {
  local agent="$1"

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  bridge_ensure_claude_channel_plugins_for_csv "$(bridge_agent_channels_csv "$agent")" "$agent"
}

bridge_ensure_claude_launch_channel_plugins() {
  local agent="$1"

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  bridge_ensure_claude_channel_plugins_for_csv "$(bridge_agent_effective_launch_plugin_channels_csv "$agent")" "$agent"
}

bridge_agent_notify_kind() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_NOTIFY_KIND[$agent]-}"

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  if [[ -n "$(bridge_agent_discord_channel_id "$agent")" ]]; then
    printf 'discord'
    return 0
  fi

  printf '%s' ""
}

bridge_agent_notify_target() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_NOTIFY_TARGET[$agent]-}"

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  printf '%s' "$(bridge_agent_discord_channel_id "$agent")"
}

bridge_agent_notify_account() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_NOTIFY_ACCOUNT[$agent]-}"
  local kind

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  kind="$(bridge_agent_notify_kind "$agent")"
  case "$kind" in
    discord)
      printf '%s' "${BRIDGE_DISCORD_RELAY_ACCOUNT:-default}"
      ;;
    telegram)
      printf 'default'
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_agent_requires_notify_transport() {
  local agent="$1"
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]]
}

bridge_agent_has_notify_transport() {
  local agent="$1"
  local kind
  local target

  kind="$(bridge_agent_notify_kind "$agent")"
  target="$(bridge_agent_notify_target "$agent")"
  [[ -n "$kind" && -n "$target" ]]
}

bridge_agent_notify_status() {
  local agent="$1"

  if ! bridge_agent_requires_notify_transport "$agent"; then
    printf '%s' "-"
    return 0
  fi

  if bridge_agent_has_notify_transport "$agent"; then
    printf '%s' "ok"
    return 0
  fi

  printf '%s' "miss"
}

bridge_agent_requires_wake_channel() {
  local agent="$1"
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]]
}

bridge_agent_has_wake_channel() {
  local agent="$1"

  if ! bridge_agent_requires_wake_channel "$agent"; then
    return 1
  fi

  [[ -n "$(bridge_agent_session "$agent")" ]]
}

bridge_agent_wake_status() {
  local agent="$1"
  local session=""

  if ! bridge_agent_requires_wake_channel "$agent"; then
    printf '%s' "-"
    return 0
  fi

  session="$(bridge_agent_session "$agent")"
  if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
    case "$(bridge_tmux_claude_blocker_state "$session" 2>/dev/null || true)" in
      trust|summary)
        printf '%s' "block"
        return 0
        ;;
    esac
  fi

  if bridge_agent_has_wake_channel "$agent"; then
    printf '%s' "ok"
    return 0
  fi

  printf '%s' "miss"
}

bridge_agent_loop() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_LOOP[$agent]-1}"
}

bridge_agent_continue() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_CONTINUE[$agent]-1}"
}

bridge_agent_model() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_MODEL[$agent]-}"
}

bridge_agent_effort() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_EFFORT[$agent]-}"
}

bridge_agent_permission_mode() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_PERMISSION_MODE[$agent]-}"
}

# Returns 0 (true) when none of model/effort/permission_mode have been set
# for $agent and permission_mode is not explicitly "legacy". In that case the
# launch builders MUST emit the historical command shape (no --model /
# --effort / --permission-mode flags, --dangerously-skip-permissions kept) so
# rosters that predate these fields keep launching byte-for-byte the same.
bridge_agent_uses_legacy_launch_flags() {
  local agent="$1"
  local pm model effort
  pm="$(bridge_agent_permission_mode "$agent")"
  model="$(bridge_agent_model "$agent")"
  effort="$(bridge_agent_effort "$agent")"
  if [[ "$pm" == "legacy" ]]; then
    return 0
  fi
  [[ -z "$pm" && -z "$model" && -z "$effort" ]]
}

bridge_agent_session_id() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_SESSION_ID[$agent]-}"
}

bridge_agent_meta_file() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_META_FILE[$agent]-}"
}

bridge_agent_history_key() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_HISTORY_KEY[$agent]-}"
}

bridge_agent_action() {
  local agent="$1"
  local action="$2"
  printf '%s' "${BRIDGE_AGENT_ACTION["$agent:$action"]-}"
}

bridge_agent_idle_timeout() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_IDLE_TIMEOUT[$agent]-0}"
}

bridge_agent_idle_timeout_configured() {
  local agent="$1"
  [[ -v "BRIDGE_AGENT_IDLE_TIMEOUT[$agent]" ]]
}

bridge_agent_is_always_on() {
  local agent="$1"
  local timeout

  bridge_agent_idle_timeout_configured "$agent" || return 1
  timeout="$(bridge_agent_idle_timeout "$agent")"
  [[ "$timeout" =~ ^[0-9]+$ ]] || return 1
  (( timeout == 0 ))
}

bridge_agent_memory_daily_refresh_enabled() {
  local agent="$1"
  local configured=""

  [[ "$(bridge_agent_source "$agent")" == "static" ]] || return 1
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1

  if [[ -v "BRIDGE_AGENT_MEMORY_DAILY_REFRESH[$agent]" ]]; then
    configured="${BRIDGE_AGENT_MEMORY_DAILY_REFRESH[$agent]-}"
    case "$configured" in
      1|true|yes|on)
        return 0
        ;;
      0|false|no|off)
        return 1
        ;;
    esac
  fi

  return 0
}

bridge_agent_inject_timestamp() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_INJECT_TIMESTAMP[$agent]-1}"
}

bridge_agent_skills_csv() {
  local agent="$1"
  local configured="${BRIDGE_AGENT_SKILLS[$agent]-}"
  local normalized=""
  local skill=""

  configured="${configured//,/ }"
  for skill in $configured; do
    skill="$(bridge_trim_whitespace "$skill")"
    [[ -n "$skill" ]] || continue
    normalized+="${normalized:+ }$skill"
  done

  printf '%s' "$normalized"
}

bridge_list_actions() {
  local agent="$1"
  local key

  for key in "${!BRIDGE_AGENT_ACTION[@]}"; do
    if [[ "$key" == "$agent:"* ]]; then
      printf '%s\n' "${key#*:}"
    fi
  done | sort -u
}

bridge_agent_is_active() {
  local agent="$1"
  local session

  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] && bridge_tmux_session_exists "$session"
}

bridge_list_agents() {
  local agent
  local actions
  local active

  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || {
    echo "  (등록된 정적 에이전트 없음)"
    return 0
  }

  if [[ ${#BRIDGE_AGENT_IDS[@]} -eq 0 ]]; then
    echo "  (등록된 정적 에이전트 없음)"
    return 0
  fi

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    actions=$(bridge_list_actions "$agent" | paste -sd ',' -)
    if [[ -z "$actions" ]]; then
      actions="-"
    fi

    if bridge_agent_is_active "$agent"; then
      active="yes"
    else
      active="no"
    fi

    printf '  %s — %s\n' "$agent" "$(bridge_agent_desc "$agent")"
    printf '    engine=%s | session=%s | workdir=%s | source=%s | active=%s | loop=%s | actions=%s\n' \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_session "$agent")" \
      "$(bridge_agent_workdir "$agent")" \
      "$(bridge_agent_source "$agent")" \
      "$active" \
      "$(bridge_agent_loop "$agent")" \
      "$actions"
  done
}

bridge_active_agent_ids() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if bridge_agent_is_active "$agent"; then
      printf '%s\n' "$agent"
    fi
  done
}

bridge_active_agent_id_by_index() {
  local target_index="$1"
  local current_index=0
  local agent

  [[ "$target_index" =~ ^[0-9]+$ ]] || return 1
  (( target_index >= 1 )) || return 1

  while IFS= read -r agent; do
    [[ -z "$agent" ]] && continue
    current_index=$((current_index + 1))
    if [[ "$current_index" == "$target_index" ]]; then
      printf '%s' "$agent"
      return 0
    fi
  done < <(bridge_active_agent_ids)

  return 1
}

bridge_list_active_agents_numbered() {
  local index=0
  local agent
  local session_id
  local printed=0
  local summary_output=""
  local -A queue_counts=()
  local -A claimed_counts=()

  if summary_output="$(bridge_queue_cli summary --format tsv 2>/dev/null)"; then
    # Issue #815 Wave A: $summary_output is the entire queue summary
    # (one row per agent) — multi-record text that triggered
    # `heredoc_write` hangs on stale runtimes. Stage through tempfile.
    local _tmp_summary
    _tmp_summary="$(mktemp)" || _tmp_summary=""
    if [[ -n "$_tmp_summary" ]]; then
      # shellcheck disable=SC2064
      trap "rm -f -- '$_tmp_summary'" RETURN
      printf '%s\n' "$summary_output" > "$_tmp_summary"
      while IFS=$'\t' read -r agent_name queued claimed _blocked _active _idle _last_seen _last_nudge _session _engine _workdir; do
        [[ -z "$agent_name" ]] && continue
        queue_counts["$agent_name"]="$queued"
        claimed_counts["$agent_name"]="$claimed"
      done < "$_tmp_summary"
    fi
  fi

  while IFS= read -r agent; do
    [[ -z "$agent" ]] && continue
    index=$((index + 1))
    printed=1
    session_id="$(bridge_agent_session_id "$agent")"
    if [[ -z "$session_id" ]]; then
      session_id="-"
    fi

    # Issue #305 Track C: flag stale registrations whose workdir no longer
    # exists on disk so a leaked smoke fixture or deleted-repo agent is
    # visible in `agent-bridge list` without inspecting the roster file.
    local _workdir
    _workdir="$(bridge_agent_workdir "$agent")"
    if [[ -n "$_workdir" && ! -d "$_workdir" ]]; then
      _workdir="$_workdir [missing]"
    fi

    printf '%d. %s | engine=%s | tmux=%s | cwd=%s | source=%s | loop=%s | inbox=%s | claimed=%s | session_id=%s\n' \
      "$index" \
      "$agent" \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_session "$agent")" \
      "$_workdir" \
      "$(bridge_agent_source "$agent")" \
      "$(bridge_agent_loop "$agent")" \
      "${queue_counts[$agent]-0}" \
      "${claimed_counts[$agent]-0}" \
      "$session_id"
  done < <(bridge_active_agent_ids)

  if [[ "$printed" == "0" ]]; then
    echo "(활성 bridge 에이전트 세션 없음)"
  fi
}

bridge_refresh_runtime_state() {
  if [[ -f "$BRIDGE_HOME/bridge-sync.sh" ]]; then
    "$BRIDGE_BASH_BIN" "$BRIDGE_HOME/bridge-sync.sh" >/dev/null 2>&1 || true
  else
    bridge_render_active_roster
  fi
}

bridge_agent_plugin_port_from_env_file() {
  # Read a single <KEY>=<value> line from a plugin .env file and echo the
  # value if it parses as a port. Empty output on miss.
  local env_file="$1"
  local key="$2"
  local line=""
  local value=""

  [[ -n "$env_file" && -f "$env_file" ]] || return 0
  [[ -n "$key" ]] || return 0
  # Grab the last occurrence — plugin .env files are append-style in places.
  line="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#${key}=}"
  # Strip optional surrounding quotes and whitespace.
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  value="${value//[[:space:]]/}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

bridge_agent_plugin_ports() {
  # Enumerate known plugin ports for an agent. Currently only teams binds
  # a long-lived port inside the tmux pane tree, but the helper is built
  # to grow: each entry is "<port>\t<binary-name>\t<plugin-label>".
  local agent="$1"
  local teams_env=""
  local port=""

  teams_env="$(bridge_agent_teams_state_dir "$agent")/.env"
  port="$(bridge_agent_plugin_port_from_env_file "$teams_env" "TEAMS_WEBHOOK_PORT" 2>/dev/null || true)"
  if [[ -n "$port" ]]; then
    printf '%s\t%s\t%s\n' "$port" "bun" "teams"
  fi

  # Mattermost plugin uses an outbound WebSocket connection (no listener),
  # so it has no port to advertise here. Inbound HTTP listener was removed
  # when the channel migrated from Outgoing Webhook to /api/v4/websocket.
}

bridge_kill_port_holder_if_orphan() {
  # Port-aware fallback to the generic orphan cleanup: if $port is still
  # bound after session stop, find the pid holding it, confirm it is
  # rooted at pid 1 (reparented to init) and that its command matches the
  # plugin binary name, then SIGTERM → wait → SIGKILL it specifically.
  # See issue #69 Defect A.
  local port="$1"
  local binary_name="$2"
  local plugin_label="$3"
  local -a holders=()
  local pid=""
  local ppid_value=""
  local cmd=""
  local attempt=0

  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ -n "$binary_name" ]] || return 0

  # Enumerate PIDs holding the port. Prefer ss -tlnp, fall back to lsof.
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && holders+=("$pid")
    done < <(
      ss -H -tlnp "sport = :${port}" 2>/dev/null \
        | grep -oE 'pid=[0-9]+' \
        | awk -F= '{print $2}' \
        | sort -u
    )
  fi
  if [[ ${#holders[@]} -eq 0 ]] && command -v lsof >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && holders+=("$pid")
    done < <(lsof -ti ":${port}" 2>/dev/null | sort -u)
  fi

  [[ ${#holders[@]} -gt 0 ]] || return 0

  for pid in "${holders[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # Only touch processes that have been reparented to init/launchd (ppid=1
    # or 0). A live session's bun child still parented to a tmux pane
    # process must not be killed from under it.
    ppid_value="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$ppid_value" =~ ^[0-9]+$ ]] || continue
    (( ppid_value == 0 || ppid_value == 1 )) || continue
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    # Require the recognized binary name in the command line to avoid
    # killing an unrelated process that happened to bind the same port.
    [[ "$cmd" == *"${binary_name}"* ]] || continue

    bridge_info "[info] killing reparented ${plugin_label} port holder pid=${pid} port=${port} cmd='${cmd}' (issue #69)"
    kill -TERM "$pid" >/dev/null 2>&1 || true
    for attempt in {1..20}; do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
}

bridge_agent_port_aware_orphan_cleanup_after_session_stop() {
  # Complement to bridge_mcp_orphan_cleanup_after_session_stop: walk the
  # plugin ports this agent reserves and make sure nothing is still
  # holding them after the tmux tree comes down. Belt-and-suspenders for
  # issue #69 Defect A, where reparented bun processes have been observed
  # to survive the pattern-based cleanup.
  local agent="$1"
  local port=""
  local binary=""
  local label=""

  [[ "${BRIDGE_PLUGIN_PORT_ORPHAN_CLEANUP_ENABLED:-1}" == "1" ]] || return 0

  while IFS=$'\t' read -r port binary label; do
    [[ -n "$port" ]] || continue
    bridge_kill_port_holder_if_orphan "$port" "$binary" "$label" \
      >/dev/null 2>&1 || true
  done < <(bridge_agent_plugin_ports "$agent" 2>/dev/null || true)
}

bridge_kill_agent_session() {
  local agent="$1"
  local session
  local attempt

  session="$(bridge_agent_session "$agent")"
  if [[ -z "$session" ]]; then
    bridge_warn "tmux 세션 정보가 없습니다: $agent"
    return 1
  fi

  if ! bridge_tmux_session_exists "$session"; then
    bridge_warn "이미 종료된 세션입니다: $agent/$session"
    return 1
  fi

  bridge_tmux_kill_session "$session"
  for attempt in {1..10}; do
    if ! bridge_tmux_session_exists "$session"; then
      break
    fi
    sleep 0.1
  done
  if bridge_tmux_session_exists "$session"; then
    bridge_warn "tmux 세션이 종료되지 않았습니다: $agent/$session"
    return 1
  fi
  sleep 0.2
  bridge_mcp_orphan_cleanup_after_session_stop "$agent" >/dev/null 2>&1 || true
  bridge_agent_port_aware_orphan_cleanup_after_session_stop "$agent" \
    >/dev/null 2>&1 || true
  bridge_agent_clear_idle_marker "$agent"
  bridge_info "[info] killed ${agent}/${session}"
}

bridge_manual_stop_agent_session() {
  local agent="$1"
  local source

  source="$(bridge_agent_source "$agent")"
  if [[ "$source" == "static" ]]; then
    bridge_agent_mark_manual_stop "$agent"
  fi

  if ! bridge_kill_agent_session "$agent"; then
    if [[ "$source" == "static" ]]; then
      bridge_agent_clear_manual_stop "$agent"
    fi
    return 1
  fi

  if [[ "$source" == "static" ]]; then
    bridge_info "[info] manual stop armed for ${agent}; use 'agent-bridge agent start ${agent}' to resume"
  fi
}

bridge_kill_active_agent_by_index() {
  local index="$1"
  local agent

  if ! agent="$(bridge_active_agent_id_by_index "$index")"; then
    bridge_die "활성 에이전트 번호가 올바르지 않습니다: $index"
  fi

  bridge_manual_stop_agent_session "$agent"
  bridge_refresh_runtime_state
}

bridge_kill_all_active_agents() {
  local -a agents=()
  local agent

  mapfile -t agents < <(bridge_active_agent_ids)
  if [[ ${#agents[@]} -eq 0 ]]; then
    echo "[info] 종료할 활성 bridge 에이전트 세션이 없습니다."
    return 0
  fi

  for agent in "${agents[@]}"; do
    bridge_manual_stop_agent_session "$agent" || true
  done

  bridge_refresh_runtime_state
}

bridge_plugin_port_range_start() {
  printf '%s' "${BRIDGE_PLUGIN_PORT_RANGE_START:-39800}"
}

bridge_plugin_port_range_end() {
  printf '%s' "${BRIDGE_PLUGIN_PORT_RANGE_END:-39999}"
}

bridge_plugin_channel_state_dir() {
  local agent="$1"
  local label="$2"

  case "$label" in
    teams)
      bridge_agent_teams_state_dir "$agent"
      ;;
    discord)
      bridge_agent_discord_state_dir "$agent"
      ;;
    telegram)
      bridge_agent_telegram_state_dir "$agent"
      ;;
    ms365)
      bridge_agent_ms365_state_dir "$agent"
      ;;
    mattermost)
      bridge_agent_mattermost_state_dir "$agent"
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_plugin_port_env_key() {
  local label="$1"

  case "$label" in
    teams)
      printf 'TEAMS_WEBHOOK_PORT'
      ;;
    discord)
      printf 'DISCORD_WEBHOOK_PORT'
      ;;
    telegram)
      printf 'TELEGRAM_WEBHOOK_PORT'
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_read_port_from_env_file() {
  local env_file="$1"
  local key="$2"
  local line=""
  local value=""

  [[ -f "$env_file" ]] || return 0
  [[ -n "$key" ]] || return 0
  line="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#"${key}="}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  value="${value//[[:space:]]/}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

bridge_port_is_free() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  python3 - "$port" <<'PY' 2>/dev/null
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
sys.exit(0)
PY
}

bridge_allocate_channel_port() {
  local agent="$1"
  local label="$2"
  local state_dir=""
  local env_file=""
  local env_key=""
  local range_start range_end span
  local current=""
  local candidate=""
  local hash_hex
  local -i offset=0
  local -i attempts=0
  local -i max_attempts=0
  local -i allocated=0

  if [[ -z "$agent" || -z "$label" ]]; then
    bridge_warn "bridge_allocate_channel_port: agent와 plugin label이 필요합니다"
    return 1
  fi

  if ! state_dir="$(bridge_plugin_channel_state_dir "$agent" "$label")"; then
    bridge_warn "bridge_allocate_channel_port: 지원하지 않는 plugin label: $label"
    return 1
  fi
  if ! env_key="$(bridge_plugin_port_env_key "$label")"; then
    bridge_warn "bridge_allocate_channel_port: plugin label에 대한 port env key를 결정하지 못했습니다: $label"
    return 1
  fi

  env_file="$state_dir/.env"
  range_start="$(bridge_plugin_port_range_start)"
  range_end="$(bridge_plugin_port_range_end)"

  if ! [[ "$range_start" =~ ^[0-9]+$ && "$range_end" =~ ^[0-9]+$ ]] || (( range_start <= 0 || range_end <= 0 || range_end < range_start )); then
    bridge_warn "BRIDGE_PLUGIN_PORT_RANGE_* 가 유효하지 않습니다: ${range_start}-${range_end}"
    return 1
  fi
  span=$(( range_end - range_start + 1 ))

  if [[ -f "$env_file" ]]; then
    current="$(bridge_read_port_from_env_file "$env_file" "$env_key" 2>/dev/null || true)"
  fi
  if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= range_start && current <= range_end )); then
    if bridge_port_is_free "$current"; then
      printf '%s' "$current"
      return 0
    fi
  fi

  hash_hex="$(bridge_sha1 "${agent}|${label}")"
  hash_hex="${hash_hex:0:8}"
  if [[ -z "$hash_hex" ]]; then
    offset=0
  else
    offset=$(( 16#${hash_hex} % span ))
  fi

  max_attempts="$span"
  attempts=0
  while (( attempts < max_attempts )); do
    candidate=$(( range_start + ( offset + attempts ) % span ))
    if bridge_port_is_free "$candidate"; then
      allocated="$candidate"
      break
    fi
    attempts=$(( attempts + 1 ))
  done

  if (( allocated == 0 )); then
    bridge_warn "bridge_allocate_channel_port: ${range_start}-${range_end} 범위에서 사용 가능한 포트를 찾지 못했습니다 (agent=${agent}, label=${label})"
    return 1
  fi

  mkdir -p "$state_dir"
  bridge_upsert_env_value "$env_file" "$env_key" "$allocated"
  printf '%s' "$allocated"
}

bridge_upsert_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local tmp_file=""

  if [[ -z "$env_file" || -z "$key" ]]; then
    return 1
  fi

  mkdir -p "$(dirname "$env_file")"
  if [[ ! -f "$env_file" ]]; then
    printf '%s=%s\n' "$key" "$value" >"$env_file"
    return 0
  fi

  tmp_file="$(mktemp "${env_file}.XXXXXX")" || return 1
  if grep -Eq "^${key}=" "$env_file" 2>/dev/null; then
    awk -v key="$key" -v value="$value" '
      BEGIN { replaced = 0 }
      {
        if ($0 ~ "^" key "=") {
          if (!replaced) {
            print key "=" value
            replaced = 1
          }
        } else {
          print $0
        }
      }
      END {
        if (!replaced) {
          print key "=" value
        }
      }
    ' "$env_file" >"$tmp_file"
  else
    cat "$env_file" >"$tmp_file"
    printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  fi
  mv "$tmp_file" "$env_file"
}

# bridge_scaffold_codex_entrypoint <home> <engine>
#
# Issue #1067 S03: write AGENTS.md as the engine-native entrypoint for a
# Codex agent into its identity source (agent_home). The template scaffold
# loop places CLAUDE.md for every engine (the template only has CLAUDE.md);
# for Codex the native instruction-file convention is AGENTS.md. This
# function creates AGENTS.md as a copy of CLAUDE.md in the same directory
# so the Codex runtime finds its role contract under the canonical filename,
# and bridge_layout_materialize_identity then delivers AGENTS.md into the
# workspace (the descriptor already lists the engine entrypoint in its copy
# set). Safe to call for any engine — it is a no-op when the descriptor
# entrypoint is CLAUDE.md (i.e., not Codex).
#
# Called from bridge-agent.sh (post-scaffold, before materialize) and
# available from lib so smoke drivers sourcing bridge-lib.sh can assert
# the S03 contract without sourcing the full bridge-agent.sh script.
bridge_scaffold_codex_entrypoint() {
  local home="$1"
  local engine="$2"
  [[ -n "$home" && -n "$engine" ]] || return 0
  local entrypoint=""
  if declare -F bridge_engine_entrypoint_filename >/dev/null 2>&1; then
    entrypoint="$(bridge_engine_entrypoint_filename "$engine" 2>/dev/null || printf '')"
  fi
  [[ -n "$entrypoint" && "$entrypoint" != "CLAUDE.md" ]] || return 0
  [[ -f "$home/CLAUDE.md" ]] || return 0
  [[ -f "$home/$entrypoint" ]] && return 0
  cp -f "$home/CLAUDE.md" "$home/$entrypoint" 2>/dev/null || true
}
