#!/usr/bin/env bash
# bootstrap-memory-system.sh — idempotent provisioner for the v0.4.0+
# wiki-graph automation stack: PreCompact hook + v2 hybrid index +
# dynamic librarian agent + nine admin-owned crons (wiki-*,
# librarian-watchdog).
#
# Modes:
#   --apply   (default) : converge the install toward the target state.
#   --dry-run           : report intended actions, mutate nothing, exit 0.
#   --check             : assert fully converged; exit 1 on any drift.
#
# Re-runnable: the 2nd run must be a no-op. Each step hashes or probes the live
# state before mutating.
#
# All outputs under $BRIDGE_STATE_ROOT/bootstrap-memory/.
#
# IMPORTANT: this script targets a *downstream* reference install. Never
# commit to applying on production without review.

# Re-exec under bash 4+ if we got picked up by macOS's default /bin/bash (3.2),
# which lacks associative arrays. Mirrors the guard in bridge-lib.sh so this
# script stays runnable standalone without sourcing the bridge library.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for bridge_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [[ -n "$bridge_candidate_bash" && -x "$bridge_candidate_bash" ]] || continue
    if "$bridge_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$bridge_candidate_bash" "$0" "$@"
    fi
  done

  echo "[bootstrap-memory] Agent Bridge requires Bash 4+ (current: ${BASH_VERSION:-unknown}). Install homebrew bash or set PATH accordingly." >&2
  exit 1
fi

set -euo pipefail

# -----------------------------------------------------------------------------
# locate bridge-home and load _common helpers
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BRIDGE_HOME:=$HOME/.agent-bridge}"
export BRIDGE_HOME

# Admin agent used as cron owner + escalation target. Defaults to
# `patch` to preserve the reference-install convention, but any install
# that names its admin differently can export BRIDGE_ADMIN_AGENT.
# If no admin env is set at invocation time, source the agent roster to
# pick up BRIDGE_ADMIN_AGENT_ID persisted by `agb setup admin`. Operator-
# shell bootstrap runs then resolve the real admin name even when the
# calling shell has not inherited the env from a bridge-managed session.
# The roster files are plain shell that set `BRIDGE_ADMIN_AGENT_ID="..."`.
if [[ -z "${BRIDGE_ADMIN_AGENT:-}${BRIDGE_ADMIN_AGENT_ID:-}" ]]; then
  # Roster files assume bridge-lib.sh is already loaded (they call
  # `bridge_add_agent_id_if_missing` and write into declared -A arrays).
  # We don't need any of that — only the BRIDGE_ADMIN_AGENT_ID line.
  # Extract it without executing the rest of the file.
  for _roster in "$BRIDGE_HOME/agent-roster.local.sh" "$BRIDGE_HOME/agent-roster.sh"; do
    if [[ -r "$_roster" ]]; then
      # Issue #1399: on an admin-less roster the `grep` finds no
      # BRIDGE_ADMIN_AGENT_ID line and exits 1. Under `set -euo pipefail`
      # that non-zero rc propagates as the pipeline's status and aborts
      # the script — so "no admin" must be treated as an empty result, not
      # a fatal error. Guard ONLY the legitimately-empty grep with a brace
      # group + `|| true`; do NOT blanket the whole pipeline, so a real
      # failure in `head`/`sed` (e.g. a broken sed expression) still
      # surfaces under pipefail rather than being silently masked.
      _admin_line="$({ grep -E '^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=' "$_roster" || true; } | head -n 1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=//; s/^"([^"]*)".*/\1/; s/^'"'"'([^'"'"']*)'"'"'.*/\1/; s/[[:space:]]*#.*$//')"
      if [[ -n "$_admin_line" ]]; then
        BRIDGE_ADMIN_AGENT_ID="$_admin_line"
        export BRIDGE_ADMIN_AGENT_ID
        break
      fi
    fi
  done
fi

: "${BRIDGE_ADMIN_AGENT:=${BRIDGE_ADMIN_AGENT_ID:-patch}}"
export BRIDGE_ADMIN_AGENT
export BRIDGE_ADMIN_AGENT_ID="${BRIDGE_ADMIN_AGENT_ID:-$BRIDGE_ADMIN_AGENT}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/_common.sh"

# Issue #1222: step_rebuild_one's apply path writes into the agent's
# memory/ dir, which under linux-user isolation is owned by the iso UID
# with group `ab-agent-<slug>` mode 2770. The controller is intentionally
# NOT in that group (per the v2 contract), so direct `rm -f`, `mv -f`,
# and `mkdir -p` of `$home/memory/*.rebuilding-*` and the swap into the
# final `index.sqlite` slot all fail with `Permission denied`. The fix
# (H.2 / codex r1 preferred) drops to the iso UID via
# `bridge_isolation_run_as_agent_user_via_bash` for the *entire* rebuild
# block — tmp create, python rebuild-index, validate, mkdir, mv — so no
# controller-side write crosses the boundary.
#
# Sourcing bridge-lib.sh pulls in bridge-agents.sh (for
# bridge_agent_linux_user_isolation_effective + bridge_agent_os_user)
# and bridge-isolation-helpers.sh (for
# bridge_isolation_run_as_agent_user_via_bash). The source is wrapped
# in a guard so a stripped install (or smoke harness that uses a
# minimal $BRIDGE_HOME tree) can still run the non-iso path —
# `_BRIDGE_ISO_HELPERS_LOADED` records whether the helper is available.
#
# IMPORTANT (codex r1 BLOCKING finding): merely sourcing bridge-lib.sh
# does NOT populate the per-agent assoc arrays
# (`BRIDGE_AGENT_ISOLATION_MODE`, `BRIDGE_AGENT_OS_USER`, …) that
# `bridge_agent_linux_user_isolation_effective` reads. The roster files
# (`$BRIDGE_HOME/agent-roster.sh` + `agent-roster.local.sh`) are loaded
# by `bridge_load_roster` from `lib/bridge-state.sh`, which then drives
# the arrays. Without that call, every iso v2 agent's predicate returns
# 1 ("not isolated") in the bootstrap shell and `step_rebuild_one`
# falls back to the legacy controller-direct path — which is exactly
# the codepath that hits `rm: Permission denied` on `2770 ab-agent-*`
# memory/ trees (#1222). So: source, verify helpers AND the roster
# loader are present, then actually load. Helpers-only is a bug.
_BRIDGE_ISO_HELPERS_LOADED=0
if [[ -r "$SCRIPT_DIR/bridge-lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/bridge-lib.sh" || true
  if declare -F bridge_isolation_run_as_agent_user_via_bash >/dev/null 2>&1 \
      && declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && declare -F bridge_load_roster >/dev/null 2>&1 \
      && bridge_load_roster >/dev/null 2>&1; then
    _BRIDGE_ISO_HELPERS_LOADED=1
  fi
fi

# -----------------------------------------------------------------------------
# arg parsing
# -----------------------------------------------------------------------------
MODE="apply"
INDEX_STALE_DAYS=7
TARGET_AGENT=""
# Issue #322 Track C: opt-in historical backfill of memory-daily harvests.
# Default empty = OFF. When set, must be a strict integer in [1, 90].
# Active only in --apply mode; ignored under --dry-run / --check (those modes
# already report what apply would do; the backfill is purely an apply-time
# side-effect that piggy-backs on `harvest-daily --missing-only`).
BACKFILL_HISTORY_DAYS=""
# Issue #729: opt-in jitter-regression remediation. Default OFF. Effective
# only with --apply. When the live `memory-daily-<agent>` crons have
# regressed to a single shared minute (legacy installs, pre-jitter
# bootstraps, or some lost-during-upgrade event), this flag instructs
# step_memory_daily_cron_one to overwrite the regressed schedule with the
# canonical jittered minute via `agb cron update`. Without it, conflict
# rows surface a hint suggesting --re-jitter so the operator opts in.
RE_JITTER=0
# Issue #2090: opt-in convergence of same-family crons whose live schedule
# has drifted from the cadence shipped in the current version. Default OFF.
# Effective only with --apply. When a wiki-* or memory-daily-<agent> cron
# exists on a DIFFERENT schedule/tz than the shipped default, bootstrap
# normally refuses to overwrite it (records `conflict`, notes drift) so an
# operator's deliberate schedule is never clobbered silently. With
# --reconcile the operator explicitly opts in to adopt the shipped default:
# each drifted same-family job is updated in place via `agb cron update`
# (verb-atomic — no delete/recreate window) and the `existing → want` diff
# is surfaced. Without it, the conflict rows still print the same diff so
# the operator can see what --reconcile would change before opting in.
RECONCILE=0
while (( $# > 0 )); do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --check)   MODE="check" ;;
    --apply)   MODE="apply" ;;
    --agent)   TARGET_AGENT="${2:-}"; shift ;;
    --stale-days) INDEX_STALE_DAYS="${2:-7}"; shift ;;
    --backfill-history)
      BACKFILL_HISTORY_DAYS="${2:-}"
      shift
      ;;
    --re-jitter) RE_JITTER=1 ;;
    --reconcile) RECONCILE=1 ;;
    -h|--help)
      cat <<EOF
usage: $(basename "$0") [--apply|--dry-run|--check] [--agent <name>] [--stale-days N] [--backfill-history N] [--re-jitter] [--reconcile]

