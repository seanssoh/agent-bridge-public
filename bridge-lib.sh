#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

# ===========================================================================
# AMBIENT-SECRET HARDENING for the Bash-3.2→4+ re-exec (issue #1454 — the
# SHARED ROOT of the inherited-env credential-exposure class).
# ===========================================================================
#
# bridge-lib.sh is sourced by essentially every entry point. Its Bash-3.2→4+
# re-exec (below) historically ran EXTERNAL commands WHILE the operator's
# ambient secret env (e.g. the Claude OAuth token) could still be live and an
# attacker-controlled hook could intercept them:
#   - a `$(command -v bash …)` command-substitution child in the candidate list,
#   - a candidate-version probe invoked with `-lc` (a LOGIN shell — it sources
#     the operator's profile AND honors BASH_ENV), and
#   - a `$(cd -P "$(dirname …)" && pwd -P)` command-substitution to compute
#     BRIDGE_SCRIPT_DIR (the `dirname` fork).
# A same-UID caller that `export -f`'d a function named after any of those
# commands (e.g. `dirname()`, incl. the `source`/`.`/`builtin`/`command`/`local`
# builtins — neutralized via the un-shadowable `POSIXLY_CORRECT=1` seed) or
# planted such a binary on PATH could have its code run IN this shell / a child
# of it while the secret was readable, and exfiltrate it. PRs #1443
# (bridge-usage.sh) and #1452/#1444 (bridge-run.sh) each closed this IN THEIR
# OWN LANE; #1454 closes the re-exec at the shared bridge-lib.sh root.
#
# OUT OF SCOPE — the launch-environment-control boundary (#1443-consistent; see
# lib/bridge-secret-scrub.sh "THREAT MODEL"): startup state the INVOKING shell
# controls that runs BEFORE bridge-lib.sh's first executable line — an
# initial-shell `BASH_ENV`/`ENV` startup file, an inherited `SHELLOPTS=xtrace`
# with a command-substitution `PS4` (Bash evaluates `PS4` before the first
# command), or an invoking-shell DEBUG trap. No pure-Bash code at the
# bridge-lib.sh root can pre-empt these, and they require the attacker to
# control the invoking shell's options/startup on a token-bearing launch — the
# same position as a same-UID attacker who can already scrape `/proc`/the
# filesystem. The harden step below DOES `unset BASH_ENV/ENV/BASH_XTRACEFD` +
# `set +x` + drop `PS4`, so those hooks cannot fire in any CHILD/re-exec the
# bridge forks AFTER hardening — only the initial-shell pre-first-line window
# is out of scope.
#
# The fix closes the window WITHOUT changing the resolved BRIDGE_SCRIPT_DIR
# value or the Bash-upgrade behavior:
#   1. harden hooks FIRST (unset -f interceptor function shadows, unset
#      BASH_ENV/ENV/BASH_XTRACEFD, set +x, drop PS4) — builtin-only, before any
#      fork. This is a no-op for normal operation (the bridge never uses those
#      hooks). The shared primitive (lib/bridge-secret-scrub.sh) provides it.
#   2. compute BRIDGE_SCRIPT_DIR with a BUILTIN parameter expansion
#      (`${BASH_SOURCE[0]%/*}`, no `dirname` fork). `cd -P`/`pwd -P` are
#      builtins, so the canonicalized value is byte-identical to before.
#   3. select the Bash-4+ candidate from HARDCODED-ABSOLUTE paths (+ a single
#      `builtin command -v bash` qualified fallback — `builtin command` cannot
#      resolve to a function shadow), probe each under `-p -c` (PRIVILEGED, not
#      `-lc`: privileged mode imports no environment functions and ignores
#      BASH_ENV/ENV; `-c` is not a login shell so no profile is sourced), and
#      re-exec with `exec "$cand" -p …` so the re-exec'd process is likewise
#      function-free + hook-free.
# bridge-lib.sh itself does NOT capture/scrub the operator's ambient secret env
# (that would change survival semantics for consumers): the steps above defeat
# the exported-function / PATH-shadow classes and the startup-file hooks for the
# CHILD/re-exec processes it forks (BASH_ENV/ENV/BASH_XTRACEFD/PS4 are unset
# before the first fork) — NOT the initial-shell pre-first-line startup window
# (out of scope, see the boundary note above). So the probe/re-exec children —
# which run only our own literal code under `-p` — cannot be hijacked even
# though they inherit the (now-unhookable) env.
# The capture/scrub + nonce-gated fd-transit helpers are PROVIDED by the shared
# primitive for consumers that need them (the #1443/#1452 lanes can adopt them
# in a follow-up); bridge-lib.sh does not wire them onto those consumers here.
#
# Everything in THIS block must be Bash 3.2-safe (it runs on macOS /bin/bash
# 3.2 BEFORE the re-exec). The primitive is written to that bar.

# ---------------------------------------------------------------------------
# SHADOW-PROOF PRE-SOURCE SEED (#1491 / #1454 gap — bootstrap interception).
# ---------------------------------------------------------------------------
# THE GAP this seed closes (codex Phase-4 BLOCKING, proven on the PR head):
# the primitive load below was historically a BARE `source` that ran WHILE an
# exported `source()` (or `.()`) function shadow could still be active. A
# same-UID caller that did
#     source() { printf '%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" >>"$leak"; command source "$@"; }
#     export -f source
# before invoking a bridge entry point would have its shadow run — reading the
# live ambient secret — at the very moment we tried to load the de-fang
# primitive. Hardening (`bridge_secret_scrub_harden_hooks`) only ran AFTER that
# source, so the de-fang primitive itself was loaded through a compromised
# `source`. The re-exec gate was therefore NOT fail-closed against caller-env
# influence.
#
# THE SEED OF TRUST. Every command token a caller could intercept — `builtin`,
# `command`, `source`, `.`, `unset`, `set`, `exec`, `eval` — can be shadowed by
# a same-named exported FUNCTION, and in bash's command lookup a function
# OUTRANKS the builtin of the same name (verified empirically on bash 5.3.9 AND
# the macOS /bin/bash 3.2 pre-re-exec shell: even `builtin unset -f builtin` is
# eaten by a `builtin()` function shadow). So no command-token-based de-fang is
# self-healing on its own.
#
# The one lever a caller CANNOT shadow is a plain VARIABLE ASSIGNMENT — it is
# not a command lookup. Assigning `POSIXLY_CORRECT=1` dynamically activates
# POSIX mode mid-shell, and in POSIX mode the POSIX *special* builtins
# (`unset`, `set`, `export`, `exec`, `eval`, …) OUTRANK same-named function
# shadows. So:
#   1. `POSIXLY_CORRECT=1`     — unshadowable assignment, turns POSIX mode ON.
#   2. `set +T +E` + `trap -`  — kill functrace/errtrace and any DEBUG/RETURN/ERR
#                                trap FIRST, BEFORE the strip. A `set -T` DEBUG
#                                trap fires before every simple command and
#                                could RE-INSTALL a `builtin()`/`source()` shadow
#                                AFTER we unset it; clearing the trap first
#                                guarantees nothing re-shadows post-strip.
#                                (#1491 Phase-4 r2, codex finding 2.)
#   3. `unset -f <names>`      — now the REAL special builtin `unset` (POSIX
#                                mode); strips every interceptor function shadow
#                                (including `source`, `.`, `builtin`, `command`,
#                                `local`, `trap`, and `unset`/`set` themselves).
#   4. `set +o posix`          — restore the historical non-POSIX semantics the
#                                rest of bridge-lib.sh parses/runs under.
#   5. `unset -f <names>` AGAIN — a SECOND strip in non-POSIX mode. On macOS
#                                /bin/bash 3.2, `unset -f .` does NOT remove a
#                                `.()` function while POSIX mode is on, but it
#                                DOES once POSIX mode is off; the second pass
#                                closes that 3.2 quirk. (#1491 Phase-4 r2,
#                                codex finding 3.) `unset` here is the genuine
#                                builtin — its shadow was stripped in step 3 and
#                                the trap can no longer re-install it.
#   6. `unset POSIXLY_CORRECT` — leave no posix-mode residue for children.
# After the strips the genuine `source`/`builtin` builtins are reachable, so the
# primitive load below (now `builtin source`, not a bare `source`) cannot be
# intercepted. This block is pure-bash, builtin-only, no fork, and Bash
# 3.2-safe — it runs on macOS /bin/bash 3.2 BEFORE the re-exec.
#
# `POSIXLY_CORRECT` is a plain (non-exported) shell var here; we unset it again
# in step 6 so it is never inherited by the candidate-probe / re-exec children.
# bridge-lib.sh itself requires non-POSIX mode (it uses arrays + `[[ ]]`), so
# unconditionally landing in `set +o posix` is the correct end state here (the
# shared primitive's harden_hooks, by contrast, restores the caller's exact
# prior POSIX state — see lib/bridge-secret-scrub.sh).
POSIXLY_CORRECT=1
set +T +E 2>/dev/null || true
trap - DEBUG RETURN ERR 2>/dev/null || true
# shellcheck disable=SC2086  # intentional word-split of the name list
unset -f source . unset set export exec eval command builtin printf read echo \
  dirname cd pwd trap local mktemp chmod rm cat readlink true false \
  2>/dev/null || true
