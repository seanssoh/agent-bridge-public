// bun test for the cardintent fence parser + quoteResult Adaptive Card
// renderer (Model B). Run: `bun test` in plugins/teams/.
//
// Coverage: fence extraction (last-of-many / none / malformed), CardIntent
// validation (accept valid; reject bad valueState / actionId / non-string
// value), valueState→render mapping, the §10 forbidden-key golden (forbidden
// key → reject/text-fallback; clean → pass), list vs detail render shape
// (AC v1.2, NO Table / targetWidth, ColumnSet≤3), and the graceful never-throw
// fallback. The §10 + graceful-fallback assertions are written to FAIL if their
// guard is reverted (mutation-proof — see the comments on those tests).

import { describe, expect, test } from 'bun:test'
import {
  ACTION_IDS,
  buildAdaptiveCard,
  extractLastCardIntentFence,
  findForbiddenCostKey,
  FORBIDDEN_COST_KEYS_PLACEHOLDER,
  isDetailLayout,
  renderOutbound,
  renderValueState,
  stripAllCardIntentFences,
  stripFence,
  validateCardIntent,
  type CardIntent,
  type Row,
} from './cardintent.ts'

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

function validListIntent(): CardIntent {
  return {
    kind: 'quoteResult',
    title: 'RFQ 견적 결과',
    sections: [
      {
        label: 'A사·세럼A 세트✓',
        rows: [
          { label: '내용물', value: '₩1,200', valueState: 'value' },
          { label: '가공비', value: '₩300', valueState: 'value' },
          { label: '견적소계', value: '₩1,500', valueState: 'value' },
        ],
        actions: [
          { actionId: 'openQuoteResultDetail', label: '상세', payload: { quoteId: 'q1' } },
          { actionId: 'selectForQuoteDoc', label: '선택', payload: { quoteId: 'q1' } },
        ],
      },
      {
        label: 'B사·크림B',
        rows: [
          { label: '내용물', value: '₩2,000', valueState: 'calculating' },
          { label: '가공비', value: '₩500', valueState: 'value' },
          { label: '견적소계', value: '₩2,500', valueState: 'masked' },
        ],
      },
    ],
    actions: [{ actionId: 'loadMoreQuotes', label: '더보기', payload: {} }],
    fallbackMarkdown: 'A사 ₩1,500 / B사 (계산중)',
  }
}

function validDetailIntent(): CardIntent {
  return {
    kind: 'quoteResult',
    title: '견적 상세',
    sections: [
      {
        label: '기본식별',
        rows: [{ label: '계정', value: 'A사', valueState: 'value' }],
      },
      {
        label: '사양',
        rows: [{ label: '용량', value: '50ml', valueState: 'value' }],
      },
      {
        label: '금액강조',
        rows: [
          { label: '견적소계', value: '₩1,500', valueState: 'value' },
          { label: '단가', value: '', valueState: 'masked' },
        ],
      },
      {
        label: '결재',
        rows: [{ label: '상태', value: '대기', valueState: 'notRequested' }],
      },
    ],
    actions: [{ actionId: 'openApprovalTrail', label: '결재내역', payload: { quoteId: 'q1' } }],
    fallbackMarkdown: 'A사 견적 상세',
  }
}

function fence(jsonObj: unknown): string {
  return '```cardintent\n' + JSON.stringify(jsonObj, null, 2) + '\n```'
}

// ---------------------------------------------------------------------------
// Fence extraction
// ---------------------------------------------------------------------------

describe('extractLastCardIntentFence', () => {
  test('returns null when no fence is present', () => {
    expect(extractLastCardIntentFence('plain text, no fence here')).toBeNull()
    expect(extractLastCardIntentFence('')).toBeNull()
  })

  test('does not match a plain ```json code block', () => {
    expect(extractLastCardIntentFence('```json\n{"a":1}\n```')).toBeNull()
  })

  test('extracts the single fence body', () => {
    const text = '여기 견적입니다.\n\n' + fence({ kind: 'quoteResult' })
    const m = extractLastCardIntentFence(text)
    expect(m).not.toBeNull()
    expect(JSON.parse(m!.body).kind).toBe('quoteResult')
  })

  test('uses the LAST of many cardintent fences', () => {
    const text =
      fence({ kind: 'quoteResult', n: 1 }) +
      '\nmiddle\n' +
      fence({ kind: 'quoteResult', n: 2 }) +
      '\ntail\n' +
      fence({ kind: 'quoteResult', n: 3 })
    const m = extractLastCardIntentFence(text)
    expect(m).not.toBeNull()
    expect(JSON.parse(m!.body).n).toBe(3)
  })

  test('malformed (unterminated) fence does not match', () => {
    const text = '```cardintent\n{ "kind": "quoteResult"'
    expect(extractLastCardIntentFence(text)).toBeNull()
  })

  test('is callable repeatedly without lastIndex bleed (global regex reset)', () => {
    const text = fence({ kind: 'quoteResult', n: 1 })
    expect(extractLastCardIntentFence(text)).not.toBeNull()
    // Second call must also find it — proves FENCE_RE.lastIndex is reset.
    expect(extractLastCardIntentFence(text)).not.toBeNull()
  })
})

