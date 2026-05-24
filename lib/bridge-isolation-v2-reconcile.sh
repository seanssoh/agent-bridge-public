#!/usr/bin/env bash
# bridge-isolation-v2-reconcile.sh — declarative install-tree reconciler
# for v2 isolation. Phase 2 architectural refactor (post-v0.14.5-beta16).
#
# Background
# ----------
# Cycles 9-12 (#1165 → #1170 → #1175 → #1178) closed bugs in helper code,
# but Phase 1 VM testing on agb-clean-test proved a deeper bug class:
# `$BRIDGE_HOME` was created as a controller-private tree (modes 0700 /
# 0600 under the operator's umask 077) while v2 isolation now runs real
# code, marker reads, state writes, and plugin setup from isolated UIDs.
# Per-cycle chmod patches in `bridge_isolation_v2_migrate_normalize_layout`
# (Layers 13-14) were already accruing; this module replaces those inline
# patches with a single declarative matrix + reconciler so every install
# / upgrade / agent-create surface lands on the same auditable contract.
#
# Design contract
# ---------------
# * Deny-by-default. Rows enumerate explicit paths only; there is NO
#   blanket `chmod -R` / `chgrp -R` walk of `$BRIDGE_HOME`. Protected
#   paths (`agent-roster*`, `handoff.local*`, `state/tasks.db`,
#   `state/daemon.log`, `state/history/`, `*.pem`/`*.key`/`*.token`,
#   `runtime/credentials/`, `runtime/secrets/`, plugin lockfiles) are
#   never touched by any row.
# * Idempotent. Apply against canonical tree → no mutations. Apply twice
#   in a row → second pass reports zero changes.
# * Auditable. `--mode check --json` emits structured drift for CI / ops;
#   `--mode apply` emits per-row CHANGED / OK / SKIP / FAILED lines.
#   Credential paths are surfaced verbatim only when the row's notes
#   field already flagged them as non-secret (the marker file path);
#   actual credential file content is never logged.
# * Read-only on missing identities (sub-system platform gate). On a
#   non-Linux host or when `bridge_isolation_v2_enforce` rejects (S3
#   discriminator), every row is a no-op success — same model as the
#   per-agent grant matrix.
#
# Row schema (14 columns, pipe-separated)
# ---------------------------------------
#   row_name|scope|path_expr|kind|owner|group|dir_mode|file_mode|
#   setgid|recursive|children_policy|mechanism|criticality|notes
#
# scope         install | per-agent | host
# kind          path_traverse | dir | dir_recursive | file_glob |
#               state_scaffold | credential_grant | marker_read_path
# owner         literal user / `controller` / `agent_user` / `root`
# group         literal / `ab-shared` / `ab-agent-<agent>` / `ab-controller`
# dir_mode      octal (0710, 2750, 0755, etc.) or `-`
# file_mode     octal (0640, 0644) or `-`
# setgid        0 or 1 (cosmetic — captured in dir_mode already)
# recursive     0 (single dir) / 1 (recurse with chmod -R g+rX style)
# children_policy  inherit | preserve | exclude:dir1,dir2
# mechanism     direct (chmod/chgrp) | helper:<fn>
# criticality   required (drift fails) | optional (drift warns)
# notes         human rationale
#
# Public function
# ---------------
#   bridge_isolation_v2_apply_install_tree_matrix \
#     --mode check|apply \
#     [--agent <name>|--all-agents] \
#     [--reason install|upgrade|agent-create|manual] \
#     [--json]
#
# Out of scope (deferred to v0.16)
# --------------------------------
# * Full Bash sweep of `bridge_linux_sudo_root` sites (148 sites — too
#   risky for this release; reconciler only hosts thin primitives reused
#   by new/changed call sites).
# * Python daemon launcher with `os.initgroups()` before setsid (would
#   close the bash-cannot-self-refresh story; v0.16 ticket).
# * Daemon auto-restart on stale supp-groups (cycle 12 already added the
#   warn; auto-restart is invasive and operator-visible).
# * Removing `agent-bridge isolate --reapply` (kept for compat; it can
#   call the new reconciler internally in a future PR).
#
# shellcheck shell=bash disable=SC2034,SC2155

# ---------------------------------------------------------------------------
# Public API constants
# ---------------------------------------------------------------------------

# Canonical row separator. Pipe is chosen to match the existing
# `matrix_rows_for_agent` schema in lib/bridge-isolation-v2.sh.
BRIDGE_ISO_RECONCILE_ROW_SEP='|'

# Per-row status emitted by `--mode apply` and `--mode check` so the
# reconciler's stdout can be parsed by JSON wrapper and by smokes.
#   ok       — already canonical (no mutation needed / observed)
#   changed  — apply mutated the path to reach canonical
#   skipped  — row was skipped (non-Linux, helper missing, path absent
#              under a benign policy)
#   missing  — required path not present (check mode only — apply
#              creates state_scaffold rows but never `dir`/`file_glob`)
#   mismatch — check mode: drift detected on a required row
#   degraded — check mode: drift detected on an optional row
#   failed   — apply mode: mutation attempt returned non-zero
BRIDGE_ISO_RECONCILE_STATUS_OK="ok"
BRIDGE_ISO_RECONCILE_STATUS_CHANGED="changed"
BRIDGE_ISO_RECONCILE_STATUS_SKIPPED="skipped"
BRIDGE_ISO_RECONCILE_STATUS_MISSING="missing"
BRIDGE_ISO_RECONCILE_STATUS_MISMATCH="mismatch"
BRIDGE_ISO_RECONCILE_STATUS_DEGRADED="degraded"
BRIDGE_ISO_RECONCILE_STATUS_FAILED="failed"

# ---------------------------------------------------------------------------
# Internal helpers — small primitives reused across row dispatchers.
# Co-locate here so reconciler-side audit logic stays in one file rather
# than reaching into lib/bridge-isolation-v2.sh's apply_row machinery
# (apply_row owns the per-agent grant matrix, not the install tree).
# ---------------------------------------------------------------------------

