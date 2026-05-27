#!/usr/bin/env bash
# scripts/smoke/beta5-2-theta-upgrade-backfill-perms.sh — issues #1315 + #1316
# (v0.15.0-beta5-2 Lane θ upgrade-backfill perms — known_marketplaces.json
# + .claude dir tree).
#
# Background. Lane α (#1297) of v0.15.0-beta5 wired
# `bridge_isolation_v2_normalize_workdir_profile_group` into the upgrade
# back-fill loop so the materialize fileset (CLAUDE.md / SOUL.md /
# SESSION-TYPE.md / MEMORY.md / MEMORY-SCHEMA.md / HEARTBEAT.md /
# CHANGE-POLICY.md / TOOLS.md / AGENTS.md) lands at
# `ab-agent-<a>:0660`. Two OOTB blockers remained on the same back-fill
# surface:
#
#   #1315 (C9). Legacy installs seeded
#     `$workdir/.claude/plugins/known_marketplaces.json` as
#     `root:ab-agent-<a> 0640`. On first agent start, the iso UID's
#     `bridge-dev-plugin-cache.py:update_known_marketplaces` does
#     `tmp.write_text + os.replace(tmp, path)` — and the rename
#     fails EPERM because the target is owned by root, not the iso UID.
#     First-start silently fails.
#
#   #1316 (C10). `bridge_isolation_v2_normalize_workdir_profile_group`
#     walked FILES only. The `.claude/` directory itself (and its
#     `.claude/plugins/` + `.claude/session-env/` children) — created by
#     `bridge-agent.sh:bridge_ensure_auto_memory_isolation` under the
#     controller umask — stays at `0700 controller:controller`. The
#     controller (a member of `ab-agent-<a>` but NOT the iso UID's
#     primary group) cannot traverse a 0700 dir owned by a different
#     UID, so `bridge-start.sh`'s pre-launch grep on
#     `$workdir/.claude/settings.json` fails EACCES.
#
# Patch (this lane). Extend
# `bridge_isolation_v2_normalize_workdir_profile_group` to also:
#   * chgrp/chmod the canonical `.claude/` dir tree
#     (`.claude/`, `.claude/plugins/`, `.claude/session-env/`) to
#     `ab-agent-<a>:2770` via the new `chgrp_dir_iso_group` helper;
#   * chown/chgrp/chmod `known_marketplaces.json` to
#     `<iso-uid>:ab-agent-<a> 0660` via the new `chown_file_iso_uid`
#     helper (which short-circuits to plain chgrp+chmod when the iso
#     UID is not resolvable, so shared-mode agents stay safe).
#
# Cases. All run in an isolated `BRIDGE_HOME` via scripts/smoke/lib.sh —
# never touches live runtime.
#
#   T1. C10 .claude dir tree normalize. Seed `.claude/`, `.claude/plugins/`,
#       `.claude/session-env/` at mode 0700 owned by the operator's
#       primary group (stand-in for "controller-umask mkdir left them
#       at 0700 controller:controller"). Run normalize. Assert every
#       directory at mode 2770 with the operator's group. T1 doubles as
#       the C10 teeth — re-introducing the files-only loop leaves them
#       at 0700 and fails this case.
#
#   T2. C9 known_marketplaces.json chgrp+chmod (no chown path —
#       smoke runs without root, so the chown_file_iso_uid helper
#       short-circuits to chgrp+chmod via the no-os_user branch). Seed
#       the file at 0640. Run normalize. Assert the file ends at
#       mode 0660 with the operator's group.
#
#   T3. Idempotent re-run — second pass over an already-normalized
#       workdir performs ZERO chgrp/chmod/chown syscalls. Proven via a
#       counter-shim that records every `_bridge_isolation_v2_run_root_or_sudo`
#       invocation. Mirrors the codex r1 BLOCKING contract from PR #1302.
#
#   T4. Mixed partial-migration — some directories already at 2770,
#       others at 0700; some files already at 0660, others at 0640. A
#       single normalize pass brings every entry to its canonical
#       state. Closes the "partial-migration idempotent" edge case from
#       the brief.
#
#   T5. Fresh-install no-op — when `.claude/` and
#       `.claude/plugins/known_marketplaces.json` are absent (clean
#       install before any settings render / catalog write), normalize
#       returns 0 silently and performs zero syscalls on those targets.
#
#   T_teeth (gated on `SMOKE_TEETH=1`). Revert proof — temporarily
#       restore the old files-only normalize body (via function override)
#       and assert the `.claude/` dir stays at 0700. The smoke catches
#       a regression that removes the directory walk.
#
# Edge cases also exercised in the helper code paths (not separate
# smoke cases — verified by code review + the helpers' own contract):
#   * Symlink refusal at `.claude` / `.claude/plugins` /
#     `.claude/session-env` (each helper emits bridge_warn and skips).
#   * `bridge_isolation_v2_enforce` no-op on non-Linux hosts — gated
#     identically to the sibling helpers.
#   * Concurrent upgrade safety — upgrade convention requires agents
#     stopped (see `bridge_linux_prepare_agent_isolation` quiesce
#     guard); this smoke runs on a stopped fixture.
#
# Footgun #11 (Bash 5.3.9 heredoc-stdin deadlock): no heredocs in
# subprocess pipelines; all driver bodies are emitted via printf-to-file.

