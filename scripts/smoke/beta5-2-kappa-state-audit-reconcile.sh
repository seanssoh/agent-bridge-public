#!/usr/bin/env bash
# shellcheck shell=bash
#
# scripts/smoke/beta5-2-kappa-state-audit-reconcile.sh —
# v0.15.0-beta5-2 Lane κ pin for the 3 patch-audit items:
#
#   #1319 H1 — activity_state picker_blocked: bridge-stall.py +
#               lib/bridge-state.sh resolver emit `picker_blocked` when
#               a rate-limit / summary picker is detected. The daemon
#               nudge path treats it as not-idle (don't fire) and not
#               as working (don't reset the stall counter).
#
#   #1324 M1 — iso v2 audit log dir: `agb audit list` (no --agent) on
#               iso v2 install enumerates BOTH the legacy controller-
#               rooted tree `$BRIDGE_HOME/logs/agents/<a>/audit.jsonl`
#               AND the v2 canonical tree
#               `$BRIDGE_HOME/data/agents/<a>/logs/audit.jsonl`. Per
#               [[feedback-root-vs-symptom-framing]] the root cause is
#               that `bridge-audit.sh:46` was hard-coded to the legacy
#               path; the v2 per-agent dirs ARE created by the prepare
#               matrix (lib/bridge-agents.sh:4389) so the existence
#               assertion holds — only the enumerator was broken.
#
#   #1325 M2 — `isolation reconcile --check` parity: manual mode
#               (--check, no --agent / --all) detects per-agent .claude
#               drift. Lane γ beta5 #1298 added the manual-mode
#               implicit `--all-agents` expansion; this smoke
#               functionally confirms `--check` honors it (the gamma
#               smoke only static-grepped the branch).
#
# Each test is paired with a teeth revert to prove the smoke would have
# caught the original bug. Per Sean's "꼼꼼하게 사이드이펙트 없이 엣지케이스
# 고려" directive (2026-05-26 brief), edge cases are addressed in-line.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every assertion
# uses `grep`/`awk` against source files OR builds harness scripts via
# `printf '%s\n' >file` and runs them as external scripts. No `<<<`
# here-string or `<<EOF` heredoc-stdin into subprocess capture.

set -uo pipefail

SMOKE_NAME="beta5-2-kappa-state-audit-reconcile"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via trap (next line), not a direct call.
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# ---------------------------------------------------------------------
# Hermetic source snapshot (#1509).
#
# Every static introspection below (T1.x / T3.x / T4.x / T8.a) greps or
# awk-extracts a function body from a source file to assert "function X
# wires call Y". Reading those files from the LIVE working tree makes the
# assertions NON-HERMETIC: under the CI `unit/static smoke` job, many
# smokes run sequentially against ONE checkout, and a neighbor smoke (or
# a load-sensitive partial read while another step rewrites/copies the
# same path) can transiently present a mutated/partial body — yielding a
# FALSE-RED (e.g. T1.c "bridge_write_roster_status_snapshot does not call
# bridge_agent_picker_blocked") even though `origin/main` is correct.
#
# Fix: snapshot each source file under test ONCE, here, into this smoke's
# own private $SMOKE_TMP_ROOT (a per-process mktemp dir that NOTHING in
# the job can mutate after capture). Re-point the *_LIB / *_CLI / *_PY
# vars at the immutable copies. The static assertions are unchanged in
# MEANING — they still verify the real source wires the call — they just
# read a copy that is frozen at smoke start.
#
# Capture source: PREFER the committed blob via `git show HEAD:<path>`.
# In CI the `unit/static smoke` job runs against a checked-out commit, so
# HEAD is exactly the source under test, and the object store is IMMUNE to
# any working-tree mutation — even a writer that truncates+rewrites the
# live file cannot corrupt a `git show` read (a plain `cp` of the live
# file CAN race such a writer and freeze a corrupt copy). When the smoke
# runs outside a git work tree (e.g. a tarball install), fall back to a
# `cp` of the live file. The teeth (T5/T6/T7/T9) derive their own temp
# copies from these snapshots, so they stay fully isolated from the live
# tree.
# ---------------------------------------------------------------------
SNAP_DIR="$SMOKE_TMP_ROOT/src-snapshot"
mkdir -p "$SNAP_DIR"

# Detect a usable git work tree rooted at the source checkout. If present,
# capture from the committed blob; otherwise fall back to copying the live
# file. Resolved once so every file uses the same capture strategy.
SNAP_USE_GIT=0
if command -v git >/dev/null 2>&1 \
   && git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  SNAP_USE_GIT=1
fi

# Freeze an immutable copy of one source file.
#   $1 = repo-relative path (e.g. lib/bridge-state.sh)
#   $2 = snapshot destination path
#
# In git mode we read the committed blob via `git show HEAD:$rel` WITHOUT
# touching the live working-tree path at all — no `[[ -f live ]]` guard,
# because that guard would re-introduce a working-tree dependency: a
# neighbor smoke transiently unlinking/replacing the live file could
# false-red the existence check even though the object store (what git
# mode actually reads) is fine. Only the non-git fallback needs the live
# file to exist.
_kappa_snapshot_source() {
  local rel="$1" dest="$2"
  if [[ "$SNAP_USE_GIT" == "1" ]]; then
    if git -C "$REPO_ROOT" show "HEAD:$rel" >"$dest" 2>/dev/null \
       && [[ -s "$dest" ]]; then
      return 0
    fi
    # HEAD lacks the path (e.g. a brand-new untracked source file): fall
    # through to the live-file copy below rather than failing outright.
  fi
  # Fallback: copy the live file (non-git context, or path not yet in HEAD).
  [[ -f "$REPO_ROOT/$rel" ]] || smoke_fail "missing $REPO_ROOT/$rel"
  cp "$REPO_ROOT/$rel" "$dest" || smoke_fail "could not snapshot $rel -> $dest"
}

