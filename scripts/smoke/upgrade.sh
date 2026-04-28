#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="upgrade"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

upgrade_backup_dry_run() {
  local target_root backup_root backup_json created manifest

  target_root="$SMOKE_TMP_ROOT/backup-target"
  backup_root="$SMOKE_TMP_ROOT/backup-root"
  mkdir -p "$target_root/state" "$target_root/shared"
  printf 'live state\n' >"$target_root/state/probe.txt"

  backup_json="$(
    python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" backup-live \
      --source-root "$SMOKE_REPO_ROOT" \
      --target-root "$target_root" \
      --backup-root "$backup_root" \
      --dry-run
  )"
  created="$(python3 - "$backup_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["created"])
PY
)"
  manifest="$(python3 - "$backup_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["manifest_path"])
PY
)"
  smoke_assert_eq "False" "$created" "upgrade backup-live dry-run does not create snapshot"
  [[ ! -e "$manifest" ]] || smoke_fail "upgrade backup-live dry-run created manifest unexpectedly: $manifest"
}

upgrade_backup_apply_primitives() {
  local source_repo target_root base_ref apply_json analyze_json mode

  source_repo="$SMOKE_TMP_ROOT/upgrade-source"
  target_root="$SMOKE_TMP_ROOT/upgrade-target"
  mkdir -p "$source_repo" "$target_root"
  git -C "$source_repo" init >/dev/null
  git -C "$source_repo" config user.email "smoke@local.invalid"
  git -C "$source_repo" config user.name "Smoke"
  printf 'old\n' >"$source_repo/sample.txt"
  git -C "$source_repo" add sample.txt
  git -C "$source_repo" commit -m base >/dev/null
  base_ref="$(git -C "$source_repo" rev-parse HEAD)"
  printf 'new\n' >"$source_repo/sample.txt"
  git -C "$source_repo" add sample.txt
  git -C "$source_repo" commit -m update >/dev/null

  printf 'old local\n' >"$target_root/sample.txt"
  analyze_json="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" analyze-live --source-root "$source_repo" --target-root "$target_root" --base-ref "$base_ref")"
  smoke_assert_contains "$analyze_json" "\"mode\": \"upgrade-analyze\"" "upgrade analyze-live mode"

  apply_json="$(python3 "$SMOKE_REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$source_repo" --target-root "$target_root" --base-ref "$base_ref")"
  mode="$(python3 - "$apply_json" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["mode"])
PY
)"
  smoke_assert_eq "upgrade-apply" "$mode" "upgrade apply-live mode"
  smoke_assert_eq "new" "$(cat "$target_root/sample.txt")" "upgrade apply-live applies upstream content"
}

main() {
  smoke_require_cmd git
  smoke_require_cmd python3
  smoke_setup_bridge_home "upgrade"
  smoke_run "upgrade backup-live dry-run contract" upgrade_backup_dry_run
  smoke_run "upgrade analyze/apply primitives" upgrade_backup_apply_primitives
  smoke_log "passed"
}

main "$@"
