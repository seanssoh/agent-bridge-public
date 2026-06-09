#!/usr/bin/env bash
# scripts/smoke/v0165-l6-net-status-v2.sh — `agb a2a net-status` v2 control-loop
# status window (#1708, v0.16.5 mesh Lane 6).
#
# #1708 ADDITIVELY enriches the #1697 read-only `agb a2a net-status [--json]`
# snapshot with a control-loop status window so a human can confirm at a glance
# that the daemon's reconcile loop is converging — WITHOUT reading config across
# nodes. STRICTLY additive: every v1 #1697 field name + shape stays byte-
# identical; the 8 v2 field groups (own_stable_address / room_leader /
# allowed_agents / room_roster / tunnel_freshness / per_peer / reconcile /
# roster_epoch_converged) are added alongside.
#
# This smoke proves the contract from the issue + the wave brief:
#   (1) ADDITIVE — net-status --json carries BOTH the v1 #1697 keys (same shape)
#       AND the 8 v2 keys. The v2 per_peer FSM never leaks into the v1 `peers`.
#   (2) ZERO-MUTATION / NON-CREATING — run net-status against a BRIDGE_HOME where
#       reconcile.db + rooms.db do NOT exist; assert the reconcile block is all-
#       `unknown` (+ last_tick null) AND neither reconcile.db NOR rooms.db is
#       created afterward (the #1697/#1708 observable-not-operable invariant).
#   (3) NO SECRETS — a secret-bearing config (listen/peer secrets + a room token
#       in the seeded rooms.db) never leaks a key/token/seed into the JSON
#       output (addresses / ports / agent NAMES / epochs / ages / counts only).
#   (4) ACTIVE-TRANSPORT-ONLY — own_stable_address + tunnel_freshness probe ONLY
#       the configured transport; a WARP config with a loud fake `tailscale` on
#       PATH never executes tailscale.
#   (5) POPULATED — with a seeded reconcile.db (peer FSM + step attempts) and a
#       seeded rooms.db, net-status surfaces per_peer state=down, the reconcile
#       auto-recovery pressure (tunnel-bounce pending=1), and the room leader +
#       epoch + roster_epoch_converged — all read-only.
#
# Everything is exercised against an ISOLATED BRIDGE_HOME with the BRIDGE_A2A_*
# db overrides pointed at the smoke temp root — no real WARP/Tailscale install,
# no live A2A state. Footgun #11: all Python driving is via the *-helper.py
# file-as-argv sidecar. macOS: run with /opt/homebrew/bin/bash (Bash 5.x).

set -euo pipefail

SMOKE_NAME="v0165-l6-net-status-v2"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/v0165-l6-net-status-v2-helper.py"
A2A_CLI="$SMOKE_REPO_ROOT/bridge-a2a.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

helper() { python3 "$HELPER" "$@"; }

write_tailscale_config_with_secrets() {
  local path="$1"
  cat >"$path" <<'EOF'
{
  "bridge_id": "ts-node",
  "transport": { "kind": "tailscale" },
  "listen": { "address": "100.64.0.5", "port": 8787, "secret": "LISTENSECRETZZZ" },
  "peers": [
    { "id": "peer-a", "address": "100.64.0.6", "node_id": "n-a",
      "inbound_allowlist": ["agent-x", "agent-y"],
      "secret": "PEERSECRETZZZ", "send_secret": "SENDSECRETZZZ" }
  ]
}
EOF
  chmod 0600 "$path"
}

write_warp_config() {
  local path="$1"
  cat >"$path" <<'EOF'
{
  "bridge_id": "warp-node",
  "transport": { "kind": "cloudflare-warp-mesh" },
  "listen": { "address": "100.96.0.5", "port": 8787 },
  "peers": [ { "id": "peer-w", "address": "100.96.0.6", "node_id": "n-w" } ]
}
EOF
  chmod 0600 "$path"
}

# A fake `tailscale` that fails LOUD (sentinel + nonzero) if ever executed.
write_loud_fake_tailscale() {
  local dir="$SMOKE_TMP_ROOT/fakebin"
  mkdir -p "$dir"
  local sentinel="$SMOKE_TMP_ROOT/tailscale-was-invoked"
  cat >"$dir/tailscale" <<EOF
#!/usr/bin/env bash
echo "FAKE_TAILSCALE_INVOKED args=\$*" >&2
printf 'invoked\n' >>"$sentinel"
exit 99
EOF
  chmod 0755 "$dir/tailscale"
  printf '%s\n%s\n' "$dir" "$sentinel"
}