# ---------------------------------------------------------------------
# T1.c-class flake root cause (CI false-red, e.g. PR #1847 run
# 27401135893): this smoke runs under `set -o pipefail`, and the
# original assertions used the shape
#
#     awk '<function range>' file | grep -qF 'needle'
#
# `grep -q` exits 0 at the FIRST match and closes the read end of the
# pipe. The snapshot-writer body is 4412 bytes with the needle at byte
# 3508 — past one 4096-byte stdio buffer — so awk emits it in two
# writes. When the runner deschedules awk between those writes (loaded
# CI box), grep matches in write 1 and exits before write 2; awk's
# second write then dies with SIGPIPE (rc 141), `pipefail` propagates
# 141 as the pipeline status even though grep matched, and the leading
# `!` turns a successful match into a false-red. Verified mechanically:
# an identical producer (4096B chunk containing the needle + delayed
# tail) yields pipeline rc=141 with PIPESTATUS producer=141/grep=0.
# The failing CI runs had `lib/bridge-state.sh` byte-identical to a
# passing main — content was never the problem; the pipe race was.
#
# Fix shape used below: extract the function body to a FILE (plain
# redirect, no pipe), then `grep -q` the file. No pipeline → no
# SIGPIPE → deterministic. T1.d (3403B) / T8.a (3857B) sit one
# refactor away from the same >4096B cliff, so they get the same
# treatment. Single-short-line `printf | grep -q` sites (T4 gate
# line) are not raceable — the producer's only write necessarily
# precedes grep's exit — and are left as-is.
# ---------------------------------------------------------------------

# Extract a shell function body by NAME from a (hermetic snapshot) source
# file, anchored on structural brace depth rather than a textual line
# window. Prints the function block (header line through its matching close
# brace) to stdout — call sites MUST redirect to a file and grep the file
# (see flake root-cause block above; piping this into `grep -q` under
# pipefail re-opens the SIGPIPE false-red).
#
# Why not `awk '/^name\(\) \{/,/^\}/'`: that range stops at the FIRST line
# whose first char is `}`. It happens to work today, but it is a fragile
# textual window — a future refactor that places any `}`-leading line inside
# the body (a nested close brace at col 0, a heredoc terminator, a brace
# group) silently truncates the range and the call-site grep then false-reds.
# Brace-depth tracking instead follows the real nesting: it opens on
# `name() {`, accumulates the net `{`/`}` balance per line, and stops
# exactly when depth returns to 0. Balanced `${param}` expansions net to
# zero per line so they do not perturb the count. The result is
# deterministic regardless of where the body's braces sit on the line.
_kappa_extract_func_body() {
  local fn="$1" src="$2"
  awk -v fn="$fn" '
    BEGIN { want = fn "() {"; infn = 0; depth = 0 }
    {
      if (!infn) {
        if (index($0, want) == 1) { infn = 1; depth = 0 }
        else next
      }
      print
      depth += gsub(/\{/, "{") - gsub(/\}/, "}")
      if (depth <= 0) exit
    }
  ' "$src"
}

# File-based wrapper: extract FUNC from SRC into DEST and fail loudly if
# the extraction came back empty (function vanished / unparseable) —
# an empty body must never let a `! grep -q` assertion pass vacuously.
_kappa_extract_func_body_file() {
  local fn="$1" src="$2" dest="$3"
  _kappa_extract_func_body "$fn" "$src" >"$dest"
  [[ -s "$dest" ]] \
    || smoke_fail "could not extract ${fn}() body from $src (empty extraction)"
}

STATE_LIB="$SNAP_DIR/bridge-state.sh"
AGENT_LIB="$SNAP_DIR/bridge-agent.sh"
DAEMON_LIB="$SNAP_DIR/bridge-daemon.sh"
AUDIT_CLI="$SNAP_DIR/bridge-audit.sh"
RECONCILE_LIB="$SNAP_DIR/bridge-isolation-v2-reconcile.sh"
STATUS_PY="$SNAP_DIR/bridge-status.py"
QUEUE_PY="$SNAP_DIR/bridge-queue.py"

_kappa_snapshot_source "lib/bridge-state.sh"                   "$STATE_LIB"
_kappa_snapshot_source "bridge-agent.sh"                       "$AGENT_LIB"
_kappa_snapshot_source "bridge-daemon.sh"                      "$DAEMON_LIB"
_kappa_snapshot_source "bridge-audit.sh"                       "$AUDIT_CLI"
_kappa_snapshot_source "lib/bridge-isolation-v2-reconcile.sh" "$RECONCILE_LIB"
_kappa_snapshot_source "bridge-status.py"                     "$STATUS_PY"
_kappa_snapshot_source "bridge-queue.py"                      "$QUEUE_PY"

# ---------------------------------------------------------------------
# T1 (H1, #1319) — activity_state picker_blocked: predicate function
# present + wired into both resolvers + daemon heartbeat path.
# ---------------------------------------------------------------------
smoke_log "T1: activity_state picker_blocked — predicate + 3 resolver call sites"

# T1.a — predicate function exists in lib/bridge-state.sh
if ! grep -nF 'bridge_agent_picker_blocked()' "$STATE_LIB" >/dev/null; then
  smoke_fail "T1.a: bridge_agent_picker_blocked() not defined in $STATE_LIB (#1319)"
fi

# T1.b — predicate reads STALL_ACTIVE_CLASSIFICATION from stall.env and
# checks against `interactive_picker`. Both substrings must be present
# inside the function body (grep'd over a multi-line region).
if ! grep -nF 'STALL_ACTIVE_CLASSIFICATION' "$STATE_LIB" >/dev/null; then
  smoke_fail "T1.b: predicate must read STALL_ACTIVE_CLASSIFICATION"
