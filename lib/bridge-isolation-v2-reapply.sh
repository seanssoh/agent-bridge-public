#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
#
# bridge-isolation-v2-reapply.sh — Operator repair tool that reasserts the
# canonical isolation-v2 ownership/mode contract on already-isolated agents.
#
# Public entrypoint: bridge_isolation_v2_reapply_cli (dispatched from
# bridge-migrate.sh as `agent-bridge migrate isolation v2 ...`). Modes:
#   --check               drift detection only — record `drift` rows for
#                         paths whose current state differs from canonical;
#                         no actions described, no mutation.
#   --dry-run             plan — record `would` rows describing the
#                         exact action --apply would take (chown/chmod/
#                         setfacl). No mutation.
#   --apply               apply the canonical state. Idempotent — a
#                         second invocation on a clean tree records
#                         `ok:already-canonical` rows and skips the
#                         recursive chown/chmod/setfacl walks.
#   --agent <name>        scope to a single linux-user-isolated agent
#                         (default: every linux-user-isolated agent in the roster)
#   --json                emit per-agent JSON report instead of human text
#
# Why a separate tool from `bridge_isolation_v2_migrate_cli`:
#
# `bridge-isolation-v2-migrate.sh` is the *initial* legacy → v2 migration
# tool. It mirrors legacy trees into a fresh `BRIDGE_DATA_ROOT`, writes the
# layout marker, and is intended to run exactly once per install.
#
# This module is the *post-upgrade repair* tool. An install that was carried
# from v0.7.x → v0.8.x via successive `agent-bridge upgrade --apply` calls
# never went through the migrate tool — its `~/.agent-bridge/agents/<agent>/`
# tree drifted in place. Issue #737 documents the breakage modes:
#
#   1. `agents/<agent>/.claude/` was never created — controller helpers
#      that try to install settings symlinks die with PermissionError on
#      the 2750-mode agent root.
#   2. Plugin state files (`workdir/.teams/.env`, `workdir/.ms365/.env`)
#      ended up `agent:controller 0600` — controller readiness probes
#      cannot read them via group, and the documented `setup teams`
#      recovery path also fails for the same reason. (v3 contract,
#      #998 PR B: these files are now isolated-UID-owned 0600/no-ACL;
#      controller accesses via passwordless sudo, not group read.)
#   3. `/home/agent-bridge-<agent>/` (the isolated agent's actual Linux
#      home) is owned by `root:agent-bridge-<agent>` with a transitional
#      v0.7-era named-user POSIX ACL granting only the controller `r-x`,
#      leaving the agent itself with **no effective access** to its own
#      home — Claude on the isolated UID immediately EACCESes on
#      `~/.claude/plugins/cache/...`.
#
# The canonical post-v2 contract (per `lib/bridge-isolation-v2.sh:38-62`
# and the upstream answer comment on #737) is:
#
#   agents/<agent>/                    root:ab-agent-<agent>      2750
#   agents/<agent>/{home,workdir,
#     runtime,logs,requests,
#     responses}/                      agent:ab-agent-<agent>     2770
#   agents/<agent>/credentials/        controller:ab-agent-<agent> 2750
#   agents/<agent>/.claude/            controller:ab-agent-<agent> 0750  (#1766)
#   agents/<agent>/.claude/settings.effective.json
#                                      controller:ab-agent-<agent> 0640  (#1766)
#   agents/<agent>/agent-env.sh        controller:ab-agent-<agent> 0640
#   agents/<agent>/workdir/.<provider>/ agent:ab-agent-<agent>     2770  (dir node only)
#     .env, access.json, state.json,   agent:ab-agent-<agent>     0600  (v3 contract,
#     mcp.json                                                           no group read)
#   /home/agent-bridge-<agent>/        agent:agent                u+rwX,go-rwx
#                                      (no extended POSIX ACL)
#
# ACL contract (KNOWN_ISSUES.md §16): the v2 layout itself contains NO
# named-user POSIX ACLs. The single transitional exception is
# `~/.claude/.credentials.json`, which `bridge_linux_grant_claude_credentials_access`
# manages and which this tool MUST NOT touch. Inside the v2 layout AND
# inside the agent's Linux home, every named-user POSIX ACL is leftover
# v0.7 transitional cruft and is stripped via `setfacl -bR`.
#
# Platform: macOS / non-Linux hosts have no isolated UID concept and no
# `setfacl`. The CLI is a contract no-op on those hosts: it returns 0
# with no stdout — neither text nor JSON — so operators do not mistake
# a non-Linux invocation for a meaningful result.
#
# Active-session safety: this tool only mutates filesystem ownership/mode
# bits on isolation-v2-shaped directories. It does not stop or restart the
# daemon and does not touch the queue. Operators may run --apply on a live
# install; the worst case is a transient EACCES on a probe that races with
# the chgrp pass.

# ---------------------------------------------------------------------------
# 1. helpers — platform / agent enumeration
# ---------------------------------------------------------------------------

# Source the platform discriminator if not already loaded. Same two-path
# pattern as lib/bridge-isolation-v2.sh:122-129 — bridge-lib.sh / bridge-
# migrate.sh sources it before us in the normal flow, but a direct caller
# (e.g., a tool that sources only this module) needs the helper brought
# in here so `bridge_isolation_v2_enforce` resolves at line 753 below.
if ! declare -f bridge_isolation_v2_enforce >/dev/null 2>&1; then
  _BRIDGE_V2_REAPPLY_MODULE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  if [[ -f "$_BRIDGE_V2_REAPPLY_MODULE_DIR/bridge-isolation-discriminator.sh" ]]; then
    # shellcheck source=bridge-isolation-discriminator.sh
    source "$_BRIDGE_V2_REAPPLY_MODULE_DIR/bridge-isolation-discriminator.sh"
  fi
  unset _BRIDGE_V2_REAPPLY_MODULE_DIR
fi

bridge_isolation_v2_reapply_supported_platform() {
  # Reapply touches Linux-only primitives (sudo chown to a foreign UID,
  # setfacl). On non-Linux hosts the linux-user isolation mode itself is
  # unreachable, so the CLI silently no-ops.
  [[ "$(uname)" == "Linux" ]]
}

bridge_isolation_v2_reapply_resolve_user_home() {
  # Resolve the actual Linux home for `os_user` via getent. Empty string
  # on lookup failure (NSS miss). Caller MUST guard before chowning the
  # tree — an empty home would chown `/`.
  local os_user="$1"
  [[ -n "$os_user" ]] || return 1
  getent passwd "$os_user" 2>/dev/null | cut -d: -f6
}

bridge_isolation_v2_reapply_controller_user() {
  # Controller user in the same convention as
  # `bridge_isolation_v2_migrate_emit_plan` — prefer SUDO_USER when the
  # tool is invoked via sudo, fall back to USER, and finally LOGNAME.
  printf '%s' "${SUDO_USER:-${USER:-${LOGNAME:-}}}"
}

bridge_isolation_v2_reapply_eligible_agents() {
  # Print one agent id per line for every roster agent declared as
  # `linux-user` isolation mode. Empty when no roster has been loaded
  # (e.g. when this is invoked under a fresh tempdir BRIDGE_HOME without
  # any agents declared).
  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || return 0
  local agent
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -n "$agent" ]] || continue
    if [[ "$(bridge_agent_isolation_mode "$agent" 2>/dev/null || printf '')" == "linux-user" ]]; then
      printf '%s\n' "$agent"
    fi
  done
}

# ---------------------------------------------------------------------------
# 2. action recorder
# ---------------------------------------------------------------------------
#
# Each per-agent run accumulates a list of action records as TSV rows in
# a temp file. Columns:
#   <path>  <action>  <before>  <after>  <status>
# `status` is `would` (check/dry-run), `ok` (apply success), or
# `error:<reason>` (apply failure). The JSON renderer reads these rows.

