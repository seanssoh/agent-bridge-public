#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/β-1231-1236-fresh-install-seed-sudoers.sh
#
# Lane β of v0.15.0-beta2 — pins the contract for two adjacent fresh-
# install fixes:
#
#   #1231: `agb agent create --isolate --channels plugin:*` on a fresh v2
#          install must NOT require the operator to know about
#          `agb plugins seed` first. Fresh init seeds the bundled
#          agent-bridge marketplace (primary path); the agent-create flow
#          detects an empty shared catalog and runs the same seed as a
#          fail-closed fallback before prepare/start.
#   #1236: the daemon-refresh sudoers status row must not contradict
#          itself. Previously the installer printed "installed: <path>"
#          unconditionally, then the verifier printed
#          `daemon_group_refresh_sudoers=missing|invalid|...` on the very
#          next line. The fix gates the "installed" line on the verifier
#          returning `ok`; otherwise it emits `manual-required` with the
#          actionable remediation.
#
# Test plan:
#   T1. `bridge-plugins.sh seed` against the bundled in-repo agent-bridge
#       marketplace from a fresh v2 BRIDGE_HOME (empty plugins-cache)
#       writes `installed_plugins.json` to
#       $BRIDGE_SHARED_ROOT/plugins-cache.
#   T2. Re-running seed over the now-populated cache is idempotent
#       (rc=0, file still present).
#   T3. The agent-bridge init seed wiring in bridge-init.sh is present
#       at the documented hook point (gated on
#       `bridge_isolation_v2_active` + live CLI) — script syntax + grep
#       contract anchor.
#   T4. The agent-create fail-closed fallback in
#       `bridge_linux_share_plugin_catalog` is present and references
#       the bundled subprocess seed path (grep contract anchor + script
#       syntax check on lib/bridge-agents.sh).
#   T5. The bridge-init.sh sudoers gating prints either ONE "installed"
#       success row OR ONE "manual-required" row, never both — driven
#       by a stubbed `bridge_daemon_control_install_sudoers` +
#       `bridge_daemon_control_check_sudoers` pair simulating the
#       install-ok / verifier-miss case from #1236.
#   T6. The agent-bridge CLI `init sudoers daemon-refresh --apply` path
#       has the same #1236 fix applied — driven by the same stubs.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home (v2 layout);
# the smoke never reads or writes the operator's live ~/.agent-bridge or
# real sudoers paths.
#
# Platform: macOS dev + Linux CI. T1-T2 exercise the platform-aware
# seed which is no-op-safe on macOS (chgrp/setgid platform discriminator
# in lib/bridge-isolation-v2.sh). T5-T6 stub the helper module
# functions so the smoke runs identically on either host.
#
# Footgun #11 (heredoc_write deadlock class): driver scripts are emitted
# with `printf '%s\n' >file` — no command substitution feeding
# heredoc-stdin, no `<<<` here-strings into bridge functions.
#
# Re-exec under bash 4+ on macOS (system bash is 3.2).
if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:β-1231-1236-fresh-install-seed-sudoers][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="β-1231-1236-fresh-install-seed-sudoers"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi
export BRIDGE_BASH_BIN="$BRIDGE_BASH"

# ============================================================================
# T1: bridge-plugins.sh seed populates installed_plugins.json on a fresh
# v2 BRIDGE_HOME with empty plugins-cache.
# ============================================================================

PLUGINS_CACHE="$BRIDGE_SHARED_ROOT/plugins-cache"

# Sanity: fresh smoke env has NO plugins-cache yet.
if [[ -e "$PLUGINS_CACHE/installed_plugins.json" ]]; then
  smoke_fail "T1 precondition violated: plugins-cache already seeded at $PLUGINS_CACHE"
fi

T1_OUTPUT=""
T1_RC=0
T1_OUTPUT="$("$BRIDGE_BASH" "$REPO_ROOT/bridge-plugins.sh" seed 2>&1)" \
  || T1_RC=$?
if (( T1_RC != 0 )); then
  printf '%s\n' "$T1_OUTPUT" >&2
  smoke_fail "T1: bridge-plugins.sh seed exited rc=$T1_RC against bundled agent-bridge marketplace"
fi
smoke_assert_file_exists "$PLUGINS_CACHE/installed_plugins.json" \
  "T1: installed_plugins.json after seed"
smoke_assert_contains "$T1_OUTPUT" "[ok] seeded" \
  "T1: seed success marker in output"
smoke_log "T1 ok: bridge-plugins.sh seed populates plugins-cache (operator did not need to know seed step)"

# ============================================================================
# T2: re-running seed is idempotent (rc=0, output stays consistent).
# ============================================================================

T2_OUTPUT=""
T2_RC=0
T2_OUTPUT="$("$BRIDGE_BASH" "$REPO_ROOT/bridge-plugins.sh" seed 2>&1)" \
  || T2_RC=$?
if (( T2_RC != 0 )); then
  printf '%s\n' "$T2_OUTPUT" >&2
  smoke_fail "T2: idempotent re-seed exited rc=$T2_RC"
fi
smoke_assert_file_exists "$PLUGINS_CACHE/installed_plugins.json" \
  "T2: installed_plugins.json still present after re-seed"
smoke_assert_contains "$T2_OUTPUT" "[ok] seeded" \
  "T2: idempotent re-seed success marker"
smoke_log "T2 ok: re-seed over populated cache is idempotent"

# ============================================================================
# T3: bridge-init.sh carries the new idempotent seed call gated on
#     `bridge_isolation_v2_active`. Anchor grep + bash syntax check.
# ============================================================================

if ! grep -q 'Issue #1231: idempotent bundled-marketplace seed' \
     "$REPO_ROOT/bridge-init.sh"; then
  smoke_fail "T3: bridge-init.sh missing the #1231 idempotent seed anchor comment"
fi
if ! grep -q 'bridge_isolation_v2_active' \
     "$REPO_ROOT/bridge-init.sh"; then
  smoke_fail "T3: bridge-init.sh seed gate must check bridge_isolation_v2_active"
fi
if ! grep -q '"\$host_profile_cli" plugins seed' \
     "$REPO_ROOT/bridge-init.sh"; then
  smoke_fail "T3: bridge-init.sh seed call must invoke the live CLI 'plugins seed'"
fi
"$BRIDGE_BASH" -n "$REPO_ROOT/bridge-init.sh" \
  || smoke_fail "T3: bridge-init.sh syntax check failed"
smoke_log "T3 ok: bridge-init.sh init seed wired"

# ============================================================================
# T4: lib/bridge-agents.sh agent-create fallback present + syntax-clean.
# ============================================================================

if ! grep -q 'Issue #1231 fail-closed fallback' \
     "$REPO_ROOT/lib/bridge-agents.sh"; then
  smoke_fail "T4: lib/bridge-agents.sh missing #1231 fail-closed fallback anchor"
fi
if ! grep -q '"\$_v2_seed_cli" plugins seed' \
     "$REPO_ROOT/lib/bridge-agents.sh"; then
  smoke_fail "T4: lib/bridge-agents.sh fallback must invoke 'plugins seed' subprocess"
fi
if ! grep -q 'in-flight fallback seed' \
     "$REPO_ROOT/lib/bridge-agents.sh"; then
  smoke_fail "T4: lib/bridge-agents.sh fail-closed actionable error string missing"
fi
"$BRIDGE_BASH" -n "$REPO_ROOT/lib/bridge-agents.sh" \
  || smoke_fail "T4: lib/bridge-agents.sh syntax check failed"
smoke_log "T4 ok: lib/bridge-agents.sh agent-create fail-closed fallback wired"

# ============================================================================
# T5: bridge-init.sh sudoers gating — install-ok + verifier-miss must
#     emit "manual-required" and NOT "installed".
# ============================================================================
#
# We drive just the sudoers gating block by sourcing a synthesized
# script that stubs the two daemon-control helpers and replays the
# bridge-init.sh block bracketed by the #1236 anchor comment.

STUB_DRIVER="$SMOKE_TMP_ROOT/stub-driver.sh"
# Extract the #1236 block from bridge-init.sh by anchor.
INIT_BLOCK_START="$(grep -n 'Issue #1236: gate the "installed: <path>" success line' \
  "$REPO_ROOT/bridge-init.sh" | head -n1 | cut -d: -f1)"
[[ -n "$INIT_BLOCK_START" ]] \
  || smoke_fail "T5: could not locate #1236 sudoers gating anchor in bridge-init.sh"
# Block ends at the matching `else` -> `fi` close of the if-chain. We
# extract a generous window and trim at the last `fi` before the next
# top-level comment block.
INIT_BLOCK_END="$(awk -v start="$INIT_BLOCK_START" '
  NR >= start {
    if ($0 ~ /^[[:space:]]+printf .\[init\] daemon_group_refresh_sudoers=%s.n. .\$_init_sudoers_reason./) {
      print NR
      exit
    }
  }
' "$REPO_ROOT/bridge-init.sh")"
# Tolerate the awk regex falling through; we want the block to end at
# the printf that emits the verifier reason — the trailing `fi` that
# closes the outer if-chain is captured below.
[[ -n "$INIT_BLOCK_END" ]] \
  || smoke_fail "T5: could not locate #1236 block end (verifier-reason printf) in bridge-init.sh"

# Find the next `fi` after INIT_BLOCK_END to close the if-chain.
INIT_BLOCK_END_FI="$(awk -v start="$INIT_BLOCK_END" 'NR>=start && /^[[:space:]]*fi[[:space:]]*$/ {print NR; exit}' \
  "$REPO_ROOT/bridge-init.sh")"
[[ -n "$INIT_BLOCK_END_FI" ]] \
  || smoke_fail "T5: could not locate closing fi for #1236 block in bridge-init.sh"

# Emit driver: stub helpers + warning collector + sed-extracted block.
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'bridge_init_append_warning() { printf "[warn] %%s\\n" "$1" >&2; }\n'
  # Install stub: succeeds, prints a fake path.
  printf 'bridge_daemon_control_install_sudoers() {\n'
  printf '  printf "%%s" "/etc/sudoers.d/agent-bridge-daemon-refresh-fake-uid"\n'
  printf '  return 0\n'
  printf '}\n'
  # Check stub: returns "missing" (the #1236 contradiction trigger).
  printf 'bridge_daemon_control_check_sudoers() {\n'
  printf '  printf "%%s" "missing"\n'
  printf '  return 1\n'
  printf '}\n'
  printf 'bridge_daemon_control_preflight_row() {\n'
  printf '  printf "daemon_group_refresh_sudoers=missing\\n"\n'
  printf '  return 0\n'
  printf '}\n'
} >"$STUB_DRIVER"

