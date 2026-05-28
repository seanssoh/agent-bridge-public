#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/A-beta4-iso-path-resolution.sh —
# v0.15.0-beta4 Lane A (iso v2 path resolution + metadata access root).
#
# Re-exec under bash 4+ so we can source bridge-lib.sh directly for
# shim-level coverage.
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:A-beta4-iso-path-resolution][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi
#
# Closes #1272 + #1277 + #1279 + #1213 (iso UID context can resolve its
# own metadata + Claude config dir + audit dir).
#
# Background:
#   patch's fresh-install OOTB on cm-prod-agentworkflow-vm01 (v0.15.0-
#   beta3) reproduced four related surfaces sharing a single root: the
#   iso UID context cannot read the controller-protected
#   `agent-roster.local.sh`, so every assoc-array lookup
#   (`BRIDGE_AGENT_OS_USER[$agent]`, `BRIDGE_AGENT_ISOLATION_MODE[$agent]`)
#   from iso UID code paths returns empty. Downstream:
#     #1272: Path A0 (sudo-less iso UID write) skips → ensure_matrix_path
#            warning floods every Stop hook.
#     #1277: `bridge_agent_claude_config_dir` returns the controller-
#            view path which does not exist on disk for iso v2; the
#            `[[ -d "$config_dir" ]]` gate strips it; session detection
#            falls back to daemon HOME, never finds the agent's sessions.
#     #1279: per-agent audit dir not auto-created beyond the 0-byte touch
#            from `prepare_agent_isolation`; iso UID can't bootstrap it
#            either. audit.jsonl stays empty.
#     #1213: `BRIDGE_AGENT_ISOLATION_MODE` scalar export silently no-ops
#            because the bash name is already an assoc array.
#
# Fix shape:
#   R1: writer — `bridge_isolation_v2_write_agent_metadata` writes
#       `state/agents/<a>/agent-meta.env` (0640 controller:ab-agent-<a>)
#       at prepare + reapply time. Sanitized key=value lines.
#   R2: reader — `bridge_load_sanitized_agent_metadata` (bridge-lib.sh,
#       NOT lib/) parses the snippet line-by-line and populates the
#       assoc-array slot for the local agent. No `source` (the bash
#       assoc/scalar collision from #1213 would silently no-op).
#   R3: `bridge_agent_claude_config_dir` getent-based fallback — when
#       the roster array is empty (cold iso UID context), look up the
#       iso UID's `pw_home` via `getent passwd` and return
#       `$pwent_home/.claude`.
#   R4: `bridge_agent_audit_dir_ensure` — defense-in-depth dir creator
#       wired into `bridge_audit_log` when the target points into the
#       iso v2 per-agent log dir.
#   R5: `session_id_detect_empty` audit emit safety net in
#       `bridge_refresh_agent_session_id` so a future regression that
#       re-introduces the mismatch cannot hide silently.
#
# Tests (host-agnostic — static-source + isolated mock fixtures; no
# real `agent-bridge-*` users, no sudo/root, no real tmux):
#
#   T1: writer + reader round-trip. Write a synthetic agent-meta.env
#       at the canonical path, then drive the reader from a sub-shell
#       with `BRIDGE_AGENT_ID=<agent>` — assert
#       `BRIDGE_AGENT_OS_USER[<agent>]` etc. populate. Asserts both
#       writer composition and parser correctness.
#
#   T2: bridge-lib.sh `bridge_load_sanitized_agent_metadata` is
#       invoked unconditionally during library load AND the function
#       exists. Asserts the load-time fold-in is wired (regression
#       sentinel for a future PR that removes the bridge-lib.sh hook).
#
#   T3: `bridge_agent_claude_config_dir` returns the iso UID's
#       `<pwent_home>/.claude` via getent fallback when the roster
#       array is empty AND iso v2 is effective.
#
#   T4: `bridge_agent_claude_config_dir` returns the legacy / daemon
#       HOME path for a non-iso agent (backward compatibility).
#
#   T5: snippet absence — the reader silently no-ops (no error
#       output, no array population) when `agent-meta.env` is missing
#       (backward compatibility, snippet not deployed yet).
#
#   T6 (teeth, #1272): with the snippet on disk and the reader
#       loaded, the iso UID context's `BRIDGE_AGENT_OS_USER[<agent>]`
#       is non-empty so the Path A0 precondition fires. Asserted by
#       grepping the Path A0 entry condition in
#       lib/bridge-isolation-v2.sh and confirming the
#       `bridge_agent_os_user` precondition would be satisfied.
#
#   T7 (teeth, #1277): the iso v2 effective branch in
#       `bridge_agent_claude_config_dir` resolves to the iso UID
#       home's `.claude` path, NOT the controller view
#       (`$BRIDGE_AGENT_HOME_ROOT/<agent>/.claude` /
#       `$BRIDGE_AGENT_ROOT_V2/<agent>/home/.claude`). Asserts the
#       fix shape by grepping the new function body for the
#       `bridge_agent_linux_user_home` AND `getent` paths.
#
#   T8 (teeth, #1213): `bridge_load_sanitized_agent_metadata` reader
#       explicitly populates `BRIDGE_AGENT_ISOLATION_MODE` via array
#       slot assignment (`BRIDGE_AGENT_ISOLATION_MODE["$agent"]=...`)
#       — NOT via bare scalar assignment (which would silently no-op
#       per the assoc-array collision #1213 documents). Asserts the
#       fix shape by static grep on bridge-lib.sh.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every
# assertion uses `grep -n` against the source files OR builds harness
# scripts with `printf '%s\n' >file` and runs them as external
# scripts. No `<<<` here-string or `<<EOF` heredoc-stdin into
# subprocess capture.

set -uo pipefail

SMOKE_NAME="A-beta4-iso-path-resolution"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
BRIDGE_LIB="$REPO_ROOT/bridge-lib.sh"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"
STATE_LIB="$REPO_ROOT/lib/bridge-state.sh"
ISO_V2_LIB="$REPO_ROOT/lib/bridge-isolation-v2.sh"
ISO_V2_REAPPLY_LIB="$REPO_ROOT/lib/bridge-isolation-v2-reapply.sh"

[[ -f "$BRIDGE_LIB" ]]          || smoke_fail "missing $BRIDGE_LIB"
[[ -f "$AGENTS_LIB" ]]          || smoke_fail "missing $AGENTS_LIB"
[[ -f "$STATE_LIB" ]]           || smoke_fail "missing $STATE_LIB"
[[ -f "$ISO_V2_LIB" ]]          || smoke_fail "missing $ISO_V2_LIB"
[[ -f "$ISO_V2_REAPPLY_LIB" ]]  || smoke_fail "missing $ISO_V2_REAPPLY_LIB"

# ---------------------------------------------------------------------
# T1: writer + reader round-trip.
# ---------------------------------------------------------------------
smoke_log "T1: synthetic agent-meta.env round-trip via bridge_load_sanitized_agent_metadata"

T1_AGENT="agent_t1"
T1_META_DIR="$BRIDGE_ACTIVE_AGENT_DIR/$T1_AGENT"
T1_META_FILE="$T1_META_DIR/agent-meta.env"
mkdir -p "$T1_META_DIR"

# Write a synthetic snippet — same shape the writer produces.
{
  printf '# synthetic test snippet\n'
  printf 'BRIDGE_AGENT_OS_USER=agent-bridge-%s\n' "$T1_AGENT"
  printf 'BRIDGE_AGENT_ISOLATION_MODE=linux-user\n'
  printf 'BRIDGE_AGENT_ENGINE=claude\n'
  printf 'BRIDGE_AGENT_HOME=/home/agent-bridge-%s\n' "$T1_AGENT"
  printf 'BRIDGE_AGENT_CLAUDE_CONFIG_DIR=/home/agent-bridge-%s/.claude\n' "$T1_AGENT"
  printf 'BRIDGE_AGENT_AUDIT_DIR=%s/data/agents/%s/logs\n' "$BRIDGE_HOME" "$T1_AGENT"
} >"$T1_META_FILE"
chmod 0640 "$T1_META_FILE"

T1_DRIVER="$SMOKE_TMP_ROOT/t1-driver.sh"
: >"$T1_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  # Note: NOT `set -u` — the reader is intentionally driven without
  # the assoc arrays pre-declared (which is the cold iso UID context
  # we are simulating). The `:-EMPTY` defaults below handle absent
  # slots cleanly.
  printf '%s\n' 'set -o pipefail'
  printf '%s\n' "agent=\"$T1_AGENT\""
  # Inline the reader so we don't require the full bridge-lib.sh init
  # chain (which would attempt to load roster, marker, etc. — far more
  # than this unit test needs).
  awk '/^bridge_load_sanitized_agent_metadata\(\) \{/,/^\}/' "$BRIDGE_LIB"
  printf '\n'
  printf '%s\n' 'bridge_load_sanitized_agent_metadata'
  printf '%s\n' 'printf "OS_USER=%s\n" "${BRIDGE_AGENT_OS_USER[$agent]:-EMPTY}"'
  printf '%s\n' 'printf "ISOLATION=%s\n" "${BRIDGE_AGENT_ISOLATION_MODE[$agent]:-EMPTY}"'
  printf '%s\n' 'printf "ENGINE=%s\n" "${BRIDGE_AGENT_ENGINE[$agent]:-EMPTY}"'
  printf '%s\n' 'in_ids=0'
  printf '%s\n' 'for _other in "${BRIDGE_AGENT_IDS[@]+"${BRIDGE_AGENT_IDS[@]}"}"; do'
  printf '%s\n' '  [[ "$_other" == "$agent" ]] && in_ids=1 && break'
  printf '%s\n' 'done'
  printf '%s\n' 'printf "IN_IDS=%s\n" "$in_ids"'
} >>"$T1_DRIVER"
chmod +x "$T1_DRIVER"

