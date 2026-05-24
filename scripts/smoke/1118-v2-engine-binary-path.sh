#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1118-v2-engine-binary-path.sh — Issue #1118.
#
# Pins the contract that the engine binary's absolute path is resolved on
# the controller side and propagated into the sudo'd child via
# BRIDGE_ENGINE_BIN, so a v2 linux-user-isolated agent does NOT depend on
# the auto-provisioned service user's PATH for engine discovery.
#
# The bug (#1118): on fresh v0.14.5-beta6 + v2 linux-user isolation, the
# controller's per-user `claude` install (typically `~/.local/bin/claude`)
# is not on the service user's PATH (`sudo -n -u <svc_user> -H` uses
# sudo's default PATH, which does not include the controller's home), and
# `--preserve-env=PATH` is not passed. The launch_cmd is `claude --resume
# ... --name ...`; `bash -lc "claude ..."` under the service user therefore
# dies with `claude: command not found`. The daemon reports the opaque
# `start-command-failed` reason and enters a permanent backoff loop.
#
# The fix:
#   1. lib/bridge-agents.sh::bridge_resolve_engine_binary — `command -v
#      <engine>` against the controller's PATH, requires an absolute path
#      on disk.
#   2. bridge-start.sh — when an engine binary is resolved, prefixes
#      `BRIDGE_ENGINE_BIN=<abs>` to SESSION_CMD so the sudo'd child sees
#      the var.
#   3. bridge-run.sh — rewrites the leading `claude`/`codex` token in
#      LAUNCH_CMD to BRIDGE_ENGINE_BIN before exec via the Python helper
#      scripts/python-helpers/launch-cmd-engine-bin-rewrite.py.
#   4. BRIDGE_ENGINE_BIN is added to `bridge_agent_preserved_env_vars` so
#      a future caller that sets the var BEFORE sudo (rather than via the
#      SESSION_CMD prefix) is still propagated. The current code paths
#      use the SESSION_CMD prefix so the sudo --preserve-env list is a
#      belt-and-suspenders entry.
#
# Test plan (in-process bash — no live tmux / Claude / sudo). The smoke
# runs the Python rewrite helper and the bash resolver against synthetic
# fixtures:
#
#   T1. bridge_resolve_engine_binary with a fake `claude` binary placed
#       FIRST on PATH returns its absolute path (rc=0). The helper
#       requires an absolute path on disk (`command -v` returning a
#       shell function/alias is rejected as rc=1).
#   T2. The Python rewrite helper rewrites a launch_cmd starting with
#       `claude --resume <id> --name <agent>` to use the absolute path,
#       preserving every subsequent token. KEY=VALUE env-prefix tokens
#       are preserved verbatim ahead of the engine token (mirroring the
#       static / safe launch-cmd builders' parsing rules).
#   T3. The Python rewrite helper LEAVES an already-absolute engine path
#       untouched so an operator override (e.g. /opt/claude/bin/claude)
#       is not silently rewritten away.
#   T4. The Python rewrite helper is a no-op when the engine binary
#       argument is empty (caller decided not to rewrite) — the original
#       launch_cmd is printed unchanged.
#   T5. End-to-end: bridge-start.sh --dry-run for a linux-user isolated
#       static agent emits a `tmux_command=` line whose SESSION_CMD
#       (the bash -lc payload inside the sudo wrap) contains the
#       `BRIDGE_ENGINE_BIN=<abs>` prefix. Skipped cleanly when the
#       smoke host has no `claude` binary on PATH OR when sudo passwordless
#       to the synthetic service user is unavailable — both are
#       common on developer macOS hosts.
#
# Footgun #11: the driver is emitted with `printf '%s\n' >file` — no
# command substitution feeding heredoc-stdin, no `<<<` here-strings into
# bridge functions.

set -uo pipefail

SMOKE_NAME="1118-v2-engine-binary-path"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_log "begin"

REPO_ROOT="$SMOKE_REPO_ROOT"
REWRITE_HELPER="$REPO_ROOT/scripts/python-helpers/launch-cmd-engine-bin-rewrite.py"
smoke_assert_file_exists "$REWRITE_HELPER" "rewrite helper missing"

smoke_make_temp_root "$SMOKE_NAME"

# --- T1: bridge_resolve_engine_binary picks up a fake `claude` on PATH ---
FAKE_BIN_DIR="$SMOKE_TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN_DIR"
FAKE_CLAUDE="$FAKE_BIN_DIR/claude"
printf '#!/usr/bin/env bash\necho "fake-claude $*"\n' >"$FAKE_CLAUDE"
chmod +x "$FAKE_CLAUDE"

_bash_bin="${BASH:-/usr/bin/env bash}"

