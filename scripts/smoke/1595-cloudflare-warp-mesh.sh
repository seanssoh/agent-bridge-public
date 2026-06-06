#!/usr/bin/env bash
# scripts/smoke/1595-cloudflare-warp-mesh.sh — A2A Cloudflare One / WARP-Mesh
# transport smoke (#1595).
#
# Exercises the transport-pluggable receiver bind/source proof + the
# Cloudflare-One / WARP-Mesh kind end-to-end against an isolated env. The WARP
# CLI + the local-interface set are MOCKED via the probe seams
# (BRIDGE_A2A_WARP_CLI, BRIDGE_A2A_IFACE_ADDRS) so the proof runs its REAL
# code path with no real WARP install. Covers:
#   (a) Cloudflare happy path — proven local Mesh IP + connected/enrolled WARP
#       -> preflight OK (bind proof), and a live loopback receiver delivers a
#       signed handoff -> 200 + local inbox visibility.
#   (b) source-address mismatch -> 403 (peer Mesh IP != client_ip).
#   (c) bad HMAC -> 401.
#   (d) bad/absent WARP local proof -> bind REFUSED fail-closed, for EACH of:
#         wildcard / loopback / unassigned-local / WARP-disconnected /
#         WARP-unregistered / CIDR-only-guess / warp-cli-absent.
#   (e) Tailscale regression — an existing tailscale/raw-IP config (no
#       `transport` block) still binds + delivers EXACTLY as before.
#   (f) A2A Rooms room-scoped delivery over the Cloudflare transport routes
#       through the SAME room_scoped_check gate (fail-closed when no rooms.db).
#
# macOS: run with /opt/homebrew/bin/bash (bash 5.x).

set -euo pipefail

SMOKE_NAME="1595-cloudflare-warp-mesh"
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
A2A_SECRET="cf-smoke-shared-secret-do-not-use-in-prod-0123456789"
# A non-loopback Mesh device IP used for the bind-proof preflight cases. It is
# never actually bound (preflight only validates) — the mock iface/WARP probes
# decide whether the proof passes.
MESH_IP="100.96.0.5"
REVIEWER_SESSION_NAME="cf-smoke-reviewer-$$-${RANDOM}"

helper() {
  python3 "$SCRIPT_DIR/1595-cloudflare-warp-mesh-helper.py" "$@"
}

pick_free_port() {
  helper free-port
}

