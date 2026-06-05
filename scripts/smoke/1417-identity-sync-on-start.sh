#!/usr/bin/env bash
# Issue #1417 regression smoke — managed-project identity drift.
#
# For an admin / managed-project agent (workdir != home) `agent create`
# materializes the HOME identity files into the workdir once
# (`bridge_layout_materialize_identity`). The runtime reads workdir-first
# (`bridge_agent_onboarding_state`), so a later hand-edit of the HOME copy
# never reaches the workdir copy and silently has no effect — onboarding can
# stay stuck `pending`. This smoke proves the structural fix:
#
#   * `bridge_layout_sync_identity_from_home` re-materializes the workdir
#     identity copy FROM HOME on start — but ONLY when HOME differs AND is
#     the newer copy, and NEVER clobbers a deliberate workdir runtime value
#     or any workdir-anchored watchdog/session state.
#   * `agb agent set-onboarding <a> <state>` writes BOTH the HOME and the
#     workdir copies atomically (the previously-missing CLI verb).
#
# Asserts (all on a temp BRIDGE_HOME — operator's live tree never touched):
#   T1 — HOME edit propagates: edit the HOME SESSION-TYPE.md onboarding line
#        (newer mtime), run the sync; the WORKDIR copy now reflects the HOME
#        value and `bridge_agent_onboarding_state` returns the new value.
#   T2 — Shared mode (workdir == home, single physical copy) is a no-op: the
#        sync makes no second copy and changes nothing.
#   T3 — Deliberate-workdir-value guard: when the WORKDIR copy is strictly
#        NEWER than HOME (a runtime mutation), the sync does NOT clobber it,
#        even though the two differ. (#1108/#1109 watchdog anchor preserved.)
#   T4 — set-onboarding writes BOTH copies: `agb agent set-onboarding`
#        re-reads to the set value; no second hand-edit needed. T4b: a MISSING
#        workdir copy is re-materialized atomically (no stranded tmp).
#   T5 — Scope guard: watchdog/session runtime state in the workdir
#        (session.lock, *.result.json, memory/) is untouched by the sync.
#
# Footgun #11 (Bash 5.3.9 heredoc-stdin deadlock): the driver bodies that run
# as a subprocess are emitted to files via printf and invoked file-as-argv;
# no `<<'PY'` / `<<EOF` stdin heredocs into a subprocess anywhere.

set -uo pipefail

SMOKE_NAME="1417-identity-sync-on-start"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

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

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

AGENT="admin-mp"
ENGINE="claude"

HOME_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/home"
WORK_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/workdir"
mkdir -p "$HOME_DIR" "$WORK_DIR"

# session-type body factory: prints a SESSION-TYPE.md whose onboarding line
# carries <state>.
write_session_type() {
  local path="$1" state="$2"
  {
    printf '%s\n' '# Session Type'
    printf '%s\n' ''
    printf '%s\n' '- Session Type: static-claude'
    printf '%s\n' "- Onboarding State: $state"
    printf '%s\n' '- Engine: claude'
  } >"$path"
}

# Seed HOME (the authored SSOT) + a create-time materialized WORKDIR copy,
# both at `pending` and byte-equal (the steady post-create state).
write_session_type "$HOME_DIR/SESSION-TYPE.md" "pending"
write_session_type "$WORK_DIR/SESSION-TYPE.md" "pending"
# Also seed the other canonical identity markers so the watchdog-shaped
# read is well-formed; not central to the assertions.
for marker in SOUL.md MEMORY.md MEMORY-SCHEMA.md CLAUDE.md; do
  printf '%s\n' "$marker body" >"$HOME_DIR/$marker"
  printf '%s\n' "$marker body" >"$WORK_DIR/$marker"
done

# Seed a minimal v2 roster so bridge_load_roster / bridge_agent_workdir
# resolve the agent to its v2 workdir.
ROSTER_FILE="$BRIDGE_ROSTER_FILE"
: >"$ROSTER_FILE"
{
  printf '%s\n' '# Smoke roster — issue #1417'
  printf 'BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
  printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$AGENT"
  printf 'BRIDGE_AGENT_ENGINE["%s"]="%s"\n' "$AGENT" "$ENGINE"
  # bridge_agent_exists() (used by bridge_require_agent in the
  # set-onboarding verb) keys off BRIDGE_AGENT_SESSION — populate it so the
  # CLI surface resolves the agent. SOURCE=static marks a managed role.
  printf 'BRIDGE_AGENT_SESSION["%s"]="agb-%s"\n' "$AGENT" "$AGENT"
  printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$AGENT"
} >>"$ROSTER_FILE"

