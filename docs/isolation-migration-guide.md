# Operator Migration Guide: shared → linux-user isolation

End-to-end, operator-runnable walkthrough for migrating a Linux host from
`shared` isolation to per-UID `linux-user` isolation, **one agent at a
time**, without taking the rest of the fleet down.

This guide stitches together the helpers and checks that already exist:

- `agent-bridge isolate` / `agent-bridge unisolate`
  (see [`lib/bridge-migration.sh`](../lib/bridge-migration.sh)) — the
  migration CLI itself.
- [Linux Per-UID Isolation Acceptance Runbook](./isolation-acceptance-runbook.md)
  — the after-the-fact validation checklist. This guide points back at
  that document rather than duplicating it.
- [Platform Support](./platform-support.md) — scope and the macOS
  exclusion.

Each step below follows the same shape as the acceptance runbook:
`command` → `expected output` → explicit **PASS / FAIL** signal.

---

## Important caveat — read before running anything

`agent-bridge isolate` sets up metadata, the dedicated OS user, ACL
plumbing, and (when `--install-sudoers` is passed or the entry is
installed manually) the sudoers drop-in that `bridge-start.sh` needs
for the runtime UID switch. **The runtime UID switch itself is
conditional**: if the sudoers entry is missing, `bridge-start.sh`
falls back to shared-mode launch with a loud warning rather than
refusing to start.

After this guide has been run on an agent, expect:

- Filesystem containment on `/home/agent-bridge-<slug>` is in effect
  (mode `0700`, owned by the new OS user).
- Per-agent ACLs on workdir / state / log / queue-gateway request+response
  directories are installed (via `bridge_linux_prepare_agent_isolation`).
- A per-agent scoped roster snapshot at
  `~/.agent-bridge/state/agents/<agent>/agent-env.sh` (controller-owned,
  `u:<os_user>:r--` ACL) so the isolated UID can resolve its own roster
  entry without read access to the shared `agent-roster.local.sh`. This
  is how `bridge-run.sh` and the hook runtime load roster state on an
  isolated host; see issue `#116`.
- For Claude-engine agents, a symlink
  `/home/agent-bridge-<slug>/.claude/.credentials.json` pointing at the
  operator's `~/.claude/.credentials.json`, plus `u:<os_user>:r--` ACL
  on the target file and a default ACL on the operator's `.claude/` so
  Claude's atomic-rename re-auth still inherits the grant. This is the
  only part of the operator's `.claude/` that is exposed — projects,
  sessions, plugins, and settings remain per-agent. Run `claude login`
  as the operator first if `~/.claude/.credentials.json` does not yet
  exist; `isolate` warns and skips that step otherwise. See issue
  `#125`.
- Runtime UID switch on tmux launch — **only if** the sudoers drop-in
  exists. Install it with `agent-bridge isolate <agent> --install-sudoers`
  (validated via `visudo -cf`) or manually per the hint printed by
  `isolate` when `--install-sudoers` is omitted. Without it, the agent
  still runs under the operator UID and audit `acting_os_uid` records
  the operator.
