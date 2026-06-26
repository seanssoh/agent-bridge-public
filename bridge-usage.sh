#!/usr/bin/env bash
# bridge-usage.sh — inspect and monitor Claude/Codex usage windows
#
# Issue #831: status/monitor must read each Claude agent's *own* usage cache
# (under that agent's home), not just the controller's $HOME, so the daemon
# can detect a rotation-worthy usage cliff on an isolated agent. The `--agents`
# flag mirrors the `bridge-auth.sh claude-token sync` convention.

set -euo pipefail

# Issue #1437 r14 BLOCKING (credential safety): a same-UID caller can hook a
# child Bash via STARTUP-FILE env vars — BASH_ENV / ENV (the non-interactive
# startup file Bash sources) and BASH_XTRACEFD. Our EARLY candidate-version probe
# (`"$cand" -c '…'`) runs a NON-privileged child Bash BEFORE the credential is
# scrubbed, so Bash would source the caller's $BASH_ENV file with the credential
# still in the env — and that file runs inside the probe child and can read it.
# Neutralize ALL such hooks at the VERY TOP, before ANY child runs. These are
# never needed by bridge-usage.sh. (Belt-and-suspenders with `-p` on every probe.)
builtin unset BASH_ENV ENV BASH_XTRACEFD 2>/dev/null || builtin true

# Issue #1437 r13 BLOCKING (credential safety): a same-UID caller can export Bash
# FUNCTIONS named after commands we invoke. Bash resolves an exported function
# BEFORE an external command (and a function can even shadow non-special builtins
# like printf/read/cd AND, per codex, exec/source/builtin/return), running it IN
# OUR SHELL CONTEXT where it can read the non-exported token shell vars. The
# ROBUST fix is to strip ALL imported functions in one shot via BASH PRIVILEGED
# MODE (`bash -p` does NOT import functions from the environment NOR process
# BASH_ENV/ENV), rather than relying on per-name `unset -f` (whose `unset`/
# `builtin` could themselves be shadowed). We re-exec under `-p` (combined with
# the Bash-4+ requirement) once, guarded by `$-`, at the VERY TOP — before the
# token is captured.
#
# Best-effort interceptor removal for the re-exec line ITSELF (the `exec` keyword
# could be a shadowed function on the very first pass). `builtin`/`unset` are
# special builtins; if THOSE are shadowed the caller already controls our process
# environment entirely (same-UID-controls-invocation-env — the deferred boundary,
# same class as bridge-lib.sh's own re-exec). This removes the common cases.
builtin unset -f exec source command builtin unset printf read echo cd pwd \
         claude head python3 python env mktemp chmod rm dirname readlink cat \
         ls true false bash sh 2>/dev/null || builtin true

# Re-exec under `bash -p` (privileged: imports NO env functions) AND Bash 4+ when
# we are not already privileged. `$-` contains `p` once privileged. We must carry
# the ambient OAT across this exec; `exec` preserves the environment, so the
# privileged pass simply re-reads CLAUDE_CODE_OAUTH_TOKEN from the env (it has not
# been captured/scrubbed yet — that happens AFTER this re-exec, in the
# function-free privileged shell).
case "$-" in
  *p*) : ;;   # already privileged — functions were not imported; proceed.
  *)
    _bu_self0="${BASH_SOURCE[0]}"
    if [[ -f "$_bu_self0" ]]; then
      # Prefer a candidate that is BOTH executable AND Bash 4+, so a single -p
      # re-exec satisfies both the privileged-mode and Bash-4+ requirements (a
      # privileged Bash-3.2 would let bridge-lib.sh re-exec WITHOUT -p and
      # re-import functions). The candidate path is absolute (not a function
      # name); its version probe inherits the ambient OAT in env, which is the
      # same pre-existing exposure as bridge-lib.sh's own candidate probe.
      for _bu_cand0 in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
        # `-p` (privileged) on the version probe too (r14): a privileged child
        # Bash sources NO BASH_ENV/ENV startup file and imports NO functions, so
        # even this pre-scrub probe (which still has the credential in its env)
        # cannot run a caller hook. BASH_ENV/ENV are also already unset above.
        if [[ -x "$_bu_cand0" ]] && "$_bu_cand0" -p -c '((${BASH_VERSINFO[0]:-0}>=4))' 2>/dev/null; then
          exec "$_bu_cand0" -p "$_bu_self0" "$@"
        fi
      done
    fi
    # No Bash-4+ candidate found — fall through; the per-name `unset -f` above is
    # the residual defense. (In practice a Bash 4+ is required and present.)
    ;;
esac
unset _bu_self0 _bu_cand0 2>/dev/null || builtin true

# Belt-and-suspenders on the privileged pass too: re-scrub any function names
# (privileged mode already prevented import, so this is normally a no-op) and use
# `builtin`/`command`/absolute qualification for every command near the token.
builtin unset -f printf read echo cd pwd command type local export unset \
         claude head python3 python env mktemp chmod rm dirname readlink \
         cat ls true false bash sh 2>/dev/null || builtin true

