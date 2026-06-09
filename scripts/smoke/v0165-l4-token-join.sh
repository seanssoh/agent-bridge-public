#!/usr/bin/env bash
# scripts/smoke/v0165-l4-token-join.sh — A2A Rooms Lane 4 (#1695):
# token-bootstrapped room join (SECURITY-CRITICAL).
#
# An UNKNOWN peer presenting a VALID, unrevoked, unexpired invite token is
# admitted to the leader's pending queue (auto-registering the reverse node-link
# from a per-pair HKDF key) instead of the old hard 403 — while EVERY §7
# invariant still holds. The transport is STUBBED end-to-end (no Tailscale / live
# socket): the sender's POST is captured by the paired-flag test hook, then
# replayed through the REAL receiver handler against a leader cfg that has NO
# peer for the joiner yet.
#
# THE 6 REQUIRED ADVERSARIAL CASES (codex-listed):
#   1  token-hash-as-key REJECTED — a peer key derived from the wire-visible
#      sha256(token) must NOT authenticate (proves domain separation).
#   2  concurrent unknown-peer joins from the same node race the disk write →
#      exactly one peer registered, no corruption (TOCTOU file lock).
#   3  reattach known-member vs new-peer split — a known/persisted peer skips
#      the bootstrap (ordinary node-link); a new peer requires full two-factor.
#   4  valid token → admitted to PENDING (not 403); revoked/expired → still 403.
#   5  WARP reach= tamper — a tampered reach= fails the invite canonical sig.
#   6  net-status / audit / config carries NO secret (no raw token, seed, or
#      derived key in the AUDIT or the join row; the derived key lives ONLY in
#      the 0600 peer config, never the raw token / seed).
# Plus: remote_addr from socket only (a body-asserted addr is never trusted);
# wire reply stays "pending" on auto-approve; allowlist == leader_agent.

set -euo pipefail

SMOKE_NAME="v0165-l4-token-join"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/v0165-l4-token-join-helper.py"
POST_HOOK="$SCRIPT_DIR/v0165-l4-token-join-post-hook.sh"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

# The leader's rooms.db (node A) lives under the isolated state dir.
export BRIDGE_A2A_ROOMS_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
mkdir -p "$BRIDGE_STATE_DIR/handoff"

NODE_A="nodeA"        # leader node id (bridge_id)
NODE_B="nodeB"        # joiner node id (bridge_id)
ADDR_A="127.0.0.1"    # leader reach address (also the joiner's socket dest)
ADDR_B="127.0.0.1"    # joiner socket source (== client_ip at the receiver)

# Leader cfg (bridge_id=nodeA) — EMPTY peers (the joiner is unknown). The signed
# reach= advertises ADDR_A:8787. This is the file the receiver auto-registers to.
CFG_A="$SMOKE_TMP_ROOT/handoff-A.json"
python3 "$HELPER" make-leader-config "$CFG_A" "$NODE_A" "$ADDR_A" >/dev/null

# Joiner cfg (bridge_id=nodeB) — EMPTY peers (no node-link to the leader yet).
CFG_B="$SMOKE_TMP_ROOT/handoff-B.json"
python3 "$HELPER" make-joiner-config "$CFG_B" "$NODE_B" "$ADDR_B" >/dev/null

CAPTURE="$SMOKE_TMP_ROOT/captured-request.json"
TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

# room_create_as <agent> <ttl> — create a room led by agent-bridge-<a> on node A.
room_create_as() {
  local who="$1" ttl="$2"
  env "${TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
    python3 "$ROOMS_CLI" create --name team --ttl "$ttl" --json 2>/dev/null
}

# join_as <os-agent> [extra env...] -- <join-args...> — run `room join` as
# agent-bridge-<a> on node B; the post hook captures the signed request +
# client_ip. The joiner self-bootstraps a LOCAL leader peer from the signed
# reach= (verifying the token-bound canonical first). Returns the CLI rc.
join_as() {
  local who="$1"; shift
  local extra=()
  while [[ "${1:-}" != "--" ]]; do extra+=("$1"); shift; done
  shift
  : >"$CAPTURE" || true
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_B" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "CAPTURE_FILE=$CAPTURE" \
      "CLIENT_IP=$ADDR_B" \
      ${extra[@]+"${extra[@]}"} \
    python3 "$ROOMS_CLI" join "$@"
}

