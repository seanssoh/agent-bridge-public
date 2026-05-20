#!/usr/bin/env bash
# scripts/smoke/antigravity-engine-acceptance.sh — Antigravity wave Track A0
# (T6 updated by Track C1 — the A0 launch guard it removed is now gone).
#
# Validates that the `antigravity` engine is accepted on every public
# surface A0 owns, that `agy`/`gemini` aliases normalize to the canonical
# `antigravity` value, and that the dynamic spawn parser still recognizes
# the `--agy` flag now that the real C1 launch branch has landed.
#
# Assertions:
# T1: helper-level — bridge_engine_binary_name maps engine VALUE -> binary
#     (antigravity->agy, claude->claude, codex->codex).
# T2: helper-level — bridge_normalize_engine maps agy/gemini/antigravity
#     -> antigravity, claude/codex passthrough, unknown -> non-zero.
# T3: `agent create ... --engine antigravity --dry-run` succeeds through
#     validation + scaffold planning (engine accepted, session_type
#     derives static-antigravity, default launch cmd does not die).
# T4: `agent create ... --engine agy --dry-run` — the alias normalizes;
#     the planned engine is stored as `antigravity`.
# T5: linux-user + antigravity create is refused with a clear message.
# T6: `agent-bridge --agy --name ... --no-attach` parses the flag and
#     proceeds PAST the (C1-removed) A0 launch guard.
# T7: positive control — `agent-bridge --codex` is unaffected (never
#     emitted the antigravity launch guard).

set -euo pipefail

SMOKE_NAME="antigravity-engine-acceptance"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

run_create() {
  bash "$SMOKE_REPO_ROOT/bridge-agent.sh" create "$@" 2>&1 || true
}

run_agent_bridge() {
  bash "$SMOKE_REPO_ROOT/agent-bridge" "$@" 2>&1 || true
}

reset_runtime() {
  rm -rf "$BRIDGE_AGENT_HOME_ROOT"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
}

resolve_bash4() {
  # Mirror the bridge-lib.sh re-exec list: pick a Bash 4+ binary so the
  # associative-array / declare -g constructs in lib/bridge-core.sh work
  # when we source it directly for the helper-level assertions.
  local cand
  for cand in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] || continue
    if "$cand" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

assert_helper_binary_name() {
  local bash4
  if ! bash4="$(resolve_bash4)"; then
    smoke_skip "engine helpers" "no Bash 4+ binary on PATH (lib/bridge-core.sh)"
    return 0
  fi

  local helper_script="$SMOKE_TMP_ROOT/engine-helper-check.sh"
  cat >"$helper_script" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
SMOKE_REPO_ROOT="$1"
# shellcheck source=lib/bridge-core.sh
source "$SMOKE_REPO_ROOT/lib/bridge-core.sh"

# bridge_engine_binary_name: engine VALUE -> on-disk binary.
[[ "$(bridge_engine_binary_name antigravity)" == "agy" ]] \
  || { printf 'FAIL: antigravity should map to agy\n' >&2; exit 1; }
[[ "$(bridge_engine_binary_name claude)" == "claude" ]] \
  || { printf 'FAIL: claude should map to claude\n' >&2; exit 1; }
[[ "$(bridge_engine_binary_name codex)" == "codex" ]] \
  || { printf 'FAIL: codex should map to codex\n' >&2; exit 1; }
# Unknown engine echoes the input unchanged (safe default).
[[ "$(bridge_engine_binary_name mystery)" == "mystery" ]] \
  || { printf 'FAIL: unknown engine should echo input unchanged\n' >&2; exit 1; }

# bridge_normalize_engine: aliases -> canonical antigravity.
for alias in antigravity agy gemini; do
  got="$(bridge_normalize_engine "$alias")" \
    || { printf 'FAIL: normalize %s exited non-zero\n' "$alias" >&2; exit 1; }
  [[ "$got" == "antigravity" ]] \
    || { printf 'FAIL: normalize %s -> %s (want antigravity)\n' "$alias" "$got" >&2; exit 1; }
done
[[ "$(bridge_normalize_engine claude)" == "claude" ]] \
  || { printf 'FAIL: normalize claude should passthrough\n' >&2; exit 1; }
[[ "$(bridge_normalize_engine codex)" == "codex" ]] \
  || { printf 'FAIL: normalize codex should passthrough\n' >&2; exit 1; }
# Unknown engine -> non-zero exit.
if bridge_normalize_engine bogus >/dev/null 2>&1; then
  printf 'FAIL: normalize bogus should exit non-zero\n' >&2
  exit 1
fi

printf 'OK\n'
HELPER

  local out
  out="$("$bash4" "$helper_script" "$SMOKE_REPO_ROOT" 2>&1)" \
    || smoke_fail "engine helpers: $out"
  smoke_assert_contains "$out" "OK" \
    "bridge_engine_binary_name + bridge_normalize_engine canonical"
}

