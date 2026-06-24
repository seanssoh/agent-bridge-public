#!/usr/bin/env bun
/**
 * Microsoft Teams channel for Claude Code.
 *
 * Azure Bot Service posts activities to /api/messages. This server gates them
 * with access.json, forwards accepted messages through Claude channel
 * notifications, and exposes reply/fetch tools over MCP.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { BotFrameworkAdapter, TurnContext, ActivityTypes } from 'botbuilder'
import type { ConversationReference, Activity } from 'botbuilder'
import { ConnectorClient, MicrosoftAppCredentials } from 'botframework-connector'
import { createServer } from 'http'
import { randomUUID } from 'crypto'
import { spawnSync } from 'child_process'
import {
  accessSync,
  appendFileSync,
  chmodSync,
  constants as fsConstants,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'fs'
import { homedir } from 'os'
import { basename, isAbsolute as pathIsAbsolute, join, resolve as pathResolve } from 'path'
import { createRecentMessageDeduper, storedRowMatchesIncoming } from './dedupe.ts'
import { renderOutbound } from './cardintent.ts'

type GroupPolicy = {
  requireMention?: boolean
  allowFrom?: string[]
}

type Access = {
  dmPolicy?: 'allowlist' | 'open' | 'disabled'
  allowFrom?: string[]
  groups?: Record<string, GroupPolicy>
  pending?: Record<string, unknown>
  routes?: Record<string, unknown>
}

type StoredAttachment = {
  attachment_id: string
  name: string
  content_type: string
  size_bytes?: number
  download_url?: string
  local_path?: string
  download_status: 'ok' | 'skipped_non_file' | 'failed'
  download_error?: string
}

type StoredMessage = {
  chat_id: string
  message_id: string
  user: string
  user_id: string
  aad_object_id: string
  text: string
  ts: string
  // Edit indicator: Teams reuses message_id on edits but bumps
  // localTimestamp/timestamp. Stored so deliveredMessageSeen can let edits
  // through while still dropping pure retransmits.
  revision?: string
  attachments?: StoredAttachment[]
}

type Ms365CallbackPayload = {
  state: string
  code?: string
  error?: string
  error_description?: string
  received_at: number
}

const STATE_DIR = process.env.TEAMS_STATE_DIR ?? join(homedir(), '.claude', 'channels', 'teams')
const BRIDGE_HOME = process.env.BRIDGE_HOME ?? join(homedir(), '.agent-bridge')
const BRIDGE_STATE_DIR = process.env.BRIDGE_STATE_DIR ?? join(BRIDGE_HOME, 'state')
const ACCESS_FILE = join(STATE_DIR, 'access.json')
const ENV_FILE = join(STATE_DIR, '.env')
const REFERENCES_FILE = join(STATE_DIR, 'conversations.json')
const MESSAGES_FILE = join(STATE_DIR, 'messages.jsonl')
function resolveAttachmentsDir(): string {
  const override = process.env.TEAMS_ATTACHMENTS_DIR
  if (override) {
    if (!pathIsAbsolute(override)) {
      process.stderr.write(
        `teams channel: TEAMS_ATTACHMENTS_DIR not absolute, falling back to default\n`,
      )
    } else {
      try {
        accessSync(override, fsConstants.W_OK)
        return override
      } catch {
        // Don't echo override path on failure to avoid leaking attacker-supplied
        // env bytes into logs.
        process.stderr.write(
          `teams channel: TEAMS_ATTACHMENTS_DIR not writable, falling back to default\n`,
        )
      }
    }
  }
  return pathResolve(STATE_DIR, 'attachments')
}

function resolveAttachmentMaxBytes(): number {
  const DEFAULT_MAX = 50 * 1024 * 1024 // 50 MB
  const CEILING = 1024 * 1024 * 1024 // 1 GB sanity ceiling
  const raw = process.env.TEAMS_ATTACHMENT_MAX_BYTES
  if (!raw) return DEFAULT_MAX
  const n = Number(raw)
  if (!Number.isFinite(n) || n <= 0) {
    process.stderr.write(
      `teams channel: TEAMS_ATTACHMENT_MAX_BYTES invalid, using default ${DEFAULT_MAX}\n`,
    )
    return DEFAULT_MAX
  }
  if (n > CEILING) {
    process.stderr.write(
      `teams channel: TEAMS_ATTACHMENT_MAX_BYTES exceeds ceiling ${CEILING}, using ceiling\n`,
    )
    return CEILING
  }
  return Math.floor(n)
}

const ATTACHMENTS_DIR = resolveAttachmentsDir()
const ATTACHMENT_MAX_BYTES = resolveAttachmentMaxBytes()
const TEAMS_FILE_DOWNLOAD_TYPE = 'application/vnd.microsoft.teams.file.download.info'
const TEAMS_FILE_CONSENT_CARD_TYPE = 'application/vnd.microsoft.teams.card.file.consent'
const TEAMS_FILE_INFO_CARD_TYPE = 'application/vnd.microsoft.teams.card.file.info'
const OUTBOUND_CONSENT_TTL_MS = 24 * 60 * 60 * 1000 // 24h
const OUTBOUND_MAX_ATTACHMENTS_PER_MESSAGE = 10
const OUTBOUND_CONSENTS_FILE = join(STATE_DIR, 'outbound-consents.json')
const MS365_CALLBACK_DIR =
  process.env.MS365_CALLBACK_SHARED_DIR ?? join(BRIDGE_HOME, 'shared', 'ms365-callbacks')

// chmod is best-effort; if it fails (e.g. an isolated linux-user UID
// that owns the file via setfacl-grant but not via inode owner) we must
// still proceed to load the env file. Splitting the chmod and the read
// avoids the previous abort-on-chmod-EPERM path.
try {
  chmodSync(ENV_FILE, 0o600)
} catch {}
try {
  const inheritedEnv = new Set(Object.keys(process.env))
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^(\w+)=(.*)$/)
    if (m && !inheritedEnv.has(m[1])) process.env[m[1]] = m[2]
  }
} catch {}

const HOST = process.env.TEAMS_WEBHOOK_HOST ?? '127.0.0.1'
const PORT = Number(process.env.TEAMS_WEBHOOK_PORT ?? '3978')
const STATIC = process.env.TEAMS_ACCESS_MODE === 'static'

const APP_ID = process.env.TEAMS_APP_ID ?? process.env.MicrosoftAppId
const APP_PASSWORD = process.env.TEAMS_APP_PASSWORD ?? process.env.MicrosoftAppPassword
const TENANT_ID = process.env.TEAMS_TENANT_ID ?? process.env.MicrosoftAppTenantId ?? ''

if (!APP_ID || !APP_PASSWORD) {
  process.stderr.write(
    `teams channel: TEAMS_APP_ID and TEAMS_APP_PASSWORD are required\n` +
    `  set them in ${ENV_FILE}\n`,
  )
  process.exit(1)
}

process.on('unhandledRejection', err => {
  process.stderr.write(`teams channel: unhandled rejection: ${err}\n`)
})
process.on('uncaughtException', err => {
  process.stderr.write(`teams channel: uncaught exception: ${err}\n`)
})

/**
 * Graceful shutdown: close the HTTP listener (releasing the bound port) and
 * exit. This is referenced by the signal handlers and the parent-death
 * watchdog below. See issue #69.
 */
let shuttingDown = false
function gracefulShutdown(reason: string): void {
  if (shuttingDown) return
  shuttingDown = true
  process.stderr.write(`teams channel: shutting down (${reason})\n`)
  try {
    httpServer.close(() => process.exit(0))
  } catch {
    process.exit(0)
  }
  // Safety: if close() hangs (open keep-alive sockets), force exit quickly.
  setTimeout(() => process.exit(0), 1500).unref?.()
}

// Signal handlers: without these, bun does not release the port when tmux
// SIGKILLs the pane process tree — the bun child is reparented to init and
// keeps holding the port. See issue #69 Defect A.
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'))
process.on('SIGHUP', () => gracefulShutdown('SIGHUP'))
process.on('SIGINT', () => gracefulShutdown('SIGINT'))

// Parent-death watchdog: poll process.ppid every 2s. If the parent has been
// reaped and we got reparented to init (ppid=1), shut down. This catches the
// abrupt `tmux kill-session` path, where no signal is delivered to the
// grandchild bun process.
const parentDeathWatch = setInterval(() => {
  try {
    if (process.ppid === 1) {
      clearInterval(parentDeathWatch)
      gracefulShutdown('parent-died')
    }
  } catch {}
}, 2000)
parentDeathWatch.unref?.()

function ensureStateDir(): void {
  // Issue #1215: STATE_DIR (the per-agent `.teams/` parent) is shared
  // between the isolated UID and the controller's `ab-agent-<slug>`
  // group on iso v2 hosts. Pre-#1215 the dir was created with mode
  // `0o700` which produced `drw---S---` after the v2 chown/chgrp pass
  // (no traversal bit for the group). The explicit `chmodSync` after
  // `mkdirSync` self-heals an existing bad-mode dir on the next teams
  // process startup. Match the ms365 fix shape — same family.
  //
  // MS365_CALLBACK_DIR stays `0o700`: only the teams plugin's listener
  // and the controller's callback-claim helper need to read it, and
  // both run as the same UID. The shared-callback contract is a
  // different family (ab-shared/3770) and explicitly out of scope per
  // the #1215 brief.
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o770 })
  try {
    chmodSync(STATE_DIR, 0o2770)
  } catch {}
  mkdirSync(MS365_CALLBACK_DIR, { recursive: true, mode: 0o700 })
}

function loadJson<T>(path: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(path, 'utf8')) as T
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return fallback
    try { renameSync(path, `${path}.corrupt-${Date.now()}`) } catch {}
    return fallback
  }
}

function saveJson(path: string, payload: unknown): void {
  ensureStateDir()
  const tmp = `${path}.tmp`
  writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 })
  renameSync(tmp, path)
  chmodSync(path, 0o600)
}

function ms365CallbackStateValid(state: string): boolean {
  // Allow a `.` so the multi-agent router can carry a `<agent>.<uuid>` prefix
  // (the ms365 plugin embeds BRIDGE_AGENT_ID to demux a shared /auth/callback).
  // No `/` is permitted, so `ms365CallbackPath` can never escape the callback
  // dir; min length 8 still rejects `..`. Max bumped to fit agent prefix+uuid.
  return /^[A-Za-z0-9_.-]{8,160}$/.test(state)
}

function ms365CallbackPath(state: string): string {
  return join(MS365_CALLBACK_DIR, `${state}.json`)
}

function handleMs365AuthCallback(url: URL, res: import('http').ServerResponse): void {
  const state = String(url.searchParams.get('state') ?? '').trim()
  const code = String(url.searchParams.get('code') ?? '').trim()
  const error = String(url.searchParams.get('error') ?? '').trim()
  const errorDescription = String(url.searchParams.get('error_description') ?? '').trim()

  if (!ms365CallbackStateValid(state)) {
    res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('invalid or missing state')
    return
  }
  if (!code && !error) {
    res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('missing code or error')
    return
  }

  const payload: Ms365CallbackPayload = {
    state,
    received_at: Math.floor(Date.now() / 1000),
  }
  if (code) payload.code = code
  if (error) payload.error = error
  if (errorDescription) payload.error_description = errorDescription
  saveJson(ms365CallbackPath(state), payload)

  const body = error
    ? '<html><body><h1>Microsoft 365 pairing failed</h1><p>Return to Claude Code and run pair_poll to inspect the error.</p></body></html>'
    : '<html><body><h1>Microsoft 365 pairing received</h1><p>Return to Claude Code and run pair_poll to finish pairing.</p></body></html>'
  res.writeHead(error ? 400 : 200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  })
  res.end(body)
}

function defaultAccess(): Access {
  return { dmPolicy: 'allowlist', allowFrom: [], groups: {}, pending: {}, routes: {} }
}

const BOOT_ACCESS = STATIC ? loadJson<Access>(ACCESS_FILE, defaultAccess()) : null

function loadAccess(): Access {
  return BOOT_ACCESS ?? loadJson<Access>(ACCESS_FILE, defaultAccess())
}

// Normalize CRLF and bare CR to LF. Applied by both compactText and htmlToText
// so every text path into runPromptGuard/channel delivery is LF-only.
function normalizeLineEndings(s: string): string {
  return s.replace(/\r\n/g, '\n').replace(/\r/g, '\n')
}

function compactText(text: string): string {
  return normalizeLineEndings(text.replace(/<at>[^<]+<\/at>/g, '')).trim()
}

// Extract plain text from an HTML string. Used when Teams delivers the message
// body as an inline text/html attachment (activity.text is empty) rather than
// in activity.text directly. Handles common inline elements and basic entities.
function htmlToText(html: string): string {
  return normalizeLineEndings(
    html
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>/gi, '\n')
      .replace(/<\/div>/gi, '\n')
      .replace(/<[^>]+>/g, '')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&')
      .replace(/&nbsp;/g, ' ')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
  )
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

function idsFor(activity: Activity): string[] {
  const from = activity.from ?? {}
  const aad = String((from as any).aadObjectId ?? '').trim()
  const id = String(from.id ?? '').trim()
  return [aad, id].filter(Boolean)
}

function userAllowed(policyIds: string[] | undefined, userIds: string[]): boolean {
  const allow = policyIds ?? []
  if (allow.length === 0) return true
  return userIds.some(id => allow.includes(id))
}

function activityMentionedBot(activity: Activity): boolean {
  const text = activity.text ?? ''
  if (/<at>[^<]+<\/at>/.test(text)) return true
  const entities = Array.isArray(activity.entities) ? activity.entities : []
  return entities.some(entity => entity.type === 'mention')
}

function gate(activity: Activity): boolean {
  const access = loadAccess()
  if (access.dmPolicy === 'disabled') return false

  const conversationId = String(activity.conversation?.id ?? '').trim()
  const channelId = String((activity.channelData as any)?.channel?.id ?? '').trim()
  const conversationType = String(activity.conversation?.conversationType ?? '').trim()
  const userIds = idsFor(activity)

  for (const key of [conversationId, channelId]) {
    if (!key) continue
    const policy = access.groups?.[key]
    if (!policy) continue
    if (policy.requireMention && !activityMentionedBot(activity)) return false
    return userAllowed(policy.allowFrom, userIds)
  }

  if (conversationType === 'personal') {
    if (access.dmPolicy === 'open') return true
    return userIds.some(id => (access.allowFrom ?? []).includes(id))
  }

  return false
}

