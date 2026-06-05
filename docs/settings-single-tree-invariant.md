# Settings single-tree invariant (#1455)

**Status:** invariant + doctor detectors shipped. The future **dynamic → static
agent promotion** feature MUST honor this invariant; the promotion feature
itself is tracked separately (see "Deferred feature" below) and is NOT
implemented here.

## The invariant

For any agent, the **effective** settings file must exist in **exactly one**
physical location, and every other location must be a **symlink** to it — never
a second real copy.

```
data/agents/<a>/home/.claude/settings.effective.json   # the ONE real file
data/agents/<a>/home/.claude/settings.json     -> settings.effective.json
data/agents/<a>/workdir/.claude/settings.json  -> ../../home/.claude/settings.effective.json
```

When this holds, `settings.json` in the home tree and `settings.json` in the
workdir tree resolve to the **same inode**, so they can never drift. When it is
violated — two real `settings.effective.json` files, one per tree — they drift
silently. Because `enabledPlugins` is a **preserved-user key**, a stale value in
the workdir-side copy sticks and survives restarts. That drift is the root cause
of **#1453** (a channel agent reading `enabledPlugins[<channel>]=false` from the
wrong tree and dropping all inbound).

The executable form of the invariant:

```
realpath(<workdir>/.claude/settings.json) == realpath(<home>/.claude/settings.json)
```

`scripts/smoke/1455-settings-two-tree-doctor.sh` (T1) asserts exactly this on a
correct layout — it is the check that would have caught #1453.

## The machinery already exists — reuse it, never hand-copy

The single-source render + atomic **relative** symlink is already implemented
and correct. Any code that materializes a settings tree MUST go through it
rather than hand-rolling a copy:

- `cmd_link_shared_settings` (`bridge-hooks.py`, the `link-shared-settings`
  subcommand) computes `os.path.relpath(shared_path, settings_path.parent)`
  (`bridge-hooks.py:2009`) and does an atomic `unlink` → `symlink_to(rel_target)`
  (`bridge-hooks.py:2011`), with sudo-as-iso fallbacks for isolated UIDs.
- The render side authors the **one** effective file:
  `bridge_ensure_claude_shared_settings_for_managed_workdir`
  (`lib/bridge-hooks.sh:138`) + the `render-shared-settings` /
  `bridge_layout_materialize_identity` path.

**Rule:** to place or re-point settings, render the effective file in the home
tree and call `link-shared-settings` for every other location. Do **not** write
a second `settings.effective.json` anywhere else.

## The doctor detectors (read-only, shipped)

Two `bridge-doctor.py` detectors surface a violation of the invariant. Both are
**report-only** — they never re-point a symlink or author policy; the operator
remediates with `link-shared-settings`.

- **`settings-two-tree-drift`** — an agent whose `home` and `workdir`
  `settings.json` resolve to **different** real files (the workdir copy is a
  second real file instead of a relative symlink back to the home effective
  tree). This is the inode divergence behind #1453.
- **`settings-multi-tree`** — an agent that has a real (non-symlink)
  `settings.effective.json` under **more than one** tree (both `home/.claude/`
  and `workdir/.claude/`). Exactly one physical effective file is allowed.

Both read `home` + `workdir` from `agent registry --json` (so the doctor stays
in lockstep with the bridge's own resolved paths) and never flag a
not-yet-rendered or dangling-symlink workdir (settings are read at launch, so an
unlinked workdir is benign).

Run them:

```bash
python3 bridge-doctor.py --json --detectors settings-two-tree-drift,settings-multi-tree
```

## Deferred feature — dynamic → static promotion

Today the only promotion path is `reclassify` (admin → static,
`bridge_agent_reclassify_static_admin` in `bridge-agent.sh`), which rewrites the
roster block but does **not** materialize a `home` tree. A genuine **dynamic →
static** promotion — where an agent that previously had only a `workdir` gets a
`home` tree for the first time — does **not exist yet**. That transition is the
exact moment the two-tree hazard bites: settings authored into the workdir
(the only tree a dynamic agent had) can end up duplicated into the new home tree
instead of the workdir being re-pointed at it.

When that feature is built, it MUST:

1. **Home is the single source of truth.** Render/author the effective settings
   into `home/.claude/settings.effective.json` and link
   `home/.claude/settings.json` → it.
2. **Migrate existing config into home, don't strand it in workdir.** Pull the
   dynamic agent's live engine settings (`enabledPlugins`,
   `extraKnownMarketplaces`, channel state) forward into the new home file by
   reusing `bridge_layout_materialize_identity` + the shared-settings render —
   never a one-off copy.
3. **Re-point the workdir, never duplicate it.** Replace
   `workdir/.claude/settings.json` with a **relative** symlink into the home
   tree via `link-shared-settings`. After promotion there must be **zero**
   physical `settings.effective.json` under `workdir/.claude/`.
4. **Assert the invariant at the end.** `realpath(workdir settings.json) ==
   realpath(home settings.json)`; fail the promotion loudly if not.

The dynamic → static promotion feature is **out of scope for #1455** and is
tracked as its own follow-up: see issue **#1555** (filed alongside this note).
Until it lands, the two doctor detectors above are the observability guardrail
that makes any two-tree regression (from a hand-migrated install or a future
feature) visible.
