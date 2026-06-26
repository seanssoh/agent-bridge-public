#!/usr/bin/env bash
# shellcheck shell=bash
# smoke-14577-thread-created-signal.sh
#
# Issue #14577 — one-time "thread created" awareness signal to the MAIN agent
# leg (Approach B: lazy first-dispatch loopback). When a thread is created under
# a configured auto-session channel, the MAIN session gets a ONE-TIME awareness
# row (thread id/title + the fact a thread-session leg is bound) — and the
# thread's conversation body is NEVER relayed to main.
#
# This smoke drives the REAL unit-under-test decisions end to end against an
# isolated BRIDGE_HOME, with NO live Claude/Discord/tmux:
#   * thread_session_dispatcher.py dispatch (dry-run + mock) — the first_dispatch
#     flag that server.ts keys the signal on.
#   * thread_task_create.py create — the producer shim that writes the loopback
#     awareness task, with `agb task create` STUBBED by a recorder so the unit
#     under test is the GUARD/EMIT decision, not a live queue write.
#   * server.ts source — structurally pinned (teeth) for the gate, the explicit
#     ledger --root (must-fix A), the bot/self filter (must-fix B), the
#     sanitizer on the arg path (must-fix C), and the lifecycle env gate (G2).
#
# Test plan:
#   D1  fresh thread  -> dispatcher JSON first_dispatch=true.
#   D2  resumed thread -> dispatcher JSON first_dispatch absent/false.
#   S1  first_dispatch=true -> thread_task_create invoked with --kind
#       thread_created, --from==--to==parent_agent, [thread-created] title
#       prefix, AND an explicit --root == the dispatcher's registry .threads root.
#   S2  first_dispatch!=true -> NO create.
#   B1  no-body-leak: the inbound message string is ABSENT from the rendered task
#       body (only static awareness metadata is relayed).
#   A1  archive signal body carries the summarize/absorb directive (summarize +
#       thread_recall) and is body-free (inbound message string ABSENT).
#   I1  two identical thread_created creates dedupe to ONE task.
#   L1  thread_archived lifecycle synthetic message_id is a DISTINCT ledger row
#       (vs the create row) and re-runs dedupe.
#   G1  gate: unset/mismatched parent channel -> no signal (server.ts gate).
#   G2  archive default ON: unset DISCORD_THREAD_LIFECYCLE_NOTIFY -> archive
#       listener fires; =created -> archive suppressed; NO threadDelete listener
#       at all (delete = no-op) (server.ts source gate).
#
# Footgun: every python3 subprocess reads inputs via argv or file paths, never
# stdin; the agb stub records to a file.

set -euo pipefail

SMOKE_NAME="14577-thread-created-signal"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# The Discord plugin (and its thread-session shims) live under
# plugins/discord/ within the repo; lib.sh pins $SMOKE_REPO_ROOT.
DISPATCHER="$SMOKE_REPO_ROOT/plugins/discord/thread-session/thread_session_dispatcher.py"
TASK_CREATE="$SMOKE_REPO_ROOT/plugins/discord/thread-session/thread_task_create.py"
SERVER_TS="$SMOKE_REPO_ROOT/plugins/discord/server.ts"

smoke_require_cmd python3
[[ -f "$DISPATCHER" ]]   || smoke_fail "dispatcher not found: $DISPATCHER"
[[ -f "$TASK_CREATE" ]]  || smoke_fail "task-create shim not found: $TASK_CREATE"
[[ -f "$SERVER_TS" ]]    || smoke_fail "server.ts not found: $SERVER_TS"

smoke_make_temp_root

PARENT_AGENT="owning-agent"
PARENT_CHANNEL="parent-chan-123"
THREAD_ID="discord-thread-9001"
INBOUND_MSG="SECRET-INBOUND-BODY-do-not-leak-1234"

# Owning-agent workspace; the dispatcher's registry root is <workdir>/.threads —
# the SAME root server.ts must pass to the shim as --root (must-fix A).
AGENT_WORKDIR="$SMOKE_TMP_ROOT/owning-agent/workdir"
AGENT_HOME="$SMOKE_TMP_ROOT/owning-agent/home"
AGENT_CONFIG_DIR="$AGENT_HOME/.claude"
LEDGER_ROOT="$AGENT_WORKDIR/.threads"
mkdir -p "$AGENT_WORKDIR" "$AGENT_CONFIG_DIR"
printf '# soul\n'     >"$AGENT_WORKDIR/SOUL.md"
printf '# contract\n' >"$AGENT_WORKDIR/CLAUDE.md"

