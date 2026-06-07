#!/usr/bin/env bash
# scripts/smoke/1635-iso-backup-perm-skip.sh
#
# Issue #1635 regression smoke — `bridge-upgrade.py backup-live` (and the
# `build_backup_entries` scan it drives) must GRACEFUL-SKIP iso-owned profile
# files that the controller cannot stat, instead of letting the PermissionError
# abort the whole upgrade.
#
# Pre-#1635 behavior: under v2 isolation the controller is intentionally NOT a
# member of the iso agent's group, so statting an iso-owned 0600 profile file
# (e.g. `agents/<a>/workdir/SOUL.md`) or traversing an owner-only 0700 subtree
# raises `PermissionError [Errno 13]`. That propagated out of `build_backup_entries`
# → `bridge-upgrade.sh`'s `set -e` aborted the ENTIRE upgrade, so iso installs
# could not upgrade to 0.16.x without `--no-migrate-agents`.
#
# Post-#1635 behavior:
#   T1 — backup-live over a fixture whose one migrate-preview entry lives under
#        an unreadable (chmod 000) subtree returns rc=0 (upgrade CONTINUES).
#   T2 — the unreadable entry is recorded under skipped_isolated (count + path)
#        and a `[bridge-upgrade]` warning is printed to stderr — NOT silently
#        dropped without trace.
#   T3 — CONTROL: a controller-readable tracked file (CLAUDE.md) is still
#        captured (state=present, copied into backup_root/live), so we never
#        drop a backup we COULD have taken.
#   T4 — CONTROL (no-iso): with every entry readable there are zero skips and
#        the backup behaves exactly as before.
#
# Portability note: simulating a real cross-UID iso boundary needs root to
# chown to another user, which CI lacks. The portable trigger for the same
# PermissionError is `chmod 000` on the *parent* directory — a non-root user
# then cannot traverse it to stat the inner file (verified on macOS + Linux).
# Root can traverse 000 dirs, so the iso-trigger cases are skipped when the
# smoke happens to run as uid 0.
#
# Footgun #11: NO heredoc-stdin to any subprocess — fixtures are written with
# printf, JSON is probed via the file-as-argv helper. Run under Bash 5.x
# (macOS system bash is 3.2).

set -euo pipefail

SMOKE_NAME="1635-iso-backup-perm-skip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  # Restore traverse on any chmod-000 dir before rm -rf can fail on it.
  if [[ -n "${ISO_SUBTREE:-}" && -d "$ISO_SUBTREE" ]]; then
    chmod 0755 "$ISO_SUBTREE" 2>/dev/null || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_make_temp_root "$SMOKE_NAME"

MIGRATOR="$REPO_ROOT/bridge-upgrade.py"
HELPER="$SCRIPT_DIR/1635-iso-backup-perm-skip-helper.py"

# Build a synthetic target install tree with one controller-readable tracked
# file and one iso-agent profile file under a workdir subtree we will make
# unreadable. The analysis/migration preview JSON name both paths.
build_target() {
  local target="$1"
  mkdir -p "$target/agents/isoagent/workdir" "$target/state/upgrade"
  printf '%s\n' "# synthetic CLAUDE.md (controller-readable)" >"$target/CLAUDE.md"
  printf '%s\n' "# synthetic SOUL.md (iso-owned)" >"$target/agents/isoagent/workdir/SOUL.md"
  printf '%s\n' '{}' >"$target/state/upgrade/last-upgrade.json"
}

write_preview_json() {
  # $1 = analysis path, $2 = migration path
  printf '%s' \
    '{"files":[{"strategy":"deploy_upstream","path":"CLAUDE.md","classification":""}]}' \
    >"$1"
  printf '%s' \
    '{"agents":[{"agent":"isoagent","updated_files":["workdir/SOUL.md"],"added_files":[],"created_dirs":[]}]}' \
    >"$2"
}

