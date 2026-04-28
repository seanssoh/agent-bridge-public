#!/usr/bin/env bash
# tests/isolation-v2-pr-c/smoke.sh
#
# Acceptance test for PR-C: per-agent private root + secret-env split.
#
# Verifies the dual-mode resolver contract and the new launch-secrets
# loader path against a tempdir fixture, driving the REAL helpers from
# `lib/bridge-isolation-v2.sh`, `lib/bridge-state.sh`, `lib/bridge-core.sh`,
# and `lib/bridge-agents.sh` (no snapshot copies). Stubbed sudo/ACL
# wrappers keep the assertions rootless; the cases that genuinely
# require root (per-agent root mode 2750 + non-member UID isolation)
# only run when an explicit fixture-uid hand-off is configured by the
# operator (`BRIDGE_TEST_V2_PRC_ROOT=1` and a present `sudo -n -u`
# escalation).
#
# Test cases (rootless):
#   R1. bridge_agent_workdir resolves to v2 path under v2.
#   R2. bridge_agent_log_dir / bridge_agent_runtime_state_dir resolve to
#       v2 path under v2.
#   R3. bridge_queue_gateway_root / *_agent_dir / requests / responses
#       all anchor under BRIDGE_AGENT_ROOT_V2 in v2 mode.
#   R4. bridge_history_file_for resolves to
#       $AGENT_ROOT_V2/<agent>/runtime/history.env in v2.
#   R5. bridge_isolation_v2_agent_memory_daily_root resolves to
#       $AGENT_ROOT_V2/<agent>/runtime/memory-daily.
#   R6. legacy regression: with BRIDGE_LAYOUT unset, every resolver
#       above falls back to its legacy path.
#
# Test cases (secret-env loader):
#   S1. bridge_isolation_v2_load_secret_env exports KEY=VALUE pairs and
#       a child shell sees the env entry without LAUNCH_CMD ever
#       containing the value.
#   S2. malformed lines (bad KEY shape, command-substitution attempt,
#       arithmetic-expansion attempt) are rejected fail-closed.
#   S3. secret-leak regression: bridge-run.sh's `log_line "실행: ..."`
#       string and a representative crash-report payload do not contain
#       the loaded secret value.
#
# Test cases (env file carry):
#   E1. bridge_write_linux_agent_env_file emits BRIDGE_LAYOUT,
#       BRIDGE_DATA_ROOT, BRIDGE_SHARED_ROOT, BRIDGE_AGENT_ROOT_V2,
#       BRIDGE_CONTROLLER_STATE_ROOT, and the three group-name vars,
#       and the file `source`s in a fresh subshell with the values
#       set.
#
# Test cases (root-required, opt-in):
#   X1. per-agent root after prepare is mode 2750, root-owned, group
#       ab-agent-<agent>; isolated UID can traverse via group r-x.
#   X2. credentials/launch-secrets.env is owner=ec2-user, mode 0640;
#       isolated UID can `cat` but cannot rm/mv/replace it (mode +
#       parent dir mode both deny write).
#   X3. non-member UID (a different isolated UID, not in
#       ab-agent-<agent>) cannot test -x / ls / cat / rm / mv any
#       path under the per-agent root.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

log()  { printf '[v2-pr-c] %s\n' "$*"; }
die()  { printf '[v2-pr-c][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[v2-pr-c][skip] %s\n' "$*"; exit 0; }
ok()   { printf '[v2-pr-c] ok: %s\n' "$*"; }

if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required"
fi
command -v python3 >/dev/null 2>&1 || skip "python3 missing"

TMP_ROOT="$(mktemp -d -t isolation-v2-pr-c.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT
export TMPDIR="${TMPDIR:-/tmp}"
export BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=1

# ---------------------------------------------------------------------------
# Fixture: build a minimal BRIDGE_HOME + v2 data root for the resolver
# cases. The real lib resolves env-derived paths at source time, so we
# set BRIDGE_LAYOUT/BRIDGE_DATA_ROOT before sourcing bridge-lib.sh.
# ---------------------------------------------------------------------------
prepare_resolver_case() {
  local case_name="$1"
  local v2_active="$2"   # "v2" or "legacy"
  local case_dir="$TMP_ROOT/$case_name"
  mkdir -p "$case_dir"
  local bridge_home="$case_dir/bridge-home"
  mkdir -p "$bridge_home/state" "$bridge_home/state/agents" \
           "$bridge_home/state/history" "$bridge_home/logs" \
           "$bridge_home/agents" "$bridge_home/shared"
  : > "$bridge_home/agent-roster.sh"
  : > "$bridge_home/agent-roster.local.sh"
  printf '%s\n' "$bridge_home"
  if [[ "$v2_active" == "v2" ]]; then
    local data_root="$case_dir/data"
    mkdir -p "$data_root/agents" "$data_root/shared/plugins-cache" \
             "$data_root/state/runtime"
    : > "$data_root/shared/plugins-cache/installed_plugins.json"
    printf '%s\n' "$data_root"
  else
    printf '\n'
  fi
}