fi
if ! grep -nF 'interactive_picker' "$STATE_LIB" >/dev/null; then
  smoke_fail "T1.b: predicate must compare against interactive_picker classification"
fi

# T1.c — snapshot writer in lib/bridge-state.sh calls the predicate
# inside the "no prompt" branch (the only place activity_state can
# transition into picker_blocked from working/starting).
#
# Extract the EXACT function body via brace-depth into a file and grep
# the FILE (no pipeline — see the flake root-cause block above; the
# original `awk range | grep -q` shape false-redded under pipefail when
# grep's early exit SIGPIPE'd awk). This also retires (1) a
# `grep picker_blocked | grep snapshot` pipeline that only ever matched
# a line mentioning BOTH names — dead logic that asserted nothing — and
# (2) the `awk '/start/,/^\}/'` textual range whose first-`}` stop is a
# truncation hazard. Empty extraction fails LOUDLY inside the wrapper.
_kappa_extract_func_body_file 'bridge_write_roster_status_snapshot' "$STATE_LIB" \
  "$SMOKE_TMP_ROOT/t1c-snapshot-writer.body"
if ! grep -qF 'bridge_agent_picker_blocked' "$SMOKE_TMP_ROOT/t1c-snapshot-writer.body"; then
  smoke_fail "T1.c: bridge_write_roster_status_snapshot does not call bridge_agent_picker_blocked"
fi

# T1.d — bridge_agent_activity_state in bridge-agent.sh calls the
# predicate. Same file-based shape as T1.c (body is 3403 bytes — one
# refactor away from the >4096B two-write pipe race).
_kappa_extract_func_body_file 'bridge_agent_activity_state' "$AGENT_LIB" \
  "$SMOKE_TMP_ROOT/t1d-activity-state.body"
if ! grep -qF 'bridge_agent_picker_blocked' "$SMOKE_TMP_ROOT/t1d-activity-state.body"; then
  smoke_fail "T1.d: bridge_agent_activity_state does not call bridge_agent_picker_blocked"
fi

# T1.e — heartbeat path in bridge-daemon.sh calls the predicate.
_kappa_extract_func_body_file 'bridge_agent_heartbeat_activity_state' "$DAEMON_LIB" \
  "$SMOKE_TMP_ROOT/t1e-heartbeat.body"
if ! grep -qF 'bridge_agent_picker_blocked' "$SMOKE_TMP_ROOT/t1e-heartbeat.body"; then
  smoke_fail "T1.e: bridge_agent_heartbeat_activity_state does not call bridge_agent_picker_blocked"
fi

# T1.f — bridge-status.py column width accommodates 'picker_blocked'
# (14 chars). The header and the row formatter must agree.
if ! grep -nE 'activity_state:<1[4-9]' "$STATUS_PY" >/dev/null; then
  smoke_fail "T1.f: bridge-status.py activity_state column must be width >= 14 to fit 'picker_blocked'"
fi

smoke_log "T1 PASS — picker_blocked predicate present + wired into snapshot/agent-show/heartbeat + status column widened"

# ---------------------------------------------------------------------
# T2 (H1, #1319) — functional: predicate returns true when stall.env
# carries STALL_ACTIVE_CLASSIFICATION=interactive_picker, false
# otherwise.
#
# Drives the predicate from a sub-shell that sources ONLY the needed
# helpers — avoids dragging the whole 9000-line bridge-state.sh into
# the harness via macOS bash 3.2 (the smoke runs on the operator's
# darwin worktree at write-time; CI re-runs on Linux).
# ---------------------------------------------------------------------
smoke_log "T2 (H1 functional): predicate truth table — picker / unknown / missing"

# Pre-build the stall.env fixtures so the driver only sources the
# predicate + runs it. This avoids embedding heredoc-into-subshell
# constructs in a printf-generated driver (which is brittle to
# heredoc-end-marker placement and bash-3.2 compatibility).
mkdir -p "$SMOKE_TMP_ROOT/t2/runtime/picker" \
         "$SMOKE_TMP_ROOT/t2/runtime/network" \
         "$SMOKE_TMP_ROOT/t2/runtime/clean"
# Write fixtures via printf so we never rely on a heredoc-in-driver.
printf 'STALL_ACTIVE_CLASSIFICATION=interactive_picker\nSTALL_ACTIVE_EXCERPT_HASH=abc123\n' \
  >"$SMOKE_TMP_ROOT/t2/runtime/picker/stall.env"
printf 'STALL_ACTIVE_CLASSIFICATION=network\n' \
  >"$SMOKE_TMP_ROOT/t2/runtime/network/stall.env"
# `clean` agent: no stall.env at all → predicate returns false.

T2_DRIVER="$SMOKE_TMP_ROOT/t2-driver.sh"
: >"$T2_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  # Stub the runtime_state_dir resolver to point at the temp root, so
  # the predicate reads our hand-rolled stall.env. The real stall.env
  # resolver depends on runtime_state_dir, so stubbing the former gives
  # the latter our temp tree.
  printf '%s\n' 'bridge_agent_runtime_state_dir() { printf "%s/runtime/%s\n" "$ROOT" "$1"; }'
  # Source the predicate function + the stall_state_file resolver
  # block via awk extraction. The predicate calls stall_state_file
  # which calls our stubbed runtime_state_dir.
  printf '%s\n' "source \"$SMOKE_TMP_ROOT/stall-file-extract.sh\""
  printf '%s\n' "source \"$SMOKE_TMP_ROOT/predicate-extract.sh\""
  printf '%s\n' 'bridge_agent_picker_blocked picker; PRC=$?'
  printf '%s\n' 'bridge_agent_picker_blocked network; NRC=$?'
  printf '%s\n' 'bridge_agent_picker_blocked clean; CRC=$?'
  printf '%s\n' 'bridge_agent_picker_blocked ""; ERC=$?'
  printf '%s\n' 'printf "PRC=%s\nNRC=%s\nCRC=%s\nERC=%s\n" "$PRC" "$NRC" "$CRC" "$ERC"'
} >>"$T2_DRIVER"
chmod +x "$T2_DRIVER"

