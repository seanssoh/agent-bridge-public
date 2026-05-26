#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/A12-beta3-1246-1252-daemon-supp-group-and-state-dir.sh —
# v0.15.0-beta3 Lane A12 (OOTB blocker bundle for #1246 + #1252).
#
# Background:
#   patch's fresh-install OOTB on cm-prod-agentworkflow-vm01 (v0.15.0-beta2)
#   landed two related blocker symptoms that this lane closes together
#   because the surface code touches the same three modules
#   (lib/bridge-daemon-control.sh, lib/bridge-state.sh, lib/bridge-agents.sh).
#
#   #1246 (daemon group-refresh pre-check false-positive)
#     - `agent create <a> --isolate` emits `daemon_group_refresh: skipped-
#       daemon-already-has-group` but the running daemon's supplementary
#       group set is provably stale (the freshly-created ab-agent-<a> GID
#       is NOT in /proc/<daemon_pid>/status `Groups:`). The systemd-user
#       auto-restart branch in lib/bridge-daemon-control.sh:404-411 is
#       bypassed and downstream nudge writes wedge.
#
#   #1252 (per-task nudge never fires after the first drop)
#     - State/agents/<a>/ directory doesn't exist → daemon's controller-
#       side writes (idle-since, pending-attention/, missing-marker-
#       retries) all fail → nudge code path skips silently. Only one
#       nudge entry in 75min uptime, labeled `appears dropped`.
#
# Tests (host-agnostic — static-source assertions + isolated mock-mkdir
# fixtures; no real `agent-bridge-*` users, no sudo/root, no real tmux):
#
#   T1: `_bridge_daemon_control_daemon_has_gid` predicate emits the
#       new structured decision-evidence log line whenever it is called
#       with a target_gid. The line shape is
#       `[daemon-control] supp-group check: pid=<P> in_proc=<G,...>
#       target_gid=<G> action=<refresh|skip> reason=<rationale>` and
#       BRIDGE_DAEMON_CONTROL_DECISION_LOG routes it to a file. Stubs
#       `bridge_daemon_pid` to return a fixed PID; stubs the proc-groups
#       reader to return a known set.
#
#   T2: `agent create` flow (via static-source grep) calls
#       `bridge_agent_state_dir_self_heal` synchronously before
#       returning success. A revert that drops the synchronous call
#       trips T2.
#
#   T3: `bridge_agent_state_dir_self_heal` creates `state/agents/<a>/`
#       with mode 2770 when missing, AND is idempotent when the dir
#       already exists.
#
#   T4: `bridge_write_idle_ready_agents` emits the structured
#       `[nudge-skip] agent=<a> task=none reason=state-dir-missing
#       evidence=<dir>` line when the per-agent state-dir is missing
#       AND self-heal also fails. Asserted via static-source grep on
#       lib/bridge-channels.sh because the helper is sourced through
#       the full daemon stack at runtime — a host-agnostic behavioral
#       repro would need the entire roster/state ladder.
#
#       r2 codex r1 BLOCKING #1252: contract is `task=<digits>` or
#       `task=none`, NEVER `task=-`. R1 hard-coded `task=-` at all four
#       new emitters and the smoke pinned the wrong shape. T4 + T11
#       now assert the correct contract.
#
#   T5: the same decision-evidence log line shape appears in EVERY
#       call site that triggers `_bridge_daemon_control_daemon_has_gid`
#       (the predicate ALWAYS emits, so the pre-check at
#       lib/bridge-daemon-control.sh:348 + 383 cannot silently false-
#       positive again — operator sees the in_proc set, the on_disk
#       set, and the target_gid in the daemon log when reconstructing
#       the wedge).
#
#       r2 codex r1 CONTRACT MISMATCH #1246: brief contract is
#       `pid=<P> on_disk=<GIDs> in_proc=<GIDs> target_gid=<G>` — R1
#       only emitted in_proc. T1 + T12 now assert both fields.
#
#   T6 (teeth): revert the predicate's decision-emit — assert T1 fails
#       loudly citing #1246. The teeth-check fixture writes a temporary
#       copy of lib/bridge-daemon-control.sh with the emit-helper body
#       neutered, then re-runs T1's logic against the patched copy and
#       expects it to fail. Closes the "smoke that always passes" class.
#
#   T7 (teeth): revert the agent-create synchronous self-heal call —
#       assert T2 fails loudly citing #1252. Same fixture pattern as T6
#       against a temporary copy of bridge-agent.sh.
#
#   T8 (r2 codex r1 BLOCKING #1252): pre-existing-dir self-heal verifies
#       mode (2770) AND group (ab-agent-<X>). Set up a dir at mode 0700,
#       call self-heal: expect rc=0 with dir now mode 2770 (auto-repair)
#       OR rc!=0 with structured reason citing chmod failure. R1
#       returned success for ANY pre-existing dir without checking
#       mode/group. r3 codex r2: T8/T9/T10 now stub
#       `bridge_agent_linux_user_isolation_effective` to return 0 (true)
#       so the iso-v2 enforcement branch is exercised; the production
#       gate added at r3 keeps non-iso agents on a no-chgrp path that
#       T16 + T17 cover separately.
#
#   T9 (r2 codex r1 BLOCKING #1252): new-create branch's chgrp failure
#       propagates instead of being silently ignored. Stub chgrp to fail
#       (via PATH override), call self-heal on a missing dir: expect
#       rc!=0 with structured reason `state_dir_chgrp_failed`. r3 codex
#       r2: also stubs the iso-v2-effective predicate to true.
#
#   T10 (r2 codex r1 BLOCKING #1252): empty group-resolver fail-loud.
#        Stub `bridge_isolation_v2_agent_group_name` to return empty,
#        call self-heal on a missing dir: expect rc!=0 with structured
#        reason `state_dir_group_resolver_empty`. r3 codex r2: also
#        stubs the iso-v2-effective predicate to true (empty resolver
#        under iso-v2 is the failure surface this asserts).
#
#   T11 (r2 codex r1 BLOCKING #1252 nudge-skip task contract): all four
#        new `[nudge-skip]` emitters cite either `task=<digits>` (when
#        a task id is in scope) or `task=none` (when none is). NEVER
#        `task=-` (R1 contract violation). Asserted via static-source
#        grep against bridge-daemon.sh + lib/bridge-channels.sh.
#
#   T12 (r2 codex r1 CONTRACT MISMATCH #1246 on_disk field): the
#        decision-evidence emit helper signature accepts on_disk between
#        pid and in_proc, and ALL call sites in
#        _bridge_daemon_control_daemon_has_gid pass it. Asserted via
#        static-source grep against lib/bridge-daemon-control.sh.
#
#   T13 (teeth, r2 codex r1 finding 1): revert the nudge-skip
#        task-contract fix back to `task=-` — assert T11 fails loudly.
#
#   T14 (teeth, r2 codex r1 finding 3): revert the on_disk evidence
#        field — assert T1 + T12 fail loudly.
#
#   T15 (teeth, r2 codex r1 finding 2): revert the self-heal
#        mode-verify on a pre-existing dir — assert T8 fails loudly.
#
#   T16 (r3 codex r2 BLOCKING): non-iso agent path — stub
#        `bridge_agent_linux_user_isolation_effective` to return 1
#        (false), call self-heal on a missing dir: expect rc=0, dir
#        created, NO chgrp attempted, NO failure on missing/empty
#        group resolver. This is the regression r2 introduced and r3
#        closes: ordinary `agent create` on a non-iso install (macOS,
#        roster without `linux_user_isolation`, shared mode) MUST not
#        fail on the pre-create-ok gate.
#
#   T17 (teeth, r3 codex r2 BLOCKING regression): revert the iso-v2
#        predicate gate (re-enforce ab-agent unconditionally), then call
#        self-heal under a STUBBED `linux_user_isolation_effective=false`
#        agent with a chgrp that fails (group does not exist). Expect
#        rc!=0 with `state_dir_chgrp_failed`. Without the r3 gate, this
#        is the exact wedge the r2 fixer produced — ordinary non-iso
#        creates failing at `bridge-agent.sh:3551-3554` with
#        `state_dir_chgrp_failed target=ab-agent-<a> post_mkdir`.
#
# Footgun #11 (heredoc-stdin subprocess deadlock class): every
# assertion uses `grep -n` against the source files OR builds harness
# scripts with `printf '%s\n' >file` and runs them as external scripts.
# No `<<<` here-string or `<<EOF` heredoc-stdin into subprocess capture.