# Issue #1437 (credential safety, DEFINITIVE design r12): the env-source OAT must
# never reach any child process — env var, on-disk path, OR inherited fd. Across
# rounds r3-r11 every transit that had to CROSS bridge-lib.sh's Bash-3.2→4+
# re-exec proved attackable (a same-UID parent controls the initial environment +
# the candidate-bash search runs command-subs; an inherited fd is readable by a
# PATH-planted `dirname`/`bash` command-sub child). The root fix: ELIMINATE the
# need to carry the token across any re-exec. We re-exec to Bash 4+ OURSELVES
# FIRST — using ONLY Bash builtins (no subprocess that could read the ambient
# token) — BEFORE touching the token. Then bridge-lib.sh never re-execs (we are
# already Bash 4+), so the token is captured exactly once, in a process that does
# NOT re-exec, and lives only in a NON-exported shell var. No fd, no transit file,
# no env transit, nothing to plant, nothing for a command-sub child to read.
#
# r12 design: SCRIPT_DIR + the bridge-private scrub first (builtins, no
# subprocess). Then, BEFORE running ANY external command (so no PATH-planted
# helper — bash, env, dirname — ever runs while the ambient OAT is in the
# environment), capture the ambient token into a NON-exported var and UNSET it
# from the env. After that the env is token-free for every subprocess (the
# self-re-exec candidate probe, bridge-lib.sh's dirname, the roster/python
# helpers). The captured value is carried across OUR self-re-exec to Bash 4+ via
# an inherited fd on an UNLINKED file (no env transit, no path), and that fd is
# CLOSED on the Bash-4+ pass BEFORE `source bridge-lib.sh` — so bridge-lib's
# dirname never inherits a readable token fd either.