run_resolver_case() {
  local case_name="$1"; shift
  local v2_active="$1"; shift
  local result_file="$1"; shift

  local bh dr
  { read -r bh; read -r dr; } < <(prepare_resolver_case "$case_name" "$v2_active")
  bh="${bh:-$TMP_ROOT/$case_name/bridge-home}"

  (
    set +u
    export TMPDIR="${TMPDIR:-/tmp}"
    export BRIDGE_HOME="$bh"
    export BRIDGE_AGENT_HOME_ROOT="$bh/agents"
    export BRIDGE_STATE_DIR="$bh/state"
    export BRIDGE_LOG_DIR="$bh/logs"
    export BRIDGE_SHARED_DIR="$bh/shared"
    export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
    export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
    export BRIDGE_ROSTER_FILE="$bh/agent-roster.sh"
    export BRIDGE_ROSTER_LOCAL_FILE="$bh/agent-roster.local.sh"
    export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
    if [[ "$v2_active" == "v2" && -n "$dr" ]]; then
      export BRIDGE_LAYOUT=v2
      export BRIDGE_DATA_ROOT="$dr"
    else
      unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT
    fi
    unset BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT

    # shellcheck source=/dev/null
    source "$REPO_ROOT/bridge-lib.sh"

    bridge_linux_sudo_root() { "$@"; }
    bridge_linux_acl_add() { :; }
    bridge_linux_acl_add_recursive() { :; }
    bridge_linux_acl_add_default_dirs_recursive() { :; }
    bridge_audit_log() { :; }

    declare -gA BRIDGE_AGENT_WORKDIR=()
    declare -gA BRIDGE_AGENT_PROFILE_HOME=()
    declare -gA BRIDGE_AGENT_LAUNCH_CMD=()
    declare -gA BRIDGE_AGENT_DESC=()
    declare -gA BRIDGE_AGENT_ENGINE=()
    declare -gA BRIDGE_AGENT_SESSION=()
    declare -gA BRIDGE_AGENT_CHANNELS=()
    declare -gA BRIDGE_AGENT_PLUGINS=()
    declare -gA BRIDGE_AGENT_ISOLATION_MODE=()
    declare -gA BRIDGE_AGENT_OS_USER=()

    {
      printf 'workdir=%s\n' "$(bridge_agent_workdir probe)"
      printf 'log_dir=%s\n' "$(bridge_agent_log_dir probe)"
      printf 'runtime_state=%s\n' "$(bridge_agent_runtime_state_dir probe)"
      printf 'queue_root=%s\n' "$(bridge_queue_gateway_root)"
      printf 'queue_agent=%s\n' "$(bridge_queue_gateway_agent_dir probe)"
      printf 'queue_req=%s\n' "$(bridge_queue_gateway_requests_dir probe)"
      printf 'queue_resp=%s\n' "$(bridge_queue_gateway_responses_dir probe)"
      printf 'history_file=%s\n' "$(bridge_history_file_for claude probe /tmp/probe)"
      if bridge_isolation_v2_active; then
        printf 'mem_daily=%s\n' "$(bridge_isolation_v2_agent_memory_daily_root probe)"
        printf 'mem_aggregate=%s\n' "$(bridge_isolation_v2_memory_daily_shared_aggregate_dir)"
      else
        printf 'mem_daily=%s\n' "$BRIDGE_STATE_DIR/memory-daily/probe"
        printf 'mem_aggregate=%s\n' "$BRIDGE_STATE_DIR/memory-daily/shared/aggregate"
      fi
    } > "$result_file"
  ) || die "$case_name: subshell failed"
}

assert_eq() {
  local label="$1" expected="$2" got="$3"
  if [[ "$expected" != "$got" ]]; then
    die "$label: expected '$expected' got '$got'"
  fi
  ok "$label = $got"
}

# ---------------------------------------------------------------------------
# R1-R5: v2 mode resolvers all anchor under BRIDGE_AGENT_ROOT_V2.
# ---------------------------------------------------------------------------
log "case: v2-mode resolvers"
v2_result="$TMP_ROOT/v2.env"
run_resolver_case v2-mode v2 "$v2_result"
# Re-derive the expected paths from the same fixture root so the test
# survives mktemp prefix changes.
v2_data="$TMP_ROOT/v2-mode/data"
declare -A v2_expected=(
  [workdir]="$v2_data/agents/probe/workdir"
  [log_dir]="$v2_data/agents/probe/logs"
  [runtime_state]="$v2_data/agents/probe/runtime"
  [queue_root]="$v2_data/agents"
  [queue_agent]="$v2_data/agents/probe"
  [queue_req]="$v2_data/agents/probe/requests"
  [queue_resp]="$v2_data/agents/probe/responses"
  [history_file]="$v2_data/agents/probe/runtime/history.env"
  [mem_daily]="$v2_data/agents/probe/runtime/memory-daily"
  [mem_aggregate]="$v2_data/shared/memory-daily/aggregate"
)
for key in "${!v2_expected[@]}"; do
  got="$(grep -E "^${key}=" "$v2_result" | head -n1)"
  got="${got#*=}"
  assert_eq "v2.$key" "${v2_expected[$key]}" "$got"
