#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1672-link-shared-settings-idempotent.sh — Issue #1672.
#
# On every iso-agent restart, `[bridge-hooks] link-shared-settings` logs a
# spurious `FileExistsError` for an already-existing settings symlink. Root
# cause: `_safe_path_check("is_symlink", settings_path)` false-negatives on an
# iso-owned existing symlink across the iso boundary (the controller's sudo
# probe can't stat it) → the caller concludes "no symlink present" → calls
# `settings_path.symlink_to(...)` → the symlink already exists → FileExistsError.
# Non-fatal (the outer `except OSError → return 0` swallows it), but spurious
# error spam every restart + masks the iso-boundary false-negative.
#
# Fix (#1672, codex FULL-consensus): make the symlink_to call idempotent. On
# FileExistsError, RE-CHECK the path: if it already resolves to the intended
# shared-settings target (resolved across the iso boundary via the existing
# `_safe_realpath` sudo `readlink -f` fallback) → treat as success / no warning.
# A wrong-target symlink or a non-symlink collision is a REAL conflict → the
# warning is PRESERVED.
#
# This smoke is HOST-AGNOSTIC: it runs on macOS dev hosts too. It drives
# `cmd_link_shared_settings` directly with stubs that reproduce the
# is_symlink false-negative (`_safe_path_check` returns False for both
# "is_symlink" and "exists") while the real fixture symlink sits on disk so
# the live `symlink_to` raises the real FileExistsError.
#
# Four cases:
#   T1 — non-iso, correct-target link → idempotent, no warning.
#   T2 — non-iso, wrong-target link → warning preserved.
#   T3 — ISO BOUNDARY, correct-target → idempotent via FORCED sudo readlink -f.
#        Teeth for codex #1672 finding 1: the harness makes the controller-
#        direct `os.path.realpath` BLIND (echoes the unresolved settings.json
#        path, mirroring how os.path.islink swallows the blocked lstat and
#        never raises PermissionError on the real boundary). If the fix relied
#        on `_safe_realpath` alone this case re-raises and the spurious warning
#        STILL fires; the forced `sudo readlink -f` path is what makes it pass.
#   T4 — ISO BOUNDARY, wrong-target → warning preserved (real conflict never
#        silently swallowed even across the boundary).
#
# Footgun #11 (heredoc_write deadlock class): every driver is built with
# `printf '%s\n' >file`; no `<<<` / `<<EOF` feeds into bash functions; no
# `$()` capture of heredoc-stdin.

set -uo pipefail

