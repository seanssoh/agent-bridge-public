// Adaptive Card renderer for the CRM `quoteResult` card — Model B.
//
// The Teams plugin reads the Claude session's outbound turn text and, if it
// contains a ```cardintent fenced block, renders it as a Bot Framework
// Adaptive Card (v1.2) attachment. This module is intentionally dependency-free
// (no botbuilder imports): it parses + validates + renders pure JSON so it can
// be unit-tested in isolation and so the server seam (`renderOutbound`) stays a
// thin, never-throwing wrapper around it.
//
// ADDITIVE CONTRACT: when no `cardintent` fence is present, `renderOutbound`
// returns the original text and NO attachments — the existing Teams reply path
// is byte-for-byte unchanged. On ANY failure (no fence / invalid JSON / schema
// fail / §10 forbidden-key fail) it degrades to text-only (fence stripped if
// one was present) and never throws.

// ---------------------------------------------------------------------------
// CardIntent contract (from cosmax-crm-cli card_intent.schema.json; encoded as
// TS types here until the schema is vendored). FIRM — do not redesign.
// ---------------------------------------------------------------------------

export type ValueState = 'value' | 'calculating' | 'notRequested' | 'masked'

// Closed enum of 11 action ids. An actionId outside this set rejects the whole
// CardIntent (the renderer never emits an action it cannot map).
export const ACTION_IDS = [
  'openQuoteResultDetail',
  'selectForQuoteDoc',
  'createQuoteDocFromSelection',
  'createQuoteDoc',
  'loadMoreQuotes',
  'reQuote',
  'cloneQuote',
  'renewQuote',
  'variantQuote',
  'openApprovalTrail',
  'shareQuote',
] as const
export type ActionId = (typeof ACTION_IDS)[number]

export const VALUE_STATES: readonly ValueState[] = [
  'value',
  'calculating',
  'notRequested',
  'masked',
]

export type Action = {
  actionId: ActionId
  label: string
  // payload carries identifier-only fields (account/product/quote ids). The
  // §10 golden runs over the rendered-card bytes, so a forbidden cost key
  // smuggled in here is caught at render time regardless of its nesting.
  payload: Record<string, unknown>
}

export type Row = {
  label: string
  // STRING ONLY — a numeric value is a contract violation (the SKILL formats
  // money into strings before emitting the fence; a number here means an
  // unformatted / un-masked cost leaked).
  value: string
  valueState: ValueState
}

export type Section = {
  label: string
  rows: Row[]
  actions?: Action[]
}

export type CardIntent = {
  kind: 'quoteResult'
  title: string
  sections: Section[]
  actions?: Action[]
  fallbackMarkdown: string
}

// ---------------------------------------------------------------------------
// §10 forbidden cost keys.
//
// Contract-derived PLACEHOLDER. The authoritative list is shipped by crm-dev
// as cosmax-crm-cli `forbidden_cost_keys.gen.json` and must be hash-pinned.
// TODO(#92): vendor cosmax-crm-cli forbidden_cost_keys.gen.json hash b0d6c661
// + hash-pin (replace this placeholder with the generated, version-pinned set).
//
// These are raw internal cost-component keys that must NEVER reach Teams: if any
// appears anywhere in the rendered Adaptive Card JSON bytes we reject the card
// and fall back to text-only. The check is on the SERIALIZED bytes, so the key
// is caught whether it leaks via a Row.value, an action payload, a label, or any
// other nested position.
export const FORBIDDEN_COST_KEYS_PLACEHOLDER: readonly string[] = [
  'unitCost',
  'unit_cost',
  'rawMaterialCost',
  'raw_material_cost',
  'materialCost',
  'material_cost',
  'laborCost',
  'labor_cost',
  'processingCostInternal',
  'processing_cost_internal',
  'marginRate',
  'margin_rate',
  'markupRate',
  'markup_rate',
  'costBreakdown',
  'cost_breakdown',
  'internalCost',
  'internal_cost',
  'supplierCost',
  'supplier_cost',
  'landedCost',
  'landed_cost',
]

