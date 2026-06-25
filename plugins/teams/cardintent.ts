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
  // Korean/literal contract terms (the role-internal cost language that must
  // NEVER reach Teams in the card OR the visible text). Note: `내용물 견적` and
  // `가공비 견적` are the ALLOWED viewer-facing price labels and are deliberately
  // NOT in this list.
  '제시가',
  '원가',
  '마진',
  '공헌이익',
  '영업이익',
  '네고율',
  '회수율',
  '작업장명',
  '임률',
  '고객요청가',
  'manufacturingCostSuggested',
  'standardCost',
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
      // 미산출 = "산출중" (Warning/앰버). Do NOT show a number while calculating.
      return { text: '산출중', color: 'Warning' }
    case 'notRequested':
      // 미의뢰 = "–" subtle.
      return { text: '–', color: 'Default', isSubtle: true }
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

// ---------------------------------------------------------------------------
// Deeplink domain-pin (Phase-1a contract primitive)
//
// The quoteResult card carries ONE [전체 견적결과 보기] button = Action.OpenUrl
// into the web/d 견적결과 화면. The url MUST be domain-pinned: an off-domain /
// wrong-protocol / freeform url is dropped (the action is not emitted) so a
// compromised SKILL emit cannot turn the card into an open redirect. The host
// allowlist is env-overridable (QA vs prod) via BRIDGE_TEAMS_DEEPLINK_HOSTS
// (comma-separated); default is the QA host.
// ---------------------------------------------------------------------------

const DEFAULT_DEEPLINK_HOST = 'crm-qa.cosmax.com'

// Read the process env without pulling @types/node into this standalone-tested
// module (tsconfig `types: []`). The deeplink host override is read from the
// ambient env at call time; tests pass an explicit env to stay hermetic.
type EnvBag = Record<string, string | undefined>
function processEnv(): EnvBag {
  const g = globalThis as { process?: { env?: EnvBag } }
  return g.process?.env ?? {}
}

export function deeplinkHosts(env: EnvBag = processEnv()): readonly string[] {
  const raw = (env.BRIDGE_TEAMS_DEEPLINK_HOSTS ?? '').trim()
  if (!raw) return [DEFAULT_DEEPLINK_HOST]
  const hosts = raw
    .split(',')
    .map(h => h.trim().toLowerCase())
    .filter(h => h.length > 0)
  return hosts.length > 0 ? hosts : [DEFAULT_DEEPLINK_HOST]
}

// The canonical web/d 견적결과 deeplink (rfq-list screen). Built from the default
// host; if the host allowlist is env-overridden, the SKILL is expected to emit a
// payload.url on that host and it is validated by isAllowedDeeplink below.
export const DEFAULT_QUOTE_RESULT_DEEPLINK = `https://${DEFAULT_DEEPLINK_HOST}/d/?screen=rfq-list`

// Validate a candidate deeplink url against the domain-pin rules: parseable,
// exact https: protocol, host EXACTLY in the allowlist, no userinfo. Returns the
// normalized href when valid, or null (→ the action is dropped, never thrown).
export function isAllowedDeeplink(
  url: unknown,
  env: EnvBag = processEnv(),
): string | null {
  if (typeof url !== 'string' || url.length === 0) return null
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return null
  }
  if (parsed.protocol !== 'https:') return null
  // Reject userinfo embedded in the authority (a `user:pass@host` smuggle that
  // points the real host off-allowlist while the prefix mimics the pinned host).
  if (parsed.username !== '' || parsed.password !== '') return null
  const allowed = deeplinkHosts(env)
  if (!allowed.includes(parsed.hostname.toLowerCase())) return null
  return parsed.href
}

