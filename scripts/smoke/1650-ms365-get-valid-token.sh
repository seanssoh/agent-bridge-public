#!/usr/bin/env bash
# scripts/smoke/1650-ms365-get-valid-token.sh — issue #1650.
#
# Pins the ms365-side contract for #1650: a `get_valid_token` MCP tool that
# returns a guaranteed-valid access_token (refreshing via the stored
# refresh_token when expired/near-expiry) for trusted in-fleet callers (the CRM
# proxy) that previously read the token file directly and so used a stale token.
#
# Source-grep level (runs where bun is unavailable, like 1343's T0). The
# behavioral path (does it actually refresh a live token) is verified by the
# downstream patch agent against real M365 credentials.
#
# Security invariant: the tool returns the access_token but NEVER the
# refresh_token, and audits with upn+expiry only (no token body).
#
# Footgun #11: no heredoc/here-string to a subprocess; awk/grep on files only.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
MS365_TS="$REPO_ROOT/plugins/ms365/server.ts"

log() { printf '[smoke:1650-ms365-get-valid-token] %s\n' "$*"; }
fail() { printf '[smoke:1650-ms365-get-valid-token][error] %s\n' "$*" >&2; exit 1; }

[[ -f "$MS365_TS" ]] || fail "required file missing: $MS365_TS"

TMPDIR_BASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$TMPDIR_BASE/agb-1650-smoke.XXXXXX")"
trap 'rm -rf "$WORK" 2>/dev/null' EXIT INT TERM

# T1 — the tool is registered.
log "T1: get_valid_token tool registered"
grep -Eq "name: 'get_valid_token'" "$MS365_TS" \
  || fail "T1: server.ts does not register a get_valid_token tool"

# Extract the get_valid_token tool object block: from its name line to the next
# top-level tool boundary (the next `  {` at the tools-array indent or the
# `  name: '` of the following tool). Use the next "name: '" line as the end.
awk "/name: 'get_valid_token'/{f=1} f{print} f && /name: '/ && \$0 !~ /get_valid_token/{c++} c>=1 && /name: 'pair_status'/{exit}" "$MS365_TS" >"$WORK/block.txt" 2>/dev/null || true
# Robust fallback: capture from get_valid_token up to the next tool's name line.
awk "
  /name: 'get_valid_token'/ {cap=1}
  cap {buf=buf\$0 ORS}
  cap && /name: 'pair_status'/ {print buf; exit}
" "$MS365_TS" >"$WORK/block.txt"
[[ -s "$WORK/block.txt" ]] || fail "T1: could not isolate the get_valid_token tool block"

# T2 — the handler reuses getAccessToken (the refresh path), not a bespoke read.
log "T2: handler reuses getAccessToken (refresh path)"
grep -Eq "getAccessToken\(upn\)" "$WORK/block.txt" \
  || fail "T2: get_valid_token handler does not call getAccessToken(upn) (must reuse the refresh + SingleFlight path)"

# T3 — returns the access_token to the caller.
log "T3: returns access_token + expiry"
grep -Eq "access_token" "$WORK/block.txt" \
  || fail "T3: get_valid_token does not return access_token"
grep -Eq "expires_at|expires_in_seconds" "$WORK/block.txt" \
  || fail "T3: get_valid_token does not return an expiry field"

# T4 — SECURITY: the value RETURNED to the caller (textResult payload) and any
# audit line must NEVER include the refresh_token. The description string and
# code comments may mention the word (they document the guarantee), so scope the
# check to executable lines, excluding `//` comments and the `description:`
# contract string.
log "T4: refresh_token never exposed (security)"
grep -vE "^[[:space:]]*//|^[[:space:]]*\*|description:|NEVER returns the refresh_token|owns the refresh_token" "$WORK/block.txt" >"$WORK/code.txt" || true
if grep -Eq "refresh_token" "$WORK/code.txt"; then
  fail "T4: a non-comment line in get_valid_token references refresh_token — the refresh secret must never leave the ms365 plugin"
fi
# Belt-and-suspenders: the textResult return payload must not carry refresh_token.
if grep -E "textResult\(" "$WORK/block.txt" | grep -q "refresh_token"; then
  fail "T4: get_valid_token textResult payload includes refresh_token"
fi

# T5 — redacted audit row (upn + expiry only, no token body).
log "T5: redacted ms365_token_issued audit"
grep -Eq "ms365_token_issued" "$WORK/block.txt" \
  || fail "T5: get_valid_token does not emit the redacted ms365_token_issued audit row"
# The audit line must not stringify the token itself.
if grep -E "ms365_token_issued" "$WORK/block.txt" | grep -Eq '\$\{access_token\}|access_token=\$'; then
  fail "T5: ms365_token_issued audit appears to embed the access_token body (must be upn+expiry only)"
fi

log "passed"
