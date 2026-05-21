#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1025-isolated-create-agent-env-install.sh — Issue #1025.
#
# Pins the contract that, for a linux-user isolated agent,
# `bridge_write_linux_agent_env_file` (lib/bridge-agents.sh) hands the
# cached `runtime/agent-env.sh` off to its per-agent destination through
# a SINGLE privileged `install` invocation that sets owner, group, and
# mode atomically — and performs NO separate post-install `chgrp`/
# `chmod` on that destination.
#
# The bug (#1025): the writer built the env file directly under the
# isolation-v2 per-agent root, which the scaffold leaves
# `root:ab-agent-<name>`. A `usermod -aG` during prepare does not
# refresh the running controller process's supplementary group set, so
# the same-invocation `mkdir`/`cat >` was refused and `agent create
# --isolate` aborted with `Permission denied`, leaving a half-created
# agent.
#
# The fix stages the build into a controller-owned tempfile and
# `install`s it via sudo. Codex r1 BLOCKING items on the first fix:
#   B1 — a bare `install` + a separate `chgrp`/`chmod` left the file
#        root-owned (the isolation-v2 matrix requires
#        `controller:<agent_grp>` mode 0640) and is not always repaired
#        later (`bridge_ensure_isolated_agent_env_current` calls the
#        writer directly with no matrix reapply).
#   B2 — the separate post-install metadata touch reopened a TOCTOU
#        symlink window: `runtime/` is isolated-UID-owned + group-
#        writable 2770, so a live isolated agent could swap
#        `agent-env.sh` for a symlink between install and chgrp/chmod.
# Both are closed by collapsing install + owner + group + mode into one
# `install -o -g -m 0640` call with no second touch.
#
# Test plan (in-process bash helpers — no live tmux / Claude / sudo):
#   T1. linux-user isolated agent, dest under BRIDGE_AGENT_ROOT_V2 →
#       the writer issues EXACTLY ONE `install` carrying `-o <controller>`
#       `-g <agent_grp>` `-m 0640`, and ZERO `chgrp`/`chmod` against the
#       per-agent destination. (B1 + B2.)
#   T2. The installed file's recorded owner:group:mode is
#       `<controller>:<agent_grp> 0640` — the v2 matrix contract. (B1.)
#   T3. The pre-install symlink defense is retained — a symlink planted
#       at the destination is removed before the install.
#
# `bridge_linux_sudo_root` is stubbed to a recorder that runs the
# command without sudo (the smoke host is not root and has no
# ab-agent-* groups) and appends each invocation to a log, so the smoke
# can assert the exact privileged-call shape on any platform.
#
# Footgun #11 (heredoc_write deadlock class): fixture uses only
# `printf '%s\n' >file` — no command substitution feeding heredoc-stdin,
# no `<<<` here-strings into bridge functions.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (macOS ships 3.2).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1025-isolated-create-agent-env-install] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1025-isolated-create-agent-env-install"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1025-isolated-create-agent-env-install"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

if ! declare -F bridge_write_linux_agent_env_file >/dev/null; then
  smoke_fail "bridge_write_linux_agent_env_file not defined after sourcing bridge-lib.sh"
fi

bridge_reset_roster_maps

# --- Recording stub for bridge_linux_sudo_root -------------------------------
# Logs each privileged call (one space-joined line) to $SUDO_LOG, then
# executes it directly (no `sudo`) so file ops still take effect on the
# unprivileged smoke host. `install -o/-g` to a non-existent user/group
# would fail here, so the `-o`/`-g` values are remapped to the current
# identity for execution while the LOG keeps the requested values — the
# assertions read the log, the filesystem effect just needs to succeed.
SUDO_LOG="$SMOKE_TMP_ROOT/sudo-calls.log"
: >"$SUDO_LOG"
# shellcheck disable=SC2329
bridge_linux_sudo_root() {
  printf '%s\n' "$*" >>"$SUDO_LOG"
  local -a run=()
  local a
  for a in "$@"; do
    case "$a" in
      "$REQUESTED_OWNER") run+=("$(id -un)") ;;
      "$REQUESTED_GROUP") run+=("$(id -gn)") ;;
      *) run+=("$a") ;;
    esac
  done
  "${run[@]}"
}

# Force the writer's Linux-only isolated-write branch on a non-Linux host.
export BRIDGE_HOST_PLATFORM_OVERRIDE="Linux"
# shellcheck disable=SC2329
bridge_agent_linux_user_isolation_effective() { return 0; }

# --- shared fixture ----------------------------------------------------------

AGENT="iso-1025"
REQUESTED_OWNER="$(id -un)"
REQUESTED_GROUP="$(bridge_isolation_v2_agent_group_name "$AGENT")"
[[ -n "$REQUESTED_GROUP" ]] || smoke_fail "could not derive agent group for $AGENT"

