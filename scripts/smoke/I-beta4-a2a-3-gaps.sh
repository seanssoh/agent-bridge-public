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
# Issue #1338 wrapped the deliver-tick call in a defense-in-depth subshell:
# `( process_a2a_deliver_tick ) || true` (matching the sibling
# start_cron_dispatch_workers / process_a2a_outbox_stuck_scan_tick calls).
# Accept either the bare or subshell-wrapped invocation so this assertion
# tracks the wiring (tick runs each sync cycle) rather than the exact
# syntax. Anchor to the start of an executable line (`^[[:space:]]*` with
# the call token immediately after) so a commented-out or echo'd mention
# (e.g. `# ( process_a2a_deliver_tick ) || true`) does NOT satisfy it —
# deleting OR commenting the real wiring must still trip the assertion.
if ! grep -Eq '^[[:space:]]*\(?[[:space:]]*process_a2a_deliver_tick[[:space:]]*\)?[[:space:]]*\|\|[[:space:]]*true' "$DAEMON_SH"; then
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

# v0.15.0-beta4 Lane I r2 (codex r1 BLOCKING): decide is now pure
# read — does NOT modify ledger. Confirm that property before we run
# ack.
if grep -F 'msg-stuck-001' "$T5_LEDGER" >/dev/null; then
  smoke_fail "T5a-purity: decide unexpectedly stamped ledger (ledger: $(cat "$T5_LEDGER"))"
fi

# T5b — daemon shell now follows up with a-stuck-ack ONLY for rows
# whose admin task was filed successfully. Simulate the all-success
# path: feed every emitted message_id back to ack.
T5_ACK_KEYS="$SMOKE_TMP_ROOT/ack-keys-t5.txt"
printf '%s' "$T5_OUT1" | awk -F'\t' 'NF{print $1}' >"$T5_ACK_KEYS"
python3 "$HELPERS_PY" a2a-stuck-ack 1000000 "$T5_LEDGER" "$T5_ACK_KEYS" "$T5_OUTBOX" >/dev/null 2>&1 || true
if ! grep -F '"msg-stuck-001": 1000000' "$T5_LEDGER" >/dev/null; then
  smoke_fail "T5b: ack did not stamp ledger for msg-stuck-001 (ledger: $(cat "$T5_LEDGER"))"
fi

# T5c — second decide within cooldown (60s later, cooldown is 3600s):
# no emit, regardless of whether shell calls ack again.
T5_OUT2="$(python3 "$HELPERS_PY" a2a-stuck-decide 1000060 600 3600 "$T5_LEDGER" "$T5_OUTBOX" 2>&1 || true)"
if [[ -n "$T5_OUT2" ]]; then
  smoke_fail "T5c: helper emitted within cooldown (output: $T5_OUT2)"
fi

smoke_log "T5 PASS — stuck row emitted, fresh/acked/dead suppressed, cooldown honored, ack stamps only on follow-up"

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
# v0.15.0-beta4 Lane I r2 (codex r1 BLOCKING): decide does NOT stamp
# the ledger. Simulate successful follow-up ack and verify re-stamp.
T6_ACK_KEYS="$SMOKE_TMP_ROOT/ack-keys-t6.txt"
printf '%s' "$T6_OUT1" | awk -F'\t' 'NF{print $1}' >"$T6_ACK_KEYS"
python3 "$HELPERS_PY" a2a-stuck-ack 1003700 "$T5_LEDGER" "$T6_ACK_KEYS" "$T5_OUTBOX" >/dev/null 2>&1 || true
if ! grep -F '"msg-stuck-001": 1003700' "$T5_LEDGER" >/dev/null; then
  T6_FAILS+="ledger not re-stamped after cooldown re-emit + ack; "
fi