# === (1) additive: v1 keys (same shape) + v2 keys both present ===============
check_additive_shape() {
  local cfg="$SMOKE_TMP_ROOT/add.json"
  write_tailscale_config_with_secrets "$cfg"
  local rdb="$SMOKE_TMP_ROOT/no-reconcile.db"   # does NOT exist
  local out
  out="$(helper run-net-status "$cfg" "$rdb" "")"
  echo "$out" | helper has-keys \
    "bridge_id,transport,listen,receiver,substrate,peers,rooms,own_stable_address,room_leader,allowed_agents,room_roster,tunnel_freshness,per_peer,reconcile,roster_epoch_converged" \
    >/dev/null \
    && smoke_log "ok-all-keys" \
    || smoke_fail "(1) net-status --json missing a v1 or v2 top-level key; got: $out"
  echo "$out" | helper v1-shape-unchanged >/dev/null \
    && smoke_log "ok-v1-shape" \
    || smoke_fail "(1) v1 #1697 field shape changed (additive contract broken); got: $out"
}

# === (2) zero-mutation / non-creating: no reconcile.db / rooms.db created ======
check_zero_mutation_non_creating() {
  local cfg="$SMOKE_TMP_ROOT/nm.json"
  write_tailscale_config_with_secrets "$cfg"
  local rdb="$SMOKE_TMP_ROOT/nm-reconcile.db"
  local roomsdb="$SMOKE_TMP_ROOT/nm-rooms.db"
  smoke_assert_eq "absent" "$([[ -e "$rdb" ]] && echo present || echo absent)" \
    "(2) precondition: reconcile.db absent before net-status"
  smoke_assert_eq "absent" "$([[ -e "$roomsdb" ]] && echo present || echo absent)" \
    "(2) precondition: rooms.db absent before net-status"
  local out
  out="$(helper run-net-status "$cfg" "$rdb" "$roomsdb")"
  echo "$out" | helper reconcile-all-unknown >/dev/null \
    && smoke_log "ok-reconcile-unknown" \
    || smoke_fail "(2) reconcile block not all-unknown on a missing store; got: $out"
  # THE non-creating proof: net-status must NOT have materialized either store.
  smoke_assert_eq "absent" "$([[ -e "$rdb" ]] && echo present || echo absent)" \
    "(2) NON-CREATING: net-status did NOT create reconcile.db"
  smoke_assert_eq "absent" "$([[ -e "$roomsdb" ]] && echo present || echo absent)" \
    "(2) NON-CREATING: net-status did NOT create rooms.db"
}

# === (3) no secrets leak into the JSON output ================================
check_no_secrets() {
  local cfg="$SMOKE_TMP_ROOT/sec.json"
  write_tailscale_config_with_secrets "$cfg"
  # A seeded rooms.db carries an invite-token-derived seed/hash internally; the
  # smoke proves NONE of those secret materials reach the snapshot. We seed with
  # a sentinel room id only; the rooms.db hash columns are never surfaced.
  local roomsdb="$SMOKE_TMP_ROOT/sec-rooms.db"
  helper seed-rooms-db "$roomsdb" "room-sec1" "agent-x" "node-1" \
    "agent-x:node-1:leader;agent-y:node-2:member" >/dev/null
  local rdb="$SMOKE_TMP_ROOT/sec-reconcile.db"
  helper seed-reconcile-db "$rdb" >/dev/null
  local out
  out="$(helper run-net-status "$cfg" "$rdb" "$roomsdb")"
  printf '%s' "$out" | helper no-secrets \
    "LISTENSECRETZZZ,PEERSECRETZZZ,SENDSECRETZZZ,invite_token_sha256,invite_key_seed" \
    >/dev/null \
    && smoke_log "ok-no-secrets" \
    || smoke_fail "(3) a secret/token/seed leaked into net-status v2 output; got: $out"
}