# --- agb stub: a recorder for `task create` -------------------------------
# server.ts shells thread_task_create.py, which shells "<bridge_home>/agent-bridge
# task create ...". We isolate BRIDGE_HOME and drop a fake agent-bridge that
# records its argv and emits the "created task #<n>" line the shim parses. This
# makes the GUARD/EMIT decision (kind, from/to, title, root, body) the unit under
# test, not a live queue write.
BRIDGE_HOME_STUB="$SMOKE_TMP_ROOT/bridge-home"
mkdir -p "$BRIDGE_HOME_STUB"
AGB_LOG="$SMOKE_TMP_ROOT/agb-create.log"
: >"$AGB_LOG"
cat >"$BRIDGE_HOME_STUB/agent-bridge" <<EOF  # noqa: iso-helper-boundary — controller-only smoke stub writer, no real iso boundary
#!/usr/bin/env bash
# Recorder stub for \`agent-bridge task create\`. Logs argv (NUL-joined per call)
# and the --body-file CONTENTS, then emits the parseable success line.
{
  printf 'CALL'
  for a in "\$@"; do printf '\037%s' "\$a"; done
  printf '\n'
} >>"$AGB_LOG"
# Capture the rendered body so B1 can prove no-body-leak. Copy the whole body
# file out verbatim (multi-line) so the assertion can scan the full rendered body.
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "--body-file" ]]; then
    cp "\$a" "$SMOKE_TMP_ROOT/last-body.md"
  fi
  prev="\$a"
done
echo "created task #777 for stub"
EOF
chmod +x "$BRIDGE_HOME_STUB/agent-bridge"

# dispatch_real_json: non-dry mock dispatch (mints the registry row). Echoes JSON.
# This is the path server.ts actually consumes; the dispatcher only emits
# first_dispatch on the real (non-dry) success JSON (server.ts never dry-runs).
dispatch_real_json() {
  local thread_id="$1" message_id="$2"
  BRIDGE_AGENT_ID="$PARENT_AGENT" python3 "$DISPATCHER" \
    --workdir "$AGENT_WORKDIR" --home "$AGENT_HOME" --config-dir "$AGENT_CONFIG_DIR" \
    dispatch --json \
    --thread-id "$thread_id" --channel-name "qa thread" \
    --parent-channel-id "$PARENT_CHANNEL" \
    --message-id "$message_id" --user tester --message "$INBOUND_MSG" \
    --mock-response "ok" --mock-seed "seed" --mock-summary "sum"
}

# emit_signal: model server.ts's emit — shell the producer shim the SAME way,
# with the explicit ledger --root (must-fix A) and a kind-appropriate STATIC body
# (no-body-leak). thread_created -> static awareness metadata; thread_archived ->
# the "summarize & absorb" directive that points main at its OWN thread_recall
# corpus. Neither body ever carries the inbound thread conversation text.
emit_signal() {
  local kind="$1" message_id="$2" body
  if [[ "$kind" == "thread_archived" ]]; then
    body="Thread $THREAD_ID ('qa thread') under $PARENT_CHANNEL was archived — work in it is likely complete. ACTION: summarize what happened in this thread and absorb it into the main session — use thread_recall to search your OWN thread corpus for this thread_id, inject the outcome into your working context, and update memory if warranted. This signal carries only metadata; the thread content is available through your own recall tool (same-agent boundary, not relayed here)."
  else
    body="Thread lifecycle awareness signal (one-time). event: $kind thread_id: $THREAD_ID — body NOT relayed."
  fi
  BRIDGE_HOME="$BRIDGE_HOME_STUB" \
  BRIDGE_AGENT_ID="$PARENT_AGENT" \
  BRIDGE_THREAD_PARENT_AGENT="$PARENT_AGENT" \
    python3 "$TASK_CREATE" \
      --root "$LEDGER_ROOT" \
      create \
      --transport discord \
      --thread-id "$THREAD_ID" \
      --message-id "$message_id" \
      --kind "$kind" \
      --source-user tester \
      --risk low \
      --title "" \
      --body "$body" \
      --reply-channel-id "$THREAD_ID" \
      --reply-thread-id "$THREAD_ID" \
      --parent-channel-id "$PARENT_CHANNEL"
}

