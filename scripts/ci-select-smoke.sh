#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

suite="required"
run_selected=0
base_ref="${BASE_SHA:-}"
head_ref="${HEAD_SHA:-HEAD}"
changed_files=""

usage() {
  cat <<'EOF'
Usage: scripts/ci-select-smoke.sh [--suite required|integration|live|legacy] [--base <sha>] [--head <sha>] [--changed-file <path>] [--run]

Selects modular smoke tests from the PR/push diff. With --run, executes the
selected scripts in order. Without --run, prints one script path per line.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      suite="$2"
      shift 2
      ;;
    --base)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      base_ref="$2"
      shift 2
      ;;
    --head)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      head_ref="$2"
      shift 2
      ;;
    --changed-file)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      changed_files+="$2"$'\n'
      shift 2
      ;;
    --run)
      run_selected=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ci-select-smoke.sh: unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$suite" in
  required|integration|live|legacy) ;;
  *)
    echo "ci-select-smoke.sh: unsupported suite: $suite" >&2
    exit 2
    ;;
esac

script_for() {
  local name="$1"
  printf 'scripts/smoke/%s.sh' "$name"
}

selected=$'\n'
add_script() {
  local script="$1"
  case "$selected" in
    *$'\n'"$script"$'\n'*) ;;
    *) selected+="$script"$'\n' ;;
  esac
}

add_required() {
  [[ "$suite" == "required" ]] || return 0
  local name
  for name in "$@"; do
    add_script "$(script_for "$name")"
  done
}

add_integration() {
  [[ "$suite" == "integration" ]] || return 0
  local name
  for name in "$@"; do
    add_script "$(script_for "$name")"
  done
}

add_live() {
  [[ "$suite" == "live" ]] || return 0
  local name
  for name in "$@"; do
    add_script "$(script_for "$name")"
  done
}

add_all_required_static() {
  add_required queue daemon launch launch-dev-channels-injection tmux-injection isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering isolated-cli-policy channel-plugins channel-env-readiness hooks upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-codex-pair mattermost-plugin pre-compact-envelope-roundtrip telegram-relay-residue-cleanup agent-create-name-validation agent-update cron-run-artifacts-retention cron-migrate-payloads upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering shared-settings-preserve-user-keys
}

add_all_integration() {
  add_integration integration-minimal
}

add_all_live() {
  add_live live-tmux-daemon
}

