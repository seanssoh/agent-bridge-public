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
# (#2035 widened the match to allow an optional second arg: getAccessToken(upn,
# freshness) threads the proactive-refresh margin through the same path.)
log "T2: handler reuses getAccessToken (refresh path)"
grep -Eq "getAccessToken\(upn[,)]" "$WORK/block.txt" \
  || fail "T2: get_valid_token handler does not call getAccessToken(upn...) (must reuse the refresh + SingleFlight path)"

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

# T6 — #1650 B1: the one-shot CLI entrypoint for sibling stdio callers (the
# cosmax-crm proxy, which is not an MCP client). `get-valid-token` argv branch
# handled before mcp.connect, prints JSON, reuses getAccessToken, no refresh_token.
log "T6: get-valid-token CLI entrypoint"
grep -Eq "process\.argv\[2\] === 'get-valid-token'" "$MS365_TS" \
  || fail "T6: server.ts does not handle the get-valid-token CLI subcommand"
# Must be handled BEFORE mcp.connect (one-shot, never starts the server).
CLI_LINE="$(grep -nE "process\.argv\[2\] === 'get-valid-token'" "$MS365_TS" | head -n1 | cut -d: -f1)"
CONNECT_LINE="$(grep -nE 'mcp\.connect\(new StdioServerTransport' "$MS365_TS" | head -n1 | cut -d: -f1)"
[[ -n "$CLI_LINE" && -n "$CONNECT_LINE" ]] || fail "T6: cannot locate CLI branch ($CLI_LINE) or mcp.connect ($CONNECT_LINE)"
(( CLI_LINE < CONNECT_LINE )) || fail "T6: get-valid-token CLI branch (line $CLI_LINE) must precede mcp.connect (line $CONNECT_LINE)"
# Isolate the CLI branch body (from the argv test to its process.exit(0)).
awk "
  /process.argv\[2\] === 'get-valid-token'/ {cap=1}
  cap {buf=buf\$0 ORS}
  cap && /process.exit\(0\)/ {print buf; exit}
" "$MS365_TS" >"$WORK/cli.txt"
[[ -s "$WORK/cli.txt" ]] || fail "T6: could not isolate the get-valid-token CLI branch body"
grep -Eq "getAccessToken\(upn[,)]" "$WORK/cli.txt" || fail "T6: CLI branch does not reuse getAccessToken(upn...)"
grep -Eq "access_token" "$WORK/cli.txt" || fail "T6: CLI branch does not emit access_token"
grep -vE "^[[:space:]]*//|^[[:space:]]*\*" "$WORK/cli.txt" >"$WORK/clicode.txt" || true
if grep -Eq "refresh_token" "$WORK/clicode.txt"; then
  fail "T6: CLI branch references refresh_token — must never leave the ms365 plugin"
fi

# T7 — #1654 codex r1 BLOCKING regression guard: resolveUpn() MUST be inside the
# CLI try/catch so a missing-upn/no-default failure exits non-zero. If it sits
# before `try {`, resolveUpn throws to the global uncaughtException handler which
# only logs and the process exits 0 (false success), breaking the proxy contract.
# Capture the FULL branch (through the catch's exit 1) and assert ordering + exit.
# (#2035 generalized the matched form from `resolveUpn(process.argv[3])` to the
# assignment `upn = resolveUpn(...)`, since the upn positional is now parsed as
# the first non-flag argv tail entry to support flag-only invocations. The
# assignment anchor avoids matching the `resolveUpn()` mention in the leading
# comment.)
log "T7: resolveUpn inside try, failure exits non-zero (no-upn regression guard)"
awk "
  /process.argv\[2\] === 'get-valid-token'/ {cap=1}
  cap {n++; if (\$0 ~ /try \{/ && !tryline) tryline=n; if (\$0 ~ /upn = resolveUpn\(/ && !upnline) upnline=n; print}
  cap && /process.exit\(1\)/ {exit}
" "$MS365_TS" >"$WORK/full.txt"
[[ -s "$WORK/full.txt" ]] || fail "T7: could not isolate the full CLI branch (through the catch)"
TRY_AT="$(grep -nE 'try \{' "$WORK/full.txt" | head -n1 | cut -d: -f1)"
UPN_AT="$(grep -nE 'upn = resolveUpn\(' "$WORK/full.txt" | head -n1 | cut -d: -f1)"
[[ -n "$TRY_AT" && -n "$UPN_AT" ]] || fail "T7: cannot locate try ($TRY_AT) or upn-assignment resolveUpn ($UPN_AT) in the CLI branch"
(( TRY_AT < UPN_AT )) || fail "T7: upn = resolveUpn(...) (line $UPN_AT) must be INSIDE the try (try at line $TRY_AT) so a no-upn failure exits non-zero"
grep -Eq "process\.exit\(1\)" "$WORK/full.txt" || fail "T7: CLI branch has no process.exit(1) failure path"

log "passed"
