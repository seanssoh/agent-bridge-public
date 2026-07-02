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
// devReqAutofill CardIntent (the 개발의뢰 draft autofill card — #17471).
//
// A SECOND, independent card kind that reuses the same fence + §10 + seam
// machinery as quoteResult but renders a different shape: a per-project grouped
// draft (one `emphasis` Container per project, each a stack of labelled
// FactSets) + a trailing "보완 필요" warning Container, with renderer-supplied
// deeplink actions ONLY. Action.Submit (confirmDevReq) is Phase-2 (a trusted
// server-side handler is required) and is NEVER emitted here.
//
// SECTION-ORDER grouping convention (LOCKED with crm-dev #17538, the preview_card
// emit contract). crm-dev emits a flat ordered section list:
//
//   [ {label: projectTitle, rows: []},        // empty-rows = a new project header
//     {label: '프로젝트정보', rows: [...]},     // content sections nest under it…
//     {label: '제품정보',     rows: [...]},
//     {label: '벌크1',        rows: [...]},
//     {label: projectTitle2,  rows: []},        // …until the next empty-rows header
//     {label: '프로젝트정보', rows: [...]},
//     {label: '⚠ 보완 필요',  rows: [missing-field labels]} ]  // trailing warning
//
// The renderer walks the list: an EMPTY-rows section opens a new `emphasis`
// Container (its label is the Accent project header); each following non-empty
// content section nests as a subheader + FactSet until the next empty-rows
// header; the trailing `⚠ 보완 …` section renders as a `warning` Container. A
// content section with NO open project header renders standalone — the flat
// safety-net, so the operator's 2-way de-risk falls out of the same code path.
//
// actions: crm-dev emits confirmDevReq / editDevReq actionIds (entity-id payload,
// NO url); the RENDERER injects a domain-pinned OpenUrl deeplink (same as
// quoteResult — the cardintent never supplies the url). Action.Submit is never
// emitted; an unknown actionId is dropped.
// ---------------------------------------------------------------------------

// Closed enum of devReq action ids. An actionId outside this set is dropped (the
// renderer never emits an action it cannot map to a domain-pinned deeplink).
export const DEVREQ_ACTION_IDS = ['confirmDevReq', 'editDevReq'] as const
export type DevReqActionId = (typeof DEVREQ_ACTION_IDS)[number]

export type DevReqAction = {
  actionId: DevReqActionId
  // payload carries entity-identifier fields only and is NEVER read for the url
  // (the renderer supplies a domain-pinned deeplink) — so a forbidden cost key
  // smuggled here is still caught by the §10 byte scan over the rendered card.
  label: string
  payload?: Record<string, unknown>
}

export type DevReqAutofillIntent = {
  kind: 'devReqAutofill'
  title: string
  subtitle?: string
  // Flat ordered section list (see the convention above): empty-rows project
  // headers interleaved with their content sections + a trailing 보완 section.
  sections: Section[]
  actions?: DevReqAction[]
  fallbackMarkdown: string
}

// ---------------------------------------------------------------------------
// §10 forbidden cost keys.
//
// VENDORED from cosmax-crm-cli `contract/adaptivecard/forbidden_cost_keys.gen.json`
// (the §10 SSOT), PR#840 @ f9f6094 on crm `main` — operator-approved 2-key
// allowlist (#20704: `suggestedPrice` + `manufacturingSuggestedPrice` are the
// ONLY sales-permitted price fields; `mSuggestedReason` is forbidden). The
// field-name set below is the golden's `forbidden` array, INLINED so this module
// stays dependency-free; cardintent.test.ts hash-pins it by recomputing the crm
// digest (sha256 over sorted forbidden∪allow) over this INLINED exported list
// plus the explicit two-key allowlist and asserting it === the golden's hash ===
// FORBIDDEN_COST_KEYS_GOLDEN_HASH — so ANY drift in this inlined list fails CI.
// (The vendored .gen.json is committed as the byte-for-byte SSOT provenance; the
// test does not read it — it recomputes over the inlined list, which is the
// runtime source of truth.) Closes #92.
//
// These keys must NEVER reach Teams: if any appears anywhere in the rendered
// Adaptive Card JSON bytes we reject the card and fall back to text-only. The
// check is on the SERIALIZED bytes, so the key is caught whether it leaks via a
// Row.value, an action payload, a label, or any other nested position.
export const FORBIDDEN_COST_KEYS_GOLDEN_HASH =
  '99f20d8c8efca4521415a030afd954d555edf0b5b201c3d3b5797b44327fcba7'

