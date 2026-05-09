#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

bridge_agent_next_session_file() {
  local agent="$1"
  printf '%s/NEXT-SESSION.md' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_claude_effective_engine_continue() {
  local agent="$1"
  local onboarding_state=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1
  [[ "$(bridge_agent_continue "$agent")" == "1" ]] || return 1
  onboarding_state="$(bridge_agent_onboarding_state "$agent")"
  if [[ "$onboarding_state" != "complete" ]]; then
    [[ "$onboarding_state" == "missing" ]] && ! bridge_agent_is_admin "$agent" || return 1
  fi
  bridge_agent_channel_setup_complete "$agent" || return 1
  [[ ! -f "$(bridge_agent_next_session_file "$agent")" ]] || return 1
  return 0
}

# Joins the argv for a `claude` launch from the dynamic builders, honoring the
# per-agent model / effort / permission_mode roster fields. When all three are
# unset (or permission_mode is explicitly "legacy") the output is byte-for-byte
# the historical shape so pre-issue-#72 rosters keep launching unchanged.
#
# Args:
#   $1 — agent id
#   $2 — effective_continue (0/1)
#   $3 — continue_fallback  (0/1)
#   $4 — session_id (may be empty)
bridge_claude_dynamic_launch_cmd() {
  local agent="$1"
  local effective_continue="$2"
  local continue_fallback="$3"
  local session_id="$4"
  local model effort pm
  local -a argv=(claude)

  if [[ "$effective_continue" == "1" && -n "$session_id" ]]; then
    argv+=(--resume "$session_id")
  elif [[ "$continue_fallback" == "1" ]]; then
    argv+=(--continue)
  fi

  if bridge_agent_uses_legacy_launch_flags "$agent"; then
    argv+=(--dangerously-skip-permissions --name "$agent")
  else
    model="$(bridge_agent_model "$agent")"
    effort="$(bridge_agent_effort "$agent")"
    pm="$(bridge_agent_permission_mode "$agent")"
    [[ -n "$model" ]] || model="claude-opus-4-7"
    [[ -n "$effort" ]] || effort="xhigh"
    [[ -n "$pm" ]] || pm="auto"
    argv+=(--model "$model" --effort "$effort" --permission-mode "$pm" --name "$agent")
  fi

  bridge_join_quoted "${argv[@]}"
}

bridge_build_dynamic_launch_cmd() {
  local agent="$1"
  local engine continue_mode session_id continue_fallback effective_continue

  engine="$(bridge_agent_engine "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  continue_fallback=0
  effective_continue=0
  if [[ "$engine" == "claude" ]]; then
    if bridge_agent_claude_effective_engine_continue "$agent"; then
      effective_continue=1
      session_id="$(bridge_claude_resume_session_id_for_agent "$agent" || true)"
    else
      session_id=""
    fi
    if [[ "$effective_continue" == "1" && -z "$session_id" ]]; then
      if bridge_claude_has_resumable_session_state "$(bridge_agent_workdir "$agent")"; then
        continue_fallback=1
      else
        bridge_warn "Claude agent '$agent' has continue=1 but no resumable session yet (first wake); launching fresh."
        bridge_audit_log state claude_session_resume_skipped_first_wake "$agent" \
          --field "continue_mode=$continue_mode" \
          --field "reason=no_transcript" \
          2>/dev/null || true
      fi
    fi
  else
    bridge_normalize_agent_session_id "$agent"
    session_id="$(bridge_agent_session_id "$agent")"
  fi

  case "$engine" in
    codex)
      if [[ "$continue_mode" == "1" && -n "$session_id" ]]; then
        bridge_join_quoted codex resume "$session_id" -c "features.codex_hooks=true" -c "features.fast_mode=true" --dangerously-bypass-approvals-and-sandbox --no-alt-screen
      else
        bridge_join_quoted codex -c "features.codex_hooks=true" -c "features.fast_mode=true" --dangerously-bypass-approvals-and-sandbox --no-alt-screen
      fi
      ;;
    claude)
      # The fresh-session branch is now only reachable when continue_mode=0
      # in the roster, or when effective_continue was gated by onboarding /
      # channel setup / NEXT-SESSION.md. continue_fallback above makes every
      # "continue intended but no session_id" case go through --continue, so
      # the silent-drift warning from issue #71 cannot fire in practice.
      # Kept as a defensive emit for the onboarding-gate case so operators
      # still see why a static agent restarted fresh.
      if [[ "$continue_mode" == "1" && "$effective_continue" != "1" ]]; then
        bridge_warn "Claude agent '$agent' has continue=1 but effective_continue is 0 (onboarding/channel/NEXT-SESSION gate); launching fresh."
        bridge_audit_log state claude_session_resume_blocked_by_gate "$agent" \
          --field "continue_mode=$continue_mode" \
          --field "effective_continue=$effective_continue" \
          2>/dev/null || true
      fi
      bridge_claude_dynamic_launch_cmd "$agent" "$effective_continue" "$continue_fallback" "$session_id"
      ;;
    *)
      printf '%s' "${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
      ;;
  esac
}

bridge_build_resume_launch_cmd() {
  local agent="$1"
  local engine continue_mode session_id
  local original_cmd=""
  local env_prefix=""
  local channels_flag=""
  local resume_cmd=""

  engine="$(bridge_agent_engine "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  if [[ "$engine" == "claude" ]] && ! bridge_agent_claude_effective_engine_continue "$agent"; then
    return 1
  fi
  bridge_normalize_agent_session_id "$agent"
  session_id="$(bridge_agent_session_id "$agent")"

  if [[ "$continue_mode" != "1" || -z "$session_id" ]]; then
    return 1
  fi

  case "$engine" in
    codex)
      bridge_join_quoted codex resume "$session_id" -c "features.codex_hooks=true" -c "features.fast_mode=true" --dangerously-bypass-approvals-and-sandbox --no-alt-screen
      ;;
    claude)
      original_cmd="${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
      if [[ "$original_cmd" =~ ^([A-Z_]+=[^ ]+[[:space:]]+)+ ]]; then
        env_prefix="${BASH_REMATCH[0]}"
      fi
      if [[ "$original_cmd" == *"--channels "* ]]; then
        channels_flag="$(printf '%s' "$original_cmd" | grep -oE -- '--channels [^ ]+' || true)"
      fi
      resume_cmd="$(bridge_claude_dynamic_launch_cmd "$agent" 1 0 "$session_id")"
      if [[ -n "$channels_flag" ]]; then
        resume_cmd="${resume_cmd} ${channels_flag//$'\n'/ }"
      fi
      if [[ -n "$env_prefix" ]]; then
        printf '%s%s' "$env_prefix" "$resume_cmd"
      else
        printf '%s' "$resume_cmd"
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_clear_agent_session_id() {
  local agent="$1"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
  bridge_persist_agent_state "$agent"
}

bridge_claude_resume_session_id_for_agent() {
  local agent="$1"
  local session_id=""
  local detected=""
  local workdir=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1

  workdir="$(bridge_agent_workdir "$agent")"

  bridge_normalize_agent_session_id "$agent"
  session_id="$(bridge_agent_session_id "$agent")"
  if [[ -n "$session_id" ]]; then
    printf '%s' "$session_id"
    return 0
  fi

  # Fallback: detect a transcript by workdir, age-bounded by the resume
  # window. Without this gate the same stale transcript that bridge_normalize
  # just rejected would be re-discovered (the original `agb admin` incident).
  local _max_hours_int="${BRIDGE_RESUME_MAX_AGE_HOURS:-48}"
  _max_hours_int="${_max_hours_int%.*}"
  [[ "$_max_hours_int" =~ ^[0-9]+$ ]] || _max_hours_int=48
  local _since_ms=$(( ($(date +%s) - _max_hours_int * 3600) * 1000 ))
  detected="$(bridge_detect_claude_session_id "$workdir" "$_since_ms" "" 2>/dev/null || true)"
  [[ -n "$detected" ]] || return 1
  # Belt-and-suspenders: round-trip through the resolver so a missed slug or
  # detection-side regression cannot reintroduce a stale id past this point.
  local _accepted="" _rc=0
  _accepted="$(bridge_resolve_resume_session_id claude "$agent" "$workdir" "$detected" 2>/dev/null)" || _rc=$?
  [[ "$_rc" != 1 && -n "$_accepted" ]] || return 1
  printf '%s' "$_accepted"
}

bridge_normalize_agent_session_id() {
  local agent="$1"
  local engine=""
  local workdir=""
  local session_id=""

  engine="$(bridge_agent_engine "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  session_id="$(bridge_agent_session_id "$agent")"
  [[ -n "$session_id" ]] || return 0

  case "$engine" in
    claude)
      # Decision site: resolver may keep (rc=0), replace (rc=2), or reject (rc=1).
      # rc=2 swaps in a fresher in-window transcript for the same workdir;
      # we persist that replacement here, since hydration sites intentionally
      # do not write state.
      local _accepted="" _rc=0
      _accepted="$(bridge_resolve_resume_session_id claude "$agent" "$workdir" "$session_id")" || _rc=$?
      case "$_rc" in
        0)
          ;;
        2)
          BRIDGE_AGENT_SESSION_ID["$agent"]="$_accepted"
          bridge_persist_agent_state "$agent"
          ;;
        *)
          bridge_clear_agent_session_id "$agent"
          return 0
          ;;
      esac
      ;;
  esac
}

bridge_codex_launch_with_hooks() {
  local original="$1"

  python3 - "$original" <<'PY'
import re
import shlex
import sys

original = sys.argv[1]
match = re.match(r"^(?P<prefix>.*?)(?P<command>codex(?:\s|$).*)$", original)
if not match:
    print(original)
    raise SystemExit(0)

env_prefix = match.group("prefix")
args = shlex.split(match.group("command"))
if not args or args[0] != "codex":
    print(original)
    raise SystemExit(0)

# v0.8.6 hotfix: this helper now ensures BOTH `codex_hooks` and
# `fast_mode` are pinned on every codex launch — admin-pair backfill,
# isolated agent create, v0.7→v0.8 migration, and resume paths all
# converge through here. Pre-hotfix it only injected `codex_hooks`,
# so an existing roster with the legacy default launch_cmd (no
# fast_mode) silently fell off the fast inference path on every
# wake. The injection is idempotent: if a flag is already present
# (via `--enable <name>`, `-c features.<name>=true`, or any later
# `-c features.<name>=...` form) the helper leaves it alone.
REQUIRED_FEATURES = ("codex_hooks", "fast_mode")
ARG_TAKING_FLAGS = {
    "-c", "--enable", "--disable", "--profile", "-p",
    "--model", "-m", "--cd", "-C",
}

def has_feature(rest: list[str], feature: str) -> bool:
    pattern = f"features.{feature}=true"
    i = 0
    while i < len(rest):
        token = rest[i]
        next_value = rest[i + 1] if i + 1 < len(rest) else None
        if token == "--enable" and next_value == feature:
            return True
        if token == "-c" and next_value is not None and pattern in next_value:
            return True
        i += 2 if token in ARG_TAKING_FLAGS and next_value is not None else 1
    return False

rest = args[1:]
prefix_pairs: list[str] = []
for feature in REQUIRED_FEATURES:
    if not has_feature(rest, feature):
        prefix_pairs.extend(["-c", f"features.{feature}=true"])

if prefix_pairs:
    rest = [*prefix_pairs, *rest]

quoted = " ".join(shlex.quote(token) for token in [args[0], *rest])
print(f"{env_prefix}{quoted}" if env_prefix else quoted)
PY
}

bridge_claude_launch_with_channels() {
  local agent="$1"
  local original="$2"
  local required=""

  required="$(bridge_agent_launch_channels_csv "$agent")"
  if [[ -z "$required" ]]; then
    printf '%s' "$original"
    return 0
  fi

  bridge_require_python
  python3 - "$original" "$required" <<'PY'
import re
import shlex
import sys

original, required_csv = sys.argv[1:]

def normalize(raw: str):
    values = []
    seen = set()
    for chunk in raw.split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        values.append(item)
    return values

required = normalize(required_csv)
if not required:
    print(original)
    raise SystemExit(0)

match = re.match(r"^(?P<prefix>.*?)(?P<command>claude(?:\s|$).*)$", original)
if not match:
    print(original)
    raise SystemExit(0)

env_prefix = match.group("prefix")
args = shlex.split(match.group("command"))
if not args or args[0] != "claude":
    print(original)
    raise SystemExit(0)

rest = args[1:]
existing = []
filtered = []
i = 0
while i < len(rest):
    token = rest[i]
    if token == "--channels" and i + 1 < len(rest):
        existing.extend(normalize(rest[i + 1]))
        i += 2
        continue
    if token.startswith("--channels="):
        existing.extend(normalize(token.split("=", 1)[1]))
        i += 1
        continue
    filtered.append(token)
    i += 1

merged = []
seen = set()
for item in [*existing, *required]:
    if item in seen:
        continue
    seen.add(item)
    merged.append(item)

rebuilt = ["claude", *filtered]
for item in merged:
    rebuilt.extend(["--channels", item])

quoted = " ".join(shlex.quote(token) for token in rebuilt)
print(f"{env_prefix}{quoted}" if env_prefix else quoted)
PY
}

bridge_claude_launch_with_development_channels() {
  local original="$1"
  local required_csv="${2:-}"

  if [[ -z "$required_csv" ]]; then
    printf '%s' "$original"
    return 0
  fi

  bridge_require_python
  python3 - "$original" "$required_csv" <<'PY'
import re
import shlex
import sys

original, required_csv = sys.argv[1:]

def normalize(raw: str):
    values = []
    seen = set()
    for chunk in raw.split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        values.append(item)
    return values

required = normalize(required_csv)
if not required:
    print(original)
    raise SystemExit(0)

match = re.match(r"^(?P<prefix>.*?)(?P<command>claude(?:\s|$).*)$", original)
if not match:
    print(original)
    raise SystemExit(0)

env_prefix = match.group("prefix")
args = shlex.split(match.group("command"))
if not args or args[0] != "claude":
    print(original)
    raise SystemExit(0)

rest = args[1:]
existing = []
filtered = []
i = 0
while i < len(rest):
    token = rest[i]
    if token == "--dangerously-load-development-channels":
        i += 1
        while i < len(rest) and not rest[i].startswith("-"):
            existing.extend(normalize(rest[i]))
            i += 1
        continue
    if token.startswith("--dangerously-load-development-channels="):
        existing.extend(normalize(token.split("=", 1)[1]))
        i += 1
        continue
    filtered.append(token)
    i += 1

merged = []
seen = set()
for item in [*existing, *required]:
    if item in seen:
        continue
    seen.add(item)
    merged.append(item)

rebuilt = ["claude", *filtered]
for item in merged:
    rebuilt.extend(["--dangerously-load-development-channels", item])

quoted = " ".join(shlex.quote(token) for token in rebuilt)
print(f"{env_prefix}{quoted}" if env_prefix else quoted)
PY
}

