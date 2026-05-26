# Authoring Claude Code Plugins for Agent Bridge Linux-User Isolation (v2)

Reference for plugin authors who want their plugin to work cleanly when an Agent Bridge operator runs it under `linux-user` isolation (the default v2 contract introduced with v0.8.0 and hardened across the v0.13.x — v0.14.5 release wave).

A plugin that follows the standard [Claude Code plugin authoring guide](https://docs.anthropic.com/en/docs/claude-code/plugins) will load on a Bridge install in `shared` mode. Under `linux-user` mode the runtime fans the plugin across multiple OS users with distinct `$HOME` trees, a controller-managed shared cache, and a stricter permission boundary. Plugins that hardcode path assumptions or write outside the iso UID's writable set will silently break here — typically with no operator-visible diagnostic.

This document spells out the additional rules. It does NOT replace the standard plugin guide; it extends it.

> Scope: this guide is for **plugin authors**. Operators looking for "how to deploy iso v2" should read `docs/isolation-migration-guide.md` and `docs/isolation-acceptance-runbook.md` instead.

## 0. Quick mental model

In `shared` mode there is one OS user (the operator) and one `$HOME`. Claude Code, every plugin, every hook, and every MCP server runs as that user. The plugin guide's defaults all assume this shape.

In `linux-user` mode there is:

- One **controller** OS user (typically `awfmanager` or the operator's login). Owns the source checkout, the `BRIDGE_HOME` tree, and the long-running daemon.
- One **per-agent** OS user per managed Claude agent, named `agent-bridge-<agent-slug>` (system account, no login shell). Owns that agent's `$HOME`, runs the agent's `claude` process, and inherits a supplementary group `ab-agent-<slug>` that grants group-shared access to the agent's workdir.
- A **shared plugin cache** under `${BRIDGE_HOME}/data/shared/plugins-cache/marketplaces/<marketplace-id>/`, owned by the controller. Each per-agent UID gets a read-only view of this cache via symlinks placed inside its own `~/.claude/plugins/marketplaces/`.

Your plugin's `SessionStart`, `UserPromptSubmit`, etc. hooks fire **as the per-agent UID**, not the controller. Your MCP server (`mcp__plugin_*` tools) is spawned **as the per-agent UID**. Filesystem access for those processes is gated by the per-agent UID's read/write permissions, which are intentionally narrow.

If you write a plugin assuming "one HOME, one user, full filesystem write access" it will load but fall over the first time it tries to mutate state.

## 1. Filesystem reference for plugin processes

When your hook or MCP server runs under `linux-user` isolation, this is what it sees:

Observed modes/owners are from live `test_iso_v26` on a Linux v0.14.5-beta26 install; mode is shown as the octal `stat -c %a` would print (4-digit when special bits are set — `2xxx` = setgid, `3xxx` = setgid + sticky):

| Path | Owner:Group | Mode | Plugin can read | Plugin can write |
| --- | --- | --- | --- | --- |
| `$HOME` (= `/home/agent-bridge-<slug>/`) | `agent-bridge-<slug>:ab-agent-<slug>` | `2750` | yes | yes |
| `$HOME/.claude/` | `root:ab-agent-<slug>` | `3770` | yes (group) | yes (group) |
| `$HOME/.claude/plugins/` | `root:ab-agent-<slug>` | `3770` | yes (group) | yes (group) |
| `$HOME/.claude/plugins/cache/` | `agent-bridge-<slug>:ab-agent-<slug>` | `2770` | yes | yes |
| `$HOME/.claude/plugins/cache/<marketplace>/<plugin>/<ver>/` | `agent-bridge-<slug>:agent-bridge-<slug>` | `0700` | yes | yes (this is your installed-plugin per-agent cache — write `.mcp.json`, state files, etc. HERE) |
| `$HOME/.claude/plugins/marketplaces/<marketplace>/` | (symlink) | (target's mode) | yes | NO — points to controller-owned shared mirror |
| `${BRIDGE_HOME}/data/shared/plugins-cache/marketplaces/<marketplace>/` | controller | varies (controller-managed) | yes (read-only) | NO — marketplace source-of-truth, do not mutate |
| `${BRIDGE_HOME}/data/agents/<slug>/` | `root:ab-agent-<slug>` | `2750` | yes (group) | NO |
| `${BRIDGE_HOME}/data/agents/<slug>/workdir/` | `agent-bridge-<slug>:ab-agent-<slug>` | `2770` | yes | yes (the agent's working directory; this is where your plugin's per-agent state files like `.teams/`, `.ms365/`, etc. should live) |
| `${BRIDGE_HOME}/data/agents/<slug>/runtime/` | `agent-bridge-<slug>:ab-agent-<slug>` | `2770` | yes | yes (env file location) |
| `${BRIDGE_HOME}/data/agents/<other-slug>/` | `root:ab-agent-<other-slug>` | `2750` | NO (group bit excludes you) | NO |
| `${BRIDGE_HOME}/state/`, `${BRIDGE_HOME}/logs/` | controller | varies | controller-only by default | NO |
| `/etc/`, `/var/`, `/opt/` etc. | root | system | usually yes | NO |
| `/tmp/` | various | sticky `1777` | yes | yes BUT no cross-UID file sharing — your UID's tmp files are yours alone |

Note: `$HOME/.claude/` and `$HOME/.claude/plugins/` are owned by `root` with the `ab-agent-<slug>` supplementary group. The iso UID is a member of that group, so reads and writes via the group are permitted. The leaf `cache/<marketplace>/<plugin>/<ver>/` directory is mode `0700` and owned by the iso UID directly — your hooks' writes land there, not at the marketplace-symlink target.

Two rules summarize the rest:

- **Read** is mostly permitted; **write** is narrow.
- **Your plugin's writable scope is essentially: `$HOME`, the per-agent cache dir under `~/.claude/plugins/cache/`, and the agent's workdir under `data/agents/<slug>/workdir/`.** Anywhere else, assume `EACCES`.

## 2. Hard rules

### 2.1 Do NOT path-check `CLAUDE_PLUGIN_ROOT` against a narrow `$HOME` prefix

Under Bridge `linux-user`, `CLAUDE_PLUGIN_ROOT` can arrive as one of two shapes depending on the runtime path that invokes your hook:

- **Per-agent installed-plugin cache** under the iso UID's home — e.g.
  `/home/agent-bridge-<slug>/.claude/plugins/cache/<marketplace>/<plugin>/<ver>` (this is `$HOME`-prefixed, mode `0700`, iso-UID-owned, writable)
- **Shared marketplace mirror** under `BRIDGE_HOME` — e.g.
  `${BRIDGE_HOME}/data/shared/plugins-cache/marketplaces/<marketplace>/...` (controller-owned, read-only to iso UID, the symlink target of `~/.claude/plugins/marketplaces/<marketplace>`)

A naive guard like:

```bash
case "$CLAUDE_PLUGIN_ROOT" in
  "$HOME/.claude/plugins/"*) : ;;
  *) echo "refusing to run outside install cache"; exit 0 ;;
esac
```

correctly accepts the per-agent cache shape but silently rejects the shared-mirror shape. If your runtime path is ever invoked with the shared-mirror `CLAUDE_PLUGIN_ROOT` (the cosmax-crm-cli `SessionStart` flow on Bridge iso v2 is one observed case — see [`SYRS-AI/cosmax-crm-cli#177`](https://github.com/SYRS-AI/cosmax-crm-cli/issues/177)), the hook silently no-ops with no operator-visible diagnostic.

Acceptable alternatives:

- **Drop the guard entirely.** If your plugin doesn't care where it's invoked from, don't enforce.
- **Allowlist both Bridge shapes.** Accept the iso UID's home AND the Bridge shared mirror when `BRIDGE_HOME` is set:
  ```bash
  case "$CLAUDE_PLUGIN_ROOT" in
    "$HOME/.claude/plugins/"*) : ;;
    *)
      if [ -n "${BRIDGE_HOME:-}" ] \
          && [ -d "${BRIDGE_HOME}/data/shared/plugins-cache/marketplaces" ] \
          && case "$CLAUDE_PLUGIN_ROOT" in
               "${BRIDGE_HOME}/data/shared/plugins-cache/marketplaces/"*) true ;;
               *) false ;;
             esac
      then : ; else echo "unsafe plugin root"; exit 0; fi
      ;;
  esac
  ```
- **Resolve the symlink and check provenance.** `readlink -f` the parent of `CLAUDE_PLUGIN_ROOT` and confirm it matches a path the operator controls (either `$HOME/.claude/plugins/` or `${BRIDGE_HOME}/data/shared/plugins-cache/marketplaces/`).

### 2.2 Write to the per-agent cache, NOT the shared marketplace mirror

If your plugin needs to mutate a file that ships with the source (a common pattern: replace a `Bearer __PLACEHOLDER__` token in a cached `.mcp.json`), write to the **per-agent installed-plugin cache copy**, not the shared marketplace mirror.

In non-isolated / `shared` deployments the operator has write access across these paths, so this class of bug often stays hidden. In `linux-user` mode the two paths are distinct and have different writability:

- Shared mirror: `${BRIDGE_HOME}/data/shared/plugins-cache/marketplaces/<marketplace>/...` (controller-owned, read-only to iso UID)
- Per-agent cache: `$HOME/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` (iso-UID-owned, writable)

`CLAUDE_PLUGIN_ROOT` MAY point at either path depending on the runtime invocation (see 2.1). Do not assume `$CLAUDE_PLUGIN_ROOT/.mcp.json` is always writable.

Strategy:

```bash
# Wrong (treats CLAUDE_PLUGIN_ROOT as universally writable — fails when it's the shared mirror):
MCP_JSON="$CLAUDE_PLUGIN_ROOT/.mcp.json"
echo "$NEW_CONTENT" > "$MCP_JSON"           # EACCES if root is the shared mirror

# Right (cache — iso UID owned, writable):
MCP_JSON="$HOME/.claude/plugins/cache/<marketplace>/<plugin>/<version>/.mcp.json"
echo "$NEW_CONTENT" > "$MCP_JSON"           # OK
```

How to discover the cache path from inside the hook:

- Bridge populates the per-agent cache before launching claude. The cache path mirrors the marketplace's directory structure exactly:
  ```
  $HOME/.claude/plugins/cache/<marketplace-id>/<plugin-name>/<version>/
  ```
- `<marketplace-id>` and `<plugin-name>` come from `.claude-plugin/marketplace.json` and `.claude-plugin/plugin.json` respectively, both of which your plugin source already declares.
- `<version>` is the plugin's declared version.

Derive the cache path from `$HOME/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` — Bridge does not export a plugin-cache-root env var to plugin child processes as of v0.14.5-beta26.

### 2.3 Do not write outside `$HOME` or the agent's workdir

Under `linux-user`, `/tmp/<plugin>-state/` is per-UID and is fine for ephemeral files, but cross-invocation state (login tokens, refresh cookies, config caches) MUST live in `$HOME` or the agent's workdir, not in:

- `/etc/<plugin>/...`
- `/var/lib/<plugin>/...`
- `/usr/local/share/<plugin>/...`
- A peer agent's home (`/home/agent-bridge-<other-slug>/`)
- `${BRIDGE_HOME}/shared/...` unless your plugin is explicitly a shared-state plugin (rare; coordinate with the operator)

The conventional choice is `$HOME/.<plugin>/`. Set umask `0077` for credentials, `0007` for shared-with-controller artifacts.

### 2.4 Do not require `sudo` or root

The iso UID is a system account with no sudo grants. Anything that needs root must happen on the controller side (typically via a Bridge install script that the operator runs once). Plugin runtime code can assume:

- No `sudo`, no `setcap`, no `mount`.
- No write to `/usr/local/bin/` or any system-managed directory.
- No `setuid` invocations of system binaries that probe for root.

If your plugin needs a privileged action, the right shape is: ship a one-time install script that the operator runs as root to provision system-level state, and have the plugin runtime consume the result (a config file, a tmpfs path, etc.) without re-checking privilege.

### 2.5 Do not assume tty or interactive input

Hooks run from non-interactive contexts: claude's session lifecycle, the bridge daemon's task-dispatch path, etc. Your hook MUST NOT:

- Call `read` or otherwise block on stdin.
- Print prompts assuming an operator will see them and respond.
- Invoke `claude /login`, `gh auth login`, or any wizard that requires a browser callback from inside the hook.

Pass all inputs via env vars, config files written in advance by setup, or MCP tool args. If your plugin needs a user-driven OAuth flow (MS365 pair_start is the canonical example), the flow should:

1. Be triggered by an MCP tool call from claude (which the user can respond to).
2. Emit a URL the user clicks in their own browser.
3. Persist the callback result to a file in `$HOME` or workdir.
4. Subsequent invocations read that file.

DO NOT bake the OAuth flow into a `SessionStart` hook that fires before claude is ready to relay the URL to the user.

### 2.6 HTTP MCP server token injection — use env or file-watch, not source mutation

A common pattern: your MCP server is HTTP, needs a Bearer token, and the token is acquired at runtime (e.g. via M365 OAuth). The naive shape:

1. Ship `.mcp.json` with `Authorization: "Bearer __PLACEHOLDER__"`
2. Run a SessionStart hook that replaces the placeholder in `.mcp.json` with the real token
3. Claude Code re-reads `.mcp.json` and the MCP server gets the right Authorization

This works in `shared` mode. Under `linux-user` it requires:

- The hook MUST write to the per-agent cache copy of `.mcp.json`, not the source (rule 2.2)
- The hook MUST NOT path-check itself out of running (rule 2.1)
- Claude Code's `.mcp.json` re-read must happen AFTER the hook substitution — in practice this means a `restart Claude Code to apply` prompt is unavoidable on the first session that acquires the token. Document this.

Better patterns for new plugins:

**Pattern A: `command:` MCP server with env-injected token**

Instead of HTTP MCP with a static Authorization header, declare:

```json
{
  "mcpServers": {
    "my-plugin": {
      "command": "node",
      "args": ["${CLAUDE_PLUGIN_ROOT}/scripts/mcp-proxy.mjs"],
      "env": {
        "MY_PLUGIN_BACKEND_URL": "https://api.example.com/mcp",
        "MY_PLUGIN_TOKEN_ENV": "MS365_ACCESS_TOKEN_FOR_MY_PLUGIN"
      }
    }
  }
}
```

The proxy reads the token from env at request-time and forwards. The token lives in a file in `$HOME` or workdir; the proxy re-reads it before each backend call. No `.mcp.json` mutation required.

This is the shape `cosmax-ep-approval` uses; it works cleanly under iso v2.

**Pattern B: HTTP MCP server with file-watch token resolver**

If you must use HTTP MCP shape, ship a thin server that watches a token file in `$HOME` and reloads on change. The plugin's `.mcp.json` then has a stable static Authorization (e.g. a long-lived plugin secret) that authorizes calls to your local server; the local server enforces the real per-user token by reading the file. This pushes the token-substitution problem to a per-UID local server which can write its own state freely.

### 2.7 Test under iso v2 before publishing

The cheapest validation:

```bash
# On a Linux host with Bridge installed:
agent-bridge agent create test_my_plugin \
  --engine claude --isolation linux-user \
  --channels plugin:my-plugin@my-marketplace

agent-bridge agent start test_my_plugin --no-attach
```

Then in the tmux pane (or via `agent-bridge urgent test_my_plugin "<task>"`):

- Confirm your plugin's tools appear in `/mcp`.
- Trigger every code path your hooks have. Watch for `PreToolUse:Bash hook error  ⎿ Failed with non-blocking status code: Traceback`.
- If your plugin needs OAuth or credentials, run the full pair_status → pair_start → callback → first tool call flow.
- After the session, inspect:
  - Cached `.mcp.json` under `/home/agent-bridge-test_my_plugin/.claude/plugins/cache/<your-marketplace>/<your-plugin>/<ver>/.mcp.json` — confirm any expected mutations happened
  - Your plugin's state files under `$HOME` or workdir — owned by `agent-bridge-test_my_plugin` with appropriate mode
  - Audit log at `${BRIDGE_HOME}/logs/agents/test_my_plugin/audit.jsonl` — look for `hook_permission_fail_open.*` entries (these indicate paths you tried to write that the iso UID could not — investigate each)

Then tear down: `agent-bridge agent delete test_my_plugin --purge-home`.

## 3. Reference: environment variables Bridge exports to plugin processes

These are confirmed-reaching your hook and MCP-server child processes on v0.14.5-beta26 (verified via `/proc/<pid>/environ` on live `test_iso_v26` claude + bun children). Names are stable across the v0.14.x series.

| Env var | Set by | Use |
| --- | --- | --- |
| `BRIDGE_HOME` | bridge-run.sh | Root of the Bridge install. Use to discover the shared marketplace mirror path in path-allowlist checks. |
| `BRIDGE_AGENT_ID` | bridge-run.sh | The current agent's slug (e.g. `test_my_plugin`). Use for state file naming or audit. |
| `BRIDGE_CONTROLLER_UID` | bridge-run.sh | The controller's numeric UID. Compare against `os.geteuid()` to detect "am I running as the iso UID or as the controller". This is the canonical iso-vs-controller predicate. |
| `HOME` | sudo + PAM | The iso UID's home, `/home/agent-bridge-<slug>/`. |
| `USER` | sudo + PAM | The iso UID, `agent-bridge-<slug>`. |
| `CLAUDE_CONFIG_DIR` | bridge-run.sh | The iso UID's claude config dir, `$HOME/.claude/`. |
| `CLAUDE_PLUGIN_ROOT` | claude-code | Path to your plugin (see rule 2.1 — can be the iso-UID-owned per-agent installed cache OR the shared marketplace mirror; do not assume which). |

The following are **NOT** reliably exported to plugin child processes as of beta26 — do not rely on them:

- `BRIDGE_AGENT_WORKDIR` — Bridge tries to export it in `bridge-run.sh` but the `sudo --preserve-env=...` boundary does not carry it through. Derive the workdir from `${BRIDGE_HOME}/data/agents/${BRIDGE_AGENT_ID}/workdir/` if you need it.
- `BRIDGE_AGENT_ISOLATION_MODE` — has a bash associative-array/scalar name collision (see `#1213`) which causes the export to silently no-op. The PR #1216 fix (beta26) addressed the *consumer* side of this in `hooks/bridge_hook_common.py` by switching to `BRIDGE_AGENT_ID + BRIDGE_CONTROLLER_UID + geteuid()` instead of reading the mode string. The mode-string export itself is still broken in beta26. **Do not read `BRIDGE_AGENT_ISOLATION_MODE` from env.** The reliable iso predicate is exactly the UID-mismatch check.

## 4. Common pitfalls (with case studies)

### 4.1 "My plugin loads but reports 0 tools"

Most common cause: your MCP server is HTTP and the Bearer token in `.mcp.json` is still a placeholder. Your token-substitution hook is failing one of:

- Rule 2.1 — its path-guard rejected Bridge's `CLAUDE_PLUGIN_ROOT`
- Rule 2.2 — it tried to write to the source `.mcp.json` instead of the cache copy
- Rule 2.5 — it tried to prompt the user for credentials but no tty was attached

Diagnose:

```bash
sudo cat $HOME_OF_ISO_AGENT/.claude/plugins/cache/<marketplace>/<plugin>/<ver>/.mcp.json
```

If the token is still the placeholder, your hook is the suspect. Manually invoke it as the iso UID with the path Bridge passes:

```bash
sudo -u agent-bridge-<slug> -H bash -c '
  cd /path/to/workdir
  CLAUDE_PLUGIN_ROOT=<the-shared-cache-path> \
    /path/to/your-hook.sh
'
```

and observe its exit code / output.

### 4.2 "Hook tracebacks flood the claude pane"

Your hook is hitting a `PermissionError` and not handling it. Wrap mutating ops with `try/except (PermissionError, OSError)` and fail-open when running under iso v2:

```python
import os

def under_iso_uid():
    controller_uid = os.environ.get('BRIDGE_CONTROLLER_UID', '').strip()
    return (
        os.environ.get('BRIDGE_AGENT_ID')
        and controller_uid.isdigit()
        and os.geteuid() != int(controller_uid)
    )

try:
    target_dir.mkdir(parents=True, exist_ok=True)
except (PermissionError, OSError):
    if under_iso_uid():
        return  # iso UID can't write here — silent skip
    raise
```

### 4.3 "Setup script runs as operator but plugin sees the operator's home"

The operator runs `bridge install` or `agent-bridge setup <X>` as themselves. Your install script (if any) gets the operator's `$HOME`. Plugin runtime later runs as the iso UID with a different `$HOME`. Don't write installer artifacts to the operator's `$HOME` expecting the plugin runtime to find them — write to `${BRIDGE_HOME}/data/shared/plugins-cache/marketplaces/<marketplace>/` or to per-agent paths the install script can compute from the roster.

## 5. Bridge-side reference issues

For background, these Bridge-side closures are the symmetric fixes to what this guide tells plugin authors:

- `#1212` — Bridge now registers any `<plugin>@<marketplace>` in claude settings, not only `@agent-bridge` (closed beta26)
- `#1213` — Bridge's iso-uid env propagation fixed so hook fail-open predicates work (closed beta26)
- `#1214` — Bridge's channel validator routes through the iso-side read fallback, no `sg` wrap needed (closed beta26)
- `#1215` — Bridge creates plugin state dirs (`.teams/`, `.ms365/`) with `02770` mode so iso UID can write (closed beta26)

If you observe a Bridge-side issue while authoring your plugin (env var that should propagate but doesn't, path your plugin can't traverse but should be able to), file at https://github.com/SYRS-AI/agent-bridge-public/issues so it can be addressed in a Bridge release.

## 6. Minimum viable iso v2 plugin checklist

Before publishing a plugin marketplace entry for use with Agent Bridge linux-user installs:

- [ ] No `CLAUDE_PLUGIN_ROOT` path-guard that rejects either of the two valid shapes (per-agent cache OR shared marketplace mirror — see rule 2.1)
- [ ] No write to the shared marketplace mirror; if mutating shipped files, write the per-agent cache copy explicitly (`$HOME/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`)
- [ ] All persistent state goes to `$HOME/.<plugin>/` or the derived workdir `${BRIDGE_HOME}/data/agents/${BRIDGE_AGENT_ID}/workdir/.<plugin>/` (Bridge does not reliably export `BRIDGE_AGENT_WORKDIR` — derive it from `BRIDGE_HOME` + `BRIDGE_AGENT_ID`)
- [ ] No `sudo`, no setuid-binary invocation, no `/etc` / `/var` / `/usr/local` writes
- [ ] No `read` from stdin, no interactive prompts, no browser callbacks bound to localhost-on-controller-host
- [ ] If MCP server is HTTP with token-injection: token substitution happens in the per-agent cache copy of `.mcp.json` AND the hook path-guard is Bridge-aware (or removed)
- [ ] Tested via a real `agent-bridge agent create ... --isolation linux-user` on a Linux host with at least one tool invocation end-to-end
- [ ] Hook tracebacks audited: `grep -RnE '(PermissionError|EACCES)' /home/awfmanager/.agent-bridge/data/agents/<slug>/home/.claude/projects/*/*.jsonl` (or your install's equivalent) returns clean

If your plugin passes this checklist, it should be safe to ship into a Bridge-managed iso v2 deployment.

## 7. Where to get help

- Operator runbook: `docs/isolation-acceptance-runbook.md`
- Migration guide for moving an existing install: `docs/isolation-migration-guide.md`
- Bridge runtime layout: `ARCHITECTURE.md`
- Live install behavior: `OPERATIONS.md`
- Known live-session quirks: `KNOWN_ISSUES.md`
- File issues: https://github.com/SYRS-AI/agent-bridge-public/issues

---

Last updated: v0.14.5-beta26 (2026-05-26). The contract described here is stable across the v0.14.x line. Major path or env-var changes will be flagged in `CHANGELOG.md` and noted at the top of this file.