// Field-name keys — the vendored crm SSOT (hash-pinned above). Exported so the
// test can recompute the crm hash over this set ∪ the allow keys and assert it
// equals FORBIDDEN_COST_KEYS_GOLDEN_HASH (drift-guard; the test uses the global
// Web Crypto `crypto.subtle`, so no fs/crypto-module import is needed).
export const FORBIDDEN_COST_FIELD_KEYS: readonly string[] = [
  'activityPrice',
  'actualPurchasedUnitPrice',
  'actualPurchasedUnitPriceNew',
  'calcError',
  'capa',
  'costBreakdown',
  'customerRequested',
  'customerRequestedManu',
  'decisionLogs',
  'erpUnitPrice',
  'expectedProfitRate',
  'fixedDirectIndirect',
  'fixedDirectIndirectExpenses',
  'fixedFacilityExpenses',
  'fixedLaborCosts',
  'freeText',
  'inputEffort',
  'inputEffortC',
  'inputEffortM',
  'inputEffortP',
  'mFixedDirectIndirectExpenses',
  'mFixedFacilityExpenses',
  'mFixedLaborCosts',
  'mOutsourcingProcessCost',
  'mSuggestedReason',
  'mTotalFixedCost',
  'mTotalVariableCost',
  'mVariableFacilityExpenses',
  'mVariableLaborCosts',
  'mWorkplaceC',
  'mWorkplaceM',
  'mWorkplaceP',
  'machineTimeC',
  'machineTimeM',
  'machineTimeP',
  'manufacturingCostBreakdown',
  'manufacturingCostSuggested',
  'manufacturingCostSuggestedPrice',
  'maxKg',
  'negotiationRate',
  'operatingProfitRate',
  'outsourcingCost',
  'outsourcingCostC',
  'outsourcingCostP',
  'outsourcingCostTotal',
  'pricingTiers',
  'quotedCost',
  'realCost',
  'realRecoveryRatePct',
  'recoveryOfFixedCost',
  'recoveryOfFixedCostB',
  'recoveryRatePct',
  'salesAndManagementCost',
  'salesManagementCost',
  'salesManagementCostVariable',
  'sgaBasis',
  'stages',
  'standardCost',
  'totalCost',
  'totalFixedCost',
  'totalVariableCost',
  'unitPrice',
  'variableFacilityExpenses',
  'variableLaborCosts',
  'workingHourC',
  'workingHourM',
  'workingHourP',
  'workplaceC',
  'workplaceM',
  'workplaceP',
]

// Visible Korean cost terms — a teams-renderer VISIBLE-TEXT layer that the crm
// field-name golden does NOT cover (the golden is JSON field names only). Aligned
// to the same #20704 decision: `제시가` (suggestedPrice) is now sales-allowed so it
// is REMOVED (and removing it also stops the allowed `가공비제시가` from
// false-tripping on the `제시가` substring); `제시사유` (mSuggestedReason) is
// forbidden and ADDED here for the visible-text scan (the field key is already in
// the golden).
//
// GOVERNANCE (crm-dev #20652, owner decision): this layer is intentionally
// teams-OWNED and NOT folded into the crm hash-pinned golden. The field-name
// golden is the by-construction security SSOT (the renderer's allowlist
// projection never serializes a raw cost VALUE, so a Korean label cannot leak a
// number); Korean cost words are open-ended fuzzy synonyms that would make a
// closed, hash-pinned golden brittle; and display-text validation is the
// renderer's layer, not the crm data SSOT's. Each term below is DERIVED from a
// crm forbidden field (the visible Korean rendering of it) — KOREAN_TERM_ORIGIN
// records that correspondence and a test asserts every term's origin field is in
// the vendored golden, so the two layers cannot silently diverge.
const FORBIDDEN_COST_KOREAN_TERMS: readonly string[] = [
  '원가',
  '마진',
  '공헌이익',
  '영업이익',
  '네고율',
  '회수율',
  '작업장명',
  '임률',
  '고객요청가',
  '제시사유',
]

// Provenance for the visible Korean layer: each visible term → the crm forbidden
// FIELD key it is the Korean rendering of. The consistency test (crm-dev #20652
// alternative) asserts every origin field is present in the vendored golden, so a
// Korean term can never outlive the removal of its underlying forbidden field.
export const KOREAN_TERM_ORIGIN: Readonly<Record<string, string>> = {
  '원가': 'realCost',
  '마진': 'expectedProfitRate',
  '공헌이익': 'recoveryOfFixedCost',
  '영업이익': 'operatingProfitRate',
  '네고율': 'negotiationRate',
  '회수율': 'recoveryRatePct',
  '작업장명': 'workplaceP',
  '임률': 'activityPrice',
  '고객요청가': 'customerRequested',
  '제시사유': 'mSuggestedReason',
}