SMOKE_NAME="1672-link-shared-settings-idempotent"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# Shared harness that drives `cmd_link_shared_settings` with the
# is_symlink/exists false-negative reproduced. argv:
#   1 = repo root, 2 = workdir, 3 = shared-settings file
# Prints "rc=<n>" then the captured payload on stdout; the spurious
# FileExistsError warning (if any) goes to stderr.
HARNESS="$SMOKE_TMP_ROOT/probe-link-idempotent.py"
printf '%s\n' '#!/usr/bin/env python3' >"$HARNESS"
# shellcheck disable=SC2129  # per-line emit keeps footgun #11 (heredoc-stdin) off the table
printf '%s\n' 'import sys' >>"$HARNESS"
printf '%s\n' 'import argparse' >>"$HARNESS"
printf '%s\n' 'sys.path.insert(0, sys.argv[1])  # repo root for bridge-hooks.py import' >>"$HARNESS"
printf '%s\n' 'import importlib.util' >>"$HARNESS"
printf '%s\n' 'spec = importlib.util.spec_from_file_location("bridge_hooks", sys.argv[1] + "/bridge-hooks.py")' >>"$HARNESS"
printf '%s\n' 'mod = importlib.util.module_from_spec(spec)' >>"$HARNESS"
printf '%s\n' 'spec.loader.exec_module(mod)' >>"$HARNESS"
printf '%s\n' '# Force linux platform check to pass — smoke runs on macOS dev hosts too.' >>"$HARNESS"
printf '%s\n' 'mod.sys.platform = "linux"' >>"$HARNESS"
printf '%s\n' '# Reproduce the iso-boundary false-negative: the controller probe' >>"$HARNESS"
printf '%s\n' '# reports BOTH "is_symlink" and "exists" as False even though the link' >>"$HARNESS"
printf '%s\n' '# is physically present on disk. This is exactly the #1672 wedge:' >>"$HARNESS"
printf '%s\n' '# caller skips the symlink/exists branches → reaches symlink_to →' >>"$HARNESS"
printf '%s\n' '# FileExistsError because the link is already there.' >>"$HARNESS"
printf '%s\n' 'def fake_safe_path_check(check, path, os_user):' >>"$HARNESS"
printf '%s\n' '    return False' >>"$HARNESS"
printf '%s\n' 'mod._safe_path_check = fake_safe_path_check' >>"$HARNESS"
printf '%s\n' '# argv[4] (optional): iso owner. Empty/absent → non-isolated mode' >>"$HARNESS"
printf '%s\n' '# (os_user None, realpath/readlink run direct on the fixture tree —' >>"$HARNESS"
printf '%s\n' '# the dev-host path). Non-empty → ISO-BOUNDARY mode: simulate a' >>"$HARNESS"
printf '%s\n' '# controller that is BLIND to the iso-owned link and must escalate' >>"$HARNESS"
printf '%s\n' '# via sudo. This is the case codex #1672 finding 1 requires teeth on.' >>"$HARNESS"
printf '%s\n' 'ISO_OWNER = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None' >>"$HARNESS"
printf '%s\n' 'if ISO_OWNER:' >>"$HARNESS"
printf '%s\n' '    import os as _os' >>"$HARNESS"
printf '%s\n' '    import subprocess as _sp' >>"$HARNESS"
printf '%s\n' '    import importlib as _il' >>"$HARNESS"
printf '%s\n' '    _isop = _il.import_module("bridge_iso_paths")' >>"$HARNESS"
printf '%s\n' '    mod._isolated_workdir_owner = lambda path: ISO_OWNER' >>"$HARNESS"
printf '%s\n' '    # The crux of finding 1: on the real iso boundary the controller' >>"$HARNESS"
printf '%s\n' '    # cannot lstat the iso-owned link, and os.path.realpath SWALLOWS the' >>"$HARNESS"
printf '%s\n' '    # blocked lstat (islink→False) and returns the UNRESOLVED path —' >>"$HARNESS"
printf '%s\n' '    # it never raises PermissionError, so _safe_realpath`s sudo fallback' >>"$HARNESS"
printf '%s\n' '    # never fires. Reproduce that by making os.path.realpath echo its' >>"$HARNESS"
printf '%s\n' '    # input for the iso-owned link (controller is blind).' >>"$HARNESS"
printf '%s\n' '    _real_realpath = _os.path.realpath' >>"$HARNESS"
printf '%s\n' '    def _blind_realpath(p, *a, **k):' >>"$HARNESS"
printf '%s\n' '        sp = str(p)' >>"$HARNESS"
printf '%s\n' '        if sp.endswith("/.claude/settings.json"):' >>"$HARNESS"
printf '%s\n' '            return sp  # unresolved — controller blind across the boundary' >>"$HARNESS"
printf '%s\n' '        return _real_realpath(p, *a, **k)' >>"$HARNESS"
printf '%s\n' '    _isop.os.path.realpath = _blind_realpath' >>"$HARNESS"
printf '%s\n' '    # The owner (via sudo) CAN resolve/read the link. Model sudo by' >>"$HARNESS"
printf '%s\n' '    # actually running readlink as the current user (who owns the' >>"$HARNESS"
printf '%s\n' '    # fixture) — the point is the code MUST take the forced-sudo path,' >>"$HARNESS"
printf '%s\n' '    # not rely on the blind controller-direct realpath above.' >>"$HARNESS"
printf '%s\n' '    def _fake_sudo_capture(os_user, *cmd):' >>"$HARNESS"
printf '%s\n' '        proc = _sp.run(list(cmd), check=False, capture_output=True, text=True)' >>"$HARNESS"
printf '%s\n' '        return proc' >>"$HARNESS"
printf '%s\n' '    mod._sudo_run_as_capture = _fake_sudo_capture' >>"$HARNESS"
printf '%s\n' '    _isop.sudo_run_as_capture = _fake_sudo_capture' >>"$HARNESS"
printf '%s\n' 'else:' >>"$HARNESS"
printf '%s\n' '    # Non-isolated: os_user None → realpath/readlink run direct.' >>"$HARNESS"
printf '%s\n' '    mod._isolated_workdir_owner = lambda path: None' >>"$HARNESS"
printf '%s\n' '# _ensure_dir_with_sudo would try to (re)create the .claude dir; the' >>"$HARNESS"
printf '%s\n' '# fixture already has it, so make it a no-op to keep the harness focused' >>"$HARNESS"
printf '%s\n' '# on the symlink_to idempotency path.' >>"$HARNESS"
printf '%s\n' 'mod._ensure_dir_with_sudo = lambda path, os_user: None' >>"$HARNESS"
printf '%s\n' 'args = argparse.Namespace(' >>"$HARNESS"
printf '%s\n' '    workdir=sys.argv[2],' >>"$HARNESS"
printf '%s\n' '    shared_settings_file=sys.argv[3],' >>"$HARNESS"
printf '%s\n' '    format="shell",' >>"$HARNESS"
printf '%s\n' ')' >>"$HARNESS"
printf '%s\n' 'rc = mod.cmd_link_shared_settings(args)' >>"$HARNESS"
printf '%s\n' 'print("rc=%d" % rc)' >>"$HARNESS"

