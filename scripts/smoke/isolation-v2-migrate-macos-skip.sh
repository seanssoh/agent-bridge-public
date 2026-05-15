#!/usr/bin/env bash
# v0.13.6 hotfix track 4 — regression smoke for the macOS shared-agent
# silent-skip branch in `bridge_isolation_v2_migrate_apply_for_upgrade`.
#
# Reproduces the v0.13.5 regression: on a macOS host with no isolated
# agents (operator's patch host), the platform-agnostic migration body
# called `bridge_isolation_v2_privilege_preflight` which demanded
# passwordless sudo and aborted the upgrade when the operator declined.
#
# Coverage:
#   T1 — Darwin + no isolated agents → JSON `skipped=true reason=macos-shared-agent`
#        + `sudo` is never invoked (verified via PATH shim that records calls).
#   T2 — Idempotent: a second call produces the same skip JSON.
#   T3 — Linux + no isolated agents → does NOT take the skip branch
#        (proceeds far enough to hit the existing migration body — the
#        body itself is allowed to fail in this temp fixture; what we
#        assert is the JSON envelope shape).
#   T4 — Darwin + at least one isolated agent in the roster → does NOT
#        take the skip branch (same envelope assertion as T3).
#   T5 — `bridge_isolation_v2_roster_has_isolated_agents` standalone
#        sanity: returns 1 with no isolated agents, returns 0 once one is
#        present.
#
# All scripted shell snippets are emitted as $'…' literals or `mktemp`
# + `printf` to a script file — no heredocs or here-strings (Bash 5.3.9
# heredoc_write deadlock class, footgun #11).

set -uo pipefail

SMOKE_NAME="isolation-v2-migrate-macos-skip"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

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

# Build a `bin/` directory shim:
#   * `uname` always reports the requested kernel (Darwin or Linux).
#   * `sudo` records every call to a log file. The skip branch must NOT
#     invoke sudo.
#
# Emitted via printf-to-file (no heredocs).
build_platform_shim() {
  local shim_dir="$1"
  local fake_uname="$2"
  local sudo_log="$3"

  mkdir -p "$shim_dir"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# uname shim — reports the requested platform regardless of'
    printf '%s\n' '# the host kernel, so the skip branch can be exercised on'
    printf '%s\n' '# any CI runner.'
    printf 'FAKE_UNAME=%q\n' "$fake_uname"
    printf '%s\n' 'if [[ $# -eq 0 ]]; then'
    printf '%s\n' '  printf "%s\n" "$FAKE_UNAME"'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
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
    printf '%s\n' '# sudo shim — records the call and exits non-zero so any'
    printf '%s\n' '# accidental sudo invocation in the skip branch turns into a'
    printf '%s\n' '# loud test failure rather than a silent state mutation.'
    printf 'LOG=%q\n' "$sudo_log"
    printf '%s\n' 'printf "[sudo-shim] %s\n" "$*" >>"$LOG"'
    printf '%s\n' 'exit 99'
  } >"$shim_dir/sudo"
  chmod +x "$shim_dir/sudo"
}

# Symlink the other PATH essentials into the shim dir so the driver
# subshell still has access to bash/mkdir/rm/printf/cat/grep when we
# replace PATH wholesale.
populate_basic_path() {
  local shim_dir="$1"
  local cmd target
  for cmd in bash mkdir rm cat tr grep sed awk printf id stat tee chmod dirname env date mktemp readlink ls cp mv touch wc head tail find sort uniq true false python3 git tmux jq sqlite3 sha256sum md5; do
    target="$(command -v "$cmd" 2>/dev/null || true)"
    # command -v on shell builtins returns the bare command name, not a
    # path. Only symlink real filesystem targets — the builtin will still
    # resolve inside the child shell because bash falls back to builtins
    # when PATH lookup misses.
    [[ -n "$target" && "${target:0:1}" == "/" ]] || continue
    # Use -L so existing symlinks (even with absent targets) are detected;
    # bare -e returns false for broken symlinks and we'd retry the ln.
    [[ -L "$shim_dir/$cmd" || -e "$shim_dir/$cmd" ]] && continue
    ln -s "$target" "$shim_dir/$cmd" 2>/dev/null || true
  done
}