# T6b — ledger pruning. Construct a smaller outbox (msg-stuck-001 gone)
# and confirm the ledger entry is pruned on next ack call (decide is
# pure read; pruning now lives in ack).
T6_OUTBOX_DROP="$SMOKE_TMP_ROOT/outbox-dropped.json"
cat >"$T6_OUTBOX_DROP" <<'JSON'
[
  {"message_id": "msg-fresh-002", "peer": "bridge-b", "target_agent": "reviewer", "priority": "normal", "status": "pending", "attempts": 0, "next_attempt_ts": 0, "last_error": null, "acked_remote_task_id": null, "created_ts": 999000, "updated_ts": 999000, "lease_expires_ts": 0, "age_seconds": 30, "due_for_seconds": 30, "next_attempt_in_seconds": null, "lease_stale_seconds": null}
]
JSON
# Empty ack-keys file — ack is still called every tick for pruning.
T6_ACK_EMPTY="$SMOKE_TMP_ROOT/ack-keys-empty.txt"
: >"$T6_ACK_EMPTY"
python3 "$HELPERS_PY" a2a-stuck-ack 1010000 "$T5_LEDGER" "$T6_ACK_EMPTY" "$T6_OUTBOX_DROP" >/dev/null 2>&1 || true
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
# Issue #1338 wrapped the stuck-scan-tick call in a defense-in-depth subshell:
# `( process_a2a_outbox_stuck_scan_tick ) || true` (same pattern as the
# deliver-tick T4 assertion above). Accept either the bare or subshell-
# wrapped invocation so this tracks the wiring rather than the exact
# syntax. Anchored to the start of an executable line (see T4) so a
# commented-out/echo'd mention does NOT satisfy the assertion.
if ! grep -Eq '^[[:space:]]*\(?[[:space:]]*process_a2a_outbox_stuck_scan_tick[[:space:]]*\)?[[:space:]]*\|\|[[:space:]]*true' "$DAEMON_SH"; then
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
# T6f — v0.15.0-beta4 Lane I r2 (codex r1 BLOCKING) wiring: daemon
# follows up with a2a-stuck-ack helper after the task-create loop,
# and that helper is registered in bridge-daemon-helpers.py.
if ! grep -F 'a2a-stuck-ack' "$DAEMON_SH" >/dev/null; then
  T6_FAILS+="daemon does not call a2a-stuck-ack helper; "
fi
if ! grep -F 'a2a-stuck-ack' "$HELPERS_PY" >/dev/null; then
  T6_FAILS+="bridge-daemon-helpers.py missing a2a-stuck-ack subcommand; "
fi
if ! grep -nE '^def cmd_a2a_stuck_ack\(' "$HELPERS_PY" >/dev/null; then
  T6_FAILS+="cmd_a2a_stuck_ack handler missing in helpers; "
fi

if [[ -n "$T6_FAILS" ]]; then
  smoke_fail "T6: $T6_FAILS"
fi

smoke_log "T6 PASS — cooldown expiry re-emits, ledger prunes dropped rows, decide+ack split wired"

# ---------------------------------------------------------------------
# T_stuck_task_create_failure_preserves_ledger — v0.15.0-beta4 Lane I
# r2 (codex r1 BLOCKING).
#
# Contract: if `$target_bridge task create` fails (transient), the
# daemon shell must NOT advance the reemit cooldown for that row.
# Otherwise the operator silently loses the alert until cooldown
# lapses. The split is enforced by:
#   - cmd_a2a_stuck_decide: pure read, no ledger writes
#   - daemon shell loop: append message_id to ack-keys only on
#     task-create success (skip on failure)
#   - cmd_a2a_stuck_ack: stamp ledger only for keys in ack-keys file
#
# We exercise the failure path by:
#   - calling decide (no ledger write)
#   - simulating task-create failure: do NOT add message_id to ack
#     keys
#   - calling ack with empty (or no-msg) ack-keys
#   - asserting ledger does not contain msg-stuck-001
#   - asserting next decide call (within cooldown) re-emits the same
#     row (since cooldown was never advanced)
# ---------------------------------------------------------------------

smoke_log "T_stuck_task_create_failure_preserves_ledger: failed task-create keeps ledger pristine"

