#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1640-urgent-from-override.sh — Issue #1640.
#
# `agb urgent <agent> "<msg>"` (→ bridge-send.sh --urgent) used to NOT accept
# a `--from <agent>` flag and actively rejected it via the `-*)` catch-all
# ("알 수 없는 옵션: --from"), inconsistent with `task create` / `task handoff`
# which both take `--from`. There was no CLI recourse when auto-inference of
# the sender was wrong/unavailable (cron driver, ad-hoc script, detached
# shell) — the task fell through to `${USER:-unknown}`.
#
# The override plumbing already existed: infer_actor_if_possible "$1"
# short-circuits when its arg is non-empty. The fix wires a `--from` flag
# through to that arg (and onward into the `task create --priority urgent` it
# builds), mirroring `bridge-task.sh create --from`. With no `--from`, the
# sender is still auto-inferred (behavior unchanged).
#
# Test plan (drives the REAL bridge-send.sh urgent path end-to-end under an
# isolated $BRIDGE_HOME/$BRIDGE_TASK_DB, then reads created_by off the durable
# queue row — no tmux session is required because the durable task is created
# before the live-wake dispatch, and the dispatch fail-soft never blocks the
# send):
#   T1 override wins: `urgent <agent> "msg" --from <override>` → the created
#      task has created_by=<override>.
#   T2 auto-attribution preserved: omitting `--from` → created_by = the
#      inferred actor (BRIDGE_AGENT_ID here), NOT "unknown" and NOT the
#      override from T1.
#   T3 no rejection: `--from` no longer trips the `-*)` catch-all
#      ("알 수 없는 옵션") and exits 0.
#   T4 arity guard: a trailing `--from` with no value dies with the
#      mirror-of-task-create message (does NOT silently swallow nothing).
#
# Footgun #11 (heredoc_write deadlock class): all subprocess capture goes
# through `$(... )` against the shell scripts directly — no python
# heredoc-stdin into a subprocess and no `<<<` here-strings into bridge
# functions. No `*-helper.py` is needed (pure CLI drive).

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (roster load). macOS ships 3.2.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1640-urgent-from-override] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1640-urgent-from-override"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

smoke_require_cmd python3

# Pick a Bash 4+ interpreter for the bridge-send.sh subprocess (system bash is
# 3.2 on macOS).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

TARGET_AGENT="urgentbot"
OVERRIDE_ACTOR="patch"
INFERRED_ACTOR="caller-sess"

# Register the target agent + a sender agent in the isolated roster so
# bridge_require_agent / bridge_agent_session resolve and BRIDGE_AGENT_ID-based
# auto-inference (bridge_infer_current_agent) resolves the sender (it only
# honors BRIDGE_AGENT_ID when that id is a REGISTERED roster agent). No engine
# binary is touched — this is a roster-data registration only.
#
# Emitted via grouped `printf` (NOT a heredoc) so there is zero heredoc-stdin
# anywhere in this fixture — footgun #11 (heredoc_write deadlock class) clean.
{
  printf 'bridge_add_agent_id_if_missing "%s"\n' "$TARGET_AGENT"
  printf 'BRIDGE_AGENT_DESC["%s"]="urgent smoke target"\n' "$TARGET_AGENT"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$TARGET_AGENT"
  printf 'BRIDGE_AGENT_SESSION["%s"]="%s"\n' "$TARGET_AGENT" "$TARGET_AGENT"
  printf 'bridge_add_agent_id_if_missing "%s"\n' "$INFERRED_ACTOR"
  printf 'BRIDGE_AGENT_DESC["%s"]="urgent smoke sender"\n' "$INFERRED_ACTOR"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$INFERRED_ACTOR"
  printf 'BRIDGE_AGENT_SESSION["%s"]="%s"\n' "$INFERRED_ACTOR" "$INFERRED_ACTOR"
} >"$BRIDGE_ROSTER_LOCAL_FILE"

# run_urgent <BRIDGE_AGENT_ID-for-inference> -- <bridge-send.sh args...>
#
# Runs the REAL bridge-send.sh --urgent path. BRIDGE_AGENT_ID sets the
# auto-inferred actor so the no-`--from` path is deterministic. Captures
# combined stdout+stderr and the exit code.
RUN_URGENT_OUT=""
RUN_URGENT_RC=0
run_urgent() {
  local inferred="$1"
  shift
  [[ "$1" == "--" ]] && shift
  RUN_URGENT_RC=0
  RUN_URGENT_OUT="$(
    BRIDGE_AGENT_ID="$inferred" \
      "$BRIDGE_BASH" "$REPO_ROOT/bridge-send.sh" --urgent "$@" 2>&1
  )" || RUN_URGENT_RC=$?
}

# latest_task_id — the id of the most-recently created task (the urgent send
# does not echo a parseable id, so read the max open-task id from the queue
# directly via find-open --all). The JSON is piped to a plain `python3 -c`
# reader (stdin from a pipe, NOT a heredoc/here-string into a bridge shell
# function — outside the footgun #11 class).
latest_task_id() {
  python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$TARGET_AGENT" --all --format json 2>/dev/null \
    | python3 -c 'import sys,json
try:
    rows = json.load(sys.stdin)
except (ValueError, json.JSONDecodeError):
    sys.exit(0)
if rows:
    print(max(int(r["id"]) for r in rows))'
}

