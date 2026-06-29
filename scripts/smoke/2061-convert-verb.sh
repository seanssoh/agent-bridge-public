#!/usr/bin/env bash
# scripts/smoke/2061-convert-verb.sh — FR #2061 Track B: the `agent convert
# <a> --to static` verb (run_convert) + audited roster flip + §0.1 last-flip
# transaction.
#
# Track A (2061-convert-migration) pins the pure migration engine. THIS smoke
# pins the ORCHESTRATION run_convert layers on top of it, against a fabricated
# operator ~/.claude in a fully isolated BRIDGE_HOME (no live Claude / tmux):
#
#   T1  --dry-run prints the migration manifest and mutates NOTHING (no roster
#       flip, no target files, no crash-state clear).
#   T2  a real convert flips the roster to source=static with a baked launch_cmd
#       (incl. --model) and start_policy=hold, migrates the transcript byte-equal
#       into the target config dir, clears pre-conversion crash state, and the
#       #1455 single-tree settings invariant holds.
#   T3  the convert is idempotent — a second run on the now-static agent is a
#       clean no-op success (manifest skip-if-identical).
#   T4  §0.1 ORDER — a simulated APPLY failure (target projects/ is a symlink →
#       Track A apply fails closed) leaves NO flipped roster (the flip is the
#       LAST mutation), the internal rollback ran, and a backup dir exists.
#   T5  an iso-effective target convert fails closed with rc 3 (MVP shared-mode
#       only) — the verb surfaces Track A's fail-closed exit code cleanly.
#
# NOT smoke-coverable (flagged for the orchestrator's live check): the actual
# `start` / `--resume` / channel-banner of the converted static agent (tmux +
# Claude submit semantics are not exercised here).

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:2061-convert-verb][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="2061-convert-verb"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

BASH4_BIN="${BRIDGE_BASH_BIN:-${BASH:-bash}}"
if (( BASH_VERSINFO[0] < 4 )); then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BASH4_BIN="/opt/homebrew/bin/bash"
  elif [[ -x /usr/local/bin/bash ]]; then
    BASH4_BIN="/usr/local/bin/bash"
  fi
fi

# The operator-global ~/.claude the dynamic-vanilla agent reads. Pin it via
# HOME + BRIDGE_CONTROLLER_HOME so bridge_agent_operator_home_dir resolves here.
OPERATOR_HOME="$SMOKE_TMP_ROOT/operator-home"
mkdir -p "$OPERATOR_HOME/.claude"

slug_of() { local p="$1"; p="${p//\//-}"; printf '%s' "$p"; }

# --- roster fixture --------------------------------------------------------
# Initialize the isolated roster file (mktemp BRIDGE_HOME — NOT hook-protected),
# then append a dynamic managed block per agent so the CLI loads it as a
# registered dynamic-vanilla Claude agent. The real roster flip below replaces
# the block via bridge_write_role_block (replace_existing=1).
init_roster() {
  printf '#!/usr/bin/env bash\n# shellcheck shell=bash disable=SC2034\n' > "$BRIDGE_ROSTER_LOCAL_FILE"
}
seed_dynamic_agent() {
  local agent="$1" workdir="$2" iso_mode="${3:-}" os_user="${4:-}"
  mkdir -p "$workdir/.claude"
  {
    printf '\n# BEGIN AGENT BRIDGE MANAGED ROLE: %s\n' "$agent"
    printf 'bridge_add_agent_id_if_missing %q\n' "$agent"
    printf 'BRIDGE_AGENT_DESC["%s"]=%q\n' "$agent" "$agent convert test"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$agent"
    printf 'BRIDGE_AGENT_SESSION["%s"]=%q\n' "$agent" "$agent"
    printf 'BRIDGE_AGENT_WORKDIR["%s"]=%q\n' "$agent" "$workdir"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="dynamic"\n' "$agent"
    [[ -n "$iso_mode" ]] && printf 'BRIDGE_AGENT_ISOLATION_MODE["%s"]=%q\n' "$agent" "$iso_mode"
    [[ -n "$os_user" ]]  && printf 'BRIDGE_AGENT_OS_USER["%s"]=%q\n' "$agent" "$os_user"
    printf '# END AGENT BRIDGE MANAGED ROLE: %s\n' "$agent"
  } >> "$BRIDGE_ROSTER_LOCAL_FILE"
}

# Seed a transcript + project memory under the operator ~/.claude for <agent>'s
# workdir cwd, so the migration manifest is non-empty.
seed_operator_state() {
  local workdir="$1" sid="$2"
  local sl; sl="$(slug_of "$workdir")"
  mkdir -p "$OPERATOR_HOME/.claude/projects/$sl/memory"
  printf '{"cwd":"%s","sessionId":"%s"}\n' "$workdir" "$sid" \
    > "$OPERATOR_HOME/.claude/projects/$sl/$sid.jsonl"
  printf '# MEMORY\nconverted-agent project memory\n' \
    > "$OPERATOR_HOME/.claude/projects/$sl/memory/MEMORY.md"
}

# Invoke the real verb with the operator HOME pinned.
convert_cli() {
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    "$BASH4_BIN" "$REPO_ROOT/bridge-agent.sh" convert "$@"
}

# Resolve a roster-derived path via a one-shot bridge-lib eval (keeps the smoke
# main process free of bridge side effects).
lib_eval() {
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
    "$BASH4_BIN" -c "source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1; $1"
}

roster_has() { grep -Fq "$1" "$BRIDGE_ROSTER_LOCAL_FILE"; }

# ===========================================================================
# T1 — --dry-run prints the manifest and mutates NOTHING.
# ===========================================================================
test_t1_dry_run_no_mutation() {
  init_roster
  local agent="dryrun" workdir="$SMOKE_TMP_ROOT/dryrun-wd"
  seed_dynamic_agent "$agent" "$workdir"
  seed_operator_state "$workdir" "sidD"
  local target="$BRIDGE_AGENT_ROOT_V2/$agent/home/.claude"
  local roster_before; roster_before="$(shasum "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}')"

  local out
  out="$(convert_cli "$agent" --to static --dry-run --json)" \
    || smoke_fail "T1: dry-run convert exited non-zero: $out"

  # The output is the manifest JSON and names the transcript.
  printf '%s' "$out" | python3 -c '
import json, sys
m = json.load(sys.stdin)
assert m["total_files"] >= 1, "dry-run manifest is empty"
names = [f["dest"].split("/")[-1] for f in m["files"]]
assert "sidD.jsonl" in names, "transcript missing from dry-run manifest: %r" % names
' || smoke_fail "T1: dry-run did not print a complete manifest"

  # Zero mutation: roster unchanged, no static flip, no target tree, no flip.
  local roster_after; roster_after="$(shasum "$BRIDGE_ROSTER_LOCAL_FILE" | awk '{print $1}')"
  smoke_assert_eq "$roster_before" "$roster_after" "T1: dry-run mutated the roster file"
  if roster_has 'BRIDGE_AGENT_SOURCE["dryrun"]="static"'; then
    smoke_fail "T1: dry-run flipped the roster to static"
  fi
  [[ ! -d "$target" ]] || [[ -z "$(find "$target" -type f 2>/dev/null)" ]] \
    || smoke_fail "T1: dry-run wrote files into the target config dir"
  smoke_log "T1 OK — --dry-run printed the manifest and mutated nothing"
}

