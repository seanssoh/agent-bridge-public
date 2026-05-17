#!/usr/bin/env bash
# Regression smoke — bridge-daemon.sh + lib/bridge-cron.sh have no
# remaining heredoc-stdin subprocess sites (footgun #11 Bash 5.3.9
# `read_comsub` / `heredoc_write` deadlock).
#
# Background (refs queue task #4807, 2026-05-17 / 2026-05-18):
#   Operator host accumulated 7 zombie daemon processes + 2 cron-workers
#   hung 13h on the same task_id. `sample <pid>` showed the familiar
#   `reader_loop → read_comsub → read` stack — same footgun #11 class
#   that the v0.13.7-9 upgrader chain and the PR #940 agent-CLI wave
#   already migrated out for their respective code paths. Five
#   bridge-daemon.sh sites (datetime format, release-alert body, stall
#   excerpt + audits, watchdog problem key, plus the two latent sites
#   in start_cron_worker and the queue-gateway socket probe) and
#   thirteen lib/bridge-cron.sh sites (slot derivation, manifest /
#   request / status writers, completion + followup body builders, two
#   task-id atomic rewrites, actions audit, always-followup metadata
#   read) all carried the same heredoc-stdin trip surface. Each was
#   migrated to a standalone helper invoked with file-as-argv (no
#   heredoc-stdin anywhere) under lib/daemon-helpers/ and
#   lib/cron-helpers/. This smoke is the regression guard.
#
# Coverage:
#   C1 — source-level grep self-audit: bridge-daemon.sh +
#        lib/bridge-cron.sh contain zero non-comment heredoc-stdin
#        subprocess lines. Re-running `lint-heredoc-ban.sh` would
#        also catch a regression, but C1 spells out the exact
#        non-comment grep so any failure points at the offending line.
#   C2 — helper directories exist and every `.py` parses. Catches
#        accidental deletion or copy-paste typos in a helper body.
#   C3 — round-trip the most-trafficked helpers against synthetic
#        inputs to confirm the file-as-argv contract still produces
#        the expected outputs (slot string, manifest JSON, status
#        JSON, task-id rewrite). The deeper write-request.py (44
#        argv) is exercised end-to-end through the call site in
#        bridge_cron_write_request when the operator runs an actual
#        cron dispatch — out of scope for this smoke.
#   C4 — call-site discipline: bridge-daemon.sh + lib/bridge-cron.sh
#        invoke the helpers via `$SCRIPT_DIR` / `$BRIDGE_SCRIPT_DIR`
#        path interpolation (NOT a brittle relative path), so the
#        helpers resolve correctly when the daemon is launched from
#        anywhere.
#
# NOT covered here:
#   The pre-existing operator host repro (concurrent daemon-status +
#   cron-dispatch + cron-worker spawn under load) is a multi-process
#   race that this smoke cannot replicate deterministically without a
#   running tmux + queue + daemon stack. Manual repro per the task
#   body is the integration check; this smoke is the structural one.

set -uo pipefail

SMOKE_NAME="bridge-daemon-cron-no-deadlock"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

smoke_require_cmd python3
smoke_require_cmd grep

DAEMON_SCRIPT="$REPO_ROOT/bridge-daemon.sh"
CRON_SCRIPT="$REPO_ROOT/lib/bridge-cron.sh"
DAEMON_HELPERS="$REPO_ROOT/lib/daemon-helpers"
CRON_HELPERS="$REPO_ROOT/lib/cron-helpers"

smoke_assert_file_exists "$DAEMON_SCRIPT" "bridge-daemon.sh source"
smoke_assert_file_exists "$CRON_SCRIPT" "lib/bridge-cron.sh source"

