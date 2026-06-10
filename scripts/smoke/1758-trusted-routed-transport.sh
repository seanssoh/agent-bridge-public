#!/usr/bin/env bash
# scripts/smoke/1758-trusted-routed-transport.sh — A2A trusted-routed transport
# smoke (#1758).
#
# Exercises the new `transport.kind: trusted-routed` end-to-end against an
# isolated env. The trusted-routed bind proof is the interface-assignment HALF
# of the WARP-Mesh proof with the WARP/Tailscale enrollment half DROPPED — for
# a private IP on a trusted, router-protected corporate network where no
# overlay client is present. The local-interface set is MOCKED via the probe
# seam (BRIDGE_A2A_IFACE_ADDRS) so the proof runs its REAL code path with no
# real WARP/Tailscale install. Covers:
#   (a) trusted-routed happy path — the bind IP is assigned to a local
#       interface, NO WARP present -> preflight OK (bind proof), and a live
#       loopback receiver delivers a signed handoff -> 200 + local inbox.
#   (b) loopback / wildcard / CIDR-only-guess (not on a local interface) binds
#       are STILL refused fail-closed.
#   (c) an unknown / typo transport.kind STILL hard-fails (no default-allow).
#   (d) auth invariants UNCHANGED under the new kind: bad HMAC -> 401,
#       source-address mismatch -> 403, inbound_allowlist enforced, and
#       room-scoped delivery still routes through room_scoped_check (403).
#   (e) sender source symmetry (#1758): a warp-mesh peer egresses from the
#       node's own Mesh listen.address; a trusted-routed peer gets None so the
#       OS routing table picks the reachable egress source.
#   (f) NO weakening: a `cloudflare-warp-mesh` config WITHOUT WARP still fails
#       closed (the enrollment proof is dropped ONLY for trusted-routed).
#
# macOS: run with /opt/homebrew/bin/bash (bash 5.x).

set -euo pipefail

SMOKE_NAME="1758-trusted-routed-transport"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HANDOFFD_PID=""
REVIEWER_SESSION=""

cleanup() {
  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$REVIEWER_SESSION" ]]; then
    tmux kill-session -t "=${REVIEWER_SESSION}" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

A2A_PORT=""
A2A_SECRET="tr-smoke-shared-secret-do-not-use-in-prod-0123456789"
# A routed private IP used for the bind-proof preflight cases. It is never
# actually bound (preflight only validates); the mock iface probe decides
# whether the interface-assignment proof passes.
ROUTED_IP="10.21.2.4"
LAN_IP="10.11.10.211"
REVIEWER_SESSION_NAME="tr-smoke-reviewer-$$-${RANDOM}"

helper() {
  python3 "$SCRIPT_DIR/1758-trusted-routed-transport-helper.py" "$@"
}

pick_free_port() {
  helper free-port
}

# Mock warp-cli that, if ever consulted, reports DISCONNECTED — proving the
# trusted-routed bind proof never calls it (no enrollment requirement), and
# that the WARP-mesh no-weakening case (f) genuinely fails closed.
write_mock_warp_cli_disconnected() {
  local cli="$SMOKE_TMP_ROOT/warp-cli-mock-disconnected"
  cat >"$cli" <<'EOF'
#!/usr/bin/env bash
# Always-disconnected mock warp-cli. Ignores --accept-tos.
args=()
for a in "$@"; do
  [[ "$a" == "--accept-tos" ]] && continue
  args+=("$a")
done
case "${args[0]:-}" in
  status)               echo "Status update: Disconnected" ;;
  registration|account) echo "Device unregistered" ;;
  *)                    echo "mock warp-cli: ${args[0]:-<none>}" >&2; exit 2 ;;
esac
exit 0
EOF
  chmod 0755 "$cli"
  printf '%s' "$cli"
}

# Bring the 'reviewer' target up so the receiver's bridge-task.sh create
# (#1318 stopped-target guard) treats it as a live reader.
write_a2a_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/reviewer"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="reviewer"
bridge_add_agent_id_if_missing "reviewer"
BRIDGE_AGENT_DESC["reviewer"]="trusted-routed smoke reviewer"
BRIDGE_AGENT_ENGINE["reviewer"]="shell"
BRIDGE_AGENT_SESSION["reviewer"]="$REVIEWER_SESSION_NAME"
BRIDGE_AGENT_WORKDIR["reviewer"]="$workdir"
BRIDGE_AGENT_LAUNCH_CMD["reviewer"]="bash -lc 'echo reviewer'"
BRIDGE_AGENT_LOOP["reviewer"]=0
BRIDGE_AGENT_CONTINUE["reviewer"]=0
EOF
}