function referenceKey(activity: Activity): string {
  return String(activity.conversation?.id ?? '').trim()
}

function storeReference(activity: Activity): void {
  const key = referenceKey(activity)
  if (!key) return
  const refs = loadJson<Record<string, ConversationReference>>(REFERENCES_FILE, {})
  refs[key] = TurnContext.getConversationReference(activity)
  saveJson(REFERENCES_FILE, refs)
}

function appendMessage(message: StoredMessage): void {
  ensureStateDir()
  appendFileSync(MESSAGES_FILE, JSON.stringify(message) + '\n', { mode: 0o600 })
}

// PreCompact channel auto-notify activity index — issue #597 Track C.
//
// Writes $BRIDGE_STATE_DIR/channels/teams/<agent>.json so the daemon's
// route-precompact-target lookup can pick the most recent inbound chat
// to notify on context compaction. Best-effort: any failure is logged and
// swallowed so a state-dir glitch never breaks live message delivery.

type TeamsActivityChannelEntry = {
  channel_id: string
  reply_kind: string
  last_seen_id?: string
  last_seen_ts?: number
  last_user_inbound_ts: number
  last_user_inbound_ts_ms: number
  last_user_inbound_message_id: string
  last_user_inbound_user_id: string
  last_user_inbound_recorded_ns: number
  thread_id?: string
}

type TeamsActivityIndex = {
  schema_version: number
  agent: string
  plugin: 'teams'
  updated_ts: number
  channels: Record<string, TeamsActivityChannelEntry>
}

function sanitizeAgentForPath(raw: string): string {
  // Activity-index files live at $BRIDGE_STATE_DIR/channels/teams/<agent>.json.
  // The agent name comes from BRIDGE_AGENT_ID, but we still defense-in-depth
  // against path traversal — same allowlist as bridge-agents.sh agent ids.
  if (!raw || typeof raw !== 'string') return ''
  if (raw.length > 64) return ''
  if (!/^[a-zA-Z0-9_-]+$/.test(raw)) return ''
  return raw
}

function teamsActivityIndexPath(agent: string): string {
  return join(BRIDGE_STATE_DIR, 'channels', 'teams', `${agent}.json`)
}

function loadTeamsActivityIndex(path: string, agent: string): TeamsActivityIndex {
  try {
    const raw = readFileSync(path, 'utf8')
    const parsed = JSON.parse(raw)
    if (parsed && typeof parsed === 'object' && parsed.channels && typeof parsed.channels === 'object') {
      return parsed as TeamsActivityIndex
    }
  } catch {}
  return {
    schema_version: 1,
    agent,
    plugin: 'teams',
    updated_ts: 0,
    channels: {},
  }
}

let teamsRecordedTail = 0

export function writeTeamsActivityIndex(
  agent: string,
  channelId: string,
  messageId: string,
  userId: string,
  inboundDate: Date,
): void {
  const safeAgent = sanitizeAgentForPath(agent)
  if (!safeAgent || !channelId || !messageId) return
  try {
    const path = teamsActivityIndexPath(safeAgent)
    const dir = join(BRIDGE_STATE_DIR, 'channels', 'teams')
    mkdirSync(dir, { recursive: true, mode: 0o700 })
    const index = loadTeamsActivityIndex(path, safeAgent)
    const tsMs = inboundDate.getTime()
    const tsSec = Math.floor(tsMs / 1000)
    // recorded_ns must be a JSON number (the route primitive int-coerces it).
    // Real epoch nanoseconds (~1.7e18) exceed Number.MAX_SAFE_INTEGER, so we
    // pack ms-precision into the upper digits and a per-process monotonic
    // tail into the lower digits. The route primitive only consults this for
    // tie-break ordering inside a 1-second window, so monotonicity within a
    // process is the only invariant that matters.
    const nowNs = tsMs * 1_000 + (teamsRecordedTail++ % 1_000)
    index.schema_version = 1
    index.agent = safeAgent
    index.plugin = 'teams'
    index.updated_ts = tsSec
    index.channels[channelId] = {
      channel_id: channelId,
      reply_kind: 'conversation',
      last_seen_id: messageId,
      last_seen_ts: tsSec,
      last_user_inbound_ts: tsSec,
      last_user_inbound_ts_ms: tsMs,
      last_user_inbound_message_id: messageId,
      last_user_inbound_user_id: userId,
      last_user_inbound_recorded_ns: nowNs,
    }
    // L1 beta19 (codex r1 design 2026-05-25): activity-index files are
    // read by the controller daemon's route lookup (bridge-channels.py:
    // 289-304) even when the file was created by an isolated UID. Mode
    // 0600 blocks the daemon's read; widen to 0640 so the ab-shared
    // group (which the reconciler sets via setgid on
    // state/channels/teams/) covers the controller read path while world
    // remains locked out.
    //
    // We chmod both the tmp file (in case the rename races a reader that
    // opens by name before chmod hits) and the final file after rename
    // (atomic-mode replace on most filesystems, but chmodSync is the
    // belt-and-braces invariant). Keep the generic per-agent state files
    // routed through saveJson() at mode 0600 — only the activity index
    // needs the daemon-group read grant.
    const tmp = `${path}.tmp`
    writeFileSync(tmp, JSON.stringify(index, null, 2) + '\n', { mode: 0o640 })
    chmodSync(tmp, 0o640)
    renameSync(tmp, path)
    chmodSync(path, 0o640)
  } catch (err) {
    process.stderr.write(`teams channel: activity-index write failed: ${err}\n`)
  }
}

function deliveredMessageSeen(chatId: string, messageId: string, revision: string): boolean {
  if (!chatId || !messageId || !existsSync(MESSAGES_FILE)) return false
  try {
    const lines = readFileSync(MESSAGES_FILE, 'utf8').split('\n').filter(Boolean)
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      try {
        const row = JSON.parse(lines[i]) as Partial<StoredMessage>
        if (row.chat_id !== chatId || row.message_id !== messageId) continue
        if (storedRowMatchesIncoming(row.revision, revision)) return true
      } catch {}
    }
  } catch {}
  return false
}

function sanitizeMessageId(raw: string): string {
  // Teams message ids are typically guid-like, numeric, or "<guid>:<num>".
  // Strict allowlist prevents path-traversal via attacker-controlled activity.id.
  // Dot is intentionally NOT in the allowlist — single dots could let an
  // attacker craft segments that the filesystem resolves into traversal
  // under some path normalization (codex r2 PR #443). Real Teams message
  // ids in the wild are alphanumeric/colon/dash/underscore; the rare
  // dotted format safely fail-closes (download_status=failed).
  if (!raw || typeof raw !== 'string') return ''
  if (raw.length > 256) return ''
  if (!/^[A-Za-z0-9_:\-]+$/.test(raw)) return ''
  return raw
}

function sanitizeFilename(name: string): string {
  if (!name || typeof name !== 'string') return ''
  // Strip path-traversal segments and separators first.
  let clean = name.replace(/\.\./g, '_').replace(/[\\/]/g, '_')
  // Strip control chars + DEL + null bytes.
  // eslint-disable-next-line no-control-regex
  clean = clean.replace(/[\x00-\x1f\x7f]/g, '')
  // Strip leading/trailing dots and whitespace.
  clean = clean.replace(/^[.\s]+|[.\s]+$/g, '')
  // Allowlist: alphanumerics, dot, dash, underscore, space.
  clean = clean.replace(/[^A-Za-z0-9._\- ]/g, '_')
  if (clean.length === 0 || clean.length > 255) return ''
  return clean
}

// Token-leak guard: the bot's Bot Framework access token must only ever be
// attached to a host that is provably a Bot Framework / AMS attachment
// endpoint. A malicious or misconfigured `contentUrl` could otherwise
// exfiltrate the bot token to an arbitrary host.
//
// Matching is by EXACT host, never by bare suffix — a bare suffix like
// `trafficmanager.net` would also match `attacker.trafficmanager.net` (anyone
// can create an Azure Traffic Manager hostname) and `skype.com` would match
// every non-AMS Skype host. Both are token-exfiltration surfaces.
//
//  - `smba.trafficmanager.net` — Bot Framework service-url attachment host
//    (`/v3/attachments/...`). Exact host only; regional variants, if any,
//    must be enumerated exactly here rather than suffix-matched.
//  - `*.asm.skype.com` — Azure Media Service (AMS) hosts for inline-image /
//    general-attachment content URLs (e.g. `api.asm.skype.com`). Allowed as
//    the exact host `asm.skype.com` or a true subdomain of it.
const BOT_FRAMEWORK_ATTACHMENT_EXACT_HOSTS = [
  'smba.trafficmanager.net',
]
const AMS_ATTACHMENT_HOST = 'asm.skype.com'

function isBotFrameworkAttachmentHost(url: string): boolean {
  let host: string
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'https:') return false
    host = parsed.hostname.toLowerCase()
  } catch {
    return false
  }
  if (BOT_FRAMEWORK_ATTACHMENT_EXACT_HOSTS.includes(host)) return true
  // AMS: exact host or a true subdomain of asm.skype.com. The leading-dot
  // check on a true subdomain rejects spoofs like `asm.skype.com.evil.com`.
  if (host === AMS_ATTACHMENT_HOST) return true
  if (host.endsWith(`.${AMS_ATTACHMENT_HOST}`)) return true
  return false
}

async function streamDownload(
  url: string,
  destPath: string,
  maxBytes: number,
  authToken?: string,
): Promise<{ ok: true; size: number } | { ok: false; error: string }> {
  // Attach the bot token only on the secured Bot Framework attachment path
  // (the inline-image / general-attachment URL that 401s). The token-leak
  // guard keeps the token off any non-Bot-Framework host even if a caller
  // passes one in. The pre-signed file-picker downloadUrl path passes no
  // token and is unaffected.
  const headers: Record<string, string> = {}
  if (authToken && isBotFrameworkAttachmentHost(url)) {
    headers['Authorization'] = `Bearer ${authToken}`
  }
  const resp = await fetch(url, { headers })
  if (!resp.ok) return { ok: false, error: `HTTP ${resp.status}` }
  const cl = resp.headers.get('content-length')
  if (cl !== null) {
    const declared = Number(cl)
    if (Number.isFinite(declared) && declared > maxBytes) {
      return { ok: false, error: 'size_limit' }
    }
  }
  if (!resp.body) return { ok: false, error: 'no response body' }

  let total = 0
  // Pre-create the file with restrictive mode so the writer inherits 0600.
  writeFileSync(destPath, '', { mode: 0o600 })
  const writer = Bun.file(destPath).writer()
  const reader = resp.body.getReader()
  try {
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      if (!value) continue
      total += value.byteLength
      if (total > maxBytes) {
        try { await writer.end() } catch {}
        try { unlinkSync(destPath) } catch {}
        return { ok: false, error: 'size_limit' }
      }
      writer.write(value)
    }
    await writer.end()
    return { ok: true, size: total }
  } catch (err) {
    try { await writer.end() } catch {}
    try { unlinkSync(destPath) } catch {}
    return { ok: false, error: String((err as Error)?.message ?? err) }
  }
}

// Cards (adaptive, hero, signin, file consent, …) are explicitly NOT general
// files. They live under application/vnd.microsoft.card.* and
// application/vnd.microsoft.teams.card.*. Inbound download skips them and
// outbound delivery rejects them (operator scope: "general files only").
function isCardContentType(ct: string): boolean {
  return (
    ct.startsWith('application/vnd.microsoft.card.') ||
    ct.startsWith('application/vnd.microsoft.teams.card.')
  )
}

// Inbound allowlist: image/*, audio/*, video/*, text/*, and any
// application/* that is NOT a card. Covers PDF, DOCX, ZIP, octet-stream,
// plain text, etc. Matches the "general files only" scope from #957.
function isGeneralFileContentType(ct: string): boolean {
  if (!ct) return false
  if (isCardContentType(ct)) return false
  if (ct.startsWith('image/')) return true
  if (ct.startsWith('audio/')) return true
  if (ct.startsWith('video/')) return true
  if (ct.startsWith('text/')) return true
  if (ct.startsWith('application/')) return true
  return false
}

// Minimal mime map for outbound attachments. We infer from the sanitized
// filename because Teams' file consent card flow expects a content type in
// the FileInfoCard payload, and agents are not asked to specify one. Anything
// not matched falls through to application/octet-stream (Teams accepts that
// for arbitrary binary downloads).
const OUTBOUND_MIME_BY_EXT: Record<string, string> = {
  '.pdf': 'application/pdf',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.csv': 'text/csv',
  '.json': 'application/json',
  '.xml': 'application/xml',
  '.html': 'text/html',
  '.htm': 'text/html',
  '.zip': 'application/zip',
  '.gz': 'application/gzip',
  '.tar': 'application/x-tar',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
}

function inferContentType(filename: string): string {
  const lower = filename.toLowerCase()
  const dot = lower.lastIndexOf('.')
  if (dot < 0) return 'application/octet-stream'
  const ext = lower.slice(dot)
  return OUTBOUND_MIME_BY_EXT[ext] ?? 'application/octet-stream'
}

// Outbound attachments must live under an allowlist root so a compromised or
// confused agent cannot leak arbitrary host files (e.g. ~/.ssh/id_rsa) by
// passing an absolute path to `reply`. Default root is per-plugin under
// STATE_DIR; operator can override with TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT.
function resolveOutboundAllowRoot(): string {
  const override = process.env.TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT
  let root: string
  if (override) {
    if (!pathIsAbsolute(override)) {
      process.stderr.write(
        `teams channel: TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT not absolute, using default\n`,
      )
      root = pathResolve(STATE_DIR, 'outbound')
    } else {
      root = pathResolve(override)
    }
  } else {
    root = pathResolve(STATE_DIR, 'outbound')
  }
  try {
    mkdirSync(root, { recursive: true, mode: 0o700 })
  } catch {}
  // r3 fix (NOTE #1): assert the resolved root is actually a directory.
  // mkdir is a no-op if the path already exists as a regular file, and a
  // file-valued env var would otherwise authorize that exact file as the
  // allow root via the `=== allowRootReal` equality branch in the per-path
  // containment check. realpath + isDirectory closes that hole.
  let real: string
  try {
    real = realpathSync(root)
  } catch (err) {
    throw new Error(
      `TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT does not resolve: ${root} (${(err as Error)?.message ?? err})`,
    )
  }
  const s = statSync(real)
  if (!s.isDirectory()) {
    throw new Error(
      `TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT must be a directory: ${root} -> ${real}`,
    )
  }
  return real
}