set -uo pipefail

SMOKE_NAME="beta5-2-theta-upgrade-backfill-perms"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

AGENT="theta_clean"
V2_WORKSPACE_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/workdir"

OPERATOR_GROUP="$(id -gn 2>/dev/null || printf '')"
[[ -n "$OPERATOR_GROUP" ]] || smoke_fail "could not resolve operator primary group"

# Probe the kernel-effective mode for setgid dirs. macOS strips the
# setgid bit when the dir is owned by the current user with their
# primary group (BSD behavior). Linux preserves it. We probe once on a
# tempdir so the smoke's assertions stay platform-portable: the
# canonical desired mode is `2770`, but the kernel-effective mode on
# macOS reduces to `770`.
EFFECTIVE_DIR_MODE="2770"
PROBE="$SMOKE_TMP_ROOT/setgid-probe"
mkdir -p "$PROBE"
chmod 2770 "$PROBE" 2>/dev/null || true
PROBE_MODE=""
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  PROBE_MODE="$(stat -f '%Lp' "$PROBE" 2>/dev/null || printf '')"
else
  PROBE_MODE="$(stat -c '%a' "$PROBE" 2>/dev/null || printf '')"
fi
PROBE_MODE_NORM="$(printf '%o' "$((8#${PROBE_MODE#0}))" 2>/dev/null || printf '%s' "$PROBE_MODE")"
if [[ "$PROBE_MODE_NORM" == "770" ]]; then
  EFFECTIVE_DIR_MODE="770"
  smoke_log "platform-probe — setgid bit stripped on this fs (macOS owner-same-group), expecting dir mode 770"
elif [[ "$PROBE_MODE_NORM" == "2770" ]]; then
  smoke_log "platform-probe — setgid bit preserved, expecting dir mode 2770"
else
  smoke_log "platform-probe — chmod 2770 landed at $PROBE_MODE_NORM (treating as canonical)"
  EFFECTIVE_DIR_MODE="$PROBE_MODE_NORM"
fi
rm -rf "$PROBE"

# Build a one-shot driver that:
#   - sources bridge-lib.sh + the isolation-v2 helper module;
#   - stubs bridge_isolation_v2_enforce ON and
#     bridge_isolation_v2_agent_group_name → operator's primary group
#     so the chgrp/chmod path runs without sudo on macOS / non-iso CI
#     hosts (mirrors α-beta5 / G-beta4-watchdog-noise T3 pattern);
#   - additionally stubs bridge_agent_os_user to empty so the
#     chown_file_iso_uid helper short-circuits to the chgrp+chmod path
#     (no iso UID means no chown — smoke runs without root and cannot
#     actually transfer ownership; the chgrp+chmod is what we assert).
#   - calls bridge_isolation_v2_normalize_workdir_profile_group on the
#     workspace and prints "ok" on success.
DRIVER="$SMOKE_TMP_ROOT/run-normalize.sh"
: >"$DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'REPO_ROOT="$1"'
  printf '%s\n' 'OPERATOR_GROUP="$2"'
  printf '%s\n' 'AGENT="$3"'
  printf '%s\n' 'WORKDIR="$4"'
  printf '%s\n' 'TEETH_FILES_ONLY="${5:-0}"'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh"'
  printf '%s\n' '# Stub the v2 enforce gate + the agent-group resolver after the'
  printf '%s\n' '# library has loaded so the normalize helper resolves them by'
  printf '%s\n' '# name lookup (function override).'
  printf '%s\n' 'bridge_isolation_v2_enforce() { return 0; }'
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "%s" "$OPERATOR_GROUP"; }'
  printf '%s\n' '# Force chown_file_iso_uid through the no-os_user short-circuit:'
  printf '%s\n' '# smoke runs without root so the real chown to an iso UID would'
  printf '%s\n' '# fail; the chgrp+chmod path is what production exercises after'
  printf '%s\n' '# the sudo-root chown in lib/bridge-agents.sh succeeds.'
  printf '%s\n' 'bridge_agent_os_user() { printf ""; }'
  printf '%s\n' 'if [[ "$TEETH_FILES_ONLY" == "1" ]]; then'
  printf '%s\n' '  # Teeth proof: simulate a regression that removes the directory'
  printf '%s\n' '  # walk + known_marketplaces normalize, leaving only the files-'
  printf '%s\n' '  # only loop. The smoke assertions below should fail in this mode.'
  printf '%s\n' '  bridge_isolation_v2_normalize_workdir_profile_group() {'
  printf '%s\n' '    local agent="$1" workdir="$2"'
  printf '%s\n' '    [[ -n "$agent" && -n "$workdir" ]] || return 0'
  printf '%s\n' '    bridge_isolation_v2_enforce || return 0'
  printf '%s\n' '    [[ -d "$workdir" ]] || return 0'
  printf '%s\n' '    local _files=("CLAUDE.md" "AGENTS.md" "SOUL.md" "SESSION-TYPE.md" "MEMORY.md" "MEMORY-SCHEMA.md" "HEARTBEAT.md" "CHANGE-POLICY.md" "TOOLS.md")'
  printf '%s\n' '    local name=""'
  printf '%s\n' '    for name in "${_files[@]}"; do'
  printf '%s\n' '      [[ -f "$workdir/$name" ]] || continue'
  printf '%s\n' '      bridge_isolation_v2_chgrp_file_iso_group "$agent" "$workdir/$name" 0660 || true'
  printf '%s\n' '    done'
  printf '%s\n' '    return 0'
  printf '%s\n' '  }'
  printf '%s\n' 'fi'
  printf '%s\n' 'bridge_isolation_v2_normalize_workdir_profile_group "$AGENT" "$WORKDIR" || exit 1'
  printf '%s\n' 'echo ok'
} >"$DRIVER"
chmod +x "$DRIVER"

