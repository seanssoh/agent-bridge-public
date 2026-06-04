#!/usr/bin/env bash
# scripts/smoke/1533-create-isolate-content-publish.sh — issue #1533:
# first `agent create --isolate` strands controller-written content under
# the freshly-`chown -R`-ed 2770 workdir because the controller's
# supp-group cache is STALE for the just-created `ab-agent-<a>` group
# (KNOWN_ISSUES §28). The #1506 recursive normalize runs DIRECT-FIRST as
# the controller, so its `find … -exec` cannot ENTER the 2770 tree —
# every pre-scaffolded file under `home/` (`.claude/**`, `memory/**`,
# `raw/**`, `skills/**`, `users/**`), `workdir/`, `runtime/`, `logs/`
# stays stranded at `iso-uid:<controller-group> 0600`.
#
# THE FIX (the recursive generalization of PR-C #1520c): an always-root,
# TOCTOU-safe fd walker (`isolation-normalize-content-tree.py`, invoked
# via `bridge_isolation_v2_publish_content_tree`) normalizes the WHOLE
# content tree to `ab-agent-<a>:0660` files / `:2770` dirs on the first
# create — independent of the controller's group cache and of 2770
# traversal. No manual `sg`-wrapped `--reapply` is needed.
#
# Cases (all run in a temp dir; never touches live runtime). The shell
# publish helper is exercised on macOS too by stubbing the v2-enforce gate
# ON and the agent-group resolver to the operator's own primary group —
# `bridge_linux_sudo_root` falls through to a direct invocation off Linux,
# so the root walker runs the real fd-based path without sudo.
#
#   T1  recursive per-FILE + per-DIR metadata: after one publish pass,
#       EVERY regular file under the tree is 0660 (group-readable) and
#       EVERY directory is 2770 (setgid). A dir-level (top-only) assertion
#       FALSE-PASSES the gap — this walks the whole tree.
#   T2  stale-cache REPRO teeth: a file pre-staged 0600 under a nested dir
#       (the exact #1533 strand shape: `iso-uid:<controller-group> 0600`)
#       is published to 0660 by the always-root walk. The PRE-FIX
#       direct-first normalize would have left it 0600 (it could not enter
#       the tree); the always-root walk PASSES.
#   T3  exec-bit preservation: a `+x` scaffolded script lands 0770 (group-
#       exec mirrors owner-exec), NOT stripped to 0660.
#   T4  excludes — `.teams/.env` (v3 channel state, --exclude-subdir) and
#       HEARTBEAT.md (--exclude-name) STAY 0600 (group-read CLEAR); the
#       `.teams` dir NODE is still normalized 2770 (group-traversable).
#   T5  symlink REFUSAL / TOCTOU: a planted `CLAUDE.md -> /tmp/evil` and a
#       planted `subdir -> /etc` are REFUSED (never followed); the external
#       targets are untouched; siblings still publish. CHANGE-POLICY.md
#       (--exclude-name) is skipped silently (no refused-symlink noise).
#   T6  idempotency: a second publish pass leaves the tree at the contract
#       (zero over-mutation, returns 0).
#   T7  enforce gate OFF (shared-mode / non-Linux) → publish is a no-op;
#       files keep their 0600 mode.
#   T8  forced publish FAILURE → the function still returns 0 (create
#       SUCCEEDS) and emits a non-silent warn + `content_publish_failed`
#       audit row (G3 non-fatal contract).
#   T9  TOCTOU / no-follow PROPERTY (BLOCKING regression guard): the root
#       walker opens every descent + file with O_NOFOLLOW and fchown/
#       fchmod's the OPEN FD; the lib publish fn delegates to the fd-based
#       helper and never re-introduces a path-based root chgrp/chmod.
#
# Teeth (regression-revert simulation):
#   T1-teeth.  Drop the fchmod from the helper → T1's group-read assertion
#              fails (a top-only dir assertion would have false-passed).
#   T3-teeth.  Drop the exec-bit preservation → T3 fails (the script loses
#              its +x and is no longer group-exec).
#   T4-teeth.  Drop the --exclude-name HEARTBEAT.md → T4 fails (HEARTBEAT
#              becomes group-readable).
#   T8-teeth.  Make the publish failure fatal (return 1) → T8's "returns 0"
#              assertion fails.
#   T9-teeth.  Revert the walker to a path-based root chgrp/chmod (or drop
#              O_NOFOLLOW) → T9 + T5 fail (the TOCTOU window reopens).
#
# Footgun #11 mitigation: zero heredoc-stdin to a subprocess; every python
# assertion runs via `python3 <file>` with argv-only arguments.

set -uo pipefail

