#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/token-updater-swap-or-defer.sh — #21895 phase-1, sub-PR 3/4 (HIGH-RISK auth).
#
# THE FEATURE: the ONE shared lease-authoritative swap-or-defer authority
# (bridge-auth.py:token_updater_lease_swap_or_defer + `claude-token
# lease-swap-or-defer` verb) that every live Claude-token rotator routes its
# rotate decision through WHEN the token-updater lease is ENABLED. When DISABLED,
# each rotator keeps today's local `cmd_rotate` behavior byte-for-byte (the
# load-bearing default-OFF invariant).
#
# Isolation: a temp BRIDGE_HOME via smoke_setup_bridge_home; the runtime-secrets
# dir + registry are pinned under it. NEVER touches the real ~/.claude or
# ~/.agent-bridge. The Contract-A swap()/mapping (owned by Sub-PR 2, built in
# parallel) is served from the helper's CI injection seam
# (BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE / _MAP_FIXTURE) so the decision matrix is
# deterministic with no live service and no dependency on the parallel client.
#
# Footgun #11: no heredoc-stdin / here-string piped into command substitution.
#
# Cases:
#   H1  DISABLED → helper returns defer_local immediately (byte-for-byte no-op)
#   H2  swap ok + unique mapping → swapped; the registry active token advances to
#       the lease-mapped local id; the return carries a rotate-shaped envelope
#       (status=rotated, old/new active id) downstream parsers read unchanged
#   H3  authoritative 409 (with reset) → suppress_cooldown, skipped:
#       all_tokens_limited envelope, soonest_reset passed through; NO local rotate
#   H4  409 with NO reset → suppress_cooldown, empty soonest (writer floor governs)
#   H5  409 + break-glass (BRIDGE_TOKEN_LEASE_BREAKGLASS_LOCAL_ROTATE=1) →
#       defer_local (operator override; caller falls back to local rotate)
#   H6  swap ok but mapping ambiguous/missing → defer_local (never guess a token)
#   H7  5xx / error / network → defer_local (service unreachable → local fallback)
#   H8  limited_until stamped on the rotating-AWAY token only, never a blanket copy
#   H9  the swapped decision leaks NO secret_material (nor token/access_token/
#       refresh_token/api_key) even when the Contract-A swap() response carries it
#       (patch Phase-5 security note — the secret stays in-process only)
#   W   the PRODUCTION path: `bridge-auth.sh claude-token lease-swap-or-defer`
#       (the WRAPPER, not bridge-auth.py directly — every rotator calls the shell
#       wrapper) dispatches the verb → swapped advances the registry; 409 →
#       suppress_cooldown (fleet-safe); unknown flag fails closed (rc=2)
#   R1  daemon route (bridge_daemon_lease_swap_route): ENABLED swap → decision
#       swapped + envelope populated; ENABLED 409 → suppress_cooldown; DISABLED /
#       degraded → defer_local + EMPTY envelope (caller runs its local rotate)
#   R2  picker-sweep route (_psw_default_rotate_claude_token): ENABLED → routes
#       through the lease verb (prints the swap envelope); DISABLED → byte-for-byte
#       the existing local `claude-token rotate`; the shared reactive-rotate
#       cooldown de-dup helpers are untouched
#   R3  cron-runner route (maybe_reactive_rotate via BRIDGE_CLAUDE_TOKEN_CMD seam):
#       ENABLED → routes through lease-swap-or-defer; DISABLED → local rotate
#   T   ci-select routes bridge-auth.py / bridge-daemon.sh / bridge-cron-runner.py
#       / scripts/picker-sweep.sh / bridge-daemon-helpers.py → this smoke

set -uo pipefail

SMOKE_NAME="token-updater-swap-or-defer"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

trap smoke_cleanup_temp_root EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
AUTH_SH="$REPO_ROOT/bridge-auth.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
PICKER_SH="$REPO_ROOT/scripts/picker-sweep.sh"
CRON_PY="$REPO_ROOT/bridge-cron-runner.py"
HELPERS_PY="$REPO_ROOT/bridge-daemon-helpers.py"
CI_SELECT="$REPO_ROOT/scripts/ci-select-smoke.sh"
for f in "$AUTH_PY" "$AUTH_SH" "$DAEMON_SH" "$PICKER_SH" "$CRON_PY" "$HELPERS_PY" "$CI_SELECT"; do
  [[ -f "$f" ]] || smoke_fail "missing source: $f"
done

export BRIDGE_RUNTIME_SECRETS_DIR="$BRIDGE_RUNTIME_ROOT/secrets"
mkdir -p "$BRIDGE_RUNTIME_SECRETS_DIR"
REGISTRY="$BRIDGE_RUNTIME_SECRETS_DIR/registry.json"
CFG="$BRIDGE_RUNTIME_CONFIG_FILE"