// ---------------------------------------------------------------------------
// Fence extraction
// ---------------------------------------------------------------------------

// Matches fenced blocks whose info string is exactly `cardintent` (optionally
// followed by trailing whitespace). Tolerant of ``` or ~~~ openers and of
// leading indentation on the fence line. Captures the inner body and the full
// span so the caller can strip it from the visible text.
const FENCE_RE = /^[ \t]*(`{3,}|~{3,})[ \t]*cardintent[ \t]*\r?\n([\s\S]*?)\r?\n[ \t]*\1[ \t]*$/gim

export type FenceMatch = {
  body: string
  // full matched span (the entire ```cardintent ... ``` block) for stripping.
  full: string
}

// Returns the LAST cardintent fence in the text, or null if none.
export function extractLastCardIntentFence(text: string): FenceMatch | null {
  if (typeof text !== 'string' || text.length === 0) return null
  let last: FenceMatch | null = null
  // Reset lastIndex each call (the regex is global + reused).
  FENCE_RE.lastIndex = 0
  for (const m of text.matchAll(FENCE_RE)) {
    last = { body: m[2] ?? '', full: m[0] }
  }
  return last
}

// Removes the given fence span from the text and tidies the surrounding
// whitespace so the human-readable summary reads cleanly. Only the exact span
// is removed (first occurrence of that exact block), leaving any other text —
// including other fenced code blocks — intact.
export function stripFence(text: string, full: string): string {
  const idx = text.indexOf(full)
  if (idx < 0) return text
  const before = text.slice(0, idx)
  const after = text.slice(idx + full.length)
  // Collapse the blank-line seam left where the fence used to be.
  return (before.replace(/[ \t]+$/, '') + after)
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

// Removes EVERY `cardintent` fenced block from the text — not just the last
// one — so a multi-fence turn never leaks earlier raw JSON to the user. The
// renderer still uses extractLastCardIntentFence() to pick WHICH intent to
// render, but the visible text must have ALL cardintent fences stripped (the
// "user must never see raw JSON" contract holds regardless of fence count).
// Other fenced code blocks (```js, ```json, …) are left intact because the
// fence regex matches the `cardintent` info-string only.
export function stripAllCardIntentFences(text: string): string {
  if (typeof text !== 'string' || text.length === 0) return text
  // Reset lastIndex each call (the regex is global + reused).
  FENCE_RE.lastIndex = 0
  const stripped = text.replace(FENCE_RE, '')
  // Collapse the trailing-space + blank-line seams left where fences used to be.
  return stripped
    .replace(/[ \t]+$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

export type ValidationResult =
  | { ok: true; intent: CardIntent }
  | { ok: false; reason: string }

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function validateAction(a: unknown, where: string): string | null {
  if (!isPlainObject(a)) return `${where}: action must be an object`
  // Fail-closed: actionId must be a STRING in the closed enum. A non-string
  // (e.g. the array `["openQuoteResultDetail"]`) would stringify to an allowed
  // id and slip past a `String(...)`-based check — reject it by type first.
  if (typeof a.actionId !== 'string' || !(ACTION_IDS as readonly string[]).includes(a.actionId)) {
    return `${where}: actionId "${String(a.actionId)}" not a string in the allowed enum`
  }
  if (typeof a.label !== 'string' || a.label.length === 0) {
    return `${where}: action.label must be a non-empty string`
  }
  if (a.payload !== undefined && !isPlainObject(a.payload)) {
    return `${where}: action.payload must be an object when present`
  }
  // payload is an identifier allowlist only — it must NOT carry an `actionId`
  // (that would let a malicious payload override the validated, enum-checked id
  // in the rendered card).
  if (isPlainObject(a.payload) && 'actionId' in a.payload) {
    return `${where}: action.payload must not contain an actionId key`
  }
  return null
}

function validateRow(r: unknown, where: string): string | null {
  if (!isPlainObject(r)) return `${where}: row must be an object`
  if (typeof r.label !== 'string') return `${where}: row.label must be a string`
  // value is STRING ONLY — a number (or any non-string) is a contract breach.
  if (typeof r.value !== 'string') {
    return `${where}: row.value must be a string (got ${typeof r.value})`
  }
  // Fail-closed: valueState must be a STRING in the closed enum. A non-string
  // (e.g. `["calculating"]`) would stringify past a `String(...)` check, then
  // miss every `switch` case in renderValueState and fall through to the raw
  // `row.value` — leaking a value that should have been masked/withheld.
  if (typeof r.valueState !== 'string' || !(VALUE_STATES as readonly string[]).includes(r.valueState)) {
    return `${where}: row.valueState "${String(r.valueState)}" not a string in the allowed enum`
  }
  return null
}

function validateSection(s: unknown, where: string): string | null {
  if (!isPlainObject(s)) return `${where}: section must be an object`
  if (typeof s.label !== 'string') return `${where}: section.label must be a string`
  if (!Array.isArray(s.rows)) return `${where}: section.rows must be an array`
  for (let i = 0; i < s.rows.length; i++) {
    const err = validateRow(s.rows[i], `${where}.rows[${i}]`)
    if (err) return err
  }
  if (s.actions !== undefined) {
    if (!Array.isArray(s.actions)) return `${where}: section.actions must be an array when present`
    for (let i = 0; i < s.actions.length; i++) {
      const err = validateAction(s.actions[i], `${where}.actions[${i}]`)
      if (err) return err
    }
  }
  return null
}

// Validate a parsed JSON value against the CardIntent shape. Strict: any
// structural mismatch rejects.
export function validateCardIntent(value: unknown): ValidationResult {
  if (!isPlainObject(value)) return { ok: false, reason: 'root is not an object' }
  if (value.kind !== 'quoteResult') {
    return { ok: false, reason: `kind must be "quoteResult" (got ${JSON.stringify(value.kind)})` }
  }
  if (typeof value.title !== 'string') return { ok: false, reason: 'title must be a string' }
  if (typeof value.fallbackMarkdown !== 'string') {
    return { ok: false, reason: 'fallbackMarkdown must be a string' }
  }
  if (!Array.isArray(value.sections)) return { ok: false, reason: 'sections must be an array' }
  if (value.sections.length === 0) return { ok: false, reason: 'sections must be non-empty' }
  for (let i = 0; i < value.sections.length; i++) {
    const err = validateSection(value.sections[i], `sections[${i}]`)
    if (err) return { ok: false, reason: err }
  }
  if (value.actions !== undefined) {
    if (!Array.isArray(value.actions)) return { ok: false, reason: 'actions must be an array when present' }
    for (let i = 0; i < value.actions.length; i++) {
      const err = validateAction(value.actions[i], `actions[${i}]`)
      if (err) return { ok: false, reason: err }
    }
  }
  return { ok: true, intent: value as unknown as CardIntent }
}

// ---------------------------------------------------------------------------
// valueState → 문구/색 mapping (renderer's responsibility)
// ---------------------------------------------------------------------------

type RenderedValue = { text: string; color: string; isSubtle?: boolean }

export function renderValueState(row: Row): RenderedValue {
  switch (row.valueState) {
    case 'value':
      return { text: row.value, color: 'Default' }
    case 'calculating':
      // Do NOT show a number while calculating.
      return { text: '(계산중)', color: 'Warning' }
    case 'notRequested':
      return { text: '(해당없음)', color: 'Default', isSubtle: true }
    case 'masked':
      return { text: '●●●', color: 'Accent' }
    default:
      // Unreachable after validation (valueState is enum-checked to a string).
      // Defense-in-depth: NEVER fall through to the raw `row.value` — an
      // unexpected state must not leak a value that a masked/withheld state
      // would have hidden. Render the masked placeholder instead.
      return { text: '●●●', color: 'Accent' }
  }
}

// ---------------------------------------------------------------------------
// Adaptive Card element builders (plain JSON; AC v1.2 allowed elements only)
// ---------------------------------------------------------------------------

type AcElement = Record<string, unknown>

const AC_VERSION = '1.2'
const AC_TYPE = 'AdaptiveCard'
const AC_CONTENT_TYPE = 'application/vnd.microsoft.card.adaptive'
// Keep cards comfortably under the practical Teams payload ceiling.
const MAX_CARD_BYTES = 28 * 1024

function textBlock(
  text: string,
  opts: { weight?: string; size?: string; color?: string; isSubtle?: boolean; wrap?: boolean } = {},
): AcElement {
  const el: AcElement = { type: 'TextBlock', text, wrap: opts.wrap ?? true }
  if (opts.weight) el.weight = opts.weight
  if (opts.size) el.size = opts.size
  if (opts.color) el.color = opts.color
  if (opts.isSubtle) el.isSubtle = true
  return el
}

// A money/spec FactSet from a section's rows. valueState mapping is applied
// per-row; the title carries any per-row subtlety via a prefix is not possible
// in a FactSet (no per-fact color in AC 1.2), so subtle/notRequested values use
// the mapped text directly and lean on the parenthetical 문구.
function factSet(rows: Row[]): AcElement {
  return {
    type: 'FactSet',
    facts: rows.map(r => {
      const rv = renderValueState(r)
      return { title: r.label, value: rv.text }
    }),
  }
}

// An ActionSet from a list of Actions. Only Submit/OpenUrl are emitted (the
// renderer maps every action to Action.Submit carrying the actionId + payload;
// a deep-link payload, if present, becomes Action.OpenUrl). ShowCard is
// root-only and not emitted from per-section sets.
function actionSet(actions: Action[]): AcElement {
  return {
    type: 'ActionSet',
    actions: actions.map(toSubmitAction),
  }
}

function toSubmitAction(a: Action): AcElement {
  const url = typeof a.payload?.url === 'string' ? (a.payload.url as string) : ''
  if (url) {
    return { type: 'Action.OpenUrl', title: a.label, url }
  }
  return {
    type: 'Action.Submit',
    title: a.label,
    // actionId LAST so the validated, enum-checked id is authoritative and a
    // payload key can never override it (defense-in-depth; validateAction also
    // rejects a payload carrying actionId).
    data: { ...a.payload, actionId: a.actionId },
  }
}

// quoteResult LIST columns (≤3). Column 1 is the section label
// (accountName · productName). Columns 2–3 are matched out of the section's
// rows by these STABLE labels — NOT the role-scoped 내용물/가공비 cost labels,
// which the server rewrites per viewer role ("제시가" vs "견적"); 견적 소계 and
// 산출상태 are stable across roles. A missing column → an em dash (never a raw
// leak). `세트` (set), if present and truthy, decorates the status with a ✓.
// col2 = 견적 소계 (quote subtotal), NOT 확정가: live RFQs leave 확정가 unset
// (notRequested) until after customer agreement, so a 확정가 column reads as all
// em dashes; 견적 소계 is the populated, stable quote headline. Match both the
// spaced and unspaced spelling the server may emit.
const COL_PRICE_LABELS: readonly string[] = ['견적 소계', '견적소계']
// Strict single stable label only — a generic '상태' row (e.g. 결재상태) must
// NOT be picked up for the 산출상태 column; a section without 산출상태 renders
// an em dash, as promised (role-scope-safe, no incidental status leak).
const COL_STATUS_LABELS: readonly string[] = ['산출상태']
const COL_SET_LABELS: readonly string[] = ['세트', 'set']
const EMDASH: RenderedValue = { text: '—', color: 'Default' }

function findRow(rows: Row[], labels: readonly string[]): Row | undefined {
  return rows.find(r => labels.includes(r.label))
}

// A single Column carrying one TextBlock (AC 1.2). `width` is 'stretch' | 'auto'.
function column(
  text: string,
  width: string,
  opts: { weight?: string; color?: string; isSubtle?: boolean } = {},
): AcElement {
  return {
    type: 'Column',
    width,
    items: [textBlock(text, { weight: opts.weight, color: opts.color, isSubtle: opts.isSubtle, wrap: true })],
  }
}

function columnSetRow(columns: AcElement[], separator: boolean): AcElement {
  return { type: 'ColumnSet', separator, columns }
}

// list render (AC 1.2): a compact ColumnSet "table" — a header row + one row
// per RFQ section (≤3 columns: 고객·제품 | 확정가 | 상태), so multiple quote
// results scan record-by-record. ColumnSet (NOT the AC 1.5 Table element) wraps
// gracefully on a narrow screen; the #15157 mobile-LCD constraint keeps us on
// AC 1.2 / no Table / no targetWidth. Per-section actions, if any, follow the
// row as an ActionSet. cardintent contract is unchanged — the server still
// sends generic sections/rows; this renderer just lays the list out as a table.
function renderList(intent: CardIntent): AcElement[] {
  const body: AcElement[] = [textBlock(intent.title, { weight: 'Bolder', size: 'Medium' })]
  // header row
  body.push(
    columnSetRow(
      [
        column('고객·제품', 'stretch', { weight: 'Bolder', isSubtle: true }),
        column('견적 소계', 'auto', { weight: 'Bolder', isSubtle: true }),
        column('상태', 'auto', { weight: 'Bolder', isSubtle: true }),
      ],
      false,
    ),
  )
  intent.sections.forEach((section, idx) => {
    const priceRow = findRow(section.rows, COL_PRICE_LABELS)
    const statusRow = findRow(section.rows, COL_STATUS_LABELS)
    const setRow = findRow(section.rows, COL_SET_LABELS)
    const price = priceRow ? renderValueState(priceRow) : EMDASH
    const status = statusRow ? renderValueState(statusRow) : EMDASH
    const setMark = setRow && setRow.valueState === 'value' && setRow.value.trim() ? ' ✓' : ''
    body.push(
      columnSetRow(
        [
          column(section.label, 'stretch', { weight: 'Bolder' }),
          column(price.text, 'auto', { color: price.color, isSubtle: price.isSubtle }),
          column(status.text + setMark, 'auto', { color: status.color, isSubtle: status.isSubtle }),
        ],
        idx > 0,
      ),
    )
    if (section.actions && section.actions.length > 0) {
      body.push(actionSet(section.actions))
    }
  })
  return body
}

// detail render: a vertical FactSet layout, one Container per named section.
// A section labelled with a 금액/amount cue gets style:"emphasis".
function isEmphasisSection(label: string): boolean {
  return /금액|amount|emphasis|강조/i.test(label)
}

function renderDetail(intent: CardIntent): AcElement[] {
  const body: AcElement[] = [textBlock(intent.title, { weight: 'Bolder', size: 'Medium' })]
  intent.sections.forEach(section => {
    const container: AcElement = {
      type: 'Container',
      separator: true,
      items: [
        textBlock(section.label, { weight: 'Bolder' }),
        factSet(section.rows),
      ],
    }
    if (isEmphasisSection(section.label)) {
      container.style = 'emphasis'
    }
    body.push(container)
  })
  return body
}

// Heuristic: a CardIntent with a single named-section-per-aspect layout is a
// "detail" card; multiple RFQ cards (each a Section with its own money block)
// is a "list". The SKILL signals intent shape via section count + the emphasis
// cue. We treat >1 section without any emphasis cue as a list; a single section,
// or any section carrying the 금액강조 cue, as detail.
export function isDetailLayout(intent: CardIntent): boolean {
  if (intent.sections.length <= 1) return true
  return intent.sections.some(s => isEmphasisSection(s.label))
}

// Build the Adaptive Card content object (the `content` of the attachment).
export function buildAdaptiveCard(intent: CardIntent): AcElement {
  const body = isDetailLayout(intent) ? renderDetail(intent) : renderList(intent)
  const card: AcElement = {
    type: AC_TYPE,
    $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
    version: AC_VERSION,
    body,
  }
  // Top-level CardIntent.actions → root ActionSet (Submit/OpenUrl). ShowCard is
  // permitted at the root only; we do not currently emit ShowCard but reserve
  // the root position for it.
  if (intent.actions && intent.actions.length > 0) {
    card.actions = intent.actions.map(toSubmitAction)
  }
  return card
}

// ---------------------------------------------------------------------------
// §10 forbidden-key golden over the rendered bytes
// ---------------------------------------------------------------------------

// Returns the first forbidden cost key found in the serialized card bytes, or
// null if clean. Case-sensitive substring scan over the JSON — a forbidden key
// anywhere (value, label, payload field name or value) trips the guard.
export function findForbiddenCostKey(
  cardJson: string,
  forbidden: readonly string[] = FORBIDDEN_COST_KEYS_PLACEHOLDER,
): string | null {
  for (const key of forbidden) {
    if (cardJson.includes(key)) return key
  }
  return null
}

// ---------------------------------------------------------------------------
// The seam: renderOutbound(text) → { text, attachments }
// ---------------------------------------------------------------------------

export type TeamsAttachment = { contentType: string; content: unknown }

export type RenderOutbound = {
  // The text to put in activity.text (fence stripped on success OR on a
  // present-but-invalid fence; unchanged when no fence is present).
  text: string
  // attachments[0] = the Adaptive Card on success; empty on the text-only path.
  attachments: TeamsAttachment[]
  // Diagnostic: why we fell back to text-only (undefined on success / no fence).
  warning?: string
}

// Pure, never-throwing. Logging is the caller's job (it passes a logger); this
// returns a structured result so it's trivially unit-testable.
export function renderOutbound(
  text: string,
  opts: { forbidden?: readonly string[] } = {},
): RenderOutbound {
  const forbidden = opts.forbidden ?? FORBIDDEN_COST_KEYS_PLACEHOLDER
  // No fence → existing path, byte-for-byte unchanged.
  let fence: FenceMatch | null = null
  try {
    fence = extractLastCardIntentFence(text)
  } catch {
    fence = null
  }
  if (!fence) {
    return { text, attachments: [] }
  }

  // A fence is present: from here on the user must never see raw JSON, so the
  // visible text always has ALL cardintent fences stripped (not just the one
  // we render from), even on the failure path. A multi-fence turn would
  // otherwise leak the earlier raw fenced JSON to the user.
  const strippedText = (() => {
    try {
      return stripAllCardIntentFences(text)
    } catch {
      return text
    }
  })()

  const fail = (warning: string): RenderOutbound => ({
    text: strippedText,
    attachments: [],
    warning,
  })

  // Parse JSON.
  let parsed: unknown
  try {
    parsed = JSON.parse(fence.body)
  } catch (err) {
    return fail(`cardintent JSON parse failed: ${(err as Error).message}`)
  }

  // Validate shape.
  const validation = validateCardIntent(parsed)
  if (!validation.ok) {
    return fail(`cardintent validation failed: ${validation.reason}`)
  }

  // Render.
  let card: AcElement
  try {
    card = buildAdaptiveCard(validation.intent)
  } catch (err) {
    return fail(`cardintent render failed: ${(err as Error).message}`)
  }

  // §10 golden over the rendered bytes.
  const cardJson = JSON.stringify(card)
  const forbiddenHit = findForbiddenCostKey(cardJson, forbidden)
  if (forbiddenHit) {
    return fail(`cardintent §10 forbidden cost key in rendered card: ${forbiddenHit}`)
  }

  // Size guard — oversized cards fall back to text-only rather than risk a
  // Teams reject of the whole activity.
  if (cardJson.length > MAX_CARD_BYTES) {
    return fail(`cardintent rendered card too large: ${cardJson.length} > ${MAX_CARD_BYTES} bytes`)
  }

  return {
    text: strippedText,
    attachments: [{ contentType: AC_CONTENT_TYPE, content: card }],
  }
}