# === (4) active-transport-only: WARP config never executes tailscale =========
check_active_transport_only() {
  local cfg="$SMOKE_TMP_ROOT/warp.json"
  write_warp_config "$cfg"
  local fake dir sentinel
  fake="$(write_loud_fake_tailscale)"
  dir="$(printf '%s' "$fake" | sed -n '1p')"
  sentinel="$(printf '%s' "$fake" | sed -n '2p')"
  rm -f "$sentinel"
  local out
  out="$(PATH="$dir:$PATH" \
         BRIDGE_A2A_TAILSCALE_CLI="$dir/tailscale" \
         BRIDGE_A2A_WARP_CLI="$SMOKE_TMP_ROOT/no-warp-cli" \
         helper run-net-status "$cfg" "" "")"
  echo "$out" | helper field "own_stable_address.transport" "cloudflare-warp-mesh" >/dev/null \
    || smoke_fail "(4) own_stable_address.transport != cloudflare-warp-mesh; got: $out"
  echo "$out" | helper field "tunnel_freshness.transport" "cloudflare-warp-mesh" >/dev/null \
    || smoke_fail "(4) tunnel_freshness.transport != cloudflare-warp-mesh; got: $out"
  smoke_assert_not_contains "$(cat "$sentinel" 2>/dev/null || true)" "invoked" \
    "(4) ACTIVE-TRANSPORT-ONLY: a WARP-mesh net-status v2 NEVER executes tailscale"
  smoke_assert_not_contains "$out" "FAKE_TAILSCALE_INVOKED" \
    "(4) no fake-tailscale output bled into the v2 snapshot"
}

# === (5) populated reconcile.db + rooms.db surfaces FSM + epoch + recovery ====
check_populated() {
  local cfg="$SMOKE_TMP_ROOT/pop.json"
  write_tailscale_config_with_secrets "$cfg"
  local rdb="$SMOKE_TMP_ROOT/pop-reconcile.db"
  helper seed-reconcile-db "$rdb" >/dev/null
  local roomsdb="$SMOKE_TMP_ROOT/pop-rooms.db"
  helper seed-rooms-db "$roomsdb" "room-pop1" "agent-x" "node-1" \
    "agent-x:node-1:leader;agent-y:node-2:member" >/dev/null
  local out
  out="$(helper run-net-status "$cfg" "$rdb" "$roomsdb")"
  # per_peer surfaces the seeded down FSM state.
  echo "$out" | helper per-peer-state "peer-a" "down" >/dev/null \
    && smoke_log "ok-per-peer-down" \
    || smoke_fail "(5) per_peer[peer-a].state != down (FSM not surfaced); got: $out"
  # reconcile auto-recovery: tunnel-bounce path has 1 pending retry (seeded error).
  echo "$out" | helper field "reconcile.auto_recovery.tunnel_bounce_pending_retries" "1" >/dev/null \
    && smoke_log "ok-tunnel-bounce-pending" \
    || smoke_fail "(5) reconcile.auto_recovery.tunnel_bounce_pending_retries != 1; got: $out"
  # last_tick advanced now the store is populated.
  echo "$out" | helper field "reconcile.last_tick_ts" "None" >/dev/null \
    && smoke_fail "(5) reconcile.last_tick_ts still None on a populated store; got: $out" \
    || smoke_log "ok-last-tick-set"
  # room leader + epoch surfaced from the seeded rooms.db.
  echo "$out" | helper field "room_leader.0.room_id" "room-pop1" >/dev/null \
    || smoke_fail "(5) room_leader[0].room_id != room-pop1; got: $out"
  echo "$out" | helper field "room_leader.0.leader_agent" "agent-x" >/dev/null \
    || smoke_fail "(5) room_leader[0].leader_agent != agent-x; got: $out"
  echo "$out" | helper field "room_roster.0.epoch" "2" >/dev/null \
    || smoke_fail "(5) room_roster[0].epoch != 2; got: $out"
  echo "$out" | helper field "roster_epoch_converged.0.converged" "True" >/dev/null \
    && smoke_log "ok-epoch-converged" \
    || smoke_fail "(5) roster_epoch_converged[0].converged != True (applied==room epoch); got: $out"
  # allowed_agents surfaces the peer inbound_allowlist + room members (names).
  echo "$out" | helper field "allowed_agents.inbound_allowlist_per_peer.0.peer" "peer-a" >/dev/null \
    || smoke_fail "(5) allowed_agents per-peer entry missing; got: $out"
}

