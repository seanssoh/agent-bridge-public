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
  closeSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
  writeSync,
} from 'fs'
import { homedir, hostname } from 'os'
import { basename, resolve, sep, join } from 'path'
import { randomUUID } from 'crypto'
import {
  hasChatDisclaimerBeenSent,
  markChatDisclaimerSent,
  prependHumanOutboundDisclaimer,
} from './disclosure.ts'
import {
  classifyRefreshError,
  redactResponseBody,
  scrubSecretShapedText,
  refreshSuccessAuditLine,
  refreshFailureAuditLine,
  SingleFlight,
  type RefreshErrorKind,
} from './token-refresh.ts'

const STATE_DIR = process.env.MS365_STATE_DIR ?? join(homedir(), '.claude', 'channels', 'ms365')
const ENV_FILE = join(STATE_DIR, '.env')
const TOKENS_DIR = join(STATE_DIR, 'tokens')
const PENDING_DIR = join(STATE_DIR, 'pending')
const ATTACHMENTS_DIR = process.env.MS365_ATTACHMENTS_DIR ?? join(STATE_DIR, 'attachments')
// Issue #1343: per-UPN channel status marker. When the refresh_token is
// permanently dead (90-day cap, revoke, consent withdrawn) we persist a
// `token_expired` status here so `pair_status` and the operator can see
// the channel needs re-auth, distinct from a transient network blip.
const STATUS_DIR = join(STATE_DIR, 'status')
const HUMAN_OUTBOUND_DISCLOSURE_FILE = join(STATE_DIR, 'human-outbound-disclosures.json')
const DEFAULT_ATTACHMENT_MAX_BYTES = 25 * 1024 * 1024
const ATTACHMENT_MAX_BYTES = clampPositiveInt(
  process.env.MS365_ATTACHMENT_MAX_BYTES,
  DEFAULT_ATTACHMENT_MAX_BYTES,
)

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
  mkdirSync(ATTACHMENTS_DIR, { recursive: true, mode: 0o700 })
  try {
    chmodSync(ATTACHMENTS_DIR, 0o700)
  } catch {}
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
// Multi-agent OAuth callback demux: when several isolated agents share one
// public bot endpoint behind a router (one Azure app, N per-agent listeners),
// the OAuth `/auth/callback` carries no agent identity — only ?code&state.
// We embed the originating agent id as a `<agent>.<uuid>` prefix in the OAuth
// `state` (Microsoft echoes `state` back verbatim) so the router can route the
// callback to the agent that started the pairing. Sanitized to the callback
// state charset so a malformed BRIDGE_AGENT_ID degrades to a plain-uuid state
// (single-listener behavior, no demux). See teams plugin `/auth/callback`.
const AGENT_TAG = /^[A-Za-z0-9_-]{1,64}$/.test((process.env.BRIDGE_AGENT_ID ?? '').trim())
  ? (process.env.BRIDGE_AGENT_ID ?? '').trim()
  : ''
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

// Issue #1650: guarantee `offline_access` is in the scope sent on a
// refresh_token grant. `offline_access` is the scope that AUTHORIZES
// refresh_token issuance + rotation; a refresh grant that omits it makes
// Entra stop returning/rotating a refresh_token (and, under some tenant
// conditional-access configs, reject the grant). The drift is silent and
// cumulative: Microsoft's token-endpoint response `scope` echoes only the
// RESOURCE-granted scopes (`User.Read Mail.Read …`) — it drops the OIDC
// scopes `offline_access openid profile`. The plugin persisted that
// narrowed response scope (`data.scope`) into the token file and then sent
// it verbatim on the NEXT refresh, so the second refresh onward dropped
// `offline_access`. Over time the refresh_token is never renewed and the
// access_token "sits expired" with the next Graph call surfacing
// `Authentication required` — exactly the #1650 symptom (the on-call
// refresh path itself is correct; it was being fed a scope that defeats it).
//
// Re-adding `offline_access` is idempotent and order-preserving (it is
// appended only when absent), and harmless when already present. We do NOT
// re-add `openid`/`profile`: only `offline_access` governs refresh-token
// continuity, and an interactive app may legitimately have paired without
// the OIDC scopes (`MS365_DEFAULT_SCOPES` override). Keeping the surface
// minimal avoids re-requesting consent for scopes the user did not grant.
export function withOfflineAccess(scope: unknown): string {
  const s = String(scope ?? '').trim()
  const parts = s.split(/\s+/).filter(Boolean)
  if (!parts.some(p => p.toLowerCase() === 'offline_access')) {
    parts.push('offline_access')
  }
  return parts.join(' ')
}

function clampPositiveInt(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback
  const n = Number(raw)
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : fallback
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
  // Defense in depth (#1825): collapse any `..` run AFTER the charset
  // filter so a claim of `..` / `a..b` can never form a path component.
  // The charset filter already strips `/` and `\`, so the slug is confined
  // to TOKENS_DIR; this extra pass neutralizes dot-traversal shapes too.
  return upn
    .replace(/[^A-Za-z0-9._-]/g, '_')
    .replace(/\.{2,}/g, '_')
    .toLowerCase()
}

// Issue #1825 -----------------------------------------------------------
// Behind a single shared bot app, pair_start only has the opaque Teams
// `aadObjectId` (the real UPN is unknown until after sign-in). The durable
// token key/filename + the token's `upn` field must end up as the REAL,
// AUTHENTICATED UPN (downstream the approvals plugin reads identity from
// the token filename / `upn` field). So at pair_poll success we derive the
// identity from the *verified token claim* — never from the unvalidated
// `pair_start` input — and key the token by that claim.
//
// The id_token returned by the authorization_code grant is minted by Azure
// AD for our own client; its `preferred_username` (v2) / `upn` claim is the
// authenticated principal. We decode the JWT payload locally for the key;
// the token itself is never re-verified here (the secure channel to the
// /token endpoint + our client_secret is the trust anchor — same as the
// access_token we just received). A Graph `/me` fallback covers the rare
// case where no id_token came back (e.g. an operator scope set without
// `openid`).
function decodeJwtPayload(jwt: string): Record<string, unknown> | null {
  const parts = String(jwt).split('.')
  if (parts.length < 2) return null
  try {
    const json = Buffer.from(parts[1], 'base64url').toString('utf8')
    const obj = JSON.parse(json)
    return obj && typeof obj === 'object' ? (obj as Record<string, unknown>) : null
  } catch {
    return null
  }
}

