#!/usr/bin/env bash
# memory-daily harvester stub — thin CLI adapter between cron runner and
# bridge-memory.py. Keep this script policy-free; Python owns all decisions.
# Under linux-user isolation the controller UID cannot read the iso agent's
# iso-owned ~/.claude/projects tree (issue #1894), so the stub runs ONLY the
# bounded transcript scan as the target OS user (passwordless sudo via the
# sudoers `bash` allowlist) and feeds the result back to the controller-UID
# harvest via --transcripts-json — the harvest itself, and every queue-DB /
# aggregate write, stays in the controller context (Design A, #786). If
# passwordless sudo is unavailable the stub falls back to --skipped-permission.
set -euo pipefail

AGENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$AGENT" ]] || { echo "error: --agent required" >&2; exit 2; }

: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
BRIDGE_AGB="${BRIDGE_AGB:-$BRIDGE_HOME/agb}"
BRIDGE_PYTHON="${BRIDGE_PYTHON:-python3}"

# Issue #1894: source the iso helpers so the linux-user branch below can run
# the transcript scan AS the iso UID via `bridge_isolation_run_as_agent_user_via_bash`.
# Mirrors the wiki-monthly-summarize.sh guard (#1849/#1827/#1222): merely
# sourcing bridge-lib.sh does NOT populate the per-agent roster arrays the
# isolation predicate reads — `bridge_load_roster` does. Source, verify the
# helpers AND the roster loader exist, then load. On a stripped install (or a
# smoke harness with a minimal $BRIDGE_HOME) the iso path stays unavailable and
# the existing controller-read / --skipped-permission fallback handles it.
_BRIDGE_ISO_HELPERS_LOADED=0
if [[ -r "$BRIDGE_HOME/bridge-lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$BRIDGE_HOME/bridge-lib.sh" || true
  if declare -F bridge_isolation_run_as_agent_user_via_bash >/dev/null 2>&1 \
      && declare -F bridge_isolation_can_sudo_to_agent >/dev/null 2>&1 \
      && declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && declare -F bridge_load_roster >/dev/null 2>&1 \
      && bridge_load_roster >/dev/null 2>&1; then
    _BRIDGE_ISO_HELPERS_LOADED=1
  fi
fi

json="$("$BRIDGE_AGB" agent show "$AGENT" --json 2>/dev/null)" \
  || { echo "error: agent show failed for $AGENT" >&2; exit 2; }
[[ -n "$json" ]] || { echo "error: empty agent show output for $AGENT" >&2; exit 2; }

# Issue #376 Track C: defense-in-depth source-class refusal. Track A filters
# memory-daily-<agent> registration to static-only agents, but an operator
# might create a cron manually or a future helper might forget to filter.
# Exit 0 (success / no-op) — NOT exit 2 — so the cron's run-state stays
# "success" and the daemon does not generate a [cron-followup] task.
agent_source="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("source") or "")')"
if [[ "$agent_source" == "dynamic" ]]; then
  printf '[memory-daily-harvest] dynamic agent %s has no per-agent daily-note pipeline; nothing to harvest. exiting cleanly.\n' "$AGENT" >&2
  exit 0
fi

# Parse JSON twice to stay whitespace-safe (paths may contain spaces).
workdir="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("workdir", ""))')"
home="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("profile", {}).get("home", ""))')"
isolation_mode="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("isolation", {}).get("mode", ""))')"
os_user="$(printf '%s' "$json" | "$BRIDGE_PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("isolation", {}).get("os_user", ""))')"

[[ -n "$workdir" && -n "$home" ]] \
  || { echo "error: missing workdir/home for $AGENT" >&2; exit 2; }

# Sidecar path: runner-exported CRON_REQUEST_DIR (cron path). Fallback is an
# agent-scoped state dir for manual/ad-hoc invocation outside the runner.
# Under v2 layout the per-agent state lives inside the v2 per-agent root, so
# the fallback resolves through the v2 helper when the layout is active.
if [[ -n "${CRON_REQUEST_DIR:-}" ]]; then
  sidecar_out="$CRON_REQUEST_DIR/authoritative-memory-daily.json"
else
  v2_md_root=""
  if [[ "${BRIDGE_LAYOUT:-legacy}" == "v2" ]] \
      && [[ -n "${BRIDGE_DATA_ROOT:-}" ]] \
      && [[ -d "${BRIDGE_DATA_ROOT}" ]] \
      && [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
    v2_md_root="$BRIDGE_AGENT_ROOT_V2/$AGENT/runtime/memory-daily"
  fi
  if [[ -n "$v2_md_root" ]]; then
    sidecar_out="$v2_md_root/adhoc.authoritative.json"
  else
    sidecar_out="$BRIDGE_HOME/state/memory-daily/$AGENT/adhoc.authoritative.json"
  fi
  mkdir -p "$(dirname "$sidecar_out")"
fi

# PR-C: under v2 layout the per-agent manifest must land under the per-agent
# private root and admin aggregates must land under shared/, not under the
# legacy controller state. Pass the resolved paths so bridge-memory.py
# writes manifests + aggregates into the v2 locations instead of falling
# back to BRIDGE_STATE_DIR/memory-daily. Without these flags the Python
# harvester would silently keep using the legacy controller tree (issue:
# PR-C r1 review finding P1 #1).
v2_extra_args=()
# Issue #418 codex r2 item 8: gate v2 extra args on data-root populated,
# matching the sidecar gate above. Transitional installs (marker present
# but BRIDGE_DATA_ROOT not yet populated) must fall back to legacy
# invocation — without this check, the harvester would pass v2 paths that
# don't exist on disk and bridge-memory.py would silently skip writes.
# The contract is: v2 extra args only when (a) layout is v2,
# (b) BRIDGE_DATA_ROOT is set, (c) BRIDGE_DATA_ROOT exists on disk, AND
# (d) BRIDGE_AGENT_ROOT_V2 is set. Mirrors the wiki harvester gate at
# scripts/wiki-daily-ingest.sh:174-176.
#
# Issue #786 Finding 2 (Design A binding): under linux-user isolation the
# harvester effectively runs as the isolated UID, which has only r-x on
# the controller-owned shared aggregate dir (matrix row
# `shared-memory-daily-aggregate` = mode 2750). Passing --shared-aggregate-dir
# from this context triggers EACCES on the admin-aggregate-*.json write.
# Per Design A, the isolated UID writes only the per-agent fragment under
# runtime/memory-daily/, and the controller-side reducer
# (scripts/memory-daily-reduce.sh) combines fragments into the shared
# aggregate. Legacy / non-isolated installs continue to pass both flags so
# the controller-run harvester still produces aggregates directly.
if [[ "${BRIDGE_LAYOUT:-legacy}" == "v2" ]] \
    && [[ -n "${BRIDGE_DATA_ROOT:-}" ]] \
    && [[ -d "${BRIDGE_DATA_ROOT}" ]] \
    && [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
  v2_extra_args+=(--per-agent-state-dir "$BRIDGE_AGENT_ROOT_V2/$AGENT/runtime/memory-daily")
  if [[ -n "${BRIDGE_SHARED_ROOT:-}" && "$isolation_mode" != "linux-user" ]]; then
    v2_extra_args+=(--shared-aggregate-dir "$BRIDGE_SHARED_ROOT/memory-daily/aggregate")
  fi
elif [[ "${BRIDGE_LAYOUT:-legacy}" == "v2" ]]; then
  # Marker says v2 but data-root not populated — transitional install.
  # Emit a debug breadcrumb so the operator can see the fallback.
  printf '[memory-daily-harvest] data root not populated; running legacy enumeration (BRIDGE_DATA_ROOT=%s)\n' \
    "${BRIDGE_DATA_ROOT:-unset}" >&2
fi

current_user="$(id -un 2>/dev/null || echo '')"
current_uid="$(id -u 2>/dev/null || echo '')"

# Lift target_home computation above the isolation exec branches so the
# reconcile helper below can use it for transcripts-root resolution. The
# existing isolation `if` block (further down) re-checks the same condition
# and consumes the same value — keeping both in sync requires only this one
# assignment.
target_home=""
if [[ "$isolation_mode" == "linux-user" \
      && -n "$os_user" \
      && -n "$current_user" \
      && "$os_user" != "$current_user" \
      && "$current_uid" != "0" ]]; then
  target_home="${BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT:-/home}/$os_user"
fi

# ----- cron-side jsonl reconcile (#390 PR-3) -----
#
# Before invoking the Python harvester, merge the agent's most recent session
# jsonl into its daily note via scripts/daily-note-reconcile.py (#390 PR-1).
# The harvester aggregates daily notes; reconcile is what populates them in
# the first place from the agent's running session. Without this step the
# cron path is jsonl-blind — only the Stop hook (#390 PR-2) reconciles, and
# only when the operator actually ends a session in time.
#
# The cron child has no session context, so we resolve the most recent
# session_id via `bridge-memory.py current-session-id` (the same convention
# used by hooks/session-stop.py and the wrap-up.md slash command). When
# resolution fails (no session, isolated UID without ACL, jsonl missing),
# we log to stderr and continue with the harvest — reconcile is best-effort
# and must NOT block the cron job's primary work.
reconcile_jsonl_for_cron() {
  local agent="$1"
  local workdir="$2"

  local reconcile_script="$BRIDGE_HOME/scripts/daily-note-reconcile.py"
  if [[ ! -f "$reconcile_script" ]]; then
    # Older install without PR-1 — silently skip.
    return 0
  fi

  # Discover session-id. cmd_current_session_id treats --home as the session
  # workdir (per its docstring + wrap-up.md convention) — pass the agent's
  # session cwd, not the bridge profile home. Honor PR #426 Track C
  # transcripts-home for isolated UIDs. Failure → empty stdout → skip.
  local session_id=""
  if [[ -n "$target_home" ]]; then
    session_id="$("$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" \
      current-session-id \
      --agent "$agent" \
      --home "$workdir" \
      --transcripts-home "$target_home" 2>/dev/null || true)"
  else
    session_id="$("$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" \
      current-session-id \
      --agent "$agent" \
      --home "$workdir" 2>/dev/null || true)"
  fi
  # Defensive: trim accidental trailing newline if multiple lines were emitted.
  session_id="${session_id%%$'\n'*}"

  if [[ -z "$session_id" ]]; then
    printf '[memory-daily-harvest] no current session for agent=%s; skipping reconcile\n' \
      "$agent" >&2
    return 0
  fi

  # Compose jsonl path with the same slug convention as
  # bridge-memory.cmd_current_session_id (line ~2409): replace BOTH `/` and
  # `.` in the workdir with `-`. The leading slash becomes a leading `-` and
  # MUST be preserved — Anthropic's ~/.claude/projects/ slug starts with `-`
  # for absolute paths.
  local transcripts_root
  if [[ -n "$target_home" && -d "$target_home/.claude/projects" ]]; then
    transcripts_root="$target_home/.claude/projects"
  else
    transcripts_root="$HOME/.claude/projects"
  fi

  # Resolve $workdir to its canonical absolute path before slugging. Mirrors
  # bridge-memory.py:cmd_current_session_id which does Path(home).resolve()
  # before the str.replace transform. Without this, a symlinked or relative
  # workdir produces a slug that doesn't match the python helper's output,
  # and the jsonl path lookup misses (codex r1 PR #451 item 2).
  local resolved_workdir
  resolved_workdir="$("$BRIDGE_PYTHON" -c '
import os.path, sys
print(os.path.realpath(sys.argv[1]))
' "$workdir" 2>/dev/null || true)"
  [[ -n "$resolved_workdir" ]] || resolved_workdir="$workdir"

  local slug
  slug="$(printf '%s' "$resolved_workdir" | sed 's:/:-:g; s:\.:-:g')"
  local jsonl="$transcripts_root/$slug/$session_id.jsonl"

  if [[ ! -f "$jsonl" ]]; then
    printf '[memory-daily-harvest] jsonl not found at %s; skipping reconcile\n' \
      "$jsonl" >&2
    return 0
  fi

  # Invoke reconcile. Best-effort — log on failure, continue.
  # Capture the exit code in a `set -e`-safe form: `|| rc=$?` keeps the
  # actual reconcile rc (a bare `if ! ... ; then rc=$?` would observe `$?`
  # AFTER the test inversion and always read 0).
  local rc=0
  "$BRIDGE_PYTHON" "$reconcile_script" \
    --agent "$agent" --jsonl "$jsonl" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '[memory-daily-harvest] reconcile failed (rc=%d) for agent=%s; continuing\n' \
      "$rc" "$agent" >&2
  fi
  return 0
}

# Run reconcile before either harvest exec branch. Both branches (isolated
# linux-user vs same-user) ultimately exec the harvester, and both need
# the agent's daily note populated from the latest session jsonl first.
reconcile_jsonl_for_cron "$AGENT" "$workdir"

# linux-user isolation (issue #219 v1.3 design + #1894 run-as-iso read-lens):
# the Python harvester always runs as the controller UID so queue DB reads
# (task_events), dedupe lookups (_task_status), and backfill writes
# (bridge-task.sh create) remain in the controller context (Design A, #786).
#
# The one thing the controller UID CANNOT do is read the target agent's
# transcript tree: under iso-v2 `<iso-home>/.claude` is group-setgid 3770, but
# Claude creates `projects/` at runtime under the iso UID's umask 077, landing
# at mode 2700 — no group read. There is no prepare-isolation ACL granting the
# controller r-X (that earlier claim was contract drift — #1894). So we run
# ONLY the bounded transcript scan AS the iso UID via the sanctioned sudoers
# `bash` allowlist (`bridge_isolation_run_as_agent_user_via_bash`), capture the
# JSON list on the controller's stdout, and feed it to the controller-UID
# harvest via --transcripts-json. Nothing else crosses the boundary.
#
# If passwordless sudo is unavailable (helper not loaded, or
# bridge_isolation_can_sudo_to_agent != 0), fall back to --skipped-permission
# so the admin aggregate surfaces the gap rather than erroring.
if [[ "$isolation_mode" == "linux-user" \
      && -n "$os_user" \
      && -n "$current_user" \
      && "$os_user" != "$current_user" \
      && "$current_uid" != "0" ]]; then
  iso_can_sudo=1
  if (( _BRIDGE_ISO_HELPERS_LOADED == 1 )) \
      && bridge_isolation_can_sudo_to_agent "$AGENT" 2>/dev/null; then
    iso_can_sudo=0
  fi

  if (( iso_can_sudo == 0 )); then
    # Run-as-iso transcript scan. The self-contained inline script invokes
    # `bridge-memory.py scan-transcripts` (read-only; emits the JSON list) as
    # the iso UID and prints it to stdout, which the controller captures here.
    # Footgun #11: argv-only, no heredoc-stdin in the inline body.
    #
    # Args bound inside the script:
    #   $1 = BRIDGE_PYTHON, $2 = BRIDGE_HOME, $3 = workdir, $4 = transcripts-home
    iso_scan_script='
bridge_python="$1"
bridge_home="$2"
workdir="$3"
transcripts_home="$4"
"$bridge_python" "$bridge_home/bridge-memory.py" scan-transcripts \
  --workdir "$workdir" \
  --transcripts-home "$transcripts_home"
'
    transcripts_json="$(mktemp "${TMPDIR:-/tmp}/agb-memharvest-transcripts.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f '$transcripts_json' 2>/dev/null" EXIT INT TERM
    iso_scan_rc=0
    bridge_isolation_run_as_agent_user_via_bash "$AGENT" "$iso_scan_script" \
      "$BRIDGE_PYTHON" "$BRIDGE_HOME" "$workdir" "$target_home" \
      >"$transcripts_json" 2>/dev/null || iso_scan_rc=$?

    if [[ "$iso_scan_rc" -eq 0 ]]; then
      # Cannot `exec` here — the EXIT trap must still fire to remove the temp.
      harvest_rc=0
      "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" harvest-daily \
        --agent "$AGENT" \
        --home "$home" \
        --workdir "$workdir" \
        --os-user "$os_user" \
        --transcripts-json "$transcripts_json" \
        --sidecar-out "$sidecar_out" \
        "${v2_extra_args[@]}" \
        --json || harvest_rc=$?
      exit "$harvest_rc"
    fi

    # Scan failed (iso UID could not run the scan, e.g. transient sudo or
    # Python error). Surface the gap via --skipped-permission rather than
    # silently emitting an empty transcript set. The fallback exec below
    # replaces this process, so the EXIT trap will NOT fire — remove the temp
    # and clear the trap explicitly here to avoid leaking it.
    rm -f "$transcripts_json" 2>/dev/null || true
    trap - EXIT INT TERM
    printf '[memory-daily-harvest] iso transcript scan failed (rc=%d) for agent=%s; recording skipped-permission\n' \
      "$iso_scan_rc" "$AGENT" >&2
  fi

  exec "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" harvest-daily \
    --agent "$AGENT" \
    --home "$home" \
    --workdir "$workdir" \
    --os-user "$os_user" \
    --skipped-permission \
    --sidecar-out "$sidecar_out" \
    "${v2_extra_args[@]}" \
    --json
fi

exec "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" harvest-daily \
  --agent "$AGENT" \
  --home "$home" \
  --workdir "$workdir" \
  --sidecar-out "$sidecar_out" \
  "${v2_extra_args[@]}" \
  --json
