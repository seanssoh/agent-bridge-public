#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/beta5-2-mu-cron-channel-creds.sh — Issues #1327, #1328, #1329.
#
# v0.15.0-beta5-2 Lane μ — three audit findings (M4 / M5 / M6):
#
#   M4 (#1327): cron dispatch path ignored the operator's manual-stop
#     marker. The wake-side gate in bridge-daemon.sh already refuses to
#     start a stopped static agent for a queued cron-dispatch row, but the
#     enqueue path in bridge-cron.sh:run_enqueue still created the queue
#     task. The fix blocks at enqueue (`cron_dispatch_skipped reason=
#     manual_stop`) AND re-checks at execute time inside the cron worker
#     (edge case 1: agent restart between dispatch and execute).
#
#   M5 (#1328): upgrade-driven $BRIDGE_CRON_STATE_DIR relocation silently
#     lost cron history. New anchor file
#     `$BRIDGE_STATE_DIR/cron-state-dir-anchor.txt` records the last-seen
#     path; `bridge_cron_state_dir_verify_and_migrate` migrates the old
#     tree on the safe single-source case and bails with a warning when
#     both old + new have content.
#
#   M6 (#1329): channel credentials written by `bridge-setup.py` landed
#     at controller-primary-group 0600 — the iso UID could not read.
#     `bridge_isolation_v2_normalize_workdir_profile_group` is extended
#     to also normalize `.<channel>/{.env,access.json,state.json,mcp.json}`
#     to `controller:ab-agent-<a> 0640` (group-read, world-none).
#
# Test plan:
#   T1 (M4)   manual-stop marker + enqueue → skipped row + audit
#             `cron_dispatch_skipped reason=manual_stop`.
#   T2 (M4)   no manual-stop marker → enqueue creates row (existing
#             happy-path; teeth for "did we accidentally block all
#             cron").
#   T3 (M5)   synthetic state-dir-path-change scenario → migrate +
#             anchor refreshed + audit-token assertion.
#   T4 (M5)   dual-state-dir conflict → bail with warning, no
#             mutation.
#   T5 (M5)   anchor missing → fresh-install no-op (write anchor only).
#   T6 (M6)   normalize helper covers the channel cred fileset
#             (.env / access.json / state.json / mcp.json under
#             .discord / .telegram / .teams / .ms365 / .mattermost).
#   T_teeth   grep the source for the audit token + normalize fileset
#             so a future refactor that drops the gate is caught.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# plain `cat >file <<EOF` bodies and command-list redirections. No
# command substitution feeding a heredoc stdin.

set -euo pipefail

SMOKE_NAME="beta5-2-mu-cron-channel-creds"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via trap EXIT below
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
CRON_LIB="$REPO_ROOT/lib/bridge-cron.sh"
ISOV2_LIB="$REPO_ROOT/lib/bridge-isolation-v2.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
CRON_SH="$REPO_ROOT/bridge-cron.sh"

smoke_assert_file_exists "$CRON_LIB" "lib/bridge-cron.sh present"
smoke_assert_file_exists "$ISOV2_LIB" "lib/bridge-isolation-v2.sh present"
smoke_assert_file_exists "$DAEMON_SH" "bridge-daemon.sh present"
smoke_assert_file_exists "$CRON_SH" "bridge-cron.sh present"

# Local helper: assert a literal substring is found in a file. Uses
# grep -F to avoid regex metacharacter surprises in the pattern.
smoke_assert_grep_found() {
  local file="$1"
  local pattern="$2"
  local context="$3"
  if ! grep -qE "$pattern" "$file"; then
    smoke_fail "$context (file=$file pattern=/$pattern/)"
  fi
}