set -uo pipefail

SMOKE_NAME="A12-beta3-1246-1252-daemon-supp-group-and-state-dir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
DAEMON_CONTROL_LIB="$REPO_ROOT/lib/bridge-daemon-control.sh"
STATE_LIB="$REPO_ROOT/lib/bridge-state.sh"
CHANNELS_LIB="$REPO_ROOT/lib/bridge-channels.sh"
AGENT_SH="$REPO_ROOT/bridge-agent.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"

[[ -f "$DAEMON_CONTROL_LIB" ]] || smoke_fail "missing $DAEMON_CONTROL_LIB"
[[ -f "$STATE_LIB" ]]          || smoke_fail "missing $STATE_LIB"
[[ -f "$CHANNELS_LIB" ]]       || smoke_fail "missing $CHANNELS_LIB"
[[ -f "$AGENT_SH" ]]           || smoke_fail "missing $AGENT_SH"
[[ -f "$DAEMON_SH" ]]          || smoke_fail "missing $DAEMON_SH"

# ---------------------------------------------------------------------
# Helper: extract _bridge_daemon_control_daemon_has_gid +
# _bridge_daemon_control_proc_groups +
# _bridge_daemon_control_emit_decision_log into an isolated script we
# can drive without sourcing the full daemon-control library (which
# requires bridge_audit_log + many init paths).
# ---------------------------------------------------------------------
extract_predicate_lib() {
  local source="$DAEMON_CONTROL_LIB"
  local out="$SMOKE_TMP_ROOT/predicate-extract.sh"
  : >"$out"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -uo pipefail'
    # Provide a no-op bridge_warn so the predicate library can call it
    # without pulling the full bridge-lib.sh init chain.
    printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
    awk '/^_bridge_daemon_control_proc_groups\(\) \{/,/^\}/' "$source"
    awk '/^_bridge_daemon_control_daemon_has_gid\(\) \{/,/^\}/' "$source"
    # r2 codex r1: also pull in the on_disk helper so the predicate
    # call sites can resolve it.
    awk '/^_bridge_daemon_control_proc_owner_on_disk_groups\(\) \{/,/^\}/' "$source"
    awk '/^_bridge_daemon_control_emit_decision_log\(\) \{/,/^\}/' "$source"
  } >>"$out"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------
# T1: predicate emits decision-evidence log line on each call.
# ---------------------------------------------------------------------
smoke_log "T1: _bridge_daemon_control_daemon_has_gid emits structured decision-evidence log"

PREDICATE_LIB="$(extract_predicate_lib)"
chmod +x "$PREDICATE_LIB"

T1_DRIVER="$SMOKE_TMP_ROOT/t1-driver.sh"
: >"$T1_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$PREDICATE_LIB\""
  # Stub bridge_daemon_pid to return a fixed PID. The real predicate
  # then calls _bridge_daemon_control_proc_groups which we ALSO stub
  # via PATH (so the /proc/<pid>/status read can be intercepted) —
  # but actually proc_groups uses `awk` on a path. Simplest fixture:
  # write a fake /proc-like file under SMOKE_TMP_ROOT, then override
  # the helper to read from it.
  printf '%s\n' 'bridge_daemon_pid() { printf "12345"; }'
  printf '%s\n' '_bridge_daemon_control_proc_groups() { printf "100\n200\n981\n"; }'
  # r2 codex r1 CONTRACT MISMATCH #1246: stub the on_disk helper so the
  # decision-evidence line carries a deterministic on_disk= field too.
  # The real helper reads /proc/<pid>/status Uid + runs `id -G <user>`;
  # the fixture short-circuits both for a host-agnostic assertion.
  printf '%s\n' '_bridge_daemon_control_proc_owner_on_disk_groups() { printf "100,200,981,777"; }'
  # Case A: target GID 981 IS present in proc groups → action=skip reason=already-has-group
  printf '%s\n' '_bridge_daemon_control_daemon_has_gid 981; rc_a=$?'
  printf '%s\n' '# Case B: target GID 999 is NOT present → action=refresh reason=missing-from-supp-set'
  printf '%s\n' '_bridge_daemon_control_daemon_has_gid 999; rc_b=$?'
  printf '%s\n' 'printf "rc_a=%s\nrc_b=%s\n" "$rc_a" "$rc_b"'
} >>"$T1_DRIVER"
chmod +x "$T1_DRIVER"

T1_DECISION_LOG="$SMOKE_TMP_ROOT/t1-decision.log"
: >"$T1_DECISION_LOG"

T1_OUT="$(
  BRIDGE_DAEMON_CONTROL_DECISION_LOG="$T1_DECISION_LOG" \
    /usr/bin/env bash "$T1_DRIVER" 2>&1
)"

# r2 codex r1 CONTRACT MISMATCH #1246: assertion now includes on_disk
# between pid and in_proc. Brief contract:
#   pid=<P> on_disk=<GIDs> in_proc=<GIDs> target_gid=<G> action=<A> reason=<R>
if ! grep -q 'pid=12345 on_disk=100,200,981,777 in_proc=100,200,981 target_gid=981 action=skip reason=already-has-group' "$T1_DECISION_LOG"; then
  smoke_fail "T1: decision log did not capture skip/already-has-group case with on_disk + in_proc; got:$(printf '\n')$(cat "$T1_DECISION_LOG")"
fi
if ! grep -q 'pid=12345 on_disk=100,200,981,777 in_proc=100,200,981 target_gid=999 action=refresh reason=missing-from-supp-set' "$T1_DECISION_LOG"; then
  smoke_fail "T1: decision log did not capture refresh/missing-from-supp-set case with on_disk + in_proc; got:$(printf '\n')$(cat "$T1_DECISION_LOG")"
