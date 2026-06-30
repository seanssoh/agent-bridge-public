#!/usr/bin/env bash
# scripts/smoke/2211-apply-marker-resume.sh
#
# Issue #2211 — `agb upgrade --apply` is not atomic / not safely interruptible:
# the VERSION flip (apply-live) lands BEFORE the slow plugin `bun install`
# (~2min+), migrate, finalize, and daemon restart, so an interruption
# (SIGTERM/137/power-loss) mid-run leaves a partial-but-looks-upgraded install.
#
# Fix (codex design-ok #21241 + patch signoff #21247): option 3 (a DISTINCT
# strict-schema marker at state/upgrade/apply-in-progress.json + detect/warn) +
# a constrained option 2 (idempotent resume reusing the ORIGINAL backup_root +
# transaction id, skipping a fresh backup). NO apply-sequence reorder (option 1 /
# version-flip-last is deferred).
#
# This smoke exercises the SSOT (bridge-upgrade.py `apply-marker` verbs:
# write/clear/resolve/detect) + the doctor detector + the status warning + the
# shell wiring (marker write/advance/clear + resume-resolve sites in source
# order), all under an isolated $TMP — never touching live bridge state.
#
# Ten mutation-backed acceptance cases (§5 of the brief + the Phase-4 r1
# corrupt-complete-marker fail-closed hardening), each guarding a DISTINCT
# mutation: revert the guard and its case fails. No vacuous asserts.
#
# Footgun #11: no heredoc-fed subprocess — file-as-argv / direct python3 calls
# only. macOS Bash 3.2-safe (no associative arrays).

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
UPGRADE_SH="$ROOT_DIR/bridge-upgrade.sh"
UPGRADE_PY="$ROOT_DIR/bridge-upgrade.py"
DOCTOR_PY="$ROOT_DIR/bridge-doctor.py"
STATUS_PY="$ROOT_DIR/bridge-status.py"
RESOLVE_HELPER="$ROOT_DIR/lib/upgrade-helpers/apply-marker-resolve-fields.py"

for f in "$UPGRADE_SH" "$UPGRADE_PY" "$DOCTOR_PY" "$STATUS_PY" "$RESOLVE_HELPER"; do
  [[ -f "$f" ]] || { printf 'FAIL (bootstrap): missing %s\n' "$f" >&2; exit 2; }
done

PASS=0
FAIL=0
LAST_DESC=""
step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-2211-apply-marker.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

AM() { python3 "$UPGRADE_PY" apply-marker "$@"; }

# Read a top-level JSON field from a file/stdin without a parser dependency in
# the assertion (we DO use python3 for the decision JSON since it can nest).
jq_field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }
decision_of() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision",""))' 2>/dev/null; }
state_of()    { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))' 2>/dev/null; }

# A fully-populated target with a valid pre-upgrade backup (manifest + entries).
seed_target() {
  # $1=root $2=target_version
  local root="$1" tv="$2"
  mkdir -p "$root/state/upgrade" "$root/backups/upgrade-orig"
  printf '{"created_at":"x","target_root":"%s","source_head":"H","version":"%s","entries":[{"path":"VERSION","sha256":"a"}]}' "$root" "$tv" >"$root/backups/upgrade-orig/manifest.json"
}

# ---------------------------------------------------------------------------
# Case 1 — Interrupt after write-state, before bun install → the marker is
# present with the correct phase; VERSION-skew state is detectable.
# Mutation guarded: the write/phase wiring (revert the write verb → no marker).
# ---------------------------------------------------------------------------
printf '== Case 1 — marker present + correct phase after a write-state interrupt ==\n'
C1="$TMP/c1"; seed_target "$C1" "0.17.0"
AM --target-root "$C1" --op write --phase apply-live --transaction "txn1" \
  --target-version "0.17.0" --target-head "deadbeef0001" --installed-version "0.16.19" \
  --backup-enabled --backup-root "$C1/backups/upgrade-orig" --restart-daemon --restart-agents >/dev/null
# Advance to write-state (the 06-30 interrupt point is right after this).
AM --target-root "$C1" --op write --phase write-state >/dev/null
C1_MARKER="$C1/state/upgrade/apply-in-progress.json"

step "marker file exists after the interrupt"
if [[ -f "$C1_MARKER" ]]; then ok; else err "no marker at $C1_MARKER"; fi