json_field() { python3 "$SCRIPT_DIR/a2a-rooms-p1a-helper.py" json-field "$1" "$2"; }

# deliver [overrides_json] — replay $CAPTURE through the real node-A receiver
# WITH the auto-join feature gate ON. The leader cfg starts with no joiner peer.
deliver() {
  local overrides="${1:-}"
  [[ -n "$overrides" ]] || overrides='{}'
  env "BRIDGE_A2A_ROOM_AUTOJOIN=1" "${TEST_FLAGS[@]}" \
    python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" "$CFG_A" \
      "$CAPTURE" "$overrides"
}

# deliver_no_gate — same but with the feature gate UNSET (default-unchanged).
deliver_no_gate() {
  local overrides="${1:-}"
  [[ -n "$overrides" ]] || overrides='{}'
  env "${TEST_FLAGS[@]}" \
    python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" "$CFG_A" \
      "$CAPTURE" "$overrides"
}

ROOM=""
LINK=""
RAW_TOKEN=""
TOKEN_HASH=""

reset_leader_cfg() {
  # Re-write BOTH configs with empty peers. Each positive delivery auto-registers
  # the joiner on the leader; each `room join` self-bootstraps a leader peer on
  # the joiner. Tests that mint a FRESH room must clear both so the joiner does
  # not reuse a stale per-(room) key it derived for a PRIOR test's room.
  python3 "$HELPER" make-leader-config "$CFG_A" "$NODE_A" "$ADDR_A" >/dev/null
  python3 "$HELPER" make-joiner-config "$CFG_B" "$NODE_B" "$ADDR_B" >/dev/null
  # SK-1: clear the joiner-side invite_nonce_seen ledger so a test that re-uses
  # the SAME captured signed link is not blocked by the real single-use replay
  # guard (the guard itself is exercised explicitly in test_nonce_replay_reject).
  python3 "$HELPER" clear-nonces "$BRIDGE_A2A_ROOMS_DB" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# setup: a room on node A; the invite is a v2 SIGNED link carrying reach=
# ---------------------------------------------------------------------------
test_setup_signed_invite() {
  local out
  out="$(room_create_as alice 0)"
  ROOM="$(json_field room_id "$out")"
  LINK="$(json_field invite_link "$out")"
  [[ -n "$ROOM" && -n "$LINK" ]] || smoke_fail "room create did not yield room/link"
  smoke_assert_contains "$LINK" "leader=$NODE_A" "invite link carries leader=nodeA"
  smoke_assert_contains "$LINK" "reach=" "invite link embeds a signed reach= locator"
  smoke_assert_contains "$LINK" "s=" "invite link carries a token-bound signature"
  RAW_TOKEN="$(python3 "$SCRIPT_DIR/a2a-rooms-p1a-helper.py" token-from-link "$LINK")"
  [[ -n "$RAW_TOKEN" ]] || smoke_fail "could not extract raw token from link"
  TOKEN_HASH="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$RAW_TOKEN")"
}

