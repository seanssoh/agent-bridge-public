#!/usr/bin/env bash
# scripts/smoke/15783-a2a-restart-sources-env.sh
#
# Issue #15783 — `agb a2a daemon start|restart` must source the managed
# install-wide env-override file (`$BRIDGE_HOME/agent-env.local.sh`) BEFORE it
# spawns the receiver, so the receiver's os.environ inherits every
# `agb config set-env` override (BRIDGE_A2A_ROOM_AUTOJOIN and all other
# BRIDGE_A2A_* / arbitrary keys) regardless of the caller's ambient env.
#
# Root cause: the `agb a2a daemon` path reaches the receiver spawn via the thin
# bridge-handoff-daemon.sh dispatcher, which sources ONLY lib/bridge-a2a.sh —
# never bridge-lib.sh / bridge_load_roster (the loader that sources
# agent-env.local.sh LAST). And the top-level `agent-bridge` wrapper SKIPS the
# pre-dispatch bridge_load_roster for the `a2a` verb (perf skip-list). So the
# receiver came up WITHOUT the override → the autojoin gate (reads os.environ
# at request time) saw OFF → 403, making the documented enable procedure a
# no-op.
#
# Fix: bridge_a2a_receiver_start() (lib/bridge-a2a.sh) now calls
# bridge_a2a_source_env_overrides() — which sources the canonical override file
# DIRECTLY (not bridge_load_roster, which is undefined in the dispatcher
# context and carries heavy restart-irrelevant side effects) — right before the
# `nohup python3 bridge-handoffd.py serve` spawn.
#
# This smoke is NON-VACUOUS + mutation-proven:
#   T1 — function contract: bridge_a2a_source_env_overrides exports BOTH a
#        BRIDGE_A2A_ROOM_AUTOJOIN=1 AND a second arbitrary BRIDGE_A2A_* override
#        from a test agent-env.local.sh into the current shell, starting from a
#        CLEAN env (neither var present in the caller).
#   T2 — integration: drive the REAL bridge_a2a_receiver_start with a stub
#        `bridge-handoffd.py` that dumps its os.environ; assert the dumped env
#        carries BOTH overrides — proving the spawn inherits them.
#   T3 — file-exists guard: a missing override file is a quiet no-op (start
#        still proceeds; no var leaks).
#   M  — MUTATION: with the source line deleted from a COPY of lib/bridge-a2a.sh,
#        the spawned receiver env does NOT carry the override — proving the
#        source is load-bearing (T2 would pass vacuously without it).
#
# Footgun #11: printf-only stub construction, no heredoc-fed subprocess. Runs
# entirely under an isolated $TMP; never touches operator/live bridge state.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
LIB_A2A="$ROOT_DIR/lib/bridge-a2a.sh"

