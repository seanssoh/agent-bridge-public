#!/usr/bin/env bash
# scripts/smoke/a2a-tailscale-identity-resolve.sh — A2A P0 runtime
# Tailscale-identity resolution smoke (A2A Setup Wizard design §8).
#
# Verifies that A2A peers + `listen` may carry an optional Tailscale
# identity (`tailscale_name` / `node_id`) that is resolved to the node's
# CURRENT TailscaleIP at use-time via `tailscale status --json`, with the
# legacy raw `address` as a back-compat fallback. Crucially it verifies the
# receiver bind PROOF is PRESERVED: resolution only produces a candidate,
# and the unchanged fail-closed proof (candidate ∈ `tailscale ip`) still
# rejects a resolved-but-not-local candidate.
#
# Uses a MOCK `tailscale` CLI (BRIDGE_A2A_TAILSCALE_CLI) — the real tailnet
# is never touched. macOS-runnable (pure python3 + a bash mock binary).
#
# Cases:
#   (a) resolve-by-tailscale_name (HostName + full MagicDNS) -> correct IP
#   (b) resolve-by-node_id (StableID)                        -> correct IP
#   (c) raw-address back-compat (no identity)                -> literal
#   (d) resolve-failure (identity not in status)             -> hard error
#   (e) bind proof REJECTS a resolved candidate NOT in `tailscale ip`  <-- security
#   (f) Tailscale unavailable + identity                     -> fail closed
#   (g) bind happy-path: identity resolves to an in-set IP   -> bind allowed
#   (h) legacy raw-address bind unchanged (in-set ok / out-of-set rejected)
#   (i) RECEIVER inbound source-address gate (do_POST):           <-- security
#       identity-only / identity-vs-stale peer resolves live; a request
#       from the resolved IP is ACCEPTED, the stale literal address is
#       NOT used (a request from it is REJECTED), and a resolver failure
#       FAILS CLOSED (rejects) — never falls through to accept.

set -euo pipefail

SMOKE_NAME="a2a-tailscale-identity-resolve"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/a2a-tailscale-identity-resolve-helper.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Mock `tailscale` whose `status --json` advertises a self node + one peer,
# and whose `ip` (the bind-proof source of truth) lists ONLY the self IP.
# self     : ID=selfStableID123  HostName=my-host       IP=100.83.90.26
# peer     : ID=peerStableID999  HostName=cm-prod-...    IP=100.76.208.4
write_mock_tailscale() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/tailscale" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "status" && "$2" == "--json" ]]; then
  cat <<'JSON'
{
  "Self": {
    "ID": "selfStableID123",
    "HostName": "my-host",
    "DNSName": "my-host.example-tailnet.ts.net.",
    "TailscaleIPs": ["100.83.90.26", "fd7a:115c:a1e0::1"],
    "Online": true, "OS": "linux"
  },
  "Peer": {
    "nodekey:abc": {
      "ID": "peerStableID999",
      "HostName": "cm-prod-agentworkflow-vm01",
      "DNSName": "cm-prod-agentworkflow-vm01.example-tailnet.ts.net.",
      "TailscaleIPs": ["100.76.208.4", "fd7a:115c:a1e0::2"],
      "Online": true, "OS": "linux"
    }
  }
}
JSON
  exit 0
fi
if [[ "$1" == "ip" ]]; then
  printf '100.83.90.26\nfd7a:115c:a1e0::1\n'
  exit 0
fi
echo "mock-tailscale: unsupported args: $*" >&2
exit 2
MOCK
  chmod +x "$dir/tailscale"
}

# Mock `tailscale` where `status --json` resolves Self to an IP that is NOT
# in the `ip` output — proves the bind proof rejects a resolved candidate
# that is not a real local Tailscale interface (case e).
write_mock_tailscale_mismatch() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/tailscale" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "status" && "$2" == "--json" ]]; then
  cat <<'JSON'
{
  "Self": {
    "ID": "selfStableID123",
    "HostName": "my-host",
    "DNSName": "my-host.example-tailnet.ts.net.",
    "TailscaleIPs": ["100.99.99.99"],
    "Online": true, "OS": "linux"
  },
  "Peer": {}
}
JSON
  exit 0
fi
if [[ "$1" == "ip" ]]; then
  printf '100.83.90.26\n'
  exit 0
fi
exit 2
MOCK
  chmod +x "$dir/tailscale"
}

_resolve() {
  BRIDGE_A2A_TAILSCALE_CLI="$MOCK_CLI" python3 "$HELPER" resolve "$1"
}
_bind() {
  BRIDGE_A2A_TAILSCALE_CLI="$MOCK_CLI" python3 "$HELPER" bind "$1"
}
# _recv_auth <client_ip> <peer-json> — drive do_POST's inbound source-address
# gate (resolve sender peer -> compare to request source -> fail closed).
_recv_auth() {
  BRIDGE_A2A_TAILSCALE_CLI="$MOCK_CLI" python3 "$HELPER" recv-auth "$1" "$2"
}