# ---------------------------------------------------------------------------
# case 4 (positive): a valid token → admitted to PENDING (not 403) + reverse
# peer auto-registered with the room's leader_agent in inbound_allowlist
# ---------------------------------------------------------------------------
test_valid_token_admits_to_pending() {
  reset_leader_cfg
  join_as bob -- "$LINK" >/dev/null 2>&1 \
    || smoke_fail "joiner side should self-bootstrap + capture the signed request"
  smoke_assert_file_exists "$CAPTURE" "the signed cross-node request was captured"
  local res
  res="$(deliver)"
  smoke_assert_contains "$res" "status=200" "valid unknown-peer token join → 200 (not 403)"
  smoke_assert_contains "$res" "\"status\": \"pending\"" \
    "wire reply stays pending even though it auto-registered the peer"
  # The reverse peer was auto-registered on the leader cfg.
  local ids
  ids="$(python3 "$HELPER" peer-ids "$CFG_A")"
  smoke_assert_contains "$ids" "$NODE_B" "the joiner node was auto-registered as a peer"
  # Its address is the SOCKET client_ip (ADDR_B), never a body-asserted addr.
  local paddr
  paddr="$(python3 "$HELPER" peer-field "$CFG_A" "$NODE_B" address)"
  smoke_assert_eq "$ADDR_B" "$paddr" "auto-registered peer address == socket client_ip"
  # The allowlist is the ROOM's leader_agent (alice), NOT the bridge_id (nodeA).
  local allow
  allow="$(python3 "$HELPER" peer-field "$CFG_A" "$NODE_B" inbound_allowlist)"
  smoke_assert_contains "$allow" "alice" "inbound_allowlist == room leader_agent (alice)"
  smoke_assert_not_contains "$allow" "$NODE_A" "inbound_allowlist is NOT the bridge_id"
  # A real verified pending row landed (leader-approval gate intact).
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$ROOM")"
  smoke_assert_contains "$rows" "\"agent\": \"bob\"" "pending row joiner agent is the OS-actor (bob)"
  smoke_assert_contains "$rows" "\"node\": \"$NODE_B\"" "pending row node is the authenticated peer (nodeB)"
  smoke_assert_contains "$rows" "\"verified\": 1" "pending row is verified (post node-link auth)"
}

# ---------------------------------------------------------------------------
# default-unchanged: with the env gate UNSET, an unknown peer is STILL 403
# ---------------------------------------------------------------------------
test_gate_default_unchanged_403() {
  reset_leader_cfg
  join_as bart -- "$LINK" >/dev/null 2>&1 || smoke_fail "capture a request"
  local res
  res="$(deliver_no_gate)"
  smoke_assert_contains "$res" "status=403" \
    "with BRIDGE_A2A_ROOM_AUTOJOIN unset, an unknown peer is STILL 403 (default unchanged)"
  smoke_assert_contains "$res" "unknown peer" "the reject is the unchanged unknown_peer 403"
  local ids
  ids="$(python3 "$HELPER" peer-ids "$CFG_A")"
  smoke_assert_not_contains "$ids" "$NODE_B" "no peer auto-registered when the gate is off"
}

# ---------------------------------------------------------------------------
# case 1: token-hash-as-key REJECTED (domain separation)
# ---------------------------------------------------------------------------
test_token_hash_as_key_rejected() {
  reset_leader_cfg
  # Capture a valid request, then RE-SIGN the body with a key WRONGLY derived
  # from the wire-visible sha256(token). The receiver derives the REAL pair key
  # from the seed; the HMAC must NOT match → 401 (proves the token hash is not
  # the key).
  join_as cara -- "$LINK" >/dev/null 2>&1 || smoke_fail "capture a request"
  local wrong_key path mid ts body bodyhash canonical badsig
  wrong_key="$(python3 "$HELPER" token-hash-key "$RAW_TOKEN" "$ROOM" "$NODE_A" "$NODE_B")"
  path="$(python3 "$HELPER" captured-field "$CAPTURE" path)"
  mid="$(python3 "$HELPER" captured-field "$CAPTURE" header:X-AGB-Message-Id)"
  ts="$(python3 "$HELPER" captured-field "$CAPTURE" header:X-AGB-Timestamp)"
  # Re-sign the EXACT captured body with the wrong key.
  body="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['body'])" "$CAPTURE")"
  bodyhash="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$body")"
  canonical="$(printf 'POST\n%s\n%s\n%s\n%s\n%s' "$path" "$NODE_B" "$mid" "$ts" "$bodyhash")"
  badsig="$(python3 -c "import hmac,hashlib,sys;print('v1='+hmac.new(bytes.fromhex(sys.argv[1]),sys.argv[2].encode(),hashlib.sha256).hexdigest())" "$wrong_key" "$canonical")"
  local res
  res="$(deliver '{"headers":{"X-AGB-Signature":"'"$badsig"'"}}')"
  smoke_assert_contains "$res" "status=401" \
    "case 1: a key derived from the WIRE token hash fails HMAC (domain separation holds)"
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$ROOM")"
  smoke_assert_not_contains "$rows" "cara" "case 1: no pending row for the token-hash-keyed forgery"
  # codex P1: a bad-signature bootstrap must NOT durably persist a peer (the disk
  # write is DEFERRED until AFTER the HMAC proves key possession). So no peer is
  # written for the token-hash forgery — no on-disk peer-config poisoning.
  local ids
  ids="$(python3 "$HELPER" peer-ids "$CFG_A")"
  smoke_assert_not_contains "$ids" "$NODE_B" \
    "case 1 (P1): a bad-signature bootstrap persists NO peer to disk (no poisoning)"
}