# =====================================================================
# D1 / D2 — dispatcher first_dispatch flag.
# =====================================================================

smoke_run "D1 fresh thread -> dispatcher JSON first_dispatch=true" : ; {
  # FRESH thread id with no prior registry row -> first dispatch CREATES it.
  out="$(dispatch_real_json "$THREAD_ID" d1-fresh)"
  python3 -c '
import json, sys
p = json.loads(sys.argv[1])
fd = p.get("first_dispatch")
assert fd is True, "expected first_dispatch=true, got %r" % (fd,)
' "$out" || smoke_fail "D1 first_dispatch was not true on a fresh thread"
}

smoke_run "D2 resumed thread -> dispatcher JSON first_dispatch absent/false" : ; {
  # The D1 dispatch above already minted the registry row for $THREAD_ID; a
  # second dispatch on the SAME thread is a resume -> first_dispatch must clear.
  out="$(dispatch_real_json "$THREAD_ID" second-real)"
  python3 -c '
import json, sys
p = json.loads(sys.argv[1])
fd = p.get("first_dispatch")
assert fd in (False, None), "expected first_dispatch absent/false on resume, got %r" % (fd,)
' "$out" || smoke_fail "D2 first_dispatch must be absent/false on a resumed thread"
}

# =====================================================================
# S1 / S2 / B1 — server.ts emit decision via the producer shim.
# =====================================================================

smoke_run "S1 first_dispatch=true -> create with thread_created kind, loopback from==to, [thread-created] title, explicit --root" : ; {
  : >"$AGB_LOG"
  # Run the emit; capture the shim's JSON (proves kind flowed through) AND the
  # downstream agb task-create argv (proves from/to/title loopback shape).
  shim_out="$(emit_signal thread_created "lifecycle-create-$THREAD_ID")"
  call="$(grep '^CALL' "$AGB_LOG" | head -1)"
  [[ -n "$call" ]] || smoke_fail "S1 producer shim never invoked agb task create"
  # The agb call (from thread_task_create.run_queue_create) carries the loopback
  # --from==--to==parent_agent and the [thread-created] default title.
  python3 -c '
import sys
parts = sys.argv[1].split("\x1f")[1:]  # drop the leading "CALL"
def val(flag):
    return parts[parts.index(flag)+1] if flag in parts else None
assert "create" in parts, "missing create subcommand"
assert val("--from") == val("--to") == "owning-agent", "from/to: %r/%r" % (val("--from"), val("--to"))
title = val("--title") or ""
assert title.startswith("[thread-created]"), "title prefix: %r" % (title,)
' "$call" || smoke_fail "S1 agb call shape wrong (from/to/title)"
  # The shim recorded producer_kind=thread_created in its idempotency key (proves
  # --kind thread_created flowed through create_or_get unchanged).
  python3 -c '
import json, sys
p = json.loads(sys.argv[1])
key = p["event"]["idempotency_key"]
assert key["producer_kind"] == "thread_created", "producer_kind=%r" % (key["producer_kind"],)
assert key["parent_agent"] == "owning-agent", "parent_agent=%r" % (key["parent_agent"],)
' "$shim_out" || smoke_fail "S1 --kind thread_created did not flow through to the ledger key"
  # The correlation ledger must be written under the EXPLICIT --root == the
  # dispatcher registry .threads root (must-fix A: shared dedup ledger).
  smoke_assert_file_exists "$LEDGER_ROOT/correlation.json" \
    "S1 correlation ledger written under the shared dispatcher root ($LEDGER_ROOT)"
}

smoke_run "S2 first_dispatch!=true -> NO create (no producer invocation)" : ; {
  # Model server.ts: when result.first_dispatch !== true, emit is never called.
  : >"$AGB_LOG"
  out="$(dispatch_real_json "$THREAD_ID" s2-resume)"  # resumed -> first_dispatch absent/false
  fd="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("first_dispatch"))' "$out")"
  if [[ "$fd" == "True" ]]; then
    smoke_fail "S2 precondition broken: resumed dispatch reported first_dispatch=True"
  fi
  # Because first_dispatch != true, server.ts does NOT call the shim.
  if grep -q '^CALL' "$AGB_LOG"; then
    smoke_fail "S2 producer shim must NOT be invoked when first_dispatch!=true"
  fi
  smoke_log "S2 OK: first_dispatch=$fd -> no create"
}

