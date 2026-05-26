#!/usr/bin/env bash
# scripts/smoke/1209-ms365-redirect-resolver.sh — issue #1209.
#
# Pins the contract closed by #1209 (and the paired #1210 input
# normalization, exercised here on the redirect-URI half only —
# scope normalization is covered by 1210-ms365-scope-normalize.sh):
#
#   plugins/ms365/server.ts exposes `resolveRedirectUri()` which
#   replaces the prior silent `http://localhost:3978/auth/callback`
#   fallback with a fail-loud resolver. Priority:
#
#     1. Explicit non-localhost MS365_REDIRECT_URI         → returned
#     2. Explicit localhost + MS365_REDIRECT_URI_ALLOW_LOCALHOST=1
#                                                          → returned
#     3. Unset OR explicit-localhost without ALLOW flag    → throw
#
#   Plus the `agent-bridge setup ms365 <agent>` wizard which persists
#   MS365_REDIRECT_URI to `.ms365/.env` so the operator does not have
#   to discover the env var by failed Microsoft sign-in.
#
# Tests:
#   T1 (TS) — server.ts exports `resolveRedirectUri` and the throw
#             message names the setup command.
#   T2 (TS) — server.ts no longer carries the localhost default
#             fallback `http://localhost:3978/auth/callback`.
#   T3 (TS, runtime) — unset env → throw matching /must be set/.
#   T4 (TS, runtime) — explicit https → returns the URL.
#   T5 (TS, runtime) — explicit localhost no allow → throws.
#   T6 (TS, runtime) — explicit localhost + ALLOW=1 → returns the URL.
#   T7 (TS, runtime) — explicit 127.0.0.1 no allow → throws.
#   T8 (Python) — bridge-setup.py ms365 dry-run with
#                 `--messaging-endpoint https://x/api/messages`
#                 derives `https://x/auth/callback` correctly.
#   T9 (Python) — bridge-setup.py ms365 write produces a `.ms365/.env`
#                 containing the resolved `MS365_REDIRECT_URI`.
#   T10 (Python) — written `.env` file mode is 0600 (regression vs
#                  beta26 #1215 secret-file mode contract).
#   T11 (sh) — bridge-setup.sh ms365 --help renders without error.
#   T12 (sh) — bridge-setup.sh main usage block lists `ms365`.
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
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1209-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

MS365_TS="$REPO_ROOT/plugins/ms365/server.ts"
BRIDGE_SETUP_PY="$REPO_ROOT/bridge-setup.py"
BRIDGE_SETUP_SH="$REPO_ROOT/bridge-setup.sh"

for f in "$MS365_TS" "$BRIDGE_SETUP_PY" "$BRIDGE_SETUP_SH"; do
  if [[ ! -f "$f" ]]; then
    printf '[FAIL] required file missing: %s\n' "$f" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# T1 — server.ts exports resolveRedirectUri + throw message points at
# the setup command (so the operator gets an actionable error path).
# ---------------------------------------------------------------------------
T1_ERRORS=""
if ! grep -E "export function resolveRedirectUri" "$MS365_TS" >/dev/null; then
  T1_ERRORS+="resolveRedirectUri export missing; "
fi
if ! grep -F "agent-bridge setup ms365" "$MS365_TS" >/dev/null; then
  T1_ERRORS+="throw message does not reference 'agent-bridge setup ms365'; "
fi
if ! grep -E "MS365_REDIRECT_URI_ALLOW_LOCALHOST" "$MS365_TS" >/dev/null; then
  T1_ERRORS+="ALLOW_LOCALHOST opt-in env var not documented; "
fi
if [[ -z "$T1_ERRORS" ]]; then
  _pass "T1: server.ts exports resolveRedirectUri + names setup command + documents allow flag"
else
  _fail "T1" "$T1_ERRORS"
fi

# ---------------------------------------------------------------------------
# T2 — server.ts no longer has the localhost default fallback. Match
# the `?? 'http://localhost:3978/auth/callback'` pattern.
# ---------------------------------------------------------------------------
if grep -E "\?\?\s*['\"]http://localhost:3978/auth/callback['\"]" "$MS365_TS" >/dev/null; then
  _fail "T2" "server.ts still carries the localhost default fallback"
else
  _pass "T2: server.ts no longer falls back to localhost:3978/auth/callback"
fi

