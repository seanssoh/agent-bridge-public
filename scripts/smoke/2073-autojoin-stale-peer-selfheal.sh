#!/usr/bin/env bash
# scripts/smoke/2073-autojoin-stale-peer-selfheal.sh — #2073:
# joiner-side STALE-LOCAL-PEER self-heal + bad_signature error taxonomy
# (SECURITY-CRITICAL, A2A HIGH-RISK #6).
#
# ROOT (codex-reproduced): a joiner whose FIRST cross-node contact 403'd while
# the leader's room auto-join gate was OFF had ALREADY written a LOCAL leader
# peer whose `secret` was derived from THAT (now stale) invite. After the leader
# enables auto-join + re-mints a FRESH invite, the joiner's `find_peer` succeeds
# → it SKIPS the bootstrap → signs with the STALE key → the receiver derives the
# FRESH key from rooms.db → opaque 401 `bad_signature` (security-alarm-shaped,
# zero actionable guidance). The crypto is correct; the joiner is reusing a stale
# token-bootstrapped local peer.
#
# THE GUARANTEES THIS SMOKE PINS (make-or-break):
#   A. SELF-HEAL is ACCEPTANCE-ANCHORED: a stale local peer + a fresh re-mint
#      link → the join first signs with the STORED (stale) key (rejected), then
#      RETRIES with the candidate key (accepted), and ONLY THEN persists the
#      refresh. Two POSTs; the retry re-signs (signatures differ).
#   A2. DOWNGRADE-PROOF: if the leader REJECTS the candidate too (a genuinely
#      stale token), NO refresh is persisted — the secret is unchanged. This is
#      the codex r2 fix: persistence is anchored to the leader's acceptance, NEVER
#      to the (token-holder-forgeable) invite nonce/signature.
#   E. A would-be downgrade link cannot change an ALREADY-CURRENT secret: the join
#      tries the stored (current) key FIRST, the leader accepts it, the retry
#      never fires, the stale candidate is never adopted.
#   B. TAXONOMY: an unknown-peer token that does NOT verify (stale/rotated) →
#      the receiver returns the actionable `stale_or_unknown_invite` 403 with a
#      single remedy string — NEVER opaque `bad_signature`, and NEVER the
#      precise verdict (mismatch/expired/revoked) to the peer (no oracle).
#   C. NO OVER-COLLAPSE (mutation): a CURRENT-token candidate whose body/HMAC is
#      genuinely TAMPERED still → 401 `bad_signature` (the taxonomy does NOT
#      relabel a real bad-sig as stale).
#   D. BOUND: the self-heal refreshes ONLY a token-bootstrapped peer (room_bootstrap
#      provenance stamp); it must NOT clobber a legit hand-provisioned node-link.
#
# Transport is STUBBED end-to-end (no Tailscale / live socket). The receiver-side
# cases (B/C/D) replay through the REAL handler; the joiner-side acceptance-
# anchored cases (A/A2/E) drive `cmd_join` in-process with a SEQUENCED post hook
# (reject/accept verdicts) so the retry path is exercised deterministically.

set -euo pipefail

SMOKE_NAME="2073-autojoin-stale-peer-selfheal"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Reuse the v0165-l4 helper + post-hook (generic capture/deliver/inspect verbs).
HELPER="$SCRIPT_DIR/v0165-l4-token-join-helper.py"
POST_HOOK="$SCRIPT_DIR/v0165-l4-token-join-post-hook.sh"
P1A_HELPER="$SCRIPT_DIR/a2a-rooms-p1a-helper.py"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

export BRIDGE_A2A_ROOMS_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
mkdir -p "$BRIDGE_STATE_DIR/handoff"

NODE_A="nodeA"        # leader node id (bridge_id)
NODE_B="nodeB"        # joiner node id (bridge_id)
ADDR_A="127.0.0.1"    # leader reach address (also the joiner's socket dest)
ADDR_B="127.0.0.1"    # joiner socket source (== client_ip at the receiver)

CFG_A="$SMOKE_TMP_ROOT/handoff-A.json"   # leader cfg (empty peers)
CFG_B="$SMOKE_TMP_ROOT/handoff-B.json"   # joiner cfg (empty peers)
CAPTURE="$SMOKE_TMP_ROOT/captured-request.json"
TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

