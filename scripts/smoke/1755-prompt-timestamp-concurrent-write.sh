#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1755-prompt-timestamp-concurrent-write.sh — Issue #1755
#
# Pins the two-layer fix for the dynamic-agent every-prompt
# "UserPromptSubmit hook error / FileNotFoundError: timestamp.tmp -> timestamp.json".
#
# Root cause: the prompt_timestamp hook can run as TWO concurrent instances on
# the same prompt because the same hook SCRIPT was registered in the global and
# the per-workdir settings scope with DIVERGENT interpreter spellings
# (relative `python3` vs the pinned absolute interpreter), so Claude Code's
# exact-string hook dedup did not collapse them. Two concurrent
# save_timestamp_state() calls then raced on a FIXED tmp name (`timestamp.tmp`):
# the loser's `tmp.replace(path)` raised FileNotFoundError, which the #1205
# Family-B handler re-raised for the controller UID → exit 1 → visible banner.
#
# Tests:
#   T1 (P1, race elimination): N concurrent prompt_timestamp_context() instances
#       for the SAME agent (controller UID, no iso env) → ZERO exceptions,
#       a valid timestamp.json carrying since_last/session_age inputs
#       (last_prompt_at + session_started_at), and NO leaked `.tmp.*` sidecars.
#   T2 (P1, #1205 Family-B preserved): save_timestamp_state() on the controller
#       with a read-only state parent STILL raises (the unique-tmp helper must
#       not have turned a genuine PermissionError into a silent no-op).
#   T3 (P2, dedup): ensure-prompt-hook re-rendered across two scope files that
#       carry divergent interpreter spellings converges BOTH onto a single,
#       identical, pinned command string — rewritten in place, no appended dup —
#       so Claude Code's exact-string dedup collapses them to one execution.
#   T4 (P1, no silent-success regression): force the final replace() to raise
#       FileNotFoundError under the CONTROLLER context (monkeypatch Path.replace
#       to unlink the unique tmp and raise) and assert save_timestamp_state()
#       PROPAGATES the exception (no swallow-as-success), so a genuine write
#       failure can never be masked. Guards the r2 codex finding: with unique
#       tmp names a FileNotFoundError at replace() is a real failure, not the
#       old benign dup-instance race.
#
# Host-agnostic: no sudo. Footgun #11 (heredoc-stdin subprocess) avoided —
# every python driver is emitted with `printf '%s\n' >>file`.

set -uo pipefail

SMOKE_NAME="1755-prompt-timestamp-concurrent-write"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  if [[ -n "${SMOKE_TMP_ROOT:-}" && -d "$SMOKE_TMP_ROOT" ]]; then
    find "$SMOKE_TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
PYTHON_BIN="${BRIDGE_PYTHON_BIN:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || smoke_fail "python3 not found on PATH"

HOOK_COMMON_FILE="$REPO_ROOT/hooks/bridge_hook_common.py"
BRIDGE_HOOKS_PY="$REPO_ROOT/bridge-hooks.py"
smoke_assert_file_exists "$HOOK_COMMON_FILE" "hooks/bridge_hook_common.py present"
smoke_assert_file_exists "$BRIDGE_HOOKS_PY" "bridge-hooks.py present"

# bridge_hook_common imports ../lib/operator_home.py relative to its own file.
# Drive against the repo's real hooks/ + lib/ via sys.path so the resolver
# finds it; the isolated BRIDGE_HOME pins where timestamp.json lands.
HOOKS_DIR="$REPO_ROOT/hooks"
AGENT="conc_ts_agent"

