#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

bridge_die() {
  echo -e "${RED}[오류] $*${NC}" >&2
  exit 1
}

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
  match="$(python3 - "$unknown" "$valid_list" <<'PY'
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
PY
  )"

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
  python3 "$BRIDGE_SCRIPT_DIR/bridge-queue-gateway.py" verify-runtime --bridge-home "$BRIDGE_HOME"
}

bridge_queue_gateway_runtime_ensure() {
  bridge_require_python
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
  if bridge_isolation_v2_active && [[ -n "$BRIDGE_AGENT_ROOT_V2" ]]; then
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
    BRIDGE_LAYOUT
    BRIDGE_DATA_ROOT
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
  if bridge_isolation_v2_active && [[ -n "$BRIDGE_AGENT_ROOT_V2" && -n "$name" ]]; then
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