# SCRIPT_DIR via Bash builtin (no dirname subprocess).
_bu_src="${BASH_SOURCE[0]}"
if [[ "$_bu_src" == */* ]]; then
  SCRIPT_DIR="${_bu_src%/*}"
else
  SCRIPT_DIR="."
fi
unset _bu_src

# Unset all bridge-private transit names unconditionally (value + export attr).
unset _bu_tok _bu_file BRIDGE_USAGE_CAPTURED_OAT env_oat \
      _BRIDGE_USAGE_OAT_FILE _BRIDGE_USAGE_OAT_OWNED 2>/dev/null || true

# r12 BLOCKING fix: bind the few external binaries that run while a token is
# reachable (rm/mktemp/chmod run with the token in a 0600 file or fd open) to
# HARDCODED ABSOLUTE paths, NOT PATH resolution — a caller-planted `rm`/`mktemp`/
# `chmod` earlier on PATH must never be the one that runs near the live token.
# Probe the standard absolute locations (builtin `[[ -x ]]`, no subprocess); if
# none exist, fall back to the bare name (best-effort; the token file is still
# 0600-owned, so a planted helper reading it gains nothing it could not already
# read as the same UID).
_bu_pick() { local n; for n in "$@"; do [[ -x "$n" ]] && { builtin printf '%s' "$n"; return 0; }; done; builtin printf '%s' "${1##*/}"; }
_BU_RM="$(_bu_pick /bin/rm /usr/bin/rm)"
_BU_MKTEMP="$(_bu_pick /usr/bin/mktemp /bin/mktemp /opt/homebrew/bin/mktemp)"
_BU_CHMOD="$(_bu_pick /bin/chmod /usr/bin/chmod)"

# A fixed (non-secret) magic prefix that proves an inherited fd 9 was written by
# US, not pre-opened by a caller to a file of their choosing. A caller cannot make
# us read a foreign fd 9 as the token unless they reproduce this prefix (and even
# then they would only be feeding their own token to the probe — never exfiltrating
# ours). Used only when we cross OUR self-re-exec.
_BU_FD_MAGIC="agb-oat-fd-v1:"

# Capture the ambient token into a NON-exported var and scrub the env NOW —
# before any external command runs. On a Bash-4+ direct entry this var simply
# carries the token to the probe (no re-exec, no fd). On a Bash-3.2 entry we
# additionally stash it on fd 9 below so it survives OUR self-re-exec.
BRIDGE_USAGE_CAPTURED_OAT=""
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  BRIDGE_USAGE_CAPTURED_OAT="$CLAUDE_CODE_OAUTH_TOKEN"
  unset CLAUDE_CODE_OAUTH_TOKEN
fi

# Self-re-exec to Bash 4+ (only when we are Bash 3.2). The env is ALREADY
# token-free at this point, so the candidate-version probe and `exec` cannot leak
# the OAT — no `env -u` / PATH-planted-`env` needed. We stash the captured token
# on fd 9 (unlinked 0600 file) so it survives the exec; the Bash-4+ pass reads it
# (magic-verified) and CLOSES fd 9 before sourcing bridge-lib.sh.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  _bu_self="${BASH_SOURCE[0]}"
  if [[ -f "$_bu_self" ]]; then
    if [[ -n "$BRIDGE_USAGE_CAPTURED_OAT" ]]; then
      if _bu_file="$("$_BU_MKTEMP" "${TMPDIR:-/tmp}/agb-usage-oat.XXXXXX" 2>/dev/null)"; then
        "$_BU_CHMOD" 600 "$_bu_file" 2>/dev/null || true
        builtin printf '%s%s' "$_BU_FD_MAGIC" "$BRIDGE_USAGE_CAPTURED_OAT" >"$_bu_file"
        exec 9<"$_bu_file" 2>/dev/null || true
        "$_BU_RM" -f -- "$_bu_file" 2>/dev/null || true
        unset _bu_file
      fi
      # Drop the in-shell copy; the value rides fd 9 across the exec.
      BRIDGE_USAGE_CAPTURED_OAT=""
    fi
    for _bu_cand in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
      # `[[ -x ]]` is a builtin; the candidate-version probe runs in a TOKEN-FREE
      # env (we unset it above), so it cannot leak the OAT. `-p` (r14) keeps even
      # this probe from sourcing a BASH_ENV/ENV startup file (also unset at top).
      # `exec` preserves fd 9 (the token transit for this Bash-3.2 fallback path).
      if [[ -x "$_bu_cand" ]] && "$_bu_cand" -p -c '((${BASH_VERSINFO[0]:-0}>=4))' 2>/dev/null; then
        exec "$_bu_cand" "$_bu_self" "$@"
      fi
    done
  fi
  echo "[bridge-usage] Agent Bridge requires Bash 4+ (current: ${BASH_VERSION:-unknown})." >&2
  exit 1
fi

# Bash 4+ now. If we were re-exec'd from Bash 3.2, the token rides fd 9 — read it
# (magic-verified), CLOSE fd 9 (so bridge-lib.sh's dirname / helpers never inherit
# it), and keep the value only in the non-exported BRIDGE_USAGE_CAPTURED_OAT.
if [[ -z "$BRIDGE_USAGE_CAPTURED_OAT" ]] && [ -r /dev/fd/9 ]; then
  _bu_fd_payload=""
  # `builtin read` bypasses any (re-)exported `read` function — defense in depth
  # on top of the top-of-script `unset -f read`.
  IFS= builtin read -r -d '' _bu_fd_payload <&9 || true
  exec 9<&- 2>/dev/null || true
  if [[ "$_bu_fd_payload" == "$_BU_FD_MAGIC"* ]]; then
    BRIDGE_USAGE_CAPTURED_OAT="${_bu_fd_payload#"$_BU_FD_MAGIC"}"
  fi
  unset _bu_fd_payload
fi
unset _BU_FD_MAGIC

# SCRIPT_DIR canonicalization with a subprocess is safe (no token in env). The
# cd/pwd/printf here are builtin-qualified so a re-exported function of those
# names cannot read BRIDGE_USAGE_CAPTURED_OAT (still live) from the subshell.
if [[ -d "$SCRIPT_DIR" ]]; then
  SCRIPT_DIR="$(builtin cd -P "$SCRIPT_DIR" 2>/dev/null && builtin pwd -P || builtin printf '%s' "$SCRIPT_DIR")"
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

bridge_load_roster
bridge_require_python

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-usage.sh <status|monitor|alerts|probe> [options...]

  status/monitor accept --agents <static|all|csv> to scope per-agent cache
  collection (default: static — same convention as bridge-auth.sh).

  probe runs the native Anthropic OAuth usage probe (#1437) to refresh the
  controller's .usage-cache.json on a headless host (no claude-hud statusLine).
  Honors a >=5min cache + cooldown; degrades gracefully on any failure.
EOF
}

command="${1:-}"
[[ -n "$command" ]] || {
  usage
  exit 1
}
shift || true

# Default cache path (controller / single-tenant). Per-agent collection below
# overrides this with the agent-specific path when --agents is in effect.
claude_usage_cache="${BRIDGE_CLAUDE_USAGE_CACHE:-$HOME/.claude/plugins/claude-hud/.usage-cache.json}"
codex_sessions_dir="${BRIDGE_CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
usage_state_file="${BRIDGE_USAGE_MONITOR_STATE_FILE:-$BRIDGE_STATE_DIR/usage/monitor-state.json}"
rotation_threshold="${BRIDGE_CLAUDE_TOKEN_ROTATION_PERCENT:-99}"
# Separate weekly preemptive warn threshold. Fires for the 7-day window before
# rotation_threshold to allow proactive rotation/escalation.
weekly_warn_threshold="${BRIDGE_CLAUDE_WEEKLY_WARN_PERCENT:-95}"
claude_token_registry="${BRIDGE_CLAUDE_TOKEN_REGISTRY:-$BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json}"

# Fail-safe a percent threshold (env- or registry-derived) before it reaches
# the Python monitor's argparse float. A non-numeric or out-of-(0,100] value
# (e.g. BRIDGE_CLAUDE_WEEKLY_WARN_PERCENT=foo) would make `usage monitor` exit
# rc!=0 before collecting any snapshot, which suppresses the 5h hard-threshold
# rotation candidate too — so an invalid value falls back to the safe default
# instead of disabling rotation entirely (#1725 review). Mirrors the registry
# 0<value<=100 validation below so env and registry inputs are equally guarded.
_bridge_usage_sanitize_percent() {
  local value="$1" fallback="$2"
  if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    && awk -v v="$value" 'BEGIN { exit !(v > 0 && v <= 100) }'; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

if [[ -f "$claude_token_registry" ]]; then
  registry_rotation_threshold="$(python3 - "$claude_token_registry" <<'PY' 2>/dev/null || true
import json
import sys
from pathlib import Path

def threshold(payload, key):
    try:
        value = float(payload.get(key) or 0)
    except Exception:
        return ""
    if 0 < value <= 100:
        return str(value)
    return ""

try:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    payload = {}
print(f"{threshold(payload, 'rotation_threshold')}|{threshold(payload, 'weekly_warn_threshold')}")
PY
)"
  registry_weekly_warn_threshold=""
  if [[ "$registry_rotation_threshold" == *"|"* ]]; then
    registry_weekly_warn_threshold="${registry_rotation_threshold#*|}"
    registry_rotation_threshold="${registry_rotation_threshold%%|*}"
  fi
  if [[ "$registry_rotation_threshold" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    rotation_threshold="$registry_rotation_threshold"
  fi
  if [[ "$registry_weekly_warn_threshold" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    weekly_warn_threshold="$registry_weekly_warn_threshold"
  fi
fi

# Final fail-safe at the single chokepoint before these reach the Python
# monitor: a malformed env value (the registry path is already validated above)
# must never reach argparse and take the whole `usage monitor` run down with it.
rotation_threshold="$(_bridge_usage_sanitize_percent "$rotation_threshold" 99)"
weekly_warn_threshold="$(_bridge_usage_sanitize_percent "$weekly_warn_threshold" 95)"

# bridge_usage_select_claude_agents <spec>
#   spec ∈ {static, all, claude, <csv>}; default `static`. Prints one Claude
#   agent id per line (filters out non-Claude engines). Mirrors
#   bridge_auth_selected_agents in bridge-auth.sh so a single operator-facing
#   `--agents` contract covers sync + monitor.
bridge_usage_select_claude_agents() {
  local spec="${1:-static}"
  local agent="" item=""
  local -a explicit=()

  case "$spec" in
    static|"")
      for agent in "${BRIDGE_AGENT_IDS[@]:-}"; do
        [[ -n "$agent" ]] || continue
        [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
        [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
        printf '%s\n' "$agent"
      done
      ;;
    all|claude)
      for agent in "${BRIDGE_AGENT_IDS[@]:-}"; do
        [[ -n "$agent" ]] || continue
        [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
        printf '%s\n' "$agent"
      done
      ;;
    *)
      IFS=',' read -r -a explicit <<<"$spec"
      for item in "${explicit[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] || continue
        bridge_agent_exists "$item" || {
          printf '[error] unknown agent: %s\n' "$item" >&2
          return 1
        }
        [[ "$(bridge_agent_engine "$item")" == "claude" ]] || {
          printf '[error] agent is not a Claude agent: %s\n' "$item" >&2
          return 1
        }
        printf '%s\n' "$item"
      done
      ;;
  esac
}

# bridge_usage_resolve_claude_cache_path <agent>
#   Stdout: absolute path the agent's claude-hud usage cache would live at.
#   Isolated agents (linux-user mode) → under $BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/<os_user>.
#   Non-isolated agents that launch Claude with a per-agent CLAUDE_CONFIG_DIR →
#     under <agent-home>/.claude (the SAME dir launch/resume write to).
#   Everything else (dynamic-vanilla / operator-global passthrough / unregistered)
#     → controller's $HOME (the existing single-tenant path).
bridge_usage_resolve_claude_cache_path() {
  local agent="$1"
  local os_user="" agent_home="" config_dir=""

  if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
    if [[ -n "$os_user" ]]; then
      agent_home="$(bridge_agent_linux_user_home "$os_user")"
      printf '%s/.claude/plugins/claude-hud/.usage-cache.json' "$agent_home"
      return 0
    fi
  fi

  # E5 (#17927 P2): non-isolated agents that launch Claude with a per-agent
  # CLAUDE_CONFIG_DIR (<agent-home>/.claude) write their statusLine usage cache
  # THERE, not under the controller $HOME. Resolve via the SAME launch resolver
  # so daemon-read == launch-write. The resolver returns empty for
  # dynamic-vanilla / operator-global-passthrough / unregistered / stale-#1316-
  # scaffold agents, where the controller $HOME IS the correct location.
  if command -v bridge_resolve_agent_claude_config_dir >/dev/null 2>&1; then
    config_dir="$(bridge_resolve_agent_claude_config_dir "$agent" 2>/dev/null || true)"
    if [[ -n "$config_dir" ]]; then
      printf '%s/plugins/claude-hud/.usage-cache.json' "$config_dir"
      return 0
    fi
  fi

  printf '%s/.claude/plugins/claude-hud/.usage-cache.json' "$HOME"
}

# bridge_usage_read_claude_cache_for_agent <agent> <path>
#   Stdout: cache file contents (JSON), empty when unreadable / absent.
#   Returns 0 always — missing cache is not an error, it just means that agent
#   contributes no Claude snapshot this tick (per brief U3).
#
# set-e safety: every helper invocation uses `cmd || rc=$?` capture, mirroring
# the pattern in lib/bridge-agents.sh:bridge_channel_env_file_readiness that
# avoided the PR #836 set-e abort.
bridge_usage_read_claude_cache_for_agent() {
  local agent="$1"
  local path="$2"
  local sudo_rc=0 probe_rc=0
  local probe_script=''

  if [[ -z "$agent" || -z "$path" ]]; then
    return 0
  fi

  # Controller-direct path: non-isolated agent, or we can read the file from
  # the controller's UID. The latter handles the common case where the agent's
  # home is on a shared filesystem with permissive perms (most CI setups).
  if [[ -r "$path" ]]; then
    cat "$path" 2>/dev/null || true
    return 0
  fi

  if ! declare -F bridge_isolation_can_sudo_to_agent >/dev/null 2>&1; then
    return 0
  fi

  sudo_rc=0
  bridge_isolation_can_sudo_to_agent "$agent" 2>/dev/null || sudo_rc=$?
  case "$sudo_rc" in
    0)
      # Isolated and sudo works — read via the isolated UID. Self-contained
      # inline script; does NOT source bridge-lib.sh under the isolated UID
      # (sudoers allowlist is `bash` + `tmux` only).
      probe_script='
file="$1"
[[ -r "$file" ]] || exit 2
cat "$file"
'
      probe_rc=0
      bridge_isolation_run_as_agent_user_via_bash "$agent" "$probe_script" "$path" 2>/dev/null || probe_rc=$?
      if [[ "$probe_rc" -eq 0 ]]; then
        return 0
      fi
      # rc=3 (script exited 1) or rc=4 (script exited 2 — file unreadable to
      # isolated UID) → contribute empty payload for this agent (skip cleanly).
      return 0
      ;;
    2)
      # Isolated agent but no passwordless sudo — degrade silently per brief
      # U4 ("that agent is skipped with a warn-log line; other agents
      # continue"). The warn line lands on the daemon's stderr; the daemon
      # already routes 2>/dev/null on the wrapper invocation, but during ad-hoc
      # `bridge-usage.sh status --agents all` the operator sees it.
      printf '[bridge-usage] skip agent=%s reason=no-passwordless-sudo\n' "$agent" >&2
      return 0
      ;;
    *)
      # rc=1 — not isolated at all. Fall back to controller-direct read.
      cat "$path" 2>/dev/null || true
      return 0
      ;;
  esac
}

# bridge_usage_build_per_agent_payload <agents-newline-stream>
#   Reads agent ids from stdin (one per line), resolves each agent's cache
#   path, reads it (with isolation-aware sudo when needed), and emits a single
#   JSON array of {agent, path, present, payload} entries. Returns the
#   tempfile path on stdout. The tempfile is mode 0600.
bridge_usage_build_per_agent_payload() {
  # Issue #831 r2 (review #2104 finding 2): per-agent cache contents must NOT
  # transit through the python3 argv. Argv is process-table-visible, has
  # ARG_MAX limits that the prior triplet encoding could hit on a large agent
  # roster, and crosses the isolation boundary that the 0600 tempfile was
  # supposed to enforce. Instead, write rows to a separate 0600 intermediate
  # file (`rows_tmp`) using a TAB-delimited <agent><TAB><path><TAB><b64-content>
  # framing, then pass ONLY the two file paths via argv. Python streams the
  # rows file and emits the final JSON array into the output tempfile.
  local tmp="" rows_tmp="" agent="" path="" content=""
  tmp="$(mktemp)"
  rows_tmp="$(mktemp)"
  chmod 600 "$tmp" "$rows_tmp"

  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    path="$(bridge_usage_resolve_claude_cache_path "$agent")"
    content="$(bridge_usage_read_claude_cache_for_agent "$agent" "$path")"
    # Line per agent: <agent><TAB><path><TAB><base64-content>. base64 keeps
    # the encoded value newline-free (tr -d '\n'), so a literal newline
    # terminates the row safely.
    printf '%s\t%s\t%s\n' "$agent" "$path" "$(printf '%s' "$content" | base64 | tr -d '\n')" >>"$rows_tmp"
  done

  python3 - "$tmp" "$rows_tmp" <<'PY'
import base64
import json
import sys
from pathlib import Path

out_path = Path(sys.argv[1])
rows_path = Path(sys.argv[2])
entries = []

with rows_path.open("r", encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 2)
        agent = parts[0] if len(parts) > 0 else ""
        path = parts[1] if len(parts) > 1 else ""
        b64 = parts[2] if len(parts) > 2 else ""
        raw = ""
        if b64:
            try:
                raw = base64.b64decode(b64).decode("utf-8", errors="replace")
            except Exception:
                raw = ""
        parsed = None
        present = False
        if raw.strip():
            try:
                parsed = json.loads(raw)
                present = True
            except Exception:
                parsed = None
                present = False
        entries.append({
            "agent": agent,
            "path": path,
            "present": present,
            "payload": parsed,
        })

out_path.write_text(json.dumps(entries, ensure_ascii=True), encoding="utf-8")
PY

  # Clean up the intermediate rows file regardless of python3 exit; the final
  # payload file (`tmp`) is the caller's responsibility (returned via stdout).
  rm -f "$rows_tmp" 2>/dev/null || true

  printf '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# Operator-facing arg parsing: we intercept `--agents <spec>` here (so we can
# collect per-agent caches before exec'ing python3) and pass the rest through
# unchanged. Anything else stays a python-side flag, including the existing
# threshold + state-file flags.
# ---------------------------------------------------------------------------
agents_spec=""
agents_explicit=0
# #17927 P2 (E6/E8): the daemon passes `--rotation-agents <spec>` to scope which
# agents' usage may DRIVE a token rotation (managed pool), distinct from
# `--agents` which scopes read-only monitoring/alerting. We resolve the spec to a
# CSV of eligible agent ids and forward it to the python monitor as
# `--rotation-eligible-agents` so eligibility is gated BEFORE the candidate is
# emitted/latched — a post-hoc daemon skip cannot un-latch.
rotation_agents_spec=""
rotation_agents_explicit=0
forward_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agents)
      agents_spec="${2:-}"
      agents_explicit=1
      shift 2
      ;;
    --agents=*)
      agents_spec="${1#--agents=}"
      agents_explicit=1
      shift
      ;;
    --rotation-agents)
      rotation_agents_spec="${2:-}"
      rotation_agents_explicit=1
      shift 2
      ;;
    --rotation-agents=*)
      rotation_agents_spec="${1#--rotation-agents=}"
      rotation_agents_explicit=1
      shift
      ;;
    *)
      forward_args+=("$1")
      shift
      ;;
  esac
