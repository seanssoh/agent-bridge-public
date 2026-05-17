#!/usr/bin/env bash
# Copy the tracked working tree into the live ~/.agent-bridge install.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
TARGET_ROOT="${HOME}/.agent-bridge"
DRY_RUN=0
RESTART_DAEMON=0
COPIED_COUNT=0
VERIFIED_COUNT=0
SKIPPED_COUNT=0
DRIFT_COUNT=0
UPGRADE_STATE_WRITTEN=0

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--target <dir>] [--dry-run] [--restart-daemon]

Copies every tracked file from the current working tree into the live install.
Runtime and target-only paths such as agent-roster.local.sh, state/, logs/, shared/, backups/, worktrees/, and live agent homes are never copied.
EOF
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# Explicit per-file-class mode contract for the live install.
#
# Background: `cp -p` preserves whatever the maintainer's source-tree perms
# happen to be (often 0600 / 0700 on a single-user dev box). On the live
# install, isolated-UID agents need group/other read on libs, hooks, marketplace
# manifests, and plugin lockfiles, plus group/other exec on entry scripts and
# hook handlers. Issue #792 captured the cascading restart failures that occur
# when source-tree perms leak through.
#
# Scope boundary: this helper sets POSIX mode bits only. POSIX ACL mask restore
# for `~/.claude/.credentials.json` and per-agent `workdir/.{teams,ms365}/.env`
# is intentionally NOT handled here — those paths live outside `$TARGET_ROOT`
# (operator-config, not deploy artifacts), and `should_skip_relpath` already
# excludes `agents/*`. ACL repair belongs in the isolation grant-matrix layer
# (`lib/bridge-isolation-v2.sh`), tracked separately.
deploy_live_install_set_mode() {
  local relpath="$1" dst="$2"
  local mode="0644"
  case "$relpath" in
    bridge-*.sh|bridge-*.py|agent-bridge|agb)
      mode="0755" ;;
    lib/*.sh|lib/*.py)
      mode="0644" ;;
    hooks/*.py|hooks/*.sh)
      mode="0755" ;;
    .claude-plugin/marketplace.json)
      mode="0644" ;;
    plugins/*/bun.lock|plugins/*/package.json|plugins/*/*.md|plugins/*/*.json)
      mode="0644" ;;
    plugins/*/*.ts|plugins/*/*.js|plugins/*/*.mjs|plugins/*/*.sh|plugins/*/*.py)
      mode="0755" ;;
    scripts/*.sh|scripts/smoke/*.sh)
      mode="0755" ;;
    scripts/*.py|scripts/*.md)
      mode="0644" ;;
    *.sh|*.py)
      mode="0644" ;;
    *)
      mode="0644" ;;
  esac
  run_cmd chmod "$mode" "$dst"
}

# Post-deploy sanity check: confirm a known-critical set of files ended up with
# permissions that the isolated-UID restart path can actually traverse.
# Non-fatal — failure emits a warning but does not abort the deploy, since
# aborting blocks operator recovery. Issue #792.
deploy_live_install_verify_critical_perms() {
  local errors=0
  local critical_files=(
    "$TARGET_ROOT/agent-bridge"
    "$TARGET_ROOT/agb"
    "$TARGET_ROOT/bridge-task.sh"
    "$TARGET_ROOT/lib/bridge-core.sh"
    "$TARGET_ROOT/hooks/prompt-guard.py"
    "$TARGET_ROOT/.claude-plugin/marketplace.json"
  )
  local f mode last_digit
  for f in "${critical_files[@]}"; do
    [[ -e "$f" ]] || continue
    if [[ ! -r "$f" ]]; then
      printf '[error] critical-perm: %s not readable by deployer\n' "$f" >&2
      errors=$((errors + 1))
    fi
    # `o+r` minimum: isolated UIDs (non-group members for marketplace etc.)
    # must be able to stat/read.
    mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo '')"
    case "$f" in
      *.sh|*/agent-bridge|*/agb|*.py)
        if [[ -n "$mode" ]]; then
          last_digit="${mode: -1}"
          if [[ "$last_digit" =~ ^[0-9]+$ ]] && (( last_digit < 4 )); then
            printf '[error] critical-perm: %s mode=%s lacks o+r (isolated UIDs cannot read)\n' "$f" "$mode" >&2
            errors=$((errors + 1))
          fi
        fi ;;
    esac
  done
  if (( errors > 0 )); then
    printf '[error] deploy-live-install: %d critical-perm checks failed\n' "$errors" >&2
    return 1
  fi
  printf '[info] deploy-live-install: critical-perm verification passed\n'
  return 0
}