step "marker phase advanced to write-state (the interrupt barrier)"
if [[ "$(jq_field "$C1_MARKER" phase)" == "write-state" ]]; then ok; else err "phase=$(jq_field "$C1_MARKER" phase)"; fi

step "marker preserves the ORIGINAL transaction across the advance"
if [[ "$(jq_field "$C1_MARKER" transaction)" == "txn1" ]]; then ok; else err "txn=$(jq_field "$C1_MARKER" transaction)"; fi

step "marker records installed≠target (version-skew is detectable)"
if [[ "$(jq_field "$C1_MARKER" installed_version)" == "0.16.19" && "$(jq_field "$C1_MARKER" target_version)" == "0.17.0" ]]; then ok; else err "installed=$(jq_field "$C1_MARKER" installed_version) target=$(jq_field "$C1_MARKER" target_version)"; fi

step "detect classifies it as interrupted (not clean)"
_d1="$(AM --target-root "$C1" --op detect)"
if [[ "$(state_of "$_d1")" == "interrupted" ]]; then ok; else err "detect state=$(state_of "$_d1")"; fi

# ---------------------------------------------------------------------------
# Case 2 — Warning: status + doctor surface the interrupted-apply warning + a
# recovery step. Mutation guarded: the detect→warning classification.
# ---------------------------------------------------------------------------
printf '== Case 2 — status + doctor surface the interrupted warning + recovery ==\n'
step "doctor emits an interrupted-apply finding with a recovery action"
_doc="$(python3 "$DOCTOR_PY" --state-dir "$C1/state" --detectors interrupted-apply --json --agent-list-json /dev/null 2>/dev/null)"
_doc_kind="$(printf '%s' "$_doc" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["kind"] if d else "")' 2>/dev/null)"
_doc_action="$(printf '%s' "$_doc" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["suggested_action"] if d else "")' 2>/dev/null)"
if [[ "$_doc_kind" == "interrupted-apply" ]] && printf '%s' "$_doc_action" | grep -q 'rollback'; then ok; else err "kind=$_doc_kind action=$_doc_action"; fi

step "status warning helper surfaces the interrupted-apply + recovery line"
_status_warn="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.interrupted_apply_warning(sys.argv[2]))
' "$STATUS_PY" "$C1/state" 2>/dev/null)"
case "$_status_warn" in
  *INTERRUPTED*rollback*|*INTERRUPTED*upgrade*) ok ;;
  *) err "status warning missing/incomplete: $_status_warn" ;;
esac

# ---------------------------------------------------------------------------
# Case 3 — Original-backup reuse: resume reuses the original backup_root + txn
# and does NOT request a fresh backup. Mutation guarded: the resume decision
# carrying backup_root/transaction.
# ---------------------------------------------------------------------------
printf '== Case 3 — resume reuses the original backup_root + transaction ==\n'
_r3="$(AM --target-root "$C1" --op resolve --target-version "0.17.0" --target-head "deadbeef0001")"
step "resolve decision == resume for the same target"
if [[ "$(decision_of "$_r3")" == "resume" ]]; then ok; else err "decision=$(decision_of "$_r3")"; fi

step "resume reuses the ORIGINAL backup_root (not a fresh one)"
_r3_backup="$(printf '%s' "$_r3" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("backup_root",""))')"
if [[ "$_r3_backup" == "$C1/backups/upgrade-orig" ]]; then ok; else err "resume backup_root=$_r3_backup"; fi

step "resume reuses the ORIGINAL transaction id"
_r3_txn="$(printf '%s' "$_r3" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("transaction",""))')"
if [[ "$_r3_txn" == "txn1" ]]; then ok; else err "resume txn=$_r3_txn"; fi

step "the shell gates fresh-backup creation on the resume-skip flag"
# The backup-live creation block must be guarded so a resume skips it.
if grep -q 'BACKUP -eq 1 && \$_BRIDGE_UPGRADE_RESUME_SKIP_BACKUP -eq 0' "$UPGRADE_SH"; then ok; else err "backup-live not gated on the resume-skip flag"; fi