done

per_agent_cache_json=""
legacy_single_path=""
# #17927 P2 (E6/E8): CSV of agents whose usage may DRIVE a rotation. Empty until
# the monitor branch resolves `--rotation-agents`. A non-empty value (even when
# it resolves to zero agents → `__ROTATION_NONE__` sentinel) ENABLES the python
# eligibility gate; the flag staying unset preserves legacy ungated behavior.
rotation_eligible_csv=""
rotation_eligible_set=0
# Cleanup any per-agent tempfile we create.
trap '[[ -n "${per_agent_cache_json:-}" ]] && rm -f -- "$per_agent_cache_json"' EXIT

run_python() {
  local subcmd="$1"
  shift
  local -a base_args=(
    "$subcmd"
    --claude-usage-cache "$claude_usage_cache"
    --codex-sessions-dir "$codex_sessions_dir"
  )
  if [[ "$subcmd" == "monitor" ]]; then
    base_args+=(--state-file "$usage_state_file" --rotation-threshold "$rotation_threshold" --weekly-warn-threshold "$weekly_warn_threshold")
  fi
  if [[ -n "$per_agent_cache_json" ]]; then
    base_args+=(--per-agent-cache-json "$per_agent_cache_json")
  fi
  if [[ -n "$legacy_single_path" ]]; then
    base_args+=(--legacy-single-path "$legacy_single_path")
  fi
  # #17927 P2 (E6/E8): pass the resolved rotation-eligible CSV (possibly empty —
  # an empty value still ENABLES the gate so only controller-managed sentinels
  # rotate). Absent flag ⇒ python leaves rotation ungated (legacy behavior).
  if [[ "$subcmd" == "monitor" && "$rotation_eligible_set" == "1" ]]; then
    base_args+=(--rotation-eligible-agents "$rotation_eligible_csv")
  fi
  # Issue #1437 PRIMARY: pass the native-probe controller cache so the monitor
  # reads it ADDITIVELY in per-agent mode (the default daemon path builds a
  # per-agent payload, which otherwise suppresses the controller cache per the
  # #831 isolation guard). Only meaningful when the probe is enabled; harmless
  # otherwise (an absent cache contributes no snapshot). bridge-usage.py dedupes
  # this against any per-agent path that already resolved to the same file.
  if [[ "${BRIDGE_USAGE_PROBE_ENABLED:-1}" == "1" ]]; then
    base_args+=(--native-usage-cache "$claude_usage_cache")
  fi
  # Stale-attribution guard (rotation ping-pong): tell the monitor which
  # token is CURRENTLY active (token-FREE one-way digest — never the token
  # itself) so a synthetic 429-signal cache written for a PREVIOUSLY-active
  # token is treated as stale instead of instantly re-rotating the freshly
  # activated token. Registry installs only — without a rotation registry
  # there is no rotation lane to protect, and the helper prints nothing.
  if [[ "${BRIDGE_USAGE_PROBE_ENABLED:-1}" == "1" && -f "$claude_token_registry" ]]; then
    local _active_digest=""
    _active_digest="$(command python3 "$SCRIPT_DIR/bridge-usage-probe.py" active-token-digest \
      --registry-path "$claude_token_registry" 2>/dev/null || builtin true)"
    if [[ -n "$_active_digest" ]]; then
      base_args+=(--active-token-digest "$_active_digest")
    fi
  fi
  base_args+=("$@")
  python3 "$SCRIPT_DIR/bridge-usage.py" "${base_args[@]}"
}

