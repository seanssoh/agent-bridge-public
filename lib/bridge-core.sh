#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

# PR #951 r7: color constants are normally defined by bridge-lib.sh BEFORE
# it sources bridge-core.sh. Direct-source paths (lib/bridge-state.sh
# sourcing this file from the top to make bridge_resolve_script_dir_check
# available to scripts/smoke/* direct-source consumers) reach the helpers
# below without bridge-lib.sh ever running, so RED/YELLOW/CYAN/NC would
# be unbound and `set -u` callers (e.g. scripts/smoke/nudge-marker-
# recovery.sh) would crash inside bridge_warn / bridge_die. Define empty
# defaults idempotently — the full-loader path's earlier assignments win
# via the := default-if-unset pattern.
: "${RED:=}"
: "${GREEN:=}"
: "${YELLOW:=}"
: "${CYAN:=}"
: "${NC:=}"

bridge_die() {
  echo -e "${RED}[오류] $*${NC}" >&2
  exit 1
}

# Per-call re-validation of BRIDGE_SCRIPT_DIR (#946 L1). Long-lived daemons
# can survive a mid-flight removal of the source checkout (worktree cleanup
# after a wave dispatch, `agb upgrade --apply` moving the source root,
# `brew prune` on a Homebrew-installed source dir). The bridge-lib.sh
# startup validation only fires when bridge-lib.sh is first sourced;
# callers that fork repeatedly into python-helpers from a running daemon
# need to re-check before each invocation. The helpers attempt a cheap
# re-resolution via BASH_SOURCE before giving up so a temporary symlink
# swap or a mount-point flip can recover.
#
# r2 (codex P1 #2): the original `_or_die` form was unsafe inside command
# substitutions. When a caller wraps `bridge_extract_development_channels_
# from_command` (and similar) in `$(...)`, `bridge_die` exits only the
# substitution subshell — the parent receives an empty value and a
# non-zero substitution exit status. Under `set -e` the parent dies; under
# `... || true` the parent silently continues with the empty value and the
# daemon-hang cascade #946 reproduces unchanged. The fix splits the helper:
#
#   bridge_resolve_script_dir_check  — returns 0/1 + writes one
#       de-duplicated audit line to BRIDGE_DAEMON_LOG (or stderr fallback).
#       Safe inside `$()`: the audit goes to a FILE, not the captured
#       stdout, so substitution swallow cannot hide the signal.
#   bridge_resolve_script_dir_or_die — thin wrapper for callers OUTSIDE
#       substitution context (startup paths, daemon tick health check).
#
# Wrapper helpers in lib/bridge-*.sh that invoke `python3
# "$BRIDGE_SCRIPT_DIR/..."` use `bridge_resolve_script_dir_check || return 1`
# so a stale source checkout fails-empty + audit-logs whether or not the
# caller's context suppresses errexit.
#
# r3 (codex P2 #951): the helpers live in lib/bridge-core.sh rather than
# bridge-lib.sh because lib/bridge-hooks.sh (and the other lib/bridge-*.sh
# wrappers that call them) is sourced directly alongside lib/bridge-core.sh
# by tests/upgrade-precompact-wire/smoke.sh case 5 — without bridge-lib.sh.
# Putting them in bridge-core (the lowest-level module every direct
# consumer already pulls) keeps both the full-loader path (bridge-lib.sh
# sources bridge-core.sh) and the direct-source path working.

# Suppress repeat audit logs. We CANNOT use a shell variable for dedup —
# the check helper is invoked from inside `$(...)` substitutions, and any
# assignment in a subshell does not survive to the parent. Use a sentinel
# file under BRIDGE_STATE_DIR keyed on the failed path so even subshell
# calls coordinate; the dedup window is per-process (PID + dir-hash) so a
# daemon restart logs again. Also export an in-process flag so the same
# shell only pays the stat/write cost once per dedup window.
_BRIDGE_SCRIPT_DIR_AUDIT_LOGGED=0
export _BRIDGE_SCRIPT_DIR_AUDIT_LOGGED

bridge_resolve_script_dir_sentinel_path() {
  # Reads BRIDGE_SCRIPT_DIR from env. Callers never pass an explicit
  # target — the global is the only resolution surface — but the
  # function is wrapped for readability and to keep the path derivation
  # local. shellcheck disable=SC2120 (no args ever passed; deliberate).
  local target="${BRIDGE_SCRIPT_DIR:-unset}"
  local hash=""
  # Avoid forking python3 for the hash — we may be here BECAUSE python3
  # cannot run. Bash-native: a short tag derived from PID + path length +
  # first/last bytes is enough to differentiate "same failed dir" from
  # "different failed dir within the same process".
  hash="${$}-${#target}-${target:0:8}-${target: -8}"
  hash="${hash//\//_}"
  printf '%s/script-dir-audit-%s' "${BRIDGE_STATE_DIR:-/tmp}" "$hash"
}

bridge_resolve_script_dir_audit() {
  local reason="$1"
  local log_line=""
  local timestamp
  timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || printf 'unknown-ts')"
  log_line="[$timestamp] [error] [L1] BRIDGE_SCRIPT_DIR=${BRIDGE_SCRIPT_DIR:-<unset>} $reason (source checkout moved or deleted mid-flight?)"

  # In-process fast path: this shell already logged.
  if (( _BRIDGE_SCRIPT_DIR_AUDIT_LOGGED == 1 )); then
    return 0
  fi

  # Cross-subshell dedup: a sentinel file exists if the parent (or a
  # sibling subshell) already logged for this PID + failed path. The
  # sentinel includes PID so a daemon restart starts clean.
  local sentinel
  sentinel="$(bridge_resolve_script_dir_sentinel_path)"
  if [[ -f "$sentinel" ]]; then
    _BRIDGE_SCRIPT_DIR_AUDIT_LOGGED=1
    return 0
  fi

  # Prefer the daemon log (visible to operator via `agb status` /
  # `tail BRIDGE_DAEMON_LOG`). Fall back to stderr if the log path is
  # unset (early-startup contexts before bridge-lib.sh finishes init)
  # or unwritable. Either sink is OUTSIDE any `$(...)` substitution
  # the caller may be running in, so the substitution swallow does
  # not hide the signal.
  local logged=0
  if [[ -n "${BRIDGE_DAEMON_LOG:-}" ]]; then
    local log_dir
    log_dir="$(dirname -- "$BRIDGE_DAEMON_LOG" 2>/dev/null || printf '')"
    if [[ -n "$log_dir" ]] && mkdir -p "$log_dir" 2>/dev/null; then
      if printf '%s\n' "$log_line" >>"$BRIDGE_DAEMON_LOG" 2>/dev/null; then
        logged=1
      fi
    fi
  fi
  if (( logged == 0 )); then
    printf '%s\n' "$log_line" >&2
  fi

  # Touch the cross-subshell sentinel. Best-effort: if BRIDGE_STATE_DIR
  # itself is unwritable we accept a small amount of log spam over
  # losing the signal entirely.
  local sentinel_dir
  sentinel_dir="$(dirname -- "$sentinel" 2>/dev/null || printf '')"
  if [[ -n "$sentinel_dir" ]]; then
    mkdir -p "$sentinel_dir" 2>/dev/null || true
    : >"$sentinel" 2>/dev/null || true
  fi
  _BRIDGE_SCRIPT_DIR_AUDIT_LOGGED=1
}