# Non-credential-shaped fixture token values (nothing resembling a real key).
FIXTURE_KEY="tu-fixture-secret-0123456789abcdef"

# bridge-auth.py <args...> with the isolated registry.
auth_py() { python3 "$AUTH_PY" --registry "$REGISTRY" "$@"; }

# Field extractor over a JSON object on stdin.
jfield() { python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }

seed_registry() {
  # Two operator-sourced tokens; tok-a active, tok-b the lease-mapped target.
  python3 -c '
import json,sys
reg={"version":1,"active_token_id":"tok-a","auto_rotate_enabled":True,"tokens":[
 {"id":"tok-a","token":"FAKE-LOCAL-TOKEN-A","enabled":True,"account_email":"a@example.com","account_email_source":"operator"},
 {"id":"tok-b","token":"FAKE-LOCAL-TOKEN-B","enabled":True,"account_email":"b@example.com","account_email_source":"operator"}]}
open(sys.argv[1],"w").write(json.dumps(reg))
' "$REGISTRY"
}

registry_active() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["active_token_id"])' "$REGISTRY"; }
registry_field() { python3 -c '
import json,sys
reg=json.load(open(sys.argv[1]))
for r in reg.get("tokens",[]):
    if r.get("id")==sys.argv[2]:
        print(r.get(sys.argv[3],"")); break
' "$REGISTRY" "$1" "$2"; }

enable_lease() {
  printf '%s' "$FIXTURE_KEY" | auth_py lease config \
    --api-url "https://lease.example.com" --server-id "srv-1" --enabled --api-key-stdin --json >/dev/null
}
disable_lease() { auth_py lease config --disabled --json >/dev/null; }

# swap-or-defer verb → prints the decision JSON.
swap_or_defer() { auth_py lease-swap-or-defer --caller "${1:-test}" "${@:2}" --json; }

# The PRODUCTION path: through the bridge-auth.sh WRAPPER (every rotator calls the
# shell wrapper, not bridge-auth.py directly). The wrapper resolves its registry
# via BRIDGE_CLAUDE_TOKEN_REGISTRY — point it at the isolated seeded registry.
swap_or_defer_wrapper() {
  BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
    bash "$AUTH_SH" claude-token lease-swap-or-defer --caller "${1:-test}" "${@:2}" --json
}

# ── H1 — DISABLED → defer_local immediately, no registry mutation ─────────
test_disabled_defer() {
  seed_registry
  disable_lease
  local out
  out="$(swap_or_defer usage_monitor)"
  smoke_assert_eq "defer_local" "$(printf '%s' "$out" | jfield action)" "H1 disabled → defer_local"
  smoke_assert_eq "lease_disabled" "$(printf '%s' "$out" | jfield reason)" "H1 reason=lease_disabled"
  smoke_assert_eq "tok-a" "$(registry_active)" "H1 registry active unchanged while disabled"
}

# ── H2 — swap ok + unique mapping → swapped + rotate-shaped envelope ──────
test_swapped_envelope() {
  seed_registry
  enable_lease
  local out
  out="$(BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"ok","service_token_id":"svc-9","account_email":"b@example.com","lease_expires_at":1234567890}' \
         BRIDGE_TOKEN_UPDATER_MAP_FIXTURE='{"status":"ok","local_token_id":"tok-b"}' \
         swap_or_defer usage_monitor --reason "usage:5h:99")"
  smoke_assert_eq "swapped" "$(printf '%s' "$out" | jfield action)" "H2 action=swapped"
  # Rotate-shaped envelope the daemon rotation-status-parse reads byte-identically.
  smoke_assert_eq "rotated" "$(printf '%s' "$out" | jfield status)" "H2 envelope status=rotated"
  smoke_assert_eq "tok-a" "$(printf '%s' "$out" | jfield old_active_token_id)" "H2 envelope old=tok-a"
  smoke_assert_eq "tok-b" "$(printf '%s' "$out" | jfield active_token_id)" "H2 envelope new=tok-b"
  smoke_assert_eq "b@example.com" "$(printf '%s' "$out" | jfield account_email)" "H2 decision carries account_email"
  smoke_assert_eq "svc-9" "$(printf '%s' "$out" | jfield service_token_id)" "H2 decision carries service_token_id"
  # The registry authority actually advanced to the lease-mapped local token.
  smoke_assert_eq "tok-b" "$(registry_active)" "H2 registry active advanced to tok-b (lease authority)"
}

# ── H10 (codex r2 envelope parity) — swapped --sync envelope carries sync.status ──
# The daemon rotation-status-parse reads payload["sync"]["status"]; the swapped
# path execs bridge-auth.py directly (no bash agent-fanout), so the verb itself
# must emit a `sync` object under --sync or the daemon audit row loses the
# sync_status column. Feed the real envelope through the SHIPPED
# rotation-status-parse and assert the 5th tab column is populated (not the `-`
# sentinel an empty field would print).
test_swapped_sync_status_parity() {
  seed_registry
  enable_lease
  local out sync_col
  out="$(BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"ok","service_token_id":"svc-9","account_email":"b@example.com"}' \
         BRIDGE_TOKEN_UPDATER_MAP_FIXTURE='{"status":"ok","local_token_id":"tok-b"}' \
         swap_or_defer usage_monitor --sync)"
  smoke_assert_eq "swapped" "$(printf '%s' "$out" | jfield action)" "H10 action=swapped (--sync)"
  # The shipped daemon parser: 6 tab-separated columns; 5th is sync_status.
  # The seeded registry has no global-auth-sync opt-in, so the in-Python operator
  # converge returns status=skipped — the point is the swapped envelope surfaces a
  # non-empty sync.status the parser reads (regression: it was the empty `-`).
  sync_col="$(python3 "$HELPERS_PY" rotation-status-parse "$out" | cut -f5)"
  smoke_assert_eq "skipped" "$sync_col" "H10 rotation-status-parse reads swapped sync_status (parity, not empty sentinel)"
}

# ── H3 — authoritative 409 with reset → suppress_cooldown ────────────────
test_conflict_suppress_with_reset() {
  seed_registry
  enable_lease
  local out
  out="$(BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"conflict","http":409,"soonest_reset":"2026-07-02T12:00:00+00:00"}' \
         swap_or_defer reactive_429)"
  smoke_assert_eq "suppress_cooldown" "$(printf '%s' "$out" | jfield action)" "H3 action=suppress_cooldown"
  smoke_assert_eq "skipped" "$(printf '%s' "$out" | jfield status)" "H3 envelope status=skipped"
  smoke_assert_eq "all_tokens_limited" "$(printf '%s' "$out" | jfield reason)" "H3 reason=all_tokens_limited"
  smoke_assert_eq "2026-07-02T12:00:00+00:00" "$(printf '%s' "$out" | jfield soonest_reset)" "H3 soonest_reset passed through"
  smoke_assert_eq "tok-a" "$(registry_active)" "H3 NO local rotate on 409 (active unchanged)"
}

# ── H4 — 409 with NO reset → suppress_cooldown, empty soonest ────────────
test_conflict_suppress_no_reset() {
  seed_registry
  enable_lease
  local out
  out="$(BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"conflict","http":409}' swap_or_defer reactive_429)"
  smoke_assert_eq "suppress_cooldown" "$(printf '%s' "$out" | jfield action)" "H4 action=suppress_cooldown"
  smoke_assert_eq "" "$(printf '%s' "$out" | jfield soonest_reset)" "H4 empty soonest (writer floor governs)"
  smoke_assert_eq "tok-a" "$(registry_active)" "H4 NO local rotate (active unchanged)"
}

# ── H5 — 409 + break-glass → defer_local ─────────────────────────────────
test_breakglass_defers() {
  seed_registry
  enable_lease
  local out
  out="$(BRIDGE_TOKEN_LEASE_BREAKGLASS_LOCAL_ROTATE=1 \
         BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"conflict","http":409}' \
         swap_or_defer reactive_429)"
  smoke_assert_eq "defer_local" "$(printf '%s' "$out" | jfield action)" "H5 break-glass → defer_local (not suppress)"
  smoke_assert_eq "breakglass_local_rotate" "$(printf '%s' "$out" | jfield reason)" "H5 reason=breakglass_local_rotate"
}

# ── H6 — swap ok but mapping ambiguous → defer_local (never guess) ───────
test_map_ambiguous_defers() {
  seed_registry
  enable_lease
  local out
  out="$(BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"ok","account_email":"b@example.com"}' \
         BRIDGE_TOKEN_UPDATER_MAP_FIXTURE='{"status":"error","reason":"map_ambiguous"}' \
         swap_or_defer usage_monitor)"
  smoke_assert_eq "defer_local" "$(printf '%s' "$out" | jfield action)" "H6 map ambiguous → defer_local"
  smoke_assert_eq "map_ambiguous" "$(printf '%s' "$out" | jfield reason)" "H6 reason=map_ambiguous (no double-prefix)"
  smoke_assert_eq "tok-a" "$(registry_active)" "H6 NO rotate on ambiguous mapping"
}

# ── H7 — 5xx / error → defer_local (service unreachable) ─────────────────
test_5xx_defers() {
  seed_registry
  enable_lease
  local out
  out="$(BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"error","http":503}' swap_or_defer active_dead)"
  smoke_assert_eq "defer_local" "$(printf '%s' "$out" | jfield action)" "H7 5xx → defer_local"
  smoke_assert_eq "tok-a" "$(registry_active)" "H7 NO rotate on 5xx"
}

# ── H8 — limited_until stamped on the rotating-AWAY token ONLY ────────────
test_limited_until_old_only() {
  seed_registry
  enable_lease
  local reset="2026-07-02T18:00:00+00:00"
  BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"ok","account_email":"b@example.com"}' \
  BRIDGE_TOKEN_UPDATER_MAP_FIXTURE='{"status":"ok","local_token_id":"tok-b"}' \
    swap_or_defer usage_monitor --reason "usage:5h:99" --limited-until "$reset" >/dev/null
  smoke_assert_eq "tok-b" "$(registry_active)" "H8 swap advanced to tok-b"
  # The OLD token (tok-a) carries limited_until; the NEW token (tok-b) does NOT.
  smoke_assert_eq "$reset" "$(registry_field tok-a limited_until)" "H8 rotating-away tok-a stamped limited_until"
  smoke_assert_eq "" "$(registry_field tok-b limited_until)" "H8 selected tok-b NOT stamped (no blanket copy)"
}

