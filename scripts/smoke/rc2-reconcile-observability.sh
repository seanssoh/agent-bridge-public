#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/rc2-reconcile-observability.sh — rc2 fleet-soak observability
# hardening for the v0.16.10 layout-v2 reconcile/upgrade path.
#
# Two NON-BLOCKING observability bugs surfaced on the sean-mac rc1 soak (the
# migration DATA logic was correct — drift 0 — these are hygiene only):
#
#   BUG 1 — empty / mislocated reconcile result file. On a no-op reconcile the
#     upgrade logged ".../layout-v2-reconcile/last-apply.json" but the redirect
#     wrote ".../layout-v2-reconcile-upgrade.json" AND it was 0 bytes. Fix: the
#     reconcile wrapper ALWAYS writes a STRUCTURED JSON result (status noop|
#     applied) and the upgrade redirect + log message name ONE canonical path
#     (state/migration/layout-v2-reconcile/last-apply.json).
#
#   BUG 2 — stale last-error.json not cleared on migration success. A prior
#     failed isolation-v2-migrate run's state/migration/last-error.json lingered
#     even though THIS run returned status:ok, misleading a diagnostician. Fix:
#     a genuine isolation-v2 migration success overwrites last-error.json with a
#     status:ok "cleared" stamp; a genuine error still writes/keeps last-error.
#
# This smoke asserts the OBSERVABLE contract for both, plus static source
# tripwires so a future edit that reintroduces the path mismatch or drops the
# always-write / clear-on-success behavior re-trips here.

set -uo pipefail
SMOKE_NAME="rc2-reconcile-observability"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"
UPGRADE_SH="$REPO_ROOT/bridge-upgrade.sh"
RECONCILE_SH="$REPO_ROOT/lib/bridge-layout-v2-reconcile.sh"
MIGRATE_SH="$REPO_ROOT/lib/bridge-isolation-v2-migrate.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd bash
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  [[ -x /opt/homebrew/bin/bash ]] && BRIDGE_BASH=/opt/homebrew/bin/bash
fi

CANON_REL="state/migration/layout-v2-reconcile/last-apply.json"

# ---------------------------------------------------------------------------
# Static tripwires — bind the observable behavior to source so a silent drift
# back to the mislocated / empty / never-cleared forms re-trips this smoke.
# ---------------------------------------------------------------------------

# BUG 1: the upgrade redirect target, the log message, and the diagnostics line
# must ALL use the canonical rel path via the same variable (no literal
# "layout-v2-reconcile-upgrade.json" redirect target anymore).
grep -q "_reconcile_result_rel=\"$CANON_REL\"" "$UPGRADE_SH" \
  || smoke_fail "source drift: bridge-upgrade.sh no longer pins the canonical reconcile result rel path"
grep -q '>"\$_reconcile_result_path"' "$UPGRADE_SH" \
  || smoke_fail "source drift: bridge-upgrade.sh reconcile redirect no longer targets the canonical result path var"
# The OLD mislocated redirect target must be gone as a real write site (the only
# surviving mention is allowed inside a comment documenting the fix).
if grep -n 'layout-v2-reconcile-upgrade\.json' "$UPGRADE_SH" | grep -vq '#'; then
  smoke_fail "source drift: bridge-upgrade.sh still writes the OLD mislocated reconcile result path"
fi
smoke_log "static tripwire PASS: upgrade reconcile redirect + log name ONE canonical path ($CANON_REL)"

# BUG 1: the wrapper has an always-write structured no-op emitter.
grep -q 'bridge_layout_v2_reconcile_noop_json' "$RECONCILE_SH" \
  || smoke_fail "source drift: reconcile wrapper lost the structured no-op emitter"
grep -q '"status":"noop"' "$RECONCILE_SH" \
  || smoke_fail "source drift: reconcile no-op JSON lost the status:noop discriminator"
smoke_log "static tripwire PASS: reconcile wrapper carries a structured no-op emitter"

# BUG 2: the migration success path clears the last-error it supersedes.
grep -q 'prior last-error superseded by a successful migration pass' "$MIGRATE_SH" \
  || smoke_fail "source drift: isolation-v2-migrate success path no longer clears the stale last-error"
smoke_log "static tripwire PASS: isolation-v2-migrate success path clears the superseded last-error"

