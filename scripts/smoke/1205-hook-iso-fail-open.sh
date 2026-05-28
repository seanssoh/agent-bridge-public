#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1205-hook-iso-fail-open.sh — Issue #1205
#
# Pins the contract closed by #1205 — hook scripts running under the iso v2
# isolated UID must fail-open (return [] / silent return) on PermissionError
# raised by the iso v2 filesystem contract instead of dumping a traceback.
# The visual noise (red PreToolUse/PostToolUse/UserPromptSubmit traceback on
# every tool call) made operators perceive that "agb itself is broken." It
# was not — the iso v2 contract was working as designed; the hook code just
# did not catch the expected PermissionError.
#
# Two surgical sites (codex r1 spec-ok, see #1205):
#   Family A — hooks/tool-policy.py::other_agent_homes()
#              wraps root.iterdir() + candidate.is_dir()
#   Family B — hooks/bridge_hook_common.py::save_timestamp_state()
#              wraps the entire write sequence (mkdir + write + chmod + replace)
#
# The two sites use the same iso-UID-gated try/except shape (re-raise for
# controller, fail-open for iso UID) backed by under_isolated_uid().
#
# Tests:
#   T1 (Family A): other_agent_homes() under iso UID + 0111 BRIDGE_AGENT_HOME_ROOT
#                  → returns [] silently (rc=0, no Traceback on stderr).
#   T2 (Family A): other_agent_homes() under controller (no iso env) +
#                  unreadable root → RAISES PermissionError/OSError
#                  (counter-test against silent regression).
#   T3 (Family A): iso env + matching BRIDGE_CONTROLLER_UID (i.e. effective UID
#                  equals controller — env-only iso shape) → RAISES.
#                  Pins the #1167-style codex BLOCKING regression where the
#                  gate keys only on env presence.
#   T4 (Family B): save_timestamp_state() under iso UID + read-only state
#                  parent (chmod 0555) → returns silently (rc=0, no stderr).
#   T5 (Family B): save_timestamp_state() under controller + read-only state
#                  parent → RAISES PermissionError/OSError.
#   T6 (Family B): iso env + matching BRIDGE_CONTROLLER_UID → RAISES
#                  (env-only-iso counter-test, mirrors T3 on Family B).
#
# Host-agnostic: no sudo required. The "iso UID" is simulated via
# BRIDGE_CONTROLLER_UID set to a synthetic value (999999) different from the
# smoke runner's euid — exactly how the #1165 Track C smoke already runs.
# Footgun #11 (heredoc-stdin subprocess) is off the table — every driver is
# emitted with `printf '%s\n' >>file`.

set -uo pipefail

SMOKE_NAME="1205-hook-iso-fail-open"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  # Restore any chmod 0111 / 0555 dirs so rm -rf can drain them.
  if [[ -n "${SMOKE_TMP_ROOT:-}" && -d "$SMOKE_TMP_ROOT" ]]; then
    find "$SMOKE_TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
TOOL_POLICY_FILE="$REPO_ROOT/hooks/tool-policy.py"
HOOK_COMMON_FILE="$REPO_ROOT/hooks/bridge_hook_common.py"

smoke_assert_file_exists "$TOOL_POLICY_FILE" "hooks/tool-policy.py present"
smoke_assert_file_exists "$HOOK_COMMON_FILE" "hooks/bridge_hook_common.py present"

PYTHON_BIN="${BRIDGE_PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 \
  || smoke_fail "python3 not found on PATH"

