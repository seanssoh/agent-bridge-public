#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/989-isolated-agent-env-state-dir.sh — Issue #989.
#
# Pins the contract that a roster mutation (channel-add / channel-remove /
# launch-cmd edit) refreshes the cached `runtime/agent-env.sh` for a
# linux-user isolated agent so the cached BRIDGE_AGENT_LAUNCH_CMD /
# BRIDGE_AGENT_WORKDIR can never regress to a pre-v2 channel state path.
#
# The bug (#989, a regression of #771): `agent update --channels-*`
# rewrote agent-roster.local.sh but never regenerated the cached
# `runtime/agent-env.sh` — the ONLY roster snapshot an isolated UID can
# read. The stale snapshot kept a launch cmd whose embedded
# `TEAMS_STATE_DIR` pointed at the pre-v2 path `agents/<X>/.teams`
# (owned ec2-user mode 700) instead of `agents/<X>/workdir/.teams`. The
# isolated UID then got EACCES on the channel state dir and silently
# stopped delivering inbound Teams messages.
#
# The fix introduced in this PR:
#   `bridge_ensure_isolated_agent_env_current` (lib/bridge-agents.sh) —
#   regenerates `runtime/agent-env.sh` via bridge_write_linux_agent_env_file
#   for linux-user isolated agents, mirroring the isolation-v2-reapply
#   recompute (lib/bridge-isolation-v2-reapply.sh:448-528). NO-OP for
#   non-isolated agents. `run_update` calls it after the roster rewrite.
#
# Test plan (all run against the bash helpers, no live tmux / Claude):
#   T1. Stale pre-v2 `runtime/agent-env.sh` → after the helper runs, the
#       regenerated file carries the v2 `workdir/` path in
#       BRIDGE_AGENT_WORKDIR (and never a bare base-dir path).
#   T2. The helper is a NO-OP for a non-isolated (shared-mode) agent —
#       a pre-existing agent-env.sh is left byte-identical (not even
#       created if absent).
#   T3. Idempotency — a second call against an already-canonical file
#       leaves it byte-identical (mtime preserved).
#   T4. Cache-staleness guard — pins the invalidate+reload+regen sequence
#       `run_update` performs. `bridge_load_roster` short-circuits on
#       BRIDGE_ROSTER_CACHE_LOADED=1 (issue #848 per-process memo), so a
#       bare reload after a roster-file rewrite replays the pre-mutation
#       maps and the regenerated env file misses the new channel. The
#       fix invalidates the cache first. T4 proves both directions: bare
#       reload → stale; invalidate+reload → fresh.
#   T5. Setup-style direct-write path — `bridge-setup.sh`'s discord /
#       telegram / teams entrypoints mutate BRIDGE_AGENT_CHANNELS /
#       BRIDGE_AGENT_LAUNCH_CMD via a single-line assoc rewrite
#       (bridge_setup_write_local_assoc), NOT via bridge_write_role_block.
#       T5 exercises that vector + the shared
#       `bridge_refresh_isolated_agent_env_after_channel_mutation` helper
#       and asserts the regenerated cache carries the v2 workdir path and
#       the newly-added channel.
#   T6. relay-cleanup upgrade vector — `bridge-relay-cleanup.py` (run by
#       `agent-bridge upgrade --apply`) rewrites BRIDGE_AGENT_CHANNELS /
#       BRIDGE_AGENT_LAUNCH_CMD to strip the legacy telegram-relay
#       plugin. T6 runs the real cleanup tool against an isolated agent's
#       roster then the shared helper (the call the upgrade block now
#       makes), asserting the regenerated cache reflects the strip.
#
# Isolation: temp BRIDGE_HOME with v2 layout via smoke_setup_bridge_home;
# the smoke never reads or writes the operator's live runtime.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `printf '%s\n' >$tmp` and plain `cat >file <<EOF` bodies on flat
# string variables — no command substitution feeding a heredoc-stdin,
# no `<<<` here-strings into bridge functions.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays. macOS ships /bin/bash
# 3.2 — match the recipe used by scripts/smoke/981-restart-session-resume-snapshot.sh.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:989-isolated-agent-env-state-dir] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="989-isolated-agent-env-state-dir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "989-isolated-agent-env-state-dir"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

if ! declare -F bridge_ensure_isolated_agent_env_current >/dev/null; then
  smoke_fail "bridge_ensure_isolated_agent_env_current not defined after sourcing bridge-lib.sh"
