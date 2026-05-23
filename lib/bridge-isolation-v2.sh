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
  _fail_marker="$(mktemp "${TMPDIR:-/tmp}/agb-secret-fail.XXXXXX" 2>/dev/null || printf '%s' "/tmp/agb-secret-fail.$$.$RANDOM")"
  rm -f "$_fail_marker"
  local _rc=0
  if (
    bridge_isolation_v2_load_secret_env "$_secret_file" || {
      : 2>/dev/null > "$_fail_marker" || true
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
  local -a _excl_names=()
  local -a _excl_paths=()
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
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude-subdir) _excl_names+=("$2"); shift 2 ;;
      --exclude-path) [[ -n "${2:-}" ]] && _excl_paths+=("$2"); shift 2 ;;
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
    printf 'state-root|%s|dir_only_traverse|controller|%s|0710||0|group_setgid|required|isolated UID needs --x to reach state/agents/<X>\n' \
      "$state_root" "$shared_grp"
    printf 'state-agents-root|%s|dir_only_traverse|controller|%s|0710||0|group_setgid|required|isolated UID needs --x to reach its own leaf\n' \
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
    if [[ "$_v2_isolation_mode" == "shared" ]]; then
      # #909: state-agent-dir under shared mode is operator-owned; the
      # `ab-agent-<X>` group does not exist. write_agent_state_marker
      # calls ensure_matrix_path "state-agent-dir" before every idle-since
      # write, so this row is the hottest fail surface on a shared-only
      # install.
      printf 'state-agent-dir|%s|dir|controller|controller_group|2770|0660|1|group_setgid|required|#909 shared-mode per-agent state leaf\n' \
        "$state_agent_dir"
    else
      printf 'state-agent-dir|%s|dir|controller|%s|2770|0660|1|group_setgid|required|RC1: per-agent state leaf, isolated UID + controller rwx\n' \
        "$state_agent_dir" "$agent_grp"
    fi
    # RC2: file-level rows are not enforced for files that may be absent
    # at apply time (idle-since, manual-stop, missing-marker-retries,
    # webhook-port, next-session.sha). The matrix grants the parent +
    # setgid so the writers inherit ab-agent-<X> automatically; the
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
    printf 'isolated-user-home|%s|dir|%s|%s|0700||0|install_managed|required|isolated UIDs private home\n' \
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
      # of ab-agent-<X>) false-passes the check despite mode being correct.
      # apply path (chown above) doesn't accept token names ("controller"
      # etc.) — caller must already resolve tokens to actual user/group
      # names — so check uses the same resolved comparison.
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
  # Path composition mirrors bridge_migration_install_sudoers
  # (lib/bridge-migration.sh): the writer emits to
  # `${sudoers_dir}/agent-bridge-${os_user}`. Use the same root so the
  # reaper targets the exact file the migrator created.
  # BRIDGE_SUDOERS_DIR is a test-only override (defaults to /etc/sudoers.d)
  # — production never sets it; the smoke at scripts/smoke/1121-agent-delete-os-purge.sh
  # points it at a tempdir so the decision logic can be exercised without
  # mutating the host's real sudoers tree.
  local sudoers_dir="${BRIDGE_SUDOERS_DIR:-/etc/sudoers.d}"
  local sudoers_path="${sudoers_dir}/agent-bridge-${os_user}"
  # Defence-in-depth: enforce both the directory location AND the literal
  # filename shape before any destructive call. The basename MUST match
  # the exact bridge-managed `agent-bridge-<slug>` form; the directory
  # MUST be the production `/etc/sudoers.d` unless an explicit
  # BRIDGE_SUDOERS_DIR override was supplied (test path). Anything else
  # is a refusal — never rm an arbitrary sudoers file. The regex pins:
  #   - prefix:     agent-bridge-
  #   - slug:       [a-zA-Z0-9_-]+
  #   - end-anchor: $
  # so neither leading `..`/symlinked-out paths nor a glob like
  # `agent-bridge-foo*` could ever slip through.
  local sudoers_base="${sudoers_path##*/}"
  local sudoers_parent="${sudoers_path%/*}"
  if [[ -z "${BRIDGE_SUDOERS_DIR:-}" && "$sudoers_parent" != "/etc/sudoers.d" ]]; then
    bridge_warn "agent delete: skipping sudoers cleanup for '$agent' — composed parent '$sudoers_parent' is not /etc/sudoers.d (refusing to rm)"
  elif [[ ! "$sudoers_base" =~ ^agent-bridge-[a-zA-Z0-9_-]+$ ]]; then
    bridge_warn "agent delete: skipping sudoers cleanup for '$agent' — composed path '$sudoers_path' does not match strict pattern (refusing to rm)"
  elif [[ -e "$sudoers_path" ]]; then
    if ! _bridge_isolation_v2_run_root_or_sudo rm -f -- "$sudoers_path"; then
      bridge_warn "agent delete: failed to remove sudoers drop-in '$sudoers_path' (best-effort — manual 'sudo rm -f $sudoers_path' may be needed)"
    fi
  fi

  return 0
}

bridge_isolation_v2_write_agent_state_marker() {
  # Atomic-ish writer for daemon-side per-agent state markers
  # (idle-since, manual-stop, missing-marker-retries, etc.). Ensures the
  # state-agent-dir matrix row is canonical, then writes mode 0660.
  # Args: agent, marker_name, content
  local agent="$1"
  local marker_name="$2"
  local content="$3"
  [[ -n "$agent" && -n "$marker_name" ]] || {
    bridge_warn "write_agent_state_marker: agent and marker_name required"
    return 1
  }
  # r11 codex BUG #4 — was `|| true`. Same anti-pattern as the other
  # apply/check paths: ensure_matrix_path failure was swallowed, so the
  # subsequent mkdir/write proceeded against a state-dir that may have
  # wrong group/mode (RC1 cascade), then the marker file inherited
  # wrong group, then verify rejected. Hard fail propagates to the
  # daemon writer's caller. Suppress only the per-call stderr because
  # bridge_warn from inside ensure_matrix_path already logged.
  bridge_isolation_v2_ensure_matrix_path "state-agent-dir" "$agent" 2>/dev/null || {
    bridge_warn "write_agent_state_marker: ensure_matrix_path failed for agent=$agent marker=$marker_name"
    return 1
  }
  local dir
  dir="$(bridge_agent_idle_marker_dir "$agent" 2>/dev/null)" \
    || dir="${BRIDGE_ACTIVE_AGENT_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state/agents}/$agent"
  mkdir -p "$dir" 2>/dev/null \
    || _bridge_isolation_v2_run_root_or_sudo mkdir -p "$dir" \
    || {
      bridge_warn "write_agent_state_marker: cannot create $dir"
      return 1
    }
  local target="$dir/$marker_name"
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
