#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1991-agentic-resolver.sh — Issue #1991 AGENTIC RESOLVER (v0.16.16).
#
# The patch-owned, canary-gated, default-deny blocked-prompt resolver that sits
# ON TOP of the #1992 safety floor. This smoke proves the four load-bearing
# claims of the design, entirely in an isolated BRIDGE_HOME, NEVER sending a key
# to a real session (every send goes through a STUB that records to a log):
#
#   1. SINGLE-SENDER: with the canary enabled for an agent, EVERY legacy key
#      sender (controller watcher, agent backstop, generic advance-blocker,
#      picker auto-resolve, picker-sweep cron + upgrade one-shot) is no-send /
#      report-only for that agent. The ONLY sender is the resolver helper.
#   2. DEFAULT-DENY POLICY: devchannels/trust/summary allow; billing/usage/
#      permission/overwrite/feedback/context/unknown/low-conf DENY — and a DENY
#      sends ZERO keys from the resolver AND from picker-autoresolve/picker-sweep.
#   3. PER-KEY ATTEMPT LATCH = the one-sender proof: a duplicate task/tick never
#      sends a second key for the same key.
#   4. PROMPT-INJECTION INVARIANT: pane text only feeds the deterministic
#      classifier/hashes; it never becomes a key token, shell, or instruction.
#      The daemon never sends. The #1992 floor (90s) is unchanged + is the
#      deterministic backstop; the resolver window (45s) is shorter.
#
# Plus the 2 MUTATION GUARDS: removing the old-sender gates makes a key reappear
# under canary (smoke fails); removing the per-key latch allows duplicate sends.
#
# Footgun #11: no heredoc-stdin into a subprocess; fixtures use printf/Write.

set -euo pipefail

if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1991-agentic-resolver] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1991-agentic-resolver"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_setup_bridge_home "1991-agentic-resolver"

REPO_ROOT="$SMOKE_REPO_ROOT"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
RESOLVER_SH="$REPO_ROOT/bridge-resolver.sh"
RESOLVER_LIB="$REPO_ROOT/lib/bridge-prompt-resolver.sh"
POLICY_PY="$REPO_ROOT/bridge-resolver-policy.py"
POLICY_JSON="$REPO_ROOT/runtime-templates/shared/prompt-resolver-actions.json"
STALL_PY="$REPO_ROOT/bridge-stall.py"
TMUX_SH="$REPO_ROOT/lib/bridge-tmux.sh"
START_SH="$REPO_ROOT/bridge-start.sh"
RUN_SH="$REPO_ROOT/bridge-run.sh"
PICKER_SH="$REPO_ROOT/lib/bridge-picker.sh"
SWEEP_SH="$REPO_ROOT/scripts/picker-sweep.sh"

smoke_assert_file_exists "$DAEMON_SH" "bridge-daemon.sh present"
smoke_assert_file_exists "$RESOLVER_SH" "bridge-resolver.sh present"
smoke_assert_file_exists "$RESOLVER_LIB" "lib/bridge-prompt-resolver.sh present"
smoke_assert_file_exists "$POLICY_PY" "bridge-resolver-policy.py present"
smoke_assert_file_exists "$POLICY_JSON" "prompt-resolver-actions.json present"
smoke_require_cmd python3

# ===========================================================================
# Part 0: policy schema + decision (pure python — no daemon/tmux). This is the
# DEFAULT-DENY contract: dangerous kinds never auto-action.
# ===========================================================================
# shellcheck disable=SC2329
policy_decide() {
  python3 "$POLICY_PY" decide --shipped "$POLICY_JSON" --prompt-kind "$1" --confidence "${2:-high}"
}
# shellcheck disable=SC2329
policy_verdict() { printf '%s' "$1" | cut -f1; }
# shellcheck disable=SC2329
policy_keys() { printf '%s' "$1" | cut -f2-; }

# shellcheck disable=SC2329
test_p0_schema_valid() {
  python3 "$POLICY_PY" validate --shipped "$POLICY_JSON" >/dev/null \
    || smoke_fail "shipped policy fails schema validation"
  python3 -c "import json,sys; json.load(open('$POLICY_JSON'))" \
    || smoke_fail "shipped policy is not valid JSON"
  smoke_log "shipped policy schema valid"
}

# shellcheck disable=SC2329
test_p0_allow_safe_kinds() {
  local out
  out="$(policy_decide devchannels high)"
  smoke_assert_eq "allow" "$(policy_verdict "$out")" "devchannels/high ALLOW"
  smoke_assert_eq "select_first confirm" "$(policy_keys "$out")" "devchannels keys = select_first confirm"
  smoke_assert_eq "allow" "$(policy_verdict "$(policy_decide trust high)")" "trust/high ALLOW"
  smoke_assert_eq "allow" "$(policy_verdict "$(policy_decide summary high)")" "summary/high ALLOW"
}

# shellcheck disable=SC2329
test_p0_deny_dangerous_kinds() {
  local k
  for k in billing usage plan-upgrade permission overwrite_confirm feedback context_pressure unknown_interactive; do
    smoke_assert_eq "deny" "$(policy_verdict "$(policy_decide "$k" high)")" "$k DENY (default-deny dangerous kind)"
  done
  smoke_assert_eq "deny" "$(policy_verdict "$(policy_decide totally_unknown_kind high)")" "unknown kind DENY (default-deny)"
  smoke_assert_eq "deny" "$(policy_verdict "$(policy_decide devchannels low)")" "low-confidence devchannels DENY (confidence gate)"
}

# shellcheck disable=SC2329
test_p0_local_demote_only() {
  local tmp; tmp="$SMOKE_TMP_ROOT/local-policy"
  mkdir -p "$tmp"
  printf '%s\n' '{"version":1,"actions":[{"prompt_kind":"devchannels","enabled":false,"action":"deny","keys":[]}]}' >"$tmp/demote.json"
  smoke_assert_eq "deny" "$(python3 "$POLICY_PY" decide --shipped "$POLICY_JSON" --local "$tmp/demote.json" --prompt-kind devchannels --confidence high | cut -f1)" \
    "local override can DEMOTE a shipped-allowed kind to deny"
  printf '%s\n' '{"version":1,"actions":[{"prompt_kind":"billing","enabled":true,"required_confidence":"high","action":"confirm","keys":["confirm"]}]}' >"$tmp/promote.json"
  smoke_assert_eq "deny" "$(python3 "$POLICY_PY" decide --shipped "$POLICY_JSON" --local "$tmp/promote.json" --prompt-kind billing --confidence high | cut -f1)" \
    "local override can NOT PROMOTE a denied kind (no local promote)"
}

# shellcheck disable=SC2329
test_p0_closed_token_vocab() {
  local tmp; tmp="$SMOKE_TMP_ROOT/badtoken"
  mkdir -p "$tmp"
  printf '%s\n' '{"version":1,"actions":[{"prompt_kind":"devchannels","enabled":true,"required_confidence":"high","action":"x","keys":["rm -rf","confirm"]}]}' >"$tmp/bad.json"
  smoke_assert_eq "deny" "$(python3 "$POLICY_PY" decide --shipped "$tmp/bad.json" --prompt-kind devchannels --confidence high | cut -f1)" \
    "out-of-vocabulary key token poisons the row → deny"
  python3 "$POLICY_PY" validate --shipped "$tmp/bad.json" >/dev/null 2>&1 \
    && smoke_fail "poisoned-token policy must FAIL schema validation" \
    || smoke_log "poisoned-token policy correctly rejected by validate"
}

# ===========================================================================
# Part 1: the resolver control-plane lib (canary gate, latch, send-block guard).
# Source the lib standalone (it depends only on bridge_bool_is_true, which we
# define locally, and bridge_agent_session, which we stub).
# ===========================================================================
# shellcheck disable=SC2329
bridge_bool_is_true() {
  local v="${1:-}"; v="${v,,}"
  case "$v" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}