# ---------------------------------------------------------------------------
# Case 4 — Rerun convergence: a re-run advancing to finalize then CLEAR
# converges to a clean state (apply marker cleared, complete marker durable).
# Mutation guarded: the clear-after-work-complete wiring.
# ---------------------------------------------------------------------------
printf '== Case 4 — rerun converges: finalize → work-complete → marker cleared ==\n'
# Drive the resumed apply forward to finalize, write the complete marker, clear.
AM --target-root "$C1" --op write --phase finalize >/dev/null
printf '{"phase":"work-complete","status":"ok","version":"0.17.0"}' >"$C1/state/upgrade/upgrade-complete.json"
AM --target-root "$C1" --op clear >/dev/null

step "apply-in-progress marker is cleared after work-complete"
if [[ ! -f "$C1_MARKER" ]]; then ok; else err "apply marker still present after clear"; fi

step "durable complete marker remains the success source of truth"
if [[ "$(jq_field "$C1/state/upgrade/upgrade-complete.json" status)" == "ok" ]]; then ok; else err "complete marker not ok"; fi

step "post-clear detect is clean"
if [[ "$(state_of "$(AM --target-root "$C1" --op detect)")" == "clean" ]]; then ok; else err "detect not clean after clear"; fi

step "the shell clears the apply marker right after the work-complete marker"
# The clear call must appear AFTER the #1662 work-complete END marker.
_wc_end="$(grep -n '^# END: Issue #1662 upgrade-complete marker + restart notice$' "$UPGRADE_SH" | head -n1 | cut -d: -f1)"
_clear_line="$(grep -n '_bridge_upgrade_apply_marker_clear$' "$UPGRADE_SH" | awk -F: -v m="$_wc_end" '$1 > m { print $1; exit }')"
if [[ -n "$_wc_end" && -n "$_clear_line" && "$_clear_line" -gt "$_wc_end" ]]; then ok; else err "clear (line ${_clear_line:-none}) not after work-complete END (line ${_wc_end:-none})"; fi

# ---------------------------------------------------------------------------
# Case 5 — Rollback to old VERSION: after an interrupted apply, a rollback
# clears the matching apply marker. Mutation guarded: the rollback marker-clear.
# ---------------------------------------------------------------------------
printf '== Case 5 — rollback clears the matching apply marker ==\n'
C5="$TMP/c5"; seed_target "$C5" "0.17.0"
AM --target-root "$C5" --op write --phase plugin-install --transaction "txn5" \
  --target-version "0.17.0" --installed-version "0.16.19" \
  --backup-enabled --backup-root "$C5/backups/upgrade-orig" --restart-daemon >/dev/null
# Simulate the rollback marker-clear (restored=true → clear --archive).
AM --target-root "$C5" --op clear --archive >/dev/null

step "rollback archived the apply marker (no live apply-in-progress remains)"
if [[ ! -f "$C5/state/upgrade/apply-in-progress.json" ]]; then ok; else err "apply marker still present after rollback clear"; fi

step "the archived marker is preserved for the audit trail"
if ls "$C5/state/upgrade/"apply-in-progress.*.archived.json >/dev/null 2>&1; then ok; else err "no archived marker file"; fi