# Build a fixture workdir + shared-settings file. The on-disk
# `.claude/settings.json` is ALREADY a symlink, reproducing the
# already-linked iso-agent restart state.
build_fixture() {
  local label="$1"      # subdir under SMOKE_TMP_ROOT
  local link_target="$2"  # what the existing symlink points at (relative)
  local fixture_root="$SMOKE_TMP_ROOT/$label"
  local workdir="$fixture_root/workdir"
  local claude_dir="$workdir/.claude"
  local shared_file="$fixture_root/shared/settings.effective.json"  # noqa: iso-helper-boundary — test scaffolding, not a controller→iso boundary callsite
  mkdir -p "$claude_dir" "$fixture_root/shared"
  printf '%s\n' '{"smoke": "shared"}' >"$shared_file"
  # Pre-create the existing symlink at the settings.json site.
  ( cd "$claude_dir" && ln -s "$link_target" "settings.json" )
  printf '%s\n' "$workdir" "$shared_file"
}

# ---------- T1 — correct-target existing link → idempotent, NO warning ----------

# The existing link already points at the intended shared-settings file (the
# canonical relative target `../../shared/settings.effective.json`). Pre-fix:
# symlink_to raised FileExistsError → outer except OSError logged the spurious
# warning. Post-fix: the FileExistsError catch re-checks, sees the target
# already matches, marks unchanged, and emits NO warning.
T1_FIXTURE="$(build_fixture "t1" "../../shared/settings.effective.json")"  # noqa: iso-helper-boundary — test scaffolding, not a controller→iso boundary callsite
T1_WORKDIR="$(printf '%s\n' "$T1_FIXTURE" | sed -n 1p)"
T1_SHARED="$(printf '%s\n' "$T1_FIXTURE" | sed -n 2p)"

T1_ERR="$SMOKE_TMP_ROOT/t1.err"
T1_OUT="$("$PY_BIN" "$HARNESS" "$REPO_ROOT" "$T1_WORKDIR" "$T1_SHARED" 2>"$T1_ERR")" \
  || smoke_fail "T1 harness rc=$? — out: $T1_OUT; err: $(cat "$T1_ERR" 2>/dev/null)"
T1_ERR_BODY="$(cat "$T1_ERR" 2>/dev/null || printf '')"

smoke_assert_contains "$T1_OUT" "rc=0" "T1 cmd_link_shared_settings rc"
smoke_assert_not_contains "$T1_ERR_BODY" "FileExistsError" \
  "T1 correct-target link must NOT log a spurious FileExistsError"
smoke_assert_not_contains "$T1_ERR_BODY" "link-shared-settings:" \
  "T1 correct-target link must NOT log any link-shared-settings warning"
# The idempotent path marks the link unchanged (shlex.quote leaves the bare
# alphanumeric token unquoted).
smoke_assert_contains "$T1_OUT" "HOOK_STATUS=unchanged" \
  "T1 idempotent path reports HOOK_STATUS=unchanged"
smoke_log "T1 PASS: correct-target existing iso-owned link is idempotent (no FileExistsError, no warning)"

# ---------- T2 — wrong-target existing link → warning PRESERVED ----------

# The existing link points at a DIFFERENT file (a real conflict). The
# FileExistsError catch must NOT swallow this — it re-raises so the structured
# `link-shared-settings: FileExistsError ...` warning still fires (preserving
# the current behavior for genuine conflicts).
T2_FIXTURE="$(build_fixture "t2" "../../shared/some-other-file.json")"
T2_WORKDIR="$(printf '%s\n' "$T2_FIXTURE" | sed -n 1p)"
T2_SHARED="$(printf '%s\n' "$T2_FIXTURE" | sed -n 2p)"

T2_ERR="$SMOKE_TMP_ROOT/t2.err"
T2_OUT="$("$PY_BIN" "$HARNESS" "$REPO_ROOT" "$T2_WORKDIR" "$T2_SHARED" 2>"$T2_ERR")" \
  || smoke_fail "T2 harness rc=$? — out: $T2_OUT; err: $(cat "$T2_ERR" 2>/dev/null)"
T2_ERR_BODY="$(cat "$T2_ERR" 2>/dev/null || printf '')"

