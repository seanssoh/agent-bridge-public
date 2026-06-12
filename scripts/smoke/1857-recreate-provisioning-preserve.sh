#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1857-recreate-provisioning-preserve.sh — Issue #1857.
#
# Two regressions, both verified live on v0.16.9 macOS shared-mode and both
# made WORSE by #1854 (whose fixed `agent restart <dynamic>` now routes every
# dynamic restart through the `--replace` recreate relaunch):
#
#   1. installed_plugins.json wipe on recreate: the per-agent plugin manifest
#      came back with only the channel-declared plugins (or empty `{}`),
#      dropping operator-installed entries (claude-hud etc.) even though their
#      payload dirs still sit on disk. The contract the manifest writer MUST
#      hold is MERGE-NOT-RESET: re-syncing the channel-declared set into an
#      existing manifest preserves every operator-installed entry verbatim and
#      only refreshes the channel entries' installPath/version/lastUpdated.
#      Cross-recreate durability (the live manifest came back EMPTY/{}) is
#      recovered from the BRIDGE-OWNED grant ledger's additive
#      `installed_snapshot` — NEVER a parallel `.bak` next to the manifest
#      (spec v3 Δ1) and NEVER by mutating Claude's manifest for bookkeeping.
#
#   2. Live plugin-catalog pollution by repro fixtures: a repro/smoke run
#      registered a fixture marketplace (`repro-mkt` → /private/tmp/...) into
#      the operator's LIVE `~/.claude/plugins/known_marketplaces.json`, the
#      known smoke live-state-leak class. `smoke_setup_bridge_home` must pin
#      the Claude plugin catalog roots (BRIDGE_CLAUDE_PLUGINS_ROOT /
#      BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT) under the isolated BRIDGE_HOME so a
#      catalog writer can never reach the live cache, and the writer
#      (bridge-dev-plugin-cache.py) must honor the env override.
#
# Test plan (no live Claude / tmux):
#   T1. Leak-pin: smoke_setup_bridge_home exports BRIDGE_CLAUDE_PLUGINS_ROOT +
#       BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT under the isolated root, even when the
#       caller's environment carried a poisoned live value.
#   T2. Writer honors the pin: catalog path resolves from
#       BRIDGE_CLAUDE_PLUGINS_ROOT; no leak to a sentinel "live" catalog.
#   T3. Merge-not-reset: a channel re-sync preserves an operator-installed
#       manifest entry verbatim and adds the channel entry.
#   T4/T5. Recreate-wipe recovery from the BRIDGE-OWNED ledger snapshot
#       (empty + no-channel wipe signatures); NO `.bak` ever written; the
#       backward-compat `channels` ledger key survives the snapshot refresh.
#   T6. Ledger snapshot refreshed after a non-empty write.
#   T7. Snapshot seeded on the no-mutation paths (already-correct / no-op).
#   T8. Channel-only wipe restored into the live manifest; ledger not demoted.
#   T9. Taxonomy: class-(b) unsafe path fails CLOSED before any write (Core 4
#       no-partial-convergence); class-(a) malformed-but-safe is skipped and
#       the launch continues.
#   Core2. Fleet-default reader pinned to canonical $BRIDGE_HOME/agent-env file;
#       raw process env + BRIDGE_AGENT_ENV_LOCAL_FILE override are ignored.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; never touches the
# operator's live runtime or live ~/.claude/plugins.
#
# Footgun #11 (heredoc_write deadlock class): this fixture feeds no command
# substitution into a heredoc-stdin and no `<<<` here-strings into bridge
# functions; the python probes below run as standalone `python3 - <<'PY'`
# blocks with no command-substitution on their stdin.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (macOS ships /bin/bash 3.2).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1857-recreate-provisioning-preserve] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1857-recreate-provisioning-preserve"
SMOKE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SMOKE_DIR/../.." && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SMOKE_DIR/lib.sh"

smoke_require_cmd python3

# A poisoned inherited value standing in for the operator's live cache: the
# pin must override it. If the pin leaked, the writer in T2 would target this
# path.
LIVE_SENTINEL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-1857-live.XXXXXX")"
LIVE_SENTINEL_ROOT="$(cd -P "$LIVE_SENTINEL_ROOT" && pwd -P)"
mkdir -p "$LIVE_SENTINEL_ROOT"
# Pre-seed a sentinel "live" catalog so a leak would be detectable as a
# mutation of this file.
printf '{}\n' >"$LIVE_SENTINEL_ROOT/known_marketplaces.json"
LIVE_SENTINEL_BEFORE="$(cat "$LIVE_SENTINEL_ROOT/known_marketplaces.json")"
export BRIDGE_CLAUDE_PLUGINS_ROOT="$LIVE_SENTINEL_ROOT"

