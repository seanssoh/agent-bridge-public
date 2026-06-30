#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2196-codex-orphan-reaper.sh — issue #2196.
#
# codex sessions spawn `node .../app-server-broker.mjs serve ...` which forks a
# `codex app-server` child (1:1). On session/host exit the broker is reparented
# to launchd (ppid==1) and keeps its app-server alive forever — a slow,
# unbounded memory/PID leak (146 pairs / ~9.3 GB in the incident) that standard
# health checks miss. lib/daemon-helpers/codex-app-server-reaper.py reaps these
# orphan pairs, gated by ALL of: broker.mjs + ppid==1 + NOT backed by a live
# codex session + age>=floor. bridge-daemon.sh runs it periodically
# (process_codex_app_server_reaper) and exposes it standalone
# (`agb daemon reap-codex-orphans`); the #68 guard refuses it from a transient
# checkout.
#
# This smoke drives the REAL reaper against a FABRICATED ps table (the helper's
# `--ps-snapshot` test seam) backed by real `sleep` stand-in processes, so the
# ppid==1 / 6h-age / roster-backed metadata is deterministic while os.kill()
# still targets real pids. It proves:
#   KEY  a roster-backed (live) app-server pair — same broker.mjs + ppid==1 +
#        old-age signature as an orphan — is NEVER reaped (cwd-protected and
#        pid-protected), while the genuine orphan pair IS reaped.
#   B2   a scan (dry-run) detects but kills NOTHING.
#   B3   the age floor spares an orphan younger than --min-age-seconds.
#   D    the daemon wires the periodic pass + the standalone subcommand, and the
#        #68 guard gates the process-killing verb.

set -euo pipefail

SMOKE_NAME="2196-codex-orphan-reaper"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REAPER_PY="$SMOKE_REPO_ROOT/lib/daemon-helpers/codex-app-server-reaper.py"
DAEMON_SH="$SMOKE_REPO_ROOT/bridge-daemon.sh"
LIB_SH="$SMOKE_REPO_ROOT/bridge-lib.sh"

smoke_require_cmd ps
smoke_require_cmd python3

# ---------------------------------------------------------------------------
smoke_log "A: reaper + daemon sources are valid"
[[ -f "$REAPER_PY" ]] || smoke_fail "missing reaper: $REAPER_PY"
python3 -c "import py_compile; py_compile.compile('$REAPER_PY', doraise=True)" || \
  smoke_fail "codex-app-server-reaper.py failed py_compile"
for f in "$DAEMON_SH" "$LIB_SH"; do
  bash -n "$f" || smoke_fail "$(basename "$f") failed bash -n"
done
# `--platform any` is required for this CI host (Linux); without it the reaper
# correctly no-ops on a non-Darwin box.
python3 "$REAPER_PY" scan --platform any --json >/dev/null || \
  smoke_fail "scan subcommand not callable"

# ---------------------------------------------------------------------------
smoke_make_temp_root "$SMOKE_NAME"
LIVE_WD="$SMOKE_TMP_ROOT/live-agent-workdir"
GONE_WD="$SMOKE_TMP_ROOT/gone-worktree"
mkdir -p "$LIVE_WD"
SNAP="$SMOKE_TMP_ROOT/ps.txt"

# Real stand-in processes. argv is irrelevant — the reaper reads identity from
# the snapshot; os.kill() targets these real pids.
sleep 600 & OB=$!   # orphan broker
sleep 600 & OA=$!   # orphan app-server (child of OB)
sleep 600 & LB=$!   # live broker (roster-backed by --cwd)
sleep 600 & LA=$!   # live app-server (child of LB)
sleep 600 & PB=$!   # live broker (roster-backed by explicit --protect-pid)

_pids=("$OB" "$OA" "$LB" "$LA" "$PB")
# Detach from job control so a reaped stand-in does not print a "Terminated"
# job-control notice (cosmetic noise in CI logs); kill-by-pid still works.
disown "${_pids[@]}" 2>/dev/null || true
# shellcheck disable=SC2064
trap "kill ${_pids[*]} 2>/dev/null || true; smoke_cleanup_temp_root" EXIT

BROKER_CMD="node /Users/x/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts/app-server-broker.mjs serve --endpoint unix:/tmp/b.sock"
APP_CMD="/Users/x/.fnm/node-versions/v24/installation/bin/codex app-server"

