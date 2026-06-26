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
  buildDevReqAutofillCard,
  buildDevStatusCard,
  DEFAULT_QUOTE_RESULT_DEEPLINK,
  deeplinkHosts,
  devReqDeeplink,
  devStatusBadgeColor,
  devStatusDeeplink,
  extractLastCardIntentFence,
  findForbiddenCostKey,
  FORBIDDEN_COST_KEYS_PLACEHOLDER,
  isAllowedDeeplink,
  isDetailLayout,
  quoteResultDeeplink,
  renderOutbound,
  renderValueState,
  SECTION10_TEXT_FALLBACK,
  stripAllCardIntentFences,
  stripFence,
  validateCardIntent,
  validateDevReqAutofill,
  validateDevStatus,
  type CardIntent,
  type DevReqAutofillIntent,
  type DevStatusIntent,
  type Row,
} from './cardintent.ts'

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// quoteResult LIST = the #17138 6-field per-RFQ stack (appendix card 8). Golden
// sample values from the spec appendix (cards 7/8): 셀트리온 내용물 5,754 / 가공비
// – (notRequested), 헤메코 3,836 / 570, and a 산출중 (calculating) case. The
// per-RFQ fields are 고객·제품 (section.label), 용량, 랩넘버, 내용물 견적,
// 가공비 견적. NO 견적 소계 / 산출상태 columns. The deeplink is the only action.
function validListIntent(): CardIntent {
  return {
    kind: 'quoteResult',
    title: '💰 견적결과 — 3건',
    sections: [
      {
        label: '(주) 셀트리온스킨큐어 · 셀트리온스킨큐어 바디크림 (호수1)',
        rows: [
          { label: '용량', value: '306 g', valueState: 'value' },
          { label: '랩넘버', value: 'TESTCTO1', valueState: 'value' },
          { label: '내용물 견적', value: '5,754 원', valueState: 'value' },
          { label: '가공비 견적', value: '', valueState: 'notRequested' },
        ],
      },
      {
        label: '주식회사 헤메코 · 헤메코 바디크림 200ml',
        rows: [
          { label: '용량', value: '204 ml', valueState: 'value' },
          { label: '랩넘버', value: 'TESTHMC0609', valueState: 'value' },
          { label: '내용물 견적', value: '3,836 원', valueState: 'value' },
          { label: '가공비 견적', value: '570 원', valueState: 'value' },
        ],
      },
      {
        label: '(주) 셀트리온스킨큐어 · 셀트리온스킨큐어 바디크림 300ml',
        rows: [
          { label: '용량', value: '306 ml', valueState: 'value' },
          { label: '랩넘버', value: 'TESTCTO1', valueState: 'value' },
          { label: '내용물 견적', value: '7,451 원', valueState: 'value' },
          { label: '가공비 견적', value: '', valueState: 'calculating' },
        ],
      },
    ],
    actions: [
      {
        // actionId-only: crm-dev emits NO url. The renderer supplies the pinned
        // deeplink for this gated actionId.
        actionId: 'openQuoteResultDetail',
        label: '전체 견적결과 보기 (web/d)',
        payload: {},
      },
    ],
    fallbackMarkdown: '셀트리온 5,754원 / 헤메코 3,836원 / 셀트리온 산출중',
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
    actions: [
      {
        actionId: 'openQuoteResultDetail',
        label: '전체 견적결과 보기 (web/d)',
        payload: {},
      },
    ],
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
  test('Phase 1a: the view action emits the renderer-supplied OpenUrl — never an Action.Submit', () => {
    // The view actionId (no payload url) emits the renderer-supplied OpenUrl
    // deeplink, and Phase 1a NEVER emits an Action.Submit. (Revert toQuoteResultAction
    // to a Submit fallback → this fails: card.actions[0] would be an Action.Submit.)
    const card: any = buildAdaptiveCard({
      kind: 'quoteResult',
      title: 't',
      fallbackMarkdown: 's',
      sections: [
        { label: '금액강조', rows: [{ label: 'a', value: '1', valueState: 'value' }] },
      ],
      actions: [{ actionId: 'openQuoteResultDetail', label: 'go', payload: { quoteId: 'q1' } }],
    })
    expect(card.actions.length).toBe(1)
    expect(card.actions[0].type).toBe('Action.OpenUrl')
    expect(card.actions[0].url).toBe('https://crm-qa.cosmax.com/d/?screen=rfq-list')
    expect(JSON.stringify(card)).not.toContain('Action.Submit')
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

  test('calculating → 산출중, Warning, NO number shown', () => {
    const r = renderValueState(mk('calculating', '₩9,999'))
    expect(r.text).toBe('산출중')
    expect(r.color).toBe('Warning')
    expect(r.text).not.toContain('9,999')
  })

  test('notRequested → –, subtle, Default', () => {
    const r = renderValueState(mk('notRequested'))
    expect(r.text).toBe('–')
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

describe('buildAdaptiveCard render shape (6-field per-RFQ stack, card 8)', () => {
  test('list renders one per-RFQ Container with 고객·제품 header + 용량/랩넘버 FactSet + 내용물/가공비 견적 price rows', () => {
    const intent = validListIntent()
    const card: any = buildAdaptiveCard(intent)
    expect(card.type).toBe('AdaptiveCard')
    expect(card.version).toBe('1.2')
    // multi-section list is NOT a detail layout
    expect(isDetailLayout(intent)).toBe(false)
    // title + one Container per RFQ (3)
    const containers = card.body.filter((b: any) => b.type === 'Container')
    expect(containers.length).toBe(3)
    // first RFQ: 고객·제품 header is the section label, Accent
    const first = containers[0]
    expect(first.separator).toBe(true)
    const header = first.items.find((i: any) => i.type === 'TextBlock')
    expect(header.text).toBe(intent.sections[0].label)
    expect(header.color).toBe('Accent')
    expect(header.weight).toBe('Bolder')
    // emphasis sub-container holds the FactSet[용량, 랩넘버] + 2 price ColumnSets
    const emph = first.items.find((i: any) => i.type === 'Container' && i.style === 'emphasis')
    expect(emph).toBeDefined()
    const factSet = emph.items.find((i: any) => i.type === 'FactSet')
    expect(factSet.facts.map((f: any) => f.title)).toEqual(['용량', '랩넘버', 'RFQ'])
    expect(factSet.facts[0].value).toBe('306 g')
    expect(factSet.facts[1].value).toBe('TESTCTO1')
    // no RFQ row in this fixture → factValue routes the missing field to em dash
    expect(factSet.facts[2].value).toBe('—')
    const priceRows = emph.items.filter((i: any) => i.type === 'ColumnSet')
    expect(priceRows.length).toBe(2)
    expect(JSON.stringify(priceRows[0])).toContain('내용물 견적')
    expect(JSON.stringify(priceRows[1])).toContain('가공비 견적')
    // golden values: 내용물 5,754 원 (value, bold) / 가공비 – (notRequested, subtle)
    expect(JSON.stringify(priceRows[0])).toContain('5,754 원')
    const contentValueCell = priceRows[0].columns[1].items[0]
    expect(contentValueCell.weight).toBe('Bolder')
    const procValueCell = priceRows[0 + 1].columns[1].items[0]
    expect(procValueCell.text).toBe('–')
    expect(procValueCell.isSubtle).toBe(true)
  })

  test('DROPS 견적 소계 / 산출상태 — neither column nor its data appears anywhere', () => {
    const card = JSON.stringify(buildAdaptiveCard(validListIntent()))
    expect(card).not.toContain('견적 소계')
    expect(card).not.toContain('견적소계')
    expect(card).not.toContain('산출상태')
  })

  test('calculating price → 산출중 (Warning), value → bold number, notRequested → – subtle', () => {
    const card: any = buildAdaptiveCard(validListIntent())
    const cardStr = JSON.stringify(card)
    // RFQ 3's 가공비 is calculating → 산출중 Warning, never the (empty) value
    expect(cardStr).toContain('산출중')
    // RFQ 2's 가공비 570 원 value → number shown
    expect(cardStr).toContain('570 원')
    // the calculating cell carries Warning color
    const containers = card.body.filter((b: any) => b.type === 'Container')
    const rfq3 = containers[2]
    const emph3 = rfq3.items.find((i: any) => i.type === 'Container' && i.style === 'emphasis')
    const procRow3 = emph3.items.filter((i: any) => i.type === 'ColumnSet')[1]
    const cell3 = procRow3.columns[1].items[0]
    expect(cell3.text).toBe('산출중')
    expect(cell3.color).toBe('Warning')
  })

  test('용량/랩넘버 missing → em dash (—), never a raw leak', () => {
    const intent: any = {
      kind: 'quoteResult',
      title: 't',
      fallbackMarkdown: 'f',
      sections: [
        { label: 'A사 · 세럼A', rows: [{ label: '내용물 견적', value: '1,000 원', valueState: 'value' }] },
        { label: 'B사 · 크림B', rows: [{ label: '내용물 견적', value: '2,000 원', valueState: 'value' }] },
      ],
    }
    const card: any = buildAdaptiveCard(intent)
    const facts = card.body
      .filter((b: any) => b.type === 'Container')[0]
      .items.find((i: any) => i.type === 'Container').items
      .find((i: any) => i.type === 'FactSet').facts
    expect(facts.find((f: any) => f.title === '용량').value).toBe('—')
    expect(facts.find((f: any) => f.title === '랩넘버').value).toBe('—')
  })

  test('RFQ row renders in the FactSet; missing RFQ → em dash', () => {
    // Operator live-feedback: the per-RFQ FactSet must carry the RFQ number. The
    // server emit already supplies a { label:'RFQ', value:'RFQ900000385' } row.
    const intent: any = {
      kind: 'quoteResult',
      title: 't',
      fallbackMarkdown: 'f',
      sections: [
        {
          label: 'A사 · 세럼A',
          rows: [
            { label: '용량', value: '306 g', valueState: 'value' },
            { label: '랩넘버', value: 'TESTCTO1', valueState: 'value' },
            { label: 'RFQ', value: 'RFQ900000385', valueState: 'value' },
            { label: '내용물 견적', value: '1,000 원', valueState: 'value' },
          ],
        },
        {
          // no RFQ row → factValue routes the missing field to an em dash
          label: 'B사 · 크림B',
          rows: [{ label: '내용물 견적', value: '2,000 원', valueState: 'value' }],
        },
      ],
    }
    const card: any = buildAdaptiveCard(intent)
    const factSetOf = (containerIdx: number) =>
      card.body
        .filter((b: any) => b.type === 'Container')[containerIdx]
        .items.find((i: any) => i.type === 'Container').items
        .find((i: any) => i.type === 'FactSet').facts
    const rfqFact = factSetOf(0).find((f: any) => f.title === 'RFQ')
    expect(rfqFact).toBeDefined()
    expect(rfqFact.value).toBe('RFQ900000385')
    expect(JSON.stringify(card)).toContain('RFQ900000385')
    // section without an RFQ row → em dash, never a leak
    expect(factSetOf(1).find((f: any) => f.title === 'RFQ').value).toBe('—')
  })

  test('a masked/calculating 용량·랩넘버 FactSet row NEVER leaks its raw value', () => {
    // The FactSet path must not fall through to row.value for a non-value state
    // (a masked 랩넘버 or a calculating 용량 would otherwise leak underlying data).
    // (Revert factValue to return the raw string unconditionally → this fails.)
    const intent: any = {
      kind: 'quoteResult',
      title: 't',
      fallbackMarkdown: 'f',
      sections: [
        {
          label: 'A사 · 세럼A',
          rows: [
            { label: '용량', value: 'SECRET-VOL-9999', valueState: 'calculating' },
            { label: '랩넘버', value: 'SECRET-LAB-0001', valueState: 'masked' },
            { label: '내용물 견적', value: '1,000 원', valueState: 'value' },
          ],
        },
        {
          label: 'B사 · 크림B',
          rows: [{ label: '내용물 견적', value: '2,000 원', valueState: 'value' }],
        },
      ],
    }
    const card: any = buildAdaptiveCard(intent)
    const cardStr = JSON.stringify(card)
    expect(cardStr).not.toContain('SECRET-VOL-9999') // calculating → 산출중, not the raw value
    expect(cardStr).not.toContain('SECRET-LAB-0001') // masked → ●●●, not the raw value
    const facts = card.body
      .filter((b: any) => b.type === 'Container')[0]
      .items.find((i: any) => i.type === 'Container').items
      .find((i: any) => i.type === 'FactSet').facts
    expect(facts.find((f: any) => f.title === '용량').value).toBe('산출중')
    expect(facts.find((f: any) => f.title === '랩넘버').value).toBe('●●●')
  })

  test('detail renders 4 sections with an emphasis Container; top-level deeplink is Action.OpenUrl', () => {
    const intent = validDetailIntent()
    expect(isDetailLayout(intent)).toBe(true)
    const card: any = buildAdaptiveCard(intent)
    expect(card.version).toBe('1.2')
    const containers = card.body.filter((b: any) => b.type === 'Container')
    expect(containers.length).toBe(4)
    expect(containers.some((c: any) => c.style === 'emphasis')).toBe(true)
    // Phase 1a: the only root action is the domain-pinned deeplink (NO Submit)
    expect(Array.isArray(card.actions)).toBe(true)
    expect(card.actions[0].type).toBe('Action.OpenUrl')
  })

  test('NO forbidden AC element types (Table) and NO targetWidth anywhere; ColumnSet ≤3', () => {
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
})

// ---------------------------------------------------------------------------
// Contract primitives (Phase-1a): PriceCell string-only, openUrl domain-pin,
// submit-reject — MUTATION-PROOF
// ---------------------------------------------------------------------------

describe('PriceCell string-only (Phase 1a)', () => {
  test('a raw-number price value fails closed — no attachment', () => {
    // PriceCell.value MUST be a string. A raw number is an unformatted/un-masked
    // cost leak; the card must NOT attach. (Revert the row.value string guard →
    // this fails: the number would render into a price cell and attach.)
    const intent: any = validListIntent()
    intent.sections[1].rows[2].value = 5754 // raw number, not "5,754 원"
    const out = renderOutbound(fence(intent))
    expect(out.attachments.length).toBe(0)
    expect(out.warning).toContain('validation failed')
  })

  test('a numeric-only decimal string is still a string but renders verbatim (no arithmetic)', () => {
    // The renderer does NO arithmetic — whatever string the SKILL formatted is
    // shown as-is. (This pins "no arithmetic": a value of "5754" is not reformatted.)
    const intent: any = validListIntent()
    intent.sections[1].rows[2].value = '5754'
    const card = JSON.stringify(buildAdaptiveCard(intent))
    expect(card).toContain('5754')
  })
})

describe('openUrl domain-pin (Phase 1a)', () => {
  test('the canonical deeplink resolves to the crm-qa rfq-list screen', () => {
    expect(DEFAULT_QUOTE_RESULT_DEEPLINK).toBe('https://crm-qa.cosmax.com/d/?screen=rfq-list')
  })

  test('default host allowlist is crm-qa.cosmax.com', () => {
    expect(deeplinkHosts({})).toEqual(['crm-qa.cosmax.com'])
  })

  test('on-domain https url is accepted (normalized href returned)', () => {
    expect(isAllowedDeeplink('https://crm-qa.cosmax.com/d/?screen=rfq-list', {})).toBe(
      'https://crm-qa.cosmax.com/d/?screen=rfq-list',
    )
  })

  test('off-domain / wrong-proto / userinfo / freeform urls are rejected (null)', () => {
    for (const bad of [
      'https://evil.example/d/?screen=rfq-list', // off-domain
      'http://crm-qa.cosmax.com/d/', // wrong protocol
      'https://crm-qa.cosmax.com@example.com/d/', // userinfo smuggle (real host off-allowlist)
      'javascript:alert(1)', // freeform scheme
      'crm-qa.cosmax.com/d/', // not parseable as absolute
      '', // empty
    ]) {
      expect(isAllowedDeeplink(bad, {})).toBeNull()
    }
  })

  test('host allowlist is env-overridable for QA/prod', () => {
    const env = { BRIDGE_TEAMS_DEEPLINK_HOSTS: 'crm.cosmax.com, crm-qa.cosmax.com' }
    expect(deeplinkHosts(env)).toEqual(['crm.cosmax.com', 'crm-qa.cosmax.com'])
    expect(isAllowedDeeplink('https://crm.cosmax.com/d/?screen=rfq-list', env)).toBe(
      'https://crm.cosmax.com/d/?screen=rfq-list',
    )
    // a host NOT in the override is still rejected
    expect(isAllowedDeeplink('https://crm-qa.cosmax.com/d/', { BRIDGE_TEAMS_DEEPLINK_HOSTS: 'crm.cosmax.com' })).toBeNull()
  })

  test('quoteResultDeeplink builds the rfq-list url on the first configured host', () => {
    expect(quoteResultDeeplink({})).toBe('https://crm-qa.cosmax.com/d/?screen=rfq-list')
  })

  test('actionId-only emit (NO payload url) renders the renderer-supplied Action.OpenUrl', () => {
    // crm-dev sends {actionId:'openQuoteResultDetail', label:…} with NO url. The
    // renderer must SUPPLY the pinned deeplink and emit the button. (Revert to
    // sourcing a.payload?.url → this fails: no url, no button.)
    const intent: any = validListIntent()
    intent.actions = [{ actionId: 'openQuoteResultDetail', label: '전체 견적결과 보기' }]
    const card: any = buildAdaptiveCard(intent)
    expect(card.actions.length).toBe(1)
    expect(card.actions[0].type).toBe('Action.OpenUrl')
    expect(card.actions[0].url).toBe('https://crm-qa.cosmax.com/d/?screen=rfq-list')
    expect(card.actions[0].title).toContain('전체 견적결과 보기')
  })

  test('a cardintent-supplied url is IGNORED — the renderer pins the destination (no open redirect)', () => {
    // THE open-redirect-elimination test: even when the cardintent smuggles a
    // payload.url (off-domain, or a different path on the allowed host), the
    // emitted url is STILL the renderer's pinned rfq-list deeplink. The cardintent
    // can NOT supply or influence the button destination. (Revert to sourcing
    // a.payload?.url → this fails: the smuggled url would surface.)
    for (const smuggled of [
      'https://evil.example.com/x',
      'https://crm-qa.cosmax.com/d/?screen=admin-export', // allowed host, attacker path
      'javascript:alert(1)',
    ]) {
      const intent: any = validListIntent()
      intent.actions = [
        { actionId: 'openQuoteResultDetail', label: '전체 견적결과 보기', payload: { url: smuggled } },
      ]
      const card: any = buildAdaptiveCard(intent)
      expect(card.actions.length).toBe(1)
      expect(card.actions[0].type).toBe('Action.OpenUrl')
      expect(card.actions[0].url).toBe('https://crm-qa.cosmax.com/d/?screen=rfq-list')
      const cardStr = JSON.stringify(card)
      expect(cardStr).not.toContain('evil.example')
      expect(cardStr).not.toContain('admin-export')
      expect(cardStr).not.toContain('javascript:')
    }
  })

  test('env host override changes the renderer-supplied url', () => {
    // BRIDGE_TEAMS_DEEPLINK_HOSTS override flows through to the emitted deeplink
    // (toQuoteResultAction builds it from the first configured host at call time
    // via the ambient env). Read/write process.env through globalThis so this
    // test typechecks under the plugin's node-types-free tsconfig (`types: []`),
    // mirroring how the source module reads the env.
    const env = (globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env ?? {}
    const prev = env.BRIDGE_TEAMS_DEEPLINK_HOSTS
    env.BRIDGE_TEAMS_DEEPLINK_HOSTS = 'crm.cosmax.com'
    try {
      const card: any = buildAdaptiveCard(validListIntent())
      expect(card.actions[0].type).toBe('Action.OpenUrl')
      expect(card.actions[0].url).toBe('https://crm.cosmax.com/d/?screen=rfq-list')
    } finally {
      if (prev === undefined) delete env.BRIDGE_TEAMS_DEEPLINK_HOSTS
      else env.BRIDGE_TEAMS_DEEPLINK_HOSTS = prev
    }
  })

  test('a NON-view actionId is DROPPED — only openQuoteResultDetail surfaces the deeplink', () => {
    // Only openQuoteResultDetail may surface as the card OpenUrl. A createQuoteDoc
    // (or any other) action must NOT be emitted as an Action.OpenUrl — even though
    // the renderer would supply the url, the actionId gate stops the laundering.
    // (Revert the actionId gate in toQuoteResultAction → this fails: the
    // createQuoteDoc action would attach as an OpenUrl.)
    const intent: any = validListIntent()
    intent.actions = [
      {
        actionId: 'createQuoteDoc',
        label: '견적서 생성',
        payload: { url: 'https://crm-qa.cosmax.com/d/?screen=rfq-list' },
      },
    ]
    const card: any = buildAdaptiveCard(intent)
    expect(card.actions).toBeUndefined() // dropped: not the gated view actionId
    expect(JSON.stringify(card)).not.toContain('Action.OpenUrl')
  })
})

describe('submit rejected (Phase 1a)', () => {
  test('a submit-type action (no deeplink url) in a quoteResult intent is NOT emitted', () => {
    const intent: any = validListIntent()
    intent.actions = [{ actionId: 'createQuoteDoc', label: '견적서 생성', payload: { quoteId: 'q1' } }]
    const out = renderOutbound(fence(intent))
    expect(out.attachments.length).toBe(1) // card still attaches
    const card = JSON.stringify(out.attachments[0].content)
    expect(card).not.toContain('Action.Submit')
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
    // Smuggle a forbidden cost key through a rendered Row.value — it lands in the
    // card's price cell text and must trip the §10 golden over the card bytes.
    const intent: any = validListIntent()
    intent.sections[0].rows[2].value = 'unitCost 1,200'
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
// §10 visible-text fail-closed — MUTATION-PROOF
//
// The card scan alone is not enough: a forbidden cost term emitted in the
// human-visible prose OUTSIDE the fence would be sent unscanned. On the FAILURE
// path (card rejected / parse / size) renderOutbound still emits the §10-clean
// safeText fallback so the prose can never leak a forbidden term. On the SUCCESS
// path the visible prose is suppressed entirely (text === '') — the card IS the
// content, so a zero visible-text leak surface is strictly stronger than the old
// hard-replace AND removes the duplicate no-card markdown table. The no-fence
// path stays byte-for-byte unchanged.
// ---------------------------------------------------------------------------

describe('§10 visible-text fail-closed (mutation-proof)', () => {
  test('forbidden term in prose + CLEAN card → visible text suppressed, card still attached', () => {
    // The card is clean (no forbidden key) so it survives §10 and is attached.
    // On card SUCCESS the visible prose is suppressed entirely (text === ''), so
    // the forbidden cost term ("원가") in the prose can never reach Teams — a
    // strictly stronger outcome than the old hard-replace. Revert the success
    // text='' suppression in renderOutbound → this fails: out.text would carry
    // "원가는 1000원" (or the §10 fallback), not the empty string.
    const out = renderOutbound('원가는 1000원\n\n' + fence(validListIntent()))
    expect(out.text).toBe('')
    expect(out.text).not.toContain('원가')
    expect(out.attachments.length).toBe(1) // clean card still sent
    expect(out.warning).toBeUndefined()
  })

  test('제시가 in the visible prose is suppressed on success (clean card still attached)', () => {
    const out = renderOutbound('제시가 기준으로 안내드립니다.\n\n' + fence(validListIntent()))
    expect(out.text).toBe('')
    expect(out.text).not.toContain('제시가')
    expect(out.attachments.length).toBe(1)
  })

  test('clean prose + clean card → visible text suppressed on success (no duplicate table), card attached', () => {
    const summary = '견적 결과를 카드로 정리했습니다.'
    const out = renderOutbound(summary + '\n\n' + fence(validListIntent()))
    // Even clean prose is suppressed on card success — the card is the content,
    // the prose/markdown table is only a no-card fallback (the dedup fix).
    expect(out.text).toBe('')
    expect(out.text).not.toContain('cardintent')
    expect(out.attachments.length).toBe(1)
  })

  test('forbidden key in the CARD still rejects, AND the text is §10-clean', () => {
    // Card carries a forbidden key (rejected → no attachment) and the prose ALSO
    // carries a forbidden term → text must be the §10 fallback, not the leak.
    const intent: any = validListIntent()
    intent.sections[0].rows[2].value = 'unitCost 1,200'
    const out = renderOutbound('마진은 30%입니다.\n\n' + fence(intent))
    expect(out.attachments.length).toBe(0) // card rejected (existing behavior)
    expect(out.warning).toContain('forbidden cost key')
    expect(out.text).toBe(SECTION10_TEXT_FALLBACK)
    expect(out.text).not.toContain('마진')
  })

  test('no-fence message is byte-for-byte unchanged even with a forbidden term (out of scope)', () => {
    // The no-fence early return is deliberately NOT hardened (only cardintent
    // turns are in scope). Revert that boundary (e.g. route the no-fence path
    // through safeText) → this fails: the text would be replaced.
    const plain = '원가는 1000원이고 마진은 30%입니다. 카드 없음.'
    const out = renderOutbound(plain)
    expect(out.text).toBe(plain) // byte-for-byte identical
    expect(out.attachments.length).toBe(0)
    expect(out.warning).toBeUndefined()
  })

  test('allowed price labels 내용물 견적 / 가공비 견적 are not forbidden (prose suppressed on card success)', () => {
    // These are the ALLOWED viewer-facing labels — they must NOT be on the
    // forbidden list. On card success the prose is suppressed regardless, so the
    // §10 fallback never fires for them either.
    expect(findForbiddenCostKey('내용물 견적')).toBeNull()
    expect(findForbiddenCostKey('가공비 견적')).toBeNull()
    const summary = '내용물 견적과 가공비 견적을 안내드립니다.'
    const out = renderOutbound(summary + '\n\n' + fence(validListIntent()))
    expect(out.text).toBe('')
    expect(out.text).not.toBe(SECTION10_TEXT_FALLBACK)
    expect(out.attachments.length).toBe(1)
  })

  test('card success suppresses the visible prose (no duplicate table)', () => {
    // Operator live-feedback dedup: the agent's no-card markdown table prose must
    // NOT be sent alongside the rendered card. On a quoteResult success the card
    // is the sole content → out.text === '' and exactly one attachment.
    const prose = [
      '견적 결과를 표로 정리했습니다:',
      '',
      '| 고객 | 제품 | 용량 | 랩넘버 | 내용물 견적 | 가공비 견적 |',
      '| --- | --- | --- | --- | --- | --- |',
      '| A사 | 제품1 | 306 g | TESTCTO1 | ₩1,500 | 산출중 |',
    ].join('\n')
    const out = renderOutbound(prose + '\n\n' + fence(validListIntent()))
    expect(out.text).toBe('')
    expect(out.attachments.length).toBe(1)
    expect(out.warning).toBeUndefined()
  })

  test('Korean + literal contract terms are on the forbidden list; 제시가 hit, labels clean', () => {
    for (const term of ['제시가', '원가', '마진', '공헌이익', '영업이익', '네고율', '회수율', '작업장명', '임률', '고객요청가', 'manufacturingCostSuggested', 'standardCost']) {
      expect(FORBIDDEN_COST_KEYS_PLACEHOLDER).toContain(term)
    }
    expect(FORBIDDEN_COST_KEYS_PLACEHOLDER).not.toContain('내용물 견적')
    expect(FORBIDDEN_COST_KEYS_PLACEHOLDER).not.toContain('가공비 견적')
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

  test('valid fence → prose suppressed + Adaptive Card attached', () => {
    const summary = 'A사 ₩1,500, B사 계산중입니다.'
    const out = renderOutbound(summary + '\n\n' + fence(validListIntent()))
    // Card success suppresses the visible prose — the card is the content.
    expect(out.text).toBe('')
    expect(out.text).not.toContain('cardintent')
    expect(out.attachments.length).toBe(1)
  })

  test('multi-fence → renders the LAST, suppresses prose on success (no raw JSON leaks)', () => {
    // codex r1 FAIL fix: on the card-success path the visible text is suppressed
    // entirely (text === ''), so neither fence's raw JSON nor the surrounding
    // prose can reach the user — strictly upholds the "user must never see raw
    // JSON" contract. (Revert the success text='' suppression → this fails: the
    // surrounding prose, or a non-fully-stripped fence marker, would leak.)
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
    // visible text fully suppressed on success → no raw JSON, no marker, no prose
    expect(out.text).toBe('')
    expect(out.text).not.toContain('cardintent')
    expect(out.text).not.toContain('FIRST_RAW_MARKER')
    expect(out.text).not.toContain('LAST_RENDERED_MARKER')
    expect(out.text).not.toContain('"kind"')
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

// ---------------------------------------------------------------------------
// devReqAutofill (개발의뢰 draft autofill card — #17471)
// ---------------------------------------------------------------------------

// The LOCKED #17538 emit shape: a flat ordered section list where an empty-rows
// section is a per-project header (Label = projectTitle), following non-empty
// sections nest under it, and a trailing "⚠ 보완 필요" section lists missing
// fields. Actions are confirmDevReq / editDevReq (entity-id payload, no url).
function validDevReqIntent(): DevReqAutofillIntent {
  return {
    kind: 'devReqAutofill',
    title: '📋 개발의뢰 초안 — 프로젝트 2건',
    subtitle: '메일 첨부 xlsx에서 자동으로 채운 초안입니다. 확인 후 등록하세요.',
    sections: [
      { label: '리안후 애프터필러 립케어 세트', rows: [] }, // P1 header (empty rows)
      {
        label: '프로젝트정보',
        rows: [
          { label: '고객 / 브랜드', value: '주식회사 온닥터 / 리안후', valueState: 'value' },
          { label: '연간 예상매출(억원)', value: '', valueState: 'notRequested' },
        ],
      },
      { label: '제품정보', rows: [{ label: '제품명', value: '리안후 립케어 세트', valueState: 'value' }] },
      { label: '비타토닝 크림', rows: [] }, // P2 header (empty rows)
      { label: '프로젝트정보', rows: [{ label: '출시 예정월', value: '2027-03', valueState: 'value' }] },
      {
        label: '⚠ 보완 필요',
        rows: [
          { label: '의뢰인', value: 'CRM 미등록 — 신규 등록 필요', valueState: 'value' },
          { label: '연간 예상매출', value: '', valueState: 'notRequested' },
        ],
      },
    ],
    actions: [
      { actionId: 'confirmDevReq', label: '✓ 승인 (등록·발송)', payload: { devReqId: 'dr-demo' } },
      { actionId: 'editDevReq', label: '✎ 수정', payload: { devReqId: 'dr-demo' } },
    ],
    fallbackMarkdown: '개발의뢰 초안(2건). 카드를 확인하세요.',
  }
}

function devReqFence(intent: unknown): string {
  return '초안입니다.\n\n```cardintent\n' + JSON.stringify(intent) + '\n```'
}

// Collect every {type} string in a rendered card tree (for action/element scans).
function collectTypes(node: unknown, acc: string[] = []): string[] {
  if (Array.isArray(node)) {
    for (const n of node) collectTypes(n, acc)
  } else if (node && typeof node === 'object') {
    const o = node as Record<string, unknown>
    if (typeof o.type === 'string') acc.push(o.type)
    for (const v of Object.values(o)) collectTypes(v, acc)
  }
  return acc
}

describe('devReqAutofill validation', () => {
  test('accepts a valid intent', () => {
    expect(validateDevReqAutofill(validDevReqIntent()).ok).toBe(true)
  })
  test('rejects the wrong kind', () => {
    expect(validateDevReqAutofill({ ...validDevReqIntent(), kind: 'quoteResult' }).ok).toBe(false)
  })
  test('rejects a non-string row value (unformatted cost leak shape)', () => {
    const bad = validDevReqIntent()
    ;(bad.sections[1].rows[0] as unknown as Record<string, unknown>).value = 12345
    expect(validateDevReqAutofill(bad).ok).toBe(false)
  })
  test('rejects a non-enum valueState (fail-closed)', () => {
    const bad = validDevReqIntent()
    ;(bad.sections[1].rows[0] as unknown as Record<string, unknown>).valueState = ['value']
    expect(validateDevReqAutofill(bad).ok).toBe(false)
  })
  test('rejects empty sections', () => {
    expect(validateDevReqAutofill({ ...validDevReqIntent(), sections: [] }).ok).toBe(false)
  })
  test('allows an empty-rows section (a project header)', () => {
    const ok = validDevReqIntent()
    expect(ok.sections[0].rows.length).toBe(0)
    expect(validateDevReqAutofill(ok).ok).toBe(true)
  })
  test('rejects an unknown action id (fail-closed)', () => {
    const bad = validDevReqIntent()
    ;(bad.actions![0] as unknown as Record<string, unknown>).actionId = 'deleteEverything'
    expect(validateDevReqAutofill(bad).ok).toBe(false)
  })
  test('rejects a non-string action id (array smuggle)', () => {
    const bad = validDevReqIntent()
    ;(bad.actions![0] as unknown as Record<string, unknown>).actionId = ['confirmDevReq']
    expect(validateDevReqAutofill(bad).ok).toBe(false)
  })
})

describe('devReqAutofill render shape (section-order grouping)', () => {
  test('an empty-rows section opens one emphasis Container per project', () => {
    const card = buildDevReqAutofillCard(validDevReqIntent()) as Record<string, unknown>
    const body = card.body as Array<Record<string, unknown>>
    const emphasis = body.filter(el => el.type === 'Container' && el.style === 'emphasis')
    expect(emphasis.length).toBe(2) // 리안후 + 비타토닝
    const head = (c: Record<string, unknown>) =>
      ((c.items as Array<Record<string, unknown>>)[0].text as string)
    expect(head(emphasis[0])).toBe('리안후 애프터필러 립케어 세트')
    expect(head(emphasis[1])).toBe('비타토닝 크림')
    // P1's container carries BOTH following content sections (프로젝트정보 + 제품정보).
    const p1 = JSON.stringify(emphasis[0])
    expect(p1).toContain('프로젝트정보')
    expect(p1).toContain('제품정보')
  })

  test('AC v1.2 only — no Table / targetWidth / Action.Submit / ToggleVisibility', () => {
    const card = buildDevReqAutofillCard(validDevReqIntent())
    const types = collectTypes(card)
    expect(types).not.toContain('Table')
    expect(types).not.toContain('Action.Submit')
    expect(types).not.toContain('Action.ToggleVisibility')
    const bytes = JSON.stringify(card)
    expect(bytes).not.toContain('targetWidth')
    expect((card as Record<string, unknown>).version).toBe('1.2')
  })

  test('confirmDevReq + editDevReq map to renderer-supplied OpenUrl deeplinks', () => {
    const card = buildDevReqAutofillCard(validDevReqIntent()) as Record<string, unknown>
    const actions = card.actions as Array<Record<string, unknown>>
    expect(actions.map(a => a.type)).toEqual(['Action.OpenUrl', 'Action.OpenUrl'])
    // Both urls are the renderer-supplied domain-pinned deeplink (never from input).
    expect(actions[0].url).toBe(devReqDeeplink())
    expect(actions[1].url).toBe(devReqDeeplink())
    expect(actions.map(a => a.title)).toEqual(['✓ 승인 (등록·발송)', '✎ 수정'])
  })

  test('the action payload entity-id never reaches the deeplink url (zero injection)', () => {
    const intent = validDevReqIntent()
    ;(intent.actions![0].payload as Record<string, unknown>).devReqId = 'evil/../../etc'
    const card = buildDevReqAutofillCard(intent) as Record<string, unknown>
    const actions = card.actions as Array<Record<string, unknown>>
    expect(actions[0].url).toBe(devReqDeeplink())
    expect(JSON.stringify(card)).not.toContain('evil/../../etc')
  })

  test('a trailing ⚠ 보완 section renders a warning Container', () => {
    const card = buildDevReqAutofillCard(validDevReqIntent()) as Record<string, unknown>
    const body = card.body as Array<Record<string, unknown>>
    const warn = body.find(el => el.type === 'Container' && el.style === 'warning')
    expect(warn).toBeDefined()
    const txt = JSON.stringify(warn)
    expect(txt).toContain('보완 필요')
    expect(txt).toContain('의뢰인: CRM 미등록 — 신규 등록 필요')
  })

  test('a content section with no open header renders standalone (flat safety-net)', () => {
    const intent = validDevReqIntent()
    intent.sections = [{ label: '단일 섹션', rows: [{ label: 'a', value: 'b', valueState: 'value' }] }]
    intent.actions = []
    const card = buildDevReqAutofillCard(intent) as Record<string, unknown>
    const body = card.body as Array<Record<string, unknown>>
    expect(body.some(el => el.type === 'Container' && el.style === 'emphasis')).toBe(false)
    const flat = body.find(
      el => el.type === 'Container' && !el.style && (el.items as Array<Record<string, unknown>>)?.[0]?.text === '단일 섹션',
    )
    expect(flat).toBeDefined()
  })

  test('a notRequested/empty field renders an em dash, never the raw value', () => {
    expect(JSON.stringify(buildDevReqAutofillCard(validDevReqIntent()))).toContain('—')
  })

  test('no actions key when nothing maps', () => {
    const intent = validDevReqIntent()
    intent.actions = []
    const card = buildDevReqAutofillCard(intent) as Record<string, unknown>
    expect('actions' in card).toBe(false)
  })
})

describe('devReqAutofill via renderOutbound (seam + §10 + suppression)', () => {
  test('success → card attachment + suppressed visible text', () => {
    const out = renderOutbound(devReqFence(validDevReqIntent()))
    expect(out.attachments.length).toBe(1)
    expect(out.text).toBe('')
    expect(out.warning).toBeUndefined()
    expect((out.attachments[0].content as Record<string, unknown>).type).toBe('AdaptiveCard')
  })

  // MUTATION-PROOF: a §10 forbidden cost key anywhere in the devReq card bytes
  // (here smuggled into a content-row value) must reject the WHOLE card →
  // text-only. If the §10 byte-scan is reverted, this test fails.
  test('§10 forbidden cost key in a devReq row → text-only fallback', () => {
    const bad = validDevReqIntent()
    bad.sections[1].rows.push({ label: '비고', value: '원가 12000', valueState: 'value' })
    const out = renderOutbound(devReqFence(bad))
    expect(out.attachments.length).toBe(0)
    expect(out.warning).toContain('§10')
    expect(out.text).not.toContain('원가')
  })

  test('an invalid devReq intent degrades to text-only, never throws', () => {
    const bad = { ...validDevReqIntent(), title: 123 }
    expect(() => renderOutbound(devReqFence(bad))).not.toThrow()
    const out = renderOutbound(devReqFence(bad))
    expect(out.attachments.length).toBe(0)
    expect(out.warning).toContain('validation failed')
  })
})

describe('quoteResult path is unchanged by the devReqAutofill addition (regression)', () => {
  test('a valid quoteResult intent still renders a card with only its OpenUrl deeplink', () => {
    const out = renderOutbound(
      '```cardintent\n' +
        JSON.stringify({
          kind: 'quoteResult',
          title: '💰 견적결과 — 1건',
          sections: [
            { label: '고객 · 제품', rows: [{ label: '내용물 견적', value: '5,754 원', valueState: 'value' }] },
          ],
          actions: [{ actionId: 'openQuoteResultDetail', label: '전체 견적결과 보기', payload: {} }],
          fallbackMarkdown: '견적결과 1건.',
        }) +
        '\n```',
    )
    expect(out.attachments.length).toBe(1)
    const card = out.attachments[0].content as Record<string, unknown>
    const actions = (card.actions as Array<Record<string, unknown>>) ?? []
    expect(actions.map(a => a.type)).toEqual(['Action.OpenUrl'])
  })
})

// ---------------------------------------------------------------------------
// devStatus (개발현황 card — #17992)
//
// A THIRD card kind, a near-clone of the quoteResult LIST shape: one Container
// per dev-product (NOT devReqAutofill's empty-rows grouping), each with an Accent
// header (제품 · 상태), a status badge colored by the 상태 row value, and a
// FactSet of the 8 dev-product fields rendered VERBATIM (a literal '—' is a real
// datum — no empty/session fallback). One card-level openDevStatusDetail action
// → a renderer-supplied domain-pinned OpenUrl (payload.url ignored). Submit never.
// ---------------------------------------------------------------------------

// VENDORED copy of the LOCKED golden:
// ~/.agent-bridge/shared/2026-06-26-devstatus-golden.json (4 dev-products). The
// copy is embedded (NOT read from disk) so the suite stays hermetic in CI where
// the shared/ runtime path does not exist. Kept byte-identical to the golden so
// a drift between this fixture and the on-disk golden is caught by review.
function goldenDevStatusIntent(): DevStatusIntent {
  return {
    kind: 'devStatus',
    title: '🧪 개발현황 — 개발제품 4건',
    sections: [
      {
        label: '케이프 요철크림 · 보류',
        rows: [
          { label: '생성일', value: '2026-06-20', valueState: 'value' },
          { label: '고객', value: '케이프 주식회사', valueState: 'value' },
          { label: '프로젝트', value: '케이프 요철크림', valueState: 'value' },
          { label: '제품', value: '케이프 요철크림', valueState: 'value' },
          { label: '벌크', value: '2건', valueState: 'value' },
          { label: '연구원', value: '김연구', valueState: 'value' },
          { label: '랩넘버', value: 'L-2026-0042', valueState: 'value' },
          { label: '상태', value: '보류', valueState: 'value' },
        ],
      },
      {
        label: '수분 진정 토너 · 진행 중',
        rows: [
          { label: '생성일', value: '2026-06-22', valueState: 'value' },
          { label: '고객', value: '뷰티랩(주)', valueState: 'value' },
          { label: '프로젝트', value: '수분 진정 토너', valueState: 'value' },
          { label: '제품', value: '수분 진정 토너', valueState: 'value' },
          { label: '벌크', value: '1건', valueState: 'value' },
          { label: '연구원', value: '박선임', valueState: 'value' },
          { label: '랩넘버', value: 'L-2026-0051', valueState: 'value' },
          { label: '상태', value: '진행 중', valueState: 'value' },
        ],
      },
      {
        label: '선쿠션 SPF50 · 출시 완료',
        rows: [
          { label: '생성일', value: '2026-06-18', valueState: 'value' },
          { label: '고객', value: '코스메디(주)', valueState: 'value' },
          { label: '프로젝트', value: '선쿠션 SPF50', valueState: 'value' },
          { label: '제품', value: '선쿠션 SPF50', valueState: 'value' },
          { label: '벌크', value: '3건', valueState: 'value' },
          { label: '연구원', value: '—', valueState: 'value' },
          { label: '랩넘버', value: 'L-2026-0033', valueState: 'value' },
          { label: '상태', value: '출시 완료', valueState: 'value' },
        ],
      },
      {
        label: '립밤 틴트 · 드롭',
        rows: [
          { label: '생성일', value: '2026-06-25', valueState: 'value' },
          { label: '고객', value: '아우라코스(주)', valueState: 'value' },
          { label: '프로젝트', value: '립밤 틴트', valueState: 'value' },
          { label: '제품', value: '립밤 틴트', valueState: 'value' },
          { label: '벌크', value: '—', valueState: 'value' },
          { label: '연구원', value: '이책임', valueState: 'value' },
          { label: '랩넘버', value: '—', valueState: 'value' },
          { label: '상태', value: '드롭', valueState: 'value' },
        ],
      },
    ],
    actions: [{ actionId: 'openDevStatusDetail', label: '전체 개발현황 보기' }],
    fallbackMarkdown:
      '| 생성일 | 고객 | 프로젝트 | 제품 | 벌크 | 연구원 | 랩넘버 | 상태 |\n|---|---|---|---|---|---|---|---|\n| 2026-06-20 | 케이프 주식회사 | 케이프 요철크림 | 케이프 요철크림 | 2건 | 김연구 | L-2026-0042 | 보류 |\n| 2026-06-22 | 뷰티랩(주) | 수분 진정 토너 | 수분 진정 토너 | 1건 | 박선임 | L-2026-0051 | 진행 중 |\n| 2026-06-18 | 코스메디(주) | 선쿠션 SPF50 | 선쿠션 SPF50 | 3건 | – | L-2026-0033 | 출시 완료 |\n| 2026-06-25 | 아우라코스(주) | 립밤 틴트 | 립밤 틴트 | – | 이책임 | – | 드롭 |',
  }
}

function devStatusFence(intent: unknown): string {
  return '개발현황 카드입니다.\n\n```cardintent\n' + JSON.stringify(intent) + '\n```'
}

describe('devStatus validation', () => {
  test('accepts the golden intent', () => {
    expect(validateDevStatus(goldenDevStatusIntent()).ok).toBe(true)
  })
  test('rejects the wrong kind', () => {
    expect(validateDevStatus({ ...goldenDevStatusIntent(), kind: 'quoteResult' }).ok).toBe(false)
  })
  test('rejects a non-string row value (unformatted cost leak shape)', () => {
    const bad = goldenDevStatusIntent()
    ;(bad.sections[0].rows[4] as unknown as Record<string, unknown>).value = 2
    expect(validateDevStatus(bad).ok).toBe(false)
  })
  test('rejects a non-enum valueState (fail-closed)', () => {
    const bad = goldenDevStatusIntent()
    ;(bad.sections[0].rows[0] as unknown as Record<string, unknown>).valueState = ['value']
    expect(validateDevStatus(bad).ok).toBe(false)
  })
  test('rejects empty sections', () => {
    expect(validateDevStatus({ ...goldenDevStatusIntent(), sections: [] }).ok).toBe(false)
  })
  test('rejects an unknown action id (fail-closed)', () => {
    const bad = goldenDevStatusIntent()
    ;(bad.actions![0] as unknown as Record<string, unknown>).actionId = 'deleteEverything'
    expect(validateDevStatus(bad).ok).toBe(false)
  })
  test('rejects a non-string action id (array smuggle)', () => {
    const bad = goldenDevStatusIntent()
    ;(bad.actions![0] as unknown as Record<string, unknown>).actionId = ['openDevStatusDetail']
    expect(validateDevStatus(bad).ok).toBe(false)
  })
})

describe('devStatus status-badge color mapping', () => {
  test('진행 중 / 단가확정 → Accent', () => {
    expect(devStatusBadgeColor('진행 중')).toBe('Accent')
    expect(devStatusBadgeColor('단가확정')).toBe('Accent')
  })
  test('보류 → Warning', () => {
    expect(devStatusBadgeColor('보류')).toBe('Warning')
  })
  test('출시 완료 → Good', () => {
    expect(devStatusBadgeColor('출시 완료')).toBe('Good')
  })
  test('드롭 → Attention', () => {
    expect(devStatusBadgeColor('드롭')).toBe('Attention')
  })
  test('unknown / empty status → Default (never throws)', () => {
    expect(devStatusBadgeColor('알수없는상태')).toBe('Default')
    expect(devStatusBadgeColor('')).toBe('Default')
    expect(devStatusBadgeColor('  보류  ')).toBe('Warning') // trimmed compare
  })
})

describe('devStatus render shape (one Container per dev-product)', () => {
  test('the golden renders 4 product Containers + a title TextBlock', () => {
    const card = buildDevStatusCard(goldenDevStatusIntent()) as Record<string, unknown>
    const body = card.body as Array<Record<string, unknown>>
    expect((body[0].text as string)).toBe('🧪 개발현황 — 개발제품 4건')
    const containers = body.filter(el => el.type === 'Container')
    expect(containers.length).toBe(4)
    const head = (c: Record<string, unknown>) => ((c.items as Array<Record<string, unknown>>)[0].text as string)
    expect(head(containers[0])).toBe('케이프 요철크림 · 보류')
    expect(head(containers[3])).toBe('립밤 틴트 · 드롭')
    // each Container ends with the 8-field FactSet
    for (const c of containers) {
      const items = c.items as Array<Record<string, unknown>>
      const factSet = items.find(el => el.type === 'FactSet') as Record<string, unknown>
      expect(factSet).toBeDefined()
      expect((factSet.facts as unknown[]).length).toBe(8)
    }
  })

  test('the status badge is colored by the 상태 row value', () => {
    const card = buildDevStatusCard(goldenDevStatusIntent()) as Record<string, unknown>
    const body = card.body as Array<Record<string, unknown>>
    const containers = body.filter(el => el.type === 'Container')
    // For each product, the SECOND item (after the Accent header) is the status badge.
    const badge = (c: Record<string, unknown>) => (c.items as Array<Record<string, unknown>>)[1]
    expect(badge(containers[0])).toMatchObject({ type: 'TextBlock', text: '보류', color: 'Warning' })
    expect(badge(containers[1])).toMatchObject({ type: 'TextBlock', text: '진행 중', color: 'Accent' })
    expect(badge(containers[2])).toMatchObject({ type: 'TextBlock', text: '출시 완료', color: 'Good' })
    expect(badge(containers[3])).toMatchObject({ type: 'TextBlock', text: '드롭', color: 'Attention' })
  })

  test("a literal '—' value renders VERBATIM (no empty/session fallback)", () => {
    const card = buildDevStatusCard(goldenDevStatusIntent()) as Record<string, unknown>
    const body = card.body as Array<Record<string, unknown>>
    const containers = body.filter(el => el.type === 'Container')
    // 선쿠션 (index 2): 연구원 = '—'; 립밤 (index 3): 벌크 = '—' 랩넘버 = '—'.
    const factsOf = (c: Record<string, unknown>) => {
      const items = c.items as Array<Record<string, unknown>>
      const fs = items.find(el => el.type === 'FactSet') as Record<string, unknown>
      return fs.facts as Array<{ title: string; value: string }>
    }
    const f2 = factsOf(containers[2])
    expect(f2.find(f => f.title === '연구원')!.value).toBe('—')
    const f3 = factsOf(containers[3])
    expect(f3.find(f => f.title === '벌크')!.value).toBe('—')
    expect(f3.find(f => f.title === '랩넘버')!.value).toBe('—')
  })

  test('AC v1.2 only — no Table / targetWidth / Action.Submit / ToggleVisibility', () => {
    const card = buildDevStatusCard(goldenDevStatusIntent())
    const types = collectTypes(card)
    expect(types).not.toContain('Table')
    expect(types).not.toContain('Action.Submit')
    expect(types).not.toContain('Action.ToggleVisibility')
    const bytes = JSON.stringify(card)
    expect(bytes).not.toContain('targetWidth')
    expect((card as Record<string, unknown>).version).toBe('1.2')
  })

  test('openDevStatusDetail → renderer-supplied domain-pinned OpenUrl (single action)', () => {
    const card = buildDevStatusCard(goldenDevStatusIntent()) as Record<string, unknown>
    const actions = card.actions as Array<Record<string, unknown>>
    expect(actions.length).toBe(1)
    expect(actions[0].type).toBe('Action.OpenUrl')
    expect(actions[0].url).toBe(devStatusDeeplink())
    expect(actions[0].title).toBe('전체 개발현황 보기')
  })

  test('the devStatus deeplink is the dev-status screen on the first allowed host', () => {
    expect(devStatusDeeplink({})).toBe('https://crm-qa.cosmax.com/d/?screen=dev-status')
    // env-overridable host
    expect(devStatusDeeplink({ BRIDGE_TEAMS_DEEPLINK_HOSTS: 'crm.cosmax.com' })).toBe(
      'https://crm.cosmax.com/d/?screen=dev-status',
    )
    // env-overridable slug (constrained charset; a junk slug falls back to default)
    expect(devStatusDeeplink({ BRIDGE_TEAMS_DEVSTATUS_SCREEN: 'dev-status-v2' })).toBe(
      'https://crm-qa.cosmax.com/d/?screen=dev-status-v2',
    )
    expect(devStatusDeeplink({ BRIDGE_TEAMS_DEVSTATUS_SCREEN: 'evil?x=1&y=2' })).toBe(
      'https://crm-qa.cosmax.com/d/?screen=dev-status',
    )
  })

  test('a cardintent-supplied payload.url is IGNORED — renderer pins the destination (no open redirect)', () => {
    for (const smuggled of [
      'https://evil.example.com/x',
      'https://crm-qa.cosmax.com/d/?screen=admin-export',
      'javascript:alert(1)',
    ]) {
      const intent = goldenDevStatusIntent()
      intent.actions = [
        { actionId: 'openDevStatusDetail', label: '전체 개발현황 보기', payload: { url: smuggled } },
      ]
      const card = buildDevStatusCard(intent) as Record<string, unknown>
      const actions = card.actions as Array<Record<string, unknown>>
      expect(actions.length).toBe(1)
      expect(actions[0].url).toBe('https://crm-qa.cosmax.com/d/?screen=dev-status')
      const cardStr = JSON.stringify(card)
      expect(cardStr).not.toContain('evil.example')
      expect(cardStr).not.toContain('admin-export')
      expect(cardStr).not.toContain('javascript:')
    }
  })

  test('a non-view actionId is DROPPED (no actions key)', () => {
    const intent = goldenDevStatusIntent()
    // smuggle a different (validation-rejected) id only via cast — buildDevStatusCard
    // is the last line of defense even past validation.
    ;(intent.actions![0] as unknown as Record<string, unknown>).actionId = 'createQuoteDoc'
    const card = buildDevStatusCard(intent) as Record<string, unknown>
    expect('actions' in card).toBe(false)
    expect(JSON.stringify(card)).not.toContain('Action.OpenUrl')
  })

  test('no actions key when nothing maps', () => {
    const intent = goldenDevStatusIntent()
    intent.actions = []
    const card = buildDevStatusCard(intent) as Record<string, unknown>
    expect('actions' in card).toBe(false)
  })
})

describe('devStatus via renderOutbound (seam + §10 + suppression)', () => {
  test('golden round-trip: fence → 4 product Containers + deeplink + NO Submit + suppressed text', () => {
    const out = renderOutbound(devStatusFence(goldenDevStatusIntent()))
    expect(out.attachments.length).toBe(1)
    expect(out.text).toBe('')
    expect(out.warning).toBeUndefined()
    const card = out.attachments[0].content as Record<string, unknown>
    expect(card.type).toBe('AdaptiveCard')
    const containers = (card.body as Array<Record<string, unknown>>).filter(el => el.type === 'Container')
    expect(containers.length).toBe(4)
    const actions = card.actions as Array<Record<string, unknown>>
    expect(actions.map(a => a.type)).toEqual(['Action.OpenUrl'])
    expect(JSON.stringify(card)).not.toContain('Action.Submit')
    // all four status badges present + correctly colored (the 2nd item of each
    // Container is the badge TextBlock)
    const badge = (c: Record<string, unknown>) => (c.items as Array<Record<string, unknown>>)[1]
    expect(badge(containers[0])).toMatchObject({ text: '보류', color: 'Warning' })
    expect(badge(containers[1])).toMatchObject({ text: '진행 중', color: 'Accent' })
    expect(badge(containers[2])).toMatchObject({ text: '출시 완료', color: 'Good' })
    expect(badge(containers[3])).toMatchObject({ text: '드롭', color: 'Attention' })
  })

  // MUTATION-PROOF: a §10 forbidden cost key anywhere in the devStatus card bytes
  // (here smuggled into a row value) must reject the WHOLE card → text-only. If
  // the §10 byte-scan is reverted, this test fails.
  test('§10 forbidden cost key in a devStatus row → text-only fallback', () => {
    const bad = goldenDevStatusIntent()
    bad.sections[0].rows.push({ label: '비고', value: '원가 12000', valueState: 'value' })
    const out = renderOutbound(devStatusFence(bad))
    expect(out.attachments.length).toBe(0)
    expect(out.warning).toContain('§10')
    expect(out.text).not.toContain('원가')
  })

  test('an invalid devStatus intent degrades to text-only, never throws', () => {
    const bad = { ...goldenDevStatusIntent(), title: 123 }
    expect(() => renderOutbound(devStatusFence(bad))).not.toThrow()
    const out = renderOutbound(devStatusFence(bad))
    expect(out.attachments.length).toBe(0)
    expect(out.warning).toContain('validation failed')
  })
})

describe('quoteResult + devReqAutofill paths are unchanged by the devStatus addition (regression)', () => {
  test('a valid quoteResult intent still renders with only its OpenUrl deeplink', () => {
    const out = renderOutbound(fence(validListIntent()))
    expect(out.attachments.length).toBe(1)
    const card = out.attachments[0].content as Record<string, unknown>
    const actions = (card.actions as Array<Record<string, unknown>>) ?? []
    expect(actions.map(a => a.type)).toEqual(['Action.OpenUrl'])
    expect(actions[0].url).toBe(quoteResultDeeplink())
  })

  test('a valid devReqAutofill intent still renders its emphasis Containers + deeplinks', () => {
    const out = renderOutbound(devReqFence(validDevReqIntent()))
    expect(out.attachments.length).toBe(1)
    const card = out.attachments[0].content as Record<string, unknown>
    const body = card.body as Array<Record<string, unknown>>
    expect(body.filter(el => el.type === 'Container' && el.style === 'emphasis').length).toBe(2)
    const actions = (card.actions as Array<Record<string, unknown>>) ?? []
    expect(actions.map(a => a.url)).toEqual([devReqDeeplink(), devReqDeeplink()])
  })
})