# ===========================================================================
# T2 — real convert: roster flip + baked launch_cmd + start_policy=hold +
# byte-equal migration + crash-state cleared + #1455 invariant.
# ===========================================================================
test_t2_convert_apply() {
  init_roster
  local agent="tester" workdir="$SMOKE_TMP_ROOT/tester-wd"
  seed_dynamic_agent "$agent" "$workdir"
  seed_operator_state "$workdir" "sid1"
  local sl; sl="$(slug_of "$workdir")"
  local target="$BRIDGE_AGENT_ROOT_V2/$agent/home/.claude"

  # Pre-seed a pre-conversion crash report so we can prove §0.2 clears it.
  local crash_file
  crash_file="$(lib_eval "bridge_agent_crash_report_file $agent")"
  [[ -n "$crash_file" ]] || smoke_fail "T2: could not resolve the crash report path"
  mkdir -p "$(dirname "$crash_file")"
  printf 'CRASH_REPORTED_AT=stale\n' > "$crash_file"

  local out
  out="$(convert_cli "$agent" --to static --model claude-opus-4 \
          --discord 'plugin:discord@claude-plugins-official' --channel 123456789012345678)" \
    || smoke_fail "T2: convert exited non-zero: $out"

  # Roster flip shape.
  roster_has 'BRIDGE_AGENT_SOURCE["tester"]="static"' \
    || smoke_fail "T2: roster was not flipped to source=static"
  roster_has 'BRIDGE_AGENT_START_POLICY["tester"]="hold"' \
    || smoke_fail "T2: start_policy=hold was not baked into the roster"
  local launch_line
  launch_line="$(grep -F 'BRIDGE_AGENT_LAUNCH_CMD["tester"]=' "$BRIDGE_ROSTER_LOCAL_FILE" || true)"
  [[ -n "$launch_line" ]] || smoke_fail "T2: no baked launch_cmd in the roster"
  case "$launch_line" in
    *claude*) : ;;
    *) smoke_fail "T2: baked launch_cmd is not a claude launch: $launch_line";;
  esac
  case "$launch_line" in
    *"--model claude-opus-4"*) : ;;
    *) smoke_fail "T2: baked launch_cmd missing the --model bake: $launch_line";;
  esac

  # Migration: the transcript landed byte-equal under the target config dir.
  smoke_assert_file_exists "$target/projects/$sl/sid1.jsonl" \
    "T2: transcript not migrated into the target config dir"
  cmp -s "$OPERATOR_HOME/.claude/projects/$sl/sid1.jsonl" "$target/projects/$sl/sid1.jsonl" \
    || smoke_fail "T2: migrated transcript is not byte-equal to the source"
  # Source untouched (copy-not-move).
  smoke_assert_file_exists "$OPERATOR_HOME/.claude/projects/$sl/sid1.jsonl" \
    "T2: source transcript was removed (must be copy, not move)"

  # §0.2: pre-conversion crash state cleared.
  [[ ! -f "$crash_file" ]] || smoke_fail "T2: pre-conversion crash report was not cleared"

  # #1455 single-tree invariant: workdir settings.json resolves to the per-agent
  # home settings.effective.json.
  local eff
  eff="$(lib_eval "bridge_hook_per_agent_settings_effective_file $agent")"
  python3 -c '