smoke_run "B1 no-body-leak: inbound message string is ABSENT from the rendered task body" : ; {
  rm -f "$SMOKE_TMP_ROOT/last-body.md"
  emit_signal thread_created "lifecycle-create-b1-$THREAD_ID" >/dev/null
  [[ -f "$SMOKE_TMP_ROOT/last-body.md" ]] || smoke_fail "B1 no body-file content captured"
  body="$(cat "$SMOKE_TMP_ROOT/last-body.md")"
  smoke_assert_not_contains "$body" "$INBOUND_MSG" \
    "B1 the inbound thread message body must NEVER appear in the signal task body"
  smoke_assert_contains "$body" "thread_created" \
    "B1 the signal body carries static awareness metadata (event kind)"
}

smoke_run "A1 archive signal body carries the summarize/absorb directive (body-free)" : ; {
  # #14641: the thread_archived signal is a "summarize & absorb" TRIGGER. Its body
  # must DIRECT main to summarize and recall its OWN thread corpus (thread_recall)
  # — and, like every lifecycle signal, must NEVER carry the inbound thread text.
  rm -f "$SMOKE_TMP_ROOT/last-body.md"
  emit_signal thread_archived "lifecycle-archive-a1" >/dev/null
  [[ -f "$SMOKE_TMP_ROOT/last-body.md" ]] || smoke_fail "A1 no body-file content captured"
  body="$(cat "$SMOKE_TMP_ROOT/last-body.md")"
  smoke_assert_contains "$body" "summarize" \
    "A1 the archive signal body must direct the main leg to summarize the thread"
  smoke_assert_contains "$body" "thread_recall" \
    "A1 the archive signal body must point main at its OWN thread_recall corpus"
  smoke_assert_not_contains "$body" "$INBOUND_MSG" \
    "A1 the inbound thread message body must NEVER appear in the archive signal body"
}

# =====================================================================
# I1 / L1 — correlation-ledger idempotency + distinct lifecycle rows.
# =====================================================================

smoke_run "I1 two identical thread_created creates dedupe to ONE task" : ; {
  first="$(emit_signal thread_created "lifecycle-create-i1-$THREAD_ID")"
  second="$(emit_signal thread_created "lifecycle-create-i1-$THREAD_ID")"
  python3 -c '
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert a["deduped"] is False, "first create should NOT be deduped"
assert b["deduped"] is True, "second identical create MUST dedupe"
assert a["event_id"] == b["event_id"], "same synthetic message_id -> same event row"
' "$first" "$second" || smoke_fail "I1 idempotency failed"
}

smoke_run "L1 thread_archived synthetic message_id is a DISTINCT ledger row; re-run dedupes" : ; {
  created="$(emit_signal thread_created "lifecycle-create-l1-$THREAD_ID")"
  archived_first="$(emit_signal thread_archived "lifecycle-archive")"
  archived_again="$(emit_signal thread_archived "lifecycle-archive")"
  python3 -c '
import json, sys
c, k1, k2 = (json.loads(a) for a in sys.argv[1:4])
assert c["event_id"] != k1["event_id"], "create vs archive must be DISTINCT ledger rows"
assert k1["deduped"] is False, "first archive create should not be deduped"
assert k2["deduped"] is True, "re-run of the archive signal MUST dedupe"
assert k1["event_id"] == k2["event_id"], "stable archive message_id -> same row on re-run"
' "$created" "$archived_first" "$archived_again" || smoke_fail "L1 distinct-row / dedupe failed"
}

# =====================================================================
# G1 — server.ts gate: unset / mismatched parent channel -> no signal.
# =====================================================================