_bridge_iso_reconcile_log() {
  # All reconciler output to stderr so `--mode check --json` callers can
  # consume the structured JSON on stdout without polluting it.
  printf '[iso-reconcile] %s\n' "$*" >&2
}

_bridge_iso_reconcile_stat_mode() {
  # Cross-platform stat — GNU `-c %a`, BSD `-f %Lp`. Empty on miss.
  local path="$1"
  [[ -n "$path" && -e "$path" ]] || return 1
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    stat -f '%Lp' "$path" 2>/dev/null
  else
    stat -c '%a' "$path" 2>/dev/null
  fi
}

_bridge_iso_reconcile_stat_owner_group() {
  # `user:group` (names, not uid:gid). Empty on miss.
  local path="$1"
  [[ -n "$path" && -e "$path" ]] || return 1
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    stat -f '%Su:%Sg' "$path" 2>/dev/null
  else
    stat -c '%U:%G' "$path" 2>/dev/null
  fi
}

_bridge_iso_reconcile_normalize_mode() {
  # Strip leading zeros from one octal string so equality compare across
  # `0644` vs `644` etc. works (printf %o on either side normalizes).
  local raw="$1"
  [[ -n "$raw" ]] || { printf ''; return 0; }
  printf '%o' "$((8#${raw#0}))" 2>/dev/null || printf '%s' "$raw"
}

_bridge_iso_reconcile_resolve_owner_token() {
  # Resolve owner/group token (`controller`, `root`, literal) to a real
  # user/group name. `controller` defers to
  # `bridge_isolation_v2_controller_user` so the matrix can stay static
  # while still picking up the live operator's account.
  local token="$1"
  case "$token" in
    controller)
      bridge_isolation_v2_controller_user 2>/dev/null
      ;;
    controller_group)
      bridge_isolation_v2_controller_primary_group 2>/dev/null
      ;;
    root)
      printf 'root'
      ;;
    *)
      printf '%s' "$token"
      ;;
  esac
}

_bridge_iso_reconcile_resolve_group_token() {
  # Group token resolver. `ab-shared` and `ab-controller` may be
  # overridden via env (BRIDGE_SHARED_GROUP / BRIDGE_CONTROLLER_GROUP).
  local token="$1"
  case "$token" in
    ab-shared)
      printf '%s' "${BRIDGE_SHARED_GROUP:-ab-shared}"
      ;;
    ab-controller)
      printf '%s' "${BRIDGE_CONTROLLER_GROUP:-ab-controller}"
      ;;
    controller_group)
      bridge_isolation_v2_controller_primary_group 2>/dev/null
      ;;
    *)
      printf '%s' "$token"
      ;;
  esac
}

_bridge_iso_reconcile_emit_row() {
  # Emit one structured per-row line to stdout (consumed by --json
  # wrapper) and a human-friendly line to stderr.
  # Format: row_name|status|path|expected|actual|notes
  local row_name="$1" status="$2" path="$3" expected="$4" actual="$5" notes="$6"
  printf '%s|%s|%s|%s|%s|%s\n' \
    "$row_name" "$status" "$path" "$expected" "$actual" "$notes"
  _bridge_iso_reconcile_log "$row_name [$status] $path  expected=$expected  actual=$actual"
}

# ---------------------------------------------------------------------------
# Protected-path guard
# ---------------------------------------------------------------------------

