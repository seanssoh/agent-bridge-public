#!/usr/bin/env bash
# scripts/smoke/tmux-server-bridge-layout-cleanup.sh — regression for
# patch ticket #4798 (2026-05-17). Pre-PR-#926 installs leaked
# BRIDGE_LAYOUT / BRIDGE_DATA_ROOT into the tmux server's GLOBAL env
# via the original `agent-bridge` invocation's environment inheritance
# at tmux server startup. Once leaked, every new pane inherits the
# stale value and the layout resolver fires its
#   `[경고] BRIDGE_LAYOUT=legacy is a stale pre-v0.8.0 env override; ...`
# warning on every CLI command. PR #926 stopped the export prefix from
# re-forwarding the vars, but did NOT clean the existing tmux server-
# level entries; the operator saw the warning on every `agb`/`agent-
# bridge` invocation until they restarted the tmux server by hand.
#
# This test pins two contracts:
#
#   C1: a v2 install on a host that has tmux available will, on
#       upgrade `--apply`, issue `tmux setenv -u -g BRIDGE_LAYOUT`
#       (and the same for BRIDGE_DATA_ROOT). The actual upgrade flow
#       is not exercised end-to-end (that requires a live install); we
#       instead verify the cleanup snippet itself by seeding a private
#       tmux server, setting the stale vars on it, running the same
#       `tmux setenv -u -g` calls the upgrader runs, and asserting
#       they are gone.
#
#   C2: the layout resolver warning is gated by a once-per-process
#       sentinel (`_BRIDGE_LAYOUT_STALE_ENV_WARNED`). Even when
#       BRIDGE_LAYOUT=legacy is set in the env and a valid v2 marker
#       is on disk, sourcing the resolver twice in the same process
#       only emits the warning once.

# Bash 4+ re-exec — sourcing the resolver needs declare -g and
# associative arrays. Mirror the prelude used by sibling smokes.
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:tmux-server-bridge-layout-cleanup] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="tmux-server-bridge-layout-cleanup"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

failed=0

# ---------------------------------------------------------------------------
# C1: tmux server-env cleanup snippet actually unsets the stale vars.
# ---------------------------------------------------------------------------
# We run the SAME `tmux setenv -u -g BRIDGE_LAYOUT|BRIDGE_DATA_ROOT` calls
# bridge-upgrade.sh runs, against a private tmux server we seed with the
# stale values. If tmux isn't available on the host (CI minimal image),
# skip C1 — the snippet's `command -v tmux` guard already makes it a no-op
# in that case, and the upgrader path is unreachable without tmux.
TMUX_SOCKET_DIR=""
TMUX_SOCKET_NAME=""
if ! command -v tmux >/dev/null 2>&1; then
  echo "  SKIP  C1: tmux not available on host (snippet is no-op without tmux)"
else
  TMUX_SOCKET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-smoke-tmux.XXXXXX")"
  TMUX_SOCKET_NAME="agb-smoke-$$"

  # `start-server` doesn't allocate a real session — but `setenv -g`
  # requires a running server. Seed with a detached session that has no
  # window-side effects.
  if ! tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" \
        new-session -d -s smoke -x 80 -y 24 'sleep 60' >/dev/null 2>&1; then
    echo "  SKIP  C1: could not start a private tmux server (host restriction)"
  else
    tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" \
      setenv -g BRIDGE_LAYOUT legacy
    tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" \
      setenv -g BRIDGE_DATA_ROOT /tmp/should-not-survive

    # Sanity: vars are present before cleanup.
    pre_layout="$(tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" \
      show-environment -g BRIDGE_LAYOUT 2>/dev/null || true)"
    if [[ "$pre_layout" != "BRIDGE_LAYOUT=legacy" ]]; then
      echo "  FAIL  C1 setup: expected BRIDGE_LAYOUT=legacy on the test server, got '$pre_layout'" >&2
      failed=1
    fi

    # Apply the same cleanup the upgrader runs.
    tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" \
      setenv -u -g BRIDGE_LAYOUT 2>/dev/null || true
    tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" \
      setenv -u -g BRIDGE_DATA_ROOT 2>/dev/null || true

    post_layout="$(tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" \
      show-environment -g BRIDGE_LAYOUT 2>/dev/null || true)"
    post_data_root="$(tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" \
      show-environment -g BRIDGE_DATA_ROOT 2>/dev/null || true)"

    # `show-environment -g <name>` on an unset var prints `-<name>` on
    # current tmux versions (the "removed-from-server" sentinel) or an
    # empty line on very old tmuxes. Either is a pass for our purposes;
    # what must NOT show up is `<name>=<value>`.
    if [[ "$post_layout" == BRIDGE_LAYOUT=* ]]; then
      echo "  FAIL  C1: BRIDGE_LAYOUT still set on tmux server after cleanup (got '$post_layout')" >&2
      failed=1
    else
      echo "  PASS  C1: BRIDGE_LAYOUT removed from tmux server-env"
    fi

    if [[ "$post_data_root" == BRIDGE_DATA_ROOT=* ]]; then
      echo "  FAIL  C1: BRIDGE_DATA_ROOT still set on tmux server after cleanup (got '$post_data_root')" >&2
      failed=1
    else
      echo "  PASS  C1: BRIDGE_DATA_ROOT removed from tmux server-env"
    fi

    # Idempotency: running the cleanup a second time with the vars
    # already unset must not error.
    if ! tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" \
          setenv -u -g BRIDGE_LAYOUT 2>/dev/null; then
      echo "  WARN  C1: second 'tmux setenv -u -g' returned non-zero; snippet swallows this via '|| true', but the call is documented as idempotent."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# C2: layout resolver warning is gated to once per process.