TFAIL_OUTBOX="$SMOKE_TMP_ROOT/outbox-tcfail.json"
TFAIL_LEDGER="$SMOKE_TMP_ROOT/stuck-alerts-tcfail.json"
TFAIL_ACK="$SMOKE_TMP_ROOT/ack-keys-tcfail.txt"
cat >"$TFAIL_OUTBOX" <<'JSON'
[
  {"message_id": "msg-stuck-fail-001", "peer": "bridge-b", "target_agent": "reviewer", "priority": "normal", "status": "retry", "attempts": 3, "next_attempt_ts": 0, "last_error": "transport: peer unreachable", "acked_remote_task_id": null, "created_ts": 1000, "updated_ts": 1100, "lease_expires_ts": 0, "age_seconds": 10000, "due_for_seconds": 9000, "next_attempt_in_seconds": null, "lease_stale_seconds": null}
]
JSON
printf '{}\n' >"$TFAIL_LEDGER"

# Step 1 — decide. Should emit row. Ledger must remain {}.
TFAIL_OUT1="$(python3 "$HELPERS_PY" a2a-stuck-decide 2000000 600 3600 "$TFAIL_LEDGER" "$TFAIL_OUTBOX" 2>&1 || true)"
if ! printf '%s' "$TFAIL_OUT1" | grep -F 'msg-stuck-fail-001' >/dev/null; then
  smoke_fail "T_stuck_task_create_failure: decide did not emit candidate row (output: $TFAIL_OUT1)"
fi
if grep -F 'msg-stuck-fail-001' "$TFAIL_LEDGER" >/dev/null; then
  smoke_fail "T_stuck_task_create_failure: decide stamped ledger (regression — must be pure read)"
fi

# Step 2 — simulate task-create failure: ack-keys file stays empty.
: >"$TFAIL_ACK"
python3 "$HELPERS_PY" a2a-stuck-ack 2000000 "$TFAIL_LEDGER" "$TFAIL_ACK" "$TFAIL_OUTBOX" >/dev/null 2>&1 || true

# Step 3 — ledger MUST NOT carry an entry for msg-stuck-fail-001.
if grep -F 'msg-stuck-fail-001' "$TFAIL_LEDGER" >/dev/null; then
  smoke_fail "T_stuck_task_create_failure: ack stamped ledger despite failed task-create (ledger: $(cat "$TFAIL_LEDGER"))"
fi

# Step 4 — next decide call within cooldown re-emits the same row,
# proving the cooldown was never started.
TFAIL_OUT2="$(python3 "$HELPERS_PY" a2a-stuck-decide 2000060 600 3600 "$TFAIL_LEDGER" "$TFAIL_OUTBOX" 2>&1 || true)"
if ! printf '%s' "$TFAIL_OUT2" | grep -F 'msg-stuck-fail-001' >/dev/null; then
  smoke_fail "T_stuck_task_create_failure: next scan did not re-emit (alert lost!); ledger=$(cat "$TFAIL_LEDGER") output=$TFAIL_OUT2"
fi

# Teeth — synthetic regression: simulate the broken old contract where
# decide stamped the ledger directly. Inject the entry by hand and
# confirm the next decide call SKIPS the row (which is what the old
# bug looked like to the operator). This proves our new assertion
# bites — the test must fail if someone reverts the split.
TFAIL_LEDGER_REVERT="$SMOKE_TMP_ROOT/stuck-alerts-tcfail-revert.json"
printf '{"msg-stuck-fail-001": 2000000}\n' >"$TFAIL_LEDGER_REVERT"
TFAIL_OUT_REVERT="$(python3 "$HELPERS_PY" a2a-stuck-decide 2000060 600 3600 "$TFAIL_LEDGER_REVERT" "$TFAIL_OUTBOX" 2>&1 || true)"
if printf '%s' "$TFAIL_OUT_REVERT" | grep -F 'msg-stuck-fail-001' >/dev/null; then
  smoke_fail "T_stuck_task_create_failure teeth: with pre-stamped ledger, decide should suppress within cooldown (cooldown not honored)"
fi

smoke_log "T_stuck_task_create_failure_preserves_ledger PASS — failed task-create preserves ledger, next scan retries, teeth bites"

