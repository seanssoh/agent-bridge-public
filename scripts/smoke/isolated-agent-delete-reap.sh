#!/usr/bin/env bash
# scripts/smoke/isolated-agent-delete-reap.sh — issue #1010.
#
# `agent delete` on an isolated (linux-user) agent must reap the dedicated
# OS user `agent-bridge-<name>` and strip its named-user traversal ACEs
# from the controller credential ancestor set. Before the fix, those
# orphan accounts + stale `user:agent-bridge-*:--x` ACEs accumulated on
# the host on every isolated create/delete cycle.
#
# This smoke exercises the *decision logic* of
# `bridge_isolation_v2_reap_isolated_agent_account` — it cannot create or
# delete real OS users in CI, so the destructive commands (`userdel`,
# `groupdel`, `setfacl`) are shimmed as bash functions that record the
# argv they were asked to run. The test then asserts WHICH commands the
# helper decided to invoke given the engine / platform / name inputs.
#
# Cases:
#   C1. Non-Linux host — the helper must skip entirely (no userdel /
#       setfacl / groupdel attempted).
#   C2. Linux + exact-name match — the helper must attempt userdel on the
#       exact `agent-bridge-<name>` user, strip the named-user ACE from
#       each ancestor that carries it, and groupdel the per-agent group.
#   C3. Naming gate — a resolved OS user that does NOT exactly match
#       `agent-bridge-<name>` must NOT trigger userdel; the helper must
#       skip + warn instead (never touch a non-bridge account).
#   C4. Empty OS user (agent was never isolated) — silent no-op.
#
# The fully destructive path (a real userdel against a live isolated
# agent) can only be verified on a live Linux host — see the PR's
# "Manual verification needed" section.

set -euo pipefail

SMOKE_NAME="isolated-agent-delete-reap"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Run the helper in a fully isolated subshell with the OS commands shimmed.
# Args: <uname> <agent> <os_user> <ancestor-with-ace> <ace-present:yes|no>
# Prints, one per line, a decision trace the caller can grep:
#   USERDEL <user>
#   SETFACL -x <u:user> <path>
#   GROUPDEL <group>
#   WARN <text>
run_reap_probe() {
  local fake_uname="$1"
  local agent="$2"
  local os_user="$3"
  local ace_dir="$4"
  local ace_present="$5"

  bash <<PROBE
set -uo pipefail

# --- shims: record decisions instead of mutating the host ---------------
uname() { printf '%s\n' "${fake_uname}"; }
userdel() { printf 'USERDEL %s\n' "\$*"; return 0; }
groupdel() { printf 'GROUPDEL %s\n' "\$*"; return 0; }
setfacl() { printf 'SETFACL %s\n' "\$*"; return 0; }
# getent: passwd <user> resolves only the exact probe user; group <grp>
# resolves only the exact per-agent group. Everything else is "absent".
getent() {
  case "\$1" in
    passwd)
      [[ "\$2" == "${os_user}" && -n "${os_user}" ]] && { printf '%s:x:9999:9999::/home/%s:/bin/bash\n' "\$2" "\$2"; return 0; }
      return 2
      ;;
    group)
      [[ "\$2" == "ab-agent-${agent}" ]] && { printf '%s:x:9999:\n' "\$2"; return 0; }
      return 2
      ;;
  esac
  return 2
}
# getfacl: report the named-user ACE only on the designated ancestor dir.
getfacl() {
  shift  # drop -p
  if [[ "\$1" == "${ace_dir}" && "${ace_present}" == "yes" && -n "${os_user}" ]]; then
    printf 'user:${os_user}:--x\n'
  fi
  return 0
}
command() {
  # Make the helper believe userdel/groupdel/setfacl/getfacl exist.
  if [[ "\$1" == "-v" ]]; then
    case "\$2" in
      userdel|groupdel|setfacl|getfacl) printf '%s\n' "\$2"; return 0 ;;
    esac
  fi
  builtin command "\$@"
}
bridge_warn() { printf 'WARN %s\n' "\$*" >&2; }
bridge_die()  { printf 'DIE %s\n' "\$*" >&2; exit 1; }

# The helper walks credential ancestors of \$HOME/.claude/.credentials.json.
# Point HOME at the temp dir whose tree contains the designated ace_dir so
# _bridge_isolation_v2_cred_ancestors yields it.
export HOME="${SMOKE_TMP_ROOT}/ctrlhome"
export SUDO_USER="" USER="probe" LOGNAME="probe"

source "${SMOKE_REPO_ROOT}/lib/bridge-isolation-v2.sh"

