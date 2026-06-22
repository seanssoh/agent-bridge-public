#!/usr/bin/env bash
# scripts/smoke/2025-a2a-whois-discovery.sh — `agb a2a whois` agent->node
# discovery + `a2a send --peer auto-resolve` + the peers-list roster column
# (#2025).
#
# #2025 closes an A2A usability gap: given only an AGENT id, you could not
# discover which peer/node it lives on, and `a2a send` forced a manual `--peer`
# lookup every time. This adds:
#   (1) `agb a2a whois <agent>` — resolve the node from the shared rooms roster
#       (the leader-authoritative room_members source, read-only via
#       `bridge-rooms.py list/show --json` — NO new registry).
#   (2) `a2a send --peer auto` / omitted --peer — auto-resolve the node from
#       --to via the SAME whois lookup; FAIL WITH CANDIDATES on ambiguity (never
#       guess); explicit `--peer` unchanged.
#   (3) a `known_agents` roster column on `a2a peers list`.
#
# This smoke is NON-VACUOUS: it seeds a REAL multi-node rooms.db (the canonical
# room_members schema) in an isolated BRIDGE_HOME, then drives the REAL CLI:
#   (A) whois resolves a UNIQUE agent (app-lead -> node-a), self-annotated.
#   (B) whois on an AMBIGUOUS agent (reviewer on node-b + node-c) lists BOTH
#       candidates and exits nonzero — it does NOT pick one.
#   (C) whois on a NOT-FOUND agent gives a clear error + nonzero exit.
#   (D) `send --peer auto` for a UNIQUE agent resolves the node and PROCEEDS
#       (dry-run stubs the actual outbox write); the dry-run peer == node-a.
#   (E) `send` (omitted --peer) for the AMBIGUOUS agent FAILS WITH CANDIDATES
#       (nonzero, no guess).
#   (F) EXPLICIT `--peer node-b` is honored verbatim (no whois, no regression)
#       even when the agent is ambiguous in rooms.
#   (G) `peers list --json` carries a known_agents roster column per node.
#   (H) NO secret leaks into whois / peers output.
#   (I) STATIC TEETH: whois registered, auto-resolve never guesses (the
#       ambiguous branch returns before find_peer), reuses the rooms CLI.
#
# Footgun #11: all Python driving is via the *-helper.py file-as-argv sidecar.
# macOS: run with /opt/homebrew/bin/bash (Bash 5.x).

set -euo pipefail

SMOKE_NAME="2025-a2a-whois-discovery"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/2025-a2a-whois-discovery-helper.py"
A2A_CLI="$SMOKE_REPO_ROOT/bridge-a2a.py"
A2A_CONFIG=""

helper() { python3 "$HELPER" "$@"; }

# Run `agb a2a <args>` against the seeded BRIDGE_HOME + config. Echoes stdout;
# stderr is captured separately by the callers that assert on it.
a2a() {
  BRIDGE_A2A_CONFIG="$A2A_CONFIG" python3 "$A2A_CLI" "$@"
}

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

# A config whose bridge_id is node-a (so app-lead@node-a is `(self)`), with
# peers node-a + node-b configured (so the roster column + auto-resolve can join
# a resolved node to a configured peer). 0600 — load_config refuses looser.
write_config() {
  A2A_CONFIG="$SMOKE_TMP_ROOT/handoff.local.json"
  cat >"$A2A_CONFIG" <<'EOF'
{
  "bridge_id": "node-a",
  "transport": { "kind": "tailscale" },
  "listen": { "address": "100.64.0.5", "port": 8787 },
  "peers": [
    { "id": "node-a", "address": "100.64.0.5", "secret": "SECRETNODEAZZZ" },
    { "id": "node-b", "address": "100.64.0.6", "secret": "SECRETNODEBZZZ" }
  ]
}
EOF
  chmod 0600 "$A2A_CONFIG"
}

