#!/usr/bin/env bun
/**
 * Mattermost channel for Claude Code.
 *
 * Subscribes to a self-hosted Mattermost via the WebSocket gateway
 * (`/api/v4/websocket`), gates incoming posts with access.json, forwards
 * accepted messages through Claude channel notifications, and exposes
 * reply/fetch tools over MCP.
 *
 * The WebSocket monitor + reconnect loop are imported from ./lib/
 * (vendored from openclaw/openclaw under MIT — see THIRD_PARTY_LICENSES.md).
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { spawnSync } from 'child_process'
import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from 'fs'
import { homedir } from 'os'
import { join } from 'path'
import { createRecentMessageDeduper } from './dedupe.ts'
import {
  createMattermostConnectOnce,
  type MattermostEventPayload,
  type MattermostPost,
} from './lib/monitor-websocket.ts'
import { runWithReconnect } from './lib/reconnect.ts'

type Access = {
  dmPolicy?: 'allowlist' | 'open' | 'disabled'
  allowFrom?: string[]
  channels?: Record<string, ChannelPolicy>
  pending?: Record<string, unknown>
  routes?: Record<string, unknown>
}

type ChannelPolicy = {
  requireMention?: boolean
  allowFrom?: string[]
}

type StoredMessage = {
  channel_id: string
  post_id: string
  user: string
  user_id: string
  text: string
  ts: string
}

const STATE_DIR = process.env.MATTERMOST_STATE_DIR ?? join(homedir(), '.claude', 'channels', 'mattermost')
const BRIDGE_HOME = process.env.BRIDGE_HOME ?? join(homedir(), '.agent-bridge')
const BRIDGE_STATE_DIR = process.env.BRIDGE_STATE_DIR ?? join(BRIDGE_HOME, 'state')
const ACCESS_FILE = join(STATE_DIR, 'access.json')
const ENV_FILE = join(STATE_DIR, '.env')
const MESSAGES_FILE = join(STATE_DIR, 'messages.jsonl')

try {
  chmodSync(ENV_FILE, 0o600)
  const inheritedEnv = new Set(Object.keys(process.env))
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^(\w+)=(.*)$/)
    if (m && !inheritedEnv.has(m[1])) process.env[m[1]] = m[2]
  }
} catch {}

const STATIC = process.env.MATTERMOST_ACCESS_MODE === 'static'
const BRIDGE_MODE = process.env.MATTERMOST_BRIDGE_MODE === '1'
const BRIDGE_AGENT = process.env.MATTERMOST_BRIDGE_AGENT ?? ''

const MM_URL = process.env.MATTERMOST_URL ?? 'http://localhost:8065'
const MM_TOKEN = process.env.MATTERMOST_BOT_TOKEN ?? process.env.MATTERMOST_PERSONAL_TOKEN ?? ''

// WebSocket transport — `MM_URL` defines the API base; the WS endpoint
// is derived (https→wss, http→ws) unless explicitly overridden.
const MM_WS_URL = process.env.MATTERMOST_WS_URL
  ?? MM_URL.replace(/^https:/, 'wss:').replace(/^http:/, 'ws:')
const HEALTH_CHECK_MS = Number(process.env.MATTERMOST_HEALTH_CHECK_MS ?? '30000')
const WS_INITIAL_DELAY_MS = Number(process.env.MATTERMOST_WS_INITIAL_DELAY_MS ?? '2000')
const WS_MAX_DELAY_MS = Number(process.env.MATTERMOST_WS_MAX_DELAY_MS ?? '60000')
const WS_IDLE_TIMEOUT_MS = Number(process.env.MATTERMOST_WS_IDLE_TIMEOUT_MS ?? '120000')

const abortController = new AbortController()

type BotRoute = {
  username: string
  token: string
  user_id?: string
  system_prompt: string
  agent?: string
}

/**
 * Per-route identity used by the WS monitor + handlePosted. One per
 * bot. For single-bot deployments this list has length 1; for
 * multi-bot deployments via MATTERMOST_BOT_ROUTES it has N entries
 * with distinct tokens, user IDs, and target agents.
 */
type RouteIdentity = {
  userId: string
  username: string
  token: string
  agent: string
}