# ---------------------------------------------------------------------------
# T1 + T2 driver — concurrent prompt_timestamp_context() + controller-raise
# counter-test. Prints one RESULT=PASS/FAIL line plus diagnostics.
# ---------------------------------------------------------------------------
T1_DRIVER="$SMOKE_TMP_ROOT/t1_concurrent.py"
: >"$T1_DRIVER"
# shellcheck disable=SC2129
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Issue #1755 T1/T2: concurrent prompt_timestamp + controller-raise."""'
  printf '%s\n' 'from __future__ import annotations'
  printf '%s\n' 'import os'
  printf '%s\n' 'import sys'
  printf '%s\n' 'import threading'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' ''
  printf '%s\n' 'hooks_dir = Path(os.environ["DRIVER_HOOKS_DIR"]).resolve()' # noqa: iso-helper-boundary — os.environ in an emitted test driver substring-matches the ratchet \.env pattern; not a boundary site
  printf '%s\n' 'repo_root = Path(os.environ["DRIVER_REPO_ROOT"]).resolve()' # noqa: iso-helper-boundary — os.environ in an emitted test driver substring-matches the ratchet \.env pattern; not a boundary site
  printf '%s\n' 'sys.path.insert(0, str(repo_root / "lib"))'
  printf '%s\n' 'sys.path.insert(0, str(hooks_dir))'
  printf '%s\n' 'import bridge_hook_common as bhc'
  printf '%s\n' ''
  printf '%s\n' 'agent = os.environ["DRIVER_AGENT"]' # noqa: iso-helper-boundary — os.environ in an emitted test driver substring-matches the ratchet \.env pattern; not a boundary site
  printf '%s\n' 'nthreads = 8'
  printf '%s\n' 'iters = 50'
  printf '%s\n' 'errors = []'
  printf '%s\n' 'barrier = threading.Barrier(nthreads)'
  printf '%s\n' ''
  printf '%s\n' 'def worker(i):'
  printf '%s\n' '    try:'
  printf '%s\n' '        barrier.wait()'
  printf '%s\n' '        for _ in range(iters):'
  printf '%s\n' '            bhc.prompt_timestamp_context(agent)'
  printf '%s\n' '    except Exception as exc:'
  printf '%s\n' '        errors.append(type(exc).__name__ + ":" + str(exc)[:160])'
  printf '%s\n' ''
  printf '%s\n' 'threads = [threading.Thread(target=worker, args=(i,)) for i in range(nthreads)]'
  printf '%s\n' 'for t in threads:'
  printf '%s\n' '    t.start()'
  printf '%s\n' 'for t in threads:'
  printf '%s\n' '    t.join()'
  printf '%s\n' ''
  printf '%s\n' 'state = bhc.load_timestamp_state(agent)'
  printf '%s\n' 'state_path = bhc.timestamp_state_path(agent)'
  printf '%s\n' 'leaked = sorted(p.name for p in state_path.parent.glob(state_path.name + ".*"))'
  printf '%s\n' 'print("ERRORS=" + repr(errors))'
  printf '%s\n' 'print("STATE_KEYS=" + ",".join(sorted(state.keys())))'
  printf '%s\n' 'print("LEAKED_TMP=" + ",".join(leaked))'
  printf '%s\n' 'ok = ('
  printf '%s\n' '    not errors'
  printf '%s\n' '    and "last_prompt_at" in state'
  printf '%s\n' '    and "session_started_at" in state'
  printf '%s\n' '    and not leaked'
  printf '%s\n' '    and state_path.exists()'
  printf '%s\n' ')'
  printf '%s\n' 'print("RESULT=" + ("PASS" if ok else "FAIL"))'
  printf '%s\n' 'raise SystemExit(0 if ok else 1)'
} >>"$T1_DRIVER"

smoke_log "T1: 8 concurrent prompt_timestamp_context() instances for one agent → no hook error"
T1_OUT="$(
  DRIVER_HOOKS_DIR="$HOOKS_DIR" \
  DRIVER_REPO_ROOT="$REPO_ROOT" \
  DRIVER_AGENT="$AGENT" \
  "$PYTHON_BIN" "$T1_DRIVER" 2>&1
)"
T1_RC=$?
smoke_assert_contains "$T1_OUT" "RESULT=PASS" "T1 concurrent prompt_timestamp (out: $T1_OUT)"
smoke_assert_eq 0 "$T1_RC" "T1 driver exit code (out: $T1_OUT)"
smoke_assert_not_contains "$T1_OUT" "FileNotFoundError" "T1 no FileNotFoundError surfaced"
smoke_assert_not_contains "$T1_OUT" "Traceback" "T1 no traceback surfaced"
smoke_log "T1 PASS: concurrent prompt_timestamp clean, timestamp.json updated, no tmp leak"