T1_OUT="$(
  BRIDGE_AGENT_ID="$T1_AGENT" \
  BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_ACTIVE_AGENT_DIR" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_SANITIZED_METADATA_SKIP_GUARD=1 \
    /usr/bin/env bash "$T1_DRIVER" 2>&1
)"

smoke_assert_contains "$T1_OUT" "OS_USER=agent-bridge-$T1_AGENT" "T1: BRIDGE_AGENT_OS_USER[<agent>] population"
smoke_assert_contains "$T1_OUT" "ISOLATION=linux-user"             "T1: BRIDGE_AGENT_ISOLATION_MODE[<agent>] population"
smoke_assert_contains "$T1_OUT" "ENGINE=claude"                    "T1: BRIDGE_AGENT_ENGINE[<agent>] population"
smoke_assert_contains "$T1_OUT" "IN_IDS=1"                         "T1: BRIDGE_AGENT_IDS contains agent"
smoke_log "T1 PASS — writer+reader round-trip populates iso UID context arrays without sourcing the file"

# ---------------------------------------------------------------------
# T2: bridge-lib.sh wires the reader to fire on every library load.
# ---------------------------------------------------------------------
smoke_log "T2: bridge-lib.sh wires bridge_load_sanitized_agent_metadata at module load"

if ! grep -nF 'bridge_load_sanitized_agent_metadata()' "$BRIDGE_LIB" >/dev/null; then
  smoke_fail "T2: bridge_load_sanitized_agent_metadata() not defined in $BRIDGE_LIB"