import os, sys
wd, eff = sys.argv[1], sys.argv[2]
assert os.path.exists(wd), "workdir settings.json missing: " + wd
assert os.path.exists(eff), "home settings.effective.json missing: " + eff
assert os.path.realpath(wd) == os.path.realpath(eff), "two-tree drift: %s != %s" % (os.path.realpath(wd), os.path.realpath(eff))
' "$workdir/.claude/settings.json" "$eff" \
    || smoke_fail "T2: #1455 single-tree settings invariant did not hold"
  smoke_log "T2 OK — roster flipped static + baked launch_cmd + hold; migration byte-equal; crash cleared; #1455 held"
}

# ===========================================================================
# T3 — idempotent re-run on the now-static agent is a clean no-op success.
# ===========================================================================
test_t3_idempotent() {
  local agent="tester" workdir="$SMOKE_TMP_ROOT/tester-wd"
  local out
  out="$(convert_cli "$agent" --to static --model claude-opus-4)" \
    || smoke_fail "T3: idempotent re-run exited non-zero: $out"
  roster_has 'BRIDGE_AGENT_SOURCE["tester"]="static"' \
    || smoke_fail "T3: re-run did not preserve source=static"
  roster_has 'BRIDGE_AGENT_START_POLICY["tester"]="hold"' \
    || smoke_fail "T3: re-run did not preserve start_policy=hold"
  # Exactly one managed block for the agent (no duplicate appended).
  local n
  n="$(grep -c '# BEGIN AGENT BRIDGE MANAGED ROLE: tester' "$BRIDGE_ROSTER_LOCAL_FILE" || true)"
  smoke_assert_eq "1" "$n" "T3: re-run duplicated the managed role block"
  smoke_log "T3 OK — re-running convert on a static agent is a clean idempotent no-op"
}