/**
 * Watchdog state: per-route timestamp of when the route became
 * disconnected. `null` means currently connected. When ALL entries
 * have stayed disconnected for > 3× WS_MAX_DELAY_MS, the multi-bot
 * watchdog terminates the process so agb can restart it.
 */
type RouteState = {
  disconnectedSince: number | null
}

const BOT_ROUTES_FILE = process.env.MATTERMOST_BOT_ROUTES ?? ''

function fatalConfig(message: string): never {
  process.stderr.write(`mattermost channel: FATAL: ${message}\n`)
  process.exit(1)
}

function loadBotRoutes(): BotRoute[] {
  if (!BOT_ROUTES_FILE) return []
  let parsed: unknown
  try {
    parsed = JSON.parse(readFileSync(BOT_ROUTES_FILE, 'utf8'))
  } catch (err) {
    fatalConfig(`could not read MATTERMOST_BOT_ROUTES ${BOT_ROUTES_FILE}: ${err}`)
  }
  if (!Array.isArray(parsed)) {
    fatalConfig(`MATTERMOST_BOT_ROUTES ${BOT_ROUTES_FILE} must contain a JSON array`)
  }
  return parsed as BotRoute[]
}

if (!MM_TOKEN && !BOT_ROUTES_FILE) {
  process.stderr.write(
    `mattermost channel: MATTERMOST_BOT_TOKEN or MATTERMOST_BOT_ROUTES is required\n` +
      `  set them in ${ENV_FILE}\n`,
  )
  process.exit(1)
}

process.on('unhandledRejection', err => {
  process.stderr.write(`mattermost channel: unhandled rejection: ${err}\n`)
})
process.on('uncaughtException', err => {
  process.stderr.write(`mattermost channel: uncaught exception: ${err}\n`)
})

