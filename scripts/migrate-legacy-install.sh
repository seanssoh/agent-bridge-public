#!/usr/bin/env bash
# shellcheck shell=bash
#
# scripts/migrate-legacy-install.sh — standalone legacy-install → clean-install migrator.
#
# Moves an old Agent Bridge install's agent-related identity into a fresh
# clean-install bridge target. This tool is OPERATOR-RUN ONLY. It is
# intentionally decoupled from bridge-upgrade.sh / bridge-init.sh /
# bridge-bootstrap.sh and must never be called from those paths.
#
# Contract: export → plan → apply → verify (issue #1087 closed all four
# subcommands for v0.14.5-beta7+). Never mutates the source in-place.
#
# Subcommands:
#   export  --source <old-BRIDGE_HOME> --bundle <dir>   (read-only on source)
#   plan    --bundle <dir>  --target <new-BRIDGE_HOME>   (read-only inspection)
#   apply   --bundle <dir>  --target <new-BRIDGE_HOME>   (writes target identity)
#   verify  --target <new-BRIDGE_HOME>                   (read-only check)
#
# Safety design (apply):
#   - apply is EXPLICIT / off-by-default — must invoke `apply` subcommand.
#   - target must be a CLEAN / FRESH install (not populated); apply refuses
#     otherwise. The cleanliness gate covers every apply write path
#     (state/agents, state/tasks.db, state/cron, data/agents, agents/,
#     agent-roster.sh, agent-roster.local.sh, cron/jobs.json,
#     handoff.local.json, .env, .migrator-apply-result.json).
#   - canonical per-agent paths come from `bridge_layout_agent_home` /
#     `bridge_layout_workspace_dir` / `bridge_layout_memory_dir` via the
#     layout shim (scripts/python-helpers/migrate-layout-shim.sh) — apply
#     does NOT compute layout paths itself.
#   - apply runs atomically: every write lands under
#     `target/.migrator-apply-staging` first, then is moved into the
#     canonical layout via `os.replace`. Failure mid-flight restores the
#     target's pre-apply file contents from the backup tree.
#   - a pre-apply content backup (NOT just a hash manifest) is written
#     to `.migrator-pre-apply-backup/files/` before any mutation.
#   - source secrets are NEVER copied; operator-supplied credentials via
#     --a2a-secret-file / --app-password-file (or BRIDGE_A2A_SHARED_SECRET
#     / BRIDGE_TEAMS_APP_PASSWORD env) ARE written to the target with
#     mode 0600.
#   - cron `payload.env` is filtered through CRON_ENV_ALLOWLIST (no
#     keyword heuristic); custom env keys are dropped.
#   - migrator is never wired into upgrade / init / bootstrap flows.
#
# Classification of items:
#   portable       — roster intent, per-agent identity (SOUL/MEMORY/etc.),
#                    cron definitions, non-secret channel config, host-profile.
#   non-portable   — tmux sessions, pid files, daemon state, queue leases,
#                    generated hooks/settings, plugin caches, logs, temp dirs,
#                    worktrees, backup snapshots, live process state.
#   secret         — Teams client secret, HMAC A2A peer keys — re-enter; never copy.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
MIGRATOR_PY="$SCRIPT_DIR/python-helpers/migrate-legacy-install-helper.py"

VERSION="1"
MIGRATOR_TAG="migrate-legacy-v${VERSION}"

_die() {
  printf '[migrator][error] %s\n' "$*" >&2
  exit 1
}

_info() {
  printf '[migrator] %s\n' "$*"
}

_warn() {
  printf '[migrator][warn] %s\n' "$*" >&2
}

usage() {
  cat <<'USAGE'
Usage: scripts/migrate-legacy-install.sh <subcommand> [options]

Subcommands:
  export  --source <old-BRIDGE_HOME> --bundle <dir>
            Read the old install (read-only) and write a portable bundle.

  plan    --bundle <dir> --target <new-BRIDGE_HOME>
            Compute and print the apply plan (read-only on both sides).

  apply   --bundle <dir> --target <new-BRIDGE_HOME>
            Apply the bundle to a clean/fresh target. Writes per-agent
            identity, cron definitions, and operator-supplied secrets
            (via --a2a-secret-file / --app-password-file). Atomic: every
            write is staged under .migrator-apply-staging and moved into
            place at the end; failure mid-flight rolls back to a
            byte-for-byte pre-apply backup. Refuses non-empty targets.

  verify  --target <new-BRIDGE_HOME>
            Run the verification gate against the migrated target.
            Drives the same layout resolver apply uses, so verify and
            apply cannot drift apart.

Options:
  --help, -h                        Print this help and exit.
  --a2a-secret-file <path>          Apply only — file containing the A2A
                                    HMAC shared secret. Written to the
                                    target's handoff.local.json (mode 0600).
  --app-password-file <path>        Apply only — file containing the Teams
                                    app password. Written to the target's
                                    .env (mode 0600).

Safety:
  Secrets (Teams client secret, A2A HMAC keys) are NEVER copied from the
  source bundle. The bundle marks them as deliberately absent. Apply
  ONLY writes secrets that the operator supplied via --a2a-secret-file /
  --app-password-file (or the matching env vars BRIDGE_A2A_SHARED_SECRET
  / BRIDGE_TEAMS_APP_PASSWORD).

This tool is OPERATOR-RUN ONLY. Never invoke from upgrade / init / bootstrap.
USAGE
}

require_python3() {
  command -v python3 >/dev/null 2>&1 || _die "python3 is required"
}

require_migrator_py() {
  [[ -f "$MIGRATOR_PY" ]] || _die "helper not found: $MIGRATOR_PY"
}

subcommand="${1:-}"
[[ -n "$subcommand" ]] || { usage >&2; exit 2; }
shift

case "$subcommand" in
  --help|-h)
    usage
    exit 0
    ;;
  export|plan|apply|verify)
    ;;
  *)
    _die "unknown subcommand: $subcommand  (use export / plan / apply / verify)"
    ;;
esac

# Parse remaining args into a flat argv we forward to the Python helper.
# The Python helper owns all flag parsing for each subcommand to keep this
# shell thin and heredoc-free.

require_python3
require_migrator_py

_info "subcommand: $subcommand"

# Forward to Python helper with subcommand as first positional arg.
# No heredoc / here-string / process-substitution-to-stdin — footgun #11 safe.
exec python3 "$MIGRATOR_PY" "$subcommand" \
  --repo-root "$REPO_ROOT" \
  --migrator-tag "$MIGRATOR_TAG" \
  "$@"