# Append the extracted block. Use sed -n with explicit start/end.
sed -n "${INIT_BLOCK_START},${INIT_BLOCK_END_FI}p" "$REPO_ROOT/bridge-init.sh" \
  >>"$STUB_DRIVER"

# Run the driver; capture stdout + stderr separately so the assertion
# can confirm the "installed: ..." string is NOT printed anywhere.
T5_STDOUT="$SMOKE_TMP_ROOT/t5.stdout"
T5_STDERR="$SMOKE_TMP_ROOT/t5.stderr"
"$BRIDGE_BASH" "$STUB_DRIVER" >"$T5_STDOUT" 2>"$T5_STDERR" || true

T5_STDOUT_CONTENT="$(cat "$T5_STDOUT")"
T5_STDERR_CONTENT="$(cat "$T5_STDERR")"
T5_ALL="$T5_STDOUT_CONTENT"$'\n'"$T5_STDERR_CONTENT"

# Assert: NO "[init] daemon-refresh sudoers: installed at" line (the
# pre-#1236 success row that contradicted the verifier).
if [[ "$T5_ALL" == *"daemon-refresh sudoers: installed at"* ]]; then
  printf '%s\n' "$T5_ALL" >&2
  smoke_fail "T5: pre-#1236 'installed at' contradiction surface present in init output"
