#!/usr/bin/env bash
# scripts/smoke/1650-ms365-refresh-scope-continuity.sh — issue #1650.
#
# Pins the BEHAVIORAL contract for #1650: an expired access_token with a
# present, still-valid refresh_token auto-refreshes — and KEEPS being able to
# refresh across successive expiry cycles.
#
# Root cause #1650 (scope drift): the refresh_token grant used to send
# `scope: cur.scope`, where `cur.scope` is the NARROWED scope echoed by the
# Microsoft token endpoint (it drops the OIDC scopes `offline_access openid
# profile`, returning only the resource scopes `User.Read Mail.Read …`). The
# plugin persisted that narrowed scope and sent it verbatim on the NEXT
# refresh, so the second refresh onward omitted `offline_access` — the scope
# that AUTHORIZES refresh_token issuance + rotation. Entra then stops renewing
# the refresh_token (and may reject the grant), so the token "sits expired"
# and the next Graph/CRM call surfaces `Authentication required`.
#
# Unlike the source-grep gates (1343 T0/T7, 1650-get-valid-token), this smoke
# drives the REAL plugins/ms365/server.ts via its `get-valid-token` one-shot
# CLI, with `bun --preload` intercepting the Microsoft token endpoint. So it
# exercises the actual getAccessToken → cross-process-lock (#2048) → doRefresh
# glue that ships — not a fork — and it is MUTATION-PROVEN: reverting the
# `withOfflineAccess(...)` fix makes the second-refresh grant drop
# `offline_access` and T1 fails.
#
# Footgun #11: no heredoc/here-string to a subprocess; the preload + harness
# are written to files and passed as argv.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
MS365_TS="$REPO_ROOT/plugins/ms365/server.ts"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
_skip() { TOTAL=$((TOTAL + 1)); printf '[skip] %s\n' "$1"; }

