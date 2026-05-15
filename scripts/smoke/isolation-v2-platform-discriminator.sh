#!/usr/bin/env bash
# S3 regression smoke — bridge-isolation-discriminator predicates.
#
# Verifies the 3 predicates introduced by S3:
#   bridge_isolation_discriminator_auto_resolve
#   bridge_isolation_v2_enforce
#   bridge_isolation_v2_require_linux
#
# Coverage (cross-platform — uses BRIDGE_HOST_PLATFORM_OVERRIDE to
# exercise both Linux and Darwin paths regardless of the running host):
#   D1 — BRIDGE_ISOLATION_REQUIRED unset + host=Linux → resolve=yes,
#         enforce returns 0, require_linux returns 0 without die.
#   D2 — BRIDGE_ISOLATION_REQUIRED unset + host=Darwin → resolve=no,
#         enforce returns 1, require_linux DIES.
#   D3 — BRIDGE_ISOLATION_REQUIRED=yes + host=Darwin → resolve=yes,
#         enforce returns 0 (explicit opt-in overrides auto-detect).
#   D4 — BRIDGE_ISOLATION_REQUIRED=no + host=Linux → resolve=no,
#         enforce returns 1 (explicit opt-out overrides auto-detect).
#   D5 — BRIDGE_ISOLATION_REQUIRED=garbage → warn-and-fallback-to-auto;
#         on host=Linux resolves yes, on host=Darwin resolves no.
#   D6 — Cache behavior: after clear_cache, a changed env reflects.
#
# Footgun #11 (Bash 5.3.9 heredoc-class deadlock): all driver bodies
# are emitted via printf-to-file (no heredocs, no here-strings).

set -uo pipefail

SMOKE_NAME="isolation-v2-platform-discriminator"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

run_predicate_probe() {
  # Args: $1 = env_required ("yes"|"no"|"auto"|"garbage"|""),
  #       $2 = host_override ("Linux"|"Darwin"),
  #       $3 = snippet (the test body),
  #       $4 = out_file
  local env_required="$1"
  local host_override="$2"
  local snippet="$3"
  local out_file="$4"
  local driver="$SMOKE_TMP_ROOT/driver-$$.sh"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    printf 'cd %q\n' "$REPO_ROOT"
    printf 'export BRIDGE_HOME=%q\n' "$SMOKE_TMP_ROOT/bh"
    printf 'export BRIDGE_STATE_DIR=%q\n' "$SMOKE_TMP_ROOT/bh/state"
    printf 'export BRIDGE_LAYOUT=v2\n'
    printf 'export BRIDGE_DATA_ROOT=%q\n' "$SMOKE_TMP_ROOT/bh/data"
    printf 'export BRIDGE_HOST_PLATFORM_OVERRIDE=%q\n' "$host_override"
    if [[ -n "$env_required" ]]; then
      printf 'export BRIDGE_ISOLATION_REQUIRED=%q\n' "$env_required"
    else
      printf '%s\n' 'unset BRIDGE_ISOLATION_REQUIRED 2>/dev/null || true'
    fi
    printf '%s\n' 'mkdir -p "$BRIDGE_HOME/state" "$BRIDGE_DATA_ROOT"'
    printf '%s\n' 'source "$0_REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1'
    printf '%s\n' "$snippet"
  } | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$driver"
  chmod +x "$driver"

  "$BRIDGE_BASH" "$driver" >"$out_file" 2>&1
  local rc=$?
  rm -f "$driver"
  return $rc
}

# D1 — default + Linux → resolve=yes, enforce 0, require_linux 0
smoke_log "D1: env=unset + host=Linux"
D1_OUT="$SMOKE_TMP_ROOT/d1.out"
run_predicate_probe "" "Linux" '
echo "RESOLVE=$(bridge_isolation_discriminator_auto_resolve)"
bridge_isolation_v2_enforce; echo "ENFORCE_RC=$?"
bridge_isolation_v2_require_linux; echo "REQUIRE_RC=$?"
' "$D1_OUT" || true

grep -q '^RESOLVE=yes$' "$D1_OUT" || { cat "$D1_OUT"; smoke_fail "D1: expected RESOLVE=yes"; }
grep -q '^ENFORCE_RC=0$' "$D1_OUT" || { cat "$D1_OUT"; smoke_fail "D1: expected ENFORCE_RC=0"; }
grep -q '^REQUIRE_RC=0$' "$D1_OUT" || { cat "$D1_OUT"; smoke_fail "D1: expected REQUIRE_RC=0"; }
smoke_log "D1 PASS"

# D2 — default + Darwin → resolve=no, enforce 1, require_linux DIES
smoke_log "D2: env=unset + host=Darwin → require_linux must die"
D2_OUT="$SMOKE_TMP_ROOT/d2.out"
run_predicate_probe "" "Darwin" '
echo "RESOLVE=$(bridge_isolation_discriminator_auto_resolve)"
bridge_isolation_v2_enforce; echo "ENFORCE_RC=$?"
bridge_isolation_v2_require_linux; echo "REQUIRE_RC=$?"
' "$D2_OUT" || true

