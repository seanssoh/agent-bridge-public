#!/usr/bin/env bash
# scripts/smoke/1563-pr8-a2a-diag-recovery.sh — A2A diagnostic + recovery
# hardening smoke (#1563 PR-8, rc2 A2A subtrack).
#
# Background (#1563 A2A subtrack): a 2026-06-06 ~1h A2A outage (patch <-> cm-prod)
# was prolonged by two BRIDGE defects — the death itself was environmental (a
# one-way tailnet dead path needing a re-handshake, NOT a receiver/protocol
# bug). The two defects this PR fixes:
#   #2 RECOVERY: backoff_seconds(base=15,ceiling=3600)+jitter -> an attempt-8..10
#      retry row waits 16-60 min; deliver only selects next_attempt_ts<=now, so
#      after the peer RECOVERED the rows sat dormant for tens of minutes.
#   #1 DIAGNOSIS: a bare "transport: timed out" told neither side which leg
#      failed -> both blamed the OTHER's receiver.
#
# This smoke pins the fix's teeth. Every assertion has a TOOTH (pre-PR-8 the
# relevant check FAILS):
#
#   #2 backoff recovery reset (probe-gated):
#     - a `status='retry'` row with next_attempt_ts>now + a peer TCP probe
#       SUCCESS -> the peer's retry rows reset to next_attempt_ts=0 (send-now);
#     - a peer whose TCP probe FAILS -> its retry row is NOT reset (backoff
#       preserved -> no thrash of an unreachable peer);  [TOOTH: remove the
#       probe-gate and the unreachable peer resets -> this check FAILS]
#     - a LEASED ('sending') row is NEVER reset;
#     - the transition gate: a sustained-ok peer does NOT reset every tick;
#     - --dry-run does NOT mutate.
#
#   #1 directional classification:
#     - healthz-OK + peer-TCP-FAIL -> peer_receiver_unreachable;
#     - healthz-OK + peer-TCP-FAIL + peer-tailnet-offline -> peer_tailnet_degraded;
#     - healthz-UNHEALTHY -> local_tailnet_degraded;
#     - tx==0/rx>0 asymmetry -> local_tailnet_degraded;
#     - none-conclusive -> transport_dead_path_unknown;  [TOOTH: a bare
#       transport-timeout with NO classification FAILS — the classifier must
#       always emit one of the four leg codes]
#
#   #3 actionable stuck-alert body: the daemon diag-lookup TSV carries
#      classification + tcp_probe + local_healthz + next_attempt_in_seconds +
#      backoff_reset + tcp_healthy_backoff_waiting, so the alert body can state
#      "TCP healthy but backoff-waiting".
#
#   #4 history preservation: the ack UPDATE PRESERVES last_error (not NULL) so
#      a post-mortem keeps the attempt trail. [TOOTH: the pre-PR-8 ack SQL
#      with `last_error=NULL` FAILS this check.]
#
# Probes use REAL loopback sockets (a reachable listener + a closed port) so no
# tailnet is needed. A2A smokes that need a REAL tailnet are out of scope here
# (skip-loud is the contract for those, but this smoke needs none).

set -euo pipefail

SMOKE_NAME="1563-pr8-a2a-diag-recovery"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/1563-pr8-a2a-diag-recovery-helper.py"
LISTEN_PID=""
WORK=""

