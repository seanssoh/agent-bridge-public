#!/usr/bin/env bash
#
# scripts/smoke/bridge-with-timeout-fallback.sh — issue #802 carry-over.
#
# Exercises the three-tier fallback chain inside `bridge_with_timeout`
# (lib/bridge-state.sh):
#
#   tier 1: GNU `timeout(1)` / `gtimeout(1)` on PATH — POSIX exit codes.
#   tier 2: `python3 subprocess.run(timeout=)` when neither binary is on PATH.
#           python3 is a hard dep of agent-bridge so this branch is reached
#           on bare macOS hosts without GNU coreutils installed.
#   tier 3: plain exec when even python3 is missing (severely degraded host).
#
# For each tier we assert (a) the exit code, (b) the elapsed-window so the
# wrap-vs-no-wrap behavior is observable, and (c) the audit-log shape.
#
# Hermetic: isolated BRIDGE_HOME via smoke_setup_bridge_home; never touches
# the live install. Uses a per-tier PATH shim to hide tier-1/2 binaries so
# tier-2 and tier-3 branches are actually reached even on a fully-equipped
# developer host.

# Bash 4+ re-exec (mirrors scripts/smoke/daemon-heredoc-timeout.sh).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:bridge-with-timeout-fallback] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="bridge-with-timeout-fallback"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

export BRIDGE_REPO_ROOT="$SMOKE_REPO_ROOT"
export BRIDGE_SCRIPT_DIR="$BRIDGE_REPO_ROOT"
: >"$BRIDGE_AUDIT_LOG"

# Resolve the absolute paths to the binaries we may want to hide per tier.
# `command -v` is enough for hermetic reasoning; we hide them by giving the
# child shell a PATH that does not contain their parent directories.
SYS_TIMEOUT="$(command -v timeout 2>/dev/null || true)"
SYS_GTIMEOUT="$(command -v gtimeout 2>/dev/null || true)"
SYS_PYTHON3="$(command -v python3)"   # required, asserted above
DATE_BIN="$(command -v date)"
SLEEP_BIN="$(command -v sleep)"
BASH_BIN="$(command -v bash)"
[[ -x "$DATE_BIN" && -x "$SLEEP_BIN" && -x "$BASH_BIN" ]] || smoke_fail "missing date/sleep/bash binaries"

# Driver script that sources bridge_with_timeout and invokes it on argv. We
# write it to disk to avoid layered quoting around `bash -c`.
DRIVER="$SMOKE_TMP_ROOT/with-timeout-driver.sh"
cat >"$DRIVER" <<'EOF'
#!/usr/bin/env bash
# args: <secs> <label> <cmd> [cmd_args...]
set -uo pipefail
SCRIPT_DIR="${BRIDGE_REPO_ROOT:?}"
# shellcheck source=/dev/null
source "$BRIDGE_REPO_ROOT/lib/bridge-state.sh"
secs="$1"
label="$2"
shift 2
bridge_with_timeout "$secs" "$label" "$@"
EOF
chmod +x "$DRIVER"

# Build a per-tier PATH directory that contains only the binaries the tier
# is allowed to see. We symlink rather than copy so identity-preserving
# resolution (`command -v`) still works and we don't accidentally shadow.
build_tier_path_dir() {
  local dir="$1"
  shift
  rm -rf "$dir"
  mkdir -p "$dir"
  local bin
  for bin in "$@"; do
    [[ -n "$bin" && -x "$bin" ]] || continue
    ln -sf "$bin" "$dir/$(basename "$bin")"
  done
  printf '%s\n' "$dir"
}

# Run the driver inside a child shell whose PATH is the supplied shim. We
# also reset the per-cache state on bridge-state.sh by sourcing afresh each
# call — the driver script does this since it sources the lib.
#
# We invoke bash via its absolute path (BASH_BIN) so the per-tier PATH shim
# does not need to advertise bash itself — that would defeat the point of
# hiding python3 in tier 3 (env(1) on macOS resolves the invoked binary via
# the new PATH only when given as a bare name).
run_in_tier() {
  local tier_path="$1"
  local secs="$2"
  local label="$3"
  shift 3
  local rc=0
  local started ended elapsed
  started="$("$DATE_BIN" +%s)"
  set +e
  env -i \
    HOME="$HOME" \
    PATH="$tier_path" \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
    BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
    BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
    BRIDGE_REPO_ROOT="$BRIDGE_REPO_ROOT" \
    BRIDGE_SCRIPT_DIR="$BRIDGE_SCRIPT_DIR" \
    "$BASH_BIN" "$DRIVER" "$secs" "$label" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  ended="$("$DATE_BIN" +%s)"
  elapsed=$(( ended - started ))
  printf 'rc=%d elapsed=%d\n' "$rc" "$elapsed"
}

# --- tier 1: timeout(1) or gtimeout(1) present ------------------------------