// A UPN claim is only accepted as a durable key when it is UPN-shaped
// (`local@domain`, no whitespace, no path separators or traversal dots).
// Anything else is rejected so a malformed/forged claim cannot determine
// the key — pairing then falls back to the opaque pair_start input.
function normalizeClaimedUpn(raw: unknown): string | null {
  if (typeof raw !== 'string') return null
  const s = raw.trim()
  if (!s) return null
  // UPN shape: exactly one `@`, non-empty local + domain, no whitespace,
  // no `/` `\` and no `..` traversal run.
  if (!/^[^\s@/\\]+@[^\s@/\\]+$/.test(s)) return null
  if (s.includes('..')) return null
  return s
}

// Extract the authenticated UPN from an id_token claim. Prefers the v2
// `preferred_username`, falls back to the v1 `upn` claim. Returns the
// UPN-validated string or null.
function claimUpnFromIdToken(idToken: unknown): string | null {
  if (typeof idToken !== 'string' || !idToken) return null
  const payload = decodeJwtPayload(idToken)
  if (!payload) return null
  return (
    normalizeClaimedUpn(payload.preferred_username) ??
    normalizeClaimedUpn(payload.upn)
  )
}

// Graph `/me` fallback for the authenticated UPN, used only when the
// token-endpoint response carried no id_token to decode. Calls Graph with
// the freshly-minted access_token directly (the token is not yet keyed in
// the store, so we cannot route through getAccessToken/graph()). Returns a
// UPN-validated string or null; any failure degrades to the opaque key.
async function claimUpnFromGraph(accessToken: string): Promise<string | null> {
  try {
    const res = await fetch(
      'https://graph.microsoft.com/v1.0/me?$select=userPrincipalName',
      { headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' } },
    )
    if (!res.ok) return null
    const data: any = await res.json().catch(() => null)
    return normalizeClaimedUpn(data?.userPrincipalName)
  } catch {
    return null
  }
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

// Issue #2048: coalesce the ENTIRE locked-refresh path (cross-process lock +
// re-read + grant) per UPN within this process, so two concurrent in-process
// getAccessToken callers do NOT each independently take the cross-process
// lock — only the flight leader does; the follower awaits its result. Distinct
// from refreshInFlight (which coalesces just the doRefresh POST) so the leader
// can still call refreshToken() inside without self-deadlocking this flight.
const lockedRefreshInFlight = new SingleFlight<TokenFile>()

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

// Issue #2048 — cross-process refresh lock --------------------------------
//
// The in-process `SingleFlight` (token-refresh.ts) coalesces concurrent
// refreshes WITHIN one Node process. But the SAME per-UPN token file is
// rotated by SEPARATE processes — the MCP server, the `get-valid-token`
// CLI one-shot, and any other concurrent caller. AAD `refresh_token` is
// single-use rotating: process A reads RT1 and POSTs → Entra rotates to
// RT2 and invalidates RT1; process B (which read RT1 concurrently) POSTs
// the now-spent RT1 → `invalid_grant` / `AADSTS70000` (permanent) → the
// loser marks the token expired → the operator must re-authorize (~every
// 3h under concurrent Graph+bearer load).
//
// A cross-process lock keyed on the token file serializes the grant across
// processes. Combined with a RE-READ after acquiring (see getAccessToken),
// exactly one process performs the grant and the rest observe the freshly
// rotated token and skip the redundant POST.
//
// Primitive: a dependency-free `O_EXCL` lockfile (sibling to the token
// file). `openSync(lockPath, 'wx')` is atomic create-or-fail across
// processes on POSIX. The ms365 plugin is TypeScript/bun and must run on
// macOS (no `flock(1)`); a Node/bun `fs` O_EXCL lockfile is portable and
// needs no extra dependency (no `proper-lockfile` in package.json).
//
// Lock hygiene:
//   - Bounded acquisition timeout — a Graph pre-call must NEVER hang
//     forever on a held lock. On timeout the lock is treated as
//     unavailable and the caller proceeds WITHOUT the cross-process guard
//     (the in-process SingleFlight + the post-grant re-read still bound
//     the damage), rather than deadlocking the Graph call.
//   - Stale-lock reclaim — a crashed holder must not deadlock the file
//     permanently. A held lock is reclaimed when the recorded PID is dead
//     on THIS host (process.kill(pid, 0) → ESRCH) OR the lockfile mtime is
//     older than a TTL (covers a holder on a different host / an
//     unreadable lockfile).
//   - No token material in the lockfile — it records only { pid, host,
//     acquired_at }. The token file itself stays the only secret surface.
// A finite, non-negative config value or the fallback. An operator that sets
// MS365_REFRESH_LOCK_TIMEOUT_MS to a non-numeric string would otherwise yield
// NaN, and `Date.now() >= NaN` is always false → an unbounded acquisition spin.
// Clamp to a finite >= 0 number so the deadline arithmetic always terminates.
function clampLockMs(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback
  const n = Number(raw)
  return Number.isFinite(n) && n >= 0 ? n : fallback
}
const REFRESH_LOCK_TTL_MS = clampLockMs(process.env.MS365_REFRESH_LOCK_TTL_MS, 30_000)
const REFRESH_LOCK_TIMEOUT_MS = clampLockMs(process.env.MS365_REFRESH_LOCK_TIMEOUT_MS, 8_000)
const REFRESH_LOCK_POLL_MS = 50
const SELF_HOST = hostname()

function lockPathFor(upn: string): string {
  return `${tokenPath(upn)}.lock`
}

// Is the recorded lockfile a stale lock we may reclaim? True when the
// holder PID is provably dead on THIS host, or the lockfile is older than
// the TTL (different-host holder / unreadable / clock skew safety net).
function isStaleLock(lockPath: string): boolean {
  let raw: string
  try {
    raw = readFileSync(lockPath, 'utf8')
  } catch {
    // Vanished between the EEXIST and the read — not stale, just gone; the
    // next O_EXCL attempt will (re)acquire it.
    return false
  }
  let meta: { pid?: number; host?: string; acquired_at?: number } = {}
  try {
    meta = JSON.parse(raw)
  } catch {
    meta = {}
  }
  // Same-host dead-PID reclaim: kill(pid, 0) throws ESRCH when no such
  // process exists. EPERM means the process IS alive (owned by another
  // uid) — NOT stale. A malformed/missing pid falls through to the TTL.
  if (meta.host === SELF_HOST && typeof meta.pid === 'number' && meta.pid > 0) {
    try {
      process.kill(meta.pid, 0)
      return false // holder alive
    } catch (e: any) {
      if (e && e.code === 'ESRCH') return true // holder dead → reclaim
      if (e && e.code === 'EPERM') return false // alive (other uid)
      // any other error → fall through to the mtime TTL
    }
  }
  // mtime TTL: covers a holder on another host, an unparseable lockfile, or
  // a same-host pid we could not classify. A lock older than the TTL is
  // assumed abandoned.
  try {
    const ageMs = Date.now() - statSync(lockPath).mtimeMs
    return ageMs > REFRESH_LOCK_TTL_MS
  } catch {
    return false
  }
}

// Serialize the reclaim of a stale lock so two waiters cannot BOTH decide the
// lock is stale and then race rename/unlink — the second delete would land on a
// THIRD process's freshly-created live lock (the TOCTOU codex r2 flagged). A
// dedicated O_EXCL reclaim guard (`<lockPath>.reclaim`) admits exactly one
// reclaimer; INSIDE the guard we RE-VERIFY staleness against the current lock
// (it may have been replaced by a live lock since the outer check) and only
// unlink if it is STILL stale. The guard is held for a single read+unlink, so a
// crashed reclaimer is bounded by an mtime TTL on the guard itself (re-using the
// same stale-reclaim logic, recursion-free) plus a hard one-shot fallback.
function reclaimStaleLock(lockPath: string): void {
  const guard = `${lockPath}.reclaim`
  let guardFd: number
  try {
    guardFd = openSync(guard, 'wx', 0o600)
  } catch (e: any) {
    if (e && e.code === 'EEXIST') {
      // Another reclaimer holds the guard, OR a previous one crashed. If the
      // guard is older than the TTL it is abandoned — best-effort clear it so a
      // crashed reclaimer cannot wedge reclaim forever; then return and let the
      // caller loop (it will retry the O_EXCL acquire or re-enter reclaim).
      try {
        if (Date.now() - statSync(guard).mtimeMs > REFRESH_LOCK_TTL_MS) {
          unlinkSync(guard)
        }
      } catch {
        /* guard vanished or unreadable — the next loop iteration retries */
      }
    }
    // Any other error (perm/ENOENT on the dir): skip reclaim this round; the
    // outer loop's bounded timeout still prevents a hang.
    return
  }
  try {
    // RE-VERIFY under the guard: the lock may have been reclaimed + re-created
    // as a LIVE lock by another waiter between the outer isStaleLock() and now.
    // Only remove it if it is STILL stale.
    if (isStaleLock(lockPath)) {
      try {
        unlinkSync(lockPath)
      } catch {
        /* already gone — another guarded reclaimer won; nothing to do */
      }
    }
  } finally {
    closeSync(guardFd)
    try {
      unlinkSync(guard)
    } catch {
      /* guard already cleared (TTL sweep) — harmless */
    }
  }
}

// Acquire the per-UPN cross-process refresh lock. Returns a release handle
// on success, or null on timeout (the caller proceeds WITHOUT the lock —
// see getAccessToken's degraded path; it never hangs the Graph call). The
// O_EXCL create is the cross-process atomic primitive; on contention we
// poll with a bounded total budget, reclaiming a provably-stale lock.
function acquireRefreshLock(upn: string): (() => void) | null {
  const lockPath = lockPathFor(upn)
  const deadline = Date.now() + Math.max(0, REFRESH_LOCK_TIMEOUT_MS)
  // Best-effort body — NEVER any token material, only liveness metadata.
  const body = JSON.stringify({
    pid: process.pid,
    host: SELF_HOST,
    acquired_at: Date.now(),
  })
  for (;;) {
    try {
      // O_CREAT | O_EXCL | O_WRONLY — atomic "create iff absent".
      const fd = openSync(lockPath, 'wx', 0o600)
      try {
        writeSync(fd, body)
      } catch {
        /* metadata is best-effort; the lock is held by the file's existence */
      } finally {
        closeSync(fd)
      }
      let released = false
      return () => {
        if (released) return
        released = true
        try {
          unlinkSync(lockPath)
        } catch {
          /* already gone (reclaimed by a stale-sweep) — nothing to do */
        }
      }
    } catch (e: any) {
      if (!e || e.code !== 'EEXIST') {
        // A non-contention error (e.g. ENOENT on a missing tokens/ dir, or
        // a permission error). Don't hang the Graph call on it — proceed
        // unlocked; the post-grant re-read still bounds the double-consume.
        return null
      }
      // Held. Reclaim if stale (serialized + re-verified under a reclaim guard
      // so two waiters cannot both remove the lock and clobber a third
      // process's freshly-created live lock), else wait within the bounded
      // budget. After a reclaim attempt we loop back to retry the O_EXCL create.
      if (isStaleLock(lockPath)) {
        reclaimStaleLock(lockPath)
        if (Date.now() >= deadline) return null // bounded even across reclaims
        continue
      }
      if (Date.now() >= deadline) return null // bounded timeout — never hang
      Atomics.wait(
        new Int32Array(new SharedArrayBuffer(4)),
        0,
        0,
        Math.min(REFRESH_LOCK_POLL_MS, Math.max(0, deadline - Date.now())),
      )
    }
  }
}

// Issue #2035 (item 1): defensively normalize a legacy millisecond `expires_at`
// to seconds on read. This plugin writes + compares `expires_at` in SECONDS
// (write = now + expires_in; read = expires_at - now, refresh when near 0), but
// a legacy ms-format token file (13-digit ms `expires_at`, from an older plugin
// version or an external pairing) would read as a permanently huge-positive
// remaining → the seconds-land freshness check thinks it is valid forever and
// NEVER refreshes. `1e12` seconds is the year 33658 vs ~1.7e9 now, so any
// `expires_at` above it is unambiguously milliseconds. Mutates `cur` in place
// (the freshness check and the reported expiry then both see seconds) and
// returns it for call-site chaining; a null token is passed through untouched.
function normalizeTokenExpiry(cur: TokenFile | null): TokenFile | null {
  if (cur && cur.expires_at > 1e12) cur.expires_at = Math.floor(cur.expires_at / 1000)
  return cur
}

// Issue #1825: when no explicit upn is passed AND MS365_DEFAULT_UPN is not
// configured, resolve the default to the single stored token's keyed UPN.
// After a shared-bot pairing the token is keyed by the authenticated real
// UPN; this lets default-UPN tool calls pick it up WITHOUT a listener
// restart (DEFAULT_UPN is read from process.env once at startup). Only the
// unambiguous single-token case is auto-resolved — an explicit
// MS365_DEFAULT_UPN always wins, and zero/multiple tokens fall through to
// the original "upn is required" error (no silent wrong-user binding).
function singleStoredUpn(): string | null {
  let files: string[]
  try {
    files = readdirSync(TOKENS_DIR).filter(f => f.endsWith('.json') && !f.endsWith('.tmp'))
  } catch {
    return null
  }
  if (files.length !== 1) return null
  const tok = loadJson<TokenFile>(join(TOKENS_DIR, files[0]))
  const upn = tok?.upn?.trim()
  return upn ? upn : null
}

function resolveUpn(arg: unknown): string {
  const s = (arg == null ? DEFAULT_UPN : String(arg)).trim()
  if (s) return s
  const sole = singleStoredUpn()
  if (sole) return sole
  throw new Error(
    'upn is required (no default configured; pass upn or set MS365_DEFAULT_UPN in .env)',
  )
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
  // `<agent>.<uuid>` when running under the bridge multi-agent router, else a
  // plain uuid. The `.` separator is absent from bridge agent ids and uuids, so
  // the router can recover the agent with `state.split('.')[0]`.
  const state = AGENT_TAG ? `${AGENT_TAG}.${randomUUID()}` : randomUUID()
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
    // r4: scrub the error code too (the callback file's `error` is
    // attacker-influenceable — it comes off the OAuth redirect query).
    return { status: 'error', error: scrubSecretShapedText(String(cb.error)).slice(0, 120), description: scrubSecretShapedText(String(cb.error_description ?? '')).slice(0, 500) }
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
    // pair_poll surfaces this via textResult (agent-visible). Scrub any
    // token-shaped substring smuggled into error OR error_description
    // (r4: top-level error code scrubbed for model consistency).
    return {
      status: 'error',
      error: scrubSecretShapedText(String(data.error)).slice(0, 120),
      description: scrubSecretShapedText(String(data.error_description ?? '')).slice(0, 500),
    }
  }
  if (!data.access_token) {
    // codex adversarial-sweep BLOCKING #2: this description flows up to
    // pair_poll's textResult (agent-visible stdout) — even more exposed
    // than an audit row. A token endpoint that returns a no-access_token
    // body still carrying refresh_token / id_token must NOT leak it.
    // redactResponseBody is _raw-aware + value-content-scrubbed.
    return {
      status: 'error',
      error: 'malformed_response',
      description: JSON.stringify(redactResponseBody(data)).slice(0, 400),
    }
  }
  // Issue #1825: key the durable token by the AUTHENTICATED claim, not the
  // opaque `pair_start` input. Derive the real UPN from the verified
  // id_token claim (preferred_username / upn); fall back to Graph /me with
  // the fresh access_token; degrade to the opaque input only if both fail
  // (never block pairing). This eliminates the post-pair re-key/mv/restart
  // dance — a single pairing with an opaque key yields a correctly-keyed
  // token whose filename + `upn` field are the real UPN.
  const authUpn =
    claimUpnFromIdToken(data.id_token) ??
    (await claimUpnFromGraph(data.access_token)) ??
    upn
  const token: TokenFile = {
    upn: authUpn,
    access_token: data.access_token,
    refresh_token: data.refresh_token,
    expires_at: now + Number(data.expires_in ?? 3600),
    scope: String(data.scope ?? pending.scopes),
    saved_at: now,
  }
  saveJson(tokenPath(authUpn), token)
  // Issue #1343: a fresh successful pairing clears any prior token_expired
  // marker so the channel stops reporting needs_reauth. Clear it under BOTH
  // the authenticated key and the opaque pair_start key (a re-key onboarding
  // may have left a stale opaque-keyed marker).
  clearTokenExpired(authUpn)
  if (authUpn !== upn) clearTokenExpired(upn)
  // The pending/callback handles are keyed by the opaque pair_start input.
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
        // Issue #1650: always include `offline_access` so Entra keeps issuing
        // + rotating a refresh_token. The stored `cur.scope` is the narrowed
        // response scope from the prior grant (Microsoft drops the OIDC
        // scopes on the response), so sending it verbatim would omit
        // `offline_access` from the second refresh onward and silently break
        // refresh-token continuity.
        scope: withOfflineAccess(cur.scope || DEFAULT_SCOPES),
        ...(CLIENT_SECRET ? { client_secret: CLIENT_SECRET } : {}),
      },
    )
  } catch (e) {
    // fetch() rejected — DNS/TCP/TLS failure. Always transient: keep the
    // existing token, do NOT mark token_expired, let the next call retry.
    // Scrub the exception text — re-thrown to the tool-handler catch
    // (agent-visible) and the audit builder scrubs its own copy too.
    const msg = scrubSecretShapedText(e instanceof Error ? e.message : String(e))
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
    // Scrub BOTH the error code and the description before they reach the
    // status marker (pair_status, agent-visible), the RefreshError.oauthError
    // (surfaced in getAccessToken's permanent re-auth message), or the
    // thrown error message (re-thrown to the tool-handler catch on the
    // transient path). r4: a compromised IdP/proxy could smuggle a token
    // into the top-level `error` field too — scrub for model consistency.
    const scrubbedError = scrubSecretShapedText(String(data.error))
    const scrubbedDesc = scrubSecretShapedText(String(data.error_description ?? ''))
    if (kind === 'permanent') {
      markTokenExpired(upn, `${scrubbedError}: ${scrubbedDesc.slice(0, 200)}`)
    }
    // Transient errors leave the stored token untouched (no saveJson) so a
    // subsequent call retries with the same still-valid refresh_token.
    throw new RefreshError(
      kind,
      scrubbedError,
      `refresh failed for ${upn}: ${scrubbedError} — ${scrubbedDesc.slice(0, 300)}`,
    )
  }

  // A 5xx with a non-JSON body comes back as { _raw, _status }. Treat any
  // missing access_token as transient (server hiccup), keep the token.
  if (!data || !data.access_token) {
    const status = data?._status
    // codex r1 BLOCKING #1: deep-redact the body before stringifying it
    // into the audit row. A malformed response that still carried a
    // refresh_token / access_token / id_token would otherwise leak the
    // raw bearer secret. redactResponseBody replaces secret-keyed values
    // with a sha256 fp (or <redacted>) on a safe copy — never the raw.
    process.stderr.write(
      refreshFailureAuditLine({
        upn,
        kind: 'transient',
        oauthError: status ? `http_${status}` : 'malformed_response',
        description: JSON.stringify(redactResponseBody(data ?? {})).slice(0, 200),
        refreshTokenPresent: true,
      }),
    )
    // The thrown message carries only the status — never the body.
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
    // Issue #1650: persist the scope WITH `offline_access` retained, so the
    // stored scope cannot drift `offline_access` out across successive
    // refreshes (the next refresh reads this back). The token endpoint's
    // response `scope` omits the OIDC scopes; re-adding `offline_access` here
    // keeps the file's scope refresh-capable and `pair_status` honest.
    scope: withOfflineAccess(String(data.scope ?? cur.scope)),
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

// #2035 item 2: proactive callers (a pre-expiry refresh cron) need a wider
// freshness margin than the interactive default WITHOUT changing the global
// 300s constant — raising that globally would pull every interactive Graph
// call's refresh_token rotation cadence in (rejected by the reporter). Opts:
// `minRemaining` refreshes when fewer than N seconds remain; `force` always
// refreshes. Both are absent on the interactive path, which keeps the exact
// 300s reactive behavior.
const NEAR_EXPIRY_SECONDS = 300
type TokenFreshness = { minRemaining?: number; force?: boolean }

async function getAccessToken(upn: string, freshness: TokenFreshness = {}): Promise<string> {
  const cur = normalizeTokenExpiry(loadJson<TokenFile>(tokenPath(upn)))
  if (!cur) throw new Error(`no token for ${upn}; run pair_start then pair_poll to authenticate`)
  const now = Math.floor(Date.now() / 1000)
  // Pre-call expiry check: refresh when expired OR within the near-expiry
  // margin (preemptive — avoids a mid-call 401). The margin defaults to the
  // 5-minute interactive constant; a proactive caller may widen it via
  // `minRemaining`, or `force` an unconditional refresh (#2035 item 2). Clamp
  // the margin to >= 0 (defense in depth) so a negative value can never let an
  // already-expired token slip past the check.
  const margin = Math.max(0, freshness.minRemaining ?? NEAR_EXPIRY_SECONDS)
  if (!freshness.force && cur.expires_at - now > margin) return cur.access_token

  // The refresh_token THIS caller would submit. The skip-redundant-grant
  // decision below keys off whether this value has been ROTATED by another
  // holder while we waited for the lock — a value comparison, so it is immune
  // to same-second `saved_at` collisions (every successful grant rotates the
  // refresh_token to a new opaque value).
  const prevRefreshToken = cur.refresh_token

  // Issue #2048: a refresh is needed. Serialize the rotating-grant POST ACROSS
  // processes (the MCP server, the get-valid-token CLI, any other caller share
  // this token file). Coalesce WITHIN this process via lockedRefreshInFlight (a
  // SingleFlight keyed by UPN, distinct from refreshInFlight) so two concurrent
  // in-process getAccessToken callers do not each take the cross-process lock —
  // only the flight leader does; the follower awaits its result. Then ACROSS
  // processes via the cross-process lock + a RE-READ: if another holder already
  // rotated the refresh_token (and the token is still usable / meets our margin)
  // skip the redundant grant and return the shared fresh token. Serialize +
  // re-read ⇒ exactly one grant, one rotation, no spent-RT replay → no
  // invalid_grant. A null lock handle means the lock timed out / was unavailable;
  // we proceed unlocked (the SingleFlight + this re-read still bound the race)
  // rather than hang the Graph call.
  try {
    const refreshed = await lockedRefreshInFlight.run(upn, async () => {
      const release = acquireRefreshLock(upn)
      try {
        const fresh = normalizeTokenExpiry(loadJson<TokenFile>(tokenPath(upn)))
        if (
          fresh &&
          fresh.access_token &&
          fresh.refresh_token &&
          fresh.refresh_token !== prevRefreshToken
        ) {
          // Another holder rotated the refresh_token while we waited on the
          // lock. Reuse the shared fresh token instead of POSTing the spent
          // pre-lock refresh_token (the double-consume).
          const reNow = Math.floor(Date.now() / 1000)
          if (freshness.force) {
            // A concurrent rotation satisfies a force too, as long as the
            // re-issued token is still usable — so two racing `force` callers
            // produce exactly one POST. A LONE force caller sees no rotation
            // (refresh_token unchanged) and falls through to grant.
            if (fresh.expires_at - reNow > 0) return fresh
          } else if (fresh.expires_at - reNow > margin) {
            // Reactive / proactive path: rotated AND within our margin → reuse.
            return fresh
          }
        }
        // Perform the grant via refreshToken (its own SingleFlight is the
        // within-process fast path; here it is reached only by the flight
        // leader). Distinct flight key (lockedRefreshInFlight) so this is safe.
        return await refreshToken(upn)
      } finally {
        // Release the cross-process lock on every flight exit. No-op when the
        // lock was unavailable (release === null).
        release?.()
      }
    })
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
    // r4 (adversarial sweep): this is the SECOND fetch path (independent
    // of postForm) and builds its own `_raw` envelope on non-JSON bodies.
    // The error is thrown → tool-handler catch → textResult (agent-
    // visible). access_token is the only secret reachable here
    // (refresh_token never travels to graph.microsoft.com), but a Graph
    // 4xx that echoes a bearer-shaped string still flows out. Route the
    // message text through the same scrub so this sink shares the
    // single choke-point. Graph error prose (e.g. "Insufficient
    // privileges") has no token shape and round-trips intact.
    const err = data?.error?.message ?? data?._raw ?? `HTTP ${res.status}`
    throw new Error(
      `graph ${method} ${path} failed (${res.status}): ${scrubSecretShapedText(String(err)).slice(0, 500)}`,
    )
  }
  return data
}

async function graphBytes(
  upn: string,
  method: string,
  path: string,
  query?: Record<string, string | number | undefined>,
  version: 'v1.0' | 'beta' = 'v1.0',
  maxBytes?: number,
): Promise<Buffer> {
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
      Accept: 'application/octet-stream',
    },
  })
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(
      `graph ${method} ${path} failed (${res.status}): ${scrubSecretShapedText(text || `HTTP ${res.status}`).slice(0, 500)}`,
    )
  }
  // When a cap is requested, reject a declared Content-Length over the cap
  // before reading any body, then stream with a hard running cap so an absent
  // or falsely-small Content-Length cannot push us past the limit. This keeps
  // the worst-case memory bounded by maxBytes (+ one chunk) rather than the
  // full attachment size.
  if (maxBytes != null) {
    const declared = Number(res.headers.get('content-length') ?? '')
    if (Number.isFinite(declared) && declared > maxBytes) {
      throw new Error(
        `attachment too large (${declared} bytes > max ${maxBytes}); raise MS365_ATTACHMENT_MAX_BYTES if needed`,
      )
    }
    const body = res.body
    if (body) {
      const reader = body.getReader()
      const chunks: Uint8Array[] = []
      let total = 0
      try {
        for (;;) {
          const { done, value } = await reader.read()
          if (done) break
          if (value && value.length) {
            total += value.length
            if (total > maxBytes) {
              try { await reader.cancel() } catch {}
              throw new Error(
                `attachment too large (>${maxBytes} bytes); raise MS365_ATTACHMENT_MAX_BYTES if needed`,
              )
            }
            chunks.push(value)
          }
        }
      } finally {
        try { reader.releaseLock() } catch {}
      }
      return Buffer.concat(chunks)
    }
    // No streamable body handle: fall back to arrayBuffer but still enforce
    // the cap so the guarantee holds.
    const buf = Buffer.from(await res.arrayBuffer())
    if (buf.length > maxBytes) {
      throw new Error(
        `attachment too large (${buf.length} bytes > max ${maxBytes}); raise MS365_ATTACHMENT_MAX_BYTES if needed`,
      )
    }
    return buf
  }
  return Buffer.from(await res.arrayBuffer())
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