cleanup() {
  if [[ -n "$LISTEN_PID" ]]; then
    kill "$LISTEN_PID" >/dev/null 2>&1 || true
    wait "$LISTEN_PID" >/dev/null 2>&1 || true
  fi
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT

smoke_require_cmd python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/${SMOKE_NAME}.XXXXXX")"
OUTBOX="$WORK/outbox.db"
LEDGER="$WORK/diag-ledger.json"
PORTFILE="$WORK/ok-port.txt"

# ---------------------------------------------------------------------------
# #1 + classifier unit teeth — deterministic, no sockets.
# ---------------------------------------------------------------------------
smoke_log "check #1: directional classifier maps each leg combination"

c="$(python3 "$HELPER" classify fail healthy none)"
smoke_assert_eq "$c" "peer_receiver_unreachable" "#1 healthz-OK + peer-TCP-FAIL"

c="$(python3 "$HELPER" classify fail healthy false)"
smoke_assert_eq "$c" "peer_tailnet_degraded" "#1 healthz-OK + peer-TCP-FAIL + peer-offline"

c="$(python3 "$HELPER" classify fail unhealthy none)"
smoke_assert_eq "$c" "local_tailnet_degraded" "#1 healthz-UNHEALTHY -> local"

c="$(python3 "$HELPER" classify fail none none)"
smoke_assert_eq "$c" "transport_dead_path_unknown" "#1 none-conclusive -> unknown"

c="$(python3 "$HELPER" classify ok none none)"
smoke_assert_eq "$c" "tcp_healthy_backoff_waiting" "#1 probe-OK -> backoff-waiting"

c="$(python3 "$HELPER" classify-asymmetry)"
smoke_assert_eq "$c" "local_tailnet_degraded" "#1 tx0/rx>0 asymmetry -> local"

# TOOTH: a classification must ALWAYS be one of the leg codes — never an empty
# / bare 'transport timeout'. Assert the output is non-empty + a known code.
case "$c" in
  peer_receiver_unreachable|local_tailnet_degraded|peer_tailnet_degraded|transport_dead_path_unknown|tcp_healthy_backoff_waiting) : ;;
  *) smoke_fail "#1 TOOTH: classifier emitted a non-leg code: '$c'" ;;
esac

# ---------------------------------------------------------------------------
# #2 backoff recovery reset — real loopback sockets.
# ---------------------------------------------------------------------------
smoke_log "check #2: probe-gated backoff reset (success->reset, fail->preserve, leased->never)"

# Start a loopback listener (reachable peer). Background it; helper writes port.
python3 "$HELPER" listen "$PORTFILE" &
LISTEN_PID=$!
# Wait for the port file.
for _ in $(seq 1 50); do [[ -s "$PORTFILE" ]] && break; sleep 0.1; done
[[ -s "$PORTFILE" ]] || smoke_fail "#2 listener did not publish a port"
OK_PORT="$(cat "$PORTFILE")"
CLOSED_PORT="$(python3 "$HELPER" free-port)"
[[ "$OK_PORT" =~ ^[0-9]+$ ]] || smoke_fail "#2 bad ok-port: $OK_PORT"
[[ "$CLOSED_PORT" =~ ^[0-9]+$ ]] || smoke_fail "#2 bad closed-port: $CLOSED_PORT"

CFG="$(python3 "$HELPER" build-outbox "$OUTBOX" "$OK_PORT" "$CLOSED_PORT")"
smoke_assert_file_exists "$CFG" "#2 config written"

# TICK 1: fresh ledger -> reachable is a probe-SUCCESS transition (reset),
# unreachable is probe-FAIL (preserved).
REPORT="$(python3 "$HELPER" reset-scenario "$OUTBOX" "$CFG" "$LEDGER")" \
  || smoke_fail "#2 reset-scenario tick1 failed"

reach_reset="$(printf '%s' "$REPORT" | python3 -c 'import sys,json; r={x["peer"]:x for x in json.load(sys.stdin)}; print(1 if r["reachable"]["backoff_reset"] else 0)')"
unreach_reset="$(printf '%s' "$REPORT" | python3 -c 'import sys,json; r={x["peer"]:x for x in json.load(sys.stdin)}; print(1 if r["unreachable"]["backoff_reset"] else 0)')"
reach_class="$(printf '%s' "$REPORT" | python3 -c 'import sys,json; r={x["peer"]:x for x in json.load(sys.stdin)}; print(r["reachable"]["classification"])')"
unreach_class="$(printf '%s' "$REPORT" | python3 -c 'import sys,json; r={x["peer"]:x for x in json.load(sys.stdin)}; print(r["unreachable"]["classification"])')"

smoke_assert_eq "$reach_reset" "1" "#2 reachable (TCP-OK) backoff RESET"
smoke_assert_eq "$unreach_reset" "0" "#2 unreachable (TCP-FAIL) backoff PRESERVED"
smoke_assert_eq "$reach_class" "tcp_healthy_backoff_waiting" "#2 reachable classified healthy/backoff-waiting"

