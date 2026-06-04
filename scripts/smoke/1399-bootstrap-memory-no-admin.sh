#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1399-bootstrap-memory-no-admin.sh — Issue #1399.
#
# `bootstrap-memory-system.sh` runs under `set -euo pipefail`. The admin-
# extraction block near the top of the script reads the live roster to pick
# up `BRIDGE_ADMIN_AGENT_ID` via a `grep | head | sed` pipeline:
#
#   _admin_line="$(grep -E '...BRIDGE_ADMIN_AGENT_ID=' "$_roster" \
#       | head -n 1 | sed -E '...')"
#
# On an **admin-less roster** (no agent declares BRIDGE_ADMIN_AGENT_ID) the
# `grep` matches nothing and exits 1. Under `pipefail` that non-zero rc
# becomes the pipeline's status, and under `set -e` the simple-command
# assignment aborts the whole script before it can fall back to the
# `patch` default. The script should treat "no admin found" as a valid
# EMPTY result, not a fatal error.
#
# Fix (#1399): guard ONLY the legitimately-empty grep with a brace group +
# `|| true` — `{ grep ... || true; } | head | sed` — so a no-match yields
# an empty admin line without aborting, while a real failure inside
# `head`/`sed` still surfaces under pipefail (no blanket masking of the
# whole pipeline).
#
# Layers, in order:
#   T1 (source-structure): the admin-extraction grep is wrapped in a
#       `{ ... || true; }` brace group — i.e. the no-match-is-empty guard
#       is present and scoped to the grep, NOT a blanket `|| true` on the
#       trailing `sed` of the pipeline.
#   T2 (pipeline isolation): an extracted copy of the guarded pipeline
#       shape, run under `set -euo pipefail` against a no-admin input,
#       does NOT abort and yields an empty result; the same shape WITHOUT
#       the guard DOES abort (proves the guard is load-bearing).
#   T3 (end-to-end positive): the real `bootstrap-memory-system.sh` run
#       against a fresh admin-less BRIDGE_HOME passes the admin-extraction
#       block (it reaches the wiki-graph default-off short-circuit and
#       exits 0 with the `wiki_graph_skipped=1` marker) instead of
#       aborting mid-extraction.
#   T4 (end-to-end with admin): the same run against a roster that DOES
#       declare BRIDGE_ADMIN_AGENT_ID still works (regression guard — the
#       guard must not swallow a real match).
#
# Footgun #11 (heredoc-stdin): every captured subprocess uses
# `out=$(... 2>&1)`. No `<<EOF` / `<<'PY'` fed to a subprocess; the only
# heredocs write roster files to disk via redirection.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1399-bootstrap-memory-no-admin][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="1399-bootstrap-memory-no-admin"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd grep
smoke_require_cmd sed
smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"
BOOTSTRAP="$REPO_ROOT/bootstrap-memory-system.sh"
smoke_assert_file_exists "$BOOTSTRAP" "T0: bootstrap-memory-system.sh present in repo root"

BRIDGE_BASH_BIN="${BRIDGE_BASH_BIN:-$(command -v bash)}"
export BRIDGE_BASH_BIN

# ----------------------------------------------------------------------------
# T1 (source-structure): the admin-extraction grep is brace-grouped with
# `|| true`. We pull the line that pipes the BRIDGE_ADMIN_AGENT_ID grep
# into head/sed and assert it opens with `{ grep ... || true; } |`.
# ----------------------------------------------------------------------------
smoke_log "T1: admin-extraction grep is guarded with a brace-group '|| true'"

EXTRACT_LINE="$(grep -nE 'grep -E .*BRIDGE_ADMIN_AGENT_ID=.* \| head -n 1 \| sed' "$BOOTSTRAP" || true)"
[[ -n "$EXTRACT_LINE" ]] || smoke_fail "T1: could not locate the admin-extraction grep|head|sed pipeline in $BOOTSTRAP"
smoke_assert_contains "$EXTRACT_LINE" '{ grep -E' \
  "T1: the admin-extraction grep must be wrapped in a brace group"
smoke_assert_contains "$EXTRACT_LINE" '|| true; } | head -n 1 | sed' \
  "T1: the brace group must close with '|| true;' before the head|sed tail (no-match-is-empty guard)"

# ----------------------------------------------------------------------------
# T2 (pipeline isolation): run the guarded vs unguarded pipeline shapes
# under `set -euo pipefail` against an admin-less input. The guard must
# make a no-match non-fatal+empty; without it the pipeline must abort.
# ----------------------------------------------------------------------------
smoke_log "T2: guarded pipeline is non-fatal on no-match; unguarded shape aborts"

T2_NO_ADMIN="$SMOKE_TMP_ROOT/t2-no-admin.sh"
cat >"$T2_NO_ADMIN" <<'ROSTER'
BRIDGE_AGENT_IDS=(alpha beta)
BRIDGE_AGENT_CHANNELS[alpha]="plugin:teams"
ROSTER