# shellcheck disable=SC2329
bridge_agent_session() { printf '%s' "${STUB_AGENT_SESSION[$1]:-}"; }
declare -A STUB_AGENT_SESSION=()
# shellcheck source=lib/bridge-prompt-resolver.sh
source "$RESOLVER_LIB"

# shellcheck disable=SC2329
test_01_canary_gate_default_off() {
  unset BRIDGE_PROMPT_RESOLVER_ENABLED BRIDGE_PROMPT_RESOLVER_AGENTS
  bridge_prompt_resolver_enabled && smoke_fail "resolver must be DEFAULT OFF" || true
  bridge_prompt_resolver_owns_agent worker-a && smoke_fail "no agent owned when disabled" || true
  export BRIDGE_PROMPT_RESOLVER_ENABLED=1
  export BRIDGE_PROMPT_RESOLVER_AGENTS="worker-a,worker-b"
  bridge_prompt_resolver_owns_agent worker-a || smoke_fail "worker-a should be owned (csv member)"
  bridge_prompt_resolver_owns_agent worker-c && smoke_fail "worker-c not in csv → not owned" || true
  export BRIDGE_PROMPT_RESOLVER_AGENTS="all"
  bridge_prompt_resolver_owns_agent any-agent || smoke_fail "all → every agent owned"
  unset BRIDGE_PROMPT_RESOLVER_ENABLED BRIDGE_PROMPT_RESOLVER_AGENTS
}

# shellcheck disable=SC2329
test_02_send_block_guard() {
  export BRIDGE_STATE_DIR="$SMOKE_TMP_ROOT/p1-state"; mkdir -p "$BRIDGE_STATE_DIR"
  STUB_AGENT_SESSION=([worker-a]=worker-a)
  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || declare -ga BRIDGE_AGENT_IDS=(worker-a)
  export BRIDGE_PROMPT_RESOLVER_ENABLED=1 BRIDGE_PROMPT_RESOLVER_AGENTS="worker-a"
  # A legacy sender (no send-authorization) must be BLOCKED for a resolver-owned session.
  unset BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED
  bridge_prompt_resolver_should_block_send worker-a || smoke_fail "legacy send must be BLOCKED for resolver-owned session"
  # The authorized resolver helper (latch held) is allowed.
  export BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED=1
  bridge_prompt_resolver_should_block_send worker-a && smoke_fail "authorized resolver send must be ALLOWED" || true
  # Dry-run blocks even the authorized sender.
  export BRIDGE_PROMPT_RESOLVER_DRY_RUN=1
  bridge_prompt_resolver_should_block_send worker-a || smoke_fail "dry-run must BLOCK even authorized send"
  unset BRIDGE_PROMPT_RESOLVER_DRY_RUN BRIDGE_PROMPT_RESOLVER_SEND_AUTHORIZED
  # A non-canary agent is never blocked.
  bridge_prompt_resolver_should_block_send other-agent && smoke_fail "non-canary agent must not be blocked" || true
  unset BRIDGE_PROMPT_RESOLVER_ENABLED BRIDGE_PROMPT_RESOLVER_AGENTS
}

# shellcheck disable=SC2329
test_03_per_key_latch_one_send() {
  export BRIDGE_STATE_DIR="$SMOKE_TMP_ROOT/p1-latch"; mkdir -p "$BRIDGE_STATE_DIR"
  local key="prompt:devchannels:abc123"
  bridge_prompt_resolver_latch_held "$key" && smoke_fail "latch must start unheld" || true
  bridge_prompt_resolver_acquire_latch "$key" || smoke_fail "first acquire must succeed"
  bridge_prompt_resolver_latch_held "$key" || smoke_fail "latch must be held after acquire"
  # Second acquire for the SAME key must FAIL (the one-sender proof).
  bridge_prompt_resolver_acquire_latch "$key" && smoke_fail "second acquire for same key must FAIL (one-sender)" || true
  # A different key gets its own latch.
  bridge_prompt_resolver_acquire_latch "prompt:trust:def456" || smoke_fail "different key acquires independently"
}

# ===========================================================================
# Part 2: daemon routing. Source the floor + router from bridge-daemon.sh and a
# STUB bridge-queue / classifier, then drive a stable detection and assert ONE
# [RESOLVER] task routes (canary on), none routes (canary off), self-picker is
# skipped, and the daemon NEVER sends a key.
# ===========================================================================
STUB_DIR="$SMOKE_TMP_ROOT/stub-bin"; mkdir -p "$STUB_DIR"
QUEUE_LOG="$SMOKE_TMP_ROOT/queue-calls.log"; : >"$QUEUE_LOG"
SEND_LOG="$SMOKE_TMP_ROOT/key-sends.log"; : >"$SEND_LOG"
cp "$STALL_PY" "$STUB_DIR/bridge-stall.py"
[[ -f "$REPO_ROOT/bridge-daemon-helpers.py" ]] && cp "$REPO_ROOT/bridge-daemon-helpers.py" "$STUB_DIR/bridge-daemon-helpers.py"
# Stub bridge-notify (the #1992 floor escalation transport) — record, no network.
NOTIFY_LOG="$SMOKE_TMP_ROOT/notify-calls.log"; : >"$NOTIFY_LOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexit 0\n' "$NOTIFY_LOG" >"$STUB_DIR/bridge-notify.sh"
chmod +x "$STUB_DIR/bridge-notify.sh"

# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-lib.sh"
for _fn in bridge_safety_floor_state_file bridge_clear_safety_floor_state \
  bridge_note_safety_floor_state bridge_write_blocked_prompt_report \
  bridge_blocked_prompt_resolver_state_file bridge_blocked_prompt_write_resolver_state \
  bridge_blocked_prompt_route_to_resolver \
  bridge_operator_notify_resolve bridge_operator_notify_send \
  bridge_safety_floor_operator_notify_marker_file bridge_safety_floor_set_operator_notify_status \
  process_blocked_prompt_safety_floor; do
  # shellcheck disable=SC1090
  source <(awk -v fn="^${_fn}\\\\(\\\\) \\\\{" '$0 ~ fn {f=1} f {print} f && /^}/ {exit}' "$DAEMON_SH")
done
declare -F process_blocked_prompt_safety_floor >/dev/null || smoke_fail "floor sweep not defined after source"
declare -F bridge_blocked_prompt_route_to_resolver >/dev/null || smoke_fail "resolver router not defined after source"
SCRIPT_DIR="$STUB_DIR"

# Stub the queue CLI used by the router (find-open / create / update). Records.
# shellcheck disable=SC2329
bridge_queue_cli() {
  printf '%s\n' "$*" >>"$QUEUE_LOG"
  case "$1" in
    # The router now upserts atomically (codex r1 finding 2). --format shell
    # emits TASK_ID=<n> + TASK_CREATED. We always return one stable id.
    upsert-open) printf 'TASK_ID=4242\nTASK_CREATED=1\n' ;;
    find-open) printf '' ;;
    create) printf 'created task #4242\n' ;;
    *) printf '' ;;
  esac
}
# Stub bridge_agent_exists so the owner is "registered".
# shellcheck disable=SC2329
bridge_agent_exists() { [[ -n "${STUB_AGENT_EXISTS[$1]:-}" ]]; }
declare -A STUB_AGENT_EXISTS=([patch]=1 [worker-a]=1)
# tmux stubs for the floor sweep.
declare -A PANE_FIXTURE=()
# shellcheck disable=SC2329
bridge_capture_recent() { printf '%s' "${PANE_FIXTURE[$1]:-}"; }
# shellcheck disable=SC2329
bridge_tmux_session_exists() { [[ -n "${PANE_FIXTURE[$1]+x}" ]]; }