Steps:
  1. PreCompact hook per active claude agent.
  2. v2 hybrid index rebuild per active claude agent (skip if fresh).
  3. Ensure the dynamic 'librarian' agent is provisioned.
  4. Register the wiki-* + librarian-watchdog cron set on the admin
     agent (default: 'patch'; override with BRIDGE_ADMIN_AGENT env).
  5. (apply only, opt-in) When --backfill-history N is supplied, run
     \`bridge-memory.py harvest-daily --from \$(today-N) --to \$(today-1)
     --agent <agent> --missing-only\` for each registered claude agent.
     N is an integer in [1, 90]; default is OFF (no historical backfill).
     Re-running with the same N is a no-op because --missing-only skips
     dates that already have a sidecar manifest. Issue #322 Track C.

Flags:
  --re-jitter   (apply only) Overwrite memory-daily-<agent> crons whose
                schedule has regressed to a same-minute fan-out (e.g.
                everyone fires at 0 3 * * *). Re-applies the canonical
                jittered minute computed from the agent name. Default
                OFF — without it, conflict rows surface a hint instead
                of mutating the cron. Issue #729.
  --reconcile   (apply only) Adopt the shipped default cadence for any
                wiki-* or memory-daily-<agent> cron whose live schedule/tz
                has drifted from the current default. Each drifted job is
                updated in place (\`agb cron update\`, verb-atomic) and the
                \`existing → want\` diff is printed. Default OFF — without
                it a same-family job on a different schedule is left
                untouched and only recorded as a conflict (with the same
                diff), so nothing changes unless you opt in. Broader than
                --re-jitter, which only remediates the same-minute
                memory-daily fan-out. Issue #2090.

JSON report written to \$BRIDGE_STATE_ROOT/bootstrap-memory/report-<stamp>.json
The report includes a top-level \`memory_daily_simultaneous_fire_max\`
field — the largest count of memory-daily-<agent> crons sharing a single
wall-clock minute observed during the run. > 1 indicates a fan-out risk
and recommends a --re-jitter pass.
EOF
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Issue #729: --re-jitter is meaningful only in --apply mode. Surface the
# misuse early rather than silently ignoring the flag.
if (( RE_JITTER == 1 )) && [[ "$MODE" != "apply" ]]; then
  echo "bootstrap-memory: --re-jitter requires --apply (current mode: $MODE)" >&2
  exit 2
fi

# Issue #2090: --reconcile mutates live crons, so like --re-jitter it is
# meaningful only in --apply mode. --dry-run / --check already surface the
# drift diff in their conflict rows (read-only), so gating the mutation flag
# to --apply keeps those modes purely reportative.
if (( RECONCILE == 1 )) && [[ "$MODE" != "apply" ]]; then
  echo "bootstrap-memory: --reconcile requires --apply (current mode: $MODE)" >&2
  exit 2
fi

# Issue #1263 (v0.15.0-beta4 Lane J): wiki-graph + librarian automation
# stack is opt-in. The default is OFF on fresh installs; existing
# installs that have already been provisioned (any prior
# `report-*.json` under `$BRIDGE_STATE_ROOT/bootstrap-memory/`) stay
# ON for back-compat. Operators can force the decision via the
# `BRIDGE_WIKI_GRAPH_ENABLED` env var:
#   - "1" / "true" / "yes" → run normally
#   - "0" / "false" / "no" → skip with advisory (exit 0)
#   - unset                → infer from state (existing report → on,
#                            fresh install → off + advisory)
# `--check` and `--dry-run` always proceed (they are read-only / report-
# generating verbs that the operator needs to inspect drift), so the
# gate only short-circuits `--apply`.
_wgraph_enabled_env="${BRIDGE_WIKI_GRAPH_ENABLED:-}"
_wgraph_should_skip=0
_wgraph_skip_reason=""
if [[ "$MODE" == "apply" ]]; then
  case "${_wgraph_enabled_env,,}" in
    1|true|yes|on)
      :  # explicit opt-in, run normally
      ;;
    0|false|no|off)
      _wgraph_should_skip=1
      _wgraph_skip_reason="BRIDGE_WIKI_GRAPH_ENABLED=$_wgraph_enabled_env (operator opt-out)"
      ;;
    "")
      # Infer from state. Any prior report file = previously provisioned
      # = stay on. No prior report = fresh install = default off.
      if compgen -G "$BRIDGE_STATE_ROOT/bootstrap-memory/report-*.json" >/dev/null 2>&1; then
        :  # back-compat: previously provisioned install stays on
      else
        _wgraph_should_skip=1
        _wgraph_skip_reason="fresh install (no prior bootstrap-memory report); wiki-graph + librarian default-off"
      fi
      ;;
    *)
      echo "bootstrap-memory: BRIDGE_WIKI_GRAPH_ENABLED must be one of 1/0/true/false/yes/no/on/off (got: $_wgraph_enabled_env)" >&2
      exit 2
      ;;
  esac
fi
if (( _wgraph_should_skip == 1 )); then
  # Routing: advisory to stderr (operator-visible), structured marker to
  # stdout so JSON consumers / wrappers can detect the skip without
  # parsing localized text. Exit 0 — this is a no-op success.
  echo "[bootstrap-memory] wiki-graph + librarian provisioning skipped: $_wgraph_skip_reason" >&2
  echo "[bootstrap-memory] re-run with BRIDGE_WIKI_GRAPH_ENABLED=1 to activate." >&2
  printf 'wiki_graph_skipped=1\nwiki_graph_skip_reason=%s\n' "$_wgraph_skip_reason"
  exit 0
fi

# Validate --backfill-history once, up-front, so a bad value fails fast
# before any provisioning side-effects. Empty (unset) is the default; only
# values that survive validation participate in the backfill loop.
if [[ -n "$BACKFILL_HISTORY_DAYS" ]]; then
  if ! [[ "$BACKFILL_HISTORY_DAYS" =~ ^[0-9]+$ ]]; then
    echo "bootstrap-memory: --backfill-history requires a non-negative integer (got: $BACKFILL_HISTORY_DAYS)" >&2
    exit 2
  fi
  if (( BACKFILL_HISTORY_DAYS < 1 || BACKFILL_HISTORY_DAYS > 90 )); then
    echo "bootstrap-memory: --backfill-history must be in [1, 90] days (got: $BACKFILL_HISTORY_DAYS); 0 is treated as OFF — omit the flag instead" >&2
    exit 2
  fi
fi

# -----------------------------------------------------------------------------
# output / report setup
# -----------------------------------------------------------------------------
REPORT_DIR="$BRIDGE_STATE_ROOT/bootstrap-memory"
mkdir -p "$REPORT_DIR"
STAMP="$(abs_stamp)"
REPORT="$REPORT_DIR/report-$STAMP.json"
TMP_REPORT="$REPORT.partial"

# Per-agent step records: "<agent>\t<step>\t<status>\t<note>"
RECORD_FILE="$(mktemp -t bootstrap-memory.XXXXXX)"
trap 'rm -f "$RECORD_FILE" "$TMP_REPORT" 2>/dev/null || true' EXIT

record() {
  # record <agent> <step> <status> <note>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$RECORD_FILE"
}

log() { printf '[%s] %s\n' "$MODE" "$*"; }

DRIFT=0
note_drift() { DRIFT=$((DRIFT + 1)); }

# Issue #729: track the largest count of memory-daily-<agent> crons sharing a
# single wall-clock minute. Populated by prepopulate_memory_daily_minute_counts
# (a pre-pass over the static-agent set) BEFORE the per-agent registration
# loop runs, so the count reflects the full pre-fix state — both the report
# field and the re-jitter eligibility gate get a consistent picture rather
# than a partial mid-loop tally. Healthy install: max == 1 (each agent's
# minute is unique under the cksum-mod-60 jitter).
MEMORY_DAILY_SIMULTANEOUS_FIRE_MAX=0
# Per-minute count of memory-daily-<agent> crons across all static agents.
# Codex r2: the re-jitter eligibility gate consults
# MEMORY_DAILY_MINUTE_COUNTS["$minute"] to require ≥2 colliding agents
# before overwriting, so an isolated operator override at e.g. minute 0
# is preserved.
declare -A MEMORY_DAILY_MINUTE_COUNTS

# -----------------------------------------------------------------------------
# load agents
# -----------------------------------------------------------------------------
AGENT_LIST_TMP="$(mktemp -t bootstrap-memory-agents.XXXXXX)"
list_active_claude_agents > "$AGENT_LIST_TMP"
if [[ -n "$TARGET_AGENT" ]]; then
  grep -E "^${TARGET_AGENT}"$'\t' "$AGENT_LIST_TMP" > "$AGENT_LIST_TMP.filt" || true
  mv "$AGENT_LIST_TMP.filt" "$AGENT_LIST_TMP"
fi
AGENT_COUNT=$(wc -l < "$AGENT_LIST_TMP" | tr -d ' ')
log "active claude agents: $AGENT_COUNT"

# Issue #376: memory-daily-<agent> crons require a stable per-agent home
# (~/.agent-bridge/agents/<n>/) which only static roster entries have. Build
# a separate static-only set so step_memory_daily_cron_one is gated on it
# without changing what hook/rebuild see.
STATIC_AGENT_LIST_TMP="$(mktemp -t bootstrap-memory-static-agents.XXXXXX)"
list_active_static_claude_agents > "$STATIC_AGENT_LIST_TMP"
if [[ -n "$TARGET_AGENT" ]]; then
  grep -E "^${TARGET_AGENT}"$'\t' "$STATIC_AGENT_LIST_TMP" > "$STATIC_AGENT_LIST_TMP.filt" || true
  mv "$STATIC_AGENT_LIST_TMP.filt" "$STATIC_AGENT_LIST_TMP"
fi
declare -A STATIC_AGENT_SET
while IFS=$'\t' read -r _sa _sh; do
  [[ -z "$_sa" ]] && continue
  STATIC_AGENT_SET["$_sa"]=1
done < "$STATIC_AGENT_LIST_TMP"

# -----------------------------------------------------------------------------
# step 1: PreCompact hook
# -----------------------------------------------------------------------------
hook_bootstrap_backup_tag="bootstrap-$STAMP"

step_hook_one() {
  local agent="$1" home="$2"
  local settings="$home/.claude/settings.json"

  if [[ ! -f "$home/CLAUDE.md" ]]; then
    record "$agent" "hook" "skip-no-claude-md" "no CLAUDE.md"
    return 0
  fi
  if [[ ! -f "$settings" ]]; then
    record "$agent" "hook" "skip-no-settings" "no settings.json"
    return 0
  fi

  # Status first: if PreCompact is already wired, skip silently.
  if "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-hooks.py" status-pre-compact-hook \
        --workdir "$home" \
        --bridge-home "$BRIDGE_HOME" \
        --python-bin "$BRIDGE_PYTHON" \
        --settings-file "$settings" \
        >/dev/null 2>&1; then
    record "$agent" "hook" "already-installed" ""
    return 0
  fi

  if [[ "$MODE" == "check" ]]; then
    record "$agent" "hook" "drift-missing" ""
    note_drift
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "$agent" "hook" "would-install" ""
    return 0
  fi

  # apply path: backup once per agent, then install.
  local bak="$settings.bak-$hook_bootstrap_backup_tag"
  if [[ ! -f "$bak" ]]; then
    cp "$settings" "$bak"
  fi
  if "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-hooks.py" ensure-pre-compact-hook \
        --workdir "$home" \
        --bridge-home "$BRIDGE_HOME" \
        --python-bin "$BRIDGE_PYTHON" \
        --settings-file "$settings" \
        >/dev/null 2>&1; then
    record "$agent" "hook" "installed" "bak=$bak"
  else
    record "$agent" "hook" "install-failed" ""
  fi
}

# -----------------------------------------------------------------------------
# step 2: v2 hybrid rebuild-index
# -----------------------------------------------------------------------------
step_rebuild_one() {
  local agent="$1" home="$2"
  local db="$home/memory/index.sqlite"

  # Fresh check: if db exists AND index_kind==v2 AND chunks>0 AND
  # indexed_at within $INDEX_STALE_DAYS → skip.
  if [[ -f "$db" ]]; then
    local fresh_status
    fresh_status=$("$BRIDGE_PYTHON" - "$db" "$INDEX_STALE_DAYS" <<'PY'
import sqlite3, sys, datetime
db = sys.argv[1]
stale_days = int(sys.argv[2])
try:
    con = sqlite3.connect(db)
    cur = con.cursor()
    cur.execute("SELECT value FROM meta WHERE key='index_kind'")
    r = cur.fetchone()
    kind = r[0] if r else ""
    cur.execute("SELECT COUNT(*) FROM chunks")
    chunks = cur.fetchone()[0]
    cur.execute("SELECT value FROM meta WHERE key='indexed_at'")
    r = cur.fetchone()
    indexed_at = r[0] if r else ""
    con.close()
except Exception as e:
    print(f"missing:{e}")
    sys.exit(0)
if kind != "bridge-wiki-hybrid-v2":
    print(f"wrong-kind:{kind}")
    sys.exit(0)
if chunks <= 0:
    print("empty")
    sys.exit(0)
try:
    ts = datetime.datetime.fromisoformat(indexed_at.replace("Z","+00:00")) if indexed_at else None
except Exception:
    ts = None
if ts is None:
    print("no-ts")
    sys.exit(0)
age = datetime.datetime.now(datetime.timezone.utc) - (ts if ts.tzinfo else ts.replace(tzinfo=datetime.timezone.utc))
if age.days < stale_days:
    print(f"fresh:{age.days}d")
else:
    print(f"stale:{age.days}d")
PY
)
    case "$fresh_status" in
      fresh:*)
        record "$agent" "index" "already-fresh" "$fresh_status"
        return 0
        ;;
    esac
  fi

  if [[ "$MODE" == "check" ]]; then
    record "$agent" "index" "drift-stale-or-missing" ""
    note_drift
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "$agent" "index" "would-rebuild" ""
    return 0
  fi

  # apply: sequential rebuild via the same wiki-v2-rebuild logic but
  # in-process (no cron). We reuse bridge-memory.py directly but with the
  # tmp+swap pattern.
  local tmp_db="$db.rebuilding-$STAMP"

  # Issue #1222: under linux-user isolation, the controller cannot write
  # into the iso-owned `memory/` dir (`2770 agent-bridge-<slug>:ab-agent-<slug>`).
  # The whole rebuild/publish block — `rm -f tmp_db`, `bridge-memory.py
  # rebuild-index --db-path tmp_db`, the python validate, `mkdir -p`, and
  # the final `mv -f tmp_db db` — touches files inside that dir. Wrapping
  # only the leading `rm -f` (or only the trailing `mv -f`) would still
  # fail the others. So we either run the entire block under the iso UID
  # (H.2 — preferred when isolated + sudo OK) or run it controller-direct
  # (legacy non-isolated path).
  local _iso_isolated=0
  if (( _BRIDGE_ISO_HELPERS_LOADED == 1 )) \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    _iso_isolated=1
  fi

  if (( _iso_isolated == 1 )); then
    # Inline rebuild script run as the iso UID via the sudoers `bash`
    # allowlist. Self-contained — does NOT source bridge-lib.sh inside
    # the isolated UID (sudoers allowlist is `bash` + `tmux` only).
    #
    # Args bound inside the script:
    #   $1 = BRIDGE_PYTHON, $2 = BRIDGE_HOME, $3 = agent, $4 = home,
    #   $5 = shared_root, $6 = db, $7 = tmp_db
    #
    # Script exit codes (all ≥ 10 so the wrapper's +2 shift on rc<3 cannot
    # collide with the wrapper's own 0/1/2 pre-flight band):
    #   0  — full rebuild + validate + swap succeeded
    #   10 — `rebuild-index` invocation failed
    #   11 — validate-failed (rebuild produced a wrong/empty DB);
    #        script removes tmp_db and exits
    #   12 — pre-rebuild tmp_db unlink failed (e.g. ACL drift inside
    #        the iso UID itself — surface as drift, not silent continue)
    #   13 — mkdir of memory/ parent failed
    #   14 — final mv tmp_db -> db failed
    #   15 — mktemp for the validate harness failed inside iso-owned tmp
    #
    # Footgun #11 (heredoc-stdin deadlock): no `<<EOF` / `<<<` / `<<'PY'`
    # anywhere in this body. The body is a single-quoted bash string so
    # $variables resolve only inside the sudo'd bash. The python harness
    # writes its source to a tmp file inside iso-owned tmp first, then
    # runs `python3 -- <tmp>`; that avoids feeding heredoc stdin into
    # the sqlite-validate subprocess.
    local iso_rebuild_script
    iso_rebuild_script='