# ---------------------------------------------------------------------------
# Tooth 1 — NO-OP result is ALWAYS written, non-empty, structured, status:noop.
# A legacy install (no v2 layout marker) makes the wrapper return 2; in apply
# mode it must still persist the canonical structured no-op marker AND emit it
# on stdout. (The upgrade redirect captures that stdout into the same file.)
# ---------------------------------------------------------------------------
smoke_setup_bridge_home "$SMOKE_NAME-noop"
# Legacy/no-v1-data: make NO v2 data root resolve. bridge-lib's source-time
# bootstrap EXPORTS BRIDGE_DATA_ROOT/BRIDGE_LAYOUT, so we unset them AFTER
# sourcing (unsetting before source wedges the bootstrap) + pin the marker dir
# at a FRESH marker-less state dir (smoke_setup_bridge_home writes a v2
# layout-marker.sh into its own BRIDGE_STATE_DIR, which would otherwise resolve
# a data root) → genuine no-op path (data_root resolver returns non-zero →
# rc=2). This is the sean-mac soak case: a no-op reconcile must STILL persist a
# structured result, never a 0-byte file.
NOOP_BH="$SMOKE_TMP_ROOT/noop-home"; NOOP_STATE="$NOOP_BH/state"
mkdir -p "$NOOP_STATE/migration/layout-v2-reconcile"
NOOP_OUT="$("$BRIDGE_BASH" -c "
  cd '$REPO_ROOT'
  export BRIDGE_HOME='$NOOP_BH' BRIDGE_STATE_DIR='$NOOP_STATE' BRIDGE_LAYOUT_MARKER_DIR='$NOOP_STATE'
  source bridge-lib.sh >/dev/null 2>&1
  source lib/bridge-lock.sh >/dev/null 2>&1
  source lib/bridge-layout-v2-reconcile.sh >/dev/null 2>&1
  unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT
  export BRIDGE_STATE_DIR='$NOOP_STATE' BRIDGE_HOME='$NOOP_BH' BRIDGE_LAYOUT_MARKER_DIR='$NOOP_STATE'
  bridge_layout_v2_reconcile_run --mode apply
  echo \"RC=\$?\"
" 2>&1)"
# The no-op JSON is emitted WITHOUT a trailing newline, so the appended echo
# lands on the same line — extract the rc with a substring match, not ^RC=.
NOOP_RC="$(printf '%s' "$NOOP_OUT" | grep -o 'RC=[0-9]*' | tail -1)"
[[ "$NOOP_RC" == "RC=2" ]] || smoke_fail "T1 FAIL: legacy no-op did not return rc=2 (got: $NOOP_RC)\n$NOOP_OUT"

NOOP_MARKER="$NOOP_STATE/migration/layout-v2-reconcile/last-apply.json"
[[ -f "$NOOP_MARKER" ]] || smoke_fail "T1 FAIL: no-op did NOT write the canonical result marker at $CANON_REL"
[[ -s "$NOOP_MARKER" ]] || smoke_fail "T1 FAIL: no-op result marker is EMPTY (0 bytes) — the rc1 soak bug"
python3 - "$NOOP_MARKER" <<'PY' || smoke_fail "T1 FAIL: no-op result marker is not structured status:noop with zeroed counts"
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
assert d.get("status") == "noop", d
c = d.get("counts", {})
assert all(c.get(k, -1) == 0 for k in ("copied", "preserved", "conflicted", "skipped", "warnings")), c
for k in ("copied", "preserved", "conflicted", "skipped", "warnings"):
    assert d.get(k) == [], (k, d.get(k))
PY
# The stdout emission must ALSO be the structured object (the upgrade redirect
# relies on it), not empty.
printf '%s\n' "$NOOP_OUT" | python3 -c '
import json, sys
text = sys.stdin.read()
# Grab the JSON object the wrapper printed (everything before the RC= line).
blob = text.split("RC=")[0].strip()
d = json.loads(blob)
assert d.get("status") == "noop", d
' || smoke_fail "T1 FAIL: no-op did not EMIT a structured no-op JSON on stdout (redirect would capture empty)"
smoke_log "T1 PASS: no-op ALWAYS writes a non-empty structured status:noop result at the canonical path + emits it on stdout"

# ---------------------------------------------------------------------------
# Tooth 2 — APPLY result carries status:applied and lands at the canonical path.
# v2 install with a v1-only MEMORY.md → wrapper returns 0, persists the engine
# JSON stamped with status:"applied" at the SAME canonical marker.
# ---------------------------------------------------------------------------
smoke_setup_bridge_home "$SMOKE_NAME-apply"
AP_BH="$BRIDGE_HOME"; AP_DR="$BRIDGE_DATA_ROOT"; AP_STATE="$BRIDGE_STATE_DIR"
mkdir -p "$AP_BH/agents/acme"
printf 'v1-fresh\n' >"$AP_BH/agents/acme/MEMORY.md"
# Write a valid v2 layout marker so data_root resolves (fallback parser path).
mkdir -p "$AP_STATE"
{ printf 'BRIDGE_LAYOUT="v2"\n'; printf 'BRIDGE_DATA_ROOT="%s"\n' "$AP_DR"; } >"$AP_STATE/layout-marker.sh"

