#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/bun-runtime-traverse.sh — L1 beta19 (codex r1 design
# 2026-05-25): exercise bridge_ensure_bun_runtime_traversable_for_isolated.
#
# The helper makes the operator's bun runtime traversable by isolated
# UIDs. It's specifically scoped to the `$HOME/.bun/` install layout
# (the official installer's drop location) — other PATH-resolved bun
# installs (homebrew, fnm, system /usr/bin) are no-op'd because their
# parent-mode contract is owned by another package manager.
#
# Tests:
#   T1 — fake $HOME/.bun/bin/bun symlinked from PATH-visible dir,
#        helper chmods $HOME/.bun and $HOME/.bun/bin to o+x (TRAVERSE
#        ONLY, not o+r).
#   T2 — BRIDGE_BUN_CHMOD_OPT_OUT=1 → modes unchanged.
#   T3 — Bun's real target is OUTSIDE $HOME → no-op (modes unchanged).
#
# Linux-only: chmod modes are gated on Linux. On macOS we still exercise
# the helper to make sure it doesn't crash, but we don't assert mode
# bits (macOS sticky/setgid handling differs from Linux). The whole
# helper is also a no-op on non-Linux by design (the chmod-traverse
# bug it closes is a Linux $HOME/0750 problem).
#
# Footgun #11 — no heredoc-stdin.

set -uo pipefail

SMOKE_NAME="bun-runtime-traverse"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

# Pick bash 4+ (same shape as phase2-install-tree-reconciler.sh).
if [[ -n "${BASH_BIN:-}" ]]; then
  SMOKE_BASH="$BASH_BIN"
elif [[ -x /opt/homebrew/bin/bash ]]; then
  SMOKE_BASH="/opt/homebrew/bin/bash"
elif [[ -x /usr/local/bin/bash ]]; then
  SMOKE_BASH="/usr/local/bin/bash"
else
  SMOKE_BASH="$(command -v bash)"
fi
[[ -n "$SMOKE_BASH" && -x "$SMOKE_BASH" ]] \
  || smoke_fail "no bash binary found"

stat_mode_o() {
  # Other-octal digit (last char of 3-digit mode).
  local path="$1" m
  if [[ "$(uname -s)" == "Darwin" ]]; then
    m="$(stat -f '%Lp' "$path" 2>/dev/null)"
  else
    m="$(stat -c '%a' "$path" 2>/dev/null)"
  fi
  # Take the last digit (other perms). Works for 3-digit and 4-digit
  # modes (the leading bits don't affect the other-bit position).
  printf '%s' "${m: -1}"
}

# Build a fake $HOME/.bun layout under the smoke temp root, plus a
# PATH-visible symlink pointing to it. The helper resolves PATH bun
# via `command -v bun`, then walks symlinks with readlink -f to find
# the real target.
build_bun_fixture() {
  local fake_home="$1"
  rm -rf "$fake_home"
  mkdir -p "$fake_home/.bun/bin"
  printf '#!/bin/sh\nexit 0\n' >"$fake_home/.bun/bin/bun"
  chmod 0755 "$fake_home/.bun/bin/bun"
  # Tighten $HOME/.bun and bin/ so the helper has actual work to do.
  chmod 0750 "$fake_home/.bun"
  chmod 0750 "$fake_home/.bun/bin"

  # PATH-visible symlink dir.
  mkdir -p "$fake_home/.local/bin"
  ln -sf "$fake_home/.bun/bin/bun" "$fake_home/.local/bin/bun"
}

build_external_bun_fixture() {
  # Bun at a path NOT under $HOME — simulates homebrew / system install.
  local fake_home="$1" extern_dir="$2"
  rm -rf "$fake_home" "$extern_dir"
  mkdir -p "$fake_home/.bun"
  # Tighten the unused $HOME/.bun so we can assert it remains untouched.
  chmod 0750 "$fake_home/.bun"

  mkdir -p "$extern_dir"
  printf '#!/bin/sh\nexit 0\n' >"$extern_dir/bun"
  chmod 0755 "$extern_dir/bun"
  chmod 0755 "$extern_dir"
}