# ---------------------------------------------------------------------------
# T2 — #1205 Family-B preserved: controller-side write into a read-only state
# parent STILL raises (the unique-tmp helper must not have masked it).
# ---------------------------------------------------------------------------
T2_DRIVER="$SMOKE_TMP_ROOT/t2_controller_raise.py"
: >"$T2_DRIVER"
# shellcheck disable=SC2129
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Issue #1755 T2: controller-side read-only parent STILL raises."""'
  printf '%s\n' 'from __future__ import annotations'
  printf '%s\n' 'import os'
  printf '%s\n' 'import sys'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' ''
  printf '%s\n' 'hooks_dir = Path(os.environ["DRIVER_HOOKS_DIR"]).resolve()' # noqa: iso-helper-boundary — os.environ in an emitted test driver substring-matches the ratchet \.env pattern; not a boundary site
  printf '%s\n' 'repo_root = Path(os.environ["DRIVER_REPO_ROOT"]).resolve()' # noqa: iso-helper-boundary — os.environ in an emitted test driver substring-matches the ratchet \.env pattern; not a boundary site
  printf '%s\n' 'sys.path.insert(0, str(repo_root / "lib"))'
  printf '%s\n' 'sys.path.insert(0, str(hooks_dir))'
  printf '%s\n' 'import bridge_hook_common as bhc'
  printf '%s\n' ''
  printf '%s\n' 'agent = os.environ["DRIVER_AGENT"]' # noqa: iso-helper-boundary — os.environ in an emitted test driver substring-matches the ratchet \.env pattern; not a boundary site
  printf '%s\n' 'state_path = bhc.timestamp_state_path(agent)'
  printf '%s\n' 'parent = state_path.parent'
  printf '%s\n' 'parent.mkdir(parents=True, exist_ok=True)'
  printf '%s\n' '# Drop write/exec so mkstemp + replace cannot create under it.'
  printf '%s\n' 'os.chmod(parent, 0o555)'
  printf '%s\n' 'try:'
  printf '%s\n' '    bhc.save_timestamp_state(agent, {"last_prompt_at": 1, "session_started_at": 1})'
  printf '%s\n' '    print("RESULT=FAIL (no raise on read-only controller parent)")'
  printf '%s\n' '    rc = 1'
  printf '%s\n' 'except (PermissionError, OSError) as exc:'
  printf '%s\n' '    print("RAISED:" + type(exc).__name__)'
  printf '%s\n' '    print("RESULT=PASS")'
  printf '%s\n' '    rc = 0'
  printf '%s\n' 'finally:'
  printf '%s\n' '    os.chmod(parent, 0o755)'
  printf '%s\n' 'raise SystemExit(rc)'
} >>"$T2_DRIVER"

smoke_log "T2: controller-side save_timestamp_state into read-only parent → STILL raises (#1205 Family-B)"
T2_OUT="$(
  DRIVER_HOOKS_DIR="$HOOKS_DIR" \
  DRIVER_REPO_ROOT="$REPO_ROOT" \
  DRIVER_AGENT="ctrl_ro_agent" \
  "$PYTHON_BIN" "$T2_DRIVER" 2>&1
)"
smoke_assert_contains "$T2_OUT" "RESULT=PASS" "T2 controller-raise preserved (out: $T2_OUT)"
smoke_assert_contains "$T2_OUT" "RAISED:" "T2 genuine permission error propagated (out: $T2_OUT)"
smoke_log "T2 PASS: #1205 Family-B controller-side re-raise preserved"

# ---------------------------------------------------------------------------
# T3 — P2 cross-scope dedup convergence. Seed two scope settings files with
# DIVERGENT interpreter spellings, ensure-prompt-hook on each with the pinned
# bin, then assert both files carry ONE identical pinned timestamp command.
# ---------------------------------------------------------------------------
PIN_BIN="/usr/bin/python3"
[[ -x "$PIN_BIN" ]] || PIN_BIN="$(command -v python3)"
DEDUP_HOME="$SMOKE_TMP_ROOT/dedup-home"
mkdir -p "$DEDUP_HOME/hooks"

WORKDIR_SETTINGS="$SMOKE_TMP_ROOT/workdir-settings.json"
SHARED_SETTINGS="$SMOKE_TMP_ROOT/shared-settings.json"

# Stale workdir spelling (a different absolute interpreter) + relative shared
# spelling — exactly the live-install divergence shape.
: >"$WORKDIR_SETTINGS"
{
  printf '%s\n' '{'
  printf '%s\n' '  "hooks": {'
  printf '%s\n' '    "UserPromptSubmit": ['
  printf '%s\n' '      { "hooks": [ {'
  printf '%s\n' '        "type": "command",'
  printf '        "command": "/opt/other/bin/python3 %s/hooks/prompt_timestamp.py --format text",\n' "$DEDUP_HOME"
  printf '%s\n' '        "timeout": 3,'
  printf '%s\n' '        "additionalContext": true'
  printf '%s\n' '      } ] }'
  printf '%s\n' '    ]'
  printf '%s\n' '  }'
  printf '%s\n' '}'
} >>"$WORKDIR_SETTINGS"

