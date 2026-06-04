#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/plugin-requires-resolver.sh — generic plugin `requires`
# resolver on the agent-create channel-expansion path (patch cm-prod Part 1).
#
# Re-exec under bash 4+ so we can `source bridge-lib.sh` directly and exercise
# `bridge_expand_channel_requires` (+ its leaf helpers) at the function level
# (matches scripts/smoke/G-channel-spec-resolution.sh).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:plugin-requires-resolver][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# What this pins
# --------------
# A plugin manifest (`.claude-plugin/plugin.json`) may declare an optional
# top-level `"requires"` array of channel specs it depends on. On `agent
# create --channels`, the create path calls `bridge_expand_channel_requires`
# (lib/bridge-agents.sh) which transitively pulls each plugin's declared
# `requires` into the resolved channel CSV. The mechanism is fully generic —
# core reads only whatever specs the manifest declares; there is ZERO domain
# hardcoding in lib/bridge-agents.sh or bridge-agent.sh.
#
# Self-contained fixture
# ----------------------
# The smoke builds a temp `$HOME/.claude/plugins` with `installed_plugins.json`
# + `known_marketplaces.json` so `bridge_resolve_plugin_install_path` resolves
# fixture plugins under a temp `fixture-mkt` directory marketplace. The leaf
# `requires` targets reuse the in-repo `plugin:teams@agent-bridge` +
# `plugin:ms365@agent-bridge` (resolved via $BRIDGE_SCRIPT_DIR/plugins/*), which
# the repo always ships — so the fixture needs no out-of-repo marketplace.
#
# Test plan
# ---------
#   T1.  EXPAND: a fixture plugin `fake-crm` that requires teams + ms365 →
#        resolved CSV includes both required channels, and a single
#        `[info] <fake-crm> requires <teams>, <ms365> — adding` line fires.
#   T2.  DEDUPE: explicitly list teams AND fake-crm (which requires teams) →
#        teams appears exactly once; no false cycle error.
#   T3.  NO-REQUIRES backward-compat: a channel set of plugins with no
#        `requires` (teams,ms365) → byte-identical output, zero stderr.
#   T4.  CYCLE (required-rooted): entry→cyc-a→cyc-b→cyc-a → clear `[error]
#        ... dependency cycle detected ...`, terminates (no hang).
#   T5.  CYCLE (seed-rooted): cyc-a→cyc-b→cyc-a with cyc-a as the seed →
#        terminates cleanly (no hang); the seed being depended-on is
#        legitimate, so no false error but the set is bounded.
#   T6.  DEPTH-CAP: a requires chain longer than the cap (default 8) → clear
#        `[error] ... depth cap ... exceeded`, terminates (no hang).
#   T7.  UNRESOLVABLE: a requires pointing at a non-installed plugin →
#        `bridge_warn` + PROCEED with the un-expanded set (create not blocked).
#   T8.  LEAF helper: `bridge_plugin_requires_specs_for_item` prints the
#        manifest's requires one per line, qualified.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout) + temp
# $HOME. The smoke only sources bridge-lib.sh and calls pure functions against
# the fixture — no roster persistence, no operator-side state read/write.

set -euo pipefail

SMOKE_NAME="plugin-requires-resolver"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "plugin-requires-resolver"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Isolated $HOME so the fixture's `.claude/plugins` is the only plugins root
# consulted for non-agent-bridge marketplaces (the in-repo teams/ms365 plugins
# resolve via $BRIDGE_SCRIPT_DIR/plugins/* regardless of $HOME).
FIXTURE_HOME="$SMOKE_TMP_ROOT/fixture-home"
FIXTURE_MKT="$SMOKE_TMP_ROOT/fixture-mkt"
PLUGINS_ROOT="$FIXTURE_HOME/.claude/plugins"
mkdir -p "$PLUGINS_ROOT" "$FIXTURE_MKT/plugins"
export HOME="$FIXTURE_HOME"

# --- fixture builders -----------------------------------------------------

# write_fixture_plugin <name> [<requires-csv>]
# Creates fixture-mkt/plugins/<name>/.claude-plugin/plugin.json and registers
# it in installed_plugins.json. <requires-csv> is a comma-separated list of
# channel specs (empty/omitted = no `requires` key).
INSTALLED_JSON="$PLUGINS_ROOT/installed_plugins.json"
KNOWN_MKT_JSON="$PLUGINS_ROOT/known_marketplaces.json"

write_fixture_plugin() {
  local name="$1"
  local requires_csv="${2:-}"
  local dir="$FIXTURE_MKT/plugins/$name"
  mkdir -p "$dir/.claude-plugin"
  if [[ -n "$requires_csv" ]]; then
    python3 - "$dir/.claude-plugin/plugin.json" "$name" "$requires_csv" <<'PY'
import json, sys
out_path, name, requires_csv = sys.argv[1], sys.argv[2], sys.argv[3]
requires = [s.strip() for s in requires_csv.split(",") if s.strip()]
with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"name": name, "version": "0.0.1", "requires": requires}, f, indent=2)
PY
  else
    python3 - "$dir/.claude-plugin/plugin.json" "$name" <<'PY'
import json, sys
out_path, name = sys.argv[1], sys.argv[2]
with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"name": name, "version": "0.0.1"}, f, indent=2)
PY
  fi
  # Register install path.
  python3 - "$INSTALLED_JSON" "$name@fixture-mkt" "$dir" <<'PY'
import json, os, sys
path, key, install = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"plugins": {}}
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
data.setdefault("plugins", {})[key] = [{"installPath": install}]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
}

build_fixtures() {
  # Directory-source marketplace so bridge_resolve_plugin_install_path's
  # known_marketplaces fallback would also resolve (installed_plugins.json's
  # installPath is consulted first and suffices here).
  python3 - "$KNOWN_MKT_JSON" "$FIXTURE_MKT" <<'PY'
import json, sys
path, mkt_path = sys.argv[1], sys.argv[2]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"fixture-mkt": {"source": {"source": "directory", "path": mkt_path}}}, f, indent=2)
PY

  : >"$INSTALLED_JSON"  # truncate; write_fixture_plugin appends
  printf '{"plugins":{}}\n' >"$INSTALLED_JSON"

  # T1/T2/T8: a plugin that requires the in-repo teams + ms365 channels.
  write_fixture_plugin "fake-crm" "plugin:teams@agent-bridge,plugin:ms365@agent-bridge"

  # T4: required-rooted cycle entry -> cyc-a -> cyc-b -> cyc-a.
  write_fixture_plugin "entry" "plugin:cyc-a@fixture-mkt"
  write_fixture_plugin "cyc-a" "plugin:cyc-b@fixture-mkt"
  write_fixture_plugin "cyc-b" "plugin:cyc-a@fixture-mkt"

  # T6: depth chain d0 -> d1 -> ... -> d10 (> default cap 8).
  local i nxt
  for i in $(seq 0 10); do
    nxt=$((i + 1))
    if [[ $i -lt 10 ]]; then
      write_fixture_plugin "d$i" "plugin:d$nxt@fixture-mkt"
    else
      write_fixture_plugin "d$i" ""
    fi
  done

  # T7: a plugin whose requires points at a non-installed plugin.
  write_fixture_plugin "needs-missing" "plugin:not-installed@nowhere-mkt"
}

# --- sanity: helpers defined + repo plugins present -----------------------

assert_environment() {
  declare -F bridge_expand_channel_requires >/dev/null \
    || smoke_fail "bridge_expand_channel_requires not defined after sourcing bridge-lib.sh"
  declare -F bridge_plugin_requires_specs_for_item >/dev/null \
    || smoke_fail "bridge_plugin_requires_specs_for_item not defined"
  declare -F bridge_plugin_item_is_resolvable >/dev/null \
    || smoke_fail "bridge_plugin_item_is_resolvable not defined"
  [[ -f "$BRIDGE_SCRIPT_DIR/plugins/teams/.claude-plugin/plugin.json" ]] \
    || smoke_fail "in-repo teams plugin manifest missing (fixture leaf target)"
  [[ -f "$BRIDGE_SCRIPT_DIR/plugins/ms365/.claude-plugin/plugin.json" ]] \
    || smoke_fail "in-repo ms365 plugin manifest missing (fixture leaf target)"
  # Guard: the in-repo leaf manifests must stay requires-free (the brief keeps
  # them backward-compatible; the real cosmax requires lives out of this repo).
  local teams_req ms365_req
  teams_req="$(python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/plugin-manifest-requires.py" \
    "$BRIDGE_SCRIPT_DIR/plugins/teams/.claude-plugin/plugin.json")"
  smoke_assert_eq "" "$teams_req" "in-repo teams manifest stays requires-free"
  ms365_req="$(python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/plugin-manifest-requires.py" \
    "$BRIDGE_SCRIPT_DIR/plugins/ms365/.claude-plugin/plugin.json")"
  smoke_assert_eq "" "$ms365_req" "in-repo ms365 manifest stays requires-free"
}

# --- helper: run the resolver capturing stdout + stderr separately --------

EXPAND_OUT=""
EXPAND_ERR=""
run_expand() {
  local input="$1"
  local err_file
  err_file="$(mktemp "${TMPDIR:-/tmp}/agb-requires-err.XXXXXX")"
  EXPAND_OUT="$(bridge_expand_channel_requires "$input" 2>"$err_file")"
  EXPAND_ERR="$(cat "$err_file")"
  rm -f "$err_file"
}

# --- T1: transitive expand + [info] line ----------------------------------

test_expand_adds_requires() {
  run_expand "plugin:fake-crm@fixture-mkt"
  smoke_assert_contains "$EXPAND_OUT" "plugin:fake-crm@fixture-mkt" \
    "T1 original channel preserved"
  smoke_assert_contains "$EXPAND_OUT" "plugin:teams@agent-bridge" \
    "T1 required teams pulled in"
  smoke_assert_contains "$EXPAND_OUT" "plugin:ms365@agent-bridge" \
    "T1 required ms365 pulled in"
  smoke_assert_contains "$EXPAND_ERR" "[info] plugin:fake-crm@fixture-mkt requires" \
    "T1 [info] expansion line emitted to stderr"
  smoke_assert_contains "$EXPAND_ERR" "— adding" \
    "T1 [info] line ends with the adding marker"
}

# --- T2: dedupe (explicit + requires) -------------------------------------

test_dedupe_explicit_and_requires() {
  run_expand "plugin:teams@agent-bridge,plugin:fake-crm@fixture-mkt"
  # teams must appear exactly once.
  local count
  count="$(printf '%s' "$EXPAND_OUT" | tr ',' '\n' | grep -c '^plugin:teams@agent-bridge$' || true)"
  smoke_assert_eq "1" "$count" "T2 explicitly-listed teams that is also a requires appears once"
  smoke_assert_contains "$EXPAND_OUT" "plugin:ms365@agent-bridge" \
    "T2 ms365 still pulled in via fake-crm requires"
  smoke_assert_not_contains "$EXPAND_ERR" "cycle detected" \
    "T2 a requires on an explicitly-listed channel is NOT a false cycle"
}

# --- T3: no-requires backward compatibility -------------------------------

test_no_requires_byte_identical() {
  local input="plugin:teams@agent-bridge,plugin:ms365@agent-bridge"
  run_expand "$input"
  smoke_assert_eq "$input" "$EXPAND_OUT" \
    "T3 no-requires channel set returns byte-identical output"
  smoke_assert_eq "" "$EXPAND_ERR" \
    "T3 no-requires path emits zero diagnostics"
}

# --- T4: required-rooted cycle -> clear error, terminates -----------------

test_cycle_required_rooted_errors() {
  run_expand "plugin:entry@fixture-mkt"
  smoke_assert_contains "$EXPAND_ERR" "dependency cycle detected" \
    "T4 required-rooted cycle surfaces a clear [error]"
  # Termination is proven by the fact run_expand returned; assert the set is
  # bounded (entry + cyc-a + cyc-b, each once).
  smoke_assert_contains "$EXPAND_OUT" "plugin:cyc-a@fixture-mkt" "T4 cyc-a in set"
  smoke_assert_contains "$EXPAND_OUT" "plugin:cyc-b@fixture-mkt" "T4 cyc-b in set"
  local count_a
  count_a="$(printf '%s' "$EXPAND_OUT" | tr ',' '\n' | grep -c '^plugin:cyc-a@fixture-mkt$' || true)"
  smoke_assert_eq "1" "$count_a" "T4 cyc-a appears exactly once (no duplicate from the back-edge)"
}