bridge_isolation_v2_reap_isolated_agent_account "${agent}" "${os_user}" 2>&1
PROBE
}

# Build a controller-home tree whose .claude ancestor chain contains a
# directory we can flag as carrying the stale ACE.
setup_ctrl_home() {
  mkdir -p "$SMOKE_TMP_ROOT/ctrlhome/.claude"
  : >"$SMOKE_TMP_ROOT/ctrlhome/.claude/.credentials.json"
}

# ---------------------------------------------------------------------------
# C1 — non-Linux: helper is a complete no-op.
# ---------------------------------------------------------------------------
test_non_linux_skips() {
  setup_ctrl_home
  local out
  out="$(run_reap_probe "Darwin" "bob" "agent-bridge-bob" \
    "$SMOKE_TMP_ROOT/ctrlhome/.claude" "yes")"

  smoke_assert_not_contains "$out" "USERDEL" \
    "C1: no userdel attempted on non-Linux host"
  smoke_assert_not_contains "$out" "SETFACL" \
    "C1: no setfacl attempted on non-Linux host"
  smoke_assert_not_contains "$out" "GROUPDEL" \
    "C1: no groupdel attempted on non-Linux host"
}

# ---------------------------------------------------------------------------
# C2 — Linux + exact name match: full reap (userdel + setfacl -x + groupdel).
# ---------------------------------------------------------------------------
test_linux_exact_match_reaps() {
  setup_ctrl_home
  local out
  out="$(run_reap_probe "Linux" "bob" "agent-bridge-bob" \
    "$SMOKE_TMP_ROOT/ctrlhome/.claude" "yes")"

  smoke_assert_contains "$out" "USERDEL agent-bridge-bob" \
    "C2: userdel attempted on the exact agent-bridge-<name> user"
  smoke_assert_contains "$out" "SETFACL -x u:agent-bridge-bob" \
    "C2: named-user traversal ACE stripped from the ancestor carrying it"
  smoke_assert_contains "$out" "GROUPDEL ab-agent-bob" \
    "C2: per-agent group dropped"
}

# ---------------------------------------------------------------------------
# C3 — naming gate: a non-matching resolved user must NOT be userdel'd.
# ---------------------------------------------------------------------------
test_naming_gate_blocks_mismatch() {
  setup_ctrl_home
  # The agent being deleted is `bob`, but the roster resolved a user that
  # is NOT `agent-bridge-bob` — e.g. a hand-edited / stale roster value.
  local out
  out="$(run_reap_probe "Linux" "bob" "operator" \
    "$SMOKE_TMP_ROOT/ctrlhome/.claude" "yes")"

  smoke_assert_not_contains "$out" "USERDEL" \
    "C3: userdel NOT attempted when resolved user != agent-bridge-<name>"
  smoke_assert_not_contains "$out" "SETFACL" \
    "C3: setfacl NOT attempted for a non-matching user"
  smoke_assert_not_contains "$out" "GROUPDEL" \
    "C3: groupdel NOT attempted for a non-matching user"
  smoke_assert_contains "$out" "WARN" \
    "C3: mismatch is reported visibly via bridge_warn"
}

# ---------------------------------------------------------------------------
# C4 — empty OS user (agent was never isolated): silent no-op.
# ---------------------------------------------------------------------------
test_empty_os_user_noop() {
  setup_ctrl_home
  local out
  out="$(run_reap_probe "Linux" "bob" "" \
    "$SMOKE_TMP_ROOT/ctrlhome/.claude" "no")"

  smoke_assert_not_contains "$out" "USERDEL" \
    "C4: no userdel when OS user is empty"
  smoke_assert_not_contains "$out" "SETFACL" \
    "C4: no setfacl when OS user is empty"
  smoke_assert_not_contains "$out" "GROUPDEL" \
    "C4: no groupdel when OS user is empty"
  smoke_assert_not_contains "$out" "WARN" \
    "C4: empty OS user is a clean silent no-op (no warnings)"
}

main() {
  smoke_require_cmd bash
  smoke_make_temp_root "isolated-agent-delete-reap"
  trap smoke_cleanup_temp_root EXIT

  smoke_run "C1 non-Linux host: reap helper is a complete no-op" \
    test_non_linux_skips
  smoke_run "C2 Linux + exact agent-bridge-<name> match: full reap" \
    test_linux_exact_match_reaps
  smoke_run "C3 naming gate: non-matching resolved user is not touched" \
    test_naming_gate_blocks_mismatch
  smoke_run "C4 empty OS user (never isolated): silent no-op" \
    test_empty_os_user_noop

  smoke_log "passed"
}

main "$@"
