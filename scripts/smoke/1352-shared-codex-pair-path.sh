#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1352-shared-codex-pair-path.sh — Issue #1352 (beta5-3 Track K).
#
# Shared-mode codex pair (the auto-provisioned <admin>-dev, isolation_mode:
# shared) died on first launch with `exit 127 codex: command not found` on a
# fresh install where `codex` lives under a user-local Node manager
# (nvm/pyenv/volta/asdf/fnm). The beta5-2 PATH-injection fix only covered the
# iso (sudo-wrap) codepath (lib/bridge-agents.sh:3699-3723); the shared
# codepath was never reached, and the daemon's own non-login PATH never had
# the manager dirs. On the reproducer host (`~/.nvm/versions/node/v24.16.0/
# bin/codex`, systemd-user daemon PATH) the picker-sweep cron then dispatched
# to the dead pair every 10 min → 152 unclaimed-task escalations over 6h.
#
# Root cause (precise): bridge_augment_engine_path (bridge-lib.sh, added in
# beta5-2 Lane ν #1317-A) gates its nvm auto-detect entirely on $NVM_DIR.
# Unlike pyenv/rbenv/asdf/fnm — all of which have a canonical $HOME/.<tool>
# fallback — nvm only exports $NVM_DIR from the operator's shellrc, which the
# daemon's systemd-user non-login shell never sources. So a default nvm
# install's `codex` never reached the launch PATH, bridge_resolve_engine_binary
# (= `command -v codex`) returned empty, BRIDGE_ENGINE_BIN stayed unset, the
# launch-cmd token rewrite was a no-op, and the bare `codex` token died 127.
#
# Fix (root, unifies shared + iso + daemon):
#   1. bridge-lib.sh bridge_augment_engine_path: add a canonical $HOME/.nvm
#      fallback when $NVM_DIR is unset, mirroring the pattern the other
#      managers already use. Manager-rotation-proof (no pinned Node version).
#   2. bridge-run.sh:349 (shared launch shell): re-augment via the same
#      canonical resolver (bridge_augment_engine_path) instead of a hard-coded
#      `~/.local/bin:~/.nix-profile/bin:/usr/local/bin` literal — removing the
#      iso-only special case so both codepaths resolve identically.
#
# Test plan:
#   T1: shared agent repro — fake canonical ~/.nvm/versions/node/vX/bin/codex,
#       $NVM_DIR UNSET, systemd-user-style PATH → bridge_augment_engine_path
#       puts the nvm bin dir on PATH and `command -v codex` resolves.
#   T2: iso codepath regression — bridge_resolve_engine_cli still resolves
#       (the same `command -v` it always used) and the iso sudo-wrap PATH
#       injection block at lib/bridge-agents.sh:3699-3723 is untouched
#       (static grep for the linux-user PATH-prepend sentinels).
#   T3: idempotent — re-invoke is a no-op; an engine already on the standard
#       PATH is not duplicated.
#   T4: both engines — `codex` AND `claude` under the canonical nvm dir both
#       resolve via the same fallback.
#   T5 (teeth): the canonical-fallback gate is what makes T1 pass — the
#       pre-fix nvm-gating ($NVM_DIR only) fails the exact same scenario, and
#       bridge-run.sh wiring the bare-literal export back in (dropping the
#       bridge_augment_engine_path call) re-introduces the iso-only special
#       case. Both pinned via static grep + a behavioral teeth check.
#
# Footgun #11 (heredoc_write deadlock class): this fixture uses only
# `printf`/`awk … >file` and `env -i … bash -c '…'` invocations — no command
# substitution feeding a heredoc stdin, no `<<<` here-strings into bridge
# functions.

set -euo pipefail

# Re-exec under Bash 4+ (the extracted helper bodies and the larger lib stack
# they belong to assume Bash 4 semantics).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1352-shared-codex-pair-path] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1352-shared-codex-pair-path"
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
LIB_SH="$REPO_ROOT/bridge-lib.sh"
RUN_SH="$REPO_ROOT/bridge-run.sh"
AGENTS_LIB="$REPO_ROOT/lib/bridge-agents.sh"

smoke_assert_file_exists "$LIB_SH" "bridge-lib.sh present"
smoke_assert_file_exists "$RUN_SH" "bridge-run.sh present"
smoke_assert_file_exists "$AGENTS_LIB" "lib/bridge-agents.sh present"

