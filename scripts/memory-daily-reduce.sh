#!/usr/bin/env bash
# memory-daily reducer — controller-side helper that combines per-agent
# memory-daily fragments into the canonical shared aggregate dir.
#
# Issue #786 Finding 2 / Design A: under linux-user isolation the
# per-agent harvester runs as the isolated UID and writes only its own
# fragment under `<agent_root>/runtime/memory-daily/` (matrix row
# `agent-runtime` mode 2770 group=ab-shared). It does NOT write to the
# shared aggregate dir (matrix row `shared-memory-daily-aggregate`
# mode 2750), which is r-x only for isolated UIDs.
#
# This reducer runs as the controller, reads each isolated agent's
# fragments via group read access, and copies them into the shared
# aggregate dir as `admin-aggregate-<agent>-<filename>`. The minimal-
# scope contract for v0.9.8: pass-through copy. A future PR may merge
# fragments into a single combined admin-aggregate-*.json.
#
# Usage:
#   scripts/memory-daily-reduce.sh
#
# Environment:
#   BRIDGE_HOME            (default: $HOME/.agent-bridge)
#   BRIDGE_LAYOUT          required: v2 (legacy installs are no-op)
#   BRIDGE_DATA_ROOT       required under v2
#   BRIDGE_AGENT_ROOT_V2   required under v2
#   BRIDGE_SHARED_ROOT     required under v2
set -euo pipefail

: "${BRIDGE_HOME:=$HOME/.agent-bridge}"

if [[ "${BRIDGE_LAYOUT:-legacy}" != "v2" ]]; then
  printf '[memory-daily-reduce] layout=%s; reducer is v2-only, exiting cleanly\n' \
    "${BRIDGE_LAYOUT:-legacy}" >&2
  exit 0
fi

if [[ -z "${BRIDGE_AGENT_ROOT_V2:-}" || -z "${BRIDGE_SHARED_ROOT:-}" ]]; then
  printf '[memory-daily-reduce] missing BRIDGE_AGENT_ROOT_V2 or BRIDGE_SHARED_ROOT under v2; exiting\n' >&2
  exit 0
fi

if [[ ! -d "$BRIDGE_AGENT_ROOT_V2" ]]; then
  printf '[memory-daily-reduce] BRIDGE_AGENT_ROOT_V2=%s does not exist; exiting\n' \
    "$BRIDGE_AGENT_ROOT_V2" >&2
  exit 0
fi

aggregate_dir="$BRIDGE_SHARED_ROOT/memory-daily/aggregate"
mkdir -p "$aggregate_dir"

reduced=0
skipped=0
errors=0

# Iterate every per-agent root under BRIDGE_AGENT_ROOT_V2. Skip entries
# that are not directories (e.g. dotfiles, transient marker files).
shopt -s nullglob
for agent_dir in "$BRIDGE_AGENT_ROOT_V2"/*/; do
  agent_name="$(basename "$agent_dir")"
  fragment_dir="$agent_dir/runtime/memory-daily"
  [[ -d "$fragment_dir" ]] || { skipped=$((skipped + 1)); continue; }

  for fragment in "$fragment_dir"/*.json; do
    [[ -f "$fragment" ]] || continue
    fragment_name="$(basename "$fragment")"
    # Skip sidecar / adhoc artifacts — only canonical date-named fragments
    # are eligible for reduction. Sidecars carry per-run scratch data and
    # would noisily bloat the shared aggregate.
    case "$fragment_name" in
      adhoc.*|*.tmp.*|.*) continue ;;
    esac

    target="$aggregate_dir/admin-aggregate-${agent_name}-${fragment_name}"
    # Atomic-ish copy: write to a tmp sibling then rename. Python's
    # _atomic_write_json convention reused so the controller-side reducer
    # composes well with concurrent readers.
    #
    # r2 codex catch — was `cp -p` which preserved the per-agent fragment
    # mode (typically 0660 on the matrix runtime/memory-daily/ row). The
    # aggregate row contract is `controller:ab-shared 0640`, so the copy
    # must DROP the source mode and chmod 0640 on the destination tmp
    # before rename. Otherwise verify reports the aggregate file as
    # mismatch even though the directory mode is canonical.
    tmp="${target}.tmp.$$"
    if cp "$fragment" "$tmp" 2>/dev/null \
        && chmod 0640 "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$target" 2>/dev/null; then
      reduced=$((reduced + 1))
    else
      rm -f "$tmp" 2>/dev/null || true
      errors=$((errors + 1))
      printf '[memory-daily-reduce] copy failed: %s -> %s\n' "$fragment" "$target" >&2
    fi
  done
done
shopt -u nullglob

printf '[memory-daily-reduce] reduced=%d skipped_agents=%d errors=%d aggregate_dir=%s\n' \
  "$reduced" "$skipped" "$errors" "$aggregate_dir" >&2

if [[ "$errors" -gt 0 ]]; then
  exit 1
fi
exit 0