run_backup() {
  # Emits the JSON payload on stdout; stderr captured to $STDERR_FILE.
  local target="$1" backup="$2" analysis="$3" migration="$4"
  python3 "$MIGRATOR" backup-live \
    --target-root "$target" \
    --backup-root "$backup" \
    --analysis-json-file "$analysis" \
    --migration-json-file "$migration" \
    2>"$STDERR_FILE"
}

ROOT_UID="$(id -u)"

# ---------------------------------------------------------------------------
# T1/T2/T3 — iso subtree unreadable: continue (rc=0), skip+warn, readable kept.
# ---------------------------------------------------------------------------
if [[ "$ROOT_UID" -eq 0 ]]; then
  smoke_log "T1-T3 SKIP: running as root — chmod 000 trigger does not block uid 0"
else
  smoke_log "T1/T2/T3: unreadable iso subtree → graceful-skip, upgrade continues"

  TARGET_A="$SMOKE_TMP_ROOT/case-a"
  BACKUP_A="$SMOKE_TMP_ROOT/backup-a"
  STDERR_FILE="$SMOKE_TMP_ROOT/stderr-a.txt"
  mkdir -p "$BACKUP_A"
  build_target "$TARGET_A"
  write_preview_json "$SMOKE_TMP_ROOT/analysis-a.json" "$SMOKE_TMP_ROOT/migration-a.json"

  # Make the iso agent's workdir non-traversable (simulates the 0700 owner-only
  # subtree of an iso UID the controller is not a group member of).
  ISO_SUBTREE="$TARGET_A/agents/isoagent/workdir"
  chmod 000 "$ISO_SUBTREE"

  set +e
  OUT_A="$(run_backup "$TARGET_A" "$BACKUP_A" \
    "$SMOKE_TMP_ROOT/analysis-a.json" "$SMOKE_TMP_ROOT/migration-a.json")"
  RC_A=$?
  set -e

  chmod 0755 "$ISO_SUBTREE"
  ISO_SUBTREE=""

  # T1 — rc=0: the upgrade step did not abort.
  smoke_assert_eq "0" "$RC_A" "T1: backup-live continues (rc=0) despite unreadable iso entry"
  smoke_log "T1 PASS: backup-live returned rc=0"

  # T2 — skip recorded + warned.
  skip_count_a="$(printf '%s' "$OUT_A" | python3 "$HELPER" field skipped_isolated_count)"
  smoke_assert_eq "1" "$skip_count_a" "T2: exactly one iso entry skipped"
  if ! python3 "$HELPER" list-has-path "$OUT_A" skipped_isolated "agents/isoagent/workdir/SOUL.md"; then
    smoke_fail "T2 FAIL: SOUL.md must be recorded in skipped_isolated"
  fi
  warn_a="$(cat "$STDERR_FILE")"
  smoke_assert_contains "$warn_a" "[bridge-upgrade]" "T2: stderr carries a [bridge-upgrade] line"
  smoke_assert_contains "$warn_a" "skipping unreadable iso-owned entry" "T2: stderr names the skip"
  smoke_log "T2 PASS: iso entry recorded in skipped_isolated + warned on stderr"

  # T3 — CONTROL: controller-readable CLAUDE.md still captured + copied.
  if python3 "$HELPER" list-has-path "$OUT_A" skipped_isolated "CLAUDE.md"; then
    smoke_fail "T3 FAIL: controller-readable CLAUDE.md must NOT be skipped"
  fi
  smoke_assert_file_exists "$BACKUP_A/live/CLAUDE.md" "T3: readable CLAUDE.md copied into backup live tree"
  smoke_assert_file_exists "$BACKUP_A/live/state/upgrade/last-upgrade.json" "T3: readable state file copied"
  # The iso file must NOT have been copied (we couldn't read it).
  if [[ -e "$BACKUP_A/live/agents/isoagent/workdir/SOUL.md" ]]; then
    smoke_fail "T3 FAIL: iso SOUL.md must not appear in the backup (it was unreadable)"
  fi
  smoke_log "T3 PASS: readable files preserved, iso file omitted from backup"
