#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/status-fast-default.sh
#
# `agb status` fast by default — defer the expensive analytics behind --full.
#
# Operator report: `agb status` took ~30s on a long-lived host. cProfile
# traced the cost to render_dashboard running audit-full-parse / fs-walk
# diagnostics on EVERY human render:
#   - orphan_agent_dir_count          (symlink keep-set fs-walk, ~23s)
#   - context_pressure_fp_rate        (json.loads over ~1.1M audit lines)
#   - config_drift_count              (audit parse)
#   - nudge_recheck_observability_counts (audit parse)
#   - pending_upgrade_conflict_count  (fs scan)
#
# Fix: the default text dashboard computes only the CORE state (daemon /
# agents / queue / health / cron — the cheap reads) and SKIPS the five
# analytics entirely (no compute, no render). `--full` (alias `--analytics`)
# restores them. The `--json` MACHINE path is unaffected — it always emits
# the full analytics fields so existing JSON consumers stay correct.
#
# This smoke asserts the deferral STRUCTURALLY (a portable `time` gate is
# not reliable in CI). It uses a fixture-seeded `cron_human_config_drift`
# audit row + a pending `*.upgrade-conflict` file so the two analytics that
# render unconditionally-when-nonzero (config-drift line, upgrade-conflict
# WARNING) are present-with-`--full` and absent-by-default. The CORE state
# (daemon line + Totals + Agents header) must render in BOTH views. The
# `--json` path must carry the analytics fields regardless of `--full`.
#
# Non-vacuous by construction: the SAME fixture drives both renders, so the
# default-absent / full-present pair fails if the deferral is reverted (the
# analytics would then render in the default too) OR if the analytics stop
# rendering under --full (the full-present assertions would fail).
#
# Footgun #11 (no python3 heredoc-stdin from a `$()`): every python3
# subprocess reads inputs via argv / file paths, never via stdin.

set -euo pipefail

# Re-exec under Bash 4+ for the bridge libs / smoke helpers.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:status-fast-default] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="status-fast-default"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

STATUS_PY="$REPO_ROOT/bridge-status.py"
AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"
: >"$AUDIT_LOG"

DAEMON_PID_FILE="$BRIDGE_STATE_DIR/daemon.pid"
: >"$DAEMON_PID_FILE"

# Roster snapshot with a header but no agent rows (matches the
# upgrade-conflicts-lifecycle / admin-gateway fixtures — the analytics under
# test don't depend on roster content).
ROSTER_SNAPSHOT="$SMOKE_TMP_ROOT/roster-snapshot.tsv"
printf 'agent\tengine\tworkdir\tactive\twake\tchannels\tloop\tsource\tactivity_state\n' >"$ROSTER_SNAPSHOT"

# Fixture 1: a recent `cron_human_config_drift` audit row → config_drift_count
# returns 1 → the `config-drift (Nd): 1` line renders WHEN --full.
python3 "$REPO_ROOT/bridge-audit.py" write --file "$AUDIT_LOG" \
  --actor daemon --action cron_human_config_drift --target some-agent \
  --detail job_key=demo >/dev/null

# Fixture 2: a pending `*.upgrade-conflict` file → pending_upgrade_conflict_count
# returns 1 → the WARNING line renders WHEN --full.
mkdir -p "$BRIDGE_HOME/scripts"
: >"$BRIDGE_HOME/scripts/smoke-fixture.sh"
: >"$BRIDGE_HOME/scripts/smoke-fixture.sh.upgrade-conflict"

run_status() {
  # run_status <extra-args...> → prints the dashboard to stdout.
  python3 "$STATUS_PY" \
    --roster-snapshot "$ROSTER_SNAPSHOT" \
    --db "$BRIDGE_TASK_DB" \
    --daemon-pid-file "$DAEMON_PID_FILE" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --bridge-home "$BRIDGE_HOME" \
    --audit-log "$AUDIT_LOG" \
    "$@"
}