function attachmentKind(odataType: unknown): 'file' | 'reference' | 'item' | 'unknown' {
  const t = String(odataType ?? '').toLowerCase()
  if (t.endsWith('fileattachment')) return 'file'
  if (t.endsWith('referenceattachment')) return 'reference'
  if (t.endsWith('itemattachment')) return 'item'
  return 'unknown'
}

function sanitizeAttachmentFilename(raw: unknown): string {
  const base = basename(String(raw ?? 'attachment').replace(/\0/g, '')).trim()
  const cleaned = base
    .replace(/[\\/]/g, '_')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/[<>:"|?*\x00-\x1F]/g, '_')
    .replace(/\s+/g, ' ')
    .replace(/^\.+$/, '')
    .slice(0, 180)
    .trim()
  return cleaned || 'attachment'
}

function isPathInside(parent: string, child: string): boolean {
  const p = resolve(parent)
  const c = resolve(child)
  return c === p || c.startsWith(p.endsWith(sep) ? p : `${p}${sep}`)
}

function resolveAttachmentSaveDir(raw: unknown): string {
  const root = resolve(ATTACHMENTS_DIR)
  const s = String(raw ?? '').trim()
  const target = s ? resolve(root, s) : root
  if (!isPathInside(root, target)) {
    throw new Error(`save_dir must be inside the ms365 attachments directory (${root})`)
  }
  mkdirSync(target, { recursive: true, mode: 0o700 })
  try {
    chmodSync(target, 0o700)
  } catch {}
  return target
}

function attachmentOutputPath(saveDir: string, name: string): string {
  const safeName = sanitizeAttachmentFilename(name)
  return join(saveDir, `${Date.now()}-${randomUUID()}-${safeName}`)
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
      const requestedUpn = resolveUpn(args.upn)
      const result = await exchangeAuthCode(requestedUpn)
      if (result.status === 'success') {
        // Issue #1825: the token is keyed by the AUTHENTICATED claim
        // (result.token.upn), which may differ from the opaque input
        // passed to pair_start. Report the durable key so the caller does
        // not have to re-derive it from the filesystem.
        const keyedUpn = result.token.upn
        return textResult({
          status: 'success',
          upn: keyedUpn,
          ...(keyedUpn !== requestedUpn
            ? { requested_upn: requestedUpn, rekeyed: true }
            : {}),
          scope: result.token.scope,
          expires_in_seconds: result.token.expires_at - Math.floor(Date.now() / 1000),
          has_refresh_token: Boolean(result.token.refresh_token),
        })
      }
      return textResult(result)
    },
  },
  {
    name: 'get_valid_token',
    description:
      'Return a currently-valid Microsoft Graph access_token for the UPN, transparently refreshing via the stored refresh_token if it is expired or within the 5-minute near-expiry margin. For trusted in-fleet callers (e.g. the CRM proxy, issue #1650) that must hold a guaranteed-valid token without reading the token file directly. A proactive-refresh caller may pass min_remaining_seconds to refresh when fewer than that many seconds remain, or force:true to refresh unconditionally (issue #2035). NEVER returns the refresh_token.',
    schema: {
      type: 'object',
      properties: {
        upn: { type: 'string', description: 'User principal name. Defaults to MS365_DEFAULT_UPN.' },
        min_remaining_seconds: {
          type: 'number',
          description:
            'Proactive-refresh margin: refresh when fewer than this many seconds remain. Omit for the default 5-minute (300s) reactive behavior.',
        },
        force: {
          type: 'boolean',
          description: 'Refresh unconditionally, ignoring the current expiry. Defaults to false.',
        },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      // #2035 item 2: thread an optional proactive-refresh margin through to the
      // freshness check; absent params keep the interactive 300s behavior.
      const freshness: TokenFreshness = {}
      // A negative margin would let an already-expired token slip past the
      // freshness check, so only accept a finite, non-negative value.
      if (typeof args.min_remaining_seconds === 'number' && Number.isFinite(args.min_remaining_seconds) && args.min_remaining_seconds >= 0) {
        freshness.minRemaining = args.min_remaining_seconds
      }
      if (args.force === true) freshness.force = true
      // #1650: reuse getAccessToken — pre-call expiry check + refresh_token
      // grant + SingleFlight coordination (no duplicate concurrent refresh) +
      // the transient/permanent classification and actionable re-auth error.
      // This is the safety net for callers (the CRM proxy) that previously read
      // the token file directly and so used a stale access_token: they now get a
      // guaranteed-valid token and the refresh happens here, in the ms365 plugin
      // that owns the refresh_token.
      const access_token = await getAccessToken(upn, freshness)
      // getAccessToken returns only the token string; the file carries the
      // authoritative post-refresh expiry. Normalize a legacy ms `expires_at`
      // here too so the reported expiry is in seconds (#2035 item 1).
      const cur = normalizeTokenExpiry(loadJson<TokenFile>(tokenPath(upn)))
      const now = Math.floor(Date.now() / 1000)
      const expires_at = cur?.expires_at ?? null
      const expires_in_seconds = expires_at != null ? expires_at - now : null
      // Redacted audit: record that a valid token was issued to a caller, with
      // upn + expiry only — never the token body, never the refresh_token.
      process.stderr.write(
        `ms365 channel: ms365_token_issued upn=${upn} expires_in_seconds=${expires_in_seconds ?? 'unknown'}\n`,
      )
      return textResult({ upn, access_token, expires_at, expires_in_seconds })
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
    name: 'mail_attachments_list',
    description:
      'List attachments for a message. Pass message_id from mail_list/mail_get. Returns metadata only; use mail_attachment_get for fileAttachment downloads.',
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
      const data = await graph(
        upn,
        'GET',
        `/me/messages/${encodeURIComponent(id)}/attachments`,
        undefined,
        { $select: 'id,name,contentType,size,isInline' },
      )
      const attachments = (data?.value ?? []).map((a: any) => {
        const type = a['@odata.type']
        return {
          id: a.id,
          name: a.name ?? '',
          contentType: a.contentType ?? null,
          size: typeof a.size === 'number' ? a.size : null,
          isInline: Boolean(a.isInline),
          kind: attachmentKind(type),
          odataType: type ?? null,
        }
      })
      return textResult({ message_id: id, count: attachments.length, attachments })
    },
  },
  {
    name: 'mail_attachment_get',
    description:
      'Download a fileAttachment from a message into the per-agent ms365 attachments directory. referenceAttachment and itemAttachment are not downloaded in this first version.',
    schema: {
      type: 'object',
      required: ['message_id', 'attachment_id'],
      properties: {
        upn: { type: 'string' },
        message_id: { type: 'string' },
        attachment_id: { type: 'string' },
        save_dir: {
          type: 'string',
          description:
            'Optional subdirectory under the ms365 attachments directory. Defaults to the root attachments dir.',
        },
      },
    },
    handler: async args => {
      const upn = resolveUpn(args.upn)
      const messageId = String(args.message_id ?? '').trim()
      const attachmentId = String(args.attachment_id ?? '').trim()
      if (!messageId) throw new Error('message_id is required')
      if (!attachmentId) throw new Error('attachment_id is required')
      // Resolve metadata from the list endpoint (metadata-only $select). The
      // single-resource GET would return a fileAttachment's base64 contentBytes
      // by default, pulling the whole payload into memory before any size guard
      // runs. Reading size from the metadata-only listing lets us reject an
      // oversized attachment before downloading a single byte.
      const listData = await graph(
        upn,
        'GET',
        `/me/messages/${encodeURIComponent(messageId)}/attachments`,
        undefined,
        { $select: 'id,name,contentType,size,isInline' },
      )
      const meta = (listData?.value ?? []).find((a: any) => a?.id === attachmentId)
      if (!meta) {
        throw new Error(`attachment ${attachmentId} not found on message ${messageId}`)
      }
      const kind = attachmentKind(meta['@odata.type'])
      if (kind === 'reference' || kind === 'item') {
        throw new Error(`attachment kind ${kind} is not downloadable yet; only fileAttachment is supported`)
      }
      const declaredSize = typeof meta.size === 'number' ? meta.size : null
      if (declaredSize != null && declaredSize > ATTACHMENT_MAX_BYTES) {
        throw new Error(
          `attachment too large (${declaredSize} bytes > max ${ATTACHMENT_MAX_BYTES}); raise MS365_ATTACHMENT_MAX_BYTES if needed`,
        )
      }
      // Download the raw bytes through $value with a hard streaming cap; never
      // rely on Graph's base64 JSON response for the primary download path.
      const bytes = await graphBytes(
        upn,
        'GET',
        `/me/messages/${encodeURIComponent(messageId)}/attachments/${encodeURIComponent(attachmentId)}/$value`,
        undefined,
        'v1.0',
        ATTACHMENT_MAX_BYTES,
      )
      const saveDir = resolveAttachmentSaveDir(args.save_dir)
      const name = sanitizeAttachmentFilename(meta.name)
      const path = attachmentOutputPath(saveDir, name)
      writeFileSync(path, bytes, { mode: 0o600 })
      try {
        chmodSync(path, 0o600)
      } catch {}
      return textResult({
        path,
        name,
        contentType: meta.contentType ?? null,
        size: bytes.length,
        declaredSize,
        kind,
        message_id: messageId,
        attachment_id: attachmentId,
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

// #1650 B1: one-shot CLI entrypoint for sibling stdio callers (the cosmax-crm
// proxy crm-mcp-proxy.mjs) that are NOT MCP clients and so cannot invoke the
// get_valid_token MCP tool. `bun server.ts get-valid-token [upn]` prints one
// JSON line { upn, access_token, expires_at, expires_in_seconds } to stdout and
// exits — same contract as the get_valid_token tool: refresh-on-expiry via
// getAccessToken (refresh_token grant + SingleFlight), NEVER the refresh_token.
// #2035 item 2: a proactive-refresh cron worker (no MCP) can widen the margin
// with `--min-remaining <seconds>` or force a refresh with `--force`; absent
// both, the call keeps the interactive 300s reactive behavior.
// Handled before mcp.connect so it never starts the server.
if (process.argv[2] === 'get-valid-token') {
  // #1654 codex r1 BLOCKING: resolveUpn() throws when no upn arg AND no
  // MS365_DEFAULT_UPN. Keep it INSIDE the try so that failure exits non-zero
  // (the global uncaughtException handler only logs — it would exit 0). `upn`
  // is declared outside so the catch can still name it in the audit.
  let upn = ''
  try {
    // #2035 item 2: parse optional proactive-refresh flags from the argv tail,
    // and resolve the upn from the first NON-flag positional so a flag-only call
    // (`get-valid-token --force`, default UPN from env) is not mistaken for
    // `get-valid-token <upn=--force>`.
    const cliArgs = process.argv.slice(3)
    const freshness: TokenFreshness = {}
    if (cliArgs.includes('--force')) freshness.force = true
    const minIdx = cliArgs.indexOf('--min-remaining')
    if (minIdx !== -1 && cliArgs[minIdx + 1] !== undefined) {
      const parsed = Number(cliArgs[minIdx + 1])
      // Reject non-finite / negative margins — a negative margin would let an
      // already-expired token slip past the freshness check.
      if (Number.isFinite(parsed) && parsed >= 0) freshness.minRemaining = parsed
    }
    const upnArg = cliArgs.find((a, i) => !a.startsWith('--') && cliArgs[i - 1] !== '--min-remaining')
    upn = resolveUpn(upnArg)
    const access_token = await getAccessToken(upn, freshness)
    const cur = normalizeTokenExpiry(loadJson<TokenFile>(tokenPath(upn)))
    const now = Math.floor(Date.now() / 1000)
    const expires_at = cur?.expires_at ?? null
    const expires_in_seconds = expires_at != null ? expires_at - now : null
    // Redacted audit (upn + expiry only, never the token body), like the tool.
    process.stderr.write(
      `ms365 channel: ms365_token_issued upn=${upn} expires_in_seconds=${expires_in_seconds ?? 'unknown'} (cli)\n`,
    )
    process.stdout.write(JSON.stringify({ upn, access_token, expires_at, expires_in_seconds }) + '\n')
    process.exit(0)
  } catch (e) {
    process.stderr.write(
      `ms365 channel: ms365_token_issue_failed upn=${upn || process.argv[3] || '<none>'} err=${e instanceof Error ? e.message : String(e)}\n`,
    )
    process.exit(1)
  }
}

await mcp.connect(new StdioServerTransport())
process.stderr.write(`ms365: MCP connected (tenant=${TENANT_ID.slice(0, 8)}..., client=${CLIENT_ID.slice(0, 8)}..., secret_len=${CLIENT_SECRET.length}, default_upn=${DEFAULT_UPN}, state_dir=${STATE_DIR})\n`)