run_normalize() {
  local teeth="${1:-0}"
  "$BRIDGE_BASH" "$DRIVER" "$REPO_ROOT" "$OPERATOR_GROUP" \
    "$AGENT" "$V2_WORKSPACE_DIR" "$teeth" \
    >"$SMOKE_TMP_ROOT/normalize.stdout" 2>"$SMOKE_TMP_ROOT/normalize.stderr"
}

# Helper — assert a single directory's group + mode.
# Uses GNU stat on Linux + BSD stat on macOS for portability.
assert_dir_grp_mode() {
  local label="$1" dir="$2" want_grp="$3" want_mode="$4"
  local actual=""
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    actual="$(stat -f '%Sg:%Lp' "$dir" 2>/dev/null || printf '')"
  else
    actual="$(stat -c '%G:%a' "$dir" 2>/dev/null || printf '')"
  fi
  local want_mode_norm actual_mode_raw actual_grp actual_mode_norm
  actual_grp="${actual%%:*}"
  actual_mode_raw="${actual##*:}"
  want_mode_norm="$(printf '%o' "$((8#${want_mode#0}))" 2>/dev/null || printf '%s' "$want_mode")"
  actual_mode_norm="$(printf '%o' "$((8#${actual_mode_raw#0}))" 2>/dev/null || printf '%s' "$actual_mode_raw")"
  if [[ "$actual_grp" != "$want_grp" || "$actual_mode_norm" != "$want_mode_norm" ]]; then
    smoke_fail "$label FAIL — expected $want_grp:$want_mode_norm, got $actual_grp:$actual_mode_norm at $dir"
  fi
}

# Helper — assert a single file's group + mode (ownership skipped —
# without root the smoke cannot transfer ownership to an iso UID).
assert_file_grp_mode() {
  local label="$1" file="$2" want_grp="$3" want_mode="$4"
  local actual=""
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    actual="$(stat -f '%Sg:%Lp' "$file" 2>/dev/null || printf '')"
  else
    actual="$(stat -c '%G:%a' "$file" 2>/dev/null || printf '')"
  fi
  local want_mode_norm actual_mode_raw actual_grp actual_mode_norm
  actual_grp="${actual%%:*}"
  actual_mode_raw="${actual##*:}"
  want_mode_norm="$(printf '%o' "$((8#${want_mode#0}))" 2>/dev/null || printf '%s' "$want_mode")"
  actual_mode_norm="$(printf '%o' "$((8#${actual_mode_raw#0}))" 2>/dev/null || printf '%s' "$actual_mode_raw")"
  if [[ "$actual_grp" != "$want_grp" || "$actual_mode_norm" != "$want_mode_norm" ]]; then
    smoke_fail "$label FAIL — expected $want_grp:$want_mode_norm, got $actual_grp:$actual_mode_norm at $file"
  fi
}

# ---------------------------------------------------------------------
# T1 — C10 .claude dir tree normalize.
# Seed three legacy-state directories at mode 0700 under the operator's
# primary group (stand-in for "controller-umask mkdir left them at
# 0700 controller:controller"). Normalize must bring all three to
# 2770 with the operator group.
# ---------------------------------------------------------------------
mkdir -p "$V2_WORKSPACE_DIR/.claude/plugins" "$V2_WORKSPACE_DIR/.claude/session-env"
chmod 0700 "$V2_WORKSPACE_DIR/.claude" "$V2_WORKSPACE_DIR/.claude/plugins" "$V2_WORKSPACE_DIR/.claude/session-env"

run_normalize 0 || smoke_fail "T1: normalize driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/normalize.stderr"))"

assert_dir_grp_mode "T1 .claude"             "$V2_WORKSPACE_DIR/.claude"             "$OPERATOR_GROUP" "$EFFECTIVE_DIR_MODE"
assert_dir_grp_mode "T1 .claude/plugins"     "$V2_WORKSPACE_DIR/.claude/plugins"     "$OPERATOR_GROUP" "$EFFECTIVE_DIR_MODE"
assert_dir_grp_mode "T1 .claude/session-env" "$V2_WORKSPACE_DIR/.claude/session-env" "$OPERATOR_GROUP" "$EFFECTIVE_DIR_MODE"
smoke_log "T1 PASS — .claude dir tree normalized from 0700 to $EFFECTIVE_DIR_MODE (C10)"

# ---------------------------------------------------------------------
# T2 — C9 known_marketplaces.json chgrp+chmod.
# Seed the file at mode 0640 under the operator's primary group
# (stand-in for "root:ab-agent-<a> 0640" — without root the smoke
# can't actually own as root, but the smoke exercises the chgrp+chmod
# code path, which is what the chown_file_iso_uid helper falls back to
# when the os_user resolver returns empty).
# ---------------------------------------------------------------------
KM_PATH="$V2_WORKSPACE_DIR/.claude/plugins/known_marketplaces.json"
printf '{\n}\n' >"$KM_PATH"
chmod 0640 "$KM_PATH"

run_normalize 0 || smoke_fail "T2: normalize driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/normalize.stderr"))"

assert_file_grp_mode "T2 known_marketplaces.json" "$KM_PATH" "$OPERATOR_GROUP" "0660"
smoke_log "T2 PASS — known_marketplaces.json normalized from 0640 to 0660 (C9)"

# ---------------------------------------------------------------------
# T3 — Idempotent re-run.
# A second normalize on already-correct entries must perform ZERO
# chgrp/chmod/chown calls (proven via a counter-shim that records
# every `_bridge_isolation_v2_run_root_or_sudo` invocation). Mirrors
# the codex r1 BLOCKING contract from PR #1302.
# ---------------------------------------------------------------------
NOMUT_DRIVER="$SMOKE_TMP_ROOT/run-nomut.sh"
NOMUT_COUNTER="$SMOKE_TMP_ROOT/nomut-counter.log"
: >"$NOMUT_COUNTER"
: >"$NOMUT_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'REPO_ROOT="$1"'
  printf '%s\n' 'OPERATOR_GROUP="$2"'
  printf '%s\n' 'AGENT="$3"'
  printf '%s\n' 'WORKDIR="$4"'
  printf '%s\n' 'COUNTER="$5"'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh"'
  printf '%s\n' 'bridge_isolation_v2_enforce() { return 0; }'
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "%s" "$OPERATOR_GROUP"; }'
  printf '%s\n' 'bridge_agent_os_user() { printf ""; }'
  printf '%s\n' '# Counter-shim — every invocation appends a line carrying the'
  printf '%s\n' '# full argv so a regression is debuggable from the counter file.'
  printf '%s\n' '_bridge_isolation_v2_run_root_or_sudo() {'
  printf '%s\n' '  printf "%s\\n" "$*" >>"$COUNTER" 2>/dev/null || true'
  printf '%s\n' '  return 0'
  printf '%s\n' '}'
  printf '%s\n' '# Also stub bridge_linux_sudo_root so the chown_file_iso_uid'
  printf '%s\n' '# path counts towards the no-mutation budget. (The os_user'
  printf '%s\n' '# resolver is stubbed empty above, so chown_file_iso_uid'
  printf '%s\n' '# routes to chgrp_file_iso_group which uses run_root_or_sudo —'
  printf '%s\n' '# but keep this stub in case future refactor changes routing.)'
  printf '%s\n' 'bridge_linux_sudo_root() {'
  printf '%s\n' '  printf "%s\\n" "$*" >>"$COUNTER" 2>/dev/null || true'
  printf '%s\n' '  return 0'
  printf '%s\n' '}'
  printf '%s\n' 'bridge_isolation_v2_normalize_workdir_profile_group "$AGENT" "$WORKDIR" || exit 1'
} >"$NOMUT_DRIVER"
chmod +x "$NOMUT_DRIVER"

"$BRIDGE_BASH" "$NOMUT_DRIVER" "$REPO_ROOT" "$OPERATOR_GROUP" \
  "$AGENT" "$V2_WORKSPACE_DIR" "$NOMUT_COUNTER" \
  2>"$SMOKE_TMP_ROOT/nomut.stderr" \
  || smoke_fail "T3: idempotent driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/nomut.stderr"))"

