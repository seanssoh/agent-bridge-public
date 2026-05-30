#!/usr/bin/env bash
# scripts/smoke/a2a-setup-wizard.sh — A2A setup-wizard P1 skeleton smoke
# (#1415; design §5/§6/§7; umbrella #1226; plan #1405-P1).
#
# Drives `agb a2a setup` (S0/S1/S2/S5/S6) end-to-end against a MOCK tailscale
# CLI (BRIDGE_A2A_TAILSCALE_CLI) + a loopback receiver
# (BRIDGE_A2A_ALLOW_TEST_BIND=1). The real tailnet is never touched. Patterns:
#   - mock tailscale CLI (status --json Self + Online peer; `ip`) — from
#     a2a-tailscale-identity-resolve.sh;
#   - loopback receiver harness (free-port + the reviewer tmux target +
#     bridge-task.sh enqueue boundary) — from a2a-cross-bridge.sh.
#
# Every check exercises a behavior that does NOT exist before this PR (the
# `setup` subcommand). The SECURITY assertions:
#   - the written config is mode 0600;
#   - the secret comes from --peer-secret-env (never a flag) and an EMPTY
#     secret is a hard fail-closed error with the daemon NOT started
#     (the explicit NEGATIVE CONTROL in check 4);
#   - S5 activates via `bridge-handoff-daemon.sh start` (the unchanged
#     fail-closed bind preflight), never a raw serve;
#   - an unresolvable peer fails closed and leaves the config unchanged
#     (check 7).
#
# Cases:
#   1. S0 detect-authed (authed mock -> show-state S1; CLI-absent -> S0,
#      no false GREEN).
#   2. S1 writes an identity-keyed listen at 0600 (node_id + tailscale_name,
#      not a raw IP as the only key).
#   3. S2 lists + writes an identity-keyed peers[] entry + allowlist +
#      secret-from-env (never the secret on the command line).
#   4. S5 activates + binds loopback; NEGATIVE CONTROL: empty secret ->
#      peer_no_secret hard-fail, daemon NOT started.
#   5. S6 handshake acked (loopback self-as-peer; resolve + dry-run + live
#      send+deliver -> 2xx + task_id -> GREEN).
#   6. Idempotent re-run = clean no-op (no churn, no dup peer, daemon up,
#      exit 0, still GREEN).
#   7. Fail-closed unresolvable peer -> resolve_node_id_unknown hard error,
#      config unchanged.

set -euo pipefail

SMOKE_NAME="a2a-setup-wizard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/a2a-setup-wizard-helper.py"

# The local bridge id == the peer id so the loopback self-handshake works
# (the receiver looks up the inbound X-AGB-Peer, which is the sender's own
# bridge_id, in its peer table — so the peer entry's id must equal it).
SELF_BRIDGE_ID="self-bridge"
PEER_SECRET_VALUE="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
REVIEWER_SESSION_NAME="a2a-setup-reviewer-$$-${RANDOM}"

HANDOFFD_STARTED=0

