#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1470-codex-fleet-sync.sh — fleet-credential Phase 2 (#1470).
#
# Issue #1470 (umbrella) Phase 2: the Codex register-once → fleet-sync
# adapter. The operator `codex login`s ONCE on a designated source agent;
# the bridge write-throughs that source's .codex/auth.json to every
# managed Codex agent. This smoke pins the security teeth the design
# (docs/design/fleet-credential-design.md §6/§7) makes the gate:
#
#   A. Write-through delivery (NOT symlink): a sync lands the source
#      auth.json byte-identical at the dest, mode 0600, a regular file.
#   B. Digest idempotency: an unchanged source is a no-op (no rewrite, no
#      generation bump); a changed source re-syncs + bumps the generation.
#   C. Source unreadable / malformed → fail loud, NO propagation, no
#      partial write.
#   D. Symlink-dest refusal: the adapter refuses to write through a
#      pre-placed symlink at the dest (no out-of-home redirect).
#   E. No cross-engine misdelivery: codex-sync refuses --engine claude
#      BEFORE any write (the Phase-1 fail-closed gate holds end-to-end).
#   F. No secret in state: the cred-state records only a digest, never the
#      auth material.
#   G. Active-scrub (Q6): the secret-scrub primitive removes the OpenAI-
#      key / Codex-token env vars from a captured child env; restore puts
#      them back only when asked.
#   H. Offline well-formedness / source-binding round-trip (Python teeth).
#
# Isolation: temp working dir under /tmp; no live BRIDGE_HOME reads/writes.
# All credential strings are smoke-only fakes.

set -euo pipefail

SMOKE_NAME="1470-codex-fleet-sync"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

REPO_ROOT="$SMOKE_REPO_ROOT"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
SCRUB_LIB="$REPO_ROOT/lib/bridge-secret-scrub.sh"
HELPER="$SCRIPT_DIR/1470-codex-fleet-sync-helper.py"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing helper: $AUTH_PY"
[[ -f "$SCRUB_LIB" ]] || smoke_fail "missing helper: $SCRUB_LIB"
[[ -f "$HELPER" ]] || smoke_fail "missing helper: $HELPER"

smoke_make_temp_root "$SMOKE_NAME"

REG="$SMOKE_TMP_ROOT/reg.json"
printf '%s' '{}' >"$REG"
export BRIDGE_STATE_DIR="$SMOKE_TMP_ROOT/state"
mkdir -p "$BRIDGE_STATE_DIR/auth"

SRC_DIR="$SMOKE_TMP_ROOT/src/.codex"
DST_DIR="$SMOKE_TMP_ROOT/dst/.codex"
mkdir -p "$SRC_DIR" "$DST_DIR"
SRC="$SRC_DIR/auth.json"
DST="$DST_DIR/auth.json"
# Smoke-only fake Codex subscription auth.json (tokens shape).
printf '%s' '{"tokens":{"access_token":"FAKE-CODEX-ACCESS-0001","refresh_token":"FAKE-REFRESH-0001"}}' >"$SRC"

codex_cli() {
  python3 "$AUTH_PY" --registry "$REG" "$@"
}

# ── A: write-through delivery (byte-identical, 0600, regular file) ──────
assert_write_through() {
  rm -f "$DST"
  local out
  out="$(codex_cli codex-sync --agent dst --source-file "$SRC" --file "$DST" --json 2>&1)"
  smoke_assert_contains "$out" '"status": "synced"' "A: synced status"
  smoke_assert_contains "$out" '"delivery": "codex_auth_file"' "A: delivery field"
  [[ -f "$DST" ]] || smoke_fail "A: dest auth.json not written"
  [[ -L "$DST" ]] && smoke_fail "A: dest is a SYMLINK (must be a write-through copy)"
  diff -q "$SRC" "$DST" >/dev/null || smoke_fail "A: dest bytes differ from source (not byte-identical)"
  # Portable LOW-bits mode helper: GNU `stat -c '%a'` (Linux) FIRST, BSD
  # `stat -f '%Lp'` (macOS) fallback. The reverse order is a footgun — on
  # Linux `stat -f` means "filesystem status" and succeeds with garbage.
  local mode
  mode="$(stat -c '%a' "$DST" 2>/dev/null || stat -f '%Lp' "$DST" 2>/dev/null)"
  smoke_assert_eq "600" "$mode" "A: dest mode 0600"
}
smoke_run "A write-through delivery: byte-identical 0600 regular file (not symlink)" \
  assert_write_through

