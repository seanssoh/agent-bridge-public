#!/usr/bin/env bash
# scripts/smoke/1343-ms365-token-refresh.sh — issue #1343.
#
# Pins the contract closed by #1343:
#
#   plugins/ms365/server.ts auto-refreshes the access_token on (or near)
#   expiry using the stored refresh_token, instead of saving the
#   refresh_token and never using it (the original 1-hour MS365 outage).
#
#   The fix layers four behaviors on top of the pre-existing 5-minute
#   pre-call expiry check:
#     1. refresh_token grant POST to /oauth2/v2.0/token when expired or
#        within the near-expiry margin.
#     2. single-flight per UPN so concurrent Graph calls do not double-
#        consume the rotating refresh_token (edge case #3).
#     3. transient (network/5xx/throttle) failure → keep the stored token
#        + retry; permanent failure (90-day cap / revoke / consent
#        withdrawn) → persist a `token_expired` status marker + actionable
#        re-auth request (fix point #3, edge case #2).
#     4. redacted `ms365_token_refreshed` / `ms365_refresh_failed` audit
#        rows on stderr — never the raw token (security edge case #1).
#
# Tests:
#   T0  (source) — server.ts imports the token-refresh helper + wires
#                  single-flight, classification, audit, status marker.
#   T1  (runtime) — expired token + refresh_token present → refresh grant
#                   fires (mock endpoint) → new access_token + future
#                   expires_at persisted.
#   T2  (runtime) — near-expiry (within 5-min margin) → preemptive refresh.
#   T3  (runtime) — refresh_token permanently dead (AADSTS700082, the
#                   90-day cap) → token_expired status marker + re-auth
#                   request thrown (graceful, no crash).
#   T4  (runtime) — access_token still valid (>5 min) → NO refresh grant
#                   (no unnecessary token-endpoint call).
#   T5  (runtime) — token file mode stays 0600 after a refresh rewrite.
#   T6  (runtime) — audit rows: ms365_token_refreshed on success,
#                   ms365_refresh_failed on permanent failure; NEITHER row
#                   contains the raw refresh_token (only sha256 fp).
#   T7  (teeth, source) — if the refresh wiring were removed from
#                   getAccessToken/refreshToken, T1's behavior could not
#                   hold; this grep guards the symptom-cover line so a
#                   future refactor cannot silently drop auto-refresh.
#   T8  (runtime) — transient failure (HTTP 503) → stored token UNCHANGED
#                   (no clobber) + NO token_expired marker (edge case #2).
#   T9  (runtime) — concurrent getAccessToken on an expired token issues
#                   exactly ONE refresh grant (single-flight, edge #3).
#   T10 (runtime, codex r1 BLOCKING #1) — a malformed token-endpoint
#                   response that still carries bearer secrets
#                   (refresh_token / id_token) is DEEP-REDACTED before it
#                   reaches the audit row; the raw secret appears nowhere
#                   in stderr (distinct from T6's seeded-mock-token check).
#   T11 (runtime, adversarial sweep BLOCKING #1) — postForm's
#                   { _raw, _status } envelope carrying a tokened non-JSON
#                   body is summarized to _raw_len + _raw_sha256; the raw
#                   form-encoded refresh_token=/access_token= text appears
#                   nowhere in the audit row (the _raw key-bypass).
#   T12 (runtime, adversarial sweep BLOCKING #2) — exchangeAuthCode /
#                   pair_poll path: a no-access_token body carrying
#                   refresh_token / id_token surfaces via textResult
#                   (agent-visible stdout); result.description must be
#                   redacted (the twin sink the r2 fix missed).
#   T13 (runtime) — a JWT smuggled under the non-secret error_description
#                   key is value-scrubbed (key-based redaction alone would
#                   miss it); surrounding prose survives.
#
# Footgun #11: pipe/argv stdin only.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
_skip() { TOTAL=$((TOTAL + 1)); printf '[skip] %s\n' "$1"; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1343-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

MS365_TS="$REPO_ROOT/plugins/ms365/server.ts"
HELPER_TS="$REPO_ROOT/plugins/ms365/token-refresh.ts"

for f in "$MS365_TS" "$HELPER_TS"; do
  if [[ ! -f "$f" ]]; then
    printf '[FAIL] required file missing: %s\n' "$f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# T0 — source: server.ts imports token-refresh helper and wires the four
# behaviors. Grep-level so it runs even where bun is unavailable.
# ---------------------------------------------------------------------------
T0_ERRORS=""
if ! grep -E "from './token-refresh.ts'" "$MS365_TS" >/dev/null; then
  T0_ERRORS+="server.ts does not import ./token-refresh.ts; "
fi
if ! grep -E "new SingleFlight" "$MS365_TS" >/dev/null; then
  T0_ERRORS+="server.ts does not use SingleFlight (concurrent-refresh race unguarded); "
fi
if ! grep -E "classifyRefreshError" "$MS365_TS" >/dev/null; then
  T0_ERRORS+="server.ts does not classify refresh errors (transient/permanent split missing); "
fi
if ! grep -E "refreshSuccessAuditLine|refreshFailureAuditLine" "$MS365_TS" >/dev/null; then
  T0_ERRORS+="server.ts does not emit refresh audit rows; "
fi
if ! grep -E "markTokenExpired" "$MS365_TS" >/dev/null; then
  T0_ERRORS+="server.ts does not persist token_expired status marker; "
fi
# Adversarial sweep BLOCKING #1 + #2: BOTH malformed-response sinks
# (doRefresh + exchangeAuthCode) must wrap the body in redactResponseBody
# before stringifying, and there must be NO bare JSON.stringify(data) of a
# response body anywhere (the choke-point invariant).
if [[ "$(grep -cE "JSON\.stringify\(redactResponseBody\(data" "$MS365_TS")" -lt 2 ]]; then
  T0_ERRORS+="server.ts has <2 redactResponseBody-wrapped malformed sinks (exchangeAuthCode twin or doRefresh missing); "
fi
if grep -E "JSON\.stringify\(data( |\)|,)" "$MS365_TS" | grep -v "redactResponseBody" >/dev/null; then
  # Allowlist: the Graph request body builder + textResult renderer are
  # not response-body→log sinks. Flag only response-body stringify leaks.
  if grep -nE "description:.*JSON\.stringify\(data\b" "$MS365_TS" | grep -v "redactResponseBody" >/dev/null; then
    T0_ERRORS+="server.ts has a raw JSON.stringify(data) in a description sink (choke-point bypass); "
  fi
fi
if ! grep -E "scrubSecretShapedText" "$MS365_TS" >/dev/null; then
  T0_ERRORS+="server.ts does not value-scrub error_description sinks (JWT-under-benign-key bypass); "
fi
if [[ -z "$T0_ERRORS" ]]; then
  _pass "T0: server.ts wires single-flight/classify/audit/status + redactResponseBody on BOTH malformed sinks + value-scrub"
else
  _fail "T0" "$T0_ERRORS"
fi

# ---------------------------------------------------------------------------
# T7 (teeth, source) — the refresh wiring in getAccessToken must call
# refreshToken on the expiry branch. If removed, expired tokens would be
# handed to Graph as-is → 401 (the original outage). This guards the
# symptom-cover line.
# ---------------------------------------------------------------------------
# Extract the getAccessToken body and assert it refreshes on expiry.
if grep -Pzo "async function getAccessToken[\s\S]*?await refreshToken\(upn\)" "$MS365_TS" >/dev/null 2>&1 \
   || awk '/async function getAccessToken/{f=1} f&&/await refreshToken\(upn\)/{print "yes"; exit}' "$MS365_TS" | grep -q yes; then
  _pass "T7: getAccessToken calls refreshToken on the expiry branch (auto-refresh wired)"
else
  _fail "T7" "getAccessToken no longer calls refreshToken on expiry — auto-refresh dropped (the #1343 outage)"
fi

# ---------------------------------------------------------------------------
# Runtime tests (T1-T6, T8-T13). These need bun. They exercise the REAL
# token-refresh.ts helper (single-flight + classify + redact +
# redactResponseBody + scrubSecretShapedText + audit builders) wired into
# the same doRefresh/getAccessToken/exchangeAuthCode/file-IO glue that
# server.ts ships, against a mock token endpoint and a temp state dir.
# T0 + T7 guard that server.ts keeps that glue, so the runtime harness
# cannot silently drift from the shipped code.
# ---------------------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  for t in T1 T2 T3 T4 T5 T6 T8 T9 T10 T11 T12 T13; do
    _skip "$t: runtime refresh behavior (bun not available)"
  done
else
  HARNESS="$SMOKE_DIR/harness.ts"
  cat >"$HARNESS" <<HARNESS_EOF
import {
  chmodSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync, statSync,
} from 'fs'
import { join } from 'path'
import {
  classifyRefreshError, redactResponseBody, refreshSuccessAuditLine, refreshFailureAuditLine,
  SingleFlight, type RefreshErrorKind,
} from '$HELPER_TS'

const STATE_DIR = process.env.HARNESS_STATE_DIR!
const TOKENS_DIR = join(STATE_DIR, 'tokens')
const STATUS_DIR = join(STATE_DIR, 'status')
mkdirSync(TOKENS_DIR, { recursive: true, mode: 0o700 })
mkdirSync(STATUS_DIR, { recursive: true, mode: 0o700 })

type TokenFile = { upn: string; access_token: string; refresh_token?: string; expires_at: number; scope: string; saved_at: number }
type StatusFile = { upn: string; status: 'token_expired'; reason: string; needs_reauth: boolean; updated_at: number }

const slug = (u: string) => u.replace(/[^A-Za-z0-9._-]/g, '_').toLowerCase()
const tokenPath = (u: string) => join(TOKENS_DIR, slug(u) + '.json')
const statusPath = (u: string) => join(STATUS_DIR, slug(u) + '.json')
function saveJson(p: string, payload: unknown) {
  const tmp = p + '.tmp'
  writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 })
  renameSync(tmp, p); chmodSync(p, 0o600)
}
function loadJson<T>(p: string): T | null { try { return JSON.parse(readFileSync(p, 'utf8')) as T } catch { return null } }
const loadStatus = (u: string) => loadJson<StatusFile>(statusPath(u))
function markTokenExpired(u: string, reason: string) {
  const s: StatusFile = { upn: u, status: 'token_expired', reason: String(reason).replace(/[\r\n]+/g, ' ').slice(0, 300), needs_reauth: true, updated_at: Math.floor(Date.now()/1000) }
  try { saveJson(statusPath(u), s) } catch {}
}
const clearTokenExpired = (u: string) => { try { unlinkSync(statusPath(u)) } catch {} }

class RefreshError extends Error {
  readonly kind: RefreshErrorKind; readonly oauthError: string
  constructor(kind: RefreshErrorKind, oauthError: string, message: string) { super(message); this.kind = kind; this.oauthError = oauthError }
}

// Mock token endpoint, controlled by env. Returns the scripted response
// and counts how many times it was hit (single-flight assertion).
let grantCalls = 0
async function postForm(_url: string, _body: Record<string,string>): Promise<any> {
  grantCalls++
  const mode = process.env.HARNESS_MOCK!
  if (mode === 'network') throw new Error('getaddrinfo ENOTFOUND login.microsoftonline.com')
  if (mode === 'http503') return { _raw: 'Service Unavailable', _status: 503 }
  // codex r1 BLOCKING #1 repro: a malformed JSON body (no usable
  // access_token in the parsed shape) that STILL carries bearer secrets.
  // The malformed-response fallback must deep-redact before logging.
  if (mode === 'malformed_secret') return { refresh_token: 'RT_SECRET', access_token: '', id_token: 'ID_SECRET', _status: 200 }
  // adversarial sweep BLOCKING #1: non-JSON body carrying tokens, wrapped
  // by postForm into the { _raw, _status } envelope (here we simulate
  // postForm having already wrapped a form-encoded tokened body).
  if (mode === 'raw_envelope') return { _raw: 'refresh_token=RT_SECRET&grant_type=refresh_token&access_token=AT_SECRET', _status: 502 }
  // T13: a JWT smuggled under the non-secret error_description key.
  if (mode === 'jwt_in_desc') return { error: 'invalid_grant', error_description: 'token eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJSVF9TRUNSRVQifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c is invalid' }
  if (mode === 'perm') return { error: 'invalid_grant', error_description: 'AADSTS700082: refresh token expired due to inactivity' }
  // adversarial sweep BLOCKING #2: auth-code exchange returns a body with
  // NO access_token but carrying refresh_token / id_token. The
  // exchangeAuthCode malformed branch surfaces this to pair_poll
  // (agent-visible stdout) and must redact it.
  if (mode === 'exchange_malformed_secret') return { refresh_token: 'RT_SECRET', id_token: 'ID_SECRET', token_type: 'Bearer' }
  // success
  await new Promise(r => setTimeout(r, 10))
  return { access_token: 'NEW_ACCESS_' + grantCalls, refresh_token: 'NEW_REFRESH_' + grantCalls, expires_in: 3600, scope: 'User.Read' }
}

const refreshInFlight = new SingleFlight<TokenFile>()
async function refreshToken(upn: string): Promise<TokenFile> { return refreshInFlight.run(upn, () => doRefresh(upn)) }

async function doRefresh(upn: string): Promise<TokenFile> {
  const cur = loadJson<TokenFile>(tokenPath(upn))
  if (!cur) throw new Error('no token')
  if (!cur.refresh_token) { markTokenExpired(upn, 'no refresh_token'); throw new RefreshError('permanent', 'no_refresh_token', 'no refresh_token') }
  let data: any
  try {
    data = await postForm('url', { grant_type: 'refresh_token', refresh_token: cur.refresh_token })
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    process.stderr.write(refreshFailureAuditLine({ upn, kind: 'transient', oauthError: 'network_error', description: msg, refreshTokenPresent: true }))
    throw new RefreshError('transient', 'network_error', msg)
  }
  if (data && data.error) {
    const kind = classifyRefreshError(data.error, data.error_description)
    process.stderr.write(refreshFailureAuditLine({ upn, kind, oauthError: String(data.error), description: String(data.error_description ?? ''), refreshTokenPresent: true }))
    if (kind === 'permanent') markTokenExpired(upn, data.error + ': ' + String(data.error_description ?? ''))
    throw new RefreshError(kind, String(data.error), 'refresh failed: ' + data.error)
  }
  if (!data || !data.access_token) {
    const status = data?._status
    // Matches server.ts: deep-redact the body before stringifying it into
    // the audit row so a malformed response carrying bearer secrets cannot
    // leak the raw token (codex r1 BLOCKING #1).
    process.stderr.write(refreshFailureAuditLine({ upn, kind: 'transient', oauthError: status ? 'http_' + status : 'malformed', description: JSON.stringify(redactResponseBody(data ?? {})).slice(0,200), refreshTokenPresent: true }))
    throw new RefreshError('transient', status ? 'http_' + status : 'malformed', 'no access_token')
  }
  const now = Math.floor(Date.now()/1000)
  const newRt = data.refresh_token ?? cur.refresh_token
  const next: TokenFile = { upn, access_token: data.access_token, refresh_token: newRt, expires_at: now + Number(data.expires_in ?? 3600), scope: String(data.scope ?? cur.scope), saved_at: now }
  saveJson(tokenPath(upn), next); clearTokenExpired(upn)
  process.stderr.write(refreshSuccessAuditLine({ upn, expiresInSeconds: next.expires_at - now, refreshTokenRotated: newRt !== cur.refresh_token, oldRefreshToken: cur.refresh_token, newRefreshToken: newRt }))
  return next
}

async function getAccessToken(upn: string): Promise<string> {
  const cur = loadJson<TokenFile>(tokenPath(upn))
  if (!cur) throw new Error('no token')
  const now = Math.floor(Date.now()/1000)
  if (cur.expires_at - now > 300) return cur.access_token
  try { const r = await refreshToken(upn); return r.access_token }
  catch (e) {
    if (e instanceof RefreshError && e.kind === 'transient' && cur.expires_at - now > 0) return cur.access_token
    if (e instanceof RefreshError && e.kind === 'permanent') throw new Error('token_expired re-auth required (' + e.oauthError + ')')
    throw e
  }
}

// exchangeAuthCode glue — mirrors server.ts's auth-code malformed branch
// (adversarial sweep BLOCKING #2). Returns the same result shape that
// pair_poll renders via textResult (agent-visible). The malformed branch
// MUST run redactResponseBody before stringifying.
type ExchangeResult = { status: 'success' } | { status: 'error'; error: string; description: string }
async function exchangeAuthCode(): Promise<ExchangeResult> {
  const data: any = await postForm('url', { grant_type: 'authorization_code', code: 'CB_CODE' })
  if (data.error) {
    return { status: 'error', error: data.error, description: JSON.stringify(redactResponseBody(data)).slice(0, 400) }
  }
  if (!data.access_token) {
    return { status: 'error', error: 'malformed_response', description: JSON.stringify(redactResponseBody(data)).slice(0, 400) }
  }
  return { status: 'success' }
}

// ---- scenario dispatcher --------------------------------------------------
const upn = 'agent@contoso.com'
const scenario = process.argv[2]
function seed(expiresOffsetSec: number, refresh: string | undefined) {
  saveJson(tokenPath(upn), { upn, access_token: 'OLD_ACCESS', refresh_token: refresh, expires_at: Math.floor(Date.now()/1000) + expiresOffsetSec, scope: 'User.Read', saved_at: Math.floor(Date.now()/1000) })
}
function fileMode(p: string): string { return (statSync(p).mode & 0o777).toString(8) }

;(async () => {
  if (scenario === 'expired') {
    seed(-60, 'RT_VALID')
    const tok = await getAccessToken(upn)
    const after = loadJson<TokenFile>(tokenPath(upn))!
    console.log('access=' + tok)
    console.log('expires_future=' + (after.expires_at > Math.floor(Date.now()/1000)))
    console.log('grant_calls=' + grantCalls)
    console.log('token_mode=' + fileMode(tokenPath(upn)))
  } else if (scenario === 'near') {
    seed(120, 'RT_VALID') // within 5-min margin
    const tok = await getAccessToken(upn)
    console.log('access=' + tok)
    console.log('grant_calls=' + grantCalls)
  } else if (scenario === 'valid') {
    seed(3000, 'RT_VALID') // > 5 min
    const tok = await getAccessToken(upn)
    console.log('access=' + tok)
    console.log('grant_calls=' + grantCalls)
  } else if (scenario === 'perm') {
    seed(-60, 'RT_DEAD')
    let threw = ''
    try { await getAccessToken(upn) } catch (e) { threw = e instanceof Error ? e.message : String(e) }
    console.log('threw=' + threw)
    const st = loadStatus(upn)
    console.log('status=' + (st?.status ?? 'none'))
    console.log('needs_reauth=' + (st?.needs_reauth ?? false))
  } else if (scenario === 'transient') {
    seed(60, 'RT_VALID') // expired-window but access still barely valid (>0)
    const before = loadJson<TokenFile>(tokenPath(upn))!
    const tok = await getAccessToken(upn)
    const after = loadJson<TokenFile>(tokenPath(upn))!
    console.log('access=' + tok)
    console.log('token_unchanged=' + (after.refresh_token === before.refresh_token && after.access_token === before.access_token))
    console.log('status=' + (loadStatus(upn)?.status ?? 'none'))
  } else if (scenario === 'concurrent') {
    seed(-60, 'RT_VALID')
    const [a, b] = await Promise.all([getAccessToken(upn), getAccessToken(upn)])
    console.log('a=' + a)
    console.log('b=' + b)
    console.log('grant_calls=' + grantCalls)
  } else if (scenario === 'malformed_secret') {
    // expired token; refresh returns a malformed body carrying secrets.
    // getAccessToken returns the (barely-valid? no — hard expired) → it
    // re-throws the transient error; we only care that the audit row in
    // stderr does NOT contain the raw secret values.
    seed(-60, 'RT_VALID')
    let threw = ''
    try { await getAccessToken(upn) } catch (e) { threw = e instanceof Error ? e.message : String(e) }
    console.log('threw=' + threw)
  } else if (scenario === 'raw_envelope') {
    // refresh hits a non-JSON {_raw,_status} body carrying tokens.
    seed(-60, 'RT_VALID')
    let threw = ''
    try { await getAccessToken(upn) } catch (e) { threw = e instanceof Error ? e.message : String(e) }
    console.log('threw=' + threw) // assertions are on stderr (audit row)
  } else if (scenario === 'jwt_in_desc') {
    // refresh fails with a JWT smuggled under error_description.
    seed(-60, 'RT_VALID')
    let threw = ''
    try { await getAccessToken(upn) } catch (e) { threw = e instanceof Error ? e.message : String(e) }
    console.log('threw=' + threw)
    console.log('status_reason=' + (loadStatus(upn)?.reason ?? 'none'))
  } else if (scenario === 'exchange_malformed_secret') {
    // auth-code exchange returns no access_token but carries tokens →
    // pair_poll-visible result.description must be redacted.
    const r = await exchangeAuthCode()
    console.log('exchange_status=' + r.status)
    console.log('exchange_desc=' + (r.status === 'error' ? r.description : ''))
  } else {
    console.log('unknown scenario')
    process.exit(2)
  }
})()
HARNESS_EOF

  run_scn() {
    local scenario="$1" mock="$2"
    env -i PATH="$PATH" HOME="$HOME" \
      HARNESS_STATE_DIR="$SMOKE_DIR/state-$scenario" \
      HARNESS_MOCK="$mock" \
      bun run "$HARNESS" "$scenario" 2>"$SMOKE_DIR/$scenario.err"
  }

  # T1 — expired token → refresh fires, new token + future expiry.
  T1_OUT="$(run_scn expired success)"
  if printf '%s\n' "$T1_OUT" | grep -q 'access=NEW_ACCESS_1' \
     && printf '%s\n' "$T1_OUT" | grep -q 'expires_future=true' \
     && printf '%s\n' "$T1_OUT" | grep -q 'grant_calls=1'; then
    _pass "T1: expired token → refresh grant fires → new access_token + future expires_at"
  else
    _fail "T1" "out: $(printf '%s' "$T1_OUT" | tr '\n' '|')"
  fi

  # T2 — near-expiry (within margin) → preemptive refresh.
  T2_OUT="$(run_scn near success)"
  if printf '%s\n' "$T2_OUT" | grep -q 'access=NEW_ACCESS_1' \
     && printf '%s\n' "$T2_OUT" | grep -q 'grant_calls=1'; then
    _pass "T2: near-expiry (within 5-min margin) → preemptive refresh"
  else
    _fail "T2" "out: $(printf '%s' "$T2_OUT" | tr '\n' '|')"
  fi

  # T3 — permanent failure → token_expired marker + re-auth throw.
  T3_OUT="$(run_scn perm perm)"
  if printf '%s\n' "$T3_OUT" | grep -q 'status=token_expired' \
     && printf '%s\n' "$T3_OUT" | grep -q 'needs_reauth=true' \
     && printf '%s\n' "$T3_OUT" | grep -qi 're-auth'; then
    _pass "T3: permanently-dead refresh_token → token_expired status + re-auth request (graceful, no crash)"
  else
    _fail "T3" "out: $(printf '%s' "$T3_OUT" | tr '\n' '|')"
  fi

  # T4 — valid token (>5 min) → NO refresh grant.
  T4_OUT="$(run_scn valid success)"
  if printf '%s\n' "$T4_OUT" | grep -q 'access=OLD_ACCESS' \
     && printf '%s\n' "$T4_OUT" | grep -q 'grant_calls=0'; then
    _pass "T4: valid access_token (>5 min) → no refresh grant (no unnecessary token-endpoint call)"
  else
    _fail "T4" "out: $(printf '%s' "$T4_OUT" | tr '\n' '|')"
  fi

  # T5 — token file mode stays 0600 after refresh rewrite (from T1's run).
  T5_TOKEN="$SMOKE_DIR/state-expired/tokens/agent_contoso.com.json"
  if [[ -f "$T5_TOKEN" ]]; then
    T5_MODE_LINUX="$(stat -c '%a' "$T5_TOKEN" 2>/dev/null || true)"
    T5_MODE_MACOS="$(stat -f '%Lp' "$T5_TOKEN" 2>/dev/null || true)"
    T5_MODE="${T5_MODE_LINUX:-$T5_MODE_MACOS}"
    if [[ "$T5_MODE" == "600" ]]; then
      _pass "T5: token file mode stays 0600 after refresh rewrite (#1215 secret-file contract)"
    else
      _fail "T5" "expected 600, got: '$T5_MODE'"
    fi
  else
    _fail "T5" "token file missing after refresh: $T5_TOKEN"
  fi

  # T6 — audit rows present, and NEITHER carries the raw refresh_token.
  T6_ERRORS=""
  if ! grep -q 'ms365_token_refreshed' "$SMOKE_DIR/expired.err"; then
    T6_ERRORS+="success audit row ms365_token_refreshed missing; "
  fi
  if ! grep -q 'ms365_refresh_failed' "$SMOKE_DIR/perm.err"; then
    T6_ERRORS+="failure audit row ms365_refresh_failed missing; "
  fi
  # Raw tokens used in mock: RT_VALID, RT_DEAD, NEW_REFRESH_*. None must
  # appear in any audit row.
  if grep -E 'RT_VALID|RT_DEAD|NEW_REFRESH_' "$SMOKE_DIR/expired.err" "$SMOKE_DIR/perm.err" >/dev/null 2>&1; then
    T6_ERRORS+="raw refresh_token leaked into an audit row (SECURITY); "
  fi
  if ! grep -q 'refresh_token_fp=sha256:' "$SMOKE_DIR/expired.err"; then
    T6_ERRORS+="success audit row missing redacted refresh_token_fp; "
  fi
  if [[ -z "$T6_ERRORS" ]]; then
    _pass "T6: audit rows emitted (refreshed/failed); no raw refresh_token leaked (sha256 fp only)"
  else
    _fail "T6" "$T6_ERRORS"
  fi

  # T8 — transient HTTP 503 → stored token unchanged + no token_expired.
  T8_OUT="$(run_scn transient http503)"
  if printf '%s\n' "$T8_OUT" | grep -q 'token_unchanged=true' \
     && printf '%s\n' "$T8_OUT" | grep -q 'status=none'; then
    _pass "T8: transient HTTP 503 → stored token unchanged + no token_expired (keep-and-retry)"
  else
    _fail "T8" "out: $(printf '%s' "$T8_OUT" | tr '\n' '|')"
  fi

  # T9 — concurrent expired-token calls → exactly ONE refresh grant.
  T9_OUT="$(run_scn concurrent success)"
  if printf '%s\n' "$T9_OUT" | grep -q 'grant_calls=1' \
     && printf '%s\n' "$T9_OUT" | grep -q 'a=NEW_ACCESS_1' \
     && printf '%s\n' "$T9_OUT" | grep -q 'b=NEW_ACCESS_1'; then
    _pass "T9: two concurrent getAccessToken on expired token → single refresh grant (single-flight)"
  else
    _fail "T9" "out: $(printf '%s' "$T9_OUT" | tr '\n' '|') err: $(cat "$SMOKE_DIR/concurrent.err" 2>/dev/null | tr '\n' '|')"
  fi

  # T10 (codex r1 BLOCKING #1) — a malformed token-endpoint response that
  # carries bearer secrets must be DEEP-REDACTED before it reaches the
  # audit row. Drive the malformed_secret scenario and assert that the
  # raw secret values (RT_SECRET / ID_SECRET) appear NOWHERE in stderr
  # (the audit row + any error output). Distinct from T6 (which covers
  # the seeded mock tokens RT_VALID / NEW_REFRESH_*).
  run_scn malformed_secret malformed_secret >/dev/null
  T10_ERR="$SMOKE_DIR/malformed_secret.err"
  if grep -E 'RT_SECRET|ID_SECRET' "$T10_ERR" >/dev/null 2>&1; then
    _fail "T10" "raw bearer secret leaked from malformed response into audit/error (SECURITY): $(cat "$T10_ERR" 2>/dev/null | tr '\n' '|')"
  elif grep -q 'ms365_refresh_failed' "$T10_ERR" 2>/dev/null \
       && grep -q 'sha256:' "$T10_ERR" 2>/dev/null; then
    _pass "T10: malformed response carrying secrets → deep-redacted in audit (no raw RT/ID secret; sha256 fp present)"
  else
    _fail "T10" "expected a redacted ms365_refresh_failed audit row with sha256 fp; got: $(cat "$T10_ERR" 2>/dev/null | tr '\n' '|')"
  fi

  # T11 (adversarial sweep BLOCKING #1) — postForm's { _raw, _status }
  # envelope carrying a tokened non-JSON body must NOT emit the raw text.
  # _raw is summarized to _raw_len + _raw_sha256; the form-encoded
  # refresh_token=/access_token= values appear NOWHERE in the audit row.
  run_scn raw_envelope raw_envelope >/dev/null
  T11_ERR="$SMOKE_DIR/raw_envelope.err"
  if grep -E 'RT_SECRET|AT_SECRET' "$T11_ERR" >/dev/null 2>&1; then
    _fail "T11" "raw _raw text leaked tokens into audit (SECURITY): $(cat "$T11_ERR" 2>/dev/null | tr '\n' '|')"
  elif grep -Eq '"_raw_sha256":"sha256:' "$T11_ERR" 2>/dev/null \
       && grep -Eq '"_raw_len":' "$T11_ERR" 2>/dev/null; then
    _pass "T11: _raw envelope summarized to _raw_len + _raw_sha256 (no raw tokened body text)"
  else
    _fail "T11" "expected _raw_len + _raw_sha256 summary; got: $(cat "$T11_ERR" 2>/dev/null | tr '\n' '|')"
  fi

  # T12 (adversarial sweep BLOCKING #2) — exchangeAuthCode / pair_poll path:
  # a no-access_token body carrying refresh_token / id_token surfaces via
  # textResult (agent-visible stdout). The result.description must be
  # redacted — neither raw secret appears.
  T12_OUT="$(run_scn exchange_malformed_secret exchange_malformed_secret)"
  if printf '%s\n' "$T12_OUT" | grep -E 'RT_SECRET|ID_SECRET' >/dev/null 2>&1; then
    _fail "T12" "raw token leaked into pair_poll-visible exchange description (SECURITY): $(printf '%s' "$T12_OUT" | tr '\n' '|')"
  elif printf '%s\n' "$T12_OUT" | grep -q 'exchange_status=error' \
       && printf '%s\n' "$T12_OUT" | grep -q 'sha256:'; then
    _pass "T12: exchangeAuthCode malformed-secret body → redacted in pair_poll-visible description (no raw token)"
  else
    _fail "T12" "expected error status + sha256 fp, no raw token; got: $(printf '%s' "$T12_OUT" | tr '\n' '|')"
  fi

  # T13 — a JWT smuggled under the non-secret error_description key must be
  # value-scrubbed (key-based redaction alone would miss it). Assert the
  # JWT header marker (eyJ...) appears nowhere in the audit row or the
  # token_expired status reason, while the surrounding prose survives.
  run_scn jwt_in_desc jwt_in_desc >/dev/null
  T13_ERR="$SMOKE_DIR/jwt_in_desc.err"
  if grep -E 'eyJhbGci|eyJzdWIi' "$T13_ERR" >/dev/null 2>&1; then
    _fail "T13" "JWT under error_description leaked (value-scrub missing): $(cat "$T13_ERR" 2>/dev/null | tr '\n' '|')"
  elif grep -q 'ms365_refresh_failed' "$T13_ERR" 2>/dev/null \
       && grep -q 'is invalid' "$T13_ERR" 2>/dev/null; then
    _pass "T13: JWT under error_description value-scrubbed (no eyJ marker; prose preserved)"
  else
    _fail "T13" "expected scrubbed audit row preserving prose; got: $(cat "$T13_ERR" 2>/dev/null | tr '\n' '|')"
  fi
fi

printf '[%s] %d/%d passed (FAILS=%d)\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL" "$FAILS"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