bridge_claude_launch_with_channel_state_dirs() {
  local agent="$1"
  local original="$2"
  local required=""
  local launch_channels=""
  local launch_dev_channels=""
  local discord_dir=""
  local telegram_dir=""
  local teams_dir=""

  required="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
  launch_channels="$(bridge_extract_channels_from_command "$original")"
  launch_dev_channels="$(bridge_extract_development_channels_from_command "$original")"
  required="$(bridge_merge_channels_csv "$required" "$launch_channels")"
  required="$(bridge_merge_channels_csv "$required" "$launch_dev_channels")"
  required="$(bridge_filter_claude_plugin_channels_csv "$required")"
  if [[ -z "$required" ]]; then
    printf '%s' "$original"
    return 0
  fi

  discord_dir="$(bridge_agent_discord_state_dir "$agent")"
  telegram_dir="$(bridge_agent_telegram_state_dir "$agent")"
  teams_dir="$(bridge_agent_teams_state_dir "$agent")"

  bridge_require_python
  python3 - "$original" "$required" "$discord_dir" "$telegram_dir" "$teams_dir" <<'PY'
import re
import shlex
import sys

original, required_csv, discord_dir, telegram_dir, teams_dir = sys.argv[1:]

def normalize(raw: str):
    values = []
    seen = set()
    for chunk in raw.split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        values.append(item)
    return values

required = normalize(required_csv)
if not required:
    print(original)
    raise SystemExit(0)

match = re.match(r"^(?P<prefix>.*?)(?P<command>claude(?:\s|$).*)$", original)
if not match:
    print(original)
    raise SystemExit(0)

env_prefix = match.group("prefix")
command = match.group("command")
assignments = []

if any(item == "plugin:discord" or item.startswith("plugin:discord@") for item in required):
    assignments.append(("DISCORD_STATE_DIR", discord_dir))
if any(
    item == "plugin:telegram"
    or item.startswith("plugin:telegram@")
    for item in required
):
    assignments.append(("TELEGRAM_STATE_DIR", telegram_dir))
if any(item == "plugin:teams" or item.startswith("plugin:teams@") for item in required):
    assignments.append(("TEAMS_STATE_DIR", teams_dir))

# Issue #771 v0.9.6 — operator's R5 diagnostic confirmed PRIMARY fix
# (v0.9.5 PR #774 `agent_env_regen`) was a false-positive: the regen
# correctly re-invokes this helper, but the helper's loop SKIPS any
# assignment whose name (`<NAME>=`) is already present in env_prefix
# regardless of the value. So a frozen-roster LAUNCH_CMD with stale
# `TEAMS_STATE_DIR=…/agents/<X>/.teams` (pre-v2 path) is NEVER
# replaced — the helper sees the name, skips, and the same stale
# value rides through every restart. Fresh-setup agents (no existing
# assignment) work correctly because the append branch fires; legacy
# v0.7→v0.8 isolated agents stay broken indefinitely. v0.9.5
# orbstack validation only exercised the fresh-setup case.
#
# Fix: regex-match the existing assignment for each name and REPLACE
# its value with the canonical (live-computed) one. Idempotent in
# the fresh case (regex doesn't match → falls through to append) and
# correct in the stale case (regex matches → in-place replace).
# Pattern allows shell-quoted values (single-quoted, double-quoted,
# or unquoted whitespace-bounded) so it survives roster-side hand
# edits and `printf '%q'` outputs from prior writers.
def _skip_dquote(s, i, n):
    # i points just AFTER opening `"`. Walks to closing `"` while
    # honoring backslash escapes and nested expansions (`$(…)`, `${…}`,
    # backticks). Returns index just AFTER the closing `"`.
    while i < n and s[i] != '"':
        c = s[i]
        if c == "\\" and i + 1 < n:
            i += 2
        elif c == "$" and i + 1 < n and s[i + 1] == "(":
            i = _skip_paren_subst(s, i + 2, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "{":
            i = _skip_brace_subst(s, i + 2, n)
        elif c == "`":
            i = _skip_backtick(s, i + 1, n)
        else:
            i += 1
    if i < n:
        i += 1
    return i


def _skip_paren_subst(s, i, n):
    # i points just AFTER opening `$(`. Tracks nested `(` / `)` and
    # quote-state until depth returns to 0. Returns index just AFTER
    # the closing `)`. Whitespace and `=` inside a $(…) substitution
    # MUST NOT split the enclosing token, so the caller treats this
    # span as opaque. (codex r4 review on PR #776 — Probe 14.)
    #
    # r6 codex catch — also honor inner ${…} and `…` so a `)` that
    # belongs to a nested brace-default like `${UNSET:-) NAME=…}` or
    # to a backtick-substitution does NOT prematurely close our
    # paren depth.
    depth = 1
    while i < n and depth > 0:
        c = s[i]
        if c == "(":
            depth += 1
            i += 1
        elif c == ")":
            depth -= 1
            i += 1
        elif c == "'":
            i += 1
            while i < n and s[i] != "'":
                i += 1
            if i < n:
                i += 1
        elif c == '"':
            i = _skip_dquote(s, i + 1, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "(":
            i = _skip_paren_subst(s, i + 2, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "{":
            i = _skip_brace_subst(s, i + 2, n)
        elif c == "`":
            i = _skip_backtick(s, i + 1, n)
        elif c == "\\" and i + 1 < n:
            i += 2
        else:
            i += 1
    return i


def _skip_backtick(s, i, n):
    # i points just AFTER opening backtick. Walks to next backtick;
    # legacy backticks don't nest natively (POSIX requires `\\\``
    # escaping for nesting), so honor backslash escapes only. Inner
    # ${…} and $(…) are NOT treated as nesting boundaries here — the
    # next bare backtick (or escaped pair) closes the span — but the
    # quote-state inside still suppresses any `=` matching at the
    # outer walker level (we never re-enter the walker until we
    # return past the closing backtick). (r6 — kept POSIX-conformant.)
    while i < n and s[i] != "`":
        if s[i] == "\\" and i + 1 < n:
            i += 2
        else:
            i += 1
    if i < n:
        i += 1
    return i


def _skip_brace_subst(s, i, n):
    # i points just AFTER `${`. Walks to matching `}` honoring nested
    # braces, quotes, and inner $(…) / `…` substitutions. Param-
    # expansion defaults can contain whitespace and arbitrary inner
    # constructs (e.g. `${VAR:-$(echo NAME=fake)}` or
    # `${VAR:-some `echo X` default}`), so we must not let an inner
    # space, `}`, or `)` from a nested context split the enclosing
    # token. (r6 codex catch — symmetry with _skip_paren_subst.)
    depth = 1
    while i < n and depth > 0:
        c = s[i]
        if c == "{":
            depth += 1
            i += 1
        elif c == "}":
            depth -= 1
            i += 1
        elif c == "'":
            i += 1
            while i < n and s[i] != "'":
                i += 1
            if i < n:
                i += 1
        elif c == '"':
            i = _skip_dquote(s, i + 1, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "(":
            i = _skip_paren_subst(s, i + 2, n)
        elif c == "$" and i + 1 < n and s[i + 1] == "{":
            i = _skip_brace_subst(s, i + 2, n)
        elif c == "`":
            i = _skip_backtick(s, i + 1, n)
        elif c == "\\" and i + 1 < n:
            i += 2
        else:
            i += 1
    return i


def _walk_top_level_tokens(s):
    # Yield (start, end) byte spans of each whitespace-delimited token
    # in `s`, treating single-quoted, double-quoted, backslash-escaped,
    # `$(…)`, backtick `…`, and `${…}` spans as opaque (so whitespace
    # inside any of these does NOT split the enclosing token).
    # Returning byte spans (not the token string) lets us preserve the
    # original bytes verbatim — critical for keeping bash expansions
    # like `$HOME`, `$(date)`, `${VAR:-x}` unquoted in unrelated
    # env-prefix assignments. (See codex r2/r3/r4 review on PR #776.)
    i, n = 0, len(s)
    while i < n:
        while i < n and s[i] in (" ", "\t"):
            i += 1
        if i >= n:
            return
        start = i
        while i < n and s[i] not in (" ", "\t"):
            c = s[i]
            if c == "'":
                i += 1
                while i < n and s[i] != "'":
                    i += 1
                if i < n:
                    i += 1
            elif c == '"':
                i = _skip_dquote(s, i + 1, n)
            elif c == "$" and i + 1 < n and s[i + 1] == "(":
                i = _skip_paren_subst(s, i + 2, n)
            elif c == "$" and i + 1 < n and s[i + 1] == "{":
                i = _skip_brace_subst(s, i + 2, n)
            elif c == "`":
                i = _skip_backtick(s, i + 1, n)
            elif c == "\\" and i + 1 < n:
                i += 2
            else:
                i += 1
        yield (start, i)


for name, value in assignments:
    # r4 codex review of #776 — preserve original byte form for tokens
    # we are NOT replacing. The r3 shlex.split + shlex.quote round-trip
    # destroyed unquoted shell expansions: `OTHER=$HOME` round-tripped
    # to `OTHER='$HOME'`, which bash then sees as the literal four-char
    # string `$HOME` instead of expanding. Walk the original env_prefix
    # in place, identify only the top-level tokens whose raw byte
    # prefix is `NAME=`, and substitute their span with the canonical
    # `NAME=<shlex.quote(value)>`. All other bytes (whitespace runs,
    # other assignments, their original quoting) pass through verbatim.
    #
    # r2 Probe 8 retained: ALL matching occurrences are replaced. Shell
    # eval is last-definition-wins, so a surviving duplicate after the
    # first replacement would re-overwrite the canonical value. Falling
    # through to append fires only when ZERO top-level matches found
    # (true fresh-setup case).
    #
    # r3 Probe 9 retained: quote-aware walker treats whitespace inside
    # `OTHER="x NAME=/fake"` as belonging to the OTHER token, so the
    # nested `NAME=/fake` substring is never matched at top level.
    quoted_value = shlex.quote(value)
    prefix_form = f"{name}="
    spans = [
        (s_, e_)
        for (s_, e_) in _walk_top_level_tokens(env_prefix)
        if env_prefix[s_:e_].startswith(prefix_form)
    ]
    if spans:
        pieces = []
        last = 0
        for s_, e_ in spans:
            pieces.append(env_prefix[last:s_])
            pieces.append(f"{name}={quoted_value}")
            last = e_
        pieces.append(env_prefix[last:])
        env_prefix = "".join(pieces)
        if env_prefix and not env_prefix.endswith((" ", "\t")):
            env_prefix += " "
    else:
        if env_prefix and not env_prefix.endswith((" ", "\t")):
            env_prefix += " "
        env_prefix += f"{name}={quoted_value} "

print(f"{env_prefix}{command}" if env_prefix else command)
PY
}

bridge_build_static_claude_launch_cmd() {
  local agent="$1"
  local fallback=""
  local continue_mode=""
  local session_id=""
  local continue_fallback=0
  local effective_continue=0

  fallback="${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
  [[ -n "$fallback" ]] || return 1

  continue_mode="$(bridge_agent_continue "$agent")"
  if bridge_agent_claude_effective_engine_continue "$agent"; then
    effective_continue=1
    session_id="$(bridge_claude_resume_session_id_for_agent "$agent" || true)"
    if [[ "$effective_continue" == "1" && -z "$session_id" ]]; then
      if bridge_claude_has_resumable_session_state "$(bridge_agent_workdir "$agent")"; then
        continue_fallback=1
      else
        bridge_warn "Claude agent '$agent' has continue=1 but no resumable session yet (first wake); launching fresh."
        bridge_audit_log state claude_session_resume_skipped_first_wake "$agent" \
          --field "continue_mode=$continue_mode" \
          --field "reason=no_transcript" \
          2>/dev/null || true
      fi
    fi
  fi

  bridge_require_python
  python3 - "$agent" "$continue_mode" "$session_id" "$continue_fallback" "$fallback" <<'PY'
import re
import shlex
import sys

agent, continue_mode, session_id, continue_fallback, original = sys.argv[1:]


def repair_false_command(value: str) -> str:
    try:
        tokens = shlex.split(value)
    except ValueError:
        return value
    if not tokens:
        return value
    idx = 0
    while idx < len(tokens):
        key = tokens[idx].split("=", 1)[0]
        if "=" not in tokens[idx] or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key) or tokens[idx].startswith("-"):
            break
        idx += 1
    if idx < len(tokens) and tokens[idx] == "false":
        tokens[idx] = "claude"
        return " ".join(shlex.quote(token) for token in tokens)
    return value


original = repair_false_command(original)
match = re.match(r"^(?P<prefix>.*?)(?P<command>claude(?:\s|$).*)$", original)
if not match:
    print(original)
    raise SystemExit(0)

env_prefix = match.group("prefix")
args = shlex.split(match.group("command"))
if not args or args[0] != "claude":
    print(original)
    raise SystemExit(0)

rest = args[1:]
extras = []
j = 0
while j < len(rest):
    token = rest[j]
    if token in {"-c", "--continue", "--dangerously-skip-permissions"}:
        j += 1
        continue
    if token in {"--resume", "--name"}:
        j += 2 if j + 1 < len(rest) else 1
        continue
    extras.append(token)
    if token.startswith("--") and j + 1 < len(rest) and not rest[j + 1].startswith("-"):
        extras.append(rest[j + 1])
        j += 2
        continue
    j += 1

base = ["claude"]
if continue_mode == "1" and session_id:
    base.extend(["--resume", session_id])
elif continue_mode == "1" and continue_fallback == "1":
    base.append("--continue")
base.extend(["--dangerously-skip-permissions", "--name", agent])
base.extend(extras)

quoted = " ".join(shlex.quote(token) for token in base)
if env_prefix:
    print(f"{env_prefix}{quoted}")
else:
    print(quoted)
PY
}

bridge_build_safe_claude_launch_cmd() {
  local agent="$1"
  local fallback=""
  local continue_mode=""
  local session_id=""

  fallback="${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
  if [[ -z "$fallback" ]]; then
    fallback="$(bridge_claude_dynamic_launch_cmd "$agent" 0 0 "")"
  fi

  continue_mode="$(bridge_agent_continue "$agent")"
  if [[ "$continue_mode" == "1" ]]; then
    session_id="$(bridge_claude_resume_session_id_for_agent "$agent" 2>/dev/null || true)"
  fi

  bridge_require_python
  python3 - "$agent" "$continue_mode" "$session_id" "$fallback" <<'PY'
import re
import shlex
import sys

agent, continue_mode, session_id, original = sys.argv[1:]


def repair_false_command(value: str) -> str:
    try:
        tokens = shlex.split(value)
    except ValueError:
        return value
    if not tokens:
        return value
    idx = 0
    while idx < len(tokens):
        key = tokens[idx].split("=", 1)[0]
        if "=" not in tokens[idx] or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key) or tokens[idx].startswith("-"):
            break
        idx += 1
    if idx < len(tokens) and tokens[idx] == "false":
        tokens[idx] = "claude"
        return " ".join(shlex.quote(token) for token in tokens)
    return value


original = repair_false_command(original)
match = re.match(r"^(?P<prefix>.*?)(?P<command>claude(?:\s|$).*)$", original)
if not match:
    print(original)
    raise SystemExit(0)

env_prefix = match.group("prefix")
args = shlex.split(match.group("command"))
if not args or args[0] != "claude":
    print(original)
    raise SystemExit(0)

rest = args[1:]
extras = []
i = 0
while i < len(rest):
    token = rest[i]
    if token in {"-c", "--continue", "--dangerously-skip-permissions"}:
        i += 1
        continue
    if token in {"--resume", "--name", "--channels"}:
        i += 2 if i + 1 < len(rest) else 1
        continue
    if token.startswith("--channels="):
        i += 1
        continue
    if token == "--dangerously-load-development-channels":
        i += 1
        while i < len(rest) and not rest[i].startswith("-"):
            i += 1
        continue
    if token.startswith("--dangerously-load-development-channels="):
        i += 1
        continue
    extras.append(token)
    if token.startswith("--") and i + 1 < len(rest) and not rest[i + 1].startswith("-"):
        extras.append(rest[i + 1])
        i += 2
        continue
    i += 1

base = ["claude"]
if continue_mode == "1" and session_id:
    base.extend(["--resume", session_id])
elif continue_mode == "1":
    base.append("--continue")
base.extend(["--dangerously-skip-permissions", "--name", agent])
base.extend(extras)

quoted = " ".join(shlex.quote(token) for token in base)
if env_prefix:
    print(f"{env_prefix}{quoted}")
else:
    print(quoted)
PY
}

bridge_safe_mode_resume_mode() {
  local agent="$1"
  local engine=""
  local session_id=""

  [[ "$(bridge_agent_continue "$agent")" == "1" ]] || {
    printf '%s' "fresh"
    return 0
  }

  engine="$(bridge_agent_engine "$agent")"
  case "$engine" in
    claude)
      session_id="$(bridge_claude_resume_session_id_for_agent "$agent" 2>/dev/null || true)"
      if [[ -n "$session_id" ]]; then
        printf '%s' "resume"
      else
        printf '%s' "continue"
      fi
      ;;
    codex)
      bridge_normalize_agent_session_id "$agent"
      session_id="$(bridge_agent_session_id "$agent")"
      if [[ -n "$session_id" ]]; then
        printf '%s' "resume"
      else
        printf '%s' "fresh"
      fi
      ;;
    *)
      printf '%s' "fresh"
      ;;
  esac
}

bridge_build_safe_launch_cmd() {
  local agent="$1"
  local engine=""
  local launch_cmd=""

  engine="$(bridge_agent_engine "$agent")"
  case "$engine" in
    claude)
      bridge_build_safe_claude_launch_cmd "$agent"
      ;;
    codex)
      if launch_cmd="$(bridge_build_resume_launch_cmd "$agent")"; then
        bridge_codex_launch_with_hooks "$launch_cmd"
      else
        launch_cmd="$(bridge_build_dynamic_launch_cmd "$agent")"
        bridge_codex_launch_with_hooks "$launch_cmd"
      fi
      ;;
    *)
      printf '%s' "${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
      ;;
  esac
}

bridge_agent_launch_cmd() {
  local agent="$1"
  local fallback=""
  local launch_cmd=""
  local engine=""

  engine="$(bridge_agent_engine "$agent")"
  if [[ "$engine" == "claude" ]]; then
    bridge_normalize_agent_session_id "$agent"
  fi

  if [[ "$(bridge_agent_source "$agent")" == "dynamic" ]]; then
    if launch_cmd="$(bridge_build_resume_launch_cmd "$agent")"; then
      if [[ "$engine" == "codex" ]]; then
        launch_cmd="$(bridge_codex_launch_with_hooks "$launch_cmd")"
      elif [[ "$engine" == "claude" ]]; then
        launch_cmd="$(bridge_claude_launch_with_channels "$agent" "$launch_cmd")"
        launch_cmd="$(bridge_claude_launch_with_development_channels "$launch_cmd" "$(bridge_agent_required_dev_channels_csv "$agent")")"
        launch_cmd="$(bridge_claude_launch_with_channel_state_dirs "$agent" "$launch_cmd")"
      fi
      launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$launch_cmd")"
      printf '%s' "$launch_cmd"
      return 0
    fi
    launch_cmd="$(bridge_build_dynamic_launch_cmd "$agent")"
    if [[ "$engine" == "codex" ]]; then
      launch_cmd="$(bridge_codex_launch_with_hooks "$launch_cmd")"
    elif [[ "$engine" == "claude" ]]; then
      launch_cmd="$(bridge_claude_launch_with_channels "$agent" "$launch_cmd")"
      launch_cmd="$(bridge_claude_launch_with_development_channels "$launch_cmd" "$(bridge_agent_required_dev_channels_csv "$agent")")"
      launch_cmd="$(bridge_claude_launch_with_channel_state_dirs "$agent" "$launch_cmd")"
    fi
    launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$launch_cmd")"
    printf '%s' "$launch_cmd"
    return 0
  fi

  fallback="${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
  if [[ "$engine" == "claude" ]] && launch_cmd="$(bridge_build_static_claude_launch_cmd "$agent")"; then
    launch_cmd="$(bridge_claude_launch_with_channels "$agent" "$launch_cmd")"
    launch_cmd="$(bridge_claude_launch_with_development_channels "$launch_cmd" "$(bridge_agent_required_dev_channels_csv "$agent")")"
    launch_cmd="$(bridge_claude_launch_with_channel_state_dirs "$agent" "$launch_cmd")"
    launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$launch_cmd")"
    printf '%s' "$launch_cmd"
    return 0
  fi
  if launch_cmd="$(bridge_build_resume_launch_cmd "$agent")"; then
    if [[ "$(bridge_agent_engine "$agent")" == "codex" ]]; then
      launch_cmd="$(bridge_codex_launch_with_hooks "$launch_cmd")"
    elif [[ "$(bridge_agent_engine "$agent")" == "claude" ]]; then
      launch_cmd="$(bridge_claude_launch_with_channels "$agent" "$launch_cmd")"
      launch_cmd="$(bridge_claude_launch_with_development_channels "$launch_cmd" "$(bridge_agent_required_dev_channels_csv "$agent")")"
      launch_cmd="$(bridge_claude_launch_with_channel_state_dirs "$agent" "$launch_cmd")"
    fi
    launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$launch_cmd")"
    printf '%s' "$launch_cmd"
    return 0
  fi

  if [[ "$(bridge_agent_engine "$agent")" == "codex" ]]; then
    fallback="$(bridge_codex_launch_with_hooks "$fallback")"
  elif [[ "$(bridge_agent_engine "$agent")" == "claude" ]]; then
    fallback="$(bridge_claude_launch_with_channels "$agent" "$fallback")"
    fallback="$(bridge_claude_launch_with_development_channels "$fallback" "$(bridge_agent_required_dev_channels_csv "$agent")")"
    fallback="$(bridge_claude_launch_with_channel_state_dirs "$agent" "$fallback")"
  fi
  launch_cmd="$(bridge_claude_launch_with_webhook "$agent" "$fallback")"
  printf '%s' "$launch_cmd"
}