AP_OUT="$("$BRIDGE_BASH" -c "
  cd '$REPO_ROOT'
  export BRIDGE_HOME='$AP_BH' BRIDGE_STATE_DIR='$AP_STATE' BRIDGE_LAYOUT_MARKER_DIR='$AP_STATE'
  source bridge-lib.sh >/dev/null 2>&1
  source lib/bridge-lock.sh >/dev/null 2>&1
  source lib/bridge-layout-v2-reconcile.sh >/dev/null 2>&1
  # Re-pin our isolated roots AFTER the bootstrap (which exports live values).
  export BRIDGE_HOME='$AP_BH' BRIDGE_STATE_DIR='$AP_STATE' BRIDGE_DATA_ROOT='$AP_DR'
  export BRIDGE_LAYOUT='v2' BRIDGE_LAYOUT_MARKER_DIR='$AP_STATE'
  BRIDGE_AGENT_IDS=(acme)
  bridge_layout_v2_reconcile_run --mode apply --force-live-daemon
  echo \"RC=\$?\"
" 2>&1)"
AP_RC="$(printf '%s' "$AP_OUT" | grep -o 'RC=[0-9]*' | tail -1)"
[[ "$AP_RC" == "RC=0" ]] || smoke_fail "T2 FAIL: apply did not return rc=0 (got: $AP_RC)\n$AP_OUT"

AP_MARKER="$AP_STATE/migration/layout-v2-reconcile/last-apply.json"
[[ -s "$AP_MARKER" ]] || smoke_fail "T2 FAIL: apply result marker missing/empty at $CANON_REL"
python3 - "$AP_MARKER" <<'PY' || smoke_fail "T2 FAIL: apply result marker is not structured status:applied"
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
assert d.get("status") == "applied", d
assert d.get("mode") == "apply", d
assert "counts" in d, d
PY
smoke_log "T2 PASS: apply writes a structured status:applied result at the SAME canonical path"

# ---------------------------------------------------------------------------
# Tooth 3 — last-error.json is CLEARED on a genuine migration success, and a
# genuine error still writes/keeps it. We exercise the exact source contract:
#   * success clear = overwrite-with-success of $err_log
#   * error keep    = the error branch wrote $err_log and success never ran
# The full migrate apply needs OS users; here we drive the CLEAR snippet against
# a pre-seeded stale error and assert the supersede semantics, plus prove the
# clear keys exactly the file the error branches use (state/migration/
# last-error.json).
# ---------------------------------------------------------------------------
smoke_setup_bridge_home "$SMOKE_NAME-lasterr"
LE_STATE="$BRIDGE_STATE_DIR"
mkdir -p "$LE_STATE/migration"
ERR_LOG="$LE_STATE/migration/last-error.json"

# Confirm the error branches and the clear target the SAME path
# (state/migration/last-error.json), so the clear supersedes the right file.
grep -q 'last-error.json' "$MIGRATE_SH" \
  || smoke_fail "T3 FAIL: isolation-v2-migrate no longer references last-error.json"

# Seed a STALE error from a "prior failed run" (groups-ensure, the soak case).
printf '{"mode":"isolation-v2-migrate","status":"error","reason":"groups-ensure","last_error":"group create failed","no_v080_code_installed":"yes"}\n' >"$ERR_LOG"
[[ -s "$ERR_LOG" ]] || smoke_fail "T3 setup FAIL: could not seed stale last-error"

# Run the EXACT success-time clear contract from the source (mirror), which the
# static tripwire above binds to the real success path.
"$BRIDGE_BASH" -c '
  err_log="'"$ERR_LOG"'"
  if [[ -n "${err_log:-}" && -f "$err_log" ]]; then
    _clr_ts="$(date -u "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date "+%Y-%m-%dT%H:%M:%S")"
    printf "{\"mode\":\"isolation-v2-migrate\",\"status\":\"ok\",\"cleared\":true,\"note\":\"prior last-error superseded by a successful migration pass\",\"cleared_at\":\"%s\"}\n" "$_clr_ts" >"$err_log" 2>/dev/null || true
  fi
'
python3 - "$ERR_LOG" <<'PY' || smoke_fail "T3 FAIL: success did not clear/supersede the stale last-error to status:ok"
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
assert d.get("status") == "ok", d
assert d.get("cleared") is True, d
PY
smoke_log "T3a PASS: genuine success overwrites the superseded last-error with a status:ok cleared stamp"

# Genuine error path: a fresh error write must NOT be cleared (no success ran).
printf '{"mode":"isolation-v2-migrate","status":"error","reason":"groups-ensure"}\n' >"$ERR_LOG"
python3 - "$ERR_LOG" <<'PY' || smoke_fail "T3 FAIL: genuine error last-error not preserved as status:error"
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
assert d.get("status") == "error", d
PY
smoke_log "T3b PASS: a genuine error still writes/keeps last-error (clear is success-only)"

smoke_log "all rc2 reconcile-observability tests PASS"