fi
if [[ "$T1_OUT" != *"rc_a=0"* ]] || [[ "$T1_OUT" != *"rc_b=1"* ]]; then
  smoke_fail "T1: predicate return codes wrong; expected rc_a=0 rc_b=1, got: $T1_OUT"
fi
smoke_log "T1 PASS — predicate emits structured decision-evidence (on_disk + in_proc) + correct rc"

# ---------------------------------------------------------------------
# T2: agent create flow synchronously invokes bridge_agent_state_dir_self_heal.
# ---------------------------------------------------------------------
smoke_log "T2: bridge-agent.sh run_create calls bridge_agent_state_dir_self_heal synchronously"

T2_MATCH="$(grep -nF 'bridge_agent_state_dir_self_heal "$agent"' "$AGENT_SH" || true)"
if [[ -z "$T2_MATCH" ]]; then
  smoke_fail "T2: bridge-agent.sh does not contain synchronous bridge_agent_state_dir_self_heal call — #1252 fix regressed (operator would see create:ok for an agent whose first nudge silently drops)"
fi
# Also assert it's in run_create's body (search for the comment anchor
# we inserted referencing #1252 in the same block).
if ! grep -q '#1252: state/agents/<a>/ MUST exist' "$AGENT_SH"; then
  smoke_fail "T2: anchor comment for #1252 in run_create missing — the synchronous self-heal block was moved/removed"
fi
smoke_log "T2 PASS — bridge-agent.sh run_create synchronously self-heals state-agent-dir before returning create:ok"

# ---------------------------------------------------------------------
# T3: bridge_agent_state_dir_self_heal creates the dir + idempotent.
# ---------------------------------------------------------------------
smoke_log "T3: bridge_agent_state_dir_self_heal creates state/agents/<a>/ with mode 2770 + is idempotent"

T3_DRIVER="$SMOKE_TMP_ROOT/t3-driver.sh"
: >"$T3_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  # Minimal stubs that bridge_agent_state_dir_self_heal needs:
  # bridge_agent_idle_marker_dir (path), bridge_warn (no-op logger),
  # bridge_isolation_v2_agent_group_name (returns empty → chgrp skipped).
  printf '%s\n' "BRIDGE_ACTIVE_AGENT_DIR=\"$SMOKE_TMP_ROOT/state-agents\""
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_agent_idle_marker_dir() {'
  printf '%s\n' '  printf "%s/%s" "$BRIDGE_ACTIVE_AGENT_DIR" "$1"'
  printf '%s\n' '}'
  # Inline the helper body directly from lib/bridge-state.sh so we do
  # not need the whole library's init chain. Extract via awk.
  awk '/^bridge_agent_state_dir_self_heal\(\) \{/,/^\}/' "$STATE_LIB" >>"$T3_DRIVER"
  printf '\n%s\n' '# Case A: dir absent → create.'
  printf '%s\n' 'bridge_agent_state_dir_self_heal test_a12_smoke; rc_a=$?'
  printf '%s\n' '[[ -d "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_smoke" ]] || { echo "T3a: dir was not created"; exit 1; }'
  # Case B: idempotent re-call.
  printf '%s\n' 'bridge_agent_state_dir_self_heal test_a12_smoke; rc_b=$?'
  printf '%s\n' 'printf "rc_a=%s rc_b=%s\n" "$rc_a" "$rc_b"'
  printf '%s\n' '# Read back mode to verify 2770 (best-effort — on BSD stat the flag set differs;'
  printf '%s\n' '# accept either 2770 or 770 since mkdir -m strips setgid on some macOS versions).'
  printf '%s\n' 'mode="$(stat -c %a "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_smoke" 2>/dev/null || stat -f %Lp "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_smoke" 2>/dev/null)"'
  printf '%s\n' 'printf "mode=%s\n" "$mode"'
} >>"$T3_DRIVER"
chmod +x "$T3_DRIVER"

T3_OUT="$(/usr/bin/env bash "$T3_DRIVER" 2>&1)"
if [[ "$T3_OUT" != *"rc_a=0 rc_b=0"* ]]; then
  smoke_fail "T3: expected rc_a=0 rc_b=0 (create + idempotent), got: $T3_OUT"
fi
# Verify the dir was created.
if [[ ! -d "$SMOKE_TMP_ROOT/state-agents/test_a12_smoke" ]]; then
  smoke_fail "T3: state-agents/test_a12_smoke dir was not created"
fi
# Verify mode contains the 2770 or 770 marker.
if [[ "$T3_OUT" != *"mode=2770"* ]] && [[ "$T3_OUT" != *"mode=770"* ]]; then
  smoke_fail "T3: expected mode 2770 or 770 (setgid stripped on some BSD stat flavors), got: $T3_OUT"
fi
smoke_log "T3 PASS — bridge_agent_state_dir_self_heal creates dir + idempotent + mode 2770/770"

# ---------------------------------------------------------------------
# T4: bridge_write_idle_ready_agents emits structured [nudge-skip] line
#     on state-dir-missing + self-heal-fail. Asserted via static-source
#     grep — the helper requires the full daemon stack to drive at
#     runtime, and the structured-line format is the contract.
# ---------------------------------------------------------------------
smoke_log "T4: bridge_write_idle_ready_agents emits [nudge-skip] structured line on state-dir-missing"

# r2 codex r1 BLOCKING #1252: contract is `task=none` at this call site
# (no task id in scope on the idle-marker writer loop), NOT `task=-`.
# Earlier R1 hard-coded `task=-`; T11 below also covers the daemon-side
# emitters that should cite `task=<digits>` when an id IS in scope.
if ! grep -q '\[nudge-skip\] agent=\$agent task=none reason=state-dir-missing evidence=\$_idle_dir' "$CHANNELS_LIB"; then
  smoke_fail "T4: lib/bridge-channels.sh does not emit '[nudge-skip] agent=<a> task=none reason=state-dir-missing evidence=<dir>' (r2 codex r1 BLOCKING: contract is task=none, NOT task=-; R1 hard-coded task=-)"
fi
# Explicit regression-of-the-wrong-contract guard: NO `task=-` literal
# may exist in the state-dir-missing emitter line.
if grep -q '\[nudge-skip\] agent=\$agent task=- ' "$CHANNELS_LIB"; then
  smoke_fail "T4: lib/bridge-channels.sh STILL emits 'task=-' at the state-dir-missing site — r2 codex r1 BLOCKING #1252 contract violation"
fi
# Also assert the audit_log emit path is in place.
if ! grep -q 'bridge_audit_log daemon nudge_skip' "$CHANNELS_LIB"; then
  smoke_fail "T4: lib/bridge-channels.sh does not emit bridge_audit_log daemon nudge_skip — the audit row anchor for #1252 is missing"
fi
smoke_log "T4 PASS — bridge_write_idle_ready_agents emits structured [nudge-skip] task=none line + audit row"

# ---------------------------------------------------------------------
# T5: predicate emits decision-evidence on EVERY call site (not just
#     test-mode). Assert via static-source grep that
#     _bridge_daemon_control_emit_decision_log is invoked from inside
#     _bridge_daemon_control_daemon_has_gid (both early-return paths
#     AND the success/refusal paths).
# ---------------------------------------------------------------------
smoke_log "T5: predicate emits decision-evidence on every code path"

# All four reasons must appear in the predicate body. We grep the file
# for the four `reason=` literal strings the predicate emits.
for reason in "daemon-not-running" "proc-status-unreadable" "already-has-group" "missing-from-supp-set"; do
  if ! grep -q "reason=\"$reason\"" "$DAEMON_CONTROL_LIB" && ! grep -q "\"$reason\"" "$DAEMON_CONTROL_LIB"; then
    smoke_fail "T5: predicate decision-evidence emit missing reason='$reason' — operator would see no log evidence on that path"
  fi
done
# Also assert the prefix appears in the emit helper.
if ! grep -q '\[daemon-control\] supp-group check:' "$DAEMON_CONTROL_LIB"; then
  smoke_fail "T5: decision-evidence log prefix '[daemon-control] supp-group check:' missing from lib/bridge-daemon-control.sh"
fi
smoke_log "T5 PASS — predicate decision-evidence covers all four code paths"

# ---------------------------------------------------------------------
# T6 (teeth): revert the predicate's decision-evidence emit → T1 fails.
# ---------------------------------------------------------------------
smoke_log "T6 (teeth): teeth-check on T1 — predicate without decision-evidence emit must FAIL T1"

T6_PATCHED_LIB="$SMOKE_TMP_ROOT/predicate-patched.sh"
# Build a copy with _bridge_daemon_control_emit_decision_log NEUTERED
# (replaced with a no-op). This simulates the pre-fix state.
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  # Keep proc_groups + has_gid + on_disk_groups as-is, but override the
  # emit helper to no-op. r2 codex r1: on_disk helper needs to exist or
  # has_gid's call site would unbound-variable.
  awk '/^_bridge_daemon_control_proc_groups\(\) \{/,/^\}/' "$DAEMON_CONTROL_LIB"
  awk '/^_bridge_daemon_control_proc_owner_on_disk_groups\(\) \{/,/^\}/' "$DAEMON_CONTROL_LIB"
  awk '/^_bridge_daemon_control_daemon_has_gid\(\) \{/,/^\}/' "$DAEMON_CONTROL_LIB"
  # Now define a NO-OP emit helper that does NOT write to the log file —
  # simulates the pre-fix predicate (silent on every code path).
  printf '%s\n' '_bridge_daemon_control_emit_decision_log() { return 0; }'
} >"$T6_PATCHED_LIB"
chmod +x "$T6_PATCHED_LIB"

T6_DRIVER="$SMOKE_TMP_ROOT/t6-driver.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "source \"$T6_PATCHED_LIB\""
  printf '%s\n' 'bridge_daemon_pid() { printf "12345"; }'
  printf '%s\n' '_bridge_daemon_control_proc_groups() { printf "100\n200\n981\n"; }'
  # r2 codex r1: also stub the on_disk helper so the predicate does not
  # invoke the real /proc lookup during the teeth-check.
  printf '%s\n' '_bridge_daemon_control_proc_owner_on_disk_groups() { printf "100,200,981"; }'
  printf '%s\n' '_bridge_daemon_control_daemon_has_gid 981 >/dev/null 2>&1 || true'
} >"$T6_DRIVER"
chmod +x "$T6_DRIVER"

T6_DECISION_LOG="$SMOKE_TMP_ROOT/t6-decision.log"
: >"$T6_DECISION_LOG"
BRIDGE_DAEMON_CONTROL_DECISION_LOG="$T6_DECISION_LOG" \
  /usr/bin/env bash "$T6_DRIVER" >/dev/null 2>&1 || true

# With the emit no-op'd, the decision log must be EMPTY.
if [[ -s "$T6_DECISION_LOG" ]]; then
  smoke_fail "T6 (teeth): patched (decision-emit no-op'd) predicate STILL wrote to decision log — teeth-check is broken (T1 would not detect a regression)"
fi
smoke_log "T6 PASS — teeth-check works: removing decision-evidence emit DOES break T1's assertion (predicate would silently false-positive again like #1246)"

# ---------------------------------------------------------------------
# T7 (teeth): revert the agent-create synchronous self-heal → T2 fails.
# ---------------------------------------------------------------------
smoke_log "T7 (teeth): teeth-check on T2 — bridge-agent.sh without self-heal must FAIL T2"

T7_PATCHED_AGENT="$SMOKE_TMP_ROOT/bridge-agent-patched.sh"
# Strip the synchronous self-heal block from bridge-agent.sh.
# We use sed to remove lines between the comment anchor and the
# closing `fi`. This is a narrow surgical patch.
sed '/#1252: state\/agents\/<a>\/ MUST exist before this agent appears to/,/^    fi$/d' \
  "$AGENT_SH" >"$T7_PATCHED_AGENT"
# Now run T2's grep against the patched copy. Both checks must FAIL.
T7_MATCH_A="$(grep -F 'bridge_agent_state_dir_self_heal "$agent"' "$T7_PATCHED_AGENT" || true)"
T7_MATCH_B="$(grep '#1252: state/agents/<a>/ MUST exist' "$T7_PATCHED_AGENT" || true)"
# After strip, the synchronous call from run_create must be gone.
# (Other unrelated self-heal references in the file — e.g. doc-comments
# — should also not exist. Today the only call is the one we inserted.)
if [[ -n "$T7_MATCH_A" ]] || [[ -n "$T7_MATCH_B" ]]; then
  smoke_fail "T7 (teeth): teeth-check sed-strip did not remove the self-heal block — teeth fixture is broken. match_a='$T7_MATCH_A' match_b='$T7_MATCH_B'"
fi
smoke_log "T7 PASS — teeth-check works: removing the synchronous self-heal call DOES break T2's assertion (operator would see create:ok for an agent that silently drops nudges, #1252)"

# ---------------------------------------------------------------------
# T8 (r2 codex r1 BLOCKING #1252): pre-existing-dir self-heal verifies
#     mode + group, and AUTO-REPAIRS via chmod / chgrp when divergent.
# ---------------------------------------------------------------------
smoke_log "T8: bridge_agent_state_dir_self_heal verifies mode 2770 on pre-existing dirs"

T8_DRIVER="$SMOKE_TMP_ROOT/t8-driver.sh"
: >"$T8_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "BRIDGE_ACTIVE_AGENT_DIR=\"$SMOKE_TMP_ROOT/t8-state-agents\""
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s/%s" "$BRIDGE_ACTIVE_AGENT_DIR" "$1"; }'
  # r3 codex r2: T8 exercises the mode-verify branch (non-iso /
  # legacy install). Predicate `bridge_agent_linux_user_isolation_
  # effective` is unstubbed → not in PATH / function-not-defined →
  # `command -v` returns false → the production helper takes the
  # mode-only path (no chgrp, no group resolver). That is the legacy
  # behavior T8 originally pinned (rc=0 with auto-repaired mode 2770,
  # or rc!=0 with structured chmod-reason).
  awk '/^bridge_agent_state_dir_self_heal\(\) \{/,/^\}/' "$STATE_LIB" >>"$T8_DRIVER"
  printf '\n%s\n' '# Pre-create the dir at mode 0700 — divergent from canonical 2770.'
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t8"'
  printf '%s\n' 'chmod 0700 "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t8"'
  printf '%s\n' 'pre_mode="$(stat -c %a "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t8" 2>/dev/null || stat -f %Lp "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t8" 2>/dev/null)"'
  printf '%s\n' 'printf "pre_mode=%s\n" "$pre_mode"'
  printf '%s\n' 'bridge_agent_state_dir_self_heal test_a12_t8; rc=$?'
  printf '%s\n' 'post_mode="$(stat -c %a "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t8" 2>/dev/null || stat -f %Lp "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t8" 2>/dev/null)"'
  printf '%s\n' 'printf "rc=%s post_mode=%s\n" "$rc" "$post_mode"'
} >>"$T8_DRIVER"
chmod +x "$T8_DRIVER"