# Guarded shape (the #1399 fix) — must exit 0 with empty output. Run as a
# top-level `bash -c` script body so it mirrors the real bootstrap context
# exactly (and pairs symmetrically with the unguarded check below).
T2_GUARDED_RC=0
T2_GUARDED_OUT="$(
  "$BRIDGE_BASH_BIN" -c '
set -euo pipefail
{ grep -E "^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=" "$1" || true; } \
  | head -n 1 \
  | sed -E "s/^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=//"
' _ "$T2_NO_ADMIN"
)" || T2_GUARDED_RC=$?
smoke_assert_eq "0" "$T2_GUARDED_RC" "T2: guarded pipeline must not abort on a no-admin roster"
smoke_assert_eq "" "$T2_GUARDED_OUT" "T2: guarded pipeline must yield an empty admin line on no-match"

# Unguarded shape (pre-fix) — must abort under pipefail (rc != 0). We run
# it as a fresh `bash -c` script body (the same context the real
# bootstrap script runs in — a top-level statement under `set -euo
# pipefail`, not a nested subshell, which has a `set -e` corner case for
# the trailing assignment) so the abort is deterministic. This proves the
# guard in T1 is load-bearing, not cosmetic.
T2_UNGUARDED_RC=0
"$BRIDGE_BASH_BIN" -c '
set -euo pipefail
_x="$(grep -E "^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=" "$1" \
  | head -n 1 \
  | sed -E "s/^.*=//")"
printf "reached:%s" "$_x"
' _ "$T2_NO_ADMIN" >/dev/null 2>&1 || T2_UNGUARDED_RC=$?
[[ "$T2_UNGUARDED_RC" -ne 0 ]] \
  || smoke_fail "T2: unguarded grep|head|sed pipeline unexpectedly survived a no-admin roster (guard is not load-bearing?)"

# ----------------------------------------------------------------------------
# T3 (end-to-end positive): the real script on a fresh admin-less
# BRIDGE_HOME must pass the admin-extraction block. With
# BRIDGE_WIKI_GRAPH_ENABLED unset on a fresh install the script
# short-circuits AFTER the admin block with the `wiki_graph_skipped=1`
# stdout marker and exit 0 — so reaching that marker proves the
# extraction block did not abort.
# ----------------------------------------------------------------------------
smoke_log "T3: bootstrap-memory-system.sh --apply on a no-admin roster reaches the wiki-graph gate (no abort)"

# smoke_setup_bridge_home already wrote empty roster files. Make the
# roster explicitly admin-less (declares agents but no admin id).
cat >"$BRIDGE_ROSTER_FILE" <<'ROSTER'
# admin-less roster: no BRIDGE_ADMIN_AGENT_ID line anywhere
BRIDGE_AGENT_IDS=(alpha beta)
ROSTER
: >"$BRIDGE_ROSTER_LOCAL_FILE"

T3_RC=0
T3_OUT="$(
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_WIKI_GRAPH_ENABLED="" \
    "$BRIDGE_BASH_BIN" "$BOOTSTRAP" --apply 2>&1
)" || T3_RC=$?
smoke_assert_eq "0" "$T3_RC" "T3: bootstrap on a no-admin roster must exit 0 (got rc=$T3_RC; out: $T3_OUT)"
smoke_assert_contains "$T3_OUT" "wiki_graph_skipped=1" \
  "T3: script must reach the wiki-graph default-off short-circuit (proves admin extraction did not abort)"

# ----------------------------------------------------------------------------
# T4 (regression guard): a roster that DOES declare BRIDGE_ADMIN_AGENT_ID
# still resolves it (the no-match guard must not swallow a real match).
# We assert against the extracted-pipeline shape rather than the full
# script so the test stays hermetic and order-independent.
# ----------------------------------------------------------------------------
smoke_log "T4: a roster that declares BRIDGE_ADMIN_AGENT_ID still resolves the admin (guard does not swallow a match)"

T4_ADMIN="$SMOKE_TMP_ROOT/t4-admin.sh"
cat >"$T4_ADMIN" <<'ROSTER'
export BRIDGE_ADMIN_AGENT_ID="myadmin"   # operator-chosen admin
BRIDGE_AGENT_IDS=(myadmin worker)
ROSTER

T4_RC=0
T4_OUT="$(
  set -euo pipefail
  { grep -E '^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=' "$T4_ADMIN" || true; } \
    | head -n 1 \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=//; s/^"([^"]*)".*/\1/; s/[[:space:]]*#.*$//'
)" || T4_RC=$?
smoke_assert_eq "0" "$T4_RC" "T4: guarded pipeline must succeed when an admin IS declared"
smoke_assert_eq "myadmin" "$T4_OUT" "T4: guarded pipeline must still extract the declared admin id"

smoke_log "PASS: #1399 admin-less roster is empty (not fatal) under set -euo pipefail"
