#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/I-beta4-a2a-3-gaps.sh — v0.15.0-beta4 Lane I.
#
# Issue #1262: A2A cross-bridge — 3 gaps preventing first-class
# operator use on fresh installs.
#
#   Gap 1: handoff daemon systemd unit auto-install + onboarding stub.
#          - bridge-init.sh accepts --enable-a2a and, when set, writes
#            $BRIDGE_HOME/handoff.local.json from the bundled example
#            (mode 0600) AND renders the systemd-user unit preview via
#            scripts/install-handoffd-systemd.sh (Linux).
#          - JSON output (--json) carries a top-level `a2a_status` field
#            so bridge-bootstrap.sh / orchestrator can branch on it.
#          - Without --enable-a2a, no scaffold happens (a2a_status =
#            "skipped").
#
#   Gap 2: outbox retry verify. Pre-existing in v0.14.5-beta22 (commit
#          06b84c1). Static-source verification only:
#          - bridge_a2a_common.py: backoff_seconds() with exponential
#            base*2^(attempts-1) up to ceiling, attempts column,
#            next_attempt_ts column.
#          - bridge-a2a.py: _schedule_retry() honors Retry-After header
#            and routes to 'dead' status when attempts >= max_attempts.
#          - bridge-daemon.sh: process_a2a_deliver_tick wires the
#            runner into cmd_sync_cycle.
#
#   Gap 3: outbox stuck alerting.
#          - bridge-daemon.sh: process_a2a_outbox_stuck_scan_tick scans
#            the outbox via `bridge-a2a.py outbox list --json` for
#            rows pending/retry past BRIDGE_A2A_STUCK_ALERT_SECS
#            (default 600s).
#          - Files an admin task with `bridge-task.sh create` per
#            stuck row, dedupe via JSON ledger
#            ($BRIDGE_STATE_DIR/handoff/stuck-alerts.json),
#            re-emit cooldown BRIDGE_A2A_STUCK_ALERT_REEMIT_SECS
#            (default 3600s).
#          - bridge-daemon-helpers.py: a2a-stuck-decide subcommand
#            owns the decision + ledger update (atomic rewrite via
#            tempfile + os.replace).
#
# Coverage matrix:
#   T1 — Gap 1: bridge-init.sh --enable-a2a writes config + advisory,
#        sets a2a_status=ok in JSON output.
#   T2 — Gap 1 teeth: without --enable-a2a, a2a_status stays "skipped"
#        and no config is written.
#   T3 — Gap 2: bridge_a2a_common.py exposes backoff_seconds() with
#        exponential growth + ceiling; outbox schema has `attempts` +
#        `next_attempt_ts` columns; bridge-a2a.py _schedule_retry()
#        exists and routes to 'dead' on max_attempts.
#   T4 — Gap 2: bridge-daemon.sh process_a2a_deliver_tick is wired
#        into cmd_sync_cycle (the runner reaches the outbox).
#   T5 — Gap 3: a2a-stuck-decide helper emits a TSV row for a stuck
#        outbox entry on first call, then emits nothing for the same
#        message_id within the re-emit cooldown.
#   T6 — Gap 3 teeth: after the re-emit cooldown elapses, the same
#        message_id alerts again. Ledger entries for message_ids no
#        longer present in the outbox are pruned.
#
# All assertions are pure static-source greps OR Python-helper unit
# tests (no live daemon required). Behavioral integration with the
# main daemon lives in the existing a2a-cross-bridge.sh + operator-
# host verification.
#
# Footgun #11: no heredoc-stdin to subprocess. All literal patterns use
# single-quoted strings or grep with explicit pattern flags. Helper
# input is passed via tmp file paths, not stdin.

set -uo pipefail