# ── H9 (patch Phase-5 security) — swapped decision leaks NO secret_material ───
# The Contract-A swap() may return `secret_material` (the new token's actual
# secret) on its JSON stdout. The swapped decision every rotator logs/audits MUST
# NOT carry it (nor any token/access_token/refresh_token/api_key field). Feed a
# swap fixture that CARRIES a secret and assert none of it appears in the output.
test_swapped_no_secret_leak() {
  seed_registry
  enable_lease
  local out
  out="$(BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"ok","account_email":"b@example.com","service_token_id":"svc-9","secret_material":"SUPER-SECRET-NEW-TOKEN-VALUE","access_token":"AT-SECRET","refresh_token":"RT-SECRET"}' \
         BRIDGE_TOKEN_UPDATER_MAP_FIXTURE='{"status":"ok","local_token_id":"tok-b"}' \
         swap_or_defer usage_monitor --reason "usage:5h:99")"
  smoke_assert_eq "swapped" "$(printf '%s' "$out" | jfield action)" "H9 swap succeeded (secret carried in fixture)"
  smoke_assert_not_contains "$out" "SUPER-SECRET-NEW-TOKEN-VALUE" "H9 decision does NOT leak secret_material"
  smoke_assert_not_contains "$out" "secret_material" "H9 decision has no secret_material key"
  smoke_assert_not_contains "$out" "AT-SECRET" "H9 decision does NOT leak access_token"
  smoke_assert_not_contains "$out" "RT-SECRET" "H9 decision does NOT leak refresh_token"
}

