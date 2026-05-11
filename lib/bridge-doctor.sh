#!/usr/bin/env bash
# lib/bridge-doctor.sh — `agent doctor` CRUD self-check (issue #619).
#
# Implements a 7-step CRUD self-check that:
#
#  1. Creates a unique fixture agent under the pinned home root
#     ($BRIDGE_HOME/agents/<fixture-id>).
#  2. Exercises update/registry/show/reclassify/retire/delete in turn.
#  3. Asserts step 7 with both `delete rc=0` AND `path-not-on-disk`
#     (the assertion PR #615 missed and that issue #619 codifies).
#  4. Cleans up the fixture via a pinned-path `rm -rf -- "${root:?}/${id:?}"`
#     final safety net even if the canonical delete refuses or partially
#     fails. The doctor never loosens production delete semantics — it
#     records denials and then runs its own pinned cleanup.
#
# Design constraints (issue #619 spec, sections 1-7):
#   - One mandatory child-invocation wrapper (bridge_doctor_invoke_agent)
#     scopes BRIDGE_AGENT_HOME_ROOT in a subshell per child. The parent
#     shell never `export`s it for the whole doctor process.
#   - The cleanup trap tolerates only the closed already-gone subset of
#     production denials; every other denial records cleanup failure.
#   - Pinned-path safety net uses `rm -rf -- "${root:?}/${id:?}"` and
#     verifies the path is gone afterwards; fatal cleanup failure exits 99.
#   - Admin caller validation runs before any fixture creation and reuses
#     bridge_agent_update_caller_{agent,source,is_admin} from
#     lib/bridge-agent-update.sh.
#   - Step 7 forbids n/a — missing delete is a fail, not a skip.
#   - Out of scope: production `agent delete --purge-home` semantics
#     changes, channel/MCP/cron/queue interaction, auto-fix logic.

# shellcheck shell=bash

# ----------------------------------------------------------------------
# Section 2: closed denial enumeration.
#
# DOCTOR_KNOWN_DENIAL_PATTERNS captures the production denial / error
# strings the doctor's child invocations may emit. Glob entries (`*`)
# are converted to anchored regex via bridge_doctor_glob_to_regex.
#
# DOCTOR_ALREADY_GONE_PATTERNS is the strict subset the cleanup trap
# tolerates as "roster/disk already cleaned". Every other denial
# records a cleanup failure even if the pinned-path rm later succeeds.
# ----------------------------------------------------------------------

# shellcheck disable=SC2034 # exposed for review/grep — not all strings
# are matched at runtime (some are documentary), but the array MUST
# stay in sync with bridge-agent.sh's denial surface.
DOCTOR_KNOWN_DENIAL_PATTERNS=(
  # delete-side already-gone (roster removed):
  "deny: agent '*' is not present in the local roster — nothing to delete"
  # show/update/reclassify/require_agent already-gone (roster removed):
  "'*'은(는) 등록된 에이전트가 아닙니다."
  # retire already-gone (no registry entry, no home dir):
  "deny: agent '*' is not in the registry and no home dir exists at *"

  # create:
  "Usage: * create <agent> [...]"
  "에이전트 이름이 CLI 플래그처럼 보입니다: '*'. 도움말을 보려면 '* create --help' 를 실행하세요."
  "에이전트 이름은 영문/숫자/._- 만 사용할 수 있고 영문/숫자로 시작해야 하며 'help'/'version' 은 예약어입니다: *"
  "이미 등록된 에이전트입니다: *"
  "옵션 값이 필요합니다: *"
  "지원하지 않는 agent create 옵션입니다: *"
  "지원하지 않는 engine 입니다: *"
  "지원하지 않는 session type 입니다: *"
  "지원하지 않는 isolation mode 입니다: *"
  "--os-user 는 --isolation linux-user 와 함께만 사용할 수 있습니다."
  "linux-user isolation에서는 workdir를 다른 에이전트와 공유할 수 없습니다: * -> *"
  "workdir가 이미 존재하고 비어 있지 않습니다: *"
  "agent template root가 없습니다: *"
  "session type template가 없습니다: *"

  # update:
  "Usage: * update <agent> [...]"
  "--launch-cmd-add-env 는 KEY=VALUE 형식이어야 합니다 (KEY matches ^[A-Za-z_][A-Za-z0-9_]*$): *"
  "--launch-cmd-add-env 값에 줄바꿈이 포함될 수 없습니다: *"
  "--launch-cmd-remove-env 는 KEY 형식이어야 합니다 (^[A-Za-z_][A-Za-z0-9_]*$): *"
  "--launch-cmd-add-dev-channel 는 plugin:NAME@SPEC 형식이어야 합니다: *"
  "--launch-cmd-remove-dev-channel 는 plugin:NAME@SPEC 형식이어야 합니다: *"
  "--channels-add 는 plugin:NAME@SPEC 형식이어야 합니다: *"
  "--channels-remove 는 plugin:NAME@SPEC 형식이어야 합니다: *"
  "지원하지 않는 agent update 옵션입니다: *"
  "--set-launch-cmd 는 다른 launch-cmd 변경 플래그와 함께 사용할 수 없습니다."
  "--channels-set 는 다른 channels 변경 플래그와 함께 사용할 수 없습니다."
  "agent update 변경 플래그가 하나 이상 필요합니다."

  # caller-trust deny (update / delete share these):
  "deny: caller_agent unspecified — pass --from <admin-agent> or set BRIDGE_AGENT_ID before invoking 'agent-bridge agent update'"
  "deny: caller agent * is not the admin agent — refusing managed-role mutation"
  "deny: caller source * is not allowed to mutate system config (need operator-tui or operator-trusted-id)"

  # list / registry / show / reclassify:
  "지원하지 않는 agent list 옵션입니다: *"
  "Usage: * show <agent> [--json]"
  "지원하지 않는 agent show 옵션입니다: *"
  "--agent 뒤에 값을 지정하세요."
  "지원하지 않는 agent reclassify 옵션입니다: *"
  "Usage: * registry [--json]"
  "지원하지 않는 agent registry 옵션입니다: *"

  # retire:
  "deny: agent '*' is static-roster — use *agent delete*"
  "deny: agent '*' has privilege_class=system — system agents are not retireable"
  "deny: agent '*' has an active tmux session — run *agent stop*"
  "deny: agent retire refused — resolved home is outside expected agent roots: *"
  "지원하지 않는 agent retire 옵션입니다: *"

  # delete:
  "Usage: * delete --agent <agent> [--purge-home] [--yes] [--json]"
  "agent delete: <name> 인자가 필요합니다."
  "agent '*' has $* open inbox task(s) — pass --orphan-tasks to mark them blocked"
  "cannot delete the configured admin agent (*) from itself — clear BRIDGE_ADMIN_AGENT_ID first"
  "agent '*' has an active session — stop it first or pass --force"
  "지원하지 않는 agent delete 옵션입니다: *"

  # top-level dispatcher:
  "지원하지 않는 agent 명령입니다: *"
)