fi

# ---------------------------------------------------------------------------
# T4 — CONTROL (no iso boundary): every entry readable → zero skips.
# ---------------------------------------------------------------------------
smoke_log "T4: all-readable fixture → zero skips, normal targeted backup"

TARGET_B="$SMOKE_TMP_ROOT/case-b"
BACKUP_B="$SMOKE_TMP_ROOT/backup-b"
STDERR_FILE="$SMOKE_TMP_ROOT/stderr-b.txt"
mkdir -p "$BACKUP_B"
build_target "$TARGET_B"
write_preview_json "$SMOKE_TMP_ROOT/analysis-b.json" "$SMOKE_TMP_ROOT/migration-b.json"

set +e
OUT_B="$(run_backup "$TARGET_B" "$BACKUP_B" \
  "$SMOKE_TMP_ROOT/analysis-b.json" "$SMOKE_TMP_ROOT/migration-b.json")"
RC_B=$?
set -e

smoke_assert_eq "0" "$RC_B" "T4: backup-live rc=0 on all-readable fixture"
skip_field_b="$(printf '%s' "$OUT_B" | python3 "$HELPER" field skipped_isolated_count)"
# skipped_isolated_count is only emitted when there are skips; absent → "None".
smoke_assert_eq "None" "$skip_field_b" "T4: no skipped_isolated key when nothing is skipped"
smoke_assert_file_exists "$BACKUP_B/live/CLAUDE.md" "T4: CLAUDE.md backed up"
smoke_assert_file_exists "$BACKUP_B/live/agents/isoagent/workdir/SOUL.md" "T4: readable iso file backed up"
smoke_log "T4 PASS: all-readable backup unchanged (no false skips)"

# ---------------------------------------------------------------------------
# T5 — codex-rescue R1 finding (a): when EVERY targeted file entry is an
#      unreadable iso path, the backup must NOT fall back to the full-tree copy
#      (which would walk the protected subtree AND back up untargeted files).
#      Snapshot stays `targeted`; an untargeted controller file must NOT appear.
# ---------------------------------------------------------------------------
if [[ "$ROOT_UID" -eq 0 ]]; then
  smoke_log "T5 SKIP: running as root — chmod 000 trigger does not block uid 0"
else
  smoke_log "T5: all targeted entries skipped → no full-tree fallback"

  TARGET_C="$SMOKE_TMP_ROOT/case-c"
  BACKUP_C="$SMOKE_TMP_ROOT/backup-c"
  STDERR_FILE="$SMOKE_TMP_ROOT/stderr-c.txt"
  mkdir -p "$BACKUP_C"
  build_target "$TARGET_C"
  # A controller file that is NOT named in the targeted preview — it must only
  # be captured by the (forbidden) full-tree fallback, so its presence in the
  # backup is the canary for a regression to the full-tree branch.
  printf '%s\n' "untargeted controller file" >"$TARGET_C/UNTARGETED.md"
  # Preview names ONLY the iso file (no readable tracked file in analysis).
  printf '%s' '{"files":[]}' >"$SMOKE_TMP_ROOT/analysis-c.json"
  printf '%s' \
    '{"agents":[{"agent":"isoagent","updated_files":["workdir/SOUL.md"],"added_files":[],"created_dirs":[]}]}' \
    >"$SMOKE_TMP_ROOT/migration-c.json"

  ISO_SUBTREE="$TARGET_C/agents/isoagent/workdir"
  chmod 000 "$ISO_SUBTREE"

  set +e
  OUT_C="$(run_backup "$TARGET_C" "$BACKUP_C" \
    "$SMOKE_TMP_ROOT/analysis-c.json" "$SMOKE_TMP_ROOT/migration-c.json")"
  RC_C=$?
  set -e

  chmod 0755 "$ISO_SUBTREE"
  ISO_SUBTREE=""

  smoke_assert_eq "0" "$RC_C" "T5: backup-live rc=0 when every targeted entry is skipped"
  mode_c="$(printf '%s' "$OUT_C" | python3 "$HELPER" field snapshot_mode)"
  smoke_assert_eq "targeted" "$mode_c" "T5: snapshot_mode stays targeted (no full fallback)"
  if [[ -e "$BACKUP_C/live/UNTARGETED.md" ]]; then
    smoke_fail "T5 FAIL: untargeted file copied → full-tree fallback regression"
  fi
  smoke_log "T5 PASS: no full-tree fallback when all targeted entries skipped"