set +o posix 2>/dev/null || true
# shellcheck disable=SC2086  # intentional word-split (2nd pass closes the bash-3.2 `unset -f .` quirk)
unset -f source . unset set export exec eval command builtin printf read echo \
  dirname cd pwd trap local mktemp chmod rm cat readlink true false \
  2>/dev/null || true
unset POSIXLY_CORRECT 2>/dev/null || true
# ---------------------------------------------------------------------------

# Derive the primitive's path with a parameter-expansion builtin (NO `dirname`
# command-substitution child — that fork must not run while a secret could be
# live). This mirrors the BRIDGE_SCRIPT_DIR derivation below but only needs the
# directory to source the primitive.
if [[ "${BASH_SOURCE[0]}" == */* ]]; then
  _BRIDGE_LIB_SELF_DIR="${BASH_SOURCE[0]%/*}"
else
  _BRIDGE_LIB_SELF_DIR="."
fi
if [[ -f "$_BRIDGE_LIB_SELF_DIR/lib/bridge-secret-scrub.sh" ]]; then
  # Load via `builtin source` (NOT a bare `source`): the seed above already
  # stripped any `source()`/`.()` function shadow, and `builtin source` cannot
  # resolve to a function shadow even if a residual one survived. So the de-fang
  # primitive is loaded through an un-interceptable path.
  # shellcheck source=lib/bridge-secret-scrub.sh
  builtin source "$_BRIDGE_LIB_SELF_DIR/lib/bridge-secret-scrub.sh"
  bridge_secret_scrub_harden_hooks
else
  # Primitive missing (truncated checkout): fall back to a minimal inline hook
  # scrub so we never regress to running the re-exec with BASH_ENV/ENV live.
  # The seed above already de-fanged the command tokens, so these `builtin`
  # calls reach the genuine builtins.
  builtin unset -f exec source command builtin unset printf read dirname cd pwd \
    2>/dev/null || builtin true
  builtin unset BASH_ENV ENV BASH_XTRACEFD 2>/dev/null || builtin true
  builtin set +x 2>/dev/null || builtin true
  builtin unset PS4 2>/dev/null || builtin true
fi
unset _BRIDGE_LIB_SELF_DIR

# Resolve the re-exec target before any guard logic, since $0 is unreliable
# under macOS /bin/bash invocations like `bash -lc '...' _ args` (where $0
# is the placeholder `_`). Prefer the caller script that sourced us
# (BASH_SOURCE[1] — e.g. bridge-daemon.sh / agent-bridge), fall back to
# bridge-lib.sh itself if invoked directly. (#576 r4 Finding 3)
_BRIDGE_LIB_REEXEC_TARGET="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"

if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  # Re-exec into a Bash 4+ candidate, but ONLY when the resolved target
  # names a regular file we can hand back to the new shell. If the target
  # cannot be resolved (e.g. sourced from `bash -c` with no caller script),
  # fall through to the "requires Bash 4+" message rather than handing the
  # candidate shell a path it cannot open.
  if [[ -f "$_BRIDGE_LIB_REEXEC_TARGET" ]]; then
    # #1454: candidate list is hardcoded-absolute first, then a single
    # `builtin command -v bash` fallback. `builtin command` cannot resolve to
    # an exported function shadow (so a `bash()`/`command()` function cannot
    # hijack the lookup); the absolute paths cannot be function names at all.
    bridge_candidate_bash_fallback="$(builtin command -v bash 2>/dev/null || true)"
    for bridge_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "$bridge_candidate_bash_fallback"; do
      [[ -n "$bridge_candidate_bash" && -x "$bridge_candidate_bash" ]] || continue
      # Probe under `-p -c` (PRIVILEGED + non-login): privileged Bash imports no
      # environment functions and ignores BASH_ENV/ENV, and `-c` (not `-lc`)
      # sources no profile — so the probe child cannot run attacker code while
      # it inherits the env. (The old `-lc` sourced the operator's login
      # profile, which a caller could have planted.)
      if "$bridge_candidate_bash" -p -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        # Re-exec PRIVILEGED so the re-exec'd bridge-lib (and every child it
        # forks) is likewise function-free + BASH_ENV/ENV-free.
        unset bridge_candidate_bash_fallback
        exec "$bridge_candidate_bash" -p "$_BRIDGE_LIB_REEXEC_TARGET" "$@"
      fi
    done
    unset bridge_candidate_bash_fallback
  fi

  echo "[bridge-lib] Agent Bridge requires Bash 4+ (current: ${BASH_VERSION:-unknown}). Re-run with a Bash 4+ shell on PATH (e.g. \`/opt/homebrew/bin/bash <script>\`)." >&2
  exit 1
fi

# Keep bridge-owned runtime files private by default.
umask 077

# #1454: compute BRIDGE_SCRIPT_DIR via a BUILTIN parameter expansion for the
# dirname (no `dirname` fork — that external command must not run where an
# exported-function shadow could intercept it while a secret could be live).
# `cd -P` + `pwd -P` are builtins and preserve the exact symlink-canonicalized
# absolute value the previous `$(dirname …)` form produced. Handle the
# no-slash (`bridge-lib.sh` with no directory) and root-level (`/foo`) cases the
# way `dirname` did: `.` and `/` respectively.
if [[ "${BASH_SOURCE[0]}" == */* ]]; then
  _BRIDGE_SCRIPT_DIR_RAW="${BASH_SOURCE[0]%/*}"
  [[ -n "$_BRIDGE_SCRIPT_DIR_RAW" ]] || _BRIDGE_SCRIPT_DIR_RAW="/"
else
  _BRIDGE_SCRIPT_DIR_RAW="."
fi
BRIDGE_SCRIPT_DIR="$(cd -P "$_BRIDGE_SCRIPT_DIR_RAW" && pwd -P)"
unset _BRIDGE_SCRIPT_DIR_RAW

# Startup validation: if the source checkout that BRIDGE_SCRIPT_DIR resolved
# to has been removed or is incomplete, fail loud and fast rather than fan
# out [Errno 2] failures from every helper invocation. This is the L1 cure
# for the daemon-hang cascade documented in #946 — when a wave-orchestration
# fixer worktree (or upgrade source dir) is cleaned up while a long-lived
# daemon still holds a path captured from BASH_SOURCE[0], every subsequent
# `python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/…"` call fails
# silently. A loud die here lets launchd restart the daemon cleanly and
# surfaces the misconfiguration to the operator.
#
# bridge_die is sourced later (bridge-core.sh) so we cannot call it yet;
# inline a minimal early-die that writes to stderr and exits 1.
if [[ -z "${BRIDGE_SCRIPT_DIR:-}" ]]; then
  echo "[bridge-lib] [error] BRIDGE_SCRIPT_DIR unresolved at startup (BASH_SOURCE[0] returned an empty dirname?)" >&2
  exit 1
fi
if [[ ! -d "$BRIDGE_SCRIPT_DIR" ]]; then
  echo "[bridge-lib] [error] BRIDGE_SCRIPT_DIR=$BRIDGE_SCRIPT_DIR does not exist (source checkout moved or deleted?)" >&2
  exit 1
fi
if [[ ! -d "$BRIDGE_SCRIPT_DIR/scripts/python-helpers" ]]; then
  echo "[bridge-lib] [error] BRIDGE_SCRIPT_DIR=$BRIDGE_SCRIPT_DIR missing scripts/python-helpers/ (incomplete source checkout?)" >&2
  exit 1
fi

bridge_early_ephemeral_tmp_root() {
  local path="${1:-}"
  local tmpdir="${TMPDIR:-}"
  local rest=""
  [[ -n "$path" ]] || return 1
  case "$path" in
    /tmp/tmp.*|/tmp/tmp.*/*)
      rest="${path#/tmp/}"
      printf '/tmp/%s' "${rest%%/*}"
      ;;
    /var/tmp/tmp.*|/var/tmp/tmp.*/*)
      rest="${path#/var/tmp/}"
      printf '/var/tmp/%s' "${rest%%/*}"
      ;;
    /private/tmp/tmp.*|/private/tmp/tmp.*/*)
      rest="${path#/private/tmp/}"
      printf '/private/tmp/%s' "${rest%%/*}"
      ;;
    *)
      if [[ -n "$tmpdir" ]]; then
        tmpdir="${tmpdir%/}"
        case "$path" in
          "$tmpdir"/tmp.*|"$tmpdir"/tmp.*/*)
            rest="${path#"$tmpdir"/}"
            printf '%s/%s' "$tmpdir" "${rest%%/*}"
            ;;
          *)
            return 1
            ;;
        esac
      else
        return 1
      fi
      ;;
  esac
}