: >"$SHARED_SETTINGS"
{
  printf '%s\n' '{'
  printf '%s\n' '  "hooks": {'
  printf '%s\n' '    "UserPromptSubmit": ['
  printf '%s\n' '      { "hooks": [ {'
  printf '%s\n' '        "type": "command",'
  printf '        "command": "python3 %s/hooks/prompt_timestamp.py --format text",\n' "$DEDUP_HOME"
  printf '%s\n' '        "timeout": 3,'
  printf '%s\n' '        "additionalContext": true'
  printf '%s\n' '      } ] }'
  printf '%s\n' '    ]'
  printf '%s\n' '  }'
  printf '%s\n' '}'
} >>"$SHARED_SETTINGS"

smoke_log "T3: ensure-prompt-hook converges divergent spellings onto one pinned command (P2 dedup)"
"$PYTHON_BIN" "$BRIDGE_HOOKS_PY" ensure-prompt-hook \
  --settings-file "$WORKDIR_SETTINGS" --bridge-home "$DEDUP_HOME" \
  --bash-bin bash --python-bin "$PIN_BIN" >/dev/null \
  || smoke_fail "T3: ensure-prompt-hook on workdir scope failed"
"$PYTHON_BIN" "$BRIDGE_HOOKS_PY" ensure-prompt-hook \
  --settings-file "$SHARED_SETTINGS" --bridge-home "$DEDUP_HOME" \
  --bash-bin bash --python-bin "$PIN_BIN" >/dev/null \
  || smoke_fail "T3: ensure-prompt-hook on shared scope failed"

# Extract + compare the timestamp commands across the two files.
T3_DRIVER="$SMOKE_TMP_ROOT/t3_compare.py"
: >"$T3_DRIVER"
# shellcheck disable=SC2129
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' 'import json, sys'
  printf '%s\n' 'def ts_cmds(p):'
  printf '%s\n' '    data = json.load(open(p))'
  printf '%s\n' '    out = []'
  printf '%s\n' '    for g in data["hooks"]["UserPromptSubmit"]:'
  printf '%s\n' '        for h in g.get("hooks", []):'
  printf '%s\n' '            if "prompt_timestamp.py" in str(h.get("command", "")):'
  printf '%s\n' '                out.append(h["command"])'
  printf '%s\n' '    return out'
  printf '%s\n' 'wd = ts_cmds(sys.argv[1])'
  printf '%s\n' 'sh = ts_cmds(sys.argv[2])'
  printf '%s\n' 'pin = sys.argv[3]'
  printf '%s\n' 'print("WD=" + repr(wd))'
  printf '%s\n' 'print("SH=" + repr(sh))'
  printf '%s\n' 'ok = (len(wd) == 1 and len(sh) == 1 and wd[0] == sh[0] and wd[0].startswith(pin + " "))'
  printf '%s\n' 'print("RESULT=" + ("PASS" if ok else "FAIL"))'
  printf '%s\n' 'raise SystemExit(0 if ok else 1)'
} >>"$T3_DRIVER"

T3_OUT="$("$PYTHON_BIN" "$T3_DRIVER" "$WORKDIR_SETTINGS" "$SHARED_SETTINGS" "$PIN_BIN" 2>&1)"
smoke_assert_contains "$T3_OUT" "RESULT=PASS" "T3 cross-scope dedup convergence (out: $T3_OUT)"
smoke_log "T3 PASS: both scopes converged on a single identical pinned timestamp command"