bridge_isolation_v2_reapply_record_action() {
  local actions_file="$1"
  local path="$2"
  local action="$3"
  local before="$4"
  local after="$5"
  local status="$6"
  printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$action" "$before" "$after" "$status" \
    >> "$actions_file"
}

# ---------------------------------------------------------------------------
# 3. probe helpers (read-only — never mutate)
# ---------------------------------------------------------------------------

bridge_isolation_v2_reapply_probe_owner_group_mode() {
  # Print "owner:group mode" for $1, or "absent" if missing. Tries GNU
  # `stat -c` first, falls back to BSD `stat -f` (so the unit test runs
  # on macOS even though the apply path is Linux-only).
  local target="$1"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    printf 'absent'
    return 0
  fi
  local raw
  raw="$(stat -c '%U:%G %a' "$target" 2>/dev/null \
    || stat -f '%Su:%Sg %Lp' "$target" 2>/dev/null \
    || true)"
  if [[ -z "$raw" ]]; then
    printf 'unknown'
    return 0
  fi
  printf '%s' "$raw"
}

bridge_isolation_v2_reapply_has_named_acl() {
  # Returns 0 when `getfacl` reports any named-user or named-group ACL
  # entry on $1. Returns 1 when there is none, the path is missing, or
  # `getfacl` is not installed (acl package absent → treat as no
  # extended ACLs to strip).
  local target="$1"
  command -v getfacl >/dev/null 2>&1 || return 1
  [[ -e "$target" || -L "$target" ]] || return 1
  getfacl --absolute-names --skip-base "$target" 2>/dev/null \
    | grep -Eq '^(user|group):[^:]+:' \
    || return 1
  return 0
}