bridge_python="$1"
bridge_home="$2"
agent="$3"
home="$4"
shared_root="$5"
db="$6"
tmp_db="$7"

# Phase 1: clear stale tmp DB. Failure here means the iso UID itself
# cannot unlink (true ACL/mode drift, not the cross-boundary case the
# fix targets) — surface as exit 12 so the caller records a drift row.
if [[ -e "$tmp_db" ]] && ! rm -f "$tmp_db"; then
  exit 12
fi

# Phase 2: run rebuild-index. Cap with timeout when available.
rebuild_rc=0
if command -v timeout >/dev/null 2>&1; then
  timeout 900 "$bridge_python" "$bridge_home/bridge-memory.py" rebuild-index \
    --agent "$agent" --home "$home" \
    --bridge-home "$bridge_home" \
    --index-kind bridge-wiki-hybrid-v2 \
    --shared-root "$shared_root" \
    --db-path "$tmp_db" \
    --json \
    >/dev/null 2>&1 || rebuild_rc=$?
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout 900 "$bridge_python" "$bridge_home/bridge-memory.py" rebuild-index \
    --agent "$agent" --home "$home" \
    --bridge-home "$bridge_home" \
    --index-kind bridge-wiki-hybrid-v2 \
    --shared-root "$shared_root" \
    --db-path "$tmp_db" \
    --json \
    >/dev/null 2>&1 || rebuild_rc=$?
else
  "$bridge_python" "$bridge_home/bridge-memory.py" rebuild-index \
    --agent "$agent" --home "$home" \
    --bridge-home "$bridge_home" \
    --index-kind bridge-wiki-hybrid-v2 \
    --shared-root "$shared_root" \
    --db-path "$tmp_db" \
    --json \
    >/dev/null 2>&1 || rebuild_rc=$?
fi
if [[ "$rebuild_rc" -ne 0 ]]; then
  exit 10
fi

# Phase 3: validate tmp_db via a python harness staged in iso-owned
# tmp. Footgun #11: write the python source with printf first, then
# `python3 -- file`, NOT a heredoc into stdin.
tmp_validate_dir="$(dirname "$tmp_db")"
validate_py="$(mktemp "$tmp_validate_dir/.bridge-memory-validate.XXXXXX.py")" || exit 15
trap "rm -f \"$validate_py\" 2>/dev/null" EXIT INT TERM
{
  printf "%s\n" "import sqlite3, sys"
  printf "%s\n" "p = sys.argv[1]"
  printf "%s\n" "con = sqlite3.connect(p); cur = con.cursor()"
  printf "%s\n" "cur.execute(\"SELECT value FROM meta WHERE key=\x27index_kind\x27\")"
  printf "%s\n" "r = cur.fetchone()"
  printf "%s\n" "kind = r[0] if r else \"\""
  printf "%s\n" "cur.execute(\"SELECT COUNT(*) FROM chunks\")"
  printf "%s\n" "chunks = cur.fetchone()[0]"
  printf "%s\n" "con.close()"
  printf "%s\n" "sys.exit(0 if (kind == \"bridge-wiki-hybrid-v2\" and chunks > 0) else 1)"
} >"$validate_py"
if ! "$bridge_python" "$validate_py" "$tmp_db"; then
  rm -f "$tmp_db" 2>/dev/null
  exit 11
fi

# Phase 4: ensure memory/ parent dir exists.
if ! mkdir -p "$(dirname "$db")"; then
  exit 13
fi

# Phase 5: atomic swap.
if ! mv -f "$tmp_db" "$db"; then
  exit 14
fi
exit 0
'
    local iso_rc=0
    bridge_isolation_run_as_agent_user_via_bash "$agent" "$iso_rebuild_script" \
      "$BRIDGE_PYTHON" "$BRIDGE_HOME" "$agent" "$home" \
      "$BRIDGE_SHARED_ROOT" "$db" "$tmp_db" 2>/dev/null || iso_rc=$?
    # bridge_isolation_run_as_agent_user_via_bash returns:
    #   0    — script rc 0 (success)
    #   1    — pre-flight: agent not isolated (impossible here, we gated above)
    #   2    — pre-flight: sudo unavailable / no passwordless sudoers
    #   3..  — script rc band (rc<3 shifted +2; rc≥3 passthrough). The
    #          script's exit codes are pinned at ≥ 10 so the shift band
    #          never collides with the pre-flight band.
    case "$iso_rc" in
      0)
        record "$agent" "index" "rebuilt" ""
        return 0
        ;;
      1)
        # rc=1 here means the isolation gate inverted between our check
        # and the helper's own re-check. Treat as a roster/state
        # inconsistency drift signal rather than masking it.
        record "$agent" "index" "rebuild-failed" "iso-helper rc=1 (not isolated?)"
        return 0
        ;;
      2)
        # Sudo unavailable / passwordless sudoers missing. The iso v2
        # contract requires this — surface explicitly so the operator
        # can fix the sudoers gap instead of seeing a silent skip.
        record "$agent" "index" "rebuild-failed" "sudo-unavailable-for-iso-uid"
        return 0
        ;;
      10)
        record "$agent" "index" "rebuild-failed" ""
        return 0
        ;;
      11)
        record "$agent" "index" "validate-failed" ""
        return 0
        ;;
      12)
        # Pre-rebuild tmp_db unlink failed under iso UID itself. True
        # drift (ACL/mode regression inside the agent's own tree), not
        # the cross-boundary case this fix targets. Surface explicitly.
        record "$agent" "index" "rebuild-failed" "stale-tmp-unlink-failed-as-iso-uid"
        return 0
        ;;
      13)
        record "$agent" "index" "rebuild-failed" "memory-mkdir-failed-as-iso-uid"
        return 0
        ;;
      14)
        record "$agent" "index" "rebuild-failed" "mv-into-place-failed-as-iso-uid"
        return 0
        ;;
      15)
        record "$agent" "index" "rebuild-failed" "validate-harness-mktemp-failed"
        return 0
        ;;
      *)
        record "$agent" "index" "rebuild-failed" "iso-helper rc=$iso_rc"
        return 0
        ;;
    esac
  fi

  # Non-isolated (shared/legacy) path — keep the controller-direct
  # implementation unchanged. Mode 2770 doesn't apply here, so the same
  # rm/rebuild/validate/mkdir/mv sequence runs as the controller user.
  rm -f "$tmp_db"
  if ! run_with_timeout 900 "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" rebuild-index \
        --agent "$agent" --home "$home" \
        --bridge-home "$BRIDGE_HOME" \
        --index-kind bridge-wiki-hybrid-v2 \
        --shared-root "$BRIDGE_SHARED_ROOT" \
        --db-path "$tmp_db" \
        --json \
        >/dev/null 2>&1; then
    record "$agent" "index" "rebuild-failed" ""
    return 0
  fi
  if ! "$BRIDGE_PYTHON" - "$tmp_db" <<'PY'
import sqlite3, sys
p = sys.argv[1]
con = sqlite3.connect(p); cur = con.cursor()
cur.execute("SELECT value FROM meta WHERE key='index_kind'")
r = cur.fetchone()
kind = r[0] if r else ""
cur.execute("SELECT COUNT(*) FROM chunks")
chunks = cur.fetchone()[0]
con.close()
sys.exit(0 if (kind == "bridge-wiki-hybrid-v2" and chunks > 0) else 1)
PY
  then
    rm -f "$tmp_db"
    record "$agent" "index" "validate-failed" ""
    return 0
  fi
  mkdir -p "$(dirname "$db")"
  mv -f "$tmp_db" "$db"
  record "$agent" "index" "rebuilt" ""
}

# -----------------------------------------------------------------------------
# step 3: 5 wiki-* crons
# -----------------------------------------------------------------------------