function resolveOutboundMaxBytes(): number {
  const DEFAULT_MAX = 50 * 1024 * 1024 // 50 MB
  const CEILING = 1024 * 1024 * 1024 // 1 GB sanity ceiling
  const raw = process.env.TEAMS_OUTBOUND_ATTACHMENT_MAX_BYTES
  if (!raw) return DEFAULT_MAX
  const n = Number(raw)
  if (!Number.isFinite(n) || n <= 0) {
    process.stderr.write(
      `teams channel: TEAMS_OUTBOUND_ATTACHMENT_MAX_BYTES invalid, using default ${DEFAULT_MAX}\n`,
    )
    return DEFAULT_MAX
  }
  if (n > CEILING) {
    process.stderr.write(
      `teams channel: TEAMS_OUTBOUND_ATTACHMENT_MAX_BYTES exceeds ceiling ${CEILING}, using ceiling\n`,
    )
    return CEILING
  }
  return Math.floor(n)
}

// Pending outbound file consent state. Persisted under STATE_DIR so a plugin
// restart between "agent calls reply with attachments" and "user accepts
// consent card" can still complete the upload.
type OutboundConsentRecord = {
  abs_path: string
  display_name: string
  size: number
  content_type: string
  agent_message: string
  created_at: string
  conversation_id: string
  chat_id: string
  // Defense-in-depth: bind the consent token to the user the card was sent to
  // (the ConversationReference's user.aadObjectId, when Teams populates it).
  // The invoke handler rejects mismatches so a leaked token can't be replayed
  // by another user even if Teams' threading model changes in the future.
  // Empty string means we never had the field (older record or non-Teams ref).
  aad_object_id?: string
}

type OutboundConsentStore = Record<string, OutboundConsentRecord>

// Per-process serialization for consent-store mutations. Two concurrent
// fileConsent/invoke handlers (or an invoke racing the startup TTL sweep) used
// to read → mutate → save in parallel, so the second writer could resurrect
// the token the first writer had just deleted. JS is single-threaded but the
// awaited Teams upload PUT in handleFileConsentInvoke yields the event loop
// long enough for a sibling invoke to interleave. The mutex is per-process:
// the on-disk atomic rename in saveOutboundConsents protects against
// cross-process tearing (which shouldn't happen — STATE_DIR is per-agent —
// but is cheap defense-in-depth).
let consentMutex: Promise<void> = Promise.resolve()
async function withConsentLock<T>(fn: () => Promise<T>): Promise<T> {
  const previous = consentMutex
  let release: () => void = () => {}
  consentMutex = new Promise<void>(resolve => {
    release = resolve
  })
  await previous
  try {
    return await fn()
  } finally {
    release()
  }
}

function loadOutboundConsents(): OutboundConsentStore {
  if (!existsSync(OUTBOUND_CONSENTS_FILE)) return {}
  try {
    return JSON.parse(readFileSync(OUTBOUND_CONSENTS_FILE, 'utf8')) as OutboundConsentStore
  } catch (err) {
    // Noisy log + rename-aside rather than silent fresh-start: a malformed
    // consent file means an in-flight upload's pending record is gone, and
    // operators need to know the file was quarantined for postmortem.
    process.stderr.write(
      `teams channel: outbound-consents.json malformed, starting fresh: ${(err as Error)?.message ?? err}\n`,
    )
    try {
      // r3 fix: Date.now() (ms) can collide on simultaneous corruption
      // detections (multi-process or rapid retries within the same tick).
      // Append pid + uuid slice so each quarantine file is unique.
      const suffix = `${Date.now()}-${process.pid}-${randomUUID().slice(0, 8)}`
      renameSync(OUTBOUND_CONSENTS_FILE, `${OUTBOUND_CONSENTS_FILE}.corrupt-${suffix}`)
    } catch {}
    return {}
  }
}

function saveOutboundConsents(store: OutboundConsentStore): void {
  // saveJson already does atomic tempfile + rename with mode 0600, so this
  // delegates to the shared helper.
  saveJson(OUTBOUND_CONSENTS_FILE, store)
}

function sweepOutboundConsentsLocked(): void {
  const store = loadOutboundConsents()
  const now = Date.now()
  let mutated = false
  for (const [token, rec] of Object.entries(store)) {
    const ts = Date.parse(rec.created_at)
    if (!Number.isFinite(ts) || now - ts > OUTBOUND_CONSENT_TTL_MS) {
      delete store[token]
      mutated = true
    }
  }
  if (mutated) saveOutboundConsents(store)
}

async function sweepOutboundConsents(): Promise<void> {
  await withConsentLock(async () => {
    sweepOutboundConsentsLocked()
  })
}

async function downloadAttachments(
  activity: Activity,
  messageId: string,
): Promise<StoredAttachment[]> {
  const items = Array.isArray(activity.attachments) ? activity.attachments : []
  if (items.length === 0) return []
  const safeMessageId = sanitizeMessageId(messageId)
  const results: StoredAttachment[] = []

  // Bot Framework attachment URLs (inline paste / drag-drop images, general
  // files) require the bot's access token. The native file-picker path
  // (TEAMS_FILE_DOWNLOAD_TYPE) uses a pre-signed downloadUrl and stays
  // unauthenticated, so only fetch a token when a general-file attachment is
  // present. MicrosoftAppCredentials caches the token internally — one call
  // per activity covers every image attachment in the message. A token-fetch
  // failure logs and falls through: the affected download still lands as
  // download_status: failed with a clear download_error rather than crashing.
  let botToken: string | undefined
  const needsBotToken = items.some((a) => {
    const ct = String(a.contentType ?? '').trim()
    return ct !== TEAMS_FILE_DOWNLOAD_TYPE && isGeneralFileContentType(ct)
  })
  if (needsBotToken && APP_ID && APP_PASSWORD) {
    try {
      const creds = new MicrosoftAppCredentials(APP_ID, APP_PASSWORD, TENANT_ID || undefined)
      botToken = await creds.getToken()
    } catch (err) {
      process.stderr.write(
        `teams channel: failed to get bot token for attachment download: ${err}\n`,
      )
    }
  }

  for (let i = 0; i < items.length; i++) {
    const att = items[i]
    const rawId = String((att as any).id ?? (att as any).contentUrl ?? '').trim()
    const attachmentId = rawId || `${messageId}-${i}`
    const name = String(att.name ?? '').trim() || `attachment-${i}`
    const contentType = String(att.contentType ?? '').trim()
    const stored: StoredAttachment = {
      attachment_id: attachmentId,
      name,
      content_type: contentType,
      download_status: 'skipped_non_file',
    }
    let downloadUrl = ''
    // Only the general-file path hands streamDownload a secured Bot Framework
    // URL that needs the bot token; the file-picker path is pre-signed.
    let isGeneralFilePath = false
    if (contentType === TEAMS_FILE_DOWNLOAD_TYPE) {
      // Teams native file picker — downloadUrl lives inside content.
      const content = ((att as any).content ?? {}) as { downloadUrl?: string }
      downloadUrl = String(content.downloadUrl ?? '').trim() || String((att as any).contentUrl ?? '').trim()
    } else if (isGeneralFileContentType(contentType)) {
      isGeneralFilePath = true
      // Generic file (PDF/DOCX/octet-stream/image/etc) from drag-drop, paste,
      // or external integrations. contentUrl is the common case; fall back to
      // content.downloadUrl which some Teams clients use for drag-drop. Cards
      // and unknown types fall through to skipped_non_file (existing
      // behavior).
      const content = ((att as any).content ?? {}) as { downloadUrl?: string }
      downloadUrl = String((att as any).contentUrl ?? '').trim() || String(content.downloadUrl ?? '').trim()
    }
    if (!downloadUrl) {
      results.push(stored)
      continue
    }
    stored.download_url = downloadUrl
    if (!safeMessageId) {
      stored.download_status = 'failed'
      stored.download_error = 'rejected message id'
      results.push(stored)
      continue
    }
    const safeName = sanitizeFilename(name)
    if (!safeName) {
      stored.download_status = 'failed'
      stored.download_error = 'rejected filename'
      results.push(stored)
      continue
    }
    try {
      const dir = join(ATTACHMENTS_DIR, safeMessageId)
      mkdirSync(dir, { recursive: true, mode: 0o700 })
      const localPath = join(dir, safeName)
      const dl = await streamDownload(
        downloadUrl,
        localPath,
        ATTACHMENT_MAX_BYTES,
        isGeneralFilePath ? botToken : undefined,
      )
      if (dl.ok) {
        stored.local_path = localPath
        stored.size_bytes = dl.size
        stored.download_status = 'ok'
      } else {
        stored.download_status = 'failed'
        stored.download_error = dl.error.slice(0, 200)
      }
    } catch (err) {
      stored.download_status = 'failed'
      stored.download_error = String((err as Error)?.message ?? err).slice(0, 200)
    }
    results.push(stored)
  }
  return results
}

function runPromptGuard(command: 'scan' | 'sanitize', text: string): Record<string, unknown> | null {
  const script = join(BRIDGE_HOME, 'bridge-guard.py')
  const result = spawnSync(
    'python3',
    [script, command, '--agent', process.env.BRIDGE_AGENT_ID ?? '', '--surface', command === 'scan' ? 'channel' : 'output', '--format', 'json', text],
    { encoding: 'utf8' },
  )
  if (result.status !== 0 && !result.stdout.trim()) return null
  try {
    return JSON.parse(result.stdout)
  } catch {
    return null
  }
}

function compactMetaList(values: Array<string | undefined>): string {
  const cleaned = values
    .map(value => String(value ?? '').trim())
    .filter(value => value.length > 0)
  return cleaned.join(', ').slice(0, 1000)
}

/**
 * Claude channel notification metadata stays flat and string-only because
 * Claude Code's MCP notification handler has silently dropped notifications
 * when nested arrays/objects are present in params.meta.
 */
function buildChannelNotificationMeta(
  activity: Activity,
  stored: StoredMessage,
  attachments: StoredAttachment[],
): Record<string, string> {
  const meta: Record<string, string> = {
    source: 'teams',
    chat_id: stored.chat_id,
    conversation_id: stored.chat_id,
    message_id: stored.message_id,
    user: stored.user,
    user_id: stored.user_id,
    aad_object_id: stored.aad_object_id,
    tenant_id: String((activity.channelData as any)?.tenant?.id ?? TENANT_ID),
    service_url: String(activity.serviceUrl ?? ''),
    text: stored.text,
    ts: stored.ts,
  }
  if (stored.revision) meta.revision = stored.revision
  if (attachments.length > 0) {
    meta.attachment_count = String(attachments.length)
    const names = compactMetaList(attachments.map(att => att.name))
    const contentTypes = compactMetaList(attachments.map(att => att.content_type))
    const downloadStatuses = compactMetaList(attachments.map(att => att.download_status))
    const localPaths = compactMetaList(attachments.map(att => att.local_path))
    const downloadErrors = compactMetaList(attachments.map(att => att.download_error))
    if (names) meta.attachment_names = names
    if (contentTypes) meta.attachment_content_types = contentTypes
    if (downloadStatuses) meta.attachment_download_statuses = downloadStatuses
    if (localPaths) meta.attachment_local_paths = localPaths
    if (downloadErrors) meta.attachment_download_errors = downloadErrors
  }
  return meta
}

function recentMessages(chatId: string, limit: number): StoredMessage[] {
  if (!existsSync(MESSAGES_FILE)) return []
  const lines = readFileSync(MESSAGES_FILE, 'utf8').split('\n').filter(Boolean)
  const rows = lines
    .map(line => {
      try { return JSON.parse(line) as StoredMessage } catch { return null }
    })
    .filter((row): row is StoredMessage => Boolean(row))
    .filter(row => !chatId || row.chat_id === chatId)
  return rows.slice(-Math.max(1, Math.min(limit, 100)))
}

/**
 * Derive a Teams service URL for proactive sends. The service URL is tenant-
 * and region-specific (e.g. https://smba.trafficmanager.net/amer/). We obtain
 * it in preference order:
 *   1. TEAMS_SERVICE_URL env var (operator override for multi-region setups).
 *   2. serviceUrl from any stored ConversationReference (populated after the
 *      first inbound message from a user).
 *   3. Hard-coded global Teams endpoint as a last resort.
 */
