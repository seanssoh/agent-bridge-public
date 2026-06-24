#!/usr/bin/env bash
# scripts/smoke/16247-hostname-keying.sh — A2A DNS-`hostname` peer keying (#16247)
#
# Verifies the 4th peer-identity leg `hostname` (DNS A/AAAA):
#   - precedence node_id > tailscale_name > hostname > literal `address`
#   - the receiver source-address check accepts MEMBERSHIP in the peer's full
#     current A/AAAA set (multi-homed / round-robin safe) — NOT a single
#     string (the security heart: a valid non-first A-record is accepted)
#   - IPv4-mapped IPv6 (::ffff:v4) normalizes to the IPv4 client for compare
#   - fail-closed + BOUNDED (timeout) resolution; a short positive cache
#     serves a still-valid set across a transient DNS blip, but fail-closes
#     once the entry expires and DNS still cannot refresh; a lookup failure is
#     negatively cached (no resolver hammering before each 403)
#   - malformed `hostname` rejects (no `address` fallback); a routed transport
#     still rejects Tailscale identity keys; raw-IP peers are byte-unchanged
#
# Pure python3 + a monkeypatched `socket.getaddrinfo` — the real DNS is never
# touched (macOS-runnable, no BRIDGE_HOME needed; the helper loads
# bridge_a2a_common by path).
#
# Non-vacuous: a MUTATION run (BRIDGE_SMOKE_MUTATE=single_ip) collapses the
# receiver set to one IP — the pre-#16247 single-string check — and MUST fail
# the multi-A-non-first membership case.

set -euo pipefail

SMOKE_NAME="16247-hostname-keying"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/16247-hostname-keying-helper.py"

main() {
  smoke_require_cmd python3

  # 1. Every resolver / cache / source-check scenario must pass.
  local out
  if ! out="$(python3 "$HELPER" 2>&1)"; then
    smoke_log "$out"
    smoke_fail "hostname-keying helper reported a FAIL"
  fi

  # Assert each headline scenario is present + passing (guards a vacuous
  # all-skip — every name below must appear as PASS:<name>).
  local expect=(
    precedence_node_id_shadows sender_first_ip
    recv_multi_a_first recv_multi_a_nonfirst recv_off_set_rejected
    ipv4_mapped_norm malformed_hostname
    dotonly_sender_failclosed dotonly_recv_failclosed
    blank_hostname_uses_address whitespace_hostname_uses_address
    routed_rejects_tskey
    failclosed_first neg_cache_second cache_serves_on_blip
    failclosed_after_expiry bounded_timeout
    backcompat_raw_single backcompat_raw_set hostname_norm_cache_key
  )
  local name
  for name in "${expect[@]}"; do
    smoke_assert_contains "$out" "PASS:$name" "scenario $name"
  done

  # 2. Non-vacuous mutation: the single-string collapse MUST fail the
  #    multi-A-non-first membership case (and exit non-zero).
  local mout rc
  set +e
  mout="$(BRIDGE_SMOKE_MUTATE=single_ip python3 "$HELPER" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_log "$mout"
    smoke_fail "MUTATION (single_ip) did not fail — the smoke would be vacuous"
  fi
  smoke_assert_contains "$mout" "FAIL:recv_multi_a_nonfirst" \
    "mutation must break the multi-A non-first membership case"

  smoke_log "PASS"
}

main "$@"
