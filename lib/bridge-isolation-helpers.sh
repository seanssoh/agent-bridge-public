#!/usr/bin/env bash
# bridge-isolation-helpers.sh — small probes for running a snippet as the
# isolated UID of a linux-user-isolated agent via the existing sudoers
# allowlist (`bash` + `tmux` only — see bridge-migration.sh:773).
#
# Issue #832: channel-health probes need a way to read a dotenv file that the
# controller cannot `[[ -r ]]` but the agent's isolated UID can. Without this,
# the daemon collapses a controller-blind dotenv into a "miss" and fires a
# false channel_health_miss audit row.
#
# These helpers depend only on already-loaded helpers from `bridge-agents.sh`
# (sourced earlier in bridge-lib.sh): `bridge_agent_os_user`,
# `bridge_agent_linux_user_isolation_effective`, and `BRIDGE_BASH_BIN`. They
# do NOT source bridge-lib.sh inside the isolated UID — the inline script
# passed to `sudo -n -u <user> bash -c` is self-contained.

# bridge_isolation_can_sudo_to_agent <agent>
#
# Returns:
#   0 — agent is in linux-user isolation AND passwordless sudo to its os_user
#       succeeds.
#   1 — agent is not in linux-user isolation (caller should run directly as
#       the controller).
#   2 — agent IS isolated but `sudo -n -u <os_user> bash -c true` fails
#       (no passwordless sudoers rule).
#
# Non-fatal: never exits the shell, suppresses stderr unless
# BRIDGE_ISOLATION_HELPERS_DEBUG=1 is set.
bridge_isolation_can_sudo_to_agent() {
  local agent="$1"
  local os_user=""
  local bash_bin="${BRIDGE_BASH_BIN:-bash}"
  local debug="${BRIDGE_ISOLATION_HELPERS_DEBUG:-0}"

  [[ -n "$agent" ]] || return 1

  # Not isolated — caller should run directly.
  if ! bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    return 1
  fi

  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
  [[ -n "$os_user" ]] || return 1

  if ! command -v sudo >/dev/null 2>&1; then
    return 2
  fi

  if [[ "$debug" == "1" ]]; then
    sudo -n -u "$os_user" "$bash_bin" -c 'exit 0' && return 0 || return 2
  fi
  if sudo -n -u "$os_user" "$bash_bin" -c 'exit 0' 2>/dev/null; then
    return 0
  fi
  return 2
}

# bridge_isolation_run_as_agent_user_via_bash <agent> <script> [arg...]
#
# Runs the inline bash script as the agent's isolated UID via:
#   sudo -n -u <os_user> ${BRIDGE_BASH_BIN:-bash} -c "$script" bridge-isolation "$@"
#
# The fixed "bridge-isolation" argument becomes "$0" inside the inline
# script; user-supplied positional args are bound as "$1", "$2", ...
#
# Returns (distinct ranges):
#   0   — agent isolated, sudo OK, script returned 0
#   1   — agent NOT in linux-user isolation (caller should run directly)
#   2   — agent isolated but passwordless sudo unavailable
#   3+  — agent isolated, sudo OK, script returned non-zero. The script's
#         actual exit code is preserved and returned unchanged (so caller
#         can distinguish e.g. 1 = no-keys from 2 = unreadable inside the
#         script's own contract).
#
# stdout: the script's stdout, unmodified.
# stderr: suppressed unless BRIDGE_ISOLATION_HELPERS_DEBUG=1.
#
# Implementation note (#832): does NOT source bridge-lib.sh inside the
# isolated UID's bash invocation. The script must be self-contained.
bridge_isolation_run_as_agent_user_via_bash() {
  local agent="$1"
  local script="$2"
  shift 2 || true

  local os_user=""
  local bash_bin="${BRIDGE_BASH_BIN:-bash}"
  local debug="${BRIDGE_ISOLATION_HELPERS_DEBUG:-0}"
  local rc=0

  [[ -n "$agent" ]] || return 1
  [[ -n "$script" ]] || return 1

  if ! bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    return 1
  fi

  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
  [[ -n "$os_user" ]] || return 1

  if ! command -v sudo >/dev/null 2>&1; then
    return 2
  fi

  if ! sudo -n -u "$os_user" "$bash_bin" -c 'exit 0' 2>/dev/null; then
    return 2
  fi

  if [[ "$debug" == "1" ]]; then
    sudo -n -u "$os_user" "$bash_bin" -c "$script" bridge-isolation "$@"
    rc=$?
  else
    sudo -n -u "$os_user" "$bash_bin" -c "$script" bridge-isolation "$@" 2>/dev/null
    rc=$?
  fi

  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  # Preserve the script's exit code unchanged for caller's distinct mapping.
  # `sudo` itself returns 1 on policy denial — we already filtered that case
  # above via the pre-flight true-probe, so any non-zero here is the script.
  # Force-shift into the 3+ band so callers can disambiguate from rc=1/2.
  if [[ "$rc" -lt 3 ]]; then
    return $((rc + 2))
  fi
  return "$rc"
}