fi

# ---------------------------------------------------------------------------
# T6 — codex-rescue R1 finding (b): a directory entry can be STAT-able (recorded
#      state=present) yet not traversable for the copy. The copy stage must
#      graceful-skip the PermissionError (warn + record), not abort. Repro: a
#      `created_dirs` entry whose directory is chmod 000.
# ---------------------------------------------------------------------------
if [[ "$ROOT_UID" -eq 0 ]]; then
  smoke_log "T6 SKIP: running as root — chmod 000 trigger does not block uid 0"
else
  smoke_log "T6: unreadable directory entry → copy-stage graceful-skip"

  TARGET_D="$SMOKE_TMP_ROOT/case-d"
  BACKUP_D="$SMOKE_TMP_ROOT/backup-d"
  STDERR_FILE="$SMOKE_TMP_ROOT/stderr-d.txt"
  mkdir -p "$BACKUP_D" "$TARGET_D/agents/a/workdir" "$TARGET_D/state/upgrade"
  printf '%s\n' "# readable CLAUDE.md" >"$TARGET_D/CLAUDE.md"
  printf '%s\n' "inside" >"$TARGET_D/agents/a/workdir/SOUL.md"
  printf '%s\n' '{}' >"$TARGET_D/state/upgrade/last-upgrade.json"
  printf '%s' '{"files":[{"strategy":"deploy_upstream","path":"CLAUDE.md","classification":""}]}' \
    >"$SMOKE_TMP_ROOT/analysis-d.json"
  # created_dirs names the workdir directory itself (recorded present as kind=dir).
  printf '%s' \
    '{"agents":[{"agent":"a","updated_files":[],"added_files":[],"created_dirs":["workdir"]}]}' \
    >"$SMOKE_TMP_ROOT/migration-d.json"

  # The directory entry is stat-able (parent traversable) but its own contents
  # are not readable for the copy — chmod 000 the directory itself.
  ISO_SUBTREE="$TARGET_D/agents/a/workdir"
  chmod 000 "$ISO_SUBTREE"

  set +e
  OUT_D="$(run_backup "$TARGET_D" "$BACKUP_D" \
    "$SMOKE_TMP_ROOT/analysis-d.json" "$SMOKE_TMP_ROOT/migration-d.json")"
  RC_D=$?
  set -e

  chmod 0755 "$ISO_SUBTREE"
  ISO_SUBTREE=""

  smoke_assert_eq "0" "$RC_D" "T6: backup-live rc=0 on unreadable directory entry (copy-stage skip)"
  if ! python3 "$HELPER" list-has-path "$OUT_D" skipped_isolated "agents/a/workdir"; then
    smoke_fail "T6 FAIL: unreadable workdir dir must be recorded in skipped_isolated"
  fi
  warn_d="$(cat "$STDERR_FILE")"
  smoke_assert_contains "$warn_d" "[bridge-upgrade]" "T6: stderr carries a [bridge-upgrade] line"
  # CONTROL: the readable CLAUDE.md is still backed up despite the dir skip.
  smoke_assert_file_exists "$BACKUP_D/live/CLAUDE.md" "T6: readable CLAUDE.md still backed up"
  # The unreadable directory's contents must NOT have been copied.
  if [[ -e "$BACKUP_D/live/agents/a/workdir/SOUL.md" ]]; then
    smoke_fail "T6 FAIL: unreadable workdir contents must not leak into the backup"
  fi
  smoke_log "T6 PASS: copy-stage graceful-skip on unreadable directory entry"