# --- (a) resolve-by-tailscale_name ---
case_a_name() {
  local got
  got="$(_resolve '{"tailscale_name":"cm-prod-agentworkflow-vm01","address":"9.9.9.9"}')"
  smoke_assert_eq "100.76.208.4" "$got" \
    "(a) tailscale_name (HostName) resolves to the peer's current IP, not the stale address"
  got="$(_resolve '{"tailscale_name":"cm-prod-agentworkflow-vm01.example-tailnet.ts.net"}')"
  smoke_assert_eq "100.76.208.4" "$got" \
    "(a) full MagicDNS name resolves to the peer's current IP"
}

# --- (b) resolve-by-node_id ---
case_b_node_id() {
  local got
  got="$(_resolve '{"node_id":"peerStableID999","address":"9.9.9.9"}')"
  smoke_assert_eq "100.76.208.4" "$got" \
    "(b) node_id (StableID) resolves to the peer's current IP, not the stale address"
  # Precedence: node_id wins over tailscale_name wins over address.
  got="$(_resolve '{"node_id":"peerStableID999","tailscale_name":"my-host","address":"9.9.9.9"}')"
  smoke_assert_eq "100.76.208.4" "$got" \
    "(b) node_id takes precedence over tailscale_name and address"
}

# --- (c) raw-address back-compat (no identity) ---
case_c_legacy() {
  local got
  got="$(_resolve '{"address":"100.64.0.20"}')"
  smoke_assert_eq "100.64.0.20" "$got" \
    "(c) no identity -> literal address returned (full back-compat)"
}

# --- (d) resolve-failure: identity not present in status -> hard error ---
case_d_resolve_failure() {
  local got
  got="$(_resolve '{"tailscale_name":"ghost-host","address":"9.9.9.9"}')"
  smoke_assert_eq "ERR:resolve_name_unknown" "$got" \
    "(d) unknown tailscale_name is a hard error — NO silent fallback to the stale address"
  smoke_assert_not_contains "$got" "9.9.9.9" \
    "(d) the stale address must not be returned when an identity fails to resolve"
  got="$(_resolve '{"node_id":"doesNotExist","address":"9.9.9.9"}')"
  smoke_assert_eq "ERR:resolve_node_id_unknown" "$got" \
    "(d) unknown node_id is a hard error — NO silent fallback to the stale address"
}

# --- (e) bind proof REJECTS a resolved candidate NOT in `tailscale ip` ---
# THE critical security assertion: resolution produces a candidate IP
# (100.99.99.99 from status --json), but the unchanged fail-closed proof
# refuses it because it is not in the real local `tailscale ip` set.
case_e_bind_proof_preserved() {
  local prev="$MOCK_CLI"
  MOCK_CLI="$MISMATCH_CLI"
  local got
  got="$(_bind '{"listen":{"node_id":"selfStableID123","port":8787},"peers":[]}')"
  MOCK_CLI="$prev"
  smoke_assert_eq "ERR:bind_not_tailnet" "$got" \
    "(e) SECURITY: a resolved candidate not in 'tailscale ip' is REJECTED — resolution did not weaken the bind proof"
}

# --- (f) Tailscale unavailable + identity -> fail closed ---
case_f_unavailable() {
  local got
  got="$(BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" \
    python3 "$HELPER" resolve '{"node_id":"x","address":"9.9.9.9"}')"
  smoke_assert_eq "ERR:tailscale_unavailable" "$got" \
    "(f) identity present + tailscale CLI absent -> fail closed (tailscale_unavailable)"
  # Legacy raw-address must still resolve even when Tailscale is unavailable.
  got="$(BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" \
    python3 "$HELPER" resolve '{"address":"100.64.0.7"}')"
  smoke_assert_eq "100.64.0.7" "$got" \
    "(f) legacy raw-address config resolves without needing Tailscale (back-compat)"
}

# --- (g) bind happy-path: identity resolves to an in-set IP -> allowed ---
case_g_bind_identity_ok() {
  local got
  got="$(_bind '{"listen":{"node_id":"selfStableID123","port":8787},"peers":[]}')"
  smoke_assert_eq "100.83.90.26:8787" "$got" \
    "(g) listen identity resolving to an in-set IP binds successfully"
}

# --- (h) legacy raw-address bind unchanged ---
case_h_bind_legacy_unchanged() {
  local got
  got="$(_bind '{"listen":{"address":"100.83.90.26","port":8787},"peers":[]}')"
  smoke_assert_eq "100.83.90.26:8787" "$got" \
    "(h) legacy raw-address listen in the set still binds (unchanged)"
  got="$(_bind '{"listen":{"address":"100.64.0.55","port":8787},"peers":[]}')"
  smoke_assert_eq "ERR:bind_not_tailnet" "$got" \
    "(h) legacy raw-address listen NOT in the set is still rejected (unchanged)"
}

