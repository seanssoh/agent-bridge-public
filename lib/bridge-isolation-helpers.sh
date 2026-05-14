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