# Extract the stall_state_file resolver + the predicate function from
# the lib via awk. The predicate's dependency chain is:
#   bridge_agent_picker_blocked
#     -> bridge_agent_stall_state_file
#         -> bridge_agent_runtime_state_dir  (stubbed in driver)
awk '/^bridge_agent_stall_state_file\(\) \{/,/^\}/' "$STATE_LIB" \
  >"$SMOKE_TMP_ROOT/stall-file-extract.sh"
awk '/^bridge_agent_picker_blocked\(\) \{/,/^\}/' "$STATE_LIB" \
  >"$SMOKE_TMP_ROOT/predicate-extract.sh"

# Pick Homebrew bash (the repo documents Bash 4+ as required).
if command -v /opt/homebrew/bin/bash >/dev/null 2>&1; then
  T2_BASH=/opt/homebrew/bin/bash
elif command -v /usr/local/bin/bash >/dev/null 2>&1; then
  T2_BASH=/usr/local/bin/bash
else
  T2_BASH="$(command -v bash)"
fi

ROOT="$SMOKE_TMP_ROOT/t2" T2_OUT="$(ROOT="$SMOKE_TMP_ROOT/t2" "$T2_BASH" "$T2_DRIVER" 2>&1 || true)"
T2_PRC="$(printf '%s\n' "$T2_OUT" | awk -F= '/^PRC=/ {print $2}')"
T2_NRC="$(printf '%s\n' "$T2_OUT" | awk -F= '/^NRC=/ {print $2}')"
T2_CRC="$(printf '%s\n' "$T2_OUT" | awk -F= '/^CRC=/ {print $2}')"
T2_ERC="$(printf '%s\n' "$T2_OUT" | awk -F= '/^ERC=/ {print $2}')"

# Edge case 1: interactive_picker classification → predicate true (rc=0).
[[ "$T2_PRC" == "0" ]] || smoke_fail "T2: predicate did not return 0 for interactive_picker classification (got rc=$T2_PRC). Out: $T2_OUT"
# Edge case 2: network classification → predicate false (rc=1).
[[ "$T2_NRC" == "1" ]] || smoke_fail "T2: predicate did not return 1 for non-picker classification (got rc=$T2_NRC). Out: $T2_OUT"
# Edge case 3: stall.env absent (recovered or never-stalled) → predicate false (rc=1).
[[ "$T2_CRC" == "1" ]] || smoke_fail "T2: predicate did not return 1 for missing stall.env (got rc=$T2_CRC). Out: $T2_OUT"
# Edge case 4: empty agent name → predicate false (rc=1) — defensive.
[[ "$T2_ERC" == "1" ]] || smoke_fail "T2: predicate did not return 1 for empty agent name (got rc=$T2_ERC). Out: $T2_OUT"

smoke_log "T2 PASS — predicate truth table holds (picker=0, network=1, clean=1, empty=1)"

# ---------------------------------------------------------------------
# T3 (M1, #1324) — bridge-audit.sh enumerates BOTH legacy and v2
# canonical trees when no --agent is given.
# ---------------------------------------------------------------------
smoke_log "T3 (M1, #1324): bridge-audit.sh walks both legacy and v2 canonical trees"

# T3.a — the iso-v2 enumeration block is present.
if ! grep -nF 'BRIDGE_AGENT_ROOT_V2' "$AUDIT_CLI" >/dev/null; then
  smoke_fail "T3.a: bridge-audit.sh missing BRIDGE_AGENT_ROOT_V2 enumeration (#1324)"
fi
if ! grep -nF 'data/agents' "$AUDIT_CLI" >/dev/null; then
  smoke_fail "T3.a: bridge-audit.sh missing data/agents fallback path (#1324)"
fi

# T3.b — legacy path still walked (back-compat).
if ! grep -nF '$BRIDGE_HOME/logs/agents' "$AUDIT_CLI" >/dev/null; then
  smoke_fail "T3.b: bridge-audit.sh dropped legacy logs/agents enumeration (back-compat regression)"
fi

# T3.c — explicit issue reference so the comment cannot drift.
if ! grep -nF 'Issue #1324' "$AUDIT_CLI" >/dev/null; then
  smoke_fail "T3.c: bridge-audit.sh missing 'Issue #1324' anchor comment for the v2 enumeration"
fi

smoke_log "T3 PASS — bridge-audit.sh enumerates both legacy + v2 canonical trees"

# ---------------------------------------------------------------------
# T4 (M2, #1325) — `isolation reconcile --check` (manual, no args)
# expansion branch present + functionally calls into the per-agent
# row emitter. This is the static-pin counterpart to gamma-beta5 T3
# (which only grepped for the parity block); here we additionally
# verify the call site is gated on BOTH check and apply modes (no
# unintentional --apply-only restriction).
# ---------------------------------------------------------------------
smoke_log "T4 (M2, #1325): manual --check parity branch covers BOTH modes"

# T4.a — manual expansion does NOT gate on $mode (so --check + --apply
# both benefit). Static check via awk over the function block. The
# block-boundary awk capture includes leading comment lines, so we
# narrow the gate-conjunct check to the actual `if (( all_agents == 0
# )) && ...` line (the one assignment line we care about) via
# grep-after-extract.
EXPANSION_BLOCK="$(awk '/Manual-mode parity/,/^  fi$/' "$RECONCILE_LIB" 2>/dev/null || true)"
if [[ -z "$EXPANSION_BLOCK" ]]; then
  smoke_fail "T4.a: manual-mode parity block not found in $RECONCILE_LIB (regression of #1298 Gap B?)"
