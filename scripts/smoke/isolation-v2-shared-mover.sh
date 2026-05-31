#!/usr/bin/env bash
# Regression smoke for the v0.15 split-brain fix: the layout marker flipped
# to v2 WITHOUT relocating the active shared tree ($BRIDGE_HOME/shared) into
# the v2 data/-prefixed layout ($BRIDGE_DATA_ROOT/shared). On macOS the
# apply_for_upgrade skip branches (marker-only-no-isolated-roster +
# macos-shared-agent) returned before any data move, so the v2 wiki indexer
# scanned an empty data/shared/wiki while every legacy BRIDGE_SHARED_DIR
# consumer still read the real content at the legacy path.
#
# The fix adds a platform-agnostic shared-tree backfill that runs BEFORE all
# skip branches (bridge_isolation_v2_migrate_shared_backfill), a sentinel it
# drops (bridge_isolation_v2_migrate_shared_sentinel_write), and a
# sentinel-gated resolver flip in lib/bridge-isolation-v2.sh.
#
# Coverage:
#   T1 — Darwin + no isolated agents (macos-shared-agent skip) + populated
#        legacy shared → backfill mirrors into data/shared, legacy PRESERVED,
#        sentinel reason=mirrored, skip JSON still emitted, sudo never called.
#   T2 — idempotent: a second apply does NOT re-mirror (sentinel-gated), even
#        after the legacy tree is mutated.
#   T3 — Darwin + BRIDGE_UPGRADE_CONTEXT=1 (marker-only-no-isolated skip) +
#        populated legacy shared → backfill still fires before that branch
#        (mirror + sentinel), proving both skip paths relocate the data.
#   T4 — empty legacy shared → sentinel reason=no-legacy-content, no crash.
#   T5 — sentinel-gated resolver flip (lib/bridge-isolation-v2.sh, sourced
#        directly): no flip without sentinel, flips to data/shared with it,
#        explicit BRIDGE_SHARED_DIR override always wins.
#   T6 — structural: the early backfill call precedes BOTH skip branches in
#        bridge_isolation_v2_migrate_apply_for_upgrade.
#
# All scripted shell snippets are emitted via printf-to-file (no heredocs /
# here-strings) — Bash 5.3.9 heredoc_write deadlock class, footgun #11.

set -uo pipefail

SMOKE_NAME="isolation-v2-shared-mover"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
MIGRATE_LIB="$REPO_ROOT/lib/bridge-isolation-v2-migrate.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

# Pick a Bash 4+ interpreter on macOS hosts (system bash is 3.2).
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi

# --- harness helpers ---------------------------------------------------------

# uname + sudo shim. uname reports the requested kernel so the macOS skip
# branch can be exercised on any runner; sudo records calls and exits
# non-zero so an accidental escalation turns into a loud failure.
build_platform_shim() {
  local shim_dir="$1" fake_uname="$2" sudo_log="$3"
  mkdir -p "$shim_dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'FAKE_UNAME=%q\n' "$fake_uname"
    printf '%s\n' 'if [[ $# -eq 0 ]]; then printf "%s\n" "$FAKE_UNAME"; exit 0; fi'
    printf '%s\n' 'while [[ $# -gt 0 ]]; do'
    printf '%s\n' '  case "$1" in'
    printf '%s\n' '    -s) printf "%s\n" "$FAKE_UNAME" ;;'
    printf '%s\n' '    -m) printf "%s\n" "x86_64" ;;'
    printf '%s\n' '    -r) printf "%s\n" "0.0.0" ;;'
    printf '%s\n' '    -a) printf "%s shim 0.0.0 #0 SMP x86_64\n" "$FAKE_UNAME" ;;'
    printf '%s\n' '    *) printf "%s\n" "$FAKE_UNAME" ;;'
    printf '%s\n' '  esac'
    printf '%s\n' '  shift'
    printf '%s\n' 'done'
  } >"$shim_dir/uname"
  chmod +x "$shim_dir/uname"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'LOG=%q\n' "$sudo_log"
    printf '%s\n' 'printf "[sudo-shim] %s\n" "$*" >>"$LOG"'
    printf '%s\n' 'exit 99'
  } >"$shim_dir/sudo"
  chmod +x "$shim_dir/sudo"
}

