#!/usr/bin/env bash
# scripts/smoke/2035-ms365-token-freshness.sh — issue #2035.
#
# Behavioral (bun-driven) smoke for the two ms365 token-freshness hardening
# items. Both run the REAL getAccessToken/get_valid_token freshness path via the
# plugin's one-shot `get-valid-token` CLI entrypoint against a fixture token
# file, with the Microsoft token endpoint mocked by a fetch override (preload).
# A `MOCK_REFRESH_CALLED` stderr marker fires iff the plugin actually performed a
# refresh_token grant, so each assertion is mutation-proven (remove the fix → the
# refresh marker flips and the assertion fails).
#
#   Item 1 — a legacy 13-digit millisecond `expires_at` (PAST in seconds-land)
#            must normalize to seconds on read so the freshness check refreshes
#            instead of treating it as valid-for-56,000-years (never refreshing).
#   Item 2 — get_valid_token gains an optional proactive-refresh margin
#            (--min-remaining N / --force) WITHOUT changing the global 300s
#            constant: a token at ~1000s remaining stays cached by default,
#            refreshes under --min-remaining 1200 or --force, and the 300s
#            interactive boundary is unchanged.
#
# Falls back to a source-grep contract check when `bun` is unavailable (CI
# images without bun); the behavioral path is the primary gate when bun exists.
#
# Footgun #11: heredocs here write to FILES only (fixture/preload), never to a
# subprocess stdin; bun is invoked with argv (no heredoc-fed bash/python3).
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
MS365_DIR="$REPO_ROOT/plugins/ms365"
MS365_TS="$MS365_DIR/server.ts"

log() { printf '[smoke:2035-ms365-token-freshness] %s\n' "$*"; }
fail() { printf '[smoke:2035-ms365-token-freshness][error] %s\n' "$*" >&2; exit 1; }

[[ -f "$MS365_TS" ]] || fail "required file missing: $MS365_TS"

TMPDIR_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$TMPDIR_BASE/agb-2035-smoke.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT INT TERM

# --- source-grep contract (always runs; fast and bun-independent) ----------
# C1: the read-time ms→sec normalize helper exists with the 1e12 threshold.
log "C1: normalizeTokenExpiry 1e12 ms→sec helper present"
grep -Eq "function normalizeTokenExpiry" "$MS365_TS" \
  || fail "C1: no normalizeTokenExpiry helper"
grep -Eq "expires_at > 1e12" "$MS365_TS" \
  || fail "C1: normalize does not gate on the 1e12 (unambiguously-ms) threshold"
grep -Eq "Math\.floor\(.*expires_at / 1000\)" "$MS365_TS" \
  || fail "C1: normalize does not divide ms by 1000"

# C2: getAccessToken applies the normalize on its authoritative read.
log "C2: getAccessToken normalizes on read"
grep -Eq "const cur = normalizeTokenExpiry\(loadJson<TokenFile>\(tokenPath\(upn\)\)\)" "$MS365_TS" \
  || fail "C2: getAccessToken does not wrap its token load in normalizeTokenExpiry"

# C3: getAccessToken accepts an optional freshness override and the global 300s
#     constant is preserved (not raised) as the default margin.
log "C3: freshness override param + default 300s preserved"
grep -Eq "getAccessToken\(upn: string, freshness: TokenFreshness" "$MS365_TS" \
  || fail "C3: getAccessToken has no optional freshness param"
grep -Eq "const NEAR_EXPIRY_SECONDS = 300" "$MS365_TS" \
  || fail "C3: the 300s constant was changed/removed (must stay 300)"
grep -Eq "freshness.minRemaining \?\? NEAR_EXPIRY_SECONDS" "$MS365_TS" \
  || fail "C3: default margin is not NEAR_EXPIRY_SECONDS (interactive 300s must be the default)"

# C4: get_valid_token tool exposes min_remaining_seconds + force in its schema.
log "C4: get_valid_token schema exposes min_remaining_seconds + force"
awk "
  /name: 'get_valid_token'/ {cap=1}
  cap {buf=buf\$0 ORS}
  cap && /name: 'pair_status'/ {print buf; exit}
" "$MS365_TS" >"$WORK/block.txt"
[[ -s "$WORK/block.txt" ]] || fail "C4: could not isolate the get_valid_token tool block"
grep -Eq "min_remaining_seconds" "$WORK/block.txt" \
  || fail "C4: get_valid_token schema/handler lacks min_remaining_seconds"
