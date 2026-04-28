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

main() {
  smoke_make_temp_root "isolation"
  smoke_run "v2 isolation rootless primitives" bash "$SMOKE_REPO_ROOT/tests/isolation-v2-primitives/smoke.sh"
  smoke_log "passed"
}

main "$@"