# C1 — heredoc-stdin self-audit. `grep -E` is the exact contract from
# scripts/lint-heredoc-ban.sh; comment-only lines are excluded so the
# audit-trail comment in bridge-daemon.sh:1038 ("moved out of `python3 -
# <<'PY'`") does not trip the assertion.
smoke_log "C1: bridge-daemon.sh + lib/bridge-cron.sh contain zero non-comment heredoc-stdin subprocess lines"
danger_pattern='(bash[[:space:]]+-s|python3[[:space:]]+-)[[:space:]].*<<-?["'"'"']?(EOF|PY)["'"'"']?'
comment_prefix='^[0-9]+:[[:space:]]*#'

for target in "$DAEMON_SCRIPT" "$CRON_SCRIPT"; do
  hits="$(grep -nE "$danger_pattern" "$target" 2>/dev/null \
          | grep -vE "$comment_prefix" || true)"
  if [[ -n "$hits" ]]; then
    smoke_log "C1 $(basename "$target") still has heredoc-stdin lines:"
    printf '%s\n' "$hits" | sed 's/^/  /'
    smoke_fail "C1: $(basename "$target") reintroduced a heredoc-stdin site"
  fi
done
smoke_log "C1 PASS — 0 non-comment heredoc-stdin sites in bridge-daemon.sh + lib/bridge-cron.sh"

# C2 — helper dirs exist + every .py parses (ast.parse).
smoke_log "C2: lib/daemon-helpers/*.py + lib/cron-helpers/*.py all parse"
if [[ ! -d "$DAEMON_HELPERS" ]]; then
  smoke_fail "C2: missing helper dir $DAEMON_HELPERS"
fi
if [[ ! -d "$CRON_HELPERS" ]]; then
  smoke_fail "C2: missing helper dir $CRON_HELPERS"
fi

