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
#   T1 — non-isolated v2 scaffold (`bridge-agent.sh:547-550`) creates
#        BOTH `home/` and `workdir/` siblings under
#        `$BRIDGE_AGENT_ROOT_V2/<agent>/` via plain `mkdir -p`.
#   T2 — resolver agreement: `bridge_agent_workdir <agent>` returns the
#        same `<agent-root>/workdir` path that T1's scaffold materialized,
#        and that path is a directory on disk (= no `workdir가 없습니다`).
#   T3 — isolated v2 scaffold (`bridge-agent.sh:536-542`) creates the same
#        `home/` + `workdir/` sibling pair via the `bridge_linux_sudo_root
#        mkdir` path that the linux-user isolation branch uses on a fresh
#        install where `data/agents/` is `root:root mode 755`. Gated on
#        Linux + passwordless sudo + non-root caller; skips cleanly on
#        macOS / no-sudo / root with a labeled smoke_log message. Required
#        because the isolated branch is structurally separate code — a
#        future refactor could break it independently of T1/T2.
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
# Regression bite: this smoke FAILS if the `if [[ -n "$_scaffold_v2_workdir" ]];
# then mkdir -p ...; fi` block is reverted in EITHER scaffold branch —
# T1 fails if `bridge-agent.sh:548-550` (non-isolated) regresses, T3
# (when its gate is met) fails if `bridge-agent.sh:536-542` (isolated)
# regresses.

set -uo pipefail

