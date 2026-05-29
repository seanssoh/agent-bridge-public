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
 * newline-collapsed description are included for triage — neither field
 * ever carries the token itself.
 */
export function refreshFailureAuditLine(args: {
  upn: string
  kind: RefreshErrorKind
  oauthError: string
  description: string
  refreshTokenPresent: boolean
}): string {
  const sanitizedDesc = String(args.description).replace(/[\r\n]+/g, ' ').slice(0, 300)
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
