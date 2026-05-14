#!/usr/bin/env bash
# Issue #851: regression coverage for the runtime channel dotenv ACL repair
# helper bridge_isolation_v2_apply_channel_state_dotenv_acl.
#
# Symptom this test pins:
#   After v0.11.0 runtime channel writes (Teams/MS365 plugin writes
#   messages.jsonl / conversations.json), the dotenv ACL mask reverts to
#   the empty triple. The named-user r-- grant then renders as
#   effective:--- and controller reads fail, blocking agent start with
#   auth=unreadable ready=no.
#
# What this fixture asserts:
#   1. The helper restores the mask to r-- and re-effective the named-user
#      grant.
#   2. The helper is a no-op success when no dotenv exists for any provider.
#   3. The helper is roster-aware: a stale named-user grant from an
#      uninstalled / renamed agent is stripped; current roster members keep
#      their grants.
#   4. On a non-Linux host (no setfacl), the helper warns and returns 0.
#
# Cross-platform behavior:
#   - Linux + setfacl + getfacl present: run the full regression matrix.
#   - macOS / no setfacl: only the non-Linux graceful-skip case runs
#     (cases 1-3 are marked SKIP); the test still exits 0 so smoke-test.sh
#     stays green on developer macOS workstations.
#
# Runs in an isolated HOME / BRIDGE_HOME and never touches the live
# runtime. Stubs the sudo dispatcher so the test does not require root.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
SKIP=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s -- %s\n' "$LAST_DESC" "$*" >&2; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP: %s -- %s\n' "$LAST_DESC" "$*"; }

TMP_HOME="$(mktemp -d -t agb-dotenv-mask-test.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export BRIDGE_HOME="$TMP_HOME/.agent-bridge"
mkdir -p "$BRIDGE_HOME"

# ---------------------------------------------------------------------------
# 1. Extract the helper under test + write a self-contained stub harness.
# ---------------------------------------------------------------------------
# We do not source the full bridge-lib because that would require a roster,
# matrix bootstrap, controller user, etc. Pull just the function body and
# wire stubs for its few dependencies. The stub helpers are appended via
# printf rather than a heredoc to avoid the documented bash 5.3 heredoc
# class (footgun #11).

EXTRACT_TMP="$TMP_HOME/extract.sh"
awk '
  /^bridge_isolation_v2_apply_channel_state_dotenv_acl\(\) \{/ {
    copy = 1
  }
  copy { print }
  copy && /^\}$/ { copy = 0; print "" }
' "$ROOT_DIR/lib/bridge-isolation-v2.sh" >"$EXTRACT_TMP"

# Sanity: extraction succeeded.
if ! grep -q '^bridge_isolation_v2_apply_channel_state_dotenv_acl' "$EXTRACT_TMP"; then
  printf '  FAIL: could not extract helper from lib/bridge-isolation-v2.sh\n' >&2
  exit 1
fi

# Append the stub helpers. Use a separate stub file built with printf so we
# never embed multi-line code via heredoc / here-string in this script.
STUB_FILE="$TMP_HOME/stubs.sh"
: >"$STUB_FILE"
{
  printf '%s\n' ''
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' ''
  printf '%s\n' '# Direct-only dispatcher: the test runs as the operator UID. The'
  printf '%s\n' '# real helper falls back to sudo only when direct fails. Collapse'
  printf '%s\n' '# to a direct exec so the test never escalates.'
  printf '%s\n' '_bridge_isolation_v2_run_root_or_sudo() {'
  printf '%s\n' '  "$@"'
  printf '%s\n' '}'
  printf '%s\n' ''
  printf '%s\n' 'bridge_isolation_v2_controller_user() {'
  printf '%s\n' '  printf "%s" "${USER:-${LOGNAME:-tester}}"'
  printf '%s\n' '}'
  printf '%s\n' ''
  printf '%s\n' 'bridge_isolation_v2_reapply_eligible_agents() {'
  printf '%s\n' '  if [[ -n "${STUB_ROSTER:-}" ]]; then'
  printf '%s\n' '    printf "%s\n" "$STUB_ROSTER"'
  printf '%s\n' '  fi'
  printf '%s\n' '}'
  printf '%s\n' ''
  printf '%s\n' 'bridge_channel_state_dir_for_item() {'
  printf '%s\n' '  case "$2" in'
  printf '%s\n' '    plugin:teams)      printf "%s" "${STUB_STATE_DIR_TEAMS:-}";;'
  printf '%s\n' '    plugin:ms365)      printf "%s" "${STUB_STATE_DIR_MS365:-}";;'
  printf '%s\n' '    plugin:discord)    printf "%s" "${STUB_STATE_DIR_DISCORD:-}";;'
  printf '%s\n' '    plugin:telegram)   printf "%s" "${STUB_STATE_DIR_TELEGRAM:-}";;'
  printf '%s\n' '    plugin:mattermost) printf "%s" "${STUB_STATE_DIR_MATTERMOST:-}";;'
  printf '%s\n' '    *) printf "%s" "";;'
  printf '%s\n' '  esac'
  printf '%s\n' '}'
  printf '%s\n' ''
  printf '%s\n' 'bridge_agent_workdir() {'
  printf '%s\n' '  printf "%s" "${STUB_AGENT_WORKDIR:-}"'
  printf '%s\n' '}'
} >"$STUB_FILE"