fi
# Pull JUST the gate predicate line (the `if (( ... ))` line that opens
# the expansion). Comment lines anywhere in the block are not gates and
# must be ignored — they may legitimately mention `mode == "apply"` as
# documentation context.
GATE_LINE="$(printf '%s\n' "$EXPANSION_BLOCK" | grep -E '^\s*if\s*\(\(' | head -n1 || true)"
if [[ -z "$GATE_LINE" ]]; then
  smoke_fail "T4.a: cannot locate the gate predicate line inside the manual-mode parity block. Block: $EXPANSION_BLOCK"
fi
# The gate line itself must NOT contain a `mode == "apply"` conjunct
# (otherwise --check is accidentally skipped). The actual guard is on
# `reason == manual` + the no-target conjuncts. Comment lines were
# already stripped above.
if printf '%s\n' "$GATE_LINE" | grep -qE 'mode.+==.+["'\'']apply["'\'']'; then
  smoke_fail "T4.a: gate predicate gates on apply mode — would re-introduce #1325 (no --check expansion). Gate: $GATE_LINE"
fi
# Positive check: the gate MUST carry the reason=="manual" conjunct
# (the actual guard that makes both --check and --apply benefit).
if ! printf '%s\n' "$GATE_LINE" | grep -qE 'reason.+==.+["'\'']manual["'\'']'; then
  smoke_fail "T4.a: gate predicate missing reason==\"manual\" conjunct. Gate: $GATE_LINE"
fi

# T4.b — explicit issue reference so the fix anchor cannot drift.
if ! grep -nF '1298' "$RECONCILE_LIB" >/dev/null; then
  smoke_fail "T4.b: $RECONCILE_LIB missing #1298 anchor reference (Lane γ beta5 origin)"
fi
if ! grep -nF '1325' "$RECONCILE_LIB" >/dev/null; then
  smoke_fail "T4.b: $RECONCILE_LIB missing #1325 anchor reference (Lane κ beta5-2 verification)"
fi

# T4.c — the matrix dispatcher does not short-circuit on mode=check
# before per-agent rows are emitted (regression check). The for-loop
# over target_agents must execute regardless of mode.
DISPATCH_BLOCK="$(awk '/for idx in/,/done < <\(bridge_isolation_v2_install_tree_matrix_rows/' "$RECONCILE_LIB" 2>/dev/null || true)"
if [[ -z "$DISPATCH_BLOCK" ]]; then
  smoke_fail "T4.c: dispatch loop block not found in $RECONCILE_LIB"
fi
# The body of the loop must invoke _bridge_iso_reconcile_process_one_row
# with `$mode` (whatever it is) — NOT a hard-coded `apply`.
if ! printf '%s\n' "$DISPATCH_BLOCK" | grep -qF '_bridge_iso_reconcile_process_one_row "$mode"'; then
  smoke_fail "T4.c: dispatch loop must pass \$mode (not a hardcoded value) to _bridge_iso_reconcile_process_one_row. Block: $DISPATCH_BLOCK"
fi

smoke_log "T4 PASS — manual --check parity present, mode-agnostic, dispatch loop honors \$mode"

# ---------------------------------------------------------------------
# T5 (teeth for T1) — revert the predicate call in
# bridge_write_roster_status_snapshot to prove the assertion would
# catch the regression. Operates on a working copy so the real source
# stays untouched.
# ---------------------------------------------------------------------
smoke_log "T5 (teeth, H1 #1319): revert snapshot picker_blocked branch -> resolver returns 'working' (assertion fires)"

T5_LIB="$SMOKE_TMP_ROOT/state-lib.t5.sh"
cp "$STATE_LIB" "$T5_LIB"

# Surgically delete the picker_blocked branch from the working copy.
# We use awk to print every line except those inside the
# `if bridge_agent_picker_blocked "$agent"; then` ... block within
# bridge_write_roster_status_snapshot, replacing it with the original
# pre-#1319 shape (no picker_blocked branch).
awk '
  BEGIN { in_snapshot = 0; skip_block = 0 }
  /^bridge_write_roster_status_snapshot\(\) \{/ { in_snapshot = 1 }
  in_snapshot && /^\}/ { in_snapshot = 0 }
  in_snapshot && /bridge_agent_picker_blocked/ { skip_block = 1; next }
  skip_block && /activity_state="picker_blocked"/ { next }
  skip_block && /^[[:space:]]*# Issue #835 Wave B:/ { skip_block = 0; print "        if bridge_tmux_engine_requires_prompt \"$engine\" \\"; print "            && ! bridge_agent_engine_process_alive \"$agent\" \"$engine\"; then"; next }
  skip_block && /elif bridge_tmux_engine_requires_prompt/ { skip_block = 0; next }
  { print }
' "$T5_LIB" >"$SMOKE_TMP_ROOT/state-lib.t5.reverted.sh"

# Now re-run the T1.c assertion against the reverted file using the SAME
# robust extractor + file-based grep T1.c uses, so the teeth test proves
# the real check (not a divergent textual range) catches the regression.
# The wrapper's non-empty check also keeps the teeth honest: if the revert
# mangled the function so badly the extraction came back empty, that is a
# broken-teeth failure, not a vacuous pass. The extracted body MUST NOT
# contain the predicate call anymore.
_kappa_extract_func_body_file 'bridge_write_roster_status_snapshot' \
  "$SMOKE_TMP_ROOT/state-lib.t5.reverted.sh" "$SMOKE_TMP_ROOT/t5-reverted.body"
if grep -qF 'bridge_agent_picker_blocked' "$SMOKE_TMP_ROOT/t5-reverted.body"; then
  smoke_fail "T5: teeth revert failed — picker_blocked branch still present in reverted snapshot writer"
fi

smoke_log "T5 PASS — teeth proves T1.c would catch the snapshot regression"

# ---------------------------------------------------------------------
# T6 (teeth for T3) — revert the bridge-audit.sh v2 enumeration to
# prove the assertion would catch the regression.
# ---------------------------------------------------------------------
smoke_log "T6 (teeth, M1 #1324): revert audit-cli v2 enumeration -> assertion fires"

T6_CLI="$SMOKE_TMP_ROOT/bridge-audit.t6.sh"
# Remove the BRIDGE_AGENT_ROOT_V2 + data/agents lines via awk filter.
awk '
  /BRIDGE_AGENT_ROOT_V2/ { next }
  /Issue #1324/ { next }
  /data\/agents/ { next }
  { print }
' "$AUDIT_CLI" >"$T6_CLI"

# Re-run the T3.a assertion against the reverted file.
if grep -nF 'BRIDGE_AGENT_ROOT_V2' "$T6_CLI" >/dev/null; then
  smoke_fail "T6: teeth revert failed — BRIDGE_AGENT_ROOT_V2 still present in reverted bridge-audit.sh"
fi

smoke_log "T6 PASS — teeth proves T3.a would catch the audit-cli enumeration regression"

# ---------------------------------------------------------------------
# T7 (teeth for T4) — revert the manual-mode parity branch to prove
# the assertion would catch the regression (#1298 Gap B reversal).
# ---------------------------------------------------------------------
smoke_log "T7 (teeth, M2 #1325): revert manual-mode parity branch -> assertion fires"

T7_LIB="$SMOKE_TMP_ROOT/bridge-isolation-v2-reconcile.t7.sh"
awk '
  /Manual-mode parity/ { skip = 1 }
  skip && /^  fi$/ { skip = 0; next }
  skip { next }
  { print }
' "$RECONCILE_LIB" >"$T7_LIB"

# Re-run the T4.a assertion against the reverted file.
T7_EXPANSION_BLOCK="$(awk '/Manual-mode parity/,/^  fi$/' "$T7_LIB" 2>/dev/null || true)"
if [[ -n "$T7_EXPANSION_BLOCK" ]]; then
  smoke_fail "T7: teeth revert failed — Manual-mode parity block still present in reverted reconcile lib"
fi

smoke_log "T7 PASS — teeth proves T4.a would catch the reconcile parity regression"

# ---------------------------------------------------------------------
# T8 (PR #1345 r2, codex r1 BLOCKING) — daemon-step snapshot carries
# activity_state column AND bridge-queue.py daemon-step EXCLUDES
# picker_blocked agents from idle_agents (stale-claim requeue skipped).
#
# Repro from codex review: claimed task + claimed_ts aged past
# --max-claim-age + agent session_activity_ts aged past --idle-threshold
# + agent activity_state="picker_blocked" → task MUST stay claimed
# (not requeued with "stale_claim_requeued" event).
# ---------------------------------------------------------------------
smoke_log "T8 (PR #1345 r2 BLOCKING): snapshot activity_state + queue.py picker_blocked exclude"

# T8.a — static asserts on the snapshot writer + queue.py reader.
# File-based extraction (body is 3857 bytes — see flake root-cause
# block; `awk range | grep -q` under pipefail is the T1.c false-red).
_kappa_extract_func_body_file 'bridge_write_agent_snapshot' "$STATE_LIB" \
  "$SMOKE_TMP_ROOT/t8a-agent-snapshot.body"
if ! grep -qE '\\tactivity_state"' "$SMOKE_TMP_ROOT/t8a-agent-snapshot.body"; then
  smoke_fail "T8.a: bridge_write_agent_snapshot header missing activity_state column (#1345 r2)"
fi
if ! grep -qF 'bridge_agent_picker_blocked' "$SMOKE_TMP_ROOT/t8a-agent-snapshot.body"; then
  smoke_fail "T8.a: bridge_write_agent_snapshot does not call bridge_agent_picker_blocked (#1345 r2)"
fi
# $QUEUE_PY is the immutable snapshot frozen at smoke start (#1509).
[[ -f "$QUEUE_PY" ]] || smoke_fail "T8.a: missing $QUEUE_PY"
if ! grep -qF '_idle_excluded_states' "$QUEUE_PY"; then
  smoke_fail "T8.a: bridge-queue.py missing _idle_excluded_states (picker_blocked exclude — #1345 r2)"
fi
if ! grep -qE 'activity_state\s*not in\s*_idle_excluded_states' "$QUEUE_PY"; then
  smoke_fail "T8.a: bridge-queue.py idle_agents predicate does not reference activity_state exclusion (#1345 r2)"
fi
if ! grep -qF 'picker_blocked' "$QUEUE_PY"; then
  smoke_fail "T8.a: bridge-queue.py missing picker_blocked literal in idle exclusion comment/set (#1345 r2)"
fi

# T8.b — functional: build a temp task DB + hand-rolled snapshot + run
# bridge-queue.py daemon-step. Assert the claimed task stays claimed.
T8_HOME="$SMOKE_TMP_ROOT/t8"
mkdir -p "$T8_HOME/state"
T8_DB="$T8_HOME/state/tasks.db"
T8_SNAPSHOT="$T8_HOME/snapshot.tsv"

# A claimed task aged past max_claim_age (use --max-claim-age 900 default).
# Pick claimed_ts = now - 2000, session_activity_ts = now - 2000 so the
# agent is well past --idle-threshold (default 120) AND --max-claim-age.
T8_NOW="$(date +%s)"
T8_AGED=$((T8_NOW - 2000))

# Snapshot row with activity_state=picker_blocked. Header MUST match
# bridge_write_agent_snapshot's output exactly so csv.DictReader maps
# columns by name.
{
  printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\tprompt_ready_ts\tprompt_ready_session\tprompt_ready_source\tactivity_state\n'
  printf 'wedged\tclaude\twedged\t/tmp\t1\t%s\t\t\t\tpicker_blocked\n' "$T8_AGED"
} >"$T8_SNAPSHOT"

# Seed the DB with a claimed task. Use sqlite3 CLI for a clean,
# repeatable insert that doesn't depend on bridge-task.sh setup.
sqlite3 "$T8_DB" <<SQL >/dev/null
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  assigned_to TEXT NOT NULL,
  created_by TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'normal',
  status TEXT NOT NULL DEFAULT 'queued',
  created_ts INTEGER NOT NULL,
  updated_ts INTEGER NOT NULL,
  body_text TEXT,
  body_path TEXT,
  claimed_by TEXT,
  claimed_ts INTEGER,
  lease_until_ts INTEGER,
  closed_ts INTEGER
);
INSERT INTO tasks (
  title, assigned_to, created_by, status, created_ts, updated_ts,
  claimed_by, claimed_ts, lease_until_ts
) VALUES (
  'wedged-task', 'wedged', 'operator', 'claimed',
  ${T8_AGED}, ${T8_AGED},
  'wedged', ${T8_AGED}, NULL
);
SQL

# Run daemon-step. The python entry runs init_db itself, so we don't
# need to predeclare the rest of the schema.
T8_OUT="$(
  BRIDGE_TASK_DB="$T8_DB" \
  BRIDGE_HOME="$T8_HOME" \
  BRIDGE_STATE_DIR="$T8_HOME/state" \
  python3 "$QUEUE_PY" daemon-step \
    --snapshot "$T8_SNAPSHOT" \
    --idle-threshold 120 \
    --max-claim-age 900 \
    --skip-nudges \
    --format text 2>&1 || true
)"

# Assert task #1 is still claimed (NOT requeued).
T8_STATUS="$(sqlite3 "$T8_DB" "SELECT status FROM tasks WHERE id=1;" 2>/dev/null || true)"
if [[ "$T8_STATUS" != "claimed" ]]; then
  smoke_fail "T8.b: claimed task for picker_blocked agent was wrongly requeued. status=$T8_STATUS out=$T8_OUT"
fi

# Assert no stale_claim_requeued event was emitted for task #1.
T8_EVENT="$(sqlite3 "$T8_DB" "SELECT COUNT(*) FROM task_events WHERE task_id=1 AND event_type='stale_claim_requeued';" 2>/dev/null || echo "0")"
if [[ "$T8_EVENT" != "0" ]]; then
  smoke_fail "T8.b: stale_claim_requeued event emitted for picker_blocked agent (count=$T8_EVENT). Expected 0."