# --- T5: seed-rooted cycle -> terminates (no hang) ------------------------

test_cycle_seed_rooted_terminates() {
  run_expand "plugin:cyc-a@fixture-mkt"
  # The seed being depended-on is legitimate (not a false error); the only
  # hard requirement is termination + a bounded set.
  smoke_assert_contains "$EXPAND_OUT" "plugin:cyc-a@fixture-mkt" "T5 seed preserved"
  smoke_assert_contains "$EXPAND_OUT" "plugin:cyc-b@fixture-mkt" "T5 cyc-b pulled in once"
  local count_b
  count_b="$(printf '%s' "$EXPAND_OUT" | tr ',' '\n' | grep -c '^plugin:cyc-b@fixture-mkt$' || true)"
  smoke_assert_eq "1" "$count_b" "T5 cyc-b appears exactly once (cycle bounded, no hang)"
}

# --- T6: depth cap -> clear error, terminates -----------------------------

test_depth_cap_errors() {
  run_expand "plugin:d0@fixture-mkt"
  smoke_assert_contains "$EXPAND_ERR" "depth cap" \
    "T6 chain longer than the cap surfaces a clear [error] depth-cap line"
  # d0..d8 added before the cap (depth 0..7 expand 8 edges); d9/d10 not reached.
  smoke_assert_contains "$EXPAND_OUT" "plugin:d8@fixture-mkt" "T6 expansion reached d8 before the cap"
  smoke_assert_not_contains "$EXPAND_OUT" "plugin:d10@fixture-mkt" \
    "T6 expansion stopped before d10 (cap held, no runaway)"
}

# --- T7: unresolvable requires -> warn + proceed --------------------------

test_unresolvable_warn_and_proceed() {
  run_expand "plugin:needs-missing@fixture-mkt"
  # The needs-missing plugin itself IS resolvable, so its requires line fires.
  smoke_assert_contains "$EXPAND_OUT" "plugin:needs-missing@fixture-mkt" \
    "T7 the requesting plugin stays in the set"
  smoke_assert_contains "$EXPAND_OUT" "plugin:not-installed@nowhere-mkt" \
    "T7 the (unexpandable) requires spec is still appended — create not blocked"
  smoke_assert_contains "$EXPAND_ERR" "could not be resolved locally" \
    "T7 unresolvable dependency warns (warn-and-continue, not a hard fail)"
}

# --- T8: leaf helper prints qualified requires one per line ---------------

test_leaf_helper_lists_requires() {
  local out
  out="$(bridge_plugin_requires_specs_for_item "plugin:fake-crm@fixture-mkt")"
  smoke_assert_contains "$out" "plugin:teams@agent-bridge" \
    "T8 leaf helper lists teams requires"
  smoke_assert_contains "$out" "plugin:ms365@agent-bridge" \
    "T8 leaf helper lists ms365 requires"
  # A no-requires plugin yields empty.
  local empty
  empty="$(bridge_plugin_requires_specs_for_item "plugin:teams@agent-bridge")"
  smoke_assert_eq "" "$empty" "T8 in-repo teams plugin (no requires) yields empty"
}

main() {
  # shellcheck source=bridge-lib.sh disable=SC1091
  source "$REPO_ROOT/bridge-lib.sh"
  assert_environment
  build_fixtures

  smoke_run "T1 transitive expand + [info] line" test_expand_adds_requires
  smoke_run "T2 dedupe explicit + requires"      test_dedupe_explicit_and_requires
  smoke_run "T3 no-requires byte-identical"      test_no_requires_byte_identical
  smoke_run "T4 cycle (required-rooted) errors"  test_cycle_required_rooted_errors
  smoke_run "T5 cycle (seed-rooted) terminates"  test_cycle_seed_rooted_terminates
  smoke_run "T6 depth cap errors"                test_depth_cap_errors
  smoke_run "T7 unresolvable warn + proceed"     test_unresolvable_warn_and_proceed
  smoke_run "T8 leaf helper lists requires"      test_leaf_helper_lists_requires
  smoke_log "passed"
}

main "$@"