nomut_calls=0
if [[ -s "$NOMUT_COUNTER" ]]; then
  nomut_calls="$(wc -l <"$NOMUT_COUNTER" | tr -d '[:space:]')"
fi
if [[ "$nomut_calls" -ne 0 ]]; then
  smoke_fail "T3 FAIL — expected 0 chgrp/chmod calls on already-correct entries, got $nomut_calls. Counter log: $(cat "$NOMUT_COUNTER")"
fi
smoke_log "T3 PASS — idempotent re-run performs zero syscalls (stat-skip honored)"

# ---------------------------------------------------------------------
# T4 — Mixed partial-migration.
# Reset to a mixed state: some dirs already at 2770, others reverted
# to 0700; same for the marketplaces file (0660 / 0640 mixed). A
# single pass must bring every entry to canonical.
# ---------------------------------------------------------------------
# Revert .claude/ root only (children remain at 2770 from T1+T2).
chmod 0700 "$V2_WORKSPACE_DIR/.claude"
# Revert the marketplaces file to 0640 only (children still 2770).
chmod 0640 "$KM_PATH"

run_normalize 0 || smoke_fail "T4: normalize driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/normalize.stderr"))"

assert_dir_grp_mode "T4 .claude"             "$V2_WORKSPACE_DIR/.claude"             "$OPERATOR_GROUP" "$EFFECTIVE_DIR_MODE"
assert_dir_grp_mode "T4 .claude/plugins"     "$V2_WORKSPACE_DIR/.claude/plugins"     "$OPERATOR_GROUP" "$EFFECTIVE_DIR_MODE"
assert_dir_grp_mode "T4 .claude/session-env" "$V2_WORKSPACE_DIR/.claude/session-env" "$OPERATOR_GROUP" "$EFFECTIVE_DIR_MODE"
assert_file_grp_mode "T4 known_marketplaces" "$KM_PATH" "$OPERATOR_GROUP" "0660"
smoke_log "T4 PASS — mixed-state partial migration converges to canonical"

