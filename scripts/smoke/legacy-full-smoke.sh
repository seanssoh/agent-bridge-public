#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[legacy-full-smoke] running legacy monolithic scripts/smoke-test.sh" >&2
exec "$REPO_ROOT/scripts/smoke-test.sh" "$@"
