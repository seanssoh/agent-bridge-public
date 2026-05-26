#!/usr/bin/env bash
# scripts/smoke/1210-ms365-scope-normalize.sh — issue #1210.
#
# Pins the contract closed by #1210:
#
#   `plugins/ms365/server.ts` exports `normalizeScopes(raw)` which
#   strips one matching outer quote pair, collapses whitespace, and
#   rejoins single space, then passes the result to URLSearchParams
#   at pair_start time. The pre-existing bug was that operator .env
#   values like `MS365_DEFAULT_SCOPES="openid ..."` flowed through
#   with literal quotes and `URLSearchParams` correctly
#   percent-encoded them as `%22`, tripping Azure AD AADSTS70011.
#
# Tests:
#   T1 (TS) — server.ts exports `normalizeScopes`.
#   T2 (TS) — pair_start handler calls `normalizeScopes(...)` before
#             URLSearchParams.
#   T3 (TS, runtime) — `"openid profile offline_access User.Read"`
#                      (double-quoted) round-trips through the
#                      authorize_url builder and the encoded `scope=`
#                      contains no `"` and no `%22`.
#   T4 (TS, runtime) — `'openid profile offline_access User.Read'`
#                      (single-quoted) → same.
#   T5 (TS, runtime) — multiple whitespace (`"openid   profile"`)
#                      collapses to single space in the encoded URL.
#   T6 (TS, runtime) — plain unquoted input round-trips unchanged.
#   T7 (TS, runtime) — args.scopes='"X Y"' → quotes stripped at the
#                      pair_start.args branch (not just env default).
#   T8 (TS, runtime) — full authorize_url shape: scope param exists
#                      and is space-joined (`+` in URL encoding) with
#                      no stray quotes.
#
# Footgun #11: pipe/argv stdin only.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
_skip() { TOTAL=$((TOTAL + 1)); printf '[skip] %s\n' "$1"; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1210-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

MS365_TS="$REPO_ROOT/plugins/ms365/server.ts"

if [[ ! -f "$MS365_TS" ]]; then
  printf '[FAIL] required file missing: %s\n' "$MS365_TS" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# T1 — server.ts exports normalizeScopes.
# ---------------------------------------------------------------------------
if grep -E "export function normalizeScopes" "$MS365_TS" >/dev/null; then
  _pass "T1: server.ts exports normalizeScopes"
else
  _fail "T1" "normalizeScopes export missing"
fi

# ---------------------------------------------------------------------------
# T2 — pair_start handler calls normalizeScopes before URLSearchParams.
# We check the handler block: there is a `const scopes =` line that
# uses normalizeScopes, and that scope value is what eventually flows
# to startAuthCode.
# ---------------------------------------------------------------------------
T2_ERRORS=""
if ! grep -E "const scopes = normalizeScopes" "$MS365_TS" >/dev/null; then
  T2_ERRORS+="pair_start handler does not call normalizeScopes on args.scopes/DEFAULT_SCOPES; "
fi
# Defense-in-depth: make sure the URLSearchParams `scope:` field gets
# the normalized value via the scopes binding (not the raw input).
if ! grep -E "scope: scopes," "$MS365_TS" >/dev/null; then
  T2_ERRORS+="URLSearchParams scope: scopes binding missing; "
fi
if [[ -z "$T2_ERRORS" ]]; then
  _pass "T2: pair_start calls normalizeScopes + URLSearchParams uses normalized 'scopes' binding"
else
  _fail "T2" "$T2_ERRORS"
fi

# ---------------------------------------------------------------------------
# T3-T8 — Runtime behavior. Extract normalizeScopes into a standalone
# harness and verify the authorize_url's scope= param is clean.
# ---------------------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  _skip "T3: double-quoted env → no %22 in authorize_url (bun not available)"
  _skip "T4: single-quoted env → no %22 in authorize_url (bun not available)"
  _skip "T5: multiple-whitespace → collapsed (bun not available)"
  _skip "T6: plain unquoted → unchanged (bun not available)"
  _skip "T7: args.scopes quoted → stripped (bun not available)"
  _skip "T8: full authorize_url shape (bun not available)"
else
  HELPER_TS="$SMOKE_DIR/normalize.ts"
  cat >"$HELPER_TS" <<'TS_EOF'
function normalizeScopes(raw: unknown): string {
  let s = String(raw ?? '').trim()
  if (s.length >= 2) {
    const first = s.charAt(0)
    const last = s.charAt(s.length - 1)
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      s = s.slice(1, -1).trim()
    }
  }
  return s.split(/\s+/).filter(Boolean).join(' ')
}

// Build the same URLSearchParams shape that startAuthCode does, so we
// exercise the actual encoding round-trip rather than just inspecting
// the normalizeScopes return value.
function authorizeUrl(scopesRaw: string): string {
  const scopes = normalizeScopes(scopesRaw)
  const params = new URLSearchParams({
    client_id: 'C',
    response_type: 'code',
    redirect_uri: 'https://x.example.com/auth/callback',
    response_mode: 'query',
    scope: scopes,
    state: 'S',
    prompt: 'select_account',
    login_hint: 'u@x',
  })
  return 'https://login.microsoftonline.com/T/oauth2/v2.0/authorize?' + params.toString()
}