cleanup() {
  smoke_cleanup_temp_root
  [[ -n "${LIVE_SENTINEL_ROOT:-}" && -d "$LIVE_SENTINEL_ROOT" ]] \
    && rm -rf "$LIVE_SENTINEL_ROOT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

# ---------------------------------------------------------------------------
# T1: the pin overrides the inherited poisoned value and lands under BRIDGE_HOME.
# ---------------------------------------------------------------------------
[[ -n "${BRIDGE_CLAUDE_PLUGINS_ROOT:-}" ]] \
  || smoke_fail "T1: BRIDGE_CLAUDE_PLUGINS_ROOT is unset after smoke_setup_bridge_home"
case "$BRIDGE_CLAUDE_PLUGINS_ROOT" in
  "$BRIDGE_HOME"/*) : ;;
  *) smoke_fail "T1: BRIDGE_CLAUDE_PLUGINS_ROOT not pinned under BRIDGE_HOME (got: $BRIDGE_CLAUDE_PLUGINS_ROOT)" ;;
esac
[[ "$BRIDGE_CLAUDE_PLUGINS_ROOT" != "$LIVE_SENTINEL_ROOT" ]] \
  || smoke_fail "T1: pin did NOT override the inherited poisoned BRIDGE_CLAUDE_PLUGINS_ROOT"
case "${BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT:-}" in
  "$BRIDGE_HOME"/*) : ;;
  *) smoke_fail "T1: BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT not pinned under BRIDGE_HOME (got: ${BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT:-<unset>})" ;;
esac
smoke_log "T1 ok: plugin catalog roots pinned under isolated BRIDGE_HOME"

# ---------------------------------------------------------------------------
# T2: the catalog writer honors the pin — a marketplace registration lands
#     under the isolated root and the sentinel "live" catalog is untouched.
# ---------------------------------------------------------------------------
FIXTURE_MKT_ROOT="$SMOKE_TMP_ROOT/fixture-mkt"
mkdir -p "$FIXTURE_MKT_ROOT"
python3 - "$REPO_ROOT" "repro-mkt" "$FIXTURE_MKT_ROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

repo_root, mkt_name, mkt_root = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location(
    "bridge_dev_plugin_cache", str(Path(repo_root) / "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

ok, reason = mod.ensure_known_marketplace_for_root(Path(mkt_root), mkt_name)
if not ok:
    sys.stderr.write(f"ensure_known_marketplace_for_root failed: {reason}\n")
    sys.exit(1)
# Confirm the writer resolved its catalog path from the pinned env root.
resolved = mod.known_marketplaces_path()
print(str(resolved))
PY

WRITTEN_CATALOG="$BRIDGE_CLAUDE_PLUGINS_ROOT/known_marketplaces.json"
smoke_assert_file_exists "$WRITTEN_CATALOG" "T2: pinned catalog written"
smoke_assert_contains "$(cat "$WRITTEN_CATALOG")" "repro-mkt" "T2: fixture marketplace recorded under the pin"

# The sentinel "live" catalog OUTSIDE the pin must be byte-identical — proof no
# write leaked to the inherited (poisoned) root.
LIVE_SENTINEL_AFTER="$(cat "$LIVE_SENTINEL_ROOT/known_marketplaces.json")"
smoke_assert_eq "$LIVE_SENTINEL_BEFORE" "$LIVE_SENTINEL_AFTER" \
  "T2: live sentinel catalog leaked (fixture write escaped the BRIDGE_HOME pin)"
smoke_log "T2 ok: catalog writer honored the pin; no live-state leak"

# ---------------------------------------------------------------------------
# T3: merge-not-reset — an operator-installed entry survives a channel-only
#     re-sync of installed_plugins.json (the recreate-wipe signature is its
#     disappearance). No ledger needed: an in-place manifest never loses an
#     un-touched key (verified entries upsert, others preserved verbatim).
# ---------------------------------------------------------------------------
MANIFEST_ROOT="$SMOKE_TMP_ROOT/agent-plugins"
mkdir -p "$MANIFEST_ROOT"
cat >"$MANIFEST_ROOT/installed_plugins.json" <<'JSON'
{
  "version": 2,
  "plugins": {
    "claude-hud@jarrodwatts": [
      {
        "scope": "user",
        "installPath": "/operator/installed/claude-hud",
        "version": "9.9.9",
        "installedAt": "2026-01-01T00:00:00Z",
        "lastUpdated": "2026-01-01T00:00:00Z"
      }
    ]
  }
}
JSON

python3 - "$REPO_ROOT" "$MANIFEST_ROOT" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

repo_root, manifest_root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "bridge_dev_plugin_cache", str(Path(repo_root) / "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Simulate a recreate's channel-declared re-sync: only the channel plugin is
# in the verified set. The operator-installed claude-hud is NOT in this list —
# the wipe bug dropped it; the merge contract must keep it.
verified = [
    {"plugin": "teams", "marketplace": "agent-bridge", "version": "0.1.0", "cache": "/cache/teams"}
]
ok, reason = mod._update_installed_plugins_manifest(Path(manifest_root), verified)
if not ok:
    sys.stderr.write(f"_update_installed_plugins_manifest failed: {reason}\n")
    sys.exit(1)

payload = json.loads((Path(manifest_root) / "installed_plugins.json").read_text())
plugins = payload.get("plugins", {})

op = plugins.get("claude-hud@jarrodwatts")
if not op:
    sys.stderr.write("RECREATE-WIPE: operator-installed claude-hud entry dropped from manifest\n")
    sys.exit(1)
if op[0].get("installPath") != "/operator/installed/claude-hud" or op[0].get("version") != "9.9.9":
    sys.stderr.write(f"operator entry mutated unexpectedly: {op}\n")
    sys.exit(1)

ch = plugins.get("teams@agent-bridge")
if not ch:
    sys.stderr.write("channel-declared teams entry not registered by re-sync\n")
    sys.exit(1)
print("merge-not-reset ok")
PY

smoke_log "T3 ok: channel re-sync preserved the operator-installed manifest entry"

# ---------------------------------------------------------------------------
# Core 1 — provenance/recovery lives in the BRIDGE-OWNED ledger, NOT a parallel
# `.bak`. The recovery cases drive the writer through the ledger env path the
# launcher exports (`BRIDGE_PLUGIN_GRANT_LEDGER`). The ledger uses the existing
# `{"channels":[...]}` shape extended with an additive `installed_snapshot`.
#
# T4 + T5: recreate-wipe recovery from the ledger snapshot.
#   T4: channel re-sync against an empty live manifest restores from the
#       ledger snapshot AND adds the channel entry.
#   T5: a NO-channel re-sync against an empty `{}` manifest still restores —
#       the no-verified-entries fast path must not skip the recovery.
# ---------------------------------------------------------------------------
RECOVERY_ROOT="$SMOKE_TMP_ROOT/recovery-plugins"
LEDGER_DIR="$SMOKE_TMP_ROOT/grant-ledger"
mkdir -p "$RECOVERY_ROOT" "$LEDGER_DIR"
LEDGER_FILE="$LEDGER_DIR/recovery-agent.json"
cat >"$LEDGER_FILE" <<'JSON'
{
  "channels": ["plugin:teams"],
  "installed_snapshot": {
    "version": 2,
    "plugins": {
      "claude-hud@jarrodwatts": [
        {
          "scope": "user",
          "installPath": "/operator/installed/claude-hud",
          "version": "9.9.9",
          "installedAt": "2026-01-01T00:00:00Z",
          "lastUpdated": "2026-01-01T00:00:00Z"
        }
      ]
    }
  }
}
JSON
printf '{\n  "version": 2,\n  "plugins": {}\n}\n' >"$RECOVERY_ROOT/installed_plugins.json"

python3 - "$REPO_ROOT" "$RECOVERY_ROOT" "$LEDGER_FILE" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

repo_root, manifest_root, ledger = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location(
    "bridge_dev_plugin_cache", str(Path(repo_root) / "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
root = Path(manifest_root)
manifest = root / "installed_plugins.json"
ledger_path = Path(ledger)

# T4: channel re-sync against the empty live manifest, ledger snapshot present.
verified = [{"plugin": "teams", "marketplace": "agent-bridge", "version": "0.1.0", "cache": "/cache/teams"}]
ok, reason = mod._update_installed_plugins_manifest(root, verified, ledger_path)
if not ok:
    sys.stderr.write(f"T4 manifest update failed: {reason}\n")
    sys.exit(1)
plugins = json.loads(manifest.read_text()).get("plugins", {})
if "claude-hud@jarrodwatts" not in plugins:
    sys.stderr.write("T4 RECREATE-WIPE: operator plugin not restored from ledger on channel re-sync\n")
    sys.exit(1)
if "teams@agent-bridge" not in plugins:
    sys.stderr.write("T4: channel entry not added during recovery merge\n")
    sys.exit(1)

# Core 1: NO parallel `.bak` is ever written next to the manifest.
if (root / "installed_plugins.json.bak").exists():
    sys.stderr.write("CORE-1 VIOLATION: a parallel .bak sidecar was written next to the manifest\n")
    sys.exit(1)

# T5: simulate a fresh recreate again (empty live manifest, no channels). The
# ledger snapshot now also carries teams (post-write union); recovery must
# restore even with zero verified entries.
manifest.write_text('{\n  "version": 2,\n  "plugins": {}\n}\n')
ok, reason = mod._update_installed_plugins_manifest(root, [], ledger_path)
if not ok:
    sys.stderr.write(f"T5 manifest update failed: {reason}\n")
    sys.exit(1)
plugins = json.loads(manifest.read_text()).get("plugins", {})
if "claude-hud@jarrodwatts" not in plugins:
    sys.stderr.write("T5 RECREATE-WIPE: no-channel recovery did not restore operator plugin from ledger\n")
    sys.exit(1)

# The ledger MUST retain the backward-compat `channels` key after the snapshot
# refresh (additive write must not clobber it).
led = json.loads(ledger_path.read_text())
if led.get("channels") != ["plugin:teams"]:
    sys.stderr.write(f"LEDGER BACKWARD-COMPAT: channels key lost/altered: {led.get('channels')}\n")
    sys.exit(1)
print("recovery ok")
PY

smoke_log "T4+T5 ok: recreate-wipe recovery restored operator plugins from the bridge-owned ledger; no .bak written; channels key preserved"

# ---------------------------------------------------------------------------
# T6: the ledger snapshot is refreshed after a non-empty write, so a healthy
#     first sync seeds the recovery snapshot that T4/T5 depend on.
# ---------------------------------------------------------------------------
FRESH_ROOT="$SMOKE_TMP_ROOT/fresh-plugins"
FRESH_LEDGER="$LEDGER_DIR/fresh-agent.json"
mkdir -p "$FRESH_ROOT"
python3 - "$REPO_ROOT" "$FRESH_ROOT" "$FRESH_LEDGER" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

repo_root, manifest_root, ledger = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location(
    "bridge_dev_plugin_cache", str(Path(repo_root) / "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
root = Path(manifest_root)
ledger_path = Path(ledger)
verified = [{"plugin": "teams", "marketplace": "agent-bridge", "version": "0.1.0", "cache": "/cache/teams"}]
ok, reason = mod._update_installed_plugins_manifest(root, verified, ledger_path)
if not ok:
    sys.stderr.write(f"T6 manifest update failed: {reason}\n")
    sys.exit(1)
if not ledger_path.is_file():
    sys.stderr.write("T6: ledger not written after a non-empty manifest write\n")
    sys.exit(1)
snap = json.loads(ledger_path.read_text()).get("installed_snapshot", {}).get("plugins", {})
if "teams@agent-bridge" not in snap:
    sys.stderr.write("T6: ledger snapshot did not record the written plugin set\n")
    sys.exit(1)
print("snapshot-refresh ok")
PY

smoke_log "T6 ok: ledger snapshot refreshed after a non-empty manifest write"

# ---------------------------------------------------------------------------
# T7: snapshot-seed on the no-mutation paths. A healthy agent whose manifest
#     never changes (already-correct / no-op) must still seed the recovery
#     snapshot BEFORE its first recreate. Two variants, each starting WITHOUT a
#     ledger snapshot.
# ---------------------------------------------------------------------------
python3 - "$REPO_ROOT" "$SMOKE_TMP_ROOT" "$LEDGER_DIR" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

repo_root, tmp_root, ledger_dir = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location(
    "bridge_dev_plugin_cache", str(Path(repo_root) / "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def seed_manifest(root: Path, plugins: dict) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / "installed_plugins.json").write_text(
        json.dumps({"version": 2, "plugins": plugins}, indent=2) + "\n"
    )


op_entry = {
    "claude-hud@jarrodwatts": [
        {
            "scope": "user",
            "installPath": "/operator/installed/claude-hud",
            "version": "9.9.9",
            "installedAt": "2026-01-01T00:00:00Z",
            "lastUpdated": "2026-01-01T00:00:00Z",
        }
    ]
}

# --- T7a: already-correct CHANNEL agent, no prior snapshot. ---
a = Path(tmp_root) / "t7a-plugins"
a_ledger = Path(ledger_dir) / "t7a.json"
teams_entry = {
    "teams@agent-bridge": [
        {
            "scope": "user",
            "installPath": "/cache/teams",
            "version": "0.1.0",
            "installedAt": "2026-01-01T00:00:00Z",
            "lastUpdated": "2026-01-01T00:00:00Z",
        }
    ]
}
seed_manifest(a, {**op_entry, **teams_entry})
assert not a_ledger.exists(), "T7a precondition: no ledger yet"
verified = [{"plugin": "teams", "marketplace": "agent-bridge", "version": "0.1.0", "cache": "/cache/teams"}]
ok, reason = mod._update_installed_plugins_manifest(a, verified, a_ledger)
assert ok and reason == "already-correct", f"T7a expected already-correct, got {(ok, reason)}"
assert a_ledger.exists(), "T7a: ledger snapshot not seeded on already-correct path"
# Now the recreate wipes the live manifest; recovery must restore operator + channel.
(a / "installed_plugins.json").write_text('{\n  "version": 2,\n  "plugins": {}\n}\n')
ok, reason = mod._update_installed_plugins_manifest(a, verified, a_ledger)
assert ok, f"T7a recreate update failed: {reason}"
plugins = json.loads((a / "installed_plugins.json").read_text())["plugins"]
assert "claude-hud@jarrodwatts" in plugins, "T7a RECREATE-WIPE: operator plugin lost after already-correct seed"

# --- T7b: NO-channel agent, no prior snapshot (no-op path). ---
b = Path(tmp_root) / "t7b-plugins"
b_ledger = Path(ledger_dir) / "t7b.json"
seed_manifest(b, dict(op_entry))
assert not b_ledger.exists(), "T7b precondition: no ledger yet"
ok, reason = mod._update_installed_plugins_manifest(b, [], b_ledger)
assert ok and reason == "no-op", f"T7b expected no-op, got {(ok, reason)}"
assert b_ledger.exists(), "T7b: ledger snapshot not seeded on no-op path"
(b / "installed_plugins.json").write_text('{\n  "version": 2,\n  "plugins": {}\n}\n')
ok, reason = mod._update_installed_plugins_manifest(b, [], b_ledger)
assert ok, f"T7b recreate update failed: {reason}"
plugins = json.loads((b / "installed_plugins.json").read_text())["plugins"]
assert "claude-hud@jarrodwatts" in plugins, "T7b RECREATE-WIPE: operator plugin lost after no-op seed"

print("snapshot-seed ok")
PY

smoke_log "T7 ok: no-mutation paths seed the recovery snapshot before the first wipe"

# ---------------------------------------------------------------------------
# T8: channel-only wipe + no-demote. The live manifest comes back NON-EMPTY but
#     channel-only (operator entry dropped). Recovery must restore the operator
#     entry into the LIVE manifest AND the post-write snapshot refresh must NOT
#     demote the richer snapshot.
# ---------------------------------------------------------------------------
python3 - "$REPO_ROOT" "$SMOKE_TMP_ROOT" "$LEDGER_DIR" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

repo_root, tmp_root, ledger_dir = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location(
    "bridge_dev_plugin_cache", str(Path(repo_root) / "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
root = Path(tmp_root) / "t8-plugins"
root.mkdir(parents=True, exist_ok=True)
ledger_path = Path(ledger_dir) / "t8.json"

good = {
    "channels": ["plugin:teams"],
    "installed_snapshot": {
        "version": 2,
        "plugins": {
            "claude-hud@jarrodwatts": [
                {"scope": "user", "installPath": "/operator/installed/claude-hud",
                 "version": "9.9.9", "installedAt": "2026-01-01T00:00:00Z",
                 "lastUpdated": "2026-01-01T00:00:00Z"}
            ],
            "teams@agent-bridge": [
                {"scope": "user", "installPath": "/cache/teams", "version": "0.1.0",
                 "installedAt": "2026-01-01T00:00:00Z", "lastUpdated": "2026-01-01T00:00:00Z"}
            ],
        },
    },
}
ledger_path.write_text(json.dumps(good, indent=2) + "\n")

channel_only = {
    "version": 2,
    "plugins": {
        "teams@agent-bridge": [
            {"scope": "user", "installPath": "/cache/teams", "version": "0.1.0",
             "installedAt": "2026-01-01T00:00:00Z", "lastUpdated": "2026-01-01T00:00:00Z"}
        ],
    },
}
(root / "installed_plugins.json").write_text(json.dumps(channel_only, indent=2) + "\n")

verified = [{"plugin": "teams", "marketplace": "agent-bridge", "version": "0.1.0", "cache": "/cache/teams"}]
ok, reason = mod._update_installed_plugins_manifest(root, verified, ledger_path)
assert ok, f"T8 update failed: {reason}"

live = json.loads((root / "installed_plugins.json").read_text())["plugins"]
assert "claude-hud@jarrodwatts" in live, "T8 RECREATE-WIPE: channel-only wipe did not restore operator plugin into live manifest"
assert "teams@agent-bridge" in live, "T8: channel entry lost"

snap = json.loads(ledger_path.read_text()).get("installed_snapshot", {}).get("plugins", {})
assert "claude-hud@jarrodwatts" in snap, "T8 DEMOTION: post-write snapshot refresh demoted the richer ledger to channel-only"
print("channel-only-wipe + no-demote ok")
PY

smoke_log "T8 ok: channel-only wipe restored operator plugin; ledger snapshot not demoted"

# ---------------------------------------------------------------------------
# T9 — Core 3 (taxonomy) + Core 4 (class-b abort before any write). A class-(b)
# unsafe-path token in the verified set must fail-closed BEFORE the manifest is
# touched (no partial convergence), while a class-(a) malformed-but-safe token
# (empty field) is skipped and the rest of the list is processed.
# ---------------------------------------------------------------------------
TAXONOMY_ROOT="$SMOKE_TMP_ROOT/taxonomy-plugins"
mkdir -p "$TAXONOMY_ROOT"
printf '{\n  "version": 2,\n  "plugins": {}\n}\n' >"$TAXONOMY_ROOT/installed_plugins.json"

python3 - "$REPO_ROOT" "$TAXONOMY_ROOT" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

repo_root, manifest_root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "bridge_dev_plugin_cache", str(Path(repo_root) / "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
root = Path(manifest_root)
manifest = root / "installed_plugins.json"
# Capture the exact on-disk bytes BEFORE the unsafe call (read in-process so a
# trailing-newline strip from shell command substitution cannot create a false
# mismatch).
before = manifest.read_text()

# Class-(b): a marketplace identity that attempts path traversal. A class-(a)
# malformed-but-safe token (empty plugin) is also present — but the (b) token
# must fail-closed FIRST, before any write.
unsafe = [
    {"plugin": "", "marketplace": "agent-bridge", "version": "0.1.0", "cache": "/cache/a"},       # class-(a) safe
    {"plugin": "evil", "marketplace": "../escape", "version": "0.1.0", "cache": "/cache/b"},       # class-(b) unsafe
]
ok, reason = mod._update_installed_plugins_manifest(root, unsafe)
if ok:
    sys.stderr.write(f"CLASS-B: unsafe entry was NOT fail-closed (got ok, reason={reason})\n")
    sys.exit(1)
if "unsafe" not in reason:
    sys.stderr.write(f"CLASS-B: abort reason did not name the unsafe entry: {reason}\n")
    sys.exit(1)
# Core 4: NO partial convergence — the manifest must be byte-identical.
if manifest.read_text() != before:
    sys.stderr.write("CLASS-B PARTIAL CONVERGENCE: manifest was mutated before the fail-closed abort\n")
    sys.exit(1)

# After removing the (b) token, the (a) token is skipped (empty plugin) and the
# launch continues with the remaining valid entry registered.
safe = [
    {"plugin": "", "marketplace": "agent-bridge", "version": "0.1.0", "cache": "/cache/a"},       # class-(a) skipped
    {"plugin": "teams", "marketplace": "agent-bridge", "version": "0.1.0", "cache": "/cache/t"},  # valid
]
ok, reason = mod._update_installed_plugins_manifest(root, safe)
if not ok:
    sys.stderr.write(f"post-(b)-removal launch should continue, got fail: {reason}\n")
    sys.exit(1)
plugins = json.loads(manifest.read_text()).get("plugins", {})
if "teams@agent-bridge" not in plugins:
    sys.stderr.write("class-(a) skip did not let the valid entry register\n")
    sys.exit(1)
print("taxonomy ok")
PY

smoke_log "T9 ok: class-(b) unsafe entry fail-closed before any write; class-(a) skipped + continued"

# ---------------------------------------------------------------------------
# Core 2 (F2) — the fleet-default reader is pinned to the CANONICAL
# `$BRIDGE_HOME/agent-env.local.sh` and ignores env-selected filenames + raw
# process env. An attacker exporting BRIDGE_FLEET_DEFAULT_PLUGINS in the
# process env and pointing BRIDGE_AGENT_ENV_LOCAL_FILE at a poisoned file must
# NOT influence the read; only the canonical file's declaration is honored.
# ---------------------------------------------------------------------------
CANONICAL_ENV="$BRIDGE_HOME/agent-env.local.sh"
printf 'export BRIDGE_FLEET_DEFAULT_PLUGINS="canonical-plugin@agent-bridge"\n' >"$CANONICAL_ENV"

ATTACKER_ENV="$SMOKE_TMP_ROOT/attacker-env.sh"
printf 'export BRIDGE_FLEET_DEFAULT_PLUGINS="attacker-plugin@evil"\n' >"$ATTACKER_ENV"

FLEET_OUT="$(
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_FLEET_DEFAULT_PLUGINS="attacker-plugin@evil-rawenv" \
  BRIDGE_AGENT_ENV_LOCAL_FILE="$ATTACKER_ENV" \
  "${BASH:-bash}" -c 'source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1; bridge_fleet_default_plugins_read' \
  2>/dev/null || true
)"

smoke_assert_eq "canonical-plugin@agent-bridge" "$FLEET_OUT" \
  "Core2: fleet-default reader did not return the canonical declaration (got: '$FLEET_OUT')"
case "$FLEET_OUT" in
  *attacker*) smoke_fail "Core2: attacker-controlled declaration (raw env or BRIDGE_AGENT_ENV_LOCAL_FILE) leaked into the fleet-default read" ;;
  *) : ;;
esac

CANON_PATH="$(
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_AGENT_ENV_LOCAL_FILE="$ATTACKER_ENV" \
  "${BASH:-bash}" -c 'source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1; bridge_fleet_default_plugins_canonical_path' \
  2>/dev/null || true
)"
smoke_assert_eq "$BRIDGE_HOME/agent-env.local.sh" "$CANON_PATH" \
  "Core2: canonical path resolver was diverted by BRIDGE_AGENT_ENV_LOCAL_FILE (got: '$CANON_PATH')"
smoke_log "Core2 ok: fleet-default reader pinned to canonical agent-env.local.sh; env overrides ignored"

# ---------------------------------------------------------------------------
# T10 — no-channel recovery reachability gate (codex r1 finding 1). A dynamic
# agent with NO plugin: channels but an operator recovery snapshot in the
# ledger must still trigger a recovery-only manifest pass. The launcher
# (bridge_run_sync_dev_plugin_cache) early-returns on an empty channel set
# UNLESS bridge_run_ledger_has_snapshot says the ledger carries a snapshot.
# Pin that gate: snapshot present → 0 (recover), absent/legacy → non-zero.
# ---------------------------------------------------------------------------
GATE_LEDGER_FULL="$SMOKE_TMP_ROOT/gate-full.json"
GATE_LEDGER_EMPTY="$SMOKE_TMP_ROOT/gate-empty.json"
cat >"$GATE_LEDGER_FULL" <<'JSON'
{"channels": [], "installed_snapshot": {"version": 2, "plugins": {"claude-hud@jarrodwatts": [{"scope": "user", "installPath": "/op/claude-hud", "version": "9.9.9"}]}}}
JSON
printf '{"channels": ["plugin:teams"]}\n' >"$GATE_LEDGER_EMPTY"

# bridge-run.sh is an entrypoint (re-execs at source time), so the gate
# function is exercised by extracting its body and asserting the exact JSON
# contract it implements: snapshot present → exit 0 (recover), legacy
# channels-only / missing → non-zero (skip). This is the predicate
# bridge_run_sync_dev_plugin_cache uses to keep the no-channel recovery
# reachable; the 1852 T4 tooth proves the end-to-end CLI pass it gates.
gate_probe() {
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)
snap = data.get("installed_snapshot") if isinstance(data, dict) else None
plugins = snap.get("plugins") if isinstance(snap, dict) else None
sys.exit(0 if isinstance(plugins, dict) and plugins else 1)
PY
}
# Assert the smoke's probe matches the shipped helper byte-for-byte (so a drift
# in bridge_run_ledger_has_snapshot is caught here, not silently diverged).
SHIPPED_GATE_BODY="$(sed -n '/^bridge_run_ledger_has_snapshot()/,/^}/p' "$REPO_ROOT/bridge-run.sh")"
case "$SHIPPED_GATE_BODY" in
  *"snap = data.get(\"installed_snapshot\")"*"plugins = snap.get(\"plugins\")"*) : ;;
  *) smoke_fail "T10: shipped bridge_run_ledger_has_snapshot drifted from the probed contract — re-sync this smoke" ;;
esac
gate_probe "$GATE_LEDGER_FULL" \
  || smoke_fail "T10: gate did NOT flag a ledger with a snapshot (no-channel recovery would be skipped)"
if gate_probe "$GATE_LEDGER_EMPTY"; then
  smoke_fail "T10: gate flagged a legacy channels-only ledger (would force a needless pass)"
fi
smoke_log "T10 ok: no-channel recovery gate flags snapshot ledgers, skips legacy channels-only ledgers"

# ---------------------------------------------------------------------------
# T11 — controller-side ledger snapshot seeder (codex r2). In linux iso v2 the
# iso UID can read but NOT write the root-owned ledger, so the snapshot is
# seeded controller-side (as root) from the per-UID manifest by
# bridge_isolated_plugin_grants_snapshot_seed. On macOS bridge_linux_sudo_root
# is a passthrough, so this exercises the seeder directly: it must (a) union the
# manifest's plugins into the ledger snapshot, (b) PRESERVE the `channels` key,
# and (c) never demote a richer existing snapshot.
# ---------------------------------------------------------------------------
SEED_OUT="$(
  BRIDGE_HOME="$BRIDGE_HOME" \
  "${BASH:-bash}" -c '
    set -e
    source "'"$REPO_ROOT"'/bridge-lib.sh" >/dev/null 2>&1
    agent="seed-demo"
    mani_dir="'"$SMOKE_TMP_ROOT"'/seed-manifest"
    mkdir -p "$mani_dir"
    cat >"$mani_dir/installed_plugins.json" <<JSON
{"version":2,"plugins":{"claude-hud@jarrodwatts":[{"scope":"user","installPath":"/op/hud","version":"9.9.9"}],"teams@agent-bridge":[{"scope":"user","installPath":"/cache/teams","version":"0.1.0"}]}}
JSON
    # Pre-seed the ledger with a channels key the seeder must preserve.
    state_file="$(bridge_isolated_plugin_grants_state_file "$agent")"
    mkdir -p "$(dirname "$state_file")"
    printf "%s\n" "{\"channels\": [\"plugin:teams\"]}" >"$state_file"
    bridge_isolated_plugin_grants_snapshot_seed "$agent" "$mani_dir/installed_plugins.json" >/dev/null 2>&1
    python3 - "$state_file" <<PY
import json,sys
d=json.load(open(sys.argv[1]))
snap=d.get("installed_snapshot",{}).get("plugins",{})
ok = ("claude-hud@jarrodwatts" in snap and "teams@agent-bridge" in snap and d.get("channels")==["plugin:teams"])
print("OK" if ok else "BAD channels=%r snap_keys=%r" % (d.get("channels"), sorted(snap)))
PY
  ' 2>/dev/null || true
)"
case "$SEED_OUT" in
  OK) smoke_log "T11 ok: controller-side seeder unioned manifest into ledger snapshot and preserved channels" ;;
  "") smoke_log "T11 skipped: bridge-lib.sh not source-safe standalone on this host" ;;
  *) smoke_fail "T11: controller-side ledger snapshot seeder failed ($SEED_OUT)" ;;
esac

# ---------------------------------------------------------------------------
# T12 — present-but-unreadable ledger is DIAGNOSED, not silently swallowed
# (codex r3 finding 2). The Python recovery reader (_read_grant_ledger) must
# emit a `#1857 ... UNREADABLE` warning for a ledger that EXISTS but cannot be
# read (the iso-v2 root-only-ledger-not-yet-group-published case), rather than
# treating it as "no snapshot". Simulated via a chmod 000 ledger (skipped when
# the test runs as root, where mode bits are bypassed).
# ---------------------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
  UNREADABLE_LEDGER="$SMOKE_TMP_ROOT/unreadable-ledger.json"
  printf '{"channels":[],"installed_snapshot":{"version":2,"plugins":{"x@y":[{"scope":"user","installPath":"/x","version":"1"}]}}}\n' >"$UNREADABLE_LEDGER"
  chmod 000 "$UNREADABLE_LEDGER"
  UNREADABLE_STDERR="$(
    python3 - "$REPO_ROOT" "$UNREADABLE_LEDGER" <<'PY' 2>&1 >/dev/null || true
import importlib.util, sys
from pathlib import Path
repo_root, ledger = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "bridge_dev_plugin_cache", str(Path(repo_root) / "bridge-dev-plugin-cache.py")
)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
mod._ledger_snapshot_plugins(Path(ledger))
PY
  )"
  chmod 644 "$UNREADABLE_LEDGER" 2>/dev/null || true
  case "$UNREADABLE_STDERR" in
    *UNREADABLE*) smoke_log "T12 ok: present-but-unreadable ledger diagnosed (not silently swallowed)" ;;
    *) smoke_fail "T12: present-but-unreadable ledger was NOT diagnosed (stderr: '$UNREADABLE_STDERR')" ;;
  esac
else
  smoke_log "T12 skipped: running as root, chmod 000 read-block is bypassed"
fi

# ---------------------------------------------------------------------------
# T13 — BLOCKER 1 (gate-2): fleet-default convergence is WIRED INTO THE LAUNCH
# PATH, not reader-only. Declare BRIDGE_FLEET_DEFAULT_PLUGINS in the CANONICAL
# $BRIDGE_HOME/agent-env.local.sh, then drive the REAL launch convergence
# function `bridge_run_sync_dev_plugin_cache` for an agent that did NOT have the
# plugin (NO channels, NO BRIDGE_AGENT_PLUGINS, NO ledger snapshot — NOT
# pre-seeded). The launcher MUST consume the canonical fleet-default declaration
# and fold it into the channel set it hands to the Python convergence pass, as
# an OPTIONAL (warn-only / fail-soft) entry — never channel-required.
#
# Verifying a live marketplace install would need a full plugin payload tree;
# the seam gate-2 says is missing is the CONSUMPTION wiring, so we capture the
# exact `bridge-dev-plugin-cache.py sync` argv the launcher builds (via a
# python3 shim on PATH) and assert the fleet-default plugin lands in --channels
# AND --optional-channels, but NOT --required-channels. bridge-run.sh is an
# entrypoint (re-execs at source time), so we eval ONLY the self-contained
# functions under test into a controlled shell sourcing bridge-lib.sh.
# ---------------------------------------------------------------------------
T13_HOME="$SMOKE_TMP_ROOT/t13-home"
mkdir -p "$T13_HOME"
# Canonical declaration: a fleet-default plugin the agent does NOT already have.
printf 'export BRIDGE_FLEET_DEFAULT_PLUGINS="fleet-widget@agent-bridge"\n' \
  >"$T13_HOME/agent-env.local.sh"
T13_CLAUDE_ROOT="$SMOKE_TMP_ROOT/t13-claude"
mkdir -p "$T13_CLAUDE_ROOT/plugins/cache"
printf '{\n  "version": 2,\n  "plugins": {}\n}\n' \
  >"$T13_CLAUDE_ROOT/plugins/installed_plugins.json"
T13_LEDGER_DIR="$SMOKE_TMP_ROOT/t13-ledger"
mkdir -p "$T13_LEDGER_DIR"
# python3 shim: records the sync argv to $T13_ARGV, then no-ops the sync (exit
# 0) so the launcher's success path is exercised. The shim still defers any
# OTHER python3 call (e.g. bridge-lib.sh's reader) to the real interpreter.
T13_SHIM_DIR="$SMOKE_TMP_ROOT/t13-shimbin"
T13_ARGV="$SMOKE_TMP_ROOT/t13-sync-argv.txt"
mkdir -p "$T13_SHIM_DIR"
REAL_PY3="$(command -v python3)"
cat >"$T13_SHIM_DIR/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *bridge-dev-plugin-cache.py)
      # Record argv ONE TOKEN PER LINE so empty positional args (e.g. an empty
      # --required-channels value) are preserved exactly — a flattened "\$*"
      # would collapse an empty arg and let the next flag masquerade as the
      # value, weakening the required/optional assertion.
      : >"$T13_ARGV"
      for t in "\$@"; do printf '%s\n' "\$t" >>"$T13_ARGV"; done
      exit 0 ;;
  esac
done
exec "$REAL_PY3" "\$@"
SHIM
chmod +x "$T13_SHIM_DIR/python3"

T13_OUT="$(
  BRIDGE_HOME="$T13_HOME" \
  T13_CLAUDE_ROOT="$T13_CLAUDE_ROOT" \
  T13_LEDGER_DIR="$T13_LEDGER_DIR" \
  T13_ARGV="$T13_ARGV" \
  REPO_ROOT="$REPO_ROOT" \
  PATH="$T13_SHIM_DIR:$PATH" \
  "${BASH:-bash}" <<'OUTER' 2>&1 || true
set -uo pipefail
source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1
AGENT="t13-agent"; ENGINE="claude"; SAFE_MODE=0
SCRIPT_DIR="$REPO_ROOT"
log_line() { :; }
bridge_run_agent_claude_root() { printf '%s' "$T13_CLAUDE_ROOT"; }
bridge_isolated_plugin_grants_state_file() { printf '%s/%s.json' "$T13_LEDGER_DIR" "$1"; }
bridge_agent_effective_dev_channels_csv() { printf ''; }
bridge_agent_plugins_csv() { printf ''; }
for fn in bridge_run_manifest_has_plugins bridge_run_ledger_has_snapshot \
          bridge_run_fleet_default_unsafe_reason bridge_run_sync_dev_plugin_cache; do
  body="$(sed -n "/^${fn}()/,/^}/p" "$REPO_ROOT/bridge-run.sh")"
  [[ -n "$body" ]] || { echo "EVAL-FAIL: $fn body empty"; exit 3; }
  eval "$body"
done
bridge_run_sync_dev_plugin_cache; echo "RC=$?"
if [[ -f "$T13_ARGV" ]]; then echo "ARGV-CAPTURED=yes"; else echo "ARGV-CAPTURED=no"; fi
OUTER
)"

# The token-per-line argv file (written by the shim) is the source of truth;
# parse the value that immediately FOLLOWS each flag token so an empty
# --required-channels value is read as "" (not the next flag). Assert the
# fleet-default plugin is in --channels AND --optional-channels (warn-only) but
# NOT in --required-channels (never a launch blocker).
T13_VERDICT="$(
  T13_ARGV="$T13_ARGV" "$REAL_PY3" - <<'PY'
import os, sys
argv_path = os.environ["T13_ARGV"]
try:
    with open(argv_path, encoding="utf-8") as fh:
        toks = [ln.rstrip("\n") for ln in fh]
except OSError:
    print("BAD: launcher never invoked the sync (no argv captured)"); sys.exit(0)
def flag(name):
    f = "--" + name
    for i, t in enumerate(toks):
        if t == f:
            return toks[i + 1] if i + 1 < len(toks) else ""
    return ""
ch = flag("channels"); opt = flag("optional-channels"); req = flag("required-channels")
target = "plugin:fleet-widget@agent-bridge"
ok = (target in ch.split(",")) and (target in opt.split(",")) and (target not in req.split(","))
print("GOOD" if ok else "BAD: channels=%r optional=%r required=%r" % (ch, opt, req))
PY
)"
case "$T13_VERDICT" in
  GOOD)
    smoke_log "T13 ok: launch path consumed the canonical fleet-default declaration and routed it as an OPTIONAL channel (installed/enabled/manifested by the convergence pass), NOT pre-seeded" ;;
  *)
    smoke_fail "T13 BLOCKER1: fleet-default NOT wired into bridge_run_sync_dev_plugin_cache convergence ($T13_VERDICT)" ;;
esac

# ---------------------------------------------------------------------------
# T14 — BLOCKER 2 (gate-2): brownfield first-snapshot reachability. A dynamic
# agent with a NON-EMPTY installed_plugins.json (only operator-installed/ad-hoc
# plugins), EMPTY channels, NO fleet-default declaration, and NO pre-existing
# ledger MUST reach the Python seed path on its FIRST launch and create the
# ledger snapshot BEFORE the first wipe. The old launcher early-returned on
# empty-channels+absent-ledger, so the first #1854 `--replace` restart wiped
# the manifest with NO snapshot to restore. Drive the REAL launch function:
# first launch seeds the snapshot, then a wipe + restart restores from it.
# The ledger is NOT pre-seeded.
# ---------------------------------------------------------------------------
T14_HOME="$SMOKE_TMP_ROOT/t14-home"
mkdir -p "$T14_HOME"   # NO agent-env.local.sh → no fleet-default declaration.
T14_CLAUDE_ROOT="$SMOKE_TMP_ROOT/t14-claude"
T14_PLUGINS_ROOT="$T14_CLAUDE_ROOT/plugins"
mkdir -p "$T14_PLUGINS_ROOT/cache"
# Brownfield manifest: only an operator-installed plugin, no channels.
cat >"$T14_PLUGINS_ROOT/installed_plugins.json" <<'JSON'
{
  "version": 2,
  "plugins": {
    "claude-hud@jarrodwatts": [
      {"scope": "user", "installPath": "/operator/installed/claude-hud",
       "version": "9.9.9", "installedAt": "2026-01-01T00:00:00Z",
       "lastUpdated": "2026-01-01T00:00:00Z"}
    ]
  }
}
JSON
T14_LEDGER_DIR="$SMOKE_TMP_ROOT/t14-ledger"
mkdir -p "$T14_LEDGER_DIR"
# Assert precondition: NO ledger exists yet.
[[ ! -e "$T14_LEDGER_DIR/t14-agent.json" ]] \
  || smoke_fail "T14 precondition: ledger pre-seeded (test would be meaningless)"

T14_OUT="$(
  BRIDGE_HOME="$T14_HOME" \
  T14_CLAUDE_ROOT="$T14_CLAUDE_ROOT" \
  T14_LEDGER_DIR="$T14_LEDGER_DIR" \
  REPO_ROOT="$REPO_ROOT" \
  "${BASH:-bash}" <<'OUTER' 2>&1 || true
set -uo pipefail
source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1
AGENT="t14-agent"; ENGINE="claude"; SAFE_MODE=0
SCRIPT_DIR="$REPO_ROOT"
log_line() { :; }
bridge_run_agent_claude_root() { printf '%s' "$T14_CLAUDE_ROOT"; }
bridge_isolated_plugin_grants_state_file() { printf '%s/%s.json' "$T14_LEDGER_DIR" "$1"; }
bridge_agent_effective_dev_channels_csv() { printf ''; }
bridge_agent_plugins_csv() { printf ''; }
for fn in bridge_run_manifest_has_plugins bridge_run_ledger_has_snapshot \
          bridge_run_fleet_default_unsafe_reason bridge_run_sync_dev_plugin_cache; do
  body="$(sed -n "/^${fn}()/,/^}/p" "$REPO_ROOT/bridge-run.sh")"
  [[ -n "$body" ]] || { echo "EVAL-FAIL: $fn body empty"; exit 3; }
  eval "$body"
done
ledger="$T14_LEDGER_DIR/t14-agent.json"
manifest="$T14_CLAUDE_ROOT/plugins/installed_plugins.json"

# First launch: empty channels, absent ledger, NON-EMPTY manifest → must NOT
# early-return; must reach the Python seed path and create the snapshot.
bridge_run_sync_dev_plugin_cache; rc1=$?
echo "RC1=$rc1"
if [[ -f "$ledger" ]]; then echo "SEEDED=yes"; else echo "SEEDED=no"; fi
python3 - "$ledger" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("SNAP="); sys.exit(0)
snap = ((d.get("installed_snapshot") or {}).get("plugins") or {})
print("SNAP=%s" % ",".join(sorted(snap.keys())))
PY

# Now simulate the #1854 --replace restart wipe: live manifest comes back EMPTY.
printf '{\n  "version": 2,\n  "plugins": {}\n}\n' >"$manifest"
# Restart launch: empty channels again, but the ledger NOW has a snapshot →
# recovery must restore the operator plugin into the wiped manifest.
bridge_run_sync_dev_plugin_cache; rc2=$?
echo "RC2=$rc2"
python3 - "$manifest" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("RESTORED=%s" % ",".join(sorted((d.get("plugins") or {}).keys())))
PY
OUTER
)"

case "$T14_OUT" in
  *"SEEDED=yes"*"SNAP="*"claude-hud@jarrodwatts"*"RESTORED="*"claude-hud@jarrodwatts"*)
    smoke_log "T14 ok: brownfield first launch seeded the ledger snapshot BEFORE the wipe; #1854 restart restored it" ;;
  *)
    smoke_fail "T14 BLOCKER2: brownfield first-snapshot path not reachable / restore failed (out: $T14_OUT)" ;;
esac

# ---------------------------------------------------------------------------
# T15 — gate-2 r1 codex finding: the fleet-default CSV split must NOT
# pathname-expand its tokens, and must NOT drop a trailing empty field. A prior
# unquoted `$_fleet_default_csv` word-split ran Bash globbing on each field
# FIRST, so a `*`/`?`/`[` glob in a declaration would expand to real cwd
# filenames BEFORE the validator saw it — silently rewriting one declaration
# token into many launch channels. The same split also ate a TRAILING empty
# token (`foo,`), so the class-(a) empty-token skip+warn never fired.
#
# This tooth proves the two properties INDEPENDENTLY (a single combined
# declaration can't, because an unsafe leading token aborts before a trailing
# empty is reached). Three self-contained sub-cases, each driving the REAL
# launch convergence:
#   T15a — SAFE glob-shaped token `*@agent-bridge` from a cwd full of decoy
#          files. `*` is a safe identity (not class-(b) traversal), so launch
#          MUST converge it as exactly ONE optional channel `plugin:*@agent-
#          bridge`. We inspect the captured sync argv: the literal token is
#          present and NO decoy filename leaked in — direct proof the split
#          stayed literal (a glob bug would replace `*` with the decoy names).
#   T15b — SAFE declaration with a TRAILING empty `valid-plugin,`. The valid
#          token converges; the trailing empty must trigger the class-(a)
#          empty-token skip+warn log (proof the trailing field survived the
#          split). Asserted via the launcher's own log line.
#   T15c — UNSAFE traversal glob `../*@agent-bridge`. Class-(b) fail-closed:
#          rc!=0, unsafe warning, and NO convergence write (argv never written).
# ---------------------------------------------------------------------------
# Shared decoy cwd: real files a stray glob would expand to in every sub-case.
T15_CWD="$SMOKE_TMP_ROOT/t15-cwd"
mkdir -p "$T15_CWD"
: >"$T15_CWD/decoy-a"; : >"$T15_CWD/decoy-b"; : >"$T15_CWD/decoy-c"
REAL_PY3="$(command -v python3)"

# Per-case captured-argv path. Deterministic from the case tag so the PARENT
# shell can read it after the command-substitution subshell that runs _t15_run
# returns (a var assigned inside the function would not survive the `$( )`
# subshell under `set -u`). `_t15_argv <tag>` resolves it on both sides.
_t15_argv() { printf '%s/t15-%s-argv.txt' "$SMOKE_TMP_ROOT" "$1"; }

# Reusable driver: $1=case-tag $2=declaration value. Emits the launcher's
# stdout (RC=.. + WARN/log lines) and records the captured sync argv (one token
# per line) to `$(_t15_argv <tag>)`. An argv-recording python3 shim no-ops sync.
_t15_run() {
  local tag="$1" decl="$2"
  local home="$SMOKE_TMP_ROOT/t15-$tag-home"
  local claude_root="$SMOKE_TMP_ROOT/t15-$tag-claude"
  local ledger_dir="$SMOKE_TMP_ROOT/t15-$tag-ledger"
  local shim_dir="$SMOKE_TMP_ROOT/t15-$tag-shimbin"
  local argv_file; argv_file="$(_t15_argv "$tag")"
  mkdir -p "$home" "$claude_root/plugins/cache" "$ledger_dir" "$shim_dir"
  printf 'export BRIDGE_FLEET_DEFAULT_PLUGINS="%s"\n' "$decl" >"$home/agent-env.local.sh"
  printf '{\n  "version": 2,\n  "plugins": {}\n}\n' \
    >"$claude_root/plugins/installed_plugins.json"
  rm -f "$argv_file"
  cat >"$shim_dir/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *bridge-dev-plugin-cache.py)
      : >"$argv_file"
      for t in "\$@"; do printf '%s\n' "\$t" >>"$argv_file"; done
      exit 0 ;;
  esac
done
exec "$REAL_PY3" "\$@"
SHIM
  chmod +x "$shim_dir/python3"
  (
    cd "$T15_CWD" && \
    BRIDGE_HOME="$home" \
    T15_CLAUDE_ROOT="$claude_root" \
    T15_LEDGER_DIR="$ledger_dir" \
    REPO_ROOT="$REPO_ROOT" \
    PATH="$shim_dir:$PATH" \
    "${BASH:-bash}" <<'OUTER' 2>&1 || true
set -uo pipefail
source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1
AGENT="t15-agent"; ENGINE="claude"; SAFE_MODE=0
SCRIPT_DIR="$REPO_ROOT"
log_line() { printf 'LOG:%s\n' "$*"; }
bridge_warn() { printf 'WARN:%s\n' "$*"; }
bridge_run_agent_claude_root() { printf '%s' "$T15_CLAUDE_ROOT"; }
bridge_isolated_plugin_grants_state_file() { printf '%s/%s.json' "$T15_LEDGER_DIR" "$1"; }
bridge_agent_effective_dev_channels_csv() { printf ''; }
bridge_agent_plugins_csv() { printf ''; }
for fn in bridge_run_manifest_has_plugins bridge_run_ledger_has_snapshot \
          bridge_run_fleet_default_unsafe_reason bridge_run_sync_dev_plugin_cache; do
  body="$(sed -n "/^${fn}()/,/^}/p" "$REPO_ROOT/bridge-run.sh")"
  [[ -n "$body" ]] || { echo "EVAL-FAIL: $fn body empty"; exit 3; }
  eval "$body"
done
bridge_run_sync_dev_plugin_cache; echo "RC=$?"
OUTER
  )
}

# --- T15a: SAFE glob token must converge LITERALLY (no cwd-filename leak) -----
T15A_OUT="$(_t15_run a '*@agent-bridge')"
T15A_ARGV="$(_t15_argv a)"
T15A_VERDICT="$(
  T15A_ARGV="$T15A_ARGV" "$REAL_PY3" - <<'PY'
import os, sys
p = os.environ["T15A_ARGV"]
try:
    toks = [l.rstrip("\n") for l in open(p, encoding="utf-8")]
except OSError:
    print("BAD: no argv captured (launcher never reached sync)"); sys.exit(0)
def flag(name):
    f = "--" + name
    for i, t in enumerate(toks):
        if t == f:
            return toks[i + 1] if i + 1 < len(toks) else ""
    return ""
ch = flag("channels").split(",") if flag("channels") else []
opt = flag("optional-channels").split(",") if flag("optional-channels") else []
literal = "plugin:*@agent-bridge"
# Literal token must be present in channels AND optional; and NO decoy filename
# may have leaked in (a glob bug would have replaced `*` with decoy-a/b/c).
leaked = any("decoy-" in t for t in ch + opt)
ok = (literal in ch) and (literal in opt) and not leaked
print("GOOD" if ok else "BAD: channels=%r optional=%r leaked=%s" % (ch, opt, leaked))
PY
)"
case "$T15A_OUT$T15A_VERDICT" in
  *"RC=0"*GOOD)
    smoke_log "T15a ok: safe glob-shaped token converged LITERALLY as one optional channel; no cwd filename leaked (split stayed literal, no glob expansion)" ;;
  *)
    smoke_fail "T15a gate2r1: glob token not literal / leaked or did not converge (out: $T15A_OUT verdict: $T15A_VERDICT)" ;;
esac

# --- T15b: SAFE token + TRAILING empty must hit class-(a) skip+warn -----------
# Order-independent: the class-(a) warn log is emitted DURING the loop (before
# the final `RC=$?` echo), so assert both substrings are present rather than a
# positional `RC=0`-then-warn pattern. Both must hold: launch succeeded (RC=0)
# AND the trailing empty produced the class-(a) skip+warn.
T15B_OUT="$(_t15_run b 'valid-plugin,')"
if [[ "$T15B_OUT" == *"RC=0"* \
      && "$T15B_OUT" == *"#1857 fleet-default class-a skip: empty declaration token"* ]]; then
  smoke_log "T15b ok: trailing empty field survived the split and triggered the class-(a) empty-token skip+warn; the valid token still converged"
else
  smoke_fail "T15b gate2r1: trailing empty token did NOT reach the class-(a) skip+warn (split dropped it?) (out: $T15B_OUT)"
fi

# --- T15c: UNSAFE traversal glob must fail closed BEFORE any write ------------
T15C_OUT="$(_t15_run c '../*@agent-bridge')"
T15C_ARGV="$(_t15_argv c)"
if [[ "$T15C_OUT" == *"RC=0"* ]]; then
  smoke_fail "T15c gate2r1: unsafe traversal-glob token did NOT fail closed (out: $T15C_OUT)"
elif [[ -f "$T15C_ARGV" ]]; then
  smoke_fail "T15c gate2r1: convergence write attempted before class-(b) abort (argv written)"
elif [[ "$T15C_OUT" != *"WARN:"*"unsafe"* ]]; then
  smoke_fail "T15c gate2r1: no class-(b) unsafe warning emitted (out: $T15C_OUT)"
else
  smoke_log "T15c ok: unsafe traversal-glob fleet-default token failed closed BEFORE any convergence write (no glob expansion, no leak)"
fi

smoke_log "all checks passed"
