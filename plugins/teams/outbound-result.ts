// Outbound `reply` result classification (#2112).
//
// The Teams `reply` text-only path used to return `sent: <chatId>` as soon as
// `context.sendActivity(...)` awaited without throwing — discarding the Bot
// Framework `ResourceResponse.id` and emitting no audit. A reply that the SDK
// accepted but never delivered (empty/absent message id) read as success, so a
// silent non-delivery looked green to the agent, the operator, and watchdog.
//
// This module is the pure, side-effect-free classifier the reply path calls to
// turn the send outcome into (a) a single grep-greppable audit row and (b) the
// caller-facing tool result. It is split out of server.ts (which has top-level
// HTTP-listen / MCP-connect side effects and cannot be imported in a unit test)
// so the three Bot Framework outcomes can be asserted directly — mirroring how
// cardintent.ts isolates the renderer.

export type ReplyOutcome = {
  /** true only when sendActivity resolved AND returned a non-empty message id. */
  ok: boolean
  /** single-line audit row (mirrors emitMcpDeliveryFailurePermanent's format). */
  auditLine: string
  /** when true the caller should throw errorText (sendActivity threw). */
  throw: boolean
  /** the message to throw when `throw` is true; '' otherwise. */
  errorText: string
  /** the tool-result text when `throw` is false; '' when `throw` is true. */
  resultText: string
}

/**
 * Classify the outcome of a `reply` text-only outbound send.
 *
 *   - confirmed   → ResourceResponse.id present, no error → `sent: … message_id=…`
 *                   (kept backward-compatible: still starts with `sent:` so
 *                    existing parsers don't break, adds message_id)
 *   - unconfirmed → awaited OK but no message id           → `teams_reply_unconfirmed: …`
 *                   (NEVER a bare `sent:`)
 *   - failed      → sendActivity threw                     → throw `teams_reply_failed: …`
 */
export function classifyReplyOutcome(input: {
  chatId: string
  convId: string
  sentId: string
  sendErr?: unknown
  attachmentCount: number
}): ReplyOutcome {
  // Collapse newlines + bound length on every externally-sourced field that is
  // interpolated into the single-line audit row (and into the tool result).
  // The Bot Framework message id and the stored conversation id are untrusted
  // strings; an embedded newline would otherwise split the `teams_outbound_reply`
  // row into multiple lines and let a crafted id spoof later audit fields.
  const oneLine = (v: unknown, max: number): string =>
    String(v ?? '').replace(/[\r\n]+/g, ' ').slice(0, max)
  const sentId = oneLine(input.sentId, 256).trim()
  const convId = oneLine(input.convId, 256)
  const chatId = oneLine(input.chatId, 256)
  const sanitizedErr = oneLine((input.sendErr as Error)?.message ?? input.sendErr, 512)
  const ok = !input.sendErr && sentId.length > 0
  const auditLine =
    `teams channel: teams_outbound_reply`
    + ` ok=${ok}`
    + ` conversation_id=${convId}`
    + ` message_id=${sentId}`
    + ` attachment_count=${input.attachmentCount}`
    + ` error=${sanitizedErr}`
  if (input.sendErr) {
    return { ok, auditLine, throw: true, errorText: `teams_reply_failed: ${sanitizedErr}`, resultText: '' }
  }
  if (!sentId) {
    return {
      ok,
      auditLine,
      throw: false,
      errorText: '',
      resultText:
        `teams_reply_unconfirmed: sendActivity returned no message id; ` +
        `delivery not confirmed (conversation=${convId})`,
    }
  }
  return { ok, auditLine, throw: false, errorText: '', resultText: `sent: ${chatId} message_id=${sentId}` }
}
