#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1929-macos-memory-pressure.sh — issue #1929.
#
# Background: on macOS, `bridge_check_memory_pressure` (lib/bridge-cron.sh)
# gated cron dispatch on `vm.swapusage` >= 80%. But macOS uses swap as a
# normal tier of the memory hierarchy — a healthy host routinely sits at
# 80-90%+ swap — so the swap-percent gate chronically false-DEFERRED *all*
# cron dispatch (the OS itself reports "Normal" pressure the whole time).
# Reporter saw 80+ stale cron dispatches accumulate in <24h.
#
# Fix (#1929 / #397): the Darwin branch now reads Apple's calibrated pressure
# tier `sysctl kern.memorystatus_vm_pressure_level` (1=Normal, 2=Warn,
# 4=Critical) and DEFERS only when level >= BRIDGE_CRON_DARWIN_PRESSURE_LEVEL
# (default 2). The legacy swap-percent probe stays available as an explicit
# fallback (BRIDGE_CRON_DARWIN_PRESSURE_FALLBACK=swap_pct) and fires
# automatically when the sysctl is unreadable, so a host always has *some*
# signal. Linux (/proc/meminfo MemAvailable) is unchanged.
#
# This smoke sources lib/bridge-cron.sh in isolation and stubs `uname` +
# `sysctl` (and, for the Linux assertion, /proc/meminfo) on PATH so it is fully
# portable to Linux CI — the macOS-specific behavior is exercised against a
# stubbed Darwin platform, not the host's real OS.

set -euo pipefail

SMOKE_NAME="1929-macos-memory-pressure"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

CRON_LIB="$SMOKE_REPO_ROOT/lib/bridge-cron.sh"

# lib/bridge-cron.sh sources bridge-core.sh which uses Bash-4+ features
# (`declare -ga`), and on macOS bare `bash` is the system 3.2. Use the
# interpreter that is already running this smoke ($BASH) — the repo requires
# Bash 4+ to run the suite, so $BASH is guaranteed 4+ here. Fall back to a
# discovered modern bash only if $BASH is somehow unset.
SMOKE_BASH="${BASH:-}"
if [[ -z "$SMOKE_BASH" ]]; then
  for _b in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [[ -x "$_b" ]] || continue
    if "$_b" -c '((BASH_VERSINFO[0] >= 4))' 2>/dev/null; then SMOKE_BASH="$_b"; break; fi
  done
fi
[[ -n "$SMOKE_BASH" ]] || smoke_fail "no Bash 4+ interpreter found (need it to source lib/bridge-cron.sh)"

TMP_ROOT=""
cleanup() { [[ -z "$TMP_ROOT" ]] || rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agb-1929-XXXXXX")"

# ---------------------------------------------------------------------------
# Part A — syntax
# ---------------------------------------------------------------------------
smoke_log "A1: lib/bridge-cron.sh is syntactically valid"
"$SMOKE_BASH" -n "$CRON_LIB" || smoke_fail "lib/bridge-cron.sh failed bash -n"

# ---------------------------------------------------------------------------
# Stub platform: uname -> Darwin, sysctl -> caller-controlled via env.
# ---------------------------------------------------------------------------
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat >"$FAKEBIN/uname" <<'FAKE'
#!/usr/bin/env bash
# STUB_KIND selects the reported platform (default Darwin).
printf '%s\n' "${STUB_KIND:-Darwin}"
FAKE
chmod +x "$FAKEBIN/uname"

# sysctl stub. STUB_LEVEL controls kern.memorystatus_vm_pressure_level:
#   - unset/"" -> exit 1 (unreadable, e.g. older macOS / sandbox)
#   - a number -> printed
# STUB_SWAP controls vm.swapusage (default = a high-swap HEALTHY host, the
# exact false-positive shape from the #1929 report: used/total = 85%).
cat >"$FAKEBIN/sysctl" <<'FAKE'
#!/usr/bin/env bash
key=""
# `sysctl -n <key>` — the bridge call shape.
[[ "$1" == "-n" ]] && key="$2" || key="$1"
case "$key" in
  kern.memorystatus_vm_pressure_level)
    if [[ -n "${STUB_LEVEL:-}" ]]; then
      printf '%s\n' "$STUB_LEVEL"
    else
      exit 1
    fi
    ;;
  vm.swapusage)
    printf '%s\n' "${STUB_SWAP:-total = 7168.00M  used = 6153.94M  free = 1014.06M  (encrypted)}"
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$FAKEBIN/sysctl"