# ---------------------------------------------------------------------------
# Family A driver — exercises tool-policy.other_agent_homes() directly.
# Loads tool-policy as a module via importlib (avoids dashed-filename
# import issues) and prints either CLEAN:<count> or RAISED:<ExcType>:<msg>.
# ---------------------------------------------------------------------------
build_family_a_driver() {
  local driver="$1"
  : >"$driver"
  # shellcheck disable=SC2129
  {
    printf '%s\n' '#!/usr/bin/env python3'
    printf '%s\n' '"""Invoke tool-policy.other_agent_homes() with a controlled env."""'
    printf '%s\n' 'from __future__ import annotations'
    printf '%s\n' 'import importlib.util'
    printf '%s\n' 'import os'
    printf '%s\n' 'import sys'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'def load_module(name, path):'
    printf '%s\n' '    spec = importlib.util.spec_from_file_location(name, str(path))'
    printf '%s\n' '    if spec is None or spec.loader is None:'
    printf '%s\n' '        raise RuntimeError("cannot load " + name + " from " + str(path))'
    printf '%s\n' '    module = importlib.util.module_from_spec(spec)'
    printf '%s\n' '    sys.modules[name] = module'
    printf '%s\n' '    spec.loader.exec_module(module)'
    printf '%s\n' '    return module'
    printf '%s\n' ''
    printf '%s\n' 'def main() -> int:'
    printf '%s\n' '    hooks_dir = Path(os.environ["DRIVER_HOOKS_DIR"]).resolve()'  # noqa: iso-helper-boundary
    printf '%s\n' '    repo_root = Path(os.environ["DRIVER_REPO_ROOT"]).resolve()'  # noqa: iso-helper-boundary
    # hooks_dir must come first on sys.path so tool-policy can import
    # bridge_hook_common as a module (its sys.path.insert mirrors this).
    printf '%s\n' '    sys.path.insert(0, str(hooks_dir))'
    printf '%s\n' '    sys.path.insert(0, str(repo_root / "lib"))'
    printf '%s\n' '    tp = load_module("tool_policy", hooks_dir / "tool-policy.py")'
    printf '%s\n' '    agent = os.environ.get("DRIVER_AGENT", "smoke_agent")'  # noqa: iso-helper-boundary
    printf '%s\n' '    try:'
    printf '%s\n' '        result = tp.other_agent_homes(agent)'
    printf '%s\n' '    except Exception as exc:'
    printf '%s\n' '        print("RAISED:" + type(exc).__name__ + ":" + str(exc)[:200])'
    printf '%s\n' '        return 0'
    printf '%s\n' '    print("CLEAN:" + str(len(result)))'
    printf '%s\n' '    return 0'
    printf '%s\n' ''
    printf '%s\n' 'if __name__ == "__main__":'
    printf '%s\n' '    raise SystemExit(main())'
  } >>"$driver"
  chmod +x "$driver"
}

# ---------------------------------------------------------------------------
# Family B driver — exercises bridge_hook_common.save_timestamp_state()
# directly. Prints CLEAN or RAISED:<ExcType>:<msg>.
# ---------------------------------------------------------------------------
build_family_b_driver() {
  local driver="$1"
  : >"$driver"
  # shellcheck disable=SC2129
  {
    printf '%s\n' '#!/usr/bin/env python3'
    printf '%s\n' '"""Invoke bridge_hook_common.save_timestamp_state with a controlled env."""'
    printf '%s\n' 'from __future__ import annotations'
    printf '%s\n' 'import importlib.util'
    printf '%s\n' 'import os'
    printf '%s\n' 'import sys'
    printf '%s\n' 'from pathlib import Path'
    printf '%s\n' ''
    printf '%s\n' 'def load_module(path):'
    printf '%s\n' '    spec = importlib.util.spec_from_file_location("bridge_hook_common", str(path))'
    printf '%s\n' '    if spec is None or spec.loader is None:'
    printf '%s\n' '        raise RuntimeError("cannot load bridge_hook_common from " + str(path))'
    printf '%s\n' '    module = importlib.util.module_from_spec(spec)'
    printf '%s\n' '    spec.loader.exec_module(module)'
    printf '%s\n' '    return module'
    printf '%s\n' ''
    printf '%s\n' 'def main() -> int:'
    printf '%s\n' '    common_path = Path(os.environ["DRIVER_HOOK_COMMON_PATH"])'  # noqa: iso-helper-boundary
    printf '%s\n' '    module = load_module(common_path)'
    printf '%s\n' '    agent = os.environ.get("DRIVER_AGENT", "smoke_agent")'  # noqa: iso-helper-boundary
    printf '%s\n' '    try:'
    printf '%s\n' '        module.save_timestamp_state(agent, {"session_started_at": 1, "last_prompt_at": 2})'
    printf '%s\n' '    except Exception as exc:'
    printf '%s\n' '        print("RAISED:" + type(exc).__name__ + ":" + str(exc)[:200])'
    printf '%s\n' '        return 0'
    printf '%s\n' '    print("CLEAN")'
    printf '%s\n' '    return 0'
    printf '%s\n' ''
    printf '%s\n' 'if __name__ == "__main__":'
    printf '%s\n' '    raise SystemExit(main())'
  } >>"$driver"
  chmod +x "$driver"
}

