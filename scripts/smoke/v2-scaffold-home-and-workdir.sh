#!/usr/bin/env bash
# scripts/smoke/v2-scaffold-home-and-workdir.sh — Issue #686 regression smoke.
#
# Pins the v2 layout contract: `bridge_scaffold_agent_home` must
# materialize BOTH `<agent-root>/home/` (the agent's HOME) AND its sibling
# `<agent-root>/workdir/` (the resolver target returned by
# `bridge_agent_workdir`). Issue #686 (v0.8.5 cycle) reported that
# scaffold only created `home/`, so `bridge-start.sh --dry-run` (and any
# resolver-relative tooling — doctor/status/start) bombed with
# `workdir가 없습니다` on every fresh v2 install.
#
# The fix landed in PR #685; this smoke locks it in so a future refactor
# of `bridge_scaffold_agent_home` cannot silently regress the sibling
# mkdir. Coverage spans BOTH scaffold branches:
#
#   T1 — non-isolated (shared) v2 scaffold (the plain-`mkdir -p` block
#        near the end of `bridge_scaffold_agent_home`) creates BOTH
#        `home/` and `workdir/` siblings under
#        `$BRIDGE_AGENT_ROOT_V2/<agent>/`. The scaffold materializes its
#        `$home` argument plus the OTHER v2 sibling
#        (`_scaffold_v2_sibling`). Note: as of Track C v0.13.10 (#895),
#        `bridge_agent_workdir` does not return the v2 `workdir/` anchor
#        for shared agents — it gates the v2-anchor override on
#        `linux-user` isolation and falls through to the explicit/default
#        resolution otherwise. Pinning the sibling mkdir is still
#        correct: (a) the scaffold still emits it on both branches and
#        an accidental removal should be a deliberate decision, not a
#        silent drop; (b) the sibling is load-bearing for the linux-user
#        branch covered by T2 and the two branches share the
#        `_scaffold_v2_sibling` local.
#   T2 — isolated v2 scaffold (the `bridge_linux_sudo_root mkdir` block)
#        creates the same `home/` + `workdir/` sibling pair via the
#        mkdir` path that the linux-user isolation branch uses on a fresh
#        install where `data/agents/` is `root:root mode 755`. Asserts
#        the resolver-agreement invariant (`bridge_agent_workdir` returns
#        the materialized `<agent-root>/workdir`) since linux-user is the
#        one isolation mode where the v2-anchor branch still fires
#        post-#895. Gated on Linux + passwordless sudo + non-root caller;
#        skips cleanly on macOS / no-sudo / root with a labeled
#        smoke_log message. Required because the isolated branch is
#        structurally separate code — a future refactor could break it
#        independently of T1.
#
# Scope note: v0.8.0+ requires the v2 isolation layout; bridge-lib.sh
# refuses to load with `BRIDGE_LAYOUT=legacy`, so the legacy-fallback
# code path inside `bridge_scaffold_agent_home` is unreachable in any
# current install and is intentionally not covered here.
#
# The smoke drives `bridge_scaffold_agent_home` directly rather than
# going through `bridge-agent.sh create` end-to-end: that wrapper exercises
# many adjacent paths (channel setup, sync_skill_docs, bridge-start dry-run)
# that have their own platform-dependent hangs / sudo prompts on a fresh
# `BRIDGE_HOME` and would mask the specific mkdir contract this smoke is
# trying to pin. `bridge_render_template_string` is stubbed to a no-op for
# the same reason — the unit under test is the v2 sibling mkdir, not
# template rendering.
#
# Regression bite: this smoke FAILS if the `if [[ -n "$_scaffold_v2_sibling" ]];
# then mkdir -p ...; fi` block is reverted in EITHER scaffold branch —
# T1 fails if the non-isolated plain-`mkdir` block regresses, T2 (when
# its gate is met) fails if the isolated `bridge_linux_sudo_root mkdir`
# block regresses.

set -uo pipefail