- Audit attribution per the acceptance runbook
  ([§3](./isolation-acceptance-runbook.md#3-audit-attribution-carries-the-acting-uid))
  becomes accurate once both migration and sudoers are in place; until
  sudoers lands, it continues to report the operator.

---

## 1. Prerequisites

Before migrating any agent, verify the host and the target agent meet
these preconditions. If any fails, stop — do not work around them.

### 1.1 Linux host

```bash
uname -s
```

Expected output:

```
Linux
```

- **PASS** if output is `Linux`.
- **FAIL** if output is `Darwin`. The migration helper refuses on macOS
  by design (see [Platform Support](./platform-support.md#agent-bridge-isolate-on-macos));
  there is no supported path. Stop here.

### 1.2 Sudo available

```bash
sudo -n true && echo ok
```

- **PASS** if it prints `ok` (passwordless) or succeeds after one prompt.
- **FAIL** if sudo is not installed or the operator account cannot
  elevate. `useradd` and `chown` require root.

### 1.3 `setfacl` available (acl package)

`bridge_linux_prepare_agent_isolation` uses `setfacl` to install the
traverse-chain ACLs that the acceptance runbook's §2 containment checks
depend on. `bridge_linux_require_setfacl` (`lib/bridge-agents.sh`)
hard-fails when the binary is absent.

```bash
command -v setfacl
```

- **PASS** if the path prints (`/usr/bin/setfacl` on most distros).
- **FAIL** if nothing prints. Install the `acl` package
  (`apt-get install -y acl` on Debian/Ubuntu, `dnf install -y acl` on
  RHEL/Fedora) before continuing. Migrating without `setfacl` will
  leave per-agent ACLs uninstalled and acceptance-runbook §2.1/§2.4
  will fail.

### 1.4 Agent currently in shared mode

The migration helper refuses to re-isolate an already-isolated agent,
but confirm anyway so you know what you are changing:

```bash
grep -E 'BRIDGE_AGENT_ISOLATION_MODE\["<agent>"\]' \
  ~/.agent-bridge/agent-roster.local.sh || echo "(unset)"
```

- **PASS** if the line is missing, or the value is `"shared"`.
- **FAIL** if the value is already `"linux-user"`. That agent has
  already been migrated; skip to §7 (verify) or §8 (rollback) as needed.

### 1.5 No live tmux session for the agent

```bash
agent-bridge agent show <agent>
```

Look at the `session` / `active` fields (or run `tmux has-session -t
<session>` directly).

- **PASS** if no tmux session is attached for this agent.
- **FAIL** if the agent is live. Proceed to §4 to stop it; do not
  attempt to `isolate` a running agent — the helper will refuse.

---

## 2. Per-agent pre-check

Capture the current state so you know what "before" looks like and so
you can compare after rollback if anything goes wrong.

### 2.1 Current roster metadata

```bash
grep -E 'BRIDGE_AGENT_(ISOLATION_MODE|OS_USER)\["<agent>"\]' \
  ~/.agent-bridge/agent-roster.local.sh || true
```

Expected output: either empty (defaults to shared) or both keys present
with the shared-mode defaults. Save this block; you will reference it
in §8 if you need to roll back.

### 2.2 Live session state

```bash
agent-bridge agent show <agent>
```

Note whether the agent is active. If it is, plan for the stop step in §4.

### 2.3 Channel plugin port (if any)

If this agent runs a channel plugin (Discord / Telegram / Teams /
mailbot), find the port it currently holds so you can confirm it
releases cleanly after stop. Plugin ports live in per-channel env
files under the agent's workdir, **not** in the roster:

```bash
grep -h -E '^(DISCORD|TELEGRAM|TEAMS)_WEBHOOK_PORT=' \
  ~/.agent-bridge/agents/<agent>/.discord/.env \
  ~/.agent-bridge/agents/<agent>/.telegram/.env \
  ~/.agent-bridge/agents/<agent>/.teams/.env 2>/dev/null \
  || echo "(no plugin port assigned)"
```

If a port is assigned, spot-check that it is held:

```bash
ss -ltnp | grep ":<port>" || echo "(port not held)"
```

Record the port for the check in §4.3.

---

## 3. Decide migration order for the batch

If you are converting more than one agent, do them one at a time and
plan the order up front.

- **Migrate the admin agent last.** The admin agent is the escalation
  target and the operator's fallback when another agent mis-behaves
  mid-migration. Keep it reachable under its pre-migration identity
  until every other agent has been flipped and verified. Once the rest
  of the fleet is clean, migrate admin last.
- **One at a time.** The helper does not lock the roster or the host,
  so running two `isolate` invocations in parallel can interleave
  `useradd`, `chown`, and roster-file writes. Wait for each agent to
  reach §7 PASS before starting the next.
- **Low-traffic window.** Each per-agent migration briefly stops that
  agent's tmux session and releases its channel plugin port. If the
  agent handles time-sensitive inbound channel traffic, route around
  it (mute, pause, or silence the channel) first.

---

## 4. Stop the agent

### 4.1 Stop command

```bash
agent-bridge agent stop <agent>
```

Expected output: either `stopped: <agent>` (session was terminated) or
`[info] 에이전트 "<agent>" 세션이 이미 중지된 상태입니다.` (no live
session — already stopped).

- **PASS** if the command exits `0`. Both outputs above are acceptable.
- **FAIL** on any other non-zero exit — investigate before continuing;
  the migration helper will refuse to run while a live tmux session
  exists.

### 4.2 tmux session gone

```bash
tmux ls 2>/dev/null | grep -F '<session-name>' || echo "(no session)"
```

- **PASS** if no matching session is listed.
- **FAIL** if a session still exists; try `agent-bridge agent stop
  <agent>` again, and if it persists, kill the tmux session manually
  with `tmux kill-session -t <session-name>`.

### 4.3 Channel plugin port released

If §2.3 recorded a port, verify it is no longer held. Skip this step
if §2.3 returned `(no plugin port assigned)`.

```bash
ss -ltnp | grep ":<port>" || echo "(port released)"
```

- **PASS** if the port is no longer held.
- **FAIL** if a process still binds the port. Identify the PID from
  `ss -ltnp` and stop it explicitly before proceeding. Do not migrate
  while a stale plugin process holds resources — it will collide with
  the post-migration restart in §7.

---

## 5. Dry-run the migration

Always run `--dry-run` first and read the plan. `isolate` is
conservative (destructive steps are gated) but it does touch the OS
user database, the filesystem, and the roster; the dry-run surfaces
every planned action without executing any of them.

### 5.1 Command

```bash
agent-bridge isolate <agent> --dry-run
```

### 5.2 Expected plan shape

The output is a `[plan]` header followed by a numbered list of steps
each prefixed with `[dry-run]`. A typical plan looks like:

```
[plan] isolate <agent> -> linux-user mode
       os_user=agent-bridge-<slug> user_home=/home/agent-bridge-<slug> workdir=/path/to/agent/workdir
  [dry-run] upsert roster metadata in /home/<operator>/.agent-bridge/agent-roster.local.sh: isolation_mode=linux-user os_user=agent-bridge-<slug>
  [dry-run] useradd --system --home-dir /home/agent-bridge-<slug> --shell /usr/sbin/nologin agent-bridge-<slug>
  [dry-run] mkdir -p /home/agent-bridge-<slug> && chown agent-bridge-<slug>:agent-bridge-<slug> /home/agent-bridge-<slug> && chmod 0700 /home/agent-bridge-<slug>
  [dry-run] install symlink /home/agent-bridge-<slug>/.agent-bridge -> /home/<operator>/.agent-bridge
  [dry-run] chown -R agent-bridge-<slug> /path/to/agent/workdir
  [dry-run] chown -R agent-bridge-<slug> /home/<operator>/.agent-bridge/state/agents/<agent>
  [dry-run] chown -R agent-bridge-<slug> /home/<operator>/.agent-bridge/logs/agents/<agent>
  [dry-run] install per-agent ACLs + queue-gateway dirs + hidden-path strips (bridge_linux_prepare_agent_isolation)
[done] isolation plan printed (dry-run) for <agent>
[note] re-run without --dry-run to apply...
```

Notes on plan shape:

- The roster upsert runs **first** so a mid-run failure leaves `unisolate`
  with enough state to roll back; the upsert is idempotent.
- Missing state or log directories print `[warn] ... skipping chown`
  lines (they will be created on first start) instead of being silently
  omitted.
- If `--install-sudoers` was passed, an additional `[sudoers] planned
  entry for /etc/sudoers.d/agent-bridge-<os_user>:` block is printed.

### 5.3 Review checklist

Before running the live apply, confirm the plan matches expectations:

- **OS user name**: Is the slug what you expect? The default is
  `agent-bridge-<sanitized-agent-name>`. If the agent roster already
  sets `BRIDGE_AGENT_OS_USER[<agent>]=...` the plan will use that.
- **User home path**: Defaults to
  `/home/agent-bridge-<slug>`. Confirm this is on the partition you
  intended.
- **Workdir chown**: The plan will `chown -R` the agent's workdir. Make
  sure the workdir listed is the right one — a mistaken chown on a
  shared repo is a pain to undo.
- **Runtime state / log chown**: These paths live under
  `~/.agent-bridge/state/agents/<agent>` and
  `~/.agent-bridge/logs/agents/<agent>`. They should match the agent
  in question; do not proceed if the paths point to a different agent.
- **Roster target**: The roster file written to is
  `~/.agent-bridge/agent-roster.local.sh`. Confirm this is the file
  your install actually sources.

- **PASS** if the plan prints cleanly, every listed path belongs to
  the target agent, and the `[note]` reminder about channel tokens
  appears at the end.
- **FAIL** if the plan references the wrong workdir, the wrong agent's
  state directory, or points at a roster file that your install does
  not source. Stop, investigate, and do not apply.

---

## 6. Apply the migration

Once the dry-run plan is approved, run the live migration.

### 6.1 Command

```bash
agent-bridge isolate <agent>
```

Expected tail output:

```
[done] isolation applied for <agent>
[note] re-provision channel tokens if the agent consumed secrets under its old UID; old files are now owned by agent-bridge-<slug>.
```

- **PASS** if the command exits `0` and prints `[done] isolation
  applied for <agent>`.
- **FAIL** on any non-zero exit. See §8 (rollback) to reset partial
  state if the apply failed mid-run.

### 6.2 Verify: OS user created

```bash
getent passwd agent-bridge-<slug>
```

Expected output (values may vary):

```
agent-bridge-<slug>:x:998:998::/home/agent-bridge-<slug>:/usr/sbin/nologin
```

- **PASS** if a line is returned.
- **FAIL** if empty. The `useradd` step did not land — inspect the
  apply output and re-run or roll back.

### 6.3 Verify: managed home owned by the new user and mode 0700

The managed home is mode `0700` owned by the new UID, so the operator
cannot `ls` into it directly. Use `stat` (which needs only `+x` on the
parent `/home`) or prefix with `sudo`.

```bash
stat -c '%U:%G %a %n' /home/agent-bridge-<slug>
sudo -u agent-bridge-<slug> ls -la /home/agent-bridge-<slug>
```

Expected `stat` output:

```
agent-bridge-<slug>:agent-bridge-<slug> 700 /home/agent-bridge-<slug>
```

- **PASS** if `stat` reports the new OS user as both owner and group
  with mode `700`.
- **FAIL** on any other owner or mode — the chown / chmod step was
  skipped or overridden. Inspect and re-apply.

### 6.4 Verify: `.agent-bridge` symlink points at the live runtime

Same access story as §6.3 — the managed home is `0700`. Use
`sudo readlink` or `sudo stat`:

```bash
sudo readlink /home/agent-bridge-<slug>/.agent-bridge
# or equivalently:
sudo stat -c '%N' /home/agent-bridge-<slug>/.agent-bridge
```

Expected: the symlink resolves to the operator's `~/.agent-bridge`
(i.e. `$BRIDGE_HOME` at apply time).

- **PASS** if the target path matches the live runtime.
- **FAIL** if the symlink is missing or points somewhere else.

### 6.5 Verify: roster has the new isolation metadata

```bash
grep -E 'BRIDGE_AGENT_(ISOLATION_MODE|OS_USER)\["<agent>"\]' \
  ~/.agent-bridge/agent-roster.local.sh
```

Expected output:

```
BRIDGE_AGENT_ISOLATION_MODE["<agent>"]="linux-user"
BRIDGE_AGENT_OS_USER["<agent>"]="agent-bridge-<slug>"
```

- **PASS** if both lines are present with the expected values.
- **FAIL** if either line is missing, or the mode is still `shared`.

### 6.6 Workdir / state / log ownership

```bash
stat -c '%U %n' /path/to/agent/workdir \
  ~/.agent-bridge/state/agents/<agent> \
  ~/.agent-bridge/logs/agents/<agent> 2>/dev/null
```

- **PASS** if every listed path is owned by `agent-bridge-<slug>`, or
  if the path is missing AND the §5.2 plan printed a
  `[warn] ... skipping chown` line for it (state/log dirs are created
  lazily on first start).
- **FAIL** if any existing path is still owned by the operator UID.

---

## 7. Restart and verify

### 7.1 Start the agent

```bash
agent-bridge agent start <agent>
```

- **PASS** if the tmux session launches without error and
  `agent-bridge agent show <agent>` reports it active.
- **FAIL** on any launch error — fall back to §8 to roll back this
  single agent while you investigate. Do not leave the fleet in a
  half-migrated state.

### 7.2 Re-run the single-agent subset of the acceptance runbook

Run the relevant parts of the
[Linux Per-UID Isolation Acceptance Runbook](./isolation-acceptance-runbook.md)
scoped to this one agent:

- §1 Cross-agent filesystem read is denied — swap the second test
  agent for a second already-isolated agent (skip if this is the first
  migrated agent; come back to it after the next one lands).
- §2.1 Own inbox works.
- §2.3 Direct DB write from isolated UID is denied.
- §2.4 Claim / done round-trip.
- §3 Audit attribution. **Full PASS if the sudoers drop-in is
  installed** (via `isolate --install-sudoers` or manual install) so
  `bridge-start.sh`'s `sudo -u` wrap actually runs the tmux session
  under the per-agent UID. If the sudoers drop-in is missing,
  `bridge-start.sh` falls back to shared-mode launch with a
  `bridge_warn` and `acting_os_uid` will still be the operator's.
  Confirm via `agent-bridge audit follow --agent <agent>` after a
  tool call.
- §4 Operator-facing audit tools — hash-chain verification should
  still pass.

- **PASS** if every applicable check passes. §3 passes only when the
  sudoers drop-in is installed.
- **FAIL** if any containment check (§1, §2.3) fails — that indicates
  filesystem or gateway isolation is broken and must be resolved
  before moving to the next agent.

### 7.3 Channel plugin sanity

If the agent runs a channel plugin, confirm it has come back up under
the new identity:

```bash
ss -ltnp | grep ":<port>"
```

- **PASS** if the port is held again and the plugin responds to a
  smoke message on the corresponding channel.
- **FAIL** if the port is never re-bound — inspect plugin logs under
  `~/.agent-bridge/logs/agents/<agent>/`. The most common cause is
  channel secrets that were readable only by the old UID; re-provision
  any credentials flagged by the `[note]` at the end of §6.1.

---

## 8. Rollback (per-agent)

If any step above fails and you need to revert a single agent back to
shared mode, use the symmetrical unisolate helper.

### 8.1 Stop the agent

```bash
agent-bridge agent stop <agent>
```

### 8.2 Dry-run rollback

```bash
agent-bridge unisolate <agent> --dry-run
```

Read the plan — it should `chown -R` the workdir, runtime state, and
log directories back to the operator user, and clear the two roster
keys. Confirm the listed paths match what `isolate` changed in §5.2.

### 8.3 Apply rollback

```bash
agent-bridge unisolate <agent>
```

Expected tail output:

```
[done] unisolate applied for <agent>
[note] the OS user agent-bridge-<slug> is intentionally preserved (it may still own unrelated files). To delete it run: sudo userdel agent-bridge-<slug> && sudo rm -rf /home/agent-bridge-<slug>
```

Two things to note:

- The dedicated OS user and `/home/agent-bridge-<slug>` **are
  preserved**. Rollback does not delete user data — if anything still
  depends on that UID (an unrelated workspace, a leftover log), it
  stays intact.
- The helper prints the exact cleanup command. Run it only after you
  have confirmed that nothing else on the host still references the
  user.

### 8.4 Verify rollback

```bash
grep -E 'BRIDGE_AGENT_(ISOLATION_MODE|OS_USER)\["<agent>"\]' \
  ~/.agent-bridge/agent-roster.local.sh || echo "(unset)"
```

Expected output: both lines present with `ISOLATION_MODE="shared"` and
empty `OS_USER=""` — the unisolate upsert writes both keys, it never
deletes. Restart the agent with `agent-bridge agent start <agent>` and
confirm it comes up.

- **PASS** if both lines are present with `ISOLATION_MODE="shared"` +
  `OS_USER=""` and the agent starts cleanly.
- **FAIL — investigate** if grep returns `(unset)`. That means
  `unisolate` short-circuited (it printed `[info] <agent> is already
  in shared mode; nothing to do.` in §8.3). Filesystem ownership was
  not reverted, and the agent was likely not in `linux-user` mode
  before you ran rollback. Check the §8.3 output, confirm the agent's
  prior state, and re-plan before acting.
- **FAIL** if the roster still has `linux-user`, or the agent fails
  to start. Check the apply output, re-run `unisolate`, and escalate
  if the state does not converge.

---

## 9. Batch guidance

A realistic migration usually has N ≥ 3 agents. Run them serially,
keep a notebook, and treat each agent as an independent unit of work.

- **Migration order.** Non-admin agents first; admin last. Within
  non-admin, migrate low-traffic and low-credential-scope agents
  first so you catch mistakes while the blast radius is small.
- **One at a time — do not parallelize.** The helper's roster
  upsert, `useradd`, and filesystem chowns are not transactional
  across a single shared roster file. Two concurrent `isolate`
  invocations against the same host can race on
  `~/.agent-bridge/agent-roster.local.sh` and lose a write.
- **Per-agent log.** For each agent, record: start timestamp,
  dry-run output hash, apply output, §6 verification results,
  §7.2 acceptance-runbook results (explicitly noting the #103
  partial-PASS on §3), and the channel plugin port state before /
  after. A compact template:

  ```
  agent=<name>
  start=<iso timestamp>
  end=<iso timestamp>
  plan_ok=yes
  apply_ok=yes
  getent=yes
  home_0700=yes
  symlink=yes
  roster=yes
  workdir_chown=yes
  restart=yes
  acceptance_fs_deny=pass
  acceptance_gateway=pass
  acceptance_audit_uid=partial-until-103
  plugin_port=rebound
  ```

- **Stuck plugin port after stop.** If §4.3 FAILs and the port never
  releases, do not proceed. Identify the holder via `ss -ltnp` and
  `ps <pid>`, and stop it. A common cause is a channel plugin
  watchdog that restarted the process between `agent stop` and your
  port check — run `agent-bridge agent stop <agent>` again to confirm
  the agent is really stopped before investigating the stray process.
- **Mid-run failures.** The migration helper writes the roster metadata
  **before** any destructive step, so `agent-bridge unisolate <agent>`
  (§8) can always roll back a partially-applied migration: it will see
  `isolation_mode="linux-user"` and `os_user=...` and reverse whatever
  chowns did land. If apply dies before the roster upsert runs,
  `unisolate` will short-circuit with `[info] ... already in shared
  mode; nothing to do.` — in that case no destructive step ran either,
  so the host is still in its pre-migration state.
  - **Exception — acceptance-runbook §2 failures after apply completes.**
    If §7.2's containment checks fail but the apply itself succeeded,
    the most likely cause is that `setfacl` was not installed (§1.3
    should have caught this) or `bridge_linux_prepare_agent_isolation`
    returned non-zero (look for the `bridge_warn` line in the apply
    output). Install `acl`, then re-run
    `agent-bridge isolate <agent>` — it is idempotent and will
    re-install the missing ACLs.
  - **Exception — §7.2 §3 audit still reports operator UID.** The
    sudoers drop-in was not installed. Run `agent-bridge isolate
    <agent> --install-sudoers`, or install the drop-in manually using
    the entry printed at the end of apply, then restart the agent.
- **After all agents are migrated.** Re-run the full
  [Linux Per-UID Isolation Acceptance Runbook](./isolation-acceptance-runbook.md)
  across two agents (the cross-agent checks in §1 and §2.2 require
  two isolated agents side by side). Note in the resulting report that
  §3 (audit attribution) is expected to partially fail until
  [#103](https://github.com/seanssoh/agent-bridge-public/issues/103)
  lands.
- **Admin last.** Once the rest of the fleet is clean, migrate the
  admin agent using the same steps. Keep an alternate terminal ready
  during the admin migration — if the admin agent is the one you were
  using as an escalation target, there is no fallback for the minutes
  between §4 and §7.1.

---

## References

- Migration helper implementation: [`lib/bridge-migration.sh`](../lib/bridge-migration.sh)
- Validation checklist: [isolation-acceptance-runbook.md](./isolation-acceptance-runbook.md)
- Scope and macOS exclusion: [platform-support.md](./platform-support.md)
- Runtime UID-switch gap: [#103](https://github.com/seanssoh/agent-bridge-public/issues/103)
- Migration helper CLI issue: [#85](https://github.com/seanssoh/agent-bridge-public/issues/85)
- Parent isolation issue: [#68](https://github.com/seanssoh/agent-bridge-public/issues/68)
