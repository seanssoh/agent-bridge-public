#!/usr/bin/env bash
# scripts/smoke/v2-cross-class-read.sh — Issue #583 closure smoke (v0.8.0 T4).
#
# Verifies that the v2 isolation layout (POSIX group `ab-agent-<n>` +
# setgid 2770 per-agent home, owned by the per-agent UID) lets a
# controller-UID reader access an isolated agent's `memory/projects/`,
# `memory/shared/`, and `memory/decisions/` paths via group permission
# alone — closing #583's "librarian cannot read linux-user-isolated
# agent's memory/projects/" loop.
#
# Why this matters in v0.8.0:
#   v1 isolation used 0700 owner-only modes plus optional named-user
#   ACLs, so a system-class agent (e.g. `librarian`) running as the
#   controller UID could not open files inside an isolated agent's
#   home unless an ACL grant was applied. v2's group + setgid model
#   (lib/bridge-isolation-v2.sh) gives every member of `ab-agent-<n>`
#   read access to the entire per-agent tree by default, and the v2
#   migration (T3) adds the controller UID to every such group. This
#   smoke is the proof that the new layout closes #583 with no ACL
#   dependency.
#
# What this smoke covers
#   1. POSITIVE — controller UID reads isolated-derm's memory fixtures
#      (projects/shared/decisions paths) via group membership alone.
#   2. NEGATIVE — an unrelated UID (NOT in `ab-agent-isolated-derm`)
#      is denied.
#   3. NO-ACL — the path carries POSIX-only permissions; no extended
#      ACL entries (POSIX `user:` rows) are present. Verifies the
#      reads do not depend on the v1 ACL fallback.
#
# What it does NOT cover (out of scope per brief)
#   * Shared aggregate paths (shared/wiki/*, shared/memory-daily/...)
#     — covered by `system-agent-class.sh`.
#   * Live `agent-bridge isolate <agent>` provisioning.
#   * Live tool-policy.py interaction (covered by
#     `system-agent-class.sh`).
#
# Gate (Phase 0)
#   Linux + passwordless `sudo` only. macOS skips with a clear message
#   so the smoke runner reports a single skip line instead of a
#   spurious failure.
#
# Cleanup discipline
#   * Trap removes the transient group via `sudo groupdel` (this also
#     detaches any temporary membership added via `usermod -aG`).
#   * Trap removes TMPHOME via `sudo rm -rf` because fixtures created
#     by the isolated UID are not removable by the controller without
#     sudo.

set -euo pipefail

SMOKE_NAME="v2-cross-class-read"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Accumulators populated as the smoke acquires resources, drained by
# the cleanup trap on every exit path.
SMOKE_GROUP_NAME=""
SMOKE_TMPHOME=""
SMOKE_USERMODE_USERS=()

