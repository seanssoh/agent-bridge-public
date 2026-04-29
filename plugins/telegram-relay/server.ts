#!/usr/bin/env bun
/**
 * Telegram channel client for the Agent Bridge polling relay daemon.
 *
 * This process does not call Telegram getUpdates. It registers with
 * lib/telegram-relay.py over a Unix socket, receives fan-out updates, and
 * exposes Telegram-compatible MCP tool names for Claude Code.
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { createHash } from 'crypto'
import { spawnSync } from 'child_process'
import { createConnection } from 'net'
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

type GroupPolicy = {
  requireMention?: boolean
  allowFrom?: string[]
}

type Access = {
  dmPolicy?: 'allowlist' | 'open' | 'disabled' | 'pairing'
  allowFrom?: string[]
  defaultChatId?: string
  groups?: Record<string, GroupPolicy>
  mentionPatterns?: string[]
  pending?: Record<string, unknown>
}

type TelegramUser = {
  id?: number | string
  username?: string
  first_name?: string
  last_name?: string
  is_bot?: boolean
}

type TelegramChat = {
  id?: number | string
  type?: string
  title?: string
  username?: string
}

type TelegramMessage = {
  message_id?: number | string
  from?: TelegramUser
  chat?: TelegramChat
  date?: number
  text?: string
  caption?: string
  entities?: Array<Record<string, unknown>>
  caption_entities?: Array<Record<string, unknown>>
  reply_to_message?: TelegramMessage
  photo?: Array<{ file_id?: string; file_unique_id?: string; file_size?: number }>
  document?: { file_id?: string; file_name?: string; mime_type?: string; file_size?: number }
  voice?: { file_id?: string; mime_type?: string; file_size?: number }
  audio?: { file_id?: string; file_name?: string; mime_type?: string; file_size?: number }
  video?: { file_id?: string; file_name?: string; mime_type?: string; file_size?: number }
  video_note?: { file_id?: string; file_size?: number }
  sticker?: { file_id?: string; emoji?: string; set_name?: string }
}

type TelegramUpdate = {
  update_id?: number | string
  message?: TelegramMessage
  edited_message?: TelegramMessage
  channel_post?: TelegramMessage
  edited_channel_post?: TelegramMessage
  delivered_to?: string[]
}

type StoredMessage = {
  chat_id: string
  message_id: string
  user: string
  user_id: string
  text: string
  ts: string
}

type ToolResult = {
  content: Array<{ type: 'text'; text: string }>
  isError?: boolean
}

const STATE_DIR = process.env.TELEGRAM_STATE_DIR ?? join(homedir(), '.claude', 'channels', 'telegram')
const BRIDGE_HOME = process.env.BRIDGE_HOME ?? join(homedir(), '.agent-bridge')
const BRIDGE_STATE_DIR = process.env.BRIDGE_STATE_DIR ?? join(BRIDGE_HOME, 'state')
const ACCESS_FILE = join(STATE_DIR, 'access.json')
const ENV_FILE = join(STATE_DIR, '.env')
const RELAY_TOKEN_FILE = process.env.TELEGRAM_RELAY_TOKEN_FILE ?? join(STATE_DIR, 'relay-token')
const MESSAGES_FILE = join(STATE_DIR, 'messages.jsonl')
const RELAY_ROOT = join(BRIDGE_STATE_DIR, 'channels', 'telegram')
const CLIENT_ID =
  process.env.TELEGRAM_RELAY_CLIENT_ID ??
  `${process.env.BRIDGE_AGENT_ID ?? process.env.USER ?? 'telegram-relay'}-${process.pid}`
const ROUTE_AGENT =
  process.env.TELEGRAM_RELAY_AGENT ??
  process.env.BRIDGE_AGENT_ID ??
  process.env.AGENT_BRIDGE_AGENT ??
  ''
const DISPATCH_MODE = process.env.TELEGRAM_RELAY_DISPATCH ?? 'mcp'
const BOT_USERNAME = String(process.env.TELEGRAM_RELAY_BOT_USERNAME ?? '').replace(/^@/, '')
const RECV_TIMEOUT_SECONDS = Number(process.env.TELEGRAM_RELAY_RECV_TIMEOUT_SECONDS ?? '25')
const SOCKET_TIMEOUT_MS = Number(process.env.TELEGRAM_RELAY_SOCKET_TIMEOUT_MS ?? '5000')

function usage(): void {
  process.stdout.write(`Usage:
  bun plugins/telegram-relay/server.ts
  bun plugins/telegram-relay/server.ts --help
  bun plugins/telegram-relay/server.ts --smoke-tool <tool> --args '<json>'

Environment:
  TELEGRAM_STATE_DIR=<agent .telegram dir>
  BRIDGE_HOME=<bridge home>
  BRIDGE_STATE_DIR=<bridge state dir>
  BRIDGE_TELEGRAM_RELAY_AUTOSPAWN=1
  TELEGRAM_RELAY_DISPATCH=mcp|urgent|both
  TELEGRAM_RELAY_AGENT=<agent for urgent dispatch>
`)
}

const argv = process.argv.slice(2)
if (argv.includes('--help') || argv.includes('-h')) {
  usage()
  process.exit(0)
}

function ensureStateDir(): void {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 })
  mkdirSync(RELAY_ROOT, { recursive: true, mode: 0o700 })
}

function loadEnvFile(): void {
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

function appendJsonLine(path: string, payload: unknown): void {
  ensureStateDir()
  const line = JSON.stringify(payload) + '\n'
  appendFileSync(path, line, { mode: 0o600 })
}

function defaultAccess(): Access {
  return { dmPolicy: 'allowlist', allowFrom: [], groups: {}, pending: {} }
}

const STATIC_ACCESS = process.env.TELEGRAM_ACCESS_MODE === 'static'
const BOOT_ACCESS = STATIC_ACCESS ? loadJson<Access>(ACCESS_FILE, defaultAccess()) : null

function loadAccess(): Access {
  return BOOT_ACCESS ?? loadJson<Access>(ACCESS_FILE, defaultAccess())
}

function tokenFromEnv(): string {
  return String(process.env.TELEGRAM_BOT_TOKEN ?? process.env.BOT_TOKEN ?? process.env.TOKEN ?? '').trim()
}

function tokenHash(token: string): string {
  return createHash('sha256').update(token).digest('hex').slice(0, 16)
}

function socketPathFor(hash: string): string {
  return join(RELAY_ROOT, `${hash}.sock`)
}

function tokenFilePath(): string {
  return RELAY_TOKEN_FILE
}

loadEnvFile()
ensureStateDir()

const TOKEN_VALUE = tokenFromEnv()
if (!TOKEN_VALUE) {
  process.stderr.write(`telegram-relay channel: TELEGRAM_BOT_TOKEN required in ${ENV_FILE}\n`)
  process.exit(1)
}
const TOKEN_HASH = tokenHash(TOKEN_VALUE)
const SOCKET_PATH = socketPathFor(TOKEN_HASH)

function atomicWrite(path: string, text: string): void {
  const tmp = `${path}.tmp-${process.pid}`
  writeFileSync(tmp, text, { mode: 0o600 })
  renameSync(tmp, path)
  try { chmodSync(path, 0o600) } catch {}
}

function ensureRelayTokenFile(): void {
  try {
    if (readFileSync(RELAY_TOKEN_FILE, 'utf8').trim() === TOKEN_VALUE) {
      chmodSync(RELAY_TOKEN_FILE, 0o600)
      return
    }
  } catch {}
  atomicWrite(RELAY_TOKEN_FILE, `${TOKEN_VALUE}\n`)
}

function registerTokenFile(): void {
  ensureRelayTokenFile()
  if (process.env.TELEGRAM_RELAY_REGISTER_TOKEN === '0') return
  if (!existsSync(tokenFilePath())) return
  const tokensFile = join(RELAY_ROOT, 'tokens.list')
  const rows = new Map<string, string>()
  try {
    for (const line of readFileSync(tokensFile, 'utf8').split('\n')) {
      if (!line.trim() || line.startsWith('#')) continue
      const [hash, file] = line.split('\t', 2)
      if (hash && file && file !== tokenFilePath()) rows.set(hash, file)
    }
  } catch {}
  rows.set(TOKEN_HASH, tokenFilePath())
  const body = Array.from(rows.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([hash, file]) => `${hash}\t${file}\n`)
    .join('')
  atomicWrite(tokensFile, body)
}

function agentBridgeCli(): string {
  if (process.env.AGENT_BRIDGE_CLI) return process.env.AGENT_BRIDGE_CLI
  const local = join(BRIDGE_HOME, 'agent-bridge')
  return existsSync(local) ? local : 'agent-bridge'
}

function runPromptGuard(command: 'scan' | 'sanitize', text: string): Record<string, unknown> | null {
  if (process.env.BRIDGE_PROMPT_GUARD_ENABLED !== '1') return null
  const script = join(BRIDGE_HOME, 'bridge-guard.py')
  const result = spawnSync(
    'python3',
    [script, command, '--agent', process.env.BRIDGE_AGENT_ID ?? ROUTE_AGENT, '--surface', command === 'scan' ? 'channel' : 'output', '--format', 'json', text],
    { encoding: 'utf8' },
  )
  if (result.status !== 0 && !result.stdout.trim()) return null
  try {
    return JSON.parse(result.stdout)
  } catch {
    return null
  }
}

function relayRpc(request: Record<string, unknown>, timeoutMs = SOCKET_TIMEOUT_MS): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(SOCKET_PATH)
    let done = false
    let buffer = ''
    const timer = setTimeout(() => {
      if (done) return
      done = true
      socket.destroy()
      reject(new Error(`relay RPC timeout: ${String(request.verb ?? 'unknown')}`))
    }, timeoutMs)

    function finish(err: Error | null, payload?: Record<string, unknown>): void {
      if (done) return
      done = true
      clearTimeout(timer)
      socket.destroy()
      if (err) reject(err)
      else resolve(payload ?? {})
    }

    socket.on('connect', () => {
      socket.write(JSON.stringify(request) + '\n')
    })
    socket.on('data', chunk => {
      buffer += chunk.toString('utf8')
      const newline = buffer.indexOf('\n')
      if (newline < 0) return
      const raw = buffer.slice(0, newline)
      try {
        const payload = JSON.parse(raw)
        if (!payload || typeof payload !== 'object') throw new Error('relay response was not an object')
        finish(null, payload as Record<string, unknown>)
      } catch (err) {
        finish(err as Error)
      }
    })
    socket.on('error', err => finish(err))
    socket.on('close', () => {
      if (!done) finish(new Error('relay socket closed before response'))
    })
  })
}

async function waitForRelayReady(timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const health = await relayRpc({ verb: 'health' }, 1000)
      if (health.ok) return true
    } catch {}
    await sleep(100)
  }
  return false
}

async function ensureRelayRunning(): Promise<void> {
  registerTokenFile()
  if (existsSync(SOCKET_PATH) && await waitForRelayReady(1000)) return
  if (process.env.BRIDGE_TELEGRAM_RELAY_AUTOSPAWN === '1') {
    const result = spawnSync(
      agentBridgeCli(),
      ['telegram-relay', 'start', '--token-file', tokenFilePath()],
      {
        env: { ...process.env, BRIDGE_HOME, BRIDGE_STATE_DIR },
        encoding: 'utf8',
      },
    )
    if (result.status !== 0) {
      throw new Error(`failed to autospawn telegram relay: ${result.stderr || result.stdout}`)
    }
  }
  if (!await waitForRelayReady(5000)) {
    throw new Error(`telegram relay daemon is not available at ${SOCKET_PATH}; enable BRIDGE_TELEGRAM_RELAY_ENABLED=1 or set BRIDGE_TELEGRAM_RELAY_AUTOSPAWN=1`)
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function str(value: unknown): string {
  return String(value ?? '').trim()
}

function messageFromUpdate(update: TelegramUpdate): TelegramMessage | null {
  return update.message ?? update.edited_message ?? update.channel_post ?? update.edited_channel_post ?? null
}

function senderName(user?: TelegramUser): string {
  if (!user) return 'telegram-user'
  if (user.username) return `@${user.username}`
  return [user.first_name, user.last_name].filter(Boolean).join(' ').trim() || str(user.id) || 'telegram-user'
}

function messageText(message: TelegramMessage): string {
  const text = str(message.text || message.caption)
  if (text) return text
  if (message.photo?.length) return '[photo]'
  if (message.document) return `[document: ${message.document.file_name ?? 'file'}]`
  if (message.voice) return '[voice message]'
  if (message.audio) return `[audio: ${message.audio.file_name ?? 'audio'}]`
  if (message.video) return `[video: ${message.video.file_name ?? 'video'}]`
  if (message.video_note) return '[video note]'
  if (message.sticker) return `[sticker: ${message.sticker.emoji ?? 'sticker'}]`
  return '[unsupported Telegram message]'
}

function attachmentMeta(message: TelegramMessage): Record<string, string> {
  if (message.photo?.length) {
    const photo = [...message.photo].sort((a, b) => Number(b.file_size ?? 0) - Number(a.file_size ?? 0))[0]
    return { attachment_kind: 'photo', attachment_file_id: str(photo?.file_id) }
  }
  const doc = message.document ?? message.voice ?? message.audio ?? message.video ?? message.video_note ?? message.sticker
  if (doc?.file_id) {
    return {
      attachment_kind: message.document ? 'document' : message.voice ? 'voice' : message.audio ? 'audio' : message.video ? 'video' : message.video_note ? 'video_note' : 'sticker',
      attachment_file_id: str(doc.file_id),
      ...(message.document?.file_name ? { attachment_name: message.document.file_name } : {}),
      ...(message.audio?.file_name ? { attachment_name: message.audio.file_name } : {}),
      ...((doc as { mime_type?: string }).mime_type ? { attachment_mime_type: str((doc as { mime_type?: string }).mime_type) } : {}),
    }
  }
  return {}
}

function userAllowed(policyIds: string[] | undefined, userIds: string[]): boolean {
  const allow = policyIds ?? []
  if (allow.length === 0) return true
  return userIds.some(id => allow.includes(id))
}

function mentioned(message: TelegramMessage, access: Access): boolean {
  const text = messageText(message)
  const entities = [...(message.entities ?? []), ...(message.caption_entities ?? [])]
  if (entities.some(entity => entity.type === 'mention' || entity.type === 'text_mention')) {
    if (!BOT_USERNAME) return true
    return text.toLowerCase().includes(`@${BOT_USERNAME.toLowerCase()}`)
  }
  if (message.reply_to_message?.from?.is_bot) return true
  for (const pattern of access.mentionPatterns ?? []) {
    try {
      if (new RegExp(pattern, 'i').test(text)) return true
    } catch {}
  }
  return false
}

function gate(update: TelegramUpdate): { ok: true; message: TelegramMessage; meta: Record<string, string> } | { ok: false } {
  const message = messageFromUpdate(update)
  if (!message?.chat) return { ok: false }
  const access = loadAccess()
  if (access.dmPolicy === 'disabled') return { ok: false }

  const chatId = str(message.chat.id)
  const senderId = str(message.from?.id)
  const userIds = [senderId, chatId].filter(Boolean)
  const chatType = str(message.chat.type)
  const groupPolicy = access.groups?.[chatId]

  if (groupPolicy) {
    if (!userAllowed(groupPolicy.allowFrom, userIds)) return { ok: false }
    if (groupPolicy.requireMention !== false && !mentioned(message, access)) return { ok: false }
  } else if (chatType === 'private' || !chatType) {
    if (access.dmPolicy === 'open') {
      // allowed
    } else if (!userIds.some(id => (access.allowFrom ?? []).includes(id))) {
      return { ok: false }
    }
  } else {
    return { ok: false }
  }

  return {
    ok: true,
    message,
    meta: {
      source: 'telegram',
      chat_id: chatId,
      message_id: str(message.message_id),
      user: senderName(message.from),
      user_id: senderId,
      ts: message.date ? new Date(Number(message.date) * 1000).toISOString() : new Date().toISOString(),
      ...attachmentMeta(message),
    },
  }
}

function channelEnvelope(content: string, meta: Record<string, string>): string {
  const attrs = Object.entries(meta)
    .filter(([, value]) => value !== '')
    .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
    .join(' ')
  return `<channel ${attrs}>${content}</channel>`
}

function storeMessage(content: string, meta: Record<string, string>): void {
  const row: StoredMessage = {
    chat_id: meta.chat_id,
    message_id: meta.message_id,
    user: meta.user,
    user_id: meta.user_id,
    text: content,
    ts: meta.ts,
  }
  appendJsonLine(MESSAGES_FILE, row)
}

let mcpConnected = false
const recent = new Set<string>()
const mcp = new Server(
  { name: 'telegram-relay', version: '0.1.0' },
  {
    capabilities: {
      tools: {},
      experimental: {
        'claude/channel': {},
        'claude/channel/permission': {},
      },
    },
    instructions: [
      'Telegram relay channel for Claude Code.',
      'Messages from Telegram arrive as <channel source="telegram" chat_id="..." message_id="..." user="..." ts="...">.',
      'Reply with the reply tool. Pass chat_id from the inbound message and optional reply_to for Telegram threading.',
      'This plugin does not own Telegram polling; Agent Bridge telegram-relay daemon owns getUpdates and fan-out.',
    ].join('\n'),
  },
)

async function dispatchInbound(content: string, meta: Record<string, string>): Promise<void> {
  const envelope = channelEnvelope(content, meta)
  if ((DISPATCH_MODE === 'mcp' || DISPATCH_MODE === 'both') && mcpConnected) {
    await mcp.notification({
      method: 'notifications/claude/channel',
      params: { content, meta },
    })
  }
  if (DISPATCH_MODE === 'urgent' || DISPATCH_MODE === 'both') {
    if (!ROUTE_AGENT) {
      process.stderr.write('telegram-relay channel: TELEGRAM_RELAY_AGENT or BRIDGE_AGENT_ID required for urgent dispatch\n')
      return
    }
    const result = spawnSync(agentBridgeCli(), ['urgent', ROUTE_AGENT, envelope], {
      env: { ...process.env, BRIDGE_HOME, BRIDGE_STATE_DIR },
      encoding: 'utf8',
    })
    if (result.status !== 0) {
      process.stderr.write(`telegram-relay channel: urgent dispatch failed: ${result.stderr || result.stdout}\n`)
    }
  }
}

async function handleUpdate(update: TelegramUpdate): Promise<void> {
  const gated = gate(update)
  if (!gated.ok) return
  const content = messageText(gated.message)
  const key = `${gated.meta.chat_id}:${gated.meta.message_id}`
  if (recent.has(key)) return
  recent.add(key)
  if (recent.size > 512) recent.delete(recent.values().next().value)

  const guarded = runPromptGuard('scan', content)
  if (guarded?.blocked) return
  storeMessage(content, gated.meta)
  await dispatchInbound(content, gated.meta)
}

async function replyTool(args: Record<string, unknown>): Promise<ToolResult> {
  const chatId = str(args.chat_id)
  let text = str(args.text)
  const replyTo = args.reply_to ?? args.reply_to_message_id
  if (!chatId) throw new Error('chat_id is required')
  if (!text) throw new Error('text is required')
  if (Array.isArray(args.files) && args.files.length > 0) {
    return { content: [{ type: 'text', text: 'error: files are not supported by telegram-relay daemon phase 2' }], isError: true }
  }
  outboundGate(chatId)
  const guarded = runPromptGuard('sanitize', text)
  if (guarded?.blocked) {
    text = '[Agent Bridge] outbound reply blocked by prompt guard.'
  } else if (guarded?.was_modified && typeof guarded.sanitized_text === 'string') {
    text = guarded.sanitized_text
  }
  await ensureRelayRunning()
  const response = await relayRpc({
    verb: 'send_message',
    chat_id: chatId,
    text,
    ...(replyTo != null && str(replyTo) ? { reply_to: Number(replyTo) } : {}),
  })
  if (!response.ok) {
    return { content: [{ type: 'text', text: `error: ${JSON.stringify(response)}` }], isError: true }
  }
  return { content: [{ type: 'text', text: JSON.stringify(response.response ?? response) }] }
}

function unsupportedTool(name: string): ToolResult {
  return {
    content: [
      {
        type: 'text',
        text: `error: ${name} is registered for Telegram tool compatibility but is not supported by telegram-relay daemon phase 2`,
      },
    ],
    isError: true,
  }
}

function outboundGate(chatId: string): void {
  const access = loadAccess()
  if ((access.allowFrom ?? []).includes(chatId)) return
  if (access.groups?.[chatId]) return
  if (access.defaultChatId && access.defaultChatId === chatId) return
  throw new Error(`chat ${chatId} is not allowlisted`)
}

const tools = [
  {
    name: 'reply',
    description: 'Reply on Telegram through the Agent Bridge relay daemon. Pass chat_id from the inbound message. Optional reply_to threads under an earlier message.',
    inputSchema: {
      type: 'object',
      properties: {
        chat_id: { type: 'string', description: 'Telegram chat id from inbound meta.chat_id.' },
        text: { type: 'string', description: 'Message text to send.' },
        reply_to: { type: 'string', description: 'Optional Telegram message id to reply under.' },
        files: { type: 'array', items: { type: 'string' }, description: 'Reserved for upstream compatibility; not supported by the relay daemon yet.' },
      },
      required: ['chat_id', 'text'],
    },
  },
  {
    name: 'react',
    description: 'Compatibility placeholder for Telegram reactions. Not supported by the relay daemon yet.',
    inputSchema: {
      type: 'object',
      properties: {
        chat_id: { type: 'string' },
        message_id: { type: 'string' },
        emoji: { type: 'string' },
      },
      required: ['chat_id', 'message_id', 'emoji'],
    },
  },
  {
    name: 'download_attachment',
    description: 'Compatibility placeholder for Telegram attachment downloads. Not supported by the relay daemon yet.',
    inputSchema: {
      type: 'object',
      properties: {
        file_id: { type: 'string' },
      },
      required: ['file_id'],
    },
  },
  {
    name: 'edit_message',
    description: "Compatibility placeholder for Telegram message edits. Not supported by the relay daemon yet.",
    inputSchema: {
      type: 'object',
      properties: {
        chat_id: { type: 'string' },
        message_id: { type: 'string' },
        text: { type: 'string' },
      },
      required: ['chat_id', 'message_id', 'text'],
    },
  },
]

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools,
}))

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const args = (req.params.arguments ?? {}) as Record<string, unknown>
  try {
    switch (req.params.name) {
      case 'reply':
        return await replyTool(args)
      case 'react':
      case 'download_attachment':
      case 'edit_message':
        return unsupportedTool(req.params.name)
      default:
        throw new Error(`unknown tool: ${req.params.name}`)
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    return { content: [{ type: 'text', text: `error: ${msg}` }], isError: true }
  }
})

let shuttingDown = false
let registered = false
let sinceId = 0

async function registerClient(): Promise<void> {
  await ensureRelayRunning()
  const response = await relayRpc({
    verb: 'register',
    client_id: CLIENT_ID,
    channel_filter: {},
    since_id: 0,
  })
  if (!response.ok) throw new Error(`relay register failed: ${JSON.stringify(response)}`)
  registered = true
  process.stderr.write(`telegram-relay channel: registered client=${CLIENT_ID} token_hash=${TOKEN_HASH}\n`)
  const readyFile = process.env.TELEGRAM_RELAY_READY_FILE
  if (readyFile) writeFileSync(readyFile, `${CLIENT_ID}\n`, { mode: 0o600 })
}

async function unregisterClient(): Promise<void> {
  if (!registered) return
  try {
    await relayRpc({ verb: 'unregister', client_id: CLIENT_ID }, 1000)
  } catch {}
  registered = false
}

async function pollLoop(): Promise<void> {
  let backoffMs = 250
  await registerClient()
  while (!shuttingDown) {
    try {
      if (!registered) {
        sinceId = 0
        await registerClient()
      }
      const response = await relayRpc(
        {
          verb: 'recv',
          client_id: CLIENT_ID,
          since_id: sinceId,
          timeout_seconds: RECV_TIMEOUT_SECONDS,
        },
        (RECV_TIMEOUT_SECONDS + 5) * 1000,
      )
      if (!response.ok) throw new Error(`relay recv failed: ${JSON.stringify(response)}`)
      const updates = Array.isArray(response.updates) ? response.updates as TelegramUpdate[] : []
      for (const update of updates) {
        const id = Number(update.update_id ?? 0)
        if (Number.isFinite(id)) sinceId = Math.max(sinceId, id)
        await handleUpdate(update)
      }
      if (typeof response.cursor === 'number') sinceId = Math.max(sinceId, response.cursor)
      backoffMs = 250
    } catch (err) {
      if (shuttingDown) return
      registered = false
      process.stderr.write(`telegram-relay channel: relay disconnected: ${err instanceof Error ? err.message : err}\n`)
      await sleep(backoffMs)
      backoffMs = Math.min(backoffMs * 2, 5000)
    }
  }
}

async function gracefulShutdown(reason: string): Promise<void> {
  if (shuttingDown) return
  shuttingDown = true
  process.stderr.write(`telegram-relay channel: shutting down (${reason})\n`)
  await unregisterClient()
  process.exit(0)
}

process.on('SIGTERM', () => { void gracefulShutdown('SIGTERM') })
process.on('SIGHUP', () => { void gracefulShutdown('SIGHUP') })
process.on('SIGINT', () => { void gracefulShutdown('SIGINT') })
process.on('unhandledRejection', err => {
  process.stderr.write(`telegram-relay channel: unhandled rejection: ${err}\n`)
})
process.on('uncaughtException', err => {
  process.stderr.write(`telegram-relay channel: uncaught exception: ${err}\n`)
})

async function smokeTool(argv: string[]): Promise<void> {
  const toolIndex = argv.indexOf('--smoke-tool')
  const argsIndex = argv.indexOf('--args')
  const name = toolIndex >= 0 ? argv[toolIndex + 1] : ''
  const rawArgs = argsIndex >= 0 ? argv[argsIndex + 1] : '{}'
  const parsed = JSON.parse(rawArgs)
  const result = name === 'reply' ? await replyTool(parsed) : unsupportedTool(name || 'unknown')
  process.stdout.write(JSON.stringify(result) + '\n')
}

if (argv.includes('--smoke-tool')) {
  await smokeTool(argv)
  process.exit(0)
}

function startPollLoop(): void {
  void pollLoop().catch(err => {
    process.stderr.write(`telegram-relay channel: startup failed: ${err instanceof Error ? err.message : err}\n`)
    process.exit(1)
  })
}

if (process.env.TELEGRAM_RELAY_DISABLE_MCP !== '1') {
  await mcp.connect(new StdioServerTransport())
  mcpConnected = true
  process.stderr.write(`telegram-relay channel: MCP connected state_dir=${STATE_DIR} token_hash=${TOKEN_HASH}\n`)
  startPollLoop()
} else {
  process.stderr.write(`telegram-relay channel: MCP disabled state_dir=${STATE_DIR} token_hash=${TOKEN_HASH}\n`)
  startPollLoop()
  // Keep the process alive for the poll loop in smoke and service modes.
  await new Promise(() => {})
}
