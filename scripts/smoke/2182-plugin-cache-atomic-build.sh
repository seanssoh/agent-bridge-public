#!/usr/bin/env bash
# Issue #2182 regression smoke — `bridge-dev-plugin-cache.py` must build a
# per-agent plugin cache ATOMICALLY and must never reuse / re-confirm a partial
# cache, so a teams version-bump fresh build can no longer race into a
# permanent channel-required launch wedge.
#
# Outage (cm-prod, v0.16.19 LTS, teams 0.1.1→0.1.2): after a version-bump
# upgrade, a teams agent that did NOT already hold the new cache version
# rebuilt `home/.claude/plugins/cache/.../<ver>/node_modules` on launch. The
# old code created `cache_version_path` up front (`mkdir`) and overlaid
# node_modules one file at a time (`shutil.copy2`). A concurrently launching
# agent saw `cache_version_path.is_dir()` → True, treated the in-progress
# partial node_modules as "already present", skipped it, and confirmed a
# permanently incomplete cache missing `node_modules/@azure/core-client/
# package.json`. The required-contract check then aborted the channel-required
# launch, and every verify-retry reused the SAME partial → 5 retries + rollback
# all failed → agent left stopped (a fleet wedge).
#
# Fix (#2182): (Part A) fresh builds are assembled in a pid-private temp dir,
# the required contract is verified on the temp, and only then is the temp
# `os.rename`'d into place — so `cache_version_path` only ever appears as a
# complete, contract-verified directory, never a partial snapshot. (Part B) an
# existing cache that is INCOMPLETE (contract file missing) is deleted and
# rebuilt rather than reused, and the terminal verify-fail also deletes a
# still-partial cache, so the verify-retry loop converges instead of wedging.
#
# T1 — partial existing cache → a SINGLE sync deletes it and rebuilds a
#      complete, contract-verified cache (pre-fix: reused the partial →
#      linked-failed forever).
# T2 — a fresh build that fails mid-overlay (a required-contract file is a
#      symlink resolving outside the source root) leaves NO partial directory
#      at `cache_version_path` — the final path is complete-or-absent
#      (pre-fix: the up-front `mkdir` left a partial dir behind).
# T3 — verify-retry no-wedge: a partial cache converges to complete on the
#      first sync and stays complete (unchanged-verified) on the next sync —
#      no permanent failure loop.
# T4 — concurrent winner: when a complete cache already exists at the final
#      path, the atomic builder discards its temp and keeps the winner intact
#      (no duplicate build, no corruption, no temp leak). Exercises the
#      `os.rename`-onto-existing branch directly.
# T5 — temp-leak zero: a failed fresh build leaves no `.<ver>.tmp.<pid>`
#      directory behind in the plugin cache root.
# T6 — winner-guarded retire: the partial-recovery delete re-verifies before
#      acting, so a complete cache another agent published is NEVER retired
#      (the concurrent-recovery stale-delete race), while a genuinely
#      incomplete cache is retired atomically (live path absent in one rename,
#      no `.<ver>.doomed.<pid>` leak).

set -u

if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "[smoke:2182-plugin-cache-atomic-build] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="2182-plugin-cache-atomic-build"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_make_temp_root "2182-plugin-cache-atomic-build"

REPO_ROOT="$SMOKE_REPO_ROOT"
DEV_CACHE_PY="$REPO_ROOT/bridge-dev-plugin-cache.py"
smoke_assert_file_exists "$DEV_CACHE_PY" "bridge-dev-plugin-cache.py present"

PLUGIN="smoke-plugin"
MARKETPLACE="smoke-mkt"
VERSION="0.0.1"
CHANNEL="plugin:${PLUGIN}@${MARKETPLACE}"