fi

# ---------------------------------------------------------------------------
# T7 — codex-rescue R2 finding: cmd_backup_extend_live (the `backup-extend-live`
#      subcommand) shared the same raw-stat + raw-copy pattern. An unreadable
#      iso changed-path must graceful-skip (warn + record) WITHOUT aborting AND
#      WITHOUT silently dropping a LATER readable extension backup in the same
#      changed_paths list (the iso path is intentionally listed first).
# ---------------------------------------------------------------------------
if [[ "$ROOT_UID" -eq 0 ]]; then
  smoke_log "T7 SKIP: running as root — chmod 000 trigger does not block uid 0"
else
  smoke_log "T7: backup-extend-live iso skip keeps later readable backups"

  TARGET_E="$SMOKE_TMP_ROOT/case-e"
  BACKUP_E="$SMOKE_TMP_ROOT/backup-e"
  STDERR_FILE="$SMOKE_TMP_ROOT/stderr-e.txt"
  mkdir -p "$BACKUP_E/live" "$TARGET_E/agents/isoagent/workdir"
  printf '%s\n' "iso soul" >"$TARGET_E/agents/isoagent/workdir/SOUL.md"
  printf '%s\n' "readable claude" >"$TARGET_E/CLAUDE.md"
  printf '%s' '{"entries":[]}' >"$BACKUP_E/manifest.json"
  # Resolve target so /tmp -> /private/tmp symlink resolution does not push the
  # absolute changed-paths outside target_root on macOS.
  TARGET_E_REAL="$(cd -P "$TARGET_E" && pwd -P)"

  ISO_SUBTREE="$TARGET_E/agents/isoagent/workdir"
  chmod 000 "$ISO_SUBTREE"

  # iso path FIRST, readable path SECOND — proves the loop does not bail after
  # the first skip and drop the readable backup.
  PATHS_JSON="$(printf '{"changed_paths":["%s/agents/isoagent/workdir/SOUL.md","%s/CLAUDE.md"]}' \
    "$TARGET_E_REAL" "$TARGET_E_REAL")"

  set +e
  OUT_E="$(python3 "$MIGRATOR" backup-extend-live \
    --target-root "$TARGET_E_REAL" --backup-root "$BACKUP_E" \
    --paths-json "$PATHS_JSON" 2>"$STDERR_FILE")"
  RC_E=$?
  set -e

  chmod 0755 "$ISO_SUBTREE"
  ISO_SUBTREE=""

  smoke_assert_eq "0" "$RC_E" "T7: backup-extend-live rc=0 on unreadable iso changed-path"
  if ! python3 "$HELPER" list-has-path "$OUT_E" skipped_isolated "agents/isoagent/workdir/SOUL.md"; then
    smoke_fail "T7 FAIL: unreadable iso path must be recorded in skipped_isolated"
  fi
  added_e="$(printf '%s' "$OUT_E" | python3 "$HELPER" field added_entries)"
  smoke_assert_eq "1" "$added_e" "T7: the later readable CLAUDE.md is still recorded (not dropped)"
  smoke_assert_file_exists "$BACKUP_E/live/CLAUDE.md" "T7: later readable CLAUDE.md still copied into backup"
  if [[ -e "$BACKUP_E/live/agents/isoagent/workdir/SOUL.md" ]]; then
    smoke_fail "T7 FAIL: unreadable iso file must not leak into the extend backup"
  fi
  smoke_log "T7 PASS: extend-live skips iso path, keeps the later readable backup"
fi

