#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
#
# bridge-isolation-v2.sh — POSIX group/setgid based isolation primitives.
#
# This module is part of the v2 isolation rewrite that replaces the
# named-ACL based contract (bridge_linux_prepare_agent_isolation) with a
# pure POSIX group + setgid model. It only provides primitives:
# path variables, group ensure helpers, chgrp/setgid helpers, and umask
# helpers. It does NOT change BRIDGE_HOME default behavior, does NOT
# delete or replace any current ACL helper, and does NOT alter any
# resolver or runtime path. Those changes belong to PR-B/C/D/E.
#
# The opt-in flag is `BRIDGE_LAYOUT=v2`. When unset (default), all helpers
# either no-op or keep legacy semantics; nothing in here breaks legacy
# installs.
#
# Design references:
# - design-review r3 plan-ok at task #1132/#1137
# - operator (Sean) directive: "공유는 group + setgid. ACL 안 씀. 개인은 700"
# - dev-codex review notes:
#     r1: per-agent private group (ab-agent-<name>) + shared write policy
#         + secret placement
#     r2: umask 077 incompatibility, shared/runtime secrets, mode 2750/0640
#     r3: per-agent v2 private umask 007, runtime secrets out of shared,
#         shared as group access boundary
#
# Group model (final):
#   ab-shared            — read-only public assets. Members: controller user
#                          and every isolated UID. Only the controller writes.
#   ab-controller        — controller-only state. Members: controller user.
#   ab-agent-<name>      — per-agent private root. Members: controller +
#                          agent-bridge-<name>. Other isolated UIDs are NOT
#                          members.
#
# Layout (final, when BRIDGE_LAYOUT=v2 and BRIDGE_DATA_ROOT is set):
#   $BRIDGE_DATA_ROOT/                      mode 755 (others traverse)
#   ├── shared/                             owner=controller, group=ab-shared,    mode 2750
#   │   ├── plugins-cache/                  ← v2 canonical Claude plugins root.
#   │   │   ├── installed_plugins.json
#   │   │   ├── known_marketplaces.json
#   │   │   └── marketplaces/<id>/         ← marketplace mirror trees live here
#   │   ├── plugins/                        ← agent-bridge plugin source (teams/ms365)
#   │   ├── skills/, docs/
#   ├── agents/                             owner=root,       group=root,         mode 755
#   │   └── <agent>/                        owner=root,
#   │                                       group=ab-agent-<name>,                mode 2750
#   │       ├── home/                       owner=agent-bridge-<name>,
#   │       │                               group=ab-agent-<name>,                mode 2770
#   │       ├── workdir/                    owner=agent-bridge-<name>,
#   │       │                               group=ab-agent-<name>,                mode 2770
#   │       ├── runtime/                    owner=agent-bridge-<name>,
#   │       │                               group=ab-agent-<name>,                mode 2770
#   │       ├── logs/                       owner=agent-bridge-<name>,
#   │       │                               group=ab-agent-<name>,                mode 2770
#   │       ├── requests/, responses/       owner=agent-bridge-<name>,
#   │       │                               group=ab-agent-<name>,                mode 2770
#   │       └── credentials/                owner=controller,
#   │                                       group=ab-agent-<name>,                mode 2750
#   │           └── launch-secrets.env      owner=controller,
#   │                                       group=ab-agent-<name>,                mode 0640
#   ├── state/                              owner=controller, group=ab-controller, mode 2750
#   │   └── runtime/                        bridge-config.json + secrets here
#   ├── agent-roster.sh                     owner=controller, group=ab-controller, mode 0640
#   └── agent-roster.local.sh               owner=controller, group=ab-controller, mode 0640
#
# Note on `marketplaces/`: PR-A's earlier draft listed `shared/marketplaces/`
# as a sibling of `plugins-cache/`. That was a bug — Claude expects the
# marketplace mirror to live under the same root as installed_plugins.json
# / known_marketplaces.json so manifest entries with marketplace references
# resolve. PR-B canonicalizes the layout: `shared/plugins-cache/marketplaces/`
# is the single marketplace mirror root. There is no separate
# `shared/marketplaces/` directory.
#
# Default group names are env-overridable so this can be exercised in
# tempdir-based tests without root.

# ---------------------------------------------------------------------------
# 1. opt-in flag and path variables
# ---------------------------------------------------------------------------

# Layout selector. v0.8.0 hard-cut: the only accepted value is `v2`. The
# resolver in lib/bridge-layout-resolver.sh fail-fasts on anything else
# (including unset / legacy / v1 / arbitrary strings) BEFORE this module
# is sourced, so by the time we read BRIDGE_LAYOUT here it is either
# `v2` or the process has already exited via bridge_die. We deliberately
# do NOT default to `legacy` anymore — the legacy-fallback default was
# the v1 ACL-isolation entry point and v0.8.0 removed v1.
#
# Tests that source this file standalone (without going through
# bridge-lib.sh + the resolver) must export BRIDGE_LAYOUT=v2 themselves;
# leaving it unset is no longer a valid runtime state.
BRIDGE_LAYOUT="${BRIDGE_LAYOUT:-}"

# Data root for v2 layout. When unset, v2 helpers no-op (legacy mode).
# Default suggestion when an operator opts in: /srv/agent-bridge.
BRIDGE_DATA_ROOT="${BRIDGE_DATA_ROOT:-}"

# Derived path variables. Empty when BRIDGE_DATA_ROOT is unset.
BRIDGE_SHARED_ROOT="${BRIDGE_SHARED_ROOT:-${BRIDGE_DATA_ROOT:+$BRIDGE_DATA_ROOT/shared}}"
BRIDGE_AGENT_ROOT_V2="${BRIDGE_AGENT_ROOT_V2:-${BRIDGE_DATA_ROOT:+$BRIDGE_DATA_ROOT/agents}}"
BRIDGE_CONTROLLER_STATE_ROOT="${BRIDGE_CONTROLLER_STATE_ROOT:-${BRIDGE_DATA_ROOT:+$BRIDGE_DATA_ROOT/state}}"

# v2 shared-dir resolver flip (gated on the migrate shared-mirror sentinel).
#
# BRIDGE_SHARED_DIR is the variable the daemon and nearly every CLI
# (knowledge/wiki search, bundle, intake, task notes) read for the active
# shared tree; its legacy default ($BRIDGE_HOME/shared) is applied lazily in
# bridge_load_roster (lib/bridge-state.sh), which is too late for callers
# that snapshot BRIDGE_SHARED_DIR right after sourcing bridge-lib.sh
# (bridge-bundle.sh, bridge-intake.sh). Resolve it HERE — at source time,
# after BRIDGE_DATA_ROOT is known from the layout marker and before any of
# those callers snapshot it — so daemon and CLIs agree.
#
# The flip is gated on a dedicated sentinel written by the migrate's shared
# backfill (bridge_isolation_v2_migrate_shared_backfill), NOT on
# "$BRIDGE_DATA_ROOT/shared exists / is non-empty": a fresh v2 data/shared
# already carries _index/_audit skeletons and plugins-cache, so emptiness is
# not a reliable "not yet migrated" signal. Until the real shared tree has
# been mirrored into the data/-prefixed layout, BRIDGE_SHARED_DIR stays
# legacy so a marker-flipped-but-data-not-moved install keeps reading real
# content (avoids the v0.15 split-brain). An explicit env override always
# wins (the -z guard).
if [[ "$BRIDGE_LAYOUT" == "v2" && -n "$BRIDGE_DATA_ROOT" \
      && -z "${BRIDGE_SHARED_DIR:-}" \
      && -f "$BRIDGE_DATA_ROOT/.v2-shared-mirror.sentinel" ]]; then
  BRIDGE_SHARED_DIR="$BRIDGE_DATA_ROOT/shared"
fi

# Group names. Operator may override via env to fit local naming policy.
BRIDGE_SHARED_GROUP="${BRIDGE_SHARED_GROUP:-ab-shared}"
BRIDGE_CONTROLLER_GROUP="${BRIDGE_CONTROLLER_GROUP:-ab-controller}"
BRIDGE_AGENT_GROUP_PREFIX="${BRIDGE_AGENT_GROUP_PREFIX:-ab-agent-}"

# ---------------------------------------------------------------------------
# 2. helpers — environment / dispatch
# ---------------------------------------------------------------------------

# Source the platform discriminator (S3). Two-path source:
# - bridge-lib.sh flow sources `bridge-isolation-discriminator.sh` before
#   us, so the function already exists and the guard below is a no-op.
# - Standalone module callers (e.g. tests/isolation-v2-primitives/smoke.sh
#   sourcing this file directly without going through bridge-lib.sh)
#   need the discriminator brought in here so `bridge_isolation_v2_enforce`
#   call sites further down resolve. The discriminator is self-contained:
#   its `_platform` helper falls back to direct `uname -s` when
#   `bridge_host_platform` is not available.
if ! declare -f bridge_isolation_v2_enforce >/dev/null 2>&1; then
  _BRIDGE_V2_MODULE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  if [[ -f "$_BRIDGE_V2_MODULE_DIR/bridge-isolation-discriminator.sh" ]]; then
    # shellcheck source=bridge-isolation-discriminator.sh
    source "$_BRIDGE_V2_MODULE_DIR/bridge-isolation-discriminator.sh"
  fi
  unset _BRIDGE_V2_MODULE_DIR
fi

bridge_isolation_v2_active() {
  # Returns 0 (active) when BRIDGE_LAYOUT=v2 and BRIDGE_DATA_ROOT is set.
  #
  # v0.8.0 hard-cut: this is now an invariant/status helper, not a
  # runtime branching primitive. The layout resolver fail-fasts at
  # startup if v2 is not active, so any code path that reaches a
  # v2-helper call site is already guaranteed to be running under v2.
  # Callers should treat a `false` return here as a programmer error
  # surface (e.g. status reporting, smoke tests sourcing the module
  # standalone), not a signal to fall back to v1/ACL behavior — the
  # v1/ACL code paths were removed.
  [[ "$BRIDGE_LAYOUT" == "v2" ]] || return 1
  [[ -n "$BRIDGE_DATA_ROOT" ]] || return 1
  return 0
}

bridge_isolation_v2_shared_plugins_root_populated() {
  # Returns 0 only when:
  #   1. v2 mode is active, and
  #   2. BRIDGE_SHARED_ROOT is set, and
  #   3. $BRIDGE_SHARED_ROOT/plugins-cache exists, and
  #   4. it actually contains the canonical Claude catalog file.
  #
  # `[[ -d ... ]]` alone is not enough: an operator who created the
  # directory tree but has not yet copied controller catalog state into
  # it would fall through to the v2 path and the share helper would
  # write garbage. Require installed_plugins.json as the readiness
  # gate; known_marketplaces.json may legitimately be absent on a
  # single-marketplace install but installed_plugins.json is always
  # written by `claude` after the first plugin install.
  bridge_isolation_v2_active || return 1
  [[ -n "$BRIDGE_SHARED_ROOT" ]] || return 1
  local root="$BRIDGE_SHARED_ROOT/plugins-cache"
  [[ -d "$root" ]] || return 1
  [[ -f "$root/installed_plugins.json" ]] || return 1
  return 0
}

bridge_isolation_v2_shared_plugins_root() {
  # Print the v2 canonical Claude plugins root if populated, else
  # return non-zero so callers can fall back to the legacy
  # controller_home/.claude/plugins location. This is the only public
  # accessor — callers MUST NOT duplicate the plugins-cache path
  # contract elsewhere.
  bridge_isolation_v2_shared_plugins_root_populated || return 1
  printf '%s' "$BRIDGE_SHARED_ROOT/plugins-cache"
}

bridge_isolation_v2_agent_root() {
  # Print the v2 per-agent root path. Caller MUST gate on
  # bridge_isolation_v2_active first; this helper does not re-check.
  local agent="$1"
  [[ -n "$agent" && -n "${BRIDGE_AGENT_ROOT_V2:-}" ]] || return 1
  printf '%s/%s' "$BRIDGE_AGENT_ROOT_V2" "$agent"
}

bridge_isolation_v2_agent_credentials_dir() {
  # Controller-owned subtree under the per-agent root. Mode 2750: the
  # isolated UID can read launch-secrets.env via group r-x but cannot
  # write/rm/mv anything inside it. Parent (per-agent root) is also
  # mode 2750 root-owned, so the isolated UID has only group r-x at
  # the root level — it cannot rmdir/rename `credentials/` either,
  # even though it shares the agent group, because POSIX requires
  # write on the *parent* directory to remove or rename an entry
  # inside it. Controller writes that need to land under the
  # per-agent root (e.g. `runtime/history.env`) go through the
  # sudo-handoff path in lib/bridge-state.sh rather than relying on
  # group-write at the root.
  local agent="$1"
  local root
  root="$(bridge_isolation_v2_agent_root "$agent")" || return 1
  printf '%s/credentials' "$root"
}

bridge_isolation_v2_agent_secret_env_file() {
  # Path to the per-agent launch-secrets.env file, the controller-owned
  # KEY=VALUE shell-env file that bridge-run.sh sources before child
  # execution (bridge_isolation_v2_load_secret_env). Claude OAuth tokens
  # no longer use this tool-inherited env channel; bridge-auth.sh renders
  # them into the agent's Claude .credentials.json file and keeps only a
  # non-secret CLAUDE_CONFIG_DIR pointer here.
  local agent="$1"
  local credentials_dir
  credentials_dir="$(bridge_isolation_v2_agent_credentials_dir "$agent")" || return 1
  printf '%s/launch-secrets.env' "$credentials_dir"
}