DEVCH_PANE='WARNING: Loading development channels
  1. I am using this for local development
  2. Cancel
Enter to confirm · Esc to cancel'
BILLING_PANE='You have reached your usage limit.
  1. Stop and wait for limit to reset
  2. Switch to extra usage
Enter to confirm · Esc to cancel'

# shellcheck disable=SC2329
summary_row() { printf '%s\t0\t0\t0\t1\t300\t0\t0\t%s\t%s\t/tmp/wd\n' "$1" "${2:-$1}" "${3:-claude}"; }
# shellcheck disable=SC2329
floor_tick() { process_blocked_prompt_safety_floor "$1" >/dev/null 2>&1 || true; }
# shellcheck disable=SC2329
reset_routing() {
  rm -rf "$BRIDGE_STATE_DIR/safety-floor" "$BRIDGE_STATE_DIR/daemon-pass-cadence" 2>/dev/null || true
  : >"$QUEUE_LOG"; : >"$NOTIFY_LOG"; : >"$SEND_LOG"
  PANE_FIXTURE=()
}
# shellcheck disable=SC2329
resolver_task_count() { grep -c 'upsert-open .*\[RESOLVER\]' "$QUEUE_LOG" 2>/dev/null || true; }

# shellcheck disable=SC2329
test_04_route_only_one_task_canary_on() {
  reset_routing
  export BRIDGE_ADMIN_AGENT_ID="patch"
  export BRIDGE_PROMPT_RESOLVER_ENABLED=1 BRIDGE_PROMPT_RESOLVER_AGENTS="worker-a"
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord" BRIDGE_OPERATOR_NOTIFY_TARGET="1"
  PANE_FIXTURE=([worker-a]="$DEVCH_PANE")
  local row; row="$(summary_row worker-a worker-a claude)"
  floor_tick "$row"   # stable=1 (no route yet)
  smoke_assert_eq "0" "$(resolver_task_count | tr -d '[:space:]')" "tick1 (stable=1): no resolver route yet"
  floor_tick "$row"   # stable=2 → route ONE task
  local n; n="$(resolver_task_count | tr -d '[:space:]')"
  [[ "$n" -ge 1 ]] || smoke_fail "stable detection must route a [RESOLVER] task (got $n)"
  # The routed task targets the owner and is metadata-only (no pane paste).
  grep -q 'upsert-open.*--to patch.*\[RESOLVER\] worker-a' "$QUEUE_LOG" || smoke_fail "resolver task not addressed to owner patch (upsert-open)"
  local body="$BRIDGE_STATE_DIR/safety-floor/worker-a.resolver-task.md"
  smoke_assert_file_exists "$body" "resolver task body written"
  grep -q 'agent-bridge resolver attempt' "$body" || smoke_fail "task body lacks the resolver command"
  smoke_assert_not_contains "$(cat "$body")" "Loading development channels" "task body must NOT paste pane capture (injection invariant)"
  # The daemon must NOT have sent a key.
  smoke_assert_eq "" "$(cat "$SEND_LOG")" "daemon NEVER sends a key (route-only)"
}

# shellcheck disable=SC2329
test_05_no_route_canary_off() {
  reset_routing
  export BRIDGE_ADMIN_AGENT_ID="patch"
  unset BRIDGE_PROMPT_RESOLVER_ENABLED BRIDGE_PROMPT_RESOLVER_AGENTS
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord" BRIDGE_OPERATOR_NOTIFY_TARGET="1"
  PANE_FIXTURE=([worker-a]="$DEVCH_PANE")
  local row; row="$(summary_row worker-a worker-a claude)"
  floor_tick "$row"; floor_tick "$row"
  smoke_assert_eq "0" "$(resolver_task_count | tr -d '[:space:]')" "DEFAULT OFF: no resolver route when canary disabled"
}

# shellcheck disable=SC2329
test_06_self_picker_skipped() {
  reset_routing
  export BRIDGE_ADMIN_AGENT_ID="patch"
  export BRIDGE_PROMPT_RESOLVER_ENABLED=1 BRIDGE_PROMPT_RESOLVER_AGENTS="all"
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord" BRIDGE_OPERATOR_NOTIFY_TARGET="1"
  PANE_FIXTURE=([patch]="$DEVCH_PANE")
  local row; row="$(summary_row patch patch claude)"
  floor_tick "$row"; floor_tick "$row"
  smoke_assert_eq "0" "$(resolver_task_count | tr -d '[:space:]')" "self-picker (agent==owner) → NO resolver task to self"
  local rs="$BRIDGE_STATE_DIR/safety-floor/patch.resolver.env"
  smoke_assert_file_exists "$rs" "self-picker resolver state recorded"
  grep -q 'skipped_self_picker' "$rs" || smoke_fail "self-picker must record skipped_self_picker outcome"
}

# shellcheck disable=SC2329
test_07_route_billing_then_resolver_denies() {
  # The daemon ROUTES even a billing prompt (routing is kind-agnostic); the
  # DENY is enforced at resolver-attempt time (tested in Part 3). Here: routing
  # happens but the daemon still never sends a key.
  reset_routing
  export BRIDGE_ADMIN_AGENT_ID="patch"
  export BRIDGE_PROMPT_RESOLVER_ENABLED=1 BRIDGE_PROMPT_RESOLVER_AGENTS="worker-a"
  export BRIDGE_OPERATOR_NOTIFY_KIND="discord" BRIDGE_OPERATOR_NOTIFY_TARGET="1"
  PANE_FIXTURE=([worker-a]="$BILLING_PANE")
  local row; row="$(summary_row worker-a worker-a claude)"
  floor_tick "$row"; floor_tick "$row"
  smoke_assert_eq "" "$(cat "$SEND_LOG")" "daemon never sends a key even for a routed billing prompt"
}

# ===========================================================================
# Part 3: resolver attempt / drain. Run bridge-resolver.sh's functions against a
# fixture safety-floor state + a STUB bridge_tmux_send_picker_key (records to
# SEND_LOG, never touches tmux). This proves: allow→one send→verified_clear;
# deny→zero send; latch→one send on dup; mismatch→no send; verify-fail→no 2nd
# key; drain→one-key-per-key; dry-run→records-no-send; prompt-injection→policy
# only, no exec.
# ===========================================================================
RSEND_LOG="$SMOKE_TMP_ROOT/resolver-sends.log"
# Build a resolver harness: source the helper's functions, override the send +
# capture, and seed state files the way the daemon router would.
# shellcheck disable=SC2329
resolver_env() {
  export BRIDGE_STATE_DIR="$SMOKE_TMP_ROOT/r3-state"
  rm -rf "$BRIDGE_STATE_DIR"; mkdir -p "$BRIDGE_STATE_DIR/safety-floor"
  rm -rf "$PANE_FIXTURE_DIR"; mkdir -p "$PANE_FIXTURE_DIR"
  export BRIDGE_PROMPT_RESOLVER_STATE_DIR="$BRIDGE_STATE_DIR/prompt-resolver"
  export BRIDGE_PROMPT_RESOLVER_ENABLED=1 BRIDGE_PROMPT_RESOLVER_AGENTS="all"
  export BRIDGE_PROMPT_RESOLVER_OWNER="patch" BRIDGE_AGENT_ID="patch"
  export BRIDGE_SCRIPT_DIR="$REPO_ROOT"
  : >"$RSEND_LOG"
}
# The agent+session-scoped resolver key (mirrors the daemon's
# bridge_blocked_prompt_resolver_key — codex r1 finding 1).
# shellcheck disable=SC2329
rkey() { printf 'prompt:%s:%s:%s:%s' "$1" "$2" "$3" "$4"; }   # agent session kind hash