# === (A) whois UNIQUE agent -> node, self-annotated ==========================
check_whois_unique() {
  local jout pout
  jout="$(a2a whois app-lead --json 2>/dev/null)"
  echo "$jout" | helper status-is "unique" >/dev/null \
    || smoke_fail "(A) whois app-lead --json status != unique; got: $jout"
  echo "$jout" | helper field "node" "node-a" >/dev/null \
    || smoke_fail "(A) whois app-lead resolved node != node-a; got: $jout"
  echo "$jout" | helper field "self" "True" >/dev/null \
    || smoke_fail "(A) whois app-lead should be (self) on node-a; got: $jout"
  pout="$(a2a whois app-lead 2>/dev/null)"
  smoke_assert_contains "$pout" "app-lead -> node-a" \
    "(A) plain whois prints the agent -> node mapping"
  smoke_assert_contains "$pout" "(self)" \
    "(A) plain whois annotates the local node as (self)"
}

# === (B) whois AMBIGUOUS agent lists candidates, never guesses ===============
check_whois_ambiguous() {
  local jout perr rc=0
  jout="$(a2a whois reviewer --json 2>/dev/null)" || rc=$?
  smoke_assert_eq "1" "$rc" "(B) whois on an ambiguous agent exits nonzero"
  echo "$jout" | helper status-is "ambiguous" >/dev/null \
    || smoke_fail "(B) whois reviewer --json status != ambiguous; got: $jout"
  echo "$jout" | helper candidates-include "node-b" >/dev/null \
    || smoke_fail "(B) ambiguous candidates missing node-b; got: $jout"
  echo "$jout" | helper candidates-include "node-c" >/dev/null \
    || smoke_fail "(B) ambiguous candidates missing node-c; got: $jout"
  # The resolved `node` must be null (it never picked one).
  echo "$jout" | helper field "node" "None" >/dev/null \
    || smoke_fail "(B) ambiguous whois must NOT resolve a single node; got: $jout"
  perr="$(a2a whois reviewer 2>&1 >/dev/null || true)"
  smoke_assert_contains "$perr" "node-b" "(B) plain whois lists candidate node-b"
  smoke_assert_contains "$perr" "node-c" "(B) plain whois lists candidate node-c"
}

# === (C) whois NOT-FOUND agent -> clear error, nonzero =======================
check_whois_not_found() {
  local jout perr rc=0
  jout="$(a2a whois ghost --json 2>/dev/null)" || rc=$?
  smoke_assert_eq "1" "$rc" "(C) whois on an absent agent exits nonzero"
  echo "$jout" | helper status-is "not_found" >/dev/null \
    || smoke_fail "(C) whois ghost --json status != not_found; got: $jout"
  perr="$(a2a whois ghost 2>&1 >/dev/null || true)"
  smoke_assert_contains "$perr" "no node found" \
    "(C) plain whois prints a clear not-found error"
}

# === (D) send --peer auto for a UNIQUE agent resolves + PROCEEDS =============
check_send_auto_unique() {
  local out
  # --dry-run stubs the actual outbox write; auto-resolve must set peer=node-a.
  out="$(a2a send --peer auto --to app-lead --from ops-lead \
         --title "t" --body "b" --dry-run 2>/dev/null)"
  echo "$out" | helper field "peer" "node-a" >/dev/null \
    || smoke_fail "(D) send --peer auto did not resolve peer=node-a; got: $out"
  echo "$out" | helper field "target_agent" "app-lead" >/dev/null \
    || smoke_fail "(D) send --peer auto target_agent != app-lead; got: $out"
  echo "$out" | helper field "dry_run" "True" >/dev/null \
    || smoke_fail "(D) send --peer auto did not reach dry-run resolve; got: $out"

  # Omitted --peer entirely (not even `auto`) must auto-resolve identically.
  out="$(a2a send --to app-lead --from ops-lead --title "t" --body "b" \
         --dry-run 2>/dev/null)"
  echo "$out" | helper field "peer" "node-a" >/dev/null \
    || smoke_fail "(D) omitted --peer did not auto-resolve peer=node-a; got: $out"
}

# === (E) send (omitted --peer) for an AMBIGUOUS agent FAILS WITH CANDIDATES ==
check_send_auto_ambiguous_fails() {
  local err rc=0
  err="$(a2a send --to reviewer --from ops-lead --title "t" --body "b" \
         --dry-run 2>&1 >/dev/null)" || rc=$?
  smoke_assert_eq "1" "$rc" "(E) send auto-resolve on an ambiguous agent fails"
  smoke_assert_contains "$err" "MULTIPLE nodes" \
    "(E) auto-resolve ambiguity error names the conflict"
  smoke_assert_contains "$err" "node-b" "(E) auto-resolve fail lists node-b"
  smoke_assert_contains "$err" "node-c" "(E) auto-resolve fail lists node-c"
  smoke_assert_contains "$err" "refusing to guess" \
    "(E) auto-resolve explicitly refuses to guess"
}