# ---------------------------------------------------------------------------
# Driver: source bridge-lib.sh + call the sync helper with an explicit target,
# exactly the way bridge-start.sh invokes it. Prints the resolved onboarding
# state after the sync.
# ---------------------------------------------------------------------------
SYNC_DRIVER="$SMOKE_TMP_ROOT/run-sync.sh"
: >"$SYNC_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'REPO_ROOT="$1"; AGENT="$2"; ENGINE="$3"; TARGET="$4"'
  printf '%s\n' '# shellcheck disable=SC1091'
  printf '%s\n' 'source "$REPO_ROOT/bridge-lib.sh"'
  printf '%s\n' 'bridge_load_roster'
  printf '%s\n' 'bridge_layout_sync_identity_from_home "$AGENT" "$ENGINE" "$TARGET" || true'
  printf '%s\n' 'printf "onboarding_state=%s\\n" "$(bridge_agent_onboarding_state "$AGENT")"'
} >"$SYNC_DRIVER"
chmod +x "$SYNC_DRIVER"

run_sync() {
  local target="$1"
  "$BRIDGE_BASH" "$SYNC_DRIVER" "$REPO_ROOT" "$AGENT" "$ENGINE" "$target" \
    2>"$SMOKE_TMP_ROOT/sync.stderr"
}

workdir_onboarding() {
  grep -E 'Onboarding State:[[:space:]]*[A-Za-z0-9._-]+' "$WORK_DIR/SESSION-TYPE.md" \
    2>/dev/null | head -n1
}

# --- T1: HOME edit propagates to the workdir copy ---------------------------

# Edit the HOME copy to `complete`, and make it strictly newer than the
# workdir copy (touch the workdir copy into the past first to be deterministic
# across filesystems with coarse mtime granularity).
touch -t 200001010000 "$WORK_DIR/SESSION-TYPE.md"
write_session_type "$HOME_DIR/SESSION-TYPE.md" "complete"

T1_OUT="$(run_sync "$WORK_DIR")" || smoke_fail "T1: sync driver exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/sync.stderr"))"
smoke_assert_contains "$(workdir_onboarding)" "complete" \
  "T1: HOME 'complete' edit did not propagate to the workdir SESSION-TYPE.md copy"
smoke_assert_contains "$T1_OUT" "onboarding_state=complete" \
  "T1: bridge_agent_onboarding_state did not return the propagated 'complete' value"

# --- T2: shared mode (workdir == home) is a no-op ---------------------------

# Pass HOME as the explicit target so source == target — the helper must
# short-circuit (single physical copy, nothing can drift).
HOME_BEFORE_HASH="$(shasum -a 256 "$HOME_DIR/SESSION-TYPE.md" 2>/dev/null | awk '{print $1}')"
run_sync "$HOME_DIR" >/dev/null || smoke_fail "T2: sync driver exited non-zero on shared-mode target"
HOME_AFTER_HASH="$(shasum -a 256 "$HOME_DIR/SESSION-TYPE.md" 2>/dev/null | awk '{print $1}')"
smoke_assert_eq "$HOME_AFTER_HASH" "$HOME_BEFORE_HASH" \
  "T2: shared-mode sync mutated the single SESSION-TYPE.md copy"

# --- T3: deliberate workdir-newer value is NOT clobbered --------------------

# The agent updated its OWN onboarding line mid-session: the workdir copy is
# now `partial` and strictly NEWER than the (older) HOME `complete` copy. The
# sync must leave the workdir value intact.
write_session_type "$HOME_DIR/SESSION-TYPE.md" "complete"
touch -t 200001010000 "$HOME_DIR/SESSION-TYPE.md"     # HOME is the OLDER copy
write_session_type "$WORK_DIR/SESSION-TYPE.md" "partial"  # workdir: fresh, newer

run_sync "$WORK_DIR" >/dev/null || smoke_fail "T3: sync driver exited non-zero"
smoke_assert_contains "$(workdir_onboarding)" "partial" \
  "T3: sync CLOBBERED a deliberate (newer) workdir runtime value with the older HOME copy"

# --- T4: set-onboarding writes BOTH copies atomically -----------------------

# Reset both copies to a known-distinct state so the verb's dual write is
# unambiguous.
write_session_type "$HOME_DIR/SESSION-TYPE.md" "pending"
write_session_type "$WORK_DIR/SESSION-TYPE.md" "pending"

SETOB_OUT="$("$BRIDGE_BASH" "$REPO_ROOT/bridge-agent.sh" set-onboarding "$AGENT" complete \
  2>"$SMOKE_TMP_ROOT/setob.stderr")" \
  || smoke_fail "T4: set-onboarding exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/setob.stderr"))"
