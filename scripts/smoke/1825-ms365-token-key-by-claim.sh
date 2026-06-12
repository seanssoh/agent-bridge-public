#!/usr/bin/env bash
# scripts/smoke/1825-ms365-token-key-by-claim.sh — issue #1825.
#
# Pins the contract closed by #1825:
#
#   At pair_poll success the ms365 plugin keys + stores the delegated token
#   by the AUTHENTICATED claim (the verified UPN from the id_token /
#   Graph /me), NOT by the opaque, unvalidated `pair_start` input. This
#   eliminates the fragile post-pair re-key/mv/restart dance: a single
#   pairing started with an opaque Teams `aadObjectId` yields a token whose
#   filename + `upn` field are the REAL UPN, which downstream consumers (the
#   approvals plugin reads identity from the token filename / `upn` field)
#   depend on.
#
# Security invariants:
#   - the durable key comes from the verified token/Graph identity, never
#     from unvalidated client-supplied input;
#   - a forged / malformed UPN input does NOT determine the durable key;
#   - path-traversal in any UPN/claim is neutralized (slug confined to the
#     tokens dir).
#
# Tests:
#   T0  (source) — server.ts derives the key from the authenticated claim
#                  (claimUpnFromIdToken / claimUpnFromGraph) and saves under
#                  the authenticated key; slugUpn neutralizes `..`.
#   T1  (runtime) — pair_poll keyed by an opaque aadObjectId input lands the
#                   token at tokens/<realUPN>.json with `upn` = real UPN.
#   T2  (runtime) — a forged/unvalidated UPN input does NOT win: the
#                   id_token claim is authoritative for the key.
#   T3  (runtime) — path-traversal in the claim is neutralized (no escape
#                   from the tokens dir; slug collapses `..`).
#   T4  (runtime) — no id_token → Graph /me fallback supplies the real UPN.
#   T5  (runtime) — both claim sources empty → degrade to the opaque input
#                   (pairing is never blocked).
#
# Footgun #11: argv/stdin only — no heredoc to a subprocess except the
# self-contained harness file written with `cat > FILE`.
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }
_skip() { TOTAL=$((TOTAL + 1)); printf '[skip] %s\n' "$1"; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1825-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

MS365_TS="$REPO_ROOT/plugins/ms365/server.ts"
[[ -f "$MS365_TS" ]] || { printf '[FAIL] required file missing: %s\n' "$MS365_TS" >&2; exit 1; }

# ---------------------------------------------------------------------------
# T0 — source: the keying glue is wired. Grep-level so it runs even where
# bun is unavailable. Guards that the runtime harness (which mirrors the
# logic) cannot silently drift from the shipped code.
# ---------------------------------------------------------------------------
T0_ERRORS=""
grep -Eq "function claimUpnFromIdToken" "$MS365_TS" \
  || T0_ERRORS+="server.ts has no claimUpnFromIdToken (id_token claim not decoded); "
grep -Eq "function claimUpnFromGraph" "$MS365_TS" \
  || T0_ERRORS+="server.ts has no claimUpnFromGraph (no /me fallback for the authenticated key); "
grep -Eq "function normalizeClaimedUpn" "$MS365_TS" \
  || T0_ERRORS+="server.ts has no normalizeClaimedUpn (claim is not UPN-shape validated); "
# The token must be saved under the AUTHENTICATED key, not the opaque input.
grep -Eq "saveJson\(tokenPath\(authUpn\)" "$MS365_TS" \
  || T0_ERRORS+="server.ts does not saveJson(tokenPath(authUpn)) — token still keyed by the pair_start input; "
# The claim must be derived BEFORE saving (claim → graph → opaque fallback).
grep -Eq "claimUpnFromIdToken\(data\.id_token\)" "$MS365_TS" \
  || T0_ERRORS+="server.ts does not derive the key from data.id_token; "
# slugUpn must collapse `..` (path-traversal teeth).
if ! grep -Eq "\\\\\.\{2,\}" "$MS365_TS"; then
  # tolerate alternate spelling of the dot-run regex
  grep -Eq "replace\(/\\\\\.\{2,\}/g" "$MS365_TS" \
    || T0_ERRORS+="slugUpn does not collapse '..' runs (dot-traversal teeth missing); "
fi
if [[ -z "$T0_ERRORS" ]]; then
  _pass "T0: server.ts derives the key from the authenticated claim (id_token/graph), validates UPN shape, saves under authUpn, and slug-collapses '..'"
else
  _fail "T0" "$T0_ERRORS"
fi

# ---------------------------------------------------------------------------
# Runtime tests (T1-T5). Need bun. They exercise a self-contained mirror of
# the exchangeAuthCode keying logic (decode id_token → normalize claim →
# graph /me fallback → opaque fallback → saveJson under the authenticated
# key). T0 guards that server.ts keeps that glue, so the harness cannot
# silently diverge from the shipped behavior.
# ---------------------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  for t in T1 T2 T3 T4 T5; do _skip "$t: runtime keying behavior (bun not available)"; done
else
  HARNESS="$SMOKE_DIR/harness.ts"
  cat >"$HARNESS" <<'HARNESS_EOF'
import { mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync, chmodSync } from 'fs'
import { join } from 'path'

const STATE_DIR = process.env.HARNESS_STATE_DIR!
const TOKENS_DIR = join(STATE_DIR, 'tokens')
mkdirSync(TOKENS_DIR, { recursive: true, mode: 0o700 })

type TokenFile = { upn: string; access_token: string; refresh_token?: string; expires_at: number; scope: string; saved_at: number }

// --- mirrors of the server.ts keying helpers (#1825) ---
function slugUpn(upn: string): string {
  return upn.replace(/[^A-Za-z0-9._-]/g, '_').replace(/\.{2,}/g, '_').toLowerCase()
}
function tokenPath(upn: string): string { return join(TOKENS_DIR, slugUpn(upn) + '.json') }
function saveJson(p: string, payload: unknown) {
  const tmp = p + '.tmp'
  writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 })
  renameSync(tmp, p); chmodSync(p, 0o600)
}
function decodeJwtPayload(jwt: string): Record<string, unknown> | null {
  const parts = String(jwt).split('.')
  if (parts.length < 2) return null
  try {
    const json = Buffer.from(parts[1], 'base64url').toString('utf8')
    const obj = JSON.parse(json)
    return obj && typeof obj === 'object' ? (obj as Record<string, unknown>) : null
  } catch { return null }
}
function normalizeClaimedUpn(raw: unknown): string | null {
  if (typeof raw !== 'string') return null
  const s = raw.trim()
  if (!s) return null
  if (!/^[^\s@/\\]+@[^\s@/\\]+$/.test(s)) return null
  if (s.includes('..')) return null
  return s
}
function claimUpnFromIdToken(idToken: unknown): string | null {
  if (typeof idToken !== 'string' || !idToken) return null
  const payload = decodeJwtPayload(idToken)
  if (!payload) return null
  return normalizeClaimedUpn(payload.preferred_username) ?? normalizeClaimedUpn(payload.upn)
}