# ---------------------------------------------------------------------------
# T4 — P1 no-silent-success regression (r2 codex finding). With unique tmp
# names a FileNotFoundError at the final replace() is a GENUINE write failure,
# not the old benign dup-instance race. Monkeypatch Path.replace under the
# CONTROLLER context to unlink the unique source tmp and raise
# FileNotFoundError (the exact codex probe shape) and assert
# save_timestamp_state() PROPAGATES it — i.e. _atomic_write_text no longer
# swallows it, and the #1205 controller-side re-raise carries it out.
# ---------------------------------------------------------------------------
T4_DRIVER="$SMOKE_TMP_ROOT/t4_replace_fnf_propagates.py"
: >"$T4_DRIVER"
# shellcheck disable=SC2129
{
  printf '%s\n' '#!/usr/bin/env python3'
  printf '%s\n' '"""Issue #1755 T4: replace() FileNotFoundError PROPAGATES (no silent success)."""'
  printf '%s\n' 'from __future__ import annotations'
  printf '%s\n' 'import os'
  printf '%s\n' 'import sys'
  printf '%s\n' 'from pathlib import Path'
  printf '%s\n' ''
  printf '%s\n' 'hooks_dir = Path(os.environ["DRIVER_HOOKS_DIR"]).resolve()' # noqa: iso-helper-boundary — os.environ in an emitted test driver substring-matches the ratchet \.env pattern; not a boundary site
  printf '%s\n' 'repo_root = Path(os.environ["DRIVER_REPO_ROOT"]).resolve()' # noqa: iso-helper-boundary — os.environ in an emitted test driver substring-matches the ratchet \.env pattern; not a boundary site
  printf '%s\n' 'sys.path.insert(0, str(repo_root / "lib"))'
  printf '%s\n' 'sys.path.insert(0, str(hooks_dir))'
  printf '%s\n' 'import bridge_hook_common as bhc'
  printf '%s\n' ''
  printf '%s\n' 'agent = os.environ["DRIVER_AGENT"]' # noqa: iso-helper-boundary — os.environ in an emitted test driver substring-matches the ratchet \.env pattern; not a boundary site
  printf '%s\n' 'state_path = bhc.timestamp_state_path(agent)'
  printf '%s\n' 'state_path.parent.mkdir(parents=True, exist_ok=True)'
  printf '%s\n' ''
  printf '%s\n' '# Controller context: do NOT set BRIDGE_*ISOLAT* env, so'
  printf '%s\n' '# _under_isolated_uid() is False and the #1205 handler re-raises.'
  printf '%s\n' 'assert not bhc._under_isolated_uid(), "T4 expects controller (non-iso) context"'
  printf '%s\n' ''
  printf '%s\n' '_real_replace = Path.replace'
  printf '%s\n' 'def _boom(self, target):'
  printf '%s\n' '    # Mimic the codex probe: the unique source tmp vanishes and'
  printf '%s\n' '    # replace() raises FileNotFoundError = a real write failure.'
  printf '%s\n' '    try:'
  printf '%s\n' '        self.unlink()'
  printf '%s\n' '    except OSError:'
  printf '%s\n' '        pass'
  printf '%s\n' '    raise FileNotFoundError(2, "No such file or directory", str(self))'
  printf '%s\n' 'Path.replace = _boom'
  printf '%s\n' 'try:'
  printf '%s\n' '    try:'
  printf '%s\n' '        bhc.save_timestamp_state(agent, {"last_prompt_at": 1, "session_started_at": 1})'
  printf '%s\n' '        print("RESULT=FAIL (replace FileNotFoundError swallowed as success)")'
  printf '%s\n' '        rc = 1'
  printf '%s\n' '    except FileNotFoundError as exc:'
  printf '%s\n' '        print("PROPAGATED:FileNotFoundError:" + str(exc)[:120])'
  printf '%s\n' '        print("TARGET_EXISTS=" + str(state_path.exists()))'
  printf '%s\n' '        print("RESULT=PASS")'
  printf '%s\n' '        rc = 0'
  printf '%s\n' 'finally:'
  printf '%s\n' '    Path.replace = _real_replace'
  printf '%s\n' '# Assert the genuine failure left NO timestamp.json (no false success).'
  printf '%s\n' 'if rc == 0 and state_path.exists():'
  printf '%s\n' '    print("RESULT=FAIL (target written despite replace failure)")'
  printf '%s\n' '    rc = 1'
  printf '%s\n' 'leaked = sorted(p.name for p in state_path.parent.glob(state_path.name + ".*"))'
  printf '%s\n' 'print("LEAKED_TMP=" + ",".join(leaked))'
  printf '%s\n' 'raise SystemExit(rc)'
} >>"$T4_DRIVER"

smoke_log "T4: controller-side replace() FileNotFoundError PROPAGATES (no silent success — r2 codex finding)"
T4_OUT="$(
  DRIVER_HOOKS_DIR="$HOOKS_DIR" \
  DRIVER_REPO_ROOT="$REPO_ROOT" \
  DRIVER_AGENT="ctrl_fnf_agent" \
  "$PYTHON_BIN" "$T4_DRIVER" 2>&1
)"
smoke_assert_contains "$T4_OUT" "RESULT=PASS" "T4 replace FileNotFoundError propagates (out: $T4_OUT)"
smoke_assert_contains "$T4_OUT" "PROPAGATED:FileNotFoundError" "T4 exception reached the caller (out: $T4_OUT)"
smoke_assert_contains "$T4_OUT" "TARGET_EXISTS=False" "T4 no false success — target not written (out: $T4_OUT)"
smoke_log "T4 PASS: genuine replace() FileNotFoundError propagates; no silent-success masking"

smoke_log "$SMOKE_NAME PASS — all 4 tests green (P1 race + #1205 preserved + P2 dedup + no silent-success)"