BASH_BIN="$(command -v bash)"

# Extract the PATH helpers from bridge-lib.sh into a standalone driver so we
# exercise the real source without bridge-lib.sh's full init side effects.
# bridge_augment_engine_path now calls bridge_dir_has_engine_cli (codex r1
# engine-presence fix), so all three must be pulled in.
DRIVER="$SMOKE_TMP_ROOT/path-helpers.sh"
awk '/^bridge_prepend_path_entry\(\) \{/,/^\}/ { print }' "$LIB_SH" >"$DRIVER"
awk '/^bridge_dir_has_engine_cli\(\) \{/,/^\}/ { print }' "$LIB_SH" >>"$DRIVER"
awk '/^bridge_augment_engine_path\(\) \{/,/^\}/ { print }' "$LIB_SH" >>"$DRIVER"

if ! grep -q '^bridge_prepend_path_entry() {' "$DRIVER"; then
  smoke_fail "setup: bridge_prepend_path_entry extract missing"
fi
if ! grep -q '^bridge_dir_has_engine_cli() {' "$DRIVER"; then
  smoke_fail "setup: bridge_dir_has_engine_cli extract missing (engine-presence fix reverted)"
fi
if ! grep -q '^bridge_augment_engine_path() {' "$DRIVER"; then
  smoke_fail "setup: bridge_augment_engine_path extract missing (likely fix reverted)"
fi

# ---------------------------------------------------------------------
# T1 — shared agent repro: canonical ~/.nvm, $NVM_DIR UNSET, daemon PATH.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t1_driver() {
  local _home="$SMOKE_TMP_ROOT/t1-home"
  local _nvm_bin="$_home/.nvm/versions/node/v24.16.0/bin"
  mkdir -p "$_nvm_bin"
  : >"$_nvm_bin/codex"
  chmod +x "$_nvm_bin/codex"

  # systemd-user default PATH (no node-manager dirs), $NVM_DIR explicitly
  # unset via env -i (it is simply absent).
  local _resolved
  _resolved="$(env -i \
      PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      HOME="$_home" \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_augment_engine_path; command -v codex 2>/dev/null || true")"
  smoke_assert_eq "$_nvm_bin/codex" "$_resolved" \
    "T1: canonical ~/.nvm codex resolves with NVM_DIR unset (shared-mode daemon repro)"
}
smoke_run "T1 shared-mode canonical-nvm resolution" t1_driver

# ---------------------------------------------------------------------
# T2 — iso codepath unchanged (no regression).
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t2_driver() {
  # The iso sudo-wrap PATH injection block (lib/bridge-agents.sh:3699-3723)
  # must remain intact: it resolves the engine CLI dir and prepends it for
  # the linux-user codepath only. Pin its sentinels so a future PR cannot
  # silently drop the iso injection while editing the shared path.
  if ! grep -q 'Inject engine CLI directory into PATH for sudo-wrapped launchers' "$AGENTS_LIB"; then
    smoke_fail "T2: iso PATH-injection comment sentinel missing — iso fix may have regressed"
  fi
  if ! grep -q 'bridge_resolve_engine_cli "\$engine"' "$AGENTS_LIB"; then
    smoke_fail "T2: iso bridge_resolve_engine_cli call missing — iso fix may have regressed"
  fi
  # The iso block is gated on linux-user isolation; that gate must still
  # wrap the engine-dir prepend.
  if ! grep -q 'if \[\[ "\$isolation_mode" == "linux-user" \]\]; then' "$AGENTS_LIB"; then
    smoke_fail "T2: linux-user isolation gate missing — iso fix may have regressed"
  fi

  # bridge_resolve_engine_cli still resolves the same way it always did
  # (`command -v`), and the canonical-nvm fallback now helps it too.
  local _home="$SMOKE_TMP_ROOT/t2-home"
  local _nvm_bin="$_home/.nvm/versions/node/v22.0.0/bin"
  mkdir -p "$_nvm_bin"
  : >"$_nvm_bin/codex"
  chmod +x "$_nvm_bin/codex"
  local _resolved
  _resolved="$(env -i \
      PATH="/usr/local/bin:/usr/bin:/bin" \
      HOME="$_home" \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_augment_engine_path; command -v codex 2>/dev/null || true")"
  smoke_assert_eq "$_nvm_bin/codex" "$_resolved" \
    "T2: controller-side engine resolution (iso prep) benefits from same fallback"
}
smoke_run "T2 iso codepath untouched" t2_driver