# Symlink PATH essentials into the shim dir so the driver subshell keeps
# access when we replace PATH wholesale. NOTE: rsync is included — the
# shared backfill's real-copy mirror needs it (the macos-skip smoke omits
# rsync because its apply_for_upgrade path never copies data).
populate_basic_path() {
  local shim_dir="$1" cmd target
  for cmd in bash mkdir rm cat tr grep sed awk printf id stat tee chmod dirname env date mktemp readlink ls cp mv touch wc head tail find sort uniq true false python3 git tmux jq sqlite3 sha256sum md5 rsync; do
    target="$(command -v "$cmd" 2>/dev/null || true)"
    [[ -n "$target" && "${target:0:1}" == "/" ]] || continue
    [[ -L "$shim_dir/$cmd" || -e "$shim_dir/$cmd" ]] && continue
    ln -s "$target" "$shim_dir/$cmd" 2>/dev/null || true
  done
}

write_driver_script() {
  local out="$1"; shift
  : >"$out"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

# Populate a legacy shared tree with recognizable content.
seed_legacy_shared() {
  local shared_dir="$1"
  mkdir -p "$shared_dir/wiki/_index" "$shared_dir/cron-dispatch"
  printf 'real wiki index\n' >"$shared_dir/wiki/index.md"
  printf 'mentions-db-bytes\n' >"$shared_dir/wiki/_index/mentions.db"
  printf 'dispatch-row\n' >"$shared_dir/cron-dispatch/row.md"
}

# Run apply_for_upgrade for a given platform / roster / upgrade-context.
# Emits the wrapper JSON to out_file. The home_dir layout mirrors a live
# install: legacy shared at $home_dir/shared, v2 data at $home_dir/data.
run_apply_for_upgrade() {
  local fake_uname="$1"      # Darwin | Linux
  local roster_kind="$2"     # shared | isolated
  local upgrade_ctx="$3"     # 0 | 1
  local home_dir="$4"
  local out_file="$5"

  local shim_dir="$home_dir/shim-bin"
  local sudo_log="$home_dir/sudo-calls.log"
  : >"$sudo_log"
  build_platform_shim "$shim_dir" "$fake_uname" "$sudo_log"
  populate_basic_path "$shim_dir"

  mkdir -p "$home_dir/state" "$home_dir/logs" \
    "$home_dir/data/shared" "$home_dir/data/agents" "$home_dir/data/state"
  : >"$home_dir/agent-roster.local.sh"

  local roster_setup
  case "$roster_kind" in
    shared)
      roster_setup='BRIDGE_AGENT_IDS=(a1 a2); bridge_agent_linux_user_isolation_effective() { return 1; }'
      ;;
    isolated)
      roster_setup='BRIDGE_AGENT_IDS=(a1 a2); bridge_agent_linux_user_isolation_effective() { local a="${1:-}"; case "$a" in a2) return 0;; *) return 1;; esac; }'
      ;;
    *) smoke_fail "internal: unknown roster_kind=$roster_kind" ;;
  esac

  local driver="$home_dir/driver.sh"
  write_driver_script "$driver" \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    'cd "$REPO_ROOT"' \
    'export BRIDGE_HOME="$HOME_DIR"' \
    'export BRIDGE_STATE_DIR="$HOME_DIR/state"' \
    'export BRIDGE_LOG_DIR="$HOME_DIR/logs"' \
    'export BRIDGE_SHARED_DIR="$HOME_DIR/shared"' \
    'export BRIDGE_DATA_ROOT="$HOME_DIR/data"' \
    'export BRIDGE_LAYOUT="v2"' \
    'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1' \
    'source "$REPO_ROOT/lib/bridge-isolation-v2-migrate.sh" >/dev/null 2>&1' \
    "$roster_setup" \
    'bridge_isolation_v2_migrate_apply_for_upgrade --target-root "$HOME_DIR" --json 2>/dev/null || true'

  PATH="$shim_dir" \
    REPO_ROOT="$REPO_ROOT" \
    HOME_DIR="$home_dir" \
    BRIDGE_HOME="$home_dir" \
    BRIDGE_STATE_DIR="$home_dir/state" \
    BRIDGE_LOG_DIR="$home_dir/logs" \
    BRIDGE_SHARED_DIR="$home_dir/shared" \
    BRIDGE_DATA_ROOT="$home_dir/data" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_UPGRADE_CONTEXT="$upgrade_ctx" \
    "$BRIDGE_BASH" "$driver" >"$out_file" 2>&1 || true
}

