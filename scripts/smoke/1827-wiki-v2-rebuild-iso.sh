#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1827-wiki-v2-rebuild-iso.sh — Issue #1827 (read-side
# sibling of #1222).
#
# The controller-run cron `scripts/wiki-v2-rebuild.sh` walks each active
# claude agent's home and rebuilds `$home/memory/index.sqlite` with a
# tmp+swap. Every step writes into `$home/memory/`:
#   mkdir -p memory/
#   <lock file create + flock>
#   rm -f tmp_db
#   bridge-memory.py rebuild-index --db-path tmp_db   (opens sqlite)
#   python validate
#   mv -f tmp_db live_db
# Under linux-user isolation `memory/` is owned by the iso UID with group
# `ab-agent-<slug>` mode 2770; the controller is intentionally NOT in that
# group (v2 contract). So every controller-side op fails with `Permission
# denied`, and each iso agent lands in the rebuild's `fail`/`skipped`
# tally — a recurring noisy per-agent failure on every run.
#
# Fix (unify with #1222): drop to the iso UID via
# `bridge_isolation_run_as_agent_user_via_bash` for the ENTIRE rebuild
# block, NOT just the leading mkdir/rm. The new code branches on
# `bridge_agent_linux_user_isolation_effective` — isolated agents go
# through the sudo'd bash inline script; non-isolated agents keep the
# legacy controller-direct path unchanged. The boundary's 2770 perms are
# never relaxed.
#
# Two layers, in order:
#
#   T1..T8 — Source-structure assertions (host-agnostic, no sudo, no
#            useradd, no real iso). They assert that:
#              T1: wiki-v2-rebuild.sh sources bridge-lib.sh (so the iso
#                  helpers are available).
#              T2: it calls bridge_load_roster after that source AND
#                  inside the _BRIDGE_ISO_HELPERS_LOADED guard (without
#                  the loader the predicate is always-false dead code —
#                  the exact #1222 r1 BLOCKING regression).
#              T3: the per-agent loop branches on
#                  bridge_agent_linux_user_isolation_effective.
#              T4: the isolated branch calls
#                  bridge_isolation_run_as_agent_user_via_bash with the
#                  rebuild block as its inline script.
#              T5: the inline script covers the FULL rebuild/publish
#                  block — mkdir of memory/, the lock, rm of stale
#                  tmp_db, rebuild-index, validate, and the final mv —
#                  under the iso UID. Wrapping only mkdir or only mv
#                  would leave the rest on the controller side, which is
#                  the bug.
#              T6: the non-iso branch keeps the legacy controller-direct
#                  sequence (so shared/legacy installs aren't regressed).
#              T7: inline-script exit codes are 0 or >= 10 so the
#                  wrapper's +2 shift on script rc<3 cannot collide with
#                  the wrapper's pre-flight 0/1/2 band.
#              T8: NO heredoc / here-string inside the inline script
#                  body (footgun #11). The lock + validate python
#                  harnesses are staged to files via printf, then run
#                  via `python3 -- file`.
#
#   T9     — Real iso reproducer (Linux + sudo + useradd gated). Stands
#            up a real `agent-bridge-w1827` user + ab-agent-w1827 group,
#            scaffolds an iso-owned `memory/` at mode 2770 with a stale
#            `index.sqlite.rebuilding` file, and asserts the cross-
#            boundary asymmetry is real on this host: a controller-direct
#            write/rm into the iso `memory/` fails, but a sudo-as-iso rm
#            succeeds. On macOS / sudoless CI hosts T9 is SKIPPED with a
#            structured log line — a ctl-writable mock would falsify the
#            contract.
#
# Footgun #11 (heredoc-stdin deadlock class): every harness file is built
# via `printf '%s\n' >file` per line, then read by `bash <file>` or
# `python3 <file>`. No `<<EOF`, no `<<<`, no `<<'PY'` anywhere here.

set -uo pipefail

SMOKE_NAME="1827-wiki-v2-rebuild-iso"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
REBUILD="$REPO_ROOT/scripts/wiki-v2-rebuild.sh"

