#!/usr/bin/env bash
# scripts/smoke/1121-agent-delete-os-purge.sh — issue #1121.
#
# `agent delete` on an isolated (linux-user) agent must also reap the
# per-agent sudoers drop-in at `${sudoers_dir}/agent-bridge-<os_user>`
# alongside the userdel/groupdel/setfacl reap added by #1010. Before
# this fix the sudoers entry leaked on every isolated create/delete
# cycle.
#
# This smoke exercises the *decision logic* of the Step-4 sudoers
# cleanup that is now part of `bridge_isolation_v2_reap_isolated_agent_account`
# — same shim-record approach as scripts/smoke/isolated-agent-delete-reap.sh:
# `userdel`/`groupdel`/`setfacl`/`rm` are replaced by bash functions that
# record argv. The sudoers root directory is redirected to the smoke
# tempdir via the production override `BRIDGE_TEST_SUDOERS_DIR_OVERRIDE` (which
# production code never sets — its sole consumer is this smoke).
#
# Cases:
#   C1. Non-Linux host — the helper must skip Step 4 entirely
#       (sudoers cleanup never triggers on macOS / non-Linux).
#   C2. Linux + exact-name match + sudoers file exists — the helper
#       must rm exactly the matching `${BRIDGE_TEST_SUDOERS_DIR_OVERRIDE}/agent-bridge-<os_user>`
#       drop-in (defence-in-depth path-pattern gate accepts this shape).
#   C3. Sudoers file does NOT exist on the host — Step 4 is a clean
#       silent no-op (no rm, no warning row).
#   C4. Naming gate (Gate 2) blocks a non-matching os_user — Step 4 is
#       never reached (same gate that blocks userdel/groupdel).
#   C5. Negative test — when sudo / direct `rm -f` cannot remove the
#       sudoers file, the helper emits a structured warning row and
#       returns 0 (does not abort the delete).
#   C6. Long agent name — sudoers path uses the 32-char-truncated
#       generated os_user, not a raw concatenation.
#
# The fully destructive path (a real rm against `/etc/sudoers.d/`) can
# only be verified on a live Linux host with root or passwordless sudo —
# see the PR's "Manual verification needed" section.

set -euo pipefail

SMOKE_NAME="1121-agent-delete-os-purge"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Run the helper in a fully isolated subshell with destructive OS commands
# shimmed. Args:
#   $1 — fake `uname -s` value
#   $2 — agent name
#   $3 — resolved os_user (what the roster gave us)
#   $4 — sudoers file existence on the fake host ("present" | "absent")
#   $5 — rm failure mode ("ok" | "fail")
#
# Prints, one per line, a decision trace the caller can grep:
#   USERDEL <user>
#   SETFACL -x <u:user> <path>
#   GROUPDEL <group>
#   RM_F <path>
#   WARN <text>
run_reap_probe() {
  local fake_uname="$1"
  local agent="$2"
  local os_user="$3"
  local sudoers_state="$4"
  local rm_mode="$5"

  # Set up the smoke's faked sudoers root before forking the probe.
  local sudoers_dir="$SMOKE_TMP_ROOT/etc/sudoers.d"
  mkdir -p "$sudoers_dir"
  if [[ "$sudoers_state" == "present" && -n "$os_user" ]]; then
    : >"$sudoers_dir/agent-bridge-$os_user"
  else
    rm -f "$sudoers_dir/agent-bridge-$os_user"
  fi

  # Pin the controller-home tree so _bridge_isolation_v2_cred_ancestors
  # has a stable parent chain.
  mkdir -p "$SMOKE_TMP_ROOT/ctrlhome/.claude"
  : >"$SMOKE_TMP_ROOT/ctrlhome/.claude/.credentials.json"

  bash <<PROBE
set -uo pipefail

# --- shims: record decisions instead of mutating the host ---------------
uname() { printf '%s\n' "${fake_uname}"; }
userdel() { printf 'USERDEL %s\n' "\$*"; return 0; }
groupdel() { printf 'GROUPDEL %s\n' "\$*"; return 0; }
setfacl() { printf 'SETFACL %s\n' "\$*"; return 0; }
# rm: shim ONLY when called with \`-f --\` (the Step-4 sudoers rm form).
# Other rm invocations (none expected in this code path) fall through to
# the real binary so the test never silently masks an unintended rm.
rm() {
  if [[ "\${1:-}" == "-f" && "\${2:-}" == "--" ]]; then
    if [[ "${rm_mode}" == "fail" ]]; then
      printf 'RM_F_FAIL %s\n' "\$3"
      return 1
    fi
    printf 'RM_F %s\n' "\$3"
    return 0
  fi
  command rm "\$@"
}

# getent: passwd <user> resolves only the exact user the reaper was handed;
# group <grp> resolves any ab-agent-* name (so the reaper attempts the
# Step-3 groupdel — kept consistent with the #1010 probe).
getent() {
  case "\$1" in
    passwd)
      [[ "\$2" == "${os_user}" && -n "${os_user}" ]] && { printf '%s:x:9999:9999::/home/%s:/bin/bash\n' "\$2" "\$2"; return 0; }
      return 2
      ;;
    group)
      [[ "\$2" == ab-agent-* ]] && { printf '%s:x:9999:\n' "\$2"; return 0; }
      return 2
      ;;
  esac
  return 2
}
getfacl() { shift; return 0; }
command() {
  if [[ "\$1" == "-v" ]]; then
    case "\$2" in
      userdel|groupdel|setfacl|getfacl|bridge_agent_default_os_user|bridge_isolation_v2_agent_group_name)
        printf '%s\n' "\$2"; return 0 ;;
    esac
  fi
  builtin command "\$@"
}
bridge_warn() { printf 'WARN %s\n' "\$*" >&2; }
bridge_die()  { printf 'DIE %s\n' "\$*" >&2; exit 1; }
bridge_require_python() { :; }