grep -q '^RESOLVE=no$' "$D2_OUT" || { cat "$D2_OUT"; smoke_fail "D2: expected RESOLVE=no"; }
grep -q '^ENFORCE_RC=1$' "$D2_OUT" || { cat "$D2_OUT"; smoke_fail "D2: expected ENFORCE_RC=1"; }
# require_linux should bridge_die before reaching the echo
if grep -q '^REQUIRE_RC=' "$D2_OUT"; then
  cat "$D2_OUT"
  smoke_fail "D2: require_linux did not die on host=Darwin"
fi
grep -q 'operation requires Linux' "$D2_OUT" || { cat "$D2_OUT"; smoke_fail "D2: expected 'requires Linux' die message"; }
smoke_log "D2 PASS"

# D3 — explicit yes + Darwin → resolve=yes, enforce 0 (override)
smoke_log "D3: env=yes + host=Darwin (explicit opt-in)"
D3_OUT="$SMOKE_TMP_ROOT/d3.out"
run_predicate_probe "yes" "Darwin" '
echo "RESOLVE=$(bridge_isolation_discriminator_auto_resolve)"
bridge_isolation_v2_enforce; echo "ENFORCE_RC=$?"
' "$D3_OUT" || true

grep -q '^RESOLVE=yes$' "$D3_OUT" || { cat "$D3_OUT"; smoke_fail "D3: expected RESOLVE=yes (explicit)"; }
grep -q '^ENFORCE_RC=0$' "$D3_OUT" || { cat "$D3_OUT"; smoke_fail "D3: expected ENFORCE_RC=0"; }
smoke_log "D3 PASS"

# D4 — explicit no + Linux → resolve=no, enforce 1 (override)
smoke_log "D4: env=no + host=Linux (explicit opt-out)"
D4_OUT="$SMOKE_TMP_ROOT/d4.out"
run_predicate_probe "no" "Linux" '
echo "RESOLVE=$(bridge_isolation_discriminator_auto_resolve)"
bridge_isolation_v2_enforce; echo "ENFORCE_RC=$?"
' "$D4_OUT" || true

grep -q '^RESOLVE=no$' "$D4_OUT" || { cat "$D4_OUT"; smoke_fail "D4: expected RESOLVE=no (explicit)"; }
grep -q '^ENFORCE_RC=1$' "$D4_OUT" || { cat "$D4_OUT"; smoke_fail "D4: expected ENFORCE_RC=1"; }
smoke_log "D4 PASS"

# D5 — invalid env → warn-and-fallback-to-auto
smoke_log "D5: env=garbage → warn + auto fallback"
D5_OUT="$SMOKE_TMP_ROOT/d5.out"
run_predicate_probe "garbage" "Linux" '
echo "RESOLVE=$(bridge_isolation_discriminator_auto_resolve)"
' "$D5_OUT" || true

grep -q '^RESOLVE=yes$' "$D5_OUT" || { cat "$D5_OUT"; smoke_fail "D5(Linux): expected fallback to yes"; }
grep -qE "BRIDGE_ISOLATION_REQUIRED='?garbage'? is invalid" "$D5_OUT" || { cat "$D5_OUT"; smoke_fail "D5: expected invalid-value warning"; }
smoke_log "D5 PASS"

# D6 — cache invalidation (same shell, no command-substitution; $() spawns
# a subshell which loses the cache var, so testing must be in-place).
smoke_log "D6: cache invalidation across BRIDGE_ISOLATION_REQUIRED mutation"
D6_OUT="$SMOKE_TMP_ROOT/d6.out"
run_predicate_probe "no" "Linux" '
bridge_isolation_discriminator_auto_resolve >"$BRIDGE_HOME/first"; echo
export BRIDGE_ISOLATION_REQUIRED=yes
bridge_isolation_discriminator_auto_resolve >"$BRIDGE_HOME/before_clear"; echo
bridge_isolation_discriminator_clear_cache
bridge_isolation_discriminator_auto_resolve >"$BRIDGE_HOME/after_clear"; echo
echo "FIRST=$(cat "$BRIDGE_HOME/first")"
echo "BEFORE_CLEAR=$(cat "$BRIDGE_HOME/before_clear")"
echo "AFTER_CLEAR=$(cat "$BRIDGE_HOME/after_clear")"
' "$D6_OUT" || true

grep -q '^FIRST=no$' "$D6_OUT" || { cat "$D6_OUT"; smoke_fail "D6: first read should be no"; }
grep -q '^BEFORE_CLEAR=no$' "$D6_OUT" || { cat "$D6_OUT"; smoke_fail "D6: cached value should persist before clear"; }
grep -q '^AFTER_CLEAR=yes$' "$D6_OUT" || { cat "$D6_OUT"; smoke_fail "D6: after clear, new env value should take effect"; }
smoke_log "D6 PASS"