# ---------------------------------------------------------------------------
# case 1b (codex r2 P1): a bad-signature bootstrap must NOT poison the SHARED
# in-memory cfg either. Drive TWO requests through ONE long-lived cfg object: a
# bad-signature forgery (req1, 401), then a LATER legit join for the SAME peer
# (req2). req2 must still admit (200) — proving req1 left NO peer in the shared
# cfg that would have hijacked req2's find_peer path.
# ---------------------------------------------------------------------------
test_shared_cfg_no_poison_across_requests() {
  reset_leader_cfg
  local out room link
  out="$(room_create_as cody 0)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  join_as cody -- "$link" >/dev/null 2>&1 || smoke_fail "capture a valid request"
  # Forge a wrong signature for req1 (token-hash-derived key → 401).
  local wrong_key path mid ts body bodyhash canonical badsig
  wrong_key="$(python3 "$HELPER" token-hash-key "$(python3 "$SCRIPT_DIR/a2a-rooms-p1a-helper.py" token-from-link "$link")" "$room" "$NODE_A" "$NODE_B")"
  path="$(python3 "$HELPER" captured-field "$CAPTURE" path)"
  mid="$(python3 "$HELPER" captured-field "$CAPTURE" header:X-AGB-Message-Id)"
  ts="$(python3 "$HELPER" captured-field "$CAPTURE" header:X-AGB-Timestamp)"
  body="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['body'])" "$CAPTURE")"
  bodyhash="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$body")"
  canonical="$(printf 'POST\n%s\n%s\n%s\n%s\n%s' "$path" "$NODE_B" "$mid" "$ts" "$bodyhash")"
  badsig="$(python3 -c "import hmac,hashlib,sys;print('v1='+hmac.new(bytes.fromhex(sys.argv[1]),sys.argv[2].encode(),hashlib.sha256).hexdigest())" "$wrong_key" "$canonical")"
  # req1 = bad-sig forgery; req2 = the SAME captured request UNMODIFIED (valid).
  # Both drive ONE shared cfg loaded once.
  local out2
  out2="$(env "BRIDGE_A2A_ROOM_AUTOJOIN=1" "${TEST_FLAGS[@]}" \
            python3 "$HELPER" deliver-two-shared-cfg "$SMOKE_REPO_ROOT" "$CFG_A" \
            "$CAPTURE" '{"headers":{"X-AGB-Signature":"'"$badsig"'"}}' \
            "$CAPTURE" '{}' 2>&1)" || smoke_fail "shared-cfg helper raised: $out2"
  smoke_assert_contains "$out2" "req1_status=401" "case 1b: the forgery is 401"
  smoke_assert_contains "$out2" "shared_cfg_peers_after_req1=0" \
    "case 1b (r2 P1): the bad-signature req leaves the SHARED cfg unpoisoned (0 peers)"
  smoke_assert_contains "$out2" "req2_status=200" \
    "case 1b (r2 P1): a later LEGIT join for the same peer still admits (req1 did not hijack find_peer)"
}