# ── B: digest idempotency (unchanged no-op; changed re-sync + bump) ─────
assert_digest_gate() {
  local out gen1 gen2
  # First sync already done in A → generation 1.
  out="$(codex_cli codex-sync --agent dst --source-file "$SRC" --file "$DST" --json 2>&1)"
  smoke_assert_contains "$out" '"status": "unchanged"' "B: re-sync of same source is a no-op"
  # Change the source → re-sync + generation bump.
  printf '%s' '{"tokens":{"access_token":"FAKE-CODEX-ACCESS-0002"}}' >"$SRC"
  out="$(codex_cli codex-sync --agent dst --source-file "$SRC" --file "$DST" --json 2>&1)"
  smoke_assert_contains "$out" '"status": "synced"' "B: changed source re-syncs"
  gen2="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cred_generation"])')"
  smoke_assert_eq "2" "$gen2" "B: generation bumped to 2 on digest change"
  diff -q "$SRC" "$DST" >/dev/null || smoke_fail "B: dest not updated to the new source bytes"
}
smoke_run "B digest idempotency: unchanged=no-op, changed=re-sync + generation bump" \
  assert_digest_gate

# ── C: source malformed / unreadable → fail loud, no write ─────────────
assert_fail_loud() {
  local bad="$SMOKE_TMP_ROOT/bad.json"
  printf '%s' '{ not valid json' >"$bad"
  local cdst="$SMOKE_TMP_ROOT/cdst/.codex/auth.json"
  mkdir -p "$(dirname "$cdst")"
  local out rc
  set +e
  out="$(codex_cli codex-sync --agent cdst --source-file "$bad" --file "$cdst" --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "C: expected non-zero rc on malformed source, got 0; out=$out"
  smoke_assert_contains "$out" '"status": "error"' "C: error status on malformed source"
  [[ ! -e "$cdst" ]] || smoke_fail "C: a credential WAS written despite malformed source"
  # An unrecognized-shape (valid JSON but no Codex credential) is also refused.
  local nocred="$SMOKE_TMP_ROOT/nocred.json"
  printf '%s' '{"hello":"world"}' >"$nocred"
  set +e
  out="$(codex_cli codex-verify --file "$nocred" --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "C: verify accepted an unrecognized shape"
  smoke_assert_contains "$out" '"status": "rejected"' "C: verify rejects unrecognized shape"
}
smoke_run "C source malformed/unreadable/unrecognized → fail loud, no propagation" \
  assert_fail_loud

# ── D: symlink-dest refusal ────────────────────────────────────────────
assert_symlink_refused() {
  local sdst_dir="$SMOKE_TMP_ROOT/sdst/.codex"
  local evil="$SMOKE_TMP_ROOT/evil-target.json"
  mkdir -p "$sdst_dir"
  ln -sf "$evil" "$sdst_dir/auth.json"
  local out rc
  set +e
  out="$(codex_cli codex-sync --agent sdst --source-file "$SRC" --file "$sdst_dir/auth.json" --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "D: expected refusal writing through a symlink, got rc=0; out=$out"
  smoke_assert_contains "$out" "symlink" "D: refusal message names the symlink"
  [[ ! -e "$evil" ]] || smoke_fail "D: the symlink target WAS written (out-of-home redirect!)"
}
smoke_run "D symlink-dest refusal: no write through a pre-placed symlink" \
  assert_symlink_refused