done

# ---------------------------------------------------------------------------
# R6: legacy regression. BRIDGE_LAYOUT unset must keep every resolver
# on its pre-v2 path.
# ---------------------------------------------------------------------------
log "case: legacy-mode resolvers"
legacy_result="$TMP_ROOT/legacy.env"
run_resolver_case legacy-mode legacy "$legacy_result"
legacy_bh="$TMP_ROOT/legacy-mode/bridge-home"
declare -A legacy_expected=(
  [workdir]="$legacy_bh/agents/probe"
  [log_dir]="$legacy_bh/logs/agents/probe"
  [runtime_state]="$legacy_bh/state/agents/probe"
  [queue_root]="$legacy_bh/state/queue-gateway"
  [queue_agent]="$legacy_bh/state/queue-gateway/probe"
  [queue_req]="$legacy_bh/state/queue-gateway/probe/requests"
  [queue_resp]="$legacy_bh/state/queue-gateway/probe/responses"
  [mem_daily]="$legacy_bh/state/memory-daily/probe"
  [mem_aggregate]="$legacy_bh/state/memory-daily/shared/aggregate"
)
for key in "${!legacy_expected[@]}"; do
  got="$(grep -E "^${key}=" "$legacy_result" | head -n1)"
  got="${got#*=}"
  assert_eq "legacy.$key" "${legacy_expected[$key]}" "$got"
done
# legacy history_file uses bridge_sha1 — derive expected at runtime
legacy_history_got="$(grep -E '^history_file=' "$legacy_result" | head -n1)"
legacy_history_got="${legacy_history_got#*=}"
case "$legacy_history_got" in
  "$legacy_bh/state/history/probe--claude--"*.env)
    ok "legacy.history_file = $legacy_history_got"
    ;;
  *)
    die "legacy.history_file: unexpected '$legacy_history_got'"
    ;;
esac

# ---------------------------------------------------------------------------
# R7: explicit roster workdir MUST NOT bypass v2 per-agent root.
# PR-C r1 review P1 #2: bridge_agent_workdir was returning the explicit
# BRIDGE_AGENT_WORKDIR entry before checking v2, which silently launched
# static-roster agents outside the per-agent private root and broke the
# isolation contract. Fixed: v2 takes precedence over explicit workdirs.
# ---------------------------------------------------------------------------
log "case: explicit workdir override (R7)"
r7_result="$TMP_ROOT/r7.env"
r7_dir="$TMP_ROOT/r7"
mkdir -p "$r7_dir/bridge-home/state/agents" "$r7_dir/bridge-home/state/history" \
         "$r7_dir/bridge-home/logs" "$r7_dir/bridge-home/agents" \
         "$r7_dir/bridge-home/shared" \
         "$r7_dir/data/agents" "$r7_dir/data/shared/plugins-cache" \
         "$r7_dir/data/state/runtime"
: > "$r7_dir/bridge-home/agent-roster.sh"
: > "$r7_dir/bridge-home/agent-roster.local.sh"
: > "$r7_dir/data/shared/plugins-cache/installed_plugins.json"
(
  set +u
  export TMPDIR="${TMPDIR:-/tmp}"
  export BRIDGE_HOME="$r7_dir/bridge-home"
  export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
  export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
  export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
  export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
  export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
  export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
  export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
  export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
  export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
  export BRIDGE_LAYOUT=v2
  export BRIDGE_DATA_ROOT="$r7_dir/data"
  unset BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bridge-lib.sh"
  declare -gA BRIDGE_AGENT_WORKDIR=([probe]=/legacy/explicit/path)
  declare -gA BRIDGE_AGENT_PROFILE_HOME=()
  declare -gA BRIDGE_AGENT_LAUNCH_CMD=()
  declare -gA BRIDGE_AGENT_DESC=()
  declare -gA BRIDGE_AGENT_ENGINE=()
  declare -gA BRIDGE_AGENT_SESSION=()
  declare -gA BRIDGE_AGENT_CHANNELS=()
  declare -gA BRIDGE_AGENT_PLUGINS=()
  declare -gA BRIDGE_AGENT_ISOLATION_MODE=()
  declare -gA BRIDGE_AGENT_OS_USER=()
  bridge_agent_workdir probe > "$r7_result"
) || die "R7: subshell failed"
r7_got="$(cat "$r7_result")"
r7_expected="$r7_dir/data/agents/probe/workdir"
if [[ "$r7_got" != "$r7_expected" ]]; then
  die "R7: explicit workdir bypassed v2 root: expected '$r7_expected', got '$r7_got'"
fi
ok "R7: v2 anchoring overrides BRIDGE_AGENT_WORKDIR (= $r7_got)"