# Pick a synthetic controller UID that cannot match the smoke runner's
# euid. 999999 is far outside any real UID space. Used in T1/T4 to make
# under_isolated_uid() return True; used in T3/T6 to match the runner's
# euid so under_isolated_uid() returns False (env-only-iso shape).
SYNTHETIC_NON_MATCH_UID="999999"
CURRENT_EUID="$(python3 -c 'import os; print(os.geteuid())')"

ABSURD_TRACEBACK_GREP='Traceback (most recent call last)'

assert_no_traceback() {
  local label="$1"
  local err_file="$2"
  if grep -q "$ABSURD_TRACEBACK_GREP" "$err_file" 2>/dev/null; then
    smoke_fail "$label: stderr contained Traceback (operator UX still broken). stderr: $(cat "$err_file")"
  fi
}

# ---------------------------------------------------------------------------
# T1 — Family A under iso UID + unreadable agent-home root → returns []
# ---------------------------------------------------------------------------
smoke_log "T1: other_agent_homes() under iso UID + 0111 root → returns [] (no Traceback)"

T1_DRIVER="$SMOKE_TMP_ROOT/t1-driver.py"
build_family_a_driver "$T1_DRIVER"

T1_ROOT="$SMOKE_TMP_ROOT/t1-agent-home-root"
mkdir -p "$T1_ROOT"
# Drop two synthetic peer-home dirs the controller-side counter-test
# (T2) can still enumerate when the mode is loosened. Under T1's 0111
# mode they exist but cannot be listed.
mkdir -p "$T1_ROOT/peer_a" "$T1_ROOT/peer_b"
chmod 0111 "$T1_ROOT"

T1_OUT="$SMOKE_TMP_ROOT/t1-out.txt"
T1_ERR="$SMOKE_TMP_ROOT/t1-err.txt"
DRIVER_HOOKS_DIR="$REPO_ROOT/hooks" \
  DRIVER_REPO_ROOT="$REPO_ROOT" \
  DRIVER_AGENT="smoke_agent" \
  BRIDGE_AGENT_HOME_ROOT="$T1_ROOT" \
  BRIDGE_AGENT_ID="iso_smoke_agent" \
  BRIDGE_AGENT_ISOLATION_MODE="linux-user" \
  BRIDGE_CONTROLLER_UID="$SYNTHETIC_NON_MATCH_UID" \
  "$PYTHON_BIN" "$T1_DRIVER" >"$T1_OUT" 2>"$T1_ERR"
T1_RC=$?

chmod 0700 "$T1_ROOT" 2>/dev/null || true
if [[ $T1_RC -ne 0 ]]; then
  smoke_fail "T1: driver exited with rc=$T1_RC (expected 0). stdout: $(cat "$T1_OUT") stderr: $(cat "$T1_ERR")"