python3 "$HELPER" make-leader-config "$CFG_A" "$NODE_A" "$ADDR_A" >/dev/null
python3 "$HELPER" make-joiner-config "$CFG_B" "$NODE_B" "$ADDR_B" >/dev/null

json_field() { python3 "$P1A_HELPER" json-field "$1" "$2"; }
token_from_link() { python3 "$P1A_HELPER" token-from-link "$1"; }
joiner_secret() { python3 "$HELPER" peer-field "$CFG_B" "$NODE_A" secret; }

# Local negative-equality assertion (the shared lib only ships smoke_assert_eq).
assert_not_eq() {
  local a="$1" b="$2" context="$3"
  [[ "$a" != "$b" ]] || smoke_fail "$context: expected values to DIFFER, both were '$a'"
}

# room_create_as <agent> — create a room led by agent-bridge-<a> on node A.
room_create_as() {
  env "${TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${1}" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
    python3 "$ROOMS_CLI" create --name team --json 2>/dev/null
}

# rotate_invite_as <agent> <room> — leader re-mints (rotates) the room invite.
rotate_invite_as() {
  env "${TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${1}" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
    python3 "$ROOMS_CLI" rotate-invite "$2" --json 2>/dev/null
}

# join_as <os-agent> <link> — run `room join` as agent-bridge-<a> on node B; the
# post hook captures the signed request + client_ip. Returns the CLI rc.
join_as() {
  local who="$1" link="$2"
  : >"$CAPTURE" || true
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_B" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "CAPTURE_FILE=$CAPTURE" \
      "CLIENT_IP=$ADDR_B" \
    python3 "$ROOMS_CLI" join "$link" >/dev/null 2>&1
}

SEQ_HELPER="$SCRIPT_DIR/2073-autojoin-stale-peer-selfheal-helper.py"
SEQ_POST_HOOK="$SCRIPT_DIR/2073-autojoin-stale-peer-selfheal-post-hook.sh"

# join_seq <os-agent> <link> <verdicts> — run `room join` driving the
# ACCEPTANCE-ANCHORED self-heal IN-PROCESS: each in-process POST gets the next
# verdict from <verdicts> (comma list of reject/accept). The 1st POST (signed
# with the STORED secret) gets verdicts[0]; the retry (signed with the CANDIDATE
# key) gets verdicts[1]. Captures each attempt to $SEQ_DIR/post-<n>.json so the
# caller can inspect WHICH key each signed with. Returns the CLI rc.
SEQ_DIR=""
join_seq() {
  local who="$1" link="$2" verdicts="$3"
  SEQ_DIR="$SMOKE_TMP_ROOT/seq-${who}-$$-${RANDOM}"
  rm -rf "$SEQ_DIR"; mkdir -p "$SEQ_DIR"
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_B" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$SEQ_POST_HOOK" \
      "SEQ_CAPTURE_DIR=$SEQ_DIR" \
      "SEQ_POST_STATUSES=$verdicts" \
      "CLIENT_IP=$ADDR_B" \
    python3 "$ROOMS_CLI" join "$link" >/dev/null 2>&1
}

# seq_post_count — how many in-process POSTs the last join_seq made.
seq_post_count() { find "$SEQ_DIR" -name 'post-*.json' 2>/dev/null | wc -l | tr -d ' '; }
# seq_post_sig <n> — the X-AGB-Signature header of the n-th captured POST.
seq_post_sig() {
  python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('headers',{}).get('X-AGB-Signature',''))" \
    "$SEQ_DIR/post-$1.json"
}

# join_as_gate_off — drive the FIRST contact through the receiver with the gate
# OFF (403 room_autojoin_disabled), but the joiner still bootstraps a LOCAL
# leader peer client-side. We run the join (captures + bootstraps) then deliver
# with no gate to confirm the 403 — the joiner-local peer write is the point.
deliver() {
  local overrides="${1:-}"; [[ -n "$overrides" ]] || overrides='{}'
  env "BRIDGE_A2A_ROOM_AUTOJOIN=1" "${TEST_FLAGS[@]}" \
    python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" "$CFG_A" \
      "$CAPTURE" "$overrides"
}
deliver_no_gate() {
  local overrides="${1:-}"; [[ -n "$overrides" ]] || overrides='{}'
  env "${TEST_FLAGS[@]}" \
    python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" "$CFG_A" \
      "$CAPTURE" "$overrides"
}

ROOM=""