bridge_resolve_script_dir_check() {
  if [[ -n "${BRIDGE_SCRIPT_DIR:-}" && -d "$BRIDGE_SCRIPT_DIR/scripts/python-helpers" ]]; then
    # Recovered (or never broken). Clear the cross-subshell sentinel so
    # a later failure logs once again, and reset the in-process flag.
    local sentinel
    sentinel="$(bridge_resolve_script_dir_sentinel_path)"
    rm -f "$sentinel" 2>/dev/null || true
    _BRIDGE_SCRIPT_DIR_AUDIT_LOGGED=0
    return 0
  fi

  # Re-resolution attempt: BASH_SOURCE may now point somewhere new if the
  # file is still discoverable through a sibling path. Cheap to try.
  # NOTE: this file lives at lib/bridge-core.sh, so dirname BASH_SOURCE[0]
  # points at <repo>/lib. The repo root (where scripts/python-helpers/ lives)
  # is one level up — hence the "/.." suffix. Do NOT drop it without also
  # moving this helper back to the repo root. (PR #951 r4 — codex P2)
  local resolved=""
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    resolved="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P 2>/dev/null)" || resolved=""
  fi
  if [[ -n "$resolved" && -d "$resolved/scripts/python-helpers" ]]; then
    BRIDGE_SCRIPT_DIR="$resolved"
    export BRIDGE_SCRIPT_DIR
    local sentinel
    sentinel="$(bridge_resolve_script_dir_sentinel_path)"
    rm -f "$sentinel" 2>/dev/null || true
    _BRIDGE_SCRIPT_DIR_AUDIT_LOGGED=0
    return 0
  fi

  local reason="does not exist or is missing scripts/python-helpers/"
  if [[ -z "${BRIDGE_SCRIPT_DIR:-}" ]]; then
    reason="unresolved"
  fi
  bridge_resolve_script_dir_audit "$reason"
  return 1
}

bridge_resolve_script_dir_or_die() {
  bridge_resolve_script_dir_check && return 0
  bridge_die "BRIDGE_SCRIPT_DIR=${BRIDGE_SCRIPT_DIR:-<unset>} does not exist or is missing scripts/python-helpers/ (source checkout moved or deleted mid-flight?)"
}

# Issue #800 regression follow-up: the Levenshtein nearest-match fallback used
# by ``bridge_suggest_subcommand`` previously embedded its Python body via
# ``python3 - "$arg" <<'PY' ... PY``. That is the same heredoc-stdin pattern
# PR #801 closed across nine daemon callsites — bash can wedge in
# ``heredoc_write`` BEFORE the python child launches. The body is short and
# only fires on unknown-subcommand error paths, so we use Pattern B
# (``python3 -c "$SCRIPT"`` here-string) rather than promoting it into
# ``bridge-daemon-helpers.py``. ``bridge_with_timeout`` (lib/bridge-state.sh)
# enforces a 5s ceiling — pure compute, no IO — and audit-logs
# ``daemon_subprocess_timeout`` on 124/137 so the operator can spot a stuck
# call site even on the help/error path. The variable is module-level so we
# don't pay parser cost on every invocation.
_BRIDGE_CORE_LEVENSHTEIN_PY='
import sys

def levenshtein(a, b):
    if a == b:
        return 0
    if not a or not b:
        return max(len(a), len(b))
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        curr = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        prev = curr
    return prev[-1]

unknown = sys.argv[1].strip()
candidates = [c for c in sys.argv[2].split() if c]

if not candidates:
    sys.exit(0)

scored = sorted(((levenshtein(unknown.lower(), c.lower()), c) for c in candidates))
best = scored[0]
second = scored[1] if len(scored) > 1 else None

# Require: (a) distance <= 2, (b) distance < len(unknown) (reject wild
# matches where the "closest" valid word shares almost nothing), and
# (c) a strict margin over second-best to avoid ambiguous ties.
if best[0] > 2:
    sys.exit(0)
if best[0] >= len(unknown):
    sys.exit(0)
if second and second[0] <= best[0]:
    # Tie — suggesting one of several equally-near is noisier than silence.
    sys.exit(0)

print(best[1])
'