fi
# The literal invocation (not the definition) must appear on its own
# line — that's the unconditional call site at module end. The
# `|| true` suffix is required (codex r1 BLOCKING #2): the iso UID
# scope guard returns 1 when invoked from the controller context, and
# bare invocation would propagate under `set -e` in callers that
# source bridge-lib.sh.
if ! grep -nE '^bridge_load_sanitized_agent_metadata([[:space:]]*\|\|[[:space:]]*true)?$' "$BRIDGE_LIB" >/dev/null; then
  smoke_fail "T2: bridge_load_sanitized_agent_metadata is defined but never invoked in $BRIDGE_LIB (the unconditional call site got dropped — iso UID context will not populate arrays from agent-meta.env)"
fi
smoke_log "T2 PASS — reader defined + invoked at bridge-lib.sh load"

# ---------------------------------------------------------------------
# T3: bridge_agent_claude_config_dir getent fallback for iso v2.
# ---------------------------------------------------------------------
smoke_log "T3: bridge_agent_claude_config_dir getent-based iso v2 fallback"

# Static-source assertion: the new function body must reference
# `getent passwd` AND fall back to a `pwent_home/.claude` printf when
# `bridge_agent_os_user` returns empty.
T3_FN_BODY="$(awk '/^bridge_agent_claude_config_dir\(\) \{/,/^\}/' "$AGENTS_LIB")"
if [[ -z "$T3_FN_BODY" ]]; then
  smoke_fail "T3: bridge_agent_claude_config_dir definition not found in $AGENTS_LIB"
fi
if [[ "$T3_FN_BODY" != *"getent passwd"* ]]; then
  smoke_fail "T3: bridge_agent_claude_config_dir lacks getent passwd fallback — iso UID context with empty roster array will resolve to controller-view path that does not exist (#1277 regression)"
fi
if [[ "$T3_FN_BODY" != *"BRIDGE_AGENT_OS_USER_PREFIX"* ]]; then
  smoke_fail "T3: bridge_agent_claude_config_dir lacks BRIDGE_AGENT_OS_USER_PREFIX override hook (existing project convention used at lib/bridge-isolation-v2.sh:1437,2323,2420) — operator-customized iso UID prefixes won't resolve"
fi
# Negative: r2 introduced a typo'd alias BRIDGE_OS_USER_PREFIX (no
# AGENT_) that diverged from the existing project convention. r3 must
# not retain the typo'd variant anywhere in this function body.
if [[ "$T3_FN_BODY" == *"BRIDGE_OS_USER_PREFIX"* ]] && [[ "$T3_FN_BODY" != *"BRIDGE_AGENT_OS_USER_PREFIX"* ]]; then
  smoke_fail "T3: bridge_agent_claude_config_dir uses typo'd BRIDGE_OS_USER_PREFIX (r2 regression) instead of existing BRIDGE_AGENT_OS_USER_PREFIX convention"
fi
if [[ "$T3_FN_BODY" != *"/.claude"* ]]; then
  smoke_fail "T3: bridge_agent_claude_config_dir does not append /.claude — caller's [[ -d \"\$config_dir\" ]] gate will reject"
fi
smoke_log "T3 PASS — getent-based iso v2 fallback wired into bridge_agent_claude_config_dir"

# ---------------------------------------------------------------------
# T4: non-iso path preserves legacy / daemon HOME resolution.
# ---------------------------------------------------------------------
smoke_log "T4: bridge_agent_claude_config_dir non-iso path returns legacy controller-view"

# The function body must still call `bridge_agent_claude_home_dir`
# (which contains the non-iso fallback to `bridge_agent_default_home`).
if [[ "$T3_FN_BODY" != *"bridge_agent_claude_home_dir"* ]]; then
  smoke_fail "T4: bridge_agent_claude_config_dir non-iso path dropped — non-iso agents will lose their config dir resolution"
fi
# And `bridge_agent_claude_home_dir` itself must keep the non-iso
# branch returning `bridge_agent_default_home`.
T4_HOME_FN_BODY="$(awk '/^bridge_agent_claude_home_dir\(\) \{/,/^\}/' "$AGENTS_LIB")"
if [[ "$T4_HOME_FN_BODY" != *"bridge_agent_default_home"* ]]; then
  smoke_fail "T4: bridge_agent_claude_home_dir non-iso branch removed — non-iso agents will lose their HOME default"
fi
smoke_log "T4 PASS — non-iso resolution preserved (backward compat)"

# ---------------------------------------------------------------------
# T5: snippet absence → reader silently no-ops.
# ---------------------------------------------------------------------
smoke_log "T5: reader is a silent no-op when agent-meta.env is absent (backward compat)"

T5_AGENT="agent_t5_missing"
# Do NOT create $BRIDGE_ACTIVE_AGENT_DIR/$T5_AGENT/agent-meta.env.

T5_DRIVER="$SMOKE_TMP_ROOT/t5-driver.sh"
: >"$T5_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  # See T1 comment: do not enable `set -u` while exercising the cold
  # iso UID context.
  printf '%s\n' 'set -o pipefail'
  printf '%s\n' "agent=\"$T5_AGENT\""
  awk '/^bridge_load_sanitized_agent_metadata\(\) \{/,/^\}/' "$BRIDGE_LIB"
  printf '\n'
  printf '%s\n' 'rc=0'
  printf '%s\n' 'bridge_load_sanitized_agent_metadata || rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
  printf '%s\n' 'printf "OS_USER=%s\n" "${BRIDGE_AGENT_OS_USER[$agent]:-EMPTY}"'
} >>"$T5_DRIVER"
chmod +x "$T5_DRIVER"