# ---------------------------------------------------------------------------
# T8 — codex-rescue R3 finding: a DESTINATION-side permission failure (the
#      operator's backup dir is not writable) must ABORT, NOT be misclassified
#      as an iso source skip — otherwise a controller-readable backup is
#      silently dropped while rc=0. Repro: readable CLAUDE.md, chmod 500 the
#      backup/live dir, backup-live must return non-zero and NOT record a skip.
# ---------------------------------------------------------------------------
if [[ "$ROOT_UID" -eq 0 ]]; then
  smoke_log "T8 SKIP: running as root — chmod 500 dest does not block uid 0"
else
  smoke_log "T8: destination-side EACCES aborts (no false iso skip) — backup-live"

  TARGET_F="$SMOKE_TMP_ROOT/case-f"
  BACKUP_F="$SMOKE_TMP_ROOT/backup-f"
  STDERR_FILE="$SMOKE_TMP_ROOT/stderr-f.txt"
  mkdir -p "$BACKUP_F/live" "$TARGET_F/state/upgrade"
  printf '%s\n' "readable claude" >"$TARGET_F/CLAUDE.md"
  printf '%s\n' '{}' >"$TARGET_F/state/upgrade/last-upgrade.json"
  printf '%s' '{"files":[{"strategy":"deploy_upstream","path":"CLAUDE.md","classification":""}]}' \
    >"$SMOKE_TMP_ROOT/analysis-f.json"
  printf '%s' '{"agents":[]}' >"$SMOKE_TMP_ROOT/migration-f.json"

  # Make the backup destination unwritable.
  DEST_DIR="$BACKUP_F/live"
  chmod 500 "$DEST_DIR"

  set +e
  OUT_F="$(run_backup "$TARGET_F" "$BACKUP_F" \
    "$SMOKE_TMP_ROOT/analysis-f.json" "$SMOKE_TMP_ROOT/migration-f.json")"
  RC_F=$?
  set -e

  chmod 0755 "$DEST_DIR"

  if [[ "$RC_F" -eq 0 ]]; then
    smoke_fail "T8 FAIL: dest-unwritable backup-live must ABORT (rc!=0), got rc=0"
  fi
  if printf '%s' "$OUT_F" | grep -q "skipped_isolated"; then
    smoke_fail "T8 FAIL: dest write failure must NOT be recorded as an iso skip"
  fi
  smoke_log "T8 PASS: destination EACCES aborted, no false skip (backup-live)"
fi

# ---------------------------------------------------------------------------
# T9 — codex-rescue R3 finding, extend-live variant: destination EACCES on
#      backup-extend-live must also ABORT, not record a false iso skip.
# ---------------------------------------------------------------------------
if [[ "$ROOT_UID" -eq 0 ]]; then
  smoke_log "T9 SKIP: running as root — chmod 500 dest does not block uid 0"
else
  smoke_log "T9: destination-side EACCES aborts (no false iso skip) — extend-live"

  TARGET_G="$SMOKE_TMP_ROOT/case-g"
  BACKUP_G="$SMOKE_TMP_ROOT/backup-g"
  STDERR_FILE="$SMOKE_TMP_ROOT/stderr-g.txt"
  mkdir -p "$BACKUP_G/live" "$TARGET_G"
  printf '%s\n' "readable claude" >"$TARGET_G/CLAUDE.md"
  printf '%s' '{"entries":[]}' >"$BACKUP_G/manifest.json"
  TARGET_G_REAL="$(cd -P "$TARGET_G" && pwd -P)"

  DEST_DIR="$BACKUP_G/live"
  chmod 500 "$DEST_DIR"

  PATHS_JSON_G="$(printf '{"changed_paths":["%s/CLAUDE.md"]}' "$TARGET_G_REAL")"

  set +e
  OUT_G="$(python3 "$MIGRATOR" backup-extend-live \
    --target-root "$TARGET_G_REAL" --backup-root "$BACKUP_G" \
    --paths-json "$PATHS_JSON_G" 2>"$STDERR_FILE")"
  RC_G=$?
  set -e

  chmod 0755 "$DEST_DIR"

  if [[ "$RC_G" -eq 0 ]]; then
    smoke_fail "T9 FAIL: dest-unwritable backup-extend-live must ABORT (rc!=0), got rc=0"
  fi
  if printf '%s' "$OUT_G" | grep -q "skipped_isolated"; then
    smoke_fail "T9 FAIL: dest write failure must NOT be recorded as an iso skip"
  fi
  smoke_log "T9 PASS: destination EACCES aborted, no false skip (extend-live)"