function textBlock(
  text: string,
  opts: {
    weight?: string
    size?: string
    color?: string
    isSubtle?: boolean
    wrap?: boolean
    horizontalAlignment?: string
  } = {},
): AcElement {
  const el: AcElement = { type: 'TextBlock', text, wrap: opts.wrap ?? true }
  if (opts.weight) el.weight = opts.weight
  if (opts.size) el.size = opts.size
  if (opts.color) el.color = opts.color
  if (opts.isSubtle) el.isSubtle = true
  if (opts.horizontalAlignment) el.horizontalAlignment = opts.horizontalAlignment
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

// The single actionId allowed to surface as a card action in Phase 1a: the
// [전체 견적결과 보기] view deeplink. Every other actionId (createQuoteDoc,
// reQuote, …) is Phase-2 territory and is dropped here — gating on the id (not
// just on "has a pinned url") stops an arbitrary action from laundering itself
// into an Action.OpenUrl by carrying an allowed-host url.
const QUOTE_RESULT_VIEW_ACTION_ID: ActionId = 'openQuoteResultDetail'

// Phase-1a quoteResult action mapping: the ONLY action the card may emit is the
// [전체 견적결과 보기] domain-pinned Action.OpenUrl deeplink. Action.Submit is
// Phase-2 territory and is never emitted, and a non-view actionId is dropped
// even if it carries a valid pinned url. The OpenUrl candidate is domain-pinned:
// an off-domain / wrong-protocol / freeform url is dropped too (action not
// emitted), never thrown. Returns the AC element or null (caller filters it out).
function toQuoteResultAction(a: Action): AcElement | null {
  if (a.actionId !== QUOTE_RESULT_VIEW_ACTION_ID) return null
  const validHref = isAllowedDeeplink(a.payload?.url)
  if (validHref) {
    return { type: 'Action.OpenUrl', title: a.label, url: validHref }
  }
  // The view action carries no valid pinned deeplink → drop (never a Submit, and
  // an off-domain url is rejected rather than emitted as an open redirect).
  return null
}

// quoteResult per-RFQ fields (#17138 6-field design). The card is the SINGLE
// mobile-safe per-product stack (appendix card 8): one Container per RFQ with a
// 고객·제품 header + a 용량/랩넘버 FactSet + 내용물 견적 / 가공비 견적 price rows.
// The wide 6-column desktop table (appendix card 7) is NOT rendered in chat — it
// lives behind the [전체 견적결과 보기] deeplink (the renderer cannot detect the
// Teams client device, so the narrow layout is the only safe one to push).
//
// 용량/랩넘버 are matched out of the section's rows by stable labels; missing →
// an em dash. The price cells are PriceCells (string-only Row.value) matched by
// the viewer-facing 내용물 견적 / 가공비 견적 labels (these are the ALLOWED §10
// price labels — never the role-internal cost language). The dropped beta2.2
// 견적 소계 / 산출상태 columns are gone: each price cell carries its own
// valueState (산출중/–) so a separate status column is redundant.
const FIELD_VOLUME_LABELS: readonly string[] = ['용량']
const FIELD_LABNO_LABELS: readonly string[] = ['랩넘버']
const FIELD_CONTENT_PRICE_LABELS: readonly string[] = ['내용물 견적']
const FIELD_PROCESSING_PRICE_LABELS: readonly string[] = ['가공비 견적']
const EMDASH = '—'

function findRow(rows: Row[], labels: readonly string[]): Row | undefined {
  return rows.find(r => labels.includes(r.label))
}

// A FactSet value for a non-price field (용량/랩넘버). These are plain spec
// fields, normally valueState:'value' — but a non-value state must NEVER fall
// through to the raw row.value (a masked/calculating row would otherwise leak
// its underlying data into the FactSet). Route every non-value state through
// renderValueState (masked→●●●, calculating→산출중, notRequested→–) and emit an
// em dash for a missing field / empty value.
function factValue(rows: Row[], labels: readonly string[]): string {
  const row = findRow(rows, labels)
  if (!row) return EMDASH
  if (row.valueState !== 'value') return renderValueState(row).text
  const v = typeof row.value === 'string' ? row.value.trim() : ''
  return v.length > 0 ? v : EMDASH
}

// A 내용물/가공비 견적 price row laid out per card-8: a [stretch: label subtle]
// [auto: PriceCell] ColumnSet (≤2 columns). A missing price row → an em dash
// (notRequested-style subtle). The PriceCell text/color comes from the row's
// valueState (value→bold number / calculating→산출중 Warning / notRequested→–).
function priceRow(label: string, rows: Row[], labels: readonly string[]): AcElement {
  const row = findRow(rows, labels)
  const rv: RenderedValue = row ? renderValueState(row) : { text: EMDASH, color: 'Default', isSubtle: true }
  return {
    type: 'ColumnSet',
    columns: [
      {
        type: 'Column',
        width: 'stretch',
        verticalContentAlignment: 'Center',
        items: [textBlock(label, { isSubtle: true })],
      },
      {
        type: 'Column',
        width: 'auto',
        verticalContentAlignment: 'Center',
        items: [
          textBlock(rv.text, {
            weight: row && row.valueState === 'value' ? 'Bolder' : undefined,
            color: rv.color,
            isSubtle: rv.isSubtle,
            wrap: false,
            horizontalAlignment: 'Right',
          }),
        ],
      },
    ],
  }
}

// list render (AC 1.2) = the mobile-safe per-product stack (appendix card 8):
// the title, then one Container (separator) per RFQ section. Each RFQ Container
// holds a 고객·제품 header (Accent, Bolder) + an `emphasis` Container with a
// 용량/랩넘버 FactSet and the 내용물 견적 / 가공비 견적 PriceCell rows. This is
// the ONLY chat layout — the wide 6-column desktop table (card 7) lives behind
// the [전체 견적결과 보기] deeplink. ColumnSet (NOT the AC 1.5 Table element)
// keeps us on AC 1.2 / no Table / no targetWidth, ≤3 columns per ColumnSet.
// Per-section actions are NOT emitted in Phase 1a (the only card action is the
// root domain-pinned deeplink); cardintent contract is unchanged — the server
// still sends generic sections/rows.
function renderRfqContainer(section: Section): AcElement {
  return {
    type: 'Container',
    separator: true,
    spacing: 'Medium',
    items: [
      textBlock(section.label, { weight: 'Bolder', color: 'Accent' }),
      {
        type: 'Container',
        style: 'emphasis',
        spacing: 'Small',
        items: [
          {
            type: 'FactSet',
            facts: [
              { title: '용량', value: factValue(section.rows, FIELD_VOLUME_LABELS) },
              { title: '랩넘버', value: factValue(section.rows, FIELD_LABNO_LABELS) },
            ],
          },
          priceRow('내용물 견적', section.rows, FIELD_CONTENT_PRICE_LABELS),
          priceRow('가공비 견적', section.rows, FIELD_PROCESSING_PRICE_LABELS),
        ],
      },
    ],
  }
}

function renderList(intent: CardIntent): AcElement[] {
  const body: AcElement[] = [textBlock(intent.title, { weight: 'Bolder', size: 'Medium' })]
  for (const section of intent.sections) {
    body.push(renderRfqContainer(section))
  }
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
  // Top-level CardIntent.actions → root actions, Phase-1a contract: the ONLY
  // action emitted is the domain-pinned [전체 견적결과 보기] Action.OpenUrl
  // deeplink. Action.Submit is dropped (Phase 2), and an off-domain / wrong-proto
  // deeplink is dropped too. If nothing survives the filter, no actions key is
  // emitted (an empty actions array would render an empty action bar).
  if (intent.actions && intent.actions.length > 0) {
    const actions = intent.actions
      .map(toQuoteResultAction)
      .filter((a): a is AcElement => a !== null)
    if (actions.length > 0) {
      card.actions = actions
    }
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

// §10-clean replacement for the visible prose when it carries a forbidden term.
// It contains no forbidden key itself, so substituting it is unconditionally
// safe. Used on the fence-present path only (the no-fence path is unchanged).
export const SECTION10_TEXT_FALLBACK =
  '[일부 내용은 보안 정책에 따라 카드로만 표시됩니다.]'

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

  // §10 also applies to the visible prose, not just the rendered card bytes: a
  // forbidden cost term emitted OUTSIDE the fence would otherwise be sent
  // unscanned. Hard-replace the whole visible text with a §10-clean fallback if
  // it carries any forbidden term, on BOTH the success and the fail() paths.
  const safeText = findForbiddenCostKey(strippedText, forbidden)
    ? SECTION10_TEXT_FALLBACK
    : strippedText

  const fail = (warning: string): RenderOutbound => ({
    text: safeText,
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
    text: safeText,
    attachments: [{ contentType: AC_CONTENT_TYPE, content: card }],
  }
}
