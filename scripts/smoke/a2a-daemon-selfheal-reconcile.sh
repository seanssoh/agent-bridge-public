#!/usr/bin/env bash
# scripts/smoke/a2a-daemon-selfheal-reconcile.sh — A2A daemon self-heal
# reconcile smoke (P-self-heal phase 1, #1403 / setup-wizard design §9.3/§9.4).
#
# Verifies the RUNNING receiver self-heals without a manual restart:
#   (a) local-IP change → reconcile rebinds to the NEW in-set IP.
#   (b) rebind candidate NOT in `tailscale ip` set → REFUSED; keeps the old
#       bind (THE bind-proof-preserved-under-reconcile security assertion).
#   (c) Tailscale unavailable during reconcile → keeps serving on the current
#       bind; no crash; never an unproven bind.
#   (d) config hot-reload picks up an ADDED peer without a restart (the live
#       server.cfg reflects the new peer + its allowlist).
#   (e) malformed config reload → keeps last-good config; records a warning
#       (config_error); the allowlist / peer table is NOT dropped.
#
# Uses a MOCK `tailscale` CLI (BRIDGE_A2A_TAILSCALE_CLI), the same pattern as
# a2a-tailscale-identity-resolve / the 1118 engine-path stub, plus the
# loopback test-bind escape hatch (BRIDGE_A2A_ALLOW_TEST_BIND=1) so the
# rebind actually binds a real socket. The real tailnet is never touched.
# macOS-runnable (pure python3 + a bash mock binary).
#
# The bind-proof cases (b)+(c) make the reload `listen` resolve to a
# NON-loopback candidate so the genuine fail-closed proof runs under
# reconcile (the loopback escape hatch only applies to loopback addresses) —
# that is how the smoke asserts the proof is preserved across a reconcile.

set -euo pipefail

SMOKE_NAME="a2a-daemon-selfheal-reconcile"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/a2a-daemon-selfheal-reconcile-helper.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# A peer with a real secret so the secret gate passes on its own (we keep the
# proof honest — no insecure-bypass envs).
PEER_A='{"id":"peer-a","address":"127.0.0.50","secret":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","inbound_allowlist":["agent-1"]}'
PEER_B='{"id":"peer-b","address":"127.0.0.51","secret":"yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy","inbound_allowlist":["agent-2"]}'

# Mock `tailscale` for the rebind happy-path: `ip` lists two loopback
# addresses (the in-set bind candidates) and `status --json` resolves the
# self HostName `my-host` to 127.0.0.3 (the NEW bind).
write_mock_tailscale_rebind() {
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
    "TailscaleIPs": ["127.0.0.3"],
    "Online": true, "OS": "linux"
  },
  "Peer": {}
}
JSON
  exit 0
fi
if [[ "$1" == "ip" ]]; then
  printf '127.0.0.2\n127.0.0.3\n'
  exit 0
fi
exit 2
MOCK
  chmod +x "$dir/tailscale"
}

# Mock whose self HostName `bad-host` resolves to a NON-loopback IP NOT in the
# `ip` set — the bind proof must REJECT it under reconcile (keep the old bind).
write_mock_tailscale_refuse() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/tailscale" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "status" && "$2" == "--json" ]]; then
  cat <<'JSON'
{
  "Self": {
    "ID": "selfStableID123",
    "HostName": "bad-host",
    "DNSName": "bad-host.example-tailnet.ts.net.",
    "TailscaleIPs": ["100.99.99.99"],
    "Online": true, "OS": "linux"
  },
  "Peer": {}
}
JSON
  exit 0
fi
if [[ "$1" == "ip" ]]; then
  printf '127.0.0.2\n'
  exit 0
fi
exit 2
MOCK
  chmod +x "$dir/tailscale"
}

# Mock that is UNAVAILABLE: every invocation exits non-zero so the resolver
# raises TailscaleUnavailable. The reconcile must keep the current bind.
write_mock_tailscale_unavailable() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/tailscale" <<'MOCK'
#!/usr/bin/env bash
echo "tailscaled not running" >&2
exit 1
MOCK
  chmod +x "$dir/tailscale"
}

# Write a 0600 config with the given listen + peers JSON fragments.
write_config() {
  local path="$1" listen_json="$2" peers_json="$3"
  cat >"$path" <<JSON
{
  "bridge_id": "test-self",
  "listen": ${listen_json},
  "peers": ${peers_json}
}
JSON
  chmod 0600 "$path"
}

# --- (a) local-IP change → reconcile rebinds to the new in-set IP ---
case_a_rebind() {
  local dir="$SMOKE_TMP_ROOT/mock-a" cfg="$SMOKE_TMP_ROOT/handoff-a.json" got
  write_mock_tailscale_rebind "$dir"
  # Reload config keys listen on the self HostName, which the mock resolves to
  # 127.0.0.3 (the NEW bind). The server starts on 127.0.0.2.
  write_config "$cfg" '{"tailscale_name":"my-host","port":8799}' "[$PEER_A]"
  got="$(BRIDGE_A2A_TAILSCALE_CLI="$dir/tailscale" python3 "$HELPER" rebind 127.0.0.2 8799 "$cfg")"
  smoke_assert_eq "REBIND:127.0.0.3:8799" "$got" \
    "(a) local-IP change rebinds to the new in-set IP"
}

