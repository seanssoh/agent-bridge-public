#!/usr/bin/env bash
# shellcheck shell=bash
# lib/bridge-layout-v2-reconcile.sh — gated v1->v2 agent-data reconciliation
# (#1820).
#
# This is the FENCING wrapper around lib/upgrade-helpers/layout-v2-reconcile.py.
# Per the design verdict (agb-1820-design-verdict.md, option (b)), the writer
# fixes and the reconciliation must ship as ONE gated migration surface:
#
#   1. Acquire a migration/upgrade lock and quiesce old writers (daemon cron
#      dispatch must be stopped or already restarted onto the fixed code; the
#      caller is responsible for the daemon being down — this wrapper verifies
#      and refuses to reconcile against a live daemon unless forced).
#   2. The four v2-aware writer fixes are deployed at this point (they are code,
#      landed by the upgrade that calls this; this wrapper does not re-apply
#      them — it asserts the invariant afterward).
#   3. Inventory + backup both v1 and v2 sides before any mutation.
#   4. Run the idempotent v1->v2 reconcile (structured JSON: copied / preserved
#      / conflicted / skipped / warnings).
#   5. Post-apply invariant: no runtime writer still targets v1 for runtime
#      identity writes (enforced by the companion smoke; this wrapper records
#      the marker so resume is gated on a successful reconcile).
#   6. Resume is the CALLER's responsibility (the upgrade flow restarts the
#      daemon after this returns 0).
#
# The wrapper itself writes nothing in dry-run mode. In apply mode it mutates
# only the v2 tree (copies, superset adopts) and the conflict-archive tree;
# the v1 tree is left intact as rollback evidence (NOT removed here — the
# verdict's safe-removal conditions are enforced separately).
#
# Footgun #11: the python reconcile is invoked file-as-argv only; no
# heredoc-stdin is piped to a subprocess from here.

if [[ -n "${_BRIDGE_LAYOUT_V2_RECONCILE_SH_SOURCED:-}" ]]; then
  return 0
fi
_BRIDGE_LAYOUT_V2_RECONCILE_SH_SOURCED=1

# bridge_layout_v2_reconcile_state_dir
#   Migration state lives under the controller state dir so it survives the
#   reconcile and is included in diagnostics.
bridge_layout_v2_reconcile_state_dir() {
  printf '%s/migration/layout-v2-reconcile' "${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
}

bridge_layout_v2_reconcile_lock_path() {
  printf '%s/layout-v2-reconcile.lock' "$(bridge_layout_v2_reconcile_state_dir)"
}

bridge_layout_v2_reconcile_marker_path() {
  printf '%s/last-apply.json' "$(bridge_layout_v2_reconcile_state_dir)"
}