fi
T1_RESULT="$(cat "$T1_OUT" | tr -d '\n')"
if [[ "$T1_RESULT" != "CLEAN:0" ]]; then
  smoke_fail "T1: expected 'CLEAN:0' (other_agent_homes returned []), got: '$T1_RESULT'. stderr: $(cat "$T1_ERR")"
fi
assert_no_traceback "T1" "$T1_ERR"
smoke_log "T1 PASS: other_agent_homes() under iso UID + 0111 root → [] (silent)"

# ---------------------------------------------------------------------------
# T2 — Family A on controller (no iso env) + unreadable root → RAISES
# ---------------------------------------------------------------------------
smoke_log "T2: other_agent_homes() on controller (no iso env) + 0111 root → RAISES"

T2_ROOT="$SMOKE_TMP_ROOT/t2-agent-home-root"
mkdir -p "$T2_ROOT/peer_a"
chmod 0111 "$T2_ROOT"

T2_OUT="$SMOKE_TMP_ROOT/t2-out.txt"
T2_ERR="$SMOKE_TMP_ROOT/t2-err.txt"
# Note: BRIDGE_AGENT_ISOLATION_MODE intentionally unset → under_isolated_uid()
# returns False → the swallow branch must NOT fire.
env -u BRIDGE_AGENT_ISOLATION_MODE \
    -u BRIDGE_CONTROLLER_UID \
  DRIVER_HOOKS_DIR="$REPO_ROOT/hooks" \
  DRIVER_REPO_ROOT="$REPO_ROOT" \
  DRIVER_AGENT="smoke_agent" \
  BRIDGE_AGENT_HOME_ROOT="$T2_ROOT" \
  BRIDGE_AGENT_ID="controller_smoke_agent" \
  "$PYTHON_BIN" "$T1_DRIVER" >"$T2_OUT" 2>"$T2_ERR"
T2_RC=$?

chmod 0700 "$T2_ROOT" 2>/dev/null || true
if [[ $T2_RC -ne 0 ]]; then
  smoke_fail "T2: driver exited with rc=$T2_RC. stdout: $(cat "$T2_OUT") stderr: $(cat "$T2_ERR")"
fi
T2_RESULT="$(cat "$T2_OUT" | tr -d '\n')"
case "$T2_RESULT" in
  RAISED:PermissionError:*|RAISED:OSError:*)
    smoke_log "T2 PASS: controller-side other_agent_homes() propagated $T2_RESULT"
    ;;
  *)
    smoke_fail "T2: expected RAISED:PermissionError:* / RAISED:OSError:* (controller still raises), got: '$T2_RESULT'. stderr: $(cat "$T2_ERR")"
    ;;
esac

# ---------------------------------------------------------------------------
# T3 — Family A with env-only iso shape (matching CONTROLLER_UID) → RAISES
# ---------------------------------------------------------------------------
smoke_log "T3: other_agent_homes() with iso env but controller-matching UID → RAISES"

T3_ROOT="$SMOKE_TMP_ROOT/t3-agent-home-root"
mkdir -p "$T3_ROOT/peer_a"
chmod 0111 "$T3_ROOT"

T3_OUT="$SMOKE_TMP_ROOT/t3-out.txt"
T3_ERR="$SMOKE_TMP_ROOT/t3-err.txt"
DRIVER_HOOKS_DIR="$REPO_ROOT/hooks" \
  DRIVER_REPO_ROOT="$REPO_ROOT" \
  DRIVER_AGENT="smoke_agent" \
  BRIDGE_AGENT_HOME_ROOT="$T3_ROOT" \
  BRIDGE_AGENT_ID="iso_shape_only_agent" \
  BRIDGE_AGENT_ISOLATION_MODE="linux-user" \
  BRIDGE_CONTROLLER_UID="$CURRENT_EUID" \
  "$PYTHON_BIN" "$T1_DRIVER" >"$T3_OUT" 2>"$T3_ERR"
T3_RC=$?

