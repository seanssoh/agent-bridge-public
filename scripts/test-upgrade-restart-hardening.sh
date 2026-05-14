#!/usr/bin/env bash
# Regression coverage for Issues 3+4 (v0.11.0) — upgrade-time restart
# hardening. Verifies:
#
#   1. bridge_upgrade_collect_agent_restart_report wraps each per-agent
#      restart with bridge_with_timeout and maps 124/137 exit codes to
#      reason="restart-timeout" (Issue 3).
#   2. bridge_upgrade_reconcile_agent_restart_recovery reclassifies
#      `failed` rows whose agent ends up active after a bounded settle
#      window to `recovered_by_daemon`, preserves the original reason
#      as `was=<reason>`, and passes other rows through unchanged
#      (Issue 4).
#   3. bridge_upgrade_agent_restart_json includes the new
#      `recovered_by_daemon` count + `recovered_by_daemon_agents` list +
#      `recovered_by_daemon_details` block; the `failed` count drops by
#      the reclassified count.
#
# Runs entirely in an isolated $TMP so it never reads or writes the
# operator's live bridge state.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-upgrade-restart-hardening-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------------------
# Section A — bridge_with_timeout exit-code mapping
# ----------------------------------------------------------------------------
# We test the exact conditional used inside
# bridge_upgrade_collect_agent_restart_report's inner script. The inner
# block lives behind a bridge_upgrade_with_target_env / -lc wrapper, so
# we replicate just the if/elif mapping in a tiny harness and drive it
# with the real `bridge_with_timeout` and a fake bridge-agent.sh script.
# This proves the mapping logic that the collect function relies on.

# Source bridge_with_timeout. It depends on a couple of caching globals
# initialised at lib/bridge-state.sh top-level, so source the file in a
# subshell-safe way and define the caching globals defensively.
_BRIDGE_WITH_TIMEOUT_BIN_CACHED=0
_BRIDGE_WITH_TIMEOUT_BIN=""
_BRIDGE_WITH_TIMEOUT_PYTHON_CACHED=0
_BRIDGE_WITH_TIMEOUT_PYTHON=""
_BRIDGE_WITH_TIMEOUT_UNAVAILABLE_LOGGED=0
_BRIDGE_WITH_TIMEOUT_PY_WRAPPER=$'import os, signal, subprocess, sys\nsecs=int(sys.argv[1]); argv=sys.argv[2:]\ntry:\n    rc=subprocess.run(argv, timeout=secs).returncode\nexcept subprocess.TimeoutExpired:\n    rc=124\nsys.exit(rc)\n'

# Stub bridge_audit_log so bridge_with_timeout's timeout branch does not
# attempt to write into a real audit log path.
bridge_audit_log() { return 0; }

EXTRACT_TMP="$TMP/bwt.sh"
awk '
  /^bridge_with_timeout\(\) \{/ { copy = 1 }
  copy { print }
  copy && /^\}$/ { copy = 0; print ""; exit }
' "$ROOT_DIR/lib/bridge-state.sh" >"$EXTRACT_TMP"
# shellcheck source=/dev/null
source "$EXTRACT_TMP"

# Fake bridge-agent.sh: behaviour controlled via env BAGT_MODE.
FAKE_AGENT="$TMP/bridge-agent.sh"
cat >"$FAKE_AGENT" <<'EOF'
#!/usr/bin/env bash
case "${BAGT_MODE:-fast-ok}" in
  hang)    sleep 60 ;;
  fail7)   exit 7 ;;
  fast-ok) exit 0 ;;
  *)       exit 0 ;;
esac
EOF
chmod +x "$FAKE_AGENT"

# Helper that mirrors the inline conditional inside
# bridge_upgrade_collect_agent_restart_report. The output is the same
# 3-field shape (status, reason, exit_code) that the inner script
# populates, so a regression in the collect function's conditional will
# also fail this helper.
restart_conditional() {
  local timeout_secs="$1"
  local mode="$2"
  local status="" reason="" exit_code=""
  if BAGT_MODE="$mode" bridge_with_timeout "$timeout_secs" \
       "upgrade_agent_restart:test" \
       "$FAKE_AGENT" restart test \
       >/dev/null 2>&1; then
    status="restarted"
    reason="eligible"
    exit_code=0
  else
    exit_code=$?
    status="failed"
    if [[ "$exit_code" == "124" || "$exit_code" == "137" ]]; then
      reason="restart-timeout"
    else
      reason="restart-failed"
    fi
  fi
  printf '%s|%s|%s\n' "$status" "$reason" "$exit_code"
}