SMOKE_NAME="I-beta4-a2a-3-gaps"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
INIT_SH="$REPO_ROOT/bridge-init.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
HELPERS_PY="$REPO_ROOT/bridge-daemon-helpers.py"
A2A_COMMON_PY="$REPO_ROOT/bridge_a2a_common.py"
A2A_PY="$REPO_ROOT/bridge-a2a.py"
HANDOFFD_SH="$REPO_ROOT/scripts/install-handoffd-systemd.sh"
EXAMPLE_JSON="$REPO_ROOT/handoff.local.example.json"

for f in "$INIT_SH" "$DAEMON_SH" "$HELPERS_PY" "$A2A_COMMON_PY" "$A2A_PY" "$HANDOFFD_SH" "$EXAMPLE_JSON"; do
  [[ -f "$f" ]] || smoke_fail "missing required file: $f"
done

# ---------------------------------------------------------------------
# T1 — Gap 1: bridge-init.sh --enable-a2a flag + scaffold function +
# JSON field present.
# ---------------------------------------------------------------------

smoke_log "T1: bridge-init.sh --enable-a2a flag wiring"

T1_FAILS=""

# T1a — the flag appears in the parser case block.
if ! grep -F -- '--enable-a2a)' "$INIT_SH" >/dev/null; then
  T1_FAILS+="missing --enable-a2a case clause; "
fi

# T1b — the flag is documented in the usage block.
if ! grep -F -- '[--enable-a2a]' "$INIT_SH" >/dev/null; then
  T1_FAILS+="--enable-a2a not in usage line; "
fi

# T1c — bridge_init_scaffold_a2a function exists.
if ! grep -nE '^bridge_init_scaffold_a2a\(\)' "$INIT_SH" >/dev/null; then
  T1_FAILS+="bridge_init_scaffold_a2a() function not defined; "
fi

# T1d — scaffold helper has at least one call site (gate verified in T2c).
# Definition + ≥1 call site = ≥2 non-comment matches.
T1D_CALLS="$(grep -cE 'bridge_init_scaffold_a2a' "$INIT_SH" || true)"
if (( T1D_CALLS < 2 )); then
  T1_FAILS+="bridge_init_scaffold_a2a has no call site (only $T1D_CALLS refs); "
fi

# T1e — JSON output carries a2a_status field.
if ! grep -F '"a2a_status":' "$INIT_SH" >/dev/null; then
  T1_FAILS+="a2a_status field missing from JSON output; "
fi

# T1f — install-handoffd-systemd.sh helper exists and is executable.
if [[ ! -x "$HANDOFFD_SH" ]]; then
  T1_FAILS+="install-handoffd-systemd.sh not executable; "
fi

# T1g — log lines route to stderr (Lane F precedent: stdout reserved for JSON).
if grep -nE '^[[:space:]]+echo "\[init\] --enable-a2a:' "$INIT_SH" \
     | grep -vE '>&2[[:space:]]*$' >/dev/null; then
  T1_FAILS+="scaffold log lines not consistently routed to stderr; "
fi

if [[ -n "$T1_FAILS" ]]; then
  smoke_fail "T1: bridge-init.sh --enable-a2a wiring: $T1_FAILS"
fi
smoke_log "T1 PASS — --enable-a2a flag wired, scaffold function present, JSON a2a_status field present, log lines route to stderr"

# ---------------------------------------------------------------------
# T2 — Gap 1 teeth: scaffold defaults to skipped (no flag = no write).
# ---------------------------------------------------------------------

smoke_log "T2: scaffold defaults to skipped"

T2_FAILS=""

# T2a — `a2a_status` defaults to "skipped" at top-of-file initialization.
if ! grep -E 'a2a_status="skipped"' "$INIT_SH" >/dev/null; then
  T2_FAILS+="a2a_status default literal 'skipped' missing; "
fi

# T2b — `enable_a2a=0` is the default.
if ! grep -E '^enable_a2a=0$' "$INIT_SH" >/dev/null; then
  T2_FAILS+="enable_a2a default 0 missing; "
fi