cat "$STUB_FILE" >>"$EXTRACT_TMP"

# shellcheck source=/dev/null
source "$EXTRACT_TMP"

# ---------------------------------------------------------------------------
# 2. Cross-platform gating.
# ---------------------------------------------------------------------------

HAVE_SETFACL=0
HAVE_GETFACL=0
if command -v setfacl >/dev/null 2>&1; then HAVE_SETFACL=1; fi
if command -v getfacl >/dev/null 2>&1; then HAVE_GETFACL=1; fi

# ---------------------------------------------------------------------------
# Case 1: dotenv with mask reverted to --- is repaired to r-- + named-user
# becomes effective r--.
# ---------------------------------------------------------------------------
step "Case 1: regressed mask is repaired and named-user grant becomes effective"

if (( HAVE_SETFACL == 1 && HAVE_GETFACL == 1 )); then
  AGENT_NAME="agent-851-fix"
  STUB_AGENT_WORKDIR="$TMP_HOME/$AGENT_NAME/workdir"
  TEAMS_DIR="$STUB_AGENT_WORKDIR/.teams"
  mkdir -p "$TEAMS_DIR"
  TEAMS_ENV="$TEAMS_DIR/.env"
  printf 'TEAMS_APP_ID=abc\nTEAMS_APP_PASSWORD=secret\n' >"$TEAMS_ENV"
  chmod 0640 "$TEAMS_ENV"

  CTRL_UID_NAME="${USER:-${LOGNAME:-}}"
  if [[ -z "$CTRL_UID_NAME" ]]; then
    skip "could not resolve controller user (USER/LOGNAME unset)"
  else
    if ! setfacl -m "u:${CTRL_UID_NAME}:r--" "$TEAMS_ENV" 2>/dev/null; then
      skip "setfacl named-user grant unsupported on this filesystem"
    elif ! setfacl -m "m::---" "$TEAMS_ENV" 2>/dev/null; then
      skip "setfacl mask manipulation unsupported on this filesystem"
    else
      pre_mask="$(getfacl -p "$TEAMS_ENV" 2>/dev/null \
        | awk -F: '/^mask::/ {print substr($3,1,3); exit}')"
      if [[ "$pre_mask" != "---" ]]; then
        err "pre-state mask was '$pre_mask', expected the regressed shape"
      fi

      STUB_STATE_DIR_TEAMS="$TEAMS_DIR"
      STUB_STATE_DIR_MS365=""
      STUB_STATE_DIR_DISCORD=""
      STUB_STATE_DIR_TELEGRAM=""
      STUB_STATE_DIR_MATTERMOST=""
      STUB_ROSTER=""

      # iso_user composition: helper uses
      #   ${BRIDGE_AGENT_OS_USER_PREFIX:-agent-bridge-}${agent}
      # With an empty prefix and agent=$CTRL_UID_NAME the grant target is the
      # controller user, which matches the precondition we just installed.
      BRIDGE_AGENT_OS_USER_PREFIX=""
      if ! bridge_isolation_v2_apply_channel_state_dotenv_acl "$CTRL_UID_NAME" 0640; then
        err "helper returned non-zero on a recoverable file"
      else
        post_mask="$(getfacl -p "$TEAMS_ENV" 2>/dev/null \
          | awk -F: '/^mask::/ {print substr($3,1,3); exit}')"
        post_named="$(getfacl -p "$TEAMS_ENV" 2>/dev/null \
          | awk -F: -v u="$CTRL_UID_NAME" '$1=="user" && $2==u {print substr($3,1,3); exit}')"
        if [[ "$post_mask" == "r--" ]] && [[ "$post_named" == "r--" ]]; then
          ok
        else
          err "post-state mask='$post_mask' named-user='$post_named' (want both r--)"
        fi
      fi
      unset BRIDGE_AGENT_OS_USER_PREFIX
    fi
  fi