# --- mock warp-cli (connected/enrolled vs the fail-closed negatives) ---
# Generated into the temp root; BRIDGE_A2A_WARP_CLI points the proof at it so
# the REAL warp_connected_and_enrolled() probe runs against a deterministic
# fixture (no real WARP needed) — emitting realistic warp-cli output. Modes
# via WARP_MOCK_MODE env:
#   connected      -> "Status update: Connected" + enrolled registration  (PASS)
#   disconnected   -> "Status update: Disconnected"                        (refused)
#   not-connected  -> "Status update: Not Connected" (strict-parse trap)   (refused)
#   connected-false-> "Status update: Connected: false" (strict-parse trap)(refused)
#   connecting     -> "Status update: Connecting"                          (refused)
#   unregistered   -> connected status + "Device unregistered"            (refused)
#   missing-reg    -> connected status + "Missing registration"           (refused)
#   reg-neg-value  -> connected status + "Account type: none" (label-shaped
#                     but negative VALUE — codex r2 trap)                  (refused)
#   reg-revoked    -> connected status + "Status: Revoked" + a valid Device
#                     ID line (non-active reg w/ a good field — codex r3 trap)(refused)
#   reg-contradict -> connected status + `registration show`="Device
#                     unregistered" (EXPLICIT negative) but `account`=enrolled.
#                     The explicit negative is terminal; the positive account
#                     fallback must NOT override it (codex r4 trap)          (refused)
#   reg-nonzero-neg-> connected status + `registration show` exits NON-ZERO
#                     with an explicit-negative message on stderr, but
#                     `account`=enrolled. The non-zero explicit negative is
#                     still terminal — no positive-account override (codex r5)(refused)
write_mock_warp_cli() {
  local cli="$SMOKE_TMP_ROOT/warp-cli-mock"
  cat >"$cli" <<'EOF'
#!/usr/bin/env bash
# Mock warp-cli driven by WARP_MOCK_MODE. Ignores --accept-tos.
mode="${WARP_MOCK_MODE:-connected}"
args=()
for a in "$@"; do
  [[ "$a" == "--accept-tos" ]] && continue
  args+=("$a")
done
sub="${args[0]:-}"
print_enrolled_reg() {
  echo "Account type: Cloudflare One Zero Trust"
  echo "Organization: smoke-org"
  echo "Device ID: 11111111-2222-3333-4444-555555555555"
}
case "$sub" in
  status)
    case "$mode" in
      connected|unregistered|missing-reg|reg-neg-value|reg-revoked|reg-contradict|reg-nonzero-neg|reg-label-neg|reg-nonzero-positive) echo "Status update: Connected" ;;
      disconnected)                        echo "Status update: Disconnected" ;;
      not-connected)                       echo "Status update: Not Connected" ;;
      connected-false)                     echo "Status update: Connected: false" ;;
      connecting)                          echo "Status update: Connecting" ;;
      *)                                   echo "Status update: Unknown" ;;
    esac
    ;;
  registration|account)
    case "$mode" in
      connected)             print_enrolled_reg ;;
      unregistered)          echo "Device unregistered" ;;
      missing-reg)           echo "Missing registration. Run 'warp-cli registration new'." ;;
      reg-neg-value)         echo "Account type: none"; echo "Registration: Missing" ;;
      reg-revoked)           echo "Status: Revoked"; echo "Device ID: 11111111-2222-3333-4444-555555555555" ;;
      reg-contradict)
        # Modern verb says EXPLICITLY unregistered; legacy `account` says
        # enrolled. The explicit negative must win (terminal) — the smoke
        # asserts the bind is REFUSED, i.e. the account positive cannot
        # override it.
        if [[ "$sub" == "registration" ]]; then
          echo "Device unregistered"
        else
          print_enrolled_reg
        fi
        ;;
      reg-nonzero-neg)
        # Modern verb exits NON-ZERO with an explicit-negative message on
        # stderr; legacy `account` says enrolled. The non-zero explicit
        # negative is still terminal (classified from the exception text) —
        # the positive account must NOT override it. Smoke asserts REFUSED.
        if [[ "$sub" == "registration" ]]; then
          echo "Device unregistered" >&2
          exit 1
        else
          print_enrolled_reg
        fi
        ;;
      reg-label-neg)
        # Modern verb returns a recognized identity LABEL with a NEGATIVE
        # value ("Account type: false") — a terminal not-enrolled signal that
        # the positive `account` fallback must NOT override (codex r6 trap).
        if [[ "$sub" == "registration" ]]; then
          echo "Account type: false"
        else
          print_enrolled_reg
        fi
        ;;
      reg-nonzero-positive)
        # BOTH the modern `registration show` AND the legacy `account` verb EXIT
        # NON-ZERO (the query failed) yet still print a positive-looking identity
        # label on stdout, with the error on stderr (NOT a recognized negative
        # token). A positive enrollment conclusion REQUIRES rc==0 — a FAILED
        # query that happens to show "Organization: …" must NOT prove enrollment
        # (#1595 patch-dev re-review). Both sites are rc-gated → downgraded to
        # UNKNOWN → REFUSED.
        echo "Organization: Cosmax"
        echo "Error: registration service unavailable" >&2
        exit 17
        ;;
      disconnected|not-connected|connected-false|connecting) print_enrolled_reg ;;
      *)                     echo "" ;;
    esac
    ;;
  *)
    echo "mock warp-cli: unknown subcommand ${sub:-<none>}" >&2
    exit 2
    ;;
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
BRIDGE_AGENT_DESC["reviewer"]="CF WARP smoke reviewer"
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