# bridge_isolation_write_file_as_agent_user_via_bash <agent> <dest_path> [mode]
#
# Symmetric WRITE counterpart to bridge_isolation_run_as_agent_user_via_bash.
# Reads content from stdin and atomically writes it to <dest_path> as the
# agent's isolated UID via:
#   sudo -n -u <os_user> ${BRIDGE_BASH_BIN:-bash} -c "$script" bridge-isolation "$dest_path" "$mode"
#
# The inline script:
#   1. Validates the destination directory exists (does NOT mkdir).
#   2. Tightens umask to 0077 so the in-flight temp file is never world/group
#      visible.
#   3. Creates a temp file inside the destination directory (same-fs, so
#      `mv -f` is atomic).
#   4. Streams stdin into the temp file via `cat -` (NOT a heredoc).
#   5. chmods the temp file to <mode> BEFORE the rename so the published file
#      lands at the correct mode without a race.
#   6. mv -f temp -> dest.
#
# Returns (mirrors the read helper):
#   0   — agent isolated, sudo OK, write succeeded.
#   1   — agent NOT in linux-user isolation (caller should fall back to a
#         direct controller-side write).
#   2   — agent isolated but passwordless sudo unavailable.
#   3+  — agent isolated, sudo OK, script returned non-zero. Matches the
#         read helper's convention: a script rc of 1 or 2 is shifted into
#         the 3+ band (rc+2) so it stays distinct from the pre-flight rc
#         band; a script rc of 3 or higher is returned unchanged. The
#         inline script reserves these exit codes:
#           script rc 5  -> destination directory missing
#           script rc 6  -> mktemp failed (disk full, perm)
#           script rc 7  -> stdin write failed
#           script rc 8  -> chmod failed
#           script rc 9  -> rename (mv -f) failed
#
# Mode defaults to 0600. No flags — positional args only.
#
# stdout: empty on success. stderr: suppressed unless
# BRIDGE_ISOLATION_HELPERS_DEBUG=1.
#
# Implementation notes:
#   - The inline script body is a single-quoted string so $variables inside
#     are NOT expanded by the controller's bash; they expand only inside the
#     sudo'd bash. This matches the read helper's pattern exactly and avoids
#     the bash heredoc_write deadlock class (issue #815 Wave D / footgun #11).
#   - Content is streamed via stdin pipe — callers must use a producer
#     pipeline (e.g. `printf '%s\n' "$content" | bridge_isolation_write_...`)
#     or input redirection from an existing file
#     (`bridge_isolation_write_... < /path/to/source`). NEVER pass content
#     via heredoc / here-string at the call site.
#   - DRY with the read helper: pre-check goes through
#     bridge_isolation_can_sudo_to_agent so both helpers share the
#     isolation+sudo gating contract.
bridge_isolation_write_file_as_agent_user_via_bash() {
  local agent="$1"
  local dest_path="$2"
  local mode="${3:-0600}"

  [[ -n "$agent" ]] || return 1
  [[ -n "$dest_path" ]] || return 1

  local sudo_rc=0
  bridge_isolation_can_sudo_to_agent "$agent" 2>/dev/null || sudo_rc=$?
  case "$sudo_rc" in
    0) ;;
    1) return 1 ;;
    2) return 2 ;;
    *) return 2 ;;
  esac

  local os_user=""
  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
  [[ -n "$os_user" ]] || return 1

  local bash_bin="${BRIDGE_BASH_BIN:-bash}"
  local debug="${BRIDGE_ISOLATION_HELPERS_DEBUG:-0}"

  # Inline write script. Single-quoted so $variables resolve inside the
  # sudo'd bash only. $0 will be the literal 'bridge-isolation' tag,
  # $1 is the destination path, $2 is the mode.
  #
  # `cat -` reads stdin (NOT a heredoc). Do NOT introduce <<<, <<EOF, or
  # any other here-document construct anywhere in this body — that would
  # re-open the Bash 5.3.9 heredoc_write deadlock class (footgun #11).
  local script
  script='
dest_path="$1"
mode="$2"
dest_dir="$(dirname "$dest_path")"
if [[ ! -d "$dest_dir" ]]; then
  exit 5
fi
umask 0077
tmp="$(mktemp "$dest_dir/.$(basename "$dest_path").bridge-write-tmp.XXXXXX")" || exit 6
trap "rm -f \"$tmp\" 2>/dev/null" EXIT INT TERM
if ! cat - >"$tmp"; then
  exit 7
fi
if ! chmod "$mode" "$tmp"; then
  exit 8
fi
if ! mv -f "$tmp" "$dest_path"; then
  exit 9
fi
trap - EXIT INT TERM
exit 0
'

  local rc=0
  if [[ "$debug" == "1" ]]; then
    sudo -n -u "$os_user" "$bash_bin" -c "$script" bridge-isolation "$dest_path" "$mode"
    rc=$?
  else
    sudo -n -u "$os_user" "$bash_bin" -c "$script" bridge-isolation "$dest_path" "$mode" 2>/dev/null
    rc=$?
  fi

  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  # Preserve the script's exit code with a +2 shift so callers can
  # disambiguate from the 0/1/2 pre-flight band (same convention as the
  # read helper above).
  if [[ "$rc" -lt 3 ]]; then
    return $((rc + 2))
  fi
  return "$rc"
}

# =============================================================================
# bridge_iso_run — Unified facade for controller->iso boundary operations
# =============================================================================
#
# The single helper for ALL controller->iso boundary reads, writes, mkdir,
# stat, and root-publish operations. Every new callsite goes through
# `bridge_iso_run` (shell) or `agent-bridge iso-run` (CLI for Python
# callers). The pre-existing low-level helpers
# (`bridge_isolation_run_as_agent_user_via_bash`,
# `bridge_isolation_write_file_as_agent_user_via_bash`) are kept as
# compatibility wrappers and internally delegate here.
#
# Two execution classes:
#
#   1. agent op       - drops to the isolated UID via existing sudoers;
#                       used for read/stat/mkdir/atomic-write/state-marker
#                       /scan-profile of agent-owned runtime files.
#   2. root-publish op - controller-published writes for root-owned
#                       per-agent metadata (`installed_plugins.json`,
#                       `known_marketplaces.json`). Strict path allowlist
#                       + final owner/group/mode enforcement.
#
# Both classes go through this same facade. NO bypass; NO direct
# path-touch on isolated trees from controller code outside this helper.
#
# ## Path allowlist
#
# `--path` (or `--from`, `--to`, `--link`) must resolve under one of:
#   - `bridge_agent_workdir <agent>`
#   - `bridge_agent_default_home <agent>`
#   - `bridge_agent_linux_user_home <os_user-for-agent>` (when isolated)
#   - `bridge_agent_idle_marker_dir <agent>`
#   - operator-supplied extras via `BRIDGE_ISO_RUN_ALLOWLIST_EXTRA`
#     (colon-separated, used by smoke tests and rare overrides)
#
# Unknown roots -> rc 40 (`unsafe path`).
#
# ## Return codes (structured)
#
#    0  - success
#   10  - agent is NOT linux-user isolated; caller passed --legacy-ok
#         to opt-in to the "direct legacy run" return signal
#   20  - sudo unavailable / passwordless sudoers missing
#   30  - path absent (read/stat: file does not exist)
#   31  - semantic missing key (env-has-any-key: file exists, no
#         matching key)
#   32  - unreadable even to the isolated UID (true ACL/mode drift)
#   40  - unsafe path (not under allowlisted per-agent root)
#    2  - op-specific failure (write-side: mktemp / chmod / mv inner
#         errors keep their script exit code; pre-flight arg-parse
#         errors also surface as 2)
#
# ## Footgun #11 (heredoc-stdin deadlock)
#
# The op scripts are single-quoted bash bodies; argv-only positional
# args; stdin via pipe only. NO `<<EOF`, NO `<<'PY'`, NO `<<<`
# here-string, NO `done < <(...)` process-substitution capture anywhere
# in this helper body. See `KNOWN_ISSUES.md` Section 26 and the v0.13.9
# chain.