bridge_load_dynamic_agent_file() {
  local file="$1"
  local AGENT_ID=""
  local AGENT_DESC=""
  local AGENT_ENGINE=""
  local AGENT_SESSION=""
  local AGENT_WORKDIR=""
  local AGENT_LOOP=""
  local AGENT_CONTINUE=""
  local AGENT_SESSION_ID=""
  local AGENT_HISTORY_KEY=""
  local AGENT_CREATED_AT=""
  local AGENT_UPDATED_AT=""

  # shellcheck source=/dev/null
  source "$file"

  if [[ -z "$AGENT_ID" || -z "$AGENT_ENGINE" || -z "$AGENT_SESSION" || -z "$AGENT_WORKDIR" ]]; then
    return 0
  fi

  if bridge_agent_exists "$AGENT_ID" && [[ "$(bridge_agent_source "$AGENT_ID")" == "static" ]]; then
    # Static-agent collision: an active dynamic env file points at an
    # already-registered static agent. Gate the candidate id through the
    # freshness resolver (mirrors the dynamic-load branch below) so a stale
    # on-disk transcript cannot leak in here. Without this gate the raw
    # AGENT_SESSION_ID from the env file would survive and be written back
    # by later start/isolation setup before bridge-run normalises — that
    # is the bypass dev-codex flagged in the round-4 review of #428.
    #
    # rc=other clears, NOT preserves: bridge_load_roster runs
    # bridge_load_dynamic_agents BEFORE bridge_load_static_histories
    # (lib/bridge-state.sh:1257 vs :1267), so any pre-existing
    # BRIDGE_AGENT_SESSION_ID at this point is the raw roster/local value
    # that has not been gated yet. Preserving it would leak a stale id
    # from the roster on top of rejecting the env candidate. Clearing
    # here is safe — bridge_load_static_agent_history runs later, also
    # gated through the resolver, and is the authoritative re-hydration
    # for static agents. Caught in dev-codex review of round 5 (#446).
    local _accepted="" _rc=0
    _accepted="$(bridge_resolve_resume_session_id "$AGENT_ENGINE" "${AGENT_ID:-}" "$AGENT_WORKDIR" "${AGENT_SESSION_ID:-}" 2>/dev/null)" || _rc=$?
    case "$_rc" in
      0|2) BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="$_accepted" ;;
      *)   BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="" ;;
    esac
    BRIDGE_AGENT_HISTORY_KEY["$AGENT_ID"]="${AGENT_HISTORY_KEY:-${BRIDGE_AGENT_HISTORY_KEY[$AGENT_ID]-}}"
    BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]="${AGENT_CREATED_AT:-${BRIDGE_AGENT_CREATED_AT[$AGENT_ID]-}}"
    BRIDGE_AGENT_UPDATED_AT["$AGENT_ID"]="${AGENT_UPDATED_AT:-${BRIDGE_AGENT_UPDATED_AT[$AGENT_ID]-}}"
    return 0
  fi

  bridge_add_agent_id_if_missing "$AGENT_ID"
  BRIDGE_AGENT_DESC["$AGENT_ID"]="${AGENT_DESC:-$AGENT_ID}"
  BRIDGE_AGENT_ENGINE["$AGENT_ID"]="$AGENT_ENGINE"
  BRIDGE_AGENT_SESSION["$AGENT_ID"]="$AGENT_SESSION"
  BRIDGE_AGENT_WORKDIR["$AGENT_ID"]="$AGENT_WORKDIR"
  BRIDGE_AGENT_SOURCE["$AGENT_ID"]="dynamic"
  BRIDGE_AGENT_META_FILE["$AGENT_ID"]="$file"
  # Issue #598 Track 1: tag provenance so `agent registry --json` can
  # report which loader made this id known.
  BRIDGE_AGENT_PROVENANCE["$AGENT_ID"]="dynamic-active-env"
  BRIDGE_AGENT_LOOP["$AGENT_ID"]="${AGENT_LOOP:-1}"
  BRIDGE_AGENT_CONTINUE["$AGENT_ID"]="${AGENT_CONTINUE:-1}"
  # Hydration: gate the stored id through the freshness resolver. rc=0 keeps
  # the candidate, rc=2 swaps in a fresher transcript for the same workdir,
  # rc=1/other means no eligible transcript so this load leaves SESSION_ID
  # empty. We never call clear/persist here — that is the decision-path job.
  local _accepted="" _rc=0
  _accepted="$(bridge_resolve_resume_session_id "$AGENT_ENGINE" "${AGENT_ID:-}" "$AGENT_WORKDIR" "${AGENT_SESSION_ID:-}" 2>/dev/null)" || _rc=$?
  case "$_rc" in
    0|2) BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="$_accepted" ;;
    *)   BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="" ;;
  esac
  BRIDGE_AGENT_HISTORY_KEY["$AGENT_ID"]="${AGENT_HISTORY_KEY:-}"
  BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]="${AGENT_CREATED_AT:-}"
  BRIDGE_AGENT_UPDATED_AT["$AGENT_ID"]="${AGENT_UPDATED_AT:-}"
}

