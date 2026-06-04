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

add_required queue daemon daemon-periodic-token-sync launch launch-dev-channels-injection tmux-injection isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering 1495-settings-invalid-hook-key 1453-channel-sticky-false-inbound isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip isolation-v2-marker-only-migrate isolation-v2-macos-noise-suppression isolation-v2-platform-discriminator isolation-v2-bucket2-gates layout-resolver-marker-over-env bsd-mktemp-portability upgrade-isolated-agent-migrate channel-plugins channel-env-readiness hooks upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-pair-server-auto-provision mattermost-plugin pre-compact-envelope-roundtrip telegram-relay-residue-cleanup agent-create-name-validation agent-create-caller-trust-gate agent-create-idle-timeout 1105-agent-add-audit 1100-audit-since-tz agent-update agent-update-launch-cmd-redaction 1122-admin-auto-caller-source 1136-always-on-no agent-doctor cron-run-artifacts-retention cron-migrate-payloads cron-mutation-audit cron-shell-runner 1114-cli-help-contract upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering 1120-controller-ops-isolated 1139-link-shared-settings-perm 1144-upgrade-complete-task 1145-ensure-dir-actually-sudo 1145-option1-deferral-guard 1151-step-a-helper 1151-r2-sudo-escalate 1155-bootstrap-skill-guard 1158-marker-controller-uid-exemption 1158-marker-load-order 1161-marker-readable-by-isolated 1165-track-a-scaffold-modes 1165-track-b-sudo-escalate-and-state 1165-track-c-hooks-and-dispatcher 1342-write-state-marker-matrix 1170-safe-path-check-sudo-escalate 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp shared-settings-preserve-user-keys status-engine-detect 835-static-admin-launch 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions 1021-isolation-v2-shared-plugin-perms 1025-isolated-create-agent-env-install 1028-isolated-workdir-check 1118-v2-engine-binary-path admin-protocol-shared-link bridge-notify-no-default-discord-875 cleanup-payload-empty-stdin-872 dynamic-agent-shared-mode-workdir v2-scaffold-home-and-workdir 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair agent-env-no-stale-bridge-layout 1015-resume-claude-config-dir 1073-fresh-channel-first-run-seed isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup 1400-purge-home-degrade-no-sudo nudge-task-age-gate 1106-nudge-shell-recheck nudge-redundant-active-agent 1323-nudge-eligibility-recheck-twostage 1199-action-required-claimed-skip tool-policy-roster-read-classify 679-wiki-ingest-exclude-precompact a2a-cross-bridge 1405-handoffd-supervision 1058-bootstrap-tmux-ux legacy-install-migrator 1117-cli-help-universal-gate 1087-migrator-apply-contract 1067-codex-provisioning 1077-migrate-iso-v2-data-dir 1108-watchdog-v2-workdir 1119-watchdog-perm-error 1113-watchdog-legacy-backfill 1115-cli-usage-drift phase2-install-tree-reconciler phase3-agent-home-contract 1201-1202-directory-marketplace-seed 1205-hook-iso-fail-open 1207-stale-supp-groups-allowlist 1208-lock-metadata-normalize 1209-ms365-redirect-resolver 1210-ms365-scope-normalize 1212-bridge-hooks-marketplace 1213-iso-uid-predicate 1214-channel-validator-iso-fallback 1215-ms365-dir-mode beta27-D-inject-timestamp-resolved beta27-E-hook-permission-fail-open-markers G-channel-spec-resolution F-daemon-supp-groups-mock F-daemon-supp-groups-real H-bootstrap-memory-iso-rebuild I-agent-description-roster ζ-1236-plugins-list-marketplaces β-1231-1236-fresh-install-seed-sudoers 6607-hook-admin-allowlist γ-cli-consistency δ-1234-daemon-start-policy B-beta3-1249-1250-plugin-ux C1-beta3-1251-restart-preflight-rollback A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir C-beta4-logger-and-spec B-beta4-setup-wizard A-beta4-iso-path-resolution D-beta4-daemon-lifecycle E-beta4-fresh-install-gate-state-dir H-beta4-iso-ownership F-beta4-oauth-bootstrap G-beta4-watchdog-noise I-beta4-a2a-3-gaps J-beta4-workflow-docs K-beta4-nits Beta-beta5-session-id-detect-sudo α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-1-session-id-detect-race dev-channel-auto-accept-no-attach mcp-liveness-giveup-auto-clear beta5-2-epsilon-tmux-inject-busy beta5-2-zeta-teams-mcp-dedup beta5-2-pi-daemon-crashloop-no-set-e-leak beta5-2-eta-cron-iso-uid-preflight beta5-2-delta-nudge-session-empty beta5-2-theta-upgrade-backfill-perms beta5-2-nu-daemon-path-quarantine beta5-2-kappa-state-audit-reconcile beta5-2-iota-daemon-escalation-family beta5-2-lambda-a2a-robustness beta5-2-mu-cron-channel-creds beta5-2-xi-misc-fixes 1359-cron-create-iso-staging 1379-iso-cron-staging-group 1383-iso-cron-result-json-group 1354-setup-teams-fd-password 1360-onboarding-next-actions-persona 1353-setup-pending-grace 1355-1356-ms365-wizard 1357-iso-boundary-quickref 1358-admin-credential-routine-exempt 1352-shared-codex-pair-path 1343-ms365-token-refresh 1378-iso-session-lock-fresh-start 1388-daemon-lock-fd-cloexec 1416-onboarding-state-field-anchor a2a-setup-wizard 1408-daemon-alert-nudge-hygiene 1409-claude-midturn-busy-gate 1427-A-roster-materialize 1427-B-template-sync-wizard 1426-cron-shell-noniso-help 1437-reactive-cron-rotation 1425-spool-rederive 1437-native-usage-probe 1468-usage-429-positive-signal 1464-cron-aware-stale-health 1497-v2-dynamic-handoff 1497-p1-home-resolver 1506-isolate-normalize 1497-p2-operator-home 1513-iso-teams-prune-eacces 1516-upgrade-downgrade-guard plugin-requires-resolver 1520-shared-claude-config-dir 1520b-create-time-creds-sync 1520c-create-isolate-profile-publish 1402-stat-platform-order 1398-a2a-inbound-stopped-target-force
add_required 1425-cron-dispatch-nudge-scope
# Issue #1461: BRIDGE_CRON_DISPATCH_MAX_PARALLEL must resolve env > runtime
# bridge-config.json key > host-profile-scaled default, and the resolved value
# must reach start_cron_dispatch_workers' worker-slot gate. In the static suite
# (and pulled per-file below on bridge-lib.sh / bridge-daemon.sh moves) so a
# revert to the hardcoded serial `:-1` default is caught.
add_required 1461-cron-max-parallel-override
add_required 1936-forward-followup-attached-escalation
add_required 1473-agent-list-iso-state-fallback
# Issue #1474 (v0.15.3 wrapper-path regression): bridge_load_roster must EXPORT
# the resolved BRIDGE_ADMIN_AGENT_ID so the admin cross-agent cron exemption
# survives `exec` into the bridge-cron.sh child via the agent-bridge/agb wrapper
# — without weakening the #1359 iso/non-admin reject.
add_required 1474-wrapper-admin-cron-exemption
# #1454: security canary for the bridge-lib.sh Bash-3.2→4+ re-exec — the
# ambient-secret exposure window (exported-function / PATH-shadow / BASH_ENV
# during the re-exec). In the static suite so any bridge-lib.sh /
# lib/bridge-secret-scrub.sh / scripts/smoke/* change re-runs it; the per-file
# cases below also pull it directly.
add_required 1454-bridge-lib-reexec-secret-canary
# #8945 Track B: expanded Codex hook coverage (PreCompact / PostCompact /
# SubagentStart / SubagentStop / PermissionRequest). All audit-only by default;
# the permission-request smoke pins the security contract.
add_required codex-precompact-hook codex-postcompact-hook codex-subagent-hooks codex-permission-request-hook
# Incident #8807 P1: in the full static suite so a change to the coalesce smoke
# helper (scripts/smoke/8807-cron-backfill-coalesce-helper.py) — which hits the
# scripts/smoke/* catch-all → add_all_required_static — still re-runs the
# coalesce smoke.
add_required 8807-cron-backfill-coalesce
# Incident #8807 P0b: in the full static suite so a change to the reaper helper
# (scripts/smoke/8807-mcp-reaper-patterns-helper.py) — which hits the
# scripts/smoke/* catch-all → add_all_required_static — still re-runs the
# reaper-pattern smoke.
add_required 8807-mcp-reaper-patterns
# #8945 Track A: the engine-aware urgent-nudge-body smoke. In the full static
# suite so a scripts/smoke/* or lib/bridge-agents.sh change re-runs it via the
# catch-all. (1067-codex-provisioning is already listed above.)
add_required codex-nudge-body
# #8945 Track D: availability-gated `codex doctor` smoke (graceful SKIP when
# codex is absent — the CI default — so a codex-less host is never a false
# release blocker) + the bridge-upgrade.sh codex-version advisory surface.
# In the full static suite so a scripts/smoke/*, bridge-watchdog.py, or
# bridge-upgrade.sh change re-runs them via the catch-all / default arm.
add_required codex-doctor codex-version-surface
# #8945 Track C: agent-scoped Codex slash-command + permission-profile
# provisioning. In the full static suite so a scripts/smoke/*, lib/bridge-
# agents.sh, bridge-agent.sh, or assets/codex/* change re-runs them via the
# catch-all / arm-specific selection below.
add_required codex-slash-commands codex-permission-profiles
# Issue #1492: bridge_agent_workdir now aligns the documented `<admin>-dev`
# codex pair's RESOLVED workspace to the admin's effective v2 workdir
# (`<admin>/workdir`) instead of leaving it drifted at the admin's old/base
# shared cwd, while keeping the pair's identity/home/hooks distinct. In the
# full static suite so a scripts/smoke/* or lib/bridge-agents.sh change
# re-runs it via the catch-all → add_all_required_static (the
# lib/bridge-agents.sh, bridge-init-codex-pair.sh, and bridge-init.sh
# selectors below also reach it transitively via the static catch-all).
add_required 1492-admin-dev-pair-workspace-v2
# A2A rooms P1a: the single-node rooms control plane + the FROZEN schema /
# envelope / receiver-seam contract (bridge_rooms_common.py, bridge-rooms.py,
# the room_scoped_check seam in bridge-handoffd.py, the optional room_id/
# room_epoch envelope fields in bridge_a2a_common.py). In the full static
# suite so a scripts/smoke/*, bridge_rooms_common.py, bridge-rooms.py,
# bridge-handoffd.py, bridge_a2a_common.py, or agent-bridge dispatcher change
# re-runs it via the catch-all / per-file arms below. Pins the lifecycle +
# epoch + leader-auth + token-hash + rotate/--once + adopt-all + envelope
# back-compat + receiver fail-closed teeth, and the rooms.db 0600 hygiene.
add_required a2a-rooms-p1a
# A2A rooms P1b: the internal-queue ACL ENFORCEMENT (design §14 R1). Gates an
# inter-agent durable create on shared-room membership when rooms_acl=enforce,
# using the OS-enforced sender (gateway SO_PEERCRED / resolve_os_actor), with a
# default-off no-op. Lives in bridge_rooms_common.py (acl_create_decision),
# bridge-queue-gateway.py (the primary iso gate), bridge-queue.py cmd_create
# (defense-in-depth + non-gateway paths), and bridge-rooms.py (the controller-
# gated acl flip). Pins the default-off no-op, same-room ALLOW, cross-room DENY,
# the --from SPOOF rejection (both paths), fail-closed, controller exemption,
# shared-mode advisory, and adopt-all->enforce strands-nobody teeth.
add_required a2a-rooms-p1b-acl
# A2A rooms #1517: the controller-only auto-bootstrap of the canonical rooms.db
# on the first room mutation (create/adopt-all) on a fresh iso host. Without it
# the controller's first `agb room create` fails closed (actor_unresolved) — no
# rooms.db exists, so the controller anchor (_controller_uid = stat(rooms.db)
# .st_uid) cannot anchor. Lives in bridge_rooms_common.py (maybe_bootstrap_
# rooms_db / canonical_rooms_db_path / _caller_owns_canonical_controller_
# location) + bridge-rooms.py (the create/adopt-all call site). Pins the
# bootstrap PASS (controller seeds a 0600 controller-owned canonical db), the
# P1b teeth (a managed non-controller agent cannot self-bootstrap to become
# controller), the env-redirect teeth (BRIDGE_A2A_ROOMS_DB does NOT relocate
# the bootstrap), and idempotency (a 2nd create does not re-bootstrap/clobber).
add_required a2a-rooms-1517-bootstrap


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
    agents/_template/codex/AGENTS.md)
      # #8945 Track A: the dedicated Codex entrypoint template carries the
      # explicit Task Processing Protocol that bridge_scaffold_codex_entrypoint
      # renders into a Codex agent's AGENTS.md (the Claude CLAUDE.md leaves the
      # protocol implicit — the #8945 wedge). It is a .md file, so the
      # is_docs_only_path early-return below would otherwise select only the
      # global required smokes. This case precedes that return so a drift in the
      # protocol marker, the managed-marker comment, or the placeholder set
      # still pulls the codex-provisioning smoke (which asserts the rendered
      # AGENTS.md contains the protocol + the agb-done close step).
      add_required 1067-codex-provisioning
      ;;
    assets/codex/prompts/*|assets/codex/profiles/*)
      # #8945 Track C: the agent-scoped Codex slash-command prompt templates and
      # the bridge-role permission profiles (real <role>.config.toml files that
      # `codex -p bridge-<role>` layers). bridge_ensure_codex_agent_slash_commands
      # renders these into <agent_home>/.codex/ (never the controller ~/.codex).
      # The prompt files are .md and the profiles are non-.sh, so the
      # is_docs_only_path early-return below would otherwise select only the
      # global required smokes. This pre-case lifts ahead of the short-circuit so
      # a drift in the managed marker, an agb verb/flag, the <agent-id>/<agent-
      # home>/<bridge-home> placeholder set, a sandbox_mode, or a role-profile
      # filename still pulls the Track C smokes (which assert the rendered assets
      # land agent-scoped, carry valid agb verbs + real loadable config profiles,
      # are idempotent, and never touch the controller ~/.codex).
      add_required codex-slash-commands codex-permission-profiles
      ;;
    agent-roster.local.example.sh)
      # v0.15.0-beta1 Lane I: the example roster is operator-facing copy.
      # An edit here (recommended BRIDGE_AGENT_DESC one-liners, admin
      # class examples) should still pull the Lane I smoke so the
      # convention's expected shape — non-empty default desc, list/show
      # carry the string, describe getter resolves it — cannot regress.
      # The file is .sh, not .md, so is_docs_only_path wouldn't elide
      # it anyway, but this explicit pre-case keeps the smoke gate
      # consistent if the trigger ever flips into the docs path.
      add_required I-agent-description-roster
      ;;
    CLAUDE.md)
      # v0.15.0-beta5-2 Lane E (#1357): the project-root CLAUDE.md carries
      # the long-form "Agent's own POV: what blocks where + workaround"
      # sub-section that the `agb agent show` iso_boundary_quickref:
      # block mirrors in compressed form. The contract spans docs + code
      # — pull the 1357 smoke when either side moves so the table header,
      # the verbatim 'body_file direct read' row name, and the parent
      # header anchor stay in lockstep. The file is .md, so the
      # is_docs_only_path early-return below would otherwise select only
      # the global required smokes; this pre-case lifts it ahead of the
      # short-circuit.
      add_required 1357-iso-boundary-quickref
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
      add_required 1114-cli-help-contract 1117-cli-help-universal-gate β-1231-1236-fresh-install-seed-sudoers
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
      # Issue #1427 Lane A: bridge-agent.sh hosts the template-sync
      # Contract-II `roster materialize-fields` writer + the gated
      # `roster write-template-profile` verb + the `agent create`
      # defaults-profile consumption. Pull the roster-materialize smoke on
      # every bridge-agent.sh move so a refactor cannot regress the
      # roster-only write, the legacy-refusal, the caller-source gate, or
      # the create-time materialization.
      if [[ "$path" == "bridge-agent.sh" ]]; then
        add_required 1427-A-roster-materialize 1427-B-template-sync-wizard
        # Issue #1473: bridge-agent.sh hosts bridge_agent_activity_state,
        # which gained the iso-UID aggregate fallback so the human-facing
        # state token agrees with the active column from a non-controller
        # UID. Pull the smoke on every bridge-agent.sh move.
        add_required 1473-agent-list-iso-state-fallback
        # PR-B / #1520b: bridge-agent.sh's run_create writes the credential-
        # pending hold marker MANDATORILY before the roster commit (and the
        # best-effort create-time seed after isolation-prep), and run_delete /
        # run_retire / create-rollback clear it. Pull the smoke on every
        # bridge-agent.sh move so a refactor cannot reopen the daemon race by
        # reordering the marker write past bridge_write_role_block, dropping a
        # clear site, or letting a seed failure roll back create.
        add_required 1520b-create-time-creds-sync
      fi
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
      # Issue #1378: lib/bridge-state.sh hosts bridge_agent_session_lock_file,
      # which must anchor the per-agent session.lock on the controller-owned
      # state leaf (state/agents/<a>/) and NOT on the iso data tree
      # (data/agents/<a>/runtime/) — otherwise a fresh iso v2 agent fails to
      # start with `session.lock: Permission denied` (controller stale-group,
      # #1025 class). Pull the smoke on every bridge-state.sh move so a
      # future refactor cannot silently revert the lock anchor.
      if [[ "$path" == "lib/bridge-state.sh" ]]; then
        add_required 1378-iso-session-lock-fresh-start
        # Issue #1473: lib/bridge-state.sh hosts the all-agent state
        # aggregate writer (bridge_write_agents_aggregate_state) + the
        # read-side helpers (should_consult / lookup) that
        # bridge_agent_is_active + bridge_agent_activity_state fall back to
        # from an iso UID. Pull the smoke on every state-lib move so a
        # refactor cannot regress the 0644 publish, the all-agents-listed
        # invariant, the no-secret column boundary, or the controller
        # no-regression gate.
        add_required 1473-agent-list-iso-state-fallback
        # Issue #1474 (v0.15.3 wrapper-path regression): lib/bridge-state.sh's
        # bridge_load_roster now EXPORTs BRIDGE_ADMIN_AGENT_ID so the resolved
        # admin id survives `exec` into the bridge-cron.sh child spawned by the
        # agent-bridge/agb wrapper — that is what lets the #1474 admin
        # cross-agent cron exemption pass on the wrapper path (it already
        # worked on a DIRECT bridge-cron.sh call). Pull the smoke on every
        # bridge-state.sh move so a refactor cannot silently drop the export
        # (which would re-break the wrapper path) OR start leaking a non-admin
        # agent's BRIDGE_AGENT_ID==admin (which would weaken the #1359 gate).
        add_required 1474-wrapper-admin-cron-exemption
        # PR-B / #1520b: lib/bridge-state.sh hosts the credential-pending
        # marker helpers (bridge_agent_credential_pending_file / _mark /
        # _active / _clear) that the create-flow hold + the daemon autostart
        # gate depend on. Pull the smoke on every bridge-state.sh move so a
        # refactor cannot rename/drop a helper or change the marker leaf path.
        add_required 1520b-create-time-creds-sync
        # Issue #1402: lib/bridge-state.sh's _bridge_rewrite_session_id_in_file
        # reads the file mode with the canonical GNU-first
        # `stat -c '%a' || stat -f '%Lp'` order before chmod'ing the rewritten
        # inode. A BSD-first order emits a statvfs blob on GNU/Linux and
        # corrupts the preserved mode. Pull the smoke on every bridge-state.sh
        # move so a refactor cannot silently revert to the wrong-order class.
        add_required 1402-stat-platform-order
      fi
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

    scripts/audit/iso-v2-ownership-audit.sh)
      # v0.15.0-beta4 Lane H (#1278): the iso v2 ownership audit
      # subject. The H-beta4 smoke pins its existence + contract; pull
      # the smoke when the audit changes so a refactor cannot drift the
      # smoke's reference assumptions (paths checked, ownership contract,
      # exit codes) out of sync.
      add_required H-beta4-iso-ownership
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
      #
      # v0.15.0-beta1 Lane I: the template now advertises
      # `agent describe <agent>`. Pull I-agent-description-roster on
      # every template edit so the row + dispatcher arm cannot drift.
      #
      # A2A rooms P1a: the template now advertises `room <create|...>`. Pull
      # a2a-rooms-p1a on every template edit so the `room` row + its
      # dispatcher arm (the `room)` case in agent-bridge) cannot drift apart.
      add_required 1115-cli-usage-drift 1117-cli-help-universal-gate I-agent-description-roster a2a-rooms-p1a a2a-rooms-p1b-acl
      ;;

    bridge-setup.py|bridge-setup.sh|bridge-status.py|bridge-status.sh|lib/bridge-setup-wizard.sh)
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
      # Issue #1215 (beta26): bridge-setup.py channel-dir mkdir call
      # sites now pass an explicit `mode=0o2770` to
      # `_isolation_aware_mkdir` (discord/telegram/teams/mattermost).
      # The 1215 smoke pins both the per-call-site mode (so a future
      # patch can't silently revert to the helper's legacy 0o2750
      # default) AND the plugins/ms365/teams server.ts STATE_DIR
      # mode + chmodSync self-heal contract. Behavioural tests skip
      # on macOS unless BRIDGE_TEST_LINUX_ROOT=1.
      # Issue #1209 (beta27): bridge-setup.py adds the `cmd_ms365`
      # wizard + `inspect_ms365_dir` + `derive_ms365_redirect_uri`
      # helpers, and bridge-setup.sh adds the `ms365` subcommand
      # dispatch + `run_ms365`. The 1209 smoke pins the wizard's
      # derive-from-messaging-endpoint behavior, the
      # `MS365_REDIRECT_URI` persistence to `.ms365/.env`, the file
      # mode (0600) regression check, and the runtime fail-loud
      # `resolveRedirectUri()` contract in plugins/ms365/server.ts.
      # Issue #1221 (v0.15.0 Lane G): bridge-setup.sh's per-channel
      # helpers (`bridge_setup_add_agent_channel`,
      # `bridge_setup_replace_agent_telegram_channel`,
      # `bridge_setup_ensure_development_channels_launch_flag`) all
      # route channel-spec tokens through `bridge_qualify_channel_item`.
      # The G smoke pins the canonical built-in plugin → marketplace
      # mapping (teams/ms365/mattermost → @agent-bridge; discord/telegram
      # → @claude-plugins-official; explicit suffixes preserved verbatim)
      # so a future bridge-setup.sh change cannot regress an un-suffixed
      # `plugin:<name>` past the bridge-owned plugin-manifest gate.
      # Issues #1268 + #1271 (v0.15.0-beta4 Lane B): bridge-setup.sh's
      # `run_teams` / `run_ms365` invoke `bridge_setup_wizard_validate_auto`
      # (auto mode) and `bridge_setup_wizard_run_teams|ms365` +
      # `bridge_setup_wizard_post_summary_*` (interactive TTY) from
      # `lib/bridge-setup-wizard.sh`. The B-beta4 smoke pins:
      #   - the canonical required-field list per channel (teams: app-id,
      #     app-password-file, tenant-id, allow-from, messaging-endpoint,
      #     webhook-host, webhook-port; ms365: client-id,
      #     client-secret-file, tenant-id, redirect-uri, default-scopes)
      #   - auto-mode fail-loud with the enumerated missing list (vs the
      #     legacy 2-flag check)
      #   - the post-summary printer surface that names the Azure portal
      #     manual-action steps after the python wizard returns
      # Pull on every move so a future patch cannot silently collapse
      # the wizard back to the silent-fail OOTB shape #1268 reproduced.
      # Issue #1278 (v0.15.0-beta4 Lane H): the bridge-setup.py mkdir of
      # `.ms365/` is the entry surface for the iso v2 ownership audit
      # family — when `.ms365` drops mode 0o2770, the iso UID's
      # subsequent `.env` reads EACCES on the parent. The H-beta4 smoke
      # pins both the `.ms365` mode 0o2770 contract (#1215 cross-check)
      # and the canonical iso v2 ownership pattern on
      # `known_marketplaces.json` (#1278) + `*.lock` (#1208). Pull on
      # every bridge-setup.py / bridge-setup.sh / wizard move so a
      # future refactor cannot silently regress the audit family.
      add_required queue upgrade-conflicts-lifecycle status-engine-detect 835-static-admin-launch 1155-bootstrap-skill-guard 1165-track-a-scaffold-modes 1170-safe-path-check-sudo-escalate 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp 1209-ms365-redirect-resolver 1215-ms365-dir-mode G-channel-spec-resolution γ-cli-consistency B-beta4-setup-wizard H-beta4-iso-ownership
      # Issue #1405 (v0.15.0 self-heal stack): bridge-status.py gained
      # read_handoffd_health + the A2A receiver health row + the
      # `a2a=DOWN`/`a2a=ALARM` header flag (text + JSON dashboards). Pull
      # 1405-handoffd-supervision on every bridge-status.py / bridge-status.sh
      # move so the row (rendered only on A2A-configured installs, silent
      # otherwise) cannot regress.
      add_required 1405-handoffd-supervision
      # Issue #1354 (v0.15.0-beta5-2 Track B): bridge-setup.py's
      # `read_secret_value` ingests `--app-password-file` / `--client-secret-file`
      # via try-open-and-read so `/dev/fd/N` (Bash process substitution
      # `<(...)`), named pipes, and character/socket specials work. Also
      # adds `--app-password-stdin` / `--client-secret-stdin` first-class
      # flags. Pull 1354-setup-teams-fd-password on every bridge-setup.py
      # / bridge-setup.sh / wizard move so a future PR cannot silently
      # re-introduce the `Path.is_file()` gate that broke the documented
      # process-substitution shape in the patch reproducer.
      add_required 1354-setup-teams-fd-password
      # v0.15.0-beta5-2 Lane κ (#1319 H1): bridge-status.py's `state`
      # column width must accommodate the new `picker_blocked` value
      # (14 chars). Pull beta5-2-kappa-state-audit-reconcile on every
      # bridge-status.py move so a future PR cannot silently shrink the
      # column back to 8 chars and clip `picker_blocked` to `picker_b`.
      add_required beta5-2-kappa-state-audit-reconcile
      # Issue #1464 (PR #1465): bridge-status.py's classify_agent_stale now
      # gates the cron-activity health signal on the owning job's CADENCE
      # (cron_schedule_cadence_seconds + cron_in_cadence) instead of the
      # blanket "any recent cron run -> ok" that masked overdue jobs. Pull
      # 1464-cron-aware-stale-health on every bridge-status.py move so a future
      # PR cannot silently revert the cadence gate back to the false-healthy
      # masking (an hourly job 35h overdue reading ok).
      add_required 1464-cron-aware-stale-health
      # Issue #1329 (v0.15.0-beta5-2 Lane μ M6): bridge-setup.py's five
      # channel handlers (cmd_discord / cmd_telegram / cmd_teams /
      # cmd_ms365 / cmd_mattermost) now call
      # `_post_write_normalize_channel_cred_group(...)` after the
      # `_isolation_aware_save_*` writes so a controller-fallback write
      # (no iso owner resolvable) lands at `controller:ab-agent-<a> 0640`
      # instead of `controller-primary-group 0600`. The smoke pins the
      # presence of the call in each handler. Pull on every
      # bridge-setup.py move so a future PR cannot silently drop the
      # post-write hook from any single handler.
      add_required queue upgrade-conflicts-lifecycle status-engine-detect 835-static-admin-launch 1155-bootstrap-skill-guard 1165-track-a-scaffold-modes 1170-safe-path-check-sudo-escalate 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp 1209-ms365-redirect-resolver 1215-ms365-dir-mode G-channel-spec-resolution γ-cli-consistency B-beta4-setup-wizard H-beta4-iso-ownership beta5-2-mu-cron-channel-creds 1354-setup-teams-fd-password
      add_required queue upgrade-conflicts-lifecycle status-engine-detect 835-static-admin-launch 1155-bootstrap-skill-guard 1165-track-a-scaffold-modes 1170-safe-path-check-sudo-escalate 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp 1209-ms365-redirect-resolver 1215-ms365-dir-mode G-channel-spec-resolution γ-cli-consistency B-beta4-setup-wizard H-beta4-iso-ownership beta5-2-mu-cron-channel-creds
      # Issue #1353 (v0.15.0-beta5-2 Track A): bridge-setup.sh's
      # `run_discord` / `run_telegram` / `run_teams` / `run_ms365`
      # each touch the setup-pending grace marker on entry (extends
      # grace) and clear it on completion (marks setup as done). The
      # 1353-setup-pending-grace smoke registers >=4 mark/clear sites
      # in bridge-setup.sh — pull on every bridge-setup.sh move so a
      # future refactor cannot drop one of the four verbs from the
      # mark/clear contract.
      add_required 1353-setup-pending-grace
      # Issues #1355 + #1356 (v0.15.0-beta5-2 followup): bridge-setup.py's
      # cmd_ms365 now (a) falls back to MS365_CONVENTION_DEFAULT_SCOPES
      # when no --default-scopes flag/existing value is present (#1355
      # protocol-convention default), surfacing the choice via
      # `default_scopes_source: convention-default|flag|existing`; and
      # (b) probes the Entra app registration's `web.redirectUris` via
      # Microsoft Graph before writing `.ms365/.env`, fail-loud aborting
      # on a verified non-match (#1356 root) and gracefully annotating
      # `redirect_uri_check: skipped` for missing-creds / 403 /
      # unreachable / --skip-entra-probe paths. lib/bridge-setup-wizard.sh
      # removed `default-scopes` from `_BRIDGE_SETUP_WIZARD_REQUIRED_MS365`
      # to match (#1355). Pull on every bridge-setup.py /
      # bridge-setup.sh / lib/bridge-setup-wizard.sh move so the
      # convention-default constant + probe wiring + required-fields
      # list cannot silently regress.
      add_required queue upgrade-conflicts-lifecycle status-engine-detect 835-static-admin-launch 1155-bootstrap-skill-guard 1165-track-a-scaffold-modes 1170-safe-path-check-sudo-escalate 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp 1209-ms365-redirect-resolver 1215-ms365-dir-mode 1355-1356-ms365-wizard G-channel-spec-resolution γ-cli-consistency B-beta4-setup-wizard H-beta4-iso-ownership beta5-2-mu-cron-channel-creds
      # Issue #1427 Lane B: bridge-setup.py hosts the `setup template-sync`
      # wizard (cmd_template_sync), the gated profile-writer routing
      # (_template_sync_profile_writer_cmd → cmd_template_profile_write),
      # the Contract-II materialize-cmd resolution, and the backfill
      # non-zero-exit propagation. lib/bridge-setup-wizard.sh hosts the
      # template-sync required-field validator. Pull 1427-B on every
      # bridge-setup.py / bridge-setup.sh / wizard move so a refactor
      # cannot regress the canonical writer path, the gate, the metadata
      # contract, or the backfill-failure exit code.
      add_required 1427-B-template-sync-wizard
      add_integration integration-minimal
      ;;

    plugins/teams/dedupe.ts)
      # Issue #1313 (beta5-2 Lane ζ): the createRecentMessageDeduper /
      # storedRowMatchesIncoming helpers gate the in-memory + log-replay
      # dedup that the Lane ζ fix relies on for safe MCP-failure retry.
      # A change to either helper must re-run the dedup-on-failure smoke
      # so the regression detector (no `recentMessageIds.forget(...)` on
      # the catch path) can flag a silent re-introduction.
      add_required beta5-2-zeta-teams-mcp-dedup
      add_integration integration-minimal
      ;;

    plugins/ms365/server.ts|plugins/teams/server.ts)
      # Issue #1215 (beta26): plugins/ms365/server.ts:ensureDirs and
      # plugins/teams/server.ts:ensureStateDir now mkdirSync STATE_DIR
      # at mode 0o770 followed by an explicit `chmodSync(STATE_DIR,
      # 0o2770)` self-heal so the v2 isolation `ab-agent-<slug>`
      # group can traverse the per-agent `.ms365/` / `.teams/`
      # parents. tokens/pending stay 0o700; secret files stay 0o600.
      # The 1215 smoke pins both the source-level pattern and the
      # behavioural self-heal (Linux only / BRIDGE_TEST_LINUX_ROOT=1
      # on mac).
      # Issue #1209 (beta27): plugins/ms365/server.ts replaces the
      # silent `http://localhost:3978/auth/callback` fallback with a
      # fail-loud `resolveRedirectUri()` invoked at pair_start time.
      # The 1209 smoke pins the resolver priority table (unset →
      # throw, explicit https → return, localhost without ALLOW →
      # throw, localhost + ALLOW=1 → return) and verifies the
      # bridge-setup.py ms365 wizard derives the URL from a Teams
      # messaging endpoint.
      # Issue #1210 (beta27): plugins/ms365/server.ts now normalizes
      # the scope string (strip outer quotes, collapse whitespace)
      # before passing to URLSearchParams, fixing AADSTS70011
      # "scope is not valid" when operator .env had quoted scope
      # values like `MS365_DEFAULT_SCOPES="openid ..."`. The 1210
      # smoke pins normalizeScopes round-tripping through the full
      # authorize_url builder with no stray quotes / %22.
      # Issue #1313 (beta5-2 Lane ζ): plugins/teams/server.ts catch
      # block no longer drops the in-memory dedup entry on MCP
      # notification failure; deliverMcpNotificationWithRetry +
      # emitMcpDeliveryFailurePermanent provide bounded retry-with-
      # backoff and a structured audit row on permanent failure.
      # Pull beta5-2-zeta-teams-mcp-dedup on every teams/server.ts
      # touch so the symptom-cover line cannot silently come back.
      # Issue #1330 M7 (beta5-2 Lane ξ): plugins/teams/server.ts now emits
      # a startup warning when BRIDGE_AGENT_ID is empty (the activity-
      # index write would otherwise silently skip → PreCompact channel-
      # route lookup misses → channel dispatch fails). Pull
      # beta5-2-xi-misc-fixes on every teams/server.ts touch so the
      # startup-warning guard cannot silently come back as a silent
      # skip.
      # Issue #1354 R2 (codex r1 SHOULD-FIX): the teams/ms365 plugin
      # servers consume the credentials that the setup wizard plants in
      # `.teams/.env` / `.ms365/.env`. A future change to either server
      # that loosens credential parsing could mask a regression in the
      # wizard's FD/stdin ingestion path (#1354). Pull
      # 1354-setup-teams-fd-password on every plugins/teams/server.ts or
      # plugins/ms365/server.ts touch so the wizard's secret-ingestion
      # contract stays exercised end-to-end.
      add_required 1209-ms365-redirect-resolver 1210-ms365-scope-normalize 1215-ms365-dir-mode beta5-2-zeta-teams-mcp-dedup beta5-2-xi-misc-fixes 1354-setup-teams-fd-password
      # Issues #1355 + #1356 (v0.15.0-beta5-2 followup): plugins/ms365/server.ts
      # is not directly touched, but the convention-default scope set
      # in bridge-setup.py is the value persisted to MS365_DEFAULT_SCOPES
      # which server.ts reads at boot. A future patch that re-shapes the
      # plugin's DEFAULT_SCOPES baseline must also re-check the wizard's
      # convention default (cross-validated by 1355-1356-ms365-wizard T1).
      add_required 1209-ms365-redirect-resolver 1210-ms365-scope-normalize 1215-ms365-dir-mode 1355-1356-ms365-wizard beta5-2-zeta-teams-mcp-dedup beta5-2-xi-misc-fixes
      # Issue #1343 (beta5-3 Track M): plugins/ms365/server.ts now
      # auto-refreshes the access_token on/near expiry using the stored
      # refresh_token, with single-flight (no double-grant race),
      # transient-vs-permanent classification (keep-and-retry vs
      # token_expired + re-auth), and redacted ms365_token_refreshed /
      # ms365_refresh_failed audit rows. The 1343 smoke pins the wiring
      # (source) + the runtime behavior (refresh-on-expiry, preemptive
      # near-expiry refresh, graceful 90-day expiry, single-flight, no
      # raw-token leak, 0600 token-file mode, malformed-response deep-redact).
      # Pull on every ms365/server.ts move so a future refactor cannot
      # silently drop auto-refresh back to the 1-hour-outage state.
      add_required 1209-ms365-redirect-resolver 1210-ms365-scope-normalize 1215-ms365-dir-mode 1343-ms365-token-refresh beta5-2-zeta-teams-mcp-dedup beta5-2-xi-misc-fixes
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
      #
      # v0.15.0-beta4 Lane J (#1280): bridge-queue.py's
      # `stabilize_body_file` now falls back to `sudo -n -u <owner> cat
      # <path>` when the direct read raises PermissionError (iso UID-
      # owned body file at mode 0660). J-beta4-workflow-docs (T1/T2)
      # pins the helper behavior + the structured SystemExit failure
      # surface; pull on every bridge-queue.py move so the fallback
      # cannot regress to silent empty-body sends.
      # v0.15.0-beta4 Lane K (#1253): bridge-queue.py + bridge-task.sh now
      # accept `claim --note <text>` / `--note-file <path>` symmetric with
      # `done` / `update`. The note text propagates into the task_events
      # row (`event_type=claimed`, `note_text=<text>`). Pull K-beta4-nits
      # whenever either file moves so a future PR cannot silently regress
      # the symmetry back to the asymmetric pre-#1253 shape.
      # v0.15.0-beta5-2 Lane δ (#1311): bridge-queue.py / bridge-task.sh
      # produce the nudge candidate rows the daemon consumes; the
      # beta5-2-delta smoke pins the defer-and-escalate path that
      # replaced the silent soft-skip when those rows surface an empty
      # session field. Pull on every queue or task surface move so a
      # future PR cannot regress the audit-row contract that downstream
      # operator triage depends on.
      # v0.15.0-beta5-2 Lane κ r2 (#1345): bridge-queue.py daemon-step
      # now excludes `picker_blocked` / `working` activity_state values
      # from the idle_agents set used by stale-claim requeue. The Lane
      # κ smoke (T8/T9/T10) pins both the python-side exclusion AND the
      # snapshot writer column ordering. Pull on every bridge-queue.py
      # move so a future refactor cannot silently re-introduce the
      # codex r1 BLOCKING repro (claimed task + picker_blocked + aged
      # → wrongly requeued).
      # Issue #1199: bridge-queue.py's find-open now accepts
      # `--status-filter <queued|claimed|blocked>` (repeatable) so the
      # ACTION REQUIRED "Highest priority" line can be restricted to
      # genuinely-queued tasks. The hook-side queue_summary consumes
      # `--status-filter queued`. Pull 1199-action-required-claimed-skip on
      # every bridge-queue.py move so a future refactor cannot regress the
      # filter (or the daemon-step queued-only candidate scan) and let a
      # just-claimed task get re-nudged.
      add_required queue 1106-nudge-shell-recheck nudge-task-age-gate nudge-redundant-active-agent 1323-nudge-eligibility-recheck-twostage 1199-action-required-claimed-skip a2a-cross-bridge 1100-audit-since-tz 1115-cli-usage-drift J-beta4-workflow-docs K-beta4-nits beta5-2-delta-nudge-session-empty beta5-2-kappa-state-audit-reconcile 1408-daemon-alert-nudge-hygiene
      # Issue #1425: find-open exclusion and cron-ready overfetch keep
      # cron-dispatch worker backlog out of human nudge/unclaimed alarms.
      add_required 1425-cron-dispatch-nudge-scope
      # Issue #1497 (P2): bridge-queue.py's six inline operator-home resolvers
      # (get_db_path / get_queue_gateway_root / proxy_via_queue_gateway --bridge-
      # home arg / get_cron_state_dir / get_queue_bodies_dir / bridge_managed_roots)
      # now share lib/operator_home.py::operator_home(). Pull 1497-p2-operator-home
      # on every bridge-queue.py move so a refactor cannot drift any of the six
      # call-sites' resulting paths off the canonical SSOT (byte-identical teeth).
      add_required 1497-p2-operator-home
      # A2A rooms P1b (#1505 follow-on): bridge-queue.py cmd_create now carries
      # the rooms ACL defense-in-depth + non-gateway gate (the direct create
      # path). Pull a2a-rooms-p1b-acl on every bridge-queue.py move so the
      # default-off no-op, the cross-room deny, and the --from spoof rejection
      # on the direct create path cannot silently regress.
      add_required a2a-rooms-p1b-acl
      add_integration integration-minimal
      ;;

    bridge-stall.py|bridge-audit.sh)
      # v0.15.0-beta5-2 Lane κ:
      #   #1319 H1 — bridge-stall.py is the source of the
      #     `interactive_picker` classification that lib/bridge-state.sh's
      #     new `bridge_agent_picker_blocked` predicate reads via stall.env.
      #     A future refactor that renames the classification (e.g. to
      #     `quarantine` or `picker`) would silently break the resolver
      #     branch without producing any compile-time error.
      #   #1324 M1 — bridge-audit.sh's no-`--agent` enumerator must walk
      #     BOTH the legacy controller-rooted tree
      #     (`$BRIDGE_HOME/logs/agents/<a>/audit.jsonl`) AND the iso v2
      #     canonical tree (`$BRIDGE_HOME/data/agents/<a>/logs/audit.jsonl`).
      #     The Lane κ smoke pins both anchors + the `Issue #1324` comment
      #     so a future PR cannot silently drop the v2 arm.
      # Pull beta5-2-kappa-state-audit-reconcile on every bridge-stall.py
      # or bridge-audit.sh move so either regression is caught at PR time.
      add_required beta5-2-kappa-state-audit-reconcile
      # v0.15.0-beta5-2 Lane ι (#1318-B): bridge-queue.py + bridge-task.sh
      # are the create boundary for queued tasks; the daemon's new
      # process_unclaimed_queue_escalation tick scans these tables on
      # every cycle. Pull beta5-2-iota-daemon-escalation-family on
      # every queue / task move so a future PR cannot regress: the
      # find-open --all --format json shape that the daemon's scan
      # consumes; the created_ts / status / assigned_to fields that the
      # age gate filters by; or the per-task dedup cooldown contract
      # that prevents admin-task spam against a long-queued task.
      add_required queue 1106-nudge-shell-recheck nudge-task-age-gate nudge-redundant-active-agent 1323-nudge-eligibility-recheck-twostage a2a-cross-bridge 1100-audit-since-tz 1115-cli-usage-drift J-beta4-workflow-docs K-beta4-nits beta5-2-delta-nudge-session-empty beta5-2-iota-daemon-escalation-family
      # v0.15.0-beta5-2 Lane ξ (#1318 part A): bridge-task.sh cmd_create
      # now refuses against stopped targets by default; --force overrides
      # with a warning + audit row. Pull beta5-2-xi-misc-fixes whenever
      # bridge-task.sh or bridge-queue.py moves so the --force flag parse,
      # the default-refuse branch, and the self-target exemption cannot
      # silently regress.
      add_required queue 1106-nudge-shell-recheck nudge-task-age-gate nudge-redundant-active-agent 1323-nudge-eligibility-recheck-twostage a2a-cross-bridge 1100-audit-since-tz 1115-cli-usage-drift J-beta4-workflow-docs K-beta4-nits beta5-2-delta-nudge-session-empty beta5-2-xi-misc-fixes
      add_integration integration-minimal
      ;;

    bridge-queue-gateway.py)
      # A2A rooms P1b: the queue gateway's authorize_and_rewrite now applies the
      # PRIMARY (iso-v2 SO_PEERCRED) rooms ACL gate to `create`. Any move to the
      # gateway authorizer must re-run the queue suite + the P1b ACL teeth (the
      # --from spoof rejection at the gateway is the security crux).
      add_required queue a2a-rooms-p1b-acl
      ;;

    bridge-a2a.py|bridge-handoffd.py|bridge_a2a_common.py|bridge-rooms.py|bridge_rooms_common.py|bridge-handoff-daemon.sh|lib/bridge-a2a.sh|handoff.local.example.json|scripts/smoke/a2a-cross-bridge-helper.py|scripts/smoke/a2a-tailscale-identity-resolve-helper.py|scripts/smoke/a2a-daemon-selfheal-reconcile-helper.py|scripts/smoke/a2a-migrate-identity-helper.py|scripts/smoke/a2a-ip-change-announce-helper.py|scripts/smoke/a2a-setup-wizard-helper.py|scripts/smoke/a2a-rooms-p1a-helper.py|scripts/smoke/a2a-rooms-p1b-acl-helper.py|scripts/smoke/a2a-rooms-1517-bootstrap-helper.py|scripts/install-handoffd-systemd.sh)
      # Issue #1032: A2A cross-bridge task handoff. Any move to the
      # receiver daemon, sender outbox/delivery-runner, shared protocol
      # module, lifecycle helper, or the smoke helper re-runs the
      # end-to-end A2A smoke (auth/allowlist/dedupe/cap/retry).
      #
      # Issue #1262 (v0.15.0-beta4 Lane I): A2A 3 gaps — systemd
      # auto-install (scripts/install-handoffd-systemd.sh), retry
      # verify (already in a2a-cross-bridge), outbox stuck alerting
      # (process_a2a_outbox_stuck_scan_tick in bridge-daemon.sh +
      # a2a-stuck-decide in bridge-daemon-helpers.py). The
      # I-beta4-a2a-3-gaps smoke covers the static-source contract for
      # all three gaps plus the python helper unit tests.
      # v0.15.0-beta4 Lane J (#1280): bridge-a2a.py's `cmd_send` now
      # falls back to `sudo -n -u <owner> cat <path>` when the
      # --body-file read raises PermissionError (iso UID-owned file at
      # mode 0660). J-beta4-workflow-docs (T1/T2) pins the helper
      # behavior + the structured failure surface; pull on every
      # bridge-a2a.py move so the fallback cannot regress to silent
      # empty-body sends.
      # beta5-2 Sub-wave 2 Lane λ (#1326 + #1331): HMAC timestamp skew
      # classification (narrow drift -> 503 transient, far-stale -> 401
      # permanent) + empty-secret fail-closed (receiver + sender, with
      # paired BRIDGE_A2A_DEV_INSECURE_BIND + BRIDGE_A2A_ALLOW_TEST_BIND
      # test-only escape hatch). beta5-2-lambda-a2a-robustness pins the
      # contract on both halves.
      # A2A Setup Wizard P0 (design §8): peers + `listen` may carry an
      # optional Tailscale identity (`tailscale_name` / `node_id`) resolved
      # to the current IP at use-time via `tailscale status --json`, with
      # the legacy raw `address` as the back-compat fallback. The shared
      # resolver lives in bridge_a2a_common.py; the sender (bridge-a2a.py)
      # and the receiver bind proof (bridge-handoffd.py) both call it.
      # a2a-tailscale-identity-resolve pins resolve-by-name/node_id, raw-IP
      # back-compat, resolve-failure fail-closed, tailscale-unavailable
      # fail-closed, AND the security invariant that the receiver bind proof
      # still REJECTS a resolved candidate not in `tailscale ip` (resolution
      # must never weaken the fail-closed bind proof).
      # Issue #1405 (v0.15.0 self-heal stack): A2A receiver supervision —
      # the daemon supervise tick (process_a2a_receiver_supervise_tick),
      # the read-only `bridge-handoffd.py healthz` serve probe, auto-restart
      # via the fail-closed `bridge-handoff-daemon.sh start`, the crash-loop
      # cap + alarm + admin task, exit-cause capture, the status alarm row,
      # and the systemd-defer path. Pull on every move to the receiver, the
      # lifecycle helper, or the systemd installer so the supervision contract
      # cannot regress to the silent-down state #1405 reported.
      # Issue #1415 (v0.15.0 self-heal stack, P1): the `agb a2a setup` wizard
      # (S0/S1/S2/S5/S6) in bridge-a2a.py produces the receiver config + starts
      # the receiver — the security-critical surface. a2a-setup-wizard pins:
      # the 0600 config write; the secret-from-env contract with the fail-closed
      # empty-secret refusal (both the wizard's own S2 check AND the daemon
      # preflight backstop); S5 activation via `bridge-handoff-daemon.sh start`
      # (never a raw serve); identity-keyed listen + peer; the idempotent
      # no-op re-run; and the fail-closed unresolvable-peer + --show-state
      # derived-state model (no state file). Pull on every bridge-a2a.py move so
      # a future PR cannot regress the wizard into writing an empty secret,
      # starting a secretless receiver, or persisting a config on a resolve
      # failure.
      # A2A rooms P1a: the envelope contract (optional room_id/room_epoch +
      # back-compat) lives in bridge_a2a_common.py and the receiver-check
      # seam (room_scoped_check, fail-closed) lives in bridge-handoffd.py, so
      # any move to those shared files must re-run a2a-rooms-p1a to confirm
      # the envelope change does not regress the room round-trip / v1
      # back-compat and the seam's fail-closed contract still holds. The
      # rooms control-plane modules (bridge-rooms.py / bridge_rooms_common.py)
      # and the rooms helper route here too via the path alternation above.
      # Issue #1398: the receiver's inbound enqueue (enqueue_via_bridge_task
      # in bridge-handoffd.py) passes --force to bridge-task.sh create so a
      # durable inbound handoff to a momentarily-stopped LOCAL target lands in
      # the queue instead of 422-ing under the #1318 stopped-target guard.
      # 1398-a2a-inbound-stopped-target-force pins: inbound-to-stopped -> 200
      # enqueued (not 422) + inbox visibility, AND that --force is the liveness
      # override ONLY (bad HMAC still 401, message_id reuse still 409) — so the
      # auth/dedupe gates upstream of the enqueue stay enforced. Pull on every
      # bridge-handoffd.py move so the force flag cannot regress to a 422 drop
      # or, worse, to a guard bypass that also weakens auth/dedupe.
      add_required a2a-cross-bridge queue I-beta4-a2a-3-gaps J-beta4-workflow-docs beta5-2-lambda-a2a-robustness a2a-tailscale-identity-resolve a2a-daemon-selfheal-reconcile a2a-migrate-identity a2a-ip-change-announce 1405-handoffd-supervision a2a-setup-wizard a2a-rooms-p1a a2a-rooms-p1b-acl a2a-rooms-1517-bootstrap 1398-a2a-inbound-stopped-target-force
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
      # v0.15.0-beta1 Lane F (autonomous daemon-side supp-groups poll):
      # bridge-daemon.sh now hosts the new data helper
      # (bridge_daemon_detect_stale_supp_groups), throttle state I/O
      # (bridge_daemon_supp_group_refresh_throttle_*), autonomous poll
      # (bridge_daemon_supp_groups_poll_and_dispatch), and the internal
      # subcommand cmd_supp_refresh_worker. Pull the two Lane F smokes
      # on every bridge-daemon.sh move so a future PR cannot silently
      # regress the dispatch/throttle/detector contract or the
      # no-SIGHUP invariant (codex spec-ok r1, F.B-prime pick).
      # v0.15.0-beta2 Lane δ (issue #1234, codex r1 BLOCKING parity): the
      # δ-1234-daemon-start-policy smoke pins both the always-on AND the
      # on-demand queued-work branches of `process_on_demand_agents`.
      # Codex r1 caught a parity gap where the on-demand branch was missing
      # the channel-miss auto-hold (the always-on branch had it). The smoke
      # extracts the production function verbatim and asserts the
      # `channel-required-validator-miss:` reason is recorded on the
      # on-demand branch — without this registration a future PR that
      # touches bridge-daemon.sh could silently re-introduce the gap on
      # the PR-path CI gate.
      # v0.15.0-beta3 Lane A3 (issue #1248): lib/bridge-state.sh hosts the
      # Layer-2 fix — `bridge_refresh_agent_session_id` now bridge_die's
      # on a `bridge_persist_agent_state` write failure with the structured
      # `state_dir_write_failed:session_id` reason, and emits the new
      # `[session-id]` success breadcrumb + `session_id_persisted` audit
      # row. bridge_write_agent_state_file / bridge_persist_agent_state
      # now propagate write rc instead of silently returning 0. Pull
      # A3-beta3-1248-restart-session-id-resume on every move so the
      # Layer-2 fail-loud and breadcrumb cannot silently regress back to
      # the pre-#1248 swallowed-failure shape (every restart spawned a
      # fresh Claude session because session_id was never persisted).
      # v0.15.0-beta4 Lane D (issue #1276): bridge-daemon.sh's cmd_run
      # now routes through `bridge_daemon_ensure_singleton` at the top
      # of every spawn path (cmd_start fork, direct `bridge-daemon.sh run`,
      # sudo-wrapped invocation, systemd ExecStart). The
      # D-beta4-daemon-lifecycle smoke pins the singleton lock/flock,
      # PID-file eviction, canonical `daemon_started` audit emit (with
      # pid + parent_pid + wrapper + sudo_self fields), and the
      # periodic `bridge_daemon_self_check`. Pull on every
      # bridge-daemon.sh move so a future PR cannot silently regress
      # back to the pre-Lane D duplicate-daemon surface that patch's
      # beta3 fresh install hit (two daemons polling the same tasks.db,
      # duplicate session_nudge_dropped rows, 5-10min nudge latency).
      # v0.15.0-beta4 Lane E (#1269): bridge-daemon.sh's three wake
      # sites (process_on_demand_agents always-on branch, queued
      # on-demand branch, and bridge_daemon_cron_dispatch_wake) now
      # invoke `bridge_agent_state_dir_self_heal` before each
      # bridge-start.sh call so a fresh-install (or VM-reboot) always-on
      # agent self-heals its missing `state/agents/<a>/` instead of
      # spinning on `start-command-failed`. The E-beta4 smoke pins all
      # three call sites via distinct `trigger=` audit-detail markers,
      # so a future PR cannot regress one of them silently while leaving
      # the others intact. lib/bridge-state.sh hosts the helper
      # (#1252), so the smoke also re-pulls on a state lib move.
      # v0.15.0-beta4 Lane G (#1266 + #1254): bridge-daemon.sh's
      # `process_watchdog_report` now downgrades the drift-task priority
      # to `low` when the watchdog payload's `fresh_install_only=true`
      # (the new daemon helper `watchdog-fresh-install-only` reads it).
      # G-beta4-watchdog-noise pins both the downgrade gate and the
      # daemon-helper readout contract — pull on every bridge-daemon.sh
      # move so a future PR cannot silently regress the priority gate.
      # v0.15.0-beta4 Lane I (#1262 Gap 3): bridge-daemon.sh now hosts
      # process_a2a_outbox_stuck_scan_tick — a new tick that scans the
      # A2A outbox for stuck rows and files admin tasks. Pull
      # I-beta4-a2a-3-gaps on every bridge-daemon.sh move so the wiring
      # (LAST_STEP literal, audit row name, target_bridge task create)
      # and the python decision helper (cmd_a2a_stuck_decide) contract
      # cannot regress silently.
      # v0.15.0-beta4 Lane J (#1267): bridge-daemon.sh's
      # `process_release_monitor` now emits a structured
      # `release_notification_downgrade_skip` audit row when the monitor
      # produced no alert but the installed version is ahead of the
      # latest stable (the bridge-daemon-helpers.py
      # `release-downgrade-classify` subcommand does the comparison).
      # J-beta4-workflow-docs (T5/T6) pins the classifier behavior;
      # pull on every bridge-daemon.sh move so the audit emit cannot
      # silently regress.
      # v0.15.0-beta5 Lane β (#1299): lib/bridge-state.sh hosts the
      # bridge_detect_claude_session_id + bridge_resolve_resume_session_id
      # shims that now wrap the python invocation in
      # `sudo -n -u <iso-uid> -- bash -c 'exec python3 "$@"' bash …` so
      # the 0600 Claude session JSON / jsonl files are readable from the
      # controller on iso v2 (beta4 Lane A only fixed the path; this
      # closes the permission boundary). bridge-sync.sh's
      # refresh_missing_session_ids is one of the callers; it threads
      # the agent's iso-v2 os_user resolved via
      # bridge_resolve_agent_iso_sudo_user (lib/bridge-agents.sh). Pull
      # Beta-beta5-session-id-detect-sudo on every move so the wrap
      # cannot silently regress.
      # v0.15.0-beta5-1 (#1304): lib/bridge-state.sh now also hosts the
      # `bridge_persist_agent_state` empty-detect no-op guard — the
      # defense-in-depth fix that prevents an empty in-memory session_id
      # from clobbering a successful 54f1742e on disk when an iso v2
      # detect race fires. Pull beta5-1-session-id-detect-race on every
      # state lib / sync.sh move so the guard cannot silently regress
      # back to the empty-overwrite shape patch caught on
      # cm-prod-agentworkflow-vm01.
      # v0.15.0-beta5-1 Lane 3 (#1307): bridge-daemon.sh now hosts the
      # MCP-liveness giveup auto-clear ledger + tick. The new helpers
      # (bridge_agent_mcp_giveup_arm/active/ts/clear/note_activity_state,
      # bridge_recheck_mcp_liveness) and `process_mcp_liveness_giveup_recovery`
      # close the silent message-drop class where a sticky giveup
      # state never auto-recovered when the agent normalized. Pull
      # mcp-liveness-giveup-auto-clear on every bridge-daemon.sh move
      # so a future PR cannot regress the activity_state observer,
      # the fallback timer, the audit-row shape (recovered /
      # recheck_still_failed), or the re-arm semantics on recheck
      # failure.
      # v0.15.0-beta5-2 Lane κ r2 (#1345): lib/bridge-state.sh's
      # bridge_write_agent_snapshot now appends the `activity_state`
      # column so the daemon-step Python path can exclude
      # picker_blocked agents from the idle_agents set used by
      # stale-claim requeue. Pull beta5-2-kappa-state-audit-reconcile
      # on every lib/bridge-state.sh or bridge-daemon.sh move so a
      # future refactor cannot silently re-introduce the codex r1
      # BLOCKING repro (claimed task + picker_blocked agent + aged
      # session_activity_ts → wrongly requeued tasks).
      # v0.15.0-beta5-5 Track Q (#1370): bridge-daemon.sh now hosts the
      # admin-only autostart recovery wrapper
      # (bridge_daemon_start_agent_with_recovery /
      # bridge_daemon_admin_autostart_recover). The 1380 smoke pins the
      # admin gate at the wrapper (non-admin agents never enter the
      # --no-continue/--safe-mode retry ladder, T6) and the base warning
      # parity (note-only on session-exited-quickly, T7). Pull
      # 1380-admin-autostart-recovery on every bridge-daemon.sh move so a
      # future PR cannot silently re-leak non-admin agents into the
      # recovery ladder or regress the non-admin byte-equivalence.
      # v0.15.0-beta5-6 (#1388): bridge-daemon.sh's three daemon-initiated
      # agent-launch sites (admin autostart recovery, base
      # bridge_daemon_start_agent_with_recovery, cron-dispatch wake) now
      # route the `bridge-start.sh` exec through
      # bridge_daemon_run_without_singleton_lock so the spawned tmux
      # server does not inherit the singleton lock fd (and pin the flock
      # after the daemon dies → restart-loop). Pull
      # 1388-daemon-lock-fd-cloexec on every bridge-daemon.sh move so a
      # future PR cannot silently re-introduce the fd leak at a launch
      # site (verified live on agb-clean-test: NRestarts churn stopped,
      # zero agent/tmux lock holders post-fix).
      # Issue #1405 (v0.15.0 self-heal stack): bridge-daemon.sh gained
      # process_a2a_receiver_supervise_tick (dispatched from cmd_sync_cycle)
      # — the A2A receiver watchdog: two-stage liveness (process gate +
      # `bridge-handoffd.py healthz` serve probe), auto-restart via the
      # fail-closed `bridge-handoff-daemon.sh start`, the crash-loop cap +
      # alarm-and-hold, exit-cause capture, the admin alarm, and the
      # systemd-defer path. Pull 1405-handoffd-supervision on every
      # bridge-daemon.sh move so the supervisor (and its invariant that
      # restart re-runs the full bind proof) cannot regress.
      # Issue #1473: bridge-daemon.sh's refresh_agent_heartbeats now also
      # publishes the world-readable all-agent state aggregate every tick
      # (bridge_write_agents_aggregate_state, hosted in lib/bridge-state.sh)
      # so an isolated agent UID can resolve every agent's active/state for
      # `agb agent list`. Pull 1473 on every daemon/state move so the
      # 0644-publish + all-agents-listed + no-secret + atomic-write contract
      # cannot regress.
      add_required daemon queue launch-dev-channels-injection channel-env-readiness cron-run-artifacts-retention cron-shell-runner status-engine-detect 835-static-admin-launch bridge-sync-roster-memo daemon-periodic-token-sync 1015-resume-claude-config-dir 1115-cli-usage-drift 1178-helper-contract-daemon-supp F-daemon-supp-groups-mock F-daemon-supp-groups-real δ-1234-daemon-start-policy A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir D-beta4-daemon-lifecycle A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir G-beta4-watchdog-noise I-beta4-a2a-3-gaps J-beta4-workflow-docs Beta-beta5-session-id-detect-sudo beta5-1-session-id-detect-race dev-channel-auto-accept-no-attach mcp-liveness-giveup-auto-clear beta5-2-epsilon-tmux-inject-busy beta5-2-pi-daemon-crashloop-no-set-e-leak beta5-2-kappa-state-audit-reconcile 1359-cron-create-iso-staging 1380-admin-autostart-recovery 1388-daemon-lock-fd-cloexec 1407-runtime-hardening 1405-handoffd-supervision 1408-daemon-alert-nudge-hygiene 1473-agent-list-iso-state-fallback 1461-cron-max-parallel-override
      # v0.15.0-beta5-2 Lane η (#1314, CRITICAL/security):
      # bridge-daemon.sh's `cmd_run_cron_worker` now gates shell-cron
      # dispatch on `bridge_cron_uid_drop_preflight`. The new gate emits
      # `cron_dispatch_refused reason=iso_uid_drop_unavailable` BEFORE
      # invoking the runner when an iso v2 agent lacks a working UID-drop
      # helper (sudo/setpriv misconfigured). Pair-defense with the
      # untouched `RuntimeError` seal in bridge-cron-runner.py:481. Pull
      # beta5-2-eta-cron-iso-uid-preflight on every bridge-daemon.sh
      # move so the gate (including the CRON_PAYLOAD_KIND=="shell" scope,
      # the audit-row name, and the refusal-side state propagation) cannot
      # regress silently.
      add_required daemon queue launch-dev-channels-injection channel-env-readiness cron-run-artifacts-retention cron-shell-runner status-engine-detect 835-static-admin-launch bridge-sync-roster-memo daemon-periodic-token-sync 1015-resume-claude-config-dir 1115-cli-usage-drift 1178-helper-contract-daemon-supp F-daemon-supp-groups-mock F-daemon-supp-groups-real δ-1234-daemon-start-policy A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir D-beta4-daemon-lifecycle A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir G-beta4-watchdog-noise I-beta4-a2a-3-gaps J-beta4-workflow-docs Beta-beta5-session-id-detect-sudo beta5-1-session-id-detect-race dev-channel-auto-accept-no-attach mcp-liveness-giveup-auto-clear beta5-2-eta-cron-iso-uid-preflight 1359-cron-create-iso-staging
      # v0.15.0-beta5-2 Lane δ (#1311): bridge-daemon.sh's nudge
      # fanout loop (inside `cmd_sync_cycle`) used to silently drop
      # any candidate row whose `$session` was empty or whose tmux
      # session had died. patch's audit C5 classified that as a
      # CRITICAL data-loss class because queued tasks stayed queued
      # forever with no audit row, no retry signal, and no escalation.
      # The new helpers
      # (bridge_daemon_nudge_deferred_state_file/load/save/clear,
      # bridge_daemon_nudge_defer_and_maybe_escalate,
      # bridge_daemon_nudge_emit_session_empty_admin_task) close the
      # silent-skip surface with a structured `nudge_deferred` audit
      # row each tick plus an at-most-once `nudge_session_empty_
      # escalated` admin task after BRIDGE_NUDGE_SESSION_EMPTY_
      # ESCALATE_AFTER consecutive deferrals. Pull
      # beta5-2-delta-nudge-session-empty on every bridge-daemon.sh
      # move so a future PR cannot reintroduce the pre-#1311 silent
      # soft-skip pattern, drop the per-task counter isolation, or
      # regress the recovery-clears-counter contract that long-lived
      # healthy agents depend on.
      add_required daemon queue launch-dev-channels-injection channel-env-readiness cron-run-artifacts-retention cron-shell-runner status-engine-detect 835-static-admin-launch bridge-sync-roster-memo daemon-periodic-token-sync 1015-resume-claude-config-dir 1115-cli-usage-drift 1178-helper-contract-daemon-supp F-daemon-supp-groups-mock F-daemon-supp-groups-real δ-1234-daemon-start-policy A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir D-beta4-daemon-lifecycle A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir G-beta4-watchdog-noise I-beta4-a2a-3-gaps J-beta4-workflow-docs Beta-beta5-session-id-detect-sudo beta5-1-session-id-detect-race dev-channel-auto-accept-no-attach mcp-liveness-giveup-auto-clear beta5-2-delta-nudge-session-empty 1359-cron-create-iso-staging
      # v0.15.0-beta5-2 Lane ν (#1317 A/B/C + #1333 L3): the daemon's
      # always-on auto-start engine pre-flight + bridge-state.sh's
      # broken-launch writer (now with reason_hint payload) + the
      # bridge-agent.sh activity_state observer (now surfacing
      # `quarantine-broken-launch`) all interlock. Pull beta5-2-nu-
      # daemon-path-quarantine on every bridge-daemon.sh / lib/bridge-
      # state.sh / bridge-agent.sh move so a future PR cannot regress
      # the operator-actionable hint chain or the activity-state label.
      add_required beta5-2-nu-daemon-path-quarantine
      # v0.15.0-beta5-2 Lane κ (#1319 H1): bridge-daemon.sh hosts
      # bridge_agent_heartbeat_activity_state (one of the three resolvers
      # that must agree on the new `picker_blocked` state); lib/bridge-
      # state.sh hosts the predicate + the snapshot writer's resolver.
      # Pull beta5-2-kappa-state-audit-reconcile on every bridge-daemon.sh
      # / lib/bridge-state.sh move so a regression at any layer (predicate
      # rename, predicate path drift, resolver branch removal) re-introduces
      # the false-positive `working` shape patch flagged on stale picker.
      add_required beta5-2-kappa-state-audit-reconcile
      # v0.15.0-beta5-2 Lane ι (#1320 H2 + #1321 H3 + #1322 H4 + #1323 H5
      # + #1318-B 7051): bridge-daemon.sh now hosts five new escalation /
      # dedup / redeliver helpers that close the patch-audited operator-
      # invisible failure surfaces. Pull
      # beta5-2-iota-daemon-escalation-family on every bridge-daemon.sh
      # move so a future PR cannot silently regress: (a) the
      # always-on launch-failure escalation cooldown contract; (b) the
      # MCP-giveup recovery miss-queue drain + dedup_key audit emit
      # contract; (c) the per-(agent, task_id) nudge dedup window
      # isolation contract (formerly the per-agent composite); (d) the
      # recheck-timeout per-task consecutive counter +
      # at-most-once admin escalation; (e) the unclaimed-queue daemon
      # tick + per-task marker cooldown contract.
      add_required beta5-2-iota-daemon-escalation-family
      # v0.15.0-beta5-2 Track G (#1323 r3): bridge-daemon.sh's
      # nudge_agent_session verify-grace block does a two-stage check
      # (stage_2 = TOTAL elapsed-time gate, not additional sleep), and
      # consults the per-(agent, task_id) dedup gate
      # (bridge_daemon_should_skip_nudge / bridge_daemon_record_nudge)
      # before/after the verify window. The 1323 smoke pins: the
      # two-stage shape + env-knob fallbacks
      # (BRIDGE_NUDGE_RECHECK_STAGE_1_SECONDS / _STAGE_2_SECONDS); and,
      # via its T4a-T4d cases (r3), the REAL dedup path — it sources
      # bridge_daemon_should_skip_nudge / bridge_daemon_record_nudge
      # straight from the daemon and drives same-task in-window SKIP,
      # different-task fire, window-expiry, and a faithful cross-tick
      # rapid-succession scenario (a `nudge_once` wrapper mirroring the
      # daemon's skip-check → verify → record-after-verified-send order;
      # nudge 1 delivered in a `( ... ) &` subshell then waited for,
      # modelling the daemon's at-most-once-per-tick guarantee, then
      # nudge 2 inline) proving a same-agent second nudge is deduped —
      # exactly one session_nudge_sent, no double-counter — rather than
      # spawning a second verify window. Pull on every bridge-daemon.sh
      # move so neither the two-stage shape nor the dedup-gate wiring can
      # regress silently.
      add_required 1323-nudge-eligibility-recheck-twostage
      # Issue #1425: human-nudge and unclaimed-task daemon paths must keep
      # the same non-cron task scope as nudge_live_state.
      add_required 1425-cron-dispatch-nudge-scope
      # Issue #1936 (gap #4): bridge-daemon.sh now hosts
      # bridge_daemon_attached_human_followup_escalate — the daemon path
      # that files a refreshable admin alert when a human-facing cron
      # followup is queued on an attached live session (which #1411 keeps
      # out of raw tmux injection). The 1936 smoke pins the classification,
      # attached-skip ordering, no-recursive-admin-loop guard, upsert
      # dedupe, and per-task cooldown. Pull it on every bridge-daemon.sh
      # move so the attached-followup escalation cannot regress silently.
      add_required 1936-forward-followup-attached-escalation
      # v0.15.0-beta5-2 Lane μ (#1327 / #1328): bridge-daemon.sh's
      # `cmd_run_cron_worker` now re-checks the manual-stop marker at
      # execute time (edge case 1: agent restart between dispatch and
      # execute), AND lib/bridge-cron.sh hosts the new cron-state-dir
      # anchor / verify-and-migrate helper called from `run_sync` to
      # preserve cron history when `BRIDGE_CRON_STATE_DIR` moves. The
      # beta5-2-mu-cron-channel-creds smoke pins the audit-row name
      # (`cron_dispatch_skipped`), the execute-time re-check site, the
      # anchor-write contract, and the conflict-bail behaviour. Pull
      # on every move of these files so the gates cannot regress
      # silently.
      add_required daemon queue launch-dev-channels-injection channel-env-readiness cron-run-artifacts-retention cron-shell-runner status-engine-detect 835-static-admin-launch bridge-sync-roster-memo daemon-periodic-token-sync 1015-resume-claude-config-dir 1115-cli-usage-drift 1178-helper-contract-daemon-supp F-daemon-supp-groups-mock F-daemon-supp-groups-real δ-1234-daemon-start-policy A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir D-beta4-daemon-lifecycle A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir G-beta4-watchdog-noise I-beta4-a2a-3-gaps J-beta4-workflow-docs Beta-beta5-session-id-detect-sudo beta5-1-session-id-detect-race dev-channel-auto-accept-no-attach mcp-liveness-giveup-auto-clear beta5-2-mu-cron-channel-creds 1359-cron-create-iso-staging
      add_required daemon queue launch-dev-channels-injection channel-env-readiness cron-run-artifacts-retention cron-shell-runner status-engine-detect 835-static-admin-launch bridge-sync-roster-memo daemon-periodic-token-sync 1015-resume-claude-config-dir 1115-cli-usage-drift 1178-helper-contract-daemon-supp F-daemon-supp-groups-mock F-daemon-supp-groups-real δ-1234-daemon-start-policy A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir D-beta4-daemon-lifecycle A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir G-beta4-watchdog-noise I-beta4-a2a-3-gaps J-beta4-workflow-docs Beta-beta5-session-id-detect-sudo beta5-1-session-id-detect-race dev-channel-auto-accept-no-attach mcp-liveness-giveup-auto-clear beta5-2-mu-cron-channel-creds
      # Issue #1379 (Track O, follow-up to #1359): root bridge-cron.sh's
      # `_bridge_cron_create_via_staging` now resolves the shared
      # cross-class group name (`bridge_isolation_v2_agent_group_name`)
      # and passes it to staging.py via `AGB_STAGE_FILE_GROUP` so the
      # staged file is chgrp-ed to a controller-readable group. Pull
      # 1379-iso-cron-staging-group on every bridge-cron.sh move so a
      # future PR cannot drop the group passthrough.
      # Issue #1383 (follow-up to #1379, daemon->iso result-read leg): the
      # daemon-written `<uuid>.result.json` is now chgrp-ed to the canonical
      # `ab-agent-<a>` group too (staging.py _write_result via
      # _resolve_result_gid), so the iso UID can read its own cron result.
      # Pin its smoke on bridge-cron.sh moves alongside the request-leg one.
      add_required 1379-iso-cron-staging-group 1383-iso-cron-result-json-group
      # Issue #1426: root bridge-cron.sh's usage() and
      # bridge_cron_validate_shell_run_config now state the iso-v2 /
      # --run-as-agent requirement up front and point a non-iso author at
      # the supported scheduled-shell fallbacks (OS crontab / --kind text)
      # plus OPERATIONS.md. Pull 1426-cron-shell-noniso-help on every
      # bridge-cron.sh move so a future PR cannot regress the help/error
      # clarity contract back to the bare dead-end message.
      add_required 1426-cron-shell-noniso-help
      # Incident #8807 P1: root bridge-cron.sh's native-sync path documents
      # scheduler-state.json as canonical and native-scheduler-state.json as a
      # read-only compat copy (single active scheduler). The
      # 8807-cron-backfill-coalesce smoke pins that documentation alongside the
      # scheduler-side catch-up coalesce; pull it on every bridge-cron.sh move
      # so the compat-copy clarification cannot be silently dropped.
      add_required 8807-cron-backfill-coalesce
      # Issue #1353 (v0.15.0-beta5-2 Track A): bridge-daemon.sh's
      # `bridge_daemon_check_channel_status_or_hold` + `bridge_report_
      # channel_health_miss` now consult `bridge_agent_setup_pending_
      # active` (defined in lib/bridge-state.sh) and silent-skip the
      # backoff / audit-row paths when the setup-pending marker is
      # present within the grace window. The 1353-setup-pending-grace
      # smoke pins both gate call sites + the marker contract (mark,
      # active, clear) + the teeth-revert under
      # BRIDGE_AGENT_SETUP_PENDING_GRACE_SECONDS=0. Pull on every
      # bridge-daemon.sh / lib/bridge-state.sh move so a future PR
      # cannot regress back to the pre-#1353 4-burst noise surface
      # that masks real errors during fresh-install OOTB.
      add_required 1353-setup-pending-grace
      # Incident #8807 P0a: bridge-daemon.sh now wires the resource-guard
      # (lib/bridge-resource-guard.sh) at every disposable-child spawn site —
      # start_cron_worker, the cron-dispatch claim/wake path
      # (start_cron_dispatch_workers + bridge_daemon_cron_dispatch_wake),
      # cmd_run_cron_worker's run-subagent fork, the supp-refresh worker, and
      # the always-on / queued-on-demand auto-start. Pull
      # 8807-resource-guard-defer on every bridge-daemon.sh move so a future
      # PR cannot silently drop a guard site or regress the fail-OPEN / leave-
      # queued / throttled-warn contract that prevents the fork-storm reboot.
      add_required 8807-resource-guard-defer
      # Incident #8807 P0b: bridge-daemon.sh moved the periodic MCP-orphan
      # cleanup (process_mcp_orphan_cleanup) to the TOP of cmd_sync_cycle so
      # it relieves process-pressure before the spawn-heavy surfaces. Pull
      # 8807-mcp-reaper-patterns on every bridge-daemon.sh move so the
      # pressure-relief ordering and the single-invocation invariant cannot
      # silently regress.
      add_required 8807-mcp-reaper-patterns
      # PR-B / #1520b: bridge-daemon.sh's bridge_daemon_autostart_allowed
      # gained the credential-pending hold predicate (return-hold-without-
      # backoff while the marker is present + the credential absent, lazy
      # self-clear once a non-empty .credentials.json lands, no bridge-auth.sh
      # source). The gate is consulted by all three start surfaces (warm
      # always-on, on-demand queued, cron-dispatch wake). Pull the smoke on
      # every bridge-daemon.sh move so a refactor cannot drop the hold,
      # start writing backoff state on a hold, or remove the lazy self-clear.
      add_required 1520b-create-time-creds-sync
      add_integration integration-minimal
      add_live live-tmux-daemon
      ;;

    lib/bridge-resource-guard.sh)
      # Incident #8807 P0a: the resource-guard primitive + the daemon-side
      # defer/audit/throttled-warn wrapper. Pull 8807-resource-guard-defer on
      # every move of the guard lib so the proc-count/memory probe, the
      # fail-OPEN contract, and the throttled-warn bookkeeping cannot regress.
      add_required 8807-resource-guard-defer
      ;;

    bridge-mcp-cleanup.py)
      # Incident #8807 P0b: the MCP-orphan reaper's DEFAULT_PATTERNS (tightened
      # to bridge-owned identities/paths + extended to the missing bridge MCP
      # signatures, never matching Pencil.app's mcp-server-darwin-arm64 or live
      # `codex resume` agents) and the PID-reuse revalidation in kill_pid. The
      # r2 control matrix + spawn fixtures live in the file-as-argv helper
      # (8807-mcp-reaper-patterns-helper.py, extracted to drop heredoc-stdin);
      # a change to that helper hits the `scripts/smoke/*` catch-all above,
      # which runs the full static suite (where 8807-mcp-reaper-patterns is
      # also registered). Pull 8807-mcp-reaper-patterns on every reaper move so
      # the control matrix and the pre-TERM/pre-KILL revalidation cannot
      # regress.
      add_required 8807-mcp-reaper-patterns
      ;;

    lib/bridge-daemon-control.sh|scripts/install-daemon-systemd.sh|scripts/sudoers-templates/agent-bridge-daemon-refresh.sudo.template)
      # v0.15.0-beta1 Lane F: the autonomous supp-groups refresh path
      # in bridge-daemon.sh dispatches a detached worker that sources
      # `lib/bridge-daemon-control.sh` and calls
      # bridge_daemon_refresh_after_group_membership_change. The
      # sudo-self systemd unit (rendered by install-daemon-systemd.sh)
      # and the sudoers template back-stop the PAM/initgroups boundary
      # that actually refreshes the daemon's supplementary-group set
      # (KillMode=process, exact ExecStart shape). Any change to those
      # three files MUST re-exercise both the host-agnostic mock and
      # the Linux-gated real smoke so a future PR cannot regress the
      # systemd-self / direct-sudo branch coverage. The 1178 startup
      # warning smoke is also pulled because the wrapper there shares
      # the new data helper with Lane F.
      # v0.15.0-beta3 Lane A12 (#1246): the supp-group pre-check
      # `_bridge_daemon_control_daemon_has_gid` now emits a structured
      # decision-evidence line on EVERY code path (daemon-not-running,
      # proc-status-unreadable, already-has-group, missing-from-supp-set)
      # so the silent false-positive that bypassed the systemd-user
      # auto-restart branch (lines 404-411) on patch's fresh-install OOTB
      # can never repeat undetected. Pull A12-beta3 on every
      # lib/bridge-daemon-control.sh move so the predicate's emit
      # contract stays pinned.
      # v0.15.0-beta4 Lane D (issue #1276): lib/bridge-daemon-control.sh
      # hosts the new `bridge_daemon_ensure_singleton` + `bridge_daemon_self_check`
      # helpers that close the duplicate-daemon spawn race. Any move to
      # this lib OR to the systemd install script OR to the sudoers
      # template MUST re-exercise the D-beta4 smoke because all three
      # files participate in the spawn path that ensure_singleton
      # guards (lib defines the helper; install-daemon-systemd.sh wires
      # the ExecStart whose every restart now crosses the helper; the
      # sudoers template authorizes the sudo-self path that emitted no
      # `daemon_started` audit row pre-Lane D).
      # v0.15.0-beta4 Lane F (#1228): probe_sudo_self_refresh's glob
      # anti-pattern was the structural root cause behind every Debian /
      # Ubuntu / RHEL install silently landing on legacy ExecStart. The
      # F-beta4-oauth-bootstrap smoke pins the sudo -ln replacement,
      # the mode= machine-parseable emit, AND the silent-fallback warn —
      # any move to install-daemon-systemd.sh OR the sudoers template
      # must re-exercise this lane.
      # v0.15.0-beta5-6 (#1388): lib/bridge-daemon-control.sh now records
      # the singleton lock fd in $BRIDGE_DAEMON_SINGLETON_LOCK_FD on a
      # successful flock acquire and exposes
      # bridge_daemon_run_without_singleton_lock, which closes that fd
      # for daemon-launched children (close-for-child) so the immortal
      # tmux server cannot inherit it and pin the flock after the daemon
      # dies. Pull 1388-daemon-lock-fd-cloexec on every move so the
      # fd-record + close-for-child contract (and its teeth) cannot
      # silently regress back to the leak-into-tmux restart-loop.
      add_required F-daemon-supp-groups-mock F-daemon-supp-groups-real 1178-helper-contract-daemon-supp A12-beta3-1246-1252-daemon-supp-group-and-state-dir D-beta4-daemon-lifecycle F-beta4-oauth-bootstrap 1388-daemon-lock-fd-cloexec
      ;;

    lib/cron-helpers/*.py)
      # v0.15.0-beta5-2 Lane η (#1314, CRITICAL/security): the cron-helpers
      # python files (extracted from heredoc-stdin sites — see footgun #11)
      # are part of the cron dispatch surface. load-run-shell.py in
      # particular now surfaces CRON_PAYLOAD_KIND, which the daemon's pre-
      # flight uses to scope shell-cron refusals. Pull the same regression
      # smokes as bridge-cron-runner.py so a refactor of these helpers
      # cannot silently regress the dispatch contract.
      # Issue #1359 (v0.15.0-beta5-2 Track H): lib/cron-helpers/staging.py
      # is the new tactical iso-staging entry point; pin its smoke on
      # every helper-tree move so a future heredoc-extraction refactor
      # cannot silently regress the staging apply / actor_agent /
      # owner-UID validation contract.
      # Issue #1379 (Track O, follow-up to #1359): staging.py's
      # cmd_write_request now resolves the shared cross-class group and
      # `chgrp`s the staged file to it (mode 0660) + self-heals the
      # per-agent subdir setgid, so the controller/daemon can read the
      # file instead of hitting the user-private-group read-denied
      # 30s pickup timeout. Pull 1379-iso-cron-staging-group on every
      # cron-helpers move so a future PR cannot drop the group-resolution
      # chain or the explicit chgrp.
      # Issue #1383 (follow-up to #1379, daemon->iso result-read leg):
      # staging.py's _write_result now resolves the canonical actor group
      # (_resolve_result_gid) and chgrp+publishes the `<uuid>.result.json`
      # so the iso UID can read its OWN cron result without Errno 13. Pin
      # 1383-iso-cron-result-json-group on every cron-helpers move so a
      # future refactor cannot drop the result-leg group resolution.
      add_required cron-run-artifacts-retention cron-shell-runner beta5-2-eta-cron-iso-uid-preflight 1359-cron-create-iso-staging 1379-iso-cron-staging-group 1383-iso-cron-result-json-group queue
      add_integration integration-minimal
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
      # v0.15.0-beta5-2 Lane η (#1314, CRITICAL/security):
      # bridge-cron-runner.py:481 retains the `RuntimeError("no supported
      # UID drop helper found (sudo or setpriv)")` seal as defense-in-
      # depth; pre-flight validation now lives at the daemon dispatch
      # site (`bridge_cron_uid_drop_preflight` in lib/bridge-cron.sh).
      # Pull beta5-2-eta-cron-iso-uid-preflight whenever the runner moves
      # so a future PR cannot silently downgrade the RuntimeError to a
      # warning (which would re-open the iso v2 controller-UID
      # fallthrough class).
      # Issue #1359 (v0.15.0-beta5-2 Track H): bridge-cron.py is the
      # apply-side subprocess invoked by `lib/cron-helpers/staging.py
      # apply` — moving native-create's argv shape silently regresses
      # the iso staging delegation. Pin 1359-cron-create-iso-staging
      # alongside the canonical cron-mutation-audit smoke.
      # Issue #1379 (Track O): also pin the staging-group smoke here so a
      # native-create argv change is co-verified against the group fix.
      # Issue #1383 (result-read leg): the apply path's _write_result is the
      # daemon-written `<uuid>.result.json` site; pin its smoke too so an
      # argv/result-shape change is co-verified against the result group fix.
      # Incident #8807 P1: bridge-cron-scheduler.py's enumerate_due_runs now
      # coalesces the catch-up backlog for idempotent / picker-sweep families
      # (cap at BRIDGE_CRON_COALESCE_CATCHUP_MAX, default 1) BEFORE enqueue so
      # a restart after downtime fires the job once instead of replaying a
      # 12-occurrence queue burst. Pull 8807-cron-backfill-coalesce on every
      # scheduler move so the coalesce-family scope, the keep-latest behaviour,
      # and the env overrides cannot regress.
      add_required cron-run-artifacts-retention cron-migrate-payloads cron-mutation-audit cron-shell-runner cron-runner-schema-openai-strict cron-path-augmentation-874 queue beta5-2-eta-cron-iso-uid-preflight 1359-cron-create-iso-staging 1379-iso-cron-staging-group 1383-iso-cron-result-json-group 8807-cron-backfill-coalesce
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
      # Issue #1513: bridge-run.sh's bridge_run_prune_legacy_teams_mcp
      # invokes scripts/python-helpers/prune-legacy-teams-mcp.py AS the
      # iso UID against the legacy $BRIDGE_AGENT_HOME_ROOT/<a> mirror. On
      # the create-shared-then-isolate path that mirror is 0700 (the #1165
      # scaffold-time chmod only fires when isolation is active AT
      # create), so the prune's Path.is_file() raises EACCES and the
      # launch aborts. Two-layer fix: the prune now skips an unreadable
      # candidate non-fatally (L1), and bridge_linux_prepare_agent_
      # isolation normalizes the legacy mirror dir's traverse bit on the
      # isolate path (L2). Pull 1513-iso-teams-prune-eacces on every
      # bridge-run.sh / bridge-agent.sh dispatcher move so neither layer
      # can silently regress (L1 back to a raising is_file(); L2 back to a
      # missing legacy-mirror chmod on the create-shared-then-isolate
      # path).
      # Issue #1213 (beta26): bridge-run.sh:212 grew a comment block
      # documenting the assoc-array vs scalar-export collision for
      # BRIDGE_AGENT_ISOLATION_MODE / BRIDGE_AGENT_OS_USER /
      # BRIDGE_AGENT_INJECT_TIMESTAMP. The fix is hook-side (UID-based
      # predicate), but the 1213 smoke pins the bash collision
      # reproducer against this exact line range. Pull it whenever
      # bridge-run.sh moves so a future patch can't silently swap the
      # working workaround back for an `unset` (which the brief
      # explicitly forbids because downstream array readers depend on
      # the lookup tables).
      # Issue #1217 (beta27 Track D): bridge-run.sh now exports
      # BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED as a distinctly-named
      # scalar alias next to the bare-name export (the bare name
      # silently no-ops because of the assoc-array collision in
      # lib/bridge-core.sh:867). The beta27-D smoke pins both the
      # bash collision repro and the Python hook's RESOLVED-first
      # read order. Pull it whenever bridge-run.sh moves so the
      # alias export and read order cannot regress.
      # v0.15.0-beta1 Lane I: bridge-agent.sh gained the `describe` verb
      # (read-only BRIDGE_AGENT_DESC getter) + `agent show` text-mode
      # unset hint. Pull I-agent-description-roster on every dispatcher
      # move so the describe dispatch arm + show hint cannot regress.
      # Issue #1251 (v0.15.0-beta3 Lane C1): bridge-agent.sh::run_restart
      # now drives a 3-phase transactional restart: pre-flight (full)
      # before the kill, in-progress marker + roster snapshot, and
      # auto-rollback on launch failure. The marker schema is the
      # contract Lane C2 (#1254 watchdog drift suppression) consumes.
      # Pull C1-beta3-1251-restart-preflight-rollback on every
      # bridge-agent.sh move so the marker shape, the pre-flight ordering,
      # and the rollback teeth all stay pinned alongside the call-site
      # changes in run_restart.
      # v0.15.0-beta4 Lane E (#1265): bridge-run.sh:207-... grew a
      # fresh-install first-wake carve-out on top of the Lane A3 #1248
      # reconcile gate. The carve-out uses
      # `state/agents/<a>/launch.history` as the fresh-vs-lost-state
      # heuristic (absent => proceed without --resume + touch marker;
      # present => die with the existing (a)/(b)/(c) remediation).
      # Pull E-beta4-fresh-install-gate-state-dir on every bridge-run.sh
      # move so a future PR cannot silently regress the OOTB `agb admin`
      # die into the lost-state branch (operator-blocking; first surface
      # patch + admin-dev codex pair on a fresh install).
      # v0.15.0-beta4 Lane K (#1282 Surface A): bridge-run.sh's
      # `bridge_run_prune_legacy_teams_mcp` now filters the steady-state
      # `absent path=…` / `unchanged path=…` rows out of the audit tail
      # — only real actions (pruned/failed/skipped) reach the operator.
      # Lane K (#1247) also adds the `agb admin set --auto-restart` CLI
      # surface, dispatched from the agent-bridge `admin` case head and
      # backed by scripts/python-helpers/admin-set-config.py. Pull
      # K-beta4-nits on every bridge-run.sh / agent-bridge move so a
      # future PR cannot silently regress either surface.
      # Issue #1297 (v0.15.0-beta5 Lane α): bridge-agent.sh's
      # `agent restart` is the operator-visible symptom — when the
      # workdir-backfill normalize is skipped on an upgrade pass,
      # restart's pre-launch grep on CLAUDE.md fails EACCES + rollback
      # also fails. The Lane α smoke pins the normalize wiring upstream
      # in the back-fill loop; pull it on every bridge-agent.sh move so
      # a restart-path refactor cannot silently re-expose the dual-
      # failure path (controller-grep + rollback) that #1297 captured.
      # v0.15.0-beta5 Lane gamma (#1298): the `agent-bridge isolation
      # reconcile` dispatcher (this CLI) routes into
      # `bridge_isolation_v2_apply_install_tree_matrix`. The Lane gamma
      # fix landed the manual-mode parity expansion inside that function
      # (reason=manual + no --agent + no --all => implicit --all-agents)
      # so manual reconcile reports agent-home-contract drift the prior
      # contract silently skipped. Pull gamma-beta5-reconcile-helper-
      # status whenever the dispatcher moves so a future PR cannot
      # silently drift the dispatch shape (e.g. by passing `--reason
      # install` instead of `--reason manual`, which would bypass the
      # parity guard).
add_required launch launch-dev-channels-injection tmux-injection upgrade-source-preservation upgrade-shared-settings-propagate agent-create-name-validation agent-create-caller-trust-gate agent-create-idle-timeout 1105-agent-add-audit 1100-audit-since-tz agent-update agent-update-launch-cmd-redaction 1122-admin-auto-caller-source 1136-always-on-no agent-doctor upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering status-engine-detect 835-static-admin-launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup 1400-purge-home-degrade-no-sudo 1028-isolated-workdir-check 1118-v2-engine-binary-path v2-scaffold-home-and-workdir 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair 1067-codex-provisioning 1115-cli-usage-drift 1151-step-a-helper 1155-bootstrap-skill-guard 1158-marker-load-order 1165-track-a-scaffold-modes 1213-iso-uid-predicate beta27-D-inject-timestamp-resolved I-agent-description-roster γ-cli-consistency C1-beta3-1251-restart-preflight-rollback A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir K-beta4-nits α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-epsilon-tmux-inject-busy beta5-2-theta-upgrade-backfill-perms 1360-onboarding-next-actions-persona 1409-claude-midturn-busy-gate 1513-iso-teams-prune-eacces plugin-requires-resolver 1520-shared-claude-config-dir 1520b-create-time-creds-sync
      # v0.15.0-beta5-2 Lane ν (#1317-B/-C): bridge-agent.sh now hosts
      # the engine-CLI pre-flight at `agent create` (refuses with
      # actionable error when the engine binary is not on PATH; opt-out
      # via --force-engine-missing) and the `bridge_agent_activity_state`
      # extension that returns `quarantine-broken-launch` when the
      # broken-launch marker exists. Pull beta5-2-nu-daemon-path-
      # quarantine on every bridge-agent.sh move so a future PR cannot
      # silently regress either surface back to the pre-#1317 opaque
      # `stopped` label or the missing-engine create silent-pass.
      add_required beta5-2-nu-daemon-path-quarantine
      # v0.15.0-beta5-2 Lane κ (#1319 H1): bridge-agent.sh hosts
      # `bridge_agent_activity_state` which is the second of the three
      # resolvers that emit `picker_blocked` (alongside the snapshot
      # writer in lib/bridge-state.sh and the heartbeat path in
      # bridge-daemon.sh). Pull beta5-2-kappa-state-audit-reconcile on
      # every bridge-agent.sh move so the predicate call and branch
      # ordering cannot silently regress.
      add_required beta5-2-kappa-state-audit-reconcile
      # v0.15.0-beta5-2 Lane ξ (#1330/#1332/#1334/#1318-A): bridge-start.sh
      # gained the BRIDGE_AGENT_ID env-prefix inline (#1330 M7) and the
      # EFFECTIVE_CONTINUE_MODE warn gate (#1334 L4); bridge-run.sh's
      # warn order must stay aligned with bridge-start.sh's. Pull
      # beta5-2-xi-misc-fixes whenever either bridge-start.sh or
      # bridge-run.sh moves so the env-prefix inline and the warn-order
      # alignment cannot silently regress.
      # Issue #1360 (v0.15.0-beta5-2 Track I): bridge-agent.sh's `agent
      # show` data pipeline now synthesizes a `.next_actions` array (refs
      # bridge-agent.sh:2041-2045 + lib/bridge-agents.sh
      # bridge_agent_next_actions_tsv/_text/_json) and `agent create`'s
      # `next_steps:` block is now persona-aware
      # (bridge_create_next_steps_lines). Pull
      # 1360-onboarding-next-actions-persona on every bridge-agent.sh
      # move so the credentials-missing/unreadable wizard mapping, the
      # terminal-only attach + memory init checklist, and the iso v2
      # plugin seed + note advisory cannot silently regress (codex r1
      # PR #1364 BLOCKING 1/2/3).
add_required launch launch-dev-channels-injection tmux-injection upgrade-source-preservation upgrade-shared-settings-propagate agent-create-name-validation agent-create-caller-trust-gate agent-create-idle-timeout 1105-agent-add-audit 1100-audit-since-tz agent-update agent-update-launch-cmd-redaction 1122-admin-auto-caller-source 1136-always-on-no agent-doctor upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering status-engine-detect 835-static-admin-launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup 1400-purge-home-degrade-no-sudo 1028-isolated-workdir-check 1118-v2-engine-binary-path v2-scaffold-home-and-workdir 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair 1067-codex-provisioning 1115-cli-usage-drift 1151-step-a-helper 1155-bootstrap-skill-guard 1158-marker-load-order 1165-track-a-scaffold-modes 1213-iso-uid-predicate beta27-D-inject-timestamp-resolved I-agent-description-roster γ-cli-consistency C1-beta3-1251-restart-preflight-rollback A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir K-beta4-nits α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-epsilon-tmux-inject-busy beta5-2-theta-upgrade-backfill-perms beta5-2-xi-misc-fixes 1360-onboarding-next-actions-persona 1513-iso-teams-prune-eacces plugin-requires-resolver 1520-shared-claude-config-dir 1520b-create-time-creds-sync
      # v0.15.0-beta5-2 Lane E (#1357): bridge-agent.sh::run_show appends
      # an `iso_boundary_quickref:` block when
      # bridge_agent_linux_user_isolation_effective <agent> returns 0 so
      # the agent (or operator inspecting it) sees the same paper-cut
      # mapping the CLAUDE.md "Agent's own POV" table documents. Pull
      # 1357-iso-boundary-quickref on every bridge-agent.sh move so a
      # future refactor cannot silently drop either the call site or its
      # iso-effective gate.
      add_required 1357-iso-boundary-quickref
      # patch cm-prod Part 1: bridge-agent.sh::run_create now calls
      # bridge_expand_channel_requires after channel normalization and before
      # the dry-run gate, transitively pulling each plugin manifest's optional
      # `requires` channel specs into $channels (generic; zero domain
      # hardcoding). The resolver lives in lib/bridge-agents.sh. Pull
      # plugin-requires-resolver on every bridge-agent.sh move so a refactor
      # cannot drop the wiring (the create-path call site), regress the
      # dedupe/cycle/depth-cap/warn-and-continue contract, or relocate the
      # expansion after the dry-run gate (which would hide it from --dry-run).
      add_required plugin-requires-resolver
      # v0.15.0-beta5-3 Track K (#1352): bridge-run.sh:349 now re-augments
      # the shared launch shell PATH via bridge_augment_engine_path (the
      # same canonical resolver the daemon runs at lib-load time) instead
      # of a hard-coded `~/.local/bin:~/.nix-profile/bin:/usr/local/bin`
      # literal. This removed the iso-only special case so the
      # auto-provisioned shared codex pair resolves a user-local Node
      # manager `codex` (nvm/pyenv/volta/asdf/fnm) instead of dying with
      # exit 127. Pull 1352-shared-codex-pair-path on every bridge-run.sh
      # move so a future PR cannot re-introduce the bare-literal export or
      # drop the bridge_augment_engine_path call.
      add_required 1352-shared-codex-pair-path
      # Issue #1353 (v0.15.0-beta5-2 Track A): bridge-agent.sh's
      # `run_create` writes the setup-pending marker for any
      # channel-required always-on agent; bridge-start.sh clears the
      # marker on operator-driven start. The 1353 smoke confirms the
      # mark site in bridge-agent.sh and the clear site in
      # bridge-start.sh — pull on every move of either so a refactor
      # cannot drop the create-side mark or the start-side clear.
      add_required 1353-setup-pending-grace
      # #8945 Track A: bridge-send.sh hosts urgent_nudge_body — the engine-aware
      # urgent-nudge body branch (Codex gets the explicit multi-step protocol,
      # Claude keeps the one-liner, unknown engine fail-safes to the one-liner).
      # Pull codex-nudge-body on every bridge-send.sh move so a refactor cannot
      # silently collapse the branch back to the engine-blind one-liner that
      # wedged the Codex patch-dev. (1067-codex-provisioning is already pulled
      # by this arm's add_required block above.)
      add_required codex-nudge-body
      # #8945 Track C: bridge-agent.sh's run_create calls
      # bridge_ensure_codex_agent_slash_commands (next to bridge_ensure_codex_
      # agent_hooks, gated on engine==codex) to deploy the agb-* slash commands
      # + bridge-role permission profiles into the agent-scoped .codex/ tree.
      # Pull the Track C smokes on every bridge-agent.sh move so a refactor
      # cannot drop the wire-up or let it leak into the controller ~/.codex.
      add_required codex-slash-commands codex-permission-profiles
      # Issue #1497 (P1): bridge-run.sh now exports BRIDGE_AGENT_HOME_RESOLVED
      # (the v2-aware identity home) alongside BRIDGE_AGENT_WORKDIR_RESOLVED at
      # BOTH the initial-launch and roster-refresh relaunch sites, and
      # bridge-agent.sh::emit_agent_records_json now emits a resolver-derived
      # `agent_home`. Pull 1497-p1-home-resolver on every bridge-run.sh /
      # bridge-agent.sh move so a refactor cannot drop either export site or
      # the agent_home JSON column (the bash→Python home channel #1497 P1 adds).
      add_required 1497-p1-home-resolver
      # Issue #1520: bridge-run.sh's shared (non v2-secret-env) final-launch
      # site now exports the per-agent CLAUDE_CONFIG_DIR (Claude only, HOME
      # unchanged) via bridge_run_shared_launch so shared-mode Claude agents
      # read their own <agent-home>/.claude config instead of the operator
      # global ~/.claude.json. Pull 1520-shared-claude-config-dir on every
      # bridge-run.sh move so a refactor cannot drop the export (the smoke's
      # teeth assert the launched env goes empty without it) or let it leak
      # onto the codex shared launch.
      add_required 1520-shared-claude-config-dir
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
      # Issue #1205 (beta25 fast-follow): tool-policy.py::other_agent_homes()
      # now wraps root.iterdir() + candidate.is_dir() in an iso-UID-gated
      # try/except (returns [] under iso, re-raises for controller). Pull
      # the regression smoke whenever tool-policy.py moves so the fail-open
      # contract + the controller-side re-raise counter-test stay pinned.
      # Issue #6607 (v0.15.0-beta2 Lane η): the anchored admin
      # bridge-verb allowlist lives directly in tool-policy.py — pull
      # the regression smoke whenever the file moves so the verb shape
      # surface (allow path + shape-deny audit row + path-traversal /
      # malformed-flag rejection) stays pinned.
      # v0.15.0-beta4 Lane K (#1255 r2): hooks/tool-policy.py hosts
      # `_bash_command_has_read_intent` — a STRICT read-intent
      # whitelist that gates the admin roster carve-out. r1 shipped
      # this as a write-intent blacklist that codex r1 review showed
      # admitted unknown stage leaders (`python3 /tmp/mutator.py
      # <roster>`, `my-mutator <roster>`, `git commit -F <roster>`).
      # r2 flips it to a whitelist delegating to
      # `_is_read_intent_bash`. Pull K-beta4-nits whenever
      # tool-policy.py moves so a future PR cannot regress the admin
      # carve-out back to a blacklist or widen it into a write/leak
      # surface.
      # Issue #1442: PROTECTED_GLOBS in lib/system_config_paths.py now
      # covers the v2 per-agent-workdir layout
      # (data/agents/*/workdir/.discord|.telegram/access.json) alongside
      # the pre-v2 globs, so the #341 operator-gated `config get/set`
      # wrapper can actually edit per-agent channel-access files on a v2
      # install. Pull the v2-glob smoke whenever the wrapper or the
      # protected-path module moves so a future edit cannot regress the
      # v2 path back to `deny: path not in system-config protected list`
      # or drop the pre-v2 globs.
      add_required hooks agent-update v2-cross-class-read admin-hook-exemption tool-policy-roster-read-classify 1205-hook-iso-fail-open 6607-hook-admin-allowlist K-beta4-nits 1358-admin-credential-routine-exempt 1442-config-protected-globs-v2
      # Issue #1497 (P2): lib/system_config_paths.py::bridge_home_dir() now
      # delegates to lib/operator_home.py::operator_home() (the operator-home
      # SSOT). Pull 1497-p2-operator-home so a change to this module or the
      # tool-policy/config consumers cannot drift the operator-home resolution
      # off the canonical form (parity + footgun-guard teeth).
      add_required 1497-p2-operator-home
      add_integration integration-minimal
      ;;

    lib/operator_home.py|bridge_guard_common.py)
      # Issue #1497 (P2): lib/operator_home.py IS the operator-home SSOT, and
      # bridge_guard_common.py::bridge_home_dir() delegates to it via the
      # repo-root lib/ import seam. A change to either is a direct hit on the
      # canonical resolver / a delegating consumer — pull the P2 smoke so the
      # resolver form (strip+expanduser+empty-guard), the byte-identical
      # delegation, and the import seam cannot regress.
      add_required 1497-p2-operator-home hooks
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
      # Issue #1207: lib/bridge-isolation-helpers.sh's
      # `bridge_iso_run_path_under_allowlist` gained a read/probe-only
      # literal-prefix fallback for the stale-supp-groups class. Pull
      # 1207-stale-supp-groups-allowlist on every isolation-helpers move
      # so a future PR cannot regress (a) into letting write/publish
      # ops accept the fallback, (b) drop the iso-side existence probe,
      # or (c) drop the `..` reject ahead of the fallback.
      # v0.15.0-beta4 Lane A (#1272 + #1277 + #1279 + #1213): the
      # sanitized per-agent metadata writer
      # (`bridge_isolation_v2_write_agent_metadata`) lives in
      # lib/bridge-isolation-v2.sh, called from
      # lib/bridge-isolation-v2-reapply.sh's reapply tick + from
      # lib/bridge-agents.sh's prepare path. The smoke pins the
      # writer presence, the reader's array-slot assignment shape,
      # the getent-based config_dir fallback, the audit_dir_ensure
      # helper, and the session_id_detect_empty visibility emit.
      # Pull A-beta4-iso-path-resolution on every isolation-lib move
      # so a regression at any layer cannot re-introduce the iso UID
      # context's empty-array → controller-view-path drift.
      # Issue #1278 (v0.15.0-beta4 Lane H): the per-UID
      # `known_marketplaces.json` ownership/mode contract that the
      # H-beta4 smoke pins depends directly on the matrix rows in
      # lib/bridge-isolation-v2.sh (`isolated-plugin-manifests` at
      # mode 2770 root:ab-agent-<a> — the parent dir is the rename
      # surface for iso UID writes) and on the writer in
      # lib/bridge-agents.sh (`bridge_write_isolated_known_marketplaces_
      # catalog`, also reached transitively via the bridge-agents.sh
      # all-required branch). Pull H-beta4-iso-ownership on every
      # isolation-lib move so a matrix-row change that re-tightens the
      # parent dir mode (or a refactor of the writer's chown/chmod
      # block) immediately fails the regression contract.
      # v0.15.0-beta4 Lane G (#1270): the new
      # `bridge_isolation_v2_normalize_workdir_profile_group` helper
      # lives in lib/bridge-isolation-v2.sh and is invoked from the
      # `agent create` post-materialize path (bridge-agent.sh) and the
      # `bridge_isolation_v2_backfill_workdir_identity` migrate path
      # (lib/bridge-isolation-v2-workdir-backfill.sh). Pull
      # G-beta4-watchdog-noise on every isolation-lib move so the
      # CLAUDE.md group=ab-agent-<a> mode 0660 contract stays pinned at
      # PR time.
      # v0.15.0-beta4 Lane J (#1281): the CLAUDE.md / docs/developer-
      # handover.md / OPERATIONS.md "Working with isolated agents
      # (iso v2)" section cross-references the iso v2 boundary
      # contract that lives in lib/bridge-isolation-v2.sh + helpers.
      # The J-beta4 smoke pins all three docs carry the section.
      # Pull on every isolation-lib move so a refactor cannot silently
      # invalidate the doc cross-link (the doc says iso UID can't read
      # X; the matrix row is what makes that true).
      # Issue #1297 (v0.15.0-beta5 Lane α): lib/bridge-isolation-v2-
      # workdir-backfill.sh's call into
      # `bridge_isolation_v2_normalize_workdir_profile_group` was gated
      # on writes-this-pass, so the beta3 → beta4 upgrade left existing
      # workdir files at `0600 iso-uid:controller-gid` →
      # bridge-start.sh grep on CLAUDE.md failed EACCES → restart +
      # rollback both failed. Lane α drops the gate so the normalize
      # runs for every iso v2 agent on every back-fill pass. Pull
      # α-beta5-upgrade-backfill-normalize on every isolation-lib move
      # so the gate cannot be re-introduced + the helper's idempotency
      # contract under the unconditional call stays pinned.
      # Issues #1315 + #1316 (v0.15.0-beta5-2 Lane θ): extends the
      # Lane α normalize to ALSO cover the `.claude/` directory tree
      # (`.claude/`, `.claude/plugins/`, `.claude/session-env/` →
      # `ab-agent-<a>:2770`) and `known_marketplaces.json` (legacy
      # `root:ab-agent-<a> 0640` → `iso-uid:ab-agent-<a> 0660` so the
      # iso UID's plugin-cache rename succeeds on first start). New
      # helpers `bridge_isolation_v2_chgrp_dir_iso_group` and
      # `bridge_isolation_v2_chown_file_iso_uid` mirror the file-iso-
      # group helper's stat-skip idempotency contract. Pull
      # beta5-2-theta-upgrade-backfill-perms on every isolation-lib
      # move so the directory walk + chown call cannot regress to a
      # files-only loop or drop the stat-skip.
      # Issue #1329 (v0.15.0-beta5-2 Lane μ M6): same normalize fn
      # also walks the channel state dirs (`.discord` / `.telegram`
      # / `.teams` / `.ms365` / `.mattermost`) and their credential
      # files (`.env`, `access.json`, `state.json`, `mcp.json`) → set
      # group `ab-agent-<a>` + mode 0640 (group-read, world-none). The
      # beta5-2-mu-cron-channel-creds smoke pins the fileset, the
      # mode (0640 NOT 0644 — edge case 6), and the absence of
      # widening tokens. Pull on every isolation-lib move so the
      # normalize cannot regress silently.
      # v0.15.0-beta5 Lane gamma (#1298): the stat helper
      # `bridge_linux_normalize_isolated_home_contract` (lib/bridge-agents.sh)
      # now emits structured per-target status lines (`denied`/`error`/
      # `missing`/`ok`/`changed`/`failed`) on EVERY early-return path so
      # the reconcile row dispatcher can distinguish runtime probe
      # failure from filesystem drift. The row dispatcher
      # (`_bridge_iso_reconcile_row_agent_home_contract` in this lib)
      # classifies `denied`/`error` -> degraded row + rc=0 (NOT drift),
      # `missing` -> missing row + rc=1 (drift), and the no-line branch
      # also degrades. Additionally, `bridge_isolation_v2_apply_install_
      # tree_matrix`'s manual-mode parity branch implicitly expands to
      # --all-agents on `reason=manual` so `agent-bridge isolation
      # reconcile --apply` (no --agent / no --all) reports agent-home-
      # contract rows instead of silently returning overall_rc=0. Pull
      # gamma-beta5-reconcile-helper-status on every isolation-lib move
      # so a refactor at either site (helper-side per-target emit, or
      # caller-side classifier, or manual-mode parity guard) is caught
      # at PR time.
      # v0.15.0-beta5-3 Track L (#1342): lib/bridge-isolation-v2.sh's
      # bridge_isolation_v2_write_agent_state_marker gained (1) a Path A0
      # equality gate that DERIVES the expected iso UID from
      # `agent-bridge-<X>` when the roster snapshot did not populate
      # os_user (the Stop-hook-inside-iso-UID + #1048-indeterminate case
      # that re-emitted the per-stop "ensure_matrix_path failed" warning),
      # and (2) a Path B ensure_matrix_path disambiguation (privileged
      # failure → genuine-drift hard-fail; unprivileged → best-effort
      # direct write, no warning). Pull 1342-write-state-marker-matrix on
      # every isolation-lib move so a future revert at either gate
      # (A0-derive removal, Path B classifier removal) re-introduces the
      # every-stop warning regression at PR time.
      add_required isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering 1495-settings-invalid-hook-key isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip isolation-v2-marker-only-migrate isolation-v2-macos-noise-suppression isolation-v2-platform-discriminator isolation-v2-bucket2-gates layout-resolver-marker-over-env 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions 1021-isolation-v2-shared-plugin-perms 1025-isolated-create-agent-env-install 1077-migrate-iso-v2-data-dir 1113-watchdog-legacy-backfill 1158-marker-controller-uid-exemption 1158-marker-load-order 1161-marker-readable-by-isolated 1165-track-b-sudo-escalate-and-state 1342-write-state-marker-matrix launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup phase2-install-tree-reconciler phase3-agent-home-contract 1207-stale-supp-groups-allowlist A-beta4-iso-path-resolution H-beta4-iso-ownership G-beta4-watchdog-noise J-beta4-workflow-docs α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-theta-upgrade-backfill-perms 1506-isolate-normalize 1520c-create-isolate-profile-publish 1513-iso-teams-prune-eacces
      # v0.15.0-beta5-2 Lane κ (#1325 M2): lib/bridge-isolation-v2-
      # reconcile.sh hosts the manual-mode parity branch (#1298 Gap B)
      # that makes `agent-bridge isolation reconcile --check` AND --apply
      # both implicitly expand to --all-agents on `reason=manual`. The
      # Lane κ smoke functionally verifies the parity branch is
      # mode-agnostic (does NOT gate on `mode == apply`) — gamma-beta5
      # only static-grepped the branch. Pull on every reconcile-lib move
      # so a future refactor cannot silently regress the --check arm
      # back to the pre-#1298 silent-skip shape.
      add_required beta5-2-kappa-state-audit-reconcile
      # Issue #1359 (Track H): lib/bridge-isolation-v2.sh now emits the
      # `state-cron-staging` matrix row (mode 2770 group=ab-shared) that
      # gives every iso UID group-write access to the new staging dir.
      # Pull 1359-cron-create-iso-staging on every isolation-lib move so
      # a row-reordering or scope-gate change cannot silently regress the
      # iso staging delegation contract.
      # v0.15 split-brain fix: lib/bridge-isolation-v2-migrate.sh gained
      # bridge_isolation_v2_migrate_shared_backfill (the platform-agnostic
      # shared-tree data move that runs before every apply_for_upgrade skip
      # branch) + its sentinel writer, and lib/bridge-isolation-v2.sh gained
      # the sentinel-gated BRIDGE_SHARED_DIR resolver flip. Pull
      # isolation-v2-shared-mover on every isolation-lib + migrate move so a
      # future revert of the early backfill call (which would re-strand the
      # active shared tree at the legacy path on macOS) or the sentinel gate
      # is caught at PR time.
      add_required isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering 1495-settings-invalid-hook-key isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip isolation-v2-marker-only-migrate isolation-v2-macos-noise-suppression isolation-v2-platform-discriminator isolation-v2-bucket2-gates layout-resolver-marker-over-env 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions 1021-isolation-v2-shared-plugin-perms 1025-isolated-create-agent-env-install 1077-migrate-iso-v2-data-dir 1113-watchdog-legacy-backfill 1158-marker-controller-uid-exemption 1158-marker-load-order 1161-marker-readable-by-isolated 1165-track-b-sudo-escalate-and-state 1342-write-state-marker-matrix launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup phase2-install-tree-reconciler phase3-agent-home-contract 1207-stale-supp-groups-allowlist A-beta4-iso-path-resolution H-beta4-iso-ownership G-beta4-watchdog-noise J-beta4-workflow-docs α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-theta-upgrade-backfill-perms beta5-2-mu-cron-channel-creds 1359-cron-create-iso-staging isolation-v2-shared-mover 1506-isolate-normalize 1520c-create-isolate-profile-publish 1513-iso-teams-prune-eacces
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
      # v0.15.0-beta5-2 Lane ν (#1333 L3): lib/bridge-skills.sh:377-...
      # gained the opt-in setpriv fallback (BRIDGE_SKILLS_USE_SETPRIV=1)
      # + actionable warn-on-double-fail. Pull beta5-2-nu-daemon-path-
      # quarantine on every lib/bridge-skills.sh move so a future PR
      # cannot silently regress the opt-in gate or the diagnostic
      # tokens back to the pre-#1333 silent skip.
      add_required isolated-skills-sync isolation launch 1151-step-a-helper 1151-r2-sudo-escalate 1155-bootstrap-skill-guard beta5-2-nu-daemon-path-quarantine
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
      # v0.15.0-beta3 Lane A12 (#1252): lib/bridge-channels.sh's
      # `bridge_write_idle_ready_agents` now self-heals
      # `state/agents/<a>/` AND emits the structured `[nudge-skip]
      # agent=<a> task=- reason=state-dir-missing evidence=<dir>` line
      # when the self-heal fails. Pull A12-beta3 on every channels-lib
      # move so the silent-drop class (patch's beta2 OOTB: one nudge in
      # 75min uptime, no further log evidence) cannot regress.
      # v0.15.0-beta5-1 Lane 3 (#1307): the MCP-liveness probe
      # path (bridge_agent_missing_plugin_mcp_channels_csv +
      # bridge_plugin_mcp_descendant_ready_for_item) lives in
      # lib/bridge-agents.sh; lib/bridge-channels.sh hosts the
      # channel-status wake/notify surface that the giveup ledger
      # gates. A change here could shift the probe shape under
      # process_mcp_liveness_giveup_recovery, so pull
      # mcp-liveness-giveup-auto-clear on every channels-lib move
      # so the recovery contract (audit emit, ledger fields,
      # transition observer) cannot regress through a probe-shape
      # change.
      # v0.15.0-beta5-2 Lane ι (#1321 H3): the new MCP-recovery
      # miss-queue drain path replays accumulated miss-notify entries
      # through the canonical `bridge_notify_send` wake path on
      # `plugin_mcp_liveness_recovered`. Pull
      # beta5-2-iota-daemon-escalation-family on every channels-lib /
      # notify move so a future PR cannot regress the redeliver +
      # dedup_key audit emit contract (the structured signal
      # operators correlate against `plugin_mcp_liveness_recovered`).
      add_required channel-plugins bridge-notify-no-default-discord-875 1165-track-a-scaffold-modes 1165-track-b-sudo-escalate-and-state 1342-write-state-marker-matrix A12-beta3-1246-1252-daemon-supp-group-and-state-dir mcp-liveness-giveup-auto-clear beta5-2-iota-daemon-escalation-family
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
      # Issue #1217 (beta27 Track E): hooks/pre-compact.py
      # `_write_started_marker` now wraps the marker write sequence
      # (mkdir + tempfile + replace) in an iso-UID-gated try/except
      # that emits audit telemetry
      # (`hook_permission_fail_open.precompact.started_marker`) before
      # returning. The beta27-E smoke pins both the iso-side audit
      # path and the controller-side negative test (no audit emitted).
      add_required pre-compact-envelope-roundtrip hooks upgrade-shared-settings-propagate beta27-E-hook-permission-fail-open-markers
      # Issue #1497 (P2): pre-compact.py's _bridge_home() is INTENTIONALLY NOT
      # delegated to the operator-home SSOT (its walk-up fallback is load-bearing
      # and divergent — deferred to P3). Pull 1497-p2-operator-home so the P2
      # parity gate re-runs whenever this hook moves, guarding both the migrated
      # surfaces and the documented deferral boundary.
      add_required 1497-p2-operator-home
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

    bootstrap-memory-system.sh)
      # Issue #1222 (v0.15.0 Lane H): step_rebuild_one's apply path now
      # branches on linux-user isolation. The H smoke pins:
      #   - bridge-lib.sh sourcing (so iso helpers are available)
      #   - bridge_agent_linux_user_isolation_effective gate
      #   - bridge_isolation_run_as_agent_user_via_bash invocation
      #   - the iso inline script covers the FULL rebuild/publish block
      #     (rm + rebuild-index + validate + mkdir + mv) — wrapping
      #     only the leading `rm` or only the trailing `mv` was the
      #     pre-fix shape and would re-trip the Permission denied bug
      #   - non-iso branch preserved (no regression for shared installs)
      #   - exit codes inside the iso script stay >= 10 so the wrapper's
      #     +2 shift on rc<3 cannot collide with its pre-flight band
      #   - no broad `--op rm` was added to bridge_iso_run (codex
      #     scoping correction: broad unlink is a v2 security surface)
      # The Linux+sudo gated T8 layer additionally stands up a real
      # `agent-bridge-h_smoke` user + ab-agent-h_smoke group, scaffolds
      # the iso-owned `memory/` at mode 2770 with a stale
      # `index.sqlite.rebuilding-*` file, and asserts the cross-boundary
      # asymmetry (controller rm fails, sudo-as-iso rm succeeds) is
      # actually reproducible on this host.
      #
      # v0.15.0-beta4 Lane J (#1263): bootstrap-memory-system.sh's
      # arg-parsing block now honors the BRIDGE_WIKI_GRAPH_ENABLED env
      # gate (default-off on fresh installs, opt-in via env=1, explicit
      # opt-out via env=0). J-beta4-workflow-docs (T7/T8/T8b) pins the
      # gate semantics + the `wiki_graph_skipped=1` stdout marker so a
      # future PR cannot regress the opt-in contract or break
      # back-compat for installs that already provisioned wiki-graph.
      #
      # Issue #1474: bootstrap-memory-system.sh's per-agent
      # `cron create --agent <peer>` is the cross-agent provisioning path
      # the admin exemption serves. Pull 1359-cron-create-iso-staging (it
      # now carries the #1474 admin-exemption + env-forgery-refused
      # security cases) so a future bootstrap change re-runs the gate.
      #
      # Issue #1399: the admin-extraction `grep|head|sed` pipeline near the
      # top of the script must treat an admin-less roster as an EMPTY
      # result, not a fatal error — under `set -euo pipefail` a no-match
      # grep (rc=1) otherwise aborts the whole script before the `patch`
      # default applies. 1399-bootstrap-memory-no-admin pins the brace-
      # group `|| true` guard (scoped to the grep, not the whole pipeline)
      # + the end-to-end no-abort behavior on a fresh admin-less install.
      add_required H-bootstrap-memory-iso-rebuild J-beta4-workflow-docs 1359-cron-create-iso-staging 1399-bootstrap-memory-no-admin
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

    hooks/codex-pre-compact.py|hooks/codex-post-compact.py|hooks/codex-subagent-start.py|hooks/codex-subagent-stop.py|hooks/codex-permission-request.py)
      # #8945 Track B — expanded Codex hook coverage (PreCompact /
      # PostCompact / SubagentStart / SubagentStop / PermissionRequest), all
      # audit-only by default. Each new hook has a focused smoke; the
      # PermissionRequest smoke additionally pins the security contract
      # (redaction, dedupe/throttle, no-default-side-effect, and the
      # auto-queue teeth). codex-companion-hooks is pulled too because it is
      # the source-of-truth for the ensure-codex-hooks render wiring these
      # events extend. This arm precedes the generic hooks/* catch-all so a
      # change to one of these hooks runs the targeted Track B smokes.
      add_required codex-precompact-hook codex-postcompact-hook codex-subagent-hooks codex-permission-request-hook codex-companion-hooks hooks
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
      # Issue #1205 (beta25 fast-follow): hooks/bridge_hook_common.py
      # grew an iso-UID-gated try/except around save_timestamp_state's
      # write sequence (mkdir + write + chmod + replace) plus a new
      # public under_isolated_uid() wrapper. hooks/prompt_timestamp.py
      # and hooks/session_start.py call save_timestamp_state transitively
      # so the same regression smoke pins the fail-open contract for
      # both call sites. Pull 1205-hook-iso-fail-open on every
      # hooks/*  + bridge-hooks.* move so a future patch cannot silently
      # weaken the gate.
      # Issue #1212 (beta26): bridge-hooks.py
      # `agent_bridge_development_plugin_settings` now accepts any
      # `plugin:<name>@<marketplace>` spec (not just @agent-bridge)
      # and emits matching `extraKnownMarketplaces` entries when the
      # marketplace mirror dir exists. 1212-bridge-hooks-marketplace
      # pins the filter shape + the 4 safety guards (bare spec, empty
      # name/marketplace, unsafe id, missing mirror) + idempotency.
      # Issue #1213 (beta26): hooks/bridge_hook_common.py drops the
      # mode-string env-var dependency from both `_under_isolated_uid`
      # and `current_isolated_agent` (the bash assoc-array name
      # collision in bridge-run.sh:212 makes the export structurally
      # impossible). 1213-iso-uid-predicate pins the UID-side predicate
      # + grep-asserted source guard against reintroducing the
      # BRIDGE_AGENT_ISOLATION_MODE check in either function body.
      # Issue #1217 (beta27 Track D): hooks/bridge_hook_common.py
      # `agent_timestamp_enabled` now reads BRIDGE_AGENT_INJECT_TIMESTAMP_
      # RESOLVED first with a fallback to the bare name (same
      # alias pattern as BRIDGE_AGENT_CLASS_FOR_HOOK). beta27-D-inject-
      # timestamp-resolved pins both the bash collision repro and the
      # Python read order.
      # Issue #1217 (beta27 Track E): hooks/pre-compact.py
      # `_write_started_marker` and hooks/session_start.py
      # `_write_compact_completed_marker` now wrap their write
      # sequences in an iso-UID-gated try/except with audit telemetry
      # (`hook_permission_fail_open.precompact.started_marker` /
      # `hook_permission_fail_open.session_start.completed_marker`).
      # beta27-E-hook-permission-fail-open-markers pins both wrappers
      # and a controller-side negative test (no audit emitted).
      # Issue #1199: hooks/bridge_hook_common.py::queue_summary now counts
      # ONLY queued tasks (was queued+claimed), so the Stop-hook ACTION
      # REQUIRED text nudge (mark-idle.sh → check-inbox.py --format text)
      # never re-fires for a just-claimed task; hooks/check_inbox.py keeps
      # the codex Stop-hook anti-abandonment gate via open_claimed_count /
      # top_claimed_row. Pull 1199-action-required-claimed-skip on every
      # hooks/* move so a future patch cannot re-add claimed to the ACTION
      # REQUIRED count or drop the codex continue-claimed-work block.
      # #8945 Track B: bridge-hooks.py's cmd_ensure_codex_hooks now renders 5
      # additional Codex events (PreCompact / PostCompact / SubagentStart /
      # SubagentStop / PermissionRequest) at hooks/codex-*.py. Pull the Track B
      # per-hook smokes so a change to the renderer re-runs the render-wiring +
      # PermissionRequest security (redaction / throttle / no-side-effect / teeth)
      # assertions.
      # Issue #1453: bridge-hooks.py's `agent_bridge_development_plugin_settings`
      # now parses the public `--channels` alias (not only the internal
      # `--dangerously-load-development-channels` flag) via the shared
      # `launched_channel_plugin_specs` helper, and both shared/isolated
      # renderers now re-assert managed channel-plugin enables AFTER the
      # preserved-key merge (`_repair_sticky_false_channel_enables`) so a
      # stale `enabledPlugins[<channel>]=false` no longer silently drops
      # inbound channel delivery. 1453-channel-sticky-false-inbound pins both
      # the alias parse (fix A) and the sticky-false repair + no-over-reach
      # (fix B), with teeth on each.
      add_required hooks upgrade-shared-settings-propagate managed-autocompact-window isolated-settings-rendering 1495-settings-invalid-hook-key 1453-channel-sticky-false-inbound per-agent-settings-rendering shared-settings-preserve-user-keys admin-hook-exemption 1067-codex-provisioning 1120-controller-ops-isolated 1139-link-shared-settings-perm 1145-ensure-dir-actually-sudo 1145-option1-deferral-guard 1151-step-a-helper 1165-track-c-hooks-and-dispatcher 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp 1205-hook-iso-fail-open 1212-bridge-hooks-marketplace 1213-iso-uid-predicate beta27-D-inject-timestamp-resolved beta27-E-hook-permission-fail-open-markers 1358-admin-credential-routine-exempt 1199-action-required-claimed-skip codex-precompact-hook codex-postcompact-hook codex-subagent-hooks codex-permission-request-hook
      # Issue #1497 (P1): hooks/bridge_hook_common.py::agent_default_home now
      # reads BRIDGE_AGENT_HOME_RESOLVED first, is v2-aware, falls back to the
      # roster CLI (`agent show --json agent_home`), and no longer lets a stale
      # legacy `agents/<a>` dir short-circuit ahead of v2. The shared
      # _resolved_env_path / _resolve_home_via_roster helpers keep the home and
      # workdir channels from drifting. Pull 1497-p1-home-resolver on every
      # hooks/* move so the RESOLVED-first order, the split-brain immunity, and
      # the bash↔Python home parity cannot silently regress.
      add_required 1497-p1-home-resolver
      add_required 1497-v2-dynamic-handoff
      # Issue #1497 (P2): hooks/bridge_hook_common.py::bridge_home_dir() now
      # delegates to the operator-home SSOT and the module self-sets-up lib/ on
      # sys.path. Pull 1497-p2-operator-home on every hooks/* move so the
      # every-session operator-home resolution + import seam cannot regress.
      add_required 1497-p2-operator-home
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
      # Issue #1297 (v0.15.0-beta5 Lane α): bridge-upgrade.sh's
      # workdir-backfill stage invokes
      # `bridge_isolation_v2_backfill_workdir_identity`, whose iso v2
      # normalize call is no longer gated on writes-this-pass. Pull
      # α-beta5-upgrade-backfill-normalize whenever the upgrade entry
      # moves so the beta3 → beta4 EACCES-on-restart regression cannot
      # be re-introduced upstream of the helper.
      # Issues #1315 + #1316 (v0.15.0-beta5-2 Lane θ): the same
      # backfill stage now also normalizes the `.claude/` directory
      # tree and `known_marketplaces.json` ownership. Pull beta5-2-
      # theta-upgrade-backfill-perms whenever the upgrade entry moves
      # so the directory walk + chown contract cannot regress.
      # v0.15.0-beta5 Lane gamma (#1298): bridge-upgrade.sh's iso-reconcile
      # stage is the original surface that emitted the 4 `[failed]` rows
      # + WARN noise. The lane gamma fix lives in lib/bridge-agents.sh
      # (helper) + lib/bridge-isolation-v2-reconcile.sh (caller +
      # manual-mode parity); pull the regression smoke on every
      # bridge-upgrade.sh move so the upgrade-time iso-reconcile call site
      # cannot regress without the smoke catching the contract drift.
      # Issue #1328 (v0.15.0-beta5-2 Lane μ M5): bridge-upgrade.sh now
      # invokes `bridge_cron_state_dir_verify_and_migrate` as a backfill
      # step so an operator-relocated `BRIDGE_CRON_STATE_DIR` migrates
      # the old tree at upgrade time. The beta5-2-mu-cron-channel-creds
      # smoke pins the helper's edge-case matrix (no anchor, anchor
      # matches, anchor differs + old empty, anchor differs + both
      # populated → conflict bail) and the run_sync wiring. Pull on
      # every bridge-upgrade.sh move so the backfill call cannot
      # silently regress.
      # #8945 Track D: bridge-upgrade.sh gained
      # bridge_upgrade_emit_codex_version_advisory — records codex --version
      # into state/upgrade/codex-version.last and surfaces a NON-fatal
      # operator advisory on a major/minor change (skips silently when codex
      # is absent). Pull codex-version-surface on every upgrade-entry move so
      # the first-seen / patch-bump / major-minor / suppress / dry-run matrix
      # cannot regress (and the extraction seam stays bound to the live
      # function body).
      # Issue #1516: bridge-upgrade.sh gained bridge_upgrade_compare_versions
      # + a downgrade guard on the apply path (refuse a silent BACKWARD move
      # — e.g. a default-stable bare `upgrade --apply` resolving a beta
      # install back to a lower stable — unless --allow-downgrade). Pull
      # 1516-upgrade-downgrade-guard on every upgrade-entry move so the
      # comparator edges, the abort+message, the --allow-downgrade override,
      # and the forward/same-version/unparseable proceed paths stay pinned.
      add_required upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-pair-server-auto-provision telegram-relay-residue-cleanup upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering upgrade-isolated-agent-migrate 864-upgrade-perm-regressions cleanup-payload-empty-stdin-872 isolation-v2-marker-only-migrate 1067-codex-provisioning 1113-watchdog-legacy-backfill 1144-upgrade-complete-task phase2-install-tree-reconciler phase3-agent-home-contract α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-theta-upgrade-backfill-perms beta5-2-mu-cron-channel-creds codex-version-surface codex-doctor 1516-upgrade-downgrade-guard
      add_integration integration-minimal
      ;;

    bridge-release.py)
      # bridge-release.py owns the full semver 2.0.0 comparator
      # (compare_semver / parse_semver_full). J-beta4-workflow-docs
      # (T9c/T9d) pins the prerelease-ordering chain that the
      # release-notification path depends on. Issue #1516 added a `compare`
      # subcommand that bridge-upgrade.sh's downgrade guard calls; pull
      # 1516-upgrade-downgrade-guard too so a comparator change cannot
      # silently flip the beta>prior-stable / beta<same-line-final ordering
      # the guard relies on.
      add_required J-beta4-workflow-docs 1516-upgrade-downgrade-guard
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

    bridge-auth.py|bridge-auth.sh)
      # v0.15.0-beta4 Lane F r2 — codex r1 BLOCKING #3 (2026-05-27).
      # bridge-auth.py and bridge-auth.sh are the canonical sites for
      # the controller-credentials aliveness gate (#1261), the
      # per-agent aliveness propagation through the wrapper, and the
      # token-schema (fresh / near_expiry / expired / no_expires_at).
      # The F-beta4-oauth-bootstrap smoke pins:
      #
      #   - controller_credentials_aliveness pure-Python classification
      #     across all four states (T1).
      #   - cmd_sync_agent refuses to propagate an expired credential
      #     (T7) — the writer-side teeth that protects every periodic
      #     sync from distributing a stale token.
      #   - wrapper JSON carries per-agent aliveness/remaining_ms (T10)
      #     so daemon-side auditing can branch.
      #
      # daemon-periodic-token-sync covers the bridge-daemon.sh tick
      # that consumes the wrapper output and writes the
      # controller_credentials_aliveness audit row + near_expiry
      # daemon_warn line.
      add_required F-beta4-oauth-bootstrap daemon-periodic-token-sync 1358-admin-credential-routine-exempt
      add_integration integration-minimal
      ;;

    bridge-daemon-helpers.py)
      # v0.15.0-beta4 Lane F r2 — codex r1 BLOCKING #3.
      # bridge-daemon-helpers.py now hosts ``sync-aliveness-parse``
      # alongside the existing ``sync-status-parse`` subcommand. The
      # F-beta4 smoke + daemon periodic-sync smoke both exercise the
      # parser; pull both whenever the helper moves so a future PR
      # cannot regress either contract.
      #
      # v0.15.0-beta4 Lane I (#1262 Gap 3): the new ``a2a-stuck-decide``
      # subcommand is the decision + ledger helper for
      # process_a2a_outbox_stuck_scan_tick. The I-beta4-a2a-3-gaps
      # smoke exercises it directly (stuck emit, cooldown suppress,
      # cooldown expiry re-emit, ledger pruning) so a future PR cannot
      # silently regress the helper output or the atomic ledger
      # rewrite.
      # v0.15.0-beta5-1 Lane 3 (#1307): the MCP-liveness giveup
      # recovery tick in bridge-daemon.sh consumes the existing
      # bridge-daemon-helpers.py shape only indirectly (via the
      # audit-write path). Register mcp-liveness-giveup-auto-clear
      # here so a helpers refactor that subtly changes the audit
      # subprocess contract re-exercises the recovery tick's emit
      # path.
      add_required F-beta4-oauth-bootstrap daemon-periodic-token-sync daemon queue I-beta4-a2a-3-gaps mcp-liveness-giveup-auto-clear
      # Issue #1936 (gap #4): bridge-daemon-helpers.py hosts the
      # ``human-followup-queued-state`` subcommand that classifies a
      # queued cron followup as human-facing (delivery_intent=
      # forward_to_user / legacy needs_human_followup). The 1936 smoke
      # sources this helper directly; pull it on every
      # bridge-daemon-helpers.py move so a future PR cannot regress the
      # classifier the attached-followup escalation depends on.
      add_required 1936-forward-followup-attached-escalation
      # Issue #1468: bridge-daemon-helpers.py hosts the
      # ``usage-probe-result-parse`` subcommand that classifies the native
      # usage-probe result for the `usage_probe` audit row (the §5 observability
      # path) and feeds the 429 near-limit signal flow. Pull the 1468 smoke on
      # every helpers move so a future PR cannot silently regress the parser the
      # proactive-rotation observability depends on.
      add_required 1468-usage-429-positive-signal
      add_integration integration-minimal
      ;;

    bridge-usage-probe.py|bridge-usage.sh|bridge-usage.py)
      # Issue #1437 PRIMARY (native proactive OAT-rotation probe) + Issue #1468
      # (treat a genuine usage-endpoint 429 rate_limit_error as a POSITIVE
      # near-limit rotation signal). These three files are the probe→cache→
      # monitor rotation path: bridge-usage-probe.py performs the GET + maps the
      # cache (and, for #1468, persists the synthetic near-limit 429-signal
      # idempotently), bridge-usage.sh wraps the credential-safe invocation +
      # emits the usage_probe audit row, and bridge-usage.py is the monitor that
      # turns the cache into rotation candidates. Pull BOTH the 1437 and 1468
      # smokes on any move so a future refactor cannot regress the credential
      # safety, the 429-signal contract, the per-window idempotence (no
      # pool-loop), or the rotation-candidate flow without CI catching it.
      add_required 1437-native-usage-probe 1468-usage-429-positive-signal
      add_required daemon daemon-periodic-token-sync
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
      #
      # v0.15.0-beta1 Lane I: bridge-init.sh now lands a useful default
      # admin description (replacing the terse `<admin> admin role`
      # placeholder) so downstream agents reading the roster on a fresh
      # install see a real role sentence. Pull I-agent-description-roster
      # on every bridge-init.sh move so the default cannot regress back
      # to the terse string.
      # v0.15.0-beta4 Lane F (#1230): bridge-init.sh's `[init]` log lines
      # are now stderr-routed so the `--json` contract (stdout = data
      # only) holds end-to-end. The F-beta4-oauth-bootstrap smoke pins
      # the stderr-routing invariant + parses the dry-run JSON to catch
      # any future leak. Pull on every bridge-init.sh move so a regression
      # cannot reintroduce bridge-bootstrap.sh's JSONDecodeError surface.
      # Same lane also rewrites the install-daemon-systemd.sh mode-parsing
      # block here, so the smoke covers that wiring too.
      #
      # v0.15.0-beta4 Lane G (#1266): bridge-init.sh now writes
      # `state/agents/<admin>/onboarding-pending` after the admin create
      # so the watchdog's first tick treats the fresh-install drift as
      # priority=low instead of high. G-beta4-watchdog-noise pins both
      # the marker schema (T7) and the downstream fresh_install_only
      # downgrade path (T1).
      # Issue #1312 (v0.15.0-beta5-2 Lane ε): bridge-init.sh now emits a
      # startup-time refuse advisory when BRIDGE_TMUX_INJECT_SPOOL_ENABLED=0
      # is set on an iso v2 install without the FORCE escape hatch. Pull
      # beta5-2-epsilon-tmux-inject-busy on every bridge-init.sh move so the
      # advisory surface cannot regress, re-opening the CRITICAL data-loss
      # class flagged by the patch audit C6.
      # Issue #1492: lib/bridge-init-codex-pair.sh captures the admin's
      # workdir into the `<admin>-dev` pair's raw roster row at provisioning
      # time, which is the value bridge_agent_workdir later aligns to the
      # admin's effective v2 workdir. Pull 1492-admin-dev-pair-workspace-v2
      # whenever the pair-provisioning or init wiring moves so a future PR
      # cannot regress the documented shared-workspace pair-review contract.
      add_required admin-pair-server-auto-provision agent-create-caller-trust-gate upgrade-shared-settings-propagate managed-autocompact-window per-agent-settings-rendering I-agent-description-roster β-1231-1236-fresh-install-seed-sudoers F-beta4-oauth-bootstrap G-beta4-watchdog-noise beta5-2-epsilon-tmux-inject-busy 1492-admin-dev-pair-workspace-v2
      add_integration integration-minimal
      ;;

    bridge-bootstrap.sh|lib/bridge-tmux-ux.sh)
      # Issue #1058: bridge-bootstrap.sh sources lib/bridge-tmux-ux.sh and
      # runs bridge_setup_tmux_ux, which writes an idempotent managed tmux
      # UX block to ~/.tmux.conf. Pull the idempotency / graceful-degradation
      # smoke whenever either file moves so a future PR cannot regress the
      # in-place block replacement or the version/terminfo gating.
      #
      # v0.15.0-beta4 Lane F (#1230 + #1261): bridge-bootstrap.sh now
      # carries the OAT advisory (#1261) AND captures bridge-init.sh's
      # stdout via $() to parse the JSON payload — any leaked log line
      # on the init stdout re-introduces the JSONDecodeError surface
      # documented in #1230. F-beta4-oauth-bootstrap pins both the
      # advisory presence and the dry-run JSON parse.
      #
      # v0.15.0-beta4 Lane I (#1262 Gap 1): bridge-init.sh now accepts
      # `--enable-a2a` and emits an `a2a_status` field in the JSON
      # payload. The smoke pins the flag wiring + JSON field + stderr
      # routing for the `[init] --enable-a2a:` log lines so a future
      # PR cannot silently leak them onto stdout.
      # v0.15.0-beta4 Lane J (#1263): bridge-bootstrap.sh now also
      # carries the wiki-graph + librarian opt-in advisory (text mode)
      # and a structured `wiki_graph` object in the --json payload.
      # J-beta4-workflow-docs (T7/T7b) asserts both surfaces are
      # present; pull on every bridge-bootstrap.sh move so the
      # advisory cannot regress to silent default.
      add_required 1058-bootstrap-tmux-ux agent-create-caller-trust-gate F-beta4-oauth-bootstrap I-beta4-a2a-3-gaps J-beta4-workflow-docs
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
      #
      # v0.15.0-beta5 Lane β (#1299): these helpers read Claude Code's
      # session JSON + transcripts which are written `0600 <iso-uid>:
      # ab-agent-<a>`. The bash shims now wrap the python invocation in
      # `sudo -n -u <iso-uid> -- bash -c 'exec python3 "$@"' bash …` so
      # the read operations succeed under iso v2. Beta-beta5-session-id-
      # detect-sudo pins the wrap shape (function-body grep + argv-
      # capture stub) and the data-shape / back-compat contract.
      # v0.15.0-beta5-1 (#1304): the empty-detect no-op guard inside
      # `bridge_persist_agent_state` blocks empty-overwrites when the
      # resolver returns rc=1 (e.g., 0600 jsonl unreadable because
      # `bridge_resolve_agent_iso_sudo_user` returned empty for this
      # PID). Pull the smoke whenever either helper moves so a change to
      # the read-side contract cannot regress the write-side guard.
      add_required 1015-resume-claude-config-dir 981-restart-session-resume-snapshot Beta-beta5-session-id-detect-sudo beta5-1-session-id-detect-race
      add_integration integration-minimal
      ;;

    scripts/python-helpers/resolve-cron-max-parallel.py)
      # Issue #1461: bridge_resolve_cron_dispatch_max_parallel delegates
      # the JSON-config + host-profile precedence (steps 2 + 3) to this
      # file-as-argv helper. A helper-only change (dropping the
      # cron_dispatch_max_parallel key read, breaking the server=3 default,
      # or no longer failing safe to the serial-1 floor) must still re-run
      # the #1461 smoke so the override mechanism cannot regress without CI
      # catching it.
      add_required 1461-cron-max-parallel-override
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

    scripts/python-helpers/prune-legacy-teams-mcp.py)
      # Issue #1513: this helper is invoked AS the iso UID by
      # bridge-run.sh against the legacy $BRIDGE_AGENT_HOME_ROOT/<a>
      # mirror. Its prune_file() now catches PermissionError/OSError
      # around is_file() and returns a non-fatal `skipped … reason=
      # stat-failed:<errno>` (L1) instead of crashing the launch on an
      # unreadable candidate. Any change to the helper must re-run the
      # #1513 smoke so the defensive skip cannot regress back to a
      # raising is_file() (which aborts the launch with EACCES).
      add_required 1513-iso-teams-prune-eacces
      add_integration integration-minimal
      ;;

    bridge-diagnose.sh|scripts/python-helpers/admin-set-config.py)
      # v0.15.0-beta4 Lane K:
      #   #1283 — bridge-diagnose.sh is now a thin deprecation shim;
      #         the `acl` subcommand exits non-zero with a notice
      #         pointing at `agent-bridge isolation reconcile`. The
      #         heavy ACL scanner helpers are removed.
      #   #1247 — scripts/python-helpers/admin-set-config.py is the
      #         file-as-argv writer for `agb admin set --auto-restart
      #         on|off` (footgun #11 — no heredoc-stdin). Pull
      #         K-beta4-nits whenever either file moves so a future
      #         PR cannot revive the ACL scanner or break the admin
      #         set CLI surface.
      add_required K-beta4-nits
      ;;

    lib/bridge-secret-scrub.sh)
      # #1454: the shared ambient-secret scrub/transit primitive. Pull the
      # bridge-lib.sh re-exec security canary on every change to it. (A change
      # to bridge-lib.sh itself already pulls the canary via the full static
      # suite below.)
      add_required 1454-bridge-lib-reexec-secret-canary
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
      # v0.15.0-beta2 lane ε: #1233 adds the `watchdog rescan` verb
      # (writes latest.md immediately, bypasses the daemon cooldown by
      # construction); #1237 adds the engine-native Codex contract
      # (validates AGENTS.md) and re-routes engines with no implemented
      # contract to `unsupported_engine_contract` instead of silent OK.
      # Pull ε-watchdog-rescan-codex on every watchdog move so a future
      # PR cannot regress either contract or accidentally re-introduce
      # the silent-codex / silent-unknown-engine path.
      # v0.15.0-beta4 Lane G (#1266 + #1270 + #1254): bridge-watchdog.py
      # gained fresh-install detection (priority=low downgrade signal),
      # static session_type onboarding_state suppression, restart-in-
      # progress marker reading (#1251 contract reuse), and the
      # scan_error category split (controller-cache-stale vs
      # iso-uid-side). Pull G-beta4-watchdog-noise on every
      # bridge-watchdog.py move so a future refactor cannot regress any
      # of those four contracts without the smoke catching it.
      # #8945 Track D: ε-watchdog-rescan-codex now also pins the shared-
      # workdir AGENTS.md home fall-back (a Codex `<admin>-dev` pair layered
      # onto a shared workdir materializes its per-agent AGENTS.md into its
      # agent_home, not the scanned workdir — the watchdog must treat the
      # entrypoint as present in EITHER location, while a genuinely missing
      # AGENTS.md still surfaces as drift). codex-doctor is pulled too so the
      # availability-gated codex env/auth smoke rides along on watchdog moves
      # that touch the codex contract surface.
      # #1520c (PR-C): bridge-watchdog.py's classify_scan_error_category now
      # routes a wrong-group / owner-only profile file to `publish-gap`
      # (BEFORE the iso readability probe) while PRESERVING genuine
      # `controller-cache-stale`. Pull 1520c-create-isolate-profile-publish
      # on every bridge-watchdog.py move so a refactor cannot re-order the
      # metadata check after the iso probe (which would mislabel the
      # create-time publish gap as cache-stale).
      add_required watchdog-profile-contract watchdog-registry-anchored watchdog-silence-stderr-capture 1108-watchdog-v2-workdir 1119-watchdog-perm-error 1113-watchdog-legacy-backfill ε-watchdog-rescan-codex G-beta4-watchdog-noise 1520c-create-isolate-profile-publish codex-doctor queue
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

    lib/agent-cli-helpers/show-format-json.py|lib/agent-cli-helpers/next-actions-tsv-to-json.py)
      # Issue #1360 (v0.15.0-beta5-2 Track I): show-format-json.py is the
      # `agent show --json` envelope assembler that now reads a 6th
      # file-as-argv input (`next-actions.json`) emitted by the
      # standalone next-actions-tsv-to-json.py helper. Both helpers
      # constitute the show-data pipeline downstream of
      # bridge_agent_next_actions_tsv. Pull the regression smoke
      # whenever either helper moves so the envelope shape
      # (.next_actions list of {run, reason, placeholder_safe: bool})
      # and the TSV→JSON boolean encoding cannot silently regress.
      #
      # v0.15.0-beta5-2 Lane E (#1357): show-format-json.py was also
      # extended with the iso_boundary_quickref payload (null for
      # shared-mode agents, list of rows for iso v2 effective agents).
      # Pull 1357-iso-boundary-quickref whenever the helper moves so a
      # future PR cannot silently regress the argv contract (5 args →
      # 6 args → 7 args) or drop the null/list dichotomy that downstream
      # consumers depend on.
      add_required 1360-onboarding-next-actions-persona 1357-iso-boundary-quickref
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
      # v0.15.0-beta5-2 Lane ξ (#1332 L2): bridge_layout_materialize_identity
      # now performs per-file atomic chgrp+chmod inside its cp loop via
      # bridge_isolation_v2_chgrp_file_iso_group so each materialized file
      # is iso-UID-readable BEFORE the next loop iteration — closing the
      # per-file race window the bulk post-materialize normalize alone
      # could not address. Pull beta5-2-xi-misc-fixes on every layout
      # move so the per-file pattern cannot silently regress to the
      # pre-#1332 controller-only cp -f.
      add_required 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair 1067-codex-provisioning v2-scaffold-home-and-workdir agent-doctor beta5-2-xi-misc-fixes
      add_integration integration-minimal
      ;;

    bridge-channels.py|bridge-channels.sh)
      # Issue #1060 (beta5 QA finding #1): bridge-channels.py's
      # remove-webhook-server now catches PermissionError/OSError quietly
      # so `agent create --isolate` no longer dumps a traceback. Cover the
      # channel-plugins regression smoke whenever the channel modules move.
      # Issue #1354 R2 (codex r1 SHOULD-FIX): the channel module path
      # owns `.<channel>/.env` write/read semantics that the setup
      # wizard's FD/stdin secret ingestion (#1354) plants secrets into.
      # Pull 1354-setup-teams-fd-password on every bridge-channels move
      # so a future channel-side refactor cannot silently regress the
      # wizard-to-channel credential contract.
      add_required channel-plugins channel-env-readiness 1354-setup-teams-fd-password
      add_integration integration-minimal
      ;;

    bridge-plugins.sh|bridge-dev-plugin-cache.py|lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py|lib/upgrade-helpers/plugins-list-json.py|lib/upgrade-helpers/plugins-list-pretty.py|lib/upgrade-helpers/plugins-marketplaces-json.py|lib/upgrade-helpers/plugins-marketplaces-pretty.py)
      # Issues #1201/#1202 (v0.14.5-beta24): bridge-plugins.sh grew
      # `bridge_plugins_seed_mirror_marketplace_root` so `agb plugins seed
      # --marketplace-root <path>` creates the controller-side mirror at
      # `$BRIDGE_SHARED_ROOT/plugins-cache/marketplaces/<id>/` that
      # `bridge_known_marketplace_info` (lib/bridge-agents.sh:1664)
      # consults before planting the iso UID's marketplace symlink.
      # bridge-dev-plugin-cache.py is the sync helper that
      # `bridge_plugins_cmd_seed` invokes — its output shape feeds the
      # mirror's downstream catalog manifests, so any move to either
      # callsite must re-run the regression smoke.
      #
      # Issue #1208 (v0.14.5-beta25): the D2 iso UID propagation in
      # bridge-plugins.sh now passes `BRIDGE_PLUGIN_LOCK_GROUP=$agent_group`
      # to `lib/upgrade-helpers/plugins-seed-merge-known-marketplace.py`
      # so the sidecar `known_marketplaces.json.lock` is created (or
      # normalized) as `root:$agent_group 0660` instead of `root:root
      # 0600`. The shell-side post-normalizer also self-heals
      # pre-existing beta24 bad locks. Pull
      # 1208-lock-metadata-normalize on every bridge-plugins.sh,
      # bridge-dev-plugin-cache.py, or helper move so the lock contract
      # cannot regress.
      #
      # Issue #1236 (v0.15.0-beta2 Lane ζ): bridge-plugins.sh grew the
      # read-only `agb plugins list [--json]` and `agb plugins
      # marketplaces [--json]` verbs. The four
      # `lib/upgrade-helpers/plugins-{list,marketplaces}-{json,pretty}.py`
      # helpers are pure-reader file-as-argv subprocess callees the new
      # verb arms invoke. Pull ζ-1236-plugins-list-marketplaces on any
      # move to bridge-plugins.sh, the sync helper, or any of the
      # plugins-* upgrade helpers so a helper-only change cannot
      # regress the empty/populated/--json/-h contract without the
      # smoke firing in required CI.
      #
      # Issues #1249 + #1250 (v0.15.0-beta3 Lane B): bridge-plugins.sh
      # grew the integrated `agb plugins add-marketplace <url-or-path>
      # [--channels ...]` verb (#1249) and a node_modules auto-install
      # pass inside `bridge_plugins_cmd_seed` (#1250) with `--no-auto-install`
      # opt-out. Both features touch the same dispatcher + seed flow
      # the existing #1201/#1202/#1208/#1236 lanes pin; pull
      # B-beta3-1249-1250-plugin-ux on every bridge-plugins.sh +
      # dev-plugin-cache + plugins-* helper move so the new dispatcher
      # entry, add-marketplace verb, and seed auto-install branch cannot
      # regress without the smoke firing in required CI. The smoke also
      # references the new lib/upgrade-helpers/plugins-seed-parse-sync-output.py
      # helper — added below as its own trigger row so a helper-only edit
      # still pulls the regression smoke.
      # Issue #1278 (v0.15.0-beta4 Lane H): `bridge_plugins_seed_propagate_
      # iso_known_marketplaces` (the D2 path) now chowns the per-UID
      # `known_marketplaces.json` to `<iso_user>:ab-agent-<a> 0660`
      # instead of `root:ab-agent-<a> 0640`, mirroring
      # `bridge_write_isolated_known_marketplaces_catalog` in
      # lib/bridge-agents.sh. The #1208 lock self-heal stays intact.
      # Pull H-beta4-iso-ownership on every bridge-plugins.sh +
      # dev-plugin-cache move so an inadvertent revert at either
      # writer site immediately fails the regression contract.
      # v0.15.0-beta4 Lane K (#1282 Surface B): bridge-dev-plugin-cache.py
      # now reports `node_modules=not-required` (instead of `=missing`)
      # for plugin sources that declare no deps + no lockfile, so `.mjs`
      # proxy plugins (`cosmax-ep-approval` etc.) stop painting the
      # operator dashboard with cosmetic noise. Pull K-beta4-nits
      # whenever bridge-dev-plugin-cache.py moves so a future PR cannot
      # silently revert the heuristic.
      add_required 1201-1202-directory-marketplace-seed channel-plugins 1208-lock-metadata-normalize ζ-1236-plugins-list-marketplaces β-1231-1236-fresh-install-seed-sudoers B-beta3-1249-1250-plugin-ux C1-beta3-1251-restart-preflight-rollback A3-beta3-1248-restart-session-id-resume C-beta4-logger-and-spec H-beta4-iso-ownership K-beta4-nits
      add_integration integration-minimal
      ;;

    scripts/python-helpers/claude-plugin-manifest-has-spec.py)
      # Issue #1274 (v0.15.0-beta4 Lane C): this standalone helper is the
      # canonical decoder for `bridge_claude_plugin_status` →
      # `_bridge_claude_plugin_bridge_manifest_has_spec` (the per-UID +
      # shared-cache manifest probe). The helper now strips a `plugin:`
      # prefix at the boundary so callers that forget to strip
      # `${item#plugin:}` (the v0.15.0-beta3 Lane C1 restart preflight
      # regression that landed unstripped at lib/bridge-agents.sh:7823)
      # still produce the correct present/absent result. Any move to
      # this helper must pull C-beta4-logger-and-spec so the boundary
      # strip contract stays caught.
      add_required C-beta4-logger-and-spec C1-beta3-1251-restart-preflight-rollback
      add_integration integration-minimal
      ;;

    lib/upgrade-helpers/plugins-seed-parse-sync-output.py)
      # Issue #1250 (v0.15.0-beta3 Lane B): the sync-output parser the
      # seed auto-install branch invokes file-as-argv. A helper-only
      # change (regex tightening, dep-detection extension) must still
      # pull the parent smoke so the parser contract stays in lockstep
      # with the seed branch that consumes its TSV rows.
      add_required B-beta3-1249-1250-plugin-ux C1-beta3-1251-restart-preflight-rollback A3-beta3-1248-restart-session-id-resume
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