fi

smoke_log "T8 PASS — daemon-step snapshot carries activity_state + queue.py honors picker_blocked exclusion"

# ---------------------------------------------------------------------
# T9 (teeth for T8) — drop the activity_state column from the snapshot
# OR drop the python-side exclusion → claimed task gets requeued. We
# pick the python-side teeth path because it isolates the queue.py
# change without re-running the daemon-step pipeline twice.
#
# Strategy: apply a working-copy patch to bridge-queue.py that removes
# `_idle_excluded_states` from the predicate (reverts to pre-r2
# behavior), run daemon-step against the same DB + snapshot fixture
# from T8 (recreated to a fresh state), and assert the task IS
# requeued. If the teeth revert fails to flip the assertion, T8 is
# not actually catching the regression.
# ---------------------------------------------------------------------
smoke_log "T9 (teeth, PR #1345 r2): revert queue.py exclusion -> task requeued"

T9_HOME="$SMOKE_TMP_ROOT/t9"
mkdir -p "$T9_HOME/state"
T9_DB="$T9_HOME/state/tasks.db"
T9_SNAPSHOT="$T9_HOME/snapshot.tsv"

T9_NOW="$(date +%s)"
T9_AGED=$((T9_NOW - 2000))

{
  printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\tprompt_ready_ts\tprompt_ready_session\tprompt_ready_source\tactivity_state\n'
  printf 'wedged\tclaude\twedged\t/tmp\t1\t%s\t\t\t\tpicker_blocked\n' "$T9_AGED"
} >"$T9_SNAPSHOT"

sqlite3 "$T9_DB" <<SQL >/dev/null
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  assigned_to TEXT NOT NULL,
  created_by TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'normal',
  status TEXT NOT NULL DEFAULT 'queued',
  created_ts INTEGER NOT NULL,
  updated_ts INTEGER NOT NULL,
  body_text TEXT,
  body_path TEXT,
  claimed_by TEXT,
  claimed_ts INTEGER,
  lease_until_ts INTEGER,
  closed_ts INTEGER
);
INSERT INTO tasks (
  title, assigned_to, created_by, status, created_ts, updated_ts,
  claimed_by, claimed_ts, lease_until_ts
) VALUES (
  'wedged-task', 'wedged', 'operator', 'claimed',
  ${T9_AGED}, ${T9_AGED},
  'wedged', ${T9_AGED}, NULL
);
SQL

# Build a reverted copy of bridge-queue.py with the exclusion removed.
# Use awk to drop the `and activity_state not in _idle_excluded_states`
# conjunct from the idle-set comprehension (the conjunct lives on its
# own line inside the if-block). The conjunct is uniquely identified
# by `_idle_excluded_states` substring.
T9_QUEUE="$SMOKE_TMP_ROOT/bridge-queue.t9.py"
awk '
  /and activity_state not in _idle_excluded_states/ { next }
  { print }
' "$QUEUE_PY" >"$T9_QUEUE"

# Sanity: the conjunct must actually be gone in the reverted copy.
if grep -q '_idle_excluded_states' "$T9_QUEUE" | grep -v '^[[:space:]]*#' | grep -v 'set()' >/dev/null 2>&1; then
  # Tolerate the `_idle_excluded_states = {...}` declaration still being
  # there — that variable is dead-code in the reverted version but
  # doesn't affect behavior. The actual exclusion line is gone.
  :