# ---------------------------------------------------------------------
# T_daemon_scan_tick_handles_create_failure — v0.15.0-beta4 Lane I r3
# (codex r2 TEST GAP).
#
# Contract: exercise the actual production `process_a2a_outbox_stuck_scan_tick`
# shell function from bridge-daemon.sh — not just the python helpers —
# under a controlled `task create` failure, then re-run under success.
#
# Mocks:
#   - `bridge-a2a.py outbox list --json` → fixture file (driver overrides
#     `bridge_with_timeout` for label `a2a_outbox_list`).
#   - `$BRIDGE_HOME/agent-bridge task create` → wrapper shim whose rc
#     reads from `BRIDGE_A2A_TEST_TASK_CREATE_RC` (0/1) per tick. Daemon
#     prefers `$BRIDGE_HOME/agent-bridge` over `$SCRIPT_DIR/agent-bridge`
#     (bridge-daemon.sh:2342-2349), so the shim wins.
#
# Acceptance (r3 codex r2 TEST GAP closure):
#   1. tick #1 with task_create rc=1:
#        - decide emits the stuck row
#        - daemon's task-create branch fails
#        - daemon_warn at bridge-daemon.sh:2468 fires
#          ("task-create failed for stuck …")
#        - ack helper runs with EMPTY ack-keys (production line 2456
#          appends ONLY inside the success branch) → ledger remains
#          unstamped for the stuck message_id
#        - throttle: next scan must NOT be skipped (we manually clear
#          tick_state between runs to keep the test deterministic)
#   2. tick #2 with task_create rc=0 (mock toggled, throttle state
#      cleared, retry-after window honored implicitly since we control
#      `BRIDGE_A2A_STUCK_ALERT_SCAN_INTERVAL_SECONDS=0` would skip the
#      tick — instead we remove the tick_state file between runs):
#        - decide emits the same stuck row (ledger never stamped)
#        - daemon's task-create branch succeeds
#        - ack helper stamps the ledger
#        - ledger NOW carries `"msg-stuck-real-001"`
#
# Teeth (regression vectors documented + exercised by tick #1):
#   V1. Move bridge-daemon.sh:2456 (`printf '%s\n' "$message_id" >>
#       "$ack_tmp"`) OUTSIDE the success branch (i.e. unconditionally
#       after the if-else). The smoke will then see ledger stamped on
#       failure → tick #2's pre-condition `ledger empty` fails →
#       assertion fires.
#   V2. Reorder helper calls so `a2a-stuck-ack` runs BEFORE the
#       task-create loop (or the loop appends to ack_tmp before the
#       success rc is known). Same shape — ledger stamped on failure
#       → assertion fires.
#
# Both vectors fail the same assertion: tick #1 must leave the ledger
# empty for `msg-stuck-real-001`.
# ---------------------------------------------------------------------

smoke_log "T_daemon_scan_tick_handles_create_failure: daemon function with mocked task-create"

DAEMON_TEST_HOME="$SMOKE_TMP_ROOT/daemon-test"
mkdir -p "$DAEMON_TEST_HOME/state/handoff"
DAEMON_TEST_CONFIG="$DAEMON_TEST_HOME/handoff.local.json"
# Daemon function gates on existence of handoff.local.json (production
# behavior — see bridge-daemon.sh:2301-2302). Content not parsed by this
# function; a stub object is fine.
printf '{"version":1,"peers":[]}\n' >"$DAEMON_TEST_CONFIG"

# Outbox fixture: one row that is stuck (status=retry, age over threshold).
DAEMON_TEST_OUTBOX="$SMOKE_TMP_ROOT/daemon-test-outbox.json"
cat >"$DAEMON_TEST_OUTBOX" <<'JSON'
[
  {"message_id": "msg-stuck-real-001", "peer": "bridge-b", "target_agent": "reviewer", "priority": "normal", "status": "retry", "attempts": 3, "next_attempt_ts": 0, "last_error": "transport: peer unreachable", "acked_remote_task_id": null, "created_ts": 1000, "updated_ts": 1100, "lease_expires_ts": 0, "age_seconds": 10000, "due_for_seconds": 9000, "next_attempt_in_seconds": null, "lease_stale_seconds": null}
]
JSON