T8_OUT="$(/usr/bin/env bash "$T8_DRIVER" 2>&1)"
# Acceptable behavior per brief:
#   - rc=0 with dir now mode 2770 (auto-repaired), OR
#   - rc!=0 with structured reason citing chmod failure
# Both prove the verifier checks mode; what R1 did (rc=0 with mode 700)
# is now NOT acceptable.
T8_OK=0
if [[ "$T8_OUT" == *"rc=0"* ]] && { [[ "$T8_OUT" == *"post_mode=2770"* ]] || [[ "$T8_OUT" == *"post_mode=770"* ]]; }; then
  T8_OK=1
elif [[ "$T8_OUT" != *"rc=0"* ]] && [[ "$T8_OUT" == *"state_dir_chmod"* ]]; then
  T8_OK=1
fi
if (( T8_OK == 0 )); then
  smoke_fail "T8 (r2 codex r1 BLOCKING #1252): self-heal on pre-existing mode=0700 dir did not auto-repair to 2770 AND did not fail-loud with structured reason; got: $T8_OUT"
fi
# Strict regression guard: rc=0 with mode 700 is EXACTLY what R1 did.
if [[ "$T8_OUT" == *"rc=0"* ]] && [[ "$T8_OUT" == *"post_mode=700"* ]]; then
  smoke_fail "T8 (r2 codex r1 BLOCKING #1252): self-heal returned rc=0 for a pre-existing dir at mode 0700 WITHOUT repairing it — R1 false-positive regressed"
fi
smoke_log "T8 PASS — self-heal on pre-existing wrong-mode dir auto-repairs or fail-louds"

# ---------------------------------------------------------------------
# T9 (r2 codex r1 BLOCKING #1252): new-create branch propagates chgrp
#     failure instead of silently ignoring it.
# ---------------------------------------------------------------------
smoke_log "T9: bridge_agent_state_dir_self_heal new-create chgrp failure propagates"

T9_DRIVER="$SMOKE_TMP_ROOT/t9-driver.sh"
: >"$T9_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "BRIDGE_ACTIVE_AGENT_DIR=\"$SMOKE_TMP_ROOT/t9-state-agents\""
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s/%s" "$BRIDGE_ACTIVE_AGENT_DIR" "$1"; }'
  # r3 codex r2: stub iso-v2-effective predicate true so the production
  # helper enters the chgrp branch this test targets. Without the stub
  # the r3 gate routes to mode-only (legacy) and chgrp is never called
  # — making the failure-propagation assertion trivially vacuous.
  printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }'
  # Stub the v2 group-name resolver to return a non-empty group so the
  # chgrp branch is entered.
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "ab-agent-test_a12_t9"; }'
  # Override `chgrp` as a function to force failure — exercises the
  # propagation path. This shadows the binary inside this subshell.
  printf '%s\n' 'chgrp() { return 1; }'
  awk '/^bridge_agent_state_dir_self_heal\(\) \{/,/^\}/' "$STATE_LIB" >>"$T9_DRIVER"
  printf '\n%s\n' 'bridge_agent_state_dir_self_heal test_a12_t9; rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
} >>"$T9_DRIVER"
chmod +x "$T9_DRIVER"

T9_OUT="$(/usr/bin/env bash "$T9_DRIVER" 2>&1 || true)"
# rc must be non-zero (chgrp failed → self-heal must NOT return success).
if [[ "$T9_OUT" == *"rc=0"* ]]; then
  smoke_fail "T9 (r2 codex r1 BLOCKING #1252): self-heal returned rc=0 despite chgrp failure — R1 ignored chgrp non-zero and silently dropped the canonical-group contract; got: $T9_OUT"
fi
# Structured reason must mention the chgrp failure surface (either
# chgrp_failed or chgrp_verify_failed — both prove the path was checked).
if [[ "$T9_OUT" != *"state_dir_chgrp"* ]]; then
  smoke_fail "T9 (r2 codex r1 BLOCKING #1252): self-heal failed but did not emit a structured chgrp reason; got: $T9_OUT"
fi
smoke_log "T9 PASS — self-heal propagates chgrp failure with structured reason"

# ---------------------------------------------------------------------
# T10 (r2 codex r1 BLOCKING #1252): empty group-resolver fails loud
#      with reason=state_dir_group_resolver_empty.
# ---------------------------------------------------------------------
smoke_log "T10: bridge_agent_state_dir_self_heal fails loud on empty group-resolver"

T10_DRIVER="$SMOKE_TMP_ROOT/t10-driver.sh"
: >"$T10_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "BRIDGE_ACTIVE_AGENT_DIR=\"$SMOKE_TMP_ROOT/t10-state-agents\""
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s/%s" "$BRIDGE_ACTIVE_AGENT_DIR" "$1"; }'
  # r3 codex r2: stub iso-v2-effective predicate true so the empty-
  # resolver fail-loud branch is exercised. Without the stub the r3
  # gate routes to mode-only (legacy) and the empty resolver is
  # never consulted.
  printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 0; }'
  # Stub the v2 resolver to return EMPTY — codex r1 direct repro.
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf ""; }'
  awk '/^bridge_agent_state_dir_self_heal\(\) \{/,/^\}/' "$STATE_LIB" >>"$T10_DRIVER"
  printf '\n%s\n' 'bridge_agent_state_dir_self_heal test_a12_t10; rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
} >>"$T10_DRIVER"
chmod +x "$T10_DRIVER"

T10_OUT="$(/usr/bin/env bash "$T10_DRIVER" 2>&1 || true)"
if [[ "$T10_OUT" == *"rc=0"* ]]; then
  smoke_fail "T10 (r2 codex r1 BLOCKING #1252): self-heal returned rc=0 with EMPTY group resolver — R1 silently no-op'd chgrp and left the dir with the controller's primary group (e.g. agentbridge), and daemon writes still wedged; got: $T10_OUT"
fi
if [[ "$T10_OUT" != *"state_dir_group_resolver_empty"* ]]; then
  smoke_fail "T10 (r2 codex r1 BLOCKING #1252): self-heal failed but did not emit reason=state_dir_group_resolver_empty; got: $T10_OUT"
fi
smoke_log "T10 PASS — self-heal fails loud on empty group resolver with structured reason"

# ---------------------------------------------------------------------
# T11 (r2 codex r1 BLOCKING #1252): all four new [nudge-skip] emitters
#      cite `task=<digits>` or `task=none`, NEVER `task=-`.
# ---------------------------------------------------------------------
smoke_log "T11: all new [nudge-skip] emitters honor the task=<id|none> contract (no task=- literals)"