else
  skip "setfacl/getfacl not available on this host"
fi

# ---------------------------------------------------------------------------
# Case 2: no dotenv exists for any provider -> return 0 (no-op).
# ---------------------------------------------------------------------------
step "Case 2: no dotenv exists, helper is a no-op success"

STUB_AGENT_WORKDIR="$TMP_HOME/case2-agent/workdir"
mkdir -p "$STUB_AGENT_WORKDIR"
STUB_STATE_DIR_TEAMS="$STUB_AGENT_WORKDIR/.teams"
STUB_STATE_DIR_MS365="$STUB_AGENT_WORKDIR/.ms365"
STUB_STATE_DIR_DISCORD=""
STUB_STATE_DIR_TELEGRAM=""
STUB_STATE_DIR_MATTERMOST=""
STUB_ROSTER=""
BRIDGE_AGENT_OS_USER_PREFIX=""

rc=0
bridge_isolation_v2_apply_channel_state_dotenv_acl "${USER:-tester}" 0640 || rc=$?
if (( rc == 0 )); then
  ok
else
  err "expected rc=0 on missing dotenvs, got rc=$rc"
fi
unset BRIDGE_AGENT_OS_USER_PREFIX

# ---------------------------------------------------------------------------
# Case 3: roster-aware strip - a stale grant is removed; the in-roster grant
# survives.
# ---------------------------------------------------------------------------
step "Case 3: stale named-user grant is stripped, in-roster grant preserved"

if (( HAVE_SETFACL == 1 && HAVE_GETFACL == 1 )); then
  AGENT_NAME="case3-agent"
  STUB_AGENT_WORKDIR="$TMP_HOME/$AGENT_NAME/workdir"
  TEAMS_DIR="$STUB_AGENT_WORKDIR/.teams"
  mkdir -p "$TEAMS_DIR"
  TEAMS_ENV="$TEAMS_DIR/.env"
  printf 'TEAMS_APP_ID=abc\n' >"$TEAMS_ENV"
  chmod 0640 "$TEAMS_ENV"

  CTRL_UID_NAME="${USER:-${LOGNAME:-}}"
  STALE_USER="daemon"
  if ! id -u "$STALE_USER" >/dev/null 2>&1; then
    STALE_USER="nobody"
  fi
  if ! id -u "$STALE_USER" >/dev/null 2>&1; then
    skip "no usable system UID for stale grant (daemon/nobody both missing)"
  elif [[ -z "$CTRL_UID_NAME" ]]; then
    skip "could not resolve controller user (USER/LOGNAME unset)"
  elif ! setfacl -m "u:${CTRL_UID_NAME}:r--" "$TEAMS_ENV" 2>/dev/null \
       || ! setfacl -m "u:${STALE_USER}:r--" "$TEAMS_ENV" 2>/dev/null; then
    skip "setfacl multi-user grant unsupported on this filesystem"
  else
    STUB_STATE_DIR_TEAMS="$TEAMS_DIR"
    STUB_STATE_DIR_MS365=""
    STUB_STATE_DIR_DISCORD=""
    STUB_STATE_DIR_TELEGRAM=""
    STUB_STATE_DIR_MATTERMOST=""
    STUB_ROSTER=""
    BRIDGE_AGENT_OS_USER_PREFIX=""

    if ! bridge_isolation_v2_apply_channel_state_dotenv_acl "$CTRL_UID_NAME" 0640; then
      err "helper returned non-zero during strip case"
    else
      post_stale="$(getfacl -p "$TEAMS_ENV" 2>/dev/null \
        | awk -F: -v u="$STALE_USER" '$1=="user" && $2==u {print "found"; exit}')"
      post_named="$(getfacl -p "$TEAMS_ENV" 2>/dev/null \
        | awk -F: -v u="$CTRL_UID_NAME" '$1=="user" && $2==u {print substr($3,1,3); exit}')"
      if [[ -z "$post_stale" ]] && [[ "$post_named" == "r--" ]]; then
        ok
      else
        err "post-state: stale-present='$post_stale' (want empty) named-user='$post_named' (want r--)"
      fi
    fi
    unset BRIDGE_AGENT_OS_USER_PREFIX
  fi