bridge_load_dynamic_agents() {
  local file

  shopt -s nullglob
  for file in "$BRIDGE_ACTIVE_AGENT_DIR"/*.env; do
    bridge_load_dynamic_agent_file "$file"
  done
  shopt -u nullglob
}

bridge_restore_dynamic_agents_from_history() {
  local file active_file
  local AGENT_ID=""
  local AGENT_DESC=""
  local AGENT_ENGINE=""
  local AGENT_SESSION=""
  local AGENT_WORKDIR=""
  local AGENT_LOOP=""
  local AGENT_CONTINUE=""
  local AGENT_SESSION_ID=""
  local AGENT_HISTORY_KEY=""
  local AGENT_CREATED_AT=""
  local AGENT_UPDATED_AT=""

  shopt -s nullglob
  for file in "$BRIDGE_HISTORY_DIR"/*.env; do
    AGENT_ID=""
    AGENT_DESC=""
    AGENT_ENGINE=""
    AGENT_SESSION=""
    AGENT_WORKDIR=""
    AGENT_LOOP=""
    AGENT_CONTINUE=""
    AGENT_SESSION_ID=""
    AGENT_HISTORY_KEY=""
    AGENT_CREATED_AT=""
    AGENT_UPDATED_AT=""

    # shellcheck source=/dev/null
    source "$file"

    if [[ -z "$AGENT_ID" || -z "$AGENT_ENGINE" || -z "$AGENT_SESSION" || -z "$AGENT_WORKDIR" ]]; then
      continue
    fi
    if bridge_agent_exists "$AGENT_ID"; then
      continue
    fi
    if ! bridge_tmux_session_exists "$AGENT_SESSION"; then
      continue
    fi

    bridge_add_agent_id_if_missing "$AGENT_ID"
    BRIDGE_AGENT_DESC["$AGENT_ID"]="${AGENT_DESC:-$AGENT_ID}"
    BRIDGE_AGENT_ENGINE["$AGENT_ID"]="$AGENT_ENGINE"
    BRIDGE_AGENT_SESSION["$AGENT_ID"]="$AGENT_SESSION"
    BRIDGE_AGENT_WORKDIR["$AGENT_ID"]="$AGENT_WORKDIR"
    BRIDGE_AGENT_SOURCE["$AGENT_ID"]="dynamic"
    # Issue #598 Track 1: history-restored entries are gated above on
    # bridge_tmux_session_exists, so this path only fires for agents
    # whose tmux session is currently live.
    BRIDGE_AGENT_PROVENANCE["$AGENT_ID"]="dynamic-history-live-session"
    BRIDGE_AGENT_LOOP["$AGENT_ID"]="${AGENT_LOOP:-1}"
    BRIDGE_AGENT_CONTINUE["$AGENT_ID"]="${AGENT_CONTINUE:-1}"
    # Hydration: gate stored id through resolver (see bridge_load_dynamic_agent_file).
    local _accepted="" _rc=0
    _accepted="$(bridge_resolve_resume_session_id "$AGENT_ENGINE" "${AGENT_ID:-}" "$AGENT_WORKDIR" "${AGENT_SESSION_ID:-}" 2>/dev/null)" || _rc=$?
    case "$_rc" in
      0|2) BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="$_accepted" ;;
      *)   BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="" ;;
    esac
    BRIDGE_AGENT_HISTORY_KEY["$AGENT_ID"]="${AGENT_HISTORY_KEY:-}"
    BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]="${AGENT_CREATED_AT:-}"
    BRIDGE_AGENT_UPDATED_AT["$AGENT_ID"]="${AGENT_UPDATED_AT:-}"

    active_file="$(bridge_dynamic_agent_file_for "$AGENT_ID")"
    BRIDGE_AGENT_META_FILE["$AGENT_ID"]="$active_file"
    # Issue #598 Track 1 r2: when BRIDGE_REGISTRY_READ_ONLY=1 is set by the
    # registry endpoint, skip the persistence side-effect to keep the registry
    # read truly read-only. The in-memory state (BRIDGE_AGENT_*) is still
    # populated for the registry's enumeration.
    if [[ "${BRIDGE_REGISTRY_READ_ONLY:-0}" != "1" ]]; then
      bridge_write_dynamic_agent_file "$AGENT_ID" "$active_file"
    fi
  done
  shopt -u nullglob
}

# Last-resort dynamic-agent reconciliation: if a live tmux session looks like
# a dynamic agent (session name equals agent name by construction) but neither
# the active .env nor the history .env restored it, rebuild the entry from:
#   1) a history file prefixed by the session name (preferred — has the real
#      engine + workdir + session_id), or
#   2) the tmux pane itself (engine detected from the pane command, workdir
#      from pane_current_path) when no history exists.
# Without this, a prune followed by loss of the active .env leaves the agent
# invisible on the dashboard even though the tmux session is still the source
# of truth (#190B).
bridge_reconcile_dynamic_agents_from_tmux() {
  local session
  local file
  local active_file
  local pane_cmd
  local pane_path
  local derived_engine

  command -v tmux >/dev/null 2>&1 || return 0

  while IFS= read -r session; do
    [[ -n "$session" ]] || continue
    if bridge_agent_exists "$session"; then
      continue
    fi
    # Skip smoke-test / ad hoc harness sessions using the centralized
    # matcher shared with scripts/smoke-test.sh.
    if bridge_session_is_smoke_or_adhoc "$session"; then
      continue
    fi

    # Prefer any history file whose filename starts with `<session>--`, which
    # means it was previously written for this exact agent name. Keep only
    # the newest match.
    file=""
    _bridge_pick_newest_history_for_session file "$session"
    if [[ -n "$file" ]]; then
      _bridge_register_dynamic_from_env_file "$session" "$file" && continue
    fi

    # Fall back to tmux pane inspection: we can only recover agents whose pane
    # command is a recognizable engine binary, since otherwise we have no
    # reliable way to set AGENT_ENGINE.
    pane_cmd="$(tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{pane_current_command}' 2>/dev/null || true)"
    pane_path="$(tmux display-message -p -t "$(bridge_tmux_pane_target "$session")" '#{pane_current_path}' 2>/dev/null || true)"
    derived_engine=""
    case "$pane_cmd" in
      *claude*) derived_engine="claude" ;;
      *codex*)  derived_engine="codex" ;;
    esac
    [[ -n "$derived_engine" && -d "$pane_path" ]] || continue

    bridge_add_agent_id_if_missing "$session"
    BRIDGE_AGENT_DESC["$session"]="Recovered ${derived_engine} agent (${pane_path})"
    BRIDGE_AGENT_ENGINE["$session"]="$derived_engine"
    BRIDGE_AGENT_SESSION["$session"]="$session"
    BRIDGE_AGENT_WORKDIR["$session"]="$pane_path"
    BRIDGE_AGENT_SOURCE["$session"]="dynamic"
    # Issue #598 Track 1: pane-derived recovery — neither active env nor
    # history file produced a registration, so the only signal is tmux.
    BRIDGE_AGENT_PROVENANCE["$session"]="dynamic-tmux-recovered"
    BRIDGE_AGENT_LOOP["$session"]="1"
    BRIDGE_AGENT_CONTINUE["$session"]="1"
    BRIDGE_AGENT_SESSION_ID["$session"]=""
    BRIDGE_AGENT_HISTORY_KEY["$session"]="$(bridge_history_key_for "$derived_engine" "$session" "$pane_path")"
    BRIDGE_AGENT_CREATED_AT["$session"]="$(date +%s)"
    BRIDGE_AGENT_UPDATED_AT["$session"]="$(bridge_now_iso)"

    active_file="$(bridge_dynamic_agent_file_for "$session")"
    BRIDGE_AGENT_META_FILE["$session"]="$active_file"
    # Issue #598 Track 1 r2: when BRIDGE_REGISTRY_READ_ONLY=1 is set by the
    # registry endpoint, skip the persistence side-effect to keep the registry
    # read truly read-only. The in-memory state (BRIDGE_AGENT_*) is still
    # populated for the registry's enumeration.
    if [[ "${BRIDGE_REGISTRY_READ_ONLY:-0}" != "1" ]]; then
      bridge_write_dynamic_agent_file "$session" "$active_file"
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
}

_bridge_pick_newest_history_for_session() {
  local -n __out_ref="$1"
  local session="$2"
  local candidate
  local -a candidates=()

  shopt -s nullglob
  candidates=("$BRIDGE_HISTORY_DIR/${session}--"*.env)
  shopt -u nullglob

  __out_ref=""
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] || continue
    if [[ -z "$__out_ref" || "$candidate" -nt "$__out_ref" ]]; then
      __out_ref="$candidate"
    fi
  done
}

_bridge_register_dynamic_from_env_file() {
  local session="$1"
  local file="$2"
  local active_file
  local AGENT_ID=""
  local AGENT_DESC=""
  local AGENT_ENGINE=""
  local AGENT_SESSION=""
  local AGENT_WORKDIR=""
  local AGENT_LOOP=""
  local AGENT_CONTINUE=""
  local AGENT_SESSION_ID=""
  local AGENT_HISTORY_KEY=""
  local AGENT_CREATED_AT=""
  local AGENT_UPDATED_AT=""

  # shellcheck source=/dev/null
  source "$file"

  if [[ -z "$AGENT_ID" || -z "$AGENT_ENGINE" || -z "$AGENT_SESSION" || -z "$AGENT_WORKDIR" ]]; then
    return 1
  fi
  if [[ "$AGENT_ID" != "$session" || "$AGENT_SESSION" != "$session" ]]; then
    return 1
  fi

  bridge_add_agent_id_if_missing "$AGENT_ID"
  BRIDGE_AGENT_DESC["$AGENT_ID"]="${AGENT_DESC:-$AGENT_ID}"
  BRIDGE_AGENT_ENGINE["$AGENT_ID"]="$AGENT_ENGINE"
  BRIDGE_AGENT_SESSION["$AGENT_ID"]="$AGENT_SESSION"
  BRIDGE_AGENT_WORKDIR["$AGENT_ID"]="$AGENT_WORKDIR"
  BRIDGE_AGENT_SOURCE["$AGENT_ID"]="dynamic"
  # Issue #598 Track 1: this helper is only called from
  # bridge_reconcile_dynamic_agents_from_tmux (tmux session is the
  # discovery signal; the history env file just supplies engine/workdir).
  BRIDGE_AGENT_PROVENANCE["$AGENT_ID"]="dynamic-tmux-recovered"
  BRIDGE_AGENT_LOOP["$AGENT_ID"]="${AGENT_LOOP:-1}"
  BRIDGE_AGENT_CONTINUE["$AGENT_ID"]="${AGENT_CONTINUE:-1}"
  # Hydration: gate the stored id through the freshness resolver. rc=0 keeps
  # the candidate, rc=2 swaps in a fresher transcript for the same workdir,
  # rc=1/other means no eligible transcript so this load leaves SESSION_ID
  # empty. We never call clear/persist here — that is the decision-path job.
  local _accepted="" _rc=0
  _accepted="$(bridge_resolve_resume_session_id "$AGENT_ENGINE" "${AGENT_ID:-}" "$AGENT_WORKDIR" "${AGENT_SESSION_ID:-}" 2>/dev/null)" || _rc=$?
  case "$_rc" in
    0|2) BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="$_accepted" ;;
    *)   BRIDGE_AGENT_SESSION_ID["$AGENT_ID"]="" ;;
  esac
  BRIDGE_AGENT_HISTORY_KEY["$AGENT_ID"]="${AGENT_HISTORY_KEY:-}"
  BRIDGE_AGENT_CREATED_AT["$AGENT_ID"]="${AGENT_CREATED_AT:-}"
  BRIDGE_AGENT_UPDATED_AT["$AGENT_ID"]="${AGENT_UPDATED_AT:-}"

  active_file="$(bridge_dynamic_agent_file_for "$AGENT_ID")"
  BRIDGE_AGENT_META_FILE["$AGENT_ID"]="$active_file"
  # Issue #598 Track 1 r2: when BRIDGE_REGISTRY_READ_ONLY=1 is set by the
  # registry endpoint, skip the persistence side-effect to keep the registry
  # read truly read-only. The in-memory state (BRIDGE_AGENT_*) is still
  # populated for the registry's enumeration.
  if [[ "${BRIDGE_REGISTRY_READ_ONLY:-0}" != "1" ]]; then
    bridge_write_dynamic_agent_file "$AGENT_ID" "$active_file"
  fi
}

bridge_load_static_agent_history() {
  local agent="$1"
  local file
  local AGENT_ID=""
  local AGENT_ENGINE=""
  local AGENT_WORKDIR=""
  local AGENT_SESSION_ID=""
  local AGENT_HISTORY_KEY=""
  local AGENT_CREATED_AT=""
  local AGENT_UPDATED_AT=""

  file="$(bridge_history_file_for_agent "$agent")"
  [[ -f "$file" ]] || return 0
  # v0.8.5 #694 (Wave-3): partial isolated agent state (failed `agent
  # create --isolate ...`) leaves `runtime/history.env` owned by the
  # isolated UID with mode 0640 group=ab-agent-<name>. The controller is
  # added to that group at `agent create` time, but supplementary group
  # membership is cached at process credential time — until the operator
  # re-logs in (or runs a fresh shell), the running `agent show` /
  # `agent doctor` / roster-load process cannot read the file via group
  # r--, even though `[[ -f "$file" ]]` succeeds (the parent dir
  # traversal works because intermediate modes are 2750/2770 with group
  # r-x and that group bit is checked at stat-time, but the actual file
  # read uses the cached effective group set). `source "$file"` then
  # bombs with `Permission denied` and crashes `bridge_load_roster` —
  # taking out every command that runs at `bridge-agent.sh` load time
  # (status, show, doctor, list, ...). Skip silently when the file is
  # not readable to this process; downstream behavior is identical to
  # the "history file absent" case (the static agent comes up without a
  # restored AGENT_SESSION_ID, and the next session-id rewrite restores
  # the entry). Mirrors the graceful-degrade pattern PR #688 added to
  # `bridge-status.py::pending_upgrade_conflict_count`.
  [[ -r "$file" ]] || return 0

  # shellcheck source=/dev/null
  source "$file"

  if [[ -n "$AGENT_ID" && "$AGENT_ID" != "$agent" ]]; then
    return 0
  fi

  if [[ -n "$AGENT_SESSION_ID" ]]; then
    AGENT_ENGINE="${AGENT_ENGINE:-$(bridge_agent_engine "$agent")}"
    AGENT_WORKDIR="${AGENT_WORKDIR:-$(bridge_agent_workdir "$agent")}"
    # Hydration: gate stored id through resolver (see bridge_load_dynamic_agent_file).
    local _accepted="" _rc=0
    _accepted="$(bridge_resolve_resume_session_id "$AGENT_ENGINE" "$agent" "$AGENT_WORKDIR" "$AGENT_SESSION_ID" 2>/dev/null)" || _rc=$?
    case "$_rc" in
      0|2) BRIDGE_AGENT_SESSION_ID["$agent"]="$_accepted" ;;
      *)   ;;
    esac
  fi
  if [[ -n "$AGENT_HISTORY_KEY" ]]; then
    BRIDGE_AGENT_HISTORY_KEY["$agent"]="$AGENT_HISTORY_KEY"
  fi
  if [[ -n "$AGENT_CREATED_AT" ]]; then
    BRIDGE_AGENT_CREATED_AT["$agent"]="$AGENT_CREATED_AT"
  fi
  if [[ -n "$AGENT_UPDATED_AT" ]]; then
    BRIDGE_AGENT_UPDATED_AT["$agent"]="$AGENT_UPDATED_AT"
  fi
  if [[ -n "${AGENT_ISOLATION_MODE:-}" ]]; then
    BRIDGE_AGENT_ISOLATION_MODE["$agent"]="$AGENT_ISOLATION_MODE"
  fi
  if [[ -n "${AGENT_OS_USER:-}" ]]; then
    BRIDGE_AGENT_OS_USER["$agent"]="$AGENT_OS_USER"
  fi
}

bridge_load_static_histories() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    bridge_load_static_agent_history "$agent"
  done
}

bridge_load_roster() {
  local agent
  local fast_load="${BRIDGE_FAST_ROSTER_LOAD:-0}"
  local isolated_env_file="${BRIDGE_AGENT_ENV_FILE:-}"
  local scoped_agent_id="${BRIDGE_AGENT_ID:-}"
  local scoped_env_file=""

  bridge_reset_roster_maps

  # When BRIDGE_AGENT_ENV_FILE is not explicitly set but BRIDGE_AGENT_ID is
  # exported (e.g., the isolated Claude/Codex session spawned by bridge-run.sh,
  # or agb commands the agent executes as its isolated UID), fall back to the
  # per-agent scoped roster snapshot written by bridge_linux_prepare_agent_isolation.
  # This is what keeps the isolated UID from needing read access to the global
  # agent-roster.local.sh (which is 0600 and contains every agent's tokens).
  # See issue #116.
  if [[ -z "$isolated_env_file" && -n "$scoped_agent_id" && -n "${BRIDGE_ACTIVE_AGENT_DIR:-}" ]]; then
    scoped_env_file="$BRIDGE_ACTIVE_AGENT_DIR/$scoped_agent_id/agent-env.sh"
    if [[ -r "$scoped_env_file" ]]; then
      isolated_env_file="$scoped_env_file"
      # Persist the discovered path so bridge_queue_gateway_proxy_agent
      # (lib/bridge-core.sh) can detect proxy mode without requiring
      # BRIDGE_AGENT_ENV_FILE to be pre-exported in the isolated REPL's
      # env. Without this export the queue CLI falls through to the
      # direct bridge-queue.py path against BRIDGE_TASK_DB=/dev/null
      # and tracebacks. See issue #436.
      export BRIDGE_AGENT_ENV_FILE="$isolated_env_file"
    fi
  fi

  if [[ -n "$isolated_env_file" ]]; then
    [[ -f "$isolated_env_file" ]] || bridge_die "agent env file이 없습니다: $isolated_env_file"
    # shellcheck source=/dev/null
    source "$isolated_env_file"
  else
    if [[ -f "$BRIDGE_ROSTER_FILE" ]]; then
      # shellcheck source=/dev/null
      source "$BRIDGE_ROSTER_FILE"
    fi

    if [[ -f "$BRIDGE_ROSTER_LOCAL_FILE" ]]; then
      # shellcheck source=/dev/null
      source "$BRIDGE_ROSTER_LOCAL_FILE"
    fi
  fi

  # Issue #539: validate BRIDGE_AGENT_CLASS values once the roster files
  # have been sourced. The closed value space is {user, system}; a typo
  # like `class=admin` must surface as a hard load error rather than
  # silently degrading to user-class privileges.
  if declare -F bridge_validate_agent_classes >/dev/null 2>&1; then
    bridge_validate_agent_classes
  fi

  : "${BRIDGE_LOG_DIR:=$BRIDGE_HOME/logs}"
  : "${BRIDGE_AUDIT_LOG:=$BRIDGE_LOG_DIR/audit.jsonl}"
  : "${BRIDGE_SHARED_DIR:=$BRIDGE_HOME/shared}"
  : "${BRIDGE_MAX_MESSAGE_LEN:=500}"
  : "${BRIDGE_TASK_NOTE_DIR:=$BRIDGE_SHARED_DIR/tasks}"
  : "${BRIDGE_TASK_LEASE_SECONDS:=900}"
  : "${BRIDGE_TASK_IDLE_NUDGE_SECONDS:=120}"
  : "${BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS:=300}"
  : "${BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS:=300}"
  : "${BRIDGE_HEALTH_WARN_SECONDS:=3600}"
  : "${BRIDGE_HEALTH_CRITICAL_SECONDS:=14400}"
  : "${BRIDGE_CHANNEL_HEALTH_REPORT_COOLDOWN_SECONDS:=1800}"
  : "${BRIDGE_CRASH_REPORT_COOLDOWN_SECONDS:=1800}"
  : "${BRIDGE_DAEMON_NOTIFY_DRY_RUN:=0}"
  : "${BRIDGE_ON_DEMAND_IDLE_SECONDS:=0}"
  : "${BRIDGE_USAGE_WARN_PERCENT:=90}"
  : "${BRIDGE_USAGE_ELEVATED_PERCENT:=95}"
  : "${BRIDGE_USAGE_CRITICAL_PERCENT:=100}"
  : "${BRIDGE_USAGE_MONITOR_INTERVAL_SECONDS:=300}"
  : "${BRIDGE_USAGE_MONITOR_STATE_FILE:=$BRIDGE_STATE_DIR/usage/monitor-state.json}"
  : "${BRIDGE_DAILY_BACKUP_ENABLED:=1}"
  : "${BRIDGE_DAILY_BACKUP_HOUR:=4}"
  # Bug #507 (3): default dropped 30 → 7. The previous default plus the
  # raw .db inclusion (bug 6) produced 45–60 GB baseline disk consumption
  # on long-lived installs and triggered the disk-full death-spiral. Set
  # the env var explicitly to 30 if you really want the old behavior.
  : "${BRIDGE_DAILY_BACKUP_RETAIN_DAYS:=7}"
  : "${BRIDGE_DAILY_BACKUP_DIR:=$BRIDGE_HOME/backups/daily}"
  : "${BRIDGE_DAILY_BACKUP_STATE_FILE:=$BRIDGE_STATE_DIR/daily-backup/state.env}"
  # Bug #507 (cooldown): after a backup failure, suppress retries inside
  # this window so a chronically-full disk doesn't burn one tarball
  # attempt per daemon cycle. One warn + one audit per window.
  : "${BRIDGE_DAILY_BACKUP_FAILURE_COOLDOWN_SECONDS:=3600}"
  # Bug #507 (concurrency): grace window for stale tmp reaping. Should
  # exceed the daemon-side bridge_with_timeout ceiling (120s) plus
  # buffer; default 180s = 120 + 60.
  : "${BRIDGE_DAILY_BACKUP_TMP_GRACE_SECONDS:=180}"
  # Daily-backup exclude roots additive to the hardcoded list in
  # bridge-upgrade.py (logs/, worktrees/, runtime/{assets,media,extensions},
  # .claude/worktrees/, state/backup-snapshots/). Colon- or comma-separated.
  : "${BRIDGE_DAILY_BACKUP_EXCLUDE_ROOTS:=}"
  # Upgrade-time backup retention (separate from daily archives). Both
  # gates apply: keep at least N most recent + only delete those older
  # than D days. The current upgrade's BACKUP_ROOT is always preserved.
  # See lib/bridge-cleanup.sh for the prune flow.
  : "${BRIDGE_UPGRADE_BACKUP_RETAIN_COUNT:=5}"
  : "${BRIDGE_UPGRADE_BACKUP_RETAIN_DAYS:=14}"
  : "${BRIDGE_RELEASE_CHECK_ENABLED:=1}"
  : "${BRIDGE_RELEASE_CHECK_INTERVAL_SECONDS:=86400}"
  : "${BRIDGE_RELEASE_CHECK_STATE_FILE:=$BRIDGE_STATE_DIR/release-check/monitor-state.json}"
  : "${BRIDGE_RELEASE_REPO:=SYRS-AI/agent-bridge-public}"
  : "${BRIDGE_STALL_SCAN_ENABLED:=1}"
  : "${BRIDGE_STALL_SCAN_INTERVAL_SECONDS:=30}"
  : "${BRIDGE_STALL_CAPTURE_LINES:=120}"
  : "${BRIDGE_STALL_EXPLICIT_IDLE_SECONDS:=30}"
  : "${BRIDGE_STALL_UNKNOWN_IDLE_SECONDS:=900}"
  : "${BRIDGE_STALL_MAX_NUDGES:=2}"
  : "${BRIDGE_STALL_ESCALATE_AFTER_SECONDS:=300}"
  : "${BRIDGE_STALL_RATE_LIMIT_RETRY_SECONDS:=30}"
  : "${BRIDGE_STALL_NETWORK_RETRY_SECONDS:=60}"
  : "${BRIDGE_STALL_UNKNOWN_RETRY_SECONDS:=300}"
  : "${BRIDGE_STALL_NETWORK_ESCALATE_SECONDS:=600}"
  : "${BRIDGE_STALL_UNKNOWN_ESCALATE_SECONDS:=600}"
  : "${BRIDGE_ADMIN_AGENT_ID:=}"
  if bridge_cron_sync_enabled; then
    BRIDGE_CRON_SYNC_ENABLED=1
  else
    BRIDGE_CRON_SYNC_ENABLED=0
  fi
  : "${BRIDGE_DISCORD_RELAY_ENABLED:=1}"
  : "${BRIDGE_DISCORD_RELAY_ACCOUNT:=default}"
  : "${BRIDGE_DISCORD_RELAY_POLL_LIMIT:=5}"
  : "${BRIDGE_DISCORD_RELAY_COOLDOWN_SECONDS:=60}"

  bridge_init_dirs

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    BRIDGE_AGENT_SOURCE["$agent"]="${BRIDGE_AGENT_SOURCE[$agent]-static}"
    # Issue #598 Track 1: any id surfaced by the roster files (without an
    # explicit dynamic loader claiming it later) is static — tag default.
    # The dynamic loaders below overwrite this with their own provenance
    # tag when they recognise the id.
    if [[ "${BRIDGE_AGENT_SOURCE[$agent]}" == "static" ]]; then
      BRIDGE_AGENT_PROVENANCE["$agent"]="${BRIDGE_AGENT_PROVENANCE[$agent]-static-roster}"
    fi
    BRIDGE_AGENT_LOOP["$agent"]="${BRIDGE_AGENT_LOOP[$agent]-1}"
    BRIDGE_AGENT_CONTINUE["$agent"]="${BRIDGE_AGENT_CONTINUE[$agent]-1}"
    BRIDGE_AGENT_HISTORY_KEY["$agent"]="${BRIDGE_AGENT_HISTORY_KEY[$agent]-$(bridge_history_key_for "$(bridge_agent_engine "$agent")" "$agent" "$(bridge_agent_workdir "$agent")")}"
    BRIDGE_AGENT_IDLE_TIMEOUT["$agent"]="${BRIDGE_AGENT_IDLE_TIMEOUT[$agent]-$BRIDGE_ON_DEMAND_IDLE_SECONDS}"
    # Issue #597 Track B: default OFF for PreCompact auto-notify. Per-agent
    # opt-in lives in agent-roster.local.sh; the language map falls back to
    # the global BRIDGE_PRECOMPACT_NOTIFY_LANG env (default "en").
    BRIDGE_AGENT_PRECOMPACT_NOTIFY["$agent"]="${BRIDGE_AGENT_PRECOMPACT_NOTIFY[$agent]-0}"
    BRIDGE_AGENT_PRECOMPACT_NOTIFY_LANG["$agent"]="${BRIDGE_AGENT_PRECOMPACT_NOTIFY_LANG[$agent]-${BRIDGE_PRECOMPACT_NOTIFY_LANG:-en}}"
  done

  bridge_load_dynamic_agents
  if [[ "$fast_load" != "1" ]]; then
    # When loading via a scoped agent-env.sh (linux-user isolation), the
    # snapshot already carries self + sanitized peer metadata. Iterating
    # peer history files would require read access on
    # $BRIDGE_HISTORY_DIR/*.env, which the isolated UID lacks (they are
    # owned by the operator UID). Sourcing one fails with "Permission
    # denied" and surfaces in the agent's REPL during routine queue CLI
    # use. Skip both peer-history hydration paths when scoped. See #436.
    if [[ -z "$isolated_env_file" ]]; then
      bridge_load_static_histories
      bridge_restore_dynamic_agents_from_history
    fi
    bridge_reconcile_dynamic_agents_from_tmux
  fi
}

bridge_audit_log() {
  local actor="$1"
  local action="$2"
  local target="$3"
  shift 3 || true

  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-audit.py" write --file "$BRIDGE_AUDIT_LOG" --actor "$actor" --action "$action" --target "$target" "$@" >/dev/null
}

# bridge_with_timeout — issue #265 proposal A.
#
# Wraps an external command with `timeout(1)` so a single hung subprocess in
# the daemon main loop cannot block the scheduler indefinitely (the canonical
# stack the issue describes is bash blocked at __wait4 on a tmux send-keys
# child whose far end is a closed Discord SSL pipe). On 124/137 (timeout or
# SIGKILL after timeout) the helper writes a `daemon_subprocess_timeout`
# audit row tagged with the call-site label so the operator can see which
# step actually hung; the exit code is propagated so existing `|| true` /
# `|| return 1` handling at the call site keeps working.
#
# Usage:
#   bridge_with_timeout <secs> <call_site_label> <cmd> [args...]
#
# - <secs> defaults to BRIDGE_DAEMON_SUBPROCESS_TIMEOUT_SECONDS (default 30s)
#   when passed as empty string.
# - <call_site_label> is the symbolic name used in the audit detail
#   (e.g. "release_monitor", "stall_analyze").
# - When neither `timeout` nor `gtimeout` is on PATH, the helper falls
#   through to a plain exec so behavior on bare hosts matches today; a
#   one-time `daemon_subprocess_timeout_unavailable` audit row is written
#   the first time so the gap is visible without spamming the log.
#
# Caveat: only wrappable around *external* commands. Bash functions cannot be
# wrapped with `timeout(1)` directly — those must be exposed through a
# subshell + `bash -c` first, which is out of scope for this helper.
_BRIDGE_WITH_TIMEOUT_BIN_CACHED=0
_BRIDGE_WITH_TIMEOUT_BIN=""
_BRIDGE_WITH_TIMEOUT_UNAVAILABLE_LOGGED=0

bridge_with_timeout() {
  local secs="${1:-}"
  local label="${2:-unknown}"
  shift 2 || true
  local default_secs="${BRIDGE_DAEMON_SUBPROCESS_TIMEOUT_SECONDS:-30}"
  local started_ts=0
  local elapsed=0
  local rc=0

  [[ "$secs" =~ ^[0-9]+$ ]] || secs="$default_secs"
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=30

  if (( _BRIDGE_WITH_TIMEOUT_BIN_CACHED == 0 )); then
    _BRIDGE_WITH_TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
    _BRIDGE_WITH_TIMEOUT_BIN_CACHED=1
  fi

  started_ts="$(date +%s 2>/dev/null || echo 0)"

  if [[ -z "$_BRIDGE_WITH_TIMEOUT_BIN" ]]; then
    if (( _BRIDGE_WITH_TIMEOUT_UNAVAILABLE_LOGGED == 0 )); then
      bridge_audit_log daemon daemon_subprocess_timeout_unavailable daemon \
        --detail call_site="$label" \
        --detail requested_seconds="$secs" \
        --detail note="neither timeout nor gtimeout on PATH; running unwrapped" \
        2>/dev/null || true
      _BRIDGE_WITH_TIMEOUT_UNAVAILABLE_LOGGED=1
    fi
    "$@"
    return $?
  fi

  "$_BRIDGE_WITH_TIMEOUT_BIN" "$secs" "$@"
  rc=$?
  if [[ "$rc" == "124" || "$rc" == "137" ]]; then
    elapsed=$(( $(date +%s 2>/dev/null || echo "$started_ts") - started_ts ))
    bridge_audit_log daemon daemon_subprocess_timeout daemon \
      --detail call_site="$label" \
      --detail timeout_seconds="$secs" \
      --detail elapsed_seconds="$elapsed" \
      --detail exit_code="$rc" \
      2>/dev/null || true
  fi
  return "$rc"
}

bridge_mcp_orphan_cleanup_state_dir() {
  printf '%s/mcp-orphan-cleanup' "$BRIDGE_STATE_DIR"
}

bridge_mcp_orphan_cleanup_last_run_file() {
  printf '%s/last-run' "$(bridge_mcp_orphan_cleanup_state_dir)"
}

bridge_mcp_orphan_cleanup_report_file() {
  printf '%s/last.json' "$(bridge_mcp_orphan_cleanup_state_dir)"
}

bridge_mcp_orphan_pattern_args() {
  local pattern=""

  [[ -n "${BRIDGE_MCP_ORPHAN_PATTERNS:-}" ]] || return 0
  while IFS= read -r pattern; do
    pattern="$(bridge_trim_whitespace "$pattern")"
    [[ -n "$pattern" ]] || continue
    printf '%s\0%s\0' "--pattern" "$pattern"
  done < <(printf '%s\n' "$BRIDGE_MCP_ORPHAN_PATTERNS" | tr ',' '\n')
}

bridge_mcp_orphan_cleanup() {
  local trigger="${1:-manual}"
  local min_age="${2:-${BRIDGE_MCP_ORPHAN_MIN_AGE_SECONDS:-300}}"
  local kill_mode="${3:-1}"
  local -a args=()
  local -a pattern_args=()
  local item=""

  [[ "$min_age" =~ ^[0-9]+$ ]] || min_age=300
  bridge_require_python
  args=("$BRIDGE_SCRIPT_DIR/bridge-mcp-cleanup.py" cleanup --json --trigger "$trigger" --min-age "$min_age")
  if [[ "$kill_mode" == "1" ]]; then
    args+=(--kill)
  else
    args+=(--dry-run)
  fi
  while IFS= read -r -d '' item; do
    pattern_args+=("$item")
  done < <(bridge_mcp_orphan_pattern_args)
  args+=("${pattern_args[@]}")
  python3 "${args[@]}"
}

bridge_mcp_orphan_cleanup_after_session_stop() {
  local agent="$1"
  local min_age="${BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS:-0}"

  [[ "${BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED:-1}" == "1" ]] || return 0
  bridge_mcp_orphan_cleanup "session-stop:${agent}" "$min_age" 1
}

bridge_dynamic_agent_ids() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_source "$agent")" == "dynamic" ]]; then
      printf '%s\n' "$agent"
    fi
  done
}

bridge_state_v2_isolated_target() {
  # v0.8.4 r2: predicate for "this controller-side write must land
  # under the v2 per-agent root because the agent is linux-user
  # isolated". Used by bridge_write_agent_state_file to pick between
  # the direct-write fast path and the sudo-handoff slow path.
  #
  # The slow path is only required when:
  #   - the host is Linux (no-op on macOS / mock hosts)
  #   - isolation v2 is active for this install
  #   - the target path lives under $BRIDGE_AGENT_ROOT_V2/<agent>/
  #   - the agent is configured with linux-user isolation effectively
  #     (BRIDGE_AGENT_ISOLATION_MODE[<agent>] resolves to linux-user)
  # Anything else (shared-mode agent in a v2 install, dynamic agent
  # whose env file lives under controller-owned state/agents/) keeps
  # the direct-write fast path so non-isolated codepaths are
  # unaffected.
  local agent="$1"
  local target="$2"

  [[ -n "$agent" && -n "$target" ]] || return 1
  [[ "$(bridge_host_platform 2>/dev/null || uname)" == "Linux" ]] || return 1
  bridge_isolation_v2_active 2>/dev/null || return 1
  [[ -n "$BRIDGE_AGENT_ROOT_V2" ]] || return 1
  case "$target" in
    "$BRIDGE_AGENT_ROOT_V2"/"$agent"/*) ;;
    *) return 1 ;;
  esac
  bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null || return 1
  return 0
}

bridge_state_sudo_install_v2_file() {
  # v0.8.4 r2: stage `$content` into a controller-owned tempfile, then
  # `bridge_linux_sudo_root install -m <mode> -o <owner> -g <group>`
  # the staged file into the per-agent root. Mirrors the cross-UID
  # write pattern PR #673 added in lib/bridge-hooks.sh
  # (bridge_install_isolated_home_settings).
  #
  # This is the controller-side escape hatch for files whose final
  # location is under $BRIDGE_AGENT_ROOT_V2/<agent>/ but whose author
  # is the controller, not the isolated UID — runtime/history.env is
  # the canonical example. The per-agent root mode 2750 (group r-x,
  # no group write) prevents the controller — a group member but not
  # the owner — from creating the parent dir or replacing the file
  # via the direct path; sudo with the right `install` invocation
  # bypasses that without weakening the root mode.
  local target="$1"
  local mode="$2"
  local owner="$3"
  local group="$4"
  local content="$5"

  [[ -n "$target" && -n "$mode" && -n "$owner" && -n "$group" ]] \
    || return 2

  local tmp=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/bridge-state-v2.XXXXXX")" || return 1
  printf '%s' "$content" >"$tmp" || { rm -f "$tmp"; return 1; }

  bridge_linux_sudo_root mkdir -p "$(dirname "$target")" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  if ! bridge_linux_sudo_root install -m "$mode" -o "$owner" -g "$group" "$tmp" "$target" 2>/dev/null; then
    # Older `install` builds reject `-o`/`-g` even under sudo; fall back
    # to plain install + chown.
    if ! bridge_linux_sudo_root install -m "$mode" "$tmp" "$target" 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
    bridge_linux_sudo_root chown "$owner:$group" "$target" 2>/dev/null || {
      rm -f "$tmp"
      return 1
    }
  fi
  rm -f "$tmp"
  return 0
}

bridge_write_agent_state_file() {
  local agent="$1"
  local file="$2"
  local desc engine session workdir loop_mode continue_mode session_id history_key created_at updated_at

  desc="$(bridge_agent_desc "$agent")"
  engine="$(bridge_agent_engine "$agent")"
  session="$(bridge_agent_session "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  session_id="$(bridge_agent_session_id "$agent")"
  history_key="$(bridge_agent_history_key "$agent")"
  created_at="${BRIDGE_AGENT_CREATED_AT[$agent]-$(date +%s)}"
  updated_at="$(bridge_now_iso)"

  BRIDGE_AGENT_UPDATED_AT["$agent"]="$updated_at"

  local content
  content="$(cat <<EOF
AGENT_ID=$(printf '%q' "$agent")
AGENT_DESC=$(printf '%q' "$desc")
AGENT_ENGINE=$(printf '%q' "$engine")
AGENT_SESSION=$(printf '%q' "$session")
AGENT_WORKDIR=$(printf '%q' "$workdir")
AGENT_LOOP=$(printf '%q' "$loop_mode")
AGENT_CONTINUE=$(printf '%q' "$continue_mode")
AGENT_SESSION_ID=$(printf '%q' "$session_id")
AGENT_HISTORY_KEY=$(printf '%q' "$history_key")
AGENT_CREATED_AT=$(printf '%q' "$created_at")
AGENT_UPDATED_AT=$(printf '%q' "$updated_at")
EOF
)"

  # v0.8.4 r2: when the target lives under the v2 per-agent root and
  # the agent is linux-user isolated, the controller — group member
  # but not the owner of the 2750 root — cannot mkdir/replace the file
  # directly. Route through the sudo-handoff helper. The file lands
  # owned by the isolated UID with mode 0640 + group=ab-agent-<name>,
  # matching what bridge_linux_prepare_agent_isolation seeds for
  # history.env (touch + chown $os_user) so the isolated UID can
  # read/rewrite it from inside its session and the controller can
  # read it via group r--.
  if bridge_state_v2_isolated_target "$agent" "$file"; then
    local _v2_owner _v2_group
    _v2_owner="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    _v2_group="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
    if [[ -n "$_v2_owner" && -n "$_v2_group" ]] \
        && bridge_state_sudo_install_v2_file \
            "$file" 0640 "$_v2_owner" "$_v2_group" "$content"; then
      return 0
    fi
    bridge_warn "bridge_write_agent_state_file: sudo-handoff write failed for $file (agent=$agent); falling back to direct write — expect Permission denied if the per-agent root is not writable to the controller"
  fi

  mkdir -p "$(dirname "$file")"
  printf '%s' "$content" >"$file"
}

bridge_write_dynamic_agent_file() {
  local agent="$1"
  local file="${2:-$(bridge_dynamic_agent_file_for "$agent")}"
  bridge_write_agent_state_file "$agent" "$file"
}

# bridge_agent_session_lock_file — per-agent lock that serialises mutations of
# the persisted AGENT_SESSION_ID across the dynamic-agent env, the static
# history env, and (when present) the linux-user-scoped agent-env.sh overlay.
# Lives under BRIDGE_ACTIVE_AGENT_DIR/<agent>/ alongside the other per-agent
# runtime markers; created lazily by callers that need to take it.
bridge_agent_session_lock_file() {
  local agent="$1"
  printf '%s/session.lock' "$(bridge_agent_runtime_state_dir "$agent")"
}

# bridge_agent_session_id_file_paths — emit the absolute paths of every
# authoritative state file that records AGENT_SESSION_ID for <agent>, one per
# line. Only paths that currently exist on disk are returned. Static agents
# normally have only the history file; a dynamic agent additionally has the
# active state file. The linux-user agent-env.sh overlay is included when
# present so isolated UIDs do not reload a stale id from their per-agent
# snapshot. Used by `agent forget-session` and `agent show --json`
# (session_source).
bridge_agent_session_id_file_paths() {
  local agent="$1"
  local history_file=""
  local active_file=""
  local overlay_file=""

  history_file="$(bridge_history_file_for_agent "$agent" 2>/dev/null || true)"
  if [[ -n "$history_file" && -f "$history_file" ]]; then
    printf '%s\n' "$history_file"
  fi
  active_file="$(bridge_dynamic_agent_file_for "$agent" 2>/dev/null || true)"
  if [[ -n "$active_file" && -f "$active_file" ]]; then
    printf '%s\n' "$active_file"
  fi
  if declare -f bridge_agent_linux_env_file >/dev/null 2>&1; then
    overlay_file="$(bridge_agent_linux_env_file "$agent" 2>/dev/null || true)"
    if [[ -n "$overlay_file" && -f "$overlay_file" ]]; then
      printf '%s\n' "$overlay_file"
    fi
  fi
}

# bridge_agent_persisted_session_id — read the persisted AGENT_SESSION_ID for
# <agent> directly from the authoritative state files, without trusting the
# in-memory BRIDGE_AGENT_SESSION_ID map (which is filtered by
# bridge_claude_session_id_exists during load and would hide a stale-but-
# present id from the operator's view). Returns the first non-empty value
# found, in source-of-truth precedence: history, then active, then overlay.
bridge_agent_persisted_session_id() {
  local agent="$1"
  local file=""
  local AGENT_SESSION_ID=""

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    AGENT_SESSION_ID=""
    # The overlay is a roster snapshot that sets values via associative-array
    # assignment, not flat AGENT_SESSION_ID=... keys, so a plain `source`
    # would not populate the local. Grep the literal active-id assignment
    # used by bridge_write_linux_agent_env_file before falling back to the
    # env-style files.
    if [[ "$file" == *"/agent-env.sh" ]]; then
      AGENT_SESSION_ID="$(
        awk -v agent="$agent" '
          $0 ~ "BRIDGE_AGENT_SESSION_ID\\[\"" agent "\"\\]=" {
            sub(/.*\]=/, "")
            gsub(/^[\047"]|[\047"]$/, "")
            print
            exit
          }
        ' "$file" 2>/dev/null || true
      )"
    else
      # shellcheck source=/dev/null
      source "$file" 2>/dev/null || true
    fi
    if [[ -n "$AGENT_SESSION_ID" ]]; then
      printf '%s' "$AGENT_SESSION_ID"
      return 0
    fi
  done < <(bridge_agent_session_id_file_paths "$agent")
  printf ''
}

# bridge_agent_session_source_path — return the absolute path of the file
# whose AGENT_SESSION_ID is currently the live id. Empty when no persisted
# id exists. This is the field exposed by `agent show --json` so an operator
# can see which file `forget-session` would rewrite.
bridge_agent_session_source_path() {
  local agent="$1"
  local file=""
  local AGENT_SESSION_ID=""

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    AGENT_SESSION_ID=""
    if [[ "$file" == *"/agent-env.sh" ]]; then
      AGENT_SESSION_ID="$(
        awk -v agent="$agent" '
          $0 ~ "BRIDGE_AGENT_SESSION_ID\\[\"" agent "\"\\]=" {
            sub(/.*\]=/, "")
            gsub(/^[\047"]|[\047"]$/, "")
            print
            exit
          }
        ' "$file" 2>/dev/null || true
      )"
    else
      # shellcheck source=/dev/null
      source "$file" 2>/dev/null || true
    fi
    if [[ -n "$AGENT_SESSION_ID" ]]; then
      printf '%s' "$file"
      return 0
    fi
  done < <(bridge_agent_session_id_file_paths "$agent")
  printf ''
}

# _bridge_rewrite_session_id_in_file — atomically clear AGENT_SESSION_ID in
# <file>. Honours the file's existing mode by chmod'ing the new inode after
# the rename, so 0600 overlay snapshots stay 0600. Returns 0 if the file was
# rewritten, 1 if no rewrite was needed, 2 on hard failure.
_bridge_rewrite_session_id_in_file() {
  local agent="$1"
  local file="$2"
  local tmp=""
  local mode=""

  [[ -n "$file" && -f "$file" ]] || return 1

  # `stat` flag differs between BSD (macOS) and GNU; fall back to a portable
  # python probe so the helper works on both supported platforms.
  if mode="$(stat -f '%Lp' "$file" 2>/dev/null)"; then
    :
  elif mode="$(stat -c '%a' "$file" 2>/dev/null)"; then
    :
  else
    mode="$(python3 - "$file" <<'PY' 2>/dev/null || true
import os
import sys
print(format(os.stat(sys.argv[1]).st_mode & 0o7777, 'o'))
PY
)"
  fi

  tmp="$(mktemp "${file}.XXXXXX")" || return 2
  if [[ "$file" == *"/agent-env.sh" ]]; then
    # Roster snapshot: rewrite the associative-array assignment inline so the
    # rest of the file (paths, channels, isolation flags) survives untouched.
    # awk is preferred over sed here so the agent literal can be passed
    # without escaping concerns.
    if ! awk -v agent="$agent" '
      $0 ~ "^BRIDGE_AGENT_SESSION_ID\\[\"" agent "\"\\]=" {
        printf "BRIDGE_AGENT_SESSION_ID[\"%s\"]=\"\"\n", agent
        next
      }
      { print }
    ' "$file" >"$tmp"; then
      rm -f "$tmp"
      return 2
    fi
  else
    # Plain env file (active or history): only touch the AGENT_SESSION_ID
    # line. Other keys (engine, workdir, history_key, timestamps) must
    # round-trip so the next `bridge_load_roster` keeps the agent intact.
    if ! awk '
      /^AGENT_SESSION_ID=/ {
        print "AGENT_SESSION_ID=\047\047"
        next
      }
      { print }
    ' "$file" >"$tmp"; then
      rm -f "$tmp"
      return 2
    fi
  fi

  if [[ -n "$mode" ]]; then
    chmod "$mode" "$tmp" 2>/dev/null || true
  fi
  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 2
  fi
  return 0
}

# _bridge_clear_session_id_critical — the read-modify-write that must be
# serialised by the per-agent session lock. Re-reads the prior id from disk
# inside the locked block (so a concurrent caller that beat us to the write
# observes an empty id and reports `changed=no`), rewrites every file that
# still carries it, and prints a single line to fd 1 of the form
# `prior_id_hash=<sha256-prefix> changed=<yes|no> cleared_files=<csv>` for
# the caller to feed straight into the audit log.
_bridge_clear_session_id_critical() {
  local agent="$1"
  local file=""
  local -a cleared=()
  local prior_id=""
  local prior_id_hash=""
  local changed="no"
  local rc=0

  prior_id="$(bridge_agent_persisted_session_id "$agent")"
  if [[ -n "$prior_id" ]]; then
    prior_id_hash="$(
      python3 - "$prior_id" <<'PY' 2>/dev/null || true
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
    )"
    prior_id_hash="${prior_id_hash:0:12}"
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if _bridge_rewrite_session_id_in_file "$agent" "$file"; then
        cleared+=("$file")
      else
        rc=$?
        if (( rc == 2 )); then
          bridge_warn "failed to rewrite '$file' while clearing session id for '$agent'"
        fi
      fi
    done < <(bridge_agent_session_id_file_paths "$agent")
    if (( ${#cleared[@]} > 0 )); then
      changed="yes"
    fi
  fi

  local csv=""
  local item=""
  for item in "${cleared[@]}"; do
    if [[ -z "$csv" ]]; then
      csv="$item"
    else
      csv+=",${item}"
    fi
  done
  printf 'prior_id_hash=%s changed=%s cleared_files=%s\n' \
    "$prior_id_hash" "$changed" "$csv"
}

# bridge_clear_persisted_session_id — clear AGENT_SESSION_ID across every
# authoritative state file for <agent>. Acquires a per-agent lock under
# state/agents/<agent>/session.lock so concurrent callers serialise on the
# read-modify-write; only the holder that finds a non-empty prior id
# reports `changed=yes`. Emits one line on stdout:
#   prior_id_hash=<sha256-prefix> changed=<yes|no> cleared_files=<csv>
# Returns 0 always; per-file failures are logged via bridge_warn.
bridge_clear_persisted_session_id() {
  local agent="$1"
  local lock_file=""
  local lock_dir=""
  local result_file=""

  lock_file="$(bridge_agent_session_lock_file "$agent")"
  lock_dir="$(dirname "$lock_file")"
  mkdir -p "$lock_dir"
  result_file="$(mktemp "${lock_file}.result.XXXXXX")"

  if command -v flock >/dev/null 2>&1; then
    {
      # Acquire with a bounded wait so a stuck holder cannot freeze the CLI.
      # 30s is well above any legitimate rewrite (single awk + mv per file)
      # and matches the pattern used by other forget/recovery commands.
      if ! flock -w 30 9; then
        bridge_warn "session lock busy after 30s, refusing forget-session for '$agent' to avoid losing a concurrent rewrite"
        printf 'prior_id_hash= changed=no cleared_files=\n' >"$result_file"
      else
        _bridge_clear_session_id_critical "$agent" >"$result_file"
      fi
    } 9>"$lock_file"
  else
    # Portable fallback when flock is missing (older macOS hosts, minimal
    # busybox containers). `mkdir` is atomic on POSIX, so a directory-based
    # mutex is safe; we retry with a short backoff before giving up.
    local lock_dir_path="${lock_file}.d"
    local attempt=0
    while ! mkdir "$lock_dir_path" 2>/dev/null; do
      attempt=$(( attempt + 1 ))
      if (( attempt >= 30 )); then
        bridge_warn "mkdir-based session lock busy after 30 retries, refusing forget-session for '$agent'"
        printf 'prior_id_hash= changed=no cleared_files=\n' >"$result_file"
        cat "$result_file"
        rm -f "$result_file"
        return 1
      fi
      sleep 1
    done
    _bridge_clear_session_id_critical "$agent" >"$result_file" || true
    rmdir "$lock_dir_path" 2>/dev/null || true
  fi

  # Reflect the cleared id in the in-memory map so any follow-up call in the
  # same process (e.g. `agent show` after forget-session) sees the new state
  # without a fresh roster reload.
  BRIDGE_AGENT_SESSION_ID["$agent"]=""

  cat "$result_file"
  rm -f "$result_file"
}

bridge_agent_idle_marker_dir() {
  local agent="$1"
  printf '%s/%s' "$BRIDGE_ACTIVE_AGENT_DIR" "$agent"
}

bridge_agent_runtime_state_dir() {
  local agent="$1"
  if bridge_isolation_v2_active && [[ -n "$BRIDGE_AGENT_ROOT_V2" && -n "$agent" ]]; then
    printf '%s/%s/runtime' "$BRIDGE_AGENT_ROOT_V2" "$agent"
    return 0
  fi
  bridge_agent_idle_marker_dir "$agent"
}

bridge_agent_log_dir() {
  local agent="$1"
  if bridge_isolation_v2_active && [[ -n "$BRIDGE_AGENT_ROOT_V2" && -n "$agent" ]]; then
    printf '%s/%s/logs' "$BRIDGE_AGENT_ROOT_V2" "$agent"
    return 0
  fi
  printf '%s/agents/%s' "$BRIDGE_LOG_DIR" "$agent"
}

bridge_agent_audit_log_file() {
  local agent="$1"
  printf '%s/audit.jsonl' "$(bridge_agent_log_dir "$agent")"
}

bridge_agent_idle_since_file() {
  local agent="$1"
  printf '%s/idle-since' "$(bridge_agent_idle_marker_dir "$agent")"
}

bridge_agent_manual_stop_file() {
  local agent="$1"
  printf '%s/manual-stop' "$(bridge_agent_idle_marker_dir "$agent")"
}

# Issue #629: missing-marker recovery probe retry counter.
# bridge_write_idle_ready_agents falls back to a single prompt-ready probe
# when the idle-since marker is absent. If that probe keeps failing (429
# stall, dialog overlay, copy-mode), the agent stays excluded indefinitely.
# This counter tracks consecutive probe failures across daemon cycles so
# the dispatcher can escalate to a synthetic marker after a bounded number
# of attempts. The file lives under the agent's idle marker dir so it is
# cleaned up automatically by bridge_agent_clear_idle_marker.
bridge_agent_missing_marker_retries_file() {
  local agent="$1"
  printf '%s/missing-marker-retries' "$(bridge_agent_idle_marker_dir "$agent")"
}

# Issue #589: prompt-ready latch.
# Records when an agent's tmux session first reached a usable Claude/Codex
# prompt during the current session. The auto-stop idle anchor in
# bridge-queue.py reads this so the boot window is not mis-attributed as
# idle time. The marker is sourceable env-var format so both shell and
# python (via shlex) callers can consume it without parsing complexity.
# Format:
#   PROMPT_READY_TS=<epoch-seconds>
#   PROMPT_READY_SESSION=<tmux session id at latch time>
#   PROMPT_READY_ENGINE=<claude|codex|...>
#   PROMPT_READY_SOURCE=<send-path|daemon-poll>
bridge_agent_prompt_ready_file() {
  local agent="$1"
  printf '%s/prompt-ready.env' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_note_prompt_ready() {
  # Usage: bridge_agent_note_prompt_ready <agent> <source>
  local agent="$1"
  local source_label="${2:-send-path}"
  local file=""
  local dir=""
  local engine=""
  local session=""
  local ts=""

  [[ -n "$agent" ]] || return 1
  # Kill switch (#589): operators can disable the latch entirely if it ever
  # backfires in production; absent the latch, idle counter falls back to
  # session_activity_ts as before.
  if [[ "${BRIDGE_DAEMON_IDLE_LATCH_DISABLED:-0}" == "1" ]]; then
    return 0
  fi

  file="$(bridge_agent_prompt_ready_file "$agent")"
  dir="$(dirname "$file")"
  engine="$(bridge_agent_engine "$agent" 2>/dev/null || true)"
  session="$(bridge_agent_session "$agent" 2>/dev/null || true)"
  ts="$(date +%s)"
  mkdir -p "$dir"

  # Idempotency: if a marker already exists for the current session, don't
  # overwrite it. The latch is a one-shot per session — we want the first
  # observed prompt-ready, not the most recent. send-path and daemon-poll
  # both call this on every cycle; keeping the original timestamp matters
  # for accurate boot-window measurement.
  if [[ -f "$file" ]]; then
    local existing_session=""
    # shellcheck disable=SC1090
    existing_session="$(grep '^PROMPT_READY_SESSION=' "$file" 2>/dev/null | head -n1 | cut -d= -f2-)"
    if [[ -n "$existing_session" && "$existing_session" == "$session" ]]; then
      return 0
    fi
  fi

  # Atomic write: stage to a per-writer tmp path and rename into place so a
  # concurrent reader (bridge-queue.py, daemon poll) never observes a
  # partially-populated marker if the writer is interrupted mid-print.
  local tmp="${file}.tmp.$$"
  {
    printf 'PROMPT_READY_TS=%s\n' "$ts"
    printf 'PROMPT_READY_SESSION=%s\n' "$session"
    printf 'PROMPT_READY_ENGINE=%s\n' "$engine"
    printf 'PROMPT_READY_SOURCE=%s\n' "$source_label"
  } >"$tmp"
  mv -f "$tmp" "$file"
}

bridge_agent_prompt_ready_epoch() {
  # Usage: bridge_agent_prompt_ready_epoch <agent>
  # Prints the epoch when the agent's current session first reached prompt-
  # ready, or "0" if no marker exists / the marker is stale (different
  # session id than the agent's currently-recorded session). Stale-session
  # validation prevents a leftover marker from a prior tmux session leaking
  # into a fresh boot window.
  local agent="$1"
  local file=""
  local current_session=""
  local marker_session=""
  local marker_ts=""

  [[ -n "$agent" ]] || { printf '0'; return 0; }
  file="$(bridge_agent_prompt_ready_file "$agent")"
  if [[ ! -f "$file" ]]; then
    printf '0'
    return 0
  fi

  marker_ts="$(grep '^PROMPT_READY_TS=' "$file" 2>/dev/null | head -n1 | cut -d= -f2-)"
  marker_session="$(grep '^PROMPT_READY_SESSION=' "$file" 2>/dev/null | head -n1 | cut -d= -f2-)"
  current_session="$(bridge_agent_session "$agent" 2>/dev/null || true)"

  [[ "$marker_ts" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  if [[ -n "$current_session" && -n "$marker_session" && "$marker_session" != "$current_session" ]]; then
    printf '0'
    return 0
  fi

  printf '%s' "$marker_ts"
}

bridge_agent_clear_prompt_ready() {
  local agent="$1"
  local file=""

  [[ -n "$agent" ]] || return 0
  file="$(bridge_agent_prompt_ready_file "$agent")"
  rm -f "$file" 2>/dev/null || true
}

bridge_agent_memory_daily_refresh_file() {
  local agent="$1"
  printf '%s/session-refresh.env' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_crash_report_file() {
  local agent="$1"
  printf '%s/crash/report.env' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_crash_report_body_file() {
  local agent="$1"
  printf '%s/crash-reports/%s.md' "$BRIDGE_SHARED_DIR" "$agent"
}

bridge_agent_crash_tail_file() {
  local agent="$1"
  printf '%s/crash/tail.log' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_crash_state_file() {
  local agent="$1"
  printf '%s/crash/state.env' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_stall_state_file() {
  local agent="$1"
  printf '%s/stall.env' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_stall_report_file() {
  local agent="$1"
  local classification="${2:-unknown}"
  printf '%s/stall/%s-%s.md' "$BRIDGE_SHARED_DIR" "$agent" "$classification"
}

bridge_agent_context_pressure_state_file() {
  local agent="$1"
  printf '%s/context-pressure.env' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_next_session_marker_file() {
  local agent="$1"
  printf '%s/next-session.sha' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_path_age_seconds() {
  local path="$1"

  [[ -e "$path" ]] || return 1
  bridge_require_python
  python3 - "$path" <<'PY'
import os
import sys
import time

print(max(0, int(time.time() - os.path.getmtime(sys.argv[1]))))
PY
}

bridge_agent_next_session_digest() {
  local agent="$1"
  local next_file=""

  next_file="$(bridge_agent_next_session_file "$agent")"
  [[ -f "$next_file" ]] || return 1
  bridge_sha1 "$(cat "$next_file")"
}

bridge_agent_next_session_is_delivered() {
  local agent="$1"
  local marker_file=""
  local digest=""
  local marker=""

  marker_file="$(bridge_agent_next_session_marker_file "$agent")"
  [[ -f "$marker_file" ]] || return 1
  digest="$(bridge_agent_next_session_digest "$agent" || true)"
  [[ -n "$digest" ]] || return 1
  marker="$(cat "$marker_file" 2>/dev/null || true)"
  [[ -n "$marker" && "$marker" == "$digest" ]]
}

bridge_agent_next_session_age_seconds() {
  local agent="$1"
  bridge_path_age_seconds "$(bridge_agent_next_session_file "$agent")"
}

bridge_agent_clear_next_session_state() {
  local agent="$1"
  rm -f "$(bridge_agent_next_session_file "$agent")" "$(bridge_agent_next_session_marker_file "$agent")"
}

bridge_agent_archive_next_session_state() {
  local agent="$1"
  local next_file=""
  local marker_file=""
  local archive_dir=""
  local archive_file=""
  local digest=""
  local digest_short=""
  local stamp=""
  local index=0

  next_file="$(bridge_agent_next_session_file "$agent")"
  marker_file="$(bridge_agent_next_session_marker_file "$agent")"
  [[ -f "$next_file" ]] || return 1

  digest="$(bridge_agent_next_session_digest "$agent" 2>/dev/null || true)"
  digest_short="${digest:0:12}"
  [[ -n "$digest_short" ]] || digest_short="unknown"
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  archive_dir="$(dirname "$next_file")/archive"
  archive_file="$archive_dir/NEXT-SESSION.${stamp}.${digest_short}.md"

  mkdir -p "$archive_dir"
  while [[ -e "$archive_file" ]]; do
    index=$((index + 1))
    archive_file="$archive_dir/NEXT-SESSION.${stamp}.${digest_short}.${index}.md"
  done
  mv "$next_file" "$archive_file"
  rm -f "$marker_file"
  printf '%s' "$archive_file"
}

bridge_agent_maybe_expire_next_session() {
  local agent="$1"
  local ttl_seconds="${2:-${BRIDGE_NEXT_SESSION_AUTO_CLEAR_SECONDS:-300}}"
  local age_seconds=0

  [[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=300
  bridge_agent_next_session_is_delivered "$agent" || return 1
  age_seconds="$(bridge_agent_next_session_age_seconds "$agent" || echo 0)"
  [[ "$age_seconds" =~ ^[0-9]+$ ]] || age_seconds=0
  (( age_seconds >= ttl_seconds )) || return 1
  bridge_agent_archive_next_session_state "$agent" >/dev/null || return 1
  printf '%s' "$age_seconds"
}

bridge_agent_pending_attention_file() {
  local agent="$1"
  printf '%s/pending-attention.env' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_pending_attention_lock_dir() {
  local agent="$1"
  printf '%s/pending-attention.lock' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_initial_inbox_marker_file() {
  local agent="$1"
  printf '%s/initial-inbox.started' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_agent_context_pressure_report_file() {
  local agent="$1"
  local severity="${2:-warning}"
  printf '%s/context-pressure/%s-%s.md' "$BRIDGE_SHARED_DIR" "$agent" "$severity"
}

bridge_agent_write_crash_report() {
  local agent="$1"
  local engine="$2"
  local fail_count="$3"
  local exit_code="$4"
  local stderr_file="$5"
  local launch_cmd="$6"
  local launch_cmd_display=""
  local report_file=""
  local tail_file=""
  local error_hash=""
  local stderr_tail=""

  launch_cmd_display="$(bridge_redact_inline_env_secrets "$launch_cmd")"
  report_file="$(bridge_agent_crash_report_file "$agent")"
  tail_file="$(bridge_agent_crash_tail_file "$agent")"
  mkdir -p "$(dirname "$report_file")"
  if [[ -f "$stderr_file" ]]; then
    tail -n 50 "$stderr_file" 2>/dev/null >"$tail_file" || true
    stderr_tail="$(cat "$tail_file" 2>/dev/null || true)"
  else
    : >"$tail_file"
  fi
  error_hash="$(bridge_sha1 "${exit_code}|${stderr_tail}")"
  cat >"$report_file" <<EOF
CRASH_AGENT=$(printf '%q' "$agent")
CRASH_ENGINE=$(printf '%q' "$engine")
CRASH_FAIL_COUNT=$(printf '%q' "$fail_count")
CRASH_EXIT_CODE=$(printf '%q' "$exit_code")
CRASH_STDERR_FILE=$(printf '%q' "$stderr_file")
CRASH_TAIL_FILE=$(printf '%q' "$tail_file")
CRASH_LAUNCH_CMD=$(printf '%q' "$launch_cmd_display")
CRASH_ERROR_HASH=$(printf '%q' "$error_hash")
CRASH_REPORTED_AT=$(printf '%q' "$(bridge_now_iso)")
EOF
}

bridge_agent_clear_crash_report() {
  local agent="$1"
  rm -f \
    "$(bridge_agent_crash_report_file "$agent")" \
    "$(bridge_agent_crash_report_body_file "$agent")" \
    "$(bridge_agent_crash_tail_file "$agent")" \
    "$(bridge_agent_crash_state_file "$agent")" >/dev/null 2>&1 || true
}

# #256 Gap 2: persist the rapid-fail circuit-breaker trip so the daemon's
# autostart gate can honour it and stop relaunching a quarantined agent.
# `bridge-run.sh` has been calling this helper since the circuit breaker
# landed (line 512), but the helper itself was missing — the unbound-function
# call raised `command not found` under `set -e`, the broken-launch file was
# never written, and the daemon kept relaunching the crashing agent (137×
# in 2h13m on the reference host during the #254 repro). This definition
# closes that loop.
bridge_agent_write_broken_launch_state() {
  local agent="$1"
  local engine="${2:-}"
  local fail_count="${3:-0}"
  local exit_code="${4:-0}"
  local stderr_file="${5:-}"
  local launch_cmd="${6:-}"
  local err_size_before="${7:-0}"
  local file=""
  local launch_cmd_display=""

  launch_cmd_display="$(bridge_redact_inline_env_secrets "$launch_cmd")"
  file="$(bridge_agent_broken_launch_file "$agent")"
  mkdir -p "$(dirname "$file")"
  bridge_require_python
  python3 - "$file" "$agent" "$engine" "$fail_count" "$exit_code" "$stderr_file" "$launch_cmd_display" "$err_size_before" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def _as_int(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


path = Path(sys.argv[1])
agent, engine, fail_count, exit_code, stderr_file, launch_cmd, err_size_before = sys.argv[2:]

payload = {
    "agent": agent,
    "engine": engine,
    "fail_count": _as_int(fail_count),
    "exit_code": _as_int(exit_code),
    "stderr_file": stderr_file,
    "launch_cmd": launch_cmd,
    "err_size_before": _as_int(err_size_before),
    "quarantined_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
}

path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
PY
}

bridge_agent_clear_broken_launch() {
  local agent="$1"
  rm -f "$(bridge_agent_broken_launch_file "$agent")" >/dev/null 2>&1 || true
}

bridge_agent_ack_crash_report() {
  local agent="$1"
  local report_file=""
  local state_file=""
  local CRASH_AGENT=""
  local CRASH_ERROR_HASH=""
  local CRASH_LAST_HASH=""
  local CRASH_LAST_REPORT_TS=""
  local now_ts=0

  report_file="$(bridge_agent_crash_report_file "$agent")"
  if [[ -f "$report_file" ]]; then
    if ! "${BASH:-bash}" -n "$report_file" >/dev/null 2>&1; then
      bridge_agent_clear_crash_report "$agent" >/dev/null 2>&1 || true
      return 1
    fi
    # shellcheck source=/dev/null
    source "$report_file" 2>/dev/null || {
      bridge_agent_clear_crash_report "$agent" >/dev/null 2>&1 || true
      return 1
    }
    if [[ -n "${CRASH_AGENT:-}" && "$CRASH_AGENT" != "$agent" ]]; then
      return 1
    fi
  fi

  state_file="$(bridge_agent_crash_state_file "$agent")"
  if [[ -f "$state_file" ]]; then
    if ! "${BASH:-bash}" -n "$state_file" >/dev/null 2>&1; then
      rm -f "$state_file" >/dev/null 2>&1 || true
    else
      # shellcheck source=/dev/null
      source "$state_file" 2>/dev/null || {
        rm -f "$state_file" >/dev/null 2>&1 || true
      }
    fi
  fi

  # Fall back to whatever hash state.env last recorded when report.env
  # has already been cleaned up (e.g. after a successful auto-restart).
  # Without this fallback the ack silently no-ops and the daemon
  # re-queues the same [crash-loop] task on every sweep. See #109.
  CRASH_ERROR_HASH="${CRASH_ERROR_HASH:-${CRASH_LAST_HASH:-}}"
  [[ -n "$CRASH_ERROR_HASH" ]] || return 1

  now_ts="$(date +%s)"
  mkdir -p "$(dirname "$state_file")"
  cat >"$state_file" <<EOF
CRASH_LAST_HASH=$(printf '%q' "${CRASH_LAST_HASH:-$CRASH_ERROR_HASH}")
CRASH_LAST_REPORT_TS=$(printf '%q' "${CRASH_LAST_REPORT_TS:-$now_ts}")
CRASH_ACK_HASH=$(printf '%q' "$CRASH_ERROR_HASH")
CRASH_ACK_TS=$(printf '%q' "$now_ts")
EOF
}

bridge_agent_memory_daily_refresh_pending() {
  local agent="$1"
  [[ -f "$(bridge_agent_memory_daily_refresh_file "$agent")" ]]
}

bridge_agent_note_memory_daily_refresh() {
  local agent="$1"
  local run_id="$2"
  local slot="${3:-}"
  local file

  file="$(bridge_agent_memory_daily_refresh_file "$agent")"
  mkdir -p "$(dirname "$file")"
  cat >"$file" <<EOF
REFRESH_REASON='memory-daily'
REFRESH_RUN_ID=$(printf '%q' "$run_id")
REFRESH_SLOT=$(printf '%q' "$slot")
REFRESH_REQUESTED_AT=$(printf '%q' "$(bridge_now_iso)")
EOF
}

bridge_agent_clear_memory_daily_refresh() {
  local agent="$1"
  rm -f "$(bridge_agent_memory_daily_refresh_file "$agent")"
}

bridge_agent_idle_since_epoch() {
  local agent="$1"
  local file
  local value

  file="$(bridge_agent_idle_since_file "$agent")"
  [[ -f "$file" ]] || return 1
  value="$(cat "$file" 2>/dev/null)" || {
    bridge_agent_clear_idle_marker "$agent" >/dev/null 2>&1 || true
    return 1
  }
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$value"
}

bridge_agent_idle_marker_exists() {
  local agent="$1"
  [[ -f "$(bridge_agent_idle_since_file "$agent")" ]]
}

bridge_agent_manual_stop_active() {
  local agent="$1"
  local file
  local value

  file="$(bridge_agent_manual_stop_file "$agent")"
  [[ -f "$file" ]] || return 1
  value="$(cat "$file" 2>/dev/null)" || {
    bridge_agent_clear_manual_stop "$agent" >/dev/null 2>&1 || true
    return 1
  }
  [[ "$value" =~ ^[0-9]+$ ]]
}

bridge_agent_mark_idle_now() {
  local agent="$1"
  local dir
  local file

  dir="$(bridge_agent_idle_marker_dir "$agent")"
  file="$(bridge_agent_idle_since_file "$agent")"
  mkdir -p "$dir"
  printf '%s\n' "$(date +%s)" >"$file"
}

bridge_agent_mark_manual_stop() {
  local agent="$1"
  local dir
  local file

  dir="$(bridge_agent_idle_marker_dir "$agent")"
  file="$(bridge_agent_manual_stop_file "$agent")"
  mkdir -p "$dir"
  printf '%s\n' "$(date +%s)" >"$file"
}

bridge_agent_clear_idle_marker() {
  local agent="$1"
  local file
  local dir

  file="$(bridge_agent_idle_since_file "$agent")"
  dir="$(bridge_agent_idle_marker_dir "$agent")"
  rm -f "$file"
  # Issue #629: drop the missing-marker retry counter so a future stale
  # marker scenario starts fresh — otherwise the counter could ratchet
  # the synthetic-marker fallback in earlier than warranted.
  rm -f "$(bridge_agent_missing_marker_retries_file "$agent")"
  rmdir "$dir" >/dev/null 2>&1 || true
}

bridge_agent_clear_manual_stop() {
  local agent="$1"
  local file
  local dir

  file="$(bridge_agent_manual_stop_file "$agent")"
  dir="$(bridge_agent_idle_marker_dir "$agent")"

  # v0.8.8 #714 (item 2): when the host runs linux-user isolation, the
  # idle-marker directory `state/agents/<agent>/` is owned by
  # `agent-bridge-<agent>:ab-controller mode 2750` (per
  # bridge_linux_prepare_agent_isolation). The controller user is in
  # the group but only has `r-x` at the marker dir, so plain `rm -f`
  # on the manual-stop file inside it raises EACCES. Same shape PR
  # #692 solved for `runtime/history.env` via
  # `bridge_state_v2_isolated_target` + sudo install. Here the file is
  # under `state/agents/`, not `$BRIDGE_AGENT_ROOT_V2/`, so the
  # existing predicate doesn't match — we gate on
  # `bridge_agent_linux_user_isolation_effective` directly. On
  # non-Linux hosts `bridge_linux_sudo_root` falls through to the
  # direct invocation, so this branch is a no-op there and on
  # non-isolated agents the plain `rm -f` already succeeded.
  if ! rm -f "$file" 2>/dev/null; then
    if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
      if ! bridge_linux_sudo_root rm -f "$file" 2>/dev/null; then
        bridge_warn "bridge_agent_clear_manual_stop: failed to remove $file (agent=$agent); manual-stop may persist and re-suppress autostart"
      fi
    else
      bridge_warn "bridge_agent_clear_manual_stop: failed to remove $file (agent=$agent); manual-stop may persist and re-suppress autostart"
    fi
  fi

  if ! rmdir "$dir" >/dev/null 2>&1; then
    if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
      # rmdir on a non-empty dir is expected and not an error; suppress
      # only the silent-fail path. The sudo attempt is best-effort.
      bridge_linux_sudo_root rmdir "$dir" >/dev/null 2>&1 || true
    fi
  fi
}

bridge_reconcile_idle_markers() {
  local agent
  local file
  local value

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    file="$(bridge_agent_idle_since_file "$agent")"
    [[ -f "$file" ]] || continue

    # #752 M3: per-marker best-effort under bridge-sync's `set -e` — a single
    # locked dir / perm-denied marker must not cascade-abort subsequent agents.
    if ! bridge_agent_is_active "$agent"; then
      if ! bridge_agent_clear_idle_marker "$agent" 2>/dev/null; then
        bridge_warn "reconcile_idle_markers: clear (inactive) failed for agent='$agent' — skipping; next reconcile will retry"
      fi
      continue
    fi

    value="$(cat "$file" 2>/dev/null)" || {
      bridge_agent_clear_idle_marker "$agent" >/dev/null 2>&1 || true
      continue
    }
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
      if ! bridge_agent_clear_idle_marker "$agent" 2>/dev/null; then
        bridge_warn "reconcile_idle_markers: clear (non-numeric) failed for agent='$agent' — skipping; next reconcile will retry"
        continue
      fi
    fi
  done
}

bridge_archive_dynamic_agent() {
  local agent="$1"
  local history_file

  history_file="$(bridge_history_file_for_agent "$agent")"
  bridge_write_agent_state_file "$agent" "$history_file"
}

bridge_remove_dynamic_agent_file() {
  local agent="$1"
  local file

  file="$(bridge_agent_meta_file "$agent")"
  if [[ -n "$file" && -f "$file" ]]; then
    rm -f "$file"
  fi
}

bridge_persist_agent_state() {
  local agent="$1"

  if [[ "$(bridge_agent_source "$agent")" == "dynamic" ]]; then
    bridge_write_dynamic_agent_file "$agent"
  fi
  bridge_write_agent_state_file "$agent" "$(bridge_history_file_for_agent "$agent")"
}

bridge_detect_claude_session_id() {
  local workdir="$1"
  local since_ms="${2:-0}"
  local exclude_csv="${3:-}"

  python3 - "$workdir" "$since_ms" "$exclude_csv" <<'PY'
import glob
import json
import os
import re
import sys

workdir = os.path.realpath(sys.argv[1])
since_ms = int(sys.argv[2] or "0")
if 0 < since_ms < 10**11:
    since_ms *= 1000
exclude = {x for x in sys.argv[3].split(",") if x}
best = None


def read_transcript_session_id(path):
    try:
        if os.path.getsize(path) <= 0:
            return None
        with open(path, "r", encoding="utf-8") as fh:
            seen = 0
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                seen += 1
                try:
                    obj = json.loads(line)
                except Exception:
                    if seen >= 10:
                        break
                    continue
                if isinstance(obj, dict):
                    found = obj.get("sessionId")
                    if found:
                        return found
                if seen >= 10:
                    break
    except Exception:
        return None
    return None


def workdir_slug_candidates(path):
    # Claude encodes the project dir by replacing "/" (always) and "." (most
    # versions) with "-". Accept both variants so older transcripts still
    # match.
    slash_only = path.replace("/", "-")
    slash_and_dot = re.sub(r"[/.]", "-", path)
    candidates = [slash_only]
    if slash_and_dot != slash_only:
        candidates.append(slash_and_dot)
    return candidates


# Primary: live sessions/<pid>.json records.
for path in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue
    sid = data.get("sessionId")
    cwd = os.path.realpath(str(data.get("cwd") or ""))
    started = int(data.get("startedAt") or 0)
    if cwd != workdir or not sid or sid in exclude:
        continue
    if since_ms and started < max(0, since_ms - 300000):
        continue
    transcript = None
    for slug in workdir_slug_candidates(workdir):
        candidate = os.path.expanduser(
            f"~/.claude/projects/{slug}/{sid}.jsonl"
        )
        if os.path.isfile(candidate):
            transcript = candidate
            break
    if transcript is None:
        for candidate in glob.glob(
            os.path.expanduser(f"~/.claude/projects/**/{sid}.jsonl"),
            recursive=True,
        ):
            if os.path.isfile(candidate):
                transcript = candidate
                break
    if transcript is None:
        continue
    if best is None or started > best[0]:
        best = (started, sid)