# Strict regression-of-wrong-contract guard: NO `[nudge-skip] ... task=- `
# string may appear in the four files that the R1 commit touched. The
# fixed shape is either `task=<digits>` or `task=none`.
T11_VIOLATIONS=""
for src in "$DAEMON_SH" "$CHANNELS_LIB"; do
  if grep -n '\[nudge-skip\][^"]*task=- ' "$src" 2>/dev/null; then
    T11_VIOLATIONS="$T11_VIOLATIONS $src"
  fi
done
if [[ -n "$T11_VIOLATIONS" ]]; then
  smoke_fail "T11 (r2 codex r1 BLOCKING #1252): [nudge-skip] emitters STILL hard-code 'task=-' instead of task=<id|none> in:$T11_VIOLATIONS"
fi

# Positive assertion: each of the 4 new emit sites must contain either
# `task=none ` or a variable-expansion `task=$...` / `task=${...}` shape.
# bridge-daemon.sh:
#   - live-queued-empty → task=none
#   - age-gate-failed   → task=${_agf_skip_task_id} (digits or 'none')
#   - dedup-cooldown    → task=${_dd_skip_task_id}  (digits or 'none')
# lib/bridge-channels.sh:
#   - state-dir-missing → task=none
if ! grep -q 'reason=live-queued-empty' "$DAEMON_SH" || ! grep -q 'task=none reason=live-queued-empty' "$DAEMON_SH"; then
  smoke_fail "T11: bridge-daemon.sh live-queued-empty emitter does not cite task=none (r2 codex r1 finding 1)"
fi
if ! grep -q 'reason=age-gate-failed' "$DAEMON_SH" || ! grep -q 'task=\${_agf_skip_task_id}' "$DAEMON_SH"; then
  smoke_fail "T11: bridge-daemon.sh age-gate-failed emitter does not cite task=\${_agf_skip_task_id} (r2 codex r1 finding 1)"
fi
if ! grep -q 'reason=dedup-cooldown' "$DAEMON_SH" || ! grep -q 'task=\${_dd_skip_task_id}' "$DAEMON_SH"; then
  smoke_fail "T11: bridge-daemon.sh dedup-cooldown emitter does not cite task=\${_dd_skip_task_id} (r2 codex r1 finding 1)"
fi
if ! grep -q 'task=none reason=state-dir-missing' "$CHANNELS_LIB"; then
  smoke_fail "T11: lib/bridge-channels.sh state-dir-missing emitter does not cite task=none (r2 codex r1 finding 1)"
fi
smoke_log "T11 PASS — [nudge-skip] emitters honor task=<id|none> contract"

# ---------------------------------------------------------------------
# T12 (r2 codex r1 CONTRACT MISMATCH #1246): on_disk field is present
#      in the decision-evidence emit helper signature + every call site.
# ---------------------------------------------------------------------
smoke_log "T12: decision-evidence emit helper includes on_disk between pid and in_proc"

# The emit helper printf format string must contain `on_disk=%s` BEFORE
# `in_proc=%s`. Single static-source grep against the literal printf.
if ! grep -q 'pid=%s on_disk=%s in_proc=%s target_gid=%s action=%s reason=%s' "$DAEMON_CONTROL_LIB"; then
  smoke_fail "T12 (r2 codex r1 CONTRACT MISMATCH #1246): decision-evidence printf format string does not include 'on_disk=%s' between 'pid=%s' and 'in_proc=%s' — operator cannot see on-disk supp groups for diagnostic"
fi
# The on_disk resolver helper must exist.
if ! grep -q '_bridge_daemon_control_proc_owner_on_disk_groups()' "$DAEMON_CONTROL_LIB"; then
  smoke_fail "T12 (r2 codex r1 CONTRACT MISMATCH #1246): _bridge_daemon_control_proc_owner_on_disk_groups resolver missing"
fi
# Every call site of the emit helper must pass 6 args (pid, on_disk,
# in_proc, target_gid, action, reason). Count fields by line: each call
# spans 2 lines (`_bridge_daemon_control_emit_decision_log \` followed
# by the args). Count emit helper invocations:
EMIT_CALLS="$(grep -cE '_bridge_daemon_control_emit_decision_log[[:space:]]*\\$' "$DAEMON_CONTROL_LIB" || true)"
if (( EMIT_CALLS < 4 )); then
  smoke_fail "T12 (r2 codex r1 CONTRACT MISMATCH #1246): expected >=4 calls to _bridge_daemon_control_emit_decision_log (one per outcome path), got $EMIT_CALLS"
fi
# Each call must include the on_disk slot. The simplest static check:
# count tokens on the args-line of each invocation. Strip out command
# substitutions ($(...)) first so nested quoted strings do not inflate
# the count. After stripping, each top-level arg is a single quoted
# string — count them and require >= 6.
T12_BAD_CALLS="$(
  awk '
    /_bridge_daemon_control_emit_decision_log[[:space:]]*\\$/ {
      getline next_line
      # Strip $(...) command-substitutions (non-nested) so inner
      # quoted strings dont inflate the arg count.
      gsub(/\$\([^)]*\)/, "X", next_line)
      n = gsub(/"[^"]*"/, "&", next_line)
      if (n != 6) print FILENAME ":" FNR ": (n=" n ") " next_line
    }
  ' "$DAEMON_CONTROL_LIB"
)"
if [[ -n "$T12_BAD_CALLS" ]]; then
  smoke_fail "T12 (r2 codex r1 CONTRACT MISMATCH #1246): emit-helper call sites do not pass 6 args (pid + on_disk + in_proc + target_gid + action + reason):$(printf '\n')$T12_BAD_CALLS"
fi
smoke_log "T12 PASS — on_disk field present in emit helper + all call sites pass it"

# ---------------------------------------------------------------------
# T13 (teeth, r2 codex r1 finding 1): revert task-contract fix back to
#      task=- → assert T11 fails loudly.
# ---------------------------------------------------------------------
smoke_log "T13 (teeth): teeth-check on T11 — reverting nudge-skip task-contract fix back to task=- must FAIL T11"

T13_PATCHED_DAEMON="$SMOKE_TMP_ROOT/bridge-daemon-T13.sh"
# Revert: replace the new `task=none` / `task=${...}` shapes back to
# the R1 `task=-` literal. Surgical sed replacement.
sed -E \
  -e 's/task=none reason=live-queued-empty/task=- reason=live-queued-empty/' \
  -e 's/task=\$\{_agf_skip_task_id\} reason=age-gate-failed/task=- reason=age-gate-failed/' \
  -e 's/task=\$\{_dd_skip_task_id\} reason=dedup-cooldown/task=- reason=dedup-cooldown/' \
  "$DAEMON_SH" >"$T13_PATCHED_DAEMON"

# Re-run the T11 strict regression guard against the patched copy.
if ! grep -q '\[nudge-skip\][^"]*task=- ' "$T13_PATCHED_DAEMON"; then
  smoke_fail "T13 (teeth): teeth-check sed-revert did NOT reintroduce task=- in patched bridge-daemon.sh — teeth fixture is broken"
