#!/usr/bin/env bash
# scripts/smoke/1575b-a2a-backoff-ceiling.sh — A2A delivery backoff ceiling
# cap smoke (#1575 Part B).
#
# Background (#1575): on a 2026-06-06 transient tailnet/DERP break, three
# crm-dev->patch outbound A2A messages stalled on attempts 7-9 with backoff
# `next=13m`. The exponential backoff used `backoff_seconds(base=15,
# ceiling=3600)`, so a high-attempt retry row idled 16-60 min — even once the
# peer recovered, each message waited out its long backoff (the operator had
# to `agb a2a outbox retry <id>` by hand). Part B caps the ceiling to 120s
# (config/env tunable) so worst-case dormancy is ~1-2 min, complementing the
# rc2 #1582 probe-gated reset from the other side.
#
# This smoke exercises the REAL source symbols (helper imports
# bridge_a2a_common + bridge-a2a.py — no re-implementation). Each assertion
# has a TOOTH (the pre-Part-B code FAILS it):
#
#   #1 backoff_seconds curve clamps at the configured ceiling (base 15 kept).
#      TOOTH: pre-Part-B default ceiling was 3600 -> attempt-8 would be 1920.
#   #2 delivery_backoff_ceiling(cfg) precedence: default 120, config override,
#      env override wins over config, sub-floor clamped to the 15s floor.
#      TOOTH: no knob existed pre-Part-B.
#   #3 _schedule_retry end-to-end: a high-attempt retry row's next_attempt
#      delay is <= ceiling + jitter (and jitter keeps it > ceiling/2).
#      TOOTH: pre-Part-B this row would land at ~16-60 min.
#   #4 an untrusted large Retry-After is clamped to the ceiling by default,
#      but honored verbatim when delivery_trust_peer_retry_after=true.
#      TOOTH: pre-Part-B `max(delay, Retry-After)` honored any value -> a
#      transient/spoofed 503 could re-impose a multi-minute backoff.
#
# No tailnet / sockets needed — this is the sender-side scheduling math only.

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
WORK="$(mktemp -d "${TMPDIR:-/tmp}/${SMOKE_NAME}.XXXXXX")"

# ---------------------------------------------------------------------------
# #1 backoff_seconds curve clamps at the configured ceiling.
# ---------------------------------------------------------------------------
smoke_log "check #1: backoff_seconds(base=15) clamps at the ceiling"

smoke_assert_eq "$(python3 "$HELPER" backoff 1 120)" "15" "#1 attempt-1 = base 15"
smoke_assert_eq "$(python3 "$HELPER" backoff 2 120)" "30" "#1 attempt-2 = 30"
smoke_assert_eq "$(python3 "$HELPER" backoff 3 120)" "60" "#1 attempt-3 = 60"
smoke_assert_eq "$(python3 "$HELPER" backoff 4 120)" "120" "#1 attempt-4 clamps to ceiling 120"
# TOOTH: attempt-8 would be 15*2^7 = 1920 if not clamped (pre-Part-B 3600
# ceiling let it through). With a 120 ceiling it MUST be 120.
smoke_assert_eq "$(python3 "$HELPER" backoff 8 120)" "120" "#1 TOOTH: attempt-8 clamped to 120 (not 1920)"

# ---------------------------------------------------------------------------
# #2 delivery_backoff_ceiling(cfg) precedence + floor.
# ---------------------------------------------------------------------------
smoke_log "check #2: ceiling resolution (default/config/env/floor)"

smoke_assert_eq "$(python3 "$HELPER" ceiling '{}')" "120" "#2 default ceiling is 120"
smoke_assert_eq "$(python3 "$HELPER" ceiling '{"delivery_backoff_ceiling_seconds": 300}')" \
  "300" "#2 config override honored"
# Env override wins over config.
env_val="$(BRIDGE_A2A_BACKOFF_CEILING_SECONDS=45 python3 "$HELPER" ceiling \
  '{"delivery_backoff_ceiling_seconds": 300}')"
smoke_assert_eq "$env_val" "45" "#2 env override wins over config"
# Sub-floor / garbage clamps to the 15s floor (must never wedge the loop).
smoke_assert_eq "$(python3 "$HELPER" ceiling '{"delivery_backoff_ceiling_seconds": 0}')" \
  "15" "#2 sub-floor 0 clamps to the 15s floor"
smoke_assert_eq "$(python3 "$HELPER" ceiling '{"delivery_backoff_ceiling_seconds": "x"}')" \
  "120" "#2 non-numeric falls back to default (no raise)"

# ---------------------------------------------------------------------------
# #3 _schedule_retry end-to-end: delay <= ceiling + jitter.
# ---------------------------------------------------------------------------
smoke_log "check #3: _schedule_retry clamps a high-attempt row to ceiling+jitter"

for i in 1 2 3 4 5; do
  out="$(python3 "$HELPER" schedule "$WORK/s$i.db" 10)"
  status="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')"
  delay="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["delay"])')"
  smoke_assert_eq "$status" "retry" "#3 row scheduled for retry (iter $i)"
  # Full jitter is delay*(0.5..1.0): with ceiling 120 the result is in
  # [60, 120]. TOOTH: pre-Part-B this attempt-10 row would be ~3600s.
  [[ "$delay" -ge 1 && "$delay" -le 120 ]] \
    || smoke_fail "#3 TOOTH: delay $delay not in [1,120] (ceiling not applied?) iter $i"
  [[ "$delay" -ge 60 ]] \
    || smoke_fail "#3 jitter floor: delay $delay < 60 (full-jitter half-window broken) iter $i"
done

# ---------------------------------------------------------------------------
# #4 Retry-After clamp (default) vs trusted (opt-in).
# ---------------------------------------------------------------------------
smoke_log "check #4: untrusted Retry-After clamped to ceiling; trusted honored"

# Default: a 3600s Retry-After must be clamped to <= ceiling (then jittered).
out="$(python3 "$HELPER" schedule "$WORK/ra1.db" 10 3600)"
ra_delay="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["delay"])')"
[[ "$ra_delay" -ge 1 && "$ra_delay" -le 120 ]] \
  || smoke_fail "#4 TOOTH: untrusted Retry-After 3600 not clamped (delay $ra_delay > 120)"

# Opt-in trust: the SAME 3600 Retry-After is honored verbatim (> ceiling).
out="$(python3 "$HELPER" schedule "$WORK/ra2.db" 10 3600 --config '{"delivery_trust_peer_retry_after": true}')"
trust_delay="$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.load(sys.stdin)["delay"])')"
[[ "$trust_delay" -gt 120 ]] \
  || smoke_fail "#4 trusted Retry-After not honored (delay $trust_delay <= 120)"

smoke_log "all #1575 Part B teeth passed"