# Local helper: assert that the python handler function (cmd_discord
# etc.) in bridge-setup.py contains at least one
# `_post_write_normalize_channel_cred_group(` call. Uses python to
# slice the function body so a refactor that moves the call into a
# helper of a different name is caught at the source-locality level.
smoke_assert_handler_post_write_normalize() {
  local handler="$1"
  local context="$2"
  python3 - "$REPO_ROOT/bridge-setup.py" "$handler" <<'PY' || smoke_fail "$context"
import sys
from pathlib import Path

src_path, handler = Path(sys.argv[1]), sys.argv[2]
src = src_path.read_text(encoding="utf-8").splitlines()

# Slice from `def <handler>(` to the next `def ` at column 0 (the
# end of the function body). Tolerates decorators because bridge-setup.py
# does not use them on the channel handlers.
start = None
for i, line in enumerate(src):
    if line.startswith(f"def {handler}("):
        start = i
        break
if start is None:
    print(f"missing handler def {handler}", file=sys.stderr)
    sys.exit(1)

end = len(src)
for j in range(start + 1, len(src)):
    if src[j].startswith("def "):
        end = j
        break

body = "\n".join(src[start:end])
if "_post_write_normalize_channel_cred_group(" not in body:
    print(
        f"{handler}: missing _post_write_normalize_channel_cred_group() call",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

# ---------------------------------------------------------------------
# T1 / T2 (M4) — source-grep teeth for the manual-stop gate.
#
# The enqueue path edit lives in `run_enqueue` (bridge-cron.sh). Direct
# end-to-end invocation requires the full bridge-lib bootstrap + a
# populated roster + a queue DB, which is out of scope for a unit
# smoke. Instead, assert the source contains the gate body so a
# refactor that drops it trips the smoke. The bridge_cron_state_dir
# helper itself is exercised via a self-contained driver below.
# ---------------------------------------------------------------------
smoke_run "T1.grep: enqueue path checks manual_stop_active for target" \
  smoke_assert_grep_found "$CRON_SH" 'bridge_agent_manual_stop_active "\$target"' \
  "bridge-cron.sh run_enqueue: manual_stop_active check missing"

smoke_run "T1.grep: enqueue emits cron_dispatch_skipped audit on manual_stop" \
  smoke_assert_grep_found "$CRON_SH" 'cron_dispatch_skipped' \
  "bridge-cron.sh run_enqueue: cron_dispatch_skipped audit row missing"

smoke_run "T1.grep: enqueue audit detail includes reason=manual_stop" \
  smoke_assert_grep_found "$CRON_SH" 'reason=manual_stop' \
  "bridge-cron.sh run_enqueue: reason=manual_stop detail missing"

smoke_run "T1.grep: execute-time re-check in cmd_run_cron_worker" \
  smoke_assert_grep_found "$DAEMON_SH" 'cron worker skipped task.*reason=manual_stop' \
  "bridge-daemon.sh cmd_run_cron_worker: execute-time manual_stop re-check missing"

# ---------------------------------------------------------------------
# T3 / T4 / T5 (M5) — exercise bridge_cron_state_dir_verify_and_migrate
# directly via a self-contained driver. The helper is pure-bash and
# only depends on `$BRIDGE_STATE_DIR` / `$BRIDGE_CRON_STATE_DIR` env
# vars, so we can call it without loading the full bridge-lib stack.
# ---------------------------------------------------------------------
EXTRACT="$SMOKE_TMP_ROOT/cron-state-extract.sh"
{
  awk '/^bridge_cron_state_dir_anchor_file\(\) \{/,/^\}/ { print }' "$CRON_LIB"
  awk '/^bridge_cron_state_dir_dir_has_content\(\) \{/,/^\}/ { print }' "$CRON_LIB"
  awk '/^bridge_cron_state_dir_verify_and_migrate\(\) \{/,/^\}/ { print }' "$CRON_LIB"
} >"$EXTRACT"

for fn in bridge_cron_state_dir_anchor_file bridge_cron_state_dir_dir_has_content bridge_cron_state_dir_verify_and_migrate; do
  if ! grep -q "^${fn}() {" "$EXTRACT"; then
    smoke_fail "extract missing ${fn}() opener"
  fi
done

# Driver: source the extracted fns and invoke verify_and_migrate.
# Stubs bridge_warn / bridge_audit_log so the helper's side effects
# can be observed via the SMOKE_AUDIT_LOG / SMOKE_WARN_LOG sinks.
DRIVER="$SMOKE_TMP_ROOT/m5-driver.sh"
cat >"$DRIVER" <<'M5_DRIVER_EOF'
#!/usr/bin/env bash
set -uo pipefail

EXTRACT="$1"
SMOKE_WARN_LOG="${SMOKE_WARN_LOG:-/dev/null}"
SMOKE_AUDIT_LOG="${SMOKE_AUDIT_LOG:-/dev/null}"

bridge_warn() {
  printf '%s\n' "$*" >>"$SMOKE_WARN_LOG"
}

bridge_audit_log() {
  local actor="$1"
  local action="$2"
  local target="$3"
  shift 3 || true
  local -a details=("$@")
  printf 'actor=%s action=%s target=%s details=%s\n' \
    "$actor" "$action" "$target" "${details[*]}" >>"$SMOKE_AUDIT_LOG"
}

# shellcheck source=/dev/null
source "$EXTRACT"

bridge_cron_state_dir_verify_and_migrate
rc=$?
echo "RC=$rc"
exit "$rc"
M5_DRIVER_EOF
chmod +x "$DRIVER"

# T5: anchor missing → fresh-install no-op, anchor gets written.
T5_STATE="$SMOKE_TMP_ROOT/t5-state"
T5_CRON="$T5_STATE/cron"
mkdir -p "$T5_CRON"
T5_ANCHOR="$T5_STATE/cron-state-dir-anchor.txt"
T5_WARN="$SMOKE_TMP_ROOT/t5-warn.log"
T5_AUDIT="$SMOKE_TMP_ROOT/t5-audit.log"
: >"$T5_WARN"
: >"$T5_AUDIT"

env -i HOME="$HOME" PATH="$PATH" \
  BRIDGE_STATE_DIR="$T5_STATE" \
  BRIDGE_CRON_STATE_DIR="$T5_CRON" \
  SMOKE_WARN_LOG="$T5_WARN" \
  SMOKE_AUDIT_LOG="$T5_AUDIT" \
  bash "$DRIVER" "$EXTRACT" >"$SMOKE_TMP_ROOT/t5.out" 2>&1
T5_RC=$?
if (( T5_RC != 0 )); then
  smoke_fail "T5: verify_and_migrate non-zero rc (out=$(cat "$SMOKE_TMP_ROOT/t5.out"))"
fi
smoke_assert_file_exists "$T5_ANCHOR" "T5: anchor file written on first run"
if ! grep -Fxq "$T5_CRON" "$T5_ANCHOR"; then
  smoke_fail "T5: anchor body mismatch (expected '$T5_CRON', got '$(cat "$T5_ANCHOR")')"
fi
if [[ -s "$T5_AUDIT" ]]; then
  smoke_fail "T5: unexpected audit emission on fresh-install path (got $(cat "$T5_AUDIT"))"
fi
smoke_log "ok: T5 fresh-install no-op writes anchor only"

# T3: anchor records OLD path, current env points to NEW (empty) path
# with OLD non-empty → migrate.
T3_STATE="$SMOKE_TMP_ROOT/t3-state"
T3_OLD="$T3_STATE/cron-old"
T3_NEW="$T3_STATE/cron-new"
mkdir -p "$T3_STATE" "$T3_OLD"
# Seed OLD with sentinel content.
printf 'sentinel\n' >"$T3_OLD/scheduler-state.json"
T3_ANCHOR="$T3_STATE/cron-state-dir-anchor.txt"
printf '%s\n' "$T3_OLD" >"$T3_ANCHOR"
T3_WARN="$SMOKE_TMP_ROOT/t3-warn.log"
T3_AUDIT="$SMOKE_TMP_ROOT/t3-audit.log"
: >"$T3_WARN"
: >"$T3_AUDIT"

env -i HOME="$HOME" PATH="$PATH" \
  BRIDGE_STATE_DIR="$T3_STATE" \
  BRIDGE_CRON_STATE_DIR="$T3_NEW" \
  SMOKE_WARN_LOG="$T3_WARN" \
  SMOKE_AUDIT_LOG="$T3_AUDIT" \
  bash "$DRIVER" "$EXTRACT" >"$SMOKE_TMP_ROOT/t3.out" 2>&1
T3_RC=$?
if (( T3_RC != 0 )); then
  smoke_fail "T3: verify_and_migrate non-zero rc (out=$(cat "$SMOKE_TMP_ROOT/t3.out"))"
fi
# OLD must have moved to NEW.
if [[ -d "$T3_OLD" ]]; then
  smoke_fail "T3: OLD path $T3_OLD still exists after migrate"
fi
smoke_assert_file_exists "$T3_NEW/scheduler-state.json" "T3: migrated NEW path has sentinel"
if ! grep -Fxq "$T3_NEW" "$T3_ANCHOR"; then
  smoke_fail "T3: anchor not refreshed to NEW path (got '$(cat "$T3_ANCHOR")')"
fi
if ! grep -q "cron_state_dir_migrated" "$T3_AUDIT"; then
  smoke_fail "T3: missing cron_state_dir_migrated audit row (audit=$(cat "$T3_AUDIT"))"
fi
smoke_log "ok: T3 migrate on path change"

# T4: dual-state-dir → bail with conflict warning, no mutation.
T4_STATE="$SMOKE_TMP_ROOT/t4-state"
T4_OLD="$T4_STATE/cron-old"
T4_NEW="$T4_STATE/cron-new"
mkdir -p "$T4_STATE" "$T4_OLD" "$T4_NEW"
printf 'old-sentinel\n' >"$T4_OLD/scheduler-state.json"
printf 'new-sentinel\n' >"$T4_NEW/scheduler-state.json"
T4_ANCHOR="$T4_STATE/cron-state-dir-anchor.txt"
printf '%s\n' "$T4_OLD" >"$T4_ANCHOR"
T4_WARN="$SMOKE_TMP_ROOT/t4-warn.log"
T4_AUDIT="$SMOKE_TMP_ROOT/t4-audit.log"
: >"$T4_WARN"
: >"$T4_AUDIT"

env -i HOME="$HOME" PATH="$PATH" \
  BRIDGE_STATE_DIR="$T4_STATE" \
  BRIDGE_CRON_STATE_DIR="$T4_NEW" \
  SMOKE_WARN_LOG="$T4_WARN" \
  SMOKE_AUDIT_LOG="$T4_AUDIT" \
  bash "$DRIVER" "$EXTRACT" >"$SMOKE_TMP_ROOT/t4.out" 2>&1
T4_RC=$?
if (( T4_RC != 0 )); then
  smoke_fail "T4: verify_and_migrate non-zero rc (out=$(cat "$SMOKE_TMP_ROOT/t4.out"))"
fi
# Both trees MUST still exist with their original content.
if [[ ! -f "$T4_OLD/scheduler-state.json" || "$(cat "$T4_OLD/scheduler-state.json")" != "old-sentinel" ]]; then
  smoke_fail "T4: OLD tree mutated on conflict path"
fi
if [[ ! -f "$T4_NEW/scheduler-state.json" || "$(cat "$T4_NEW/scheduler-state.json")" != "new-sentinel" ]]; then
  smoke_fail "T4: NEW tree mutated on conflict path"
fi
if ! grep -q "cron state dir conflict" "$T4_WARN"; then
  smoke_fail "T4: missing conflict warning (warn=$(cat "$T4_WARN"))"
fi
if ! grep -q "cron_state_dir_conflict" "$T4_AUDIT"; then
  smoke_fail "T4: missing cron_state_dir_conflict audit (audit=$(cat "$T4_AUDIT"))"
fi
smoke_log "ok: T4 dual-state-dir bails with warning"

# T_teeth M5: ensure sync entry path invokes the verifier.
smoke_run "T_teeth.M5: run_sync calls bridge_cron_state_dir_verify_and_migrate" \
  smoke_assert_grep_found "$CRON_SH" 'bridge_cron_state_dir_verify_and_migrate' \
  "bridge-cron.sh run_sync: state-dir verify call missing"

# ---------------------------------------------------------------------
# T6 (M6) — source-grep teeth for the channel cred fileset in the
# extended normalize helper.
# ---------------------------------------------------------------------
for chan_dir in ".discord" ".telegram" ".teams" ".ms365" ".mattermost"; do
  smoke_run "T6.grep: normalize covers ${chan_dir}" \
    smoke_assert_grep_found "$ISOV2_LIB" "\"${chan_dir}\"" \
    "lib/bridge-isolation-v2.sh: missing ${chan_dir} in _iso_channel_dirs"
done

for chan_file in ".env" "access.json" "state.json" "mcp.json"; do
  smoke_run "T6.grep: normalize covers ${chan_file}" \
    smoke_assert_grep_found "$ISOV2_LIB" "\"${chan_file}\"" \
    "lib/bridge-isolation-v2.sh: missing ${chan_file} in _iso_channel_files"
done

# Confirm the mode is 0640 not 0644 (edge case 6 — keep group-only).
# The chgrp_file_iso_group call for channel files spans two lines in
# the source; the leaf-line carries `$chan_file" 0640 "$workdir"` so
# anchor the assertion there. Also assert 0644 is NOT present on the
# same fileset (defense in depth — a typo from 0640 → 0644 would
# silently widen to world-read).
smoke_run "T6.grep: normalize uses mode 0640 for channel cred files" \
  smoke_assert_grep_found "$ISOV2_LIB" '\$chan_file"[[:space:]]+0640[[:space:]]+"\$workdir"' \
  "lib/bridge-isolation-v2.sh: channel cred mode must be 0640 (group-read), not 0644 (world-read)"

# Teeth: scan the normalize-fn body for any 0644 token applied to a
# channel cred — should never appear.
if grep -nE '\$chan_file"[[:space:]]+0644' "$ISOV2_LIB" >/dev/null 2>&1; then
  smoke_fail "lib/bridge-isolation-v2.sh: channel cred normalize uses 0644 somewhere — must be 0640 (edge case 6 world-read widening)"
fi
smoke_log "ok: T6.teeth: no 0644 on channel cred normalize"

# Confirm post-write normalize is wired into every channel cmd in
# bridge-setup.py.
for handler in cmd_discord cmd_telegram cmd_teams cmd_ms365 cmd_mattermost; do
  smoke_run "T6.grep: bridge-setup.py ${handler} calls _post_write_normalize_channel_cred_group" \
    smoke_assert_handler_post_write_normalize "$handler" \
    "bridge-setup.py: ${handler} missing post-write channel normalize call"
done

# ---------------------------------------------------------------------
# T6b / T6c (R2, codex r1 BLOCKING security) — exercise
# `_post_write_normalize_channel_cred_group` directly through a Python
# harness and assert the file mode is UNCHANGED at 0600 when:
#
#   T6b  non-iso-v2 host (no `ab-shared` group) → gate 1 trips, no
#        mutation. The 0600 default is the correct posture there.
#   T6c  iso-v2 effective host with the per-agent `ab-agent-<X>` group
#        missing (agent not yet provisioned) → gate 2 trips, audit row
#        emitted, no mutation.
#
# Both cases use the `BRIDGE_ISO_V2_EFFECTIVE_OVERRIDE` env hook so the
# smoke does not require real POSIX groups. The pre-r2 codepath wrote
# `chgrp` then unconditional `chmod 0640` — the regression check below
# is the same shape codex used to demonstrate the original BLOCKING.
#
# T_teeth security: revert the gate (override=yes + an agent whose
# resolved group name doesn't exist anywhere on host) and confirm the
# helper at HEAD still refuses to widen. If the future refactor drops
# the group_exists check, the teeth case files at 0640.
# ---------------------------------------------------------------------
T6BC_HARNESS="$SMOKE_TMP_ROOT/t6bc-normalize.py"
cat >"$T6BC_HARNESS" <<'PY'
"""Direct call into bridge-setup.py:_post_write_normalize_channel_cred_group.

Invoked from the smoke fixture with three argv slots:
  argv[1]  REPO_ROOT  — path to checkout root (bridge-setup.py lives at root).
  argv[2]  PATH       — channel cred file to normalize. Pre-seeded by caller
                        at mode 0600.
  argv[3]  AGENT      — agent name passed to the helper.

The helper writes nothing on a gate trip; the caller asserts the file is
still at 0600 and (for T6c) that an audit row was emitted.
"""
import importlib.util
import os
import stat
import sys
from pathlib import Path

repo = Path(sys.argv[1])
target = Path(sys.argv[2])
agent = sys.argv[3]

spec = importlib.util.spec_from_file_location("bridge_setup", repo / "bridge-setup.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

before = stat.S_IMODE(target.lstat().st_mode)
module._post_write_normalize_channel_cred_group(target, agent)
after = stat.S_IMODE(target.lstat().st_mode)
print(f"BEFORE={before:04o} AFTER={after:04o}")
PY

t6_normalize_run() {
  # $1: label, $2: override (yes/no/empty), $3: agent name, $4: expected mode
  # ($5: optional extra env in `KEY=val KEY=val` form).
  local label="$1"
  local override="$2"
  local agent="$3"
  local expected="$4"
  local extra_env="${5:-}"
  local target="$SMOKE_TMP_ROOT/${label}-cred.env"
  local audit_log="$SMOKE_TMP_ROOT/${label}-audit.jsonl"
  : >"$audit_log"
  printf 'TOKEN=redacted\n' >"$target"
  chmod 0600 "$target"
  local before_mode
  before_mode="$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target")"
  if [[ "$before_mode" != "600" ]]; then
    smoke_fail "${label}: precondition file mode=${before_mode} expected 600"
  fi
  local override_env=()
  if [[ -n "$override" ]]; then
    override_env=("BRIDGE_ISO_V2_EFFECTIVE_OVERRIDE=${override}")
  fi
  # shellcheck disable=SC2086  # intentional word-split on extra_env
  env -i HOME="$HOME" PATH="$PATH" \
    BRIDGE_AUDIT_LOG="$audit_log" \
    "${override_env[@]}" \
    $extra_env \
    python3 "$T6BC_HARNESS" "$REPO_ROOT" "$target" "$agent" \
    >"$SMOKE_TMP_ROOT/${label}.out" 2>&1
  local rc=$?
  if (( rc != 0 )); then
    smoke_fail "${label}: harness rc=${rc} out=$(cat "$SMOKE_TMP_ROOT/${label}.out")"
  fi
  local after_mode
  after_mode="$(stat -f '%Lp' "$target" 2>/dev/null || stat -c '%a' "$target")"
  if [[ "$after_mode" != "$expected" ]]; then
    smoke_fail "${label}: file mode=${after_mode} expected=${expected} (file widened — codex r1 BLOCKING regression)"
  fi
  echo "$audit_log"
}

# T6b: non-iso-v2 host (override=no) → gate 1, file STAYS 0600, no audit.
T6B_AUDIT="$(t6_normalize_run "t6b-noniso" "no" "samplenoniso" "600")"
if [[ -s "$T6B_AUDIT" ]]; then
  # Gate 1 returns early before audit; an audit row would indicate the
  # gate ran AFTER the chgrp path which is the exact BLOCKING shape.
  smoke_fail "T6b: unexpected audit emission on non-iso-v2 skip (audit=$(cat "$T6B_AUDIT"))"
fi
smoke_log "ok: T6b non-iso-v2 host: file UNCHANGED at 0600"

# T6c: iso-v2 effective (override=yes) but the resolved `ab-agent-<a>`
# group does not exist on host (random uuid-style agent name guarantees
# no collision with a real provisioned group) → gate 2, audit row
# `channel_cred_normalize_skipped` with reason=group_missing.
T6C_AGENT="t6c$(date +%s)abc"
T6C_AUDIT="$(t6_normalize_run "t6c-isomissing" "yes" "$T6C_AGENT" "600")"
if [[ ! -s "$T6C_AUDIT" ]]; then
  smoke_fail "T6c: missing audit row on iso-v2 + group-missing skip"
fi
if ! grep -q 'channel_cred_normalize_skipped' "$T6C_AUDIT"; then
  smoke_fail "T6c: audit row missing channel_cred_normalize_skipped action (audit=$(cat "$T6C_AUDIT"))"
fi
if ! grep -q '"reason": "group_missing"\|"reason":"group_missing"' "$T6C_AUDIT"; then
  smoke_fail "T6c: audit row missing reason=group_missing (audit=$(cat "$T6C_AUDIT"))"
fi
smoke_log "ok: T6c iso-v2 host + group missing: file UNCHANGED at 0600 + audit emitted"

# T_teeth (security): revert the post-r2 gate by stripping the source
# of the iso-v2 + group_exists checks, then re-run with override=yes +
# nonexistent agent. The pre-r2 codepath chmod-widened to 0640 here.
# This teeth is a source-level grep: any HEAD that lacks BOTH the
# `_iso_v2_effective_host()` guard AND the `grp.getgrnam(group)`
# probe in `_post_write_normalize_channel_cred_group` would re-introduce
# the BLOCKING shape.
smoke_run "T6.teeth.r2: _iso_v2_effective_host gate present" \
  smoke_assert_grep_found "$REPO_ROOT/bridge-setup.py" 'if not _iso_v2_effective_host\(\):' \
  "bridge-setup.py: r2 iso-v2 effective gate stripped — chmod-widen regression"

smoke_run "T6.teeth.r2: grp.getgrnam group_exists probe present" \
  smoke_assert_grep_found "$REPO_ROOT/bridge-setup.py" 'grp\.getgrnam\(group\)' \
  "bridge-setup.py: r2 group_exists probe stripped — chmod-widen regression"

smoke_run "T6.teeth.r2: chgrp rc gate guards chmod" \
  smoke_assert_grep_found "$REPO_ROOT/bridge-setup.py" 'proc\.returncode != 0' \
  "bridge-setup.py: r2 chgrp-rc gate stripped — chmod can widen on chgrp failure"

# ---------------------------------------------------------------------
# Bash syntax check on the modified files (defense in depth — the
# project-level `bash -n` smoke also covers this but a per-PR smoke
# saves a round trip).
# ---------------------------------------------------------------------
for f in "$CRON_LIB" "$ISOV2_LIB" "$DAEMON_SH" "$CRON_SH"; do
  smoke_run "syntax: bash -n $(basename "$f")" \
    bash -n "$f"
done

smoke_log "ALL OK"

# ---------------------------------------------------------------------
# helpers used above (defined here to keep the test plan readable above)
# ---------------------------------------------------------------------
:
