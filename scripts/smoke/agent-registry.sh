#!/usr/bin/env bash
# scripts/smoke/agent-registry.sh — Issue #598 Track 1 smoke.
#
# Validates the new `agent registry --json` endpoint:
#   T1. Static + dynamic-active-env mix → both rows surface with correct
#       `class` (static vs dynamic) and `source` (static-roster vs
#       dynamic-active-env) tags.
#   T2. system-class agent → `class=system` in the public field while
#       `agent_source` and `privilege_class` preserve the raw signals
#       (system wins over static/dynamic for cleanup callers, but the
#       provenance split stays available).
#   T3. Empty roster → `[]` (well-formed JSON).
#   T4. Stable sort: two consecutive calls produce byte-identical output.
#   T5. Output is parseable by `jq` (well-formed JSON, not just
#       text-shaped JSON).
#
# Uses an isolated BRIDGE_HOME via smoke_setup_bridge_home — never
# touches the operator's live runtime.
#
# Not registered in scripts/smoke-test.sh yet — Track 2's detector smoke
# will register both fixtures once the orphan-agent-dir detector lands.

set -euo pipefail

SMOKE_NAME="agent-registry"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "agent-registry"

REPO_ROOT="$SMOKE_REPO_ROOT"

BASH4_BIN="${BASH:-bash}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# Helper — invoke `agent registry --json` against the isolated
# BRIDGE_HOME. Re-exports every BRIDGE_* the lib injected so the
# subshell sees the same scope.
agent_registry_json() {
  "$BASH4_BIN" "$REPO_ROOT/bridge-agent.sh" registry --json
}

# Helper — assert JSON output parses with jq when jq is available; fall
# back to python json.loads otherwise so the smoke remains portable to
# hosts without jq installed.
assert_valid_json() {
  local payload="$1"
  local context="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -e . >/dev/null 2>&1 \
      || smoke_fail "$context: jq rejected the payload (not valid JSON): $payload"
  else
    "$PY_BIN" -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$payload" \
      || smoke_fail "$context: python json.loads rejected the payload: $payload"
  fi
}

# ---------------------------------------------------------------------------
# Roster fixture writers.
# ---------------------------------------------------------------------------

write_empty_roster() {
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  rm -rf "$BRIDGE_ACTIVE_AGENT_DIR"
  mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"
}

write_static_one() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "alpha"
BRIDGE_AGENT_ENGINE["alpha"]="claude"
BRIDGE_AGENT_SESSION["alpha"]="alpha"
BRIDGE_AGENT_WORKDIR["alpha"]="$BRIDGE_AGENT_HOME_ROOT/alpha"
EOF
  # Clear any dynamic-active-env files left behind by a prior test so
  # tests that expect a static-only roster are not contaminated.
  rm -rf "$BRIDGE_ACTIVE_AGENT_DIR"
  mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"
}

# Dynamic active-env files live under $BRIDGE_ACTIVE_AGENT_DIR/*.env and
# are sourced by bridge_load_dynamic_agents during bridge_load_roster.
write_dynamic_active_env() {
  local agent="$1"
  local engine="$2"
  local file="$BRIDGE_ACTIVE_AGENT_DIR/${agent}.env"
  mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"
  cat >"$file" <<EOF
AGENT_ID="$agent"
AGENT_DESC="dynamic test agent"
AGENT_ENGINE="$engine"
AGENT_SESSION="$agent"
AGENT_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$agent"
AGENT_LOOP=1
AGENT_CONTINUE=1
EOF
}

write_static_with_system() {
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "alpha"
BRIDGE_AGENT_ENGINE["alpha"]="claude"
BRIDGE_AGENT_SESSION["alpha"]="alpha"
BRIDGE_AGENT_WORKDIR["alpha"]="$BRIDGE_AGENT_HOME_ROOT/alpha"

bridge_add_agent_id_if_missing "patrol"
BRIDGE_AGENT_ENGINE["patrol"]="claude"
BRIDGE_AGENT_SESSION["patrol"]="patrol"
BRIDGE_AGENT_WORKDIR["patrol"]="$BRIDGE_AGENT_HOME_ROOT/patrol"
BRIDGE_AGENT_CLASS["patrol"]="system"
EOF
}

