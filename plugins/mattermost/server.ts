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

const BOT_ROUTES_FILE = process.env.MATTERMOST_BOT_ROUTES ?? ''
let botRoutes: BotRoute[] = []

function loadBotRoutes(): BotRoute[] {
  if (!BOT_ROUTES_FILE) return []
  try {
    return JSON.parse(readFileSync(BOT_ROUTES_FILE, 'utf8')) as BotRoute[]
  } catch { return [] }
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
function gracefulShutdown(reason: string): void {
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
  setTimeout(() => process.exit(0), 1500).unref?.()
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

async function mmApiRequest(method: string, path: string, body?: unknown): Promise<unknown> {
  const url = `${MM_URL}/api/v4${path}`
  const headers: Record<string, string> = {
    'Authorization': `Bearer ${MM_TOKEN}`,
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

async function mmCreatePost(channelId: string, message: string, tokenOverride?: string): Promise<unknown> {
  if (tokenOverride) {
    const url = `${MM_URL}/api/v4/posts`
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${tokenOverride}`,
        'Content-Type': 'application/json',
        'User-Agent': 'agent-bridge-mattermost/0.1',
      },
      body: JSON.stringify({ channel_id: channelId, message }),
    })
    if (!response.ok) {
      const detail = await response.text()
      throw new Error(`Mattermost API POST /posts failed: ${response.status} ${detail}`)
    }
    return response.text().then(t => t ? JSON.parse(t) : null)
  }
  return mmApiRequest('POST', '/posts', { channel_id: channelId, message })
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

async function mmGetMe(): Promise<{ id: string; username: string }> {
  return mmApiRequest('GET', '/users/me') as Promise<{ id: string; username: string }>
}

let botUserId = ''
let botUsername = ''

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

async function handlePosted(post: MattermostPost, payload: MattermostEventPayload): Promise<void> {
  if (recentMessageIds.seen(post.id)) {
    if (duplicateDropLogs < 10) {
      process.stderr.write(`mattermost channel: dropped duplicate post_id=${post.id}\n`)
      duplicateDropLogs += 1
    }
    return
  }
  // Self-message: bot's own posts arrive on its own WS too (via Mattermost
  // broadcast). Filter to prevent infinite loops. Per-route self-loop
  // prevention for multi-bot lands in commit 3b.
  if (post.user_id === botUserId) return

  const channelId = post.channel_id
  const userId = post.user_id
  const userName = String(payload.data?.sender_name ?? userId).replace(/^@/, '') || 'mattermost-user'
  let text = String(post.message ?? '').trim()
  if (!channelId || !text) return

  const isDirect = (payload.data?.channel_type ?? '') === 'D'
  const mentionedBot = botUsername ? text.includes(`@${botUsername}`) : false

  if (!gate(channelId, userId, isDirect, mentionedBot)) return

  // Strip bot mention from text. Per-route mention gate (with `data.mentions`
  // primary + text fallback) lands in commit 3b once per-route bot identity
  // is wired.
  if (botUsername) {
    text = text.replace(new RegExp(`@${botUsername}\\b`, 'g'), '').trim()
    if (!text) return
  }

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

  if (BRIDGE_MODE) {
    if (BRIDGE_AGENT) {
      void bridgeSend(BRIDGE_AGENT, text, userName, channelId, null)
    }
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
          team_id: String(payload.data?.team_id ?? payload.broadcast?.team_id ?? ''),
          ts,
        },
      },
    })
  }
}

async function start(): Promise<void> {
  // Boot identity check — invalid bot token is a hard fail. The plugin
  // cannot do anything useful without a valid token, so failing fast and
  // letting agb (or the launcher) restart is preferable to running with
  // partial identity. Architect finding #1 — must be try/catch with exit.
  let me: { id: string; username: string }
  try {
    me = await mmGetMe()
  } catch (err) {
    process.stderr.write(
      `mattermost channel: FATAL: could not fetch bot identity (invalid MATTERMOST_BOT_TOKEN?): ${err}\n`,
    )
    process.exit(1)
  }
  botUserId = me.id
  botUsername = me.username
  process.stderr.write(`mattermost channel: authenticated as @${botUsername} (${botUserId})\n`)

  botRoutes = loadBotRoutes()
  if (botRoutes.length > 0) {
    // Resolve user_ids for each bot route. NOTE: in commit 3a only the
    // single-bot path (MM_TOKEN) is wired to WS; per-route WS connections
    // and per-route bot identity land in commit 3b. Loading the routes
    // here keeps the config-validation surface live so operators can
    // confirm bot-routes JSON parses correctly without enabling multi-bot.
    for (const route of botRoutes) {
      if (!route.user_id) {
        try {
          const resp = await fetch(`${MM_URL}/api/v4/users/username/${route.username}`, {
            headers: { 'Authorization': `Bearer ${route.token}` },
          })
          if (resp.ok) {
            const user = (await resp.json()) as { id: string }
            route.user_id = user.id
          }
        } catch {
          /* best-effort — config validation only */
        }
      }
    }
    process.stderr.write(
      `mattermost channel: loaded ${botRoutes.length} bot routes (multi-bot WS wiring lands in commit 3b): ${botRoutes
        .map(r => `@${r.username}`)
        .join(', ')}\n`,
    )
  }

  // Single-bot WS connection. Multi-bot per-route fan-out + watchdog
  // lands in commit 3b.
  process.stderr.write(`mattermost channel: connecting to ${MM_WS_URL}/api/v4/websocket\n`)
  const seq = makeSeqCounter()
  const connectOnce = createMattermostConnectOnce({
    wsUrl: `${MM_WS_URL}/api/v4/websocket`,
    botToken: MM_TOKEN,
    abortSignal: abortController.signal,
    runtime: {
      log: msg => process.stderr.write(`${msg}\n`),
      error: msg => process.stderr.write(`${msg}\n`),
    },
    nextSeq: seq,
    onPosted: handlePosted,
    getBotUpdateAt: () => fetchBotUpdateAt(MM_TOKEN, botUserId),
    healthCheckIntervalMs: HEALTH_CHECK_MS,
    idleTimeoutMs: WS_IDLE_TIMEOUT_MS,
  })

  // Single-bot uses await: the reconnect loop only exits on abortSignal,
  // so once shutdown signals fire (SIGTERM/SIGHUP/SIGINT/parent-died)
  // the loop terminates and start() returns and the process exits
  // cleanly. Architect finding #3 (single-bot half).
  const wsLoop = runWithReconnect(connectOnce, {
    abortSignal: abortController.signal,
    initialDelayMs: WS_INITIAL_DELAY_MS,
    maxDelayMs: WS_MAX_DELAY_MS,
    jitterRatio: 0.2,
    onError: err => process.stderr.write(`mattermost channel: ws error: ${err}\n`),
    onReconnect: ms => process.stderr.write(`mattermost channel: ws reconnecting in ${ms}ms\n`),
  })

  // MCP stdio runs in parallel — agents reach in via stdio MCP for
  // reply / fetch_messages tools regardless of WS state.
  await Promise.all([mcp.connect(new StdioServerTransport()), wsLoop])
}

await start()
