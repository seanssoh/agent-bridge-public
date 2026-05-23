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
# Contract: export → plan → apply → verify. Never mutates the source in-place.
#
# Subcommands:
#   export  --source <old-BRIDGE_HOME> --bundle <dir>   (read-only on source)
#   plan    --bundle <dir>  --target <new-BRIDGE_HOME>   (read-only on target)
#   apply   --bundle <dir>  --target <new-BRIDGE_HOME>   (writes to target)
#   verify  --target <new-BRIDGE_HOME>                   (read-only check)
#
# Safety gates (apply only):
#   - apply is EXPLICIT / off-by-default — must invoke `apply` subcommand.
#   - target must be a CLEAN / FRESH install (not populated); apply refuses otherwise.
#   - a backup + manifest are written to target before any mutation.
#   - secrets are never copied; apply prompts for re-entry via file / env / stdin.
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
            [EXPLICIT / off-by-default] Write the bundle into a clean target.
            Requires: clean/fresh target, mandatory backup, secrets re-entered.
            Optional: --app-password-file <file>  (Teams client secret)
                      --a2a-secret-file <file>     (A2A HMAC key file, JSON)

  verify  --target <new-BRIDGE_HOME>
            Run the verification gate against the migrated target.

Options:
  --help, -h    Print this help and exit.

Safety:
  apply refuses a non-empty / already-populated target.
  Secrets (Teams client secret, A2A HMAC keys) are NEVER copied from the
  source bundle. Supply them via --app-password-file / --a2a-secret-file,
  BRIDGE_TEAMS_APP_PASSWORD env var, or interactive stdin prompt.

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