# ===========================================================================
# T4 — §0.1 ORDER: a simulated apply failure leaves NO flipped roster (the flip
# is the LAST mutation), the internal rollback ran, a backup dir exists.
# ===========================================================================
test_t4_apply_failure_no_flip() {
  init_roster
  local agent="failer" workdir="$SMOKE_TMP_ROOT/failer-wd"
  seed_dynamic_agent "$agent" "$workdir"
  seed_operator_state "$workdir" "sidF"
  local home_claude="$BRIDGE_AGENT_ROOT_V2/$agent/home/.claude"

  # Force the Track A apply (§0.1 step 5) to fail closed: make the target's
  # projects/ a symlink to an outside dir (real .claude, real settings — so the
  # materialize + #1455 invariant at step 4 pass; only the migration copy
  # rejects on dest_is_safe symlink traversal). This is strictly later than the
  # roster flip would NOT have happened: the flip is step 7.
  local escape="$SMOKE_TMP_ROOT/failer-escape"
  mkdir -p "$home_claude" "$escape"
  ln -s "$escape" "$home_claude/projects"

  local rc=0
  convert_cli "$agent" --to static >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || smoke_fail "T4: convert succeeded despite a forced apply failure"

  # The roster was NEVER flipped — the seeded dynamic block survives intact.
  roster_has 'BRIDGE_AGENT_SOURCE["failer"]="dynamic"' \
    || smoke_fail "T4: the dynamic roster block was lost on a failed convert"
  if roster_has 'BRIDGE_AGENT_SOURCE["failer"]="static"'; then
    smoke_fail "T4: roster was flipped to static despite the apply failure (NOT last-flip)"
  fi
  if roster_has 'BRIDGE_AGENT_START_POLICY["failer"]='; then
    smoke_fail "T4: a static start_policy line was written despite the failure"
  fi

  # The internal rollback ran: a backup dir was created by the attempted apply
  # (apply persists the WAL before copying), and nothing escaped the symlink.
  [[ -d "$BRIDGE_STATE_DIR/convert-backups/failer" ]] \
    && [[ -n "$(find "$BRIDGE_STATE_DIR/convert-backups/failer" -name apply-journal.jsonl 2>/dev/null)" ]] \
    || smoke_fail "T4: no backup dir / WAL from the attempted apply (rollback evidence missing)"
  [[ -z "$(find "$escape" -type f 2>/dev/null)" ]] \
    || smoke_fail "T4: data escaped through the projects/ symlink (traversal)"
  smoke_log "T4 OK — apply failure left NO flipped roster (flip is last); rollback ran; no traversal escape"
}

# ===========================================================================
# T5 — iso-effective target convert fails closed with rc 3 (MVP shared only).
# ===========================================================================
test_t5_iso_fail_closed() {
  init_roster
  local agent="isov" workdir="$SMOKE_TMP_ROOT/isov-wd"
  seed_dynamic_agent "$agent" "$workdir" "linux-user" "agent-bridge-isov"

  local rc=0
  HOME="$OPERATOR_HOME" BRIDGE_CONTROLLER_HOME="$OPERATOR_HOME" \
  BRIDGE_HOST_PLATFORM_OVERRIDE="Linux" \
    "$BASH4_BIN" -c "unset BRIDGE_DISABLE_ISOLATION; exec '$REPO_ROOT/bridge-agent.sh' convert '$agent' --to static" \
    >/dev/null 2>&1 || rc=$?
  smoke_assert_eq "3" "$rc" \
    "T5: iso-effective target convert must FAIL CLOSED with rc 3 (MVP shared-mode only)"
  if roster_has 'BRIDGE_AGENT_SOURCE["isov"]="static"'; then
    smoke_fail "T5: iso convert flipped the roster despite failing closed"
  fi
  smoke_log "T5 OK — iso-effective target convert fails closed (rc 3); no roster flip"
}

# --- run -------------------------------------------------------------------
smoke_run "T1 --dry-run prints manifest + mutates nothing" test_t1_dry_run_no_mutation
smoke_run "T2 convert flips roster static + migrates + clears crash + #1455" test_t2_convert_apply
smoke_run "T3 idempotent re-run is a clean no-op" test_t3_idempotent
smoke_run "T4 §0.1 apply-failure leaves no flipped roster (rollback ran)" test_t4_apply_failure_no_flip
smoke_run "T5 iso-effective target fails closed (rc 3)" test_t5_iso_fail_closed

smoke_log "PASS — #2061 Track B convert verb: dry-run no-mutation, audited static flip with baked launch_cmd + hold, byte-equal migration, crash-clear, #1455 invariant, idempotent, last-flip rollback, iso fail-closed"