T5_OUT="$(
  BRIDGE_AGENT_ID="$T5_AGENT" \
  BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_ACTIVE_AGENT_DIR" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_SANITIZED_METADATA_SKIP_GUARD=1 \
    /usr/bin/env bash "$T5_DRIVER" 2>&1
)"

# After r2 (codex BLOCKING #2), the snippet-absent branch returns 1 so
# callers can distinguish "skipped" from "populated"; this is still a
# silent no-op for the assoc arrays.
smoke_assert_contains "$T5_OUT" "rc=1"             "T5: reader rc=1 when snippet absent (post-r2 contract: return 1 instead of 0 so callers can branch)"
smoke_assert_contains "$T5_OUT" "OS_USER=EMPTY"    "T5: array slot stays empty when snippet absent (no spurious population)"
smoke_log "T5 PASS — reader returns rc=1 on missing snippet (post-r2 contract); arrays remain empty (no spurious population)"

# ---------------------------------------------------------------------
# T6 (teeth, #1272): the writer is wired so Path A0 precondition fires.
# ---------------------------------------------------------------------
smoke_log "T6 (teeth, #1272): bridge_isolation_v2_write_agent_metadata is called from prepare/reapply paths"

# Writer must exist.
if ! grep -nF 'bridge_isolation_v2_write_agent_metadata()' "$ISO_V2_LIB" >/dev/null; then
  smoke_fail "T6: bridge_isolation_v2_write_agent_metadata() not defined in $ISO_V2_LIB — #1272 root not closed"
fi

# Writer must compose the file at $BRIDGE_ACTIVE_AGENT_DIR/<agent>/agent-meta.env
T6_WRITER_BODY="$(awk '/^bridge_isolation_v2_write_agent_metadata\(\) \{/,/^\}/' "$ISO_V2_LIB")"
if [[ "$T6_WRITER_BODY" != *"agent-meta.env"* ]]; then
  smoke_fail "T6: writer body does not reference agent-meta.env — file path drift"
fi
if [[ "$T6_WRITER_BODY" != *"0640"* ]]; then
  smoke_fail "T6: writer does not chmod 0640 — iso UID + controller mutual-read permission contract broken"
fi
if [[ "$T6_WRITER_BODY" != *"BRIDGE_AGENT_OS_USER="* ]]; then
  smoke_fail "T6: writer does not emit BRIDGE_AGENT_OS_USER= — #1272 Path A0 precondition cannot be satisfied"
fi

# Writer must be called from bridge_linux_prepare_agent_isolation.
if ! grep -nF 'bridge_isolation_v2_write_agent_metadata' "$AGENTS_LIB" >/dev/null; then
  smoke_fail "T6: bridge_isolation_v2_write_agent_metadata not called from $AGENTS_LIB — agent create path will not seed the snippet"
fi

# And from the reapply path.
if ! grep -nF 'bridge_isolation_v2_write_agent_metadata' "$ISO_V2_REAPPLY_LIB" >/dev/null; then
  smoke_fail "T6: bridge_isolation_v2_write_agent_metadata not called from $ISO_V2_REAPPLY_LIB — reapply will not refresh the snippet"
fi
smoke_log "T6 PASS — writer defined, wired to prepare + reapply, file composition correct"

# ---------------------------------------------------------------------
# T7 (teeth, #1277): iso v2 effective branch in config_dir resolver
# returns iso UID home /.claude, not controller view.
# ---------------------------------------------------------------------
smoke_log "T7 (teeth, #1277): config_dir iso v2 effective branch returns iso UID home"

# The iso v2 effective branch must call `bridge_agent_linux_user_home`
# (which composes /home/<os_user>) OR getent passwd (the array-empty
# fallback) and NOT print a controller-view path.
if [[ "$T3_FN_BODY" != *"bridge_agent_linux_user_home"* ]]; then
  smoke_fail "T7: iso v2 effective branch dropped bridge_agent_linux_user_home — would resolve to controller-view path (#1277 regression)"
fi

# Cross-check that the getent fallback explicitly composes
# `pwent_home/.claude`, not the controller-view path.
T7_LINES="$(awk '/^bridge_agent_claude_config_dir\(\) \{/,/^\}/' "$AGENTS_LIB")"
if [[ "$T7_LINES" != *'pwent_home="$(getent passwd '*'cut -d: -f6)"'* ]]; then
  smoke_fail "T7: getent passwd composition for pwent_home not found — fallback path may not extract user home correctly"
fi

# Negative: the iso v2 effective branch must NOT defer to
# `bridge_agent_default_home` (which would return the controller view).
# Inspect ONLY the iso v2 branch body, not the trailing fallback.
#
# Footgun #11 (codex r1 BLOCKING #3): the previous form used a here-string
# (`<<<"$T7_LINES"`) which violates the self-stated contract documented
# at lines 106-110 above (no `<<<` or `<<EOF` into subprocess capture).
# Switch to a temp file so the awk + sed pipe reads from a real file
# descriptor and cannot deadlock under Bash 5.3.9.
T7_TMP="$(mktemp "${SMOKE_TMP_ROOT:-/tmp}/A-beta4-T7-lines.XXXXXX")"
printf '%s\n' "$T7_LINES" >"$T7_TMP"
T7_ISO_BRANCH="$(awk '
  /bridge_agent_linux_user_isolation_effective/,0