# Build a one-shot driver script. `printf` line-by-line into a tempfile
# so we never cross the heredoc surface.
write_driver_script() {
  local out="$1"
  shift
  : >"$out"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

# --- T5 first: standalone helper sanity check --------------------------------

smoke_log "T5: bridge_isolation_v2_roster_has_isolated_agents standalone sanity"

T5_HOME="$SMOKE_TMP_ROOT/t5"
mkdir -p "$T5_HOME/state"

T5_DRIVER="$SMOKE_TMP_ROOT/t5-driver.sh"
write_driver_script "$T5_DRIVER" \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  'cd "$REPO_ROOT"' \
  'export BRIDGE_HOME="$T5_HOME"' \
  'export BRIDGE_STATE_DIR="$T5_HOME/state"' \
  'export BRIDGE_LOG_DIR="$T5_HOME/logs"' \
  'export BRIDGE_SHARED_DIR="$T5_HOME/shared"' \
  'export BRIDGE_DATA_ROOT="$T5_HOME/data"' \
  'export BRIDGE_LAYOUT="v2"' \
  'mkdir -p "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$BRIDGE_DATA_ROOT/shared" "$BRIDGE_DATA_ROOT/agents" "$BRIDGE_DATA_ROOT/state"' \
  ': >"$T5_HOME/agent-roster.local.sh"' \
  'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1' \
  'declare -F bridge_isolation_v2_roster_has_isolated_agents >/dev/null 2>&1 || { echo "[t5] helper missing"; exit 1; }' \
  'rc=0; bridge_isolation_v2_roster_has_isolated_agents 2>/dev/null || rc=$?' \
  'echo "empty=$rc"' \
  'BRIDGE_AGENT_IDS=(test_shared)' \
  'bridge_agent_linux_user_isolation_effective() { return 1; }' \
  'rc=0; bridge_isolation_v2_roster_has_isolated_agents 2>/dev/null || rc=$?' \
  'echo "shared_only=$rc"' \
  'BRIDGE_AGENT_IDS=(test_shared test_isolated)' \
  'bridge_agent_linux_user_isolation_effective() { local a="${1:-}"; case "$a" in test_isolated) return 0;; *) return 1;; esac; }' \
  'rc=0; bridge_isolation_v2_roster_has_isolated_agents 2>/dev/null || rc=$?' \
  'echo "mixed=$rc"'

T5_OUT="$(REPO_ROOT="$REPO_ROOT" T5_HOME="$T5_HOME" "$BRIDGE_BASH" "$T5_DRIVER" 2>&1)" || true

# T5 expectation corrected v0.13.10 — `bridge_isolation_v2_roster_has_isolated_agents`
# returns rc=2 (NOT rc=1) when `BRIDGE_AGENT_IDS` is undeclared, per the
# helper's documented contract at lib/bridge-isolation-v2.sh:1083-1107:
#   0 — has isolated agent
#   1 — roster fully iterated, NO agent is effectively isolated (confirmed)
#   2 — predicate function or BRIDGE_AGENT_IDS array unavailable (unknown)
# The first sub-case here invokes the helper before `BRIDGE_AGENT_IDS=...`
# is set in the driver, so the helper hits the `declare -p BRIDGE_AGENT_IDS
# || return 2` guard — rc=2 is the correct expectation. Latent bug from
# PR #882: the original assertion mistakenly expected rc=1 ("empty array")
# but the smoke driver leaves the array undeclared, not empty. Never
# surfaced until Track A's lib/bridge-isolation-v2-migrate.sh edit pulled
# this smoke into the ci-select required set.
case "$T5_OUT" in
  *"empty=2"*) ;;
  *) smoke_fail "T5 expected empty=2 (BRIDGE_AGENT_IDS undeclared → rc=2 unknown), got: $T5_OUT" ;;