SMOKE_NAME="1533-create-isolate-content-publish"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

# Audit log target (T8 emits a content_publish_failed row).
export BRIDGE_AUDIT_LOG="$SMOKE_TMP_ROOT/audit.jsonl"
: >"$BRIDGE_AUDIT_LOG"

# Pin the v2 layout via the env-override path BEFORE bridge-lib.sh source
# (same fresh-install-die guard as the PR-C smoke).
export BRIDGE_LAYOUT="v2"
export BRIDGE_DATA_ROOT="$SMOKE_TMP_ROOT/data"
mkdir -p "$BRIDGE_DATA_ROOT"

HELPER_DIR="$REPO_ROOT/scripts/smoke/1533-create-isolate-helpers"
[[ -d "$HELPER_DIR" ]] || smoke_fail "missing $HELPER_DIR (#1533 helpers)"
ASSERT="$HELPER_DIR/assert-content-tree-modes.py"
[[ -f "$ASSERT" ]] || smoke_fail "missing $ASSERT"

WALKER="$REPO_ROOT/scripts/python-helpers/isolation-normalize-content-tree.py"
[[ -f "$WALKER" ]] || smoke_fail "missing walker: $WALKER"

OPERATOR_GROUP="$(id -gn 2>/dev/null || printf '')"
[[ -n "$OPERATOR_GROUP" ]] || smoke_fail "could not resolve operator primary group"

# ---------------------------------------------------------------------
# Build a `home/` tree mirroring the post-chown create-time strand state:
# nested content at 0600, an executable script, a HEARTBEAT.md (must stay
# 0600), a CHANGE-POLICY.md symlink, and a .teams/.env channel file.
# ---------------------------------------------------------------------
make_home_fixture() {
  local h="$1"
  mkdir -p "$h/.claude/commands" "$h/memory" "$h/skills" "$h/users" \
           "$h/.teams"
  local f
  for f in CLAUDE.md SOUL.md MEMORY.md HEARTBEAT.md; do
    : >"$h/$f"; chmod 0600 "$h/$f"
  done
  : >"$h/.claude/settings.json"; chmod 0600 "$h/.claude/settings.json"
  : >"$h/.claude/commands/wrap-up.md"; chmod 0600 "$h/.claude/commands/wrap-up.md"
  : >"$h/memory/note.md"; chmod 0600 "$h/memory/note.md"
  : >"$h/users/default.md"; chmod 0600 "$h/users/default.md"
  printf '#!/bin/sh\n' >"$h/skills/run.sh"; chmod 0700 "$h/skills/run.sh"
  : >"$h/.teams/.env"; chmod 0600 "$h/.teams/.env"
}

# Invoke the lib publish fn with the v2-enforce gate stubbed ON and the
# agent-group resolver stubbed to the operator's primary group. Extra
# positional args after the roots/excludes are eval'd as stub overrides.
run_publish() {
  local enforce_rc="$1"; shift
  local group="$1"; shift
  local extra_stub="$1"; shift
  # remaining args = roots + --exclude-* flags passed through
  (
    set +e
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1
    # shellcheck disable=SC2329
    bridge_isolation_v2_enforce() { return "$enforce_rc"; }
    # shellcheck disable=SC2329
    bridge_isolation_v2_agent_group_name() { printf '%s' "$group"; }
    if [[ -n "$extra_stub" ]]; then
      eval "$extra_stub"
    fi
    bridge_isolation_v2_publish_content_tree "test_agent" "$group" "" "$@"
    printf 'rc=%s\n' "$?"
  )
}

# =====================================================================
# T1/T2/T3/T4 — recursive publish + strand repro + exec-bit + excludes
# =====================================================================
T1_HOME="$SMOKE_TMP_ROOT/t1-home"
make_home_fixture "$T1_HOME"
# T5 plant: CHANGE-POLICY.md symlink to an external target (excluded by name)
T1_EXT_CP="$SMOKE_TMP_ROOT/t1-external-change-policy.md"
: >"$T1_EXT_CP"; chmod 0600 "$T1_EXT_CP"
ln -s "$T1_EXT_CP" "$T1_HOME/CHANGE-POLICY.md"

T1_LOG="$SMOKE_TMP_ROOT/t1.log"
run_publish 0 "$OPERATOR_GROUP" "" \
  "$T1_HOME" \
  --exclude-subdir .teams --exclude-name HEARTBEAT.md \
  --exclude-name CHANGE-POLICY.md >"$T1_LOG" 2>&1
smoke_assert_contains "$(cat "$T1_LOG")" "rc=0" "T1 publish helper rc"