start_reviewer_session() {
  REVIEWER_SESSION="$REVIEWER_SESSION_NAME"
  if ! tmux new-session -d -s "$REVIEWER_SESSION" "sleep 600" 2>/dev/null; then
    smoke_fail "reviewer tmux new-session '$REVIEWER_SESSION' failed"
  fi
  if ! tmux has-session -t "=${REVIEWER_SESSION}" 2>/dev/null; then
    smoke_fail "reviewer tmux session '$REVIEWER_SESSION' did not come up"
  fi
}

# Receiver config (kind=trusted-routed). `peer_addr` is the address the
# receiver compares the inbound client_ip against. Pass a loopback peer addr
# for the happy/source-match cases and a routed IP for the mismatch case.
write_tr_config() {
  local port="$1" peer_addr="$2"
  cat >"$BRIDGE_HOME/handoff.local.json" <<EOF
{
  "bridge_id": "bridge-b",
  "transport": { "kind": "trusted-routed" },
  "listen": { "address": "127.0.0.1", "port": ${port}, "enqueue_path": "/enqueue" },
  "timestamp_skew_seconds": 300,
  "peers": [
    {
      "id": "bridge-a",
      "address": "${peer_addr}",
      "port": ${port},
      "secret": "${A2A_SECRET}",
      "inbound_allowlist": ["reviewer"],
      "caps": { "max_body_bytes": 262144, "max_title_bytes": 1024 }
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff.local.json"
}

# A preflight-only trusted-routed config carrying an arbitrary bind address.
write_tr_bind_config() {
  local bind="$1"
  cat >"$BRIDGE_HOME/handoff-tr-bind.json" <<EOF
{
  "bridge_id": "bridge-b",
  "transport": { "kind": "trusted-routed" },
  "listen": { "address": "${bind}", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-tr-bind.json"
}

# A mock `tailscale` CLI that reports a tailnet IP on `ip` AND records that it
# was invoked (touches a sentinel). Used by the empty-bind F1 case to PROVE the
# trusted-routed empty-listen.address path FAILS CLOSED with bind_unresolved
# and NEVER falls through to the Tailscale auto-select (which would otherwise
# bind tailnet[0]=100.64.0.99 under the weaker interface-only proof).
write_mock_tailscale_available() {
  local cli="$SMOKE_TMP_ROOT/tailscale-mock-available"
  local sentinel="$SMOKE_TMP_ROOT/tailscale-was-invoked"
  rm -f "$sentinel"
  cat >"$cli" <<EOF
#!/usr/bin/env bash
: >"$sentinel"
case "\${1:-}" in
  ip)            echo "100.64.0.99" ;;
  status)        echo '{"Self":{"TailscaleIPs":["100.64.0.99"]}}' ;;
  *)             echo "mock tailscale: \${1:-<none>}" >&2; exit 0 ;;
esac
exit 0
EOF
  chmod 0755 "$cli"
  printf '%s' "$cli"
}

base_url() {
  printf 'http://127.0.0.1:%s' "$A2A_PORT"
}

# Run the receiver preflight with the mocked iface probe. NO warp-cli is given
# (BRIDGE_A2A_WARP_CLI points at a non-existent path) to PROVE the
# trusted-routed proof never needs WARP. Echoes combined stdout+stderr; the
# caller asserts on it + the captured rc.
tr_preflight() {
  local bind="$1" iface_addrs="$2"
  write_tr_bind_config "$bind"
  local out rc=0
  out="$(BRIDGE_A2A_WARP_CLI="$SMOKE_TMP_ROOT/no-such-warp-cli" \
        BRIDGE_A2A_IFACE_ADDRS="$iface_addrs" \
        python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" preflight \
          --config "$BRIDGE_HOME/handoff-tr-bind.json" 2>&1)" || rc=$?
  printf '%s\n__RC__=%s\n' "$out" "$rc"
}

# === (a) bind proof — happy path: assigned local IP, NO WARP ===
tr_bind_proof_happy() {
  local res; res="$(tr_preflight "$ROUTED_IP" "$ROUTED_IP $LAN_IP")"
  smoke_assert_contains "$res" "__RC__=0" "trusted-routed assigned bind preflight exits 0"
  smoke_assert_contains "$res" "preflight] OK" \
    "assigned local IP + NO WARP -> bind OK (interface-assignment proof only)"
}

# === (b) fail-closed bind refusals ===
tr_bind_refuse_wildcard() {
  local res; res="$(tr_preflight "0.0.0.0" "0.0.0.0")"
  smoke_assert_contains "$res" "__RC__=1" "wildcard bind refused (rc=1)"
  smoke_assert_contains "$res" "bind_wildcard" "wildcard -> bind_wildcard"
}

tr_bind_refuse_loopback() {
  local res; res="$(tr_preflight "127.0.0.1" "127.0.0.1")"
  smoke_assert_contains "$res" "__RC__=1" "loopback bind refused (rc=1)"
  smoke_assert_contains "$res" "bind_loopback" "loopback -> bind_loopback"
}

tr_bind_refuse_unassigned_local() {
  # The routed IP is NOT on any local interface -> refused (no CIDR-shape pass).
  local res; res="$(tr_preflight "$ROUTED_IP" "$LAN_IP 192.168.1.2")"
  smoke_assert_contains "$res" "__RC__=1" "unassigned routed IP refused (rc=1)"
  smoke_assert_contains "$res" "bind_not_local" \
    "routed IP not on a local interface -> bind_not_local (no CIDR-shape pass)"
}

tr_bind_refuse_cidr_only_guess() {
  # Empty local-interface set: a CIDR-shaped-but-not-local IP must still refuse.
  local res; res="$(tr_preflight "$ROUTED_IP" "")"
  smoke_assert_contains "$res" "__RC__=1" "CIDR-only guess refused (rc=1)"
  smoke_assert_contains "$res" "bind_not_local" \
    "CIDR-shaped-but-not-local routed IP -> bind_not_local (CIDR shape is NOT proof)"
}

# === (c) unknown / typo transport.kind hard-fails ===
tr_unknown_kind_hard_fail() {
  cat >"$BRIDGE_HOME/handoff-unk.json" <<EOF
{
  "bridge_id": "bridge-b",
  "transport": { "kind": "trusted-rooted" },
  "listen": { "address": "${ROUTED_IP}", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-unk.json"
  local out rc=0
  out="$(BRIDGE_A2A_IFACE_ADDRS="$ROUTED_IP" \
        python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" preflight \
          --config "$BRIDGE_HOME/handoff-unk.json" 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" "typo transport.kind refused (rc=1)"
  smoke_assert_contains "$out" "transport_unknown" \
    "'trusted-rooted' (typo) -> transport_unknown (no default-allow)"
}

# === live loopback receiver over the trusted-routed transport ===
start_tr_receiver() {
  local peer_addr="$1"
  A2A_PORT="$(pick_free_port)"
  write_tr_config "$A2A_PORT" "$peer_addr"
  # BRIDGE_A2A_ALLOW_TEST_BIND=1 short-circuits the membership proof BEFORE the
  # interface check (transport-agnostic loopback escape hatch), so the live
  # end-to-end socket runs on loopback while the bind-proof itself is covered
  # by the preflight cases above.
  BRIDGE_A2A_ALLOW_TEST_BIND=1 \
    python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" serve \
      --config "$BRIDGE_HOME/handoff.local.json" \
      >"$SMOKE_TMP_ROOT/handoffd.log" 2>&1 &
  HANDOFFD_PID=$!
  local waited=0
  while (( waited < 50 )); do
    if helper wait-port "$A2A_PORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  smoke_fail "trusted-routed receiver did not start; log: $(cat "$SMOKE_TMP_ROOT/handoffd.log")"
}

stop_tr_receiver() {
  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
    HANDOFFD_PID=""
  fi
}

# === (a) e2e: signed handoff over trusted-routed transport -> 200 + inbox ===
tr_successful_enqueue() {
  start_tr_receiver "127.0.0.1"
  local out
  out="$(helper ok "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=200" \
    "valid signed handoff over trusted-routed transport -> 200"
  local inbox_out
  inbox_out="$("$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer)"
  smoke_assert_contains "$inbox_out" "trusted routed ok" \
    "trusted-routed handoff visible in local inbox"
}

# === (d) bad HMAC -> 401 (auth layer unchanged under the new kind) ===
tr_auth_fail() {
  local out
  out="$(helper auth-fail "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=401" "bad HMAC over trusted-routed transport -> 401"
}

# === (d) room-scoped delivery routes through room_scoped_check (fail-closed) ===
tr_room_scoped_gate() {
  local out
  out="$(helper room-scoped "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=403" \
    "room-scoped over trusted-routed transport gated by room_scoped_check (no rooms.db -> 403)"
}

# === (d) source-address mismatch -> 403 ===
tr_source_mismatch() {
  # Peer configured with a routed IP that is NOT the loopback the client posts
  # from -> resolve_peer_address_for_transport returns the routed IP and the
  # client_ip (127.0.0.1) mismatch is rejected BEFORE HMAC.
  stop_tr_receiver
  start_tr_receiver "10.21.2.99"
  local out
  out="$(helper ok "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=403" \
    "peer routed IP != client_ip -> 403 source-address mismatch"
  smoke_assert_contains "$out" "source address mismatch" \
    "403 body names the source-address mismatch"
}

# === (e) sender source symmetry (#1758) ===
tr_sender_source_select() {
  local out; out="$(helper source-select)"
  smoke_assert_contains "$out" "MESH_SOURCE=10.128.0.25" \
    "warp-mesh peer egresses from this node's own Mesh listen.address"
  smoke_assert_contains "$out" "ROUTED_SOURCE=None" \
    "trusted-routed peer gets None -> OS routing picks the reachable source"
  smoke_assert_contains "$out" "TAILSCALE_SOURCE=None" \
    "tailscale peer keeps legacy OS-routed source (no pin)"
  smoke_assert_contains "$out" "MESH_NOLISTEN_SOURCE=None" \
    "warp-mesh with no usable Mesh listen.address falls back to OS-routed (no guess)"
}

tr_sender_source_bound_egress() {
  local port; port="$(pick_free_port)"
  local out; out="$(helper source-bound-egress "$port")"
  smoke_assert_contains "$out" "BOUND_STATUS=200" \
    "source-bound opener delivers the POST (mesh-source case)"
  smoke_assert_contains "$out" "BOUND_SRC=127.0.0.1" \
    "source-bound opener egresses from the chosen source (stands in for the Mesh IP)"
  smoke_assert_contains "$out" "ROUTED_STATUS=200" \
    "None-source (OS-routed) opener delivers the POST (trusted-routed case)"
}

# === (e/F2) CALL-SITE-SHAPED source selection — the real laptop rollout shape ===
tr_sender_source_callsite() {
  # Fixed warp-mesh node + two heterogeneous peers (one mesh, one routed-marked)
  # resolved through the EXACT sender sequence. Proves the per-DESTINATION fix:
  # the bug Mesh-pinned EVERY peer on a warp-mesh node, stranding the routed
  # cm-prod peer ("Network is unreachable").
  local out; out="$(helper source-select-callsite)"
  smoke_assert_contains "$out" "NODE_KIND=cloudflare-warp-mesh" \
    "node kind derived once = cloudflare-warp-mesh (the laptop)"
  smoke_assert_contains "$out" "MESH_PEER_SOURCE=10.128.0.25" \
    "unmarked Mesh peer keeps the pinned Mesh source (byte-unaffected)"
  smoke_assert_contains "$out" "ROUTED_PEER_SOURCE=None" \
    "routed-marked cm-prod peer gets None -> OS-routed (was wrongly Mesh-pinned)"
}

# === (e/F2) an unknown PEER transport.kind hard-fails (fail-closed) ===
tr_peer_transport_unknown() {
  local out; out="$(helper peer-transport-unknown)"
  smoke_assert_contains "$out" "PEER_UNKNOWN_CODE=transport_unknown" \
    "typo PEER transport.kind -> transport_unknown (no silent fallback)"
}

# === (F1) empty listen.address under trusted-routed -> bind_unresolved ===
tr_empty_bind_no_autoselect() {
  # The trusted-routed bind proof is interface-assignment ONLY (weaker). An
  # empty listen.address MUST fail closed with bind_unresolved and MUST NOT
  # fall through to the Tailscale auto-select (which would bind tailnet[0]
  # under that weaker proof). A tailscale CLI that WOULD return 100.64.0.99 is
  # provided; we assert it was NEVER consulted.
  local ts_cli sentinel
  ts_cli="$(write_mock_tailscale_available)"
  sentinel="$SMOKE_TMP_ROOT/tailscale-was-invoked"
  write_tr_bind_config ""
  local out rc=0
  out="$(BRIDGE_A2A_WARP_CLI="$SMOKE_TMP_ROOT/no-such-warp-cli" \
        BRIDGE_A2A_TAILSCALE_CLI="$ts_cli" \
        BRIDGE_A2A_IFACE_ADDRS="100.64.0.99" \
        python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" preflight \
          --config "$BRIDGE_HOME/handoff-tr-bind.json" 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" "trusted-routed empty listen.address refused (rc=1)"
  smoke_assert_contains "$out" "bind_unresolved" \
    "empty listen.address under trusted-routed -> bind_unresolved (no auto-select)"
  smoke_assert_not_contains "$out" "auto-selected tailnet IP" \
    "trusted-routed empty bind does NOT auto-select a tailnet IP"
  smoke_assert_not_contains "$out" "100.64.0.99" \
    "the auto-select tailnet IP never leaks into a trusted-routed bind"
  [[ -f "$sentinel" ]] && smoke_fail \
    "trusted-routed empty bind consulted tailscale (auto-select path reached)"
  smoke_log "F1: trusted-routed empty bind failed closed, tailscale never consulted"
}

# === (f) NO weakening: WARP-mesh WITHOUT WARP still fails closed ===
tr_warp_mesh_still_requires_warp() {
  stop_tr_receiver
  cat >"$BRIDGE_HOME/handoff-cf-bind.json" <<EOF
{
  "bridge_id": "bridge-b",
  "transport": { "kind": "cloudflare-warp-mesh" },
  "listen": { "address": "${ROUTED_IP}", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-cf-bind.json"
  local mock; mock="$(write_mock_warp_cli_disconnected)"
  local out rc=0
  # IP IS on a local interface, but WARP is disconnected -> the cloudflare
  # path MUST still fail closed. The enrollment proof was dropped ONLY for
  # trusted-routed; cloudflare-warp-mesh is unchanged.
  out="$(BRIDGE_A2A_WARP_CLI="$mock" \
        BRIDGE_A2A_IFACE_ADDRS="$ROUTED_IP" \
        python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" preflight \
          --config "$BRIDGE_HOME/handoff-cf-bind.json" 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" "cloudflare-warp-mesh WITHOUT WARP still refused (rc=1)"
  smoke_assert_contains "$out" "warp_unavailable" \
    "cloudflare-warp-mesh enrollment proof intact (trusted-routed did NOT weaken it)"
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd tmux
  smoke_setup_bridge_home "1758-trusted-routed-transport"
  write_a2a_roster
  start_reviewer_session

  # (a) + (b) + (c) bind-proof cases (preflight; mocked iface probe, NO WARP).
  smoke_run "(a) trusted-routed bind proof: assigned local IP + NO WARP -> OK" tr_bind_proof_happy
  smoke_run "(b) trusted-routed bind refused: wildcard" tr_bind_refuse_wildcard
  smoke_run "(b) trusted-routed bind refused: loopback" tr_bind_refuse_loopback
  smoke_run "(b) trusted-routed bind refused: unassigned-local routed IP" tr_bind_refuse_unassigned_local
  smoke_run "(b) trusted-routed bind refused: CIDR-only guess" tr_bind_refuse_cidr_only_guess
  smoke_run "(c) unknown/typo transport.kind hard-fails" tr_unknown_kind_hard_fail

  # (a) e2e + (d) auth invariants over a live loopback trusted-routed receiver.
  smoke_run "(a) trusted-routed e2e: signed handoff -> 200 + inbox" tr_successful_enqueue
  smoke_run "(d) bad HMAC over trusted-routed transport -> 401" tr_auth_fail
  smoke_run "(d) room-scoped over trusted-routed gated by room_scoped_check" tr_room_scoped_gate
  smoke_run "(d) source-address mismatch -> 403" tr_source_mismatch

  # (e) sender source symmetry.
  smoke_run "(e) sender source selection per transport (mesh vs routed)" tr_sender_source_select
  smoke_run "(e/F2) call-site-shaped: warp-mesh node + mesh & routed-marked peers" tr_sender_source_callsite
  smoke_run "(e/F2) unknown PEER transport.kind hard-fails" tr_peer_transport_unknown
  smoke_run "(e) source-bound opener egress (bound source vs OS-routed)" tr_sender_source_bound_egress

  # (F1) empty listen.address under trusted-routed -> bind_unresolved (no auto-select).
  smoke_run "(F1) trusted-routed empty listen.address -> bind_unresolved (no auto-select)" tr_empty_bind_no_autoselect

  # (f) no-weakening: WARP-mesh enrollment proof intact.
  smoke_run "(f) cloudflare-warp-mesh WITHOUT WARP still fails closed" tr_warp_mesh_still_requires_warp

  smoke_log "passed"
}

main "$@"