# Fallback: dead processes left behind a transcript but sessions/<pid>.json
# has already been cleaned up. Pick the most recent transcript in the
# agent's project dir so `continue=1` agents can resume after a restart.
if best is None:
    transcripts = []
    for slug in workdir_slug_candidates(workdir):
        transcripts.extend(
            glob.glob(os.path.expanduser(f"~/.claude/projects/{slug}/*.jsonl"))
        )
    for transcript in transcripts:
        stem = os.path.splitext(os.path.basename(transcript))[0]
        if not stem or stem in exclude:
            continue
        try:
            mtime_ms = int(os.path.getmtime(transcript) * 1000)
        except Exception:
            continue
        if since_ms and mtime_ms < max(0, since_ms - 300000):
            continue
        # Filename is what `claude --resume` takes; trust it even if the
        # first-line sessionId disagrees (legacy transcripts may lack it).
        read_transcript_session_id(transcript)
        if best is None or mtime_ms > best[0]:
            best = (mtime_ms, stem)

print(best[1] if best else "")
PY
}

# bridge_resolve_resume_session_id is the single source of truth for whether
# a Claude transcript should be resumed. It is pure: callers pass everything
# in (engine, agent, workdir, candidate_session_id [, max_age_hours]) and it
# does not read or write BRIDGE_AGENT_* arrays. The caller owns state.
#
#   stdout: accepted_id (may differ from candidate; empty means "no resume").
#   exit:   0 = candidate accepted as-is (or non-claude engine passthrough)
#           1 = no eligible transcript at all (caller MUST NOT --continue/--resume)
#           2 = candidate ineligible/stale, replaced with a fresher eligible id
#   stderr: one debug-level reason line on rc=1 or rc=2 (suppressed by the
#           legacy boolean wrappers below since they are probes).
#
# Eligibility: ~/.claude/projects/<workdir-slug>/<id>.jsonl exists, size > 0,
# and mtime within `max_age_hours` (default ${BRIDGE_RESUME_MAX_AGE_HOURS:-48}).
# When the candidate is ineligible but the workdir has another in-window
# transcript, the freshest of those is returned (rc=2). If no in-window
# transcript exists, rc=1.
bridge_resolve_resume_session_id() {
  local engine="$1"
  local agent="${2:-}"
  local workdir="$3"
  local candidate="${4:-}"
  local max_age_hours="${5:-${BRIDGE_RESUME_MAX_AGE_HOURS:-48}}"

  if [[ "$engine" != "claude" ]]; then
    if [[ -n "$candidate" ]]; then printf '%s' "$candidate"; fi
    return 0
  fi
  [[ -n "$workdir" ]] || return 1

  python3 - "$workdir" "$candidate" "$max_age_hours" "$agent" <<'PY'
import os
import re
import sys
import time

input_workdir = sys.argv[1]
workdir = os.path.realpath(input_workdir)
candidate = sys.argv[2] or ""
try:
    max_age_hours = float(sys.argv[3])
except ValueError:
    max_age_hours = 48.0
agent = sys.argv[4] or ""

cutoff = time.time() - max_age_hours * 3600


def workdir_slug_candidates(path):
    slash_only = path.replace("/", "-")
    slash_and_dot = re.sub(r"[/.]", "-", path)
    candidates = [slash_only]
    if slash_and_dot != slash_only:
        candidates.append(slash_and_dot)
    return candidates


def ordered_slug_candidates(paths):
    candidates = []
    seen = set()
    for path in paths:
        for slug in workdir_slug_candidates(path):
            if slug not in seen:
                seen.add(slug)
                candidates.append(slug)
    return candidates


eligible = []
seen_stems = set()
for slug in ordered_slug_candidates([input_workdir, workdir]):
    base = os.path.expanduser(f"~/.claude/projects/{slug}")
    if not os.path.isdir(base):
        continue
    try:
        entries = os.listdir(base)
    except OSError:
        continue
    for entry in entries:
        if not entry.endswith(".jsonl"):
            continue
        stem = entry[: -len(".jsonl")]
        if not stem or stem in seen_stems:
            continue
        full = os.path.join(base, entry)
        try:
            st = os.stat(full)
        except OSError:
            continue
        if not os.path.isfile(full) or st.st_size <= 0:
            continue
        if st.st_mtime < cutoff:
            continue
        seen_stems.add(stem)
        eligible.append((st.st_mtime, stem))

if not eligible:
    sys.stderr.write(
        f"[debug] resume id rejected: no eligible transcript within {max_age_hours}h "
        f"for workdir={workdir} agent={agent}\n"
    )
    sys.exit(1)

eligible.sort(key=lambda t: t[0], reverse=True)
freshest_stem = eligible[0][1]

if candidate and candidate == freshest_stem:
    print(candidate, end="")
    sys.exit(0)

if candidate:
    sys.stderr.write(
        f"[debug] resume id replaced: candidate={candidate} "
        f"freshest={freshest_stem} workdir={workdir} agent={agent}\n"
    )
    print(freshest_stem, end="")
    sys.exit(2)

# Empty candidate: freshest eligible is just an acceptance, not a replacement.
print(freshest_stem, end="")
sys.exit(0)
PY
}