# --- (i) RECEIVER inbound source-address gate (do_POST) ---
# THE inbound security assertion. The receiver must authenticate the source
# IP against the sender peer's CURRENT resolved Tailscale IP, not a stored
# literal. The mock resolves the peer to 100.76.208.4 while the config also
# carries a STALE literal address 9.9.9.9.
case_i_recv_source_auth() {
  local got
  # (i.1) identity-only peer (no literal address), request from the resolved
  #       IP -> ACCEPT. Proves identity-only inbound config is now usable.
  got="$(_recv_auth '100.76.208.4' '{"id":"cm-prod","tailscale_name":"cm-prod-agentworkflow-vm01"}')"
  smoke_assert_eq "ACCEPT" "$got" \
    "(i) identity-only peer: request from the resolved IP is accepted (identity-only inbound is usable)"

  # (i.2) identity resolves to X (100.76.208.4) while a STALE literal
  #       address Y (9.9.9.9) is also configured; request source == X -> ACCEPT.
  #       Proves the receiver uses the RESOLVED current IP, not the stale literal.
  got="$(_recv_auth '100.76.208.4' '{"id":"cm-prod","node_id":"peerStableID999","address":"9.9.9.9"}')"
  smoke_assert_eq "ACCEPT" "$got" \
    "(i) identity-vs-stale: request from the live-resolved IP is accepted (stale literal is NOT the anchor)"

  # (i.3) SECURITY: request from the STALE literal address (9.9.9.9) is
  #       REJECTED — the stale stored IP must never authenticate inbound.
  got="$(_recv_auth '9.9.9.9' '{"id":"cm-prod","node_id":"peerStableID999","address":"9.9.9.9"}')"
  smoke_assert_eq "REJECT:addr_mismatch" "$got" \
    "(i) SECURITY: request from the STALE literal address is rejected (inbound stale-IP class closed)"

  # (i.4) a request from an unrelated IP is REJECTED.
  got="$(_recv_auth '203.0.113.7' '{"id":"cm-prod","node_id":"peerStableID999"}')"
  smoke_assert_eq "REJECT:addr_mismatch" "$got" \
    "(i) request from an unrelated source IP is rejected"

  # (i.5) FAIL CLOSED: an identity that does not resolve -> REJECT (never
  #       falls through to accept, even though a stale literal == client_ip).
  got="$(_recv_auth '9.9.9.9' '{"id":"cm-prod","node_id":"doesNotExist","address":"9.9.9.9"}')"
  smoke_assert_eq "REJECT:resolve_node_id_unknown" "$got" \
    "(i) FAIL CLOSED: unresolvable identity rejects inbound even when the stale literal would match client_ip"

  # (i.6) FAIL CLOSED: Tailscale unavailable + identity -> REJECT.
  got="$(BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" \
    python3 "$HELPER" recv-auth '100.76.208.4' \
    '{"id":"cm-prod","node_id":"peerStableID999","address":"100.76.208.4"}')"
  smoke_assert_eq "REJECT:tailscale_unavailable" "$got" \
    "(i) FAIL CLOSED: Tailscale unavailable + identity rejects inbound (no fall-through to the literal)"

  # (i.7) legacy raw-address peer (no identity): request from the literal
  #       address is ACCEPTED, unchanged back-compat for the inbound gate.
  got="$(_recv_auth '100.64.0.20' '{"id":"legacy","address":"100.64.0.20"}')"
  smoke_assert_eq "ACCEPT" "$got" \
    "(i) legacy raw-address peer: inbound source-address gate unchanged (back-compat)"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"

  MOCK_DIR="$SMOKE_TMP_ROOT/mock-bin"
  MISMATCH_DIR="$SMOKE_TMP_ROOT/mock-bin-mismatch"
  write_mock_tailscale "$MOCK_DIR"
  write_mock_tailscale_mismatch "$MISMATCH_DIR"
  MOCK_CLI="$MOCK_DIR/tailscale"
  MISMATCH_CLI="$MISMATCH_DIR/tailscale"

  # Make sure no real loopback test-bind escape hatch is active for the
  # bind-proof cases (the proof must run for real).
  unset BRIDGE_A2A_ALLOW_TEST_BIND BRIDGE_A2A_DEV_INSECURE_BIND

  smoke_run "(a) resolve by tailscale_name"                 case_a_name
  smoke_run "(b) resolve by node_id"                        case_b_node_id
  smoke_run "(c) raw-address back-compat"                   case_c_legacy
  smoke_run "(d) resolve-failure is a hard error"           case_d_resolve_failure
  smoke_run "(e) bind proof preserved (security)"           case_e_bind_proof_preserved
  smoke_run "(f) tailscale unavailable -> fail closed"      case_f_unavailable
  smoke_run "(g) bind identity happy-path"                  case_g_bind_identity_ok
  smoke_run "(h) legacy raw-address bind unchanged"         case_h_bind_legacy_unchanged
  smoke_run "(i) receiver inbound source-auth (security)"   case_i_recv_source_auth

  smoke_log "PASS"
}

main "$@"