# Canonical cron definitions — one source of truth. Title MUST match exactly
# for re-entrancy detection.
#
# NOTE: cron create uses --payload (not --command). The payload we ship is the
# path to the shell script plus a conventional "exec" hint that downstream
# cron runners interpret via `bash <payload>` (see bridge-cron-runner.py).
CRON_SPECS=(
  # title|schedule|tz|script
  "wiki-weekly-summarize|0 22 * * 0|Asia/Seoul|wiki-weekly-summarize.sh"
  "wiki-monthly-summarize|0 2 1 * *|Asia/Seoul|wiki-monthly-summarize.sh"
  "wiki-repair-links|0 5 * * 6|Asia/Seoul|wiki-repair-links.sh"
  "wiki-v2-rebuild|0 6 * * 6|Asia/Seoul|wiki-v2-rebuild.sh"
  "wiki-dedup-weekly|0 4 * * 0|Asia/Seoul|wiki-dedup-weekly.sh"
  # Daily-note two-lane ingest. Lane A (wiki-daily-copy.py) runs inside
  # the shell script; Lane B queues [librarian-ingest] for non-daily.
  # Scheduled at 06:00 to stagger 3 hours after the 03:00 memory-daily-*
  # fan-out. Co-scheduling at 03:00 produced a same-slot daemon-runner race
  # in which Lane A's wiki-daily-copy invocation observed files=0 every day
  # (issue #320 Track A). Existing 0.6.17 installs that already have this
  # cron at "0 3 * * *" are migrated to "0 6 * * *" by step_cron_one below.
  "wiki-daily-ingest|0 6 * * *|Asia/Seoul|wiki-daily-ingest.sh"
  # Weekly Lane A catch-all (issue #320 Track B). The daily wiki-daily-ingest
  # advances a watermark per #321; an agent that never processes its backfill
  # task in time can leave a daily note stranded. wiki-daily-copy.py --all
  # walks every date present under each agent's memory/ and re-copies any
  # missing wiki replica. Hash idempotency (wiki-daily-copy.py:93) keeps the
  # pass cheap on subsequent runs. Sundays 07:00 KST = one hour after the
  # 06:00 daily stagger so the two never overlap on the same wall minute.
  "wiki-copy-full-backfill|0 7 * * 0|Asia/Seoul|wiki-copy-full-backfill.sh"
  # L1 observation scanner. Populates shared/wiki/_index/mentions.db and
  # the distribution-report snapshot. Offset :17 misses top-of-hour cluster.
  "wiki-mention-scan|17 * * * *|Asia/Seoul|wiki-mention-scan.sh"
  # Librarian is dynamic (session-type=dynamic). Watchdog polls every
  # 10 min for [librarian-ingest] tasks and starts the agent on demand.
  "librarian-watchdog|*/10 * * * *|Asia/Seoul|librarian-watchdog.sh"
  # L2 candidacy. Weekly scan of mentions.db → candidate report +
  # [wiki-hub-candidates] task for the admin agent. Admin judgement
  # required before canonical hub authoring — automation stops here.
  "wiki-hub-audit|0 23 * * 4|Asia/Seoul|wiki-hub-audit.sh"
)

# Fetch existing crons once, parse JSON, cache a title→{schedule,tz,id} map.
EXISTING_CRONS_JSON="$(mktemp -t bootstrap-crons.XXXXXX.json)"
"$BRIDGE_AGB" cron list --agent "$BRIDGE_ADMIN_AGENT" --json 2>/dev/null >"$EXISTING_CRONS_JSON" || echo '[]' > "$EXISTING_CRONS_JSON"

cron_lookup() {
  # cron_lookup <title> — prints "id<TAB>schedule<TAB>tz<TAB>payload_preview"
  # or empty. payload_preview is the truncated payload string surfaced by
  # `agent-bridge cron list --json`; sufficient for the legacy
  # `[cron-dispatch]` prefix check used by the payload-migration branch in
  # step_cron_one.
  local title="$1"
  "$BRIDGE_PYTHON" - "$EXISTING_CRONS_JSON" "$title" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
title = sys.argv[2]
# `agent-bridge cron list --json` can emit either a bare list (older versions)
# or an object with a `jobs` key (current). Handle both shapes.
if isinstance(data, dict):
    jobs = data.get("jobs") or []
elif isinstance(data, list):
    jobs = data
else:
    jobs = []
for j in jobs:
    if not isinstance(j, dict):
        continue
    # `agent-bridge cron list --json` exposes the display name under
    # either `title` (older tooling) or `name` (current bridge-cron.sh).
    # Same story for schedule: `schedule` vs `schedule_text`. Try both.
    name = j.get("title") or j.get("name") or ""
    # Some installs also suffix a short uuid to the name (e.g. when two
    # jobs share the canonical title). Tolerate that by matching on the
    # stem before the first "-<hex>" or by exact match.
    def _matches(candidate: str, wanted: str) -> bool:
        if candidate == wanted:
            return True
        # Trim trailing "-<8 hex>" that some installs add after create.
        import re
        stem = re.sub(r"-[0-9a-f]{8,}$", "", candidate)
        return stem == wanted
    if _matches(name, title):
        sched = j.get("schedule") or j.get("schedule_text") or ""
        tz = j.get("tz") or j.get("timezone") or j.get("schedule_tz") or ""
        jid = j.get("id") or j.get("job_id") or ""
        # payload_preview is a ~100-char truncation; we only need the
        # leading prefix to gate the `[cron-dispatch]` migration branch.
        preview = j.get("payload_preview") or ""
        # Strip tab/newline so awk -F'\t' parsing in bash doesn't split
        # a multiline payload across columns.
        preview = preview.replace("\t", " ").replace("\n", " ").replace("\r", " ")
        print(f"{jid}\t{sched}\t{tz}\t{preview}")
        break
PY
}

step_cron_one() {
  local title="$1" sched="$2" tz="$3" script="$4"

  # The script lives under the bootstrap-shipped scripts/ dir. We resolve
  # the *installed* script path by convention: scripts are copied to
  # $BRIDGE_HOME/scripts/ when this bootstrap runs with --apply.
  local installed_script="$BRIDGE_HOME/scripts/$script"

  local found
  found="$(cron_lookup "$title" || true)"
  if [[ -n "$found" ]]; then
    local existing_id existing_sched existing_tz
    existing_id="$(printf '%s' "$found" | awk -F'\t' '{print $1}')"
    existing_sched="$(printf '%s' "$found" | awk -F'\t' '{print $2}')"
    existing_tz="$(printf '%s' "$found" | awk -F'\t' '{print $3}')"
    # Cron list may return several shapes across bridge-cron versions:
    #   "cron <expr>"                  e.g. "cron 0 22 * * 0"
    #   "<expr>"                       e.g. "0 22 * * 0"
    #   "cron <expr> <tz>"             e.g. "cron 0 22 * * 0 Asia/Seoul"
    #   "<expr> <tz>"                  e.g. "0 22 * * 0 Asia/Seoul"
    # Our expected value is the bare expression (no "cron " prefix, no tz).
    # Normalize both sides to a 5-field cron expression before comparing
    # AND separately compare the timezone — two identical 5-field
    # expressions in different TZs fire at completely different wall
    # times, so skipping tz can register `already` for the wrong slot.
    local norm_existing norm_expected trailing_tz
    norm_existing="${existing_sched#cron }"
    # Split the normalized string into (cron-expr, tz). Anything from
    # the 6th whitespace run onward is treated as the tz expression.
    trailing_tz="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(" ".join(parts[5:]))' "$norm_existing")"
    norm_existing="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(" ".join(parts[:5]))' "$norm_existing")"
    # Prefer the explicit `tz` column from cron_lookup; fall back to the
    # trailing-tz chunk of the schedule string.
    local effective_existing_tz="${existing_tz:-$trailing_tz}"
    norm_expected="$sched"
    if [[ "$norm_existing" == "$norm_expected" && "$effective_existing_tz" == "$tz" ]]; then
      # schedule + tz match. The payload may still be stale: older
      # bootstraps registered these jobs as `[cron-dispatch] ...`
      # natural-language briefs aimed at the admin agent, while the
      # canonical payload (line ~549 below) is `bash $installed_script`.
      # That mismatch wakes the admin's 1M-context Opus session every
      # firing just to invoke a deterministic shell script.
      #
      # Migrate stale managed payloads to match the canonical bootstrap
      # payload. Only fires when the existing payload starts with the
      # `[cron-dispatch]` prefix (operator-customized payloads keep their
      # text). Same 3-mode pattern as the wiki-daily-ingest schedule
      # migration block below.
      local existing_id existing_payload canonical_payload
      existing_id="$(printf '%s' "$found" | awk -F'\t' '{print $1}')"
      existing_payload="$(printf '%s' "$found" | awk -F'\t' '{print $4}')"
      canonical_payload="bash $installed_script"
      if [[ "$existing_payload" == "[cron-dispatch]"* ]]; then
        if [[ "$MODE" == "check" ]]; then
          record "$BRIDGE_ADMIN_AGENT" "cron:$title" "drift-payload-pending" \
            "id=$existing_id existing-prefix=[cron-dispatch] want=bash"
          note_drift
          return 0
        fi
        if [[ "$MODE" == "dry-run" ]]; then
          record "$BRIDGE_ADMIN_AGENT" "cron:$title" "would-migrate-payload" \
            "id=$existing_id [cron-dispatch] → bash $installed_script"
          return 0
        fi
        if [[ -z "$existing_id" ]]; then
          record "$BRIDGE_ADMIN_AGENT" "cron:$title" "migrate-payload-failed" \
            "no id from cron_lookup; existing-prefix=[cron-dispatch]"
          note_drift
          return 0
        fi
        if [[ ! -x "$installed_script" ]]; then
          # Script not yet installed (apply-step bootstrap_install_scripts
          # may run after this). Defer: leave the stale payload, emit
          # drift so the next run picks it up.
          record "$BRIDGE_ADMIN_AGENT" "cron:$title" "migrate-payload-deferred" \
            "id=$existing_id installed_script=$installed_script not-yet-executable"
          note_drift
          return 0
        fi
        if "$BRIDGE_AGB" cron update "$existing_id" \
              --payload "$canonical_payload" \
              >/dev/null 2>&1; then
          record "$BRIDGE_ADMIN_AGENT" "cron:$title" "migrated-payload" \
            "id=$existing_id [cron-dispatch] → bash"
        else
          record "$BRIDGE_ADMIN_AGENT" "cron:$title" "migrate-payload-failed" \
            "id=$existing_id"
          note_drift
        fi
        return 0
      fi
      record "$BRIDGE_ADMIN_AGENT" "cron:$title" "already-registered" "$existing_sched tz=$effective_existing_tz"
      return 0
    fi
    # Planned migration: wiki-daily-ingest moved from 0 3 * * * → 0 6 * * *
    # in #320 Track A. 0.6.17 installs already have it at the legacy slot;
    # treat that exact pair as a managed re-registration (not an operator
    # override) so the apply step can move it forward without manual edits.
    if [[ "$title" == "wiki-daily-ingest" \
          && "$norm_existing" == "0 3 * * *" \
          && "$norm_expected" == "0 6 * * *" \
          && "$effective_existing_tz" == "$tz" ]]; then
      local existing_id
      existing_id="$(printf '%s' "$found" | awk -F'\t' '{print $1}')"
      if [[ "$MODE" == "check" ]]; then
        record "$BRIDGE_ADMIN_AGENT" "cron:$title" "drift-migration-pending" \
          "existing=$existing_sched want=$sched tz=$tz reason=#320-trackA"
        note_drift
        return 0
      fi
      if [[ "$MODE" == "dry-run" ]]; then
        record "$BRIDGE_ADMIN_AGENT" "cron:$title" "would-migrate" \
          "id=$existing_id 0 3 * * * → 0 6 * * * tz=$tz"
        return 0
      fi
      if [[ -z "$existing_id" ]]; then
        record "$BRIDGE_ADMIN_AGENT" "cron:$title" "migrate-failed" \
          "no id from cron_lookup; existing=$existing_sched want=$sched"
        note_drift
        return 0
      fi
      if "$BRIDGE_AGB" cron update "$existing_id" \
            --schedule "$sched" \
            --tz "$tz" \
            >/dev/null 2>&1; then
        record "$BRIDGE_ADMIN_AGENT" "cron:$title" "migrated" \
          "id=$existing_id 0 3 * * * → 0 6 * * * tz=$tz reason=#320-trackA"
      else
        record "$BRIDGE_ADMIN_AGENT" "cron:$title" "migrate-failed" \
          "id=$existing_id 0 3 * * * → 0 6 * * *"
        note_drift
      fi
      return 0
    fi
    # Issue #2090 — opt-in convergence. The live schedule/tz has drifted
    # from the shipped default and none of the managed-migration branches
    # above matched (so this is either an operator override or a cadence
    # change we do not auto-migrate). With --reconcile the operator has
    # explicitly asked to adopt the shipped default: update the job in place
    # (verb-atomic; no delete/recreate window) and record the diff. Without
    # the flag we fall through to the non-destructive conflict path below,
    # which prints the same `existing → want` diff so the operator can see
    # what --reconcile would change before opting in.
    if [[ "$RECONCILE" == "1" && "$MODE" == "apply" && -n "$existing_id" ]]; then
      if "$BRIDGE_AGB" cron update "$existing_id" \
            --schedule "$sched" \
            --tz "$tz" \
            >/dev/null 2>&1; then
        record "$BRIDGE_ADMIN_AGENT" "cron:$title" "reconciled" \
          "id=$existing_id $existing_sched tz=$effective_existing_tz → $sched tz=$tz reason=#2090-adopt-default"
        printf '[%s] reconcile cron:%s — adopted shipped default: %s tz=%s → %s tz=%s\n' \
          "$MODE" "$title" "$existing_sched" "$effective_existing_tz" "$sched" "$tz"
        return 0
      fi
      record "$BRIDGE_ADMIN_AGENT" "cron:$title" "reconcile-failed" \
        "id=$existing_id $existing_sched tz=$effective_existing_tz → $sched tz=$tz"
      note_drift
      return 0
    fi
    local reconcile_hint=""
    if [[ "$RECONCILE" != "1" ]]; then
      reconcile_hint=" hint=run-with---reconcile-to-adopt-shipped-default"
    fi
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "conflict" "existing=$existing_sched tz=$effective_existing_tz want=$sched tz=$tz — refusing$reconcile_hint"
    note_drift
    return 0
  fi

  if [[ "$MODE" == "check" ]]; then
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "drift-missing" ""
    note_drift
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "would-register" "schedule=$sched tz=$tz"
    return 0
  fi

  # apply: copy script into $BRIDGE_HOME/scripts/ (idempotent) then register.
  # The operator is expected to have copied _common.sh as well (this bootstrap
  # does it below, before the loop runs — see bootstrap_install_scripts).
  if [[ ! -x "$installed_script" ]]; then
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "skip-script-missing" "$installed_script"
    note_drift
    return 0
  fi

  local payload
  payload="bash $installed_script"

  if "$BRIDGE_AGB" cron create --agent "$BRIDGE_ADMIN_AGENT" \
        --schedule "$sched" \
        --tz "$tz" \
        --title "$title" \
        --payload "$payload" \
        >/dev/null 2>&1; then
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "registered" "$sched $tz"
  else
    record "$BRIDGE_ADMIN_AGENT" "cron:$title" "register-failed" ""
  fi
}

