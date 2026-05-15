#!/usr/bin/env bash
# scripts/smoke/bridge-notify-no-default-discord-875.sh — Issue #875 regression
# guard for the bridge-notify "default account silent-skip" contract.
#
# Before this PR, `bridge-notify.py send --kind discord --account default` on a
# host that never wired a default Discord account raised SystemExit with the
# operator-facing string `discord account not found: default`. The cron-
# followup path (which composes the body the admin agent sees) embedded that
# string verbatim, training the operator to ignore notify failures even when
# the alert had really not been delivered.
#
# The fix narrows the strict SystemExit to *named* account misses (real
# operator misconfig) and turns the implicit-default miss into a silent skip
# with a structured audit row. T1 below proves the new contract; T2 proves the
# named-account path still hard-fails so a real typo doesn't slip past.
#
# Footgun #11 (Bash 5.3.9 heredoc deadlock): no heredoc, no here-string. All
# inline Python is written to a tmp file with printf and run via `python3
# <file>`.

set -euo pipefail

SMOKE_NAME="bridge-notify-no-default-discord-875"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# Empty runtime config — no `channels.discord.accounts.default` entry. This
# mirrors the operator-host state at issue-file time: an agent (patch-dev) that
# never declared a Discord channel triggers a notify path that reaches the
# default-account lookup with nothing on the other end.
CONFIG_FILE="$SMOKE_TMP_ROOT/bridge-config.json"
printf '%s\n' '{}' >"$CONFIG_FILE"

AUDIT_LOG="$SMOKE_TMP_ROOT/audit.jsonl"
export BRIDGE_AUDIT_LOG="$AUDIT_LOG"
: >"$AUDIT_LOG"

# T1: default account miss → silent skip, exit 0, JSON body has status=skipped
#     and no "not found" text. This is the regression guard.
T1_STDOUT="$SMOKE_TMP_ROOT/t1.stdout"
T1_STDERR="$SMOKE_TMP_ROOT/t1.stderr"
set +e
"$PY_BIN" "$REPO_ROOT/bridge-notify.py" send \
  --agent patch-dev \
  --kind discord \
  --target 123456789 \
  --account default \
  --runtime-config "$CONFIG_FILE" \
  --title "smoke" \
  --message "should-not-be-surfaced" \
  >"$T1_STDOUT" 2>"$T1_STDERR"
T1_RC=$?
set -e

[[ "$T1_RC" -eq 0 ]] || smoke_fail "T1 expected rc=0, got rc=$T1_RC; stderr=$(cat "$T1_STDERR")"

T1_OUT="$(cat "$T1_STDOUT")"
smoke_assert_contains "$T1_OUT" '"status": "skipped"' "T1 default miss emits status=skipped"
smoke_assert_contains "$T1_OUT" '"skip_reason": "no_default_account"' "T1 default miss tags skip_reason"
smoke_assert_not_contains "$T1_OUT" "not found" "T1 default miss does not surface 'not found'"

T1_ERR="$(cat "$T1_STDERR")"
smoke_assert_not_contains "$T1_ERR" "not found" "T1 default miss does not surface 'not found' on stderr"

[[ -s "$AUDIT_LOG" ]] || smoke_fail "T1 expected an audit row at $AUDIT_LOG"
AUDIT_TAIL="$(tail -n 1 "$AUDIT_LOG")"
smoke_assert_contains "$AUDIT_TAIL" '"action": "bridge_notify_skipped"' "T1 audit row records bridge_notify_skipped"
smoke_assert_contains "$AUDIT_TAIL" '"reason": "no_default_account"' "T1 audit row carries reason"

smoke_log "T1 default-miss silent-skip ok"

# T2: explicit non-default account miss → strict SystemExit with the original
#     descriptive error. This proves the fix is narrow — a real operator typo
#     in `--account my-bot` still trips, the cosmetic-only path is the implicit
#     default.
T2_STDOUT="$SMOKE_TMP_ROOT/t2.stdout"
T2_STDERR="$SMOKE_TMP_ROOT/t2.stderr"
set +e
"$PY_BIN" "$REPO_ROOT/bridge-notify.py" send \
  --agent patch-dev \
  --kind discord \
  --target 123456789 \
  --account my-bot \
  --runtime-config "$CONFIG_FILE" \
  --title "smoke" \
  --message "should-fail" \
  >"$T2_STDOUT" 2>"$T2_STDERR"
T2_RC=$?
set -e

[[ "$T2_RC" -ne 0 ]] || smoke_fail "T2 expected non-zero rc (named account miss), got rc=0; stdout=$(cat "$T2_STDOUT")"
T2_ERR="$(cat "$T2_STDERR")"
smoke_assert_contains "$T2_ERR" "discord account not found: my-bot" "T2 named-account miss preserves strict error"

smoke_log "T2 named-account miss still hard-fails ok"

smoke_log "ok"