# fields: pid ppid age_seconds rss command...
{
  printf '%s 1 90000 64000 %s --cwd %s --pid-file /tmp/o/broker.pid\n'   "$OB" "$BROKER_CMD" "$GONE_WD"
  printf '%s %s 90000 63000 %s\n'                                         "$OA" "$OB" "$APP_CMD"
  printf '%s 1 90000 64000 %s --cwd %s --pid-file /tmp/l/broker.pid\n'   "$LB" "$BROKER_CMD" "$LIVE_WD"
  printf '%s %s 90000 63000 %s\n'                                         "$LA" "$LB" "$APP_CMD"
  printf '%s 1 90000 64000 %s --cwd %s --pid-file /tmp/p/broker.pid\n'   "$PB" "$BROKER_CMD" "$SMOKE_TMP_ROOT/other-wd"
} >"$SNAP"

_assert_alive() { kill -0 "$2" 2>/dev/null || smoke_fail "$1 (pid $2) was killed but must SURVIVE"; }
_assert_dead()  { kill -0 "$2" 2>/dev/null && smoke_fail "$1 (pid $2) must be REAPED but is alive"; return 0; }

# ---------------------------------------------------------------------------
smoke_log "B2: scan (dry-run) detects the orphan pair but KILLS NOTHING"
scan_json="$(python3 "$REAPER_PY" scan --platform any --ps-snapshot "$SNAP" \
  --protect-cwd "$LIVE_WD" --protect-pid "$PB" --json)"
scan_total="$(BRIDGE_T="$scan_json" python3 -c 'import os,json;print(json.loads(os.environ["BRIDGE_T"])["counts"]["total"])')"
smoke_assert_eq "2" "$scan_total" "scan must report exactly the orphan broker+app-server pair"
# The scan must name the orphan pids and NOT the protected ones.
cand_pids="$(BRIDGE_T="$scan_json" python3 -c 'import os,json;print(" ".join(str(c["pid"]) for c in json.loads(os.environ["BRIDGE_T"])["candidates"]))')"
case " $cand_pids " in *" $OB "*) : ;; *) smoke_fail "scan did not flag orphan broker $OB" ;; esac
case " $cand_pids " in *" $OA "*) : ;; *) smoke_fail "scan did not flag orphan app-server $OA" ;; esac
case " $cand_pids " in *" $LB "*|*" $LA "*|*" $PB "*) smoke_fail "scan flagged a protected live process: $cand_pids" ;; esac
for nm in "OB:$OB" "OA:$OA" "LB:$LB" "LA:$LA" "PB:$PB"; do _assert_alive "${nm%%:*}" "${nm##*:}"; done

# ---------------------------------------------------------------------------
smoke_log "B3: age floor — an orphan younger than --min-age-seconds is spared"
python3 "$REAPER_PY" reap --platform any --ps-snapshot "$SNAP" \
  --protect-cwd "$LIVE_WD" --protect-pid "$PB" --min-age-seconds 999999 \
  --grace-seconds 2 --json >/dev/null
for nm in "OB:$OB" "OA:$OA" "LB:$LB" "LA:$LA" "PB:$PB"; do _assert_alive "${nm%%:*}" "${nm##*:}"; done

# ---------------------------------------------------------------------------
smoke_log "KEY: reap kills ONLY the genuine orphan pair; live roster-backed pairs SURVIVE"
reap_json="$(python3 "$REAPER_PY" reap --platform any --ps-snapshot "$SNAP" \
  --protect-cwd "$LIVE_WD" --protect-pid "$PB" --grace-seconds 3 --json)"
reaped_flag="$(BRIDGE_T="$reap_json" python3 -c 'import os,json;print(json.loads(os.environ["BRIDGE_T"])["reaped"])')"
smoke_assert_eq "True" "$reaped_flag" "reap report must mark reaped=True"

# The crux of #2196: a live app-server with the SAME ppid==1 + old broker.mjs
# signature must NEVER be reaped because it is backed by a live codex session.
_assert_alive "live broker (cwd-protected) LB" "$LB"
_assert_alive "live app-server (cwd-protected) LA" "$LA"
_assert_alive "live broker (pid-protected) PB" "$PB"
# The genuine orphan pair IS reaped.
_assert_dead "orphan broker OB" "$OB"
_assert_dead "orphan app-server OA" "$OA"