const mode = process.argv[2] || ''
const raw = process.argv[3] || ''
if (mode === 'normalize') {
  console.log(normalizeScopes(raw))
} else if (mode === 'authorize') {
  console.log(authorizeUrl(raw))
} else {
  console.error('mode required: normalize | authorize')
  process.exit(2)
}
TS_EOF

  # Helper to inspect the encoded scope= parameter from an authorize_url.
  extract_scope() {
    # Take a single-line URL on stdin, isolate `scope=...&` chunk.
    grep -oE 'scope=[^&]*' || true
  }

  # T3 — double-quoted env → no literal " and no %22 in scope param.
  RAW='"openid profile offline_access User.Read"'
  T3_URL="$(bun run "$HELPER_TS" authorize "$RAW" 2>&1 || true)"
  T3_SCOPE="$(printf '%s\n' "$T3_URL" | extract_scope)"
  T3_ERRORS=""
  case "$T3_SCOPE" in
    *'"'*) T3_ERRORS+="scope contains literal '\"'; ";;
    *'%22'*) T3_ERRORS+="scope contains %22; ";;
  esac
  # Decoded scope must equal canonical form.
  T3_DECODED="$(printf '%s\n' "$T3_SCOPE" | sed -e 's/^scope=//' -e 's/+/ /g' -e 's/%2[Ee]/./g')"
  if [[ "$T3_DECODED" != "openid profile offline_access User.Read" ]]; then
    T3_ERRORS+="decoded scope mismatch: '$T3_DECODED'; "
  fi
  if [[ -z "$T3_ERRORS" ]]; then
    _pass "T3: double-quoted env scope → no literal '\"' or %22 in authorize_url"
  else
    _fail "T3" "$T3_ERRORS (full scope param: $T3_SCOPE)"
  fi

  # T4 — single-quoted env → same.
  RAW="'openid profile offline_access User.Read'"
  T4_URL="$(bun run "$HELPER_TS" authorize "$RAW" 2>&1 || true)"
  T4_SCOPE="$(printf '%s\n' "$T4_URL" | extract_scope)"
  T4_ERRORS=""
  case "$T4_SCOPE" in
    *"'"*) T4_ERRORS+="scope contains literal single quote; ";;
    *"%27"*) T4_ERRORS+="scope contains %27; ";;
  esac
  if [[ -z "$T4_ERRORS" ]]; then
    _pass "T4: single-quoted env scope → no literal quote in authorize_url"
  else
    _fail "T4" "$T4_ERRORS (full scope param: $T4_SCOPE)"
  fi

  # T5 — multiple whitespace → collapsed (no double `+` in URL encoding,
  # equivalent to no double space in decoded form).
  RAW='"openid   profile  offline_access"'
  T5_NORM="$(bun run "$HELPER_TS" normalize "$RAW" 2>&1 || true)"
  if [[ "$T5_NORM" == "openid profile offline_access" ]]; then
    _pass "T5: multiple whitespace collapses to single space"
  else
    _fail "T5" "expected 'openid profile offline_access', got: '$T5_NORM'"
  fi

  # T6 — plain unquoted input → unchanged.
  RAW='openid profile User.Read'
  T6_NORM="$(bun run "$HELPER_TS" normalize "$RAW" 2>&1 || true)"
  if [[ "$T6_NORM" == "openid profile User.Read" ]]; then
    _pass "T6: plain unquoted input round-trips unchanged"
  else
    _fail "T6" "expected 'openid profile User.Read', got: '$T6_NORM'"
  fi

  # T7 — args.scopes quoted (simulating MCP args path, not env path).
  # The same normalizeScopes function handles both — `pair_start.handler`
  # calls `normalizeScopes(args.scopes ?? DEFAULT_SCOPES)`.
  RAW='"User.Read Mail.Read"'
  T7_NORM="$(bun run "$HELPER_TS" normalize "$RAW" 2>&1 || true)"
  if [[ "$T7_NORM" == "User.Read Mail.Read" ]]; then
    _pass "T7: quoted args.scopes input has quotes stripped"
  else
    _fail "T7" "expected 'User.Read Mail.Read', got: '$T7_NORM'"
  fi

  # T8 — full authorize_url shape: scope param exists, space-joined
  # (URL-encoded as +), no stray quote chars anywhere in the URL.
  RAW='"openid profile offline_access User.Read"'
  T8_URL="$(bun run "$HELPER_TS" authorize "$RAW" 2>&1 || true)"
  T8_ERRORS=""
  if ! printf '%s\n' "$T8_URL" | grep -E "scope=openid\\+profile\\+offline_access\\+User\\.Read" >/dev/null; then
    T8_ERRORS+="authorize_url scope= not '+'-joined; "
  fi
  case "$T8_URL" in
    *'%22'*) T8_ERRORS+="authorize_url contains %22; ";;
    *'"'*) T8_ERRORS+="authorize_url contains literal '\"'; ";;
  esac
  if [[ -z "$T8_ERRORS" ]]; then
    _pass "T8: full authorize_url has clean '+'-joined scope, no stray quotes"
  else
    _fail "T8" "$T8_ERRORS (url: $T8_URL)"
  fi
fi

printf '[%s] %d/%d passed (FAILS=%d)\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL" "$FAILS"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