# ---------------------------------------------------------------------------
# setup: a room + an initial v2 SIGNED invite (link v1)
# ---------------------------------------------------------------------------
LINK_V1=""
RAW_V1=""
test_setup() {
  local out
  out="$(room_create_as alice)"
  ROOM="$(json_field room_id "$out")"
  LINK_V1="$(json_field invite_link "$out")"
  [[ -n "$ROOM" && -n "$LINK_V1" ]] || smoke_fail "room create did not yield room/link"
  smoke_assert_contains "$LINK_V1" "s=" "invite v1 carries a token-bound signature"
  RAW_V1="$(token_from_link "$LINK_V1")"
  [[ -n "$RAW_V1" ]] || smoke_fail "could not extract raw token from link v1"
}

# ---------------------------------------------------------------------------
# A. THE CORE FIX — stale-local-peer self-heal across a re-mint, ANCHORED to the
#    leader's ACCEPTANCE (codex r2/r3). The joiner has a stale local peer (v1
#    key). On a fresh v2 link the join is ACCEPTANCE-ANCHORED: it first signs with
#    the STORED (stale v1) key → the leader REJECTS → it RETRIES signing with the
#    candidate v2 key → the leader ACCEPTS → only THEN is the refresh PERSISTED.
#    We drive this in-process with a sequenced post hook: verdicts=reject,accept.
# ---------------------------------------------------------------------------
test_self_heal_across_remint() {
  # 1) gate-off first contact bootstraps a stale LOCAL leader peer (v1 key).
  join_as bob "$LINK_V1" || smoke_fail "first join should capture + bootstrap (CLI ok)"
  deliver_no_gate >/dev/null
  local stale_secret
  stale_secret="$(joiner_secret)"
  [[ -n "$stale_secret" ]] || smoke_fail "joiner should have bootstrapped a local leader peer from v1"

  # 2) leader rotates → v2 (v1 now invalid).
  python3 "$HELPER" make-leader-config "$CFG_A" "$NODE_A" "$ADDR_A" >/dev/null
  local out2 link_v2
  out2="$(rotate_invite_as alice "$ROOM")"
  link_v2="$(json_field invite_link "$out2")"
  [[ -n "$link_v2" ]] || smoke_fail "rotate-invite did not yield a fresh link"
  smoke_assert_contains "$out2" "\"remint\": true" "rotate is flagged as a re-mint (#2073 UX)"

  # 3) present the FRESH v2 link. The 1st POST (stale v1 key) is REJECTED, the
  # retry (candidate v2 key) is ACCEPTED → the refresh persists.
  join_seq bob "$link_v2" "reject,accept" || smoke_fail "A: self-heal join should succeed on the accepted retry"
  smoke_assert_eq "2" "$(seq_post_count)" \
    "A: the join made exactly TWO POSTs (stale-key attempt + candidate-key retry)"
  local healed_secret
  healed_secret="$(joiner_secret)"
  assert_not_eq "$stale_secret" "$healed_secret" \
    "A: the joiner's local leader-peer secret was REFRESHED (v1 → v2) after the leader ACCEPTED"
  local expected_v2 sig1 sig2
  expected_v2="$(python3 "$HELPER" derive-pair-key "$(token_from_link "$link_v2")" "$ROOM" "$NODE_A" "$NODE_B")"
  smoke_assert_eq "$expected_v2" "$healed_secret" \
    "A: the refreshed secret is the key derived from the FRESH (v2) token"
  # The 1st POST signed with the STALE key, the 2nd with the CANDIDATE key — prove
  # they differ (the retry really re-signed, it was not a blind replay).
  sig1="$(seq_post_sig 1)"; sig2="$(seq_post_sig 2)"
  assert_not_eq "$sig1" "$sig2" \
    "A: the retry RE-SIGNED with the candidate key (signatures differ from the stale-key attempt)"
}