grep -Eq "force" "$WORK/block.txt" \
  || fail "C4: get_valid_token schema/handler lacks force"

# C5: SECURITY regression — the get_valid_token block still never exposes the
#     refresh_token on any non-comment/non-description line (#1650 invariant).
log "C5: refresh_token never exposed (security regression guard)"
grep -vE "^[[:space:]]*//|^[[:space:]]*\*|description:|NEVER returns the refresh_token|owns the refresh_token" "$WORK/block.txt" >"$WORK/code.txt" || true
if grep -Eq "refresh_token" "$WORK/code.txt"; then
  fail "C5: a non-comment line in get_valid_token references refresh_token"
fi

# --- behavioral path (primary gate when bun is available) ------------------
if ! command -v bun >/dev/null 2>&1; then
  log "bun not found — behavioral cases skipped (source-grep contract passed)"
  log "passed"
  exit 0
fi

# Vendored deps for the MCP SDK import (offline, idempotent).
if [[ ! -d "$MS365_DIR/node_modules/@modelcontextprotocol" ]]; then
  log "installing ms365 plugin deps (bun install)"
  ( cd "$MS365_DIR" && bun install --no-summary >/dev/null 2>&1 ) \
    || { log "bun install failed (offline?) — behavioral cases skipped"; log "passed"; exit 0; }
fi

# fetch-mock preload: intercept the MS token endpoint, emit a marker, return a
# fresh token. Written to a FILE (not a subprocess stdin) — footgun-#11 safe.
cat >"$WORK/mock-fetch.ts" <<'TS'
const realFetch = globalThis.fetch
globalThis.fetch = (async (url: any, init?: any) => {
  const u = String(url)
  if (u.includes('login.microsoftonline.com') && u.includes('/oauth2/v2.0/token')) {
    process.stderr.write('MOCK_REFRESH_CALLED\n')
    return new Response(JSON.stringify({
      access_token: 'NEW_TOKEN_FROM_REFRESH',
      refresh_token: 'NEW_REFRESH',
      expires_in: 3600,
      scope: 'openid profile offline_access',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } })
  }
  return realFetch(url, init)
}) as any
TS

STATE="$WORK/state"
mkdir -p "$STATE/tokens"
UPN="smoke@example.com"
# slugUpn lowercases and maps non-[A-Za-z0-9._-] to '_': smoke@example.com → smoke_example.com
TOKEN_FILE="$STATE/tokens/smoke_example.com.json"
NOW="$(date +%s)"
NOW_MS=$((NOW * 1000))

write_token() { # $1=expires_at  $2=access_token
  cat >"$TOKEN_FILE" <<JSON
{"upn":"$UPN","access_token":"$2","refresh_token":"OLD_REFRESH","expires_at":$1,"scope":"openid profile offline_access","saved_at":$NOW}
JSON
}

# run_cli [args...] — explicit UPN positional + extra flags.
run_cli() { _run_cli "$UPN" "$@"; }
# run_cli_noupn [flags...] — NO explicit UPN; resolves MS365_DEFAULT_UPN. Proves
# flag-only invocations (`get-valid-token --force`) are not mis-parsed as a UPN.
run_cli_noupn() { _run_cli "$@"; }
_run_cli() {
  local out="$WORK/out.txt" err="$WORK/err.txt"
  MS365_STATE_DIR="$STATE" MS365_TENANT_ID=t MS365_CLIENT_ID=c MS365_CLIENT_SECRET=s \
  MS365_DEFAULT_UPN="$UPN" \
    bun --preload "$WORK/mock-fetch.ts" "$MS365_TS" get-valid-token "$@" \
    >"$out" 2>"$err"
  local rc=$?
  REFRESH_COUNT="$(grep -c MOCK_REFRESH_CALLED "$err" || true)"
  OUT_TOKEN="$(grep -oE 'NEW_TOKEN_FROM_REFRESH|STALE_TOKEN|CACHED_TOKEN|EXPIRED_TOKEN' "$out" | head -n1)"
  CLI_RC="$rc"
}