# Returns 0 (true) if the given workdir has any in-window
# `~/.claude/projects/<slug>/*.jsonl` transcript. Used by launch builders to
# decide whether `claude --continue`/picker is safe to invoke. Backed by
# bridge_resolve_resume_session_id so the freshness gate is inherited; the
# resolver's debug stderr is suppressed because this is a probe.
bridge_claude_has_resumable_session_state() {
  local workdir="$1"
  [[ -n "$workdir" ]] || return 1
  local rc=0
  bridge_resolve_resume_session_id claude "" "$workdir" "" >/dev/null 2>/dev/null || rc=$?
  [[ "$rc" != 1 ]]
}

# Returns 0 (true) iff the given session id is eligible to resume for the
# workdir under the same freshness rule the resolver applies. Kept for
# backward-compatible callers; new code should call
# bridge_resolve_resume_session_id directly. Resolver stderr is suppressed
# because this is used as a boolean probe during roster hydration and launch
# probes — those paths must not emit noisy diagnostics.
bridge_claude_session_id_exists() {
  local session_id="$1"
  local workdir="$2"
  [[ -n "$session_id" && -n "$workdir" ]] || return 1
  local accepted="" rc=0
  accepted="$(bridge_resolve_resume_session_id claude "" "$workdir" "$session_id" 2>/dev/null)" || rc=$?
  [[ "$rc" == 0 && "$accepted" == "$session_id" ]]
}