bridge_isolation_v2_load_secret_env() {
  # Strict KEY=VALUE shell-env loader. Used by bridge-run.sh to inject
  # launch secrets into the current shell so they reach the child via
  # `export` without ever appearing in the LAUNCH_CMD string.
  #
  # Strict parse rules (refuse anything else, fail closed):
  #   - blank line: skip
  #   - comment line (^[[:space:]]*#): skip
  #   - KEY=VALUE: KEY must match [A-Z_][A-Z0-9_]*. VALUE may be:
  #       * unquoted (no whitespace, no quote, no $, no `, no \\)
  #       * single-quoted '...'  (literal, no escapes inside)
  #       * double-quoted "..." (literal but allows \" \\ and $ literal —
  #                              we deliberately do NOT expand $ here so
  #                              loaded files cannot exfiltrate other env)
  #
  # The strict shape blocks attempts to smuggle command substitution,
  # arithmetic expansion, parameter expansion, here-docs, or array
  # syntax through this loader.
  local file="$1"
  [[ -n "$file" ]] || {
    bridge_warn "load_secret_env: file required"
    return 1
  }
  [[ -f "$file" ]] || {
    bridge_warn "load_secret_env: file not found: $file"
    return 1
  }
  if [[ -r "$file" ]]; then
    :
  else
    bridge_warn "load_secret_env: cannot read $file"
    return 1
  fi
  # PR-C r2 (codex r1 B-3): reject secret files whose mode would allow
  # group write or world read. The launch-secrets.env contract is 0640
  # (controller-write, group-read, no other) per PR body §"Per-Agent
  # Root Layout"; anything broader is either a misconfigured deploy or
  # a tampering attempt and we MUST refuse to export from it. Probe
  # cross-platform: GNU `stat -c '%a'` first, BSD `stat -f '%Lp'` fallback.
  local _secret_mode=""
  _secret_mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)"
  case "$_secret_mode" in
    640|0640|600|0600|400|0400)
      : # acceptable — controller-write only, no group-write, no world-read
      ;;
    *)
      bridge_warn "load_secret_env: refusing $file (mode=${_secret_mode}, expected 0640/0600/0400)"
      return 1
      ;;
  esac
  local line key value lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # strip leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    # KEY=VALUE split on first =
    if [[ "$line" != *=* ]]; then
      bridge_warn "load_secret_env: $file:$lineno not KEY=VALUE form"
      return 1
    fi
    key="${line%%=*}"
    value="${line#*=}"
    if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
      bridge_warn "load_secret_env: $file:$lineno invalid KEY"
      return 1
    fi
    case "$value" in
      \'*\')
        # single-quoted literal
        value="${value:1:${#value}-2}"
        if [[ "$value" == *\'* ]]; then
          bridge_warn "load_secret_env: $file:$lineno embedded single-quote"
          return 1
        fi
        ;;
      \"*\")
        # double-quoted literal (we treat it literally; no $/`/\\ expansion)
        value="${value:1:${#value}-2}"
        case "$value" in
          *\$*|*\`*|*\\*)
            bridge_warn "load_secret_env: $file:$lineno disallowed metachar in double-quoted value"
            return 1
            ;;
        esac
        ;;
      *)
        # bare value: forbid whitespace, quotes, $, `, \\
        case "$value" in
          *[[:space:]]*|*\"*|*\'*|*\$*|*\`*|*\\*)
            bridge_warn "load_secret_env: $file:$lineno bare value contains disallowed character (use single-quotes)"
            return 1
            ;;
        esac
        ;;
    esac
    # export into current shell. Subshell `export` would not propagate.
    # shellcheck disable=SC2163
    export "$key=$value"
  done < "$file"
  return 0
}

bridge_isolation_v2_exec_with_secret_env() {
  # Subshell-wrap for bridge-run.sh's launch path. Loads launch secrets
  # inside a subshell, then `exec`s the agent command from the same
  # subshell so the secrets reach the child via `export` without ever
  # appearing in LAUNCH_CMD or persisting in the long-lived parent.
  #
  # PR-C r2 (codex r1 G-19): extracted from bridge-run.sh so the smoke
  # test exercises the EXACT production code path, not a re-implementation.
  #
  # Args:
  #   $1 secret_file   absolute path to launch-secrets.env
  #   $2 bash_bin      bash to use for `exec ... -lc <launch_cmd>`
  #   $3 launch_cmd    the agent launch command line
  #   $4 errfile       path to append child stderr to (via tee)
  #   $5 agent_name    agent id, used in the loader-failure bridge_die message
  #   $6 scrub_env_keys (optional) space-separated env var NAMES to `unset`
  #      AFTER the secret loader runs and BEFORE the `exec` — the
  #      managed-Codex ambient-key scrub (#1470 Q6 / codex r1 BLOCKING).
  #      The loader exports arbitrary KEY=VALUE rows from launch-secrets.env;
  #      without this a managed Codex agent could re-inherit OPENAI_API_KEY /
  #      CODEX_ACCESS_TOKEN from that file even though bridge-run.sh scrubbed
  #      the ambient env. Unsetting them HERE, inside the loader+exec
  #      subshell, guarantees the launched child sees them absent regardless
  #      of the launch-secrets.env content. Empty/unset → no scrub.
  #   $7 repin_env_pairs (optional) newline-separated KEY=VALUE assignments
  #      to `export` AFTER the scrub and BEFORE the `exec` — the dynamic
  #      vanilla Codex HOME/CODEX_HOME re-pin (#1899 Phase-4 BLOCKING).
  #      Unlike the scrub, which only *removes* a variable, the re-pin SETS
  #      it to an operator value. Scrubbing CODEX_HOME alone is insufficient
  #      for a dynamic vanilla Codex agent: the secrets file may carry a
  #      stale per-agent CODEX_HOME/HOME, and merely unsetting it would let
  #      the launch fall back to whatever HOME the loader left, not the
  #      operator-global ~/.codex the #1899 contract requires. So the caller
  #      passes the scrub keys (HOME CODEX_HOME) AND the re-pin pairs
  #      (HOME=<op_home>, CODEX_HOME=<op_home>/.codex); the scrub clears any
  #      stale value first, then the re-pin authoritatively sets the operator
  #      value. Each line is `KEY=VALUE` (value may contain '='; only the
  #      first '=' splits). Empty/unset → no re-pin.
  #
  # Side effects:
  #   - Sets BRIDGE_ISOLATION_V2_LAST_EXEC_RC to the child's exit code.
  #   - On loader failure, calls bridge_die (does not return).
  local _secret_file="$1"
  local _bash_bin="$2"
  local _launch_cmd="$3"
  local _errfile="$4"
  local _agent="$5"
  local _scrub_keys="${6:-}"
  local _repin_pairs="${7:-}"
  # PR-C r2 review P2 #1: cannot use the subshell exit code as the
  # loader-failure sentinel — the same subshell `exec`s the agent
  # command, so any legitimate child exit code (e.g. exit 75 from a
  # claude / codex process) would be misclassified as a secret-load
  # failure and call bridge_die. Use an out-of-band marker file that
  # only the loader-failure branch creates; the parent then checks the
  # marker independently of the exit code.
  local _fail_marker
  _fail_marker="$(mktemp "${TMPDIR:-/tmp}/agb-secret-fail.XXXXXX" 2>/dev/null || printf '%s' "/tmp/agb-secret-fail.$$.$RANDOM")"
  rm -f "$_fail_marker"
  local _rc=0
  if (
    bridge_isolation_v2_load_secret_env "$_secret_file" || {
      : 2>/dev/null > "$_fail_marker" || true
      exit 1
    }
    # #1470 Q6 (codex r1 BLOCKING): scrub the managed-Codex ambient keys
    # AFTER the loader (which may have re-exported them from
    # launch-secrets.env) and BEFORE the exec, so the launched child never
    # inherits them. `unset` removes both value and export attribute.
    if [[ -n "$_scrub_keys" ]]; then
      # shellcheck disable=SC2086  # intentional word-split of the name list
      unset $_scrub_keys 2>/dev/null || true
    fi
    # #1899 Phase-4 BLOCKING: re-pin the operator HOME/CODEX_HOME for a
    # dynamic vanilla Codex agent AFTER the scrub (which cleared any stale
    # launch-secrets.env value) and BEFORE the exec. The re-pin is the only
    # step that can SET the operator value — a scrub-only fix would leave
    # the child without an authoritative CODEX_HOME. Pairs are newline-
    # separated KEY=VALUE; only the first '=' splits so a value may contain '='.
    if [[ -n "$_repin_pairs" ]]; then
      local _repin_line _repin_key _repin_val
      while IFS= read -r _repin_line; do
        [[ -n "$_repin_line" ]] || continue
        _repin_key="${_repin_line%%=*}"
        _repin_val="${_repin_line#*=}"
        [[ -n "$_repin_key" && "$_repin_key" != "$_repin_line" ]] || continue
        export "$_repin_key=$_repin_val"
      done <<< "$_repin_pairs"
    fi
    exec "$_bash_bin" -lc "$_launch_cmd"
  ) 2> >(tee -a "$_errfile" >&2); then
    _rc=0
  else
    _rc=$?
  fi
  if [[ -f "$_fail_marker" ]]; then
    rm -f "$_fail_marker"
    bridge_die "isolation v2: failed to load launch secrets for '$_agent' from $_secret_file"
  fi
  rm -f "$_fail_marker"
  BRIDGE_ISOLATION_V2_LAST_EXEC_RC="$_rc"
  return 0
}

bridge_isolation_v2_agent_memory_daily_root() {
  # Per-agent memory-daily root. Lives inside the per-agent root so it
  # inherits the same isolation contract; the daily harvester writes
  # per-agent fragments here (group ab-shared, mode 2770) and the
  # controller-side reducer (`scripts/memory-daily-reduce.sh`) combines
  # fragments into the shared aggregate dir (#786 Finding 2 / Design A).
  local agent="$1"
  local root
  root="$(bridge_isolation_v2_agent_root "$agent")" || return 1
  printf '%s/runtime/memory-daily' "$root"
}

bridge_isolation_v2_memory_daily_shared_aggregate_dir() {
  # Canonical shared aggregate directory — controller-owned, group-readable.
  # Lives under shared/ so isolated UIDs may read but never write the
  # aggregate (design-r3 decision: shared writes are controller-only;
  # matrix row `shared-memory-daily-aggregate` is mode 2750 / r-x by
  # ab-shared). Per #786 Finding 2 (Design A), the controller-side reducer
  # `scripts/memory-daily-reduce.sh` is the sole writer — isolated harvester
  # invocations skip --shared-aggregate-dir and only emit per-agent
  # fragments under `<agent_root>/runtime/memory-daily/`. PR-C r3: contract
  # unified across all callers so prepare/migration grants the same path
  # the reducer writes, eliminating the parent-vs-child mismatch flagged
  # in r2 review finding P2 #2.
  [[ -n "$BRIDGE_SHARED_ROOT" ]] || return 1
  printf '%s/memory-daily/aggregate' "$BRIDGE_SHARED_ROOT"
}

bridge_isolation_v2_agent_group_name() {
  local agent="$1"
  [[ -n "$agent" ]] || {
    bridge_warn "agent_group_name: agent name required"
    return 1
  }
  # Linux groupadd accepts [a-z_][a-z0-9_-]* with total length <= 32.
  # Reject early so _ensure_group does not fail opaquely later.
  if [[ ! "$agent" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    bridge_warn "agent_group_name: '$agent' has invalid chars for a group name (allowed: [a-z_][a-z0-9_-]*)"
    return 1
  fi
  local composed="${BRIDGE_AGENT_GROUP_PREFIX}${agent}"
  # v0.8.4: platform-branched length policy.
  # - macOS: dseditgroup tolerates 255-char names; pass through unchanged.
  # - Linux: groupadd hard-caps at 32 chars. v0.8.3 hard-rejected; v0.8.4
  #   deterministically hash-truncates so any name accepted by `agent
  #   create` composes to a unique <=32-char group. The agent name
  #   segment is reduced to `<first-N-chars>-<7-char-sha256>` where the
  #   hash is taken over the full untruncated name; two agents whose
  #   names share the first N chars but differ later still get distinct
  #   group names because the hash discriminates.
  if [[ "$(uname)" == "Darwin" ]]; then
    if (( ${#composed} > 255 )); then
      bridge_warn "agent_group_name: '$composed' exceeds 255-char group-name limit on Darwin"
      return 1
    fi
    printf '%s' "$composed"
    return 0
  fi
  if (( ${#composed} <= 32 )); then
    printf '%s' "$composed"
    return 0
  fi
  local _prefix_len=${#BRIDGE_AGENT_GROUP_PREFIX}
  local _avail=$(( 32 - _prefix_len ))
  # Need at least 1 char + '-' + 7-char hash = 9 chars for the segment.
  if (( _avail < 9 )); then
    bridge_warn "agent_group_name: BRIDGE_AGENT_GROUP_PREFIX '$BRIDGE_AGENT_GROUP_PREFIX' leaves no room (${_avail}) for a hash-truncated agent segment under the 32-char Linux limit"
    return 1
  fi
  local _keep=$(( _avail - 1 - 7 ))
  local _hash
  _hash="$(bridge_isolation_v2_short_sha256 "$agent" 7)" || {
    bridge_warn "agent_group_name: short-sha256 hash failed for '$agent'"
    return 1
  }
  local _head="${agent:0:_keep}"
  # Tail dashes/underscores before the inserted '-' would produce '--' or
  # '_-'; both are still valid for groupadd ([a-z_][a-z0-9_-]*) but the
  # leading char of $_head is taken from the original agent name which
  # already passed the [a-z_] anchor regex above, so the composed name
  # remains policy-compliant.
  printf '%s%s-%s' "$BRIDGE_AGENT_GROUP_PREFIX" "$_head" "$_hash"
}

bridge_isolation_v2_short_sha256() {
  # Emit the first <len> hex chars of sha256(<text>). Used by
  # bridge_isolation_v2_agent_group_name to compose a deterministic
  # collision-resistant suffix when the raw agent name plus prefix would
  # exceed Linux's 32-char group-name limit.
  local text="$1"
  local len="${2:-7}"
  [[ "$len" =~ ^[0-9]+$ ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$text" "$len" <<'PY'
import hashlib, sys
text, length = sys.argv[1], int(sys.argv[2])
print(hashlib.sha256(text.encode("utf-8")).hexdigest()[:length])
PY
    return $?
  fi
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | cut -c "1-${len}"
    return $?
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | cut -c "1-${len}"
    return $?
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 3. group / membership ensure helpers
# ---------------------------------------------------------------------------

bridge_isolation_v2_group_exists() {
  # Returns 0 if the named group exists. Works without root. Dispatches by
  # `uname` so macOS (no getent) uses dscl. The Darwin path probes
  # /Local/Default first; OD-bound directories (corp LDAP) would also
  # need a `dscl /Search` fallback but that is not in the v0.8.0 scope.
  local name="$1"
  [[ -n "$name" ]] || return 1
  if [[ "$(uname)" == "Darwin" ]]; then
    bridge_isolation_v2_darwin_group_exists "$name"
    return $?
  fi
  getent group "$name" >/dev/null 2>&1
}

bridge_isolation_v2_darwin_group_exists() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  dscl . -read "/Groups/$name" PrimaryGroupID >/dev/null 2>&1
}

bridge_isolation_v2_darwin_group_gid() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  dscl . -read "/Groups/$name" PrimaryGroupID 2>/dev/null \
    | awk '/^PrimaryGroupID:/ {print $2}'
}

bridge_isolation_v2_darwin_ensure_group() {
  # Idempotent group create on macOS via `dseditgroup`. `-o create -r
  # <real-name>` requires admin; we try direct first then sudo -n. The
  # `-r` value is the human-readable RealName attribute — the spec
  # suggests "Agent Bridge agent <n>" so DS browsers show provenance.
  local name="$1"
  local realname="${2:-Agent Bridge group $name}"
  [[ -n "$name" ]] || {
    bridge_warn "darwin_ensure_group: name required"
    return 1
  }
  if bridge_isolation_v2_darwin_group_exists "$name"; then
    return 0
  fi
  if dseditgroup -o create -r "$realname" -t group "$name" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n dseditgroup -o create -r "$realname" -t group "$name" 2>/dev/null; then
      return 0
    fi
  fi
  bridge_warn "darwin_ensure_group: cannot create '$name' (need admin or passwordless sudo)"
  return 1
}

bridge_isolation_v2_darwin_ensure_user_in_group() {
  # Idempotent supplementary membership add on macOS via `dseditgroup
  # edit -a <user> -t user <group>`. Like Linux, already-running shells
  # do NOT pick up the new membership — operators must re-login or
  # caller must restart the relevant process trees.
  local user="$1"
  local group="$2"
  [[ -n "$user" && -n "$group" ]] || {
    bridge_warn "darwin_ensure_user_in_group: user and group required"
    return 1
  }
  # Check membership via `dseditgroup -o checkmember`. Returns 0 with
  # "yes <user> is a member of <group>" on stdout when present.
  if dseditgroup -o checkmember -m "$user" "$group" 2>/dev/null \
      | grep -q '^yes'; then
    return 0
  fi
  if dseditgroup -o edit -a "$user" -t user "$group" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n dseditgroup -o edit -a "$user" -t user "$group" 2>/dev/null; then
      return 0
    fi
  fi
  bridge_warn "darwin_ensure_user_in_group: cannot add '$user' to '$group' (need admin or passwordless sudo)"
  return 1
}

bridge_isolation_v2_user_in_group() {
  # Returns 0 if the named user is a member of the named group. Reads
  # the static nss view (does NOT see supplementary groups picked up by
  # already-running processes; for that, run `id -nG <user>` from a
  # fresh shell).
  local user="$1"
  local group="$2"
  [[ -n "$user" && -n "$group" ]] || return 1
  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$group"
}

bridge_isolation_v2_ensure_group() {
  # Idempotent: create the group if it does not exist. On Linux requires
  # root or passwordless `sudo groupadd`; on macOS requires admin or
  # passwordless `sudo dseditgroup` (handled by darwin helper). Returns
  # 0 on success or pre-existing.
  local name="$1"
  [[ -n "$name" ]] || {
    bridge_warn "bridge_isolation_v2_ensure_group: name required"
    return 1
  }
  if bridge_isolation_v2_group_exists "$name"; then
    return 0
  fi
  if [[ "$(uname)" == "Darwin" ]]; then
    bridge_isolation_v2_darwin_ensure_group "$name"
    return $?
  fi
  # groupadd -r returns 9 when the group already exists. The pre-check
  # above covers the common case but a TOCTOU window between
  # group_exists and groupadd lets rc=9 leak through under concurrent
  # prepare runs; treat it as success.
  local rc
  if [[ "$(id -u)" -eq 0 ]]; then
    if ! groupadd -r "$name"; then
      rc=$?
      [[ $rc -eq 9 ]] || return 1
    fi
  else
    if ! sudo -n groupadd -r "$name" 2>/dev/null; then
      rc=$?
      if [[ $rc -ne 9 ]]; then
        bridge_warn "ensure_group: cannot create '$name' (need root or passwordless sudo)"
        return 1
      fi
    fi
  fi
  return 0
}

bridge_isolation_v2_ensure_user_in_group() {
  # Idempotent: add user to group as a supplementary member if not
  # already present. WARNING: already-running shells/daemons do NOT
  # pick up new supplementary groups. On macOS the supplementary group
  # cache is per-login, so changes only take effect after the affected
  # user re-logins (handled by the migration tool's
  # migration_requires_relogin flag). Caller must restart the relevant
  # process trees on Linux.
  local user="$1"
  local group="$2"
  [[ -n "$user" && -n "$group" ]] || {
    bridge_warn "ensure_user_in_group: user and group required"
    return 1
  }
  if bridge_isolation_v2_user_in_group "$user" "$group"; then
    return 0
  fi
  if [[ "$(uname)" == "Darwin" ]]; then
    bridge_isolation_v2_darwin_ensure_user_in_group "$user" "$group"
    return $?
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    usermod -aG "$group" "$user"
  else
    sudo -n usermod -aG "$group" "$user" 2>/dev/null || {
      bridge_warn "ensure_user_in_group: cannot add '$user' to '$group' (need root or passwordless sudo)"
      return 1
    }
  fi
}

# ---------------------------------------------------------------------------
# 4. mode / chgrp / setgid helpers
# ---------------------------------------------------------------------------

_bridge_isolation_v2_run_root_or_sudo() {
  # Run the given command directly when permitted (root, or POSIX
  # permits the operation for the caller — e.g. owner changing to
  # their own primary group), otherwise fall back to passwordless
  # sudo.
  #
  # Direct-first matters for rootless cases: a non-root user can
  # `chgrp` to one of their own groups and `chmod` files they own
  # without sudo. Forcing `sudo -n` would block both the regression
  # smoke (caller's primary group on a tempdir tree) and any
  # non-root operator workflow when sudo is intentionally absent.
  if "$@" 2>/dev/null; then
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    sudo -n "$@" 2>/dev/null && return 0
  fi
  return 1
}

# _bridge_isolation_v2_realpath <path>
#
# Portable canonical path resolution. GNU coreutils `realpath` (Linux
# default) supports `-m` for non-existent leaves; BSD `realpath` (macOS
# default) does not even support `-m`. Both will resolve every existing
# component. When neither flavor produces output (e.g. a missing leaf
# under a missing parent on BSD), fall back to Python's `os.path.realpath`
# which handles non-existent leaves uniformly across platforms.
#
# Emits the canonical path on stdout; returns 0 even when resolution
# yields a best-effort result. Returns 1 only when no resolver is
# available at all (no realpath binary AND no python3 — defensively
# impossible on supported hosts but kept for safety).
_bridge_isolation_v2_realpath() {
  local p="$1"
  local out=""
  if command -v realpath >/dev/null 2>&1; then
    # Try GNU `-m` first (handles non-existent leaves). On BSD realpath
    # this errors; fall through to bare realpath which works on existing
    # paths and most one-level-missing-leaf cases via parent resolution.
    out="$(realpath -m -- "$p" 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
      out="$(realpath -- "$p" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$out" ]] && command -v python3 >/dev/null 2>&1; then
    # NOTE: do not insert ``--`` between ``-c '<script>'`` and the
    # argument — ``python3 -c`` does NOT honor ``--`` as an end-of-options
    # marker. ``sys.argv[1]`` would then be the literal string ``--`` and
    # the real path would be silently dropped. Pass the path directly.
    out="$(python3 -c 'import os, sys; sys.stdout.write(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null || true)"
  fi
  if [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  # Last-resort fallback: emit the input unchanged. Callers that compare
  # canonical-against-canonical will treat a "no resolver available" host
  # as failing the canonical check (different paths compare unequal),
  # which is the safe direction — refuse the mutation.
  printf '%s' "$p"
  return 1
}

# _bridge_isolation_v2_assert_no_symlink_in_path <leaf> <workdir>
#
# Refuse any symlink along the path from $workdir (inclusive of children,
# exclusive of $workdir itself) up to and including $leaf. Also refuse
# when the canonical resolution of $leaf escapes the canonical of
# $workdir.
#
# Codex r1 BLOCKING (PR #1335 r1): the previous leaf-only `[[ -L $file ]]`
# guard in `chown_file_iso_uid` and `chgrp_dir_iso_group` only rejected
# the LEAF as a symlink. If an ANCESTOR was a symlink (e.g.
# ``.claude/plugins -> /tmp/outside``), the leaf
# (``/tmp/outside/known_marketplaces.json``) was a regular file — and the
# chmod/chgrp/chown calls mutated the EXTERNAL target while logging
# "refusing to follow symlink" on the leaf check (which passed because
# the leaf itself was not a symlink). This violated the symlink_refusal
# contract and created side effects outside the workdir.
#
# Per Sean's quality directive (2026-05-28): "refuse all symlinks in
# path" — do NOT follow even within-workdir symlinks. The contract is
# simpler and impossible to bypass with symlink-chain trickery.
#
# Returns:
#   0 — path is safe (no symlinks anywhere from workdir/* to leaf, AND
#       canonical leaf is under canonical workdir).
#   1 — refuse (caller should bridge_warn and return WITHOUT mutating).
#
# Edge cases handled:
#   * Symlink chains (.../a -> /b -> /c -> outside): every level
#     is checked individually via `-L`; any link in chain → refuse.
#   * Relative symlinks (.claude/plugins -> ../../../etc): canonical
#     resolution catches the escape; ancestor walk catches the symlink
#     itself.
#   * Workdir itself contains symlinks (operator-set): canonical check
#     compares resolved-leaf prefix against resolved-workdir; a workdir
#     under /var/folders/X-symlinked-to-/private/var/folders/X (macOS)
#     resolves consistently on both sides → safe.
#   * Symlink to within-workdir (.claude/plugins -> .claude/cache):
#     ancestor walk sees `.claude/plugins` IS a symlink → REFUSE. This
#     is the deliberate-stricter contract per Sean's directive.
#   * Non-existent leaf under existing parent: `-L $leaf` returns false
#     (no entry), so leaf check passes; ancestor walk still inspects all
#     existing parent components.
#
# Caller contract: $leaf is an absolute path under $workdir; $workdir is
# an absolute path. Both arguments are required.
_bridge_isolation_v2_assert_no_symlink_in_path() {
  local leaf="$1"
  local workdir="$2"
  [[ -n "$leaf" && -n "$workdir" ]] || return 1

  # Canonical containment check. Resolve both ends; the canonical leaf
  # MUST sit under the canonical workdir + '/'. Use the realpath helper
  # which falls through to Python when neither GNU `-m` nor BSD bare
  # realpath produces output (missing-leaf-under-missing-parent on BSD).
  local can_leaf can_workdir
  can_leaf="$(_bridge_isolation_v2_realpath "$leaf" || printf '%s' "$leaf")"
  can_workdir="$(_bridge_isolation_v2_realpath "$workdir" || printf '%s' "$workdir")"
  # The canonical workdir + '/' prefix match (NOT a substring match) so
  # `/var/agent-bridge` does not match `/var/agent-bridge-other/...`.
  case "$can_leaf" in
    "$can_workdir"|"$can_workdir"/*) : ;;
    *)
      bridge_warn "iso-v2: refusing — canonical path escapes workdir (leaf='$leaf' canonical='$can_leaf' workdir='$workdir' canonical_workdir='$can_workdir')"
      return 1
      ;;
  esac

  # Ancestor symlink walk. Inspect every node from $leaf upward, stopping
  # ONE level above $workdir (we do not inspect $workdir itself — operator
  # may legitimately have a symlinked workdir root and the canonical check
  # above already proved no path-escape). Each `-L $current` test runs
  # under the controller UID so it sees the real fs view.
  local current="$leaf"
  local guard=0
  while [[ "$current" != "$workdir" && "$current" != "/" && "$current" != "." ]]; do
    if [[ -L "$current" ]]; then
      bridge_warn "iso-v2: refusing — symlink in ancestor path (component='$current' leaf='$leaf' workdir='$workdir')"
      return 1
    fi
    current="$(dirname -- "$current")"
    # Hard guard against pathological recursion (symlink loops via
    # dirname are not possible, but defensive against truncated paths).
    guard=$((guard + 1))
    if (( guard > 4096 )); then
      bridge_warn "iso-v2: refusing — ancestor walk exceeded depth guard for '$leaf' (workdir='$workdir')"
      return 1
    fi
  done

  return 0
}

bridge_isolation_v2_chgrp_setgid_dir() {
  # Apply group ownership + setgid bit + mode to a single directory.
  # Idempotent. Honors mode argument (e.g. 2750 for shared, 2770 for
  # per-agent private). Direct-first (POSIX-permitted operation by
  # caller) before falling back to sudo, so the rootless primary-
  # group regression path works without sudo.
  local group="$1"
  local mode="$2"
  local dir="$3"
  [[ -n "$group" && -n "$mode" && -n "$dir" ]] || {
    bridge_warn "chgrp_setgid_dir: group, mode, and dir required"
    return 1
  }
  [[ -d "$dir" ]] || {
    bridge_warn "chgrp_setgid_dir: not a directory: $dir"
    return 1
  }
  # Platform discriminator gate (S3): chgrp + setgid bit are POSIX
  # primitives that only have a security model on Linux. On non-Linux
  # hosts (default: macOS) this is a silent no-op so callers see
  # success rather than chgrp-failure noise. Audit C07 (Bucket 2).
  bridge_isolation_v2_enforce || return 0
  _bridge_isolation_v2_run_root_or_sudo chgrp "$group" "$dir" || return 1
  _bridge_isolation_v2_run_root_or_sudo chmod "$mode" "$dir" || return 1
}

# bridge_isolation_v2_chgrp_file_iso_group <agent> <file> [mode] [workdir]
#
# Normalize a single per-agent file's group + mode to the per-agent
# isolation group (``ab-agent-<a>``) at mode ``0660`` (operator-overridable
# via the third arg). Issue #1270 (v0.15.0-beta4 Lane G): the
# ``CLAUDE.md`` that ``bridge_layout_materialize_identity`` materializes
# into the v2 ``workdir/`` inherits the controller's primary group and
# mode 0600 from the ``cp -f`` source. Every OTHER iso workdir file
# (.teams/.env, channel-state .env etc.) is grouped to ``ab-agent-<a>``
# at mode 0660 so the controller — a member of that group — can grep /
# read the file. Without this normalization, ``agent start``'s
# controller-side grep on ``$workdir/CLAUDE.md`` emits a cosmetic
# ``Permission denied`` warning on every start.
#
# Contract:
#   * Linux v2 isolation only. ``bridge_isolation_v2_enforce`` skips the
#     call on non-Linux hosts (macOS no-op) and when the agent is in
#     shared isolation mode. The caller is responsible for gating on
#     ``bridge_agent_linux_user_isolation_effective`` BEFORE this call;
#     calling it for a shared-mode agent silently returns 0.
#   * Idempotent: re-running the chgrp/chmod on an already-normalized
#     file is a no-op — the stat-skip below short-circuits the mutation
#     entirely so a Lane α back-fill pass over an already-normalized
#     workdir performs zero ``chgrp`` / ``chmod`` syscalls (codex r1
#     BLOCKING on PR #1302). ``%G:%a`` is read with the existing portable
#     stat pattern (GNU ``-c`` vs BSD ``-f``); mode strings are compared
#     octal-to-octal via ``printf %o`` so ``0660`` vs ``660`` parses the
#     same way.
#   * Defensive symlink refusal: refuse ANY symlink in the ancestor path
#     from ``$workdir`` to ``$file`` (inclusive of leaf), and refuse when
#     the canonical resolution of ``$file`` escapes ``$workdir``. PR #1335
#     r3 (codex r2 BLOCKING): the leaf-only ``[[ -L $file ]]`` guard
#     pattern that r2 closed in the sibling chown/chgrp_dir helpers was
#     still missing here. Direct codex r2 repro: ``work/CLAUDE.md ->
#     /tmp/out/CLAUDE.md`` (leaf-as-symlink to external target), pre-r3
#     normalize mutated the external target to ``staff:660`` because the
#     materialize-fileset loop fed the path here WITHOUT a workdir and
#     the helper had no ancestor-walk gate at all. The fourth ``$workdir``
#     argument is REQUIRED to engage the ancestor walk; calling without
#     it logs a bridge_warn and falls back to the legacy leaf-only check
#     (no behavior change for legacy callers, but they are now visible in
#     logs).
#   * Returns 0 when there is no work to do (file missing, agent group
#     cannot be resolved, or platform discriminator says non-Linux).
#     Only an explicit chgrp/chmod failure returns 1.
bridge_isolation_v2_chgrp_file_iso_group() {
  local agent="$1"
  local file="$2"
  local mode="${3:-0660}"
  local workdir="${4:-}"
  [[ -n "$agent" && -n "$file" ]] || {
    bridge_warn "chgrp_file_iso_group: agent and file required"
    return 1
  }
  # Platform discriminator gate (S3): no-op on non-Linux hosts the same
  # way bridge_isolation_v2_chgrp_setgid_dir gates. Returning 0 keeps
  # the caller's happy path simple.
  bridge_isolation_v2_enforce || return 0
  # Ancestor symlink walk + canonical containment (PR #1335 r3, codex r2
  # BLOCKING). When the caller passes ``$workdir`` (current behavior for
  # ``bridge_isolation_v2_normalize_workdir_profile_group``), refuse if
  # ANY component along $workdir → $file is a symlink, OR if the
  # canonical resolved $file escapes $workdir. This closes the
  # ``work/CLAUDE.md -> /tmp/out/CLAUDE.md`` bypass where the external
  # target got mutated despite no symlink gate at all. Legacy callers
  # (no workdir) fall back to the leaf-only check with a deprecation
  # warning — same pattern as chown_file_iso_uid / chgrp_dir_iso_group.
  if [[ -n "$workdir" ]]; then
    if ! _bridge_isolation_v2_assert_no_symlink_in_path "$file" "$workdir"; then
      bridge_warn "chgrp_file_iso_group: refusing $file under workdir=$workdir (symlink-in-path or canonical-escape; operator must repair the symlink chain before re-running)"
      return 0
    fi
  else
    bridge_warn "chgrp_file_iso_group: legacy leaf-only symlink check (no workdir argument) at $file — pass workdir to engage ancestor-walk protection"
    if [[ -L "$file" ]]; then
      bridge_warn "chgrp_file_iso_group: refusing to follow symlink at $file"
      return 0
    fi
  fi
  [[ -f "$file" ]] || return 0
  local agent_grp=""
  agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
  [[ -n "$agent_grp" ]] || return 0
  # Idempotent stat-skip (codex r1 BLOCKING on PR #1302). Already-correct
  # files must not produce chgrp/chmod syscalls — the Lane α back-fill
  # loop calls this helper for every materialize-fileset entry on every
  # upgrade pass, and unconditional mutations are observable to the smoke
  # via the T_idempotent_no_mutation counter. Cross-platform stat: GNU
  # ``-c '%G:%a'`` vs BSD ``-f '%Sg:%Lp'``. Mode normalization handles
  # both `0660` (caller arg) and `660` (stat output) by reducing to
  # printf %o on both sides. Empty cur (stat failed — e.g. permission
  # denied on a file the controller cannot stat directly) falls through
  # to the mutation path which retries via sudo.
  local cur=""
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    cur="$(stat -f '%Sg:%Lp' "$file" 2>/dev/null || printf '')"
  else
    cur="$(stat -c '%G:%a' "$file" 2>/dev/null || printf '')"
  fi
  if [[ -n "$cur" ]]; then
    local cur_grp="${cur%%:*}"
    local cur_mode_raw="${cur##*:}"
    local cur_mode_norm="" want_mode_norm=""
    cur_mode_norm="$(printf '%o' "$((8#${cur_mode_raw#0}))" 2>/dev/null || printf '%s' "$cur_mode_raw")"
    want_mode_norm="$(printf '%o' "$((8#${mode#0}))" 2>/dev/null || printf '%s' "$mode")"
    if [[ "$cur_grp" == "$agent_grp" && "$cur_mode_norm" == "$want_mode_norm" ]]; then
      return 0
    fi
  fi
  _bridge_isolation_v2_run_root_or_sudo chgrp "$agent_grp" "$file" || return 1
  _bridge_isolation_v2_run_root_or_sudo chmod "$mode" "$file" || return 1
  return 0
}

# bridge_isolation_v2_chgrp_dir_iso_group <agent> <dir> [mode] [workdir]
#
# Normalize a single per-agent DIRECTORY's group + mode to the per-agent
# isolation group (``ab-agent-<a>``) at mode ``2770`` (operator-overridable
# via the third arg). Issue #1316 (v0.15.0-beta5-2 Lane θ): the legacy
# `mkdir -p "$workdir/.claude"` in bridge-agent.sh ran under the controller
# umask and left ``.claude/`` at ``0700 controller:controller`` (or
# ``0700 iso-uid:controller-gid`` after Step A chowned the parent). On
# the upgrade path that directory is never re-normalized — and the
# controller (a member of ``ab-agent-<a>`` but NOT the iso UID's primary
# group) cannot traverse it, so ``bridge-start.sh``'s pre-launch grep on
# ``$workdir/.claude/settings.json`` fails with EACCES.
#
# Mirrors ``bridge_isolation_v2_chgrp_file_iso_group`` semantics:
#   * Linux v2 isolation only (gated via ``bridge_isolation_v2_enforce``).
#   * Idempotent — stat-skip on already-correct ``%G:%a`` short-circuits
#     to zero syscalls.
#   * Defensive symlink refusal: refuse ANY symlink in the ancestor path
#     from ``$workdir`` to ``$dir`` (inclusive of leaf), and refuse when
#     the canonical resolution of ``$dir`` escapes ``$workdir``. PR #1335
#     r2 (codex r1 BLOCKING): the leaf-only ``[[ -L $dir ]]`` guard
#     allowed an ancestor symlink (``.claude/plugins -> /tmp/outside``)
#     to bypass the refusal because the leaf was a regular file in the
#     external target — the chmod/chgrp then mutated the external tree.
#     Per Sean's quality directive (2026-05-28): refuse all symlinks in
#     path. The fourth ``$workdir`` argument is REQUIRED to engage the
#     ancestor walk; calling without it logs a bridge_warn and falls
#     back to the legacy leaf-only check (no behavior change for
#     legacy callers, but they are now visible in logs).
#   * Failure on chgrp/chmod returns 1; "target missing" returns 0.
#
# Default mode 2770 = group rwx + setgid bit so newly-created child
# files/dirs inherit ``ab-agent-<a>``. The setgid bit is essential here:
# files Claude writes under ``.claude/`` (settings.local.json, cache
# entries, ...) must land at ``ab-agent-<a>`` group, otherwise the
# controller loses read access on every fresh write.
bridge_isolation_v2_chgrp_dir_iso_group() {
  local agent="$1"
  local dir="$2"
  local mode="${3:-2770}"
  local workdir="${4:-}"
  [[ -n "$agent" && -n "$dir" ]] || {
    bridge_warn "chgrp_dir_iso_group: agent and dir required"
    return 1
  }
  # Platform discriminator gate (S3): no-op on non-Linux hosts the same
  # way the sibling helpers gate. Returning 0 keeps the caller's happy
  # path simple.
  bridge_isolation_v2_enforce || return 0
  # Ancestor symlink walk + canonical containment (PR #1335 r2, codex r1
  # BLOCKING). When the caller passes ``$workdir`` (current behavior for
  # ``bridge_isolation_v2_normalize_workdir_profile_group``), refuse the
  # mutation if ANY component along $workdir → $dir is a symlink, OR if
  # the canonical resolved $dir escapes $workdir. This closes the
  # ``.claude/plugins -> /tmp/outside`` bypass that left the legacy
  # leaf-only check passing while the external target got mutated.
  if [[ -n "$workdir" ]]; then
    if ! _bridge_isolation_v2_assert_no_symlink_in_path "$dir" "$workdir"; then
      bridge_warn "chgrp_dir_iso_group: refusing $dir under workdir=$workdir (symlink-in-path or canonical-escape; operator must repair the symlink chain before re-running)"
      return 0
    fi
  else
    # Legacy direct-caller path (no workdir): leaf-only symlink check.
    # Future code must pass workdir to get full ancestor-walk protection.
    bridge_warn "chgrp_dir_iso_group: legacy leaf-only symlink check (no workdir argument) at $dir — pass workdir to engage ancestor-walk protection"
    if [[ -L "$dir" ]]; then
      bridge_warn "chgrp_dir_iso_group: refusing to follow symlink at $dir (operator must remove the symlink before re-running)"
      return 0
    fi
  fi
  [[ -d "$dir" ]] || return 0
  local agent_grp=""
  agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
  [[ -n "$agent_grp" ]] || return 0
  # Idempotent stat-skip — mirrors the chgrp_file_iso_group pattern. A
  # back-fill pass over an already-normalized .claude/ tree must perform
  # zero ``chgrp`` / ``chmod`` syscalls. Mode comparison normalizes both
  # sides to printf %o so ``2770`` vs ``02770`` parses the same.
  #
  # macOS-setgid-strip note: when the caller-requested mode includes the
  # setgid bit (e.g. 2770) and the host is macOS owning the dir with its
  # primary group, BSD silently strips the setgid bit on chmod — leaving
  # the on-disk mode at 0770. A naive equality check would force a
  # re-chmod on every pass even though the kernel WILL strip it again,
  # producing an infinite-non-idempotent loop. Treat a mode-without-
  # setgid as a match for a setgid-requested mode on macOS so the
  # stat-skip engages.
  local cur=""
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    cur="$(stat -f '%Sg:%Lp' "$dir" 2>/dev/null || printf '')"
  else
    cur="$(stat -c '%G:%a' "$dir" 2>/dev/null || printf '')"
  fi
  if [[ -n "$cur" ]]; then
    local cur_grp="${cur%%:*}"
    local cur_mode_raw="${cur##*:}"
    local cur_mode_norm="" want_mode_norm=""
    cur_mode_norm="$(printf '%o' "$((8#${cur_mode_raw#0}))" 2>/dev/null || printf '%s' "$cur_mode_raw")"
    want_mode_norm="$(printf '%o' "$((8#${mode#0}))" 2>/dev/null || printf '%s' "$mode")"
    if [[ "$cur_grp" == "$agent_grp" && "$cur_mode_norm" == "$want_mode_norm" ]]; then
      return 0
    fi
    # macOS setgid-strip tolerance: on Darwin, when the requested mode
    # carries the setgid bit (numeric value >= 2000 octal) but the dir
    # mode bits sans setgid already match the request, treat as
    # already-normalized. The kernel will keep stripping setgid on every
    # chmod-attempt, so re-firing the chmod is a guaranteed no-op +
    # wasted syscall.
    if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
      local want_low cur_low
      want_low="$(printf '%o' "$(( 8#${want_mode_norm} & 8#0777 ))" 2>/dev/null || printf '')"
      cur_low="$(printf '%o' "$(( 8#${cur_mode_norm} & 8#0777 ))" 2>/dev/null || printf '')"
      local want_has_setgid=0
      if (( 8#${want_mode_norm} >= 8#2000 )); then
        want_has_setgid=1
      fi
      if [[ "$cur_grp" == "$agent_grp" \
            && "$want_has_setgid" == "1" \
            && -n "$want_low" && "$want_low" == "$cur_low" ]]; then
        return 0
      fi
    fi
  fi
  _bridge_isolation_v2_run_root_or_sudo chgrp "$agent_grp" "$dir" || return 1
  _bridge_isolation_v2_run_root_or_sudo chmod "$mode" "$dir" || return 1
  return 0
}

# bridge_isolation_v2_chown_file_iso_uid <agent> <file> [mode] [workdir]
#
# Normalize a single per-agent FILE owned by ``root`` (or any non-iso
# UID) to ``agent-bridge-<a>:ab-agent-<a> 0660`` (operator-overridable
# via the third arg). Issue #1315 (v0.15.0-beta5-2 Lane θ): on the
# upgrade path the legacy ``known_marketplaces.json`` was seeded as
# ``root:ab-agent-<a> 640`` by ``bridge_write_isolated_known_marketplaces_catalog``.
# Issue #1278 (Lane H beta4) fixed the create-path to write
# ``iso-uid:ab-agent-<a> 0660`` so the iso UID's
# ``bridge-dev-plugin-cache.py:update_known_marketplaces`` rename
# (``tmp.write_text`` + ``os.replace``) succeeds. But the upgrade
# back-fill loop never re-owned the legacy file; first agent start fails
# silently with EPERM on rename.
#
# This helper is the upgrade-side mirror of the create-path
# chown+chgrp+chmod chain at ``bridge_write_isolated_known_marketplaces_catalog:2251-2253``.
# It uses ``bridge_linux_sudo_root chown`` because the controller UID
# typically cannot chown a root-owned file directly.
#
# Mirrors ``bridge_isolation_v2_chgrp_file_iso_group`` semantics:
#   * Linux v2 isolation only (gated via ``bridge_isolation_v2_enforce``).
#   * Idempotent — stat-skip on already-correct ``%U:%G:%a`` short-circuits
#     to zero syscalls.
#   * Defensive symlink refusal: refuse ANY symlink in the ancestor path
#     from ``$workdir`` to ``$file`` (inclusive of leaf), and refuse
#     when the canonical resolution of ``$file`` escapes ``$workdir``.
#     PR #1335 r2 (codex r1 BLOCKING): direct repro showed
#     ``.claude/plugins -> /tmp/outside`` +
#     ``/tmp/outside/known_marketplaces.json mode 0640 wheel:wheel`` →
#     normalize logged "refusing symlink" on the leaf check (which
#     passed because the leaf itself was not a symlink) BUT still
#     mutated the external target to mode 0660. The fourth
#     ``$workdir`` arg is REQUIRED to engage the ancestor walk;
#     calling without it logs a bridge_warn and falls back to the
#     legacy leaf-only check.
#   * Failure on chown/chgrp/chmod returns 1; "target missing" returns 0.
#   * Requires ``bridge_agent_os_user`` to resolve the iso UID. When the
#     resolver returns empty (shared-mode agent or fresh non-iso install)
#     this helper returns 0 — no-op, not failure.
bridge_isolation_v2_chown_file_iso_uid() {
  local agent="$1"
  local file="$2"
  local mode="${3:-0660}"
  local workdir="${4:-}"
  [[ -n "$agent" && -n "$file" ]] || {
    bridge_warn "chown_file_iso_uid: agent and file required"
    return 1
  }
  bridge_isolation_v2_enforce || return 0
  # Ancestor symlink walk + canonical containment (PR #1335 r2, codex r1
  # BLOCKING). When the caller passes ``$workdir`` (current behavior for
  # ``bridge_isolation_v2_normalize_workdir_profile_group``), refuse if
  # ANY component along $workdir → $file is a symlink, OR if the
  # canonical resolved $file escapes $workdir. This closes the
  # ``.claude/plugins -> /tmp/outside`` bypass where the external
  # target got mutated despite the leaf-only "refusing symlink" log.
  if [[ -n "$workdir" ]]; then
    if ! _bridge_isolation_v2_assert_no_symlink_in_path "$file" "$workdir"; then
      bridge_warn "chown_file_iso_uid: refusing $file under workdir=$workdir (symlink-in-path or canonical-escape; operator must repair the symlink chain before re-running)"
      return 0
    fi
  else
    bridge_warn "chown_file_iso_uid: legacy leaf-only symlink check (no workdir argument) at $file — pass workdir to engage ancestor-walk protection"
    if [[ -L "$file" ]]; then
      bridge_warn "chown_file_iso_uid: refusing to follow symlink at $file"
      return 0
    fi
  fi
  [[ -f "$file" ]] || return 0
  local agent_grp=""
  agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
  [[ -n "$agent_grp" ]] || return 0
  local os_user=""
  if command -v bridge_agent_os_user >/dev/null 2>&1; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
  fi
  # No iso UID resolvable → shared-mode agent or pre-v2 install. Fall
  # back to the file-iso-group helper which handles chgrp+chmod without
  # chown. This keeps the helper safe to call across mixed-mode agents.
  # Thread $workdir so the fallback also engages the ancestor walk (we
  # already validated $file is safe above, so this is defense-in-depth /
  # contract consistency — the fallback helper's own check is a no-op
  # repeat in the happy path).
  if [[ -z "$os_user" ]]; then
    bridge_isolation_v2_chgrp_file_iso_group "$agent" "$file" "$mode" "$workdir"
    return $?
  fi
  # Idempotent stat-skip — short-circuit if ``%U:%G:%a`` already matches
  # ``$os_user:$agent_grp:$mode``. Same numeric-mode normalization as
  # the sibling helpers.
  local cur=""
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    cur="$(stat -f '%Su:%Sg:%Lp' "$file" 2>/dev/null || printf '')"
  else
    cur="$(stat -c '%U:%G:%a' "$file" 2>/dev/null || printf '')"
  fi
  if [[ -n "$cur" ]]; then
    local cur_uid="${cur%%:*}"
    local cur_rest="${cur#*:}"
    local cur_grp="${cur_rest%%:*}"
    local cur_mode_raw="${cur_rest##*:}"
    local cur_mode_norm="" want_mode_norm=""
    cur_mode_norm="$(printf '%o' "$((8#${cur_mode_raw#0}))" 2>/dev/null || printf '%s' "$cur_mode_raw")"
    want_mode_norm="$(printf '%o' "$((8#${mode#0}))" 2>/dev/null || printf '%s' "$mode")"
    if [[ "$cur_uid" == "$os_user" && "$cur_grp" == "$agent_grp" && "$cur_mode_norm" == "$want_mode_norm" ]]; then
      return 0
    fi
  fi
  # Use bridge_linux_sudo_root for the chown — controller UID cannot
  # chown root-owned files. The chgrp + chmod could in principle run via
  # the direct-first helper (POSIX permits chown-to-own-group for
  # already-owned files), but the chown above transfers ownership to
  # the iso UID which the controller is NOT, so subsequent chmod/chgrp
  # from the controller would fail. Drive all three through
  # bridge_linux_sudo_root for consistency.
  if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
    bridge_linux_sudo_root chown "$os_user:$agent_grp" "$file" 2>/dev/null \
      || _bridge_isolation_v2_run_root_or_sudo chown "$os_user:$agent_grp" "$file" \
      || return 1
    bridge_linux_sudo_root chmod "$mode" "$file" 2>/dev/null \
      || _bridge_isolation_v2_run_root_or_sudo chmod "$mode" "$file" \
      || return 1
  else
    # No sudo-root helper available (shouldn't happen on Linux v2 but
    # guard for unit-test pathways). Best-effort direct chown which
    # only succeeds when caller is root.
    _bridge_isolation_v2_run_root_or_sudo chown "$os_user:$agent_grp" "$file" || return 1
    _bridge_isolation_v2_run_root_or_sudo chmod "$mode" "$file" || return 1
  fi
  return 0
}

# bridge_isolation_v2_repair_queue_dirs <agent>
#
# Issue #1829: cheap, idempotent ownership repair for the per-agent queue
# gateway dirs `requests/` and `responses/`. The authoritative stamp is the
# isolate/prepare subdir loop (`agent-bridge-<a>:ab-agent-<a> 2770`), but a
# first-start-death + restart-rollback can strand these dirs
# `<controller>:<controller> 2770` (controller primary group), which cuts the
# iso UID off from EVERY `agb` gateway verb (it is a member of
# `ab-agent-<a>` but NOT the controller's primary group, so it can neither
# write request files nor read response files). `agent start`/`restart` never
# re-ran the prepare normalizer, so the strand could persist until a manual
# `agb migrate isolation v2 --apply`. This helper closes that gap by
# re-asserting ONLY the two queue dirs on every start.
#
# Contract (mirrors the sibling chown helpers):
#   * Linux v2 isolation only (gated via bridge_isolation_v2_enforce);
#     silent no-op off Linux / shared-mode / when the iso UID does not resolve.
#   * Idempotent stat-skip: a dir already at `os_user:agent_grp 2770` is a
#     pure stat with zero mutating syscalls — the common case is free.
#   * Non-fatal: a failed chown/chgrp/chmod returns non-zero but the CALLER
#     (bridge-start.sh) treats that as a warn surface, never a launch abort —
#     a still-stranded dir is exactly today's behavior.
#   * Only repairs dirs that EXIST; a missing dir is left to the lazy gateway
#     creator (which now also stamps the group, see bridge-queue-gateway.py).
bridge_isolation_v2_repair_queue_dirs() {
  local agent="$1"
  [[ -n "$agent" ]] || return 0
  bridge_isolation_v2_enforce || return 0

  local agent_root=""
  agent_root="$(bridge_isolation_v2_agent_root "$agent" 2>/dev/null || printf '')"
  [[ -n "$agent_root" ]] || return 0
  local agent_grp=""
  agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
  [[ -n "$agent_grp" ]] || return 0
  local os_user=""
  if command -v bridge_agent_os_user >/dev/null 2>&1; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
  fi
  # No iso UID resolvable → shared-mode / pre-v2; the queue-dir ownership
  # contract does not apply.
  [[ -n "$os_user" ]] || return 0

  local rc=0 sub dir cur cur_uid cur_rest cur_grp cur_mode_raw cur_mode_norm
  for sub in requests responses; do
    dir="$agent_root/$sub"
    # Existence probe through the sudo-handoff helper: the per-agent root is
    # `root:ab-agent-<a> 2750` and a stale-group controller cannot traverse it
    # with a plain `[[ -d ]]` (#1028). Skip cleanly when absent.
    if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      bridge_linux_sudo_root test -d "$dir" 2>/dev/null || continue
    else
      [[ -d "$dir" ]] || continue
    fi
    # Idempotent stat-skip — read the current owner:group:mode (via sudo so a
    # stale-group controller can still stat through the 2750 parent).
    if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      cur="$(bridge_linux_sudo_root stat -c '%U:%G:%a' "$dir" 2>/dev/null || printf '')"
    else
      cur="$(stat -c '%U:%G:%a' "$dir" 2>/dev/null || printf '')"
    fi
    if [[ -n "$cur" ]]; then
      cur_uid="${cur%%:*}"
      cur_rest="${cur#*:}"
      cur_grp="${cur_rest%%:*}"
      cur_mode_raw="${cur_rest##*:}"
      cur_mode_norm="$(printf '%o' "$((8#${cur_mode_raw#0}))" 2>/dev/null || printf '%s' "$cur_mode_raw")"
      if [[ "$cur_uid" == "$os_user" && "$cur_grp" == "$agent_grp" && "$cur_mode_norm" == "2770" ]]; then
        continue
      fi
    fi
    # Re-assert the contract. chown transfers to the iso UID (which the
    # controller is not), so drive all three through the sudo-root helper.
    if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      bridge_linux_sudo_root chown "$os_user:$agent_grp" "$dir" 2>/dev/null \
        || _bridge_isolation_v2_run_root_or_sudo chown "$os_user:$agent_grp" "$dir" \
        || { rc=1; continue; }
      bridge_linux_sudo_root chmod 2770 "$dir" 2>/dev/null \
        || _bridge_isolation_v2_run_root_or_sudo chmod 2770 "$dir" \
        || { rc=1; continue; }
    else
      _bridge_isolation_v2_run_root_or_sudo chown "$os_user:$agent_grp" "$dir" || { rc=1; continue; }
      _bridge_isolation_v2_run_root_or_sudo chmod 2770 "$dir" || { rc=1; continue; }
    fi
  done
  return "$rc"
}

# bridge_isolation_v2_normalize_workdir_profile_group <agent> <workdir>
#
# Issue #1270 (v0.15.0-beta4 Lane G): after the v2 workdir materialize
# step copies CLAUDE.md (and the rest of the Claude/Codex profile fileset)
# from the identity source into the runtime workdir, those files inherit
# the controller's primary group and mode 0600. Walk the canonical
# materialize set and chgrp each to the per-agent isolation group at mode
# 0660 so the controller — a member of that group — can read them
# without sudo.
#
# This mirrors the materialize fileset in
# ``lib/bridge-agent-layout.sh:bridge_layout_materialize_identity`` (the
# CLAUDE / SOUL / SESSION-TYPE / MEMORY / MEMORY-SCHEMA / HEARTBEAT /
# CHANGE-POLICY / TOOLS list, plus the engine-native entrypoint and the
# Claude-compat copy). Any future file the materializer adds should be
# added to ``_iso_profile_files`` below so the controller-side reads
# stay coherent.
#
# Issue #1316 (v0.15.0-beta5-2 Lane θ C10): the original implementation
# walked FILES only. The ``.claude/`` directory inside ``$workdir`` —
# created by ``bridge-agent.sh:bridge_ensure_auto_memory_isolation``
# under the controller umask — stays at ``0700 controller:controller``
# (or ``0700 iso-uid:controller-gid`` after Step A chowns the parent).
# ``bridge-start.sh``'s pre-launch grep on ``$workdir/.claude/settings.json``
# then fails EACCES because the controller cannot traverse a 0700 dir
# owned by a different UID. Extend the normalize to also walk the
# canonical ``.claude/`` dir tree (``.claude/``, ``.claude/plugins/``,
# ``.claude/session-env/``) and chgrp+chmod each to
# ``ab-agent-<a>:2770``.
#
# Issue #1315 (v0.15.0-beta5-2 Lane θ C9): the legacy
# ``$workdir/.claude/plugins/known_marketplaces.json`` was seeded by
# the controller as ``root:ab-agent-<a> 0640`` on installs predating
# #1278 (Lane H beta4). On agent first-start, the iso UID's
# ``bridge-dev-plugin-cache.py:update_known_marketplaces`` does
# ``tmp.write_text + os.replace(tmp, path)`` which requires the rename
# target to be owned by the iso UID — and silently fails EPERM
# otherwise. Normalize this single file alongside the directory tree:
# chown to ``iso-uid:ab-agent-<a> 0660`` so the rename succeeds.
#
# Contract:
#   * Linux v2 isolation only (gated via ``bridge_isolation_v2_enforce``).
#   * Idempotent: the file/dir helpers each carry stat-skip and
#     short-circuit when ``%U:%G:%a`` already matches the target. A
#     re-run on an already-normalized workdir performs zero
#     ``chown`` / ``chgrp`` / ``chmod`` syscalls.
#   * Failure on any single entry is non-fatal — a warning is emitted
#     via the per-entry helper and the loop continues so a partial
#     normalize does not block the rest of ``agent create`` (or the
#     upgrade backfill loop).
#   * Symlinks at any of the directory or known_marketplaces.json
#     locations are refused (see ``chgrp_dir_iso_group`` /
#     ``chown_file_iso_uid``); operator must remove the symlink before
#     re-running.
#   * Fresh-install no-op: when the file or directory is missing the
#     per-entry helpers return 0 silently.
bridge_isolation_v2_normalize_workdir_profile_group() {
  local agent="$1"
  local workdir="$2"
  [[ -n "$agent" && -n "$workdir" ]] || return 0
  bridge_isolation_v2_enforce || return 0
  [[ -d "$workdir" ]] || return 0
  local _iso_profile_files=(
    "CLAUDE.md"
    "AGENTS.md"
    "SOUL.md"
    "SESSION-TYPE.md"
    "MEMORY.md"
    "MEMORY-SCHEMA.md"
    "HEARTBEAT.md"
    "CHANGE-POLICY.md"
    "TOOLS.md"
  )
  local name=""
  for name in "${_iso_profile_files[@]}"; do
    [[ -f "$workdir/$name" ]] || continue
    # PR #1335 r3 (codex r2 BLOCKING): pass $workdir as the fourth arg to
    # engage the ancestor symlink walk + canonical containment check in
    # chgrp_file_iso_group. Direct codex r2 repro: ``work/CLAUDE.md ->
    # /tmp/out/CLAUDE.md`` (leaf-as-symlink to external target) — without
    # the workdir-threaded ancestor walk, the chgrp+chmod mutated the
    # external target to staff:660. r2 fixed the sibling chown/chgrp_dir
    # helpers but missed the materialize-fileset helper here.
    bridge_isolation_v2_chgrp_file_iso_group "$agent" "$workdir/$name" 0660 "$workdir" \
      || bridge_warn "chgrp_file_iso_group failed for $workdir/$name (non-fatal)"
  done

  # Issue #1316 (C10): normalize the ``.claude/`` directory tree the
  # controller-umask mkdir left at 0700. Order matters — parent before
  # child — so a re-run on a half-normalized tree advances each level
  # without leaving a hole the controller cannot traverse. Each helper
  # call is independently idempotent (stat-skip), non-fatal on failure
  # (warning emitted, loop continues), and a no-op when the directory
  # is missing entirely (fresh install before any settings render).
  local _iso_profile_dirs=(
    ".claude"
    ".claude/plugins"
    ".claude/session-env"
  )
  local dname=""
  for dname in "${_iso_profile_dirs[@]}"; do
    [[ -d "$workdir/$dname" ]] || continue
    # PR #1335 r2 (codex r1 BLOCKING): pass $workdir as the fourth arg
    # to engage the ancestor symlink walk + canonical containment check
    # in chgrp_dir_iso_group. Without this, an ancestor symlink (e.g.
    # ``.claude/plugins -> /tmp/outside``) would let the helper mutate
    # an external tree even though the leaf was a regular file.
    bridge_isolation_v2_chgrp_dir_iso_group "$agent" "$workdir/$dname" 2770 "$workdir" \
      || bridge_warn "chgrp_dir_iso_group failed for $workdir/$dname (non-fatal)"
  done

  # Issue #1315 (C9): normalize ``known_marketplaces.json`` ownership +
  # mode to ``iso-uid:ab-agent-<a> 0660`` so the iso UID's plugin-cache
  # rename succeeds on first start. Uses ``chown_file_iso_uid`` (not
  # ``chgrp_file_iso_group``) because the legacy file is root-owned and
  # plain chgrp would leave it un-rename-able by the iso UID. The helper
  # short-circuits to ``chgrp_file_iso_group`` semantics when the iso UID
  # is not resolvable (shared-mode / non-iso install), so a mixed-mode
  # caller stays safe.
  #
  # PR #1335 r2 (codex r1 BLOCKING): pass $workdir as the fourth arg so
  # the ancestor-symlink walk catches the codex-r1 repro
  # (``.claude/plugins -> /tmp/outside``, leaf is a regular file in the
  # external target tree, leaf-only `-L` check passes, chmod mutates
  # external file). Note: the wrapper `-f` test below ALSO follows
  # symlinks (it is `-f`, not `-L`), but the helper's ancestor walk
  # refuses before any syscall so the wrapper-test side effect is moot.
  if [[ -f "$workdir/.claude/plugins/known_marketplaces.json" ]]; then
    bridge_isolation_v2_chown_file_iso_uid \
      "$agent" "$workdir/.claude/plugins/known_marketplaces.json" 0660 "$workdir" \
      || bridge_warn "chown_file_iso_uid failed for $workdir/.claude/plugins/known_marketplaces.json (non-fatal)"
  fi

  # Issue #1329 (v0.15.0-beta5-2 Lane μ M6): normalize per-channel
  # credential files so the iso UID can read them via the per-agent
  # group. `bridge-setup.py:save_json` / `save_text` write
  # `.<channel>/{access.json,.env,state.json,mcp.json}` at the
  # controller umask + explicit `os.chmod(... 0o600)` — leaving the
  # files at `controller-primary-group 0600` even on iso v2 agents.
  # Iso UID's plugin then EACCESes on the controller-blind read path
  # (no sudo handoff configured) and the channel connection fails
  # silently. Normalize:
  #
  #   * the channel state dir itself to `controller:ab-agent-<a> 2770`
  #     so the iso UID can traverse + list via the per-agent group.
  #     2770 = setgid'd group-rwx, world-none. Setgid on the dir
  #     ensures any future controller-side `save_json` lands at
  #     group `ab-agent-<a>` by default (POSIX setgid-inherits-group
  #     contract).
  #   * each known credential file to `controller:ab-agent-<a> 0640`.
  #     The brief explicitly chose 0640 (group-read) — NOT 0644 —
  #     because the iso UID is the only non-controller principal that
  #     needs read access and granting world-read would be a strict
  #     widening (edge case 6). Owner-rw is unchanged from the legacy
  #     0600 shape.
  #
  # Compatibility with the v3 channel-dotenv contract
  # (`agent-bridge migrate isolation v3 --apply` ⇒ `iso-uid:ab-agent-<a>
  # 0600`): the chgrp helper preserves the iso UID owner if it's
  # already there (chgrp does not change owner), and the chmod 0640
  # is a strict superset of 0600 for group-read. A v3-migrated host
  # ends up at `iso-uid:ab-agent-<a> 0640`; both shapes satisfy the
  # iso-UID-can-read contract and neither widens to world. Smoke T5
  # asserts the controller-owned 0600 → group-readable 0640
  # transition; v3-canonical files are left semantically equivalent
  # under the looser shape.
  #
  # Idempotency: each per-file helper carries stat-skip on exact
  # `%G:%a` match (see `bridge_isolation_v2_chgrp_file_iso_group` /
  # `bridge_isolation_v2_chgrp_dir_iso_group`). A re-run on an
  # already-normalized credential tree performs zero chgrp/chmod
  # syscalls (edge case 7).
  local _iso_channel_dirs=(
    ".discord"
    ".telegram"
    ".teams"
    ".ms365"
    ".mattermost"
  )
  # Per-channel credential filename list. Common entries (`.env`,
  # `access.json`) appear in every provider; channel-specific
  # extras (`state.json` for teams, `mcp.json` for mattermost)
  # are included so a future channel-state file that lands at
  # `controller 0600` is also normalized. Files absent from the
  # specific channel dir short-circuit via the `[[ -f ]]` guard
  # in the per-entry helper.
  local _iso_channel_files=(
    ".env"
    "access.json"
    "state.json"
    "mcp.json"
  )
  local chan_dir chan_file
  for chan_dir in "${_iso_channel_dirs[@]}"; do
    # Skip cleanly if the agent has not set up this channel.
    [[ -d "$workdir/$chan_dir" ]] || continue
    bridge_isolation_v2_chgrp_dir_iso_group \
      "$agent" "$workdir/$chan_dir" 2770 "$workdir" \
      || bridge_warn "chgrp_dir_iso_group failed for $workdir/$chan_dir (non-fatal)"
    for chan_file in "${_iso_channel_files[@]}"; do
      [[ -f "$workdir/$chan_dir/$chan_file" ]] || continue
      # Mode 0640 (group-read, world-none) — see contract comment above.
      bridge_isolation_v2_chgrp_file_iso_group \
        "$agent" "$workdir/$chan_dir/$chan_file" 0640 "$workdir" \
        || bridge_warn "chgrp_file_iso_group failed for $workdir/$chan_dir/$chan_file (non-fatal)"
    done
  done
  return 0
}

# bridge_isolation_v2_publish_workdir_profile_files <agent> <workdir> [group]
#
# Issue #1520c (v0.16.0-beta3 residual). First-time `agent create
# --isolate` for a linux-user iso Claude agent leaves the workdir profile
# files at `iso-uid:<controller-primary-group> 0600` instead of the iso v2
# contract `iso-uid:ab-agent-<a> 0660`, even though
# `bridge_linux_prepare_agent_isolation` already runs the #1506 recursive
# normalize (`bridge_isolation_v2_chgrp_setgid_recursive`) AFTER its
# `chown -R "$os_user" "$workdir"`.
#
# PINNED MECHANISM (empirical trace on agb-node-a, v0.16.0-beta3): during
# the SAME `agent create` process, `prepare` creates the `ab-agent-<a>`
# group and chowns the workdir tree to the iso UID. The controller process
# that invoked `agent create` carries a STALE supplementary-group cache
# that does not yet include the just-created `ab-agent-<a>` group (live
# processes never refresh group membership — KNOWN_ISSUES §28). The #1506
# recursive normalize runs its per-FILE `find … -exec chgrp/chmod`
# DIRECT-FIRST as the controller, which cannot traverse the now-
# `2770 ab-agent-<a>` workdir directory — so `find` reaches zero of the
# profile FILES (the workdir DIR itself was normalized via a root step,
# which is why the dir is correctly 2770 but the files stay 0600/controller-
# group). The `_bridge_isolation_v2_run_root_or_sudo` fallback does not
# rescue the per-file passes because the un-enterable directory yields a
# zero-file traversal rather than a hard non-zero the fallback re-runs
# under sudo.
#
# This helper closes that gap with a NARROW, profile-file-only publish that
# is ALWAYS root-forced (`bridge_linux_sudo_root`, i.e. `sudo -n` as root) —
# root chgrp/chmod does not depend on the controller's group-cache or on
# being able to traverse the 2770 workdir, so it succeeds on the very first
# create. It is scoped to the six Claude identity profile basenames that
# live directly under `$workdir`:
#
#   SOUL.md CLAUDE.md SESSION-TYPE.md MEMORY.md MEMORY-SCHEMA.md TOOLS.md
#
# DELIBERATELY EXCLUDED (NOT the broad
# `bridge_isolation_v2_normalize_workdir_profile_group` set):
#   * HEARTBEAT.md — controller-owned `0600` by design (daemon writes it as
#     the controller; the iso UID never reads it). Publishing it would
#     break the controller-owned contract and is a watchdog false-positive
#     source in the other direction.
#   * CHANGE-POLICY.md — a symlink to the shared `../../../shared/` copy;
#     chgrp/chmod must never follow it (would mutate the shared target).
#   * AGENTS.md — not part of the Claude identity profile that the iso UID
#     must read at session boot; left to the broad normalizer's own contract.
#   * The v3 channel-state dirs/files (`.teams/.ms365/.discord/.telegram/
#     .mattermost`) — never matched (the six basenames are top-level files,
#     not channel state) so the v3 `iso-uid:ab-agent-<a> 0600` contract is
#     preserved untouched.
#
# Contract:
#   * Linux v2 isolation only (gated via `bridge_isolation_v2_enforce`);
#     a silent no-op success off Linux / when v2 primitives are not
#     initialized, so the create path stays simple on every host.
#   * Symlink-safe: a profile basename that is itself a symlink (root-side
#     `test -h`) is REFUSED — never chgrp/chmod'd — so a planted
#     `CLAUDE.md -> /tmp/evil` cannot redirect the publish onto an external
#     target. (chgrp/chmod follow symlinks; the root-side `-h` check fences
#     this before any mutation.)
#   * Idempotent: a root-side `stat` short-circuits when the file already
#     matches `ab-agent-<a>:0660`, so a re-run (reapply / prepare on an
#     already-published tree) performs zero chgrp/chmod syscalls.
#   * Exec-bit irrelevant: profile `.md` files carry no exec bit; the fixed
#     `0660` is the canonical contract for these text identity files.
#   * NON-SILENT but NON-FATAL (G3): a per-file failure emits a `bridge_warn`
#     AND a `profile_publish_failed` audit row, and the loop CONTINUES — the
#     function ALWAYS returns 0 so `agent create` SUCCEEDS even if the
#     publish could not complete (operator then re-runs
#     `agent-bridge isolate <a> --reapply`). It does NOT roll back create.
bridge_isolation_v2_publish_workdir_profile_files() {
  local agent="$1"
  local workdir="$2"
  local group="${3:-}"
  local os_user_in="${4:-}"
  [[ -n "$agent" && -n "$workdir" ]] || return 0
  bridge_isolation_v2_enforce || return 0
  if [[ -z "$group" ]]; then
    group="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
  fi
  [[ -n "$group" ]] || return 0
  # The six Claude identity profile basenames. Kept in lockstep with the
  # scaffold/materialize fileset, but DELIBERATELY narrower than
  # bridge_isolation_v2_normalize_workdir_profile_group's set: HEARTBEAT.md
  # (controller-owned 0600), CHANGE-POLICY.md (shared symlink) and AGENTS.md
  # are excluded on purpose — see the contract comment above.
  local _profile_basenames=(
    "SOUL.md"
    "CLAUDE.md"
    "SESSION-TYPE.md"
    "MEMORY.md"
    "MEMORY-SCHEMA.md"
    "TOOLS.md"
  )
  # The root-side mutation is delegated to a standalone python helper that
  # opens each basename with O_NOFOLLOW relative to a workdir DIRECTORY fd
  # and fchown/fchmod's the OPEN FD — never re-resolving a profile pathname
  # after deciding to mutate it. This closes the TOCTOU window that a
  # path-based `test -h` + `chgrp`/`chmod` left open: once prepare's
  # `chown -R` hands the workdir to the iso UID, that UID owns every entry
  # and can swap `SOUL.md` for `SOUL.md -> /etc/shadow` between a path
  # check and a path mutation. An fd bound to the verified regular-file
  # inode cannot be redirected by a later rename. See the helper header.
  local _publish_helper="${BRIDGE_SCRIPT_DIR:-}/scripts/python-helpers/isolation-publish-profile-files.py"
  if [[ ! -f "$_publish_helper" ]]; then
    bridge_warn "publish_workdir_profile_files: helper missing ($_publish_helper) for agent=$agent (non-fatal) — re-run \`agent-bridge isolate $agent --reapply\`"
    bridge_audit_log isolation profile_publish_failed "$agent" \
      --detail op=publish-helper --detail reason=helper-missing \
      >/dev/null 2>&1 || true
    return 0
  fi
  # Owner of the freshly-chowned profile files; threaded so the helper can
  # assert `st_uid == <iso-uid>` (defence in depth). Prefer the value the
  # caller already resolved (the `chown -R` target); fall back to the
  # roster value. Empty when neither is resolvable — the helper then skips
  # the owner check rather than refusing everything.
  local _os_user="$os_user_in"
  [[ -n "$_os_user" ]] || _os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
  local _publish_out="" _publish_rc=0
  _publish_out="$(bridge_linux_sudo_root python3 "$_publish_helper" \
    "$workdir" "$group" 0660 "$_os_user" "${_profile_basenames[@]}" 2>/dev/null)"
  _publish_rc=$?
  if (( _publish_rc != 0 )); then
    # Fatal setup error inside the helper (unknown group / workdir not
    # openable) or the root invocation itself failed. Non-fatal: warn +
    # audit, create still succeeds.
    bridge_warn "publish_workdir_profile_files: root publish helper failed (rc=$_publish_rc) for agent=$agent (non-fatal) — re-run \`agent-bridge isolate $agent --reapply\`"
    bridge_audit_log isolation profile_publish_failed "$agent" \
      --detail op=publish-helper --detail rc="$_publish_rc" \
      >/dev/null 2>&1 || true
    return 0
  fi
  # Per-file results (TAB-separated: <status>\t<basename>\t<detail>).
  # Piped into the loop (not a `<<<` here-string — lint-heredoc-ban bans
  # here-strings to a non-interpreter consumer); the loop only warns/audits
  # (side effects), keeping no state past the subshell, so the pipe is safe.
  local _st="" _fname="" _detail=""
  printf '%s\n' "$_publish_out" | while IFS=$'\t' read -r _st _fname _detail; do
    [[ -n "$_st" ]] || continue
    case "$_st" in
      published|ok-nochange|absent)
        : ;;  # success / nothing to do
      refused-symlink)
        # A symlinked profile basename at one of the six identity files is
        # anomalous — a planted redirect (the exact attack this fd-based
        # publish hardens against) or a mis-shared CHANGE-POLICY-style link.
        # O_NOFOLLOW refused it before any chgrp/chmod. Warn AND audit: a
        # refused symlink is a security-relevant signal, not a transient
        # condition, so it gets the same `profile_publish_failed` row as the
        # other per-file refusals (audit parity, G3 contract).
        bridge_warn "publish_workdir_profile_files: refusing symlink at $workdir/$_fname (agent=$agent); operator must repair the symlink before re-running isolate"
        bridge_audit_log isolation profile_publish_failed "$agent" \
          --detail file="$_fname" --detail op=refused-symlink \
          >/dev/null 2>&1 || true ;;
      refused-nonregular|refused-owner)
        bridge_warn "publish_workdir_profile_files: refusing $_st at $workdir/$_fname (agent=$agent; $_detail; non-fatal)"
        bridge_audit_log isolation profile_publish_failed "$agent" \
          --detail file="$_fname" --detail op="$_st" --detail info="$_detail" \
          >/dev/null 2>&1 || true ;;
      mutate-failed|*)
        # chgrp/chmod (fchown/fchmod) raised on the open fd. Non-fatal.
        bridge_warn "publish_workdir_profile_files: chgrp/chmod failed for $workdir/$_fname (agent=$agent; $_detail; non-fatal) — re-run \`agent-bridge isolate $agent --reapply\`"
        bridge_audit_log isolation profile_publish_failed "$agent" \
          --detail file="$_fname" --detail op="${_detail%%:*}" --detail info="$_detail" \
          >/dev/null 2>&1 || true ;;
    esac
  done
  return 0
}

# Issue #1533 — root-forced, TOCTOU-safe normalize of an isolated agent's
# WRITABLE CONTENT SUBTREES (`home/`, `workdir/`, `runtime/`, `logs/`) to
# the iso v2 contract (`ab-agent-<a>:0660` files / `ab-agent-<a>:2770`
# dirs) on a FIRST `agent create --isolate`.
#
# This is the recursive generalization of
# `bridge_isolation_v2_publish_workdir_profile_files` (PR-C, #1520c). Same
# root cause, broader surface: the create-path #1506 normalize
# (`bridge_isolation_v2_chgrp_setgid_recursive`, below) runs its per-entry
# chgrp/chmod DIRECT-FIRST as the controller. On a first create the
# controller's supplementary-group cache is STALE for the just-created
# `ab-agent-<a>` group (KNOWN_ISSUES §28), so its `find … -exec` cannot
# ENTER the freshly-`chown -R`-ed `2770 ab-agent-<a>` subtree — it reaches
# zero files, returns 0, and EVERY pre-scaffolded file under `home/`
# (`.claude/**`, `memory/**`, `raw/**`, `skills/**`, `users/**`) stays
# stranded at `iso-uid:<controller-group> 0600`. PR-C narrowly rescued
# only the six profile basenames directly under `$workdir`; this closes
# the residual for the whole content tree so no controller-written
# first-isolate file needs a manual `sg`-wrapped `--reapply`.
#
# Always-root + fd-safe (the inner python walker
# `scripts/python-helpers/isolation-normalize-content-tree.py`):
#   * Runs via `bridge_linux_sudo_root`, so it is independent of the
#     controller's group cache and of 2770 traversability — it succeeds on
#     the first create. Off Linux / under `bridge_linux_sudo_root`'s direct
#     fall-through it runs the SAME fd-based path (so the smoke exercises
#     real behavior on macOS).
#   * TOCTOU: after prepare's `chown -R <iso-uid>` the iso UID owns every
#     entry and can swap any inode for a symlink mid-walk. The walker opens
#     every directory descent and every file with `O_NOFOLLOW`/`O_DIRECTORY`
#     and fchown/fchmod's the OPEN FD — never a path-based root chgrp/chmod
#     that a rename could redirect (the CVE-class footgun a `find -exec` as
#     root over an iso-owned tree would reopen). A symlinked / non-regular /
#     wrong-owner entry is REFUSED, never mutated.
#   * Exec bits preserved (a `+x` plugin script lands 0770, not stripped).
#   * Excludes the v3 channel-state dirs' CONTENTS (`.teams`/`.ms365`/
#     `.discord`/`.telegram`/`.mattermost` files stay `iso-uid 0600`); the
#     dir nodes themselves are still normalized 2770 so they stay
#     group-traversable — mirrors the `--exclude-subdir` contract of the
#     recursive bash helper.
#   * Excludes BY NAME (`--exclude-name`) the top-level files whose
#     0600/owner contract must NOT be relaxed: HEARTBEAT.md
#     (controller-owned 0600 by design — the daemon owns it; the iso UID
#     never reads it) and CHANGE-POLICY.md (shared symlink — O_NOFOLLOW
#     refuses it anyway, the name-exclude just avoids a per-run
#     `refused-symlink` warn). These are skipped ENTIRELY (no chgrp/chmod),
#     preserving the same exclusions the #1520c profile publish + watchdog
#     classifier already hold.
#   * Idempotent: an entry already at the contract is skipped (no syscall),
#     so a re-run / the re-login case where the direct-first normalize
#     already succeeded performs zero mutations.
#   * NON-SILENT but NON-FATAL (G3): a per-entry refusal/failure emits a
#     `bridge_warn` + a `content_publish_failed` audit row; the function
#     ALWAYS returns 0 so `agent create` SUCCEEDS even if a node could not
#     be normalized (operator can still `--reapply`). It does NOT roll back
#     create.
bridge_isolation_v2_publish_content_tree() {
  local agent="$1"; shift
  local group="$1"; shift
  local os_user_in="$1"; shift
  # Remaining args: one or more root dirs to normalize, optionally
  # interleaved with `--exclude-subdir <name>` (applied to ALL roots'
  # top-level entries). The caller passes the v3 channel-state names.
  [[ -n "$agent" ]] || return 0
  bridge_isolation_v2_enforce || return 0
  if [[ -z "$group" ]]; then
    group="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
  fi
  [[ -n "$group" ]] || return 0

  local -a _roots=()
  local -a _excludes=()
  # #1766: optional target-validated symlink acceptance passed straight
  # through to the walker (only the canonical settings.json self-target link).
  local -a _accept_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude-subdir)
        [[ $# -ge 2 ]] || { shift; continue; }
        _excludes+=(--exclude-subdir "$2"); shift 2 ;;
      --exclude-name)
        [[ $# -ge 2 ]] || { shift; continue; }
        _excludes+=(--exclude-name "$2"); shift 2 ;;
      --accept-settings-link-rel)
        [[ $# -ge 2 ]] || { shift; continue; }
        _accept_args+=(--accept-settings-link-rel "$2"); shift 2 ;;
      --accept-settings-link-target)
        [[ $# -ge 2 ]] || { shift; continue; }
        _accept_args+=(--accept-settings-link-target "$2"); shift 2 ;;
      *)
        # Collect a non-empty root candidate. Deliberately NOT a
        # controller-side `[[ -d "$1" ]]` precheck: on a FIRST
        # `agent create --isolate` the controller's STALE supp-group cache
        # (KNOWN_ISSUES §28) cannot group-traverse the per-agent root
        # (`controller:ab-agent-<a> 2750`), so a `-d` test would FALSE-
        # NEGATIVE every root and the publish would no-op — the exact bug
        # this function fixes. The ROOT walker (`_open_root`) runs as root,
        # CAN traverse, and treats a genuinely missing root as a benign
        # skip (FileNotFoundError), so existence validation belongs there,
        # not in this group-cache-dependent controller precheck.
        [[ -n "$1" ]] && _roots+=("$1"); shift ;;
    esac
  done
  # Nothing to normalize (no root args at all) → benign no-op success.
  [[ ${#_roots[@]} -gt 0 ]] || return 0

  local _helper="${BRIDGE_SCRIPT_DIR:-}/scripts/python-helpers/isolation-normalize-content-tree.py"
  if [[ ! -f "$_helper" ]]; then
    bridge_warn "publish_content_tree: helper missing ($_helper) for agent=$agent (non-fatal) — re-run \`agent-bridge isolate $agent --reapply\`"
    bridge_audit_log isolation content_publish_failed "$agent" \
      --detail op=publish-helper --detail reason=helper-missing \
      >/dev/null 2>&1 || true
    return 0
  fi

  local _os_user="$os_user_in"
  [[ -n "$_os_user" ]] || _os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"

  # The controller owns the prepared container dirs (`home`/`workdir`/
  # `runtime`/`logs` at `controller:2770`); pass it so the walker accepts
  # those as valid DIRECTORY owners (in addition to the iso UID) and can
  # descend through them to the iso-owned content beneath. Regular FILES
  # stay gated strictly to the iso UID.
  local _controller_user=""
  _controller_user="$(bridge_current_user 2>/dev/null || id -un 2>/dev/null || printf '')"
  local -a _controller_arg=()
  [[ -n "$_controller_user" ]] && _controller_arg=(--controller-user "$_controller_user")

  local _out="" _rc=0
  _out="$(bridge_linux_sudo_root python3 "$_helper" \
    "$group" 0660 2770 "$_os_user" "${_roots[@]}" "${_excludes[@]}" \
    "${_controller_arg[@]}" "${_accept_args[@]}" 2>/dev/null)"
  _rc=$?
  if (( _rc != 0 )); then
    bridge_warn "publish_content_tree: root normalize helper failed (rc=$_rc) for agent=$agent (non-fatal) — re-run \`agent-bridge isolate $agent --reapply\`"
    bridge_audit_log isolation content_publish_failed "$agent" \
      --detail op=publish-helper --detail rc="$_rc" \
      >/dev/null 2>&1 || true
    return 0
  fi

  # Per-entry results (TAB-separated: <status>\t<relpath>\t<detail>). The
  # walker emits ONLY non-ok lines + a trailing `summary` line. Piped (not
  # a here-string — lint-heredoc-ban) into a side-effect-only loop.
  local _st="" _rel="" _detail=""
  printf '%s\n' "$_out" | while IFS=$'\t' read -r _st _rel _detail; do
    [[ -n "$_st" ]] || continue
    case "$_st" in
      summary)
        : ;;  # counts line; nothing actionable per-entry
      accepted-settings-symlink)
        # #1766: the canonical settings.json self-target link was accepted
        # and its group normalized — a success outcome, audited for trace.
        bridge_audit_log isolation content_settings_symlink_accepted "$agent" \
          --detail file="$_rel" --detail target="$_detail" \
          >/dev/null 2>&1 || true ;;
      refused-symlink)
        bridge_warn "publish_content_tree: refusing symlink at $_rel (agent=$agent); not normalized (planted-redirect guard)"
        bridge_audit_log isolation content_publish_failed "$agent" \
          --detail file="$_rel" --detail op=refused-symlink \
          >/dev/null 2>&1 || true ;;
      refused-nonregular|refused-owner)
        bridge_warn "publish_content_tree: refusing $_st at $_rel (agent=$agent; $_detail; non-fatal)"
        bridge_audit_log isolation content_publish_failed "$agent" \
          --detail file="$_rel" --detail op="$_st" --detail info="$_detail" \
          >/dev/null 2>&1 || true ;;
      mutate-failed|*)
        bridge_warn "publish_content_tree: chgrp/chmod failed for $_rel (agent=$agent; $_detail; non-fatal) — re-run \`agent-bridge isolate $agent --reapply\`"
        bridge_audit_log isolation content_publish_failed "$agent" \
          --detail file="$_rel" --detail op="${_detail%%:*}" --detail info="$_detail" \
          >/dev/null 2>&1 || true ;;
    esac
  done
  return 0
}

bridge_isolation_v2_chgrp_setgid_recursive() {
  # Apply group + mode to a tree. Directories get the dir-mode (with
  # setgid bit), files get the file-mode (without setgid). The dir-mode
  # MUST include the setgid bit (e.g. 2750, 2770) so newly-created
  # children inherit the group automatically.
  #
  # Direct-first like chgrp_setgid_dir; the regression smoke validates
  # the rootless primary-group path without sudo.
  local group="$1"
  local dir_mode="$2"
  local file_mode="$3"
  local root="$4"
  shift 4
  [[ -n "$group" && -n "$dir_mode" && -n "$file_mode" && -n "$root" ]] || {
    bridge_warn "chgrp_setgid_recursive: group, dir_mode, file_mode, root required"
    return 1
  }
  [[ -d "$root" ]] || {
    bridge_warn "chgrp_setgid_recursive: not a directory: $root"
    return 1
  }
  # Optional --exclude-subdir <name> args (#998 PR B): contents of named
  # subdirs are pruned from all find passes; the dir nodes themselves are
  # still chgrp/chmod'd (v3 channel state dirs stay 2770/agent-group while
  # their files remain isolated-UID 0600).
  #
  # Optional --exclude-path <abs-path> args (#1021): an ABSOLUTE path
  # whose whole subtree — the node itself AND its contents — is pruned
  # from every find pass. Unlike --exclude-subdir (a leaf name relative
  # to $root), --exclude-path takes a fully-qualified path so a caller
  # can fence off a shared tree (e.g. the shared plugins cache) that
  # might be reachable inside $root via a bind mount, a real nested
  # directory, or — when $root itself is a symlink that `find` follows
  # from the command line — a sibling subtree. This guarantees the
  # recursive chgrp/chmod can never re-group shared plugin material to
  # the per-agent group and break other isolated agents.
  #
  # Optional --exclude-name <basename> args (#1891): a LEAF basename
  # (matched anywhere in the tree via `-name`) whose node is pruned from
  # every find pass — neither chgrp'd nor chmod'd. Unlike --exclude-subdir
  # (whose dir node IS still mutated, only its contents skipped),
  # --exclude-name skips the matched node entirely. The load-bearing
  # caller is the memory-tree normalize: `memory/index.sqlite` must stay
  # controller-owned 0600 (the controller-side reducer/rebuilder owns it;
  # the iso UID never reads it directly), so it must NOT be relaxed to the
  # 0660 ab-agent-<a> content contract that the rest of `memory/` gets.
  local -a _excl_names=()
  local -a _excl_paths=()
  local -a _excl_basenames=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude-subdir)
        [[ $# -ge 2 ]] || {
          bridge_warn "chgrp_setgid_recursive: --exclude-subdir requires a value"
          return 1
        }
        _excl_names+=("$2"); shift 2
        ;;
      --exclude-path)
        [[ $# -ge 2 ]] || {
          bridge_warn "chgrp_setgid_recursive: --exclude-path requires a value"
          return 1
        }
        [[ -n "$2" ]] && _excl_paths+=("$2")
        shift 2
        ;;
      --exclude-name)
        [[ $# -ge 2 ]] || {
          bridge_warn "chgrp_setgid_recursive: --exclude-name requires a value"
          return 1
        }
        [[ -n "$2" ]] && _excl_basenames+=("$2")
        shift 2
        ;;
      *) bridge_warn "chgrp_setgid_recursive: unknown option: $1"; return 1 ;;
    esac
  done
  # find prune: -path "$root/<name>/*" -prune -o  — excludes file contents
  # under each named subdir; dir nodes fall through to the normal predicates.
  local -a _find_prune=()
  local _fp_n
  for _fp_n in "${_excl_names[@]}"; do
    _find_prune+=('-path' "$root/$_fp_n/*" '-prune' '-o')
  done
  # --exclude-name prunes any node whose leaf basename matches (the node
  # itself; no `/*` clause — these are files we skip in place, not subtrees
  # to descend). Keeps `index.sqlite` controller-owned 0600 (#1891).
  local _fp_b
  for _fp_b in "${_excl_basenames[@]}"; do
    _find_prune+=('-name' "$_fp_b" '-prune' '-o')
  done
  # --exclude-path prunes the matched node AND everything beneath it:
  # `-path "$abs" -prune -o -path "$abs/*" -prune -o`. The bare `-path
  # "$abs"` prune covers the node itself so it is neither chgrp'd nor
  # chmod'd; the `/*` prune covers its contents.
  local _fp_p
  for _fp_p in "${_excl_paths[@]}"; do
    _find_prune+=('-path' "$_fp_p" '-prune' '-o'
                  '-path' "$_fp_p/*" '-prune' '-o')
  done
  local -a _excl_args=()
  local _ea_n
  for _ea_n in "${_excl_names[@]}"; do
    _excl_args+=('--exclude-subdir' "$_ea_n")
  done
  local _ea_p
  for _ea_p in "${_excl_paths[@]}"; do
    _excl_args+=('--exclude-path' "$_ea_p")
  done
  local _ea_b
  for _ea_b in "${_excl_basenames[@]}"; do
    _excl_args+=('--exclude-name' "$_ea_b")
  done
  # Platform discriminator gate (S5 Track A1, extending S3 pattern):
  # recursive chgrp + setgid bit only has a security model on hosts
  # where POSIX setgid groups are the primitive (default: Linux).
  # Audit C08 — Bucket 2. Operators can force enforcement via
  # BRIDGE_ISOLATION_REQUIRED=yes.
  bridge_isolation_v2_enforce || return 0
  # Issue #746 v0.9.4 followup: translate the numeric file_mode into a
  # symbolic chmod that PRESERVES executable bits via `X` (uppercase).
  # Background: v0.9.3 PR #768 wired this helper into the spaced-CLI
  # repair tool (reapply_one_agent), which iterates `agents/<X>/home/`
  # — that tree contains executable plugin scripts (e.g.
  # `.claude/plugins/cache/<...>/scripts/*.sh` at 0750). The previous
  # blanket `chmod 0660` on every file killed those exec bits and broke
  # SessionStart hooks (`crm-mcp-token-sync.sh: Permission denied`) on
  # the operator's production host. Symbolic mode with `X` adds group
  # exec only when the file already has any exec bit (or is a dir),
  # leaving textfiles at g+rw and scripts at g+rwx.
  #
  # User permissions are intentionally NOT touched — the file owner
  # (agent UID) already has rw on its own files; we only assert the
  # group + other invariants the v2 contract requires.
  local _file_chmod_symbolic
  # `u-s,g-s` explicitly strips any pre-existing setuid/setgid bits on
  # regular files. Files in agents/<X>/{home,workdir,...} should never
  # carry setuid/setgid (privilege escalation surface); strip them
  # defensively as part of the canonical-state assertion. Dirs are
  # handled by the literal `dir_mode` chmod above (e.g. 2770 INCLUDES
  # the setgid bit, which is intentional — newly-created files inherit
  # the group). The verify helper masks special bits when comparing
  # file modes (line ~852), so without explicit strip a stray setuid
  # bit could survive and verify as clean. r2 codex catch.
  case "${file_mode#0}" in
    660) _file_chmod_symbolic='u-s,g-s,g+rwX,o-rwx' ;;
    640) _file_chmod_symbolic='u-s,g-s,g+rX,g-w,o-rwx' ;;
    600) _file_chmod_symbolic='u-s,g-s,g-rwx,o-rwx' ;;
    *)
      # Unknown literal mode — fall back to the original blanket chmod
      # so callers using novel modes get the legacy behavior. Future
      # additions to the cases above should match the v2 contract surface.
      _file_chmod_symbolic="$file_mode"
      ;;
  esac

  # `chgrp -R` follows symlinks on BSD/macOS by default while GNU
  # coreutils does not, so a symlink-to-directory inside $root could
  # lead the chown out of the tree on macOS. Restrict the recursion
  # to files+dirs explicitly via find so symlinks (-type l) are never
  # chgrp'd or chmod'd; the four-pass approach is consistent with the
  # chmod passes below.
  _bridge_isolation_v2_run_root_or_sudo find "$root" "${_find_prune[@]}" -type d -exec chgrp "$group" {} + || return 1
  _bridge_isolation_v2_run_root_or_sudo find "$root" "${_find_prune[@]}" -type f -exec chgrp "$group" {} + || return 1
  _bridge_isolation_v2_run_root_or_sudo find "$root" "${_find_prune[@]}" -type d -exec chmod "$dir_mode" {} + || return 1
  _bridge_isolation_v2_run_root_or_sudo find "$root" "${_find_prune[@]}" -type f -exec chmod "$_file_chmod_symbolic" {} + || return 1

  # Self-verify: catches the symptom from issue #746 where the
  # direct-first path returns 0 with no actual mutations (e.g. find
  # exit-status not propagating through `-exec ... +` on some findutils
  # builds, or the sudo path silently degraded). Without this, the
  # migrator advances the v2 marker on a half-repaired tree and the
  # controller-group read sweep keeps failing every Saturday.
  #
  # Note (v0.9.4 followup): the verify helper takes the original numeric
  # file_mode but only sample-checks ONE file's mode. With the new
  # exec-preserving symbolic chmod, an executable file's post-chmod
  # mode will not match `file_mode` exactly (it'll have the +x bit on).
  # The verify check is best-effort and the verify failure here is
  # primarily about catching wrong-group (which the symbolic chmod
  # doesn't affect). On a sample mode mismatch the helper still emits
  # a bridge_warn but the operator's centralized read access (the
  # actual #746 contract) is still satisfied because group + base mode
  # is correct. A future cleanup could make verify aware of symbolic
  # modes, but it's not required for the #746 contract.
  if ! bridge_isolation_v2_verify_chgrp_setgid_recursive \
        "$group" "$dir_mode" "$file_mode" "$root" "${_excl_args[@]}"; then
    # Drift detected. Retry with sudo-only (skip direct-first), in case
    # the direct-first attempt succeeded-on-find-but-failed-on-chgrp.
    # If still drifted after the sudo retry, surface clearly so the
    # migrator caller can abort instead of writing the v2 marker on a
    # half-repaired tree.
    if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      sudo -n find "$root" "${_find_prune[@]}" -type d -exec chgrp "$group" {} + 2>/dev/null || true
      sudo -n find "$root" "${_find_prune[@]}" -type f -exec chgrp "$group" {} + 2>/dev/null || true
      sudo -n find "$root" "${_find_prune[@]}" -type d -exec chmod "$dir_mode" {} + 2>/dev/null || true
      sudo -n find "$root" "${_find_prune[@]}" -type f -exec chmod "$_file_chmod_symbolic" {} + 2>/dev/null || true
    fi
    if ! bridge_isolation_v2_verify_chgrp_setgid_recursive \
          "$group" "$dir_mode" "$file_mode" "$root" "${_excl_args[@]}"; then
      bridge_warn "chgrp_setgid_recursive: tree under $root still has drifted group/mode after sudo retry — see preceding verify warnings"
      return 1
    fi
  fi
  return 0
}

bridge_isolation_v2_verify_chgrp_setgid_recursive() {
  # Confirm the recursive chgrp/chmod actually landed on every entry
  # under root. Used as a belt-and-braces check after
  # bridge_isolation_v2_chgrp_setgid_recursive — see issue #746 for the
  # symptom (helper returns 0 but files keep their pre-migration group/
  # mode, leaving controller-group reads broken on isolated agent
  # workdirs).
  local group="$1"
  local dir_mode="$2"
  local file_mode="$3"
  local root="$4"
  shift 4
  [[ -n "$group" && -n "$dir_mode" && -n "$file_mode" && -n "$root" ]] || {
    bridge_warn "verify_chgrp_setgid_recursive: group, dir_mode, file_mode, root required"
    return 1
  }
  [[ -d "$root" ]] || return 0  # nothing to verify
  local -a _excl_names=()
  local -a _excl_paths=()
  local -a _excl_basenames=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude-subdir) _excl_names+=("$2"); shift 2 ;;
      --exclude-path) [[ -n "${2:-}" ]] && _excl_paths+=("$2"); shift 2 ;;
      --exclude-name) [[ -n "${2:-}" ]] && _excl_basenames+=("$2"); shift 2 ;;
      *) shift ;;
    esac
  done
  local -a _find_prune=()
  local _fp_n
  for _fp_n in "${_excl_names[@]}"; do
    _find_prune+=('-path' "$root/$_fp_n/*" '-prune' '-o')
  done
  # #1021: prune --exclude-path subtrees from the verify scan too, so a
  # deliberately-excluded shared tree (left at its shared group on
  # purpose) does not register as a verify mismatch.
  local _fp_p
  for _fp_p in "${_excl_paths[@]}"; do
    _find_prune+=('-path' "$_fp_p" '-prune' '-o'
                  '-path' "$_fp_p/*" '-prune' '-o')
  done
  # #1891: prune --exclude-name nodes from the verify scan too, so the
  # deliberately-skipped `index.sqlite` (controller-owned 0600, NOT in the
  # agent group) does not register as a group/mode mismatch.
  local _fp_b
  for _fp_b in "${_excl_basenames[@]}"; do
    _find_prune+=('-name' "$_fp_b" '-prune' '-o')
  done

  # Normalize expected modes to %04o so `stat` output ("2770", "660")
  # compares cleanly across BSD/macOS and GNU coreutils.
  local exp_dir_mode exp_file_mode
  exp_dir_mode="$(printf '%04o' "$((8#$dir_mode))" 2>/dev/null || printf '%s' "$dir_mode")"
  exp_file_mode="$(printf '%04o' "$((8#$file_mode))" 2>/dev/null || printf '%s' "$file_mode")"

  local stat_fmt
  if [[ "$(uname)" == "Darwin" ]]; then
    stat_fmt=(-f %A)
  else
    stat_fmt=(-c %a)
  fi

  # First dir whose group != expected. `\! -group` is portable across
  # BSD/macOS find and GNU findutils; `-not` is GNU-only.
  local mismatch_path
  mismatch_path="$(find "$root" "${_find_prune[@]}" -type d \! -group "$group" -print 2>/dev/null | head -n1)"
  if [[ -n "$mismatch_path" ]]; then
    bridge_warn "verify_chgrp_setgid_recursive: dir group mismatch under $root (first: $mismatch_path expected=$group)"
    return 1
  fi
  mismatch_path="$(find "$root" "${_find_prune[@]}" -type f \! -group "$group" -print 2>/dev/null | head -n1)"
  if [[ -n "$mismatch_path" ]]; then
    bridge_warn "verify_chgrp_setgid_recursive: file group mismatch under $root (first: $mismatch_path expected=$group)"
    return 1
  fi
  # Sample mode check (one entry per type) — a full mode walk is
  # expensive on large trees; the sample is enough to catch the silent-
  # no-op failure mode where every entry kept its pre-migration mode.
  local sample_dir sample_file actual_mode normalized_actual
  sample_dir="$(find "$root" "${_find_prune[@]}" -type d -print 2>/dev/null | head -n1)"
  sample_file="$(find "$root" "${_find_prune[@]}" -type f -print 2>/dev/null | head -n1)"
  if [[ -n "$sample_dir" ]]; then
    actual_mode="$(stat "${stat_fmt[@]}" "$sample_dir" 2>/dev/null || true)"
    if [[ -n "$actual_mode" ]]; then
      normalized_actual="$(printf '%04o' "$((8#$actual_mode))" 2>/dev/null || printf '%s' "$actual_mode")"
      if [[ "$normalized_actual" != "$exp_dir_mode" ]]; then
        bridge_warn "verify_chgrp_setgid_recursive: dir mode mismatch at $sample_dir (expected=$exp_dir_mode actual=$normalized_actual)"
        return 1
      fi
    fi
  fi
  if [[ -n "$sample_file" ]]; then
    actual_mode="$(stat "${stat_fmt[@]}" "$sample_file" 2>/dev/null || true)"
    if [[ -n "$actual_mode" ]]; then
      normalized_actual="$(printf '%04o' "$((8#$actual_mode))" 2>/dev/null || printf '%s' "$actual_mode")"
      # Issue #746 v0.9.4 followup: chgrp_setgid_recursive uses
      # exec-preserving symbolic chmod on files (g+rwX,o-rwx), so an
      # originally-executable file (e.g. plugin script 0750) lands at
      # 0770 post-fix while the caller still passes the canonical
      # numeric file_mode (0660) as the verify target. Compare only
      # the rw bits (0666 mask) so the verify is exec-aware: it still
      # catches "didn't chmod at all" (rw bits would be wrong) but
      # tolerates the preserved exec bit. Sticky/setgid/setuid not
      # expected on regular files; if they appear we'd want to flag,
      # but the existing helper doesn't set them either, so masking
      # them out here is consistent with the chmod target.
      local masked_actual masked_expected
      masked_actual="$(printf '%04o' $(( 8#$normalized_actual & 8#0666 )) 2>/dev/null || printf '%s' "$normalized_actual")"
      masked_expected="$(printf '%04o' $(( 8#$exp_file_mode & 8#0666 )) 2>/dev/null || printf '%s' "$exp_file_mode")"
      if [[ "$masked_actual" != "$masked_expected" ]]; then
        bridge_warn "verify_chgrp_setgid_recursive: file mode (rw bits) mismatch at $sample_file (expected_rw=$masked_expected actual_full=$normalized_actual)"
        return 1
      fi
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 4a-mem. iso-owned memory/ tree normalize (#1891)
# ---------------------------------------------------------------------------

bridge_isolation_v2_normalize_memory_tree() {
  # #1891 — Normalize an isolated agent's `memory/` subtree to the
  # header-matrix contract: dirs `2770` group=`ab-agent-<a>`, files `0660`,
  # EXCEPT the controller-owned `memory/index.sqlite` which stays `0600`
  # (the controller-side memory reducer/rebuilder is its sole writer; the
  # iso UID reads memory via the markdown wiki + the controller-published
  # aggregate, never the raw index DB).
  #
  # Why a dedicated helper instead of leaning on the broad content-tree
  # normalize: later-created (Jun-4+) iso agents finished provisioning with
  # `memory/` left controller-owned `2700` (no group bits) — a create-time
  # normalize that silently under-reached or failed. The iso UID then can't
  # read its OWN memory/ (daily harvest fails). This helper is invoked from
  # BOTH the create path and reapply/reconcile so an EXISTING stale `2700`
  # subtree is repaired, not just fresh creates. It deliberately does NOT
  # relax `index.sqlite` (criterion 2): a naive recursive group-open would
  # break the controller-owned 0600 invariant the rebuilder relies on.
  #
  # Args:
  #   $1 group   — ab-agent-<a>
  #   $2+ roots  — one or more `memory/` dirs (e.g. <root>/home/memory,
  #                <root>/workdir/memory). Missing roots are skipped.
  # Returns non-zero if any present root failed to normalize. A complete
  # no-op success off Linux / when v2 primitives are not initialized
  # (the recursive helper gates on `bridge_isolation_v2_enforce`).
  local group="$1"; shift
  [[ -n "$group" ]] || {
    bridge_warn "normalize_memory_tree: group required"
    return 1
  }
  command -v bridge_isolation_v2_chgrp_setgid_recursive >/dev/null 2>&1 || return 0
  # Off Linux / when v2 is not the security model this is a complete no-op
  # success (mirrors the recursive helper's own gate, but applied up-front so
  # the index.sqlite re-assert below does NOT run on a dev host either).
  # Smokes force enforcement via BRIDGE_ISOLATION_REQUIRED=yes.
  bridge_isolation_v2_enforce || return 0

  local _mem_root
  local _rc=0
  for _mem_root in "$@"; do
    [[ -n "$_mem_root" && -d "$_mem_root" ]] || continue
    # Skip index.sqlite by leaf name so the recursive pass never relaxes the
    # memory index DB to the 0660 ab-agent-<a> content mode. Its 0600 mode is
    # the special case the contract carves out (criterion 2) — group members
    # (incl. the controller) must not gain read on it via the memory walk.
    # Scope: this helper's roots are the `memory/` trees themselves (the caller
    # passes `home/memory` + `workdir/memory`), so the basename match is
    # effectively `memory/**/index.sqlite` — the ONLY place a memory index DB
    # lives. The broad #1506/#1533 passes elsewhere only add the exclude on the
    # memory-bearing roots (home/workdir), so no `index.sqlite` outside a
    # `memory/` tree is unintentionally exempted.
    if ! bridge_isolation_v2_chgrp_setgid_recursive \
          "$group" 2770 0660 "$_mem_root" --exclude-name index.sqlite; then
      bridge_warn "normalize_memory_tree: chgrp/chmod of '$_mem_root' returned non-zero for group '$group' (the iso UID may not read its own memory/ until \`agent-bridge isolate <a> --reapply\` succeeds)."
      _rc=1
    fi
    # Belt-and-braces: if index.sqlite exists, re-assert its restrictive 0600
    # mode. The recursive pass skipped it by name, but a prior drift could have
    # left it group-readable (e.g. an earlier blanket 0660); restore 0600 so
    # the DB never gains group read. OWNER is intentionally left untouched: the
    # rebuild writes the live DB AS the iso UID inside the 2770 memory dir
    # (scripts/wiki-v2-rebuild.sh drops to the iso UID), so it is legitimately
    # iso-owned — a chown here would fight that model. 0600 has no group bits,
    # so iso-owned 0600 is exactly "no group read", which is the invariant.
    #
    # The memory dir is iso-UID-owned (2770), so the iso UID could swap
    # index.sqlite for a symlink between the test and the chmod (TOCTOU /
    # planted-redirect). Refuse a symlinked target — chmod only a real regular
    # file. Best-effort: a chmod failure narrows the read audience, never
    # widens it, so it is non-fatal.
    local _idx="$_mem_root/index.sqlite"
    if [[ -f "$_idx" && ! -L "$_idx" ]]; then
      if ! { chmod 0600 "$_idx" 2>/dev/null \
              || _bridge_isolation_v2_run_root_or_sudo chmod 0600 "$_idx" 2>/dev/null; }; then
        # A failed re-restrict means index.sqlite may stay group-readable
        # (0660 left by the content publisher) — the exact criterion-2 break.
        # Surface it via the helper's return code so the reapply driver records
        # an error row (and the create-path warn fires). Still NON-fatal at the
        # call sites (they `|| bridge_warn`), matching the #1506/#1533 contract.
        bridge_warn "normalize_memory_tree: could not reassert 0600 on '$_idx' — it may remain group-readable; re-run \`agent-bridge isolate <a> --reapply\`."
        _rc=1
      fi
    elif [[ -L "$_idx" ]]; then
      bridge_warn "normalize_memory_tree: refusing symlinked index.sqlite at '$_idx' (planted-redirect guard); not chmod'd."
    fi
  done
  return "$_rc"
}

# ---------------------------------------------------------------------------
# 4b. ACL scrub — strip pre-v2 ACL entries before the chmod pass
# ---------------------------------------------------------------------------

bridge_isolation_v2_acl_scrub_path_allowed() {
  # Returns 0 when the given root is inside an allow-list:
  #   - $BRIDGE_DATA_ROOT/ (any subtree of the v2 data root)
  #   - $BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/agent-bridge-*  (per-agent home)
  # Returns 1 for anything else, in particular the controller's home.
  #
  # Both target and the allow-list roots are passed through `cd -P`/`pwd -P`
  # so symlinked prefixes (e.g. macOS `/tmp -> /private/tmp`) compare cleanly.
  local target="$1"
  [[ -n "$target" ]] || return 1
  local target_abs
  target_abs="$(cd -P "$target" 2>/dev/null && pwd -P)" || target_abs="$target"
  local dr="${BRIDGE_DATA_ROOT:-}"
  if [[ -n "$dr" ]]; then
    local dr_abs
    dr_abs="$(cd -P "$dr" 2>/dev/null && pwd -P)" || dr_abs="$dr"
    case "$target_abs" in
      "$dr_abs"|"$dr_abs"/*) return 0 ;;
    esac
  fi
  local iso_root="${BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT:-/home}"
  local iso_abs
  iso_abs="$(cd -P "$iso_root" 2>/dev/null && pwd -P)" || iso_abs="$iso_root"
  case "$target_abs" in
    "$iso_abs"/agent-bridge-*) return 0 ;;
  esac
  return 1
}

bridge_isolation_v2_acl_scrub() {
  # Recursively remove every named ACL entry on the tree. Required by the
  # migration tool: pre-v2 (v1) installs left ACLs on agent paths that
  # would override v2 group permissions in a way the operator can not
  # see from `ls -l`. Linux uses `setfacl -bR`; macOS has no `setfacl`,
  # so `chmod -R -P -N` (`-P` = no-symlink-follow, `-N` = remove ACL).
  #
  # r2 review fix: the migration writes an err log on the controller and
  # then advances the global v2 marker after this scrub. If we silently
  # swallowed scrub failures, the install would land in an "isolation-v2
  # marker present + leftover ACLs override the new POSIX bits" state —
  # the contract break codex flagged. We now propagate the scrub rc and
  # the migration caller turns that into a `bridge_die` so the marker is
  # never advanced on a half-scrubbed tree.
  #
  # Errors from the scrub command itself are captured in a temp file and
  # echoed via bridge_warn so operators have something to grep when they
  # rerun. The err-file path is opportunistic; if mktemp itself fails we
  # still surface the rc.
  local root="$1"
  [[ -n "$root" ]] || {
    bridge_warn "acl_scrub: root required"
    return 1
  }
  # r15 codex Probe 5 — path guard FIRST, before the directory check.
  # Earlier the guard ran AFTER `[[ -d "$root" ]] || return 0`, so a
  # caller passing a controller-credential FILE (not directory) hit
  # the early return and false-passed without the guard ever running.
  # That meant a misrouted scrub against the Anthropic credential
  # would silently no-op instead of refusing — operator could not
  # tell whether the scrub had stripped the named-user ACL or not.
  if ! bridge_isolation_v2_acl_scrub_path_allowed "$root"; then
    bridge_warn "acl_scrub: refusing path outside BRIDGE_DATA_ROOT or /home/agent-bridge-* (controller credential ACL guard, refs #781): $root"
    return 1
  fi
  if [[ -f "$root" ]]; then
    # File path inside the allowlist: refuse loudly. Per-file ACL scrub
    # is not part of the bulk-strip contract; callers that need to
    # strip a single file's ACL should use setfacl directly with
    # explicit named-entry deletion. This refusal prevents a caller
    # from passing e.g. `agents/<X>/workdir/.teams/.env` and getting
    # a silent rc=0 while the file's ACL stays intact.
    bridge_warn "acl_scrub: refusing file path (use setfacl for per-file strip): $root"
    return 1
  fi
  [[ -d "$root" ]] || {
    bridge_warn "acl_scrub: $root is neither a directory nor regular file"
    return 1
  }
  local _scrub_err _rc
  _scrub_err="$(mktemp 2>/dev/null || printf '/dev/null')"
  if [[ "$(uname)" == "Darwin" ]]; then
    _bridge_isolation_v2_run_root_or_sudo \
      chmod -R -P -N "$root" 2>"$_scrub_err"
    _rc=$?
    if (( _rc != 0 )); then
      bridge_warn "acl_scrub: chmod -R -P -N failed at $root (rc=${_rc}); see ${_scrub_err}"
      [[ "$_scrub_err" != "/dev/null" ]] && rm -f "$_scrub_err"
      return 1
    fi
    # Self-verify: counterpart of the Linux setfacl post-verify added by
    # H2 / PR #755. `_bridge_isolation_v2_run_root_or_sudo` direct-first
    # may rc=0 even when the per-entry ACL strip didn't land. Darwin has
    # no getfacl; ACL entries surface as numbered prefix lines (`  0:`,
    # `  1:`, …) in `ls -le` output. Best-effort — empty trees or BSD ls
    # without ACL support yield no match, so verify passes.
    local _residual_acl
    _residual_acl="$(find "$root" -print0 2>/dev/null \
                      | xargs -0 ls -leOd 2>/dev/null \
                      | grep -E '^[[:space:]]+[0-9]+:' | head -n1 || true)"
    if [[ -n "$_residual_acl" ]]; then
      if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo -n chmod -R -P -N "$root" 2>/dev/null || true
      fi
      _residual_acl="$(find "$root" -print0 2>/dev/null \
                        | xargs -0 ls -leOd 2>/dev/null \
                        | grep -E '^[[:space:]]+[0-9]+:' | head -n1 || true)"
      if [[ -n "$_residual_acl" ]]; then
        bridge_warn "acl_scrub: residual ACL after chmod -R -P -N + sudo retry: $_residual_acl"
        [[ "$_scrub_err" != "/dev/null" ]] && rm -f "$_scrub_err"
        return 1
      fi
    fi
    [[ "$_scrub_err" != "/dev/null" ]] && rm -f "$_scrub_err"
    return 0
  fi
  if ! command -v setfacl >/dev/null 2>&1; then
    # No setfacl on this Linux box — POSIX ACLs cannot be present without
    # the toolchain that creates them, so a missing setfacl is treated as
    # "nothing to scrub". Do NOT silently bypass when setfacl IS present
    # but fails — that's the contract break we're closing.
    [[ "$_scrub_err" != "/dev/null" ]] && rm -f "$_scrub_err"
    return 0
  fi
  # Pre-check: when getfacl is available, treat "tree has no extended
  # ACLs" as a no-op. This avoids tripping on distros where `setfacl -b`
  # on a clean tree returns non-zero. Best-effort — when getfacl is
  # missing we fall through to the direct scrub.
  if command -v getfacl >/dev/null 2>&1; then
    local _ext_acls
    _ext_acls="$(getfacl --skip-base -R "$root" 2>/dev/null \
      | grep -v '^[[:space:]]*$' | grep -v '^#' | head -n 1 || true)"
    if [[ -z "$_ext_acls" ]]; then
      [[ "$_scrub_err" != "/dev/null" ]] && rm -f "$_scrub_err"
      return 0
    fi
  fi
  _bridge_isolation_v2_run_root_or_sudo \
    setfacl -bR "$root" 2>"$_scrub_err"
  _rc=$?
  if (( _rc != 0 )); then
    bridge_warn "acl_scrub: setfacl -bR failed at $root (rc=${_rc}); see ${_scrub_err}"
    return 1
  fi
  # Self-verify: mirrors the issue #746 / PR #749 fix shape for the
  # recursive chgrp path. `_bridge_isolation_v2_run_root_or_sudo` tries
  # direct first and may return rc=0 even when per-entry strip didn't
  # land (e.g. `acl` package build differences across distros, or the
  # sudo path silently degraded). Without this, the migrator advances
  # the v2 marker on a tree with surviving named ACLs and controller
  # group reads drift the same way #746 reported.
  #
  # When getfacl is unavailable on this Linux box we fall through to
  # the existing rc-only check (mirrors the pre-check fallback above).
  if command -v getfacl >/dev/null 2>&1; then
    local _residual_acl
    _residual_acl="$(getfacl --absolute-names --skip-base -R "$root" 2>/dev/null \
                      | grep -E '^(user|group|default:user|default:group):[^:]+:' | head -n1 || true)"
    if [[ -n "$_residual_acl" ]]; then
      # Retry sudo-only (skip direct-first), in case direct succeeded
      # on rc but failed on per-entry strip.
      if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo -n setfacl -bR "$root" 2>/dev/null || true
      fi
      _residual_acl="$(getfacl --absolute-names --skip-base -R "$root" 2>/dev/null \
                        | grep -E '^(user|group|default:user|default:group):[^:]+:' | head -n1 || true)"
      if [[ -n "$_residual_acl" ]]; then
        bridge_warn "acl_scrub: residual named ACL after setfacl -bR + sudo retry: $_residual_acl"
        [[ "$_scrub_err" != "/dev/null" ]] && rm -f "$_scrub_err"
        return 1
      fi
    fi
  fi
  [[ "$_scrub_err" != "/dev/null" ]] && rm -f "$_scrub_err"
  return 0
}

# ---------------------------------------------------------------------------
# 4c. privilege preflight — used by migration / upgrade callers
# ---------------------------------------------------------------------------

bridge_isolation_v2_privilege_preflight() {
  # Returns 0 when the caller has sufficient privilege to run the group
  # / membership / chmod mutations. Returns non-zero with bridge_warn
  # describing the missing capability — caller composes the
  # bridge_die remediation and decides whether to abort or skip.
  #
  # Linux: need root or passwordless sudo (groupadd / usermod / chmod
  # passes go through `_bridge_isolation_v2_run_root_or_sudo`).
  # Darwin: need passwordless sudo for `dseditgroup -o create/edit`
  # (admin members can technically run dseditgroup direct, but the
  # group-create path almost always needs sudo because system-managed
  # group ranges are protected).
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    return 0
  fi
  bridge_warn "isolation-v2 migration requires root or passwordless sudo (current uid=$(id -u))"
  return 1
}

bridge_isolation_v2_roster_has_isolated_agents() {
  # Returns:
  #   0  — at least one roster agent has effective linux-user isolation
  #   1  — roster fully iterated, NO agent is effectively isolated (confirmed
  #        shared-only / safe to skip)
  #   2  — predicate function or BRIDGE_AGENT_IDS array unavailable
  #        (unknown — callers MUST fall through to the existing path
  #        rather than treat as "no isolated")
  #
  # codex r1 needs-more catch (PR #882): merging rc=1 (confirmed-no-iso) and
  # rc=2 (unknown) in a single non-zero would let a Darwin host with a
  # broken roster predicate take the macOS skip branch, bypassing the
  # legitimate preflight. Splitting the unknown state into rc=2 lets the
  # caller gate "skip" on the confirmed rc=1 only.
  declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 || return 2
  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || return 2
  local _roster_agent
  for _roster_agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -n "$_roster_agent" ]] || continue
    if bridge_agent_linux_user_isolation_effective "$_roster_agent" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# 5. umask helpers — restore on every path
# ---------------------------------------------------------------------------

bridge_with_private_umask() {
  # Run a command under umask 007 so newly-created files are 0660 and
  # directories are 2770 (setgid bit applied separately by chmod). The
  # umask is restored on every exit path including `set -e` propagation
  # in a caller — RETURN trap fires when the function returns, normally
  # or via errexit, where post-hoc `umask "$saved"` would be skipped.
  # Double quotes capture the value at trap-set time.
  local saved
  saved="$(umask)"
  trap "umask $saved" RETURN
  umask 007
  "$@"
}

bridge_with_shared_umask() {
  # Run a command under umask 027 so newly-created files are 0640 and
  # directories are 2750. Restore on every exit path including `set -e`
  # propagation; see bridge_with_private_umask for the trap rationale.
  local saved
  saved="$(umask)"
  trap "umask $saved" RETURN
  umask 027
  "$@"
}

# ---------------------------------------------------------------------------
# 6. inventory helpers — for migration tool / docs / acceptance tests
# ---------------------------------------------------------------------------

bridge_isolation_v2_layout_summary() {
  # Print one-line key=value pairs describing the active v2 layout, or
  # `layout=legacy` when the v2 mode is not active. Useful for CLI/audit.
  if ! bridge_isolation_v2_active; then
    printf 'layout=legacy\n'
    return 0
  fi
  printf 'layout=v2\n'
  printf 'data_root=%s\n' "$BRIDGE_DATA_ROOT"
  printf 'shared_root=%s\n' "$BRIDGE_SHARED_ROOT"
  printf 'agent_root=%s\n' "$BRIDGE_AGENT_ROOT_V2"
  printf 'controller_state_root=%s\n' "$BRIDGE_CONTROLLER_STATE_ROOT"
  printf 'shared_group=%s\n' "$BRIDGE_SHARED_GROUP"
  printf 'controller_group=%s\n' "$BRIDGE_CONTROLLER_GROUP"
  printf 'agent_group_prefix=%s\n' "$BRIDGE_AGENT_GROUP_PREFIX"
}

# ---------------------------------------------------------------------------
# 6b. launchd lifecycle helpers (macOS upgrade) - v0.8.3
# ---------------------------------------------------------------------------
#
# `bridge_isolation_v2_migrate_wait_daemon_gone` polls 10s for an empty
# `bridge_daemon_all_pids` after `bridge-daemon.sh stop`. On macOS hosts
# installed via `scripts/install-daemon-launchagent.sh` the daemon is
# supervised by launchd with `KeepAlive=true`, so the unit respawns
# within 1-2 seconds of the kill. The poll never sees a clean window
# and the migration aborts with "daemon stop verification failed".
#
# Modern macOS (10.11+) deprecated `launchctl load`; the reliable
# lifecycle is `launchctl bootout` / `launchctl bootstrap` against the
# `gui/<uid>` domain. KeepAlive plist edits are not equivalent because
# they don't catch the dict-form `KeepAlive.AfterInitialDemand` or the
# legacy `OnDemand` key.
#
# State is recorded under `$BRIDGE_STATE_DIR/migration/launchd-restore.json`
# so a migration that crashes between bootout and bootstrap can be
# recovered on the next run via `restore_if_needed`.

bridge_isolation_v2_launchd_plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist' \
    "$HOME" "${BRIDGE_DAEMON_LAUNCHAGENT_LABEL:-ai.agent-bridge.daemon}"
}

bridge_isolation_v2_launchd_restore_file() {
  printf '%s/migration/launchd-restore.json' "${BRIDGE_STATE_DIR}"
}

bridge_isolation_v2_launchd_unload() {
  [[ "$(uname)" == "Darwin" ]] || return 0

  local plist_path
  plist_path="$(bridge_isolation_v2_launchd_plist_path)"
  [[ -f "$plist_path" ]] || return 0  # not launchd-managed

  local restore_file
  restore_file="$(bridge_isolation_v2_launchd_restore_file)"
  install -d -m 0755 "$(dirname "$restore_file")" 2>/dev/null \
    || mkdir -p "$(dirname "$restore_file")"

  local uid
  uid="$(id -u)"

  # Record what we're about to do so a crash can recover.
  printf '{"plist_path":"%s","uid":%s,"unloaded_at":"%s","restored_at":null}\n' \
    "$plist_path" "$uid" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$restore_file"

  # Best-effort bootout. Tolerate "service not loaded" - modern launchctl
  # returns non-zero in that case but the post-condition (unit not
  # loaded) is what we want regardless.
  launchctl bootout "gui/${uid}" "$plist_path" 2>/dev/null || true

  # Verify daemon process actually gone - KeepAlive race window is
  # ~1-2s, so 50 attempts at 0.2s = 10s ceiling matches the existing
  # wait_daemon_gone budget.
  local attempt
  for attempt in $(seq 1 50); do
    if [[ -z "$(bridge_daemon_all_pids 2>/dev/null || true)" ]]; then
      return 0
    fi
    sleep 0.2
  done
  bridge_warn "launchd_unload: daemon still alive after bootout - may need manual launchctl bootout"
  return 1
}

bridge_isolation_v2_launchd_bootstrap() {
  [[ "$(uname)" == "Darwin" ]] || return 0

  local plist_path
  plist_path="$(bridge_isolation_v2_launchd_plist_path)"
  [[ -f "$plist_path" ]] || return 0

  local restore_file
  restore_file="$(bridge_isolation_v2_launchd_restore_file)"
  local uid
  uid="$(id -u)"

  if ! launchctl bootstrap "gui/${uid}" "$plist_path" 2>/dev/null; then
    bridge_warn "launchd_bootstrap: bootstrap failed; daemon may need manual restart"
    return 1
  fi

  # Mark restore complete by removing the save file.
  if [[ -f "$restore_file" ]]; then
    rm -f "$restore_file" 2>/dev/null || true
  fi
  return 0
}

# Recovery hook: call from the migrate apply path BEFORE bootout, so a
# previous-run leftover bootout (no bootstrap yet) gets restored first.
# This is the cross-run safety net for the case where the EXIT trap in
# `apply_for_upgrade` did not fire (SIGKILL / power loss / OOM).
bridge_isolation_v2_launchd_restore_if_needed() {
  [[ "$(uname)" == "Darwin" ]] || return 0
  local restore_file
  restore_file="$(bridge_isolation_v2_launchd_restore_file)"
  [[ -f "$restore_file" ]] || return 0
  bridge_warn "launchd: detected stale unload from prior run - restoring before retry"
  bridge_isolation_v2_launchd_bootstrap
}

# ---------------------------------------------------------------------------
# 6c. isolation grant matrix — single contract for migrate/prepare/reapply/verify
# ---------------------------------------------------------------------------
#
# v0.9.7 (refs #781): every required-access path for an isolated agent is now
# enumerated in one matrix. Migration, prepare, reapply, daemon writers, and
# the new `agent-bridge isolation verify` CLI all consume the same matrix
# rows so a fix at one site cannot leave the next required path unverified.
# See docs/agent-runtime/v2-isolation-grant-matrix.md (PR 3) for the design
# rationale and the row-by-row breakdown.
#
# Row schema (one TSV per matrix entry — pipe-delimited because TSV columns
# contain spaces in `notes`):
#   row_name|path|access_type|owner|group|dir_mode|file_mode|setgid|grant_mechanism|criticality|notes
#
# Field meaning:
#   row_name        stable identifier so callers can ensure_matrix_path by name
#   path            absolute path with `<X>` already substituted for the agent
#   access_type     dir | file | dir_only_traverse — verifier picks probes
#   owner           expected owner (`controller` token resolved at apply time)
#   group           expected group (`ab-agent-<X>`, `ab-shared`, `ab-controller`)
#   dir_mode        for `access_type=dir`/`dir_only_traverse`, the directory mode
#   file_mode       for `access_type=file`, the file mode (or '' if not file)
#   setgid          1 when the dir mode includes the setgid bit, 0 otherwise
#   grant_mechanism group_setgid | controller_credential_group | install_managed
#   criticality     required | optional | not-applicable (PR 1 has only required)
#   notes           short human reference for the verify CLI's suggested_fix
#
# Out-of-scope for PR 1 (RC6 per-agent plugin cache + criticality split lands
# in PR 2; upgrade reproducer + docs land in PR 3).

bridge_isolation_v2_matrix_rows_for_agent() {
  # Emit one matrix row per line for the named agent. Caller should pipe
  # through a dispatcher (`bridge_isolation_v2_apply_grant_matrix_for_agent`)
  # that resolves `controller` to the live controller user and applies or
  # checks per row. Returns non-zero only when the agent argument is invalid
  # (the matrix itself is static contract, not roster-dependent).
  local agent="$1"
  [[ -n "$agent" ]] || {
    bridge_warn "matrix_rows_for_agent: agent name required"
    return 1
  }
  local data_root shared_root
  data_root="${BRIDGE_DATA_ROOT:-}"
  shared_root="${BRIDGE_SHARED_ROOT:-${data_root:+$data_root/shared}}"
  local agent_root="${data_root:+$data_root/agents/$agent}"
  local state_root="${BRIDGE_HOME:-}/state"
  local state_agents_root="${state_root}/agents"
  local state_agent_dir="${state_agents_root}/$agent"
  # state/cron/{,runs} are dispatch-shared parents that the isolated agent
  # UID must be able to TRAVERSE into in order to reach the per-run leaf
  # (the leaf itself is grant_isolation'd to 2770 in lib/bridge-cron.sh).
  # See bridge-lib.sh:225 (BRIDGE_CRON_STATE_DIR) + lib/bridge-cron.sh:202
  # (run dir layout).
  local state_cron_root="${BRIDGE_CRON_STATE_DIR:-${state_root}/cron}"
  local state_cron_runs_root="${state_cron_root}/runs"
  local shared_grp="${BRIDGE_SHARED_GROUP:-ab-shared}"
  local ctrl_grp="${BRIDGE_CONTROLLER_GROUP:-ab-controller}"
  local iso_user="${BRIDGE_AGENT_OS_USER_PREFIX:-agent-bridge-}${agent}"
  local iso_home_root="${BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT:-/home}"
  local iso_home="${iso_home_root}/${iso_user}"

  # #909: branch the per-agent matrix rows on the agent's isolation_mode.
  # Same family as #895 (workdir resolver) — v2 layout can be active while
  # individual agents run in shared mode (default for `agb --claude --name
  # <X>` dynamic spawn and for installs that never opted any agent into
  # linux-user isolation). Linux-user rows reference the per-agent UID
  # `agent-bridge-<X>` and group `ab-agent-<X>`, neither of which exists
  # on a shared-only install. Without this branch a freshly created
  # shared agent fails ensure_matrix_path on every state-marker write
  # (chown to nonexistent user/group), so write_agent_state_marker returns
  # 1, the idle-since marker never lands, and the always-on daemon
  # restart-loops the tmux session indefinitely.
  # #1048: an indeterminate isolation_mode (the function undefined, a
  # nonzero exit, or an empty/unknown value from a roster read that raced
  # a concurrent typed-roster rewrite) must fall back to `shared`, NOT
  # `linux-user`. The shared rows are group-less and reference no
  # per-agent UID, so they apply cleanly on any install. The linux-user
  # rows demand `ab-agent-<X>` / `agent-bridge-<X>` plumbing that a
  # shared-only install never created — defaulting an indeterminate
  # result there makes ensure_matrix_path fail on every state-marker
  # write for a misclassified shared agent. Only an explicit
  # `linux-user` selects the linux-user matrix.
  local _v2_isolation_mode="shared"
  if command -v bridge_agent_isolation_mode >/dev/null 2>&1; then
    _v2_isolation_mode="$(bridge_agent_isolation_mode "$agent" 2>/dev/null || printf 'shared')"
  fi
  case "$_v2_isolation_mode" in
    linux-user) ;;
    *) _v2_isolation_mode="shared" ;;
  esac

  # r2 P1 #1: defer agent_grp resolution until we know we're in linux-user
  # mode. bridge_isolation_v2_agent_group_name rejects names outside
  # `[a-z_][a-z0-9_-]*` (POSIX group-name shape), but bridge-core.sh accepts
  # broader names in shared mode (digits/dots/hyphens/uppercase). Resolving
  # here in shared mode would fail the whole matrix emit for a legitimate
  # shared agent like `foo.bar`, which is the exact wedge the #909 fix
  # exists to close. Shared rows use `controller_group` (resolved at
  # apply_row time) instead of the per-agent group.
  local agent_grp=""
  if [[ "$_v2_isolation_mode" != "shared" ]]; then
    agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null)" || {
      bridge_warn "matrix_rows_for_agent: cannot resolve agent group for '$agent'"
      return 1
    }
  fi

  # ----- BRIDGE_DATA_ROOT + BRIDGE_AGENT_ROOT_V2 traverse rows (#1078 F2) -----
  # Issue #1078 F2: a fresh v2 install creates `data/` (BRIDGE_DATA_ROOT)
  # and `data/agents/` (BRIDGE_AGENT_ROOT_V2) under the controller's umask,
  # which is often 077 → mode 0700. With 0700 the isolated UID (a member
  # of ab-shared, not the controller) cannot traverse `data/agents/` to
  # reach its own `data/agents/<X>/` (which is 2750 root:ab-agent-<X>).
  # The result: every isolated agent is fundamentally non-functional —
  # bridge-start.sh fails to enter the per-agent workdir, the daemon's
  # state-marker writes return EACCES, and there is no `isolation verify`
  # row for these parents to surface the drift.
  #
  # Layout comment at top of file documents `$BRIDGE_DATA_ROOT/  mode 755
  # (others traverse)`. We pick the same `dir_only_traverse` pattern as
  # state-root / state-agents-root — controller:ab-shared 0710 — so every
  # isolated UID (always a member of ab-shared) gets `--x` and nothing
  # else. 0711 (others +x) would also work but widens the surface
  # unnecessarily; 0710 + ab-shared narrows to the exact set of
  # accounts that should be reaching v2 agent dirs.
  if [[ -n "$data_root" ]]; then
    printf 'data-root|%s|dir_only_traverse|controller|%s|0710||0|group_setgid|required|#1078 F2: isolated UID needs --x to reach data/agents/<X>\n' \
      "$data_root" "$shared_grp"
  fi
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
    printf 'data-agents-root|%s|dir_only_traverse|controller|%s|0710||0|group_setgid|required|#1078 F2: isolated UID needs --x to reach its own agent dir\n' \
      "$BRIDGE_AGENT_ROOT_V2" "$shared_grp"
  fi

  # ----- shared/ row family (catalog/source only — RC6 per-agent cache
  # lands in PR 2 as a separate row family) -----
  if [[ -n "$shared_root" ]]; then
    printf 'shared-root|%s|dir|controller|%s|2750||1|group_setgid|required|shared catalog/source root\n' \
      "$shared_root" "$shared_grp"
    printf 'shared-plugins-cache|%s/plugins-cache|dir|controller|%s|2750|0640|1|group_setgid|required|shared plugin catalog/source (RC6 per-agent cache is PR 2)\n' \
      "$shared_root" "$shared_grp"
    printf 'shared-memory-daily-aggregate|%s/memory-daily/aggregate|dir|controller|%s|2750|0640|1|group_setgid|required|memory-daily aggregate read by isolated UIDs\n' \
      "$shared_root" "$shared_grp"
  fi

  # ----- per-agent root + writable subdirs + credentials -----
  if [[ -n "$agent_root" ]]; then
    if [[ "$_v2_isolation_mode" == "shared" ]]; then
      # #909 shared-mode row family: operator-owned, controller primary
      # group. Mode 2750 for the root mirrors linux-user (root-owned
      # 2750: only the controller can write at the root), but the
      # writable subdirs widen to mode 2770 with `controller`+
      # `controller_group` so the controller (which IS the agent process
      # in shared mode) can write. No `ab-agent-<X>` group required, no
      # `agent-bridge-<X>` user required. The credentials/runtime files
      # keep mode 0640 (controller-only write, group-read) so a future
      # mode migration to per-agent isolation does not regress secrets.
      printf 'agent-root|%s|dir|controller|controller_group|2750||1|group_setgid|required|#909 shared-mode: controller-owned per-agent root\n' \
        "$agent_root"
      local sub
      for sub in home workdir runtime logs requests responses; do
        printf 'agent-%s|%s/%s|dir|controller|controller_group|2770|0660|1|group_setgid|required|#909 shared-mode writable subtree\n' \
          "$sub" "$agent_root" "$sub"
      done
      printf 'agent-credentials-dir|%s/credentials|dir|controller|controller_group|2750|0640|1|group_setgid|required|#909 shared-mode credentials dir\n' \
        "$agent_root"
      printf 'agent-launch-secrets|%s/credentials/launch-secrets.env|file|controller|controller_group||0640|0|group_setgid|required|#909 shared-mode launch secret env file\n' \
        "$agent_root"
      printf 'agent-env-sh|%s/runtime/agent-env.sh|file|controller|controller_group||0640|0|group_setgid|required|#909 shared-mode cached launch env\n' \
        "$agent_root"
    else
      printf 'agent-root|%s|dir|root|%s|2750||1|group_setgid|required|root-owned 2750: isolated UID enters via group r-x, no group write\n' \
        "$agent_root" "$agent_grp"
      local sub
      for sub in home workdir runtime logs requests responses; do
        printf 'agent-%s|%s/%s|dir|%s|%s|2770|0660|1|group_setgid|required|writable subtree (RC4=runtime RC5=logs)\n' \
          "$sub" "$agent_root" "$sub" "$iso_user" "$agent_grp"
      done
      printf 'agent-credentials-dir|%s/credentials|dir|controller|%s|2750|0640|1|group_setgid|required|controller writes launch-secrets.env, group reads\n' \
        "$agent_root" "$agent_grp"
      printf 'agent-launch-secrets|%s/credentials/launch-secrets.env|file|controller|%s||0640|0|group_setgid|required|launch secret env file (mode 0640 contract)\n' \
        "$agent_root" "$agent_grp"
      printf 'agent-env-sh|%s/runtime/agent-env.sh|file|controller|%s||0640|0|group_setgid|required|cached launch env\n' \
        "$agent_root" "$agent_grp"
    fi
  fi

  # ----- RC1/RC2: $BRIDGE_HOME/state/{,agents/,agents/<X>} -----
  if [[ -n "$state_root" ]]; then
    # RC1 design choice (Q2 in design v2): state/ + state/agents/ get
    # execute-only traversal via the controller group so isolated hooks
    # can reach the per-agent leaf without opening daemon-owned siblings.
    # The leaf directory itself takes the writable per-agent contract so
    # idle-since etc. can be unlinked by the isolated UID (RC2 fix).
    # #1161 r2: mode broadened from 0710 to 0711 (others --x). The
    # ab-shared group grant remains the primary traversal path; the
    # extra `others --x` covers isolated UIDs that are NOT reliably
    # joined to `ab-shared` on real installs (the marker readability
    # premise of #1161). Dir contents are still non-listable for the
    # non-owner — only specific files reachable by full path. Without
    # this, state-root at 0710 blocks isolated `sudo -u <agent> cat
    # $BRIDGE_HOME/state/layout-marker.sh` before the file's 0644 mode
    # matters (POSIX traversal fails at the parent).
    printf 'state-root|%s|dir_only_traverse|controller|%s|0711||0|group_setgid|required|isolated UID needs --x to reach state/agents/<X> and state/layout-marker.sh (#1161)\n' \
      "$state_root" "$shared_grp"
    printf 'state-agents-root|%s|dir_only_traverse|controller|%s|0711||0|group_setgid|required|isolated UID needs --x to reach its own leaf (#1161)\n' \
      "$state_agents_root" "$shared_grp"
    # state/cron/{,runs} get traverse-only via ab-shared so cron dispatch
    # writes (controller side) + the isolated UID's reads of its own
    # per-run leaf both work. The leaf itself is granted 2770 + default
    # ACL in lib/bridge-cron.sh::bridge_cron_run_dir_grant_isolation —
    # this row only opens the traversal path.
    printf 'state-cron-root|%s|dir_only_traverse|controller|%s|0710||0|group_setgid|required|isolated UID needs --x to reach state/cron/runs/<run_id>\n' \
      "$state_cron_root" "$shared_grp"
    printf 'state-cron-runs-root|%s|dir_only_traverse|controller|%s|0710||0|group_setgid|required|isolated UID needs --x to reach its own per-run leaf\n' \
      "$state_cron_runs_root" "$shared_grp"
    # Issue #1359 tactical staging delegation for `agb cron create`.
    # The staging tree is per-agent rooted to defeat the cross-agent
    # forge gap codex r1 #1 flagged: a flat staging dir under ab-shared
    # 2770 would let any iso UID rewrite a peer's request file
    # in-place or pre-create a peer's result.json before the daemon
    # picks it up.
    #
    # Two-tier layout:
    #   - shared root `state/cron-staging/`: dir_only_traverse mode
    #     0711 / group=ab-shared. Every iso UID gets --x to enter,
    #     but no read/list of peers' subdir names. The controller
    #     (owner) can list for scan/apply/sweep.
    #   - per-agent subdir `state/cron-staging/<X>/`: emitted in the
    #     per-agent branch below as `state-cron-staging-agent-dir`
    #     mode 2770 group=ab-agent-<X> so only that agent's iso UID
    #     has group-write. Files inside inherit ab-agent-<X> via
    #     setgid + land at mode 0660 owner=iso UID.
    printf 'state-cron-staging-root|%s|dir_only_traverse|controller|%s|0711||0|group_setgid|required|#1359 r2: shared staging root; iso UIDs traverse only, per-agent subdir carries the write grant\n' \
      "${BRIDGE_CRON_STAGING_DIR:-${state_root}/cron-staging}" "$shared_grp"
    # Issue #1359 r2: per-agent staging subdir. Mode 2770 +
    # group=ab-agent-<X> (iso branch) or controller_group (shared
    # branch) so only the named agent's iso UID has group-write — the
    # cross-agent forge gap codex r1 #1 flagged closes here. Files
    # inside inherit the group via setgid and land at mode 0660
    # owner=iso UID. The daemon (controller) reads via owner of the
    # parent + ownership of the file (after the iso UID writes it).
    local state_cron_staging_root="${BRIDGE_CRON_STAGING_DIR:-${state_root}/cron-staging}"
    local state_cron_staging_agent_dir="${state_cron_staging_root}/${agent}"
    if [[ "$_v2_isolation_mode" == "shared" ]]; then
      # #909 family: shared-mode per-agent staging subdir, controller-
      # owned with the controller's primary group. Iso UIDs don't
      # exist in shared mode, but the controller still writes / reads.
      printf 'state-cron-staging-agent-dir|%s|dir|controller|controller_group|2770|0660|1|group_setgid|required|#1359 r2 shared-mode per-agent staging subdir\n' \
        "$state_cron_staging_agent_dir"
      # #909: state-agent-dir under shared mode is operator-owned; the
      # `ab-agent-<X>` group does not exist. write_agent_state_marker
      # calls ensure_matrix_path "state-agent-dir" before every idle-since
      # write, so this row is the hottest fail surface on a shared-only
      # install.
      printf 'state-agent-dir|%s|dir|controller|controller_group|2770|0660|1|group_setgid|required|#909 shared-mode per-agent state leaf\n' \
        "$state_agent_dir"
    else
      printf 'state-cron-staging-agent-dir|%s|dir|controller|%s|2770|0660|1|group_setgid|required|#1359 r2 per-agent staging subdir; only this agent has group-write\n' \
        "$state_cron_staging_agent_dir" "$agent_grp"
      # Issue #1165 Gap 6 (r2): the per-agent state-agent-dir leaf keeps
      # its per-agent group `ab-agent-<X>` (NOT `ab-shared`). The r1 fix
      # widened to `ab-shared` so the Stop hook (running as the isolated
      # UID) could satisfy `ensure_matrix_path` without escalation, but
      # that opened a cross-agent integrity hole: any isolated UID in
      # `ab-shared` could create/delete `manual-stop` and
      # `broken-launch` markers in any OTHER agent's leaf and suppress
      # that agent's autostart / daemon wake.
      #
      # The r2 fix preserves the per-agent integrity boundary
      # (`controller:ab-agent-<X>:2770`) and addresses the Stop-hook
      # failure mode at the writer instead — see
      # `bridge_isolation_v2_write_agent_state_marker` below, which
      # routes through `bridge_isolation_write_file_as_agent_user_via_bash`
      # (sudo-escalate as the isolated UID, bound to that agent's own
      # leaf scope via the per-agent sudoers entry).
      printf 'state-agent-dir|%s|dir|controller|%s|2770|0660|1|group_setgid|required|RC1: per-agent state leaf, isolated UID + controller rwx (per-agent integrity boundary; writes from iso hook go via sudo writer)\n' \
        "$state_agent_dir" "$agent_grp"
    fi
    # RC2: file-level rows are not enforced for files that may be absent
    # at apply time (idle-since, manual-stop, missing-marker-retries,
    # webhook-port, next-session.sha). The matrix grants the parent +
    # setgid so the writers inherit `ab-agent-<X>` automatically; the
    # writer helper sets mode 0660 explicitly.
  fi

  # ----- Legacy opt-in: controller Anthropic credentials read grant -----
  # Default OFF. Sharing the controller's rotating Claude OAuth file across
  # agents widens the secret surface and can invalidate every session when the
  # token is exposed or rotated. Operators that still need the old transition
  # behavior can opt in explicitly with BRIDGE_ENABLE_CONTROLLER_CREDENTIAL_ACL=1.
  if [[ "${BRIDGE_ENABLE_CONTROLLER_CREDENTIAL_ACL:-0}" == "1" ]]; then
    local ctrl_user="${SUDO_USER:-${USER:-${LOGNAME:-}}}"
    if [[ -n "$ctrl_user" ]]; then
      local ctrl_home
      ctrl_home="$(getent passwd "$ctrl_user" 2>/dev/null | cut -d: -f6)"
      if [[ -z "$ctrl_home" ]]; then
        ctrl_home="${HOME:-}"
      fi
      if [[ -n "$ctrl_home" ]]; then
        printf 'controller-credentials|%s/.claude/.credentials.json|file|%s|%s||0640|0|controller_credential_group|required|opt-in group-mode read grant for controller Claude credential (ab-shared)\n' \
          "$ctrl_home" "$ctrl_user" "${BRIDGE_SHARED_GROUP:-ab-shared}"
      fi
    fi
  fi

  # ----- isolated user's own private home (catalog symlink target etc.) -----
  # #909: skip the entire isolated-user-home + per-agent plugin row family
  # for shared-mode agents. These rows reference `agent-bridge-<X>` (a
  # Linux account that is never created for shared agents) — emitting them
  # would re-introduce the chown-to-nonexistent-user failure this fix
  # exists to close. Plugin install in shared mode lands under the
  # controller's own ~/.claude (the legacy path) instead of the per-agent
  # isolated home.
  if [[ -n "$iso_home_root" ]] && [[ "$_v2_isolation_mode" != "shared" ]]; then
    # Phase 3 (codex design 2026-05-24): the isolated HOME contract is
    # 2750 owner=$iso_user group=ab-agent-<agent>, NOT 0700 owner=iso
    # group=iso. The 0700 here was a v0.9.7-era contract that was
    # already superseded by `bridge_linux_prepare_agent_isolation`
    # (lib/bridge-agents.sh) and is now formalized in the shared
    # helper `bridge_linux_normalize_isolated_home_contract`. The
    # per-agent matrix path remains a no-op for the new reconciler
    # (the install-tree matrix at
    # `bridge_isolation_v2_install_tree_matrix_rows` emits the
    # canonical `agent_home_contract` rows), but we update this stale
    # contract here so a future audit trap doesn't catch a reader.
    printf 'isolated-user-home|%s|dir|%s|ab-agent-%s|2750||1|install_managed|required|isolated UIDs private home — owner=iso, group=ab-agent-<agent>, setgid+2750 (see bridge_linux_normalize_isolated_home_contract for SSOT)\n' \
      "$iso_home" "$iso_user" "$iso_user"

    # ----- v0.9.7 PR 2 (refs #781) RC6: per-agent plugin subsystem rows -----
    #
    # Per design v2 §"Per-agent plugin contract" / §"dev-plugin-cache
    # linker contract", v0.9.7 abandons the v1 shared dev-plugin-cache
    # design and replaces it with four per-agent rows under the isolated
    # home. Operator's binding principle: each isolated agent installs
    # its own plugins, logs in separately, and never shares cache or
    # credentials with another agent. The legacy controller credential
    # ACL row above is disabled unless explicitly opted in.
    #
    # All four rows use grant_mechanism `install_managed`: the matrix
    # apply path does not create or chmod these — `bridge_linux_share_
    # plugin_catalog` and `bridge-dev-plugin-cache.py` (running as the
    # isolated UID under bridge-start.sh's sudo wrap) own creation.
    # The matrix's job is to enumerate the rows so `agent-bridge
    # isolation verify` and the upgrader's pre/post checks measure
    # exactly what the agent will see at runtime.
    #
    # Criticality split (Q4 decision): rows tied to plugins are
    # `optional` for agents that declare no plugins (a Codex agent
    # with zero plugin: channels and zero BRIDGE_AGENT_PLUGINS does
    # not need a cache directory at all). Verify reports those as
    # degraded only and the CLI's `--strict-optional` flag escalates
    # them to required when the operator wants every row enforced
    # regardless of declaration.
    local iso_plugins_root="${iso_home}/.claude/plugins"
    local _v2_plugin_channels="" _v2_plugin_allowlist=""
    _v2_plugin_channels="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
    _v2_plugin_allowlist="$(bridge_agent_plugins_csv "$agent" 2>/dev/null || true)"
    local _v2_plugin_criticality="optional"
    if [[ "$_v2_plugin_channels" == *plugin:* ]] \
        || [[ -n "$_v2_plugin_allowlist" ]]; then
      _v2_plugin_criticality="required"
    fi

    # 1. Per-agent plugin runtime data (OAuth tokens, session state).
    #    Lifecycle: created by bridge_linux_share_plugin_catalog at
    #    lib/bridge-agents.sh:2007; preserved by unshare; removed only
    #    by explicit agent removal. Mode 0700 because plugin secrets
    #    live here and must NEVER be group-readable, including by the
    #    agent's own ab-agent-<X> group.
    printf 'isolated-plugin-data|%s/data|dir|%s|%s|0700||0|install_managed|%s|per-agent plugin runtime state and OAuth tokens (private to isolated UID)\n' \
      "$iso_plugins_root" "$iso_user" "$iso_user" "$_v2_plugin_criticality"

    # 2. Per-agent plugin credentials. This is the generic row covering
    #    ms365 Microsoft Graph tokens, cosmax-crm OAuth, GitHub PATs,
    #    Telegram bot tokens, Discord tokens, Teams app passwords, etc.
    #    Plugin install code controls the exact filename — the matrix
    #    just verifies the parent dir is private to the isolated UID.
    #    Files inside take 0600 when the plugin manages mode; dirs take
    #    0700. `install_managed` means matrix verify probes ownership
    #    and traversal but does not enforce a specific file mode.
    #    Same path as data/ today (per design v2 line 44 — credentials
    #    live under data/<plugin>/ in the current implementation), but
    #    the row is enumerated separately so a future split (e.g.
    #    plugins/credentials/) lands in one matrix entry rather than
    #    requiring all callers to track two paths.
    printf 'isolated-plugin-credentials|%s/data|dir|%s|%s|0700||0|install_managed|%s|per-agent plugin credential files (ms365/cosmax-crm/GitHub PAT etc; mode 0600 for files when plugin owns mode)\n' \
      "$iso_plugins_root" "$iso_user" "$iso_user" "$_v2_plugin_criticality"

    # 3. Per-agent plugin manifests (installed_plugins.json,
    #    known_marketplaces.json, marketplaces/). These are root-owned,
    #    group-writable so the isolated UID can take an flock and merge
    #    its per-UID installed_plugins.json (Issue #864 R3 — was 2750,
    #    which blocked flock on installed_plugins.json.lock and aborted
    #    launch with `channel-required plugin cache failed`).
    #    `installPath` entries inside installed_plugins.json must
    #    resolve to the per-agent cache row below — never to a shared
    #    dev-plugin-cache (rejected by Q3) and never to another agent's
    #    home. Verification of `installPath` resolution lives in
    #    `bridge-dev-plugin-cache.py` post-link checks, not in the
    #    bash matrix apply.
    printf 'isolated-plugin-manifests|%s|dir|root|%s|2770||1|install_managed|%s|per-agent plugin manifests (installed_plugins.json + marketplaces/) — installPath must resolve under same isolated home; group write required for flock\n' \
      "$iso_plugins_root" "$agent_grp" "$_v2_plugin_criticality"

    # 4. Per-agent plugin cache root. Per design v2 line 46 / Q3
    #    decision: NOT a symlink to a shared cache directory. The cache
    #    is materialized inside the isolated UID's own home by code
    #    running as that UID (bridge-dev-plugin-cache.py via the
    #    bridge-start.sh sudo wrap). Cache version dirs land under
    #    cache/<marketplace>/<plugin>/<version>/ and inherit the
    #    isolated UID:UID ownership. Mode 0700 because cache content
    #    is operationally private to one agent.
    #
    #    A missing cache directory is NOT itself a launch blocker —
    #    bridge-run.sh's RC6 sync step attempts to create it. Failure
    #    of the sync attempt routes through the criticality split in
    #    bridge-dev-plugin-cache.py: channel-required plugin failures
    #    block, optional (BRIDGE_AGENT_PLUGINS) plugin failures warn
    #    and continue. The matrix row enumerates the path so verify
    #    can probe ownership/mode when the directory exists.
    printf 'isolated-plugin-cache|%s/cache|dir|%s|%s|0700||0|install_managed|%s|per-agent plugin cache root (Q3 decision: NEVER a symlink to shared cache; created on demand by isolated UID)\n' \
      "$iso_plugins_root" "$iso_user" "$iso_user" "$_v2_plugin_criticality"
  fi
  return 0
}

bridge_isolation_v2_controller_user() {
  # Isolated agent hooks run with USER=agent-bridge-<agent>, but generated
  # agent envs carry the controller UID that authored the v2 layout.
  local controller_uid="${BRIDGE_CONTROLLER_UID:-}"
  local controller_user=""

  if [[ "$controller_uid" =~ ^[0-9]+$ ]] && command -v getent >/dev/null 2>&1; then
    controller_user="$(getent passwd "$controller_uid" 2>/dev/null | cut -d: -f1 || true)"
    if [[ -n "$controller_user" ]]; then
      printf '%s' "$controller_user"
      return 0
    fi
  fi

  controller_user="${SUDO_USER:-${USER:-${LOGNAME:-}}}"
  [[ -n "$controller_user" ]] || return 1
  printf '%s' "$controller_user"
}

bridge_isolation_v2_controller_primary_group() {
  # Resolve the controller user's primary group name. Used by the shared-
  # mode matrix branch (#909) — shared-mode per-agent rows are owned by the
  # operator (controller) and grouped by the operator's primary group rather
  # than the per-agent `ab-agent-<X>` group (which exists only for
  # linux-user isolation). This keeps `chown`/`chgrp` against real local
  # identifiers so apply_row does not fail with "user/group does not exist"
  # on a shared-only install.
  local controller_user=""
  controller_user="$(bridge_isolation_v2_controller_user 2>/dev/null || true)"
  [[ -n "$controller_user" ]] || return 1
  local group=""
  group="$(id -gn "$controller_user" 2>/dev/null || true)"
  [[ -n "$group" ]] || return 1
  printf '%s' "$group"
}

bridge_isolation_v2_identity_exists() {
  # Probe whether a POSIX user or group name resolves on the local host.
  # Used by apply_row's #909 belt-and-braces guard so a row referencing a
  # non-existent identity (e.g., `agent-bridge-mgmt` on a shared-only
  # install) is skipped rather than wedging the daemon.
  # Args: name, kind ("user" | "group")
  local name="$1"
  local kind="$2"
  [[ -n "$name" && -n "$kind" ]] || return 1
  case "$kind" in
    user)
      # Propagate getent's rc on Linux (authoritative). Fall through to
      # `id -u` on hosts without getent (macOS) — `id -u <missing>` is
      # also authoritative (rc=1).
      if command -v getent >/dev/null 2>&1; then
        getent passwd "$name" >/dev/null 2>&1
        return $?
      fi
      id -u "$name" >/dev/null 2>&1
      return $?
      ;;
    group)
      # Try getent first (Linux NSS). If getent is present, propagate its
      # rc — a successful lookup is rc=0, NSS-absent is non-zero, and
      # either result is authoritative.
      if command -v getent >/dev/null 2>&1; then
        getent group "$name" >/dev/null 2>&1
        return $?
      fi
      # macOS fallback: dscl returns rc=56 for eDSRecordNotFound. When
      # dscl is available, propagate its rc directly so the probe is
      # authoritative on macOS too (early-`return 0`-only made the probe
      # non-authoritative, defeating the purpose of the belt-and-braces
      # guard on macOS smokes).
      if command -v dscl >/dev/null 2>&1; then
        dscl . -read "/Groups/$name" >/dev/null 2>&1
        return $?
      fi
      # No probe primitive available — return success so the downstream
      # chown proceeds and surfaces its own error path. This is the
      # non-Linux, non-macOS fallback (rare in practice).
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_isolation_v2_apply_row() {
  # Internal dispatcher — applies (or checks) one matrix row.
  # Args:
  #   $1 mode    apply | check
  #   $2..$11   row fields in matrix order (row_name path access_type owner
  #             group dir_mode file_mode setgid grant_mechanism criticality)
  #   $12       agent (optional) — required for controller_credential_group
  #             and consulted by the #909 belt-and-braces fallback to gate
  #             "missing identity = warn" on shared-mode agents only.
  # Returns 0 on apply success / clean check, non-zero otherwise. Caller
  # is responsible for emitting per-row report rows; this helper only
  # mutates filesystem state (apply) or compares (check).
  local mode="$1"
  local row_name="$2"
  local path="$3"
  local access_type="$4"
  local owner="$5"
  local group="$6"
  local dir_mode="$7"
  local file_mode="$8"
  local setgid="$9"
  local mechanism="${10}"
  local criticality="${11}"
  local agent="${12:-}"

  # Resolve `controller` token at apply/check time so the matrix stays static.
  if [[ "$owner" == "controller" ]]; then
    owner="$(bridge_isolation_v2_controller_user 2>/dev/null || true)"
    [[ -n "$owner" ]] || {
      bridge_warn "apply_row($row_name): cannot resolve controller user"
      return 1
    }
  fi
  # #909: same indirection for the group field so shared-mode rows can
  # emit `controller_group` without baking the operator's primary group
  # name into the static matrix.
  if [[ "$group" == "controller_group" ]]; then
    group="$(bridge_isolation_v2_controller_primary_group 2>/dev/null || true)"
    [[ -n "$group" ]] || {
      bridge_warn "apply_row($row_name): cannot resolve controller primary group"
      return 1
    }
  fi

  case "$mechanism" in
    controller_credential_group)
      # RC3 named-user ACL — agent context is required to verify the
      # named-user grant and ancestor traversal entries. The orchestrating
      # caller (apply_grant_matrix_for_agent) routes apply+check directly
      # through the dedicated helpers below with $agent in scope, so this
      # branch should be unreachable in normal operation. If a third-party
      # caller invokes apply_row with no agent context (12th arg),
      # downgrade to fail-loud — silent ok was the v0.9.5/v0.9.6 RC3
      # recurrence anti-pattern.
      if [[ -z "$agent" ]]; then
        bridge_warn "apply_row($row_name): controller_credential_group requires agent context (\$12); refuse to false-pass"
        return 1
      fi
      if [[ "$mode" == "apply" ]]; then
        bridge_isolation_v2_apply_controller_credentials_read_grant "$agent" "$file_mode"
        return $?
      fi
      bridge_isolation_v2_check_controller_credentials_read_grant "$agent" "$path" "$file_mode"
      return $?
      ;;
    install_managed)
      # Isolated user's own home — touched only by ensure_user_home /
      # agent-remove. Apply is a no-op here (creating the user is a
      # prerequisite of prepare). Check confirms the directory exists.
      if [[ "$mode" == "apply" ]]; then
        return 0
      fi
      [[ -d "$path" ]]
      return $?
      ;;
    group_setgid)
      # Platform discriminator gate (S3): the group_setgid mechanism
      # is a silent no-op when v2 is not the security primitive on
      # this host (default: non-Linux). Callers don't see false-negative
      # chown/chmod failures against an `agent-bridge-*` user/group
      # that does not exist outside Linux. Operators can force via
      # BRIDGE_ISOLATION_REQUIRED=yes.
      bridge_isolation_v2_enforce || return 0
      ;;
    *)
      bridge_warn "apply_row($row_name): unknown grant_mechanism '$mechanism'"
      return 1
      ;;
  esac

  # #909 belt-and-braces: if the resolved owner/group does not exist on
  # this host, treat the apply branch as a non-fatal degraded skip ONLY
  # for shared-mode agents. The primary fix is the shared-mode row branch
  # in matrix_rows_for_agent, which emits operator-owned rows that ALWAYS
  # resolve. This guard is the second line of defense: if any matrix row
  # still slips through referencing a non-existent identity (e.g., a
  # future row family or a mis-routed caller passing an `ab-agent-<X>`
  # group on a shared-only install), a shared agent should NOT wedge into
  # a daemon restart-loop the operator cannot mitigate from an agent
  # session — same failure shape the original #909 report documents.
  #
  # r2 P1 #2: gate the downgrade on shared-mode. Linux-user rows in
  # matrix_rows_for_agent (`else` branches around the
  # `_v2_isolation_mode == "shared"` checks) reference `agent-bridge-<X>`
  # / `ab-agent-<X>`. A missing identity there is a real linux-user setup
  # bug (e.g., bridge_linux_prepare_agent_isolation never ran, useradd
  # failed silently); masking it with a warn would hide the bug and
  # leave the agent half-prepared. Without an agent in scope ($12 unset
  # — third-party caller), preserve the pre-r1 hard-fail behavior because
  # we cannot prove shared-mode.
  if [[ "$mode" == "apply" ]] \
      && [[ "$mechanism" == "group_setgid" ]]; then
    local _missing_kind="" _missing_name=""
    if ! bridge_isolation_v2_identity_exists "$owner" "user" 2>/dev/null; then
      _missing_kind="user"
      _missing_name="$owner"
    elif ! bridge_isolation_v2_identity_exists "$group" "group" 2>/dev/null; then
      _missing_kind="group"
      _missing_name="$group"
    fi
    if [[ -n "$_missing_kind" ]]; then
      local _agent_iso_mode=""
      if [[ -n "$agent" ]] \
          && command -v bridge_agent_isolation_mode >/dev/null 2>&1; then
        _agent_iso_mode="$(bridge_agent_isolation_mode "$agent" 2>/dev/null || true)"
      fi
      if [[ "$_agent_iso_mode" == "shared" ]]; then
        bridge_warn "apply_row($row_name): $_missing_kind '$_missing_name' does not exist on host — skipping apply (#909 shared-mode non-fatal)"
        return 0
      fi
      bridge_warn "apply_row($row_name): $_missing_kind '$_missing_name' does not exist on host (agent='${agent:-<unknown>}', mode='${_agent_iso_mode:-<unknown>}') — refusing to false-pass linux-user setup"
      return 1
    fi
  fi

  # group_setgid path — the common case.
  case "$access_type" in
    dir|dir_only_traverse)
      if [[ "$mode" == "apply" ]]; then
        # Create the directory if missing — most callers (prepare, daemon
        # writers) reach apply with the dir already extant; the mkdir is
        # for daemon ensure_matrix_path callers.
        if [[ ! -d "$path" ]]; then
          _bridge_isolation_v2_run_root_or_sudo mkdir -p "$path" || return 1
        fi
        _bridge_isolation_v2_run_root_or_sudo chown "$owner:$group" "$path" || return 1
        _bridge_isolation_v2_run_root_or_sudo chmod "$dir_mode" "$path" || return 1
        return 0
      fi
      # check
      [[ -d "$path" ]] || return 1
      local actual_mode
      actual_mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)"
      [[ -n "$actual_mode" ]] || return 1
      local want
      want="$(printf '%04o' "$((8#$dir_mode))" 2>/dev/null || printf '%s' "$dir_mode")"
      local got
      got="$(printf '%04o' "$((8#$actual_mode))" 2>/dev/null || printf '%s' "$actual_mode")"
      [[ "$want" == "$got" ]] || return 1
      # r2 codex catch — also compare owner:group. Without this, RC1-style
      # group drift (e.g. state/agents/<X> owned by ab-controller instead
      # of the row's expected `ab-agent-<X>`) false-passes the check
      # despite mode being correct. apply path (chown above) doesn't
      # accept token names ("controller" etc.) — caller must already
      # resolve tokens to actual user/group names — so check uses the
      # same resolved comparison.
      local actual_og want_og
      actual_og="$(stat -c '%U:%G' "$path" 2>/dev/null || stat -f '%Su:%Sg' "$path" 2>/dev/null)"
      [[ -n "$actual_og" ]] || return 1
      want_og="$owner:$group"
      [[ "$actual_og" == "$want_og" ]]
      return $?
      ;;
    file)
      if [[ "$mode" == "apply" ]]; then
        if [[ ! -e "$path" ]]; then
          # Files are not created by apply — daemon writers create them
          # via the matrix-aware writer. Treat absent as a no-op success
          # (verify will report mismatch separately).
          return 0
        fi
        _bridge_isolation_v2_run_root_or_sudo chown "$owner:$group" "$path" || return 1
        if [[ -n "$file_mode" ]]; then
          _bridge_isolation_v2_run_root_or_sudo chmod "$file_mode" "$path" || return 1
        fi
        return 0
      fi
      # check
      [[ -e "$path" ]] || return 1
      if [[ -n "$file_mode" ]]; then
        local actual
        actual="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)"
        [[ -n "$actual" ]] || return 1
        local want_f got_f
        want_f="$(printf '%04o' "$((8#$file_mode))" 2>/dev/null || printf '%s' "$file_mode")"
        got_f="$(printf '%04o' "$((8#$actual))" 2>/dev/null || printf '%s' "$actual")"
        [[ "$want_f" == "$got_f" ]] || return 1
      fi
      # r2 codex catch — owner:group drift also fails check, mirroring dir
      # branch above. Files inherit group from setgid parent in normal
      # operation, but a mis-grouped pre-existing file (e.g. RC2's
      # ec2-user:ab-controller idle-since) must surface here.
      local actual_og_f want_og_f
      actual_og_f="$(stat -c '%U:%G' "$path" 2>/dev/null || stat -f '%Su:%Sg' "$path" 2>/dev/null)"
      [[ -n "$actual_og_f" ]] || return 1
      want_og_f="$owner:$group"
      [[ "$actual_og_f" == "$want_og_f" ]]
      return $?
      ;;
    *)
      bridge_warn "apply_row($row_name): unknown access_type '$access_type'"
      return 1
      ;;
  esac
}

bridge_isolation_v2_apply_grant_matrix_for_agent() {
  # Walk every matrix row for the named agent and apply or check it.
  # Args:
  #   $1 agent
  #   $2 --apply | --check (default --check)
  # Output (--check mode): one line per row to stdout in TSV form
  #   <row_name>\t<path>\t<status>\t<expected>\t<actual>
  # Exit: 0 when every required row is satisfied; non-zero on any
  # required mismatch (--check) or apply failure (--apply).
  local agent="$1"
  local mode_flag="${2:---check}"
  [[ -n "$agent" ]] || {
    bridge_warn "apply_grant_matrix_for_agent: agent required"
    return 1
  }
  local mode="check"
  case "$mode_flag" in
    --apply) mode="apply" ;;
    --check|--dry-run) mode="check" ;;
    *)
      bridge_warn "apply_grant_matrix_for_agent: unknown mode '$mode_flag'"
      return 1
      ;;
  esac

  local rc=0 row line
  while IFS= read -r row || [[ -n "$row" ]]; do
    [[ -n "$row" ]] || continue
    # row format: row_name|path|access_type|owner|group|dir_mode|file_mode|setgid|mechanism|criticality|notes
    IFS='|' read -r r_name r_path r_access r_owner r_group r_dmode r_fmode r_setgid r_mech r_crit r_notes <<<"$row"
    local row_rc=0
    if [[ "$r_mech" == "controller_credential_group" ]]; then
      # RC3 — apply AND check both routed through dedicated helpers with
      # the agent in scope. apply_row alone cannot recover agent from row
      # data and would either false-pass or refuse the row. (r3 codex
      # catch: previously only the apply branch routed; check fell through
      # to apply_row which only verified mask::r--.)
      if [[ "$mode" == "apply" ]]; then
        # Pass r_fmode so apply repairs mode + closes other-bits to match
        # what check enforces (r5 codex catch — apply/check invariants
        # were asymmetric: apply set only ACL, check rejected mode/other).
        bridge_isolation_v2_apply_controller_credentials_read_grant \
          "$agent" "$r_fmode" \
          || row_rc=$?
      else
        # Pass r_fmode so the helper enforces the matrix-contracted file
        # mode (r4 codex catch — world-readable credentials false-passed).
        bridge_isolation_v2_check_controller_credentials_read_grant \
          "$agent" "$r_path" "$r_fmode" \
          || row_rc=$?
      fi
    else
      # r2 P1 #2: pass agent ($12) so apply_row's belt-and-braces fallback
      # can gate "missing identity = warn" on shared-mode agents only.
      bridge_isolation_v2_apply_row "$mode" \
        "$r_name" "$r_path" "$r_access" "$r_owner" "$r_group" \
        "$r_dmode" "$r_fmode" "$r_setgid" "$r_mech" "$r_crit" \
        "$agent" \
        || row_rc=$?
    fi
    if [[ "$mode" == "check" ]]; then
      local status="ok" expected actual mode_part=""
      if (( row_rc != 0 )); then
        # v0.9.7 PR 2 (Q4 split): a row whose criticality is `optional`
        # demotes mismatch to `degraded` and does NOT flip the overall
        # exit code by default. The CLI's `--strict-optional` flag
        # post-processes the rows it cares about (it sees the
        # criticality column emitted below) and escalates `degraded` to
        # `mismatch` when the operator wants strict enforcement. Keeping
        # the demotion here means matrix-direct callers
        # (apply_grant_matrix_for_agent invoked from migrate apply) get
        # the same lenient default — they only fail the apply when a
        # required row is broken.
        if [[ "$r_crit" == "optional" || "$r_crit" == "not-applicable" ]]; then
          status="degraded"
        else
          status="mismatch"
          rc=1
        fi
      fi
      if [[ -n "$r_dmode" && -n "$r_fmode" ]]; then
        mode_part="${r_dmode}/${r_fmode}"
      elif [[ -n "$r_dmode" ]]; then
        mode_part="$r_dmode"
      elif [[ -n "$r_fmode" ]]; then
        mode_part="$r_fmode"
      fi
      expected="$r_owner:$r_group${mode_part:+ }$mode_part"
      actual="$(bridge_isolation_v2_reapply_probe_owner_group_mode "$r_path" 2>/dev/null || printf 'unknown')"
      # v0.9.7 PR 2 (refs #781): emit the criticality as a 6th column
      # so `agent-bridge isolation verify --strict-optional` can promote
      # `degraded` rows to `mismatch` post-hoc without re-walking the
      # matrix. Existing 5-column consumers (PR 1's verify output)
      # tolerate the extra column because they read with `IFS=$'\t' read
      # -r _name _path _status _expected _actual` — trailing fields are
      # silently absorbed by the last variable in plain `read` only when
      # there are MORE fields than vars; with `read -r a b c d e` the
      # 6th field tail-attaches to `e`. Verify CLI is updated to read
      # the 6th column explicitly so the criticality stays addressable.
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$r_name" "$r_path" "$status" "$expected" "$actual" "$r_crit"
    elif (( row_rc != 0 )); then
      if [[ "$r_crit" == "optional" || "$r_crit" == "not-applicable" ]]; then
        bridge_warn "apply_grant_matrix_for_agent($agent): optional row $r_name degraded at $r_path (continuing)"
      else
        bridge_warn "apply_grant_matrix_for_agent($agent): row $r_name failed at $r_path"
        rc=1
      fi
    fi
  done < <(bridge_isolation_v2_matrix_rows_for_agent "$agent")
  return $rc
}

bridge_isolation_v2_ensure_matrix_path() {
  # Fast path for daemon writers: ensure the named matrix row's path
  # exists with correct ownership/mode before write. Idempotent — when
  # the row is already canonical this returns 0 with no mutation.
  # Args: row_name, agent
  local row_name="$1"
  local agent="$2"
  [[ -n "$row_name" && -n "$agent" ]] || {
    bridge_warn "ensure_matrix_path: row_name and agent required"
    return 1
  }
  # Platform discriminator gate (S3): isolation-v2 enforcement is a
  # silent no-op on hosts where v2 is not the security model (default:
  # non-Linux). Daemon writers proceed with the caller's normal FS
  # perms instead of seeing the chown/chmod path fail loudly.
  # Operators can force enforcement via BRIDGE_ISOLATION_REQUIRED=yes
  # (e.g., for self-test on a Linux container running rootless).
  bridge_isolation_v2_enforce || return 0
  local row
  row="$(bridge_isolation_v2_matrix_rows_for_agent "$agent" \
          | awk -F'|' -v n="$row_name" '$1 == n {print; exit}')"
  if [[ -z "$row" ]]; then
    bridge_warn "ensure_matrix_path: row '$row_name' not found for agent '$agent'"
    return 1
  fi
  IFS='|' read -r r_name r_path r_access r_owner r_group r_dmode r_fmode r_setgid r_mech r_crit r_notes <<<"$row"
  # r2 P1 #2: pass agent ($12) so apply_row's belt-and-braces fallback
  # can gate "missing identity = warn" on shared-mode agents only.
  if bridge_isolation_v2_apply_row "check" \
    "$r_name" "$r_path" "$r_access" "$r_owner" "$r_group" \
    "$r_dmode" "$r_fmode" "$r_setgid" "$r_mech" "$r_crit" \
    "$agent" 2>/dev/null; then
    return 0
  fi
  bridge_isolation_v2_apply_row "apply" \
    "$r_name" "$r_path" "$r_access" "$r_owner" "$r_group" \
    "$r_dmode" "$r_fmode" "$r_setgid" "$r_mech" "$r_crit" \
    "$agent"
}

# ---------------------------------------------------------------------------
# Helpers for controller credential group-mode (#998 PR A)
# ---------------------------------------------------------------------------
_bridge_isolation_v2_shared_group() {
  local name="${BRIDGE_SHARED_GROUP:-ab-shared}"
  getent group "$name" 2>/dev/null | cut -d: -f3
}

# Returns 0 (true) when BRIDGE_HOME is a live (non-tempdir) install
_bridge_isolation_v2_cred_is_live() {
  local bh="${BRIDGE_HOME:-}"
  case "$bh" in
    /tmp/*|/var/tmp/*) return 1 ;;
  esac
  if [[ -n "${TMPDIR:-}" ]]; then
    case "$bh" in
      "${TMPDIR%/}"/*) return 1 ;;
    esac
  fi
  return 0
}

# Emits each ancestor of PATH (parent → /, exclusive) one per line
_bridge_isolation_v2_cred_ancestors() {
  local p="$1"
  p="$(dirname "$p")"
  while [[ -n "$p" && "$p" != "/" && "$p" != "." ]]; do
    printf '%s\n' "$p"
    p="$(dirname "$p")"
  done
}

# Gate shared by apply and check.
# Returns 0 and prints the shared-group gid when the caller should proceed.
# Returns non-zero (skip gracefully) when platform/group preconditions fail.
# Platform/policy skip check for credential group-mode helpers.
# Returns 0 when Linux + auto/yes isolation policy is active.
# Returns 1 for graceful skip (non-Linux, BRIDGE_ISOLATION_REQUIRED=no, etc.).
# Does NOT check group existence — callers must resolve the group in their own
# shell so bridge_die can exit the parent shell, not a command-substitution subshell.
_bridge_isolation_v2_cred_platform_ok() {
  bridge_isolation_discriminator_auto_resolve >/dev/null
  [[ "$_BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED" == "yes" ]]
}

bridge_isolation_v2_apply_controller_credentials_read_grant() {
  # Replaces the former RC3 named-user ACL grant with ab-shared group-mode (#998 PR A).
  # Contracted state after apply:
  #   credential file  — setfacl -b (strip extended ACLs), chgrp ab-shared, chmod 0640
  #                      base group::r--, no world bits
  #   all ancestors    — strip generated agent-bridge-* named-user ACEs (targeted setfacl -x)
  #   private ancestors (no o+x) — additionally: chgrp ab-shared, chmod g+x,
  #                                 setfacl -m group::--x (traverse, no listing)
  local agent="$1"
  [[ -n "$agent" ]] || {
    bridge_warn "apply_controller_credentials_read_grant: agent required"
    return 1
  }

  # Platform/policy gate (non-Linux / BRIDGE_ISOLATION_REQUIRED=no → skip)
  _bridge_isolation_v2_cred_platform_ok || return 0
  # Group resolution before ACL tooling gate: missing group on live is always fatal,
  # even when setfacl/getfacl are absent.
  local _grp_gid
  _grp_gid="$(_bridge_isolation_v2_shared_group)"
  if [[ -z "$_grp_gid" ]]; then
    if _bridge_isolation_v2_cred_is_live; then
      bridge_die "controller credential group-mode: group '${BRIDGE_SHARED_GROUP:-ab-shared}' is missing. Create the group and add controller + isolated agent users, then restart."
    else
      bridge_warn "controller credential group-mode: group '${BRIDGE_SHARED_GROUP:-ab-shared}' missing; skipping (non-live)"
      return 0
    fi
  fi
  # ACL tooling gate (no setfacl/getfacl package → skip gracefully)
  command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 || return 0

  local ctrl_user="${SUDO_USER:-${USER:-${LOGNAME:-}}}"
  [[ -n "$ctrl_user" ]] || {
    bridge_warn "apply_controller_credentials_read_grant: cannot resolve controller user"
    return 1
  }
  local ctrl_home
  ctrl_home="$(getent passwd "$ctrl_user" 2>/dev/null | cut -d: -f6)"
  [[ -n "$ctrl_home" ]] || ctrl_home="${HOME:-}"
  [[ -n "$ctrl_home" ]] || {
    bridge_warn "apply_controller_credentials_read_grant: cannot resolve controller home"
    return 1
  }

  # cred_path constructed from parts to avoid static path strings in this file
  local cred_dir="${ctrl_home}/.claude"
  local cred_file="${cred_dir}/.credentials.json"

  if [[ -L "$cred_file" ]]; then
    bridge_warn "apply_controller_credentials_read_grant: refusing symlink at credential path (path guard)"
    return 1
  fi
  [[ -f "$cred_file" ]] || return 0  # not present yet — idempotent no-op

  local _pfx="${BRIDGE_AGENT_OS_USER_PREFIX:-agent-bridge-}"

  # Pass 1: strip generated agent-bridge-* named-user ACEs on ALL ancestors
  local anc
  while IFS= read -r anc; do
    [[ -e "$anc" ]] || continue
    local _existing_named
    _existing_named="$(getfacl -p "$anc" 2>/dev/null \
      | awk -F: -v p="$_pfx" '$1=="user" && $2!="" && substr($2,1,length(p))==p {print $2}')"
    if [[ -n "$_existing_named" ]]; then
      local _u
      while IFS= read -r _u; do
        [[ -n "$_u" ]] || continue
        _bridge_isolation_v2_run_root_or_sudo \
          setfacl -x "u:${_u}" "$anc" 2>/dev/null || {
            bridge_warn "apply_controller_credentials_read_grant: setfacl -x u:${_u} on $anc failed"
            return 1
          }
      done <<<"$_existing_named"
    fi
  done < <(_bridge_isolation_v2_cred_ancestors "$cred_file")

  # Credential file: strip all extended ACLs, then apply group-mode
  _bridge_isolation_v2_run_root_or_sudo setfacl -b "$cred_file" 2>/dev/null || {
    bridge_warn "apply_controller_credentials_read_grant: setfacl -b on credential file failed"
    return 1
  }
  _bridge_isolation_v2_run_root_or_sudo \
    chgrp "${BRIDGE_SHARED_GROUP:-ab-shared}" "$cred_file" 2>/dev/null || {
      bridge_warn "apply_controller_credentials_read_grant: chgrp ab-shared on credential file failed"
      return 1
    }
  _bridge_isolation_v2_run_root_or_sudo chmod 0640 "$cred_file" 2>/dev/null || {
    bridge_warn "apply_controller_credentials_read_grant: chmod 0640 on credential file failed"
    return 1
  }

  # Pass 2: private (non-o+x) ancestors get ab-shared traversal
  while IFS= read -r anc; do
    [[ -e "$anc" ]] || continue
    local _anc_mode
    _anc_mode="$(stat -c '%a' "$anc" 2>/dev/null)"
    # last octal digit: 0/2/4/6 = no o+x; 1/3/5/7 = o+x present
    case "${_anc_mode: -1}" in
      1|3|5|7) continue ;;  # public ancestor (o+x) — leave untouched
    esac
    # Private ancestor: grant group traversal only (no listing)
    _bridge_isolation_v2_run_root_or_sudo \
      chgrp "${BRIDGE_SHARED_GROUP:-ab-shared}" "$anc" 2>/dev/null || {
        bridge_warn "apply_controller_credentials_read_grant: chgrp ab-shared on $anc failed"
        return 1
      }
    _bridge_isolation_v2_run_root_or_sudo chmod g+x "$anc" 2>/dev/null || {
      bridge_warn "apply_controller_credentials_read_grant: chmod g+x on $anc failed"
      return 1
    }
    # Explicitly set base group::--x so the entry is effective even when
    # unrelated ACLs are present (mask can otherwise clamp group access)
    _bridge_isolation_v2_run_root_or_sudo \
      setfacl -m "group::--x" "$anc" 2>/dev/null || {
        bridge_warn "apply_controller_credentials_read_grant: setfacl -m group::--x on $anc failed"
        return 1
      }
  done < <(_bridge_isolation_v2_cred_ancestors "$cred_file")

  return 0
}

bridge_isolation_v2_check_controller_credentials_read_grant() {
  # Verifies group-mode contracted state. Pure POSIX + group checks.
  # Conditions:
  #   (a) cred file: gid=ab-shared, group-read bit set, no world bits
  #   (b) cred file: no extended ACL entries (no mask/named/default)
  #   (c) cred file: base group::r-- in getfacl output
  #   (d) all ancestors: no generated agent-bridge-* named-user ACEs
  #   (e) private (non-o+x) ancestors: gid=ab-shared, g+x set, base group::--x
  local agent="$1" path="$2" file_mode="${3:-0640}"
  [[ -n "$agent" && -n "$path" ]] || return 1
  [[ -f "$path" ]] || return 1

  # Platform/policy gate
  _bridge_isolation_v2_cred_platform_ok || return 0
  # Group resolution before ACL tooling gate: missing group on live is always fatal,
  # even when setfacl/getfacl are absent.
  local _grp_gid
  _grp_gid="$(_bridge_isolation_v2_shared_group)"
  if [[ -z "$_grp_gid" ]]; then
    if _bridge_isolation_v2_cred_is_live; then
      bridge_die "controller credential group-mode: group '${BRIDGE_SHARED_GROUP:-ab-shared}' is missing. Create the group and add controller + isolated agent users, then restart."
    else
      bridge_warn "controller credential group-mode: group '${BRIDGE_SHARED_GROUP:-ab-shared}' missing; skipping (non-live)"
      return 0
    fi
  fi
  # ACL tooling gate (no setfacl/getfacl package → skip gracefully)
  command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 || return 0

  local _pfx="${BRIDGE_AGENT_OS_USER_PREFIX:-agent-bridge-}"

  # (a) file gid and EXACT mode. apply chmods the credential to exactly
  # $file_mode (matrix default 0640); check must reject any widened mode
  # (0660 group-write, 0670/0770 group/owner-exec, etc.) — a loose
  # "group-read bit set + no world bits" test false-passes those and
  # re-opens the RC3 apply/verify-divergence recurrence (#778/#441/...).
  local file_gid file_mode_actual
  file_gid="$(stat -c '%g' "$path" 2>/dev/null)"
  file_mode_actual="$(stat -c '%a' "$path" 2>/dev/null)"
  [[ "$file_gid" == "$_grp_gid" ]] || return 1
  # normalize both to canonical octal (strips leading-zero / width diffs)
  local _exp_mode _got_mode
  _exp_mode="$(printf '%o' "$((8#${file_mode#0}))" 2>/dev/null || printf '%s' "${file_mode#0}")"
  _got_mode="$(printf '%o' "$((8#${file_mode_actual:-0}))" 2>/dev/null || printf '%s' "$file_mode_actual")"
  [[ -n "$_got_mode" && "$_got_mode" == "$_exp_mode" ]] || return 1

  # (b)+(c) getfacl: no extended entries, base group::r--
  local acl_out
  acl_out="$(getfacl -p "$path" 2>/dev/null)"
  [[ -n "$acl_out" ]] || return 1
  printf '%s\n' "$acl_out" | grep -qE '^mask::'   && return 1
  printf '%s\n' "$acl_out" | grep -qE '^user:[^:]+:' && return 1
  printf '%s\n' "$acl_out" | grep -qE '^default:'  && return 1
  local _grp_entry
  _grp_entry="$(printf '%s\n' "$acl_out" \
    | awk -F: '/^group::/ {print substr($3,1,3)}' | head -n1)"
  [[ "$_grp_entry" == "r--" ]] || return 1

  # (d)+(e) ancestor checks
  local anc
  while IFS= read -r anc; do
    [[ -e "$anc" ]] || continue
    local anc_acl
    anc_acl="$(getfacl -p "$anc" 2>/dev/null)"

    # (d) no generated agent-bridge-* ACEs on any ancestor
    if printf '%s\n' "$anc_acl" | grep -qE "^user:${_pfx}"; then
      return 1
    fi

    # (e) private ancestors only
    local _anc_mode
    _anc_mode="$(stat -c '%a' "$anc" 2>/dev/null)"
    case "${_anc_mode: -1}" in
      1|3|5|7) continue ;;  # public (o+x) — no further assertion
    esac
    local anc_gid
    anc_gid="$(stat -c '%g' "$anc" 2>/dev/null)"
    [[ "$anc_gid" == "$_grp_gid" ]] || return 1
    # g+x in stat: group digit (second from right) is 1,3,5,7
    [[ "${_anc_mode: -2:1}" =~ ^[1357]$ ]] || return 1
    # base group::--x (traverse only, no listing) in getfacl
    local _anc_grp
    _anc_grp="$(printf '%s\n' "$anc_acl" \
      | awk -F: '/^group::/ {print substr($3,1,3)}' | head -n1)"
    [[ "$_anc_grp" == "--x" ]] || return 1
  done < <(_bridge_isolation_v2_cred_ancestors "$path")

  return 0
}

# bridge_isolation_v2_reap_isolated_agent_account — issue #1010.
#
# Cleanup hook for `agent delete` on an isolated (linux-user) agent. Reaps
# the dedicated OS user `agent-bridge-<name>`, strips its named-user
# traversal ACEs from the controller credential ancestor set, and (best-
# effort) drops a matching per-agent group. ALL destructive steps are
# hard-gated and best-effort: a failure never aborts the delete, but every
# failure is reported visibly via bridge_warn so the operator can clean up
# by hand.
#
# Args:
#   $1 — agent name (the `<name>` being deleted)
#   $2 — expected OS user, resolved by the caller from the roster. This
#        function will ONLY ever act on a user whose name is EXACTLY
#        "${BRIDGE_AGENT_OS_USER_PREFIX:-agent-bridge-}<name>" — a non-
#        matching argument is rejected outright (never userdel a user the
#        bridge did not create).
#
# r3 (codex task #5740): internal helper for the sudoers drop-in
# removal decision. Takes the sudoers root as an EXPLICIT ARGUMENT —
# production passes /etc/sudoers.d hardcoded; the smoke at
# scripts/smoke/1121-agent-delete-os-purge.sh invokes this helper
# directly with a tmpdir to exercise the decision logic. There is no
# env-controlled root anymore (closes the r1/r2 bypass vector).
#
# Args:
#   $1 — agent (for warning messages only)
#   $2 — os_user (gated upstream by Gate 2 exact-match check)
#   $3 — sudoers_dir (production = /etc/sudoers.d; tests = tmpdir)
#
# The basename regex still pins `agent-bridge-<slug>` strictly; the
# sudoers_dir argument carries the trusted root. Best-effort: missing
# file is a clean no-op.
_bridge_isolation_v2_reap_sudoers_drop_in() {
  local agent="$1"
  local os_user="$2"
  local sudoers_dir="$3"
  local sudoers_path="${sudoers_dir}/agent-bridge-${os_user}"
  local sudoers_base="${sudoers_path##*/}"
  # The basename regex is the load-bearing defence — sudoers_dir is the
  # caller-trusted root and the caller is the production-hardcoded
  # /etc/sudoers.d or the smoke-fixture tmpdir; either way the basename
  # MUST be exactly `agent-bridge-<slug>` (no `..`, no glob).
  if [[ ! "$sudoers_base" =~ ^agent-bridge-[a-zA-Z0-9_-]+$ ]]; then
    bridge_warn "agent delete: skipping sudoers cleanup for '$agent' — composed path '$sudoers_path' does not match strict pattern (refusing to rm)"
  elif [[ -e "$sudoers_path" ]]; then
    if ! _bridge_isolation_v2_run_root_or_sudo rm -f -- "$sudoers_path"; then
      bridge_warn "agent delete: failed to remove sudoers drop-in '$sudoers_path' (best-effort — manual 'sudo rm -f $sudoers_path' may be needed)"
    fi
  fi
}

# Issue #1140: parallel of _bridge_isolation_v2_reap_sudoers_drop_in.
#
# Reap the OS-level home directory `<home_root>/<os_user>` left over after
# Step 1 `userdel <os_user>` (which intentionally runs without -r so we
# retain explicit control over the rm). PR #1129 closed #1121 partially
# (user/group/sudoers were cleaned) but `/home/agent-bridge-<a>` survived
# every isolated create/delete cycle and accumulated as orphan_directory
# rows in the watchdog scan.
#
# Args:
#   $1 — agent (for warning messages only — Gate 2 already validated)
#   $2 — os_user (already gated upstream by Gate 2 exact-match check
#                 against bridge_agent_default_os_user(agent))
#   $3 — home_root (production = "/home"; tests = tmpdir under
#                   $SMOKE_TMP_ROOT/home so the smoke can stage the
#                   exact tree without touching the real /home/*)
#
# Defence-in-depth:
#   - os_user basename MUST match `^agent-bridge-[a-zA-Z0-9_-]+$`. The
#     final absolute path is `<home_root>/<os_user>` and the basename
#     check pins the leaf to the exact account-name shape the bridge
#     auto-provisions via bridge_agent_default_os_user.
#   - Path must exist as a directory; a missing tree is a clean silent
#     no-op (no warning) so a host where the reap raced an external
#     cleanup does not produce alarm noise.
#   - `rm -rf` uses `--` separator so a path containing a leading `-`
#     (defence-only — the basename regex already rejects it) cannot be
#     interpreted as an option.
#   - Uses `_bridge_isolation_v2_run_root_or_sudo` (direct-first, sudo
#     fallback) because the tree is owned by the now-removed isolated
#     UID and the controller alone cannot recursively rm it on most
#     hosts. Failure emits a structured warning and returns 0 (never
#     aborts the reap — Step 2/3/4/6 still need to fire).
#
# Env-controlled root is explicitly OUT OF SCOPE (mirror the #1121 r3
# contract): production hardcodes `/home`; tests pass a tmpdir as a
# direct function argument.
_bridge_isolation_v2_reap_os_home_dir() {
  local agent="$1"
  local os_user="$2"
  local home_root="$3"
  local home_path="${home_root}/${os_user}"
  local home_base="${home_path##*/}"
  if [[ ! "$home_base" =~ ^agent-bridge-[a-zA-Z0-9_-]+$ ]]; then
    bridge_warn "agent delete: skipping OS home cleanup for '$agent' — composed path '$home_path' does not match strict pattern (refusing to rm)"
    return 0
  fi
  if [[ ! -d "$home_path" ]]; then
    return 0
  fi
  if ! _bridge_isolation_v2_run_root_or_sudo rm -rf -- "$home_path"; then
    bridge_warn "agent delete: failed to remove OS home dir '$home_path' (best-effort — manual 'sudo rm -rf $home_path' may be needed)"
  fi
  return 0
}

# Issue #1140: parallel of _bridge_isolation_v2_reap_sudoers_drop_in.
#
# Reap the v2 per-agent workdir tree at `<agent_root_v2>/<agent>`. On a
# v2 install this directory tree is `root:ab-agent-<a>` mode 2750 with
# `home/`, `workdir/`, `runtime/`, `logs/` children. PR #1129 left this
# tree behind because the sudoers reap focused on /etc/sudoers.d only;
# the watchdog correctly reported it as an orphan_directory (#1119) but
# the create/delete loop kept accumulating these trees on every cycle.
#
# Args:
#   $1 — agent (for warning messages + path composition; the basename
#                check pins it to the exact slug shape `agent create`
#                accepts so a misconfigured caller cannot escape the
#                v2 agent root)
#   $2 — agent_root_v2 (production = $BRIDGE_AGENT_ROOT_V2; tests = a
#                       tmpdir under $SMOKE_TMP_ROOT/data/agents)
#
# Defence-in-depth:
#   - agent basename MUST match `^[a-zA-Z0-9_-]+$`. The composed path
#     is `<agent_root_v2>/<agent>`; the basename check pins the leaf
#     to the same slug regex `agent create` validates against, so a
#     `..`, glob, or absolute path cannot be smuggled in.
#   - `agent_root_v2` must be a non-empty argument. If the production
#     caller could not resolve $BRIDGE_AGENT_ROOT_V2 (legacy install,
#     unset env) the helper is a clean silent no-op rather than
#     composing an attacker-controlled `/<agent>` rm target.
#   - Path must exist as a directory; missing tree = clean no-op.
#   - `rm -rf -- <path>` for the same reason as the sudoers helper.
#   - Uses `_bridge_isolation_v2_run_root_or_sudo` because the tree
#     parent is root-owned (mode 2750) on a v2 install — the
#     controller alone cannot rm the per-agent root without sudo.
#
# This helper does NOT touch `$BRIDGE_AGENT_ROOT_V2` itself or any
# sibling agent's directory; it only reaps the single `<agent>` child.
_bridge_isolation_v2_reap_v2_workdir() {
  local agent="$1"
  local agent_root_v2="$2"
  if [[ -z "$agent_root_v2" ]]; then
    return 0
  fi
  if [[ ! "$agent" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    bridge_warn "agent delete: skipping v2 workdir cleanup for '$agent' — agent slug does not match strict pattern (refusing to rm)"
    return 0
  fi
  local workdir_path="${agent_root_v2}/${agent}"
  if [[ ! -d "$workdir_path" ]]; then
    return 0
  fi
  if ! _bridge_isolation_v2_run_root_or_sudo rm -rf -- "$workdir_path"; then
    bridge_warn "agent delete: failed to remove v2 workdir '$workdir_path' (best-effort — manual 'sudo rm -rf $workdir_path' may be needed)"
  fi
  return 0
}

# Returns 0 always (best-effort); skips silently on non-Linux / missing
# tooling / non-isolated agents.
bridge_isolation_v2_reap_isolated_agent_account() {
  local agent="$1"
  local os_user="$2"

  [[ -n "$agent" ]] || return 0

  # Gate 1 — Linux only. macOS / shared-mode hosts have no dedicated OS
  # user; nothing to reap. Skip silently.
  [[ "$(uname -s)" == "Linux" ]] || return 0

  # Gate 2 — exact-name match. The resolved OS user MUST exactly equal the
  # generated bridge-managed account name for this agent. This is the core
  # safety gate: it guarantees we never run userdel/groupdel/setfacl
  # against an account the bridge did not create or that does not belong
  # to this delete target. A loose pattern match is explicitly avoided.
  #
  # The expected name MUST be computed via bridge_agent_default_os_user —
  # the same helper `agent create` uses (bridge-agent.sh) — NOT a raw
  # "<prefix><agent>" concatenation. `agent create` accepts agent names
  # longer than the Linux 32-char account budget and that helper
  # TRUNCATES the composed name to fit. A raw prefix+agent string would
  # not equal the truncated account the bridge actually created, so the
  # gate would skip cleanup for every long-named isolated agent — leaving
  # behind exactly the orphan this function exists to reap (issue #1010).
  if [[ -z "$os_user" ]]; then
    # No OS user resolved from the roster — agent was never an isolated
    # linux-user agent (or its account is already gone). Nothing to do.
    return 0
  fi
  local expected=""
  if command -v bridge_agent_default_os_user >/dev/null 2>&1; then
    expected="$(bridge_agent_default_os_user "$agent" 2>/dev/null || printf '')"
  fi
  if [[ -z "$expected" ]]; then
    bridge_warn "agent delete: skipping OS-user cleanup for '$agent' — could not compute the expected bridge account name (refusing to act without an exact-match reference)"
    return 0
  fi
  if [[ "$os_user" != "$expected" ]]; then
    bridge_warn "agent delete: skipping OS-user cleanup for '$agent' — resolved user '$os_user' does not exactly match expected '$expected' (refusing to touch a non-bridge account)"
    return 0
  fi

  # ---------------------------------------------------------------------
  # Step 2 (run before Step 1) — strip the named-user traversal ACEs.
  #
  # Must happen while the user still exists: setfacl -x by name resolves
  # the principal, and stripping after userdel would leave numeric stale
  # entries. Reuse isolation-v2's own credential-ancestor logic
  # (_bridge_isolation_v2_cred_ancestors) so the ancestor set matches
  # exactly what the grant path operated on — do not re-derive it.
  # ---------------------------------------------------------------------
  if command -v setfacl >/dev/null 2>&1; then
    local ctrl_user ctrl_home
    ctrl_user="${SUDO_USER:-${USER:-${LOGNAME:-}}}"
    if [[ -n "$ctrl_user" ]]; then
      ctrl_home="$(getent passwd "$ctrl_user" 2>/dev/null | cut -d: -f6)"
      [[ -n "$ctrl_home" ]] || ctrl_home="${HOME:-}"
    fi
    if [[ -n "${ctrl_home:-}" ]]; then
      # Same credential-file path the grant path uses.
      local cred_file="${ctrl_home}/.claude/.credentials.json"
      local anc
      while IFS= read -r anc; do
        [[ -e "$anc" ]] || continue
        # Only act when the ACE is actually present, so a clean host
        # produces no noise. getfacl is best-effort.
        if command -v getfacl >/dev/null 2>&1; then
          getfacl -p "$anc" 2>/dev/null \
            | grep -qE "^user:${os_user}:" || continue
        fi
        if ! _bridge_isolation_v2_run_root_or_sudo \
             setfacl -x "u:${os_user}" "$anc"; then
          bridge_warn "agent delete: failed to strip traversal ACE u:${os_user} from $anc (best-effort; manual 'setfacl -x u:${os_user} $anc' may be needed)"
        fi
      done < <(_bridge_isolation_v2_cred_ancestors "$cred_file")
    else
      bridge_warn "agent delete: could not resolve controller home — skipping traversal-ACE strip for '$os_user' (manual cleanup may be needed)"
    fi
  fi

  # ---------------------------------------------------------------------
  # Step 1 — remove the dedicated OS user.
  #
  # Gate: the user must actually exist in passwd AND match the exact
  # expected name (already verified above). A userdel failure (user
  # logged in, processes running, etc.) is non-fatal but reported.
  # ---------------------------------------------------------------------
  if getent passwd "$os_user" >/dev/null 2>&1; then
    if command -v userdel >/dev/null 2>&1; then
      if ! _bridge_isolation_v2_run_root_or_sudo userdel "$os_user"; then
        bridge_warn "agent delete: userdel '$os_user' failed (best-effort — the user may be logged in or have running processes; manual 'userdel $os_user' may be needed)"
      fi
    else
      bridge_warn "agent delete: userdel not available — orphan OS user '$os_user' left behind (manual cleanup needed)"
    fi
  fi

  # ---------------------------------------------------------------------
  # Step 3 — drop the per-agent group, if one was created.
  #
  # Optional and exact-match guarded. The group name MUST be composed via
  # bridge_isolation_v2_agent_group_name — the same helper the grant path
  # uses — NOT a raw "<group-prefix><agent>" concatenation. On Linux that
  # helper hash-truncates any name that would exceed the 32-char groupadd
  # limit, so a raw concatenation would miss (and never groupdel) the real
  # hashed group for every long-named agent. Best-effort; a non-empty
  # group (still has members) makes groupdel fail and that is fine —
  # report and move on.
  # ---------------------------------------------------------------------
  local agent_grp=""
  if command -v bridge_isolation_v2_agent_group_name >/dev/null 2>&1; then
    agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
  fi
  if [[ -n "$agent_grp" ]] && getent group "$agent_grp" >/dev/null 2>&1; then
    if command -v groupdel >/dev/null 2>&1; then
      if ! _bridge_isolation_v2_run_root_or_sudo groupdel "$agent_grp"; then
        bridge_warn "agent delete: groupdel '$agent_grp' failed (best-effort — group may still have members; manual 'groupdel $agent_grp' may be needed)"
      fi
    else
      bridge_warn "agent delete: groupdel not available — per-agent group '$agent_grp' left behind (manual cleanup needed)"
    fi
  fi

  # ---------------------------------------------------------------------
  # Step 4 — drop the per-agent sudoers drop-in, if one was installed.
  #
  # bridge_migration_install_sudoers writes the entry to a single fixed
  # path: `/etc/sudoers.d/agent-bridge-<os_user>`. The reap mirrors that
  # writer's path shape exactly — anything else is a refusal. This is
  # the strict path-pattern safety gate the issue (#1121) calls for:
  # we never `rm` a sudoers file that does not match the EXACT generated
  # name, even if a misconfigured caller passed a different `os_user`.
  #
  # Constraints (mirror Steps 1-3):
  #   - Linux only (Gate 1 above already enforces).
  #   - `os_user` already passed Gate 2 (exact `agent-bridge-<name>` match
  #     via bridge_agent_default_os_user). The sudoers filename is built
  #     from that same gated value, so no separate gate is needed here —
  #     but we re-validate the FINAL absolute path shape against the
  #     literal pattern as a defence-in-depth check before the `rm`.
  #   - Best-effort: missing file is a clean no-op (no warning).
  #   - Use `rm -f` (NOT `rm -rf`) — the sudoers entry is a single
  #     regular file, never a directory. `-f` swallows "missing" so a
  #     host without the drop-in produces no noise.
  # ---------------------------------------------------------------------
  # Production code path: pass /etc/sudoers.d HARDCODED as the third
  # argument. The smoke at scripts/smoke/1121-agent-delete-os-purge.sh
  # invokes the internal `_bridge_isolation_v2_reap_sudoers_drop_in`
  # helper directly with a temporary sudoers root, so the production
  # function never sees a non-`/etc/sudoers.d` value.
  #
  # r3 (codex task #5740 BLOCKING): r1/r2 used an env-var override
  # (`BRIDGE_SUDOERS_DIR` then `BRIDGE_TEST_SUDOERS_DIR_OVERRIDE`) to
  # let the smoke redirect the rm. Codex flagged that any
  # env-controlled root is still a bypass vector — an attacker who
  # controls process env (or a script that leaks the var) could rm
  # arbitrary files matching the basename pattern. The new design has
  # NO env-controlled root: production hardcodes the literal
  # `/etc/sudoers.d` argument; tests pass a tmpdir to the same internal
  # helper directly (function-arg-controlled, not env-controlled).
  _bridge_isolation_v2_reap_sudoers_drop_in "$agent" "$os_user" "/etc/sudoers.d"

  # ---------------------------------------------------------------------
  # Step 5 — reap the OS-level home directory (#1140).
  #
  # `useradd` provisioned `/home/agent-bridge-<a>` (mode 0700, owner
  # agent-bridge-<a>) for the isolated account. Step 1 above ran
  # `userdel <os_user>` WITHOUT `-r`, leaving the tree on disk. Before
  # #1140 the tree leaked on every isolated create/delete cycle.
  #
  # Step ordering matters: this MUST run AFTER Step 1 userdel so the
  # rm target's owner UID is already unallocated — anyone re-acquiring
  # the same UID before the rm cannot see partial-deletion debris.
  #
  # Production hardcodes the literal "/home" argument (same shape as
  # /etc/sudoers.d for Step 4); the smoke at
  # scripts/smoke/1140-purge-home-os-cleanup.sh invokes the internal
  # helper directly with a temporary home root, so the production
  # function never sees a non-"/home" value (no env-controlled root —
  # mirrors the #1121 r3 BLOCKING contract that no env var redirects
  # the rm).
  # ---------------------------------------------------------------------
  # r2 (codex #5863 BLOCKING): respect BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT
  # (the same env var that bridge_agent_default_os_home / migration paths read
  # — defaults to /home but installs can override). Hardcoding /home leaked
  # the OS home dir for any non-default install.
  _bridge_isolation_v2_reap_os_home_dir "$agent" "$os_user" "${BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT:-/home}"

  # ---------------------------------------------------------------------
  # Step 6 — reap the v2 per-agent workdir tree (#1140).
  #
  # On a v2 install `agent create` scaffolds `<BRIDGE_AGENT_ROOT_V2>/<a>`
  # with `home/`, `workdir/`, `runtime/`, `logs/` children (root-owned
  # 2750). PR #1129's sudoers reap left this tree behind so #1119's
  # watchdog scan kept reporting it as an orphan_directory on every
  # cycle. This step closes the loop.
  #
  # The agent_root_v2 argument is read from the live env (production
  # caller path) rather than hardcoded because the v2 root is a
  # per-install variable, not a fixed FS path. On a legacy (v1)
  # install BRIDGE_AGENT_ROOT_V2 is empty and the helper is a clean
  # silent no-op (early `[[ -z "$agent_root_v2" ]]` return). The
  # smoke invokes the helper directly with a tmpdir.
  # ---------------------------------------------------------------------
  _bridge_isolation_v2_reap_v2_workdir "$agent" "${BRIDGE_AGENT_ROOT_V2:-}"

  return 0
}

_bridge_isolation_v2_state_marker_trace() {
  # Opt-in path/rc trace for the state-marker writer (#1342). Silent by
  # default; emits to stderr only when BRIDGE_ISOLATION_STATE_MARKER_DEBUG=1.
  # Diagnostic only — never alters control flow, never a return-channel
  # producer (stderr, matching bridge_warn). Operators/codex on cm-prod set
  # the env var to capture which Path (A0/A/B) fired and each fall-through rc
  # without re-introducing per-stop warning noise.
  [[ "${BRIDGE_ISOLATION_STATE_MARKER_DEBUG:-0}" == "1" ]] || return 0
  printf '[trace] write_agent_state_marker: %s\n' "$*" >&2
}

_bridge_isolation_v2_state_marker_can_repair_as_root() {
  # Returns 0 when the caller can perform the canonical chown/chmod repair
  # of the state-agent-dir leaf — i.e. is root, or has a passwordless sudo
  # grant. This mirrors the privilege model of
  # `_bridge_isolation_v2_run_root_or_sudo` (direct-as-root OR `sudo -n`),
  # which `ensure_matrix_path`'s apply path already uses. The state-marker
  # writer (#1342) consults this ONLY to disambiguate a failed
  # ensure_matrix_path: a privileged failure is genuine drift (hard-fail),
  # an unprivileged one is the iso-UID-no-sudoers case (best-effort skip).
  [[ "$(id -u 2>/dev/null)" == "0" ]] && return 0
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    return 0
  fi
  return 1
}

bridge_isolation_v2_write_agent_state_marker() {
  # Atomic-ish writer for daemon-side per-agent state markers
  # (idle-since, manual-stop, missing-marker-retries, etc.).
  #
  # Three write paths:
  #
  #   (A0) Effective UID already matches the agent's own os_user → atomic
  #        direct write (mktemp + chmod + mv) as that user. No sudo
  #        needed because we ARE the target UID. This is the Stop-hook-
  #        from-isolated-session case: `bridge-start.sh` launches
  #        linux-user agents under `sudo -n -u "$SUDO_WRAP_OS_USER"` so
  #        the Claude/Codex Stop hook runs as `agent-bridge-<X>` writing
  #        into `agent-bridge-<X>`'s OWN leaf. The generated sudoers
  #        rule (`lib/bridge-migration.sh` `operator ALL=(os_user)`) is
  #        controller-scoped — it does NOT grant
  #        `agent-bridge-<X> ALL=(agent-bridge-<X>)`, so Path A's sudo
  #        helper would rc=2 from the iso UID and fall through to Path B
  #        (which fails on `ensure_matrix_path` for the same reason).
  #        Path A0 fixes this by skipping sudo entirely when the
  #        effective UID is already the target (#1165 Track B r3 codex
  #        catch).
  #
  #        Cross-agent integrity stays strict: Path A0 only fires when
  #        the current user IS the writer's `$agent` os_user. An
  #        isolated agent-X process cannot use Path A0 to reach agent-Y
  #        (different os_users won't match the `id -un` check).
  #
  #   (A)  Linux-user isolation effective for `agent` + euid mismatches
  #        the agent's os_user → route the write through
  #        `bridge_isolation_write_file_as_agent_user_via_bash`, which
  #        `sudo -n -u <agent's own os_user>`s into the isolated UID's
  #        context and atomic-writes to its OWN state leaf. The
  #        per-agent sudoers entry (installed by
  #        `bridge_migration_sudoers_entry`) only whitelists that one
  #        os_user, so the caller can never reach a different agent's
  #        `state/agents/<other>/` leaf — per-agent integrity boundary
  #        preserved (issue #1165 Gap 6 r2 codex catch).
  #
  #        This path skips `ensure_matrix_path "state-agent-dir"` because
  #        the matrix repair requires chown/chmod escalation that the
  #        Stop hook's iso UID cannot perform (only bash/tmux are in
  #        sudoers). Canonical chown/chmod is the responsibility of the
  #        controller-side prepare/reapply path, not the per-write hook.
  #
  #   (B)  Non-isolated (legacy / shared-mode / tests) → original
  #        controller direct-write path with `ensure_matrix_path` gate.
  #
  # Args: agent, marker_name, content
  local agent="$1"
  local marker_name="$2"
  local content="$3"
  [[ -n "$agent" && -n "$marker_name" ]] || {
    bridge_warn "write_agent_state_marker: agent and marker_name required"
    return 1
  }

  local dir
  dir="$(bridge_agent_idle_marker_dir "$agent" 2>/dev/null)" \
    || dir="${BRIDGE_ACTIVE_AGENT_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state/agents}/$agent"
  local target="$dir/$marker_name"

  local _current_user
  _current_user="$(id -un 2>/dev/null || true)"
  _bridge_isolation_v2_state_marker_trace \
    "entry agent=$agent marker=$marker_name euid_user=${_current_user:-<unknown>} target=$target"

  # ---- Path (A0): euid already matches target → direct write, no sudo ----
  #
  # The Stop hook from an isolated Claude/Codex session runs as
  # `agent-bridge-<X>` (bridge-start.sh launches the session under
  # `sudo -n -u "$SUDO_WRAP_OS_USER"`). Generated sudoers
  # (`lib/bridge-migration.sh` `operator ALL=(os_user)`) is
  # controller-scoped, so the iso UID cannot sudo back to itself via
  # Path A's helper (rc=2 → Path B → original ensure_matrix_path bug).
  # When we are ALREADY the target user, skip sudo entirely and do an
  # atomic write (mktemp + chmod + mv) directly. Same on-disk shape as
  # the helper produces; only the privilege transition is omitted.
  #
  # Cross-agent guard: Path A0 only fires when `id -un` equals the
  # writer's `$agent` os_user. Agent-X process trying to write agent-Y's
  # marker will see id-un=agent-bridge-X, target os_user=agent-bridge-Y,
  # equality fails, fall through to Path A — which in turn fails because
  # the sudoers rule does not cross agent boundaries either.
  #
  # #1342 root cause: the equality gate consulted ONLY the roster-resolved
  # `bridge_agent_os_user "$agent"`. When the Stop hook runs inside the iso
  # UID (`agent-bridge-<X>`) but its scoped roster snapshot did not populate
  # `BRIDGE_AGENT_OS_USER[<X>]` — or `bridge_agent_isolation_mode` came back
  # indeterminate (#1048) — `_target_os_user` is empty, A0 is skipped, AND
  # Path A's `bridge_agent_linux_user_isolation_effective` also returns 1
  # (it requires a non-empty os_user, see bridge-agents.sh:1028). Both
  # isolation paths fall through to Path B, whose `ensure_matrix_path` then
  # tries a chown/chmod the iso UID cannot perform → the per-stop
  # "ensure_matrix_path failed … marker=idle-since" warning.
  #
  # Fix: derive the EXPECTED iso UID purely from the canonical construction
  # `${BRIDGE_AGENT_OS_USER_PREFIX:-agent-bridge-}${agent}` (the same string
  # `matrix_rows_for_agent` uses for `iso_user`) when the roster lookup is
  # empty. The euid==target equality is then driven by the runtime context
  # (`id -un`), not by a roster snapshot that may not have loaded. The
  # cross-agent guard is unchanged in strength: A0 still fires only when the
  # current user IS this agent's own iso UID — an agent-X process writing
  # agent-Y's marker still sees `id-un=agent-bridge-X` ≠ derived
  # `agent-bridge-Y` and falls through.
  local _target_os_user=""
  if command -v bridge_agent_os_user >/dev/null 2>&1; then
    _target_os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
  fi
  local _target_os_user_src="roster"
  if [[ -z "$_target_os_user" ]]; then
    _target_os_user="${BRIDGE_AGENT_OS_USER_PREFIX:-agent-bridge-}${agent}"
    _target_os_user_src="derived"
  fi
  _bridge_isolation_v2_state_marker_trace \
    "PathA0 check target_os_user=$_target_os_user (src=$_target_os_user_src) current_user=${_current_user:-<unknown>}"
  if [[ -n "$_current_user" && "$_current_user" == "$_target_os_user" ]]; then
    _bridge_isolation_v2_state_marker_trace "PathA0 selected (euid==target, no sudo)"
    # Ensure the parent dir exists (best-effort — we already own it
    # when euid==target_os_user under iso v2). Do NOT call
    # ensure_matrix_path: same rationale as Path A — chown/chmod
    # escalation is the controller's job, not the per-write hook.
    mkdir -p "$dir" 2>/dev/null || {
      bridge_warn "write_agent_state_marker: Path A0 cannot create $dir"
      return 1
    }
    local _tmp
    _tmp="$(mktemp "$target.XXXXXX" 2>/dev/null)" || {
      bridge_warn "write_agent_state_marker: Path A0 mktemp failed under $dir"
      return 1
    }
    printf '%s\n' "$content" >"$_tmp" || {
      rm -f "$_tmp" 2>/dev/null || true
      bridge_warn "write_agent_state_marker: Path A0 write failed: $_tmp"
      return 1
    }
    # r4 codex BLOCKING — soft-fail chmod was a state-drift trap.
    # mktemp leaves 0600 owner-only by default; if the chmod 0660
    # silently failed, the controller/daemon (member of the
    # ab-agent-<X> group, not the iso UID) could no longer read
    # the published marker. Match the sudo-as-iso helper (exit 8)
    # and Path B (`return 1` after bridge_warn) contracts: cleanup
    # the temp file, warn, hard-fail. Same parity rationale as the
    # adjacent `|| true → return 1` comments on r11/r14.
    chmod 0660 "$_tmp" 2>/dev/null || {
      rm -f "$_tmp" 2>/dev/null || true
      bridge_warn "write_agent_state_marker: Path A0 chmod 0660 failed: $_tmp"
      return 1
    }
    mv -f "$_tmp" "$target" || {
      rm -f "$_tmp" 2>/dev/null || true
      bridge_warn "write_agent_state_marker: Path A0 rename failed: $_tmp → $target"
      return 1
    }
    _bridge_isolation_v2_state_marker_trace "PathA0 success target=$target"
    return 0
  fi

  # ---- Path (A): sudo-escalate as the agent's own iso UID ----
  #
  # Only attempt when both helpers are loaded AND the agent is
  # linux-user isolated. The helper itself re-verifies isolation
  # effective + sudo availability and returns:
  #   0  → wrote OK
  #   1  → agent NOT in linux-user iso (fall through to Path B)
  #   2  → iso but sudo unavailable (fall through to Path B; controller
  #         path will then either succeed (controller-driven write) or
  #         report a clean failure)
  #   3+ → iso + sudo OK but inline script failed (dest dir missing,
  #         mktemp failed, etc.); surface a hard fail because the iso
  #         UID's environment is the canonical writer for its own leaf.
  if command -v bridge_isolation_write_file_as_agent_user_via_bash >/dev/null 2>&1 \
      && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    _bridge_isolation_v2_state_marker_trace "PathA selected (sudo-as-iso writer)"
    local _sudo_rc=0
    printf '%s\n' "$content" \
      | bridge_isolation_write_file_as_agent_user_via_bash "$agent" "$target" "0660" \
      || _sudo_rc=$?
    _bridge_isolation_v2_state_marker_trace "PathA sudo-as-iso rc=$_sudo_rc"
    case "$_sudo_rc" in
      0)
        return 0
        ;;
      1|2)
        # Fall through to Path B (controller direct write). Path B will
        # either succeed (controller has write to the leaf via direct
        # ownership) or fail cleanly with bridge_warn.
        :
        ;;
      *)
        bridge_warn "write_agent_state_marker: sudo-as-iso writer failed (rc=$_sudo_rc) for agent=$agent marker=$marker_name target=$target"
        return 1
        ;;
    esac
  fi

  # ---- Path (B): controller direct write (legacy / non-iso) ----
  _bridge_isolation_v2_state_marker_trace "PathB selected (controller direct write)"
  #
  # r11 codex BUG #4 — was `|| true`. Same anti-pattern as the other
  # apply/check paths: ensure_matrix_path failure was swallowed, so the
  # subsequent mkdir/write proceeded against a state-dir that may have
  # wrong group/mode (RC1 cascade), then the marker file inherited
  # wrong group, then verify rejected. Hard fail propagates to the
  # daemon writer's caller. Suppress only the per-call stderr because
  # bridge_warn from inside ensure_matrix_path already logged.
  #
  # #1342: ensure_matrix_path can fail for two distinct reasons —
  #   (a) the caller has root/sudo and the chown/chmod genuinely failed
  #       (a real matrix-apply error worth surfacing), OR
  #   (b) the caller is an iso UID with NO sudoers grant to chown the
  #       `controller:ab-agent-<X>:2770` leaf. In case (b) the iso UID is
  #       still a MEMBER of `ab-agent-<X>` (its primary group), so it can
  #       legitimately write the 0660 marker file into the existing 2770
  #       leaf — it just cannot repair ownership/mode. The pre-#1342
  #       behavior hard-failed on (b) too, producing the per-stop
  #       "ensure_matrix_path failed … marker=idle-since" warning even
  #       though the marker write would have succeeded.
  #
  # Fix: ensure_matrix_path's `apply` already escalates its chown/chmod via
  # `_bridge_isolation_v2_run_root_or_sudo`, so a failure means one of:
  #   (a) we HAVE root/sudo and the canonical repair genuinely failed — a
  #       real matrix-apply error; preserve the pre-#1342 hard-fail so the
  #       controller-context drift still surfaces loudly, OR
  #   (b) we have NO privileged path (iso UID, no sudoers chown grant) — the
  #       only thing missing is the ability to chown a leaf the controller
  #       already owns; the iso UID can still write the 0660 marker into the
  #       existing 2770 group-writable leaf. In (b) drop the spurious
  #       per-stop warning and continue best-effort to the direct write,
  #       which remains the authoritative hard-fail if the leaf is truly
  #       not writable.
  # We never widen the leaf group or cross agent boundaries here — only
  # repair-or-skip the existing per-agent leaf.
  if ! bridge_isolation_v2_ensure_matrix_path "state-agent-dir" "$agent" 2>/dev/null; then
    if _bridge_isolation_v2_state_marker_can_repair_as_root; then
      # Case (a): privileged repair was available to ensure_matrix_path's
      # apply path yet still failed → genuine drift. Hard-fail as before.
      bridge_warn "write_agent_state_marker: ensure_matrix_path failed for agent=$agent marker=$marker_name"
      return 1
    fi
    # Case (b): no root/sudo — best-effort continue. Trace only.
    _bridge_isolation_v2_state_marker_trace \
      "PathB ensure_matrix_path unrepairable (no root/sudo) — best-effort direct write for agent=$agent marker=$marker_name"
  fi
  mkdir -p "$dir" 2>/dev/null \
    || _bridge_isolation_v2_run_root_or_sudo mkdir -p "$dir" \
    || {
      bridge_warn "write_agent_state_marker: cannot create $dir"
      return 1
    }
  local tmp="${target}.tmp.$$"
  printf '%s\n' "$content" > "$tmp" 2>/dev/null || {
    # Direct write failed — fall back to sudo for controller-write paths.
    if ! _bridge_isolation_v2_run_root_or_sudo bash -c "printf '%s\n' \"\$1\" > \"\$2\"" _ "$content" "$tmp" 2>/dev/null; then
      bridge_warn "write_agent_state_marker: cannot write $tmp"
      return 1
    fi
  }
  mv -f "$tmp" "$target" 2>/dev/null \
    || _bridge_isolation_v2_run_root_or_sudo mv -f "$tmp" "$target" \
    || {
      bridge_warn "write_agent_state_marker: cannot rename into $target"
      rm -f "$tmp" 2>/dev/null \
        || _bridge_isolation_v2_run_root_or_sudo rm -f "$tmp" 2>/dev/null || true
      return 1
    }
  # r14 codex Probe 4 — was `|| true`. chmod 0660 failure means the
  # marker file's mode doesn't match the matrix contract; verify will
  # reject. Hard fail propagates so callers see the asymmetry.
  chmod 0660 "$target" 2>/dev/null \
    || _bridge_isolation_v2_run_root_or_sudo chmod 0660 "$target" 2>/dev/null \
    || {
      bridge_warn "write_agent_state_marker: cannot chmod 0660 $target"
      return 1
    }
  return 0
}