describe('stripFence', () => {
  test('removes the fence span and trims the seam', () => {
    const f = fence({ kind: 'quoteResult' })
    const text = '요약 텍스트입니다.\n\n' + f
    const m = extractLastCardIntentFence(text)!
    const stripped = stripFence(text, m.full)
    expect(stripped).toBe('요약 텍스트입니다.')
    expect(stripped).not.toContain('cardintent')
    expect(stripped).not.toContain('```')
  })

  test('leaves an unrelated code block intact', () => {
    const f = fence({ kind: 'quoteResult' })
    const text = '```js\nconst x = 1\n```\n\n' + f
    const m = extractLastCardIntentFence(text)!
    const stripped = stripFence(text, m.full)
    expect(stripped).toContain('const x = 1')
    expect(stripped).not.toContain('cardintent')
  })
})

describe('stripAllCardIntentFences', () => {
  test('removes EVERY cardintent fence (multi-fence) — no raw JSON leaks', () => {
    const text =
      '요약입니다.\n\n' +
      fence({ kind: 'quoteResult', n: 1, marker: 'FENCE_ONE_RAW' }) +
      '\n중간 텍스트\n' +
      fence({ kind: 'quoteResult', n: 2, marker: 'FENCE_TWO_RAW' }) +
      '\n끝.\n' +
      fence({ kind: 'quoteResult', n: 3, marker: 'FENCE_THREE_RAW' })
    const stripped = stripAllCardIntentFences(text)
    expect(stripped).not.toContain('cardintent')
    expect(stripped).not.toContain('FENCE_ONE_RAW')
    expect(stripped).not.toContain('FENCE_TWO_RAW')
    expect(stripped).not.toContain('FENCE_THREE_RAW')
    // surrounding prose survives
    expect(stripped).toContain('요약입니다.')
    expect(stripped).toContain('중간 텍스트')
    expect(stripped).toContain('끝.')
  })

  test('leaves non-cardintent code blocks intact', () => {
    const text = '```json\n{"a":1}\n```\n\n' + fence({ kind: 'quoteResult' })
    const stripped = stripAllCardIntentFences(text)
    expect(stripped).toContain('{"a":1}')
    expect(stripped).not.toContain('cardintent')
  })

  test('no-op when there is no cardintent fence', () => {
    expect(stripAllCardIntentFences('plain text')).toBe('plain text')
  })
})

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