# ── W — the PRODUCTION path: the bridge-auth.sh WRAPPER dispatches the verb ───
# Every rotator calls `bash bridge-auth.sh claude-token lease-swap-or-defer …`,
# NOT bridge-auth.py directly. If the wrapper's claude-token case lacks the arm,
# the verb falls through to usage/exit 1 → callers parse empty → defer_local, and
# the authoritative-409 suppress path is DEAD in production. This pins the arm.
test_wrapper_dispatches_swapped() {
  seed_registry
  enable_lease
  local out
  out="$(BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"ok","account_email":"b@example.com"}' \
         BRIDGE_TOKEN_UPDATER_MAP_FIXTURE='{"status":"ok","local_token_id":"tok-b"}' \
         swap_or_defer_wrapper usage_monitor --reason "usage:5h:99")"
  smoke_assert_eq "swapped" "$(printf '%s' "$out" | jfield action)" "W wrapper dispatches the verb (swapped)"
  smoke_assert_eq "tok-b" "$(registry_active)" "W wrapper swap advanced the registry (verb actually ran)"
}

test_wrapper_dispatches_suppress() {
  seed_registry
  enable_lease
  local out
  # THE codex-flagged fleet-safety path THROUGH THE WRAPPER: 409 → suppress, not
  # a fallback-to-local-rotate on empty wrapper output.
  out="$(BRIDGE_TOKEN_UPDATER_SWAP_FIXTURE='{"status":"conflict","http":409,"soonest_reset":"2026-07-02T12:00:00+00:00"}' \
         swap_or_defer_wrapper reactive_429)"
  smoke_assert_eq "suppress_cooldown" "$(printf '%s' "$out" | jfield action)" "W wrapper 409 → suppress_cooldown (fleet-safe, not defer)"
  smoke_assert_eq "tok-a" "$(registry_active)" "W wrapper 409 did NOT local-rotate"
}

test_wrapper_unknown_flag_fails_closed() {
  local rc
  set +e
  BRIDGE_CLAUDE_TOKEN_REGISTRY="$REGISTRY" \
    bash "$AUTH_SH" claude-token lease-swap-or-defer --bogus-flag >/dev/null 2>&1
  rc=$?
  set -e 2>/dev/null || true
  [[ "$rc" -eq 2 ]] || smoke_fail "W wrapper unknown flag rc=$rc (must fail closed rc=2)"
}

