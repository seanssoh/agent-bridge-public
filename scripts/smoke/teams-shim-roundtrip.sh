#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/teams-shim-roundtrip.sh — L1 beta19 (codex r1 design
# 2026-05-25): exercise plugins/teams/server.ts createExpressResponseShim
# with a fake http.ServerResponse that has writeHead/end but no
# status/send (the BotFrameworkAdapter response shape mismatch this fix
# closes).
#
# Asserts:
#   T1 — JSON object body → end() called once, statusCode=202,
#        Content-Type=application/json, body=stringified JSON.
#   T2 — String body → end() called once, statusCode=200, no
#        Content-Type set, body=string verbatim.
#   T3 — Buffer body → end() called once, statusCode=200, body=Buffer.
#   T4 — undefined body → end() called once with no body, statusCode=204.
#   T5 — null body → end() called once with no body, statusCode=204.
#   T6 — double send() → second call is a no-op (defense against
#        adapter double-end on error catch).
#
# Footgun #11 — no heredoc-stdin to subprocess. The bun invocation is
# direct argv, output captured via plain `$()` substitution which is
# safe (no piped stdin).

set -uo pipefail

SMOKE_NAME="teams-shim-roundtrip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Bun is required to run server.ts. Skip cleanly if absent (the smoke
# matrix tolerates skips on hosts without bun installed).
if ! command -v bun >/dev/null 2>&1; then
  smoke_skip "teams-shim-roundtrip" "bun not on PATH; install via https://bun.sh/install to run this smoke"
  exit 0
fi

TEAMS_DIR="$REPO_ROOT/plugins/teams"
if [[ ! -d "$TEAMS_DIR/node_modules" ]]; then
  smoke_log "ensuring plugins/teams/node_modules present"
  if ! ( cd "$TEAMS_DIR" && bun install --frozen-lockfile --no-summary >&2 ); then
    smoke_fail "bun install in plugins/teams failed"
  fi
fi

run_shim_variant() {
  local variant="$1"
  TEAMS_APP_ID=smoke TEAMS_APP_PASSWORD=smoke \
    bun "$TEAMS_DIR/server.ts" _smoke-shim --variant "$variant"
}

assert_json_field() {
  local payload="$1" field="$2" want="$3" ctx="$4"
  # python3 is the universal extractor we already require elsewhere
  local got
  got="$(printf '%s\n' "$payload" \
        | python3 -c 'import json,sys; row=json.loads(sys.stdin.read().splitlines()[-1]); print(row.get(sys.argv[1]))' \
            "$field" 2>/dev/null)"
  if [[ "$got" != "$want" ]]; then
    smoke_fail "$ctx: field $field want '$want' got '$got' from payload: $payload"
  fi
}

test_t1_json_body() {
  smoke_log "T1: JSON object body → application/json + statusCode=202"
  local out
  out="$(run_shim_variant json)"
  assert_json_field "$out" threw "False" "T1"
  assert_json_field "$out" ended "True" "T1"
  assert_json_field "$out" endCalls "1" "T1"
  assert_json_field "$out" statusCode "202" "T1"
  assert_json_field "$out" contentType "application/json" "T1"
  assert_json_field "$out" bodyString '{"ok":true,"smoke":"shim"}' "T1"
  smoke_log "T1 PASS"
}

test_t2_string_body() {
  smoke_log "T2: string body → no Content-Type set, body verbatim"
  local out
  out="$(run_shim_variant string)"
  assert_json_field "$out" threw "False" "T2"
  assert_json_field "$out" ended "True" "T2"
  assert_json_field "$out" statusCode "200" "T2"
  assert_json_field "$out" contentType "None" "T2"
  assert_json_field "$out" bodyString "plain string body" "T2"
  smoke_log "T2 PASS"
}

test_t3_buffer_body() {
  smoke_log "T3: Buffer body → bodyKind=buffer, no Content-Type"
  local out
  out="$(run_shim_variant buffer)"
  assert_json_field "$out" threw "False" "T3"
  assert_json_field "$out" ended "True" "T3"
  assert_json_field "$out" statusCode "200" "T3"
  assert_json_field "$out" bodyKind "buffer" "T3"
  smoke_log "T3 PASS"
}

test_t4_empty_body() {
  smoke_log "T4: undefined body → res.end() with no body"
  local out
  out="$(run_shim_variant empty)"
  assert_json_field "$out" threw "False" "T4"
  assert_json_field "$out" ended "True" "T4"
  assert_json_field "$out" statusCode "204" "T4"
  assert_json_field "$out" bodyKind "undefined" "T4"
  smoke_log "T4 PASS"
}

test_t5_null_body() {
  smoke_log "T5: null body → res.end() with no body"
  local out
  out="$(run_shim_variant null)"
  assert_json_field "$out" threw "False" "T5"
  assert_json_field "$out" ended "True" "T5"
  assert_json_field "$out" statusCode "204" "T5"
  assert_json_field "$out" bodyKind "undefined" "T5"
  smoke_log "T5 PASS"
}

test_t6_double_send_no_op() {
  smoke_log "T6: second send() is a no-op (defensive against adapter double-end)"
  local out
  out="$(run_shim_variant double-send)"
  assert_json_field "$out" threw "False" "T6"
  assert_json_field "$out" endCalls "1" "T6"
  # First send wins — payload should be the first body, not the second.
  assert_json_field "$out" bodyString '{"first":true}' "T6"
  smoke_log "T6 PASS"
}

smoke_run "T1 json-body" test_t1_json_body
smoke_run "T2 string-body" test_t2_string_body
smoke_run "T3 buffer-body" test_t3_buffer_body
smoke_run "T4 empty-body" test_t4_empty_body
smoke_run "T5 null-body" test_t5_null_body
smoke_run "T6 double-send-no-op" test_t6_double_send_no_op

smoke_log "teams-shim-roundtrip: ALL TESTS PASS"
exit 0