# Strict already-gone subset — the only denials the cleanup trap may
# tolerate. Every other DOCTOR_KNOWN_DENIAL_PATTERNS match in cleanup
# stderr records a cleanup failure (and the pinned-path safety net
# still fires for the filesystem side).
DOCTOR_ALREADY_GONE_PATTERNS=(
  "deny: agent '*' is not present in the local roster — nothing to delete"
  "'*'은(는) 등록된 에이전트가 아닙니다."
  "deny: agent '*' is not in the registry and no home dir exists at *"
)

# ----------------------------------------------------------------------
# Section 1: child-invocation wrapper + log management.
# ----------------------------------------------------------------------

# Convert one DOCTOR_*_PATTERNS glob entry to an anchored extended
# regex. Globs use `*` for "any chars"; regex escapes everything else.
bridge_doctor_glob_to_regex() {
  local glob="$1"
  local out="" ch
  local i
  local backslash
  backslash=$'\\'
  for ((i = 0; i < ${#glob}; i++)); do
    ch="${glob:$i:1}"
    case "$ch" in
      '*') out+='.*' ;;
      '.'|'+'|'?'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|'|'/')
        out+="\\${ch}"
        ;;
      "$backslash")
        out+="${backslash}${backslash}"
        ;;
      *) out+="$ch" ;;
    esac
  done
  printf '%s' "$out"
}

# Strip ANSI color sequences and any leading [오류] / [error] /
# [warn] prefixes bridge_die / bridge_warn add. Callers feed normalized
# stderr into the matcher.
bridge_doctor_normalize_stderr() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  # Strip CSI escape sequences and the bridge_die/bridge_warn prefixes.
  # bridge-core.sh wraps `bridge_die` output with RED + "[오류] " + msg + NC,
  # and `bridge_warn` with YELLOW + "[경고] " + msg + NC.
  sed -E \
    -e 's/\x1B\[[0-9;]*[a-zA-Z]//g' \
    -e 's/^\[오류\] //' \
    -e 's/^\[경고\] //' \
    -e 's/^\[error\] //' \
    -e 's/^\[warn\] //' \
    "$path"
}

# Match normalized stderr against an array name (passed by name).
# Returns 0 on first match, 1 if no pattern matches.
bridge_doctor_log_matches_any() {
  local stderr_log="$1"
  local array_name="$2"
  local normalized
  normalized="$(bridge_doctor_normalize_stderr "$stderr_log" 2>/dev/null || true)"
  [[ -n "$normalized" ]] || return 1
  local -n patterns_ref="$array_name"
  local glob regex
  for glob in "${patterns_ref[@]}"; do
    regex="$(bridge_doctor_glob_to_regex "$glob")"
    if printf '%s' "$normalized" | grep -Eq -- "$regex"; then
      return 0
    fi
  done
  return 1
}

bridge_doctor_known_denial_match() {
  bridge_doctor_log_matches_any "$1" DOCTOR_KNOWN_DENIAL_PATTERNS
}

bridge_doctor_log_matches_already_gone() {
  bridge_doctor_log_matches_any "$1" DOCTOR_ALREADY_GONE_PATTERNS
}

# Allocate the next stdout/stderr log pair for a given verb.
# Side-effects: writes paths into the variables named by argv[2] / argv[3].
bridge_doctor_next_log_pair() {
  local verb="$1"
  local stdout_var="$2"
  local stderr_var="$3"
  : "${BRIDGE_DOCTOR_LOG_DIR:?bridge_doctor_next_log_pair: BRIDGE_DOCTOR_LOG_DIR unset}"
  : "${BRIDGE_DOCTOR_CALL_INDEX:=0}"
  BRIDGE_DOCTOR_CALL_INDEX=$((BRIDGE_DOCTOR_CALL_INDEX + 1))
  local idx
  idx="$(printf '%03d' "$BRIDGE_DOCTOR_CALL_INDEX")"
  printf -v "$stdout_var" '%s/%s.%s.stdout.log' "$BRIDGE_DOCTOR_LOG_DIR" "$idx" "$verb"
  printf -v "$stderr_var" '%s/%s.%s.stderr.log' "$BRIDGE_DOCTOR_LOG_DIR" "$idx" "$verb"
}

# bridge_doctor_invoke_agent <fixture_home_root> <verb> [args...]
#
# Executes `bridge-agent.sh <verb> args...` with BRIDGE_AGENT_HOME_ROOT
# scoped to fixture_home_root in a subshell. Captures stdout / stderr
# to per-call log files. Records the child rc and log paths in
# BRIDGE_DOCTOR_LAST_*. Never converts a non-zero rc to zero.
bridge_doctor_invoke_agent() {
  local fixture_home_root="$1"
  shift
  local verb="$1"
  shift
  [[ -n "$fixture_home_root" ]] || { printf 'doctor wrapper: missing fixture_home_root\n' >&2; return 127; }
  [[ -n "$verb" ]] || { printf 'doctor wrapper: missing verb\n' >&2; return 127; }

  local stdout_log stderr_log
  bridge_doctor_next_log_pair "$verb" stdout_log stderr_log

  local agent_script="$SCRIPT_DIR/bridge-agent.sh"
  if [[ ! -r "$agent_script" || ! -f "$agent_script" ]]; then
    printf 'doctor wrapper: bridge-agent.sh not executable/readable: %s\n' "$agent_script" >"$stderr_log"
    BRIDGE_DOCTOR_LAST_STDOUT_LOG="$stdout_log"
    BRIDGE_DOCTOR_LAST_STDERR_LOG="$stderr_log"
    BRIDGE_DOCTOR_LAST_RC=127
    return 127
  fi

  # Subshell isolation — BRIDGE_AGENT_HOME_ROOT is exported only here.
  # shellcheck disable=SC2030 # subshell-scoped export is the design.
  #
  # Issue #670 — also pin BRIDGE_CODEX_HOOKS_FILE into the isolated
  # BRIDGE_HOME for the duration of every child invocation. Without
  # this, the doctor's `create --engine codex` step downstream-runs
  # `bridge-start.sh --dry-run`, which calls `bridge_ensure_codex_hooks`.
  # That helper resolves to `$HOME/.codex/hooks.json` by default and
  # writes PreToolUse + Stop entries whose `command` strings reference
  # `$BRIDGE_HOME/hooks/codex-task-mode-policy.py` and
  # `$BRIDGE_HOME/hooks/codex-review-output-shape.py`. When the
  # doctor's temp BRIDGE_HOME is cleaned up, those entries become
  # stale references in the operator's real `~/.codex/hooks.json`,
  # permanently breaking every codex session on the host (PreToolUse
  # blocks every command with `python3: can't open file ...`).
  #
  # Pinning BRIDGE_CODEX_HOOKS_FILE to a path inside the isolated
  # BRIDGE_HOME redirects the writes to a hooks.json that dies with
  # the temp dir on doctor exit. The operator's hooks.json is never
  # touched. Guarded by [[ -n "${BRIDGE_HOME:-}" ]] (validated up in
  # bridge_doctor_run) so the export is always safe here.
  local rc=0
  (
    export BRIDGE_AGENT_HOME_ROOT="$fixture_home_root"
    if [[ -n "${BRIDGE_HOME:-}" ]]; then
      export BRIDGE_CODEX_HOOKS_FILE="$BRIDGE_HOME/.codex/hooks.json"
    fi
    exec "${BRIDGE_BASH_BIN:-bash}" "$agent_script" "$verb" "$@"
  ) >"$stdout_log" 2>"$stderr_log" || rc=$?

  BRIDGE_DOCTOR_LAST_STDOUT_LOG="$stdout_log"
  BRIDGE_DOCTOR_LAST_STDERR_LOG="$stderr_log"
  BRIDGE_DOCTOR_LAST_RC="$rc"
  # Doctor must continue past step failures so every CRUD verb is
  # exercised. The wrapper records rc but always returns 0; the
  # caller (bridge_doctor_step) inspects BRIDGE_DOCTOR_LAST_RC.
  return 0
}