bridge_sanitize_stale_ephemeral_controller_env() {
  local name=""
  local value=""
  local root=""
  local -a path_vars=(
    BRIDGE_HOME
    BRIDGE_ROSTER_FILE
    BRIDGE_ROSTER_LOCAL_FILE
    BRIDGE_STATE_DIR
    BRIDGE_LAYOUT_MARKER_DIR
    BRIDGE_ACTIVE_AGENT_DIR
    BRIDGE_HISTORY_DIR
    BRIDGE_WORKTREE_META_DIR
    BRIDGE_ACTIVE_ROSTER_TSV
    BRIDGE_ACTIVE_ROSTER_MD
    BRIDGE_DAEMON_PID_FILE
    BRIDGE_DAEMON_LOG
    BRIDGE_DAEMON_CRASH_LOG
    BRIDGE_TASK_DB
    BRIDGE_PROFILE_STATE_DIR
    BRIDGE_CRON_STATE_DIR
    BRIDGE_CRON_HOME_DIR
    BRIDGE_NATIVE_CRON_JOBS_FILE
    BRIDGE_CRON_DISPATCH_WORKER_DIR
    BRIDGE_WORKTREE_ROOT
    BRIDGE_AGENT_HOME_ROOT
    BRIDGE_RUNTIME_ROOT
    BRIDGE_RUNTIME_SCRIPTS_DIR
    BRIDGE_RUNTIME_SKILLS_DIR
    BRIDGE_RUNTIME_SHARED_DIR
    BRIDGE_RUNTIME_SHARED_TOOLS_DIR
    BRIDGE_RUNTIME_SHARED_REFERENCES_DIR
    BRIDGE_RUNTIME_MEMORY_DIR
    BRIDGE_RUNTIME_CREDENTIALS_DIR
    BRIDGE_RUNTIME_SECRETS_DIR
    BRIDGE_RUNTIME_CONFIG_FILE
    BRIDGE_HOOKS_DIR
    BRIDGE_SHARED_DIR
    BRIDGE_TASK_NOTE_DIR
    BRIDGE_LOG_DIR
    BRIDGE_DATA_ROOT
    BRIDGE_SHARED_ROOT
    BRIDGE_AGENT_ROOT_V2
    BRIDGE_CONTROLLER_STATE_ROOT
    BRIDGE_CLAUDE_CHANNELS_HOME
    BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT
    BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE
  )

  [[ "${BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV:-0}" == "1" ]] && return 0

  for name in "${path_vars[@]}"; do
    value="${!name:-}"
    [[ -n "$value" ]] || continue
    root="$(bridge_early_ephemeral_tmp_root "$value" 2>/dev/null || true)"
    [[ -n "$root" ]] || continue
    [[ -d "$root" ]] && continue
    printf '[bridge-lib] [warn] unsetting stale ephemeral controller env %s=%s (missing root %s)\n' \
      "$name" "$value" "$root" >&2
    unset "$name"
  done
}

bridge_sanitize_stale_ephemeral_controller_env

if [[ -z "${BRIDGE_HOME:-}" ]]; then
  BRIDGE_HOME="$HOME/.agent-bridge"
fi
if [[ -z "${BRIDGE_ROSTER_FILE:-}" ]]; then
  if [[ -f "$BRIDGE_HOME/agent-roster.sh" ]]; then
    BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
  else
    BRIDGE_ROSTER_FILE="$BRIDGE_SCRIPT_DIR/agent-roster.sh"
  fi
fi
BRIDGE_ROSTER_LOCAL_FILE="${BRIDGE_ROSTER_LOCAL_FILE:-$BRIDGE_HOME/agent-roster.local.sh}"
# Issue #1734: dedicated install env-override file written by `agb config
# set-env`. Sourced by bridge_load_roster AFTER the roster so it is a true
# install override, and protected by PROTECTED_GLOBS (lib/system_config_paths.py)
# so it is not a new unprotected sourced shell file.
BRIDGE_AGENT_ENV_LOCAL_FILE="${BRIDGE_AGENT_ENV_LOCAL_FILE:-$BRIDGE_HOME/agent-env.local.sh}"
BRIDGE_STATE_DIR="${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}"
# Layout marker is anchored separately from BRIDGE_STATE_DIR so v2 activation
# never moves marker discovery. Defaults to $BRIDGE_HOME/state and is never
# rebased onto $BRIDGE_DATA_ROOT/state — controller state may relocate in a
# future PR, the marker location must not.
BRIDGE_LAYOUT_MARKER_DIR="${BRIDGE_LAYOUT_MARKER_DIR:-$BRIDGE_HOME/state}"
BRIDGE_ACTIVE_AGENT_DIR="${BRIDGE_ACTIVE_AGENT_DIR:-$BRIDGE_STATE_DIR/agents}"
BRIDGE_HISTORY_DIR="${BRIDGE_HISTORY_DIR:-$BRIDGE_STATE_DIR/history}"
BRIDGE_WORKTREE_META_DIR="${BRIDGE_WORKTREE_META_DIR:-$BRIDGE_STATE_DIR/worktrees}"
BRIDGE_ACTIVE_ROSTER_TSV="${BRIDGE_ACTIVE_ROSTER_TSV:-$BRIDGE_STATE_DIR/active-roster.tsv}"
BRIDGE_ACTIVE_ROSTER_MD="${BRIDGE_ACTIVE_ROSTER_MD:-$BRIDGE_STATE_DIR/active-roster.md}"
# Issue #1473: world-readable (0644) all-agent live-state aggregate the
# daemon (controller UID) publishes each tick so an isolated agent UID —
# which cannot reach the controller's per-UID tmux socket and cannot read
# the 0600 active-roster — can still resolve every agent's active/state in
# `agb agent list`. Carries ONLY non-secret observational fields
# (agent / active / activity_state / updated_at). See lib/bridge-state.sh
# bridge_write_agents_aggregate_state + lib/bridge-agents.sh fallback.
# BRIDGE_AGENTS_AGGREGATE_MAX_AGE_SECONDS (read inline in
# bridge_agents_aggregate_should_consult) bounds how stale the aggregate
# may be before a non-controller reader stops trusting it (daemon-down
# safety); unset → 3× the heartbeat interval, 0 → disable the gate.
BRIDGE_AGENTS_AGGREGATE_TSV="${BRIDGE_AGENTS_AGGREGATE_TSV:-$BRIDGE_STATE_DIR/agents-aggregate.tsv}"
BRIDGE_DAEMON_PID_FILE="${BRIDGE_DAEMON_PID_FILE:-$BRIDGE_STATE_DIR/daemon.pid}"
# Issue #590 / PR #599 r2: prefer the installer-written launchagent.config
# marker so custom --label/--plist/--log-path installs resolve correctly.
# The marker's presence is the "launchd-managed" signal — we don't need
# to guess plist filenames or pin to the default label. Linux (systemd/
# nohup) installs simply lack the marker and fall through to daemon.log.
# Operators can still override BRIDGE_DAEMON_LOG via env.
#
# r3 (PR #599): the marker-read is split into __bridge_resolve_launchagent_log
# so bridge-daemon.sh can reuse the same precedence for BRIDGE_LAUNCHAGENT_LOG
# (otherwise the EXIT-trap append at bridge-daemon.sh:147-151 lands in the
# wrong file on custom --log-path installs).
__bridge_resolve_launchagent_log() {
  local config_path="$BRIDGE_STATE_DIR/launchagent.config"
  if [[ ! -f "$config_path" ]]; then
    printf ''
    return
  fi
  (
    set -e
    # shellcheck disable=SC1090
    source "$config_path"
    printf '%s' "${BRIDGE_LAUNCHAGENT_LOG:-}"
  )
}