chmod 0700 "$T3_ROOT" 2>/dev/null || true
if [[ $T3_RC -ne 0 ]]; then
  smoke_fail "T3: driver exited with rc=$T3_RC. stdout: $(cat "$T3_OUT") stderr: $(cat "$T3_ERR")"
fi
T3_RESULT="$(cat "$T3_OUT" | tr -d '\n')"
case "$T3_RESULT" in
  RAISED:PermissionError:*|RAISED:OSError:*)
    smoke_log "T3 PASS: env-only iso (UID matches controller) propagated $T3_RESULT"
    ;;
  *)
    smoke_fail "T3: expected RAISED (env-only iso shape must NOT swallow), got: '$T3_RESULT'. stderr: $(cat "$T3_ERR")"
    ;;
esac

# ---------------------------------------------------------------------------
# T4 — Family B under iso UID + read-only state parent → returns silently
# ---------------------------------------------------------------------------
smoke_log "T4: save_timestamp_state() under iso UID + 0555 state parent → silent return"

T4_DRIVER="$SMOKE_TMP_ROOT/t4-driver.py"
build_family_b_driver "$T4_DRIVER"

T4_HOME="$SMOKE_TMP_ROOT/t4-bridge-home"
T4_STATE_DIR="$T4_HOME/state"
T4_STATE_AGENTS="$T4_STATE_DIR/agents"
mkdir -p "$T4_STATE_AGENTS"
# 0555: traverse + read, no write → mkdir of <agent>/ subdir fails.
chmod 0555 "$T4_STATE_AGENTS"

T4_OUT="$SMOKE_TMP_ROOT/t4-out.txt"
T4_ERR="$SMOKE_TMP_ROOT/t4-err.txt"
DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON_FILE" \
  DRIVER_AGENT="iso_b_agent" \
  BRIDGE_HOME="$T4_HOME" \
  BRIDGE_STATE_DIR="$T4_STATE_DIR" \
  BRIDGE_ACTIVE_AGENT_DIR="$T4_STATE_AGENTS" \
  BRIDGE_AGENT_ID="iso_b_agent" \
  BRIDGE_AGENT_ISOLATION_MODE="linux-user" \
  BRIDGE_CONTROLLER_UID="$SYNTHETIC_NON_MATCH_UID" \
  "$PYTHON_BIN" "$T4_DRIVER" >"$T4_OUT" 2>"$T4_ERR"
T4_RC=$?

chmod 0700 "$T4_STATE_AGENTS" 2>/dev/null || true
if [[ $T4_RC -ne 0 ]]; then
  smoke_fail "T4: driver exited with rc=$T4_RC. stdout: $(cat "$T4_OUT") stderr: $(cat "$T4_ERR")"
fi
T4_RESULT="$(cat "$T4_OUT" | tr -d '\n')"
if [[ "$T4_RESULT" != "CLEAN" ]]; then
  smoke_fail "T4: expected 'CLEAN' (save_timestamp_state returned without raise), got: '$T4_RESULT'. stderr: $(cat "$T4_ERR")"
fi
assert_no_traceback "T4" "$T4_ERR"
smoke_log "T4 PASS: save_timestamp_state() under iso UID + 0555 state parent → silent"

# ---------------------------------------------------------------------------
# T5 — Family B on controller (no iso env) + read-only state parent → RAISES
# ---------------------------------------------------------------------------
smoke_log "T5: save_timestamp_state() on controller + 0555 state parent → RAISES"

T5_HOME="$SMOKE_TMP_ROOT/t5-bridge-home"
T5_STATE_DIR="$T5_HOME/state"
T5_STATE_AGENTS="$T5_STATE_DIR/agents"
mkdir -p "$T5_STATE_AGENTS"
chmod 0555 "$T5_STATE_AGENTS"