assert_create_antigravity() {
  reset_runtime
  local out
  out="$(run_create agyrole --engine antigravity --dry-run)"
  smoke_assert_contains "$out" "agent: agyrole" \
    "create --engine antigravity --dry-run accepted"
  smoke_assert_contains "$out" "dry_run: yes" \
    "create --engine antigravity --dry-run flags itself as a plan"
  smoke_assert_not_contains "$out" "지원하지 않는 engine" \
    "create --engine antigravity: engine not rejected"
  smoke_assert_not_contains "$out" "지원하지 않는 session type" \
    "create --engine antigravity: session_type static-antigravity accepted"
}

assert_create_agy_alias() {
  reset_runtime
  local out
  out="$(run_create agyrole --engine agy --dry-run)"
  smoke_assert_contains "$out" "agent: agyrole" \
    "create --engine agy (alias) --dry-run accepted"
  smoke_assert_contains "$out" "engine: antigravity" \
    "create --engine agy normalizes the stored engine to antigravity"
}

assert_linux_user_guard() {
  reset_runtime
  local out
  out="$(run_create agyrole --engine antigravity --isolation linux-user --dry-run)"
  smoke_assert_contains "$out" "linux-user isolation" \
    "create antigravity + linux-user refused with a clear message"
}

assert_spawn_past_launch_guard() {
  reset_runtime
  local probe_dir="$SMOKE_TMP_ROOT/agy-probe"
  mkdir -p "$probe_dir"
  local out
  # --no-attach keeps us out of an interactive tmux attach. Track C1
  # removed the temporary bridge-start.sh launch guard and landed the
  # real agy launch branch, so the spawn now parses + proceeds PAST the
  # (removed) guard. This smoke only asserts the guard is gone and the
  # flag still parses — the full launch contract is covered by
  # antigravity-settings-preseed.sh and the C1 launch-builder checks.
  out="$(run_agent_bridge --agy --name agyprobe --workdir "$probe_dir" --no-attach)"
  smoke_assert_not_contains "$out" "C1 트랙 대기" \
    "--agy spawn no longer hits the (removed) A0 launch guard"
  smoke_assert_not_contains "$out" "알 수 없는 옵션" \
    "--agy flag is recognized by the dynamic spawn parser"
}

assert_codex_unaffected() {
  reset_runtime
  local probe_dir="$SMOKE_TMP_ROOT/codex-probe"
  mkdir -p "$probe_dir"
  local out
  out="$(run_agent_bridge --codex --name codexprobe --workdir "$probe_dir" --no-attach)"
  smoke_assert_not_contains "$out" "C1 트랙 대기" \
    "--codex spawn does not hit the antigravity launch guard"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"

  smoke_run "T1/T2: engine helpers"                assert_helper_binary_name
  smoke_run "T3: create --engine antigravity"      assert_create_antigravity
  smoke_run "T4: create --engine agy alias"        assert_create_agy_alias
  smoke_run "T5: linux-user + antigravity guard"   assert_linux_user_guard
  smoke_run "T6: --agy spawn past launch guard"    assert_spawn_past_launch_guard
  smoke_run "T7: --codex unaffected"               assert_codex_unaffected

  smoke_log "PASS"
}

main "$@"