# ── E: no cross-engine misdelivery ─────────────────────────────────────
assert_cross_engine_refused() {
  rm -f "$DST"
  local out rc
  set +e
  out="$(codex_cli codex-sync --agent dst --source-file "$SRC" --file "$DST" --engine claude --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "E: codex-sync accepted --engine claude (cross-engine hole!)"
  smoke_assert_contains "$out" '"status": "error"' "E: error status on engine=claude"
  smoke_assert_not_contains "$out" '"status": "synced"' "E: nothing synced"
  # And the Phase-1 Claude sync-agent still refuses --engine codex (the
  # other direction of the gate — pinned here for end-to-end coverage).
  set +e
  out="$(codex_cli sync-agent --agent x --file "$SMOKE_TMP_ROOT/claude-dst/.credentials.json" \
    --engine codex --allowed-root "$SMOKE_TMP_ROOT/claude-dst" --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "E: claude sync-agent accepted --engine codex"
}
smoke_run "E no cross-engine misdelivery: codex-sync refuses claude, claude sync refuses codex" \
  assert_cross_engine_refused

# ── F: no secret in cred-state ─────────────────────────────────────────
assert_no_secret_in_state() {
  # Re-sync to ensure a fresh stamp.
  printf '%s' '{"tokens":{"access_token":"FAKE-SECRET-MARKER-XYZ"}}' >"$SRC"
  codex_cli codex-sync --agent dst --source-file "$SRC" --file "$DST" --json >/dev/null 2>&1
  local state="$BRIDGE_STATE_DIR/auth/cred-state.json"
  [[ -f "$state" ]] || smoke_fail "F: cred-state file missing after sync"
  if grep -q "FAKE-SECRET-MARKER-XYZ" "$state"; then
    smoke_fail "F: secret material LEAKED into cred-state.json"
  fi
}
smoke_run "F no secret in cred-state: only the digest is recorded" \
  assert_no_secret_in_state

# ── G: active-scrub primitive (Q6) ─────────────────────────────────────
# The Codex ambient-key capture removes OPENAI_API_KEY / CODEX_ACCESS_TOKEN
# from the env (so a managed Codex child sees them absent); restore puts
# them back. Exercised through the shared primitive in a fresh bash -c so
# the parent env is untouched. The values are smoke-only fakes.
assert_codex_scrub() {
  local out
  out="$(OPENAI_API_KEY='sk-FAKE-OPENAI-G' CODEX_ACCESS_TOKEN='FAKE-CODEX-TOK-G' \
    bash -c '
      source "'"$SCRUB_LIB"'"
      bridge_secret_scrub_capture_codex _ok _ct
      # After capture: env must be SCRUBBED (absent for a managed child).
      printf "post_capture_openai=[%s]\n" "${OPENAI_API_KEY:-ABSENT}"
      printf "post_capture_codex=[%s]\n" "${CODEX_ACCESS_TOKEN:-ABSENT}"
      # The captured values live in the NON-exported shell vars.
      printf "captured_openai=[%s]\n" "$_ok"
      printf "captured_codex=[%s]\n" "$_ct"
      # Restore re-exports them.
      bridge_secret_scrub_restore_codex _ok _ct
      printf "post_restore_openai=[%s]\n" "${OPENAI_API_KEY:-ABSENT}"
    ' 2>&1)"
  smoke_assert_contains "$out" 'post_capture_openai=[ABSENT]' "G: OPENAI key scrubbed from env after capture"
  smoke_assert_contains "$out" 'post_capture_codex=[ABSENT]' "G: Codex token scrubbed from env after capture"
  smoke_assert_contains "$out" 'captured_openai=[sk-FAKE-OPENAI-G]' "G: captured value preserved in shell var"
  smoke_assert_contains "$out" 'post_restore_openai=[sk-FAKE-OPENAI-G]' "G: restore re-exports the value"
}
smoke_run "G active-scrub: OpenAI-key / Codex-token removed from managed child env, restorable" \
  assert_codex_scrub

# ── H: offline well-formedness / snapshot / source-binding (Python) ─────
assert_wellformed() {
  local out
  out="$(python3 "$HELPER" wellformed "$AUTH_PY")"
  smoke_assert_eq "wellformed-ok" "$out" "H1 codex_auth_wellformed"
}
smoke_run "H1 offline well-formedness gate (tokens/apikey accept, junk reject)" \
  assert_wellformed