bridge_detect_codex_session_id() {
  local workdir="$1"
  local since_epoch="${2:-0}"
  local exclude_csv="${3:-}"

  python3 - "$workdir" "$since_epoch" "$exclude_csv" <<'PY'
import datetime as dt
import glob
import json
import os
import sys

workdir = sys.argv[1]
since_epoch = float(sys.argv[2] or "0")
if since_epoch > 10**11:
    since_epoch /= 1000.0
exclude = {x for x in sys.argv[3].split(",") if x}
paths = sorted(
    glob.glob(os.path.expanduser("~/.codex/sessions/**/*.jsonl"), recursive=True),
    key=lambda p: os.path.getmtime(p),
    reverse=True,
)[:500]
best = None

def parse_iso(value: str) -> float:
    if not value:
        return 0.0
    value = value.replace("Z", "+00:00")
    try:
        return dt.datetime.fromisoformat(value).timestamp()
    except Exception:
        return 0.0

for path in paths:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") != "session_meta":
                    continue
                payload = obj.get("payload", {})
                sid = payload.get("id")
                cwd = payload.get("cwd")
                ts = parse_iso(payload.get("timestamp"))
                if cwd != workdir or not sid or sid in exclude:
                    break
                if since_epoch and ts < max(0.0, since_epoch - 300.0):
                    break
                if best is None or ts > best[0]:
                    best = (ts, sid)
                break
    except Exception:
        continue

print(best[1] if best else "")
PY
}