// The §10 scan set = vendored field-name SSOT ∪ teams visible Korean terms.
export const FORBIDDEN_COST_KEYS: readonly string[] = [
  ...FORBIDDEN_COST_FIELD_KEYS,
  ...FORBIDDEN_COST_KOREAN_TERMS,
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
// into the web/d 견적결과 화면. The RENDERER supplies the url (the rfq-list screen
// on the first configured allowed host) — the cardintent never carries/controls
// it — so a compromised SKILL emit has zero open-redirect surface. The host
// allowlist is env-overridable (QA vs prod) via BRIDGE_TEAMS_DEEPLINK_HOSTS
// (comma-separated); default is the QA host. isAllowedDeeplink remains the
// belt-and-suspenders validator the renderer-built url is checked against.
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
// host; when the host allowlist is env-overridden, the renderer builds the url on
// the first configured host (see quoteResultDeeplink) — the cardintent never
// supplies the url, so there is no open-redirect surface.
export const DEFAULT_QUOTE_RESULT_DEEPLINK = `https://${DEFAULT_DEEPLINK_HOST}/d/?screen=rfq-list`

// The renderer-supplied 견적결과 deeplink for the current env: the rfq-list screen
// on the FIRST configured allowed host (default crm-qa.cosmax.com, overridable via
// BRIDGE_TEAMS_DEEPLINK_HOSTS). This is the ONLY source of the [전체 견적결과 보기]
// url — the cardintent's payload.url is never read — so a compromised SKILL emit
// cannot point the button off-domain (zero open-redirect surface).
export function quoteResultDeeplink(env: EnvBag = processEnv()): string {
  return `https://${deeplinkHosts(env)[0]}/d/?screen=rfq-list`
}

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
    spacing?: string
  } = {},
): AcElement {
  const el: AcElement = { type: 'TextBlock', text, wrap: opts.wrap ?? true }
  if (opts.weight) el.weight = opts.weight
  if (opts.size) el.size = opts.size
  if (opts.color) el.color = opts.color
  if (opts.isSubtle) el.isSubtle = true
  if (opts.horizontalAlignment) el.horizontalAlignment = opts.horizontalAlignment
  if (opts.spacing) el.spacing = opts.spacing
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
// reQuote, …) is Phase-2 territory and is dropped here — gating on the id stops
// an arbitrary action from laundering itself into the renderer-supplied
// Action.OpenUrl deeplink.
const QUOTE_RESULT_VIEW_ACTION_ID: ActionId = 'openQuoteResultDetail'

// Phase-1a quoteResult action mapping: the ONLY action the card may emit is the
// [전체 견적결과 보기] Action.OpenUrl deeplink, and the RENDERER supplies its url.
// The cardintent's `a.payload?.url` is ignored entirely — crm-dev emits actionId
// only — so a compromised SKILL emit cannot influence the destination (zero
// open-redirect surface). The url is the rfq-list screen on the first configured
// allowed host; it is re-validated through isAllowedDeeplink (belt-and-suspenders:
// the constructed host is always allowed, so this never drops a legitimate emit).
// Action.Submit is Phase-2 territory and is never emitted, and a non-view actionId
// is dropped. Returns the AC element or null (caller filters it out).
function toQuoteResultAction(a: Action): AcElement | null {
  if (a.actionId !== QUOTE_RESULT_VIEW_ACTION_ID) return null
  const validHref = isAllowedDeeplink(quoteResultDeeplink())
  if (validHref) {
    return { type: 'Action.OpenUrl', title: a.label, url: validHref }
  }
  // Unreachable in practice (the renderer-built host is always allowlisted), but
  // fail-closed: never emit an action without a validated pinned url.
  return null
}

// quoteResult per-RFQ fields (#17138 6-field design; #22358 A1 spec fields). The
// card is the SINGLE mobile-safe per-product stack (appendix card 8): one
// Container per RFQ with a 고객·제품 header + an RFQ/랩넘버/용량/수량/부자재사양
// FactSet + 내용물 견적 / 가공비 견적 price rows. The wide 6-column desktop table
// (appendix card 7) is NOT rendered in chat — it lives behind the
// [전체 견적결과 보기] deeplink (the renderer cannot detect the Teams client
// device, so the narrow layout is the only safe one to push).
//
// RFQ/랩넘버/용량/수량/부자재사양 are matched out of the section's rows by stable
// labels; missing → an em dash. The price cells are PriceCells (string-only Row.value) matched by
// the viewer-facing 내용물 견적 / 가공비 견적 labels (these are the ALLOWED §10
// price labels — never the role-internal cost language). The dropped beta2.2
// 견적 소계 / 산출상태 columns are gone: each price cell carries its own
// valueState (산출중/–) so a separate status column is redundant.
const FIELD_VOLUME_LABELS: readonly string[] = ['용량']
const FIELD_LABNO_LABELS: readonly string[] = ['랩넘버']
const FIELD_RFQ_LABELS: readonly string[] = ['RFQ']
// #22358 A1: the server (v239+) also emits 수량 (already thousands-formatted,
// e.g. "5,000") and 부자재사양 (already " · "-joined server-side) rows for the
// quoteResult chat card. Both are spec identifiers (NOT §10 cost fields — the
// server projection guarantees it), matched + ordered by these stable labels and
// printed VERBATIM; a missing row falls back to the existing em dash.
const FIELD_QUANTITY_LABELS: readonly string[] = ['수량']
const FIELD_SUBMATERIAL_LABELS: readonly string[] = ['부자재사양']
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
// holds a 고객·제품 header (Accent, Bolder) + an `emphasis` Container with an
// RFQ/랩넘버/용량/수량/부자재사양 FactSet and the 내용물 견적 / 가공비 견적
// PriceCell rows. This is the ONLY chat layout — the wide 6-column desktop table (card 7) lives behind
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
              // #22358 A1 field order: RFQ (grouping identifier, kept per the
              // operator live-feedback golden) then 랩넘버 · 용량 · 수량 ·
              // 부자재사양. Each value is the server-provided string printed
              // verbatim via factValue (§10: spec identifiers, not cost); a
              // missing row → em dash.
              { title: 'RFQ', value: factValue(section.rows, FIELD_RFQ_LABELS) },
              { title: '랩넘버', value: factValue(section.rows, FIELD_LABNO_LABELS) },
              { title: '용량', value: factValue(section.rows, FIELD_VOLUME_LABELS) },
              { title: '수량', value: factValue(section.rows, FIELD_QUANTITY_LABELS) },
              { title: '부자재사양', value: factValue(section.rows, FIELD_SUBMATERIAL_LABELS) },
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
  // action emitted is the [전체 견적결과 보기] Action.OpenUrl deeplink, whose url
  // the RENDERER supplies (the cardintent never carries/controls it). Action.Submit
  // is dropped (Phase 2) and a non-view actionId is dropped. If nothing survives
  // the filter, no actions key is emitted (an empty actions array would render an
  // empty action bar).
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
// devReqAutofill: deeplink, validation, render
// ---------------------------------------------------------------------------

// The CRM web 개발의뢰 draft screen deeplink — the confirmDevReq / editDevReq
// actions map to this (the Phase-2 Action.Submit confirm flow is deferred).
// Domain-pinned exactly like the quoteResult deeplink: the RENDERER supplies the
// url on the first configured allowed host, the cardintent never carries/controls
// it (zero open-redirect surface). The screen slug is operator-overridable via
// BRIDGE_TEAMS_DEVREQ_SCREEN (default 'dev-request'); it is constrained to a
// conservative slug charset so it can never smuggle an extra path/query segment
// past the domain-pin. The entity-id in the action payload is intentionally NOT
// placed in the url (it lands on the dev-request screen, not a per-entity url —
// the same zero-injection posture as quoteResult's rfq-list deeplink).
const DEFAULT_DEVREQ_SCREEN = 'dev-request'

export function devReqDeeplink(env: EnvBag = processEnv()): string {
  const raw = (env.BRIDGE_TEAMS_DEVREQ_SCREEN ?? '').trim()
  const screen = /^[a-z0-9-]+$/i.test(raw) ? raw : DEFAULT_DEVREQ_SCREEN
  return `https://${deeplinkHosts(env)[0]}/d/?screen=${screen}`
}

// The reserved label that marks the trailing 보완 필요 section (rendered as a
// warning Container rather than a project content section). Matched by prefix so
// "⚠ 보완 필요" / "⚠ 보완 필요사항 N건" both qualify.
const DEVREQ_WARNING_RE = /^⚠\s*보완/

function validateDevReqAction(a: unknown, where: string): string | null {
  if (!isPlainObject(a)) return `${where}: action must be an object`
  // Fail-closed: actionId must be a STRING in the devReq closed enum (a non-string
  // like ["confirmDevReq"] would stringify past a String() check).
  if (typeof a.actionId !== 'string' || !(DEVREQ_ACTION_IDS as readonly string[]).includes(a.actionId)) {
    return `${where}: actionId "${String(a.actionId)}" not a string in the devReq allowed enum`
  }
  if (typeof a.label !== 'string' || a.label.length === 0) {
    return `${where}: action.label must be a non-empty string`
  }
  if (a.payload !== undefined && !isPlainObject(a.payload)) {
    return `${where}: action.payload must be an object when present`
  }
  return null
}

export type DevReqValidationResult =
  | { ok: true; intent: DevReqAutofillIntent }
  | { ok: false; reason: string }

// Strict validation for the devReqAutofill shape. Rows are validated by the same
// validateSection/validateRow as quoteResult (string-only values, enum-checked
// valueState — so a masked/calculating row can never leak its raw value). An
// empty-rows section is allowed (it is a project header). Top-level actions are
// validated against the devReq action enum; section-level actions are not used.
export function validateDevReqAutofill(value: unknown): DevReqValidationResult {
  if (!isPlainObject(value)) return { ok: false, reason: 'root is not an object' }
  if (value.kind !== 'devReqAutofill') {
    return { ok: false, reason: `kind must be "devReqAutofill" (got ${JSON.stringify(value.kind)})` }
  }
  if (typeof value.title !== 'string') return { ok: false, reason: 'title must be a string' }
  if (typeof value.fallbackMarkdown !== 'string') {
    return { ok: false, reason: 'fallbackMarkdown must be a string' }
  }
  if (value.subtitle !== undefined && typeof value.subtitle !== 'string') {
    return { ok: false, reason: 'subtitle must be a string when present' }
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
      const err = validateDevReqAction(value.actions[i], `actions[${i}]`)
      if (err) return { ok: false, reason: err }
    }
  }
  return { ok: true, intent: value as unknown as DevReqAutofillIntent }
}

