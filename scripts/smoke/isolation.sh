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
  local physical_tmp logical_tmp candidate result bash_bin

  physical_tmp="$SMOKE_TMP_ROOT/physical-tmp"
  logical_tmp="$SMOKE_TMP_ROOT/logical-tmp"
  candidate="$physical_tmp/tmp.bridge-home"
  bash_bin="$(smoke_bash4)"

  mkdir -p "$physical_tmp"
  ln -s "$physical_tmp" "$logical_tmp"

  result="$(TMPDIR="$logical_tmp" "$bash_bin" -c '
    source "$1/bridge-lib.sh"
    if bridge_tmp_ephemeral_path_is "$2"; then
      printf yes
    else
      printf no
    fi
  ' -- "$SMOKE_REPO_ROOT" "$candidate")"
  smoke_assert_eq "yes" "$result" "canonical TMPDIR path classified as ephemeral"
}

smoke_bash4() {
  local candidate
  for candidate in "${BASH:-}" /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  smoke_fail "bash 4+ is required for isolation smoke"
}

main() {
  smoke_make_temp_root "isolation"
  smoke_run "ephemeral detector accepts physical TMPDIR paths" canonical_tmpdir_ephemeral_detector
  smoke_run "v2 isolation rootless primitives" bash "$SMOKE_REPO_ROOT/tests/isolation-v2-primitives/smoke.sh"
  smoke_run "isolated Claude read lens mask repair" bash "$SMOKE_REPO_ROOT/tests/isolation-claude-read-lens/smoke.sh"
  smoke_log "passed"
}

main "$@"
