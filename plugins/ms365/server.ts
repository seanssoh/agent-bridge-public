#!/usr/bin/env bun
/**
 * Microsoft 365 / Graph API MCP plugin for Claude Code, local dev channel.
 *
 * - Per-UPN delegated token storage via OAuth authorization code flow with a
 *   local HTTPS redirect (the Teams plugin multiplexes /auth/callback through
 *   its existing webhook listener and writes the code to a shared directory).
 * - Auto refresh with refresh_token (issue #1343): every Graph pre-call
 *   refreshes when the access_token is expired or within 5 minutes of
 *   expiry. Refreshes are single-flighted per UPN so concurrent calls do
 *   not double-consume the rotating refresh_token. Transient failures
 *   (network / 5xx / throttle) keep the stored token and retry; a
 *   permanently-dead refresh_token (90-day cap / revoke / consent
 *   withdrawn) persists a `token_expired` status marker and surfaces an
 *   actionable re-auth request instead of an opaque Graph 401. Both paths
 *   emit a redacted `ms365_token_refreshed` / `ms365_refresh_failed`
 *   audit row to stderr (never the raw token).
 * - Tools for Mail, Calendar, People, User, Directory.
 *
 * Env (loaded from $MS365_STATE_DIR/.env if present):
 *   MS365_TENANT_ID       - Entra tenant id (GUID)
 *   MS365_CLIENT_ID       - App registration client id (GUID)
 *   MS365_CLIENT_SECRET   - Confidential client secret (required for web app flow)
 *   MS365_DEFAULT_UPN     - Default user principal when tools are called without upn
 *   MS365_STATE_DIR       - Override state dir (defaults to ~/.claude/channels/ms365)
 *   MS365_DEFAULT_SCOPES  - Space-separated scopes to request during pairing
 *   MS365_REDIRECT_URI    - Redirect URI registered on the app registration.
 *                           Must match the Azure AD app configuration exactly.
 *                           In a hosted deployment it points at the public
 *                           ingress fronting the Teams plugin (which
 *                           multiplexes /auth/callback). REQUIRED — if unset
 *                           OR a localhost variant, the plugin fails loud
 *                           at pair_start time with an actionable error
 *                           naming `agent-bridge setup ms365 <agent>`.
 *                           Issue #1209: the prior silent default of
 *                           `http://localhost:3978/auth/callback` produced
 *                           guaranteed AADSTS50011 failures any time the
 *                           OAuth click happened on a different host than
 *                           the bun listener (every realistic production
 *                           deployment).
 *   MS365_REDIRECT_URI_ALLOW_LOCALHOST - Set to `1` to opt back into a
 *                           localhost MS365_REDIRECT_URI (e.g. for local
 *                           dev where the click + listener are on the same
 *                           host). Default: unset → localhost rejected.
 *   MS365_CALLBACK_SHARED_DIR - Where the Teams plugin drops captured callback
 *                           payloads (default $BRIDGE_HOME/shared/ms365-callbacks)
 *   BRIDGE_HOME           - Agent Bridge install root (default ~/.agent-bridge)
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { randomUUID } from 'crypto'
import {
  hasChatDisclaimerBeenSent,
  markChatDisclaimerSent,
  prependHumanOutboundDisclaimer,
} from './disclosure.ts'
import {
  classifyRefreshError,
  refreshSuccessAuditLine,
  refreshFailureAuditLine,
  SingleFlight,
  type RefreshErrorKind,
} from './token-refresh.ts'

const STATE_DIR = process.env.MS365_STATE_DIR ?? join(homedir(), '.claude', 'channels', 'ms365')
const ENV_FILE = join(STATE_DIR, '.env')
const TOKENS_DIR = join(STATE_DIR, 'tokens')
const PENDING_DIR = join(STATE_DIR, 'pending')
// Issue #1343: per-UPN channel status marker. When the refresh_token is
// permanently dead (90-day cap, revoke, consent withdrawn) we persist a
// `token_expired` status here so `pair_status` and the operator can see
// the channel needs re-auth, distinct from a transient network blip.
const STATUS_DIR = join(STATE_DIR, 'status')
const HUMAN_OUTBOUND_DISCLOSURE_FILE = join(STATE_DIR, 'human-outbound-disclosures.json')

const BRIDGE_HOME = process.env.BRIDGE_HOME ?? join(homedir(), '.agent-bridge')
const MS365_CALLBACK_DIR =
  process.env.MS365_CALLBACK_SHARED_DIR ?? join(BRIDGE_HOME, 'shared', 'ms365-callbacks')

function ensureDirs(): void {
  // Issue #1215: STATE_DIR (the per-agent `.ms365/` parent) is shared
  // between the isolated UID and the controller's `ab-agent-<slug>`
  // group on iso v2 hosts. Pre-#1215 the dir was created with mode
  // `0o700` which produced `drw---S---` after the v2 chown/chgrp pass
  // (no traversal bit for the group), and the controller's `agent start`
  // channel-required validator could not stat `.ms365/.env` to confirm
  // MS365_CLIENT_ID. The brief mandates `0o2770` (setgid + rwx for
  // owner AND group) to match the v2 isolation contract for agent
  // workdirs and the other channel state dirs.
  //
  // Use an explicit `chmodSync` after `mkdirSync` so the helper also
  // self-heals an existing bad-mode dir (`0o700`, `0o660`, etc.) on
  // the next ms365 process startup — `mkdirSync({recursive: true})`
  // is a no-op when the dir already exists, but `chmodSync` always
  // runs and repairs the mode in place.
  //
  // `tokens/` and `pending/` stay `0o700`: tokens are per-UPN secrets
  // the controller has no business reading. The brief explicitly
  // forbids widening secret file modes beyond `0o600`; the directory
  // mode is the public-vs-private boundary.
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o770 })
  try {
    chmodSync(STATE_DIR, 0o2770)
  } catch {}
  mkdirSync(TOKENS_DIR, { recursive: true, mode: 0o700 })
  mkdirSync(PENDING_DIR, { recursive: true, mode: 0o700 })
  // Issue #1343: status markers are not secrets (they hold no token
  // material — only a `token_expired` flag + timestamp + redacted
  // fingerprint), but they live under the per-UPN private tree, so keep
  // the dir at 0o700 alongside tokens/pending for consistency.
  mkdirSync(STATUS_DIR, { recursive: true, mode: 0o700 })
  mkdirSync(MS365_CALLBACK_DIR, { recursive: true, mode: 0o700 })
}

ensureDirs()

// chmod is best-effort; if it fails (e.g. an isolated linux-user UID
// that owns the file via setfacl-grant but not via inode owner) we must
// still proceed to load the env file. Splitting the chmod and the read
// avoids the previous abort-on-chmod-EPERM path that left process.env
// untouched and tripped the missing-credentials exit below.
try {
  chmodSync(ENV_FILE, 0o600)
} catch {}
try {
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^(\w+)=(.*)$/)
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2]
  }
} catch {}

const TENANT_ID = process.env.MS365_TENANT_ID ?? ''
const CLIENT_ID = process.env.MS365_CLIENT_ID ?? ''
const CLIENT_SECRET = process.env.MS365_CLIENT_SECRET ?? ''
const DEFAULT_UPN = process.env.MS365_DEFAULT_UPN ?? ''
const DEFAULT_SCOPES =
  process.env.MS365_DEFAULT_SCOPES ??
  'openid profile offline_access User.Read Mail.Read Mail.Send Calendars.Read Calendars.ReadWrite People.Read User.Read.All Directory.Read.All Chat.ReadWrite'

// Issue #1209: replace the silent localhost default with a fail-loud
// resolver invoked lazily from pair_start. The previous fallback
// produced `http://localhost:3978/auth/callback` any time
// MS365_REDIRECT_URI was unset, which yields a guaranteed AADSTS50011
// failure whenever the user's browser runs on a different host than
// the bun listener (i.e. every realistic production deployment, since
// the Bridge runs on a server and users click links on their laptops).
//
// Priority order:
//   1. Explicit non-localhost MS365_REDIRECT_URI  → returned as-is.
//   2. Explicit localhost MS365_REDIRECT_URI WITH
//      MS365_REDIRECT_URI_ALLOW_LOCALHOST=1       → returned (local dev).
//   3. Anything else (unset, or localhost without
//      the allow flag)                             → throws with a
//      message naming the `agent-bridge setup ms365` wizard so the
//      operator gets an actionable next step at the first pair_start
//      invocation, not at the user's failed Microsoft sign-in.
export function resolveRedirectUri(): string {
  const explicit = (process.env.MS365_REDIRECT_URI ?? '').trim()
  const allowLocalhost = process.env.MS365_REDIRECT_URI_ALLOW_LOCALHOST === '1'
  const isLocalhost = /^https?:\/\/(localhost|127\.0\.0\.1)(:|\/|$)/i.test(explicit)
  if (explicit && (!isLocalhost || allowLocalhost)) {
    return explicit
  }
  throw new Error(
    "MS365_REDIRECT_URI must be set to a publicly reachable URL " +
      "(typically https://<your-bot-host>/auth/callback). " +
      "Run 'agent-bridge setup ms365 <agent>' to persist it, " +
      "and register the same URL on your Entra app's Authentication → Redirect URIs. " +
      "(For local dev only: set MS365_REDIRECT_URI_ALLOW_LOCALHOST=1 to opt back into the localhost default.)",
  )
}

// Issue #1210: normalize the scope string before handing it to
// URLSearchParams. The bug was an input artifact, not a serializer
// flaw — `MS365_DEFAULT_SCOPES` is a STRING, and when an operator's
// .env had `MS365_DEFAULT_SCOPES="openid profile offline_access ..."`
// the literal double-quotes flowed all the way into the authorize_url
// as `scope=%22openid...%22`, tripping AADSTS70011 "scope is not
// valid". URLSearchParams correctly percent-encoded the quotes — they
// just shouldn't have been there.
//
// Contract:
//   - Trim outer whitespace.
//   - Strip ONE matching outer quote pair (`"..."` or `'...'`). Inner
//     quotes are not OAuth scope characters and would already break
//     scope parsing, so the surface bug is the outer wrap.
//   - Split on any whitespace, drop empties, rejoin with single space.
//   - Plain unquoted input round-trips unchanged.
export function normalizeScopes(raw: unknown): string {
  let s = String(raw ?? '').trim()
  if (s.length >= 2) {
    const first = s.charAt(0)
    const last = s.charAt(s.length - 1)
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      s = s.slice(1, -1).trim()
    }
  }
  return s.split(/\s+/).filter(Boolean).join(' ')
}

if (!TENANT_ID || !CLIENT_ID || !CLIENT_SECRET) {
  process.stderr.write(
    `ms365: MS365_TENANT_ID, MS365_CLIENT_ID, and MS365_CLIENT_SECRET are required\n` +
      `  set them in ${ENV_FILE}\n`,
  )
  process.exit(1)
}

type TokenFile = {
  upn: string
  access_token: string
  refresh_token?: string
  expires_at: number
  scope: string
  saved_at: number
}

type PendingFile = {
  upn: string
  state: string
  scopes: string
  created_at: number
  expires_at: number
  authorize_url: string
}

// Issue #1343: persisted per-UPN channel status. `token_expired` is set
// only when the refresh_token is *permanently* dead (re-auth required);
// a transient refresh failure leaves no marker so the next call retries.
type StatusFile = {
  upn: string
  status: 'token_expired'
  reason: string
  needs_reauth: boolean
  updated_at: number
}

// Issue #1343: a refresh failure that carries its transient/permanent
// classification so getAccessToken can decide whether to keep retrying
// with the existing token (transient) or surface a re-auth request
// (permanent). The message NEVER contains the refresh_token itself.
class RefreshError extends Error {
  readonly kind: RefreshErrorKind
  readonly oauthError: string
  constructor(kind: RefreshErrorKind, oauthError: string, message: string) {
    super(message)
    this.name = 'RefreshError'
    this.kind = kind
    this.oauthError = oauthError
  }
}

type CallbackFile = {
  state: string
  code: string
  error?: string
  error_description?: string
  received_at: number
}

function slugUpn(upn: string): string {
  return upn.replace(/[^A-Za-z0-9._-]/g, '_').toLowerCase()
}

function tokenPath(upn: string): string {
  return join(TOKENS_DIR, `${slugUpn(upn)}.json`)
}

function pendingPath(upn: string): string {
  return join(PENDING_DIR, `${slugUpn(upn)}.json`)
}

// Issue #1343 -----------------------------------------------------------
function statusPath(upn: string): string {
  return join(STATUS_DIR, `${slugUpn(upn)}.json`)
}

// Single-flight refresh coordinator: two concurrent Graph calls that both
// cross the expiry threshold share ONE refresh round-trip, so the
// rotating refresh_token is consumed exactly once (no double-grant race).
const refreshInFlight = new SingleFlight<TokenFile>()

function loadStatus(upn: string): StatusFile | null {
  return loadJson<StatusFile>(statusPath(upn))
}

// Persist a `token_expired` marker (re-auth required). Best-effort: a
// failure to write the marker must not mask the underlying refresh error.
function markTokenExpired(upn: string, reason: string): void {
  const status: StatusFile = {
    upn,
    status: 'token_expired',
    reason: String(reason).replace(/[\r\n]+/g, ' ').slice(0, 300),
    needs_reauth: true,
    updated_at: Math.floor(Date.now() / 1000),
  }
  try {
    saveJson(statusPath(upn), status)
  } catch {
    /* best-effort; the audit row + thrown RefreshError still surface */
  }
}