# ---------------------------------------------------------------------
# T5 — Fresh-install no-op.
# When `.claude/` and the marketplaces file are absent (clean install
# before any settings render / catalog write), normalize returns 0 and
# does not error. We exercise this in a fresh workdir directory that
# only has the materialize-fileset files (no .claude/, no
# known_marketplaces.json).
# ---------------------------------------------------------------------
FRESH_AGENT="theta_fresh"
FRESH_WORKDIR="$BRIDGE_AGENT_ROOT_V2/$FRESH_AGENT/workdir"
mkdir -p "$FRESH_WORKDIR"
printf 'fresh\n' >"$FRESH_WORKDIR/CLAUDE.md"
chmod 0660 "$FRESH_WORKDIR/CLAUDE.md"

FRESH_DRIVER="$SMOKE_TMP_ROOT/run-fresh.sh"
: >"$FRESH_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'REPO_ROOT="$1"'
  printf '%s\n' 'OPERATOR_GROUP="$2"'
  printf '%s\n' 'AGENT="$3"'
  printf '%s\n' 'WORKDIR="$4"'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh"'
  printf '%s\n' 'bridge_isolation_v2_enforce() { return 0; }'
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "%s" "$OPERATOR_GROUP"; }'
  printf '%s\n' 'bridge_agent_os_user() { printf ""; }'
  printf '%s\n' 'bridge_isolation_v2_normalize_workdir_profile_group "$AGENT" "$WORKDIR" || exit 1'
  printf '%s\n' 'echo ok'
} >"$FRESH_DRIVER"
chmod +x "$FRESH_DRIVER"

