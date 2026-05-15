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
  add_required queue daemon daemon-periodic-token-sync launch launch-dev-channels-injection tmux-injection isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip upgrade-isolated-agent-migrate channel-plugins channel-env-readiness hooks upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-codex-pair mattermost-plugin pre-compact-envelope-roundtrip telegram-relay-residue-cleanup agent-create-name-validation agent-update agent-doctor cron-run-artifacts-retention cron-migrate-payloads cron-mutation-audit cron-shell-runner upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering shared-settings-preserve-user-keys status-engine-detect 835-static-admin-launch 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions admin-protocol-shared-link bridge-notify-no-default-discord-875 cleanup-payload-empty-stdin-872 dynamic-agent-shared-mode-workdir
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

  # v0.13.6 hotfix track 1 r2 (codex catch): docs/agent-runtime/admin-protocol.md
  # is the SSOT body that bridge-docs.py renders into <bridge_home>/shared/
  # ADMIN-PROTOCOL.md. A change to the SSOT must trigger the propagation smoke
  # so the rendered body stays in lockstep with the wire-up. This case must
  # precede the is_docs_only_path early-return below, which would otherwise
  # short-circuit on the .md extension and select only the global required
  # smokes.
  case "$path" in
    docs/agent-runtime/admin-protocol.md)
      add_required admin-protocol-shared-link
      ;;
  esac

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
      # Issue #835 Wave B: bridge-status.py gained the
      # `starting/stalled before engine` rendering branch — cover the
      # regression smoke + engine-alive unit smoke when status entry
      # points move.
      add_required queue upgrade-conflicts-lifecycle status-engine-detect 835-static-admin-launch
      add_integration integration-minimal
      ;;

    bridge-queue.py|bridge-task.sh|bridge-audit.py)
      add_required queue
      add_integration integration-minimal
      ;;

    bridge-daemon.sh|bridge-sync.sh|bridge-watchdog.sh|bridge-cron.sh|lib/bridge-cron.sh|lib/bridge-state.sh|lib/bridge-notify.sh)
      # Issue #835 Wave A / B / C: lib/bridge-state.sh hosts
      # bridge_agent_launch_cmd (Wave A heredoc extraction) and the
      # bridge_write_roster_status_snapshot 'starting/stalled before
      # engine' branch (Wave B). Cover the regression smoke + the
      # engine-alive unit smoke when this file moves.
      #
      # Issue #848 r2: bridge-sync-roster-memo guards the bridge-sync.sh
      # roster-cache invalidation contract added on top of the r1
      # per-process memoization. Triggered on bridge-sync.sh and on
      # lib/bridge-state.sh (which hosts bridge_roster_cache_invalidate
      # / bridge_load_roster).
      #
      # v0.13.6 hotfix (refs operator report 2026-05-15 patch host):
      # bridge-daemon.sh exposes a new periodic claude-token sync tick so
      # cron-only static agents do not go stale between rotation events.
      # daemon-periodic-token-sync covers the due-check / tick / audit /
      # state-file cadence contract.
      add_required daemon queue launch-dev-channels-injection channel-env-readiness cron-run-artifacts-retention cron-shell-runner status-engine-detect 835-static-admin-launch bridge-sync-roster-memo daemon-periodic-token-sync
      add_integration integration-minimal
      add_live live-tmux-daemon
      ;;

    bridge-cron.py|bridge-cron-runner.py|bridge-cron-scheduler.py)
      # Issue #533 — cron run-artifact retention/GC contract lives in
      # bridge-cron.py. Cover its smoke directly when any cron-side
      # python file moves.
      # Issue #541 PR-A — memory-daily payload migration also lives in
      # bridge-cron.py; pull its smoke in for the same trigger set.
      # Issue #628 — cron mutation audit emission ditto.
      # Native cron shell payload runner regression.
      # v0.13.5 hotfix — RESULT_SCHEMA must satisfy OpenAI Structured
      # Outputs strict mode (every key in properties must appear in
      # required at every nested object level). Cover the invariant
      # smoke whenever bridge-cron-runner.py moves so a future PR can't
      # silently regress the strict-mode contract.
      # #874 (v0.13.6 hotfix): bridge-cron-runner.py's COMMON_BIN_DIRS +
      # BRIDGE_CRON_EXTRA_PATH ext point control whether cron-driven
      # codex/claude invocations can locate both the CLI binary AND the
      # node interpreter under fnm/nvm/asdf/volta. Pin the registration
      # contract smoke whenever the runner moves so a future PR cannot
      # silently regress the fallback list.
      add_required cron-run-artifacts-retention cron-migrate-payloads cron-mutation-audit cron-shell-runner cron-runner-schema-openai-strict cron-path-augmentation-874 queue
      add_integration integration-minimal
      ;;

    bridge-start.sh|bridge-run.sh|bridge-send.sh|bridge-action.sh|bridge-agent.sh|agent-bridge|agb|lib/bridge-tmux.sh|lib/bridge-session-patterns.sh|lib/bridge-wave.sh|lib/bridge-agent-update.sh|lib/bridge-doctor.sh)
      # Issue #835 Wave B: lib/bridge-tmux.sh hosts the new
      # bridge_agent_engine_process_alive predicate and
      # bridge_tmux_command_name_matches_engine basename helper.
      # bridge-agent.sh::bridge_agent_activity_state consumes them.
      # Cover both Wave C's integration smoke + Wave B's unit smoke
      # whenever either file moves.
      add_required launch launch-dev-channels-injection tmux-injection upgrade-source-preservation upgrade-shared-settings-propagate agent-create-name-validation agent-update agent-doctor upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering status-engine-detect 835-static-admin-launch
      add_integration integration-minimal
      add_live live-tmux-daemon
      ;;

    hooks/tool-policy.py|bridge-config.py|lib/system_config_paths.py)
      # Issue #528: tool-policy / wrapper / protected-glob changes can
      # alter the trust-model envelope the typed agent-update path
      # mirrors. Run agent-update to catch drift in the contract.
      # Issue #583 (v0.8.0 T4): tool-policy.py's system-class allowlist
      # for cross-agent reads is the v1 partial fix that v2's group
      # permission model supersedes; cover the v2 closure smoke so
      # changes to the allowlist don't silently regress the v2 path.
      # v0.13.6 track 2: admin agent read-intent exemption pass on
      # credential deny surfaces (raw mention, env dump, argv path,
      # input path). Cover the regression smoke whenever tool-policy.py
      # moves so the exemption + mutation deny contract stays pinned.
      add_required hooks agent-update v2-cross-class-read admin-hook-exemption
      add_integration integration-minimal
      ;;

    lib/bridge-isolation*.sh|lib/bridge-migration.sh|bridge-migrate.sh|lib/bridge-marker-bootstrap.sh|tests/isolation*)
      # Issue #583 closure smoke (v0.8.0 T4): the cross-class read
      # boundary depends directly on lib/bridge-isolation-v2.sh
      # primitives (group + setgid model), so cover it whenever any
      # isolation lib moves. v0.8.1 hotfix: lock-portability smoke
      # also lives in this trigger row (mkdir-based atomic lock in
      # bridge-isolation-v2-migrate.sh).
      # Issue #857 PR-1: bridge_isolation_write_file_as_agent_user_via_bash
      # lives in lib/bridge-isolation-helpers.sh; pull its regression
      # smoke in on every isolation-lib move so the write helper's
      # pre-check + atomic write rc map stays covered.
      # Issue #864: bridge_isolation_v2_migrate_marker_write owner fix
      # (R1) + normalize_layout per-agent .claude/plugins/ chmod 2770
      # (R3) live in lib/bridge-isolation-v2-migrate.sh; the matrix
      # row for the manifests dir (R3) lives in lib/bridge-isolation-v2.sh;
      # the marker validator the R1 fix targets lives in
      # lib/bridge-marker-bootstrap.sh. Pull the smoke in for every
      # isolation-lib + marker-bootstrap move.
      # #857 PR-6 (v0.13.4): `agent-bridge migrate isolation v3` channel-
      # dotenv migrator lives in lib/bridge-isolation-v3-channel-dotenv.sh
      # and depends directly on v2-reapply primitives; pull its smoke
      # for every isolation-lib + bridge-migrate.sh move.
      add_required isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions launch
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

    scripts/apply-channel-policy.sh|lib/bridge-channels.sh|lib/bridge-discord.sh|bridge-discord-relay.sh|bridge-notify.sh|bridge-notify.py|runtime-templates/*)
      # Issue #875: bridge-notify.py owns the implicit-default account silent-
      # skip contract — when an agent has no Discord channel and the runner
      # reaches the default-account lookup, the runner must return 0 with a
      # structured skip row instead of surfacing "discord account not found:
      # default" as a hard failure in cron-followup bodies. Cover the
      # regression smoke whenever bridge-notify.py moves so the strict-miss
      # vs default-miss split stays intact.
      add_required channel-plugins bridge-notify-no-default-discord-875
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

    hooks/codex-task-mode-policy.py|hooks/codex-review-output-shape.py)
      # Issue #639 — codex companion-role policy hook redesign
      # (default-deny block-mode allow-list + common-shape parser). The
      # comprehensive smoke covers all 6 D1 gaps + PR #636 r1-r5 regression
      # + grant grammar; the original codex-companion-hooks.sh remains the
      # source-of-truth for the queue-time validator and ensure-codex-hooks
      # wiring. Pull both in for any change to either codex companion hook.
      add_required hooks codex-task-mode-policy-comprehensive codex-companion-hooks
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
      # v0.13.6 track 2: hooks/prompt-guard.py grew an admin
      # warn-only carve-out for low/medium severity hits and reuses
      # tool-policy's `is_admin_agent`. The admin-hook-exemption smoke
      # covers both the prompt-guard branch and the tool-policy
      # credential-deny exemption.
      add_required hooks upgrade-shared-settings-propagate managed-autocompact-window isolated-settings-rendering per-agent-settings-rendering shared-settings-preserve-user-keys admin-hook-exemption
      add_integration integration-minimal
      ;;

    bridge-upgrade.sh|bridge-upgrade.py|scripts/export-public-snapshot.sh|VERSION)
      # Issue #652 (v0.8.2 hotfix): bridge-upgrade.py:cmd_migrate_agents
      # gained a try/except for PermissionError + a `memory/` template
      # skip; cover its smoke directly when the upgrade Python or shell
      # entry moves.
      # Issue #864 (v0.13.0 hotfix): bridge-upgrade.sh gained the post-
      # apply-live `find scripts/ -type d -exec chmod a+rX {} +` step
      # (R2). Pull the per-regression smoke whenever the upgrade entry
      # moves so the umask=077 dir normalization stays pinned.
      # Issue #872 (v0.13.6 track 7): bridge_cleanup_render_summary's
      # empty-stdin / invalid-payload degradation is invoked from
      # bridge-upgrade.sh's [upgrade-complete] task body composer; pull
      # its regression smoke in whenever the upgrade entry moves so the
      # task body cannot regress to leaking raw JSONDecodeError text.
      add_required upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-codex-pair telegram-relay-residue-cleanup upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering upgrade-isolated-agent-migrate 864-upgrade-perm-regressions cleanup-payload-empty-stdin-872
      add_integration integration-minimal
      ;;

    lib/bridge-cleanup.sh)
      # Issue #872 (v0.13.6 track 7): the cleanup payload renderer must
      # degrade gracefully on empty / invalid stdin so the
      # [upgrade-complete] task body never contains a raw Python
      # JSONDecodeError. Cover the regression whenever the cleanup lib
      # moves.
      add_required cleanup-payload-empty-stdin-872 upgrade telegram-relay-residue-cleanup
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

    scripts/python-helpers/launch-cmd-*.py)
      # Issue #835 Wave A: launch-cmd Python heredoc bodies were extracted
      # from lib/bridge-state.sh into standalone .py files to dodge the
      # Bash 5.3.9 heredoc_write deadlock on the static admin
      # `bridge_agent_launch_cmd` path. Any modification to these helpers
      # must re-run the Wave C regression smoke that asserts the call
      # returns in <2s.
      add_required 835-static-admin-launch launch launch-dev-channels-injection channel-env-readiness
      add_integration integration-minimal
      ;;

    scripts/python-helpers/cleanup-payload-renderer.py)
      # PR #886 r2: bridge_cleanup_render_summary delegates the JSON →
      # markdown render to this fixture file so the renderer body lives
      # outside any heredoc (post-#800 footgun #11 mitigation). Any
      # change to the fixture must re-run the empty-stdin regression
      # smoke that asserts the renderer never leaks JSONDecodeError.
      add_required cleanup-payload-empty-stdin-872 upgrade telegram-relay-residue-cleanup
      add_integration integration-minimal
      ;;

    bridge-lib.sh|lib/bridge-core.sh|lib/bridge-agents.sh|agent-roster.sh|agent-roster.local.example.sh|bridge-config.sh)
      add_all_required_static
      add_all_integration
      add_live live-tmux-daemon
      ;;

    bridge-docs.py)
      # v0.13.6 hotfix track 1: bridge-docs.py owns AGENT_SHARED_LINKS and
      # the shared-doc render dispatch. The admin-protocol-shared-link
      # smoke pins the wire-up that propagates docs/agent-runtime/
      # admin-protocol.md into <bridge_home>/shared/ADMIN-PROTOCOL.md and
      # symlinks it from every agent home. Cover it on every bridge-docs.py
      # move so the dispatch table and link tuple stay in lockstep.
      add_required admin-protocol-shared-link
      add_integration integration-minimal
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
  # Issue #815 Wave D: destructive regression smoke is repo-wide coverage
  # for the heredoc / here-string deadlock surface Wave A/B/C fixed. It
  # runs on every required-suite invocation regardless of diff so a
  # future commit that touches an unrelated file cannot accidentally
  # regress the deadlock or detection-gap class without CI catching it.
  add_required heredoc-regression
  # Task #4494 Wave D: integrated dynamic-recovery smoke exercises the
  # 3 already-shipped surface fixes from #826 (PR #837 bridge-sync
  # grace) / #827 (PR #840 live Claude session id pre-transcript) /
  # #828 (PR #839 skill auto-help opt-in) in a single end-to-end flow
  # simulating the operator's 2026-05-14 `crm-test` recovery scenario.
  # Pinned to every required-suite run regardless of diff so a future
  # commit that touches an unrelated file cannot regress any of the
  # three vectors in combination.
  add_required 4494-integrated-dynamic-recovery
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