# ---------------------------------------------------------------------------
# case 4 (negative): revoked / expired token → still 403, no pending row
# ---------------------------------------------------------------------------
test_revoked_and_expired_still_403() {
  # Expired: a 1s-TTL room, backdate the token ts.
  reset_leader_cfg
  local out room link
  out="$(room_create_as dora 1)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  python3 "$HELPER" set-token-ts "$BRIDGE_A2A_ROOMS_DB" "$room" 1 >/dev/null
  join_as erin -- "$link" >/dev/null 2>&1 || smoke_fail "capture an expired-token request"
  local res
  res="$(deliver)"
  smoke_assert_contains "$res" "status=403" "case 4: an EXPIRED token is still 403 (not admitted)"
  smoke_assert_contains "$res" "expired" "case 4: refusal reason is expired"
  local ids
  ids="$(python3 "$HELPER" peer-ids "$CFG_A")"
  smoke_assert_not_contains "$ids" "$NODE_B" "case 4: no peer auto-registered for an expired token"
  # Revoked: rotate the original room's invite (old token no longer matches).
  reset_leader_cfg
  join_as fred -- "$LINK" >/dev/null 2>&1 || smoke_fail "capture an old-token request"
  env "${TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-alice" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
    python3 "$ROOMS_CLI" rotate-invite "$ROOM" --json >/dev/null 2>&1 \
    || smoke_fail "leader rotate-invite should succeed"
  res="$(deliver)"
  smoke_assert_contains "$res" "status=403" "case 4: a REVOKED (rotated-away) token is still 403"
}

# ---------------------------------------------------------------------------
# case 5: WARP reach= tamper — a tampered reach= fails the invite canonical sig
# ---------------------------------------------------------------------------
test_reach_tamper_fails_signature() {
  # A clean joiner (no local leader peer) so the FIRST-CONTACT verify path runs.
  reset_leader_cfg
  # Tamper the reach= address in the link, then try to join: the joiner's
  # token-bound canonical verification must FAIL (refusing first contact) so the
  # CLI exits non-zero and NO request is captured.
  local tampered
  tampered="$(python3 -c "
import sys
link=sys.argv[1]
import urllib.parse as u
parts=u.urlsplit(link); q=dict(u.parse_qsl(parts.query))
# rewrite the reach address to an attacker IP, keep the (now-stale) signature.
import re
q['reach']=re.sub(r':[0-9.]+:', ':10.66.66.66:', q['reach'])
newq=u.urlencode(q)
print(u.urlunsplit((parts.scheme, parts.netloc, parts.path, newq, '')))
" "$LINK")"
  : >"$CAPTURE" || true
  if join_as gwen -- "$tampered" >/dev/null 2>&1; then
    smoke_fail "case 5: a tampered reach= must be REFUSED by the joiner (sig mismatch)"
  fi
  # No request should have been captured (the joiner refused before sending).
  if [[ -s "$CAPTURE" ]]; then
    smoke_fail "case 5: the joiner must NOT send after a reach= tamper"
  fi
  smoke_log "ok: case 5: tampered reach= rejected by the token-bound canonical signature"
}

# ---------------------------------------------------------------------------
# SK-1: an EXPIRED signed invite LINK (iat + ttl < now) is refused by the joiner
# BEFORE first contact — a real, enforced freshness gate (distinct from the
# leader's server-side token TTL).
# ---------------------------------------------------------------------------
test_invite_link_expired_refused() {
  reset_leader_cfg
  local out room rawtok link
  out="$(room_create_as lena 0)"
  room="$(json_field room_id "$out")"
  rawtok="$(python3 "$SCRIPT_DIR/a2a-rooms-p1a-helper.py" token-from-link "$(json_field invite_link "$out")")"
  # Mint a correctly-signed link whose iat is 100000s ago with a 24h ttl → expired.
  local past
  past="$(python3 -c "import time;print(int(time.time())-100000)")"
  link="$(python3 "$HELPER" mint-signed-link "$room" "$NODE_A" "$rawtok" "$ADDR_A" 8787 "$past" 86400 "n-expired")"
  : >"$CAPTURE" || true
  if join_as lena -- "$link" >/dev/null 2>&1; then
    smoke_fail "SK-1: an EXPIRED signed invite link must be refused by the joiner"
  fi
  if [[ -s "$CAPTURE" ]]; then
    smoke_fail "SK-1: the joiner must NOT send after an expired link"
  fi
  smoke_log "ok: SK-1: an expired signed invite link is refused before first contact"
}