# ---------------------------------------------------------------------
# T3 — idempotent; engine already on standard PATH not duplicated.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t3_driver() {
  local _home="$SMOKE_TMP_ROOT/t3-home"
  local _nvm_bin="$_home/.nvm/versions/node/v20.0.0/bin"
  mkdir -p "$_nvm_bin"
  : >"$_nvm_bin/codex"
  chmod +x "$_nvm_bin/codex"

  # Re-invoke twice; the nvm dir must appear exactly once on PATH.
  local _count
  _count="$(env -i \
      PATH="/usr/local/bin:/usr/bin:/bin" \
      HOME="$_home" \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_augment_engine_path; bridge_augment_engine_path; printf '%s' \"\$PATH\" | tr ':' '\n' | grep -c 'v20.0.0/bin'")"
  smoke_assert_eq "1" "$_count" \
    "T3: bridge_augment_engine_path is idempotent (nvm dir added once on re-invoke)"
}
smoke_run "T3 idempotency" t3_driver

# ---------------------------------------------------------------------
# T4 — both codex and claude resolve via the canonical nvm fallback.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t4_driver() {
  local _home="$SMOKE_TMP_ROOT/t4-home"
  local _nvm_bin="$_home/.nvm/versions/node/v24.16.0/bin"
  mkdir -p "$_nvm_bin"
  : >"$_nvm_bin/codex"; chmod +x "$_nvm_bin/codex"
  : >"$_nvm_bin/claude"; chmod +x "$_nvm_bin/claude"

  local _both
  _both="$(env -i \
      PATH="/usr/local/bin:/usr/bin:/bin" \
      HOME="$_home" \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_augment_engine_path; printf '%s|%s' \"\$(command -v codex 2>/dev/null || true)\" \"\$(command -v claude 2>/dev/null || true)\"")"
  smoke_assert_eq "$_nvm_bin/codex|$_nvm_bin/claude" "$_both" \
    "T4: both codex and claude resolve via canonical-nvm fallback"

  # T4b: volta canonical fallback ($HOME/.volta/bin, $VOLTA_HOME unset) —
  # same daemon non-login-shell class the issue calls out alongside nvm.
  local _vhome="$SMOKE_TMP_ROOT/t4-volta-home"
  mkdir -p "$_vhome/.volta/bin"
  : >"$_vhome/.volta/bin/codex"; chmod +x "$_vhome/.volta/bin/codex"
  local _volta_resolved
  _volta_resolved="$(env -i \
      PATH="/usr/local/bin:/usr/bin:/bin" \
      HOME="$_vhome" \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_augment_engine_path; command -v codex 2>/dev/null || true")"
  smoke_assert_eq "$_vhome/.volta/bin/codex" "$_volta_resolved" \
    "T4b: canonical ~/.volta/bin codex resolves with VOLTA_HOME unset"
}
smoke_run "T4 codex + claude + volta" t4_driver