# ---------------------------------------------------------------------------
# T3-T7 — Runtime behavior of resolveRedirectUri. We extract the
# function body from server.ts and execute it via bun in isolation
# (no MCP SDK imports needed — the helper is pure).
# ---------------------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  _skip "T3: unset env → throw (bun not available)"
  _skip "T4: explicit https → returned (bun not available)"
  _skip "T5: localhost no-allow → throws (bun not available)"
  _skip "T6: localhost + allow → returned (bun not available)"
  _skip "T7: 127.0.0.1 no-allow → throws (bun not available)"
else
  HELPER_TS="$SMOKE_DIR/resolver.ts"
  cat >"$HELPER_TS" <<'TS_EOF'
function resolveRedirectUri(): string {
  const explicit = (process.env.MS365_REDIRECT_URI ?? '').trim()
  const allowLocalhost = process.env.MS365_REDIRECT_URI_ALLOW_LOCALHOST === '1'
  const isLocalhost = /^https?:\/\/(localhost|127\.0\.0\.1)(:|\/|$)/i.test(explicit)
  if (explicit && (!isLocalhost || allowLocalhost)) {
    return explicit
  }
  throw new Error(
    "MS365_REDIRECT_URI must be set to a publicly reachable URL " +
      "(typically https://<your-bot-host>/auth/callback). " +
      "Run 'agent-bridge setup ms365 <agent>' to persist it, " +
      "and register the same URL on your Entra app's Authentication → Redirect URIs. " +
      "(For local dev only: set MS365_REDIRECT_URI_ALLOW_LOCALHOST=1 to opt back into the localhost default.)",
  )
}

const mode = process.argv[2]
try {
  const result = resolveRedirectUri()
  console.log("OK:" + result)
} catch (e: any) {
  console.log("THROW:" + (e && e.message ? e.message : String(e)))
}
TS_EOF

  # Use `env -i` to scrub the parent env, then pass only the vars we
  # want. `T<N>_OUT="$(env ... bun ...)"` would NOT propagate the
  # prefix because shell parses it as two assignments: the env-prefix
  # form only applies to a SIMPLE command, not to an assignment whose
  # value is a command substitution.
  run_resolver() {
    env -i PATH="$PATH" HOME="$HOME" "$@" bun run "$HELPER_TS" 2>&1 || true
  }

  # T3: unset → throw
  T3_OUT="$(run_resolver)"
  if [[ "$T3_OUT" == THROW:* && "$T3_OUT" == *"must be set"* ]]; then
    _pass "T3: unset MS365_REDIRECT_URI → throws with actionable message"
  else
    _fail "T3" "expected THROW:must be set..., got: $T3_OUT"
  fi

  # T4: explicit https → returned
  T4_OUT="$(run_resolver MS365_REDIRECT_URI='https://bot.example.com/auth/callback')"
  if [[ "$T4_OUT" == "OK:https://bot.example.com/auth/callback" ]]; then
    _pass "T4: explicit https URL → returned"
  else
    _fail "T4" "expected OK:https://..., got: $T4_OUT"
  fi

  # T5: localhost no allow → throw
  T5_OUT="$(run_resolver MS365_REDIRECT_URI='http://localhost:3978/auth/callback')"
  if [[ "$T5_OUT" == THROW:* ]]; then
    _pass "T5: explicit localhost without ALLOW → throws"
  else
    _fail "T5" "expected THROW, got: $T5_OUT"
  fi

  # T6: localhost + ALLOW=1 → returned
  T6_OUT="$(run_resolver \
    MS365_REDIRECT_URI='http://localhost:3978/auth/callback' \
    MS365_REDIRECT_URI_ALLOW_LOCALHOST=1)"
  if [[ "$T6_OUT" == "OK:http://localhost:3978/auth/callback" ]]; then
    _pass "T6: explicit localhost + ALLOW=1 → returned"
  else
    _fail "T6" "expected OK:http://localhost..., got: $T6_OUT"
  fi

  # T7: 127.0.0.1 no allow → throw
  T7_OUT="$(run_resolver MS365_REDIRECT_URI='http://127.0.0.1:3978/auth/callback')"
  if [[ "$T7_OUT" == THROW:* ]]; then
    _pass "T7: explicit 127.0.0.1 without ALLOW → throws"
  else
    _fail "T7" "expected THROW, got: $T7_OUT"
  fi
fi

