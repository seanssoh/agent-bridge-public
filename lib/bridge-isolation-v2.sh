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

# Group names. Operator may override via env to fit local naming policy.
BRIDGE_SHARED_GROUP="${BRIDGE_SHARED_GROUP:-ab-shared}"
BRIDGE_CONTROLLER_GROUP="${BRIDGE_CONTROLLER_GROUP:-ab-controller}"
BRIDGE_AGENT_GROUP_PREFIX="${BRIDGE_AGENT_GROUP_PREFIX:-ab-agent-}"

# ---------------------------------------------------------------------------
# 2. helpers — environment / dispatch
# ---------------------------------------------------------------------------

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
  [[ -n "$agent" && -n "$BRIDGE_AGENT_ROOT_V2" ]] || return 1
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
  # execution (bridge_isolation_v2_load_secret_env). Keeping secrets in
  # this file (not in BRIDGE_AGENT_LAUNCH_CMD) prevents leaks via
  # process listings, dry-run output, log lines, and crash reports.
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
  #
  # Side effects:
  #   - Sets BRIDGE_ISOLATION_V2_LAST_EXEC_RC to the child's exit code.
  #   - On loader failure, calls bridge_die (does not return).
  local _secret_file="$1"
  local _bash_bin="$2"
  local _launch_cmd="$3"
  local _errfile="$4"
  local _agent="$5"
  # PR-C r2 review P2 #1: cannot use the subshell exit code as the
  # loader-failure sentinel — the same subshell `exec`s the agent
  # command, so any legitimate child exit code (e.g. exit 75 from a
  # claude / codex process) would be misclassified as a secret-load
  # failure and call bridge_die. Use an out-of-band marker file that
  # only the loader-failure branch creates; the parent then checks the
  # marker independently of the exit code.
  local _fail_marker
  _fail_marker="$(mktemp -t agb-secret-fail.XXXXXX 2>/dev/null || printf '%s' "/tmp/agb-secret-fail.$$.$RANDOM")"
  rm -f "$_fail_marker"
  local _rc=0
  if (
    bridge_isolation_v2_load_secret_env "$_secret_file" || {
      : > "$_fail_marker" 2>/dev/null || true
      exit 1
    }
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
  # inherits the same isolation contract; the daily harvester aggregates
  # into the shared aggregate dir (controller-owned, group-readable).
  local agent="$1"
  local root
  root="$(bridge_isolation_v2_agent_root "$agent")" || return 1
  printf '%s/runtime/memory-daily' "$root"
}