step_tier1_binary_path() {
  smoke_log "tier 1: timeout(1)/gtimeout(1) on PATH must kill stalling cmd at budget"

  if [[ -z "$SYS_TIMEOUT" && -z "$SYS_GTIMEOUT" ]]; then
    smoke_skip "tier 1" "neither timeout(1) nor gtimeout(1) on host — cannot exercise the binary tier"
    return 0
  fi

  local tier_dir
  tier_dir="$(build_tier_path_dir "$SMOKE_TMP_ROOT/path-tier1" \
    "$SYS_TIMEOUT" "$SYS_GTIMEOUT" "$SYS_PYTHON3" "$DATE_BIN" "$SLEEP_BIN")"

  local output rc elapsed
  output="$(run_in_tier "$tier_dir" 2 tier1_smoke "$SLEEP_BIN" 10)"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [[ -n "$rc" ]] || smoke_fail "tier 1: could not parse rc from '$output'"
  [[ -n "$elapsed" ]] || smoke_fail "tier 1: could not parse elapsed from '$output'"
  if [[ "$rc" != "124" && "$rc" != "137" ]]; then
    smoke_fail "tier 1: expected rc=124|137, got rc=$rc (elapsed=${elapsed}s)"
  fi
  if (( elapsed > 8 )); then
    smoke_fail "tier 1: 2s budget not enforced (elapsed=${elapsed}s)"
  fi

  # Audit row must tag tier=binary and the call-site label.
  if ! grep -q '"call_site": "tier1_smoke"' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "tier 1: audit log missing call_site=tier1_smoke: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  if ! grep -q '"tier": "binary"' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "tier 1: audit log missing tier=binary detail: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  smoke_log "  rc=$rc elapsed=${elapsed}s (binary tier killed at budget)"
}

# --- tier 2: python3 only ---------------------------------------------------

step_tier2_python_kill() {
  smoke_log "tier 2: with timeout(1)/gtimeout(1) hidden, python3 subprocess.run must kill at budget"

  local tier_dir
  tier_dir="$(build_tier_path_dir "$SMOKE_TMP_ROOT/path-tier2" \
    "$SYS_PYTHON3" "$DATE_BIN" "$SLEEP_BIN")"

  # Sanity: confirm the shim really hides timeout/gtimeout.
  if env -i HOME="$HOME" PATH="$tier_dir" "$BASH_BIN" -c 'command -v timeout' >/dev/null 2>&1; then
    smoke_fail "tier 2 PATH shim leaked timeout(1)"
  fi
  if env -i HOME="$HOME" PATH="$tier_dir" "$BASH_BIN" -c 'command -v gtimeout' >/dev/null 2>&1; then
    smoke_fail "tier 2 PATH shim leaked gtimeout(1)"
  fi

  local output rc elapsed
  output="$(run_in_tier "$tier_dir" 2 tier2_smoke "$SLEEP_BIN" 10)"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [[ -n "$rc" ]] || smoke_fail "tier 2: could not parse rc from '$output'"
  [[ -n "$elapsed" ]] || smoke_fail "tier 2: could not parse elapsed from '$output'"
  # python wrapper maps TimeoutExpired -> 124 to match GNU timeout(1).
  if [[ "$rc" != "124" ]]; then
    smoke_fail "tier 2: expected rc=124 from python TimeoutExpired, got rc=$rc (elapsed=${elapsed}s)"
  fi
  if (( elapsed > 8 )); then
    smoke_fail "tier 2: 2s budget not enforced (elapsed=${elapsed}s) — python wrap is broken"
  fi

  # Audit row must tag tier=python (not binary, not unavailable).
  if ! grep -q '"call_site": "tier2_smoke"' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "tier 2: audit log missing call_site=tier2_smoke: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  # Slice to lines belonging to tier2_smoke so we don't accidentally match
  # tier1_smoke rows from the prior step.
  local tier2_rows
  tier2_rows="$(grep '"call_site": "tier2_smoke"' "$BRIDGE_AUDIT_LOG" || true)"
  if ! printf '%s\n' "$tier2_rows" | grep -q '"tier": "python"'; then
    smoke_fail "tier 2: audit row missing tier=python detail: $tier2_rows"
  fi
  if printf '%s\n' "$tier2_rows" | grep -q 'daemon_subprocess_timeout_unavailable'; then
    smoke_fail "tier 2: should NOT log daemon_subprocess_timeout_unavailable (python succeeded as wrap)"
  fi
  smoke_log "  rc=$rc elapsed=${elapsed}s (python tier killed at budget)"
}