SMOKE_NAME="v2-scaffold-home-and-workdir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# T2 creates root-owned dirs via sudo; the default rm in
# `smoke_cleanup_temp_root` can fail on those without escalation. Wrap
# cleanup so the sudo-created tree is reaped before the controller-owned
# rm runs.
cleanup() {
  if [[ -n "${T2_SUDO_CLEANUP_ROOT:-}" && -d "$T2_SUDO_CLEANUP_ROOT" ]]; then
    sudo -n rm -rf "$T2_SUDO_CLEANUP_ROOT" >/dev/null 2>&1 || true
  fi
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

# Build a driver script that:
#   1. exports the same v2 env the live runtime would have,
#   2. sources bridge-lib.sh,
#   3. extracts and sources just `bridge_scaffold_agent_home` (line
#      385..618) + its small `bridge_agent_manage_python` /
#      `bridge_render_template_string` deps from `bridge-agent.sh`,
#   4. stubs `bridge_render_template_string` to a no-op so the template
#      loop does not depend on session-template lookup / python3 / etc.,
#   5. calls scaffold with caller-provided isolation args and asserts on
#      the resulting tree.
#
# Driver is emitted via printf-to-file (no heredocs) to stay clear of the
# Bash 5.3.9 heredoc-stdin deadlock class (footgun #11). The caller picks
# isolation mode by exporting `SCAFFOLD_ISOLATION_MODE` + `SCAFFOLD_OS_USER`
# before invoking the driver; empty strings select the non-isolated branch.
write_driver_script() {
  local out="$1"

  : >"$out"
  local line
  for line in \
    '#!/usr/bin/env bash' \
    'set -uo pipefail' \
    'cd "$REPO_ROOT"' \
    'SCRIPT_DIR="$REPO_ROOT"' \
    'source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1' \
    'FUNC_TMP="$DRIVER_TMP_DIR/scaffold-funcs.sh"' \
    '{' \
    '  sed -n "128,139p" "$REPO_ROOT/bridge-agent.sh"' \
    '  sed -n "188,257p" "$REPO_ROOT/bridge-agent.sh"' \
    '  sed -n "385,618p" "$REPO_ROOT/bridge-agent.sh"' \
    '} > "$FUNC_TMP"' \
    'source "$FUNC_TMP"' \
    'declare -F bridge_scaffold_agent_home >/dev/null 2>&1 || { echo "DRIVER_FAIL: bridge_scaffold_agent_home not loaded"; exit 91; }' \
    '# Stub template renderer to a no-op so scaffold returns immediately' \
    '# after the mkdirs (the unit under test). The template loop still' \
    '# touches the filesystem (creating empty target files) but does not' \
    '# depend on the bundled session-template tree.' \
    'bridge_render_template_string() { :; }' \
    'export -f bridge_render_template_string 2>/dev/null || true' \
    'HOME_DIR="$AGENT_HOME_DIR"' \
    'echo "=== scaffold start ==="' \
    'bridge_scaffold_agent_home "$AGENT_ID" "$HOME_DIR" "Probe Agent" "test role" claude static-claude "${SCAFFOLD_ISOLATION_MODE:-}" "${SCAFFOLD_OS_USER:-}"' \
    'echo "=== scaffold end ==="' \
    'echo "AGENT_ROOT_LISTING:"' \
    'ls -1 "$(dirname "$HOME_DIR")" 2>&1 | sed "s/^/  /"' \
    'echo "RESOLVER_OUTPUT:"' \
    'declare -A BRIDGE_AGENT_WORKDIR 2>/dev/null || true' \
    '# Post-#895 (Track C v0.13.10), bridge_agent_workdir gates the v2-anchor' \
    '# override on the agent`s registered isolation_mode (`linux-user` only).' \
    '# Production reads that from `BRIDGE_AGENT_ISOLATION_MODE[<agent>]`,' \
    '# populated by bridge_load_roster from `agent-roster.local.sh`. The' \
    '# driver bypasses roster load (it`s testing scaffold + resolver in' \
    '# isolation), so we mirror the roster state directly: register the' \
    '# agent`s isolation mode here so the resolver`s mode-gate sees the' \
    '# same value the caller passed to scaffold. T1 (no SCAFFOLD_ISOLATION_MODE)' \
    '# leaves the entry unset → resolver falls through to default; T2' \
    '# (linux-user) writes the entry → resolver returns the v2 anchor.' \
    'declare -A BRIDGE_AGENT_ISOLATION_MODE 2>/dev/null || true' \
    '# bridge_agent_isolation_mode also reads `BRIDGE_AGENT_OS_USER[$agent]-`' \
    '# (lib/bridge-agents.sh:794). Under `set -u`, that read fails on an' \
    '# undeclared assoc array and silently aborts the function via the' \
    '# 2>/dev/null in the resolver — falling back to the non-v2 path. Declare' \
    '# the OS_USER map up-front so the predicate sees an empty entry instead' \
    '# of an unset-variable error. The smoke does not exercise os_user-driven' \
    '# linux-user detection (T2 hits the explicit isolation_mode path), so' \
    '# leaving the entry unset is correct — only the declaration is needed.' \
    'declare -A BRIDGE_AGENT_OS_USER 2>/dev/null || true' \
    'if [[ -n "${SCAFFOLD_ISOLATION_MODE:-}" ]]; then' \
    '  BRIDGE_AGENT_ISOLATION_MODE["$AGENT_ID"]="$SCAFFOLD_ISOLATION_MODE"' \
    'fi' \
    'resolved="$(bridge_agent_workdir "$AGENT_ID" 2>&1)"' \
    'echo "  $resolved"' \
    'if [[ -d "$HOME_DIR" ]]; then echo "HOME_DIR_STATUS: dir"; else echo "HOME_DIR_STATUS: missing"; fi' \
    'sibling_workdir="$(dirname "$HOME_DIR")/workdir"' \
    'if [[ -d "$sibling_workdir" ]]; then echo "SIBLING_WORKDIR_STATUS: dir"; else echo "SIBLING_WORKDIR_STATUS: missing"; fi' \
    'if [[ "$resolved" == "$sibling_workdir" ]]; then echo "RESOLVER_MATCH: yes"; else echo "RESOLVER_MATCH: no"; fi' \
    'rm -f "$FUNC_TMP" >/dev/null 2>&1 || true'
  do
    printf '%s\n' "$line" >>"$out"
  done
  chmod +x "$out"
}

# Pull a specific suffix from the driver's stdout. Tab-and-colon
# separated for easy grep.
extract_line() {
  local out="$1"
  local key="$2"
  printf '%s\n' "$out" | sed -n "s/^$key: //p" | head -n 1
}

# --- T1: non-isolated v2 — both home/ and workdir/ siblings created ----------

smoke_log "T1: non-isolated (shared) v2 scaffold materializes BOTH home/ and workdir/ siblings"

T1_DRIVER_DIR="$SMOKE_TMP_ROOT/t1"
mkdir -p "$T1_DRIVER_DIR"
T1_DRIVER="$T1_DRIVER_DIR/driver.sh"
T1_AGENT_ID="probe-v2"
T1_HOME_DIR="$BRIDGE_AGENT_ROOT_V2/$T1_AGENT_ID/home"

write_driver_script "$T1_DRIVER"

T1_OUT="$(
  REPO_ROOT="$REPO_ROOT" \
  DRIVER_TMP_DIR="$T1_DRIVER_DIR" \
  AGENT_ID="$T1_AGENT_ID" \
  AGENT_HOME_DIR="$T1_HOME_DIR" \
  SCAFFOLD_ISOLATION_MODE="" \
  SCAFFOLD_OS_USER="" \
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
  BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
  BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
  BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
  BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
  BRIDGE_LAYOUT="v2" \
  BRIDGE_DATA_ROOT="$BRIDGE_DATA_ROOT" \
  BRIDGE_SHARED_ROOT="$BRIDGE_SHARED_ROOT" \
  BRIDGE_AGENT_ROOT_V2="$BRIDGE_AGENT_ROOT_V2" \
  BRIDGE_CONTROLLER_STATE_ROOT="$BRIDGE_CONTROLLER_STATE_ROOT" \
  BRIDGE_RUNTIME_ROOT="$BRIDGE_RUNTIME_ROOT" \
  BRIDGE_HOOKS_DIR="$BRIDGE_HOOKS_DIR" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
  "$BRIDGE_BASH" "$T1_DRIVER" 2>&1
)"
T1_RC=$?