# Seed a resolver routing state file (as the daemon router writes it). Takes
# agent/session/kind/hash and DERIVES the agent+session-scoped key. routed_ts +
# first_seen default to NOW so the resolver attempt window is OPEN during the
# test (the helper denies past first_seen+75s / routed_ts+45s).
# shellcheck disable=SC2329
seed_resolver_state() {
  local agent="$1" session="$2" kind="$3" hash="$4" conf="${5:-high}" owner="${6:-patch}"
  local key now; key="$(rkey "$agent" "$session" "$kind" "$hash")"; now="$(date +%s)"
  local f="$BRIDGE_STATE_DIR/safety-floor/${agent}.resolver.env"
  {
    printf 'SAFETY_FLOOR_RESOLVER_KEY=%q\n' "$key"
    printf 'SAFETY_FLOOR_RESOLVER_AGENT=%q\n' "$agent"
    printf 'SAFETY_FLOOR_RESOLVER_OWNER=%q\n' "$owner"
    printf 'SAFETY_FLOOR_RESOLVER_ROUTED_TS=%q\n' "$now"
    printf 'SAFETY_FLOOR_RESOLVER_TASK_ID=%q\n' 4242
    printf 'SAFETY_FLOOR_RESOLVER_OUTCOME=%q\n' routed
    printf 'SAFETY_FLOOR_SESSION_ID=%q\n' "$session"
    printf 'SAFETY_FLOOR_PROMPT_KIND=%q\n' "$kind"
    printf 'SAFETY_FLOOR_CONTENT_HASH=%q\n' "$hash"
    printf 'SAFETY_FLOOR_RESOLVER_CONFIDENCE=%q\n' "$conf"
    printf 'SAFETY_FLOOR_FIRST_SEEN_TS=%q\n' "$now"
    printf 'SAFETY_FLOOR_KEY=%q\n' "$key"
  } >"$f"
}

# Run an isolated resolver subprocess (real bridge-resolver.sh) with a stubbed
# send + capture, so the actual attempt/drain/latch/policy logic runs end-to-end
# but NO real key is sent. We inject stubs by writing a tiny pre-source shim.
RUN_RESOLVER_SHIM="$SMOKE_TMP_ROOT/resolver-shim.sh"
PANE_FIXTURE_DIR="$SMOKE_TMP_ROOT/pane-fixtures"
# Register a per-session BEFORE/AFTER pane fixture for the resolver subprocess.
# BEFORE = first capture (pre-send), AFTER = subsequent captures (post-send).
# shellcheck disable=SC2329
set_pane_fixture() {
  local session="$1" before="$2" after="${3:-}"
  mkdir -p "$PANE_FIXTURE_DIR"
  printf '%s' "$before" >"$PANE_FIXTURE_DIR/${session}.before"
  printf '%s' "$after" >"$PANE_FIXTURE_DIR/${session}.after"
}
# shellcheck disable=SC2329
write_resolver_shim() {
  # Single-session convenience: $1 BEFORE pane, $2 AFTER pane (default cleared).
  # Registers worker-a's fixture and (re)writes the shim. For multi-session
  # drain, call set_pane_fixture per session BEFORE running drain. A first arg
  # that is empty only (re)writes the shim — no implicit worker-a fixture.
  if [[ $# -ge 1 && -n "$1" ]]; then set_pane_fixture worker-a "$1" "${2:-}"; fi
  cat >"$RUN_RESOLVER_SHIM" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
export RESOLVER_SEND_LOG="$RSEND_LOG"
export _RESOLVER_PANE_DIR="$PANE_FIXTURE_DIR"
SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/bridge-lib.sh"
# Stub the send primitive: record the token, NEVER touch tmux.
bridge_tmux_send_picker_key() {
  local label="\$1" session="\$2" engine="\$3" token="\$4"
  # Enforce the closed vocabulary like the real one (refuse unknown tokens).
  case "\$token" in
    confirm|down|up|select_first|y|Y|n|N) printf '%s\n' "send token=\$token session=\$session" >>"\$RESOLVER_SEND_LOG"; return 0 ;;
    *) printf '%s\n' "REFUSED token=\$token" >>"\$RESOLVER_SEND_LOG"; return 1 ;;
  esac
}
# Per-session capture: first call for a session returns its BEFORE fixture,
# subsequent calls return AFTER. State is tracked per session via a marker file.
bridge_capture_recent() {
  local session="\$1"
  local seen="\${_RESOLVER_PANE_DIR}/.\${session}.seen"
  if [[ -e "\$seen" ]]; then
    cat "\${_RESOLVER_PANE_DIR}/\${session}.after" 2>/dev/null || true
  else
    : >"\$seen"
    cat "\${_RESOLVER_PANE_DIR}/\${session}.before" 2>/dev/null || true
  fi
}
bridge_agent_engine() { printf 'claude'; }
bridge_agent_exists() { case "\$1" in patch|worker-a|worker-b|worker-c) return 0 ;; *) return 1 ;; esac; }
bridge_agent_session() { printf '%s' "\$1"; }
bridge_agent_workdir() { printf '%s' "\${_RESOLVER_AGENT_WORKDIR:-/tmp/wd}"; }
# tmux stub for the trust-workdir gate: only display-message -p '#{pane_current_path}'
# is consulted; return the per-test fixture cwd (empty => unreadable cwd).
tmux() {
  if [[ "\$1" == "display-message" ]]; then printf '%s\n' "\${_RESOLVER_PANE_CWD:-}"; return 0; fi
  return 0
}
bridge_tmux_pane_target() { printf '%s' "\$1"; }
# Override bridge_with_timeout so it runs the command in-shell (our tmux stub is
# a SHELL FUNCTION; the real bridge_with_timeout execs timeout(1)<binary>, which
# would bypass the stub and hit the real tmux binary). Run the command directly.
bridge_with_timeout() { shift 2 || true; "\$@"; }
# Run the requested resolver subcommand body.
source <(awk '/^resolver_safety_floor_dir\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$RESOLVER_SH")
SHIM
  # Append the resolver-helper functions + a dispatch.
  for fn in resolver_log resolver_die resolver_state_file_for_key resolver_state_field \
    resolver_require_owner resolver_policy_decision resolver_capture_and_detect \
    resolver_attempt resolver_trust_session_registered resolver_drain resolver_status; do
    awk -v f="^${fn}\\\\(\\\\) \\\\{" '$0 ~ f {g=1} g {print} g && /^}/ {exit}' "$RESOLVER_SH" >>"$RUN_RESOLVER_SHIM"
  done
  {
    echo 'cmd="$1"; shift'
    echo 'case "$cmd" in attempt) resolver_attempt "$@" ;; drain) resolver_drain "$@" ;; status) resolver_status "$@" ;; esac'
  } >>"$RUN_RESOLVER_SHIM"
}

# shellcheck disable=SC2329
run_resolver() { bash "$RUN_RESOLVER_SHIM" "$@" 2>/dev/null; }
# shellcheck disable=SC2329
send_count() { grep -c '^send ' "$RSEND_LOG" 2>/dev/null || true; }
# Compute the REAL content_hash the #1992 detector produces for a pane fixture,
# so a routed key seeded for a test matches the live re-capture (no false
# mismatch). prompt_kind is also returned for assertions.
# shellcheck disable=SC2329
real_hash_for() {
  printf '%s\n' "$1" | python3 "$STALL_PY" detect-prompt --format shell \
    | sed -n 's/^PROMPT_CONTENT_HASH=//p' | tr -d '"'
}
# shellcheck disable=SC2329
real_kind_for() {
  printf '%s\n' "$1" | python3 "$STALL_PY" detect-prompt --format shell \
    | sed -n 's/^PROMPT_KIND=//p' | tr -d '"'
}