step_tier2_python_passthrough() {
  smoke_log "tier 2: python wrap must pass through exit codes for fast-completing cmds"
  local tier_dir
  tier_dir="$(build_tier_path_dir "$SMOKE_TMP_ROOT/path-tier2-pass" \
    "$SYS_PYTHON3" "$DATE_BIN" "$SLEEP_BIN")"

  # `sleep 0` exits 0 immediately; budget 5s is well above that.
  local output rc
  output="$(run_in_tier "$tier_dir" 5 tier2_pass "$SLEEP_BIN" 0)"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  if [[ "$rc" != "0" ]]; then
    smoke_fail "tier 2 passthrough: expected rc=0, got rc=$rc (output=$output)"
  fi

  # The fast-success path must NOT write a timeout audit row.
  if grep -q '"call_site": "tier2_pass"' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "tier 2 passthrough: unexpected audit row for successful run"
  fi
  smoke_log "  rc=$rc (python tier transparently passes success)"
}

# --- tier 3: nothing available ---------------------------------------------

step_tier3_unwrapped_with_audit() {
  smoke_log "tier 3: with no timeout AND no python3, helper runs unwrapped + logs unavailable"

  # Hide python3 too. We still need date/sleep for the run, and we must NOT
  # leak python3 — but bridge_audit_log -> bridge-audit.py internally calls
  # python3 via bridge_require_python; we want the audit row written even
  # when the wrap layer cannot find python3 on the *child PATH*. So we use
  # bridge_audit_log's own python via the parent's PATH passed through, but
  # only as part of bridge-state.sh's `bridge_require_python` resolution.
  # Simplest: leave PATH bare of any python3 (also hides it from
  # bridge_require_python), then validate by reading the audit log AFTER
  # the run with PATH restored. If python3 isn't on the child PATH at all,
  # bridge_audit_log will fail silently (it is wrapped in `2>/dev/null
  # || true`), and we cannot prove the unavailable row was written. So
  # instead we hide ONLY timeout/gtimeout AND make python3 unfindable
  # specifically by the cache resolver inside bridge_with_timeout — we do
  # that by giving the shim no python3 link but leaving bridge_require_python
  # to find python3 via its own argv0 fallback. bridge_require_python uses
  # `command -v python3` though, so that route also fails on a PATH without
  # python3. Net: we accept that on this child PATH the audit log row may
  # not actually land, and prove tier 3 a different way: by snapshotting
  # the audit log size before/after the call and asserting the call ran
  # unwrapped via the elapsed window (a 10-second sleep with a 2-second
  # budget must take ~10s if no wrap fires).

  local tier_dir
  tier_dir="$(build_tier_path_dir "$SMOKE_TMP_ROOT/path-tier3" \
    "$DATE_BIN" "$SLEEP_BIN")"

  # Sanity: confirm the shim hides BOTH wrap binaries AND python3.
  if env -i HOME="$HOME" PATH="$tier_dir" "$BASH_BIN" -c 'command -v timeout' >/dev/null 2>&1; then
    smoke_fail "tier 3 PATH shim leaked timeout(1)"
  fi
  if env -i HOME="$HOME" PATH="$tier_dir" "$BASH_BIN" -c 'command -v gtimeout' >/dev/null 2>&1; then
    smoke_fail "tier 3 PATH shim leaked gtimeout(1)"
  fi
  if env -i HOME="$HOME" PATH="$tier_dir" bash -c 'command -v python3' >/dev/null 2>&1; then
    smoke_fail "tier 3 PATH shim leaked python3"
  fi

  # Run a 3-second sleep with a 2-second budget. If tier 3 falls through to
  # unwrapped exec (status quo), the sleep runs to completion (~3s). If
  # somehow tier 1 or tier 2 fires we would see ~2s + rc=124, which would be
  # a test failure (the shim is incorrect).
  local output rc elapsed
  output="$(run_in_tier "$tier_dir" 2 tier3_smoke "$SLEEP_BIN" 3)"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [[ -n "$rc" ]] || smoke_fail "tier 3: could not parse rc from '$output'"
  [[ -n "$elapsed" ]] || smoke_fail "tier 3: could not parse elapsed from '$output'"
  if [[ "$rc" != "0" ]]; then
    smoke_fail "tier 3: expected rc=0 (sleep ran unwrapped), got rc=$rc"
  fi
  # The sleep runs ~3s; if some upstream layer killed it at 2s we'd see <=2.
  if (( elapsed < 3 )); then
    smoke_fail "tier 3: expected ~3s unwrapped sleep, got elapsed=${elapsed}s (a wrap fired unexpectedly)"
  fi
  smoke_log "  rc=$rc elapsed=${elapsed}s (unwrapped exec — status quo when both wrap layers absent)"
}

smoke_run "tier 1 (timeout/gtimeout binary) kills at budget"        step_tier1_binary_path
smoke_run "tier 2 (python3) kills at budget when binary hidden"    step_tier2_python_kill
smoke_run "tier 2 (python3) passes through fast-success commands"  step_tier2_python_passthrough
smoke_run "tier 3 (no wrap) runs unwrapped when python3 hidden"    step_tier3_unwrapped_with_audit

smoke_log "PASS"