cleanup() {
  # Best-effort: drop the group first (this implicitly removes any
  # supplementary membership rows we created via `usermod -aG`), then
  # remove the temp tree as root because fixtures owned by the
  # isolated UID are not unlinkable by the controller.
  local user
  if [[ -n "$SMOKE_GROUP_NAME" ]] && command -v getent >/dev/null 2>&1; then
    if getent group "$SMOKE_GROUP_NAME" >/dev/null 2>&1; then
      sudo -n groupdel "$SMOKE_GROUP_NAME" >/dev/null 2>&1 || true
    fi
  fi
  # `groupdel` already detaches membership rows on Linux, but be
  # defensive: walk the recorded user list and run `gpasswd -d` to
  # cover the rare case where groupdel fails (e.g. group is a primary
  # group somewhere it shouldn't be).
  if [[ -n "$SMOKE_GROUP_NAME" ]] && (( ${#SMOKE_USERMODE_USERS[@]} > 0 )); then
    for user in "${SMOKE_USERMODE_USERS[@]}"; do
      [[ -n "$user" ]] || continue
      sudo -n gpasswd -d "$user" "$SMOKE_GROUP_NAME" >/dev/null 2>&1 || true
    done
  fi
  if [[ -n "$SMOKE_TMPHOME" && -d "$SMOKE_TMPHOME" ]]; then
    sudo -n rm -rf "$SMOKE_TMPHOME" >/dev/null 2>&1 || \
      rm -rf "$SMOKE_TMPHOME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Phase 0 — gate
# ---------------------------------------------------------------------------

if [[ "$(uname -s 2>/dev/null || printf 'unknown')" != "Linux" ]]; then
  smoke_log "skip: requires Linux (POSIX group + setgid model is kernel-specific)"
  exit 0
fi

if ! command -v sudo >/dev/null 2>&1; then
  smoke_log "skip: requires sudo (cannot exercise multi-UID read boundary)"
  exit 0
fi

if ! sudo -n true 2>/dev/null; then
  smoke_log "skip: requires passwordless sudo (cannot mutate group membership non-interactively)"
  exit 0
fi

for cmd in getent groupadd groupdel usermod gpasswd id sg getfacl stat; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    smoke_log "skip: missing required command '$cmd' (Linux util-linux + acl pkgs expected)"
    exit 0
  fi
done

# Pick an unrelated non-root UID that is NOT the runner. `nobody` and
# `daemon` are the conventional unprivileged accounts on every Linux
# distro shipped in the last 20 years; either is fine. We need
# passwordless `sudo -u <user>` to run reads as that UID. Skip cleanly
# if no candidate is available.
controller_user="$(id -un)"
controller_uid="$(id -u)"
if [[ "$controller_uid" -eq 0 ]]; then
  # Running as root would bypass POSIX group-permission checks (root
  # reads everything regardless of mode), making the negative case
  # vacuous. The smoke must run as a non-root user.
  smoke_log "skip: refusing to run as root (would bypass POSIX permission checks and make negative case vacuous)"
  exit 0
fi

unrelated_user=""
for candidate in "${BRIDGE_V2_CROSS_CLASS_UNRELATED:-}" nobody daemon bin _unknown; do
  [[ -n "$candidate" ]] || continue
  [[ "$candidate" == "$controller_user" ]] && continue
  id -u "$candidate" >/dev/null 2>&1 || continue
  if sudo -n -u "$candidate" /bin/true >/dev/null 2>&1; then
    unrelated_user="$candidate"
    break
  fi
done
if [[ -z "$unrelated_user" ]]; then
  smoke_log "skip: cannot find an unrelated non-root UID reachable via passwordless sudo (set BRIDGE_V2_CROSS_CLASS_UNRELATED, or ensure one of nobody/daemon/bin/_unknown is sudoable)"
  exit 0
fi

# The "isolated agent UID" stand-in. We use `nobody` (or whichever
# unrelated UID we picked) here too if no separate isolated candidate
# is available — but we MUST have a distinct UID for the isolated
# fixture owner versus the unrelated denied reader. If only one
# candidate exists, we cannot exercise both roles without bypassing
# the kernel boundary; skip cleanly.
isolated_user=""
for candidate in "${BRIDGE_V2_CROSS_CLASS_ISOLATED:-}" daemon nobody bin _unknown nfsnobody mail; do
  [[ -n "$candidate" ]] || continue
  [[ "$candidate" == "$controller_user" ]] && continue
  [[ "$candidate" == "$unrelated_user" ]] && continue
  id -u "$candidate" >/dev/null 2>&1 || continue
  if sudo -n -u "$candidate" /bin/true >/dev/null 2>&1; then
    isolated_user="$candidate"
    break
  fi
done
if [[ -z "$isolated_user" ]]; then
  smoke_log "skip: need two distinct non-root UIDs (one isolated stand-in, one unrelated) reachable via passwordless sudo (set BRIDGE_V2_CROSS_CLASS_ISOLATED + BRIDGE_V2_CROSS_CLASS_UNRELATED)"
  exit 0
fi

smoke_log "Linux + passwordless sudo gate satisfied"
smoke_log "controller=$controller_user (uid=$controller_uid) isolated=$isolated_user unrelated=$unrelated_user"

# ---------------------------------------------------------------------------
# Phase 1 — setup TMPHOME and a transient `ab-agent-<n>` group
# ---------------------------------------------------------------------------

# Build a unique, well-formed Linux group name. v2 uses
# `${BRIDGE_AGENT_GROUP_PREFIX:-ab-agent-}<agent>`; we mirror that
# pattern so the resulting group looks identical to a real one. The
# random suffix prevents collision with parallel CI runs and any
# real `ab-agent-*` group that might exist on the host.
random_suffix="$(printf '%04x' "$RANDOM")$(printf '%04x' "$$")"
SMOKE_GROUP_NAME="ab-agent-smoke-${random_suffix:0:8}"
agent_name="smoke-${random_suffix:0:8}"

# Linux group name limit is 32 characters; verify the composed name fits.
if (( ${#SMOKE_GROUP_NAME} > 32 )); then
  smoke_fail "computed group name '$SMOKE_GROUP_NAME' exceeds 32-char limit"
fi

SMOKE_TMPHOME="$(mktemp -d "${TMPDIR:-/tmp}/v2-cross-class-read.XXXXXX")"
SMOKE_TMPHOME="$(cd -P "$SMOKE_TMPHOME" && pwd -P)"

smoke_log "phase 1: TMPHOME=$SMOKE_TMPHOME group=$SMOKE_GROUP_NAME"

# Create the transient group. Use `groupadd -r` (system group) to
# match the convention v2 install scripts use.
sudo -n groupadd -r "$SMOKE_GROUP_NAME" \
  || smoke_fail "phase 1: groupadd $SMOKE_GROUP_NAME failed"

# Add the controller UID to the group. The on-disk membership row is
# what `chgrp` validates against, not the runtime supplementary group
# list of the current shell — so this works without re-login. We
# spawn the read assertions via `sg "$SMOKE_GROUP_NAME" -c '...'`
# (which loads a fresh shell with the new group active) to avoid
# depending on the current shell's already-cached `id -G`.
sudo -n usermod -aG "$SMOKE_GROUP_NAME" "$controller_user" \
  || smoke_fail "phase 1: usermod -aG $SMOKE_GROUP_NAME $controller_user failed"
SMOKE_USERMODE_USERS+=("$controller_user")

# The isolated UID is also a member of its own ab-agent group in v2.
sudo -n usermod -aG "$SMOKE_GROUP_NAME" "$isolated_user" \
  || smoke_fail "phase 1: usermod -aG $SMOKE_GROUP_NAME $isolated_user failed"
SMOKE_USERMODE_USERS+=("$isolated_user")

# The unrelated UID is deliberately NOT added to the group. This is
# the boundary the negative case asserts.

# ---------------------------------------------------------------------------
# Phase 2 — build the v2 per-agent home (mode 2770, group=ab-agent-<n>)
# ---------------------------------------------------------------------------

# Mirror the v2 layout from lib/bridge-isolation-v2.sh:
#   $TMPHOME/agents/<agent>/                       2750 root:ab-agent-<n>
#     home/                                        2770 isolated:ab-agent-<n>
#       memory/projects/, memory/shared/, memory/decisions/
agents_root="$SMOKE_TMPHOME/agents"
agent_root="$agents_root/$agent_name"
agent_home="$agent_root/home"

# `mktemp -d` returns a 0700-mode dir owned by the runner. Open the
# parent prefix to 0755 (others traverse) so the unrelated UID can
# reach the fixture path; v2 layout has $BRIDGE_DATA_ROOT as 0755 for
# this reason.
chmod 0755 "$SMOKE_TMPHOME"
sudo -n install -d -m 0755 -o root -g root "$agents_root" \
  || smoke_fail "phase 2: failed to create $agents_root as root"

# Per-agent root: 2750 root:ab-agent-<n>. Group members can traverse;
# isolated UID owns home/ underneath but cannot mv/rm the per-agent
# root itself.
sudo -n install -d -m 2750 -o root -g "$SMOKE_GROUP_NAME" "$agent_root" \
  || smoke_fail "phase 2: failed to create $agent_root with group $SMOKE_GROUP_NAME"

# Per-agent home: 2770 isolated:ab-agent-<n>. Setgid bit ensures
# every file/dir created inside inherits group=ab-agent-<n>, which is
# what makes the controller's group-based read work transparently.
sudo -n install -d -m 2770 -o "$isolated_user" -g "$SMOKE_GROUP_NAME" "$agent_home" \
  || smoke_fail "phase 2: failed to create $agent_home owned by $isolated_user"

# Verify mode/owner/group landed exactly as expected. `stat -c` is
# GNU coreutils; we already gated on Linux.
agent_home_mode="$(stat -c '%a' "$agent_home")"
agent_home_owner="$(stat -c '%U' "$agent_home")"
agent_home_group="$(stat -c '%G' "$agent_home")"
smoke_assert_eq "2770" "$agent_home_mode" "agent home mode"
smoke_assert_eq "$isolated_user" "$agent_home_owner" "agent home owner"
smoke_assert_eq "$SMOKE_GROUP_NAME" "$agent_home_group" "agent home group"

# ---------------------------------------------------------------------------
# Phase 3 — write fixture files as the isolated UID
# ---------------------------------------------------------------------------

# Create projects/, shared/, decisions/ under memory/ — exactly the
# subpath set #583 lists. Each gets one fixture file with a sentinel
# string the positive-case `cat` must observe.
for subdir in memory/projects memory/shared memory/decisions; do
  sudo -n -u "$isolated_user" /bin/sh -c \
    "umask 007 && mkdir -p '$agent_home/$subdir'" \
    || smoke_fail "phase 3: isolated UID could not create $subdir"
done

declare -a fixture_paths=(
  "$agent_home/memory/projects/foo.md"
  "$agent_home/memory/shared/bar.md"
  "$agent_home/memory/decisions/baz.md"
)
sentinel="cross-class-read-OK-${random_suffix:0:6}"
for path in "${fixture_paths[@]}"; do
  sudo -n -u "$isolated_user" /bin/sh -c \
    "umask 007 && printf '%s\n' '$sentinel' >'$path'" \
    || smoke_fail "phase 3: isolated UID could not write $path"
done

# Verify the setgid bit on the parent dir caused fixture group
# inheritance. If this fails, the v2 model itself is broken on this
# host and the rest of the smoke is meaningless.
for path in "${fixture_paths[@]}"; do
  fixture_group="$(stat -c '%G' "$path")"
  smoke_assert_eq "$SMOKE_GROUP_NAME" "$fixture_group" \
    "fixture group inheritance via setgid bit ($path)"
done

# ---------------------------------------------------------------------------
# Phase 4 — POSITIVE: controller (member of ab-agent-<n>) can read
# ---------------------------------------------------------------------------

# Spawn the read via `sg "$SMOKE_GROUP_NAME" -c '<cmd>'`: this loads a
# fresh shell as the current user with the named group's privileges
# active, picking up the `usermod -aG` row we wrote. The current shell
# would not see the new group otherwise (the kernel caches
# supplementary groups at exec time).
for path in "${fixture_paths[@]}"; do
  out=""
  out="$(sg "$SMOKE_GROUP_NAME" -c "cat '$path' 2>&1")" || \
    smoke_fail "phase 4 (positive): controller=$controller_user via sg $SMOKE_GROUP_NAME could not read $path: $out"
  smoke_assert_contains "$out" "$sentinel" \
    "phase 4 (positive): controller read of $path returns sentinel"
done

smoke_log "phase 4: controller UID reads memory/{projects,shared,decisions} via group permission (3/3)"

# ---------------------------------------------------------------------------
# Phase 5 — NEGATIVE: unrelated UID (NOT in group) is denied
# ---------------------------------------------------------------------------

for path in "${fixture_paths[@]}"; do
  if sudo -n -u "$unrelated_user" /bin/sh -c "cat '$path' >/dev/null 2>&1"; then
    smoke_fail "phase 5 (negative): unrelated UID=$unrelated_user CAN read $path (should be denied — not in $SMOKE_GROUP_NAME)"
  fi
done

smoke_log "phase 5: unrelated UID denied at all 3 fixture paths"

# ---------------------------------------------------------------------------
# Phase 6 — NO-ACL: confirm POSIX-only, no extended ACL fallback
# ---------------------------------------------------------------------------

# `getfacl --skip-base` prints only extended (named-user / named-group
# / mask) entries. v2's contract is that group permission alone — not
# any ACL — grants the controller access. If named-user rows appear
# here, the smoke is silently passing via the v1 ACL fallback and the
# v2 group model has not actually been validated.
for path in "$agent_home" "${fixture_paths[@]}"; do
  acl_out="$(getfacl --skip-base --absolute-names "$path" 2>/dev/null || true)"
  # `--skip-base` suppresses the base owner/group/other rows. What
  # remains is comments (lines starting with #) and blank lines; any
  # `user:` or `group:<name>:` row is an extended entry.
  extended_rows="$(printf '%s\n' "$acl_out" | grep -E '^(user|group|mask|default):[^:]+:' || true)"
  if [[ -n "$extended_rows" ]]; then
    smoke_fail "phase 6 (no-ACL): $path has extended ACL entries (v2 contract is POSIX-only):
$extended_rows"
  fi
done

smoke_log "phase 6: no extended ACLs on agent home or any of the 3 fixture paths"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

smoke_log "PASS — controller reads via group; unrelated UID denied; no ACL dependency"
