#!/usr/bin/env bash
# scripts/smoke/1355-1356-ms365-wizard.sh — issues #1355 + #1356.
#
# Pins two refinements to the `agent-bridge setup ms365` wizard:
#
#   #1355 — --default-scopes is now a protocol-convention default (MS
#           Graph minimal: Mail.Read / Mail.Send / Calendars.ReadWrite
#           / offline_access) rather than wizard-required. Auto-mode
#           (`--yes`) without `--default-scopes` succeeds and surfaces
#           `default_scopes_source: convention-default`. Site-specific
#           values (client-id, secret, tenant-id, redirect-uri,
#           default-upn) stay wizard-required.
#
#   #1356 — The wizard now probes the Entra app registration's
#           `web.redirectUris` via Microsoft Graph and fails loud when
#           the operator-supplied redirect URI is NOT registered. Probe
#           respects `--skip-entra-probe` and gracefully skips when
#           credentials/network/permissions are missing
#           (`redirect_uri_check: skipped (...)`).
#
# Tests:
#   T1 (#1355): auto-mode without `--default-scopes` succeeds + uses
#               convention default + emits the source marker.
#   T2 (#1355): auto-mode with `--default-scopes "X Y"` uses the given
#               scopes verbatim + emits source `flag:--default-scopes`.
#   T3 (#1355): wizard required-fields enumerator no longer lists
#               `default-scopes` for ms365 (#1355 promotion).
#   T4 (#1356): mock Graph API returning `redirect_uris=[<target>]` →
#               `redirect_uri_check: ok` + `redirect_uri_registered: yes`.
#   T5 (#1356): mock returning `redirect_uris=[<other>]` → fail-loud
#               with abort + error names "등록돼 있지 않습니다".
#   T6 (#1356): mock returning 403 with `Authorization_RequestDenied`
#               → `redirect_uri_check: skipped (insufficient app
#               permission)` + write_status: ok (does NOT abort).
#   T7 teeth (#1355): convention-default constant has the canonical
#                     4-scope minimal set (regression guard against a
#                     future patch shrinking the default).
#   T8 teeth (#1356): the Entra-probe helper is wired into cmd_ms365
#                     (regression guard against a future patch
#                     short-circuiting the probe call).
#
# Mock surface: BRIDGE_MS365_LOGIN_BASE_URL + BRIDGE_MS365_GRAPH_BASE_URL
# point at a short-lived python http.server that returns the canned
# token + `applications?$filter=...` response. The server lives in
# `$SMOKE_DIR/mock-server.py` and is killed by the EXIT trap.
#
# Footgun #11: every captured subprocess uses `out=$(... 2>&1)`. The
# python mock-server body is materialized to a file and invoked by
# path, not via heredoc-stdin to subprocess.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