# bridge_usage_native_probe
#   Issue #1437 PRIMARY: run the native Anthropic OAuth usage probe so a
#   headless host (no claude-hud statusLine → no stdin tap → no
#   .usage-cache.json) can still produce the Claude `used_percent` the
#   token-rotation monitor reads, enabling PROACTIVE rotation before the
#   account hard-limits. Writes the SAME .usage-cache.json shape the monitor
#   already consumes (this is a new SOURCE, not a new consumer).
#
#   Feature flag: BRIDGE_USAGE_PROBE_ENABLED (default 1). The probe self-gates
#   on a >=5min cache + cooldown and degrades on any failure, so calling it on
#   every monitor tick is safe (it rarely makes a network call).
#
#   User-Agent: claude-code/<ver> is MANDATORY (the endpoint 429s without it).
#   We detect <ver> via `claude --version` once and fall back to the helper's
#   built-in default when the CLI is absent (headless hosts often lack it).
#
#   CREDENTIAL SAFETY (#1437 r2+r3 BLOCKING): the active OAT must NOT leak via
#   ambient environment inheritance into ANY subprocess this script spawns —
#   early (the roster/session Python helpers run when bridge-lib.sh is sourced)
#   OR late (the version sniff + probe children). Two measures:
#     1. The env-source OAT is captured + UNSET from the environment at the TOP
#        of bridge-usage.sh, BEFORE `source bridge-lib.sh` / bridge_load_roster /
#        bridge_require_python run (r3 fix: an in-function unset was too late and
#        leaked into those early helper children). So no child of this script —
#        early or late — inherits the token; `claude --version` + its `head`
#        child + mktemp/chmod are all covered.
#     2. The probe prefers the registry / .credentials.json token sources (read
#        directly, no env). If the operator only has the env source, we deliver
#        the captured value DELIBERATELY: write it to a short-lived 0600 temp
#        file, pass `--token-file` + `--no-env-token`. The temp file is unlinked
#        immediately after the probe returns (trap-guarded). The token is read
#        once from that private file and used only in the Authorization header.
bridge_usage_native_probe() {
  [[ "${BRIDGE_USAGE_PROBE_ENABLED:-1}" == "1" ]] || return 0

  local cache_path="$claude_usage_cache"
  local registry_path="$claude_token_registry"
  local claude_bin="${BRIDGE_CLAUDE_TOKEN_CHECK_BIN:-claude}"
  local ua_version="" version_line=""
  local token_file=""
  # The env-source OAT was already captured + unset from the environment at the
  # TOP of this script (before bridge-lib.sh / bridge_load_roster spawned any
  # Python helper children), so NO subprocess — early roster/session helpers OR
  # the later probe children — ever inherits it. We read the captured value here
  # for deliberate token-file delivery only.
  #
  # r8 BLOCKING: a caller who pre-EXPORTED `env_oat` would, under Bash 3.2, make
  # this function-local carry the export attribute (Bash 3.2 keeps an inherited
  # export attribute on `local`), so the probe child would inherit
  # env_oat=<captured token>. `export -n env_oat` (portable on Bash 3.2 + 4+)
  # strips the export attribute so the captured value stays a non-exported local.
  local env_oat=""
  builtin export -n env_oat 2>/dev/null || builtin true
  env_oat="${BRIDGE_USAGE_CAPTURED_OAT:-}"
  local -a probe_args=()

  # Best-effort version sniff for the mandatory User-Agent. Never fatal. The OAT
  # is absent from the environment (scrubbed at script top), but env_oat /
  # BRIDGE_USAGE_CAPTURED_OAT hold it as non-exported shell vars HERE — so these
  # commands are FUNCTION-bypassed (r13 BLOCKING): `command -v` / `command
  # "$claude_bin"` / `command head` bypass any caller-(re-)exported function of
  # those names (which would run in our shell and read those vars). The
  # top-of-script `unset -f` already removed them; `command` is belt-and-suspenders.
  if command -v "$claude_bin" >/dev/null 2>&1; then
    version_line="$(command "$claude_bin" --version 2>/dev/null | command head -n 1 || builtin true)"
    # `claude --version` prints e.g. "2.1.0 (Claude Code)"; take the first token.
    ua_version="${version_line%% *}"
  fi

  probe_args=(probe --cache-path "$cache_path" --registry-path "$registry_path")
  [[ -n "$ua_version" ]] && probe_args+=(--user-agent-version "$ua_version")
  # Issue #1468 §5 (observability): ask the probe for its token-free `--json`
  # result so we can emit a `usage_probe` audit row on a 429 near-limit signal
  # or a probe failure (the path was previously a silent best-effort `exit 0`,
  # so a defeated proactive probe was invisible without replaying the HTTP call).
  # We CAPTURE the probe's stdout into a variable below — it must NOT leak onto
  # this function's stdout, which (in the embedded monitor pre-refresh path) is
  # part of the captured monitor JSON.
  probe_args+=(--json)

  # Deliberate env-token delivery (r12 BLOCKING fix): if the env source WAS set,
  # hand it to the probe via an INHERITED fd on an UNLINKED 0600 file — NOT a
  # `--token-file <path>` (the path is visible in argv / the process table, and
  # the linked temp file is briefly findable+readable). We write the token to a
  # 0600 file, open it read-only on fd 8, UNLINK the path immediately (nothing
  # left on disk), and pass `--token-fd 8` + `--no-env-token`. The python probe
  # reads fd 8; fd 8 is closed when the probe subprocess exits. mktemp/chmod run
  # with the OAT already scrubbed from the environment (unset at script top).
  local _pf_have_fd=0
  if [[ -n "$env_oat" ]]; then
    # Use the hardcoded-absolute mktemp/chmod/rm bound at script top so a
    # PATH-planted helper cannot be the one that runs while fd 8 / the 0600 file
    # is live (r12 BLOCKING). The file is 0600-owned, opened on fd 8, and unlinked
    # immediately — no path in argv (we pass `--token-fd 8`, just the integer).
    if token_file="$("${_BU_MKTEMP:-mktemp}" "${TMPDIR:-/tmp}/agb-usage-oat.XXXXXX" 2>/dev/null)"; then
      "${_BU_CHMOD:-chmod}" 600 "$token_file" 2>/dev/null || builtin true
      builtin printf '%s' "$env_oat" >"$token_file"
      if exec 8<"$token_file" 2>/dev/null; then
        _pf_have_fd=1
        probe_args+=(--token-fd 8 --no-env-token)
      fi
      # Unlink immediately whether or not the fd opened — no path left on disk.
      "${_BU_RM:-rm}" -f -- "$token_file" 2>/dev/null || builtin true
      token_file=""
    fi
  fi
  # Scrub the captured value from the function-local now that it is on fd 8 (or
  # delivery degraded); the token no longer lives in any shell var for the probe
  # call.
  env_oat=""

  # The helper always exits 0 (best-effort, graceful degrade); we mirror that so
  # a probe issue never aborts the surrounding status/monitor command. The OAT is
  # absent from the inherited environment and from every shell var (env_oat
  # cleared above); when fd 8 carries it that is the deliberate source, otherwise
  # the probe uses the registry / .credentials.json sources it reads directly.
  # `command python3` bypasses any caller-(re-)exported `python3` function (which
  # would run in our shell with fd 8 inherited) — r13 BLOCKING, belt on top of
  # the top-of-script `unset -f python3`.
  #
  # Issue #1468: CAPTURE the probe's token-free `--json` result. The probe's
  # stderr (its `_log` lines) stays on stderr; only the single JSON line lands
  # on stdout, which we grab here so it never pollutes the monitor JSON the
  # daemon captures from this function's stdout.
  local _probe_result=""
  _probe_result="$(command python3 "$SCRIPT_DIR/bridge-usage-probe.py" "${probe_args[@]}" "$@" 2>/dev/null || builtin true)"

  # Close fd 8 so no later sibling inherits it.
  if [[ "$_pf_have_fd" -eq 1 ]]; then
    exec 8<&- 2>/dev/null || true
  fi

  # Issue #1468 §5: emit a `usage_probe` audit row on a noteworthy outcome (429
  # near-limit signal / suppressed-idempotent / probe failure). The parser emits
  # a row ONLY for those statuses (empty on fresh/written/cooldown), so the
  # common no-op tick stays audit-silent. Best-effort: a parse/audit failure
  # must never abort the surrounding status/monitor command.
  bridge_usage_probe_audit "$_probe_result" || builtin true
}