function resolveServiceUrl(): string {
  const override = process.env.TEAMS_SERVICE_URL
  if (override && /^https?:\/\//.test(override)) return override.replace(/\/$/, '') + '/'
  const refs = loadJson<Record<string, ConversationReference>>(REFERENCES_FILE, {})
  for (const ref of Object.values(refs)) {
    if (ref.serviceUrl) return ref.serviceUrl.replace(/\/$/, '') + '/'
  }
  // Global Teams endpoint -- works for most commercial tenants.
  return 'https://smba.trafficmanager.net/amer/'
}

/**
 * Proactive 1:1 send via Bot Framework createConversation.
 *
 * Creates a new 1:1 conversation with the target Teams user (identified by
 * their Teams user ID or AAD object ID) and posts the message. If a stored
 * ConversationReference already exists for a past conversation with this user
 * we skip createConversation and reuse the existing reference -- this is
 * faster and avoids duplicate conversations.
 *
 * Returns a result object with `ok`, `conversation_id`, `message_id`, and
 * `error` fields. Never throws -- all Bot Framework errors are caught and
 * mapped to the error envelope so the agent can report them clearly.
 */
async function sendMessageProactive(
  targetId: string,
  text: string,
): Promise<{ ok: boolean; conversation_id: string; message_id: string; error?: string }> {
  // Fast path: if we already have a ConversationReference for a conversation
  // where this user was the "from" party, reuse it.
  const refs = loadJson<Record<string, ConversationReference>>(REFERENCES_FILE, {})
  let existingRef: ConversationReference | undefined
  for (const ref of Object.values(refs)) {
    const refFrom = (ref as any).user ?? ref.from
    if (!refFrom) continue
    const refAad = String((refFrom as any).aadObjectId ?? '').trim()
    const refId = String((refFrom as any).id ?? refFrom?.id ?? '').trim()
    if ((refAad && refAad === targetId) || (refId && refId === targetId)) {
      existingRef = ref
      break
    }
  }

  if (existingRef) {
    let sentId = ''
    try {
      await adapter.continueConversation(existingRef, async context => {
        const sent = await context.sendActivity(text)
        sentId = (sent as any)?.id ?? ''
      })
      return { ok: true, conversation_id: String((existingRef as any).conversation?.id ?? ''), message_id: sentId }
    } catch (err) {
      return { ok: false, conversation_id: '', message_id: '', error: String((err as Error)?.message ?? err) }
    }
  }

  // Cold path: no stored reference -- initiate via createConversation.
  const serviceUrl = resolveServiceUrl()
  let creds: MicrosoftAppCredentials
  try {
    creds = new MicrosoftAppCredentials(APP_ID!, APP_PASSWORD!, TENANT_ID || undefined)
  } catch (err) {
    return { ok: false, conversation_id: '', message_id: '', error: `credentials_error: ${(err as Error)?.message ?? err}` }
  }

  let client: ConnectorClient
  try {
    client = new ConnectorClient(creds, { baseUri: serviceUrl })
  } catch (err) {
    return { ok: false, conversation_id: '', message_id: '', error: `connector_error: ${(err as Error)?.message ?? err}` }
  }

  const params = {
    isGroup: false,
    bot: { id: APP_ID!, name: 'Bot' },
    members: [{ id: targetId, name: '' }],
    ...(TENANT_ID ? { tenantId: TENANT_ID, channelData: { tenant: { id: TENANT_ID } } } : { channelData: {} }),
  }

  let conversationId = ''
  let messageId = ''
  try {
    const result = await client.conversations.createConversation(params as any)
    conversationId = String((result as any).id ?? '').trim()
    if (!conversationId) {
      return { ok: false, conversation_id: '', message_id: '', error: 'createConversation returned no conversation id' }
    }
    const sendResult = await client.conversations.sendToConversation(
      conversationId,
      { type: 'message', text } as any,
    )
    messageId = String((sendResult as any)?.id ?? '').trim()
    return { ok: true, conversation_id: conversationId, message_id: messageId }
  } catch (err) {
    const msg = String((err as Error)?.message ?? err)
    // Surface Bot Framework error codes as actionable hints.
    let error = `bot_framework_error: ${msg}`
    if (/403|forbidden|not authorized/i.test(msg)) {
      error = `bot_not_installed_or_auth_failed: ${msg} -- ensure the bot app is installed in the target user's Teams personal scope, and that TEAMS_APP_ID / TEAMS_APP_PASSWORD / TEAMS_TENANT_ID match the Azure Bot registration`
    } else if (/404|not found/i.test(msg)) {
      error = `user_not_found: ${msg} -- confirm the target user id is the correct AAD object id or Teams user id for this tenant`
    }
    return { ok: false, conversation_id: conversationId, message_id: '', error }
  }
}

/**
 * Send a Teams file consent card for one outbound file. Teams renders a card
 * in the conversation; when the user clicks Accept, the bot receives a
 * `fileConsent/invoke` activity with an upload URL. The bot PUTs file bytes
 * to that URL, then posts a fileInfo card so the user can open the upload.
 *
 * We store a record keyed by a server-generated token in the acceptContext;
 * the invoke handler looks the token up to find the abs_path on disk.
 * Persisting through STATE_DIR means a plugin restart between the consent
 * card send and the user accept doesn't strand the upload.
 *
 * `text` is only sent on the first card (per-message) so the user sees the
 * agent's message once, not repeated per attachment. The caller is
 * responsible for passing '' on subsequent attachments in the same message.
 */
async function sendFileConsentCard(
  ref: ConversationReference,
  chatId: string,
  absPath: string,
  displayName: string,
  size: number,
  contentType: string,
  agentMessage: string,
): Promise<string> {
  const token = randomUUID()
  const refUserAad = String((ref as any).user?.aadObjectId ?? '').trim()
  // INVARIANT: callers pass the realpath-resolved absPath so the record pins
  // the consent to a specific inode chain (the validation site in
  // call_tool/reply replaces the raw user-supplied path with realpathSync's
  // result before invoking us). handleFileConsentInvoke re-validates the
  // stored path at upload time to catch any swap during the send→accept
  // window — see r3 (P1 BLOCKING) fix.
  const record: OutboundConsentRecord = {
    abs_path: absPath,
    display_name: displayName,
    size,
    content_type: contentType,
    agent_message: agentMessage,
    created_at: new Date().toISOString(),
    conversation_id: String((ref as any).conversation?.id ?? ''),
    chat_id: chatId,
    ...(refUserAad ? { aad_object_id: refUserAad } : {}),
  }
  await withConsentLock(async () => {
    const store = loadOutboundConsents()
    store[token] = record
    saveOutboundConsents(store)
  })

  await adapter.continueConversation(ref, async context => {
    const consentAttachment = {
      contentType: TEAMS_FILE_CONSENT_CARD_TYPE,
      name: displayName,
      content: {
        description: agentMessage || `File from Agent Bridge: ${displayName}`,
        sizeInBytes: size,
        acceptContext: { token },
        declineContext: { token },
      },
    }
    const activity: Partial<Activity> = {
      type: ActivityTypes.Message,
      attachments: [consentAttachment as any],
    }
    if (agentMessage) {
      activity.text = agentMessage
    }
    await context.sendActivity(activity)
  })

  return token
}

/**
 * Handle a `fileConsent/invoke` activity from Teams. The activity.value is a
 * FileConsentCardResponse: action (accept/decline), context (our token), and
 * — on accept — uploadInfo with uploadUrl. On accept we PUT the file bytes
 * to the upload URL, then post a follow-up message with a fileInfo card
 * pointing at the uploaded blob. On decline we drop the pending record and
 * post a small text reply.
 *
 * Returns an InvokeResponse status to be cached on context.turnState so
 * BotFrameworkAdapter.processActivity can write it back to Teams. Any error
 * is logged and surfaced as status=500 — Teams will not retry consent
 * invokes; the consent card stays clickable until it expires.
 */
async function handleFileConsentInvoke(context: TurnContext): Promise<void> {
  const activity = context.activity
  const value = ((activity as any).value ?? {}) as {
    action?: string
    context?: { token?: string }
    uploadInfo?: {
      uploadUrl?: string
      contentUrl?: string
      uniqueId?: string
      name?: string
      fileType?: string
    }
  }
  const action = String(value.action ?? '').trim()
  const token = String(value.context?.token ?? '').trim()
  const invokeConvId = String(activity.conversation?.id ?? '').trim()
  const invokeAad = String((activity.from as any)?.aadObjectId ?? '').trim()

  // Tell BotFrameworkAdapter the invoke status to write back. Status 200 +
  // empty body is the Bot Framework convention for "consent handled".
  const sendInvokeStatus = async (status: number) => {
    await context.sendActivity({
      type: 'invokeResponse',
      value: { status, body: {} },
    } as any)
  }

  // Look up the record under the lock. If the conversation id (or aadObjectId,
  // when present on both sides) doesn't match what we recorded when the consent
  // card was sent, treat the token as compromised: drop it and decline. The
  // token is an unguessable uuid, but binding it to the conversation prevents
  // a leaked token from being replayed in a different chat.
  //
  // r3 (P1 BLOCKING + P2): under the same lock we ALSO re-validate the stored
  // path (lstat + realpath + containment + size equality) and reserve the
  // token by deleting it BEFORE releasing the lock for the PUT. Reservation
  // closes the second-accept race against the single-use Teams upload URL;
  // re-validation closes the consent-send→accept TOCTOU symlink-swap window.
  // Bytes are read inside the lock too so a path swap can't race the read.
  type LockedAccept = { kind: 'ok'; record: OutboundConsentRecord; bytes: Buffer }
  type LockedReject = { kind: 'reject'; status: number; reason: string }
  type LockedNone = undefined
  const handled = await withConsentLock(async (): Promise<LockedAccept | LockedReject | LockedNone> => {
    const store = loadOutboundConsents()
    const rec = token ? store[token] : undefined
    if (!rec) return undefined
    if (rec.conversation_id && invokeConvId && invokeConvId !== rec.conversation_id) {
      process.stderr.write(
        `teams channel: fileConsent conversation mismatch token=${token} ` +
          `invoke=${invokeConvId} stored=${rec.conversation_id}\n`,
      )
      delete store[token]
      saveOutboundConsents(store)
      return undefined
    }
    const storedAad = String((rec as any).aad_object_id ?? '').trim()
    if (storedAad && invokeAad) {
      if (storedAad !== invokeAad) {
        process.stderr.write(
          `teams channel: fileConsent aad mismatch token=${token} ` +
            `invoke=${invokeAad} stored=${storedAad}\n`,
        )
        delete store[token]
        saveOutboundConsents(store)
        return undefined
      }
    } else if (storedAad || invokeAad) {
      // r3 fix (NOTE #2): don't silently degrade — record the asymmetry so an
      // operator notices if Teams stops sending aadObjectId on invokes (which
      // would otherwise downgrade every check to conversation-only binding).
      process.stderr.write(
        `teams channel: fileConsent aadObjectId bind asymmetric token=${token} ` +
          `stored=${storedAad ? 'present' : 'absent'} invoke=${invokeAad ? 'present' : 'absent'}; ` +
          `proceeding with conversation-only bind\n`,
      )
    }

    // Accept-action specific work (re-validate + reserve). Decline and other
    // actions take the existing fast path outside the lock so we don't block
    // the mutex on path I/O for non-upload flows.
    if (action !== 'accept') {
      return { kind: 'ok', record: rec, bytes: Buffer.alloc(0) }
    }

    // r3 (P1 BLOCKING): re-run lstat + realpath + containment + size equality
    // against the STORED abs_path. The stored path was already realpath-pinned
    // at consent-send time (see sendFileConsentCard caller), but the inode
    // chain can still be swapped under us during the send→accept window. We
    // refuse on any of: lstat-is-symlink, realpath change, containment break,
    // size drift, not-a-file.
    let allowRootReal: string
    try {
      allowRootReal = resolveOutboundAllowRoot()
    } catch (err) {
      process.stderr.write(
        `teams channel: fileConsent allow-root resolve failed token=${token}: ${(err as Error)?.message ?? err}\n`,
      )
      delete store[token]
      saveOutboundConsents(store)
      return { kind: 'reject', status: 500, reason: 'allow-root unresolved' }
    }

    let nowReal: string
    try {
      const linkStat = lstatSync(rec.abs_path)
      if (linkStat.isSymbolicLink()) {
        process.stderr.write(
          `teams channel: fileConsent upload-time symlink detected token=${token} path=${rec.abs_path}\n`,
        )
        delete store[token]
        saveOutboundConsents(store)
        return { kind: 'reject', status: 404, reason: 'symlink swap' }
      }
      nowReal = realpathSync(rec.abs_path)
    } catch (err) {
      process.stderr.write(
        `teams channel: fileConsent upload-time path resolve failed token=${token}: ${(err as Error)?.message ?? err}\n`,
      )
      delete store[token]
      saveOutboundConsents(store)
      return { kind: 'reject', status: 404, reason: 'path unresolved' }
    }

    if (nowReal !== allowRootReal && !nowReal.startsWith(allowRootReal + '/')) {
      process.stderr.write(
        `teams channel: fileConsent upload-time path escaped allow root token=${token} ` +
          `path=${nowReal} root=${allowRootReal}\n`,
      )
      delete store[token]
      saveOutboundConsents(store)
      return { kind: 'reject', status: 404, reason: 'escaped allow root' }
    }

    let stat
    try {
      stat = statSync(nowReal)
    } catch (err) {
      process.stderr.write(
        `teams channel: fileConsent upload-time stat failed token=${token}: ${(err as Error)?.message ?? err}\n`,
      )
      delete store[token]
      saveOutboundConsents(store)
      return { kind: 'reject', status: 404, reason: 'stat failed' }
    }
    if (!stat.isFile()) {
      process.stderr.write(
        `teams channel: fileConsent upload-time path is not a regular file token=${token} path=${nowReal}\n`,
      )
      delete store[token]
      saveOutboundConsents(store)
      return { kind: 'reject', status: 404, reason: 'not a regular file' }
    }
    if (stat.size !== rec.size) {
      // r3: size drift now refuses (was a warning). A change in size between
      // consent and accept is also a swap signal — fail closed.
      process.stderr.write(
        `teams channel: fileConsent size drift token=${token} stored=${rec.size} actual=${stat.size}; refusing\n`,
      )
      delete store[token]
      saveOutboundConsents(store)
      return { kind: 'reject', status: 404, reason: 'size drift' }
    }

    let bytes: Buffer
    try {
      bytes = readFileSync(nowReal)
    } catch (err) {
      process.stderr.write(
        `teams channel: fileConsent upload-time read failed token=${token}: ${(err as Error)?.message ?? err}\n`,
      )
      delete store[token]
      saveOutboundConsents(store)
      return { kind: 'reject', status: 500, reason: 'read failed' }
    }

    // r3 (P2): reserve the token by deleting it INSIDE the lock before the
    // PUT runs. A concurrent accept replay will now 404 on the lookup above
    // rather than racing the consumed Teams upload URL with a second PUT.
    // Failure of the PUT does NOT restore the record (the upload URL is
    // single-use, so a retry would 4xx at Teams anyway).
    delete store[token]
    saveOutboundConsents(store)
    return { kind: 'ok', record: rec, bytes }
  })

  if (!handled) {
    process.stderr.write(`teams channel: fileConsent invoke for unknown token=${token}\n`)
    await sendInvokeStatus(404)
    return
  }
  if (handled.kind === 'reject') {
    try {
      await context.sendActivity(`File delivery failed: ${handled.reason}`)
    } catch {}
    await sendInvokeStatus(handled.status)
    return
  }

  const record = handled.record
  const bytes = handled.bytes

  if (action === 'decline') {
    await withConsentLock(async () => {
      const store = loadOutboundConsents()
      delete store[token]
      saveOutboundConsents(store)
    })
    try {
      await context.sendActivity(`File delivery declined: ${record.display_name}`)
    } catch (err) {
      process.stderr.write(`teams channel: decline reply failed: ${err}\n`)
    }
    await sendInvokeStatus(200)
    return
  }

  if (action !== 'accept') {
    process.stderr.write(`teams channel: fileConsent unknown action=${action}\n`)
    await sendInvokeStatus(400)
    return
  }

  const uploadUrl = String(value.uploadInfo?.uploadUrl ?? '').trim()
  if (!uploadUrl) {
    process.stderr.write(`teams channel: fileConsent accept missing uploadUrl token=${token}\n`)
    // Record is already consumed; nothing to clean up.
    await sendInvokeStatus(400)
    return
  }

  // Teams upload protocol: PUT with Content-Range covering the whole file.
  // For a single-chunk upload the range is `bytes 0-(size-1)/size`. The PUT
  // intentionally runs OUTSIDE the consent lock so a slow upload doesn't
  // serialize sibling invokes in the same process.
  const last = Math.max(0, bytes.byteLength - 1)
  const contentRange = `bytes 0-${last}/${bytes.byteLength}`
  let uploadOk = false
  let uploadErr = ''
  try {
    // Bun's fetch accepts Buffer as body; cast to keep strict tsc happy
    // (DOM lib BodyInit doesn't list Node Buffer).
    const resp = await fetch(uploadUrl, {
      method: 'PUT',
      headers: {
        'Content-Length': String(bytes.byteLength),
        'Content-Range': contentRange,
      },
      body: bytes as unknown as BodyInit,
    })
    uploadOk = resp.ok
    if (!uploadOk) uploadErr = `HTTP ${resp.status}`
  } catch (err) {
    uploadErr = String((err as Error)?.message ?? err)
  }

  if (!uploadOk) {
    // Token was already reserved (deleted) inside the consent lock — a retry
    // 404s rather than re-PUTting against the now-consumed upload URL. See
    // r3 (P2) note on handleFileConsentInvoke.
    process.stderr.write(`teams channel: fileConsent upload failed token=${token}: ${uploadErr}\n`)
    try {
      await context.sendActivity(`File upload failed: ${record.display_name}`)
    } catch {}
    await sendInvokeStatus(502)
    return
  }

  // Post a FileInfoCard so the user gets a clickable link to the uploaded
  // file. Best-effort: a posting failure after a successful upload still
  // counts as success — the file is in the user's OneDrive.
  try {
    const fileInfoAttachment = {
      contentType: TEAMS_FILE_INFO_CARD_TYPE,
      name: record.display_name,
      contentUrl: value.uploadInfo?.contentUrl,
      content: {
        uniqueId: value.uploadInfo?.uniqueId,
        fileType: value.uploadInfo?.fileType,
      },
    }
    await context.sendActivity({
      type: ActivityTypes.Message,
      attachments: [fileInfoAttachment as any],
    } as Partial<Activity>)
  } catch (err) {
    process.stderr.write(`teams channel: fileInfo post failed (upload succeeded): ${err}\n`)
  }

  // Token already reserved (deleted) inside the consent lock — no cleanup needed.
  await sendInvokeStatus(200)
}

const adapter = new BotFrameworkAdapter({
  appId: APP_ID,
  appPassword: APP_PASSWORD,
  channelAuthTenant: TENANT_ID || undefined,
})
const recentMessageIds = createRecentMessageDeduper(256)
let duplicateDropLogs = 0

// dedupeKey: chat scopes the id (Teams reuses message ids across conversations
// for thread replies); revision distinguishes edits — Teams keeps the same
// activity.id when a user edits a message but bumps localTimestamp/timestamp,
// so including the revision lets edits through while still dropping pure
// retransmits of the original payload.
function dedupeKey(chatId: string, messageId: string, revision: string): string {
  return revision ? `${chatId}::${messageId}::${revision}` : `${chatId}::${messageId}`
}

function logDuplicateDrop(chatId: string, messageId: string): void {
  if (duplicateDropLogs >= 10) return
  process.stderr.write(`teams channel: dropped duplicate chat_id=${chatId} message_id=${messageId}\n`)
  duplicateDropLogs += 1
}

// Issue #1313 (CRITICAL data-loss): the prior catch block called
// `recentMessageIds.forget(dedupeKey(...))` on mcp.notification failure and
// re-threw. The intent was "let Teams retry the webhook", but the side
// effect was:
//   1. dedup state for the in-flight message is dropped,
//   2. Teams retries the webhook,
//   3. the retry passes the in-memory dedup check (now empty) and the
//      log-replay dedup (no row yet — appendMessage runs *after* the
//      MCP notification),
//   4. MCP notification is attempted again. If MCP is still degraded,
//      the same failure repeats and Claude never receives the message.
//   5. Worse: a transient MCP hiccup that recovers between Teams retries
//      can yield N notifications for the same message (the "log silently
//      lost" symptom from the patch C7 audit).
//
// Fix (Option 1 — internal retry, dedup-preserving):
//   - Try the MCP notification up to MCP_NOTIFICATION_MAX_ATTEMPTS times
//     with exponential backoff (base MCP_NOTIFICATION_BACKOFF_MS, doubling
//     per attempt, jitter-free for predictability under smoke harness).
//   - If a retry succeeds, behaviour is identical to a first-try success.
//   - If all attempts fail, emit a structured audit line to stderr
//     (teams_mcp_notification_failed_permanent) so the operator's daemon
//     log scraper can escalate to an admin task. Then SWALLOW the error:
//     returning 2xx to Teams stops Bot Framework from re-driving the same
//     webhook against a degraded MCP transport (which would loop with no
//     net progress). The dedup entry is preserved on every code path so
//     a Teams retry that does sneak through is dropped cleanly.
//
// Edge cases (per #1313 brief):
//   - Genuine new message vs Teams retry: dedupeKey() composes chat_id +
//     message_id + revision (line 1587). A genuine new message has a new
//     message_id or bumped revision, so it gets a fresh entry. A retry of
//     the same activity collides on the same key — dropped at the seen()
//     check above the try block.
//   - Race (two concurrent inbound webhooks for the same activity.id):
//     recentMessageIds.seen() is a Set+Queue Set.has check; the first
//     caller wins, the second sees true and drops. No double-deliver.
//   - MCP recovers mid-retry: attempt 2 succeeds → audit row not emitted,
//     dedup stays, normal success path resumes.
//   - Claude Code restart between Teams send + MCP retry: the StdioServer
//     transport will fail every attempt; the audit row records the
//     permanent failure. dedup stays — once Claude reconnects the next
//     fresh Teams message flows through, no replay of the lost message
//     (that's a separate persistence concern, tracked in the issue body).
//   - Perma-down (MCP transport gone): all attempts fail → one audit row
//     per failed message; Teams stops retrying (we return 2xx); admin
//     sees the audit lines accumulate.
//
// The helper is exported for the `_smoke-mcp-retry` harness so the smoke
// can exercise the retry-and-give-up shape without spinning up a real
// MCP transport.
const MCP_NOTIFICATION_MAX_ATTEMPTS = 3
const MCP_NOTIFICATION_BACKOFF_MS = 100

export type DeliverNotificationResult = {
  delivered: boolean
  attempts: number
  errors: string[]
}

/**
 * Deliver an MCP notification with bounded retry-and-backoff.
 *
 * @param send    closure that performs the actual `mcp.notification(...)`
 *                call. Returns void on success, throws on failure.
 * @param sleep   injectable async sleep — tests pass a no-op so the
 *                harness completes in ms instead of seconds.
 * @param opts    override the default attempt count / backoff base.
 *
 * Contract: `delivered: true` means at least one attempt resolved with
 * no thrown error. `delivered: false` means every attempt threw; the
 * caller is responsible for the perma-fail audit + swallow decision.
 * The function never throws.
 */
export async function deliverMcpNotificationWithRetry(
  send: () => Promise<void>,
  sleep: (ms: number) => Promise<void> = ms => new Promise(resolve => setTimeout(resolve, ms)),
  opts: { maxAttempts?: number; backoffMs?: number } = {},
): Promise<DeliverNotificationResult> {
  const maxAttempts = Number.isFinite(opts.maxAttempts) && (opts.maxAttempts ?? 0) > 0
    ? Math.floor(opts.maxAttempts ?? 0)
    : MCP_NOTIFICATION_MAX_ATTEMPTS
  const backoffMs = Number.isFinite(opts.backoffMs) && (opts.backoffMs ?? -1) >= 0
    ? Math.floor(opts.backoffMs ?? 0)
    : MCP_NOTIFICATION_BACKOFF_MS
  const errors: string[] = []
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      await send()
      return { delivered: true, attempts: attempt, errors }
    } catch (err) {
      errors.push(String(err))
      if (attempt < maxAttempts) {
        // Exponential backoff: attempt 1 → backoffMs, 2 → 2*backoffMs, …
        await sleep(backoffMs * Math.pow(2, attempt - 1))
      }
    }
  }
  return { delivered: false, attempts: maxAttempts, errors }
}

