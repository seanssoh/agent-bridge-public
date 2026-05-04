#!/usr/bin/env bash
# scripts/smoke/isolated-skills-sync.sh — Issue #544 PR3 smoke.
#
# Validates `bridge_sync_isolated_home_claude_skills` against a fixture
# bridge home and a stand-in isolated UID home. Three groups of assertions:
#
# 1. All four bridge-native skills (agent-bridge-runtime, cron-manager,
#    memory-wiki, patch-permission-approval) land in the isolated home's
#    .claude/skills/<skill>/SKILL.md.
# 2. Path text in rendered SKILL.md is normalized: every occurrence of
#    `~/.agent-bridge/` becomes the absolute BRIDGE_HOME path, so the
#    skill body's `agb` / `agent-bridge` commands resolve under the
#    isolated UID without depending on `~` semantics or per-home symlinks.
# 3. Subdirectory structure (e.g. references/) is preserved when the
#    source skill carries one.
#
# Coverage: helper logic only. Does NOT exercise:
#   - real Linux sudo (we stub bridge_linux_sudo_root to drop sudo since
#     the fixture isolated home is owned by the test user under TMPDIR);
#   - real `agent-bridge isolate <agent> --reapply` against a live UID;
#   - the wire-in via bridge_bootstrap_claude_shared_skills (covered by
#     existing isolation smoke).
# End-to-end coverage is operator-side per OPERATIONS.md (`agent-bridge
# isolate <agent> --reapply` + agent restart).

set -euo pipefail

SMOKE_NAME="isolated-skills-sync"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

SKILL_NAMES=(agent-bridge-runtime cron-manager memory-wiki patch-permission-approval)