// Clear a stale `token_expired` marker once a refresh (or re-pair)
// succeeds, so a recovered channel does not keep reporting needs_reauth.
function clearTokenExpired(upn: string): void {
  try {
    unlinkSync(statusPath(upn))
  } catch {
    /* no marker present — nothing to clear */
  }
}

function saveJson(path: string, payload: unknown): void {
  const tmp = `${path}.tmp`
  writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 })
  renameSync(tmp, path)
  chmodSync(path, 0o600)
}

function loadJson<T>(path: string): T | null {
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as T
  } catch {
    return null
  }
}

function resolveUpn(arg: unknown): string {
  const s = (arg == null ? DEFAULT_UPN : String(arg)).trim()
  if (!s) {
    throw new Error(
      'upn is required (no default configured; pass upn or set MS365_DEFAULT_UPN in .env)',
    )
  }
  return s
}

async function postForm(
  url: string,
  body: Record<string, string>,
): Promise<any> {
  const form = new URLSearchParams(body)
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
  })
  const text = await res.text()
  try {
    return JSON.parse(text)
  } catch {
    return { _raw: text, _status: res.status }
  }
}

function callbackPath(state: string): string {
  return join(MS365_CALLBACK_DIR, `${state}.json`)
}

function startAuthCode(upn: string, scopes: string, redirectUri: string): PendingFile {
  const state = randomUUID()
  const now = Math.floor(Date.now() / 1000)
  const authorizeParams = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: 'code',
    redirect_uri: redirectUri,
    response_mode: 'query',
    scope: scopes,
    state,
    prompt: 'select_account',
    login_hint: upn,
  })
  const authorizeUrl =
    `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/authorize?` + authorizeParams.toString()
  const pending: PendingFile = {
    upn,
    state,
    scopes,
    created_at: now,
    expires_at: now + 900,
    authorize_url: authorizeUrl,
  }
  saveJson(pendingPath(upn), pending)
  return pending
}

