#!/usr/bin/env bash
# shellcheck shell=bash
#
# bridge-smoke-tmux-isolation.sh — fleet-down guard for the smoke harness.
#
# Root cause of the 2026-06-16 double fleet-down: every bridge agent shares the
# host's DEFAULT tmux socket (`bridge-start.sh` launches `tmux new-session` with
# NO `-S`/`-L`), so that single server is a whole-fleet single point of failure.
# The smoke harness is destructive (it stops daemons and runs
# `tmux kill-session` / server teardown). When a smoke is run from inside an
# agent's own tmux pane, `$TMUX` points at the LIVE default server, so a stray
# kill/teardown there downs every agent at once — even if `TMUX_TMPDIR` is set,
# because an inherited `$TMUX` overrides socket selection.
#
# This guard forces the smoke harness into a PRIVATE tmux universe and
# fail-closes if the resolved socket dir could be the shared/live one. Source it
# (do NOT exec it) at the very top of every smoke entry point — BEFORE any tmux
# operation — so a sourced `exit 1` aborts the destructive run:
#
#     source "$REPO_ROOT/lib/bridge-smoke-tmux-isolation.sh"
#
# It is idempotent: re-sourcing reuses the already-exported private TMUX_TMPDIR.
# Setting `BRIDGE_SMOKE_TMUX_ISOLATION=off` is intentionally NOT honored — the
# guard must not be defeatable by an inherited env var (that is the whole point).

# Sever an inherited live-server attachment. This is the CRITICAL line: without
# it a private TMUX_TMPDIR is bypassed by `$TMUX` and tmux talks to the live
# default server.
unset TMUX TMUX_PANE 2>/dev/null || true

if [[ -z "${TMUX_TMPDIR:-}" ]]; then
  # No socket dir chosen — create a private one. mktemp under $TMPDIR (or /tmp)
  # yields a path that cannot collide with the default `/tmp/tmux-<uid>` server.
  TMUX_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-smoke-tmux.XXXXXX")" || {
    printf '[smoke][error] tmux isolation: mktemp -d failed; refusing to run a destructive smoke without a private tmux socket dir.\n' >&2
    exit 1
  }
  export TMUX_TMPDIR
  printf '[smoke] tmux socket isolated: TMUX_TMPDIR=%s (fleet-down guard)\n' "$TMUX_TMPDIR" >&2
else
  # A socket dir was supplied — refuse it if it can resolve to a shared/live
  # tmux server dir. `${TMUX_TMPDIR%/}` strips a trailing slash; exact-match the
  # known shared roots and the `/tmp/tmux-*` default-server family.
  case "${TMUX_TMPDIR%/}" in
    /tmp | /private/tmp | /var/folders | /private/var/folders | \
    /tmp/tmux-* | /private/tmp/tmux-*)
      printf '[smoke][error] refusing to run: TMUX_TMPDIR=%s can resolve to the shared/live tmux socket.\n' "$TMUX_TMPDIR" >&2
      printf '[smoke][error] this harness kills tmux sessions; on the default socket that downs live bridge agents (2026-06-16 fleet-down incident).\n' >&2
      printf '[smoke][error] unset TMUX_TMPDIR (the guard will mktemp a private dir) or point it at a private mktemp dir.\n' >&2
      exit 1
      ;;
  esac
fi