describe('validateCardIntent', () => {
  test('accepts a valid list intent', () => {
    const r = validateCardIntent(validListIntent())
    expect(r.ok).toBe(true)
  })

  test('accepts a valid detail intent', () => {
    const r = validateCardIntent(validDetailIntent())
    expect(r.ok).toBe(true)
  })

  test('rejects wrong kind', () => {
    const bad = { ...validListIntent(), kind: 'somethingElse' }
    const r = validateCardIntent(bad)
    expect(r.ok).toBe(false)
  })

  test('rejects missing title / fallbackMarkdown', () => {
    const noTitle: any = validListIntent()
    delete noTitle.title
    expect(validateCardIntent(noTitle).ok).toBe(false)
    const noFallback: any = validListIntent()
    delete noFallback.fallbackMarkdown
    expect(validateCardIntent(noFallback).ok).toBe(false)
  })

  test('rejects a non-string Row.value (number leak)', () => {
    const bad: any = validListIntent()
    bad.sections[0].rows[0].value = 1500 // number, not string
    const r = validateCardIntent(bad)
    expect(r.ok).toBe(false)
    expect((r as any).reason).toContain('row.value must be a string')
  })

  test('rejects a bad valueState', () => {
    const bad: any = validListIntent()
    bad.sections[0].rows[0].valueState = 'mystery'
    expect(validateCardIntent(bad).ok).toBe(false)
  })

  test('rejects a bad actionId (outside the 11-enum)', () => {
    const bad: any = validListIntent()
    bad.actions[0].actionId = 'deleteEverything'
    expect(validateCardIntent(bad).ok).toBe(false)
  })

  test('accepts every actionId in the closed enum', () => {
    for (const id of ACTION_IDS) {
      const intent: any = validListIntent()
      intent.actions = [{ actionId: id, label: 'x', payload: {} }]
      expect(validateCardIntent(intent).ok).toBe(true)
    }
  })

  test('rejects empty sections', () => {
    const bad: any = validListIntent()
    bad.sections = []
    expect(validateCardIntent(bad).ok).toBe(false)
  })

  // --- fail-closed type-confusion (Phase-4 review findings) ---------------
  // A non-string actionId/valueState would stringify past a `String(...)`
  // -based enum check. These MUST be rejected by type, not coerced.
  test('rejects an array-wrapped actionId (type-confusion bypass)', () => {
    const bad: any = validListIntent()
    bad.actions[0].actionId = ['openQuoteResultDetail']
    expect(validateCardIntent(bad).ok).toBe(false)
  })

  test('rejects an array-wrapped valueState (would fall through to raw value leak)', () => {
    const bad: any = validListIntent()
    bad.sections[0].rows[0].valueState = ['calculating']
    expect(validateCardIntent(bad).ok).toBe(false)
  })

  test('rejects a payload that carries an actionId (override attempt)', () => {
    const bad: any = validListIntent()
    bad.actions[0].payload = { actionId: 'deleteEverything', quoteId: 'q1' }
    expect(validateCardIntent(bad).ok).toBe(false)
  })
})

describe('renderer is authoritative / non-leaking (defense-in-depth)', () => {
  test('toSubmitAction: validated actionId wins over a payload.actionId', () => {
    // Even if a payload.actionId slipped past validation, the rendered card's
    // data.actionId must be the validated, enum-checked id.
    const card: any = buildAdaptiveCard({
      kind: 'quoteResult',
      title: 't',
      fallbackMarkdown: 's',
      sections: [
        { label: '금액강조', rows: [{ label: 'a', value: '1', valueState: 'value' }] },
      ],
      actions: [
        { actionId: 'openQuoteResultDetail', label: 'go', payload: { actionId: 'deleteEverything' } as any },
      ],
    })
    expect(card.actions[0].data.actionId).toBe('openQuoteResultDetail')
  })

  test('renderValueState: unexpected state renders masked, never the raw value', () => {
    const r: any = renderValueState({ label: 'x', value: 'SECRET-9999', valueState: 'mystery' as any })
    expect(r.text).not.toBe('SECRET-9999')
    expect(r.text).toBe('●●●')
  })
})

// ---------------------------------------------------------------------------
// valueState → render mapping
// ---------------------------------------------------------------------------

describe('renderValueState', () => {
  const mk = (valueState: Row['valueState'], value = '₩1,000'): Row => ({
    label: '값',
    value,
    valueState,
  })

  test('value → raw value, default color', () => {
    const r = renderValueState(mk('value'))
    expect(r.text).toBe('₩1,000')
    expect(r.color).toBe('Default')
  })

  test('calculating → (계산중), Warning, NO number shown', () => {
    const r = renderValueState(mk('calculating', '₩9,999'))
    expect(r.text).toBe('(계산중)')
    expect(r.color).toBe('Warning')
    expect(r.text).not.toContain('9,999')
  })

  test('notRequested → (해당없음), subtle, Default', () => {
    const r = renderValueState(mk('notRequested'))
    expect(r.text).toBe('(해당없음)')
    expect(r.isSubtle).toBe(true)
    expect(r.color).toBe('Default')
  })

  test('masked → ●●●, Accent (no underlying value)', () => {
    const r = renderValueState(mk('masked', '₩secret'))
    expect(r.text).toBe('●●●')
    expect(r.color).toBe('Accent')
    expect(r.text).not.toContain('secret')
  })
})

// ---------------------------------------------------------------------------
// Render shape: AC v1.2, no Table/targetWidth, ColumnSet ≤ 3
// ---------------------------------------------------------------------------