# Stand in for bridge_agent_default_os_user (lib/bridge-agents.sh is too
# heavy to source standalone). Reuse the existing sidecar that already
# reproduces the helper verbatim — same approach as the #1010 probe.
bridge_agent_default_os_user() {
  python3 "${SMOKE_REPO_ROOT}/scripts/smoke/isolated-agent-delete-reap.py" "\$1"
}

export HOME="${SMOKE_TMP_ROOT}/ctrlhome"
export SUDO_USER="" USER="probe" LOGNAME="probe"
export BRIDGE_AGENT_GROUP_PREFIX="ab-agent-"
# Test-only override of the sudoers root — production code path uses
# /etc/sudoers.d/ when this is unset. The reaper composes the final path
# as "\${BRIDGE_TEST_SUDOERS_DIR_OVERRIDE}/agent-bridge-<os_user>".
export BRIDGE_TEST_SUDOERS_DIR_OVERRIDE="${SMOKE_TMP_ROOT}/etc/sudoers.d"

source "${SMOKE_REPO_ROOT}/lib/bridge-isolation-v2.sh"

bridge_isolation_v2_reap_isolated_agent_account "${agent}" "${os_user}" 2>&1
PROBE
}

expected_os_user() {
  python3 "$SMOKE_REPO_ROOT/scripts/smoke/isolated-agent-delete-reap.py" "$1"
}

# ---------------------------------------------------------------------------
# C1 — non-Linux: Step 4 sudoers cleanup never triggers.
# ---------------------------------------------------------------------------
test_non_linux_skips_sudoers() {
  local os_user
  os_user="$(expected_os_user "bob")"
  local out
  out="$(run_reap_probe "Darwin" "bob" "$os_user" "present" "ok")"

  smoke_assert_not_contains "$out" "RM_F" \
    "C1: no rm -f attempted on non-Linux host"
  smoke_assert_not_contains "$out" "skipping sudoers cleanup" \
    "C1: no sudoers refusal warning on non-Linux (Gate 1 exits before Step 4)"
}

# ---------------------------------------------------------------------------
# C2 — Linux + exact match + sudoers file present: rm at the exact path.
# ---------------------------------------------------------------------------
test_linux_exact_match_removes_sudoers() {
  local os_user
  os_user="$(expected_os_user "bob")"
  smoke_assert_eq "agent-bridge-bob" "$os_user" \
    "C2 pre: short name composes to the un-truncated account name"
  local out
  out="$(run_reap_probe "Linux" "bob" "$os_user" "present" "ok")"

  # Path mirrors lib/bridge-migration.sh:793 writer:
  # "${BRIDGE_TEST_SUDOERS_DIR_OVERRIDE}/agent-bridge-${os_user}". For os_user already
  # carrying the "agent-bridge-" prefix the resulting filename is
  # double-prefixed (agent-bridge-agent-bridge-bob) — by design, the
  # reaper mirrors the writer exactly so the file actually gets hit.
  smoke_assert_contains "$out" "RM_F ${SMOKE_TMP_ROOT}/etc/sudoers.d/agent-bridge-${os_user}" \
    "C2: sudoers drop-in removed at exactly \${BRIDGE_TEST_SUDOERS_DIR_OVERRIDE}/agent-bridge-<os_user>"
  smoke_assert_not_contains "$out" "refusing to rm" \
    "C2: strict pattern gate accepts the canonical agent-bridge-<slug> shape"
}