# bridge_usage_probe_audit <probe-json>
#   Issue #1468 §5 (observability): translate the native probe's token-free
#   `--json` result into a `usage_probe` audit row when the outcome is
#   noteworthy. Silent on the healthy fresh/written/cooldown ticks. The probe
#   result is token-free by construction (the probe never echoes the OAT).
bridge_usage_probe_audit() {
  local probe_json="${1:-}"
  [[ -n "$probe_json" ]] || return 0
  local admin_agent="${BRIDGE_ADMIN_AGENT_ID:-}"
  [[ -n "$admin_agent" ]] || return 0
  command -v bridge_audit_log >/dev/null 2>&1 || return 0
  local row=""
  row="$(command python3 "$SCRIPT_DIR/bridge-daemon-helpers.py" usage-probe-result-parse "$probe_json" 2>/dev/null || builtin true)"
  [[ -n "$row" ]] || return 0
  local p_status p_reset p_retry p_http p_detail
  # #1468: split the tab-separated probe row WITHOUT a here-string (footgun #11
  # / lint-heredoc-ban H3). The row is token-free (status/reset/retry/http/
  # detail) and we read it back from a temp file so `read`'s field semantics
  # are preserved exactly (verified byte-identical to the prior here-string
  # parse).
  local _row_tmp=""
  _row_tmp="$(command mktemp "${TMPDIR:-/tmp}/agb-usage-probe-row.XXXXXX" 2>/dev/null)" || return 0
  printf '%s\n' "$row" >"$_row_tmp" 2>/dev/null || { command rm -f "$_row_tmp"; return 0; }
  IFS=$'\t' read -r p_status p_reset p_retry p_http p_detail <"$_row_tmp"
  command rm -f "$_row_tmp"
  [[ -n "$p_status" ]] || return 0
  # Decode the `-` sentinel back to empty: the python helper writes `-` for
  # empty columns so bash `read -r` cannot collapse adjacent IFS=$'\t'
  # separators (tab is IFS whitespace; an empty middle field used to shift
  # http_status into the reset_at slot). Same producer/consumer contract as
  # the mcp-miss-queue drain rows.
  [[ "$p_reset" == "-" ]] && p_reset=""
  [[ "$p_retry" == "-" ]] && p_retry=""
  [[ "$p_http" == "-" ]] && p_http=""
  [[ "$p_detail" == "-" ]] && p_detail=""
  bridge_audit_log daemon usage_probe "$admin_agent" \
    --detail status="$p_status" \
    --detail reset_at="$p_reset" \
    --detail retry_after="$p_retry" \
    --detail http_status="$p_http" \
    --detail detail="$p_detail" \
    --detail source="native-oauth-probe" >/dev/null 2>&1 || builtin true
}