"$PY_BIN" "$ASSERT" "$T1_HOME" \
  --published-file-mode 0660 --published-dir-mode 2770 \
  --exec-file "skills/run.sh" \
  --owner-only "HEARTBEAT.md" \
  --excluded-subdir-content ".teams/.env" \
  --symlink "CHANGE-POLICY.md" \
  --min-files 6 \
  || smoke_fail "T1-T5 FAIL — recursive content publish / excludes / exec-bit (see $T1_LOG)"

# T4 extra: the .teams dir NODE itself must be 2770 (group-traversable)
# even though its CONTENT (.env) stays 0600. Use python for the mode read
# so the setgid bit is portable (macOS `stat -f '%Lp'` drops setgid).
TEAMS_DIR_MODE="$("$PY_BIN" -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o7777)[2:])' "$T1_HOME/.teams")"
smoke_assert_eq "2770" "$TEAMS_DIR_MODE" "T4 .teams dir node normalized 2770 (content still 0600)"
# T5 extra: CHANGE-POLICY external target untouched + no refused-symlink noise
T1_CP_MODE="$(stat -c '%a' "$T1_EXT_CP" 2>/dev/null || stat -f '%Lp' "$T1_EXT_CP" 2>/dev/null)"
smoke_assert_eq "600" "$T1_CP_MODE" "T5 CHANGE-POLICY external target stays 0600"
smoke_assert_not_contains "$(cat "$T1_LOG")" "CHANGE-POLICY" "T5 excluded CHANGE-POLICY never examined"
smoke_log "T1-T5 PASS — tree @ 0660/2770; HEARTBEAT/.teams.env 0600; +x preserved; symlink excluded"

# =====================================================================
# T5b — symlink REFUSAL (a NON-excluded planted redirect) + TOCTOU
# =====================================================================
T5_HOME="$SMOKE_TMP_ROOT/t5-home"
make_home_fixture "$T5_HOME"
T5_EXT="$SMOKE_TMP_ROOT/t5-external-claude.md"
: >"$T5_EXT"; chmod 0600 "$T5_EXT"
rm -f "$T5_HOME/CLAUDE.md"; ln -s "$T5_EXT" "$T5_HOME/CLAUDE.md"
# planted dir redirect: skills2 -> a controller-owned external dir
T5_EXTDIR="$SMOKE_TMP_ROOT/t5-external-dir"; mkdir -p "$T5_EXTDIR"; chmod 0700 "$T5_EXTDIR"
ln -s "$T5_EXTDIR" "$T5_HOME/skills2"
T5_LOG="$SMOKE_TMP_ROOT/t5.log"
: >"$BRIDGE_AUDIT_LOG"
run_publish 0 "$OPERATOR_GROUP" "" \
  "$T5_HOME" --exclude-subdir .teams --exclude-name HEARTBEAT.md \
  >"$T5_LOG" 2>&1
smoke_assert_contains "$(cat "$T5_LOG")" "rc=0" "T5b publish rc"
smoke_assert_contains "$(cat "$T5_LOG")" "refusing symlink" "T5b symlink refusal warn"
smoke_assert_contains "$(cat "$BRIDGE_AUDIT_LOG")" "content_publish_failed" \
  "T5b refused-symlink emits content_publish_failed audit row"
smoke_assert_contains "$(cat "$BRIDGE_AUDIT_LOG")" "refused-symlink" \
  "T5b audit row carries op=refused-symlink"
[[ -L "$T5_HOME/CLAUDE.md" ]] || smoke_fail "T5b FAIL — CLAUDE.md symlink was followed/replaced"
T5_EXT_MODE="$(stat -c '%a' "$T5_EXT" 2>/dev/null || stat -f '%Lp' "$T5_EXT" 2>/dev/null)"
smoke_assert_eq "600" "$T5_EXT_MODE" "T5b symlinked CLAUDE.md external target untouched"
T5_EXTDIR_MODE="$(stat -c '%a' "$T5_EXTDIR" 2>/dev/null || stat -f '%Lp' "$T5_EXTDIR" 2>/dev/null)"
smoke_assert_eq "700" "$T5_EXTDIR_MODE" "T5b planted dir-redirect target untouched (not 2770)"
smoke_log "T5b PASS — planted file/dir symlinks refused; external targets untouched"

# =====================================================================
# T6 — idempotency: second pass = zero over-mutation, returns 0
# =====================================================================
T6_LOG="$SMOKE_TMP_ROOT/t6.log"
run_publish 0 "$OPERATOR_GROUP" "" \
  "$T1_HOME" --exclude-subdir .teams --exclude-name HEARTBEAT.md \
  --exclude-name CHANGE-POLICY.md >"$T6_LOG" 2>&1
