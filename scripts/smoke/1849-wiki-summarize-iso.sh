#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1849-wiki-summarize-iso.sh — Issue #1849 (sibling of #1827
# / #1222).
#
# The controller-run crons `scripts/wiki-monthly-summarize.sh` and
# `scripts/wiki-weekly-summarize.sh` walk each active claude agent's home
# and run `bridge-memory.py summarize {monthly,weekly}`, which reads and
# writes under `$home/memory/`. Under linux-user isolation `memory/` is
# owned by the iso UID with group `ab-agent-<slug>` mode 2770; the
# controller is intentionally NOT in that group (v2 contract). So the
# controller-direct invocation fails with `Permission denied`, and each iso
# agent lands in the summarize's `fail` tally — a recurring noisy per-agent
# failure on every run, even though the only impact is a stale summary.
#
# Fix (unify with #1827 / #1222): drop to the iso UID via
# `bridge_isolation_run_as_agent_user_via_bash` for the summarize. The new
# code branches on `bridge_agent_linux_user_isolation_effective` — isolated
# agents go through the sudo'd bash inline script; non-isolated agents keep
# the legacy controller-direct path unchanged. The boundary's 2770 perms
# are never relaxed.
#
# Two layers, in order:
#
#   T1..T7 — Source-structure assertions (host-agnostic, no sudo, no
#            useradd, no real iso), run against BOTH summarize scripts:
#              T1: the script sources ../bridge-lib.sh (loads iso helpers).
#              T2: bridge_load_roster is called after that source AND
#                  inside the _BRIDGE_ISO_HELPERS_LOADED guard (without the
#                  loader the predicate is always-false dead code — the
#                  exact #1222 r1 BLOCKING regression).
#              T3: the per-agent loop branches on
#                  bridge_agent_linux_user_isolation_effective.
#              T4: the isolated branch calls
#                  bridge_isolation_run_as_agent_user_via_bash with the
#                  summarize as its inline script.
#              T5: the inline script actually runs `bridge-memory.py
#                  summarize <period>` (so it's the summarize that crosses
#                  the boundary, not a no-op).
#              T6: the non-iso branch keeps the legacy controller-direct
#                  `run_with_timeout ... summarize <period>` path (so
#                  shared/legacy installs aren't regressed).
#              T7: inline-script exit codes are 0 or >= 10 so the wrapper's
#                  +2 shift on script rc<3 cannot collide with the
#                  wrapper's pre-flight 0/1/2 band; AND no heredoc /
#                  here-string inside the inline body (footgun #11).
#
#   T8     — Real iso reproducer (Linux + sudo + useradd gated). Stands up
#            a real `agent-bridge-w1849` user + ab-agent-w1849 group,
#            scaffolds an iso-owned `memory/` at mode 2770, and asserts the
#            cross-boundary asymmetry is real on this host: a
#            controller-direct write into the iso `memory/` fails, but a
#            sudo-as-iso write succeeds. On macOS / sudoless CI hosts T8 is
#            SKIPPED with a structured log line — a ctl-writable mock would
#            falsify the contract.
#
# Footgun #11 (heredoc-stdin deadlock class): every harness assertion uses
# grep/awk over the source files; no `<<EOF`, no `<<<`, no `<<'PY'` is
# introduced by the iso path under test.

set -uo pipefail

SMOKE_NAME="1849-wiki-summarize-iso"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

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

# ---------------------------------------------------------------------
# T1..T7 — structural assertions, applied to both summarize scripts.
#          assert_structure <script-path> <period>
# ---------------------------------------------------------------------
assert_structure() {
  local script="$1"
  local period="$2"
  local base
  base="$(basename "$script")"

  if [[ ! -r "$script" ]]; then
    smoke_fail "cannot read $base at $script"
  fi

  # T1 — sources ../bridge-lib.sh.
  grep -Eq 'source[[:space:]]+"\$HERE/\.\./bridge-lib\.sh"' "$script" \
    || smoke_fail "T1 $base does not source ../bridge-lib.sh"
  smoke_log "ok: T1 $base sources bridge-lib.sh"

  # T2 — bridge_load_roster after the source, inside the guard. Strip
  #      comments first so a docstring mention can't satisfy it.
  local no_comments="$SMOKE_TMP_ROOT/$base.no-comments.txt"
  grep -nv '^[[:space:]]*#' "$script" >"$no_comments"
  grep -q "bridge_load_roster" "$no_comments" \
    || smoke_fail "T2 $base bridge_load_roster not called (predicate gate would always fail)"
  grep -q "_BRIDGE_ISO_HELPERS_LOADED" "$no_comments" \
    || smoke_fail "T2 $base no _BRIDGE_ISO_HELPERS_LOADED guard"
  local source_line loader_line
  source_line="$(grep 'source[[:space:]]\+"\$HERE/\.\./bridge-lib\.sh"' "$no_comments" | head -1 | cut -d: -f1)"
  loader_line="$(grep "bridge_load_roster" "$no_comments" | head -1 | cut -d: -f1)"
  if [[ -z "$source_line" || -z "$loader_line" ]] || (( loader_line <= source_line )); then
    smoke_fail "T2 $base bridge_load_roster does not appear after source bridge-lib.sh (source_line=$source_line, loader_line=$loader_line)"
  fi
  smoke_log "ok: T2 $base bridge_load_roster called after bridge-lib.sh source, inside the guard"

  # T3 — loop branches on the isolation predicate.
  grep -q "bridge_agent_linux_user_isolation_effective" "$script" \
    || smoke_fail "T3 $base no bridge_agent_linux_user_isolation_effective gate"
  smoke_log "ok: T3 $base loop branches on isolation gate"

  # T4 — iso branch calls the run-as helper.
  grep -q "bridge_isolation_run_as_agent_user_via_bash" "$script" \
    || smoke_fail "T4 $base no bridge_isolation_run_as_agent_user_via_bash call"
  smoke_log "ok: T4 $base iso branch invokes bridge_isolation_run_as_agent_user_via_bash"

  # T5 — extract the single-quoted _iso_summarize_script body and assert it
  #      runs `bridge-memory.py summarize <period>`.
  local body="$SMOKE_TMP_ROOT/$base.iso-body.txt"
  awk "
    /_iso_summarize_script=\x27\$/ {inb=1; next}
    inb==1 && /^\x27\$/ {inb=0; next}
    inb==1 {print}
  " "$script" >"$body"
  if [[ ! -s "$body" ]]; then
    smoke_fail "T5 $base could not extract _iso_summarize_script body (empty)"
  fi
  grep -Eq "bridge-memory\.py.* summarize $period" "$body" \
    || smoke_fail "T5 $base iso body does not run summarize $period inside the boundary"
  smoke_log "ok: T5 $base iso body runs summarize $period as the iso UID"

  # T6 — non-iso branch keeps the legacy controller-direct path. The
  #      `run_with_timeout ... summarize <period>` line is the stable marker
  #      of that path and must survive (no regression for shared installs).
  grep -Eq "run_with_timeout[[:space:]]+[0-9]+.*summarize $period" "$script" \
    || smoke_fail "T6 $base legacy controller-direct summarize path disappeared (regression risk)"
  smoke_log "ok: T6 $base non-iso legacy path preserved"

  # T7a — inline-script exit codes are 0 or >= 10 (wrapper +2-shift band).
  local codes_file="$SMOKE_TMP_ROOT/$base.iso-exit-codes.txt"
  grep -Eo 'exit[[:space:]]+[0-9]+' "$body" | awk '{print $2}' >"$codes_file"
  local code t7_bad=0
  while IFS= read -r code; do
    [[ -n "$code" ]] || continue
    if (( code != 0 && code < 10 )); then
      printf '[T7] %s _iso_summarize_script uses forbidden exit code: %s\n' "$base" "$code" >&2
      t7_bad=1
    fi
  done <"$codes_file"
  if (( t7_bad == 1 )); then
    smoke_fail "T7 $base _iso_summarize_script exit-code contract violated (must be 0 or >= 10)"
  fi

  # T7b — no heredoc / here-string in the inline body (footgun #11).
  if grep -Eq '[<][<]-?[A-Za-z_'"'"'"]|[<][<][<]' "$body"; then
    grep -nE '[<][<]-?[A-Za-z_'"'"'"]|[<][<][<]' "$body" >&2
    smoke_fail "T7 $base _iso_summarize_script contains a heredoc/here-string (footgun #11)"
  fi
  smoke_log "ok: T7 $base iso exit codes are 0 or >= 10, no heredoc/here-string"
}

assert_structure "$REPO_ROOT/scripts/wiki-monthly-summarize.sh" monthly
assert_structure "$REPO_ROOT/scripts/wiki-weekly-summarize.sh" weekly

# ---------------------------------------------------------------------
# T8 — Real iso reproducer. Linux + sudo + useradd required. Skipped
#      otherwise.
# ---------------------------------------------------------------------
ISO_USER=""
ISO_GROUP=""
ISO_USER_CREATED=""
ISO_WORKDIR=""

t8_should_run() {
  smoke_is_linux || { smoke_skip "T8 real iso reproducer" "host is not Linux"; return 1; }
  command -v sudo >/dev/null 2>&1 || { smoke_skip "T8 real iso reproducer" "sudo not installed"; return 1; }
  sudo -n true 2>/dev/null || { smoke_skip "T8 real iso reproducer" "sudo -n unavailable"; return 1; }
  command -v useradd >/dev/null 2>&1 || { smoke_skip "T8 real iso reproducer" "useradd not installed"; return 1; }
  command -v groupadd >/dev/null 2>&1 || { smoke_skip "T8 real iso reproducer" "groupadd not installed"; return 1; }
  return 0
}

if t8_should_run; then
  ISO_USER="agent-bridge-w1849"
  ISO_GROUP="ab-agent-w1849"
  ISO_WORKDIR="$SMOKE_TMP_ROOT/iso-workdir"

  if ! sudo -n groupadd -r "$ISO_GROUP" 2>/dev/null; then
    smoke_skip "T8 real iso reproducer" "groupadd -r $ISO_GROUP failed (group exists?)"
  elif ! sudo -n useradd -r -g "$ISO_GROUP" -M -s /usr/sbin/nologin "$ISO_USER" 2>/dev/null; then
    sudo -n groupdel "$ISO_GROUP" 2>/dev/null || true
    smoke_skip "T8 real iso reproducer" "useradd -r $ISO_USER failed"
  else
    ISO_USER_CREATED=1
    # Open just enough of the mktemp 0700 path so the iso user can chdir
    # through but cannot list (o+x only, no o+r). /tmp itself is 1777.
    chmod o+x "$SMOKE_TMP_ROOT" 2>/dev/null || true
    sudo -n mkdir -p "$ISO_WORKDIR/memory"
    sudo -n chown -R "$ISO_USER:$ISO_GROUP" "$ISO_WORKDIR"
    sudo -n chmod 2770 "$ISO_WORKDIR/memory"
    sudo -n chmod 2770 "$ISO_WORKDIR"

    # T8.a — controller direct write into iso-owned memory/ MUST fail (the
    # pre-fix shape: the summarize would write here and get Permission denied).
    T8A_PROBE="$ISO_WORKDIR/memory/.w1849-write-probe"
    if : >"$T8A_PROBE" 2>/dev/null; then
      rm -f "$T8A_PROBE" 2>/dev/null || true
      smoke_fail "T8.a controller wrote into iso-owned memory/ — fixture mode is wrong"
    fi
    smoke_log "ok: T8.a controller direct write into iso memory/ fails (pre-fix shape reproduced)"

    # T8.b — sudo-as-iso write via the same helper shape the fix uses
    # (`sudo -n -u <iso> bash -c '...'`). Proves the post-fix path works.
    T8B_PROBE="$ISO_WORKDIR/memory/.w1849-iso-probe"
    if ! sudo -n -u "$ISO_USER" bash -c "touch '$T8B_PROBE'"; then
      smoke_fail "T8.b sudo-as-iso write rc=$? — post-fix path is broken on this host"
    fi
    sudo -n test -e "$T8B_PROBE" \
      || smoke_fail "T8.b sudo-as-iso write reported success but file is absent"
    smoke_log "ok: T8.b sudo-as-iso write into iso memory/ succeeds (post-fix path works)"
  fi
fi

smoke_log "all assertions passed"
exit 0