# ---------------------------------------------------------------------------
# R1 — the daemon route (bridge_daemon_lease_swap_route), extracted + eval'd
# from the REAL bridge-daemon.sh so a revert of the routing fails the extract.
# ---------------------------------------------------------------------------
DAEMON_ROUTE_SETUP=0
setup_daemon_route() {
  (( DAEMON_ROUTE_SETUP == 1 )) && return 0
  local body
  body="$(awk '/^bridge_daemon_lease_swap_route\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$DAEMON_SH")"
  [[ -n "$body" ]] || smoke_fail "R1 could not extract bridge_daemon_lease_swap_route from bridge-daemon.sh"
  eval "$body"
  command -v bridge_daemon_lease_swap_route >/dev/null 2>&1 \
    || smoke_fail "R1 bridge_daemon_lease_swap_route not defined after eval"
  export SCRIPT_DIR_REAL="$REPO_ROOT"
  DAEMON_ROUTE_SETUP=1
}

# Stub bridge_with_timeout: discriminate the lease --check gate, the
# lease-swap-or-defer verb, and the lease-decision-parse call by argv. Driven by
# MOCK_LEASE_ENABLED (check rc) + MOCK_DECISION_JSON (verb output).
# shellcheck disable=SC2329
bridge_with_timeout() {
  shift 2 # drop <secs> <label>
  local args="$*"
  case "$args" in
    *"lease status --check"*)
      [[ "${MOCK_LEASE_ENABLED:-0}" == "1" ]] && return 0 || return 1
      ;;
    *"lease-swap-or-defer"*)
      printf '%s\n' "${MOCK_DECISION_JSON:-}"
      ;;
    *"lease-decision-parse"*)
      # Delegate to the REAL shipped parser on the ACTUAL decision_json the route
      # passed (the last positional after the helper argv: python3 <helpers>
      # lease-decision-parse <decision_json>).
      python3 "$HELPERS_PY" lease-decision-parse "$4"
      ;;
    *) : ;;
  esac
}

run_daemon_route() {
  setup_daemon_route
  # The extracted fn references $SCRIPT_DIR + $BRIDGE_BASH_BIN; the stub ignores
  # them (argv-discriminated), but they must be set for the (unused) real path.
  SCRIPT_DIR="$REPO_ROOT" BRIDGE_BASH_BIN="bash" \
    bridge_daemon_lease_swap_route "$@"
}

test_daemon_route_swapped() {
  export MOCK_LEASE_ENABLED=1
  export MOCK_DECISION_JSON='{"action":"swapped","status":"rotated","old_active_token_id":"tok-a","active_token_id":"tok-b"}'
  BRIDGE_LEASE_ROUTE_DECISION=""; BRIDGE_LEASE_ROUTE_ENVELOPE=""
  run_daemon_route usage_monitor --reason "usage:5h:99"
  smoke_assert_eq "swapped" "$BRIDGE_LEASE_ROUTE_DECISION" "R1a daemon route ENABLED swap → decision=swapped"
  smoke_assert_contains "$BRIDGE_LEASE_ROUTE_ENVELOPE" "rotated" "R1a daemon route envelope carries the rotate shape"
}

test_daemon_route_suppress() {
  export MOCK_LEASE_ENABLED=1
  export MOCK_DECISION_JSON='{"action":"suppress_cooldown","status":"skipped","reason":"all_tokens_limited","soonest_reset":"2026-07-02T12:00:00+00:00"}'
  BRIDGE_LEASE_ROUTE_DECISION=""; BRIDGE_LEASE_ROUTE_ENVELOPE=""
  run_daemon_route reactive_429 --reason "reactive-429:worker-a"
  smoke_assert_eq "suppress_cooldown" "$BRIDGE_LEASE_ROUTE_DECISION" "R1b daemon route ENABLED 409 → suppress_cooldown"
  smoke_assert_contains "$BRIDGE_LEASE_ROUTE_ENVELOPE" "all_tokens_limited" "R1b suppress envelope feeds the pool-exhausted writer"
}

test_daemon_route_defer_disabled() {
  export MOCK_LEASE_ENABLED=0   # lease --check fails → early defer, no verb call
  export MOCK_DECISION_JSON='{"action":"swapped"}'  # would-be swap, but gate is OFF
  BRIDGE_LEASE_ROUTE_DECISION="sentinel"; BRIDGE_LEASE_ROUTE_ENVELOPE="sentinel"
  run_daemon_route usage_monitor --reason "usage:5h:99"
  smoke_assert_eq "defer_local" "$BRIDGE_LEASE_ROUTE_DECISION" "R1c daemon route DISABLED → defer_local (caller runs local rotate)"
  smoke_assert_eq "" "$BRIDGE_LEASE_ROUTE_ENVELOPE" "R1c daemon route DISABLED → EMPTY envelope"
}