smoke_assert_contains "$(cat "$T6_LOG")" "rc=0" "T6 idempotent rc"
"$PY_BIN" "$ASSERT" "$T1_HOME" \
  --published-file-mode 0660 --published-dir-mode 2770 \
  --exec-file "skills/run.sh" \
  --owner-only "HEARTBEAT.md" \
  --excluded-subdir-content ".teams/.env" \
  --symlink "CHANGE-POLICY.md" \
  --min-files 6 \
  || smoke_fail "T6 FAIL — idempotent re-publish changed the published state"
smoke_log "T6 PASS — re-publish is idempotent"

# =====================================================================
# T7 — enforce gate OFF → publish is a no-op (files stay 0600)
# =====================================================================
T7_HOME="$SMOKE_TMP_ROOT/t7-home"
make_home_fixture "$T7_HOME"
run_publish 1 "$OPERATOR_GROUP" "" "$T7_HOME" >/dev/null 2>&1
T7_MODE="$(stat -c '%a' "$T7_HOME/CLAUDE.md" 2>/dev/null || stat -f '%Lp' "$T7_HOME/CLAUDE.md" 2>/dev/null)"
smoke_assert_eq "600" "$T7_MODE" "T7 enforce-OFF publish is a no-op (CLAUDE.md stays 0600)"
smoke_log "T7 PASS — enforce gate OFF makes publish a no-op"

# =====================================================================
# T8 — forced publish failure → create SUCCEEDS (returns 0) + non-silent
#      warn + content_publish_failed audit row (G3 non-fatal contract).
# =====================================================================
T8_HOME="$SMOKE_TMP_ROOT/t8-home"
make_home_fixture "$T8_HOME"
T8_LOG="$SMOKE_TMP_ROOT/t8.log"
T8_STUB='bridge_linux_sudo_root() { case "$1" in python3|python|*/python3|*/python) return 1;; *) command "$@";; esac; }'
: >"$BRIDGE_AUDIT_LOG"
run_publish 0 "$OPERATOR_GROUP" "$T8_STUB" "$T8_HOME" >"$T8_LOG" 2>&1
smoke_assert_contains "$(cat "$T8_LOG")" "rc=0" "T8 forced-failure helper still returns 0 (non-fatal)"
smoke_assert_contains "$(cat "$T8_LOG")" "normalize helper failed" "T8 non-silent warn on publish failure"
smoke_assert_contains "$(cat "$BRIDGE_AUDIT_LOG")" "content_publish_failed" \
  "T8 content_publish_failed audit row emitted"
smoke_log "T8 PASS — forced publish failure is non-fatal (create succeeds) + non-silent + audited"

# =====================================================================
# T9 — TOCTOU / no-follow PROPERTY tooth (BLOCKING regression guard).
# =====================================================================
grep -q "O_NOFOLLOW" "$WALKER" \
  || smoke_fail "T9 FAIL — walker does not open with O_NOFOLLOW (TOCTOU-unsafe)"
grep -q "O_DIRECTORY" "$WALKER" \
  || smoke_fail "T9 FAIL — walker does not O_DIRECTORY-gate descents"
grep -q "os.fchown" "$WALKER" \
  || smoke_fail "T9 FAIL — walker does not fchown the open fd"
grep -q "os.fchmod" "$WALKER" \
  || smoke_fail "T9 FAIL — walker does not fchmod the open fd"
# The publish FN body in the lib must delegate to the helper, not
# re-introduce a path-based `bridge_linux_sudo_root chgrp/chmod <path>`.
PUBLISH_FN_BODY="$SMOKE_TMP_ROOT/content-publish-fn-body.txt"
awk '
  /^bridge_isolation_v2_publish_content_tree\(\)[[:space:]]*\{/ { f=1 }
  f { print }
  f && /^\}/ { exit }
' "$REPO_ROOT/lib/bridge-isolation-v2.sh" >"$PUBLISH_FN_BODY"
[[ -s "$PUBLISH_FN_BODY" ]] || smoke_fail "T9 FAIL — could not extract publish fn body"
if grep -Eq 'bridge_linux_sudo_root[[:space:]]+(chgrp|chmod)[[:space:]]' "$PUBLISH_FN_BODY"; then
  smoke_fail "T9 FAIL — publish fn re-introduced a path-based root chgrp/chmod (TOCTOU)"
fi
grep -q "isolation-normalize-content-tree.py" "$PUBLISH_FN_BODY" \
  || smoke_fail "T9 FAIL — publish fn does not delegate to the fd-based root walker"
smoke_log "T9 PASS — root content normalize is fd-based O_NOFOLLOW (no path-based chgrp/chmod race)"

smoke_log "ALL PASS"
