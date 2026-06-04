#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1470-engine-auth-seam.sh — fleet-credential Phase 1.
#
# Issue #1470 (umbrella) Phase 1: the engine-auth descriptor seam +
# cred-generation schema groundwork. This smoke pins two contracts:
#
#   A. The engine-auth descriptor (lib/bridge-engine-descriptor.sh)
#      dispatches Claude through the seam with behavior-preserving
#      values — the Claude credential path stays byte-identical to the
#      pre-seam hardcoded shape (`.claude/.credentials.json` dest,
#      `claudeAiOauth` payload key, rotating-pool model, native-oauth
#      usage source, rotation supported). Codex gets a descriptor slot
#      only (single-source-sync, opaque copy, no rotation); antigravity
#      degrades cleanly to auth_supported=no.
#
#   B. The cred-generation state store (bridge-auth.py) is idempotent +
#      fail-closed: the per-agent generation bumps only when the synced
#      credential digest changes, the state file lands mode 0600, the
#      secret is NEVER written to state, and a corrupt state file
#      migrates to a fresh default rather than raising.
#
# Phase 1 is a behavior-preserving refactor — the descriptor exists so
# bridge-auth dispatches BY ENGINE instead of hardcoding Claude; Claude
# must behave identically. The Codex adapter (register/sync/verify) is
# Phase 2 and is intentionally NOT exercised here.
#
# Isolation: temp working dir under /tmp; no live BRIDGE_HOME reads/writes.

set -euo pipefail

SMOKE_NAME="1470-engine-auth-seam"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

REPO_ROOT="$SMOKE_REPO_ROOT"
DESCRIPTOR="$REPO_ROOT/lib/bridge-engine-descriptor.sh"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
[[ -f "$DESCRIPTOR" ]] || smoke_fail "missing helper: $DESCRIPTOR"
[[ -f "$AUTH_PY" ]] || smoke_fail "missing helper: $AUTH_PY"

smoke_make_temp_root "$SMOKE_NAME"

# ───────────────────────── Part A: descriptor seam ─────────────────────
# Each accessor is exercised in a fresh `bash -c` so rc / stdout are not
# polluted by a stale function from the parent shell. The descriptor is
# dependency-free (pure case-table accessors), so direct sourcing is safe.

assert_descriptor_out() {
  local fn="$1"
  shift
  local expected_out="$1"
  local expected_rc="$2"
  local context="$3"
  shift 3
  local args="$*"
  local out rc
  set +e
  out="$(bash -c "source '$DESCRIPTOR'; $fn $args" 2>/dev/null)"
  rc=$?
  set -e
  smoke_assert_eq "$expected_out" "$out" "$context: stdout"
  smoke_assert_eq "$expected_rc" "$rc" "$context: rc"
}

assert_descriptor_rc() {
  local fn="$1"
  local expected_rc="$2"
  local context="$3"
  shift 3
  local args="$*"
  local rc
  set +e
  bash -c "source '$DESCRIPTOR'; $fn $args" >/dev/null 2>&1
  rc=$?
  set -e
  smoke_assert_eq "$expected_rc" "$rc" "$context: rc"
}

# A1: auth_supported — claude/codex managed (rc=0), antigravity NOT (rc=1).
smoke_run "A1a claude auth_supported (rc=0)" \
  assert_descriptor_rc bridge_engine_auth_supported 0 "A1a" claude
smoke_run "A1b codex auth_supported (rc=0)" \
  assert_descriptor_rc bridge_engine_auth_supported 0 "A1b" codex
smoke_run "A1c antigravity auth_unsupported (rc=1)" \
  assert_descriptor_rc bridge_engine_auth_supported 1 "A1c" antigravity
smoke_run "A1d unknown auth_unsupported (rc=1)" \
  assert_descriptor_rc bridge_engine_auth_supported 1 "A1d" nonesuch

# A2: auth_model — the per-engine credential-management model.
smoke_run "A2a claude → rotating-pool" \
  assert_descriptor_out bridge_engine_auth_model rotating-pool 0 "A2a" claude
smoke_run "A2b codex → single-source-sync" \
  assert_descriptor_out bridge_engine_auth_model single-source-sync 0 "A2b" codex
smoke_run "A2c antigravity → none" \
  assert_descriptor_out bridge_engine_auth_model none 0 "A2c" antigravity

# A3: cred_dest_path — Claude tail byte-identical to the historical literal.
smoke_run "A3a claude dest tail unchanged" \
  assert_descriptor_out bridge_engine_cred_dest_path .claude/.credentials.json 0 "A3a" agentx claude
smoke_run "A3b codex dest tail" \
  assert_descriptor_out bridge_engine_cred_dest_path .codex/auth.json 0 "A3b" agentx codex