# === (5b) degrade-safe: a wedged rooms CLI (TimeoutExpired) never raises =======
check_rooms_cli_wedged_degrades() {
  # Unit: the v2 readers (_netstat_rooms_cli/_netstat_rooms_v2) AND the v1 reader
  # (_netstat_rooms_count, which runs first) all degrade to empty+error.
  helper rooms-cli-wedged-degrades >/dev/null \
    && smoke_log "ok-wedged-rooms-degrades" \
    || smoke_fail "(5b) a wedged bridge-rooms.py (TimeoutExpired) must degrade to empty+error, never unwind net-status (codex r1/r2 [P1])"
  # End-to-end: the FULL cmd_net_status path must return rc 0, never raise, even
  # when EVERY rooms subprocess times out (codex r2 [P1] — the v1 rooms count
  # reader runs before the v2 path).
  local cfg="$SMOKE_TMP_ROOT/wedged.json"
  write_tailscale_config_with_secrets "$cfg"
  helper net-status-full-wedged-rooms "$cfg" >/dev/null \
    && smoke_log "ok-full-netstatus-wedged" \
    || smoke_fail "(5b) FULL cmd_net_status must degrade (rc 0) on a wedged rooms CLI, never raise (codex r2 [P1])"
}

# === (6) static teeth: the v2 sources are read-only/non-creating ==============
check_static_read_only() {
  local src; src="$(cat "$A2A_CLI")"
  smoke_assert_contains "$src" "reconcile.reconcile_status_snapshot(" \
    "(6) reconcile block reuses the non-creating reconcile_status_snapshot"
  smoke_assert_contains "$src" "reconcile.peer_reachability_snapshot(" \
    "(6) per_peer reuses the non-creating peer_reachability_snapshot"
  # rooms v2 reads delegate to bridge-rooms.py, which owns the read-only,
  # non-creating open (open_rooms_readonly — returns None on an absent db).
  local rcli; rcli="$(cat "$SMOKE_REPO_ROOT/bridge-rooms.py")"
  smoke_assert_contains "$rcli" "open_rooms_readonly()" \
    "(6) rooms v2 reads go through the read-only rooms CLI (open_rooms_readonly, non-creating)"
  # DEGRADE-SAFE: BOTH rooms subprocess wrappers (v1 _netstat_rooms_count + v2
  # _netstat_rooms_cli) must catch subprocess errors (TimeoutExpired is NOT an
  # OSError subclass), so a wedged bridge-rooms.py can never unwind the read-only
  # snapshot. (codex r1+r2 [P1] fix — must appear at least twice.)
  local subprocerr_count
  subprocerr_count="$(printf '%s' "$src" | grep -c 'subprocess.SubprocessError')"
  [[ "$subprocerr_count" -ge 2 ]] \
    && smoke_log "ok-both-rooms-readers-catch-subprocesserror" \
    || smoke_fail "(6) both v1+v2 rooms subprocess wrappers must catch subprocess.SubprocessError (found $subprocerr_count, need >=2)"
  # The reconcile-common read surfaces MUST use the read-only URI (no creation).
  local rsrc; rsrc="$(cat "$SMOKE_REPO_ROOT/bridge_reconcile_common.py")"
  smoke_assert_contains "$rsrc" "def peer_reachability_snapshot" \
    "(6) peer_reachability_snapshot helper exists in bridge_reconcile_common"
  smoke_assert_contains "$rsrc" '?mode=ro' \
    "(6) reconcile read surfaces open reconcile.db read-only (?mode=ro, non-creating)"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "v0165-l6-net-status-v2"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"

  smoke_run "(1) net-status --json is ADDITIVE: v1 #1697 keys (same shape) + 8 v2 keys" check_additive_shape
  smoke_run "(2) ZERO-MUTATION: net-status creates NO reconcile.db / rooms.db (observable-not-operable)" check_zero_mutation_non_creating
  smoke_run "(3) NO SECRETS: listen/peer secrets + room token/seed never leak into v2 output" check_no_secrets
  smoke_run "(4) ACTIVE-TRANSPORT-ONLY: WARP config v2 never executes tailscale" check_active_transport_only
  smoke_run "(5) POPULATED: per_peer FSM + reconcile auto-recovery + room leader/epoch surfaced" check_populated
  smoke_run "(5b) DEGRADE-SAFE: a wedged rooms CLI (TimeoutExpired) degrades, never unwinds net-status" check_rooms_cli_wedged_degrades
  smoke_run "(6) static: v2 sources are the non-creating read-only snapshots" check_static_read_only

  smoke_log "passed"
}

main "$@"