# ---------------------------------------------------------------------------
# Regression guard for the codex Phase-4 finding: a `--cwd` value with SPACES
# (a live agent workdir like "/Users/sean/Live Project") must parse in full so
# cwd-protection still matches; a broker with NO `--cwd` (or an unparseable one)
# must fail CLOSED (spared); and an orphan whose spaced `--cwd` sits at the END
# of a (possibly truncated) ps line must still parse + reap.
smoke_log "B5: cwd-parse safety — spaced live cwd spared, no-cwd fail-closed, spaced EOL orphan reaped"
SPACE_LIVE_WD="$SMOKE_TMP_ROOT/Live Project"   # NOTE: embedded space
SPACE_GONE_WD="$SMOKE_TMP_ROOT/gone worktree"  # spaced + never created (gone)
mkdir -p "$SPACE_LIVE_WD"
sleep 600 & LBS=$!   # live broker, spaced protected --cwd (the bug scenario)
sleep 600 & LBSA=$!  # its app-server child
sleep 600 & NCB=$!   # broker.mjs ppid==1 old with NO --cwd -> fail-closed
sleep 600 & OEB=$!   # orphan broker, spaced --cwd at END of line -> reap
sleep 600 & OEA=$!   # its app-server child
_pids5=("$LBS" "$LBSA" "$NCB" "$OEB" "$OEA")
disown "${_pids5[@]}" 2>/dev/null || true
SNAP5="$SMOKE_TMP_ROOT/ps5.txt"
{
  printf '%s 1 90000 64000 %s --cwd %s --pid-file /tmp/l/b.pid\n' "$LBS" "$BROKER_CMD" "$SPACE_LIVE_WD"
  printf '%s %s 90000 63000 %s\n'                                  "$LBSA" "$LBS" "$APP_CMD"
  printf '%s 1 90000 64000 %s --pid-file /tmp/n/b.pid\n'           "$NCB" "$BROKER_CMD"
  printf '%s 1 90000 64000 %s --cwd %s\n'                          "$OEB" "$BROKER_CMD" "$SPACE_GONE_WD"
  printf '%s %s 90000 63000 %s\n'                                  "$OEA" "$OEB" "$APP_CMD"
} >"$SNAP5"
python3 "$REAPER_PY" reap --platform any --ps-snapshot "$SNAP5" \
  --protect-cwd "$SPACE_LIVE_WD" --grace-seconds 3 --json >/dev/null
_assert_alive "live broker with SPACED protected cwd LBS" "$LBS"
_assert_alive "live app-server (spaced cwd) LBSA" "$LBSA"
_assert_alive "broker with NO --cwd (fail-closed) NCB" "$NCB"
_assert_dead "orphan broker spaced EOL cwd OEB" "$OEB"
_assert_dead "orphan app-server (spaced EOL) OEA" "$OEA"
kill "${_pids5[@]}" 2>/dev/null || true

# ---------------------------------------------------------------------------
smoke_log "D: daemon wires the periodic pass + standalone subcommand; #68 gates the verb"
grep -q 'process_codex_app_server_reaper' "$DAEMON_SH" || \
  smoke_fail "bridge-daemon.sh does not define/wire the periodic reaper pass"
grep -q 'codex_app_server_reaper' "$DAEMON_SH" || \
  smoke_fail "bridge-daemon.sh missing the cadence-gated pass key"
grep -q 'reap-codex-orphans)' "$DAEMON_SH" || \
  smoke_fail "bridge-daemon.sh missing the reap-codex-orphans dispatch verb"
grep -q 'cmd_reap_codex_orphans' "$DAEMON_SH" || \
  smoke_fail "bridge-daemon.sh missing the standalone CLI handler"
grep -q 'reap-codex-orphans' "$LIB_SH" || \
  smoke_fail "bridge-lib.sh #68 verdict does not gate reap-codex-orphans"
# The pass invokes the helper through the BRIDGE_SCRIPT_DIR-guarded wrapper.
grep -q 'bridge_daemon_helper_python codex-app-server-reaper' "$DAEMON_SH" || \
  smoke_fail "reaper pass does not invoke the helper via bridge_daemon_helper_python"

# No new heredoc-stdin introduced (footgun #11 / heredoc-ban ratchet).
if [[ -x "$SMOKE_REPO_ROOT/scripts/lint-heredoc-ban.sh" ]]; then
  bash "$SMOKE_REPO_ROOT/scripts/lint-heredoc-ban.sh" >/dev/null 2>&1 || \
    smoke_fail "lint-heredoc-ban regressed — a new heredoc-stdin site was introduced"
fi

smoke_log "PASS: $SMOKE_NAME"