// A devReq FactSet: each row → {title,value}, value via renderValueState so a
// masked/calculating/notRequested row never leaks its raw value; an empty value
// renders as an em dash (matches the 미입력→— convention in the sign-off design).
function devReqFactSet(rows: Row[]): AcElement {
  return {
    type: 'FactSet',
    spacing: 'Small',
    facts: rows.map(r => {
      if (r.valueState === 'value') {
        const v = typeof r.value === 'string' ? r.value.trim() : ''
        return { title: r.label, value: v.length > 0 ? v : EMDASH }
      }
      return { title: r.label, value: renderValueState(r).text }
    }),
  }
}

function isDevReqWarningSection(label: string): boolean {
  return DEVREQ_WARNING_RE.test(label.trim())
}

// A subheader TextBlock + its FactSet (nested inside a project Container).
// #22358 A3: match the quoteRequest card's section-label tone so the
// 프로젝트정보/제품정보/벌크 boundaries stand out — the same Accent header style
// renderQuoteRequestContainer uses ({ weight:'Bolder', color:'Accent' }),
// replacing the prior small/subtle greyed subheader.
function devReqSubSection(subheader: string, rows: Row[]): AcElement[] {
  return [
    textBlock(subheader, { weight: 'Bolder', color: 'Accent', spacing: 'Small' }),
    devReqFactSet(rows),
  ]
}

// The trailing 보완 필요 warning Container. Each row is a missing/needs-attention
// field → a subtle bullet (label, plus ": value" when a value is carried). The
// value still flows through renderValueState so a masked/calculating row can't
// leak its raw value here either.
function devReqWarningContainer(label: string, rows: Row[]): AcElement {
  const items: AcElement[] = [textBlock(label, { weight: 'Bolder', color: 'Attention' })]
  for (const r of rows) {
    const v = r.valueState === 'value' ? (typeof r.value === 'string' ? r.value.trim() : '') : renderValueState(r).text
    const text = v.length > 0 ? `${r.label}: ${v}` : r.label
    items.push(textBlock(text, { isSubtle: true, spacing: 'Small' }))
  }
  return { type: 'Container', style: 'warning', separator: true, spacing: 'Medium', items }
}