step "the shell clears the apply marker on a restored rollback (gated, in the rollback block)"
# Prove the clear is GATED on restored=true AND lives inside the rollback block:
# the restored-gate line must precede the --op clear --archive within a small
# window AFTER the rollback ROLLBACK_JSON computation (not just both-exist-anywhere).
_rb_line="$(grep -n 'ROLLBACK_JSON="\$(python3' "$UPGRADE_SH" | head -n1 | cut -d: -f1)"
_gate_line="$(grep -n '"restored": true' "$UPGRADE_SH" | awk -F: -v m="$_rb_line" '$1 > m { print $1; exit }')"
_clear_line="$(grep -n -- '--op clear --archive' "$UPGRADE_SH" | awk -F: -v m="${_gate_line:-0}" '$1 > m { print $1; exit }')"
if [[ -n "$_rb_line" && -n "$_gate_line" && -n "$_clear_line" \
      && "$_gate_line" -gt "$_rb_line" && "$_clear_line" -gt "$_gate_line" \
      && $((_clear_line - _gate_line)) -le 4 ]]; then
  ok
else
  err "restored-gated clear not wired in the rollback block (rb=${_rb_line:-none} gate=${_gate_line:-none} clear=${_clear_line:-none})"
fi

# ---------------------------------------------------------------------------
# Case 6 — Strict-schema reject: a marker with an unknown key / malformed value
# is rejected (fail closed, no wrong resume).
# ★Mutation: drop the strict check → a malformed marker drives a resume.
# ---------------------------------------------------------------------------
printf '== Case 6 — strict-schema rejects a malformed marker (fail closed) ==\n'
C6="$TMP/c6"; seed_target "$C6" "0.17.0"
AM --target-root "$C6" --op write --phase write-state --transaction "txn6" \
  --target-version "0.17.0" --backup-root "$C6/backups/upgrade-orig" --restart-daemon >/dev/null
C6_MARKER="$C6/state/upgrade/apply-in-progress.json"
# Inject an UNKNOWN key into the otherwise-valid marker.
python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["EVIL_UNKNOWN_KEY"] = "x"
json.dump(d, open(p, "w"))
' "$C6_MARKER"

step "resolve of a marker with an unknown key fails closed (no resume)"
_r6="$(AM --target-root "$C6" --op resolve --target-version "0.17.0")"
if [[ "$(decision_of "$_r6")" == "fail-closed" ]]; then ok; else err "decision=$(decision_of "$_r6") (a malformed marker MUST NOT resume)"; fi

step "the fail-closed decision carries operator guidance"
_r6_guidance="$(printf '%s' "$_r6" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("guidance",""))')"
if [[ -n "$_r6_guidance" ]]; then ok; else err "no guidance on fail-closed"; fi

step "detect classifies the malformed marker as malformed (not interrupted/clean)"
if [[ "$(state_of "$(AM --target-root "$C6" --op detect)")" == "malformed" ]]; then ok; else err "detect did not flag malformed"; fi

step "status agrees with the SSOT — an unknown-key marker reads as MALFORMED (no drift)"
# Parity guard: status must NOT call the SSOT-malformed marker 'INTERRUPTED'.
_status6="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.interrupted_apply_warning(sys.argv[2]))
' "$STATUS_PY" "$C6/state" 2>/dev/null)"
case "$_status6" in
  *MALFORMED*) ok ;;
  *INTERRUPTED*) err "status called an SSOT-malformed marker INTERRUPTED (drift): $_status6" ;;
  *) err "status produced no/unknown warning for a malformed marker: $_status6" ;;
esac

step "a malformed value (wrong type) is ALSO rejected"
C6b="$TMP/c6b"; seed_target "$C6b" "0.17.0"
AM --target-root "$C6b" --op write --phase write-state --transaction "t" --target-version "0.17.0" --restart-daemon >/dev/null
python3 -c '
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["pid"] = "not-an-int"   # pid must be an int
json.dump(d, open(p, "w"))
' "$C6b/state/upgrade/apply-in-progress.json"
if [[ "$(decision_of "$(AM --target-root "$C6b" --op resolve --target-version "0.17.0")")" == "fail-closed" ]]; then ok; else err "wrong-typed pid was not rejected"; fi

# ---------------------------------------------------------------------------
# Case 7 — Different-target fail-closed: marker target ≠ requested target →
# fail closed with guidance, no resume.
# ---------------------------------------------------------------------------
printf '== Case 7 — different target fails closed (no cross-target resume) ==\n'
C7="$TMP/c7"; seed_target "$C7" "0.17.0"
AM --target-root "$C7" --op write --phase migrate --transaction "txn7" \
  --target-version "0.17.0" --target-head "aaaa11112222" --installed-version "0.16.19" \
  --backup-enabled --backup-root "$C7/backups/upgrade-orig" --restart-daemon >/dev/null

step "resolve with a DIFFERENT requested target fails closed"
_r7="$(AM --target-root "$C7" --op resolve --target-version "0.18.0" --target-head "ffff99998888")"
if [[ "$(decision_of "$_r7")" == "fail-closed" ]]; then ok; else err "decision=$(decision_of "$_r7")"; fi

step "the mismatch reason names both the marker target and the requested target"
_r7_reason="$(printf '%s' "$_r7" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))')"
if printf '%s' "$_r7_reason" | grep -q '0.17.0' && printf '%s' "$_r7_reason" | grep -q '0.18.0'; then ok; else err "reason=$_r7_reason"; fi