SMOKE_NAME="v2-scaffold-home-and-workdir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# T3 creates root-owned dirs via sudo; the default rm in
# `smoke_cleanup_temp_root` can fail on those without escalation. Wrap
# cleanup so the sudo-created tree is reaped before the controller-owned
# rm runs.
cleanup() {
  if [[ -n "${T3_SUDO_CLEANUP_ROOT:-}" && -d "$T3_SUDO_CLEANUP_ROOT" ]]; then
    sudo -n rm -rf "$T3_SUDO_CLEANUP_ROOT" >/dev/null 2>&1 || true
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
#      385..613) + its small `bridge_agent_manage_python` /
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
    '  sed -n "385,613p" "$REPO_ROOT/bridge-agent.sh"' \
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

# --- T1 + T2: non-isolated v2 — both home/ and workdir/ created --------------

smoke_log "T1+T2: non-isolated v2 scaffold materializes BOTH home/ and workdir/"

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
T1_RESOLVER_MATCH="$(extract_line "$T1_OUT" "RESOLVER_MATCH")"
T1_RESOLVED="$(printf '%s\n' "$T1_OUT" | awk '/^RESOLVER_OUTPUT:/{getline; sub(/^  /,""); print; exit}')"

smoke_assert_eq "dir" "$T1_HOME_STATUS" "T1: home/ directory was created"
smoke_assert_eq "dir" "$T1_SIBLING_STATUS" "T1: workdir/ sibling was created (issue #686 fix, non-isolated branch)"
smoke_assert_eq "yes" "$T1_RESOLVER_MATCH" "T2: bridge_agent_workdir resolved to the sibling workdir/ that scaffold materialized"
# Belt-and-suspenders: the resolver output is exactly the path we expect.
smoke_assert_eq "$BRIDGE_AGENT_ROOT_V2/$T1_AGENT_ID/workdir" "$T1_RESOLVED" \
  "T2: resolver returns canonical v2 path (\$BRIDGE_AGENT_ROOT_V2/<agent>/workdir)"

smoke_log "T1+T2 PASS — non-isolated branch verified"

# --- T3: isolated (linux-user) v2 — sudo-mediated branch ---------------------
#
# The isolated scaffold path at `bridge-agent.sh:470-545` is gated on
# `uname -s == Linux` + sudo + the linux-user predicate. On a fresh
# install, `data/agents/` is `root:root mode 755` so the plain `mkdir -p
# "$home"` fails with `Permission denied`; the sudo-handoff block runs
# the per-agent root + `home/` + `workdir/` mkdirs as root with controller
# ownership instead. T3 exercises that branch end-to-end on Linux CI.
#
# Skip cleanly when the gate cannot be satisfied — the smoke runs on
# macOS dev hosts too and must not require interactive sudo there.

smoke_log "T3: isolated linux-user v2 scaffold also materializes home/ and workdir/ (sudo-handoff branch)"

T3_SKIP_REASON=""
if [[ "$(uname -s 2>/dev/null || printf 'unknown')" != "Linux" ]]; then
  T3_SKIP_REASON="requires Linux (isolated scaffold branch is uname-gated to Linux)"
elif ! command -v sudo >/dev/null 2>&1; then
  T3_SKIP_REASON="requires sudo (isolated branch uses bridge_linux_sudo_root)"
elif ! sudo -n true 2>/dev/null; then
  T3_SKIP_REASON="requires passwordless sudo (cannot mkdir/chown/chmod as root non-interactively)"
elif [[ "$(id -u)" == "0" ]]; then
  # Running as root would short-circuit `bridge_linux_sudo_root` (it just
  # runs the command directly when uid=0), so the test wouldn't actually
  # exercise the sudo-handoff codepath. Skip rather than produce a false
  # green.
  T3_SKIP_REASON="refusing to run as root (would bypass the sudo-handoff codepath)"
fi

if [[ -n "$T3_SKIP_REASON" ]]; then
  smoke_log "T3 SKIP: $T3_SKIP_REASON"
else
  T3_DRIVER_DIR="$SMOKE_TMP_ROOT/t3"
  mkdir -p "$T3_DRIVER_DIR"
  T3_DRIVER="$T3_DRIVER_DIR/driver.sh"
  # Use a dedicated v2 root for T3 so we never collide with T1's tree and
  # so cleanup can sudo-rm one well-known subtree. The directory is created
  # in a temp location the smoke owns; the sudo-handoff inside scaffold
  # will mkdir its per-agent subdir as root.
  T3_V2_ROOT="$SMOKE_TMP_ROOT/t3-v2-agents"
  T3_DATA_ROOT="$SMOKE_TMP_ROOT/t3-v2-data"
  mkdir -p "$T3_V2_ROOT" "$T3_DATA_ROOT/shared" "$T3_DATA_ROOT/state"
  # Replicate the "fresh install" pre-state: agents/ is root:root mode 755
  # so the controller cannot mkdir into it directly. This is the exact
  # condition the isolated scaffold branch was written to recover from
  # (PR #677 / #688). Without this, the controller's plain `mkdir -p $home`
  # at bridge-agent.sh:547 would race ahead of the sudo block and the
  # isolated branch's mkdirs would no-op against a pre-existing dir.
  sudo -n chown root:root "$T3_V2_ROOT" >/dev/null 2>&1 \
    || smoke_fail "T3 fixture setup: sudo chown root:root $T3_V2_ROOT failed"
  sudo -n chmod 0755 "$T3_V2_ROOT" >/dev/null 2>&1 \
    || smoke_fail "T3 fixture setup: sudo chmod 0755 $T3_V2_ROOT failed"
  # Register the root-owned tree for cleanup so the EXIT trap can sudo-rm
  # it before `smoke_cleanup_temp_root` tries (and fails) to rm it
  # unprivileged.
  T3_SUDO_CLEANUP_ROOT="$T3_V2_ROOT"

  T3_AGENT_ID="probe_iso"   # underscore-form matches the linux-user policy regex
  T3_HOME_DIR="$T3_V2_ROOT/$T3_AGENT_ID/home"
  # `os_user` just needs to be non-empty for `_scaffold_isolation_active=1`;
  # the scaffold's sudo path does not invoke `sudo -u <os_user>` at all —
  # it only uses sudo-as-root for the mkdir/chown/chmod sequence. Use the
  # controller's own login name to keep the value real and avoid creating
  # a system-user dependency.
  T3_OS_USER="$(id -un)"

  write_driver_script "$T3_DRIVER"

  T3_OUT="$(
    REPO_ROOT="$REPO_ROOT" \
    DRIVER_TMP_DIR="$T3_DRIVER_DIR" \
    AGENT_ID="$T3_AGENT_ID" \
    AGENT_HOME_DIR="$T3_HOME_DIR" \
    SCAFFOLD_ISOLATION_MODE="linux-user" \
    SCAFFOLD_OS_USER="$T3_OS_USER" \
    BRIDGE_HOME="$BRIDGE_HOME" \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
    BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
    BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
    BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
    BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
    BRIDGE_AGENT_HOME_ROOT="$BRIDGE_AGENT_HOME_ROOT" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_DATA_ROOT="$T3_DATA_ROOT" \
    BRIDGE_SHARED_ROOT="$T3_DATA_ROOT/shared" \
    BRIDGE_AGENT_ROOT_V2="$T3_V2_ROOT" \
    BRIDGE_CONTROLLER_STATE_ROOT="$T3_DATA_ROOT/state" \
    BRIDGE_RUNTIME_ROOT="$BRIDGE_RUNTIME_ROOT" \
    BRIDGE_HOOKS_DIR="$BRIDGE_HOOKS_DIR" \
    BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
    "$BRIDGE_BASH" "$T3_DRIVER" 2>&1
  )"
  T3_RC=$?

  if [[ $T3_RC -ne 0 ]]; then
    smoke_fail "T3 driver exited rc=$T3_RC. output:
$T3_OUT"
  fi

  T3_HOME_STATUS="$(extract_line "$T3_OUT" "HOME_DIR_STATUS")"
  T3_SIBLING_STATUS="$(extract_line "$T3_OUT" "SIBLING_WORKDIR_STATUS")"
  T3_RESOLVER_MATCH="$(extract_line "$T3_OUT" "RESOLVER_MATCH")"

  smoke_assert_eq "dir" "$T3_HOME_STATUS" "T3: isolated branch created home/ directory (sudo-handoff path)"
  smoke_assert_eq "dir" "$T3_SIBLING_STATUS" "T3: isolated branch created workdir/ sibling (issue #686 fix, sudo-handoff branch)"
  smoke_assert_eq "yes" "$T3_RESOLVER_MATCH" "T3: resolver returns the sudo-materialized workdir/"

  smoke_log "T3 PASS — isolated branch verified"
fi

smoke_log "all tests PASS — issue #686 fix verified at current main (both scaffold branches)"