smoke_run "G1 gate: unset/mismatched parent channel -> no signal (server.ts gate)" : ; {
  # server.ts emit + maybeHandleThreadSession bail when
  # THREAD_AUTO_SESSION_CHANNEL_ID is '' OR parentId !== it. Pin the source gate.
  grep -q "THREAD_AUTO_SESSION_CHANNEL_ID === '' || opts.parentId !== THREAD_AUTO_SESSION_CHANNEL_ID" "$SERVER_TS" \
    || smoke_fail "G1 emitThreadLifecycleSignal must gate on parentId === THREAD_AUTO_SESSION_CHANNEL_ID"
  grep -q "THREAD_AUTO_SESSION_CHANNEL_ID === '' || parentId !== THREAD_AUTO_SESSION_CHANNEL_ID" "$SERVER_TS" \
    || smoke_fail "G1 maybeHandleThreadSession gate must remain (no signal outside configured channel)"
}

# =====================================================================
# G2 — archive default-ON env gate + delete is a no-op (no listener).
# =====================================================================

smoke_run "G2 archive default ON; =created suppresses; NO threadDelete listener (delete=no-op)" : ; {
  # Default-ON archive gate: unset env -> '' -> THREAD_ARCHIVE_NOTIFY true; only
  # the literal 'created' opts OUT. Pin the new default-on gate expression.
  grep -q "const THREAD_LIFECYCLE_NOTIFY = process.env.DISCORD_THREAD_LIFECYCLE_NOTIFY ?? ''" "$SERVER_TS" \
    || smoke_fail "G2 DISCORD_THREAD_LIFECYCLE_NOTIFY must default to '' (unset) so archive stays ON"
  grep -q "const THREAD_ARCHIVE_NOTIFY = THREAD_LIFECYCLE_NOTIFY !== 'created'" "$SERVER_TS" \
    || smoke_fail "G2 archive must default ON: THREAD_ARCHIVE_NOTIFY = NOTIFY !== 'created' ('created' = opt-out)"
  # The archive listener is behind the new default-on gate.
  grep -q "if (THREAD_ARCHIVE_NOTIFY) {" "$SERVER_TS" \
    || smoke_fail "G2 the threadUpdate-archived listener must be behind THREAD_ARCHIVE_NOTIFY"
  # The old opt-in 'all' gate is GONE.
  if grep -q "THREAD_LIFECYCLE_NOTIFY === 'all'" "$SERVER_TS"; then
    smoke_fail "G2 the old THREAD_LIFECYCLE_NOTIFY === 'all' gate must be removed"
  fi
  # Delete is intentionally a no-op: there must be NO threadDelete listener at all.
  if grep -q "client.on('threadDelete'" "$SERVER_TS"; then
    smoke_fail "G2 threadDelete listener must be REMOVED (delete = no-op)"
  fi
  # Archive still rides threadUpdate, only on the archived transition.
  grep -q "client.on('threadUpdate'" "$SERVER_TS" \
    || smoke_fail "G2 threadUpdate listener missing"
  # threadUpdate fires ONLY on the archived transition; ambiguous prior state skips.
  grep -q "oldThread?.archived !== false || newThread?.archived !== true" "$SERVER_TS" \
    || smoke_fail "G2 threadUpdate must fire only on the !old.archived && new.archived transition (skip ambiguous)"
}

# =====================================================================
# Teeth — pin the must-fixes structurally in server.ts.
# =====================================================================

smoke_run "T teeth: must-fix A explicit root, B bot/self filter, C arg sanitizer present" : ; {
  # A: server-side root computed as <workdir>/.threads and passed as --root.
  grep -q "function threadLedgerRoot()" "$SERVER_TS" \
    || smoke_fail "teeth(A): threadLedgerRoot() must compute the shared ledger root"
  grep -q "'--root', root," "$SERVER_TS" \
    || smoke_fail "teeth(A): the producer args must pass the explicit --root before create"
  # B: bot/self filter — never signal thread_created for the bot's own thread.
  grep -q "ownerId === client.user?.id" "$SERVER_TS" \
    || smoke_fail "teeth(B): bot/self filter (thread.ownerId === client.user.id) must be present"
  # C: sanitizer reused on thread name + username before the arg path.
  grep -q "function safeArgText(" "$SERVER_TS" \
    || smoke_fail "teeth(C): safeArgText sanitizer must exist"
  grep -q "safeArgText(opts.threadName)" "$SERVER_TS" \
    || smoke_fail "teeth(C): thread name must be sanitized before the arg path"
  grep -q "safeArgText(opts.username)" "$SERVER_TS" \
    || smoke_fail "teeth(C): username must be sanitized before the arg path"
}

smoke_log "all checks passed"