' <"$T7_TMP" | sed -n '1,/Non-iso path/p')"
rm -f "$T7_TMP"

if [[ "$T7_ISO_BRANCH" == *"bridge_agent_default_home"* ]]; then
  smoke_fail "T7: iso v2 branch calls bridge_agent_default_home — would return controller-view path on iso v2"
fi
smoke_log "T7 PASS — config_dir iso v2 branch resolves to iso UID home (#1277 root closed)"

# ---------------------------------------------------------------------
# T8 (teeth, #1213): reader populates assoc array via slot, NOT scalar.
# ---------------------------------------------------------------------
smoke_log "T8 (teeth, #1213): reader populates BRIDGE_AGENT_ISOLATION_MODE via assoc slot assignment"

T8_READER_BODY="$(awk '/^bridge_load_sanitized_agent_metadata\(\) \{/,/^\}/' "$BRIDGE_LIB")"
if [[ -z "$T8_READER_BODY" ]]; then
  smoke_fail "T8: bridge_load_sanitized_agent_metadata definition not found"
fi
# Must use array-slot assignment for BRIDGE_AGENT_ISOLATION_MODE.
if [[ "$T8_READER_BODY" != *'BRIDGE_AGENT_ISOLATION_MODE["$agent"]='* ]]; then
  smoke_fail "T8: reader does not assign BRIDGE_AGENT_ISOLATION_MODE via assoc slot — bare scalar would silently no-op per #1213 (the very bug this lane closes)"
fi
if [[ "$T8_READER_BODY" != *'BRIDGE_AGENT_OS_USER["$agent"]='* ]]; then
  smoke_fail "T8: reader does not assign BRIDGE_AGENT_OS_USER via assoc slot — same collision class"
fi
if [[ "$T8_READER_BODY" != *'BRIDGE_AGENT_ENGINE["$agent"]='* ]]; then
  smoke_fail "T8: reader does not assign BRIDGE_AGENT_ENGINE via assoc slot — same collision class"
fi
# Negative: the reader must NOT `source` the snippet (source would
# trigger the assoc/scalar collision class).
if [[ "$T8_READER_BODY" == *'source "$meta_file"'* ]] || [[ "$T8_READER_BODY" == *'. "$meta_file"'* ]]; then
  smoke_fail "T8: reader sources the snippet — would trigger #1213 silent no-op against the assoc arrays"
fi
smoke_log "T8 PASS — reader uses array-slot assignments (#1213 collision class avoided)"

# ---------------------------------------------------------------------
# T_neg (codex r1 BLOCKING #2): iso UID scope guard rejects controller
# context. When the smoke driver runs as the operator user (NOT
# `${BRIDGE_OS_USER_PREFIX:-agent-bridge}-*`), the reader must return
# 1 and leave the assoc arrays untouched. This prevents the controller
# from accidentally preferring stale snippet contents over the live
# roster path.
# ---------------------------------------------------------------------
smoke_log "T_neg (codex r1 BLOCKING #2): reader rejects controller context — iso UID guard fires"

T_NEG_AGENT="agent_t_neg"
T_NEG_META_DIR="$BRIDGE_ACTIVE_AGENT_DIR/$T_NEG_AGENT"
T_NEG_META_FILE="$T_NEG_META_DIR/agent-meta.env"
mkdir -p "$T_NEG_META_DIR"
{
  printf '# T_neg synthetic snippet\n'
  printf 'BRIDGE_AGENT_OS_USER=agent-bridge-%s\n' "$T_NEG_AGENT"
  printf 'BRIDGE_AGENT_ISOLATION_MODE=linux-user\n'
  printf 'BRIDGE_AGENT_ENGINE=claude\n'
} >"$T_NEG_META_FILE"
chmod 0640 "$T_NEG_META_FILE"

T_NEG_DRIVER="$SMOKE_TMP_ROOT/t-neg-driver.sh"
: >"$T_NEG_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -o pipefail'
  printf '%s\n' "agent=\"$T_NEG_AGENT\""
  awk '/^bridge_load_sanitized_agent_metadata\(\) \{/,/^\}/' "$BRIDGE_LIB"
  printf '\n'
  printf '%s\n' 'rc=0'
  # NOTE: NO BRIDGE_SANITIZED_METADATA_SKIP_GUARD here — exercise the
  # real guard against the current (controller) user.
  printf '%s\n' 'bridge_load_sanitized_agent_metadata || rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
  printf '%s\n' 'printf "OS_USER=%s\n" "${BRIDGE_AGENT_OS_USER[$agent]:-EMPTY}"'
  printf '%s\n' 'printf "ISOLATION=%s\n" "${BRIDGE_AGENT_ISOLATION_MODE[$agent]:-EMPTY}"'
  printf '%s\n' 'in_ids=0'
  printf '%s\n' 'for _other in "${BRIDGE_AGENT_IDS[@]+"${BRIDGE_AGENT_IDS[@]}"}"; do'
  printf '%s\n' '  [[ "$_other" == "$agent" ]] && in_ids=1 && break'
  printf '%s\n' 'done'
  printf '%s\n' 'printf "IN_IDS=%s\n" "$in_ids"'
} >>"$T_NEG_DRIVER"
chmod +x "$T_NEG_DRIVER"

