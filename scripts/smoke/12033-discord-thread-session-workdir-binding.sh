#!/usr/bin/env bash
# scripts/smoke/12033-discord-thread-session-workdir-binding.sh
#
# Task #12033 (vendored bridge-official Discord plugin, generalized
# thread-session) — finding 2: the thread sub-session MUST bind to the
# channel-OWNING agent's workspace, not to the plugin dir.
#
# The Discord plugin server (plugins/discord/server.ts) spawns
# thread_session_dispatcher.py for every message in a configured-channel
# thread. The dispatcher's --workdir/--home/--config-dir default to
# CLAUDE_PROJECT_DIR / CLAUDE_CONFIG_DIR, and when neither is present its
# __file__-relative fallback resolves to the PLUGIN dir
# (plugins/discord/), so the spawned thread leg would cwd into
# plugins/discord/.threads and --add-dir plugins/discord — mis-attributing
# the thread leg's identity + runtime.
#
# The fix has server.ts forward the bridge launch envelope's owning-agent
# workdir/home/config-dir to the dispatcher explicitly
# (--workdir/--home/--config-dir). This smoke pins the dispatcher contract
# both sides:
#   * POSITIVE: with the binding args, dry-run dispatch reports
#     cwd = <agent-workdir>/.threads and --add-dir = <agent-workdir>.
#   * REGRESSION: with NO binding and NO CLAUDE_PROJECT_DIR, the dispatcher
#     falls back to the plugin dir (the bug the fix exists to close) — so a
#     future change that drops the server.ts forwarding is caught.
#   * FAIL-CLOSED: with no resolvable parent agent (BRIDGE_AGENT_ID /
#     BRIDGE_THREAD_PARENT_AGENT unset), dispatch refuses.
#
# Pure dry-run; no real Claude/Discord. py-only, no bridge state touched.

set -euo pipefail

SMOKE_NAME="12033-discord-thread-session-workdir-binding"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

DISPATCHER="$SMOKE_REPO_ROOT/plugins/discord/thread-session/thread_session_dispatcher.py"
PLUGIN_DIR="$SMOKE_REPO_ROOT/plugins/discord"

smoke_require_cmd python3

[[ -f "$DISPATCHER" ]] || smoke_fail "dispatcher not found at $DISPATCHER"

smoke_make_temp_root

AGENT_WORKDIR="$SMOKE_TMP_ROOT/owning-agent/workdir"
AGENT_HOME="$SMOKE_TMP_ROOT/owning-agent/home"
AGENT_CONFIG_DIR="$AGENT_HOME/.claude"
mkdir -p "$AGENT_WORKDIR" "$AGENT_CONFIG_DIR"
printf '# owning agent soul\n' >"$AGENT_WORKDIR/SOUL.md"
printf '# owning agent contract\n' >"$AGENT_WORKDIR/CLAUDE.md"

run_probe() {
  # $1 = python assertion script reading the dispatch JSON on argv[1].
  # Remaining args after `--` are passed straight to the dispatcher.
  local assertion="$1"; shift
  local out rc=0
  out="$(BRIDGE_AGENT_ID="owning-agent" python3 "$DISPATCHER" "$@" 2>/tmp/.thread-bind-err.$$)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    smoke_fail "dispatcher exited $rc: $(head -n1 /tmp/.thread-bind-err.$$ 2>/dev/null)"
  fi
  rm -f /tmp/.thread-bind-err.$$
  python3 -c "$assertion" "$out"
}

assert_binding_to_agent_workdir() {
  # init runtime under the bound workdir, then dry-run dispatch.
  BRIDGE_AGENT_ID="owning-agent" python3 "$DISPATCHER" \
    --workdir "$AGENT_WORKDIR" --home "$AGENT_HOME" --config-dir "$AGENT_CONFIG_DIR" \
    init >/dev/null

  run_probe '
import json, os, sys
payload = json.loads(sys.argv[1])
workdir = os.environ["EXPECT_WORKDIR"]
cwd = os.path.realpath(payload["cwd"])
cmd = payload["command"]
add_dir = os.path.realpath(cmd[cmd.index("--add-dir") + 1])
plugin = os.path.realpath(os.environ["PLUGIN_DIR"])
assert add_dir == os.path.realpath(workdir), f"--add-dir {add_dir} != agent workdir {workdir}"
assert cwd == os.path.realpath(os.path.join(workdir, ".threads")), f"cwd {cwd} not <workdir>/.threads"
assert not add_dir.startswith(plugin), f"--add-dir bound to plugin dir: {add_dir}"
assert not cwd.startswith(plugin), f"cwd bound to plugin dir: {cwd}"
' \
    --workdir "$AGENT_WORKDIR" --home "$AGENT_HOME" --config-dir "$AGENT_CONFIG_DIR" \
    dispatch --json --dry-run \
    --thread-id t1 --channel-name c --parent-channel-id p \
    --message-id m1 --user u --message hi
}

