#!/usr/bin/env bash
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

# Fleet-down guard: this runner spawns destructive smokes; isolate the tmux
# socket (and sever an inherited live `$TMUX`) so a selected smoke can never
# tear down the shared default server. Exported here, inherited by every smoke
# this runner spawns — covers smokes that do not source scripts/smoke/lib.sh.
# shellcheck source=../lib/bridge-smoke-tmux-isolation.sh
source "$REPO_ROOT/lib/bridge-smoke-tmux-isolation.sh"

suite="required"
run_selected=0
base_ref="${BASE_SHA:-}"
head_ref="${HEAD_SHA:-HEAD}"
changed_files=""
# Post-selection sharding (#1897). Default 0/0 means "no sharding": the
# selected list is emitted/run whole — the sharding filter is a strict no-op,
# so for any given selected list the no-shard output is byte-identical to the
# pre-sharding behaviour. When --shard-total K (>=1) and --shard-index N (1..K)
# are set, the FINAL selected list is filtered to the shard via index-mod: the
# i-th selected script (0-based) belongs to shard (i % K) + 1.
shard_index=0
shard_total=0

usage() {
  cat <<'EOF'
Usage: scripts/ci-select-smoke.sh [--suite required|integration|live|legacy] [--base <sha>] [--head <sha>] [--changed-file <path>] [--shard-index N --shard-total K] [--run]

Selects modular smoke tests from the PR/push diff. With --run, executes the
selected scripts in order. Without --run, prints one script path per line.

--shard-index N --shard-total K filters the final selected list to shard N of
K (1-based) using index-mod partitioning. Both must be given together; with
neither, no sharding is applied and the whole selected list is used.
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
    --shard-index)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      shard_index="$2"
      shift 2
      ;;
    --shard-total)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      shard_total="$2"
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