# probe: source the cron lib with the stubbed platform and return the verdict
# as a string ("HEALTHY" or "DEFER") — bridge_check_memory_pressure returns 0
# when healthy (proceed) and 1 when pressured (defer).
probe() {
  # args until `--` are NAME=value env assignments; nothing after is needed.
  local -a envv=("$@")
  env PATH="$FAKEBIN:$PATH" "${envv[@]}" \
    "$SMOKE_BASH" -c '
      set -uo pipefail
      # shellcheck source=/dev/null
      source "'"$CRON_LIB"'"
      if bridge_check_memory_pressure; then printf HEALTHY; else printf DEFER; fi
    '
}

assert_verdict() {
  local got="$1" want="$2" ctx="$3"
  [[ "$got" == "$want" ]] || smoke_fail "$ctx: expected $want, got $got"
}

# ---------------------------------------------------------------------------
# Part B — the #1929 false-positive is gone (Darwin, high swap, Normal level)
# ---------------------------------------------------------------------------
smoke_log "B1: Normal pressure (level=1) + 85% swap -> HEALTHY (false-defer fixed)"
out="$(probe STUB_LEVEL=1)"
assert_verdict "$out" "HEALTHY" "B1 healthy-host-high-swap"

smoke_log "B2: mutation guard — the OLD swap-only behavior WOULD have deferred"
# Prove non-vacuity: the reporter's swap line is >=80%, so a swap-only probe
# (the pre-fix code) would DEFER. If B1 returned HEALTHY, the kernel-tier
# signal is genuinely overriding the swap gate (not just always-healthy stub).
used_pct_ge_80="$(awk '
  { for (i=1;i<=NF;i++){ if($i=="used") u=$(i+2); if($i=="total") t=$(i+2) } }
  END { gsub(/M/,"",u); gsub(/M/,"",t); if (t>0 && (u*100/t)>=80) print "yes"; else print "no" }
' <<<"total = 7168.00M  used = 6153.94M  free = 1014.06M  (encrypted)")"
[[ "$used_pct_ge_80" == "yes" ]] || \
  smoke_fail "B2 fixture swap is below 80% — the mutation test would be vacuous"

# ---------------------------------------------------------------------------
# Part C — the guard still fires on GENUINE pressure
# ---------------------------------------------------------------------------
smoke_log "C1: Warn pressure (level=2) -> DEFER (guard still works when real)"
assert_verdict "$(probe STUB_LEVEL=2)" "DEFER" "C1 warn-defers"

smoke_log "C2: Critical pressure (level=4) -> DEFER"
assert_verdict "$(probe STUB_LEVEL=4)" "DEFER" "C2 critical-defers"

smoke_log "C3: BRIDGE_CRON_DARWIN_PRESSURE_LEVEL=4 raises threshold — level=2 -> HEALTHY"
assert_verdict "$(probe STUB_LEVEL=2 BRIDGE_CRON_DARWIN_PRESSURE_LEVEL=4)" \
  "HEALTHY" "C3 threshold-override"

smoke_log "C4: bad BRIDGE_CRON_DARWIN_PRESSURE_LEVEL clamps to default(2) — level=2 -> DEFER"
assert_verdict "$(probe STUB_LEVEL=2 BRIDGE_CRON_DARWIN_PRESSURE_LEVEL=99)" \
  "DEFER" "C4 bad-threshold-clamps"

smoke_log "C5: malformed-but-readable level + 85% swap -> HEALTHY (no swap fallback, level parses as 0)"
# A non-empty sysctl read means the kernel signal IS reachable; a garbled value
# must parse as Normal (level 0) and NOT fall through to the swap probe — else
# the #1929 false-defer reopens on any host that emits unexpected sysctl text.
# Mirrors bridge-cron-runner.py (`int(...) except ValueError: 0`, then return).
assert_verdict "$(probe STUB_LEVEL=bogus)" "HEALTHY" "C5 malformed-readable-is-healthy"