FAILS=0
TOTAL=0
_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-1355-1356-smoke.XXXXXX")"
MOCK_PID=""
cleanup() {
  if [[ -n "$MOCK_PID" ]]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$SMOKE_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

BRIDGE_SETUP_PY="$REPO_ROOT/bridge-setup.py"
WIZARD_LIB="$REPO_ROOT/lib/bridge-setup-wizard.sh"

for f in "$BRIDGE_SETUP_PY" "$WIZARD_LIB"; do
  if [[ ! -f "$f" ]]; then
    printf '[FAIL] required file missing: %s\n' "$f" >&2
    exit 1
  fi
done

# Pick a Bash 4+ interpreter (mac default is 3.2, which trips
# bridge-lib.sh sources). Mirrors B-beta4 smoke.
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# ---------------------------------------------------------------------------
# Helper: run bridge-setup.py ms365 with a fresh ms365-dir under SMOKE_DIR.
# Returns rc + captures stdout+stderr together.
# ---------------------------------------------------------------------------
run_ms365_setup() {
  local label="$1"
  shift
  local ms365_dir="$SMOKE_DIR/$label/.ms365"
  mkdir -p "$ms365_dir"
  local out=""
  local rc=0
  out="$(python3 "$BRIDGE_SETUP_PY" ms365 \
    --agent testagent \
    --ms365-dir "$ms365_dir" \
    "$@" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# ---------------------------------------------------------------------------
# T1 — #1355 — auto-mode without --default-scopes succeeds and uses the
# protocol convention default. We --skip-entra-probe to keep the test
# offline (the probe is exercised by T4-T6 against the mock server).
# ---------------------------------------------------------------------------
T1_OUT="$(run_ms365_setup t1 \
  --redirect-uri https://bot.example.com/auth/callback \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --default-upn user@example.com \
  --skip-entra-probe \
  --yes)" || T1_RC=$?
T1_RC="${T1_RC:-0}"
T1_ENV="$SMOKE_DIR/t1/.ms365/.env"
if [[ "$T1_RC" -ne 0 ]]; then
  _fail "T1" "exit rc=$T1_RC (expected 0); out: $T1_OUT"
elif ! printf '%s\n' "$T1_OUT" | grep -F "default_scopes_source: convention-default" >/dev/null; then
  _fail "T1" "missing 'default_scopes_source: convention-default' marker; out: $T1_OUT"
elif ! printf '%s\n' "$T1_OUT" | grep -E "default_scopes:.*https://graph.microsoft.com/Mail.Read.*Mail.Send.*Calendars.ReadWrite.*offline_access" >/dev/null; then
  _fail "T1" "default_scopes line did not include the canonical minimal set; out: $T1_OUT"
elif [[ ! -f "$T1_ENV" ]]; then
  _fail "T1" ".env was not written: $T1_ENV"
elif ! grep -E "^MS365_DEFAULT_SCOPES=https://graph.microsoft.com/Mail.Read https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/Calendars.ReadWrite offline_access$" "$T1_ENV" >/dev/null; then
  _fail "T1" "MS365_DEFAULT_SCOPES line in .env did not match canonical convention default; .env: $(cat "$T1_ENV")"
else
  _pass "T1 (#1355): auto-mode without --default-scopes uses convention default + emits source marker"
fi

# ---------------------------------------------------------------------------
# T2 — #1355 — auto-mode WITH --default-scopes uses the given scopes
# verbatim + source marker is `flag:--default-scopes`.
# ---------------------------------------------------------------------------
T2_OUT="$(run_ms365_setup t2 \
  --redirect-uri https://bot.example.com/auth/callback \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --default-scopes "openid Foo.Custom Bar.Other" \
  --skip-entra-probe \
  --yes)" || T2_RC=$?
T2_RC="${T2_RC:-0}"
T2_ENV="$SMOKE_DIR/t2/.ms365/.env"
if [[ "$T2_RC" -ne 0 ]]; then
  _fail "T2" "exit rc=$T2_RC (expected 0); out: $T2_OUT"
elif ! printf '%s\n' "$T2_OUT" | grep -F "default_scopes_source: flag:--default-scopes" >/dev/null; then
  _fail "T2" "missing 'default_scopes_source: flag:--default-scopes' marker; out: $T2_OUT"
elif ! grep -E "^MS365_DEFAULT_SCOPES=openid Foo.Custom Bar.Other$" "$T2_ENV" >/dev/null; then
  _fail "T2" "explicit scopes not persisted verbatim; .env: $(cat "$T2_ENV")"
else
  _pass "T2 (#1355): auto-mode with --default-scopes uses given scopes + flag source marker"
fi

# ---------------------------------------------------------------------------
# T3 — #1355 — wizard required-fields enumerator no longer lists
# `default-scopes` for ms365 (the promotion is visible at the wizard
# layer too — auto-mode validation never flags --default-scopes as
# missing).
# ---------------------------------------------------------------------------
T3_OUT="$("$BRIDGE_BASH" -c '
  set -uo pipefail
  source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1 || true
  source "'"$WIZARD_LIB"'"
  printf "ms365_required="
  bridge_setup_wizard_required_fields ms365 | tr "\n" "," | sed "s/,$//"
  printf "\n"
' 2>&1)"
if printf '%s\n' "$T3_OUT" | grep -F "ms365_required=client-id,client-secret-file,tenant-id,redirect-uri" >/dev/null \
   && ! printf '%s\n' "$T3_OUT" | grep -F "default-scopes" >/dev/null; then
  _pass "T3 (#1355): wizard ms365 required-fields no longer includes default-scopes"
else
  _fail "T3" "expected ms365_required=client-id,client-secret-file,tenant-id,redirect-uri (no default-scopes); got: $T3_OUT"
fi

# ---------------------------------------------------------------------------
# Mock server setup for T4-T6. The server runs in a child process and
# routes:
#   POST /<tenant>/oauth2/v2.0/token   → { "access_token": "...", ... }
#   GET  /v1.0/applications?$filter=appId eq '<cid>'&$select=...
#                                      → { "value": [ { "appId": ..., "web": { "redirectUris": [...] } } ] }
# The server reads its desired behavior from environment via a file:
#   $SMOKE_DIR/mock-config.json with { redirectUris: [...], status: 200|403, ... }
# We rewrite the config file between subtests.
# ---------------------------------------------------------------------------

MOCK_SERVER_PY="$SMOKE_DIR/mock-server.py"
MOCK_CONFIG="$SMOKE_DIR/mock-config.json"

# Materialize the mock server script to disk (file-as-argv only — no
# heredoc-stdin to subprocess; see footgun #11).
cat >"$MOCK_SERVER_PY" <<'PY_EOF'
"""Tiny mock Microsoft Graph + login endpoint for smoke 1355-1356.

Reads behavior from $MOCK_CONFIG, which is a JSON file containing:
  - redirect_uris (list[str])
  - graph_status (int)        — HTTP status for the applications query
  - graph_error_code (str)    — Optional Microsoft error code, included
                                in the error body for 403 responses.
  - graph_error_message (str) — Optional error message body.

Rewriting the config file picks up immediately (read on every request).
"""

from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def _load_config() -> dict:
    path = os.environ["MOCK_CONFIG"]
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # noqa: A003
        # Quiet the default per-request stderr noise — the smoke captures
        # the parent's stdout only.
        pass

    def _send_json(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):  # noqa: N802
        # /<tenant>/oauth2/v2.0/token
        if self.path.endswith("/oauth2/v2.0/token"):
            length = int(self.headers.get("Content-Length") or "0")
            _ = self.rfile.read(length)  # body discarded
            self._send_json(
                200,
                {
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "access_token": "mock-graph-access-token",
                },
            )
            return
        self._send_json(404, {"error": {"code": "NotFound"}})

    def do_GET(self):  # noqa: N802
        cfg = _load_config()
        if self.path.startswith("/v1.0/applications"):
            status = int(cfg.get("graph_status") or 200)
            if status != 200:
                self._send_json(
                    status,
                    {
                        "error": {
                            "code": cfg.get("graph_error_code") or "Forbidden",
                            "message": cfg.get("graph_error_message") or "denied",
                        }
                    },
                )
                return
            uris = list(cfg.get("redirect_uris") or [])
            self._send_json(
                200,
                {
                    "value": [
                        {
                            "appId": "C1",
                            "web": {"redirectUris": uris},
                        }
                    ]
                },
            )
            return
        self._send_json(404, {"error": {"code": "NotFound"}})


def main() -> int:
    host = os.environ.get("MOCK_HOST", "127.0.0.1")
    port = int(os.environ.get("MOCK_PORT") or "0")
    server = HTTPServer((host, port), Handler)
    bound_port = server.server_address[1]
    # The parent reads this from the port file before issuing requests.
    port_file = os.environ.get("MOCK_PORT_FILE")
    if port_file:
        with open(port_file, "w", encoding="utf-8") as fh:
            fh.write(str(bound_port))
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY_EOF

MOCK_PORT_FILE="$SMOKE_DIR/mock-port"
# Default config — overwritten before each subtest.
printf '%s\n' '{"redirect_uris": [], "graph_status": 200}' >"$MOCK_CONFIG"

# Start the mock server.
MOCK_CONFIG="$MOCK_CONFIG" MOCK_HOST=127.0.0.1 MOCK_PORT=0 \
  MOCK_PORT_FILE="$MOCK_PORT_FILE" python3 "$MOCK_SERVER_PY" \
  >"$SMOKE_DIR/mock.log" 2>&1 &
MOCK_PID=$!

# Wait for the port file to materialize.
mock_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if [[ -s "$MOCK_PORT_FILE" ]]; then
    mock_ready=1
    break
  fi
  sleep 0.2
done
if [[ "$mock_ready" -ne 1 ]]; then
  _fail "T4-setup" "mock server did not bind a port within 3s; mock.log: $(cat "$SMOKE_DIR/mock.log" 2>/dev/null || printf '(empty)')"
  exit 1
fi
MOCK_PORT="$(cat "$MOCK_PORT_FILE")"
MOCK_BASE="http://127.0.0.1:$MOCK_PORT"

export BRIDGE_MS365_LOGIN_BASE_URL="$MOCK_BASE"
export BRIDGE_MS365_GRAPH_BASE_URL="$MOCK_BASE"

# Allow `http://bot.example.com` to bypass the redirect-URI warning
# (used only by the smoke fixture so the input URL stays stable).
TARGET_URI="https://bot.example.com/auth/callback"
OTHER_URI="https://other.example.com/somewhere/else"

# ---------------------------------------------------------------------------
# T4 — #1356 — mock returns redirect_uris=[<target>] → registered=yes.
# ---------------------------------------------------------------------------
printf '%s\n' "{\"redirect_uris\": [\"$TARGET_URI\"], \"graph_status\": 200}" >"$MOCK_CONFIG"
T4_OUT="$(run_ms365_setup t4 \
  --redirect-uri "$TARGET_URI" \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --yes)" || T4_RC=$?
T4_RC="${T4_RC:-0}"
if [[ "$T4_RC" -ne 0 ]]; then
  _fail "T4" "exit rc=$T4_RC (expected 0); out: $T4_OUT"
elif ! printf '%s\n' "$T4_OUT" | grep -F "redirect_uri_check: ok" >/dev/null; then
  _fail "T4" "missing 'redirect_uri_check: ok' marker; out: $T4_OUT"
elif ! printf '%s\n' "$T4_OUT" | grep -F "redirect_uri_registered: yes" >/dev/null; then
  _fail "T4" "missing 'redirect_uri_registered: yes' marker; out: $T4_OUT"
else
  _pass "T4 (#1356): mock Graph returning matching URI → redirect_uri_check: ok"
fi

# ---------------------------------------------------------------------------
# T5 — #1356 — mock returns redirect_uris=[<other>] → fail-loud abort.
# ---------------------------------------------------------------------------
printf '%s\n' "{\"redirect_uris\": [\"$OTHER_URI\"], \"graph_status\": 200}" >"$MOCK_CONFIG"
T5_OUT="$(run_ms365_setup t5 \
  --redirect-uri "$TARGET_URI" \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --yes)" || T5_RC=$?
T5_RC="${T5_RC:-0}"
T5_ENV="$SMOKE_DIR/t5/.ms365/.env"
if [[ "$T5_RC" -eq 0 ]]; then
  _fail "T5" "expected non-zero rc (probe should have aborted); out: $T5_OUT"
elif ! printf '%s\n' "$T5_OUT" | grep -F "등록돼 있지 않습니다" >/dev/null; then
  _fail "T5" "expected '등록돼 있지 않습니다' fail-loud message; out: $T5_OUT"
elif [[ -f "$T5_ENV" ]]; then
  _fail "T5" "probe died but .env was still written (regression: abort must happen BEFORE the write)"
else
  _pass "T5 (#1356): mock returning non-matching URI → fail-loud abort, no .env written"
fi

# ---------------------------------------------------------------------------
# T6 — #1356 — mock returns 403 Authorization_RequestDenied → wizard
# annotates `redirect_uri_check: skipped (insufficient app permission)`
# and DOES NOT abort.
# ---------------------------------------------------------------------------
printf '%s\n' '{"redirect_uris": [], "graph_status": 403, "graph_error_code": "Authorization_RequestDenied", "graph_error_message": "Insufficient privileges to complete the operation."}' >"$MOCK_CONFIG"
T6_OUT="$(run_ms365_setup t6 \
  --redirect-uri "$TARGET_URI" \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --yes)" || T6_RC=$?
T6_RC="${T6_RC:-0}"
T6_ENV="$SMOKE_DIR/t6/.ms365/.env"
if [[ "$T6_RC" -ne 0 ]]; then
  _fail "T6" "expected rc=0 (skip should not abort); out: $T6_OUT"
elif ! printf '%s\n' "$T6_OUT" | grep -F "redirect_uri_check: skipped (insufficient app permission" >/dev/null; then
  _fail "T6" "missing 'skipped (insufficient app permission' marker; out: $T6_OUT"
elif [[ ! -f "$T6_ENV" ]]; then
  _fail "T6" "expected .env to be written (skip is non-fatal); out: $T6_OUT"
else
  _pass "T6 (#1356): mock returning 403 → annotated skip + write proceeds"
fi

# ---------------------------------------------------------------------------
# T7 (teeth) — #1355 — convention default constant in bridge-setup.py
# carries the canonical Mail+Calendar minimal set. Regression guard
# against a future patch shrinking the default (e.g. dropping Mail.Send
# or Calendars.ReadWrite) without bumping the smoke.
# ---------------------------------------------------------------------------
T7_MATCH="$(grep -nE "MS365_CONVENTION_DEFAULT_SCOPES" "$BRIDGE_SETUP_PY" | head -5)"
if printf '%s\n' "$T7_MATCH" | grep -F "MS365_CONVENTION_DEFAULT_SCOPES" >/dev/null \
   && grep -F "https://graph.microsoft.com/Mail.Read" "$BRIDGE_SETUP_PY" >/dev/null \
   && grep -F "https://graph.microsoft.com/Mail.Send" "$BRIDGE_SETUP_PY" >/dev/null \
   && grep -F "https://graph.microsoft.com/Calendars.ReadWrite" "$BRIDGE_SETUP_PY" >/dev/null \
   && grep -E "^\s*\"offline_access\"" "$BRIDGE_SETUP_PY" >/dev/null; then
  _pass "T7 (teeth #1355): MS365_CONVENTION_DEFAULT_SCOPES holds canonical Mail+Calendar minimal set"
else
  _fail "T7" "convention default constant body changed shape (Mail.Read/Mail.Send/Calendars.ReadWrite/offline_access required); grep: $T7_MATCH"
fi

# ---------------------------------------------------------------------------
# T8 (teeth) — #1356 — the Entra probe call site is still wired into
# cmd_ms365. Regression guard against a future patch silently
# replacing the call with a no-op or branching it off behind an
# always-true flag.
# ---------------------------------------------------------------------------
if grep -F "ms365_check_redirect_uri_registered(" "$BRIDGE_SETUP_PY" >/dev/null \
   && grep -F "skip_entra_probe" "$BRIDGE_SETUP_PY" >/dev/null; then
  _pass "T8 (teeth #1356): cmd_ms365 invokes ms365_check_redirect_uri_registered + honors --skip-entra-probe"
else
  _fail "T8" "probe wiring missing — cmd_ms365 must call ms365_check_redirect_uri_registered + check skip_entra_probe"
fi

# ---------------------------------------------------------------------------
# T9 (codex-rescue catch) — #1356 — verbatim match is verbatim. The
# Microsoft identity platform matches the sent redirect_uri against
# the Entra `web.redirectUris` array character-for-character (including
# query string and fragment). An earlier implementation stripped query
# + fragment in the normalization helper "to avoid spurious mismatches",
# which would let `https://x/cb?code=abc` pass the probe while
# AADSTS50011 fires at runtime. Pin both directions:
#   T9a — operator-typed URI carries a query string, Entra registered
#         the bare URI → probe MUST say not_registered + fail-loud abort.
#   T9b — operator-typed URI carries a fragment, Entra registered the
#         bare URI → probe MUST say not_registered + fail-loud abort.
# ---------------------------------------------------------------------------
printf '%s\n' "{\"redirect_uris\": [\"$TARGET_URI\"], \"graph_status\": 200}" >"$MOCK_CONFIG"
T9A_OUT="$(run_ms365_setup t9a \
  --redirect-uri "${TARGET_URI}?code=abc" \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --yes)" || T9A_RC=$?
T9A_RC="${T9A_RC:-0}"
if [[ "$T9A_RC" -eq 0 ]]; then
  _fail "T9a" "verbatim match regression: query-string suffix bypassed probe (Entra would fire AADSTS50011 at runtime). out: $T9A_OUT"
elif ! printf '%s\n' "$T9A_OUT" | grep -F "등록돼 있지 않습니다" >/dev/null; then
  _fail "T9a" "expected fail-loud on query-string mismatch; out: $T9A_OUT"
else
  _pass "T9a (#1356 codex-rescue catch): query-string suffix triggers not_registered (verbatim match holds)"
fi

T9B_OUT="$(run_ms365_setup t9b \
  --redirect-uri "${TARGET_URI}#fragment" \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --yes)" || T9B_RC=$?
T9B_RC="${T9B_RC:-0}"
if [[ "$T9B_RC" -eq 0 ]]; then
  _fail "T9b" "verbatim match regression: fragment suffix bypassed probe. out: $T9B_OUT"
elif ! printf '%s\n' "$T9B_OUT" | grep -F "등록돼 있지 않습니다" >/dev/null; then
  _fail "T9b" "expected fail-loud on fragment mismatch; out: $T9B_OUT"
else
  _pass "T9b (#1356 codex-rescue catch): fragment suffix triggers not_registered"
fi

# T9c — flip the other direction: Entra registered URI carries a query,
# operator typed the bare URI → still not_registered (verbatim both ways).
printf '%s\n' "{\"redirect_uris\": [\"${TARGET_URI}?login=1\"], \"graph_status\": 200}" >"$MOCK_CONFIG"
T9C_OUT="$(run_ms365_setup t9c \
  --redirect-uri "$TARGET_URI" \
  --tenant-id T1 --client-id C1 --client-secret S1 \
  --yes)" || T9C_RC=$?
T9C_RC="${T9C_RC:-0}"
if [[ "$T9C_RC" -eq 0 ]]; then
  _fail "T9c" "verbatim match regression: Entra had a query-suffixed URI, operator typed bare, probe falsely accepted. out: $T9C_OUT"
elif ! printf '%s\n' "$T9C_OUT" | grep -F "등록돼 있지 않습니다" >/dev/null; then
  _fail "T9c" "expected fail-loud on inverse mismatch; out: $T9C_OUT"
else
  _pass "T9c (#1356 codex-rescue catch): inverse direction also verbatim (registered carries query, sent bare → not_registered)"
fi

# T9d (teeth, source-level) — verify the normalize helper does NOT strip
# query/fragment. A future patch that re-introduces urlparse + path-only
# would silently re-open the T9a/T9b bypass; T9d catches the source
# change without needing the full mock loop.
HELPER_BODY="$(awk '/^def ms365_normalize_redirect_uri_for_compare/{f=1; next} f && /^def /{exit} f' "$BRIDGE_SETUP_PY")"
if [[ -z "$HELPER_BODY" ]]; then
  _fail "T9d (teeth)" "could not locate ms365_normalize_redirect_uri_for_compare body (function renamed/removed?)"
elif printf '%s\n' "$HELPER_BODY" | grep -F "urlparse" >/dev/null; then
  _fail "T9d (teeth)" "ms365_normalize_redirect_uri_for_compare re-introduced urlparse-based stripping — query/fragment bypass is back"
elif printf '%s\n' "$HELPER_BODY" | grep -E "parsed\.(path|netloc|scheme)" >/dev/null; then
  _fail "T9d (teeth)" "ms365_normalize_redirect_uri_for_compare re-introduced parsed.path/netloc/scheme — query/fragment bypass is back"
else
  _pass "T9d (teeth #1356): ms365_normalize_redirect_uri_for_compare is verbatim (no urlparse-based strip)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n[summary] 1355-1356-ms365-wizard: %d tests, %d failures\n' "$TOTAL" "$FAILS"
if (( FAILS > 0 )); then
  exit 1
fi
exit 0