fi
if ! declare -F bridge_write_linux_agent_env_file >/dev/null; then
  smoke_fail "bridge_write_linux_agent_env_file not defined (sanity check)"
fi
if ! declare -F bridge_agent_linux_env_file >/dev/null; then
  smoke_fail "bridge_agent_linux_env_file not defined (sanity check)"
fi

bridge_reset_roster_maps

# --- shared fixture ----------------------------------------------------------

# Seed a minimal in-memory agent record. The writer reads ~25 BRIDGE_AGENT_*
# maps; seed every one it touches so bridge_write_linux_agent_env_file
# produces a complete file. linux-user isolation is declared so
# bridge_agent_workdir resolves the v2 anchor (BRIDGE_AGENT_ROOT_V2/<X>/workdir).
seed_agent() {
  local agent="$1"
  local isolation="$2"
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]=""
  BRIDGE_AGENT_PROFILE_HOME["$agent"]=""
  BRIDGE_AGENT_LAUNCH_CMD["$agent"]="TEAMS_STATE_DIR=$BRIDGE_AGENT_ROOT_V2/$agent/.teams claude --plugin plugin:teams@agent-bridge"
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
  BRIDGE_AGENT_CHANNELS["$agent"]="plugin:teams@agent-bridge"
  BRIDGE_AGENT_ISOLATION_MODE["$agent"]="$isolation"
  BRIDGE_AGENT_OS_USER["$agent"]="agent-bridge-$agent"
}

# Plant a STALE pre-v2 runtime/agent-env.sh: BRIDGE_AGENT_WORKDIR points at
# the bare base agent dir (no `/workdir`), exactly the shape a v0.7->v0.8
# migrated agent's cache had before #771 / this fix.
plant_stale_env_file() {
  local agent="$1"
  local env_file="$2"
  mkdir -p "$(dirname "$env_file")"
  cat >"$env_file" <<EOF
#!/usr/bin/env bash
# stale pre-v2 cache (smoke fixture)
BRIDGE_AGENT_WORKDIR[$agent]=$BRIDGE_AGENT_ROOT_V2/$agent
BRIDGE_AGENT_LAUNCH_CMD[$agent]='TEAMS_STATE_DIR=$BRIDGE_AGENT_ROOT_V2/$agent/.teams claude'
EOF
}

# --- T1: stale isolated agent-env.sh is regenerated with the v2 path ---------

test_isolated_regenerates_v2_path() {
  local agent="iso-989"
  seed_agent "$agent" "linux-user"

  # Stub the isolation predicate to return 0 so the helper exercises the
  # regenerate path on a non-Linux smoke host (mirrors the mocking
  # convention in scripts/smoke/857-pr1-isolation-write-helper.sh). The
  # writer's Linux-only chgrp/chmod branch is skipped because
  # bridge_host_platform still reports the real (non-Linux) host.
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 0; }

  local env_file
  env_file="$(bridge_agent_linux_env_file "$agent")"
  plant_stale_env_file "$agent" "$env_file"

  # Pre-condition: the planted file has the pre-v2 (bare base-dir) path.
  local stale_workdir_line
  stale_workdir_line="$(grep "BRIDGE_AGENT_WORKDIR\[$agent\]" "$env_file")"
  smoke_assert_not_contains "$stale_workdir_line" "/workdir" \
    "T1 pre-condition: planted env file has the stale pre-v2 path"

  local rc=0
  bridge_ensure_isolated_agent_env_current "$agent" || rc=$?
  smoke_assert_eq "0" "$rc" "T1 helper returns 0 for an isolated agent"
  smoke_assert_file_exists "$env_file" "T1 env file still exists after regen"

  # The regenerated file must carry the v2 workdir anchor.
  local fresh_workdir_line
  fresh_workdir_line="$(grep "^BRIDGE_AGENT_WORKDIR\[" "$env_file" | head -n 1)"
  smoke_assert_contains "$fresh_workdir_line" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir" \
    "T1 regenerated env file carries the v2 workdir path"

  # And the channel state dir derived from workdir lands under workdir/.
  local teams_dir
  teams_dir="$(bridge_agent_teams_state_dir "$agent")"
  smoke_assert_contains "$teams_dir" "/workdir/.teams" \
    "T1 teams state dir resolves to the v2 workdir/.teams path"
}