# ---------------------------------------------------------------------------
# T1 — $HOME/.bun → chmod o+x (traverse only, not o+r)
# ---------------------------------------------------------------------------
test_t1_home_bun_traverse() {
  smoke_log "T1: $HOME/.bun bun → helper chmods o+x"
  local fake_home="$SMOKE_TMP_ROOT/t1-home"
  build_bun_fixture "$fake_home"

  HOME="$fake_home" PATH="$fake_home/.local/bin:$PATH" \
  "$SMOKE_BASH" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_ensure_bun_runtime_traversable_for_isolated 0
  " >"$SMOKE_TMP_ROOT/t1.out" 2>&1 || true

  if ! smoke_is_linux; then
    smoke_log "T1 SKIP (non-Linux: helper is a no-op outside Linux by design)"
    return 0
  fi

  # Assert $HOME/.bun and $HOME/.bun/bin gained o+x.
  local bun_o bin_o
  bun_o="$(stat_mode_o "$fake_home/.bun")"
  bin_o="$(stat_mode_o "$fake_home/.bun/bin")"
  # o+x means the other-bit-set value must include 1 (execute). For
  # 750→751 etc., the other digit becomes 1 (or higher if more bits
  # set). We just assert the execute bit is on: (other & 1) != 0.
  if (( (bun_o & 1) == 0 )); then
    smoke_fail "T1: $fake_home/.bun other-mode='$bun_o' lacks +x (expected (other & 1) != 0)"
  fi
  if (( (bin_o & 1) == 0 )); then
    smoke_fail "T1: $fake_home/.bun/bin other-mode='$bin_o' lacks +x"
  fi
  # Verify it's TRAVERSE ONLY — other-bit must NOT have +r (bit 4).
  if (( bun_o & 4 )); then
    smoke_fail "T1: $fake_home/.bun other-mode='$bun_o' has +r (read), helper must grant traverse only"
  fi
  if (( bin_o & 4 )); then
    smoke_fail "T1: $fake_home/.bun/bin other-mode='$bin_o' has +r (read), helper must grant traverse only"
  fi
  smoke_log "T1 PASS (.bun=$bun_o .bun/bin=$bin_o)"
}

# ---------------------------------------------------------------------------
# T2 — BRIDGE_BUN_CHMOD_OPT_OUT=1 → no chmod
# ---------------------------------------------------------------------------
test_t2_opt_out() {
  smoke_log "T2: BRIDGE_BUN_CHMOD_OPT_OUT=1 → no-op"
  local fake_home="$SMOKE_TMP_ROOT/t2-home"
  build_bun_fixture "$fake_home"

  local before_bun before_bin
  before_bun="$(stat_mode_o "$fake_home/.bun")"
  before_bin="$(stat_mode_o "$fake_home/.bun/bin")"

  HOME="$fake_home" PATH="$fake_home/.local/bin:$PATH" \
  BRIDGE_BUN_CHMOD_OPT_OUT=1 \
  "$SMOKE_BASH" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_ensure_bun_runtime_traversable_for_isolated 0
  " >"$SMOKE_TMP_ROOT/t2.out" 2>&1 || true

  local after_bun after_bin
  after_bun="$(stat_mode_o "$fake_home/.bun")"
  after_bin="$(stat_mode_o "$fake_home/.bun/bin")"

  if [[ "$before_bun" != "$after_bun" ]]; then
    smoke_fail "T2: $fake_home/.bun mode changed from '$before_bun' to '$after_bun' despite opt-out"
  fi
  if [[ "$before_bin" != "$after_bin" ]]; then
    smoke_fail "T2: $fake_home/.bun/bin mode changed from '$before_bin' to '$after_bin' despite opt-out"
  fi
  smoke_log "T2 PASS (modes unchanged: .bun=$after_bun .bun/bin=$after_bin)"
}

# ---------------------------------------------------------------------------
# T3 — bun NOT under $HOME → no-op
# ---------------------------------------------------------------------------
test_t3_external_bun_no_op() {
  smoke_log "T3: bun real target outside $HOME → no-op"
  local fake_home="$SMOKE_TMP_ROOT/t3-home"
  local extern_dir="$SMOKE_TMP_ROOT/t3-extern/bin"
  build_external_bun_fixture "$fake_home" "$extern_dir"

  local before_bun
  before_bun="$(stat_mode_o "$fake_home/.bun")"

  HOME="$fake_home" PATH="$extern_dir:$PATH" \
  "$SMOKE_BASH" -c "
    set -uo pipefail
    source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
    bridge_ensure_bun_runtime_traversable_for_isolated 0
  " >"$SMOKE_TMP_ROOT/t3.out" 2>&1 || true

  local after_bun
  after_bun="$(stat_mode_o "$fake_home/.bun")"

  if [[ "$before_bun" != "$after_bun" ]]; then
    smoke_fail "T3: $fake_home/.bun mode changed from '$before_bun' to '$after_bun' but bun is NOT under $HOME — helper must be no-op"
  fi
  smoke_log "T3 PASS (no-op for external bun, $fake_home/.bun mode=$after_bun unchanged)"
}

smoke_run "T1 home-bun-traverse" test_t1_home_bun_traverse
smoke_run "T2 opt-out" test_t2_opt_out
smoke_run "T3 external-bun-no-op" test_t3_external_bun_no_op

smoke_log "bun-runtime-traverse: ALL TESTS PASS"
exit 0
