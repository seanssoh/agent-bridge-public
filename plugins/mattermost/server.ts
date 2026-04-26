#!/usr/bin/env bun
/**
 * Mattermost channel for Claude Code.
 *
 * Receives messages via Mattermost Outgoing Webhooks or Bot WebSocket,
 * gates them with access.json, forwards accepted messages through Claude
 * channel notifications, and exposes reply/fetch tools over MCP.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { createServer } from 'http'
import { randomUUID } from 'crypto'
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

const HOST = process.env.MATTERMOST_WEBHOOK_HOST ?? '127.0.0.1'
const PORT = Number(process.env.MATTERMOST_WEBHOOK_PORT ?? '3979')
const STATIC = process.env.MATTERMOST_ACCESS_MODE === 'static'
const STANDALONE = process.env.MATTERMOST_STANDALONE === '1'
const STANDALONE_SYSTEM_PROMPT = process.env.MATTERMOST_SYSTEM_PROMPT ?? ''
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY ?? ''
const CLAUDE_MODEL = process.env.MATTERMOST_CLAUDE_MODEL ?? 'claude-sonnet-4-20250514'
const BRIDGE_MODE = process.env.MATTERMOST_BRIDGE_MODE === '1'
const BRIDGE_AGENT = process.env.MATTERMOST_BRIDGE_AGENT ?? ''

const MM_URL = process.env.MATTERMOST_URL ?? 'http://localhost:8065'
const MM_TOKEN = process.env.MATTERMOST_BOT_TOKEN ?? process.env.MATTERMOST_PERSONAL_TOKEN ?? ''
const MM_WEBHOOK_TOKEN = process.env.MATTERMOST_OUTGOING_WEBHOOK_TOKEN ?? ''

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
    httpServer.close(() => process.exit(0))
  } catch {
    process.exit(0)
  }
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
  const sendMessage = `[Mattermost channel_id=${channelId}] ${userName}: ${message}\n\nReply using the mattermost reply tool with channel_id="${channelId}". Your bot token is already configured.`
  const agb = join(BRIDGE_HOME, 'agent-bridge')
  try {
    const { execSync } = await import('child_process')
    execSync(`"${agb}" urgent "${targetAgent}" "${sendMessage.replace(/"/g, '\\"')}"`, {
      encoding: 'utf8',
      timeout: 10000,
    })
    process.stderr.write(`mattermost channel: bridge-send to ${agent} for channel ${channelId}\n`)
  } catch (err) {
    process.stderr.write(`mattermost channel: bridge-send failed: ${err}\n`)
    // Fallback to standalone reply if bridge-send fails
    if (STANDALONE) {
      void claudeReply(message, userName, channelId, route)
    }
  }
}

async function claudeReply(userMessage: string, userName: string, channelId: string, route?: BotRoute | null): Promise<void> {
  const replyToken = route?.token ?? MM_TOKEN
  const replyBotName = route?.username ?? botUsername
  const systemPrompt = route?.system_prompt ?? (STANDALONE_SYSTEM_PROMPT || `You are a helpful assistant in a Mattermost channel. Respond concisely in the same language as the user. Your bot username is @${replyBotName}.`)

  if (ANTHROPIC_API_KEY) {
    try {
      const recent = recentMessages(channelId, 10)
      const contextMessages = recent.slice(-10).map(m => ({
        role: m.user_id === botUserId ? 'assistant' as const : 'user' as const,
        content: m.user_id === botUserId ? m.text : `[${m.user}]: ${m.text}`,
      }))
      contextMessages.push({ role: 'user' as const, content: `[${userName}]: ${userMessage}` })

      const response = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'x-api-key': ANTHROPIC_API_KEY,
          'anthropic-version': '2023-06-01',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: CLAUDE_MODEL,
          max_tokens: 1024,
          system: systemPrompt,
          messages: contextMessages,
        }),
      })
      if (!response.ok) {
        const detail = await response.text()
        process.stderr.write(`mattermost channel: Claude API error: ${response.status} ${detail}\n`)
        return
      }
      const data = await response.json() as { content: Array<{ type: string; text: string }> }
      const replyText = data.content?.filter(b => b.type === 'text').map(b => b.text).join('\n') ?? ''
      if (replyText) {
        await mmCreatePost(channelId, replyText, replyToken !== MM_TOKEN ? replyToken : undefined)
        process.stderr.write(`mattermost channel: standalone reply sent to ${channelId} as @${replyBotName}\n`)
      }
    } catch (err) {
      process.stderr.write(`mattermost channel: Claude API call failed: ${err}\n`)
    }
  } else {
    // Fallback: use claude CLI --print mode
    try {
      const { execSync } = await import('child_process')
      const prompt = `${systemPrompt}\n\nUser ${userName} says: ${userMessage}`
      const result = execSync(`claude --print "${prompt.replace(/"/g, '\\"')}"`, {
        encoding: 'utf8',
        timeout: 60000,
      }).trim()
      if (result) {
        await mmCreatePost(channelId, result, replyToken !== MM_TOKEN ? replyToken : undefined)
        process.stderr.write(`mattermost channel: standalone reply (cli) sent to ${channelId} as @${replyBotName}\n`)
      }
    } catch (err) {
      process.stderr.write(`mattermost channel: claude cli fallback failed: ${err}\n`)
    }
  }
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

type OutgoingWebhookPayload = {
  token?: string
  team_id?: string
  team_domain?: string
  channel_id?: string
  channel_name?: string
  timestamp?: number
  user_id?: string
  user_name?: string
  post_id?: string
  text?: string
  trigger_word?: string
  file_ids?: string
}

function handleOutgoingWebhook(payload: OutgoingWebhookPayload): void {
  if (MM_WEBHOOK_TOKEN && payload.token !== MM_WEBHOOK_TOKEN) {
    process.stderr.write(`mattermost channel: outgoing webhook token mismatch\n`)
    return
  }

  const channelId = String(payload.channel_id ?? '').trim()
  const postId = String(payload.post_id ?? randomUUID()).trim()
  const userId = String(payload.user_id ?? '').trim()
  const userName = String(payload.user_name ?? 'mattermost-user')
  let text = String(payload.text ?? '').trim()

  if (!channelId || !text) return
  if (userId === botUserId) return

  if (recentMessageIds.seen(postId)) {
    if (duplicateDropLogs < 10) {
      process.stderr.write(`mattermost channel: dropped duplicate post_id=${postId}\n`)
      duplicateDropLogs += 1
    }
    return
  }

  const isDirect = (payload.channel_name ?? '').startsWith('__')
  const mentionedBot = botUsername ? text.includes(`@${botUsername}`) : false

  if (!gate(channelId, userId, isDirect, mentionedBot)) return

  // Detect which bot was mentioned and route accordingly
  let routedBot: BotRoute | null = null
  if (STANDALONE && botRoutes.length > 0) {
    for (const route of botRoutes) {
      if (text.includes(`@${route.username}`)) {
        routedBot = route
        text = text.replace(new RegExp(`@${route.username}\\b`, 'g'), '').trim()
        break
      }
    }
    if (!routedBot) {
      // No specific bot mentioned — use default bot or ignore
      if (botUsername) {
        text = text.replace(new RegExp(`@${botUsername}\\b`, 'g'), '').trim()
      }
    }
  } else if (botUsername) {
    text = text.replace(new RegExp(`@${botUsername}\\b`, 'g'), '').trim()
  }

  const guarded = runPromptGuard('scan', text)
  if (guarded?.blocked) return

  const rawTs = payload.timestamp ?? 0
  const ts = rawTs > 1e12
    ? new Date(rawTs).toISOString()
    : rawTs > 0
      ? new Date(rawTs * 1000).toISOString()
      : new Date().toISOString()

  const stored: StoredMessage = {
    channel_id: channelId,
    post_id: postId,
    user: userName,
    user_id: userId,
    text,
    ts,
  }
  appendMessage(stored)

  if (BRIDGE_MODE) {
    const targetAgent = routedBot?.agent ?? routedBot?.username?.replace(/-bot$/, '').replace(/-/g, '_') ?? BRIDGE_AGENT
    if (targetAgent) {
      void bridgeSend(targetAgent, text, userName, channelId, routedBot)
    }
  } else if (STANDALONE) {
    void claudeReply(text, userName, channelId, routedBot)
  } else {
    void mcp.notification({
      method: 'notifications/claude/channel',
      params: {
        content: text,
        meta: {
          source: 'mattermost',
          channel_id: channelId,
          post_id: postId,
          user: userName,
          user_id: userId,
          team_id: String(payload.team_id ?? ''),
          ts,
        },
      },
    })
  }
}

const httpServer = createServer((req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)

  if (req.method === 'GET' && url.pathname === '/health') {
    const body = JSON.stringify({ ok: true, channel: 'mattermost', port: PORT })
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) })
    res.end(body)
    return
  }

  if (req.method === 'POST' && url.pathname === '/hooks/outgoing') {
    let body = ''
    req.on('data', chunk => { body += chunk })
    req.on('end', () => {
      try {
        const payload = JSON.parse(body) as OutgoingWebhookPayload
        handleOutgoingWebhook(payload)
      } catch (err) {
        process.stderr.write(`mattermost channel: failed to parse webhook payload: ${err}\n`)
      }
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end('{}')
    })
    return
  }

  res.writeHead(404)
  res.end()
})

httpServer.on('error', err => {
  process.stderr.write(`mattermost channel: http listen failed on ${HOST}:${PORT}: ${err}\n`)
  process.exit(1)
})

async function start(): Promise<void> {
  try {
    const me = await mmGetMe()
    botUserId = me.id
    botUsername = me.username
    process.stderr.write(`mattermost channel: authenticated as @${botUsername} (${botUserId})\n`)
  } catch (err) {
    process.stderr.write(`mattermost channel: warning: could not fetch bot identity: ${err}\n`)
  }

  botRoutes = loadBotRoutes()
  if (botRoutes.length > 0) {
    // Resolve user_ids for each bot route
    for (const route of botRoutes) {
      if (!route.user_id) {
        try {
          const resp = await fetch(`${MM_URL}/api/v4/users/username/${route.username}`, {
            headers: { 'Authorization': `Bearer ${route.token}` },
          })
          if (resp.ok) {
            const user = await resp.json() as { id: string }
            route.user_id = user.id
          }
        } catch {}
      }
    }
    process.stderr.write(`mattermost channel: loaded ${botRoutes.length} bot routes: ${botRoutes.map(r => `@${r.username}`).join(', ')}\n`)
  }

  httpServer.listen(PORT, HOST, () => {
    process.stderr.write(`mattermost channel: listening on http://${HOST}:${PORT} (/hooks/outgoing)${STANDALONE ? ' [standalone]' : ''}\n`)
  })

  if (!STANDALONE) {
    await mcp.connect(new StdioServerTransport())
  }
}

await start()