# _bridge_iso_run_canonicalize <path>
# Echo the canonical absolute form of <path>. <path> MUST exist; on
# resolution failure, echoes empty and returns non-zero.
#
# Portable across Linux (`readlink -f` works) and macOS BSD (`readlink
# -f` exists on Big Sur+; older macOS without it falls through to the
# python3 fallback). All errors are squashed: callers MUST check the
# return code AND verify non-empty stdout before trusting the result.
_bridge_iso_run_canonicalize() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  if [[ ! -e "$p" ]]; then
    return 1
  fi
  local out=""
  if out="$(readlink -f -- "$p" 2>/dev/null)" && [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    out="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null)" \
      && [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  fi
  # Last-resort: cd -P into dirname, append basename. Works for paths
  # whose parent exists and is traversable; fails closed otherwise.
  local d b
  d="$(dirname -- "$p")" || return 1
  b="$(basename -- "$p")" || return 1
  out="$(cd -P -- "$d" 2>/dev/null && printf '%s/%s' "$PWD" "$b")" \
    && [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  return 1
}

# _bridge_iso_run_canonicalize_destination <path>
# Echo the canonical form of <path> when <path> may not exist yet.
# Walks up to the deepest EXISTING ancestor, canonicalizes that, then
# re-appends the tail components literally (which means the tail must
# have already been verified to contain no `..` and no symlinks — the
# caller is responsible for that pre-check via the literal `..` reject
# in `bridge_iso_run_path_under_allowlist`).
#
# Why this is safe: by the time the tail is appended, the deepest
# existing ancestor has been resolved through any symlink chain. The
# tail being non-existent means a symlink cannot already sit on any
# tail component (symlinks are inodes; they exist). So
# `<canonical-existing-ancestor>/<literal-tail>` is the canonical form
# of the requested destination, modulo the `..`/no-symlink invariant
# on the tail which the gate enforces upstream.
#
# Echoes empty on failure (no traversable ancestor reached `/`).
_bridge_iso_run_canonicalize_destination() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  # Already-existing path: canonicalize directly.
  if [[ -e "$p" ]]; then
    _bridge_iso_run_canonicalize "$p"
    return $?
  fi

  # Walk up to the deepest existing ancestor.
  local tail=""
  local cur="$p"
  local prev=""
  while [[ "$cur" != "/" && "$cur" != "." && -n "$cur" ]]; do
    if [[ -e "$cur" ]]; then
      break
    fi
    prev="$cur"
    cur="$(dirname -- "$cur")"
    if [[ -z "$tail" ]]; then
      tail="$(basename -- "$prev")"
    else
      tail="$(basename -- "$prev")/$tail"
    fi
    # Guard against pathological infinite loops (dirname of "/" is "/").
    [[ "$cur" == "$prev" ]] && return 1
  done

  if [[ ! -e "$cur" ]]; then
    return 1
  fi

  local canonical_ancestor=""
  canonical_ancestor="$(_bridge_iso_run_canonicalize "$cur")" || return 1
  [[ -n "$canonical_ancestor" ]] || return 1

  if [[ -z "$tail" ]]; then
    printf '%s' "$canonical_ancestor"
  else
    printf '%s/%s' "${canonical_ancestor%/}" "$tail"
  fi
  return 0
}

# _bridge_iso_run_has_dotdot_segment <path>
# Returns 0 iff <path> contains a literal `..` path segment (between
# slashes, or as the first/last segment). Examples:
#   /a/b/../c   -> 0 (yes)
#   /a/..b/c    -> 1 (no — `..b` is not `..`)
#   ../a/b      -> 0 (yes)
#   /a/b/..     -> 0 (yes)
#   /a..b/c     -> 1 (no)
_bridge_iso_run_has_dotdot_segment() {
  local p="$1"
  local _saved_IFS="$IFS"
  IFS="/"
  # shellcheck disable=SC2086  # word-split on / is intentional
  local seg
  for seg in $p; do
    if [[ "$seg" == ".." ]]; then
      IFS="$_saved_IFS"
      return 0
    fi
  done
  IFS="$_saved_IFS"
  return 1
}

# _bridge_iso_run_collect_canonical_roots <agent>
# Print one canonical allowlist root per line to stdout. Uses the same
# root resolution as the legacy lexical gate but canonicalizes each
# root via `_bridge_iso_run_canonicalize`. Skips roots that fail to
# canonicalize (root does not exist — that's a layout config issue,
# not an escape — the legacy lexical compare would not have matched
# the canonical path anyway).
#
# Output may include duplicate canonical paths when multiple roots
# resolve to the same canonical dir (e.g. legacy + v2 home both point
# at the same symlink target). Callers dedupe via the prefix match
# loop and don't need uniqueness.
_bridge_iso_run_collect_canonical_roots() {
  local agent="$1"
  local raw_root=""
  local canon=""
  local os_user=""

  _print_if_resolves() {
    local r="$1"
    [[ -n "$r" ]] || return 0
    r="${r%/}"
    canon="$(_bridge_iso_run_canonicalize "$r" 2>/dev/null || true)"
    if [[ -n "$canon" ]]; then
      printf '%s\n' "${canon%/}"
    fi
  }

  if declare -F bridge_agent_workdir >/dev/null 2>&1; then
    raw_root="$(bridge_agent_workdir "$agent" 2>/dev/null || printf '')"
    _print_if_resolves "$raw_root"
  fi

  if declare -F bridge_agent_default_home >/dev/null 2>&1; then
    raw_root="$(bridge_agent_default_home "$agent" 2>/dev/null || printf '')"
    _print_if_resolves "$raw_root"
  fi

  if declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    if declare -F bridge_agent_os_user >/dev/null 2>&1 \
        && declare -F bridge_agent_linux_user_home >/dev/null 2>&1; then
      os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
      if [[ -n "$os_user" ]]; then
        raw_root="$(bridge_agent_linux_user_home "$os_user" 2>/dev/null || printf '')"
        _print_if_resolves "$raw_root"
      fi
    fi
  fi

  if declare -F bridge_agent_idle_marker_dir >/dev/null 2>&1; then
    raw_root="$(bridge_agent_idle_marker_dir "$agent" 2>/dev/null || printf '')"
    _print_if_resolves "$raw_root"
  fi

  local extra="${BRIDGE_ISO_RUN_ALLOWLIST_EXTRA:-}"
  if [[ -n "$extra" ]]; then
    local _saved_IFS="$IFS"
    IFS=":"
    local r
    for r in $extra; do
      [[ -n "$r" ]] || continue
      _print_if_resolves "$r"
    done
    IFS="$_saved_IFS"
  fi

  unset -f _print_if_resolves 2>/dev/null || true
}

# bridge_iso_run_path_under_allowlist <agent> <path>
#
# Returns 0 if <path> is under any allowlisted per-agent root, 1
# otherwise.
#
# R2 hardening (codex r1 BLOCKING): the gate is no longer lexical-only.
# Steps:
#   1. Reject any literal `..` path segment in the raw <path>. This
#      catches `<allowed-root>/../outside/...` shapes before any
#      canonicalization step that would normalize them away. The
#      filesystem itself would resolve them, but for the gate to be
#      meaningful we MUST refuse the request rather than transparently
#      resolving the escape — operators relying on the `..` reject as
#      a clear signal that their input is bad.
#   2. Collect canonical (symlink-resolved) forms of the allowlist
#      roots. A root that does not exist on disk is silently dropped
#      (would never match a real canonical path anyway).
#   3. Canonicalize <path>. For not-yet-created destinations the
#      deepest existing ancestor is canonicalized and the tail
#      re-appended literally (tail is already `..`-free by step 1; a
#      symlink cannot sit on a non-existent tail component by
#      definition).
#   4. Compare canonical <path> against each canonical root via
#      lexical-prefix on already-canonicalized strings. A symlink
#      ancestor (e.g. `<allowed-root>/link -> /etc`) shows up as a
#      canonical mismatch and is rejected.
#
# Return:
#   0 — path canonicalizes under one of the canonical allowlist roots
#   1 — escape detected (`..` segment, symlink ancestor, no canonical
#       root match, canonicalization failure)
bridge_iso_run_path_under_allowlist() {
  local agent="$1"
  local path="$2"
  [[ -n "$agent" && -n "$path" ]] || return 1

  # Reject literal `..` segments BEFORE canonicalization. `..` would
  # normalize away under `readlink -f`, but we want to refuse the
  # request rather than silently resolve an escape.
  if _bridge_iso_run_has_dotdot_segment "$path"; then
    return 1
  fi

  # Strip trailing slash to keep the canonical-prefix match consistent
  # against root entries which we also strip.
  path="${path%/}"

  # Canonicalize the path (handling not-yet-created destinations by
  # walking up to the deepest existing ancestor).
  local canon_path=""
  canon_path="$(_bridge_iso_run_canonicalize_destination "$path" 2>/dev/null || true)"
  if [[ -z "$canon_path" ]]; then
    # Could not canonicalize — refuse rather than fall through. This
    # is the fail-closed branch for paths whose entire ancestor chain
    # is missing (rare but possible during agent bootstrap).
    return 1
  fi
  canon_path="${canon_path%/}"

  # Collect canonical allowlist roots and prefix-match against them.
  local canon_roots_tmp
  canon_roots_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-iso-run-roots.XXXXXX")" || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$canon_roots_tmp' 2>/dev/null" RETURN

  _bridge_iso_run_collect_canonical_roots "$agent" >"$canon_roots_tmp" 2>/dev/null || true

  local canon_root=""
  local matched=0
  while IFS= read -r canon_root; do
    [[ -n "$canon_root" ]] || continue
    if [[ "$canon_path" == "$canon_root" || "$canon_path" == "$canon_root"/* ]]; then
      matched=1
      break
    fi
  done <"$canon_roots_tmp"

  rm -f "$canon_roots_tmp" 2>/dev/null
  trap - RETURN
  [[ "$matched" -eq 1 ]] && return 0
  return 1
}

# _bridge_iso_run_agent_script <agent> <inline-script> [arg...]
# Run an isolated-UID inline script via the existing run helper. Wraps
# the rc band so callers can map through _bridge_iso_run_unshift_rc.
_bridge_iso_run_agent_script() {
  local agent="$1"
  local script="$2"
  shift 2 || true
  if declare -F bridge_isolation_run_as_agent_user_via_bash >/dev/null 2>&1; then
    bridge_isolation_run_as_agent_user_via_bash "$agent" "$script" "$@"
    return $?
  fi
  return 20
}

# _bridge_iso_run_unshift_rc - translate the existing read-helper's
# "+2 band shift" rc back into the structured rc band:
#   read-helper rc 0   -> 0  (success)
#   read-helper rc 1   -> 10 (not isolated)
#   read-helper rc 2   -> 20 (sudo unavailable)
#   read-helper rc 3+  -> passthrough (script's own exit codes:
#                                       30=absent / 31=miss / 32=unread / etc)
_bridge_iso_run_unshift_rc() {
  local in_rc="$1"
  case "$in_rc" in
    0) return 0 ;;
    1) return 10 ;;
    2) return 20 ;;
    *) return "$in_rc" ;;
  esac
}

# ---- op scripts ------------------------------------------------------------
#
# Single-quoted op scripts. argv conventions:
#   $0 = literal "bridge-isolation" (ps display, set by helper)
#   $1..$N = positional args per op
#
# NO heredoc-stdin, NO here-string, NO command-substitution-of-heredoc
# anywhere in these bodies. Pipe via `cat -` from controller-supplied
# stdin where needed. Footgun #11 invariant.

# OP_STAT - argv: <path> <test_kind>
#   test_kind in {exists,file,dir,symlink,readable}
#   exit 0 = test passed; 30 = file absent; 32 = unreadable to iso UID
_BRIDGE_ISO_RUN_OP_STAT='
path="$1"
test_kind="$2"
case "$test_kind" in
  exists)
    [[ -e "$path" ]] && exit 0
    exit 30
    ;;
  file)
    [[ -f "$path" ]] && exit 0
    exit 30
    ;;
  dir)
    [[ -d "$path" ]] && exit 0
    exit 30
    ;;
  symlink)
    [[ -L "$path" ]] && exit 0
    exit 30
    ;;
  readable)
    if [[ -r "$path" ]]; then
      exit 0
    fi
    if [[ -e "$path" ]]; then
      exit 32
    fi
    exit 30
    ;;
  *)
    exit 2
    ;;
esac
'

# OP_READ_FILE - argv: <path>
#   exit 0 + stdout = file contents; 30 = absent; 32 = unreadable
_BRIDGE_ISO_RUN_OP_READ_FILE='
path="$1"
[[ -e "$path" ]] || exit 30
[[ -r "$path" ]] || exit 32
cat -- "$path"
'

# OP_ENV_HAS_ANY_KEY - argv: <path> <key1> [key2 ...]
#   exit 0 = at least one matching non-empty key; 31 = file readable but
#   no matching key; 30 = absent; 32 = unreadable
_BRIDGE_ISO_RUN_OP_ENV_HAS_ANY_KEY='
path="$1"
shift
[[ -e "$path" ]] || exit 30
[[ -r "$path" ]] || exit 32
if [[ $# -eq 0 ]]; then
  if grep -Eq "^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=[^[:space:]#]" "$path"; then
    exit 0
  fi
  exit 31
fi
for k in "$@"; do
  if grep -Eq "^[[:space:]]*(export[[:space:]]+)?${k}=[^[:space:]#].*" "$path"; then
    exit 0
  fi
done
exit 31
'

# OP_READ_ENV_KEY - argv: <path> <key>
#   exit 0 + stdout = value (first match, stripped); 31 = no key;
#   30 = absent; 32 = unreadable
_BRIDGE_ISO_RUN_OP_READ_ENV_KEY='
path="$1"
key="$2"
[[ -e "$path" ]] || exit 30
[[ -r "$path" ]] || exit 32
line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$path" 2>/dev/null | head -1 || true)"
[[ -n "$line" ]] || exit 31
line="${line#"${line%%[![:space:]]*}"}"
line="${line#export }"
line="${line#"${line%%[![:space:]]*}"}"
line="${line#${key}=}"
line="${line%%#*}"
# Trim trailing whitespace (read-helper trimming convention).
line="${line%"${line##*[![:space:]]}"}"
printf "%s" "$line"
'

# OP_MKDIR_P - argv: <path> [mode]
#   mode optional ("" = no chmod); exit 0 on success; 2 = mkdir failed;
#   8 = chmod failed
_BRIDGE_ISO_RUN_OP_MKDIR_P='
path="$1"
mode="$2"
mkdir -p -- "$path" || exit 2
if [[ -n "$mode" ]]; then
  chmod "$mode" "$path" || exit 8
fi
exit 0
'

# OP_RENAME - argv: <from> <to>
#   exit 0; 30 = from absent; 9 = mv failed
_BRIDGE_ISO_RUN_OP_RENAME='
from_path="$1"
to_path="$2"
[[ -e "$from_path" ]] || exit 30
mv -f -- "$from_path" "$to_path" || exit 9
exit 0
'

# ---- dispatcher ------------------------------------------------------------

# bridge_iso_run - public entry point.
# Argv flag style (see header comment for op list).
bridge_iso_run() {
  local agent=""
  local op=""
  local path=""
  local from_path=""
  local to_path=""
  local link_path=""
  local target_path=""
  local mode=""
  local marker_name=""
  local workdir_path=""
  local format=""
  local test_kind=""
  local group_agent=""
  local read_stdin=0
  local legacy_ok=0
  local keys=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) agent="$2"; shift 2 ;;
      --op) op="$2"; shift 2 ;;
      --path) path="$2"; shift 2 ;;
      --from) from_path="$2"; shift 2 ;;
      --to) to_path="$2"; shift 2 ;;
      --link) link_path="$2"; shift 2 ;;
      --target) target_path="$2"; shift 2 ;;
      --mode) mode="$2"; shift 2 ;;
      --name) marker_name="$2"; shift 2 ;;
      --workdir) workdir_path="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      --test) test_kind="$2"; shift 2 ;;
      --key) keys+=("$2"); shift 2 ;;
      --group-agent) group_agent="$2"; shift 2 ;;
      --stdin) read_stdin=1; shift ;;
      --legacy-ok) legacy_ok=1; shift ;;
      --) shift; break ;;
      *)
        printf 'bridge_iso_run: unknown arg %q\n' "$1" >&2
        return 2
        ;;
    esac
  done

  [[ -n "$agent" ]] || { printf 'bridge_iso_run: --agent required\n' >&2; return 2; }
  [[ -n "$op" ]] || { printf 'bridge_iso_run: --op required\n' >&2; return 2; }

  # ---- path allowlist gate ----
  local primary_path=""
  case "$op" in
    publish-root-symlink) primary_path="$link_path" ;;
    rename)
      primary_path="$to_path"
      if [[ -n "$from_path" ]]; then
        bridge_iso_run_path_under_allowlist "$agent" "$from_path" || return 40
      fi
      ;;
    scan-profile)        primary_path="$workdir_path" ;;
    state-marker-write)
      # The marker resolves under the agent's idle-marker dir; no
      # external --path, so the allowlist check happens at resolve
      # time inside _bridge_iso_run_state_marker_write.
      primary_path=""
      ;;
    *)                   primary_path="$path" ;;
  esac
  if [[ -n "$primary_path" ]]; then
    bridge_iso_run_path_under_allowlist "$agent" "$primary_path" || return 40
  fi

  # ---- isolation gate ----
  local isolated=0
  if declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    isolated=1
  fi

  if [[ "$isolated" -eq 0 ]]; then
    if [[ "$legacy_ok" -eq 1 ]]; then
      return 10
    fi
    _bridge_iso_run_op_direct \
      "$op" "$path" "$from_path" "$to_path" "$link_path" "$target_path" \
      "$mode" "$marker_name" "$workdir_path" "$format" "$test_kind" \
      "$group_agent" "$read_stdin" "${keys[@]+"${keys[@]}"}"
    return $?
  fi

  _bridge_iso_run_op_isolated \
    "$agent" "$op" "$path" "$from_path" "$to_path" "$link_path" "$target_path" \
    "$mode" "$marker_name" "$workdir_path" "$format" "$test_kind" \
    "$group_agent" "$read_stdin" "${keys[@]+"${keys[@]}"}"
  return $?
}

# _bridge_iso_run_op_isolated - dispatches the per-op script under sudo.
_bridge_iso_run_op_isolated() {
  local agent="$1"
  local op="$2"
  local path="$3"
  local from_path="$4"
  local to_path="$5"
  local link_path="$6"
  local target_path="$7"
  local mode="$8"
  local marker_name="$9"
  local workdir_path="${10}"
  local format="${11}"
  local test_kind="${12}"
  local group_agent="${13}"
  local read_stdin="${14}"
  shift 14 || true
  local keys=("$@")
  # Suppress unused-warning shellcheck where ops don't consume a var.
  : "${read_stdin}${link_path}${target_path}"

  local rc=0
  case "$op" in
    stat)
      [[ -n "$path" && -n "$test_kind" ]] \
        || { printf 'bridge_iso_run stat: --path and --test required\n' >&2; return 2; }
      _bridge_iso_run_agent_script "$agent" "$_BRIDGE_ISO_RUN_OP_STAT" "$path" "$test_kind"
      rc=$?
      _bridge_iso_run_unshift_rc "$rc"
      return $?
      ;;
    read-file|read-json)
      [[ -n "$path" ]] \
        || { printf 'bridge_iso_run read-*: --path required\n' >&2; return 2; }
      _bridge_iso_run_agent_script "$agent" "$_BRIDGE_ISO_RUN_OP_READ_FILE" "$path"
      rc=$?
      _bridge_iso_run_unshift_rc "$rc"
      return $?
      ;;
    env-has-any-key)
      [[ -n "$path" ]] \
        || { printf 'bridge_iso_run env-has-any-key: --path required\n' >&2; return 2; }
      _bridge_iso_run_agent_script "$agent" "$_BRIDGE_ISO_RUN_OP_ENV_HAS_ANY_KEY" "$path" "${keys[@]+"${keys[@]}"}"
      rc=$?
      _bridge_iso_run_unshift_rc "$rc"
      return $?
      ;;
    read-env-key)
      [[ -n "$path" && ${#keys[@]} -ge 1 ]] \
        || { printf 'bridge_iso_run read-env-key: --path and --key required\n' >&2; return 2; }
      _bridge_iso_run_agent_script "$agent" "$_BRIDGE_ISO_RUN_OP_READ_ENV_KEY" "$path" "${keys[0]}"
      rc=$?
      _bridge_iso_run_unshift_rc "$rc"
      return $?
      ;;
    mkdir-p)
      [[ -n "$path" ]] \
        || { printf 'bridge_iso_run mkdir-p: --path required\n' >&2; return 2; }
      _bridge_iso_run_agent_script "$agent" "$_BRIDGE_ISO_RUN_OP_MKDIR_P" "$path" "$mode"
      rc=$?
      _bridge_iso_run_unshift_rc "$rc"
      return $?
      ;;
    atomic-write)
      [[ -n "$path" && -n "$mode" ]] \
        || { printf 'bridge_iso_run atomic-write: --path and --mode required\n' >&2; return 2; }
      _bridge_iso_run_write_via_helper "$agent" "$path" "$mode"
      return $?
      ;;
    rename)
      [[ -n "$from_path" && -n "$to_path" ]] \
        || { printf 'bridge_iso_run rename: --from and --to required\n' >&2; return 2; }
      _bridge_iso_run_agent_script "$agent" "$_BRIDGE_ISO_RUN_OP_RENAME" "$from_path" "$to_path"
      rc=$?
      _bridge_iso_run_unshift_rc "$rc"
      return $?
      ;;
    state-marker-write)
      [[ -n "$marker_name" ]] \
        || { printf 'bridge_iso_run state-marker-write: --name required\n' >&2; return 2; }
      _bridge_iso_run_state_marker_write "$agent" "$marker_name"
      return $?
      ;;
    scan-profile)
      [[ -n "$workdir_path" ]] \
        || { printf 'bridge_iso_run scan-profile: --workdir required\n' >&2; return 2; }
      _bridge_iso_run_scan_profile "$agent" "$workdir_path" "${format:-json}"
      return $?
      ;;
    publish-root-file)
      [[ -n "$path" && -n "$mode" && -n "$group_agent" ]] \
        || { printf 'bridge_iso_run publish-root-file: --path, --mode, --group-agent required\n' >&2; return 2; }
      _bridge_iso_run_publish_root_file "$agent" "$path" "$mode" "$group_agent"
      return $?
      ;;
    publish-root-symlink)
      [[ -n "$link_path" && -n "$target_path" && -n "$group_agent" ]] \
        || { printf 'bridge_iso_run publish-root-symlink: --link, --target, --group-agent required\n' >&2; return 2; }
      _bridge_iso_run_publish_root_symlink "$agent" "$link_path" "$target_path" "$group_agent"
      return $?
      ;;
    *)
      printf 'bridge_iso_run: unknown --op %q\n' "$op" >&2
      return 2
      ;;
  esac
}

# _bridge_iso_run_op_direct - non-isolated codepath. Same ops, no sudo.
_bridge_iso_run_op_direct() {
  local op="$1"
  local path="$2"
  local from_path="$3"
  local to_path="$4"
  local link_path="$5"
  local target_path="$6"
  local mode="$7"
  local marker_name="$8"
  local workdir_path="$9"
  local format="${10}"
  local test_kind="${11}"
  local group_agent="${12}"
  local read_stdin="${13}"
  shift 13 || true
  local keys=("$@")
  : "${marker_name}${format}${group_agent}${read_stdin}"

  case "$op" in
    stat)
      case "$test_kind" in
        exists)
          [[ -e "$path" ]] && return 0
          return 30
          ;;
        file)
          [[ -f "$path" ]] && return 0
          return 30
          ;;
        dir)
          [[ -d "$path" ]] && return 0
          return 30
          ;;
        symlink)
          [[ -L "$path" ]] && return 0
          return 30
          ;;
        readable)
          [[ -r "$path" ]] && return 0
          [[ -e "$path" ]] && return 32
          return 30
          ;;
        *) return 2 ;;
      esac
      ;;
    read-file|read-json)
      [[ -e "$path" ]] || return 30
      [[ -r "$path" ]] || return 32
      cat -- "$path"
      ;;
    env-has-any-key)
      [[ -e "$path" ]] || return 30
      [[ -r "$path" ]] || return 32
      if [[ ${#keys[@]} -eq 0 ]]; then
        if grep -Eq "^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=[^[:space:]#]" "$path"; then
          return 0
        fi
        return 31
      fi
      local k
      for k in "${keys[@]}"; do
        if grep -Eq "^[[:space:]]*(export[[:space:]]+)?${k}=[^[:space:]#].*" "$path"; then
          return 0
        fi
      done
      return 31
      ;;
    read-env-key)
      [[ -e "$path" ]] || return 30
      [[ -r "$path" ]] || return 32
      local first
      first="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${keys[0]}=" "$path" 2>/dev/null | head -1 || true)"
      [[ -n "$first" ]] || return 31
      first="${first#"${first%%[![:space:]]*}"}"
      first="${first#export }"
      first="${first#"${first%%[![:space:]]*}"}"
      first="${first#${keys[0]}=}"
      first="${first%%#*}"
      first="${first%"${first##*[![:space:]]}"}"
      printf "%s" "$first"
      ;;
    mkdir-p)
      mkdir -p -- "$path" || return 2
      if [[ -n "$mode" ]]; then
        chmod "$mode" "$path" || return 8
      fi
      ;;
    atomic-write)
      _bridge_iso_run_atomic_write_direct "$path" "$mode"
      return $?
      ;;
    rename)
      [[ -e "$from_path" ]] || return 30
      mv -f -- "$from_path" "$to_path" || return 9
      ;;
    state-marker-write)
      local marker_dir=""
      if declare -F bridge_agent_idle_marker_dir >/dev/null 2>&1; then
        marker_dir="$(bridge_agent_idle_marker_dir "" 2>/dev/null || printf '')"
      fi
      [[ -n "$marker_dir" ]] || return 5
      mkdir -p -- "$marker_dir" || return 2
      _bridge_iso_run_atomic_write_direct "$marker_dir/$marker_name" "0640"
      return $?
      ;;
    scan-profile)
      [[ -n "$workdir_path" ]] || return 2
      [[ -d "$workdir_path" ]] || return 30
      printf '{"workdir":"%s","isolated":false}\n' "$workdir_path"
      ;;
    publish-root-file)
      _bridge_iso_run_atomic_write_direct "$path" "$mode"
      return $?
      ;;
    publish-root-symlink)
      ln -sfn -- "$target_path" "$link_path" || return 9
      ;;
    *)
      printf 'bridge_iso_run direct: unknown --op %q\n' "$op" >&2
      return 2
      ;;
  esac
}

# _bridge_iso_run_atomic_write_direct <path> <mode>
# Controller-side atomic write helper (mirrors the inline op-script body).
_bridge_iso_run_atomic_write_direct() {
  local dest_path="$1"
  local mode="$2"
  local dest_dir
  dest_dir="$(dirname "$dest_path")"
  [[ -d "$dest_dir" ]] || return 5
  local tmp
  tmp="$(mktemp "$dest_dir/.$(basename "$dest_path").bridge-iso-tmp.XXXXXX")" || return 6
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' 2>/dev/null" EXIT INT TERM
  cat - >"$tmp" || return 7
  chmod "$mode" "$tmp" || return 8
  mv -f "$tmp" "$dest_path" || return 9
  trap - EXIT INT TERM
  return 0
}

# _bridge_iso_run_write_via_helper <agent> <path> <mode>
# Delegate to the existing iso-write helper which already handles
# mktemp/chmod/mv-as-iso-UID via pipe-only stdin. Maps its rc band into
# the structured bridge_iso_run rc band.
_bridge_iso_run_write_via_helper() {
  local agent="$1"
  local path="$2"
  local mode="$3"
  if ! declare -F bridge_isolation_write_file_as_agent_user_via_bash >/dev/null 2>&1; then
    return 20
  fi
  local rc=0
  bridge_isolation_write_file_as_agent_user_via_bash "$agent" "$path" "$mode"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 10 ;;
    2) return 20 ;;
    *) return "$rc" ;;
  esac
}

# _bridge_iso_run_state_marker_write <agent> <marker_name>
# Writes a marker under the agent's idle-marker dir. Streams stdin (the
# marker body) through the iso write helper.
_bridge_iso_run_state_marker_write() {
  local agent="$1"
  local marker="$2"
  local dir=""
  if declare -F bridge_agent_idle_marker_dir >/dev/null 2>&1; then
    dir="$(bridge_agent_idle_marker_dir "$agent" 2>/dev/null || printf '')"
  fi
  [[ -n "$dir" ]] || return 5
  # Validate the resolved marker path is under the allowlist (defense in
  # depth; the dispatcher gate already passes since the marker dir IS
  # one of the allowlisted roots).
  bridge_iso_run_path_under_allowlist "$agent" "$dir/$marker" || return 40

  # mkdir-p the dir as the iso UID first (idempotent).
  _bridge_iso_run_agent_script "$agent" "$_BRIDGE_ISO_RUN_OP_MKDIR_P" "$dir" "0750"
  local mk_rc=$?
  case "$mk_rc" in
    0) ;;
    1) return 10 ;;
    2) return 20 ;;
    *) return "$mk_rc" ;;
  esac
  _bridge_iso_run_write_via_helper "$agent" "$dir/$marker" "0640"
  return $?
}

# _bridge_iso_run_scan_profile <agent> <workdir> <format>
# Emit a small JSON snapshot of the workdir metadata. Runs inside the
# iso UID so controller-side PermissionError on lstat is bypassed.
_bridge_iso_run_scan_profile() {
  local agent="$1"
  local workdir="$2"
  local format="$3"
  [[ "$format" == "json" ]] \
    || { printf 'bridge_iso_run scan-profile: --format must be json\n' >&2; return 2; }
  local script
  script='
workdir="$1"
[[ -d "$workdir" ]] || exit 30
mode=""
owner=""
group=""
if stat -c "%a" "$workdir" >/dev/null 2>&1; then
  mode="$(stat -c "%a" "$workdir" 2>/dev/null)"
  owner="$(stat -c "%U" "$workdir" 2>/dev/null)"
  group="$(stat -c "%G" "$workdir" 2>/dev/null)"
elif stat -f "%Lp" "$workdir" >/dev/null 2>&1; then
  mode="$(stat -f "%Lp" "$workdir" 2>/dev/null)"
  owner="$(stat -f "%Su" "$workdir" 2>/dev/null)"
  group="$(stat -f "%Sg" "$workdir" 2>/dev/null)"
fi
printf "{\"workdir\":\"%s\",\"isolated\":true,\"mode\":\"%s\",\"owner\":\"%s\",\"group\":\"%s\"}\n" \
  "$workdir" "$mode" "$owner" "$group"
'
  _bridge_iso_run_agent_script "$agent" "$script" "$workdir"
  local rc=$?
  _bridge_iso_run_unshift_rc "$rc"
  return $?
}

# _bridge_iso_run_publish_root_file <agent> <path> <mode> <group_agent>
# Root-published write. The controller writes via a temp under the
# dest dir, then chowns to `root:ab-agent-<group_agent>` and chmods,
# then mv -f. Used for paths that MUST be root-owned (the iso UID must
# not be able to rewrite its own plugin allowlist).
#
# Uses `bridge_linux_sudo_root` when available (escalates via the
# pre-installed sudoers entry), otherwise falls back to direct ops
# (works when the controller IS root, e.g. server-mode installs and
# test harnesses with BRIDGE_ISO_RUN_ALLOWLIST_EXTRA pointing at a
# tmpdir).
#
# Symlink-traversal defense: refuses to publish when the immediate
# dest_dir is itself a symlink (`-L` check). This blocks the classic
# `installed_plugins.json -> /tmp/attacker` swap pattern; nested
# symlinks under the dest_dir are caught by the allowlist gate at the
# dispatcher level (the lexical prefix check sees the resolved
# textual path).
_bridge_iso_run_publish_root_file() {
  local agent="$1"
  local dest_path="$2"
  local mode="$3"
  local group_agent="$4"
  : "${agent}"  # agent arg reserved for future per-agent provenance log
  local dest_dir
  dest_dir="$(dirname "$dest_path")"

  if [[ -L "$dest_dir" ]]; then
    return 40
  fi
  if [[ ! -d "$dest_dir" ]]; then
    if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      bridge_linux_sudo_root mkdir -p -- "$dest_dir" 2>/dev/null || return 5
    else
      mkdir -p -- "$dest_dir" 2>/dev/null || return 5
    fi
  fi

  local tmp
  if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
    tmp="$(bridge_linux_sudo_root mktemp "$dest_dir/.$(basename "$dest_path").bridge-pub-tmp.XXXXXX" 2>/dev/null)" || return 6
  else
    tmp="$(mktemp "$dest_dir/.$(basename "$dest_path").bridge-pub-tmp.XXXXXX" 2>/dev/null)" || return 6
  fi

  local cleanup_cmd
  if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
    cleanup_cmd="bridge_linux_sudo_root rm -f -- '$tmp' 2>/dev/null"
  else
    cleanup_cmd="rm -f -- '$tmp' 2>/dev/null"
  fi
  # shellcheck disable=SC2064
  trap "$cleanup_cmd" EXIT INT TERM

  if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
    bridge_linux_sudo_root tee "$tmp" >/dev/null || return 7
    bridge_linux_sudo_root chown "root:ab-agent-${group_agent}" "$tmp" 2>/dev/null \
      || bridge_linux_sudo_root chown "root:${group_agent}" "$tmp" 2>/dev/null \
      || true
    bridge_linux_sudo_root chmod "$mode" "$tmp" || return 8
    bridge_linux_sudo_root mv -f -- "$tmp" "$dest_path" || return 9
  else
    cat - >"$tmp" || return 7
    chown "root:ab-agent-${group_agent}" "$tmp" 2>/dev/null \
      || chown "root:${group_agent}" "$tmp" 2>/dev/null \
      || true
    chmod "$mode" "$tmp" || return 8
    mv -f -- "$tmp" "$dest_path" || return 9
  fi
  trap - EXIT INT TERM
  return 0
}

# _bridge_iso_run_publish_root_symlink <agent> <link> <target> <group_agent>
# Root-published symlink (atomic via ln -sfn).
_bridge_iso_run_publish_root_symlink() {
  local agent="$1"
  local link_path="$2"
  local target_path="$3"
  local group_agent="$4"
  : "${agent}${group_agent}"  # reserved for future provenance log
  local link_dir
  link_dir="$(dirname "$link_path")"
  if [[ -L "$link_dir" ]]; then
    return 40
  fi
  if [[ ! -d "$link_dir" ]]; then
    return 5
  fi
  if command -v bridge_linux_sudo_root >/dev/null 2>&1; then
    bridge_linux_sudo_root ln -sfn -- "$target_path" "$link_path" || return 9
  else
    ln -sfn -- "$target_path" "$link_path" || return 9
  fi
  return 0
}

# End of bridge_iso_run facade.