step "the SAME target still resolves to resume (mismatch guard is not over-broad)"
if [[ "$(decision_of "$(AM --target-root "$C7" --op resolve --target-version "0.17.0" --target-head "aaaa11112222")")" == "resume" ]]; then ok; else err "same-target no longer resumes (guard too broad)"; fi

# Case 7b — a FOREIGN target_root marker (copied/restored from another install)
# must fail closed even when version+head match. ★Mutation: drop the target_root
# equality gate → a foreign marker drives a resume off the wrong backup.
printf '== Case 7b — foreign target_root marker fails closed (same version+head) ==\n'
C7B="$TMP/c7b"; C7B_OTHER="$TMP/c7b-other"
mkdir -p "$C7B/state/upgrade" "$C7B_OTHER/backups/upgrade-orig"
printf '{"entries":[]}' >"$C7B_OTHER/backups/upgrade-orig/manifest.json"
# Write a marker whose recorded target_root is the OTHER install, then resolve
# against $C7B with the SAME version+head.
python3 -c '
import json, sys, os
this_root, other_root = sys.argv[1], sys.argv[2]
m = {
 "schema_version":1,"kind":"apply-in-progress","status":"in-progress","phase":"write-state",
 "transaction":"tf","pid":1,"psid":"","uid":"0","target_root":other_root,
 "installed_version":"0.16.19","target_version":"0.17.0","target_head":"aaaa11112222","target_ref":"",
 "source_head":"","source_ref":"","backup_enabled":True,"backup_root":other_root+"/backups/upgrade-orig",
 "restart_daemon":True,"restart_agents":False,"started_at":"x","updated_at":"x"}
json.dump(m, open(os.path.join(this_root,"state/upgrade/apply-in-progress.json"),"w"))
' "$C7B" "$C7B_OTHER"
step "resolve of a foreign-target_root marker (matching version+head) fails closed"
_r7b="$(AM --target-root "$C7B" --op resolve --target-version "0.17.0" --target-head "aaaa11112222")"
if [[ "$(decision_of "$_r7b")" == "fail-closed" ]]; then ok; else err "decision=$(decision_of "$_r7b") (a foreign target_root MUST NOT resume)"; fi
step "the foreign-marker reason names the target_root mismatch"
if printf '%s' "$_r7b" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' | grep -qi 'target_root'; then ok; else err "reason does not mention target_root"; fi

# Case 7c — the `restart` phase is NOT a valid marker phase (the enum stops at
# finalize; the marker is cleared before restart). Both the writer (argparse
# choices) and the strict validator must reject it. ★Mutation: add `restart`
# back to APPLY_MARKER_PHASES → an injected restart-phase marker resolves.
printf '== Case 7c — restart phase is rejected (enum stops at finalize) ==\n'
C7C="$TMP/c7c"; mkdir -p "$C7C/state/upgrade"
step "the writer rejects --phase restart (argparse choices exclude it)"
if AM --target-root "$C7C" --op write --phase restart >/dev/null 2>&1; then err "writer accepted --phase restart"; else ok; fi
step "an injected restart-phase marker is rejected by the strict validator"
printf '{"schema_version":1,"kind":"apply-in-progress","status":"in-progress","phase":"restart","transaction":"t","pid":1,"psid":"","uid":"0","target_root":"%s","installed_version":"0.16","target_version":"0.17","target_head":"","target_ref":"","source_head":"","source_ref":"","backup_enabled":false,"backup_root":"","restart_daemon":true,"restart_agents":true,"started_at":"x","updated_at":"x"}' "$C7C" >"$C7C/state/upgrade/apply-in-progress.json"
if [[ "$(decision_of "$(AM --target-root "$C7C" --op resolve --target-version "0.17")")" == "fail-closed" ]] && [[ "$(state_of "$(AM --target-root "$C7C" --op detect)")" == "malformed" ]]; then ok; else err "restart-phase marker was not rejected"; fi

# ---------------------------------------------------------------------------
# Case 8 — No-backup guidance: a backup-enabled marker with a missing/invalid
# backup_root → fail closed with the rollback/rerun guidance.
# ---------------------------------------------------------------------------
printf '== Case 8 — backup-enabled marker w/ invalid backup_root fails closed ==\n'
C8="$TMP/c8"; mkdir -p "$C8/state/upgrade"
# backup_enabled=true but the backup_root dir does not exist → no rollback point.
AM --target-root "$C8" --op write --phase plugin-install --transaction "txn8" \
  --target-version "0.17.0" --installed-version "0.16.19" \
  --backup-enabled --backup-root "$C8/backups/does-not-exist" --restart-daemon >/dev/null

