#!/usr/bin/env bash
# scripts/smoke/a2a-ip-change-announce.sh — A2A signed peer-identity-update
# control message smoke (P-self-heal-3 / setup-wizard design §9.6).
#
# THE most security-sensitive A2A surface: the receiver MUTATES stored peer
# identity in response to UNTRUSTED remote traffic. This smoke drives the
# REAL receiver do_POST stack (HMAC, remote_addr, dedupe, skew, corroborate,
# apply) against a loopback-bound receiver + a MOCK `tailscale` CLI, and
# asserts the full fail-closed contract:
#
#   (a) valid announce from a paired peer whose claimed identity MATCHES the
#       receiver's own tailscale status   -> peer identity updated + hot-reload
#   (b) wire-asserted identity that does NOT match the receiver's own status
#       (claims a DIFFERENT real node)    -> REJECTED (409), no update   <-- ANTI-SPOOF
#   (c) bad HMAC                          -> 401, no update
#   (d) unknown/unpaired peer             -> 403, no update (NOT a discovery channel)
#   (e) replay (same message_id + body)   -> idempotent 200 duplicate, no double-update
#   (f) remote_addr != peer's resolved IP -> 403 reject BEFORE body
#   (g) the update NEVER touches secret/allowlist/caps/other peers
#   (h) 0600 preserved on write
#
# Uses a MOCK `tailscale` CLI (BRIDGE_A2A_TAILSCALE_CLI) + the loopback
# test-bind escape hatch (BRIDGE_A2A_ALLOW_TEST_BIND=1) so a real socket
# binds. The real tailnet is never touched. macOS-runnable.
#
# Mock topology (status --json):
#   Self      : ID=selfStableID123   HostName=my-host    IP=127.0.0.1
#   peer cm   : ID=peerStableID999    HostName=cm-prod-agentworkflow-vm01  IP=127.0.0.1
#   other     : ID=otherStableID      HostName=other-host  IP=127.0.0.9
# `ip` lists 127.0.0.1 (the bind). The peer `cm-prod` is identity-keyed on
# tailscale_name so it resolves to 127.0.0.1 (== the loopback client) for the
# inbound remote_addr gate.

set -euo pipefail

SMOKE_NAME="a2a-ip-change-announce"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/a2a-ip-change-announce-helper.py"
HANDOFFD_PID=""
A2A_PORT=""
A2A_SECRET="identity-update-smoke-secret-do-not-use-0123456789ab"

cleanup() {
  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

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
    "TailscaleIPs": ["127.0.0.1"],
    "Online": true, "OS": "linux"
  },
  "Peer": {
    "nodekey:cm": {
      "ID": "peerStableID999",
      "HostName": "cm-prod-agentworkflow-vm01",
      "DNSName": "cm-prod-agentworkflow-vm01.example-tailnet.ts.net.",
      "TailscaleIPs": ["127.0.0.1"],
      "Online": true, "OS": "linux"
    },
    "nodekey:other": {
      "ID": "otherStableID",
      "HostName": "other-host",
      "DNSName": "other-host.example-tailnet.ts.net.",
      "TailscaleIPs": ["127.0.0.9"],
      "Online": true, "OS": "linux"
    }
  }
}
JSON
  exit 0
fi
if [[ "$1" == "ip" ]]; then
  printf '127.0.0.1\n'
  exit 0
fi
exit 2
MOCK
  chmod +x "$dir/tailscale"
}