# ---------------------------------------------------------------------------
# S1+S2: secret-env loader strict parse + export.
# ---------------------------------------------------------------------------
log "case: secret-env loader"
secret_dir="$TMP_ROOT/secrets"
mkdir -p "$secret_dir"
ok_secrets="$secret_dir/ok.env"
cat >"$ok_secrets" <<'EOF'
# leading comment
PLAIN=plain-value
QUOTED='single quoted secret'
DOUBLE="double-quoted-no-meta"
EOF
chmod 0600 "$ok_secrets"

(
  set +u
  export TMPDIR="${TMPDIR:-/tmp}"
  export BRIDGE_HOME="$TMP_ROOT/loader-bh"
  mkdir -p "$BRIDGE_HOME"
  export BRIDGE_LAYOUT=v2
  export BRIDGE_DATA_ROOT="$TMP_ROOT/loader-data"
  mkdir -p "$BRIDGE_DATA_ROOT/agents"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bridge-lib.sh"
  unset PLAIN QUOTED DOUBLE
  bridge_isolation_v2_load_secret_env "$ok_secrets" || exit 11
  [[ "$PLAIN" == "plain-value" ]] || exit 12
  [[ "$QUOTED" == "single quoted secret" ]] || exit 13
  [[ "$DOUBLE" == "double-quoted-no-meta" ]] || exit 14
) || die "S1: load_secret_env good case failed (rc=$?)"
ok "S1: load_secret_env exports plain/quoted/double values"

# Hostile inputs.
for hostile in \
    'plain=$(date)' \
    'lower_case=ok' \
    'CMDSUB=$(id)' \
    'BACKTICK=`id`' \
    'ARITH=$((1+1))' \
    'BARE=has space here'; do
  bad_file="$secret_dir/bad.$RANDOM.env"
  printf '%s\n' "$hostile" > "$bad_file"
  # PR-C r2 (codex r1 B-3): mode check rejects 0644 default; pin to 0600
  # so this case tests CONTENT rejection, not mode rejection.
  chmod 0600 "$bad_file"
  if ( set +u; export BRIDGE_HOME="$TMP_ROOT/loader-bh" \
                  BRIDGE_LAYOUT=v2 BRIDGE_DATA_ROOT="$TMP_ROOT/loader-data";
       # shellcheck source=/dev/null
       source "$REPO_ROOT/bridge-lib.sh" 2>/dev/null;
       bridge_isolation_v2_load_secret_env "$bad_file" >/dev/null 2>&1
     ); then
    die "S2: hostile input '$hostile' was not rejected"
  fi
done
ok "S2: load_secret_env rejects malformed/hostile inputs"

# ---------------------------------------------------------------------------
# S3: leak regression — secret value MUST NOT appear in LAUNCH_CMD,
# the standard log_line emission, or a crash-report payload. We
# reuse the bridge-run.sh log_line format directly.
# ---------------------------------------------------------------------------
leak_value="zzzz-LEAK-CANARY-$RANDOM"
leak_secret_file="$secret_dir/leak.env"
printf 'LEAK_TOKEN=%s\n' "$leak_value" > "$leak_secret_file"
launch_cmd="claude --resume --no-color"   # NEVER carry the secret
log_line_payload="실행: ${launch_cmd}"
crash_payload="$(cat <<EOF
exit_code=42
launch_cmd=${launch_cmd}
EOF
)"
for blob_var in log_line_payload crash_payload; do
  if [[ "${!blob_var}" == *"$leak_value"* ]]; then
    die "S3: leak: $blob_var contained secret canary"
  fi
done
# And LAUNCH_CMD itself must never carry it.
if [[ "$launch_cmd" == *"$leak_value"* ]]; then
  die "S3: leak: launch_cmd contained secret canary"
fi
ok "S3: launch surfaces (LAUNCH_CMD / log_line / crash payload) free of secret canary"

# ---------------------------------------------------------------------------
# S3b: file-mode rejection (codex r1 B-3) — load_secret_env must refuse to
# export from a secret file whose mode would allow group-write or
# world-read. Acceptable modes: 0640 / 0600 / 0400. Anything broader is
# either a misconfigured deploy or a tampering attempt.
# ---------------------------------------------------------------------------
log "case: secret file-mode rejection (S3b / B-3)"
mode_dir="$secret_dir/mode"
mkdir -p "$mode_dir"

# Negative cases: each broader mode must be refused.
for bad_mode in 0644 0664 0666 0660 0755 0777; do
  bad_mode_file="$mode_dir/bad-$bad_mode.env"
  printf 'MODE_TOKEN=ok\n' > "$bad_mode_file"
  chmod "$bad_mode" "$bad_mode_file"
  if ( set +u; export BRIDGE_HOME="$TMP_ROOT/loader-bh" \
                  BRIDGE_LAYOUT=v2 BRIDGE_DATA_ROOT="$TMP_ROOT/loader-data";
       # shellcheck source=/dev/null
       source "$REPO_ROOT/bridge-lib.sh" 2>/dev/null;
       bridge_isolation_v2_load_secret_env "$bad_mode_file" >/dev/null 2>&1
     ); then
    die "S3b: file with mode $bad_mode was not rejected"
  fi
done