# ---------------------------------------------------------------------------
# A2. PERSIST IS ACCEPTANCE-ANCHORED — if the leader REJECTS BOTH the stale-key
#     attempt AND the candidate-key retry (e.g. the supplied token is itself
#     stale, NOT the current one), NO refresh is persisted. This is the
#     DOWNGRADE-PROOF core (codex r2): a stale token's key never accepts, so it
#     is never written, by construction (no link/nonce trust).
# ---------------------------------------------------------------------------
test_persist_only_on_acceptance() {
  python3 "$HELPER" make-joiner-config "$CFG_B" "$NODE_B" "$ADDR_B" >/dev/null
  # Bootstrap a stale local peer via a FRESH room's gate-off first contact.
  local outb linkb
  outb="$(room_create_as hank)"
  linkb="$(json_field invite_link "$outb")"
  join_as hank "$linkb" || smoke_fail "A2: first contact should bootstrap"
  local before
  before="$(joiner_secret)"
  [[ -n "$before" ]] || smoke_fail "A2: expected a bootstrapped local peer"
  # Mint a DIFFERENT room's link (so its derived key differs) and present it: both
  # the stale-key attempt and the candidate-key retry are REJECTED by the leader.
  local outx linkx
  outx="$(room_create_as hank)"
  linkx="$(json_field invite_link "$outx")"
  join_seq hank "$linkx" "reject,reject" || true
  smoke_assert_eq "2" "$(seq_post_count)" \
    "A2: a rejected heal still PROBES twice (stale-key + candidate-key) before giving up"
  local after
  after="$(joiner_secret)"
  smoke_assert_eq "$before" "$after" \
    "A2 (downgrade-proof): when the leader REJECTS the candidate, NO refresh is persisted"
}

# ---------------------------------------------------------------------------
# A3. OVERRIDE-PROBE NON-PERSISTENCE INVARIANT (codex r3) — an override_secret
#     join probe must be INTRINSICALLY non-persistent: it may never bootstrap /
#     persist a peer from inside _post_room_join_request. We call the probe with
#     NO peer configured and assert it RAISES + writes NOTHING (defense in depth,
#     independent of the cmd_join call site that already only probes known peers).
# ---------------------------------------------------------------------------
test_override_probe_no_persist() {
  local probecfg="$SMOKE_TMP_ROOT/probe-nopeer.json"
  python3 "$HELPER" make-joiner-config "$probecfg" "$NODE_B" "$ADDR_B" >/dev/null
  local out room link raw
  out="$(room_create_as iris)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  raw="$(token_from_link "$link")"
  local res
  res="$(env "${TEST_FLAGS[@]}" python3 "$SEQ_HELPER" probe-no-bootstrap-persist \
           "$SMOKE_REPO_ROOT" "$probecfg" "$NODE_A" "$room" "$raw" 2>&1)"
  smoke_assert_contains "$res" "ok raised=override_probe_no_peer" \
    "A3 (codex r3): an override_secret probe RAISES on a missing peer (never bootstraps)"
  smoke_assert_contains "$res" "no_persist=1" \
    "A3 (codex r3): the override_secret probe persisted NOTHING to the config"
  # Belt-and-suspenders: the leader peer must NOT appear in the probe cfg.
  local ids
  ids="$(python3 "$HELPER" peer-ids "$probecfg")"
  smoke_assert_not_contains "$ids" "$NODE_A" \
    "A3 (codex r3): no leader peer was written by the override_secret probe"
}

# ---------------------------------------------------------------------------
# E. DOWNGRADE GUARD (codex r2) — a still-TTL-valid OLD link (even with a fresh
#    forged nonce) cannot downgrade an already-current secret. Because the join
#    tries the STORED (current) secret FIRST and the leader ACCEPTS it, the retry
#    never fires and the candidate (stale) key is never adopted. We model the
#    "current secret is accepted" first POST with verdicts=accept.
# ---------------------------------------------------------------------------
test_downgrade_replay_guard() {
  python3 "$HELPER" make-joiner-config "$CFG_B" "$NODE_B" "$ADDR_B" >/dev/null
  # Bootstrap a local peer (call it the CURRENT key) via a gate-off first contact.
  local outc linkc
  outc="$(room_create_as gwen)"
  linkc="$(json_field invite_link "$outc")"
  join_as gwen "$linkc" || smoke_fail "E: first contact should bootstrap"
  local current_secret
  current_secret="$(joiner_secret)"
  [[ -n "$current_secret" ]] || smoke_fail "E: expected a bootstrapped current peer"
  # Now present an OLD/other signed link whose derived key DIFFERS (a would-be
  # downgrade). The 1st POST signs with the CURRENT stored secret → the leader
  # ACCEPTS it (verdict=accept) → the retry NEVER fires → the candidate (stale)
  # key is NEVER adopted. The secret stays the current key.
  local outo linko
  outo="$(room_create_as gwen)"
  linko="$(json_field invite_link "$outo")"
  join_seq gwen "$linko" "accept" || smoke_fail "E: the current-key attempt should be accepted"
  smoke_assert_eq "1" "$(seq_post_count)" \
    "E: the current key was accepted on the FIRST POST → no downgrade retry fired"
  local after_replay
  after_replay="$(joiner_secret)"
  smoke_assert_eq "$current_secret" "$after_replay" \
    "E (codex r2): a would-be downgrade link does NOT change the already-current secret"
}

