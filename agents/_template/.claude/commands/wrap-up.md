---
description: Append the current session's work summary to today's daily note before you exit or compact.
---

This session's work needs to land in today's daily note so the next
session — and any reviewer — can pick up without re-reading the whole
transcript. Run this before you `/compact` or exit. You can re-run it
freely; the tool replaces your existing section for this session.

## How to write the summary

Produce plain markdown with these three subsections. No YAML, no front
matter — the storage layer handles metadata for you.

```
## 작업 요약
- (3~5 bullet: 이 세션에서 실제로 일어난 일)

## 결정 사항
- (이 세션에서 내려진 의사결정. 없으면 생략)

## 다음 세션 주의사항
- (이어서 할 일, 기다리는 응답, 주의할 상태)
```

Keep each bullet concrete. Reference file paths, task ids, PR numbers
directly. If nothing changed in a subsection this session, leave the
bullets empty — don't invent filler.

## How to run it

The tool reads the summary from stdin and routes it into
`~/.agent-bridge/agents/<agent>/memory/<today>.md` under a section keyed
by this session's id. Run:

```bash
# The daily note lives under the agent's bridge runtime home, which is
# not always the same as the session's working directory. Resolve them
# separately.
#
#   AGENT_HOME  — where `memory/<today>.md` gets written. Always the
#                 bridge-managed home; matches `bridge-agent.sh`
#                 scaffolding and PR 1A's autoMemoryDirectory seed.
#   WORKDIR     — the session's cwd, used by current-session-id to
#                 derive the `~/.claude/projects/<slug>/` lookup key.
#                 Claude scopes transcripts by the git root of the
#                 session cwd, so conflating this with AGENT_HOME sends
#                 the scan to a directory that has no jsonl files.
if [[ -n "${BRIDGE_AGENT_HOME_ROOT:-}" ]]; then
  AGENT_HOME="$BRIDGE_AGENT_HOME_ROOT/$BRIDGE_AGENT_ID"
else
  AGENT_HOME="$HOME/.agent-bridge/agents/$BRIDGE_AGENT_ID"
fi
WORKDIR="${BRIDGE_AGENT_WORKDIR:-$AGENT_HOME}"

# Issue #412 Track C: under linux-user isolation `~/.claude/projects/`
# resolves to the isolated UID's home (where Claude actually wrote the
# transcripts), but $WORKDIR is the controller-side path the agent was
# spawned in. The default `--claude-projects` lookup is rooted at the
# calling shell's $HOME, which already matches the isolated home when
# the launcher runs us under sudo -n -u, but `--transcripts-home "$HOME"`
# decouples the lookup from any wrapper that might reset HOME and makes
# the isolation contract explicit. Shared-mode agents skip the override.
CSI_ARGS=(--agent "$BRIDGE_AGENT_ID" --home "$WORKDIR")
if [[ -n "${BRIDGE_AGENT_OS_USER:-}" ]]; then
  CSI_ARGS+=(--transcripts-home "$HOME")
fi
SESSION_ID="$(python3 ~/.agent-bridge/bridge-memory.py current-session-id \
    "${CSI_ARGS[@]}")"
python3 ~/.agent-bridge/bridge-memory.py daily-append \
    --agent "$BRIDGE_AGENT_ID" \
    --home "$AGENT_HOME" \
    --session-id "$SESSION_ID" \
    --writer session \
    --content-from-stdin <<'MD'
## 작업 요약
- (...)

## 결정 사항
- (...)

## 다음 세션 주의사항
- (...)
MD
```

Use the single-quoted heredoc (`<<'MD'`) so variables inside the body
are not expanded.

## What happens next

- First run of the day: the daily note is created with a stable metadata
  comment (`<!-- bridge-daily-meta: {...} -->`) on line 1 plus a level-1
  title.
- Subsequent runs in the same session: your section is replaced in
  place; `last_reconciled_at` is updated.
- New session on the same day: a new section is appended, and the
  metadata's `session_ids` list grows.

If the command prints a path and one of `appended` / `replaced`, you are
done. Any non-zero exit means the write failed; read the stderr message
and either fix the input or escalate to the admin agent.

## When not to use it

- Codex-run sessions: the `current-session-id` helper looks at
  `~/.claude/projects/`, which codex does not populate. Use a direct
  `--session-id <uuid>` if the admin provides one; otherwise skip and
  rely on the cron fallback landing in PR 2B.
- If `$BRIDGE_AGENT_ID` is unset, the command fails loudly. That means
  you are probably running outside a bridge-scaffolded home — do not
  guess an agent id.