esac
case "$T5_OUT" in
  *"shared_only=1"*) ;;
  *) smoke_fail "T5 expected shared_only=1 (no isolated agents → non-zero), got: $T5_OUT" ;;
esac
case "$T5_OUT" in
  *"mixed=0"*) ;;
  *) smoke_fail "T5 expected mixed=0 (at least one isolated → zero), got: $T5_OUT" ;;
esac
smoke_log "T5 PASS: helper distinguishes undeclared / shared-only / mixed rosters"

# --- shared fixture for T1..T4 -----------------------------------------------

# Generate a JSON-extraction helper inline rather than depending on jq —
# the apply_for_upgrade wrapper emits a single-line JSON object so a
# grep is sufficient.
assert_skipped() {
  local label="$1"
  local payload="$2"
  case "$payload" in
    *'"skipped":true'*) ;;
    *) smoke_fail "$label expected payload to carry skipped=true, got: $payload" ;;
  esac
  case "$payload" in
    *'"reason":"macos-shared-agent"'*) ;;
    *) smoke_fail "$label expected reason=macos-shared-agent, got: $payload" ;;
  esac
  case "$payload" in
    *'"mode":"isolation-v2-migrate"'*) ;;
    *) smoke_fail "$label expected mode=isolation-v2-migrate, got: $payload" ;;
  esac
}

assert_not_skipped_for_macos_branch() {
  # The skip branch emits the specific `reason=macos-shared-agent` token.
  # Anything else (success / privilege error / migration body output)
  # must not carry that token — that is the regression we're protecting
  # against in T3/T4.
  local label="$1"
  local payload="$2"
  case "$payload" in
    *'"reason":"macos-shared-agent"'*)
      smoke_fail "$label: macos-shared-agent skip branch fired on a path that should NOT take it. payload=$payload" ;;
  esac
}

# Build a Darwin-shim PATH with sudo recorder, then run a one-shot driver
# that sources the bridge libs + calls the apply_for_upgrade wrapper.
run_apply_for_upgrade() {
  local fake_uname="$1"        # Darwin | Linux
  local roster_kind="$2"       # empty | shared | isolated
  local home_dir="$3"
  local out_file="$4"

  local shim_dir="$home_dir/shim-bin"
  local sudo_log="$home_dir/sudo-calls.log"
  : >"$sudo_log"
  build_platform_shim "$shim_dir" "$fake_uname" "$sudo_log"
  populate_basic_path "$shim_dir"

  mkdir -p "$home_dir/state" "$home_dir/logs" "$home_dir/shared"

  local roster_setup
  case "$roster_kind" in
    empty)
      roster_setup='unset BRIDGE_AGENT_IDS 2>/dev/null || true'
      ;;
    shared)
      # Roster has agents, but all return non-zero from
      # bridge_agent_linux_user_isolation_effective. Force the predicate
      # to return 1 unconditionally.
      roster_setup='BRIDGE_AGENT_IDS=(a1 a2); bridge_agent_linux_user_isolation_effective() { return 1; }'
      ;;
    isolated)
      # At least one agent returns 0 from the predicate.
      roster_setup='BRIDGE_AGENT_IDS=(a1 a2); bridge_agent_linux_user_isolation_effective() { local a="${1:-}"; case "$a" in a2) return 0;; *) return 1;; esac; }'
      ;;
    *) smoke_fail "internal: unknown roster_kind=$roster_kind" ;;
  esac

  mkdir -p "$home_dir/data/shared" "$home_dir/data/agents" "$home_dir/data/state"
  : >"$home_dir/agent-roster.local.sh"

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

  # PATH = shim-dir only, so `uname` and `sudo` resolve to our shims.
  PATH="$shim_dir" \
    REPO_ROOT="$REPO_ROOT" \
    HOME_DIR="$home_dir" \
    BRIDGE_HOME="$home_dir" \
    BRIDGE_STATE_DIR="$home_dir/state" \
    BRIDGE_LOG_DIR="$home_dir/logs" \
    BRIDGE_SHARED_DIR="$home_dir/shared" \
    BRIDGE_DATA_ROOT="$home_dir/data" \
    BRIDGE_LAYOUT="v2" \
    "$BRIDGE_BASH" "$driver" >"$out_file" 2>&1 || true
}