if [[ $T1_RC -ne 0 ]]; then
  smoke_fail "T1 driver exited rc=$T1_RC. output:
$T1_OUT"
fi

T1_HOME_STATUS="$(extract_line "$T1_OUT" "HOME_DIR_STATUS")"
T1_SIBLING_STATUS="$(extract_line "$T1_OUT" "SIBLING_WORKDIR_STATUS")"

smoke_assert_eq "dir" "$T1_HOME_STATUS" "T1: home/ directory was created"
smoke_assert_eq "dir" "$T1_SIBLING_STATUS" "T1: workdir/ sibling was created (issue #686 fix, non-isolated branch)"
# Note: post-#895 (Track C v0.13.10), bridge_agent_workdir for shared
# agents falls through to bridge_agent_default_home (i.e. `<root>/home`)
# rather than returning `<root>/workdir`. The resolver-agreement
# assertion only applies to the linux-user branch and is covered by T2
# below; the sibling mkdir here is still pinned because the scaffold
# still emits it on both branches.

smoke_log "T1 PASS — non-isolated branch sibling mkdir verified"

# --- T2: isolated (linux-user) v2 — sudo-mediated branch + resolver match ----
#
# The isolated scaffold path at `bridge-agent.sh:470-545` is gated on
# `uname -s == Linux` + sudo + the linux-user predicate. On a fresh
# install, `data/agents/` is `root:root mode 755` so the plain `mkdir -p
# "$home"` fails with `Permission denied`; the sudo-handoff block runs
# the per-agent root + `home/` + `workdir/` mkdirs as root with controller
# ownership instead. T2 exercises that branch end-to-end on Linux CI.
#
# Post-#895 (Track C v0.13.10), linux-user is also the one isolation mode
# where `bridge_agent_workdir` still returns the v2 `workdir/` anchor —
# so T2 additionally asserts the resolver-agreement invariant (= the
# original #686 `workdir가 없습니다` symptom path is fully closed).
#
# Skip cleanly when the gate cannot be satisfied — the smoke runs on
# macOS dev hosts too and must not require interactive sudo there.

