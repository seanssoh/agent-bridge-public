/**
 * Mattermost WebSocket monitor — single-connection lifecycle.
 *
 * Adapted from openclaw/openclaw (MIT, Copyright (c) 2025 Peter Steinberger):
 *   extensions/mattermost/src/mattermost/monitor-websocket.ts
 *
 * Differences from the original:
 *   - Removed openclaw plugin SDK dependencies (zod schema validation,
 *     debug-proxy capture instrumentation, runtime/account snapshot types
 *     are simplified to local definitions).
 *   - Schema validation replaced with shape-checked JSON.parse — Mattermost
 *     event payloads are trusted enough for shape coercion.
 *   - `rawDataToString` inlined (was in monitor-helpers.ts).
 *
 * Keeps verbatim:
 *   - The auth-challenge seq protocol (Mattermost expects this as the
 *     first frame after the WS opens; without it the server stops sending
 *     events even though the socket stays connected).
 *   - The 30s health-check loop polling the bot account `update_at`
 *     (catches the silent-disconnect-after-bot-disable/enable cycle).
 *   - The opened-vs-not-opened close handling — opens that close cleanly
 *     resolve so the reconnect loop resets backoff; closes before open
 *     reject so backoff increases.
 */

import { randomUUID } from "node:crypto"
import WebSocket from "ws"

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/**
 * Subset of Mattermost's Post payload that we actually consume. Mattermost
 * also returns many more fields (props, metadata, hashtags, etc.); they
 * pass through as `[key: string]: unknown` for downstream code that needs
 * them.
 */
export type MattermostPost = {
  id: string
  user_id: string
  channel_id: string
  message: string
  create_at?: number
  update_at?: number
  type?: string
  props?: Record<string, unknown>
  root_id?: string
  parent_id?: string
  [key: string]: unknown
}

export type MattermostEventPayload = {
  event?: string
  data?: {
    post?: string | MattermostPost
    reaction?: string | Record<string, unknown>
    channel_id?: string
    channel_name?: string
    channel_display_name?: string
    channel_type?: string
    sender_name?: string
    team_id?: string
    mentions?: string
  }
  broadcast?: {
    channel_id?: string
    team_id?: string
    user_id?: string
  }
}

export type ChannelAccountSnapshot = {
  connected?: boolean
  lastConnectedAt?: number
  lastError?: string | null
  lastDisconnect?: { at: number; status: number; error?: string }
}

export type RuntimeEnv = {
  log?: (msg: string) => void
  error?: (msg: string) => void
}

export type MattermostWebSocketLike = {
  on(event: "open", listener: () => void): void
  on(event: "message", listener: (data: WebSocket.RawData) => void | Promise<void>): void
  on(event: "close", listener: (code: number, reason: Buffer) => void): void
  on(event: "error", listener: (err: unknown) => void): void
  send(data: string): void
  close(): void
  terminate(): void
}

export type MattermostWebSocketFactory = (url: string) => MattermostWebSocketLike

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function rawDataToString(data: WebSocket.RawData): string {
  if (typeof data === "string") {
    return data
  }
  if (Buffer.isBuffer(data)) {
    return data.toString("utf8")
  }
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data).toString("utf8")
  }
  if (Array.isArray(data)) {
    return Buffer.concat(data as Buffer[]).toString("utf8")
  }
  return String(data)
}

function parseMattermostEventPayload(raw: string): MattermostEventPayload | null {
  try {
    const parsed = JSON.parse(raw)
    if (parsed && typeof parsed === "object") {
      return parsed as MattermostEventPayload
    }
  } catch {
    /* fall through */
  }
  return null
}

function parseMattermostPost(value: unknown): MattermostPost | null {
  if (typeof value === "string") {
    try {
      const parsed = JSON.parse(value)
      if (
        parsed &&
        typeof parsed === "object" &&
        typeof (parsed as { id?: unknown }).id === "string"
      ) {
        return parsed as MattermostPost
      }
    } catch {
      /* fall through */
    }
    return null
  }
  if (
    value &&
    typeof value === "object" &&
    typeof (value as { id?: unknown }).id === "string"
  ) {
    return value as MattermostPost
  }
  return null
}