# --- T1: Darwin + no isolated agents → skip branch + no sudo ----------------

smoke_log "T1: Darwin + no isolated agents → skip branch (no sudo invocation)"

T1_HOME="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_HOME"
T1_OUT="$T1_HOME/out.txt"
run_apply_for_upgrade Darwin shared "$T1_HOME" "$T1_OUT"
T1_PAYLOAD="$(cat "$T1_OUT")"
assert_skipped "T1" "$T1_PAYLOAD"

if [[ -s "$T1_HOME/sudo-calls.log" ]]; then
  smoke_fail "T1: sudo shim recorded calls — skip branch must NOT call sudo. log=$(cat "$T1_HOME/sudo-calls.log")"
fi
smoke_log "T1 PASS: skip JSON emitted + sudo never invoked"

# --- T2: idempotent — second call same result --------------------------------

smoke_log "T2: idempotent — repeated call produces the same skip JSON"

T2_HOME="$SMOKE_TMP_ROOT/t2"
mkdir -p "$T2_HOME"
T2_OUT_A="$T2_HOME/out-a.txt"
T2_OUT_B="$T2_HOME/out-b.txt"
run_apply_for_upgrade Darwin shared "$T2_HOME" "$T2_OUT_A"
run_apply_for_upgrade Darwin shared "$T2_HOME" "$T2_OUT_B"
T2_A="$(cat "$T2_OUT_A")"
T2_B="$(cat "$T2_OUT_B")"
assert_skipped "T2-A" "$T2_A"
assert_skipped "T2-B" "$T2_B"

if [[ -s "$T2_HOME/sudo-calls.log" ]]; then
  smoke_fail "T2: sudo shim recorded calls across idempotent runs. log=$(cat "$T2_HOME/sudo-calls.log")"
fi
smoke_log "T2 PASS: idempotent skip + no sudo across two calls"

# --- T3: Linux + no isolated agents → NOT the skip branch -------------------

smoke_log "T3: Linux + no isolated agents → must NOT take the macOS skip branch"

T3_HOME="$SMOKE_TMP_ROOT/t3"
mkdir -p "$T3_HOME"
T3_OUT="$T3_HOME/out.txt"
run_apply_for_upgrade Linux shared "$T3_HOME" "$T3_OUT"
T3_PAYLOAD="$(cat "$T3_OUT")"
assert_not_skipped_for_macos_branch "T3" "$T3_PAYLOAD"
smoke_log "T3 PASS: Linux path bypasses the macOS skip branch"

# --- T4: Darwin + at least one isolated agent → NOT the skip branch ---------

smoke_log "T4: Darwin + at least one isolated agent → must NOT take the macOS skip branch"

T4_HOME="$SMOKE_TMP_ROOT/t4"
mkdir -p "$T4_HOME"
T4_OUT="$T4_HOME/out.txt"
run_apply_for_upgrade Darwin isolated "$T4_HOME" "$T4_OUT"
T4_PAYLOAD="$(cat "$T4_OUT")"
assert_not_skipped_for_macos_branch "T4" "$T4_PAYLOAD"
smoke_log "T4 PASS: Darwin+isolated-present bypasses the skip branch"

smoke_log "all 5 tests PASS"