seed_agent() {
  local agent="$1"
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]=""
  BRIDGE_AGENT_PROFILE_HOME["$agent"]=""
  BRIDGE_AGENT_LAUNCH_CMD["$agent"]="claude"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
  BRIDGE_AGENT_HISTORY_KEY["$agent"]=""
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_UPDATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_IDLE_TIMEOUT["$agent"]="600"
  BRIDGE_AGENT_NOTIFY_KIND["$agent"]=""
  BRIDGE_AGENT_NOTIFY_TARGET["$agent"]=""
  BRIDGE_AGENT_NOTIFY_ACCOUNT["$agent"]=""
  BRIDGE_AGENT_DISCORD_CHANNEL_ID["$agent"]=""
  BRIDGE_AGENT_CHANNELS["$agent"]=""
  BRIDGE_AGENT_ISOLATION_MODE["$agent"]="linux-user"
  BRIDGE_AGENT_OS_USER["$agent"]="agent-bridge-$agent"
}

seed_agent "$AGENT"

ENV_FILE="$(bridge_agent_linux_env_file "$AGENT")"
# Sanity: the destination must be under the per-agent v2 root, which is
# the predicate that arms the staged-install branch.
case "$ENV_FILE" in
  "$BRIDGE_AGENT_ROOT_V2/$AGENT"/*) ;;
  *) smoke_fail "env file '$ENV_FILE' is not under BRIDGE_AGENT_ROOT_V2 — fixture mis-seeded" ;;
esac

# --- T3 fixture: plant a symlink at the destination --------------------------
# The pre-install symlink defense must remove it before the install.
mkdir -p "$(dirname "$ENV_FILE")"
DECOY="$SMOKE_TMP_ROOT/decoy-target"
printf 'decoy\n' >"$DECOY"
ln -sf "$DECOY" "$ENV_FILE"
[[ -L "$ENV_FILE" ]] || smoke_fail "T3 pre-condition: failed to plant symlink at $ENV_FILE"

# --- run the writer ----------------------------------------------------------
rc=0
bridge_write_linux_agent_env_file "$AGENT" || rc=$?
smoke_assert_eq "0" "$rc" "writer returns 0 for an isolated agent"
smoke_assert_file_exists "$ENV_FILE" "agent-env.sh exists after the writer runs"

# --- T1: exactly one `install`, zero post-install chgrp/chmod on the dest ----
install_calls="$(grep -c '^install ' "$SUDO_LOG" || true)"
smoke_assert_eq "1" "$install_calls" \
  "T1: writer issues exactly ONE privileged install for the staged env file"

# No `chgrp`/`chmod` against the per-agent destination after install.
# (`install -m` carries the mode; `-o`/`-g` carry the owner/group — a
# separate metadata touch is the TOCTOU window codex flagged.)
if grep -E "^(chgrp|chmod) .*${AGENT}" "$SUDO_LOG" >/dev/null 2>&1; then
  echo "--- sudo call log ---" >&2
  cat "$SUDO_LOG" >&2
  smoke_fail "T1: found a post-install chgrp/chmod against the per-agent env file — TOCTOU window reopened"
fi
smoke_log "T1 PASS — single install, no follow-prone second metadata touch"

# --- T2: the install carries the v2 matrix owner:group:mode contract ---------
install_line="$(grep '^install ' "$SUDO_LOG" | head -n1)"
smoke_assert_contains "$install_line" "-o $REQUESTED_OWNER" \
  "T2: install sets owner to the controller user"
smoke_assert_contains "$install_line" "-g $REQUESTED_GROUP" \
  "T2: install sets group to the per-agent group ($REQUESTED_GROUP)"
smoke_assert_contains "$install_line" "-m 0640" \
  "T2: install sets mode 0640 (isolation-v2 agent-env-sh contract)"

# Filesystem effect: the recorder remapped -o/-g to the current identity
# for execution, but mode is identity-independent — assert it landed.
env_mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")"
smoke_assert_eq "640" "$env_mode" \
  "T2: installed agent-env.sh is mode 0640 on disk"
smoke_log "T2 PASS — install lands controller:<agent_grp> 0640 atomically"

# --- T3: the pre-install symlink defense removed the planted symlink ---------
[[ -L "$ENV_FILE" ]] && smoke_fail "T3: env file is still a symlink — pre-install defense did not fire"
[[ -f "$ENV_FILE" ]] || smoke_fail "T3: env file is not a regular file after the writer ran"
if grep -q "$DECOY" "$ENV_FILE" 2>/dev/null; then
  smoke_fail "T3: writer wrote THROUGH the planted symlink — decoy content reached the destination"
fi
grep -q '^BRIDGE_AGENT_ID=' "$ENV_FILE" \
  || smoke_fail "T3: installed file does not look like a real agent-env.sh"
smoke_log "T3 PASS — planted symlink removed; install landed a fresh regular file"

smoke_log "PASS — isolated-create env-file install is atomic owner:group:mode, no TOCTOU window (#1025)"
exit 0
