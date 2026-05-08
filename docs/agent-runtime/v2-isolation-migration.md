# Isolation v2 — drift-recovery and migration reference

Deep reference for operators bringing a v0.7.x → v0.8 install onto the
canonical isolation-v2 contract, or recovering an install that drifted
from it. Pair with:

- [`OPERATIONS.md` § "Isolation v2 canonical state and migration"](../../OPERATIONS.md#isolation-v2-canonical-state-and-migration)
  — the short surface-level operator runbook.
- [`KNOWN_ISSUES.md` §16](../../KNOWN_ISSUES.md#16-layout-v2--claude-first-launch-login-required-pr-641--v080)
  — the single retained ACL surface (`~/.claude/.credentials.json`)
  and the v0.7→v0.8 ACL-leftover manual recovery.
- [`docs/isolation-migration-guide.md`](../isolation-migration-guide.md)
  — the older v0.6→v0.7 `shared → linux-user` migration walkthrough
  (separate, predates v2).
- `lib/bridge-isolation-v2.sh:38-62` — the contract source of truth.

This document is reference material — copy-pasteable diagnostic and
recovery commands plus the drift signatures we have seen on real
installs. The expected operator entry point is the
`agent-bridge migrate isolation v2` CLI added in v0.9.0; everything
below also serves as the manual-recovery procedure when that CLI is
not available.

---

## 1. v2 layout overview

The canonical state table for an isolated agent named `<agent>` (its
backing Linux UID is `agent-bridge-<agent>`, its private group is
`ab-agent-<agent>`):

| Path | Owner | Group | Mode | Notes |
|---|---|---|---|---|
| `~/.agent-bridge/shared/` | controller | `ab-shared` | `2750` | read-only public assets |
| `~/.agent-bridge/state/` | controller | `ab-controller` | `2750` | controller-only |
| `~/.agent-bridge/agents/<agent>/` | **root** | `ab-agent-<agent>` | `2750` | per-agent private root |
| `~/.agent-bridge/agents/<agent>/{home,workdir,runtime,logs,requests,responses}/` | `agent-bridge-<agent>` | `ab-agent-<agent>` | `2770` | agent owns; controller via group |
| `~/.agent-bridge/agents/<agent>/credentials/` | controller | `ab-agent-<agent>` | `2750` | controller writes, agent reads |
| `~/.agent-bridge/agents/<agent>/credentials/launch-secrets.env` | controller | `ab-agent-<agent>` | `0640` | |
| `~/.agent-bridge/agents/<agent>/agent-env.sh` | controller | `ab-agent-<agent>` | `0640` | |
| `~/.agent-bridge/agents/<agent>/workdir/.teams/.env`, `.../.ms365/.env` | `agent-bridge-<agent>` | `ab-agent-<agent>` | `0640` | controller readiness probe via group |
| `/home/agent-bridge-<agent>/` | `agent-bridge-<agent>` | `agent-bridge-<agent>` | `0700` | agent's actual Linux home, no ACL |
| `/home/agent-bridge-<agent>/.claude/`, sub-tree | `agent-bridge-<agent>` | `agent-bridge-<agent>` | `0700` | same — no ACL |

Two access mechanisms only:

1. **Group + setgid**, throughout the v2 layout under
   `~/.agent-bridge/agents/<agent>/`. The controller reads the agent
   tree by virtue of membership in `ab-agent-<agent>`; the per-agent
   UID is the owner. New files inherit the group via the setgid bit
   on the parent directory plus the agent process's `umask 007`
   (applied by `bridge_run_apply_v2_umask_if_needed`).

2. **Plain owner-only**, on the agent's actual Linux home
   (`/home/agent-bridge-<agent>/`). The controller has no path into
   this tree at all. Anything outside the v2 layout that the
   controller needs to share with the agent must be re-mediated
   through the v2 tree (via `agents/<agent>/credentials/` for secrets,
   via `agents/<agent>/workdir/...` for plugin state, etc.).

The single transitional ACL exception (`~/.claude/.credentials.json`
in the operator's home) is documented in
[`KNOWN_ISSUES.md` §16](../../KNOWN_ISSUES.md#16-layout-v2--claude-first-launch-login-required-pr-641--v080)
— that surface is *outside* the v2 layout and uses a named-user `r--`
ACL plus an `--x` traverse chain because it is the operator's home
file. It is preserved by the migration command.

## 2. Drift signatures from v0.7

The most common shapes of drift on a v0.7-upgraded install. None of
these are catastrophic on their own, but each one breaks at least one
controller workflow until corrected.

### 2.1 Pre-v2 ACL leftovers on the agent's Linux home

```text
/home/agent-bridge-<agent>/                root:agent-bridge-<agent>  0750
/home/agent-bridge-<agent>/.claude/        root:agent-bridge-<agent>  0750
                                           + named-user ACL: u:<controller>:r-x
```

**v2 expects**:

```text
/home/agent-bridge-<agent>/                agent-bridge-<agent>:agent-bridge-<agent>  0700
/home/agent-bridge-<agent>/.claude/        agent-bridge-<agent>:agent-bridge-<agent>  0700
                                           no ACL
```

Cause: v0.7's `bridge_linux_prepare_agent_isolation` created the home
as `root` and granted the controller a named-user ACL for traversal
and read. v0.8.0 deleted that helper but the v2 cut-over did not
chown the existing home back to the agent or strip the ACL. The
controller still has read access via the leftover ACL, which is
exactly the surface v2 contract removed.

Why this matters: any tooling that walks `/home/agent-bridge-<agent>/`
expecting it to be `0700` agent-only (e.g. the audit fast-path that
asserts "only the agent can read its own home") sees the leftover
controller ACL and reports false-positive drift.

### 2.2 Plugin state files at `0600` controller-owned

```text
~/.agent-bridge/agents/<agent>/workdir/.teams/.env       <controller>:<controller>  0600
~/.agent-bridge/agents/<agent>/workdir/.ms365/.env       <controller>:<controller>  0600
```

**v2 expects**:

```text
~/.agent-bridge/agents/<agent>/workdir/.teams/.env   agent-bridge-<agent>:ab-agent-<agent>  0640
~/.agent-bridge/agents/<agent>/workdir/.ms365/.env   agent-bridge-<agent>:ab-agent-<agent>  0640
```

Cause: pre-v2 the readiness probe ran as the controller against a
controller-owned file. v2 moved the probe behind a group read so the
file must be agent-owned with `ab-agent-<agent>` group + `0640`.

Why this matters: the controller-side readiness probe for a Teams /
MS365 plugin can no longer read the file it is probing, because the
agent process now writes through the v2 umask and the file lands
agent-owned, not controller-owned. The probe surfaces as a perpetual
"not ready".

### 2.3 Missing `agents/<agent>/.claude/`

```text
~/.agent-bridge/agents/<agent>/.claude/   (does not exist)
```

**v2 expects**:

```text
~/.agent-bridge/agents/<agent>/.claude/   <controller>:<controller>  0700
```

Cause: the controller-side `.claude/` shadow that the readiness probe
and admin tooling reach for is created lazily; on installs that never
exercised the lazy path, the directory is simply missing.

Why this matters: `agent-bridge agent show <agent>` and other
controller-side admin commands that look at the controller-side
`.claude/` raise FileNotFoundError instead of "not configured yet".

## 3. Migration command (v0.9.0+)

The operator-facing entry point for the recovery. Three forms:

```bash
# Drift report only — never mutates.
agent-bridge migrate isolation v2 --check

# Print the planned mutations without applying them.
agent-bridge migrate isolation v2 --dry-run

# Apply the fix. Idempotent on a canonical install.
agent-bridge migrate isolation v2 --apply
```

Scope each invocation to a single agent with `--agent <name>`; the
default fans out across every isolated agent in the roster.

What `--apply` does:

1. Re-asserts the canonical owner / group / mode triplet on every row
   of the canonical state table for each isolated agent (idempotent
   when the row is already canonical).
2. Strips any named-user POSIX ACL it finds inside the v2 tree
   (`~/.agent-bridge/agents/<agent>/...`) and on the agent's actual
   Linux home (`/home/agent-bridge-<agent>/...`). Equivalent to
   `setfacl -bR <path>` on each of those subtrees.
3. **Preserves** the `~/.claude/.credentials.json` named-user ACL plus
   the `--x` traverse chain in the operator's home — that is the
   single transitional exception (see
   [`KNOWN_ISSUES.md` §16](../../KNOWN_ISSUES.md#16-layout-v2--claude-first-launch-login-required-pr-641--v080)).
4. Re-runs the readiness-probe shape check on the controller-side
   `.claude/` shadow and the workdir plugin state files, fixing any
   drift in §2.2 and §2.3 above.

`--check` and `--dry-run` produce the same plan but never mutate.
`--check` is the form intended for periodic operator audits.

## 4. Manual recovery

For installs where the v0.9.0 migration command is unavailable. Run
each block as the controller (the user that owns
`~/.agent-bridge/`), with `sudo` available.

```bash
# Identify the agent and its UID/GID names.
A=<agent>
USER=agent-bridge-$A
GROUP=ab-agent-$A
CTRL=$(id -un)

# 1. Re-own the agent's actual Linux home and strip transitional ACLs.
sudo chown -R "$USER:$USER" "/home/$USER/"
sudo chmod -R u+rwX,go-rwx "/home/$USER/"
sudo setfacl -bR "/home/$USER/"

# 2. Realign plugin state files to v2 group-read contract.
for f in "$HOME/.agent-bridge/agents/$A/workdir/.teams/.env" \
         "$HOME/.agent-bridge/agents/$A/workdir/.ms365/.env"; do
  if [[ -f "$f" ]]; then
    sudo chown "$USER:$GROUP" "$f"
    sudo chmod 0640 "$f"
  fi
done

# 3. Create the controller-side .claude/ shadow if missing.
sudo install -d -o "$CTRL" -g "$CTRL" -m 0700 \
  "$HOME/.agent-bridge/agents/$A/.claude"

# 4. (Optional) Re-assert the canonical group + mode on the v2 agent root.
sudo chown root:"$GROUP" "$HOME/.agent-bridge/agents/$A"
sudo chmod 2750 "$HOME/.agent-bridge/agents/$A"

# 5. Restart the agent.
agent-bridge agent start "$A"
```

**Do not** run `setfacl -b` on `~/.claude/.credentials.json` or its
ancestor chain. That is the single retained ACL surface; stripping it
breaks first-launch credential read for every isolated agent on the
host until you re-run isolation prep.

## 5. POSIX ACL contract — quick summary

| Surface | ACL? | Notes |
|---|---|---|
| `~/.agent-bridge/...` (entire v2 layout) | **No** | group ownership + setgid only |
| `/home/agent-bridge-<agent>/...` | **No** | agent-only `0700`, no ACL |
| `~/.claude/.credentials.json` + ancestor chain | **Yes** | single transitional named-user ACL |
| Anywhere else outside the v2 layout | **No** | no ACL surface |

See [`KNOWN_ISSUES.md` §16](../../KNOWN_ISSUES.md#16-layout-v2--claude-first-launch-login-required-pr-641--v080)
for the long-term plan to replace the transitional surface with
per-agent `claude login` (operator workflow change).

## 6. Diagnostic commands

Probe a single agent:

```bash
A=<agent>
USER=agent-bridge-$A
GROUP=ab-agent-$A

# Per-agent v2 root: should be `root:ab-agent-<agent> 2750`.
stat -c "%U:%G %a" "$HOME/.agent-bridge/agents/$A"

# Per-agent home (inside v2 layout): should be `<USER>:<GROUP> 2770`.
stat -c "%U:%G %a" "$HOME/.agent-bridge/agents/$A/home"

# Agent's actual Linux home: should be `<USER>:<USER> 700`, no ACL.
sudo stat -c "%U:%G %a" "/home/$USER"
sudo getfacl --skip-base "/home/$USER"
sudo getfacl --skip-base "/home/$USER/.claude" 2>/dev/null

# Plugin state files: should be `<USER>:<GROUP> 640`.
stat -c "%U:%G %a" "$HOME/.agent-bridge/agents/$A/workdir/.teams/.env" 2>/dev/null
stat -c "%U:%G %a" "$HOME/.agent-bridge/agents/$A/workdir/.ms365/.env" 2>/dev/null

# Per-agent group membership (controller + agent UID).
getent group "$GROUP"

# Agent UID's effective groups (must include $GROUP and ab-shared).
sudo -u "$USER" id -nG
```

`--skip-base` on `getfacl` filters out the default UNIX permission
entries, leaving only any extended (named-user / named-group / mask)
entries — i.e. exactly the surface that v2 contract says should be
empty inside the agent's home.

## 7. Related issues

- **#737** — the originating spec for this document and for the
  v0.9.0 migration command.
- **#720** — drift report for the v0.7 → v0.8 home-ownership leftover
  (§2.1 above).
- **#730** — `bridge_linux_grant_claude_credentials_access` removal +
  the single retained ACL surface.
- **#731** — readiness probe vs. plugin state file mode mismatch
  (§2.2 above).