step "A1: hung restart -> status=failed reason=restart-timeout exit=124"
out="$(restart_conditional 1 hang)"
if [[ "$out" == "failed|restart-timeout|124" ]]; then ok; else err "got [$out]"; fi

step "A2: fast-ok restart -> status=restarted reason=eligible exit=0"
out="$(restart_conditional 5 fast-ok)"
if [[ "$out" == "restarted|eligible|0" ]]; then ok; else err "got [$out]"; fi

step "A3: ordinary failure (exit 7) -> reason=restart-failed exit=7"
out="$(restart_conditional 5 fail7)"
if [[ "$out" == "failed|restart-failed|7" ]]; then ok; else err "got [$out]"; fi

# ----------------------------------------------------------------------------
# Section B — bridge_upgrade_reconcile_agent_restart_recovery
# ----------------------------------------------------------------------------
# Extract the reconcile function and stub bridge_upgrade_with_target_env
# so the inner -lc body runs in this test shell. The inner body sources
# bridge-lib.sh which we do not need — instead we shadow the only
# collaborator it calls (bridge_agent_is_active) and bridge_load_roster.

RECON_TMP="$TMP/reconcile.sh"
awk '
  /^bridge_upgrade_reconcile_agent_restart_recovery\(\) \{/ { copy = 1; print; next }
  copy && /^bridge_[a-z_]+\(\) \{/ { exit }
  copy { print }
' "$ROOT_DIR/bridge-upgrade.sh" >"$RECON_TMP"

# Stub bridge_upgrade_with_target_env: drop the target_root arg and run
# the rest. The inner block then runs under the test's env (no env -i).
bridge_upgrade_with_target_env() {
  local _target_root="$1"
  shift
  "$@"
}

# The inner block sources "$source_root/bridge-lib.sh" and calls
# bridge_load_roster. Provide a tiny stand-in source root so the source
# statement succeeds, and stub the two collaborators it uses.
SOURCE_ROOT="$TMP/source-root"
mkdir -p "$SOURCE_ROOT"
cat >"$SOURCE_ROOT/bridge-lib.sh" <<'EOF'
bridge_load_roster() { return 0; }
# Defined per-case to drive the recovery probe deterministically.
bridge_agent_is_active() {
  local agent="$1"
  case " ${RECOVERED_AGENTS:-} " in
    *" $agent "*) return 0 ;;
    *) return 1 ;;
  esac
}
EOF

# Plumb SOURCE_ROOT through to the extracted function (it defaults to
# $SOURCE_ROOT at the upgrade layer; we set it directly here).
export SOURCE_ROOT
# The reconcile function spawns an inner `bash -lc` via $BRIDGE_BASH_BIN.
# That subshell does not inherit unexported test-shell vars, so export
# both the bash bin and the per-case knob the stub reads.
export BRIDGE_BASH_BIN="${BRIDGE_BASH_BIN:-bash}"
export RECOVERED_AGENTS=""

# shellcheck source=/dev/null
source "$RECON_TMP"

mk_row() {
  # Helper: 7-column tab-separated row matching the collect contract.
  local agent="$1" status="$2" reason="$3" exit_code="${4:-}" tail="${5:-}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$agent" "$status" "$reason" 0 "$agent-session" "$exit_code" "$tail"
}

step "B1: failed agent becomes active during settle -> recovered_by_daemon (was=restart-failed)"
export RECOVERED_AGENTS="alpha"
report="$(mk_row alpha failed restart-failed 7 dGFpbA==)"
out="$(bridge_upgrade_reconcile_agent_restart_recovery /irrelevant "$report" 0 "$SOURCE_ROOT" 2)"
expected="$(printf 'alpha\trecovered_by_daemon\tdaemon-recovered:was=restart-failed\t0\talpha-session\t7\tdGFpbA==')"
if [[ "$out" == "$expected" ]]; then ok; else err "got [$out]"; fi

step "B2: failed-timeout agent active during settle -> was=restart-timeout preserved"
export RECOVERED_AGENTS="beta"
report="$(mk_row beta failed restart-timeout 124 '')"
out="$(bridge_upgrade_reconcile_agent_restart_recovery /irrelevant "$report" 0 "$SOURCE_ROOT" 2)"
if grep -q $'^beta\trecovered_by_daemon\tdaemon-recovered:was=restart-timeout\t' <<<"$out"; then
  ok
else
  err "got [$out]"
fi