daemon_count=0
cron_count=0
for h in "$DAEMON_HELPERS"/*.py; do
  [[ -f "$h" ]] || continue
  daemon_count=$((daemon_count + 1))
  if ! python3 -c "import ast; ast.parse(open('$h').read())" 2>/dev/null; then
    smoke_fail "C2: $h failed to parse"
  fi
done
for h in "$CRON_HELPERS"/*.py; do
  [[ -f "$h" ]] || continue
  cron_count=$((cron_count + 1))
  if ! python3 -c "import ast; ast.parse(open('$h').read())" 2>/dev/null; then
    smoke_fail "C2: $h failed to parse"
  fi
done
if (( daemon_count == 0 )); then
  smoke_fail "C2: lib/daemon-helpers/ contains no .py files"
fi
if (( cron_count == 0 )); then
  smoke_fail "C2: lib/cron-helpers/ contains no .py files"
fi
smoke_log "C2 PASS — $daemon_count daemon helpers + $cron_count cron helpers all parse"

# C3 — round-trip the most-trafficked helpers. The smaller helpers cover
# the hot daemon-status / cron-dispatch paths; the deeper write-request
# (44 argv) and write-manifest (25 argv) helpers are exercised by the
# end-to-end cron dispatch path itself.
smoke_log "C3: round-trip the hot helpers against synthetic inputs"
c3_dir="$SMOKE_TMP_ROOT/c3"
mkdir -p "$c3_dir"

# C3.1 — daemon: format-epoch-iso
epoch_iso="$(python3 "$DAEMON_HELPERS/format-epoch-iso.py" 1700000000 2>&1)"
case "$epoch_iso" in
  20*-*-*T*:*:*) ;;
  *)
    smoke_log "C3.1 unexpected output: $epoch_iso"
    smoke_fail "C3: format-epoch-iso.py did not produce an ISO timestamp"
    ;;
esac

# C3.2 — daemon: stall-decode-excerpt round-trip
encoded="$(printf 'hello\n' | python3 -c 'import base64, sys; print(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"), end="")')"
decoded="$(python3 "$DAEMON_HELPERS/stall-decode-excerpt.py" "$encoded" 2>&1)"
smoke_assert_eq "hello" "$decoded" "C3 stall-decode-excerpt round-trip"

# C3.3 — daemon: watchdog-problem-key produces stable sha256
key_a="$(python3 "$DAEMON_HELPERS/watchdog-problem-key.py" '{"agents":[{"id":"x","heartbeat_age_seconds":5}]}' 2>&1)"
key_b="$(python3 "$DAEMON_HELPERS/watchdog-problem-key.py" '{"agents":[{"id":"x","heartbeat_age_seconds":99}]}' 2>&1)"
if [[ "$key_a" != "$key_b" ]]; then
  smoke_log "C3.3 keys diverged (heartbeat_age_seconds should be excluded):"
  smoke_log "  key_a=$key_a"
  smoke_log "  key_b=$key_b"
  smoke_fail "C3: watchdog-problem-key did not exclude heartbeat_age_seconds"
fi

# C3.4 — cron: slot-from-datetime
slot="$(python3 "$CRON_HELPERS/slot-from-datetime.py" "2026-05-17T08:30:45Z" 2>&1)"
smoke_assert_eq "2026-05-17T08:30+00:00" "$slot" "C3 slot-from-datetime"

# C3.5 — cron: safe-component slug
slug="$(python3 "$CRON_HELPERS/safe-component.py" "memory daily/run #1" 2>&1)"
case "$slug" in
  memory-daily-run-1) ;;
  *)
    smoke_log "C3.5 unexpected slug: $slug"
    smoke_fail "C3: safe-component slug did not match expected shape"
    ;;
esac

# C3.6 — cron: write-status JSON round-trip
status_file="$c3_dir/status.json"
python3 "$CRON_HELPERS/write-status.py" \
  "$status_file" "run-1" "ok" "claude" \
  "/r/req.json" "/r/res.json" "2026-05-17T08:30:00+00:00" "" 2>&1
if ! python3 -c "import json; d=json.load(open('$status_file')); assert d['state']=='ok' and d['run_id']=='run-1' and 'error' not in d" 2>/dev/null; then
  smoke_log "C3.6 status file content:"; cat "$status_file"
  smoke_fail "C3: write-status produced unexpected JSON"
fi

# C3.7 — cron: update-request-task-id atomic rewrite
req_file="$c3_dir/request.json"
printf '%s' '{"run_id":"run-1","dispatch_task_id":0}' >"$req_file"
python3 "$CRON_HELPERS/update-request-task-id.py" "$req_file" 4807 2>&1
if ! python3 -c "import json; d=json.load(open('$req_file')); assert d['dispatch_task_id']==4807 and d['run_id']=='run-1'" 2>/dev/null; then
  smoke_log "C3.7 request file content:"; cat "$req_file"
  smoke_fail "C3: update-request-task-id did not preserve other keys"
fi

# C3.8 — cron: load-run-shell emits the legacy CRON_* env vars
load_dir="$c3_dir/load"
mkdir -p "$load_dir"
printf '%s' '{"run_id":"r","job_id":"j","job_name":"jn","family":"f","slot":"s","target_agent":"ta","target_engine":"te"}' >"$load_dir/request.json"
printf '%s' '{"status":"ok","summary":"all good"}' >"$load_dir/result.json"
printf '%s' '{"state":"completed"}' >"$load_dir/status.json"
load_out="$(python3 "$CRON_HELPERS/load-run-shell.py" "$load_dir/request.json" "$load_dir/result.json" "$load_dir/status.json" 2>&1)"
smoke_assert_contains "$load_out" "CRON_RUN_ID=r" "C3 load-run-shell run-id"
smoke_assert_contains "$load_out" "CRON_RESULT_STATUS=ok" "C3 load-run-shell result-status"
smoke_assert_contains "$load_out" "CRON_RUN_STATE=completed" "C3 load-run-shell run-state"
smoke_assert_contains "$load_out" "CRON_FAILURE_CLASS=admin-resolvable" "C3 load-run-shell failure-class default"

smoke_log "C3 PASS — hot helpers round-trip cleanly"

# C4 — call-site discipline. Every helper invocation in bridge-daemon.sh
# must route through `$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/` (PR #953 r3
# centralized the seven inline `$SCRIPT_DIR` call sites behind the
# `bridge_daemon_helper_python` wrapper, which uses `$BRIDGE_SCRIPT_DIR`
# so the per-call `bridge_resolve_script_dir_check` guard's recovery
# branch — which only rewrites BRIDGE_SCRIPT_DIR — actually changes the
# dispatch target). Every helper invocation in lib/bridge-cron.sh must
# route through `$BRIDGE_SCRIPT_DIR/lib/cron-helpers/` (centralized
# behind `bridge_cron_helper_python` in the same PR). A relative path
# or hard-coded absolute path would re-introduce the operator-host
# runtime drift that the upgrade-helpers / agent-cli-helpers waves
# taught us to avoid.
smoke_log "C4: helper call sites use \$BRIDGE_SCRIPT_DIR interpolation"

# r5 (codex PR #953 r4): positive count must FILTER COMMENTS so explanatory
# comment lines (e.g. "# python3 \"$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/...\"")
# do not inflate the call-site count and let the assertion silently pass
# even after a regression removes all real invocations.
daemon_call_pattern='python3 "\$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/'
daemon_call_count="$(grep -nE "$daemon_call_pattern" "$DAEMON_SCRIPT" \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | wc -l | tr -d '[:space:]')"
if (( daemon_call_count == 0 )); then
  smoke_fail "C4: no helper invocations found in bridge-daemon.sh"
fi

# bridge-daemon.sh must not import a daemon helper via a non-anchored path.
# r5 (codex PR #953 r4): also catch the QUOTED non-anchored form
# python3 "$SOMEVAR/lib/daemon-helpers/..." (e.g. reintroducing $SCRIPT_DIR
# in place of $BRIDGE_SCRIPT_DIR breaks the script-dir guard recovery branch).
if grep -nE 'python3 ("?[^"]*|"\$[^"]*")lib/daemon-helpers/' "$DAEMON_SCRIPT" \
    | grep -vE 'python3 "\$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/' \
    | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
  smoke_log "C4 bridge-daemon.sh has a non-anchored helper invocation:"
  grep -nE 'python3 ("?[^"]*|"\$[^"]*")lib/daemon-helpers/' "$DAEMON_SCRIPT" \
    | grep -vE 'python3 "\$BRIDGE_SCRIPT_DIR/lib/daemon-helpers/' \
    | grep -vE '^[0-9]+:[[:space:]]*#'
  smoke_fail "C4: daemon helper invocation missing \$BRIDGE_SCRIPT_DIR anchor"
fi

cron_call_pattern='python3 "\$BRIDGE_SCRIPT_DIR/lib/cron-helpers/'
cron_call_count="$(grep -nE "$cron_call_pattern" "$CRON_SCRIPT" \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | wc -l | tr -d '[:space:]')"
if (( cron_call_count == 0 )); then
  smoke_fail "C4: no helper invocations found in lib/bridge-cron.sh"
fi

if grep -nE 'python3 ("?[^"]*|"\$[^"]*")lib/cron-helpers/' "$CRON_SCRIPT" \
    | grep -vE 'python3 "\$BRIDGE_SCRIPT_DIR/lib/cron-helpers/' \
    | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null 2>&1; then
  smoke_log "C4 lib/bridge-cron.sh has a non-anchored helper invocation:"
  grep -nE 'python3 ("?[^"]*|"\$[^"]*")lib/cron-helpers/' "$CRON_SCRIPT" \
    | grep -vE 'python3 "\$BRIDGE_SCRIPT_DIR/lib/cron-helpers/' \
    | grep -vE '^[0-9]+:[[:space:]]*#'
  smoke_fail "C4: cron helper invocation missing \$BRIDGE_SCRIPT_DIR anchor"
fi

smoke_log "C4 PASS — $daemon_call_count daemon + $cron_call_count cron helper call sites all anchored"

smoke_log "PASS — bridge-daemon.sh + lib/bridge-cron.sh no longer carry footgun #11 surfaces"
exit 0