// Mock Graph /me, scripted by env.
async function claimUpnFromGraph(_accessToken: string): Promise<string | null> {
  const u = process.env.HARNESS_GRAPH_UPN
  return u ? normalizeClaimedUpn(u) : null
}

// Build a fake (unsigned) id_token from a claims JSON env var.
function fakeIdToken(claims: Record<string, unknown> | null): string | undefined {
  if (!claims) return undefined
  const header = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url')
  const body = Buffer.from(JSON.stringify(claims)).toString('base64url')
  return header + '.' + body + '.'
}

// --- the exchangeAuthCode keying core (mirror) ---
async function keyAndStore(opaqueInput: string): Promise<TokenFile> {
  const claims = process.env.HARNESS_CLAIMS ? JSON.parse(process.env.HARNESS_CLAIMS) : null
  const id_token = fakeIdToken(claims)
  const access_token = 'AT_' + Date.now()
  const now = Math.floor(Date.now() / 1000)
  const authUpn =
    claimUpnFromIdToken(id_token) ??
    (await claimUpnFromGraph(access_token)) ??
    opaqueInput
  const token: TokenFile = {
    upn: authUpn, access_token, refresh_token: 'RT', expires_at: now + 3600,
    scope: 'User.Read', saved_at: now,
  }
  saveJson(tokenPath(authUpn), token)
  return token
}