# T2c — bridge_init_scaffold_a2a is gated by an `if [[ $enable_a2a -eq 1 ]]`
# branch (NOT unconditional). Find any non-definition line referencing
# the function and walk back a few lines looking for the gate.
T2_CALL_LINE="$(grep -nE 'bridge_init_scaffold_a2a' "$INIT_SH" | grep -vE ':[[:space:]]*#' | grep -vE 'bridge_init_scaffold_a2a\(\)' | head -1 | cut -d: -f1)"
if [[ -z "$T2_CALL_LINE" ]]; then
  T2_FAILS+="cannot locate scaffold call site for gate check; "
else
  # Up to five lines up should contain the gate `[[ $enable_a2a -eq 1 ]]`.
  T2_GATE="$(awk -v ln="$T2_CALL_LINE" 'NR >= ln-5 && NR < ln { print }' "$INIT_SH")"
  if ! printf '%s\n' "$T2_GATE" | grep -F '$enable_a2a -eq 1' >/dev/null; then
    T2_FAILS+="scaffold call site not gated by enable_a2a -eq 1 (call line $T2_CALL_LINE); "
  fi
fi

if [[ -n "$T2_FAILS" ]]; then
  smoke_fail "T2: scaffold default-skipped contract: $T2_FAILS"
fi
smoke_log "T2 PASS — defaults are skipped/0; scaffold call is gated"

# ---------------------------------------------------------------------
# T3 — Gap 2 verify: retry primitives in bridge_a2a_common.py + bridge-a2a.py.
# ---------------------------------------------------------------------

smoke_log "T3: Gap 2 (retry) primitives present"

T3_FAILS=""

# T3a — backoff_seconds() exists with exponential growth.
if ! grep -nE '^def backoff_seconds\(' "$A2A_COMMON_PY" >/dev/null; then
  T3_FAILS+="backoff_seconds() missing in bridge_a2a_common.py; "
fi
if ! grep -F 'delay = base * (2 ** max(0, attempts - 1))' "$A2A_COMMON_PY" >/dev/null; then
  T3_FAILS+="backoff_seconds exponential formula missing; "
fi

# T3b — _OUTBOX_SCHEMA carries attempts + next_attempt_ts columns.
if ! grep -F 'attempts            INTEGER NOT NULL DEFAULT 0' "$A2A_COMMON_PY" >/dev/null; then
  T3_FAILS+="outbox schema missing attempts column; "
fi
if ! grep -F 'next_attempt_ts     INTEGER NOT NULL DEFAULT 0' "$A2A_COMMON_PY" >/dev/null; then
  T3_FAILS+="outbox schema missing next_attempt_ts column; "
fi

# T3c — bridge-a2a.py _schedule_retry honors Retry-After and routes to dead.
if ! grep -nE '^def _schedule_retry\(' "$A2A_PY" >/dev/null; then
  T3_FAILS+="_schedule_retry() missing in bridge-a2a.py; "
fi
if ! grep -F "delivery_max_attempts" "$A2A_PY" >/dev/null; then
  T3_FAILS+="delivery_max_attempts policy missing; "
fi
if ! grep -F "status='dead'" "$A2A_PY" >/dev/null; then
  T3_FAILS+="dead-letter routing missing on max attempts; "
fi

# T3d — Retry-After header honored.
if ! grep -F 'Retry-After' "$A2A_PY" >/dev/null; then
  T3_FAILS+="Retry-After header not honored; "
fi

if [[ -n "$T3_FAILS" ]]; then
  smoke_fail "T3: Gap 2 retry primitives: $T3_FAILS"
fi
smoke_log "T3 PASS — backoff_seconds + attempts/next_attempt_ts schema + _schedule_retry + dead-letter on max + Retry-After"

# ---------------------------------------------------------------------
# T4 — Gap 2 verify: process_a2a_deliver_tick wired into cmd_sync_cycle.
# ---------------------------------------------------------------------

smoke_log "T4: process_a2a_deliver_tick wired into daemon sync cycle"

T4_FAILS=""