# -----------------------------------------------------------------------------
# step 3b: per-agent memory-daily-<agent> cron
# -----------------------------------------------------------------------------
# Gate mirror of lib/bridge-agents.sh::bridge_agent_memory_daily_refresh_enabled.
# Bootstrap cannot source bridge-lib safely without pulling in the roster, so we
# approximate: the default is ON (matching the bash helper). An install that
# disables the refresh sets BRIDGE_AGENT_MEMORY_DAILY_REFRESH_<agent>=0 in the
# bootstrap env (every char that isn't a bash identifier char is normalised to
# `_` so the env name is valid — e.g. agent `agb-dev-claude` → env key
# `BRIDGE_AGENT_MEMORY_DAILY_REFRESH_agb_dev_claude`, agent `foo.bar` →
# `BRIDGE_AGENT_MEMORY_DAILY_REFRESH_foo_bar`), or writes
# BRIDGE_AGENT_MEMORY_DAILY_REFRESH[<agent>]=0 into the roster (which the daemon
# enforces at dispatch time regardless, using the raw agent id as the key).
memory_daily_gate_on() {
  local agent="$1"
  # `bridge_validate_agent_name` accepts `[A-Za-z0-9._-]+`, but bash identifiers
  # are restricted to `[A-Za-z_][A-Za-z0-9_]*`. Indirect expansion via `${!key}`
  # aborts with "invalid variable name" on hyphens, dots, or anything else
  # outside the identifier alphabet. Normalise *all* non-identifier chars to
  # `_` before building the env key — not just hyphens — so every valid agent
  # id is safely mappable.
  local safe_agent="${agent//[!A-Za-z0-9_]/_}"
  local key="BRIDGE_AGENT_MEMORY_DAILY_REFRESH_${safe_agent}"
  local val
  val="${!key:-}"
  val="${val,,}"
  case "$val" in
    0|false|no|off) return 1 ;;
  esac
  return 0
}

# Per-agent cron cache: populate on demand inside step_memory_daily_cron_one.
# Key = agent id; value = JSON blob (list or {jobs: []}) from
#   `$BRIDGE_AGB cron list --agent <agent> --json`.
declare -A MEMORY_DAILY_EXISTING_JSON

memory_daily_cron_lookup() {
  # memory_daily_cron_lookup <agent> <title> — prints "id<TAB>schedule<TAB>tz" or empty.
  local agent="$1"
  local title="$2"
  local blob="${MEMORY_DAILY_EXISTING_JSON[$agent]-}"
  local blob_file="$REPORT_DIR/.cron-list-$agent.json"
  if [[ -z "$blob" ]]; then
    blob="$("$BRIDGE_AGB" cron list --agent "$agent" --json 2>/dev/null || echo '[]')"
    MEMORY_DAILY_EXISTING_JSON[$agent]="$blob"
    printf '%s' "$blob" >"$blob_file"
  elif [[ ! -f "$blob_file" ]]; then
    printf '%s' "$blob" >"$blob_file"
  fi
  "$BRIDGE_PYTHON" - "$blob_file" "$title" <<'PY'
import json, re, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
title = sys.argv[2]
if isinstance(data, dict):
    jobs = data.get("jobs") or []
elif isinstance(data, list):
    jobs = data
else:
    jobs = []
for j in jobs:
    if not isinstance(j, dict):
        continue
    name = j.get("title") or j.get("name") or ""
    stem = re.sub(r"-[0-9a-f]{8,}$", "", name)
    if name == title or stem == title:
        sched = j.get("schedule") or j.get("schedule_text") or ""
        tz = j.get("tz") or j.get("timezone") or j.get("schedule_tz") or ""
        jid = j.get("id") or j.get("job_id") or ""
        print(f"{jid}\t{sched}\t{tz}")
        break
PY
}

# Issue #729 (codex r2): pre-populate MEMORY_DAILY_MINUTE_COUNTS by walking
# every static agent's memory-daily cron BEFORE the main registration loop.
# The eligibility gate in step_memory_daily_cron_one (re-jitter overwrite)
# needs the FULL pre-fix count of agents-per-minute to distinguish a real
# collapse (≥2 agents on the same minute) from a single operator override
# (one agent legitimately parked at e.g. minute 0). The previous incremental
# tally inside step_memory_daily_cron_one was order-dependent: the first
# agent at a colliding minute always saw count=1 and would have been
# wrongly classified as "single override" if the gate consulted it.
prepopulate_memory_daily_minute_counts() {
  local agent _home minute found norm_existing
  while IFS=$'\t' read -r agent _home; do
    [[ -z "$agent" ]] && continue
    [[ -z "${STATIC_AGENT_SET[$agent]:-}" ]] && continue
    found="$(memory_daily_cron_lookup "$agent" "memory-daily-$agent" || true)"
    [[ -z "$found" ]] && continue
    norm_existing="$(printf '%s' "$found" | awk -F'\t' '{print $2}')"
    norm_existing="${norm_existing#cron }"
    norm_existing="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(" ".join(parts[:5]))' "$norm_existing" 2>/dev/null || true)"
    [[ -z "$norm_existing" ]] && continue
    minute="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(parts[0] if parts else "")' "$norm_existing" 2>/dev/null || true)"
    [[ -z "$minute" ]] && continue
    MEMORY_DAILY_MINUTE_COUNTS["$minute"]=$(( ${MEMORY_DAILY_MINUTE_COUNTS["$minute"]:-0} + 1 ))
    if (( ${MEMORY_DAILY_MINUTE_COUNTS["$minute"]} > MEMORY_DAILY_SIMULTANEOUS_FIRE_MAX )); then
      MEMORY_DAILY_SIMULTANEOUS_FIRE_MAX="${MEMORY_DAILY_MINUTE_COUNTS["$minute"]}"
    fi
  done < "$AGENT_LIST_TMP"
}