else
  skip "setfacl/getfacl not available on this host"
fi

# ---------------------------------------------------------------------------
# Case 4: non-Linux host (no setfacl) -> return 0 with a warning.
# ---------------------------------------------------------------------------
step "Case 4: setfacl absent on host, helper returns 0 with warning"

# Build a sibling script that overrides `command` so any "command -v setfacl"
# lookup returns 1. All other lookups still succeed. Compose via printf to
# stay clear of multi-line heredoc patterns.
SIM_TMP="$TMP_HOME/sim-no-setfacl.sh"
cp "$EXTRACT_TMP" "$SIM_TMP"
{
  printf '%s\n' ''
  printf '%s\n' '# Shadow command builtin: any "command -v setfacl" lookup returns 1;'
  printf '%s\n' '# every other lookup delegates to the real builtin.'
  printf '%s\n' 'command() {'
  printf '%s\n' '  if [[ "$1" == "-v" && "$2" == "setfacl" ]]; then'
  printf '%s\n' '    return 1'
  printf '%s\n' '  fi'
  printf '%s\n' '  builtin command "$@"'
  printf '%s\n' '}'
  printf '%s\n' ''
  printf '%s\n' 'STUB_AGENT_WORKDIR="$HOME/case4-agent/workdir"'
  printf '%s\n' 'mkdir -p "$STUB_AGENT_WORKDIR"'
  printf '%s\n' 'STUB_STATE_DIR_TEAMS="$STUB_AGENT_WORKDIR/.teams"'
  printf '%s\n' 'STUB_STATE_DIR_MS365=""'
  printf '%s\n' 'STUB_STATE_DIR_DISCORD=""'
  printf '%s\n' 'STUB_STATE_DIR_TELEGRAM=""'
  printf '%s\n' 'STUB_STATE_DIR_MATTERMOST=""'
  printf '%s\n' 'STUB_ROSTER=""'
  printf '%s\n' 'BRIDGE_AGENT_OS_USER_PREFIX=""'
  printf '%s\n' ''
  printf '%s\n' 'rc=0'
  printf '%s\n' 'warn_capture="$(bridge_isolation_v2_apply_channel_state_dotenv_acl "tester" 0640 2>&1)" || rc=$?'
  printf '%s\n' 'printf "RC=%s\n" "$rc"'
  printf '%s\n' 'printf "WARN=%s\n" "$warn_capture"'
} >>"$SIM_TMP"

sim_out="$(bash "$SIM_TMP" 2>&1)"
sim_rc="$(printf '%s' "$sim_out" | awk -F= '/^RC=/ {print $2; exit}')"
sim_warn="$(printf '%s' "$sim_out" | awk -F= '/^WARN=/ {sub("^WARN=",""); print}')"
if [[ "$sim_rc" == "0" ]] && printf '%s' "$sim_warn" | grep -q "setfacl not available"; then
  ok
else
  err "rc='$sim_rc' warn='$sim_warn' (want rc=0 + warning about setfacl absence)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$((PASS + FAIL + SKIP))
printf '\n# Issue #851 dotenv-mask-repair suite: %s passed, %s skipped, %s failed (total %s)\n' \
  "$PASS" "$SKIP" "$FAIL" "$TOTAL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