async function exchangeAuthCode(
  upn: string,
): Promise<
  | { status: 'success'; token: TokenFile }
  | { status: 'pending'; hint: string }
  | { status: 'expired' }
  | { status: 'error'; error: string; description: string }
> {
  const pending = loadJson<PendingFile>(pendingPath(upn))
  if (!pending) {
    return { status: 'error', error: 'no_pending', description: `no pending pairing for ${upn}; call pair_start first` }
  }
  const now = Math.floor(Date.now() / 1000)
  if (now >= pending.expires_at) {
    try { unlinkSync(pendingPath(upn)) } catch {}
    try { unlinkSync(callbackPath(pending.state)) } catch {}
    return { status: 'expired' }
  }

  const cb = loadJson<CallbackFile>(callbackPath(pending.state))
  if (!cb) {
    return { status: 'pending', hint: 'waiting for user to complete sign-in via authorize_url' }
  }
  if (cb.error) {
    try { unlinkSync(callbackPath(pending.state)) } catch {}
    try { unlinkSync(pendingPath(upn)) } catch {}
    return { status: 'error', error: cb.error, description: String(cb.error_description ?? '').slice(0, 500) }
  }
  if (!cb.code) {
    return { status: 'error', error: 'empty_code', description: 'callback file had no code' }
  }

  const data = await postForm(
    `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`,
    {
      grant_type: 'authorization_code',
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      code: cb.code,
      // Issue #1209: redirect_uri at the token endpoint MUST match
      // the value used at pair_start. Resolver throws if unset, which
      // is the desired surface here too (the pair_start that wrote
      // the pending file would have already validated this — we
      // re-call as defense in depth in case env changed mid-flight).
      redirect_uri: resolveRedirectUri(),
      scope: pending.scopes,
    },
  )
  if (data.error) {
    return {
      status: 'error',
      error: data.error,
      description: String(data.error_description ?? '').slice(0, 500),
    }
  }
  if (!data.access_token) {
    return {
      status: 'error',
      error: 'malformed_response',
      description: JSON.stringify(data).slice(0, 400),
    }
  }
  const token: TokenFile = {
    upn,
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_at: now + Number(data.expires_in ?? 3600),
    scope: String(data.scope ?? pending.scopes),
    saved_at: now,
  }
  saveJson(tokenPath(upn), token)
  // Issue #1343: a fresh successful pairing clears any prior
  // token_expired marker so the channel stops reporting needs_reauth.
  clearTokenExpired(upn)
  try { unlinkSync(pendingPath(upn)) } catch {}
  try { unlinkSync(callbackPath(pending.state)) } catch {}
  return { status: 'success', token }
}

// Issue #1343: perform the refresh_token grant. Single-flighted by UPN so
// concurrent Graph calls do not both consume the rotating refresh_token
// (edge case #3). On a network/5xx/throttle failure the existing token is
// left untouched and a `transient` RefreshError is thrown (edge case #2:
// keep token, retry on next call). On a permanent failure (90-day cap,
// revoke, consent withdrawn) a `token_expired` status marker is persisted
// and a `permanent` RefreshError is thrown so the agent gets an
// actionable re-auth request instead of an opaque Graph 401. Both paths
// emit a grep-friendly audit row to stderr — never the raw token.
async function refreshToken(upn: string): Promise<TokenFile> {
  return refreshInFlight.run(upn, () => doRefresh(upn))
}

async function doRefresh(upn: string): Promise<TokenFile> {
  const cur = loadJson<TokenFile>(tokenPath(upn))
  if (!cur) throw new Error(`no token for ${upn}; run pair_start + pair_poll`)
  if (!cur.refresh_token) {
    // No refresh_token at all is structurally identical to a dead one:
    // re-auth is the only fix. Mark token_expired so pair_status reports it.
    markTokenExpired(upn, 'no refresh_token stored; re-pair required')
    process.stderr.write(
      refreshFailureAuditLine({
        upn,
        kind: 'permanent',
        oauthError: 'no_refresh_token',
        description: 'token file has no refresh_token',
        refreshTokenPresent: false,
      }),
    )
    throw new RefreshError('permanent', 'no_refresh_token', `no refresh_token for ${upn}; re-pair`)
  }

  let data: any
  try {
    data = await postForm(
      `https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`,
      {
        grant_type: 'refresh_token',
        client_id: CLIENT_ID,
        refresh_token: cur.refresh_token,
        scope: cur.scope || DEFAULT_SCOPES,
        ...(CLIENT_SECRET ? { client_secret: CLIENT_SECRET } : {}),
      },
    )
  } catch (e) {
    // fetch() rejected — DNS/TCP/TLS failure. Always transient: keep the
    // existing token, do NOT mark token_expired, let the next call retry.
    const msg = e instanceof Error ? e.message : String(e)
    process.stderr.write(
      refreshFailureAuditLine({
        upn,
        kind: 'transient',
        oauthError: 'network_error',
        description: msg,
        refreshTokenPresent: true,
      }),
    )
    throw new RefreshError('transient', 'network_error', `refresh network error for ${upn}: ${msg}`)
  }

  if (data && data.error) {
    const kind = classifyRefreshError(data.error, data.error_description)
    process.stderr.write(
      refreshFailureAuditLine({
        upn,
        kind,
        oauthError: String(data.error),
        description: String(data.error_description ?? ''),
        refreshTokenPresent: true,
      }),
    )
    if (kind === 'permanent') {
      markTokenExpired(upn, `${data.error}: ${String(data.error_description ?? '').slice(0, 200)}`)
    }
    // Transient errors leave the stored token untouched (no saveJson) so a
    // subsequent call retries with the same still-valid refresh_token.
    throw new RefreshError(
      kind,
      String(data.error),
      `refresh failed for ${upn}: ${data.error} — ${String(data.error_description ?? '').slice(0, 300)}`,
    )
  }

  // A 5xx with a non-JSON body comes back as { _raw, _status }. Treat any
  // missing access_token as transient (server hiccup), keep the token.
  if (!data || !data.access_token) {
    const status = data?._status
    process.stderr.write(
      refreshFailureAuditLine({
        upn,
        kind: 'transient',
        oauthError: status ? `http_${status}` : 'malformed_response',
        description: JSON.stringify(data ?? {}).slice(0, 200),
        refreshTokenPresent: true,
      }),
    )
    throw new RefreshError(
      'transient',
      status ? `http_${status}` : 'malformed_response',
      `refresh returned no access_token for ${upn} (status=${status ?? 'n/a'})`,
    )
  }

  const now = Math.floor(Date.now() / 1000)
  const newRefreshToken = data.refresh_token ?? cur.refresh_token
  const next: TokenFile = {
    upn,
    access_token: data.access_token,
    refresh_token: newRefreshToken,
    expires_at: now + Number(data.expires_in ?? 3600),
    scope: String(data.scope ?? cur.scope),
    saved_at: now,
  }
  saveJson(tokenPath(upn), next)
  // A successful refresh clears any prior token_expired marker (recovery).
  clearTokenExpired(upn)
  process.stderr.write(
    refreshSuccessAuditLine({
      upn,
      expiresInSeconds: next.expires_at - now,
      refreshTokenRotated: newRefreshToken !== cur.refresh_token,
      oldRefreshToken: cur.refresh_token,
      newRefreshToken,
    }),
  )
  return next
}

