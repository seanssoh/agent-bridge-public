#!/usr/bin/env bash
# Issue #1663 regression smoke — `bridge-dev-plugin-cache.py` overlay must
# NOT cascade-fail iso agent launches on an unreadable upgrade/VCS sidecar.
#
# Outage (cm-prod, Linux iso-v2): after `upgrade --apply`, a stashed local
# change to `plugins/ms365/server.ts` conflicted with v0.16.1, so the
# upgrader's `conflict_backup_path` wrote `server.ts.upgrade-conflict` at
# 0600 owner-only inside the plugin source dir. The dev-plugin-cache overlay
# copied every source entry with an EXACT-NAME skip set only (node_modules,
# symlinks) — it did NOT skip the `*.upgrade-conflict` sidecar. The iso UID
# could not read the 0600 file → `copy2` raised PermissionError → the ENTIRE
# plugin cache build aborted → `install-failed` → channel-required plugin
# cache failed → every iso agent on that plugin cascade-failed to launch
# (`always-on-launch-failure` ×10).
#
# Fix (#1663): (1) pattern-skip upgrade/VCS/merge sidecars in BOTH overlay
# paths (`overlay_source_to_cache` + recursive `_overlay_dir`) — skip+WARN,
# non-fatal; (2) a per-entry copy/stat guard so one unknown unreadable entry
# is skipped+WARN'd instead of aborting the whole build; (3) EXCEPT a
# required plugin-contract file (plugin.json / package.json / server.ts /
# server.js / mcp.json / .mcp.json) unreadable → fail-loud (install-failed),
# because silently shipping a cache missing its contract file is worse.
#
# This smoke runs the CLI as the current (non-root) UID with a `chmod 0000`
# file: a non-owner-readable file is unreadable to the running UID, which is
# exactly the condition the iso UID hits on the 0600 owner-only sidecar. So
# the macOS dev host and Linux CI both exercise the real `PermissionError`
# code path without needing a true cross-UID setup.
#
# T1 — sidecar (0000 `server.ts.upgrade-conflict`) + an unknown unreadable
#      file (0000) → cache build exits 0, logs WARNINGs, omits the sidecar +
#      unknown file from the cache, and still reports a `*-verified` status
#      for a channel-required plugin (no cascade).
# T2 — a REQUIRED-CONTRACT file (`server.ts` itself) unreadable (0000) →
#      cache build fails-loud (install-failed, exit 1), NOT a silent
#      verified status.
# T3 — a nested required-contract file (`.claude-plugin/plugin.json`)
#      unreadable → fail-loud too (recursion-depth required-contract guard).

set -u

if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "[smoke:1663-plugin-cache-sidecar-skip] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1663-plugin-cache-sidecar-skip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  # Restore perms on any 0000 fixtures so cleanup can remove the tree.
  if [[ -n "${SMOKE_TMP_ROOT:-}" && -d "$SMOKE_TMP_ROOT" ]]; then
    chmod -R u+rwX "$SMOKE_TMP_ROOT" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "1663-plugin-cache-sidecar-skip"

REPO_ROOT="$SMOKE_REPO_ROOT"
DEV_CACHE_PY="$REPO_ROOT/bridge-dev-plugin-cache.py"
smoke_assert_file_exists "$DEV_CACHE_PY" "bridge-dev-plugin-cache.py present"

if [[ "$(id -u)" == "0" ]]; then
  # Root reads through mode 0000, so the PermissionError path cannot be
  # exercised. Don't claim a pass we did not verify.
  smoke_skip "1663 sidecar/required-contract guard" "cannot simulate unreadable file as root (uid 0)"
  smoke_log "passed"
  exit 0
fi

PLUGIN="smoke-plugin"
MARKETPLACE="smoke-mkt"
VERSION="0.0.1"
CHANNEL="plugin:${PLUGIN}@${MARKETPLACE}"

# Build a self-contained marketplace fixture whose marketplace name matches
# the channel's marketplace, so `resolve_marketplace_root` returns --root
# directly (no known_marketplaces.json lookup needed).
build_fixture() {
  local mktroot="$1"
  local srcdir="$mktroot/plugins/$PLUGIN"
  mkdir -p "$mktroot/.claude-plugin" "$srcdir/.claude-plugin"
  cat >"$mktroot/.claude-plugin/marketplace.json" <<JSON
{
  "name": "$MARKETPLACE",
  "plugins": [
    {"name": "$PLUGIN", "source": "./plugins/$PLUGIN", "version": "$VERSION"}
  ]
}
JSON
  cat >"$srcdir/.claude-plugin/plugin.json" <<JSON
{"name": "$PLUGIN", "version": "$VERSION"}
JSON
  printf "console.log('hi')\n" >"$srcdir/server.ts"
  cat >"$srcdir/package.json" <<JSON
{"name": "$PLUGIN", "version": "$VERSION"}
JSON
  printf '%s' "$srcdir"
}

# Run the sync CLI for a fixture. Pins cache + plugins roots into the temp
# tree so nothing live is touched. Echoes the JSON on stdout; returns the
# CLI exit code.
run_sync() {
  local mktroot="$1"
  local case_id="$2"
  BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="$SMOKE_TMP_ROOT/$case_id/cache" \
  BRIDGE_CLAUDE_PLUGINS_ROOT="$SMOKE_TMP_ROOT/$case_id/plugins-root" \
    python3 "$DEV_CACHE_PY" sync \
      --root "$mktroot" \
      --channels "$CHANNEL" \
      --required-channels "$CHANNEL" \
      --agent "$SMOKE_NAME" \
      --json
}