bridge_isolation_v2_reapply_has_extended_acl() {
  # Returns 0 when `getfacl` reports ANY extended ACL entry on $1 — a
  # named user/group, a `mask::` entry, or a `default:` entry. Broader
  # than has_named_acl, which matches named rows only.
  #
  # The v3 channel-dotenv contract is "no extended ACL at all" (the
  # isolated UID owns its own 0600 dotenv — there is nothing to grant).
  # A residual `mask::` with no named rows still violates that contract,
  # so the v3 detector MUST use this predicate: has_named_acl would
  # false-clean a mask-only file and let `--check` emit
  # `ok:already-canonical` / `--apply` skip `setfacl -b`.
  #
  # `--skip-base` already drops the base user::/group::/other:: triad,
  # so any remaining user:/group:/mask:/default: line is an extended
  # entry. Returns 1 when there is none, the path is missing, or
  # `getfacl` is not installed (acl package absent → nothing to strip).
  local target="$1"
  command -v getfacl >/dev/null 2>&1 || return 1
  [[ -e "$target" || -L "$target" ]] || return 1
  getfacl --absolute-names --skip-base "$target" 2>/dev/null \
    | grep -Eq '^(user|group|mask|default):' \
    || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 4. mutation helpers — direct-then-sudo, fail-loud
# ---------------------------------------------------------------------------
#
# These wrap chown/chgrp/chmod/setfacl/install with a direct attempt
# first, then `sudo -n` fallback. They take an explicit dry-run flag so
# the same call site can be reused by --check / --dry-run / --apply.

bridge_isolation_v2_reapply_run_priv() {
  # Try direct first (caller already owns), then passwordless sudo.
  if "$@" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo -n "$@" 2>/dev/null && return 0
  fi
  return 1
}

bridge_isolation_v2_reapply_chown_chmod_dir() {
  # Apply owner:group + mode to a single directory. Returns 0 / non-zero;
  # caller records the action+status.
  local owner_group="$1"
  local mode="$2"
  local dir="$3"
  bridge_isolation_v2_reapply_run_priv chown "$owner_group" "$dir" || return 1
  bridge_isolation_v2_reapply_run_priv chmod "$mode" "$dir" || return 1
  return 0
}

bridge_isolation_v2_reapply_chown_chmod_file() {
  local owner_group="$1"
  local mode="$2"
  local file="$3"
  bridge_isolation_v2_reapply_run_priv chown "$owner_group" "$file" || return 1
  # If an extended ACL is present, Linux chmod updates the ACL mask rather
  # than the owning-group entry. Strip first so the target mode is applied
  # cleanly (no stale mask entry overriding the chmod result).
  if bridge_isolation_v2_reapply_has_named_acl "$file"; then
    bridge_isolation_v2_reapply_run_priv setfacl -b "$file" || return 1
  fi
  bridge_isolation_v2_reapply_run_priv chmod "$mode" "$file" || return 1
  return 0
}

bridge_isolation_v2_reapply_install_dir() {
  local owner="$1"
  local group="$2"
  local mode="$3"
  local dir="$4"
  bridge_isolation_v2_reapply_run_priv install -d -o "$owner" -g "$group" -m "$mode" "$dir" \
    || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 5. per-agent reapply pass
# ---------------------------------------------------------------------------

bridge_isolation_v2_reapply_one_agent() {
  # Reapply (or audit, when mode=check/dry-run) the canonical contract on
  # one agent. Args:
  #   $1 mode           check | dry-run | apply
  #   $2 agent          agent id
  #   $3 actions_file   TSV destination for action rows (caller-owned)
  #   $4 errors_file    one-line error messages (caller-owned)
  local mode="$1"
  local agent="$2"
  local actions_file="$3"
  local errors_file="$4"

  local apply=0
  case "$mode" in
    apply) apply=1 ;;
    check|dry-run) apply=0 ;;
    *)
      printf 'unknown reapply mode: %s\n' "$mode" >> "$errors_file"
      return 1
      ;;
  esac

  local agent_grp
  agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
  if [[ -z "$agent_grp" ]]; then
    printf '%s\n' "agent_group_name: cannot derive group for agent '$agent'" \
      >> "$errors_file"
    return 1
  fi

  local os_user
  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
  if [[ -z "$os_user" ]]; then
    printf '%s\n' "os_user: agent '$agent' has no os_user (roster declares linux-user but no os_user mapping)" \
      >> "$errors_file"
    return 1
  fi

  local controller_user
  controller_user="$(bridge_isolation_v2_reapply_controller_user)"
  if [[ -z "$controller_user" ]]; then
    printf '%s\n' "controller_user: cannot resolve controller user (SUDO_USER/USER/LOGNAME all empty)" \
      >> "$errors_file"
    return 1
  fi

  # Issue #1077: this tool repairs a v2 isolated agent — its on-disk
  # layout lives under `$BRIDGE_AGENT_ROOT_V2/<agent>/` (e.g.
  # `$BRIDGE_DATA_ROOT/agents/<agent>/`), NOT under the legacy
  # `$BRIDGE_AGENT_HOME_ROOT/<agent>/` (which on a v2 install is the
  # tracked profile-template tree). Using the legacy path makes every
  # per-agent grant-matrix row land on a non-existent (or wrong) directory
  # and emit `skipped:no-such-directory`, so the tool repairs nothing.
  # Route through the v2 typed resolver so the matrix repair stays in
  # lockstep with the rest of the isolation-v2 stack (PR #1081 LAYOUT).
  local agent_root
  agent_root="$(bridge_isolation_v2_agent_root "$agent" 2>/dev/null || true)"
  if [[ -z "$agent_root" ]]; then
    printf '%s\n' "agent_root: bridge_isolation_v2_agent_root returned empty for agent '$agent' (BRIDGE_AGENT_ROOT_V2 unset — v2 layout not active?)" \
      >> "$errors_file"
    return 1
  fi

  # ------------------------------------------------------------------
  # Layout target table
  # ------------------------------------------------------------------
  # Each row is (kind, path, target_owner_group, target_mode). For
  # `kind=dir_install` the row creates the dir if missing; for
  # `kind=dir`/`kind=file` the row asserts ownership/mode if the path
  # exists. Missing dirs/files for kind=dir/file are skipped (recorded
  # as `absent`) so this stays a pure repair tool — it does not invent
  # workdir/runtime/etc when the agent has not been started.
  # ------------------------------------------------------------------

  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "dir_root" "$agent_root" "root:$agent_grp" "2750"

  local sub
  for sub in home workdir runtime logs requests responses; do
    bridge_isolation_v2_reapply_assert \
      "$mode" "$apply" "$actions_file" "$errors_file" \
      "dir" "$agent_root/$sub" "$os_user:$agent_grp" "2770"
  done

  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "dir" "$agent_root/credentials" "$controller_user:$agent_grp" "2750"

  # credentials/launch-secrets.env: controller-owned 0640 secret env file
  # sourced by bridge-run.sh. The isolated UID reads it via group r-x on
  # `credentials/`. Drift here (e.g. agent:ab-agent-<n> 0600 from a v0.7
  # leftover) blocks `bridge_isolation_v2_load_secret_env` and any
  # controller-side readiness probe. Canonical contract:
  # `controller:ab-agent-<agent> 0640` (lib/bridge-isolation-v2.sh:60-61).
  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "file" "$agent_root/credentials/launch-secrets.env" \
    "$controller_user:$agent_grp" "0640"

  # `.claude/` is the surface that triggered the #737 cascade. If missing
  # on apply, create it controller-owned so `bridge-hooks.py:
  # cmd_link_shared_settings` can install settings. #1766: the canonical
  # mode is `controller:ab-agent-<a> 0750`, NOT `controller:controller
  # 0700` — the iso UID must be able to group-traverse this dir to read its
  # own `workdir/.claude/settings.json` (a symlink into here). 0750 grants
  # the agent's OWN group r-x and traverse; controller keeps full rwx; the
  # iso UID still cannot create/replace entries (no group write, no setgid).
  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "dir_install" "$agent_root/.claude" "$controller_user:$agent_grp" "0750"

  # #1766: the per-agent-root `settings.effective.json` is the TARGET of the
  # workdir `.claude/settings.json` symlink. `bridge-hooks.py:save_json`
  # renders it controller-owned 0600 → the iso UID EACCESes on its own
  # settings on every (re)start, surfacing a blocking "Settings Error"
  # picker. Canonical contract: `controller:ab-agent-<a> 0640` — group READ
  # only (the file stays controller-owned so the iso UID can never rewrite
  # the hook contract). A freshly-isolated agent may not have rendered
  # settings yet; the `file` kind records `skipped:no-such-file` (not drift)
  # when the target is absent, so this row is safe pre-first-render.
  local _eff_settings_path="$agent_root/.claude/settings.effective.json"  # noqa: iso-helper-boundary — controller-side reapply grant-matrix path (chgrp/chmod via reapply_assert), not an iso boundary RW; sibling of the agent-env.sh / launch-secrets.env rows above
  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "file" "$_eff_settings_path" \
    "$controller_user:$agent_grp" "0640"

  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "file" "$agent_root/agent-env.sh" "$controller_user:$agent_grp" "0640"

  # Channel state dir nodes: 2770/agent-group for traversal. File contents
  # are isolated-UID-owned 0600/no-ACL (v3 contract, #998 PR B) and are
  # excluded from the workdir recursive pass below — assert only the dirs.
  local _cs_dir
  for _cs_dir in .teams .ms365 .discord .telegram .mattermost; do
    bridge_isolation_v2_reapply_assert \
      "$mode" "$apply" "$actions_file" "$errors_file" \
      "dir" "$agent_root/workdir/$_cs_dir" "$os_user:$agent_grp" "2770"
  done

  # v0.9.7 (refs #781): the duplicated writable-subdir block (this used
  # to appear twice — once at line 368 and once at line 415, identical
  # word-for-word) is now consolidated into a single matrix-driven
  # apply. The per-row contract is the SAME ContentSecurityPolicy as
  # before — `home workdir runtime logs requests responses` recursive
  # `agent_grp 2770/0660` — but the row source is now
  # `bridge_isolation_v2_matrix_rows_for_agent` so a contract change
  # ripples through migrate, prepare, reapply, and verify in lockstep.
  # Issue #746's recursive-repair contract is preserved because
  # bridge_isolation_v2_chgrp_setgid_recursive remains the helper that
  # matrix apply ultimately calls (the matrix dispatcher uses the same
  # mutation primitive set).
  # Issue #1021: shared plugin material must NEVER be re-grouped to this
  # agent's private group by a per-agent reapply — doing so drops the
  # `ab-shared` group / world-read contract and breaks every OTHER
  # isolated agent that loads the same shared plugin source. Fence the
  # shared plugin roots out of the recursive chgrp/chmod with absolute
  # --exclude-path prunes. Two roots are covered: the v2 canonical
  # shared plugins cache (`$BRIDGE_SHARED_ROOT/plugins-cache`) and the
  # legacy install-rooted plugins dir (`$BRIDGE_HOME/plugins`). Both are
  # passed even when not reachable inside `$agent_root/<sub>` — the
  # prune is a harmless no-op when the path is not in the tree, and is
  # the load-bearing guard when it IS (bind mount, real nested dir, or
  # a symlinked `<sub>` that `find` follows from the command line).
  local -a _shared_plugin_excl=()
  local _shared_plugins_cache=""
  if command -v bridge_isolation_v2_shared_plugins_root >/dev/null 2>&1; then
    _shared_plugins_cache="$(bridge_isolation_v2_shared_plugins_root 2>/dev/null || true)"
  fi
  if [[ -z "$_shared_plugins_cache" && -n "${BRIDGE_SHARED_ROOT:-}" ]]; then
    _shared_plugins_cache="$BRIDGE_SHARED_ROOT/plugins-cache"
  fi
  [[ -n "$_shared_plugins_cache" ]] \
    && _shared_plugin_excl+=(--exclude-path "$_shared_plugins_cache")
  [[ -n "${BRIDGE_HOME:-}" ]] \
    && _shared_plugin_excl+=(--exclude-path "$BRIDGE_HOME/plugins")

  local _writable_sub
  for _writable_sub in home workdir runtime logs requests responses; do
    [[ -d "$agent_root/$_writable_sub" ]] || continue
    if [[ "$apply" == "1" ]]; then
      # workdir: exclude channel state dir contents (v3 0600/no-ACL contract,
      # #998 PR B). Dir nodes are covered by the reapply_assert loop above.
      local -a _ws_excl=()
      if [[ "$_writable_sub" == "workdir" ]]; then
        _ws_excl=(--exclude-subdir .teams --exclude-subdir .ms365
                  --exclude-subdir .discord --exclude-subdir .telegram
                  --exclude-subdir .mattermost)
      fi
      # #1891: home/ and workdir/ carry a `memory/` subtree whose
      # `index.sqlite` must keep its restrictive 0600 mode — never relaxed to
      # the 0660 ab-agent-<a> content mode by this recursive pass (0600 = no
      # group read, the criterion-2 carve-out). Scope the leaf-name exclude to
      # the memory-bearing roots only. The dedicated memory normalize below
      # re-asserts 0600 and group-opens the rest of `memory/` (incl. a stale
      # 2700 tree).
      if [[ "$_writable_sub" == "home" || "$_writable_sub" == "workdir" ]]; then
        _ws_excl+=(--exclude-name index.sqlite)
      fi
      if bridge_isolation_v2_chgrp_setgid_recursive \
            "$agent_grp" 2770 0660 "$agent_root/$_writable_sub" \
            "${_ws_excl[@]}" \
            "${_shared_plugin_excl[@]}" 2>/dev/null; then
        bridge_isolation_v2_reapply_record_action \
          "$actions_file" "$agent_root/$_writable_sub" \
          "chgrp_chmod_recursive" "drift|unknown" "$agent_grp 2770/0660" "ok"
      else
        bridge_isolation_v2_reapply_record_action \
          "$actions_file" "$agent_root/$_writable_sub" \
          "chgrp_chmod_recursive" "drift|unknown" "$agent_grp 2770/0660" \
          "error:recursive_chgrp_chmod_failed"
        printf '%s\n' "chgrp/chmod recursive failed: $agent_root/$_writable_sub (need root or passwordless sudo; rerun after addressing)" \
          >> "$errors_file"
      fi
    else
      local _non_apply_status="would"
      [[ "$mode" == "check" ]] && _non_apply_status="drift"
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$agent_root/$_writable_sub" \
        "chgrp_chmod_recursive" "drift|unknown" "$agent_grp 2770/0660" \
        "$_non_apply_status"
    fi
  done

  # #1891: explicitly repair the iso-owned `memory/` trees under BOTH the
  # effective home and the workdir, INCLUDING an existing stale
  # controller-owned `2700` subtree (the later-created-agent symptom that
  # v0.16.10 reconcile did NOT repair). The recursive pass above skips
  # `index.sqlite`; this dedicated call group-opens the rest of `memory/`
  # to 2770/0660 and re-asserts the restrictive 0600 mode on index.sqlite
  # (no group read). Only mutates on apply; check/dry-run report drift via
  # the recursive row above (memory/ is a subtree of home/workdir already
  # scanned).
  if [[ "$apply" == "1" ]] \
      && command -v bridge_isolation_v2_normalize_memory_tree >/dev/null 2>&1; then
    local _mem_a="$agent_root/home/memory"
    local _mem_b="$agent_root/workdir/memory"
    if bridge_isolation_v2_normalize_memory_tree "$agent_grp" "$_mem_a" "$_mem_b" 2>/dev/null; then
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$agent_root/{home,workdir}/memory" \
        "memory_tree_normalize" "drift|2700" "$agent_grp 2770/0660 +index.sqlite=0600" "ok"
    else
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$agent_root/{home,workdir}/memory" \
        "memory_tree_normalize" "drift|2700" "$agent_grp 2770/0660 +index.sqlite=0600" \
        "error:memory_tree_normalize_failed"
      printf '%s\n' "memory/ tree normalize failed for $agent: $_mem_a / $_mem_b (iso UID may not read its own memory/; need root or passwordless sudo; rerun after addressing)" \
        >> "$errors_file"
    fi
  fi

  # v0.9.7 RC1 (refs #781): apply the per-agent state/agents/<X>/ matrix
  # row through reapply too. The dedicated CLI users hit this surface
  # most often (operator's `migrate isolation v2 --apply --agent <X>`
  # production rescue), so wiring the row here fixes the operator state
  # in-place without requiring a full re-isolate. The matrix helper is
  # idempotent and silently ok'd when the path is already canonical.
  if [[ "$apply" == "1" ]] \
      && command -v bridge_isolation_v2_apply_grant_matrix_for_agent >/dev/null 2>&1; then
    if bridge_isolation_v2_apply_grant_matrix_for_agent "$agent" --apply >/dev/null 2>&1; then
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "matrix:$agent" \
        "matrix_apply" "drift|unknown" "rc1-rc5 grant matrix" "ok"
    else
      # r9 codex catch — matrix apply failure must be a hard error,
      # not warn:matrix_partial. Previously the wrapper recorded a warn
      # label and dispatch returned 0, so a stale-strip failure (or any
      # other matrix apply hard-fail from r8) was silently masked. Now
      # mirror the failure pattern other rows already use: error:* label
      # + line in errors_file. The dispatch loop below propagates
      # non-empty errors_file to the wrapper exit code.
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "matrix:$agent" \
        "matrix_apply" "drift|unknown" "rc1-rc5 grant matrix" \
        "error:matrix_apply_failed"
      printf '%s\n' "matrix apply failed for agent '$agent' (rc1-rc5 grant matrix). Review prior bridge_warn lines for the specific row; rerun after addressing." \
        >> "$errors_file"
    fi
  fi

  # Layout-internal ACL strip — every named-user/named-group ACL inside
  # `agents/<agent>/` is v0.7 leftover per KNOWN_ISSUES §16 + #737
  # answer table. Strip recursively. The `~/.claude/.credentials.json`
  # exception lives outside this tree and is not visited here.
  bridge_isolation_v2_reapply_strip_layout_acls \
    "$mode" "$apply" "$actions_file" "$errors_file" "$agent_root"

  # Issue #771 v0.9.5: regenerate the cached `runtime/agent-env.sh`
  # (which carries `BRIDGE_AGENT_LAUNCH_CMD[$agent]` for isolated
  # agents). This file was written ONCE at agent create / v0.7→v0.8
  # isolate time with the THEN-current paths embedded in the launch
  # cmd (e.g. `TEAMS_STATE_DIR=$BRIDGE_HOME/agents/<X>/.teams`). After
  # v2 layout migration moved channel state dirs under `workdir/`
  # (e.g. `workdir/.teams/`), the cached launch cmd still pointed at
  # the pre-v2 path → bun teams server.ts started with stale
  # TEAMS_STATE_DIR → silent exit before bind → operator's #771
  # symptom (only one of N agents' Teams server LISTEN-ing).
  #
  # bridge_write_linux_agent_env_file recomputes the launch cmd from
  # the LIVE roster + current `bridge_agent_workdir` (which honors
  # BRIDGE_AGENT_ROOT_V2 + appends `/workdir`), so calling it here
  # refreshes the cache to v2-correct paths. Skipped on check / dry-
  # run modes (they only report; mutation belongs to apply). Symlink
  # rejection is enforced by the writer itself (lib/bridge-agents.sh
  # `bridge_write_linux_agent_env_file` v0.9.5 r2 hardening —
  # `runtime/` is agent-UID-writable so a planted symlink could
  # otherwise corrupt controller-owned files).
  if [[ "$apply" == "1" ]]; then
    local _env_file=""
    local _writer_loaded=0 _path_loaded=0
    command -v bridge_write_linux_agent_env_file >/dev/null 2>&1 && _writer_loaded=1
    command -v bridge_agent_linux_env_file >/dev/null 2>&1 && _path_loaded=1
    if (( _writer_loaded == 0 )) || (( _path_loaded == 0 )); then
      # r2 codex finding 2: silent skip on missing helper would mask a
      # real non-fix (load-order regression, fixture isolation). Treat
      # missing helper as an explicit error so the operator sees that
      # regen didn't actually run.
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$agent_root/runtime/agent-env.sh" \
        "agent_env_regen" "stale" "live-launch-cmd" \
        "error:helper_not_loaded"
      printf '%s\n' "agent_env_regen skipped for $agent: bridge_write_linux_agent_env_file or bridge_agent_linux_env_file not loaded (load-order regression?). Stale BRIDGE_AGENT_LAUNCH_CMD remains — channel servers may bind wrong paths." \
        >> "$errors_file"
    else
      _env_file="$(bridge_agent_linux_env_file "$agent" 2>/dev/null || true)"
      if [[ -n "$_env_file" ]]; then
        # r2 codex finding 3: idempotency — if the existing file is
        # not a symlink AND already byte-identical to what the writer
        # would produce, skip the rewrite to preserve mtime/ctime
        # ("ok:already-canonical" matches the rest of the reapply tool's
        # second-invocation contract). Generate to a temp path, cmp
        # against existing; if same, drop temp and record canonical;
        # else move temp into place (which the writer will redo
        # internally — this short-circuit only affects unchanged
        # cases). We re-use the writer rather than open-coding the
        # body so future changes to the launch_cmd format propagate.
        local _tmp_env=""
        _tmp_env="$(mktemp "${TMPDIR:-/tmp}/agent-env.regen.XXXXXX" 2>/dev/null || true)"
        if [[ -n "$_tmp_env" ]] \
            && bridge_write_linux_agent_env_file "$agent" "$_tmp_env" 2>/dev/null; then
          if [[ -f "$_env_file" && ! -L "$_env_file" ]] \
              && cmp -s "$_tmp_env" "$_env_file" 2>/dev/null; then
            rm -f "$_tmp_env"
            bridge_isolation_v2_reapply_record_action \
              "$actions_file" "$_env_file" "agent_env_regen" \
              "stale|unknown" "live-launch-cmd" "ok:already-canonical"
          else
            rm -f "$_tmp_env"
            if bridge_write_linux_agent_env_file "$agent" "$_env_file" 2>/dev/null; then
              bridge_isolation_v2_reapply_record_action \
                "$actions_file" "$_env_file" "agent_env_regen" \
                "stale" "live-launch-cmd" "ok"
            else
              bridge_isolation_v2_reapply_record_action \
                "$actions_file" "$_env_file" "agent_env_regen" \
                "stale" "live-launch-cmd" "error:write_failed"
              printf '%s\n' "agent_env_regen failed for $agent: $_env_file (next agent start will use stale BRIDGE_AGENT_LAUNCH_CMD — channel servers may bind wrong paths)" \
                >> "$errors_file"
            fi
          fi
        else
          [[ -n "$_tmp_env" ]] && rm -f "$_tmp_env"
          bridge_isolation_v2_reapply_record_action \
            "$actions_file" "$_env_file" "agent_env_regen" \
            "stale" "live-launch-cmd" "error:write_temp_failed"
          printf '%s\n' "agent_env_regen failed (temp) for $agent: $_env_file" \
            >> "$errors_file"
        fi
      fi
    fi
  else
    local _env_file_dr=""
    if command -v bridge_agent_linux_env_file >/dev/null 2>&1; then
      _env_file_dr="$(bridge_agent_linux_env_file "$agent" 2>/dev/null || true)"
    fi
    if [[ -n "$_env_file_dr" ]]; then
      local _env_dr_status="would"
      [[ "$mode" == "check" ]] && _env_dr_status="drift"
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$_env_file_dr" "agent_env_regen" \
        "stale" "live-launch-cmd" "$_env_dr_status"
    fi
  fi

  # Lane A (v0.15.0-beta4): refresh the sanitized per-agent metadata
  # snippet (`state/agents/<a>/agent-meta.env`) alongside the launch
  # cmd refresh. Same staleness window — if the os_user / engine /
  # config_dir composition drifted (e.g. operator manually
  # renamed/migrated the iso UID), the iso UID context would carry
  # stale identity until next prepare.
  #
  # #1891 (F3a): was warn-only on write failure AND never verified
  # presence after a "successful" write — so an absent/under-permissioned
  # snippet stayed silent (the daemon then mis-detected the engine). On
  # apply, write then VERIFY presence + the `0640 controller:ab-agent-<a>`
  # contract + iso-UID readability; record a hard `error:*` row + an
  # errors_file line on any failure so the reapply wrapper exits nonzero
  # (an explicit held state, not a silent pass).
  if [[ "$apply" == "1" ]]; then
    if command -v bridge_isolation_v2_write_agent_metadata >/dev/null 2>&1; then
      local _meta_file="${BRIDGE_ACTIVE_AGENT_DIR:-$BRIDGE_HOME/state/agents}/$agent/agent-meta.env"
      if ! bridge_isolation_v2_write_agent_metadata "$agent" 2>/dev/null; then
        bridge_isolation_v2_reapply_record_action \
          "$actions_file" "$_meta_file" "agent_meta_regen" \
          "stale|absent" "live-roster" "error:write_failed"
        printf '%s\n' "agent_meta_regen write failed for $agent: $_meta_file (iso UID cannot resolve its own engine/config_dir; the daemon may mis-detect the engine; rerun after addressing)" \
          >> "$errors_file"
      elif command -v bridge_isolation_v2_verify_agent_metadata >/dev/null 2>&1 \
          && ! bridge_isolation_v2_verify_agent_metadata "$agent" 2>/dev/null; then
        bridge_isolation_v2_reapply_record_action \
          "$actions_file" "$_meta_file" "agent_meta_regen" \
          "stale|absent" "live-roster" "error:verify_failed"
        printf '%s\n' "agent_meta_regen verify failed for $agent: $_meta_file (absent or wrong owner/group/mode after apply; see preceding verify_agent_metadata warning; rerun after addressing)" \
          >> "$errors_file"
      else
        bridge_isolation_v2_reapply_record_action \
          "$actions_file" "$_meta_file" "agent_meta_regen" \
          "stale|absent" "live-roster" "ok"
      fi
    fi
  else
    local _meta_file_dr="${BRIDGE_ACTIVE_AGENT_DIR:-$BRIDGE_HOME/state/agents}/$agent/agent-meta.env"
    local _meta_dr_status="would"
    [[ "$mode" == "check" ]] && _meta_dr_status="drift"
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$_meta_file_dr" "agent_meta_regen" \
      "stale|absent" "live-roster" "$_meta_dr_status"
  fi

  # ------------------------------------------------------------------
  # Agent's actual Linux home (`/home/agent-bridge-<agent>/`)
  # ------------------------------------------------------------------
  # Agent owner of own home, no extended ACL. The cascade in #737 was
  # `root:agent-bridge-<agent>` + named-user ACL leaving the agent with
  # zero effective access to its own .claude tree. The fix is the
  # opposite: chown to agent:agent, chmod u+rwX,go-rwx, setfacl -bR.

  local linux_home
  linux_home="$(bridge_isolation_v2_reapply_resolve_user_home "$os_user")"
  if [[ -z "$linux_home" ]]; then
    printf '%s\n' "linux_home: NSS lookup failed for $os_user (skipping agent home repair)" \
      >> "$errors_file"
  elif [[ "$linux_home" == "/" || "$linux_home" == "" ]]; then
    printf '%s\n' "linux_home: refusing to chown root '/' for $os_user (NSS returned empty home)" \
      >> "$errors_file"
  elif [[ ! -d "$linux_home" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$linux_home" "agent_linux_home" "absent" "absent" \
      "skipped:no-such-directory"
  else
    bridge_isolation_v2_reapply_assert_agent_home \
      "$mode" "$apply" "$actions_file" "$errors_file" \
      "$linux_home" "$os_user"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# 5a. assert helpers (one row per call)
# ---------------------------------------------------------------------------

bridge_isolation_v2_reapply_assert() {
  # Generic asserter. Records exactly one action row per call.
  local mode="$1"
  local apply="$2"
  local actions_file="$3"
  local errors_file="$4"
  local kind="$5"          # dir_root | dir | dir_install | file
  local path="$6"
  local owner_group="$7"
  local target_mode="$8"

  local target_owner
  target_owner="${owner_group%%:*}"

  local target_group
  target_group="${owner_group##*:}"

  local before
  before="$(bridge_isolation_v2_reapply_probe_owner_group_mode "$path")"
  local target_repr="$owner_group $target_mode"

  # mode → non-apply status mapping. --check records pure drift
  # ("path differs from canonical, no action proposed"); --dry-run
  # records the concrete action that --apply WOULD take. Apply paths
  # ignore this and record `ok`/`error:*` as before.
  local non_apply_status="would"
  if [[ "$mode" == "check" ]]; then
    non_apply_status="drift"
  fi

  case "$kind" in
    dir_install)
      if [[ "$before" == "absent" ]]; then
        if [[ "$apply" == "1" ]]; then
          if bridge_isolation_v2_reapply_install_dir \
              "$target_owner" "$target_group" "$target_mode" "$path"; then
            local after
            after="$(bridge_isolation_v2_reapply_probe_owner_group_mode "$path")"
            bridge_isolation_v2_reapply_record_action \
              "$actions_file" "$path" "create_dir" \
              "absent" "$after" "ok"
          else
            bridge_isolation_v2_reapply_record_action \
              "$actions_file" "$path" "create_dir" \
              "absent" "$target_repr" "error:install_dir_failed"
            printf '%s\n' "create_dir failed: $path (need root or passwordless sudo)" \
              >> "$errors_file"
          fi
        else
          bridge_isolation_v2_reapply_record_action \
            "$actions_file" "$path" "create_dir" \
            "absent" "$target_repr" "$non_apply_status"
        fi
        return 0
      fi
      # Already present — fall through to ownership/mode normalization
      # so a `.claude/` that was created in some other shape gets fixed
      # to the canonical (controller:ab-agent-<a> 0750) layout (#1766).
      ;;
    dir|dir_root)
      if [[ "$before" == "absent" ]]; then
        bridge_isolation_v2_reapply_record_action \
          "$actions_file" "$path" "chown_chmod_dir" \
          "absent" "absent" "skipped:no-such-directory"
        return 0
      fi
      ;;
    file)
      if [[ "$before" == "absent" ]]; then
        bridge_isolation_v2_reapply_record_action \
          "$actions_file" "$path" "chown_chmod_file" \
          "absent" "absent" "skipped:no-such-file"
        return 0
      fi
      ;;
    *)
      printf '%s\n' "assert: unknown kind '$kind' for $path" >> "$errors_file"
      return 1
      ;;
  esac

  # Idempotency guard: when the path is already canonical, record
  # `ok:already-canonical` and skip chown/chmod. Mirrors the agent-home
  # guard pattern at `bridge_isolation_v2_reapply_assert_agent_home`
  # (no recursive walk when the canary at the top says everything is
  # clean).
  #
  # Mode comparison must normalize format before compare because:
  #   - probe output uses `stat -c '%a'` / `stat -f '%Lp'`, both of
  #     which strip leading zeros (canonical 0640 → "640", 0700 → "700")
  #   - the layout target table records canonical modes WITH leading
  #     zeros (0640, 0700, 2750, 2770)
  # A naive `"$before" == "$target_repr"` compare therefore always
  # reports drift on `0640`/`0700` paths even when they are clean,
  # causing every `--apply` (and `--check`) to re-issue chown/chmod and
  # re-record `ok` instead of `ok:already-canonical`. Normalize via
  # `$((10#$mode))` so `640` and `0640` both become `416` (decimal of
  # the same octal) for the compare.
  #
  # Path-local ACL is also checked: the canonical layout has zero
  # named-user/named-group POSIX ACLs inside `agents/<agent>/`. If the
  # path carries a named ACL we are NOT canonical, even when owner+mode
  # match — the recursive setfacl strip pass at the agent level will
  # repair it, but we must not record this row as `ok:already-canonical`.
  local before_owner_group="${before% *}"
  local before_mode_raw="${before##* }"
  local before_mode_norm="$before_mode_raw"
  local target_mode_norm="$target_mode"
  if [[ "$before_mode_raw" =~ ^[0-7]+$ ]]; then
    before_mode_norm=$((10#$before_mode_raw))
  fi
  if [[ "$target_mode" =~ ^[0-7]+$ ]]; then
    target_mode_norm=$((10#$target_mode))
  fi
  if [[ "$before_owner_group" == "$owner_group" \
        && "$before_mode_norm" == "$target_mode_norm" ]]; then
    local path_has_named_acl=0
    if bridge_isolation_v2_reapply_has_named_acl "$path"; then
      path_has_named_acl=1
    fi
    if (( path_has_named_acl == 0 )); then
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$path" \
        "$([[ "$kind" == "file" ]] && printf 'chown_chmod_file' || printf 'chown_chmod_dir')" \
        "$before" "$before" "ok:already-canonical"
      return 0
    fi
  fi

  if [[ "$apply" != "1" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$path" \
      "$([[ "$kind" == "file" ]] && printf 'chown_chmod_file' || printf 'chown_chmod_dir')" \
      "$before" "$target_repr" "$non_apply_status"
    return 0
  fi

  local rc=0
  if [[ "$kind" == "file" ]]; then
    bridge_isolation_v2_reapply_chown_chmod_file \
      "$owner_group" "$target_mode" "$path" || rc=$?
  else
    bridge_isolation_v2_reapply_chown_chmod_dir \
      "$owner_group" "$target_mode" "$path" || rc=$?
  fi
  if (( rc != 0 )); then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$path" \
      "$([[ "$kind" == "file" ]] && printf 'chown_chmod_file' || printf 'chown_chmod_dir')" \
      "$before" "$target_repr" "error:priv_op_failed"
    printf '%s\n' "$kind chown/chmod failed: $path (need root or passwordless sudo)" \
      >> "$errors_file"
    return 1
  fi
  local after
  after="$(bridge_isolation_v2_reapply_probe_owner_group_mode "$path")"
  bridge_isolation_v2_reapply_record_action \
    "$actions_file" "$path" \
    "$([[ "$kind" == "file" ]] && printf 'chown_chmod_file' || printf 'chown_chmod_dir')" \
    "$before" "$after" "ok"
}

bridge_isolation_v2_reapply_strip_layout_acls() {
  # Strip every named-user/named-group POSIX ACL under
  # `agents/<agent>/`. Records one action row per call (not per file)
  # because the recursive walk is opaque from the operator's
  # perspective; the row's `before` field carries a sentinel describing
  # which subtree was affected.
  local mode="$1"
  local apply="$2"
  local actions_file="$3"
  local errors_file="$4"
  local root="$5"

  if [[ ! -d "$root" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$root" "setfacl_strip_recursive" \
      "absent" "absent" "skipped:no-such-directory"
    return 0
  fi

  # Platform discriminator gate (S5 Track A2, audit C-S2 Bucket 2):
  # POSIX `setfacl` is Linux-only. The tool-presence check below would
  # false-pass on a Darwin host with Homebrew-installed Linux setfacl
  # (BSD ACL semantics differ — silent no-op or attribute-error). The
  # discriminator gate is platform-aware and pre-empts the tool-presence
  # check on non-Linux hosts. Operator can force via
  # BRIDGE_ISOLATION_REQUIRED=yes (the tool-presence check still
  # protects against missing setfacl on Linux).
  if ! bridge_isolation_v2_enforce; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$root" "setfacl_strip_recursive" \
      "non-linux-host" "non-linux-host" "skipped:platform-discriminator"
    return 0
  fi

  if ! command -v setfacl >/dev/null 2>&1; then
    # ACL toolchain absent → nothing was set, nothing to strip.
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$root" "setfacl_strip_recursive" \
      "no-acl-tooling" "no-acl-tooling" "skipped:setfacl-missing"
    return 0
  fi

  # Cheap pre-check: only run the recursive setfacl when we actually
  # see a named ACL anywhere in the tree. Avoids a big `find -exec
  # setfacl` pass on installs that never had v0.7 ACL cruft.
  local has_acl=0
  if command -v getfacl >/dev/null 2>&1; then
    if getfacl --absolute-names -R --skip-base "$root" 2>/dev/null \
        | grep -Eq '^(user|group):[^:]+:'; then
      has_acl=1
    fi
  else
    # No getfacl → assume we may have ACLs and let setfacl no-op
    # cleanly when there are none.
    has_acl=1
  fi

  if (( has_acl == 0 )); then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$root" "setfacl_strip_recursive" \
      "no-named-acl" "no-named-acl" "ok:nothing-to-strip"
    return 0
  fi

  if [[ "$apply" != "1" ]]; then
    local non_apply_status="would"
    [[ "$mode" == "check" ]] && non_apply_status="drift"
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$root" "setfacl_strip_recursive" \
      "named-acl-present" "named-acl-stripped" "$non_apply_status"
    return 0
  fi

  if bridge_isolation_v2_reapply_run_priv setfacl -bR -- "$root"; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$root" "setfacl_strip_recursive" \
      "named-acl-present" "named-acl-stripped" "ok"
    return 0
  fi

  bridge_isolation_v2_reapply_record_action \
    "$actions_file" "$root" "setfacl_strip_recursive" \
    "named-acl-present" "named-acl-present" "error:setfacl_failed"
  printf '%s\n' "setfacl -bR failed: $root (need root or passwordless sudo)" \
    >> "$errors_file"
  return 1
}

bridge_isolation_v2_reapply_assert_agent_home() {
  # Reapply contract on `/home/agent-bridge-<agent>/`:
  #   - chown -R agent:agent
  #   - chmod -R u+rwX,go-rwx
  #   - setfacl -bR (strip transitional v0.7 named-user ACLs)
  #
  # The `~/.claude/.credentials.json` exception in KNOWN_ISSUES §16 is
  # on the *operator's* home (`$controller_home/.claude/.credentials.json`),
  # NOT on the isolated agent's home, so stripping ACLs here does not
  # touch that exception.
  local mode="$1"
  local apply="$2"
  local actions_file="$3"
  local errors_file="$4"
  local linux_home="$5"
  local os_user="$6"

  local before
  before="$(bridge_isolation_v2_reapply_probe_owner_group_mode "$linux_home")"
  local target_repr_owner="$os_user:$os_user"

  local home_has_named_acl="no-named-acl"
  if bridge_isolation_v2_reapply_has_named_acl "$linux_home"; then
    home_has_named_acl="named-acl-present"
  fi

  # Idempotency guard: if the *top-level* of the home is already
  # `os_user:os_user` with go-rwx stripped AND no named ACL is present,
  # treat the whole tree as canonical and skip the recursive chown/chmod
  # /setfacl. This makes the second `--apply` invocation a true no-op
  # (the first one already normalized the tree, and there is no out-of
  # -band drift source between calls). The recursive walk costs are
  # measurable on agents with large `~/.claude/projects/` trees, so we
  # avoid it when the canary at the top says everything below is clean.
  #
  # The check is intentionally coarse — we trust the top-level mode bits
  # as a proxy for the recursive state. An operator who manually chmods
  # something deep inside the tree and then runs --apply expecting a
  # full rewalk should pass --check first to confirm drift; a clean
  # canary means we skip.
  if [[ "$apply" == "1" && "$before" != "absent" && "$before" != "unknown" ]]; then
    local before_owner_group="${before% *}"
    local before_mode="${before##* }"
    if [[ "$before_owner_group" == "$target_repr_owner" \
          && "$home_has_named_acl" == "no-named-acl" ]]; then
      # go-rwx implies the last digit and the middle digit must each
      # have the read/write bits cleared. Cheap probe: any group/other
      # bit set in the top-level mode means we still need the recursive
      # chmod pass; otherwise the tree is canonical.
      if [[ -n "$before_mode" && "$before_mode" =~ ^[0-7][0-7][0-7]+$ ]]; then
        local group_digit="${before_mode:1:1}"
        local other_digit="${before_mode:2:1}"
        if [[ "$group_digit" == "0" && "$other_digit" == "0" ]]; then
          bridge_isolation_v2_reapply_record_action \
            "$actions_file" "$linux_home" "chown_recursive_agent_home" \
            "$before" "$before" "ok:already-canonical"
          bridge_isolation_v2_reapply_record_action \
            "$actions_file" "$linux_home" "setfacl_strip_recursive" \
            "no-named-acl" "no-named-acl" "ok:already-canonical"
          return 0
        fi
      fi
    fi
  fi

  if [[ "$apply" != "1" ]]; then
    local non_apply_status="would"
    [[ "$mode" == "check" ]] && non_apply_status="drift"
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$linux_home" "chown_recursive_agent_home" \
      "$before" "$target_repr_owner u+rwX,go-rwx" "$non_apply_status"
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$linux_home" "setfacl_strip_recursive" \
      "$home_has_named_acl" "no-named-acl" "$non_apply_status"
    return 0
  fi

  local rc=0

  # 1) Recursive chown to agent:agent.
  if ! bridge_isolation_v2_reapply_run_priv \
        chown -R "$os_user:$os_user" -- "$linux_home"; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$linux_home" "chown_recursive_agent_home" \
      "$before" "$target_repr_owner" "error:chown_R_failed"
    printf '%s\n' "chown -R $os_user:$os_user failed on $linux_home" \
      >> "$errors_file"
    rc=1
  else
    # 2) Recursive chmod u+rwX,go-rwx — fix world/group readable cruft
    # without clobbering executable bits on subdirs/scripts.
    if ! bridge_isolation_v2_reapply_run_priv \
          chmod -R u+rwX,go-rwx -- "$linux_home"; then
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$linux_home" "chmod_recursive_agent_home" \
        "$before" "$target_repr_owner u+rwX,go-rwx" "error:chmod_R_failed"
      printf '%s\n' "chmod -R u+rwX,go-rwx failed on $linux_home" \
        >> "$errors_file"
      rc=1
    else
      local after
      after="$(bridge_isolation_v2_reapply_probe_owner_group_mode "$linux_home")"
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$linux_home" "chown_recursive_agent_home" \
        "$before" "$after" "ok"
    fi
  fi

  # 3) Strip transitional ACLs on the agent's home tree.
  if command -v setfacl >/dev/null 2>&1; then
    if bridge_isolation_v2_reapply_run_priv setfacl -bR -- "$linux_home"; then
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$linux_home" "setfacl_strip_recursive" \
        "named-acl-maybe" "no-named-acl" "ok"
    else
      bridge_isolation_v2_reapply_record_action \
        "$actions_file" "$linux_home" "setfacl_strip_recursive" \
        "named-acl-maybe" "named-acl-maybe" "error:setfacl_failed"
      printf '%s\n' "setfacl -bR failed on $linux_home" >> "$errors_file"
      rc=1
    fi
  else
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$linux_home" "setfacl_strip_recursive" \
      "no-acl-tooling" "no-acl-tooling" "skipped:setfacl-missing"
  fi

  return $rc
}

# ---------------------------------------------------------------------------
# 6. report rendering — text + JSON
# ---------------------------------------------------------------------------

bridge_isolation_v2_reapply_render_text() {
  # Text report. One block per agent.
  local mode="$1"
  local agents_file="$2"   # one agent id per line
  local actions_dir="$3"   # contains <agent>.actions and <agent>.errors

  local total_agents=0
  local total_repaired=0

  printf '== isolation-v2 reapply (mode=%s) ==\n' "$mode"

  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    total_agents=$((total_agents + 1))
    local actions_file="$actions_dir/$agent.actions"
    local errors_file="$actions_dir/$agent.errors"
    printf '\nagent: %s\n' "$agent"

    if [[ ! -f "$actions_file" ]]; then
      printf '  (no actions recorded)\n'
      continue
    fi

    local row_path row_action row_before row_after row_status
    local agent_repaired=0
    while IFS=$'\t' read -r row_path row_action row_before row_after row_status; do
      [[ -n "$row_path" ]] || continue
      printf '  %-32s %-26s %s -> %s [%s]\n' \
        "$row_action" "$row_status" "$row_before" "$row_after" "$row_path"
      # An agent counts toward `repaired` whenever any row reflects a
      # non-canonical state that the tool surfaced (`drift` for --check,
      # `would` for --dry-run) or actually fixed (`ok`, but NOT
      # `ok:already-canonical` — that row means we did nothing because
      # the path was already correct, which is exactly what idempotent
      # second --apply runs should produce).
      case "$row_status" in
        ok|would|drift) agent_repaired=1 ;;
      esac
    done < "$actions_file"

    if (( agent_repaired )); then
      total_repaired=$((total_repaired + 1))
    fi

    if [[ -s "$errors_file" ]]; then
      printf '  errors:\n'
      sed 's/^/    - /' "$errors_file"
    fi
  done < "$agents_file"

  printf '\nsummary: total_agents=%d repaired=%d mode=%s\n' \
    "$total_agents" "$total_repaired" "$mode"
}

bridge_isolation_v2_reapply_render_json() {
  # JSON report. Schema:
  #   { "agents": [ { "agent": "<name>", "isolated": true,
  #                   "actions": [ {path,action,before,after,status}, ... ],
  #                   "errors": [ "...", ... ] } ],
  #     "total_agents": N, "total_repaired": M, "mode": "<mode>" }
  local mode="$1"
  local agents_file="$2"
  local actions_dir="$3"

  bridge_require_python
  python3 - "$mode" "$agents_file" "$actions_dir" <<'PY'
import json
import sys
from pathlib import Path

mode = sys.argv[1]
agents_file = Path(sys.argv[2])
actions_dir = Path(sys.argv[3])

agents_out = []
total_repaired = 0

agent_ids = [line.strip() for line in agents_file.read_text().splitlines() if line.strip()]
for agent in agent_ids:
    actions_path = actions_dir / f"{agent}.actions"
    errors_path = actions_dir / f"{agent}.errors"
    actions = []
    repaired = False
    if actions_path.exists():
        for line in actions_path.read_text().splitlines():
            if not line:
                continue
            cols = line.split("\t")
            while len(cols) < 5:
                cols.append("")
            path, action, before, after, status = cols[:5]
            actions.append({
                "path": path,
                "action": action,
                "before": before,
                "after": after,
                "status": status,
            })
            # `ok:already-canonical` is intentionally excluded — it
            # means the path was already correct and we did nothing,
            # which is the desired outcome of an idempotent second
            # --apply run. `drift` (--check) and `would` (--dry-run)
            # both reflect surfaced non-canonical state.
            if status in ("ok", "would", "drift"):
                repaired = True
    errors = []
    if errors_path.exists():
        errors = [ln for ln in errors_path.read_text().splitlines() if ln]
    if repaired:
        total_repaired += 1
    agents_out.append({
        "agent": agent,
        "isolated": True,
        "actions": actions,
        "errors": errors,
    })

print(json.dumps({
    "mode": mode,
    "agents": agents_out,
    "total_agents": len(agent_ids),
    "total_repaired": total_repaired,
}, indent=2))
PY
}

# ---------------------------------------------------------------------------
# 7. CLI dispatch
# ---------------------------------------------------------------------------

bridge_isolation_v2_reapply_cli() {
  # Args: already-shifted past `migrate isolation v2`.
  local mode=""
  local target_agent=""
  local emit_json=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        [[ -z "$mode" ]] || bridge_die "migrate isolation v2: --check/--dry-run/--apply are mutually exclusive"
        mode="check"
        shift
        ;;
      --dry-run)
        [[ -z "$mode" ]] || bridge_die "migrate isolation v2: --check/--dry-run/--apply are mutually exclusive"
        mode="dry-run"
        shift
        ;;
      --apply)
        [[ -z "$mode" ]] || bridge_die "migrate isolation v2: --check/--dry-run/--apply are mutually exclusive"
        mode="apply"
        shift
        ;;
      --agent)
        [[ $# -ge 2 ]] || bridge_die "migrate isolation v2: --agent requires a value"
        target_agent="$2"
        shift 2
        ;;
      --json)
        emit_json=1
        shift
        ;;
      -h|--help|help)
        cat <<'USAGE'
Usage: agent-bridge migrate isolation v2 [--check|--dry-run|--apply] [--agent <name>] [--json]

Reapply the canonical isolation-v2 ownership/ACL contract on every
linux-user-isolated agent in the roster (or the named agent), repairing
v0.7 → v0.8 upgrade drift. Covers:

  - agents/<agent>/         root:ab-agent-<agent>      2750
  - agents/<agent>/{home,workdir,runtime,logs,requests,responses}/
                            agent:ab-agent-<agent>     2770
  - agents/<agent>/credentials/
                            controller:ab-agent-<agent> 2750
  - agents/<agent>/.claude/
                            controller:ab-agent-<agent> 0750  (created if absent;
                            #1766: group-traversable so the iso UID can read its
                            own project settings; the rendered effective file
                            inside is group-published controller:ab-agent 0640)
  - agents/<agent>/agent-env.sh
                            controller:ab-agent-<agent> 0640
  - agents/<agent>/workdir/.<provider>/
                            dir node: agent:ab-agent-<agent> 2770
                            file contents (.env, access.json, etc.):
                            v3 contract — isolated-UID-owned 0600, no ACL
                            (not touched by v2 reapply; use
                            `agent-bridge migrate isolation v3 --check`)
  - agents/<agent>/         strip every named-user/named-group POSIX ACL
  - /home/agent-bridge-<agent>/
                            agent:agent / u+rwX,go-rwx / setfacl -bR

Modes:
  --check     drift detection only. Read-only audit that reports paths
              whose current state differs from canonical. Status field
              is `drift` for non-canonical rows and `ok:already-canonical`
              for clean rows. No actions are described.
  --dry-run   plan mode. Same read-only audit as --check, but each
              non-canonical row records the concrete action --apply
              would take (status `would`, with the planned target in
              the `after` column).
  --apply     apply the canonical state. Requires root or passwordless
              sudo. Idempotent — a second --apply on a clean tree
              records `ok:already-canonical` rows and performs no
              filesystem mutation.

Notes:
  - macOS / non-Linux hosts silently no-op (no isolated UID concept).
  - The named-user ACL on ~/.claude/.credentials.json is preserved
    (KNOWN_ISSUES.md §16; managed by bridge_linux_grant_claude_credentials_access).
USAGE
        return 0
        ;;
      *)
        bridge_die "migrate isolation v2: unknown option: $1"
        ;;
    esac
  done

  if [[ -z "$mode" ]]; then
    bridge_die "migrate isolation v2: one of --check, --dry-run, --apply is required"
  fi

  # Non-Linux host → completely silent skip. linux-user isolation is
  # Linux-only (no setfacl, no foreign UIDs), so this CLI is a contract
  # no-op on macOS / *BSD / WSL-but-not-Linux. Emitting JSON or text on
  # those hosts misleads operators into thinking something happened —
  # the field expectation is "stdout empty + exit 0".
  if ! bridge_isolation_v2_reapply_supported_platform; then
    return 0
  fi

  # Materialize agents-to-process.
  local tmp_root
  tmp_root="$(mktemp -d -t agb-reapply.XXXXXX)" \
    || bridge_die "migrate isolation v2: cannot create temp dir"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp_root'" RETURN

  local agents_file="$tmp_root/agents"
  : > "$agents_file"

  if [[ -n "$target_agent" ]]; then
    if [[ "$(bridge_agent_isolation_mode "$target_agent" 2>/dev/null || printf '')" != "linux-user" ]]; then
      bridge_die "migrate isolation v2: agent '$target_agent' is not linux-user-isolated (or not in the roster)"
    fi
    printf '%s\n' "$target_agent" > "$agents_file"
  else
    bridge_isolation_v2_reapply_eligible_agents > "$agents_file"
  fi

  local actions_dir="$tmp_root/actions"
  mkdir -p "$actions_dir"

  # Per-agent pass.
  local agent
  local total_errors=0
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    local af="$actions_dir/$agent.actions"
    local ef="$actions_dir/$agent.errors"
    : > "$af"
    : > "$ef"
    bridge_isolation_v2_reapply_one_agent "$mode" "$agent" "$af" "$ef" || true
    # r9 codex catch — accumulate per-agent errors so the dispatch exit
    # code reflects them. Previously dispatch returned 0 unconditionally,
    # which meant that a matrix-apply hard-fail (or any other write
    # failure that produced an errors_file line) was masked. Operator
    # sees rc=0 from `migrate isolation v2 --apply` while verify still
    # rejects → false-positive cycle (the v0.9.5/v0.9.6 anti-pattern).
    if [[ -s "$ef" ]]; then
      total_errors=$(( total_errors + $(wc -l < "$ef" 2>/dev/null || printf 0) ))
    fi
  done < "$agents_file"

  if (( emit_json )); then
    bridge_isolation_v2_reapply_render_json "$mode" "$agents_file" "$actions_dir"
  else
    bridge_isolation_v2_reapply_render_text "$mode" "$agents_file" "$actions_dir"
  fi
  if (( total_errors > 0 )); then
    return 1
  fi
  return 0
}