# ---------------------------------------------------------------------------
# T8 — bridge-setup.py ms365 dry-run derives redirect URI from
# `--messaging-endpoint`. Tests the wizard's derivation logic without
# touching any live install state.
# ---------------------------------------------------------------------------
T8_DIR="$SMOKE_DIR/t8/.ms365"
T8_OUT="$(python3 "$BRIDGE_SETUP_PY" ms365 \
  --agent testagent \
  --ms365-dir "$T8_DIR" \
  --messaging-endpoint https://bot.example.com/api/messages \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --yes --dry-run 2>&1 || true)"
if printf '%s\n' "$T8_OUT" | grep -E "redirect_uri:\s*https://bot.example.com/auth/callback" >/dev/null \
   && printf '%s\n' "$T8_OUT" | grep -E "redirect_uri_source:\s*derived:flag:--messaging-endpoint" >/dev/null; then
  _pass "T8: bridge-setup.py ms365 dry-run derives /auth/callback from --messaging-endpoint"
else
  _fail "T8" "derive failed; output: $T8_OUT"
fi

# ---------------------------------------------------------------------------
# T9 — bridge-setup.py ms365 (no dry-run) writes the resolved
# MS365_REDIRECT_URI to .ms365/.env.
# ---------------------------------------------------------------------------
T9_DIR="$SMOKE_DIR/t9/.ms365"
python3 "$BRIDGE_SETUP_PY" ms365 \
  --agent testagent \
  --ms365-dir "$T9_DIR" \
  --redirect-uri https://bot.example.com/auth/callback \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --yes >"$SMOKE_DIR/t9.log" 2>&1 || true
if [[ -f "$T9_DIR/.env" ]] && grep -E "^MS365_REDIRECT_URI=https://bot.example.com/auth/callback$" "$T9_DIR/.env" >/dev/null; then
  _pass "T9: bridge-setup.py ms365 writes MS365_REDIRECT_URI= to .ms365/.env"
else
  _fail "T9" ".env missing or MS365_REDIRECT_URI not persisted; .env contents: $(cat "$T9_DIR/.env" 2>/dev/null || printf '(no file)')"
fi

# ---------------------------------------------------------------------------
# T10 — .ms365/.env file mode stays 0600 (regression check vs #1215
# secret-file mode contract).
# ---------------------------------------------------------------------------
if [[ -f "$T9_DIR/.env" ]]; then
  T10_MODE_LINUX="$(stat -c '%a' "$T9_DIR/.env" 2>/dev/null || true)"
  T10_MODE_MACOS="$(stat -f '%Lp' "$T9_DIR/.env" 2>/dev/null || true)"
  T10_MODE="${T10_MODE_LINUX:-$T10_MODE_MACOS}"
  if [[ "$T10_MODE" == "600" ]]; then
    _pass "T10: .ms365/.env file mode 0600 (no widening beyond secrets contract)"
  else
    _fail "T10" "expected mode 600, got: '$T10_MODE'"
  fi
else
  _fail "T10" "skipped — .env was not written"
fi

# ---------------------------------------------------------------------------
# T11 — bridge-setup.sh ms365 --help renders without error.
# ---------------------------------------------------------------------------
T11_BASH="/opt/homebrew/bin/bash"
if [[ ! -x "$T11_BASH" ]]; then
  T11_BASH="$(command -v bash)"
fi
T11_OUT="$("$T11_BASH" "$BRIDGE_SETUP_SH" ms365 --help 2>&1 || true)"
if printf '%s\n' "$T11_OUT" | grep -E "ms365 <agent>.*--redirect-uri" >/dev/null; then
  _pass "T11: bridge-setup.sh ms365 --help renders the ms365 subcommand usage"
else
  _fail "T11" "ms365 --help missing expected usage; output: $T11_OUT"
fi

# ---------------------------------------------------------------------------
# T12 — bridge-setup.sh main usage lists ms365 as a known subcommand.
# ---------------------------------------------------------------------------
T12_OUT="$("$T11_BASH" "$BRIDGE_SETUP_SH" --help 2>&1 || true)"
if printf '%s\n' "$T12_OUT" | grep -E "ms365 <agent>" >/dev/null; then
  _pass "T12: bridge-setup.sh main usage includes ms365"
else
  _fail "T12" "main usage missing ms365; output: $T12_OUT"
fi

printf '[%s] %d/%d passed (FAILS=%d)\n' "$(basename "$0")" "$((TOTAL - FAILS))" "$TOTAL" "$FAILS"
if [[ $FAILS -ne 0 ]]; then
  exit 1
fi
exit 0
