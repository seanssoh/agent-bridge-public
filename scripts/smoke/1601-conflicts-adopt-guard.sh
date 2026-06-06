#!/usr/bin/env bash
# scripts/smoke/1601-conflicts-adopt-guard.sh — Issue #1601 smoke.
#
# `agb upgrade conflicts adopt` used to do an UNVALIDATED
# `shutil.copyfile(sidecar, live)` and then immediately unlink the sidecar.
# But the `.upgrade-conflict` sidecar holds `git merge-file --diff3` output,
# i.e. it may still contain unresolved conflict markers. Adopting that over a
# working live file can write non-parseable, marker-laden content; if the live
# target is `bridge-upgrade.py` (or another module on the conflicts path), the
# very tool used to recover starts failing with SyntaxError — and the recovery
# sidecar was already unlinked.
#
# This smoke validates the fail-closed content guard added to
# cmd_conflicts_adopt:
#   (a) sidecar WITH conflict markers      -> refused, nonzero, sidecar
#       PRESERVED, live UNCHANGED.
#   (b) marker-free `.py` with SyntaxError -> refused, preserved, live
#       unchanged.
#   (c) clean valid sidecar                -> succeeds, live updated, sidecar
#       removed, `.pre-adopt` backup written.
#   (d) self-brick: `bridge-upgrade.py.upgrade-conflict` with markers
#       -> refused (the recovery tool stays runnable).
#   (e) marker false-positive guard: a legit content line that begins with
#       `=======` followed by MORE `=` (a Markdown heading underline) is NOT a
#       7-char conflict marker -> still adoptable.
#   (f) --force escape hatch: a marker-bearing sidecar adopts under --force.
#
# Conflict-marker fixtures are assembled with `marker7()` from a non-literal
# base so this smoke file contains no verbatim 7-char marker lines (keeps the
# ci-select conflict-marker self-check and lint-heredoc clean). Uses
# BRIDGE_HOME isolation (mktemp -d); never touches operator live runtime.

set -euo pipefail

SMOKE_NAME="1601-conflicts-adopt-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

UPGRADE_PY=""

# ---- helpers ---------------------------------------------------------

marker7() {
  # Emit a diff3 conflict marker line: 7 identical chars + optional label.
  # Built via printf so this source file holds no verbatim marker string.
  local ch="$1"
  local label="${2:-}"
  local seven
  seven="$(printf '%0.s'"$ch" {1..7})"
  if [[ -n "$label" ]]; then
    printf '%s %s' "$seven" "$label"
  else
    printf '%s' "$seven"
  fi
}

write_marker_sidecar() {
  # Write a sidecar whose body is a diff3 merge result with live/upstream
  # hunks and all four marker forms.
  local path="$1"
  {
    printf 'unchanged top line\n'
    marker7 '<' 'live'; printf '\n'
    printf 'operator local edit\n'
    marker7 '|' 'base'; printf '\n'
    printf 'original base line\n'
    marker7 '='; printf '\n'
    printf 'incoming upstream line\n'
    marker7 '>' 'upstream'; printf '\n'
    printf 'unchanged bottom line\n'
  } >"$path"
}

# ---- assertions ------------------------------------------------------

assert_marker_sidecar_refused() {
  local live="$BRIDGE_HOME/sample.txt"
  local conflict="$live.upgrade-conflict"
  printf 'clean live content\n' >"$live"
  write_marker_sidecar "$conflict"
  local live_before
  live_before="$(cat "$live")"

  local rc=0 err
  err="$(python3 "$UPGRADE_PY" conflicts-adopt --target-root "$BRIDGE_HOME" --yes "$conflict" \
    2>&1 1>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || smoke_fail "(a) adopt of a marker sidecar must exit non-zero"
  smoke_assert_contains "$err" "unresolved conflict markers" "(a) refusal names unresolved markers"
  smoke_assert_file_exists "$conflict" "(a) sidecar PRESERVED on refusal"
  smoke_assert_eq "$live_before" "$(cat "$live")" "(a) live target UNCHANGED on refusal"
}

