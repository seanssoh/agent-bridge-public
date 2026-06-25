// bun test for the `reply` outbound result classifier (#2112 — Teams reply
// silent non-delivery). Run: `bun test` in plugins/teams/.
//
// Coverage: the three Bot Framework outcomes the reply text-only path must
// distinguish — confirmed (non-empty ResourceResponse.id), unconfirmed (awaited
// OK but empty/absent id), and failed (sendActivity threw) — plus the
// backward-compatibility invariant (confirmed still starts with `sent:`) and
// the single-line audit-row contract. These assertions are written to FAIL if
// the regression that shipped to production (return a bare `sent:` regardless
// of the message id) is reintroduced.

import { describe, expect, test } from 'bun:test'
import { classifyReplyOutcome } from './outbound-result.ts'

describe('classifyReplyOutcome', () => {
  test('confirmed delivery: non-empty message id → backward-compatible sent: with message_id', () => {
    const out = classifyReplyOutcome({
      chatId: 'chat-1',
      convId: 'conv-1',
      sentId: 'abc',
      attachmentCount: 0,
    })
    expect(out.ok).toBe(true)
    expect(out.throw).toBe(false)
    // Backward-compat: existing parsers split on `sent:` — must still match.
    expect(out.resultText.startsWith('sent:')).toBe(true)
    expect(out.resultText).toBe('sent: chat-1 message_id=abc')
    expect(out.auditLine).toBe(
      'teams channel: teams_outbound_reply ok=true conversation_id=conv-1 message_id=abc attachment_count=0 error=',
    )
  })

  test('confirmed delivery with attachment: id captured, attachment_count surfaced', () => {
    const out = classifyReplyOutcome({
      chatId: 'chat-2',
      convId: 'conv-2',
      sentId: 'mid-77',
      attachmentCount: 1,
    })
    expect(out.ok).toBe(true)
    expect(out.resultText).toBe('sent: chat-2 message_id=mid-77')
    expect(out.auditLine).toContain('attachment_count=1')
  })

  test('unconfirmed: empty message id → teams_reply_unconfirmed, NEVER a bare sent:', () => {
    const out = classifyReplyOutcome({
      chatId: 'chat-3',
      convId: 'conv-3',
      sentId: '',
      attachmentCount: 0,
    })
    expect(out.ok).toBe(false)
    expect(out.throw).toBe(false)
    expect(out.resultText.startsWith('teams_reply_unconfirmed:')).toBe(true)
    expect(out.resultText).toContain('conversation=conv-3')
    // Mutation-proof: the production regression returned `sent:` here.
    expect(out.resultText.startsWith('sent:')).toBe(false)
    expect(out.auditLine).toContain('ok=false')
    expect(out.auditLine).toContain('message_id= ')
  })

  test('unconfirmed: whitespace-only message id is treated as empty', () => {
    const out = classifyReplyOutcome({
      chatId: 'chat-4',
      convId: 'conv-4',
      sentId: '   ',
      attachmentCount: 0,
    })
    expect(out.ok).toBe(false)
    expect(out.resultText.startsWith('teams_reply_unconfirmed:')).toBe(true)
  })

  test('failed: sendActivity threw → caller throws teams_reply_failed, no sent:', () => {
    const out = classifyReplyOutcome({
      chatId: 'chat-5',
      convId: 'conv-5',
      sentId: '',
      sendErr: new Error('connector 502'),
      attachmentCount: 0,
    })
    expect(out.ok).toBe(false)
    expect(out.throw).toBe(true)
    expect(out.errorText).toBe('teams_reply_failed: connector 502')
    expect(out.resultText).toBe('')
    expect(out.auditLine).toContain('ok=false')
    expect(out.auditLine).toContain('error=connector 502')
  })

  test('failed: a captured id is NOT reported as success when sendErr is present', () => {
    // Defensive: even if a partial id was captured before the throw, an error
    // must win — ok=false and the caller throws.
    const out = classifyReplyOutcome({
      chatId: 'chat-6',
      convId: 'conv-6',
      sentId: 'partial',
      sendErr: new Error('boom'),
      attachmentCount: 0,
    })
    expect(out.ok).toBe(false)
    expect(out.throw).toBe(true)
  })

  test('audit row is single-line: newlines in the error are collapsed', () => {
    const out = classifyReplyOutcome({
      chatId: 'chat-7',
      convId: 'conv-7',
      sentId: '',
      sendErr: new Error('line1\nline2\r\nline3'),
      attachmentCount: 0,
    })
    expect(out.auditLine.includes('\n')).toBe(false)
    expect(out.auditLine.includes('\r')).toBe(false)
    expect(out.auditLine).toContain('error=line1 line2 line3')
  })

  test('audit row stays single-line when the message id / conversation id carry newlines', () => {
    // A crafted ResourceResponse.id or conversation id must not split the audit
    // row into multiple lines or spoof later fields. (codex r1 BLOCKING)
    const out = classifyReplyOutcome({
      chatId: 'chat-8',
      convId: 'conv-8\nattachment_count=999 error=injected',
      sentId: 'mid\nok=true conversation_id=spoof',
      attachmentCount: 0,
    })
    expect(out.auditLine.includes('\n')).toBe(false)
    expect(out.auditLine.includes('\r')).toBe(false)
    expect(out.auditLine.split('\n').length).toBe(1)
    // The confirmed tool result must also stay single-line.
    expect(out.resultText.includes('\n')).toBe(false)
  })

  test('field values are length-bounded (no unbounded id blows the audit row)', () => {
    const out = classifyReplyOutcome({
      chatId: 'c',
      convId: 'x'.repeat(5000),
      sentId: 'y'.repeat(5000),
      attachmentCount: 0,
    })
    // sentId/convId are each capped at 256.
    expect(out.auditLine.length).toBeLessThan(1200)
  })
})