step "resolve fails closed when a backup-enabled marker has no valid backup"
_r8="$(AM --target-root "$C8" --op resolve --target-version "0.17.0")"
if [[ "$(decision_of "$_r8")" == "fail-closed" ]]; then ok; else err "decision=$(decision_of "$_r8")"; fi

step "the guidance points at rollback / rerun-with-backup recovery"
_r8_guidance="$(printf '%s' "$_r8" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("guidance",""))')"
if printf '%s' "$_r8_guidance" | grep -qiE 'rollback|backup-root|no-backup'; then ok; else err "guidance=$_r8_guidance"; fi

step "a backup-enabled marker WITH a valid backup_root + manifest DOES resume"
C8b="$TMP/c8b"; seed_target "$C8b" "0.17.0"
AM --target-root "$C8b" --op write --phase plugin-install --transaction "t" \
  --target-version "0.17.0" --backup-enabled --backup-root "$C8b/backups/upgrade-orig" --restart-daemon >/dev/null
if [[ "$(decision_of "$(AM --target-root "$C8b" --op resolve --target-version "0.17.0")")" == "resume" ]]; then ok; else err "valid backup did not resume (guard too strict)"; fi

# ---------------------------------------------------------------------------
# Case 9 — Stale apply marker + matching complete marker → reconciled quietly
# (apply finished, clear didn't land) — NOT a scary warning, marker archived.
# ---------------------------------------------------------------------------
printf '== Case 9 — stale marker + matching complete marker reconciles quietly ==\n'
C9="$TMP/c9"; seed_target "$C9" "0.17.0"
AM --target-root "$C9" --op write --phase finalize --transaction "txn9" \
  --target-version "0.17.0" --backup-root "$C9/backups/upgrade-orig" --restart-daemon >/dev/null
# The apply ACTUALLY finished — a matching complete marker exists, the clear
# just didn't land (e.g. the session was SIGKILLed right after work-complete).
printf '{"phase":"work-complete","status":"ok","version":"0.17.0"}' >"$C9/state/upgrade/upgrade-complete.json"

step "resolve decision == reconcile-clear (apply finished; not a fail-closed)"
if [[ "$(decision_of "$(AM --target-root "$C9" --op resolve --target-version "0.17.0")")" == "reconcile-clear" ]]; then ok; else err "decision=$(decision_of "$(AM --target-root "$C9" --op resolve --target-version "0.17.0")")"; fi

step "detect classifies it as reconcile (quiet) — NOT interrupted"
if [[ "$(state_of "$(AM --target-root "$C9" --op detect)")" == "reconcile" ]]; then ok; else err "detect state != reconcile"; fi

step "doctor emits NO interrupted-apply finding for the reconcile case (stays quiet)"
_doc9="$(python3 "$DOCTOR_PY" --state-dir "$C9/state" --detectors interrupted-apply --json --agent-list-json /dev/null 2>/dev/null)"
_doc9_n="$(printf '%s' "$_doc9" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)"
if [[ "$_doc9_n" == "0" ]]; then ok; else err "doctor emitted $_doc9_n finding(s) for the reconcile case (should be quiet)"; fi

step "status stays quiet on the reconcile case (no scary warning)"
_status9="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(repr(m.interrupted_apply_warning(sys.argv[2])))
' "$STATUS_PY" "$C9/state" 2>/dev/null)"
if [[ "$_status9" == "''" ]]; then ok; else err "status warned on a reconcile case: $_status9"; fi

step "the reconcile archive clears the stale marker (quiet self-heal mutation)"
AM --target-root "$C9" --op clear --archive >/dev/null
if [[ ! -f "$C9/state/upgrade/apply-in-progress.json" ]] && ls "$C9/state/upgrade/"apply-in-progress.*.archived.json >/dev/null 2>&1; then ok; else err "reconcile did not archive the stale marker"; fi