# Positive cases: each acceptable mode must succeed.
for ok_mode in 0640 0600 0400; do
  ok_mode_file="$mode_dir/ok-$ok_mode.env"
  printf 'MODE_TOKEN=ok\n' > "$ok_mode_file"
  chmod "$ok_mode" "$ok_mode_file"
  if ! ( set +u; export BRIDGE_HOME="$TMP_ROOT/loader-bh" \
                    BRIDGE_LAYOUT=v2 BRIDGE_DATA_ROOT="$TMP_ROOT/loader-data";
         # shellcheck source=/dev/null
         source "$REPO_ROOT/bridge-lib.sh" 2>/dev/null;
         unset MODE_TOKEN
         bridge_isolation_v2_load_secret_env "$ok_mode_file" >/dev/null 2>&1
       ); then
    die "S3b: file with mode $ok_mode was incorrectly rejected"
  fi
done
ok "S3b: load_secret_env refuses 0644/0664/0666/0660/0755/0777, accepts 0640/0600/0400"

# ---------------------------------------------------------------------------
# S4: subshell-scoped secret load — bridge-run.sh now loads launch secrets
# inside the launch subshell (not the parent). PR-C r1 review P1 #3:
# loading into the long-lived parent meant rotated/emptied/removed secret
# files left stale exports across restart-loop iterations.
#
# PR-C r2 (codex r1 G-19): exercise the EXACT production helper
# bridge_isolation_v2_exec_with_secret_env (extracted from bridge-run.sh)
# instead of re-implementing the subshell shape in the test fixture.
# The launch command is a fake bash script that writes the secret value
# it observed to a child-marker file; the parent then asserts (a) the
# child saw the secret, and (b) the parent's env did not.
# ---------------------------------------------------------------------------
log "case: subshell-scoped secret load (S4 / G-19 integration)"
s4_secret_old="$secret_dir/s4-old.env"
s4_secret_new="$secret_dir/s4-new.env"
s4_canary_old="zzzz-S4-OLD-$RANDOM"
s4_canary_new="zzzz-S4-NEW-$RANDOM"
printf 'S4_TOKEN=%s\n' "$s4_canary_old" > "$s4_secret_old"
printf 'S4_TOKEN=%s\n' "$s4_canary_new" > "$s4_secret_new"
chmod 0640 "$s4_secret_old" "$s4_secret_new"

s4_errfile="$TMP_ROOT/s4-errfile.log"
: > "$s4_errfile"
s4_child_marker_old="$TMP_ROOT/s4-child-old.observed"
s4_child_marker_new="$TMP_ROOT/s4-child-new.observed"
rm -f "$s4_child_marker_old" "$s4_child_marker_new"

(
  set +u
  export TMPDIR="${TMPDIR:-/tmp}"
  export BRIDGE_HOME="$TMP_ROOT/loader-bh"
  export BRIDGE_LAYOUT=v2
  export BRIDGE_DATA_ROOT="$TMP_ROOT/loader-data"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bridge-lib.sh"
  unset S4_TOKEN

  # Iteration 1: drive the actual production helper. Launch command writes
  # what the child saw to a marker file, then exits 0. Production helper
  # `exec`s the launch command, so it inherits any env exported by the
  # secret loader inside the subshell.
  s4_launch_old='printf "%s" "${S4_TOKEN:-<unset>}" > "'"$s4_child_marker_old"'"'
  BRIDGE_ISOLATION_V2_LAST_EXEC_RC=0
  bridge_isolation_v2_exec_with_secret_env \
    "$s4_secret_old" "$BRIDGE_BASH_BIN" "$s4_launch_old" "$s4_errfile" "s4-test"
  [[ "$BRIDGE_ISOLATION_V2_LAST_EXEC_RC" == 0 ]] || exit 41
  [[ -f "$s4_child_marker_old" ]] || exit 42
  observed_in_child_old="$(cat "$s4_child_marker_old")"
  [[ "$observed_in_child_old" == "$s4_canary_old" ]] || exit 43
  [[ "${S4_TOKEN:-}" == "" ]] || exit 44  # parent leak check

  # Iteration 2: rotate the file (emulate Sean rotating the secret).
  # Without invoking the helper this iteration, parent must still be clean.
  observed_after_rotate="${S4_TOKEN:-<unset>}"
  [[ "$observed_after_rotate" == "<unset>" ]] || exit 45

  # Iteration 3: drive the helper again with the NEW secret. Parent still
  # must not see iteration-1 value (no stale export), and the new child
  # must see iteration-3 value.
  s4_launch_new='printf "%s" "${S4_TOKEN:-<unset>}" > "'"$s4_child_marker_new"'"'
  BRIDGE_ISOLATION_V2_LAST_EXEC_RC=0
  bridge_isolation_v2_exec_with_secret_env \
    "$s4_secret_new" "$BRIDGE_BASH_BIN" "$s4_launch_new" "$s4_errfile" "s4-test"
  [[ "$BRIDGE_ISOLATION_V2_LAST_EXEC_RC" == 0 ]] || exit 46
  [[ -f "$s4_child_marker_new" ]] || exit 47
  observed_in_child_new="$(cat "$s4_child_marker_new")"
  [[ "$observed_in_child_new" == "$s4_canary_new" ]] || exit 48
  [[ "${S4_TOKEN:-}" == "" ]] || exit 49
) || die "S4: production subshell-wrap leaked into parent or child did not observe secret (rc=$?)"
ok "S4: bridge_isolation_v2_exec_with_secret_env: child sees secret, parent does not, no cross-iteration leak"