build_fixture() {
  smoke_make_temp_root "$SMOKE_NAME"

  FIXTURE_BRIDGE_HOME="$SMOKE_TMP_ROOT/bridge-home"
  FIXTURE_ISOLATED_HOME_ROOT="$SMOKE_TMP_ROOT/home"
  FIXTURE_OS_USER="agent-bridge-smoke"
  FIXTURE_ISOLATED_HOME="$FIXTURE_ISOLATED_HOME_ROOT/$FIXTURE_OS_USER"
  FIXTURE_AGENT="smoke"

  mkdir -p \
    "$FIXTURE_BRIDGE_HOME/.claude/skills" \
    "$FIXTURE_ISOLATED_HOME"

  # Seed each shared skill with a minimal SKILL.md whose body contains
  # the `~/.agent-bridge/` literal that the renderer must rewrite. The
  # extra plain-text line ensures rewrite happens both inline and in
  # fenced code blocks. patch-permission-approval also gets a
  # references/ subdir so the smoke verifies subdir preservation.
  local skill
  for skill in "${SKILL_NAMES[@]}"; do
    mkdir -p "$FIXTURE_BRIDGE_HOME/.claude/skills/$skill"
    cat >"$FIXTURE_BRIDGE_HOME/.claude/skills/$skill/SKILL.md" <<EOF
---
name: $skill
description: Smoke fixture for $skill — exercises path rewrite.
---

# $skill

Run \`~/.agent-bridge/agb inbox \$BRIDGE_AGENT_ID\` to drain the queue.

\`\`\`bash
~/.agent-bridge/agent-bridge memory query --agent "\$BRIDGE_AGENT_ID"
\`\`\`
EOF
  done

  # Subdirectory in patch-permission-approval — verify the renderer
  # walks the tree and preserves structure.
  mkdir -p "$FIXTURE_BRIDGE_HOME/.claude/skills/patch-permission-approval/references"
  cat >"$FIXTURE_BRIDGE_HOME/.claude/skills/patch-permission-approval/references/notes.md" <<'EOF'
# Reference notes

See `~/.agent-bridge/agb show <id>` for task detail.
EOF
}

invoke_sync() {
  # Run the helper inside a fresh bash that sources bridge-lib.sh, with
  # BRIDGE_HOST_PLATFORM_OVERRIDE=Linux so the predicate succeeds on
  # macOS dev hosts, and BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT pointed at
  # the fixture so the helper writes into TMPDIR. We override
  # bridge_linux_sudo_root to drop the sudo wrap (the fixture isolated
  # home is already owned by the test user) — the helper's behavior is
  # otherwise identical.
  local repo_root="$SMOKE_REPO_ROOT"
  local bash_bin="${BRIDGE_BASH_BIN:-bash}"

  BRIDGE_HOME="$FIXTURE_BRIDGE_HOME" \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$FIXTURE_ISOLATED_HOME_ROOT" \
  "$bash_bin" -c "
    set -uo pipefail
    source '$repo_root/bridge-lib.sh'

    # Initialize empty roster maps without loading on-disk rosters.
    # bridge_reset_roster_maps declares every BRIDGE_AGENT_* assoc
    # array, which lets us inject the fixture agent's metadata directly.
    bridge_reset_roster_maps

    # Inject the fixture agent. Keys are unquoted on purpose: bash
    # under \`set -u\` evaluates quoted single-token keys as variable
    # references inside an assoc-array index.
    BRIDGE_AGENT_IDS+=($FIXTURE_AGENT)
    BRIDGE_AGENT_ENGINE[$FIXTURE_AGENT]=claude
    BRIDGE_AGENT_ISOLATION_MODE[$FIXTURE_AGENT]=linux-user
    BRIDGE_AGENT_OS_USER[$FIXTURE_AGENT]=$FIXTURE_OS_USER

    # Drop sudo: the fixture isolated home is owned by the controlling
    # test user under TMPDIR, so sudo is unnecessary and unavailable in
    # CI. The helper calls this primitive uniformly for every mutation.
    bridge_linux_sudo_root() {
      \"\$@\"
    }

    bridge_sync_isolated_home_claude_skills '$FIXTURE_AGENT'
  "
}

assert_all_skills_present() {
  local skill
  for skill in "${SKILL_NAMES[@]}"; do
    smoke_assert_file_exists \
      "$FIXTURE_ISOLATED_HOME/.claude/skills/$skill/SKILL.md" \
      "skill '$skill' rendered into isolated home"
  done
}

assert_path_normalization() {
  local skill
  local target
  for skill in "${SKILL_NAMES[@]}"; do
    target="$FIXTURE_ISOLATED_HOME/.claude/skills/$skill/SKILL.md"
    # Every `~/.agent-bridge/` literal in the source must be gone. The
    # tilde here is intentional — we are searching for the literal text
    # the renderer is supposed to have rewritten away, not a path.
    # shellcheck disable=SC2088
    if grep -F '~/.agent-bridge/' "$target" >/dev/null 2>&1; then
      smoke_fail "skill '$skill' still contains '~/.agent-bridge/' after rewrite (target=$target)"
    fi
    # Absolute BRIDGE_HOME path must be present in its place. The
    # fixture body inserts both `agb` and `agent-bridge memory` calls,
    # so the rewrite must produce the absolute form for both.
    smoke_assert_contains \
      "$(cat "$target")" \
      "$FIXTURE_BRIDGE_HOME/agb inbox" \
      "skill '$skill' rewrites '~/.agent-bridge/agb' to absolute BRIDGE_HOME"
    smoke_assert_contains \
      "$(cat "$target")" \
      "$FIXTURE_BRIDGE_HOME/agent-bridge memory" \
      "skill '$skill' rewrites '~/.agent-bridge/agent-bridge' to absolute BRIDGE_HOME"
  done
}

assert_subdir_preserved() {
  local subdir_target="$FIXTURE_ISOLATED_HOME/.claude/skills/patch-permission-approval/references/notes.md"
  smoke_assert_file_exists "$subdir_target" \
    "subdirectory file under references/ preserved during sync"
  # Same intentional-tilde rationale as assert_path_normalization above.
  # shellcheck disable=SC2088
  if grep -F '~/.agent-bridge/' "$subdir_target" >/dev/null 2>&1; then
    smoke_fail "subdir file still contains '~/.agent-bridge/' after rewrite (target=$subdir_target)"
  fi
  smoke_assert_contains \
    "$(cat "$subdir_target")" \
    "$FIXTURE_BRIDGE_HOME/agb show" \
    "subdir SKILL reference rewrites bridge path to absolute BRIDGE_HOME"
}

# Render a single skill with `BRIDGE_HOME=$1`, into an isolated home
# unique to that run. The variant tests run after the main sync and
# therefore re-use the seeded source tree under $FIXTURE_BRIDGE_HOME
# (a real path with no quirks). The non-canonical input is what the
# variant feeds to the helper as BRIDGE_HOME — the renderer must
# canonicalize it to the same `$FIXTURE_BRIDGE_HOME` text in the
# rendered SKILL.md.
invoke_sync_with_bridge_home() {
  local bridge_home_input="$1"
  local isolated_home_root="$2"
  local os_user="$3"

  local repo_root="$SMOKE_REPO_ROOT"
  local bash_bin="${BRIDGE_BASH_BIN:-bash}"

  BRIDGE_HOME="$bridge_home_input" \
  BRIDGE_HOST_PLATFORM_OVERRIDE=Linux \
  BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$isolated_home_root" \
  "$bash_bin" -c "
    set -uo pipefail
    source '$repo_root/bridge-lib.sh'

    bridge_reset_roster_maps

    BRIDGE_AGENT_IDS+=($FIXTURE_AGENT)
    BRIDGE_AGENT_ENGINE[$FIXTURE_AGENT]=claude
    BRIDGE_AGENT_ISOLATION_MODE[$FIXTURE_AGENT]=linux-user
    BRIDGE_AGENT_OS_USER[$FIXTURE_AGENT]=$os_user

    bridge_linux_sudo_root() {
      \"\$@\"
    }

    bridge_sync_isolated_home_claude_skills '$FIXTURE_AGENT'
  "
}

# Render with BRIDGE_HOME ending in a trailing slash. Canonicalization
# must produce the same absolute path as the canonical fixture, with no
# `//` doubled separator in the rewritten text.
assert_canonicalize_trailing_slash() {
  local home_trailing="$FIXTURE_BRIDGE_HOME/"
  local iso_root="$SMOKE_TMP_ROOT/home-trailing"
  local iso_user="agent-bridge-smoke-trailing"
  local iso_home="$iso_root/$iso_user"

  mkdir -p "$iso_home"
  invoke_sync_with_bridge_home "$home_trailing" "$iso_root" "$iso_user"

  local target="$iso_home/.claude/skills/agent-bridge-runtime/SKILL.md"
  smoke_assert_file_exists "$target" \
    "trailing-slash variant: rendered SKILL.md exists"
  smoke_assert_contains \
    "$(cat "$target")" \
    "$FIXTURE_BRIDGE_HOME/agb inbox" \
    "trailing-slash variant: rewrite produces canonical BRIDGE_HOME path"
  smoke_assert_not_contains \
    "$(cat "$target")" \
    "$FIXTURE_BRIDGE_HOME//" \
    "trailing-slash variant: no doubled '//' separator in rendered output"
}

# Render with BRIDGE_HOME containing an embedded doubled slash. normpath
# collapses the duplicate; the rewritten text must match the canonical
# single-slash absolute form.
assert_canonicalize_doubled_slash() {
  local home_double
  home_double="$(dirname "$FIXTURE_BRIDGE_HOME")//$(basename "$FIXTURE_BRIDGE_HOME")"
  local iso_root="$SMOKE_TMP_ROOT/home-double"
  local iso_user="agent-bridge-smoke-double"
  local iso_home="$iso_root/$iso_user"

  mkdir -p "$iso_home"
  invoke_sync_with_bridge_home "$home_double" "$iso_root" "$iso_user"

  local target="$iso_home/.claude/skills/agent-bridge-runtime/SKILL.md"
  smoke_assert_file_exists "$target" \
    "doubled-slash variant: rendered SKILL.md exists"
  smoke_assert_contains \
    "$(cat "$target")" \
    "$FIXTURE_BRIDGE_HOME/agb inbox" \
    "doubled-slash variant: rewrite produces canonical BRIDGE_HOME path"
  smoke_assert_not_contains \
    "$(cat "$target")" \
    "$FIXTURE_BRIDGE_HOME//" \
    "doubled-slash variant: doubled '//' collapsed to single '/'"
}

# Render with BRIDGE_HOME pointing at a symlink to the real bridge home.
# realpath must resolve the symlink so the rewritten text reflects the
# underlying real path, not the symlink string.
assert_canonicalize_symlink() {
  local link_path="$SMOKE_TMP_ROOT/bridge-home-symlink"
  ln -s "$FIXTURE_BRIDGE_HOME" "$link_path"

  local iso_root="$SMOKE_TMP_ROOT/home-symlink"
  local iso_user="agent-bridge-smoke-symlink"
  local iso_home="$iso_root/$iso_user"

  mkdir -p "$iso_home"
  invoke_sync_with_bridge_home "$link_path" "$iso_root" "$iso_user"

  local target="$iso_home/.claude/skills/agent-bridge-runtime/SKILL.md"
  smoke_assert_file_exists "$target" \
    "symlink variant: rendered SKILL.md exists"
  smoke_assert_contains \
    "$(cat "$target")" \
    "$FIXTURE_BRIDGE_HOME/agb inbox" \
    "symlink variant: rewrite resolves to real BRIDGE_HOME path"
  smoke_assert_not_contains \
    "$(cat "$target")" \
    "$link_path/agb" \
    "symlink variant: symlink string does not appear in rendered output"
}

main() {
  build_fixture
  invoke_sync

  smoke_run "all bridge-native skills present in isolated home" \
    assert_all_skills_present
  smoke_run "path text normalized to absolute BRIDGE_HOME" \
    assert_path_normalization
  smoke_run "skill subdirectory structure preserved" \
    assert_subdir_preserved

  # Canonicalization sub-tests (issue #544 PR3 r2). Each variant feeds
  # the helper a non-canonical BRIDGE_HOME spelling and asserts the
  # rendered SKILL.md contains the same canonical absolute path the
  # main fixture produces. Without realpath+normpath these diverge.
  smoke_run "trailing-slash BRIDGE_HOME canonicalizes to bare path" \
    assert_canonicalize_trailing_slash
  smoke_run "doubled-slash BRIDGE_HOME canonicalizes to single slash" \
    assert_canonicalize_doubled_slash
  smoke_run "symlinked BRIDGE_HOME canonicalizes to real path" \
    assert_canonicalize_symlink

  smoke_log "PASS"
}

main "$@"