# ---------------------------------------------------------------------------
# T1 — static + dynamic mix.
# ---------------------------------------------------------------------------
test_static_plus_dynamic() {
  write_static_one
  write_dynamic_active_env "delta" "codex"

  local out
  out="$(agent_registry_json)"
  assert_valid_json "$out" "T1 valid JSON"

  # Two records, sorted alphabetically (alpha before delta).
  local count
  count="$("$PY_BIN" -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' <<<"$out")"
  smoke_assert_eq "2" "$count" "T1 two records"

  local first_id
  first_id="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d[0]["id"])' <<<"$out")"
  smoke_assert_eq "alpha" "$first_id" "T1 sorted by id (alpha first)"

  # Field-level assertions for the static row.
  local alpha_class alpha_source alpha_provenance alpha_priv
  alpha_class="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="alpha"][0]; print(a["class"])' <<<"$out")"
  alpha_source="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="alpha"][0]; print(a["agent_source"])' <<<"$out")"
  alpha_provenance="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="alpha"][0]; print(a["source"])' <<<"$out")"
  alpha_priv="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="alpha"][0]; print(a["privilege_class"])' <<<"$out")"
  smoke_assert_eq "static" "$alpha_class" "T1 alpha class"
  smoke_assert_eq "static" "$alpha_source" "T1 alpha agent_source"
  smoke_assert_eq "static-roster" "$alpha_provenance" "T1 alpha provenance"
  smoke_assert_eq "user" "$alpha_priv" "T1 alpha privilege_class"

  # Field-level assertions for the dynamic row.
  local delta_class delta_source delta_provenance delta_engine
  delta_class="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="delta"][0]; print(a["class"])' <<<"$out")"
  delta_source="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="delta"][0]; print(a["agent_source"])' <<<"$out")"
  delta_provenance="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="delta"][0]; print(a["source"])' <<<"$out")"
  delta_engine="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="delta"][0]; print(a["engine"])' <<<"$out")"
  smoke_assert_eq "dynamic" "$delta_class" "T1 delta class"
  smoke_assert_eq "dynamic" "$delta_source" "T1 delta agent_source"
  smoke_assert_eq "dynamic-active-env" "$delta_provenance" "T1 delta provenance"
  smoke_assert_eq "codex" "$delta_engine" "T1 delta engine"
}

# ---------------------------------------------------------------------------
# T2 — system-class agent (cleanup-class system wins, raw fields preserved).
# ---------------------------------------------------------------------------
test_system_class_precedence() {
  write_static_with_system
  rm -rf "$BRIDGE_ACTIVE_AGENT_DIR"
  mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"

  local out
  out="$(agent_registry_json)"
  assert_valid_json "$out" "T2 valid JSON"

  local patrol_class patrol_source patrol_priv
  patrol_class="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="patrol"][0]; print(a["class"])' <<<"$out")"
  patrol_source="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="patrol"][0]; print(a["agent_source"])' <<<"$out")"
  patrol_priv="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); a=[r for r in d if r["id"]=="patrol"][0]; print(a["privilege_class"])' <<<"$out")"
  smoke_assert_eq "system" "$patrol_class" "T2 system wins over static in cleanup class"
  smoke_assert_eq "static" "$patrol_source" "T2 raw agent_source preserved"
  smoke_assert_eq "system" "$patrol_priv" "T2 raw privilege_class preserved"
}

# ---------------------------------------------------------------------------
# T3 — empty roster → `[]`.
# ---------------------------------------------------------------------------
test_empty_roster() {
  write_empty_roster

  local out
  out="$(agent_registry_json)"
  assert_valid_json "$out" "T3 valid JSON"

  local count
  count="$("$PY_BIN" -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' <<<"$out")"
  smoke_assert_eq "0" "$count" "T3 empty roster yields zero records"
}

# ---------------------------------------------------------------------------
# T4 — stable sort across calls.
# ---------------------------------------------------------------------------
test_stable_sort() {
  write_static_one
  write_dynamic_active_env "delta" "codex"
  write_dynamic_active_env "bravo" "claude"
  write_dynamic_active_env "charlie" "claude"

  local first second
  first="$(agent_registry_json)"
  second="$(agent_registry_json)"
  if [[ "$first" != "$second" ]]; then
    smoke_fail "T4 two consecutive calls produced different output"
  fi

  # Also confirm the order is alphabetical: alpha, bravo, charlie, delta.
  local ids
  ids="$("$PY_BIN" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(",".join(r["id"] for r in d))' <<<"$first")"
  smoke_assert_eq "alpha,bravo,charlie,delta" "$ids" "T4 ids sorted alphabetically"
}

# ---------------------------------------------------------------------------
# T5 — output is well-formed JSON parseable by jq.
# T1/T2/T3/T4 already call assert_valid_json on every payload, but T5
# adds an explicit jq-only check (skipped when jq is absent) so the
# fixture documents the contract distinctly.
# ---------------------------------------------------------------------------
test_jq_parseable() {
  write_static_one

  local out
  out="$(agent_registry_json)"

  if command -v jq >/dev/null 2>&1; then
    local jq_count
    jq_count="$(printf '%s' "$out" | jq 'length')"
    smoke_assert_eq "1" "$jq_count" "T5 jq length matches expected"
    local jq_id
    jq_id="$(printf '%s' "$out" | jq -r '.[0].id')"
    smoke_assert_eq "alpha" "$jq_id" "T5 jq selects expected id"
  else
    smoke_skip "T5 jq parse" "jq not installed on host"
  fi
}

smoke_run "T1 static + dynamic mix"           test_static_plus_dynamic
smoke_run "T2 system-class precedence"        test_system_class_precedence
smoke_run "T3 empty roster"                   test_empty_roster
smoke_run "T4 stable sort"                    test_stable_sort
smoke_run "T5 jq parseable"                   test_jq_parseable

smoke_log "all checks passed"