# DB state teeth: reachable retry rows -> pending/0; leased untouched; unreach preserved.
ST="$(python3 "$HELPER" states "$OUTBOX")"
mr1="$(printf '%s' "$ST" | python3 -c 'import sys,json; print(json.load(sys.stdin)["m-reach-1"][0])')"
mr1n="$(printf '%s' "$ST" | python3 -c 'import sys,json; print(json.load(sys.stdin)["m-reach-1"][1])')"
ml="$(printf '%s' "$ST" | python3 -c 'import sys,json; print(json.load(sys.stdin)["m-reach-leased"][0])')"
mu="$(printf '%s' "$ST" | python3 -c 'import sys,json; print(json.load(sys.stdin)["m-unreach-1"][0])')"
smoke_assert_eq "$mr1" "pending" "#2 reachable retry row -> pending"
smoke_assert_eq "$mr1n" "0" "#2 reachable retry row -> next_attempt_ts=0 (send-now)"
smoke_assert_eq "$ml" "sending" "#2 TOOTH: LEASED row NEVER reset (still 'sending')"
smoke_assert_eq "$mu" "retry" "#2 TOOTH: unreachable peer NOT reset (still 'retry' = backoff preserved)"

# TICK 2 (transition gate): re-arm reachable to retry/future; a SUSTAINED-ok
# peer (prev='ok' in ledger) must NOT reset again -> no thrash loop.
python3 "$HELPER" rearm-retry "$OUTBOX"
REPORT2="$(python3 "$HELPER" reset-scenario "$OUTBOX" "$CFG" "$LEDGER")" \
  || smoke_fail "#2 reset-scenario tick2 failed"
reach_reset2="$(printf '%s' "$REPORT2" | python3 -c 'import sys,json; r={x["peer"]:x for x in json.load(sys.stdin)}; print(1 if r["reachable"]["backoff_reset"] else 0)')"
smoke_assert_eq "$reach_reset2" "0" "#2 transition gate: sustained-ok does NOT reset again"
ST2="$(python3 "$HELPER" states "$OUTBOX")"
mr1s2="$(printf '%s' "$ST2" | python3 -c 'import sys,json; print(json.load(sys.stdin)["m-reach-1"][0])')"
smoke_assert_eq "$mr1s2" "retry" "#2 transition gate: row stays 'retry' on a sustained-ok tick"

# DRY-RUN teeth: fresh ledger (transition) but --dry-run -> no SQL mutation.
rm -f "$LEDGER"
python3 "$HELPER" rearm-retry "$OUTBOX"
REPORT3="$(python3 "$HELPER" reset-scenario "$OUTBOX" "$CFG" "$LEDGER" --dry-run)" \
  || smoke_fail "#2 reset-scenario dry-run failed"
reach_reset3="$(printf '%s' "$REPORT3" | python3 -c 'import sys,json; r={x["peer"]:x for x in json.load(sys.stdin)}; print(1 if r["reachable"]["backoff_reset"] else 0)')"
smoke_assert_eq "$reach_reset3" "0" "#2 --dry-run reports no reset"
ST3="$(python3 "$HELPER" states "$OUTBOX")"
mr1s3="$(printf '%s' "$ST3" | python3 -c 'import sys,json; print(json.load(sys.stdin)["m-reach-1"][0])')"
smoke_assert_eq "$mr1s3" "retry" "#2 --dry-run did NOT mutate the row"

# TOOTH (codex r1): --dry-run must be ledger-READ-ONLY. A dry-run on a
# recovered peer must NOT consume the fail->ok transition — the SUBSEQUENT
# real run must STILL reset. (Pre-fix: dry-run stamped the ledger 'ok', so the
# real run saw prev=='ok' and skipped the reset -> rows stayed dormant.)
[[ -f "$LEDGER" ]] && smoke_fail "#2 TOOTH: --dry-run wrote the transition ledger (must be read-only)"
python3 "$HELPER" rearm-retry "$OUTBOX"
REPORT4="$(python3 "$HELPER" reset-scenario "$OUTBOX" "$CFG" "$LEDGER")" \
  || smoke_fail "#2 reset-scenario post-dry-run real run failed"