case "$command" in
  probe)
    bridge_usage_native_probe "${forward_args[@]+"${forward_args[@]}"}"
    exit 0
    ;;
  status|monitor)
    # Issue #1437: on a headless host the native probe is the only thing that
    # produces a Claude usage cache. Refresh it (self-gated on cache age +
    # cooldown) BEFORE the monitor reads the cache so a fresh tick has signal.
    # Skipped entirely when --agents collects per-agent caches from live
    # claude-hud taps, and degrades to a no-op when the flag is off.
    bridge_usage_native_probe
    if [[ "$agents_explicit" -eq 1 ]]; then
      agent_stream=""
      agent_stream="$(bridge_usage_select_claude_agents "$agents_spec")" || exit 1
      if [[ -n "$agent_stream" ]]; then
        per_agent_cache_json="$(printf '%s\n' "$agent_stream" | bridge_usage_build_per_agent_payload)"
        # Back-compat: preserve the single-controller-cache path so any
        # downstream tooling that ignores the per-agent array still sees the
        # legacy field unchanged.
        legacy_single_path="$claude_usage_cache"
      fi
    fi
    # #17927 P2 (E6/E8): resolve the rotation-eligible scope (managed-token pool)
    # to a CSV the python monitor uses to gate rotation candidates. Resolved with
    # the SAME selector as `--agents` so the set matches the bridge-auth sync
    # fanout. monitor-only — `status` never rotates.
    if [[ "$command" == "monitor" && "$rotation_agents_explicit" -eq 1 ]]; then
      rotation_stream=""
      # #17927 P2 (codex r2 — Bug 1): an EXPLICIT-EMPTY rotation scope
      # (BRIDGE_USAGE_ROTATION_AGENTS="") means "only controller-managed
      # sentinels are rotation-eligible", NOT the static pool. The selector maps
      # an empty spec to its static --agents default, so special-case empty to an
      # empty eligible CSV here (the monitor then rotates only __native__/legacy
      # sentinels, never a named statusLine agent).
      if [[ -z "$rotation_agents_spec" ]]; then
        rotation_eligible_csv=""
      else
        rotation_stream="$(bridge_usage_select_claude_agents "$rotation_agents_spec")" || exit 1
        rotation_eligible_csv="$(printf '%s' "$rotation_stream" | tr '\n' ',' | sed 's/,*$//')"
      fi
      rotation_eligible_set=1
    fi
    run_python "$command" "${forward_args[@]+"${forward_args[@]}"}"
    rc=$?
    exit "$rc"
    ;;
  alerts)
    exec python3 "$SCRIPT_DIR/bridge-usage.py" alerts \
      --audit-file "$BRIDGE_AUDIT_LOG" \
      "${forward_args[@]+"${forward_args[@]}"}"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