# --- (b) rebind candidate NOT in `tailscale ip` set → REFUSED (keeps old) ---
# THE bind-proof-preserved-under-reconcile assertion: resolution produces a
# candidate (100.99.99.99) but the unchanged fail-closed proof rejects it
# because it is not in `tailscale ip` — the reconcile keeps the current bind
# rather than binding an unproven address.
case_b_proof_preserved() {
  local dir="$SMOKE_TMP_ROOT/mock-b" cfg="$SMOKE_TMP_ROOT/handoff-b.json" got
  write_mock_tailscale_refuse "$dir"
  write_config "$cfg" '{"tailscale_name":"bad-host","port":8799}' "[$PEER_A]"
  got="$(BRIDGE_A2A_TAILSCALE_CLI="$dir/tailscale" python3 "$HELPER" rebind 127.0.0.2 8799 "$cfg")"
  smoke_assert_eq "BINDKEEP:bind_not_tailnet" "$got" \
    "(b) SECURITY: rebind candidate not in 'tailscale ip' is REFUSED; old bind kept (proof preserved under reconcile)"
}

# --- (c) Tailscale unavailable during reconcile → keep current bind, no crash ---
case_c_unavailable() {
  local dir="$SMOKE_TMP_ROOT/mock-c" cfg="$SMOKE_TMP_ROOT/handoff-c.json" got
  write_mock_tailscale_unavailable "$dir"
  # Identity-keyed listen forces a resolve attempt, which fails closed.
  write_config "$cfg" '{"tailscale_name":"my-host","port":8799}' "[$PEER_A]"
  got="$(BRIDGE_A2A_TAILSCALE_CLI="$dir/tailscale" python3 "$HELPER" rebind 127.0.0.2 8799 "$cfg")"
  smoke_assert_eq "BINDKEEP:tailscale_unavailable" "$got" \
    "(c) Tailscale unavailable during reconcile keeps current bind; no crash, no unproven bind"
}

# --- (d) config hot-reload picks up an ADDED peer without a restart ---
case_d_hot_reload_add() {
  local dir="$SMOKE_TMP_ROOT/mock-d" cfg="$SMOKE_TMP_ROOT/handoff-d.json" out reload_line add_line
  write_mock_tailscale_rebind "$dir"
  # Raw loopback listen so the bind is a no-op; we only assert the hot-reload
  # sees the second peer (peer-b) added to the live table.
  write_config "$cfg" '{"address":"127.0.0.2","port":8799}' "[$PEER_A,$PEER_B]"
  out="$(BRIDGE_A2A_TAILSCALE_CLI="$dir/tailscale" python3 "$HELPER" config 127.0.0.2 8799 "$cfg" peer-b)"
  reload_line="$(printf '%s\n' "$out" | grep '^CFG' | head -1)"
  add_line="$(printf '%s\n' "$out" | grep '^CFGADD' | head -1)"
  smoke_assert_eq "CFGRELOAD:ok" "$reload_line" \
    "(d) config hot-reload succeeds"
  smoke_assert_eq "CFGADD:present" "$add_line" \
    "(d) hot-reload picks up the added peer without a restart"
}

# --- (e) malformed config reload → keeps last-good, records a warning ---
case_e_malformed_keeps_last_good() {
  local dir="$SMOKE_TMP_ROOT/mock-e" cfg="$SMOKE_TMP_ROOT/handoff-e.json" out reload_line add_line
  write_mock_tailscale_rebind "$dir"
  printf '{ this is not valid json' >"$cfg"
  chmod 0600 "$cfg"
  out="$(BRIDGE_A2A_TAILSCALE_CLI="$dir/tailscale" python3 "$HELPER" config 127.0.0.2 8799 "$cfg" peer-a)"
  reload_line="$(printf '%s\n' "$out" | grep '^CFG' | head -1)"
  add_line="$(printf '%s\n' "$out" | grep '^CFGADD' | head -1)"
  smoke_assert_eq "CFGKEPT:config_parse" "$reload_line" \
    "(e) malformed config reload keeps last-good config (config_parse error)"
  # The start config carries peer-a; a kept last-good config must STILL have
  # peer-a (the allowlist / peer table was not dropped to a half-parsed value).
  smoke_assert_eq "CFGADD:present" "$add_line" \
    "(e) last-good allowlist / peer table is preserved after a malformed reload"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"

  # The rebind cases bind a real loopback socket via the test-bind escape
  # hatch; the bind PROOF still runs for non-loopback resolved candidates,
  # which is how (b)+(c) assert the proof is preserved under reconcile.
  export BRIDGE_A2A_ALLOW_TEST_BIND=1

  smoke_run "(a) local-IP change rebinds"                 case_a_rebind
  smoke_run "(b) bind proof preserved (security)"         case_b_proof_preserved
  smoke_run "(c) tailscale unavailable -> keep bind"      case_c_unavailable
  smoke_run "(d) config hot-reload adds a peer"           case_d_hot_reload_add
  smoke_run "(e) malformed reload keeps last-good"        case_e_malformed_keeps_last_good

  unset BRIDGE_A2A_ALLOW_TEST_BIND
  smoke_log "PASS"
}

main "$@"