assert_backfill_effects() {
  local label="$1" home_dir="$2"
  smoke_assert_file_exists "$home_dir/data/shared/wiki/index.md" \
    "$label: data/shared wiki mirrored"
  smoke_assert_contains "$(cat "$home_dir/data/shared/wiki/index.md" 2>/dev/null)" \
    "real wiki index" "$label: mirrored content matches legacy"
  smoke_assert_file_exists "$home_dir/data/shared/wiki/_index/mentions.db" \
    "$label: nested _index mirrored"
  smoke_assert_file_exists "$home_dir/data/shared/cron-dispatch/row.md" \
    "$label: cron-dispatch mirrored"
  # delete_eligible=0 — legacy preserved.
  smoke_assert_file_exists "$home_dir/shared/wiki/index.md" \
    "$label: legacy shared PRESERVED (delete_eligible=0)"
  smoke_assert_file_exists "$home_dir/data/.v2-shared-mirror.sentinel" \
    "$label: sentinel written"
  smoke_assert_contains "$(cat "$home_dir/data/.v2-shared-mirror.sentinel" 2>/dev/null)" \
    "reason=mirrored" "$label: sentinel reason=mirrored"
}

assert_no_sudo() {
  local label="$1" home_dir="$2"
  if [[ -s "$home_dir/sudo-calls.log" ]]; then
    smoke_fail "$label: sudo was invoked — backfill + skip path must stay sudo-free. log=$(cat "$home_dir/sudo-calls.log")"
  fi
}

# --- T1: macos-shared-agent skip + populated legacy --------------------------

smoke_log "T1: Darwin macos-shared-agent skip relocates the shared tree before returning"
T1_HOME="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_HOME/shared"
seed_legacy_shared "$T1_HOME/shared"
T1_OUT="$T1_HOME/out.txt"
run_apply_for_upgrade Darwin shared 0 "$T1_HOME" "$T1_OUT"
T1_PAYLOAD="$(cat "$T1_OUT")"
smoke_assert_contains "$T1_PAYLOAD" '"reason":"macos-shared-agent"' \
  "T1: macos-shared-agent skip JSON still emitted"
assert_backfill_effects "T1" "$T1_HOME"
assert_no_sudo "T1" "$T1_HOME"
smoke_log "T1 PASS: data relocated + legacy preserved + sentinel + skip intact + no sudo"

# --- T2: idempotent — second apply does not re-mirror ------------------------

smoke_log "T2: idempotent — second apply is a sentinel-gated no-op"
T2_HOME="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_HOME/shared"
seed_legacy_shared "$T2_HOME/shared"
T2_OUT_A="$T2_HOME/out-a.txt"
T2_OUT_B="$T2_HOME/out-b.txt"
run_apply_for_upgrade Darwin shared 0 "$T2_HOME" "$T2_OUT_A"
assert_backfill_effects "T2-A" "$T2_HOME"
# Mutate legacy AFTER the first mirror; the sentinel-gated no-op must NOT
# propagate the change.
printf 'CHANGED-AFTER-FIRST-MIRROR\n' >"$T2_HOME/shared/wiki/index.md"
run_apply_for_upgrade Darwin shared 0 "$T2_HOME" "$T2_OUT_B"
T2_MIRRORED="$(cat "$T2_HOME/data/shared/wiki/index.md" 2>/dev/null)"
smoke_assert_contains "$T2_MIRRORED" "real wiki index" \
  "T2: second apply did NOT re-mirror (data/shared still holds original)"
smoke_assert_not_contains "$T2_MIRRORED" "CHANGED-AFTER-FIRST-MIRROR" \
  "T2: post-mirror legacy mutation must not leak into data/shared"
assert_no_sudo "T2" "$T2_HOME"
smoke_log "T2 PASS: sentinel-gated idempotency holds"

# --- T3: marker-only-no-isolated skip also relocates -------------------------

smoke_log "T3: Darwin marker-only-no-isolated skip (UPGRADE_CONTEXT=1) also relocates"
T3_HOME="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_HOME/shared"
seed_legacy_shared "$T3_HOME/shared"
T3_OUT="$T3_HOME/out.txt"
run_apply_for_upgrade Darwin shared 1 "$T3_HOME" "$T3_OUT"
T3_PAYLOAD="$(cat "$T3_OUT")"
smoke_assert_contains "$T3_PAYLOAD" '"reason":"marker-only-no-isolated-roster"' \
  "T3: marker-only-no-isolated skip JSON emitted"
assert_backfill_effects "T3" "$T3_HOME"
assert_no_sudo "T3" "$T3_HOME"
smoke_log "T3 PASS: backfill fires before the marker-only fast-path too"

# --- T4: empty legacy → reason=no-legacy-content -----------------------------

smoke_log "T4: empty legacy shared → sentinel reason=no-legacy-content, no crash"
T4_HOME="$SMOKE_TMP_ROOT/t4"
mkdir -p "$T4_HOME/shared"   # exists but empty
T4_OUT="$T4_HOME/out.txt"
run_apply_for_upgrade Darwin shared 0 "$T4_HOME" "$T4_OUT"
T4_PAYLOAD="$(cat "$T4_OUT")"
smoke_assert_contains "$T4_PAYLOAD" '"reason":"macos-shared-agent"' \
  "T4: skip JSON still emitted with empty legacy"