cache_version_dir() {
  local case_id="$1"
  printf '%s' "$SMOKE_TMP_ROOT/$case_id/cache/$MARKETPLACE/$PLUGIN/$VERSION"
}

# ---------------------------------------------------------------------------
# T1 — unreadable sidecar + unknown unreadable file → verified, no cascade.
# ---------------------------------------------------------------------------
t1_sidecar_non_fatal() {
  local case_id="t1"
  local mktroot="$SMOKE_TMP_ROOT/$case_id/mkt"
  local srcdir
  srcdir="$(build_fixture "$mktroot")"

  # The 0600 owner-only conflict sidecar from the upgrader. 0000 makes it
  # unreadable to the running (non-root) UID == the iso UID's view of a 0600
  # owner-only file owned by the controller.
  printf 'stashed secret server.ts\n' >"$srcdir/server.ts.upgrade-conflict"
  chmod 0000 "$srcdir/server.ts.upgrade-conflict"
  # An UNKNOWN unreadable entry (not a known sidecar) — must skip+WARN too.
  printf 'opaque\n' >"$srcdir/private-blob.dat"
  chmod 0000 "$srcdir/private-blob.dat"

  local out rc
  out="$(run_sync "$mktroot" "$case_id" 2>"$SMOKE_TMP_ROOT/$case_id.stderr")"
  rc=$?

  smoke_assert_eq "0" "$rc" "T1 channel-required sync must exit 0 (no cascade)"

  local status
  status="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["results"][0].get("status",""))')"
  smoke_assert_eq "linked-verified" "$status" "T1 status must be linked-verified"

  # Cache must contain the real content and OMIT both unreadable entries.
  local cvd
  cvd="$(cache_version_dir "$case_id")"
  smoke_assert_file_exists "$cvd/server.ts" "T1 real server.ts copied into cache"
  smoke_assert_file_exists "$cvd/package.json" "T1 package.json copied into cache"
  smoke_assert_file_exists "$cvd/.claude-plugin/plugin.json" "T1 nested plugin.json copied"
  [[ -e "$cvd/server.ts.upgrade-conflict" ]] && \
    smoke_fail "T1 sidecar must be OMITTED from cache, found: $cvd/server.ts.upgrade-conflict"
  [[ -e "$cvd/private-blob.dat" ]] && \
    smoke_fail "T1 unknown unreadable file must be OMITTED from cache"

  # Operator-visible WARN signal for both skips.
  local stderr_blob
  stderr_blob="$(cat "$SMOKE_TMP_ROOT/$case_id.stderr")"
  smoke_assert_contains "$stderr_blob" "server.ts.upgrade-conflict" "T1 sidecar skip logs a WARNING"
  smoke_assert_contains "$stderr_blob" "private-blob.dat" "T1 unknown-unreadable skip logs a WARNING"
  return 0
}

# ---------------------------------------------------------------------------
# T2 — required-contract file unreadable → fail-loud (install-failed).
# ---------------------------------------------------------------------------
t2_required_contract_fail_loud() {
  local case_id="t2"
  local mktroot="$SMOKE_TMP_ROOT/$case_id/mkt"
  local srcdir
  srcdir="$(build_fixture "$mktroot")"

  # server.ts is required plugin-contract material — unreadable must NOT be
  # silently skipped (the cache would load broken). Fail loud instead.
  chmod 0000 "$srcdir/server.ts"

  local out rc
  out="$(run_sync "$mktroot" "$case_id" 2>/dev/null)"
  rc=$?

  smoke_assert_eq "1" "$rc" "T2 required-contract unreadable must exit 1 (fail-loud)"

  local status reason
  status="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["results"][0].get("status",""))')"
  reason="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["results"][0].get("reason",""))')"
  smoke_assert_eq "install-failed" "$status" "T2 status must be install-failed (not a silent verified)"
  smoke_assert_contains "$reason" "required-contract-unreadable" "T2 reason names required-contract"
  return 0
}

# ---------------------------------------------------------------------------
# T3 — nested required-contract (.claude-plugin/plugin.json) unreadable →
#      fail-loud too (proves the required-contract guard fires at every
#      recursion depth, not just the top level).
# ---------------------------------------------------------------------------
t3_nested_required_contract_fail_loud() {
  local case_id="t3"
  local mktroot="$SMOKE_TMP_ROOT/$case_id/mkt"
  local srcdir
  srcdir="$(build_fixture "$mktroot")"

  chmod 0000 "$srcdir/.claude-plugin/plugin.json"

  local out rc
  out="$(run_sync "$mktroot" "$case_id" 2>/dev/null)"
  rc=$?

  smoke_assert_eq "1" "$rc" "T3 nested required-contract unreadable must exit 1 (fail-loud)"

  local status
  status="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["results"][0].get("status",""))')"
  smoke_assert_eq "install-failed" "$status" "T3 nested required-contract → install-failed"
  return 0
}

smoke_run "T1 sidecar + unknown unreadable → verified, no cascade" t1_sidecar_non_fatal
smoke_run "T2 required-contract unreadable → fail-loud" t2_required_contract_fail_loud
smoke_run "T3 nested required-contract unreadable → fail-loud" t3_nested_required_contract_fail_loud

smoke_log "passed"