export class WebSocketClosedBeforeOpenError extends Error {
  constructor(
    public readonly code: number,
    public readonly reason?: string,
  ) {
    super(`websocket closed before open (code ${code})`)
    this.name = "WebSocketClosedBeforeOpenError"
  }
}

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

export type CreateMattermostConnectOnceOpts = {
  wsUrl: string
  botToken: string
  abortSignal?: AbortSignal
  statusSink?: (patch: Partial<ChannelAccountSnapshot>) => void
  runtime: RuntimeEnv
  nextSeq: () => number
  onPosted: (post: MattermostPost, payload: MattermostEventPayload) => Promise<void>
  onReaction?: (payload: MattermostEventPayload) => Promise<void>
  webSocketFactory?: MattermostWebSocketFactory
  /**
   * Called periodically to check whether the bot account has been modified
   * (e.g. disabled then re-enabled) since the WebSocket was opened. Returns
   * the bot's current `update_at` timestamp. When it differs from the value
   * recorded at connect time, the connection is terminated so the reconnect
   * loop can establish a fresh one.
   */
  getBotUpdateAt?: () => Promise<number>
  healthCheckIntervalMs?: number
}

export const defaultMattermostWebSocketFactory: MattermostWebSocketFactory = (url) => {
  return new WebSocket(url) as unknown as MattermostWebSocketLike
}

export function parsePostedPayload(
  payload: MattermostEventPayload,
): { payload: MattermostEventPayload; post: MattermostPost } | null {
  if (payload.event !== "posted") {
    return null
  }
  const postData = payload.data?.post
  if (!postData) {
    return null
  }
  const post = parseMattermostPost(postData)
  if (!post) {
    return null
  }
  return { payload, post }
}

export function parsePostedEvent(
  data: WebSocket.RawData,
): { payload: MattermostEventPayload; post: MattermostPost } | null {
  const raw = rawDataToString(data)
  const payload = parseMattermostEventPayload(raw)
  if (!payload) {
    return null
  }
  return parsePostedPayload(payload)
}