# shellcheck disable=SC2329
test_08_resolver_devchannels_one_send_verified() {
  resolver_env
  local h; h="$(real_hash_for "$DEVCH_PANE")"; local key; key="$(rkey worker-a worker-a devchannels "$h")"
  seed_resolver_state worker-a worker-a devchannels "$h"
  write_resolver_shim "$DEVCH_PANE" '❯ waiting for your input'
  local out; out="$(run_resolver attempt --key "$key" --owner patch)"
  smoke_assert_contains "$out" "verified_clear" "devchannels resolve → verified_clear"
  smoke_assert_eq "2" "$(send_count | tr -d '[:space:]')" "devchannels sends exactly 2 tokens (select_first confirm)"
  grep -q 'token=select_first' "$RSEND_LOG" || smoke_fail "devchannels must send select_first"
  grep -q 'token=confirm' "$RSEND_LOG" || smoke_fail "devchannels must send confirm"
}

# shellcheck disable=SC2329
test_08b_trust_workdir_match_gate() {
  # codex r1/r2 finding 5: trust is allowed ONLY when the live pane cwd equals
  # the registered agent workdir. Match → resolves; mismatch / unreadable cwd →
  # denied (fail closed). The live cwd is read from tmux metadata (stubbed).
  local TRUST_PANE='Quick safety check:
  1. Yes, I trust this folder
  2. No
Enter to confirm · Esc to cancel'
  local h; h="$(real_hash_for "$TRUST_PANE")"
  local rk_kind; rk_kind="$(real_kind_for "$TRUST_PANE")"
  [[ "$rk_kind" == "trust" ]] || smoke_fail "trust pane did not classify as trust (got $rk_kind)"
  local key; key="$(rkey worker-a worker-a trust "$h")"
  local wd="$SMOKE_TMP_ROOT/trust-wd"; mkdir -p "$wd"

  # (a) live cwd == registered workdir → trust resolves (confirm sent).
  resolver_env
  export _RESOLVER_AGENT_WORKDIR="$wd" _RESOLVER_PANE_CWD="$wd"
  seed_resolver_state worker-a worker-a trust "$h"
  write_resolver_shim "$TRUST_PANE" '❯ waiting for your input'
  local out; out="$(run_resolver attempt --key "$key" --owner patch)"
  smoke_assert_contains "$out" "verified_clear" "trust with matching workdir → resolves"
  smoke_assert_eq "1" "$(send_count | tr -d '[:space:]')" "trust resolves with one token (confirm)"

  # (b) live cwd != registered workdir → denied (no send).
  resolver_env
  export _RESOLVER_AGENT_WORKDIR="$wd" _RESOLVER_PANE_CWD="/tmp/somewhere-else-$$"
  mkdir -p "$_RESOLVER_PANE_CWD"
  seed_resolver_state worker-a worker-a trust "$h"
  write_resolver_shim "$TRUST_PANE" "$TRUST_PANE"
  out="$(run_resolver attempt --key "$key" --owner patch)"
  smoke_assert_contains "$out" "denied_policy" "trust with MISMATCHED workdir → denied"
  smoke_assert_eq "0" "$(send_count | tr -d '[:space:]')" "trust mismatch → ZERO key sends"
  rmdir "$_RESOLVER_PANE_CWD" 2>/dev/null || true

  # (c) unreadable / empty live cwd → fail closed (denied, no send).
  resolver_env
  export _RESOLVER_AGENT_WORKDIR="$wd" _RESOLVER_PANE_CWD=""
  seed_resolver_state worker-a worker-a trust "$h"
  write_resolver_shim "$TRUST_PANE" "$TRUST_PANE"
  out="$(run_resolver attempt --key "$key" --owner patch)"
  smoke_assert_contains "$out" "denied_policy" "trust with UNREADABLE cwd → fail closed (denied)"
  smoke_assert_eq "0" "$(send_count | tr -d '[:space:]')" "trust unreadable cwd → ZERO key sends"
  unset _RESOLVER_AGENT_WORKDIR _RESOLVER_PANE_CWD
}

# shellcheck disable=SC2329
test_09_resolver_billing_denied_zero_send() {
  resolver_env
  local h; h="$(real_hash_for "$BILLING_PANE")"; local key; key="$(rkey worker-a worker-a billing "$h")"
  seed_resolver_state worker-a worker-a billing "$h"
  write_resolver_shim "$BILLING_PANE" "$BILLING_PANE"
  local out; out="$(run_resolver attempt --key "$key" --owner patch)"
  smoke_assert_contains "$out" "denied_policy" "billing → denied_policy"
  smoke_assert_eq "0" "$(send_count | tr -d '[:space:]')" "billing DENY → ZERO key sends from resolver"
}

# shellcheck disable=SC2329
test_10_resolver_permission_overwrite_unknown_denied() {
  local label pane real_kind real_hash key out
  local -a labels=(permission overwrite unknown)
  for label in "${labels[@]}"; do
    resolver_env
    case "$label" in
      permission) pane='Allow Bash command for this session? (y/n)' ;;
      overwrite) pane='Overwrite? (y/n)' ;;
      unknown) pane='Choose a target:
  1. Production
  2. Staging
Enter to confirm · Esc to cancel' ;;
    esac
    real_kind="$(real_kind_for "$pane")"
    real_hash="$(real_hash_for "$pane")"
    [[ -n "$real_kind" ]] || smoke_fail "$label pane did not classify (kind empty)"
    key="$(rkey worker-a worker-a "$real_kind" "$real_hash")"
    seed_resolver_state worker-a worker-a "$real_kind" "$real_hash"
    write_resolver_shim "$pane" "$pane"
    out="$(run_resolver attempt --key "$key" --owner patch)"
    smoke_assert_contains "$out" "denied_policy" "$label ($real_kind) → denied_policy"
    smoke_assert_eq "0" "$(send_count | tr -d '[:space:]')" "$label ($real_kind) DENY → ZERO key sends"
  done
}

# shellcheck disable=SC2329
test_11_latch_one_send_on_duplicate() {
  resolver_env
  local h; h="$(real_hash_for "$DEVCH_PANE")"; local key; key="$(rkey worker-a worker-a devchannels "$h")"
  seed_resolver_state worker-a worker-a devchannels "$h"
  write_resolver_shim "$DEVCH_PANE" '❯ waiting for your input'
  run_resolver attempt --key "$key" --owner patch >/dev/null
  local first; first="$(send_count | tr -d '[:space:]')"
  # Re-seed state (duplicate task / duplicate tick) and attempt AGAIN — the
  # latch must refuse a second send.
  seed_resolver_state worker-a worker-a devchannels "$h"
  write_resolver_shim "$DEVCH_PANE" "$DEVCH_PANE"   # pretend still showing
  local out; out="$(run_resolver attempt --key "$key" --owner patch)"
  smoke_assert_contains "$out" "latch_held_no_resend" "duplicate attempt refused by latch"
  smoke_assert_eq "$first" "$(send_count | tr -d '[:space:]')" "latch → NO second send for the same key (one-sender)"
}

# shellcheck disable=SC2329
test_11b_identical_content_multi_agent_no_latch_collision() {
  # codex r1 finding 1: two DIFFERENT agents blocked on BYTE-IDENTICAL prompts
  # must get DISTINCT latches (the key includes agent+session). Each resolves
  # independently — no cross-agent latch collision suppressing the second send.
  resolver_env
  local h; h="$(real_hash_for "$DEVCH_PANE")"
  local ka kb; ka="$(rkey worker-a worker-a devchannels "$h")"; kb="$(rkey worker-b worker-b devchannels "$h")"
  [[ "$ka" != "$kb" ]] || smoke_fail "identical-content keys for different agents MUST differ (agent-scoped key)"
  seed_resolver_state worker-a worker-a devchannels "$h"
  seed_resolver_state worker-b worker-b devchannels "$h"
  write_resolver_shim ""   # per-session fixtures below
  set_pane_fixture worker-a "$DEVCH_PANE" '❯ waiting for your input'
  set_pane_fixture worker-b "$DEVCH_PANE" '❯ waiting for your input'
  run_resolver attempt --key "$ka" --owner patch >/dev/null
  run_resolver attempt --key "$kb" --owner patch >/dev/null
  # Each agent resolved → 2 keys × 2 tokens = 4 sends (no collision suppressing one).
  smoke_assert_eq "4" "$(send_count | tr -d '[:space:]')" "identical-content prompts on 2 agents → 2 independent resolves (no latch collision)"
}