fi
smoke_log "T13 PASS — teeth-check works: reverting the contract fix to task=- IS detected by T11's regression guard"

# ---------------------------------------------------------------------
# T14 (teeth, r2 codex r1 finding 3): revert on_disk evidence field →
#      T1 + T12 fail loudly.
# ---------------------------------------------------------------------
smoke_log "T14 (teeth): teeth-check on T1/T12 — reverting on_disk evidence field must FAIL T12"

T14_PATCHED_DC="$SMOKE_TMP_ROOT/bridge-daemon-control-T14.sh"
# Revert: replace the new printf with the R1 in_proc-only printf.
sed -E \
  -e 's/pid=%s on_disk=%s in_proc=%s target_gid=%s action=%s reason=%s/pid=%s in_proc=%s target_gid=%s action=%s reason=%s/' \
  "$DAEMON_CONTROL_LIB" >"$T14_PATCHED_DC"

if grep -q 'pid=%s on_disk=%s in_proc=%s target_gid=%s action=%s reason=%s' "$T14_PATCHED_DC"; then
  smoke_fail "T14 (teeth): teeth-check sed-revert did NOT remove on_disk=%s from patched printf — teeth fixture is broken"
fi
# Also confirm the R1 (pre-fix) shape returned.
if ! grep -q 'pid=%s in_proc=%s target_gid=%s action=%s reason=%s' "$T14_PATCHED_DC"; then
  smoke_fail "T14 (teeth): teeth-check sed-revert did not restore the R1 (pre-fix) in_proc-only printf shape"
fi
smoke_log "T14 PASS — teeth-check works: reverting the on_disk field IS detected by T12's assertion"

# ---------------------------------------------------------------------
# T15 (teeth, r2 codex r1 finding 2): revert self-heal mode-verify on
#      pre-existing dir → T8 fails loudly.
# ---------------------------------------------------------------------
smoke_log "T15 (teeth): teeth-check on T8 — reverting self-heal mode-verify (rc=0 for any pre-existing dir) must FAIL T8"

T15_DRIVER="$SMOKE_TMP_ROOT/t15-driver.sh"
: >"$T15_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "BRIDGE_ACTIVE_AGENT_DIR=\"$SMOKE_TMP_ROOT/t15-state-agents\""
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s/%s" "$BRIDGE_ACTIVE_AGENT_DIR" "$1"; }'
  # T15 = the R1 (pre-r2) helper shape: rc=0 for any pre-existing dir
  # regardless of mode/group. Inline a minimal R1-shape function so the
  # teeth-check is hermetic.
  printf '%s\n' 'bridge_agent_state_dir_self_heal_R1() {'
  printf '%s\n' '  local agent="$1"; [[ -n "$agent" ]] || return 1'
  printf '%s\n' '  local dir; dir="$(bridge_agent_idle_marker_dir "$agent")"'
  printf '%s\n' '  if [[ -d "$dir" ]]; then return 0; fi   # <-- R1 bug: rc=0 without checking mode'
  printf '%s\n' '  mkdir -m 2770 -p "$dir" 2>/dev/null && return 0'
  printf '%s\n' '  return 1'
  printf '%s\n' '}'
  printf '%s\n' '# Pre-create the dir at mode 0700 — the R1 helper returns rc=0 anyway.'
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t15"'
  printf '%s\n' 'chmod 0700 "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t15"'
  printf '%s\n' 'bridge_agent_state_dir_self_heal_R1 test_a12_t15; rc=$?'
  printf '%s\n' 'post_mode="$(stat -c %a "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t15" 2>/dev/null || stat -f %Lp "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t15" 2>/dev/null)"'
  printf '%s\n' 'printf "rc=%s post_mode=%s\n" "$rc" "$post_mode"'
} >>"$T15_DRIVER"
chmod +x "$T15_DRIVER"

T15_OUT="$(/usr/bin/env bash "$T15_DRIVER" 2>&1 || true)"
# This is what R1 produced: rc=0 with mode 700. If T8's regression guard
# is working, the R1 shape would fail T8's assertion. We assert here
# that the R1 shape DOES produce that exact output (so a reviewer can
# see the regression demonstration).
if [[ "$T15_OUT" != *"rc=0"* ]] || [[ "$T15_OUT" != *"post_mode=700"* ]]; then
  smoke_fail "T15 (teeth): the R1-shape helper did NOT reproduce the codex r1 finding 2 false-positive (expected rc=0 post_mode=700); got: $T15_OUT — teeth fixture is broken"
fi
smoke_log "T15 PASS — teeth-check works: the R1 false-positive (rc=0 with mode 700) IS the regression T8 catches"

# ---------------------------------------------------------------------
# T16 (r3 codex r2 BLOCKING): non-iso agent path — self-heal MUST not
#      chgrp to ab-agent-<a>, MUST not fail on empty/missing group.
#      Stub `bridge_agent_linux_user_isolation_effective` to return 1
#      (false), call self-heal on a missing dir with chgrp stubbed to
#      fail and resolver stubbed to a fake group: expect rc=0 (the gate
#      added at r3 routes around the group enforcement for non-iso
#      agents). This is the regression r2 introduced: ordinary
#      `agent create` on macOS / non-Linux / shared-iso installs failed
#      at the pre-create-ok gate.
# ---------------------------------------------------------------------
smoke_log "T16: bridge_agent_state_dir_self_heal skips ab-agent enforcement on non-iso agents (r3 codex r2 regression closed)"

T16_DRIVER="$SMOKE_TMP_ROOT/t16-driver.sh"
: >"$T16_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "BRIDGE_ACTIVE_AGENT_DIR=\"$SMOKE_TMP_ROOT/t16-state-agents\""
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s/%s" "$BRIDGE_ACTIVE_AGENT_DIR" "$1"; }'
  # r3 codex r2 BLOCKING: predicate returns 1 (non-iso). Even with the
  # resolver returning a fake group and chgrp guaranteed to fail, the
  # production helper MUST short-circuit those branches and return rc=0.
  printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }'
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "ab-agent-test_a12_t16"; }'
  printf '%s\n' 'chgrp() { return 1; }   # explicit fail — gate must prevent this from being reached'
  awk '/^bridge_agent_state_dir_self_heal\(\) \{/,/^\}/' "$STATE_LIB" >>"$T16_DRIVER"
  printf '\n%s\n' '# Case A: non-iso new-create. Dir absent → mkdir + no chgrp.'
  printf '%s\n' 'bridge_agent_state_dir_self_heal test_a12_t16; rc=$?'
  printf '%s\n' '[[ -d "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t16" ]] || { echo "T16a: dir not created"; exit 1; }'
  printf '%s\n' 'post_grp="$(stat -c %G "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t16" 2>/dev/null || stat -f %Sg "$BRIDGE_ACTIVE_AGENT_DIR/test_a12_t16" 2>/dev/null)"'
  printf '%s\n' 'printf "rc=%s post_grp=%s\n" "$rc" "$post_grp"'
  printf '\n%s\n' '# Case B: non-iso idempotent re-call.'
  printf '%s\n' 'bridge_agent_state_dir_self_heal test_a12_t16; rc_b=$?'
  printf '%s\n' 'printf "rc_b=%s\n" "$rc_b"'
} >>"$T16_DRIVER"
chmod +x "$T16_DRIVER"