/**
 * Resolve the absolute path to `bridge-task.sh`. Mirrors the pattern in
 * `bridge-memory.py` (BRIDGE_HOME-relative). `BRIDGE_SCRIPT_DIR` takes
 * precedence when set (the daemon exports it on every isolated runner);
 * otherwise we fall back to `BRIDGE_HOME` → `${HOME}/.agent-bridge`.
 *
 * Returns the resolved path even if the file does not exist on disk —
 * the caller checks `existsSync` before spawning so the audit-row says
 * `bridge_task_not_found` instead of crashing the plugin.
 */
function resolveBridgeTaskPath(): string {
  const scriptDir = (process.env.BRIDGE_SCRIPT_DIR ?? '').trim()
  if (scriptDir) {
    return join(scriptDir, 'bridge-task.sh')
  }
  const bridgeHome = (process.env.BRIDGE_HOME ?? '').trim() || join(homedir(), '.agent-bridge')
  return join(bridgeHome, 'bridge-task.sh')
}

/**
 * Emit a structured permanent-failure audit line for an MCP notification
 * that exhausted all retries, and queue an admin escalation task so the
 * operator gets a durable, queue-tracked signal (not just a stderr line).
 *
 * Stderr line — operator log breadcrumb, grep-friendly:
 *
 *   teams channel: teams_mcp_notification_failed_permanent message_id=<id> chat_id=<id> attempts=<n> last_error=<text>
 *
 * Admin task — canonical operator signal. Created via the EXISTING
 * `bridge-task.sh create` boundary (queue-first contract, CLAUDE.md
 * §"Queue-First Is a Contract"). Routed to `$BRIDGE_ADMIN_AGENT_ID`
 * with priority `high`. The task body carries the same fields as the
 * stderr line plus a one-line operator action hint.
 *
 * Fallback ladder (each step writes its own stderr audit so the
 * operator log shows WHY the queue task was skipped):
 *
 *   1. BRIDGE_ADMIN_AGENT_ID unset → stderr-only, audit reason
 *      `admin_task_skipped reason=no_admin_configured`.
 *   2. bridge-task.sh path missing → stderr-only, audit reason
 *      `admin_task_skipped reason=bridge_task_not_found path=<resolved>`.
 *   3. spawnSync nonzero exit → audit `admin_task_failed status=<n>
 *      stderr=<truncated>`.
 *   4. spawnSync throws (ENOENT, EACCES, …) → audit
 *      `admin_task_exception err=<truncated>`.
 *
 * The function never throws — Teams webhook ack must not be blocked by
 * a queue-create error. spawnSync timeout is 2000ms to bound the
 * webhook-side latency hit (issue #1336 R2 brief edge-case #3).
 *
 * Exported for the `_smoke-mcp-retry` harness.
 */
export function emitMcpDeliveryFailurePermanent(
  chatId: string,
  messageId: string,
  attempts: number,
  errors: string[],
): void {
  const lastError = errors.length > 0 ? errors[errors.length - 1] : ''
  // One-liner: keep grep-greppable; collapse newlines in the error to
  // keep the audit row on a single line (downstream log parsers split
  // on `\n`).
  const sanitizedError = String(lastError).replace(/[\r\n]+/g, ' ').slice(0, 512)
  process.stderr.write(
    `teams channel: teams_mcp_notification_failed_permanent`
      + ` message_id=${messageId}`
      + ` chat_id=${chatId}`
      + ` attempts=${attempts}`
      + ` last_error=${sanitizedError}\n`,
  )

  // Admin task escalation — queue-first canonical operator signal.
  const adminAgent = (process.env.BRIDGE_ADMIN_AGENT_ID ?? '').trim()
  if (!adminAgent) {
    process.stderr.write(
      `teams channel: teams_mcp_perma_fail_admin_task_skipped`
        + ` reason=no_admin_configured`
        + ` message_id=${messageId}\n`,
    )
    return
  }
  const taskCli = resolveBridgeTaskPath()
  if (!existsSync(taskCli)) {
    process.stderr.write(
      `teams channel: teams_mcp_perma_fail_admin_task_skipped`
        + ` reason=bridge_task_not_found`
        + ` path=${taskCli}`
        + ` message_id=${messageId}\n`,
    )
    return
  }
  const taskTitle = `[teams-mcp-perma-fail] message ${messageId} undelivered after ${attempts} retries`
  const taskBody = [
    `Teams MCP notification failed permanently after ${attempts} retries.`,
    ``,
    `message_id: ${messageId}`,
    `chat_id: ${chatId}`,
    `attempts: ${attempts}`,
    `last_error: ${sanitizedError}`,
    ``,
    `Operator action: inspect Teams channel + Claude session state.`,
    `Manual re-deliver may be required. The dedup entry was preserved`,
    `(beta5-2 Lane ζ contract) so a re-driven webhook will not re-fire.`,
  ].join('\n')
  try {
    const result = spawnSync(
      'bash',
      [
        taskCli,
        'create',
        '--to', adminAgent,
        '--title', taskTitle,
        '--body', taskBody,
        '--priority', 'high',
      ],
      {
        stdio: ['ignore', 'pipe', 'pipe'],
        timeout: 2000,
        encoding: 'utf8',
      },
    )
    if (result.error) {
      const errText = String(result.error).replace(/[\r\n]+/g, ' ').slice(0, 256)
      process.stderr.write(
        `teams channel: teams_mcp_perma_fail_admin_task_exception`
          + ` err=${errText}`
          + ` message_id=${messageId}\n`,
      )
      return
    }
    if (result.status !== 0) {
      const stderrText = String(result.stderr ?? '').replace(/[\r\n]+/g, ' ').slice(0, 256)
      process.stderr.write(
        `teams channel: teams_mcp_perma_fail_admin_task_failed`
          + ` status=${result.status}`
          + ` stderr=${stderrText}`
          + ` message_id=${messageId}\n`,
      )
      return
    }
    process.stderr.write(
      `teams channel: teams_mcp_perma_fail_admin_task_created`
        + ` admin=${adminAgent}`
        + ` message_id=${messageId}\n`,
    )
  } catch (err) {
    const errText = String(err).replace(/[\r\n]+/g, ' ').slice(0, 256)
    process.stderr.write(
      `teams channel: teams_mcp_perma_fail_admin_task_exception`
        + ` err=${errText}`
        + ` message_id=${messageId}\n`,
    )
  }
}