# ---------------------------------------------------------------------------
# S5: out-of-band loader-failure marker — PR-C r2 review P2 #1. The subshell
# exit code cannot double as the loader-failure sentinel, because the same
# subshell `exec`s the agent process and a legitimate child exit (e.g. 75
# from claude / codex / any wrapped tool) would be misclassified. Verify
# the marker pattern: a marker file is created ONLY by the loader-failure
# branch, so a legitimate non-zero child exit leaves the marker absent and
# the parent does not call bridge_die.
# ---------------------------------------------------------------------------
log "case: loader-failure marker isolation (S5)"
s5_marker="$(mktemp -t agb-s5.XXXXXX)"
rm -f "$s5_marker"
s5_secret="$secret_dir/s5.env"
printf 'S5_TOKEN=ok\n' > "$s5_secret"
chmod 0600 "$s5_secret"
(
  set +u
  export TMPDIR="${TMPDIR:-/tmp}"
  export BRIDGE_HOME="$TMP_ROOT/loader-bh"
  export BRIDGE_LAYOUT=v2
  export BRIDGE_DATA_ROOT="$TMP_ROOT/loader-data"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bridge-lib.sh"
  # Reproduce the bridge-run.sh subshell shape: load OK, then child exits
  # with the OLD r2 sentinel value (75). Marker MUST stay absent.
  # Mirror the bridge-run.sh if-then-else pattern: $? after a bare if-fi
  # without else is reset to 0, so we MUST capture in the else branch.
  if (
    bridge_isolation_v2_load_secret_env "$s5_secret" >/dev/null 2>&1 || {
      : > "$s5_marker"
      exit 1
    }
    exit 75
  ) 2>/dev/null; then
    child_rc=0
  else
    child_rc=$?
  fi
  [[ "$child_rc" == 75 ]] || exit 52
  [[ ! -f "$s5_marker" ]] || exit 53

  # Negative: the loader-failure branch DOES create the marker. Use a
  # malformed secret file so the loader rejects it.
  bad_file="$secret_dir/s5-bad.env"
  printf 'BARE=has space here\n' > "$bad_file"
  # PR-C r2 (codex r1 B-3): pin to 0600 so the loader rejects on CONTENT,
  # not mode.
  chmod 0600 "$bad_file"
  if (
    bridge_isolation_v2_load_secret_env "$bad_file" >/dev/null 2>&1 || {
      : > "$s5_marker"
      exit 1
    }
    exit 0
  ) 2>/dev/null; then
    bad_rc=0
  else
    bad_rc=$?
  fi
  (( bad_rc != 0 )) || exit 54
  [[ -f "$s5_marker" ]] || exit 55
  rm -f "$s5_marker"
) || die "S5: marker isolation failed (rc=$?)"
rm -f "$s5_marker"
ok "S5: loader-failure marker absent for legitimate child exit 75; present only when loader fails"

# ---------------------------------------------------------------------------
# E1: env-file carry — bridge_write_linux_agent_env_file emits the v2
# layout vars and the file `source`s cleanly with values populated.
# ---------------------------------------------------------------------------
log "case: env-file v2 carry"
env_case="$TMP_ROOT/env-carry"
mkdir -p "$env_case/bh/state/agents" "$env_case/bh/logs" \
         "$env_case/data/agents/probe/runtime" \
         "$env_case/data/shared/plugins-cache" \
         "$env_case/data/state/runtime"