test_daemon_route_defer_on_defer_decision() {
  export MOCK_LEASE_ENABLED=1
  export MOCK_DECISION_JSON='{"action":"defer_local","reason":"map_ambiguous"}'
  BRIDGE_LEASE_ROUTE_DECISION="sentinel"; BRIDGE_LEASE_ROUTE_ENVELOPE="sentinel"
  run_daemon_route usage_monitor --reason "usage:5h:99"
  smoke_assert_eq "defer_local" "$BRIDGE_LEASE_ROUTE_DECISION" "R1d ENABLED but decision=defer_local → defer_local"
  smoke_assert_eq "" "$BRIDGE_LEASE_ROUTE_ENVELOPE" "R1d defer_local → EMPTY envelope"
}

# ---------------------------------------------------------------------------
# R2 — the picker-sweep route (_psw_default_rotate_claude_token), extracted +
# eval'd from the REAL scripts/picker-sweep.sh. The picker calls `bash
# "$BRIDGE_HOME/bridge-auth.sh" claude-token <verb>` and `python3
# "$BRIDGE_HOME/bridge-daemon-helpers.py" lease-decision-parse`. We point
# $BRIDGE_HOME at a picker-stub dir whose bridge-auth.sh is a RECORDER stub (so we
# see which verb the picker dispatched) and whose bridge-daemon-helpers.py is a
# symlink to the REAL shipped parser (so routing consumes the shipped decoder).
# We do NOT shadow `bash` — that would hijack the W wrapper tests' real
# bridge-auth.sh call.
# ---------------------------------------------------------------------------
PICKER_ROUTE_SETUP=0
PICKER_STUB_HOME="$SMOKE_TMP_ROOT/picker-home"
PICKER_AUTH_LEDGER_FILE="$SMOKE_TMP_ROOT/picker-verb.ledger"
setup_picker_route() {
  (( PICKER_ROUTE_SETUP == 1 )) && return 0
  local fns body
  # Pull the three picker helpers the route uses, in file order.
  for fns in _psw_token_updater_lease_enabled _psw_lease_decision_action _psw_default_rotate_claude_token; do
    body="$(awk -v fn="$fns" '$0 ~ "^"fn"\\(\\) \\{"{p=1} p{print} p&&/^\}/{exit}' "$PICKER_SH")"
    [[ -n "$body" ]] || smoke_fail "R2 could not extract $fns from picker-sweep.sh"
    eval "$body"
  done
  command -v _psw_default_rotate_claude_token >/dev/null 2>&1 \
    || smoke_fail "R2 _psw_default_rotate_claude_token not defined after eval"
  # Build the picker-stub BRIDGE_HOME: a recorder bridge-auth.sh + a symlink to
  # the REAL bridge-daemon-helpers.py so lease-decision-parse runs the shipped code.
  mkdir -p "$PICKER_STUB_HOME"
  ln -sf "$HELPERS_PY" "$PICKER_STUB_HOME/bridge-daemon-helpers.py"
  cat >"$PICKER_STUB_HOME/bridge-auth.sh" <<'STUB'
#!/usr/bin/env bash
# Recorder stub for the picker route: $2 is the claude-token verb; $3.. its args.
# (invoked as `bash <this> claude-token <verb> ...`).
verb="${2:-}"
case "$verb" in
  lease)
    # `lease status --check`: rc from MOCK_LEASE_ENABLED.
    [[ "${MOCK_LEASE_ENABLED:-0}" == "1" ]] && exit 0 || exit 1
    ;;
  lease-swap-or-defer)
    printf 'lease-swap-or-defer\n' >>"$PICKER_AUTH_LEDGER_FILE"
    printf '%s\n' "${MOCK_DECISION_JSON:-}"
    ;;
  rotate)
    printf 'rotate\n' >>"$PICKER_AUTH_LEDGER_FILE"
    printf '%s\n' '{"status":"rotated","old_active_token_id":"tok-a","active_token_id":"tok-b"}'
    ;;
  *) printf '%s\n' '{}' ;;
esac
exit 0
STUB
  chmod +x "$PICKER_STUB_HOME/bridge-auth.sh"
  export PICKER_AUTH_LEDGER_FILE
  PICKER_ROUTE_SETUP=1
}

# Run the picker route against the picker-stub BRIDGE_HOME (scoped so the rest of
# the smoke keeps the isolated real home). The picker's rotate fn runs inside a
# command-substitution subshell, so the verb ledger is FILE-backed (a shell-var
# increment there would not propagate to the parent).
run_picker_rotate() { BRIDGE_HOME="$PICKER_STUB_HOME" _psw_default_rotate_claude_token "$@"; }