const mcp = new Server(
  { name: 'teams', version: '0.1.0' },
  {
    capabilities: {
      tools: {},
      experimental: {
        'claude/channel': {},
        'claude/channel/permission': {},
      },
    },
    instructions: [
      'Microsoft Teams channel for Claude Code.',
      'Messages from Teams arrive as <channel source="teams" chat_id="..." message_id="..." user="..." ts="...">.',
      'Anything the Teams user should see must be sent with the reply tool. Terminal transcript output is not delivered to Teams.',
      'Pass chat_id from the inbound message to reply. Use fetch_messages for recent local message context.',
    ].join('\n'),
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description:
        'Reply to a Teams conversation. Optionally attach general files (personal chats only — group/channel returns attachments_not_supported_in_groupchat).',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string', description: 'Teams conversation id from inbound meta.chat_id.' },
          text: { type: 'string', description: 'Message text to send.' },
          attachments: {
            type: 'array',
            description:
              'Optional file attachments. Personal chats only (Phase 1). Cards rejected. Max 10 per message. Each path must be absolute and within TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT (default: $TEAMS_STATE_DIR/outbound).',
            items: {
              type: 'object',
              properties: {
                path: {
                  type: 'string',
                  description:
                    'Absolute path to file (must be within TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT, regular file).',
                },
                name: {
                  type: 'string',
                  description: 'Optional display name shown in Teams; defaults to basename(path).',
                },
              },
              required: ['path'],
            },
            maxItems: OUTBOUND_MAX_ATTACHMENTS_PER_MESSAGE,
          },
        },
        required: ['chat_id'],
      },
    },
    {
      name: 'fetch_messages',
      description: 'Fetch recent Teams messages captured by this plugin from the local rolling log.',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string', description: 'Optional Teams conversation id.' },
          limit: { type: 'number', description: 'Maximum number of messages, default 20, max 100.' },
        },
      },
    },
    {
      name: 'send_message',
      description:
        'Proactively send a 1:1 Teams message to an allowlisted user without requiring an inbound message first. ' +
        'Uses the Bot Framework createConversation pattern when no stored conversation reference exists. ' +
        'The target user must appear in the access.json allowFrom list. ' +
        "Requires the bot app to be installed in the target user's Teams personal scope.",
      inputSchema: {
        type: 'object',
        properties: {
          to: {
            type: 'string',
            description:
              'AAD object ID or Teams user ID of the target user. Must match an entry in access.json allowFrom.',
          },
          text: {
            type: 'string',
            description: 'Message text to send.',
          },
        },
        required: ['to', 'text'],
      },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const args = (req.params.arguments ?? {}) as Record<string, unknown>
  switch (req.params.name) {
    case 'reply': {
      const chatId = String(args.chat_id ?? '').trim()
      let text = String(args.text ?? '').trim()
      const attachmentsArg = Array.isArray(args.attachments) ? args.attachments : []
      if (!chatId) throw new Error('chat_id is required')
      if (!text && attachmentsArg.length === 0) {
        throw new Error('text or attachments is required')
      }
      if (attachmentsArg.length > OUTBOUND_MAX_ATTACHMENTS_PER_MESSAGE) {
        throw new Error(
          `too many attachments: ${attachmentsArg.length} > ${OUTBOUND_MAX_ATTACHMENTS_PER_MESSAGE}`,
        )
      }
      if (text) {
        const guarded = runPromptGuard('sanitize', text)
        if (guarded?.blocked) {
          text = '[Agent Bridge] outbound reply blocked by prompt guard.'
        } else if (guarded?.was_modified && typeof guarded.sanitized_text === 'string') {
          text = guarded.sanitized_text
        }
      }
      const refs = loadJson<Record<string, ConversationReference>>(REFERENCES_FILE, {})
      const ref = refs[chatId]
      if (!ref) {
        throw new Error(
          `conversation reference not found for ${chatId}; wait for an inbound Teams message first`,
        )
      }

      if (attachmentsArg.length === 0) {
        // Text-only path. ADDITIVE Adaptive Card seam (Model B): if the turn
        // text carries a ```cardintent fence, renderOutbound strips it and
        // returns an Adaptive Card attachment to dual-send alongside the
        // human-readable summary. When there's no fence (or any render/
        // validation/§10 failure) renderOutbound returns the text with NO
        // attachments and this path is byte-for-byte the prior behavior.
        // renderOutbound never throws.
        const rendered = renderOutbound(text)
        if (rendered.warning) {
          process.stderr.write(`teams channel: cardintent fallback: ${rendered.warning}\n`)
        }
        await adapter.continueConversation(ref, async context => {
          if (rendered.attachments.length > 0) {
            await context.sendActivity({
              type: ActivityTypes.Message,
              text: rendered.text,
              attachments: rendered.attachments as any,
            })
          } else {
            // Unchanged plain-string send (preserves the prior wire shape when
            // no card is produced).
            await context.sendActivity(rendered.text)
          }
        })
        return { content: [{ type: 'text', text: `sent: ${chatId}` }] }
      }

      // Attachment path. Phase 1 supports personal chats only — group/channel
      // outbound files require SharePoint upload and are deferred to Phase 2.
      const conversationType = String((ref as any).conversation?.conversationType ?? '').trim()
      if (conversationType !== 'personal') {
        throw new Error(
          `attachments_not_supported_in_groupchat: outbound files only supported in personal chats ` +
            `(conversationType=${conversationType || 'unknown'})`,
        )
      }

      // Validate each attachment up front before sending any consent cards so a
      // single bad path doesn't leave half the files in pending consent state.
      const allowRoot = resolveOutboundAllowRoot()
      // realpath the allow root once: if the root itself is a symlink chain we
      // need to compare resolved-to-resolved. resolveOutboundAllowRoot mkdirs
      // the root, so this should always succeed; on failure fall back to the
      // raw root and let the per-path check below reject anything outside it.
      let allowRootReal: string
      try {
        allowRootReal = realpathSync(allowRoot)
      } catch {
        allowRootReal = allowRoot
      }
      const maxBytes = resolveOutboundMaxBytes()
      const validated: {
        absPath: string
        displayName: string
        size: number
        contentType: string
      }[] = []
      for (const item of attachmentsArg) {
        const rawPath = String((item as any)?.path ?? '').trim()
        if (!rawPath) throw new Error('attachment.path is required')
        if (!pathIsAbsolute(rawPath)) {
          throw new Error(`attachment.path must be absolute: ${rawPath}`)
        }
        const absPath = pathResolve(rawPath)
        // Reject symlinks outright before realpath: the supplied path must
        // point directly at a regular file. A symlink whose TARGET is inside
        // the allow root would pass realpath containment but is a more
        // surprising input vector than necessary — and a symlink whose target
        // moves between lstat and read is a TOCTOU primitive we don't need to
        // accept. lstat (NOT stat) so we see the link itself, not its target.
        let lstat
        try {
          lstat = lstatSync(absPath)
        } catch (err) {
          throw new Error(`attachment.path not found: ${absPath} (${(err as Error).message})`)
        }
        if (lstat.isSymbolicLink()) {
          throw new Error(`attachment.path must not be a symlink: ${absPath}`)
        }
        // Containment via realpath: resolve the full chain (including any
        // symlinks in PARENT directories) and compare against the realpath of
        // the allow root. This closes the symlink-escape hole left by the
        // pre-realpath pathResolve.startsWith check, where a malicious entry
        // inside the allow root could point at /etc/shadow and be uploaded.
        let absPathReal: string
        try {
          absPathReal = realpathSync(absPath)
        } catch (err) {
          throw new Error(`attachment.path not found: ${absPath} (${(err as Error).message})`)
        }
        if (absPathReal !== allowRootReal && !absPathReal.startsWith(allowRootReal + '/')) {
          throw new Error(
            `attachment.path resolves outside TEAMS_OUTBOUND_ATTACHMENTS_ALLOW_ROOT ` +
              `(${allowRootReal}): ${absPath} -> ${absPathReal}`,
          )
        }
        // statSync on the realpath is now safe (containment proven, lstat
        // already confirmed the supplied entry isn't a link).
        let stat
        try {
          stat = statSync(absPathReal)
        } catch (err) {
          throw new Error(`attachment.path not found: ${absPath} (${(err as Error).message})`)
        }
        if (!stat.isFile()) {
          throw new Error(`attachment.path is not a regular file: ${absPath}`)
        }
        if (stat.size > maxBytes) {
          throw new Error(`attachment too large: ${absPath} (${stat.size} > ${maxBytes})`)
        }
        const rawName = String((item as any)?.name ?? '').trim() || basename(absPath)
        const safeName = sanitizeFilename(rawName)
        if (!safeName) {
          throw new Error(`attachment.name rejected by sanitizer: ${rawName}`)
        }
        const ct = inferContentType(safeName)
        if (isCardContentType(ct)) {
          throw new Error(`attachment content_type is a card type (not allowed): ${ct}`)
        }
        validated.push({ absPath: absPathReal, displayName: safeName, size: stat.size, contentType: ct })
      }

      // Send one consent card per file. The agent's text rides on the first
      // card so the user sees the message once; subsequent cards have empty
      // text so we don't repeat it. The user accepts each card independently;
      // each accept triggers a fileConsent/invoke handled by
      // handleFileConsentInvoke below.
      const tokens: string[] = []
      for (let i = 0; i < validated.length; i++) {
        const v = validated[i]
        const messageForCard = i === 0 ? text : ''
        const token = await sendFileConsentCard(
          ref,
          chatId,
          v.absPath,
          v.displayName,
          v.size,
          v.contentType,
          messageForCard,
        )
        tokens.push(token)
      }

      return {
        content: [
          {
            type: 'text',
            text: `consent_cards_sent: ${chatId} count=${tokens.length}`,
          },
        ],
      }
    }
    case 'fetch_messages': {
      const chatId = String(args.chat_id ?? '').trim()
      const limit = Number(args.limit ?? 20)
      const rows = recentMessages(chatId, Number.isFinite(limit) ? limit : 20)
      return { content: [{ type: 'text', text: JSON.stringify(rows, null, 2) }] }
    }
    case 'send_message': {
      const to = String(args.to ?? '').trim()
      let text = String(args.text ?? '').trim()
      if (!to) throw new Error('to is required')
      if (!text) throw new Error('text is required')

      // Codex r1 BLOCKING: mirror the inbound DM gate (fail-closed).
      // Inbound personal-DM is allowed when dmPolicy === 'open' OR the
      // sender id is in allowFrom; the previous send_message gate was
      // inverted (allowed.length > 0 && !allowed.includes(to)) so a
      // default empty allowFrom would let any target through.
      const access = loadAccess()
      const allowed = access.allowFrom ?? []
      const dmPolicy = access.dmPolicy ?? 'allowlist'
      if (dmPolicy === 'disabled') {
        throw new Error('send_message: dmPolicy is "disabled"; proactive DMs are not allowed.')
      }
      if (dmPolicy !== 'open' && !allowed.includes(to)) {
        throw new Error(
          `send_message: target "${to}" is not in the access.json allowFrom list ` +
          `(dmPolicy=${dmPolicy}); add the user's AAD object id or Teams user id to ` +
          `--allow-from before sending, or set dmPolicy=open if proactive sends to any target are intended.`,
        )
      }

      // Codex r1 SHOULD-FIX: fail fast on missing TEAMS_TENANT_ID rather
      // than deferring to a downstream Bot Framework/network error.
      if (!TENANT_ID) {
        throw new Error(
          'send_message: TEAMS_TENANT_ID env var is required for proactive ' +
          'createConversation; set it in plugins/teams/.env',
        )
      }

      // Prompt guard: sanitize outbound text before send.
      const guarded = runPromptGuard('sanitize', text)
      if (guarded?.blocked) {
        text = '[Agent Bridge] outbound message blocked by prompt guard.'
      } else if (guarded?.was_modified && typeof guarded.sanitized_text === 'string') {
        text = guarded.sanitized_text
      }

      const result = await sendMessageProactive(to, text)
      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(result),
          },
        ],
      }
    }
    default:
      throw new Error(`unknown tool: ${req.params.name}`)
  }
})