# ---------------------------------------------------------------------------
# Case 10 — Corrupt complete marker must NOT fail OPEN (Phase-4 r1 fix).
# A VALID pending apply-in-progress.json + a CORRUPTED upgrade-complete.json:
#   (a) resolve must NOT rc=1 / traceback — it returns a real fail-closed
#       decision (resume, since the complete marker cannot corroborate done);
#   (b) the shell resume-resolution must NOT degrade a resolver failure to
#       {"decision":"none"} when the marker is present — it bridge_die's BEFORE
#       any mutation, so NO fresh backup overwrites the original rollback point;
#   (c) detect + doctor + status must NOT go silent — the pending marker is
#       surfaced as interrupted, not swallowed.
# Mutation-backed two ways:
#   * revert complete_marker_matches() to let the corrupt marker RAISE → (a)/(c) RED;
#   * revert the shell marker-presence gate (blanket none-fallback) → (b) RED.
# ---------------------------------------------------------------------------
printf '== Case 10 — corrupt complete marker does NOT fail open (rollback preserved) ==\n'
C10="$TMP/c10"; seed_target "$C10" "0.17.0"
AM --target-root "$C10" --op write --phase plugin-install --transaction "txn10" \
  --target-version "0.17.0" --target-head "deadbeef0010" --installed-version "0.16.19" \
  --backup-enabled --backup-root "$C10/backups/upgrade-orig" --restart-daemon --restart-agents >/dev/null
# The success marker is CORRUPT (truncated JSON) — it can neither be parsed nor
# trusted to corroborate completion.
printf '{"phase":"work-complete","status":"ok"' >"$C10/state/upgrade/upgrade-complete.json"

step "(a) resolve does NOT rc=1 on a corrupt complete marker (no traceback)"
_r10_out="$(AM --target-root "$C10" --op resolve --target-version "0.17.0" --target-head "deadbeef0010" 2>/dev/null)"
_r10_rc=$?
if [[ "$_r10_rc" -eq 0 ]]; then ok; else err "resolve rc=$_r10_rc (corrupt complete marker crashed the resolver)"; fi

step "(a) resolve fail-closes toward the pending marker (resume, NOT reconcile-clear)"
if [[ "$(decision_of "$_r10_out")" == "resume" ]]; then ok; else err "decision=$(decision_of "$_r10_out") (corrupt complete marker must not corroborate a clear)"; fi

step "(c) detect does NOT rc=1 and classifies interrupted (not swallowed)"
_d10_out="$(AM --target-root "$C10" --op detect 2>/dev/null)"
_d10_rc=$?
if [[ "$_d10_rc" -eq 0 && "$(state_of "$_d10_out")" == "interrupted" ]]; then ok; else err "detect rc=$_d10_rc state=$(state_of "$_d10_out")"; fi

step "(c) doctor surfaces the interrupted-apply finding (not silent)"
_doc10="$(python3 "$DOCTOR_PY" --state-dir "$C10/state" --detectors interrupted-apply --json --agent-list-json /dev/null 2>/dev/null)"
_doc10_kind="$(printf '%s' "$_doc10" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["kind"] if d else "")' 2>/dev/null)"
if [[ "$_doc10_kind" == "interrupted-apply" ]]; then ok; else err "doctor kind=$_doc10_kind (went silent on a corrupt complete marker)"; fi

step "(c) status surfaces the interrupted warning (not silent)"
_status10="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("bs", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.interrupted_apply_warning(sys.argv[2]))
' "$STATUS_PY" "$C10/state" 2>/dev/null)"
case "$_status10" in
  *INTERRUPTED*) ok ;;
  *) err "status went silent on a corrupt complete marker: $_status10" ;;
esac

# (b) The shell resume-resolution must FAIL CLOSED when the resolver process
# itself fails (rc≠0) AND the marker is present — bridge_die BEFORE any mutation,
# never the blanket {"decision":"none"} that would authorize a fresh backup. We
# drive the actual BEGIN/END resume-resolution block with bridge_die stubbed and
# a python3 stub that forces `apply-marker --op resolve` to rc=1 (the corrupt-
# marker failure mode), and assert it dies WITHOUT setting up a fresh backup.
_resume_block="$(sed -n '/^# BEGIN: Issue #2211 interrupted-apply resume resolution$/,/^# END: Issue #2211 interrupted-apply resume resolution$/p' "$UPGRADE_SH")"