is_docs_only_path() {
  local path="$1"
  case "$path" in
    *.md|docs/*|.github/ISSUE_TEMPLATE/*|.github/pull_request_template.md|LICENSE|NOTICE|CHANGELOG.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_changed_files() {
  if [[ -n "$changed_files" ]]; then
    printf '%s' "$changed_files"
    return 0
  fi

  if [[ "${GITHUB_EVENT_NAME:-}" == "schedule" || "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
    printf '__ALL__\n'
    return 0
  fi

  if [[ -n "$base_ref" && -n "$head_ref" && ! "$base_ref" =~ ^0+$ ]]; then
    if git -C "$REPO_ROOT" cat-file -e "${base_ref}^{commit}" 2>/dev/null \
      && git -C "$REPO_ROOT" cat-file -e "${head_ref}^{commit}" 2>/dev/null; then
      git -C "$REPO_ROOT" diff --name-only "$base_ref" "$head_ref"
      return 0
    fi
  fi

  if git -C "$REPO_ROOT" rev-parse --verify HEAD^ >/dev/null 2>&1; then
    git -C "$REPO_ROOT" diff --name-only HEAD^ HEAD
  else
    printf '__ALL__\n'
  fi
}

select_for_path() {
  local path="$1"

  if [[ "$path" == "__ALL__" ]]; then
    add_all_required_static
    add_all_integration
    add_all_live
    return 0
  fi

  if is_docs_only_path "$path"; then
    return 0
  fi

  case "$path" in
    .github/workflows/*|scripts/ci-select-smoke.sh|scripts/smoke/*)
      add_all_required_static
      add_all_integration
      add_all_live
      ;;

    bridge-setup.py|bridge-setup.sh|bridge-status.py|bridge-status.sh)
      add_required queue upgrade-conflicts-lifecycle
      add_integration integration-minimal
      ;;

    bridge-queue.py|bridge-task.sh|bridge-audit.py)
      add_required queue
      add_integration integration-minimal
      ;;

    bridge-daemon.sh|bridge-sync.sh|bridge-watchdog.sh|bridge-cron.sh|lib/bridge-cron.sh|lib/bridge-state.sh|lib/bridge-notify.sh)
      add_required daemon queue launch-dev-channels-injection channel-env-readiness cron-run-artifacts-retention
      add_integration integration-minimal
      add_live live-tmux-daemon
      ;;

    bridge-cron.py|bridge-cron-runner.py|bridge-cron-scheduler.py)
      # Issue #533 — cron run-artifact retention/GC contract lives in
      # bridge-cron.py. Cover its smoke directly when any cron-side
      # python file moves.
      # Issue #541 PR-A — memory-daily payload migration also lives in
      # bridge-cron.py; pull its smoke in for the same trigger set.
      add_required cron-run-artifacts-retention cron-migrate-payloads queue
      add_integration integration-minimal
      ;;

    bridge-start.sh|bridge-run.sh|bridge-send.sh|bridge-action.sh|bridge-agent.sh|agent-bridge|agb|lib/bridge-tmux.sh|lib/bridge-session-patterns.sh|lib/bridge-wave.sh|lib/bridge-agent-update.sh)
      add_required launch launch-dev-channels-injection tmux-injection upgrade-source-preservation upgrade-shared-settings-propagate agent-create-name-validation agent-update upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering
      add_integration integration-minimal
      add_live live-tmux-daemon
      ;;

    hooks/tool-policy.py|bridge-config.py|lib/system_config_paths.py)
      # Issue #528: tool-policy / wrapper / protected-glob changes can
      # alter the trust-model envelope the typed agent-update path
      # mirrors. Run agent-update to catch drift in the contract.
      add_required hooks agent-update
      add_integration integration-minimal
      ;;

    lib/bridge-isolation*.sh|lib/bridge-migration.sh|bridge-migrate.sh|tests/isolation*)
      add_required isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering isolated-cli-policy launch
      add_integration integration-minimal
      add_live live-tmux-daemon
      ;;

    bin/agb|bin/*)
      # Issue #544 PR1 — curated bin/ shim for isolated agents.
      # Issue #544 PR4 — same shim carries the isolated-CLI policy gate.
      add_required isolated-bin-agb isolated-cli-policy isolation launch
      add_integration integration-minimal
      ;;

    lib/bridge-skills.sh|.claude/skills/*)
      # Issue #544 PR3 — bridge-native skill sync into isolated HOME.
      # Path text rewrite + tree walk live in lib/bridge-skills.sh and
      # the source skill bodies are the rewrite input.
      add_required isolated-skills-sync isolation launch
      add_integration integration-minimal
      ;;

    scripts/apply-channel-policy.sh|lib/bridge-channels.sh|lib/bridge-discord.sh|bridge-discord-relay.sh|bridge-notify.sh|runtime-templates/*)
      add_required channel-plugins
      add_integration integration-minimal
      ;;

    .claude-plugin/marketplace.json|plugins/*/.claude-plugin/plugin.json|plugins/*/.mcp.json)
      add_required channel-plugins
      add_integration integration-minimal
      ;;

    plugins/mattermost/*|plugins/mattermost/*/*|plugins/mattermost/*/*/*)
      add_required mattermost-plugin
      add_integration integration-minimal
      ;;

    hooks/pre-compact.py|bridge-memory.py|scripts/librarian-process-ingest.py)
      add_required pre-compact-envelope-roundtrip hooks upgrade-shared-settings-propagate
      add_integration integration-minimal
      ;;

    hooks/*|bridge-hooks.py|lib/bridge-hooks.sh)
      # Issue #544 PR2 — bridge-hooks.py grew the
      # `render-isolated-home-settings` subcommand and lib/bridge-hooks.sh
      # grew `bridge_install_isolated_home_settings`. Pull the new smoke
      # in whenever either touches.
      # Issue #555 — `bridge_link_claude_settings_to_shared` /
      # `bridge_ensure_claude_*_hook` now take an optional 3rd `agent`
      # arg that switches to per-agent rendering; cover the regression.
      # Issue #613 — shared renderer now preserves operator-edited user
      # keys symmetrically with the isolated renderer.
      add_required hooks upgrade-shared-settings-propagate managed-autocompact-window isolated-settings-rendering per-agent-settings-rendering shared-settings-preserve-user-keys
      add_integration integration-minimal
      ;;

    bridge-upgrade.sh|bridge-upgrade.py|scripts/export-public-snapshot.sh|VERSION)
      add_required upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-codex-pair telegram-relay-residue-cleanup upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering
      add_integration integration-minimal
      ;;

    bridge-relay-cleanup.py)
      add_required upgrade upgrade-shared-settings-propagate telegram-relay-residue-cleanup
      add_integration integration-minimal
      ;;

    bridge-init.sh|lib/bridge-admin-pair.sh)
      add_required admin-codex-pair upgrade-shared-settings-propagate managed-autocompact-window per-agent-settings-rendering
      add_integration integration-minimal
      ;;

    bridge-lib.sh|lib/bridge-core.sh|lib/bridge-agents.sh|agent-roster.sh|agent-roster.local.example.sh|bridge-config.sh)
      add_all_required_static
      add_all_integration
      add_live live-tmux-daemon
      ;;

    *.sh|lib/*.sh|scripts/*.sh|*.py|scripts/*.py)
      add_required launch queue
      add_integration integration-minimal
      ;;

    *)
      add_all_required_static
      add_all_integration
      ;;
  esac
}

if [[ "$suite" == "legacy" ]]; then
  add_script "$(script_for legacy-full-smoke)"
else
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    select_for_path "$path"
  done < <(detect_changed_files)
fi

selected_list="$(printf '%s\n' "$selected" | sed '/^$/d')"

if [[ $run_selected -eq 0 ]]; then
  printf '%s\n' "$selected_list"
  exit 0
fi

if [[ -z "$selected_list" ]]; then
  echo "[ci-select] no $suite smoke selected for this change set"
  exit 0
fi

for script in $selected_list; do
  [[ -n "$script" ]] || continue
  if [[ ! -f "$REPO_ROOT/$script" ]]; then
    echo "[ci-select][error] selected smoke script is missing: $script" >&2
    exit 1
  fi
  echo "::group::$script"
  if ! bash "$REPO_ROOT/$script"; then
    echo "::endgroup::"
    echo "[ci-select][error] $suite smoke failed in $script" >&2
    exit 1
  fi
  echo "::endgroup::"
done