// Walk the flat section list (the LOCKED #17538 convention): an EMPTY-rows
// section opens a new emphasis Container (Accent project header); each following
// non-empty content section nests as a subheader + FactSet until the next
// empty-rows header; a trailing "⚠ 보완 …" section renders as a warning
// Container; a content section with no open project header renders standalone
// (the flat safety-net).
function renderDevReqBody(intent: DevReqAutofillIntent): AcElement[] {
  const body: AcElement[] = [textBlock(intent.title, { weight: 'Bolder', size: 'Medium' })]
  if (intent.subtitle && intent.subtitle.trim().length > 0) {
    body.push(textBlock(intent.subtitle, { isSubtle: true, spacing: 'None' }))
  }

  let currentProjectItems: AcElement[] | null = null
  for (const section of intent.sections) {
    if (isDevReqWarningSection(section.label)) {
      // Trailing 보완 필요 → standalone warning Container; ends any open group.
      currentProjectItems = null
      body.push(devReqWarningContainer(section.label, section.rows))
      continue
    }
    if (section.rows.length === 0) {
      // Empty-rows header → start a new per-project emphasis Container.
      currentProjectItems = [
        textBlock(section.label, { weight: 'Bolder', color: 'Accent', size: 'Medium' }),
      ]
      body.push({ type: 'Container', style: 'emphasis', separator: true, spacing: 'Medium', items: currentProjectItems })
    } else if (currentProjectItems) {
      // Content section nests under the open project Container.
      currentProjectItems.push(...devReqSubSection(section.label, section.rows))
    } else {
      // Flat safety-net: a content section with no open project header.
      // #22358 A3: same Accent section-label tone as the nested sub-sections.
      body.push({
        type: 'Container',
        separator: true,
        spacing: 'Medium',
        items: [textBlock(section.label, { weight: 'Bolder', color: 'Accent' }), devReqFactSet(section.rows)],
      })
    }
  }

  return body
}

// Map a validated devReq action → a domain-pinned Action.OpenUrl. The RENDERER
// supplies the url (devReqDeeplink), IGNORING the action's payload entity-id/url
// entirely → zero open-redirect surface (same posture as toQuoteResultAction).
// Action.Submit is never produced regardless of input; an unmappable action → null.
function toDevReqAction(a: DevReqAction): AcElement | null {
  if (!(DEVREQ_ACTION_IDS as readonly string[]).includes(a.actionId)) return null
  const href = isAllowedDeeplink(devReqDeeplink())
  if (!href) return null
  return { type: 'Action.OpenUrl', title: a.label, url: href }
}

// Build the devReqAutofill Adaptive Card. Actions are renderer-supplied
// domain-pinned OpenUrl deeplinks ONLY (confirmDevReq / editDevReq → the CRM web
// draft screen); Action.Submit is NEVER emitted (Phase-2 trusted-handler gate),
// and a non-devReq actionId is dropped. No actions key when nothing survives.
export function buildDevReqAutofillCard(intent: DevReqAutofillIntent): AcElement {
  const card: AcElement = {
    type: AC_TYPE,
    $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
    version: AC_VERSION,
    body: renderDevReqBody(intent),
  }
  if (intent.actions && intent.actions.length > 0) {
    const actions = intent.actions.map(toDevReqAction).filter((a): a is AcElement => a !== null)
    if (actions.length > 0) {
      card.actions = actions
    }
  }
  return card
}

// ---------------------------------------------------------------------------
// devStatus CardIntent (the 개발현황 card — #17992).
//
// A THIRD, independent card kind that reuses the same fence + §10 + seam
// machinery as quoteResult/devReqAutofill but renders a near-clone of the
// quoteResult LIST shape: one Container per dev-product (NOT devReqAutofill's
// empty-rows grouping). Each Container carries the section.label (제품 · 상태)
// as an Accent header, a status badge whose color is derived from the 상태 row
// value, and a FactSet of the 8 dev-product fields rendered VERBATIM (a literal
// '—' value is a real datum here — there is NO empty/session fallback). The
// single card-level action openDevStatusDetail maps to a renderer-supplied,
// domain-pinned Action.OpenUrl (devStatusDeeplink — the cardintent never carries
// the url, so zero open-redirect surface). Action.Submit is NEVER emitted.
//
// LOCKED golden (the render must match it):
// ~/.agent-bridge/shared/2026-06-26-devstatus-golden.json (4 dev-products, 8
// value-rows each: 생성일/고객/프로젝트/제품/벌크/연구원/랩넘버/상태).
// ---------------------------------------------------------------------------

// Closed enum of devStatus action ids. An actionId outside this set is dropped
// (the renderer never emits an action it cannot map to a domain-pinned deeplink).
export const DEVSTATUS_ACTION_IDS = ['openDevStatusDetail'] as const
export type DevStatusActionId = (typeof DEVSTATUS_ACTION_IDS)[number]

export type DevStatusAction = {
  actionId: DevStatusActionId
  // payload carries entity-identifier fields only and is NEVER read for the url
  // (the renderer supplies a domain-pinned deeplink) — so a forbidden cost key
  // smuggled here is still caught by the §10 byte scan over the rendered card.
  label: string
  payload?: Record<string, unknown>
}

export type DevStatusIntent = {
  kind: 'devStatus'
  title: string
  // One Section per dev-product: label = "<제품> · <상태>", rows = the 8 fields.
  sections: Section[]
  actions?: DevStatusAction[]
  fallbackMarkdown: string
}

// The CRM web 개발현황 screen deeplink — openDevStatusDetail maps to this.
// Domain-pinned exactly like the quoteResult/devReq deeplinks: the RENDERER
// supplies the url on the first configured allowed host, the cardintent never
// carries/controls it (zero open-redirect surface). The screen slug is
// operator-overridable via BRIDGE_TEAMS_DEVSTATUS_SCREEN (default 'dev-status');
// it is constrained to a conservative slug charset so it can never smuggle an
// extra path/query segment past the domain-pin.
const DEFAULT_DEVSTATUS_SCREEN = 'dev-status'