[[ -f "$MS365_TS" ]] || { printf '[FAIL] required file missing: %s\n' "$MS365_TS" >&2; exit 1; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$TMPDIR_BASE/agb-1650-scope-smoke.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT INT TERM

# ---------------------------------------------------------------------------
# T0 (source, runs without bun) — the refresh grant scope is fed through the
# offline_access guard. Guards the symptom-cover line so a refactor cannot
# silently re-introduce the drift.
# ---------------------------------------------------------------------------
T0_ERRORS=""
grep -Eq "function withOfflineAccess" "$MS365_TS" \
  || T0_ERRORS+="server.ts has no withOfflineAccess helper; "
# The refresh_token grant POST scope must be wrapped.
if ! awk '/grant_type: .refresh_token./{f=1} f&&/scope:.*withOfflineAccess/{print "yes"; exit} f&&/\}\)/{f=0}' "$MS365_TS" | grep -q yes; then
  T0_ERRORS+="refresh grant scope not wrapped in withOfflineAccess (drift unguarded); "
fi
if [[ -z "$T0_ERRORS" ]]; then
  _pass "T0: refresh grant scope guarded by withOfflineAccess (source)"
else
  _fail "T0" "$T0_ERRORS"
fi

# ---------------------------------------------------------------------------
# Runtime tests need bun. They drive the REAL server.ts CLI with a mocked
# token endpoint (narrowed-scope responses, the Entra behavior that triggers
# the drift).
# ---------------------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  for t in T1 T2; do _skip "$t: runtime refresh behavior (bun not available)"; done
else
  PRELOAD="$WORK/preload.ts"
  # The interceptor records every grant's requested scope to a probe file and
  # returns a Microsoft-style NARROWED response scope (drops offline_access /
  # openid / profile), which is exactly what reproduces the drift. It never
  # returns a rotated refresh_token, mirroring the "offline_access dropped →
  # no new refresh_token" Entra behavior.
  {
    printf '%s\n' "const realFetch = globalThis.fetch"
    printf '%s\n' "const PROBE = process.env.PROBE_FILE!"  # noqa: iso-helper-boundary (JS process.env in a TS fixture, not an iso agent-env file)
    printf '%s\n' "import { appendFileSync } from 'fs'"
    printf '%s\n' "let n = 0"
    printf '%s\n' "globalThis.fetch = (async (input: any, init?: any) => {"
    printf '%s\n' "  const url = typeof input === 'string' ? input : (input?.url ?? String(input))"
    printf '%s\n' "  if (url.includes('/oauth2/v2.0/token')) {"
    printf '%s\n' "    n++"
    printf '%s\n' "    const sentScope = new URLSearchParams(String(init?.body ?? '')).get('scope') ?? ''"
    printf '%s\n' "    appendFileSync(PROBE, 'scope=[' + sentScope + ']\\n')"
    printf '%s\n' "    const payload = { access_token: 'NEW_ACCESS_' + n, expires_in: 3600, scope: 'User.Read Mail.Read', token_type: 'Bearer' }"
    printf '%s\n' "    return new Response(JSON.stringify(payload), { status: 200, headers: { 'content-type': 'application/json' } })"
    printf '%s\n' "  }"
    printf '%s\n' "  return realFetch(input, init)"
    printf '%s\n' "}) as any"
  } >"$PRELOAD"

  STATE="$WORK/state"
  mkdir -p "$STATE/tokens"
  PROBE="$WORK/probe.txt"
  : >"$PROBE"
  TOKEN="$STATE/tokens/agent_example.com.json"

  # Seed an expired access_token with a present, still-valid refresh_token and
  # the original (offline_access-bearing) scope.
  seed_expired() {
    bun -e "
      const fs=require('fs');
      const now=Math.floor(Date.now()/1000);
      fs.writeFileSync('$TOKEN', JSON.stringify({
        upn:'agent@example.com', access_token:'OLD_ACCESS', refresh_token:'RT_VALID',
        expires_at: now-60, scope:'openid profile offline_access User.Read Mail.Read', saved_at: now-3700
      }));
      fs.chmodSync('$TOKEN', 0o600);
    "
  }

  run_cli() {
    env -i PATH="$PATH" HOME="$HOME" \
      MS365_TENANT_ID="t" MS365_CLIENT_ID="c" MS365_CLIENT_SECRET="s" \
      MS365_DEFAULT_UPN="agent@example.com" \
      MS365_STATE_DIR="$STATE" BRIDGE_HOME="$STATE/bridge" \
      PROBE_FILE="$PROBE" \
      bun --preload "$PRELOAD" "$MS365_TS" get-valid-token 2>>"$WORK/cli.err"
  }

  : >"$WORK/cli.err"
  seed_expired
  OUT1="$(run_cli)"          # refresh 1 (cur.scope still has offline_access)
  seed_expired               # force the NEXT expiry cycle (now reads back the persisted narrowed scope)
  OUT2="$(run_cli)"          # refresh 2 — the drift point
  # NB: seed_expired rewrites the whole token file, so refresh 2 reads the
  # ORIGINAL scope, not the persisted one. To exercise the persisted-scope
  # path, re-expire WITHOUT reseeding for refresh 3.
  bun -e "const fs=require('fs');const p='$TOKEN';const d=JSON.parse(fs.readFileSync(p,'utf8'));d.expires_at=Math.floor(Date.now()/1000)-60;fs.writeFileSync(p,JSON.stringify(d));"
  OUT3="$(run_cli)"          # refresh 3 — reads the PERSISTED scope from refresh 2

  # T1 — every grant requested a scope that includes offline_access. Refresh 2
  # is the one that regresses without the fix (its cur.scope is the original,
  # but refresh 3 reads the persisted scope — both must carry offline_access).
  GRANT_LINES="$(grep -c 'scope=\[' "$PROBE" 2>/dev/null || echo 0)"
  MISSING="$(grep 'scope=\[' "$PROBE" | grep -vc 'offline_access' || true)"
  if [[ "$GRANT_LINES" -ge 3 && "${MISSING:-0}" -eq 0 ]]; then
    _pass "T1: every refresh grant ($GRANT_LINES) requested offline_access (no scope drift)"
  else
    _fail "T1" "grants=$GRANT_LINES missing_offline_access=$MISSING; probe: $(tr '\n' '|' <"$PROBE")"
  fi

  # T2 — the refresh actually fired each cycle (new access_token returned), and
  # the persisted token scope retains offline_access (so future refreshes stay
  # refresh-capable). This is the behavioral guarantee the issue asked for.
  T2_ERRORS=""
  for o in "$OUT1" "$OUT2" "$OUT3"; do
    printf '%s' "$o" | grep -q 'NEW_ACCESS_' || T2_ERRORS+="a refresh cycle returned no fresh access_token; "
  done
  PERSISTED_SCOPE="$(bun -e "console.log(JSON.parse(require('fs').readFileSync('$TOKEN','utf8')).scope)" 2>/dev/null || echo '')"
  printf '%s' "$PERSISTED_SCOPE" | grep -q 'offline_access' \
    || T2_ERRORS+="persisted token scope lost offline_access ('$PERSISTED_SCOPE'); "
  if [[ -z "$T2_ERRORS" ]]; then
    _pass "T2: refresh fired each cycle + persisted scope retains offline_access (refresh-capable)"
  else
    _fail "T2" "$T2_ERRORS"
  fi
fi

printf '[%s] %d/%d passed (FAILS=%d)\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL" "$FAILS"
[[ $FAILS -eq 0 ]] || exit 1
exit 0