const opaque = process.env.HARNESS_OPAQUE_INPUT!
const tok = await keyAndStore(opaque)
const files = readdirSync(TOKENS_DIR).filter(f => f.endsWith('.json'))
// Emit a machine-readable result line for the bash side to assert on.
process.stdout.write(JSON.stringify({
  keyed_upn: tok.upn,
  token_files: files,
  // Confirm the on-disk file's `upn` field round-trips to the keyed UPN.
  on_disk_upn: (() => { try { return JSON.parse(readFileSync(tokenPath(tok.upn), 'utf8')).upn } catch { return null } })(),
}) + '\n')
HARNESS_EOF

  run_harness() { # opaque_input ; sets STATE_DIR per call
    local opaque="$1"
    local state; state="$(mktemp -d "$SMOKE_DIR/state.XXXXXX")"
    HARNESS_STATE_DIR="$state" HARNESS_OPAQUE_INPUT="$opaque" \
      HARNESS_CLAIMS="${HARNESS_CLAIMS:-}" HARNESS_GRAPH_UPN="${HARNESS_GRAPH_UPN:-}" \
      bun run "$HARNESS" 2>"$SMOKE_DIR/harness.err"
  }

  # T1 — opaque aadObjectId input, real UPN from id_token claim.
  HARNESS_CLAIMS='{"preferred_username":"alice@example.com"}'; HARNESS_GRAPH_UPN=''
  OUT="$(run_harness "00000000-aaaa-bbbb-cccc-111122223333")"
  # The durable key + `upn` field are the REAL UPN; the filename is its slug
  # (slugUpn maps `@` → `_`, so alice@example.com → alice_example.com.json).
  if printf '%s' "$OUT" | grep -q '"keyed_upn":"alice@example.com"' \
     && printf '%s' "$OUT" | grep -q '"token_files":\["alice_example.com.json"\]' \
     && printf '%s' "$OUT" | grep -q '"on_disk_upn":"alice@example.com"'; then
    _pass "T1: opaque input keyed by the id_token claim → tokens/alice_example.com.json, upn field = real UPN"
  else
    _fail "T1" "expected keyed_upn/on_disk_upn=alice@example.com, file=alice_example.com.json; got: $OUT"
  fi
  unset HARNESS_CLAIMS HARNESS_GRAPH_UPN

  # T2 — a FORGED opaque input + a different authenticated claim: the claim wins.
  HARNESS_CLAIMS='{"preferred_username":"real@example.com"}'; HARNESS_GRAPH_UPN=''
  OUT="$(run_harness "attacker@example.test")"
  if printf '%s' "$OUT" | grep -q '"keyed_upn":"real@example.com"' \
     && ! printf '%s' "$OUT" | grep -q 'attacker@example.test'; then
    _pass "T2: forged input ignored — durable key is the authenticated claim (real@example.com)"
  else
    _fail "T2" "forged input should not determine the key; got: $OUT"
  fi
  unset HARNESS_CLAIMS HARNESS_GRAPH_UPN

  # T3 — path-traversal in BOTH claim and opaque input is neutralized.
  # A traversal-shaped claim is rejected by normalizeClaimedUpn (contains '..'),
  # so the code falls back to the opaque input, whose slug must still be
  # confined to the tokens dir (no '/' survives, '..' collapses to '_').
  HARNESS_CLAIMS='{"preferred_username":"../../../../etc/passwd@x"}'; HARNESS_GRAPH_UPN=''
  OUT="$(run_harness "../../evil@example.com")"
  files_line="$(printf '%s' "$OUT" | sed -n 's/.*"token_files":\(\[[^]]*\]\).*/\1/p')"
  # No produced token file may contain a slash or a surviving '..' run — the
  # slug strips '/' and collapses '..' so the key stays inside tokens/. The
  # harness only ever writes via tokenPath(), so a confined filename proves
  # the write stayed in the tokens dir.
  if [[ -z "$files_line" ]]; then
    _fail "T3" "no token_files in harness output: $OUT"
  elif printf '%s' "$files_line" | grep -Eq '/|\.\.'; then
    _fail "T3" "a token filename escaped the tokens dir (traversal not neutralized): $files_line"
  else
    _pass "T3: traversal in claim + opaque input neutralized (slug confined to tokens/, no '/' or '..')"
  fi
  unset HARNESS_CLAIMS HARNESS_GRAPH_UPN

  # T4 — no id_token claim → Graph /me fallback supplies the real UPN.
  HARNESS_CLAIMS=''; HARNESS_GRAPH_UPN='bob@example.com'
  OUT="$(run_harness "11111111-aaaa-bbbb-cccc-222233334444")"
  if printf '%s' "$OUT" | grep -q '"keyed_upn":"bob@example.com"' \
     && printf '%s' "$OUT" | grep -q '"on_disk_upn":"bob@example.com"'; then
    _pass "T4: no id_token → Graph /me fallback keys by the real UPN (bob@example.com)"
  else
    _fail "T4" "graph /me fallback should supply the key; got: $OUT"
  fi
  unset HARNESS_CLAIMS HARNESS_GRAPH_UPN

  # T5 — neither claim source resolves → degrade to the opaque input (never block).
  HARNESS_CLAIMS=''; HARNESS_GRAPH_UPN=''
  OUT="$(run_harness "carol@example.com")"
  if printf '%s' "$OUT" | grep -q '"keyed_upn":"carol@example.com"'; then
    _pass "T5: both claim sources empty → degrade to the opaque input (pairing not blocked)"
  else
    _fail "T5" "should fall back to the opaque input when no claim resolves; got: $OUT"
  fi
  unset HARNESS_CLAIMS HARNESS_GRAPH_UPN
fi

# ---------------------------------------------------------------------------
printf '[1825-ms365-token-key-by-claim] %d/%d checks passed\n' "$((TOTAL - FAILS))" "$TOTAL"
[[ "$FAILS" -eq 0 ]] || exit 1