# ---------------------------------------------------------------------------
# B. TAXONOMY — a stale/unknown invite token (unknown-peer path) → the
#    actionable `stale_or_unknown_invite` 403, NEVER opaque bad_signature, and
#    NEVER the precise verdict (no oracle). We force the stale case by capturing
#    a join for an OLD token then rotating the leader's invite away from it.
# ---------------------------------------------------------------------------
test_taxonomy_stale_invite() {
  python3 "$HELPER" make-leader-config "$CFG_A" "$NODE_A" "$ADDR_A" >/dev/null
  python3 "$HELPER" make-joiner-config "$CFG_B" "$NODE_B" "$ADDR_B" >/dev/null
  local out room link
  out="$(room_create_as cara)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  # Capture a join for THIS (soon-to-be-stale) token.
  join_as cara "$link" || smoke_fail "capture an old-token request"
  # Leader rotates the invite away → the captured token no longer matches.
  rotate_invite_as cara "$room" >/dev/null
  local res
  res="$(deliver)"
  smoke_assert_contains "$res" "status=403" "B: a stale (rotated-away) token is 403"
  smoke_assert_contains "$res" "stale_or_unknown_invite" \
    "B: the reject carries the actionable stale_or_unknown_invite code"
  smoke_assert_contains "$res" "issue a fresh invite" \
    "B: the reply names the remedy (request a fresh invite)"
  smoke_assert_not_contains "$res" "bad_signature" \
    "B: a stale invite is NOT misreported as bad_signature"
  # NO ORACLE: the peer-facing reply must not leak the precise verdict word.
  smoke_assert_not_contains "$res" "mismatch" "B: no token-verdict (mismatch) leak to the peer"
  smoke_assert_not_contains "$res" "expired" "B: no token-verdict (expired) leak to the peer"
  smoke_assert_not_contains "$res" "revoked" "B: no token-verdict (revoked) leak to the peer"
  # The AUDIT keeps the precise subreason for the operator (local logs only).
  local audit="$BRIDGE_LOG_DIR/a2a-handoff.jsonl"
  if [[ -f "$audit" ]]; then
    smoke_assert_contains "$(grep room_join_reject "$audit" | tail -1)" \
      '"reason": "unknown_peer_token_' \
      "B: the audit keeps the precise unknown_peer_token_<verdict> subreason"
  fi
}

# ---------------------------------------------------------------------------
# C. MUTATION / NO OVER-COLLAPSE — a CURRENT-token candidate whose HMAC is
#    genuinely TAMPERED still → 401 bad_signature. The taxonomy must NOT swallow
#    a real bad-signature into the stale bucket.
# ---------------------------------------------------------------------------
test_tampered_body_still_bad_signature() {
  python3 "$HELPER" make-leader-config "$CFG_A" "$NODE_A" "$ADDR_A" >/dev/null
  python3 "$HELPER" make-joiner-config "$CFG_B" "$NODE_B" "$ADDR_B" >/dev/null
  local out room link raw
  out="$(room_create_as dora)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  raw="$(token_from_link "$link")"
  join_as dora "$link" || smoke_fail "capture a valid request"
  # Forge a signature with a key WRONGLY derived from the wire-visible
  # sha256(token) — the receiver's per-pair HMAC (from the seed) must reject it.
  # The token is CURRENT (verifies OK), so this exercises the HMAC stage, not
  # the token-validity stage — it MUST stay bad_signature, never stale.
  local wrong_key path mid ts body bodyhash canonical badsig
  wrong_key="$(python3 "$HELPER" token-hash-key "$raw" "$room" "$NODE_A" "$NODE_B")"
  path="$(python3 "$HELPER" captured-field "$CAPTURE" path)"
  mid="$(python3 "$HELPER" captured-field "$CAPTURE" header:X-AGB-Message-Id)"
  ts="$(python3 "$HELPER" captured-field "$CAPTURE" header:X-AGB-Timestamp)"
  body="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['body'])" "$CAPTURE")"
  bodyhash="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$body")"
  canonical="$(printf 'POST\n%s\n%s\n%s\n%s\n%s' "$path" "$NODE_B" "$mid" "$ts" "$bodyhash")"
  badsig="$(python3 -c "import hmac,hashlib,sys;print('v1='+hmac.new(bytes.fromhex(sys.argv[1]),sys.argv[2].encode(),hashlib.sha256).hexdigest())" "$wrong_key" "$canonical")"
  local res
  res="$(deliver '{"headers":{"X-AGB-Signature":"'"$badsig"'"}}')"
  smoke_assert_contains "$res" "status=401" \
    "C: a tampered HMAC on a CURRENT token is 401 (HMAC stage), not 403 stale"
  smoke_assert_contains "$res" "signature verification failed" \
    "C: the reject stays bad_signature (no over-collapse into the stale bucket)"
  smoke_assert_not_contains "$res" "stale_or_unknown_invite" \
    "C: a real bad-signature is NEVER relabeled stale_or_unknown_invite"
}

