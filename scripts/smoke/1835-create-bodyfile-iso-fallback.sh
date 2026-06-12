#!/usr/bin/env bash
#
# Issue #1835 — `agb task create --body-file` with an iso-owned /tmp file.
#
# An iso-v2 agent running `agb task create --body-file /tmp/<file>` hit a hard
# failure when the body file was owned by `agent-bridge-<a>:ab-agent-<a>` (mode
# 0660) and the reading process was not a member of that group. The #1280
# sudo-as-owner fallback covered the `agb show` read path AND the
# `bridge-queue.py create --body-file` SERVER path (file transport), but the
# SOCKET transport's client-side preflight (bridge-queue-gateway.py
# :_read_inline_text) read the file with no fallback — so it raised
# `body_file_unreadable` ("unreadable under client UID") with no hint that file
# ownership was the cause.
#
# The fix applies the SAME #1280 sudo-read fallback (`sudo -n -u <owner> cat`)
# on PermissionError, and — when that fallback cannot apply — emits an
# actionable iso-ownership error naming `--body` / `sudo chmod 0644`.
#
# This smoke is Python-level (it monkeypatches os.open / _sudo_read_body_file)
# so it runs deterministically on every platform without real iso UIDs.
#
# Footgun #11 / C1: every Python snippet is driven through the file-as-argv
# sidecar 1835-create-bodyfile-iso-fallback-helper.py — NO `python3 - <<'PY'`
# heredoc-stdin to a subprocess anywhere in this smoke.

set -euo pipefail

SMOKE_NAME="1835-create-bodyfile-iso-fallback"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/${SMOKE_NAME}-helper.py"

trap smoke_cleanup_temp_root EXIT

BODY_FILE=""

# A readable body file is read directly — the sudo fallback must NOT fire
# (no regression for the common controller-readable case).
bodyfile_direct_read_no_fallback() {
  local out
  out="$(python3 "$HELPER" direct-read-no-fallback "$SMOKE_REPO_ROOT" "$BODY_FILE" 2>&1 || true)"
  smoke_assert_contains "$out" "ok-direct-read-no-fallback" \
    "readable body file is read directly; sudo fallback not invoked"
}

# PermissionError on open -> sudo-as-owner fallback succeeds -> the recovered
# bytes are decoded and returned (the #1280 parity behavior).
bodyfile_fallback_success() {
  local out
  out="$(python3 "$HELPER" fallback-success "$SMOKE_REPO_ROOT" "$BODY_FILE" 2>&1 || true)"
  smoke_assert_contains "$out" "ok-fallback-success" \
    "PermissionError -> sudo-as-owner fallback recovers the body bytes"
}

# PermissionError + fallback unavailable (no sudoers grant) -> actionable
# iso-ownership error naming the file-ownership root cause and workarounds.
bodyfile_fallback_unavailable_actionable() {
  local out
  out="$(python3 "$HELPER" fallback-unavailable-actionable "$SMOKE_REPO_ROOT" "$BODY_FILE" 2>&1 || true)"
  smoke_assert_contains "$out" "ok-fallback-unavailable-actionable" \
    "fallback unavailable -> actionable iso-ownership error (--body / chmod 0644 / #1280)"
}

# Bytes recovered via the fallback still pass the SAME inline size cap a direct
# read would — the fallback does not bypass the transport limit.
bodyfile_fallback_size_cap() {
  local out
  out="$(python3 "$HELPER" fallback-size-cap "$SMOKE_REPO_ROOT" "$BODY_FILE" 2>&1 || true)"
  smoke_assert_contains "$out" "ok-fallback-size-cap" \
    "fallback bytes still respect the inline-transport size cap"
}

main() {
  smoke_require_cmd python3
  smoke_assert_file_exists "$HELPER" "1835 helper sidecar present"
  smoke_setup_bridge_home "1835-create-bodyfile-iso-fallback"

  BODY_FILE="$SMOKE_TMP_ROOT/body.md"
  printf '[plan] focus checklist\nExpected output: implement-ok\n' >"$BODY_FILE"

  smoke_run "readable body file: direct read, no fallback" bodyfile_direct_read_no_fallback
  smoke_run "PermissionError: sudo-as-owner fallback succeeds" bodyfile_fallback_success
  smoke_run "fallback unavailable: actionable iso-ownership error" bodyfile_fallback_unavailable_actionable
  smoke_run "fallback bytes respect the inline size cap" bodyfile_fallback_size_cap

  smoke_log "passed"
}

main "$@"