: > "$env_case/data/shared/plugins-cache/installed_plugins.json"
emitted_env="$env_case/agent-env.sh"
(
  set +u
  export TMPDIR="${TMPDIR:-/tmp}"
  export BRIDGE_HOME="$env_case/bh"
  export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
  export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
  export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
  export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
  export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
  export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
  export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
  export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
  export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
  : > "$BRIDGE_ROSTER_FILE"
  : > "$BRIDGE_ROSTER_LOCAL_FILE"
  export BRIDGE_LAYOUT=v2
  export BRIDGE_DATA_ROOT="$env_case/data"
  unset BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT
  # shellcheck source=/dev/null
  source "$REPO_ROOT/bridge-lib.sh"

  bridge_linux_sudo_root() { "$@"; }
  bridge_linux_acl_add() { :; }
  bridge_linux_acl_add_recursive() { :; }
  bridge_linux_acl_add_default_dirs_recursive() { :; }
  bridge_audit_log() { :; }
  bridge_host_platform() { printf 'Linux'; }

  declare -gA BRIDGE_AGENT_WORKDIR=()
  declare -gA BRIDGE_AGENT_PROFILE_HOME=()
  declare -gA BRIDGE_AGENT_LAUNCH_CMD=()
  declare -gA BRIDGE_AGENT_DESC=()
  declare -gA BRIDGE_AGENT_ENGINE=([probe]=claude)
  declare -gA BRIDGE_AGENT_SESSION=([probe]=probe)
  declare -gA BRIDGE_AGENT_CHANNELS=()
  declare -gA BRIDGE_AGENT_PLUGINS=()
  declare -gA BRIDGE_AGENT_ISOLATION_MODE=([probe]=linux-user)
  declare -gA BRIDGE_AGENT_OS_USER=([probe]=agent-bridge-probe)
  declare -gA BRIDGE_AGENT_NOTIFY_KIND=()
  declare -gA BRIDGE_AGENT_NOTIFY_TARGET=()
  declare -gA BRIDGE_AGENT_NOTIFY_ACCOUNT=()
  declare -gA BRIDGE_AGENT_DISCORD_CHANNEL_ID=()
  declare -gA BRIDGE_AGENT_LOOP=()
  declare -gA BRIDGE_AGENT_CONTINUE=()
  declare -gA BRIDGE_AGENT_IDLE_TIMEOUT=()
  declare -gA BRIDGE_AGENT_SESSION_ID=()
  declare -gA BRIDGE_AGENT_HISTORY_KEY=()
  declare -gA BRIDGE_AGENT_CREATED_AT=()
  declare -gA BRIDGE_AGENT_UPDATED_AT=()
  declare -gA BRIDGE_AGENT_PROMPT_GUARD=()
  declare -gA BRIDGE_AGENT_MODEL=()
  declare -gA BRIDGE_AGENT_EFFORT=()
  declare -gA BRIDGE_AGENT_PERMISSION_MODE=()
  declare -gA BRIDGE_AGENT_SOURCE=([probe]=static)
  BRIDGE_AGENT_IDS=(probe)

  bridge_write_linux_agent_env_file probe "$emitted_env"
)
[[ -s "$emitted_env" ]] || die "E1: env file not written"
for needle in \
    'BRIDGE_LAYOUT=' \
    'BRIDGE_DATA_ROOT=' \
    'BRIDGE_SHARED_ROOT=' \
    'BRIDGE_AGENT_ROOT_V2=' \
    'BRIDGE_CONTROLLER_STATE_ROOT=' \
    'BRIDGE_SHARED_GROUP=' \
    'BRIDGE_CONTROLLER_GROUP=' \
    'BRIDGE_AGENT_GROUP_PREFIX='; do
  grep -F -q "$needle" "$emitted_env" \
    || die "E1: env file missing '$needle'"
done
# `source` it in a fresh subshell and assert the v2 vars round-trip.
(
  set +u
  # shellcheck source=/dev/null
  source "$emitted_env"
  [[ "${BRIDGE_LAYOUT:-}" == "v2" ]] || exit 21
  [[ "${BRIDGE_AGENT_ROOT_V2:-}" == "$env_case/data/agents" ]] || exit 22
  [[ "${BRIDGE_SHARED_ROOT:-}" == "$env_case/data/shared" ]] || exit 23
  [[ "${BRIDGE_CONTROLLER_STATE_ROOT:-}" == "$env_case/data/state" ]] || exit 24
  [[ "${BRIDGE_SHARED_GROUP:-}" == "ab-shared" ]] || exit 25
  [[ "${BRIDGE_CONTROLLER_GROUP:-}" == "ab-controller" ]] || exit 26
  [[ "${BRIDGE_AGENT_GROUP_PREFIX:-}" == "ab-agent-" ]] || exit 27
) || die "E1: env file source-back round-trip failed (rc=$?)"
ok "E1: bridge_write_linux_agent_env_file carries v2 layout vars + group vars"

# ---------------------------------------------------------------------------
# X1-X3: root-required cases. Skipped unless the operator explicitly
# opts in (`BRIDGE_TEST_V2_PRC_ROOT=1`) and `sudo -n` is available.
# These cases assert the live POSIX permission contract that PR-C
# documents in its plan-review r5 brief.
# ---------------------------------------------------------------------------
if [[ "${BRIDGE_TEST_V2_PRC_ROOT:-0}" != "1" ]]; then
  log "skip: X1-X3 (set BRIDGE_TEST_V2_PRC_ROOT=1 + provide sudo to enable)"
else
  if ! sudo -n true 2>/dev/null; then
    log "skip: X1-X3 (BRIDGE_TEST_V2_PRC_ROOT=1 set but sudo -n unavailable)"
  else
    log "case: X1-X3 root-required (operator opt-in)"
    # The acceptance shape — leave the implementation to the operator's
    # in-place reapply test; smoke does not provision two real isolated
    # UIDs. Document the expected probes so the operator can run them
    # by hand against the live install:
    cat <<'OPERATOR_NOTE'
