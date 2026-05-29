/**
 * MS365 token-refresh support — issue #1343.
 *
 * The 1-hour MS365 outage closed by #1343 was NOT "refresh logic missing"
 * (server.ts already had a `refreshToken()` + a 5-minute pre-call expiry
 * check in `getAccessToken()`). The outage came from the refresh path
 * failing *opaquely and unrecoverably*:
 *
 *   1. Two concurrent Graph calls both crossed the expiry threshold and
 *      both fired a refresh_token grant. Entra rotates the refresh_token
 *      on each grant, so the second POST presented an already-consumed
 *      refresh_token → AADSTS invalid_grant → the token file was
 *      clobbered into a permanently-broken state, requiring manual
 *      re-auth. (Edge case #3: concurrent refresh race.)
 *
 *   2. A transient network blip on the single refresh attempt threw and
 *      was surfaced to the agent as a generic Graph error. The still-
 *      present (just-expired) token was never recovered and there was no
 *      retry, so every subsequent call re-threw. (Edge case #2: network
 *      fail must keep the existing token + retry, not invalidate.)
 *
 *   3. A genuinely-expired-or-revoked refresh_token (the 90-day cap, or
 *      an admin revoke) produced the same opaque Graph error as a
 *      transient blip, with zero operator-visible signal and no
 *      actionable re-auth request. (Fix point #3 + #4.)
 *
 * This module supplies the building blocks that close those gaps without
 * leaking the refresh_token into any log or audit line:
 *
 *   - `classifyRefreshError`        — transient vs permanent split.
 *   - `redactToken`                 — sha256(:12) fingerprint for audit.
 *   - `tokenStatusLine` / audit row builders — grep-friendly stderr,
 *     mirroring the Teams plugin's `<channel> channel: <event> k=v` form.
 *   - `SingleFlight`                — per-key promise coalescing so two
 *     concurrent Graph calls share one refresh round-trip.
 *
 * Nothing here performs I/O against the token file or the network; that
 * stays in server.ts so the secret-file mode contract (#1215, 0o600)
 * lives in exactly one place.
 */

import { createHash } from 'crypto'

/**
 * Entra/AAD refresh_token grant failures split into two buckets:
 *
 *   - `permanent`  — the refresh_token is dead (expired past the 90-day
 *     cap, revoked, consent withdrawn, account disabled). Re-auth is the
 *     only fix; retrying the same refresh_token will never succeed. The
 *     channel should mark `token_expired` and request re-auth.
 *   - `transient`  — a network blip, a 5xx from login.microsoftonline.com,
 *     throttling (`temporarily_unavailable`), or an indeterminate error.
 *     The existing token must be preserved and the next pre-call attempt
 *     may retry. NEVER invalidate the stored token on a transient error.
 *
 * The classification keys off the OAuth2 `error` code and the AADSTS
 * sub-code embedded in `error_description`. When in doubt we default to
 * `transient` — invalidating a still-good refresh_token (forcing a manual
 * re-auth) is strictly worse than one extra retry.
 */
export type RefreshErrorKind = 'transient' | 'permanent'

// AADSTS sub-codes that mean "this refresh_token will never work again".
// Sourced from Microsoft Identity Platform error reference.
//   AADSTS700082 — refresh token expired due to inactivity (the 90-day cap)
//   AADSTS700084 — refresh token issued to a single-page-app expired
//   AADSTS50173  — session revoked (password change / admin revoke)
//   AADSTS50078 / AADSTS50076 — MFA / conditional-access re-challenge
//   AADSTS65001  — consent withdrawn / not granted
//   AADSTS70000  — invalid grant (generic, but for grant_type=refresh_token
//                  it means the token is no longer redeemable)
const PERMANENT_AADSTS = [
  'AADSTS700082',
  'AADSTS700084',
  'AADSTS50173',
  'AADSTS50078',
  'AADSTS50076',
  'AADSTS65001',
  'AADSTS70000',
]

// OAuth2 top-level error codes that are unambiguously permanent for a
// refresh_token grant. `invalid_grant` is the canonical "this code/token
// can't be redeemed" signal; `invalid_client` / `unauthorized_client`
// mean the app registration is wrong (also not retry-fixable).
const PERMANENT_OAUTH_ERRORS = ['invalid_grant', 'invalid_client', 'unauthorized_client']

// OAuth2 error codes that are explicitly retryable.
const TRANSIENT_OAUTH_ERRORS = ['temporarily_unavailable', 'server_error']