assert_snapshot() {
  local good="$SMOKE_TMP_ROOT/snap-good.json"
  local bad="$SMOKE_TMP_ROOT/snap-bad.json"
  printf '%s' '{"tokens":{"access_token":"FAKE-SNAP-0001"}}' >"$good"
  printf '%s' '{ broken' >"$bad"
  local out
  out="$(python3 "$HELPER" snapshot "$AUTH_PY" "$good" "$bad")"
  smoke_assert_eq "snapshot-ok" "$out" "H2 read_codex_auth_snapshot"
}
smoke_run "H2 atomic snapshot validate+digest; malformed/missing raise" \
  assert_snapshot

assert_source_binding() {
  local binding="$SMOKE_TMP_ROOT/codex-source.json"
  local out
  out="$(python3 "$HELPER" source-binding "$AUTH_PY" "$binding")"
  smoke_assert_eq "source-binding-ok" "$out" "H3 source-binding round-trip"
}
smoke_run "H3 source-binding persisted 0600, reloads, corrupt degrades to empty" \
  assert_source_binding

# ── I: blank-engine coercion refused (codex r1 BLOCKING) ───────────────
# An explicit `--engine ""` / `"   "` must be REFUSED, not coerced to the
# codex default — an empty engine is an attacker-shaped value.
assert_blank_engine_refused() {
  local engine_value="$1"
  local context="$2"
  local idst="$SMOKE_TMP_ROOT/idst/.codex/auth.json"
  mkdir -p "$(dirname "$idst")"
  rm -f "$idst"
  local out rc
  set +e
  out="$(codex_cli codex-sync --agent idst --source-file "$SRC" --file "$idst" \
    --engine "$engine_value" --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "$context: blank engine '$engine_value' was accepted (coerced to codex)"
  smoke_assert_not_contains "$out" '"status": "synced"' "$context: nothing synced"
  [[ ! -e "$idst" ]] || smoke_fail "$context: a credential was written for blank engine"
}
smoke_run "I1 sync --engine '' refused (no coercion to codex)" \
  assert_blank_engine_refused "" "I1"
smoke_run "I2 sync --engine '   ' refused" \
  assert_blank_engine_refused "   " "I2"

# ── J: symlinked-PARENT (.codex dir) refusal (codex r1 BLOCKING) ────────
# The agent could pre-place `.codex` itself as a symlink to redirect the
# privileged write out of its home; --allowed-root must reject it.
assert_parent_symlink_refused() {
  local home="$SMOKE_TMP_ROOT/jhome"
  local evil="$SMOKE_TMP_ROOT/jevil"
  mkdir -p "$home" "$evil"
  # .codex is a symlink pointing OUTSIDE the agent home.
  ln -sf "$evil" "$home/.codex"
  local jdst="$home/.codex/auth.json"
  local out rc
  set +e
  out="$(codex_cli codex-sync --agent jdst --source-file "$SRC" --file "$jdst" \
    --allowed-root "$home" --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "J: write through a symlinked-parent .codex was accepted; out=$out"
  [[ ! -e "$evil/auth.json" ]] || smoke_fail "J: the symlink-target dir was written (out-of-home redirect!)"
}
smoke_run "J symlinked-parent .codex refused (no out-of-home redirect via parent)" \
  assert_parent_symlink_refused

# ── K: rollback only to the recorded last-known-good (codex r1 BLOCKING) ─
# After a successful sync (gen N), if an attacker swaps the dest to a
# DIFFERENT (valid-shape but wrong-source) file, a subsequent failed sync
# must NOT adopt that swapped file as the rollback target.
assert_rollback_not_to_wrong_source() {
  local khome="$SMOKE_TMP_ROOT/khome/.codex"
  mkdir -p "$khome"
  local kdst="$khome/auth.json"
  # Establish a known-good gen-1 sync.
  printf '%s' '{"tokens":{"access_token":"K-GOOD-GEN1"}}' >"$SRC"
  codex_cli codex-sync --agent kagent --source-file "$SRC" --file "$kdst" --json >/dev/null 2>&1
  # Attacker swaps the dest to a valid-shape WRONG-SOURCE file.
  printf '%s' '{"tokens":{"access_token":"K-ATTACKER-SWAPPED"}}' >"$kdst"
  # New source; force a write FAILURE by chowning to root (non-root caller).
  printf '%s' '{"tokens":{"access_token":"K-GOOD-GEN2"}}' >"$SRC"
  local out rc
  set +e
  out="$(codex_cli codex-sync --agent kagent --source-file "$SRC" --file "$kdst" \
    --owner-uid 0 --owner-gid 0 --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "K: expected the chown-to-root write to fail; out=$out"
  # The rollback must NOT have adopted the attacker-swapped file as LKG —
  # the backup was gated on digest==recorded-gen, which the swapped file
  # fails. The dest is therefore either untouched (atomic writer left the
  # swapped file, since chown failed pre-replace) — assert the message does
  # NOT claim a rollback to the swapped material.
  smoke_assert_not_contains "$out" "rolled back to last-known-good" "K: no rollback to a wrong-source file"
}
smoke_run "K rollback never adopts an attacker-swapped wrong-source dest" \
  assert_rollback_not_to_wrong_source