cleanup() {
  # Stop a receiver the wizard may have started.
  if (( HANDOFFD_STARTED )); then
    BRIDGE_A2A_TAILSCALE_CLI="$MOCK_CLI" BRIDGE_A2A_ALLOW_TEST_BIND=1 \
      bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" stop >/dev/null 2>&1 || true
  fi
  if [[ -n "${REVIEWER_SESSION:-}" ]]; then
    tmux kill-session -t "=${REVIEWER_SESSION}" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

# Mock `tailscale`. Self + a peer named SELF_BRIDGE_ID, BOTH at 127.0.0.1 so
# the identity-keyed listen + peer resolve to loopback (the test-bind hatch
# lets the receiver bind it). `ip` lists 127.0.0.1 (the bind-proof source of
# truth in test mode). All on the same loopback so the self-handshake works.
write_mock_tailscale() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/tailscale" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "status" && "$2" == "--json" ]]; then
  cat <<'JSON'
{
  "Self": {
    "ID": "selfStableID111",
    "HostName": "my-host",
    "DNSName": "my-host.example-tailnet.ts.net.",
    "TailscaleIPs": ["127.0.0.1"],
    "Online": true, "OS": "linux"
  },
  "Peer": {
    "nodekey:self": {
      "ID": "peerStableID222",
      "HostName": "self-bridge",
      "DNSName": "self-bridge.example-tailnet.ts.net.",
      "TailscaleIPs": ["127.0.0.1"],
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
echo "mock-tailscale: unsupported args: $*" >&2
exit 2
MOCK
  chmod +x "$dir/tailscale"
}

# Bring the 'reviewer' agent up so the inbound enqueue (S6 live handshake)
# lands in a real inbox via the bridge-task.sh create boundary (which refuses
# a stopped target, #1318). Mirrors a2a-cross-bridge.sh.
write_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/reviewer"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="reviewer"
bridge_add_agent_id_if_missing "reviewer"
BRIDGE_AGENT_DESC["reviewer"]="A2A setup smoke reviewer"
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

# Run the wizard with the mock tailscale CLI + loopback test-bind active.
# The secret is exported into A2A_PEER_SECRET (read by --peer-secret-env) so
# it is NEVER on the command line.
setup() {
  BRIDGE_A2A_TAILSCALE_CLI="$MOCK_CLI" \
  BRIDGE_A2A_ALLOW_TEST_BIND=1 \
  A2A_PEER_SECRET="$PEER_SECRET_VALUE" \
    python3 "$SMOKE_REPO_ROOT/bridge-a2a.py" setup "$@"
}

# Variant with NO secret in the env (the negative control needs an unset var).
setup_no_secret() {
  local secret_env=""
  BRIDGE_A2A_TAILSCALE_CLI="$MOCK_CLI" \
  BRIDGE_A2A_ALLOW_TEST_BIND=1 \
  A2A_PEER_SECRET="$secret_env" \
    python3 "$SMOKE_REPO_ROOT/bridge-a2a.py" setup "$@"
}

show_state_json() {
  BRIDGE_A2A_TAILSCALE_CLI="${1:-$MOCK_CLI}" \
    python3 "$SMOKE_REPO_ROOT/bridge-a2a.py" setup --show-state --json
}

hh() { python3 "$HELPER" "$@"; }

# CFG is assigned in main(), AFTER smoke_setup_bridge_home re-exports
# BRIDGE_HOME under the isolated temp root (assigning it at top-level would
# capture the operator's live BRIDGE_HOME).
CFG=""

# --- (1) S0 detect-authed vs CLI-absent ---
case_1_s0() {
  local out current
  out="$(show_state_json "$MOCK_CLI")"
  current="$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["current_state"])')"
  smoke_assert_eq "S1" "$current" \
    "(1) authed tailscale + empty config -> show-state reports S1 (S0 satisfied)"

  # CLI genuinely absent -> S0 not satisfied, no false GREEN.
  out="$(show_state_json "$SMOKE_TMP_ROOT/no-such-cli")"
  current="$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["current_state"])')"
  smoke_assert_eq "S0" "$current" \
    "(1) absent tailscale CLI -> show-state stays at S0 (no false GREEN)"
  smoke_assert_contains "$out" "tailscale" \
    "(1) S0 action mentions tailscale (login/install gate)"
}

# --- (2) S1 writes an identity-keyed listen at 0600 ---
case_2_s1() {
  setup --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" >/dev/null
  smoke_assert_file_exists "$CFG" "(2) S1 wrote handoff.local.json"
  smoke_assert_eq "0600" "$(hh config-mode "$CFG")" \
    "(2) SECURITY: written config is mode 0600"
  smoke_assert_eq "$SELF_BRIDGE_ID" "$(hh config-field "$CFG" bridge_id)" \
    "(2) bridge_id persisted"
  smoke_assert_eq "selfStableID111" "$(hh config-field "$CFG" listen.node_id)" \
    "(2) listen keyed on the Self Tailscale node_id (not a raw IP)"
  smoke_assert_eq "my-host.example-tailnet.ts.net" \
    "$(hh config-field "$CFG" listen.tailscale_name)" \
    "(2) listen also carries the Self MagicDNS name"
  smoke_assert_eq "$A2A_PORT" "$(hh config-field "$CFG" listen.port)" \
    "(2) listen.port persisted"
}

# --- (3) S2 writes an identity-keyed peer + allowlist + secret-from-env ---
case_3_s2() {
  setup --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer "$SELF_BRIDGE_ID" --peer-secret-env A2A_PEER_SECRET \
    --inbound-allowlist reviewer >/dev/null
  smoke_assert_eq "1" "$(hh peer-count "$CFG")" \
    "(3) exactly one peer configured"
  smoke_assert_eq "$SELF_BRIDGE_ID" "$(hh config-field "$CFG" peers.0.id)" \
    "(3) peer id persisted"
  smoke_assert_eq "peerStableID222" "$(hh config-field "$CFG" peers.0.node_id)" \
    "(3) peer keyed on the discovered Tailscale node_id (identity, not raw IP)"
  smoke_assert_eq '["reviewer"]' "$(hh config-field "$CFG" peers.0.inbound_allowlist)" \
    "(3) inbound_allowlist taken from --inbound-allowlist"
  smoke_assert_eq "yes" "$(hh peer-secret-set "$CFG" "$SELF_BRIDGE_ID")" \
    "(3) peer secret set from --peer-secret-env (read from the environment)"
  # The secret VALUE must never appear in the wizard's own output.
  local out
  out="$(setup --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer "$SELF_BRIDGE_ID" --peer-secret-env A2A_PEER_SECRET \
    --inbound-allowlist reviewer 2>&1)"
  smoke_assert_not_contains "$out" "$PEER_SECRET_VALUE" \
    "(3) SECURITY: the secret value is never echoed by the wizard"
}

# --- (4) S5 activates + NEGATIVE CONTROL empty secret fails closed ---
case_4_s5_and_negative_control() {
  # NEGATIVE CONTROL, on a SEPARATE config, with NO --yes so the daemon
  # backstop preflight is NEVER reached: this isolates the WIZARD's OWN S2
  # empty-secret fail-closed teeth (a regression there is caught here, not
  # masked by the receiver's independent preflight). The wizard must
  # hard-error with peer_no_secret BEFORE writing the config or touching S5.
  local neg_cfg="$BRIDGE_HOME/handoff-negctl.json"
  local out rc=0
  out="$(BRIDGE_A2A_CONFIG="$neg_cfg" setup_no_secret \
    --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer "$SELF_BRIDGE_ID" --peer-secret-env A2A_PEER_SECRET \
    --inbound-allowlist reviewer 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" \
    "(4) NEGATIVE CONTROL: empty --peer-secret-env -> non-zero exit (wizard S2 teeth, no --yes)"
  smoke_assert_contains "$out" "peer_no_secret" \
    "(4) NEGATIVE CONTROL: the WIZARD's own S2 check reports peer_no_secret"
  smoke_assert_not_contains "$out" "S5 OK" \
    "(4) NEGATIVE CONTROL: S5 never activates on an empty secret"
  smoke_assert_not_contains "$out" "wrote " \
    "(4) NEGATIVE CONTROL: the wizard writes NO config on an empty secret (fail-closed before persist)"
  # The wizard's empty-secret check fires BEFORE the atomic config write, so
  # the neg-control config is never created (the strongest outcome — no empty
  # secret can have been persisted).
  smoke_assert_eq "1" "$([[ -f "$neg_cfg" ]] && echo 0 || echo 1)" \
    "(4) NEGATIVE CONTROL: no config written at all (fail-closed before persist)"

  # SECOND-LAYER backstop: even WITH --yes (so the daemon preflight is
  # reached) an empty secret still cannot produce a running receiver — the
  # receiver's OWN fail-closed preflight refuses. This pins the irreducible
  # backstop (a wizard regression alone can never start a secretless receiver).
  rc=0
  out="$(BRIDGE_A2A_CONFIG="$neg_cfg" setup_no_secret \
    --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer "$SELF_BRIDGE_ID" --peer-secret-env A2A_PEER_SECRET \
    --inbound-allowlist reviewer --yes 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" \
    "(4) BACKSTOP: empty secret + --yes still exits non-zero (receiver refuses)"
  smoke_assert_contains "$out" "peer_no_secret" \
    "(4) BACKSTOP: the failure is peer_no_secret (no secretless receiver)"
  smoke_assert_not_contains "$out" "receiver started" \
    "(4) BACKSTOP: the receiver is NOT started on an empty secret"

  # Now the real S5 activation against the main (secret-set) config + --yes.
  out="$(setup --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer "$SELF_BRIDGE_ID" --peer-secret-env A2A_PEER_SECRET \
    --inbound-allowlist reviewer --yes 2>&1)"
  HANDOFFD_STARTED=1
  smoke_assert_contains "$out" "S5 OK" "(4) S5 activated the receiver"
  # The receiver must be live + healthy (via the lifecycle helper, NOT a raw
  # serve) on the loopback bind.
  local healthz rc2=0
  healthz="$(BRIDGE_A2A_TAILSCALE_CLI="$MOCK_CLI" BRIDGE_A2A_ALLOW_TEST_BIND=1 \
    bash "$SMOKE_REPO_ROOT/bridge-handoff-daemon.sh" healthz 2>&1)" || rc2=$?
  smoke_assert_eq "0" "$rc2" "(4) receiver healthz probe passes (live serve)"
}

# --- (5) S6 handshake acked (live self-loopback) ---
case_5_s6_handshake() {
  # Dry-run default first: resolves + reachable, NO inbox task created.
  local out
  out="$(setup --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer "$SELF_BRIDGE_ID" --peer-secret-env A2A_PEER_SECRET \
    --inbound-allowlist reviewer 2>&1)"
  smoke_assert_contains "$out" "S6 OK (dry-run)" \
    "(5) S6 default is dry-run + GREEN-on-reachable (no peer inbox task)"

  # Live handshake: real send + deliver -> 2xx ack with a task id -> GREEN.
  out="$(setup --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer "$SELF_BRIDGE_ID" --peer-secret-env A2A_PEER_SECRET \
    --inbound-allowlist reviewer --live-handshake 2>&1)"
  smoke_assert_contains "$out" "S6 OK (live)" \
    "(5) S6 --live-handshake acked the loopback self-handshake (GREEN)"
  smoke_assert_contains "$out" "GREEN" "(5) S6 reports GREEN on a live ack"
  # The handshake task must be visible in the reviewer inbox (real enqueue
  # boundary).
  local inbox
  inbox="$("$SMOKE_REPO_ROOT/agent-bridge" inbox reviewer 2>/dev/null || true)"
  smoke_assert_contains "$inbox" "a2a setup handshake" \
    "(5) the live handshake landed in the reviewer inbox (real enqueue)"
}

# --- (6) idempotent re-run = clean no-op ---
case_6_idempotent() {
  local before after out
  before="$(cat "$CFG")"
  out="$(setup --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer "$SELF_BRIDGE_ID" --peer-secret-env A2A_PEER_SECRET \
    --inbound-allowlist reviewer 2>&1)"
  after="$(cat "$CFG")"
  smoke_assert_eq "$before" "$after" \
    "(6) re-run wrote no config changes (byte-identical)"
  smoke_assert_eq "1" "$(hh peer-count "$CFG")" \
    "(6) re-run did not duplicate the peer"
  smoke_assert_contains "$out" "no changes written" \
    "(6) re-run reports the config already current"
  # show-state must report DONE-equivalent (S6 is the terminal pending action
  # when S0-S5 hold; the live handshake leaves no durable observable).
  local current
  current="$(show_state_json | python3 -c 'import json,sys;print(json.load(sys.stdin)["current_state"])')"
  smoke_assert_eq "S6" "$current" \
    "(6) with S0-S5 satisfied, show-state reports S6 (the handshake is the last action)"
}

# --- (7) fail-closed unresolvable peer ---
case_7_unresolvable_peer() {
  # Pre-seed a config whose peer is keyed on a node_id NOT in the mock status.
  # The wizard must HARD-ERROR resolving it (resolve_node_id_unknown) at the
  # S6 handshake and leave the config unchanged.
  local ghost_cfg="$BRIDGE_HOME/handoff-ghost.json"
  cat >"$ghost_cfg" <<EOF
{
  "bridge_id": "$SELF_BRIDGE_ID",
  "listen": { "node_id": "selfStableID111", "tailscale_name": "my-host", "port": $A2A_PORT },
  "peers": [
    {
      "id": "ghost-peer",
      "node_id": "doesNotExist999",
      "port": $A2A_PORT,
      "enqueue_path": "/enqueue",
      "secret": "$PEER_SECRET_VALUE",
      "inbound_allowlist": ["reviewer"]
    }
  ]
}
EOF
  chmod 0600 "$ghost_cfg"
  local before after out rc=0
  before="$(cat "$ghost_cfg")"
  out="$(BRIDGE_A2A_CONFIG="$ghost_cfg" setup \
    --peer ghost-peer --live-handshake 2>&1)" || rc=$?
  after="$(cat "$ghost_cfg")"
  smoke_assert_eq "1" "$rc" \
    "(7) unresolvable peer -> non-zero exit (fail-closed)"
  smoke_assert_contains "$out" "resolve_node_id_unknown" \
    "(7) the failure is resolve_node_id_unknown (no silent stale fallback)"
  smoke_assert_eq "$before" "$after" \
    "(7) the config is unchanged after a fail-closed resolve error"
}

# --- (8) --peer WITHOUT --peer-secret-env is fail-closed before any write ---
# codex #1418 r1 BLOCKING-2: a MISSING --peer-secret-env flag (not just an empty
# value) used to bypass the secret guard and strand a secretless peer on disk.
# The guard now fires on a missing flag too, BEFORE any cfg mutation/write.
case_8_peer_without_secret_flag() {
  local nf_cfg="$BRIDGE_HOME/handoff-noflag.json"
  local out rc=0
  out="$(BRIDGE_A2A_CONFIG="$nf_cfg" setup \
    --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer "$SELF_BRIDGE_ID" --inbound-allowlist reviewer 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" \
    "(8) --peer with NO --peer-secret-env -> non-zero exit (fail-closed)"
  smoke_assert_contains "$out" "peer_no_secret" \
    "(8) the failure is peer_no_secret (missing flag, not just empty value)"
  smoke_assert_not_contains "$out" "wrote " \
    "(8) NO config written when --peer-secret-env is absent"
  smoke_assert_eq "1" "$([[ -f "$nf_cfg" ]] && echo 0 || echo 1)" \
    "(8) no config file created at all (refused before persist)"
}

# --- (9) un-keyed unresolvable peer is REFUSED at the write stage ---
# codex #1418 r1 BLOCKING-1: `--peer <ghost>` where ghost is NOT among the
# Online mock nodes AND has no pre-placed address used to be WRITTEN (with a
# secret) + reported S2-done + activatable while skipping S6. The wizard must
# now hard-error (peer_unresolvable) BEFORE persisting anything.
case_9_unkeyed_peer_refused() {
  local uk_cfg="$BRIDGE_HOME/handoff-unkeyed.json"
  local out rc=0
  # ghost-peer is not in the mock `tailscale status` and the config does not
  # exist yet (no pre-placed address) -> must be refused.
  out="$(BRIDGE_A2A_CONFIG="$uk_cfg" setup \
    --bridge-id "$SELF_BRIDGE_ID" --listen-port "$A2A_PORT" \
    --peer ghost-peer --peer-secret-env A2A_PEER_SECRET \
    --inbound-allowlist reviewer 2>&1)" || rc=$?
  smoke_assert_eq "1" "$rc" \
    "(9) un-keyed unresolvable --peer -> non-zero exit (fail-closed)"
  smoke_assert_contains "$out" "peer_unresolvable" \
    "(9) the failure is peer_unresolvable (no secret-bearing dead peer written)"
  smoke_assert_not_contains "$out" "wrote " \
    "(9) NO config written for an unresolvable un-keyed peer"
  smoke_assert_eq "1" "$([[ -f "$uk_cfg" ]] && echo 0 || echo 1)" \
    "(9) no config file created (the dead un-keyed peer never persisted)"
  # And there is NO way to then activate it: a follow-up --yes with no --peer
  # against a config that was never written must not start a receiver for a
  # ghost peer (the config simply does not exist -> S5 has nothing to activate).
  rc=0
  out="$(BRIDGE_A2A_CONFIG="$uk_cfg" setup --yes 2>&1)" || rc=$?
  smoke_assert_not_contains "$out" "S5 OK" \
    "(9) --yes cannot activate a receiver off the never-written ghost config"
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd tmux
  # An inherited BRIDGE_A2A_CONFIG from the operator's shell would point the
  # wizard at the LIVE config — unset it so every path resolves under the
  # isolated BRIDGE_HOME smoke_setup_bridge_home pins below.
  unset BRIDGE_A2A_CONFIG BRIDGE_A2A_OUTBOX_DB BRIDGE_A2A_INBOX_DB
  smoke_setup_bridge_home "$SMOKE_NAME"
  CFG="$BRIDGE_HOME/handoff.local.json"

  MOCK_DIR="$SMOKE_TMP_ROOT/mock-bin"
  write_mock_tailscale "$MOCK_DIR"
  MOCK_CLI="$MOCK_DIR/tailscale"

  A2A_PORT="$(hh free-port)"
  write_roster
  start_reviewer_session

  smoke_run "(1) S0 detect-authed vs CLI-absent"        case_1_s0
  smoke_run "(2) S1 identity-keyed listen at 0600"      case_2_s1
  smoke_run "(3) S2 identity-keyed peer + secret-env"   case_3_s2
  smoke_run "(4) S5 activate + empty-secret neg-ctl"    case_4_s5_and_negative_control
  smoke_run "(5) S6 handshake acked (live loopback)"    case_5_s6_handshake
  smoke_run "(6) idempotent re-run no-op"               case_6_idempotent
  smoke_run "(7) fail-closed unresolvable peer"         case_7_unresolvable_peer
  smoke_run "(8) --peer without --peer-secret-env"      case_8_peer_without_secret_flag
  smoke_run "(9) un-keyed peer refused at write"        case_9_unkeyed_peer_refused

  smoke_log "PASS"
}

main "$@"
