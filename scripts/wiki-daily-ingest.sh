#!/bin/bash
# Wiki daily ingest orchestrator (Phase 1 hardening — 2026-04-19).
#
# Two lanes:
#
#   Lane A — daily-note replication (deterministic, no LLM):
#     Agent memory/YYYY-MM-DD.md files are copied as byte-equivalent
#     replicas to shared/wiki/agents/<agent>/daily/<agent>-YYYY-MM-DD.md
#     per wiki-graph-rules.md §2. Handled by wiki-daily-copy.py.
#
#   Lane B — non-daily capture ingest (LLM-assisted):
#     Research/project/decision/shared files modified in the last 24h
#     are queued as a [librarian-ingest] task. Daily notes are NEVER
#     included in this lane — previously that caused misrouting into
#     operating-rules.md because daily notes carry no schema_version=1
#     envelope and hit the librarian ambiguous-fallback path.
#
# This script runs both lanes in sequence. Either can no-op cleanly.

set -u
# Resolve bridge home + paths from env with sane defaults. Do not
# hardcode ~/.agent-bridge — other deployments may relocate.
: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
: "${BRIDGE_AGENTS_ROOT:=$BRIDGE_HOME/agents}"
: "${BRIDGE_SHARED_ROOT:=$BRIDGE_HOME/shared}"
: "${BRIDGE_WIKI_ROOT:=$BRIDGE_SHARED_ROOT/wiki}"
: "${BRIDGE_SCRIPTS_ROOT:=$BRIDGE_HOME/scripts}"
: "${BRIDGE_STATE_DIR:=$BRIDGE_HOME/state}"
: "${BRIDGE_AGB:=$BRIDGE_HOME/agent-bridge}"
: "${BRIDGE_ADMIN_AGENT:=${BRIDGE_ADMIN_AGENT_ID:-patch}}"

# Watermark of the last successful Lane A ingest. Persisted between runs so
# late-arriving daily notes (written after the previous run's window) are
# still picked up on the next run instead of being stranded by the static
# 2-day rolling window. See issue #321 Track A.
WIKI_INGEST_STATE_DIR="$BRIDGE_STATE_DIR/wiki"
WIKI_INGEST_WATERMARK_FILE="$WIKI_INGEST_STATE_DIR/last-ingest.txt"

AGENTS_ROOT="$BRIDGE_AGENTS_ROOT"
WIKI="$BRIDGE_WIKI_ROOT"
SCRIPTS_ROOT="$BRIDGE_SCRIPTS_ROOT"
DATE=$(date +%Y-%m-%d)