export function createMattermostConnectOnce(
  opts: CreateMattermostConnectOnceOpts,
): () => Promise<void> {
  const webSocketFactory = opts.webSocketFactory ?? defaultMattermostWebSocketFactory
  const healthCheckIntervalMs = opts.healthCheckIntervalMs ?? 30_000
  return async () => {
    // flowId is kept for forward-compat (was used by openclaw debug capture).
    // Logged only on errors so an operator can correlate one connection's
    // events across log lines.
    const flowId = randomUUID()
    const ws = webSocketFactory(opts.wsUrl)
    const onAbort = () => ws.terminate()
    opts.abortSignal?.addEventListener("abort", onAbort, { once: true })
    const getBotUpdateAt = opts.getBotUpdateAt

    try {
      return await new Promise<void>((resolve, reject) => {
        let opened = false
        let settled = false
        let healthCheckEnabled = getBotUpdateAt != null
        let healthCheckInFlight = false
        let healthCheckTimer: ReturnType<typeof setTimeout> | undefined
        let initialUpdateAt: number | undefined

        const clearTimers = () => {
          if (healthCheckTimer !== undefined) {
            clearTimeout(healthCheckTimer)
            healthCheckTimer = undefined
          }
        }

        const stopHealthChecks = () => {
          healthCheckEnabled = false
          clearTimers()
        }

        const scheduleHealthCheck = () => {
          if (!getBotUpdateAt || !healthCheckEnabled || settled || healthCheckInFlight) {
            return
          }
          healthCheckTimer = setTimeout(() => {
            healthCheckTimer = undefined
            void runHealthCheck()
          }, healthCheckIntervalMs)
        }

        const runHealthCheck = async () => {
          if (!getBotUpdateAt || !healthCheckEnabled || settled || healthCheckInFlight) {
            return
          }
          healthCheckInFlight = true
          try {
            const current = await getBotUpdateAt()
            if (!healthCheckEnabled || settled) {
              return
            }
            if (initialUpdateAt === undefined) {
              initialUpdateAt = current
              return
            }
            if (current !== initialUpdateAt) {
              opts.runtime.log?.(
                `mattermost: bot account updated (update_at changed: ${initialUpdateAt} → ${current}) — reconnecting [flow=${flowId}]`,
              )
              stopHealthChecks()
              ws.terminate()
            }
          } catch (err) {
            if (!healthCheckEnabled || settled) {
              return
            }
            const label =
              initialUpdateAt === undefined
                ? "mattermost: failed to get initial update_at"
                : "mattermost: health check error"
            opts.runtime.error?.(`${label}: ${String(err)} [flow=${flowId}]`)
          } finally {
            healthCheckInFlight = false
            scheduleHealthCheck()
          }
        }

        const resolveOnce = () => {
          if (settled) {
            return
          }
          settled = true
          stopHealthChecks()
          resolve()
        }
        const rejectOnce = (error: Error) => {
          if (settled) {
            return
          }
          settled = true
          stopHealthChecks()
          reject(error)
        }

        ws.on("open", () => {
          opened = true
          opts.statusSink?.({
            connected: true,
            lastConnectedAt: Date.now(),
            lastError: null,
          })
          const authPayload = JSON.stringify({
            seq: opts.nextSeq(),
            action: "authentication_challenge",
            data: { token: opts.botToken },
          })
          ws.send(authPayload)

          // Periodically check if the bot account was modified (e.g.
          // disable/enable). After such a cycle the WebSocket silently
          // stops delivering events even though the connection itself
          // stays alive. Comparing update_at detects this reliably
          // regardless of how quickly the cycle happens.
          if (getBotUpdateAt) {
            void runHealthCheck()
          }
        })

        ws.on("message", async (data) => {
          const raw = rawDataToString(data)
          const payload = parseMattermostEventPayload(raw)
          if (!payload) {
            return
          }

          if (payload.event === "reaction_added" || payload.event === "reaction_removed") {
            if (!opts.onReaction) {
              return
            }
            try {
              await opts.onReaction(payload)
            } catch (err) {
              opts.runtime.error?.(`mattermost reaction handler failed: ${String(err)}`)
            }
            return
          }

          if (payload.event !== "posted") {
            return
          }
          const parsed = parsePostedPayload(payload)
          if (!parsed) {
            return
          }
          try {
            await opts.onPosted(parsed.post, parsed.payload)
          } catch (err) {
            opts.runtime.error?.(`mattermost handler failed: ${String(err)}`)
          }
        })

        ws.on("close", (code, reason) => {
          stopHealthChecks()
          const message = reasonToString(reason)
          opts.statusSink?.({
            connected: false,
            lastDisconnect: {
              at: Date.now(),
              status: code,
              error: message || undefined,
            },
          })
          if (opened) {
            resolveOnce()
            return
          }
          rejectOnce(new WebSocketClosedBeforeOpenError(code, message || undefined))
        })

        ws.on("error", (err) => {
          opts.runtime.error?.(`mattermost websocket error: ${String(err)} [flow=${flowId}]`)
          opts.statusSink?.({
            lastError: String(err),
          })
          try {
            ws.close()
          } catch {
            /* swallow — ws already in error state */
          }
        })
      })
    } finally {
      opts.abortSignal?.removeEventListener("abort", onAbort)
    }
  }
}

function reasonToString(reason: Buffer | string | undefined): string {
  if (!reason) {
    return ""
  }
  if (typeof reason === "string") {
    return reason
  }
  return reason.length > 0 ? reason.toString("utf8") : ""
}