# Build a self-contained marketplace fixture whose marketplace name matches the
# channel's marketplace (so the root resolves directly). The source ships a
# node_modules tree with NESTED required-contract files (the @azure package.json
# files the real teams plugin carries — exactly the contract material the
# partial-copy race used to drop).
build_fixture() {
  local mktroot="$1"
  local srcdir="$mktroot/plugins/$PLUGIN"
  mkdir -p "$mktroot/.claude-plugin" "$srcdir/.claude-plugin" \
           "$srcdir/node_modules/@azure/core-client" \
           "$srcdir/node_modules/@azure/core-rest-pipeline" \
           "$srcdir/node_modules/regular-dep"
  cat >"$mktroot/.claude-plugin/marketplace.json" <<JSON
{
  "name": "$MARKETPLACE",
  "plugins": [
    {"name": "$PLUGIN", "source": "./plugins/$PLUGIN", "version": "$VERSION"}
  ]
}
JSON
  cat >"$srcdir/.claude-plugin/plugin.json" <<JSON
{"name": "$PLUGIN", "version": "$VERSION"}
JSON
  printf "console.log('hi')\n" >"$srcdir/server.ts"
  cat >"$srcdir/package.json" <<JSON
{"name": "$PLUGIN", "version": "$VERSION"}
JSON
  printf '{"name":"@azure/core-client"}\n' \
    >"$srcdir/node_modules/@azure/core-client/package.json"
  printf 'module.exports={}\n' \
    >"$srcdir/node_modules/@azure/core-client/index.js"
  printf '{"name":"@azure/core-rest-pipeline"}\n' \
    >"$srcdir/node_modules/@azure/core-rest-pipeline/package.json"
  printf '{"name":"regular-dep"}\n' \
    >"$srcdir/node_modules/regular-dep/package.json"
  printf '%s' "$srcdir"
}

# Run the sync CLI for a fixture. Pins cache + plugins roots into the temp tree
# so nothing live is touched. Echoes the JSON on stdout; returns the CLI rc.
run_sync() {
  local mktroot="$1"
  local case_id="$2"
  BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="$SMOKE_TMP_ROOT/$case_id/cache" \
  BRIDGE_CLAUDE_PLUGINS_ROOT="$SMOKE_TMP_ROOT/$case_id/plugins-root" \
    python3 "$DEV_CACHE_PY" sync \
      --root "$mktroot" \
      --channels "$CHANNEL" \
      --required-channels "$CHANNEL" \
      --agent "$SMOKE_NAME" \
      --json
}

json_status() {
  printf '%s' "$1" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d["results"][0].get("status",""))'
}

json_reason() {
  printf '%s' "$1" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d["results"][0].get("reason",""))'
}

plugin_cache_root_dir() {
  printf '%s' "$SMOKE_TMP_ROOT/$1/cache/$MARKETPLACE/$PLUGIN"
}

cache_version_dir() {
  printf '%s' "$SMOKE_TMP_ROOT/$1/cache/$MARKETPLACE/$PLUGIN/$VERSION"
}

