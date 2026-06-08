#!/usr/bin/env bash
# scripts/smoke/v0165-l1-stable-addr.sh — Lane-1 stable-addr reconcile adapter
# (#1705, v0.16.5 A2A Rooms zero-touch mesh).
#
# Lane 1 fills the `stable_local_addr(transport, cfg)` adapter SEAM that Lane 0
# defined: the reconcile `stable-addr` step detects the node's STABLE substrate
# listen address (Tailscale: identity-keyed `tailscale ip`; cloudflare-warp-mesh:
# a real utun/Mesh IP in 10.128.0.0/16 on a live local interface) and, when it
# has drifted from the configured `listen.address`, PROPOSES the stable addr as
# the new desired config (written atomically). The ACTUAL rebind still routes
# through resolve_bind() — this step only proposes config. This smoke pins the
# adapter contract so a later lane cannot silently regress it.
#
# Asserted (all against an ISOLATED config via BRIDGE_A2A_CONFIG → a tmpdir
# file; all Python driving via the *-helper.py file-as-argv sidecar, footgun
# #11: NO heredoc-stdin). The detector probe seams are MOCKED so the REAL
# adapter code path runs with no real Tailscale/WARP install:
#   - BRIDGE_A2A_IFACE_ADDRS  mocks the WARP detector's live interface set.
#   - BRIDGE_A2A_TAILSCALE_CLI mocks the `tailscale` CLI (or an absent path).
#
#   (a) CONVERGED — listen.address already == the observed stable addr → no-op
#       (idempotent; the config is NOT mutated).
#   (b) CHANGED + desired-config-updated — when they differ, the written config
#       holds the new addr; a re-run is then converged (idempotent).
#   (c) ERROR (NOT a bad-addr return) — when no stable address is provable, the
#       step returns step_error and the config is left UNCHANGED (fail-closed).
#   (d) ACTIVE-TRANSPORT-ONLY — the tailscale path never inspects WARP utun and
#       the WARP path never shells `tailscale` (a poisoned ts CLI is never run).
#   (e) FAIL-CLOSED — an address not on any local interface / not in the
#       `tailscale ip` set is NEVER returned (a bad-addr return is a defect).
#
# Run green on /opt/homebrew/bin/bash (macOS) and Linux CI bash.

set -euo pipefail

SMOKE_NAME="v0165-l1-stable-addr"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
HELPER="$REPO_ROOT/scripts/smoke/${SMOKE_NAME}-helper.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_assert_file_exists "$HELPER" "lane-1 helper present"

# Isolated BRIDGE_HOME — config files land under the tmp root, never the
# operator's live runtime.
smoke_setup_bridge_home "$SMOKE_NAME"

CFG_DIR="$SMOKE_TMP_ROOT/l1cfg"
mkdir -p "$CFG_DIR"

# --- mock `tailscale` CLI: emits a deterministic identity-keyed IP set ---
# `tailscale ip` prints the node's own addresses (IPv4 first), exactly the set
# the receiver bind proof binds against. The detector reuses this path.
TS_MOCK="$SMOKE_TMP_ROOT/tailscale-mock"
cat >"$TS_MOCK" <<'EOF'
#!/usr/bin/env bash
# Mock `tailscale`. Only `ip` is exercised by the stable-addr detector.
if [[ "${1:-}" == "ip" ]]; then
  echo "100.64.0.7"
  echo "fd7a:115c:a1e0::7"
  exit 0
fi
echo "mock tailscale: unexpected args: $*" >&2
exit 2
EOF
chmod 0755 "$TS_MOCK"

# --- poisoned `tailscale` CLI: touches a sentinel + exits non-zero IF run ---
# Used by the WARP isolation case to PROVE the WARP branch never shells it.
TS_SENTINEL="$SMOKE_TMP_ROOT/ts-was-shelled"
TS_POISON="$SMOKE_TMP_ROOT/tailscale-poison"
cat >"$TS_POISON" <<EOF
#!/usr/bin/env bash
touch "$TS_SENTINEL"
echo "BUG: a WARP node shelled tailscale" >&2
exit 99
EOF
chmod 0755 "$TS_POISON"