# D7 — cache contract through bridge_isolation_v2_enforce wrapper.
# Codex r1 catch: _enforce previously used $() which spawned a subshell,
# so the cache var was never written back to the parent shell. This
# verifies the documented cache contract holds across the gate the 140
# S5 sites will actually use.
smoke_log "D7: _enforce wrapper cache contract"
D7_OUT="$SMOKE_TMP_ROOT/d7.out"
run_predicate_probe "no" "Linux" '
bridge_isolation_v2_enforce; FIRST_RC=$?
echo "CACHE_AFTER_FIRST=$_BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED"
echo "FIRST_RC=$FIRST_RC"
# Mutate env without clear_cache; the cache must override.
export BRIDGE_ISOLATION_REQUIRED=yes
bridge_isolation_v2_enforce; SECOND_RC=$?
echo "CACHE_AFTER_SECOND=$_BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED"
echo "SECOND_RC=$SECOND_RC"
# Now clear cache and verify the new env wins.
bridge_isolation_discriminator_clear_cache
bridge_isolation_v2_enforce; THIRD_RC=$?
echo "CACHE_AFTER_THIRD=$_BRIDGE_ISOLATION_DISCRIMINATOR_AUTO_RESOLVED"
echo "THIRD_RC=$THIRD_RC"
' "$D7_OUT" || true

grep -q '^CACHE_AFTER_FIRST=no$' "$D7_OUT" || { cat "$D7_OUT"; smoke_fail "D7: _enforce did not populate parent-shell cache after first call"; }
grep -q '^FIRST_RC=1$' "$D7_OUT" || { cat "$D7_OUT"; smoke_fail "D7: _enforce rc mismatch after first call"; }
grep -q '^CACHE_AFTER_SECOND=no$' "$D7_OUT" || { cat "$D7_OUT"; smoke_fail "D7: cache should persist across env mutation without clear_cache"; }
grep -q '^SECOND_RC=1$' "$D7_OUT" || { cat "$D7_OUT"; smoke_fail "D7: _enforce should honor cached value, not new env"; }
grep -q '^CACHE_AFTER_THIRD=yes$' "$D7_OUT" || { cat "$D7_OUT"; smoke_fail "D7: cache should reflect new env after clear_cache"; }
grep -q '^THIRD_RC=0$' "$D7_OUT" || { cat "$D7_OUT"; smoke_fail "D7: _enforce should honor new env after clear_cache"; }
smoke_log "D7 PASS"

# D8 — standalone v2 module sources discriminator (CI red regression guard).
# Codex r1 catch: tests/isolation-v2-primitives/smoke.sh sources
# lib/bridge-isolation-v2.sh directly. After r2, v2 module self-sources
# the discriminator so _enforce is defined in that flow too.
smoke_log "D8: standalone v2 source brings in discriminator"
D8_OUT="$SMOKE_TMP_ROOT/d8.out"
D8_DRIVER="$SMOKE_TMP_ROOT/d8-driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf 'cd %q\n' "$REPO_ROOT"
  # Stub bridge_warn / bridge_die like the real standalone smoke does.
  printf '%s\n' 'bridge_warn() { printf "[stub_warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_die() { printf "[stub_die] %s\n" "$*" >&2; exit 1; }'
  printf '%s\n' 'source "$0_REPO_ROOT/lib/bridge-isolation-v2.sh" 2>&1'
  printf '%s\n' 'if declare -f bridge_isolation_v2_enforce >/dev/null 2>&1; then echo "ENFORCE_DEFINED=yes"; else echo "ENFORCE_DEFINED=no"; fi'
  printf '%s\n' 'if declare -f bridge_isolation_discriminator_auto_resolve >/dev/null 2>&1; then echo "RESOLVE_DEFINED=yes"; else echo "RESOLVE_DEFINED=no"; fi'
} | sed "s#\$0_REPO_ROOT#$REPO_ROOT#g" >"$D8_DRIVER"
chmod +x "$D8_DRIVER"
"$BRIDGE_BASH" "$D8_DRIVER" >"$D8_OUT" 2>&1 || true
rm -f "$D8_DRIVER"

grep -q '^ENFORCE_DEFINED=yes$' "$D8_OUT" || { cat "$D8_OUT"; smoke_fail "D8: standalone v2 source did not bring in bridge_isolation_v2_enforce"; }
grep -q '^RESOLVE_DEFINED=yes$' "$D8_OUT" || { cat "$D8_OUT"; smoke_fail "D8: standalone v2 source did not bring in bridge_isolation_discriminator_auto_resolve"; }
smoke_log "D8 PASS"

smoke_log "PASS — discriminator predicates correct across 8 cases"
exit 0