should_skip_relpath() {
  local relpath="$1"

  case "$relpath" in
    agent-roster.local.sh|logs|logs/*|shared|shared/*|state|state/*|backups|backups/*|worktrees|worktrees/*)
      return 0
      ;;
    agents/_template/*|agents/.claude/*|agents/README.md|agents/SYNC-MODEL.md|agents/CUTOVER-WAVES.md|agents/WORKSPACE-MIGRATION-PLAN.md)
      return 1
      ;;
    agents/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

note_skip_relpath() {
  local relpath="$1"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] skip runtime path %s\n' "$relpath"
  else
    printf '[info] skipping runtime path %s\n' "$relpath"
  fi
}

copy_tracked_file() {
  local relpath="$1"
  local src="$SOURCE_ROOT/$relpath"
  local dst="$TARGET_ROOT/$relpath"

  if should_skip_relpath "$relpath"; then
    note_skip_relpath "$relpath"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    return 0
  fi

  [[ -f "$src" ]] || return 0

  run_cmd mkdir -p "$(dirname "$dst")"
  run_cmd cp -p "$src" "$dst"
  # #792: source-tree perms can be 0600/0700; force the live-install contract.
  deploy_live_install_set_mode "$relpath" "$dst"
  COPIED_COUNT=$((COPIED_COUNT + 1))
}

verify_tracked_file() {
  local relpath="$1"
  local src="$SOURCE_ROOT/$relpath"
  local dst="$TARGET_ROOT/$relpath"

  if should_skip_relpath "$relpath"; then
    return 0
  fi

  [[ -f "$src" ]] || return 0
  [[ -f "$dst" ]] || {
    echo "[error] missing deployed file: $dst" >&2
    exit 1
  }

  if ! cmp -s "$src" "$dst"; then
    echo "[error] deployed file differs: $relpath" >&2
    exit 1
  fi

  VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
}

report_reverse_drift() {
  local relpath="$1"
  local src="$SOURCE_ROOT/$relpath"
  local dst="$TARGET_ROOT/$relpath"

  if should_skip_relpath "$relpath"; then
    return 0
  fi

  [[ -f "$src" ]] || return 0
  [[ -f "$dst" ]] || return 0

  if cmp -s "$src" "$dst"; then
    return 0
  fi

  DRIFT_COUNT=$((DRIFT_COUNT + 1))
  printf '[warn] live file differs from repo: %s\n' "$relpath" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || {
        echo "--target requires a directory" >&2
        exit 1
      }
      TARGET_ROOT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --restart-daemon)
      RESTART_DAEMON=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! git -C "$SOURCE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "[error] source root is not a git working tree: $SOURCE_ROOT" >&2
  exit 1
fi

mkdir -p "$TARGET_ROOT"

while IFS= read -r -d '' relpath; do
  report_reverse_drift "$relpath"
done < <(git -C "$SOURCE_ROOT" ls-files -z)

if [[ "$DRIFT_COUNT" -gt 0 ]]; then
  printf '[warn] detected %s live files that differ from repo before deploy\n' "$DRIFT_COUNT" >&2
fi

while IFS= read -r -d '' relpath; do
  copy_tracked_file "$relpath"
done < <(git -C "$SOURCE_ROOT" ls-files -z)

if [[ "$DRY_RUN" == "0" ]]; then
  while IFS= read -r -d '' relpath; do
    verify_tracked_file "$relpath"
  done < <(git -C "$SOURCE_ROOT" ls-files -z)

  # #792: non-fatal sanity sweep so the operator notices a perms regression
  # the moment it ships, instead of after six isolated-UID restart failures.
  if ! deploy_live_install_verify_critical_perms; then
    printf '[warn] deploy-live-install: critical-perm verification flagged issues (see above)\n' >&2
  fi

  # PR #953 r4 (codex review): normalize traverse perms on lib helper dirs
  # created under controller umask=077. Files inside are chmod'd by
  # copy_tracked_file, but parent dirs created via mkdir -p stay 0700,
  # blocking isolated-UID agents from invoking the helpers. Mirrors the
  # post-apply chmod block in bridge-upgrade.sh.
  for helper_dir in scripts/python-helpers lib/cron-helpers lib/daemon-helpers lib/upgrade-helpers lib/lint-helpers lib/agent-cli-helpers; do
    if [[ -d "$TARGET_ROOT/$helper_dir" ]]; then
      find "$TARGET_ROOT/$helper_dir" -type d -exec chmod a+rX {} + 2>/dev/null || true
    fi
  done

  python3 "$SOURCE_ROOT/bridge-upgrade.py" write-state \
    --source-root "$SOURCE_ROOT" \
    --target-root "$TARGET_ROOT" >/dev/null
  UPGRADE_STATE_WRITTEN=1
fi

if [[ "$RESTART_DAEMON" == "1" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] bash %s/bridge-daemon.sh stop --force\n' "$TARGET_ROOT"
    printf '[dry-run] bash %s/bridge-daemon.sh ensure\n' "$TARGET_ROOT"
  elif [[ ! -f "$TARGET_ROOT/state/layout-marker.sh" ]]; then
    # Clean install path: layout-marker.sh hasn't been written yet
    # (bridge-bootstrap.sh writes it on first run). Skipping daemon
    # restart here — the bootstrap step that follows is the canonical
    # marker-writer + first daemon-start. Without this skip,
    # bridge-daemon.sh ensure would source bridge-lib.sh, which would
    # hard-die in bridge_layout_resolver_init at
    # `markerless(fresh-install-candidate)` because the bypass nonce
    # is not armed for this subprocess.
    DAEMON_RESTART_SKIPPED=1
  else
    # --force: deploy-live-install is a sanctioned daemon stop+restart path
    # and must not be blocked by the #314/#315 active-agent guard.
    bash "$TARGET_ROOT/bridge-daemon.sh" stop --force >/dev/null 2>&1 || true
    bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
  fi
fi

printf 'source_root: %s\n' "$SOURCE_ROOT"
printf 'target_root: %s\n' "$TARGET_ROOT"
printf 'copied_files: %s\n' "$COPIED_COUNT"
printf 'skipped_runtime_paths: %s\n' "$SKIPPED_COUNT"
printf 'predeploy_live_drift: %s\n' "$DRIFT_COUNT"
if [[ "$DRY_RUN" == "0" ]]; then
  printf 'verified_files: %s\n' "$VERIFIED_COUNT"
  printf 'upgrade_state_written: %s\n' "$([[ "$UPGRADE_STATE_WRITTEN" == "1" ]] && printf yes || printf no)"
fi
if [[ "${DAEMON_RESTART_SKIPPED:-0}" == "1" ]]; then
  printf 'daemon_restarted: skipped-fresh-install\n'
else
  printf 'daemon_restarted: %s\n' "$([[ "$RESTART_DAEMON" == "1" ]] && printf yes || printf no)"
fi