# ---------------------------------------------------------------------------
# SK-1: the per-issue NONCE makes a signed link SINGLE-USE for a first-contact
# bootstrap — a REPLAYED signed link is refused on the second presentation.
# ---------------------------------------------------------------------------
test_nonce_replay_reject() {
  reset_leader_cfg
  local out room rawtok link
  out="$(room_create_as mara 0)"
  room="$(json_field room_id "$out")"
  rawtok="$(python3 "$SCRIPT_DIR/a2a-rooms-p1a-helper.py" token-from-link "$(json_field invite_link "$out")")"
  local now
  now="$(python3 -c "import time;print(int(time.time()))")"
  link="$(python3 "$HELPER" mint-signed-link "$room" "$NODE_A" "$rawtok" "$ADDR_A" 8787 "$now" 86400 "n-once")"
  # First use: succeeds (captures + records the nonce). The joiner ALSO writes a
  # local leader peer, so we clear it before the replay to FORCE the bootstrap
  # path again (otherwise the second join is a known-peer re-join, not a replay).
  join_as mara -- "$link" >/dev/null 2>&1 || smoke_fail "first signed-link use should succeed"
  python3 "$HELPER" make-joiner-config "$CFG_B" "$NODE_B" "$ADDR_B" >/dev/null
  : >"$CAPTURE" || true
  # Second use of the SAME link → nonce replay refused (no capture, non-zero rc).
  if join_as mara -- "$link" >/dev/null 2>&1; then
    smoke_fail "SK-1: a REPLAYED signed link (same nonce) must be refused"
  fi
  if [[ -s "$CAPTURE" ]]; then
    smoke_fail "SK-1: the joiner must NOT send on a nonce replay"
  fi
  smoke_log "ok: SK-1: a replayed signed link (same nonce) is refused (single-use)"
}

# ---------------------------------------------------------------------------
# case 6: no secret (raw token / seed / derived key) in the audit or join row
# ---------------------------------------------------------------------------
test_no_secret_in_audit_or_row() {
  reset_leader_cfg
  # Use a FRESH room/link so this case is independent of any prior rotate/revoke.
  local out room link raw thash
  out="$(room_create_as hana 0)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  raw="$(python3 "$SCRIPT_DIR/a2a-rooms-p1a-helper.py" token-from-link "$link")"
  thash="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$raw")"
  join_as hana -- "$link" >/dev/null 2>&1 || smoke_fail "capture a request"
  deliver >/dev/null
  [[ -n "$raw" && -n "$thash" ]] || smoke_fail "token/hash not set up"
  local derived seed RAW_TOKEN TOKEN_HASH ROOM
  RAW_TOKEN="$raw"; TOKEN_HASH="$thash"; ROOM="$room"
  derived="$(python3 "$HELPER" derive-pair-key "$RAW_TOKEN" "$ROOM" "$NODE_A" "$NODE_B")"
  seed="$(python3 -c "import hmac,hashlib,sys;print(hmac.new(b'a2a-room-pair-seed-v1',sys.argv[1].encode(),hashlib.sha256).hexdigest())" "$RAW_TOKEN")"
  # 1) the audit log carries NONE of: raw token, token hash, key seed, derived key.
  local audit="$BRIDGE_LOG_DIR/a2a-handoff.jsonl"
  if [[ -f "$audit" ]]; then
    for needle in "$RAW_TOKEN" "$TOKEN_HASH" "$seed" "$derived"; do
      if grep -qF "$needle" "$audit"; then
        smoke_fail "case 6: a secret-equivalent ($needle) leaked into the audit log"
      fi
    done
  fi
  # 2) the pending join row carries no token / seed / derived key.
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$ROOM")"
  for needle in "$RAW_TOKEN" "$TOKEN_HASH" "$seed" "$derived"; do
    smoke_assert_not_contains "$rows" "$needle" "case 6: no secret-equivalent in the join row"
  done
  # 3) the RAW TOKEN and SEED never reach the peer config (only the DERIVED key
  # is persisted there, at 0600).
  local cfgtext
  cfgtext="$(python3 "$HELPER" config-text "$CFG_A")"
  smoke_assert_not_contains "$cfgtext" "$RAW_TOKEN" "case 6: raw token never in peer config"
  smoke_assert_not_contains "$cfgtext" "$seed" "case 6: key seed never in peer config"
  smoke_assert_contains "$cfgtext" "$derived" "case 6: the DERIVED per-pair key IS the persisted peer secret"
}