fi

# Assert: the new "manual-required" row IS present.
if [[ "$T5_ALL" != *"manual-required"* ]]; then
  printf '%s\n' "$T5_ALL" >&2
  smoke_fail "T5: expected 'manual-required' line in init output, got: $T5_ALL"
fi

# Assert: verifier reason is exposed in stdout.
if [[ "$T5_STDOUT_CONTENT" != *"daemon_group_refresh_sudoers=missing"* ]]; then
  printf '%s\n' "$T5_STDOUT_CONTENT" >&2
  smoke_fail "T5: expected 'daemon_group_refresh_sudoers=missing' status row in init stdout"
fi

smoke_log "T5 ok: bridge-init.sh sudoers gating prints manual-required + NO 'installed' contradiction"

# ============================================================================
# T6: agent-bridge CLI `init sudoers daemon-refresh --apply` path —
#     same #1236 contradiction gating applied.
# ============================================================================
#
# The agent-bridge CLI wraps the install + verify with an `apply` case.
# We can drive it by sourcing the relevant block with the same stubs.
# Extract from the apply case anchor.

CLI_BLOCK_START="$(grep -n 'Issue #1236: gate the "installed: <path>" success line' \
  "$REPO_ROOT/agent-bridge" | head -n1 | cut -d: -f1)"