# Receiver config (kind=cloudflare-warp-mesh). `peer_addr` is the address the
# receiver compares the inbound client_ip against. Pass a loopback peer addr
# for the happy/source-match cases and a Mesh IP for the mismatch case.
write_cf_config() {
  local port="$1" peer_addr="$2"
  cat >"$BRIDGE_HOME/handoff.local.json" <<EOF
{
  "bridge_id": "bridge-b",
  "transport": { "kind": "cloudflare-warp-mesh" },
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

# A preflight-only CF config carrying an arbitrary bind address (not bound).
write_cf_bind_config() {
  local bind="$1"
  cat >"$BRIDGE_HOME/handoff-cf-bind.json" <<EOF
{
  "bridge_id": "bridge-b",
  "transport": { "kind": "cloudflare-warp-mesh" },
  "listen": { "address": "${bind}", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-cf-bind.json"
}

# Legacy Tailscale/raw-IP config (NO transport block) for the regression case.
write_legacy_tailscale_config() {
  local port="$1"
  cat >"$BRIDGE_HOME/handoff-legacy.json" <<EOF
{
  "bridge_id": "bridge-b",
  "listen": { "address": "127.0.0.1", "port": ${port}, "enqueue_path": "/enqueue" },
  "timestamp_skew_seconds": 300,
  "peers": [
    {
      "id": "bridge-a",
      "address": "127.0.0.1",
      "port": ${port},
      "secret": "${A2A_SECRET}",
      "inbound_allowlist": ["reviewer"],
      "caps": { "max_body_bytes": 262144 }
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-legacy.json"
}

base_url() {
  printf 'http://127.0.0.1:%s' "$A2A_PORT"
}

# Run the receiver preflight with mocked WARP + iface probes. Echoes combined
# stdout+stderr; the caller asserts on it + the captured rc.
cf_preflight() {
  local bind="$1" warp_mode="$2" iface_addrs="$3" warp_cli="$4"
  write_cf_bind_config "$bind"
  local out rc=0
  out="$(WARP_MOCK_MODE="$warp_mode" \
        BRIDGE_A2A_WARP_CLI="$warp_cli" \
        BRIDGE_A2A_IFACE_ADDRS="$iface_addrs" \
        python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" preflight \
          --config "$BRIDGE_HOME/handoff-cf-bind.json" 2>&1)" || rc=$?
  printf '%s\n__RC__=%s\n' "$out" "$rc"
}

# === (a) bind proof — happy path: proven local Mesh IP + connected WARP ===
cf_bind_proof_happy() {
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" connected "$MESH_IP 10.0.0.1" "$mock")"
  smoke_assert_contains "$res" "__RC__=0" "CF happy bind proof preflight exits 0"
  smoke_assert_contains "$res" "preflight] OK" "proven local Mesh IP + connected WARP -> bind OK"
}

# === (d) fail-closed bind refusals ===
cf_bind_refuse_wildcard() {
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "0.0.0.0" connected "0.0.0.0" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "wildcard bind refused (rc=1)"
  smoke_assert_contains "$res" "bind_wildcard" "wildcard -> bind_wildcard"
}

cf_bind_refuse_loopback() {
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "127.0.0.1" connected "127.0.0.1" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "loopback bind refused (rc=1)"
  smoke_assert_contains "$res" "bind_loopback" "loopback -> bind_loopback"
}

cf_bind_refuse_unassigned_local() {
  # WARP connected but the Mesh IP is NOT on any local interface -> refused.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" connected "10.0.0.1 192.168.1.2" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "unassigned-local Mesh IP refused (rc=1)"
  smoke_assert_contains "$res" "bind_not_warp_local" \
    "Mesh IP not on a local interface -> bind_not_warp_local (no CIDR-shape pass)"
}

cf_bind_refuse_cidr_only_guess() {
  # The CIDR-shape is right (inside the Mesh range) but it is NOT a real local
  # interface address: an empty local-interface set must still refuse.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "100.96.0.250" connected "" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "CIDR-only guess refused (rc=1)"
  smoke_assert_contains "$res" "bind_not_warp_local" \
    "CIDR-shaped-but-not-local Mesh IP -> bind_not_warp_local (CIDR shape is NOT proof)"
}

cf_bind_refuse_warp_disconnected() {
  # IP IS on a local interface, but WARP is disconnected -> refused.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" disconnected "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "WARP-disconnected bind refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "disconnected WARP -> warp_unavailable (fail-closed)"
}

cf_bind_refuse_warp_unregistered() {
  # IP on a local interface, WARP connected, but device not enrolled -> refused.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" unregistered "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "WARP-unregistered bind refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "un-enrolled WARP device -> warp_unavailable (fail-closed)"
}

cf_bind_refuse_warp_cli_absent() {
  # warp-cli not found -> cannot prove connected/enrolled -> refused. The
  # empirical probe blocked by "WARP not installed" must FAIL CLOSED, not pass.
  local res; res="$(cf_preflight "$MESH_IP" connected "$MESH_IP" "$SMOKE_TMP_ROOT/no-such-warp-cli")"
  smoke_assert_contains "$res" "__RC__=1" "absent warp-cli bind refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "absent warp-cli -> warp_unavailable (no shape-only fallback)"
}

# Strict-parse traps (#1595 codex r1 finding 1): an ambiguous "connected"-
# containing status must NOT pass. "Not Connected" / "Connected: false" /
# "Connecting" each contain the substring "connected" but are NOT an exact
# connected state -> must fail closed.
cf_bind_refuse_status_not_connected() {
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" not-connected "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "'Not Connected' status refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "'Not Connected' (contains 'connected') -> warp_unavailable (strict parse)"
}

cf_bind_refuse_status_connected_false() {
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" connected-false "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "'Connected: false' status refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "'Connected: false' -> warp_unavailable (strict parse)"
}

cf_bind_refuse_status_connecting() {
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" connecting "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "'Connecting' status refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "'Connecting' (transient) -> warp_unavailable (strict parse)"
}

cf_bind_refuse_reg_device_unregistered() {
  # "Device unregistered" is non-empty output but is NOT enrollment -> refuse.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" unregistered "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "'Device unregistered' refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "'Device unregistered' (non-empty != enrolled) -> warp_unavailable"
}

cf_bind_refuse_reg_negative_value() {
  # codex r2 trap: a positive-LABEL line with a NEGATIVE value (e.g.
  # "Account type: none" / "Registration: Missing") must NOT pass the
  # enrollment proof — a label-only check would false-pass it.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" reg-neg-value "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "label-with-negative-value reg refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "'Account type: none' (label-shaped, negative value) -> warp_unavailable"
}

# Finding 2 (#1595 codex r1): a cloudflare-warp-mesh `listen` keyed on a
# Tailscale identity (node_id/tailscale_name) must be REJECTED — a WARP node
# cannot resolve a tailnet identity, and resolve_bind must not fall through to
# `tailscale status`. Refuse fail-closed at bind resolution.
cf_bind_refuse_reg_revoked_status() {
  # codex r3 trap: a non-active registration STATUS line (Revoked/Inactive/
  # Deleted/...) must fail closed even when a concrete identity field (a valid
  # Device ID) is ALSO present.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" reg-revoked "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "revoked-status reg refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "'Status: Revoked' + valid Device ID -> warp_unavailable (non-active reg)"
}

cf_bind_refuse_reg_contradictory_probe() {
  # codex r4 trap: `registration show` EXPLICITLY says unregistered while the
  # legacy `account` fallback says enrolled. The explicit negative is
  # terminal — the positive fallback must NOT override it -> fail closed.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" reg-contradict "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "contradictory reg probes refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "explicit 'registration show' negative not overridden by positive 'account' -> warp_unavailable"
}

cf_bind_refuse_reg_nonzero_negative() {
  # codex r5 trap: `registration show` exits NON-ZERO with an explicit-negative
  # message; the legacy `account` fallback says enrolled. The non-zero explicit
  # negative is classified from the exception text and is terminal — the
  # positive account must NOT override it -> fail closed.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" reg-nonzero-neg "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "non-zero explicit-negative reg refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "non-zero 'registration show' explicit negative not overridden by positive 'account' -> warp_unavailable"
}

cf_bind_refuse_reg_label_negative_value_fallback() {
  # codex r6 trap: modern verb returns a recognized identity LABEL with a
  # NEGATIVE value ("Account type: false") — terminal not-enrolled — while the
  # legacy `account` fallback says enrolled. The positive fallback must NOT
  # override the terminal negative -> fail closed.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" reg-label-neg "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "label-negative-value reg refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "'Account type: false' (terminal) not overridden by positive 'account' -> warp_unavailable"
}

cf_bind_refuse_reg_nonzero_positive() {
  # patch-dev #1595 re-review: BOTH `registration show` AND the legacy `account`
  # verb EXIT NON-ZERO (the query failed) yet print a positive-looking identity
  # label ("Organization: Cosmax") on stdout with the error on stderr (NOT a
  # recognized negative token). A positive enrollment conclusion REQUIRES rc==0
  # — a FAILED query that merely shows a positive label must NOT prove
  # enrollment. The rc gate downgrades both probe sites to UNKNOWN -> fail closed.
  local mock; mock="$(write_mock_warp_cli)"
  local res; res="$(cf_preflight "$MESH_IP" reg-nonzero-positive "$MESH_IP" "$mock")"
  smoke_assert_contains "$res" "__RC__=1" "non-zero positive-label reg refused (rc=1)"
  smoke_assert_contains "$res" "warp_unavailable" \
    "non-zero 'registration show'/'account' positive label not trusted -> warp_unavailable"
}

cf_bind_refuse_listen_tailscale_identity() {
  cat >"$BRIDGE_HOME/handoff-cf-listenid.json" <<EOF
{
  "bridge_id": "bridge-b",
  "transport": { "kind": "cloudflare-warp-mesh" },
  "listen": { "node_id": "nDEADBEEF", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-cf-listenid.json"
  local mock; mock="$(write_mock_warp_cli)"
  local out rc=0
  out="$(WARP_MOCK_MODE=connected BRIDGE_A2A_WARP_CLI="$mock" \
        BRIDGE_A2A_IFACE_ADDRS="$MESH_IP" \
        python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" preflight \
          --config "$BRIDGE_HOME/handoff-cf-listenid.json" 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" "WARP listen with tailscale identity refused (rc=1)"
  smoke_assert_contains "$out" "warp_identity_misconfig" \
    "WARP listen.node_id -> warp_identity_misconfig (no tailscale fallthrough)"
}

# === live loopback receiver over the Cloudflare transport ===
start_cf_receiver() {
  local peer_addr="$1"
  A2A_PORT="$(pick_free_port)"
  write_cf_config "$A2A_PORT" "$peer_addr"
  # BRIDGE_A2A_ALLOW_TEST_BIND=1 short-circuits the membership proof BEFORE
  # the WARP probe (transport-agnostic loopback escape hatch), so the live
  # end-to-end socket runs without a real WARP install while the bind-proof
  # itself is covered by the preflight cases above.
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
  smoke_fail "CF receiver did not start; log: $(cat "$SMOKE_TMP_ROOT/handoffd.log")"
}

stop_cf_receiver() {
  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
    HANDOFFD_PID=""
  fi
}

# === (a) e2e: signed handoff over Cloudflare transport -> 200 + inbox ===
cf_successful_enqueue() {
  start_cf_receiver "127.0.0.1"
  local out
  out="$(helper ok "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=200" \
    "valid signed handoff over CF transport -> 200"
  local inbox_out
  inbox_out="$("$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer)"
  smoke_assert_contains "$inbox_out" "cloudflare warp mesh ok" \
    "CF-transport handoff visible in local inbox"
}

# === (c) bad HMAC -> 401 (auth layer unchanged under CF transport) ===
cf_auth_fail() {
  local out
  out="$(helper auth-fail "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=401" "bad HMAC over CF transport -> 401"
}

# === (f) room-scoped delivery routes through room_scoped_check (fail-closed) ===
cf_room_scoped_gate() {
  local out
  out="$(helper room-scoped "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=403" \
    "room-scoped over CF transport gated by room_scoped_check (no rooms.db -> 403)"
}

# === (b) source-address mismatch -> 403 ===
cf_source_mismatch() {
  # Peer configured with a Mesh IP that is NOT the loopback the client posts
  # from -> resolve_peer_address_for_transport returns the Mesh IP and the
  # client_ip (127.0.0.1) mismatch is rejected BEFORE HMAC.
  stop_cf_receiver
  start_cf_receiver "100.96.0.99"
  local out
  out="$(helper ok "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=403" \
    "peer Mesh IP != client_ip -> 403 source-address mismatch"
  smoke_assert_contains "$out" "source address mismatch" \
    "403 body names the source-address mismatch"
}

# === (e) Tailscale regression: legacy config still binds + delivers ===
cf_tailscale_regression() {
  stop_cf_receiver
  local port; port="$(pick_free_port)"
  write_legacy_tailscale_config "$port"
  # Legacy config has NO transport block -> transport_kind defaults to
  # "tailscale" and the bind goes through the unchanged loopback test-bind +
  # (in prod) the tailscale-ip membership proof. Loopback test-bind here.
  BRIDGE_A2A_ALLOW_TEST_BIND=1 \
    python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" serve \
      --config "$BRIDGE_HOME/handoff-legacy.json" \
      >"$SMOKE_TMP_ROOT/handoffd-legacy.log" 2>&1 &
  HANDOFFD_PID=$!
  A2A_PORT="$port"
  local waited=0
  while (( waited < 50 )); do
    if helper wait-port "$A2A_PORT" 2>/dev/null; then break; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  helper wait-port "$A2A_PORT" >/dev/null 2>&1 || \
    smoke_fail "legacy receiver did not start; log: $(cat "$SMOKE_TMP_ROOT/handoffd-legacy.log")"

  local out
  out="$(helper ok "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=200" \
    "legacy tailscale/raw-IP config (no transport block) still delivers -> 200"
  local inbox_out
  inbox_out="$("$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer)"
  smoke_assert_contains "$inbox_out" "cloudflare warp mesh ok" \
    "legacy-config handoff visible in local inbox (regression intact)"

  # And the legacy preflight WITHOUT tailscale CLI must still fail closed on a
  # tailnet-shaped bind (the unchanged Tailscale proof) — proving #1595 did
  # not weaken the Tailscale path.
  cat >"$BRIDGE_HOME/handoff-cgnat.json" <<'EOF'
{
  "bridge_id": "bridge-b",
  "listen": { "address": "100.64.0.10", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff-cgnat.json"
  local pf rc=0
  pf="$(BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" \
        python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" preflight \
          --config "$BRIDGE_HOME/handoff-cgnat.json" 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" "legacy tailscale preflight still fails closed without tailscale CLI"
  smoke_assert_contains "$pf" "tailscale_unavailable" \
    "Tailscale proof unchanged: absent tailscale CLI -> tailscale_unavailable"
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd tmux
  smoke_setup_bridge_home "1595-cloudflare-warp-mesh"
  write_a2a_roster
  start_reviewer_session

  # (a) + (d) bind-proof cases (preflight; mocked WARP + iface probes).
  smoke_run "(a) CF bind proof: proven local Mesh IP + connected WARP -> OK" cf_bind_proof_happy
  smoke_run "(d) CF bind refused: wildcard" cf_bind_refuse_wildcard
  smoke_run "(d) CF bind refused: loopback" cf_bind_refuse_loopback
  smoke_run "(d) CF bind refused: unassigned-local Mesh IP" cf_bind_refuse_unassigned_local
  smoke_run "(d) CF bind refused: CIDR-only guess" cf_bind_refuse_cidr_only_guess
  smoke_run "(d) CF bind refused: WARP disconnected" cf_bind_refuse_warp_disconnected
  smoke_run "(d) CF bind refused: WARP unregistered" cf_bind_refuse_warp_unregistered
  smoke_run "(d) CF bind refused: warp-cli absent" cf_bind_refuse_warp_cli_absent
  smoke_run "(d) CF bind refused: status 'Not Connected' (strict parse)" cf_bind_refuse_status_not_connected
  smoke_run "(d) CF bind refused: status 'Connected: false' (strict parse)" cf_bind_refuse_status_connected_false
  smoke_run "(d) CF bind refused: status 'Connecting' (strict parse)" cf_bind_refuse_status_connecting
  smoke_run "(d) CF bind refused: 'Device unregistered' (non-empty != enrolled)" cf_bind_refuse_reg_device_unregistered
  smoke_run "(d) CF bind refused: reg label with negative value (codex r2 trap)" cf_bind_refuse_reg_negative_value
  smoke_run "(d) CF bind refused: non-active reg status (Revoked, codex r3 trap)" cf_bind_refuse_reg_revoked_status
  smoke_run "(d) CF bind refused: contradictory reg probes (codex r4 trap)" cf_bind_refuse_reg_contradictory_probe
  smoke_run "(d) CF bind refused: non-zero explicit-negative reg (codex r5 trap)" cf_bind_refuse_reg_nonzero_negative
  smoke_run "(d) CF bind refused: label-negative-value not overridden by fallback (codex r6 trap)" cf_bind_refuse_reg_label_negative_value_fallback
  smoke_run "(d) CF bind refused: non-zero exit + positive label (patch-dev re-review: rc==0 required for enrolled)" cf_bind_refuse_reg_nonzero_positive
  smoke_run "(d) CF bind refused: WARP listen keyed on tailscale identity" cf_bind_refuse_listen_tailscale_identity

  # (a) e2e + (c) + (f) over a live loopback CF-transport receiver.
  smoke_run "(a) CF transport e2e: signed handoff -> 200 + inbox" cf_successful_enqueue
  smoke_run "(c) bad HMAC over CF transport -> 401" cf_auth_fail
  smoke_run "(f) room-scoped over CF transport gated by room_scoped_check" cf_room_scoped_gate

  # (b) source-address mismatch (peer Mesh IP != client_ip).
  smoke_run "(b) source-address mismatch -> 403" cf_source_mismatch

  # (e) Tailscale regression.
  smoke_run "(e) Tailscale/raw-IP regression: legacy config still binds+delivers" cf_tailscale_regression

  smoke_log "passed"
}

main "$@"