assert_refresh()   { [[ "$REFRESH_COUNT" == "1" ]] || fail "$1: expected a refresh (MOCK_REFRESH_CALLED), got count=$REFRESH_COUNT token=$OUT_TOKEN rc=$CLI_RC"; }
assert_cached()    { [[ "$REFRESH_COUNT" == "0" ]] || fail "$1: expected NO refresh (cached), got count=$REFRESH_COUNT token=$OUT_TOKEN rc=$CLI_RC"; }
assert_ok()        { [[ "$CLI_RC" == "0" ]] || fail "$1: CLI exited non-zero ($CLI_RC)"; }

# T1 — Item 1: legacy 13-digit ms expires_at, PAST → must REFRESH (mutation:
# remove the normalize → seconds read is ~56,000y positive → never refreshes).
log "T1 (item 1): legacy 13-digit ms past expires_at refreshes"
write_token $((NOW_MS - 600000)) "STALE_TOKEN"
run_cli
assert_ok "T1"; assert_refresh "T1"
[[ "$OUT_TOKEN" == "NEW_TOKEN_FROM_REFRESH" ]] || fail "T1: returned token was not the refreshed one ($OUT_TOKEN)"

# T2 — Item 2: ~1000s remaining, DEFAULT → cached (unchanged 300s behavior).
log "T2 (item 2): default at ~1000s remaining returns cached"
write_token $((NOW + 1000)) "CACHED_TOKEN"
run_cli
assert_ok "T2"; assert_cached "T2"

# T3 — Item 2: ~1000s remaining, --min-remaining 1200 → REFRESH (mutation:
# ignore the freshness param → cached, fails).
log "T3 (item 2): --min-remaining 1200 at ~1000s remaining refreshes"
write_token $((NOW + 1000)) "CACHED_TOKEN"
run_cli --min-remaining 1200
assert_ok "T3"; assert_refresh "T3"

# T4 — Item 2: ~1000s remaining, --force → REFRESH unconditionally.
log "T4 (item 2): --force at ~1000s remaining refreshes"
write_token $((NOW + 1000)) "CACHED_TOKEN"
run_cli --force
assert_ok "T4"; assert_refresh "T4"

# T5 — Item 2: ~1000s remaining, --min-remaining 500 → cached (1000 > 500).
log "T5 (item 2): --min-remaining 500 at ~1000s remaining returns cached"
write_token $((NOW + 1000)) "CACHED_TOKEN"
run_cli --min-remaining 500
assert_ok "T5"; assert_cached "T5"

# T6 — Item 2 regression: the interactive 300s boundary is unchanged.
log "T6 (item 2): interactive 300s boundary unchanged (250s refresh / 350s cached)"
write_token $((NOW + 250)) "CACHED_TOKEN"
run_cli
assert_ok "T6a"; assert_refresh "T6a"
write_token $((NOW + 350)) "CACHED_TOKEN"
run_cli
assert_ok "T6b"; assert_cached "T6b"

# T7 — SECURITY: the access_token leaves, the refresh_token never does (stdout).
log "T7: refresh_token never leaks to the CLI stdout payload"
write_token $((NOW + 1000)) "CACHED_TOKEN"
run_cli
if grep -Eq "refresh_token|OLD_REFRESH|NEW_REFRESH" "$WORK/out.txt"; then
  fail "T7: CLI stdout payload leaked a refresh_token"
fi

# T8 — Item 2 (codex r1 #1): a FLAG-ONLY call (no explicit upn positional, UPN
# from MS365_DEFAULT_UPN) must treat `--force` as a flag, NOT as the upn. Before
# the fix this exited non-zero with "no token for --force".
log "T8 (item 2): flag-only --force resolves default UPN (not upn=--force)"
write_token $((NOW + 1000)) "CACHED_TOKEN"
run_cli_noupn --force
assert_ok "T8"; assert_refresh "T8"

# T9 — Item 2 (codex r1 #2) SECURITY: a NEGATIVE --min-remaining must never let
# an already-expired token slip past the freshness check. With the token expired
# 10s ago, a negative margin must still trigger a refresh (the invalid margin is
# rejected → falls back to the 300s default → expired ⇒ refresh).
log "T9 (item 2): negative --min-remaining never serves an expired token"
write_token $((NOW - 10)) "EXPIRED_TOKEN"
run_cli --min-remaining -1200
assert_ok "T9"; assert_refresh "T9"
[[ "$OUT_TOKEN" == "NEW_TOKEN_FROM_REFRESH" ]] || fail "T9: served a non-refreshed token ($OUT_TOKEN) under a negative margin"

log "passed"