# ---------------------------------------------------------------------------
# Seed a fake $BRIDGE_HOME with a valid v2 marker, point the env at it,
# then source bridge-lib.sh twice from a single child shell while the
# stale BRIDGE_LAYOUT=legacy is in the env. The first source must emit
# the `stale pre-v0.8.0` warning; the second source must NOT.

C2_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agb-smoke-c2.XXXXXX")"
C2_OUT="$(mktemp "${TMPDIR:-/tmp}/agb-c2-out.XXXXXX")"
trap '
  rm -rf "$C2_HOME"
  rm -f "$C2_OUT"
  if [[ -n "${TMUX_SOCKET_NAME:-}" && -n "${TMUX_SOCKET_DIR:-}" ]]; then
    tmux -L "$TMUX_SOCKET_NAME" -S "$TMUX_SOCKET_DIR/sock" kill-server 2>/dev/null || true
    rm -rf "$TMUX_SOCKET_DIR"
  fi
' EXIT
mkdir -p "$C2_HOME/state" "$C2_HOME/agents" "$C2_HOME/data"

# Write a valid v2 marker. Owner must be the current UID (resolver
# rejects markers owned by anyone else), mode must have no group/world
# write bits. Built via printf rather than a `cat >file <<EOF` heredoc
# to stay outside footgun #11's reach when this smoke gets invoked
# from inside a $(...) capture.
MARKER="$C2_HOME/state/layout-marker.sh"
printf 'BRIDGE_LAYOUT=v2\nBRIDGE_DATA_ROOT=%s\n' "'$C2_HOME/data'" >"$MARKER"
chmod 0640 "$MARKER"

# Existing-install evidence (tasks.db) so the resolver does NOT classify
# this fake home as fresh-install-candidate and demand the bypass.
: >"$C2_HOME/state/tasks.db"

C2_DRIVER="$SCRIPT_DIR/tmux-server-bridge-layout-cleanup-driver.sh"
if [[ ! -x "$C2_DRIVER" ]]; then
  echo "  FAIL  C2: missing driver: $C2_DRIVER" >&2
  exit 2
fi

# Run the driver with the fake home; capture combined stdout+stderr.
# Unset any inherited sentinel so the first source sees a virgin slate.
env -u _BRIDGE_LAYOUT_STALE_ENV_WARNED \
  BRIDGE_HOME="$C2_HOME" \
  BRIDGE_LAYOUT_MARKER_DIR="$C2_HOME/state" \
  BRIDGE_LAYOUT=legacy \
  "$C2_DRIVER" "$REPO_ROOT" >"$C2_OUT" 2>&1 || {
  echo "  FAIL  C2 driver exited non-zero. Output:" >&2
  sed 's/^/    /' "$C2_OUT" >&2
  failed=1
}

# Count the "stale pre-v0.8.0" warning occurrences. The marker text is
# stable in the resolver. We accept both Korean `[경고]` prefix and the
# raw English snippet because terminals stripping ANSI / UTF8 in CI
# could mangle the prefix.
warn_count="$(grep -c 'stale pre-v0\.8\.0 env override' "$C2_OUT" || true)"
if [[ "$warn_count" -eq 1 ]]; then
  echo "  PASS  C2: stale-env warning emitted exactly once across two resolver sources"
elif [[ "$warn_count" -eq 0 ]]; then
  echo "  FAIL  C2: stale-env warning was NOT emitted on first source (gate over-fired)" >&2
  sed 's/^/    /' "$C2_OUT" >&2
  failed=1
else
  echo "  FAIL  C2: stale-env warning emitted $warn_count time(s) — gate did not hold" >&2
  sed 's/^/    /' "$C2_OUT" >&2
  failed=1
fi

if (( failed )); then
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