# ---------------------------------------------------------------------
# T5 (teeth) — the fix is what makes T1 pass; reverting either layer
# re-introduces the bug.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t5_driver() {
  # Teeth-A (behavioral): the PRE-FIX nvm gating ($NVM_DIR only, no canonical
  # fallback) fails the exact T1 scenario. We reconstruct that gating inline
  # and assert codex stays unresolvable — proving the canonical fallback is
  # load-bearing.
  local _home="$SMOKE_TMP_ROOT/t5-home"
  local _nvm_bin="$_home/.nvm/versions/node/v24.16.0/bin"
  mkdir -p "$_nvm_bin"
  : >"$_nvm_bin/codex"; chmod +x "$_nvm_bin/codex"
  local _old_resolved
  _old_resolved="$(env -i \
      PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      HOME="$_home" \
      "$BASH_BIN" -c '
        prepend() { local e="$1"; [[ -n "$e" ]]||return 0; [[ -d "$e" ]]||return 0; case ":$PATH:" in *":$e:"*) ;; *) PATH="$e${PATH:+:$PATH}";; esac; }
        # Pre-fix nvm gating: gated entirely on $NVM_DIR.
        if [[ -n "${NVM_DIR:-}" && -d "$NVM_DIR/versions/node" ]]; then prepend "x"; fi
        command -v codex 2>/dev/null || true')"
  smoke_assert_eq "" "$_old_resolved" \
    "T5-A teeth: pre-fix NVM_DIR-only gating fails the shared-mode repro (codex not found)"

  # Teeth-B (static): bridge-lib.sh's nvm branch must carry the canonical
  # ~/.nvm fallback. Pin the sentinel so a revert is caught.
  if ! grep -q 'HOME/.nvm/versions/node' "$LIB_SH"; then
    smoke_fail "T5-B teeth: canonical \$HOME/.nvm fallback missing from bridge-lib.sh (fix reverted)"
  fi

  # Teeth-C (static): bridge-run.sh must call bridge_augment_engine_path
  # rather than re-export the hard-coded 3-dir literal (the iso-only special
  # case). Pin the call site and assert the bare literal is gone.
  if ! grep -q 'bridge_augment_engine_path' "$RUN_SH"; then
    smoke_fail "T5-C teeth: bridge-run.sh no longer calls bridge_augment_engine_path (fix reverted)"
  fi
  if grep -q 'export PATH="\$HOME/.local/bin:\$HOME/.nix-profile/bin:/usr/local/bin:\$PATH"' "$RUN_SH"; then
    smoke_fail "T5-C teeth: bridge-run.sh still uses the hard-coded PATH literal (iso-only special case not removed)"
  fi
}
smoke_run "T5 teeth (revert detection)" t5_driver