export function classifyRefreshError(
  oauthError: string | undefined,
  errorDescription: string | undefined,
): RefreshErrorKind {
  const err = String(oauthError ?? '').trim().toLowerCase()
  const desc = String(errorDescription ?? '')

  // An AADSTS permanent sub-code is decisive regardless of the top-level
  // OAuth error (Entra often wraps a permanent sub-code in invalid_grant).
  for (const code of PERMANENT_AADSTS) {
    if (desc.includes(code)) return 'permanent'
  }
  if (TRANSIENT_OAUTH_ERRORS.includes(err)) return 'transient'
  if (PERMANENT_OAUTH_ERRORS.includes(err)) return 'permanent'
  // Unknown / network-level / indeterminate → transient (safe default:
  // keep the token, retry, never force a manual re-auth on a guess).
  return 'transient'
}

/**
 * Produce a non-reversible fingerprint of a secret for audit lines.
 *
 * The refresh_token (and access_token) are themselves bearer credentials.
 * They MUST NOT appear in any log, audit row, or error message. When ops
 * needs to correlate "the token rotated" across two audit lines, a stable
 * sha256 prefix is enough — it confirms identity/rotation without exposing
 * the secret. An empty/missing token yields `none` so the audit line still
 * renders.
 */
export function redactToken(token: string | undefined | null): string {
  const s = String(token ?? '')
  if (!s) return 'none'
  return 'sha256:' + createHash('sha256').update(s).digest('hex').slice(0, 12)
}

// Keys whose VALUES are bearer secrets / authorization material and must
// never reach a log, audit row, or error string in cleartext. Matched
// case-insensitively as a substring so `client_secret`, `id_token`,
// `device_code`, etc. are all caught.
const SECRET_KEY_PATTERN = /(refresh_token|access_token|id_token|token|secret|client_secret|code|assertion|password)/i

// Issue #1343 (adversarial sweep BLOCKING #1, defense-in-depth): scrub
// token-SHAPED substrings out of any string value, regardless of the key
// it lives under. This catches secrets smuggled under a non-secret key —
// e.g. a JWT embedded in `error_description`, or a token endpoint that
// returns a form-encoded body whose text lands in `_raw`. The patterns
// are deliberately TIGHT so ordinary error prose is not mangled:
//
//   1. JWT — three base64url segments separated by dots, `eyJ...` header.
//   2. OAuth form-encoded credential params: `<param>=<value>` where the
//      param name is a known secret key and the value is a non-trivial
//      token run (8+ chars of token alphabet). Matches the
//      `refresh_token=...&grant_type=...` body shape.
//   3. Long base64url runs (40+ chars) that look like opaque bearer
//      tokens. 40 is above any realistic English word / GUID-with-dashes
//      so prose survives; AADSTS codes (`AADSTS700082`) are far shorter.
//
// Each match is replaced with the match's sha256:12 fingerprint so ops
// can still correlate a repeated leak without seeing the secret.
const JWT_RE = /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g
const FORM_CRED_RE = /\b(refresh_token|access_token|id_token|code|assertion)=([A-Za-z0-9._~+/=%-]{8,})/gi
const LONG_B64URL_RE = /\b[A-Za-z0-9_-]{40,}\b/g

export function scrubSecretShapedText(input: string): string {
  let s = String(input)
  s = s.replace(JWT_RE, m => redactToken(m))
  s = s.replace(FORM_CRED_RE, (_m, param: string, value: string) => `${param}=${redactToken(value)}`)
  s = s.replace(LONG_B64URL_RE, m => redactToken(m))
  return s
}

/**
 * Issue #1343 (codex r1 BLOCKING #1 + adversarial sweep BLOCKING #1):
 * deep-redact a token-endpoint response body before it is stringified
 * into an audit row, a thrown error, OR an agent-visible textResult.
 *
 * The malformed-response fallback used to `JSON.stringify(data)` the raw
 * body. Two leak classes follow from that:
 *   - a malformed JSON object that still carried a `refresh_token` /
 *     `access_token` / `id_token` (closed by key-based redaction); and
 *   - the `postForm` non-JSON envelope `{ _raw: <text>, _status }`, whose
 *     `_raw` is NOT a secret key, so a token endpoint / proxy that
 *     returns a form-encoded or HTML body carrying tokens leaked the raw
 *     text (the adversarial-sweep bypass).
 *
 * This walks the object recursively and returns a SAFE COPY (the original
 * `data` is never mutated):
 *   - `_raw` is NEVER emitted as text — it is summarized to
 *     `{ _raw_len, _raw_sha256 }` (status + length + fingerprint is enough
 *     for ops triage; the unparseable body's diagnostic value does not
 *     justify the leak risk).
 *   - Values under a secret-looking key → `redactToken` (string) or
 *     `'<redacted>'` (non-string).
 *   - Every OTHER string value is run through `scrubSecretShapedText` so a
 *     token smuggled under a benign key (JWT in `error_description`, etc.)
 *     is still neutralized.
 *   - Arrays and nested objects are walked element-by-element.
 *   - Non-object input: a top-level string is scrubbed; other primitives
 *     pass through.
 *
 * A depth guard bounds pathological/cyclic inputs.
 */