async function getAccessToken(upn: string): Promise<string> {
  const cur = loadJson<TokenFile>(tokenPath(upn))
  if (!cur) throw new Error(`no token for ${upn}; run pair_start then pair_poll to authenticate`)
  const now = Math.floor(Date.now() / 1000)
  // Pre-call expiry check: refresh when expired OR within the 5-minute
  // near-expiry margin (preemptive — avoids a mid-call 401).
  if (cur.expires_at - now > 300) return cur.access_token
  try {
    const refreshed = await refreshToken(upn)
    return refreshed.access_token
  } catch (e) {
    if (e instanceof RefreshError && e.kind === 'transient' && cur.expires_at - now > 0) {
      // Edge case #2: refresh hit a transient failure but the current
      // access_token is still (barely) valid — use it rather than hard-
      // failing the call. The next call will retry the refresh.
      return cur.access_token
    }
    if (e instanceof RefreshError && e.kind === 'permanent') {
      // Graceful 90-day-expiry fallback: surface an actionable re-auth
      // request, not a crash or an opaque Graph error (fix point #3).
      throw new Error(
        `MS365 token for ${upn} is expired and cannot be refreshed (${e.oauthError}). ` +
          `Re-authenticate: run pair_start then pair_poll (or 'agent-bridge setup ms365 <agent>'). ` +
          `Channel status: token_expired.`,
      )
    }
    throw e
  }
}

async function graph(
  upn: string,
  method: string,
  path: string,
  body?: unknown,
  query?: Record<string, string | number | undefined>,
  version: 'v1.0' | 'beta' = 'v1.0',
  extraHeaders?: Record<string, string>,
): Promise<any> {
  const token = await getAccessToken(upn)
  let url = `https://graph.microsoft.com/${version}${path}`
  if (query) {
    const qs = new URLSearchParams()
    for (const [k, v] of Object.entries(query)) {
      if (v != null && v !== '') qs.append(k, String(v))
    }
    const s = qs.toString()
    if (s) url += (url.includes('?') ? '&' : '?') + s
  }
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
      ...(extraHeaders ?? {}),
    },
    body: body != null ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  let data: any = null
  try { data = text ? JSON.parse(text) : null } catch { data = { _raw: text } }
  if (!res.ok) {
    const err = data?.error?.message ?? data?._raw ?? `HTTP ${res.status}`
    throw new Error(`graph ${method} ${path} failed (${res.status}): ${String(err).slice(0, 500)}`)
  }
  return data
}

// -------- MCP server -----------------------------------------------------------

const mcp = new Server(
  { name: 'ms365', version: '0.1.0' },
  {
    capabilities: { tools: {} },
    instructions: [
      'Microsoft 365 / Graph API tools for Claude Code.',
      'Before any mail/calendar/people call, ensure the target UPN has a paired token.',
      'Pair flow (authorization code): call pair_start → give the user the authorize_url → user signs in and approves → call pair_poll (status=success|pending|expired|error) until success.',
      'Default UPN may be bound via MS365_DEFAULT_UPN env; otherwise pass upn explicitly to every tool.',
      'Tokens auto-refresh when expired or within 5 minutes of expiry, using the stored refresh_token (single-flighted so concurrent calls share one grant). Transient refresh failures keep the existing token and retry; a permanently-dead refresh_token (90-day cap / revoke) sets pair_status.status=token_expired and asks you to re-run pair_start. Call logout to delete a token.',
    ].join('\n'),
  },
)

type ToolDef = {
  name: string
  description: string
  schema: Record<string, unknown>
  handler: (args: Record<string, unknown>) => Promise<unknown>
}

function textResult(data: unknown) {
  return { content: [{ type: 'text', text: typeof data === 'string' ? data : JSON.stringify(data, null, 2) }] }
}

/**
 * If MS365_MAIL_DISCLAIMER is set in the environment, prepend it to an outgoing
 * mail body. This is opt-in so upstream users who don't need it are unaffected.
 *
 * The env value may contain the literal token `{operator}`, which is replaced at
 * send time with the display name resolved from Azure AD via Graph `/me`
 * (cached per UPN). This avoids hard-coding operator names in config files —
 * the authoritative name always comes from the directory. Falls back to the UPN
 * local-part if the Graph lookup fails for any reason.
 *
 * Idempotent: if the disclaimer is already inside the body (e.g. the caller
 * passed a body that already had it), the body is returned unchanged.
 */
const operatorNameCache = new Map<string, string>()

async function resolveOperatorDisplayName(upn: string): Promise<string> {
  const cached = operatorNameCache.get(upn)
  if (cached) return cached
  try {
    const me = await graph(upn, 'GET', '/me', undefined, { $select: 'displayName' })
    const name = String(me?.displayName ?? '').trim()
    if (name) {
      operatorNameCache.set(upn, name)
      return name
    }
  } catch {
    /* fall through to upn fallback */
  }
  const fallback = upn.split('@')[0] ?? upn
  operatorNameCache.set(upn, fallback)
  return fallback
}

async function resolveDisclaimerTemplate(upn: string, raw: string): Promise<string> {
  const trimmed = raw.trim()
  if (!trimmed.includes('{operator}')) return trimmed
  const name = await resolveOperatorDisplayName(upn)
  return trimmed.replace(/\{operator\}/g, name)
}

async function resolveConfiguredDisclaimer(upn: string, envKeys: string[]): Promise<string> {
  for (const key of envKeys) {
    const raw = process.env[key]
    if (!raw) continue
    const trimmed = raw.trim()
    if (!trimmed) continue
    return resolveDisclaimerTemplate(upn, trimmed)
  }
  return ''
}