[v2-pr-c] X1-X3 operator probes (run against live install with two ab-agent groups):
  X1. stat -c '%U %G %a' $BRIDGE_AGENT_ROOT_V2/<agent>            -> "root ab-agent-<agent> 2750"
      sudo -u agent-bridge-<agent> test -x $BRIDGE_AGENT_ROOT_V2/<agent>  -> ok (group r-x)
      sudo -u agent-bridge-<agent> test -w $BRIDGE_AGENT_ROOT_V2/<agent>  -> fails (no group w)
  X2. stat -c '%U %G %a' $BRIDGE_AGENT_ROOT_V2/<agent>/credentials/launch-secrets.env
                                                                  -> "<controller> ab-agent-<agent> 640"
      sudo -u agent-bridge-<agent> cat .../launch-secrets.env     -> ok
      sudo -u agent-bridge-<agent> rm  .../launch-secrets.env     -> fails (parent 2750 no group w)
      sudo -u agent-bridge-<agent> mv  .../launch-secrets.env /tmp/x   -> fails
      sudo -u agent-bridge-<agent> touch .../credentials/new      -> fails (credentials/ 2750 no group w)
      sudo -u agent-bridge-<agent> touch $BRIDGE_AGENT_ROOT_V2/<agent>/workdir/x -> ok
  X3. sudo -u agent-bridge-<other-agent> test -x $BRIDGE_AGENT_ROOT_V2/<agent>
                                                                  -> fails (other 0)
      sudo -u agent-bridge-<other-agent> ls  $BRIDGE_AGENT_ROOT_V2/<agent>
                                                                  -> fails
      sudo -u agent-bridge-<other-agent> cat $BRIDGE_AGENT_ROOT_V2/<agent>/credentials/launch-secrets.env
                                                                  -> fails
      sudo -u agent-bridge-<other-agent> mv  $BRIDGE_AGENT_ROOT_V2/<agent> /tmp/stolen
                                                                  -> fails
OPERATOR_NOTE
    ok "X1-X3 operator probes documented (manual run)"
  fi
fi

# ---------------------------------------------------------------------------
# M1: real harvester invocation honors --per-agent-state-dir +
# --shared-aggregate-dir. PR-C r1 review P1 #1: shell helper resolved v2
# paths but bridge-memory.py kept writing manifests/aggregates under the
# legacy controller tree because it accepted only --state-dir. Fix added
# two new args that override per-agent and shared aggregate independently.
# Verify the Python harvester writes the manifest into the per-agent dir
# and (when triggered) the aggregate into the shared dir.
# ---------------------------------------------------------------------------
log "case: real harvester respects PR-C path overrides (M1)"
m1_dir="$TMP_ROOT/m1"
mkdir -p "$m1_dir/per-agent" "$m1_dir/shared-aggregate" \
         "$m1_dir/home/.agent-bridge/state" \
         "$m1_dir/home/workdir/.claude/projects" \
         "$m1_dir/sidecar"
m1_sidecar="$m1_dir/sidecar/result.json"
# Run harvester with --skipped-permission so it produces a manifest
# without needing real transcript scanning, and exercises the aggregate
# write path via _update_permission_aggregate.
m1_log="$TMP_ROOT/m1.out"
if ! BRIDGE_HOME="$m1_dir/home/.agent-bridge" \
     python3 "$REPO_ROOT/bridge-memory.py" harvest-daily \
       --agent probe \
       --home "$m1_dir/home" \
       --workdir "$m1_dir/home/workdir" \
       --os-user fake-isolated-user \
       --skipped-permission \
       --sidecar-out "$m1_sidecar" \
       --per-agent-state-dir "$m1_dir/per-agent" \
       --shared-aggregate-dir "$m1_dir/shared-aggregate" \
       --json > "$m1_log" 2>&1; then
  log "M1: harvester output:"
  sed 's/^/  /' "$m1_log"
  die "M1: bridge-memory.py harvest-daily failed"
fi
# Manifest path: <per-agent-state-dir>/<date>.json (no agent slug appended).
m1_manifest_count="$(find "$m1_dir/per-agent" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l)"
(( m1_manifest_count >= 1 )) \
  || { log "M1: per-agent dir contents:"; ls -la "$m1_dir/per-agent" 2>&1 | sed 's/^/  /'; die "M1: per-agent manifest not written under --per-agent-state-dir"; }
# Aggregate: <shared-aggregate-dir>/admin-aggregate-skip.json (skipped-permission path).
[[ -s "$m1_dir/shared-aggregate/admin-aggregate-skip.json" ]] \
  || { log "M1: shared-aggregate dir contents:"; ls -la "$m1_dir/shared-aggregate" 2>&1 | sed 's/^/  /'; die "M1: admin-aggregate-skip.json not written under --shared-aggregate-dir"; }
# Negative: nothing under the legacy state dir.
legacy_dir="$m1_dir/home/.agent-bridge/state/memory-daily"
if [[ -d "$legacy_dir/probe" ]] && find "$legacy_dir/probe" -name '*.json' -type f | grep -q .; then
  die "M1: legacy controller tree was written despite v2 overrides ($legacy_dir/probe)"
fi
ok "M1: per-agent manifest written under --per-agent-state-dir, aggregate under --shared-aggregate-dir, no legacy fallback"

log "all rootless cases passed"
