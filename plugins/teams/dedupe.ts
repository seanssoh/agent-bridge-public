// Bounded in-memory deduper for inbound channel webhooks. The caller is
// responsible for choosing the key shape; the Teams server passes
// `${chat_id}::${message_id}::${revision}` so:
//   - chat_id scopes the id (Teams reuses message ids across conversations
//     for thread replies, so a bare message id can collide).
//   - message_id is the activity's stable id, the primary dedupe field.
//   - revision (Bot Framework localTimestamp / timestamp) lets Teams edits
//     through — edits keep the same message_id but bump localTimestamp.
// `forget` is exposed so the caller can roll back the dedupe entry when
// channel delivery fails and the message must be allowed to retry.
export type RecentMessageDeduper = {
  seen(messageId: string): boolean
  forget(messageId: string): void
}

// Matches a stored messages.jsonl row against an incoming activity. Two
// match shapes:
//   1. exact 3-tuple (chat_id + message_id + revision) — same edit replay
//      or same-revision retransmit.
//   2. legacy fallback (stored.revision === undefined) — pre-revision rows
//      written by older versions had no revision field; without this clause
//      a fresh-revision arrival for the same (chat_id, message_id) would
//      slip past the dedupe and double-deliver. Conservative: any row that
//      lacks revision matches regardless of incoming revision.
// The caller filters rows by chat_id+message_id before calling this.
export function storedRowMatchesIncoming(
  storedRevision: string | undefined,
  incomingRevision: string,
): boolean {
  if (storedRevision === undefined) return true
  return (storedRevision ?? '') === (incomingRevision ?? '')
}

export function createRecentMessageDeduper(limit = 256): RecentMessageDeduper {
  const queue: string[] = []
  const seenIds = new Set<string>()
  const max = Number.isFinite(limit) && limit > 0 ? Math.floor(limit) : 256

  return {
    seen(messageId: string): boolean {
      const id = String(messageId || '').trim()
      if (!id) return false
      if (seenIds.has(id)) return true
      queue.push(id)
      seenIds.add(id)
      while (queue.length > max) {
        const removed = queue.shift()
        if (removed) seenIds.delete(removed)
      }
      return false
    },
    forget(messageId: string): void {
      const id = String(messageId || '').trim()
      if (!id || !seenIds.delete(id)) return
      const idx = queue.indexOf(id)
      if (idx >= 0) queue.splice(idx, 1)
    },
  }
}