step "(b) shell guard block is present in source (marker-presence gate to grep)"
if [[ -n "$_resume_block" ]] && printf '%s' "$_resume_block" | grep -q 'apply-in-progress.json'; then ok; else err "resume-resolution block missing the apply-marker-file gate"; fi

# Non-recursive python3 stub: force `--op resolve` to rc=1, pass everything else
# through to the real interpreter (so the resolve-fields helper still parses).
STUB10="$TMP/stub10"; mkdir -p "$STUB10"
_realpy="$(command -v python3)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [[ "$a" == "resolve" ]] && exit 1; done\n'
  printf 'exec %q "$@"\n' "$_realpy"
} >"$STUB10/python3"
chmod +x "$STUB10/python3"

run_resume_block() { # $1=marker-present(0/1)
  (
    set -uo pipefail
    export PATH="$STUB10:$PATH"
    SUBCOMMAND="apply"; DRY_RUN=0
    TARGET_ROOT="$C10"; SOURCE_VERSION="0.17.0"; TARGET_HEAD="deadbeef0010"
    SOURCE_ROOT="$ROOT_DIR"; BACKUP_ROOT="$C10/backups/upgrade-orig"
    bridge_die() { printf 'BRIDGE_DIE: %s\n' "$*"; exit 17; }
    _bridge_upgrade_apply_marker_clear() { :; }
    if [[ "$1" -eq 0 ]]; then rm -f "$C10/state/upgrade/apply-in-progress.json"; fi
    eval "$_resume_block"
    printf 'NO_DIE decision=%s skip_backup=%s\n' "${_resume_decision:-unset}" "${_BRIDGE_UPGRADE_RESUME_SKIP_BACKUP:-unset}"
  )
}

# Marker present + resolver rc=1 → MUST bridge_die before any mutation.
_present_out="$(run_resume_block 1 2>&1)"; _present_rc=$?
step "(b) marker present + resolver failure → bridge_die before any backup (fail closed)"
if [[ "$_present_rc" -eq 17 ]] && printf '%s' "$_present_out" | grep -q 'BRIDGE_DIE'; then ok; else err "did NOT die (rc=$_present_rc): $_present_out"; fi

step "(b) the fail-closed death authorizes NO fresh backup (rollback point preserved)"
if ! printf '%s' "$_present_out" | grep -q 'skip_backup'; then ok; else err "reached the skip_backup decision instead of dying: $_present_out"; fi

# Behavior-invariance counter-anchor: NO marker + resolver rc=1 → none rc=0, no die.
rm -f "$C10/state/upgrade/apply-in-progress.json"  # restore for a clean re-seed below
_absent_out="$(run_resume_block 0 2>&1)"; _absent_rc=$?
step "(b) invariant — NO marker + resolver failure → decision=none, no die (happy path intact)"
if [[ "$_absent_rc" -eq 0 ]] && printf '%s' "$_absent_out" | grep -q 'NO_DIE decision=none'; then ok; else err "no-marker path changed (rc=$_absent_rc): $_absent_out"; fi

# ---------------------------------------------------------------------------
# Behavior-invariance anchor — the marker write is purely ADDITIVE: it sits
# BEFORE apply-live (no reorder of the apply sequence). Guards the §3 signoff.
# ---------------------------------------------------------------------------
printf '== invariant — marker write precedes apply-live (no apply-sequence reorder) ==\n'
step "the first apply-marker write (apply-live phase) precedes the apply-live call"
_mwrite="$(grep -n '_bridge_upgrade_apply_marker_write apply-live' "$UPGRADE_SH" | head -n1 | cut -d: -f1)"
_applive="$(grep -n '^apply_args=(apply-live' "$UPGRADE_SH" | head -n1 | cut -d: -f1)"
if [[ -n "$_mwrite" && -n "$_applive" && "$_mwrite" -lt "$_applive" ]]; then ok; else err "marker write (line ${_mwrite:-none}) not before apply-live (line ${_applive:-none})"; fi

step "the resume resolution runs on the apply path BEFORE the first mutation"
if grep -q '# BEGIN: Issue #2211 interrupted-apply resume resolution' "$UPGRADE_SH"; then ok; else err "resume-resolution block missing"; fi

# ---------------------------------------------------------------------------
printf '\n== 2211-apply-marker-resume: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