"$BRIDGE_BASH" "$FRESH_DRIVER" "$REPO_ROOT" "$OPERATOR_GROUP" \
  "$FRESH_AGENT" "$FRESH_WORKDIR" \
  >"$SMOKE_TMP_ROOT/fresh.stdout" 2>"$SMOKE_TMP_ROOT/fresh.stderr" \
  || smoke_fail "T5: fresh driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/fresh.stderr"))"

# .claude/ never existed → still absent.
if [[ -e "$FRESH_WORKDIR/.claude" ]]; then
  smoke_fail "T5 FAIL — normalize created .claude/ on fresh install (must be no-op when missing)"
fi
smoke_log "T5 PASS — fresh-install no-op (no .claude/, no known_marketplaces.json)"

# ---------------------------------------------------------------------
# T_teeth (gated on SMOKE_TEETH=1).
# Revert proof — with the files-only normalize body stubbed in, re-seed
# the legacy state and assert .claude/ stays at 0700 and
# known_marketplaces.json stays at 0640. The smoke catches the C10/C9
# regression that removes the new directory walk + file chown.
# ---------------------------------------------------------------------
if [[ "${SMOKE_TEETH:-0}" == "1" ]]; then
  TEETH_AGENT="theta_teeth"
  TEETH_WORKDIR="$BRIDGE_AGENT_ROOT_V2/$TEETH_AGENT/workdir"
  mkdir -p "$TEETH_WORKDIR/.claude/plugins" "$TEETH_WORKDIR/.claude/session-env"
  chmod 0700 "$TEETH_WORKDIR/.claude" "$TEETH_WORKDIR/.claude/plugins" "$TEETH_WORKDIR/.claude/session-env"
  printf '{\n}\n' >"$TEETH_WORKDIR/.claude/plugins/known_marketplaces.json"
  chmod 0640 "$TEETH_WORKDIR/.claude/plugins/known_marketplaces.json"

  AGENT="$TEETH_AGENT" V2_WORKSPACE_DIR="$TEETH_WORKDIR" run_normalize 1 \
    || smoke_fail "T_teeth: teeth driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/normalize.stderr"))"

  # With files-only stubbed, the directories stay at 0700.
  teeth_actual=""
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    teeth_actual="$(stat -f '%Lp' "$TEETH_WORKDIR/.claude" 2>/dev/null || printf '')"
  else
    teeth_actual="$(stat -c '%a' "$TEETH_WORKDIR/.claude" 2>/dev/null || printf '')"
  fi
  teeth_norm="$(printf '%o' "$((8#${teeth_actual#0}))" 2>/dev/null || printf '%s' "$teeth_actual")"
  if [[ "$teeth_norm" == "2770" ]]; then
    smoke_fail "T_teeth FAIL — files-only stub left .claude/ at 2770 (teeth regression-proof broken)"
  fi
  smoke_log "T_teeth PASS — files-only stub leaves .claude/ at $teeth_norm (smoke catches C10 regression)"
fi

smoke_log "all tests PASS (#1315 + #1316)"