# Count @azure subpackages whose package.json landed in the cache.
azure_contract_count() {
  local cvd="$1"
  local n=0 pkg
  for pkg in "$cvd"/node_modules/@azure/*/package.json; do
    [[ -f "$pkg" ]] && n=$((n + 1))
  done
  printf '%s' "$n"
}

assert_no_temp_leak() {
  local case_id="$1"
  local ctx="$2"
  local pcr; pcr="$(plugin_cache_root_dir "$case_id")"
  [[ -d "$pcr" ]] || return 0
  local leftovers="" entry
  shopt -s nullglob dotglob
  for entry in "$pcr/.${VERSION}.tmp."*; do
    leftovers+="$entry "
  done
  shopt -u nullglob dotglob
  [[ -z "$leftovers" ]] || smoke_fail "$ctx: temp dir(s) leaked: $leftovers"
}

# Seed a PARTIAL cache version dir: node_modules exists but is missing the
# nested @azure/core-client/package.json required-contract file — the exact
# shape the partial-copy race left behind.
seed_partial_cache() {
  local case_id="$1"
  local cvd; cvd="$(cache_version_dir "$case_id")"
  mkdir -p "$cvd/.claude-plugin" \
           "$cvd/node_modules/@azure/core-client" \
           "$cvd/node_modules/@azure/core-rest-pipeline" \
           "$cvd/node_modules/regular-dep"
  printf '{"name": "%s", "version": "%s"}\n' "$PLUGIN" "$VERSION" \
    >"$cvd/.claude-plugin/plugin.json"
  printf "console.log('hi')\n" >"$cvd/server.ts"
  printf '{"name": "%s", "version": "%s"}\n' "$PLUGIN" "$VERSION" \
    >"$cvd/package.json"
  # node_modules present but @azure/core-client/package.json MISSING (only its
  # index.js made it across) — the partial-copy symptom.
  printf 'module.exports={}\n' \
    >"$cvd/node_modules/@azure/core-client/index.js"
  printf '{"name":"@azure/core-rest-pipeline"}\n' \
    >"$cvd/node_modules/@azure/core-rest-pipeline/package.json"
  printf '{"name":"regular-dep"}\n' \
    >"$cvd/node_modules/regular-dep/package.json"
}

# ---------------------------------------------------------------------------
# T1 — partial existing cache → single sync rebuilds complete + verified.
# ---------------------------------------------------------------------------
t1_partial_rebuilds_clean() {
  local case_id="t1"
  local mktroot="$SMOKE_TMP_ROOT/$case_id/mkt"
  build_fixture "$mktroot" >/dev/null
  seed_partial_cache "$case_id"

  local cvd; cvd="$(cache_version_dir "$case_id")"
  # Precondition: the seeded cache is genuinely partial.
  [[ -e "$cvd/node_modules/@azure/core-client/package.json" ]] && \
    smoke_fail "T1 fixture invalid: seeded cache already has the contract file"

  local out rc
  out="$(run_sync "$mktroot" "$case_id" 2>/dev/null)"
  rc=$?

  smoke_assert_eq "0" "$rc" "T1 single sync on a partial cache must exit 0"
  smoke_assert_eq "updated-verified" "$(json_status "$out")" \
    "T1 status must be updated-verified (partial deleted + atomically rebuilt)"

  smoke_assert_file_exists "$cvd/node_modules/@azure/core-client/package.json" \
    "T1 missing contract file is present after rebuild"
  smoke_assert_file_exists "$cvd/node_modules/@azure/core-rest-pipeline/package.json" \
    "T1 sibling @azure package.json present after rebuild"
  smoke_assert_eq "2" "$(azure_contract_count "$cvd")" \
    "T1 full @azure dependency set rebuilt"
  assert_no_temp_leak "$case_id" "T1"
  return 0
}

# ---------------------------------------------------------------------------
# T2 — failed fresh build leaves no partial at cache_version_path (atomicity).
# ---------------------------------------------------------------------------
t2_failed_build_no_partial_final() {
  local case_id="t2"
  local mktroot="$SMOKE_TMP_ROOT/$case_id/mkt"
  local srcdir; srcdir="$(build_fixture "$mktroot")"

  # Make a required-contract file (a nested @azure package.json) a symlink
  # resolving OUTSIDE the marketplace root → the overlay fails loud mid-build.
  # This is a path-resolution failure (works as root too), forcing the fresh
  # build to abort partway.
  local outside="$SMOKE_TMP_ROOT/$case_id/outside"
  mkdir -p "$outside"
  printf '{"name":"@azure/core-client"}\n' >"$outside/package.json"
  rm -f "$srcdir/node_modules/@azure/core-client/package.json"
  ln -s "$outside/package.json" "$srcdir/node_modules/@azure/core-client/package.json"

  local out rc
  out="$(run_sync "$mktroot" "$case_id" 2>/dev/null)"
  rc=$?

  smoke_assert_eq "1" "$rc" "T2 failed fresh build (required channel) must exit 1"
  smoke_assert_eq "install-failed" "$(json_status "$out")" \
    "T2 status must be install-failed"
  smoke_assert_contains "$(json_reason "$out")" "required-contract" \
    "T2 reason names the required-contract failure"

  # The atomicity invariant: the final path must NOT exist as a partial — the
  # build happened in a temp that was discarded. (Pre-fix: the up-front mkdir
  # left a partial directory at cache_version_path.)
  local cvd; cvd="$(cache_version_dir "$case_id")"
  [[ -e "$cvd" ]] && \
    smoke_fail "T2 failed build left a partial cache_version_path: $cvd"
  assert_no_temp_leak "$case_id" "T2"
  return 0
}

# ---------------------------------------------------------------------------
# T3 — verify-retry no-wedge: partial converges then stays complete.
# ---------------------------------------------------------------------------
t3_verify_retry_converges() {
  local case_id="t3"
  local mktroot="$SMOKE_TMP_ROOT/$case_id/mkt"
  build_fixture "$mktroot" >/dev/null
  seed_partial_cache "$case_id"

  local cvd; cvd="$(cache_version_dir "$case_id")"

  # Retry #1 — must converge to a complete, verified cache (not loop on the
  # partial like the pre-fix code did).
  local out1 rc1
  out1="$(run_sync "$mktroot" "$case_id" 2>/dev/null)"
  rc1=$?
  smoke_assert_eq "0" "$rc1" "T3 retry#1 must exit 0 (converge, no wedge)"
  smoke_assert_eq "updated-verified" "$(json_status "$out1")" \
    "T3 retry#1 rebuilds the partial into a verified cache"
  smoke_assert_file_exists "$cvd/node_modules/@azure/core-client/package.json" \
    "T3 retry#1 contract file present"

  # Retry #2 — the now-complete cache is cheaply reused, still verified.
  local out2 rc2
  out2="$(run_sync "$mktroot" "$case_id" 2>/dev/null)"
  rc2=$?
  smoke_assert_eq "0" "$rc2" "T3 retry#2 must exit 0"
  smoke_assert_eq "unchanged-verified" "$(json_status "$out2")" \
    "T3 retry#2 reuses the complete cache (unchanged-verified)"
  smoke_assert_file_exists "$cvd/node_modules/@azure/core-client/package.json" \
    "T3 retry#2 contract file still present"
  assert_no_temp_leak "$case_id" "T3"
  return 0
}

# ---------------------------------------------------------------------------
# T4 — concurrent winner: a complete cache already at the final path is kept
#      intact; the atomic builder discards its temp (direct os.rename-onto-
#      existing branch coverage).
# ---------------------------------------------------------------------------
T4_DRIVER='
import importlib.util, os, shutil, sys
from pathlib import Path

repo, work = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "dpc", os.path.join(repo, "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

src_root = Path(work, "mkt")
srcdir = src_root / "plugins" / "smoke-plugin"
(srcdir / ".claude-plugin").mkdir(parents=True)
(srcdir / ".claude-plugin" / "plugin.json").write_text(
    "{\"name\": \"smoke-plugin\", \"version\": \"0.0.1\"}"
)
(srcdir / "server.ts").write_text("console.log(1)\n")
(srcdir / "package.json").write_text("{\"name\": \"smoke-plugin\"}")
nm = srcdir / "node_modules" / "@azure" / "core-client"
nm.mkdir(parents=True)
(nm / "package.json").write_text("{\"name\": \"@azure/core-client\"}")
(nm / "index.js").write_text("module.exports={}\n")

plugin_cache_root = Path(work, "cache", "smoke-mkt", "smoke-plugin")
cache_version_path = plugin_cache_root / "0.0.1"
plugin_cache_root.mkdir(parents=True)

# A concurrent agent already published a COMPLETE cache at the final path.
shutil.copytree(srcdir, cache_version_path)
(cache_version_path / "WINNER_SENTINEL").write_text("winner\n")
winner_pkg = cache_version_path / "node_modules" / "@azure" / "core-client" / "package.json"
assert winner_pkg.is_file(), "fixture: winner contract file missing"

# The atomic builder must lose the publish race gracefully: rename onto the
# non-empty winner fails, the winner is kept, the temp is discarded.
mod._atomic_build_cache_version(srcdir, cache_version_path, plugin_cache_root, src_root, agent="2182")

assert (cache_version_path / "WINNER_SENTINEL").is_file(), "winner cache was clobbered"
assert winner_pkg.is_file(), "winner contract file missing after build"
leftovers = [p.name for p in plugin_cache_root.iterdir() if p.name.startswith(".0.0.1.tmp.")]
assert not leftovers, "temp leaked: %r" % (leftovers,)
print("T4_OK")
'

t4_concurrent_winner_kept() {
  local case_id="t4"
  local work="$SMOKE_TMP_ROOT/$case_id"
  mkdir -p "$work"

  local out rc
  out="$(python3 -c "$T4_DRIVER" "$REPO_ROOT" "$work" 2>&1)"
  rc=$?
  smoke_assert_eq "0" "$rc" "T4 concurrent-winner driver must exit 0 (got: $out)"
  smoke_assert_contains "$out" "T4_OK" "T4 winner kept + temp discarded"
  return 0
}

# ---------------------------------------------------------------------------
# T5 — temp-leak zero on a failed fresh build.
# ---------------------------------------------------------------------------
t5_temp_leak_zero_on_failure() {
  local case_id="t5"
  local mktroot="$SMOKE_TMP_ROOT/$case_id/mkt"
  local srcdir; srcdir="$(build_fixture "$mktroot")"

  local outside="$SMOKE_TMP_ROOT/$case_id/outside"
  mkdir -p "$outside"
  printf '{"name":"@azure/core-client"}\n' >"$outside/package.json"
  rm -f "$srcdir/node_modules/@azure/core-client/package.json"
  ln -s "$outside/package.json" "$srcdir/node_modules/@azure/core-client/package.json"

  local out rc
  out="$(run_sync "$mktroot" "$case_id" 2>/dev/null)"
  rc=$?
  smoke_assert_eq "1" "$rc" "T5 failed fresh build must exit 1"
  smoke_assert_eq "install-failed" "$(json_status "$out")" \
    "T5 status must be install-failed"

  # The finally-clause must have removed the pid-private temp.
  assert_no_temp_leak "$case_id" "T5"
  return 0
}

# ---------------------------------------------------------------------------
# T6 — winner-guarded retire: the partial-recovery delete is path-identity
#      revalidated, so a complete cache another agent published is NEVER
#      retired (the concurrent-recovery stale-delete race), while a genuinely
#      incomplete cache IS retired atomically with no half-deleted state and no
#      `.doomed.<pid>` leak.
# ---------------------------------------------------------------------------
T6_DRIVER='
import importlib.util, os, shutil, sys
from pathlib import Path

repo, work = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "dpc", os.path.join(repo, "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def make_source(root):
    srcdir = root / "plugins" / "smoke-plugin"
    (srcdir / ".claude-plugin").mkdir(parents=True)
    (srcdir / ".claude-plugin" / "plugin.json").write_text("{\"name\": \"smoke-plugin\"}")
    (srcdir / "server.ts").write_text("x\n")
    (srcdir / "package.json").write_text("{\"name\": \"smoke-plugin\"}")
    nm = srcdir / "node_modules" / "@azure" / "core-client"
    nm.mkdir(parents=True)
    (nm / "package.json").write_text("{\"name\": \"@azure/core-client\"}")
    (nm / "index.js").write_text("module.exports={}\n")
    return srcdir

# --- T6a: complete winner is NOT retired (path-identity revalidation) ---
a = Path(work, "a")
src_a = make_source(a / "mkt")
pcr_a = a / "cache" / "smoke-mkt" / "smoke-plugin"
cvp_a = pcr_a / "0.0.1"
pcr_a.mkdir(parents=True)
shutil.copytree(src_a, cvp_a)              # a COMPLETE cache (winner)
(cvp_a / "WINNER_SENTINEL").write_text("w\n")
retired = mod._retire_cache_if_incomplete(cvp_a, src_a, pcr_a)
assert retired is False, "complete winner was wrongly retired"
assert cvp_a.is_dir() and (cvp_a / "WINNER_SENTINEL").is_file(), "winner cache was deleted"
assert (cvp_a / "node_modules" / "@azure" / "core-client" / "package.json").is_file()

# --- T6b: a genuinely incomplete cache IS retired atomically, no doomed leak ---
b = Path(work, "b")
src_b = make_source(b / "mkt")
pcr_b = b / "cache" / "smoke-mkt" / "smoke-plugin"
cvp_b = pcr_b / "0.0.1"
pcr_b.mkdir(parents=True)
shutil.copytree(src_b, cvp_b)
# Make it INCOMPLETE: drop the nested @azure contract file.
(cvp_b / "node_modules" / "@azure" / "core-client" / "package.json").unlink()
retired = mod._retire_cache_if_incomplete(cvp_b, src_b, pcr_b)
assert retired is True, "incomplete cache was not retired"
assert not cvp_b.exists(), "live path still present after retire (not atomic-absent)"
doomed = [p.name for p in pcr_b.iterdir() if p.name.startswith(".0.0.1.doomed.")]
assert not doomed, "doomed dir leaked: %r" % (doomed,)
print("T6_OK")
'

t6_winner_guarded_retire() {
  local case_id="t6"
  local work="$SMOKE_TMP_ROOT/$case_id"
  mkdir -p "$work"

  local out rc
  out="$(python3 -c "$T6_DRIVER" "$REPO_ROOT" "$work" 2>&1)"
  rc=$?
  smoke_assert_eq "0" "$rc" "T6 winner-guarded-retire driver must exit 0 (got: $out)"
  smoke_assert_contains "$out" "T6_OK" "T6 winner kept + incomplete retired atomically"
  return 0
}

smoke_run "T1 partial existing cache → single-sync clean rebuild" t1_partial_rebuilds_clean
smoke_run "T2 failed fresh build leaves no partial final (atomicity)" t2_failed_build_no_partial_final
smoke_run "T3 verify-retry converges, no permanent wedge" t3_verify_retry_converges
smoke_run "T4 concurrent winner kept, temp discarded" t4_concurrent_winner_kept
smoke_run "T5 temp-leak zero on a failed fresh build" t5_temp_leak_zero_on_failure
smoke_run "T6 winner-guarded retire (no stale-delete of a winner)" t6_winner_guarded_retire

smoke_log "passed"