# T4a — process_a2a_deliver_tick function defined.
if ! grep -nE '^process_a2a_deliver_tick\(\)' "$DAEMON_SH" >/dev/null; then
  T4_FAILS+="process_a2a_deliver_tick() function missing; "
fi

# T4b — called from cmd_sync_cycle (LAST_STEP=a2a_deliver_tick set before call).
if ! grep -F 'BRIDGE_DAEMON_LAST_STEP="a2a_deliver_tick"' "$DAEMON_SH" >/dev/null; then
  T4_FAILS+="cmd_sync_cycle does not set LAST_STEP=a2a_deliver_tick; "
fi
if ! grep -F 'process_a2a_deliver_tick || true' "$DAEMON_SH" >/dev/null; then
  T4_FAILS+="process_a2a_deliver_tick not invoked from cmd_sync_cycle; "
fi

if [[ -n "$T4_FAILS" ]]; then
  smoke_fail "T4: deliver tick wiring: $T4_FAILS"
fi
smoke_log "T4 PASS — deliver tick wired into cmd_sync_cycle"

# ---------------------------------------------------------------------
# T5 — Gap 3: a2a-stuck-decide helper end-to-end.
# ---------------------------------------------------------------------

smoke_log "T5: a2a-stuck-decide emits stuck row + respects cooldown"

# Build a synthetic outbox.json that matches the canonical shape of
# `agb a2a outbox list --json` (per bridge-a2a.py cmd_outbox).
T5_OUTBOX="$SMOKE_TMP_ROOT/outbox.json"
T5_LEDGER="$SMOKE_TMP_ROOT/stuck-alerts.json"
cat >"$T5_OUTBOX" <<'JSON'
[
  {"message_id": "msg-stuck-001", "peer": "bridge-b", "target_agent": "reviewer", "priority": "normal", "status": "retry", "attempts": 3, "next_attempt_ts": 0, "last_error": "transport: peer unreachable", "acked_remote_task_id": null, "created_ts": 1000, "updated_ts": 1100, "lease_expires_ts": 0, "age_seconds": 10000, "due_for_seconds": 9000, "next_attempt_in_seconds": null, "lease_stale_seconds": null},
  {"message_id": "msg-fresh-002", "peer": "bridge-b", "target_agent": "reviewer", "priority": "normal", "status": "pending", "attempts": 0, "next_attempt_ts": 0, "last_error": null, "acked_remote_task_id": null, "created_ts": 999000, "updated_ts": 999000, "lease_expires_ts": 0, "age_seconds": 30, "due_for_seconds": 30, "next_attempt_in_seconds": null, "lease_stale_seconds": null},
  {"message_id": "msg-acked-003", "peer": "bridge-b", "target_agent": "reviewer", "priority": "normal", "status": "acked", "attempts": 1, "next_attempt_ts": 0, "last_error": null, "acked_remote_task_id": "task-42", "created_ts": 500, "updated_ts": 600, "lease_expires_ts": 0, "age_seconds": 100000, "due_for_seconds": null, "next_attempt_in_seconds": null, "lease_stale_seconds": null},
  {"message_id": "msg-dead-004", "peer": "bridge-b", "target_agent": "reviewer", "priority": "normal", "status": "dead", "attempts": 12, "next_attempt_ts": 0, "last_error": "max attempts (12): HTTP 401", "acked_remote_task_id": null, "created_ts": 500, "updated_ts": 600, "lease_expires_ts": 0, "age_seconds": 100000, "due_for_seconds": null, "next_attempt_in_seconds": null, "lease_stale_seconds": null}
]
JSON
printf '{}\n' >"$T5_LEDGER"

# T5a — first call: emit the stuck row only.
T5_OUT1="$(python3 "$HELPERS_PY" a2a-stuck-decide 1000000 600 3600 "$T5_LEDGER" "$T5_OUTBOX" 2>&1 || true)"
if ! printf '%s' "$T5_OUT1" | grep -F 'msg-stuck-001' >/dev/null; then
  smoke_fail "T5a: helper did not emit stuck row (output: $T5_OUT1)"
