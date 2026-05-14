#!/usr/bin/env bash
# shellcheck shell=bash
# bridge-admin-pair.sh — register the sibling codex dev agent (`<admin>-dev`)
# that the admin agent pair-programs with, and render the managed
# pair-programming SOP block that gets injected into the admin's CLAUDE.md.
#
# Issue #517. The bash-side managed-block rendering MUST stay byte-identical
# to bridge-upgrade.py's render_admin_pair_block() so a fresh admin install
# (this lib) and an upgraded admin (bridge-upgrade.py migrate-agents) end up
# with the same content.

bridge_admin_pair_name() {
  local admin="$1"
  printf '%s-dev' "$admin"
}

# Idempotently register the sibling codex agent for the given admin.
# - engine=codex, session-type=static-codex, source=static
# - workdir inherits the admin's workdir (admin pair-programs in the same tree)
# - channels: none (queue-only — pair never reaches an external surface)
# - --always-on so the daemon picks it up automatically
# Prints a structured stderr line on every action so callers can audit.
# Returns 0 when the pair exists at exit (created or already-existed); 1 on
# hard failure of `agent create`.
bridge_ensure_admin_codex_pair() {
  local admin="$1"
  local pair_name pair_workdir create_output rc

  [[ -n "$admin" ]] || return 1
  pair_name="$(bridge_admin_pair_name "$admin")"

  if bridge_agent_exists "$pair_name"; then
    printf '[admin-pair] skipped (already-exists): %s\n' "$pair_name" >&2
    return 0
  fi

  pair_workdir="$(bridge_agent_workdir "$admin" 2>/dev/null || true)"
  if [[ -z "$pair_workdir" ]]; then
    pair_workdir="$(bridge_agent_default_home "$admin")"
  fi

  local description="Dedicated codex dev pair for ${admin}: plans, reviews, and proposes code changes via the queue."
  local role_text="Pair programmer for ${admin} (codex)"

  # Issue #691: pair shares the admin's workdir by design (they pair-program
  # in the same tree). Post-#686 the admin's workdir already contains managed
  # `.agents/` scaffold, which trips run_create's non-empty-workdir guard.
  # Opt out of the guard with --allow-shared-workdir so the backfill no
  # longer surfaces a spurious "admin-pair backfill failed" warning on
  # otherwise-clean fresh inits.
  set +e
  create_output="$(
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" agent create "$pair_name" \
      --engine codex \
      --session-type static-codex \
      --session "$pair_name" \
      --display-name "$pair_name" \
      --workdir "$pair_workdir" \
      --role "$role_text" \
      --description "$description" \
      --always-on \
      --allow-shared-workdir \
      2>&1
  )"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    # Defensive: `agent create` can return nonzero after the roster mutation
    # has already happened (post-register validation, env warnings, etc.).
    # Reload the roster and let the inject step run if the pair actually
    # made it. This keeps the install convergent on transient failures
    # rather than leaving an admin with a registered pair but no SOP block.
    # (Issue #517 r1 review finding 3.)
    # Issue #848: the child process touched the roster files on disk,
    # so the in-process cache must be discarded before re-reading.
    bridge_roster_cache_invalidate
    bridge_load_roster
    if bridge_agent_exists "$pair_name"; then
      printf '[admin-pair] create-partial-but-registered: %s\n%s\n' "$pair_name" "$create_output" >&2
      return 0
    fi
    printf '[admin-pair] create-failed: %s\n%s\n' "$pair_name" "$create_output" >&2
    return 1
  fi

  printf '[admin-pair] created: %s\n' "$pair_name" >&2
  return 0
}

# Render the admin pair-programming SOP managed block for the given admin
# name. Output is read by callers and either written into the admin's
# CLAUDE.md (via bridge-upgrade.py inject-admin-pair-block) or compared
# against the python-rendered output during smoke verification.
#
# Keep the body byte-identical to bridge-upgrade.py:render_admin_pair_block.
bridge_admin_pair_managed_block() {
  local admin="$1"
  local pair
  pair="$(bridge_admin_pair_name "$admin")"
  cat <<EOF
<!-- BEGIN MANAGED:admin-pair-programming -->
## Pair Programming Protocol (with \`${pair}\`)

This admin agent always pair-programs with \`${pair}\` (codex). Never commit or
file an upstream PR without going through the loop below; never ask the operator
to manually trigger a review.

1. **Plan brief.** Write \`/tmp/<task-slug>-plan.md\` describing background, focus
   checklist, expected output shape (\`plan-ok\` / \`needs-more\`). Queue:
   \`agent-bridge task create --to ${pair} --title "[plan] <subject>" --body-file /tmp/...\`.
2. **Wait for plan-ok.** Implement only after \`${pair}\` returns
   \`plan-ok\` or after a \`needs-more\` round resolves.
3. **Implement** in your worktree.
4. **Code review.** Write \`/tmp/<task-slug>-codereview.md\` (artifacts to review,
   focus list). Queue: \`agent-bridge task create --to ${pair} --title "[review] <subject>" --body-file ...\`.
5. **Merge only on \`implement-ok\`.** If \`needs-more\`, action and resubmit as
   r2/r3 with bumped title and a fresh brief. After 3 rounds without
   \`implement-ok\`, stop and reconsider scope.
6. **Off-hours autonomy.** When the operator delegates explicitly, \`${pair}\`'s
   \`implement-ok\` substitutes for operator approval until the operator returns.

## Default workflow — \`wave-orchestration\`

When the operator asks for a feature, fix, or multi-issue ship, default to the
bundled \`wave-orchestration\` skill (\`.claude/skills/wave-orchestration/\`).
Independent work fans out as 2–4 parallel issue-fixer dispatches into isolated
worktrees; codex review goes through \`${pair}\` via the queue (or
\`codex:codex-rescue\` subagent when \`${pair}\` is busy). Single-track work still
uses this Pair Programming Protocol — wave is the multi-track extension, not
a replacement. Skip wave only for trivial one-line fixes or when the operator
explicitly asks for a sequential / non-parallel approach.

Out of scope for this pair: business decisions, anything tagged
\`human-decision-required\`. Those go to the operator channel, not \`${pair}\`.
<!-- END MANAGED:admin-pair-programming -->
EOF
}