# ---------------------------------------------------------------------
# T6 — multi-version nvm regression (codex r1 BLOCKING): semver-aware
# selection + engine-presence verification.
# ---------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked via smoke_run
t6_driver() {
  # Sub-test 6a (lexicographic trap + engine-presence): two nvm versions —
  # v9.99.0 has node but NOT codex, v24.16.0 has codex. A lexicographic
  # `sort | tail -1` ranks v9.99.0 last (after v24.16.0) AND a presence-
  # blind selection would prepend an engine-less dir. The fixed selection
  # must pick v24.16.0/bin so `command -v codex` actually resolves.
  local _home="$SMOKE_TMP_ROOT/t6a-home"
  mkdir -p "$_home/.nvm/versions/node/v9.99.0/bin" \
           "$_home/.nvm/versions/node/v24.16.0/bin"
  : >"$_home/.nvm/versions/node/v9.99.0/bin/node"; chmod +x "$_home/.nvm/versions/node/v9.99.0/bin/node"
  : >"$_home/.nvm/versions/node/v24.16.0/bin/codex"; chmod +x "$_home/.nvm/versions/node/v24.16.0/bin/codex"
  local _resolved_6a
  _resolved_6a="$(env -i \
      PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      HOME="$_home" \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_augment_engine_path; command -v codex 2>/dev/null || true")"
  smoke_assert_eq "$_home/.nvm/versions/node/v24.16.0/bin/codex" "$_resolved_6a" \
    "T6a: multi-version trap — semver+engine-presence picks v24.16.0 (not lex-last/engine-less v9.99.0)"

  # Sub-test 6b (both versions have engine, no default alias): the highest
  # semver wins deterministically (v24.16.0 > v18.0.0 under sort -V).
  local _home_b="$SMOKE_TMP_ROOT/t6b-home"
  mkdir -p "$_home_b/.nvm/versions/node/v18.0.0/bin" \
           "$_home_b/.nvm/versions/node/v24.16.0/bin"
  : >"$_home_b/.nvm/versions/node/v18.0.0/bin/codex"; chmod +x "$_home_b/.nvm/versions/node/v18.0.0/bin/codex"
  : >"$_home_b/.nvm/versions/node/v24.16.0/bin/codex"; chmod +x "$_home_b/.nvm/versions/node/v24.16.0/bin/codex"
  local _resolved_6b
  _resolved_6b="$(env -i \
      PATH="/usr/local/bin:/usr/bin:/bin" \
      HOME="$_home_b" \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_augment_engine_path; command -v codex 2>/dev/null || true")"
  smoke_assert_eq "$_home_b/.nvm/versions/node/v24.16.0/bin/codex" "$_resolved_6b" \
    "T6b: both engine-bearing, no alias — highest semver (v24.16.0) chosen deterministically"

  # Sub-test 6c (default alias wins over higher semver): default→v18, both
  # have engine → v18 (operator intent) not v24.
  local _home_c="$SMOKE_TMP_ROOT/t6c-home"
  mkdir -p "$_home_c/.nvm/versions/node/v18.0.0/bin" \
           "$_home_c/.nvm/versions/node/v24.16.0/bin" \
           "$_home_c/.nvm/alias"
  : >"$_home_c/.nvm/versions/node/v18.0.0/bin/codex"; chmod +x "$_home_c/.nvm/versions/node/v18.0.0/bin/codex"
  : >"$_home_c/.nvm/versions/node/v24.16.0/bin/codex"; chmod +x "$_home_c/.nvm/versions/node/v24.16.0/bin/codex"
  printf 'v18.0.0\n' >"$_home_c/.nvm/alias/default"
  local _resolved_6c
  _resolved_6c="$(env -i \
      PATH="/usr/local/bin:/usr/bin:/bin" \
      HOME="$_home_c" \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_augment_engine_path; command -v codex 2>/dev/null || true")"
  smoke_assert_eq "$_home_c/.nvm/versions/node/v18.0.0/bin/codex" "$_resolved_6c" \
    "T6c: default alias (v18.0.0, engine-bearing) wins over higher-semver v24.16.0"

  # Sub-test 6d (graceful when NO version has an engine): no .nvm dir is
  # prepended (no false positive). Assert no .nvm path lands on PATH.
  local _home_d="$SMOKE_TMP_ROOT/t6d-home"
  mkdir -p "$_home_d/.nvm/versions/node/v9.99.0/bin"
  : >"$_home_d/.nvm/versions/node/v9.99.0/bin/node"; chmod +x "$_home_d/.nvm/versions/node/v9.99.0/bin/node"
  local _nvm_on_path_6d
  _nvm_on_path_6d="$(env -i \
      PATH="/usr/local/bin:/usr/bin:/bin" \
      HOME="$_home_d" \
      "$BASH_BIN" -c "source '$DRIVER'; bridge_augment_engine_path; printf '%s' \"\$PATH\" | tr ':' '\n' | grep -c '.nvm/versions/node' || true")"
  smoke_assert_eq "0" "$_nvm_on_path_6d" \
    "T6d: no engine-bearing nvm version — graceful, no false prepend"

  # Teeth (T6e behavioral): the PRE-FIX selection (lexicographic sort, no
  # engine-presence check) fails the 6a trap. Reconstruct it inline and
  # assert it picks the engine-less v9.99.0/bin so codex stays unresolved.
  local _resolved_teeth
  _resolved_teeth="$(env -i \
      PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      HOME="$_home" \
      "$BASH_BIN" -c '
        root="$HOME/.nvm"
        # Pre-fix: lexicographic sort, take last, no engine-presence check.
        latest="$(ls -1 "$root/versions/node" 2>/dev/null | sort | tail -n1)"
        if [[ -n "$latest" && -d "$root/versions/node/$latest/bin" ]]; then
          PATH="$root/versions/node/$latest/bin:$PATH"
        fi
        command -v codex 2>/dev/null || true')"
  smoke_assert_eq "" "$_resolved_teeth" \
    "T6e teeth: pre-fix lexicographic+presence-blind selection picks engine-less v9.99.0 (codex unresolved)"

  # Teeth (T6f static): bridge-lib.sh must use sort -V (NOT bare sort) and
  # the engine-presence helper. Pin both sentinels.
  if ! grep -q 'sort -Vr' "$LIB_SH"; then
    smoke_fail "T6f teeth: semver-aware 'sort -Vr' missing from bridge-lib.sh nvm selection (lexicographic regression)"
  fi
  if grep -qE '\| *sort *\| *tail' "$LIB_SH"; then
    smoke_fail "T6f teeth: bridge-lib.sh still contains a lexicographic 'sort | tail' (must be sort -V)"
  fi
  if ! grep -q 'bridge_dir_has_engine_cli' "$LIB_SH"; then
    smoke_fail "T6f teeth: engine-presence helper bridge_dir_has_engine_cli missing from bridge-lib.sh"
  fi
}
smoke_run "T6 multi-version nvm (semver + engine-presence)" t6_driver

smoke_log "PASS: $SMOKE_NAME (T1-T6)"