# shellcheck disable=SC2329
test_12_session_changed_mismatch_no_send() {
  resolver_env
  # Routed key is devchannels, but the live pane re-detects a DIFFERENT prompt
  # (trust) → mismatch, no send. The seeded content_hash is for the devchannels
  # pane; the live trust pane differs in kind → mismatch on kind first.
  local h; h="$(real_hash_for "$DEVCH_PANE")"; local key; key="$(rkey worker-a worker-a devchannels "$h")"
  seed_resolver_state worker-a worker-a devchannels "$h"
  local TRUST_PANE='Quick safety check:
  1. Yes, I trust this folder
  2. No
Enter to confirm · Esc to cancel'
  write_resolver_shim "$TRUST_PANE" "$TRUST_PANE"
  local out; out="$(run_resolver attempt --key "$key" --owner patch)"
  smoke_assert_contains "$out" "mismatch" "key drift → mismatch"
  smoke_assert_eq "0" "$(send_count | tr -d '[:space:]')" "mismatch → NO key sent"
}

# shellcheck disable=SC2329
test_13_verify_failure_no_second_key() {
  resolver_env
  local h; h="$(real_hash_for "$DEVCH_PANE")"; local key; key="$(rkey worker-a worker-a devchannels "$h")"
  seed_resolver_state worker-a worker-a devchannels "$h"
  # BEFORE = picker; AFTER = SAME picker still present (auto-accept didn't take).
  write_resolver_shim "$DEVCH_PANE" "$DEVCH_PANE"
  local out; out="$(run_resolver attempt --key "$key" --owner patch)"
  smoke_assert_contains "$out" "still_prompt" "post-send still present → still_prompt"
  smoke_assert_eq "2" "$(send_count | tr -d '[:space:]')" "verify-fail → the ORIGINAL send happened once, NO second key"
}

# shellcheck disable=SC2329
test_14_dry_run_records_no_send() {
  resolver_env
  export BRIDGE_PROMPT_RESOLVER_DRY_RUN=1
  local h; h="$(real_hash_for "$DEVCH_PANE")"; local key; key="$(rkey worker-a worker-a devchannels "$h")"
  seed_resolver_state worker-a worker-a devchannels "$h"
  write_resolver_shim "$DEVCH_PANE" '❯ waiting for your input'
  local out; out="$(run_resolver attempt --key "$key" --owner patch)"
  unset BRIDGE_PROMPT_RESOLVER_DRY_RUN
  smoke_assert_contains "$out" "dry_run_would_send" "dry-run records the would-act decision"
  smoke_assert_eq "0" "$(send_count | tr -d '[:space:]')" "dry-run sends ZERO keys"
}

# shellcheck disable=SC2329
test_15_prompt_injection_policy_only_no_exec() {
  resolver_env
  rm -f /tmp/agb-1991-resolver-pwned
  # A pane with command-looking injected text that ALSO carries the devchannels
  # affordance. The resolver must classify by affordance, send ONLY the policy's
  # tokens, and NEVER execute the injected commands.
  local EVIL='WARNING: Loading development channels
  1. I am using this for local development
$(touch /tmp/agb-1991-resolver-pwned); `rm -rf ~`
Enter to confirm · Esc to cancel'
  local real_hash key
  real_hash="$(printf '%s\n' "$EVIL" | python3 "$STALL_PY" detect-prompt --format shell | sed -n 's/^PROMPT_CONTENT_HASH=//p' | tr -d '"')"
  key="$(rkey worker-a worker-a devchannels "$real_hash")"
  seed_resolver_state worker-a worker-a devchannels "$real_hash"
  write_resolver_shim "$EVIL" '❯ waiting for your input'
  local out; out="$(run_resolver attempt --key "$key" --owner patch)"
  [[ ! -e /tmp/agb-1991-resolver-pwned ]] || smoke_fail "INJECTION: pane text was EXECUTED by the resolver"
  smoke_assert_contains "$out" "verified_clear" "injected pane still resolves by affordance (policy-only action)"
  # Only closed semantic tokens were sent — never an injected string.
  grep -qE '^send token=(select_first|confirm)' "$RSEND_LOG" || smoke_fail "resolver did not send the policy tokens"
  grep -q 'rm -rf' "$RSEND_LOG" && smoke_fail "INJECTION: an injected string reached the send log" || true
}

# shellcheck disable=SC2329
test_16_drain_879_batch_one_key_each() {
  resolver_env
  # #879 batch: 3 agents show devchannels pickers (3 routed keys, distinct
  # content). drain must process each ONCE with one key sequence per key, no
  # second sender. Distinct option text → distinct content_hash per key.
  local PA='WARNING: Loading development channels
  1. I am using this for local development [host-a]
Enter to confirm · Esc to cancel'
  local PB='WARNING: Loading development channels
  1. I am using this for local development [host-b]
Enter to confirm · Esc to cancel'
  local PC='WARNING: Loading development channels
  1. I am using this for local development [host-c]
Enter to confirm · Esc to cancel'
  local ha hb hc
  ha="$(real_hash_for "$PA")"; hb="$(real_hash_for "$PB")"; hc="$(real_hash_for "$PC")"
  seed_resolver_state worker-a worker-a devchannels "$ha"
  seed_resolver_state worker-b worker-b devchannels "$hb"
  seed_resolver_state worker-c worker-c devchannels "$hc"
  # Per-session fixtures: each clears after its send.
  write_resolver_shim ""   # rewrite shim (no default fixture)
  set_pane_fixture worker-a "$PA" '❯ waiting for your input'
  set_pane_fixture worker-b "$PB" '❯ waiting for your input'
  set_pane_fixture worker-c "$PC" '❯ waiting for your input'
  local out; out="$(run_resolver drain --limit 10 --owner patch)"
  smoke_assert_contains "$out" "drained=3" "drain processes all 3 routed keys"
  # 3 keys × 2 tokens (select_first confirm) = 6 sends, never more (one-key-each).
  smoke_assert_eq "6" "$(send_count | tr -d '[:space:]')" "#879 batch: exactly one key sequence per key (3×2 tokens)"
  # No second sender: only the resolver send log has entries; the floor's notify
  # log and the daemon send log are untouched in this part.
}

# shellcheck disable=SC2329
test_16b_owner_fence_requires_ambient_identity() {
  # codex r1 finding 4: the owner fence is proven ONLY by ambient $BRIDGE_AGENT_ID.
  # A passed --owner is NOT identity proof, and a missing identity fails closed.
  resolver_env
  local h; h="$(real_hash_for "$DEVCH_PANE")"; local key; key="$(rkey worker-a worker-a devchannels "$h")"
  seed_resolver_state worker-a worker-a devchannels "$h"
  write_resolver_shim "$DEVCH_PANE" '❯ waiting for your input'
  # Non-owner ambient identity → refused even with --owner patch. Guard the
  # non-zero exit (resolver_die exits 1) so the smoke's set -e does not abort.
  local rc=0
  BRIDGE_AGENT_ID=intruder bash "$RUN_RESOLVER_SHIM" attempt --key "$key" --owner patch >/dev/null 2>&1 && rc=0 || rc=$?
  [[ $rc -ne 0 ]] || smoke_fail "non-owner ambient identity must be REFUSED (owner fence bypass)"
  smoke_assert_eq "0" "$(send_count | tr -d '[:space:]')" "refused caller sends ZERO keys"
  # Empty ambient identity fails closed.
  rc=0
  BRIDGE_AGENT_ID= bash "$RUN_RESOLVER_SHIM" attempt --key "$key" --owner patch >/dev/null 2>&1 && rc=0 || rc=$?
  [[ $rc -ne 0 ]] || smoke_fail "empty BRIDGE_AGENT_ID must fail closed (no implicit owner)"
  smoke_log "owner fence: identity proven only by ambient BRIDGE_AGENT_ID (--owner not accepted as proof)"
}