# compute_since_date — resolve effective --since for Lane A.
#
# Reads the persisted watermark if it exists and parses as YYYY-MM-DD.
# Falls back to "yesterday" on missing/empty/malformed input. Clamps the
# result to max(watermark, today-14d) so a long-stale watermark cannot
# trigger an unbounded backfill. The 14-day floor matches the practical
# lookback window operators care about; revisit if data shows otherwise.
compute_since_date() {
  local watermark=""
  if [ -f "$WIKI_INGEST_WATERMARK_FILE" ]; then
    watermark="$(head -n1 "$WIKI_INGEST_WATERMARK_FILE" 2>/dev/null | tr -d '[:space:]')"
    if ! [[ "$watermark" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      watermark=""
    fi
  fi
  local default_since
  default_since=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d)
  if [ -z "$watermark" ]; then
    printf '%s' "$default_since"
    return 0
  fi
  local floor
  floor=$(date -v-14d +%Y-%m-%d 2>/dev/null || date -d '14 days ago' +%Y-%m-%d)
  # Lexicographic compare is correct for ISO-8601 YYYY-MM-DD.
  if [[ "$watermark" < "$floor" ]]; then
    printf '%s' "$floor"
  else
    printf '%s' "$watermark"
  fi
}

YESTERDAY="$(compute_since_date)"
LOG="$WIKI/_audit/ingest-$DATE.md"
mkdir -p "$(dirname "$LOG")"

# write_watermark_atomic — durable, crash-safe watermark write.
#
# Writes to a tempfile in the same directory and renames into place so a
# crash mid-write cannot leave a partial / corrupt watermark behind.
write_watermark_atomic() {
  local date_str="$1"
  mkdir -p "$WIKI_INGEST_STATE_DIR" || return 1
  local tmp
  tmp="$(mktemp "$WIKI_INGEST_STATE_DIR/.last-ingest.XXXXXX")" || return 1
  printf '%s\n' "$date_str" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$WIKI_INGEST_WATERMARK_FILE"
  # Issue #321 r2: explicit permission so the watermark mode does not depend
  # on the caller's umask. Matches peer daemon-owned state files under
  # $BRIDGE_STATE_DIR (active-roster.md, tasks.db, daemon.* — all 0600).
  chmod 600 "$WIKI_INGEST_WATERMARK_FILE" 2>/dev/null || true
}

# -------------------------------------------------------------------------
# Lane A — daily-note byte-replica copy (no librarian involvement)
# -------------------------------------------------------------------------

COPY_JSON="$(mktemp -t wiki-daily-copy.XXXXXX.json)"
# shellcheck disable=SC2064
trap "rm -f '$COPY_JSON'" EXIT

copy_rc=0
python3 "$SCRIPTS_ROOT/wiki-daily-copy.py" \
  --since "$YESTERDAY" --until "$DATE" --json \
  >"$COPY_JSON" 2>>"$LOG" || copy_rc=$?

copy_summary=$(python3 - "$COPY_JSON" <<'PYEOF'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    print("copy-summary-unavailable")
    sys.exit(0)
print(
    f"agents={data.get('agents_seen',0)} "
    f"files={data.get('files_seen',0)} "
    f"created={data.get('created',0)} "
    f"replaced={data.get('replaced',0)} "
    f"unchanged={data.get('unchanged',0)} "
    f"errors={data.get('errors',0)}"
)
PYEOF
)

# Extract Lane A error count for watermark gating. Treat parse failure /
# missing field as non-zero so we never advance the watermark on a run we
# could not verify succeeded.
copy_errors=$(python3 - "$COPY_JSON" <<'PYEOF'
import json
import sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
    print(int(data.get("errors", 1)))
except Exception:
    print(1)
PYEOF
)

# -------------------------------------------------------------------------
# Lane B — non-daily captures for librarian ingest.
#
# v2-gated dual-mode enumeration. Default-off invariant: legacy installs
# (BRIDGE_LAYOUT unset or "legacy") use the original find-based enumeration
# over $AGENTS_ROOT/*/memory/... so unrelated installs are unaffected by
# PR-D's stricter contract. Only when BRIDGE_LAYOUT=v2 do we switch to the
# workdir-aware strict probe via `agb agent list --json` — install-root
# memory is a frozen snapshot under v2, so the workdir field becomes the
# single source of truth.
#
# Strict (v2) fail-closed semantics:
#   - BRIDGE_AGB 미실행/비실행파일      → exit 2
#   - `agent list --json` 호출 실패      → exit 2 + stderr
#   - JSON parse 실패 또는 list 아님     → exit 2 + stderr
#   - 정상 + 진짜 0 active claude agent  → silent OK, Lane B 0 카운트
# 모든 fail 경로는 `_lane_b_stderr` 임시파일을 명시적으로 rm 한 뒤 exit
# (기존 line ~101 의 COPY_JSON EXIT trap 을 손상하지 않기 위해 별도 trap 미사용).
#
# Isolated-agent skip (issue #583 Track C):
#   Agents created with `--isolation linux-user` own their `memory/` subtree
#   under a per-UID 0700 root. The librarian (running as the operator UID)
#   cannot read those paths, so any [librarian-ingest] task pointed at them
#   completes with "cross-agent access blocked" and the same files re-queue
#   the next day forever. We classify isolation up-front from operator-UID-
#   readable metadata only (`agb agent list --json` reads the roster, never
#   the agent's private root) and skip such agents from Lane B entirely
#   before any `find`/`ls` touches their tree. Skipped agents are recorded
#   in the audit log AND the stdout summary with the stable reason string
#   `isolated_private_root_unreadable_by_design` so log consumers can grep
#   on it. Track A (ACL grant on the private root) is rejected by operator
#   policy after isolate-v2; Track B (push-to-staging) is the long-term
#   fix and ships separately.
# -------------------------------------------------------------------------

: "${BRIDGE_AGB:=$BRIDGE_HOME/agent-bridge}"
: "${BRIDGE_PYTHON:=python3}"

# Stable identifier for the skip reason. Keep this literal in sync with
# any downstream log consumers / dashboards that grep on it.
readonly LANE_B_ISOLATED_SKIP_REASON="isolated_private_root_unreadable_by_design"

declare -a AGENT_MEMORY_ROOTS=()
declare -a SKIPPED_ISOLATED_AGENTS=()

# Active-contract gate: v2 path requires BRIDGE_LAYOUT=v2 AND a populated
# BRIDGE_DATA_ROOT directory. A child env that propagates only LAYOUT=v2
# without the data root would otherwise drop into the strict v2 enumeration
# with no place to read from. PR-F invariant: gate on contract, not textual
# default.
if [[ "${BRIDGE_LAYOUT:-legacy}" == "v2" \
      && -n "${BRIDGE_DATA_ROOT:-}" \
      && -d "${BRIDGE_DATA_ROOT}" ]]; then
  # v2: strict workdir-aware enumeration via `agb agent list --json`.
  if [[ ! -x "$BRIDGE_AGB" ]]; then
    printf '[wiki-daily-ingest] BRIDGE_AGB not executable: %s\n' "$BRIDGE_AGB" >&2
    exit 2
  fi

  _lane_b_stderr="$(mktemp -t wiki-daily-ingest.agb-stderr.XXXXXX)"

  agent_list_json="$("$BRIDGE_AGB" agent list --json 2>"$_lane_b_stderr")"
  agb_exit=$?
  if (( agb_exit != 0 )); then
    printf '[wiki-daily-ingest] agb agent list --json failed (exit=%d): %s\n' \
      "$agb_exit" "$(cat "$_lane_b_stderr")" >&2
    rm -f "$_lane_b_stderr"
    exit 2
  fi

  # Emit "<agent>\t<workdir>\t<isolation_mode>" per active claude agent.
  # isolation_mode is read from the JSON only — the roster is the source of
  # truth and the operator UID can read it; we never touch the agent's
  # private root to determine isolation status (issue #583 Track C).
  agents_tsv="$("$BRIDGE_PYTHON" - "$agent_list_json" <<'PY' 2>"$_lane_b_stderr"
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception as e:
    print(f"malformed JSON: {e}", file=sys.stderr)
    sys.exit(2)
if not isinstance(data, list):
    print(f"expected JSON list, got {type(data).__name__}", file=sys.stderr)
    sys.exit(2)
for a in data:
    if not isinstance(a, dict):
        continue
    if a.get("engine") != "claude" or not a.get("active"):
        continue
    name = a.get("agent") or ""
    wd = a.get("workdir") or ""
    if not name or not wd:
        continue
    isolation = a.get("isolation") or {}
    mode = (isolation.get("mode") if isinstance(isolation, dict) else "") or "shared"
    print(f"{name}\t{wd}\t{mode}")
PY
)"
  parse_exit=$?
  if (( parse_exit != 0 )); then
    printf '[wiki-daily-ingest] agent list JSON parse failed (exit=%d): %s\n' \
      "$parse_exit" "$(cat "$_lane_b_stderr")" >&2
    rm -f "$_lane_b_stderr"
    exit 2
  fi
  rm -f "$_lane_b_stderr"

  if [[ -n "$agents_tsv" ]]; then
    while IFS=$'\t' read -r _agent _workdir _isolation; do
      [[ -n "$_agent" && -n "$_workdir" ]] || continue
      # Issue #583 Track C: skip linux-user-isolated agents BEFORE any
      # filesystem read. The classifier above used only operator-UID-
      # readable metadata so this branch never opens the private root.
      if [[ "$_isolation" == "linux-user" ]]; then
        SKIPPED_ISOLATED_AGENTS+=("$_agent")
        continue
      fi
      [[ -d "$_workdir/memory" ]] || continue
      AGENT_MEMORY_ROOTS+=("$_workdir/memory")
    done <<< "$agents_tsv"
  fi
