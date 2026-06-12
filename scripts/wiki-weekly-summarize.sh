#!/usr/bin/env bash
# wiki-weekly-summarize — iterate active claude agents, run
# `bridge-memory summarize weekly` for each. Sequential; Mac mini 8GB.
#
# Cron: Sunday 22:00 KST ("cron 0 22 * * 0 Asia/Seoul").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_common.sh"

# Issue #1849 (sibling of #1827 / #1222): `bridge-memory.py summarize weekly`
# reads and writes under `$home/memory/`. Under linux-user isolation that dir
# is owned by the iso UID with group `ab-agent-<slug>` mode 2770; the
# controller is intentionally NOT in that group (per the v2 contract), so the
# controller-direct invocation below fails with `Permission denied` and each
# iso agent lands in the `fail` tally — a recurring, noisy per-agent failure
# on every run, even though the only impact is a stale summary.
#
# Fix (unify with #1827's resolution): drop to the iso UID via
# `bridge_isolation_run_as_agent_user_via_bash` so the summarize runs inside
# the boundary. Do NOT relax the 2770 iso perms. Non-isolated (shared/legacy)
# agents keep the controller-direct path unchanged.
#
# Sourcing bridge-lib.sh pulls in
# `bridge_agent_linux_user_isolation_effective` / `bridge_agent_os_user`
# (bridge-agents.sh) and `bridge_isolation_run_as_agent_user_via_bash`
# (bridge-isolation-helpers.sh). The source is guarded so a stripped install
# (or smoke harness with a minimal $BRIDGE_HOME) still runs the non-iso path.
# `_BRIDGE_ISO_HELPERS_LOADED` records whether the iso path is available.
#
# IMPORTANT (#1222 codex r1 finding, carried via #1827): merely sourcing
# bridge-lib.sh does NOT populate the per-agent assoc arrays the predicate
# reads — those are filled by `bridge_load_roster`. Without that call every
# iso agent's predicate returns false in this shell and summarize falls back
# to the controller-direct path that hits `Permission denied`. So: source,
# verify the helpers AND the roster loader exist, then load.
_BRIDGE_ISO_HELPERS_LOADED=0
if [[ -r "$HERE/../bridge-lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HERE/../bridge-lib.sh" || true
  if declare -F bridge_isolation_run_as_agent_user_via_bash >/dev/null 2>&1 \
      && declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && declare -F bridge_load_roster >/dev/null 2>&1 \
      && bridge_load_roster >/dev/null 2>&1; then
    _BRIDGE_ISO_HELPERS_LOADED=1
  fi
fi

JOB="wiki-weekly-summarize"
LOG="$(audit_path "$JOB")"
log_audit "$JOB" "starting $JOB" >/dev/null

trap 'file_failure_task "$JOB" "$LOG"' ERR

ok=0
fail=0
skipped=0
while IFS=$'\t' read -r agent home; do
  [[ -z "$agent" || -z "$home" ]] && continue
  log_audit "$JOB" "== agent=$agent home=$home ==" >/dev/null

  # Issue #1849: under linux-user isolation the summarize below reads/writes
  # the iso-owned `memory/` dir (mode 2770 `agent-bridge-<slug>:ab-agent-<slug>`),
  # which the controller cannot touch. Run the summarize as the iso UID via the
  # sanctioned run-as helper (matches #1827 / #1222). On a non-isolated
  # (shared/legacy) agent this gate is false and the controller-direct path
  # below runs unchanged.
  _iso_isolated=0
  if (( _BRIDGE_ISO_HELPERS_LOADED == 1 )) \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    _iso_isolated=1
  fi

  if (( _iso_isolated == 1 )); then
    # Self-contained inline summarize run as the iso UID via the sudoers
    # `bash` allowlist. Does NOT source bridge-lib.sh inside the isolated UID
    # (the allowlist is `bash` + `tmux` only). The body is a single-quoted
    # string so $vars resolve only inside the sudo'd bash.
    #
    # Args bound inside the script:
    #   $1 = BRIDGE_PYTHON, $2 = BRIDGE_HOME, $3 = agent, $4 = home
    #
    # Script exit codes (all 0 or >= 10 so the wrapper's +2 shift on script
    # rc<3 never collides with the wrapper's own 0/1/2 pre-flight band — see
    # bridge_isolation_run_as_agent_user_via_bash):
    #   0  — summarize succeeded
    #   10 — no memory/ dir inside the iso tree (nothing to summarize)
    #   13 — summarize invocation failed
    #
    # Footgun #11 (heredoc-stdin deadlock): NO `<<EOF` / `<<<` / `<<'PY'` in
    # this body — only a direct bridge-memory.py invocation.
    _iso_summarize_script='
bridge_python="$1"
bridge_home="$2"
agent="$3"
home="$4"

if [[ ! -d "$home/memory" ]]; then
  exit 10
fi

summ_rc=0
if command -v timeout >/dev/null 2>&1; then
  timeout 600 "$bridge_python" "$bridge_home/bridge-memory.py" summarize weekly \
    --agent "$agent" --home "$home" --json >/dev/null 2>&1 || summ_rc=$?
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout 600 "$bridge_python" "$bridge_home/bridge-memory.py" summarize weekly \
    --agent "$agent" --home "$home" --json >/dev/null 2>&1 || summ_rc=$?
else
  "$bridge_python" "$bridge_home/bridge-memory.py" summarize weekly \
    --agent "$agent" --home "$home" --json >/dev/null 2>&1 || summ_rc=$?
fi
if [[ "$summ_rc" -ne 0 ]]; then
  exit 13
fi
exit 0
'
    _iso_rc=0
    bridge_isolation_run_as_agent_user_via_bash "$agent" "$_iso_summarize_script" \
      "$BRIDGE_PYTHON" "$BRIDGE_HOME" "$agent" "$home" 2>/dev/null || _iso_rc=$?
    case "$_iso_rc" in
      0)
        log_audit "$JOB" "ok: $agent (iso-uid)" >/dev/null
        ok=$((ok + 1))
        ;;
      10)
        log_audit "$JOB" "skip: no memory dir (iso-uid) agent=$agent" >/dev/null
        skipped=$((skipped + 1))
        ;;
      2)
        # Sudo unavailable / passwordless sudoers missing. The iso v2 contract
        # requires it — count as skipped (not a summarize failure) with an
        # info line, not per-agent ERROR spam.
        log_audit "$JOB" "ISO_SUDO_UNAVAILABLE skip agent=$agent" >/dev/null
        skipped=$((skipped + 1))
        ;;
      1)
        # rc=1 means the helper's own isolation re-check disagreed with our
        # gate (roster/state drift). Skip with an info line.
        log_audit "$JOB" "ISO_GATE_INCONSISTENT skip agent=$agent" >/dev/null
        skipped=$((skipped + 1))
        ;;
      *)
        log_audit "$JOB" "FAIL($_iso_rc): $agent (iso-uid)" >/dev/null
        fail=$((fail + 1))
        ;;
    esac
    continue
  fi

  if [[ ! -d "$home/memory" ]]; then
    log_audit "$JOB" "skip: no memory dir" >/dev/null
    skipped=$((skipped + 1))
    continue
  fi
  if run_with_timeout 600 "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" summarize weekly \
        --agent "$agent" --home "$home" --json \
        >>"$LOG" 2>&1; then
    log_audit "$JOB" "ok: $agent" >/dev/null
    ok=$((ok + 1))
  else
    rc=$?
    log_audit "$JOB" "FAIL($rc): $agent" >/dev/null
    fail=$((fail + 1))
  fi
done < <(list_active_claude_agents)

log_audit "$JOB" "done ok=$ok fail=$fail skipped=$skipped" >/dev/null

# Non-zero exit only when at least one hard failure *and* no successes.
# Per-agent failures alone don't fail the whole cron — they surface via the
# failure task.
if (( fail > 0 && ok == 0 )); then
  file_failure_task "$JOB" "$LOG"
  exit 1
fi
exit 0