# Receiver config: bind on 127.0.0.1 (loopback test bind). One paired peer
# `cm-prod` identity-keyed on tailscale_name so the inbound remote_addr gate
# resolves it to 127.0.0.1 (== the loopback client). It carries a secret +
# allowlist + caps we assert are NEVER mutated, plus a SECOND peer `other-peer`
# we assert is left untouched.
write_a2a_config() {
  local port="$1"
  cat >"$BRIDGE_HOME/handoff.local.json" <<EOF
{
  "bridge_id": "bridge-self",
  "listen": { "address": "127.0.0.1", "port": ${port},
              "identity_update_path": "/peer-identity-update" },
  "timestamp_skew_seconds": 300,
  "peers": [
    {
      "id": "cm-prod",
      "tailscale_name": "cm-prod-agentworkflow-vm01",
      "port": ${port},
      "secret": "${A2A_SECRET}",
      "inbound_allowlist": ["reviewer", "ops"],
      "caps": { "max_body_bytes": 262144, "max_title_bytes": 1024 }
    },
    {
      "id": "other-peer",
      "tailscale_name": "other-host",
      "secret": "other-peer-secret-untouched-aaaaaaaaaaaaaaaaaaaaaa",
      "inbound_allowlist": ["someone"]
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff.local.json"
}

start_receiver() {
  local dir="$SMOKE_TMP_ROOT/mock-bin"
  write_mock_tailscale "$dir"
  export BRIDGE_A2A_TAILSCALE_CLI="$dir/tailscale"
  A2A_PORT="$(python3 "$HELPER" free-port)"
  write_a2a_config "$A2A_PORT"
  # Disable the periodic reconcile timer so the only config mutation is the
  # one the identity-update applies (deterministic assertions). SIGHUP path
  # is unaffected.
  BRIDGE_A2A_RECONCILE_INTERVAL=0 \
  BRIDGE_A2A_ALLOW_TEST_BIND=1 \
    python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" serve \
      --config "$BRIDGE_HOME/handoff.local.json" \
      >"$SMOKE_TMP_ROOT/handoffd.log" 2>&1 &
  HANDOFFD_PID=$!
  local waited=0
  while (( waited < 50 )); do
    if python3 "$HELPER" wait-port "$A2A_PORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  smoke_fail "receiver did not start; log: $(cat "$SMOKE_TMP_ROOT/handoffd.log")"
}

base_url() { printf 'http://127.0.0.1:%s' "$A2A_PORT"; }

# Path to the cfg-reader helper. Assigned from SMOKE_TMP_ROOT in main() AFTER
# smoke_setup_bridge_home runs (a parse-time assignment would expand to an
# empty root). Kept as a plain variable — NOT a $(...) command-substitution in
# a heredoc redirect target — so lint-heredoc-ban does not false-trigger C2.
CFG_HELPER=""
cfg_get() { python3 "$CFG_HELPER" "$@"; }

# --- config field reader (tiny, file-as-argv) -------------------------------
write_cfg_helper() {
  cat >"$CFG_HELPER" <<'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
expr = sys.argv[2]
def peer(pid):
    for p in cfg.get("peers", []):
        if p.get("id") == pid:
            return p
    return {}
if expr.startswith("peer:"):
    pid, _, field = expr[len("peer:"):].partition(".")
    p = peer(pid)
    cur = p
    for part in field.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part, "<MISSING>")
        else:
            cur = "<MISSING>"
    if isinstance(cur, list):
        print(",".join(str(x) for x in cur))
    else:
        print(cur)
else:
    print("<bad-expr>")
PYEOF
}

# --- (a) valid announce -> identity applied + hot-reload --------------------
case_a_apply() {
  local out cfg="$BRIDGE_HOME/handoff.local.json"
  out="$(python3 "$HELPER" post "$(base_url)" cm-prod "$A2A_SECRET" ok)"
  smoke_assert_contains "$out" "STATUS=200" "(a) valid corroborated announce -> 200"
  smoke_assert_contains "$out" '"applied": true' "(a) response flags applied"
  # The on-disk config now records the receiver-VERIFIED node_id for cm-prod.
  smoke_assert_eq "peerStableID999" "$(cfg_get "$cfg" peer:cm-prod.node_id)" \
    "(a) cm-prod identity-keyed to the receiver-verified StableID"
}

# --- (b) ANTI-SPOOF: wire claims a node the receiver does NOT corroborate ---
case_b_spoof_rejected() {
  local out cfg="$BRIDGE_HOME/handoff.local.json" before after
  before="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  out="$(python3 "$HELPER" post "$(base_url)" cm-prod "$A2A_SECRET" spoof)"
  smoke_assert_contains "$out" "STATUS=409" \
    "(b) ANTI-SPOOF: claim not corroborated by receiver's own status -> 409"
  after="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  smoke_assert_eq "$before" "$after" \
    "(b) ANTI-SPOOF: a spoofed/non-corroborated claim does NOT mutate the peer identity"
  # It must NOT have re-pointed cm-prod at the OTHER node.
  smoke_assert_not_contains "$after" "otherStableID" \
    "(b) ANTI-SPOOF: cm-prod was not re-pointed at a different node"
}

# --- (c) bad HMAC -> 401, no update ----------------------------------------
case_c_badhmac() {
  local out cfg="$BRIDGE_HOME/handoff.local.json" before after
  before="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  out="$(python3 "$HELPER" post "$(base_url)" cm-prod "$A2A_SECRET" badhmac)"
  smoke_assert_contains "$out" "STATUS=401" "(c) bad HMAC -> 401"
  after="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  smoke_assert_eq "$before" "$after" "(c) bad HMAC does not mutate the peer"
}

# --- (d) unknown/unpaired peer -> 403, no update ---------------------------
case_d_unpaired() {
  local out cfg="$BRIDGE_HOME/handoff.local.json"
  out="$(python3 "$HELPER" post "$(base_url)" ghost-peer "$A2A_SECRET" ok)"
  smoke_assert_contains "$out" "STATUS=403" \
    "(d) unknown/unpaired peer -> 403 (NOT a discovery channel)"
  smoke_assert_eq "<MISSING>" "$(cfg_get "$cfg" peer:ghost-peer.id)" \
    "(d) the unpaired peer was NOT created on disk"
}

# --- (e) replay (same message_id + body) -> idempotent, no double-update ----
case_e_replay() {
  local out cfg="$BRIDGE_HOME/handoff.local.json" before after
  before="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  # `replay` reuses the `ok` message_id; cm-prod is already identity-keyed from
  # case (a), so this is dedupe-duplicate (the original landed) -> 200 dup.
  out="$(python3 "$HELPER" post "$(base_url)" cm-prod "$A2A_SECRET" replay)"
  smoke_assert_contains "$out" "STATUS=200" "(e) replay -> idempotent 200"
  smoke_assert_contains "$out" '"duplicate": true' "(e) replay flagged duplicate"
  after="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  smoke_assert_eq "$before" "$after" "(e) replay does not double-update"
}

# --- (i) SECURITY: EMPTY message_id is rejected before dedupe/mutation -------
# A peer holding the shared secret signs a request with an EMPTY
# X-AGB-Message-Id (the empty id is baked into the canonical so the HMAC still
# verifies). Pre-fix (8148f12) this skipped dedupe AND let the bridge_id
# corroboration be bypassed. The receiver MUST reject it (400) with no
# mutation. (#1406 codex r1 SECURITY)
case_i_empty_message_id() {
  local out cfg="$BRIDGE_HOME/handoff.local.json" before after
  before="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  out="$(python3 "$HELPER" post "$(base_url)" cm-prod "$A2A_SECRET" emptyid)"
  smoke_assert_contains "$out" "STATUS=400" \
    "(i) SECURITY: signed request with EMPTY message_id -> 400 reject"
  smoke_assert_contains "$out" "message id required" \
    "(i) 400 reports message id required"
  after="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  smoke_assert_eq "$before" "$after" \
    "(i) SECURITY: empty-message_id request does NOT mutate the peer identity"
}

# --- (j) SECURITY: cross-peer bridge_id mismatch rejected unconditionally ----
# A peer signs a VALID, non-empty-id request whose body bridge_id claims a
# DIFFERENT peer (announcing about someone else). Pre-fix the bridge_id check
# was conditional on a non-empty id, but even with a non-empty id the check
# MUST fire (unconditional). The receiver MUST reject it (422) with no
# mutation. (#1406 codex r1 SECURITY)
case_j_bridge_id_mismatch() {
  local out cfg="$BRIDGE_HOME/handoff.local.json" before after
  before="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  out="$(python3 "$HELPER" post "$(base_url)" cm-prod "$A2A_SECRET" bridgemismatch)"
  smoke_assert_contains "$out" "STATUS=422" \
    "(j) SECURITY: signed body bridge_id != authenticated peer -> 422 reject"
  smoke_assert_contains "$out" "bridge_id does not match authenticated peer" \
    "(j) 422 reports bridge_id mismatch"
  after="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  smoke_assert_eq "$before" "$after" \
    "(j) SECURITY: a cross-peer announce does NOT mutate the peer identity"
}

# --- (g) the update never touched secret/allowlist/caps/other peers ---------
case_g_scope_preserved() {
  local cfg="$BRIDGE_HOME/handoff.local.json"
  smoke_assert_eq "$A2A_SECRET" "$(cfg_get "$cfg" peer:cm-prod.secret)" \
    "(g) cm-prod secret unchanged"
  smoke_assert_eq "reviewer,ops" "$(cfg_get "$cfg" peer:cm-prod.inbound_allowlist)" \
    "(g) cm-prod inbound_allowlist unchanged"
  smoke_assert_eq "262144" "$(cfg_get "$cfg" peer:cm-prod.caps.max_body_bytes)" \
    "(g) cm-prod caps unchanged"
  # The OTHER peer is byte-untouched (no node_id added, secret + allowlist kept).
  smoke_assert_eq "<MISSING>" "$(cfg_get "$cfg" peer:other-peer.node_id)" \
    "(g) other-peer identity NOT mutated by an announce about cm-prod"
  smoke_assert_eq "other-peer-secret-untouched-aaaaaaaaaaaaaaaaaaaaaa" \
    "$(cfg_get "$cfg" peer:other-peer.secret)" \
    "(g) other-peer secret untouched"
  smoke_assert_eq "someone" "$(cfg_get "$cfg" peer:other-peer.inbound_allowlist)" \
    "(g) other-peer allowlist untouched"
}

# --- (h) 0600 preserved on write -------------------------------------------
case_h_mode_preserved() {
  local cfg="$BRIDGE_HOME/handoff.local.json" mode
  mode="$(python3 -c "import os,sys;print(format(os.stat(sys.argv[1]).st_mode & 0o777, '04o'))" "$cfg")"
  smoke_assert_eq "0600" "$mode" "(h) config still 0600 after the apply"
}

# --- (f) remote_addr != peer's resolved IP -> 403 before body --------------
# Restart the receiver against a mock whose peer `cm-prod` resolves to a
# DIFFERENT IP (127.0.0.2) than the loopback client (127.0.0.1). The inbound
# remote_addr gate must reject BEFORE the body is read.
case_f_addr_mismatch() {
  local out cfg="$BRIDGE_HOME/handoff.local.json" before after dir2
  dir2="$SMOKE_TMP_ROOT/mock-bin-2"
  mkdir -p "$dir2"
  cat >"$dir2/tailscale" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "status" && "$2" == "--json" ]]; then
  cat <<'JSON'
{
  "Self": { "ID": "selfStableID123", "HostName": "my-host",
            "DNSName": "my-host.example-tailnet.ts.net.",
            "TailscaleIPs": ["127.0.0.1"], "Online": true, "OS": "linux" },
  "Peer": {
    "nodekey:cm": { "ID": "peerStableID999",
      "HostName": "cm-prod-agentworkflow-vm01",
      "DNSName": "cm-prod-agentworkflow-vm01.example-tailnet.ts.net.",
      "TailscaleIPs": ["127.0.0.2"], "Online": true, "OS": "linux" }
  }
}
JSON
  exit 0
fi
if [[ "$1" == "ip" ]]; then printf '127.0.0.1\n'; exit 0; fi
exit 2
MOCK
  chmod +x "$dir2/tailscale"
  # Stop the running receiver and start a fresh one with the mismatch mock.
  kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
  wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  HANDOFFD_PID=""
  A2A_PORT="$(python3 "$HELPER" free-port)"
  write_a2a_config "$A2A_PORT"
  BRIDGE_A2A_RECONCILE_INTERVAL=0 \
  BRIDGE_A2A_ALLOW_TEST_BIND=1 \
  BRIDGE_A2A_TAILSCALE_CLI="$dir2/tailscale" \
    python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" serve \
      --config "$BRIDGE_HOME/handoff.local.json" \
      >"$SMOKE_TMP_ROOT/handoffd2.log" 2>&1 &
  HANDOFFD_PID=$!
  local waited=0
  while (( waited < 50 )); do
    if python3 "$HELPER" wait-port "$A2A_PORT" 2>/dev/null; then break; fi
    sleep 0.1; waited=$((waited + 1))
  done
  # Capture the baseline AFTER the fresh write_a2a_config (so it reflects the
  # restarted config — a fresh peer with no node_id yet). The 403-rejected
  # request must leave it byte-identical.
  before="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  out="$(BRIDGE_A2A_TAILSCALE_CLI="$dir2/tailscale" \
    python3 "$HELPER" post "$(base_url)" cm-prod "$A2A_SECRET" ok)"
  smoke_assert_contains "$out" "STATUS=403" \
    "(f) remote_addr != peer's resolved IP -> 403 (rejected before body)"
  smoke_assert_contains "$out" "source address mismatch" \
    "(f) 403 reports source address mismatch"
  after="$(cfg_get "$cfg" peer:cm-prod.node_id)"
  smoke_assert_eq "$before" "$after" "(f) addr-mismatch does not mutate the peer"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  CFG_HELPER="$SMOKE_TMP_ROOT/cfg-get.py"
  write_cfg_helper

  smoke_run "start loopback receiver (mock tailscale)"   start_receiver
  smoke_run "(a) valid announce applies identity"        case_a_apply
  smoke_run "(b) ANTI-SPOOF: non-corroborated rejected"  case_b_spoof_rejected
  smoke_run "(c) bad HMAC -> 401"                         case_c_badhmac
  smoke_run "(d) unpaired peer -> 403"                   case_d_unpaired
  smoke_run "(e) replay -> idempotent, no double-update" case_e_replay
  smoke_run "(i) SECURITY: empty message_id -> 400"      case_i_empty_message_id
  smoke_run "(j) SECURITY: bridge_id mismatch -> 422"    case_j_bridge_id_mismatch
  smoke_run "(g) scope: secret/allowlist/caps/peers kept" case_g_scope_preserved
  smoke_run "(h) 0600 preserved on write"                case_h_mode_preserved
  smoke_run "(f) remote_addr mismatch -> 403 before body" case_f_addr_mismatch

  smoke_log "PASS"
}

main "$@"
