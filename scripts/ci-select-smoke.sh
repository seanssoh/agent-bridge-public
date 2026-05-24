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

  add_required queue daemon daemon-periodic-token-sync launch launch-dev-channels-injection tmux-injection isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip isolation-v2-marker-only-migrate isolation-v2-macos-noise-suppression isolation-v2-platform-discriminator isolation-v2-bucket2-gates layout-resolver-marker-over-env bsd-mktemp-portability upgrade-isolated-agent-migrate channel-plugins channel-env-readiness hooks upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-pair-server-auto-provision mattermost-plugin pre-compact-envelope-roundtrip telegram-relay-residue-cleanup agent-create-name-validation agent-create-caller-trust-gate agent-create-idle-timeout 1105-agent-add-audit 1100-audit-since-tz agent-update agent-update-launch-cmd-redaction 1122-admin-auto-caller-source 1136-always-on-no agent-doctor cron-run-artifacts-retention cron-migrate-payloads cron-mutation-audit cron-shell-runner 1114-cli-help-contract upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering 1120-controller-ops-isolated 1139-link-shared-settings-perm 1144-upgrade-complete-task 1145-ensure-dir-actually-sudo 1145-option1-deferral-guard 1151-step-a-helper 1151-r2-sudo-escalate 1155-bootstrap-skill-guard 1158-marker-controller-uid-exemption 1158-marker-load-order 1161-marker-readable-by-isolated 1165-track-a-scaffold-modes 1165-track-b-sudo-escalate-and-state 1165-track-c-hooks-and-dispatcher 1170-safe-path-check-sudo-escalate 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp shared-settings-preserve-user-keys status-engine-detect 835-static-admin-launch 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions 1021-isolation-v2-shared-plugin-perms 1025-isolated-create-agent-env-install 1028-isolated-workdir-check 1118-v2-engine-binary-path admin-protocol-shared-link bridge-notify-no-default-discord-875 cleanup-payload-empty-stdin-872 dynamic-agent-shared-mode-workdir v2-scaffold-home-and-workdir 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair agent-env-no-stale-bridge-layout 1015-resume-claude-config-dir 1073-fresh-channel-first-run-seed isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup nudge-task-age-gate 1106-nudge-shell-recheck nudge-redundant-active-agent tool-policy-roster-read-classify 679-wiki-ingest-exclude-precompact a2a-cross-bridge 1058-bootstrap-tmux-ux legacy-install-migrator 1117-cli-help-universal-gate 1087-migrator-apply-contract 1067-codex-provisioning 1077-migrate-iso-v2-data-dir 1108-watchdog-v2-workdir 1119-watchdog-perm-error 1113-watchdog-legacy-backfill 1115-cli-usage-drift phase2-install-tree-reconciler


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
    agents/_template/CLAUDE.md|agents/_template/.claude/commands/wrap-up.md)
      # Issue #1060 D3/D4: these tracked templates carry the
      # resolver-derived layout wording (CLAUDE.md) and the per-agent
      # memory-dir resolution (wrap-up.md). They are .md files, so the
      # is_docs_only_path early-return below would otherwise select only
      # the global required smokes. This case precedes that return so a
      # template-text drift still pulls the #1060 layout smokes.
      add_required 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair 1067-codex-provisioning
      ;;
  esac

  # Issue #1114: subcommand-group dispatchers previously rejected
  # `--help`. The 1114-cli-help-contract smoke pins the contract for
  # the 16 sites the PR touched (incl. the dangerous case where
  # `daemon ensure --help` silently ran cmd_start). Pull it additively
  # whenever any affected CLI dispatcher moves — the main `case` below
  # routes most of these files into broader trigger rows for their
  # primary smokes, so this pre-pass adds 1114 ON TOP without
  # competing with the case-first-match. Companion follow-ups
  # #1115 / #1116 / #1117 own the broader contract.
  #
  # Issue #1117: the universal --help/-h contract gate walks every
  # top-level branch + every dispatcher verb (bridge-agent.sh,
  # bridge-cron.sh, bridge-task.sh, bridge-daemon.sh) and asserts the
  # no-side-effect property for daemon verbs. Pull it on every CLI
  # dispatcher move so a future PR cannot regress the contract for a
  # verb the 16-site #1114 pin didn't cover.
  case "$path" in
    agent-bridge|agb|bridge-upgrade.sh|bridge-memory.sh|bridge-intake.sh|bridge-bundle.sh|bridge-cron.sh|bridge-daemon.sh|bridge-discord-relay.sh|bridge-send.sh|bridge-agent.sh|bridge-profile.sh|bridge-task.sh)
      add_required 1114-cli-help-contract 1117-cli-help-universal-gate
      # Issue #1165 Gap 8: the agent-bridge dispatcher head carries
      # the BRIDGE_CONTROLLER_UID recovery block that re-arms the
      # marker validator's owner exemption (#1158) when agb is
      # invoked directly from an isolated UID (not through the
      # bridge-start.sh sudo wrapper). Pull the Track C smoke on
      # every dispatcher move so a future PR cannot regress the
      # recovery + marker-stat formula away from
      # lib/bridge-marker-bootstrap.sh's path resolution.
      case "$path" in
        agent-bridge|agb)
          add_required 1165-track-c-hooks-and-dispatcher
          ;;
      esac
      ;;
    lib/bridge-cron.sh|lib/bridge-state.sh)
      # Issue #1117: lib/bridge-cron.sh hosts bridge_cron_python +
      # bridge_require_cron_source_jobs, the helpers `bridge-cron.sh`'s
      # verb arms route --help through. lib/bridge-state.sh hosts the
      # roster/agent helpers `bridge-agent.sh`'s run_* arms call before
      # processing --help. Pull the universal gate on either lib move
      # so a future PR cannot regress a verb's --help path via the
      # underlying helper.
      add_required 1117-cli-help-universal-gate
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

    scripts/cli-help/*)
      # Issues #1115 + #1116: the operator-facing CLI usage template
      # (scripts/cli-help/agent-bridge-usage.txt) must stay in lockstep
      # with the dispatcher's case-switch. Pull 1115-cli-usage-drift on
      # every template edit so a future PR cannot regress the documented
      # surface (a missing PUBLIC subcommand or a leaked INTERNAL one).
      #
      # Issue #1117: the universal --help/-h contract gate parses the
      # same template to enumerate top-level commands. Pull it on every
      # template edit so a new __CLI_NAME__ <cmd> row that lacks an
      # accepting --help dispatcher arm trips CI at PR time.
      add_required 1115-cli-usage-drift 1117-cli-help-universal-gate
      ;;

    bridge-setup.py|bridge-setup.sh|bridge-status.py|bridge-status.sh)
      # Issue #835 Wave B: bridge-status.py gained the
      # `starting/stalled before engine` rendering branch — cover the
      # regression smoke + engine-alive unit smoke when status entry
      # points move.
      # Issue #1155: bridge-setup.sh:886/:986 thread the agent id into
      # `bridge_bootstrap_project_skill` so the v2-isolation guard can
      # fire. Pull 1155-bootstrap-skill-guard on every bridge-setup.sh
      # move so the thread-through cannot regress.
      # Issue #1165 Track A: bridge-setup.py:_isolation_aware_mkdir
      # gained the mode/group widening (Gap 1) so isolated channel
      # state dirs (.teams/.telegram/.discord/.mattermost/) land at
      # 2750 not 0700. Pull 1165-track-a on every bridge-setup.py move
      # so the helper signature + sudo-script chmod step cannot
      # regress back to the umask-only shape.
      # Issue #1170: bridge-setup.py:_safe_path_check now proactively
      # sudo-escalates when `os_user` is provided (instead of waiting
      # for a PermissionError to fall back) and fail-closes the direct
      # pathlib branch so `setup teams|telegram|discord` no longer
      # raises a traceback when the controller cannot stat
      # `.teams/.env` under v2 isolation (Track A fix mode 2750 +
      # ab-agent-<a> group but controller not in the group). Pull
      # 1170-safe-path-check-sudo-escalate on every bridge-setup.py
      # move so the sudo-first shape and fail-closed semantics cannot
      # silently regress to raw `path.exists()`.
      # Issue #1175: bridge-setup.py + bridge-hooks.py now both import
      # the canonical safe-path helpers from `lib/bridge_iso_paths.py`
      # (previously duplicated locally with subtly different shapes).
      # Pull 1175-exhaustive-pathlib-audit on every bridge-setup.py move
      # so the shared-module wiring, the swept HIGH sites (L392 mkdir
      # idempotency, L1873 mattermost MCP, L1995 channel access preserve),
      # and the lint-raw-pathlib-on-isolated regression guard cannot
      # silently regress.
      # Issue #1178 (cycle 12 architectural root): bridge-setup.py's
      # `_isolation_aware_mkdir` traceback at L368 was unblocked by
      # routing the new `_sudo_stat_owner` recovery in
      # `lib/bridge_iso_paths.py`. The L368 raw mkdir is now noqa'd as
      # the controller-owned post-helper fallback. Pull
      # 1178-helper-contract-daemon-supp on every bridge-setup.py move
      # so the L368 reproducer + extended lint baseline cannot regress.
      add_required queue upgrade-conflicts-lifecycle status-engine-detect 835-static-admin-launch 1155-bootstrap-skill-guard 1165-track-a-scaffold-modes 1170-safe-path-check-sudo-escalate 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp
      add_integration integration-minimal
      ;;

    bridge-queue.py|bridge-task.sh|bridge-audit.py)
      # Issue #1014 A: bridge-queue.py's daemon idle-nudge now gates the
      # ACTION REQUIRED nudge on task-queued age so a freshly-pushed task
      # is not re-nudged within the redelivery window. Cover the
      # regression smoke whenever the queue backend moves.
      #
      # Issue #1032: the A2A receiver routes accepted cross-bridge
      # handoffs through bridge-task.sh create as its enqueue boundary,
      # so a change to that boundary must re-run the A2A end-to-end
      # smoke alongside the queue regression smokes.
      #
      # Issues #1115 + #1116: bridge-task.sh hosts the `create` shorthand
      # that agent-bridge dispatches via the inbox|show|claim|done|…|create
      # alt and the smoke's T2 documents-every-public-toplevel check. Pull
      # 1115-cli-usage-drift so a change to bridge-task.sh's case dispatch
      # cannot silently invalidate the operator-facing shorthand surface.
      add_required queue 1106-nudge-shell-recheck nudge-task-age-gate nudge-redundant-active-agent a2a-cross-bridge 1100-audit-since-tz 1115-cli-usage-drift
      add_integration integration-minimal
      ;;

    bridge-a2a.py|bridge-handoffd.py|bridge_a2a_common.py|bridge-handoff-daemon.sh|lib/bridge-a2a.sh|handoff.local.example.json|scripts/smoke/a2a-cross-bridge-helper.py)
      # Issue #1032: A2A cross-bridge task handoff. Any move to the
      # receiver daemon, sender outbox/delivery-runner, shared protocol
      # module, lifecycle helper, or the smoke helper re-runs the
      # end-to-end A2A smoke (auth/allowlist/dedupe/cap/retry).
      add_required a2a-cross-bridge queue
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
      #
      # Issue #1015: lib/bridge-state.sh hosts the resume/detect shims
      # (bridge_detect_claude_session_id, bridge_detect_session_id,
      # bridge_resolve_resume_session_id) that thread the agent's
      # CLAUDE_CONFIG_DIR to the python helpers; bridge-sync.sh's
      # refresh_missing_session_ids is one of the callers. Cover the
      # config-root resolution smoke whenever either file moves.
      # Issue #1116: bridge-cron.sh's `case "$subcommand" in` block must
      # stay in lockstep with the operator-facing usage template's
      # `cron <…>` line + the typo-suggestion candidate list. Pull
      # 1115-cli-usage-drift on every cron dispatcher move so a future
      # PR cannot regress an internal subcommand back into the public
      # surface (or drop a public one).
      # Issue #1178 (cycle 12, Deliverable C): bridge-daemon.sh gained
      # a startup supplementary-group staleness warning
      # (bridge_daemon_warn_if_supp_groups_stale). Pull
      # 1178-helper-contract-daemon-supp on every bridge-daemon.sh move
      # so the warning behavior + macOS no-op gate cannot regress
      # silently.
      add_required daemon queue launch-dev-channels-injection channel-env-readiness cron-run-artifacts-retention cron-shell-runner status-engine-detect 835-static-admin-launch bridge-sync-roster-memo daemon-periodic-token-sync 1015-resume-claude-config-dir 1115-cli-usage-drift 1178-helper-contract-daemon-supp
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
      # Issue #1010: bridge-agent.sh::run_delete now calls the isolated-
      # agent OS-user reap helper; cover its gating-decision smoke so a
      # regression in the delete-path wire-up is caught.
      # Issue #1023: the typed `agent update --launch-cmd-*` path now
      # redacts credential-bearing env values across every output
      # surface (diff / operation_summary / actions / audit detail /
      # --json / plain text / dry-run). Pull the redaction smoke
      # whenever bridge-agent.sh or lib/bridge-agent-update.sh moves so
      # a future PR cannot regress a secret-leak surface.
      # Issue #1028: bridge-start.sh's workdir-existence decision is
      # privilege-aware for linux-user isolated agents (sudo-backed
      # `test -d` instead of a plain controller `[[ -d ]]` that
      # false-negates on the 0750 isolated agent root). Pull its unit
      # smoke whenever bridge-start.sh moves so a future PR cannot
      # regress the privilege-aware probe back to the plain check.
      # Issue #1047: bridge-agent.sh::run_create is now caller-trust gated
      # (an agent-direct source is denied, mirroring update/delete). Pull
      # its gate smoke whenever bridge-agent.sh or lib/bridge-agent-update.sh
      # moves so a future PR cannot regress the create/update/delete trust
      # symmetry back to an ungated create.
      # Issue #1060: bridge-agent.sh::run_create scaffolds the authored
      # identity into the identity source (layer 2) and runs a
      # materialization step into the engine read target; bridge-start.sh's
      # dry-run now surfaces `agent_home` alongside `workdir`. Pull the
      # three-layer agent-layout smokes whenever bridge-agent.sh or
      # bridge-start.sh moves so a future PR cannot regress the D1
      # scaffold-then-materialize inversion back to the empty-sibling bug.
      # Issues #1115 + #1116: the agent-bridge top-level dispatch + the
      # bridge-agent.sh subcommand surface must stay in lockstep with the
      # operator-facing usage template at scripts/cli-help/agent-bridge-
      # usage.txt and with the `_top_valid` typo-suggestion array. Pull
      # 1115-cli-usage-drift on every dispatcher move so a future PR
      # cannot silently regress the documented surface.
      # Issue #1151: bridge-agent.sh::bridge_ensure_auto_memory_isolation
      # and bridge_ensure_memory_precompact_hook gained the v2-isolation
      # Step-A defer guard. Pull the helper's unit smoke whenever
      # bridge-agent.sh moves so the contract stays pinned alongside the
      # call-site fixes.
      # Issue #1155: bridge-start.sh:481 (Claude) and :534 (Codex) plus
      # bridge-agent.sh:3237 thread the agent id into
      # `bridge_bootstrap_project_skill` so the v2-isolation guard can
      # fire. Pull 1155-bootstrap-skill-guard whenever any of these
      # dispatchers moves so a future PR cannot regress the thread-
      # through (without it the workdir-side mkdir/mv floods operator
      # stdout right before tmux session death — Gate 3 fail).
      # Issue #1165 Track A: bridge-agent.sh's v2 scaffold sudo block
      # (lines around 681-720) now also normalizes the legacy
      # $BRIDGE_AGENT_HOME_ROOT/<agent>/ to 0755 so the legacy-teams-
      # mcp pruner and other inventory scanners can stat into it from
      # any UID on the box (Gap 4). Pull 1165-track-a on every
      # bridge-agent.sh move so the scaffold legacy-root chmod cannot
      # regress back to a missing chmod.
      add_required launch launch-dev-channels-injection tmux-injection upgrade-source-preservation upgrade-shared-settings-propagate agent-create-name-validation agent-create-caller-trust-gate agent-create-idle-timeout 1105-agent-add-audit 1100-audit-since-tz agent-update agent-update-launch-cmd-redaction 1122-admin-auto-caller-source 1136-always-on-no agent-doctor upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering status-engine-detect 835-static-admin-launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup 1028-isolated-workdir-check 1118-v2-engine-binary-path v2-scaffold-home-and-workdir 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair 1067-codex-provisioning 1115-cli-usage-drift 1151-step-a-helper 1155-bootstrap-skill-guard 1158-marker-load-order 1165-track-a-scaffold-modes
      add_integration integration-minimal
      add_live live-tmux-daemon
      ;;

    lib/bridge_iso_paths.py|scripts/lint-raw-pathlib-on-isolated.sh|scripts/baselines/raw-pathlib-baseline.txt)
      # Issue #1175: lib/bridge_iso_paths.py is the canonical
      # implementation of `_safe_path_check`, `_safe_read_env`,
      # `_safe_load_json`, `_isolated_workdir_owner`,
      # `_resolve_isolated_owner_for_path`, `_sudo_run_as` consumed
      # by bridge-setup.py + bridge-hooks.py. Any change to the
      # shared module risks breaking both surfaces simultaneously;
      # pull the consolidated regression smoke + the canonical-shape
      # 1170 smoke + the per-area smokes for both consumers.
      # Issue #1178 (cycle 12 architectural root): the canonical
      # helpers gained a `_sudo_stat_owner` recovery so a
      # PermissionError on lstat()/exists() during the walker is no
      # longer silently swallowed. Pull 1178-helper-contract-daemon-supp
      # on every lib/bridge_iso_paths.py / lint /
      # raw-pathlib-baseline.txt move so the helper contract + lint
      # extension + boomerang test cannot regress.
      add_required 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp 1170-safe-path-check-sudo-escalate 1165-track-a-scaffold-modes 1165-track-c-hooks-and-dispatcher hooks
      add_integration integration-minimal
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
      # Issue #1014 C: the Bash read-intent classifier now treats a
      # neutral prelude stage (cd / test / echo / …) as transparent so a
      # routine `cd … && grep agent-roster.local.sh` read is no longer
      # mis-classified as a write. Cover the classifier regression smoke
      # whenever tool-policy.py moves.
      add_required hooks agent-update v2-cross-class-read admin-hook-exemption tool-policy-roster-read-classify
      add_integration integration-minimal
      ;;

    lib/bridge-isolation*.sh|lib/bridge-migration.sh|bridge-migrate.sh|lib/bridge-marker-bootstrap.sh|lib/bridge-layout-resolver.sh|tests/isolation*)
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
      # PR #897 (v0.13.10 Track A): `bridge_isolation_v2_migrate_apply_for_upgrade`'s
      # markerless-existing-install + no-isolated-roster fast-path lives
      # in lib/bridge-isolation-v2-migrate.sh; pull its regression smoke
      # (T1-T5 marker-write contract + T6 post-marker workdir resolver)
      # for every isolation-lib + bridge-migrate.sh move so the fast-path
      # stays covered.
      # Issue #1010: bridge_isolation_v2_reap_isolated_agent_account
      # (isolated-agent OS-user + traversal-ACE reaper) lives in
      # lib/bridge-isolation-v2.sh; pull its gating-decision smoke for
      # every isolation-lib move.
      # Issue #1121: Step-4 sudoers drop-in cleanup added to the same
      # reaper. Smoke at scripts/smoke/1121-agent-delete-os-purge.sh
      # exercises the path-pattern gate, the BRIDGE_SUDOERS_DIR override,
      # and the best-effort rm failure path. Same file lives in
      # lib/bridge-isolation-v2.sh, so include the gating-decision smoke
      # on every isolation-lib move.
      # Issue #1140: Step-5 (OS home dir) + Step-6 (v2 workdir) reap
      # added to the same reaper. Smoke at
      # scripts/smoke/1140-purge-home-os-cleanup.sh exercises each
      # helper's strict path-pattern gate, the absent-target silent
      # no-op, the empty-`agent_root_v2` legacy short-circuit, and the
      # best-effort rm failure paths. Same file lives in
      # lib/bridge-isolation-v2.sh, so include it on every
      # isolation-lib move.
      # Issue #1021: bridge_isolation_v2_chgrp_setgid_recursive's
      # --exclude-path prune (lib/bridge-isolation-v2.sh) and the
      # reapply caller's shared-plugin fence (lib/bridge-isolation-v2-
      # reapply.sh) keep a per-agent apply from re-grouping shared
      # plugin material; pull its regression smoke for every
      # isolation-lib move.
      # Issue #1025: the isolated-create env-file install asserts the
      # `agent-env-sh` matrix contract (controller:<agent_grp> 0640)
      # defined in lib/bridge-isolation-v2.sh; pull its smoke on every
      # isolation-lib move so a matrix-row change re-checks the writer.
      # Issue #1077: `bridge_isolation_v2_reapply_one_agent` resolves
      # `agent_root` through `bridge_isolation_v2_agent_root` so per-agent
      # grant-matrix rows land on `$BRIDGE_DATA_ROOT/agents/<a>/`, not the
      # tracked profile template at `$BRIDGE_HOME/agents/<a>/`. Pull its
      # regression smoke for every isolation-lib + bridge-migrate.sh move
      # so the dual-tree confusion class stays caught at PR time.
      # Issue #1113: lib/bridge-isolation-v2-workdir-backfill.sh hosts
      # `bridge_isolation_v2_backfill_workdir_identity`, the post-marker
      # back-fill that closes the v0.14.5-beta6 watchdog dual-tree gap
      # for legacy-migrated agents. Pull its regression smoke for every
      # isolation-lib move so the helper's idempotency + operator-edit
      # preservation + roster-scoped enumeration stays covered.
      # Issue #1158: `bridge_isolation_v2_marker_validate` in
      # lib/bridge-marker-bootstrap.sh gained a BRIDGE_CONTROLLER_UID
      # owner-exemption so isolated agents (sudo -u <agent>) can validate
      # controller-owned markers without the mode check loosening. Pull
      # 1158-marker-controller-uid-exemption on every isolation-lib +
      # marker-bootstrap move so the identity-exemption matrix + the
      # intact group/world-write reject stays covered.
      # Issue #1161: the three production layout-marker writers
      # (lib/bridge-isolation-v2-migrate.sh: marker_write +
      # marker_write_minimal; lib/bridge-layout-resolver.sh:
      # bridge_layout_write_v2_marker) chmod the marker file to 0644
      # AND chmod the marker parent dir to 0711 so isolated UIDs can
      # both traverse INTO state/ and `open()` the marker without
      # depending on `ab-shared` group membership. The matrix rows for
      # state-root + state-agents-root in lib/bridge-isolation-v2.sh
      # also moved 0710 → 0711 to match. Pull
      # 1161-marker-readable-by-isolated on every isolation-lib +
      # marker-bootstrap + layout-resolver move so a revert at any
      # site immediately fails the regression contract.
      # r2 (#1162) added `lib/bridge-layout-resolver.sh` to the
      # path-pattern arm above — writer #3 lives there, so a
      # resolver-only regression now selects this smoke through
      # changed-file selection.
      # Issue #1165 Gap 6 (r2 + r3): the linux-user state-agent-dir
      # matrix row in lib/bridge-isolation-v2.sh stays
      # `controller:ab-agent-<X>:2770` for per-agent integrity (r1's
      # widen to `ab-shared` was reverted per codex BLOCKING: any iso
      # UID could touch any other agent's manual-stop / broken-launch
      # marker through the shared group). The Stop-hook failure mode is
      # addressed inside the writer instead — r2 added a sudo-as-iso
      # helper path, and r3 added Path A0 (direct write when effective
      # UID already matches the target os_user, since the generated
      # sudoers rule is controller-scoped and the iso UID cannot sudo
      # back to itself). Pull
      # 1165-track-b-sudo-escalate-and-state on every isolation-lib
      # move so a future revert at any layer (row widening,
      # writer's Path A0 / Path A removal) re-introduces the Stop-hook
      # regression at PR time.
      # Phase 2 (post-v0.14.5-beta16): the new declarative install-tree
      # reconciler lives at lib/bridge-isolation-v2-reconcile.sh and is
      # called from bridge_isolation_v2_migrate_normalize_layout (D2),
      # bridge_linux_prepare_agent_isolation (D4), and the new
      # `agent-bridge isolation reconcile` CLI (D5). The Layer 17
      # marker writer guard `_bridge_marker_writer_is_controller_uid`
      # lives in lib/bridge-marker-bootstrap.sh (D6). Pull the phase2
      # smoke on every isolation-lib + marker-bootstrap move so a
      # regression at any layer (matrix row drift, dispatcher bug,
      # protected-path guard removal, marker-write guard removal) is
      # caught at PR time.
      add_required isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip isolation-v2-marker-only-migrate isolation-v2-macos-noise-suppression isolation-v2-platform-discriminator isolation-v2-bucket2-gates layout-resolver-marker-over-env 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions 1021-isolation-v2-shared-plugin-perms 1025-isolated-create-agent-env-install 1077-migrate-iso-v2-data-dir 1113-watchdog-legacy-backfill 1158-marker-controller-uid-exemption 1158-marker-load-order 1161-marker-readable-by-isolated 1165-track-b-sudo-escalate-and-state launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup phase2-install-tree-reconciler
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
      # Issue #1151: bridge_link_shared_claude_skill +
      # bridge_sync_claude_runtime_skills + bridge_ensure_project_claude_
      # guidance gained the v2-isolation Step-A defer guard. Pull the
      # helper's unit smoke whenever lib/bridge-skills.sh moves so the
      # contract stays pinned alongside the call-site fixes.
      # Issue #1151 r2: 1151-r2-sudo-escalate pins the configured-skills
      # roundtrip + project CLAUDE.md sudo-escalate contracts so the
      # post-Step-A v2 write paths cannot regress to DEFER.
      # Issue #1155: `bridge_bootstrap_project_skill` gained the always-
      # skip-under-v2 guard (beta10 missed the 7th controller-touch
      # site). Pull its unit smoke whenever lib/bridge-skills.sh moves
      # so a future PR cannot drop the optional agent arg + guard.
      add_required isolated-skills-sync isolation launch 1151-step-a-helper 1151-r2-sudo-escalate 1155-bootstrap-skill-guard
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
      # Issue #1165 Track A: lib/bridge-channels.sh's
      # bridge_install_teams_plugin_node_modules now chmod -R go+rX
      # node_modules after bun install so bridge-dev-plugin-cache.py
      # can copy from an isolated UID context (Gap 3). Pull
      # 1165-track-a on every lib/bridge-channels.sh move so the chmod
      # step cannot regress back to controller-only umask.
      # Issue #1165 Gap 6: lib/bridge-channels.sh's
      # `bridge_collect_ready_agents` Stop-hook recovery path calls
      # `bridge_isolation_v2_write_agent_state_marker` for the
      # missing-marker-retries counter; the same state-agent-dir matrix
      # row this smoke pins also governs that writer. Pull
      # 1165-track-b-sudo-escalate-and-state on every channels-lib
      # move so a marker-write regression surfaces here.
      add_required channel-plugins bridge-notify-no-default-discord-875 1165-track-a-scaffold-modes 1165-track-b-sudo-escalate-and-state
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

    scripts/wiki-daily-ingest.sh)
      # Issue #679: wiki-daily-ingest.sh Lane B excludes
      # `*pre-compact-dump*` raw envelopes from the librarian ingest
      # selection. Cover the exclusion regression smoke whenever the
      # ingest orchestrator moves.
      add_required 679-wiki-ingest-exclude-precompact
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
      # #1120 sub-A: `_isolated_workdir_owner` + `_ensure_dir_with_sudo`
      # gained ancestor-walk + sudo-first contract changes that the
      # 1120 smoke pins.
      # #1139 sub-A: `_isolated_workdir_owner` gained uid-first lookup
      # so a workdir owned by `agent-bridge-<slug>:<controller-gid>`
      # (gid != ab-agent-<slug>) no longer falls through to a None
      # return + controller-direct `path.mkdir` PermissionError. The
      # 1139 smoke pins the uid-first contract + the half-scaffolded
      # `partial` downgrade for `bridge_agent_onboarding_state`.
      # Issue #1151: the v2-isolation Step-A defer predicate lifted from
      # `bridge_link_claude_settings_to_shared` (PR #1149) into the shared
      # helper `bridge_agent_workdir_step_a_complete` is exercised by
      # 1151-step-a-helper. Pull it on every bridge-hooks.sh move so the
      # contract the 4 other controller-touch sites depend on (auto-memory
      # isolation, link-shared-claude-skill, sync-claude-runtime-skills,
      # ensure-memory-precompact-hook, ensure-project-claude-guidance) stays
      # pinned.
      # Issue #1175: bridge-hooks.py + bridge-setup.py now share the
      # canonical isolation-aware safe-path helpers in
      # `lib/bridge_iso_paths.py`. Settings render/overlay/symlink
      # probes + workdir/home/skills scans + agent-home enumerator
      # all routed through `_safe_path_check` so v2 isolated trees
      # the controller cannot stat directly no longer crash the
      # rerender / scan flow with PermissionError tracebacks (the
      # PostToolUseFailure flood that drove #1165 Gap 7). Pull
      # 1175-exhaustive-pathlib-audit on every bridge-hooks.py move.
      # Issue #1178 (cycle 12): bridge-hooks.py gained noqa'd mutator
      # sites (cmd_render_isolated_home_settings, _ensure_dir_with_sudo
      # fallback, cmd_link_shared_settings sudo-recovery loop) under
      # the extended lint surface. Pull 1178-helper-contract-daemon-supp
      # so the noqa contract + helper integration cannot regress.
      add_required hooks upgrade-shared-settings-propagate managed-autocompact-window isolated-settings-rendering per-agent-settings-rendering shared-settings-preserve-user-keys admin-hook-exemption 1067-codex-provisioning 1120-controller-ops-isolated 1139-link-shared-settings-perm 1145-ensure-dir-actually-sudo 1145-option1-deferral-guard 1151-step-a-helper 1165-track-c-hooks-and-dispatcher 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp
      add_integration integration-minimal
      ;;

    scripts/migrate-legacy-install.sh|scripts/python-helpers/migrate-legacy-install-helper.py|scripts/python-helpers/migrator-smoke-helpers.py|scripts/python-helpers/migrate-layout-shim.sh|scripts/smoke/legacy-install-migrator.sh|scripts/smoke/1087-migrator-apply-contract.sh)
      # clean-cut wave beta6: standalone legacy-install migrator (export/plan/apply/verify).
      # The migrator and its smoke are independent of the upgrade path; pull only
      # the migration smokes + queue baseline so a change here doesn't rerun the
      # full upgrade matrix unnecessarily.
      # Issue #1087 (beta7): apply contract gaps closed — add the dedicated
      # apply-contract smoke and the new layout shim to the path-trigger set.
      add_required legacy-install-migrator 1087-migrator-apply-contract queue
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
      # PR #897 (v0.13.10 Track A): bridge-upgrade.sh sets
      # `BRIDGE_UPGRADE_CONTEXT=1` on the isolation-v2 migrate call and
      # propagates it through `bridge_upgrade_with_target_env`'s `env -i`
      # filter; the env var gates the markerless-existing-install
      # marker-only fast-path. Pull the regression smoke (T3 specifically
      # asserts the env-propagation contract — fast-path NOT fired when
      # BRIDGE_UPGRADE_CONTEXT is unset) whenever the upgrade entry moves.
      # Issue #1113: bridge-upgrade.sh gained a post-migrate workdir-
      # identity back-fill step (between iso-v2 migrate and apply-live)
      # that materializes canonical identity markers from the tracked
      # profile tree into the v2 runtime workspace for legacy / marker-
      # only-migrated agents. Pull its regression smoke whenever the
      # upgrade entry moves so the dual-tree gap that #1108/#1109
      # exposed stays closed.
      # Issue #1144: bridge-upgrade.sh captures the pre-apply VERSION
      # into INSTALLED_VERSION (previously assigned only in --check),
      # and keeps the post-task body_file on disk after a successful
      # task create. Pull the regression smoke whenever the upgrade
      # entry moves so neither of those two beta8 regressions can
      # recur.
      # Phase 2 (post-v0.14.5-beta16): bridge-upgrade.sh gained a
      # post-apply-live + pre-agent-restart hook calling
      # `lib/upgrade-helpers/isolation-v2-reconcile.sh` (D3). Pull
      # phase2-install-tree-reconciler whenever the upgrade entry
      # moves so a regression on the reconciler-on-every-upgrade
      # invariant is caught at PR time.
      add_required upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-pair-server-auto-provision telegram-relay-residue-cleanup upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering upgrade-isolated-agent-migrate 864-upgrade-perm-regressions cleanup-payload-empty-stdin-872 isolation-v2-marker-only-migrate 1067-codex-provisioning 1113-watchdog-legacy-backfill 1144-upgrade-complete-task phase2-install-tree-reconciler
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

    bridge-init.sh|lib/bridge-init-codex-pair.sh|lib/bridge-init-default-crons.sh|lib/bridge-host-profile.sh)
      # Issue #1047: bridge-init.sh's fresh-install admin `agent create`
      # runs as a subprocess (no TTY) and must mark itself an
      # operator-trusted caller, or the new create gate would deny the
      # bootstrap. Pull the gate smoke so a future PR cannot drop that
      # trusted-source marker and silently break first install.
      # Issue #1052: lib/bridge-init-codex-pair.sh auto-provisions the
      # `<admin>-dev` codex pair on a server host; the picker-sweep cron
      # (lib/bridge-init-default-crons.sh) targets it, and the host-profile
      # advisory (lib/bridge-host-profile.sh) carries the dev-path manual
      # recipe. Pull admin-pair-server-auto-provision whenever any of the
      # four touches so the server/dev gate matrix stays pinned.
      add_required admin-pair-server-auto-provision agent-create-caller-trust-gate upgrade-shared-settings-propagate managed-autocompact-window per-agent-settings-rendering
      add_integration integration-minimal
      ;;

    bridge-bootstrap.sh|lib/bridge-tmux-ux.sh)
      # Issue #1058: bridge-bootstrap.sh sources lib/bridge-tmux-ux.sh and
      # runs bridge_setup_tmux_ux, which writes an idempotent managed tmux
      # UX block to ~/.tmux.conf. Pull the idempotency / graceful-degradation
      # smoke whenever either file moves so a future PR cannot regress the
      # in-place block replacement or the version/terminfo gating.
      add_required 1058-bootstrap-tmux-ux agent-create-caller-trust-gate
      add_integration integration-minimal
      ;;

    scripts/python-helpers/launch-cmd-*.py)
      # Issue #835 Wave A: launch-cmd Python heredoc bodies were extracted
      # from lib/bridge-state.sh into standalone .py files to dodge the
      # Bash 5.3.9 heredoc_write deadlock on the static admin
      # `bridge_agent_launch_cmd` path. Any modification to these helpers
      # must re-run the Wave C regression smoke that asserts the call
      # returns in <2s.
      # Issue #1023: scripts/python-helpers/launch-cmd-redact.py is the
      # shared secret-redaction surface every `agent update --launch-cmd-*`
      # output path routes through; pull its regression smoke whenever
      # any launch-cmd helper moves.
      add_required 835-static-admin-launch launch launch-dev-channels-injection channel-env-readiness agent-update-launch-cmd-redaction 1118-v2-engine-binary-path
      add_integration integration-minimal
      ;;

    scripts/python-helpers/detect-claude-session-id.py|scripts/python-helpers/resolve-claude-resume-session-id.py)
      # Issue #1015: these helpers resolve the Claude session JSON +
      # transcript roots. They must key off the agent's CLAUDE_CONFIG_DIR
      # (isolation-v2 custom HOME) rather than the daemon process's HOME,
      # otherwise static agents launch a fresh session on every restart.
      # 1015-resume-claude-config-dir pins the config-root resolution
      # (trailing arg > CLAUDE_CONFIG_DIR env > daemon-HOME fallback) and
      # the backward-compatible non-isolated path.
      add_required 1015-resume-claude-config-dir 981-restart-session-resume-snapshot
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

    bridge-watchdog.py)
      # bridge-watchdog.py owns the home-profile-contract check
      # (has_home_profile_contract): the required profile files, the
      # managed CLAUDE.md block, and the onboarding-staleness signal only
      # apply to Claude static agents. A new engine (antigravity, v0.14.5)
      # otherwise falls through to the Claude default and surfaces as a
      # false status=error. Cover the contract truth-table smoke plus the
      # registry-anchoring and stderr-capture regressions whenever the
      # watchdog moves.
      # Issue #1108: the watchdog now routes the per-agent scan target
      # through the registry's `workdir` field on v2 layouts so it stops
      # false-positive-reporting `missing_files: CLAUDE.md, SOUL.md, …`
      # on every cron tick. Pull 1108-watchdog-v2-workdir on every
      # watchdog move so the dual-tree confusion class stays caught.
      add_required watchdog-profile-contract watchdog-registry-anchored watchdog-silence-stderr-capture 1108-watchdog-v2-workdir 1119-watchdog-perm-error 1113-watchdog-legacy-backfill queue
      add_integration integration-minimal
      ;;

    bridge-docs.py)
      # v0.13.6 hotfix track 1: bridge-docs.py owns AGENT_SHARED_LINKS and
      # the shared-doc render dispatch. The admin-protocol-shared-link
      # smoke pins the wire-up that propagates docs/agent-runtime/
      # admin-protocol.md into <bridge_home>/shared/ADMIN-PROTOCOL.md and
      # symlinks it from every agent home. Cover it on every bridge-docs.py
      # move so the dispatch table and link tuple stay in lockstep.
      add_required admin-protocol-shared-link
      # render_shared_common_instructions_md() appends the machine-local
      # COMMON-INSTRUCTIONS.local.md override; pin the no-op-when-absent
      # contract so a bridge-docs.py move can't regress it.
      add_required common-instructions-local-override
      add_integration integration-minimal
      ;;

    lib/agent-cli-helpers/audit-detail-json.py|lib/agent-cli-helpers/agent-update-result-json.py)
      # Issue #1023: these helpers render the `agent update` audit
      # detail and the --json result envelope; both route launch-cmd
      # values through the shared launch-cmd-redact module. Pull the
      # redaction regression smoke whenever either renderer moves.
      # Issue #1105: the same audit-detail-json renderer is now invoked
      # by `agent add` too (via bridge_agent_update_emit_audit); pull
      # its smoke so a future PR cannot regress the create-side row.
      # Issue #1136: both renderers gained an optional `expressed_intent`
      # positional that the audit row + --json envelope surface when
      # the operator passed `--always-on yes|no`. Pull the symmetric
      # smoke so a renderer move cannot regress the new field.
      add_required agent-update agent-update-launch-cmd-redaction 1105-agent-add-audit 1136-always-on-no
      add_integration integration-minimal
      ;;

    lib/bridge-agent-layout.sh|lib/bridge-engine-descriptor.sh|scripts/daily-note-reconcile.py)
      # Issue #1060: the typed agent-layout resolver + minimal engine
      # descriptor + the D4 memory-tooling default. All three feed the
      # three-layer agent-layout model the #1060 D5 smokes pin — run them
      # whenever any of these move so a future PR cannot drift the
      # resolver / descriptor / memory-default out of agreement. (The D3
      # template .md files are dispatched in the pre-docs-return case
      # above.)
      add_required 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair 1067-codex-provisioning v2-scaffold-home-and-workdir agent-doctor
      add_integration integration-minimal
      ;;

    bridge-channels.py|bridge-channels.sh)
      # Issue #1060 (beta5 QA finding #1): bridge-channels.py's
      # remove-webhook-server now catches PermissionError/OSError quietly
      # so `agent create --isolate` no longer dumps a traceback. Cover the
      # channel-plugins regression smoke whenever the channel modules move.
      add_required channel-plugins channel-env-readiness
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
  # Task #4648 carry: BSD mktemp portability is repo-wide regression
  # class coverage (positional `mktemp "...XXXXXX.<ext>"` returns the
  # literal path on macOS BSD). The smoke's M4 grep-lint catches any
  # NEW occurrence across tracked shell files, so any PR — even one
  # that touches a file unrelated to the original sites — fails CI
  # if it reintroduces the bug class. Cheap (single grep + ~4 string
  # checks); always required.
  add_required bsd-mktemp-portability
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