else
  # Legacy: original find-based enumeration over $AGENTS_ROOT/*/memory.
  # Each install-root agent dir with a memory/ subtree contributes a root.
  #
  # Issue #583 Track C: ask `agb agent list --json` (operator-UID-readable
  # roster only — does not touch any agent's private root) for the
  # isolation mode of each agent and skip linux-user agents before the
  # find walk reaches their tree. Best-effort: if BRIDGE_AGB is missing
  # or the call fails / returns malformed JSON, the deny-list stays
  # empty and the legacy path runs exactly as before. This preserves the
  # legacy default-off invariant while giving the skip path a chance to
  # work on every install where the CLI is healthy.
  #
  # Bash 3.2 compatibility: macOS system bash lacks associative arrays,
  # so the deny-list is held as a newline-delimited string with leading
  # and trailing delimiters and tested via `[[ ... == *NL$name$NL* ]]`.
  # bridge_validate_agent_name already restricts agent names to
  # alphanumerics/dash/underscore so a name cannot contain a literal
  # newline that would defeat the membership test.
  _legacy_iso_deny_list=$'\n'
  if [[ -x "$BRIDGE_AGB" ]]; then
    _legacy_iso_json="$("$BRIDGE_AGB" agent list --json 2>/dev/null || true)"
    if [[ -n "$_legacy_iso_json" ]]; then
      _legacy_iso_tsv="$("$BRIDGE_PYTHON" - "$_legacy_iso_json" <<'PY' 2>/dev/null || true
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for a in data:
    if not isinstance(a, dict):
        continue
    name = a.get("agent") or ""
    if not name:
        continue
    isolation = a.get("isolation") or {}
    mode = (isolation.get("mode") if isinstance(isolation, dict) else "") or "shared"
    if mode == "linux-user":
        print(name)