bridge_isolation_v2_memory_daily_shared_aggregate_dir() {
  # Canonical shared aggregate directory — the harvester writes
  # admin-aggregate-*.json files DIRECTLY under this path (not inside an
  # extra `aggregate/` child). Lives under shared/ so other isolated UIDs
  # may read the aggregate but never write it (design-r3 decision: shared
  # writes are controller-only). PR-C r3: contract unified across all
  # callers so prepare/migration grants the same path the Python writer
  # uses, eliminating the parent-vs-child mismatch flagged in r2 review
  # finding P2 #2.
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
  _bridge_isolation_v2_run_root_or_sudo chgrp "$group" "$dir" || return 1
  _bridge_isolation_v2_run_root_or_sudo chmod "$mode" "$dir" || return 1
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
  [[ -n "$group" && -n "$dir_mode" && -n "$file_mode" && -n "$root" ]] || {
    bridge_warn "chgrp_setgid_recursive: group, dir_mode, file_mode, root required"
    return 1
  }
  [[ -d "$root" ]] || {
    bridge_warn "chgrp_setgid_recursive: not a directory: $root"
    return 1
  }
  # `chgrp -R` follows symlinks on BSD/macOS by default while GNU
  # coreutils does not, so a symlink-to-directory inside $root could
  # lead the chown out of the tree on macOS. Restrict the recursion
  # to files+dirs explicitly via find so symlinks (-type l) are never
  # chgrp'd or chmod'd; the four-pass approach is consistent with the
  # chmod passes below.
  _bridge_isolation_v2_run_root_or_sudo find "$root" -type d -exec chgrp "$group" {} + || return 1
  _bridge_isolation_v2_run_root_or_sudo find "$root" -type f -exec chgrp "$group" {} + || return 1
  _bridge_isolation_v2_run_root_or_sudo find "$root" -type d -exec chmod "$dir_mode" {} + || return 1
  _bridge_isolation_v2_run_root_or_sudo find "$root" -type f -exec chmod "$file_mode" {} + || return 1

  # Self-verify: catches the symptom from issue #746 where the
  # direct-first path returns 0 with no actual mutations (e.g. find
  # exit-status not propagating through `-exec ... +` on some findutils
  # builds, or the sudo path silently degraded). Without this, the
  # migrator advances the v2 marker on a half-repaired tree and the
  # controller-group read sweep keeps failing every Saturday.
  if ! bridge_isolation_v2_verify_chgrp_setgid_recursive \
        "$group" "$dir_mode" "$file_mode" "$root"; then
    # Drift detected. Retry with sudo-only (skip direct-first), in case
    # the direct-first attempt succeeded-on-find-but-failed-on-chgrp.
    # If still drifted after the sudo retry, surface clearly so the
    # migrator caller can abort instead of writing the v2 marker on a
    # half-repaired tree.
    if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      sudo -n find "$root" -type d -exec chgrp "$group" {} + 2>/dev/null || true
      sudo -n find "$root" -type f -exec chgrp "$group" {} + 2>/dev/null || true
      sudo -n find "$root" -type d -exec chmod "$dir_mode" {} + 2>/dev/null || true
      sudo -n find "$root" -type f -exec chmod "$file_mode" {} + 2>/dev/null || true
    fi
    if ! bridge_isolation_v2_verify_chgrp_setgid_recursive \
          "$group" "$dir_mode" "$file_mode" "$root"; then
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
  [[ -n "$group" && -n "$dir_mode" && -n "$file_mode" && -n "$root" ]] || {
    bridge_warn "verify_chgrp_setgid_recursive: group, dir_mode, file_mode, root required"
    return 1
  }
  [[ -d "$root" ]] || return 0  # nothing to verify

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
  mismatch_path="$(find "$root" -type d \! -group "$group" -print 2>/dev/null | head -n1)"
  if [[ -n "$mismatch_path" ]]; then
    bridge_warn "verify_chgrp_setgid_recursive: dir group mismatch under $root (first: $mismatch_path expected=$group)"
    return 1
  fi
  mismatch_path="$(find "$root" -type f \! -group "$group" -print 2>/dev/null | head -n1)"
  if [[ -n "$mismatch_path" ]]; then
    bridge_warn "verify_chgrp_setgid_recursive: file group mismatch under $root (first: $mismatch_path expected=$group)"
    return 1
  fi
  # Sample mode check (one entry per type) — a full mode walk is
  # expensive on large trees; the sample is enough to catch the silent-
  # no-op failure mode where every entry kept its pre-migration mode.
  local sample_dir sample_file actual_mode normalized_actual
  sample_dir="$(find "$root" -type d -print 2>/dev/null | head -n1)"
  sample_file="$(find "$root" -type f -print 2>/dev/null | head -n1)"
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
      if [[ "$normalized_actual" != "$exp_file_mode" ]]; then
        bridge_warn "verify_chgrp_setgid_recursive: file mode mismatch at $sample_file (expected=$exp_file_mode actual=$normalized_actual)"
        return 1
      fi
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 4b. ACL scrub — strip pre-v2 ACL entries before the chmod pass
# ---------------------------------------------------------------------------

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
  [[ -d "$root" ]] || return 0
  local _scrub_err _rc
  _scrub_err="$(mktemp 2>/dev/null || printf '/dev/null')"
  if [[ "$(uname)" == "Darwin" ]]; then
    _bridge_isolation_v2_run_root_or_sudo \
      chmod -R -P -N "$root" 2>"$_scrub_err"
    _rc=$?
    if (( _rc != 0 )); then
      bridge_warn "acl_scrub: chmod -R -P -N failed at $root (rc=${_rc}); see ${_scrub_err}"
      return 1
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