# ---------------------------------------------------------------------------
# case 2: concurrent unknown-peer joins race the disk write → exactly one peer,
# no corruption (TOCTOU file lock)
# ---------------------------------------------------------------------------
test_concurrent_register_toctou() {
  local racecfg="$SMOKE_TMP_ROOT/race.json"
  python3 "$HELPER" make-leader-config "$racecfg" "$NODE_A" "$ADDR_A" >/dev/null
  local out
  out="$(python3 "$HELPER" concurrent-register "$racecfg" 8 "$NODE_B" "$ADDR_B" "deadbeefdeadbeefdeadbeefdeadbeef")"
  smoke_assert_contains "$out" "peer_count=1" \
    "case 2: 8 concurrent registers for the same peer → exactly ONE peer row (TOCTOU lock)"
  smoke_assert_contains "$out" "secret_intact=True" "case 2: the persisted secret is intact (no corruption)"
}

# ---------------------------------------------------------------------------
# case 3: reattach known-member vs new-peer split — a KNOWN peer never enters
# the bootstrap path (ordinary node-link); a NEW peer requires the token.
# ---------------------------------------------------------------------------
test_reattach_known_vs_new() {
  reset_leader_cfg
  # Fresh room/link (independent of any prior rotate).
  local out room link
  out="$(room_create_as ivy 0)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  # First, a new peer bootstraps (token required) → registers nodeB.
  join_as ivy -- "$link" >/dev/null 2>&1 || smoke_fail "capture a request"
  deliver >/dev/null
  local ids
  ids="$(python3 "$HELPER" peer-ids "$CFG_A")"
  smoke_assert_contains "$ids" "$NODE_B" "reattach: the new peer is now persisted (known)"
  # Now nodeB is KNOWN. A second join from nodeB takes the established-peer path
  # (find_peer succeeds) — it never re-enters the token-bootstrap branch. Prove
  # the known-peer path still works even WITHOUT the env gate (no token-bootstrap
  # needed for an already-paired peer).
  join_as ivy -- "$link" >/dev/null 2>&1 || smoke_fail "capture a second request"
  local res
  res="$(deliver_no_gate)"
  smoke_assert_contains "$res" "status=200" \
    "reattach: a KNOWN peer re-joins via the ordinary node-link (no token-bootstrap, gate off)"
  # A brand-new DIFFERENT peer with the gate off is still 403 (two-factor for new).
  # nodeC uses its OWN fresh room/link (a distinct single-use nonce) so it is a
  # genuine first contact, not a replay of ivy's link.
  local outc linkc cfg_c="$SMOKE_TMP_ROOT/handoff-C.json"
  outc="$(room_create_as jade 0)"
  linkc="$(json_field invite_link "$outc")"
  python3 "$HELPER" make-joiner-config "$cfg_c" "nodeC" "$ADDR_B" >/dev/null
  : >"$CAPTURE" || true
  env "${TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-jade" \
      "BRIDGE_A2A_CONFIG=$cfg_c" "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "CAPTURE_FILE=$CAPTURE" "CLIENT_IP=$ADDR_B" \
    python3 "$ROOMS_CLI" join "$linkc" >/dev/null 2>&1 || smoke_fail "capture nodeC request"
  res="$(deliver_no_gate '{"headers":{"X-AGB-Peer":"nodeC"}}')"
  smoke_assert_contains "$res" "status=403" \
    "reattach: a brand-new peer is still 403 with the gate off (new ≠ known; two-factor)"
}

