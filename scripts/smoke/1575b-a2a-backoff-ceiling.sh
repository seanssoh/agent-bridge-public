#!/usr/bin/env bash
# scripts/smoke/1575b-a2a-backoff-ceiling.sh — A2A delivery backoff ceiling
# cap smoke (#1575 Part B) plus the #1589/B8 Retry-After floor reconciliation.
#
# This smoke exercises the real source symbols through the helper. The intended
# split-cap contract is:
#   - our exponential backoff is capped by delivery_backoff_ceiling_seconds
#     (default 120);
#   - untrusted peer Retry-After is still a hard floor, but bounded by
#     delivery_max_retry_after_seconds (default 600);
#   - delivery_trust_peer_retry_after must be literal boolean true, and even the
#     trusted path is bounded by the 3600s sanity cap.

set -euo pipefail

SMOKE_NAME="1575b-a2a-backoff-ceiling"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/1575b-a2a-backoff-ceiling-helper.py"
WORK=""

cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd sqlite3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${SMOKE_NAME}.XXXXXX")"

schedule_delay() {
  local db="$1"
  shift
  python3 "$HELPER" schedule "$db" "$@" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["delay"])'
}

schedule_status() {
  local db="$1"
  shift
  python3 "$HELPER" schedule "$db" "$@" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])'
}

smoke_log "check #1: backoff_seconds(base=15) clamps at the ceiling"
smoke_assert_eq "$(python3 "$HELPER" backoff 1 120)" "15" "#1 attempt-1 = base 15"
smoke_assert_eq "$(python3 "$HELPER" backoff 2 120)" "30" "#1 attempt-2 = 30"
smoke_assert_eq "$(python3 "$HELPER" backoff 3 120)" "60" "#1 attempt-3 = 60"
smoke_assert_eq "$(python3 "$HELPER" backoff 4 120)" "120" "#1 attempt-4 clamps to 120"
smoke_assert_eq "$(python3 "$HELPER" backoff 8 120)" "120" "#1 TOOTH: attempt-8 clamped to 120"

smoke_log "check #2: config resolution (backoff ceiling + Retry-After max)"
smoke_assert_eq "$(python3 "$HELPER" ceiling '{}')" "120" "#2 default backoff ceiling is 120"
smoke_assert_eq "$(python3 "$HELPER" ceiling '{"delivery_backoff_ceiling_seconds": 300}')" \
  "300" "#2 ceiling config override honored"
env_val="$(BRIDGE_A2A_BACKOFF_CEILING_SECONDS=45 python3 "$HELPER" ceiling \
  '{"delivery_backoff_ceiling_seconds": 300}')"
smoke_assert_eq "$env_val" "45" "#2 ceiling env override wins over config"
smoke_assert_eq "$(python3 "$HELPER" ceiling '{"delivery_backoff_ceiling_seconds": 0}')" \
  "15" "#2 ceiling sub-floor clamps to base step"
smoke_assert_eq "$(python3 "$HELPER" ceiling '{"delivery_backoff_ceiling_seconds": "x"}')" \
  "120" "#2 non-numeric ceiling falls back to default"
smoke_assert_eq "$(python3 "$HELPER" max-ra '{}')" "600" "#2 default Retry-After max is 600"
smoke_assert_eq "$(python3 "$HELPER" max-ra '{"delivery_max_retry_after_seconds": 900}')" \
  "900" "#2 Retry-After max config override honored"
smoke_assert_eq "$(python3 "$HELPER" max-ra '{"delivery_max_retry_after_seconds": "x"}')" \
  "600" "#2 non-numeric Retry-After max falls back to default"

smoke_log "check #3: _schedule_retry caps our high-attempt exponential backoff"
for i in 1 2 3 4 5; do
  db="$WORK/s$i.db"
  status="$(schedule_status "$db" 10)"
  delay="$(sqlite3 "$db" "SELECT next_attempt_ts - 2000000000 FROM outbox WHERE message_id='m-1575b'")"
  smoke_assert_eq "$status" "retry" "#3 row scheduled for retry (iter $i)"
  [[ "$delay" -ge 1 && "$delay" -le 120 ]] \
    || smoke_fail "#3 TOOTH: delay $delay not in [1,120] (ceiling not applied?) iter $i"
  [[ "$delay" -ge 60 ]] \
    || smoke_fail "#3 jitter floor: delay $delay < 60 (full-jitter half-window broken) iter $i"
done

smoke_log "check #4: untrusted Retry-After is a hard floor capped separately at 600"
ra300_delay="$(schedule_delay "$WORK/ra300.db" 10 300)"
smoke_assert_eq "$ra300_delay" "300" "#4 B8: untrusted Retry-After=300 remains a floor"

ra700_delay="$(schedule_delay "$WORK/ra700.db" 10 700)"
smoke_assert_eq "$ra700_delay" "600" "#4 boundary: untrusted Retry-After=700 clamps to 600"

ra700_cfg_delay="$(schedule_delay "$WORK/ra700-cfg.db" 10 700 --config \
  '{"delivery_max_retry_after_seconds": 650}')"
smoke_assert_eq "$ra700_cfg_delay" "650" "#4 config: untrusted Retry-After cap can be raised"

smoke_log "check #5: non-finite Retry-After cannot crash or install a floor"
for bad_retry_after in inf Infinity 1e400 -inf; do
  out="$(python3 "$HELPER" schedule "$WORK/nonfinite-${bad_retry_after//[^A-Za-z0-9]/_}.db" \
    10 "$bad_retry_after")"
  status="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')"
  delay="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["delay"])')"
  smoke_assert_eq "$status" "retry" "#5 non-finite Retry-After still schedules retry: $bad_retry_after"
  [[ "$delay" -ge 1 && "$delay" -le 120 ]] \
    || smoke_fail "#5 non-finite Retry-After '$bad_retry_after' installed a floor or crashed (delay $delay)"
  [[ "$delay" -ge 60 ]] \
    || smoke_fail "#5 non-finite Retry-After '$bad_retry_after' bypassed expected jitter range (delay $delay)"
done

fraction_delay="$(schedule_delay "$WORK/fraction.db" 10 300.1)"
smoke_assert_eq "$fraction_delay" "301" "#5 fractional Retry-After is ceiled to preserve hard-floor semantics"

smoke_log "check #6: exact-bool trust gate + trusted sanity cap"
trust700_delay="$(schedule_delay "$WORK/trust700.db" 10 700 --config \
  '{"delivery_trust_peer_retry_after": true}')"
smoke_assert_eq "$trust700_delay" "700" "#6 trusted literal true honors Retry-After=700"

for cfg in '{"delivery_trust_peer_retry_after": "true"}' \
           '{"delivery_trust_peer_retry_after": 1}'; do
  db="$WORK/trust-string-$(printf '%s' "$cfg" | tr -cd '[:alnum:]').db"
  delay="$(schedule_delay "$db" 10 700 --config "$cfg")"
  smoke_assert_eq "$delay" "600" "#6 truthy non-bool trust value is not trusted: $cfg"
done

trust5000_delay="$(schedule_delay "$WORK/trust5000.db" 10 5000 --config \
  '{"delivery_trust_peer_retry_after": true}')"
smoke_assert_eq "$trust5000_delay" "3600" "#6 trusted Retry-After is sanity-capped at 3600"

smoke_log "all #1575/#1589 retry cap teeth passed"