function walk(node: any, visit: (n: any) => void): void {
  if (Array.isArray(node)) {
    for (const c of node) walk(c, visit)
    return
  }
  if (node && typeof node === 'object') {
    visit(node)
    for (const k of Object.keys(node)) walk(node[k], visit)
  }
}

describe('buildAdaptiveCard render shape', () => {
  test('list renders AC v1.2 with Containers + separators + FactSets', () => {
    const card: any = buildAdaptiveCard(validListIntent())
    expect(card.type).toBe('AdaptiveCard')
    expect(card.version).toBe('1.2')
    // multi-section list is NOT a detail layout
    expect(isDetailLayout(validListIntent())).toBe(false)
    const containers = card.body.filter((b: any) => b.type === 'Container')
    expect(containers.length).toBe(2)
    // first card no separator, subsequent cards separated
    expect(containers[0].separator).toBe(false)
    expect(containers[1].separator).toBe(true)
    // money mini-FactSet present in each container
    for (const c of containers) {
      expect(c.items.some((i: any) => i.type === 'FactSet')).toBe(true)
    }
    // per-card ActionSet present where the section had actions
    expect(containers[0].items.some((i: any) => i.type === 'ActionSet')).toBe(true)
  })

  test('detail renders 4 sections with an emphasis Container', () => {
    const intent = validDetailIntent()
    expect(isDetailLayout(intent)).toBe(true)
    const card: any = buildAdaptiveCard(intent)
    expect(card.version).toBe('1.2')
    const containers = card.body.filter((b: any) => b.type === 'Container')
    expect(containers.length).toBe(4)
    expect(containers.some((c: any) => c.style === 'emphasis')).toBe(true)
    // top-level actions → root ActionSet (card.actions)
    expect(Array.isArray(card.actions)).toBe(true)
    expect(card.actions[0].type).toBe('Action.Submit')
  })

  test('NO forbidden AC element types (Table) and NO targetWidth anywhere', () => {
    for (const intent of [validListIntent(), validDetailIntent()]) {
      const card = buildAdaptiveCard(intent)
      let sawTable = false
      let sawTargetWidth = false
      let maxColumns = 0
      walk(card, n => {
        if (n.type === 'Table') sawTable = true
        if ('targetWidth' in n) sawTargetWidth = true
        if (n.type === 'ColumnSet' && Array.isArray(n.columns)) {
          maxColumns = Math.max(maxColumns, n.columns.length)
        }
      })
      expect(sawTable).toBe(false)
      expect(sawTargetWidth).toBe(false)
      expect(maxColumns).toBeLessThanOrEqual(3)
    }
  })

  test('valueState mapping flows into the rendered FactSet (calculating hides number)', () => {
    const card = JSON.stringify(buildAdaptiveCard(validListIntent()))
    expect(card).toContain('(계산중)')
    expect(card).toContain('●●●')
    // the masked underlying subtotal ₩2,500 must NOT appear
    expect(card).not.toContain('2,500')
  })
})

// ---------------------------------------------------------------------------
// §10 forbidden-key golden — MUTATION-PROOF
// ---------------------------------------------------------------------------

describe('§10 forbidden cost keys (mutation-proof)', () => {
  test('findForbiddenCostKey flags a card carrying a forbidden key', () => {
    // Sanity: the placeholder list is non-empty (revert it → this fails).
    expect(FORBIDDEN_COST_KEYS_PLACEHOLDER.length).toBeGreaterThan(0)
    const dirty = JSON.stringify({ data: { unitCost: 1200 } })
    expect(findForbiddenCostKey(dirty)).toBe('unitCost')
  })

  test('findForbiddenCostKey returns null for a clean card', () => {
    const clean = JSON.stringify(buildAdaptiveCard(validListIntent()))
    expect(findForbiddenCostKey(clean)).toBeNull()
  })

  test('renderOutbound falls back to text-only when a forbidden key leaks into the card', () => {
    // Smuggle a forbidden key through an action payload — it lands in the
    // rendered card's Action.Submit.data and must trip the §10 golden.
    const intent: any = validListIntent()
    intent.sections[0].actions[0].payload = { quoteId: 'q1', unitCost: 1200 }
    const out = renderOutbound(fence(intent))
    // §10 guard MUST reject → no attachment, text-only graceful, fence stripped.
    // (Revert the findForbiddenCostKey check in renderOutbound → this fails:
    // the card would be attached and out.attachments.length === 1.)
    expect(out.attachments.length).toBe(0)
    expect(out.warning).toContain('forbidden cost key')
    expect(out.text).not.toContain('cardintent')
  })

  test('a clean intent passes §10 and is attached', () => {
    const out = renderOutbound(fence(validListIntent()))
    expect(out.attachments.length).toBe(1)
    expect(out.attachments[0].contentType).toBe('application/vnd.microsoft.card.adaptive')
    expect(out.warning).toBeUndefined()
  })
})

