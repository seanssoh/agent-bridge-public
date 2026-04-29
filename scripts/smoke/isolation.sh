#!/usr/bin/env bash

set -euo pipefail

SMOKE_NAME="isolation"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

canonical_tmpdir_ephemeral_detector() {
  local physical_tmp logical_tmp candidate result

  physical_tmp="$SMOKE_TMP_ROOT/physical-tmp"
  logical_tmp="$SMOKE_TMP_ROOT/logical-tmp"
  candidate="$physical_tmp/tmp.bridge-home"

  mkdir -p "$physical_tmp"
  ln -s "$physical_tmp" "$logical_tmp"

  result="$(TMPDIR="$logical_tmp" "$BASH" -c '
    source "$1/bridge-lib.sh"
    if bridge_tmp_ephemeral_path_is "$2"; then
      printf yes
    else
      printf no
    fi
  ' -- "$SMOKE_REPO_ROOT" "$candidate")"
  smoke_assert_eq "yes" "$result" "canonical TMPDIR path classified as ephemeral"
}

main() {
  smoke_make_temp_root "isolation"
  smoke_run "ephemeral detector accepts physical TMPDIR paths" canonical_tmpdir_ephemeral_detector
  smoke_run "v2 isolation rootless primitives" bash "$SMOKE_REPO_ROOT/tests/isolation-v2-primitives/smoke.sh"
  smoke_run "isolated Claude read lens mask repair" bash "$SMOKE_REPO_ROOT/tests/isolation-claude-read-lens/smoke.sh"
  smoke_log "passed"
}

main "$@"