# ---------------------------------------------------------------------------
# Part D — fallback paths (sysctl unreadable / explicit opt-in)
# ---------------------------------------------------------------------------
smoke_log "D1: sysctl pressure-level unreadable + 85% swap -> DEFER (auto swap fallback)"
assert_verdict "$(probe)" "DEFER" "D1 unreadable-falls-back-to-swap"

smoke_log "D2: sysctl unreadable + 50% swap -> HEALTHY (swap fallback honors limit)"
assert_verdict \
  "$(probe STUB_SWAP='total = 7168.00M  used = 3000.00M  free = 4168.00M  (encrypted)')" \
  "HEALTHY" "D2 unreadable-low-swap"

smoke_log "D3: explicit BRIDGE_CRON_DARWIN_PRESSURE_FALLBACK=swap_pct + Normal level + 85% swap -> DEFER"
assert_verdict "$(probe STUB_LEVEL=1 BRIDGE_CRON_DARWIN_PRESSURE_FALLBACK=swap_pct)" \
  "DEFER" "D3 explicit-legacy-fallback"

smoke_log "D4: legacy fallback honors BRIDGE_CRON_SWAP_PCT_LIMIT=95 — 85% swap -> HEALTHY"
assert_verdict \
  "$(probe STUB_LEVEL=1 BRIDGE_CRON_DARWIN_PRESSURE_FALLBACK=swap_pct BRIDGE_CRON_SWAP_PCT_LIMIT=95)" \
  "HEALTHY" "D4 legacy-limit-override"

smoke_log "D5: env knobs are whitespace/case normalized (match the Python contract)"
# Padded level value still reads as Warn -> DEFER (level_raw is trimmed).
assert_verdict "$(probe 'STUB_LEVEL= 2 ')" "DEFER" "D5a padded-level-warn"
# Padded + mixed-case fallback opt-in still selects swap_pct -> DEFER at 85%.
assert_verdict "$(probe STUB_LEVEL=1 'BRIDGE_CRON_DARWIN_PRESSURE_FALLBACK=  Swap_Pct  ')" \
  "DEFER" "D5b padded-mixedcase-fallback"
# Padded threshold knob still clamps/parses -> level=2 below threshold 4 = HEALTHY.
assert_verdict "$(probe STUB_LEVEL=2 'BRIDGE_CRON_DARWIN_PRESSURE_LEVEL= 4 ')" \
  "HEALTHY" "D5c padded-threshold"

# ---------------------------------------------------------------------------
# Part E — Linux path is unchanged (stubbed platform; portable to any host)
# ---------------------------------------------------------------------------
# The Linux branch reads /proc/meminfo directly (not via a stubbable command),
# so we can only drive it on a real Linux host. Gate the behavioral assertion
# on the smoke host actually being Linux; everywhere else assert structurally
# that the Linux branch was NOT touched by this change.
smoke_log "E1: Linux branch still keys on MemAvailable + BRIDGE_CRON_MIN_AVAIL_MB"
grep -q "BRIDGE_CRON_MIN_AVAIL_MB" "$CRON_LIB" || \
  smoke_fail "Linux MemAvailable knob disappeared from bridge_check_memory_pressure"
grep -q "MemAvailable" "$CRON_LIB" || \
  smoke_fail "Linux MemAvailable probe disappeared from bridge_check_memory_pressure"

if smoke_is_linux; then
  smoke_log "E2: (Linux host) healthy host -> HEALTHY"
  # A real Linux host running CI has ample MemAvailable; default 512MB floor.
  assert_verdict "$(STUB_KIND=Linux probe)" "HEALTHY" "E2 linux-healthy"

  smoke_log "E3: (Linux host) impossibly high floor forces DEFER"
  # Set the floor above any plausible MemAvailable so the guard fires — proves
  # the Linux branch still gates (and that #1929 did not disable it).
  assert_verdict "$(STUB_KIND=Linux probe BRIDGE_CRON_MIN_AVAIL_MB=999999999)" \
    "DEFER" "E3 linux-floor-defers"
else
  smoke_skip "E2/E3 Linux behavioral assertions" "smoke host is not Linux"
fi

smoke_log "PASS: $SMOKE_NAME"