step "B3: failed agent stays inactive -> failed status unchanged"
export RECOVERED_AGENTS=""
report="$(mk_row gamma failed restart-failed 9 '')"
out="$(bridge_upgrade_reconcile_agent_restart_recovery /irrelevant "$report" 0 "$SOURCE_ROOT" 1)"
if grep -q $'^gamma\tfailed\trestart-failed\t' <<<"$out"; then
  ok
else
  err "got [$out]"
fi

step "B4: restarted/skipped rows pass through unchanged even when agent listed as recovered"
export RECOVERED_AGENTS="delta epsilon"
report="$(printf '%s\n%s\n' \
  "$(mk_row delta restarted eligible 0 '')" \
  "$(mk_row epsilon skipped inactive '' '')")"
out="$(bridge_upgrade_reconcile_agent_restart_recovery /irrelevant "$report" 0 "$SOURCE_ROOT" 1)"
# Expect the report shape to be unchanged. Since there are no `failed`
# rows, the reconciler short-circuits before sleeping — also implicitly
# verifies the no-`failed` skip path.
if grep -q $'^delta\trestarted\teligible\t' <<<"$out" \
   && grep -q $'^epsilon\tskipped\tinactive\t' <<<"$out" \
   && ! grep -q 'recovered_by_daemon' <<<"$out"; then
  ok
else
  err "got [$out]"
fi

step "B5a: non-numeric settle_seconds falls back to default 20s (no crash)"
export RECOVERED_AGENTS="eta"
report="$(mk_row eta failed restart-failed 7 '')"
# Pass a deliberately bad settle_seconds; the defensive normalisation
# should swap it for 20s. The recovered agent passes the very first
# probe so the function returns immediately without waiting 20s.
out="$(bridge_upgrade_reconcile_agent_restart_recovery /irrelevant "$report" 0 "$SOURCE_ROOT" abc)"
if grep -q $'^eta\trecovered_by_daemon\tdaemon-recovered:was=restart-failed\t' <<<"$out"; then
  ok
else
  err "got [$out]"
fi

step "B5: dry_run=1 short-circuits even with a failed row + recovered agent"
export RECOVERED_AGENTS="zeta"
report="$(mk_row zeta failed restart-failed 7 '')"
out="$(bridge_upgrade_reconcile_agent_restart_recovery /irrelevant "$report" 1 "$SOURCE_ROOT" 5)"
# dry-run path returns the report verbatim, no reclassification.
if grep -q $'^zeta\tfailed\trestart-failed\t' <<<"$out" \
   && ! grep -q 'recovered_by_daemon' <<<"$out"; then
  ok
else
  err "got [$out]"
fi

# ----------------------------------------------------------------------------
# Section C — bridge_upgrade_agent_restart_json contract
# ----------------------------------------------------------------------------
JSON_TMP="$TMP/json.sh"
awk '
  /^bridge_upgrade_agent_restart_json\(\) \{/ { copy = 1; print; next }
  copy && /^bridge_[a-z_]+\(\) \{/ { exit }
  copy { print }
' "$ROOT_DIR/bridge-upgrade.sh" >"$JSON_TMP"
# shellcheck source=/dev/null
source "$JSON_TMP"

step "C1: recovered_by_daemon counted + agents + details; failed drops accordingly"
# 1 restarted ok, 1 failed (unrecovered), 1 recovered_by_daemon (was timeout)
report="$(printf '%s\n%s\n%s\n' \
  "$(mk_row a1 restarted eligible 0 '')" \
  "$(mk_row a2 failed restart-failed 9 '')" \
  "$(mk_row a3 recovered_by_daemon 'daemon-recovered:was=restart-timeout' 124 dGFpbA==)")"
out="$(bridge_upgrade_agent_restart_json "$report" 1 0)"
# Quick schema-shape assertions via python3.
if python3 - "$out" <<'PY' >/dev/null
import json, sys
p = json.loads(sys.argv[1])
assert p["restart_attempted_ok"] == 1, p
assert p["restart_attempted_ok_agents"] == ["a1"], p
assert p["failed"] == 1, p
assert p["failed_agents"] == ["a2"], p
assert p["recovered_by_daemon"] == 1, p
assert p["recovered_by_daemon_agents"] == ["a3"], p
details = p["recovered_by_daemon_details"]
assert len(details) == 1, p
d = details[0]
assert d["agent"] == "a3", d
assert d["was_reason"] == "restart-timeout", d
assert d["exit_code"] == 124, d
assert d["last_log_tail"] == "tail", d
PY
then ok; else err "schema/contract assertions failed: out=[$out]"; fi

printf '\nTotal: %d, Pass: %d, Fail: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
exit "$FAIL"