# ---------------------------------------------------------------------------
# D. BOUND — the self-heal must NOT clobber a peer whose secret it cannot
#    reproduce from a token (a legit hand-provisioned node-link). Plant a leader
#    peer with a non-token secret, then a join with a fresh signed link must NOT
#    overwrite it (the expected-old-secret guard refuses).
# ---------------------------------------------------------------------------
test_bound_no_clobber_legit_peer() {
  python3 "$HELPER" make-leader-config "$CFG_A" "$NODE_A" "$ADDR_A" >/dev/null
  python3 "$HELPER" make-joiner-config "$CFG_B" "$NODE_B" "$ADDR_B" >/dev/null
  local out room link
  out="$(room_create_as erin)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  # Plant a hand-provisioned leader peer on the JOINER with a deterministic,
  # NON-token secret (32 hex bytes). The self-heal must never touch it.
  local legit="cafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00d"
  python3 "$SCRIPT_DIR/2073-autojoin-stale-peer-selfheal-helper.py" \
    plant-peer "$CFG_B" "$NODE_A" "$ADDR_A" "$legit" >/dev/null
  local before
  before="$(joiner_secret)"
  smoke_assert_eq "$legit" "$before" "D: planted a legit (non-token) leader peer secret"
  # A join with a fresh signed link: the self-heal compares the v-token key to
  # the planted secret. They differ, but the refresh's expected_old_secret guard
  # only proceeds when the stored secret IS the value the caller derived as the
  # CURRENT one — here the caller's current_secret == the planted legit value,
  # so the refresh WOULD compute a new key. The guarantee is the guard refuses to
  # overwrite a value it did not stage. We assert the secret is NOT silently
  # replaced by a token-derived key (it stays the legit value OR the join still
  # signs with the planted secret). Either way the legit secret is preserved.
  join_as erin "$link" || true
  local after
  after="$(joiner_secret)"
  # The planted legit secret must remain the active secret (not clobbered to a
  # token-derived value the operator never installed).
  smoke_assert_eq "$legit" "$after" \
    "D (bound): a legit hand-provisioned peer secret is NOT clobbered by the self-heal"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "setup: room + v2 signed invite (link v1)" test_setup
smoke_run "A: stale-local-peer self-heal across a re-mint (acceptance-anchored retry persists the refresh)" test_self_heal_across_remint
smoke_run "A2: persist is acceptance-anchored — a leader-rejected candidate is NOT persisted (downgrade-proof)" test_persist_only_on_acceptance
smoke_run "A3: override_secret probe is intrinsically non-persistent — raises on missing peer (codex r3)" test_override_probe_no_persist
smoke_run "E: downgrade guard — a would-be downgrade link does NOT change an already-current secret (codex r2)" test_downgrade_replay_guard
smoke_run "B: taxonomy — a stale invite → stale_or_unknown_invite (no opaque bad_signature, no oracle)" test_taxonomy_stale_invite
smoke_run "C: mutation — a tampered HMAC on a current token STILL → bad_signature (no over-collapse)" test_tampered_body_still_bad_signature
smoke_run "D: bound — the self-heal does NOT clobber a legit hand-provisioned peer secret" test_bound_no_clobber_legit_peer

smoke_log "passed"