# Mock agent-bridge shim. Daemon prefers $BRIDGE_HOME/agent-bridge over
# $SCRIPT_DIR/agent-bridge (see daemon function, lines 2342-2349). Reads
# rc from $BRIDGE_A2A_TEST_TASK_CREATE_RC.
DAEMON_TEST_AGB_SHIM="$DAEMON_TEST_HOME/agent-bridge"
cat >"$DAEMON_TEST_AGB_SHIM" <<'SHIM'
#!/usr/bin/env bash
# Mock for v0.15.0-beta4 Lane I r3 smoke. Returns rc from env var.
rc="${BRIDGE_A2A_TEST_TASK_CREATE_RC:-0}"
case "${1:-}" in
  task)
    if [[ "$rc" == "1" ]]; then
      printf 'mock-agent-bridge: task create failed (BRIDGE_A2A_TEST_TASK_CREATE_RC=1)\n' >&2
      exit 1
    fi
    exit 0
    ;;
  *)
    # Any other subcommand: no-op success.
    exit 0
    ;;
esac
SHIM
chmod +x "$DAEMON_TEST_AGB_SHIM"

DAEMON_TEST_WARN_LOG="$SMOKE_TMP_ROOT/daemon-test-warn.log"
DAEMON_TEST_EVENT_LOG="$SMOKE_TMP_ROOT/daemon-test-event.log"
: >"$DAEMON_TEST_WARN_LOG"
: >"$DAEMON_TEST_EVENT_LOG"

DAEMON_TEST_LEDGER="$DAEMON_TEST_HOME/state/handoff/stuck-alerts.json"
DAEMON_TEST_TICK="$DAEMON_TEST_HOME/state/handoff/stuck-scan-tick.env"

# Driver script — invokes the actual production
# process_a2a_outbox_stuck_scan_tick function from bridge-daemon.sh
# with mocks for `bridge-a2a.py outbox list --json` and `agent-bridge
# task create`. See run-stuck-scan-tick.sh for the mock contract.
DAEMON_TEST_DRIVER="$REPO_ROOT/scripts/smoke/I-beta4-helpers/run-stuck-scan-tick.sh"
if [[ ! -x "$DAEMON_TEST_DRIVER" ]]; then
  smoke_fail "T_daemon_scan_tick_handles_create_failure: missing driver $DAEMON_TEST_DRIVER"
fi

# Tick #1 — task_create rc=1 (failure path).
rm -f "$DAEMON_TEST_TICK" "$DAEMON_TEST_LEDGER"
env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
  SCRIPT_DIR="$REPO_ROOT" \
  BRIDGE_HOME="$DAEMON_TEST_HOME" \
  BRIDGE_STATE_DIR="$DAEMON_TEST_HOME/state" \
  BRIDGE_A2A_CONFIG="$DAEMON_TEST_CONFIG" \
  BRIDGE_ADMIN_AGENT_ID="patch-test" \
  BRIDGE_A2A_STUCK_ALERT_SCAN_INTERVAL_SECONDS=300 \
  BRIDGE_A2A_STUCK_ALERT_SECS=600 \
  BRIDGE_A2A_STUCK_ALERT_REEMIT_SECS=3600 \
  BRIDGE_A2A_TEST_OUTBOX_JSON="$DAEMON_TEST_OUTBOX" \
  BRIDGE_A2A_TEST_TASK_CREATE_RC=1 \
  BRIDGE_A2A_TEST_WARN_LOG="$DAEMON_TEST_WARN_LOG" \
  BRIDGE_A2A_TEST_EVENT_LOG="$DAEMON_TEST_EVENT_LOG" \
  bash "$DAEMON_TEST_DRIVER" \
    >"$SMOKE_TMP_ROOT/daemon-test-tick1.out" 2>"$SMOKE_TMP_ROOT/daemon-test-tick1.err" || true