[[ -n "$CLI_BLOCK_START" ]] \
  || smoke_fail "T6: could not locate #1236 anchor in agent-bridge CLI"

# Find the `exit 1` terminal line inside the apply case body (skip
# `exit 0` which is the success branch; both belong to the same block
# and bracketing on `exit 1` keeps the inner `case "$_REASON" in ...
# esac` properly paired in the extracted driver).
CLI_BLOCK_END="$(awk -v start="$CLI_BLOCK_START" '
  NR >= start && /^[[:space:]]*exit 1[[:space:]]*$/ {print NR; exit}
' "$REPO_ROOT/agent-bridge")"
[[ -n "$CLI_BLOCK_END" ]] \
  || smoke_fail "T6: could not locate apply-case 'exit 1' terminal in agent-bridge CLI"

# The CLI block uses `exit 0|1` for terminal results. Drive it in a
# subshell so the `exit` does not kill the smoke.
CLI_DRIVER="$SMOKE_TMP_ROOT/cli-driver.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'bridge_daemon_control_install_sudoers() {\n'
  printf '  printf "%%s" "/etc/sudoers.d/agent-bridge-daemon-refresh-fake-uid"\n'
  printf '  return 0\n'
  printf '}\n'
  printf 'bridge_daemon_control_check_sudoers() {\n'
  printf '  printf "%%s" "missing"\n'
  printf '  return 1\n'
  printf '}\n'
} >"$CLI_DRIVER"
sed -n "${CLI_BLOCK_START},${CLI_BLOCK_END}p" "$REPO_ROOT/agent-bridge" \
  >>"$CLI_DRIVER"

T6_STDOUT="$SMOKE_TMP_ROOT/t6.stdout"
T6_STDERR="$SMOKE_TMP_ROOT/t6.stderr"
"$BRIDGE_BASH" "$CLI_DRIVER" >"$T6_STDOUT" 2>"$T6_STDERR" || true

T6_STDOUT_CONTENT="$(cat "$T6_STDOUT")"
T6_STDERR_CONTENT="$(cat "$T6_STDERR")"
T6_ALL="$T6_STDOUT_CONTENT"$'\n'"$T6_STDERR_CONTENT"

# Assert: NO bare "installed: /etc/sudoers.d/..." success line on stdout.
# The new code may print "installed: <path> (verifier=ok)" on success
# but NEVER a bare "installed: <path>" without the verifier=ok suffix.
if echo "$T6_STDOUT_CONTENT" | grep -E '^installed: [^[:space:]]+$' >/dev/null 2>&1; then
  printf '%s\n' "$T6_ALL" >&2
  smoke_fail "T6: agent-bridge CLI emitted pre-#1236 bare 'installed: <path>' on a verifier-miss host"
fi

# Assert: stderr carries the "manual-required" remediation hint.
if [[ "$T6_STDERR_CONTENT" != *"manual-required"* ]]; then
  printf '%s\n' "$T6_ALL" >&2
  smoke_fail "T6: expected 'manual-required' remediation in agent-bridge CLI stderr"
fi

# Assert: status row on stdout reports the verifier reason.
if [[ "$T6_STDOUT_CONTENT" != *"daemon_group_refresh_sudoers=missing"* ]]; then
  printf '%s\n' "$T6_ALL" >&2
  smoke_fail "T6: expected 'daemon_group_refresh_sudoers=missing' on agent-bridge CLI stdout"
fi

smoke_log "T6 ok: agent-bridge CLI sudoers gating matches bridge-init.sh contract"

smoke_log "all green — #1231 init+fallback seed + #1236 sudoers gating verified"
exit 0