# bridge_layout_v2_reconcile_data_root
#   Resolve the v2 data root using the same precedence the writers use: explicit
#   env, then the layout marker (BRIDGE_HOME-only). Prints nothing + returns 1
#   on a legacy install (no reconcile to do).
bridge_layout_v2_reconcile_data_root() {
  if [[ -n "${BRIDGE_DATA_ROOT:-}" ]]; then
    printf '%s' "$BRIDGE_DATA_ROOT"
    return 0
  fi
  # Prefer the CANONICAL marker validator+loader (#1820 r2, codex): a corrupt or
  # tampered marker (group/world-writable, command-substitution in a value,
  # wrong owner) must be REJECTED before any mutation — never act on it via a
  # bare grep|sed parse. bridge_isolation_v2_marker_load runs
  # bridge_isolation_v2_marker_validate first and parse-exports (never sources)
  # the allowlisted KEY=value lines, exporting BRIDGE_LAYOUT/BRIDGE_DATA_ROOT
  # only on a valid marker.
  if command -v bridge_isolation_v2_marker_load >/dev/null 2>&1; then
    local _prev_layout="${BRIDGE_LAYOUT:-}" _prev_dr="${BRIDGE_DATA_ROOT:-}"
    bridge_isolation_v2_marker_load >/dev/null 2>&1 || true
    local loaded_layout="${BRIDGE_LAYOUT:-}" loaded_dr="${BRIDGE_DATA_ROOT:-}"
    # Restore any pre-existing env so this resolver stays side-effect-free.
    if [[ -n "$_prev_layout" ]]; then export BRIDGE_LAYOUT="$_prev_layout"; else unset BRIDGE_LAYOUT; fi
    if [[ -n "$_prev_dr" ]]; then export BRIDGE_DATA_ROOT="$_prev_dr"; else unset BRIDGE_DATA_ROOT; fi
    if [[ "$loaded_layout" == "v2" && -n "$loaded_dr" && "$loaded_dr" == /* ]]; then
      printf '%s' "$loaded_dr"
      return 0
    fi
    # Validator present but marker invalid/legacy -> nothing to reconcile.
    return 1
  fi
  # Fallback ONLY when the canonical validator is not sourced (minimal context).
  # This path still requires an absolute data root and a v2 layout line.
  local marker_dir marker_path layout data_root
  marker_dir="${BRIDGE_LAYOUT_MARKER_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
  marker_path="$marker_dir/layout-marker.sh"
  [[ -f "$marker_path" && ! -L "$marker_path" ]] || return 1
  layout="$(grep -E '^[[:space:]]*BRIDGE_LAYOUT=' "$marker_path" 2>/dev/null \
    | tail -n1 | sed -E 's/^[[:space:]]*BRIDGE_LAYOUT=//; s/^["'\'']//; s/["'\'']$//')"
  [[ "$layout" == "v2" ]] || return 1
  data_root="$(grep -E '^[[:space:]]*BRIDGE_DATA_ROOT=' "$marker_path" 2>/dev/null \
    | tail -n1 | sed -E 's/^[[:space:]]*BRIDGE_DATA_ROOT=//; s/^["'\'']//; s/["'\'']$//')"
  [[ -n "$data_root" && "$data_root" == /* ]] || return 1
  printf '%s' "$data_root"
}

# bridge_layout_v2_reconcile_roster_agents
#   CSV of roster-scoped agent ids. Prefers the loaded roster array; falls back
#   to scanning the v2 agents dir so the reconcile still runs in a minimal
#   upgrade context where the roster isn't sourced.
bridge_layout_v2_reconcile_roster_agents() {
  local data_root="$1"
  local -a ids=()
  if declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
    local a
    for a in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ -n "$a" ]] && ids+=("$a")
    done
  fi
  if [[ ${#ids[@]} -eq 0 && -d "$data_root/agents" ]]; then
    local d
    for d in "$data_root/agents"/*/; do
      [[ -d "$d" ]] || continue
      local name="${d%/}"
      name="${name##*/}"
      [[ "$name" == "_template" || "$name" == "shared" || "$name" == .* ]] && continue
      ids+=("$name")
    done
  fi
  local IFS=,
  printf '%s' "${ids[*]:-}"
}

# bridge_layout_v2_reconcile_iso_agents_json <agents-csv>
#   Emit a JSON object {"<agent>":"<os_user>", ...} for the subset of the given
#   roster-scoped agents that are EFFECTIVELY iso v2 isolated (linux-user
#   isolation active on this host for that agent). The python engine consumes
#   this (via --iso-agents-json, file-as-argv) to GRACEFUL-SKIP the controller-
#   side direct-read/backup of those agents' 0600 agent-private memory (#1820
#   rc3) — the controller cannot read it and must not try.
#
#   Emits "{}" when no agents are isolated (shared-mode install, macOS, or the
#   iso helpers are not sourced), which makes the engine behave exactly as it
#   did before this fix. Best-effort + side-effect-free: a missing helper or an
#   unresolvable os_user simply omits that agent (it then takes the normal
#   shared-mode path). Built with printf (no python dependency on this path).
bridge_layout_v2_reconcile_iso_agents_json() {
  local agents_csv="$1"
  # Without the agent iso predicate we cannot classify anything as iso — treat
  # the whole install as shared-mode (the engine's prior behavior).
  if ! command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1; then
    printf '{}'
    return 0
  fi
  local -a pairs=()
  local agent os_user
  local IFS=,
  local -a ids=()
  read -r -a ids <<<"$agents_csv"
  unset IFS
  for agent in "${ids[@]}"; do
    [[ -n "$agent" ]] || continue
    bridge_agent_linux_user_isolation_effective "$agent" || continue
    os_user=""
    if command -v bridge_agent_os_user >/dev/null 2>&1; then
      os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    fi
    [[ -n "$os_user" ]] || continue
    # JSON-escape backslash and double-quote in agent id and os_user (both are
    # constrained to safe charsets by the roster/os-user composers, but escape
    # defensively so the emitted object is always valid JSON).
    local ja jo
    ja="${agent//\\/\\\\}"; ja="${ja//\"/\\\"}"
    jo="${os_user//\\/\\\\}"; jo="${jo//\"/\\\"}"
    pairs+=("\"$ja\":\"$jo\"")
  done
  if [[ ${#pairs[@]} -eq 0 ]]; then
    printf '{}'
    return 0
  fi
  local out="{" i=0
  local p
  for p in "${pairs[@]}"; do
    if [[ $i -gt 0 ]]; then out+=","; fi
    out+="$p"
    i=$((i + 1))
  done
  out+="}"
  printf '%s' "$out"
}

# bridge_layout_v2_reconcile_host_iso_active <agents-csv>
#   Print "1" iff this host is iso-v2-active, else "0" (#1820 rc4). This is the
#   HOST-LEVEL signal the engine's defensive belt uses: when active, a
#   controller PermissionError reaching an agent home is recorded as a
#   structured graceful-skip instead of an Errno13 warning — EVEN for an agent
#   the iso-map builder failed to classify (the cm-prod 6/8 case, where the
#   reconcile driver context had incomplete os_user / isolation_mode registry
#   metadata for some production bots).
#
#   A host is iso-v2-active iff:
#     * host platform is Linux (the OS-user boundary only exists there), AND
#     * at least one rostered agent either resolved into the iso map OR merely
#       REQUESTED linux-user isolation (isolation_mode==linux-user). We accept
#       "requested" — not only "effective" — precisely because the bug is that
#       os_user resolution can be incomplete; gating the belt on full
#       resolution would re-open the exact gap. On a pure shared-mode Linux
#       host (no agent requests linux-user) this is "0" and PermissionErrors
#       stay warnings, byte-identical to pre-rc4. On macOS it is always "0".
#   Best-effort + side-effect-free: a missing predicate yields "0" (shared-mode
#   behavior preserved).
bridge_layout_v2_reconcile_host_iso_active() {
  local agents_csv="$1"
  # macOS / non-Linux: the boundary does not exist. Resolve platform via the
  # canonical predicate when available, else uname.
  local platform=""
  if command -v bridge_host_platform >/dev/null 2>&1; then
    platform="$(bridge_host_platform 2>/dev/null || true)"
  else
    platform="$(uname -s 2>/dev/null || true)"
  fi
  [[ "$platform" == "Linux" ]] || { printf '0'; return 0; }
  # If the iso-map builder classified anything, the host is iso-active.
  local iso_json
  iso_json="$(bridge_layout_v2_reconcile_iso_agents_json "$agents_csv")"
  if [[ -n "$iso_json" && "$iso_json" != "{}" ]]; then
    printf '1'
    return 0
  fi
  # Otherwise check whether ANY rostered agent merely REQUESTED linux-user
  # isolation — robust to incomplete os_user resolution (the cm-prod gap).
  if command -v bridge_agent_linux_user_isolation_requested >/dev/null 2>&1; then
    local agent
    local IFS=,
    local -a ids=()
    read -r -a ids <<<"$agents_csv"
    unset IFS
    for agent in "${ids[@]}"; do
      [[ -n "$agent" ]] || continue
      if bridge_agent_linux_user_isolation_requested "$agent" 2>/dev/null; then
        printf '1'
        return 0
      fi
    done
  fi
  printf '0'
}

# bridge_layout_v2_reconcile_noop_json
#   Emit the canonical STRUCTURED no-op result object. Used when there is no
#   v1->v2 reconcile to perform (legacy / non-v2 install or no v1-only data) so
#   the result marker is ALWAYS a well-formed structured JSON — never an empty
#   file (rc2 soak observability). Mirrors the python helper's shape (same
#   arrays + counts keys) with everything zeroed, plus the explicit
#   `status:"noop"` discriminator and a timestamp. ASCII-only, printf-built (no
#   python dependency required on this path).
bridge_layout_v2_reconcile_noop_json() {
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
  printf '{"status":"noop","mode":"apply","schema":"layout-v2-reconcile/1","reason":"legacy/non-v2 install or no v1-only data","copied":[],"preserved":[],"conflicted":[],"skipped":[],"warnings":[],"isolation_v2_migration":[],"counts":{"copied":0,"preserved":0,"conflicted":0,"skipped":0,"warnings":0,"backed_up":0,"isolation_v2_migration":0},"timestamp":"%s"}\n' \
    "$ts"
}

# bridge_layout_v2_reconcile_run --mode apply|dry-run [--force-live-daemon]
#   The fenced reconcile entry point. Emits the python helper's JSON on stdout.
#   Returns:
#     0  reconcile completed (including when conflicts were reported)
#     2  legacy install / nothing to do (structured no-op JSON in apply mode)
#     3  refused: live daemon and not forced (fencing violation)
#     1  internal error
bridge_layout_v2_reconcile_run() {
  local mode="dry-run"
  local force_live_daemon=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) mode="$2"; shift 2 ;;
      --force-live-daemon) force_live_daemon=1; shift ;;
      *) shift ;;
    esac
  done

  local data_root
  if ! data_root="$(bridge_layout_v2_reconcile_data_root)"; then
    # Legacy install — no v1->v2 reconcile to perform. Still persist a STRUCTURED
    # no-op result to the canonical marker (apply mode only) + emit it on stdout
    # so the upgrade path's result file is never empty / mislocated (rc2 soak
    # observability). The caller treats rc=2 as a benign proceed.
    if [[ "$mode" == "apply" ]]; then
      local _noop_state_dir _noop_json
      _noop_state_dir="$(bridge_layout_v2_reconcile_state_dir)"
      _noop_json="$(bridge_layout_v2_reconcile_noop_json)"
      mkdir -p "$_noop_state_dir" 2>/dev/null || true
      printf '%s' "$_noop_json" >"$(bridge_layout_v2_reconcile_marker_path)" 2>/dev/null || true
      printf '%s' "$_noop_json"
    fi
    return 2
  fi

  local script_dir helper
  script_dir="${BRIDGE_SCRIPT_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
  helper="$script_dir/lib/upgrade-helpers/layout-v2-reconcile.py"
  if [[ ! -f "$helper" ]]; then
    printf '{"error":"reconcile helper missing","helper":"%s"}\n' "$helper" >&2
    return 1
  fi

  # Fencing: refuse to mutate against a live daemon unless explicitly forced.
  # A live daemon may still dispatch a cron disposable worker that writes to v1
  # mid-reconcile, recreating the fork — exactly the race the verdict warns of.
  # FAIL-CLOSED (#1820 r2, codex): in apply mode the quiesce check must be able
  # to PROVE the daemon is down. If bridge_daemon_all_pids is unavailable (the
  # daemon module is not sourced), we cannot prove quiescence, so we refuse
  # rather than silently skip the fence. `--force-live-daemon` is the explicit
  # operator override for contexts where quiescence is guaranteed externally.
  if [[ "$mode" == "apply" && "$force_live_daemon" -eq 0 ]]; then
    if ! command -v bridge_daemon_all_pids >/dev/null 2>&1; then
      printf '{"error":"refused: cannot prove daemon quiescence (bridge_daemon_all_pids unavailable); source the daemon module or pass --force-live-daemon"}\n' >&2
      return 3
    fi
    # #1820 r4 (codex): `daemon stop` (SIGTERM) is ASYNCHRONOUS — it returns
    # before the daemon process has actually exited, so an immediate PID check
    # can still see the draining daemon and refuse a legitimately-quiescing
    # install. Poll bridge_daemon_all_pids for a BOUNDED window (default 10s,
    # override via BRIDGE_LAYOUT_V2_RECONCILE_QUIESCE_WAIT) so a short teardown
    # race resolves to "down" instead of a spurious refusal. We still FAIL-CLOSED
    # if PIDs persist past the window (a daemon that will not die is a real
    # fencing violation — refuse rather than race a v1 cron write).
    local _quiesce_wait="${BRIDGE_LAYOUT_V2_RECONCILE_QUIESCE_WAIT:-10}"
    [[ "$_quiesce_wait" =~ ^[0-9]+$ ]] || _quiesce_wait=10
    # Force base-10 in all arithmetic below (#1820 r5, codex): a digits-only but
    # leading-zero value like `09` is a malformed OCTAL literal in Bash
    # arithmetic (`(( x >= 09 ))` errors "value too great for base 8"), which
    # would break the ceiling check and could loop instead of failing closed.
    # `10#` pins base-10 so any zero-padded value compares correctly.
    local _waited=0 _pids
    while :; do
      _pids="$(bridge_daemon_all_pids 2>/dev/null || true)"
      [[ -z "$_pids" ]] && break
      if (( _waited >= 10#$_quiesce_wait )); then
        printf '{"error":"refused: daemon still live after %ss quiesce wait (pids present); stop it before apply, or pass --force-live-daemon"}\n' "$_quiesce_wait" >&2
        return 3
      fi
      sleep 1
      _waited=$((_waited + 1))
    done
  fi

  local state_dir backup_root queue_dir stamp
  state_dir="$(bridge_layout_v2_reconcile_state_dir)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
  backup_root="$state_dir/backups/$stamp"
  queue_dir="$state_dir/manual-tasks"
  if [[ "$mode" == "apply" ]]; then
    mkdir -p "$state_dir" "$backup_root" "$queue_dir" 2>/dev/null || true
  fi

  local agents_csv
  agents_csv="$(bridge_layout_v2_reconcile_roster_agents "$data_root")"

  local python_bin
  python_bin="$(command -v python3 || command -v python || true)"
  if [[ -z "$python_bin" ]]; then
    printf '{"error":"python3 not found"}\n' >&2
    return 1
  fi

  # Acquire the migration lock for the apply mutation window (refuse-fast).
  local lock_token=""
  if [[ "$mode" == "apply" ]] && command -v bridge_scoped_lock_acquire >/dev/null 2>&1; then
    mkdir -p "$state_dir" 2>/dev/null || true
    if bridge_scoped_lock_acquire "$(bridge_layout_v2_reconcile_lock_path)"; then
      lock_token="$BRIDGE_SCOPED_LOCK_TOKEN"
    else
      printf '{"error":"refused: another layout-v2 reconcile holds the lock"}\n' >&2
      return 3
    fi
  fi

  # Conflict archives default UNDER v2 (verdict: "copy the v1 variant to a
  # conflict archive under v2") — we do NOT pass --conflict-archive-root, so the
  # engine writes each conflict under `<data>/agents/<a>/home/.reconcile-
  # conflicts/`. The archive PATHS are carried in the emitted JSON
  # (conflicted[].archived) and the JSON is persisted to the state marker below,
  # so archives are included in diagnostic output as the verdict requires.
  # iso v2 (#1820 rc3): compute {agent: os_user} for effectively-isolated agents
  # and hand it to the engine file-as-argv (footgun #11) so it graceful-skips the
  # controller-side direct-read/backup of those agents' 0600 agent-private
  # memory. Best-effort: "{}" (no iso agents) preserves the prior shared-mode
  # behavior byte-for-byte. The file lives under the migration state dir so it is
  # captured in diagnostics; we clean it up after the engine run.
  local iso_agents_json iso_agents_file=""
  iso_agents_json="$(bridge_layout_v2_reconcile_iso_agents_json "$agents_csv")"
  if [[ -n "$iso_agents_json" && "$iso_agents_json" != "{}" ]]; then
    mkdir -p "$state_dir" 2>/dev/null || true
    iso_agents_file="$state_dir/.iso-agents-${stamp}.json"
    printf '%s' "$iso_agents_json" >"$iso_agents_file" 2>/dev/null || iso_agents_file=""
  fi

  # Host-level iso-v2-active signal for the engine's defensive belt (#1820 rc4).
  # When active, a controller PermissionError reaching an agent home becomes a
  # structured graceful-skip even for an agent the iso-map builder missed (the
  # cm-prod 6/8 case). On shared-mode / macOS this is "0" → PermissionErrors
  # stay warnings (byte-identical to pre-rc4).
  local host_iso_active
  host_iso_active="$(bridge_layout_v2_reconcile_host_iso_active "$agents_csv")"
  local -a host_iso_flag=()
  [[ "$host_iso_active" == "1" ]] && host_iso_flag=(--host-iso-active)

  local out rc
  out="$("$python_bin" "$helper" \
    --bridge-home "${BRIDGE_HOME:-$HOME/.agent-bridge}" \
    --data-root "$data_root" \
    --agents-csv "$agents_csv" \
    --mode "$mode" \
    --backup-root "$backup_root" \
    --iso-agents-json "$iso_agents_file" \
    "${host_iso_flag[@]}" \
    --queue-task-dir "$queue_dir" 2>/dev/null)"
  rc=$?

  # The iso-agents map is a transient input to the engine; remove it after the
  # run (the structured isolation_v2_migration section in the result JSON is the
  # durable audit record, not this scratch file).
  [[ -n "$iso_agents_file" && -f "$iso_agents_file" ]] && rm -f "$iso_agents_file" 2>/dev/null || true

  if [[ "$mode" == "apply" && -n "$lock_token" ]] \
      && command -v bridge_scoped_lock_release >/dev/null 2>&1; then
    bridge_scoped_lock_release "$lock_token"
  fi

  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$out"
    return 1
  fi

  # Stamp an explicit top-level status discriminator onto the engine JSON so the
  # persisted result is self-describing (status:"applied" vs the no-op path's
  # status:"noop") without a consumer having to infer it from the counts (rc2
  # soak observability). Best-effort: if the inject fails (no python / malformed
  # — neither expected here, we just ran the engine) we fall back to the raw
  # engine JSON, which is still structured and non-empty.
  local _stamped
  _stamped="$(printf '%s' "$out" | "$python_bin" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if isinstance(d, dict) and "status" not in d:
        d = {"status": "applied", **d}
    sys.stdout.write(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True))
    sys.stdout.write("\n")
except Exception:
    sys.exit(1)
' 2>/dev/null)" && [[ -n "$_stamped" ]] && out="$_stamped"

  # Record the apply marker so resume is gated on a completed reconcile.
  if [[ "$mode" == "apply" ]]; then
    printf '%s\n' "$out" >"$(bridge_layout_v2_reconcile_marker_path)" 2>/dev/null || true
    # Create a REAL queue task per divergent conflict so the operator gets an
    # actionable inbox item (verdict: "create a manual queue task"), not just a
    # markdown file. Best-effort: if the queue CLI is unavailable (minimal
    # upgrade context) the markdown task the engine already wrote under
    # state/migration/.../manual-tasks/ remains the durable record. Each task
    # body is the engine-written markdown; the dedup marker means a re-apply
    # does not re-emit the markdown, so this loop is bounded to NEW conflicts.
    bridge_layout_v2_reconcile_enqueue_conflicts "$out"
  fi

  printf '%s\n' "$out"
  return 0
}

# bridge_layout_v2_reconcile_enqueue_conflicts <reconcile-json>
#   For each conflict in the reconcile JSON that has a freshly-written queue_task
#   markdown (i.e. NOT already_archived), create a durable queue task addressed
#   to the configured admin agent. Best-effort; never fatal.
bridge_layout_v2_reconcile_enqueue_conflicts() {
  local json="$1"
  local task_sh="${BRIDGE_SCRIPT_DIR:-.}/bridge-task.sh"
  [[ -f "$task_sh" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local admin=""
  if command -v bridge_admin_agent_id >/dev/null 2>&1; then
    admin="$(bridge_admin_agent_id 2>/dev/null || true)"
  fi
  [[ -n "$admin" ]] || admin="${BRIDGE_ADMIN_AGENT_ID:-}"
  [[ -n "$admin" ]] || return 0

  # Emit one base64(JSON) line PER conflict that has a freshly-written task file
  # (already_archived=false ⇒ queue_task non-null). base64 (not TSV) because
  # `rel` is raw filesystem-derived text and `queue_task` paths can contain
  # tabs/newlines, which would corrupt a delimited row (#1820 r3, codex). One
  # opaque token per line is newline-safe and the shell never parses the fields.
  local rows
  rows="$(printf '%s' "$json" | python3 -c '
import base64, json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for c in d.get("conflicted", []):
    qt = c.get("queue_task")
    if qt and not c.get("already_archived"):
        rec = {"agent": c.get("agent",""), "rel": c.get("rel",""), "queue_task": qt}
        sys.stdout.write(base64.b64encode(
            json.dumps(rec, ensure_ascii=False).encode("utf-8")).decode("ascii") + "\n")
' 2>/dev/null)"
  [[ -n "$rows" ]] || return 0

  local bash_bin="${BRIDGE_BASH_BIN:-$(command -v bash)}"
  local token agent rel qt
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    # Decode each field individually via python (no shell field-splitting on the
    # raw path text). Empty output => skip.
    agent="$(printf '%s' "$token" | python3 -c 'import base64,json,sys; print(json.loads(base64.b64decode(sys.stdin.read())).get("agent",""))' 2>/dev/null)"
    rel="$(printf '%s' "$token" | python3 -c 'import base64,json,sys; print(json.loads(base64.b64decode(sys.stdin.read())).get("rel",""))' 2>/dev/null)"
    qt="$(printf '%s' "$token" | python3 -c 'import base64,json,sys; print(json.loads(base64.b64decode(sys.stdin.read())).get("queue_task",""))' 2>/dev/null)"
    [[ -n "$agent" && -n "$qt" && -f "$qt" ]] || continue
    "$bash_bin" "$task_sh" create \
      --from "$admin" --to "$admin" \
      --title "[reconcile-conflict] $agent: divergent v1/v2 memory $rel (#1820)" \
      --body-file "$qt" >/dev/null 2>&1 || true
  done <<< "$rows"
}