const tools: ToolDef[] = [
  {
    name: 'pair_start',
    description:
      'Begin authorization-code pairing for a user principal (UPN). Returns an authorize_url the user must open in a browser. Follow up with pair_poll to exchange the code for tokens.',
    schema: {
      type: 'object',
      properties: {
        upn: { type: 'string', description: 'User principal name (email-like). Defaults to MS365_DEFAULT_UPN.' },
        scopes: { type: 'string', description: 'Space-separated OAuth scopes. Defaults to MS365_DEFAULT_SCOPES.' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      // Issue #1210: normalize the scope string (strip accidental
      // wrapping quotes, collapse whitespace) before passing to
      // URLSearchParams. Without this the literal `"openid ..."` in
      // an operator's .env became `%22openid...%22` in authorize_url
      // and Microsoft Identity Platform rejected with AADSTS70011.
      const scopes = normalizeScopes(args.scopes ?? DEFAULT_SCOPES)
      // Issue #1209: resolve the redirect URI at pair_start time so
      // any misconfiguration surfaces as a clear, actionable error
      // here (with a pointer to `agent-bridge setup ms365`) instead
      // of as AADSTS50011 on the user's failed Microsoft sign-in.
      const redirectUri = resolveRedirectUri()
      const pending = startAuthCode(upn, scopes, redirectUri)
      return textResult({
        upn,
        authorize_url: pending.authorize_url,
        redirect_uri: redirectUri,
        state: pending.state,
        expires_in_seconds: pending.expires_at - Math.floor(Date.now() / 1000),
        instructions: `Open the authorize_url in a browser, sign in as ${upn}, approve the requested permissions. The browser will redirect to ${redirectUri}. Then call pair_poll to finish.`,
      })
    },
  },
  {
    name: 'pair_poll',
    description:
      'Check whether the user has completed the authorization-code redirect, and if so, exchange the code for access + refresh tokens. Returns status=success|pending|expired|error.',
    schema: {
      type: 'object',
      properties: {
        upn: { type: 'string' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const result = await exchangeAuthCode(upn)
      if (result.status === 'success') {
        return textResult({
          status: 'success',
          upn,
          scope: result.token.scope,
          expires_in_seconds: result.token.expires_at - Math.floor(Date.now() / 1000),
          has_refresh_token: Boolean(result.token.refresh_token),
        })
      }
      return textResult(result)
    },
  },
  {
    name: 'pair_status',
    description: 'Report whether a UPN currently has a stored token and when it expires.',
    schema: { type: 'object', properties: { upn: { type: 'string' } } },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const cur = loadJson<TokenFile>(tokenPath(upn))
      // Issue #1343: surface a persisted token_expired marker so the
      // operator (and the agent) can tell "re-auth required" apart from
      // a transient blip without re-deriving it from a failed call.
      const status = loadStatus(upn)
      if (!cur) {
        return textResult({
          upn,
          paired: false,
          ...(status ? { status: status.status, needs_reauth: status.needs_reauth, reason: status.reason } : {}),
        })
      }
      const now = Math.floor(Date.now() / 1000)
      return textResult({
        upn,
        paired: true,
        expires_in_seconds: cur.expires_at - now,
        has_refresh_token: Boolean(cur.refresh_token),
        scope: cur.scope,
        saved_at_iso: new Date(cur.saved_at * 1000).toISOString(),
        ...(status
          ? { status: status.status, needs_reauth: status.needs_reauth, reason: status.reason }
          : { status: 'ok', needs_reauth: false }),
      })
    },
  },
  {
    name: 'logout',
    description: 'Delete the stored token for a UPN. User must re-run pair_start next time.',
    schema: { type: 'object', properties: { upn: { type: 'string' } } },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      // Issue #1343: clear any token_expired marker on logout so a
      // re-pair starts from a clean status.
      clearTokenExpired(upn)
      try {
        unlinkSync(tokenPath(upn))
        return textResult({ upn, removed: true })
      } catch (e) {
        return textResult({ upn, removed: false, reason: String(e) })
      }
    },
  },
  {
    name: 'me',
    description: 'Return the signed-in user profile (GET /me).',
    schema: {
      type: 'object',
      properties: {
        upn: { type: 'string' },
        select: { type: 'string', description: 'OData $select fields, comma-separated.' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const select = String(args.select ?? 'displayName,userPrincipalName,mail,jobTitle,officeLocation,id')
      return textResult(await graph(upn, 'GET', '/me', undefined, { $select: select }))
    },
  },
  {
    name: 'mail_list',
    description:
      'List recent messages from the user\'s mailbox. Default folder is Inbox. Supports $top, $search, $filter.',
    schema: {
      type: 'object',
      properties: {
        upn: { type: 'string' },
        folder: { type: 'string', description: 'Well-known folder name or folder id. Default: inbox.' },
        top: { type: 'number', description: 'Max messages to return (default 10, max 50).' },
        search: { type: 'string', description: 'Graph $search KQL expression.' },
        filter: { type: 'string', description: 'Graph $filter expression.' },
        select: { type: 'string' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const folder = String(args.folder ?? 'inbox')
      const top = Math.max(1, Math.min(Number(args.top ?? 10), 50))
      const select = String(
        args.select ?? 'id,subject,from,toRecipients,receivedDateTime,bodyPreview,isRead,hasAttachments,importance',
      )
      const query: Record<string, string | number | undefined> = {
        $top: top,
        $select: select,
      }
      if (args.search) query.$search = `"${String(args.search).replace(/"/g, '\\"')}"`
      if (args.filter) query.$filter = String(args.filter)
      else if (!args.search) query.$orderby = 'receivedDateTime desc'
      const path = folder === 'inbox'
        ? '/me/mailFolders/inbox/messages'
        : folder === 'sent'
        ? '/me/mailFolders/sentitems/messages'
        : `/me/mailFolders/${encodeURIComponent(folder)}/messages`
      const data = await graph(upn, 'GET', path, undefined, query)
      const rows = (data?.value ?? []).map((m: any) => ({
        id: m.id,
        received: m.receivedDateTime,
        from: m.from?.emailAddress
          ? `${m.from.emailAddress.name ?? ''} <${m.from.emailAddress.address ?? ''}>`.trim()
          : '',
        subject: m.subject,
        preview: m.bodyPreview,
        unread: !m.isRead,
        attachments: !!m.hasAttachments,
        importance: m.importance,
      }))
      return textResult({ count: rows.length, messages: rows })
    },
  },
  {
    name: 'mail_get',
    description: 'Fetch a single message with full body. Pass the id returned from mail_list.',
    schema: {
      type: 'object',
      required: ['message_id'],
      properties: {
        upn: { type: 'string' },
        message_id: { type: 'string' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const id = String(args.message_id ?? '').trim()
      if (!id) throw new Error('message_id is required')
      const data = await graph(upn, 'GET', `/me/messages/${encodeURIComponent(id)}`)
      return textResult({
        id: data.id,
        received: data.receivedDateTime,
        from: data.from?.emailAddress,
        to: (data.toRecipients ?? []).map((r: any) => r.emailAddress),
        cc: (data.ccRecipients ?? []).map((r: any) => r.emailAddress),
        subject: data.subject,
        body_type: data.body?.contentType,
        body: data.body?.content,
        hasAttachments: data.hasAttachments,
      })
    },
  },
  {
    name: 'mail_send',
    description:
      'Send an email as the signed-in user. to is a comma-separated list of email addresses. body is plain text by default, set body_type to \"html\" for HTML. When MS365_MAIL_DISCLAIMER is set, it is automatically prepended to every outgoing message body.',
    schema: {
      type: 'object',
      required: ['to', 'subject', 'body'],
      properties: {
        upn: { type: 'string' },
        to: { type: 'string', description: 'Comma-separated recipient addresses.' },
        cc: { type: 'string' },
        subject: { type: 'string' },
        body: { type: 'string' },
        body_type: { type: 'string', enum: ['text', 'html'], description: 'Default text.' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const to = String(args.to ?? '').split(',').map(s => s.trim()).filter(Boolean)
      if (to.length === 0) throw new Error('to is required (comma-separated)')
      const cc = String(args.cc ?? '').split(',').map(s => s.trim()).filter(Boolean)
      const bodyType = String(args.body_type ?? 'text')
      const disclaimer = await resolveConfiguredDisclaimer(upn, [
        'MS365_MAIL_DISCLAIMER',
        'BRIDGE_HUMAN_OUTBOUND_DISCLAIMER',
      ])
      const message = {
        subject: String(args.subject ?? ''),
        body: {
          contentType: bodyType,
          content: prependHumanOutboundDisclaimer(String(args.body ?? ''), bodyType, disclaimer),
        },
        toRecipients: to.map(a => ({ emailAddress: { address: a } })),
        ccRecipients: cc.map(a => ({ emailAddress: { address: a } })),
      }
      await graph(upn, 'POST', '/me/sendMail', { message, saveToSentItems: true })
      return textResult({ sent: true, to, cc, subject: message.subject })
    },
  },
  {
    name: 'mail_reply',
    description:
      'Reply to the sender of a message, preserving Graph conversation threading. Pass the message_id from mail_list/mail_get. body is plain text by default; set body_type to \"html\" for HTML. The original message is quoted by Graph automatically. When MS365_MAIL_DISCLAIMER is set, it is automatically prepended.',
    schema: {
      type: 'object',
      required: ['message_id', 'body'],
      properties: {
        upn: { type: 'string' },
        message_id: { type: 'string' },
        body: { type: 'string' },
        body_type: { type: 'string', enum: ['text', 'html'], description: 'Default text.' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const id = String(args.message_id ?? '').trim()
      if (!id) throw new Error('message_id is required')
      const bodyType = String(args.body_type ?? 'text')
      const disclaimer = await resolveConfiguredDisclaimer(upn, [
        'MS365_MAIL_DISCLAIMER',
        'BRIDGE_HUMAN_OUTBOUND_DISCLAIMER',
      ])
      const payload = {
        message: {
          body: {
            contentType: bodyType,
            content: prependHumanOutboundDisclaimer(String(args.body ?? ''), bodyType, disclaimer),
          },
        },
      }
      await graph(upn, 'POST', `/me/messages/${encodeURIComponent(id)}/reply`, payload)
      return textResult({ replied: true, message_id: id })
    },
  },
  {
    name: 'mail_reply_all',
    description:
      'Reply-all to a message, preserving Graph conversation threading and the original To/Cc recipient set. Pass the message_id from mail_list/mail_get. body is plain text by default; set body_type to \"html\" for HTML. The original message is quoted by Graph automatically. When MS365_MAIL_DISCLAIMER is set, it is automatically prepended.',
    schema: {
      type: 'object',
      required: ['message_id', 'body'],
      properties: {
        upn: { type: 'string' },
        message_id: { type: 'string' },
        body: { type: 'string' },
        body_type: { type: 'string', enum: ['text', 'html'], description: 'Default text.' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const id = String(args.message_id ?? '').trim()
      if (!id) throw new Error('message_id is required')
      const bodyType = String(args.body_type ?? 'text')
      const disclaimer = await resolveConfiguredDisclaimer(upn, [
        'MS365_MAIL_DISCLAIMER',
        'BRIDGE_HUMAN_OUTBOUND_DISCLAIMER',
      ])
      const payload = {
        message: {
          body: {
            contentType: bodyType,
            content: prependHumanOutboundDisclaimer(String(args.body ?? ''), bodyType, disclaimer),
          },
        },
      }
      await graph(upn, 'POST', `/me/messages/${encodeURIComponent(id)}/replyAll`, payload)
      return textResult({ replied_all: true, message_id: id })
    },
  },
  {
    name: 'calendar_upcoming',
    description: 'List calendar events in the next N days (default 7). Uses /me/calendarview.',
    schema: {
      type: 'object',
      properties: {
        upn: { type: 'string' },
        days: { type: 'number', description: 'Default 7, max 60.' },
        top: { type: 'number', description: 'Default 50, max 200.' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const days = Math.max(1, Math.min(Number(args.days ?? 7), 60))
      const top = Math.max(1, Math.min(Number(args.top ?? 50), 200))
      const start = new Date()
      const end = new Date(start.getTime() + days * 86_400_000)
      const data = await graph(upn, 'GET', '/me/calendarview', undefined, {
        startDateTime: start.toISOString(),
        endDateTime: end.toISOString(),
        $top: top,
        $orderby: 'start/dateTime',
        $select: 'id,subject,organizer,start,end,location,isAllDay,attendees,onlineMeeting,isCancelled',
      })
      const events = (data?.value ?? []).map((e: any) => ({
        id: e.id,
        subject: e.subject,
        start: e.start?.dateTime,
        end: e.end?.dateTime,
        tz: e.start?.timeZone,
        location: e.location?.displayName,
        organizer: e.organizer?.emailAddress?.address,
        attendees: (e.attendees ?? []).map((a: any) => a.emailAddress?.address).filter(Boolean),
        online: !!e.onlineMeeting,
        cancelled: !!e.isCancelled,
      }))
      return textResult({ days, count: events.length, events })
    },
  },
  {
    name: 'calendar_create',
    description: 'Create a calendar event. start and end accept ISO 8601 strings. Attendees comma-separated.',
    schema: {
      type: 'object',
      required: ['subject', 'start', 'end'],
      properties: {
        upn: { type: 'string' },
        subject: { type: 'string' },
        start: { type: 'string', description: 'ISO 8601 (e.g. 2026-04-12T14:00:00)' },
        end: { type: 'string' },
        timezone: { type: 'string', description: 'IANA tz (default Asia/Seoul).' },
        attendees: { type: 'string', description: 'Comma-separated email list.' },
        body: { type: 'string' },
        location: { type: 'string' },
        online: { type: 'boolean', description: 'Create as Teams online meeting.' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const tz = String(args.timezone ?? 'Asia/Seoul')
      const attendees = String(args.attendees ?? '')
        .split(',')
        .map(s => s.trim())
        .filter(Boolean)
      const payload: any = {
        subject: String(args.subject),
        start: { dateTime: String(args.start), timeZone: tz },
        end: { dateTime: String(args.end), timeZone: tz },
        body: { contentType: 'text', content: String(args.body ?? '') },
        attendees: attendees.map(a => ({
          emailAddress: { address: a },
          type: 'required',
        })),
      }
      if (args.location) payload.location = { displayName: String(args.location) }
      if (args.online) {
        payload.isOnlineMeeting = true
        payload.onlineMeetingProvider = 'teamsForBusiness'
      }
      const data = await graph(upn, 'POST', '/me/events', payload)
      return textResult({
        created: true,
        id: data.id,
        webLink: data.webLink,
        joinUrl: data.onlineMeeting?.joinUrl,
      })
    },
  },
  {
    name: 'people_search',
    description: 'Search the signed-in user\'s relevant people (colleagues, frequent contacts).',
    schema: {
      type: 'object',
      required: ['query'],
      properties: {
        upn: { type: 'string' },
        query: { type: 'string' },
        top: { type: 'number' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const q = String(args.query ?? '').trim()
      if (!q) throw new Error('query is required')
      const top = Math.max(1, Math.min(Number(args.top ?? 10), 25))
      const data = await graph(upn, 'GET', '/me/people', undefined, {
        $search: `"${q.replace(/"/g, '\\"')}"`,
        $top: top,
        $select: 'id,displayName,givenName,surname,scoredEmailAddresses,jobTitle,companyName,department',
      })
      const people = (data?.value ?? []).map((p: any) => ({
        name: p.displayName,
        email: p.scoredEmailAddresses?.[0]?.address,
        job: p.jobTitle,
        dept: p.department,
        company: p.companyName,
        id: p.id,
      }))
      return textResult({ query: q, count: people.length, people })
    },
  },
  {
    name: 'users_list',
    description:
      'Enumerate users from the directory via Graph /users. Supports OData $filter / $search / $top / $select for department-, jobTitle-, or displayName-scoped queries. Uses ConsistencyLevel=eventual + $count=true so advanced filters (startsWith, endsWith, contains, $search) work. Requires User.Read.All or Directory.Read.All.',
    schema: {
      type: 'object',
      properties: {
        upn: { type: 'string', description: 'Caller UPN (default MS365_DEFAULT_UPN).' },
        filter: { type: 'string', description: "OData $filter expression, e.g. \"department eq 'Sales 7'\" or \"startsWith(department,'Sales')\"." },
        search: { type: 'string', description: 'OData $search expression (fully quoted), e.g. "\\"department:Sales\\"".' },
        top: { type: 'number', description: 'Default 25, max 200.' },
        select: { type: 'string', description: 'Comma-separated $select field list.' },
        orderby: { type: 'string', description: 'Optional $orderby, e.g. "displayName".' },
      },
    },
    handler: async args => {
      const caller = resolveUpn(args.upn)
      const top = Math.max(1, Math.min(Number(args.top ?? 25), 200))
      const select = String(
        args.select ??
          'id,displayName,userPrincipalName,mail,jobTitle,department,officeLocation,companyName',
      )
      const query: Record<string, string | number | undefined> = {
        $top: top,
        $select: select,
        $count: 'true',
      }
      if (args.filter) query.$filter = String(args.filter)
      if (args.search) query.$search = String(args.search)
      if (args.orderby) query.$orderby = String(args.orderby)
      const data = await graph(
        caller,
        'GET',
        '/users',
        undefined,
        query,
        'v1.0',
        { ConsistencyLevel: 'eventual' },
      )
      const users = (data?.value ?? []).map((u: any) => ({
        id: u.id,
        name: u.displayName,
        upn: u.userPrincipalName,
        mail: u.mail,
        jobTitle: u.jobTitle,
        department: u.department,
        office: u.officeLocation,
        company: u.companyName,
      }))
      return textResult({
        count: users.length,
        total_at_server: data?.['@odata.count'] ?? null,
        next_link: data?.['@odata.nextLink'] ?? null,
        users,
      })
    },
  },
  {
    name: 'user_get',
    description: 'Look up a user in the directory by UPN or email. Requires User.Read.All on the calling principal.',
    schema: {
      type: 'object',
      required: ['lookup'],
      properties: {
        upn: { type: 'string', description: 'Who is making the call (default MS365_DEFAULT_UPN).' },
        lookup: { type: 'string', description: 'UPN/email of the user to look up.' },
        select: { type: 'string' },
      },
    },
    handler: async args => {
      const caller = resolveUpn(args.upn)
      const lookup = String(args.lookup ?? '').trim()
      if (!lookup) throw new Error('lookup is required')
      const select = String(
        args.select ?? 'id,displayName,userPrincipalName,mail,jobTitle,officeLocation,department,companyName',
      )
      const data = await graph(caller, 'GET', `/users/${encodeURIComponent(lookup)}`, undefined, { $select: select })
      return textResult(data)
    },
  },
  {
    name: 'chat_list',
    description:
      'List the signed-in user\'s recent Teams chats (1:1, group, and meeting chats). Requires Chat.ReadBasic or Chat.Read scope. Expands members and lastMessagePreview.',
    schema: {
      type: 'object',
      properties: {
        upn: { type: 'string' },
        top: { type: 'number', description: 'Max chats to return (default 20, max 50).' },
        filter: { type: 'string', description: 'OData $filter, e.g. chatType eq \'oneOnOne\'.' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const top = Math.max(1, Math.min(Number(args.top ?? 20), 50))
      const query: Record<string, string | number | undefined> = {
        $top: top,
        $expand: 'members,lastMessagePreview',
        $orderby: 'lastMessagePreview/createdDateTime desc',
      }
      if (args.filter) query.$filter = String(args.filter)
      const data = await graph(upn, 'GET', '/me/chats', undefined, query)
      const chats = (data?.value ?? []).map((c: any) => {
        const members = (c.members ?? [])
          .map((m: any) => m.displayName ?? m.email ?? m.userId)
          .filter(Boolean)
        const lastMsg = c.lastMessagePreview
        return {
          id: c.id,
          chat_type: c.chatType,
          topic: c.topic ?? null,
          members,
          last_updated: c.lastUpdatedDateTime,
          last_message: lastMsg
            ? {
                created: lastMsg.createdDateTime,
                from:
                  lastMsg.from?.user?.displayName ??
                  lastMsg.from?.application?.displayName ??
                  null,
                preview: stripHtml(String(lastMsg.body?.content ?? '')).slice(0, 240),
                content_type: lastMsg.body?.contentType,
              }
            : null,
          web_url: c.webUrl,
        }
      })
      return textResult({ count: chats.length, chats })
    },
  },
  {
    name: 'chat_messages',
    description:
      'Fetch recent messages from a specific Teams chat. Requires Chat.Read or ChatMessage.Read scope. Pass chat_id returned by chat_list.',
    schema: {
      type: 'object',
      required: ['chat_id'],
      properties: {
        upn: { type: 'string' },
        chat_id: { type: 'string' },
        top: { type: 'number', description: 'Max messages to return (default 20, max 50).' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const chatId = String(args.chat_id ?? '').trim()
      if (!chatId) throw new Error('chat_id is required')
      const top = Math.max(1, Math.min(Number(args.top ?? 20), 50))
      const data = await graph(
        upn,
        'GET',
        `/chats/${encodeURIComponent(chatId)}/messages`,
        undefined,
        { $top: top },
      )
      const messages = (data?.value ?? []).map((m: any) => ({
        id: m.id,
        created: m.createdDateTime,
        from:
          m.from?.user?.displayName ??
          m.from?.application?.displayName ??
          null,
        from_id: m.from?.user?.id ?? null,
        content_type: m.body?.contentType,
        content: stripHtml(String(m.body?.content ?? '')),
        importance: m.importance,
        message_type: m.messageType,
        deleted: !!m.deletedDateTime,
      }))
      return textResult({ chat_id: chatId, count: messages.length, messages })
    },
  },
  {
    name: 'chat_send',
    description:
      'Send a message to a specific Teams chat as the signed-in user. Requires ChatMessage.Send or Chat.ReadWrite scope. When MS365_CHAT_DISCLAIMER or BRIDGE_HUMAN_OUTBOUND_DISCLAIMER is set, the disclaimer is prepended only to the first outbound message per chat_id for that human profile.',
    schema: {
      type: 'object',
      required: ['chat_id', 'body'],
      properties: {
        upn: { type: 'string' },
        chat_id: { type: 'string' },
        body: { type: 'string' },
        content_type: { type: 'string', enum: ['text', 'html'], description: 'Default text.' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const chatId = String(args.chat_id ?? '').trim()
      if (!chatId) throw new Error('chat_id is required')
      const body = String(args.body ?? '')
      if (!body) throw new Error('body is required')
      const contentType = String(args.content_type ?? 'text')
      const disclaimer = await resolveConfiguredDisclaimer(upn, [
        'MS365_CHAT_DISCLAIMER',
        'BRIDGE_HUMAN_OUTBOUND_DISCLAIMER',
      ])
      const shouldMarkDisclosure =
        Boolean(disclaimer) &&
        !hasChatDisclaimerBeenSent(HUMAN_OUTBOUND_DISCLOSURE_FILE, upn, chatId)
      const outboundBody = shouldMarkDisclosure
        ? prependHumanOutboundDisclaimer(body, contentType, disclaimer)
        : body
      const data = await graph(
        upn,
        'POST',
        `/chats/${encodeURIComponent(chatId)}/messages`,
        { body: { contentType, content: outboundBody } },
      )
      if (shouldMarkDisclosure) {
        markChatDisclaimerSent(HUMAN_OUTBOUND_DISCLOSURE_FILE, upn, chatId, String(data.id ?? ''))
      }
      return textResult({
        sent: true,
        chat_id: chatId,
        message_id: data.id,
        created: data.createdDateTime,
      })
    },
  },
  {
    name: 'joined_teams',
    description: 'List the Teams the signed-in user is a member of. Requires Team.ReadBasic.All or User.Read scope depending on tenant.',
    schema: {
      type: 'object',
      properties: {
        upn: { type: 'string' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const data = await graph(upn, 'GET', '/me/joinedTeams')
      const teams = (data?.value ?? []).map((t: any) => ({
        id: t.id,
        name: t.displayName,
        description: t.description,
        visibility: t.visibility,
      }))
      return textResult({ count: teams.length, teams })
    },
  },
  {
    name: 'chat_delete',
    description:
      'Soft-delete a previously sent chat message. Only the original author can delete their own message. Requires Chat.ReadWrite scope. The message is hidden for all participants but can be restored via chat_undo_delete.',
    schema: {
      type: 'object',
      required: ['chat_id', 'message_id'],
      properties: {
        upn: { type: 'string' },
        chat_id: { type: 'string' },
        message_id: { type: 'string' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const chatId = String(args.chat_id ?? '').trim()
      const msgId = String(args.message_id ?? '').trim()
      if (!chatId) throw new Error('chat_id is required')
      if (!msgId) throw new Error('message_id is required')
      await graph(
        upn,
        'POST',
        `/me/chats/${encodeURIComponent(chatId)}/messages/${encodeURIComponent(msgId)}/softDelete`,
      )
      return textResult({ deleted: true, chat_id: chatId, message_id: msgId })
    },
  },
  {
    name: 'chat_undo_delete',
    description:
      'Restore a previously soft-deleted chat message. Mirror of chat_delete using the Graph /undoSoftDelete action.',
    schema: {
      type: 'object',
      required: ['chat_id', 'message_id'],
      properties: {
        upn: { type: 'string' },
        chat_id: { type: 'string' },
        message_id: { type: 'string' },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const chatId = String(args.chat_id ?? '').trim()
      const msgId = String(args.message_id ?? '').trim()
      if (!chatId) throw new Error('chat_id is required')
      if (!msgId) throw new Error('message_id is required')
      await graph(
        upn,
        'POST',
        `/me/chats/${encodeURIComponent(chatId)}/messages/${encodeURIComponent(msgId)}/undoSoftDelete`,
      )
      return textResult({ restored: true, chat_id: chatId, message_id: msgId })
    },
  },
  {
    name: 'chat_create',
    description:
      'Create (or retrieve, if it already exists) a 1:1 or group Teams chat including the signed-in user and the listed target UPNs. Requires Chat.Create or Chat.ReadWrite scope. Returns the chat_id that can then be used with chat_send / chat_messages.',
    schema: {
      type: 'object',
      required: ['targets'],
      properties: {
        upn: { type: 'string', description: 'Caller UPN (default MS365_DEFAULT_UPN). Will be added as owner.' },
        targets: {
          type: 'string',
          description: 'Comma-separated list of target user UPNs/emails to include. For a 1:1 pass exactly one.',
        },
        topic: { type: 'string', description: 'Optional topic. Required for group chats (>=3 members total), ignored for 1:1.' },
      },
    },
    handler: async args => {
      const caller = resolveUpn(args.upn)
      const targets = String(args.targets ?? '')
        .split(',')
        .map(s => s.trim())
        .filter(Boolean)
      if (targets.length === 0) throw new Error('targets is required (comma-separated UPNs)')
      const allMembers = [caller, ...targets]
      const isOneOnOne = allMembers.length === 2
      const payload: any = {
        chatType: isOneOnOne ? 'oneOnOne' : 'group',
        members: allMembers.map(u => ({
          '@odata.type': '#microsoft.graph.aadUserConversationMember',
          roles: ['owner'],
          'user@odata.bind': `https://graph.microsoft.com/v1.0/users('${u}')`,
        })),
      }
      if (!isOneOnOne) {
        if (!args.topic) throw new Error('topic is required for group chats (3+ members)')
        payload.topic = String(args.topic)
      }
      const data = await graph(caller, 'POST', '/chats', payload)
      return textResult({
        id: data.id,
        chat_type: data.chatType,
        topic: data.topic ?? null,
        web_url: data.webUrl,
        created: data.createdDateTime,
      })
    },
  },
]

function stripHtml(s: string): string {
  return s.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/\s+/g, ' ').trim()
}

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: tools.map(t => ({ name: t.name, description: t.description, inputSchema: t.schema })),
}))

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const tool = tools.find(t => t.name === req.params.name)
  if (!tool) throw new Error(`unknown tool: ${req.params.name}`)
  const args = (req.params.arguments ?? {}) as Record<string, unknown>
  try {
    return (await tool.handler(args)) as any
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    return { content: [{ type: 'text', text: `error: ${msg}` }], isError: true }
  }
})

process.on('unhandledRejection', err => {
  process.stderr.write(`ms365 channel: unhandled rejection: ${err}\n`)
})
process.on('uncaughtException', err => {
  process.stderr.write(`ms365 channel: uncaught exception: ${err}\n`)
})

await mcp.connect(new StdioServerTransport())
process.stderr.write(`ms365: MCP connected (tenant=${TENANT_ID.slice(0, 8)}..., client=${CLIENT_ID.slice(0, 8)}..., secret_len=${CLIENT_SECRET.length}, default_upn=${DEFAULT_UPN}, state_dir=${STATE_DIR})\n`)