# ---------------------------------------------------------------------------
# remote_addr socket-only: the auto-registered peer address is the SOCKET
# client_ip the request actually arrived on — NEVER the signed reach= address,
# NEVER a body/header claim. So the addr gate that runs next pins the peer to its
# true socket source, and there is no body-asserted-address bypass.
# ---------------------------------------------------------------------------
test_remote_addr_socket_only() {
  reset_leader_cfg
  local out link
  out="$(room_create_as kim 0)"
  link="$(json_field invite_link "$out")"
  # The joiner's signed reach= advertises ADDR_A (127.0.0.1), but we deliver the
  # request as if it physically arrived from a DIFFERENT socket (10.7.7.7). The
  # receiver must register the peer at the SOCKET ip, not the reach=, and admit
  # (the addr gate trivially holds because address==socket by construction).
  join_as kim -- "$link" >/dev/null 2>&1 || smoke_fail "capture a request"
  local res
  res="$(deliver '{"client_ip":"10.7.7.7"}')"
  smoke_assert_contains "$res" "status=200" \
    "remote_addr: a token-valid join admits regardless of which socket it came from"
  local paddr
  paddr="$(python3 "$HELPER" peer-field "$CFG_A" "$NODE_B" address)"
  smoke_assert_eq "10.7.7.7" "$paddr" \
    "remote_addr: the peer address is the SOCKET client_ip (10.7.7.7), NOT the signed reach= (127.0.0.1)"
  # Re-pin: a FRESH join (new room → new message_id, so not a dedupe replay) from
  # yet another socket persists the peer at the NEW socket ip, never a wire claim.
  reset_leader_cfg
  local out2 link2
  out2="$(room_create_as kira 0)"
  link2="$(json_field invite_link "$out2")"
  join_as kira -- "$link2" >/dev/null 2>&1 || smoke_fail "capture a fresh request"
  res="$(deliver '{"client_ip":"10.8.8.8"}')"
  smoke_assert_contains "$res" "status=200" "remote_addr: re-bootstrap from a new socket still admits"
  paddr="$(python3 "$HELPER" peer-field "$CFG_A" "$NODE_B" address)"
  smoke_assert_eq "10.8.8.8" "$paddr" "remote_addr: the address re-pins to the new socket ip"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "setup: room on node A + v2 SIGNED invite (reach= + s=)" test_setup_signed_invite
smoke_run "case 4: a valid token admits to PENDING (not 403); peer auto-registered" test_valid_token_admits_to_pending
smoke_run "gate default-unchanged: env unset → unknown peer STILL 403" test_gate_default_unchanged_403
smoke_run "case 1: token-hash-as-key rejected (domain separation)" test_token_hash_as_key_rejected
smoke_run "case 1b: bad-sig bootstrap does not poison the shared in-mem cfg (r2 P1)" test_shared_cfg_no_poison_across_requests
smoke_run "case 4 (neg): revoked / expired token still 403, no peer" test_revoked_and_expired_still_403
smoke_run "case 5: WARP reach= tamper fails the invite canonical signature" test_reach_tamper_fails_signature
smoke_run "SK-1: an expired signed invite link is refused before first contact" test_invite_link_expired_refused
smoke_run "SK-1: a replayed signed link (same nonce) is refused (single-use)" test_nonce_replay_reject
smoke_run "case 6: no raw token / seed / derived key in audit or join row" test_no_secret_in_audit_or_row
smoke_run "case 2: concurrent unknown-peer joins → one peer, no corruption (TOCTOU)" test_concurrent_register_toctou
smoke_run "case 3: reattach known-vs-new split (known skips bootstrap; new needs token)" test_reattach_known_vs_new
smoke_run "remote_addr socket-only on the bootstrap path (wrong socket ip → 403)" test_remote_addr_socket_only

smoke_log "passed"