[[ -f "$LIB_A2A" ]] || { printf 'FAIL (bootstrap): missing %s\n' "$LIB_A2A" >&2; exit 2; }

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err()  { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP="$(mktemp -d -t agb-15783-a2a-restart-env.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# A python3 is required for the integration stub (writes its own env dump).
command -v python3 >/dev/null 2>&1 || { printf 'SKIP: python3 not available\n'; exit 0; }

# Hermetic env: a developer/operator shell may have BRIDGE_STATE_DIR /
# BRIDGE_LOG_DIR / BRIDGE_AGENT_ENV_LOCAL_FILE exported pointing at the LIVE
# install. Those override the $BRIDGE_HOME-derived paths, so without scrubbing
# them the receiver-start helper would resolve the LIVE pidfile and short-
# circuit on the operator's real receiver (and worse, could read live state).
# Unset every BRIDGE_* derivation override so all paths derive from the
# isolated $BRIDGE_HOME we set per subshell. CI has none of these set; this
# keeps a local run faithful to CI. Call as the FIRST line inside each isolated
# subshell.
scrub_bridge_env() {
  unset BRIDGE_STATE_DIR BRIDGE_LOG_DIR BRIDGE_AGENT_ENV_LOCAL_FILE \
        BRIDGE_AGENT_ENV_FILE BRIDGE_AGENT_ID BRIDGE_ROSTER_FILE \
        BRIDGE_ROSTER_LOCAL_FILE BRIDGE_A2A_ROOM_AUTOJOIN \
        BRIDGE_A2A_SMOKE_15783 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Shared fixture: an isolated BRIDGE_HOME with a managed-format
# agent-env.local.sh carrying two BRIDGE_A2A_* overrides.
# ---------------------------------------------------------------------------
HOME_DIR="$TMP/bridge-home"
mkdir -p "$HOME_DIR/state/handoff" "$HOME_DIR/logs"
ENV_FILE="$HOME_DIR/agent-env.local.sh"
# Managed format == one `export KEY='value'` per line (bridge-config.py
# render_env_export_line). Two distinct BRIDGE_A2A_* keys prove the fix is
# BROAD (all overrides), not autojoin-specific.
{
  printf "# managed by agb config set-env — do not edit by hand\n"
  printf "export BRIDGE_A2A_ROOM_AUTOJOIN='1'\n"
  printf "export BRIDGE_A2A_SMOKE_15783='broad-marker'\n"
} > "$ENV_FILE"

# Minimal handoff config so bridge_a2a_receiver_start passes the
# config-not-found guard.
CONFIG="$HOME_DIR/handoff.local.json"
printf '{}\n' > "$CONFIG"

# ---------------------------------------------------------------------------
# T1 — function contract: source overrides into a CLEAN shell.
# Run in a subshell so the sourced vars do not leak into the harness, and so
# the "clean caller env" precondition is real (the vars are NOT exported here).
# ---------------------------------------------------------------------------
printf '== T1 — bridge_a2a_source_env_overrides exports ALL agent-env.local.sh overrides from a clean env ==\n'
T1_OUT="$TMP/t1.out"
(
  # CLEAN caller env: the override vars are deliberately absent.
  scrub_bridge_env
  export BRIDGE_HOME="$HOME_DIR"
  # shellcheck source=lib/bridge-a2a.sh
  source "$LIB_A2A"
  bridge_a2a_source_env_overrides
  printf 'AUTOJOIN=%s\n' "${BRIDGE_A2A_ROOM_AUTOJOIN:-UNSET}"
  printf 'BROAD=%s\n' "${BRIDGE_A2A_SMOKE_15783:-UNSET}"
) > "$T1_OUT" 2>/dev/null

step "BRIDGE_A2A_ROOM_AUTOJOIN propagates (the autojoin gate)"
if grep -q '^AUTOJOIN=1$' "$T1_OUT"; then ok; else err "autojoin not set: $(tr '\n' '|' < "$T1_OUT")"; fi

step "a SECOND BRIDGE_A2A_* override propagates (broad, not autojoin-only)"
if grep -q '^BROAD=broad-marker$' "$T1_OUT"; then ok; else err "broad override not set: $(tr '\n' '|' < "$T1_OUT")"; fi

# ---------------------------------------------------------------------------
# Integration driver: build a stub bridge-handoffd.py that (1) passes
# `preflight`, and on `serve --detach --pidfile P --config C` (2) dumps its
# os.environ to $ENV_DUMP, (3) writes its own pid to P, (4) stays alive long
# enough for bridge_a2a_receiver_pid_is_receiver() to verify it. The stub is
# named bridge-handoffd.py and invoked with the real argv, so the cmdline
# carries `bridge-handoffd.py`, `serve`, and `--pidfile <P>` — satisfying the
# pid-is-receiver match.
# ---------------------------------------------------------------------------
make_stub_repo() {
  # $1 = repo dir to populate with the stub bridge-handoffd.py
  local repo="$1"
  mkdir -p "$repo"
  local stub="$repo/bridge-handoffd.py"
  {
    printf '#!/usr/bin/env python3\n'
    printf 'import os, sys, time\n'
    printf 'argv = sys.argv[1:]\n'
    printf 'if argv and argv[0] == "preflight":\n'
    printf '    sys.exit(0)\n'
    printf 'if argv and argv[0] == "serve":\n'
    printf '    pidfile = None\n'
    printf '    if "--pidfile" in argv:\n'
    printf '        pidfile = argv[argv.index("--pidfile") + 1]\n'
    printf '    dump = os.environ.get("BRIDGE_A2A_SMOKE_ENV_DUMP")\n'
    printf '    if dump:\n'
    printf '        with open(dump, "w", encoding="utf-8") as fh:\n'
    printf '            for k, v in sorted(os.environ.items()):\n'
    printf '                fh.write("%%s=%%s\\n" %% (k, v))\n'
    printf '    pid = os.fork()\n'
    printf '    if pid > 0:\n'
    printf '        sys.exit(0)\n'
    printf '    os.setsid()\n'
    printf '    if pidfile:\n'
    printf '        with open(pidfile, "w", encoding="utf-8") as fh:\n'
    printf '            fh.write(str(os.getpid()))\n'
    printf '    time.sleep(8)\n'
    printf '    sys.exit(0)\n'
    printf 'sys.exit(0)\n'
  } > "$stub"
}

# Drive bridge_a2a_receiver_start against a given lib-a2a copy + stub repo, with
# a CLEAN caller env, and return the receiver env dump path.
# $1 = lib-a2a path to source ; $2 = env-dump path
run_receiver_start() {
  local lib="$1" dump="$2"
  local repo="$TMP/repo-$RANDOM"
  make_stub_repo "$repo"
  (
    scrub_bridge_env
    export BRIDGE_HOME="$HOME_DIR"
    export BRIDGE_A2A_REPO_ROOT="$repo"
    export BRIDGE_A2A_CONFIG="$CONFIG"
    export BRIDGE_A2A_SMOKE_ENV_DUMP="$dump"
    # Fresh pidfile each run.
    rm -f "$HOME_DIR/state/handoff/handoffd.pid"
    # shellcheck source=/dev/null
    source "$lib"
    bridge_a2a_receiver_start >/dev/null 2>&1 || true
  )
  # Reap the lingering stub child so it does not outlive the smoke.
  if [[ -f "$HOME_DIR/state/handoff/handoffd.pid" ]]; then
    kill "$(cat "$HOME_DIR/state/handoff/handoffd.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "$HOME_DIR/state/handoff/handoffd.pid"
  fi
}

# ---------------------------------------------------------------------------
# T2 — integration: the REAL receiver spawn inherits the overrides.
# ---------------------------------------------------------------------------
printf '== T2 — the spawned receiver os.environ carries the overrides (real bridge_a2a_receiver_start) ==\n'
DUMP_FIX="$TMP/env-dump-fix"
run_receiver_start "$LIB_A2A" "$DUMP_FIX"

step "env dump was produced (receiver actually spawned)"
if [[ -s "$DUMP_FIX" ]]; then ok; else err "no env dump — stub serve did not run"; fi

step "receiver env has BRIDGE_A2A_ROOM_AUTOJOIN=1"
if grep -q '^BRIDGE_A2A_ROOM_AUTOJOIN=1$' "$DUMP_FIX"; then ok; else err "autojoin missing from receiver env"; fi

step "receiver env has the second BRIDGE_A2A_* override (broad)"
if grep -q '^BRIDGE_A2A_SMOKE_15783=broad-marker$' "$DUMP_FIX"; then ok; else err "broad override missing from receiver env"; fi

# ---------------------------------------------------------------------------
# T3 — missing override file is a quiet no-op (start still proceeds).
# ---------------------------------------------------------------------------
printf '== T3 — a missing agent-env.local.sh is a quiet no-op ==\n'
NO_ENV_HOME="$TMP/no-env-home"
mkdir -p "$NO_ENV_HOME/state/handoff" "$NO_ENV_HOME/logs"
printf '{}\n' > "$NO_ENV_HOME/handoff.local.json"
DUMP_NOENV="$TMP/env-dump-noenv"
REPO_NOENV="$TMP/repo-noenv"
make_stub_repo "$REPO_NOENV"
(
  scrub_bridge_env
  export BRIDGE_HOME="$NO_ENV_HOME"
  export BRIDGE_A2A_REPO_ROOT="$REPO_NOENV"
  export BRIDGE_A2A_CONFIG="$NO_ENV_HOME/handoff.local.json"
  export BRIDGE_A2A_SMOKE_ENV_DUMP="$DUMP_NOENV"
  rm -f "$NO_ENV_HOME/state/handoff/handoffd.pid"
  # shellcheck source=/dev/null
  source "$LIB_A2A"
  bridge_a2a_receiver_start >/dev/null 2>&1 || true
)
if [[ -f "$NO_ENV_HOME/state/handoff/handoffd.pid" ]]; then
  kill "$(cat "$NO_ENV_HOME/state/handoff/handoffd.pid" 2>/dev/null)" 2>/dev/null || true
fi
step "receiver still spawned with no override file present"
if [[ -s "$DUMP_NOENV" ]]; then ok; else err "receiver did not spawn when override file absent"; fi
step "no override var leaked when the file is absent"
if grep -q '^BRIDGE_A2A_ROOM_AUTOJOIN=' "$DUMP_NOENV"; then err "autojoin present without an override file"; else ok; fi

# ---------------------------------------------------------------------------
# M — MUTATION: delete the source-overrides call from a COPY of lib/bridge-a2a.sh
# and confirm the spawned receiver env NO LONGER carries the override. Proves
# the source line is load-bearing (T2 is not vacuously green).
# ---------------------------------------------------------------------------
printf '== M — mutation: removing the source line drops the override from the receiver env ==\n'
LIB_MUT="$TMP/bridge-a2a.mutant.sh"
# Strip the single in-function call. grep -v on the exact call line is the
# minimal mutation; the helper definition can stay (it is the CALL that
# propagates). Pure-bash filter, no sed-stdin heredoc.
MUT_REMOVED=0
: > "$LIB_MUT"
while IFS= read -r _line || [[ -n "$_line" ]]; do
  case "$_line" in
    *"  bridge_a2a_source_env_overrides"*)
      # Drop ONLY the bare in-function call (two-space indent inside
      # bridge_a2a_receiver_start), not the definition or comments.
      MUT_REMOVED=1
      continue
      ;;
  esac
  printf '%s\n' "$_line" >> "$LIB_MUT"
done < "$LIB_A2A"

step "mutation removed the source-overrides call (regression-proof anchor)"
if [[ "$MUT_REMOVED" -eq 1 ]]; then ok; else err "could not find the in-function bridge_a2a_source_env_overrides call to mutate"; fi

DUMP_MUT="$TMP/env-dump-mutant"
run_receiver_start "$LIB_MUT" "$DUMP_MUT"
step "mutant receiver env does NOT carry the override (source is load-bearing)"
if [[ -s "$DUMP_MUT" ]] && grep -q '^BRIDGE_A2A_ROOM_AUTOJOIN=1$' "$DUMP_MUT"; then
  err "override present even with the source line removed — T2 would pass vacuously"
else
  ok
fi

# ---------------------------------------------------------------------------
printf '\n== 15783-a2a-restart-sources-env: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