# ---------------------------------------------------------------------------
# C3 — sudoers file does NOT exist: Step 4 is a clean silent no-op.
# ---------------------------------------------------------------------------
test_missing_sudoers_silent_noop() {
  local os_user
  os_user="$(expected_os_user "bob")"
  local out
  out="$(run_reap_probe "Linux" "bob" "$os_user" "absent" "ok")"

  smoke_assert_not_contains "$out" "RM_F" \
    "C3: no rm attempted when sudoers drop-in is absent"
  smoke_assert_not_contains "$out" "failed to remove sudoers" \
    "C3: absent file produces no warning row (clean no-op)"
}

# ---------------------------------------------------------------------------
# C4 — naming gate (Gate 2) blocks a non-matching os_user: Step 4 is
# never reached.
# ---------------------------------------------------------------------------
test_naming_gate_blocks_sudoers() {
  # Agent is `bob` but the roster resolved a non-matching user. The
  # production reap returns at Gate 2 (production path).
  local out
  out="$(run_reap_probe "Linux" "bob" "operator" "present" "ok")"

  smoke_assert_not_contains "$out" "RM_F" \
    "C4: rm NOT attempted when resolved user != agent-bridge-<name>"
  smoke_assert_contains "$out" "WARN" \
    "C4: mismatch reported via bridge_warn (Gate 2)"
}

# ---------------------------------------------------------------------------
# C5 — negative test: rm -f failure (no sudo + restricted perms) emits a
# structured warning row but does NOT abort the reap (best-effort).
# ---------------------------------------------------------------------------
test_rm_failure_emits_warning_row() {
  local os_user
  os_user="$(expected_os_user "bob")"
  local out
  out="$(run_reap_probe "Linux" "bob" "$os_user" "present" "fail")"

  smoke_assert_contains "$out" "failed to remove sudoers drop-in" \
    "C5: rm failure produces a structured WARN row (best-effort delete)"
  smoke_assert_contains "$out" "WARN" \
    "C5: warning is emitted via bridge_warn (visible in audit/log)"
  # The reap function returns 0 regardless of Step 4 outcome; if the
  # probe reached Steps 1-3 the run did not abort on the Step 4 failure.
  smoke_assert_contains "$out" "USERDEL agent-bridge-bob" \
    "C5: Steps 1-3 still run (reap never aborts on Step 4 failure)"
}

# ---------------------------------------------------------------------------
# C6 — long agent name: the sudoers path is composed from the truncated
# generated account name, NOT a raw concatenation. Same class as the
# #1010 long-name case — proves a long agent name does not slip through
# Step 4 with a name that would never match a real sudoers file.
# ---------------------------------------------------------------------------
test_long_name_uses_truncated_sudoers_path() {
  local long_agent="worker-very-long-isolated-agent-name-here"
  local os_user
  os_user="$(expected_os_user "$long_agent")"
  smoke_assert_eq "agent-bridge-worker-very-long-is" "$os_user" \
    "C6 pre: long name composes to a 32-char-truncated account name"

  local out
  out="$(run_reap_probe "Linux" "$long_agent" "$os_user" "present" "ok")"

  # The Step-4 path the reap walks must use the truncated os_user.
  # Path mirrors the migrator's writer (lib/bridge-migration.sh:793),
  # which double-prefixes when os_user already carries "agent-bridge-".
  smoke_assert_contains "$out" "RM_F ${SMOKE_TMP_ROOT}/etc/sudoers.d/agent-bridge-${os_user}" \
    "C6: sudoers rm uses the truncated /etc/sudoers.d/agent-bridge-<truncated-os_user> path"
  smoke_assert_not_contains "$out" "agent-bridge-${long_agent}" \
    "C6: raw (untruncated) agent name is NEVER part of the rm argv"
}

main() {
  smoke_require_cmd bash
  smoke_require_cmd python3
  smoke_make_temp_root "1121-agent-delete-os-purge"
  trap smoke_cleanup_temp_root EXIT

  smoke_run "C1 non-Linux host: Step 4 sudoers cleanup never triggers" \
    test_non_linux_skips_sudoers
  smoke_run "C2 Linux + exact match + sudoers present: rm at exact path" \
    test_linux_exact_match_removes_sudoers
  smoke_run "C3 sudoers file absent: silent no-op" \
    test_missing_sudoers_silent_noop
  smoke_run "C4 naming gate blocks Step 4 for non-matching resolved user" \
    test_naming_gate_blocks_sudoers
  smoke_run "C5 rm failure produces structured warning, never aborts reap" \
    test_rm_failure_emits_warning_row
  smoke_run "C6 long agent name: sudoers path uses truncated identity" \
    test_long_name_uses_truncated_sudoers_path

  smoke_log "passed"
}

main "$@"