# Shard-arg validation (#1897). Both flags must be set together or not at all.
# 0/0 = no sharding. A non-default value must be a non-negative integer; when
# sharding is active, shard_total >= 1 and 1 <= shard_index <= shard_total.
case "$shard_index" in *[!0-9]*) echo "ci-select-smoke.sh: --shard-index must be a non-negative integer: $shard_index" >&2; exit 2 ;; esac
case "$shard_total" in *[!0-9]*) echo "ci-select-smoke.sh: --shard-total must be a non-negative integer: $shard_total" >&2; exit 2 ;; esac
# Strip any leading zeros for arithmetic comparison (10# base prefix).
shard_index=$((10#$shard_index))
shard_total=$((10#$shard_total))
if [[ $shard_index -ne 0 || $shard_total -ne 0 ]]; then
  if [[ $shard_total -lt 1 ]]; then
    echo "ci-select-smoke.sh: --shard-total must be >= 1 when sharding: $shard_total" >&2
    exit 2
  fi
  if [[ $shard_index -lt 1 || $shard_index -gt $shard_total ]]; then
    echo "ci-select-smoke.sh: --shard-index must be in 1..$shard_total: $shard_index" >&2
    exit 2
  fi
fi

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

add_required queue daemon daemon-periodic-token-sync launch launch-dev-channels-injection tmux-injection isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering 1495-settings-invalid-hook-key 1453-channel-sticky-false-inbound 1455-settings-two-tree-doctor isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip isolation-v2-marker-only-migrate isolation-v2-macos-noise-suppression isolation-v2-platform-discriminator isolation-v2-bucket2-gates layout-resolver-marker-over-env bsd-mktemp-portability upgrade-isolated-agent-migrate channel-plugins channel-env-readiness hooks upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-pair-server-auto-provision mattermost-plugin pre-compact-envelope-roundtrip telegram-relay-residue-cleanup agent-create-name-validation agent-create-caller-trust-gate agent-create-idle-timeout 1105-agent-add-audit 1100-audit-since-tz agent-update agent-update-launch-cmd-redaction 1122-admin-auto-caller-source 1136-always-on-no agent-doctor cron-run-artifacts-retention cron-migrate-payloads cron-mutation-audit cron-shell-runner 1114-cli-help-contract upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering 1120-controller-ops-isolated 1139-link-shared-settings-perm 1144-upgrade-complete-task 1145-ensure-dir-actually-sudo 1145-option1-deferral-guard 1151-step-a-helper 1151-r2-sudo-escalate 1155-bootstrap-skill-guard 1158-marker-controller-uid-exemption 1158-marker-load-order 1161-marker-readable-by-isolated 1165-track-a-scaffold-modes 1165-track-b-sudo-escalate-and-state 1165-track-c-hooks-and-dispatcher 1342-write-state-marker-matrix 1170-safe-path-check-sudo-escalate 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp shared-settings-preserve-user-keys 1689-statusline-preserve-rerender 1756-settings-preserve-model-user-keys status-engine-detect 835-static-admin-launch 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions 1021-isolation-v2-shared-plugin-perms 1025-isolated-create-agent-env-install 1028-isolated-workdir-check 1118-v2-engine-binary-path admin-protocol-shared-link bridge-notify-no-default-discord-875 cleanup-payload-empty-stdin-872 dynamic-agent-shared-mode-workdir v2-scaffold-home-and-workdir 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair agent-env-no-stale-bridge-layout 1015-resume-claude-config-dir 1073-fresh-channel-first-run-seed 1753-hud-config-seed isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup 1400-purge-home-degrade-no-sudo nudge-task-age-gate 1106-nudge-shell-recheck nudge-redundant-active-agent 1323-nudge-eligibility-recheck-twostage 1199-action-required-claimed-skip tool-policy-roster-read-classify 1690-tasksdb-read-carveout 1692-admin-bash-symmetry 1709-shared-secret-suffix-guard 679-wiki-ingest-exclude-precompact a2a-cross-bridge 1405-handoffd-supervision 1058-bootstrap-tmux-ux legacy-install-migrator 1117-cli-help-universal-gate 1087-migrator-apply-contract 1067-codex-provisioning 1077-migrate-iso-v2-data-dir 1108-watchdog-v2-workdir 1119-watchdog-perm-error 1113-watchdog-legacy-backfill 1115-cli-usage-drift phase2-install-tree-reconciler phase3-agent-home-contract 1201-1202-directory-marketplace-seed 1205-hook-iso-fail-open 1207-stale-supp-groups-allowlist 1208-lock-metadata-normalize 1209-ms365-redirect-resolver 1210-ms365-scope-normalize 1212-bridge-hooks-marketplace 1213-iso-uid-predicate 1214-channel-validator-iso-fallback 1215-ms365-dir-mode beta27-D-inject-timestamp-resolved beta27-E-hook-permission-fail-open-markers G-channel-spec-resolution F-daemon-supp-groups-mock F-daemon-supp-groups-real H-bootstrap-memory-iso-rebuild I-agent-description-roster ζ-1236-plugins-list-marketplaces β-1231-1236-fresh-install-seed-sudoers 6607-hook-admin-allowlist γ-cli-consistency δ-1234-daemon-start-policy B-beta3-1249-1250-plugin-ux C1-beta3-1251-restart-preflight-rollback A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir C-beta4-logger-and-spec B-beta4-setup-wizard A-beta4-iso-path-resolution D-beta4-daemon-lifecycle E-beta4-fresh-install-gate-state-dir H-beta4-iso-ownership F-beta4-oauth-bootstrap G-beta4-watchdog-noise I-beta4-a2a-3-gaps J-beta4-workflow-docs K-beta4-nits Beta-beta5-session-id-detect-sudo α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-1-session-id-detect-race dev-channel-auto-accept-no-attach mcp-liveness-giveup-auto-clear beta5-2-epsilon-tmux-inject-busy beta5-2-zeta-teams-mcp-dedup beta5-2-pi-daemon-crashloop-no-set-e-leak beta5-2-eta-cron-iso-uid-preflight beta5-2-delta-nudge-session-empty beta5-2-theta-upgrade-backfill-perms beta5-2-nu-daemon-path-quarantine beta5-2-kappa-state-audit-reconcile beta5-2-iota-daemon-escalation-family beta5-2-lambda-a2a-robustness beta5-2-mu-cron-channel-creds beta5-2-xi-misc-fixes 1359-cron-create-iso-staging 1379-iso-cron-staging-group 1383-iso-cron-result-json-group 1354-setup-teams-fd-password 1360-onboarding-next-actions-persona 1353-setup-pending-grace 1355-1356-ms365-wizard 1357-iso-boundary-quickref 1358-admin-credential-routine-exempt 1352-shared-codex-pair-path 1343-ms365-token-refresh 1378-iso-session-lock-fresh-start 1388-daemon-lock-fd-cloexec 1416-onboarding-state-field-anchor a2a-setup-wizard 1408-daemon-alert-nudge-hygiene 1409-claude-midturn-busy-gate 1427-A-roster-materialize 1427-B-template-sync-wizard 1426-cron-shell-noniso-help 1437-reactive-cron-rotation 1425-spool-rederive 1617-pending-attention-arrival-stale 1437-native-usage-probe 1468-usage-429-positive-signal usage-probe-edge-classification 1464-cron-aware-stale-health 1497-v2-dynamic-handoff 1497-p1-home-resolver 1506-isolate-normalize 1497-p2-operator-home 1513-iso-teams-prune-eacces 1516-upgrade-downgrade-guard 1612-upgrade-restart-receiver plugin-requires-resolver 1520-shared-claude-config-dir 1520b-create-time-creds-sync 1520c-create-isolate-profile-publish 1533-create-isolate-content-publish 1766-iso-settings-readable 1402-stat-platform-order 1398-a2a-inbound-stopped-target-force 1463-launchd-keepalive-singleton-thrash 1470-engine-auth-seam 1470-codex-fleet-sync 1459-cron-dispatch-recovery 1417-identity-sync-on-start 1750-admin-workdir-identity-not-pair-template upgrade-migrate-rematerialize-workdir 1367-auth-sealed-paste 1563-daemon-singleton 9882-daemon-audit-fp 9981-iso-urgent-instant-wake 9981-iso-pending-attention-readable 1563-pr2-daemon-self-abort 1563-pr3-daemon-escalation 1563-pr4-a2a-receiver-healthz 1563-pr5-fp-control-matrix 1563-pr6-watchdog-scan-timeout 1563-pr7-tick-cadence 1563-pr8-a2a-diag-recovery 1602-dryrun-ref-fidelity 1601-conflicts-adopt-guard 1569-askuserquestion-bound 1611-migrate-orphan-skip 1613-wiki-mention-fence-indent 1623-a2a-backpressure-failopen 1628-a2a-deliver-per-row-guard 1631-nudge-helper-db-guard 1630-a2a-fresh-arrival-nudge 1637-agb-list-iso-marker 1635-iso-backup-perm-skip 1629-healthz-not-semaphore-gated 1640-urgent-from-override 1639-post-restart-auto-wake 1638-settings-cosmetic-conflict 1650-ms365-get-valid-token 1636-rematerialize-scaffolding 1659-cron-status-walk-perf 1663-plugin-cache-sidecar-skip 1660-upgrade-emit-brokenpipe 1661-upgrade-singleton-lock 1662-upgrade-complete-marker 1667-daemon-control-lock-serialize 1672-link-shared-settings-idempotent 1671-teams-eaddrinuse-diagnostic 1670-rematerialize-dryrun-agent-preserved 1677-cron-summary-short-derive lts-channel-sticky-resolver 1685-receiver-staleness-selfheal 1701-warp-healthz-socket-held 1697-a2a-net-status 1693-read-viewers v0165-l0-reconcile-skeleton v0165-l2-tunnel-health v0165-l1-stable-addr v0165-l3-peer-reachability v0165-l4-token-join v0165-l5-relay-roster v0165-l6-net-status-v2 v0166-la-tunnel-bounce-gate v0166-lb-transient-peers v0166-lc-config-set-env 1567-codex-orphan-upgrade-reaper 1675-1694-settings-homebrew-abspath-conflict 1652-queue-gateway-crashloop 11901-shared-global-settings-inherit 1759-selfref-global-loop-guard 1679-1680-a2a-receiver-supervisor-robustness 1762-picker-autoresolve 1783-picker-idle-nonpicker 1764-ratchet-anchoring 1769-freshness-gate-resume 1763-static-model-effort 1781-doc-migration-memory-preserve 1786-tasksdb-doctor-verb 1795-reaper-ephemeral-policy 1803-orphan-dir-gc 1801-watchdog-bounded-broken-links 1872-watchdog-unsupported-engine-info 1809-agents-md-backfill 1806-admin-guard-allow-audit 1823-v2-peer-home-containment 1852-dynamic-agent-restart 1855-keychain-free-backfill 1860-smoke-daemon-stub-temp-guard 1853-self-restart-footgun 1797-reaper-keep-audit-latch 1857-recreate-provisioning-preserve 1844-plugin-liveness-probe 1826-cron-at-naive-tz 1842-cron-tamper-iso-groupwrite 1833-status-gateway-timeout-not-down 1837-gateway-exit-code-on-commit 1825-ms365-token-key-by-claim 1836-iso-first-start-queue-dir-ownership dynamic-agent-resume-config-dir-scope 1891-iso-create-path-completeness 1892-doc-backfill-engine-fail-closed 1906-flag-engine-mismatched-docs 1890-dynamic-vanilla-claude 1900-dynamic-vanilla-refresh-noop 1900-dynamic-vanilla-v2-secret-env-scrub 1899-dynamic-vanilla-codex 1899-dynamic-vanilla-codex-v2-secret-env-repin 1923-askuserquestion-hard-ban 1934-hook-path-canonical-fence 1934-hook-file-self-heal
add_required 1425-cron-dispatch-nudge-scope
# Issue #1894: the memory-daily harvester runs the iso agent's transcript scan
# AS the iso UID (run-as-iso narrow helper) and marshals it back to the
# controller-UID harvest via --transcripts-json, replacing the broken
# controller-read `[[ -r && -x ]]` branch that always fell to
# --skipped-permission (the promised prepare-isolation ACL was absent in the
# field). In the full static suite so any harvest-stub / bridge-memory.py
# scan-transcripts edit re-runs the run-as-iso + marshal-back contract.
add_required 1894-iso-transcript-harvest-run-as-iso
# Issue #1897: the ci-select-smoke sharding self-check. Pins the post-selection
# --shard-index/--shard-total filter contract (union-of-shards == unsharded,
# disjoint shards, empty-shard exit 0, --run shard filtering, shard-aware bun
# detection) for BOTH the full required list and a changed-file-selected list.
# In the full static suite so any selector edit re-runs the guard.
add_required 1897-ci-select-shard
# Issue #1881: channel-plugin enable restart guidance (A) + /plugin enable
# route-away (B) + the live_mcp_status runtime-readiness field on `agent show
# --json` (C). bridge_setup_print_restart_hint (bridge-setup.sh) and
# bridge_agent_live_mcp_status / bridge_agent_session_health_json
# (lib/bridge-agents.sh) are the surfaces. In the full static suite so any
# channel/agent-surface edit re-runs it.
add_required 1881-channel-enable-live-mcp-readiness
# Issue #1181: modal-blocker detection (Layer 1). Spans lib/bridge-tmux.sh
# (matcher + shared is_block predicate), lib/bridge-state.sh (snapshot
# wake_reason column), lib/bridge-agents.sh (wake status), bridge-daemon.sh
# (nudge-drop reason=modal_<state>), and bridge-status.py (wake_reason
# surfaces). In the full static suite so any scripts/smoke/* move re-runs the
# detection + status-surface contract.
add_required 1181-modal-blocker-detect
# Issue #1820: layout-v2 four-writer migration + gated v1->v2 reconciliation.
# All eight verdict gates as smokes — cron/precompact/settings/doc-sync writer
# fixes, the reconcile conflict policy + idempotence, the dry-run inventory and
# gated apply (wrapper end-to-end incl. the fail-closed quiesce fence), and the
# post-apply source invariant. In the full static suite so any writer or
# reconcile edit re-runs the whole matrix.
add_required 1820-cron-writer-v2-candidate 1820-precompact-resolved-env-v2 1820-settings-v2-render-symlink 1820-doc-sync-v2-target-root 1820-reconcile-conflict-policy 1820-reconcile-dryrun-inventory 1820-reconcile-apply-gated 1820-post-apply-invariant 1820-upgrade-reconcile-fail-closed
# Issue #1813: the #1820 doc-sync writer (writer 4) reached the v2 home TREE but
# the link MATH inside bridge-docs.py still hard-coded `../shared/<name>` (v1
# depth) — so the four canon shared-doc symlinks never resolved into v2 homes,
# correct absolute links got clobbered, and broken-link cleanup deleted by name.
# The fix is depth-correct os.path.relpath targets + realpath-based accept +
# resolution-scoped cleanup, plus the bridge-upgrade.sh doc-sync caller now
# resolves the v2 data root from the target marker. In the full static suite so
# any bridge-docs.py link-math or upgrade doc-sync caller edit re-runs the gate.
add_required 1813-canon-links-resolve-v2
# Issue #1905: bridge-upgrade.sh's #1820 reconcile quiesce is now systemd-aware —
# it stops agent-bridge-daemon.service + agent-bridge-daemon-liveness.timer via
# systemctl so systemd cannot respawn the daemon back into the fail-closed fence
# (and restores them on the restart phase). In the full static suite so any
# upgrade-quiesce/restart-phase edit re-runs the systemd-aware guard.
add_required 1905-upgrade-systemd-quiesce-respawn
# Issue #655: the macOS launchd analog of #1905. bridge-upgrade.sh's #1820
# reconcile quiesce now boots out + disables the agent-bridge LaunchAgent
# (KeepAlive) so launchd cannot respawn the daemon back into the fail-closed
# fence (and re-enables + bootstraps + kickstarts it on the restart phase).
# Gated behind a Darwin+launchctl+resolvable-label check so the systemd/plain-
# bash paths are byte-for-byte unchanged. In the full static suite so any
# upgrade-quiesce/restart-phase edit re-runs the launchd-aware guard alongside
# the systemd one.
add_required 655-upgrade-launchd-quiesce-respawn
# Issue #1916: bridge_init_register_default_picker_sweep now migrates the legacy
# text-kind picker-sweep cron to shell-kind FAIL-SAFE (recreate-first /
# verify-before-delete) — the legacy row is deleted only after a shell row is
# confirmed present, so a failed re-register can never strand the host with zero
# picker-sweep crons. In the full static suite so any init-cron migration edit
# re-runs the ordering guard.
add_required 1916-picker-sweep-migrate-atomic
# rc2 fleet-soak observability hardening for the #1820 reconcile/upgrade path:
# the reconcile ALWAYS writes a structured result at the canonical
# state/migration/layout-v2-reconcile/last-apply.json (status noop|applied,
# never a 0-byte file), the upgrade redirect + log message name that SAME path,
# and a genuine isolation-v2 migration success clears the stale last-error it
# supersedes. In the full static suite so any reconcile/upgrade/migrate edit
# re-runs the observability guard.
add_required rc2-reconcile-observability
# Issue #1820 rc3 (cm-prod real-Linux iso-v2 production soak of v0.16.10-rc2):
# the layout-v2 reconcile must NOT controller-direct-read an iso v2 agent's
# agent-private 0600 memory (that raised [Errno 13] backup-failed warnings on 4
# iso bots and the iso permission pass was absent from last-apply.json). The
# engine now GRACEFUL-SKIPS iso agents passed in --iso-agents-json and records a
# structured isolation_v2_migration(skipped-iso-private) section. In the full
# static suite so any reconcile/iso edit re-runs the iso-permission guard.
add_required 1820-iso-reconcile-permission
# Issue #1820 rc4 (cm-prod real-Linux iso-v2 production soak of v0.16.10-rc3):
# the rc3 6 Errno13 warnings were the invoker shell's STALE supplementary group
# cache, NOT topology — the controller IS in every ab-agent-<a> group and the
# 2770 iso homes are group-readable; a 15-day-old login shell missing the newly
# created bot groups inherited a stale group set into the reconcile child so
# os.scandir(2770 home) threw Errno13 (KNOWN_ISSUES §28 / #1836). The systemic
# fix: a SHARED fresh-group preflight (bridge_controller_supp_group_refresh in
# lib/bridge-agents.sh) used by BOTH the reconcile driver and the watchdog entry
# (detect the live group set missing rostered iso groups → sg re-exec, or WARN
# when impossible — never silently mask); REMOVAL of the retracted whole-home
# belt; and (A2) a FILE-LEVEL 0600 owner-only skip as the SOLE skip mechanism
# (reason file-owner-only), replacing the rc3 #1876 up-front iso-map whole-agent
# skip so correctness does NOT depend on iso-map completeness (the no-meta mdj
# case). The watchdog also downgrades registry-classified permission_denied iso
# rows + (env fallback) the transient stale-group window. In the full static
# suite so any reconcile/watchdog/iso edit re-runs the guard.
add_required 1820-rc4-iso-stale-group-preflight
# Issue #1820 rc4 gate-2 (#13364, patch-dev real-Linux rig): the rc4 file-level
# iso owner-only skip was authorized by a single HOST-WIDE --iso-host boolean, so
# on a MIXED iso/shared host a SHARED agent's per-file PermissionError got
# silently downgraded to a file-owner-only iso skip instead of surfacing the
# required warning. The fix replaces the host-wide gate with a PER-AGENT iso set
# (--iso-agents, built from the same roster predicate the preflight uses —
# effective OR requested linux-user isolation, NOT requiring a resolved os_user
# so the no-meta mdj case still downgrades). The downgrade fires ONLY for an
# agent in that set; a shared agent's per-file PermissionError stays a warning +
# data skip, byte-identical to main, even on a mixed host. This rig is the
# mixed-host reproducer. In the full static suite so any reconcile/iso edit
# re-runs the per-agent gate guard.
add_required 1820-rc4-iso-mixed-host-skip
# Issue #1820 rc4 supplement (cm-prod #7277): the watchdog's broken-symlink scan
# walks the DATA-TREE MIRROR workdir; for an original anomaly agent whose mirror
# render is incomplete the `.claude/settings.json -> settings.effective.json`
# mirror symlink dangles even though the agent's REAL runtime HOME effective
# settings are fully rendered + loaded (all hooks/plugins active, bot healthy) —
# a pure false-positive. The fix decides "has hooks/plugins" from the agent's
# runtime HOME effective settings (iso-aware home resolution), filters the
# dangling mirror symlink out IFF the runtime home HAS hooks/plugins (or its iso
# home is unreadable → graceful skip via bridge_iso_boundary), and keeps the row
# when the runtime home genuinely lacks them. In the full static suite so any
# bridge-watchdog.py / bridge_iso_boundary.py edit re-runs the guard.
add_required 1820-rc4-watchdog-settings-source
# Issue #1835: bridge-queue-gateway.py's SOCKET-transport client preflight
# (_read_inline_text) now applies the #1280 sudo-as-owner body-file fallback on
# PermissionError, with an actionable iso-ownership error when it cannot apply.
# In the full static suite so any scripts/smoke/* move re-runs the parity guard.
add_required 1835-create-bodyfile-iso-fallback
# Issue #1769: trusted-resume marker — a fresh/idle Claude agent restart now
# resumes instead of launching a brand-new session. In the full static suite
# so any scripts/smoke/* or session-resume helper change re-runs the
# regression guard (no marker → still reject) alongside the acceptance +
# single-use + launch-builder paths.
add_required 1769-restart-trusted-resume
# Issue #1755: dynamic-agent every-prompt UserPromptSubmit hook error
# (FileNotFoundError on the prompt_timestamp tmp rename, from a fixed tmp name +
# concurrent dup hook registration). In the static suite so any scripts/smoke/*
# move re-runs the concurrent-write + cross-scope-dedup regression via the
# catch-all → add_all_required_static (also pulled per-file on hooks/* /
# bridge-hooks.py / lib/bridge-hooks.sh moves above).
add_required 1755-prompt-timestamp-concurrent-write
# #1725: weekly-warn / 5h rotation threshold fail-safe sanitize + the weekly
# no-alternate escalation regression. In the static suite so a scripts/smoke/*
# move re-runs both via the catch-all → add_all_required_static (also pulled
# per-file on bridge-usage.* moves above).
add_required weekly-warn-threshold-sanitize weekly-usage-quota-escalation
# Issue #1568: the routine queued-task idle-nudge (nudge_agent_session in
# bridge-daemon.sh) must gate on the real-interaction predicate
# bridge_tmux_session_inject_busy, NOT bare `attached > 0` — a persistent-client
# multiplexer (cmux) keeps every session attached and stranded queued work
# behind the bare guard. In the static suite (and pulled per-file below on
# bridge-daemon.sh moves) so a revert to the bare-attach guard is caught.
add_required 1568-routine-nudge-inject-busy-gate
# #9780: Stop/turn-end inbox auto-drain. In the full static suite so a
# scripts/smoke/*, hooks/*, or bridge-queue.py change re-runs the Stop-chain
# loop-guard regression via the catch-all → add_all_required_static. The
# per-file selectors below (hooks/bridge_hook_common.py, hooks/check_inbox.py,
# bridge-queue.py, bridge-hooks.py) also pull it directly.
add_required 9780-stop-inbox-drain
# Issue #1596: the Stop drain excludes daemon-owned `[cron-dispatch]` rows from
# the actionable predicate (with the `[cron-followup]` carve-out) so the daemon
# cron tasks it owns/closes no longer wake the model. In the static suite and
# pulled per-file below on hooks/* / bridge-queue.py / bridge-hooks.py moves.
add_required 1596-stop-drain-cron-dispatch
# #10222: A2A receiver backpressure must count currently OPEN tasks
# (queued/claimed/blocked) by joining inbox_dedupe to tasks.db, not all-time
# accepted rows. Keep this in the static suite and pull it on receiver changes.
add_required a2a-backpressure-openonly
# #1623: the backpressure check must FAIL OPEN when the open-task COUNT cannot be
# computed (sqlite3.DatabaseError from the read-only WAL open of tasks.db) —
# skip the cap + accept the already-authenticated handoff (backpressure_count_skip
# audit), NOT 503-reject. Genuine over-cap still 429. Static suite + receiver pull.
add_required 1623-a2a-backpressure-failopen
# #1575-B + #1589/B8: A2A sender retry scheduling keeps our exponential backoff
# ceiling separate from peer Retry-After floor caps.
add_required 1575b-a2a-backoff-ceiling
# #1618: `agb a2a outbox retry` of a dead/retry row resets attempts=0 (alongside
# next_attempt_ts=0) so a manual retry walks the backoff ladder from the base
# interval instead of one-shot-then-ceiling / re-dead-letter.
add_required 1618-outbox-retry-resets-attempts
# #1628: the sender deliver loop wraps each `_deliver_one` in a per-row guard so
# one un-deliverable row (e.g. an iso-owned 0660 body the runner can't read ->
# PermissionError at read_bytes) cannot unwind the WHOLE batch — the bad row is
# demoted to the transient retry path (lease cleared) and the batch continues.
# Static suite + pulled on bridge-a2a.py (sender) changes.
add_required 1628-a2a-deliver-per-row-guard
# #1595: A2A is transport-pluggable (Tailscale | cloudflare-warp-mesh). The
# Cloudflare bind proof inspects REAL local interface state + WARP connected/
# enrolled status (CIDR shape is NOT proof; fail-closed on uncertainty); the
# Tailscale + raw-IP back-compat is preserved exactly. Keep in the static suite
# and pull it per-file below on the receiver / shared-protocol / sender moves.
add_required 1595-cloudflare-warp-mesh
# #1758: trusted-routed transport — interface-assignment bind proof ONLY (the
# WARP/Tailscale enrollment half dropped), loopback/wildcard still refused,
# unknown kind still hard-fails, HMAC/allowlist/source-check intact, + sender
# per-destination source symmetry (mesh peer -> Mesh source, routed peer ->
# OS-routed). Static suite + pulled per-file below on the same receiver /
# shared-protocol / sender moves as 1595.
add_required 1758-trusted-routed-transport
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
# Incident #9770 Track 2: surgical per-session codex app-server / Pencil MCP
# subtree reap. In the full static suite so a change to bridge-mcp-cleanup.py,
# the helper, or any of the three teardown seams (bridge-run.sh /
# bridge_kill_agent_session / daemon idle-kill) re-runs the #1-invariant proof.
add_required 9770-codex-teardown-reap
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
# A2A rooms P4.1 (design §11 / §14 R3): the cross-node JOIN. Member on node B
# posts a signed room-join-request to the leader's node A over the node-link;
# node A re-runs the full fail-closed auth preamble (remote_addr -> HMAC -> skew
# -> dedupe), verifies the invite token (HASH compare + TTL + revocation), and
# persists a VERIFIED PENDING row (no auto-admit — approve is P4.2). In the full
# static suite. Lives in bridge-handoffd.py (_handle_room_join_request),
# bridge_a2a_common.py (build/parse_room_join_request), bridge_rooms_common.py
# (verify_invite_token_outcome TTL/revocation + record_verified_cross_node_join_
# request), and bridge-rooms.py (OS-actor-anchored joiner + cross-node send).
# Pins the 5 teeth (hostile --from/env inert, no-cross-agent-impersonation,
# expired/revoked refused, no token/hash persisted anywhere, malformed/dup
# handled) + the unweakened auth preamble + the non-leader-node refusal.
add_required rooms-p4-1-cross-node-join
# A2A rooms P4.2 (design §6 / §11 / §14 R2): leader APPROVE + roster broadcast.
# On a cross-node approve the leader admits the member (REQUIRING a P4.1 verified
# pending row), bumps the epoch, and broadcasts the leader-signed canonical
# roster to every member node over the node-link; each member persists it to
# room_roster_cache. Lives in bridge-handoffd.py (_handle_room_roster_broadcast),
# bridge_a2a_common.py (build/parse_room_roster_broadcast), bridge_rooms_common.py
# (approve_cross_node gate + accept_roster_broadcast member-side contracts +
# reserve_roster_dedupe), and bridge-rooms.py (cross-approve gate + broadcast
# sender + local-join-intent binding). Pins the 7 teeth: cross-approve requires a
# verified pending row, a non-leader peer roster is rejected, an invalid pairwise
# HMAC is rejected, a first roster with no local binding is refused (rogue-leader
# mint prevented), epoch monotonicity, the cache update is atomic, and the
# local-leader-add path stays distinct (no P4.1 regression).
add_required rooms-p4-2-roster-broadcast
# A2A rooms P4.3 (design §11): room-scoped TALK (cross-node member messaging).
# Once a member node holds a leader-MAC'd roster in room_roster_cache (from P4.2),
# members on DIFFERENT nodes exchange room-scoped messages WITHOUT the leader
# online — each member validates membership against its OWN local cache + the
# envelope's room_epoch, fail-closed. Lives in bridge-handoffd.py
# (room_scoped_check — the P4.3 leader-MAC roster-cache gate on the enqueue path),
# bridge_rooms_common.py (roster_cache_membership_check), and bridge-rooms.py
# (`room talk` — OS-actor-anchored sender + cached-epoch stamp + room-scoped
# enqueue over the node-link). Pins the 9 teeth: a member message is delivered, a
# non-member sender is rejected, a mismatched epoch (stale AND ahead) is rejected
# fail-closed, an unknown room (no cache) is rejected, a missing room_id/epoch is
# 422, a plain non-room message is NOT room talk (delivered, no gate, no
# membership), a hostile --from/env cannot impersonate, a replay is deduped /
# same-id-diff-body is 409, and the auth preamble is unreachable pre-auth.
add_required rooms-p4-3-room-talk
# A2A rooms whole-room fan-out (#1594): the `agent-bridge a2a send --room <id>`
# (== `room send` == `room talk --fanout`) ergonomic surface over the P4.3
# machinery — one message to EVERY OTHER member of a room (self excluded), local
# same-node members via the LOCAL queue (bridge-task.sh create) + remote members
# via the cross-node room-scoped A2A leg. Membership is proven from the sender's
# OWN local roster cache / authoritative rooms.db (bridge-rooms.py cmd_talk +
# _local_target_pairs/_post_room_local); `a2a send --room` routes there via
# bridge-a2a.py's _delegate_room_fanout. The receiver-side room gate
# (bridge-handoffd.py / bridge_rooms_common.py) is UNCHANGED — the sender check
# is an ADDITIVE gate. Pins the 8 teeth: same-room fan-out allowed, a non-member
# sender denied (nothing leaves either leg), self excluded, local-leg delivery,
# remote-leg delivery (real receiver 200), partial-failure reported per-recipient
# (rc=2), NO regression for `room talk` (cross-node only) + the 1:1
# `a2a send --peer --to` surface, and the receiver membership gate stays
# fail-closed against a rewritten non-member envelope sender.
add_required 1594-rooms-fanout
# A2A rooms P4.5 (design §11): two polish follow-ups from the P4.4 VM acceptance.
# FIX 1 (UX completeness): a NON-leader node that joined a room now sees it via
# `room show`/`room list` — cmd_show/cmd_list (bridge-rooms.py) fall back to the
# member-side room_roster_cache (list_roster_cache / cached_roster_members /
# cached_leader in bridge_rooms_common.py) instead of "not found". FIX 2 (info-
# hygiene): enqueue_via_bridge_task (bridge-handoffd.py) returns a TERSE peer-
# facing 422 detail ("unknown target '<agent>'") instead of echoing the
# `bridge-task.sh` roster dump (agb-list engine/workdir/source columns) — the
# full reason stays in the LOCAL audit only. Pins both teeth sets: member-side
# show/list surfaces the cache, leader rooms unchanged, no-room/no-cache still
# 404; unknown target -> 422 with no roster leak + full local audit recorded.
add_required rooms-p4-5-polish
# Issue #1792: cron scope fence + task-create origin stamp. bridge-cron-runner.py
# build_prompt now appends a SCOPE FENCE (job-name-parameterized) so a cron child
# cannot "helpfully" act on inherited in-flight work (ghost queue tasks under the
# parent's name, edits in the parent's worktree); bridge-queue.py cmd_create
# records an `origin` stamp (cron:<run_id> | session:<id>) surfaced by `agb show`.
# In the static suite so any scripts/smoke/* change re-runs the fence-presence +
# origin-recorded + legacy-shape teeth via the catch-all; the bridge-cron-runner.py
# and bridge-queue.py/bridge-task.sh per-file arms below also pull it directly.
add_required 1792-cron-scope-fence
# rc3 BLOCKER 2: the scope fence also REFUSES cron-worker auto-exec of
# irreversible/prod-mutation operations and interactive-gated (`blocked`) tasks
# (cm-prod cron-worker-ran-a-held-`agb upgrade` incident). In the static suite
# so any scripts/smoke/* change re-runs the guard-presence + no-over-block teeth.
add_required 1875-cron-prod-mutation-guard
# Issue #1738 (SECURITY): the #341 `config set` / `config set-env` write gate now
# authorizes from a controller-published tmux pane-pid binding matched against
# bridge-config.py's OWN process ancestry (a shell cannot set its parent pid),
# NOT from spoofable process env (BRIDGE_AGENT_ID / BRIDGE_ADMIN_AGENT_ID /
# BRIDGE_CALLER_SOURCE). bridge-start.sh publishes the binding via
# bridge_publish_config_caller_binding (lib/bridge-state.sh) after tmux
# new-session; hooks/tool-policy.py adds the interim eval/bash -c/sh -c/$var
# indirection deny. In the full static suite so any scripts/smoke/* change
# re-runs the adversarial env-spoof matrix (both verbs DENY + target-unchanged,
# legit admin-binding + operator-TTY ALLOW); the per-file arms below pull it on
# bridge-config.py / bridge-start.sh / lib/bridge-state.sh / tool-policy.py moves.
add_required 1738-config-caller-binding


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
      #
      # Issue #1809: the template now wraps its runtime canon in the
      # `<!-- BEGIN/END AGENT BRIDGE DOC MIGRATION -->` managed block so a codex
      # AGENTS.md participates in the SAME create-if-absent + marker-splice
      # refresh as CLAUDE.md (upgrade backfill + daemon hygiene). A drift in the
      # marker placement would break that splice, so pull the #1809 smoke too.
      add_required 1067-codex-provisioning 1809-agents-md-backfill
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
          # Issue #1637: `agent-bridge list` (bridge_list_active_agents_
          # numbered) renders the workdir column with an [iso]/[missing]
          # discriminator so an iso agent whose workdir is present-but-
          # permission-blocked is no longer mislabeled [missing]. Pull the
          # smoke on every dispatcher move so a refactor of the list verb
          # cannot regress the marker selection.
          add_required 1637-agb-list-iso-marker
          # Issue #1890: the `agent-bridge` dynamic-spawn block now skips the
          # bridge_resolve_resume_session_id rehydration for dynamic Claude so
          # the bridge never persists an operator transcript id (resume is
          # native `claude --continue`). Pull 1890-dynamic-vanilla-claude on
          # every dispatcher move.
          add_required 1890-dynamic-vanilla-claude
          ;;
      esac
      # Issue #1795: the `agent-bridge` create path parses `--ephemeral` /
      # BRIDGE_AGENT_EPHEMERAL and writes BRIDGE_AGENT_EPHEMERAL at
      # registration so the daemon reaper can tell a throwaway worker from an
      # operator-created dynamic. Pull the reaper-policy smoke on every
      # `agent-bridge` move so a refactor cannot drop the tag at creation.
      if [[ "$path" == "agent-bridge" ]]; then
        add_required 1795-reaper-ephemeral-policy
      fi
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
        # Issue #1759: bridge-agent.sh's run_rerender_settings hosts the
        # drift-apply blast-radius guard (refuse a rerender that would write
        # through a symlink doubling as the operator's global) + the
        # `--force-operator-global` opt-in, plus the plan-json mirror of the
        # renderer's self-ref loop break. Pull the smoke on every
        # bridge-agent.sh move so a refactor cannot drop the guard or let the
        # plan drift back into perpetual needs-rerender on the self-ref layout.
        add_required 1759-selfref-global-loop-guard
        # Issue #1769: bridge-agent.sh's run_restart writes the short-TTL
        # trusted-resume marker after validating the live session it kills,
        # so the relaunch's post-kill resolver accepts that exact id once
        # despite the now-dead pid (repairing the #981 re-inject for a
        # fresh/idle session with no eligible transcript yet). Pull the smoke
        # on every bridge-agent.sh move so a refactor cannot drop the marker
        # write (re-breaking fresh/idle restart resume).
        add_required 1769-restart-trusted-resume
        # Issue #1852: bridge-agent.sh's run_restart re-materializes a dynamic
        # agent's active-env file after the post-kill prune (and fails closed
        # before the kill when the recorded metadata cannot reconstruct it),
        # so `agent restart <dynamic>` relaunches via the same write-env-then-
        # `bridge-start.sh --replace` mechanism the recreate flow uses instead
        # of deregistering the agent. Pull the smoke on every bridge-agent.sh
        # move so a refactor cannot reopen the destroy-on-restart regression.
        add_required 1852-dynamic-agent-restart
        # Issue #1853: bridge-agent.sh's run_restart detects a self-restart
        # (caller lives inside the target session's tree) and re-execs the
        # restart detached (setsid/nohup) so the relaunch survives the
        # self-kill instead of dying between kill and relaunch (continuity
        # lost). Pull the smoke on every bridge-agent.sh move so a refactor
        # cannot drop the self-restart detect+detach guard.
        add_required 1853-self-restart-footgun
        # Issue #1753: bridge-agent.sh's run_create calls
        # bridge_seed_operator_plugin_config after the first-run-config seed,
        # to seed-if-absent the operator's allowlisted plugin display config
        # (default claude-hud) into a fresh Claude agent home. Pull the smoke on
        # every bridge-agent.sh move so a refactor cannot drop the create-time
        # seed call or reopen the abbreviated-HUD regression.
        add_required 1753-hud-config-seed
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
        # Issue #1795: lib/bridge-state.sh hosts the dynamic-agent meta-file
        # writer (bridge_write_agent_state_file emits AGENT_EPHEMERAL) + every
        # loader path that reads it back into BRIDGE_AGENT_EPHEMERAL with the
        # legacy-absent ⇒ "0" migration default. Pull the reaper-policy smoke on
        # every bridge-state.sh move so a refactor cannot drop the persisted tag
        # or regress the migration fail-safe (which would re-open reaping of
        # operator-created dynamics).
        add_required 1795-reaper-ephemeral-policy
        # Issue #1738 (SECURITY): lib/bridge-state.sh hosts the config-caller
        # binding writer (bridge_publish_config_caller_binding / _remove /
        # _dir / _file) — the controller-published pane-pid record
        # bridge-config.py's `config set` / `set-env` write gate matches its
        # process ancestry against (instead of spoofable env). Pull the
        # adversarial binding smoke on every bridge-state.sh move so a refactor
        # cannot rename/drop the writer or change the binding shape/path.
        add_required 1738-config-caller-binding
        add_required 1378-iso-session-lock-fresh-start
        # Issue #9981 (sibling of #1378): lib/bridge-state.sh hosts the
        # pending-attention spool resolvers (bridge_agent_pending_attention_
        # state_dir / _file / _lock_dir), which must anchor the instant-wake
        # spool on the controller-owned state leaf (state/agents/<a>/) and NOT
        # on the iso data tree (data/agents/<a>/runtime/) — otherwise a
        # controller `urgent` against an always-on iso agent fails to write the
        # wake marker (perm-denied, 200-retry giveup) and the urgent degrades
        # to poll latency. Pull the smoke on every bridge-state.sh move so a
        # future refactor cannot silently revert the spool anchor.
        add_required 9981-iso-urgent-instant-wake
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
        # Incident #9770 Track 2: lib/bridge-state.sh hosts the codex subtree
        # reap helpers (bridge_codex_subtree_capture / _reap_captured /
        # _reap_for_session / _audit) that all three teardown seams call, plus
        # the redacted audit summary. Pull 9770-codex-teardown-reap on every
        # bridge-state.sh move so a refactor cannot drop a helper, leak command
        # strings into the audit, or weaken the within-subtree allowlist filter.
        add_required 9770-codex-teardown-reap
        # Issue #1734 (v0.16.6 Lane C): lib/bridge-state.sh's bridge_load_roster
        # now sources $BRIDGE_AGENT_ENV_LOCAL_FILE (agent-env.local.sh) LAST,
        # after the scoped agent env / agent-roster.local.sh, so an `agb config
        # set-env` override is a true install-wide override. Pull the security
        # smoke on every bridge-state.sh move so a refactor cannot drop the
        # source order (which would silently neuter set-env) or source it
        # BEFORE the roster (which would let the roster override the override).
        add_required v0166-lc-config-set-env
        # Issue #1769 mechanism 2: lib/bridge-state.sh hosts
        # bridge_claude_resume_session_id_for_agent, the resolvable-resume-id
        # probe that bridge-start.sh's setup-freshness gate now consults
        # before discarding a resumable session. Pull the gate smoke on every
        # bridge-state.sh move so a refactor of the resume-id helper cannot
        # silently re-break the silent-fresh-discard fix.
        add_required 1769-freshness-gate-resume
        # Issue #1769 mechanism 1: lib/bridge-state.sh's
        # bridge_resolve_resume_session_id threads the trusted-resume marker id
        # to the python resolver and consumes it on the decision-site accept
        # (BRIDGE_RESUME_TRUSTED_CONSUME=1 set only by
        # bridge_normalize_agent_session_id). Pull the smoke on every
        # bridge-state.sh move so a refactor cannot drop the marker plumbing
        # (re-breaking #981 fresh/idle restart resume) or consume on a
        # read-only hydration probe (burning it pre-launch).
        add_required 1769-restart-trusted-resume
        # Issue #1763: lib/bridge-state.sh's bridge_build_static_claude_launch_cmd
        # now reads BRIDGE_AGENT_MODEL/EFFORT and passes them to the static
        # launch helper so `agent update --model/--effort` actually reaches a
        # static Claude agent's process (was a silent no-op). Pull the smoke on
        # every bridge-state.sh move so a refactor cannot drop the model/effort
        # plumbing (re-breaking the materialize path) or regress the
        # roster-wins / preserve-when-empty precedence.
        add_required 1763-static-model-effort
        # Operator-session-hijack fix: lib/bridge-state.sh hosts
        # bridge_resolve_agent_claude_config_dir (scopes resume detection to a
        # dynamic agent's OWN isolated config dir — no operator-HOME fallback)
        # and bridge_agent_resume_quarantine_archive_transcript /
        # bridge_agent_resume_quarantine_add (ownership-scoped quarantine that
        # refuses to move a transcript outside the agent's config dir). Pull the
        # differential smoke on every bridge-state.sh move so a refactor cannot
        # re-introduce the operator-HOME fallback (re-hijacking the operator's
        # vanilla session) or un-scope the quarantine (destroying it).
        add_required dynamic-agent-resume-config-dir-scope
        # Issue #1890 (supersedes #1889 for dynamic Claude): bridge-state.sh now
        # branches the launch builders (bridge_build_dynamic_launch_cmd /
        # bridge_build_resume_launch_cmd / bridge_claude_dynamic_launch_cmd) and
        # the config-dir resolver + quarantine add/archive on the new
        # bridge_agent_is_dynamic_vanilla_claude predicate so dynamic Claude
        # launches plain `claude`/`claude --continue` (never `--resume <id>`),
        # resolves an EMPTY config dir (operator-global passthrough), and has
        # quarantine refused. 1890-dynamic-vanilla-claude pins all of that plus
        # static-unchanged; pull it on every bridge-state.sh move.
        add_required 1890-dynamic-vanilla-claude
        # Issue #1899 (Codex sibling): bridge-state.sh now branches the codex
        # launch builder + resume-decline + normalize/refresh/resolve no-ops on
        # bridge_agent_is_dynamic_vanilla_codex so dynamic Codex launches `codex
        # resume --last` (never `codex resume <id>`/`--all`) and never
        # detects/persists a codex session id. Pull 1899 on every bridge-state.sh
        # move so a refactor cannot regress the codex launch/resume contract.
        add_required 1899-dynamic-vanilla-codex
        # Issue #1181: lib/bridge-state.sh's bridge_write_roster_status_snapshot
        # now appends the trailing wake_reason column and routes the blocker
        # state through the shared bridge_tmux_claude_blocker_state_is_block
        # predicate. Pull the smoke on every bridge-state.sh move so a refactor
        # cannot drop the wake_reason column (header/row lockstep) or revert the
        # snapshot to the trust|summary-only wake=block arm.
        add_required 1181-modal-blocker-detect
      fi
      ;;

    bridge-run.sh)
      # Incident #9770 Track 2: bridge-run.sh's bridge_run_cleanup_mcp_orphans
      # is the clean-pane-exit teardown seam that one-shot captures+reaps the
      # session's own codex pane subtree (while the pane is still alive). Pull
      # 9770-codex-teardown-reap on every bridge-run.sh move so a refactor
      # cannot drop the clean-exit subtree reap or its skip+audit fallback.
      add_required 9770-codex-teardown-reap
      # Issue #1857: bridge-run.sh's bridge_run_sync_dev_plugin_cache now hosts
      # the launch-path provisioning convergence — the fleet-default canonical
      # read + class-(b) fail-closed unsafe-token gate + brownfield first-snapshot
      # reachability (teeth T13-T15 in 1857-recreate-provisioning-preserve drive
      # these functions directly). Pull the smoke on every bridge-run.sh move so a
      # refactor cannot silently drop the convergence union or the fail-closed
      # split (the gate-2 glob-bypass regression lived exactly here).
      add_required 1857-recreate-provisioning-preserve
      # Issue #1890: bridge-run.sh's launch-env path (bridge_run_shared_launch,
      # bridge_run_export_claude_launch_env, the keychain-free / channel-plugin
      # preflights) now branches on bridge_agent_is_dynamic_vanilla_claude so a
      # dynamic Claude agent launches against the operator-global ~/.claude with
      # NO per-agent CLAUDE_CONFIG_DIR export and NO per-agent credential/plugin
      # seed. Pull 1890-dynamic-vanilla-claude on every bridge-run.sh move.
      add_required 1890-dynamic-vanilla-claude
      # Issue #1899 (Codex sibling): bridge-run.sh's bridge_run_export_codex_
      # launch_env now pins CODEX_HOME to the operator global ~/.codex for a
      # dynamic vanilla Codex agent (never <agent_home>/.codex). Pull 1899 on
      # every bridge-run.sh move so the codex launch-env contract can't regress.
      add_required 1899-dynamic-vanilla-codex
      # Issue #1899 Phase-4 BLOCKING: bridge-run.sh's v2 secret-env wrapper block
      # now scrubs HOME/CODEX_HOME AND passes operator re-pin pairs to
      # bridge_isolation_v2_exec_with_secret_env for the dynamic vanilla Codex
      # case, so a stale launch-secrets.env CODEX_HOME cannot repoint the child
      # away from operator-global ~/.codex (the Codex analogue of the #1900
      # CLAUDE_CONFIG_DIR leak). The repin smoke drives the PRODUCTION wrapper
      # path (which 1899-dynamic-vanilla-codex does NOT). Pull it on every
      # bridge-run.sh move so the scrub+re-pin wiring can't regress.
      add_required 1899-dynamic-vanilla-codex-v2-secret-env-repin
      ;;
  esac

  # Issue #1797 NB-5: the 1795-reaper-ephemeral-policy smoke is in the static
  # required set (so it runs on every PR), but ci-select did not map it per-path
  # for the two libs that host the reaper's disposability inputs:
  #   - lib/bridge-agents.sh hosts bridge_agent_ephemeral / bridge_agent_loop,
  #     the predicates reap_idle_dynamic_agents gates the keep/reap decision on.
  #   - lib/bridge-wave.sh is the canonical throwaway-spawn surface that tags
  #     wave-fixer dispatch ephemeral=1 (the only class the reaper reaps).
  # Add the two per-path entries so a narrow-selected change to either file
  # re-runs the reaper-policy smoke instead of skipping it.
  case "$path" in
    lib/bridge-agents.sh|lib/bridge-wave.sh)
      add_required 1795-reaper-ephemeral-policy 1797-reaper-keep-audit-latch
      # Issue #1891: bridge_linux_prepare_agent_isolation (this lib) gained
      # the create-path memory/ normalize + the index.sqlite exclude + the
      # hard agent-meta.env write+verify. Pull 1891-iso-create-path-
      # completeness on every bridge-agents.sh move so a refactor cannot
      # silently drop the create-path completeness contract.
      add_required 1891-iso-create-path-completeness
      # Issue #1890: lib/bridge-agents.sh hosts the
      # bridge_agent_is_dynamic_vanilla_claude predicate — the single boundary
      # every #1890 site (launch builders, config-dir resolver, quarantine,
      # launch env, hooks redirect) gates on — plus the
      # bridge_ensure_claude_first_run_config skip. Pull 1890-dynamic-vanilla-
      # claude on every bridge-agents.sh move so the predicate's value space
      # cannot drift out from under those callers.
      add_required 1890-dynamic-vanilla-claude
      # Issue #1899: lib/bridge-agents.sh also hosts the sibling
      # bridge_agent_is_dynamic_vanilla_codex predicate — the boundary every
      # #1899 site gates on. Pull 1899 on every bridge-agents.sh move.
      add_required 1899-dynamic-vanilla-codex
      # Issue #1181: lib/bridge-agents.sh's bridge_agent_wake_status now routes
      # the agent-show / heartbeat wake decision through the shared
      # bridge_tmux_claude_blocker_state_is_block predicate so it agrees with the
      # snapshot writer. Pull the smoke on every bridge-agents.sh move so a
      # refactor cannot revert it to the trust|summary-only case arm and let the
      # two surfaces drift.
      add_required 1181-modal-blocker-detect
      # Issue #1738 r2 (GC gap): bridge_kill_agent_session (this lib) now also
      # drops the config-caller binding on its dead-session / no-session early
      # returns (not only the orderly tail), so a stopped/crashed agent's stale
      # pane_pid cannot be ridden by a later same-pid process. Pull the
      # adversarial binding smoke on every bridge-agents.sh move so a refactor
      # cannot re-open the early-return GC gap.
      add_required 1738-config-caller-binding
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

    scripts/iso-helper-ratchet.sh|scripts/baselines/iso-helper-baseline.txt|scripts/baselines/iso-helper-allowlist.txt)
      # Issue #1764: the controller->isolated boundary ratchet's detection
      # regex must stay word-boundary-anchored (`\.env` must not fire inside
      # `os.environ`, etc.) and fail-closed for genuine boundary callsites.
      # Pull the anchoring self-test whenever the ratchet, its baseline, or
      # its allowlist changes so a pattern edit cannot silently re-introduce
      # the substring false positives or weaken the gate.
      add_required 1764-ratchet-anchoring
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
      # Issue #1803: bridge-status.py gained the orphan_agent_dirs counter
      # (summary line + JSON), computed via the shared bridge_orphan_classifier
      # SSOT. Pull the GC smoke so a status-counter refactor that drifts from
      # the classifier's verdict is caught.
      # Issue #1844: bridge-status.py's Plugin Liveness section is now wired
      # to a real discord-relay probe (discord_liveness_by_agent /
      # plugin_liveness_sources / plugins_for_agent) instead of the
      # hardcoded "unknown" stub. Pull 1844-plugin-liveness-probe on every
      # bridge-status.py move so the probe wiring + omit-when-no-probe
      # contract cannot silently regress back to all-unknown rows.
      add_required queue upgrade-conflicts-lifecycle status-engine-detect 835-static-admin-launch 1155-bootstrap-skill-guard 1165-track-a-scaffold-modes 1170-safe-path-check-sudo-escalate 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp 1209-ms365-redirect-resolver 1215-ms365-dir-mode G-channel-spec-resolution γ-cli-consistency B-beta4-setup-wizard H-beta4-iso-ownership 1803-orphan-dir-gc 1844-plugin-liveness-probe 1833-status-gateway-timeout-not-down
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
      # Issue #1659: bridge-status.py's last_cron_run_by_agent now reduces the
      # run-dir to the LATEST run per distinct (agent, job-key) BEFORE running
      # the cadence check (was one occurrence-walk per historical run record =>
      # O(run-records); ~84s on a 5,632-record host). The matcher in
      # bridge-cron-scheduler.py is memoized (allowed_values -> bounded LRU).
      # Pull 1659-cron-status-walk-perf on every bridge-status.py move so a
      # future PR cannot regress render back to O(run-records) or collapse the
      # per-schedule reduction to latest-run-per-agent (which false-stales a
      # multi-job agent).
      add_required 1659-cron-status-walk-perf
      # Issue #1463: bridge-status.py's daemon_status now ports the shell
      # resolver's fallbacks (recorded-pid cmdline validation, scoped pgrep,
      # mkdir-lock owner.pid) so a transiently-missing daemon.pid (the
      # launchd-thrash secondary bug deletes it) no longer reads as
      # `stopped pid=-` while the daemon is running. Pull
      # 1463-launchd-keepalive-singleton-thrash on every bridge-status.py
      # move so the fallback chain cannot regress back to the bare
      # read-pid + kill(pid,0) that disagreed with the shell resolver.
      add_required 1463-launchd-keepalive-singleton-thrash
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
      # Issue #1881-A/B: bridge-setup.sh hosts bridge_setup_print_restart_hint,
      # the operator guidance that (A) names the bridge-native `agent restart
      # <a>` step after a channel setup and (B) routes the operator AWAY from
      # `/plugin enable` (SymlinkWriteRefused). Pull 1881 on every bridge-setup.sh
      # move so a refactor cannot drop the restart-name or the route-away.
      add_required 1881-channel-enable-live-mcp-readiness
      # Issue #1181: bridge-status.py reads the trailing wake_reason snapshot
      # column, emits it as a named --json field, and renders the "Wake Blocked"
      # human block. Pull the smoke on every bridge-status.py move so a refactor
      # cannot drop the wake_reason surfaces.
      if [[ "$path" == "bridge-status.py" ]]; then
        add_required 1181-modal-blocker-detect
      fi
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
      # Issue #1671-A (v0.16.3): plugins/teams/server.ts's httpServer bind-error
      # handler now emits a clear EADDRINUSE diagnostic (HOST:PORT +
      # TEAMS_WEBHOOK_PORT + "another process ... holds this port") via the
      # pure buildListenErrorDiagnostic() helper, instead of a bare
      # process.exit(1) with a terse line. The reap was DEFERRED (diagnostic-
      # only) — the smoke also pins that the bind-error path performs NO
      # kill/reap and proves an unrelated decoy listener is NOT killed. Pull
      # 1671-teams-eaddrinuse-diagnostic on every teams/server.ts touch so a
      # future refactor cannot silently regress to the terse exit OR sneak in
      # an un-provable reap.
      add_required 1671-teams-eaddrinuse-diagnostic
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
      # Issue #1825: server.ts now keys + stores the delegated token by the
      # AUTHENTICATED claim (id_token preferred_username/upn, Graph /me
      # fallback) at pair_poll success, not by the opaque pair_start input —
      # eliminating the post-pair re-key/mv/restart dance. The 1825 smoke
      # pins that the durable key/`upn` field is the verified claim, a forged
      # input cannot determine the key, and path-traversal is neutralized.
      # Pull on every ms365/server.ts move so a refactor cannot regress the
      # keying contract that the approvals plugin's identity read depends on.
      add_required 1209-ms365-redirect-resolver 1210-ms365-scope-normalize 1215-ms365-dir-mode 1343-ms365-token-refresh 1650-ms365-get-valid-token 1825-ms365-token-key-by-claim beta5-2-zeta-teams-mcp-dedup beta5-2-xi-misc-fixes
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
      # Issue #1630 (audit R3, root cause of #10561): bridge-queue.py
      # daemon-step now consumes the A2A fresh-arrival markers and exempts
      # the named task ids from ONLY the redelivery-age gate; bridge-task.sh
      # is the enqueue boundary the receiver drives. Pull the smoke on every
      # queue/task move so a refactor cannot reopen the ~60s age-gate hole
      # (T1) or regress the no-marker/idle-gate invariants (T2/T5).
      add_required 1630-a2a-fresh-arrival-nudge
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
      # Issue #1459: bridge-queue.py gained the queue-global
      # `cron-backlog-snapshot` subcommand (oldest queued [cron-dispatch]
      # row + count + age across ALL agents) that the daemon backlog sweep
      # reads. Pull 1459-cron-dispatch-recovery on every bridge-queue.py move
      # so the snapshot shape (oldest/age/count/agent/family fields) cannot
      # drift out from under the sweep.
      add_required 1459-cron-dispatch-recovery
      # #9780: bridge-queue.py gained the `note-self-continue` verb (the Stop
      # inbox-drain daemon nudge-suppression stamp — updates last_nudge_ts /
      # last_nudge_key WITHOUT bumping nudge_fail_count) and the find-open
      # single-row `updated_ts` field the loop-guard key depends on. Pull
      # 9780-stop-inbox-drain on every bridge-queue.py move so a refactor cannot
      # silently regress the fail-count-free stamp or drop updated_ts (which
      # would weaken the id+status+updated_ts guard key → re-loop risk).
      add_required 9780-stop-inbox-drain
      # Issue #1596: the Stop drain filters daemon-owned `[cron-dispatch]` rows
      # out of the actionable predicate via find-open --all (title + created_by
      # columns) and re-confirms the chosen row open. Pull
      # 1596-stop-drain-cron-dispatch on every bridge-queue.py move so a change
      # to the find-open `--all` payload (title / created_by / status / id) or
      # the cron-dispatch SQL exclusions cannot silently break the filter.
      add_required 1596-stop-drain-cron-dispatch
      # Issue #1792: bridge-queue.py's cmd_create now records an `origin`
      # attribution stamp (additive nullable column; cron:<run_id> from
      # BRIDGE_CRON_RUN_ID, else session:<id>) and cmd_show surfaces it. Pull
      # 1792-cron-scope-fence on every queue / task move so a refactor cannot
      # drop the column, the resolve_origin precedence (cron over session), the
      # `agb show` origin line, or regress a legacy (no-origin) row to an error.
      add_required 1792-cron-scope-fence
      add_integration integration-minimal
      ;;

    bridge-doctor.py)
      # Issue #1455: bridge-doctor.py hosts the read-only detector framework.
      # The settings single-tree detectors (settings-two-tree-drift /
      # settings-multi-tree) and the orphan-agent-dir detector all live here,
      # so pull the doctor smokes whenever the file moves — a refactor of the
      # registry-load gate, the detector_runs registration, or the
      # realpath/symlink comparison would otherwise silently regress them.
      # Issue #1786: bridge-doctor.py now hosts the `tasks-db` detector
      # (probe_tasks_db_health + detect_tasks_db) — the policy-blessed queue
      # DB health check the upgrade-complete checklist routes the admin agent
      # through. Pull its smoke whenever the doctor file moves so a refactor
      # of the WAL-aware ro-open ladder or the 3-state (ok/corrupt/
      # unverifiable) contract cannot silently regress it.
      # Issue #1803: bridge-doctor.py's orphan-agent-dir detector now consumes
      # the shared bridge_orphan_classifier SSOT. Pull the GC smoke too so a
      # classifier-refactor that changed the doctor's verdicts (which the GC
      # action layer reuses) is caught by both the detector smoke AND the
      # action/keep-set/TOCTOU/prune teeth.
      # Issue #1809: bridge-doctor.py now hosts the engine-aware
      # missing-agent-entrypoint detector (codex AGENTS.md). Pull the #1809
      # smoke whenever the doctor file moves so a refactor of the detector
      # registration / registry-consumer set / engine scoping cannot silently
      # regress the codex-only flagging.
      add_required 1455-settings-two-tree-doctor orphan-agent-dir agent-doctor 1786-tasksdb-doctor-verb 1803-orphan-dir-gc 1809-agents-md-backfill
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
      # Issue #1652 (CRITICAL crash-loop): the socket listener now guards its
      # _set_socket_group_mode / _refresh_socket_perms against a transiently-
      # missing socket (degrade, not FileNotFoundError crash) and treats an
      # empty connect-probe recv as a quiet _ProbeClose (no invalid_payload /
      # BrokenPipeError spam). Pull 1652-queue-gateway-crashloop on every
      # gateway move so the listener-survival + quiet-probe contract holds.
      # Issue #1792: the gateway now forwards a `cron_run_id` field (attribution
      # metadata only) and run_queue injects it into the queue child env as
      # BRIDGE_CRON_RUN_ID so an iso cron child's create is stamped
      # origin=cron:<id>. Pull 1792-cron-scope-fence on every gateway move so a
      # refactor cannot drop the forward/injection or let it bleed into the
      # trusted-actor / ACL decision.
      # Issue #1837 (keystone) + #1834: the gateway CLIENT path (cmd_client)
      # now degrades a busy/transient file-transport round-trip without false
      # failure — exit-code-reflects-commit for done/claim/cancel, bounded
      # read-side retry, read-verb direct-DB fallback, and the
      # gateway_daemon_liveness tri-state primitive (A3/#1833 consumes it).
      # Pull 1837-gateway-exit-code-on-commit on every gateway move so a
      # refactor cannot regress the no-false-failure client contract.
      # Issue #1835: the gateway's SOCKET-transport client preflight
      # (_read_inline_text) now mirrors the #1280 sudo-as-owner body-file
      # fallback that bridge-queue.py's create server path already has, so an
      # iso-owned `--body-file` read on PermissionError drops to
      # `sudo -n -u <owner> cat` and otherwise emits an actionable iso-ownership
      # error instead of an opaque body_file_unreadable. Pull
      # 1835-create-bodyfile-iso-fallback on every gateway move so the parity +
      # actionable-error contract cannot regress.
      # Issue #1833 (wave v0.16.10 A3): bridge-daemon.sh status / agb status
      # health is now anchored on gateway_daemon_liveness via
      # bridge_daemon_liveness (lib/bridge-state.sh). Pull
      # 1833-status-gateway-timeout-not-down on every gateway move so a
      # primitive change cannot silently flip the status renderer back to a
      # gateway-response-derived (false `down`) health verdict.
      add_required queue a2a-rooms-p1b-acl 1652-queue-gateway-crashloop 1792-cron-scope-fence 1837-gateway-exit-code-on-commit 1835-create-bodyfile-iso-fallback 1833-status-gateway-timeout-not-down 1836-iso-first-start-queue-dir-ownership
      ;;

    bridge-a2a.py|bridge-handoffd.py|bridge_a2a_common.py|bridge_reconcile_common.py|bridge-rooms.py|bridge_rooms_common.py|bridge-handoff-daemon.sh|lib/bridge-a2a.sh|lib/daemon-helpers/a2a-receiver-exit-cause.py|lib/daemon-helpers/a2a-receiver-staleness.py|handoff.local.example.json|scripts/smoke/a2a-cross-bridge-helper.py|scripts/smoke/a2a-tailscale-identity-resolve-helper.py|scripts/smoke/a2a-daemon-selfheal-reconcile-helper.py|scripts/smoke/a2a-migrate-identity-helper.py|scripts/smoke/a2a-ip-change-announce-helper.py|scripts/smoke/a2a-setup-wizard-helper.py|scripts/smoke/a2a-rooms-p1a-helper.py|scripts/smoke/a2a-rooms-p1b-acl-helper.py|scripts/smoke/a2a-rooms-1517-bootstrap-helper.py|scripts/smoke/rooms-p4-1-cross-node-join-helper.py|scripts/smoke/rooms-p4-1-post-hook.sh|scripts/smoke/rooms-p4-2-roster-broadcast-helper.py|scripts/smoke/rooms-p4-2-post-hook.sh|scripts/smoke/rooms-p4-3-room-talk-helper.py|scripts/smoke/rooms-p4-3-post-hook.sh|scripts/smoke/1594-rooms-fanout-helper.py|scripts/smoke/1594-rooms-fanout-post-hook.sh|scripts/smoke/1594-rooms-fanout-local-hook.sh|scripts/smoke/rooms-p4-5-polish.sh|scripts/smoke/rooms-p4-5-helper.py|scripts/smoke/1563-pr8-a2a-diag-recovery-helper.py|scripts/smoke/1575b-a2a-backoff-ceiling-helper.py|scripts/smoke/1618-outbox-retry-resets-attempts-helper.py|scripts/smoke/1628-a2a-deliver-per-row-guard-helper.py|scripts/smoke/1629-healthz-not-semaphore-gated-helper.py|scripts/smoke/1595-cloudflare-warp-mesh-helper.py|scripts/smoke/1758-trusted-routed-transport.sh|scripts/smoke/1758-trusted-routed-transport-helper.py|scripts/smoke/1701-warp-healthz-socket-held-helper.py|scripts/smoke/1697-a2a-net-status-helper.py|scripts/smoke/1685-boot-marker-helper.py|scripts/smoke/v0165-l0-reconcile-skeleton-helper.py|scripts/smoke/v0165-l2-tunnel-health-helper.py|scripts/smoke/v0165-l1-stable-addr-helper.py|scripts/smoke/v0165-l3-peer-reachability-helper.py|scripts/smoke/v0165-l4-token-join-helper.py|scripts/smoke/v0165-l4-token-join-post-hook.sh|scripts/smoke/v0165-l5-relay-roster-helper.py|scripts/smoke/v0165-l5-relay-post-hook.sh|scripts/smoke/v0165-l5-roster-post-hook.sh|scripts/smoke/v0165-l6-net-status-v2.sh|scripts/smoke/v0165-l6-net-status-v2-helper.py|scripts/smoke/v0166-la-tunnel-bounce-gate.sh|scripts/smoke/v0166-la-tunnel-bounce-gate-helper.py|scripts/smoke/v0166-lb-transient-peers.sh|scripts/smoke/v0166-lb-transient-peers-helper.py|scripts/smoke/1728-test-bind-state-path-guard.sh|scripts/smoke/1728-test-bind-state-path-guard-helper.py|scripts/smoke/1679-1680-a2a-receiver-supervisor-robustness.sh|scripts/install-handoffd-systemd.sh)
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
      # A2A Rooms P4.1 (design §11 / §14 R3): the cross-node JOIN. A member on
      # node B posts a signed room-join-request to the leader's node A; node A
      # verifies (node-link HMAC + token-HASH + TTL + revocation) and persists a
      # PENDING row (no auto-admit). The NEW remote surface is
      # _handle_room_join_request in bridge-handoffd.py; the wire builder/parser
      # is in bridge_a2a_common.py; the TTL/revocation verify + verified-pending
      # persistence is in bridge_rooms_common.py; the OS-actor-anchored joiner +
      # cross-node send is in bridge-rooms.py. rooms-p4-1-cross-node-join pins the
      # 5 teeth: hostile --from/env cannot change the joiner, a node-B process
      # cannot join as another B agent, expired/revoked tokens are refused, the
      # raw token AND its hash never persist in any queue/audit/staged file, and
      # malformed/duplicate requests are handled — PLUS the auth preamble stays
      # unweakened (HMAC 401 / remote_addr 403 / unknown-peer 403). Pull on every
      # move to any of those files so the cross-node admission gate cannot regress.
      # A2A Rooms P4.2 (design §6 / §14 R2): leader APPROVE + roster broadcast.
      # The NEW remote surface is _handle_room_roster_broadcast in
      # bridge-handoffd.py; the wire builder/parser is build/parse_room_roster_
      # broadcast in bridge_a2a_common.py; the cross-approve gate + member-side
      # acceptance (anti-rogue-leader binding + monotonic epoch + atomic cache) is
      # in bridge_rooms_common.py; the broadcast sender + local-join-intent
      # binding is in bridge-rooms.py. rooms-p4-2-roster-broadcast pins the 7
      # teeth (cross-approve needs a verified row, non-leader roster rejected,
      # bad pairwise HMAC rejected, first-roster-without-binding refused, epoch
      # monotonicity, atomic cache, local-add path distinct). Pull on every move.
      # A2A Rooms P4.3 (design §11): room-scoped TALK. The membership gate is the
      # P4.3 activation of room_scoped_check in bridge-handoffd.py (it now reads
      # the member-local leader-MAC room_roster_cache + the envelope room_epoch,
      # fail-closed, instead of a live is_member read); the cache-membership
      # decision is roster_cache_membership_check in bridge_rooms_common.py; the
      # `room talk` sender (OS-actor-anchored + cached-epoch stamp + room-scoped
      # enqueue) is in bridge-rooms.py. rooms-p4-3-room-talk pins the 9 teeth
      # (member delivered, non-member rejected, epoch mismatch stale/ahead
      # rejected, unknown room rejected, missing room_id/epoch 422, plain message
      # not room talk, hostile --from cannot impersonate, replay dedupe /
      # same-id-diff-body 409, auth preamble unreachable pre-auth). Pull on move.
      # A2A Rooms P4.5 (design §11): two follow-ups from the P4.4 VM acceptance.
      # FIX 1 (UX): `cmd_show`/`cmd_list` in bridge-rooms.py now fall back to the
      # member-side room_roster_cache (via list_roster_cache / cached_roster_
      # members / cached_leader in bridge_rooms_common.py) so a NON-leader node
      # sees a room it joined instead of "not found". FIX 2 (info-hygiene):
      # enqueue_via_bridge_task in bridge-handoffd.py returns a TERSE peer-facing
      # detail (no `agb list` roster dump) while the full reason stays in the
      # local audit only. rooms-p4-5-polish pins both: member show/list surfaces
      # the cache, leader rooms unchanged, unknown-room still 404; an unknown
      # target -> terse 422 with no engine/workdir/source leak + full local audit.
      # Issue #1563 PR-4 (rc2 daemon redesign §A2A healthz): the A2A receiver
      # SUPERVISION policy. bridge-handoffd.py tags its startup audit rows with
      # phase=config (non-transient) vs phase=bind (potentially-transient); the
      # classifier in lib/daemon-helpers/a2a-receiver-exit-cause.py maps those to
      # error_class transient|auth_config; the policy helpers in lib/bridge-a2a.sh
      # (bridge_a2a_backoff_seconds / breaker_should_open / supervise_decision)
      # drive bounded exponential backoff + a circuit breaker keyed by
      # (config-fingerprint, error_class). 1563-pr4-a2a-receiver-healthz pins:
      # transient bind-unavailable backs off (no immediate respawn) then OPENS
      # the breaker + escalates ONCE; auth/config errors are HELD (never thrashed);
      # a successful bind / window reset clears the breaker; the escalation
      # task-create failure is audited; AND — critically — the fail-closed bind
      # proof / HMAC 401 / allowlist 403 are UNCHANGED (the healthz change is
      # supervision-only). Pull on every move to the receiver, the policy helpers,
      # or the exit-cause classifier so the anti-thrash + fail-closed teeth cannot
      # regress. The #1563 PR-5 integration matrix also sources the A2A policy
      # helpers + the exit-cause classifier for its ROW7 backoff/decision +
      # fail-closed-intact assertions, so pull it on these A2A moves too.
      # Issue #1563 PR-8 (rc2 A2A subtrack): A2A diagnostic + recovery
      # hardening. bridge-a2a.py grows `diagnose-stuck` (directional leg
      # classification from local healthz + peer TCP + tailscale tx/rx, plus
      # the probe-gated backoff reset) and preserves last_error on ack;
      # bridge-daemon.sh's stuck-scan invokes it + enriches the alert body via
      # bridge-daemon-helpers.py's a2a-diag-lookup. 1563-pr8-a2a-diag-recovery
      # pins: probe-SUCCESS->reset / probe-FAIL->preserve / leased->never-reset
      # (the anti-thrash teeth), the leg classifier, the actionable alert
      # fields, and the ack history-preservation. Pull on every bridge-a2a.py
      # move so the recovery reset + the fail-closed-untouched boundary cannot
      # regress.
      # Issue #1575 Part B (A2A network-instability recovery): the outbox
      # backoff CEILING cap. bridge_a2a_common.py grows
      # DEFAULT_DELIVERY_BACKOFF_CEILING_SECONDS (120, was 3600) +
      # delivery_backoff_ceiling(cfg) (config key + BRIDGE_A2A_BACKOFF_CEILING_
      # SECONDS env override, floored at the base step); backoff_seconds()
      # defaults to it; bridge-a2a.py:_schedule_retry reads it, passes it as the
      # ceiling, keeps base 15 + full jitter, and bounds an untrusted Retry-After
      # by the two-cap model (delivery_max_retry_after_seconds, #1589 two-cap).
      # 1575b-a2a-backoff-ceiling pins: the curve clamp, the ceiling precedence
      # (default/config/env/floor + non-numeric fallback), the end-to-end
      # _schedule_retry delay <= ceiling+jitter, the two-cap Retry-After floor,
      # and the non-finite guard. Pull on every move to either file so a
      # recovered peer's retry rows cannot regress to a multi-minute dormant backoff.
      # #1589 (A2A audit B1-B8): a2a-backpressure-openonly pins the in-transaction
      # OPEN-only backpressure count + the reaper / recover / deadline regressions.
      # Issue #1612: bridge-upgrade.sh cycles the receiver via this script's
      # `restart` subcommand on `upgrade --restart-daemon` (the receiver has no
      # hot-reload). Pull 1612-upgrade-restart-receiver whenever the receiver
      # lifecycle script / lib-a2a moves so a change to the status output shape
      # or the restart subcommand cannot silently break the upgrade-time cycle.
      # Issue #1618: bridge-a2a.py's `outbox retry` resets attempts=0 (alongside
      # next_attempt_ts=0) so a manual retry of a dead/retry row walks the backoff
      # ladder from the base interval instead of one-shot-then-ceiling /
      # re-dead-letter. 1618-outbox-retry-resets-attempts drives the REAL
      # cmd_outbox retry path + _schedule_retry; pull it on every bridge-a2a.py
      # move so the attempt-reset cannot regress to the preserve-attempts footgun.
      # Issue #1628: bridge-a2a.py's cmd_deliver wraps each `_deliver_one` in a
      # per-row guard so one un-deliverable row (unreadable body -> PermissionError
      # at read_bytes, or a transient OSError) cannot unwind the whole batch.
      # 1628-a2a-deliver-per-row-guard drives the REAL cmd_deliver loop with a
      # poisoned-first + healthy-second outbox; pull it on every bridge-a2a.py
      # move so the deliver loop cannot regress to a no-guard batch-abort.
      # Issue #1630 (audit R3, root cause of #10561): the receiver
      # (bridge-handoffd.py) posts a one-shot fresh-arrival marker for the
      # created task id right after a successful enqueue so the controller
      # daemon nudges it on the next tick instead of waiting out the ~60s
      # redelivery-age gate. Pull 1630 on every receiver move so the
      # marker-post (and its bypass-only-the-age-gate invariant) cannot
      # regress.
      # Issue #1629 (audit R2, HIGH): the receiver's GET /healthz liveness probe
      # is EXEMPT from the request-concurrency semaphore. process_request
      # (bridge-handoffd.py) MSG_PEEKs the request line before the semaphore
      # acquire and dispatches GET <healthz_path> WITHOUT a slot, so a
      # saturated-but-healthy receiver still answers liveness 200 instead of 503
      # (which the supervisor would misread as DOWN and restart mid-handoff). The
      # semaphore release is conditional so the exempt probe never over-releases
      # the BoundedSemaphore. 1629-healthz-not-semaphore-gated pins: healthz 200
      # while every slot is held (real request 503 negative control), the idle
      # baseline, AND — critically — the fail-closed boundary (bad HMAC -> 401,
      # unknown peer -> 403) is UNCHANGED. Pull on every receiver move so the
      # exemption + the untouched auth boundary cannot regress.
      # Issue #1716 (v0.16.5 A2A mesh Lane 0): bridge-handoffd.py:reconcile_once
      # now drives the ordered idempotent reconcile sequence
      # (stable-addr → bind-reprove → tunnel-health → peer-reachability →
      # roster-epoch) through the durable backoff store in
      # bridge_reconcile_common.py (state/handoff/reconcile.db). The four
      # adapter SEAMS are stubs the staged lanes fill. v0165-l0-reconcile-
      # skeleton pins the framework contract (idempotence, bounded exp-backoff
      # + cap + converged-reset, the no-secret status snapshot, and the
      # fail-safe that a raising adapter never crashes the tick). Pull it on
      # every receiver/common move so a later lane cannot regress the loop.
      # Issue #1706 (v0.16.5 A2A mesh Lane 2): the tunnel_health adapter SEAM is
      # now filled — per-transport substrate freshness (WARP MASQUE handshake
      # age vs Tailscale status) with a bounded, injectable WARP auto-bounce on
      # a proven-stale handshake (paced by the same reconcile.db backoff gate).
      # v0165-l2-tunnel-health pins active-transport-only probing, the
      # converged/degraded/unknowable result contract, the no-bounce-on-fresh /
      # no-bounce-on-parse-failure invariants, and no-secret fields. Pull it on
      # every receiver/common move so the adapter cannot regress.
      # Issue #1707 (v0.16.5 A2A mesh Lane 3): the peer_reachability_step adapter
      # SEAM is now filled — a per-peer hysteretic UP→SUSPECT→DOWN→(recovery)→UP
      # state machine via an injectable outbound TCP probe, per-peer backoff via
      # the reconcile.db gate, and an IP-drift LAN→WARP rebind that RECORDS the
      # desired listen.address via stable_local_addr (never binds — resolve_bind
      # stays the bind oracle). v0165-l3-peer-reachability pins the hysteresis
      # (no single-probe flap), recovery, bounded pacing, per-peer isolation,
      # the IP-drift record-not-bind contract, fail-closed probe-failure
      # (unknowable != UP), and no-secret state/fields. Pull it on every
      # receiver/common move so the FSM cannot regress.
      # Issue #1728 (v0.16.6 Lane E): the test-bind state-path guard. The
      # BRIDGE_A2A_ALLOW_TEST_BIND flag gated the loopback bind but NOT the
      # state path — a test mesh inheriting a live BRIDGE_STATE_DIR could
      # clobber the live rooms.db/reconcile.db/outbox/inbox. The guard
      # (guard_test_bind_state_path in bridge_a2a_common.py + bridge_rooms_
      # common.py, called from ensure_handoff_dirs / _connect / cmd_serve)
      # fails closed when the resolved state dir is outside BRIDGE_HOME under
      # the test-only flag. 1728-test-bind-state-path-guard pins fail-closed
      # under the footgun, prod-path-unchanged, and the opt-in gating. Pull it
      # on every receiver/common move so the guard cannot regress.
      add_required a2a-cross-bridge queue I-beta4-a2a-3-gaps J-beta4-workflow-docs beta5-2-lambda-a2a-robustness a2a-tailscale-identity-resolve a2a-daemon-selfheal-reconcile a2a-migrate-identity a2a-ip-change-announce 1405-handoffd-supervision 1679-1680-a2a-receiver-supervisor-robustness a2a-setup-wizard a2a-rooms-p1a a2a-rooms-p1b-acl a2a-rooms-1517-bootstrap 1398-a2a-inbound-stopped-target-force a2a-backpressure-openonly 1623-a2a-backpressure-failopen rooms-p4-1-cross-node-join rooms-p4-2-roster-broadcast rooms-p4-3-room-talk 1594-rooms-fanout rooms-p4-5-polish 1563-pr4-a2a-receiver-healthz 1563-pr5-fp-control-matrix 1563-pr8-a2a-diag-recovery 1575b-a2a-backoff-ceiling 1618-outbox-retry-resets-attempts 1628-a2a-deliver-per-row-guard 1595-cloudflare-warp-mesh 1758-trusted-routed-transport 1612-upgrade-restart-receiver 1630-a2a-fresh-arrival-nudge 1629-healthz-not-semaphore-gated 1701-warp-healthz-socket-held 1697-a2a-net-status 1685-receiver-staleness-selfheal v0165-l0-reconcile-skeleton v0165-l2-tunnel-health v0165-l1-stable-addr v0165-l3-peer-reachability v0165-l4-token-join v0165-l5-relay-roster v0165-l6-net-status-v2 v0166-la-tunnel-bounce-gate v0166-lb-transient-peers 1728-test-bind-state-path-guard
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
      # Issue #1463: bridge-daemon.sh's cmd_restart is now launchd-aware
      # (cycles launchd's own job via `launchctl kickstart -k` instead of an
      # out-of-band stop+start so the launchd KeepAlive job never thrashes
      # against the singleton lock), and _bridge_daemon_on_exit now removes
      # the pid-file ONLY when it still holds its own pid (a losing launchd
      # competitor must not delete the true holder's pid-file → false
      # `stopped pid=-`). Pull 1463-launchd-keepalive-singleton-thrash on
      # every bridge-daemon.sh move so neither the launchd restart path nor
      # the pid-file ownership guard can silently regress.
      # Issue #1563 PR-2: bridge-daemon.sh's cmd_run now runs each scheduler
      # tick via the runner-process supervisor
      # (bridge_daemon_run_tick_supervised) and `exit`s non-zero on the wedge
      # rc (T1 self-abort → OS-init restart), and cmd_sync_cycle refreshes the
      # progress heartbeat around the long bounded steps
      # (_bridge_daemon_mark_progress). Pull 1563-pr2-daemon-self-abort on
      # every bridge-daemon.sh move so neither the supervisor wiring, the
      # wedge-rc exit, nor the progress markers (the negative-control plumbing
      # that keeps a HEALTHY long step from self-aborting) can silently regress.
      # Issue #1563 PR-4: process_a2a_receiver_supervise_tick in bridge-daemon.sh
      # now classifies the receiver exit (transient vs auth/config), applies
      # bounded backoff + a circuit breaker, and escalates once per cooldown via
      # the shared bridge_a2a_receiver_escalate helper. Pull
      # 1563-pr4-a2a-receiver-healthz on every bridge-daemon.sh move so the
      # supervision backoff/breaker + the restart-window breaker reset + the
      # escalate-once-per-cooldown audit cannot regress.
      # Issue #1563 PR-5: the integration "false-positive control matrix" exercises
      # the COMBINED daemon-redesign behaviors (singleton PR-1 + T1 self-abort PR-2 +
      # admin-liveness escalation PR-3 + A2A receiver backoff/breaker PR-4) as one
      # flapping-monitor surface — every row asserts both the HEALTHY case is NOT
      # punished AND a teeth-revert DOES misfire. Pull 1563-pr5-fp-control-matrix on
      # every bridge-daemon.sh move so no single PR's hardening can regress without
      # the integration matrix catching the cross-behavior false-positive.
      # Issue #1563 PR-6: process_watchdog_report's report-file scan was a BARE,
      # un-bounded call that wedged the daemon main loop forever on a hung
      # bridge-watchdog.py walk (patch diagnosed live with `sample`). PR-6 routes
      # BOTH the markdown scan and the --json scan through the new
      # bridge_run_command_with_pgroup_timeout (deadline + process-GROUP kill so the
      # python3 walk + agent-bridge grandchild cannot orphan). Pull
      # 1563-pr6-watchdog-scan-timeout on every bridge-daemon.sh move so a future PR
      # cannot silently re-introduce the bare un-bounded scan or regress the
      # group-kill (the orphan-killed teeth).
      # Issue #1579 (#1563 PR-7): cmd_sync_cycle now cadence-gates the EXPENSIVE
      # PERIODIC per-agent passes (channel-health, plugin-liveness, the per-agent
      # context-pressure / stall scans, the unclaimed sweeps, crash/memory
      # housekeeping) via bridge_daemon_pass_due (~30s, env-overridable) while the
      # TIME-CRITICAL delivery/escalation passes stay EVERY tick — root cause 2 of
      # the slow-tick (#10099) finding. Pull 1563-pr7-tick-cadence on every
      # bridge-daemon.sh move so neither the gate helper, the periodic-vs-time-
      # critical split (a wrongly-gated delivery pass = a latency regression), nor
      # the mark-before-due-check heartbeat ordering can silently regress.
      # Issue #1629 (audit R2, HIGH): the supervisor's GET /healthz probe
      # (process_a2a_receiver_supervise_tick) must read alive from a saturated
      # receiver — the receiver-side semaphore exemption (bridge-handoffd.py) is
      # what prevents the busy-but-healthy 503 -> misclassify DOWN -> restart
      # mid-handoff loop. Pull 1629-healthz-not-semaphore-gated on every
      # bridge-daemon.sh move so a supervisor change cannot reintroduce the
      # self-inflicted restart-under-load by relying on a probe the receiver
      # would 503 under saturation.
      # Issue #1652 (CRITICAL queue-gateway socket listener crash-loop): the
      # daemon's bridge_queue_gateway_socket_clean_stale now requires N
      # consecutive connect-probe failures (bridge_queue_gateway_socket_probe_persistently_dead)
      # before removing a live-pid's socket, so a single transient probe flap
      # can no longer rm a healthy listener's bound socket. Pull
      # 1652-queue-gateway-crashloop on every bridge-daemon.sh move so a
      # regression to the single-miss rm cannot reopen the crash-loop.
      add_required daemon queue launch-dev-channels-injection channel-env-readiness cron-run-artifacts-retention cron-shell-runner status-engine-detect 835-static-admin-launch bridge-sync-roster-memo daemon-periodic-token-sync 1015-resume-claude-config-dir 1115-cli-usage-drift 1178-helper-contract-daemon-supp F-daemon-supp-groups-mock F-daemon-supp-groups-real δ-1234-daemon-start-policy A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir D-beta4-daemon-lifecycle A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir G-beta4-watchdog-noise I-beta4-a2a-3-gaps J-beta4-workflow-docs Beta-beta5-session-id-detect-sudo beta5-1-session-id-detect-race dev-channel-auto-accept-no-attach mcp-liveness-giveup-auto-clear beta5-2-epsilon-tmux-inject-busy beta5-2-pi-daemon-crashloop-no-set-e-leak beta5-2-kappa-state-audit-reconcile 1359-cron-create-iso-staging 1380-admin-autostart-recovery 1388-daemon-lock-fd-cloexec 1407-runtime-hardening 1405-handoffd-supervision 1679-1680-a2a-receiver-supervisor-robustness 1408-daemon-alert-nudge-hygiene 1473-agent-list-iso-state-fallback 1461-cron-max-parallel-override 1463-launchd-keepalive-singleton-thrash 1563-pr2-daemon-self-abort 1563-pr4-a2a-receiver-healthz 1563-pr5-fp-control-matrix 1563-pr6-watchdog-scan-timeout 1563-pr7-tick-cadence 1563-pr8-a2a-diag-recovery 1629-healthz-not-semaphore-gated 1685-receiver-staleness-selfheal v0165-l0-reconcile-skeleton v0165-l2-tunnel-health v0165-l1-stable-addr v0165-l3-peer-reachability v0165-l4-token-join v0165-l5-relay-roster v0165-l6-net-status-v2 v0166-la-tunnel-bounce-gate v0166-lb-transient-peers 1652-queue-gateway-crashloop 1803-orphan-dir-gc 1809-agents-md-backfill 1855-keychain-free-backfill 1833-status-gateway-timeout-not-down 1934-hook-file-self-heal
      # Issue #1899: bridge-sync.sh's refresh_missing_session_ids backfill sweep
      # now skips dynamic vanilla Codex (it must never detect/persist an operator
      # ~/.codex session id). Pull 1899 on bridge-sync.sh moves so the daemon
      # backfill no-op can't regress.
      if [[ "$path" == "bridge-sync.sh" ]]; then
        add_required 1899-dynamic-vanilla-codex
      fi
      # Issue #1855: bridge-daemon.sh gained process_keychain_free_backfill, the
      # cadence-gated hygiene pass that runs `bridge-auth.sh claude-token
      # backfill-settings` for pre-#1520 shared agents. Pull 1855 on every
      # daemon move so the backfill subcommand it drives stays in contract.
      # Issue #1630 (audit R3, root cause of #10561): the daemon nudge_scan
      # step (cmd_daemon_step, driven by bridge-daemon.sh via
      # lib/bridge-state.sh::bridge_task_daemon_step) now consumes the A2A
      # fresh-arrival markers and exempts those task ids from ONLY the
      # redelivery-age gate. Pull 1630 on every daemon / state-lib move so
      # the next-tick wake for a fresh inbound A2A task cannot regress back
      # to the ~60s age-gate hole.
      add_required 1630-a2a-fresh-arrival-nudge
      # Issue #1762: bridge-daemon.sh hosts the cadence-gated picker
      # auto-resolve scan (bridge_picker_scan_all_sessions, pass
      # picker_autoresolve) wired into cmd_sync_cycle. Pull the smoke on every
      # bridge-daemon.sh move so a refactor cannot silently drop the phase or
      # un-gate it. (lib/bridge-picker.sh / lib/bridge-picker.py have their own
      # arm below; scripts/smoke/* changes reach it via the static catch-all.)
      add_required 1762-picker-autoresolve
      # Issue #1783: the same daemon-driven scan hosts the per-pass UNKNOWN-
      # escalation storm fuse (bridge_picker_scan_all_sessions resets the cap
      # counters + emits the one summary warn line). Pull the idle-nonpicker
      # smoke on every bridge-daemon.sh move so a scan refactor cannot drop the
      # storm-fuse reset/summary wiring.
      add_required 1783-picker-idle-nonpicker
      # Fleet-credential Phase 2 (#1470): bridge-daemon.sh gained the
      # periodic Codex single-source → fleet-sync tick
      # (bridge_daemon_periodic_codex_cred_sync_tick). 1470-codex-fleet-sync
      # pins the codex-cred sync surface the tick drives; pull it on every
      # bridge-daemon.sh move so the tick wiring cannot silently regress.
      add_required 1470-codex-fleet-sync
      # Issue #1459: bridge-daemon.sh now hosts the cron-dispatch backlog
      # sweep (bridge_daemon_sweep_cron_dispatch_backlog — WRAPS the bare
      # start_cron_dispatch_workers call, emits cron_dispatch_backlog /
      # cron_dispatch_auto_recovered on before/after snapshots with a
      # cooldown marker) and the late-nudge-success sweep
      # (bridge_daemon_sweep_nudge_late_success — emits
      # session_nudge_late_success for resolved submit_lost_post_grace
      # drops). Pull 1459-cron-dispatch-recovery on every bridge-daemon.sh
      # move so the cron-vs-human taxonomy separation, the wrap-not-
      # duplicate worker-start, the idempotency, and the no-false-human-
      # alarm contract cannot silently regress.
      add_required 1459-cron-dispatch-recovery
      # Issue #1568: bridge-daemon.sh's nudge_agent_session (the routine
      # queued-task idle-nudge) now gates the attached-session skip on
      # bridge_tmux_session_inject_busy, not bare `attached > 0`. Pull
      # 1568-routine-nudge-inject-busy-gate on every bridge-daemon.sh move so a
      # revert to the bare-attach guard (which stranded queued work behind any
      # persistent tmux client, e.g. a cmux multitab) is caught.
      add_required 1568-routine-nudge-inject-busy-gate
      # Issue #1631 (A2A audit R4): bridge-daemon.sh's nudge_agent_session now
      # SKIPS this tick (daemon_subprocess_error / action=skip_this_tick) on a
      # non-timeout nudge-live-state failure, instead of falling through to
      # live_queued=0 → session_nudge_dropped_stale. Paired with the
      # bridge-daemon-helpers.py read-only DB guard (_connect_queue_db_readonly).
      # Pull 1631-nudge-helper-db-guard on every bridge-daemon.sh move so a
      # revert to the stale-drop-on-failure shape (which silently suppressed a
      # legitimately-queued task's nudge on a transient IO/env glitch) is caught.
      add_required 1631-nudge-helper-db-guard
      # PR #1790 (#1789, r3 BLOCKING 1): bridge-daemon.sh's
      # process_usage_monitor decodes the rotation-status TSV with
      # IFS=$'\t' read and maps the helper's `-` empty-column sentinel
      # back to "" per field. Pull the rotation suite on every
      # bridge-daemon.sh move so a future edit that drops the sentinel
      # decode (re-collapsing empty columns and shifting soonest_reset
      # into rotation_from) is caught by the encode/decode roundtrip case.
      add_required 1789-rotation-limited-until
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
      # Issue #1842 (CRITICAL): lib/bridge-cron.sh's
      # `bridge_cron_run_dir_grant_isolation` now grants 3770 (setgid+STICKY,
      # was 2770) on the iso TEXT-cron run dir, and the runner's tamper-check
      # exemption REQUIRES that sticky bit (the #1842 codex-r2 TOCTOU defense).
      # Pin 1842-cron-tamper-iso-groupwrite on every bridge-cron.sh move so a
      # future PR cannot drop the sticky bit out of lockstep with the runner's
      # sticky-gated exemption (silently re-opening the request.json swap
      # window or re-breaking every iso cron).
      add_required 1379-iso-cron-staging-group 1383-iso-cron-result-json-group 1842-cron-tamper-iso-groupwrite
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
      # Issue #1843 (secondary footgun): root bridge-cron.sh's run_finalize now
      # captures the native-finalize-run JSON and bridge_warn-surfaces a
      # consecutive-failure escalation (the durable audit row + payload block
      # are written by bridge-cron.py). Pull
      # 1843-cron-consecutive-failure-escalation on every bridge-cron.sh move
      # so a future PR cannot regress the finalize escalation back to silent
      # error accumulation (the 7-day field-outage class).
      add_required 1843-cron-consecutive-failure-escalation
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
      # Incident #9770 Track 2: bridge-daemon.sh's reap_idle_orphan_sessions is
      # one of the three central teardown seams that capture the codex pane
      # subtree BEFORE `tmux kill-session` and reap it after. Pull
      # 9770-codex-teardown-reap on every bridge-daemon.sh move so a refactor
      # cannot drop the capture-before-kill ordering or the skip+audit (never a
      # global sweep) when the pane PID is unresolvable.
      add_required 9770-codex-teardown-reap
      # Issue #1795: bridge-daemon.sh's reap_idle_dynamic_agents now gates the
      # reap on the disposability tag (ephemeral=="1") + a hard loop=1 skip, so
      # operator-created dynamics and relaunch-loop agents are never reaped.
      # Pull 1795-reaper-ephemeral-policy on every bridge-daemon.sh move so a
      # refactor cannot drop either new predicate or the kept-idle skip-audit
      # (which would re-open the repeated reaping of operator codex pairs).
      add_required 1795-reaper-ephemeral-policy
      # Issue #1797 NB-1: bridge-daemon.sh's reap_idle_dynamic_agents now latches
      # the keep-audit line so it fires only on a keep-decision TRANSITION (not
      # every tick). Pull 1797-reaper-keep-audit-latch on every bridge-daemon.sh
      # move so a refactor cannot revert to a per-tick daemon_info and re-open the
      # log-volume regression.
      add_required 1797-reaper-keep-audit-latch
      # PR-B / #1520b: bridge-daemon.sh's bridge_daemon_autostart_allowed
      # gained the credential-pending hold predicate (return-hold-without-
      # backoff while the marker is present + the credential absent, lazy
      # self-clear once a non-empty .credentials.json lands, no bridge-auth.sh
      # source). The gate is consulted by all three start surfaces (warm
      # always-on, on-demand queued, cron-dispatch wake). Pull the smoke on
      # every bridge-daemon.sh move so a refactor cannot drop the hold,
      # start writing backoff state on a hold, or remove the lazy self-clear.
      add_required 1520b-create-time-creds-sync
      # #9819 A/B (rc2 #1563 PR-3): bridge-daemon.sh gained the admin-liveness
      # escalation tick (process_daemon_admin_liveness_escalation) + the
      # MCP-liveness-giveup admin escalation (bridge_daemon_mcp_giveup_escalate_admin).
      # Pull 1563-pr3-daemon-escalation on every bridge-daemon.sh move so a
      # refactor cannot (a) regress the conservative admin-down predicate into
      # the flapping-monitor irony (escalating a busy/idle-but-alive admin),
      # (b) re-swallow the escalation task-create failure (drop the
      # daemon_escalation_task_create_failed audit + retry retention), or
      # (c) drop the patch-dev fallback / giveup→admin-task routing.
      add_required 1563-pr3-daemon-escalation
      # Issue #1181: bridge-daemon.sh's nudge_agent_session now probes the live
      # blocker state before emitting session_nudge_dropped and tags the audit
      # row reason=modal_<state> (keeping submit_lost_post_grace reserved for the
      # #331 composer race); the late-success sweep no longer pins to that one
      # reason string. Pull the smoke on every bridge-daemon.sh move so a
      # refactor cannot drop the modal-reason tagging.
      if [[ "$path" == "bridge-daemon.sh" ]]; then
        add_required 1181-modal-blocker-detect
        # Issue #1738 r2 (BLOCKER 2): bridge-daemon.sh's reconcile pass now
        # prunes config-caller bindings whose tmux session is gone
        # (bridge_daemon_prune_orphan_config_caller_bindings, via the
        # lib/daemon-helpers/config-binding-list.py lister). Pull the adversarial
        # binding smoke on every bridge-daemon.sh move so a refactor cannot drop
        # the orphan-prune (which would re-open the PID-reuse forgery window).
        add_required 1738-config-caller-binding
      fi
      add_integration integration-minimal
      add_live live-tmux-daemon
      ;;

    lib/daemon-helpers/config-binding-list.py)
      # Issue #1738 r2 (BLOCKER 2): this helper lists config-caller bindings as
      # `<agent>\t<session>` rows for the daemon orphan-prune. Pull the
      # adversarial binding smoke on every move so a change to the row shape /
      # parse cannot silently break the prune (re-opening the PID-reuse window).
      add_required 1738-config-caller-binding
      ;;

    lib/daemon-helpers/config-binding-record.py)
      # Issue #1738 r3 (FIX 3): this helper emits a present binding's stale-check
      # fields (`<pane_pid>\t<agent_id>\t<admin_agent_id>`) so the daemon
      # self-heal can republish a present-but-stale record. Pull the binding
      # smoke on every move so a change to the field shape / parse cannot
      # silently break the stale-record repair.
      add_required 1738-config-caller-binding
      ;;

    lib/daemon-helpers/hook-file-missing-scan.py)
      # Issue #1934 (facet 2): this helper scans an agent's rendered hook command
      # paths for an absent FILE; the daemon `bridge_daemon_reheal_missing_hook_files`
      # reconcile arm uses its `ok`/`missing` result to force a self-heal re-render.
      # Pull the self-heal smoke on every move so a change to the scan output / the
      # basename allowlist cannot silently break the missing-hook recovery (the
      # cm-prod farm-outage class). The canonical-fence smoke rides along since the
      # re-render and the renderer share the `_stable_hooks_dir` builders.
      add_required 1934-hook-file-self-heal 1934-hook-path-canonical-fence
      ;;

    scripts/python-helpers/config-caller-binding-write.py)
      # Issue #1738 r5 (FIX C): this helper writes the binding record, including
      # the `owner_uid` field the wrapper's pane-owner check requires (the
      # kernel-boundary closer for the iso forged-pid exploit). Pull the binding
      # smoke on every move so a change to the record schema (dropping owner_uid)
      # cannot silently disable the owner check and re-open the forged-pid window.
      add_required 1738-config-caller-binding
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
      # Incident #9770 Track 2: the reaper now hosts the surgical per-session
      # subtree mode (capture_subtree / reap_captured / kill_pid_subtree +
      # SUBTREE_ALLOWLIST_PATTERNS, kept OUT of DEFAULT_PATTERNS). Pull
      # 9770-codex-teardown-reap on every reaper move so a refactor cannot
      # weaken the #1 invariant (a live roster codex / in-progress review is
      # never killed), leak codex names into the global DEFAULT_PATTERNS, or
      # regress the per-signal PID-reuse revalidation.
      add_required 9770-codex-teardown-reap
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
      # Issue #1463: lib/bridge-daemon-control.sh now hosts the canonical
      # launchd-aware restart primitive (bridge_daemon_launchd_restart +
      # _bridge_daemon_launchd_label / _bridge_daemon_launchd_job_pid),
      # which cycles launchd's own job via `launchctl kickstart -k` and
      # REFUSES (rc=2) when the live lock holder is not launchd's job pid
      # (out-of-band split). Pull 1463-launchd-keepalive-singleton-thrash on
      # every move so the kickstart path, the split-detection refusal, and
      # the non-launchd fall-through cannot silently regress.
      # Issue #1563 PR-2: lib/bridge-daemon-control.sh now hosts the T1
      # runner-process supervisor (bridge_daemon_run_tick_supervised +
      # bridge_daemon_tick_deadline_seconds / _progress_touch / _progress_age /
      # bridge_daemon_sd_notify), and install-daemon-systemd.sh renders the
      # optional Type=notify + WatchdogSec outer ring (--watchdog) on top of
      # the existing Restart=always. Pull 1563-pr2-daemon-self-abort on every
      # move so the max-step-budget deadline (NOT nudge-latency), the
      # process-group kill, the structured daemon_tick_deadline_exceeded audit,
      # and the systemd watchdog wiring cannot silently regress.
      # Issue #1563 PR-5: lib/bridge-daemon-control.sh also hosts the singleton
      # (PR-1) + state-counter primitives the integration matrix sources for its
      # ROW1-4 false-positive controls. Pull 1563-daemon-singleton +
      # 1563-pr5-fp-control-matrix on every control-lib move so a revert of the
      # singleton/self-abort hardening fails the integration matrix too.
      # Issue #1563 PR-6: lib/bridge-daemon-control.sh's
      # _BRIDGE_DAEMON_TICK_STEP_TIMEOUT_KNOBS list now includes
      # BRIDGE_WATCHDOG_SCAN_TIMEOUT_SECONDS (codex r1) so a healthy operator-
      # RAISED watchdog scan ceiling widens the T1 self-abort deadline rather
      # than tripping it. The 1563-pr2 smoke's E5 multi-knob assertion pins the
      # coupling; pull 1563-pr6-watchdog-scan-timeout too so the watchdog-scan
      # helper's own contract is re-checked on a knob-list move.
      # Issue #1667: lib/bridge-daemon-control.sh's _bridge_daemon_control_lock_acquire
      # now returns its token via the BRIDGE_DAEMON_CONTROL_LOCK_TOKEN global and
      # is called DIRECTLY (never under `$()`, which closed the flock fd in the
      # subshell and released the daemon-refresh lock early — no mutual exclusion
      # for the re-check/restart critical section). Pull 1667-daemon-control-lock-
      # serialize on every move so the direct-acquire-holds-across-section
      # guarantee, the regression witness for the old `$()` pattern, and the
      # no-`$()`-capture call-site wiring cannot silently regress.
      add_required F-daemon-supp-groups-mock F-daemon-supp-groups-real 1178-helper-contract-daemon-supp A12-beta3-1246-1252-daemon-supp-group-and-state-dir D-beta4-daemon-lifecycle F-beta4-oauth-bootstrap 1388-daemon-lock-fd-cloexec 1463-launchd-keepalive-singleton-thrash 9882-daemon-audit-fp 1563-daemon-singleton 1563-pr2-daemon-self-abort 1563-pr5-fp-control-matrix 1563-pr6-watchdog-scan-timeout 1667-daemon-control-lock-serialize
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
      # Issue #1842: the runner's iso-group-write tamper exemption mirrors
      # staging.py's `_canonical_actor_group_names` (same ab-agent-<a> +
      # hash-truncated derivation). Pin 1842-cron-tamper-iso-groupwrite on
      # cron-helpers moves so a change to the group-name policy stays
      # co-verified against the tamper-check exemption.
      add_required cron-run-artifacts-retention cron-shell-runner beta5-2-eta-cron-iso-uid-preflight 1359-cron-create-iso-staging 1379-iso-cron-staging-group 1383-iso-cron-result-json-group 1842-cron-tamper-iso-groupwrite queue
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
      # Issue #1459: bridge-cron.py's run_reconcile_run_state now covers
      # the 3 split-brain cases (queue-done/run-queued, queued-dispatch-lost,
      # running-worker-stale) beyond the legacy cancelled case, and emits
      # cron_dispatch_reconcile. Pull 1459-cron-dispatch-recovery on every
      # bridge-cron.py move so the reconcile case matrix + the
      # worker-evidence/grace guard (never false-positive a live run) cannot
      # regress.
      # Issue #1659: bridge-cron-scheduler.py's cron matcher is now memoized
      # (allowed_values -> bounded LRU of immutable frozensets), collapsing the
      # 45.9M expand_atom calls the agb-status cadence walk made on a large
      # cron-run-record backlog. Pull 1659-cron-status-walk-perf on every
      # scheduler move so a future PR cannot drop the memoization (or return a
      # mutable set a caller could corrupt) and regress agb-status back to its
      # ~84s O(run-records x window-minutes x fields) walk.
      # Issue #1677 (v0.16.3): bridge-cron-runner.py's validate_result no longer
      # raises a fatal ValueError on a schema-valid summary_short=null/empty/
      # overlong for a non-silent delivery_intent — it derives the digest from
      # the required non-empty `summary` (first non-empty line) and VISIBLY
      # truncates to ≤ SUMMARY_SHORT_MAX, preserving the rest of the child's
      # valid signal instead of substituting the generic error envelope. Pull
      # 1677-cron-summary-short-derive on every runner move so a future PR
      # cannot re-introduce the fatal raise, regress to silent truncation, make
      # an empty `summary` non-fatal, or leak the scope fence (bad
      # forward_target must stay fatal).
      # Issue #1826: bridge-cron.py's parse_at_datetime now anchors a NAIVE
      # `--at` in `--tz` (host-local when omitted) instead of the host zone,
      # preserves an explicit offset / `Z` unchanged, errors loudly on an
      # unhonorable `--tz` (no silent drop), and echoes the resolved instant in
      # local + UTC. Pull 1826-cron-at-naive-tz on every bridge-cron.py /
      # scheduler move so a future PR cannot regress naive-`--at` back to the
      # host-zone reinterpretation, drop `--tz`, or break DST-correct anchoring.
      # Issue #1792: bridge-cron-runner.py's build_prompt now appends the
      # job-name-parameterized SCOPE FENCE block (the cheap, big-win mitigation
      # for cron-child scope creep) and exports BRIDGE_CRON_RUN_ID into the
      # dispatched child env so a task it creates is attributable. Pull
      # 1792-cron-scope-fence on every runner move so a future PR cannot drop the
      # fence header, stop interpolating the job title, drop a load-bearing
      # prohibition, or stop threading the run-id origin stamp.
      # Issue #1843 (secondary footgun): bridge-cron.py's native-finalize-run
      # now trips a `cron_consecutive_failure_escalated` audit row + payload
      # `escalation` block when back-to-back cron failures cross the
      # threshold/cadence, so a chronically-broken cron (the 7-day silent
      # outage class) can no longer accumulate errors invisibly. Pull
      # 1843-cron-consecutive-failure-escalation on every bridge-cron.py move
      # so a future PR cannot drop the escalation, regress the threshold/
      # cadence boundary, or stop clearing the provenance marker on success.
      # rc3 BLOCKER 2: build_prompt's scope fence now also REFUSES auto-exec of
      # irreversible/prod-mutation operations (`agb upgrade`, release/tag,
      # fleet/roster mutation) and any interactive-gated (`blocked`) task — the
      # cm-prod cron-worker-auto-ran-a-held-`agb upgrade` incident. Pull
      # 1875-cron-prod-mutation-guard on every runner move so a future PR cannot
      # drop the prod-mutation/interactive-gated refusal or over-block routine
      # cron jobs.
      # Issue #1880: bridge-cron-runner.py's run_claude/run_codex now pass an
      # EXPLICIT --model (and codex reasoning effort) resolved by
      # resolve_cron_child_model_effort (per-job jobs.json → cron-default →
      # roster accessor → BRIDGE_CRON_DEFAULT_MODEL env), so the disposable cron
      # child never inherits the interactive `.claude/settings.json` model that
      # `/model` writes; bridge-cron.py's native-create/native-update persist the
      # per-job + cronDefaults fields. Pull 1880-cron-explicit-model on every
      # runner/bridge-cron.py move so a future PR cannot drop the explicit
      # --model, regress the precedence order, or re-couple the child to the
      # interactive settings.json (the entitlement-drop 404 incident).
      add_required cron-run-artifacts-retention cron-migrate-payloads cron-mutation-audit cron-shell-runner cron-runner-schema-openai-strict cron-path-augmentation-874 queue beta5-2-eta-cron-iso-uid-preflight 1359-cron-create-iso-staging 1379-iso-cron-staging-group 1383-iso-cron-result-json-group 8807-cron-backfill-coalesce 1459-cron-dispatch-recovery 1659-cron-status-walk-perf 1677-cron-summary-short-derive 1792-cron-scope-fence 1875-cron-prod-mutation-guard 1843-cron-consecutive-failure-escalation 1826-cron-at-naive-tz 1842-cron-tamper-iso-groupwrite 1880-cron-explicit-model
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
add_required launch launch-dev-channels-injection tmux-injection upgrade-source-preservation upgrade-shared-settings-propagate agent-create-name-validation agent-create-caller-trust-gate agent-create-idle-timeout 1105-agent-add-audit 1100-audit-since-tz agent-update agent-update-launch-cmd-redaction 1122-admin-auto-caller-source 1136-always-on-no agent-doctor upgrade-conflicts-lifecycle 1601-conflicts-adopt-guard managed-autocompact-window per-agent-settings-rendering 1756-settings-preserve-model-user-keys status-engine-detect 835-static-admin-launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup 1400-purge-home-degrade-no-sudo 1028-isolated-workdir-check 1118-v2-engine-binary-path v2-scaffold-home-and-workdir 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair 1067-codex-provisioning 1115-cli-usage-drift 1151-step-a-helper 1155-bootstrap-skill-guard 1158-marker-load-order 1165-track-a-scaffold-modes 1213-iso-uid-predicate beta27-D-inject-timestamp-resolved I-agent-description-roster γ-cli-consistency C1-beta3-1251-restart-preflight-rollback A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir K-beta4-nits α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-epsilon-tmux-inject-busy beta5-2-theta-upgrade-backfill-perms 1360-onboarding-next-actions-persona 1409-claude-midturn-busy-gate 1639-post-restart-auto-wake 1425-spool-rederive 1617-pending-attention-arrival-stale 1513-iso-teams-prune-eacces plugin-requires-resolver 1520-shared-claude-config-dir 1520b-create-time-creds-sync 1417-identity-sync-on-start 1638-settings-cosmetic-conflict 1675-1694-settings-homebrew-abspath-conflict 1769-freshness-gate-resume 1753-hud-config-seed
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
      # Issue #9981: lib/bridge-tmux.sh hosts the pending-attention spool
      # lock loop (bridge_tmux_pending_attention_with_lock) that gained the
      # EACCES fast-fail (a single warning instead of a 200-retry spin when
      # the spool dir is unwritable), and bridge-send.sh's `urgent` path
      # drives the spool append. Pull 9981-iso-urgent-instant-wake whenever
      # bridge-tmux.sh or bridge-send.sh moves so a refactor cannot silently
      # revert the fast-fail back to the 200-retry giveup the live incident
      # showed.
      if [[ "$path" == "lib/bridge-tmux.sh" || "$path" == "bridge-send.sh" ]]; then
        add_required 9981-iso-urgent-instant-wake
      fi
      # Issue #1640: bridge-send.sh's urgent path now parses `--from <agent>`
      # and threads it into infer_actor_if_possible (sender-attribution
      # override, mirroring `task create --from`); the agent-bridge/agb wrapper
      # documents it in the `urgent --help` text. Pull 1640-urgent-from-override
      # whenever bridge-send.sh or the CLI wrapper moves so a refactor cannot
      # silently re-reject `--from` (the catch-all "알 수 없는 옵션") or drop the
      # override back to forced auto-inference.
      if [[ "$path" == "bridge-send.sh" || "$path" == "agent-bridge" || "$path" == "agb" ]]; then
        add_required 1640-urgent-from-override
      fi
      # Issue #9981 (read side): lib/bridge-tmux.sh hosts
      # bridge_tmux_pending_attention_publish_group_read, which publishes the
      # spool file group-readable (chgrp ab-agent-<a> + chmod 0640, iso-v2
      # effective only) so the ISO AGENT — the wake consumer that reads the
      # spool via hooks/bridge_hook_common.py — can read its instant-wake
      # count. Without the publish the file lands umask-077 0600 and the agent
      # read EACCES → silent zero events. Pull the read-side smoke on every
      # bridge-tmux.sh move so a refactor cannot silently drop the publish back
      # to owner-only.
      if [[ "$path" == "lib/bridge-tmux.sh" ]]; then
        add_required 9981-iso-pending-attention-readable
      fi
      # Issue #1617: lib/bridge-tmux.sh hosts
      # bridge_tmux_pending_attention_flush + the unified task-ref staleness
      # gate (bridge_tmux_pending_attention_task_ref_id/_is_done) that drops a
      # deferred `task #N` notification (arrival OR completion) when the
      # referenced task is already done. Pull the arrival-stale smoke (and the
      # #1425/#1952 rederive regression it generalizes) on every bridge-tmux.sh
      # move so a refactor cannot silently regress the gate back to a per-type
      # matcher (which re-leaks stale arrival nudges) or weaken the fail-safe
      # KEEP-on-read-failure invariant.
      if [[ "$path" == "lib/bridge-tmux.sh" ]]; then
        add_required 1617-pending-attention-arrival-stale 1425-spool-rederive
      fi
      # Issue #1762: lib/bridge-tmux.sh hosts the picker keystroke primitive
      # bridge_tmux_send_picker_key — the ONLY keystroke path the picker
      # resolver is allowed to use (high-risk #2). Pull the picker smoke on
      # every bridge-tmux.sh move so a refactor cannot drop the primitive or
      # let the resolver fall back to raw send-keys.
      if [[ "$path" == "lib/bridge-tmux.sh" ]]; then
        add_required 1762-picker-autoresolve
        # Issue #1783: the idle-nonpicker smoke drives the same resolver
        # keystroke path (idle composers must never key); pull it too.
        add_required 1783-picker-idle-nonpicker
        # Issue #1181: lib/bridge-tmux.sh hosts
        # bridge_tmux_claude_blocker_state_from_text (the new feedback_survey /
        # permission_grant / overwrite_confirm / context_pressure branches) and
        # the shared bridge_tmux_claude_blocker_state_is_block predicate. Pull
        # the smoke on every bridge-tmux.sh move so a refactor cannot drop a
        # modal signature, regress the trailing none default, or let the
        # is_block list drift from the snapshot/wake surfaces.
        add_required 1181-modal-blocker-detect
      fi
      # Fleet-credential Phase 2 (#1470, Q6): bridge-run.sh's entry envelope
      # now active-scrubs the OpenAI-key / Codex-token ambient env vars and
      # restores them ONLY for an explicitly unmanaged Codex run
      # (bridge_run_apply_codex_ambient_env at the launch site). Pull
      # 1470-codex-fleet-sync on every bridge-run.sh move so a refactor of
      # the launch envelope cannot silently re-leak a managed Codex agent's
      # ambient key into the child process.
      add_required 1470-codex-fleet-sync
      # v0.15.0-beta5-2 Lane κ (#1319 H1): bridge-agent.sh hosts
      # `bridge_agent_activity_state` which is the second of the three
      # resolvers that emit `picker_blocked` (alongside the snapshot
      # writer in lib/bridge-state.sh and the heartbeat path in
      # bridge-daemon.sh). Pull beta5-2-kappa-state-audit-reconcile on
      # every bridge-agent.sh move so the predicate call and branch
      # ordering cannot silently regress.
      add_required beta5-2-kappa-state-audit-reconcile
      # Issue #1639: bridge-start.sh propagates BRIDGE_AUTO_RESTART_WAKE=1 into
      # the SESSION_CMD env prefix ONLY on a non-interactive (ATTACH=0)
      # auto-restart launch, and bridge-run.sh's
      # bridge_run_schedule_idle_marker_and_inbox_bootstrap widens the
      # first-turn inbox-bootstrap inject to fire on an auto-restart even when
      # the persistent initial-inbox marker already exists (so a post-restart
      # Claude session does not sit idle). 1639-post-restart-auto-wake pins both
      # the dry-run discriminator and the wake decision matrix; pull it whenever
      # bridge-run.sh or bridge-start.sh moves so a future PR cannot silently
      # regress the auto-restart-only gate or re-leak the marker-suppression bug.
      if [[ "$path" == "bridge-run.sh" || "$path" == "bridge-start.sh" ]]; then
        add_required 1639-post-restart-auto-wake
      fi
      # Issue #1738 (SECURITY): bridge-start.sh publishes the config-caller
      # pane-pid binding (bridge_publish_config_caller_binding) after tmux
      # new-session — the unspoofable signal bridge-config.py's `config set` /
      # `set-env` write gate matches its process ancestry against. Pull the
      # adversarial binding smoke whenever bridge-start.sh moves so a future PR
      # cannot drop the publish call or break the binding shape.
      if [[ "$path" == "bridge-start.sh" ]]; then
        add_required 1738-config-caller-binding
      fi
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
add_required launch launch-dev-channels-injection tmux-injection upgrade-source-preservation upgrade-shared-settings-propagate agent-create-name-validation agent-create-caller-trust-gate agent-create-idle-timeout 1105-agent-add-audit 1100-audit-since-tz agent-update agent-update-launch-cmd-redaction 1122-admin-auto-caller-source 1136-always-on-no agent-doctor upgrade-conflicts-lifecycle 1601-conflicts-adopt-guard managed-autocompact-window per-agent-settings-rendering 1756-settings-preserve-model-user-keys status-engine-detect 835-static-admin-launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup 1400-purge-home-degrade-no-sudo 1028-isolated-workdir-check 1118-v2-engine-binary-path v2-scaffold-home-and-workdir 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair 1067-codex-provisioning 1115-cli-usage-drift 1151-step-a-helper 1155-bootstrap-skill-guard 1158-marker-load-order 1165-track-a-scaffold-modes 1213-iso-uid-predicate beta27-D-inject-timestamp-resolved I-agent-description-roster γ-cli-consistency C1-beta3-1251-restart-preflight-rollback A3-beta3-1248-restart-session-id-resume A12-beta3-1246-1252-daemon-supp-group-and-state-dir A-beta4-iso-path-resolution E-beta4-fresh-install-gate-state-dir K-beta4-nits α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-epsilon-tmux-inject-busy beta5-2-theta-upgrade-backfill-perms beta5-2-xi-misc-fixes 1360-onboarding-next-actions-persona 1639-post-restart-auto-wake 1425-spool-rederive 1617-pending-attention-arrival-stale 1513-iso-teams-prune-eacces plugin-requires-resolver 1520-shared-claude-config-dir 1520b-create-time-creds-sync 1638-settings-cosmetic-conflict 1675-1694-settings-homebrew-abspath-conflict 1769-freshness-gate-resume
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
      # Issue #1899: bridge-start.sh's codex launch branch now routes a dynamic
      # vanilla Codex agent's comms hooks to PROJECT-LOCAL <workdir>/.codex/
      # hooks.json (never the operator ~/.codex/hooks.json) with trust detect +
      # report. Pull 1899 on every bridge-start.sh move so the hook-target +
      # trust-report contract can't silently regress.
      if [[ "$path" == "bridge-start.sh" ]]; then
        add_required 1899-dynamic-vanilla-codex
        # Issue #1923: bridge-start.sh's Claude hook-ensure block now calls
        # bridge_ensure_claude_askuserquestion_ban for EVERY Claude agent
        # (next to tool-policy / prompt-guard), so a dynamic-vanilla agent's
        # blocking AskUserQuestion picker is denied at start. Pull
        # 1923-askuserquestion-hard-ban on every bridge-start.sh move so a
        # refactor cannot drop the ensure call (it is the only AskUserQuestion
        # surface a vanilla agent gets).
        add_required 1923-askuserquestion-hard-ban
      fi
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

    hooks/tool-policy.py|hooks/askuserquestion_escalate.py|bridge-config.py|lib/system_config_paths.py)
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
      # Issue #1367 (sealed-paste): hooks/tool-policy.py hosts the
      # token-FREE `receive --request` exemption + the
      # `tool_policy_credential_routine_sealed_paste` audit row + the
      # token-accepting-receive deny. Pull the sealed-paste smoke whenever
      # tool-policy.py moves so the tight exemption + the
      # no-token-in-deny-audit contract stay pinned.
      # Issue #1569 (bounded AskUserQuestion): hooks/tool-policy.py hosts the
      # AskUserQuestion PreToolUse intercept (handle_askuserquestion) that
      # short-circuits the unbounded interactive picker into a channel
      # escalation + autonomous fallback via hooks/askuserquestion_escalate.py.
      # Pull the regression smoke whenever tool-policy.py moves so the no-hang
      # bound, the two fallback branches (proceed+note / block+escalate), the
      # answered branch, and the guard-not-weakened invariant (every other tool
      # byte-identical) stay pinned.
      # Issue #1690 (v0.16.4 guard): hooks/tool-policy.py hosts the two
      # state/tasks.db protected-path branches that now honor read_intent
      # (a read of the DB file does not mutate the queue). Pull the
      # KEEP-invariant carve-out smoke whenever tool-policy.py moves so a
      # future PR cannot regress the read-allow OR weaken the teeth: writes
      # / output redirection / file sinks / sqlite3 (mutate AND -readonly
      # SELECT, left denied) / unparseable commands must stay DENIED.
      # Issue #1692 (admin Bash carve-out parity): hooks/tool-policy.py's
      # protected_alias_reason now exempts admin read-intent Bash reads of
      # peer-home / shared paths (mirroring the non-Bash admin exemption),
      # while keeping admin writes + non-admin reads denied and preserving
      # the independent system-class read carve-out. Pull the KEEP-invariant
      # smoke whenever tool-policy.py moves so a future PR cannot regress the
      # role-branch (admin via is_admin_agent, not class==system) or leak the
      # carve-out to writes / non-admin agents / expansion-spelled paths.
      # Issue #1693 (read-only viewers + shlex-fail short-needle): hooks/
      # tool-policy.py's _READ_INTENT_BASH_COMMANDS gains stdout-only viewers
      # (strings/hexdump/comm/fold/expand/paste/csvlook) and the shlex-failure
      # substring fallback narrows the SHORT-needle (hooks/, state/cron/)
      # prefix set to drop prose punctuation. Pull the KEEP-invariant smoke
      # whenever tool-policy.py moves so a future PR cannot regress the viewer
      # read-allow OR weaken the teeth (viewer redirect-to-sink stays denied,
      # bat/batcat stay denied, real redirect/assignment short-needle stays
      # denied, non-admin peer-home read stays denied).
      # Issue #1734 (v0.16.6 Lane C): hooks/tool-policy.py hosts the
      # `config set-env` exact-shape, admin-only, anti-spoof Bash gate
      # (_config_set_env_check) + the updated #341 roster deny message;
      # bridge-config.py hosts the `set-env` wrapper (key allowlist / deny
      # / per-key typing / shell-safe atomic write / before-after-hash audit);
      # lib/system_config_paths.py adds agent-env.local.sh to PROTECTED_GLOBS.
      # Pull the security smoke whenever any of these move so a future PR
      # cannot regress the deny-FIRST envelope (env-assignment spoof, forbidden
      # key, shell-embed, non-admin) or the #341 direct-Edit/Write block.
      # Issue #1709 (v0.16.6 Lane D, HIGH confidentiality): hooks/tool-policy.py's
      # Stage-A shared-forbidden gate (_shared_forbidden_aliases) + Stage-B
      # peer-home gate (_peer_alias_list) gain a prefix-spelling-agnostic
      # forbidden-SUFFIX matcher (_forbidden_suffix_in_command) that closes the
      # brace `${HOME}` / `$BRIDGE_HOME` / `${BRIDGE_HOME}` / ANSI-C-hex bypass a
      # non-admin used to read team shared/secrets|private + peer homes. Pull the
      # KEEP-invariant smoke whenever tool-policy.py moves so a future PR cannot
      # regress the every-spelling DENY (both stages), the obfuscation fail-close,
      # or the no-over-block on own-home / public-wiki / repo-glob reads.
      # Issue #1786: the queue-DB tool-policy gate is WHY the upgrade-complete
      # checklist routes the admin agent through `agent-bridge doctor
      # --detectors tasks-db` instead of the raw `verify-tasks-db` command.
      # The 1786 smoke probes the real PreToolUse hook (blessed verb ALLOWED,
      # raw db-path command DENIED) — pull it whenever tool-policy.py moves so
      # a change to the queue-DB gate cannot silently invalidate the verb
      # routing the template now depends on.
      # Issue #1806 (+ #1711): hooks/tool-policy.py hosts the strict trusted-
      # admin predicate (`is_trusted_admin_agent_for_guard`) and the four
      # admin allow+audit carve-outs (peer-home WRITE, tilde/glob read
      # downgrade, sqlite3 task-db, sed -n read) plus the non-Bash #1711
      # shared/secrets Read deny. Pull the 1806 KEEP-invariant smoke whenever
      # tool-policy.py moves so a future PR cannot regress the anti-spoof
      # predicate, the resolved-path containment, or the forbidden-tree denies
      # that stay in force even for admin.
      # Issue #1738 (SECURITY): bridge-config.py's `config set`/`set-env` write
      # gate now resolves the caller from a controller pane-pid binding +
      # process ancestry (resolve_config_caller), NOT env identity; tool-policy.py
      # adds the interim eval/bash -c/sh -c/$var indirection deny. Pull the
      # adversarial matrix smoke whenever tool-policy.py or bridge-config.py moves
      # so a future PR cannot regress the env-spoof DENY (both verbs) or the
      # legit admin-binding / operator-TTY ALLOW.
      add_required hooks agent-update v2-cross-class-read admin-hook-exemption tool-policy-roster-read-classify 1205-hook-iso-fail-open 6607-hook-admin-allowlist K-beta4-nits 1358-admin-credential-routine-exempt 1367-auth-sealed-paste 1442-config-protected-globs-v2 1569-askuserquestion-bound 1690-tasksdb-read-carveout 1692-admin-bash-symmetry 1709-shared-secret-suffix-guard 1693-read-viewers v0166-lc-config-set-env 1786-tasksdb-doctor-verb 1806-admin-guard-allow-audit 1823-v2-peer-home-containment 1738-config-caller-binding
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
      add_required isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering 1495-settings-invalid-hook-key isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip isolation-v2-marker-only-migrate isolation-v2-macos-noise-suppression isolation-v2-platform-discriminator isolation-v2-bucket2-gates layout-resolver-marker-over-env 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions 1021-isolation-v2-shared-plugin-perms 1025-isolated-create-agent-env-install 1077-migrate-iso-v2-data-dir 1113-watchdog-legacy-backfill 1158-marker-controller-uid-exemption 1158-marker-load-order 1161-marker-readable-by-isolated 1165-track-b-sudo-escalate-and-state 1342-write-state-marker-matrix launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup phase2-install-tree-reconciler phase3-agent-home-contract 1207-stale-supp-groups-allowlist A-beta4-iso-path-resolution H-beta4-iso-ownership G-beta4-watchdog-noise J-beta4-workflow-docs α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-theta-upgrade-backfill-perms 1506-isolate-normalize 1520c-create-isolate-profile-publish 1533-create-isolate-content-publish 1766-iso-settings-readable 1513-iso-teams-prune-eacces 1836-iso-first-start-queue-dir-ownership 1891-iso-create-path-completeness 1899-dynamic-vanilla-codex-v2-secret-env-repin
      # Issue #1891: lib/bridge-isolation-v2.sh hosts
      # bridge_isolation_v2_normalize_memory_tree (iso-owned memory/ tree
      # repair, incl. an existing stale 2700 subtree, keeping index.sqlite
      # controller-owned 0600) + bridge_isolation_v2_verify_agent_metadata
      # (the hard agent-meta.env presence/mode check). Both the create path
      # and reapply call them. Pull 1891-iso-create-path-completeness on
      # every isolation-lib move so a refactor cannot drop the F1/F3a
      # create-path completeness contract.
      # Issue #1829: lib/bridge-isolation-v2.sh hosts
      # bridge_isolation_v2_repair_queue_dirs (idempotent requests/responses
      # ownership repair). Pull 1836-iso-first-start-queue-dir-ownership on
      # every isolation-lib move so the queue-dir self-heal contract stays
      # covered.
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
      add_required isolation isolated-bin-agb isolated-skills-sync isolated-settings-rendering 1495-settings-invalid-hook-key isolated-cli-policy v2-cross-class-read isolation-v2-migrate-lock-portability isolation-v2-migrate-macos-skip isolation-v2-marker-only-migrate isolation-v2-macos-noise-suppression isolation-v2-platform-discriminator isolation-v2-bucket2-gates layout-resolver-marker-over-env 857-pr1-isolation-write-helper 857-pr6-isolation-v3-channel-dotenv-migrate 864-upgrade-perm-regressions 1021-isolation-v2-shared-plugin-perms 1025-isolated-create-agent-env-install 1077-migrate-iso-v2-data-dir 1113-watchdog-legacy-backfill 1158-marker-controller-uid-exemption 1158-marker-load-order 1161-marker-readable-by-isolated 1165-track-b-sudo-escalate-and-state 1342-write-state-marker-matrix launch isolated-agent-delete-reap 1121-agent-delete-os-purge 1140-purge-home-os-cleanup phase2-install-tree-reconciler phase3-agent-home-contract 1207-stale-supp-groups-allowlist A-beta4-iso-path-resolution H-beta4-iso-ownership G-beta4-watchdog-noise J-beta4-workflow-docs α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-theta-upgrade-backfill-perms beta5-2-mu-cron-channel-creds 1359-cron-create-iso-staging isolation-v2-shared-mover 1506-isolate-normalize 1520c-create-isolate-profile-publish 1533-create-isolate-content-publish 1766-iso-settings-readable 1513-iso-teams-prune-eacces 1891-iso-create-path-completeness
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
      # Issue #1762: this arm's `runtime-templates/*` glob also matches the
      # shipped picker catalog + the picker-resolve skill (case takes the first
      # matching arm, ahead of the dedicated picker arm below). Pull the picker
      # smoke when one of those data files moves so a catalog schema change is
      # exercised.
      case "$path" in
        runtime-templates/shared/picker-catalog.json|runtime-templates/skills/picker-resolve/SKILL.md)
          add_required 1762-picker-autoresolve
          # Issue #1766: the catalog grew the claude-settings-error entry; the
          # #1766 smoke asserts it parses + matches a Settings Error capture.
          add_required 1766-iso-settings-readable
          # Issue #1783: the catalog grew the claude-idle-ready / codex-idle-ready
          # non_picker entries; the idle-nonpicker smoke asserts they classify
          # the idle composers (and a real picker is NOT shadowed by them).
          add_required 1783-picker-idle-nonpicker
          ;;
      esac
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
      # Issue #1894: bridge-memory.py gained the read-only `scan-transcripts`
      # subcommand + the harvest-daily `--transcripts-json` ingestion arg that
      # the memory-daily harvest stub uses to run the iso agent's transcript
      # scan as the iso UID and marshal it back to the controller. Re-run the
      # run-as-iso + marshal-back contract smoke whenever this file moves.
      add_required 1894-iso-transcript-harvest-run-as-iso
      add_integration integration-minimal
      ;;

    scripts/wiki-v2-rebuild.sh)
      # Issue #1827 (read-side sibling of #1222): the controller-run
      # wiki/index rebuild now branches on linux-user isolation. For an
      # iso agent the whole rebuild/publish block (mkdir memory/, lock,
      # rm stale tmp_db, rebuild-index, validate, mv-into-place) runs as
      # the iso UID via bridge_isolation_run_as_agent_user_via_bash —
      # the controller can't write the 2770 iso-owned memory/ dir, so
      # the legacy controller-direct path tallied every iso agent as a
      # fail/skip on every run. The 1827 smoke pins:
      #   - ../bridge-lib.sh sourcing (so the iso helpers load)
      #   - bridge_load_roster after that source + inside the
      #     _BRIDGE_ISO_HELPERS_LOADED guard (without it the predicate is
      #     always-false dead code — the #1222 r1 BLOCKING regression)
      #   - bridge_agent_linux_user_isolation_effective gate
      #   - bridge_isolation_run_as_agent_user_via_bash invocation
      #   - the iso inline script covers the FULL block (mkdir + lock +
      #     rm + rebuild-index + validate + mv); wrapping only mkdir or
      #     only mv would re-trip the Permission denied bug
      #   - non-iso branch preserved (no regression for shared installs)
      #   - inline-script exit codes stay 0 or >= 10 so the wrapper's +2
      #     shift on rc<3 cannot collide with its pre-flight band
      #   - no heredoc/here-string in the iso inline body (footgun #11)
      # The Linux+sudo gated T9 layer stands up a real
      # agent-bridge-w1827 user + ab-agent-w1827 group, scaffolds the
      # iso-owned memory/ at mode 2770 with a stale index.sqlite.rebuilding
      # file, and asserts the cross-boundary asymmetry (controller rm
      # fails, sudo-as-iso rm succeeds) reproduces on this host.
      add_required 1827-wiki-v2-rebuild-iso H-bootstrap-memory-iso-rebuild
      add_integration integration-minimal
      ;;

    scripts/wiki-monthly-summarize.sh|scripts/wiki-weekly-summarize.sh)
      # Issue #1849 (sibling of #1827 / #1222): the controller-run
      # wiki monthly/weekly summarize crons run `bridge-memory.py
      # summarize {monthly,weekly}`, which reads/writes the iso-owned
      # 2770 memory/ dir. The controller is not in ab-agent-<slug>, so
      # the legacy controller-direct path tallied every iso agent as a
      # fail on every run. Both scripts now branch on linux-user
      # isolation and run the summarize as the iso UID via
      # bridge_isolation_run_as_agent_user_via_bash. The 1849 smoke pins,
      # for BOTH scripts:
      #   - ../bridge-lib.sh sourcing (so the iso helpers load)
      #   - bridge_load_roster after that source + inside the
      #     _BRIDGE_ISO_HELPERS_LOADED guard (without it the predicate is
      #     always-false dead code — the #1222 r1 BLOCKING regression)
      #   - bridge_agent_linux_user_isolation_effective gate
      #   - bridge_isolation_run_as_agent_user_via_bash invocation
      #   - the iso inline body runs `bridge-memory.py summarize <period>`
      #   - non-iso branch preserved (legacy run_with_timeout summarize
      #     path survives — no regression for shared installs)
      #   - inline-script exit codes stay 0 or >= 10 so the wrapper's +2
      #     shift on rc<3 cannot collide with its pre-flight band
      #   - no heredoc/here-string in the iso inline body (footgun #11)
      # The Linux+sudo gated T8 layer stands up a real agent-bridge-w1849
      # user + ab-agent-w1849 group, scaffolds the iso-owned memory/ at
      # mode 2770, and asserts the cross-boundary asymmetry (controller
      # write fails, sudo-as-iso write succeeds) reproduces on this host.
      add_required 1849-wiki-summarize-iso
      add_integration integration-minimal
      ;;

    scripts/memory-daily-harvest.sh)
      # Issue #1894 (read-lens sibling of #1849 / #1827 / #1222): the
      # controller-run memory-daily harvester needs r-X into each iso agent's
      # transcript tree <iso-home>/.claude/projects to scan sessions. The
      # promised prepare-isolation ACL is absent in the field (.claude is
      # group-setgid 3770 but Claude creates projects/ at mode 2700 under the
      # iso UID's umask 077), so the old controller-read `[[ -r && -x ]]` branch
      # always failed and every iso agent fell to --skipped-permission. The stub
      # now runs ONLY the bounded transcript scan as the iso UID via
      # bridge_isolation_run_as_agent_user_via_bash (run-as-iso narrow helper)
      # and marshals the JSON list back to the controller-UID harvest via
      # --transcripts-json; all queue-DB / aggregate writes stay controller-side
      # (Design A, #786) and the prepare-isolation path is untouched. The 1894
      # smoke pins:
      #   - $BRIDGE_HOME/bridge-lib.sh sourcing (so the iso helpers load)
      #   - bridge_load_roster after that source + inside the
      #     _BRIDGE_ISO_HELPERS_LOADED guard (#1222 r1 dead-code regression)
      #   - bridge_isolation_can_sudo_to_agent probe + run-as helper invocation
      #   - the iso inline body runs `bridge-memory.py scan-transcripts`
      #   - scan-success feeds harvest --transcripts-json; --skipped-permission
      #     fallback preserved (no regression when sudo is unavailable)
      #   - the stub does NOT chmod/setfacl .claude/projects (the forbidden
      #     broad relaxation that would regress #1891 / #1506 / #1533)
      #   - no heredoc/here-string in the iso inline body (footgun #11)
      #   - behavioral repro: probe-success → queue-backfill (transcript seen),
      #     probe-fail → status=skipped
      add_required 1894-iso-transcript-harvest-run-as-iso
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
      #
      # Issue #1613 part (a): bootstrap-memory-system.sh's first-run task
      # body now spells the wiki-bootstrap report step correctly
      # (--full-rebuild builds the DB only; a separate `--report --out`
      # writes today's distribution-report-<date>.md). Pull
      # 1613-wiki-mention-fence-indent so the paired scanner regression
      # rides along whenever the bootstrap entry moves.
      add_required H-bootstrap-memory-iso-rebuild J-beta4-workflow-docs 1359-cron-create-iso-staging 1399-bootstrap-memory-no-admin 1613-wiki-mention-fence-indent
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
      # Issue #1672: bridge-hooks.py's `cmd_link_shared_settings` now catches
      # FileExistsError from `symlink_to` and re-checks idempotently — a link
      # already resolving to the intended shared-settings target is a no-op
      # (no spurious warning every iso-agent restart); a wrong-target / non-
      # symlink collision still surfaces the warning. The trailing diagnostic
      # readlink is now iso-safe too. 1672-link-shared-settings-idempotent pins
      # the correct-target (no error/no warning) + wrong-target (warning
      # preserved) cases; pull it on every bridge-hooks.py move.
      # Issue #1890: dynamic Claude agents now write their bridge comms hooks to
      # `<workdir>/.claude/settings.local.json` (not settings.json) via
      # bridge-hooks.sh's bridge_claude_local_hook_target_args /
      # bridge_claude_dynamic_local_settings_target /
      # bridge_claude_prepare_dynamic_local_settings, and hooks/prompt-guard.py
      # no-ops without BRIDGE_AGENT_ID. 1890-dynamic-vanilla-claude pins the
      # local-settings redirect (operator-key preserve + .git/info/exclude +
      # loud-fail-on-tracked), the prompt-guard no-op, and that STATIC Claude
      # still writes settings.json. Pull on every hooks/* + bridge-hooks.sh move.
      # Issue #1934: bridge-hooks.py grew `_stable_hooks_dir` + the canonical/
      # fenced hook-path render (facet 1), so a temp BRIDGE_HOME render can no
      # longer leak /tmp hook paths into live settings / _template / Codex
      # .codex/hooks.json. 1934-hook-path-canonical-fence pins it; the
      # 1934-hook-file-self-heal smoke (daemon facet 2) rides along since the
      # renderer + the daemon re-render share the same builders.
      add_required hooks upgrade-shared-settings-propagate managed-autocompact-window isolated-settings-rendering 1495-settings-invalid-hook-key 1453-channel-sticky-false-inbound per-agent-settings-rendering shared-settings-preserve-user-keys 1689-statusline-preserve-rerender 1756-settings-preserve-model-user-keys 11901-shared-global-settings-inherit 1759-selfref-global-loop-guard admin-hook-exemption 1067-codex-provisioning 1120-controller-ops-isolated 1139-link-shared-settings-perm 1672-link-shared-settings-idempotent 1145-ensure-dir-actually-sudo 1145-option1-deferral-guard 1151-step-a-helper 1165-track-c-hooks-and-dispatcher 1175-exhaustive-pathlib-audit 1178-helper-contract-daemon-supp 1205-hook-iso-fail-open 1212-bridge-hooks-marketplace 1213-iso-uid-predicate 1934-hook-path-canonical-fence 1934-hook-file-self-heal beta27-D-inject-timestamp-resolved beta27-E-hook-permission-fail-open-markers 1358-admin-credential-routine-exempt 1199-action-required-claimed-skip codex-precompact-hook codex-postcompact-hook codex-subagent-hooks codex-permission-request-hook 1890-dynamic-vanilla-claude 1899-dynamic-vanilla-codex
      # Issue #1497 (P1): hooks/bridge_hook_common.py::agent_default_home now
      # reads BRIDGE_AGENT_HOME_RESOLVED first, is v2-aware, falls back to the
      # roster CLI (`agent show --json agent_home`), and no longer lets a stale
      # legacy `agents/<a>` dir short-circuit ahead of v2. The shared
      # _resolved_env_path / _resolve_home_via_roster helpers keep the home and
      # workdir channels from drifting. Pull 1497-p1-home-resolver on every
      # hooks/* move so the RESOLVED-first order, the split-brain immunity, and
      # the bash↔Python home parity cannot silently regress.
      # #9780: hooks/bridge_hook_common.py grew the Stop inbox-drain shared
      # guard (compute_drain_decision + the marker load/save/key helpers),
      # hooks/inbox-auto-drain.py is the new Claude Stop step, hooks/check_inbox.py
      # routes `--format codex` through the same shared guard, and bridge-hooks.py
      # wires inbox-auto-drain.py into the Claude Stop chain AFTER surface-reply-
      # enforce / BEFORE session-stop (+ the reorder normaliser). Pull
      # 9780-stop-inbox-drain on every hooks/* / bridge-hooks.py move so a future
      # patch cannot regress the loop guard (fail-open, atomic-persist-before-
      # block, never-block-when-empty), the #1199 queued-vs-claimed split, or the
      # Stop-chain ordering.
      add_required 9780-stop-inbox-drain
      # Issue #1766: bridge_link_claude_settings_to_shared (lib/bridge-hooks.sh)
      # now group-publishes the per-agent effective file (0640) + parent .claude/
      # (0750) for iso v2 agents so the iso UID can read its own
      # workdir/.claude/settings.json target. Pull 1766-iso-settings-readable on
      # every hooks/* / bridge-hooks.* / bridge-hooks.sh move so the publish +
      # the walker accept/refuse contract + the picker catalog entry cannot
      # silently regress.
      add_required 1766-iso-settings-readable
      # Issue #1596: hooks/bridge_hook_common.py::drain_top_actionable now filters
      # daemon-owned `[cron-dispatch]` / `created_by=cron:` rows (with the
      # `[cron-followup]` carve-out) out of BOTH the queued and claimed paths via
      # _is_daemon_owned_cron_dispatch + the find-open --all iterate/filter, and
      # re-confirms the SELECTED row still open (_row_still_open) before the
      # block — so a daemon cron-dispatch row no longer wakes the model
      # (check-inbox.py codex + inbox-auto-drain.py claude inherit the one shared
      # predicate). Pull 1596-stop-drain-cron-dispatch on every hooks/* /
      # bridge-hooks.py move so a future patch cannot re-broaden the predicate to
      # block on daemon-owned work, drop the followup carve-out, single-shot the
      # head (a real task behind a cron row), or skip the late fail-open re-check.
      add_required 1596-stop-drain-cron-dispatch
      add_required 1497-p1-home-resolver
      add_required 1497-v2-dynamic-handoff
      # Issue #9981 (read side): hooks/bridge_hook_common.py is the CONSUMER of
      # the pending-attention spool — it reads state/agents/<a>/
      # pending-attention.env (the controller-owned state leaf) to surface the
      # queued-event count at prompt time, running as the ISO AGENT UID. The
      # read-side smoke pins (a) the reader/writer path agreement and (b) the
      # group-read publish that lets the agent UID actually open the marker.
      # Pull it on every hooks/* move so a reader-path drift back to the iso
      # data tree (or a regressed group-read assumption) fails loud.
      add_required 9981-iso-pending-attention-readable
      # Issue #1497 (P2): hooks/bridge_hook_common.py::bridge_home_dir() now
      # delegates to the operator-home SSOT and the module self-sets-up lib/ on
      # sys.path. Pull 1497-p2-operator-home on every hooks/* move so the
      # every-session operator-home resolution + import seam cannot regress.
      add_required 1497-p2-operator-home
      # Issue #1755: hooks/bridge_hook_common.py::save_timestamp_state now uses a
      # unique per-instance tmp + benign last-writer-wins on the final rename
      # (P1 race), and lib/bridge-hooks.sh + bridge-hooks.py unify every hook
      # ensure on bridge_hook_pinned_python_bin so divergent global/workdir
      # interpreter spellings converge (P2 dedup). Pull the dedicated smoke on
      # every hooks/* / bridge-hooks.py / lib/bridge-hooks.sh move so the
      # every-prompt concurrent-write contract, the preserved #1205 Family-B
      # controller re-raise, and the cross-scope command convergence cannot
      # regress back into the visible "UserPromptSubmit hook error" banner.
      add_required 1755-prompt-timestamp-concurrent-write
      # Issue #1923: bridge-hooks.py gained the AskUserQuestion hard-ban
      # surface — askuserquestion_ban_hook_command / is_askuserquestion_ban_hook
      # / cmd_ensure_askuserquestion_ban + the ensure_scoped_permission_deny
      # post-merge invariant call in BOTH render commands — and
      # lib/bridge-hooks.sh gained bridge_ensure_claude_askuserquestion_ban with
      # the shared/local routing. Pull 1923-askuserquestion-hard-ban on every
      # hooks/* / bridge-hooks.py / lib/bridge-hooks.sh move so a future patch
      # cannot regress the dedicated PreToolUse deny hook (the guaranteed
      # bypassPermissions mechanism), the vanilla settings.local.json routing,
      # the fail-loud-on-operator-data writer, or the scoped-deny final-render
      # invariant.
      add_required 1923-askuserquestion-hard-ban
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

    bridge-upgrade.sh|bridge-upgrade.py|lib/bridge-lock.sh|scripts/export-public-snapshot.sh|VERSION|LTS_SERIES)
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
      # Issue #10370: migrate-agents now emits rematerialize planning/apply
      # rows for stale workdir identity copies. Pull the focused smoke on
      # every upgrade entry move so backup planning, dry-run, shared-cwd
      # protection, and iso writer routing stay pinned.
      # Issue #1612: bridge-upgrade.sh's RESTART_DAEMON block now also cycles
      # the A2A handoff receiver via `bridge-handoff-daemon.sh restart` —
      # restart-if-running only, never under --dry-run, quiet no-op on a
      # missing/non-running receiver, and only through the standard restart
      # path so the fail-closed bind proof is re-established. Pull
      # 1612-upgrade-restart-receiver on every upgrade-entry move so the
      # running/stopped/dry-run/missing/failure matrix stays pinned and a
      # future PR cannot regress it to the main-daemon-only restart.
      # Issue #1611: migrate-agents now roster-restricts its loop (orphan /
      # non-roster dirs are skipped; safe fallback migrates all when the
      # roster is unknown; --migrate-all-agents force-includes orphans).
      # Pull 1611-migrate-orphan-skip on every upgrade-entry move so the
      # roster filter, the skipped_orphans payload, and the fallback cannot
      # silently regress.
      # Issue #1613 part (a): bridge-upgrade.sh's [upgrade-complete] task
      # body now spells the wiki-bootstrap report step correctly
      # (--full-rebuild builds the DB only; a separate `--report --out`
      # writes today's distribution-report-<date>.md). Pull
      # 1613-wiki-mention-fence-indent on every upgrade-entry move so the
      # paired scanner regression rides along with the template surface.
      # Issue #1635: build_backup_entries / backup-live now GRACEFUL-SKIP
      # iso-owned profile files the controller cannot stat (PermissionError /
      # EACCES) instead of aborting the whole upgrade; the skipped entries are
      # surfaced in the backup JSON + a [bridge-upgrade] stderr warning. Pull
      # 1635-iso-backup-perm-skip on every upgrade-entry move so the
      # graceful-skip, the skipped_isolated payload, and the readable-file
      # control cannot silently regress.
      # Issue #1636: rematerialize-agent-identity.sh now also propagates the
      # non-identity _template scaffolding (.claude/commands, raw/captures,
      # session-type-files, codex/ except AGENTS.md) to the agent workdir,
      # add-missing-only (skip-existing, never clobber a customized file) and
      # surfaces a scaffold_paths/scaffold_added payload that build_backup_entries
      # consumes. Pull 1636-rematerialize-scaffolding on every upgrade-entry move
      # so the skip-existing policy, idempotency, codex/AGENTS.md exclusion, and
      # the iso PermissionError graceful-skip cannot silently regress.
      # Issue #1660: bridge-upgrade.py routes every cmd_* JSON emit through the
      # BrokenPipe-safe emit_json helper (flush-in-try, devnull-on-except,
      # intended-rc preserved). Issue #1661: bridge-upgrade.sh acquires a
      # state/locks/upgrade.lock singleton (shared lib/bridge-lock.sh) for
      # mutating flows only, released via the existing exit handler. Pull both
      # regression smokes on every upgrade-entry (or lib/bridge-lock.sh) move.
      # Issue #1662: bridge-upgrade.sh writes a DURABLE success marker
      # (state/upgrade/upgrade-complete.json, phase=work-complete) AFTER all
      # apply/migrate/reclassify work and BEFORE the restart phase, and emits a
      # notice that a self-restart SIGKILL (exit 137 on sudo-self systemd) is
      # EXPECTED-success; the marker is promoted to phase=restart-complete after
      # every restart step survives, and surfaced as the upgrade_complete_marker
      # --json field. Pull 1662-upgrade-complete-marker on every upgrade-entry
      # move so the marker-before-restart ordering, the phase distinction, the
      # notice text, and the --json wiring cannot silently regress.
      # Issue #1670: rematerialize_agent_identity() now pins the dry-run identity
      # boundary — the helper payload's agent must be nonempty AND equal the
      # asked-for agent, else it is converted to a structured rematerialize error
      # keyed on result.agent (the helper's Bash 3.2 -> 4+ re-exec used to drop
      # the mandatory args and re-run with a blank agent -> agent="" + usage for
      # every agent in the dry-run preview). Pull 1670-rematerialize-dryrun-agent-preserved
      # on every upgrade-entry move so the Python guard cannot silently regress.
      # v0.16.3 Lane F: bridge-upgrade.sh gained the `lts` upgrade channel —
      # bridge_upgrade_latest_lts_tag (highest stable tag within the root
      # LTS_SERIES major.minor, fail-closed on missing/malformed series),
      # sticky per-install persistence via state/upgrade/channel
      # (bridge_upgrade_read/write_sticky_channel, fail-closed on an invalid
      # recorded value), the bare-invocation precedence block (explicit CLI >
      # special cases > sticky > legacy stable), and `lts` in the #1516
      # downgrade guard. Pull lts-channel-sticky-resolver on every
      # upgrade-entry (or LTS_SERIES) move so the resolver, the fail-closed
      # paths, the default-unchanged behavior, the sticky read/write gate, and
      # the downgrade-guard participation stay pinned.
      # Issue #1781 (DATA-LOSS): the upgrade-time HOME->workdir identity sync
      # (rematerialize) must NOT overwrite agent-written MEMORY.md /
      # users/<id>/MEMORY.md with the stale home copy, and the preserved
      # workdir copies must stay in the targeted backup set. Pull the focused
      # smoke on every upgrade-entry move so the state-vs-doc split, the
      # preserved_paths plumbing, and the backup-set coverage stay pinned.
      add_required upgrade upgrade-source-preservation upgrade-shared-settings-propagate admin-pair-server-auto-provision telegram-relay-residue-cleanup upgrade-conflicts-lifecycle managed-autocompact-window per-agent-settings-rendering upgrade-isolated-agent-migrate 864-upgrade-perm-regressions cleanup-payload-empty-stdin-872 isolation-v2-marker-only-migrate 1067-codex-provisioning 1113-watchdog-legacy-backfill 1144-upgrade-complete-task phase2-install-tree-reconciler phase3-agent-home-contract α-beta5-upgrade-backfill-normalize gamma-beta5-reconcile-helper-status beta5-2-theta-upgrade-backfill-perms beta5-2-mu-cron-channel-creds codex-version-surface codex-doctor 1516-upgrade-downgrade-guard 1612-upgrade-restart-receiver upgrade-migrate-rematerialize-workdir 1602-dryrun-ref-fidelity 1601-conflicts-adopt-guard 1611-migrate-orphan-skip 1613-wiki-mention-fence-indent 1635-iso-backup-perm-skip 1638-settings-cosmetic-conflict 1636-rematerialize-scaffolding 1660-upgrade-emit-brokenpipe 1661-upgrade-singleton-lock 1662-upgrade-complete-marker 1670-rematerialize-dryrun-agent-preserved 1781-doc-migration-memory-preserve 1817-live-root-claude-stub lts-channel-sticky-resolver 1567-codex-orphan-upgrade-reaper 1675-1694-settings-homebrew-abspath-conflict 1786-tasksdb-doctor-verb 1809-agents-md-backfill 1892-doc-backfill-engine-fail-closed 1905-upgrade-systemd-quiesce-respawn 655-upgrade-launchd-quiesce-respawn 1855-keychain-free-backfill 1813-canon-links-resolve-v2
      # Issue #1906: bridge-upgrade.py's backfill-codex-entrypoints sweep gained
      # the REPORT-ONLY engine-mismatched-doc detector (a stale Codex-contract
      # AGENTS.md on a non-codex agent -> engine_mismatch_docs + non_clean).
      # Pull the #1906 smoke on every bridge-upgrade.py move so a refactor of the
      # backfill loop cannot silently drop the residue flag or start mutating the
      # flagged file.
      add_required 1906-flag-engine-mismatched-docs
      # Issue #1923: bridge-upgrade.sh's Claude hook-propagation loop now also
      # calls bridge_ensure_claude_askuserquestion_ban so existing agents
      # (incl. pre-#1923 dynamic-vanilla agents whose settings.local.json had
      # no AskUserQuestion deny) backfill the ban on `upgrade --apply`. Pull
      # 1923-askuserquestion-hard-ban on every bridge-upgrade.sh move so the
      # backfill call cannot silently regress.
      if [[ "$path" == "bridge-upgrade.sh" ]]; then
        add_required 1923-askuserquestion-hard-ban
      fi
      add_integration integration-minimal
      ;;

    lib/upgrade-helpers/rematerialize-agent-identity.sh|scripts/smoke/upgrade-migrate-rematerialize-workdir.sh|scripts/smoke/1636-rematerialize-scaffolding.sh|scripts/smoke/1670-rematerialize-dryrun-agent-preserved.sh|scripts/smoke/1781-doc-migration-memory-preserve.sh|scripts/smoke/1809-agents-md-backfill.sh)
      # Issue #1809: the rematerialize helper gained the entrypoint-backfill-only
      # mode (the daemon doc-backfill mirror) + the codex AGENTS.md is one of the
      # entrypoint docs; pull the #1809 smoke whenever the helper or its smoke
      # changes so the entrypoint-only short-circuit + shared-workspace guard are
      # re-exercised alongside the full identity/scaffold suite.
      add_required upgrade-migrate-rematerialize-workdir 1636-rematerialize-scaffolding 1670-rematerialize-dryrun-agent-preserved 1781-doc-migration-memory-preserve 1809-agents-md-backfill
      add_integration integration-minimal
      ;;

    scripts/smoke/1611-migrate-orphan-skip.sh|scripts/smoke/1611-migrate-orphan-skip-helper.py)
      # Issue #1611: editing the migrate-orphan-skip smoke or its JSON
      # probe re-runs the smoke directly (the scripts/smoke/* catch-all
      # already pulls it via the full static suite; this arm keeps the
      # selection focused when only these two files change).
      add_required 1611-migrate-orphan-skip
      ;;

    lib/upgrade-helpers/codex-orphan-cleanup.sh|lib/upgrade-helpers/codex-orphan-cleanup.py|lib/upgrade-helpers/codex-orphan-cleanup-summary.py|scripts/smoke/1567-codex-orphan-upgrade-reaper.sh|scripts/smoke/1567-codex-orphan-upgrade-reaper-helper.py)
      # Issue #1567: the one-shot upgrade-time codex broker + queue-gateway
      # orphan reaper. Editing the helper shim, its Python detector/summary, or
      # the smoke/helper re-runs the focused smoke (the scripts/smoke/* catch-all
      # pulls it via the full static suite; this arm keeps the selection focused
      # when only these files change). The bridge-upgrade.sh arm above also
      # selects it on every upgrade-entry move.
      add_required 1567-codex-orphan-upgrade-reaper
      ;;

    scripts/smoke/1635-iso-backup-perm-skip.sh|scripts/smoke/1635-iso-backup-perm-skip-helper.py)
      # Issue #1635: editing the iso-backup-perm-skip smoke or its JSON probe
      # re-runs the smoke directly (the scripts/smoke/* catch-all already pulls
      # it via the full static suite; this arm keeps the selection focused when
      # only these two files change). The graceful-skip behavior itself lives in
      # bridge-upgrade.py, so the bridge-upgrade.py arm above also selects this
      # smoke on a backup-scan change.
      add_required 1635-iso-backup-perm-skip
      ;;

    scripts/smoke/1663-plugin-cache-sidecar-skip.sh)
      # Issue #1663: editing the dev-plugin-cache sidecar-skip smoke re-runs it
      # directly (the scripts/smoke/* catch-all already pulls it via the full
      # static suite; this arm keeps the selection focused when only this file
      # changes). The sidecar-skip / per-entry-guard / required-contract
      # behavior itself lives in bridge-dev-plugin-cache.py, so the
      # bridge-dev-plugin-cache.py arm above also selects this smoke on an
      # overlay change.
      add_required 1663-plugin-cache-sidecar-skip
      ;;

    scripts/smoke/1623-a2a-backpressure-failopen.sh)
      # Issue #1623: editing the backpressure fail-open smoke re-runs it directly
      # (the scripts/smoke/* catch-all already pulls it via the full static suite;
      # this arm keeps the selection focused when only this file changes). The
      # backpressure fail-open behavior itself lives in bridge-handoffd.py, so the
      # bridge-handoffd.py arm above also selects this smoke on a receiver change.
      add_required 1623-a2a-backpressure-failopen
      ;;

    scripts/smoke/1629-healthz-not-semaphore-gated.sh|scripts/smoke/1629-healthz-not-semaphore-gated-helper.py)
      # Issue #1629 (audit R2, HIGH): editing the healthz-semaphore-exemption
      # smoke or its helper re-runs the smoke directly (the scripts/smoke/*
      # catch-all already pulls it via the full static suite; this arm keeps the
      # selection focused when only these two files change). The exemption itself
      # lives in bridge-handoffd.py (process_request), so the bridge-handoffd.py
      # arm above also selects this smoke on a receiver change.
      add_required 1629-healthz-not-semaphore-gated
      ;;

    scripts/smoke/1630-a2a-fresh-arrival-nudge.sh)
      # Issue #1630 (audit R3, root cause of #10561): editing the fresh-arrival
      # nudge smoke re-runs it directly (the scripts/smoke/* catch-all already
      # pulls it via the full static suite; this arm keeps the selection focused
      # when only this file changes). The behavior spans bridge-handoffd.py
      # (marker writer) and bridge-queue.py daemon-step (marker consumer +
      # age-gate exemption), so those arms above also select this smoke.
      add_required 1630-a2a-fresh-arrival-nudge
      ;;

    scripts/smoke/1618-outbox-retry-resets-attempts.sh|scripts/smoke/1618-outbox-retry-resets-attempts-helper.py)
      # Issue #1618: editing the outbox-retry-reset smoke or its helper re-runs
      # the smoke directly (the scripts/smoke/* catch-all already pulls it via
      # the full static suite; this arm keeps the selection focused when only
      # these two files change). The helper is ALSO listed in the bridge-a2a.py
      # arm above so a sender change selects this smoke.
      add_required 1618-outbox-retry-resets-attempts
      ;;

    scripts/smoke/1628-a2a-deliver-per-row-guard.sh|scripts/smoke/1628-a2a-deliver-per-row-guard-helper.py)
      # Issue #1628: editing the per-row-guard smoke or its helper re-runs the
      # smoke directly (the scripts/smoke/* catch-all already pulls it via the
      # full static suite; this arm keeps the selection focused when only these
      # two files change). The deliver-loop guard itself lives in bridge-a2a.py,
      # so the bridge-a2a.py arm above also selects this smoke on a sender change.
      add_required 1628-a2a-deliver-per-row-guard
      ;;

    scripts/smoke/1640-urgent-from-override.sh)
      # Issue #1640: editing the urgent --from override smoke re-runs it
      # directly (the scripts/smoke/* catch-all already pulls it via the full
      # static suite; this arm keeps the selection focused when only this file
      # changes). The override itself lives in bridge-send.sh (parsed there and
      # threaded into infer_actor_if_possible) with the help text in the
      # agent-bridge/agb wrapper, so the bridge-send.sh|agent-bridge|agb arm
      # above also selects this smoke on a CLI change.
      add_required 1640-urgent-from-override
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
      # Issue #1786: bridge_cleanup_render_verification_block emits the
      # upgrade-complete db-health step. Pull the doctor-verb smoke whenever
      # the cleanup lib moves so step 4 cannot regress from the policy-blessed
      # `agent-bridge doctor --detectors tasks-db` verb back to the
      # hook-blocked raw `verify-tasks-db` command.
      add_required cleanup-payload-empty-stdin-872 upgrade telegram-relay-residue-cleanup 1786-tasksdb-doctor-verb
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
      # Fleet-credential Phase 1 (#1470): the engine-auth descriptor seam
      # + cred-generation schema groundwork. bridge-auth.py/.sh now
      # dispatch credential ops BY ENGINE through
      # lib/bridge-engine-descriptor.sh and stamp a per-agent
      # cred_generation at sync time. 1470-engine-auth-seam pins that
      # Claude stays behavior-preserving through the seam and that the
      # cred-generation state store is idempotent + fail-closed + 0600 +
      # never records the secret. Pull it on every auth move so a future
      # refactor cannot regress the Claude-no-regression contract or the
      # Q4 schema.
      #
      # Fleet-credential Phase 2 (#1470): the Codex register-once →
      # fleet-sync adapter (codex-cred {register,sync,verify,source} +
      # cmd_codex_*). 1470-codex-fleet-sync pins the write-through-not-
      # symlink delivery, digest idempotency, malformed/unreadable
      # fail-loud, symlink-dest refusal, NO cross-engine misdelivery,
      # no-secret-in-state, the Q6 active-scrub primitive, and the offline
      # well-formedness/source-binding teeth. Pull it on every auth move so
      # a refactor cannot regress the Codex security contracts.
      #
      # Issue #1367 (sealed-paste): bridge-auth.py/.sh host the new
      # `claude-token receive` verb (operator-terminal echo-off read +
      # token-free request/receipt). 1367-auth-sealed-paste pins the
      # no-tty fail-closed, the echo-off happy path (registry write +
      # canary-absence from transcript/audit), the token-free request,
      # and the negative guard shapes. Pull it on every auth move so a
      # future refactor cannot regress the sealed-paste contract.
      # PR #1790 (#1789 D1/D2): rotate is now limit-window aware
      # (--limited-until stamp, future-limited candidate skip,
      # all_tokens_limited refusal + sentinel-encoded TSV). The
      # 1789-rotation-limited-until wrapper runs the canonical
      # tests/claude-token-rotation suite so every auth move re-proves the
      # rotation contract end-to-end (r3 P1: previously dangling in tests/
      # with no CI mapping).
      #
      # Issue #1855: bridge-auth.py/.sh now host the keychain-free apiKeyHelper
      # `backfill-settings` subcommand (create-if-absent + --check coherence
      # report) and the cred-state-honesty `coherent` field on cmd_sync_agent.
      # 1855-keychain-free-backfill pins the create-if-absent / idempotency /
      # non-Darwin-no-op / --check-read-only / byte-identical-to-provision
      # contracts so a refactor of the shared settings writer cannot regress
      # the pre-#1520 backfill.
      add_required F-beta4-oauth-bootstrap daemon-periodic-token-sync 1358-admin-credential-routine-exempt 1367-auth-sealed-paste 1470-engine-auth-seam 1470-codex-fleet-sync 1789-rotation-limited-until 1855-keychain-free-backfill
      # Issue #1899: bridge-auth.sh's bridge_auth_codex_selected_agents +
      # codex sync loop now EXCLUDE dynamic vanilla Codex from the codex-cred
      # fleet sync (it inherits the operator-global ~/.codex/auth.json). Pull
      # 1899 on every bridge-auth move so the exclusion can't silently drop.
      add_required 1899-dynamic-vanilla-codex
      add_integration integration-minimal
      ;;

    tests/claude-token-rotation/*)
      # PR #1790 (#1789): edits to the rotation suite itself must re-run it.
      add_required 1789-rotation-limited-until
      add_integration integration-minimal
      ;;

    lib/bridge-secret-scrub.sh)
      # Fleet-credential Phase 2 (#1470, Q6): the shared scrub primitive
      # now carries bridge_secret_scrub_capture_codex /
      # bridge_secret_scrub_restore_codex for the OpenAI-key / Codex-token
      # ambient-key scrub. 1470-codex-fleet-sync §G exercises them;
      # F-beta4-oauth-bootstrap + 1520b cover the Claude transit the same
      # primitive backs so a scrub change cannot silently break either.
      add_required 1470-codex-fleet-sync F-beta4-oauth-bootstrap 1520b-create-time-creds-sync
      add_integration integration-minimal
      ;;

    lib/upgrade-helpers/codex-sync-summary.py)
      # Fleet-credential Phase 2 (#1470): the heredoc-free Codex fleet-sync
      # JSON summary helper invoked by bridge_auth_codex_sync_agents.
      add_required 1470-codex-fleet-sync
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
      # Issue #1563 PR-8 (rc2 A2A subtrack): bridge-daemon-helpers.py now hosts
      # ``a2a-diag-lookup`` — the per-peer directional-diagnosis extractor the
      # stuck-scan uses to enrich the alert body. 1563-pr8-a2a-diag-recovery
      # exercises it (TSV fields + absent-peer empty) so a helper refactor
      # cannot regress the enriched alert contract.
      add_required F-beta4-oauth-bootstrap daemon-periodic-token-sync daemon queue I-beta4-a2a-3-gaps mcp-liveness-giveup-auto-clear 1563-pr8-a2a-diag-recovery
      # PR #1790 r3 BLOCKING 1: rotation-status-parse now sentinel-encodes
      # empty TSV columns (`-`) so the daemon's IFS=$'\t' read cannot
      # collapse them. The rotation suite pins the encode/decode roundtrip.
      add_required 1789-rotation-limited-until
      # Issue #1732 (Lane B): bridge-daemon-helpers.py's ``a2a-stuck-decide`` is
      # now class-aware — it suppresses the [A2A] outbox stuck admin alarm for
      # transient peers (alarm_on_unreachable=False) and honors a per-peer longer
      # grace window. v0166-lb-transient-peers' alarm-class-aware case pins that
      # filter (transient suppressed, persistent unchanged) so a future helper
      # refactor cannot silently regress the quiet-noise policy.
      add_required v0166-lb-transient-peers
      # Issue #1936 (gap #4): bridge-daemon-helpers.py hosts the
      # ``human-followup-queued-state`` subcommand that classifies a
      # queued cron followup as human-facing (delivery_intent=
      # forward_to_user / legacy needs_human_followup). The 1936 smoke
      # sources this helper directly; pull it on every
      # bridge-daemon-helpers.py move so a future PR cannot regress the
      # classifier the attached-followup escalation depends on.
      add_required 1936-forward-followup-attached-escalation
      # Issue #1631 (A2A audit R4): bridge-daemon-helpers.py hosts the three
      # nudge-eligibility helpers (cmd_nudge_live_state,
      # cmd_nudge_eligibility_recheck, cmd_human_followup_queued_state) and the
      # shared _connect_queue_db_readonly guard that opens the queue DB read-only
      # (is_file() + file:...?mode=ro) so a missing/unreadable BRIDGE_TASK_DB
      # exits non-zero instead of CREATING an empty DB and reporting queued=0.
      # 1631-nudge-helper-db-guard pins the no-empty-DB-creation + rc!=0 + caller
      # skip-this-tick contract (with a guard-reverted negative control); pull it
      # on every helpers move so a future PR cannot regress the read-only guard.
      add_required 1631-nudge-helper-db-guard
      # Issue #1468: bridge-daemon-helpers.py hosts the
      # ``usage-probe-result-parse`` subcommand that classifies the native
      # usage-probe result for the `usage_probe` audit row (the §5 observability
      # path) and feeds the 429 near-limit signal flow. Pull the 1468 smoke on
      # every helpers move so a future PR cannot silently regress the parser the
      # proactive-rotation observability depends on.
      add_required 1468-usage-429-positive-signal
      # Issue #1803: bridge-daemon-helpers.py hosts the orphan-gc-non-clean +
      # orphan-gc-task-body subcommands the daemon orphan-dir GC pass consumes.
      # Pull the GC smoke on every helpers move so a refactor of those two
      # subcommands cannot silently regress the [hygiene] admin-task emit.
      add_required 1803-orphan-dir-gc
      # Issue #1809: bridge-daemon-helpers.py hosts the agent-doc-backfill-non-
      # clean + agent-doc-backfill-task-body subcommands the daemon codex
      # AGENTS.md doc-backfill hygiene pass consumes. Pull the #1809 smoke on
      # every helpers move so a refactor of those two subcommands cannot
      # silently regress the non-clean decision or the [hygiene] task body.
      add_required 1809-agents-md-backfill
      # Issue #1892: the same agent-doc-backfill-non-clean + -task-body helpers
      # now surface the fail-closed `held` rows (roster/heuristic engine
      # disagreement when agent-meta.env is absent). Pull the #1892 smoke on
      # every helpers move so a refactor cannot drop the held non-clean signal
      # or the held section of the [hygiene] task body.
      add_required 1892-doc-backfill-engine-fail-closed
      # Issue #1906: the same helpers now also fold engine_mismatch_docs (a stale
      # Codex-contract AGENTS.md on a non-codex agent) into non-clean and render
      # the flag-only [hygiene] section. Pull the #1906 smoke on every helpers
      # move so a refactor cannot drop the engine-mismatch non-clean signal or
      # the flag-only section of the [hygiene] task body.
      add_required 1906-flag-engine-mismatched-docs
      add_integration integration-minimal
      ;;

    bridge_orphan_classifier.py|bridge-orphan-gc.py)
      # Issue #1803: the action-safe agent-home-root classifier SSOT and the
      # GC action layer (quarantine + separate prune). Both are exercised by
      # the GC smoke (keep-set / age-gate / TOCTOU / move-as-link / prune
      # containment) and — because the classifier also backs the read-only
      # detector — the doctor's behavior-preserving smoke. Pull both so a
      # change to either file is caught by the detector AND the action teeth.
      add_required 1803-orphan-dir-gc orphan-agent-dir agent-doctor status-engine-detect
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
      # Issue #1824: bridge-usage-probe.py classifies a CDN-edge block (CF 429/403
      # with no anthropic origin headers) as `edge-blocked` and refuses to fabricate
      # a synthetic 100% near-limit cache from it (vs a genuine origin
      # account-rate-limit). Pull the edge-classification smoke on any usage-probe
      # move so a refactor cannot regress the edge-vs-quota classifier (which would
      # re-introduce synthetic-quota poisoning from an edge block).
      add_required usage-probe-edge-classification
      add_required daemon daemon-periodic-token-sync
      # #1725 weekly proactive rotation: the threshold-sanitize fail-safe lives
      # in bridge-usage.sh's env→Python chokepoint and the no-alternate weekly
      # escalation rides the same monitor path, so pin both on any bridge-usage
      # move — a malformed weekly/rotation env value must never crash the monitor
      # and silently disable the 5h hard-threshold rotation.
      add_required weekly-warn-threshold-sanitize weekly-usage-quota-escalation
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
      # Issue #1750: lib/bridge-init-codex-pair.sh provisions the `<admin>-dev`
      # pair onto the admin's SHARED workdir. The pair's start-time identity
      # sync must NOT stamp the codex-pair template over the admin's workdir
      # identity. Pull 1750-admin-workdir-identity-not-pair-template on every
      # pair-provisioning / init move so the fail-safe foreign-owner guard
      # stays wired to the topology that produced the drift.
      add_required admin-pair-server-auto-provision agent-create-caller-trust-gate upgrade-shared-settings-propagate managed-autocompact-window per-agent-settings-rendering I-agent-description-roster β-1231-1236-fresh-install-seed-sudoers F-beta4-oauth-bootstrap G-beta4-watchdog-noise beta5-2-epsilon-tmux-inject-busy 1492-admin-dev-pair-workspace-v2 1750-admin-workdir-identity-not-pair-template 1916-picker-sweep-migrate-atomic
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
      # Issue #1763: launch-cmd-static-claude-build.py now injects the
      # roster-materialized --model/--effort (with roster-wins /
      # preserve-when-empty precedence) so `agent update --model/--effort` is
      # no longer a silent no-op for static Claude agents. Pull the smoke on
      # every launch-cmd helper move so a refactor cannot drop the injection or
      # the dedup-against-baked-flags logic.
      add_required 835-static-admin-launch 1763-static-model-effort launch launch-dev-channels-injection channel-env-readiness agent-update-launch-cmd-redaction 1118-v2-engine-binary-path
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
      #
      # Issue #1769: resolve-claude-resume-session-id.py gained the
      # trusted_id (argv[7]) acceptance — when the candidate equals the id
      # run_restart vouched for via the short-TTL marker, the live-session
      # shortcut accepts it despite the dead pid. Pull 1769-restart-trusted-
      # resume on every helper move so a refactor cannot drop the trusted
      # accept (re-breaking fresh/idle restart resume) or widen it past the
      # candidate==trusted_id guard into a freshness-gate bypass.
      #
      # Issue #1807: both helpers' workdir_slug_candidates() gained a third
      # candidate `re.sub(r"[/._]", "-", path)` so an underscore-containing
      # workdir matches the on-disk Claude project dir (some Claude Code
      # versions map "_" → "-", anthropics/claude-code #30828; confirmed live
      # on cm-prod). Pull 1807-resume-slug-underscore on every helper move so
      # a refactor cannot drop the underscore candidate (re-breaking resume
      # for any agent whose workdir path contains "_") or narrow the
      # back-compat slash-only / slash+dot candidates.
      add_required 1015-resume-claude-config-dir 981-restart-session-resume-snapshot Beta-beta5-session-id-detect-sudo beta5-1-session-id-detect-race 1769-restart-trusted-resume 1807-resume-slug-underscore
      add_integration integration-minimal
      ;;

    scripts/python-helpers/seed-operator-plugin-config.py)
      # Issue #1753: this helper performs the seed-if-absent copy of the
      # operator's allowlisted plugin display config (default claude-hud) into
      # a Claude agent's `.claude/plugins/<plugin>/config.json`. A helper-only
      # change (dropping the dst-exists guard, breaking the allowlist gate, or
      # no-op'ing on an absent src) must still re-run the #1753 smoke so the
      # never-overwrite + allowlist contract cannot regress without CI catching
      # it.
      add_required 1753-hud-config-seed
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

    scripts/python-helpers/isolation-normalize-content-tree.py|scripts/python-helpers/isolation-publish-profile-files.py)
      # Issue #1533 / #1520c: the two ALWAYS-ROOT, TOCTOU-safe fd publishers
      # invoked by bridge_isolation_v2_publish_content_tree (whole content
      # tree) and bridge_isolation_v2_publish_workdir_profile_files (the six
      # profile basenames). Both open every node with O_NOFOLLOW and
      # fchown/fchmod the OPEN FD so a planted symlink redirect cannot
      # retarget the root mutation. A helper-only change (owner-gate tweak,
      # exclude semantics, mode/exec-bit handling) MUST re-run BOTH parent
      # smokes so the fd-based TOCTOU discipline + the stale-cache-publish
      # teeth cannot silently regress to a path-based root chgrp/chmod.
      add_required 1533-create-isolate-content-publish 1520c-create-isolate-profile-publish 1506-isolate-normalize
      # Issue #1766: the content-tree walker grew a target-validated
      # `settings.json -> settings.effective.json` symlink acceptance (the
      # planted-redirect guard now accepts EXACTLY that one self-target shape).
      # Pull the #1766 smoke so the accept/refuse contract cannot regress.
      add_required 1766-iso-settings-readable
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
      # Issue #1734 (v0.16.6 Lane C): bridge-lib.sh defines
      # BRIDGE_AGENT_ENV_LOCAL_FILE (the agent-env.local.sh path the set-env
      # wrapper writes + bridge_load_roster sources) and bridge-config.sh
      # dispatches the `config set-env` subcommand. `add_all_required_static`
      # already pulls the security smoke via the master list; the explicit
      # add_required pins it independently so a future change to the
      # master-list / catch-all coupling cannot silently drop it on a
      # bridge-lib.sh / bridge-config.sh move.
      add_required v0166-lc-config-set-env
      # Issue #1769: lib/bridge-agents.sh hosts the trusted-resume marker
      # helpers (bridge_agent_resume_trusted_marker_write / _id / _clear /
      # _path) that run_restart writes and the resolver consults.
      # `add_all_required_static` already pulls the smoke via the master
      # list; the explicit add_required pins it independently so a future
      # master-list/catch-all coupling change cannot silently drop it on a
      # bridge-agents.sh move.
      add_required 1769-restart-trusted-resume
      # Issue #1852: lib/bridge-agents.sh hosts the dynamic-restart guidance
      # helpers (bridge_agent_restart_dynamic_recreate_hint /
      # _unsupported_guidance) that run_restart's fail-closed + reassert paths
      # call. `add_all_required_static` already pulls the smoke via the master
      # list; pin it explicitly so a master-list/catch-all coupling change
      # cannot silently drop it on a bridge-agents.sh move.
      add_required 1852-dynamic-agent-restart
      # Issue #1853: lib/bridge-agents.sh hosts the self-restart helpers
      # (bridge_agent_restart_is_self / _relaunch_detached /
      # _self_unsupported_guidance) that run_restart's detached-survival path
      # calls. `add_all_required_static` already pulls the smoke via the master
      # list; pin it explicitly so a master-list/catch-all coupling change
      # cannot silently drop it on a bridge-agents.sh move.
      add_required 1853-self-restart-footgun
      # Issue #1881-C: lib/bridge-agents.sh hosts bridge_agent_live_mcp_status
      # (the runtime-state liveness classifier) and the bridge_agent_session_
      # health_json path that surfaces it as the `live_mcp_status` field on
      # `agent show --json`. `add_all_required_static` already pulls the smoke
      # via the master list; pin it explicitly so a master-list/catch-all
      # coupling change cannot silently drop it on a bridge-agents.sh move.
      add_required 1881-channel-enable-live-mcp-readiness
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
      # #1801: collect_broken_links is now a BOUNDED os.walk (entry/depth/
      # wall-time caps + dir exclusions) returning the explicit 3-state
      # complete/truncated/skipped contract, with a HOME-scale workdir guard
      # that degrades the scanner (status note) instead of escalating the
      # agent, plus a markdown report cap. Pull 1801-watchdog-bounded-broken-
      # links on every bridge-watchdog.py move so a refactor cannot
      # re-introduce the unbounded rglob (which blew the 30s scan ceiling on
      # a HOME-scale workdir for 9+ days) or silently drop / over-escalate
      # on a bound.
      # #1872: ``unsupported_engine_contract`` is now informational/advisory —
      # excluded from problem_count + the HIGH ``[watchdog] agent profile
      # drift`` task gate while staying visible in the report. The smoke pins
      # the POSITIVE case (healthy unsupported-engine agent → row visible,
      # problem tally 0) AND the NEGATIVE CONTROL (SAME engine with
      # broken_links > 0 → warn → STILL pages), so a refactor cannot either
      # re-promote the no-contract status to a problem (re-introducing the
      # patch-agy HIGH-task noise) or over-suppress it into a blanket
      # all-unsupported-engine mute that swallows real drift. Pull it on every
      # bridge-watchdog.py move.
      add_required watchdog-profile-contract watchdog-registry-anchored watchdog-silence-stderr-capture 1108-watchdog-v2-workdir 1119-watchdog-perm-error 1113-watchdog-legacy-backfill ε-watchdog-rescan-codex G-beta4-watchdog-noise 1520c-create-isolate-profile-publish 1801-watchdog-bounded-broken-links 1872-watchdog-unsupported-engine-info 1820-rc4-iso-stale-group-preflight codex-doctor queue
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
      # Issue #1781 (DATA-LOSS): bridge-docs.py owns AGENT_RUNTIME_REWRITE_FILES,
      # the in-place legacy-path rewrite set. MEMORY.md is agent-written state
      # and must stay OUT of that set. Pull the focused smoke (it pins the
      # source token) on every bridge-docs.py move so a refactor cannot
      # silently re-add MEMORY.md to the doc-rewrite list.
      add_required 1781-doc-migration-memory-preserve
      # Issue #1813: bridge-docs.py owns ensure_agent_shared_links /
      # cleanup_broken_shared_doc_links — the canon shared-doc symlink writer.
      # Pull the v2-depth resolution gate on every bridge-docs.py move so the
      # link-target math stays depth-correct (relpath, not hard-coded
      # `../shared`) and cleanup stays resolution-scoped (never name-based).
      add_required 1813-canon-links-resolve-v2
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
      # Fleet-credential Phase 1 (#1470): the engine-auth descriptor
      # added auth accessors (auth_supported / auth_model / cred_dest /
      # cred_source / supports_rotation / usage_source / cred_payload_key)
      # so bridge-auth dispatches credential ops by engine. Pull
      # 1470-engine-auth-seam on any descriptor move so a future PR
      # cannot drift the auth accessor table away from what bridge-auth
      # consumes.
      # Issue #1417: bridge_layout_sync_identity_from_home (the sync-on-start
      # reconciliation that propagates HOME identity edits to the workdir copy
      # without clobbering deliberate workdir runtime state) lives in this
      # module. Pull its smoke on every layout move so a refactor cannot
      # regress the differ+mtime guard or the watchdog-state scope guard.
      # Issue #10370: upgrade-time rematerialization reuses the layout
      # fileset/target semantics while bypassing sync-on-start's mtime guard.
      # Pull its smoke on layout moves so shared-cwd and target resolution
      # cannot drift.
      # Issue #1750: bridge_layout_workspace_foreign_owned + the sync/materialize
      # fail-safe guards that keep a codex sibling-pair's identity OUT of the
      # admin's shared workdir live in this module. Pull its smoke on every
      # layout move so a refactor cannot regress the foreign-owner guard and
      # reintroduce the fresh-install admin-workdir-identity drift.
      # Issue #1781 (DATA-LOSS): bridge_layout_materialize_identity shares the
      # MEMORY.md sync fileset with the upgrade-time rematerializer. Pull the
      # focused state-vs-doc smoke on every layout move so a refactor of the
      # shared fileset cannot re-introduce the home->workdir MEMORY clobber.
      add_required 1060-layout-fresh-v2-static-claude 1060-layout-fresh-v2-static-codex 1060-layout-shared-workdir-pair 1067-codex-provisioning v2-scaffold-home-and-workdir agent-doctor beta5-2-xi-misc-fixes 1470-engine-auth-seam 1417-identity-sync-on-start 1750-admin-workdir-identity-not-pair-template upgrade-migrate-rematerialize-workdir 1636-rematerialize-scaffolding 1781-doc-migration-memory-preserve
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
      # Issue #1663 (v0.16.2): the overlay (overlay_source_to_cache +
      # recursive _overlay_dir) now pattern-skips upgrade/VCS sidecars
      # (`*.upgrade-conflict`, `*.orig`, `*.rej`, merge-tool sidecars,
      # `.git`/`.hg`/`.svn`) and guards each entry so one unreadable file
      # (e.g. a 0600 owner-only conflict sidecar an iso UID cannot read)
      # is skipped+WARN'd instead of aborting the whole cache build and
      # cascade-failing every iso agent on the plugin — EXCEPT a required
      # plugin-contract file (plugin.json/package.json/server.ts|js/
      # mcp.json) which fails loud. Pull 1663-plugin-cache-sidecar-skip on
      # every bridge-dev-plugin-cache.py move so a refactor cannot revert
      # the sidecar-skip / per-entry-guard / required-contract contract.
      # Issue #1857: bridge-dev-plugin-cache.py is both the
      # known_marketplaces.json catalog writer (ensure_known_marketplace_for_root)
      # and the installed_plugins.json manifest writer
      # (_update_installed_plugins_manifest) the recreate-preserve contract
      # pins — the catalog writer MUST resolve its root from
      # BRIDGE_CLAUDE_PLUGINS_ROOT (leak-pin) and the manifest writer MUST
      # merge-not-reset operator-installed entries on a channel-only re-sync.
      # Pull 1857-recreate-provisioning-preserve on every move so a refactor
      # of either writer cannot silently regress the contract.
      add_required 1201-1202-directory-marketplace-seed channel-plugins 1208-lock-metadata-normalize ζ-1236-plugins-list-marketplaces β-1231-1236-fresh-install-seed-sudoers B-beta3-1249-1250-plugin-ux C1-beta3-1251-restart-preflight-rollback A3-beta3-1248-restart-session-id-resume C-beta4-logger-and-spec H-beta4-iso-ownership K-beta4-nits 1663-plugin-cache-sidecar-skip 1857-recreate-provisioning-preserve
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

    scripts/bridge-daemon-liveness.sh|bridge-watchdog-silence.py)
      # Issue #1463: the two out-of-band daemon supervisors. Both now route
      # their restart through the single `bridge-daemon.sh restart` verb
      # (launchd-aware: kickstart instead of out-of-band stop+start), and
      # both handle the rc=2 "out-of-band split refused" outcome distinctly.
      # Pull 1463-launchd-keepalive-singleton-thrash (the restart-primitive
      # contract) plus the silence-watchdog stderr-capture regression on
      # every supervisor move so neither the routing nor the refuse-handling
      # can silently regress to the thrash-inducing direct stop+start.
      add_required 1463-launchd-keepalive-singleton-thrash watchdog-silence-stderr-capture launch queue
      add_integration integration-minimal
      ;;

    bridge-escalate.sh)
      # Issue #1569: the bounded AskUserQuestion intercept
      # (hooks/askuserquestion_escalate.py, driven by hooks/tool-policy.py)
      # fires `agb escalate question` to route the question + options to the
      # human channel. Pull the bounded-AskUserQuestion smoke whenever
      # bridge-escalate.sh moves so a change to the escalate CLI shape cannot
      # silently regress the channel-routing leg of the bound. The escalate
      # CLI's own dynamic-routing contract is covered by the main
      # scripts/smoke-test.sh suite.
      add_required 1569-askuserquestion-bound queue
      add_integration integration-minimal
      ;;

    scripts/wiki-mention-scan.py)
      # Issue #1613 part (b): wiki-mention-scan.py's wikilink scanner now
      # blanks CommonMark 4-space / tab INDENTED code blocks (via the
      # length-preserving blank_indented_code pass) in addition to fenced
      # regions + inline codespans, and defensively rejects POSIX
      # bracket-class surfaces (`:space:` from `[[:space:]]`). Pull the
      # regression smoke whenever the scanner moves so bash `[[ ... ]]`
      # tests / POSIX classes in indented blocks can't re-leak as wikilinks
      # while genuine `[[wikilink]]` resolution stays intact.
      add_required 1613-wiki-mention-fence-indent
      add_integration integration-minimal
      ;;

    lib/bridge-picker.sh|lib/bridge-picker.py|runtime-templates/shared/picker-catalog.json|runtime-templates/skills/picker-resolve/SKILL.md)
      # Issue #1762: the no-LLM picker auto-resolve stage. lib/bridge-picker.sh
      # (shell orchestrator + safety rails), lib/bridge-picker.py (catalog
      # match / stuck-confirm / anti-loop), the shipped catalog, and the admin
      # picker-resolve skill all feed the same smoke. Pull it on any of their
      # moves so a refactor or a catalog schema change is caught.
      add_required 1762-picker-autoresolve
      # Issue #1766: the matcher also classifies the claude-settings-error
      # entry; pull the #1766 smoke so a matcher change cannot break it.
      add_required 1766-iso-settings-readable
      # Issue #1783: idle composers classify as non_picker (default catalog
      # entries) + the tightened bridge_picker_pane_looks_prompt_like heuristic +
      # the per-pass storm fuse all live in this same surface. Pull the
      # idle-nonpicker smoke on any picker source move so a heuristic/catalog/
      # fuse refactor cannot reopen the #1783 fleet-wide false-positive wave.
      add_required 1783-picker-idle-nonpicker
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

# Post-selection sharding (#1897). Filter the FINAL selected list to the
# requested shard via index-mod: the i-th selected script (0-based, in
# selection order) belongs to shard (i % shard_total) + 1. With no shard
# args (shard_total == 0) this is a no-op and selected_list is unchanged,
# so the unsharded path stays byte-identical to the pre-sharding behaviour.
# The union of shards 1..K equals the unsharded list with no duplicates and
# no omissions, and intra-shard order is preserved.
if [[ $shard_total -ge 1 ]]; then
  shard_filtered=""
  i=0
  # selected_list holds whitespace-free smoke paths (scripts/smoke/<name>.sh),
  # so word-splitting iterates them in order — the same idiom the --run loop
  # below uses (`for script in $selected_list`). No here-string / process-sub
  # here keeps the heredoc-ban ratchet baseline unchanged (footgun #11 hygiene).
  for script in $selected_list; do
    [[ -n "$script" ]] || continue
    if [[ $(( i % shard_total + 1 )) -eq $shard_index ]]; then
      shard_filtered+="$script"$'\n'
    fi
    i=$(( i + 1 ))
  done
  selected_list="$(printf '%s' "$shard_filtered" | sed '/^$/d')"
fi

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