let shuttingDown = false
function gracefulShutdown(reason: string, exitCode = 0): void {
  if (shuttingDown) return
  shuttingDown = true
  process.stderr.write(`mattermost channel: shutting down (${reason})\n`)
  try {
    abortController.abort()
  } catch {
    /* abort can throw on certain runtime states — fall through */
  }
  // Safety: if the abort + WS close path hangs (network limbo, etc.),
  // force exit shortly after. Matches the Teams plugin's 1.5s safety net.
  setTimeout(() => process.exit(exitCode), 1500).unref?.()
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'))
process.on('SIGHUP', () => gracefulShutdown('SIGHUP'))
process.on('SIGINT', () => gracefulShutdown('SIGINT'))

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

function defaultAccess(): Access {
  return { dmPolicy: 'allowlist', allowFrom: [], channels: {}, pending: {}, routes: {} }
}

const BOOT_ACCESS = STATIC ? loadJson<Access>(ACCESS_FILE, defaultAccess()) : null

function loadAccess(): Access {
  return BOOT_ACCESS ?? loadJson<Access>(ACCESS_FILE, defaultAccess())
}

function gate(channelId: string, userId: string, isDirect: boolean, mentionedBot: boolean): boolean {
  const access = loadAccess()
  if (access.dmPolicy === 'disabled') return false

  const channelPolicy = access.channels?.[channelId]
  if (channelPolicy) {
    if (channelPolicy.requireMention && !mentionedBot) return false
    const allow = channelPolicy.allowFrom ?? []
    if (allow.length > 0 && !allow.includes(userId)) return false
    return true
  }

  if (isDirect) {
    if (access.dmPolicy === 'open') return true
    return (access.allowFrom ?? []).includes(userId)
  }

  return false
}

function appendMessage(message: StoredMessage): void {
  ensureStateDir()
  appendFileSync(MESSAGES_FILE, JSON.stringify(message) + '\n', { mode: 0o600 })
}

// PreCompact channel auto-notify activity index — issue #597 Track C.
//
// Writes $BRIDGE_STATE_DIR/channels/mattermost/<agent>.json so the daemon's
// route-precompact-target lookup can pick the most recent inbound channel
// to notify on context compaction. Best-effort: any failure is logged and
// swallowed so a state-dir glitch never breaks live message delivery.

type MattermostActivityChannelEntry = {
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

type MattermostActivityIndex = {
  schema_version: number
  agent: string
  plugin: 'mattermost'
  updated_ts: number
  channels: Record<string, MattermostActivityChannelEntry>
}

function sanitizeAgentForPath(raw: string): string {
  if (!raw || typeof raw !== 'string') return ''
  if (raw.length > 64) return ''
  if (!/^[a-zA-Z0-9_-]+$/.test(raw)) return ''
  return raw
}

function mattermostActivityIndexPath(agent: string): string {
  return join(BRIDGE_STATE_DIR, 'channels', 'mattermost', `${agent}.json`)
}

function loadMattermostActivityIndex(path: string, agent: string): MattermostActivityIndex {
  try {
    const raw = readFileSync(path, 'utf8')
    const parsed = JSON.parse(raw)
    if (parsed && typeof parsed === 'object' && parsed.channels && typeof parsed.channels === 'object') {
      return parsed as MattermostActivityIndex
    }
  } catch {}
  return {
    schema_version: 1,
    agent,
    plugin: 'mattermost',
    updated_ts: 0,
    channels: {},
  }
}

let mattermostRecordedTail = 0

function writeMattermostActivityIndex(
  agent: string,
  channelId: string,
  postId: string,
  userId: string,
  inboundDate: Date,
  rootId: string,
): void {
  const safeAgent = sanitizeAgentForPath(agent)
  if (!safeAgent || !channelId || !postId) return
  try {
    const path = mattermostActivityIndexPath(safeAgent)
    const dir = join(BRIDGE_STATE_DIR, 'channels', 'mattermost')
    mkdirSync(dir, { recursive: true, mode: 0o700 })
    const index = loadMattermostActivityIndex(path, safeAgent)
    const tsMs = inboundDate.getTime()
    const tsSec = Math.floor(tsMs / 1000)
    // recorded_ns: see writeTeamsActivityIndex — ms-precision packed into the
    // upper digits, per-process counter into the lower three digits, kept
    // under Number.MAX_SAFE_INTEGER. Used only for tie-break ordering.
    const nowNs = tsMs * 1_000 + (mattermostRecordedTail++ % 1_000)
    index.schema_version = 1
    index.agent = safeAgent
    index.plugin = 'mattermost'
    index.updated_ts = tsSec
    const entry: MattermostActivityChannelEntry = {
      channel_id: channelId,
      reply_kind: rootId ? 'thread' : 'root',
      last_seen_id: postId,
      last_seen_ts: tsSec,
      last_user_inbound_ts: tsSec,
      last_user_inbound_ts_ms: tsMs,
      last_user_inbound_message_id: postId,
      last_user_inbound_user_id: userId,
      last_user_inbound_recorded_ns: nowNs,
    }
    if (rootId) {
      entry.thread_id = rootId
    }
    index.channels[channelId] = entry
    const tmp = `${path}.tmp`
    writeFileSync(tmp, JSON.stringify(index, null, 2) + '\n', { mode: 0o600 })
    renameSync(tmp, path)
  } catch (err) {
    process.stderr.write(`mattermost channel: activity-index write failed: ${err}\n`)
  }
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

function recentMessages(channelId: string, limit: number): StoredMessage[] {
  if (!existsSync(MESSAGES_FILE)) return []
  const lines = readFileSync(MESSAGES_FILE, 'utf8').split('\n').filter(Boolean)
  const rows = lines
    .map(line => {
      try { return JSON.parse(line) as StoredMessage } catch { return null }
    })
    .filter((row): row is StoredMessage => Boolean(row))
    .filter(row => !channelId || row.channel_id === channelId)
  return rows.slice(-Math.max(1, Math.min(limit, 100)))
}

async function mmApiRequest(
  method: string,
  path: string,
  body?: unknown,
  tokenOverride?: string,
): Promise<unknown> {
  const url = `${MM_URL}/api/v4${path}`
  const headers: Record<string, string> = {
    'Authorization': `Bearer ${tokenOverride ?? MM_TOKEN}`,
    'Content-Type': 'application/json',
    'User-Agent': 'agent-bridge-mattermost/0.1',
  }
  const opts: RequestInit = { method, headers }
  if (body) opts.body = JSON.stringify(body)

  const response = await fetch(url, opts)
  if (!response.ok) {
    const detail = await response.text()
    throw new Error(`Mattermost API ${method} ${path} failed: ${response.status} ${detail}`)
  }
  const text = await response.text()
  return text ? JSON.parse(text) : null
}

async function mmCreatePost(
  channelId: string,
  message: string,
  tokenOverride?: string,
  rootId?: string,
): Promise<unknown> {
  // root_id: when set, this post becomes a thread reply rooted at the given
  // post id. Mattermost's threading model is "post inside the same channel
  // with root_id == the original post id"; if the original was already
  // inside a thread, callers should pass that thread's root id (the same
  // root_id that lives on the inbound post.root_id), not the inbound's own
  // post id. Issue #597 Track C uses this for managed PreCompact replies.
  const body: Record<string, string> = { channel_id: channelId, message }
  if (rootId && typeof rootId === 'string' && rootId.length > 0) {
    body.root_id = rootId
  }
  if (tokenOverride) {
    const url = `${MM_URL}/api/v4/posts`
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${tokenOverride}`,
        'Content-Type': 'application/json',
        'User-Agent': 'agent-bridge-mattermost/0.1',
      },
      body: JSON.stringify(body),
    })
    if (!response.ok) {
      const detail = await response.text()
      throw new Error(`Mattermost API POST /posts failed: ${response.status} ${detail}`)
    }
    return response.text().then(t => t ? JSON.parse(t) : null)
  }
  return mmApiRequest('POST', '/posts', body)
}

async function bridgeSend(agent: string, message: string, userName: string, channelId: string, route?: BotRoute | null): Promise<void> {
  const targetAgent = route?.agent ?? agent
  const sendMessage =
    `[Mattermost] channel_id=${channelId} user=${userName}\n\n${message}\n\n` +
    `Reply via the mattermost MCP tool (mcp__mattermost__create_post) using the channel_id above.`
  const agb = join(BRIDGE_HOME, 'agent-bridge')
  const result = spawnSync(agb, ['urgent', targetAgent, sendMessage], {
    encoding: 'utf8',
    timeout: 10000,
  })
  if (result.error) {
    process.stderr.write(`mattermost channel: bridge-send spawn failed: ${result.error}\n`)
    return
  }
  if (result.status !== 0) {
    process.stderr.write(`mattermost channel: bridge-send exit ${result.status}: ${result.stderr ?? ''}\n`)
    return
  }
  process.stderr.write(`mattermost channel: bridge-send to ${targetAgent} for channel ${channelId}\n`)
}

async function mmGetMe(token?: string): Promise<{ id: string; username: string }> {
  return mmApiRequest('GET', '/users/me', undefined, token) as Promise<{
    id: string
    username: string
  }>
}

/**
 * Server-parsed mentions: Mattermost includes `data.mentions` on `posted`
 * events as a JSON-stringified array of user IDs that the server's own
 * mention parser identified. This is more authoritative than re-parsing
 * the message text — handles internationalized usernames, markdown
 * context, etc. May be absent on some event types or older Mattermost
 * versions, hence the fallback to text parsing in `mentionsBotUsername`.
 */
function extractServerParsedMentionUserIds(
  payload: MattermostEventPayload,
): string[] | null {
  const raw = payload.data?.mentions
  if (typeof raw !== 'string' || raw.length === 0) return null
  try {
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return null
    return parsed.filter((x): x is string => typeof x === 'string')
  } catch {
    return null
  }
}

/**
 * Text-parsing fallback: matches `@username` with word-boundary
 * semantics. Does NOT match `@username-foo`, `@usernameSomething`,
 * or backtick/code-block-quoted occurrences. Used only when
 * `data.mentions` is absent or empty (Architect iteration-2 finding).
 */
function mentionsBotUsername(text: string, username: string): boolean {
  if (!text || !username) return false
  // Mattermost username allowed chars: a-z, 0-9, dot, dash, underscore.
  // Word boundary on right side via lookahead — anything that's not
  // those chars terminates the username.
  const pattern = new RegExp(`(^|[^A-Za-z0-9_.-])@${escapeRegex(username)}(?![A-Za-z0-9_.-])`, 'i')
  return pattern.test(text)
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

const recentMessageIds = createRecentMessageDeduper(256)
let duplicateDropLogs = 0

const mcp = new Server(
  { name: 'mattermost', version: '0.1.0' },
  {
    capabilities: {
      tools: {},
      experimental: {
        'claude/channel': {},
        'claude/channel/permission': {},
      },
    },
    instructions: [
      'Mattermost channel for Claude Code.',
      'Messages from Mattermost arrive as <channel source="mattermost" channel_id="..." post_id="..." user="..." ts="...">.',
      'Anything the Mattermost user should see must be sent with the reply tool. Terminal transcript output is not delivered to Mattermost.',
      'Pass channel_id from the inbound message to reply. Use fetch_messages for recent local message context.',
    ].join('\n'),
  },
)

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description: 'Reply to a Mattermost channel. Pass channel_id from the inbound message.',
      inputSchema: {
        type: 'object',
        properties: {
          channel_id: { type: 'string', description: 'Mattermost channel id from inbound meta.channel_id.' },
          text: { type: 'string', description: 'Message text to send.' },
        },
        required: ['channel_id', 'text'],
      },
    },
    {
      name: 'fetch_messages',
      description: 'Fetch recent Mattermost messages captured by this plugin from the local rolling log.',
      inputSchema: {
        type: 'object',
        properties: {
          channel_id: { type: 'string', description: 'Optional Mattermost channel id.' },
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
      const channelId = String(args.channel_id ?? '').trim()
      let text = String(args.text ?? '').trim()
      if (!channelId) throw new Error('channel_id is required')
      if (!text) throw new Error('text is required')
      const guarded = runPromptGuard('sanitize', text)
      if (guarded?.blocked) {
        text = '[Agent Bridge] outbound reply blocked by prompt guard.'
      } else if (guarded?.was_modified && typeof guarded.sanitized_text === 'string') {
        text = guarded.sanitized_text
      }
      await mmCreatePost(channelId, text)
      return { content: [{ type: 'text', text: `sent: ${channelId}` }] }
    }
    case 'fetch_messages': {
      const channelId = String(args.channel_id ?? '').trim()
      const limit = Number(args.limit ?? 20)
      const rows = recentMessages(channelId, Number.isFinite(limit) ? limit : 20)
      return { content: [{ type: 'text', text: JSON.stringify(rows, null, 2) }] }
    }
    default:
      throw new Error(`unknown tool: ${req.params.name}`)
  }
})

function makeSeqCounter(): () => number {
  let seq = 1
  return () => seq++
}

/**
 * Raw `GET /api/v4/users/{userId}` returning the bot's current `update_at`.
 * Does NOT route through `mmApiRequest` because that helper hardcodes the
 * global `MM_TOKEN` (multi-bot per-route token-aware mmApiRequest lands in
 * commit 3b). For 3a single-bot, the token here is `MM_TOKEN` itself.
 */
async function fetchBotUpdateAt(token: string, userId: string): Promise<number> {
  const url = `${MM_URL}/api/v4/users/${userId}`
  const resp = await fetch(url, {
    headers: {
      'Authorization': `Bearer ${token}`,
      'User-Agent': 'agent-bridge-mattermost/0.1',
    },
  })
  if (!resp.ok) {
    throw new Error(`get user ${userId} failed: ${resp.status}`)
  }
  const data = (await resp.json()) as { update_at?: number }
  return Number(data.update_at ?? 0)
}

async function handlePosted(
  post: MattermostPost,
  payload: MattermostEventPayload,
  route: RouteIdentity,
): Promise<void> {
  // Self-message check uses THIS route's userId. Multi-bot: bot A posting
  // arrives on bot B's WS too — bot A's route filters it; bot B's route
  // sees it as a non-self post and applies the mention gate normally.
  if (post.user_id === route.userId) return

  const channelId = post.channel_id
  const userId = post.user_id
  const userName =
    String(payload.data?.sender_name ?? userId).replace(/^@/, '') || 'mattermost-user'
  let text = String(post.message ?? '').trim()
  if (!channelId || !text) return

  // Per-route mention gate — server-parsed mention list is authoritative
  // when present; fall back to text parsing for events that omit it.
  const serverMentions = extractServerParsedMentionUserIds(payload)
  const mentionedThisBot =
    serverMentions !== null
      ? serverMentions.includes(route.userId)
      : mentionsBotUsername(text, route.username)

  const isDirect = (payload.data?.channel_type ?? '') === 'D'

  // The gate (access.json) still controls DM/channel allowlists. For
  // multi-bot, mention-required behavior is enforced by the per-route
  // mention gate above; if the event survives both gates it belongs to
  // this route.
  if (!gate(channelId, userId, isDirect, mentionedThisBot)) return
  if (!isDirect && !mentionedThisBot) return

  // Per-(post, route) dedupe — same post.id arriving on multiple WS
  // connections (one per bot) is expected for multi-bot, and each route
  // must be allowed to process it independently.
  const dedupeKey = `${post.id}::${route.userId}`
  if (recentMessageIds.seen(dedupeKey)) {
    if (duplicateDropLogs < 10) {
      process.stderr.write(
        `mattermost channel: dropped duplicate post_id=${post.id} route=@${route.username}\n`,
      )
      duplicateDropLogs += 1
    }
    return
  }

  // Strip THIS route's @mention from the message body. Other bots'
  // mentions stay in (so the agent sees that the user also addressed
  // others — useful for cross-bot delegation context).
  text = text.replace(new RegExp(`@${escapeRegex(route.username)}\\b`, 'gi'), '').trim()
  if (!text) return

  const guarded = runPromptGuard('scan', text)
  if (guarded?.blocked) return

  const ts =
    post.create_at && post.create_at > 0
      ? new Date(post.create_at).toISOString()
      : new Date().toISOString()

  const stored: StoredMessage = {
    channel_id: channelId,
    post_id: post.id,
    user: userName,
    user_id: userId,
    text,
    ts,
  }
  appendMessage(stored)

  // PreCompact channel auto-notify activity-index write — issue #597 Track C.
  // Best-effort; failures are logged inside the helper and never bubble up.
  // root_id: thread continuation. If the inbound post is already inside a
  // thread (post.root_id set), a reply uses that root; otherwise replying
  // with root_id=post.id starts a thread under the inbound post.
  const agentForIndex = route.agent || process.env.BRIDGE_AGENT_ID || ''
  if (agentForIndex) {
    const inboundDate =
      post.create_at && post.create_at > 0 ? new Date(post.create_at) : new Date()
    const rootForIndex = String(post.root_id ?? '').trim() || post.id
    writeMattermostActivityIndex(agentForIndex, channelId, post.id, userId, inboundDate, rootForIndex)
  }

  if (BRIDGE_MODE) {
    void bridgeSend(route.agent, text, userName, channelId, null)
  } else {
    void mcp.notification({
      method: 'notifications/claude/channel',
      params: {
        content: text,
        meta: {
          source: 'mattermost',
          channel_id: channelId,
          post_id: post.id,
          user: userName,
          user_id: userId,
          bot_username: route.username,
          team_id: String(payload.data?.team_id ?? payload.broadcast?.team_id ?? ''),
          ts,
        },
      },
    })
  }
}

/**
 * Resolve the route list at boot. Two modes:
 *   - MATTERMOST_BOT_ROUTES set + non-empty: each route is validated
 *     by calling mmGetMe(route.token). First failure is fatal — running
 *     with partial routes silently drops one bot's traffic.
 *   - No BOT_ROUTES: single-bot fallback. MM_TOKEN must be set;
 *     BRIDGE_AGENT must be set when BRIDGE_MODE=1.
 */
async function resolveRoutes(): Promise<RouteIdentity[]> {
  const file = loadBotRoutes()
  if (file.length > 0) {
    const out: RouteIdentity[] = []
    for (const r of file) {
      if (!r.token || !r.username) {
        process.stderr.write(
          `mattermost channel: FATAL: bot route missing token/username: ${JSON.stringify({ username: r.username })}\n`,
        )
        process.exit(1)
      }
      let me: { id: string; username: string }
      try {
        me = await mmGetMe(r.token)
      } catch (err) {
        process.stderr.write(
          `mattermost channel: FATAL: could not validate bot route @${r.username}: ${err}\n`,
        )
        process.exit(1)
      }
      const agent = r.agent ?? r.username.replace(/-bot$/, '').replace(/-/g, '_')
      out.push({
        userId: me.id,
        username: me.username,
        token: r.token,
        agent,
      })
    }
    return out
  }

  // Single-bot fallback.
  if (!MM_TOKEN) {
    process.stderr.write(
      `mattermost channel: FATAL: MATTERMOST_BOT_TOKEN required when MATTERMOST_BOT_ROUTES is unset\n`,
    )
    process.exit(1)
  }
  let me: { id: string; username: string }
  try {
    me = await mmGetMe(MM_TOKEN)
  } catch (err) {
    process.stderr.write(
      `mattermost channel: FATAL: could not fetch bot identity (invalid MATTERMOST_BOT_TOKEN?): ${err}\n`,
    )
    process.exit(1)
  }
  if (BRIDGE_MODE && !BRIDGE_AGENT) {
    process.stderr.write(
      `mattermost channel: FATAL: MATTERMOST_BRIDGE_AGENT required when BRIDGE_MODE=1 in single-bot mode\n`,
    )
    process.exit(1)
  }
  return [
    {
      userId: me.id,
      username: me.username,
      token: MM_TOKEN,
      agent: BRIDGE_AGENT,
    },
  ]
}

async function start(): Promise<void> {
  const routes = await resolveRoutes()
  process.stderr.write(
    `mattermost channel: ${routes.length} route(s) authenticated: ${routes.map(r => `@${r.username}→${r.agent || '(no-agent)'}`).join(', ')}\n`,
  )

  process.stderr.write(`mattermost channel: connecting to ${MM_WS_URL}/api/v4/websocket\n`)

  const routeStates: RouteState[] = routes.map(() => ({ disconnectedSince: null }))

  // Per-route reconnect loops. Each loop has its own auth_challenge seq
  // counter (Mattermost expects monotonically increasing seq per WS
  // connection — separate connections start from 1 independently).
  const wsLoops = routes.map((route, i) => {
    const seq = makeSeqCounter()
    const connectOnce = createMattermostConnectOnce({
      wsUrl: `${MM_WS_URL}/api/v4/websocket`,
      botToken: route.token,
      abortSignal: abortController.signal,
      runtime: {
        log: msg => process.stderr.write(`[@${route.username}] ${msg}\n`),
        error: msg => process.stderr.write(`[@${route.username}] ${msg}\n`),
      },
      nextSeq: seq,
      onPosted: (post, payload) => handlePosted(post, payload, route),
      getBotUpdateAt: () => fetchBotUpdateAt(route.token, route.userId),
      healthCheckIntervalMs: HEALTH_CHECK_MS,
      idleTimeoutMs: WS_IDLE_TIMEOUT_MS,
      statusSink: patch => {
        if (patch.connected === true) {
          routeStates[i].disconnectedSince = null
        } else if (patch.connected === false && routeStates[i].disconnectedSince === null) {
          routeStates[i].disconnectedSince = Date.now()
        }
      },
    })

    return runWithReconnect(connectOnce, {
      abortSignal: abortController.signal,
      initialDelayMs: WS_INITIAL_DELAY_MS,
      maxDelayMs: WS_MAX_DELAY_MS,
      jitterRatio: 0.2,
      onError: err =>
        process.stderr.write(`mattermost channel: [@${route.username}] ws error: ${err}\n`),
      onReconnect: ms =>
        process.stderr.write(
          `mattermost channel: [@${route.username}] ws reconnecting in ${ms}ms\n`,
        ),
    })
  })

  // Multi-bot watchdog: if every route stays disconnected for longer than
  // 3× the max reconnect backoff, the deployment has likely lost the
  // ability to reach Mattermost entirely. Exit non-zero so agb restarts
  // the process — letting the reconnect loops spin forever would leave
  // a zombie agent that shows up as "alive" but answers nothing.
  // (Single-bot is fine without this: `await runWithReconnect` ensures
  // the process exits naturally when its abort fires.)
  const watchdogThresholdMs = WS_MAX_DELAY_MS * 3
  if (routes.length > 1) {
    const watchdog = setInterval(() => {
      const now = Date.now()
      const allDown =
        routeStates.length > 0 &&
        routeStates.every(s => s.disconnectedSince !== null && now - s.disconnectedSince > watchdogThresholdMs)
      if (allDown) {
        clearInterval(watchdog)
        process.stderr.write(
          `mattermost channel: FATAL: all ${routes.length} routes disconnected > ${watchdogThresholdMs}ms — exiting for restart\n`,
        )
        // Trigger graceful shutdown path so MCP stdio + WS abort fire.
        gracefulShutdown('all-routes-down', 1)
      }
    }, 15_000)
    watchdog.unref?.()
  }

  // MCP stdio runs in parallel — agents reach in via stdio MCP for
  // reply / fetch_messages tools regardless of WS state. We await all
  // WS loops too so that single-bot exits cleanly when its loop ends
  // (Architect finding #3, single-bot half) and multi-bot keeps running
  // until the watchdog or signal handler aborts.
  await Promise.all([mcp.connect(new StdioServerTransport()), ...wsLoops])
}

// CLI mode: `node server.js send-managed --agent ... --channel-id ...`.
// Used by the daemon's send-managed-message wrapper for PreCompact notify
// (issue #597). Short-circuits the daemon WS startup so a one-shot outbound
// reply never spins up the inbound listener path.
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
    process.stderr.write('mattermost send-managed: --channel-id and --body are required\n')
    return 2
  }
  if (agent && !process.env.BRIDGE_AGENT_ID) {
    process.env.BRIDGE_AGENT_ID = agent
  }

  // Resolve the per-agent route token so managed sends preserve bot identity
  // in multi-bot deployments. MATTERMOST_BOT_ROUTES maps each route to a
  // distinct bot account (token + username); send-managed should post as the
  // bot configured for `--agent` rather than the global MM_TOKEN. Falls back
  // to MM_TOKEN when no route matches (preserves behavior for installs that
  // haven't set up multi-agent routing). See codex r1 review of #610.
  let routeToken = ''
  if (agent) {
    try {
      const routes = loadBotRoutes()
      for (const r of routes) {
        const routeAgent = r.agent ?? r.username.replace(/-bot$/, '').replace(/-/g, '_')
        if (routeAgent === agent && r.token) {
          routeToken = r.token
          break
        }
      }
    } catch (err) {
      process.stderr.write(`mattermost send-managed: bot-routes lookup failed: ${err}\n`)
    }
  }
  const sendToken = routeToken || MM_TOKEN
  if (!sendToken) {
    process.stderr.write(
      'mattermost send-managed: no token available for agent ' +
        (agent || '(unspecified)') +
        '; set MATTERMOST_BOT_TOKEN or MATTERMOST_BOT_ROUTES in ' + ENV_FILE + '\n',
    )
    return 2
  }

  let sanitizedBody = body
  const guarded = runPromptGuard('sanitize', body)
  if (guarded?.blocked) {
    sanitizedBody = '[Agent Bridge] outbound reply blocked by prompt guard.'
  } else if (guarded?.was_modified && typeof guarded.sanitized_text === 'string') {
    sanitizedBody = guarded.sanitized_text
  }

  // Mattermost threading: pass the inbound post id as root_id so the reply
  // surfaces in the same thread. The daemon's --reply-to-message-id is the
  // inbound post id from the activity index. If the original post was
  // already a thread reply, callers may pass its root_id instead — same
  // shape, Mattermost resolves equivalently.
  let posted: unknown
  try {
    posted = await mmCreatePost(channelId, sanitizedBody, sendToken, replyToMessageId || undefined)
  } catch (err) {
    process.stderr.write(`mattermost send-managed: send failed: ${err}\n`)
    return 1
  }

  const postedRow = posted as { id?: string; root_id?: string } | null
  const sentId = String(postedRow?.id ?? '').trim()
  const threadId = String(postedRow?.root_id ?? '').trim() || replyToMessageId || ''
  // best_effort_threading=false — Mattermost natively supports message-
  // granular threading via root_id, which we used.
  const out = {
    status: 'sent',
    plugin: 'mattermost',
    channel_id: channelId,
    message_id: sentId,
    thread_id: threadId || null,
    best_effort_threading: false,
  }
  process.stdout.write(JSON.stringify(out) + '\n')
  return 0
}

const CLI_SUBCOMMAND = (process.argv[2] ?? '').trim()

if (CLI_SUBCOMMAND === 'send-managed') {
  const code = await runSendManagedCli()
  process.exit(code)
}

await start()
