#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1191-agent-start-node-version-gate.sh — Issue #1191.
#
# Re-exec under bash 4+ so the lib helpers (which rely on associative
# arrays / `declare -F` semantics that match the live start path) run on
# the same shell layer as bridge-start.sh. macOS ships bash 3.2.
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1191-agent-start-node-version-gate][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Pins the per-`agent start` Node.js version gate (fix shape (b) from the
# issue): when a to-be-loaded bundled plugin declares `engines.node` and
# the host node is missing or older than the declared minimum major, the
# start path emits a NON-FATAL warning naming the offending plugin.
# Instead of the confusing downstream SyntaxError-in-logs the plugin MCP
# spawn produces on a stock-Ubuntu Node 12 host.
#
# The gate is the factored helper `bridge_warn_plugins_node_engines` in
# lib/bridge-channels.sh (backed by the engines.node parse in
# scripts/python-helpers/plugin-engines-node-min-major.py). None of the
# IN-TREE bundled plugins declare engines.node today (the issue's
# canonical case, cosmax-ep-approval, is an EXTERNAL marketplace plugin),
# so this smoke builds a fixture "script dir" with its own plugins/ tree
# and shims `node` on PATH to control the reported host version.
#
# Test plan:
#   T0 (parser): the engines.node min-major parser derives the right
#      floor for >=14, ^18||^20, ~16, 18.x, ">= 16 < 21" (=> 16, NOT 21),
#      "14 - 18" (=> 14), and declares NO floor (exit 1) for "*", "x",
#      upper-bound-only "<21", and garbage — the false-positive classes a
#      codex review flagged. Under-warning is safe; a false warn is not.
#   T1 (warn fires, old node): a plugin declaring engines.node ">=18"
#      with host node shimmed to v12 emits a "requires node >= 18" warn.
#   T2 (non-fatal): the gate returns 0 even when it warns (start would
#      proceed) — proven by asserting the caller sees rc=0.
#   T3 (silent, current node): the SAME plugin with host node shimmed to
#      v20 emits NO node-check warning.
#   T4 (silent, no engines.node): a plugin with NO engines.node emits no
#      warning even on old node (nothing to gate on).
#   T5 (missing node): engines.node ">=18" with `node` absent from PATH
#      emits the "node is not on PATH" variant, still rc=0.
#   T6 (mutation proof): running the gate over the T1 fixture but with a
#      DELETED engines.node field produces NO warn — proving the warn in
#      T1 is caused by the requirement, not an unconditional print.
#   T7 (end-to-end wiring): (a) the gate call site exists in
#      bridge-start.sh, and (b) a real `bridge-start.sh <role> --dry-run`
#      for a role declaring a REAL bundled plugin channel (no
#      engines.node) completes rc=0 and stays silent even on a shimmed
#      old node — proving non-fatal wiring with no false positive. The
#      decisive FIRING path is proven at the function level (T1/T5/T6).
#
# Footgun #11 (heredoc_write deadlock class): fixture writes use plain
# `cat >file <<EOF` bodies and `printf` — no command substitution feeding
# a heredoc-stdin into a bridge function.

set -uo pipefail

SMOKE_NAME="1191-agent-start-node-version-gate"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
GATE_HELPER="$REPO_ROOT/scripts/python-helpers/plugin-engines-node-min-major.py"
[[ -f "$GATE_HELPER" ]] || smoke_fail "missing helper: $GATE_HELPER"

# --- Build a fixture "script dir" whose plugins/ tree we control -------
# The gate resolves plugins against $BRIDGE_SCRIPT_DIR/plugins and the
# parser against $BRIDGE_SCRIPT_DIR/scripts/python-helpers/. Symlink the
# real scripts/ so the parser is the shipped one; give the fixture its
# own plugins/ so we can declare engines.node.
FIXROOT="$SMOKE_TMP_ROOT/scriptdir"
mkdir -p "$FIXROOT/scripts" "$FIXROOT/plugins"
ln -s "$REPO_ROOT/scripts/python-helpers" "$FIXROOT/scripts/python-helpers"

make_plugin() {
  # $1 = plugin name, $2 = engines.node value ("" => omit engines)
  local name="$1" engines="$2"
  local dir="$FIXROOT/plugins/$name"
  mkdir -p "$dir"
  if [[ -n "$engines" ]]; then
    cat >"$dir/package.json" <<EOF
{
  "name": "$name",
  "version": "1.0.0",
  "engines": { "node": "$engines" }
}
EOF
  else
    cat >"$dir/package.json" <<EOF
{
  "name": "$name",
  "version": "1.0.0"
}
EOF
  fi
}

make_plugin "needs18" ">=18"
make_plugin "noengines" ""

# --- T0: engines.node semver parser (min-major) ------------------------
# Locks the parser contract directly, including the two false-positive
# classes a codex review flagged: wildcard ranges must declare NO floor
# (exit 1, never warn) and a whitespace-separated upper bound must not be
# read as the minimum (">= 16 < 21" -> 16, not 21). Under-warning is
# acceptable; a FALSE warn on a fine host is the failure mode we guard.
test_parser_min_major() {
  local pj="$SMOKE_TMP_ROOT/parser-probe.json"
  # $1 = engines.node spec, $2 = expected stdout, $3 = expected rc, $4 = label
  _check_parser() {
    local spec="$1" exp_out="$2" exp_rc="$3" label="$4"
    printf '{"name":"p","engines":{"node":"%s"}}\n' "$spec" >"$pj"
    local out rc
    set +e
    out="$(python3 "$GATE_HELPER" "$pj" 2>/dev/null)"
    rc=$?
    set -e
    smoke_assert_eq "$exp_out" "$out" "T0 [$label] out for engines.node='$spec'"
    smoke_assert_eq "$exp_rc" "$rc" "T0 [$label] rc for engines.node='$spec'"
  }
  _check_parser ">=14"       "14" "0" "gte-14"
  _check_parser ">=18.0.0"   "18" "0" "gte-18-patch"
  _check_parser "^18 || ^20" "18" "0" "caret-alt-min"
  _check_parser "~16"        "16" "0" "tilde-16"
  _check_parser "18.x"       "18" "0" "x-minor"
  _check_parser ">= 16 < 21" "16" "0" "codex-separated-upper-bound"
  _check_parser "14 - 18"    "14" "0" "hyphen-range"
  _check_parser "*"          ""   "1" "codex-wildcard-star-no-floor"
  _check_parser "x"          ""   "1" "wildcard-x-no-floor"
  _check_parser "<21"        ""   "1" "upper-bound-only-no-floor"
  _check_parser "latest"     ""   "1" "garbage-no-floor"
  # Missing engines.node entirely -> exit 1.
  printf '{"name":"p"}\n' >"$pj"
  local out2 rc2
  set +e
  out2="$(python3 "$GATE_HELPER" "$pj" 2>/dev/null)"; rc2=$?
  set -e
  smoke_assert_eq "" "$out2" "T0 [no-engines] empty out"
  smoke_assert_eq "1" "$rc2" "T0 [no-engines] rc=1"
}

# --- node shim: a fake `node` that prints a chosen version -------------
SHIMBIN="$SMOKE_TMP_ROOT/shimbin"
mkdir -p "$SHIMBIN"
write_node_shim() {
  # $1 = version string node --version should print, e.g. "v12.22.9"
  cat >"$SHIMBIN/node" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  printf '%s\n' "$1"
  exit 0
fi
exit 0
EOF
  chmod +x "$SHIMBIN/node"
}

# Run the gate in an isolated bash subshell with a controlled PATH and a
# fixture BRIDGE_SCRIPT_DIR, capturing stderr (where bridge_warn writes).
#
# We source lib/bridge-channels.sh DIRECTLY (which idempotently pulls in
# bridge-core.sh for bridge_warn / bridge_resolve_script_dir_check),
# rather than the top-level bridge-lib.sh. bridge-lib.sh unconditionally
# recomputes BRIDGE_SCRIPT_DIR from its own BASH_SOURCE (repo root),
# which would clobber the fixture override — the direct-source path is a
# supported entry (see the header of lib/bridge-channels.sh) and is the
# same set of functions the live start path calls. Echoes the function's
# rc on the LAST stdout line as GATE_RC=<n>.
run_gate() {
  # $1 = PATH to use, $2 = required-plugins CSV
  local path_val="$1" csv="$2"
  BRIDGE_SCRIPT_DIR="$FIXROOT" PATH="$path_val" \
    "${BRIDGE_BASH_BIN:-bash}" -c '
      set -uo pipefail
      # shellcheck source=/dev/null
      source "'"$REPO_ROOT"'/lib/bridge-channels.sh" >/dev/null 2>&1 || {
        echo "GATE_RC=127"; exit 0;
      }
      bridge_warn_plugins_node_engines "'"$csv"'"
      echo "GATE_RC=$?"
    '
}

# --- T1: warn fires on old node for a >=18 plugin ----------------------
test_warn_fires_old_node() {
  write_node_shim "v12.22.9"
  local out
  out="$(run_gate "$SHIMBIN:$PATH" "needs18" 2>&1)"
  smoke_assert_contains "$out" "[start][node-check]" \
    "T1 old-node run emits a node-check line"
  smoke_assert_contains "$out" "plugin 'needs18' requires node >= 18" \
    "T1 warn names the offending plugin + required major"
  smoke_assert_contains "$out" "non-fatal" \
    "T1 warn states it is non-fatal"
  smoke_assert_contains "$out" "GATE_RC=0" \
    "T2 gate returns rc=0 even when it warns (start not blocked)"
}

# --- T3: silent on a current node --------------------------------------
test_silent_current_node() {
  write_node_shim "v20.11.1"
  local out
  out="$(run_gate "$SHIMBIN:$PATH" "needs18" 2>&1)"
  smoke_assert_not_contains "$out" "node-check" \
    "T3 no node-check warning when host node (v20) satisfies >=18"
  smoke_assert_contains "$out" "GATE_RC=0" \
    "T3 gate returns rc=0"
}

# --- T4: silent when plugin declares no engines.node -------------------
test_silent_no_engines() {
  write_node_shim "v12.22.9"
  local out
  out="$(run_gate "$SHIMBIN:$PATH" "noengines" 2>&1)"
  smoke_assert_not_contains "$out" "node-check" \
    "T4 no warning when the plugin declares no engines.node (even on old node)"
  smoke_assert_contains "$out" "GATE_RC=0" \
    "T4 gate returns rc=0"
}

# --- T5: node absent from PATH, plugin needs it ------------------------
test_warn_node_missing() {
  # A PATH that contains neither the shim nor a system node. Point at an
  # empty dir plus python3's dir (python3 is needed by the parser).
  local py_dir empty_dir
  py_dir="$(dirname "$(command -v python3)")"
  empty_dir="$SMOKE_TMP_ROOT/emptybin"
  mkdir -p "$empty_dir"
  # Guard: if a `node` still resolves on this minimal PATH, the host has
  # node in the same dir as python3 — skip rather than assert falsely.
  if PATH="$empty_dir:$py_dir" command -v node >/dev/null 2>&1; then
    smoke_skip "T5" "node co-located with python3 on this host; cannot isolate a node-absent PATH"
    return 0
  fi
  local out
  out="$(run_gate "$empty_dir:$py_dir" "needs18" 2>&1)"
  smoke_assert_contains "$out" "node is not on PATH" \
    "T5 warns that node is missing when a plugin needs it"
  smoke_assert_contains "$out" "needs18 (>= 18)" \
    "T5 missing-node warn names the offending plugin + required major"
  smoke_assert_contains "$out" "GATE_RC=0" \
    "T5 gate returns rc=0 when node is absent"
}

# --- T6: mutation proof — remove engines.node, warn must disappear -----
test_mutation_proof() {
  write_node_shim "v12.22.9"
  # Baseline: T1 fixture warns.
  local before
  before="$(run_gate "$SHIMBIN:$PATH" "needs18" 2>&1)"
  smoke_assert_contains "$before" "requires node >= 18" \
    "T6 baseline: engines.node fixture warns on old node"
  # Mutate: strip engines from the SAME plugin dir.
  make_plugin "needs18" ""
  local after
  after="$(run_gate "$SHIMBIN:$PATH" "needs18" 2>&1)"
  smoke_assert_not_contains "$after" "node-check" \
    "T6 mutation: warn disappears once engines.node is removed (warn is requirement-driven, not unconditional)"
  # Restore for any later reuse.
  make_plugin "needs18" ">=18"
}

# --- T7: end-to-end wiring on the REAL start path ----------------------
# Prove the gate is (a) wired into bridge-start.sh and (b) reachable on a
# real `--dry-run` without blocking.
#
# bridge-start.sh sources bridge-lib.sh, which unconditionally recomputes
# BRIDGE_SCRIPT_DIR from its own location (the real repo root) — so a
# fixture plugins/ tree cannot be injected via env for the full script.
# The decisive FIRING behavior is proven at the function level by
# T1/T5/T6 (the exact function the wiring calls). Here we prove the two
# things the function-level tests cannot:
#   T7a. The call site exists in bridge-start.sh (guards against a silent
#        removal of the hook).
#   T7b. A real dry-run for a role declaring a REAL bundled plugin
#        channel (one that has package.json but NO engines.node, e.g.
#        discord) completes rc=0 and emits NO node-check warn even on a
#        shimmed-old node — proving the gate is non-fatal AND does not
#        false-positive on plugins that declare no requirement.
test_end_to_end_wiring() {
  # T7a — static wiring assertion.
  local start_src
  start_src="$(cat "$REPO_ROOT/bridge-start.sh")"
  smoke_assert_contains "$start_src" "bridge_warn_plugins_node_engines" \
    "T7a bridge-start.sh wires the node-version gate into the start path"

  # T7b — real dry-run over a real bundled plugin with no engines.node.
  # Pick the first in-tree plugin that has a package.json (discord/ms365/
  # mattermost/teams today), so this test tracks the shipped plugin set.
  local real_plugin=""
  local d
  for d in "$REPO_ROOT"/plugins/*/; do
    d="${d%/}"
    if [[ -f "$d/package.json" ]]; then
      real_plugin="$(basename -- "$d")"
      break
    fi
  done
  if [[ -z "$real_plugin" ]]; then
    smoke_skip "T7b" "no in-tree bundled plugin with package.json to exercise"
    return 0
  fi

  write_node_shim "v12.22.9"
  # A fake `claude` binary so bridge-start.sh's engine resolver succeeds
  # (host-independent). Co-locate it with the node shim so both resolve.
  local fake_claude="$SHIMBIN/claude"
  printf '#!/usr/bin/env bash\necho "fake-claude $*"\n' >"$fake_claude"
  chmod +x "$fake_claude"

  local role="node-gate-role"
  local workdir="$SMOKE_TMP_ROOT/$role-workdir"
  mkdir -p "$workdir"
  # Self-contained roster (overwrite, not append) with the shebang +
  # bridge_add_agent_id_if_missing idiom the start path resolves against
  # (matches scripts/smoke/1118-v2-engine-binary-path.sh).
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# shellcheck shell=bash disable=SC2034' \
    "bridge_add_agent_id_if_missing \"$role\"" \
    "BRIDGE_AGENT_DESC[\"$role\"]=\"#1191 node-gate smoke fixture\"" \
    "BRIDGE_AGENT_ENGINE[\"$role\"]=\"claude\"" \
    "BRIDGE_AGENT_SESSION[\"$role\"]=\"$role\"" \
    "BRIDGE_AGENT_WORKDIR[\"$role\"]=\"$workdir\"" \
    "BRIDGE_AGENT_LOOP[\"$role\"]=\"1\"" \
    "BRIDGE_AGENT_CONTINUE[\"$role\"]=\"0\"" \
    "BRIDGE_AGENT_CHANNELS[\"$role\"]=\"plugin:${real_plugin}@agent-bridge\"" \
    "BRIDGE_AGENT_LAUNCH_CMD[\"$role\"]=\"claude --name $role\"" \
    >"$BRIDGE_ROSTER_FILE"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"

  local out rc
  set +e
  out="$(PATH="$SHIMBIN:$PATH" \
    "${BRIDGE_BASH_BIN:-bash}" "$REPO_ROOT/bridge-start.sh" "$role" --dry-run 2>&1)"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    smoke_log "T7b dry-run output:"
    printf '%s\n' "$out" | sed 's/^/  /' >&2
  fi
  smoke_assert_eq "0" "$rc" \
    "T7b bridge-start.sh --dry-run exits 0 (node gate did not block start)"
  smoke_assert_not_contains "$out" "node-check" \
    "T7b real bundled plugin '$real_plugin' declares no engines.node — gate stays silent (no false positive) even on shimmed-old node"
}

if [[ "${BRIDGE_SMOKE_1191_E2E:-1}" == "1" ]]; then
  E2E_ENABLED=1
else
  E2E_ENABLED=0
fi

smoke_run "T0 engines.node min-major parser" test_parser_min_major
smoke_run "T1/T2 warn fires + non-fatal on old node" test_warn_fires_old_node
smoke_run "T3 silent on current node" test_silent_current_node
smoke_run "T4 silent when no engines.node" test_silent_no_engines
smoke_run "T5 warn when node missing" test_warn_node_missing
smoke_run "T6 mutation proof" test_mutation_proof
if (( E2E_ENABLED == 1 )); then
  smoke_run "T7 end-to-end wiring on real start path" test_end_to_end_wiring
else
  smoke_skip "T7" "BRIDGE_SMOKE_1191_E2E=0"
fi

smoke_log "PASS"