# Write an isolated A2A config (mode 0600 — load_config refuses group/world
# readable). \$1 = path, \$2 = transport-block JSON (or empty), \$3 = listen addr.
write_cfg() {
  local path="$1" transport="$2" addr="$3"
  local tblock=""
  [[ -n "$transport" ]] && tblock="\"transport\": $transport,"
  cat >"$path" <<EOF
{
  "bridge_id": "node-1",
  ${tblock}
  "listen": { "address": "${addr}", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$path"
}

run_helper() {
  # \$1 = subcommand, \$2 = cfg path; remaining env (iface/ts CLI) set by caller.
  python3 "$HELPER" "$1" "$REPO_ROOT" "$2"
}

smoke_assert_file_absent() {
  local path="$1" context="$2"
  [[ ! -e "$path" ]] || smoke_fail "$context: expected file to be absent: $path"
}

# Write a config with a MALFORMED/unknown transport.kind (load_config tolerates
# it — only transport_kind() hard-errors). \$1 = path, \$2 = listen addr.
write_malformed_cfg() {
  local path="$1" addr="$2"
  cat >"$path" <<EOF
{
  "bridge_id": "node-1",
  "transport": { "kind": "bogus-unknown-transport" },
  "listen": { "address": "${addr}", "port": 8787 },
  "peers": []
}
EOF
  chmod 0600 "$path"
}

# === (b) WARP drift → changed + config updated → idempotent ===
warp_changed() {
  local cfg="$CFG_DIR/warp-drift.json"
  write_cfg "$cfg" '{ "kind": "cloudflare-warp-mesh" }' "10.11.10.211"
  local out
  out="$(BRIDGE_A2A_CONFIG="$cfg" \
        BRIDGE_A2A_IFACE_ADDRS="10.128.0.5 192.168.1.40" \
        run_helper warp-changed "$cfg")"
  smoke_assert_contains "$out" "OK warp-changed" \
    "(b) WARP drift -> step_changed, desired config written to the utun addr, re-run idempotent"
}

# === (a) WARP already converged → no-op (config unchanged) ===
warp_converged() {
  local cfg="$CFG_DIR/warp-conv.json"
  write_cfg "$cfg" '{ "kind": "cloudflare-warp-mesh" }' "10.128.0.5"
  local out
  out="$(BRIDGE_A2A_CONFIG="$cfg" \
        BRIDGE_A2A_IFACE_ADDRS="10.128.0.5 192.168.1.40" \
        run_helper warp-converged "$cfg")"
  smoke_assert_contains "$out" "OK warp-converged" \
    "(a) WARP already at stable addr -> step_converged (idempotent, config not mutated)"
}

# === (c)+(e) WARP no stable addr on any interface → step_error, fail-closed ===
warp_error() {
  local cfg="$CFG_DIR/warp-err.json"
  write_cfg "$cfg" '{ "kind": "cloudflare-warp-mesh" }' "10.11.10.211"
  # The live interface set has NO 10.128.x utun addr -> unprovable.
  local out
  out="$(BRIDGE_A2A_CONFIG="$cfg" \
        BRIDGE_A2A_IFACE_ADDRS="192.168.1.40 100.64.0.1" \
        run_helper warp-error "$cfg")"
  smoke_assert_contains "$out" "OK warp-error" \
    "(c)+(e) WARP addr not on any local interface -> step_error (no bad-addr return; config unchanged)"
}

# === (b) Tailscale drift → changed, addr from `tailscale ip` not WARP utun ===
ts_changed() {
  local cfg="$CFG_DIR/ts-drift.json"
  write_cfg "$cfg" '' "1.2.3.4"
  # An iface override carrying a WARP utun addr is PRESENT but must be IGNORED
  # on the tailscale branch (active-transport-only).
  local out
  out="$(BRIDGE_A2A_CONFIG="$cfg" \
        BRIDGE_A2A_TAILSCALE_CLI="$TS_MOCK" \
        BRIDGE_A2A_IFACE_ADDRS="10.128.0.5" \
        run_helper ts-changed "$cfg")"
  smoke_assert_contains "$out" "OK ts-changed" \
    "(b)+(d) Tailscale drift -> step_changed to the \`tailscale ip\` addr (never a WARP utun addr)"
}

# === (a) Tailscale already converged → no-op ===
ts_converged() {
  local cfg="$CFG_DIR/ts-conv.json"
  write_cfg "$cfg" '' "100.64.0.7"
  local out
  out="$(BRIDGE_A2A_CONFIG="$cfg" \
        BRIDGE_A2A_TAILSCALE_CLI="$TS_MOCK" \
        run_helper ts-converged "$cfg")"
  smoke_assert_contains "$out" "OK ts-converged" \
    "(a) Tailscale already at \`tailscale ip\` addr -> step_converged (config not mutated)"
}

# === (c)+(e) Tailscale CLI absent → step_error, fail-closed ===
ts_error() {
  local cfg="$CFG_DIR/ts-err.json"
  write_cfg "$cfg" '' "1.2.3.4"
  local out
  out="$(BRIDGE_A2A_CONFIG="$cfg" \
        BRIDGE_A2A_TAILSCALE_CLI="$SMOKE_TMP_ROOT/no-such-tailscale" \
        run_helper ts-error "$cfg")"
  smoke_assert_contains "$out" "OK ts-error" \
    "(c)+(e) absent tailscale CLI -> step_error (fail-closed; config unchanged)"
}

# === (d) active-transport-only: WARP branch NEVER shells tailscale ===
isolation_warp_never_shells_ts() {
  local cfg="$CFG_DIR/iso.json"
  write_cfg "$cfg" '{ "kind": "cloudflare-warp-mesh" }' "10.128.0.9"
  rm -f "$TS_SENTINEL"
  local out
  # Point the tailscale CLI at the POISON mock: if the WARP branch shelled it,
  # the sentinel file would appear and the helper would FAIL.
  out="$(BRIDGE_A2A_CONFIG="$cfg" \
        BRIDGE_A2A_TAILSCALE_CLI="$TS_POISON" \
        L1_TS_SENTINEL="$TS_SENTINEL" \
        BRIDGE_A2A_IFACE_ADDRS="10.128.0.9 192.168.1.5" \
        run_helper isolation "$cfg")"
  smoke_assert_contains "$out" "OK isolation" \
    "(d) WARP branch resolves WITHOUT shelling tailscale (active-transport-only)"
  smoke_assert_file_absent "$TS_SENTINEL" \
    "(d) tailscale CLI sentinel never written (proof the WARP path never ran it)"
}

# === (c)+(d) malformed transport.kind under the orchestrator's guessed-tailscale
# fallback must NOT detect+persist (codex [P1] regression guard) ===
malformed_transport_no_guess() {
  local cfg="$CFG_DIR/malformed.json"
  write_malformed_cfg "$cfg" "1.2.3.4"
  rm -f "$TS_SENTINEL"
  local out
  # The poisoned ts CLI proves the detector never ran; the guessed arg is
  # "tailscale" (what reconcile_once forces after transport_kind raises).
  out="$(BRIDGE_A2A_CONFIG="$cfg" \
        BRIDGE_A2A_TAILSCALE_CLI="$TS_POISON" \
        L1_TS_SENTINEL="$TS_SENTINEL" \
        run_helper malformed "$cfg")"
  smoke_assert_contains "$out" "OK malformed" \
    "(c)+(d) malformed transport.kind -> step_error (no detect/persist under a guessed tailscale)"
  smoke_assert_file_absent "$TS_SENTINEL" \
    "(d) tailscale CLI never shelled under a guessed transport (config-derived kind validated)"
}

warp_changed
warp_converged
warp_error
ts_changed
ts_converged
ts_error
isolation_warp_never_shells_ts
malformed_transport_no_guess

smoke_log "ALL CHECKS PASSED ($SMOKE_NAME)"