# ---------------------------------------------------------------------------
# 6b. sanitized per-agent metadata snippet (Lane A beta4)
# ---------------------------------------------------------------------------
#
# `state/agents/<agent>/agent-meta.env` is a small secret-free key=value
# file the iso UID context can read to populate just the iso-relevant
# fields (`os_user`, `isolation_mode`, `engine`, etc.) without needing to
# read the controller-protected `agent-roster.local.sh` (0600 owner=
# controller). It is a SEPARATE file from the full scoped
# `runtime/agent-env.sh` (sourced by `bridge_load_roster` at agent
# launch time) — that file lives under `data/agents/<a>/runtime/` which
# is gated by `ab-agent-<a>` membership + setgid, and reaching it from a
# raw hook subprocess that has not had `BRIDGE_AGENT_ROOT_V2` exported
# is brittle (the env can drop between agent stop and the next hook
# call). `agent-meta.env` lives at a stable controller-rooted path
# (`$BRIDGE_HOME/state/agents/<a>/`) that the iso UID can always
# resolve via the early defaults in bridge-lib.sh.
#
# Contents (key=value lines, NO secrets, NO command bodies):
#   BRIDGE_AGENT_OS_USER=agent-bridge-<a>
#   BRIDGE_AGENT_ISOLATION_MODE=linux-user
#   BRIDGE_AGENT_ENGINE=claude
#   BRIDGE_AGENT_HOME=/home/agent-bridge-<a>
#   BRIDGE_AGENT_CLAUDE_CONFIG_DIR=/home/agent-bridge-<a>/.claude
#   BRIDGE_AGENT_AUDIT_DIR=<controller-rooted logs dir for this agent>
#
# Scope (codex r1 NEEDS-CLARIFY, PR #1286 r2): this snippet carries
# STATIC agent properties ONLY — where the agent lives (home /
# config_dir), under which OS user, with which engine, under which
# isolation mode, and where its audit dir is. It does NOT carry
# dynamic / lifecycle state. In particular, the Lane E (#1265 + #1269)
# fresh-state detection contract is OUT OF SCOPE for this writer —
# Lane E owns a separate marker (e.g. `state/agents/<a>/launch.history`
# touched on first wake) so write responsibilities stay disjoint.
# Future readers needing fresh-state must not extend this snippet with
# launch-history fields; they must use the Lane E marker contract.
#
# Permissions: 0640, owner=controller, group=ab-agent-<a>. Iso UID
# (group member) + controller (owner) both read; world has no access.
#
# The reader lives in `bridge-lib.sh` (post-module-source) and parses
# the file via `read -r` line-by-line (no `source`) so the assoc-array
# vs scalar collision documented in #1213 cannot fire.
#
# This writer is iso-v2 only. Non-iso agents skip — their controller
# already has direct roster access and the iso UID context does not
# exist.
bridge_isolation_v2_write_agent_metadata() {
  local agent="$1"
  [[ -n "$agent" ]] || {
    bridge_warn "write_agent_metadata: agent required"
    return 1
  }

  # Linux-only: the writer is a no-op on macOS dev hosts (consistent
  # with the rest of the iso-v2 sudo handoff path).
  [[ "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]] || return 0

  # Only write for iso-v2 agents. Non-iso agents in a v2-active install
  # legitimately use the regular roster.
  command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 || return 0
  bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null || return 0

  local os_user=""
  local isolation_mode=""
  local engine=""
  local user_home=""
  local claude_config_dir=""
  local audit_dir=""
  local agent_grp=""
  local controller_user=""
  local meta_dir=""
  local meta_file=""

  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
  isolation_mode="$(bridge_agent_isolation_mode "$agent" 2>/dev/null || true)"
  engine="$(bridge_agent_engine "$agent" 2>/dev/null || true)"
  [[ -n "$os_user" ]] || {
    bridge_warn "write_agent_metadata: bridge_agent_os_user('$agent') returned empty; cannot write metadata snippet"
    return 1
  }

  user_home="$(bridge_agent_linux_user_home "$os_user")"
  claude_config_dir="$user_home/.claude"
  audit_dir="$(bridge_agent_log_dir "$agent" 2>/dev/null || true)"
  agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
  controller_user="$(bridge_current_user 2>/dev/null || true)"
  meta_dir="$BRIDGE_ACTIVE_AGENT_DIR/$agent"
  meta_file="$meta_dir/agent-meta.env"

  # Ensure the controller-owned parent dir exists. The matrix apply path
  # (state-agent-dir row) does this too, but call it idempotently here
  # so the metadata writer is callable from `bridge-init.sh` /
  # standalone repair contexts that do not transit the full matrix.
  if [[ ! -d "$meta_dir" ]]; then
    mkdir -p "$meta_dir" 2>/dev/null \
      || _bridge_isolation_v2_run_root_or_sudo mkdir -p "$meta_dir" \
      || {
        bridge_warn "write_agent_metadata: cannot create $meta_dir"
        return 1
      }
  fi

  # Build atomically in a controller-owned temp under the same dir so
  # the rename is on the same filesystem. The temp file inherits
  # controller umask 077; we relax mode + chgrp after content is
  # written.
  local tmp_meta=""
  tmp_meta="$(mktemp "$meta_dir/.agent-meta.env.XXXXXX" 2>/dev/null)" || {
    # The parent dir may be group-writable but not controller-writable
    # in odd repair states. Fall back to TMPDIR + sudo-mv.
    tmp_meta="$(mktemp "${TMPDIR:-/tmp}/agent-meta.env.XXXXXX")" || {
      bridge_warn "write_agent_metadata: mktemp failed for $agent"
      return 1
    }
  }

  {
    printf '# Sanitized iso-UID-readable metadata snippet for agent=%s\n' "$agent"
    printf '# Managed by agent-bridge. Regenerated on each prepare/reapply.\n'
    printf '# Format: key=value, one per line. NOT sourced — parsed by bridge-lib.sh.\n'
    printf '# Permissions: 0640 controller:%s — iso UID + controller both read.\n' "${agent_grp:-ab-agent-$agent}"
    printf 'BRIDGE_AGENT_OS_USER=%s\n' "$os_user"
    printf 'BRIDGE_AGENT_ISOLATION_MODE=%s\n' "${isolation_mode:-linux-user}"
    printf 'BRIDGE_AGENT_ENGINE=%s\n' "${engine:-claude}"
    printf 'BRIDGE_AGENT_HOME=%s\n' "$user_home"
    printf 'BRIDGE_AGENT_CLAUDE_CONFIG_DIR=%s\n' "$claude_config_dir"
    printf 'BRIDGE_AGENT_AUDIT_DIR=%s\n' "${audit_dir:-}"
  } >"$tmp_meta" || {
    rm -f "$tmp_meta" 2>/dev/null || true
    bridge_warn "write_agent_metadata: cannot write content to $tmp_meta"
    return 1
  }

  # Mode 0640 — controller (owner) rw, agent group r, world none.
  chmod 0640 "$tmp_meta" 2>/dev/null || {
    rm -f "$tmp_meta" 2>/dev/null || true
    bridge_warn "write_agent_metadata: chmod 0640 failed for $tmp_meta"
    return 1
  }

  # Group ownership. The controller is already a member of
  # `ab-agent-<a>` (joined at prepare time), but the file is created
  # under the controller's primary group — switch it. Best-effort
  # (non-fatal): a chgrp failure here only narrows the read audience
  # to the file owner; the iso UID would lose access, which is what
  # the lane is fixing — so escalate to sudo if the direct chgrp
  # fails.
  if [[ -n "$agent_grp" ]]; then
    if ! chgrp "$agent_grp" "$tmp_meta" 2>/dev/null; then
      if ! _bridge_isolation_v2_run_root_or_sudo chgrp "$agent_grp" "$tmp_meta" 2>/dev/null; then
        rm -f "$tmp_meta" 2>/dev/null || true
        bridge_warn "write_agent_metadata: chgrp $agent_grp failed for $tmp_meta"
        return 1
      fi
    fi
  fi

  # Atomic rename. If the parent dir is not controller-writable (some
  # repair states), fall back to sudo mv.
  if ! mv -f "$tmp_meta" "$meta_file" 2>/dev/null; then
    if ! _bridge_isolation_v2_run_root_or_sudo mv -f "$tmp_meta" "$meta_file" 2>/dev/null; then
      rm -f "$tmp_meta" 2>/dev/null \
        || _bridge_isolation_v2_run_root_or_sudo rm -f "$tmp_meta" 2>/dev/null || true
      bridge_warn "write_agent_metadata: rename failed: $tmp_meta -> $meta_file"
      return 1
    fi
  fi

  return 0
}

bridge_isolation_v2_verify_agent_metadata() {
  # #1891 (F3a) — Confirm `state/agents/<a>/agent-meta.env` is present AND
  # carries the canonical `0640 controller:ab-agent-<a>` contract AND the
  # iso UID can actually consume it. This is the visible/nonzero check the
  # create-path uses so an absent/under-permissioned snippet becomes a hard
  # failure instead of a silent warn (the symptom: later-created agents
  # finished provisioning with the snippet missing, and the daemon then
  # mis-detected the engine). Secret-free: the snippet itself carries no
  # secrets, and this verifier neither logs nor reads file contents.
  #
  # Returns 0 only when every assertion holds. On any failure it
  # bridge_warns the specific reason and returns 1.
  local agent="$1"
  [[ -n "$agent" ]] || { bridge_warn "verify_agent_metadata: agent required"; return 1; }

  # Linux-only + iso-v2-only, mirroring the writer's own gates: on a
  # macOS/dev host or for a non-iso agent the writer is a no-op success, so
  # the verifier must also pass (there is nothing to verify).
  [[ "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]] || return 0
  command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 || return 0
  bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null || return 0

  local meta_file="${BRIDGE_ACTIVE_AGENT_DIR:-$BRIDGE_HOME/state/agents}/$agent/agent-meta.env"  # noqa: iso-helper-boundary — controller-owned 0640 snippet path; controller-side stat/verify, not an iso boundary RW (the iso-read probe below uses bridge_isolation_run_as_agent_user_via_bash)
  if [[ ! -f "$meta_file" ]]; then
    bridge_warn "verify_agent_metadata: $meta_file absent after apply for agent '$agent' (iso UID cannot resolve its own engine/config_dir; the daemon may mis-detect the engine)."
    return 1
  fi

  # Mode 0640 (controller rw, agent group r, world none).
  local stat_fmt
  if [[ "$(uname)" == "Darwin" ]]; then stat_fmt=(-f %A); else stat_fmt=(-c %a); fi
  local mode
  mode="$(stat "${stat_fmt[@]}" "$meta_file" 2>/dev/null || true)"
  mode="$(printf '%04o' "$((8#${mode:-0}))" 2>/dev/null || printf '%s' "$mode")"
  if [[ "$mode" != "0640" ]]; then
    bridge_warn "verify_agent_metadata: $meta_file mode=$mode, expected 0640 for agent '$agent'."
    return 1
  fi

  # Owner = controller. The snippet is controller-owned (the writer creates it
  # under the controller umask, then only chgrps the GROUP to ab-agent-<a>).
  # An iso-UID owner here would mean the file was rewritten cross-boundary —
  # the iso UID must never own the metadata contract (it could then forge its
  # own engine/config_dir). Skip silently if the controller user is unresolved.
  local want_owner cur_owner own_fmt
  want_owner="$(bridge_current_user 2>/dev/null || id -un 2>/dev/null || true)"
  if [[ -n "$want_owner" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then own_fmt=(-f %Su); else own_fmt=(-c %U); fi
    cur_owner="$(stat "${own_fmt[@]}" "$meta_file" 2>/dev/null || true)"
    if [[ -n "$cur_owner" && "$cur_owner" != "$want_owner" ]]; then
      bridge_warn "verify_agent_metadata: $meta_file owner=$cur_owner, expected controller '$want_owner' for agent '$agent'."
      return 1
    fi
  fi

  # Group ab-agent-<a>.
  local agent_grp want_grp
  want_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
  if [[ -n "$want_grp" ]]; then
    local grp_fmt
    if [[ "$(uname)" == "Darwin" ]]; then grp_fmt=(-f %Sg); else grp_fmt=(-c %G); fi
    agent_grp="$(stat "${grp_fmt[@]}" "$meta_file" 2>/dev/null || true)"
    if [[ -n "$agent_grp" && "$agent_grp" != "$want_grp" ]]; then
      bridge_warn "verify_agent_metadata: $meta_file group=$agent_grp, expected $want_grp for agent '$agent'."
      return 1
    fi
  fi

  # Iso-UID consumption: confirm the agent's own OS user can read the file.
  # `bridge_isolation_run_as_agent_user_via_bash` drops to the iso UID; a
  # `test -r` there proves the group-read path the iso process depends on.
  if command -v bridge_isolation_run_as_agent_user_via_bash >/dev/null 2>&1; then
    if ! bridge_isolation_run_as_agent_user_via_bash "$agent" \
          "test -r '$meta_file'" >/dev/null 2>&1; then
      bridge_warn "verify_agent_metadata: iso UID for agent '$agent' cannot read $meta_file (group-read path broken)."
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 7. exports
# ---------------------------------------------------------------------------

# Always export the layout flag so children inherit the explicit choice.
export BRIDGE_LAYOUT

# Only export the v2-specific vars when v2 is active. Legacy installs
# do not see these vars in the child env, preserving the unset semantics
# any pre-v2 reader may depend on (e.g. callers distinguishing
# ${VAR+set} vs ${VAR-empty}).
if bridge_isolation_v2_active; then
  export BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 \
         BRIDGE_CONTROLLER_STATE_ROOT \
         BRIDGE_SHARED_GROUP BRIDGE_CONTROLLER_GROUP \
         BRIDGE_AGENT_GROUP_PREFIX
fi