# bridge_suggest_subcommand — intent-recovery for unknown CLI subcommands.
#
# Issue #163: agents repeatedly guessed CLI subcommand names that don't exist
# (`agent-bridge cron stats`, `cron list --failed`, `agent-bridge health`) and
# the dispatchers only emitted "지원하지 않는 X 명령입니다: Y" with no hint.
# Failed attempts often cascaded into blocked fallbacks (direct `sqlite3`).
#
# This helper produces a single-line "혹시 X 이었나요?" suggestion from a
# curated intent alias table (primary) plus a Levenshtein nearest-match
# fallback (secondary). Callers print the suggestion right before `bridge_die`
# so the operator / agent sees the recovery hint in the same error frame.
#
# Usage:
#   hint="$(bridge_suggest_subcommand "cron stats" "inventory show list create ... errors cleanup")"
#   [[ -n "$hint" ]] && bridge_warn "$hint"
#   bridge_die "지원하지 않는 cron 명령입니다: cron stats"
#
# Args:
#   $1 — the unknown input (may be a multi-token phrase like "cron stats" or
#        a single token like "health"). Case-sensitive; callers should
#        normalize to the form the user typed.
#   $2 — space-separated list of valid subcommand names for the current
#        dispatcher (may be empty; helper then skips fuzzy match and only
#        consults the curated alias table).
#
# Emits: a Korean suggestion line on stdout, or empty if no suggestion
# reaches the confidence threshold. Never exits. Never contaminates stderr.
bridge_suggest_subcommand() {
  local unknown="$1"
  local valid_list="$2"
  local suggestions=""

  [[ -n "$unknown" ]] || return 0

  # Curated intent → command table. Keys are the phrases agents actually
  # typed in the wild (Issue #163 실측 + future telemetry); values are the
  # canonical commands. Extend conservatively — one wrong alias is worse
  # than no alias.
  case "$unknown" in
    health|diag|diagnose|diagnostic|diagnostics)
      suggestions="agent-bridge status  |  agent-bridge watchdog scan"
      ;;
    "cron stats"|"cron stat"|"cron status"|"cron metrics")
      suggestions="agent-bridge cron errors report  |  agent-bridge cron list"
      ;;
    "cron list --failed"|"cron failed"|"cron failures"|"cron errors"|"cron error")
      suggestions="agent-bridge cron errors report"
      ;;
    "cron history"|"cron log"|"cron logs"|"cron audit"|"cron runs")
      suggestions="agent-bridge cron errors report  |  agent-bridge cron show <job>"
      ;;
    "queue status"|"queue stats"|"task stats")
      suggestions="agent-bridge summary  |  agent-bridge status"
      ;;
    ps|processes|agents)
      suggestions="agent-bridge list  |  agent-bridge status"
      ;;
    help)
      suggestions="agent-bridge --help"
      ;;
  esac

  if [[ -n "$suggestions" ]]; then
    printf '혹시 이 명령이었나요?  %s' "$suggestions"
    return 0
  fi

  # Fallback: Levenshtein nearest-match against the caller-supplied valid
  # list. Only emits when a candidate is strictly closer than the next-best
  # (prevents "cron" → equidistant ambiguity from false-suggesting). Uses
  # python for the distance calc since the helper is already python-gated
  # elsewhere and we need unicode-safe comparison for Korean argument words.
  [[ -n "$valid_list" ]] || return 0

  bridge_require_python
  local match
  # Pattern B per PR #801 / #800 follow-up: ``python3 -c "$SCRIPT"`` here-
  # string + ``bridge_with_timeout`` wrapper. The previous form was
  # ``python3 - "$arg" <<'PY' ... PY`` which is the heredoc-stdin deadlock
  # class. ``bridge_with_timeout`` is defined in lib/bridge-state.sh which
  # is sourced AFTER this module in bridge-lib.sh — safe because bash
  # resolves the function name at call time, not at source time.
  match="$(bridge_with_timeout 5 core_match python3 -c "$_BRIDGE_CORE_LEVENSHTEIN_PY" "$unknown" "$valid_list" 2>/dev/null || true)"

  if [[ -n "$match" ]]; then
    printf '혹시 %q 이었나요?' "$match"
  fi
}

# bridge_cli_subcommand_help_summary — extract Usage lines for one subcommand.
#
# Issue #283 Track A: skill content (`bridge-commands.md`) was hand-maintained
# and drifted out of sync with the real CLI surface. This helper parses
# `<cli> --help` and returns every Usage line whose first token after the CLI
# name matches `$1`. Caller renders the result however it wants (one bullet
# per line, in the auto-discovered "Full Subcommand Reference" section).
#
# Defensive contract: missing CLI, unreadable CLI, malformed --help output, or
# a subcommand that has no Usage entries all return empty stdout with rc=0.
# Never fails. Never writes to stderr.
#
# Usage:
#   bridge_cli_subcommand_help_summary cron "$BRIDGE_HOME/agent-bridge"
#
# Args:
#   $1 — top-level subcommand name (e.g. "cron", "task"). Required; empty
#        returns empty.
#   $2 — path to the agent-bridge CLI binary. Optional; defaults to
#        ${BRIDGE_CLI_NAME:-${BRIDGE_SCRIPT_DIR}/agent-bridge} so the helper
#        works inside the source checkout without explicit wiring.
bridge_cli_subcommand_help_summary() {
  local subcommand="$1"
  local cli="${2:-${BRIDGE_CLI_NAME:-${BRIDGE_SCRIPT_DIR:-.}/agent-bridge}}"

  [[ -n "$subcommand" ]] || return 0
  [[ -n "$cli" && -f "$cli" ]] || return 0

  "$cli" --help 2>/dev/null | awk -v cmd="$subcommand" '
    BEGIN { in_usage = 0 }
    /^Usage:/                    { in_usage = 1; next }
    in_usage == 0                { next }
    /^[^[:space:]]/              { in_usage = 0; next }
    /^[[:space:]]*$/             { next }
    {
      sub(/^[[:space:]]+/, "")
      if (NF < 2) next
      if ($2 == cmd) print $0
    }
  '
}

# bridge_cli_top_level_subcommands — list unique top-level subcommand names.
#
# Issue #283 Track A: the auto-discovered subcommand reference renders one
# section per top-level subcommand. This helper returns the unique
# second-tokens of every Usage line in `<cli> --help`, skipping flag-shaped
# entries like `--codex|--claude` so the renderer doesn't produce a section
# titled with a flag union.
#
# Defensive contract: missing or unreadable CLI returns empty stdout with rc=0.
# Output is one subcommand per line, in the order they first appear in --help
# (so the rendered reference mirrors the operator-facing layout).
bridge_cli_top_level_subcommands() {
  local cli="${1:-${BRIDGE_CLI_NAME:-${BRIDGE_SCRIPT_DIR:-.}/agent-bridge}}"

  [[ -n "$cli" && -f "$cli" ]] || return 0

  "$cli" --help 2>/dev/null | awk '
    BEGIN { in_usage = 0 }
    /^Usage:/                    { in_usage = 1; next }
    in_usage == 0                { next }
    /^[^[:space:]]/              { in_usage = 0; next }
    /^[[:space:]]*$/             { next }
    {
      sub(/^[[:space:]]+/, "")
      if (NF < 2) next
      sub_cmd = $2
      # Skip flag-shaped pseudo-subcommands (e.g. "--codex|--claude") so
      # the rendered reference does not produce a `### --codex|--claude`
      # section header.
      if (sub_cmd ~ /^-/) next
      if (!(sub_cmd in seen)) {
        seen[sub_cmd] = 1
        print sub_cmd
      }
    }
  '
}

bridge_warn() {
  echo -e "${YELLOW}[경고] $*${NC}" >&2
}

bridge_info() {
  echo -e "${CYAN}$*${NC}"
}

bridge_version() {
  local version_file="$BRIDGE_SCRIPT_DIR/VERSION"

  if [[ -f "$version_file" ]]; then
    head -n 1 "$version_file" | tr -d '[:space:]'
    return 0
  fi

  printf '0.0.0-dev'
}

bridge_source_head() {
  git -C "$BRIDGE_SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || printf '-'
}