__bridge_default_daemon_log() {
  local resolved
  resolved="$(__bridge_resolve_launchagent_log)"
  if [[ -n "$resolved" ]]; then
    printf '%s' "$resolved"
  else
    printf '%s' "$BRIDGE_STATE_DIR/daemon.log"
  fi
}
BRIDGE_DAEMON_LOG="${BRIDGE_DAEMON_LOG:-$(__bridge_default_daemon_log)}"
BRIDGE_DAEMON_CRASH_LOG="${BRIDGE_DAEMON_CRASH_LOG:-$BRIDGE_STATE_DIR/daemon-crash.log}"
BRIDGE_DAEMON_INTERVAL="${BRIDGE_DAEMON_INTERVAL:-5}"
BRIDGE_DAEMON_START_WAIT_SECONDS="${BRIDGE_DAEMON_START_WAIT_SECONDS:-3}"
BRIDGE_TASK_DB="${BRIDGE_TASK_DB:-$BRIDGE_STATE_DIR/tasks.db}"
BRIDGE_PROFILE_STATE_DIR="${BRIDGE_PROFILE_STATE_DIR:-$BRIDGE_STATE_DIR/profiles}"
BRIDGE_CRON_STATE_DIR="${BRIDGE_CRON_STATE_DIR:-$BRIDGE_STATE_DIR/cron}"
BRIDGE_CRON_HOME_DIR="${BRIDGE_CRON_HOME_DIR:-$BRIDGE_HOME/cron}"
BRIDGE_NATIVE_CRON_JOBS_FILE="${BRIDGE_NATIVE_CRON_JOBS_FILE:-$BRIDGE_CRON_HOME_DIR/jobs.json}"
BRIDGE_CRON_DISPATCH_WORKER_DIR="${BRIDGE_CRON_DISPATCH_WORKER_DIR:-$BRIDGE_CRON_STATE_DIR/workers}"
# Issue #1359 tactical staging delegation for iso v2 `agb cron create`.
# Iso UIDs cannot write to `BRIDGE_NATIVE_CRON_JOBS_FILE` (controller-owned
# mode 0640) so they drop a JSON mutation request into this directory at
# mode 0660 owner=iso group=ab-shared. The daemon's cron-sync tick picks
# them up, validates the caller identity (actor_agent==filename agent
# AND file owner UID matches actor_agent's iso UID), applies via
# `bridge-cron.py native-create`, and writes a result.json sibling. See
# `lib/cron-helpers/staging.py` for the wire schema.
BRIDGE_CRON_STAGING_DIR="${BRIDGE_CRON_STAGING_DIR:-$BRIDGE_STATE_DIR/cron-staging}"
BRIDGE_CRON_STAGING_TIMEOUT_SECONDS="${BRIDGE_CRON_STAGING_TIMEOUT_SECONDS:-30}"
BRIDGE_CRON_STAGING_POLL_INTERVAL_SECONDS="${BRIDGE_CRON_STAGING_POLL_INTERVAL_SECONDS:-1}"
BRIDGE_CRON_STAGING_STALE_SECONDS="${BRIDGE_CRON_STAGING_STALE_SECONDS:-300}"
# codex r1 #3: daemon-side per-file apply timeout. A wedged
# `bridge-cron.py native-create` subprocess (FIFO payload-file,
# slow disk) would otherwise stall the cron-sync tick. Default 25s
# leaves headroom under the cron_sync_timeout (default 30s).
BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS="${BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS:-25}"
# cron-dispatch worker-pool size resolution (issue #1461). Precedence, in
# order, highest wins:
#
#   1. BRIDGE_CRON_DISPATCH_MAX_PARALLEL env (explicit operator override —
#      e.g. the daemon LaunchAgent/systemd unit env, or an exported value).
#   2. `cron_dispatch_max_parallel` in the runtime bridge-config.json — the
#      sanctioned, audit-chained, upgrade-safe path. Set it with
#      `agb config set --path runtime/bridge-config.json
#        --change cron_dispatch_max_parallel=<N>`. `agb config set` refuses
#      the `.sh` roster (it cannot shell-parse it safely), so this JSON key
#      is the only tunable an operator can set through sanctioned tooling.
#   3. Host-profile-scaled default: profile=server hosts (the cron-heavy
#      case the issue reports) get 3; dev / small-RAM / unknown hosts keep
#      the conservative serial 1 baseline from issue #579.
#
# The resolution must happen AFTER BRIDGE_RUNTIME_CONFIG_FILE is resolved
# (below), so the actual assignment is deferred until then; only the helper
# is defined here. Precedence 2 (JSON config) + 3 (host-profile default) live
# in a standalone file-as-argv python helper rather than an inline heredoc —
# heredoc-stdin to a subprocess is the Bash 5.3.9 footgun #11 deadlock class
# this repo bans (see KNOWN_ISSUES.md §26 / lint-heredoc-ban). The helper is
# callable at lib-load time (BRIDGE_SCRIPT_DIR / scripts/python-helpers are
# validated earlier in this file).
bridge_resolve_cron_dispatch_max_parallel() {
  # 1. Explicit env override wins outright (when it is a positive integer).
  local env_val="${BRIDGE_CRON_DISPATCH_MAX_PARALLEL:-}"
  if [[ "$env_val" =~ ^[0-9]+$ ]] && (( 10#$env_val >= 1 )); then
    printf '%s' "$env_val"
    return 0
  fi

  command -v python3 >/dev/null 2>&1 || { printf '1'; return 0; }

  local config_file="${BRIDGE_RUNTIME_CONFIG_FILE:-}"
  local host_profile_file=""
  if [[ -n "${BRIDGE_HOME:-}" && -f "$BRIDGE_HOME/state/install/host-profile.json" ]]; then
    host_profile_file="$BRIDGE_HOME/state/install/host-profile.json"
  elif [[ -n "${BRIDGE_STATE_DIR:-}" && -f "$BRIDGE_STATE_DIR/install/host-profile.json" ]]; then
    host_profile_file="$BRIDGE_STATE_DIR/install/host-profile.json"
  fi

  # 2. runtime config key, then 3. host-profile-scaled default. The helper
  # never raises — any read error / missing file falls through to the
  # serial-1 floor — so a guard here keeps the resolver from emitting empty.
  local resolved=""
  resolved="$(python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/resolve-cron-max-parallel.py" \
    "$config_file" "$host_profile_file" 2>/dev/null || true)"
  if [[ "$resolved" =~ ^[0-9]+$ ]] && (( 10#$resolved >= 1 )); then
    printf '%s' "$resolved"
  else
    printf '1'
  fi
}
BRIDGE_CRON_DISPATCH_LEASE_SECONDS="${BRIDGE_CRON_DISPATCH_LEASE_SECONDS:-7200}"
# Issue #1459 — cron-dispatch backlog/reconcile knobs.
#   BACKLOG_THRESHOLD_SECONDS: a queued [cron-dispatch] row older than this
#     while workers are saturated emits a cron_dispatch_backlog audit row.
#   BACKLOG_COOLDOWN_SECONDS: re-emit window per (oldest_task_id, reason)
#     marker so a sustained backlog does not spam every daemon tick.
#   RECONCILE_GRACE_SECONDS: how long a non-terminal run may sit without
#     worker evidence before the reconciler declares it lost (defaults to
#     the dispatch lease in bridge-cron.sh sync).
BRIDGE_CRON_DISPATCH_BACKLOG_THRESHOLD_SECONDS="${BRIDGE_CRON_DISPATCH_BACKLOG_THRESHOLD_SECONDS:-300}"
BRIDGE_CRON_DISPATCH_BACKLOG_COOLDOWN_SECONDS="${BRIDGE_CRON_DISPATCH_BACKLOG_COOLDOWN_SECONDS:-1800}"
BRIDGE_WORKTREE_ROOT="${BRIDGE_WORKTREE_ROOT:-$HOME/.agent-bridge/worktrees}"
BRIDGE_AGENT_HOME_ROOT="${BRIDGE_AGENT_HOME_ROOT:-$BRIDGE_HOME/agents}"
BRIDGE_RUNTIME_ROOT="${BRIDGE_RUNTIME_ROOT:-$BRIDGE_HOME/runtime}"
BRIDGE_RUNTIME_SCRIPTS_DIR="${BRIDGE_RUNTIME_SCRIPTS_DIR:-$BRIDGE_RUNTIME_ROOT/scripts}"
BRIDGE_RUNTIME_SKILLS_DIR="${BRIDGE_RUNTIME_SKILLS_DIR:-$BRIDGE_RUNTIME_ROOT/skills}"
BRIDGE_RUNTIME_SHARED_DIR="${BRIDGE_RUNTIME_SHARED_DIR:-$BRIDGE_RUNTIME_ROOT/shared}"
BRIDGE_RUNTIME_SHARED_TOOLS_DIR="${BRIDGE_RUNTIME_SHARED_TOOLS_DIR:-$BRIDGE_RUNTIME_SHARED_DIR/tools}"
BRIDGE_RUNTIME_SHARED_REFERENCES_DIR="${BRIDGE_RUNTIME_SHARED_REFERENCES_DIR:-$BRIDGE_RUNTIME_SHARED_DIR/references}"
BRIDGE_RUNTIME_MEMORY_DIR="${BRIDGE_RUNTIME_MEMORY_DIR:-$BRIDGE_RUNTIME_ROOT/memory}"
BRIDGE_RUNTIME_CREDENTIALS_DIR="${BRIDGE_RUNTIME_CREDENTIALS_DIR:-$BRIDGE_RUNTIME_ROOT/credentials}"
BRIDGE_RUNTIME_SECRETS_DIR="${BRIDGE_RUNTIME_SECRETS_DIR:-$BRIDGE_RUNTIME_ROOT/secrets}"
BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="${BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT:-/home}"
if [[ -z "${BRIDGE_RUNTIME_CONFIG_FILE:-}" ]]; then
  if [[ -f "$BRIDGE_RUNTIME_ROOT/bridge-config.json" ]]; then
    BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/bridge-config.json"
  elif [[ -f "$BRIDGE_RUNTIME_ROOT/openclaw.json" ]]; then
    BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/openclaw.json"
  else
    BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/bridge-config.json"
  fi
fi
# Resolve cron-dispatch worker-pool size now that BRIDGE_RUNTIME_CONFIG_FILE
# is known (issue #1461). See bridge_resolve_cron_dispatch_max_parallel above
# for the env > JSON-config > host-profile precedence. The result is exported
# below so the daemon's start_cron_dispatch_workers reads the resolved value.
BRIDGE_CRON_DISPATCH_MAX_PARALLEL="$(bridge_resolve_cron_dispatch_max_parallel)"
BRIDGE_GATEWAY_TRANSPORT="${BRIDGE_GATEWAY_TRANSPORT:-file}"
BRIDGE_GATEWAY_LISTENER="${BRIDGE_GATEWAY_LISTENER:-auto}"
BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT="${BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT:-/run/agent-bridge}"
BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS="${BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS:-5}"
BRIDGE_TMPFILES_DIR="${BRIDGE_TMPFILES_DIR:-/etc/tmpfiles.d}"
BRIDGE_TMPFILES_DRIVER="${BRIDGE_TMPFILES_DRIVER:-systemd-tmpfiles}"
BRIDGE_HOOKS_DIR="${BRIDGE_HOOKS_DIR:-$BRIDGE_HOME/hooks}"
BRIDGE_CHANNEL_SERVER_NAME="${BRIDGE_CHANNEL_SERVER_NAME:-bridge-webhook}"
BRIDGE_WEBHOOK_PORT_RANGE_START="${BRIDGE_WEBHOOK_PORT_RANGE_START:-9101}"
BRIDGE_WEBHOOK_PORT_RANGE_END="${BRIDGE_WEBHOOK_PORT_RANGE_END:-9199}"
BRIDGE_CLAUDE_IDLE_FALLBACK_SECONDS="${BRIDGE_CLAUDE_IDLE_FALLBACK_SECONDS:-300}"
BRIDGE_DASHBOARD_WEBHOOK_URL="${BRIDGE_DASHBOARD_WEBHOOK_URL:-}"
BRIDGE_DASHBOARD_STATE_FILE="${BRIDGE_DASHBOARD_STATE_FILE:-$BRIDGE_STATE_DIR/dashboard.json}"
BRIDGE_DASHBOARD_IDLE_SECONDS="${BRIDGE_DASHBOARD_IDLE_SECONDS:-900}"
BRIDGE_DASHBOARD_SUMMARY_SECONDS="${BRIDGE_DASHBOARD_SUMMARY_SECONDS:-3600}"
BRIDGE_LEGACY_HOME="${BRIDGE_LEGACY_HOME:-${BRIDGE_OPENCLAW_HOME:-$HOME/.openclaw}}"
BRIDGE_SOURCE_CRON_JOBS_FILE="${BRIDGE_SOURCE_CRON_JOBS_FILE:-${BRIDGE_OPENCLAW_CRON_JOBS_FILE:-$BRIDGE_LEGACY_HOME/cron/jobs.json}}"
BRIDGE_OPENCLAW_HOME="${BRIDGE_OPENCLAW_HOME:-$BRIDGE_LEGACY_HOME}"
BRIDGE_OPENCLAW_CRON_JOBS_FILE="${BRIDGE_OPENCLAW_CRON_JOBS_FILE:-$BRIDGE_SOURCE_CRON_JOBS_FILE}"
BRIDGE_DISCORD_RELAY_STATE_FILE="${BRIDGE_DISCORD_RELAY_STATE_FILE:-$BRIDGE_STATE_DIR/discord-relay.json}"
BRIDGE_DAEMON_LAUNCHAGENT_LABEL="${BRIDGE_DAEMON_LAUNCHAGENT_LABEL:-ai.agent-bridge.daemon}"
BRIDGE_DAEMON_LAUNCHAGENT_PLIST="${BRIDGE_DAEMON_LAUNCHAGENT_PLIST:-$HOME/Library/LaunchAgents/$BRIDGE_DAEMON_LAUNCHAGENT_LABEL.plist}"
BRIDGE_TMUX_PROMPT_WAIT_SECONDS="${BRIDGE_TMUX_PROMPT_WAIT_SECONDS:-2}"
BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED="${BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED:-1}"
BRIDGE_MCP_ORPHAN_CLEANUP_INTERVAL_SECONDS="${BRIDGE_MCP_ORPHAN_CLEANUP_INTERVAL_SECONDS:-300}"
BRIDGE_MCP_ORPHAN_MIN_AGE_SECONDS="${BRIDGE_MCP_ORPHAN_MIN_AGE_SECONDS:-300}"
BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS="${BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS:-0}"
BRIDGE_MCP_ORPHAN_NOTIFY_THRESHOLD="${BRIDGE_MCP_ORPHAN_NOTIFY_THRESHOLD:-10}"
BRIDGE_MCP_ORPHAN_PATTERNS="${BRIDGE_MCP_ORPHAN_PATTERNS:-}"
BRIDGE_BASH_BIN="${BRIDGE_BASH_BIN:-${BASH:-$(command -v bash)}}"
export BRIDGE_BASH_BIN
export BRIDGE_HOME BRIDGE_ROSTER_FILE BRIDGE_ROSTER_LOCAL_FILE
export BRIDGE_STATE_DIR BRIDGE_LAYOUT_MARKER_DIR BRIDGE_ACTIVE_AGENT_DIR BRIDGE_HISTORY_DIR BRIDGE_WORKTREE_META_DIR
export BRIDGE_ACTIVE_ROSTER_TSV BRIDGE_ACTIVE_ROSTER_MD
export BRIDGE_DAEMON_PID_FILE BRIDGE_DAEMON_LOG BRIDGE_DAEMON_CRASH_LOG
export BRIDGE_DAEMON_INTERVAL BRIDGE_DAEMON_START_WAIT_SECONDS
export BRIDGE_TASK_DB BRIDGE_PROFILE_STATE_DIR BRIDGE_CRON_STATE_DIR BRIDGE_CRON_HOME_DIR BRIDGE_NATIVE_CRON_JOBS_FILE
export BRIDGE_CRON_DISPATCH_WORKER_DIR BRIDGE_CRON_DISPATCH_MAX_PARALLEL BRIDGE_CRON_DISPATCH_LEASE_SECONDS
export BRIDGE_CRON_DISPATCH_BACKLOG_THRESHOLD_SECONDS BRIDGE_CRON_DISPATCH_BACKLOG_COOLDOWN_SECONDS
export BRIDGE_CRON_STAGING_DIR BRIDGE_CRON_STAGING_TIMEOUT_SECONDS BRIDGE_CRON_STAGING_POLL_INTERVAL_SECONDS BRIDGE_CRON_STAGING_STALE_SECONDS BRIDGE_CRON_STAGING_APPLY_TIMEOUT_SECONDS
export BRIDGE_WORKTREE_ROOT BRIDGE_AGENT_HOME_ROOT
export BRIDGE_RUNTIME_ROOT BRIDGE_RUNTIME_SCRIPTS_DIR BRIDGE_RUNTIME_SKILLS_DIR
export BRIDGE_RUNTIME_SHARED_DIR BRIDGE_RUNTIME_SHARED_TOOLS_DIR BRIDGE_RUNTIME_SHARED_REFERENCES_DIR BRIDGE_RUNTIME_MEMORY_DIR
export BRIDGE_RUNTIME_CREDENTIALS_DIR BRIDGE_RUNTIME_SECRETS_DIR BRIDGE_RUNTIME_CONFIG_FILE
export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT
export BRIDGE_GATEWAY_TRANSPORT BRIDGE_GATEWAY_LISTENER BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT
export BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS BRIDGE_TMPFILES_DIR BRIDGE_TMPFILES_DRIVER
export BRIDGE_HOOKS_DIR
export BRIDGE_CHANNEL_SERVER_NAME BRIDGE_WEBHOOK_PORT_RANGE_START BRIDGE_WEBHOOK_PORT_RANGE_END
export BRIDGE_CLAUDE_IDLE_FALLBACK_SECONDS
export BRIDGE_DASHBOARD_WEBHOOK_URL BRIDGE_DASHBOARD_STATE_FILE
export BRIDGE_LEGACY_HOME BRIDGE_SOURCE_CRON_JOBS_FILE BRIDGE_OPENCLAW_HOME BRIDGE_OPENCLAW_CRON_JOBS_FILE
export BRIDGE_DISCORD_RELAY_STATE_FILE BRIDGE_DAEMON_LAUNCHAGENT_LABEL BRIDGE_DAEMON_LAUNCHAGENT_PLIST
export BRIDGE_TMUX_PROMPT_WAIT_SECONDS
export BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED BRIDGE_MCP_ORPHAN_CLEANUP_INTERVAL_SECONDS BRIDGE_MCP_ORPHAN_MIN_AGE_SECONDS
export BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS BRIDGE_MCP_ORPHAN_NOTIFY_THRESHOLD BRIDGE_MCP_ORPHAN_PATTERNS

bridge_bool_is_true() {
  local value="${1:-}"
  value="${value,,}"
  case "$value" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

bridge_runtime_config_value() {
  local key="$1"
  [[ -n "$key" && -f "${BRIDGE_RUNTIME_CONFIG_FILE:-}" ]] || return 1
  python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/read-json-key.py" \
    "$BRIDGE_RUNTIME_CONFIG_FILE" "$key" 2>/dev/null
}

bridge_config_bool_enabled() {
  local key="$1"
  local value=""
  value="$(bridge_runtime_config_value "$key" 2>/dev/null || true)"
  bridge_bool_is_true "$value"
}

bridge_claude_keychain_free_auth_enabled() {
  if [[ -n "${BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH:-}" ]]; then
    bridge_bool_is_true "$BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH"
    return $?
  fi
  bridge_config_bool_enabled "claude_keychain_free_auth"
}

bridge_claude_api_key_helper_path() {
  local path=""
  if [[ -n "${BRIDGE_CLAUDE_API_KEY_HELPER:-}" ]]; then
    path="$BRIDGE_CLAUDE_API_KEY_HELPER"
  else
    path="$(bridge_runtime_config_value "claude_api_key_helper" 2>/dev/null || true)"
    [[ -n "$path" ]] || path="$BRIDGE_SCRIPT_DIR/scripts/claude-oat-api-key-helper.sh"
  fi
  case "$path" in
    /*) printf '%s' "$path" ;;
    *) printf '%s/%s' "$BRIDGE_SCRIPT_DIR" "$path" ;;
  esac
}

bridge_claude_token_registry_path() {
  printf '%s' "${BRIDGE_CLAUDE_TOKEN_REGISTRY:-$BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json}"
}

bridge_claude_api_key_helper_ttl_ms() {
  local value="${BRIDGE_CLAUDE_API_KEY_HELPER_TTL_MS:-}"
  if [[ -z "$value" ]]; then
    value="$(bridge_runtime_config_value "claude_api_key_helper_ttl_ms" 2>/dev/null || true)"
  fi
  if [[ "$value" =~ ^[0-9]+$ ]] && (( 10#$value > 0 )); then
    printf '%s' "$value"
  else
    printf '%s' "60000"
  fi
}

bridge_prepend_path_entry() {
  local entry="$1"
  [[ -n "$entry" ]] || return 0
  [[ -d "$entry" ]] || return 0
  case ":$PATH:" in
    *":$entry:"*) ;;
    *) PATH="$entry${PATH:+:$PATH}" ;;
  esac
}

# Issue #1352 (beta5-3 Track K, codex r1 BLOCKING): true iff the given
# directory holds an executable engine CLI (`codex` or `claude`). nvm
# multi-version installs commonly leave several `versions/node/<v>/bin`
# dirs where only the version the operator `npm i -g`'d into actually has
# the engine; prepending an engine-less dir is a false fix (PATH grows but
# `command -v codex` stays empty → exit 127 persists). bridge-lib.sh runs
# this at lib-load time before we know which engine the launching agent
# uses, so either binary qualifies a candidate.
bridge_dir_has_engine_cli() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] || return 1
  [[ -x "$dir/codex" || -x "$dir/claude" ]]
}

bridge_prepend_path_entry "$HOME/.local/bin"
bridge_prepend_path_entry "$HOME/.nix-profile/bin"
bridge_prepend_path_entry "$HOME/bin"
bridge_prepend_path_entry "/opt/homebrew/bin"
bridge_prepend_path_entry "/usr/local/bin"

# Issue #1317-A (beta5-2 Lane ν): daemon non-login shells miss nvm/pyenv
# /rbenv/fnm/asdf PATH entries because operator shellrc init is skipped.
# Without these, an nvm-installed `codex` (`~/.nvm/versions/node/vX/bin/`)
# is not on the daemon's PATH, `bridge-start.sh` launch dies with
# `codex: command not found` (exit 127), the rapid-fail circuit breaker
# writes `broken-launch`, and the operator sees only `activity_state:
# stopped` with no hint why.
#
# Strategy: hybrid override + auto-detect.
#   1. BRIDGE_ENGINE_PATH (highest priority): colon-separated list of
#      directories the operator explicitly wants on the daemon PATH.
#      Each entry is prepended via bridge_prepend_path_entry so order is
#      preserved and missing dirs are skipped.
#   2. Auto-detect runtime managers from common env hints + canonical
#      install paths:
#        - $NVM_DIR/versions/node/<latest>/bin
#        - $PYENV_ROOT/shims  ($PYENV_ROOT/bin already covered via shims
#          for `pyenv` itself; shims is the path that exposes pyenv-
#          managed Python)
#        - $RBENV_ROOT/shims
#        - ASDF_DATA_DIR (and ~/.asdf) shims
#        - fnm: $FNM_DIR/aliases/default/bin OR canonical
#          ~/.local/share/fnm/aliases/default/bin
#
# All checks are best-effort: missing env vars, missing dirs, or missing
# `versions/node/<latest>` symlink targets fall through silently. This
# function is idempotent (re-sourcing bridge-lib.sh is a no-op).
bridge_augment_engine_path() {
  local _entry=""
  local _override_path="${BRIDGE_ENGINE_PATH:-}"

  # 1. Operator override (highest priority — prepended last so it ends up
  # at the front of PATH after all auto-detect entries are prepended).
  # We iterate auto-detect first, then operator override last so the
  # override wins.

  # 2. Auto-detect — nvm
  #
  # Issue #1352 (beta5-3 Track K): unlike pyenv/rbenv/asdf/fnm below, nvm
  # only exports $NVM_DIR from the operator's shellrc (`nvm.sh` sources it
  # in a login/interactive shell). The daemon — and therefore every
  # bridge-start.sh / bridge-run.sh launch it spawns, shared OR iso — runs
  # in a systemd-user non-login shell where $NVM_DIR is unset, so the
  # auto-detect below was a no-op and the canonical default install
  # ($HOME/.nvm/versions/node/vX/bin/codex) never reached the launch PATH.
  # That left `bridge_resolve_engine_binary` (= `command -v codex`)
  # returning empty → BRIDGE_ENGINE_BIN unset → no launch-cmd token rewrite
  # → bare `codex` → exit 127 on the auto-provisioned <admin>-dev codex
  # pair (isolation_mode: shared). Mirror the canonical-fallback pattern
  # the other managers already use so a default nvm install resolves
  # without the operator having to export $NVM_DIR for the daemon.
  local _nvm_root="${NVM_DIR:-}"
  if [[ -z "$_nvm_root" && -d "$HOME/.nvm/versions/node" ]]; then
    _nvm_root="$HOME/.nvm"
  fi
  if [[ -n "$_nvm_root" && -d "$_nvm_root/versions/node" ]]; then
    # Selection contract (codex r1 BLOCKING fixes):
    #   1. semver-aware ordering — `sort -V`, NEVER lexicographic. A
    #      lexicographic `sort` ranks `v9.99.0` after `v24.16.0`, so the
    #      "latest" fallback would pick a stale/wrong version.
    #   2. engine-presence — only a `versions/node/<v>/bin` dir that
    #      actually holds `codex`/`claude` is a candidate. A multi-version
    #      install where the engine lives in just one version dir must not
    #      have an engine-less dir prepended (that grows PATH but leaves
    #      `command -v codex` empty → exit 127 persists).
    # Priority: the `nvm alias default` version IF its bin has an engine;
    # otherwise the highest-semver engine-bearing version; otherwise no
    # prepend (graceful — never a false positive).
    local _nvm_default_alias=""
    if [[ -r "$_nvm_root/alias/default" ]]; then
      _nvm_default_alias="$(cat "$_nvm_root/alias/default" 2>/dev/null || true)"
      _nvm_default_alias="${_nvm_default_alias#v}"
    fi
    local _nvm_chosen_bin=""
    if [[ -n "$_nvm_default_alias" ]] \
        && bridge_dir_has_engine_cli "$_nvm_root/versions/node/v$_nvm_default_alias/bin"; then
      _nvm_chosen_bin="$_nvm_root/versions/node/v$_nvm_default_alias/bin"
    else
      # Highest-semver engine-bearing version dir. List version dir names,
      # sort -V (version sort) descending, and take the first whose bin
      # holds an engine CLI. `ls -1v` is not portable to macOS BSD ls, but
      # `sort -V` is available on both GNU coreutils and BSD/macOS sort.
      #
      # Footgun #11 (lint-heredoc-ban H3): the version list is staged into a
      # tempfile read via plain `< "$_tmpf"` rather than a `< <(...)`
      # process substitution — the project bans `< <(`, `<<<`, and
      # heredoc-stdin (Bash 5.3.9 read_comsub/heredoc_write deadlock class).
      # The tempfile is removed immediately after the loop.
      local _nvm_ver="" _nvm_verfile=""
      _nvm_verfile="$(mktemp 2>/dev/null || true)"
      if [[ -n "$_nvm_verfile" ]]; then
        # shellcheck disable=SC2012  # nvm version dirs are predictable
        # `v24.16.0`-style names; ls + sort -V is intentional (find -printf
        # is non-portable on macOS BSD find).
        ls -1 "$_nvm_root/versions/node" 2>/dev/null | sort -Vr >"$_nvm_verfile"
        while IFS= read -r _nvm_ver; do
          [[ -n "$_nvm_ver" ]] || continue
          if bridge_dir_has_engine_cli "$_nvm_root/versions/node/$_nvm_ver/bin"; then
            _nvm_chosen_bin="$_nvm_root/versions/node/$_nvm_ver/bin"
            break
          fi
        done <"$_nvm_verfile"
        rm -f "$_nvm_verfile"
      fi
    fi
    if [[ -n "$_nvm_chosen_bin" ]]; then
      bridge_prepend_path_entry "$_nvm_chosen_bin"
    fi
  fi

  # 3. Auto-detect — pyenv
  if [[ -n "${PYENV_ROOT:-}" ]]; then
    bridge_prepend_path_entry "$PYENV_ROOT/shims"
    bridge_prepend_path_entry "$PYENV_ROOT/bin"
  elif [[ -d "$HOME/.pyenv" ]]; then
    bridge_prepend_path_entry "$HOME/.pyenv/shims"
    bridge_prepend_path_entry "$HOME/.pyenv/bin"
  fi

  # 4. Auto-detect — rbenv
  if [[ -n "${RBENV_ROOT:-}" ]]; then
    bridge_prepend_path_entry "$RBENV_ROOT/shims"
    bridge_prepend_path_entry "$RBENV_ROOT/bin"
  elif [[ -d "$HOME/.rbenv" ]]; then
    bridge_prepend_path_entry "$HOME/.rbenv/shims"
    bridge_prepend_path_entry "$HOME/.rbenv/bin"
  fi

  # 5. Auto-detect — asdf (legacy `.asdf` and current `ASDF_DATA_DIR`)
  if [[ -n "${ASDF_DATA_DIR:-}" ]]; then
    bridge_prepend_path_entry "$ASDF_DATA_DIR/shims"
  fi
  if [[ -d "$HOME/.asdf/shims" ]]; then
    bridge_prepend_path_entry "$HOME/.asdf/shims"
  fi

  # 6. Auto-detect — fnm
  if [[ -n "${FNM_DIR:-}" ]]; then
    bridge_prepend_path_entry "$FNM_DIR/aliases/default/bin"
  elif [[ -d "$HOME/.local/share/fnm/aliases/default/bin" ]]; then
    bridge_prepend_path_entry "$HOME/.local/share/fnm/aliases/default/bin"
  fi

  # 7. Auto-detect — volta (issue #1352: same daemon non-login-shell gap as
  # nvm — $VOLTA_HOME is only exported by the operator's shellrc, so honor
  # it when set and fall back to the canonical $HOME/.volta/bin install dir
  # the daemon can find without it).
  if [[ -n "${VOLTA_HOME:-}" && -d "$VOLTA_HOME/bin" ]]; then
    bridge_prepend_path_entry "$VOLTA_HOME/bin"
  elif [[ -d "$HOME/.volta/bin" ]]; then
    bridge_prepend_path_entry "$HOME/.volta/bin"
  fi

  # 8. Operator override last (becomes leftmost on PATH).
  if [[ -n "$_override_path" ]]; then
    # Honor colon-separated multi-dir overrides. Iterate from last to
    # first so the first entry in BRIDGE_ENGINE_PATH ends up leftmost
    # after all prepends.
    local _entries=()
    local IFS_save="$IFS"
    IFS=':'
    # shellcheck disable=SC2206
    _entries=( $_override_path )
    IFS="$IFS_save"
    local _i
    for (( _i=${#_entries[@]}-1; _i>=0; _i-- )); do
      _entry="${_entries[$_i]}"
      [[ -n "$_entry" ]] || continue
      bridge_prepend_path_entry "$_entry"
    done
  fi
}

bridge_augment_engine_path

export PATH

RED='\033[0;31m'
# shellcheck disable=SC2034
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BRIDGE_MANAGED_MARKER="Managed by agent-bridge. Regenerated by agent-bridge."

bridge_source_module() {
  local module="$1"
  local path="$BRIDGE_SCRIPT_DIR/lib/$module"

  if [[ ! -f "$path" ]]; then
    echo "[bridge-lib] missing module: $path" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$path"
}

bridge_source_module "bridge-session-patterns.sh"
bridge_source_module "bridge-core.sh"
# Read the v2 layout marker (state/layout-marker.sh) before any module
# snapshots BRIDGE_LAYOUT/BRIDGE_DATA_ROOT. Sourced after bridge-core.sh
# so bridge_warn is available, before bridge-agents.sh / bridge-isolation-v2.sh
# so v2 helpers see the marker values. Safe no-op when the marker is absent.
bridge_source_module "bridge-marker-bootstrap.sh"
# Resolve layout (env / marker / missing-marker(existing) / fresh-install-
# candidate / invalid-marker(fallback)) before bridge-agents.sh snapshots
# child env defaults. Read-only — never writes the marker.
bridge_source_module "bridge-layout-resolver.sh"
bridge_source_module "bridge-agents.sh"
# Issue #832: small probes for running a snippet as the isolated UID of a
# linux-user-isolated agent. Sourced after bridge-agents.sh because the
# helpers depend on bridge_agent_os_user /
# bridge_agent_linux_user_isolation_effective.
bridge_source_module "bridge-isolation-helpers.sh"
bridge_source_module "bridge-guard.sh"
bridge_source_module "bridge-tmux.sh"
bridge_source_module "bridge-skills.sh"
bridge_source_module "bridge-hooks.sh"
bridge_source_module "bridge-channels.sh"
bridge_source_module "bridge-state.sh"
# Issue #1762: no-LLM picker auto-resolve stage. Sourced after bridge-tmux.sh
# (it drives every keystroke through that layer's primitives) and
# bridge-state.sh (bridge_with_timeout). Function-name resolution is at call
# time, so this placement only needs to land before the daemon tick runs.
bridge_source_module "bridge-picker.sh"
# S3 (v0.14.x stabilization): platform discriminator. Sourced BEFORE
# bridge-isolation-v2.sh so the v2 module's Bucket 2 enforcement
# gates can call `bridge_isolation_v2_enforce`. Depends on
# bridge_host_platform from bridge-agents.sh (sourced above).
bridge_source_module "bridge-isolation-discriminator.sh"
bridge_source_module "bridge-isolation-v2.sh"
# r12 codex catch (#782) — bridge-isolation-v2-reapply.sh defines
# `bridge_isolation_v2_reapply_eligible_agents`, which the v2 matrix
# apply/check helpers in bridge-isolation-v2.sh need at runtime to
# enumerate the isolated-agent roster. Without it, code paths that
# don't transit bridge-migrate.sh (notably bridge-upgrade.sh's apply
# subprocess and bridge-start.sh's prepare_agent_isolation) silently
# fall back to single-agent behavior and strip other roster agents'
# credential grants during upgrade. Source it here so every entry
# point sees the helper.
bridge_source_module "bridge-isolation-v2-reapply.sh"
# Phase 2 (post-v0.14.5-beta16): declarative install-tree reconciler.
# Sourced AFTER bridge-isolation-v2-reapply.sh because
# `apply_install_tree_matrix --all-agents` defers to
# `bridge_isolation_v2_reapply_eligible_agents` to enumerate the
# isolated roster. Sourced BEFORE bridge-isolation-v3-channel-dotenv.sh
# (no dependency) so the load order stays grouped under the v2 family.
bridge_source_module "bridge-isolation-v2-reconcile.sh"
# #857 PR-6 (v0.13.4): channel-dotenv migrator. Depends on v2-reapply
# primitives (record_action / run_priv / has_named_acl /
# probe_owner_group_mode / chown_chmod_file) — source after v2-reapply.
bridge_source_module "bridge-isolation-v3-channel-dotenv.sh"
# v0.8.0 T5: runtime-only `BRIDGE_DISABLE_ISOLATION=1` escape hatch.
# Sourced after bridge-isolation-v2.sh so bridge_isolation_v2_active is
# already defined (the runtime state helper composes the two).
bridge_source_module "bridge-isolation-runtime.sh"
bridge_source_module "bridge-profiles.sh"
# Issue #1060: typed agent-layout resolver + minimal engine descriptor.
# Sourced after bridge-agents.sh (the resolver wraps
# `bridge_agent_default_home` / `bridge_agent_workdir`) and
# bridge-profiles.sh (the profile-source layer wraps
# `bridge_profile_source_root`). The descriptor depends on the layout
# resolver for workspace/home resolution, so it loads second.
bridge_source_module "bridge-agent-layout.sh"
bridge_source_module "bridge-engine-descriptor.sh"
bridge_source_module "bridge-cron.sh"
# Incident #8807 P0a: resource-guard reuses bridge-cron.sh's
# bridge_check_memory_pressure, so it must source AFTER bridge-cron.sh.
bridge_source_module "bridge-resource-guard.sh"
bridge_source_module "bridge-discord.sh"
bridge_source_module "bridge-notify.sh"
bridge_source_module "bridge-migration.sh"
# Beta20 L2 Variant 3A — daemon refresh orchestration. Sourced AFTER
# bridge-state.sh (provides bridge_daemon_pid / bridge_daemon_recorded_pid)
# and bridge-agents.sh (bridge_current_user / bridge_linux_sudo_root) and
# bridge-isolation-v2.sh (group membership probes). Provides
# bridge_daemon_refresh_after_group_membership_change + sudoers installer
# called by agent create / delete / isolate / `agent-bridge init sudoers
# daemon-refresh`.
bridge_source_module "bridge-daemon-control.sh"
bridge_source_module "bridge-wave.sh"
# bridge-agent-update.sh is the typed/audited mutation surface for the
# protected agent-roster.local.sh managed-role fields (issue #528).
# Sourced last because it consumes helpers from bridge-agents.sh and
# bridge-core.sh (`bridge_admin_agent_id`, `bridge_require_python`).
bridge_source_module "bridge-agent-update.sh"

# Per-call re-validation of BRIDGE_SCRIPT_DIR (#946 L1) — the
# `bridge_resolve_script_dir_check` / `_or_die` helpers used by every
# `python3 "$BRIDGE_SCRIPT_DIR/..."` wrapper in lib/bridge-*.sh now live in
# lib/bridge-core.sh (r3, PR #951). bridge-lib.sh sources bridge-core.sh
# above, so the full-loader path here is unaffected; the move keeps the
# helpers available to direct-source consumers (e.g.
# tests/upgrade-precompact-wire/smoke.sh case 5, which sources
# lib/bridge-core.sh + lib/bridge-hooks.sh without bridge-lib.sh) without
# requiring them to also pull bridge-lib.sh.

# ---------------------------------------------------------------------------
# Lane A (v0.15.0-beta4): sanitized-first metadata read for iso UID context.
# ---------------------------------------------------------------------------
#
# When bridge-lib.sh is sourced from an iso UID (stop hook,
# mark-idle.sh, sub-shell run as `agent-bridge-<X>`), the protected
# `agent-roster.local.sh` is 0600 owner=controller and cannot be read.
# `bridge_load_roster` recovers via the scoped `runtime/agent-env.sh`
# under BRIDGE_AGENT_ROOT_V2 — but that recovery only fires when
# `bridge_load_roster` is actually called (queue-safe verb), and even
# then it depends on BRIDGE_AGENT_ID being exported into the hook env.
# Many hook subprocess paths (Claude `Stop` hook -> mark-idle.sh ->
# `bridge_agent_mark_idle_now`) consume the assoc arrays
# (`BRIDGE_AGENT_OS_USER[$agent]`, `BRIDGE_AGENT_ISOLATION_MODE[$agent]`)
# directly via lib/bridge-isolation-v2.sh::Path A0 before any explicit
# roster load — and those arrays are empty until something populates
# them.
#
# `agent-meta.env` (written by `bridge_isolation_v2_write_agent_metadata`,
# 0640 controller:ab-agent-<a>) is the sanitized backup snippet the iso
# UID can always read. Source-style sourcing would silently no-op
# because `BRIDGE_AGENT_OS_USER` / `BRIDGE_AGENT_ISOLATION_MODE` are
# bound to associative arrays (see #1213). Instead, we parse the file
# line-by-line and explicitly populate the assoc-array slot for the
# local agent.
#
# Backward compatibility: agents that have no snippet on disk
# (legacy installs that have not run prepare/reapply after this
# upgrade) fall through to the existing `bridge_load_roster` path —
# behavior is identical to current.
#
# Triggers: BRIDGE_AGENT_ID must be set AND the snippet must exist at
# the stable location. Empty / missing BRIDGE_AGENT_ID is the
# controller-side path, which always uses the full roster.
bridge_load_sanitized_agent_metadata() {
  # iso UID scope guard (codex r2 BLOCKING, PR #1286 r3):
  # This reader is only meaningful in an iso UID context (sub-shell
  # running as the agent's OS user). The controller (operator user)
  # has read access to the full `agent-roster.local.sh` via
  # `bridge_load_roster`, so populating arrays from the sanitized
  # snippet would (a) duplicate work and (b) risk preferring stale
  # snippet contents over the live roster.
  #
  # Prefix-independent 2-stage user-match guard — covers all three
  # supported iso UID naming cases:
  #   - default prefix (agent-bridge-<agent>)
  #   - custom prefix via `BRIDGE_AGENT_OS_USER_PREFIX=<pfx>`
  #   - explicit per-agent override via `bridge-agent.sh --os-user <user>`
  #     (the snippet's BRIDGE_AGENT_OS_USER may bear no syntactic
  #     relation to any prefix at all)
  #
  # Stage A peeks the snippet's BRIDGE_AGENT_OS_USER without sourcing
  # the file (avoids the #1213 assoc/scalar collision class). Stage B
  # compares `id -un` against that expected value. Match → load.
  # Mismatch → return 1.
  #
  # Returns 1 (not 0) when the current user is NOT the iso UID for
  # this agent — the call site at module-end uses `|| true` so this
  # does not propagate under `set -e`. Tests that need to drive the
  # reader from a controller context set
  # BRIDGE_SANITIZED_METADATA_SKIP_GUARD=1 to bypass the guard
  # (documented in scripts/smoke/lib.sh; never set in production
  # code paths).

  local agent="${BRIDGE_AGENT_ID:-}"
  [[ -n "$agent" ]] || return 1

  local meta_file="${BRIDGE_ACTIVE_AGENT_DIR:-$BRIDGE_HOME/state/agents}/$agent/agent-meta.env"
  [[ -r "$meta_file" ]] || return 1

  if [[ "${BRIDGE_SANITIZED_METADATA_SKIP_GUARD:-0}" != "1" ]]; then
    # Stage A: extract the snippet's BRIDGE_AGENT_OS_USER value via
    # awk peek — no `source`, no sub-shell variable bleed. Strip
    # surrounding double or single quotes if present.
    local _expected_os_user
    _expected_os_user="$(awk -F= '
      $1 == "BRIDGE_AGENT_OS_USER" {
        v = $0
        sub(/^BRIDGE_AGENT_OS_USER=/, "", v)
        gsub(/^"|"$/, "", v)
        gsub(/^'\''|'\''$/, "", v)
        print v
        exit
      }
    ' "$meta_file" 2>/dev/null)"
    [[ -n "$_expected_os_user" ]] || return 1

    # Stage B: match current user against the snippet's expected
    # owner. Mismatch → controller context or wrong agent → skip.
    local _cur_user
    _cur_user="$(id -un 2>/dev/null)" || return 1
    [[ "$_cur_user" == "$_expected_os_user" ]] || return 1
  fi

  # Ensure the assoc arrays exist (bridge-core.sh declares them inside
  # `bridge_reset_roster_maps`, which fires inside `bridge_load_roster`).
  # On a cold iso UID context the maps may not yet be declared at all;
  # declaring here is idempotent.
  declare -g -A BRIDGE_AGENT_OS_USER 2>/dev/null || true
  declare -g -A BRIDGE_AGENT_ISOLATION_MODE 2>/dev/null || true
  declare -g -A BRIDGE_AGENT_ENGINE 2>/dev/null || true
  declare -g -a BRIDGE_AGENT_IDS 2>/dev/null || true

  local key=""
  local val=""
  local line=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip CR (CRLF tolerance), skip blanks + comments.
    line="${line%$'\r'}"
    case "$line" in
      ''|\#*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    # Reject keys with whitespace or any character that's not in the
    # set we recognize. This is sanitization, not security — the file
    # is 0640 controller:ab-agent-<a>, owned by a privileged writer.
    case "$key" in
      BRIDGE_AGENT_OS_USER)
        BRIDGE_AGENT_OS_USER["$agent"]="$val"
        ;;
      BRIDGE_AGENT_ISOLATION_MODE)
        BRIDGE_AGENT_ISOLATION_MODE["$agent"]="$val"
        ;;
      BRIDGE_AGENT_ENGINE)
        BRIDGE_AGENT_ENGINE["$agent"]="$val"
        ;;
      BRIDGE_AGENT_HOME|BRIDGE_AGENT_CLAUDE_CONFIG_DIR|BRIDGE_AGENT_AUDIT_DIR)
        # Informational only — no array slot today. Future readers
        # could prefer these over `getent` lookups; for now they
        # serve as an operator-readable audit trail.
        :
        ;;
      *)
        # Unknown key — ignore (forward-compat snippet evolution).
        :
        ;;
    esac
  done <"$meta_file"

  # If the agent isn't already in the IDs list (cold iso UID context),
  # add it so callers that iterate `${BRIDGE_AGENT_IDS[@]}` see it.
  local existing
  for existing in "${BRIDGE_AGENT_IDS[@]+"${BRIDGE_AGENT_IDS[@]}"}"; do
    if [[ "$existing" == "$agent" ]]; then
      return 0
    fi
  done
  BRIDGE_AGENT_IDS+=("$agent")
  return 0
}

bridge_load_sanitized_agent_metadata || true