export function devStatusDeeplink(env: EnvBag = processEnv()): string {
  const raw = (env.BRIDGE_TEAMS_DEVSTATUS_SCREEN ?? '').trim()
  const screen = /^[a-z0-9-]+$/i.test(raw) ? raw : DEFAULT_DEVSTATUS_SCREEN
  return `https://${deeplinkHosts(env)[0]}/d/?screen=${screen}`
}

// The row label that carries the dev-product status (the 상태 field). Its value
// drives the status-badge color (crm-dev's info/warning/success/danger mapping).
const FIELD_STATUS_LABELS: readonly string[] = ['상태']

// Map a 상태 value → an AC v1.2 TextBlock color for the status badge:
//   진행 중 / 단가확정 → Accent (info)   보류 → Warning (warning)
//   출시 완료          → Good (success)   드롭 → Attention (danger)
//   anything else      → Default
// (Trimmed compare; an unknown/empty status falls back to Default, never throws.)
export function devStatusBadgeColor(status: string): string {
  const s = typeof status === 'string' ? status.trim() : ''
  switch (s) {
    case '진행 중':
    case '단가확정':
      return 'Accent'
    case '보류':
      return 'Warning'
    case '출시 완료':
      return 'Good'
    case '드롭':
      return 'Attention'
    default:
      return 'Default'
  }
}

function validateDevStatusAction(a: unknown, where: string): string | null {
  if (!isPlainObject(a)) return `${where}: action must be an object`
  // Fail-closed: actionId must be a STRING in the devStatus closed enum (a
  // non-string like ["openDevStatusDetail"] would stringify past a String() check).
  if (typeof a.actionId !== 'string' || !(DEVSTATUS_ACTION_IDS as readonly string[]).includes(a.actionId)) {
    return `${where}: actionId "${String(a.actionId)}" not a string in the devStatus allowed enum`
  }
  if (typeof a.label !== 'string' || a.label.length === 0) {
    return `${where}: action.label must be a non-empty string`
  }
  if (a.payload !== undefined && !isPlainObject(a.payload)) {
    return `${where}: action.payload must be an object when present`
  }
  return null
}

export type DevStatusValidationResult =
  | { ok: true; intent: DevStatusIntent }
  | { ok: false; reason: string }

// Strict validation for the devStatus shape. Rows are validated by the same
// validateSection/validateRow as quoteResult (string-only values, enum-checked
// valueState — so a masked/calculating row can never leak its raw value).
// Top-level actions are validated against the devStatus action enum;
// section-level actions are not used.
export function validateDevStatus(value: unknown): DevStatusValidationResult {
  if (!isPlainObject(value)) return { ok: false, reason: 'root is not an object' }
  if (value.kind !== 'devStatus') {
    return { ok: false, reason: `kind must be "devStatus" (got ${JSON.stringify(value.kind)})` }
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
      const err = validateDevStatusAction(value.actions[i], `actions[${i}]`)
      if (err) return { ok: false, reason: err }
    }
  }
  return { ok: true, intent: value as unknown as DevStatusIntent }
}

// A devStatus FactSet: each row → {title,value}. A 'value'-state row is rendered
// VERBATIM (a literal '—' is a real datum in this card — there is NO empty/session
// fallback like devReqFactSet's). A non-'value' state (masked/calculating/
// notRequested) NEVER falls through to the raw row.value — route it through
// renderValueState (defense-in-depth: a masked row must not leak its data).
function devStatusFactSet(rows: Row[]): AcElement {
  return {
    type: 'FactSet',
    facts: rows.map(r => {
      if (r.valueState === 'value') {
        return { title: r.label, value: r.value }
      }
      return { title: r.label, value: renderValueState(r).text }
    }),
  }
}

// One dev-product Container: an Accent header (section.label = 제품 · 상태), a
// status badge colored by the 상태 row value, then the 8-field FactSet. Mobile-
// safe (no wide grid / Table / targetWidth). The wide desktop view lives behind
// the [전체 개발현황 보기] deeplink (the renderer can't detect the Teams client).
function renderDevStatusContainer(section: Section): AcElement {
  const statusRow = findRow(section.rows, FIELD_STATUS_LABELS)
  const statusText =
    statusRow && statusRow.valueState === 'value' && typeof statusRow.value === 'string'
      ? statusRow.value.trim()
      : ''
  const items: AcElement[] = [textBlock(section.label, { weight: 'Bolder', color: 'Accent' })]
  if (statusText.length > 0) {
    items.push(textBlock(statusText, { weight: 'Bolder', color: devStatusBadgeColor(statusText), spacing: 'None' }))
  }
  items.push(devStatusFactSet(section.rows))
  return { type: 'Container', separator: true, spacing: 'Medium', items }
}

function renderDevStatusBody(intent: DevStatusIntent): AcElement[] {
  const body: AcElement[] = [textBlock(intent.title, { weight: 'Bolder', size: 'Medium' })]
  for (const section of intent.sections) {
    body.push(renderDevStatusContainer(section))
  }
  return body
}

// The single actionId allowed to surface as a card action: the [전체 개발현황 보기]
// view deeplink. Every other actionId is dropped — gating on the id stops an
// arbitrary action from laundering itself into the renderer-supplied OpenUrl.
const DEVSTATUS_VIEW_ACTION_ID: DevStatusActionId = 'openDevStatusDetail'