fi

# ---------------------------------------------------------------------------
# T10 — codex-rescue R4 finding: a NESTED destination EACCES inside a
#       shutil.copytree batch surfaces at tuple index 1 (the dst), not index 0.
#       The source/dest discriminator must inspect BOTH src and dst of every
#       shutil.Error member, so a readable source dir copied over a pre-existing
#       unwritable nested backup dir ABORTS (does not false-skip).
# ---------------------------------------------------------------------------
if [[ "$ROOT_UID" -eq 0 ]]; then
  smoke_log "T10 SKIP: running as root — chmod 500 nested dest does not block uid 0"
else
  smoke_log "T10: nested copytree destination EACCES aborts (no false skip)"

  TARGET_H="$SMOKE_TMP_ROOT/case-h"
  BACKUP_H="$SMOKE_TMP_ROOT/backup-h"
  STDERR_FILE="$SMOKE_TMP_ROOT/stderr-h.txt"
  # Source dir is fully READABLE; the abort must come from the DEST side.
  mkdir -p "$TARGET_H/agents/a/dir/nested" "$TARGET_H/state/upgrade" \
    "$BACKUP_H/live/agents/a/dir/nested"
  printf '%s\n' "readable nested file" >"$TARGET_H/agents/a/dir/nested/file.md"
  printf '%s\n' '{}' >"$TARGET_H/state/upgrade/last-upgrade.json"
  printf '%s' '{"files":[]}' >"$SMOKE_TMP_ROOT/analysis-h.json"
  printf '%s' \
    '{"agents":[{"agent":"a","updated_files":[],"added_files":[],"created_dirs":["dir"]}]}' \
    >"$SMOKE_TMP_ROOT/migration-h.json"

  # Pre-create the nested DEST dir unwritable so copytree's per-member write
  # raises EACCES at tuple index 1 (the destination path).
  DEST_NESTED="$BACKUP_H/live/agents/a/dir/nested"
  chmod 500 "$DEST_NESTED"

  set +e
  OUT_H="$(run_backup "$TARGET_H" "$BACKUP_H" \
    "$SMOKE_TMP_ROOT/analysis-h.json" "$SMOKE_TMP_ROOT/migration-h.json")"
  RC_H=$?
  set -e

  chmod -R 0755 "$BACKUP_H/live"

  if [[ "$RC_H" -eq 0 ]]; then
    smoke_fail "T10 FAIL: nested dest-EACCES copytree must ABORT (rc!=0), got rc=0"
  fi
  if printf '%s' "$OUT_H" | grep -q "skipped_isolated"; then
    smoke_fail "T10 FAIL: nested dest write failure must NOT be recorded as an iso skip"
  fi
  smoke_log "T10 PASS: nested copytree dest EACCES aborted, no false skip"
fi

# ---------------------------------------------------------------------------
# T11 — codex-rescue R6 finding: a copy-stage source EACCES skip must demote the
#       MANIFEST entry from state=present to skipped_isolated, so the manifest
#       never claims a backup payload that was never written. Round-trip: rollback
#       must (a) restore a readable file, (b) leave the skipped iso file untouched
#       (neither restored-over nor deleted).
# ---------------------------------------------------------------------------
if [[ "$ROOT_UID" -eq 0 ]]; then
  smoke_log "T11 SKIP: running as root — chmod 000 trigger does not block uid 0"