# ── L: dir_fd writer rejects a symlinked parent at OPEN (codex r2 BLOCKING) ─
# The parent-pinned writer opens `.codex` with O_DIRECTORY|O_NOFOLLOW, so a
# symlinked parent fails at open even independent of the pre-check — the
# defense against the live parent-swap TOCTOU. Driven via the Python helper
# so the smoke exercises write_private_file_atomic_dirfd directly.
assert_dirfd_writer_hardening() {
  local out
  out="$(python3 "$HELPER" dirfd-writer "$AUTH_PY" "$SMOKE_TMP_ROOT/dirfd")"
  smoke_assert_eq "dirfd-writer-ok" "$out" "L dir_fd writer hardening"
}
smoke_run "L dir_fd writer: O_NOFOLLOW rejects symlinked parent; allowed_root enforced" \
  assert_dirfd_writer_hardening

# ── M: LIVE parent-swap refused on every platform (codex Phase-4 BLOCKING) ──
# The exact codex repro: monkeypatch os.open so the dest parent `.codex` is
# RENAMED OUTSIDE allowed_root the instant the writer opens it, with an in-root
# decoy dropped in its place. The fix checks the OPENED FD's identity (F_GETPATH
# on Darwin, /proc/self/fd on Linux; fail-closed otherwise) — NOT a string
# re-resolution that the decoy would defeat. The write MUST be REFUSED and land
# NOTHING inside the decoy OR outside the root. This is the macOS-specific hole
# the old `parent.resolve()` fallback left open; the tooth exercises the
# F_GETPATH path on macOS and the procfs path on Linux.
assert_live_swap_refused() {
  local out
  out="$(python3 "$HELPER" live-swap "$AUTH_PY" "$SMOKE_TMP_ROOT/liveswap")"
  smoke_assert_eq "live-swap-refused-ok" "$out" "M live parent-swap refused (fd identity)"
}
smoke_run "M live parent-swap refused on this platform (fd identity, no string re-resolve)" \
  assert_live_swap_refused

# ── N: sync-level live-swap → error envelope + no write (audit-able) ────────
# At the cmd_codex_sync orchestration layer a refused dir_fd write surfaces as
# a structured `"status": "error"` envelope (the audit-able outcome) and writes
# NO credential. We can't easily race os.open through the CLI, so we assert the
# orchestration refusal shape for the symlinked-parent case (same refusal path
# the live-swap takes): error envelope, non-zero rc, nothing written.
assert_sync_refusal_is_auditable() {
  local nhome="$SMOKE_TMP_ROOT/nhome"
  local nevil="$SMOKE_TMP_ROOT/nevil"
  mkdir -p "$nhome" "$nevil"
  ln -sf "$nevil" "$nhome/.codex"
  local out rc
  set +e
  out="$(codex_cli codex-sync --agent nagent --source-file "$SRC" \
    --file "$nhome/.codex/auth.json" --allowed-root "$nhome" --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "N: expected refusal rc, got 0; out=$out"
  smoke_assert_contains "$out" '"status": "error"' "N: error envelope (audit-able)"
  [[ ! -e "$nevil/auth.json" ]] || smoke_fail "N: credential leaked outside via the parent symlink"
}
smoke_run "N sync-level refusal emits an error envelope + writes nothing (auditable)" \
  assert_sync_refusal_is_auditable

smoke_log "smoke test passed"