async function handleActivity(context: TurnContext): Promise<void> {
  const activity = context.activity
  // Outbound file consent flow: when the user clicks Accept/Decline on a
  // consent card sent by the `reply` MCP tool, Teams delivers a
  // fileConsent/invoke. We handle it before the access gate because the
  // bot itself initiated the conversation — the per-conversation gate
  // already approved this user when the inbound message that triggered the
  // reply was accepted. Returning early after invoke handling is intentional;
  // invoke activities are not chat messages to deliver to Claude.
  if (activity.type === ActivityTypes.Invoke && (activity as any).name === 'fileConsent/invoke') {
    await handleFileConsentInvoke(context)
    return
  }
  // Supported activity types:
  //   - Message       — new chat message from a Teams user.
  //   - MessageUpdate — Teams edit of an existing message; reuses the
  //                     original activity.id but bumps localTimestamp /
  //                     timestamp. The revision-aware dedupe (below) lets
  //                     edits flow through while still dropping retransmits.
  // Intentionally not handled: MessageDelete (out of scope — Teams does
  // emit these, but we don't currently propagate redactions back to the
  // Claude session). All other activity types (typing, conversationUpdate,
  // membersAdded, …) are ignored.
  if (activity.type !== ActivityTypes.Message && activity.type !== ActivityTypes.MessageUpdate) return
  if (!gate(activity)) return

  const chatId = referenceKey(activity)
  const messageId = String(activity.id ?? randomUUID())
  // Bot Framework bumps localTimestamp on edited messages (and timestamp
  // tracks server-side receive time). Either is a stable enough edit
  // indicator to keep edits from being dropped as duplicates.
  const revision = String(
    (activity as any).localTimestamp ??
      (activity.timestamp instanceof Date ? activity.timestamp.toISOString() : activity.timestamp ?? ''),
  )
  if (recentMessageIds.seen(dedupeKey(chatId, messageId, revision))) {
    logDuplicateDrop(chatId, messageId)
    return
  }
  if (deliveredMessageSeen(chatId, messageId, revision)) {
    logDuplicateDrop(chatId, messageId)
    return
  }

  storeReference(activity)

  const userName = String(activity.from?.name ?? activity.from?.id ?? 'teams-user')
  const userIds = idsFor(activity)
  const aad = userIds[0] ?? ''
  // Teams wraps formatted/multiline messages as an inline text/html attachment
  // with activity.text set to empty string. Extract the body in that case so
  // the message is not silently dropped (issue #983).
  let text = compactText(activity.text ?? '')
  if (!text && Array.isArray(activity.attachments)) {
    const htmlAtt = activity.attachments.find(
      att => String(att.contentType ?? '').trim() === 'text/html'
        && typeof (att as any).content === 'string'
        && (att as any).content,
    )
    if (htmlAtt) {
      text = htmlToText(String((htmlAtt as any).content ?? ''))
    }
  }
  const guarded = runPromptGuard('scan', text)
  if (guarded?.blocked) return
  const ts = activity.timestamp instanceof Date ? activity.timestamp.toISOString() : new Date().toISOString()

  const attachments = await downloadAttachments(activity, messageId)

  const stored: StoredMessage = {
    chat_id: chatId,
    message_id: messageId,
    user: userName,
    user_id: userIds[userIds.length - 1] ?? '',
    aad_object_id: aad,
    text,
    ts,
    ...(revision ? { revision } : {}),
    ...(attachments.length > 0 ? { attachments } : {}),
  }
  // Channel delivery and local log append are split:
  //
  //   1. MCP delivery: bounded retry-with-backoff inside
  //      deliverMcpNotificationWithRetry (issue #1313 — Lane ζ). The
  //      dedup entry is preserved on every outcome so a Teams webhook
  //      retry that races us is dropped at the seen() check above. On
  //      permanent failure we emit the audit row + swallow (no throw)
  //      so Bot Framework stops re-driving the same activity against a
  //      degraded MCP transport (which would loop with no net progress
  //      and previously cost the message entirely once dedup got
  //      forgotten on the first failure).
  //   2. Local log append: best-effort after a confirmed MCP delivery.
  //      A failed log append (disk full, EACCES, …) only means
  //      fetch_messages can't replay this entry from the local audit
  //      log — the message is already in the active Claude session.
  //
  // Inbound messages are delivered exclusively via the MCP channel
  // notification (issue #1204): the prior bridge-queue delivery workaround
  // was removed because it silently dropped messages when BRIDGE_AGENT_ID
  // was unset in the plugin's environment, masking the very bug it claimed
  // to work around.
  const deliverResult = await deliverMcpNotificationWithRetry(
    () => mcp.notification({
      method: 'notifications/claude/channel',
      params: {
        content: text || (attachments.length > 0 ? '(attachment)' : ''),
        meta: buildChannelNotificationMeta(activity, stored, attachments),
      },
    }),
  )
  if (!deliverResult.delivered) {
    // All retries exhausted. Emit the structured permanent-failure
    // audit row so the operator's log scraper escalates to an admin
    // task, then swallow the error: returning 2xx to Teams stops Bot
    // Framework from re-driving the same activity webhook against a
    // degraded MCP transport. The dedup entry stays, so any in-flight
    // Teams retry that races us is dropped at the seen() check above.
    for (const errText of deliverResult.errors) {
      process.stderr.write(`teams channel: failed to deliver inbound message_id=${messageId} via channel: ${errText}\n`)
    }
    emitMcpDeliveryFailurePermanent(chatId, messageId, deliverResult.attempts, deliverResult.errors)
    return
  }

  try {
    appendMessage(stored)
  } catch (err) {
    process.stderr.write(`teams channel: failed to append local log message_id=${messageId} (delivery already succeeded): ${err}\n`)
  }

  // PreCompact channel auto-notify activity-index write — issue #597 Track C.
  // Best-effort; failures are logged inside the helper and never bubble up.
  //
  // Bot-self exclusion: only record inbound activity from a real user. Teams'
  // Bot Framework can echo bot-authored messages back through the inbound
  // pipeline (proactive sends from continueConversation, multi-bot crosstalk
  // in shared channels). Recording those would point the daemon's
  // route-precompact-target at the bot's own posts, breaking the "reply to
  // the user who last spoke" contract. The most reliable Bot Framework signal
  // is `from.role === 'bot'`; we also defense-in-depth against self-echo where
  // `from.id` matches the bot's recipient id. See codex r1 review of #610.
  const agentForIndex = process.env.BRIDGE_AGENT_ID ?? ''
  if (agentForIndex && !isInboundFromBotOrSelf(activity)) {
    const inboundDate = activity.timestamp instanceof Date ? activity.timestamp : new Date()
    writeTeamsActivityIndex(agentForIndex, chatId, messageId, stored.user_id, inboundDate)
  }
}

/**
 * True when an inbound activity is from a bot or a self-echo of the bot's own
 * outbound message. Used to skip activity-index updates that would otherwise
 * point the PreCompact route lookup at bot posts instead of the last user
 * inbound.
 *
 * Signals (in order of reliability):
 *   1. `from.role === 'bot'` — Bot Framework convention; emitted by Teams for
 *      proactive sends and bot-to-bot messages.
 *   2. `from.id === recipient.id` — self-echo: the bot is identified as both
 *      the sender and the recipient on the same activity.
 *   3. `from.id === APP_ID` — the bot's app id appears as the sender.
 *
 * Exported for the precompact-notify smoke harness.
 */
export function isInboundFromBotOrSelf(activity: Partial<Activity> & { from?: { id?: string; role?: string }; recipient?: { id?: string } }): boolean {
  const from = activity.from
  if (!from) return false
  if (from.role === 'bot') return true
  const recipientId = activity.recipient?.id ?? ''
  if (from.id && recipientId && from.id === recipientId) return true
  if (APP_ID && from.id && from.id === APP_ID) return true
  return false
}

/**
 * L1 beta19 (codex r1 design 2026-05-25): BotFrameworkAdapter's
 * processActivity assumes an Express-shaped response with `status()`
 * and `send()`. Node's native http.ServerResponse only exposes
 * `writeHead/end`, so the adapter throws TypeError on response-write
 * paths (auth challenges, error replies). This shim adapts the
 * native response to the Express subset the adapter actually calls.
 *
 * We deliberately do NOT migrate to CloudAdapter.processActivityDirect
 * — that changes the auth/adapter semantics (CloudAdapter expects
 * SingleTenant/MultiTenant credential resolution paths the current
 * BotFrameworkAdapter setup does not have) and is well out of scope
 * for an L1 stabilization fix.
 *
 * Exported for the shim smoke harness (server.ts `_smoke-shim`
 * subcommand).
 *
 * Contract:
 *   status(code)   → sets res.statusCode, returns the shim (chainable).
 *   send(body)     → ends the native response exactly once.
 *     Buffer / string  → res.end(body) as-is
 *     object           → JSON.stringify + 'Content-Type: application/json'
 *                        (only when no Content-Type already set)
 *     undefined / null → res.end() with no body
 *
 * Second `send()` call is a no-op (defensive against the adapter
 * accidentally double-ending on an error catch path).
 */
export function createExpressResponseShim(res: import('http').ServerResponse): {
  status(code: number): any
  send(body?: unknown): any
} {
  let ended = false
  const shim: any = {
    status(code: number) {
      res.statusCode = code
      return shim
    },
    send(body?: unknown) {
      if (ended) return shim
      ended = true
      if (body === undefined || body === null) {
        res.end()
        return shim
      }
      if (Buffer.isBuffer(body) || typeof body === 'string') {
        res.end(body)
        return shim
      }
      if (!res.getHeader('Content-Type')) {
        res.setHeader('Content-Type', 'application/json')
      }
      res.end(JSON.stringify(body))
      return shim
    },
  }
  return shim
}

const httpServer = createServer((req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
  if (req.method === 'GET' && url.pathname === '/health') {
    const body = JSON.stringify({ ok: true, channel: 'teams', port: PORT })
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) })
    res.end(body)
    return
  }
  if (req.method === 'GET' && url.pathname === '/auth/callback') {
    handleMs365AuthCallback(url, res)
    return
  }
  if (req.method === 'POST' && url.pathname === '/api/messages') {
    const shim = createExpressResponseShim(res)
    adapter.processActivity(req, shim as any, async context => {
      await handleActivity(context)
    }).catch(err => {
      process.stderr.write(`teams channel: processActivity failed: ${err}\n`)
      if (!res.headersSent) {
        res.writeHead(500)
        res.end()
      }
    })
    return
  }
  res.writeHead(404)
  res.end()
})

// Issue #1671-A (v0.16.3): the prior handler was a bare `exit(1)` with a
// terse "http listen failed" line. On the cm-prod incident the listener hit
// EADDRINUSE on its expected loopback port (TEAMS_WEBHOOK_PORT) because a
// reparented (ppid=1) stale teams listener from a prior session still held
// it — and the operator had no actionable signal in the swallowed log, so
// the only recovery was waiting out the orphan's #69 parent-death watchdog
// (a ~22-min gap during which the router-default triage agent dropped
// unknown-Teams-sender traffic).
//
// The fix here is the LOW-RISK, ALWAYS-SHIPPED half of the codex-consensus
// direction: emit a clear, actionable EADDRINUSE diagnostic that names the
// exact HOST:PORT, the configured TEAMS_WEBHOOK_PORT env var, and states
// plainly that another process holds the port. We deliberately do NOT
// auto-reap the port holder (see the design note below) — a reap can only
// be done safely under a strict provenance gate, and the actual cm-prod
// holder was a *different-UID* standalone router whose argv/cwd/env this
// process cannot even read to prove ownership. So we keep the exit(1) and
// let the existing #69 parent-death watchdog self-heal the orphan, just
// with a far better operator signal than before.
//
// Why reap is DEFERRED (not shipped) for #1671-A:
//   - A provenance gate strong enough to be safe ("this is provably MY own
//     stale teams listener for THIS agent") requires reading the holder's
//     argv/cwd/env to match the plugin entrypoint + BRIDGE_AGENT_ID. On the
//     incident host the holder ran under a different OS user, so those reads
//     are impossible (cross-UID /proc/<pid>/{cmdline,cwd,environ} is denied)
//     → ownership is UNPROVABLE → killing it would be killing an arbitrary
//     port holder, which the scope fence forbids.
//   - A reap whose positive path cannot be proven by a CI smoke is an
//     un-provable reap; per the consensus direction we ship diagnostic-only.
//
// `buildListenErrorDiagnostic` is a pure function (no process side-effects)
// so the #1671-A smoke can assert the exact diagnostic shape for the
// EADDRINUSE branch and the generic-error branch without standing up a real
// listener. The single bind-error handler below is the only call site at
// runtime.
export function buildListenErrorDiagnostic(
  code: string | undefined,
  host: string,
  port: number,
  err: unknown,
): string {
  if (code === 'EADDRINUSE') {
    return (
      `teams channel: cannot bind ${host}:${port} — EADDRINUSE: another process ` +
      `already holds this port. ` +
      `The port is set by TEAMS_WEBHOOK_PORT (currently ${port}; ` +
      `host TEAMS_WEBHOOK_HOST=${host}). ` +
      `This usually means a previous teams listener for this agent was reparented ` +
      `to init (ppid=1) and has not released the port yet — its #69 parent-death ` +
      `watchdog will free it within ~a few seconds to minutes, after which a ` +
      `restart will succeed. To recover immediately, identify and stop the holder ` +
      `(e.g. on Linux: \`ss -ltnp 'sport = :${port}'\` or ` +
      `\`lsof -nP -iTCP:${port} -sTCP:LISTEN\`), then restart this agent. ` +
      `If the holder is a *separate* standalone router process, give it the same ` +
      `parent-death watchdog or consolidate onto one listener for this port.\n`
    )
  }
  return `teams channel: http listen failed on ${host}:${port}: ${err}\n`
}

httpServer.on('error', err => {
  const code = (err as NodeJS.ErrnoException | undefined)?.code
  // Always-shipped clear EADDRINUSE diagnostic (issue #1671-A). No reap: the
  // holder's provenance is unprovable across the UID boundary on the incident
  // host, so we exit and let the #69 parent-death watchdog self-heal.
  process.stderr.write(buildListenErrorDiagnostic(code, HOST, PORT, err))
  process.exit(1)
})

