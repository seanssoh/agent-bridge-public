export type RecentMessageDeduper = {
  seen(messageId: string): boolean
  forget(messageId: string): void
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