# --- (1) default dashboard: analytics DEFERRED, core state present ---------
assert_default_defers_analytics() {
  local out
  out="$(run_status)" || smoke_fail "(1) default render failed: $out"

  # Core state renders in the fast default path.
  smoke_assert_contains "$out" "Agent Bridge Status" "(1) default renders the title (core)"
  smoke_assert_contains "$out" "daemon " "(1) default renders the daemon line (core)"
  smoke_assert_contains "$out" "Totals" "(1) default renders the Totals line (core)"
  smoke_assert_contains "$out" "Agents" "(1) default renders the Agents section (core)"

  # The five analytics must NOT compute/render in the default path.
  smoke_assert_not_contains "$out" "config-drift (" "(1) default omits the config-drift analytic"
  smoke_assert_not_contains "$out" "pending upgrade-conflict file" "(1) default omits the upgrade-conflict WARNING"
  smoke_assert_not_contains "$out" "context-pressure FP rate" "(1) default omits the context-pressure analytic"
  smoke_assert_not_contains "$out" "nudge-recheck (" "(1) default omits the nudge-recheck analytic"

  # The deferral hint tells the operator how to get the analytics.
  smoke_assert_contains "$out" "analytics deferred" "(1) default emits the deferral hint"
  smoke_assert_contains "$out" "run with --full" "(1) deferral hint names --full"
}

# --- (2) --full dashboard: analytics PRESENT, core state present -----------
assert_full_renders_analytics() {
  local out
  out="$(run_status --full)" || smoke_fail "(2) --full render failed: $out"

  # Core state still renders under --full.
  smoke_assert_contains "$out" "Agent Bridge Status" "(2) --full renders the title (core)"
  smoke_assert_contains "$out" "Totals" "(2) --full renders the Totals line (core)"
  smoke_assert_contains "$out" "Agents" "(2) --full renders the Agents section (core)"

  # The fixture-driven analytics render under --full.
  smoke_assert_contains "$out" "config-drift (7d): 1" "(2) --full renders the config-drift analytic"
  smoke_assert_contains "$out" "WARNING: 1 pending upgrade-conflict file(s)" "(2) --full renders the upgrade-conflict WARNING"

  # The deferral hint is gone under --full.
  smoke_assert_not_contains "$out" "analytics deferred" "(2) --full drops the deferral hint"
}

# --- (3) --analytics alias behaves like --full -----------------------------
assert_analytics_alias() {
  local out
  out="$(run_status --analytics)" || smoke_fail "(3) --analytics render failed: $out"
  smoke_assert_contains "$out" "config-drift (7d): 1" "(3) --analytics alias renders the analytics"
  smoke_assert_not_contains "$out" "analytics deferred" "(3) --analytics alias drops the deferral hint"
}

# --- (4) --json MACHINE path unaffected: analytics fields present ----------
# The lean default is the HUMAN dashboard only; the JSON path must keep
# emitting the analytics fields so existing JSON consumers (the
# upgrade-conflicts / 1323 smokes, admin-bot) stay correct.
assert_json_keeps_analytics() {
  local json
  json="$(run_status --json)" || smoke_fail "(4) --json render failed: $json"

  local json_file helper
  json_file="$SMOKE_TMP_ROOT/status.json"
  printf '%s' "$json" >"$json_file"
  helper="$SMOKE_TMP_ROOT/assert-json.py"
  cat >"$helper" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
# The analytics fields must be present in the default (no --full) JSON.
assert "pending_upgrade_conflicts" in doc, f"missing pending_upgrade_conflicts: {sorted(doc)}"
assert "orphan_agent_dirs" in doc, f"missing orphan_agent_dirs: {sorted(doc)}"
assert "nudge_recheck" in doc, f"missing nudge_recheck: {sorted(doc)}"
# The fixture seeded one pending upgrade-conflict file; the JSON machine
# path must observe it even without --full.
assert doc["pending_upgrade_conflicts"] == 1, doc["pending_upgrade_conflicts"]
# Core state is also present.
assert "daemon" in doc and "totals" in doc and "agents" in doc, sorted(doc)
print("ok")
PY
  local parsed
  parsed="$(python3 "$helper" "$json_file")" || smoke_fail "(4) --json analytics-field assertion failed"
  smoke_assert_eq "ok" "$parsed" "(4) --json carries analytics fields without --full"
}

smoke_run "(1) default dashboard defers the expensive analytics, keeps core state" assert_default_defers_analytics
smoke_run "(2) --full computes + renders the analytics, keeps core state" assert_full_renders_analytics
smoke_run "(3) --analytics alias matches --full" assert_analytics_alias
smoke_run "(4) --json machine path keeps the analytics fields (default lean = human only)" assert_json_keeps_analytics

smoke_log "PASS: $SMOKE_NAME"