# ----------------------------------------------------------------------
# Section 3: pinned-path final safety net.
# ----------------------------------------------------------------------

# Refuse if the resolved fixture path escapes the pinned root (defense
# against resolver bugs). Otherwise rm -rf with :? guards on both
# components, then verify the path is gone. Returns 0 on success; on
# failure prints to stderr and returns 1.
bridge_doctor_pinned_safety_rm() {
  local fixture_home_root="$1"
  local fixture_id="$2"
  [[ -n "$fixture_home_root" && -n "$fixture_id" ]] || {
    printf 'doctor pinned-rm: missing fixture_home_root or fixture_id\n' >&2
    return 1
  }
  local fixture_path="$fixture_home_root/$fixture_id"
  case "$fixture_path" in
    "$fixture_home_root"/*) ;;
    *)
      printf 'doctor internal: fixture path escaped pinned root: %s\n' "$fixture_path" >&2
      return 1
      ;;
  esac
  rm -rf -- "${fixture_home_root:?}/${fixture_id:?}"
  if [[ -e "$fixture_path" ]]; then
    printf 'doctor cleanup failed: fixture path still exists after rm -rf: %s\n' "$fixture_path" >&2
    return 1
  fi
  return 0
}

# ----------------------------------------------------------------------
# Section 4: admin caller validation.
# ----------------------------------------------------------------------

bridge_doctor_validate_admin_caller() {
  local caller_agent="$1"
  local caller_source="$2"
  if [[ -z "$caller_agent" ]]; then
    bridge_die "deny: caller_agent unspecified — pass --from <admin-agent> or set BRIDGE_AGENT_ID before invoking 'agent-bridge agent doctor'"
  fi
  if ! bridge_agent_update_caller_is_admin "$caller_agent"; then
    bridge_die "deny: caller agent $caller_agent is not the admin agent — refusing agent doctor mutation"
  fi
  if [[ "$caller_source" != "operator-tui" && "$caller_source" != "operator-trusted-id" ]]; then
    bridge_die "deny: caller source $caller_source is not allowed to run agent doctor (need operator-tui or operator-trusted-id)"
  fi
  return 0
}

# ----------------------------------------------------------------------
# Section 7 + 8: portable lock for concurrent doctor refusal.
# ----------------------------------------------------------------------

# mkdir-based lock — atomic on macOS and Linux. The pid file inside
# the lock dir lets a future doctor detect a stale lock owner.
bridge_doctor_acquire_lock() {
  local lock_dir="$1"
  local run_id="$2"
  mkdir -p "$(dirname "$lock_dir")"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    local owner=""
    if [[ -f "$lock_dir/owner.pid" ]]; then
      owner="$(cat "$lock_dir/owner.pid" 2>/dev/null || true)"
    fi
    bridge_die "agent doctor refused: lock present at $lock_dir${owner:+ (owner pid=$owner)}"
  fi
  printf '%s' "$$" >"$lock_dir/owner.pid"
  printf '%s' "$run_id" >"$lock_dir/run-id"
  BRIDGE_DOCTOR_LOCK_DIR="$lock_dir"
}

bridge_doctor_release_lock() {
  local lock_dir="${BRIDGE_DOCTOR_LOCK_DIR:-}"
  [[ -n "$lock_dir" && -d "$lock_dir" ]] || return 0
  rm -f "$lock_dir/owner.pid" "$lock_dir/run-id" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
  BRIDGE_DOCTOR_LOCK_DIR=""
}

# ----------------------------------------------------------------------
# Section 6 + 7: result accumulation, JSON envelope, cleanup trap.
# ----------------------------------------------------------------------

# State globals (flat arrays indexed 1..7, plus status counters).
# Initialized fresh in bridge_doctor_run before each invocation.
bridge_doctor_init_state() {
  BRIDGE_DOCTOR_STEP_LABEL=("" "" "" "" "" "" "" "")
  BRIDGE_DOCTOR_STEP_VERB=("" "" "" "" "" "" "" "")
  BRIDGE_DOCTOR_STEP_STATUS=("" "" "" "" "" "" "" "")
  BRIDGE_DOCTOR_STEP_REASON=("" "" "" "" "" "" "" "")
  BRIDGE_DOCTOR_STEP_RC=("" "" "" "" "" "" "" "")
  BRIDGE_DOCTOR_STEP_STDOUT_LOG=("" "" "" "" "" "" "" "")
  BRIDGE_DOCTOR_STEP_STDERR_LOG=("" "" "" "" "" "" "" "")
  BRIDGE_DOCTOR_OVERALL_EXIT=0
  BRIDGE_DOCTOR_CALL_INDEX=0
  BRIDGE_DOCTOR_CLEANUP_KNOWN_DENIAL=0
  BRIDGE_DOCTOR_CLEANUP_PINNED_RM=0
  BRIDGE_DOCTOR_CLEANUP_FINAL_PATH_EXISTS=0
  BRIDGE_DOCTOR_CLEANUP_STATUS="pass"
  BRIDGE_DOCTOR_CLEANUP_CHILD_RC=0
}

bridge_doctor_set_step() {
  local n="$1" status="$2" reason="$3"
  BRIDGE_DOCTOR_STEP_STATUS[n]="$status"
  BRIDGE_DOCTOR_STEP_REASON[n]="$reason"
  # OVERALL_EXIT is recomputed from the final step matrix in
  # bridge_doctor_recompute_overall_exit (called before emit). Setting
  # it here on every fail would double-count steps that are later
  # demoted to n/a (e.g., retire's static-roster denial).
}

# Re-derive OVERALL_EXIT from the post-test step matrix. Called once
# right before bridge_doctor_emit_results so demote-to-n/a transitions
# (e.g., retire step 6) don't leave a stale 1.
bridge_doctor_recompute_overall_exit() {
  local i
  BRIDGE_DOCTOR_OVERALL_EXIT=0
  for ((i = 1; i <= 7; i++)); do
    if [[ "${BRIDGE_DOCTOR_STEP_STATUS[i]:-}" == "fail" ]]; then
      BRIDGE_DOCTOR_OVERALL_EXIT=1
      return 0
    fi
  done
  return 0
}

bridge_doctor_pass_step() { bridge_doctor_set_step "$1" "pass" "$2"; }
bridge_doctor_fail_step() { bridge_doctor_set_step "$1" "fail" "$2"; }
bridge_doctor_na_step()   { bridge_doctor_set_step "$1" "n/a"  "$2"; }

# bridge_doctor_step <n> <verb_label> <verb> [args...]
#
# Run one CRUD step via bridge_doctor_invoke_agent. Records the rc and
# log paths under BRIDGE_DOCTOR_STEP_*. Sets a default fail reason if
# rc is non-zero; the caller may override status / reason after this
# returns to add JSON / disk-side assertions.
bridge_doctor_step() {
  local n="$1"
  local verb_label="$2"
  shift 2
  BRIDGE_DOCTOR_STEP_LABEL[n]="$verb_label"
  BRIDGE_DOCTOR_STEP_VERB[n]="$1"
  bridge_doctor_invoke_agent "$BRIDGE_DOCTOR_FIXTURE_HOME_ROOT" "$@"
  local rc="${BRIDGE_DOCTOR_LAST_RC:-0}"
  BRIDGE_DOCTOR_STEP_RC[n]="$rc"
  BRIDGE_DOCTOR_STEP_STDOUT_LOG[n]="$BRIDGE_DOCTOR_LAST_STDOUT_LOG"
  BRIDGE_DOCTOR_STEP_STDERR_LOG[n]="$BRIDGE_DOCTOR_LAST_STDERR_LOG"
  if [[ "$rc" != "0" ]]; then
    bridge_doctor_fail_step "$n" "$verb_label returned rc=$rc"
  fi
  return 0
}

# Validate that stdout for step N is a JSON object with expected fields.
bridge_doctor_assert_step_json_object() {
  local n="$1"
  local context="$2"
  local stdout_log="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[$n]:-}"
  [[ -f "$stdout_log" ]] || {
    bridge_doctor_fail_step "$n" "$context: stdout log missing"
    return 1
  }
  bridge_require_python
  if ! python3 - "$stdout_log" <<'PY' >/dev/null 2>&1
import json, sys
data = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert isinstance(data, dict), "not a JSON object"
PY
  then
    bridge_doctor_fail_step "$n" "$context: stdout is not a JSON object"
    return 1
  fi
  return 0
}

# Read a single field from step N's stdout JSON. Echoes the value or
# empty on miss. Caller decides how to treat absence.
bridge_doctor_step_json_field() {
  local n="$1"
  local field="$2"
  local stdout_log="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[$n]:-}"
  [[ -f "$stdout_log" ]] || return 0
  bridge_require_python
  python3 - "$stdout_log" "$field" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.loads(open(sys.argv[1], encoding="utf-8").read())
except Exception:
    sys.exit(0)
field = sys.argv[2]
val = data
for part in field.split("."):
    if isinstance(val, dict) and part in val:
        val = val[part]
    else:
        sys.exit(0)
if isinstance(val, (str, int, float, bool)):
    print(val)
PY
}

# Emit the JSON envelope (Section 6 schema).
bridge_doctor_emit_results() {
  local json_mode="$1"
  local pass_count=0 fail_count=0 na_count=0 i
  for ((i = 1; i <= 7; i++)); do
    case "${BRIDGE_DOCTOR_STEP_STATUS[$i]:-}" in
      pass) pass_count=$((pass_count + 1)) ;;
      fail) fail_count=$((fail_count + 1)) ;;
      n/a)  na_count=$((na_count + 1)) ;;
    esac
  done

  if [[ $json_mode -eq 1 ]]; then
    bridge_require_python
    DOCTOR_RUN_ID="$BRIDGE_DOCTOR_RUN_ID" \
    DOCTOR_FIXTURE_ID="$BRIDGE_DOCTOR_FIXTURE_ID" \
    DOCTOR_FIXTURE_HOME_ROOT="$BRIDGE_DOCTOR_FIXTURE_HOME_ROOT" \
    DOCTOR_FIXTURE_HOME_PATH="${BRIDGE_DOCTOR_FIXTURE_HOME_PATH:-}" \
    DOCTOR_CALLER_AGENT="$BRIDGE_DOCTOR_CALLER_AGENT" \
    DOCTOR_CALLER_SOURCE="$BRIDGE_DOCTOR_CALLER_SOURCE" \
    DOCTOR_CLEANUP_CHILD_RC="$BRIDGE_DOCTOR_CLEANUP_CHILD_RC" \
    DOCTOR_CLEANUP_KNOWN_DENIAL="$BRIDGE_DOCTOR_CLEANUP_KNOWN_DENIAL" \
    DOCTOR_CLEANUP_PINNED_RM="$BRIDGE_DOCTOR_CLEANUP_PINNED_RM" \
    DOCTOR_CLEANUP_FINAL_PATH_EXISTS="$BRIDGE_DOCTOR_CLEANUP_FINAL_PATH_EXISTS" \
    DOCTOR_CLEANUP_STATUS="$BRIDGE_DOCTOR_CLEANUP_STATUS" \
    DOCTOR_OVERALL_EXIT="$BRIDGE_DOCTOR_OVERALL_EXIT" \
    DOCTOR_PASS="$pass_count" DOCTOR_FAIL="$fail_count" DOCTOR_NA="$na_count" \
    DOCTOR_STEP_LABEL_1="${BRIDGE_DOCTOR_STEP_LABEL[1]:-}" \
    DOCTOR_STEP_LABEL_2="${BRIDGE_DOCTOR_STEP_LABEL[2]:-}" \
    DOCTOR_STEP_LABEL_3="${BRIDGE_DOCTOR_STEP_LABEL[3]:-}" \
    DOCTOR_STEP_LABEL_4="${BRIDGE_DOCTOR_STEP_LABEL[4]:-}" \
    DOCTOR_STEP_LABEL_5="${BRIDGE_DOCTOR_STEP_LABEL[5]:-}" \
    DOCTOR_STEP_LABEL_6="${BRIDGE_DOCTOR_STEP_LABEL[6]:-}" \
    DOCTOR_STEP_LABEL_7="${BRIDGE_DOCTOR_STEP_LABEL[7]:-}" \
    DOCTOR_STEP_VERB_1="${BRIDGE_DOCTOR_STEP_VERB[1]:-}" \
    DOCTOR_STEP_VERB_2="${BRIDGE_DOCTOR_STEP_VERB[2]:-}" \
    DOCTOR_STEP_VERB_3="${BRIDGE_DOCTOR_STEP_VERB[3]:-}" \
    DOCTOR_STEP_VERB_4="${BRIDGE_DOCTOR_STEP_VERB[4]:-}" \
    DOCTOR_STEP_VERB_5="${BRIDGE_DOCTOR_STEP_VERB[5]:-}" \
    DOCTOR_STEP_VERB_6="${BRIDGE_DOCTOR_STEP_VERB[6]:-}" \
    DOCTOR_STEP_VERB_7="${BRIDGE_DOCTOR_STEP_VERB[7]:-}" \
    DOCTOR_STEP_STATUS_1="${BRIDGE_DOCTOR_STEP_STATUS[1]:-}" \
    DOCTOR_STEP_STATUS_2="${BRIDGE_DOCTOR_STEP_STATUS[2]:-}" \
    DOCTOR_STEP_STATUS_3="${BRIDGE_DOCTOR_STEP_STATUS[3]:-}" \
    DOCTOR_STEP_STATUS_4="${BRIDGE_DOCTOR_STEP_STATUS[4]:-}" \
    DOCTOR_STEP_STATUS_5="${BRIDGE_DOCTOR_STEP_STATUS[5]:-}" \
    DOCTOR_STEP_STATUS_6="${BRIDGE_DOCTOR_STEP_STATUS[6]:-}" \
    DOCTOR_STEP_STATUS_7="${BRIDGE_DOCTOR_STEP_STATUS[7]:-}" \
    DOCTOR_STEP_REASON_1="${BRIDGE_DOCTOR_STEP_REASON[1]:-}" \
    DOCTOR_STEP_REASON_2="${BRIDGE_DOCTOR_STEP_REASON[2]:-}" \
    DOCTOR_STEP_REASON_3="${BRIDGE_DOCTOR_STEP_REASON[3]:-}" \
    DOCTOR_STEP_REASON_4="${BRIDGE_DOCTOR_STEP_REASON[4]:-}" \
    DOCTOR_STEP_REASON_5="${BRIDGE_DOCTOR_STEP_REASON[5]:-}" \
    DOCTOR_STEP_REASON_6="${BRIDGE_DOCTOR_STEP_REASON[6]:-}" \
    DOCTOR_STEP_REASON_7="${BRIDGE_DOCTOR_STEP_REASON[7]:-}" \
    DOCTOR_STEP_RC_1="${BRIDGE_DOCTOR_STEP_RC[1]:-}" \
    DOCTOR_STEP_RC_2="${BRIDGE_DOCTOR_STEP_RC[2]:-}" \
    DOCTOR_STEP_RC_3="${BRIDGE_DOCTOR_STEP_RC[3]:-}" \
    DOCTOR_STEP_RC_4="${BRIDGE_DOCTOR_STEP_RC[4]:-}" \
    DOCTOR_STEP_RC_5="${BRIDGE_DOCTOR_STEP_RC[5]:-}" \
    DOCTOR_STEP_RC_6="${BRIDGE_DOCTOR_STEP_RC[6]:-}" \
    DOCTOR_STEP_RC_7="${BRIDGE_DOCTOR_STEP_RC[7]:-}" \
    DOCTOR_STEP_STDOUT_1="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[1]:-}" \
    DOCTOR_STEP_STDOUT_2="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[2]:-}" \
    DOCTOR_STEP_STDOUT_3="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[3]:-}" \
    DOCTOR_STEP_STDOUT_4="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[4]:-}" \
    DOCTOR_STEP_STDOUT_5="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[5]:-}" \
    DOCTOR_STEP_STDOUT_6="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[6]:-}" \
    DOCTOR_STEP_STDOUT_7="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[7]:-}" \
    DOCTOR_STEP_STDERR_1="${BRIDGE_DOCTOR_STEP_STDERR_LOG[1]:-}" \
    DOCTOR_STEP_STDERR_2="${BRIDGE_DOCTOR_STEP_STDERR_LOG[2]:-}" \
    DOCTOR_STEP_STDERR_3="${BRIDGE_DOCTOR_STEP_STDERR_LOG[3]:-}" \
    DOCTOR_STEP_STDERR_4="${BRIDGE_DOCTOR_STEP_STDERR_LOG[4]:-}" \
    DOCTOR_STEP_STDERR_5="${BRIDGE_DOCTOR_STEP_STDERR_LOG[5]:-}" \
    DOCTOR_STEP_STDERR_6="${BRIDGE_DOCTOR_STEP_STDERR_LOG[6]:-}" \
    DOCTOR_STEP_STDERR_7="${BRIDGE_DOCTOR_STEP_STDERR_LOG[7]:-}" \
    python3 - <<'PY'
import json, os

def env(k):
    return os.environ.get(k, "")

def env_int(k):
    try:
        return int(os.environ.get(k, "0") or 0)
    except Exception:
        return 0

steps = []
for i in range(1, 8):
    rc_raw = env(f"DOCTOR_STEP_RC_{i}")
    try:
        rc_val = int(rc_raw) if rc_raw != "" else None
    except Exception:
        rc_val = None
    steps.append({
        "step": i,
        "label": env(f"DOCTOR_STEP_LABEL_{i}"),
        "verb": env(f"DOCTOR_STEP_VERB_{i}"),
        "status": env(f"DOCTOR_STEP_STATUS_{i}"),
        "reason": env(f"DOCTOR_STEP_REASON_{i}"),
        "rc": rc_val,
        "stdout_log": env(f"DOCTOR_STEP_STDOUT_{i}") or None,
        "stderr_log": env(f"DOCTOR_STEP_STDERR_{i}") or None,
    })

payload = {
    "doctor_run_id": env("DOCTOR_RUN_ID"),
    "fixture_id": env("DOCTOR_FIXTURE_ID"),
    "fixture_home_root": env("DOCTOR_FIXTURE_HOME_ROOT"),
    "fixture_home_path": env("DOCTOR_FIXTURE_HOME_PATH") or env("DOCTOR_FIXTURE_HOME_ROOT") + "/" + env("DOCTOR_FIXTURE_ID"),
    "admin_validation": {
        "caller_agent": env("DOCTOR_CALLER_AGENT"),
        "caller_source": env("DOCTOR_CALLER_SOURCE"),
        "status": "pass",
    },
    "steps": steps,
    "cleanup": {
        "child_delete_rc": env_int("DOCTOR_CLEANUP_CHILD_RC"),
        "known_denial_matched": env("DOCTOR_CLEANUP_KNOWN_DENIAL") == "1",
        "pinned_rm_fired": env("DOCTOR_CLEANUP_PINNED_RM") == "1",
        "final_path_exists": env("DOCTOR_CLEANUP_FINAL_PATH_EXISTS") == "1",
        "status": env("DOCTOR_CLEANUP_STATUS") or "pass",
    },
    "summary": {
        "pass": env_int("DOCTOR_PASS"),
        "fail": env_int("DOCTOR_FAIL"),
        "n/a":  env_int("DOCTOR_NA"),
        "overall_exit": env_int("DOCTOR_OVERALL_EXIT"),
    },
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  else
    printf 'agent doctor — run_id=%s fixture=%s\n' \
      "$BRIDGE_DOCTOR_RUN_ID" "$BRIDGE_DOCTOR_FIXTURE_ID"
    printf '  caller=%s source=%s\n' \
      "$BRIDGE_DOCTOR_CALLER_AGENT" "$BRIDGE_DOCTOR_CALLER_SOURCE"
    local i
    for ((i = 1; i <= 7; i++)); do
      printf '  step=%d verb=%s status=%-4s rc=%s reason=%s\n' \
        "$i" "${BRIDGE_DOCTOR_STEP_LABEL[$i]:-}" \
        "${BRIDGE_DOCTOR_STEP_STATUS[$i]:-}" \
        "${BRIDGE_DOCTOR_STEP_RC[$i]:-}" \
        "${BRIDGE_DOCTOR_STEP_REASON[$i]:-}"
    done
    printf '  cleanup status=%s pinned_rm=%s known_denial=%s final_path_exists=%s\n' \
      "$BRIDGE_DOCTOR_CLEANUP_STATUS" \
      "$BRIDGE_DOCTOR_CLEANUP_PINNED_RM" \
      "$BRIDGE_DOCTOR_CLEANUP_KNOWN_DENIAL" \
      "$BRIDGE_DOCTOR_CLEANUP_FINAL_PATH_EXISTS"
    printf 'agent doctor summary: pass=%s fail=%s n/a=%s overall_exit=%s\n' \
      "$pass_count" "$fail_count" "$na_count" "$BRIDGE_DOCTOR_OVERALL_EXIT"
  fi
}

# ----------------------------------------------------------------------
# Section 7: cleanup trap.
# ----------------------------------------------------------------------

bridge_doctor_cleanup() {
  local original_rc=$?
  trap - EXIT INT TERM
  set +e

  if [[ -z "${BRIDGE_DOCTOR_FIXTURE_ID:-}" || -z "${BRIDGE_DOCTOR_FIXTURE_HOME_ROOT:-}" ]]; then
    bridge_doctor_release_lock
    exit "$original_rc"
  fi

  local cleanup_failed=0
  local fixture_home_root="$BRIDGE_DOCTOR_FIXTURE_HOME_ROOT"
  local fixture_id="$BRIDGE_DOCTOR_FIXTURE_ID"
  local fixture_path="${BRIDGE_DOCTOR_FIXTURE_HOME_PATH:-$fixture_home_root/$fixture_id}"

  # Try canonical child delete first. Suppress its rc — we drive the
  # disk verification below regardless. Pass --from + operator-tui hints
  # via the inherited env (the wrapper subshell preserves them).
  bridge_doctor_invoke_agent "$fixture_home_root" delete "$fixture_id" \
    --from "${BRIDGE_DOCTOR_CALLER_AGENT:-}" --purge-home --json
  local del_rc="${BRIDGE_DOCTOR_LAST_RC:-0}"
  BRIDGE_DOCTOR_CLEANUP_CHILD_RC="$del_rc"
  local cleanup_err="$BRIDGE_DOCTOR_LAST_STDERR_LOG"

  if [[ $del_rc -ne 0 ]]; then
    if bridge_doctor_log_matches_already_gone "$cleanup_err"; then
      BRIDGE_DOCTOR_CLEANUP_KNOWN_DENIAL=1
    else
      cleanup_failed=1
      printf 'doctor cleanup: child delete failed unexpectedly rc=%s stderr=%s\n' \
        "$del_rc" "$cleanup_err" >&2
    fi
  fi

  # Filesystem-side safety net — fires whenever the actual home path
  # remains. The pinned-rm helper enforces the :? guards and verifies
  # the path is gone after rm -rf.
  if [[ -e "$fixture_path" ]]; then
    BRIDGE_DOCTOR_CLEANUP_PINNED_RM=1
    # Compute pinned-rm parent + child from the actual fixture_path,
    # not just the home root, so v2's <id>/home suffix is removed.
    local pinned_parent pinned_child
    pinned_parent="$(dirname -- "$fixture_path")"
    pinned_child="$(basename -- "$fixture_path")"
    if ! bridge_doctor_pinned_safety_rm "$pinned_parent" "$pinned_child"; then
      BRIDGE_DOCTOR_CLEANUP_FINAL_PATH_EXISTS=1
      BRIDGE_DOCTOR_CLEANUP_STATUS="fail"
      printf 'FATAL: doctor unable to clean fixture even after rm -rf: %s\n' \
        "$fixture_path" >&2
      bridge_doctor_release_lock
      exit 99
    fi
    # Best-effort prune of the v2 <id>/ wrapper dir if now empty (parent
    # of the home suffix). Failure is non-fatal — leaves a harmless
    # empty dir for next-doctor cleanup.
    if [[ "$pinned_child" == "home" ]]; then
      rmdir "$pinned_parent" 2>/dev/null || true
    fi
  fi

  if [[ $cleanup_failed -eq 1 ]]; then
    BRIDGE_DOCTOR_CLEANUP_STATUS="fail"
  fi

  bridge_doctor_release_lock

  if [[ $original_rc -ne 0 ]]; then
    exit "$original_rc"
  fi
  if [[ $cleanup_failed -eq 1 ]]; then
    exit 1
  fi
  exit 0
}

# ----------------------------------------------------------------------
# Section 9: top-level entry — bridge_doctor_run.
# ----------------------------------------------------------------------

bridge_doctor_run() {
  local json_mode=0
  local from_agent=""
  local doctor_help=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      --from)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        from_agent="$2"
        shift 2
        ;;
      -h|--help) doctor_help=1; shift ;;
      *) bridge_die "지원하지 않는 agent doctor 옵션입니다: $1" ;;
    esac
  done

  if [[ $doctor_help -eq 1 ]]; then
    cat <<'EOF'
Usage: agent-bridge agent doctor [--from <agent>] [--json]

Run a 7-step CRUD self-check (create / update / registry / show /
reclassify / retire / delete) against an isolated fixture under
$BRIDGE_HOME/agents. Validates that `agent delete --purge-home` both
returns rc=0 AND removes the pinned filesystem path. The fixture is
always cleaned up via a pinned-path rm -rf safety net; on cleanup
failure the doctor exits 99 so operators notice the leak.

Caller must be the admin agent (BRIDGE_ADMIN_AGENT_ID) AND from an
operator-trusted source (BRIDGE_CALLER_SOURCE=operator-tui or
operator-trusted-id, or a real TTY on stdin/stdout).

Output: text summary by default; --json emits a structured envelope
with per-step pass/fail/n-a, log paths, cleanup detail, and overall
exit code.
EOF
    return 0
  fi

  [[ -n "${BRIDGE_HOME:-}" && -d "$BRIDGE_HOME" ]] \
    || bridge_die "agent doctor requires existing BRIDGE_HOME: ${BRIDGE_HOME:-<unset>}"

  # Disable errexit for the doctor body — every CRUD verb must run even
  # if an earlier one failed, so the operator sees a complete pass/fail/n-a
  # matrix. Step failures are tracked via BRIDGE_DOCTOR_OVERALL_EXIT.
  set +e

  bridge_doctor_init_state

  # Section 4: admin caller validation BEFORE any side effect.
  local caller_agent caller_source
  caller_agent="$(bridge_agent_update_caller_agent "$from_agent")"
  caller_source="$(bridge_agent_update_caller_source)"
  bridge_doctor_validate_admin_caller "$caller_agent" "$caller_source"

  BRIDGE_DOCTOR_CALLER_AGENT="$caller_agent"
  BRIDGE_DOCTOR_CALLER_SOURCE="$caller_source"

  # Allocate run id, fixture id, log dir.
  local run_id fixture_id fixture_home_root fixture_home_path log_dir lock_dir
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fixture_id="doctor-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  # Doctor pins to $BRIDGE_HOME/agents (legacy/v1) or $BRIDGE_AGENT_ROOT_V2
  # (v2). Never inherits a parent BRIDGE_AGENT_HOME_ROOT override
  # (Section 1, Section 8). The wrapper re-exports BRIDGE_AGENT_HOME_ROOT
  # scoped to a subshell on every invocation.
  #
  # The actual fixture home path mirrors `bridge_agent_default_home`,
  # which is what production `agent delete --purge-home` resolves to:
  #   - v2 active: $BRIDGE_AGENT_ROOT_V2/<id>/home
  #   - legacy:    $BRIDGE_AGENT_HOME_ROOT/<id>
  # Step 7 asserts on this exact path, so the doctor catches the same
  # regression PR #615 missed (delete rc=0 with path still on disk).
  local fixture_workdir=""
  if command -v bridge_isolation_v2_active >/dev/null 2>&1 \
     && bridge_isolation_v2_active \
     && [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
    fixture_home_root="$BRIDGE_AGENT_ROOT_V2"
    fixture_home_path="$BRIDGE_AGENT_ROOT_V2/$fixture_id/home"
    fixture_workdir="$BRIDGE_AGENT_ROOT_V2/$fixture_id/workdir"
  else
    fixture_home_root="$BRIDGE_HOME/agents"
    fixture_home_path="$fixture_home_root/$fixture_id"
  fi
  mkdir -p "$fixture_home_root"
  # v2 layout requires the per-agent workdir to exist before
  # `bridge-start.sh --dry-run` runs (which `agent create` invokes
  # at the tail of run_create). Pre-create it so the doctor doesn't
  # trip a downstream rc=1 on a fixture that otherwise registered
  # successfully. This is identical to what production v2
  # `agent-bridge upgrade --apply` does.
  if [[ -n "$fixture_workdir" ]]; then
    mkdir -p "$fixture_workdir"
  fi
  log_dir="${TMPDIR:-/tmp}/agent-doctor.${run_id}"
  if ! mkdir -p "$log_dir"; then
    bridge_die "agent doctor cannot create log dir: $log_dir"
  fi

  BRIDGE_DOCTOR_RUN_ID="$run_id"
  BRIDGE_DOCTOR_FIXTURE_ID="$fixture_id"
  BRIDGE_DOCTOR_FIXTURE_HOME_ROOT="$fixture_home_root"
  BRIDGE_DOCTOR_FIXTURE_HOME_PATH="$fixture_home_path"
  BRIDGE_DOCTOR_LOG_DIR="$log_dir"

  # Concurrent doctor refusal (Section 8). Lock acquired AFTER admin
  # validation, BEFORE step 1 (Section 4 final paragraph).
  lock_dir="$BRIDGE_HOME/state/agent-doctor.lock"
  bridge_doctor_acquire_lock "$lock_dir" "$run_id"
  trap bridge_doctor_cleanup EXIT INT TERM

  # ----- Step 1: create --json -----
  # Let `agent create` decide the workdir/home placement via its own
  # default resolver (v1: $BRIDGE_AGENT_HOME_ROOT/<id>, v2: under
  # $BRIDGE_AGENT_ROOT_V2/<id>). Step 7 will assert on the same
  # default-home path that `agent delete --purge-home` removes.
  #
  # Pass --test-fixture so installs that have flagged `doctor-` as a
  # test-artifact prefix don't refuse the create. Production refuses
  # test-artifact names without --test-fixture (issue #598 Track 4).
  bridge_doctor_step 1 create create "$fixture_id" --test-fixture \
    --engine codex --session-type static-codex --json
  # Step 1 is "fixture exists in registry AND on disk" — a non-zero rc
  # from create's downstream `bridge-start.sh --dry-run` capture is not
  # a CRUD failure if the fixture itself materialized. We re-check via
  # the registry/show paths in steps 3/4. Here we only require: stdout
  # is a JSON object with agent=fixture_id, AND the home path exists.
  local step1_stdout="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[1]:-}"
  if [[ -f "$step1_stdout" ]] && bridge_require_python 2>/dev/null \
     && python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).read()); assert isinstance(d,dict) and d.get("agent")==sys.argv[2]' \
        "$step1_stdout" "$fixture_id" 2>/dev/null \
     && [[ -e "$fixture_home_path" ]]; then
    bridge_doctor_pass_step 1 "create produced fixture at $fixture_home_path"
  else
    if [[ ! -e "$fixture_home_path" ]]; then
      bridge_doctor_fail_step 1 "create succeeded but fixture home absent: $fixture_home_path"
    else
      bridge_doctor_fail_step 1 "create json malformed or agent != $fixture_id"
    fi
  fi

  # ----- Step 2: update typed flag -----
  if [[ "${BRIDGE_DOCTOR_STEP_STATUS[1]:-}" == "pass" ]]; then
    bridge_doctor_step 2 update update "$fixture_id" \
      --from "$caller_agent" --json \
      --launch-cmd-add-env BRIDGE_DOCTOR_PROBE=1
    if [[ "${BRIDGE_DOCTOR_STEP_STATUS[2]:-}" != "fail" ]]; then
      if bridge_doctor_assert_step_json_object 2 "update"; then
        local changed_field
        changed_field="$(bridge_doctor_step_json_field 2 changed)"
        if [[ "$changed_field" != "True" && "$changed_field" != "true" && "$changed_field" != "1" ]]; then
          bridge_doctor_fail_step 2 "update json changed=$changed_field (expected truthy)"
        else
          bridge_doctor_pass_step 2 "update applied typed flag (changed=$changed_field)"
        fi
      fi
    fi
  else
    bridge_doctor_na_step 2 "skipped: step 1 (create) did not pass"
  fi

  # ----- Step 3: registry --json -----
  bridge_doctor_step 3 registry registry --json
  if [[ "${BRIDGE_DOCTOR_STEP_STATUS[3]:-}" != "fail" ]]; then
    local stdout_log_3="${BRIDGE_DOCTOR_STEP_STDOUT_LOG[3]:-}"
    if [[ -f "$stdout_log_3" ]]; then
      bridge_require_python
      local count
      count="$(python3 - "$stdout_log_3" "$fixture_id" <<'PY' 2>/dev/null || echo 0
import json, sys
try:
    data = json.loads(open(sys.argv[1], encoding="utf-8").read())
except Exception:
    print(0); sys.exit(0)
target = sys.argv[2]
n = 0
if isinstance(data, list):
    for r in data:
        if isinstance(r, dict) and r.get("id") == target:
            n += 1
print(n)
PY
)"
      if [[ "$count" == "1" ]]; then
        bridge_doctor_pass_step 3 "registry contains fixture exactly once"
      else
        bridge_doctor_fail_step 3 "registry contains fixture count=$count (expected 1)"
      fi
    else
      bridge_doctor_fail_step 3 "registry stdout log missing"
    fi
  fi

  # ----- Step 4: show --json -----
  bridge_doctor_step 4 show show "$fixture_id" --json
  if [[ "${BRIDGE_DOCTOR_STEP_STATUS[4]:-}" != "fail" ]]; then
    if bridge_doctor_assert_step_json_object 4 "show"; then
      local show_agent
      show_agent="$(bridge_doctor_step_json_field 4 agent)"
      if [[ "$show_agent" != "$fixture_id" ]]; then
        bridge_doctor_fail_step 4 "show json agent='$show_agent' != fixture='$fixture_id'"
      else
        bridge_doctor_pass_step 4 "show reflects fixture id"
      fi
    fi
  fi

  # ----- Step 5: reclassify --json -----
  # The fixture is created as static; reclassify is for runtime-detected
  # promotion candidates. A static fixture typically yields count=0,
  # which is a valid pass/n-a depending on whether the verb produced
  # well-formed JSON. We treat rc=0 + JSON-shape OK as n/a unless the
  # verb mutated the fixture (count > 0 with apply).
  bridge_doctor_step 5 reclassify reclassify --agent "$fixture_id" --json
  if [[ "${BRIDGE_DOCTOR_STEP_STATUS[5]:-}" != "fail" ]]; then
    if bridge_doctor_assert_step_json_object 5 "reclassify"; then
      local rc_count
      rc_count="$(bridge_doctor_step_json_field 5 count)"
      if [[ -z "$rc_count" || "$rc_count" == "0" ]]; then
        bridge_doctor_na_step 5 "fixture already static; no reclassify candidate"
      else
        bridge_doctor_pass_step 5 "reclassify produced count=$rc_count"
      fi
    fi
  fi

  # ----- Step 6: retire --json -----
  # Retire refuses static-roster agents (production contract). The
  # doctor's fixture is created as a static role. Treat the static-deny
  # path as n/a — production contract is preserved. If retire passes
  # (e.g. because a future product ships dynamic-fixture mode), record
  # pass.
  bridge_doctor_step 6 retire retire "$fixture_id" --json
  case "${BRIDGE_DOCTOR_STEP_STATUS[6]:-}" in
    pass|"") : ;;
    fail)
      local stderr_log_6="${BRIDGE_DOCTOR_STEP_STDERR_LOG[6]:-}"
      local normalized
      normalized="$(bridge_doctor_normalize_stderr "$stderr_log_6" 2>/dev/null || true)"
      if [[ "$normalized" == *"is static-roster"* ]]; then
        bridge_doctor_na_step 6 "retire refused: fixture is static-roster (production contract)"
      fi
      ;;
  esac
  if [[ "${BRIDGE_DOCTOR_STEP_STATUS[6]:-}" == "" ]]; then
    bridge_doctor_pass_step 6 "retire returned rc=0"
  fi

  # ----- Step 7: delete --json (self-asserting) -----
  bridge_doctor_step 7 delete delete "$fixture_id" \
    --from "$caller_agent" --purge-home --json
  local del_rc="${BRIDGE_DOCTOR_STEP_RC[7]:-}"
  if [[ "$del_rc" != "0" ]]; then
    bridge_doctor_fail_step 7 "agent delete returned rc=$del_rc"
  elif [[ -e "$fixture_home_path" ]]; then
    bridge_doctor_fail_step 7 "agent delete returned 0 but path '$fixture_home_path' still exists"
  else
    bridge_doctor_pass_step 7 "agent delete removed pinned fixture path"
  fi

  bridge_doctor_recompute_overall_exit
  bridge_doctor_emit_results "$json_mode"

  # Cleanup trap fires on exit. The trap re-runs delete (harmless if
  # step 7 already removed the fixture) and applies the pinned-path
  # safety net for any path that lingers.
  return "$BRIDGE_DOCTOR_OVERALL_EXIT"
}