// Map a validated devStatus action → a domain-pinned Action.OpenUrl. The RENDERER
// supplies the url (devStatusDeeplink), IGNORING the action's payload entity-id/url
// entirely → zero open-redirect surface (same posture as toQuoteResultAction).
// Action.Submit is never produced; a non-view actionId → null (dropped).
function toDevStatusAction(a: DevStatusAction): AcElement | null {
  if (a.actionId !== DEVSTATUS_VIEW_ACTION_ID) return null
  const href = isAllowedDeeplink(devStatusDeeplink())
  if (!href) return null
  return { type: 'Action.OpenUrl', title: a.label, url: href }
}

// Build the devStatus Adaptive Card. The only action emitted is the renderer-
// supplied domain-pinned [전체 개발현황 보기] OpenUrl deeplink; Action.Submit is
// NEVER emitted, and a non-view actionId is dropped. No actions key when nothing
// survives the filter (an empty actions array renders an empty action bar).
export function buildDevStatusCard(intent: DevStatusIntent): AcElement {
  const card: AcElement = {
    type: AC_TYPE,
    $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
    version: AC_VERSION,
    body: renderDevStatusBody(intent),
  }
  if (intent.actions && intent.actions.length > 0) {
    const actions = intent.actions.map(toDevStatusAction).filter((a): a is AcElement => a !== null)
    if (actions.length > 0) {
      card.actions = actions
    }
  }
  return card
}

// ---------------------------------------------------------------------------
// quoteRequest CardIntent (the 견적의뢰 미리보기 card — #17138 card 6).
//
// A FOURTH, independent card kind that reuses the same fence + §10 + seam
// machinery as quoteResult/devReqAutofill/devStatus but renders a read-only
// pre-submission FactSet: the title, then one Container per section (제품 기본정보
// + 견적 종류, interleaved per product), each an Accent header + a FactSet whose
// rows go through the same renderValueState path as quoteResult (so a
// masked/calculating/notRequested row never leaks its raw value). The single
// card-level action is confirmQuoteRequest — the [승인 (견적의뢰 제출)] approval
// button. UNLIKE the other three kinds it is a confirm/submit callback, not a
// web/d navigation, so the renderer emits an Action.Submit (NOT an OpenUrl
// deeplink). The renderer SUPPLIES the submit data — a single {actionId} object
// — and IGNORES the cardintent's action payload entirely (same zero-injection
// posture as the other kinds: a forbidden cost key smuggled into the payload is
// never echoed into the card, and the §10 byte-scan still covers the row values).
//
// LOCKED golden (the render must match it):
// cosmax-crm-cli contract/adaptivecard/golden_quoterequest_preview.json
// (TestQuoteRequestGoldenMatches on crm main; 2 products → 기본정보 + 견적 종류
// section pairs, a single confirmQuoteRequest action, a fallbackMarkdown body).
// ---------------------------------------------------------------------------

// Closed enum of quoteRequest action ids. An actionId outside this set is
// dropped (the renderer never emits an action it cannot map). The 견적의뢰
// 미리보기 card carries exactly one card-level action: the [승인 (견적의뢰 제출)]
// confirmQuoteRequest approval button.
export const QUOTEREQUEST_ACTION_IDS = ['confirmQuoteRequest'] as const
export type QuoteRequestActionId = (typeof QUOTEREQUEST_ACTION_IDS)[number]

export type QuoteRequestAction = {
  actionId: QuoteRequestActionId
  // payload carries identifier-only fields (project_id) and is NEVER echoed into
  // the rendered Action.Submit data (the renderer supplies a minimal {actionId}
  // data object) — so a forbidden cost key smuggled here is never serialized into
  // the card, and the §10 byte scan over the rendered card still covers the rest.
  label: string
  payload?: Record<string, unknown>
}

export type QuoteRequestIntent = {
  kind: 'quoteRequest'
  title: string
  // One Section per aspect, interleaved per product: 제품 기본정보 + 견적 종류.
  sections: Section[]
  actions?: QuoteRequestAction[]
  fallbackMarkdown: string
}

function validateQuoteRequestAction(a: unknown, where: string): string | null {
  if (!isPlainObject(a)) return `${where}: action must be an object`
  // Fail-closed: actionId must be a STRING in the quoteRequest closed enum (a
  // non-string like ["confirmQuoteRequest"] would stringify past a String() check).
  if (typeof a.actionId !== 'string' || !(QUOTEREQUEST_ACTION_IDS as readonly string[]).includes(a.actionId)) {
    return `${where}: actionId "${String(a.actionId)}" not a string in the quoteRequest allowed enum`
  }
  if (typeof a.label !== 'string' || a.label.length === 0) {
    return `${where}: action.label must be a non-empty string`
  }
  if (a.payload !== undefined && !isPlainObject(a.payload)) {
    return `${where}: action.payload must be an object when present`
  }
  return null
}

export type QuoteRequestValidationResult =
  | { ok: true; intent: QuoteRequestIntent }
  | { ok: false; reason: string }

// Strict validation for the quoteRequest shape. Rows are validated by the same
// validateSection/validateRow as quoteResult (string-only values, enum-checked
// valueState — so a masked/calculating row can never leak its raw value).
// Top-level actions are validated against the quoteRequest action enum;
// section-level actions are not used.
export function validateQuoteRequest(value: unknown): QuoteRequestValidationResult {
  if (!isPlainObject(value)) return { ok: false, reason: 'root is not an object' }
  if (value.kind !== 'quoteRequest') {
    return { ok: false, reason: `kind must be "quoteRequest" (got ${JSON.stringify(value.kind)})` }
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
      const err = validateQuoteRequestAction(value.actions[i], `actions[${i}]`)
      if (err) return { ok: false, reason: err }
    }
  }
  return { ok: true, intent: value as unknown as QuoteRequestIntent }
}

