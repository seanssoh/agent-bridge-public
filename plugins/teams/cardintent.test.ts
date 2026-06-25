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
  DEFAULT_QUOTE_RESULT_DEEPLINK,
  deeplinkHosts,
  extractLastCardIntentFence,
  findForbiddenCostKey,
  FORBIDDEN_COST_KEYS_PLACEHOLDER,
  isAllowedDeeplink,
  isDetailLayout,
  renderOutbound,
  renderValueState,
  SECTION10_TEXT_FALLBACK,
  stripAllCardIntentFences,
  stripFence,
  validateCardIntent,
  type CardIntent,
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
        actionId: 'openQuoteResultDetail',
        label: '전체 견적결과 보기 (web/d)',
        payload: { url: 'https://crm-qa.cosmax.com/d/?screen=rfq-list' },
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
        payload: { url: 'https://crm-qa.cosmax.com/d/?screen=rfq-list' },
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
  test('Phase 1a: a non-deeplink action (no valid url) emits NO Action — never an Action.Submit', () => {
    // A validated action without a domain-pinned url is dropped: Phase 1a emits
    // no Submit. (Revert toQuoteResultAction back to a Submit fallback → this
    // fails: card.actions[0] would be an Action.Submit.)
    const card: any = buildAdaptiveCard({
      kind: 'quoteResult',
      title: 't',
      fallbackMarkdown: 's',
      sections: [
        { label: '금액강조', rows: [{ label: 'a', value: '1', valueState: 'value' }] },
      ],
      actions: [{ actionId: 'openQuoteResultDetail', label: 'go', payload: { quoteId: 'q1' } }],
    })
    expect(card.actions).toBeUndefined()
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
    expect(factSet.facts.map((f: any) => f.title)).toEqual(['용량', '랩넘버'])
    expect(factSet.facts[0].value).toBe('306 g')
    expect(factSet.facts[1].value).toBe('TESTCTO1')
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

  test('a valid deeplink is emitted as the card Action.OpenUrl', () => {
    const card: any = buildAdaptiveCard(validListIntent())
    expect(card.actions.length).toBe(1)
    expect(card.actions[0].type).toBe('Action.OpenUrl')
    expect(card.actions[0].url).toBe('https://crm-qa.cosmax.com/d/?screen=rfq-list')
    expect(card.actions[0].title).toContain('전체 견적결과 보기')
  })

  test('an off-domain deeplink is DROPPED — the action is not emitted, the card still renders', () => {
    const intent: any = validListIntent()
    intent.actions[0].payload.url = 'https://evil.example/d/?screen=rfq-list'
    const card: any = buildAdaptiveCard(intent)
    expect(card.actions).toBeUndefined() // dropped, not thrown
    expect(JSON.stringify(card)).not.toContain('evil.example')
    // the card body still rendered (graceful drop, not a whole-card failure)
    expect(card.body.length).toBeGreaterThan(1)
  })

  test('a NON-view actionId carrying a pinned (allowed-host) url is DROPPED — no url laundering', () => {
    // Only openQuoteResultDetail may surface as the card OpenUrl. A createQuoteDoc
    // (or any other) action that smuggles an allowed-host url must NOT be emitted
    // as an Action.OpenUrl. (Revert the actionId gate in toQuoteResultAction →
    // this fails: the createQuoteDoc action would attach as an OpenUrl.)
    const intent: any = validListIntent()
    intent.actions = [
      {
        actionId: 'createQuoteDoc',
        label: '견적서 생성',
        payload: { url: 'https://crm-qa.cosmax.com/d/?screen=rfq-list' },
      },
    ]
    const card: any = buildAdaptiveCard(intent)
    expect(card.actions).toBeUndefined() // dropped despite the valid pinned url
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
// human-visible prose OUTSIDE the fence would be sent unscanned. renderOutbound
// must hard-replace the whole visible text with a §10-clean fallback on the
// fence-present path (success AND fail), while leaving the no-fence path
// byte-for-byte unchanged.
// ---------------------------------------------------------------------------

describe('§10 visible-text fail-closed (mutation-proof)', () => {
  test('forbidden term in prose + CLEAN card → text hard-replaced, card still attached', () => {
    // The card is clean (no forbidden key) so it survives §10; the prose carries
    // a forbidden cost term ("원가") and MUST be replaced wholesale. Revert the
    // safeText substitution in renderOutbound → this fails: out.text would still
    // contain "원가는 1000원" and leak the forbidden term to Teams.
    const out = renderOutbound('원가는 1000원\n\n' + fence(validListIntent()))
    expect(out.text).toBe(SECTION10_TEXT_FALLBACK)
    expect(out.text).not.toContain('원가')
    expect(out.attachments.length).toBe(1) // clean card still sent
    expect(out.warning).toBeUndefined()
  })

  test('제시가 in the visible prose is hard-replaced (clean card still attached)', () => {
    const out = renderOutbound('제시가 기준으로 안내드립니다.\n\n' + fence(validListIntent()))
    expect(out.text).toBe(SECTION10_TEXT_FALLBACK)
    expect(out.text).not.toContain('제시가')
    expect(out.attachments.length).toBe(1)
  })

  test('clean prose + clean card → visible text unchanged (fence stripped), card attached', () => {
    const summary = '견적 결과를 카드로 정리했습니다.'
    const out = renderOutbound(summary + '\n\n' + fence(validListIntent()))
    expect(out.text).toBe(summary) // NOT replaced — the fallback only fires on a hit
    expect(out.text).not.toBe(SECTION10_TEXT_FALLBACK)
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

  test('allowed price labels 내용물 견적 / 가공비 견적 in prose pass (not forbidden)', () => {
    // These are the ALLOWED viewer-facing labels — they must NOT be on the
    // forbidden list, so the prose carrying them is sent unchanged.
    expect(findForbiddenCostKey('내용물 견적')).toBeNull()
    expect(findForbiddenCostKey('가공비 견적')).toBeNull()
    const summary = '내용물 견적과 가공비 견적을 안내드립니다.'
    const out = renderOutbound(summary + '\n\n' + fence(validListIntent()))
    expect(out.text).toBe(summary)
    expect(out.text).not.toBe(SECTION10_TEXT_FALLBACK)
    expect(out.attachments.length).toBe(1)
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