# Antigravity wave (Track A0): the engine VALUE stored in the roster is not
# always the on-disk binary name. `antigravity` is launched via the `agy`
# binary; `claude`/`codex` happen to match. Every site that does
# `command -v "$engine"` assuming value==binary must route through this so
# the daemon/agents do not permanently skip an agy agent as
# `engine-cli-missing:antigravity`.
bridge_engine_binary_name() {
  local engine="${1:-}"
  case "$engine" in
    antigravity) printf 'agy' ;;
    claude) printf 'claude' ;;
    codex) printf 'codex' ;;
    # Unknown engine: echo the input unchanged so callers degrade safely
    # (a `command -v` of an unknown token simply fails, as before).
    *) printf '%s' "$engine" ;;
  esac
}

# Antigravity wave (Track A0): normalize an operator-supplied engine token
# to the canonical stored engine VALUE. `agy` and `gemini` are accepted
# aliases for `antigravity`; `claude`/`codex` pass through. An unknown
# token returns non-zero with an empty stdout so callers can `bridge_die`.
bridge_normalize_engine() {
  local engine="${1:-}"
  case "$engine" in
    antigravity|agy|gemini) printf 'antigravity' ;;
    claude) printf 'claude' ;;
    codex) printf 'codex' ;;
    *) return 1 ;;
  esac
}