assert_no_binding_falls_back_to_plugin() {
  # Reproduce the bug path: no binding args, and scrub the env signals the
  # dispatcher would otherwise read, so --workdir falls back to default_workdir()
  # = the plugin dir. --add-dir must then resolve to the PLUGIN dir. We DO pass
  # an explicit --root under the temp root so the dry-run's ensure_runtime()
  # artifacts (.threads) do NOT land in the tracked plugins/discord/ tree;
  # --root only relocates rt.root and does not affect rt.workdir / --add-dir.
  local out rc=0
  local no_bind_root="$SMOKE_TMP_ROOT/no-bind-root"
  mkdir -p "$no_bind_root"
  out="$(env -u CLAUDE_PROJECT_DIR -u CLAUDE_CONFIG_DIR \
      -u THREAD_SESSION_WORKDIR -u THREAD_SESSION_HOME \
      -u BRIDGE_AGENT_WORKDIR_RESOLVED -u BRIDGE_AGENT_WORKDIR \
      -u BRIDGE_AGENT_HOME_RESOLVED \
      BRIDGE_AGENT_ID="owning-agent" \
      python3 "$DISPATCHER" --root "$no_bind_root" dispatch --json --dry-run \
        --thread-id t1 --channel-name c --parent-channel-id p \
        --message-id m1 --user u --message hi)" || rc=$?
  [[ $rc -eq 0 ]] || smoke_fail "no-binding dry-run exited $rc"
  PLUGIN_DIR="$PLUGIN_DIR" python3 -c '
import json, os, sys
payload = json.loads(sys.argv[1])
cmd = payload["command"]
add_dir = os.path.realpath(cmd[cmd.index("--add-dir") + 1])
plugin = os.path.realpath(os.environ["PLUGIN_DIR"])
assert add_dir == plugin, f"expected plugin-dir fallback, got {add_dir}"
' "$out"
}

assert_fail_closed_no_parent_agent() {
  local rc=0
  env -u BRIDGE_AGENT_ID -u BRIDGE_THREAD_PARENT_AGENT \
    python3 "$DISPATCHER" \
    --workdir "$AGENT_WORKDIR" --home "$AGENT_HOME" --config-dir "$AGENT_CONFIG_DIR" \
    dispatch --json --dry-run \
    --thread-id t1 --channel-name c --parent-channel-id p \
    --message-id m1 --user u --message hi >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 0 ]] || smoke_fail "dispatch did NOT fail closed without a resolvable parent agent"
}

assert_bundled_selftest_green() {
  # $1 = python script path (relative to the thread-session dir). Drive its
  # bundled `selftest` subcommand and require rc=0. This pins the thread guard
  # fail-closed contract (protected-path denies apply BEFORE the tmp write
  # carve-out) and the dispatcher's own invariants on every plugin touch.
  local script="$1"
  local path="$SMOKE_REPO_ROOT/plugins/discord/thread-session/$script"
  local rc=0
  [[ -f "$path" ]] || smoke_fail "bundled selftest target missing: $path"
  # Pin the dispatcher's runtime root to a temp workdir so the selftest's
  # `init` (registry/locks/scratch) lands under SMOKE_TMP_ROOT, NOT in the
  # tracked plugins/discord/.threads (the __file__-relative default workdir).
  local selftest_workdir="$SMOKE_TMP_ROOT/selftest-workdir"
  local selftest_root="$selftest_workdir/.threads"
  mkdir -p "$selftest_workdir"
  THREAD_SESSION_WORKDIR="$selftest_workdir" \
    THREAD_SESSION_HOME="$selftest_workdir/home" \
    THREAD_SESSION_ROOT="$selftest_root" \
    python3 "$path" selftest >/dev/null 2>/tmp/.thread-selftest-err.$$ || rc=$?
  if [[ $rc -ne 0 ]]; then
    smoke_fail "$script selftest exited $rc: $(tail -n1 /tmp/.thread-selftest-err.$$ 2>/dev/null)"
  fi
  rm -f /tmp/.thread-selftest-err.$$
}

main() {
  export EXPECT_WORKDIR="$AGENT_WORKDIR"
  export PLUGIN_DIR
  smoke_run "#12033 thread-session dry-run binds cwd/add-dir to the owning agent workdir" \
    assert_binding_to_agent_workdir
  smoke_run "#12033 no-binding + no CLAUDE_PROJECT_DIR falls back to plugin dir (regression guard)" \
    assert_no_binding_falls_back_to_plugin
  smoke_run "#12033 dispatch fails closed when no parent agent is resolvable" \
    assert_fail_closed_no_parent_agent
  smoke_run "#12033 thread_session_guard selftest GREEN (tmp carve-out cannot override protected-path deny)" \
    assert_bundled_selftest_green thread_session_guard.py
  smoke_run "#12033 thread_session_dispatcher selftest GREEN" \
    assert_bundled_selftest_green thread_session_dispatcher.py
  smoke_log "passed"
}

main "$@"