// A quoteRequest FactSet: each row → {title,value}. A 'value'-state row whose
// value is a non-empty string renders VERBATIM (a literal '—' is a real datum
// here — it is the server's notRequested rendering); an empty 'value' string
// renders as an em dash. A non-'value' state (masked/calculating/notRequested)
// NEVER falls through to the raw row.value — route it through renderValueState
// (defense-in-depth: a masked row must not leak its data).
function quoteRequestFactSet(rows: Row[]): AcElement {
  return {
    type: 'FactSet',
    facts: rows.map(r => {
      if (r.valueState === 'value') {
        const v = typeof r.value === 'string' ? r.value.trim() : ''
        return { title: r.label, value: v.length > 0 ? v : EMDASH }
      }
      return { title: r.label, value: renderValueState(r).text }
    }),
  }
}

// One section Container: an Accent header (section.label = 제품 #N · … / 견적
// 종류 #N) then the field FactSet. Mobile-safe (no wide grid / Table /
// targetWidth) — the same per-section stack as the quoteResult detail layout.
function renderQuoteRequestContainer(section: Section): AcElement {
  return {
    type: 'Container',
    separator: true,
    spacing: 'Medium',
    items: [
      textBlock(section.label, { weight: 'Bolder', color: 'Accent' }),
      quoteRequestFactSet(section.rows),
    ],
  }
}

function renderQuoteRequestBody(intent: QuoteRequestIntent): AcElement[] {
  const body: AcElement[] = [textBlock(intent.title, { weight: 'Bolder', size: 'Medium' })]
  for (const section of intent.sections) {
    body.push(renderQuoteRequestContainer(section))
  }
  return body
}

// Map a validated quoteRequest action → an Action.Submit. The RENDERER supplies
// the submit data ({ actionId } only), IGNORING the cardintent's payload entirely
// — so a forbidden cost key smuggled into the payload is never echoed into the
// card (zero-injection; same posture as toDevReqAction dropping the payload
// entity-id). A non-confirm actionId → null (dropped). This is the ONLY card kind
// that emits an Action.Submit: confirmQuoteRequest is a 제출 confirm callback (a
// trusted server-side handler routes on the actionId), not a web/d navigation, so
// an OpenUrl deeplink would be the wrong shape.
function toQuoteRequestAction(a: QuoteRequestAction): AcElement | null {
  if (!(QUOTEREQUEST_ACTION_IDS as readonly string[]).includes(a.actionId)) return null
  return { type: 'Action.Submit', title: a.label, data: { actionId: a.actionId } }
}

// Build the quoteRequest Adaptive Card. The only action emitted is the
// renderer-supplied [승인 (견적의뢰 제출)] Action.Submit whose data is a single
// { actionId } object (the cardintent's payload is never echoed); a non-confirm
// actionId is dropped. No actions key when nothing survives the filter (an empty
// actions array renders an empty action bar).
export function buildQuoteRequestCard(intent: QuoteRequestIntent): AcElement {
  const card: AcElement = {
    type: AC_TYPE,
    $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
    version: AC_VERSION,
    body: renderQuoteRequestBody(intent),
  }
  if (intent.actions && intent.actions.length > 0) {
    const actions = intent.actions.map(toQuoteRequestAction).filter((a): a is AcElement => a !== null)
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
  forbidden: readonly string[] = FORBIDDEN_COST_KEYS,
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
  const forbidden = opts.forbidden ?? FORBIDDEN_COST_KEYS
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

  // Validate shape + render — branch on the card kind. quoteResult is the
  // original path (untouched); devReqAutofill is the 개발의뢰 draft card;
  // devStatus is the 개발현황 card; quoteRequest is the 견적의뢰 미리보기 card.
  // All four share the §10 byte-scan, size guard, and success-suppression tail
  // below.
  let card: AcElement
  const kind = isPlainObject(parsed) ? parsed.kind : undefined
  if (kind === 'devReqAutofill') {
    const validation = validateDevReqAutofill(parsed)
    if (!validation.ok) {
      return fail(`cardintent validation failed: ${validation.reason}`)
    }
    try {
      card = buildDevReqAutofillCard(validation.intent)
    } catch (err) {
      return fail(`cardintent render failed: ${(err as Error).message}`)
    }
  } else if (kind === 'devStatus') {
    const validation = validateDevStatus(parsed)
    if (!validation.ok) {
      return fail(`cardintent validation failed: ${validation.reason}`)
    }
    try {
      card = buildDevStatusCard(validation.intent)
    } catch (err) {
      return fail(`cardintent render failed: ${(err as Error).message}`)
    }
  } else if (kind === 'quoteRequest') {
    const validation = validateQuoteRequest(parsed)
    if (!validation.ok) {
      return fail(`cardintent validation failed: ${validation.reason}`)
    }
    try {
      card = buildQuoteRequestCard(validation.intent)
    } catch (err) {
      return fail(`cardintent render failed: ${(err as Error).message}`)
    }
  } else {
    const validation = validateCardIntent(parsed)
    if (!validation.ok) {
      return fail(`cardintent validation failed: ${validation.reason}`)
    }
    try {
      card = buildAdaptiveCard(validation.intent)
    } catch (err) {
      return fail(`cardintent render failed: ${(err as Error).message}`)
    }
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

  // Card success → the card IS the content; suppress the visible prose so the
  // user does not see a duplicate of the agent's no-card markdown fallback
  // alongside the rendered card. This is strictly stronger than the §10
  // hard-replace on the success path: text === '' is a zero visible-text leak
  // surface. The §10 prose scan still governs the fail() fallback via safeText,
  // and the rendered-card §10 byte scan above still rejects a forbidden card.
  return {
    text: '',
    attachments: [{ contentType: AC_CONTENT_TYPE, content: card }],
  }
}