test_picker_route_enabled_routes() {
  setup_picker_route
  export MOCK_LEASE_ENABLED=1
  export MOCK_DECISION_JSON='{"action":"swapped","status":"rotated","old_active_token_id":"tok-a","active_token_id":"tok-b"}'
  : >"$PICKER_AUTH_LEDGER_FILE"
  local out ledger
  out="$(run_picker_rotate worker-a)"
  ledger="$(cat "$PICKER_AUTH_LEDGER_FILE")"
  smoke_assert_contains "$ledger" "lease-swap-or-defer" "R2a picker ENABLED → routes through lease-swap-or-defer"
  smoke_assert_contains "$out" "rotated" "R2a picker emits the swap envelope"
  # A swapped decision must NOT also fall through to a local rotate.
  case "$ledger" in
    *rotate*) smoke_fail "R2a picker ENABLED swap also ran a local rotate (double-rotate): '$ledger'" ;;
  esac
}

test_picker_route_disabled_local() {
  setup_picker_route
  export MOCK_LEASE_ENABLED=0
  : >"$PICKER_AUTH_LEDGER_FILE"
  local out ledger
  out="$(run_picker_rotate worker-a)"
  ledger="$(cat "$PICKER_AUTH_LEDGER_FILE")"
  # DISABLED → the lease gate is a no-op and the EXISTING local rotate runs.
  smoke_assert_contains "$ledger" "rotate" "R2b picker DISABLED → byte-for-byte local rotate"
  case "$ledger" in
    *lease-swap-or-defer*) smoke_fail "R2b picker DISABLED still called the lease verb: '$ledger'" ;;
  esac
  smoke_assert_contains "$out" "rotated" "R2b picker local rotate output preserved"
}

test_picker_cooldown_dedup_preserved() {
  # The picker's shared reactive-rotate cooldown de-dup lives in the sweep loop
  # (bridge_reactive_rotate_cooldown_active / _cooldown_note), NOT in the rotate
  # function. Assert the source still consults + stamps them so the routing edit
  # did not disturb the de-dup.
  smoke_assert_contains "$(cat "$PICKER_SH")" "bridge_reactive_rotate_cooldown_active" "R2c picker still consults the shared cooldown"
  smoke_assert_contains "$(cat "$PICKER_SH")" "bridge_reactive_rotate_cooldown_note" "R2c picker still stamps the shared cooldown"
}

# ---------------------------------------------------------------------------
# R3 — the cron-runner route. maybe_reactive_rotate resolves the token CLI via
# BRIDGE_CLAUDE_TOKEN_CMD (a documented test seam). We point it at a recorder
# stub and assert the verb it dispatched: lease-swap-or-defer when ENABLED,
# rotate when DISABLED.
# ---------------------------------------------------------------------------
CRON_STUB="$SMOKE_TMP_ROOT/cron-token-stub.sh"
CRON_LEDGER="$SMOKE_TMP_ROOT/cron-verb.ledger"
make_cron_stub() {
  cat >"$CRON_STUB" <<'STUB'
#!/usr/bin/env bash
# Recorder stub for BRIDGE_CLAUDE_TOKEN_CMD. Args after the seam prefix are the
# claude-token subcommand + flags. Record the verb and emit a plausible JSON.
verb="${1:-}"
printf '%s\n' "$verb" >>"$CRON_LEDGER"
case "$verb" in
  lease)
    # `lease status --check`: rc from MOCK_LEASE_ENABLED.
    [[ "${MOCK_LEASE_ENABLED:-0}" == "1" ]] && exit 0 || exit 1
    ;;
  lease-swap-or-defer)
    printf '%s\n' "${MOCK_DECISION_JSON:-}"
    ;;
  classify-output)
    # The runner classifies the captured run BEFORE deciding to rotate; force a
    # quota-limited verdict so the reactive-rotate path engages.
    printf '%s\n' '{"status":"quota_limited","api_error_status":"429","reset_at":"2026-07-02T12:00:00+00:00","returncode":1,"json_ok":false}'
    ;;
  rotate)
    printf '%s\n' '{"status":"rotated","old_active_token_id":"tok-a","active_token_id":"tok-b"}'
    ;;
  list)
    printf '%s\n' '{"active_token_id":"tok-a","tokens":[{"id":"tok-a","enabled":true},{"id":"tok-b","enabled":true}]}'
    ;;
  mark-quota) printf '%s\n' '{"status":"ok"}' ;;
  *) printf '%s\n' '{}' ;;
esac
exit 0
STUB
  chmod +x "$CRON_STUB"
}

# Drive maybe_reactive_rotate directly through a tiny python harness that imports
# the runner module and calls it with a quota-limited captured run.
cron_reactive_probe() {
  # $1 = MOCK_LEASE_ENABLED (0/1); prints the runner's rotate verb ledger.
  : >"$CRON_LEDGER"
  MOCK_LEASE_ENABLED="$1" \
  MOCK_DECISION_JSON="${MOCK_DECISION_JSON:-}" \
  CRON_LEDGER="$CRON_LEDGER" \
  BRIDGE_CLAUDE_TOKEN_CMD="$CRON_STUB" \
  python3 "$SCRIPT_DIR/token-updater-swap-or-defer-cron-probe.py" "$CRON_PY"
}