# Assert 1: daemon_warn at bridge-daemon.sh:2468 fired ("task-create failed").
if ! grep -F '[a2a_stuck_scan] task-create failed for stuck msg-stuck-real-001' \
     "$DAEMON_TEST_WARN_LOG" >/dev/null; then
  smoke_fail "T_daemon_scan_tick_handles_create_failure: tick #1 did not emit task-create-failed warn (warn log: $(cat "$DAEMON_TEST_WARN_LOG"); stderr: $(cat "$SMOKE_TMP_ROOT/daemon-test-tick1.err"))"
fi

# Assert 2: ledger unstamped for msg-stuck-real-001 (production code path:
# line 2456 only appends to ack_tmp inside the success branch).
if [[ ! -f "$DAEMON_TEST_LEDGER" ]]; then
  smoke_fail "T_daemon_scan_tick_handles_create_failure: tick #1 did not create ledger file"
fi
if grep -F 'msg-stuck-real-001' "$DAEMON_TEST_LEDGER" >/dev/null; then
  smoke_fail "T_daemon_scan_tick_handles_create_failure: tick #1 stamped ledger despite task-create failure — regression of bridge-daemon.sh:2456 ack_tmp-append-on-success contract (ledger: $(cat "$DAEMON_TEST_LEDGER"))"
fi

smoke_log "T_daemon_scan_tick_handles_create_failure tick #1 PASS — warn emitted, ledger unstamped on rc=1"

# Tick #2 — task_create rc=0 (success path). Clear throttle so the
# function runs again rather than gating on `now < next`.
rm -f "$DAEMON_TEST_TICK"
env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
  SCRIPT_DIR="$REPO_ROOT" \
  BRIDGE_HOME="$DAEMON_TEST_HOME" \
  BRIDGE_STATE_DIR="$DAEMON_TEST_HOME/state" \
  BRIDGE_A2A_CONFIG="$DAEMON_TEST_CONFIG" \
  BRIDGE_ADMIN_AGENT_ID="patch-test" \
  BRIDGE_A2A_STUCK_ALERT_SCAN_INTERVAL_SECONDS=300 \
  BRIDGE_A2A_STUCK_ALERT_SECS=600 \
  BRIDGE_A2A_STUCK_ALERT_REEMIT_SECS=3600 \
  BRIDGE_A2A_TEST_OUTBOX_JSON="$DAEMON_TEST_OUTBOX" \
  BRIDGE_A2A_TEST_TASK_CREATE_RC=0 \
  BRIDGE_A2A_TEST_WARN_LOG="$DAEMON_TEST_WARN_LOG" \
  BRIDGE_A2A_TEST_EVENT_LOG="$DAEMON_TEST_EVENT_LOG" \
  bash "$DAEMON_TEST_DRIVER" \
    >"$SMOKE_TMP_ROOT/daemon-test-tick2.out" 2>"$SMOKE_TMP_ROOT/daemon-test-tick2.err" || true

# Assert 3: ledger NOW stamped for msg-stuck-real-001 (success branch
# ran ack_tmp append → ack helper stamped ledger).
if ! grep -F 'msg-stuck-real-001' "$DAEMON_TEST_LEDGER" >/dev/null; then
  smoke_fail "T_daemon_scan_tick_handles_create_failure: tick #2 did NOT stamp ledger after rc=0 — regression of success-branch ack contract (ledger: $(cat "$DAEMON_TEST_LEDGER"); event log: $(cat "$DAEMON_TEST_EVENT_LOG"); stderr: $(cat "$SMOKE_TMP_ROOT/daemon-test-tick2.err"))"
fi

# Assert 4: event log shows the daemon's emitted-count line — confirms
# task-create success path ran end-to-end.
if ! grep -F '[a2a_stuck_scan] emitted 1 stuck-outbox admin task' "$DAEMON_TEST_EVENT_LOG" >/dev/null; then
  smoke_fail "T_daemon_scan_tick_handles_create_failure: tick #2 did not log success emission (event log: $(cat "$DAEMON_TEST_EVENT_LOG"))"
fi

smoke_log "T_daemon_scan_tick_handles_create_failure tick #2 PASS — ledger stamped on rc=0 follow-up"
smoke_log "T_daemon_scan_tick_handles_create_failure PASS — daemon scan-tick honors task-create rc on success-branch-only ack-append contract"

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