# === (F) EXPLICIT --peer is honored verbatim (no whois, no regression) =======
check_explicit_peer_unchanged() {
  local out
  # reviewer is AMBIGUOUS in rooms, but an explicit --peer must be used as-is
  # with NO whois consultation — this is the no-regression guarantee.
  out="$(a2a send --peer node-b --to reviewer --from ops-lead \
         --title "t" --body "b" --dry-run 2>/dev/null)"
  echo "$out" | helper field "peer" "node-b" >/dev/null \
    || smoke_fail "(F) explicit --peer node-b was not honored verbatim; got: $out"
  echo "$out" | helper field "target_agent" "reviewer" >/dev/null \
    || smoke_fail "(F) explicit --peer send target_agent != reviewer; got: $out"
}

# === (G) peers list --json carries a known_agents roster column ==============
check_peers_roster_column() {
  local jout pout
  jout="$(a2a peers list --json 2>/dev/null)"
  echo "$jout" | helper known-agents-for "node-a" "app-lead" >/dev/null \
    || smoke_fail "(G) peers list known_agents for node-a missing app-lead; got: $jout"
  echo "$jout" | helper known-agents-for "node-b" "reviewer" >/dev/null \
    || smoke_fail "(G) peers list known_agents for node-b missing reviewer; got: $jout"
  pout="$(a2a peers list 2>/dev/null)"
  smoke_assert_contains "$pout" "known_agents=" \
    "(G) plain peers list shows the known_agents column"
}

# === (H) no secret leaks into whois / peers output ===========================
check_no_secrets() {
  local combined
  combined="$(a2a whois app-lead --json 2>/dev/null; a2a peers list --json 2>/dev/null; \
              a2a peers list 2>/dev/null)"
  printf '%s' "$combined" | helper no-secrets "SECRETNODEAZZZ,SECRETNODEBZZZ" >/dev/null \
    && smoke_log "ok-no-secrets" \
    || smoke_fail "(H) a peer secret leaked into whois/peers output"
}

# === (I) static teeth ========================================================
check_static_teeth() {
  local src; src="$(cat "$A2A_CLI")"
  smoke_assert_contains "$src" "def cmd_whois" \
    "(I) cmd_whois handler exists"
  smoke_assert_contains "$src" 'sub.add_parser(
        "whois"' \
    "(I) whois subcommand is registered"
  smoke_assert_contains "$src" "def resolve_agent_node" \
    "(I) shared resolver exists (whois + send auto-resolve use it)"
  smoke_assert_contains "$src" "_netstat_rooms_cli" \
    "(I) whois reuses the read-only rooms CLI delegation (no new registry)"
  # The auto-resolver must RETURN on ambiguity BEFORE find_peer (never guesses).
  smoke_assert_contains "$src" "refusing to guess" \
    "(I) send auto-resolve fails-with-candidates on ambiguity"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"

  write_config
  helper seed-rooms >/dev/null || smoke_fail "could not seed rooms.db"

  smoke_run "(A) whois resolves a UNIQUE agent -> node (self-annotated)" check_whois_unique
  smoke_run "(B) whois on an AMBIGUOUS agent lists every candidate, never guesses" check_whois_ambiguous
  smoke_run "(C) whois on a NOT-FOUND agent gives a clear error + nonzero exit" check_whois_not_found
  smoke_run "(D) send --peer auto for a unique agent resolves the node + proceeds" check_send_auto_unique
  smoke_run "(E) send (omitted --peer) for an ambiguous agent FAILS WITH CANDIDATES" check_send_auto_ambiguous_fails
  smoke_run "(F) EXPLICIT --peer is honored verbatim (no whois, no regression)" check_explicit_peer_unchanged
  smoke_run "(G) peers list carries a known_agents roster column" check_peers_roster_column
  smoke_run "(H) NO secret leaks into whois / peers output" check_no_secrets
  smoke_run "(I) static: whois registered + auto-resolve never guesses + reuses rooms CLI" check_static_teeth

  smoke_log "passed"
}

main "$@"