test_cron_route_enabled_routes() {
  make_cron_stub
  export MOCK_DECISION_JSON='{"action":"swapped","status":"rotated","old_active_token_id":"tok-a","active_token_id":"tok-b"}'
  cron_reactive_probe 1 >/dev/null 2>&1 || true
  smoke_assert_contains "$(cat "$CRON_LEDGER")" "lease-swap-or-defer" "R3a cron ENABLED → routes through lease-swap-or-defer"
  # ENABLED swap must NOT also fire the local rotate verb.
  case "$(cat "$CRON_LEDGER")" in
    *$'\n'rotate*|rotate$'\n'*|*$'\n'rotate$'\n'*) smoke_fail "R3a cron ENABLED swap also ran a local rotate: $(tr '\n' ' ' <"$CRON_LEDGER")" ;;
  esac
}

test_cron_route_disabled_local() {
  make_cron_stub
  cron_reactive_probe 0 >/dev/null 2>&1 || true
  smoke_assert_contains "$(cat "$CRON_LEDGER")" "rotate" "R3b cron DISABLED → local rotate"
  case "$(cat "$CRON_LEDGER")" in
    *lease-swap-or-defer*) smoke_fail "R3b cron DISABLED still called the lease verb: $(tr '\n' ' ' <"$CRON_LEDGER")" ;;
  esac
}

# ── T — ci-select routing ────────────────────────────────────────────────
test_ci_select_routing() {
  local f out
  for f in bridge-auth.py bridge-daemon.sh bridge-cron-runner.py scripts/picker-sweep.sh bridge-daemon-helpers.py; do
    out="$(bash "$CI_SELECT" --changed-file "$f" 2>/dev/null || true)"
    smoke_assert_contains "$out" "$SMOKE_NAME" "T ci-select routes $f → $SMOKE_NAME"
  done
}

smoke_run "H1 DISABLED → defer_local immediately (byte-for-byte no-op)"            test_disabled_defer
smoke_run "H2 swap ok + unique map → swapped + rotate-shaped envelope + advance"  test_swapped_envelope
smoke_run "H3 authoritative 409 (reset) → suppress_cooldown, no local rotate"     test_conflict_suppress_with_reset
smoke_run "H4 409 no reset → suppress_cooldown, empty soonest (writer floor)"     test_conflict_suppress_no_reset
smoke_run "H5 409 + break-glass → defer_local"                                    test_breakglass_defers
smoke_run "H6 swap ok + map ambiguous → defer_local (never guess)"               test_map_ambiguous_defers
smoke_run "H7 5xx/error → defer_local (service unreachable)"                      test_5xx_defers
smoke_run "H8 limited_until stamped on rotating-away token ONLY"                  test_limited_until_old_only
smoke_run "H9 swapped decision leaks NO secret_material (patch Phase-5)"          test_swapped_no_secret_leak
smoke_run "H10 swapped --sync envelope → rotation-status-parse reads sync_status" test_swapped_sync_status_parity
smoke_run "W  wrapper (bridge-auth.sh) dispatches the verb → swapped + advance"   test_wrapper_dispatches_swapped
smoke_run "W  wrapper 409 → suppress_cooldown (fleet-safe, PRODUCTION path)"      test_wrapper_dispatches_suppress
smoke_run "W  wrapper unknown flag fails closed (rc=2)"                           test_wrapper_unknown_flag_fails_closed
smoke_run "R1a daemon route ENABLED swap → decision=swapped + envelope"           test_daemon_route_swapped
smoke_run "R1b daemon route ENABLED 409 → suppress_cooldown envelope"            test_daemon_route_suppress
smoke_run "R1c daemon route DISABLED → defer_local + EMPTY envelope"             test_daemon_route_defer_disabled
smoke_run "R1d daemon route ENABLED+defer decision → defer_local + EMPTY"        test_daemon_route_defer_on_defer_decision
smoke_run "R2a picker route ENABLED → routes through lease verb (no double)"     test_picker_route_enabled_routes
smoke_run "R2b picker route DISABLED → byte-for-byte local rotate"               test_picker_route_disabled_local
smoke_run "R2c picker shared reactive-rotate cooldown de-dup preserved"          test_picker_cooldown_dedup_preserved
smoke_run "R3a cron route ENABLED → routes through lease verb"                    test_cron_route_enabled_routes
smoke_run "R3b cron route DISABLED → local rotate"                               test_cron_route_disabled_local
smoke_run "T  ci-select routes all 5 changed sources → this smoke"               test_ci_select_routing

smoke_log "all checks passed"