assert_syntax_broken_py_refused() {
  local live="$BRIDGE_HOME/broken_module.py"
  local conflict="$live.upgrade-conflict"
  printf 'x = 1\n' >"$live"
  # Marker-free but a genuine SyntaxError (unindented block body).
  printf 'def f():\npass\n' >"$conflict"
  local live_before
  live_before="$(cat "$live")"

  local rc=0 err
  err="$(python3 "$UPGRADE_PY" conflicts-adopt --target-root "$BRIDGE_HOME" --yes "$conflict" \
    2>&1 1>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || smoke_fail "(b) adopt of a SyntaxError .py must exit non-zero"
  smoke_assert_contains "$err" "fails a syntax check" "(b) refusal names the syntax check"
  smoke_assert_file_exists "$conflict" "(b) sidecar PRESERVED on syntax failure"
  smoke_assert_eq "$live_before" "$(cat "$live")" "(b) live .py UNCHANGED on syntax failure"
}

assert_clean_sidecar_adopts() {
  local live="$BRIDGE_HOME/clean_module.py"
  local conflict="$live.upgrade-conflict"
  printf 'old = 1\n' >"$live"
  printf 'new = 2\n' >"$conflict"

  python3 "$UPGRADE_PY" conflicts-adopt --target-root "$BRIDGE_HOME" --yes "$conflict" >/dev/null
  [[ -f "$conflict" ]] && smoke_fail "(c) sidecar must be removed after a validated adopt"
  smoke_assert_eq "new = 2" "$(cat "$live")" "(c) live updated to sidecar content"
  smoke_assert_file_exists "$live.pre-adopt" "(c) .pre-adopt backup of prior live written"
  smoke_assert_eq "old = 1" "$(cat "$live.pre-adopt")" "(c) .pre-adopt holds the prior live bytes"
}

assert_self_brick_refused() {
  # The crown jewel: a marker-laden bridge-upgrade.py sidecar must be refused
  # so the recovery tool stays runnable.
  local live="$BRIDGE_HOME/bridge-upgrade.py"
  local conflict="$live.upgrade-conflict"
  printf '#!/usr/bin/env python3\nok = True\n' >"$live"
  write_marker_sidecar "$conflict"
  local live_before
  live_before="$(cat "$live")"

  local rc=0 err
  err="$(python3 "$UPGRADE_PY" conflicts-adopt --target-root "$BRIDGE_HOME" --yes "$conflict" \
    2>&1 1>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || smoke_fail "(d) adopt of a marker bridge-upgrade.py sidecar must be refused"
  smoke_assert_file_exists "$conflict" "(d) self-brick sidecar PRESERVED"
  smoke_assert_eq "$live_before" "$(cat "$live")" "(d) live bridge-upgrade.py UNCHANGED (tool stays runnable)"
  # And the still-clean live module is genuinely importable/parseable.
  python3 -c "import py_compile; py_compile.compile('$live', doraise=True)" \
    || smoke_fail "(d) live bridge-upgrade.py must remain py_compile-clean after a refused adopt"
}

assert_marker_false_positive_adopts() {
  # A content line beginning with `=======` followed by MORE `=` is a Markdown
  # heading underline, not a 7-char divider marker. It must NOT be rejected.
  local live="$BRIDGE_HOME/doc.md"
  local conflict="$live.upgrade-conflict"
  printf 'old heading\n' >"$live"
  {
    printf 'New Heading\n'
    printf '==========\n'   # 10 '=' chars: a Markdown setext underline, not a marker.
    printf 'body line that mentions ======= inside prose\n'
    printf 'a code-ish line: ===== five equals =====\n'
  } >"$conflict"
  local sidecar_before
  sidecar_before="$(cat "$conflict")"

  python3 "$UPGRADE_PY" conflicts-adopt --target-root "$BRIDGE_HOME" --yes "$conflict" >/dev/null \
    || smoke_fail "(e) a marker-free doc with =-prefixed content lines must adopt"
  [[ -f "$conflict" ]] && smoke_fail "(e) sidecar removed after a successful adopt"
  smoke_assert_eq "$sidecar_before" "$(cat "$live")" "(e) live updated to the (non-marker) sidecar content"
}