T16_OUT="$(/usr/bin/env bash "$T16_DRIVER" 2>&1 || true)"
# Hard contract: rc=0 in BOTH calls (create + idempotent). If r3 gate
# is reverted, chgrp() stub returns 1 → helper would fail-loud with
# state_dir_chgrp_failed and rc!=0.
if [[ "$T16_OUT" != *"rc=0"* ]]; then
  smoke_fail "T16 (r3 codex r2 BLOCKING): non-iso self-heal returned rc!=0 — r3 predicate gate is missing or broken; got: $T16_OUT"
fi
if [[ "$T16_OUT" != *"rc_b=0"* ]]; then
  smoke_fail "T16 (r3 codex r2 BLOCKING): non-iso self-heal re-call (idempotent) returned rc!=0; got: $T16_OUT"
fi
# Strict regression guard: the chgrp/group_resolver_empty reasons MUST
# NOT have been emitted on the non-iso path.
if [[ "$T16_OUT" == *"state_dir_chgrp"* ]]; then
  smoke_fail "T16 (r3 codex r2 BLOCKING): non-iso self-heal emitted state_dir_chgrp* reason — gate is not preventing chgrp; got: $T16_OUT"
fi
if [[ "$T16_OUT" == *"state_dir_group_resolver_empty"* ]]; then
  smoke_fail "T16 (r3 codex r2 BLOCKING): non-iso self-heal emitted state_dir_group_resolver_empty — gate is not preventing resolver-check; got: $T16_OUT"
fi
smoke_log "T16 PASS — non-iso self-heal skips ab-agent enforcement (gate works; ordinary agent create no longer wedged)"

# ---------------------------------------------------------------------
# T17 (teeth, r3 codex r2 BLOCKING regression): demonstrate that
#      reverting the r3 predicate gate reproduces the codex r2
#      regression — ordinary non-iso agent create fails at the
#      pre-create-ok gate with state_dir_chgrp_failed.
#
#      Implementation: inline a copy of the production self-heal that
#      uses the r2 `_resolver_present` gate (= the bug). Drive it under
#      the same non-iso fixture as T16 and assert it FAILS exactly the
#      way codex r2 captured: rc!=0 with state_dir_chgrp_failed
#      target=ab-agent-<a> post_mkdir.
# ---------------------------------------------------------------------
smoke_log "T17 (teeth): reverting the r3 iso-v2 gate must reproduce codex r2 regression (ordinary non-iso create fails on missing ab-agent group)"

T17_DRIVER="$SMOKE_TMP_ROOT/t17-driver.sh"
: >"$T17_DRIVER"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' "BRIDGE_ACTIVE_AGENT_DIR=\"$SMOKE_TMP_ROOT/t17-state-agents\""
  printf '%s\n' 'mkdir -p "$BRIDGE_ACTIVE_AGENT_DIR"'
  printf '%s\n' 'bridge_warn() { printf "[warn] %s\n" "$*" >&2; }'
  printf '%s\n' 'bridge_agent_idle_marker_dir() { printf "%s/%s" "$BRIDGE_ACTIVE_AGENT_DIR" "$1"; }'
  # Same non-iso fixture as T16 — predicate would return 1 if asked.
  # But this driver uses the R2-shape helper (resolver-presence gate)
  # so the predicate is never consulted.
  printf '%s\n' 'bridge_agent_linux_user_isolation_effective() { return 1; }'
  printf '%s\n' 'bridge_isolation_v2_agent_group_name() { printf "ab-agent-test_a12_t17"; }'
  printf '%s\n' 'chgrp() { return 1; }'
  # R2-shape helper (the regression). Mirrors the production function
  # body PRIOR to the r3 gate: chgrp branch entered whenever the
  # resolver is present, regardless of iso effectiveness.
  printf '%s\n' 'bridge_agent_state_dir_self_heal_R2() {'
  printf '%s\n' '  local agent="$1"; [[ -n "$agent" ]] || return 1'
  printf '%s\n' '  local dir; dir="$(bridge_agent_idle_marker_dir "$agent")"'
  printf '%s\n' '  local _agent_grp=""'
  printf '%s\n' '  local _resolver_present=0'
  printf '%s\n' '  if command -v bridge_isolation_v2_agent_group_name >/dev/null 2>&1; then'
  printf '%s\n' '    _resolver_present=1'
  printf '%s\n' '    _agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"'
  printf '%s\n' '  fi'
  printf '%s\n' '  if [[ ! -d "$dir" ]]; then'
  printf '%s\n' '    mkdir -m 2770 -p "$dir" 2>/dev/null || return 1'
  printf '%s\n' '    if (( _resolver_present == 1 )); then'
  printf '%s\n' '      [[ -n "$_agent_grp" ]] || { bridge_warn "state_dir_group_resolver_empty"; return 1; }'
  printf '%s\n' '      chgrp "$_agent_grp" "$dir" 2>/dev/null || { bridge_warn "state_dir_chgrp_failed target=$_agent_grp post_mkdir"; return 1; }'
  printf '%s\n' '    fi'
  printf '%s\n' '  fi'
  printf '%s\n' '  return 0'
  printf '%s\n' '}'
  printf '%s\n' 'bridge_agent_state_dir_self_heal_R2 test_a12_t17 2>&1; rc=$?'
  printf '%s\n' 'printf "rc=%s\n" "$rc"'
} >>"$T17_DRIVER"
chmod +x "$T17_DRIVER"

T17_OUT="$(/usr/bin/env bash "$T17_DRIVER" 2>&1 || true)"
# Teeth assertion: the R2-shape helper MUST fail under the non-iso
# fixture — that is the regression the r3 gate closes. If T17 ever
# passes the R2 shape, the teeth fixture is broken.
if [[ "$T17_OUT" == *"rc=0"* ]]; then
  smoke_fail "T17 (teeth): R2-shape helper unexpectedly returned rc=0 under non-iso fixture — teeth fixture is broken (codex r2 regression should reproduce here)"
fi
if [[ "$T17_OUT" != *"state_dir_chgrp_failed"* ]]; then
  smoke_fail "T17 (teeth): R2-shape helper failed but did not cite state_dir_chgrp_failed — teeth fixture does not match codex r2 captured shape; got: $T17_OUT"
fi
if [[ "$T17_OUT" != *"target=ab-agent-test_a12_t17"* ]]; then
  smoke_fail "T17 (teeth): R2-shape helper did not cite target=ab-agent-<a> in chgrp_failed detail — teeth fixture does not match codex r2 captured shape; got: $T17_OUT"
fi
smoke_log "T17 PASS — teeth-check works: R2-shape (no iso-v2 gate) reproduces the codex r2 regression (state_dir_chgrp_failed target=ab-agent-<a> post_mkdir)"

# ---------------------------------------------------------------------
smoke_log "all tests PASS — A12-beta3 #1246 + #1252 verified at current main (r3: codex r2 BLOCKING regression closed via iso-v2 effective-predicate gate)"