smoke_assert_contains "$SETOB_OUT" "onboarding_state: complete" \
  "T4: set-onboarding did not report the new state"
smoke_assert_contains "$(grep 'Onboarding State' "$HOME_DIR/SESSION-TYPE.md")" "complete" \
  "T4: set-onboarding did not write the HOME copy"
smoke_assert_contains "$(workdir_onboarding)" "complete" \
  "T4: set-onboarding did not write the WORKDIR copy"

# T4b: when the WORKDIR copy is MISSING, set-onboarding re-materializes it
# from HOME (the atomic tmp+rename copy path) so both trees end byte-equal —
# no stranded partial file, no second hand-edit needed.
write_session_type "$HOME_DIR/SESSION-TYPE.md" "pending"
rm -f "$WORK_DIR/SESSION-TYPE.md"
"$BRIDGE_BASH" "$REPO_ROOT/bridge-agent.sh" set-onboarding "$AGENT" complete \
  >/dev/null 2>"$SMOKE_TMP_ROOT/setob2.stderr" \
  || smoke_fail "T4b: set-onboarding (workdir missing) exited non-zero (stderr: $(cat "$SMOKE_TMP_ROOT/setob2.stderr"))"
smoke_assert_file_exists "$WORK_DIR/SESSION-TYPE.md" \
  "T4b: set-onboarding did not re-materialize the missing WORKDIR copy"
smoke_assert_contains "$(workdir_onboarding)" "complete" \
  "T4b: re-materialized WORKDIR copy does not carry the set onboarding state"
# No stranded atomic-copy tmp sibling left behind.
LEFTOVER_TMP="$(find "$WORK_DIR" -maxdepth 1 -name '.onboarding-copy-*' 2>/dev/null | head -n1)"
smoke_assert_eq "$LEFTOVER_TMP" "" \
  "T4b: set-onboarding left a stranded atomic-copy tmp sibling: $LEFTOVER_TMP"

# --- T5: watchdog/session runtime state is untouched by the sync ------------

# Seed deliberate workdir-anchored runtime state, then drive a propagating
# sync (HOME newer SESSION-TYPE.md) and assert the runtime artifacts survive
# byte-for-byte — the sync is scoped to identity files only.
mkdir -p "$WORK_DIR/memory"
printf '%s' 'session-lock-sentinel' >"$WORK_DIR/session.lock"
printf '%s' '{"result":"sentinel"}' >"$WORK_DIR/cron.result.json"
printf '%s' 'memory-sentinel'       >"$WORK_DIR/memory/notes.md"
LOCK_BEFORE="$(shasum -a 256 "$WORK_DIR/session.lock"     2>/dev/null | awk '{print $1}')"
RES_BEFORE="$(shasum -a 256 "$WORK_DIR/cron.result.json"  2>/dev/null | awk '{print $1}')"
MEM_BEFORE="$(shasum -a 256 "$WORK_DIR/memory/notes.md"   2>/dev/null | awk '{print $1}')"

touch -t 200001010000 "$WORK_DIR/SESSION-TYPE.md"
write_session_type "$HOME_DIR/SESSION-TYPE.md" "complete"
run_sync "$WORK_DIR" >/dev/null || smoke_fail "T5: sync driver exited non-zero"

LOCK_AFTER="$(shasum -a 256 "$WORK_DIR/session.lock"     2>/dev/null | awk '{print $1}')"
RES_AFTER="$(shasum -a 256 "$WORK_DIR/cron.result.json"  2>/dev/null | awk '{print $1}')"
MEM_AFTER="$(shasum -a 256 "$WORK_DIR/memory/notes.md"   2>/dev/null | awk '{print $1}')"
smoke_assert_eq "$LOCK_AFTER" "$LOCK_BEFORE" \
  "T5: sync MUTATED the workdir session.lock (must be out of scope)"
smoke_assert_eq "$RES_AFTER" "$RES_BEFORE" \
  "T5: sync MUTATED a workdir *.result.json (must be out of scope)"
smoke_assert_eq "$MEM_AFTER" "$MEM_BEFORE" \
  "T5: sync MUTATED the workdir memory/ tree (must be out of scope)"
# And the identity file DID propagate (the sync still works while leaving
# runtime state alone).
smoke_assert_contains "$(workdir_onboarding)" "complete" \
  "T5: identity sync regressed — HOME edit did not propagate alongside the scope guard"

smoke_log "PASS: $SMOKE_NAME (T1-T5)"