assert_force_overrides_guard() {
  local live="$BRIDGE_HOME/forced.txt"
  local conflict="$live.upgrade-conflict"
  printf 'clean live\n' >"$live"
  write_marker_sidecar "$conflict"
  local sidecar_before
  sidecar_before="$(cat "$conflict")"

  python3 "$UPGRADE_PY" conflicts-adopt --target-root "$BRIDGE_HOME" --yes --force "$conflict" >/dev/null \
    || smoke_fail "(f) --force must adopt a marker-bearing sidecar"
  [[ -f "$conflict" ]] && smoke_fail "(f) --force adopt removes the sidecar after copy"
  smoke_assert_eq "$sidecar_before" "$(cat "$live")" "(f) --force copies the sidecar verbatim"
  smoke_assert_file_exists "$live.pre-adopt" "(f) --force adopt still snapshots the prior live"
}

assert_backup_failure_refuses_before_write() {
  # patch-dev #1601 re-review: a non-writable PARENT DIR with a still-writable
  # live file makes the `.pre-adopt` snapshot fail while the live overwrite
  # would otherwise succeed. Adopt MUST refuse BEFORE writing live — never
  # overwrite without a recovery copy — with a controlled nonzero (no
  # traceback) and the sidecar preserved.
  local dir="$BRIDGE_HOME/ro-target"
  mkdir -p "$dir"
  local live="$dir/live.py"
  local conflict="$live.upgrade-conflict"
  printf 'old = 1\n' >"$live"
  printf 'new = 2\n' >"$conflict"
  chmod 600 "$live" "$conflict"
  chmod 500 "$dir"   # parent non-writable: a new `.pre-adopt` cannot be created

  local rc=0 err
  err="$(python3 "$UPGRADE_PY" conflicts-adopt --target-root "$BRIDGE_HOME" --yes "$conflict" \
    2>&1 1>/dev/null)" || rc=$?
  chmod 700 "$dir"   # restore so we can inspect + cleanup can remove the dir

  [[ "$rc" -ne 0 ]] || smoke_fail "(g) adopt must refuse when the .pre-adopt snapshot cannot be created"
  smoke_assert_eq "old = 1" "$(cat "$live")" "(g) live UNCHANGED when the backup cannot be written"
  [[ -f "$live.pre-adopt" ]] && smoke_fail "(g) no .pre-adopt must exist after a refused adopt"
  smoke_assert_file_exists "$conflict" "(g) sidecar PRESERVED on backup-failure refusal"
  if printf '%s' "$err" | grep -qiE 'Traceback'; then
    smoke_fail "(g) backup-failure refusal must be a controlled error, not a traceback"
  fi
}

main() {
  smoke_require_cmd python3
  smoke_require_cmd bash
  smoke_setup_bridge_home "1601-conflicts-adopt-guard"
  UPGRADE_PY="$SMOKE_REPO_ROOT/bridge-upgrade.py"

  smoke_run "(a) marker sidecar refused, preserved, live unchanged" assert_marker_sidecar_refused
  smoke_run "(b) marker-free .py SyntaxError refused, preserved" assert_syntax_broken_py_refused
  smoke_run "(c) clean sidecar adopts, sidecar removed, .pre-adopt backup" assert_clean_sidecar_adopts
  smoke_run "(d) self-brick: marker bridge-upgrade.py refused, tool stays runnable" assert_self_brick_refused
  smoke_run "(e) =-prefixed content line is not a marker, still adoptable" assert_marker_false_positive_adopts
  smoke_run "(f) --force escape hatch overrides the guard" assert_force_overrides_guard
  smoke_run "(g) backup snapshot failure refuses before overwriting live" assert_backup_failure_refuses_before_write
  smoke_log "passed"
}

main "$@"