smoke_assert_file_exists "$T4_HOME/data/.v2-shared-mirror.sentinel" \
  "T4: sentinel written even with empty legacy"
smoke_assert_contains "$(cat "$T4_HOME/data/.v2-shared-mirror.sentinel" 2>/dev/null)" \
  "reason=no-legacy-content" "T4: sentinel reason=no-legacy-content"
smoke_log "T4 PASS: empty-legacy path records no-legacy-content, no crash"

# --- T5: sentinel-gated resolver flip (lib/bridge-isolation-v2.sh) -----------

smoke_log "T5: resolver flip is sentinel-gated (direct isolation-v2.sh source)"
resolver_shared_dir() {
  # Args: <data_root> [extra env...]; prints the resolved BRIDGE_SHARED_DIR.
  local data_root="$1"; shift
  env -u BRIDGE_SHARED_DIR -u BRIDGE_SHARED_ROOT -u BRIDGE_AGENT_ROOT_V2 \
      -u BRIDGE_CONTROLLER_STATE_ROOT "$@" \
      BRIDGE_LAYOUT=v2 BRIDGE_DATA_ROOT="$data_root" \
      "$BRIDGE_BASH" --noprofile --norc -c "
        source '$REPO_ROOT/lib/bridge-isolation-v2.sh' >/dev/null 2>&1 || true
        printf '%s\n' \"\${BRIDGE_SHARED_DIR:-unset}\"
      " 2>&1
}
T5_DATA="$SMOKE_TMP_ROOT/t5/data"
mkdir -p "$T5_DATA/shared/wiki"
# No sentinel -> no flip.
T5_NOSENT="$(resolver_shared_dir "$T5_DATA")"
smoke_assert_not_contains "$T5_NOSENT" "$T5_DATA/shared" \
  "T5: resolver does NOT flip without sentinel"
# Sentinel present -> flip to data/shared.
printf 'm\n' >"$T5_DATA/.v2-shared-mirror.sentinel"
T5_SENT="$(resolver_shared_dir "$T5_DATA")"
smoke_assert_eq "$T5_DATA/shared" "$T5_SENT" \
  "T5: resolver flips BRIDGE_SHARED_DIR=data/shared with sentinel"
# Explicit override always wins.
T5_OVERRIDE="$(resolver_shared_dir "$T5_DATA" BRIDGE_SHARED_DIR=/explicit/override/shared)"
smoke_assert_eq "/explicit/override/shared" "$T5_OVERRIDE" \
  "T5: explicit BRIDGE_SHARED_DIR override wins over sentinel flip"
smoke_log "T5 PASS: flip gated on sentinel, override respected"

# --- T6: structural — backfill precedes both skip branches -------------------

smoke_log "T6: early backfill call precedes both apply_for_upgrade skip branches"
fn_start="$(grep -n '^bridge_isolation_v2_migrate_apply_for_upgrade()' "$MIGRATE_LIB" | head -1 | cut -d: -f1)"
[[ -n "$fn_start" ]] || smoke_fail "T6: apply_for_upgrade function not found"
backfill_ln="$(awk 'NR>='"$fn_start"' && /bridge_isolation_v2_migrate_shared_backfill "\$data_root" "\$target_root"/ {print NR; exit}' "$MIGRATE_LIB")"
marker_only_ln="$(awk 'NR>='"$fn_start"' && /"reason":"marker-only-no-isolated-roster"/ {print NR; exit}' "$MIGRATE_LIB")"
macos_skip_ln="$(awk 'NR>='"$fn_start"' && /"reason":"macos-shared-agent"/ {print NR; exit}' "$MIGRATE_LIB")"
[[ -n "$backfill_ln" && -n "$marker_only_ln" && -n "$macos_skip_ln" ]] \
  || smoke_fail "T6: could not locate all anchors (backfill=$backfill_ln marker-only=$marker_only_ln macos=$macos_skip_ln)"
if (( backfill_ln < marker_only_ln && backfill_ln < macos_skip_ln )); then
  smoke_log "T6 PASS: backfill (L$backfill_ln) precedes marker-only (L$marker_only_ln) + macos-shared-agent (L$macos_skip_ln)"
else
  smoke_fail "T6: backfill call must precede skip branches (backfill=$backfill_ln marker-only=$marker_only_ln macos=$macos_skip_ln)"
fi

smoke_log "all 6 tests PASS"