fi
# Fresh row not emitted (age < threshold).
if printf '%s' "$T5_OUT1" | grep -F 'msg-fresh-002' >/dev/null; then
  smoke_fail "T5a: helper incorrectly emitted fresh row (age < stuck_secs)"
fi
# Acked row not emitted (status != pending/retry).
if printf '%s' "$T5_OUT1" | grep -F 'msg-acked-003' >/dev/null; then
  smoke_fail "T5a: helper incorrectly emitted acked row"
fi
# Dead row not emitted (status == dead, separate signal).
if printf '%s' "$T5_OUT1" | grep -F 'msg-dead-004' >/dev/null; then
  smoke_fail "T5a: helper incorrectly emitted dead row"
fi

# T5b — ledger updated with last-emit timestamp.
if ! grep -F '"msg-stuck-001": 1000000' "$T5_LEDGER" >/dev/null; then
  smoke_fail "T5b: ledger missing emit ts for msg-stuck-001 (ledger: $(cat "$T5_LEDGER"))"
fi

# T5c — second call within cooldown (60s later, cooldown is 3600s): no emit.
T5_OUT2="$(python3 "$HELPERS_PY" a2a-stuck-decide 1000060 600 3600 "$T5_LEDGER" "$T5_OUTBOX" 2>&1 || true)"
if [[ -n "$T5_OUT2" ]]; then
  smoke_fail "T5c: helper emitted within cooldown (output: $T5_OUT2)"
fi

smoke_log "T5 PASS — stuck row emitted, fresh/acked/dead suppressed, cooldown honored"

# ---------------------------------------------------------------------
# T6 — Gap 3 teeth: cooldown expiry re-emits; ledger pruning.
# ---------------------------------------------------------------------

smoke_log "T6: cooldown expiry re-emits + ledger pruning"

T6_FAILS=""

# T6a — same row 3700s later (past 3600s cooldown): emits again.
T6_OUT1="$(python3 "$HELPERS_PY" a2a-stuck-decide 1003700 600 3600 "$T5_LEDGER" "$T5_OUTBOX" 2>&1 || true)"
if ! printf '%s' "$T6_OUT1" | grep -F 'msg-stuck-001' >/dev/null; then
  T6_FAILS+="cooldown-expiry re-emit failed (output: $T6_OUT1); "
fi
# Ledger should be re-stamped to 1003700.
if ! grep -F '"msg-stuck-001": 1003700' "$T5_LEDGER" >/dev/null; then
  T6_FAILS+="ledger not re-stamped after cooldown re-emit; "
fi

# T6b — ledger pruning. Construct a smaller outbox (msg-stuck-001 gone)
# and confirm the ledger entry is pruned on next decide call.
T6_OUTBOX_DROP="$SMOKE_TMP_ROOT/outbox-dropped.json"
cat >"$T6_OUTBOX_DROP" <<'JSON'
[
  {"message_id": "msg-fresh-002", "peer": "bridge-b", "target_agent": "reviewer", "priority": "normal", "status": "pending", "attempts": 0, "next_attempt_ts": 0, "last_error": null, "acked_remote_task_id": null, "created_ts": 999000, "updated_ts": 999000, "lease_expires_ts": 0, "age_seconds": 30, "due_for_seconds": 30, "next_attempt_in_seconds": null, "lease_stale_seconds": null}
]
JSON
python3 "$HELPERS_PY" a2a-stuck-decide 1010000 600 3600 "$T5_LEDGER" "$T6_OUTBOX_DROP" >/dev/null 2>&1 || true
if grep -F 'msg-stuck-001' "$T5_LEDGER" >/dev/null; then
  T6_FAILS+="ledger did not prune msg-stuck-001 after it dropped from outbox; "
fi