T5_OUT="$SMOKE_TMP_ROOT/t5-out.txt"
T5_ERR="$SMOKE_TMP_ROOT/t5-err.txt"
env -u BRIDGE_AGENT_ISOLATION_MODE \
    -u BRIDGE_CONTROLLER_UID \
  DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON_FILE" \
  DRIVER_AGENT="controller_b_agent" \
  BRIDGE_HOME="$T5_HOME" \
  BRIDGE_STATE_DIR="$T5_STATE_DIR" \
  BRIDGE_ACTIVE_AGENT_DIR="$T5_STATE_AGENTS" \
  BRIDGE_AGENT_ID="controller_b_agent" \
  "$PYTHON_BIN" "$T4_DRIVER" >"$T5_OUT" 2>"$T5_ERR"
T5_RC=$?

chmod 0700 "$T5_STATE_AGENTS" 2>/dev/null || true
if [[ $T5_RC -ne 0 ]]; then
  smoke_fail "T5: driver exited with rc=$T5_RC. stdout: $(cat "$T5_OUT") stderr: $(cat "$T5_ERR")"
fi
T5_RESULT="$(cat "$T5_OUT" | tr -d '\n')"
case "$T5_RESULT" in
  RAISED:PermissionError:*|RAISED:OSError:*)
    smoke_log "T5 PASS: controller-side save_timestamp_state() propagated $T5_RESULT"
    ;;
  *)
    smoke_fail "T5: expected RAISED:PermissionError:* / RAISED:OSError:* (controller still raises), got: '$T5_RESULT'. stderr: $(cat "$T5_ERR")"
    ;;
esac

# ---------------------------------------------------------------------------
# T6 — Family B env-only iso shape (matching CONTROLLER_UID) → RAISES
# ---------------------------------------------------------------------------
smoke_log "T6: save_timestamp_state() with iso env but controller-matching UID → RAISES"

T6_HOME="$SMOKE_TMP_ROOT/t6-bridge-home"
T6_STATE_DIR="$T6_HOME/state"
T6_STATE_AGENTS="$T6_STATE_DIR/agents"
mkdir -p "$T6_STATE_AGENTS"
chmod 0555 "$T6_STATE_AGENTS"

T6_OUT="$SMOKE_TMP_ROOT/t6-out.txt"
T6_ERR="$SMOKE_TMP_ROOT/t6-err.txt"
DRIVER_HOOK_COMMON_PATH="$HOOK_COMMON_FILE" \
  DRIVER_AGENT="iso_shape_only_b_agent" \
  BRIDGE_HOME="$T6_HOME" \
  BRIDGE_STATE_DIR="$T6_STATE_DIR" \
  BRIDGE_ACTIVE_AGENT_DIR="$T6_STATE_AGENTS" \
  BRIDGE_AGENT_ID="iso_shape_only_b_agent" \
  BRIDGE_AGENT_ISOLATION_MODE="linux-user" \
  BRIDGE_CONTROLLER_UID="$CURRENT_EUID" \
  "$PYTHON_BIN" "$T4_DRIVER" >"$T6_OUT" 2>"$T6_ERR"
T6_RC=$?

chmod 0700 "$T6_STATE_AGENTS" 2>/dev/null || true
if [[ $T6_RC -ne 0 ]]; then
  smoke_fail "T6: driver exited with rc=$T6_RC. stdout: $(cat "$T6_OUT") stderr: $(cat "$T6_ERR")"
fi
T6_RESULT="$(cat "$T6_OUT" | tr -d '\n')"
case "$T6_RESULT" in
  RAISED:PermissionError:*|RAISED:OSError:*)
    smoke_log "T6 PASS: env-only iso Family B propagated $T6_RESULT"
    ;;
  *)
    smoke_fail "T6: expected RAISED (env-only iso shape must NOT swallow), got: '$T6_RESULT'. stderr: $(cat "$T6_ERR")"
    ;;
esac

smoke_log "1205-hook-iso-fail-open PASS — all 6 tests green (Family A + B fail-open + 3 negative tests)"