# shellcheck disable=SC2329
test_16c_resolver_window_enforced() {
  # codex r1 finding 3: an attempt past the absolute resolver window (first_seen
  # + 75s) is DENIED with no send — the #1992 floor owns escalation past then.
  resolver_env
  local h; h="$(real_hash_for "$DEVCH_PANE")"; local key; key="$(rkey worker-a worker-a devchannels "$h")"
  seed_resolver_state worker-a worker-a devchannels "$h"
  # Backdate routed_ts + first_seen well past the window.
  local sf="$BRIDGE_STATE_DIR/safety-floor/worker-a.resolver.env"
  local old=$(( $(date +%s) - 200 ))
  awk -v o="$old" 'BEGIN{OFS=""}
    /^SAFETY_FLOOR_RESOLVER_ROUTED_TS=/{print "SAFETY_FLOOR_RESOLVER_ROUTED_TS=", o; next}
    /^SAFETY_FLOOR_FIRST_SEEN_TS=/{print "SAFETY_FLOOR_FIRST_SEEN_TS=", o; next}
    {print}' "$sf" >"$sf.tmp" && mv "$sf.tmp" "$sf"
  write_resolver_shim "$DEVCH_PANE" '❯ waiting for your input'
  local out; out="$(run_resolver attempt --key "$key" --owner patch)"
  smoke_assert_contains "$out" "window_elapsed" "attempt past the resolver window → window_elapsed"
  smoke_assert_eq "0" "$(send_count | tr -d '[:space:]')" "past-window attempt sends ZERO keys (#1992 floor escalates)"
}

# ===========================================================================
# Part 4: legacy-sender GATES (single-sender composition) + mutation guards.
# These assert the gate exists at every legacy send site under canary.
# ===========================================================================
# shellcheck disable=SC2329
test_17_legacy_gates_present() {
  # Each legacy sender must consult the resolver-ownership gate at its send site.
  grep -q 'bridge_prompt_resolver_owns_agent' "$START_SH" \
    || smoke_fail "bridge-start.sh controller watcher is NOT gated by the resolver"
  grep -q 'bridge_prompt_resolver_owns_agent' "$RUN_SH" \
    || smoke_fail "bridge-run.sh agent backstop is NOT gated by the resolver"
  grep -q 'bridge_prompt_resolver_owns_agent' "$PICKER_SH" \
    || smoke_fail "lib/bridge-picker.sh auto-resolve is NOT gated by the resolver"
  grep -q '_psw_resolver_owns_agent' "$SWEEP_SH" \
    || smoke_fail "scripts/picker-sweep.sh is NOT gated by the resolver"
  grep -q 'bridge_prompt_resolver_should_block_send' "$TMUX_SH" \
    || smoke_fail "lib/bridge-tmux.sh primitive has NO central send-block guard"
  # The upgrade one-shot must rely on picker-sweep's self-gate.
  grep -q 'BRIDGE_PROMPT_RESOLVER' "$REPO_ROOT/bridge-upgrade.sh" \
    || smoke_fail "bridge-upgrade.sh one-shot does not document the resolver single-sender contract"
  # CRITICAL: the upgrade target-env (env -i allowlist) must pass the canary
  # vars through, or the post-upgrade picker-sweep one-shot would run WITHOUT
  # the canary env and key a resolver-owned agent (single-sender gap). Assert
  # the allowlist carries BRIDGE_PROMPT_RESOLVER_ENABLED + _AGENTS.
  local upgrade_env_body
  upgrade_env_body="$(awk '/^bridge_upgrade_with_target_env\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$REPO_ROOT/bridge-upgrade.sh")"
  smoke_assert_contains "$upgrade_env_body" "BRIDGE_PROMPT_RESOLVER_ENABLED=" \
    "upgrade target-env passes BRIDGE_PROMPT_RESOLVER_ENABLED through (one-shot self-gate works)"
  smoke_assert_contains "$upgrade_env_body" "BRIDGE_PROMPT_RESOLVER_AGENTS=" \
    "upgrade target-env passes BRIDGE_PROMPT_RESOLVER_AGENTS through"
}

# shellcheck disable=SC2329
test_18_picker_sweep_skips_canary_agent() {
  # Drive the REAL picker-sweep.sh with stubbed list/capture/send seams and
  # assert it does NOT send for a resolver-owned canary agent, but DOES for a
  # non-canary agent. The sweep self-gates via _psw_resolver_owns_agent reading
  # the canary env (it does not source bridge-lib.sh). We register the seam
  # functions from a file the sweep's stub-fn vars point at.
  local SW_SEND="$SMOKE_TMP_ROOT/sweep-sends.log"; : >"$SW_SEND"
  local SW_HOME="$SMOKE_TMP_ROOT/sweep-home"; mkdir -p "$SW_HOME/logs"
  local SEAMS="$SMOKE_TMP_ROOT/sweep-seams.sh"
  # Write the seam functions to a file (heredoc to a FILE, not stdin-to-subproc
  # — footgun #11 only bans the latter). The summary picker pane is a known
  # auto-Enter shape for BOTH listed agents.
  cat >"$SEAMS" <<SEAMS_EOF
_sw_list() { printf '%s\n' worker-a worker-z; }
_sw_cap() {
  printf '%s\n' 'Resume from summary (recommended)'
  printf '%s\n' '  1. Resume from summary (recommended)'
  printf '%s\n' '  2. Resume full session as-is'
  printf '%s\n' 'Enter to confirm · Esc to cancel'
}
_sw_send_enter() { printf 'ENTER %s\n' "\$1" >>'$SW_SEND'; }
_sw_send_option() { printf 'OPTION %s %s\n' "\$1" "\$2" >>'$SW_SEND'; }
SEAMS_EOF
  # Run the sweep in a clean subshell that sources the seams, exports them, and
  # points the sweep's seam-fn override vars at them.
  (
    # shellcheck source=/dev/null
    source "$SEAMS"
    export -f _sw_list _sw_cap _sw_send_enter _sw_send_option
    export BRIDGE_HOME="$SW_HOME"
    export BRIDGE_PICKER_SWEEP_ENABLED=1 BRIDGE_PICKER_SWEEP_SELF="" BRIDGE_PICKER_SWEEP_NOTIFY=""
    export BRIDGE_PICKER_SWEEP_LIST_SESSIONS_FN=_sw_list
    export BRIDGE_PICKER_SWEEP_CAPTURE_PANE_FN=_sw_cap
    export BRIDGE_PICKER_SWEEP_SEND_ENTER_FN=_sw_send_enter
    export BRIDGE_PICKER_SWEEP_SEND_OPTION_FN=_sw_send_option
    export BRIDGE_PROMPT_RESOLVER_ENABLED=1 BRIDGE_PROMPT_RESOLVER_AGENTS="worker-a"
    bash "$SWEEP_SH"
  ) >/dev/null 2>&1 || true
  # worker-a is canary-owned → must be skipped (no send). worker-z is not owned
  # → it DOES get a send (proves the sweep is actually keying, gate non-vacuous).
  if grep -q 'worker-a' "$SW_SEND" 2>/dev/null; then
    smoke_fail "GATE: picker-sweep sent a key for canary-owned worker-a (single-sender broken)"
  fi
  grep -q 'worker-z' "$SW_SEND" 2>/dev/null \
    || smoke_fail "GATE non-vacuous: picker-sweep should have keyed non-canary worker-z (harness broken)"
  smoke_log "picker-sweep skips resolver-owned worker-a, still keys non-canary worker-z"
}