# A4: cred_source — registry for Claude, agent-source for Codex.
smoke_run "A4a claude → registry" \
  assert_descriptor_out bridge_engine_cred_source registry 0 "A4a" claude
smoke_run "A4b codex → agent-source" \
  assert_descriptor_out bridge_engine_cred_source agent-source 0 "A4b" codex

# A5: supports_rotation — claude yes, codex/antigravity no.
smoke_run "A5a claude supports rotation (rc=0)" \
  assert_descriptor_rc bridge_engine_supports_rotation 0 "A5a" claude
smoke_run "A5b codex no rotation (rc=1)" \
  assert_descriptor_rc bridge_engine_supports_rotation 1 "A5b" codex

# A6: usage_source — native probe for Claude, observe-only snapshots for Codex.
smoke_run "A6a claude → native-oauth-probe" \
  assert_descriptor_out bridge_engine_usage_source native-oauth-probe 0 "A6a" claude
smoke_run "A6b codex → codex-snapshots" \
  assert_descriptor_out bridge_engine_usage_source codex-snapshots 0 "A6b" codex

# A7: cred_payload_key — Claude `claudeAiOauth`; Codex opaque-copy (empty, rc=0).
smoke_run "A7a claude → claudeAiOauth" \
  assert_descriptor_out bridge_engine_cred_payload_key claudeAiOauth 0 "A7a" claude
smoke_run "A7b codex → empty (opaque copy, rc=0)" \
  assert_descriptor_out bridge_engine_cred_payload_key '' 0 "A7b" codex

# A8: Python-side mirror agrees with the bash descriptor for Claude and the
# Claude credential payload key is byte-identical to the historical shape.
# The Python body lives in 1470-engine-auth-seam-helper.py (file-as-argv,
# NO heredoc) so the smoke does not introduce a `python3 - <<'PY'`-in-
# command-substitution deadlock site (footgun #11 / KNOWN_ISSUES §26).
assert_py_seam() {
  local out
  out="$(python3 "$SCRIPT_DIR/1470-engine-auth-seam-helper.py" seam-mirror "$AUTH_PY")"
  smoke_assert_eq "py-seam-ok" "$out" "A8 python seam mirror"
}
smoke_run "A8 python descriptor mirror + claude payload byte-identical" \
  assert_py_seam

# ─────────────────── Part B: cred-generation state ─────────────────────
# Idempotent + fail-closed schema groundwork (Q4). Driven through the
# bridge-auth.py state helpers directly so the smoke does not need a full
# agent runtime; the daemon/sync wiring is exercised by the existing
# daemon-periodic-token-sync + F-beta4-oauth-bootstrap smokes.

STATE_FILE="$SMOKE_TMP_ROOT/cred-state.json"

# The cred-state Python body lives in 1470-engine-auth-seam-helper.py
# (file-as-argv, NO heredoc) for the same footgun-#11 reason as A8 above.
assert_cred_state() {
  local out
  out="$(python3 "$SCRIPT_DIR/1470-engine-auth-seam-helper.py" cred-state "$AUTH_PY" "$STATE_FILE")"
  smoke_assert_eq "cred-state-ok" "$out" "B cred-generation state"
}
smoke_run "B cred-generation idempotent + fail-closed + 0600 + no-secret" \
  assert_cred_state

# ─────────────── Part C: sync-agent --engine fail-closed gate ───────────
# Phase 1's `cmd_sync_agent` IS the Claude write path. A non-Claude
# `--engine` (or an unknown one) MUST be refused BEFORE any registry read
# or credential write — Codex/Gemini are descriptor slots, their adapter
# is Phase 2. This pins that `--engine codex` and `--engine bogus` cannot
# execute the Claude sync body (codex r1 BLOCKING).

REG_FILE="$SMOKE_TMP_ROOT/claude-oauth-tokens.json"
DEST_DIR="$SMOKE_TMP_ROOT/agent-home/.claude"
DEST_FILE="$DEST_DIR/.credentials.json"
# A registry with one active token so the Claude path WOULD write if the
# gate were absent. The token is a smoke-only fake.
mkdir -p "$DEST_DIR"
# Fixture registry written with printf (not a heredoc) so no new
# heredoc-stdin site remains anywhere in this smoke (footgun #11 hygiene).
# The token is a smoke-only fake.
printf '%s\n' \
  '{' \
  '  "version": 1,' \
  '  "active_token_id": "smoke",' \
  '  "auto_rotate_enabled": false,' \
  '  "rotation_threshold": 99.0,' \
  '  "tokens": [' \
  '    {"id": "smoke", "token": "FAKE-OAT-FOR-SMOKE-0001", "enabled": true}' \
  '  ],' \
  '  "last_rotation": {}' \
  '}' >"$REG_FILE"