# Still non-fatal (return 0 via the outer except OSError), but the warning
# MUST be present for the genuine wrong-target conflict.
smoke_assert_contains "$T2_OUT" "rc=0" "T2 cmd_link_shared_settings rc (non-fatal)"
smoke_assert_contains "$T2_ERR_BODY" "FileExistsError" \
  "T2 wrong-target link MUST preserve the FileExistsError warning (real conflict)"
smoke_assert_contains "$T2_ERR_BODY" "link-shared-settings:" \
  "T2 wrong-target link MUST emit the structured link-shared-settings warning"
smoke_log "T2 PASS: wrong-target existing link preserves the FileExistsError warning"

# ---------- T3 — ISO-BOUNDARY correct-target → idempotent via forced sudo ------

# The teeth for codex #1672 finding 1. In iso mode the harness makes the
# controller-direct `os.path.realpath` BLIND (returns the unresolved
# settings.json path, exactly as the real boundary does because os.path.islink
# swallows the blocked lstat and never raises PermissionError). If the fix
# relied on `_safe_realpath` alone, `current_target` would be the unresolved
# path, would NOT equal the intended target, and the spurious warning would
# STILL fire. The fix forces `sudo readlink -f` first (`_resolve_iso_link_
# realpath`), so the correct-target link resolves correctly and is idempotent.
T3_FIXTURE="$(build_fixture "t3" "../../shared/settings.effective.json")"  # noqa: iso-helper-boundary — test scaffolding, not a controller→iso boundary callsite
T3_WORKDIR="$(printf '%s\n' "$T3_FIXTURE" | sed -n 1p)"
T3_SHARED="$(printf '%s\n' "$T3_FIXTURE" | sed -n 2p)"

T3_ERR="$SMOKE_TMP_ROOT/t3.err"
T3_OUT="$("$PY_BIN" "$HARNESS" "$REPO_ROOT" "$T3_WORKDIR" "$T3_SHARED" "agent-bridge-smoke1672" 2>"$T3_ERR")" \
  || smoke_fail "T3 harness rc=$? — out: $T3_OUT; err: $(cat "$T3_ERR" 2>/dev/null)"
T3_ERR_BODY="$(cat "$T3_ERR" 2>/dev/null || printf '')"

smoke_assert_contains "$T3_OUT" "rc=0" "T3 cmd_link_shared_settings rc"
smoke_assert_not_contains "$T3_ERR_BODY" "FileExistsError" \
  "T3 iso-boundary correct-target must NOT log FileExistsError (forced sudo readlink -f resolves it)"
smoke_assert_not_contains "$T3_ERR_BODY" "link-shared-settings:" \
  "T3 iso-boundary correct-target must NOT log any link-shared-settings warning"
smoke_assert_contains "$T3_OUT" "HOOK_STATUS=unchanged" \
  "T3 iso-boundary idempotent path reports HOOK_STATUS=unchanged"
smoke_log "T3 PASS: iso-boundary correct-target is idempotent via forced sudo readlink -f (controller-direct realpath blind)"

# ---------- T4 — ISO-BOUNDARY wrong-target → warning PRESERVED -----------------

# Same iso boundary, but the existing link points elsewhere. The forced sudo
# `readlink -f` resolves to a target that does NOT equal the intended shared
# file, so the catch re-raises and the structured warning is preserved (a real
# conflict is never silently swallowed even across the iso boundary).
T4_FIXTURE="$(build_fixture "t4" "../../shared/some-other-file.json")"
T4_WORKDIR="$(printf '%s\n' "$T4_FIXTURE" | sed -n 1p)"
T4_SHARED="$(printf '%s\n' "$T4_FIXTURE" | sed -n 2p)"

T4_ERR="$SMOKE_TMP_ROOT/t4.err"
T4_OUT="$("$PY_BIN" "$HARNESS" "$REPO_ROOT" "$T4_WORKDIR" "$T4_SHARED" "agent-bridge-smoke1672" 2>"$T4_ERR")" \
  || smoke_fail "T4 harness rc=$? — out: $T4_OUT; err: $(cat "$T4_ERR" 2>/dev/null)"
T4_ERR_BODY="$(cat "$T4_ERR" 2>/dev/null || printf '')"

smoke_assert_contains "$T4_OUT" "rc=0" "T4 cmd_link_shared_settings rc (non-fatal)"
smoke_assert_contains "$T4_ERR_BODY" "FileExistsError" \
  "T4 iso-boundary wrong-target MUST preserve the FileExistsError warning (real conflict)"
smoke_assert_contains "$T4_ERR_BODY" "link-shared-settings:" \
  "T4 iso-boundary wrong-target MUST emit the structured link-shared-settings warning"
smoke_log "T4 PASS: iso-boundary wrong-target preserves the FileExistsError warning"

smoke_log "all 4 tests PASS (#1672)"