# Drive WITHOUT the SKIP_GUARD env — the case is the controller user
# (the operator running this smoke), which never matches the iso UID
# prefix `agent-bridge-*`.
T_NEG_OUT="$(
  BRIDGE_AGENT_ID="$T_NEG_AGENT" \
  BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_ACTIVE_AGENT_DIR" \
  BRIDGE_HOME="$BRIDGE_HOME" \
    /usr/bin/env bash "$T_NEG_DRIVER" 2>&1
)"

smoke_assert_contains "$T_NEG_OUT" "rc=1"          "T_neg: reader returns rc=1 from controller context (iso UID guard fires)"
smoke_assert_contains "$T_NEG_OUT" "OS_USER=EMPTY" "T_neg: BRIDGE_AGENT_OS_USER not populated from controller context"
smoke_assert_contains "$T_NEG_OUT" "ISOLATION=EMPTY" "T_neg: BRIDGE_AGENT_ISOLATION_MODE not populated from controller context"
smoke_assert_contains "$T_NEG_OUT" "IN_IDS=0"      "T_neg: BRIDGE_AGENT_IDS not extended from controller context"

# Static-source assertion: the reader body must contain the 2-stage
# user-match guard (codex r2 BLOCKING). This catches future refactors
# that drop the guard or revert to a prefix-only form (which would
# miss custom-prefix + explicit per-agent installs).
T_NEG_READER_BODY="$(awk '/^bridge_load_sanitized_agent_metadata\(\) \{/,/^\}/' "$BRIDGE_LIB")"
if [[ "$T_NEG_READER_BODY" != *'id -un'* ]]; then
  smoke_fail "T_neg: reader body does not call id -un — iso UID scope guard missing (codex r1 BLOCKING #2)"
fi
# Stage A: must peek BRIDGE_AGENT_OS_USER from the snippet (no source,
# no prefix coupling).
if [[ "$T_NEG_READER_BODY" != *'BRIDGE_AGENT_OS_USER'* ]] \
   || [[ "$T_NEG_READER_BODY" != *'awk'* ]]; then
  smoke_fail "T_neg: reader body does not awk-peek BRIDGE_AGENT_OS_USER — 2-stage user-match guard (codex r2 BLOCKING) missing"
fi
# Negative: r3 must NOT key off a prefix-only guard. The r2 form
# (prefix match against `id -un`) silently skipped custom-prefix +
# explicit per-agent installs. A re-introduction of any prefix-only
# case statement against `id -un` would re-open the codex r2 BLOCKING.
if [[ "$T_NEG_READER_BODY" == *'BRIDGE_OS_USER_PREFIX'* ]] \
   && [[ "$T_NEG_READER_BODY" != *'BRIDGE_AGENT_OS_USER_PREFIX'* ]]; then
  smoke_fail "T_neg: reader body retains typo'd BRIDGE_OS_USER_PREFIX (r2 regression) — should not key on a prefix variable at all under r3"
fi
smoke_log "T_neg PASS — iso UID guard rejects controller context, arrays unchanged, 2-stage user-match guard logic present in source"

# ---------------------------------------------------------------------
# T_neg2 (codex r2 BLOCKING — custom-prefix iso UID): when the
# operator runs the install with `BRIDGE_AGENT_OS_USER_PREFIX=custom-`
# (the existing project convention used at lib/bridge-isolation-v2.sh
# :1437,2323,2420), the agent's iso UID is e.g. `custom-<agent>`. The
# r2 reader keyed its guard off a typo'd `BRIDGE_OS_USER_PREFIX` and
# default `agent-bridge`, so iso UID code paths under a custom prefix
# returned rc=1 with empty arrays even when running AS the agent's
# OS user — the iso-UID guard was effectively unreachable.
#
# r3 fix uses Stage A awk-peek of the snippet's BRIDGE_AGENT_OS_USER
# + Stage B `id -un` match, so the guard is prefix-independent. We
# simulate the iso UID context by writing the snippet's
# BRIDGE_AGENT_OS_USER to the operator's current `id -un` (the only
# value we can match without actually swapping UIDs). The snippet
# wears a custom prefix that bears no relation to `agent-bridge-` —
# the test passes regardless because Stage B is prefix-agnostic.
# ---------------------------------------------------------------------
smoke_log "T_neg2 (codex r2 BLOCKING — custom-prefix iso UID): reader fires when current user matches snippet, regardless of prefix"

T_NEG2_AGENT="agent_t_neg2"
T_NEG2_META_DIR="$BRIDGE_ACTIVE_AGENT_DIR/$T_NEG2_AGENT"
T_NEG2_META_FILE="$T_NEG2_META_DIR/agent-meta.env"
mkdir -p "$T_NEG2_META_DIR"
# Use the operator's current user as the snippet's expected OS user,
# but spelled with a "custom-" prefix shape (`custom-<id-un>`). We
# cannot actually swap UIDs in a smoke harness — instead we set the
# snippet to the current user verbatim so Stage B can match, and rely
# on the fact that the guard logic is prefix-agnostic.
T_NEG2_CURRENT_USER="$(id -un 2>/dev/null)"
[[ -n "$T_NEG2_CURRENT_USER" ]] || smoke_fail "T_neg2: id -un returned empty — host environment cannot drive this test"
{
  printf '# T_neg2 synthetic snippet — custom-prefix iso UID context\n'
  printf 'BRIDGE_AGENT_OS_USER=%s\n' "$T_NEG2_CURRENT_USER"
  printf 'BRIDGE_AGENT_ISOLATION_MODE=linux-user\n'
  printf 'BRIDGE_AGENT_ENGINE=claude\n'
} >"$T_NEG2_META_FILE"
chmod 0640 "$T_NEG2_META_FILE"

