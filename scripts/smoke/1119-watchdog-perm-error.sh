#!/usr/bin/env bash
# Issue #1119 regression smoke — `bridge-watchdog.py scan` must NEVER
# crash on a single agent's PermissionError. A v2-linux-user-isolated
# workdir is owned by `agent-bridge-<slug>:ab-agent-<slug>` mode `0700`
# (or `2750` with setgid + ACLs), so a controller-side `Path.is_dir()`
# on that workdir raises `PermissionError [Errno 13]`. Before the fix,
# that exception bubbled out of `resolve_scan_path` (the v2 workdir
# redirect from #1108) THROUGH the outer list-comprehension in
# `main()` and killed the whole pass — one isolated agent prevented
# every other agent from being scanned. The librarian-watchdog cron
# then silently stopped producing useful reports.
#
# Post-fix contract:
#
#   1. `resolve_scan_path` tries the direct `is_dir()`; on
#      `PermissionError` it probes via `sudo -n -u <iso> test -d`. If
#      sudo escalates, it returns the workdir; otherwise it re-raises.
#   2. `main()` wraps each agent's resolve+scan in a try/except. A
#      `PermissionError` / `FileNotFoundError` / `OSError` from the
#      resolve+scan boundary is captured into a structured
#      `status: scan_error` row with `error_kind` and `error_path` set
#      — and the walk continues for every other agent.
#
# Pre-fix behavior would have been an uncaught traceback at
# `bridge-watchdog.py:291` (`resolve_scan_path`'s `candidate.is_dir()`).
# Post-fix behavior is exit 0 with a JSON payload that contains the
# isolated agent's `scan_error` row AND every other agent's normal row.
#
# Asserts:
#
#   T1 — `watchdog scan --json` exits 0 even when one agent's workdir
#        is unreadable. (Pre-fix: exit 1 + traceback to stderr.)
#   T2 — The isolated agent appears in the output with
#        `status == "scan_error"`, `error_kind == "permission_denied"`,
#        and a non-empty `error_path` naming the unreachable workdir.
#   T3 — A second, healthy v2 agent in the same scan still classifies
#        `ok` with `missing_files: []` — the regression class is the
#        whole-pass crash, not a per-agent regression.
#   T4 — stderr names the unreachable agent + the `permission_denied`
#        kind so an operator inspecting cron logs can find it.
#
# Portability: this smoke does NOT require real linux-user isolation
# (no sudo / useradd / chgrp). It triggers the watchdog's
# PermissionError code path by placing the simulated isolated workdir
# under a 0000-mode parent directory, which raises EACCES on
# `is_dir()` for any caller — controller or otherwise — on Linux and
# macOS alike. The fix surface the smoke exercises (`resolve_scan_path`
# / `main()` outer try/except / `scan_error` row construction) is
# platform-independent.

set -uo pipefail

SMOKE_NAME="1119-watchdog-perm-error"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

