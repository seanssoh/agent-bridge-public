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
import { createServer } from 'http'
import { randomUUID } from 'crypto'
import { spawnSync } from 'child_process'
import {
  accessSync,
  appendFileSync,
  chmodSync,
  constants as fsConstants,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'fs'
import { homedir } from 'os'
import { isAbsolute as pathIsAbsolute, join, resolve as pathResolve } from 'path'
import { createRecentMessageDeduper, storedRowMatchesIncoming } from './dedupe.ts'

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

if (process.env.TEAMS_BRIDGE_MODE === '1' || process.env.TEAMS_BRIDGE_AGENT) {
  process.stderr.write(
    'teams channel: ignoring deprecated TEAMS_BRIDGE_MODE/TEAMS_BRIDGE_AGENT; inbound messages use notifications/claude/channel\n',
  )
}
if (process.env.TEAMS_DELIVERY_MODE && process.env.TEAMS_DELIVERY_MODE !== 'channel') {
  process.stderr.write(
    `teams channel: unsupported TEAMS_DELIVERY_MODE=${process.env.TEAMS_DELIVERY_MODE}; using channel delivery\n`,
  )
}

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
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
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
  return /^[A-Za-z0-9_-]{8,128}$/.test(state)
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

function compactText(text: string): string {
  return text.replace(/<at>[^<]+<\/at>/g, '').trim()
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

function writeTeamsActivityIndex(
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
    const tmp = `${path}.tmp`
    writeFileSync(tmp, JSON.stringify(index, null, 2) + '\n', { mode: 0o600 })
    renameSync(tmp, path)
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

async function streamDownload(
  url: string,
  destPath: string,
  maxBytes: number,
): Promise<{ ok: true; size: number } | { ok: false; error: string }> {
  const resp = await fetch(url)
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

async function downloadAttachments(
  activity: Activity,
  messageId: string,
): Promise<StoredAttachment[]> {
  const items = Array.isArray(activity.attachments) ? activity.attachments : []
  if (items.length === 0) return []
  const safeMessageId = sanitizeMessageId(messageId)
  const results: StoredAttachment[] = []
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
    if (contentType === TEAMS_FILE_DOWNLOAD_TYPE) {
      const content = ((att as any).content ?? {}) as { downloadUrl?: string }
      downloadUrl = String(content.downloadUrl ?? '').trim() || String((att as any).contentUrl ?? '').trim()
    } else if (contentType.startsWith('image/')) {
      downloadUrl = String((att as any).contentUrl ?? '').trim()
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
      const dl = await streamDownload(downloadUrl, localPath, ATTACHMENT_MAX_BYTES)
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
      description: 'Reply to a Teams conversation. Pass chat_id from the inbound message.',
      inputSchema: {
        type: 'object',
        properties: {
          chat_id: { type: 'string', description: 'Teams conversation id from inbound meta.chat_id.' },
          text: { type: 'string', description: 'Message text to send.' },
        },
        required: ['chat_id', 'text'],
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
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const args = (req.params.arguments ?? {}) as Record<string, unknown>
  switch (req.params.name) {
    case 'reply': {
      const chatId = String(args.chat_id ?? '').trim()
      let text = String(args.text ?? '').trim()
      if (!chatId) throw new Error('chat_id is required')
      if (!text) throw new Error('text is required')
      const guarded = runPromptGuard('sanitize', text)
      if (guarded?.blocked) {
        text = '[Agent Bridge] outbound reply blocked by prompt guard.'
      } else if (guarded?.was_modified && typeof guarded.sanitized_text === 'string') {
        text = guarded.sanitized_text
      }
      const refs = loadJson<Record<string, ConversationReference>>(REFERENCES_FILE, {})
      const ref = refs[chatId]
      if (!ref) throw new Error(`conversation reference not found for ${chatId}; wait for an inbound Teams message first`)
      await adapter.continueConversation(ref, async context => {
        await context.sendActivity(text)
      })
      return { content: [{ type: 'text', text: `sent: ${chatId}` }] }
    }
    case 'fetch_messages': {
      const chatId = String(args.chat_id ?? '').trim()
      const limit = Number(args.limit ?? 20)
      const rows = recentMessages(chatId, Number.isFinite(limit) ? limit : 20)
      return { content: [{ type: 'text', text: JSON.stringify(rows, null, 2) }] }
    }
    default:
      throw new Error(`unknown tool: ${req.params.name}`)
  }
})

async function handleActivity(context: TurnContext): Promise<void> {
  const activity = context.activity
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
  const text = compactText(activity.text ?? '')
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
  // Channel delivery and local log append are split: a delivery failure must
  // surface as a non-2xx so Teams retries, but a successful delivery followed
  // by a failed log append (disk full, EACCES, …) should NOT cause Teams to
  // retry — the message is already in the active Claude session. The only
  // observable consequence of a log-append failure is that fetch_messages
  // can't replay this entry from the local audit log.
  try {
    await mcp.notification({
      method: 'notifications/claude/channel',
      params: {
        content: text || (attachments.length > 0 ? '(attachment)' : ''),
        meta: {
          source: 'teams',
          chat_id: chatId,
          conversation_id: chatId,
          message_id: messageId,
          user: userName,
          user_id: stored.user_id,
          aad_object_id: aad,
          tenant_id: String((activity.channelData as any)?.tenant?.id ?? TENANT_ID),
          service_url: String(activity.serviceUrl ?? ''),
          ts,
          ...(revision ? { revision } : {}),
          ...(attachments.length > 0
            ? {
                attachment_count: String(attachments.length),
                attachments: attachments.map(att => ({
                  name: att.name,
                  content_type: att.content_type,
                  download_status: att.download_status,
                  ...(att.local_path ? { local_path: att.local_path } : {}),
                  ...(att.size_bytes !== undefined ? { size_bytes: att.size_bytes } : {}),
                  ...(att.download_error ? { download_error: att.download_error } : {}),
                })),
              }
            : {}),
        },
      },
    })
  } catch (err) {
    recentMessageIds.forget(dedupeKey(chatId, messageId, revision))
    process.stderr.write(`teams channel: failed to deliver inbound message_id=${messageId}: ${err}\n`)
    throw err
  }
  try {
    appendMessage(stored)
  } catch (err) {
    process.stderr.write(`teams channel: failed to append local log message_id=${messageId} (delivery already succeeded): ${err}\n`)
  }

  // PreCompact channel auto-notify activity-index write — issue #597 Track C.
  // Best-effort; failures are logged inside the helper and never bubble up.
  const agentForIndex = process.env.BRIDGE_AGENT_ID ?? ''
  if (agentForIndex) {
    const inboundDate = activity.timestamp instanceof Date ? activity.timestamp : new Date()
    writeTeamsActivityIndex(agentForIndex, chatId, messageId, stored.user_id, inboundDate)
  }
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
    adapter.processActivity(req, res, async context => {
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

httpServer.on('error', err => {
  process.stderr.write(`teams channel: http listen failed on ${HOST}:${PORT}: ${err}\n`)
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

httpServer.listen(PORT, HOST, () => {
  process.stderr.write(`teams channel: listening on http://${HOST}:${PORT} (/api/messages, /auth/callback)\n`)
})

await mcp.connect(new StdioServerTransport())