export function redactResponseBody(data: unknown, depth = 0): unknown {
  if (depth > 8) return '<max-depth>'
  if (data === null) return null
  if (typeof data === 'string') return scrubSecretShapedText(data)
  if (typeof data !== 'object') return data
  if (Array.isArray(data)) {
    return data.map(item => redactResponseBody(item, depth + 1))
  }
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(data as Record<string, unknown>)) {
    if (key === '_raw') {
      // postForm's non-JSON envelope. Never emit the raw text — a proxy /
      // endpoint can stuff a tokened form-encoded or HTML body here.
      const raw = String(value ?? '')
      out._raw_len = raw.length
      out._raw_sha256 = redactToken(raw)
    } else if (SECRET_KEY_PATTERN.test(key)) {
      out[key] = typeof value === 'string' ? redactToken(value) : '<redacted>'
    } else if (typeof value === 'string') {
      out[key] = scrubSecretShapedText(value)
    } else if (value !== null && typeof value === 'object') {
      out[key] = redactResponseBody(value, depth + 1)
    } else {
      out[key] = value
    }
  }
  return out
}

/**
 * Build the grep-friendly stderr audit line for a successful refresh.
 * Mirrors the Teams plugin convention: `<channel> channel: <event> k=v`.
 * Only redacted fingerprints of the tokens appear — never the raw values.
 */
export function refreshSuccessAuditLine(args: {
  upn: string
  expiresInSeconds: number
  refreshTokenRotated: boolean
  oldRefreshToken?: string
  newRefreshToken?: string
}): string {
  return (
    `ms365 channel: ms365_token_refreshed` +
    ` upn=${args.upn}` +
    ` expires_in=${args.expiresInSeconds}` +
    ` refresh_token_rotated=${args.refreshTokenRotated}` +
    ` refresh_token_fp=${redactToken(args.newRefreshToken ?? args.oldRefreshToken)}\n`
  )
}

/**
 * Build the grep-friendly stderr audit line for a failed refresh.
 * `kind` distinguishes transient (token kept, will retry) from permanent
 * (token_expired, re-auth required). The OAuth error + a truncated,
 * newline-collapsed description are included for triage.
 *
 * The description is value-content-scrubbed at this sink (adversarial
 * sweep, defense-in-depth): even if a caller passes a description that
 * smuggled a token-shaped substring (a JWT in error_description, a raw
 * network-error string echoing a URL with a token), it is neutralized
 * here so the audit line can never carry a bearer secret.
 */
export function refreshFailureAuditLine(args: {
  upn: string
  kind: RefreshErrorKind
  oauthError: string
  description: string
  refreshTokenPresent: boolean
}): string {
  const sanitizedDesc = scrubSecretShapedText(
    String(args.description).replace(/[\r\n]+/g, ' '),
  ).slice(0, 300)
  return (
    `ms365 channel: ms365_refresh_failed` +
    ` upn=${args.upn}` +
    ` kind=${args.kind}` +
    ` error=${args.oauthError || 'unknown'}` +
    ` refresh_token_present=${args.refreshTokenPresent}` +
    ` description=${sanitizedDesc}\n`
  )
}

/**
 * Coalesce concurrent operations that share a key into one in-flight
 * promise. The MS365 outage's race was two Graph calls both firing a
 * refresh; with single-flight the second awaits the first's result and
 * both see the same freshly-rotated token. Entra only sees one grant, so
 * the refresh_token is rotated exactly once and never double-consumed.
 *
 * The in-flight entry is cleared in a `finally` so a failed refresh does
 * not wedge the key — the next call starts a fresh attempt (which is what
 * the transient-retry posture wants).
 */
export class SingleFlight<T> {
  private inflight = new Map<string, Promise<T>>()

  run(key: string, fn: () => Promise<T>): Promise<T> {
    const existing = this.inflight.get(key)
    if (existing) return existing
    const p = (async () => {
      try {
        return await fn()
      } finally {
        this.inflight.delete(key)
      }
    })()
    this.inflight.set(key, p)
    return p
  }
}