created_by_of() {
  local id="$1"
  python3 "$REPO_ROOT/bridge-queue.py" show "$id" --format shell 2>/dev/null \
    | sed -n "s/^TASK_CREATED_BY=//p" | head -n1 | sed "s/^'//; s/'$//"
}

# ---------------------------------------------------------------------
# T1 — --from override wins: created_by equals the explicit override.
# ---------------------------------------------------------------------
test_from_override_wins() {
  smoke_log "T1: --from override sets created_by to the explicit actor"

  run_urgent "$INFERRED_ACTOR" -- "$TARGET_AGENT" "override-urgent body" --from "$OVERRIDE_ACTOR"
  if (( RUN_URGENT_RC != 0 )); then
    echo "------ output ------" >&2
    echo "$RUN_URGENT_OUT" >&2
    echo "--------------------" >&2
    smoke_fail "T1: urgent --from exited non-zero (rc=$RUN_URGENT_RC)"
  fi
  smoke_assert_not_contains "$RUN_URGENT_OUT" "알 수 없는 옵션" \
    "T1: --from must not be rejected by the catch-all"

  local id created_by
  id="$(latest_task_id)"
  [[ "$id" =~ ^[0-9]+$ ]] || smoke_fail "T1: could not resolve created task id (out: $RUN_URGENT_OUT)"
  created_by="$(created_by_of "$id")"
  smoke_assert_eq "$OVERRIDE_ACTOR" "$created_by" \
    "T1: created_by must equal the --from override"
}

# ---------------------------------------------------------------------
# T2 — auto-attribution preserved: no --from → created_by is the inferred
# actor (BRIDGE_AGENT_ID), NOT "unknown" and NOT the T1 override.
# ---------------------------------------------------------------------
test_auto_attribution_preserved() {
  smoke_log "T2: omitting --from keeps the auto-inferred sender (behavior unchanged)"

  run_urgent "$INFERRED_ACTOR" -- "$TARGET_AGENT" "auto-urgent body"
  if (( RUN_URGENT_RC != 0 )); then
    echo "------ output ------" >&2
    echo "$RUN_URGENT_OUT" >&2
    echo "--------------------" >&2
    smoke_fail "T2: urgent without --from exited non-zero (rc=$RUN_URGENT_RC)"
  fi

  local id created_by
  id="$(latest_task_id)"
  [[ "$id" =~ ^[0-9]+$ ]] || smoke_fail "T2: could not resolve created task id (out: $RUN_URGENT_OUT)"
  created_by="$(created_by_of "$id")"
  smoke_assert_eq "$INFERRED_ACTOR" "$created_by" \
    "T2: created_by must be the inferred actor when --from is omitted"
  smoke_assert_not_contains "$created_by" "unknown" \
    "T2: auto-attribution must not fall through to 'unknown' when a sender is inferable"
  if [[ "$created_by" == "$OVERRIDE_ACTOR" ]]; then
    smoke_fail "T2: created_by leaked the T1 override ($OVERRIDE_ACTOR) into a no-from send"
  fi
}

# ---------------------------------------------------------------------
# T3 — --from no longer trips the unknown-option catch-all (the exact
# inconsistency #1640 reported). Asserted via a non-error exit + no marker.
# ---------------------------------------------------------------------
test_from_not_rejected() {
  smoke_log "T3: --from is a recognized option (no '알 수 없는 옵션' rejection)"

  run_urgent "$INFERRED_ACTOR" -- "$TARGET_AGENT" "accepts-from body" --from "$OVERRIDE_ACTOR"
  smoke_assert_eq "0" "$RUN_URGENT_RC" "T3: urgent --from must exit 0"
  smoke_assert_not_contains "$RUN_URGENT_OUT" "알 수 없는 옵션: --from" \
    "T3: --from must not produce the unknown-option error"
}

# ---------------------------------------------------------------------
# T4 — arity guard: a trailing `--from` with no value dies (mirrors
# bridge-task.sh create --from), it does NOT silently swallow.
# ---------------------------------------------------------------------
test_from_requires_value() {
  smoke_log "T4: trailing --from with no value is rejected (arity guard)"

  run_urgent "$INFERRED_ACTOR" -- "$TARGET_AGENT" "needs-value body" --from
  if (( RUN_URGENT_RC == 0 )); then
    echo "------ output ------" >&2
    echo "$RUN_URGENT_OUT" >&2
    echo "--------------------" >&2
    smoke_fail "T4: a value-less --from must NOT succeed"
  fi
  smoke_assert_contains "$RUN_URGENT_OUT" "--from" \
    "T4: the arity error must name the --from flag"
}

smoke_run "T1 --from override wins" test_from_override_wins
smoke_run "T2 auto-attribution preserved" test_auto_attribution_preserved
smoke_run "T3 --from not rejected" test_from_not_rejected
smoke_run "T4 --from requires value" test_from_requires_value

smoke_log "PASS — #1640 agb urgent --from overrides sender attribution; auto-inference unchanged when omitted"
exit 0