step_memory_daily_cron_one() {
  local agent="$1"
  local title="memory-daily-$agent"
  # Auto-jitter the daily cron minute by a stable hash of the agent name so
  # that 20+ memory-daily crons don't fan out at the same wall-clock minute.
  # Issue #579: identical-minute fan-out + BRIDGE_CRON_DISPATCH_MAX_PARALLEL=2
  # starves small-RAM hosts via cron memory-pressure deferrals. Hash is
  # deterministic so a re-applied bootstrap maps the same agent to the same
  # minute (no drift). The conflict-refuse path below preserves any
  # already-registered schedule — operators migrate manually with
  # `agent-bridge cron update --schedule` when they want to adopt the spread.
  local jitter_min
  jitter_min="$(printf '%s' "$agent" | cksum | awk '{print $1 % 60}')"
  local sched="$jitter_min 3 * * *"
  local tz="Asia/Seoul"
  local installed_script="$BRIDGE_HOME/scripts/memory-daily-harvest.sh"

  # Cron payload — cron runner forwards this text to a claude subagent as the
  # prompt body. The inline instruction below is load-bearing (v0.7 §3.3): the
  # Python harvester writes the authoritative RESULT_SCHEMA JSON to
  # $CRON_REQUEST_DIR/authoritative-memory-daily.json and the runner reads that
  # file directly. The subagent's structured_output is a secondary relay and
  # MUST NOT re-interpret status / summary / actions_taken.
  #
  # Issue #541 PR-A — this body must stay byte-identical to the canonical
  # MEMORY_DAILY_JSONL_AWARE_PROMPT_TEMPLATE in bridge-cron.py (with `{agent}`
  # substituted) so `agb cron migrate-payloads --jsonl-aware` treats freshly
  # bootstrapped jobs as `unchanged`. If you edit one, edit the other and
  # docs/agent-runtime/memory-daily-harvest.md §2 in the same change.
  local payload
  payload="bash \"\$BRIDGE_HOME/scripts/memory-daily-harvest.sh\" --agent $agent

# This harvester reconciles the agent's most recent jsonl session
# transcript (resolved via session_id under ~/.claude/projects/) into the
# agent's daily note at memory/daily/<YYYY-MM-DD>.md by invoking
# scripts/daily-note-reconcile.py before the harvest pass. The harvester
# then writes the authoritative RESULT_SCHEMA JSON to
# \$CRON_REQUEST_DIR/authoritative-memory-daily.json. The runner reads that
# file directly. Your structured_output is a secondary relay.
# Do NOT re-interpret status / summary / actions_taken — the harvester is authoritative."

  local found existing_sched existing_tz existing_id
  found="$(memory_daily_cron_lookup "$agent" "$title" || true)"
  if [[ -n "$found" ]]; then
    existing_id="$(printf '%s' "$found" | awk -F'\t' '{print $1}')"
    existing_sched="$(printf '%s' "$found" | awk -F'\t' '{print $2}')"
    existing_tz="$(printf '%s' "$found" | awk -F'\t' '{print $3}')"
  fi

  # Issue #376 Track B: apply-time migration. Track A (v0.6.18) gates the
  # registration loop on STATIC_AGENT_SET so a fresh bootstrap no longer
  # creates memory-daily-<agent> crons for dynamic agents. But pre-v0.6.18
  # installs already have those crons sitting on the cron board — Track C
  # makes the harvester silently no-op for them, but the entries remain
  # dead weight until removed. Detect and clean them up here, mirroring
  # the 3-mode pattern used for the #320 Track A migration in step_cron_one.
  #
  # Dynamic = "active claude agent NOT in STATIC_AGENT_SET". This avoids an
  # extra `agb agent show --json` subprocess per agent — the static set is
  # already loaded at script start from list_active_static_claude_agents.
  if [[ -z "${STATIC_AGENT_SET[$agent]:-}" ]]; then
    if [[ -n "$found" ]]; then
      case "$MODE" in
        apply)
          if "$BRIDGE_AGB" cron delete "$existing_id" >/dev/null 2>&1; then
            record "$agent" "cron:$title" "migrated-removed" \
              "id=$existing_id reason=dynamic-agent-not-memory-daily-target"
          else
            record "$agent" "cron:$title" "migrate-failed" \
              "id=$existing_id reason=dynamic-agent-not-memory-daily-target"
            note_drift
          fi
          ;;
        dry-run)
          record "$agent" "cron:$title" "would-remove" \
            "id=$existing_id reason=dynamic-agent-not-memory-daily-target"
          ;;
        check|*)
          record "$agent" "cron:$title" "drift-migration-pending" \
            "id=$existing_id reason=dynamic-agent-not-memory-daily-target"
          note_drift
          ;;
      esac
    else
      record "$agent" "cron:$title" "skip-dynamic-agent" ""
    fi
    return 0
  fi

  if ! memory_daily_gate_on "$agent"; then
    # Gate off. If a cron exists, schedule a cleanup in apply mode; else skip.
    if [[ -n "$found" ]]; then
      if [[ "$MODE" == "check" ]]; then
        record "$agent" "cron:$title" "drift-disabled-but-present" "id=$existing_id"
        note_drift
      elif [[ "$MODE" == "dry-run" ]]; then
        record "$agent" "cron:$title" "would-delete" "id=$existing_id reason=gate-off"
      else
        if "$BRIDGE_AGB" cron delete "$existing_id" >/dev/null 2>&1; then
          record "$agent" "cron:$title" "deleted-gate-off" "id=$existing_id"
        else
          record "$agent" "cron:$title" "delete-failed" "id=$existing_id"
          note_drift
        fi
      fi
    else
      record "$agent" "cron:$title" "skip-gate-off" ""
    fi
    return 0
  fi

  if [[ -n "$found" ]]; then
    # Normalize schedule vs tz — same approach as step_cron_one above.
    local norm_existing norm_expected trailing_tz effective_existing_tz
    norm_existing="${existing_sched#cron }"
    trailing_tz="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(" ".join(parts[5:]))' "$norm_existing")"
    norm_existing="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(" ".join(parts[:5]))' "$norm_existing")"
    effective_existing_tz="${existing_tz:-$trailing_tz}"
    norm_expected="$sched"

    # Issue #729: extract the existing minute for the re-jitter eligibility
    # gate. The full per-minute collapse count was already populated by
    # prepopulate_memory_daily_minute_counts (run before this loop), so the
    # gate can consult MEMORY_DAILY_MINUTE_COUNTS["$existing_minute"] and
    # know the count reflects ALL agents, not just the ones the loop has
    # walked so far. The lazy incremental tally that lived here pre-r2 was
    # order-dependent and would always show count=1 for the first agent at
    # a colliding minute — wrong signal for the collapse gate.
    local existing_minute
    existing_minute="$("$BRIDGE_PYTHON" -c 'import sys; parts = sys.argv[1].split(); print(parts[0] if parts else "")' "$norm_existing" 2>/dev/null || true)"

    if [[ "$norm_existing" == "$norm_expected" && "$effective_existing_tz" == "$tz" ]]; then
      record "$agent" "cron:$title" "already-registered" "$existing_sched tz=$effective_existing_tz"
      return 0
    fi

    # Issue #729 — opt-in jitter regression remediation. The conflict
    # shape we care about is "schedule is daily-3am with the WRONG minute"
    # (i.e. "<minute> 3 * * *" with minute != jitter_min). That is the
    # signature of a legacy install whose memory-daily crons were
    # registered before the jitter logic landed (or whose jitter regressed
    # during an upgrade) — every agent now fires at the same minute,
    # producing N simultaneous Claude session spawns.
    #
    # We DO NOT remediate every conflict: if the operator has parked the
    # cron at an entirely different hour or day-of-week (`30 4 * * 1`,
    # for example), that is a deliberate override and `--re-jitter` must
    # leave it alone.
    if [[ "$RE_JITTER" == "1" \
          && "$MODE" == "apply" \
          && -n "$existing_id" \
          && "$effective_existing_tz" == "$tz" ]]; then
      # Match schedule shape: M H * * * with H==3 and M numeric & in [0,59].
      # Use python for the parse — same dependency footprint as the rest
      # of this script, and avoids fragile bash regex on cron field syntax.
      local rejitter_eligible
      rejitter_eligible="$("$BRIDGE_PYTHON" - "$norm_existing" <<'PY'
import sys
parts = sys.argv[1].split()
if len(parts) != 5:
    print("no"); sys.exit(0)
minute, hour, dom, mon, dow = parts
if hour != "3" or dom != "*" or mon != "*" or dow != "*":
    print("no"); sys.exit(0)
try:
    m = int(minute)
except ValueError:
    print("no"); sys.exit(0)
if 0 <= m <= 59:
    print("yes")
else:
    print("no")
PY
)"
      # Collapse gate (codex r2): even when the schedule shape matches the
      # legacy-install signature (M 3 * * *), only overwrite when ≥2
      # memory-daily crons share the same minute. A single agent parked at
      # `0 3 * * *` is indistinguishable from a deliberate operator override
      # — there is no fan-out to remediate, so we preserve the schedule and
      # fall through to the conflict-refuse path (which surfaces a
      # collapse-not-detected hint instead of the generic re-jitter hint).
      local simultaneous_count="${MEMORY_DAILY_MINUTE_COUNTS[$existing_minute]:-0}"
      if [[ "$rejitter_eligible" == "yes" ]] && (( simultaneous_count >= 2 )); then
        if "$BRIDGE_AGB" cron update "$existing_id" \
              --schedule "$sched" \
              --tz "$tz" \
              >/dev/null 2>&1; then
          record "$agent" "cron:$title" "re-jittered" \
            "id=$existing_id $existing_sched → $sched tz=$tz reason=#729-jitter-regression simultaneous=$simultaneous_count"
          return 0
        else
          record "$agent" "cron:$title" "re-jitter-failed" \
            "id=$existing_id $existing_sched → $sched simultaneous=$simultaneous_count"
          note_drift
          return 0
        fi
      fi
    fi

    # Issue #2090 — opt-in convergence. Broader than --re-jitter: adopt the
    # shipped default (canonical jittered `<minute> 3 * * *`) for ANY drifted
    # memory-daily-<agent> cron, not only the same-minute collapse signature.
    # The operator opting in with --reconcile has explicitly asked to converge
    # to the shipped cadence, so we update in place (verb-atomic) rather than
    # refuse. Without the flag we fall through to the non-destructive conflict
    # path below (which prints the same diff).
    if [[ "$RECONCILE" == "1" && "$MODE" == "apply" && -n "$existing_id" ]]; then
      if "$BRIDGE_AGB" cron update "$existing_id" \
            --schedule "$sched" \
            --tz "$tz" \
            >/dev/null 2>&1; then
        record "$agent" "cron:$title" "reconciled" \
          "id=$existing_id $existing_sched tz=$effective_existing_tz → $sched tz=$tz reason=#2090-adopt-default"
        printf '[%s] reconcile cron:%s — adopted shipped default: %s tz=%s → %s tz=%s\n' \
          "$MODE" "$title" "$existing_sched" "$effective_existing_tz" "$sched" "$tz"
        return 0
      fi
      record "$agent" "cron:$title" "reconcile-failed" \
        "id=$existing_id $existing_sched tz=$effective_existing_tz → $sched tz=$tz"
      note_drift
      return 0
    fi

    # Conflict refused. Surface the --re-jitter hint when the conflict
    # shape is plausibly a jitter regression (daily-3am, wrong minute) so
    # operators learn about the recovery path without reading docs. The
    # hint is purely advisory — emitting it does not mutate anything.
    #
    # codex r2: when the shape matches but only ONE agent is on this minute
    # (no real collapse), surface a different hint so the operator
    # understands why --re-jitter would have skipped this entry. The
    # collapse-gate path also lands here when invoked with --re-jitter — in
    # that case we still emit the hint so the report row carries the
    # explanation rather than just refusing silently.
    local hint=""
    local hint_simultaneous="${MEMORY_DAILY_MINUTE_COUNTS[$existing_minute]:-0}"
    if [[ "$effective_existing_tz" == "$tz" ]]; then
      local rejitter_eligible_hint
      rejitter_eligible_hint="$("$BRIDGE_PYTHON" - "$norm_existing" <<'PY'
import sys
parts = sys.argv[1].split()
if len(parts) != 5:
    print("no"); sys.exit(0)
minute, hour, dom, mon, dow = parts
if hour != "3" or dom != "*" or mon != "*" or dow != "*":
    print("no"); sys.exit(0)
try:
    m = int(minute)
except ValueError:
    print("no"); sys.exit(0)