# shellcheck disable=SC2329
test_mutation_gate_removed_key_reappears() {
  # MUTATION GUARD 1: strip the resolver gate from the picker-sweep skip and
  # assert a key WOULD reappear for the canary agent — proving the gate is
  # load-bearing (non-vacuous). We mutate a COPY, never the tracked file.
  local mutant="$SMOKE_TMP_ROOT/picker-sweep.mutant.sh"
  # Remove the resolver-skip block (the 4 lines guarding on _psw_resolver_owns_agent).
  awk '
    /Issue #1991 single-sender: skip resolver-owned/ {skip=3; next}
    skip>0 {skip--; next}
    {print}
  ' "$SWEEP_SH" >"$mutant"
  # The mutant must NO LONGER reference the skip call inside the loop body
  # (the helper def may remain, but the in-loop guard is gone).
  local guarded_calls mutant_calls
  guarded_calls="$(grep -c 'if _psw_resolver_owns_agent' "$SWEEP_SH" || true)"
  mutant_calls="$(grep -c 'if _psw_resolver_owns_agent' "$mutant" || true)"
  [[ "$guarded_calls" -ge 1 ]] || smoke_fail "MUTATION GUARD: original sweep lacks the in-loop resolver skip"
  [[ "$mutant_calls" -lt "$guarded_calls" ]] \
    || smoke_fail "MUTATION GUARD: removing the gate did not drop the in-loop skip (gate not load-bearing)"
  smoke_log "MUTATION GUARD 1: removing the picker-sweep gate drops the canary skip (gate is load-bearing)"
}

# shellcheck disable=SC2329
test_mutation_latch_removed_duplicate_sends() {
  # MUTATION GUARD 2: a resolver whose latch acquire ALWAYS succeeds would send
  # a second key on a duplicate attempt. Prove the latch is what prevents it by
  # running with the latch neutered and asserting a second send DOES occur.
  #
  # First confirm the REAL latch blocks a duplicate (the control), then build a
  # mutant shim with the latch neutered and confirm a duplicate send DOES occur.
  resolver_env
  local h; h="$(real_hash_for "$DEVCH_PANE")"; local key; key="$(rkey worker-a worker-a devchannels "$h")"
  seed_resolver_state worker-a worker-a devchannels "$h"
  write_resolver_shim "$DEVCH_PANE" "$DEVCH_PANE"

  # Build a mutant shim: append latch-neutering overrides AFTER the helper
  # functions but BEFORE the dispatch tail. We reconstruct the shim from parts
  # rather than editing in place (avoids the non-portable `head -n -N`).
  local mutant="$SMOKE_TMP_ROOT/resolver-shim.mutant.sh"
  # Everything up to (not including) the dispatch tail = lines before 'cmd="$1"'.
  awk '/^cmd="\$1"; shift$/{exit} {print}' "$RUN_RESOLVER_SHIM" >"$mutant"
  {
    echo '# MUTANT: neuter the per-key latch (always acquirable).'
    echo 'bridge_prompt_resolver_latch_held() { return 1; }'
    echo 'bridge_prompt_resolver_acquire_latch() { return 0; }'
    echo 'cmd="$1"; shift'
    echo 'case "$cmd" in attempt) resolver_attempt "$@" ;; drain) resolver_drain "$@" ;; status) resolver_status "$@" ;; esac'
  } >>"$mutant"

  : >"$RSEND_LOG"
  bash "$mutant" attempt --key "$key" --owner patch >/dev/null 2>&1 || true
  local one; one="$(send_count | tr -d '[:space:]')"
  # Second attempt with the neutered latch + same key still showing → MORE sends.
  bash "$mutant" attempt --key "$key" --owner patch >/dev/null 2>&1 || true
  local two; two="$(send_count | tr -d '[:space:]')"
  [[ "$one" -ge 1 ]] || smoke_fail "MUTATION GUARD: mutant did not send on the first attempt (harness broken)"
  [[ "$two" -gt "$one" ]] \
    || smoke_fail "MUTATION GUARD: neutering the latch did NOT cause a duplicate send (latch not load-bearing)"
  smoke_log "MUTATION GUARD 2: removing the per-key latch allows duplicate sends (latch is the one-sender proof)"
}

# --- run -------------------------------------------------------------------
smoke_run "P0: policy schema valid" test_p0_schema_valid
smoke_run "P0: allow devchannels/trust/summary" test_p0_allow_safe_kinds
smoke_run "P0: DENY billing/usage/permission/overwrite/feedback/context/unknown/low-conf" test_p0_deny_dangerous_kinds
smoke_run "P0: local policy is demote-only (no promote)" test_p0_local_demote_only
smoke_run "P0: closed token vocabulary enforced" test_p0_closed_token_vocab
smoke_run "01: canary gate default OFF + allowlist" test_01_canary_gate_default_off
smoke_run "02: central send-block guard (legacy blocked, resolver allowed)" test_02_send_block_guard
smoke_run "03: per-key attempt latch one-send" test_03_per_key_latch_one_send
smoke_run "04: route-only ONE [RESOLVER] task (canary on), daemon never sends" test_04_route_only_one_task_canary_on
smoke_run "05: no route when canary OFF (default)" test_05_no_route_canary_off
smoke_run "06: self-picker (agent==owner) skipped" test_06_self_picker_skipped
smoke_run "07: billing routed but daemon never sends" test_07_route_billing_then_resolver_denies
smoke_run "08: resolver devchannels → one send → verified_clear" test_08_resolver_devchannels_one_send_verified
smoke_run "08b: trust workdir-match gate (match/mismatch/fail-closed) (codex r2 #5)" test_08b_trust_workdir_match_gate
smoke_run "09: resolver billing → DENY → zero send" test_09_resolver_billing_denied_zero_send
smoke_run "10: resolver permission/overwrite/unknown → DENY → zero send" test_10_resolver_permission_overwrite_unknown_denied
smoke_run "11: latch → one send on duplicate task/tick" test_11_latch_one_send_on_duplicate
smoke_run "11b: identical-content multi-agent → distinct latches (codex r1 #1)" test_11b_identical_content_multi_agent_no_latch_collision
smoke_run "12: session/key changed → mismatch → no send" test_12_session_changed_mismatch_no_send
smoke_run "13: verify failure → no second key" test_13_verify_failure_no_second_key
smoke_run "14: canary dry-run → records, no send" test_14_dry_run_records_no_send
smoke_run "15: prompt-injection → policy-only, no exec" test_15_prompt_injection_policy_only_no_exec
smoke_run "16: #879 batch drain → one key per key" test_16_drain_879_batch_one_key_each
smoke_run "16b: owner fence proven by ambient identity (codex r1 #4)" test_16b_owner_fence_requires_ambient_identity
smoke_run "16c: resolver attempt window enforced (codex r1 #3)" test_16c_resolver_window_enforced
smoke_run "17: legacy-sender gates present at every site" test_17_legacy_gates_present
smoke_run "18: picker-sweep skips resolver-owned canary agent" test_18_picker_sweep_skips_canary_agent
smoke_run "MUTATION: gate removed → key reappears under canary" test_mutation_gate_removed_key_reappears
smoke_run "MUTATION: latch removed → duplicate sends" test_mutation_latch_removed_duplicate_sends

smoke_log "all #1991 agentic-resolver single-sender / default-deny / latch / injection / #879-batch / mutation checks pass"
exit 0