// ---------------------------------------------------------------------------
// renderOutbound seam — graceful fallback (MUTATION-PROOF) + additive contract
// ---------------------------------------------------------------------------

describe('renderOutbound graceful fallback (mutation-proof)', () => {
  test('no fence → text unchanged, NO attachments (additive contract)', () => {
    const text = '평범한 답변입니다. 카드 없음.'
    const out = renderOutbound(text)
    expect(out.text).toBe(text)
    expect(out.attachments.length).toBe(0)
    expect(out.warning).toBeUndefined()
  })

  test('valid fence → fence stripped + Adaptive Card attached', () => {
    const summary = 'A사 ₩1,500, B사 계산중입니다.'
    const out = renderOutbound(summary + '\n\n' + fence(validListIntent()))
    expect(out.text).toBe(summary)
    expect(out.text).not.toContain('cardintent')
    expect(out.attachments.length).toBe(1)
  })

  test('multi-fence → renders the LAST, strips ALL fences (no earlier raw JSON leaks)', () => {
    // codex r1 FAIL fix: the visible text must have EVERY cardintent fence
    // stripped, not just the last one. An earlier fence's raw JSON in out.text
    // would violate the "user must never see raw JSON" contract.
    // (Revert renderOutbound's stripAllCardIntentFences back to the single-span
    // stripFence(text, fence.full) → this fails: the first fence's marker leaks.)
    const summary = '두 견적 요약입니다.'
    const first: any = validListIntent()
    first.title = 'FIRST_RAW_MARKER'
    const last: any = validDetailIntent()
    last.title = 'LAST_RENDERED_MARKER'
    const text = summary + '\n\n' + fence(first) + '\n그리고\n' + fence(last)
    const out = renderOutbound(text)
    // last fence is the one rendered → its title is in the card, not as raw JSON
    expect(out.attachments.length).toBe(1)
    const cardBytes = JSON.stringify(out.attachments[0].content)
    expect(cardBytes).toContain('LAST_RENDERED_MARKER')
    // NEITHER fence's raw JSON may remain in the visible text
    expect(out.text).not.toContain('cardintent')
    expect(out.text).not.toContain('FIRST_RAW_MARKER')
    expect(out.text).not.toContain('LAST_RENDERED_MARKER')
    expect(out.text).not.toContain('"kind"')
    // surrounding prose survives
    expect(out.text).toContain('두 견적 요약입니다.')
    expect(out.text).toContain('그리고')
  })

  test('invalid JSON fence → text-only, fence stripped, NEVER throws', () => {
    const summary = '요약입니다.'
    const text = summary + '\n\n```cardintent\n{ not valid json,,, }\n```'
    let out: ReturnType<typeof renderOutbound> | undefined
    expect(() => {
      out = renderOutbound(text)
    }).not.toThrow()
    expect(out!.attachments.length).toBe(0)
    expect(out!.text).not.toContain('cardintent')
    expect(out!.text).toContain(summary)
    expect(out!.warning).toContain('parse failed')
  })

  test('schema-failing fence → text-only, fence stripped (number value leak)', () => {
    const bad: any = validListIntent()
    bad.sections[0].rows[0].value = 1500 // number → schema reject
    const out = renderOutbound('요약\n\n' + fence(bad))
    // Revert the validateCardIntent gate in renderOutbound → this fails (the
    // malformed intent would render and attach).
    expect(out.attachments.length).toBe(0)
    expect(out.warning).toContain('validation failed')
    expect(out.text).not.toContain('cardintent')
  })

  test('never throws on adversarial inputs', () => {
    const inputs = [
      '',
      '```cardintent\n\n```',
      '```cardintent\nnull\n```',
      '```cardintent\n[]\n```',
      '```cardintent\n"just a string"\n```',
      '```cardintent\n12345\n```',
    ]
    for (const i of inputs) {
      expect(() => renderOutbound(i)).not.toThrow()
      expect(renderOutbound(i).attachments.length).toBe(0)
    }
  })
})