# T6c — daemon-side function presence + wiring.
if ! grep -nE '^process_a2a_outbox_stuck_scan_tick\(\)' "$DAEMON_SH" >/dev/null; then
  T6_FAILS+="process_a2a_outbox_stuck_scan_tick() function missing; "
fi
if ! grep -F 'BRIDGE_DAEMON_LAST_STEP="a2a_stuck_scan_tick"' "$DAEMON_SH" >/dev/null; then
  T6_FAILS+="cmd_sync_cycle does not set LAST_STEP=a2a_stuck_scan_tick; "
fi
if ! grep -F 'process_a2a_outbox_stuck_scan_tick || true' "$DAEMON_SH" >/dev/null; then
  T6_FAILS+="stuck scan tick not invoked from cmd_sync_cycle; "
fi
# T6d — audit row name `a2a_outbox_stuck_alert_emitted` present.
if ! grep -F 'a2a_outbox_stuck_alert_emitted' "$DAEMON_SH" >/dev/null; then
  T6_FAILS+="audit row a2a_outbox_stuck_alert_emitted missing; "
fi
# T6e — admin task creation via target_bridge task create.
if ! grep -F '"$target_bridge" task create' "$DAEMON_SH" >/dev/null; then
  T6_FAILS+="stuck scan does not create admin task via target_bridge; "
fi

if [[ -n "$T6_FAILS" ]]; then
  smoke_fail "T6: $T6_FAILS"
fi

smoke_log "T6 PASS — cooldown expiry re-emits, ledger prunes dropped rows, daemon wiring intact"

# ---------------------------------------------------------------------
# Teeth — verify the helper truly fails to emit when key field is wrong.
# ---------------------------------------------------------------------

smoke_log "Teeth: assertion bites on mutated input"

# Synthetic regression: revert the stuck row's status from 'retry' to 'sending'.
# The helper should now NOT emit anything (sending = runner-active, not stuck).
T7_OUTBOX="$SMOKE_TMP_ROOT/outbox-mutated.json"
T7_LEDGER="$SMOKE_TMP_ROOT/stuck-alerts-mutated.json"
printf '{}\n' >"$T7_LEDGER"
sed 's/"status": "retry"/"status": "sending"/' "$T5_OUTBOX" >"$T7_OUTBOX"
T7_OUT="$(python3 "$HELPERS_PY" a2a-stuck-decide 1000000 600 3600 "$T7_LEDGER" "$T7_OUTBOX" 2>&1 || true)"
if printf '%s' "$T7_OUT" | grep -F 'msg-stuck-001' >/dev/null; then
  smoke_fail "teeth: helper emitted msg-stuck-001 with status=sending (should be excluded — teeth missing)"
fi

# Synthetic regression: drop age_seconds below threshold.
T8_OUTBOX="$SMOKE_TMP_ROOT/outbox-fresh.json"
T8_LEDGER="$SMOKE_TMP_ROOT/stuck-alerts-fresh.json"
printf '{}\n' >"$T8_LEDGER"
sed 's/"age_seconds": 10000/"age_seconds": 100/' "$T5_OUTBOX" >"$T8_OUTBOX"
# Also drop created_ts so the fallback can't bring age back over threshold.
sed -i.bak 's/"created_ts": 1000/"created_ts": 999900/' "$T8_OUTBOX"
rm -f "$T8_OUTBOX.bak"
T8_OUT="$(python3 "$HELPERS_PY" a2a-stuck-decide 1000000 600 3600 "$T8_LEDGER" "$T8_OUTBOX" 2>&1 || true)"
if printf '%s' "$T8_OUT" | grep -F 'msg-stuck-001' >/dev/null; then
  smoke_fail "teeth: helper emitted msg-stuck-001 with age=100 (should be excluded — teeth missing)"
fi

smoke_log "Teeth PASS — mutated status='sending' and age<threshold both correctly suppress emit"

smoke_log "all tests PASS — Lane I (#1262 Gap 1 + Gap 2 verify + Gap 3) verified at current source"