# shellcheck disable=SC2329  # invoked via trap below
cleanup() {
  if [[ -n "${ISO_USER_CREATED:-}" && -n "${ISO_USER:-}" ]]; then
    if command -v userdel >/dev/null 2>&1; then
      sudo -n userdel -r "$ISO_USER" 2>/dev/null || \
        sudo -n userdel "$ISO_USER" 2>/dev/null || true
    fi
    if command -v groupdel >/dev/null 2>&1; then
      sudo -n groupdel "$ISO_GROUP" 2>/dev/null || true
    fi
    if [[ -n "${ISO_WORKDIR:-}" && -d "$ISO_WORKDIR" ]]; then
      sudo -n chown -R "$(id -u):$(id -g)" "$ISO_WORKDIR" 2>/dev/null || true
      sudo -n chmod -R u+rwX "$ISO_WORKDIR" 2>/dev/null || true
    fi
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"
smoke_require_cmd bash

if [[ ! -r "$REBUILD" ]]; then
  smoke_fail "cannot read scripts/wiki-v2-rebuild.sh at $REBUILD"
fi

# ---------------------------------------------------------------------
# T1 — wiki-v2-rebuild sources bridge-lib.sh (loads the iso helpers).
#      The source is relative to the script's own dir: "$HERE/../bridge-lib.sh".
# ---------------------------------------------------------------------
grep -Eq 'source[[:space:]]+"\$HERE/\.\./bridge-lib\.sh"' "$REBUILD" \
  || smoke_fail "T1 wiki-v2-rebuild.sh does not source ../bridge-lib.sh"
smoke_log "ok: T1 wiki-v2-rebuild sources bridge-lib.sh"

# ---------------------------------------------------------------------
# T2 — bridge_load_roster is called AFTER the bridge-lib.sh source and
#      inside the _BRIDGE_ISO_HELPERS_LOADED guard. Comment lines are
#      stripped first so a docstring mention doesn't satisfy it. #1222
#      r1 BLOCKING: without the loader the predicate is always-false dead
#      code and iso agents fall back to the controller-direct path.
# ---------------------------------------------------------------------
T2_NO_COMMENTS="$SMOKE_TMP_ROOT/rebuild-no-comments.txt"
grep -nv '^[[:space:]]*#' "$REBUILD" >"$T2_NO_COMMENTS"
grep -q "bridge_load_roster" "$T2_NO_COMMENTS" \
  || smoke_fail "T2 bridge_load_roster not called (predicate gate would always fail)"
grep -q "_BRIDGE_ISO_HELPERS_LOADED" "$T2_NO_COMMENTS" \
  || smoke_fail "T2 no _BRIDGE_ISO_HELPERS_LOADED guard"
{
  source_line="$(grep 'source[[:space:]]\+"\$HERE/\.\./bridge-lib\.sh"' "$T2_NO_COMMENTS" | head -1 | cut -d: -f1)"
  loader_line="$(grep "bridge_load_roster" "$T2_NO_COMMENTS" | head -1 | cut -d: -f1)"
  if [[ -z "$source_line" || -z "$loader_line" ]] || (( loader_line <= source_line )); then
    smoke_fail "T2 bridge_load_roster does not appear after source bridge-lib.sh (source_line=$source_line, loader_line=$loader_line)"
  fi
}
smoke_log "ok: T2 bridge_load_roster called after bridge-lib.sh source, inside the guard"

# ---------------------------------------------------------------------
# T3 — per-agent loop branches on bridge_agent_linux_user_isolation_effective.
# ---------------------------------------------------------------------
grep -q "bridge_agent_linux_user_isolation_effective" "$REBUILD" \
  || smoke_fail "T3 no bridge_agent_linux_user_isolation_effective gate"
smoke_log "ok: T3 rebuild loop branches on isolation gate"

# ---------------------------------------------------------------------
# T4 — isolated branch calls bridge_isolation_run_as_agent_user_via_bash.
# ---------------------------------------------------------------------
grep -q "bridge_isolation_run_as_agent_user_via_bash" "$REBUILD" \
  || smoke_fail "T4 no bridge_isolation_run_as_agent_user_via_bash call"
smoke_log "ok: T4 iso branch invokes bridge_isolation_run_as_agent_user_via_bash"

# ---------------------------------------------------------------------
# T5 — the inline iso script covers the ENTIRE rebuild/publish block, not
#      just mkdir or just mv. Extract the single-quoted _iso_rebuild_script
#      body and assert each phase is present.
# ---------------------------------------------------------------------
T_BODY="$SMOKE_TMP_ROOT/iso-rebuild-body.txt"
awk "
  /_iso_rebuild_script=\x27\$/ {inb=1; next}
  inb==1 && /^\x27\$/ {inb=0; next}
  inb==1 {print}
" "$REBUILD" >"$T_BODY"
if [[ ! -s "$T_BODY" ]]; then
  smoke_fail "T5 could not extract _iso_rebuild_script body from $REBUILD (file empty)"
fi

t5_phases=(
  'mkdir -p .*dirname .*live_db'
  'fcntl|flock'
  'rm -f .*tmp_db'
  'bridge-memory.py.* rebuild-index'
  'validate_py'
  'mv -f .*tmp_db.*live_db'
)
t5_missing=0
for needle in "${t5_phases[@]}"; do
  if ! grep -Eq "$needle" "$T_BODY"; then
    printf '[T5] _iso_rebuild_script body missing phase: %s\n' "$needle" >&2
    t5_missing=1
  fi
done
if (( t5_missing == 1 )); then
  smoke_fail "T5 _iso_rebuild_script does not cover the full rebuild/publish block"
fi
smoke_log "ok: T5 _iso_rebuild_script covers mkdir + lock + rm + rebuild + validate + mv"

# ---------------------------------------------------------------------
# T6 — non-iso branch keeps the legacy controller-direct sequence so
#      shared/legacy installs are not regressed. The legacy validate
#      heredoc terminator `^PY$` is a stable marker of that path.
# ---------------------------------------------------------------------
grep -q "^PY$" "$REBUILD" \
  || smoke_fail "T6 non-iso legacy validate heredoc disappeared (regression risk)"
smoke_log "ok: T6 non-iso branch preserved"

# ---------------------------------------------------------------------
# T7 — inline-script exit codes are 0 or >= 10 (wrapper +2-shift band).
# ---------------------------------------------------------------------
t7_bad=0
t7_codes_file="$SMOKE_TMP_ROOT/iso-rebuild-exit-codes.txt"
grep -Eo 'exit[[:space:]]+[0-9]+' "$T_BODY" | awk '{print $2}' >"$t7_codes_file"
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  if (( code != 0 && code < 10 )); then
    printf '[T7] _iso_rebuild_script uses forbidden exit code: %s\n' "$code" >&2
    t7_bad=1
  fi
done <"$t7_codes_file"
if (( t7_bad == 1 )); then
  smoke_fail "T7 _iso_rebuild_script exit-code contract violated (must be 0 or >= 10)"
fi
smoke_log "ok: T7 _iso_rebuild_script exit codes are 0 or >= 10"

# ---------------------------------------------------------------------
# T8 — no heredoc / here-string inside the inline-script body (footgun
#      #11). The body runs under `sudo -n -u <iso> bash -c "$script"`,
#      where a `<<EOF` / `<<<` would risk the read_comsub/heredoc_write
#      deadlock class.
# ---------------------------------------------------------------------
if grep -Eq '[<][<]-?[A-Za-z_'"'"'"]|[<][<][<]' "$T_BODY"; then
  grep -nE '[<][<]-?[A-Za-z_'"'"'"]|[<][<][<]' "$T_BODY" >&2
  smoke_fail "T8 _iso_rebuild_script contains a heredoc/here-string (footgun #11)"
fi
smoke_log "ok: T8 no heredoc/here-string in the iso inline script"

# ---------------------------------------------------------------------
# T9 — Real iso reproducer. Linux + sudo + useradd required. Skipped
#      otherwise.
# ---------------------------------------------------------------------
ISO_USER=""
ISO_GROUP=""
ISO_USER_CREATED=""
ISO_WORKDIR=""

t9_should_run() {
  smoke_is_linux || { smoke_skip "T9 real iso reproducer" "host is not Linux"; return 1; }
  command -v sudo >/dev/null 2>&1 || { smoke_skip "T9 real iso reproducer" "sudo not installed"; return 1; }
  sudo -n true 2>/dev/null || { smoke_skip "T9 real iso reproducer" "sudo -n unavailable"; return 1; }
  command -v useradd >/dev/null 2>&1 || { smoke_skip "T9 real iso reproducer" "useradd not installed"; return 1; }
  command -v groupadd >/dev/null 2>&1 || { smoke_skip "T9 real iso reproducer" "groupadd not installed"; return 1; }
  return 0
}

if t9_should_run; then
  ISO_USER="agent-bridge-w1827"
  ISO_GROUP="ab-agent-w1827"
  ISO_WORKDIR="$SMOKE_TMP_ROOT/iso-workdir"

  if ! sudo -n groupadd -r "$ISO_GROUP" 2>/dev/null; then
    smoke_skip "T9 real iso reproducer" "groupadd -r $ISO_GROUP failed (group exists?)"
  elif ! sudo -n useradd -r -g "$ISO_GROUP" -M -s /usr/sbin/nologin "$ISO_USER" 2>/dev/null; then
    sudo -n groupdel "$ISO_GROUP" 2>/dev/null || true
    smoke_skip "T9 real iso reproducer" "useradd -r $ISO_USER failed"
  else
    ISO_USER_CREATED=1
    # Open just enough of the mktemp 0700 path so the iso user can chdir
    # through but cannot list (o+x only, no o+r). /tmp itself is 1777.
    chmod o+x "$SMOKE_TMP_ROOT" 2>/dev/null || true
    sudo -n mkdir -p "$ISO_WORKDIR/memory"
    sudo -n chown -R "$ISO_USER:$ISO_GROUP" "$ISO_WORKDIR"
    sudo -n chmod 2770 "$ISO_WORKDIR/memory"
    sudo -n chmod 2770 "$ISO_WORKDIR"

    STALE_TMP="$ISO_WORKDIR/memory/index.sqlite.rebuilding"
    if ! sudo -n -u "$ISO_USER" bash -c "touch '$STALE_TMP' && chmod 0640 '$STALE_TMP'"; then
      smoke_fail "T9 fixture: iso user could not create $STALE_TMP — check SMOKE_TMP_ROOT traversal"
    fi

    # T9.a — controller direct write into iso-owned memory/ MUST fail.
    T9A_PROBE="$ISO_WORKDIR/memory/.w1827-write-probe"
    if : >"$T9A_PROBE" 2>/dev/null; then
      rm -f "$T9A_PROBE" 2>/dev/null || true
      smoke_fail "T9.a controller wrote into iso-owned memory/ — fixture mode is wrong"
    fi
    smoke_log "ok: T9.a controller direct write into iso memory/ fails"

    # T9.b — controller direct rm MUST fail (the pre-fix shape). Existence
    # is confirmed with root (`sudo -n test -e`), NOT a controller-side
    # `[[ -e ]]`, which would false-report "disappeared" across the 2770
    # boundary.
    if rm -f "$STALE_TMP" 2>/dev/null && ! sudo -n test -e "$STALE_TMP"; then
      smoke_fail "T9.b controller direct rm succeeded — fixture is NOT iso-owned"
    fi
    sudo -n test -e "$STALE_TMP" \
      || smoke_fail "T9.b stale tmp disappeared between fixture create and assert"
    smoke_log "ok: T9.b controller direct rm fails (pre-fix shape reproduced)"

    # T9.c — sudo-as-iso rm via the same helper shape the fix uses
    # (`sudo -n -u <iso> bash -c '...'`). Proves the post-fix path works.
    if ! sudo -n -u "$ISO_USER" bash -c "rm -f '$STALE_TMP'"; then
      smoke_fail "T9.c sudo-as-iso rm rc=$? — post-fix path is broken on this host"
    fi
    ! sudo -n test -e "$STALE_TMP" \
      || smoke_fail "T9.c sudo-as-iso rm reported success but file remains"
    smoke_log "ok: T9.c sudo-as-iso rm succeeds (post-fix path works)"
  fi
fi

smoke_log "all assertions passed"
exit 0