resolved_t1="$(
  PATH="$FAKE_BIN_DIR:$PATH" "$_bash_bin" -c '
    set -e
    SCRIPT_DIR="'"$REPO_ROOT"'"
    BRIDGE_SCRIPT_DIR="$SCRIPT_DIR"
    # bridge-layout-resolver.sh runs `bridge_resolve_layout` at source
    # time (lib/bridge-layout-resolver.sh:530). On a fresh CI checkout
    # without a layout-marker.sh on disk it dies with "Agent Bridge
    # v0.8.0 requires isolation-v2" unless BRIDGE_LAYOUT is set to v2
    # (env-override path). Other smokes pin this via
    # smoke_setup_bridge_home; T1-T4 here only need the temp root, so
    # set BRIDGE_LAYOUT directly for the inner subshell.
    BRIDGE_LAYOUT="v2"
    # bridge_layout_resolver_validate_env requires BRIDGE_DATA_ROOT to
    # accompany BRIDGE_LAYOUT=v2 (partial env is rejected — see
    # lib/bridge-layout-resolver.sh:128-141). Otherwise the validator
    # returns 1, the resolver falls through to fresh-install-candidate,
    # and bridge_die fires with "markerless(fresh-install-candidate)".
    BRIDGE_DATA_ROOT="${SMOKE_TMP_ROOT:-/tmp}/agent-bridge-data"
    export BRIDGE_SCRIPT_DIR BRIDGE_LAYOUT BRIDGE_DATA_ROOT
    source "$SCRIPT_DIR/bridge-lib.sh" >/dev/null 2>&1
    bridge_resolve_engine_binary claude
  ' 2>/dev/null
)"
smoke_assert_eq "$FAKE_CLAUDE" "$resolved_t1" "T1: bridge_resolve_engine_binary should return the fake absolute claude path"

# T1b: rejects an unsupported engine name.
if PATH="$FAKE_BIN_DIR:$PATH" "$_bash_bin" -c '
  set -e
  SCRIPT_DIR="'"$REPO_ROOT"'"
  BRIDGE_SCRIPT_DIR="$SCRIPT_DIR"
  BRIDGE_LAYOUT="v2"
  export BRIDGE_SCRIPT_DIR BRIDGE_LAYOUT
  source "$SCRIPT_DIR/bridge-lib.sh" >/dev/null 2>&1
  bridge_resolve_engine_binary not-an-engine
' >/dev/null 2>&1; then
  smoke_fail "T1b: unsupported engine should return rc=1"
fi

# T1c: returns rc=1 when binary is absent (empty PATH).
if PATH="" "$_bash_bin" -c '
  set -e
  SCRIPT_DIR="'"$REPO_ROOT"'"
  BRIDGE_SCRIPT_DIR="$SCRIPT_DIR"
  BRIDGE_LAYOUT="v2"
  export BRIDGE_SCRIPT_DIR BRIDGE_LAYOUT
  source "$SCRIPT_DIR/bridge-lib.sh" >/dev/null 2>&1
  bridge_resolve_engine_binary claude
' >/dev/null 2>&1; then
  smoke_fail "T1c: missing claude on PATH should return rc=1"
fi

smoke_log "T1 PASS — bridge_resolve_engine_binary"

# --- T2: rewrite helper substitutes bare engine token with absolute path ---
input_t2="claude --resume abc-123 --name dev_mun --dangerously-skip-permissions"
out_t2="$(python3 "$REWRITE_HELPER" "$FAKE_CLAUDE" "$input_t2")"
expected_t2="$FAKE_CLAUDE --resume abc-123 --name dev_mun --dangerously-skip-permissions"
smoke_assert_eq "$expected_t2" "$out_t2" "T2: bare claude → absolute path"

# T2b: env-prefix tokens before engine name are preserved verbatim.
input_t2b="FOO=bar BAZ=qux codex resume xyz --no-alt-screen"
out_t2b="$(python3 "$REWRITE_HELPER" "/usr/bin/codex" "$input_t2b")"
expected_t2b="FOO=bar BAZ=qux /usr/bin/codex resume xyz --no-alt-screen"
smoke_assert_eq "$expected_t2b" "$out_t2b" "T2b: env-prefix preserved, codex token rewritten"

smoke_log "T2 PASS — bare engine token rewrite"

# --- T3: already-absolute engine path is left untouched ---
input_t3="/opt/claude/bin/claude --name dev_mun"
out_t3="$(python3 "$REWRITE_HELPER" "$FAKE_CLAUDE" "$input_t3")"
smoke_assert_eq "$input_t3" "$out_t3" "T3: absolute engine path retained"

smoke_log "T3 PASS — absolute path retained"