assert_engine_gate() {
  local engine="$1"
  local context="$2"
  local out rc
  set +e
  out="$(BRIDGE_AUTH_CRED_STATE_FILE="$SMOKE_TMP_ROOT/c-cred-state.json" \
    python3 "$REPO_ROOT/bridge-auth.py" --registry "$REG_FILE" sync-agent \
      --agent smoke --file "$DEST_FILE" --engine "$engine" \
      --allowed-root "$SMOKE_TMP_ROOT/agent-home" --json 2>&1)"
  rc=$?
  set -e
  # Must fail (rc != 0) and must NOT have written the Claude credential.
  [[ "$rc" -ne 0 ]] || smoke_fail "$context: expected non-zero rc, got 0; out=$out"
  smoke_assert_not_contains "$out" "claude_credentials_file" "$context: no Claude delivery"
  [[ ! -e "$DEST_FILE" ]] || smoke_fail "$context: Claude credential file WAS written for engine=$engine"
}

# C1: --engine codex (known, non-Claude) → refused, no write.
smoke_run "C1 sync-agent --engine codex refused (no Claude write)" \
  assert_engine_gate codex "C1"

# C2: --engine bogus (unknown) → refused, no write.
smoke_run "C2 sync-agent --engine bogus refused (no Claude write)" \
  assert_engine_gate bogus-engine "C2"

# C3: control — default (claude, no --engine) still WRITES the Claude
# credential, proving the gate did not break the happy path.
assert_engine_default_writes() {
  local out rc
  rm -f "$DEST_FILE"
  set +e
  out="$(BRIDGE_AUTH_CRED_STATE_FILE="$SMOKE_TMP_ROOT/c-cred-state.json" \
    python3 "$REPO_ROOT/bridge-auth.py" --registry "$REG_FILE" sync-agent \
      --agent smoke --file "$DEST_FILE" \
      --allowed-root "$SMOKE_TMP_ROOT/agent-home" --json 2>&1)"
  rc=$?
  set -e
  smoke_assert_eq 0 "$rc" "C3: default engine rc"
  smoke_assert_contains "$out" "claude_credentials_file" "C3: Claude delivery present"
  smoke_assert_contains "$out" '"engine": "claude"' "C3: engine field claude"
  [[ -e "$DEST_FILE" ]] || smoke_fail "C3: Claude credential file should exist on default path"
}
smoke_run "C3 default engine (claude) still writes — gate did not break happy path" \
  assert_engine_default_writes

# C4: --engine "" (EXPLICIT empty string) MUST be refused, not coerced to
# the Claude default (codex r2 BLOCKING). The destination is a
# `.codex/auth.json` path to model the exact cross-engine
# credential-misdelivery hole: a Phase-2 caller passing an empty engine
# var must NOT write a Claude credential into the Codex dest. Asserts:
# non-zero/refused status, the response does NOT report engine:claude or
# status:synced, and NO file is written at the Codex dest.
CODEX_DEST_DIR="$SMOKE_TMP_ROOT/codex-home/.codex"
CODEX_DEST_FILE="$CODEX_DEST_DIR/auth.json"
mkdir -p "$CODEX_DEST_DIR"

assert_empty_engine_refused() {
  local engine_value="$1"
  local context="$2"
  local out rc
  rm -f "$CODEX_DEST_FILE"
  set +e
  out="$(BRIDGE_AUTH_CRED_STATE_FILE="$SMOKE_TMP_ROOT/c-cred-state.json" \
    python3 "$REPO_ROOT/bridge-auth.py" --registry "$REG_FILE" sync-agent \
      --agent smoke --file "$CODEX_DEST_FILE" --engine "$engine_value" \
      --allowed-root "$SMOKE_TMP_ROOT/codex-home" --json 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || smoke_fail "$context: expected non-zero rc, got 0; out=$out"
  smoke_assert_not_contains "$out" '"status": "synced"' "$context: not synced"
  smoke_assert_not_contains "$out" '"engine": "claude"' "$context: no claude engine"
  smoke_assert_not_contains "$out" "claude_credentials_file" "$context: no Claude delivery"
  [[ ! -e "$CODEX_DEST_FILE" ]] || smoke_fail "$context: a credential WAS written into the Codex dest for engine='$engine_value'"
}

# C4: explicit empty string → refused, nothing written to the Codex dest.
smoke_run "C4 sync-agent --engine '' refused (no Claude write into Codex dest)" \
  assert_empty_engine_refused "" "C4"

# C5: whitespace-only → same refusal (no truthiness/strip bypass).
smoke_run "C5 sync-agent --engine '   ' refused (no Claude write into Codex dest)" \
  assert_empty_engine_refused "   " "C5"

smoke_log "smoke test passed"
