#!/usr/bin/env bash
# shellcheck shell=bash
# bridge-init-codex-pair.sh — fresh-install auto-provisioning of the admin's
# permanent `<admin>-dev` codex pair.
#
# Issue #1052 (reconsiders #4769, which reverted #517): on a fresh install the
# admin agent should ship with its sibling `<admin>-dev` codex agent so the
# `<admin> (claude) + <admin>-dev (codex)` pair-programming model works out of
# the box. The operator's 2026-05-22 decision gates this on TWO conditions:
#
#   1. the `codex` CLI is present on the controller's PATH, AND
#   2. the resolved host profile is `server` (an always-on production host).
#
# The `dev` profile deliberately stays admin-only (the #4769 dev-minimal
# philosophy) — `bridge_host_profile_emit_dev_advisories` in
# lib/bridge-host-profile.sh already prints the manual
# `agent create <admin>-dev --engine codex …` recipe for that path. When codex
# is absent the claude admin runs solo and onboarding mentions that
# pair-programming is unavailable.
#
# The helper is invoked from bridge-init.sh AFTER host-profile resolution and
# BEFORE bridge_init_register_default_picker_sweep — the picker-sweep cron
# targets `<admin>-dev`, so the pair must exist first or the cron registration
# skips. Because the pair is created by a child `agent create` subprocess, the
# helper invalidates + reloads the parent's roster cache after a successful
# create so the in-memory `bridge_agent_exists` check inside the picker-sweep
# registration sees the freshly created pair on this same first-run init (the
# #848 child-mutation pattern, mirroring the admin create at bridge-init.sh).
# Non-fatal on every failure path: a codex-pair backfill must never fail an
# otherwise-successful admin install.

# Auto-provision the admin's `<admin>-dev` codex pair when codex is present and
# the host profile is `server`.
#
# Args:
#   $1 = agent-bridge CLI path (the live CLI under $BRIDGE_HOME)
#   $2 = admin agent id (drives the `<admin>-dev` pair name + workdir)
#   $3 = resolved host profile (`server` | `dev` | empty)
#
# Behavior (all branches print a structured `[init] codex-pair …` stderr line):
#   - profile != server      → skip (dev path keeps its own advisory).
#   - codex CLI absent        → skip + onboarding note (claude admin runs solo).
#   - pair already in roster  → skip (idempotent; re-running init is safe).
#   - else                    → `agent create <admin>-dev --engine codex …`.
#
# Always returns 0 — init must keep going regardless of the outcome.
bridge_init_provision_admin_codex_pair() {
  local agent_bridge_cli="$1"
  local admin_agent="$2"
  local host_profile="$3"
  local pair_name="${admin_agent}-dev"

  if [[ -z "$agent_bridge_cli" || -z "$admin_agent" ]]; then
    printf '[init] codex-pair provisioning skipped — missing CLI path or admin agent\n' >&2
    return 0
  fi
  if [[ ! -x "$agent_bridge_cli" ]]; then
    printf '[init] codex-pair provisioning skipped — CLI not executable: %s\n' "$agent_bridge_cli" >&2
    return 0
  fi

  # Gate 1: host profile must be `server`. The `dev` profile is intentionally
  # admin-only; bridge_host_profile_emit_dev_advisories already prints the
  # manual create recipe there.
  if [[ "$host_profile" != "server" ]]; then
    printf '[init] codex-pair auto-provisioning skipped — host profile is %s (server-only); see the dev advisory for the manual `agent create %s --engine codex` recipe\n' \
      "${host_profile:-unset}" "$pair_name" >&2
    return 0
  fi

  # Gate 2: codex CLI must be on PATH. Reuse bridge_resolve_engine_cli rather
  # than bridge_init_require_command — an absent codex CLI is non-fatal here
  # (the claude admin runs solo).
  local codex_cli=""
  codex_cli="$(bridge_resolve_engine_cli codex 2>/dev/null || true)"
  if [[ -z "$codex_cli" ]]; then
    printf '[init] codex-pair auto-provisioning skipped — codex CLI not found on PATH; pair-programming is unavailable and %s runs solo. Install the codex CLI and re-run bridge-bootstrap.sh to backfill %s.\n' \
      "$admin_agent" "$pair_name" >&2
    return 0
  fi

  # Idempotency: re-running bootstrap when the pair already exists must not
  # error or duplicate.
  if bridge_agent_exists "$pair_name" 2>/dev/null; then
    printf '[init] codex-pair already provisioned — skip: %s\n' "$pair_name" >&2
    return 0
  fi

  # Inherit the admin's workdir so the pair programs in the same tree. Fall
  # back to the pair's own default home when the admin workdir is unknown.
  local pair_workdir=""
  pair_workdir="$(bridge_agent_workdir "$admin_agent" 2>/dev/null || true)"
  if [[ -z "$pair_workdir" ]]; then
    pair_workdir="$(bridge_agent_default_home "$pair_name" 2>/dev/null || true)"
  fi

  local description="Dedicated codex dev pair for ${admin_agent}: plans, reviews, and proposes code changes via the queue."
  local role_text="Pair programmer for ${admin_agent} (codex)"

  local create_args=(agent create "$pair_name"
    --engine codex
    --session-type static-codex
    --session "$pair_name"
    --display-name "$pair_name"
    --role "$role_text"
    --description "$description"
    --always-on)
  if [[ -n "$pair_workdir" ]]; then
    # The admin scaffold already populated this workdir; opt into layering
    # the codex pair onto it (issue #691 `--allow-shared-workdir` contract).
    create_args+=(--workdir "$pair_workdir" --allow-shared-workdir)
  fi

  # Issue #1047: `agent create` is caller-trust gated and rejects an
  # `agent-direct` source. This is an operator-initiated bootstrap step that
  # runs as a subprocess with redirected stdout (TTY detection would demote it
  # to `agent-direct`). Mark it as a sanctioned operator-trusted caller — the
  # same idiom the admin create in bridge-init.sh uses.
  local create_output="" rc=0
  set +e
  create_output="$(BRIDGE_CALLER_SOURCE="operator-trusted-id" \
    "$BRIDGE_BASH_BIN" "$agent_bridge_cli" "${create_args[@]}" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    printf '[init] codex-pair auto-provisioning failed for %s — operator can create it manually with `agent create %s --engine codex …`\n%s\n' \
      "$pair_name" "$pair_name" "$create_output" >&2
    return 0
  fi

  # Issue #848 pattern (also applied to the admin create at
  # bridge-init.sh:509-513): the child `agent create` invocation above
  # mutated `agent-roster.local.sh` on disk, but the parent bridge-init.sh
  # process still holds a roster cache loaded BEFORE the pair existed. The
  # very next caller — bridge_init_register_default_picker_sweep — gates on
  # `bridge_agent_exists "<admin>-dev"`, which reads in-memory roster state
  # only; without this refresh it sees the stale cache and skips the cron on
  # this same first-run init. Invalidate + reload the parent's cache here so
  # the picker-sweep registration that follows sees the freshly created pair.
  bridge_roster_cache_invalidate
  bridge_load_roster

  printf '[init] codex-pair auto-provisioned: %s (engine=codex, always-on) — admin pair for %s\n' \
    "$pair_name" "$admin_agent" >&2
  return 0
}