cleanup() {
  # Restore the 0000-blocker mode so smoke_cleanup_temp_root can rm -rf
  # the tree. Without this, the rm walk fails on the unreachable dir.
  if [[ -n "${BLOCKED_PARENT:-}" && -d "$BLOCKED_PARENT" ]]; then
    chmod 0700 "$BLOCKED_PARENT" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# Two agents in the same scan: one isolated/unreachable, one healthy.
# The unreachable one is the regression-class trigger; the healthy one
# guards against the "fix accidentally short-circuited the whole loop"
# anti-regression.
ISOLATED_AGENT="iso_agent"
HEALTHY_AGENT="ok_agent"

# Place the isolated agent's workdir under a 0000-mode parent dir so
# `Path.is_dir()` raises `PermissionError [Errno 13]` regardless of the
# caller's UID. This matches the symptom shape from the operator host
# (`v2-linux-user-isolated workdir mode 0700`, controller missing the
# group): the `is_dir()` syscall reaches an ancestor it can't traverse
# and fails the same way.
BLOCKED_PARENT="$BRIDGE_AGENT_ROOT_V2/$ISOLATED_AGENT"
ISO_WORKDIR="$BLOCKED_PARENT/workdir"
mkdir -p "$ISO_WORKDIR"
# (Seed a profile inside; the file content is irrelevant — the
# watchdog never reaches it under the 0000 ancestor.)
: >"$ISO_WORKDIR/CLAUDE.md"
chmod 0000 "$BLOCKED_PARENT"

# Sanity guard: confirm the 0000-blocker actually denies `is_dir()`
# before running the watchdog. If the host runs as root (UID 0), 0000
# is bypassed and the smoke would PASS for the wrong reason — the
# regression-class test would not exercise the PermissionError path.
if "$PY_BIN" -c "from pathlib import Path; import sys; sys.exit(0 if Path('$ISO_WORKDIR').is_dir() else 1)" 2>/dev/null; then
  smoke_log "skip: running as root (UID 0) bypasses 0000-mode denial; cannot exercise PermissionError path"
  exit 0
fi

# Healthy v2 agent — full profile in workdir, no permission deny.
OK_WORKDIR="$BRIDGE_AGENT_ROOT_V2/$HEALTHY_AGENT/workdir"
mkdir -p "$OK_WORKDIR"
cat >"$OK_WORKDIR/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
: >"$OK_WORKDIR/SOUL.md"
: >"$OK_WORKDIR/MEMORY-SCHEMA.md"
: >"$OK_WORKDIR/MEMORY.md"
cat >"$OK_WORKDIR/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: static-claude
- Onboarding State: complete
EOF

# `list_agent_dirs` enumerates `$BRIDGE_AGENT_HOME_ROOT/<a>/` (the
# tracked profile-template tree) — seed an empty dir per agent so the
# resolver finds both in the scan_paths list before redirecting via
# the registry's `workdir` field. The watchdog only stat's these dirs
# during enumeration; it never reads inside.
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$ISOLATED_AGENT"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$HEALTHY_AGENT"

# Fixture registry — both agents are claude/static v2 with explicit
# `workdir` fields. The resolver redirects to those; for the isolated
# agent, that redirect is what triggers the `is_dir()` PermissionError
# class the fix guards against.
REGISTRY_JSON="$SMOKE_TMP_ROOT/registry.json"
cat >"$REGISTRY_JSON" <<EOF
[
  {
    "id": "$ISOLATED_AGENT",
    "class": "static",
    "agent_source": "static",
    "engine": "claude",
    "workdir": "$ISO_WORKDIR"
  },
  {
    "id": "$HEALTHY_AGENT",
    "class": "static",
    "agent_source": "static",
    "engine": "claude",
    "workdir": "$OK_WORKDIR"
  }
]
EOF

STDERR_LOG="$SMOKE_TMP_ROOT/stderr.log"
OUT_JSON="$("$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REGISTRY_JSON" 2>"$STDERR_LOG")"
RC=$?
if [[ $RC -ne 0 ]]; then
  smoke_log "stderr was:"
  cat "$STDERR_LOG" >&2 || true
  smoke_fail "T1 FAIL: watchdog scan exited rc=$RC (pre-fix shape: traceback at resolve_scan_path)"
fi
smoke_log "T1 PASS: watchdog scan exits 0 with one unreadable agent in the roster"

# T2 + T3: assert the JSON payload structure.
"$PY_BIN" - "$OUT_JSON" "$ISOLATED_AGENT" "$HEALTHY_AGENT" "$ISO_WORKDIR" <<'PY' \
  || smoke_fail "T2/T3 assertions failed — see stderr"
import json
import sys

payload = json.loads(sys.argv[1])
iso_agent = sys.argv[2]
ok_agent = sys.argv[3]
iso_workdir = sys.argv[4]

rows = {row["agent"]: row for row in payload["agents"]}
assert iso_agent in rows, (
    f"T2 FAIL: isolated agent missing from output rows; got {list(rows)}. "
    f"The whole pass may have aborted before the row was constructed."
)
assert ok_agent in rows, (
    f"T3 FAIL: healthy agent missing from output rows; got {list(rows)}. "
    f"Pre-fix bug shape — the isolated agent's PermissionError killed "
    f"the loop before the healthy agent was scanned."
)

iso_row = rows[iso_agent]
assert iso_row["status"] == "scan_error", (
    f"T2 FAIL: isolated agent status={iso_row['status']!r}; expected "
    f"'scan_error'. Row: {iso_row}."
)
assert iso_row.get("error_kind") == "permission_denied", (
    f"T2 FAIL: isolated agent error_kind={iso_row.get('error_kind')!r}; "
    f"expected 'permission_denied'. Row: {iso_row}."
)
err_path = iso_row.get("error_path") or ""
assert err_path, (
    f"T2 FAIL: isolated agent error_path is empty; expected the "
    f"unreachable workdir. Row: {iso_row}."
)
# The error_path can be either the exact workdir (when the OS reports
# the filename on the OSError) or the registry-recorded workdir
# (filename fallback). Both shapes are acceptable; assert it at least
# points at the unreachable tree, not an unrelated path.
assert iso_workdir in err_path or err_path in iso_workdir, (
    f"T2 FAIL: isolated agent error_path={err_path!r} does not name "
    f"the unreachable workdir {iso_workdir!r}. Row: {iso_row}."
)

ok_row = rows[ok_agent]
assert ok_row["status"] == "ok", (
    f"T3 FAIL: healthy agent status={ok_row['status']!r}; expected "
    f"'ok'. The fix must not affect agents whose workdir is readable. "
    f"Row: {ok_row}."
)
assert ok_row["missing_files"] == [], (
    f"T3 FAIL: healthy agent missing_files={ok_row['missing_files']!r}; "
    f"expected []. Row: {ok_row}."
)

# problem_count must include the scan_error row (it is NOT ok).
expected_problems = 1
assert payload.get("problem_count") == expected_problems, (
    f"T2/T3 FAIL: problem_count={payload.get('problem_count')!r}; "
    f"expected {expected_problems} (the scan_error row counts as a "
    f"problem so dashboards still surface it)."
)
print("T2+T3 PASS")
PY
smoke_log "T2 PASS: isolated agent reported as status=scan_error, error_kind=permission_denied"
smoke_log "T3 PASS: healthy agent in the same scan still classifies ok"

# T4 — stderr names the unreachable agent + the kind so the operator
# can grep cron logs for it. The exact wording is intentionally
# tolerant: the contract is "the agent name and the error_kind appear
# in stderr", not the specific message body.
stderr_text="$(cat "$STDERR_LOG")"
if [[ "$stderr_text" != *"$ISOLATED_AGENT"* ]]; then
  smoke_fail "T4 FAIL: stderr does not name the unreachable agent '$ISOLATED_AGENT'. stderr:\n$stderr_text"
fi
if [[ "$stderr_text" != *"permission_denied"* ]]; then
  smoke_fail "T4 FAIL: stderr does not surface 'permission_denied'. stderr:\n$stderr_text"
fi
smoke_log "T4 PASS: stderr surfaces the unreachable agent + permission_denied kind"

smoke_log "all 4 tests PASS (#1119)"