print("yes" if 0 <= m <= 59 else "no")
PY
)"
      if [[ "$rejitter_eligible_hint" == "yes" ]]; then
        if (( hint_simultaneous >= 2 )); then
          if [[ "$RE_JITTER" != "1" ]]; then
            hint=" hint=run-with---re-jitter-to-overwrite simultaneous=$hint_simultaneous"
          fi
        else
          # Shape eligible but only one agent on this minute → operator
          # override, not a collapse. Tell the operator we left it alone.
          hint=" hint=skipped-single-minute-cron-not-collapsed simultaneous=$hint_simultaneous"
        fi
      fi
    fi

    # Issue #2090: the drift is adoptable via --reconcile for ANY shape (not
    # just the re-jitter collapse signature). Surface that path when the
    # operator has not opted in, so the generic-override conflict rows learn
    # about the converge-to-default option too.
    if [[ "$RECONCILE" != "1" ]]; then
      hint+=" hint=run-with---reconcile-to-adopt-shipped-default"
    fi

    record "$agent" "cron:$title" "conflict" \
      "existing=$existing_sched tz=$effective_existing_tz want=$sched tz=$tz — refusing$hint"
    note_drift
    return 0
  fi

  if [[ "$MODE" == "check" ]]; then
    record "$agent" "cron:$title" "drift-missing" ""
    note_drift
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "$agent" "cron:$title" "would-register" "schedule=$sched tz=$tz"
    return 0
  fi

  if [[ ! -x "$installed_script" ]]; then
    record "$agent" "cron:$title" "skip-script-missing" "$installed_script"
    note_drift
    return 0
  fi

  # Issue #1474: when this agent differs from the admin running the
  # bootstrap, this is a cross-agent provision that routes through the
  # #1359 staging delegation and the daemon applies it. Capture stderr so
  # a failure (staging timeout / daemon down / a reject reason) surfaces
  # in the record instead of an opaque empty `register-failed` that lets
  # drift silently stick at 2-3 forever (the symptom #1474 reports).
  local _cron_create_err
  _cron_create_err="$(mktemp -t agb-bootstrap-cron-create.XXXXXX 2>/dev/null || printf '')"
  if "$BRIDGE_AGB" cron create --agent "$agent" \
        --schedule "$sched" \
        --tz "$tz" \
        --title "$title" \
        --payload "$payload" \
        >/dev/null 2>"${_cron_create_err:-/dev/null}"; then
    record "$agent" "cron:$title" "registered" "$sched $tz"
  else
    local _err_tail=""
    if [[ -n "$_cron_create_err" && -s "$_cron_create_err" ]]; then
      # Single-line, bounded tail so the TSV record stays parseable
      # (strip both newlines and tabs — the record file is tab-delimited).
      _err_tail="$(tr '\n\t' '  ' <"$_cron_create_err" | cut -c1-300)"
    fi
    record "$agent" "cron:$title" "register-failed" "$_err_tail"
    note_drift
  fi
  [[ -n "$_cron_create_err" ]] && rm -f "$_cron_create_err" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# scripts installation (apply only)
# -----------------------------------------------------------------------------
bootstrap_install_scripts() {
  local target="$BRIDGE_HOME/scripts"
  mkdir -p "$target"
  local changed=0
  for f in _common.sh wiki-weekly-summarize.sh wiki-monthly-summarize.sh \
           wiki-repair-links.sh wiki-v2-rebuild.sh wiki-dedup-weekly.sh \
           wiki-daily-ingest.sh wiki-daily-copy.py wiki-copy-full-backfill.sh \
           wiki-mention-scan.py wiki-mention-scan.sh \
           wiki-hub-audit.py wiki-hub-audit.sh \
           sync-memory-schema.py \
           librarian-provision.sh librarian-watchdog.sh librarian-idle-exit.sh \
           librarian-process-ingest.py \
           memory-daily-harvest.sh; do
    local src="$SCRIPT_DIR/scripts/$f"
    local dst="$target/$f"
    if [[ ! -f "$src" ]]; then
      log "warn: source script missing: $src"
      continue
    fi
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      # Content matches, but a prior upgrade may have dropped the exec
      # bit on the copy (umask-governed write path). step_cron_one gates
      # on `test -x`, so a mode-only drift here causes skip-script-missing
      # downstream. Repair it in apply mode without bumping the file.
      if [[ ! -x "$dst" ]]; then
        if [[ "$MODE" == "check" ]]; then
          note_drift
          record "install" "script:$f" "drift-mode" "$dst"
        elif [[ "$MODE" == "dry-run" ]]; then
          record "install" "script:$f" "would-chmod" "$dst"
        else
          chmod 0755 "$dst"
          record "install" "script:$f" "chmod-repaired" "$dst"
        fi
      fi
      continue
    fi
    if [[ "$MODE" == "check" ]]; then
      note_drift
      record "install" "script:$f" "drift-mismatch" ""
      continue
    fi
    if [[ "$MODE" == "dry-run" ]]; then
      record "install" "script:$f" "would-install" ""
      continue
    fi
    cp "$src" "$dst"
    chmod 0755 "$dst"
    changed=$((changed + 1))
    record "install" "script:$f" "installed" ""
  done
  log "scripts changed: $changed"

  # librarian-provision.sh resolves its CLAUDE.md template at
  # $SCRIPT_DIR/agents/librarian/CLAUDE.md. On a downstream install
  # where $BRIDGE_HOME != the repo checkout, this file is missing
  # unless we explicitly stage it. Ensure the template sits next to
  # the provisioner before step_librarian_provision runs.
  local agents_src="$SCRIPT_DIR/scripts/agents"
  local agents_dst="$BRIDGE_HOME/scripts/agents"
  if [[ -d "$agents_src" ]]; then
    local templ_changed=0
    while IFS= read -r -d '' src; do
      local rel="${src#$agents_src/}"
      local dst="$agents_dst/$rel"
      if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        continue
      fi
      if [[ "$MODE" == "check" ]]; then
        note_drift
        record "install" "template:agents/$rel" "drift-mismatch" ""
        continue
      fi
      if [[ "$MODE" == "dry-run" ]]; then
        record "install" "template:agents/$rel" "would-install" ""
        continue
      fi
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      templ_changed=$((templ_changed + 1))
      record "install" "template:agents/$rel" "installed" ""
    done < <(find "$agents_src" -type f -name '*.md' -print0 2>/dev/null)
    if [[ "$templ_changed" -gt 0 ]]; then log "agent templates changed: $templ_changed"; fi
  fi
}

# -----------------------------------------------------------------------------
# librarian provisioning (dynamic agent — required for Lane B ingest)
# -----------------------------------------------------------------------------
step_librarian_provision() {
  local provision_script="$BRIDGE_HOME/scripts/librarian-provision.sh"
  if [[ ! -x "$provision_script" ]]; then
    record "librarian" "provision" "skip-script-missing" "$provision_script"
    note_drift
    return 0
  fi
  # Fast-path: librarian already registered → no-op. The provision script
  # is idempotent but this avoids an extra subprocess on common case.
  if "$BRIDGE_AGB" agent list 2>/dev/null | awk '{print $1}' | grep -qx "librarian"; then
    record "librarian" "provision" "already-provisioned" ""
    return 0
  fi
  if [[ "$MODE" == "check" ]]; then
    note_drift
    record "librarian" "provision" "drift-missing" ""
    return 0
  fi
  if [[ "$MODE" == "dry-run" ]]; then
    record "librarian" "provision" "would-provision" ""
    return 0
  fi
  if bash "$provision_script" >>"$RECORD_FILE.provision.log" 2>&1; then
    record "librarian" "provision" "provisioned" ""
  else
    record "librarian" "provision" "provision-failed" \
      "see $RECORD_FILE.provision.log"
    note_drift
  fi
}

# -----------------------------------------------------------------------------
# memory-daily aggregate migration (issue #219): move legacy root-level
# admin-aggregate JSON files into shared/aggregate/ so the new ACL contract
# (linux-user isolation) can grant write on the shared subdir without opening
# up the per-agent manifest tree. Runs in controller context, idempotent.
# -----------------------------------------------------------------------------
bootstrap_migrate_memory_daily_aggregate() {
  local mdr="$BRIDGE_STATE_DIR/memory-daily"
  local shared_agg="$mdr/shared/aggregate"
  [[ -d "$mdr" ]] || return 0
  local agg
  for agg in admin-aggregate-skip.json admin-aggregate-escalated.json; do
    local legacy="$mdr/$agg"
    local target="$shared_agg/$agg"
    if [[ -f "$legacy" && ! -f "$target" ]]; then
      if [[ "$MODE" == "apply" ]]; then
        mkdir -p "$shared_agg"
        mv "$legacy" "$target"
        record "$BRIDGE_ADMIN_AGENT" "memory-daily:$agg" "migrated" "shared/aggregate/"
      elif [[ "$MODE" == "dry-run" ]]; then
        record "$BRIDGE_ADMIN_AGENT" "memory-daily:$agg" "would-migrate" "shared/aggregate/"
      else
        note_drift
        record "$BRIDGE_ADMIN_AGENT" "memory-daily:$agg" "drift-legacy-present" "shared/aggregate/"
      fi
    fi
    local legacy_lock="$mdr/$agg.lock"
    local target_lock="$shared_agg/$agg.lock"
    if [[ -f "$legacy_lock" && ! -f "$target_lock" && "$MODE" == "apply" ]]; then
      mkdir -p "$shared_agg"
      mv "$legacy_lock" "$target_lock"
    fi
  done
}

# -----------------------------------------------------------------------------
# step 4: opt-in historical backfill of memory-daily harvests (issue #322 Track C)
# -----------------------------------------------------------------------------
# When the operator passes `--backfill-history N`, fan harvest-daily out across
# the [today-N, today-1] window for every active claude agent in the bootstrap
# scope, with `--missing-only` so re-runs are no-ops. The flag is OFF by
# default — opt-in is the contract because a real backfill of N=14 days across
# 5 agents queues up to 70 [memory-daily-backfill] tasks at once. Tracks A+B
# (PR #335 + PR #340) shipped the range mode and --missing-only filter that
# this loop drives; this step is the post-install ergonomic that prevents
# the pre-cron-registration coverage gap from going unnoticed.
step_backfill_history_one() {
  local agent="$1" home="$2" from_date="$3" to_date="$4"
  local rc=0
  local stderr_log="$REPORT_DIR/.backfill-history-$agent-$STAMP.stderr"
  if "$BRIDGE_PYTHON" "$BRIDGE_HOME/bridge-memory.py" harvest-daily \
        --agent "$agent" \
        --home "$home" \
        --workdir "$home" \
        --from "$from_date" --to "$to_date" \
        --tz Asia/Seoul \
        --missing-only \
        >/dev/null 2>"$stderr_log"; then
    record "$agent" "backfill-history" "ok" \
      "from=$from_date to=$to_date days=$BACKFILL_HISTORY_DAYS missing-only"
    return 0
  fi
  rc=$?
  # Per-agent failures must NOT abort the loop — tracked in the JSON report
  # with the stderr tail so the operator can triage one agent without losing
  # the rest.
  local stderr_tail
  stderr_tail="$(tr '\n' ' ' <"$stderr_log" 2>/dev/null | head -c 200)"
  record "$agent" "backfill-history" "failed" \
    "rc=$rc from=$from_date to=$to_date stderr=$stderr_tail"
  return 1
}

