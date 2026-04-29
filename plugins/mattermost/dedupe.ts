export type RecentMessageDeduper = {
  seen(messageId: string): boolean
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
  }
}