// CLI mode: `node server.js send-managed --agent ... --channel-id ...`.
// Used by the daemon's send-managed-message wrapper for PreCompact notify
// (issue #597). Short-circuits the daemon HTTP/WS startup so a one-shot
// outbound reply never spins up the inbound listener path.
async function runSendManagedCli(): Promise<number> {
  const argv = process.argv.slice(3)
  const flags: Record<string, string> = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const key = arg.slice(2)
    const value = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : ''
    if (value) i++
    flags[key] = value
  }
  const channelId = String(flags['channel-id'] ?? '').trim()
  const replyToMessageId = String(flags['reply-to-message-id'] ?? '').trim()
  const body = String(flags['body'] ?? '')
  const agent = String(flags['agent'] ?? '').trim()
  if (!channelId || !body) {
    process.stderr.write('teams send-managed: --channel-id and --body are required\n')
    return 2
  }
  // Surface the agent id to runPromptGuard via env so the guard line uses
  // the same agent the daemon claims to be sending on behalf of.
  if (agent && !process.env.BRIDGE_AGENT_ID) {
    process.env.BRIDGE_AGENT_ID = agent
  }

  let sanitizedBody = body
  const guarded = runPromptGuard('sanitize', body)
  if (guarded?.blocked) {
    sanitizedBody = '[Agent Bridge] outbound reply blocked by prompt guard.'
  } else if (guarded?.was_modified && typeof guarded.sanitized_text === 'string') {
    sanitizedBody = guarded.sanitized_text
  }

  const refs = loadJson<Record<string, ConversationReference>>(REFERENCES_FILE, {})
  const ref = refs[channelId]
  if (!ref) {
    process.stderr.write(
      `teams send-managed: conversation reference not found for ${channelId}; ` +
      `wait for an inbound Teams message first\n`,
    )
    return 3
  }

  let sentId = ''
  try {
    await adapter.continueConversation(ref, async context => {
      const sent = await context.sendActivity(sanitizedBody)
      if (sent && typeof sent === 'object' && 'id' in sent && typeof sent.id === 'string') {
        sentId = sent.id
      }
    })
  } catch (err) {
    process.stderr.write(`teams send-managed: send failed: ${err}\n`)
    return 1
  }

  // Q3: Teams' continueConversation posts into the same conversation, but
  // Bot Framework does not surface true per-message threading at this API
  // level — there is no replyToId parameter on sendActivity that maps to a
  // user message id. The output marks best_effort_threading=true so the
  // daemon can audit the limitation per the orchestrator's Track C spec.
  const out = {
    status: 'sent',
    plugin: 'teams',
    channel_id: channelId,
    message_id: sentId || '',
    thread_id: replyToMessageId || null,
    best_effort_threading: true,
  }
  process.stdout.write(JSON.stringify(out) + '\n')
  return 0
}

const CLI_SUBCOMMAND = (process.argv[2] ?? '').trim()

if (CLI_SUBCOMMAND === 'send-managed') {
  const code = await runSendManagedCli()
  process.exit(code)
}

// Internal smoke harness — exercised only by tests/precompact-notify/teams-mattermost-adapter.sh
// and scripts/smoke/zeta-beta5-2-teams-mcp-dedup.sh.
// `_smoke-record-activity` invokes writeTeamsActivityIndex directly so the
// smoke can validate the activity-index file schema without spinning up a
// full Bot Framework adapter. `_smoke-should-record` reports whether a
// synthesized activity would be skipped by the bot-self filter.
// `_smoke-channel-meta` asserts the direct Claude channel notification uses
// scalar metadata, not the richer bridge queue payload.
// `_smoke-mcp-retry` exercises deliverMcpNotificationWithRetry +
// emitMcpDeliveryFailurePermanent (issue #1313) without standing up a
// real MCP transport. All smoke commands short-circuit before
// httpServer.listen.
if (CLI_SUBCOMMAND === '_smoke-shim') {
  // L1 beta19 (codex r1 design 2026-05-25): exercise createExpressResponseShim
  // with a fake http.ServerResponse that has writeHead/end but no
  // status/send. The shim is what closes the BotFrameworkAdapter
  // TypeError. Asserts response completes cleanly (no thrown TypeError
  // on `res.status(...).send(...)`), and that the status + content-type
  // + body propagated through to the underlying response. Output is
  // a single JSON line on stdout consumed by the smoke harness.
  const argv = process.argv.slice(3)
  const flags: Record<string, string> = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const key = arg.slice(2)
    const value = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : ''
    if (value) i++
    flags[key] = value
  }
  const variant = String(flags['variant'] ?? 'json').trim()
  // Build a minimal ServerResponse stand-in: just statusCode, headers,
  // writeHead, end, setHeader, getHeader. Express does not introspect
  // beyond these for the status/send code paths.
  const headers: Record<string, string | number | string[]> = {}
  let body: any = undefined
  let ended = false
  let endCalls = 0
  const fakeRes: any = {
    statusCode: 0,
    headersSent: false,
    writeHead(code: number, hdrs?: Record<string, string | number>) {
      fakeRes.statusCode = code
      fakeRes.headersSent = true
      if (hdrs) Object.assign(headers, hdrs)
    },
    setHeader(name: string, value: string | number | string[]) {
      headers[name] = value
    },
    getHeader(name: string) {
      return headers[name]
    },
    end(b?: any) {
      endCalls++
      ended = true
      body = b
    },
  }
  let threw = false
  let errMsg = ''
  try {
    const shim = createExpressResponseShim(fakeRes as any)
    if (variant === 'json') {
      shim.status(202).send({ ok: true, smoke: 'shim' })
    } else if (variant === 'string') {
      shim.status(200).send('plain string body')
    } else if (variant === 'buffer') {
      shim.status(200).send(Buffer.from('buffer-body'))
    } else if (variant === 'empty') {
      shim.status(204).send()
    } else if (variant === 'null') {
      shim.status(204).send(null)
    } else if (variant === 'double-send') {
      shim.status(200).send({ first: true })
      shim.send({ second: 'should be ignored' })
    } else {
      process.stderr.write(`teams _smoke-shim: unknown variant '${variant}'\n`)
      process.exit(2)
    }
  } catch (e) {
    threw = true
    errMsg = String(e)
  }
  const result = {
    variant,
    threw,
    err: errMsg,
    ended,
    endCalls,
    statusCode: fakeRes.statusCode,
    contentType: headers['Content-Type'] ?? null,
    bodyKind: body === undefined
      ? 'undefined'
      : body === null
        ? 'null'
        : Buffer.isBuffer(body)
          ? 'buffer'
          : typeof body,
    bodyString: body === undefined || body === null ? '' : String(body),
  }
  process.stdout.write(JSON.stringify(result) + '\n')
  process.exit(0)
}

if (CLI_SUBCOMMAND === '_smoke-mcp-retry') {
  // Issue #1313 Lane ζ (#1313): exercise deliverMcpNotificationWithRetry
  // + emitMcpDeliveryFailurePermanent without standing up a real MCP
  // transport. Variants:
  //
  //   succeed-first  — send() resolves on attempt 1.
  //   succeed-second — send() throws on attempt 1, resolves on attempt 2
  //                    (MCP recovers mid-retry).
  //   all-fail       — send() throws on every attempt (perma-down).
  //   custom         — read --attempts (N total) and --fail-until (1-based
  //                    attempt index, exclusive — every attempt < this
  //                    index throws; the attempt at this index resolves).
  //                    Set --fail-until 99 with --attempts 3 for "all fail".
  //
  // Output is a single JSON line on stdout consumed by the smoke harness.
  // The audit-emit helper is invoked when delivered=false so the smoke
  // can grep the captured stderr for the structured token.
  const argv = process.argv.slice(3)
  const flags: Record<string, string> = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const key = arg.slice(2)
    const value = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : ''
    if (value) i++
    flags[key] = value
  }
  const variant = String(flags['variant'] ?? 'succeed-first').trim()
  let maxAttempts: number
  let failUntil: number
  if (variant === 'succeed-first') {
    maxAttempts = 3
    failUntil = 1
  } else if (variant === 'succeed-second') {
    maxAttempts = 3
    failUntil = 2
  } else if (variant === 'all-fail') {
    maxAttempts = 3
    failUntil = 99
  } else if (variant === 'custom') {
    maxAttempts = Number(flags['attempts'] ?? '3')
    failUntil = Number(flags['fail-until'] ?? '99')
  } else {
    process.stderr.write(`teams _smoke-mcp-retry: unknown variant '${variant}'\n`)
    process.exit(2)
  }
  let calls = 0
  const send = async (): Promise<void> => {
    calls += 1
    if (calls < failUntil) {
      throw new Error(`smoke-injected-failure attempt=${calls}`)
    }
  }
  const sleepCalls: number[] = []
  const fakeSleep = async (ms: number): Promise<void> => {
    sleepCalls.push(ms)
    // No real wait — smoke completes in milliseconds.
  }
  const chatId = String(flags['chat-id'] ?? 'chat-smoke').trim()
  const messageId = String(flags['message-id'] ?? 'message-smoke').trim()
  const result = await deliverMcpNotificationWithRetry(send, fakeSleep, { maxAttempts, backoffMs: 100 })
  if (!result.delivered) {
    emitMcpDeliveryFailurePermanent(chatId, messageId, result.attempts, result.errors)
  }
  process.stdout.write(JSON.stringify({
    variant,
    delivered: result.delivered,
    attempts: result.attempts,
    errorsCount: result.errors.length,
    sleepCount: sleepCalls.length,
    sleepCalls,
  }) + '\n')
  process.exit(0)
}

if (
  CLI_SUBCOMMAND === '_smoke-record-activity'
  || CLI_SUBCOMMAND === '_smoke-should-record'
  || CLI_SUBCOMMAND === '_smoke-channel-meta'
) {
  const argv = process.argv.slice(3)
  const flags: Record<string, string> = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const key = arg.slice(2)
    const value = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : ''
    if (value) i++
    flags[key] = value
  }
  if (CLI_SUBCOMMAND === '_smoke-record-activity') {
    const agent = String(flags['agent'] ?? '').trim()
    const channelId = String(flags['channel-id'] ?? '').trim()
    const messageId = String(flags['message-id'] ?? '').trim()
    const userId = String(flags['user-id'] ?? '').trim()
    const tsMs = Number(flags['ts-ms'] ?? Date.now())
    if (!agent || !channelId || !messageId) {
      process.stderr.write('teams _smoke-record-activity: --agent, --channel-id, --message-id required\n')
      process.exit(2)
    }
    writeTeamsActivityIndex(agent, channelId, messageId, userId, new Date(tsMs))
    process.exit(0)
  }
  if (CLI_SUBCOMMAND === '_smoke-channel-meta') {
    const fakeActivity: any = {
      channelData: { tenant: { id: 'tenant-smoke' } },
      serviceUrl: 'https://example.invalid/teams',
    }
    const stored: StoredMessage = {
      chat_id: 'chat-smoke',
      message_id: 'message-smoke',
      user: 'Smoke User',
      user_id: 'user-smoke',
      aad_object_id: 'aad-smoke',
      text: 'hello smoke',
      ts: '2026-01-01T00:00:00.000Z',
      revision: 'revision-smoke',
    }
    const attachments: StoredAttachment[] = [
      {
        attachment_id: 'attachment-smoke',
        name: 'smoke.html',
        content_type: 'text/html',
        download_status: 'skipped_non_file',
      },
    ]
    process.stdout.write(JSON.stringify(buildChannelNotificationMeta(fakeActivity, stored, attachments)) + '\n')
    process.exit(0)
  }
  // _smoke-should-record
  const fromId = String(flags['from-id'] ?? '').trim()
  const fromRole = String(flags['from-role'] ?? '').trim()
  const recipientId = String(flags['recipient-id'] ?? '').trim()
  const fakeActivity: any = {
    from: { id: fromId, role: fromRole || undefined },
    recipient: { id: recipientId },
  }
  const isBotOrSelf = isInboundFromBotOrSelf(fakeActivity)
  process.stdout.write(JSON.stringify({ should_skip: isBotOrSelf }) + '\n')
  process.exit(0)
}

if (CLI_SUBCOMMAND === '_smoke-listen-error-diagnostic') {
  // Issue #1671-A (v0.16.3): exercise buildListenErrorDiagnostic directly so
  // the smoke can assert the EADDRINUSE diagnostic shape (HOST:PORT,
  // TEAMS_WEBHOOK_PORT, "another process ... holds this port") and the
  // generic-error fallback shape without standing up a real listener.
  // Variants:
  //   eaddrinuse — code 'EADDRINUSE' → port-conflict diagnostic.
  //   generic    — any other code → terse "http listen failed" line.
  // The HOST/PORT are read from TEAMS_WEBHOOK_HOST/TEAMS_WEBHOOK_PORT exactly
  // as the runtime listener path does, so the smoke can pin that the operator
  // env var name surfaces in the message. Output: the raw diagnostic string
  // on stdout (single record; the trailing newline is preserved).
  const argv = process.argv.slice(3)
  const flags: Record<string, string> = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const key = arg.slice(2)
    const value = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : ''
    if (value) i++
    flags[key] = value
  }
  const variant = String(flags['variant'] ?? 'eaddrinuse').trim()
  const code = variant === 'generic' ? 'ECONNREFUSED' : 'EADDRINUSE'
  const fakeErr = Object.assign(new Error(`listen ${code} ${HOST}:${PORT}`), { code })
  process.stdout.write(buildListenErrorDiagnostic(code, HOST, PORT, fakeErr))
  process.exit(0)
}

// Sweep stale outbound file consents (older than 24h) on plugin start so a
// long-lived state file doesn't accumulate unbounded pending records. Best
// effort: a sweep failure logs but never blocks listener startup. The sweep
// runs through the per-process consent mutex so a concurrent invoke during
// startup can't trample it.
sweepOutboundConsents().catch(err => {
  process.stderr.write(`teams channel: outbound consent sweep failed: ${err}\n`)
})

httpServer.listen(PORT, HOST, () => {
  process.stderr.write(`teams channel: listening on http://${HOST}:${PORT} (/api/messages, /auth/callback)\n`)
})

// Issue #1330 M7 (v0.14.5-beta5-2 Lane ξ): surface a startup warning when
// BRIDGE_AGENT_ID is empty so the operator sees that the activity-index
// write at line 2314 below will silently skip for the entire lifetime of
// this MCP server. Without the warning, the missing activity-index causes
// PreCompact channel-route lookup to miss the session-id mapping for this
// agent, and the operator's only diagnostic is "channel dispatch fails"
// long after the start-time root cause is forgotten.
//
// The warning fires once at server start, not on every inbound message.
// The activity-index skip at line 2314 stays graceful (no per-message
// stderr spam) because per-message logging would flood the channel when
// the env is misconfigured at the bridge-start.sh / launch envelope
// layer — the start-time warning is the actionable signal.
if (!process.env.BRIDGE_AGENT_ID) {
  process.stderr.write(
    'teams channel: BRIDGE_AGENT_ID is empty at server start — PreCompact ' +
    'activity-index writes will be skipped for every inbound message. ' +
    'Verify the bridge launch envelope inlines BRIDGE_AGENT_ID (see ' +
    'bridge-start.sh #1330 M7 / bridge-run.sh:350).\n',
  )
}

await mcp.connect(new StdioServerTransport())