# Expand a leading `~` or `~/...` to $HOME. Bash-native equivalent of
# `pathlib.Path(p).expanduser()` for the agent-bridge path patterns the
# roster actually uses (`~`, `~/foo`, `/abs/...`, or a relative path).
# Issue v0.8.6 hotfix: previously this lived in bridge-agent.sh and called
# `bridge_agent_manage_python`, so any caller that didn't transitively
# source bridge-agent.sh saw `bridge_expand_user_path: command not found`
# (e.g. `lib/bridge-isolation-v2-migrate.sh:136` running under
# `bridge-migrate.sh`'s sourcing chain). Move the helper here so every
# bridge-lib.sh consumer has it without sourcing the executable script.
# Bash-native by design: drops the python startup cost on every call site
# (rerender preflight, scaffold path resolution, migration preflight) and
# is byte-equivalent for the inputs the codebase actually uses. The python
# `~user` expansion is intentionally not supported — agent roster paths
# are always controller-relative.
bridge_expand_user_path() {
  local raw="$1"
  case "$raw" in
    '')   printf '%s' "" ;;
    '~')  printf '%s' "$HOME" ;;
    \~/*) printf '%s%s' "$HOME" "${raw:1}" ;;
    *)    printf '%s' "$raw" ;;
  esac
}

bridge_source_ref() {
  git -C "$BRIDGE_SCRIPT_DIR" describe --tags --exact-match HEAD 2>/dev/null \
    || git -C "$BRIDGE_SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null \
    || printf '-'
}

bridge_init_dirs() {
  mkdir -p \
    "$BRIDGE_HOME" \
    "$BRIDGE_STATE_DIR" \
    "$BRIDGE_CRON_HOME_DIR" \
    "$BRIDGE_PROFILE_STATE_DIR" \
    "$BRIDGE_ACTIVE_AGENT_DIR" \
    "$BRIDGE_HISTORY_DIR" \
    "$BRIDGE_WORKTREE_META_DIR" \
    "$BRIDGE_WORKTREE_ROOT" \
    "$BRIDGE_LOG_DIR" \
    "$BRIDGE_SHARED_DIR" \
    "$BRIDGE_TASK_NOTE_DIR" \
    "$BRIDGE_RUNTIME_ROOT" \
    "$BRIDGE_RUNTIME_SCRIPTS_DIR" \
    "$BRIDGE_RUNTIME_SKILLS_DIR" \
    "$BRIDGE_RUNTIME_SHARED_TOOLS_DIR" \
    "$BRIDGE_RUNTIME_SHARED_REFERENCES_DIR" \
    "$BRIDGE_RUNTIME_MEMORY_DIR" \
    "$BRIDGE_RUNTIME_CREDENTIALS_DIR" \
    "$BRIDGE_RUNTIME_SECRETS_DIR"
}

bridge_require_python() {
  if command -v python3 >/dev/null 2>&1; then
    return 0
  fi

  bridge_die "python3가 필요합니다."
}

bridge_now_iso() {
  bridge_require_python
  python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"))
PY
}

bridge_runtime_id() {
  local home="$1"
  [[ -n "$home" ]] || {
    echo "bridge_runtime_id: home required" >&2
    return 2
  }
  bridge_require_python
  python3 - "$home" <<'PY'
import hashlib
import os
import sys

canonical = os.path.realpath(os.path.expanduser(sys.argv[1]))
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:12])
PY
}

bridge_queue_gateway_runtime_root() {
  printf '%s' "${BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT:-/run/agent-bridge}"
}

bridge_queue_gateway_socket_path() {
  local bridge_id
  bridge_id="$(bridge_runtime_id "$BRIDGE_HOME")" || return $?
  printf '%s/%s/queue-gateway.sock' "$(bridge_queue_gateway_runtime_root)" "$bridge_id"
}

bridge_queue_gateway_transport() {
  local transport="${BRIDGE_GATEWAY_TRANSPORT:-file}"
  case "$transport" in
    file|socket)
      printf '%s' "$transport"
      ;;
    *)
      bridge_warn "invalid BRIDGE_GATEWAY_TRANSPORT=$transport; falling back to file"
      printf '%s' "file"
      ;;
  esac
}

bridge_queue_gateway_runtime_verify() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/bridge-queue-gateway.py" verify-runtime --bridge-home "$BRIDGE_HOME"
}

bridge_queue_gateway_runtime_ensure() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/bridge-queue-gateway.py" ensure-runtime --bridge-home "$BRIDGE_HOME" "$@"
}

bridge_nonce() {
  bridge_require_python
  python3 - <<'PY'
import secrets

print(secrets.token_hex(8))
PY
}

bridge_queue_gateway_root() {
  # v2 layout: queue agent dirs live inside the per-agent root so the
  # requests/ and responses/ subtrees inherit the isolated-UID
  # ownership without a separate ACL subtree. The "root" returned
  # here is therefore the per-agent root parent (BRIDGE_AGENT_ROOT_V2),
  # and bridge_queue_gateway_agent_dir composes "<root>/<agent>" the
  # same way as the legacy "<state>/queue-gateway/<agent>" path.
  if bridge_isolation_v2_active && [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
    printf '%s' "$BRIDGE_AGENT_ROOT_V2"
    return 0
  fi
  printf '%s/queue-gateway' "$BRIDGE_STATE_DIR"
}

# Plugin catalog metadata files exposed read-only to isolated UIDs as
# symlinks into the controller's ~/.claude/plugins/. We treat these as
# "audit-level" disclosure — they reveal plugin names/versions but no
# secrets and no plugin source code. The matching strip in
# bridge_migration_unisolate iterates the same constant.
declare -ga BRIDGE_ISOLATION_SHARED_CATALOG_READ_FILES=(
  known_marketplaces.json
  install-counts-cache.json
  blocklist.json
)

# Returns 0 (success) if the cron sync path should run, 1 otherwise.
# Contract: walk the new name and its two legacy aliases.
#   - If any variable is a recognized off-form (0, false, no, off), disable.
#   - If any variable is a recognized on-form (1, true, yes, on), keep checking
#     the others (so another variable can still explicitly disable).
#   - If any variable is set to a non-empty, unrecognized value (e.g. "2",
#     "banana"), fail closed: disable — so an operator's typo does not silently
#     flip a side-effectful sync on.
#   - If all three are unset or empty, enable (the #192 default-ON goal).
# Case-insensitive (relies on bash 4+ ${var,,}).
# Replaces a bash parameter-expansion chain that implemented precedence and
# silently let an outer =1 override an inner =0 — which broke the #192
# legacy-opt-out promise.
bridge_cron_sync_enabled() {
  local var val normalized
  for var in BRIDGE_CRON_SYNC_ENABLED BRIDGE_LEGACY_CRON_SYNC_ENABLED BRIDGE_OPENCLAW_CRON_SYNC_ENABLED; do
    val="${!var-}"
    [[ -z "$val" ]] && continue
    normalized="${val,,}"
    case "$normalized" in
      1|true|yes|on)
        ;;
      0|false|no|off)
        return 1
        ;;
      *)
        return 1
        ;;
    esac
  done
  return 0
}

bridge_queue_gateway_agent_dir() {
  local agent="$1"
  printf '%s/%s' "$(bridge_queue_gateway_root)" "$agent"
}

bridge_queue_gateway_requests_dir() {
  local agent="$1"
  printf '%s/requests' "$(bridge_queue_gateway_agent_dir "$agent")"
}

bridge_queue_gateway_responses_dir() {
  local agent="$1"
  printf '%s/responses' "$(bridge_queue_gateway_agent_dir "$agent")"
}

bridge_queue_gateway_proxy_agent() {
  # Resolve the calling agent that should route through the queue gateway
  # instead of touching the SQLite DB directly. Returns the agent id on stdout
  # when proxy mode applies; empty + non-zero rc otherwise.
  #
  # Decoupled from `${#BRIDGE_AGENT_IDS[@]}` so the scoped env can carry every
  # peer's id (needed for client-side bridge_require_agent on A2A queue tasks)
  # without simultaneously dropping the isolated UID off the gateway path.
  # The explicit `BRIDGE_GATEWAY_PROXY=1` flag is emitted by
  # bridge_write_linux_agent_env_file whenever the agent runs in linux-user
  # isolation. See issue #294.
  local agent=""

  [[ -n "${BRIDGE_AGENT_ENV_FILE:-}" ]] || return 1
  [[ "${BRIDGE_GATEWAY_PROXY:-}" == "1" ]] || return 1
  agent="${BRIDGE_AGENT_ID:-}"
  if [[ -z "$agent" ]]; then
    # Fallback: scoped envs always emit the calling agent's id first.
    agent="${BRIDGE_AGENT_IDS[0]:-}"
  fi
  [[ -n "$agent" ]] || return 1
  bridge_agent_linux_user_isolation_effective "$agent" || return 1
  printf '%s' "$agent"
}

bridge_queue_cli_direct() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard. Called from many `$(...)`
  # substitutions across the queue path.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/bridge-queue.py" "$@"
}

bridge_sha1() {
  local text="$1"

  bridge_require_python
  python3 - "$text" <<'PY'
import hashlib
import sys

print(hashlib.sha1(sys.argv[1].encode("utf-8")).hexdigest())
PY
}

# Batch variant of bridge_sha1 — one python3 spawn hashes N inputs. Reads
# one input per line from stdin, emits hex digests one per line in the
# same order. Use when a caller knows the full set of inputs upfront
# (canonical case: roster hydration's per-agent history-key hashing,
# which used to pay one python3 cold-start per agent). Refs #848.
bridge_sha1_batch() {
  bridge_require_python
  # #946 L1 (r2 codex P1 #1 — explicitly cited): `bridge_load_roster` uses
  # this after every cache invalidation. r1 left this path unguarded, so
  # the stale-source #946 cascade reproduced on every roster reload. The
  # `_check` form is required (not `_or_die`) because callers typically
  # wrap this in `$( ... | bridge_sha1_batch )` for batched hashing.
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
  python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/sha1-batch.py"
}

bridge_redact_inline_env_secrets() {
  local text="${1-}"
  local redacted=""

  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s' "[redacted launch command: python3 unavailable]"
    return 0
  fi

  if redacted="$(printf '%s' "$text" | python3 -c '
import re
import sys

text = sys.stdin.read()


def sensitive(name):
    upper = name.upper()
    # Substring markers cover the common secret families. Note that
    # ``AUTH``/``PRIVATE``/``SECRET`` already cover their ``*_KEY``
    # variants by substring match; ``API_KEY``/``CLIENT_KEY``/``ACCESS_KEY``
    # are listed explicitly so non-secret env names that merely happen to
    # end in ``_KEY`` (e.g. ``BRIDGE_LAYOUT_MARKER_KEY``, ``CACHE_KEY``,
    # ``STATE_KEY``) are no longer false-positive redacted (#428 r2).
    if any(
        marker in upper
        for marker in (
            "SECRET",
            "TOKEN",
            "PASSWORD",
            "PASSWD",
            "CREDENTIAL",
            "AUTH",
            "BEARER",
            "PRIVATE",
            "COOKIE",
            "JWT",
            "API_KEY",
            "AUTH_KEY",
            "PRIVATE_KEY",
            "CLIENT_KEY",
            "ACCESS_KEY",
            "SECRET_KEY",
        )
    ):
        return True
    if re.search(r"(^|_)PWD($|_)", upper):
        return True
    return False


assignment = re.compile(
    r"(^|\s)"
    r"([A-Za-z_][A-Za-z0-9_]*)"
    r"(=)"
    r"(\$'\''(?:[^'\''\\]|\\.)*'\''|\$\"(?:[^\"\\]|\\.)*\"|'\''(?:[^'\''\\]|\\.)*'\''|\"(?:[^\"\\]|\\.)*\"|(?:\\.|[^\s])*)",
    re.MULTILINE,
)


def replace(match):
    prefix, name, equals, _value = match.groups()
    if sensitive(name):
        return f"{prefix}{name}{equals}***redacted***"
    return match.group(0)


sys.stdout.write(assignment.sub(replace, text))
' 2>/dev/null)"; then
    printf '%s' "$redacted"
    return 0
  fi

  printf '%s' "[redacted launch command: redaction failed]"
}

bridge_queue_cli() {
  local agent=""
  local transport=""

  if agent="$(bridge_queue_gateway_proxy_agent 2>/dev/null)"; then
    bridge_require_python
    # #946 L1 (r2): stale-source guard. bridge_queue_cli is the
    # universal queue path — frequently called from `$(...)`.
    if ! bridge_resolve_script_dir_check; then
      return 1
    fi
    transport="$(bridge_queue_gateway_transport)"
    if [[ "$transport" == "socket" ]]; then
      python3 "$BRIDGE_SCRIPT_DIR/bridge-queue-gateway.py" socket-client \
        --bridge-home "$BRIDGE_HOME" \
        --timeout "${BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS:-5}" \
        "$@"
      return $?
    else
      python3 "$BRIDGE_SCRIPT_DIR/bridge-queue-gateway.py" client \
        --root "$(bridge_queue_gateway_root)" \
        --agent "$agent" \
        --timeout "${BRIDGE_QUEUE_GATEWAY_TIMEOUT_SECONDS:-45}" \
        --poll "${BRIDGE_QUEUE_GATEWAY_POLL_SECONDS:-0.2}" \
        "$@"
      return $?
    fi
  fi

  bridge_queue_cli_direct "$@"
}

bridge_queue_source_shell() {
  local queue_output=""

  queue_output="$(bridge_queue_cli "$@")" || return $?
  # shellcheck disable=SC1090
  source /dev/stdin <<<"$queue_output"
}

bridge_reset_roster_maps() {
  unset BRIDGE_ADMIN_AGENT_ID
  unset BRIDGE_AGENT_IDS BRIDGE_AGENT_DESC BRIDGE_AGENT_ENGINE BRIDGE_AGENT_SESSION
  unset BRIDGE_AGENT_WORKDIR BRIDGE_AGENT_PROFILE_HOME BRIDGE_AGENT_LAUNCH_CMD BRIDGE_AGENT_ACTION
  unset BRIDGE_AGENT_SOURCE BRIDGE_AGENT_META_FILE BRIDGE_AGENT_LOOP
  unset BRIDGE_AGENT_CONTINUE BRIDGE_AGENT_SESSION_ID BRIDGE_AGENT_SESSION_STALE_HINT BRIDGE_AGENT_HISTORY_KEY
  unset BRIDGE_AGENT_CREATED_AT BRIDGE_AGENT_UPDATED_AT BRIDGE_AGENT_IDLE_TIMEOUT
  unset BRIDGE_AGENT_NOTIFY_KIND BRIDGE_AGENT_NOTIFY_TARGET BRIDGE_AGENT_NOTIFY_ACCOUNT
  unset BRIDGE_AGENT_WEBHOOK_PORT BRIDGE_LEGACY_AGENT_TARGET BRIDGE_OPENCLAW_AGENT_TARGET BRIDGE_CRON_AGENT_TARGET BRIDGE_CRON_FALLBACK_AGENT BRIDGE_AGENT_DISCORD_CHANNEL_ID BRIDGE_AGENT_CHANNELS BRIDGE_AGENT_PLUGINS BRIDGE_AGENT_AUTO_ACCEPT_DEV_CHANNELS BRIDGE_AGENT_MEMORY_DAILY_REFRESH BRIDGE_AGENT_INJECT_TIMESTAMP BRIDGE_AGENT_PROMPT_GUARD BRIDGE_CRON_ENQUEUE_FAMILIES
  unset BRIDGE_AGENT_SKILLS
  unset BRIDGE_AGENT_ISOLATION_MODE BRIDGE_AGENT_OS_USER
  unset BRIDGE_AGENT_CLASS
  unset BRIDGE_AGENT_PROVENANCE
  # Issue #597 Track B: PreCompact channel auto-notify opt-in maps.
  unset BRIDGE_AGENT_PRECOMPACT_NOTIFY BRIDGE_AGENT_PRECOMPACT_NOTIFY_LANG

  declare -g -a BRIDGE_AGENT_IDS=()
  declare -g -A BRIDGE_AGENT_DESC=()
  declare -g -A BRIDGE_AGENT_ENGINE=()
  declare -g -A BRIDGE_AGENT_SESSION=()
  declare -g -A BRIDGE_AGENT_WORKDIR=()
  declare -g -A BRIDGE_AGENT_PROFILE_HOME=()
  declare -g -A BRIDGE_AGENT_LAUNCH_CMD=()
  declare -g -A BRIDGE_AGENT_ACTION=()
  declare -g -A BRIDGE_AGENT_SOURCE=()
  declare -g -A BRIDGE_AGENT_META_FILE=()
  declare -g -A BRIDGE_AGENT_LOOP=()
  declare -g -A BRIDGE_AGENT_CONTINUE=()
  declare -g -A BRIDGE_AGENT_SESSION_ID=()
  declare -g -A BRIDGE_AGENT_SESSION_STALE_HINT=()
  declare -g -A BRIDGE_AGENT_HISTORY_KEY=()
  declare -g -A BRIDGE_AGENT_CREATED_AT=()
  declare -g -A BRIDGE_AGENT_UPDATED_AT=()
  declare -g -A BRIDGE_AGENT_IDLE_TIMEOUT=()
  declare -g -A BRIDGE_AGENT_NOTIFY_KIND=()
  declare -g -A BRIDGE_AGENT_NOTIFY_TARGET=()
  declare -g -A BRIDGE_AGENT_NOTIFY_ACCOUNT=()
  declare -g -A BRIDGE_AGENT_WEBHOOK_PORT=()
  declare -g -A BRIDGE_LEGACY_AGENT_TARGET=()
  declare -g -A BRIDGE_OPENCLAW_AGENT_TARGET=()
  declare -g -A BRIDGE_CRON_AGENT_TARGET=()
  declare -g -A BRIDGE_AGENT_DISCORD_CHANNEL_ID=()
  declare -g -A BRIDGE_AGENT_CHANNELS=()
  declare -g -A BRIDGE_AGENT_PLUGINS=()
  declare -g -A BRIDGE_AGENT_AUTO_ACCEPT_DEV_CHANNELS=()
  declare -g -A BRIDGE_AGENT_MEMORY_DAILY_REFRESH=()
  declare -g -A BRIDGE_AGENT_INJECT_TIMESTAMP=()
  declare -g -A BRIDGE_AGENT_PROMPT_GUARD=()
  declare -g -A BRIDGE_AGENT_SKILLS=()
  declare -g -A BRIDGE_AGENT_ISOLATION_MODE=()
  declare -g -A BRIDGE_AGENT_OS_USER=()
  # Issue #539: per-agent privilege class consumed by hooks/tool-policy.py.
  # Default-empty; bridge_agent_class normalizes missing/unknown to "user".
  # Operators opt agents into class=system in agent-roster.local.sh; the
  # public roster declares no system-class agents.
  declare -g -A BRIDGE_AGENT_CLASS=()
  # Issue #598 Track 1: provenance tag set by each loader path so the
  # registry endpoint can report which registry made the agent id known
  # (`static-roster`, `dynamic-active-env`, `dynamic-history-live-session`,
  # `dynamic-tmux-recovered`). Default-empty; consumers fall back to
  # `static-roster` when the tag is missing — that matches the historical
  # implicit behavior of any id present in BRIDGE_AGENT_IDS without a
  # dynamic loader having claimed it.
  declare -g -A BRIDGE_AGENT_PROVENANCE=()
  # Issue #597 Track B: per-agent opt-in for PreCompact channel auto-notify.
  # Default OFF (any unset entry is treated as 0). Opt in per-agent in
  # agent-roster.local.sh: BRIDGE_AGENT_PRECOMPACT_NOTIFY[<agent>]="1".
  declare -g -A BRIDGE_AGENT_PRECOMPACT_NOTIFY=()
  # Issue #597 Track B: per-agent language override for PreCompact notice
  # template. Falls back to BRIDGE_PRECOMPACT_NOTIFY_LANG (env, default "en").
  declare -g -A BRIDGE_AGENT_PRECOMPACT_NOTIFY_LANG=()
  declare -g -a BRIDGE_CRON_ENQUEUE_FAMILIES=()

  # Issue #597 Track B: scalar envs for the auto-notify pipeline. Each is
  # honored at daemon-cycle time; the kill switch lets operators disable
  # all sends without redeploy.
  : "${BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS:=1800}"
  : "${BRIDGE_PRECOMPACT_NOTICE_DEDUP_SECONDS:=300}"
  : "${BRIDGE_PRECOMPACT_EMA_ALPHA:=0.30}"
  : "${BRIDGE_PRECOMPACT_NOTIFY_DISABLED:=0}"
  : "${BRIDGE_PRECOMPACT_NOTIFY_LANG:=en}"
  : "${BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN:=0}"
  : "${BRIDGE_PRECOMPACT_FOLLOWUP_RETRY_SECONDS:=600}"
  export BRIDGE_PRECOMPACT_NOTIFY_RECENCY_SECONDS \
    BRIDGE_PRECOMPACT_NOTICE_DEDUP_SECONDS \
    BRIDGE_PRECOMPACT_EMA_ALPHA \
    BRIDGE_PRECOMPACT_NOTIFY_DISABLED \
    BRIDGE_PRECOMPACT_NOTIFY_LANG \
    BRIDGE_PRECOMPACT_NOTIFY_DRY_RUN \
    BRIDGE_PRECOMPACT_FOLLOWUP_RETRY_SECONDS
}

bridge_add_agent_id_if_missing() {
  local agent="$1"
  local existing

  for existing in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$existing" == "$agent" ]]; then
      return 0
    fi
  done

  BRIDGE_AGENT_IDS+=("$agent")
}

bridge_validate_agent_name() {
  local name="$1"

  # Issue #526: a leading hyphen lets `--help` / `-h` / future flag names
  # slip through as positional <name> arguments and silently scaffold a real
  # agent named `--help`. Require the first character to be alphanumeric so
  # CLI flags can never bind here.
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1

  # Reserved-name list: bare words that look like CLI verbs.
  case "$name" in
    help|version) return 1 ;;
  esac

  return 0
}

# Issue #598 Track 4: test-artifact name patterns. Cleanup detectors and
# operator hygiene depend on this list staying canonical between `agent
# create` / dynamic-spawn refusal and the future `orphan-agent-dir`
# detector (Track 2). Keep BRIDGE_TEST_ARTIFACT_PREFIXES + the trailing
# `-repro-<digits>` regex in lockstep with `bridge-doctor.py` if/when
# Track 2 lands.
BRIDGE_TEST_ARTIFACT_PREFIXES=(
  "smoke-"
  "test-"
  "bootstrap-"
  "created-agent-"
  "pref-"
)

# bridge_validate_agent_name_test_artifact <name>
#   Returns 0 when the name matches a known test-artifact pattern (a
#   leading prefix from BRIDGE_TEST_ARTIFACT_PREFIXES OR a trailing
#   `-repro-<digits>` suffix). Returns 1 otherwise. Callers use this to
#   refuse `create` / dynamic-spawn unless `--test-fixture` is passed.
bridge_validate_agent_name_test_artifact() {
  local name="$1"
  local prefix
  for prefix in "${BRIDGE_TEST_ARTIFACT_PREFIXES[@]}"; do
    if [[ "$name" == "$prefix"* ]]; then
      return 0
    fi
  done
  if [[ "$name" =~ -repro-[0-9]+$ ]]; then
    return 0
  fi
  return 1
}

bridge_join_quoted() {
  local out=""
  local arg
  local quoted

  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    out+="${out:+ }${quoted}"
  done

  printf '%s' "$out"
}

bridge_export_env_prefix() {
  local out=""
  local name
  local value
  local quoted
  local names=(
    BRIDGE_BASH_BIN
    BRIDGE_HOME
    BRIDGE_ROSTER_FILE
    BRIDGE_ROSTER_LOCAL_FILE
    BRIDGE_STATE_DIR
    # NOTE 2026-05-16 (patch ticket #4725): BRIDGE_LAYOUT and
    # BRIDGE_DATA_ROOT were intentionally REMOVED from this prefix.
    # On a v2-migrated install, the marker at state/layout-marker.sh
    # is the source of truth — children re-resolve via the resolver
    # at startup. When this prefix was re-exporting the parent's
    # potentially-stale BRIDGE_LAYOUT, every spawned child inherited
    # the legacy value and triggered the
    # `BRIDGE_LAYOUT=legacy is a stale pre-v0.8.0 env override; …
    # Preferring marker.` warning on every CLI invocation — visible
    # to the operator dozens of times per command output. The
    # underlying resolver behavior is correct (marker wins); the
    # noise was self-inflicted by re-propagating the demoted value
    # into the child shell. Dropping these two names lets the child
    # resolver compute the layout cleanly.
    BRIDGE_LAYOUT_MARKER_DIR
    BRIDGE_ACTIVE_AGENT_DIR
    BRIDGE_HISTORY_DIR
    BRIDGE_WORKTREE_META_DIR
    BRIDGE_ACTIVE_ROSTER_TSV
    BRIDGE_ACTIVE_ROSTER_MD
    BRIDGE_DAEMON_PID_FILE
    BRIDGE_DAEMON_LOG
    BRIDGE_DAEMON_INTERVAL
    BRIDGE_TASK_DB
    BRIDGE_PROFILE_STATE_DIR
    BRIDGE_DISCORD_RELAY_STATE_FILE
    BRIDGE_WORKTREE_ROOT
    BRIDGE_RUNTIME_ROOT
    BRIDGE_RUNTIME_SCRIPTS_DIR
    BRIDGE_RUNTIME_SKILLS_DIR
    BRIDGE_RUNTIME_SHARED_DIR
    BRIDGE_RUNTIME_SHARED_TOOLS_DIR
    BRIDGE_RUNTIME_SHARED_REFERENCES_DIR
    BRIDGE_RUNTIME_MEMORY_DIR
    BRIDGE_RUNTIME_CREDENTIALS_DIR
    BRIDGE_RUNTIME_SECRETS_DIR
    BRIDGE_RUNTIME_CONFIG_FILE
    BRIDGE_LOG_DIR
    BRIDGE_SHARED_DIR
    BRIDGE_TASK_NOTE_DIR
    BRIDGE_TASK_LEASE_SECONDS
    BRIDGE_TASK_IDLE_NUDGE_SECONDS
    BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS
    BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS
    BRIDGE_ON_DEMAND_IDLE_SECONDS
    BRIDGE_DISCORD_RELAY_ENABLED
    BRIDGE_DISCORD_RELAY_ACCOUNT
    BRIDGE_DISCORD_RELAY_POLL_LIMIT
    BRIDGE_DISCORD_RELAY_COOLDOWN_SECONDS
    BRIDGE_CODEX_TASK_MODE_POLICY
    BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE
    # v0.8.0 T5: rollback hatch must propagate from the controller env
    # into the per-agent SESSION_CMD child so bridge-run.sh sees the
    # same value the daemon does (otherwise the wrap-skip logic would
    # fire only at start time, not on subsequent runtime restarts).
    BRIDGE_DISABLE_ISOLATION
  )

  for name in "${names[@]}"; do
    [[ -n "${!name+x}" ]] || continue
    value="${!name}"
    printf -v quoted '%q' "$value"
    out+="${out:+ }${name}=${quoted}"
  done

  printf '%s' "$out"
}

bridge_project_root_for_path() {
  local path="$1"

  # Callers iterate every registered agent's workdir; a stale registration whose
  # directory has been removed (deleted repo, expired worktree, renamed home)
  # must not abort the enumeration nor leak `cd: No such file or directory`
  # noise to operator stderr. Return the registered path verbatim when it is
  # missing — that is what the caller would have shown anyway. See issue #305.
  if [[ -z "$path" || ! -d "$path" ]]; then
    printf '%s' "$path"
    return 0
  fi

  if git -C "$path" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$path" rev-parse --show-toplevel | sed 's#/*$##'
    return 0
  fi

  (cd "$path" 2>/dev/null && pwd -P) || printf '%s' "$path"
}

bridge_compat_config_file() {
  if [[ -f "$BRIDGE_RUNTIME_CONFIG_FILE" ]]; then
    printf '%s' "$BRIDGE_RUNTIME_CONFIG_FILE"
    return 0
  fi
  printf '%s/openclaw.json' "$BRIDGE_LEGACY_HOME"
}

bridge_compat_credentials_dir() {
  if [[ -d "$BRIDGE_RUNTIME_CREDENTIALS_DIR" ]]; then
    printf '%s' "$BRIDGE_RUNTIME_CREDENTIALS_DIR"
    return 0
  fi
  printf '%s/credentials' "$BRIDGE_LEGACY_HOME"
}

bridge_compat_secrets_dir() {
  if [[ -d "$BRIDGE_RUNTIME_SECRETS_DIR" ]]; then
    printf '%s' "$BRIDGE_RUNTIME_SECRETS_DIR"
    return 0
  fi
  printf '%s/secrets' "$BRIDGE_LEGACY_HOME"
}

bridge_path_relative_to_root() {
  local path="$1"
  local root="$2"

  bridge_require_python
  python3 - "$path" "$root" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
root = os.path.realpath(sys.argv[2])

try:
    rel = os.path.relpath(path, root)
except Exception:
    rel = "."

print(rel)
PY
}

bridge_path_is_within_root() {
  local path="$1"
  local root="$2"

  bridge_require_python
  python3 - "$path" "$root" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
root = os.path.realpath(sys.argv[2])

try:
    common = os.path.commonpath([path, root])
except ValueError:
    print("0")
    raise SystemExit(0)

print("1" if common == root else "0")
PY
}

bridge_history_key_for() {
  local engine="$1"
  local name="$2"
  local workdir="$3"
  bridge_sha1 "${engine}|${name}|${workdir}"
}

bridge_history_file_for() {
  local engine="$1"
  local name="$2"
  local workdir="$3"
  local key

  # v2 layout: history.env lives inside the per-agent runtime root
  # rather than in BRIDGE_HISTORY_DIR. Format stays shell-env (KEY=VALUE)
  # so the existing readers/writers (`source` in
  # bridge_load_static_agent_history, shell assignments in
  # bridge_write_agent_state_file, the session-id rewrite path) work
  # without a format migration. Only the location changes.
  if bridge_isolation_v2_active && [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" && -n "$name" ]]; then
    printf '%s/%s/runtime/history.env' "$BRIDGE_AGENT_ROOT_V2" "$name"
    return 0
  fi
  key="$(bridge_history_key_for "$engine" "$name" "$workdir")"
  printf '%s/%s--%s--%s.env' "$BRIDGE_HISTORY_DIR" "$name" "$engine" "$key"
}

bridge_dynamic_agent_file_for() {
  local name="$1"
  printf '%s/%s.env' "$BRIDGE_ACTIVE_AGENT_DIR" "$name"
}