PY
)"
      while IFS= read -r _iso_name; do
        [[ -n "$_iso_name" ]] || continue
        _legacy_iso_deny_list+="$_iso_name"$'\n'
      done <<< "$_legacy_iso_tsv"
    fi
  fi

  if [[ -d "$AGENTS_ROOT" ]]; then
    # Issue #583 Track C r2: glob $AGENTS_ROOT/* (the operator-UID-readable
    # parent), derive the agent name from the path, run the deny-list check
    # FIRST, and only then `[[ -d "$_legacy_agent_dir/memory" ]]`. The
    # previous shape stat'd the agent's memory subdir before the deny-list
    # check, which could trip permissions on installs where the agent home
    # itself is per-UID owned. The "skip BEFORE any read attempt into a
    # possibly-private path" contract requires the deny-list to gate even
    # the directory-existence test on $_legacy_agent_dir/memory.
    for _legacy_agent_dir in "$AGENTS_ROOT"/*; do
      # Stat the parent (operator-UID-readable in v1 layout). Skip non-dir
      # entries like stray files or broken symlinks.
      [[ -d "$_legacy_agent_dir" ]] || continue
      _legacy_agent="${_legacy_agent_dir##*/}"
      if [[ "$_legacy_iso_deny_list" == *$'\n'"$_legacy_agent"$'\n'* ]]; then
        SKIPPED_ISOLATED_AGENTS+=("$_legacy_agent")
        continue
      fi
      _legacy_memory_dir="$_legacy_agent_dir/memory"
      [[ -d "$_legacy_memory_dir" ]] || continue
      AGENT_MEMORY_ROOTS+=("$_legacy_memory_dir")
    done
  fi
fi