_bridge_iso_reconcile_path_is_protected() {
  # Return 0 (true / protected) if the path matches the explicit
  # exclude list. Belt-and-braces: every individual row's path is
  # validated against this guard before any chmod / chgrp. A future
  # accidental row referencing `agent-roster.sh` would still be a
  # no-op SKIP instead of a security regression.
  #
  # Exclusions (rationale):
  #   agent-roster*, handoff.local*  — controller-only configs that may
  #                                    embed secrets (HMAC, channel IDs).
  #   state/tasks.db, daemon.log, history/  — controller-only operator data.
  #   *.pem, *.key, *.token, .credentials.json
  #          — secret material; only the one explicit `credential_grant`
  #            row may touch a credentials file, and it is dispatched via
  #            `bridge_isolation_v2_apply_controller_credentials_read_grant`,
  #            never raw chmod here.
  #   runtime/credentials/, runtime/secrets/  — secret stores.
  #   plugins-cache lockfiles / *.lock — coordinator state.
  local path="$1"
  [[ -n "$path" ]] || return 0
  local base
  base="$(basename -- "$path")"
  case "$base" in
    agent-roster*|handoff.local*) return 0 ;;
    tasks.db|daemon.log) return 0 ;;
    *.pem|*.key|*.token) return 0 ;;
    .credentials.json) return 0 ;;
    *.lock) return 0 ;;
  esac
  case "$path" in
    */state/history|*/state/history/*) return 0 ;;
    */runtime/credentials|*/runtime/credentials/*) return 0 ;;
    */runtime/secrets|*/runtime/secrets/*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Row dispatchers (one per kind)
# ---------------------------------------------------------------------------

_bridge_iso_reconcile_row_path_traverse() {
  # kind=path_traverse
  # Ancestor like $HOME needs o+x (or g+x) for traverse only. NEVER
  # grant read/list. Used for HOME above BRIDGE_HOME so isolated UIDs
  # can stat their way down to the install tree without listing the
  # operator's home directory.
  local mode="$1" row_name="$2" path="$3" owner="$4" group="$5" \
        dir_mode="$6" notes="$7"

  if _bridge_iso_reconcile_path_is_protected "$path"; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" "$dir_mode" "(protected)" \
      "$notes"
    return 0
  fi

  if [[ ! -d "$path" ]]; then
    # Path absent — for path_traverse this is benign on hosts where
    # BRIDGE_HOME does not live under $HOME (advanced layouts). The
    # caller's row already conditionally emitted only when the parent
    # was relevant; if we still got here the path simply doesn't exist
    # yet, skip with diagnostic.
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" "$dir_mode" "(absent)" \
      "$notes"
    return 0
  fi

  local actual_mode
  actual_mode="$(_bridge_iso_reconcile_stat_mode "$path")"
  # Compute the "would be canonical" mode = current OR the +x bits the
  # row contracts. dir_mode for path_traverse is conventionally a
  # bit-mask (o+x or g+x); we OR it in.
  local current_int
  current_int=$(( 8#${actual_mode:-0} ))
  local desired_bits
  desired_bits=$(( 8#${dir_mode#0} ))
  local target_int=$(( current_int | desired_bits ))
  if (( current_int == target_int )); then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_OK" "$path" \
      "$(printf '%o' "$desired_bits")" "$(printf '%o' "$current_int")" \
      "$notes"
    return 0
  fi

  if [[ "$mode" == "check" ]]; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_MISMATCH" "$path" \
      "$(printf '%o' "$target_int")" "$(printf '%o' "$current_int")" \
      "$notes"
    return 1
  fi

  # apply — owner of $HOME runs `chmod o+x $HOME` without sudo. Try
  # direct chmod first; fall back to root-or-sudo helper if available.
  local target_mode
  target_mode="$(printf '%o' "$target_int")"
  if chmod "$target_mode" "$path" 2>/dev/null \
      || _bridge_isolation_v2_run_root_or_sudo chmod "$target_mode" "$path"; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_CHANGED" "$path" \
      "$target_mode" "$(printf '%o' "$current_int")" "$notes"
    return 0
  fi

  _bridge_iso_reconcile_emit_row "$row_name" \
    "$BRIDGE_ISO_RECONCILE_STATUS_FAILED" "$path" \
    "$target_mode" "$(printf '%o' "$current_int")" \
    "$notes (chmod failed; operator may need to run manually: chmod $target_mode $path)"
  return 1
}

_bridge_iso_reconcile_row_dir() {
  # kind=dir — single dir: chown owner:group + chmod mode (no recursion)
  local mode="$1" row_name="$2" path="$3" owner_resolved="$4" group_resolved="$5" \
        dir_mode="$6" setgid="$7" criticality="$8" notes="$9"

  if _bridge_iso_reconcile_path_is_protected "$path"; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" \
      "$owner_resolved:$group_resolved $dir_mode" "(protected)" "$notes"
    return 0
  fi

  if [[ ! -d "$path" ]]; then
    if [[ "$criticality" == "optional" ]]; then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" \
        "$owner_resolved:$group_resolved $dir_mode" "(absent)" "$notes"
      return 0
    fi
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_MISSING" "$path" \
      "$owner_resolved:$group_resolved $dir_mode" "(absent)" "$notes"
    return 1
  fi

  local actual_mode actual_og expected_mode_norm actual_mode_norm
  actual_mode="$(_bridge_iso_reconcile_stat_mode "$path")"
  actual_og="$(_bridge_iso_reconcile_stat_owner_group "$path")"
  expected_mode_norm="$(_bridge_iso_reconcile_normalize_mode "$dir_mode")"
  actual_mode_norm="$(_bridge_iso_reconcile_normalize_mode "${actual_mode:-0}")"
  local expected_og="$owner_resolved:$group_resolved"

  if [[ "$expected_mode_norm" == "$actual_mode_norm" \
        && "$expected_og" == "$actual_og" ]]; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_OK" "$path" \
      "$expected_og $expected_mode_norm" "$actual_og $actual_mode_norm" "$notes"
    return 0
  fi

  if [[ "$mode" == "check" ]]; then
    local status_word="$BRIDGE_ISO_RECONCILE_STATUS_MISMATCH"
    [[ "$criticality" == "optional" ]] \
      && status_word="$BRIDGE_ISO_RECONCILE_STATUS_DEGRADED"
    _bridge_iso_reconcile_emit_row "$row_name" "$status_word" "$path" \
      "$expected_og $expected_mode_norm" "$actual_og $actual_mode_norm" "$notes"
    [[ "$criticality" == "optional" ]] && return 0
    return 1
  fi

  # apply — only mutate the bits that differ to keep the audit signal
  # honest. chown / chmod individually so a per-row FAIL points at the
  # specific operation, not a compound one.
  local rc=0
  if [[ "$expected_og" != "$actual_og" ]]; then
    if ! _bridge_isolation_v2_run_root_or_sudo \
        chown "$owner_resolved:$group_resolved" "$path"; then
      rc=1
    fi
  fi
  if (( rc == 0 )) && [[ "$expected_mode_norm" != "$actual_mode_norm" ]]; then
    if ! _bridge_isolation_v2_run_root_or_sudo chmod "$dir_mode" "$path"; then
      rc=1
    fi
  fi
  if (( rc == 0 )); then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_CHANGED" "$path" \
      "$expected_og $expected_mode_norm" "$actual_og $actual_mode_norm" "$notes"
    return 0
  fi
  _bridge_iso_reconcile_emit_row "$row_name" \
    "$BRIDGE_ISO_RECONCILE_STATUS_FAILED" "$path" \
    "$expected_og $expected_mode_norm" "$actual_og $actual_mode_norm" "$notes"
  return 1
}

_bridge_iso_reconcile_row_dir_recursive() {
  # kind=dir_recursive — explicit code dir gets chgrp -R + chmod -R
  # g+rX. The capital X grants execute only on dirs (POSIX), preserving
  # the existing executable bit on scripts that have it without
  # promoting every file to executable.
  local mode="$1" row_name="$2" path="$3" group_resolved="$4" \
        children_policy="$5" criticality="$6" notes="$7"

  if _bridge_iso_reconcile_path_is_protected "$path"; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" \
      "group=$group_resolved g+rX recursive" "(protected)" "$notes"
    return 0
  fi

  if [[ ! -d "$path" ]]; then
    if [[ "$criticality" == "optional" ]]; then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" \
        "group=$group_resolved g+rX recursive" "(absent)" "$notes"
      return 0
    fi
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_MISSING" "$path" \
      "group=$group_resolved g+rX recursive" "(absent)" "$notes"
    return 1
  fi

  # Drift signal: probe a representative file under the dir for the
  # expected g+r bit. cheap proxy — exhaustive walk would be slow on
  # large lib/ trees and the apply path is idempotent anyway.
  local probe_file probe_group probe_mode
  probe_file="$(find "$path" -maxdepth 2 -type f -print -quit 2>/dev/null \
                || true)"
  if [[ -n "$probe_file" ]]; then
    probe_group="$(stat -f '%Sg' "$probe_file" 2>/dev/null \
                 || stat -c '%G' "$probe_file" 2>/dev/null)"
    probe_mode="$(_bridge_iso_reconcile_stat_mode "$probe_file")"
  fi
  local probe_mode_int=$(( 8#${probe_mode:-0} ))
  # g+r = bit 0040, dir +x is checked separately on directories. For
  # files we want at least g+r (octal 0040).
  local has_group_read=0
  if (( probe_mode_int & 040 )); then
    has_group_read=1
  fi

  if [[ -n "$probe_file" ]] \
      && [[ "$probe_group" == "$group_resolved" ]] \
      && (( has_group_read == 1 )); then
    # Don't reflexively re-mutate. Honest "ok" signal.
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_OK" "$path" \
      "group=$group_resolved g+rX recursive" \
      "group=$probe_group mode=$probe_mode (probe: $probe_file)" \
      "$notes"
    return 0
  fi

  if [[ "$mode" == "check" ]]; then
    local status_word="$BRIDGE_ISO_RECONCILE_STATUS_MISMATCH"
    [[ "$criticality" == "optional" ]] \
      && status_word="$BRIDGE_ISO_RECONCILE_STATUS_DEGRADED"
    _bridge_iso_reconcile_emit_row "$row_name" "$status_word" "$path" \
      "group=$group_resolved g+rX recursive" \
      "group=${probe_group:-?} mode=${probe_mode:-?} (probe: ${probe_file:-none})" \
      "$notes"
    [[ "$criticality" == "optional" ]] && return 0
    return 1
  fi

  # apply — recursive chgrp + chmod g+rX. Errors land per-call so the
  # operator sees which side failed.
  local rc=0
  if ! _bridge_isolation_v2_run_root_or_sudo \
      chgrp -R "$group_resolved" "$path"; then
    rc=1
  fi
  if (( rc == 0 )) && ! _bridge_isolation_v2_run_root_or_sudo \
      chmod -R g+rX "$path"; then
    rc=1
  fi
  if (( rc == 0 )); then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_CHANGED" "$path" \
      "group=$group_resolved g+rX recursive" \
      "group=${probe_group:-?} mode=${probe_mode:-?}" "$notes"
    return 0
  fi
  _bridge_iso_reconcile_emit_row "$row_name" \
    "$BRIDGE_ISO_RECONCILE_STATUS_FAILED" "$path" \
    "group=$group_resolved g+rX recursive" \
    "group=${probe_group:-?} mode=${probe_mode:-?}" "$notes"
  return 1
}

_bridge_iso_reconcile_row_file_glob() {
  # kind=file_glob — root-level entrypoint files (agent-bridge, agb,
  # bridge-*.sh, bridge-*.py). Each matching file gets chgrp + chmod
  # g+r. Excludes go through the path_is_protected guard. Pattern is
  # supplied via the `path_expr` field literally (a shell glob the row
  # author types).
  local mode="$1" row_name="$2" glob="$3" group_resolved="$4" \
        criticality="$5" notes="$6"

  local parent
  parent="$(dirname "$glob")"
  if [[ ! -d "$parent" ]]; then
    if [[ "$criticality" == "optional" ]]; then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$glob" \
        "group=$group_resolved g+r each" "(parent absent: $parent)" "$notes"
      return 0
    fi
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_MISSING" "$glob" \
      "group=$group_resolved g+r each" "(parent absent: $parent)" "$notes"
    return 1
  fi

  local matched=0 changed=0 failed=0 ok=0 skipped=0
  local probe_evidence=""
  local file base
  # Iterate the glob via `compgen -G` so shell globbing happens once.
  while IFS= read -r file; do
    [[ -n "$file" && -f "$file" ]] || continue
    base="$(basename -- "$file")"
    if _bridge_iso_reconcile_path_is_protected "$file"; then
      ((skipped++)) || true
      continue
    fi
    ((matched++)) || true
    local fg fmode
    fg="$(stat -f '%Sg' "$file" 2>/dev/null \
           || stat -c '%G' "$file" 2>/dev/null)"
    fmode="$(_bridge_iso_reconcile_stat_mode "$file")"
    local fmode_int=$(( 8#${fmode:-0} ))
    if [[ "$fg" == "$group_resolved" ]] && (( fmode_int & 040 )); then
      ((ok++)) || true
      [[ -z "$probe_evidence" ]] && probe_evidence="$base ok"
      continue
    fi
    if [[ "$mode" == "check" ]]; then
      probe_evidence="${probe_evidence:+$probe_evidence; }$base group=$fg mode=$fmode"
      continue
    fi
    if _bridge_isolation_v2_run_root_or_sudo chgrp "$group_resolved" "$file" \
        && _bridge_isolation_v2_run_root_or_sudo chmod g+r "$file"; then
      ((changed++)) || true
    else
      ((failed++)) || true
      probe_evidence="${probe_evidence:+$probe_evidence; }$base FAIL"
    fi
  done < <(compgen -G "$glob" 2>/dev/null || true)

  if (( matched == 0 )); then
    if [[ "$criticality" == "optional" ]]; then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$glob" \
        "group=$group_resolved g+r each" "(no matches; $skipped excluded)" \
        "$notes"
      return 0
    fi
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_MISSING" "$glob" \
      "group=$group_resolved g+r each" "(no matches; $skipped excluded)" \
      "$notes"
    return 1
  fi

  if [[ "$mode" == "check" ]]; then
    if [[ -n "$probe_evidence" ]] && (( ok != matched )); then
      local status_word="$BRIDGE_ISO_RECONCILE_STATUS_MISMATCH"
      [[ "$criticality" == "optional" ]] \
        && status_word="$BRIDGE_ISO_RECONCILE_STATUS_DEGRADED"
      _bridge_iso_reconcile_emit_row "$row_name" "$status_word" "$glob" \
        "group=$group_resolved g+r each" \
        "matched=$matched ok=$ok ($probe_evidence)" "$notes"
      [[ "$criticality" == "optional" ]] && return 0
      return 1
    fi
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_OK" "$glob" \
      "group=$group_resolved g+r each" \
      "matched=$matched ok=$ok skipped=$skipped" "$notes"
    return 0
  fi

  if (( failed > 0 )); then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_FAILED" "$glob" \
      "group=$group_resolved g+r each" \
      "matched=$matched changed=$changed failed=$failed" "$notes"
    return 1
  fi
  if (( changed > 0 )); then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_CHANGED" "$glob" \
      "group=$group_resolved g+r each" \
      "matched=$matched changed=$changed skipped=$skipped" "$notes"
    return 0
  fi
  _bridge_iso_reconcile_emit_row "$row_name" \
    "$BRIDGE_ISO_RECONCILE_STATUS_OK" "$glob" \
    "group=$group_resolved g+r each" \
    "matched=$matched ok=$ok skipped=$skipped" "$notes"
  return 0
}

_bridge_iso_reconcile_row_state_scaffold() {
  # kind=state_scaffold — per-agent state/agents/<agent> dir. Created
  # when absent (this is the ONE kind that mkdirs in --apply mode).
  # Other kinds refuse to invent paths because creating, say,
  # `$BRIDGE_HOME/lib/` is structurally wrong (it's source-installed).
  local mode="$1" row_name="$2" path="$3" owner_resolved="$4" \
        group_resolved="$5" dir_mode="$6" notes="$7"

  if _bridge_iso_reconcile_path_is_protected "$path"; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" \
      "$owner_resolved:$group_resolved $dir_mode" "(protected)" "$notes"
    return 0
  fi

  if [[ ! -d "$path" ]]; then
    if [[ "$mode" == "check" ]]; then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_MISSING" "$path" \
        "$owner_resolved:$group_resolved $dir_mode" "(absent)" "$notes"
      return 1
    fi
    if ! _bridge_isolation_v2_run_root_or_sudo mkdir -p "$path"; then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_FAILED" "$path" \
        "$owner_resolved:$group_resolved $dir_mode" "(mkdir failed)" "$notes"
      return 1
    fi
  fi

  # Fall through to the same chown+chmod logic as `dir` so the row is
  # canonical after scaffold-create.
  _bridge_iso_reconcile_row_dir \
    "$mode" "$row_name" "$path" "$owner_resolved" "$group_resolved" \
    "$dir_mode" "1" "required" "$notes"
}

_bridge_iso_reconcile_row_credential_grant() {
  # kind=credential_grant — dispatch to
  # `bridge_isolation_v2_apply_controller_credentials_read_grant`.
  # The helper already encapsulates ACL stripping, ancestor traversal,
  # and credential file mode contract — we just route based on mode.
  local mode="$1" row_name="$2" path="$3" agent="$4" file_mode="$5" \
        criticality="$6" notes="$7"

  if _bridge_iso_reconcile_path_is_protected "$path"; then
    # The credential file IS protected by name (.credentials.json); this
    # row is the ONE intentional exception, so we don't skip on the
    # protected guard. (Audit-trail comment: keep this branch as a
    # documentation point — every other row consults the guard, this
    # row deliberately does not.)
    :
  fi

  if [[ -z "$agent" ]]; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" \
      "credential_grant" "(no agent context)" "$notes"
    return 0
  fi

  if ! command -v bridge_isolation_v2_apply_controller_credentials_read_grant \
      >/dev/null 2>&1; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" \
      "credential_grant" "(helper missing)" "$notes"
    return 0
  fi

  if [[ "$mode" == "check" ]]; then
    # Subshell isolation (same rationale as apply branch below): the
    # check helper also calls bridge_die on missing ab-shared on a
    # live install.
    if ( bridge_isolation_v2_check_controller_credentials_read_grant \
        "$agent" "$path" "$file_mode" >/dev/null 2>&1 ); then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_OK" "$path" \
        "credential_grant ($file_mode)" "ok" "$notes"
      return 0
    fi
    local status_word="$BRIDGE_ISO_RECONCILE_STATUS_MISMATCH"
    [[ "$criticality" == "optional" ]] \
      && status_word="$BRIDGE_ISO_RECONCILE_STATUS_DEGRADED"
    _bridge_iso_reconcile_emit_row "$row_name" "$status_word" "$path" \
      "credential_grant ($file_mode)" "drift" "$notes"
    [[ "$criticality" == "optional" ]] && return 0
    return 1
  fi

  # Subshell isolation: the helper calls bridge_die on missing
  # ab-shared group + live install, which would exit the entire
  # reconciler mid-loop and drop the per-row output that `cat
  # $raw_rows_tmp` is supposed to dump at the end. Running in a
  # subshell scopes the exit to just this call so the reconciler
  # keeps walking other rows.
  if ( bridge_isolation_v2_apply_controller_credentials_read_grant \
      "$agent" "$file_mode" >/dev/null 2>&1 ); then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_CHANGED" "$path" \
      "credential_grant ($file_mode)" "applied" "$notes"
    return 0
  fi
  _bridge_iso_reconcile_emit_row "$row_name" \
    "$BRIDGE_ISO_RECONCILE_STATUS_FAILED" "$path" \
    "credential_grant ($file_mode)" "apply failed (helper bridge_die or grant error)" "$notes"
  # Optional rows: degrade to non-fatal (the row is marked optional
  # in the matrix, so a missing ab-shared group on a live install
  # shouldn't fail the overall reconcile).
  [[ "$criticality" == "optional" ]] && return 0
  return 1
}

_bridge_iso_reconcile_row_marker_read_path() {
  # kind=marker_read_path — marker dir (parent) and marker file
  # (state/layout-marker.sh). Contract:
  #   - dir: controller-owned, mode 0711 (others +x for traverse only;
  #     not group-readable so an isolated UID outside ab-shared can
  #     reach the marker by full path without listing siblings).
  #   - file: root or controller-owned, mode 0644, NEVER group/world
  #     writable. Validator (lib/bridge-marker-bootstrap.sh) already
  #     refuses anything else.
  local mode="$1" row_name="$2" path="$3" owner_resolved="$4" \
        group_resolved="$5" dir_mode="$6" file_mode="$7" notes="$8"

  if _bridge_iso_reconcile_path_is_protected "$path"; then
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" \
      "marker_read_path" "(protected)" "$notes"
    return 0
  fi

  if [[ -d "$path" ]]; then
    # Treat as dir row with the dir_mode contract.
    _bridge_iso_reconcile_row_dir \
      "$mode" "$row_name" "$path" "$owner_resolved" "$group_resolved" \
      "$dir_mode" "0" "required" "$notes"
    return $?
  fi
  if [[ -f "$path" ]]; then
    # File contract: chmod file_mode + chown owner:group. Refuse to
    # mutate if g+w or o+w is currently set (mode validator would also
    # refuse, but fail loud here too rather than silently fixing).
    local actual_mode actual_og
    actual_mode="$(_bridge_iso_reconcile_stat_mode "$path")"
    actual_og="$(_bridge_iso_reconcile_stat_owner_group "$path")"
    local actual_int=$(( 8#${actual_mode:-0} ))
    if (( actual_int & 022 )); then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_FAILED" "$path" \
        "$owner_resolved:$group_resolved $file_mode" \
        "$actual_og $actual_mode (group/world writable — refuse)" \
        "$notes (marker validator rejects; remove and re-init)"
      return 1
    fi
    local expected_mode_norm actual_mode_norm
    expected_mode_norm="$(_bridge_iso_reconcile_normalize_mode "$file_mode")"
    actual_mode_norm="$(_bridge_iso_reconcile_normalize_mode "$actual_mode")"
    local expected_og="$owner_resolved:$group_resolved"
    if [[ "$expected_mode_norm" == "$actual_mode_norm" \
          && "$expected_og" == "$actual_og" ]]; then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_OK" "$path" \
        "$expected_og $expected_mode_norm" \
        "$actual_og $actual_mode_norm" "$notes"
      return 0
    fi
    if [[ "$mode" == "check" ]]; then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_MISMATCH" "$path" \
        "$expected_og $expected_mode_norm" \
        "$actual_og $actual_mode_norm" "$notes"
      return 1
    fi
    local rc=0
    if [[ "$expected_og" != "$actual_og" ]] \
        && ! _bridge_isolation_v2_run_root_or_sudo \
              chown "$expected_og" "$path"; then
      rc=1
    fi
    if (( rc == 0 )) && [[ "$expected_mode_norm" != "$actual_mode_norm" ]] \
        && ! _bridge_isolation_v2_run_root_or_sudo chmod "$file_mode" "$path"; then
      rc=1
    fi
    if (( rc == 0 )); then
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_CHANGED" "$path" \
        "$expected_og $expected_mode_norm" \
        "$actual_og $actual_mode_norm" "$notes"
      return 0
    fi
    _bridge_iso_reconcile_emit_row "$row_name" \
      "$BRIDGE_ISO_RECONCILE_STATUS_FAILED" "$path" \
      "$expected_og $expected_mode_norm" \
      "$actual_og $actual_mode_norm" "$notes"
    return 1
  fi

  # Path absent — marker file may legitimately not exist yet
  # (fresh-install-candidate). Skip without flagging.
  _bridge_iso_reconcile_emit_row "$row_name" \
    "$BRIDGE_ISO_RECONCILE_STATUS_SKIPPED" "$path" \
    "marker_read_path" "(absent)" "$notes"
  return 0
}

# ---------------------------------------------------------------------------
# Matrix generation
# ---------------------------------------------------------------------------

bridge_isolation_v2_install_tree_matrix_rows() {
  # Emit one row per line for the install-scope contract. Caller can
  # filter by scope on the consumer side.
  # Order matters: install rows first, then per-agent rows. Each agent
  # invocation re-emits the install rows so a single `--agent X
  # --reason agent-create` call covers both ancestor + leaf normalization.
  local agent="${1:-}"
  local data_root="${BRIDGE_HOME:-}"
  [[ -n "$data_root" ]] || { bridge_warn "install_tree_matrix_rows: BRIDGE_HOME unset"; return 1; }
  local shared_grp="${BRIDGE_SHARED_GROUP:-ab-shared}"
  local marker_dir="${BRIDGE_LAYOUT_MARKER_DIR:-$data_root/state}"
  local marker_file="$marker_dir/layout-marker.sh"

  # ----- HOME traverse row (only if BRIDGE_HOME is under $HOME) -----
  # Linux defaults $HOME to mode 0750; isolated UIDs need POSIX
  # traverse (o+x) to reach BRIDGE_HOME. Conservative grant — no read,
  # no list, just traverse.
  local home_parent
  home_parent="$(dirname "$data_root")"
  if [[ -n "${HOME:-}" && "$home_parent" == "$HOME" && -d "$home_parent" ]]; then
    # NOTE: owner field for path_traverse is informational only — the
    # row dispatcher uses chmod direct-or-sudo and the operator owns
    # $HOME so direct chmod succeeds without sudo.
    printf '%s\n' \
      "path-traverse-home|host|$home_parent|path_traverse|controller|controller_group|001|-|0|0|inherit|direct|required|isolated UIDs need o+x to traverse \$HOME → \$BRIDGE_HOME"
  fi

  # ----- BRIDGE_HOME (data root) chgrp ab-shared + g+x -----
  printf '%s\n' \
    "data-root|install|$data_root|dir|controller|ab-shared|0710|-|0|0|inherit|direct|required|\$BRIDGE_HOME chgrp ab-shared + group traverse (iso UIDs in ab-shared can stat, not list)"

  # ----- static install subdirs — readable code + scripts -----
  local sub
  for sub in lib scripts hooks runtime shared; do
    if [[ -d "$data_root/$sub" ]]; then
      printf '%s\n' \
        "${sub}-dir|install|$data_root/$sub|dir_recursive|controller|ab-shared|-|-|0|1|inherit|direct|required|$sub/ chgrp -R ab-shared + chmod -R g+rX (read + dir traverse, preserves exec bit on files)"
    fi
  done

  # ----- root-level entrypoint files (file_glob) -----
  printf '%s\n' \
    "root-entrypoints|install|$data_root/*|file_glob|controller|ab-shared|-|0644|0|0|preserve|direct|required|root entrypoint scripts (agent-bridge, agb, bridge-*.sh, bridge-*.py) g+r (excludes agent-roster*, handoff.local* via protected guard)"

  # ----- marker dir + file -----
  printf '%s\n' \
    "marker-path-dir|install|$marker_dir|marker_read_path|controller|ab-shared|0711|-|0|0|inherit|direct|required|marker dir mode 0711 — others +x for traverse, no listing; group ab-shared for readability"
  printf '%s\n' \
    "marker-path-file|install|$marker_file|marker_read_path|root|ab-shared|-|0644|0|0|inherit|direct|required|marker file 0644 root:ab-shared — validator accepts; world-read is non-secret content (LAYOUT + DATA_ROOT)"

  # ----- per-agent rows (only when --agent is provided) -----
  if [[ -n "$agent" ]]; then
    local state_root="${BRIDGE_STATE_DIR:-$data_root/state}"
    local state_agents_root="$state_root/agents"
    local state_agent_dir="$state_agents_root/$agent"
    # state-agent-leaf creation lands here too so a freshly created
    # isolated agent has its per-agent state dir present before the
    # daemon's first marker write. The matrix in
    # `bridge_isolation_v2_matrix_rows_for_agent` (lib/bridge-isolation-v2.sh)
    # is the SSOT for the leaf's ownership/mode contract; this row
    # only guarantees existence. apply mode does the mkdir, then the
    # per-agent matrix's `state-agent-dir` row sets the leaf mode
    # later in prepare flow (we don't replicate the ab-agent-<X>
    # contract here to keep one source of truth).
    printf '%s\n' \
      "agent-state-leaf|per-agent|$state_agent_dir|state_scaffold|controller|ab-shared|0710|-|0|0|inherit|direct|optional|state/agents/$agent dir scaffold (per-agent matrix owns final mode)"

    # ----- credential grant for this agent's iso UID context -----
    # Routed through the existing credential_grant helper which knows
    # how to find ~/.claude/.credentials.json and apply the ab-shared
    # group-mode contract. opt-in via BRIDGE_ENABLE_CONTROLLER_CREDENTIAL_ACL=1
    # — the row stays in the matrix unconditionally so verify reports
    # drift even when opt-out, but check returns ok on a missing file
    # (helper short-circuits on absent credential).
    local ctrl_home cred_path=""
    if command -v bridge_isolation_v2_controller_user >/dev/null 2>&1; then
      local ctrl_user
      ctrl_user="$(bridge_isolation_v2_controller_user 2>/dev/null || true)"
      if [[ -n "$ctrl_user" ]]; then
        ctrl_home="$(getent passwd "$ctrl_user" 2>/dev/null | cut -d: -f6)"
        [[ -z "$ctrl_home" ]] && ctrl_home="${HOME:-}"
        [[ -n "$ctrl_home" ]] && cred_path="$ctrl_home/.claude/.credentials.json"
      fi
    fi
    # Even when the file is absent, emit the row so the audit trail
    # shows operators that this is a known surface (helper returns ok
    # on missing file).
    if [[ -n "$cred_path" ]]; then
      printf '%s\n' \
        "agent-credentials-grant|per-agent|$cred_path|credential_grant|controller|ab-shared|-|0640|0|0|preserve|helper:bridge_isolation_v2_apply_controller_credentials_read_grant|optional|controller ~/.claude/.credentials.json group-mode read grant for agent $agent (ab-shared)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Public entrypoint
# ---------------------------------------------------------------------------

bridge_isolation_v2_apply_install_tree_matrix() {
  # Walk the install-tree matrix in `--mode check` or `--mode apply`.
  # Returns 0 when every required row is canonical (check) or applied
  # cleanly (apply); non-zero on any required mismatch or apply failure.
  # Optional rows degrade but do not flip the exit code.
  #
  # Output:
  #   stdout — one per-row line (pipe-separated): row_name|status|path|
  #            expected|actual|notes  (consumed by --json wrapper)
  #   stderr — human-readable summary line per row + final summary
  #
  # Args (any order):
  #   --mode check|apply             default: check
  #   --agent <name>                  process the named agent's rows
  #   --all-agents                    process every roster agent's rows
  #   --reason install|upgrade|agent-create|manual  diagnostic only
  #   --json                          re-emit stdout as JSON document
  local mode="check"
  local agent=""
  local all_agents=0
  local reason="manual"
  local emit_json=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        mode="${2:-check}"; shift 2 ;;
      --agent)
        agent="${2:-}"; shift 2 ;;
      --all-agents)
        all_agents=1; shift ;;
      --reason)
        reason="${2:-manual}"; shift 2 ;;
      --json)
        emit_json=1; shift ;;
      -h|--help)
        cat <<'EOF' >&2
Usage: bridge_isolation_v2_apply_install_tree_matrix --mode check|apply
       [--agent <name>|--all-agents] [--reason install|upgrade|agent-create|manual]
       [--json]

Walks the declarative install-tree matrix for the v2 layout.
  check  — read-only; emit drift report, exit non-zero on required mismatch.
  apply  — mutate filesystem state to reach canonical; idempotent.
EOF
        return 0
        ;;
      *)
        bridge_warn "apply_install_tree_matrix: unknown flag: $1"
        return 2 ;;
    esac
  done

  case "$mode" in
    check|apply) ;;
    *) bridge_warn "apply_install_tree_matrix: --mode must be check|apply (got: $mode)"; return 2 ;;
  esac

  # Platform discriminator gate (S3): no-op success on non-Linux. The
  # matrix's chmod/chgrp/setgid rows have no security model off Linux
  # and the ab-* groups don't exist there.
  if command -v bridge_isolation_v2_enforce >/dev/null 2>&1; then
    bridge_isolation_v2_enforce || {
      _bridge_iso_reconcile_log "skip: discriminator declined (non-Linux or BRIDGE_ISOLATION_REQUIRED=no)"
      return 0
    }
  fi

  _bridge_iso_reconcile_log "begin mode=$mode reason=$reason agent=${agent:-<install-only>} all_agents=$all_agents"

  # Capture rows per agent. When --all-agents, walk the eligible
  # isolated roster (re-use the v2-reapply helper that the
  # per-agent grant matrix uses for the same purpose).
  local -a target_agents=()
  if (( all_agents == 1 )); then
    if command -v bridge_isolation_v2_reapply_eligible_agents >/dev/null 2>&1; then
      while IFS= read -r _eligible_agent; do
        [[ -n "$_eligible_agent" ]] || continue
        target_agents+=("$_eligible_agent")
      done < <(bridge_isolation_v2_reapply_eligible_agents 2>/dev/null || true)
    fi
    if (( ${#target_agents[@]} == 0 )); then
      # No isolated agents — run the install-scope rows once with an
      # empty agent so callers always see the install layer asserted.
      target_agents=("")
    fi
  else
    target_agents=("$agent")
  fi

  local overall_rc=0
  local raw_rows_tmp
  raw_rows_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-iso-reconcile.XXXXXX")"
  local _cleanup_tmp="$raw_rows_tmp"
  # shellcheck disable=SC2064  # capture tmp path at trap-set time
  trap "rm -f '$_cleanup_tmp' 2>/dev/null" RETURN

  local idx
  for idx in "${!target_agents[@]}"; do
    local this_agent="${target_agents[$idx]}"
    local row
    while IFS= read -r row || [[ -n "$row" ]]; do
      [[ -n "$row" ]] || continue
      _bridge_iso_reconcile_process_one_row "$mode" "$this_agent" "$row" >>"$raw_rows_tmp" || overall_rc=1
    done < <(bridge_isolation_v2_install_tree_matrix_rows "$this_agent")
  done

  if (( emit_json == 1 )); then
    _bridge_iso_reconcile_emit_json "$mode" "$reason" "$raw_rows_tmp" "$overall_rc"
  else
    # Already wrote per-row pipe lines to raw_rows_tmp; replay to stdout.
    cat "$raw_rows_tmp"
  fi

  _bridge_iso_reconcile_log "end mode=$mode reason=$reason overall_rc=$overall_rc"
  return "$overall_rc"
}

_bridge_iso_reconcile_process_one_row() {
  # Parse one row, resolve tokens, dispatch by kind. Returns 0 on
  # success/clean-drift-on-optional; non-zero on required failure.
  local mode="$1" agent="$2" row="$3"
  local row_name scope path_expr kind owner group dir_mode file_mode \
        setgid recursive children_policy mechanism criticality notes
  IFS='|' read -r row_name scope path_expr kind owner group \
                  dir_mode file_mode setgid recursive children_policy \
                  mechanism criticality notes <<<"$row"

  local owner_resolved group_resolved
  owner_resolved="$(_bridge_iso_reconcile_resolve_owner_token "$owner")"
  group_resolved="$(_bridge_iso_reconcile_resolve_group_token "$group")"

  case "$kind" in
    path_traverse)
      _bridge_iso_reconcile_row_path_traverse \
        "$mode" "$row_name" "$path_expr" "$owner_resolved" \
        "$group_resolved" "$dir_mode" "$notes"
      ;;
    dir)
      _bridge_iso_reconcile_row_dir \
        "$mode" "$row_name" "$path_expr" "$owner_resolved" \
        "$group_resolved" "$dir_mode" "$setgid" "$criticality" "$notes"
      ;;
    dir_recursive)
      _bridge_iso_reconcile_row_dir_recursive \
        "$mode" "$row_name" "$path_expr" "$group_resolved" \
        "$children_policy" "$criticality" "$notes"
      ;;
    file_glob)
      _bridge_iso_reconcile_row_file_glob \
        "$mode" "$row_name" "$path_expr" "$group_resolved" \
        "$criticality" "$notes"
      ;;
    state_scaffold)
      _bridge_iso_reconcile_row_state_scaffold \
        "$mode" "$row_name" "$path_expr" "$owner_resolved" \
        "$group_resolved" "$dir_mode" "$notes"
      ;;
    credential_grant)
      _bridge_iso_reconcile_row_credential_grant \
        "$mode" "$row_name" "$path_expr" "$agent" "$file_mode" \
        "$criticality" "$notes"
      ;;
    marker_read_path)
      _bridge_iso_reconcile_row_marker_read_path \
        "$mode" "$row_name" "$path_expr" "$owner_resolved" \
        "$group_resolved" "$dir_mode" "$file_mode" "$notes"
      ;;
    *)
      bridge_warn "process_one_row: unknown kind '$kind' for row '$row_name'"
      _bridge_iso_reconcile_emit_row "$row_name" \
        "$BRIDGE_ISO_RECONCILE_STATUS_FAILED" "$path_expr" \
        "kind=$kind" "(unknown)" "$notes"
      return 1
      ;;
  esac
}

_bridge_iso_reconcile_emit_json() {
  # Re-emit the captured raw rows as a JSON document on stdout. The
  # input file has pipe-separated lines: row|status|path|expected|actual|notes.
  local mode="$1" reason="$2" raw_path="$3" overall_rc="$4"
  if ! command -v python3 >/dev/null 2>&1; then
    bridge_warn "apply_install_tree_matrix: --json requires python3"
    cat "$raw_path"
    return 0
  fi
  python3 - "$mode" "$reason" "$raw_path" "$overall_rc" <<'PY'
import json, sys
mode = sys.argv[1]
reason = sys.argv[2]
raw_path = sys.argv[3]
overall_rc = int(sys.argv[4])
rows = []
try:
    with open(raw_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("|", 5)
            if len(parts) < 6:
                continue
            row_name, status, path, expected, actual, notes = parts
            rows.append({
                "row": row_name,
                "status": status,
                "path": path,
                "expected": expected,
                "actual": actual,
                "notes": notes,
            })
except OSError as exc:
    print(json.dumps({"error": f"read raw rows failed: {exc}"}))
    sys.exit(2)
print(json.dumps({
    "mode": mode,
    "reason": reason,
    "exit_status": "ok" if overall_rc == 0 else "drift",
    "rows": rows,
}, ensure_ascii=False, indent=2))
PY
}

# ---------------------------------------------------------------------------
# End of module
# ---------------------------------------------------------------------------