run_backfill_history() {
  # Caller guarantees BACKFILL_HISTORY_DAYS is a validated [1, 90] integer
  # and MODE == "apply".
  local n="$BACKFILL_HISTORY_DAYS"
  local from_date to_date
  # `date -v-Nd` is BSD/macOS; `date -d "N days ago"` is GNU. Try both so the
  # bootstrap stays portable across the same OS matrix the rest of the bridge
  # supports (Bash 4+, macOS + Linux).
  from_date="$(date -v-"${n}"d +%Y-%m-%d 2>/dev/null \
            || date -d "${n} days ago" +%Y-%m-%d 2>/dev/null \
            || true)"
  to_date="$(date -v-1d +%Y-%m-%d 2>/dev/null \
          || date -d 'yesterday' +%Y-%m-%d 2>/dev/null \
          || true)"
  if [[ -z "$from_date" || -z "$to_date" ]]; then
    record "$BRIDGE_ADMIN_AGENT" "backfill-history" "skip-date-resolve-failed" \
      "n=$n from=$from_date to=$to_date"
    note_drift
    return 0
  fi

  if [[ "$AGENT_COUNT" -eq 0 ]]; then
    record "$BRIDGE_ADMIN_AGENT" "backfill-history" "skip-no-agents" \
      "n=$n from=$from_date to=$to_date"
    return 0
  fi

  # Resolve agent (name, home) pairs from the cached snapshot taken at script
  # start. We can't re-run list_active_claude_agents here without paying for
  # another `agb agent list --json` round-trip; the snapshot is fresh enough
  # for a single bootstrap run.
  local ok_count=0 fail_count=0
  while IFS=$'\t' read -r agent home; do
    [[ -z "$agent" || -z "$home" ]] && continue
    if step_backfill_history_one "$agent" "$home" "$from_date" "$to_date"; then
      ok_count=$((ok_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
  done < "$AGENT_LIST_TMP"

  record "$BRIDGE_ADMIN_AGENT" "backfill-history-summary" "complete" \
    "n=$n from=$from_date to=$to_date agents=$AGENT_COUNT ok=$ok_count fail=$fail_count"
  if (( fail_count > 0 )); then
    note_drift
  fi
}

# -----------------------------------------------------------------------------
# run all steps
# -----------------------------------------------------------------------------
bootstrap_install_scripts
bootstrap_migrate_memory_daily_aggregate
step_librarian_provision

# Issue #729 (codex r2): build the FULL pre-fix collapse map before any
# per-agent mutation. The re-jitter eligibility gate inside
# step_memory_daily_cron_one consults MEMORY_DAILY_MINUTE_COUNTS to gate
# overwrites on ≥2 same-minute crons (real collapse), so a single
# operator-overridden agent at e.g. minute 0 is preserved.
prepopulate_memory_daily_minute_counts

while IFS=$'\t' read -r agent home; do
  [[ -z "$agent" || -z "$home" ]] && continue
  step_hook_one "$agent" "$home"
  step_rebuild_one "$agent" "$home"
  # Issue #376: memory-daily-<agent> registration is gated on static-class
  # membership *inside* step_memory_daily_cron_one. The function returns
  # early for dynamic agents — either deleting a stale pre-v0.6.18 cron
  # (Track B apply-time migration) or recording skip-dynamic-agent when no
  # cron exists. Always invoke; the static/dynamic split is the function's
  # responsibility, not the loop's.
  step_memory_daily_cron_one "$agent"
done < "$AGENT_LIST_TMP"

for spec in "${CRON_SPECS[@]}"; do
  IFS='|' read -r title sched tz script <<<"$spec"
  step_cron_one "$title" "$sched" "$tz" "$script"
done

# Issue #322 Track C — opt-in, apply-only. Runs after cron registration so a
# fresh install ends with both forward (cron-driven) and backward (this loop)
# coverage. dry-run / check skip the loop entirely; the harvester itself is
# the SSOT for "what would be queued", and exposing a synthetic dry-run here
# would double-code that decision logic.
if [[ "$MODE" == "apply" && -n "$BACKFILL_HISTORY_DAYS" ]]; then
  run_backfill_history
elif [[ -n "$BACKFILL_HISTORY_DAYS" ]]; then
  record "$BRIDGE_ADMIN_AGENT" "backfill-history" "skip-non-apply-mode" \
    "mode=$MODE n=$BACKFILL_HISTORY_DAYS"
fi

rm -f "$EXISTING_CRONS_JSON" "$AGENT_LIST_TMP" "$STATIC_AGENT_LIST_TMP"

# -----------------------------------------------------------------------------
# first-run post-bootstrap signal — queue the "do the first scan + hub
# candidate review" task for the admin agent. Only fires once per install;
# subsequent --apply runs skip so the admin isn't spammed.
# -----------------------------------------------------------------------------
FIRST_RUN_MARKER="$REPORT_DIR/.first-run-complete"
# Only emit the first-run task when:
#   - mode is apply (dry-run / check never notify)
#   - marker does not yet exist (prevents spam on re-applies)
#   - bootstrap converged (DRIFT=0 — no install/register failures)
#   - bridge CLI is executable
# AND only write the marker AFTER `agb task create` succeeds, so if
# task creation fails we retry the signal on the next --apply.
if [[ "$MODE" == "apply" && ! -f "$FIRST_RUN_MARKER" \
      && "$DRIFT" -eq 0 && -x "$BRIDGE_AGB" ]]; then
  FIRST_RUN_BODY="$(mktemp -t bootstrap-first-run.XXXXXX)"
  cat >"$FIRST_RUN_BODY" <<FR_EOF
# Wiki pipeline bootstrap completed — first run on this host

- bootstrap_report: $REPORT
- admin_agent: $BRIDGE_ADMIN_AGENT
- bridge_home: $BRIDGE_HOME
- completed_at: $(date -Iseconds 2>/dev/null || date)

## Next steps (one-time)

1. Full mention scan — builds shared/wiki/_index/mentions.db only and
   prints a JSON summary (it does not write a report file). Idempotent,
   safe to re-run.
   \`$BRIDGE_HOME/scripts/wiki-mention-scan.py --full-rebuild\`

2. Generate today's distribution report from the freshly built index,
   then review it. Use every section:
   \`\`\`
   $BRIDGE_HOME/scripts/wiki-mention-scan.py --report \\
     --out $BRIDGE_WIKI_ROOT/_index/distribution-report-\$(date +%Y-%m-%d).md
   \`\`\`
   - §1 cross-agent reach — sanity check.
   - §2 L2 hub candidates — the weekly cron resurfaces these as
     \`[wiki-hub-candidates]\` tasks; trigger now in step 3.
   - §3 unresolved wikilinks — typos or missing stubs. Fix
     unambiguous targets with \`agb wiki repair-links --apply\`.
   - §4 orphan entity slugs — delete per
     \`docs/agent-runtime/wiki-entity-lifecycle.md\` §3.6 or
     leave until Phase 3 LLM can classify.
   Path: \`$BRIDGE_WIKI_ROOT/_index/distribution-report-<date>.md\`

3. Trigger the first L2 candidacy sweep now (cron will run this
   weekly on Thursday 23:00 KST from now on):
   \`\`\`
   $BRIDGE_HOME/scripts/wiki-hub-audit.py \\
     --emit-task --admin-agent $BRIDGE_ADMIN_AGENT \\
     --bridge-bin $BRIDGE_AGB \\
     --out $BRIDGE_WIKI_ROOT/_audit/hub-candidates-\$(date +%Y-%m-%d).md
   \`\`\`
   Note: \`--emit-task\` requires \`--out\`; without \`--out\`
   the script writes to stdout and skips the task creation.

4. When the \`[wiki-hub-candidates]\` task lands, process per
   \`docs/agent-runtime/admin-protocol.md\` "Wiki Canonical Hub
   Curation" section.

## Pipeline reference

- \`docs/agent-runtime/wiki-onboarding.md\` — full admin walkthrough
- \`docs/agent-runtime/admin-protocol.md\` — weekly hub curation ritual
- \`docs/agent-runtime/wiki-mention-index.md\` — L1 schema + cadence
- \`docs/agent-runtime/wiki-entity-lifecycle.md\` — entity frontmatter rules
- \`docs/agent-runtime/wiki-graph-rules.md\` — graph edge policy

## Done

Close with: \`agb done <task_id> --note "first scan <N> files / <E> entities; <C> hub candidates for review"\`
FR_EOF
  if "$BRIDGE_AGB" task create \
      --to "$BRIDGE_ADMIN_AGENT" --priority normal --from "$BRIDGE_ADMIN_AGENT" \
      --title "[wiki-system-first-run] bootstrap complete — do initial scan" \
      --body-file "$FIRST_RUN_BODY" >/dev/null 2>&1; then
    : > "$FIRST_RUN_MARKER"
  fi
  rm -f "$FIRST_RUN_BODY"
elif [[ "$MODE" == "apply" && ! -f "$FIRST_RUN_MARKER" && "$DRIFT" -gt 0 ]]; then
  # Bootstrap did not converge cleanly. Do NOT emit a "complete" task
  # and do NOT write the marker — the next --apply will retry once
  # the underlying failures are fixed.
  log "first-run signal deferred: drift=$DRIFT (bootstrap did not converge)"
fi

# -----------------------------------------------------------------------------
# emit JSON report
# -----------------------------------------------------------------------------
"$BRIDGE_PYTHON" - "$RECORD_FILE" "$MODE" "$DRIFT" "$REPORT" "$MEMORY_DAILY_SIMULTANEOUS_FIRE_MAX" "$RE_JITTER" "$RECONCILE" <<'PY'
import json, sys, datetime, pathlib
record_file, mode, drift_str, out_path, simul_max_str, rejitter_str, reconcile_str = sys.argv[1:8]
drift = int(drift_str)
simul_max = int(simul_max_str)
re_jitter = bool(int(rejitter_str))
reconcile = bool(int(reconcile_str))
records = []
with open(record_file, encoding="utf-8") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        while len(parts) < 4:
            parts.append("")
        agent, step, status, note = parts
        records.append({"agent": agent, "step": step, "status": status, "note": note})
payload = {
    "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "mode": mode,
    "drift": drift,
    # Issue #729 — fan-out indicator. > 1 means N memory-daily-<agent>
    # crons share a single wall-clock minute, producing N simultaneous
    # Claude session spawns. Operators run with --re-jitter to remediate.
    "memory_daily_simultaneous_fire_max": simul_max,
    "re_jitter_requested": re_jitter,
    # Issue #2090 — set when --reconcile was passed. Reconciled same-family
    # crons appear as records with status "reconciled" (existing → want).
    "reconcile_requested": reconcile,
    "record_count": len(records),
    "records": records,
}
pathlib.Path(out_path).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
print(f"report: {out_path}")
PY

log "done mode=$MODE drift=$DRIFT"

# Exit policy:
# - apply: 0 unless install-failed or register-failed records exist.
# - dry-run: 0 always (report is the output).
# - check: 0 only when drift==0, else 1.
case "$MODE" in
  check)
    if (( DRIFT > 0 )); then exit 1; fi
    ;;
  apply)
    # Escalate to 2 if any hard-fail step happened.
    if grep -qE $'\t'"(install-failed|register-failed|rebuild-failed|validate-failed)"$'\t' "$RECORD_FILE"; then
      exit 2
    fi
    ;;
esac
exit 0