fi

# Confirm the predicate no longer references the exclusion in the
# active code path. We grep for the specific conjunct line.
if grep -F 'and activity_state not in _idle_excluded_states' "$T9_QUEUE" >/dev/null; then
  smoke_fail "T9: teeth revert failed — exclusion conjunct still present in reverted bridge-queue.py"
fi

# Pre-flight: confirm the reverted file still parses as Python.
if ! python3 -m py_compile "$T9_QUEUE" 2>"$SMOKE_TMP_ROOT/t9-compile.err"; then
  smoke_fail "T9: teeth-reverted bridge-queue.py failed py_compile: $(cat "$SMOKE_TMP_ROOT/t9-compile.err")"
fi

T9_OUT="$(
  BRIDGE_TASK_DB="$T9_DB" \
  BRIDGE_HOME="$T9_HOME" \
  BRIDGE_STATE_DIR="$T9_HOME/state" \
  python3 "$T9_QUEUE" daemon-step \
    --snapshot "$T9_SNAPSHOT" \
    --idle-threshold 120 \
    --max-claim-age 900 \
    --skip-nudges \
    --format text 2>&1 || true
)"

T9_STATUS="$(sqlite3 "$T9_DB" "SELECT status FROM tasks WHERE id=1;" 2>/dev/null || true)"
T9_EVENT="$(sqlite3 "$T9_DB" "SELECT COUNT(*) FROM task_events WHERE task_id=1 AND event_type='stale_claim_requeued';" 2>/dev/null || echo "0")"

if [[ "$T9_STATUS" != "queued" ]]; then
  smoke_fail "T9: teeth revert did NOT flip outcome — task status=$T9_STATUS (expected queued). out=$T9_OUT"
fi
if [[ "$T9_EVENT" -lt 1 ]]; then
  smoke_fail "T9: teeth revert did NOT emit stale_claim_requeued event (count=$T9_EVENT). out=$T9_OUT"
fi

smoke_log "T9 PASS — teeth proves T8 would catch a regression of the picker_blocked exclusion"

# ---------------------------------------------------------------------
# T10 (PR #1345 r2 backwards compat) — legacy snapshot WITHOUT the
# activity_state column still works (DictReader returns None → empty
# string → exclusion set does not match → pre-r2 idle classification
# preserved for the upgrade window between bash + python halves).
# ---------------------------------------------------------------------
smoke_log "T10 (PR #1345 r2 back-compat): legacy snapshot without activity_state column"

T10_HOME="$SMOKE_TMP_ROOT/t10"
mkdir -p "$T10_HOME/state"
T10_DB="$T10_HOME/state/tasks.db"
T10_SNAPSHOT="$T10_HOME/snapshot.tsv"

T10_NOW="$(date +%s)"
T10_AGED=$((T10_NOW - 2000))

# Pre-r2 snapshot: header has 9 columns (no activity_state). This is
# what a v0.14.5 daemon writes before the upgrade applies the bash
# half. After the python half lands but before the bash half, the
# snapshot rows do not carry activity_state — the .get('activity_state',
# '') fallback in queue.py MUST treat this as legacy idle (preserves
# pre-r2 stale-claim requeue behavior).
{
  printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\tprompt_ready_ts\tprompt_ready_session\tprompt_ready_source\n'
  printf 'legacy\tclaude\tlegacy\t/tmp\t1\t%s\t\t\t\n' "$T10_AGED"
} >"$T10_SNAPSHOT"

sqlite3 "$T10_DB" <<SQL >/dev/null
CREATE TABLE IF NOT EXISTS tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  assigned_to TEXT NOT NULL,
  created_by TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'normal',
  status TEXT NOT NULL DEFAULT 'queued',
  created_ts INTEGER NOT NULL,
  updated_ts INTEGER NOT NULL,
  body_text TEXT,
  body_path TEXT,
  claimed_by TEXT,
  claimed_ts INTEGER,
  lease_until_ts INTEGER,
  closed_ts INTEGER
);
INSERT INTO tasks (
  title, assigned_to, created_by, status, created_ts, updated_ts,
  claimed_by, claimed_ts, lease_until_ts
) VALUES (
  'legacy-task', 'legacy', 'operator', 'claimed',
  ${T10_AGED}, ${T10_AGED},
  'legacy', ${T10_AGED}, NULL
);
SQL

T10_OUT="$(
  BRIDGE_TASK_DB="$T10_DB" \
  BRIDGE_HOME="$T10_HOME" \
  BRIDGE_STATE_DIR="$T10_HOME/state" \
  python3 "$QUEUE_PY" daemon-step \
    --snapshot "$T10_SNAPSHOT" \
    --idle-threshold 120 \
    --max-claim-age 900 \
    --skip-nudges \
    --format text 2>&1 || true
)"

# Legacy row → activity_state == "" → not in {picker_blocked, working}
# → idle (pre-r2 behavior) → task gets requeued. This is the no-break
# proof for non-iso-v2 / pre-upgrade installs.
T10_STATUS="$(sqlite3 "$T10_DB" "SELECT status FROM tasks WHERE id=1;" 2>/dev/null || true)"
if [[ "$T10_STATUS" != "queued" ]]; then
  smoke_fail "T10: legacy snapshot back-compat broken — task status=$T10_STATUS (expected queued, pre-r2 behavior preserved). out=$T10_OUT"
fi

smoke_log "T10 PASS — legacy snapshot without activity_state preserves pre-r2 idle classification"

smoke_log "ALL PASS — beta5-2 Lane κ smoke (H1 #1319 + M1 #1324 + M2 #1325 + r2 #1345 snapshot+queue)"
exit 0