else
  smoke_log "T11: copy-stage skip demotes manifest entry + rollback ignores it"

  TARGET_I="$SMOKE_TMP_ROOT/case-i"
  BACKUP_I="$SMOKE_TMP_ROOT/backup-i"
  STDERR_FILE="$SMOKE_TMP_ROOT/stderr-i.txt"
  mkdir -p "$TARGET_I/agents/a/dir" "$TARGET_I/state/upgrade" "$BACKUP_I/live"
  printf '%s\n' "inside iso dir" >"$TARGET_I/agents/a/dir/x.md"
  printf '%s\n' "readable claude" >"$TARGET_I/CLAUDE.md"
  printf '%s\n' '{}' >"$TARGET_I/state/upgrade/last-upgrade.json"
  printf '%s' '{"files":[{"strategy":"deploy_upstream","path":"CLAUDE.md","classification":""}]}' \
    >"$SMOKE_TMP_ROOT/analysis-i.json"
  # created_dirs names the iso 'dir'; chmod 000 makes its copy fail at copy stage.
  printf '%s' \
    '{"agents":[{"agent":"a","updated_files":[],"added_files":[],"created_dirs":["dir"]}]}' \
    >"$SMOKE_TMP_ROOT/migration-i.json"

  ISO_SUBTREE="$TARGET_I/agents/a/dir"
  chmod 000 "$ISO_SUBTREE"

  set +e
  OUT_I="$(run_backup "$TARGET_I" "$BACKUP_I" \
    "$SMOKE_TMP_ROOT/analysis-i.json" "$SMOKE_TMP_ROOT/migration-i.json")"
  RC_I=$?
  set -e

  chmod 0755 "$ISO_SUBTREE"
  ISO_SUBTREE=""

  smoke_assert_eq "0" "$RC_I" "T11: backup-live rc=0 on copy-stage iso skip"
  # The manifest entry for the skipped dir must be state=skipped_isolated, NOT present.
  state_i="$(python3 "$HELPER" manifest-state "$BACKUP_I/manifest.json" "agents/a/dir")"
  smoke_assert_eq "skipped_isolated" "$state_i" "T11: skipped dir manifest entry demoted (not present)"

  # Round-trip rollback: readable file restored, skipped iso file untouched.
  RESTORE_I="$SMOKE_TMP_ROOT/restore-i"
  mkdir -p "$RESTORE_I/agents/a/dir" "$RESTORE_I/state/upgrade"
  printf '%s\n' "MODIFIED after backup" >"$RESTORE_I/CLAUDE.md"
  printf '%s\n' "live iso content must survive" >"$RESTORE_I/agents/a/dir/x.md"
  printf '%s\n' '{}' >"$RESTORE_I/state/upgrade/last-upgrade.json"

  set +e
  python3 "$MIGRATOR" rollback-live \
    --target-root "$RESTORE_I" --backup-root "$BACKUP_I" >/dev/null 2>"$STDERR_FILE"
  RC_RB=$?
  set -e
  smoke_assert_eq "0" "$RC_RB" "T11: rollback-live rc=0"
  rb_claude="$(cat "$RESTORE_I/CLAUDE.md")"
  smoke_assert_eq "readable claude" "$rb_claude" "T11: readable CLAUDE.md restored from backup"
  smoke_assert_file_exists "$RESTORE_I/agents/a/dir/x.md" "T11: skipped iso file left untouched (not deleted)"
  rb_iso="$(cat "$RESTORE_I/agents/a/dir/x.md")"
  smoke_assert_eq "live iso content must survive" "$rb_iso" "T11: skipped iso file content unchanged"
  smoke_log "T11 PASS: copy-stage skip demotes manifest entry; rollback ignores it"
fi

smoke_log "all assertions passed (#1635)"