smoke_log "T2: isolated linux-user v2 scaffold materializes home/ + workdir/ via sudo-handoff (and resolver agrees)"

T2_SKIP_REASON=""
if [[ "$(uname -s 2>/dev/null || printf 'unknown')" != "Linux" ]]; then
  T2_SKIP_REASON="requires Linux (isolated scaffold branch is uname-gated to Linux)"
elif ! command -v sudo >/dev/null 2>&1; then
  T2_SKIP_REASON="requires sudo (isolated branch uses bridge_linux_sudo_root)"
elif ! sudo -n true 2>/dev/null; then
  T2_SKIP_REASON="requires passwordless sudo (cannot mkdir/chown/chmod as root non-interactively)"
elif [[ "$(id -u)" == "0" ]]; then
  # Running as root would short-circuit `bridge_linux_sudo_root` (it just
  # runs the command directly when uid=0), so the test wouldn't actually
  # exercise the sudo-handoff codepath. Skip rather than produce a false
  # green.
  T2_SKIP_REASON="refusing to run as root (would bypass the sudo-handoff codepath)"
fi

if [[ -n "$T2_SKIP_REASON" ]]; then
  smoke_log "T2 SKIP: $T2_SKIP_REASON"
else
  T2_DRIVER_DIR="$SMOKE_TMP_ROOT/t2"
  mkdir -p "$T2_DRIVER_DIR"
  T2_DRIVER="$T2_DRIVER_DIR/driver.sh"
  # Use a dedicated v2 root for T2 so we never collide with T1's tree and
  # so cleanup can sudo-rm one well-known subtree. The directory is created
  # in a temp location the smoke owns; the sudo-handoff inside scaffold
  # will mkdir its per-agent subdir as root.
  T2_V2_ROOT="$SMOKE_TMP_ROOT/t2-v2-agents"
  T2_DATA_ROOT="$SMOKE_TMP_ROOT/t2-v2-data"
  mkdir -p "$T2_V2_ROOT" "$T2_DATA_ROOT/shared" "$T2_DATA_ROOT/state"
  # Replicate the "fresh install" pre-state: agents/ is root:root mode 755
  # so the controller cannot mkdir into it directly. This is the exact
  # condition the isolated scaffold branch was written to recover from
  # (PR #677 / #688). Without this, the controller's plain `mkdir -p $home`
  # at bridge-agent.sh:547 would race ahead of the sudo block and the
  # isolated branch's mkdirs would no-op against a pre-existing dir.
  sudo -n chown root:root "$T2_V2_ROOT" >/dev/null 2>&1 \
    || smoke_fail "T2 fixture setup: sudo chown root:root $T2_V2_ROOT failed"
  sudo -n chmod 0755 "$T2_V2_ROOT" >/dev/null 2>&1 \
    || smoke_fail "T2 fixture setup: sudo chmod 0755 $T2_V2_ROOT failed"
  # Register the root-owned tree for cleanup so the EXIT trap can sudo-rm
  # it before `smoke_cleanup_temp_root` tries (and fails) to rm it
  # unprivileged.
  T2_SUDO_CLEANUP_ROOT="$T2_V2_ROOT"

  T2_AGENT_ID="probe_iso"   # underscore-form matches the linux-user policy regex
  T2_HOME_DIR="$T2_V2_ROOT/$T2_AGENT_ID/home"
  # `os_user` just needs to be non-empty for `_scaffold_isolation_active=1`;
  # the scaffold's sudo path does not invoke `sudo -u <os_user>` at all —
  # it only uses sudo-as-root for the mkdir/chown/chmod sequence. Use the
  # controller's own login name to keep the value real and avoid creating
  # a system-user dependency.
  T2_OS_USER="$(id -un)"

  write_driver_script "$T2_DRIVER"

  T2_OUT="$(
    REPO_ROOT="$REPO_ROOT" \
    DRIVER_TMP_DIR="$T2_DRIVER_DIR" \
    AGENT_ID="$T2_AGENT_ID" \
    AGENT_HOME_DIR="$T2_HOME_DIR" \
    SCAFFOLD_ISOLATION_MODE="linux-user" \
    SCAFFOLD_OS_USER="$T2_OS_USER" \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
    BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
    BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
    BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
    BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
    BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_DATA_ROOT="$T2_DATA_ROOT" \
    BRIDGE_SHARED_ROOT="$T2_DATA_ROOT/shared" \
    BRIDGE_AGENT_ROOT_V2="$T2_V2_ROOT" \
    BRIDGE_CONTROLLER_STATE_ROOT="$T2_DATA_ROOT/state" \
    BRIDGE_RUNTIME_ROOT="$BRIDGE_RUNTIME_ROOT" \
    BRIDGE_HOOKS_DIR="$BRIDGE_HOOKS_DIR" \
    BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
    "$BRIDGE_BASH" "$T2_DRIVER" 2>&1
  )"
  T2_RC=$?

  if [[ $T2_RC -ne 0 ]]; then
    smoke_fail "T2 driver exited rc=$T2_RC. output:
$T2_OUT"
  fi

  T2_HOME_STATUS="$(extract_line "$T2_OUT" "HOME_DIR_STATUS")"
  T2_SIBLING_STATUS="$(extract_line "$T2_OUT" "SIBLING_WORKDIR_STATUS")"
  T2_RESOLVER_MATCH="$(extract_line "$T2_OUT" "RESOLVER_MATCH")"
  T2_RESOLVED="$(printf '%s\n' "$T2_OUT" | awk '/^RESOLVER_OUTPUT:/{getline; sub(/^  /,""); print; exit}')"

  smoke_assert_eq "dir" "$T2_HOME_STATUS" "T2: isolated branch created home/ directory (sudo-handoff path)"
  smoke_assert_eq "dir" "$T2_SIBLING_STATUS" "T2: isolated branch created workdir/ sibling (issue #686 fix, sudo-handoff branch)"
  if [[ "$T2_RESOLVER_MATCH" != "yes" ]]; then
    smoke_fail "T2: bridge_agent_workdir returns the sudo-materialized workdir/ (linux-user → v2 anchor branch): expected RESOLVER_MATCH=yes, got '$T2_RESOLVER_MATCH'. resolved='$T2_RESOLVED' expected_sibling='$T2_V2_ROOT/$T2_AGENT_ID/workdir'"
  fi

  smoke_log "T2 PASS — isolated branch + resolver agreement verified"
fi

smoke_log "all tests PASS — issue #686 fix verified at current main (both scaffold branches)"