bridge_detect_session_id() {
  local engine="$1"
  local workdir="$2"
  local since_hint="$3"
  local exclude_csv="${4:-}"

  case "$engine" in
    codex)
      bridge_detect_codex_session_id "$workdir" "$since_hint" "$exclude_csv"
      ;;
    claude)
      bridge_detect_claude_session_id "$workdir" "$since_hint" "$exclude_csv"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_refresh_agent_session_id() {
  local agent="$1"
  local attempts="${2:-8}"
  local sleep_seconds="${3:-0.25}"
  local extra_exclude_csv="${4:-}"
  local since_hint sid detected exclude_csv
  local -a excluded=()
  local -a extra_excluded=()
  local other try_index extra

  sid="$(bridge_agent_session_id "$agent")"
  if [[ -n "$sid" ]]; then
    if ! bridge_channel_csv_contains "$extra_exclude_csv" "$sid"; then
      printf '%s' "$sid"
      return 0
    fi
  fi
  if [[ -n "$extra_exclude_csv" ]]; then
    IFS=',' read -r -a extra_excluded <<<"$extra_exclude_csv"
  fi

  since_hint="${BRIDGE_AGENT_CREATED_AT[$agent]-$(date +%s)}"
  for ((try_index = 0; try_index < attempts; try_index += 1)); do
    excluded=()
    for extra in "${extra_excluded[@]}"; do
      extra="$(bridge_trim_whitespace "$extra")"
      [[ -n "$extra" ]] || continue
      excluded+=("$extra")
    done
    for other in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$other" == "$agent" ]] && continue
      sid="$(bridge_agent_session_id "$other")"
      if [[ -n "$sid" ]]; then
        excluded+=("$sid")
      fi
    done
    exclude_csv="$(IFS=,; echo "${excluded[*]}")"

    detected="$(bridge_detect_session_id \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_workdir "$agent")" \
      "$since_hint" \
      "$exclude_csv")"

    if [[ -n "$detected" ]]; then
      BRIDGE_AGENT_SESSION_ID["$agent"]="$detected"
      bridge_persist_agent_state "$agent"
      printf '%s' "$detected"
      return 0
    fi

    sleep "$sleep_seconds"
  done

  return 1
}

bridge_daemon_recorded_pid() {
  if [[ -f "$BRIDGE_DAEMON_PID_FILE" ]]; then
    cat "$BRIDGE_DAEMON_PID_FILE"
  fi
}

bridge_daemon_pid() {
  local pid=""
  local candidate=""
  local pattern=""
  local cmdline=""

  pid="$(bridge_daemon_recorded_pid)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    # Issue #683: pid recycling guard. A stale pid file plus a recycled
    # OS pid would let `kill -0` succeed for a totally unrelated process,
    # yielding "running pid=NNNN" from cmd_status that contradicts the
    # live-listener probes. Verify cmdline before trusting the recorded pid;
    # fall through to the pgrep-by-pattern path on mismatch.
    cmdline="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ -z "$cmdline" || "$cmdline" == *"bridge-daemon.sh run"* ]]; then
      printf '%s' "$pid"
      return 0
    fi
  fi

  pattern="$BRIDGE_HOME/bridge-daemon.sh run"
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if kill -0 "$candidate" 2>/dev/null; then
      if [[ "$candidate" != "$pid" ]]; then
        printf '%s\n' "$candidate" >"$BRIDGE_DAEMON_PID_FILE"
      fi
      printf '%s' "$candidate"
      return 0
    fi
  done < <(pgrep -f "$pattern" 2>/dev/null || true)

  return 1
}

bridge_daemon_is_running() {
  local pid

  pid="$(bridge_daemon_pid 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

bridge_daemon_all_pids() {
  # Issue #269: cmd_stop only killed the pid-file PID, so any earlier daemon
  # that lost its pid-file (e.g. install moved paths, orphan re-parented to
  # PPID=1, manual `bridge-daemon.sh run` from diagnostics) survived stop +
  # systemd restart and ran concurrently with the systemd-managed daemon —
  # silently ignoring later env drop-ins. Match every own-user process whose
  # cmdline ends in "bridge-daemon.sh run" so stop can sweep all of them,
  # including daemons launched from a different BRIDGE_HOME path.
  # BRIDGE_DAEMON_STOP_PATTERN overrides the match pattern so isolated tests
  # do not pick up the operator's live daemons via system-wide pgrep.
  # The `-U "$(id -u)"` scope is required because the previous narrower
  # fallback (path-prefixed by BRIDGE_HOME) implicitly limited matches to
  # this operator; broadening to a path-agnostic pattern without a UID
  # filter would let `pgrep -f` return processes owned by other users
  # (default on Linux), inflating orphan_count and risking SIGTERM to a
  # different user's daemon if cmd_stop is ever invoked under sudo/root.
  local pattern="${BRIDGE_DAEMON_STOP_PATTERN:-bridge-daemon\\.sh run$}"
  local self_pid="${BASHPID:-$$}"
  local self_uid
  self_uid="$(id -u 2>/dev/null || printf '%s' "${UID:-}")"
  local pgrep_user_args=()
  [[ -n "$self_uid" ]] && pgrep_user_args=(-U "$self_uid")
  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ "$candidate" == "$self_pid" ]] && continue
    printf '%s\n' "$candidate"
  done < <(pgrep "${pgrep_user_args[@]}" -f "$pattern" 2>/dev/null || true)
}

bridge_write_agent_snapshot() {
  local file="$1"
  local agent
  local active
  local session
  local activity
  local prompt_ready_ts
  local prompt_ready_session
  local prompt_ready_source
  local prompt_ready_file

  {
    # Issue #589: extended snapshot format adds three trailing columns for
    # the prompt-ready latch (timestamp, session-id, source). Older daemon
    # consumers that read only the first six columns are unaffected; the
    # python upsert path uses .get() with default empty for the new keys.
    echo -e "agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\tprompt_ready_ts\tprompt_ready_session\tprompt_ready_source"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      active=0
      session="$(bridge_agent_session "$agent")"
      activity=""
      if bridge_agent_is_active "$agent"; then
        active=1
        activity="$(bridge_tmux_session_activity_ts "$session")"
      fi

      prompt_ready_ts=""
      prompt_ready_session=""
      prompt_ready_source=""
      prompt_ready_file="$(bridge_agent_prompt_ready_file "$agent")"
      if [[ -f "$prompt_ready_file" ]]; then
        prompt_ready_ts="$(grep '^PROMPT_READY_TS=' "$prompt_ready_file" 2>/dev/null | head -n1 | cut -d= -f2-)"
        prompt_ready_session="$(grep '^PROMPT_READY_SESSION=' "$prompt_ready_file" 2>/dev/null | head -n1 | cut -d= -f2-)"
        prompt_ready_source="$(grep '^PROMPT_READY_SOURCE=' "$prompt_ready_file" 2>/dev/null | head -n1 | cut -d= -f2-)"
        # Stale-session guard: if the marker session id doesn't match the
        # agent's current session, drop the latch values. The python path
        # would compute the same suppression but only if it had access to
        # the live session id, which it doesn't.
        if [[ -n "$prompt_ready_session" && -n "$session" && "$prompt_ready_session" != "$session" ]]; then
          prompt_ready_ts=""
          prompt_ready_session=""
          prompt_ready_source=""
        fi
      fi

      echo -e "${agent}\t$(bridge_agent_engine "$agent")\t${session}\t$(bridge_agent_workdir "$agent")\t${active}\t${activity}\t${prompt_ready_ts}\t${prompt_ready_session}\t${prompt_ready_source}"
    done
  } >"$file"
}

bridge_write_roster_status_snapshot() {
  local file="$1"
  local agent
  local active
  local wake
  local channels
  local channel_reason
  local configured_channels
  local session
  local activity_state
  local loop_mode
  local engine
  local recent

  {
    echo -e "agent\tengine\tsession\tworkdir\tsource\tloop\tactive\twake\tchannels\tchannel_reason\tactivity_state\tconfigured_channels"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      active=0
      wake="-"
      channels="$(bridge_agent_channel_status "$agent")"
      channel_reason=""
      if [[ "$channels" == "miss" ]]; then
        channel_reason="$(bridge_agent_channel_runtime_drift_reason "$agent")"
        if [[ -z "$channel_reason" ]]; then
          channel_reason="$(bridge_agent_channel_status_reason "$agent")"
        fi
        channel_reason="${channel_reason//$'\t'/ }"
        channel_reason="${channel_reason//$'\n'/ }"
      fi
      activity_state="stopped"
      session="$(bridge_agent_session "$agent")"
      engine="$(bridge_agent_engine "$agent")"
      loop_mode="$(bridge_agent_loop "$agent")"
      configured_channels="$(bridge_agent_channels_csv "$agent")"
      configured_channels="${configured_channels//$'\t'/ }"
      configured_channels="${configured_channels//$'\n'/ }"
      if bridge_agent_is_active "$agent"; then
        active=1
        recent=""
        if bridge_tmux_engine_requires_prompt "$engine"; then
          recent="$(bridge_capture_recent "$session" 80 2>/dev/null || true)"
        fi
        if bridge_agent_requires_wake_channel "$agent"; then
          wake="ok"
          if [[ "$engine" == "claude" && -n "$recent" ]]; then
            case "$(bridge_tmux_claude_blocker_state_from_text "$recent")" in
              trust|summary)
                wake="block"
                ;;
            esac
          fi
        fi
        if bridge_tmux_session_has_prompt_from_text "$engine" "$recent"; then
          activity_state="idle"
        else
          activity_state="working"
        fi
      fi

      echo -e "${agent}\t${engine}\t${session}\t$(bridge_agent_workdir "$agent")\t$(bridge_agent_source "$agent")\t${loop_mode}\t${active}\t${wake}\t${channels}\t${channel_reason}\t${activity_state}\t${configured_channels}"
    done
  } >"$file"
}

bridge_task_daemon_step() {
  local snapshot_file="$1"
  local ready_agents_file="${2:-}"
  local zombie_threshold="${BRIDGE_ZOMBIE_NUDGE_THRESHOLD:-10}"
  local args=(
    daemon-step
    --snapshot "$snapshot_file"
    --lease-seconds "$BRIDGE_TASK_LEASE_SECONDS"
    --heartbeat-window "$BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS"
    --idle-threshold "$BRIDGE_TASK_IDLE_NUDGE_SECONDS"
    --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS"
    --zombie-threshold "$zombie_threshold"
    --blocked-reminder-seconds "${BRIDGE_TASK_BLOCKED_REMINDER_SECONDS:-86400}"
    --blocked-escalate-seconds "${BRIDGE_TASK_BLOCKED_ESCALATE_SECONDS:-604800}"
    --admin-agent "${BRIDGE_ADMIN_AGENT_ID:-patch}"
  )

  if [[ -n "$ready_agents_file" && -f "$ready_agents_file" ]]; then
    args+=(--ready-agents-file "$ready_agents_file")
  fi

  bridge_queue_cli "${args[@]}"
}

bridge_task_note_nudge() {
  local agent="$1"
  local key="${2:-}"
  local zombie_threshold="${BRIDGE_ZOMBIE_NUDGE_THRESHOLD:-10}"
  local args=(note-nudge --agent "$agent" --zombie-threshold "$zombie_threshold")

  if [[ -n "$key" ]]; then
    args+=(--key "$key")
  fi

  bridge_queue_cli "${args[@]}" >/dev/null
}

bridge_queue_task_status() {
  # Issue #331 Track A: lightweight status read used by the daemon's nudge
  # verifier. Reuses the existing `show --format shell` payload (TASK_STATUS)
  # so we don't introduce a new queue subcommand.
  local task_id="${1:-}"
  local status_shell=""

  [[ -n "$task_id" ]] || return 1
  status_shell="$(bridge_queue_cli show "$task_id" --format shell 2>/dev/null)" || return 1
  TASK_STATUS=""
  # shellcheck disable=SC1090
  source /dev/stdin <<<"$status_shell"
  [[ -n "$TASK_STATUS" ]] || return 1
  printf '%s' "$TASK_STATUS"
}

bridge_render_active_roster() {
  local tmp_tsv tmp_md updated session_id
  local agent
  local summary_output=""
  local -A queue_counts=()
  local -A claimed_counts=()

  if summary_output="$(bridge_queue_cli summary --format tsv 2>/dev/null)"; then
    while IFS=$'\t' read -r agent_name queued claimed _blocked _active _idle _last_seen _last_nudge _session _engine _workdir; do
      [[ -z "$agent_name" ]] && continue
      queue_counts["$agent_name"]="$queued"
      claimed_counts["$agent_name"]="$claimed"
    done <<<"$summary_output"
  fi

  tmp_tsv="$(mktemp)"
  tmp_md="$(mktemp)"
  updated="$(bridge_now_iso)"

  {
    echo -e "agent\tengine\tsession\tcwd\tsource\tloop\tcontinue\tqueued\tclaimed\tsession_id\tupdated_at"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      if ! bridge_agent_is_active "$agent"; then
        continue
      fi

      session_id="$(bridge_agent_session_id "$agent")"
      echo -e "${agent}\t$(bridge_agent_engine "$agent")\t$(bridge_agent_session "$agent")\t$(bridge_agent_workdir "$agent")\t$(bridge_agent_source "$agent")\t$(bridge_agent_loop "$agent")\t$(bridge_agent_continue "$agent")\t${queue_counts[$agent]-0}\t${claimed_counts[$agent]-0}\t${session_id}\t${updated}"
    done
  } >"$tmp_tsv"

  {
    echo "# Active Agent Roster"
    echo
    echo "updated_at: ${updated}"
    echo
    echo "| agent | engine | session | source | loop | inbox | claimed | cwd | session_id |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      if ! bridge_agent_is_active "$agent"; then
        continue
      fi

      session_id="$(bridge_agent_session_id "$agent")"
      echo "| ${agent} | $(bridge_agent_engine "$agent") | $(bridge_agent_session "$agent") | $(bridge_agent_source "$agent") | $(bridge_agent_loop "$agent") | ${queue_counts[$agent]-0} | ${claimed_counts[$agent]-0} | $(bridge_agent_workdir "$agent") | ${session_id} |"
    done
  } >"$tmp_md"

  mv "$tmp_tsv" "$BRIDGE_ACTIVE_ROSTER_TSV"
  mv "$tmp_md" "$BRIDGE_ACTIVE_ROSTER_MD"
}