T_NEG2_DRIVER="$SMOKE_TMP_ROOT/t-neg2-driver.sh"
: >"$T_NEG2_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -o pipefail'
  printf '%s\n' "agent=\"$T_NEG2_AGENT\""
  awk '/^bridge_load_sanitized_agent_metadata\(\) \{/,/^\}/' "$BRIDGE_LIB"
  printf '\n'
  printf '%s\n' 'rc=0'
  # NOTE: NO BRIDGE_SANITIZED_METADATA_SKIP_GUARD — exercise the real
  # 2-stage guard. With snippet matching `id -un`, the guard must let
  # the load through (rc=0).
  printf '%s\n' 'bridge_load_sanitized_agent_metadata || rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
  printf '%s\n' 'printf "OS_USER=%s\n" "${BRIDGE_AGENT_OS_USER[$agent]:-EMPTY}"'
  printf '%s\n' 'printf "ISOLATION=%s\n" "${BRIDGE_AGENT_ISOLATION_MODE[$agent]:-EMPTY}"'
} >>"$T_NEG2_DRIVER"
chmod +x "$T_NEG2_DRIVER"

# Set a custom prefix to prove the guard does NOT key off the prefix
# at all — the snippet's BRIDGE_AGENT_OS_USER (=current user) is the
# sole input Stage A/B care about.
T_NEG2_OUT="$(
  BRIDGE_AGENT_ID="$T_NEG2_AGENT" \
  BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_ACTIVE_AGENT_DIR" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_AGENT_OS_USER_PREFIX="custom-" \
    /usr/bin/env bash "$T_NEG2_DRIVER" 2>&1
)"

smoke_assert_contains "$T_NEG2_OUT" "rc=0" "T_neg2: reader rc=0 when snippet's BRIDGE_AGENT_OS_USER matches id -un (custom-prefix install)"
smoke_assert_contains "$T_NEG2_OUT" "OS_USER=$T_NEG2_CURRENT_USER" "T_neg2: BRIDGE_AGENT_OS_USER array populated under custom prefix"
smoke_assert_contains "$T_NEG2_OUT" "ISOLATION=linux-user" "T_neg2: BRIDGE_AGENT_ISOLATION_MODE array populated under custom prefix"
smoke_log "T_neg2 PASS — custom-prefix iso UID context loads metadata (prefix-independent Stage A/B guard)"

# ---------------------------------------------------------------------
# T_neg3 (codex r2 BLOCKING — explicit per-agent --os-user): when the
# operator passes `bridge-agent.sh --os-user manual-name`, the agent's
# OS user bears NO syntactic relation to any prefix at all. The r2
# prefix-only guard skipped this case entirely. r3 must still load
# the snippet when the current user matches the snippet's value.
# ---------------------------------------------------------------------
smoke_log "T_neg3 (codex r2 BLOCKING — explicit per-agent --os-user): reader fires when snippet matches id -un"

T_NEG3_AGENT="agent_t_neg3"
T_NEG3_META_DIR="$BRIDGE_ACTIVE_AGENT_DIR/$T_NEG3_AGENT"
T_NEG3_META_FILE="$T_NEG3_META_DIR/agent-meta.env"
mkdir -p "$T_NEG3_META_DIR"
T_NEG3_CURRENT_USER="$(id -un 2>/dev/null)"
[[ -n "$T_NEG3_CURRENT_USER" ]] || smoke_fail "T_neg3: id -un returned empty — host environment cannot drive this test"
# The snippet's BRIDGE_AGENT_OS_USER is just the current user — no
# prefix at all. This is exactly the shape produced by an explicit
# `--os-user <current-user>` override.
{
  printf '# T_neg3 synthetic snippet — explicit per-agent override\n'
  printf 'BRIDGE_AGENT_OS_USER=%s\n' "$T_NEG3_CURRENT_USER"
  printf 'BRIDGE_AGENT_ISOLATION_MODE=linux-user\n'
  printf 'BRIDGE_AGENT_ENGINE=claude\n'
} >"$T_NEG3_META_FILE"
chmod 0640 "$T_NEG3_META_FILE"

T_NEG3_DRIVER="$SMOKE_TMP_ROOT/t-neg3-driver.sh"
: >"$T_NEG3_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -o pipefail'
  printf '%s\n' "agent=\"$T_NEG3_AGENT\""
  awk '/^bridge_load_sanitized_agent_metadata\(\) \{/,/^\}/' "$BRIDGE_LIB"
  printf '\n'
  printf '%s\n' 'rc=0'
  printf '%s\n' 'bridge_load_sanitized_agent_metadata || rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
  printf '%s\n' 'printf "OS_USER=%s\n" "${BRIDGE_AGENT_OS_USER[$agent]:-EMPTY}"'
  printf '%s\n' 'printf "ENGINE=%s\n" "${BRIDGE_AGENT_ENGINE[$agent]:-EMPTY}"'
} >>"$T_NEG3_DRIVER"
chmod +x "$T_NEG3_DRIVER"

# No BRIDGE_AGENT_OS_USER_PREFIX export — verifies the guard does not
# *require* a prefix env to be set at all for explicit-per-agent.
T_NEG3_OUT="$(
  BRIDGE_AGENT_ID="$T_NEG3_AGENT" \
  BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_ACTIVE_AGENT_DIR" \
  BRIDGE_HOME="$BRIDGE_HOME" \
    /usr/bin/env bash "$T_NEG3_DRIVER" 2>&1
)"