# --- T2: NO-OP for a non-isolated (shared-mode) agent ------------------------

test_non_isolated_noop() {
  local agent="shared-989"
  seed_agent "$agent" "shared"

  # No isolation-predicate stub here: on this non-Linux smoke host
  # bridge_agent_linux_user_isolation_effective returns 1 for a
  # shared-mode agent, which is exactly the NO-OP gate we want to pin.
  local env_file
  env_file="$(bridge_agent_linux_env_file "$agent")"
  mkdir -p "$(dirname "$env_file")"
  printf '%s\n' "SENTINEL=untouched" >"$env_file"

  local rc=0
  bridge_ensure_isolated_agent_env_current "$agent" || rc=$?
  smoke_assert_eq "0" "$rc" "T2 helper returns 0 (NO-OP) for a non-isolated agent"

  local after
  after="$(cat "$env_file")"
  smoke_assert_eq "SENTINEL=untouched" "$after" \
    "T2 non-isolated agent-env.sh left byte-identical (NO-OP)"
}

# --- T3: idempotency — a second call leaves the file unchanged ---------------

test_idempotent_second_call() {
  local agent="idem-989"
  seed_agent "$agent" "linux-user"
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 0; }

  local env_file
  env_file="$(bridge_agent_linux_env_file "$agent")"
  mkdir -p "$(dirname "$env_file")"

  # First call generates the canonical file.
  bridge_ensure_isolated_agent_env_current "$agent"
  smoke_assert_file_exists "$env_file" "T3 first call generated the env file"
  local first_sum
  first_sum="$(cksum <"$env_file")"

  # Second call against an already-canonical file must not rewrite it.
  local rc=0
  bridge_ensure_isolated_agent_env_current "$agent" || rc=$?
  smoke_assert_eq "0" "$rc" "T3 second call returns 0"
  local second_sum
  second_sum="$(cksum <"$env_file")"
  smoke_assert_eq "$first_sum" "$second_sum" \
    "T3 already-canonical env file left byte-identical on the second call"
}

# --- T4: cache-staleness guard (the invalidate+reload+regen sequence) --------

# Write a roster file (agent-roster.local.sh) with a single isolated agent
# whose channel set is `$channels`. v2 layout markers are already seeded by
# smoke_setup_bridge_home.
write_isolated_roster() {
  local agent="$1"
  local channels="$2"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_ADMIN_AGENT_ID=${agent}
# BEGIN AGENT BRIDGE MANAGED ROLE: ${agent}
bridge_add_agent_id_if_missing ${agent}
BRIDGE_AGENT_DESC["${agent}"]='isolated smoke fixture'
BRIDGE_AGENT_ENGINE["${agent}"]='claude'
BRIDGE_AGENT_SESSION["${agent}"]='${agent}'
BRIDGE_AGENT_SOURCE["${agent}"]="static"
BRIDGE_AGENT_LAUNCH_CMD["${agent}"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CHANNELS["${agent}"]="${channels}"
BRIDGE_AGENT_ISOLATION_MODE["${agent}"]='linux-user'
BRIDGE_AGENT_OS_USER["${agent}"]='agent-bridge-${agent}'
BRIDGE_AGENT_CONTINUE["${agent}"]="1"
# END AGENT BRIDGE MANAGED ROLE: ${agent}
EOF
}

# Extract the BRIDGE_AGENT_CHANNELS assignment for $agent from a generated
# agent-env.sh (the writer emits it as `BRIDGE_AGENT_CHANNELS[<q>]=<q>`).
env_file_channels_line() {
  local agent="$1"
  local env_file="$2"
  grep "BRIDGE_AGENT_CHANNELS\[" "$env_file" | grep "$agent" | head -n 1
}

test_cache_staleness_guard() {
  local agent="cache-989"
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 0; }

  # 1. Roster on disk starts with ONLY teams; load it (sets the
  #    per-process BRIDGE_ROSTER_CACHE_LOADED=1 memo, mirroring what
  #    bridge-agent.sh does at script load before run_update).
  write_isolated_roster "$agent" "plugin:teams@agent-bridge"
  bridge_roster_cache_invalidate
  bridge_load_roster

  local env_file
  env_file="$(bridge_agent_linux_env_file "$agent")"
  mkdir -p "$(dirname "$env_file")"

  # 2. Simulate a channel-add: rewrite the roster file on disk with an
  #    extra channel (this is what bridge_write_role_block does inside
  #    run_update — it only touches the file, not the in-memory maps).
  write_isolated_roster "$agent" "plugin:teams@agent-bridge,plugin:discord@agent-bridge"

  # 2a. Negative control: a BARE reload (no cache invalidation) is a
  #     no-op because of the #848 memo, so the regenerated env file
  #     still misses the new channel. This is the exact bug a missing
  #     bridge_roster_cache_invalidate re-introduces.
  bridge_load_roster
  bridge_ensure_isolated_agent_env_current "$agent"
  local stale_line
  stale_line="$(env_file_channels_line "$agent" "$env_file")"
  smoke_assert_not_contains "$stale_line" "discord" \
    "T4 negative control: bare reload (no invalidate) replays stale maps — discord absent"

  # 2b. The fix: invalidate THEN reload picks up the new channel from
  #     disk; the regenerated env file now carries it.
  bridge_roster_cache_invalidate
  bridge_load_roster
  bridge_ensure_isolated_agent_env_current "$agent"
  local fresh_line
  fresh_line="$(env_file_channels_line "$agent" "$env_file")"
  smoke_assert_contains "$fresh_line" "discord" \
    "T4 invalidate+reload+regen: regenerated env file carries the newly-added channel"
  smoke_assert_contains "$fresh_line" "teams" \
    "T4 invalidate+reload+regen: original channel still present"
}

# --- T5: setup-style direct write path + shared post-mutation helper ---------

# Rewrite ONLY the BRIDGE_AGENT_CHANNELS assignment line in the roster file
# in place — this mirrors bridge-setup.sh's bridge_setup_write_local_assoc
# (a single-line assoc rewrite), as opposed to bridge_write_role_block's
# whole managed-role block rewrite that run_update / T1-T4 exercise.
setup_style_rewrite_channels() {
  local agent="$1"
  local channels="$2"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/roster.XXXXXX")"
  while IFS= read -r line; do
    case "$line" in
      "BRIDGE_AGENT_CHANNELS[\"$agent\"]="*)
        # Double-quoted value form, matching bridge_setup_write_local_assoc.
        printf '%s\n' "BRIDGE_AGENT_CHANNELS[\"$agent\"]=\"$channels\""
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done <"$BRIDGE_ROSTER_LOCAL_FILE" >"$tmp"
  mv "$tmp" "$BRIDGE_ROSTER_LOCAL_FILE"
}

test_setup_style_mutation_refreshes_cache() {
  local agent="setup-989"
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 0; }

  # Roster starts with teams only; load it (per-process cache memo set).
  write_isolated_roster "$agent" "plugin:teams@agent-bridge"
  bridge_roster_cache_invalidate
  bridge_load_roster

  local env_file
  env_file="$(bridge_agent_linux_env_file "$agent")"
  mkdir -p "$(dirname "$env_file")"

  # Simulate `agent-bridge setup discord <agent>`: the setup mutator
  # rewrites the BRIDGE_AGENT_CHANNELS line on disk AND updates the
  # in-process map, then the entrypoint calls the shared post-mutation
  # helper. Reproduce that exact two-step here.
  setup_style_rewrite_channels "$agent" "plugin:teams@agent-bridge,plugin:discord@agent-bridge"
  BRIDGE_AGENT_CHANNELS["$agent"]="plugin:teams@agent-bridge,plugin:discord@agent-bridge"

  local rc=0
  bridge_refresh_isolated_agent_env_after_channel_mutation "$agent" || rc=$?
  smoke_assert_eq "0" "$rc" "T5 shared helper returns 0 after a setup-style mutation"

  # The regenerated cache must carry the v2 workdir path AND the new channel.
  local workdir_line channels_line
  workdir_line="$(grep "^BRIDGE_AGENT_WORKDIR\[" "$env_file" | head -n 1)"
  smoke_assert_contains "$workdir_line" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir" \
    "T5 regenerated env file carries the v2 workdir path"
  channels_line="$(env_file_channels_line "$agent" "$env_file")"
  smoke_assert_contains "$channels_line" "discord" \
    "T5 setup-style channel add propagated to the regenerated cache"
  smoke_assert_contains "$channels_line" "teams" \
    "T5 original channel still present after the setup-style mutation"

  local teams_dir
  teams_dir="$(bridge_agent_teams_state_dir "$agent")"
  smoke_assert_contains "$teams_dir" "/workdir/.teams" \
    "T5 teams state dir resolves to the v2 workdir/.teams path"
}

# --- T6: relay-cleanup upgrade vector + shared helper ------------------------

# bridge-relay-cleanup.py is the v0.7.x telegram-relay residue cleanup that
# `agent-bridge upgrade --apply` runs. It rewrites BRIDGE_AGENT_CHANNELS to
# drop the legacy `plugin:telegram-relay@*` item — another roster-mutation
# path. The upgrade block now calls the shared helper after relay-cleanup;
# T6 exercises that end-to-end: real relay-cleanup roster rewrite + the
# shared helper, asserting the regenerated cache reflects the relay-stripped
# channel set with the v2 workdir path.
test_relay_cleanup_vector_refreshes_cache() {
  local agent="relay-989"
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 0; }

  # Roster carries the legacy relay channel; load it (cache memo set).
  write_isolated_roster "$agent" "plugin:telegram-relay@claude-plugins-official"
  bridge_roster_cache_invalidate
  bridge_load_roster

  local env_file
  env_file="$(bridge_agent_linux_env_file "$agent")"
  mkdir -p "$(dirname "$env_file")"

  # Run the REAL relay-cleanup tool against this roster (no backup —
  # mirrors the in-upgrade caller). It rewrites BRIDGE_AGENT_CHANNELS to
  # drop the relay item and ensure plugin:telegram@claude-plugins-official.
  python3 "$REPO_ROOT/bridge-relay-cleanup.py" \
    --target-root "$BRIDGE_HOME" \
    --roster-file "$BRIDGE_ROSTER_LOCAL_FILE" \
    --no-backup >/dev/null 2>&1

  # Sanity: the relay channel is gone from the roster file on disk.
  local roster_channels_line
  roster_channels_line="$(grep "BRIDGE_AGENT_CHANNELS\[" "$BRIDGE_ROSTER_LOCAL_FILE" | head -n 1)"
  smoke_assert_not_contains "$roster_channels_line" "telegram-relay" \
    "T6 pre-condition: relay-cleanup stripped plugin:telegram-relay from the roster"

  # The shared helper (the call the upgrade block now makes after
  # relay-cleanup) must propagate that into the cached env file.
  local rc=0
  bridge_refresh_isolated_agent_env_after_channel_mutation "$agent" || rc=$?
  smoke_assert_eq "0" "$rc" "T6 shared helper returns 0 after the relay-cleanup rewrite"

  local channels_line workdir_line
  channels_line="$(env_file_channels_line "$agent" "$env_file")"
  smoke_assert_not_contains "$channels_line" "telegram-relay" \
    "T6 regenerated cache no longer carries the legacy relay channel"
  workdir_line="$(grep "^BRIDGE_AGENT_WORKDIR\[" "$env_file" | head -n 1)"
  smoke_assert_contains "$workdir_line" "$BRIDGE_AGENT_ROOT_V2/$agent/workdir" \
    "T6 regenerated cache carries the v2 workdir path"
}

# --- main --------------------------------------------------------------------

# Each test reseeds the maps and runs in its own sub-shell so a stubbed
# bridge_agent_linux_user_isolation_effective does not leak across cases.
( test_isolated_regenerates_v2_path ) || smoke_fail "T1 sub-shell failed"
smoke_log "ok: T1 (stale isolated agent-env.sh regenerated with v2 workdir path)"

( test_non_isolated_noop ) || smoke_fail "T2 sub-shell failed"
smoke_log "ok: T2 (NO-OP for non-isolated agent)"

( test_idempotent_second_call ) || smoke_fail "T3 sub-shell failed"
smoke_log "ok: T3 (idempotent — second call leaves the file byte-identical)"

( test_cache_staleness_guard ) || smoke_fail "T4 sub-shell failed"
smoke_log "ok: T4 (cache invalidate+reload required before regen picks up roster changes)"

( test_setup_style_mutation_refreshes_cache ) || smoke_fail "T5 sub-shell failed"
smoke_log "ok: T5 (setup-style direct-write mutation + shared helper refreshes the cache)"

( test_relay_cleanup_vector_refreshes_cache ) || smoke_fail "T6 sub-shell failed"
smoke_log "ok: T6 (relay-cleanup roster rewrite + shared helper refreshes the cache)"

smoke_log "passed"