# --- T4: empty engine_bin is a no-op ---
input_t4="claude --name dev_mun"
out_t4="$(python3 "$REWRITE_HELPER" "" "$input_t4")"
smoke_assert_eq "$input_t4" "$out_t4" "T4: empty engine_bin no-op"

# T4b: tolerate a malformed (unbalanced quote) input — returns the
# original unchanged (always exits 0) so the launch path falls back to
# the legacy bare-name behavior.
input_t4b='claude --name "dev_mun'
out_t4b="$(python3 "$REWRITE_HELPER" "$FAKE_CLAUDE" "$input_t4b")"
smoke_assert_eq "$input_t4b" "$out_t4b" "T4b: malformed input returned unchanged"

smoke_log "T4 PASS — no-op safety"

# --- T5: bridge-start.sh --dry-run propagates BRIDGE_ENGINE_BIN ---
#
# This branch needs a working bridge HOME and a static-isolated agent. We
# scaffold one through `agent-bridge agent create --isolate-mode linux-user`
# semantics by writing a minimal roster + state directly. To keep the
# smoke cheap and host-independent we drive `bridge-start.sh --dry-run`
# in the "non-isolated" branch first (sudo wrap inactive) and assert that
# BRIDGE_ENGINE_BIN still rides the SESSION_CMD prefix. (The sudo-wrap
# arm of the prefix injection is identical — the var is unconditional in
# bridge-start.sh; the sudo wrap then forwards it via the SESSION_CMD
# bash -lc payload.)
#
# Skipped cleanly if the host has no `claude` on PATH at all (the
# resolver returns rc=1 and the prefix is intentionally omitted).
if ! command -v claude >/dev/null 2>&1 && [[ ! -x "$FAKE_CLAUDE" ]]; then
  smoke_skip "T5" "no claude binary on PATH and fake binary missing"
else
  smoke_setup_bridge_home "$SMOKE_NAME"

  # Minimal static roster entry: a Claude agent with workdir, loop, etc.
  AGENT_NAME="iso-engine-bin-smoke"
  WORK_DIR="$SMOKE_TMP_ROOT/work"
  mkdir -p "$WORK_DIR"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# shellcheck shell=bash disable=SC2034' \
    "bridge_add_agent_id_if_missing \"$AGENT_NAME\"" \
    "BRIDGE_AGENT_DESC[\"$AGENT_NAME\"]=\"#1118 smoke fixture\"" \
    "BRIDGE_AGENT_ENGINE[\"$AGENT_NAME\"]=\"claude\"" \
    "BRIDGE_AGENT_SESSION[\"$AGENT_NAME\"]=\"$AGENT_NAME\"" \
    "BRIDGE_AGENT_WORKDIR[\"$AGENT_NAME\"]=\"$WORK_DIR\"" \
    "BRIDGE_AGENT_LOOP[\"$AGENT_NAME\"]=\"1\"" \
    "BRIDGE_AGENT_CONTINUE[\"$AGENT_NAME\"]=\"0\"" \
    "BRIDGE_AGENT_LAUNCH_CMD[\"$AGENT_NAME\"]=\"claude --name $AGENT_NAME\"" \
    >"$BRIDGE_ROSTER_FILE"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"

  # Make the fake binary the FIRST claude on PATH so the resolver picks
  # it deterministically even if the host has a real one too.
  export PATH="$FAKE_BIN_DIR:$PATH"

  set +e
  dry_run_output="$("$_bash_bin" "$REPO_ROOT/bridge-start.sh" "$AGENT_NAME" --dry-run 2>&1)"
  dry_run_rc=$?
  set -e
  if [[ $dry_run_rc -ne 0 ]]; then
    smoke_log "T5 dry-run output:"
    printf '%s\n' "$dry_run_output" | sed 's/^/  /' >&2
    smoke_fail "T5: bridge-start.sh --dry-run failed (rc=$dry_run_rc)"
  fi

  tmux_line="$(printf '%s\n' "$dry_run_output" | grep '^tmux_command=' || true)"
  [[ -n "$tmux_line" ]] || {
    smoke_log "T5 dry-run output:"
    printf '%s\n' "$dry_run_output" | sed 's/^/  /' >&2
    smoke_fail "T5: dry-run did not emit tmux_command= line"
  }
  smoke_assert_contains "$tmux_line" "BRIDGE_ENGINE_BIN=" "T5: SESSION_CMD prefix should carry BRIDGE_ENGINE_BIN"
  smoke_assert_contains "$tmux_line" "$FAKE_CLAUDE" "T5: SESSION_CMD prefix should carry the resolved fake-claude path"

  smoke_log "T5 PASS — BRIDGE_ENGINE_BIN propagated into SESSION_CMD"
fi

smoke_log "ok"