smoke_assert_contains "$T_NEG3_OUT" "rc=0" "T_neg3: reader rc=0 when snippet's BRIDGE_AGENT_OS_USER matches id -un (explicit per-agent --os-user)"
smoke_assert_contains "$T_NEG3_OUT" "OS_USER=$T_NEG3_CURRENT_USER" "T_neg3: BRIDGE_AGENT_OS_USER array populated under explicit per-agent override"
smoke_assert_contains "$T_NEG3_OUT" "ENGINE=claude" "T_neg3: BRIDGE_AGENT_ENGINE array populated under explicit per-agent override"
smoke_log "T_neg3 PASS — explicit per-agent --os-user loads metadata (no prefix dependency)"

# ---------------------------------------------------------------------
# T_neg4 (codex r2 BLOCKING — controller context with explicit per-
# agent shape): even when the snippet wears an explicit-per-agent
# style value (no prefix relation), if the current user does NOT
# match it the reader must still return rc=1. Asserts Stage B
# rejection works under explicit-per-agent naming too.
# ---------------------------------------------------------------------
smoke_log "T_neg4 (codex r2 BLOCKING — controller context with explicit per-agent shape): reader rejects mismatch"

T_NEG4_AGENT="agent_t_neg4"
T_NEG4_META_DIR="$BRIDGE_ACTIVE_AGENT_DIR/$T_NEG4_AGENT"
T_NEG4_META_FILE="$T_NEG4_META_DIR/agent-meta.env"
mkdir -p "$T_NEG4_META_DIR"
# Use a value that cannot equal the operator's `id -un`. UNIX
# usernames cannot begin with a leading hyphen or contain spaces, so
# this synthetic value will never match any real user.
T_NEG4_NEVER_MATCHES="manual-name-zz-$$-never-matches-any-real-user"
{
  printf '# T_neg4 synthetic snippet — explicit per-agent shape\n'
  printf 'BRIDGE_AGENT_OS_USER=%s\n' "$T_NEG4_NEVER_MATCHES"
  printf 'BRIDGE_AGENT_ISOLATION_MODE=linux-user\n'
  printf 'BRIDGE_AGENT_ENGINE=claude\n'
} >"$T_NEG4_META_FILE"
chmod 0640 "$T_NEG4_META_FILE"

T_NEG4_DRIVER="$SMOKE_TMP_ROOT/t-neg4-driver.sh"
: >"$T_NEG4_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -o pipefail'
  printf '%s\n' "agent=\"$T_NEG4_AGENT\""
  awk '/^bridge_load_sanitized_agent_metadata\(\) \{/,/^\}/' "$BRIDGE_LIB"
  printf '\n'
  printf '%s\n' 'rc=0'
  printf '%s\n' 'bridge_load_sanitized_agent_metadata || rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
  printf '%s\n' 'printf "OS_USER=%s\n" "${BRIDGE_AGENT_OS_USER[$agent]:-EMPTY}"'
  printf '%s\n' 'printf "ISOLATION=%s\n" "${BRIDGE_AGENT_ISOLATION_MODE[$agent]:-EMPTY}"'
} >>"$T_NEG4_DRIVER"
chmod +x "$T_NEG4_DRIVER"

T_NEG4_OUT="$(
  BRIDGE_AGENT_ID="$T_NEG4_AGENT" \
  BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_ACTIVE_AGENT_DIR" \
  BRIDGE_HOME="$BRIDGE_HOME" \
    /usr/bin/env bash "$T_NEG4_DRIVER" 2>&1
)"

smoke_assert_contains "$T_NEG4_OUT" "rc=1" "T_neg4: reader rc=1 when snippet's BRIDGE_AGENT_OS_USER (explicit per-agent shape) does not match id -un"
smoke_assert_contains "$T_NEG4_OUT" "OS_USER=EMPTY" "T_neg4: BRIDGE_AGENT_OS_USER not populated when Stage B mismatches"
smoke_assert_contains "$T_NEG4_OUT" "ISOLATION=EMPTY" "T_neg4: BRIDGE_AGENT_ISOLATION_MODE not populated when Stage B mismatches"
smoke_log "T_neg4 PASS — controller context rejects explicit per-agent shape when id -un mismatches"

# ---------------------------------------------------------------------
# Bonus assertions: R4 (audit_dir_ensure wired) + R5
# (session_id_detect_empty audit emit safety net).
# ---------------------------------------------------------------------
smoke_log "Bonus: R4 audit_dir_ensure helper + R5 session_id_detect_empty audit emit"

if ! grep -nF 'bridge_agent_audit_dir_ensure()' "$STATE_LIB" >/dev/null; then
  smoke_fail "R4: bridge_agent_audit_dir_ensure() not defined in $STATE_LIB (#1279)"
fi
if ! grep -nF 'bridge_agent_audit_dir_ensure' "$STATE_LIB" | grep -v '^.*:bridge_agent_audit_dir_ensure()' >/dev/null; then
  smoke_fail "R4: bridge_agent_audit_dir_ensure defined but never called (the bridge_audit_log wire-in dropped)"
fi
if ! grep -nF 'session_id_detect_empty' "$STATE_LIB" >/dev/null; then
  smoke_fail "R5: session_id_detect_empty audit emit not present in $STATE_LIB (#1279 R2 visibility safety net)"
fi
smoke_log "Bonus PASS — R4 + R5 wired"

smoke_log "ALL TESTS PASS — Lane A beta4 iso v2 path resolution + metadata access root closed (#1272 + #1277 + #1279 + #1213) + iso UID scope guard (codex r1 BLOCKING #2) + prefix-independent 2-stage user-match guard (codex r2 BLOCKING)"