reach_reset4="$(printf '%s' "$REPORT4" | python3 -c 'import sys,json; r={x["peer"]:x for x in json.load(sys.stdin)}; print(1 if r["reachable"]["backoff_reset"] else 0)')"
smoke_assert_eq "$reach_reset4" "1" "#2 TOOTH: real run AFTER a dry-run STILL resets (dry-run did not poison the gate)"
ST4="$(python3 "$HELPER" states "$OUTBOX")"
mr1s4="$(printf '%s' "$ST4" | python3 -c 'import sys,json; print(json.load(sys.stdin)["m-reach-1"][0])')"
smoke_assert_eq "$mr1s4" "pending" "#2 TOOTH: post-dry-run real run actually reset the row"

# ---------------------------------------------------------------------------
# #3 actionable stuck-alert body — the daemon diag-lookup TSV.
# ---------------------------------------------------------------------------
smoke_log "check #3: daemon diag-lookup TSV carries the actionable alert fields"

# Re-arm + a real (non-dry) tick so the report has a reset row to look up.
rm -f "$LEDGER"
python3 "$HELPER" rearm-retry "$OUTBOX"
DIAG_JSON="$WORK/diag.json"
python3 "$HELPER" reset-scenario "$OUTBOX" "$CFG" "$LEDGER" >"$DIAG_JSON" \
  || smoke_fail "#3 reset-scenario for diag json failed"

TSV="$(python3 "$SMOKE_REPO_ROOT/bridge-daemon-helpers.py" a2a-diag-lookup reachable "$DIAG_JSON")"
[[ -n "$TSV" ]] || smoke_fail "#3 diag-lookup returned empty for a backoff-waiting peer"
IFS=$'\t' read -r d_class d_tcp d_healthz d_next d_reset d_tcp_healthy <<<"$TSV"
smoke_assert_eq "$d_class" "tcp_healthy_backoff_waiting" "#3 alert classification field"
smoke_assert_eq "$d_tcp" "ok" "#3 alert tcp_probe field"
smoke_assert_match "$d_next" '^[0-9]+$' "#3 alert next_attempt_in_seconds is numeric"
smoke_assert_eq "$d_tcp_healthy" "1" "#3 alert 'TCP healthy but backoff-waiting' flag"
smoke_assert_eq "$d_reset" "1" "#3 alert backoff_reset flag (this tick reset it)"

# diag-lookup for an absent peer -> empty (the alert falls back to un-enriched).
TSV_ABSENT="$(python3 "$SMOKE_REPO_ROOT/bridge-daemon-helpers.py" a2a-diag-lookup nope "$DIAG_JSON")"
smoke_assert_eq "$TSV_ABSENT" "" "#3 diag-lookup empty for a peer not in the report"

# ---------------------------------------------------------------------------
# #4 history preservation after ack.
# ---------------------------------------------------------------------------
smoke_log "check #4: ack PRESERVES last_error (attempt trail not NULL-wiped)"

ACK_DB="$WORK/ack.db"
ACK="$(python3 "$HELPER" ack-history "$ACK_DB")"
ack_status="$(printf '%s' "$ACK" | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')"
ack_err="$(printf '%s' "$ACK" | python3 -c 'import sys,json; v=json.load(sys.stdin)["last_error"]; print("" if v is None else v)')"
ack_remote="$(printf '%s' "$ACK" | python3 -c 'import sys,json; print(json.load(sys.stdin)["acked_remote_task_id"])')"
smoke_assert_eq "$ack_status" "acked" "#4 ack success semantics intact (status=acked)"
smoke_assert_eq "$ack_remote" "remote-123" "#4 ack remote task id recorded"
[[ -n "$ack_err" ]] || smoke_fail "#4 TOOTH: last_error was NULL-wiped on ack (history lost)"
smoke_assert_contains "$ack_err" "transport" "#4 attempt history (last_error) preserved on ack"

smoke_log "all PR-8 teeth passed"