# Deduplicate the skipped-agent list and sort for deterministic output.
# Bash 3.2 compatibility: avoid mapfile (bash 4) by using a portable read
# loop into a temporary array, then reassigning.
if (( ${#SKIPPED_ISOLATED_AGENTS[@]} > 0 )); then
  _skipped_sorted=()
  while IFS= read -r _name; do
    [[ -n "$_name" ]] && _skipped_sorted+=("$_name")
  done < <(printf '%s\n' "${SKIPPED_ISOLATED_AGENTS[@]}" | sort -u)
  SKIPPED_ISOLATED_AGENTS=("${_skipped_sorted[@]}")
fi
skipped_isolated_count=${#SKIPPED_ISOLATED_AGENTS[@]}

# Research files touched in last 24h (across all active agent memory roots).
# Issue #583 Track C: AGENT_MEMORY_ROOTS may legitimately be empty when every
# active agent is linux-user-isolated (and therefore skipped). Use the
# defined-fallback expansion so `set -u` does not trip on the empty array.
touched_research=""
if (( ${#AGENT_MEMORY_ROOTS[@]} > 0 )); then
  for _root in "${AGENT_MEMORY_ROOTS[@]}"; do
    [[ -d "$_root/research" ]] || continue
    while IFS= read -r _f; do
      [[ -n "$_f" ]] && touched_research+="$_f"$'\n'
    done < <(find "$_root/research" -type f -name '*.md' -mtime -1 2>/dev/null)
  done
fi
touched_research=$(printf '%s' "$touched_research" | sed '/^$/d' | sort -u)
research_count=$(printf '%s\n' "$touched_research" | grep -c '[^[:space:]]' || true)
research_count=${research_count:-0}

# projects/shared/decisions files touched in last 24h.
touched_other=""
if (( ${#AGENT_MEMORY_ROOTS[@]} > 0 )); then
  for _root in "${AGENT_MEMORY_ROOTS[@]}"; do
    for _sub in projects shared decisions; do
      [[ -d "$_root/$_sub" ]] || continue
      while IFS= read -r _f; do
        [[ -n "$_f" ]] && touched_other+="$_f"$'\n'
      done < <(find "$_root/$_sub" -type f -name '*.md' -mtime -1 2>/dev/null)
    done
  done
fi
touched_other=$(printf '%s' "$touched_other" | sed '/^$/d' | sort -u)
other_count=$(printf '%s\n' "$touched_other" | grep -c '[^[:space:]]' || true)
other_count=${other_count:-0}

# PreCompact raw envelopes touched in last 24h. Issue #582: hooks/pre-compact.py
# routes through `bridge-memory.py capture`, which writes schema_version=1
# JSON envelopes to <agent_home>/raw/captures/inbox/. Until this loop existed,
# those captures landed on disk and never reached `[librarian-ingest]`.
# scripts/librarian-process-ingest.py::load_envelope already reads .json
# captures and is idempotent (rejects duplicates by hash), so files inside the
# 24h window can be re-enqueued safely across overlapping daily runs.
#
# Each AGENT_MEMORY_ROOTS entry has the shape `<agent_home>/memory`, so the
# agent home root is the parent directory; the raw inbox lives one level over
# at `<agent_home>/raw/captures/inbox`. Reusing the existing roots keeps both
# the legacy and v2 enumeration paths in sync without inventing a new resolver.
#
# Issue #583 Track C: AGENT_MEMORY_ROOTS is already filtered to exclude
# linux-user-isolated agents (the deny-list runs during root construction
# above), so this loop transparently inherits the skip. The raw inbox under
# an isolated agent's `<agent_home>/raw/captures/inbox` is never stat'd for
# the same reason its `<agent_home>/memory/...` is never stat'd: the deny-
# list short-circuits before either path is reached. A skipped agent
# therefore contributes ONE skip line to the audit log (not two — memory
# and raw are deduped through the shared roots array).
# Same empty-array guard as the research/other walks: every active agent
# may legitimately be linux-user-isolated, leaving AGENT_MEMORY_ROOTS empty.
touched_raw=""
if (( ${#AGENT_MEMORY_ROOTS[@]} > 0 )); then
  for _root in "${AGENT_MEMORY_ROOTS[@]}"; do
    _agent_home_dir="$(dirname -- "$_root")"
    _raw_inbox="$_agent_home_dir/raw/captures/inbox"
    [[ -d "$_raw_inbox" ]] || continue
    while IFS= read -r _f; do
      [[ -n "$_f" ]] && touched_raw+="$_f"$'\n'
    done < <(find "$_raw_inbox" -type f \( -name '*.json' -o -name '*.md' \) -mtime -1 2>/dev/null)
  done
fi
touched_raw=$(printf '%s' "$touched_raw" | sed '/^$/d' | sort -u)
raw_count=$(printf '%s\n' "$touched_raw" | grep -c '[^[:space:]]' || true)
raw_count=${raw_count:-0}

non_daily_total=$(( research_count + other_count + raw_count ))

# Audit log — always written.
{
  echo "# Wiki Daily Ingest Queue — $DATE"
  echo ""
  echo "## Lane A (daily byte-replica copy, no librarian)"
  echo ""
  echo "$copy_summary"
  if [ "$copy_rc" -ne 0 ]; then
    echo ""
    echo "**Lane A exit code:** $copy_rc — see stderr above."
  fi
  echo ""
  echo "## Lane B (non-daily captures for librarian)"
  echo ""
  echo "### Research files ($research_count)"
  echo "$touched_research" | while read -r f; do [ -n "$f" ] && echo "- $f"; done
  echo ""
  echo "### Other projects/shared/decisions ($other_count)"
  echo "$touched_other" | while read -r f; do [ -n "$f" ] && echo "- $f"; done
  echo ""
  echo "### Raw envelopes ($raw_count)"
  echo "$touched_raw" | while read -r f; do [ -n "$f" ] && echo "- $f"; done
  echo ""
  # Issue #583 Track C: explicit listing of agents whose private root was
  # not enumerated. Stable reason string — keep in sync with
  # $LANE_B_ISOLATED_SKIP_REASON above. A skipped agent is recorded once
  # here regardless of whether the gate fired against the memory walk or
  # the raw envelope walk; both share AGENT_MEMORY_ROOTS as their input.
  echo "### Skipped (isolated private root) ($skipped_isolated_count)"
  if (( skipped_isolated_count > 0 )); then
    for _skipped in "${SKIPPED_ISOLATED_AGENTS[@]}"; do
      echo "- $_skipped — reason: $LANE_B_ISOLATED_SKIP_REASON"
    done
  fi
} > "$LOG"

# Queue librarian task only for non-daily work. Lane A already handled
# daily notes and did not produce a task. Falls back to the admin agent
# (default: patch) only if the librarian is not provisioned on this
# install — treated as an install incompleteness signal, not a routine
# routing choice.
if [ "$non_daily_total" -gt 0 ]; then
  target="$BRIDGE_ADMIN_AGENT"
  if "$BRIDGE_AGB" agent show librarian >/dev/null 2>&1; then
    target="librarian"
  fi
  "$BRIDGE_AGB" task create --to "$target" --priority normal --from "$BRIDGE_ADMIN_AGENT" \
    --title "[librarian-ingest] $non_daily_total 파일 ingest 필요 — $DATE" \
    --body-file "$LOG" >/dev/null 2>&1 || true
fi

# Advance the watermark only when Lane A reported errors=0 AND the copy
# subprocess exited cleanly. Any failure leaves the previous watermark in
# place so the next run retries the same window.
if [ "$copy_rc" -eq 0 ] && [ "$copy_errors" = "0" ]; then
  write_watermark_atomic "$DATE" || true
fi

# Stdout summary. The skipped-isolated counter is always present so log
# consumers can grep on it without conditional lookups; the agent list
# uses the LANE_B_ISOLATED_SKIP_REASON literal so the grep contract is
# stable across both surfaces (audit log + stdout). The raw=$raw_count
# field is the #585 raw envelope counter and stays adjacent to the other
# Lane B lane counters.
skipped_isolated_csv=""
if (( skipped_isolated_count > 0 )); then
  skipped_isolated_csv="$(IFS=,; echo "${SKIPPED_ISOLATED_AGENTS[*]}")"
fi
echo "wiki-daily-ingest: date=$DATE since=$YESTERDAY lane-a ${copy_summary} lane-b research=$research_count other=$other_count raw=$raw_count total=$non_daily_total skipped-isolated=$skipped_isolated_count skipped-isolated-reason=$LANE_B_ISOLATED_SKIP_REASON skipped-isolated-agents=${skipped_isolated_csv:-none} log=$LOG"
