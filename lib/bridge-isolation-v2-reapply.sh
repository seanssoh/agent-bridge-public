#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
#
# bridge-isolation-v2-reapply.sh — Operator repair tool that reasserts the
# canonical isolation-v2 ownership/mode contract on already-isolated agents.
#
# Public entrypoint: bridge_isolation_v2_reapply_cli (dispatched from
# bridge-migrate.sh as `agent-bridge migrate isolation v2 ...`). Modes:
#   --check               read-only audit; print drift, no mutation
#   --dry-run             same as --check but with explicit "would do" rows
#   --apply               apply the canonical state
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
#      recovery path also fails for the same reason.
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
#   agents/<agent>/.claude/            controller:controller       0700
#   agents/<agent>/agent-env.sh        controller:ab-agent-<agent> 0640
#   agents/<agent>/workdir/.teams/.env,
#     .ms365/.env                      agent:ab-agent-<agent>     0640
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
# `setfacl`. The CLI silently no-ops on those hosts.
#
# Active-session safety: this tool only mutates filesystem ownership/mode
# bits on isolation-v2-shaped directories. It does not stop or restart the
# daemon and does not touch the queue. Operators may run --apply on a live
# install; the worst case is a transient EACCES on a probe that races with
# the chgrp pass.

# ---------------------------------------------------------------------------
# 1. helpers — platform / agent enumeration
# ---------------------------------------------------------------------------

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

  local agent_root="$BRIDGE_AGENT_HOME_ROOT/$agent"

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

  # `.claude/` is the surface that triggered the #737 cascade. If
  # missing on apply, create it controller-owned 0700 so subsequent
  # `bridge-hooks.py:cmd_link_shared_settings` can install settings.
  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "dir_install" "$agent_root/.claude" "$controller_user:$controller_user" "0700"

  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "file" "$agent_root/agent-env.sh" "$controller_user:$agent_grp" "0640"

  # Plugin state .env files: present only after a `setup teams` /
  # `setup ms365` round. When absent, do not invent.
  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "file" "$agent_root/workdir/.teams/.env" "$os_user:$agent_grp" "0640"

  bridge_isolation_v2_reapply_assert \
    "$mode" "$apply" "$actions_file" "$errors_file" \
    "file" "$agent_root/workdir/.ms365/.env" "$os_user:$agent_grp" "0640"

  # Layout-internal ACL strip — every named-user/named-group ACL inside
  # `agents/<agent>/` is v0.7 leftover per KNOWN_ISSUES §16 + #737
  # answer table. Strip recursively. The `~/.claude/.credentials.json`
  # exception lives outside this tree and is not visited here.
  bridge_isolation_v2_reapply_strip_layout_acls \
    "$mode" "$apply" "$actions_file" "$errors_file" "$agent_root"

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
            "absent" "$target_repr" "would"
        fi
        return 0
      fi
      # Already present — fall through to ownership/mode normalization
      # so a `.claude/` that was created in some other shape gets fixed
      # to the canonical (controller:controller 0700) layout.
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

  if [[ "$before" == "$target_repr" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$path" \
      "$([[ "$kind" == "file" ]] && printf 'chown_chmod_file' || printf 'chown_chmod_dir')" \
      "$before" "$before" "ok:already-canonical"
    return 0
  fi

  if [[ "$apply" != "1" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$path" \
      "$([[ "$kind" == "file" ]] && printf 'chown_chmod_file' || printf 'chown_chmod_dir')" \
      "$before" "$target_repr" "would"
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
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$root" "setfacl_strip_recursive" \
      "named-acl-present" "named-acl-stripped" "would"
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

  if [[ "$apply" != "1" ]]; then
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$linux_home" "chown_recursive_agent_home" \
      "$before" "$target_repr_owner u+rwX,go-rwx" "would"
    bridge_isolation_v2_reapply_record_action \
      "$actions_file" "$linux_home" "setfacl_strip_recursive" \
      "$(bridge_isolation_v2_reapply_has_named_acl "$linux_home" \
          && printf 'named-acl-present' \
          || printf 'no-named-acl')" \
      "no-named-acl" "would"
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
      case "$row_status" in
        ok|would) agent_repaired=1 ;;
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
            if status in ("ok", "would"):
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
                            controller:controller       0700  (created if absent)
  - agents/<agent>/agent-env.sh
                            controller:ab-agent-<agent> 0640
  - agents/<agent>/workdir/.teams/.env, .ms365/.env
                            agent:ab-agent-<agent>     0640  (if present)
  - agents/<agent>/         strip every named-user/named-group POSIX ACL
  - /home/agent-bridge-<agent>/
                            agent:agent / u+rwX,go-rwx / setfacl -bR

Modes:
  --check     audit only (read-only); print drift, no mutation.
  --dry-run   like --check but with explicit "would do" rows.
  --apply     apply the canonical state. Requires root or passwordless sudo.

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

  # Non-Linux host → silent skip with informative report.
  if ! bridge_isolation_v2_reapply_supported_platform; then
    if (( emit_json )); then
      printf '{"mode":"%s","agents":[],"total_agents":0,"total_repaired":0,"platform":"%s","skipped":"non-linux"}\n' \
        "$mode" "$(uname)"
    else
      printf '== isolation-v2 reapply (mode=%s) ==\n' "$mode"
      printf 'platform=%s — linux-user isolation is Linux-only; skipping.\n' "$(uname)"
    fi
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
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    local af="$actions_dir/$agent.actions"
    local ef="$actions_dir/$agent.errors"
    : > "$af"
    : > "$ef"
    bridge_isolation_v2_reapply_one_agent "$mode" "$agent" "$af" "$ef" || true
  done < "$agents_file"

  if (( emit_json )); then
    bridge_isolation_v2_reapply_render_json "$mode" "$agents_file" "$actions_dir"
  else
    bridge_isolation_v2_reapply_render_text "$mode" "$agents_file" "$actions_dir"
  fi
  return 0
}
