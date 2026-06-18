#!/usr/bin/env bash
# bridge-run.sh — roster 기반 에이전트 실행기

set -uo pipefail

# #1444 BLOCKING 1 (credential safety, DEFINITIVE design — mirror of PR #1443's
# bridge-usage.sh r13). The env-source credential vars (CLAUDE_CODE_OAUTH_TOKEN,
# ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN) must never reach ANY child process —
# not via env var, not via on-disk path, not via inherited fd, not via an
# exported-function shadow, and not via a caller BASH_ENV/ENV startup-file hook.
# The flow, in order (each step runs before any external/child that could observe
# the credential):
#   A. Strip interceptor function shadows (exec/source/command/builtin/unset/…)
#      and `builtin unset BASH_ENV ENV BASH_XTRACEFD` so neither a function shadow
#      nor a caller startup-file can run in a child THIS script forks.
#   B. Capture+scrub (the "STEP A" block below, builtins only): move the three
#      credential VALUES into NON-exported shell vars and UNSET them from the ENV —
#      so from here on the environment is TOKEN-FREE for every subprocess we spawn.
#   C. UNIFIED re-exec to a PRIVILEGED Bash 4+ shell (`exec ... -p <bash4+>`) when
#      we are not already privileged OR not Bash 4+. Privileged Bash imports NO env
#      functions and ignores BASH_ENV/ENV — so the WHOLE exported-function-shadow
#      class (incl. `python3` forked by the keychain-free gate's
#      `bridge_runtime_config_value`, `uname` by `bridge_host_platform`, or names a
#      per-`unset -f` list would miss) AND the BASH_ENV/ENV hook class are closed
#      at the root, not per-name. Because this runs AFTER step B, the
#      candidate-version probe and the `exec` run in a token-free env — NO child of
#      bridge-run.sh inherits the credential. The captured values cross OUR re-exec
#      on fd 9 (unlinked 0600 file, magic-prefixed), and the privileged pass reads
#      + CLOSES fd 9 BEFORE `source bridge-lib.sh` — so bridge-lib.sh's source-time
#      dirname never inherits a readable token fd either. The single `-p` re-exec
#      satisfies BOTH privileged-mode and the Bash-4+ requirement, so bridge-lib.sh
#      never re-execs.
#   D. The values live ONLY in NON-exported shell vars across `source
#      bridge-lib.sh`, and are re-exported into the child env only on the legacy
#      auth path AFTER the source. Nothing to plant, nothing for a child to read.
# Residual (deferred #1454): the bash STARTUP of the very first `bash
# bridge-run.sh` process itself sources BASH_ENV before line 1 — our step-A unset
# is too late for that single process; launching privileged (`bash -p
# bridge-run.sh`) closes even that. Same boundary as bridge-lib.sh's own startup
# and a caller shadowing exec/builtin/unset to no-ops (caller who controls the
# launch env already holds the token). The per-name `unset -f` strips are kept
# belt-and-suspenders.

# Exported-function shadow defense — ROOT fix adopted from PR #1443's
# bridge-usage.sh head 05666c0. A same-UID caller can `export -f` Bash FUNCTIONS
# named after ANY command we invoke (printf/read/mktemp/chmod/python3/uname/… —
# the per-`unset -f` approach was whack-a-mole, codex kept finding the next missed
# name). Bash resolves an exported function BEFORE the external/builtin, so an
# UNQUALIFIED invocation would run the caller's function IN OUR shell and read our
# non-exported credential vars. The `bash -p` re-exec (step C) strips the ENTIRE
# class in one shot; the per-name `unset -f` here is belt-and-suspenders and also
# guards the re-exec line itself.

# Best-effort interceptor removal for the re-exec line ITSELF (FIRST, so the
# `builtin`/`unset` we rely on below are the real builtins): the `exec`/`unset`
# /`builtin` keywords on the very first pass could be shadowed functions. If THOSE
# special builtins are shadowed the caller already controls our process
# environment entirely (same-UID-controls-invocation-env — the deferred boundary
# tracked as #1454, same class as bridge-lib.sh's own re-exec). This strips the
# common cases.
builtin unset -f exec source command builtin unset printf read echo mktemp chmod \
         rm cat dirname cd pwd trap export local python3 python uname env \
         claude codex head readlink bash sh set true false 2>/dev/null || builtin true

# #1520 r5 (codex Phase-4 BLOCKING): clear inherited allexport at TRUE process
# entry — BEFORE the STEP A `_bridge_run_tok_*` token captures (below) and any
# proven-flag bare assignment. A caller-controlled BASH_ENV (sourced by bash
# before line 1) can run `set -a` (allexport), under which every later BARE
# assignment is EXPORTED to child processes instead of staying process-local —
# leaking the captured credential values to the first `$()` command-sub fork
# AND re-exporting the keychain-free proven flag to the launched Claude child.
# `set +a` stops auto-exporting FUTURE assignments (it does not unset anything
# the script legitimately exports later via an explicit `export`), so STEP A's
# captures, the proven-flag lifecycle, and the loop counters all stay
# process-local. Use `builtin set` (and `set` is in the `builtin unset -f`
# shadow-strip above) so a caller `set(){ :; }` FUNCTION shadow cannot no-op it.
#
# Boundary (deferred #1454, the SAME boundary the credential STEP A capture
# already lives under): this clear — like the entire STEP A scrub and the
# `builtin unset -f` shadow-strip — is itself written with `builtin`. A caller
# that shadows the `builtin` KEYWORD (`builtin(){ :; }` via BASH_ENV) defeats
# `builtin set +a`, `builtin unset -f`, AND STEP A's `builtin printf`/scrub
# alike — but such a caller "already controls our process environment entirely"
# (same-UID-controls-invocation-env) and the operator token would leak through
# STEP A regardless of #1520. So #1520's allexport clear inherits exactly the
# pre-existing #1454 boundary; it introduces no NEW weakness. Closing the
# `builtin`-keyword shadow is the #1454 work item, out of scope here. The
# `bash -p` re-exec below is the belt for the lesser (non-`builtin`) shadows.
builtin set +a

# Caller startup-file + xtrace hooks (#1444 BLOCKING, codex round-3 / parallel
# #1443): BASH_ENV / ENV name a file that EVERY non-interactive non-privileged
# bash SOURCES at startup, and BASH_XTRACEFD redirects `set -x` trace output to a
# caller-chosen fd. A same-UID caller can point BASH_ENV at a script that dumps a
# leaked credential the moment we fork a non-privileged child. We never use these
# hooks, so drop them HERE — before any child this script forks can run. Defense
# in depth: the STEP A capture+scrub below removes the credential from the env
# BEFORE the candidate-bash version probe runs (so the probe child inherits NO
# token), and the probe + re-exec additionally run under `bash -p` (privileged
# ignores BASH_ENV/ENV).
# `builtin unset` (the `unset` shadow was just stripped above) so a residual
# `unset()` function cannot no-op this. (The bash STARTUP of the very first `bash
# bridge-run.sh` process itself sources BASH_ENV before line 1 runs — that single
# sourcing is the deferred #1454 boundary; the `-p` re-exec keeps the WORKING
# shell + all its children clean.)
builtin unset BASH_ENV ENV BASH_XTRACEFD 2>/dev/null || builtin true

# Unset all bridge-private transit names unconditionally (value + export attr) so
# a caller-injected value can never be trusted on entry.
unset _bridge_run_tok_oat _bridge_run_tok_anthropic_key _bridge_run_tok_anthropic_auth \
      _bridge_run_fd_payload 2>/dev/null || true

# Inherited fd 9 defense (#1444 BLOCKING, codex round-3 fourth-pass): a same-UID
# caller can PRE-OPEN fd 9 to a file of their choosing before launching us. That
# caller-controlled fd would otherwise be inherited by every child this script
# forks (the `_bridge_run_pick` `$()` subshells, the candidate-version probes). We
# use fd 9 ONLY as OUR OWN transit across OUR re-exec, proven by a PER-PROCESS
# RANDOM NONCE (not a fixed public magic) that we generate AFTER closing any
# inherited fd 9 and write as the fd-9 record's first field; the re-exec'd pass
# accepts fd 9 ONLY when the inbound `_BRIDGE_RUN_FD9_NONCE` env value matches that
# first field. Because the nonce is generated in the parent AFTER the inherited fd
# 9 was closed, a caller cannot have pre-opened fd 9 with our nonce.
#   - OUR re-exec'd pass (nonce PRESENT): CONSUME fd 9 RIGHT HERE — read the
#     NUL-delimited records (builtins only, no fork) into the NON-exported shell
#     vars and CLOSE fd 9 — so fd 9 is gone BEFORE the first `$(...)` subshell
#     below ever forks (no child of the re-exec'd pass inherits the token fd).
#   - INITIAL pass (nonce ABSENT, or a caller-forged nonce that cannot match a fd 9
#     we have not written): CLOSE any inherited fd 9 before the first child fork.
if [[ -n "${_BRIDGE_RUN_FD9_NONCE:-}" ]] && [[ -r /dev/fd/9 ]]; then
  _bridge_run_fd_magic_seen=""
  while IFS= builtin read -r -d '' _bridge_run_fd_payload <&9; do
    if [[ -z "$_bridge_run_fd_magic_seen" ]]; then
      # First record must equal the per-process nonce the parent set. A
      # caller-preopened fd 9 cannot reproduce it (generated after the inherited
      # fd 9 was closed); a mismatch means this fd 9 is not ours — abandon it.
      [[ "$_bridge_run_fd_payload" == "$_BRIDGE_RUN_FD9_NONCE" ]] && _bridge_run_fd_magic_seen=1
      [[ -z "$_bridge_run_fd_magic_seen" ]] && break
      continue
    fi
    case "$_bridge_run_fd_payload" in
      CLAUDE_CODE_OAUTH_TOKEN=*) _bridge_run_tok_oat="${_bridge_run_fd_payload#*=}" ;;
      ANTHROPIC_API_KEY=*) _bridge_run_tok_anthropic_key="${_bridge_run_fd_payload#*=}" ;;
      ANTHROPIC_AUTH_TOKEN=*) _bridge_run_tok_anthropic_auth="${_bridge_run_fd_payload#*=}" ;;
      OPENAI_API_KEY=*) _bridge_run_tok_openai="${_bridge_run_fd_payload#*=}" ;;
      CODEX_ACCESS_TOKEN=*) _bridge_run_tok_codex="${_bridge_run_fd_payload#*=}" ;;
    esac
  done
  unset _bridge_run_fd_payload _bridge_run_fd_magic_seen
fi
# Always close fd 9 now: in the re-exec'd pass it has been consumed above; in the
# initial pass this drops any caller-preopened fd 9 before the first child fork.
# Brace-group the redirect so `2>/dev/null` scopes to the close ONLY — a bare
# `exec 9<&- 2>/dev/null` (exec with no command) would make `2>/dev/null`
# PERMANENT and swallow all later stderr (incl. bridge_die diagnostics).
{ exec 9<&-; } 2>/dev/null || builtin true
# The nonce has served its purpose (handoff proven); drop it from the env so no
# later child sees it.
unset _BRIDGE_RUN_FD9_NONCE 2>/dev/null || true

# SCRIPT_DIR via Bash builtins only (no `dirname` subprocess). Must stay ABSOLUTE
# (used as `python3 "$SCRIPT_DIR/..."` after this script cd's into WORK_DIR); when
# BASH_SOURCE[0] is relative, anchor to the launch CWD ($PWD) captured before any
# cd. Parameter expansion cannot be function-shadowed.
_bridge_run_src="${BASH_SOURCE[0]}"
if [[ "$_bridge_run_src" == */* ]]; then
  SCRIPT_DIR="${_bridge_run_src%/*}"
else
  SCRIPT_DIR="."
fi
if [[ "$SCRIPT_DIR" != /* ]]; then
  SCRIPT_DIR="$PWD/$SCRIPT_DIR"
fi
unset _bridge_run_src

# STEP A (UNCONDITIONAL, builtins + parameter expansion ONLY — runs before ANY
# external command AND before any `$(...)` command-substitution subshell, so no
# child of bridge-run.sh ever inherits the ambient token in its env): capture the
# three credential VALUES into NON-exported shell vars and UNSET them from the
# environment. A forged inbound env var cannot skip this. (codex round-3 BLOCKING:
# the `_bridge_run_pick` `$()` subshells below would otherwise fork while the token
# is still in env — so the scrub MUST precede them.) In OUR re-exec'd pass the
# values were already restored from fd 9 at the top; `${var:-${ENV:-}}` PRESERVES
# the restored value (and the env is already token-free there anyway).
_bridge_run_tok_oat="${_bridge_run_tok_oat:-${CLAUDE_CODE_OAUTH_TOKEN:-}}"
_bridge_run_tok_anthropic_key="${_bridge_run_tok_anthropic_key:-${ANTHROPIC_API_KEY:-}}"
_bridge_run_tok_anthropic_auth="${_bridge_run_tok_anthropic_auth:-${ANTHROPIC_AUTH_TOKEN:-}}"
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

# #1470 Phase 2 (Q6) — Codex ambient-key active-scrub. The Codex fleet-sync
# model delivers the subscription auth.json as a FILE the `codex` binary
# reads from CODEX_HOME, never an ambient env var. Capture the OpenAI-key /
# Codex-access-token env values into NON-exported shell vars and UNSET them
# from the env at TRUE process entry — alongside the STEP A Claude scrub,
# BEFORE any `$(...)` subshell / probe child / re-exec — so no child of
# bridge-run.sh ever inherits them. They are RESTORED later (below the
# launch decision) ONLY for an explicitly unmanaged/operator-owned Codex
# run; a MANAGED Codex agent launches with these absent so the bridge-
# delivered auth.json is the sole credential. (Pure parameter-expansion +
# unset — builtin-only, no fork, runs before the secret-scrub lib is
# sourced, mirroring the Claude capture above.) Values are NEVER logged.
_bridge_run_tok_openai="${_bridge_run_tok_openai:-${OPENAI_API_KEY:-}}"
_bridge_run_tok_codex="${_bridge_run_tok_codex:-${CODEX_ACCESS_TOKEN:-}}"
unset OPENAI_API_KEY CODEX_ACCESS_TOKEN

# #1520 r4 (codex Phase-4 BLOCKING): scrub the proven-keychain-free TRUST flag
# at TRUE process entry — here, alongside the STEP A credential scrub, BEFORE
# the `_bridge_run_pick` `$()` subshells below, the candidate-version probe
# forks, and the privileged `bash -p` re-exec. `unset` removes BOTH the value
# AND the export attribute, so an INHERITED exported
# `BRIDGE_RUN_CLAUDE_KEYCHAIN_FREE_VALIDATED=1` from the parent env cannot
# reach any early child / re-exec as a spoofed "proven" signal. A BARE `=0`
# assignment would NOT suffice: assigning over an inherited exported var keeps
# the export attribute (`env VAR=1 bash -c 'VAR=0; bash -c "echo \$VAR"'`
# prints 0 — the child still SEES it). The flag is only ever a process-local
# shell var afterward (the preflight sets/resets it with bare assignments,
# which create a NON-exported var once the inherited export attribute is gone);
# it must NEVER be exported, so the launched Claude child never inherits it.
unset BRIDGE_RUN_CLAUDE_KEYCHAIN_FREE_VALIDATED

# Bind the externals that run while the captured credential is reachable
# (mktemp/chmod/rm during the optional self-re-exec transit) to HARDCODED ABSOLUTE
# paths — a PATH-planted `mktemp`/`chmod`/`rm` must never run near the live token,
# and an absolute path cannot be a function name. `[[ -x ]]` is a builtin (no
# subprocess). The `$(...)` command-substitution subshells here run AFTER STEP A,
# so the env is already TOKEN-FREE — these forks inherit no credential.
_bridge_run_pick() { local _n; for _n in "$@"; do [[ -x "$_n" ]] && { builtin printf '%s' "$_n"; return 0; }; done; builtin printf '%s' "${1##*/}"; }
_BR_MKTEMP="$(_bridge_run_pick /usr/bin/mktemp /bin/mktemp /opt/homebrew/bin/mktemp)"
_BR_CHMOD="$(_bridge_run_pick /bin/chmod /usr/bin/chmod)"
_BR_RM="$(_bridge_run_pick /bin/rm /usr/bin/rm)"
unset -f _bridge_run_pick

# PER-PROCESS RANDOM NONCE proving an inherited fd 9 was written by US, not
# pre-opened by a caller (replaces the old fixed PUBLIC magic — codex round-3
# fourth-pass). Generated HERE, AFTER the inherited-fd-9 close above, so a caller
# cannot have pre-opened fd 9 with this value. Two independent entropy sources
# combined (SRANDOM is unguessable on Bash 5.1+; $RANDOM/PID/EPOCHSECONDS fall back
# on older Bash) — builtins only, no subprocess, no PATH/function exposure. Written
# as the fd-9 record's first field AND exported as _BRIDGE_RUN_FD9_NONCE for the
# re-exec'd pass to match before it trusts fd 9.
_BR_FD_MAGIC="agb-run-cred-fd-v2:${SRANDOM:-}:${RANDOM}${RANDOM}${RANDOM}:${BASHPID:-$$}:${EPOCHSECONDS:-0}"

# UNIFIED re-exec to a PRIVILEGED Bash 4+ shell. We re-exec into `bash -p` so the
# working shell + every child it forks is function-free + BASH_ENV-free + Bash 4+.
#
# #1520 r5 (codex Phase-4 BLOCKING): the re-exec into `bash -p` is DEFENSE IN
# DEPTH for residual function-shadow / BASH_ENV cleanliness — it is NOT the
# primary #1520 guarantee, and so its decision deliberately does NOT try to
# detect "am I the re-exec'd pass" from any caller-influenced signal (the `$-`
# `p` flag is set by a BASH_ENV `set -p`; a plain env marker or an fd-9 nonce
# can be pre-staged by a same-UID caller who controls both the env var AND the
# inherited fd). Those are all forgeable on first entry. Instead the SECURITY-
# CRITICAL invariants are established UNCONDITIONALLY at true process entry,
# BEFORE this decision and immune to it being skipped:
#   - `builtin set +a` cleared inherited allexport, so the STEP A token captures
#     and the keychain-free proven flag are process-local (never exported to a
#     child) regardless of whether we re-exec;
#   - STEP A captured + unset the credential env vars;
#   - the `builtin unset -f` strip (now incl. `set`) removed function shadows
#     and `builtin unset BASH_ENV ENV BASH_XTRACEFD` dropped the startup hooks.
# So a caller `set -p` that skips this re-exec cannot reintroduce the #1520
# token / proven-flag leak. We still re-exec for the clean `-p` shell on the
# normal path (not privileged, or not yet Bash 4+); the `bash -p` target is
# function-free + BASH_ENV-free + Bash 4+, and re-execs exactly once (after it,
# `-p` is set and we are 4+, so the condition is false).
#
# CRITICAL (codex round-3 BLOCKING): this runs AFTER STEP A scrubbed the credential
# from the ENV, so the candidate-version probe and the `exec` run in a TOKEN-FREE
# env — no child of bridge-run.sh inherits the credential in its environment. AND
# (codex round-3 second-pass): we SELECT the Bash-4+ candidate FIRST (the probe
# children fork while fd 9 is NOT yet open), and open the token-bearing fd 9 ONLY
# after a candidate is chosen — immediately before `exec` — so the credential fd is
# inherited ONLY by the final re-exec target, never by a probe child. The post-
# re-exec pass reads + CLOSES fd 9 BEFORE sourcing bridge-lib.sh, so bridge-lib.sh's
# source-time dirname never inherits a readable token fd either. Nothing to plant,
# nothing for a child to read.
if [[ "$-" != *p* ]] || (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  _bridge_run_self="${BASH_SOURCE[0]}"
  if [[ -f "$_bridge_run_self" ]]; then
    # 1. SELECT the candidate FIRST — probe each absolute-path Bash under `-p`
    #    (token-free env, NO fd 9 open yet, so the probe children inherit neither
    #    the credential env nor a readable token fd). `-p` also makes the probe
    #    ignore BASH_ENV/ENV + imported functions.
    _bridge_run_chosen=""
    for _bridge_run_cand in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
      if [[ -x "$_bridge_run_cand" ]] && "$_bridge_run_cand" -p -c '((${BASH_VERSINFO[0]:-0}>=4))' 2>/dev/null; then
        _bridge_run_chosen="$_bridge_run_cand"
        break
      fi
    done
    if [[ -n "$_bridge_run_chosen" ]]; then
      # 2. Now that a candidate is chosen and NO more probe children will fork,
      #    stash the captured token values (if any) on fd 9 (unlinked 0600 file,
      #    nonce-prefixed; `exec`/`-p` preserve fd inheritance). Only the `exec`
      #    target below inherits fd 9. fd 9 is opened ONLY when a token exists —
      #    it is purely the secure credential transit, NOT a re-exec signal (the
      #    re-exec decision above is intentionally token/fd-independent).
      if [[ -n "$_bridge_run_tok_oat$_bridge_run_tok_anthropic_key$_bridge_run_tok_anthropic_auth$_bridge_run_tok_openai$_bridge_run_tok_codex" ]]; then
        if _bridge_run_fd_file="$("$_BR_MKTEMP" "${TMPDIR:-/tmp}/agb-run-cred.XXXXXX" 2>/dev/null)"; then
          "$_BR_CHMOD" 600 "$_bridge_run_fd_file" 2>/dev/null || true
          # builtin printf so an exported printf() function cannot intercept the
          # token write. NUL-delimited NAME=VALUE records (safe for newlines/`=`).
          # #1470 P2: the captured Codex ambient-key values ride the SAME fd-9
          # transit so they too are scrubbed from the env across the re-exec and
          # restored ONLY for an explicitly unmanaged Codex run (decided below).
          {
            builtin printf '%s\0' "$_BR_FD_MAGIC"
            [[ -n "$_bridge_run_tok_oat" ]] && builtin printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\0' "$_bridge_run_tok_oat"
            [[ -n "$_bridge_run_tok_anthropic_key" ]] && builtin printf 'ANTHROPIC_API_KEY=%s\0' "$_bridge_run_tok_anthropic_key"
            [[ -n "$_bridge_run_tok_anthropic_auth" ]] && builtin printf 'ANTHROPIC_AUTH_TOKEN=%s\0' "$_bridge_run_tok_anthropic_auth"
            [[ -n "$_bridge_run_tok_openai" ]] && builtin printf 'OPENAI_API_KEY=%s\0' "$_bridge_run_tok_openai"
            [[ -n "$_bridge_run_tok_codex" ]] && builtin printf 'CODEX_ACCESS_TOKEN=%s\0' "$_bridge_run_tok_codex"
          } >"$_bridge_run_fd_file"
          # Brace-group the redirect: a bare `exec 9<file 2>/dev/null` (exec with
          # redirections but no command) would make `2>/dev/null` PERMANENT and
          # the re-exec'd child below would inherit a /dev/null stderr.
          { exec 9<"$_bridge_run_fd_file"; } 2>/dev/null || true
          "$_BR_RM" -f -- "$_bridge_run_fd_file" 2>/dev/null || true
          unset _bridge_run_fd_file
        fi
        # Drop the in-shell copies; the values ride fd 9 across the exec.
        unset _bridge_run_tok_oat _bridge_run_tok_anthropic_key _bridge_run_tok_anthropic_auth \
              _bridge_run_tok_openai _bridge_run_tok_codex
        # Hand the nonce to the re-exec'd pass so it can prove fd 9 is OURS (it
        # validates the first record == this nonce). Only set when we actually
        # opened fd 9 with a token.
        export _BRIDGE_RUN_FD9_NONCE="$_BR_FD_MAGIC"
      fi
      # 3. Re-exec into the chosen privileged Bash 4+ shell.
      exec "$_bridge_run_chosen" -p "$_bridge_run_self" "$@"
    fi
  fi
  # Reached only if we found no Bash-4+ candidate to re-exec into. The per-name
  # `unset -f` strip above is the residual defense.
  if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
    echo "[bridge-run] Agent Bridge requires Bash 4+ (current: ${BASH_VERSION:-unknown}). Put a Bash 4+ on PATH." >&2
    exit 1
  fi
  unset _bridge_run_chosen _bridge_run_cand _bridge_run_self 2>/dev/null || true
fi

# Privileged Bash 4+ now. The fd-9 token transit (if any) was already consumed +
# closed at the TOP (before any `$(...)` subshell forked), so the captured values
# live ONLY in the NON-exported _bridge_run_tok_* shell vars here. Drop the transit
# binaries (the nonce was already unset at the top).
unset _BR_FD_MAGIC _BR_MKTEMP _BR_CHMOD _BR_RM 2>/dev/null || true

# Belt-and-suspenders on the privileged working pass (privileged mode already
# prevented function import across the re-exec, so this is normally a no-op): the
# captured secret is now live in the NON-exported _bridge_run_tok_* vars again, so
# re-strip any command-named function shadow before bridge-lib.sh is sourced and
# the keychain-free gate forks python3 / uname. Belt: commands near the live token
# also use `builtin`/`command`/absolute qualification.
builtin unset -f printf read echo mktemp chmod rm cat dirname cd pwd command \
         builtin exec source trap export local python3 python uname env claude \
         codex head readlink bash sh true false 2>/dev/null || builtin true

# Issue #1101: defensive unset of stale BRIDGE_LAYOUT/BRIDGE_DATA_ROOT before
# sourcing bridge-lib.sh. This is the launch envelope tmux runs as the pane's
# session command, so anything we drop here is never seen by the child agent
# process (Claude/Codex) or any Bash-tool subshells it spawns inside the pane.
#
# Background: PR #1019 §B stopped the daemon's launch-envelope writer
# (`bridge_write_linux_agent_env_file`) from baking `BRIDGE_LAYOUT=legacy`
# into the per-agent env file, and the layout-resolver demotes the same
# value when a v2 marker exists. But on installs that ran a pre-#1019 daemon
# with `BRIDGE_LAYOUT=legacy` in its ambient env (operator shell rc, stale
# tmux server env, …), the value was already copied into the parent process
# chain (daemon → bridge-start.sh → tmux new-session) BEFORE the resolver
# demoted it, so every pane this script launches still inherits the stale
# value. The resolver in the resulting child shells then re-fires the
# "stale pre-v0.8.0 env override" warning on every CLI call.
#
# Gating: only drop when a valid v2 layout marker is present. Without a
# marker the resolver's hard-die path is the correct outcome — operators on
# legacy installs need the upgrade prompt, not a silent normalization.
_bridge_run_layout_marker="${BRIDGE_LAYOUT_MARKER_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}/layout-marker.sh"
if [[ -f "$_bridge_run_layout_marker" ]] \
    && [[ "${BRIDGE_LAYOUT:-}" == "legacy" || "${BRIDGE_LAYOUT:-}" == "v1" ]]; then
  unset BRIDGE_LAYOUT BRIDGE_DATA_ROOT
fi
unset _bridge_run_layout_marker

# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

# #1444 BLOCKING 1 (codex Phase-4): we are past `source bridge-lib.sh`, which did
# NOT re-exec (we self-re-exec'd to Bash 4+ above), so its `:33` dirname ran in a
# token-free env with NO transit fd/path/var to read — the captured credential
# values live ONLY in the NON-exported _bridge_run_tok_* shell vars. Now decide
# whether to restore them into the environment for the launched Claude:
#   - LEGACY auth path (NOT keychain-free, or not on Darwin where the feature
#     applies): the ambient env token may legitimately be the child Claude's auth
#     source, so RESTORE — preserving pre-#1444 behavior.
#   - KEYCHAIN-FREE on Darwin: the child authenticates via the apiKeyHelper /
#     .credentials.json, never the env token, so DO NOT restore.
# The mode-decision helpers run while the captured secret is still live in the
# NON-exported _bridge_run_tok_* vars, so their UNQUALIFIED command invocations
# matter: bridge_claude_keychain_free_auth_enabled -> bridge_runtime_config_value
# forks `python3` (the config-file-backed gate path; the env
# BRIDGE_CLAUDE_KEYCHAIN_FREE_AUTH=1 short-circuit skips it), and
# bridge_host_platform forks `uname`. A caller-exported `python3()`/`uname()`
# function would otherwise run IN OUR shell and read _bridge_run_tok_*. The
# top-of-script `bash -p` privileged re-exec stripped ALL imported functions, so
# those forks resolve to the real external — not a caller's shadow. Their child
# processes also inherit a token-free env (the secret lives only in our shell vars,
# never exported here), so nothing leaks via env/fd/path either.
if [[ -n "$_bridge_run_tok_oat$_bridge_run_tok_anthropic_key$_bridge_run_tok_anthropic_auth" ]]; then
  _bridge_run_restore_creds=1
  if bridge_claude_keychain_free_auth_enabled 2>/dev/null; then
    _bridge_run_platform="$(bridge_host_platform 2>/dev/null || builtin printf '')"
    [[ "$_bridge_run_platform" == "Darwin" ]] && _bridge_run_restore_creds=0
    unset _bridge_run_platform
  fi
  if [[ "$_bridge_run_restore_creds" == "1" ]]; then
    [[ -n "$_bridge_run_tok_oat" ]] && export CLAUDE_CODE_OAUTH_TOKEN="$_bridge_run_tok_oat"
    [[ -n "$_bridge_run_tok_anthropic_key" ]] && export ANTHROPIC_API_KEY="$_bridge_run_tok_anthropic_key"
    [[ -n "$_bridge_run_tok_anthropic_auth" ]] && export ANTHROPIC_AUTH_TOKEN="$_bridge_run_tok_anthropic_auth"
  fi
  unset _bridge_run_restore_creds
fi
unset _bridge_run_tok_oat _bridge_run_tok_anthropic_key _bridge_run_tok_anthropic_auth

# #1470 Phase 2 (Q6): the captured Codex ambient-key values
# (_bridge_run_tok_openai / _bridge_run_tok_codex) are deliberately NOT
# unset here — unlike the Claude vars above, the Codex restore DECISION
# needs the per-agent ENGINE + managed/unmanaged status, which is resolved
# later in the relaunch loop. They stay live (NON-exported, already scrubbed
# from the env) until bridge_run_apply_codex_ambient_env runs at the launch
# site. For every non-Codex agent they simply remain absent from the env
# (correct — the launched Claude/antigravity child never wants them).

# PR-E (revised): linux-user isolation requires umask 0007 in both
# legacy ACL-backed isolation and v2 group/setgid isolation. Without
# 0007, umask-governed creates land with group bits=0, which can collapse
# the POSIX ACL mask to `---` and mask named-user entries such as the
# controller's rwX grant. This caused 2026-05-04/05 daily-backup EACCES
# regressions on isolated agent homes. Scope is the umask-governed create
# path only; application-level chmod 0600 remains out of scope.
#
# Called twice from this script: once after the first bridge_require_agent
# at startup, and once from bridge_run_refresh_roster_if_changed after the
# subsequent bridge_require_agent on roster reload. Defined here (above
# any caller) so the first call site below is not running against an
# undefined function (PR #399 r1 FAIL #14): bash with `set -uo pipefail`
# silently emits "command not found" + rc=127 and the script keeps going,
# leaving initial v2 launches inheriting bridge-lib.sh's 0077.
#
# BRIDGE_RUN_UMASK_PROBE_FILE is a hidden smoke-only hook: when set, the
# helper writes the resulting umask (post-set) to that path so a smoke
# fixture can assert the bridge-run.sh effective umask without parsing
# /proc/<pid>/status. Inert when unset.
bridge_run_apply_v2_umask_if_needed() {
  local agent="$1"
  # v0.8.0 T5: BRIDGE_DISABLE_ISOLATION=1 short-circuits the umask 007
  # wrap so the child inherits bridge-lib.sh's default 0077. With the
  # boundary off, the agent runs as the controller UID and private mode
  # (controller-only readable) is the correct contract — group bits do
  # not need to be set for a peer UID that no longer exists.
  if bridge_isolation_disabled_by_env; then
    if [[ -n "${BRIDGE_RUN_UMASK_PROBE_FILE:-}" ]]; then
      umask 2>/dev/null >"$BRIDGE_RUN_UMASK_PROBE_FILE" || true
    fi
    return 0
  fi
  if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    umask 007
  fi
  if [[ -n "${BRIDGE_RUN_UMASK_PROBE_FILE:-}" ]]; then
    umask 2>/dev/null >"$BRIDGE_RUN_UMASK_PROBE_FILE" || true
  fi
}

usage() {
  echo "Usage: bash $SCRIPT_DIR/bridge-run.sh <agent> [--once] [--continue|--no-continue] [--safe-mode] [--dry-run]"
  echo "       bash $SCRIPT_DIR/bridge-run.sh --list"
  echo ""
  echo "등록된 에이전트:"
  bridge_list_agents
}

LIST_ONLY=0
ONCE=0
DRY_RUN=0
CONTINUE_EXPLICIT=0
CONTINUE_MODE=1
SAFE_MODE=0
AGENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --once)
      ONCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --safe-mode)
      SAFE_MODE=1
      shift
      ;;
    --continue)
      CONTINUE_EXPLICIT=1
      CONTINUE_MODE=1
      shift
      ;;
    --no-continue)
      CONTINUE_EXPLICIT=1
      CONTINUE_MODE=0
      shift
      ;;
    -*)
      bridge_die "알 수 없는 옵션: $1"
      ;;
    *)
      if [[ -z "$AGENT" ]]; then
        AGENT="$1"
      else
        bridge_die "에이전트는 하나만 지정할 수 있습니다."
      fi
      shift
      ;;
  esac
done

# Export BRIDGE_AGENT_ID before roster load so bridge_load_roster can pick up
# the per-agent scoped snapshot when this script runs under an isolated UID
# that cannot read the 0600 agent-roster.local.sh. See issue #116.
if [[ -n "$AGENT" ]]; then
  export BRIDGE_AGENT_ID="$AGENT"
fi
bridge_load_roster

if [[ $LIST_ONLY -eq 1 ]]; then
  bridge_list_agents
  exit 0
fi

if [[ -z "$AGENT" ]]; then
  usage
  exit 1
fi

bridge_require_agent "$AGENT"

# PR-E: apply the isolation launch umask before any runtime mkdir/plugin
# sync/launch work. bridge-lib.sh:17 unconditionally sets 0077; this
# helper changes it only when the agent is linux-user-isolated.
bridge_run_apply_v2_umask_if_needed "$AGENT"

if [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
  BRIDGE_AGENT_CONTINUE["$AGENT"]="$CONTINUE_MODE"
fi

# Issue #268: same warning as bridge-start.sh, repeated here because operators
# can invoke bridge-run.sh directly (and tmux session_cmd injects --no-continue
# without going through bridge-start.sh on FORCE_FRESH_SESSION paths). Goes to
# stderr so dry-run callers parsing stdout for `session_id=...` keep working.
if [[ $CONTINUE_EXPLICIT -eq 1 && "$CONTINUE_MODE" == "0" ]]; then
  _persisted_session_id="$(bridge_agent_persisted_session_id "$AGENT")"
  if [[ -n "$_persisted_session_id" ]]; then
    bridge_warn "launched fresh for this run, but saved session_id=${_persisted_session_id} remains; next normal restart will resume it. Use 'agb agent forget-session $AGENT' to clear permanently."
  fi
  unset _persisted_session_id
fi

if [[ $SAFE_MODE -eq 1 ]]; then
  ONCE=1
fi

# Issue #1248 Lane A3 — `--no-continue` vs `continue=1` reconcile.
#
# Source-of-truth matrix (applied AFTER --continue/--no-continue overrides
# from CLI args have been folded into BRIDGE_AGENT_CONTINUE):
#
#   effective continue=1 + session_id non-empty  ->  resume verb in
#       launch_cmd (engine-specific: claude --resume <id>, codex resume
#       <id>); decided by the downstream launch-cmd builders.
#   effective continue=1 + session_id EMPTY      ->  bridge_die here with
#       structured remediation. This is the #1248 surface — silent
#       persist-write failure (downstream of #1246) left session_id
#       empty, and every subsequent restart spawned a fresh Claude
#       session because the launch-cmd builder's
#       `bridge_claude_has_resumable_session_state` fallback emitted
#       --continue and the post-startup capture in
#       bridge_run_schedule_idle_marker_and_inbox_bootstrap silently
#       swallowed the persist failure. Failing here makes the missing
#       capture ops-visible on the next restart instead of compounding
#       into another orphan jsonl.
#   effective continue=0 or --no-continue passed  ->  NO resume verb
#       (intentional fresh session); decided by the downstream builders.
#
# Safe-mode short-circuit: BRIDGE_AGENT_RESUME_GATE_ENABLED=0 disables
# the gate for the rare case an operator needs to bypass it during
# incident triage (e.g. inspecting a known-broken roster). Audit-log a
# one-line breadcrumb so the bypass is not invisible.
_resume_gate_enabled="${BRIDGE_AGENT_RESUME_GATE_ENABLED:-1}"
if [[ "$_resume_gate_enabled" == "1" && $SAFE_MODE -eq 0 ]]; then
  _gate_continue="$(bridge_agent_continue "$AGENT")"
  _gate_session_id="$(bridge_agent_session_id "$AGENT")"
  if [[ "$_gate_continue" == "1" && -z "$_gate_session_id" ]]; then
    # Issue #1265 (v0.15.0-beta4 Lane E) — fresh-install first-wake
    # carve-out. The Lane A3 gate (above) was designed for the
    # `lost-state` case: an agent that has launched before (and
    # therefore captured a session_id) but lost the persisted id due
    # to the #1246 daemon supp-group write failure or operator-side
    # rm -rf. That gate correctly fires loud so the operator sees it.
    # However it also fired on the FRESH-install first-wake case, which
    # is the OOTB-normal path:
    #   `agb admin` on a fresh install -> patch agent has continue=1
    #   (roster default for admins) AND session_id="" (no jsonl yet,
    #   never launched). #1265 reported this as an OOTB-blocker for
    #   the operator-visible `agb admin` flow AND for the daemon
    #   picker-sweep wake of the codex pair (patch-dev), which had no
    #   way to provide an `--no-continue` override.
    #
    # Heuristic: `state/agents/<a>/launch.history` is the marker that
    # the agent has been launched at least once. Absent => fresh
    # first-wake (proceed without --resume, emit a structured info
    # log + audit row, and defer marker creation to the real-launch
    # path so dry-run inspection stays side-effect-free; the NEXT
    # empty-sid condition after a real launch correctly falls into
    # the lost-state die branch).
    # Present => the agent has launched before; an empty session_id
    # now is the genuine #1248 lost-state and the die path is correct.
    #
    # The marker file is initially empty (touch only). Future passes
    # may append 1-line per launch for ops-analytics; the schema is
    # intentionally minimal so a `touch`/`rm` is the only operational
    # surface. mkdir of the parent uses the existing self-heal helper
    # (#1252 -- `bridge_agent_state_dir_self_heal`) to keep mode/group
    # canonical on iso-v2 hosts; a touch fallback is also tried in
    # case the helper is absent (non-v2 install) or the parent already
    # exists but the helper short-circuits. Touch failure is
    # non-fatal: we still proceed (the gate has decided the launch is
    # legitimate) -- a future tick will retry.
    #
    # R2 (codex r1 BLOCKING — dry-run poisoning): the marker MUST NOT
    # be created in this gate, because `bridge-run.sh --dry-run` is an
    # advertised inspection mode and reaching the gate is not the same
    # as "actually launched". Creating the marker here would flip a
    # never-launched agent into "launched before" state, so the next
    # real first launch (or even a second dry-run) would fall through
    # to the lost-state die branch. We capture intent in a flag here
    # and the real-launch path (after the dry-run early-exit) creates
    # the marker exactly once, right before the launch loop.
    #
    # R3 (codex r2 BLOCKING — canonical state-dir path): the marker
    # path MUST anchor on the canonical per-agent state leaf
    # (`bridge_agent_idle_marker_dir <agent>` => `$BRIDGE_ACTIVE_AGENT_DIR/<a>`,
    # which composes from `$BRIDGE_STATE_DIR/agents`), not on the
    # hardcoded `$BRIDGE_HOME/state/agents/<a>` path. On hosts where
    # `BRIDGE_STATE_DIR` is relocated independently of `BRIDGE_HOME`
    # (operator override, isolated test layout) the two diverge and the
    # gate would write the marker into one tree while the
    # `bridge_agent_state_dir_self_heal` helper used by the real-launch
    # block (and the daemon wake paths) targets the canonical tree —
    # they would silently disagree and the next empty-sid gate would
    # never see the marker, breaking the #1248 lost-state -> die
    # contract on relocated layouts.
    _gate_launch_history="$(bridge_agent_idle_marker_dir "$AGENT")/launch.history"
    if [[ ! -f "$_gate_launch_history" ]]; then
      bridge_info "[run] fresh first-wake (no session yet) — launching new session (agent=$AGENT)"
      bridge_audit_log run fresh_first_wake "$AGENT" \
        --detail continue_mode="$_gate_continue" \
        --detail reason=fresh_install_no_launch_history \
        2>/dev/null || true
      # Defer marker creation to the real-launch path (see post-dry-run
      # block below). The gate has decided the launch is legitimate;
      # the marker becomes truth-on-disk only when an actual launch is
      # attempted, NOT when --dry-run is inspecting the resolution.
      BRIDGE_RUN_PENDING_FRESH_MARKER="$_gate_launch_history"
      unset _gate_launch_history
    else
      unset _gate_launch_history
      # Lost-state: the agent HAS launched before (launch.history present) but
      # its persisted session_id is gone — a #1246 daemon supp-group write
      # failure, state churn, an operator rm, or a prior crash-loop that never
      # captured one. The original behavior bridge_die'd here. Under the
      # daemon's always-on restart loop that BRICKS the agent permanently:
      # every relaunch hard-fails identically, so the agent can never recover
      # on its own (the daemon's plugin-MCP-liveness watchdog then restarts it
      # forever). A missing session_id is recoverable — degrade THIS launch to
      # a fresh session (no --resume), exactly like the fresh-first-wake path
      # above, but emit a loud warn so it stays ops-visible. The launch
      # captures a fresh session_id on start and normal resume returns next
      # launch. Genuine persistence/write errors still hard-fail loud in
      # bridge_refresh_agent_session_id (bridge_die), so the #1248 fail-loud
      # contract for actual write failures is preserved.
      bridge_warn "[run] lost-state: continue=1 but session_id empty (agent=$AGENT) — degrading to a fresh session for this launch; a new id is captured on start and normal resume returns next launch"
      bridge_audit_log run session_id_missing_resume_degraded "$AGENT" \
        --detail continue_mode="$_gate_continue" \
        --detail reason=lost_state_session_id_empty_degraded_to_fresh \
        2>/dev/null || true
    fi
  fi
  unset _gate_continue _gate_session_id
fi
unset _resume_gate_enabled

WORK_DIR="$(bridge_agent_workdir "$AGENT")"
ENGINE="$(bridge_agent_engine "$AGENT")"
SESSION="$(bridge_agent_session "$AGENT")"
if [[ $SAFE_MODE -eq 1 ]]; then
  LAUNCH_CMD="$(bridge_build_safe_launch_cmd "$AGENT")"
else
  LAUNCH_CMD="$(bridge_agent_launch_cmd "$AGENT")"
fi

if [[ -z "$WORK_DIR" || -z "$LAUNCH_CMD" ]]; then
  bridge_die "'$AGENT'의 workdir 또는 launch command가 비어 있습니다."
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "agent=$AGENT"
  echo "engine=$ENGINE"
  echo "workdir=$WORK_DIR"
  echo "loop=$(bridge_agent_loop "$AGENT")"
  echo "continue=$(bridge_agent_continue "$AGENT")"
  echo "session_id=$(bridge_agent_session_id "$AGENT")"
  echo "safe_mode=$SAFE_MODE"
  echo "channels=$(bridge_agent_channels_csv "$AGENT")"
  echo "channel_status=$(bridge_agent_channel_status "$AGENT")"
  echo "launch=$(bridge_redact_inline_env_secrets "$LAUNCH_CMD")"
  # R2 (codex r1 BLOCKING — dry-run poisoning): dry-run must NEVER
  # create the launch.history marker. Unset the deferred-marker hint
  # captured by the resume gate so a subsequent real launch in this
  # process (none today, but defensive) cannot accidentally touch it
  # via leaked global state.
  unset BRIDGE_RUN_PENDING_FRESH_MARKER
  exit 0
fi

# R2 (codex r1 BLOCKING — dry-run poisoning, fresh first-wake real
# launch path): the resume gate above captured a deferred marker hint
# (BRIDGE_RUN_PENDING_FRESH_MARKER) when it observed continue=1 +
# session_id="" + launch.history absent. Now that we have cleared the
# dry-run early-exit, this IS a real launch — create the marker once,
# right before the launch loop starts, so the NEXT empty-sid condition
# (next process invocation) correctly falls into the lost-state die
# branch (#1248). Marker creation failure stays non-fatal (the gate
# has already decided the launch is legitimate) — a future tick will
# retry.
if [[ -n "${BRIDGE_RUN_PENDING_FRESH_MARKER:-}" ]]; then
  if command -v bridge_agent_state_dir_self_heal >/dev/null 2>&1; then
    bridge_agent_state_dir_self_heal "$AGENT" >/dev/null 2>&1 || true
  fi
  mkdir -p "$(dirname "$BRIDGE_RUN_PENDING_FRESH_MARKER")" 2>/dev/null || true
  : >"$BRIDGE_RUN_PENDING_FRESH_MARKER" 2>/dev/null || true
  unset BRIDGE_RUN_PENDING_FRESH_MARKER
fi

# Issue #1352 (beta5-3 Track K): re-augment the launch shell PATH with the
# resolved engine-manager dirs (nvm/pyenv/rbenv/asdf/fnm + BRIDGE_ENGINE_PATH)
# rather than a hard-coded `~/.local/bin:~/.nix-profile/bin:/usr/local/bin`
# list. bridge-lib.sh already ran bridge_augment_engine_path at source time
# (above), so this is normally a no-op — but it removes the iso-only special
# case (the shared codex pair, isolation_mode: shared, is what every admin
# install auto-provisions, and it never reached the iso sudo-wrap PATH
# injection at lib/bridge-agents.sh:3699-3723). Calling the same canonical
# resolver here guarantees the bare `codex`/`claude` token in LAUNCH_CMD
# resolves on user-local Node managers (nvm/pyenv/volta/asdf/fnm) whichever
# codepath the agent took, and stays manager-rotation-proof (no pinned Node
# version). The three legacy dirs are already covered by the lib-load-time
# bridge_prepend_path_entry block, so dropping the inline literal loses
# nothing. Idempotent (bridge_prepend_path_entry skips dirs already on PATH).
bridge_augment_engine_path
export PATH
export BRIDGE_AGENT_ID="$AGENT"
export BRIDGE_ADMIN_AGENT_ID="$(bridge_admin_agent_id)"
export BRIDGE_AGENT_WORKDIR="$WORK_DIR"
# Issue #1497: the bare name collides with BRIDGE_AGENT_WORKDIR[] in
# lib/bridge-agents.sh, so hooks consume this scalar alias first.
export BRIDGE_AGENT_WORKDIR_RESOLVED="$WORK_DIR"
# Issue #1497 (P1): identity-home companion to the workdir scalar above.
# bridge_agent_default_home is v2-aware (`$BRIDGE_AGENT_ROOT_V2/<a>/home`
# on a v2 install, legacy `$BRIDGE_AGENT_HOME_ROOT/<a>` otherwise), so this
# carries the SAME tree the bash launch/state layer uses. The Python hook
# (hooks/bridge_hook_common.py::agent_default_home) reads this scalar FIRST,
# which is what prevents the v2-blind legacy short-circuit that silently
# dropped the NEXT-SESSION.md handoff for v2-split agents. There is no
# assoc-array named BRIDGE_AGENT_HOME_RESOLVED, so unlike the workdir case
# this name does not strictly need the _RESOLVED suffix — but keeping the
# parallel naming makes the bash→Python channel a single recognizable
# pattern (mirrors BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED, #1217).
export BRIDGE_AGENT_HOME_RESOLVED="$(bridge_agent_default_home "$AGENT")"
# Issue #1213 / #1217 (beta27): BRIDGE_AGENT_ISOLATION_MODE,
# BRIDGE_AGENT_OS_USER, and BRIDGE_AGENT_INJECT_TIMESTAMP all share
# their names with associative arrays declared in
# lib/bridge-agents.sh:3410 (ISOLATION_MODE, OS_USER) and
# lib/bridge-core.sh:867 (INJECT_TIMESTAMP). Bash silently no-ops a
# scalar export of a name bound to an associative array (no error,
# ARR=value writes to ARR[0] and `export ARR` refuses to export the
# array), so the bare-name exports below never reach the child env.
#
# Fixes:
#   - BRIDGE_AGENT_ISOLATION_MODE / BRIDGE_AGENT_OS_USER: #1213
#     switched the Python hook predicate off the mode-string env to
#     a UID-based check (_current_agent_under_foreign_uid); see
#     hooks/bridge_hook_common.py:_under_isolated_uid. The bare-name
#     scalar exports stay as silent-no-ops to avoid breaking any
#     out-of-band consumer that might still read them on a future host.
#   - BRIDGE_AGENT_INJECT_TIMESTAMP: #1217 (beta27 Track D) adds a
#     distinctly-named scalar alias BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED
#     (same shape as BRIDGE_AGENT_CLASS_FOR_HOOK for #539). The Python
#     hook reads RESOLVED first, with a fallback to the bare name for
#     manual / non-bridge launches where the assoc-array collision
#     does not exist.
#
# DO NOT `unset` either array name as a workaround: downstream array
# readers in bridge-run.sh and lib/* expect the lookup table to remain
# populated.
export BRIDGE_AGENT_ISOLATION_MODE="$(bridge_agent_isolation_mode "$AGENT")"
export BRIDGE_AGENT_OS_USER="$(bridge_agent_os_user "$AGENT")"
# Issue #539: privilege class consumed by hooks/tool-policy.py to gate
# cross-agent reads. Default "user"; "system" opts in to read-only access
# of peer memory/{projects,decisions,shared}/ trees. Exported as a
# distinctly-named scalar (BRIDGE_AGENT_CLASS in bash is the associative
# array of every agent's class; the hook only needs the calling agent's
# value, so we surface a scalar alias here).
export BRIDGE_AGENT_CLASS_FOR_HOOK="$(bridge_agent_class "$AGENT")"
# Issue #1217 (beta27 Track D): the bare BRIDGE_AGENT_INJECT_TIMESTAMP
# export silently no-ops because of the assoc-array name collision
# documented in the comment block above. Keep it for backwards
# compatibility, and add BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED as the
# distinctly-named scalar alias the Python hook actually reads.
export BRIDGE_AGENT_INJECT_TIMESTAMP="$(bridge_agent_inject_timestamp "$AGENT")"
export BRIDGE_AGENT_INJECT_TIMESTAMP_RESOLVED="$(bridge_agent_inject_timestamp "$AGENT")"
export BRIDGE_AGENT_PROMPT_GUARD_POLICY="$(bridge_guard_policy_raw "$AGENT")"
export BRIDGE_PROMPT_GUARD_CANARY_TOKENS="$(bridge_agent_prompt_guard_canary "$AGENT")"

mkdir -p "$(bridge_agent_log_dir "$AGENT")" "$BRIDGE_SHARED_DIR"
cd "$WORK_DIR" || bridge_die "$WORK_DIR 디렉토리가 없습니다."

LOGFILE="$(bridge_agent_log_dir "$AGENT")/$(date '+%Y%m%d').log"
ERRFILE="$(bridge_agent_log_dir "$AGENT")/$(date '+%Y%m%d').err.log"
BRIDGE_RUN_ROSTER_SIGNATURE=""

log_line() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line" | tee -a "$LOGFILE"
}

log_loop_help() {
  bridge_run_session_attached || return 0
  log_line "tmux에서 쉘로 돌아가기: Ctrl-b 를 누른 뒤 d 를 누르세요."
  log_line "에이전트를 완전히 종료하기: 바깥 터미널에서 'agb kill ${AGENT}' 를 실행하세요."
}

bridge_run_session_attached() {
  local attached

  [[ -n "$SESSION" ]] || return 1
  attached="$(bridge_tmux_session_attached_count "$SESSION" 2>/dev/null || printf '0')"
  [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
  (( attached > 0 ))
}

bridge_run_detach_attached_clients() {
  [[ -n "$SESSION" ]] || return 0
  bridge_tmux_detach_clients "$SESSION" >/dev/null 2>&1 || true
}

bridge_run_stop_foreground_session() {
  if [[ "$(bridge_agent_source "$AGENT")" == "static" ]]; then
    bridge_agent_mark_manual_stop "$AGENT"
  fi
  bridge_agent_clear_idle_marker "$AGENT"
}

bridge_run_cleanup_mcp_orphans() {
  local min_age="${BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS:-0}"

  [[ "${BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED:-1}" == "1" ]] || return 0
  [[ "$min_age" =~ ^[0-9]+$ ]] || min_age=0

  # Incident #9770 Track 2: surgically reap THIS session's own codex
  # app-server + Pencil MCP subtree on clean pane exit. The pane is still
  # alive here (this runs in the exit handler before the tmux session is
  # gone), so a single resolve of the pane PID is race-free. Scoped to the
  # pane's descendants only — a live roster codex in a different pane is
  # never reachable. Fail-soft; must not block exit.
  if command -v bridge_codex_subtree_reap_for_session >/dev/null 2>&1; then
    bridge_codex_subtree_reap_for_session "$SESSION" "$AGENT" "session-exit:${AGENT}" \
      >/dev/null 2>&1 || true
  fi

  # Give orphaned MCP grandchildren a brief chance to be reparented to init
  # before scanning, otherwise the conservative detector can miss them.
  sleep 0.2
  bridge_mcp_orphan_cleanup "session-exit:${AGENT}" "$min_age" 1 >/dev/null 2>&1 || true
}

bridge_run_roster_signature() {
  local payload=""
  local file=""

  for file in "$BRIDGE_ROSTER_FILE" "$BRIDGE_ROSTER_LOCAL_FILE"; do
    payload+="${file}"$'\n'
    if [[ -f "$file" ]]; then
      payload+="present"$'\n'
      payload+="$(cat "$file")"$'\n'
    else
      payload+="missing"$'\n'
    fi
  done

  bridge_sha1 "$payload"
}

bridge_run_refresh_roster_if_changed() {
  local signature=""

  signature="$(bridge_run_roster_signature)"
  if [[ -n "$BRIDGE_RUN_ROSTER_SIGNATURE" && "$signature" == "$BRIDGE_RUN_ROSTER_SIGNATURE" ]]; then
    return 0
  fi

  # Issue #848: signature changed on disk — discard the per-process
  # cache so the next bridge_load_roster actually re-reads the files
  # instead of returning the cached pre-change state.
  bridge_roster_cache_invalidate
  bridge_load_roster
  bridge_require_agent "$AGENT"
  # PR-E: re-apply isolation umask after roster reload — bridge-lib.sh's
  # umask 077 is sticky across the process but a defensive re-set guards
  # against any subshell that may have reset it during the refresh.
  bridge_run_apply_v2_umask_if_needed "$AGENT"
  if [[ $CONTINUE_EXPLICIT -eq 1 ]]; then
    BRIDGE_AGENT_CONTINUE["$AGENT"]="$CONTINUE_MODE"
  fi
  WORK_DIR="$(bridge_agent_workdir "$AGENT")"
  ENGINE="$(bridge_agent_engine "$AGENT")"
  SESSION="$(bridge_agent_session "$AGENT")"
  [[ -n "$WORK_DIR" ]] || bridge_die "'$AGENT'의 workdir가 비어 있습니다."
  # Issue #1497 (#1498 r1): re-export the resolved-workdir scalar on the
  # roster-refresh relaunch path too. Without this, a relaunch that recomputes
  # WORK_DIR (e.g. the roster workdir changed) would leave child hooks
  # inheriting the STALE BRIDGE_AGENT_WORKDIR_RESOLVED from initial startup,
  # which hooks/bridge_hook_common.py prefers over the fresh roster/v2 answer —
  # re-introducing the handoff misrouting this fix removes.
  export BRIDGE_AGENT_WORKDIR="$WORK_DIR"
  export BRIDGE_AGENT_WORKDIR_RESOLVED="$WORK_DIR"
  # Issue #1497 (P1): mirror the workdir re-export above for the identity
  # home. A roster-refresh relaunch must not leave child hooks inheriting a
  # STALE BRIDGE_AGENT_HOME_RESOLVED from initial startup — the Python hook
  # reads it before the v2/legacy computation, so a stale value would
  # re-introduce the home mis-resolution this fix removes. Recomputed via the
  # same v2-aware resolver after the roster reload.
  export BRIDGE_AGENT_HOME_RESOLVED="$(bridge_agent_default_home "$AGENT")"
  cd "$WORK_DIR" || bridge_die "$WORK_DIR 디렉토리가 없습니다."
  if [[ -n "$BRIDGE_RUN_ROSTER_SIGNATURE" ]]; then
    log_line "[info] roster changed on disk; reloading before next relaunch"
  fi
  BRIDGE_RUN_ROSTER_SIGNATURE="$signature"
}

# Returns 0 if there is at least one open (queued/claimed/blocked) handoff
# task for the agent. Used by bridge_run_reconcile_next_session_state to
# preserve NEXT-SESSION.md while the next session has not yet acknowledged
# the handoff. find-open already excludes terminal states.
bridge_run_handoff_pending_for_agent() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  local found=""
  found="$(bridge_queue_cli find-open --agent "$agent" \
    --title-prefix "[bridge:handoff-pending]" --format id 2>/dev/null || true)"
  [[ -n "$found" ]]
}

bridge_run_reconcile_next_session_state() {
  local next_file=""
  local marker_file=""
  local age_seconds=""
  local ttl_seconds="${BRIDGE_NEXT_SESSION_AUTO_CLEAR_SECONDS:-300}"

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  next_file="$(bridge_agent_next_session_file "$AGENT")"
  [[ -f "$next_file" ]] || return 0

  if bridge_run_handoff_pending_for_agent "$AGENT"; then
    log_line "[info] NEXT-SESSION.md preserved — handoff task pending for $AGENT"
    return 0
  fi

  age_seconds="$(bridge_agent_maybe_expire_next_session "$AGENT" "$ttl_seconds" || true)"
  if [[ "$age_seconds" =~ ^[0-9]+$ ]]; then
    marker_file="$(bridge_agent_next_session_marker_file "$AGENT")"
    log_line "[info] auto-archived stale NEXT-SESSION.md after ${age_seconds}s (previous handoff digest was already delivered)"
    bridge_audit_log daemon next_session_autoarchived "$AGENT" \
      --detail age_seconds="$age_seconds" \
      --detail ttl_seconds="$ttl_seconds" \
      --detail next_session_file="$next_file" \
      --detail marker_file="$marker_file"
    return 0
  fi

  if [[ "$(bridge_agent_continue "$AGENT")" == "1" ]]; then
    log_line "[warn] NEXT-SESSION.md present at $next_file -> --resume suppressed for this restart. Delete it after handoff verification."
  fi
}

bridge_run_schedule_idle_marker_and_inbox_bootstrap() {
  local next_file="$WORK_DIR/NEXT-SESSION.md"
  local marker_file=""
  local previous_session_id="${1:-}"
  local auto_restart_wake=0

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  marker_file="$(bridge_agent_initial_inbox_marker_file "$AGENT")"

  # Issue #1639: a daemon/upgrade/watchdog auto-restart spawns a fresh Claude
  # session that opens FULLY IDLE — the SessionStart hook runs as a shell
  # process but its result only surfaces as a system-reminder on the NEXT user
  # message, so with no user turn the first turn never starts and queued/blocked
  # work stalls until a human types. bridge-start.sh propagates
  # BRIDGE_AUTO_RESTART_WAKE=1 ONLY on a non-interactive (auto-restart) launch
  # (ATTACH=0 — daemon, upgrade, `bridge-agent.sh restart` without --attach); an
  # operator-driven interactive `agent-bridge start`/attach (ATTACH=1) never sets
  # it, so this wake never fires under the operator's own eyes. We gate on
  # RESTART_COUNT==0 so it fires at most ONCE per launched loop (a crash-restart
  # iteration of the SAME loop has RESTART_COUNT>0 and is skipped), and we reuse
  # the existing inbox-bootstrap inject + #1199 nudge record below so the daemon
  # nudge tick treats the queued set as delivered and does NOT double-fire. The
  # firing branch is widened to fire even when the once-per-loop-lifetime
  # initial-inbox marker already exists (it persists on disk across restarts) —
  # that marker would otherwise suppress every post-first-launch auto-wake, which
  # is exactly the idle-session bug.
  if [[ "${BRIDGE_AUTO_RESTART_WAKE:-0}" == "1" \
        && "${BRIDGE_AGENT_LOOP_RESTART_COUNT:-0}" == "0" ]]; then
    auto_restart_wake=1
  fi

  # Issue #2003: a per-launch nonce so the restart-wake idempotency key's
  # session_identity fallback (`tmux:<session>:<nonce>`) is unique per launched
  # session when Claude session metadata is not yet available. A later restart
  # mints a new nonce, so a still-present handoff may legitimately wake again.
  local launch_nonce="${SRANDOM:-}${RANDOM}${RANDOM}-${EPOCHSECONDS:-$(date +%s)}-${BASHPID:-$$}"

  (
    "$BRIDGE_BASH_BIN" -lc '
      set -euo pipefail
      script_dir="$1"
      session="$2"
      agent="$3"
      marker_file="$4"
      next_file="$5"
      previous_session_id="$6"
      auto_restart_wake="$7"
      launch_nonce="${8:-}"
      source "$script_dir/bridge-lib.sh"
      if bridge_tmux_wait_for_prompt "$session" claude 30; then
        # Issue #1248 Lane A3: drop the `>/dev/null 2>&1 || true` swallow
        # that silently absorbed every persist-write failure (root
        # symptom: session_id never landed on disk, every subsequent
        # restart spawned a fresh Claude session). The function now
        # `bridge_die`s on a persistence write failure; let stderr reach
        # the parent subshell so the structured reason and the
        # [session-id] success breadcrumb both land in the agent log.
        # Suppress stdout (the captured id) — only stderr carries the
        # ops-visible signal we care about here.
        if [[ -f "$next_file" && -n "$previous_session_id" ]]; then
          bridge_refresh_agent_session_id "$agent" 24 0.5 "$previous_session_id" >/dev/null || true
        elif [[ -z "$(bridge_agent_session_id "$agent")" ]]; then
          # Claude session metadata can appear after tmux startup. Refresh once
          # more at prompt-ready time so static resume state is persisted before
          # the agent later goes inactive.
          bridge_refresh_agent_session_id "$agent" 24 0.5 >/dev/null || true
        fi
        bridge_agent_mark_idle_now "$agent"
        # ----------------------------------------------------------------------
        # Issue #2003 — post-restart wake decision (7-step order).
        #
        # The gate is the SAME as #1639: this branch only runs at all when the
        # whole inject is eligible — first-ever launch (marker absent) OR an
        # auto-restart (auto_restart_wake==1, which the parent already gated on
        # BRIDGE_AUTO_RESTART_WAKE=1 + LOOP_RESTART_COUNT==0). What #2003 fixes:
        # the OLD code suppressed the wake entirely whenever NEXT-SESSION.md
        # existed (`! -f "$next_file"`) AND fired the empty-queue kick only when
        # the persistent initial-inbox marker was absent — so a mature restarted
        # session with a handoff + empty queue sat idle forever. Now we ALWAYS
        # query the daemon-canonical queue state (even with a handoff present),
        # and a present NEXT-SESSION.md becomes a queue-backed wake instead of a
        # suppressor.
        #
        # Idempotency (2 layers): (1) queue-backed — the #1199 nudge key (the
        # queued id set, or the handoff task id) so the daemon nudge tick treats
        # the set as delivered and never double-fires; (2) queue-less fallback —
        # a per-(agent, session_identity, wake_kind, payload_digest) marker under
        # state/agents/<agent>/restart-wake/, checked immediately before the send
        # and written immediately after, so a queue-unavailable handoff wake
        # fires at most once per launched session.
        # ----------------------------------------------------------------------
        if [[ ! -f "$marker_file" ]] || [[ "$auto_restart_wake" == "1" ]]; then
          # session_identity: the refreshed Claude session id when available,
          # else a tmux+nonce identity unique to THIS launched session (so a
          # later restart with a still-present handoff may wake again).
          session_identity="$(bridge_agent_session_id "$agent" 2>/dev/null || true)"
          if [[ -n "$session_identity" ]]; then
            session_identity="claude:${session_identity}"
          else
            session_identity="tmux:${session}:${launch_nonce}"
          fi

          # STEP 1: ALWAYS query daemon-canonical nudge-live-state, even when a
          # NEXT-SESSION.md handoff exists. 4th TSV col = queued_top (highest-
          # priority QUEUED non-cron task), 3rd col = comma-join queued id CSV
          # byte-identical to the daemon nudge_key (#1639 codex r2 [P2]).
          queued_top=""
          queue_key=""
          if command -v bridge_with_timeout >/dev/null 2>&1; then
            nudge_state="$(bridge_with_timeout 15 inbox_bootstrap_nudge_key \
              python3 "$script_dir/bridge-daemon-helpers.py" \
              nudge-live-state "${BRIDGE_TASK_DB:-}" "$agent" 1 2>/dev/null)" || nudge_state=""
            if [[ -n "$nudge_state" ]]; then
              queue_key="$(printf "%s" "$nudge_state" | cut -f3)"
              queued_top="$(printf "%s" "$nudge_state" | cut -f4)"
            fi
          fi

          task_id=""
          wake_kind=""
          payload_digest="none"
          fallback_kick=0
          if [[ -n "$queued_top" ]]; then
            # STEP 2: genuinely-queued work. Surface the queued top + record the
            # queued dedup key (covers a SessionStart-created handoff task that
            # is already queued — #1199 suppresses the daemon double-fire).
            task_id="$queued_top"
            wake_kind="queued"
            payload_digest="$queue_key"
          else
            # STEP 3: no queued top — probe NON-CRON claimed|blocked OPEN work
            # (#1639 codex r3 [P2] / r4 cron-exclusion). Record NO dedup key
            # (daemon nudges only queued). Preserves existing #1639 behavior.
            task_id="$(bridge_queue_cli find-open --agent "$agent" --status-filter claimed --status-filter blocked --exclude-title-prefix '[cron-dispatch]' 2>/dev/null | head -n 1 || true)"
            if [[ -n "$task_id" ]]; then
              wake_kind="claimed-blocked"
              queue_key=""
              payload_digest="none"
            elif [[ -f "$next_file" ]]; then
              # STEP 4: a NEXT-SESSION.md handoff is present and no open work was
              # found. Find/create the EXACT handoff task the SessionStart hook
              # uses (same digest + title contract) so the restart wake is
              # queue-backed + daemon-deduped. Either the hook already created it
              # (find-open returns it) or we create it — both converge on one
              # open task and one nudge key.
              wake_kind="handoff"
              payload_digest="$(bridge_agent_next_session_digest "$agent" 2>/dev/null || printf "none")"
              handoff_id="$(bridge_run_handoff_task_find_or_create "$agent" "$next_file" 2>/dev/null || true)"
              if [[ -n "$handoff_id" ]]; then
                task_id="$handoff_id"
                queue_key="$handoff_id"
              else
                # STEP 5: queue access failed — cannot make the wake queue-backed.
                # Fall back to a per-session restart-wake marker latch so we send
                # ONE handoff-resume kick per launched session + handoff digest.
                queue_key=""
                fallback_kick=1
              fi
            elif [[ "$auto_restart_wake" == "1" && ! -f "$marker_file" ]]; then
              # STEP 6: no NEXT-SESSION, no open work, first-ever launch
              # (marker absent) — the minimal first-launch session-resumed kick.
              wake_kind="first-launch-empty"
              payload_digest="none"
              fallback_kick=1
            fi
            # STEP 7 (implicit): no NEXT-SESSION, no open work, marker present —
            # task_id stays empty + fallback_kick stays 0 → nothing is sent.
          fi

          # The fallback idempotency latch path (queue-less handoff wake / first-
          # launch kick): only fire if the per-session marker is absent, then
          # write it immediately after a successful send.
          restart_wake_marker=""
          if (( fallback_kick == 1 )); then
            restart_wake_marker="$(bridge_agent_restart_wake_marker_file "$agent" "$session_identity" "$wake_kind" "$payload_digest")"
            if [[ -f "$restart_wake_marker" ]]; then
              # Already woke this launched session for this exact wake — skip.
              fallback_kick=0
              task_id=""
            fi
          fi

          if [[ -n "$task_id" ]]; then
            if bridge_inject_metadata_only_enabled; then
              inject_text="$(bridge_format_injection_meta inbox-bootstrap agent="$agent" top="$task_id")"
            else
              inject_text="[Agent Bridge] ACTION REQUIRED — open tasks detected. Run exactly: ~/.agent-bridge/agb inbox $agent"
            fi
            bridge_tmux_send_and_submit "$session" claude "$inject_text" "$agent"
            # Record the queued/handoff set as nudged so the daemon nudge tick
            # treats it as delivered (last_nudge_key byte-matches the daemon
            # nudge_key). Set for queued work AND for a queue-backed handoff wake.
            if [[ -n "$queue_key" ]]; then
              bridge_task_note_nudge "$agent" "$queue_key" >/dev/null 2>&1 || true
            fi
          elif (( fallback_kick == 1 )); then
            # Queue-less handoff wake (STEP 5) or first-launch empty kick (STEP
            # 6). Send ONE minimal resume kick and latch the per-session marker.
            if [[ "$wake_kind" == "handoff" ]]; then
              if bridge_inject_metadata_only_enabled; then
                inject_text="$(bridge_format_injection_meta handoff-resume agent="$agent" reason=auto-restart)"
              else
                inject_text="[Agent Bridge] session resumed after an automatic restart — a NEXT-SESSION.md handoff is pending. Read NEXT-SESSION.md, execute its checklist, and notify the operator. Then check your queue: ~/.agent-bridge/agb inbox $agent"
              fi
            else
              if bridge_inject_metadata_only_enabled; then
                inject_text="$(bridge_format_injection_meta session-resumed agent="$agent" reason=auto-restart)"
              else
                inject_text="[Agent Bridge] session resumed after an automatic restart — re-read your session onboarding (SOUL.md / CLAUDE.md / NEXT-SESSION.md) and check your queue: ~/.agent-bridge/agb inbox $agent"
              fi
            fi
            bridge_tmux_send_and_submit "$session" claude "$inject_text" "$agent"
            if [[ -n "$restart_wake_marker" ]]; then
              mkdir -p "$(dirname "$restart_wake_marker")" 2>/dev/null || true
              printf "%s\n" "$(date +%s)" >"$restart_wake_marker" 2>/dev/null || true
            fi
          fi
          # Preserve the once-per-loop-lifetime initial-inbox marker for the
          # first-launch branch. The auto-restart wake reuses the #1199 nudge
          # dedup + the per-session restart-wake latch, so it never needs (or
          # writes) the once-per-lifetime marker — never rewrite it on a mature
          # restart (#2003: must not reuse initial-inbox.started for handoff).
          if [[ ! -f "$marker_file" ]]; then
            mkdir -p "$(dirname "$marker_file")"
            printf "%s\n" "$(date +%s)" >"$marker_file"
          fi
        fi
      fi
    ' -- "$SCRIPT_DIR" "$SESSION" "$AGENT" "$marker_file" "$next_file" "$previous_session_id" "$auto_restart_wake" "$launch_nonce"
  ) </dev/null >/dev/null 2>>"$ERRFILE" &
}

bridge_run_should_auto_accept_dev_channels() {
  local launch_cmd="$1"
  local effective=""

  [[ "$ENGINE" == "claude" ]] || return 1
  [[ $SAFE_MODE -eq 0 ]] || return 1
  # Presence of --dangerously-load-development-channels in the launch cmd
  # is itself the operator's explicit opt-in; the warning picker is a
  # confirmation of that same decision. Auto-accept whenever any dev
  # channel is extracted from the cmd, regardless of the per-agent
  # allowlist or isolation mode. PR #364 r2 originally gated this on the
  # bridge_agent_auto_accept_dev_channels_csv allowlist, which silently
  # excluded non-isolated agents whose roster had a non-default override
  # (issue #410: sales_sean stalled indefinitely on the picker on cold
  # start because the per-agent allowlist did not intersect the loaded
  # dev channels).
  effective="$(bridge_extract_development_channels_from_command "$launch_cmd")"
  [[ -n "$effective" ]] || return 1
  return 0
}

bridge_run_schedule_dev_channels_accept() {
  local launch_cmd="$1"

  bridge_run_should_auto_accept_dev_channels "$launch_cmd" || return 0

  if [[ "${BRIDGE_CONTROLLER_DEV_CHANNELS_ACCEPT:-0}" == "1" ]]; then
    log_line "[info] controller-side Claude development-channels auto-accept armed; skipping agent-side watcher"
    return 0
  fi

  # Operator-tunable timeout. Default 60s covers 4-plugin cold-start
  # (bun teams + bun ms365 + node cosmax-* MCP servers) on isolated
  # linux-user agents where claude takes longer than the historic 15s
  # budget to draw the development-channels picker. Reduce to 5–15s in
  # diagnosis to fail-loud quickly.
  local accept_timeout="${BRIDGE_RUN_DEV_CHANNELS_ACCEPT_TIMEOUT_SECONDS:-60}"
  [[ "$accept_timeout" =~ ^[0-9]+$ ]] || accept_timeout=60
  (( accept_timeout > 0 )) || accept_timeout=60

  log_line "[info] auto-accepting Claude development-channels prompt for allowlisted dev channel(s) (timeout=${accept_timeout}s)"

  # Background child must not silently swallow stderr — that hid every
  # picker-stuck warning before. Route its output to the agent log files
  # the parent already maintains so wait_for_prompt's bridge_warn lines
  # land where operators look. accept_timeout is passed in as $3 because
  # the child runs in a fresh `bash -lc` shell with `set -u` — outer
  # locals are not visible.
  (
    "$BRIDGE_BASH_BIN" -lc '
      set -euo pipefail
      script_dir="$1"
      session="$2"
      accept_timeout="$3"
      source "$script_dir/bridge-lib.sh"
      if ! bridge_tmux_wait_for_prompt "$session" claude "$accept_timeout" 1; then
        printf "[%s] [warn] auto-accept dev-channels: bridge_tmux_wait_for_prompt failed/timeout on session=%s\n" \
          "$(date "+%Y-%m-%d %H:%M:%S")" "$session" >&2
      fi
    ' -- "$SCRIPT_DIR" "$SESSION" "$accept_timeout"
  ) </dev/null >>"$LOGFILE" 2>>"$ERRFILE" &
}

bridge_run_agent_claude_root() {
  # Resolve the Claude config root the launched agent will actually use.
  # Keep this in one place so the dev-plugin cache sync and plugin enable
  # preflight operate on the same CLAUDE_CONFIG_DIR as the final
  # LAUNCH_CMD. Shared agents inherit the operator HOME for generic
  # ~/.config tools, but Claude state remains per-agent via
  # CLAUDE_CONFIG_DIR.
  local _agent_os_user_local=""

  if command -v bridge_agent_claude_config_dir >/dev/null 2>&1; then
    bridge_agent_claude_config_dir "$AGENT"
    return 0
  fi

  if ! bridge_isolation_disabled_by_env && bridge_agent_linux_user_isolation_effective "$AGENT"; then
    _agent_os_user_local="$(bridge_agent_os_user "$AGENT")"
    printf '%s/.claude' "$(bridge_agent_linux_user_home "$_agent_os_user_local")"
  else
    printf '%s/.claude' "$(bridge_agent_default_home "$AGENT")"
  fi
}

bridge_run_claude_keychain_free_preflight() {
  local platform=""
  local helper_path=""
  local config_dir=""
  local settings_file=""
  local registry_path=""
  local ttl_ms=""

  # #1520 r3 (codex Phase-4 BLOCKING): a "proven keychain-free" signal for the
  # shared-launch credential guard. Reset every call so a non-Darwin /
  # unvalidated path leaves it 0; it is set to 1 ONLY after the full Darwin
  # settings/helper/registry validation below passes. The guard then treats
  # keychain-free as export-safe-without-credential ONLY when this is 1 —
  # never on the enable flag alone (which is platform-blind env/config), so a
  # non-Darwin agent where this function early-returns without validating
  # falls through to seed/recheck/skip-export instead of exporting an empty
  # per-agent dir.
  BRIDGE_RUN_CLAUDE_KEYCHAIN_FREE_VALIDATED=0

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  # Issue #1890: dynamic vanilla Claude authenticates from the operator-global
  # ~/.claude (no per-agent config dir, no per-agent settings.json / apiKeyHelper
  # / .credentials.json). The keychain-free preflight validates a PER-AGENT
  # settings.json and bridge_dies when it is absent — which it always is for a
  # passthrough agent. Skip it: vanilla Claude resolves the operator's own auth.
  if command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 \
     && bridge_agent_is_dynamic_vanilla_claude "$AGENT"; then
    return 0
  fi
  bridge_claude_keychain_free_auth_enabled || return 0
  ttl_ms="$(bridge_claude_api_key_helper_ttl_ms)"
  export CLAUDE_CODE_API_KEY_HELPER_TTL_MS="$ttl_ms"

  platform="$(bridge_host_platform 2>/dev/null || uname -s 2>/dev/null || printf '')"
  [[ "$platform" == "Darwin" ]] || return 0

  # #1444 BLOCKING 1 (defense-in-depth): the credential vars were already
  # captured + unset at the top of this script BEFORE `source bridge-lib.sh`, and
  # the post-source restore block deliberately did NOT restore them on this
  # keychain-free + Darwin path — so they are already absent here. This redundant
  # unset is a belt-and-suspenders guard in case any code between source and this
  # preflight re-introduced one of them; it keeps the keychain-free child env
  # provably clean (the launched Claude authenticates via the apiKeyHelper /
  # .credentials.json, never the ambient env token).
  unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

  bridge_require_python
  helper_path="$(bridge_claude_api_key_helper_path)"
  [[ -f "$helper_path" && -x "$helper_path" ]] \
    || bridge_die "Claude keychain-free auth is enabled but apiKeyHelper is not executable: $helper_path"

  config_dir="$(bridge_run_agent_claude_root)"
  settings_file="$config_dir/settings.json"
  [[ -f "$settings_file" ]] \
    || bridge_die "Claude keychain-free auth is enabled but settings.json is missing: $settings_file"

  if ! python3 "$SCRIPT_DIR/scripts/python-helpers/validate-claude-apikeyhelper-settings.py" \
      "$settings_file" "$helper_path"; then
    bridge_die "Claude keychain-free auth is enabled but settings.json does not point at apiKeyHelper: $settings_file"
  fi

  registry_path="$(bridge_claude_token_registry_path)"
  if ! python3 "$SCRIPT_DIR/bridge-auth.py" \
      --registry "$registry_path" \
      api-key-helper --check >/dev/null; then
    bridge_die "Claude keychain-free auth is enabled but no active registry OAT is available"
  fi

  # #1520 r3: every keychain-free precondition validated on this platform
  # (Darwin + executable apiKeyHelper + settings.json pointing at it + an
  # active registry OAT). The apiKeyHelper supplies the token at launch, so a
  # missing per-agent `.credentials.json` is expected and the shared-launch
  # guard may export the per-agent CLAUDE_CONFIG_DIR without seeding one.
  BRIDGE_RUN_CLAUDE_KEYCHAIN_FREE_VALIDATED=1
}

# shellcheck disable=SC2030,SC2031 # plugin preflight intentionally scopes env to this subshell.
bridge_run_ensure_claude_launch_channel_plugins() {
  local agent_claude_root=""
  local agent_home=""

  # Issue #1890: dynamic vanilla Claude has no per-agent config dir — it
  # inherits the operator-global ~/.claude (settings / plugins / MCP). Enabling
  # channel plugins into the unused per-agent dir (and re-pointing HOME /
  # CLAUDE_CONFIG_DIR there) would both be a no-op for the launched process and
  # defeat the global passthrough. Skip it; the operator-global plugin set is
  # what the agent runs with.
  if command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 \
     && bridge_agent_is_dynamic_vanilla_claude "$AGENT"; then
    return 0
  fi

  agent_claude_root="$(bridge_run_agent_claude_root)"
  if command -v bridge_agent_claude_home_dir >/dev/null 2>&1; then
    agent_home="$(bridge_agent_claude_home_dir "$AGENT" 2>/dev/null || true)"
  fi
  if [[ -z "$agent_home" ]]; then
    agent_home="${agent_claude_root%/.claude}"
  fi
  (
    export HOME="$agent_home"
    # SC2030: subshell-local export is intentional — it scopes HOME /
    # CLAUDE_CONFIG_DIR to the plugin-enable preflight only (see the
    # matching #1520 export in bridge_run_shared_launch below).
    # shellcheck disable=SC2030
    export CLAUDE_CONFIG_DIR="$agent_claude_root"
    bridge_ensure_claude_launch_channel_plugins "$AGENT"
  )
}

# Per-process sentinel for the #1520 r3 one-time degrade warning. bridge-run.sh
# is one long-lived process per agent relaunch loop, so a process-scoped
# associative array keyed by agent id de-duplicates the skip-export warning
# across every loop iteration without a guard file. (Not exported — exporting
# an associative array silently breaks; see the BRIDGE_AGENT_ISOLATION_MODE
# collision footgun.)
declare -A BRIDGE_RUN_DEGRADE_WARNED=()

# bridge_run_warn_once <agent> <message>
#
# Emit <message> via log_line at most once per <agent> for the lifetime of
# this process. Used by the shared-launch skip-export degrade path so a
# persistently-unseedable agent does not spam the log on every relaunch
# (bridge-run.sh's while-true loop re-enters bridge_run_shared_launch every
# iteration).
bridge_run_warn_once() {
  local _agent="$1"
  local _msg="$2"
  [[ -n "${BRIDGE_RUN_DEGRADE_WARNED[$_agent]:-}" ]] && return 0
  BRIDGE_RUN_DEGRADE_WARNED["$_agent"]=1
  log_line "$_msg"
}

# bridge_run_ensure_shared_claude_credential <agent_claude_root>
#
# Issue #1520 r2 (codex Phase-4 BLOCKING) — guard the CLAUDE_CONFIG_DIR
# export against stranding a shared agent authless.
#
# The export points the launched `claude` at its per-agent config dir. That
# is only safe if the dir actually holds the credential `claude` needs.
# Static shared Claude agents get their per-agent `.credentials.json`
# populated by the daemon's periodic `claude-token sync` (default scope
# `static`). Shared DYNAMIC Claude agents do NOT: dynamic create seeds only
# `.claude.json` (first-run config), and the daemon sync's static-only
# default skips BRIDGE_AGENT_SOURCE != static. So a previously
# operator-global-authed dynamic agent would restart pointed at an empty
# per-agent dir and lose auth.
#
# Fix: seed-at-launch-if-missing. Before exporting, if the per-agent
# credential file is absent, run a single-agent `claude-token sync` for THIS
# agent (the explicit-CSV `--agents <agent>` spec bypasses the static-only
# selector — see bridge_auth_selected_agents) which reuses the production
# credential resolver + controller-credentials fallback and writes the file
# at 0600 via bridge-auth.py's atomic writer. Works for static AND dynamic;
# no sync-default change, no hand-rolled secret copying.
#
# Returns 0 when the export is safe (credential present, OR a PROVEN
# keychain-free launch where `.credentials.json` is intentionally absent and
# the keychain-free preflight positively validated settings.json -> apiKeyHelper
# -> registry OAT on this platform). Returns 1 when the per-agent dir has no
# usable credential and could not be seeded (e.g. operator never authed) — the
# caller then SKIPS the export so a previously-working operator-global launch
# is not broken (graceful degrade).
bridge_run_ensure_shared_claude_credential() {
  local _claude_root="$1"
  local _cred_file="$_claude_root/.credentials.json"

  # Keychain-free auth: the per-agent dir authenticates via the apiKeyHelper
  # wired into settings.json, not a credential file — so a missing credential
  # file is expected and the export is safe WITHOUT seeding one.
  #
  # #1520 r3 (codex Phase-4 BLOCKING): gate this fast-path on the PROVEN
  # keychain-free state, NOT on bridge_claude_keychain_free_auth_enabled. The
  # enable flag is platform-blind env/config; bridge_run_claude_keychain_free_-
  # preflight early-returns on non-Darwin WITHOUT validating settings/helper/
  # registry, yet leaves the flag enabled. Trusting the flag alone would export
  # an UNAUTHENTICATED empty per-agent dir on a non-Darwin host. The preflight
  # sets BRIDGE_RUN_CLAUDE_KEYCHAIN_FREE_VALIDATED=1 only after it has
  # positively validated keychain-free on this platform; anything else (non-
  # Darwin, unvalidated, preflight not run) leaves it 0 and falls through to
  # the seed -> recheck -> export-if-present -> else skip-export path below.
  if [[ "${BRIDGE_RUN_CLAUDE_KEYCHAIN_FREE_VALIDATED:-0}" == "1" ]]; then
    return 0
  fi

  # Already seeded (static agents, or a dynamic agent seeded on a prior pass).
  [[ -f "$_cred_file" ]] && return 0

  # Missing — seed THIS agent specifically (bypasses the static-only default).
  # Best-effort + time-boxed: a sync failure must not wedge the launch loop.
  bridge_with_timeout 20 shared_claude_credential_seed \
    "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/bridge-auth.sh" claude-token sync \
    --agents "$AGENT" --json >/dev/null 2>&1 || true

  # Re-check: only report "safe to export" if the file now exists.
  [[ -f "$_cred_file" ]] && return 0
  return 1
}

# bridge_run_apply_codex_ambient_env
#
# #1470 Phase 2 (Q6) — the Codex ambient-key restore DECISION, run inside
# the launch subshell right before the agent process forks (so the export
# scopes to the launched child only, never the long-lived relaunch loop).
#
# At process entry bridge-run.sh ACTIVE-SCRUBBED the OpenAI-key + Codex-
# access-token env vars into the NON-exported _bridge_run_tok_openai /
# _bridge_run_tok_codex shell vars (they rode the fd-9 transit across the
# privileged re-exec and were restored into those vars there). This helper
# decides whether to put them BACK into the launched child's env:
#
#   - MANAGED Codex agent (the default for any roster Codex agent): the
#     bridge delivers the subscription auth.json as a FILE the `codex`
#     binary reads from CODEX_HOME (= <agent_home>/.codex, because the
#     launch sets HOME to the agent home). The ambient key must NOT be
#     restored — a stale/foreign OPENAI_API_KEY / CODEX_ACCESS_TOKEN in
#     the env would silently override the file login. Keep them ABSENT.
#   - EXPLICITLY UNMANAGED / operator-owned Codex run
#     (BRIDGE_CODEX_UNMANAGED_AUTH=1, or a non-Codex agent that legitimately
#     carried these vars): restore so the operator's own ambient auth still
#     works. This is the warn-only escape hatch the design permits.
#   - NON-Codex agent: no-op (the vars were never relevant; they stay
#     absent, which is the correct token-free child env).
#
# Values are NEVER logged. Builtin-only branch + export; no fork.
bridge_run_apply_codex_ambient_env() {
  # Nothing captured → nothing to decide.
  [[ -n "${_bridge_run_tok_openai:-}${_bridge_run_tok_codex:-}" ]] || return 0

  if [[ "$ENGINE" == "codex" ]]; then
    if [[ "${BRIDGE_CODEX_UNMANAGED_AUTH:-0}" == "1" ]]; then
      # Explicit operator opt-out: this Codex run authenticates from the
      # ambient env, not a bridge-delivered auth.json. Restore + warn once.
      [[ -n "${_bridge_run_tok_openai:-}" ]] && export OPENAI_API_KEY="$_bridge_run_tok_openai"
      [[ -n "${_bridge_run_tok_codex:-}" ]] && export CODEX_ACCESS_TOKEN="$_bridge_run_tok_codex"
      bridge_run_warn_once "$AGENT" \
        "[warn] ${AGENT}: BRIDGE_CODEX_UNMANAGED_AUTH=1 — launching Codex with the ambient OpenAI-key / Codex-token env vars RESTORED (operator-owned auth, NOT bridge-managed). Unset BRIDGE_CODEX_UNMANAGED_AUTH and run 'agent-bridge auth codex-cred sync' to switch this agent to the managed file-login fleet."
    fi
    # MANAGED (default): do nothing — the vars stay scrubbed so the
    # bridge-delivered .codex/auth.json is the sole credential.
    return 0
  fi
  # Non-Codex agent that happened to inherit these vars: a managed Claude/
  # antigravity child has no use for them; leave them absent (token-free).
  return 0
}

# bridge_run_shared_launch <bash_bin> <launch_cmd> <errfile>
#
# Issue #1520 — final-launch site for the shared (non v2-secret-env) path.
# Mirrors the v2 secret-env exec branch's job of getting the per-agent
# CLAUDE_CONFIG_DIR onto the launched `claude` process, but for shared-mode
# (isolation_mode: shared, non linux-user) Claude agents that never go
# through bridge_isolation_v2_exec_with_secret_env.
#
# Without this, a shared Claude agent launched `"$bash_bin" -lc "$cmd"` with
# CLAUDE_CONFIG_DIR unset, so Claude fell back to HOME-default config = the
# operator's global ~/.claude.json. Per-agent user-scope MCP / settings /
# credential isolation (which the bridge pre-seeds into
# bridge_agent_claude_config_dir = <agent-home>/.claude) was silently
# ignored. Exporting the resolved per-agent config dir here makes the fix
# apply to BOTH newly-created AND existing shared agents on (re)start — it
# rides the launch path, not a scaffold-time launch_cmd prefix that would
# miss agents created before this change.
#
# Extracted as a function (matching the bridge_isolation_v2_exec_with_secret_env
# rationale at lib/bridge-isolation-v2.sh) so the smoke test exercises the
# EXACT production code path that constructs the child's launch env.
#
# Contract:
#   - Claude only. Codex agents take the same shared else-branch but must
#     NOT receive CLAUDE_CONFIG_DIR; gate on ENGINE == claude.
#   - Export CLAUDE_CONFIG_DIR ONLY. HOME stays the operator/shared home in
#     shared mode (unlike the plugin-preflight subshell above, which repoints
#     HOME for its plugin-enable work). Repointing HOME for a shared agent
#     would move every HOME-relative read off the operator's home and is
#     explicitly out of scope for #1520.
#   - The export runs in the same subshell that runs the launch, so it never
#     pollutes the long-lived parent (the relaunch loop).
#   - r2 (codex Phase-4): the export only fires when the per-agent dir holds a
#     usable credential (bridge_run_ensure_shared_claude_credential seeds it
#     on demand for static AND dynamic agents). If it cannot, the launch falls
#     back to the pre-#1520 operator-global path so a previously-authed agent
#     is never stranded.
#   - Returns the child's exit code.
bridge_run_shared_launch() {
  local _bash_bin="$1"
  local _launch_cmd="$2"
  local _errfile="$3"
  local _agent_claude_root=""

  if [[ "$ENGINE" == "claude" ]] \
     && command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 \
     && bridge_agent_is_dynamic_vanilla_claude "$AGENT"; then
    # Issue #1890: dynamic vanilla Claude inherits the operator-global
    # ~/.claude (model / settings / plugins / MCP / credentials). Skip BOTH the
    # per-agent CLAUDE_CONFIG_DIR export AND the per-agent credential seed:
    # leaving _agent_claude_root empty falls through to the no-export branch
    # below so the launched `claude` resolves config from $HOME/.claude exactly
    # like the operator typing `claude` in this workdir. Do NOT seed a
    # per-agent credential — vanilla resolves the operator's own auth.
    _agent_claude_root=""
  elif [[ "$ENGINE" == "claude" ]]; then
    _agent_claude_root="$(bridge_run_agent_claude_root)"
    # r2: gate the export on the per-agent dir actually being authed. If the
    # credential is missing AND cannot be seeded, clear the root so we skip
    # the export and launch against the operator-global config as before.
    if [[ -n "$_agent_claude_root" ]] \
        && ! bridge_run_ensure_shared_claude_credential "$_agent_claude_root"; then
      # r3: warn at most once per agent per process — the relaunch loop
      # re-enters this skip-export path every iteration, so an unconditional
      # log_line here spams the log. The functional fallback (skip export ->
      # operator-global launch) is unchanged; only the warning is de-duped.
      bridge_run_warn_once "$AGENT" \
        "[warn] ${AGENT}: per-agent Claude credential missing and could not be seeded at $_agent_claude_root/.credentials.json — launching against the operator-global config (CLAUDE_CONFIG_DIR not set). Run 'agent-bridge auth claude-token sync --agents ${AGENT}' once the controller is authed to enable per-agent config isolation."
      _agent_claude_root=""
    fi
  fi

  local _rc=0
  if [[ -n "$_agent_claude_root" ]]; then
    if (
      # SC2030/SC2031: the subshell-local export is the point — it scopes
      # CLAUDE_CONFIG_DIR to the exec'd child only, never the relaunch loop.
      # shellcheck disable=SC2030,SC2031
      export CLAUDE_CONFIG_DIR="$_agent_claude_root"
      exec "$_bash_bin" -lc "$_launch_cmd"
    ) 2> >(tee -a "$_errfile" >&2); then
      _rc=0
    else
      _rc=$?
    fi
  else
    # Non-Claude (e.g. codex) shared launch — no CLAUDE_CONFIG_DIR export.
    # #1470 Phase 2 (Q6): apply the Codex ambient-key restore DECISION inside
    # the launch subshell so any export scopes to the exec'd child only. For a
    # MANAGED Codex agent (default) this is a no-op — the OpenAI-key / Codex-
    # token env vars stay scrubbed so the bridge-delivered .codex/auth.json is
    # the sole credential; for the explicit unmanaged opt-out it restores them.
    if (
      # shellcheck disable=SC2030,SC2031  # subshell-local export scopes to the exec'd child
      bridge_run_apply_codex_ambient_env
      exec "$_bash_bin" -lc "$_launch_cmd"
    ) 2> >(tee -a "$_errfile" >&2); then
      _rc=0
    else
      _rc=$?
    fi
  fi
  return "$_rc"
}

# shellcheck disable=SC2030,SC2031 # launch env export is intentional for the child command below.
bridge_run_export_claude_launch_env() {
  local agent_claude_root=""
  local agent_home=""

  [[ "$ENGINE" == "claude" ]] || return 0

  # Issue #1890: dynamic vanilla Claude must run with the OPERATOR HOME so
  # `~/.claude` resolves to the operator-global tree (model / settings /
  # plugins / MCP / session history / credentials), exactly like the operator
  # typing `claude` in this workdir. Without this it would inherit
  # HOME=<agent-home> (the scaffolded per-agent home under BRIDGE_AGENT_HOME_-
  # ROOT) and see none of the operator global config — the very bug #1890 fixes.
  if command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 \
     && bridge_agent_is_dynamic_vanilla_claude "$AGENT"; then
    local _operator_home=""
    if command -v bridge_agent_operator_home_dir >/dev/null 2>&1; then
      _operator_home="$(bridge_agent_operator_home_dir 2>/dev/null || true)"
    fi
    [[ -n "$_operator_home" ]] && export HOME="$_operator_home"
    return 0
  fi

  agent_claude_root="$(bridge_run_agent_claude_root)"
  if command -v bridge_agent_claude_home_dir >/dev/null 2>&1; then
    agent_home="$(bridge_agent_claude_home_dir "$AGENT" 2>/dev/null || true)"
  fi
  if [[ -z "$agent_home" ]]; then
    agent_home="${agent_claude_root%/.claude}"
  fi
  # #1621/#1622: export the operator HOME ONLY. CLAUDE_CONFIG_DIR is owned by
  # bridge_run_shared_launch's exec subshell (#1520) — it exports the per-agent
  # config dir ONLY when the credential gate passes, and intentionally leaves
  # it UNSET on the failed-seed graceful-degrade path so the launch falls back
  # to the operator-global config ($HOME/.claude). Exporting CLAUDE_CONFIG_DIR
  # here in the long-lived parent loop would leak into that degrade subshell
  # and defeat the #1520 fallback (codex Phase-4 BLOCKING). HOME-only keeps the
  # two concerns cleanly split: this sets shared HOME=operator; shared_launch
  # decides CLAUDE_CONFIG_DIR per-agent-vs-degrade.
  [[ -n "$agent_home" ]] && export HOME="$agent_home"
}

# shellcheck disable=SC2030,SC2031 # launch env export is intentional for the child command below.
bridge_run_export_codex_launch_env() {
  [[ "$ENGINE" == "codex" ]] || return 0

  # Issue #1899: a dynamic vanilla Codex agent must run against the operator-
  # global ~/.codex (config.toml model/profile, auth.json, sessions/), exactly
  # like the operator typing `codex` in this workdir. Pin BOTH:
  #   - HOME = operator home, so any HOME-relative read resolves to the operator
  #     tree (and the default CODEX_HOME = $HOME/.codex lands there);
  #   - CODEX_HOME = <operator_home>/.codex EXPLICITLY, so even a future
  #     HOME repoint cannot make CODEX_HOME become <agent_home>/.codex (the
  #     invariant #1899 protects).
  # CODEX_SQLITE_HOME is intentionally left untouched (unset unless the operator
  # already exported it). Managed/static/admin Codex and iso-v2 Codex are
  # excluded by the predicate and keep their per-agent CODEX_HOME behavior.
  if command -v bridge_agent_is_dynamic_vanilla_codex >/dev/null 2>&1 \
     && bridge_agent_is_dynamic_vanilla_codex "$AGENT"; then
    local _operator_home=""
    if command -v bridge_agent_operator_home_dir >/dev/null 2>&1; then
      _operator_home="$(bridge_agent_operator_home_dir 2>/dev/null || true)"
    fi
    if [[ -n "$_operator_home" ]]; then
      export HOME="$_operator_home"
      export CODEX_HOME="$_operator_home/.codex"
    fi
    return 0
  fi
  # Managed/static/admin Codex: no-op. HOME / CODEX_HOME are resolved by the
  # existing managed path (iso-v2 secret-env loader sets HOME = iso UID home;
  # shared mode inherits the operator HOME), unchanged from pre-#1899.
  return 0
}

bridge_run_ledger_has_snapshot() {
  # Issue #1857: true when the bridge-owned grant ledger at $1 records a
  # non-empty `installed_snapshot.plugins` map (an operator recovery snapshot
  # worth a recovery-only manifest pass even with zero channel-declared
  # plugins). Best-effort: a missing/unreadable/legacy `{"channels":[...]}`
  # ledger returns non-zero.
  local ledger="$1"
  [[ -n "$ledger" && -f "$ledger" && -r "$ledger" ]] || return 1
  python3 - "$ledger" <<'PY'
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

bridge_run_manifest_has_plugins() {
  # Issue #1857 (BLOCKER 2): true when the agent's live
  # installed_plugins.json at $1 records a NON-EMPTY `plugins` map. A
  # brownfield dynamic agent with only operator-installed (ad-hoc) plugins
  # and NO plugin: channels must still reach the Python seed path so the
  # FIRST recovery snapshot is taken BEFORE its first #1854 `--replace`
  # restart wipe — otherwise recovery has nothing to restore. The empty/
  # missing/unparseable manifest returns non-zero (genuinely nothing to
  # snapshot). Runs as the launching identity (iso UID or controller), so a
  # plain file read on the running UID's own view is correct here.
  local manifest="$1"
  [[ -n "$manifest" && -f "$manifest" && -r "$manifest" ]] || return 1
  python3 - "$manifest" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)
plugins = data.get("plugins") if isinstance(data, dict) else None
sys.exit(0 if isinstance(plugins, dict) and plugins else 1)
PY
}

bridge_run_fleet_default_unsafe_reason() {
  # Issue #1857 (spec v3 Δ3, class-b): return a non-empty reason on stdout
  # when a fleet-default declaration token is structurally UNSAFE (path
  # traversal / reserved component / separator in the `<plugin>@<marketplace>`
  # identity that later forms a filesystem-resolvable catalog/manifest key).
  # Class-(b) unsafe validation is fail-closed for ALL classes and MUST run
  # BEFORE any path join or convergence write — a malformed marketplace/plugin
  # identity that could escape the catalog path is a security stop, never an
  # availability degrade. Mirrors the Python `_manifest_entry_unsafe_reason`
  # gate (lib parity: bridge-dev-plugin-cache.py) so the bash launch-path
  # validator and the Python writer agree on what is unsafe. Empty stdout =
  # safe (may still be class-(a) malformed or class-(c) unavailable, handled
  # downstream as warn-only).
  local token="$1"
  local plugin="" marketplace=""
  # Split `plugin@marketplace`; a bare token (no `@`) is qualified to the
  # agent-bridge marketplace downstream, so validate the plugin half here.
  if [[ "$token" == *"@"* ]]; then
    plugin="${token%%@*}"
    marketplace="${token#*@}"
  else
    plugin="$token"
    marketplace=""
  fi
  # PARITY CONTRACT (Issue #1857 gate-2 r4): this per-half safe-component check
  # MUST mirror the Python `_alias_rejection_reason` gate in
  # bridge-dev-plugin-cache.py (the same value about to become a filesystem
  # path component in the catalog/manifest write). Because the bash launch-path
  # validator runs FIRST and fail-closes BEFORE any convergence write, any
  # unsafe half the Python side would reject but bash folds would let a valid
  # earlier token converge before the Python raise — violating the
  # fail-closed-before-any-write intent. The Python rules for a NON-EMPTY half:
  #   1. characters outside [A-Za-z0-9._-]   (catches `/`, `\`, `*`, space, AND
  #      a leftover `@` from a multiple-`@` token like `good@market@extra`),
  #   2. contains `..` as a SUBSTRING        (catches `good..bad`, `../evil`),
  #   3. reserved name `.`/`..`              (subsumed by 1/2 but explicit),
  #   4. Windows reserved name (CON/PRN/AUX/NUL/COM[1-9]/LPT[1-9], any case),
  #   5. leading dot disallowed unless `.git` (catches `.hidden`).
  local field="" value=""
  for field in plugin marketplace; do
    if [[ "$field" == "plugin" ]]; then value="$plugin"; else value="$marketplace"; fi
    [[ -n "$value" ]] || continue
    # (1b) length ceiling → mirrors Python `_alias_rejection_reason` (`len >
    # 200`). A 201-char all-safe-character half is SAFE under the charset gate
    # but a path-length / overflow risk the Python writer rejects, so the bash
    # launch-path gate must reject it too (else a valid earlier token converges
    # before the Python raise). Checked before the charset glob so an
    # over-long value short-circuits fast.
    if (( ${#value} > 200 )); then
      printf 'unsafe-%s: length %s exceeds 200' "$field" "${#value}"; return 0
    fi
    # (2) embedded `..` substring → traversal. Check first so the message is
    # specific; the glob below would also catch it but this is clearer.
    if [[ "$value" == *".."* ]]; then
      printf 'unsafe-%s: contains traversal substring (%s)' "$field" "$value"; return 0
    fi
    # (1) any character outside the safe alias set [A-Za-z0-9._-].
    # SECURITY (codex gate-2 r1): use a literal glob test on the QUOTED value
    # (no word-split, no command sub), so a bare-glob value (`*`) is matched
    # literally and never pathname-expands mid-validation. The negated bracket
    # class `*[!A-Za-z0-9._-]*` matches when ANY disallowed char is present —
    # this is the bash mirror of Python's `_SAFE_ALIAS_RE.fullmatch` (and it is
    # what catches a leftover `@` from a multiple-`@` token, a `/`, `\`, `*`,
    # or whitespace).
    if [[ "$value" == *[!A-Za-z0-9._-]* ]]; then
      printf 'unsafe-%s: contains characters outside [A-Za-z0-9._-] (%s)' "$field" "$value"; return 0
    fi
    # (3) reserved `.`/`..` exact name (defensive; (2) already caught `..`).
    if [[ "$value" == "." || "$value" == ".." ]]; then
      printf 'unsafe-%s: reserved component (%s)' "$field" "$value"; return 0
    fi
    # (4) Windows reserved device names, case-insensitive (CON, PRN, AUX, NUL,
    # COM1-9, LPT1-9) — these resolve to devices on Windows filesystems.
    local _upper=""
    _upper="$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]')"
    case "$_upper" in
      CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])
        printf 'unsafe-%s: reserved Windows name (%s)' "$field" "$value"; return 0 ;;
    esac
    # (5) leading dot disallowed unless `.git` (hidden-path / dotfile escape).
    if [[ "$value" == .* && "$value" != ".git" ]]; then
      printf 'unsafe-%s: leading dot disallowed (%s)' "$field" "$value"; return 0
    fi
  done
  printf ''
  return 0
}

bridge_run_sync_dev_plugin_cache() {
  # v0.9.7 RC6 (refs #781): the Python linker is now criticality-aware.
  # Channel-required plugin failures (declared via BRIDGE_AGENT_CHANNELS=
  # plugin:<id>) must block bridge-start; BRIDGE_AGENT_PLUGINS optional
  # plugin failures warn and continue. The split is computed here and
  # passed to Python via --required-channels / --optional-channels.
  #
  # Channels passed as --channels remain the union (effective dev
  # channels), so the linker can sync everything in one pass; the
  # criticality split only affects logging label (ERROR vs WARNING)
  # and the Python exit code.
  #
  # Returns:
  #   0 — all channel-required plugins verified (optional warnings OK)
  #   non-zero — at least one channel-required plugin failed (block)
  local channels="" required_channels="" optional_csv=""
  local output=""
  local line=""
  local rc=0

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  # Issue #1890: dynamic vanilla Claude inherits operator-global plugins/MCP and
  # uses no per-agent config dir, so syncing a per-agent dev-plugin cache is a
  # no-op for the launched process. Skip it so a missing per-agent cache cannot
  # `exit 65` block a passthrough launch.
  if command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 \
     && bridge_agent_is_dynamic_vanilla_claude "$AGENT"; then
    return 0
  fi
  channels="$(bridge_agent_effective_dev_channels_csv "$AGENT")"

  # Issue #1857: the bridge-owned plugin grant ledger holds the operator's
  # installed-plugins recovery snapshot (extending the existing
  # `{"channels":[...]}` ledger). Resolved from the controller-trusted
  # `$BRIDGE_STATE_DIR` (NOT the env-overridable plugin roots), pinned by the
  # canonical helper, and passed as an explicit path so the Python writer can
  # restore operator plugins after a recreate wipe without ever mutating
  # Claude's manifest for bookkeeping or writing a parallel `.bak`.
  local _plugin_grant_ledger=""
  if declare -F bridge_isolated_plugin_grants_state_file >/dev/null 2>&1; then
    _plugin_grant_ledger="$(bridge_isolated_plugin_grants_state_file "$AGENT" 2>/dev/null || true)"
  fi

  # Issue #1857 (BLOCKER 1 — fleet-default convergence): every Claude-agent
  # launch converges `channel-declared ∪ fleet-default ∪ existing records`.
  # The fleet-default declaration is read from the CANONICAL protected file
  # (`$BRIDGE_HOME/agent-env.local.sh`, never env-overridable) via the pinned
  # reader, so declaring `BRIDGE_FLEET_DEFAULT_PLUGINS` on a live fleet seeds
  # every Claude agent on its next NATURAL relaunch — "declare once, converge
  # forever". The union happens HERE in the launch path (not just in a reader
  # helper): each safe fleet-default spec is folded into the effective channel
  # set so the Python writer installs/enables/manifests it exactly like a
  # channel plugin. Taxonomy (spec v3 Δ3):
  #   class-(b) unsafe identity      → fail-closed for ALL classes, BEFORE any
  #                                    path join / convergence write (return
  #                                    non-zero so launch aborts before the
  #                                    Python pass writes anything).
  #   class-(a) malformed-but-safe   → skip that token + warn, process the rest.
  #   class-(c) unavailable-but-safe → routed as OPTIONAL (warn-once, never a
  #                                    launch blocker) — channel-required stays
  #                                    fail-closed, fleet-default is fail-soft.
  local _fleet_default_csv="" _fleet_qualified=""
  if declare -F bridge_fleet_default_plugins_read >/dev/null 2>&1; then
    _fleet_default_csv="$(bridge_fleet_default_plugins_read 2>/dev/null || true)"
  fi
  if [[ -n "$_fleet_default_csv" ]]; then
    local _fd_token="" _fd_item="" _fd_unsafe=""
    # SECURITY (codex gate-2 r1): split with `read -r -a` (NOT an unquoted
    # `$_fleet_default_csv` word-split). An unquoted split runs Bash pathname
    # expansion on each field FIRST, so a `*` (or any glob) in an unsafe
    # fleet-default declaration would expand to real cwd filenames BEFORE
    # `bridge_run_fleet_default_unsafe_reason` ever validates it — silently
    # rewriting the token and defeating the class-(b) fail-closed contract.
    # `read -r -a` reads literal fields with no globbing. A `__FD_SENTINEL__`
    # tail field is appended then dropped so a TRAILING empty token (`foo,`)
    # survives as a real empty field and still hits the class-(a) empty-token
    # skip+warn branch below (a bare word-split silently eats trailing empties).
    local -a _fd_arr=()
    IFS=',' read -r -a _fd_arr <<<"${_fleet_default_csv},__FD_SENTINEL__"
    if (( ${#_fd_arr[@]} > 0 )); then
      unset "_fd_arr[$(( ${#_fd_arr[@]} - 1 ))]"
    fi
    for _fd_token in "${_fd_arr[@]}"; do
      _fd_token="${_fd_token## }"
      _fd_token="${_fd_token%% }"
      # class-(a): empty token after trim is malformed-but-safe → skip+warn.
      # A bare empty token has NO non-empty half to be unsafe, so the class-b
      # check below would no-op anyway; skip it early as a cheap fast-path.
      if [[ -z "$_fd_token" ]]; then
        log_line "[dev-plugin-cache] #1857 fleet-default class-a skip: empty declaration token"
        continue
      fi
      # ORDERING CONTRACT (Issue #1857 spec v3, frozen taxonomy — gate-2 r4
      # restructure): class-(b) unsafe MUST be evaluated BEFORE the class-(a)
      # empty-half skip. The precedence is fail-closed-first:
      #   1. validate EVERY non-empty half for a real unsafe component
      #      (traversal `..`/`../evil`, reserved component, catalog escape) →
      #      if ANY non-empty half is unsafe, FAIL CLOSED (rc!=0), never
      #      downgraded — even when the OTHER half is empty;
      #   2. ONLY THEN, if the token is merely malformed-but-safe (empty
      #      plugin/marketplace half with NO unsafe non-empty component), do
      #      the class-(a) skip+warn and keep processing the list;
      #   3. else fold the valid token into a channel.
      # The earlier code did (2) before (1), so a token with both an empty
      # half AND an unsafe non-empty half (`@../evil` = empty plugin + traversal
      # marketplace; `@..` = empty plugin + reserved marketplace) was wrongly
      # class-a downgraded (skip+warn, launch continued) instead of fail-closed.
      # `bridge_run_fleet_default_unsafe_reason` already skips empty halves
      # (`[[ -n "$value" ]] || continue`) and validates the non-empty half(s),
      # so running it FIRST is exactly the fail-closed-first contract: the
      # unsafe half wins over the empty half.
      #
      # class-(b): unsafe identity in ANY non-empty half fails closed BEFORE any
      # path join / write AND before any class-a empty-half downgrade.
      _fd_unsafe="$(bridge_run_fleet_default_unsafe_reason "$_fd_token")"
      if [[ -n "$_fd_unsafe" ]]; then
        bridge_warn "#1857 fleet-default unsafe declaration (fail-closed) for ${AGENT}: ${_fd_unsafe}"
        return 1
      fi
      # class-(a): a token with an EMPTY plugin OR EMPTY marketplace HALF
      # (`bad@` = empty marketplace, `@evil` = empty plugin) and NO unsafe
      # non-empty half (the class-b check above already returned) is bad SPEC
      # SYNTAX, not traversal — malformed-but-safe. Skip+warn that token and
      # keep processing the rest of the list (Issue #1857, spec v3 Δ3 class-a),
      # matching the manifest writer's established class-a behavior
      # (bridge-dev-plugin-cache.py: missing-plugin/marketplace skip). It must
      # NOT be folded into a channel: an empty component reaches Python's
      # `_require_safe_path_component`, which raises ValueError on the empty
      # value and would take down the WHOLE launch via the fleet-default path.
      # A single typo in the protected fleet-default declaration must never
      # block every Claude launch.
      if [[ "$_fd_token" == *"@"* ]]; then
        local _fd_plugin_half="${_fd_token%%@*}"
        local _fd_marketplace_half="${_fd_token#*@}"
        if [[ -z "$_fd_plugin_half" || -z "$_fd_marketplace_half" ]]; then
          bridge_warn "#1857 fleet-default class-a skip for ${AGENT}: malformed spec '${_fd_token}' (empty plugin or marketplace half) — skipped, launch continues"
          continue
        fi
      fi
      # Qualify to the `plugin:<plugin>@<marketplace>` channel form the Python
      # comparator and the manifest writer expect; a bare token gets the
      # agent-bridge marketplace (mirrors the BRIDGE_AGENT_PLUGINS path above).
      if [[ "$_fd_token" == *"@"* ]]; then
        _fd_item="plugin:${_fd_token}"
      else
        _fd_item="plugin:${_fd_token}@agent-bridge"
      fi
      if [[ -n "$_fleet_qualified" ]]; then
        _fleet_qualified+=",$_fd_item"
      else
        _fleet_qualified="$_fd_item"
      fi
    done
  fi
  # Snapshot the channel-required set BEFORE folding in fleet-default, so
  # `required_channels` (block-on-fail) below derives ONLY from the channel-
  # declared set. Fleet-default entries are routed as OPTIONAL (warn-only)
  # further down — they must never be promoted to channel-required, or a
  # missing fleet-default payload would block launch (violates "never a launch
  # blocker").
  local _channel_required_only="$channels"

  # Fold the validated fleet-default set into the effective channel union so the
  # Python pass converges it. They are OPTIONAL (fail-soft), so a missing
  # payload / unreachable marketplace warns-once and never blocks launch.
  if [[ -n "$_fleet_qualified" ]]; then
    if [[ -n "$channels" ]]; then
      channels+=",$_fleet_qualified"
    else
      channels="$_fleet_qualified"
    fi
  fi

  # A dynamic agent with NO plugin: channels but operator-installed plugins
  # (claude-hud installed ad-hoc, recorded in the ledger snapshot) is the exact
  # #1857 scenario the create-time-only materialization missed: a recreate
  # empties the live manifest and there is no channel set to trigger the
  # writer. Run a recovery-only pass (empty channel set → zero verified entries
  # → the writer's no-verified-entries recovery branch restores from the ledger
  # snapshot) whenever the ledger records a non-empty snapshot.
  #
  # Fast-return only when there is genuinely nothing to do:
  #   - no ledger path resolved, OR
  #   - the ledger file is ABSENT, OR
  #   - the ledger is present AND READABLE but carries no snapshot.
  # A ledger that is PRESENT but UNREADABLE (codex r3 finding 2 — e.g. a
  # pre-#1857 root-only ledger whose group-publish has not landed) must NOT be
  # treated as "no snapshot": fall THROUGH to the sync pass so the Python
  # `_read_grant_ledger` diagnostic fires and tells the operator to re-publish
  # ownership, rather than silently skipping recovery.
  # NOTE: this function runs AS the launching identity (the iso UID under the
  # sudo wrap in iso v2, or the controller user in shared mode), so the file
  # tests below use the running UID's own view — exactly the identity that must
  # read the ledger for recovery. No sudo escalation here.
  if [[ -z "$channels" ]]; then
    # Issue #1857 (BLOCKER 2 — brownfield first-snapshot reachability): a
    # dynamic agent with ONLY operator-installed (ad-hoc) plugins, NO plugin:
    # channels, and NO fleet-default declaration has a non-empty live manifest
    # but no ledger snapshot yet. It MUST reach the Python seed path so the
    # FIRST recovery snapshot is taken BEFORE its first #1854 `--replace`
    # restart wipe — otherwise recovery has nothing to restore. So before the
    # no-channel fast-return, fall THROUGH whenever the agent's live manifest is
    # non-empty (the Python `_seed_ledger_snapshot_if_needed` then snapshots it
    # on the no-op path). Resolve the manifest under the SAME Claude config root
    # the sync pass below targets, so the reachability check and the writer
    # agree on the file. Best-effort: an unresolved root / missing manifest
    # falls back to the original ledger-only gate.
    local _agent_manifest=""
    local _agent_claude_root_probe=""
    _agent_claude_root_probe="$(bridge_run_agent_claude_root 2>/dev/null || true)"
    if [[ -n "$_agent_claude_root_probe" ]]; then
      _agent_manifest="$_agent_claude_root_probe/plugins/installed_plugins.json"
    fi
    if [[ -z "$_plugin_grant_ledger" || ! -e "$_plugin_grant_ledger" ]]; then
      # No ledger yet. Still take the first snapshot if there is a non-empty
      # ad-hoc manifest to protect; otherwise nothing to do.
      if [[ -n "$_agent_manifest" ]] \
          && bridge_run_manifest_has_plugins "$_agent_manifest"; then
        : # fall through to the sync pass so the seed snapshot is taken
      else
        return 0
      fi
    elif [[ -r "$_plugin_grant_ledger" ]] \
        && ! bridge_run_ledger_has_snapshot "$_plugin_grant_ledger"; then
      # Ledger present+readable but carries no snapshot. Same brownfield gate:
      # seed from a non-empty manifest before returning, else no-op.
      if [[ -n "$_agent_manifest" ]] \
          && bridge_run_manifest_has_plugins "$_agent_manifest"; then
        : # fall through to seed the first snapshot
      else
        return 0
      fi
    fi
    # else: present-and-(unreadable OR has-snapshot) → run the pass so either
    # recovery happens or the Python diagnostic surfaces the unreadable ledger.
  fi

  # Required: every plugin: channel from the channel-DECLARED set only (the
  # fleet-default union was deliberately excluded above — fleet-default is
  # optional/warn-only, never block-on-fail).
  # These come from BRIDGE_AGENT_CHANNELS — primary-channel config.
  required_channels="$_channel_required_only"

  # Optional: BRIDGE_AGENT_PLUGINS allowlist entries (#272). These are
  # bare plugin ids; qualify them with the agent-bridge marketplace so
  # the Python comparator (which sees full plugin:<id>@<mkt> strings)
  # can match. Items already in the channels CSV are also marked
  # optional here — the Python side takes the lenient declaration as
  # binding when both lists overlap.
  optional_csv="$(bridge_agent_plugins_csv "$AGENT" 2>/dev/null || true)"
  if [[ -n "$optional_csv" ]]; then
    local _opt_qualified="" _opt_token="" _opt_item=""
    local IFS_orig="$IFS"
    IFS=','
    # shellcheck disable=SC2206 # intentional split on `,`.
    local -a _opt_arr=( $optional_csv )
    IFS="$IFS_orig"
    for _opt_token in "${_opt_arr[@]}"; do
      _opt_token="${_opt_token## }"
      _opt_token="${_opt_token%% }"
      [[ -n "$_opt_token" ]] || continue
      if [[ "$_opt_token" == *"@"* ]]; then
        _opt_item="plugin:${_opt_token}"
      else
        _opt_item="plugin:${_opt_token}@agent-bridge"
      fi
      if [[ -n "$_opt_qualified" ]]; then
        _opt_qualified+=",$_opt_item"
      else
        _opt_qualified="$_opt_item"
      fi
    done
    optional_csv="$_opt_qualified"
  fi

  # Issue #1857 (BLOCKER 1): mark every fleet-default channel OPTIONAL so the
  # Python criticality split treats a missing fleet-default payload as
  # warn-once + continue (class-(c) fail-soft), never block-on-fail. Already-
  # qualified to `plugin:<plugin>@<marketplace>` above.
  if [[ -n "$_fleet_qualified" ]]; then
    if [[ -n "$optional_csv" ]]; then
      optional_csv+=",$_fleet_qualified"
    else
      optional_csv="$_fleet_qualified"
    fi
  fi

  local agent_claude_root=""
  agent_claude_root="$(bridge_run_agent_claude_root)"

  output="$(BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="$agent_claude_root/plugins/cache" \
    BRIDGE_CLAUDE_PLUGINS_ROOT="$agent_claude_root/plugins" \
    BRIDGE_PLUGIN_GRANT_LEDGER="$_plugin_grant_ledger" \
    python3 "$SCRIPT_DIR/bridge-dev-plugin-cache.py" sync \
    --channels "$channels" \
    --required-channels "$required_channels" \
    --optional-channels "${optional_csv:-}" \
    --agent "$AGENT" \
    2>&1)" || rc=$?

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    log_line "[dev-plugin-cache] $line"
  done <<<"$output"

  if (( rc != 0 )); then
    # Required-plugin failure — surface with bridge_warn AND propagate
    # the non-zero exit upstream. bridge-run.sh's caller (bridge-start.sh
    # via the sudo wrap) needs the non-zero status to block launch per
    # the Q4 channel-required criticality decision. The legacy code
    # path swallowed this with `bridge_warn` only and let the launch
    # continue — which is exactly the silent-failure shape RC6 names.
    bridge_warn "development plugin cache sync failed for ${AGENT} (channel-required plugin missing/unverified)"
    return "$rc"
  fi
  return 0
}

bridge_run_prune_legacy_teams_mcp() {
  local channels=""
  local output=""
  local line=""
  local rc=0

  [[ "$ENGINE" == "claude" ]] || return 0
  [[ $SAFE_MODE -eq 0 ]] || return 0
  # Issue #1890: dynamic vanilla Claude has no per-agent config dir / manifest to
  # prune — operator-global MCP is inherited as-is. Skip.
  if command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 \
     && bridge_agent_is_dynamic_vanilla_claude "$AGENT"; then
    return 0
  fi
  channels="$(bridge_agent_effective_dev_channels_csv "$AGENT")"
  bridge_channel_csv_contains "$channels" "plugin:teams" || return 0

  output="$(python3 "$SCRIPT_DIR/scripts/python-helpers/prune-legacy-teams-mcp.py" \
    --agent "$AGENT" \
    --workdir "$WORK_DIR" \
    --agent-root "$BRIDGE_AGENT_HOME_ROOT/$AGENT" \
    2>&1)" || rc=$?

  # Issue #1282 (Surface A) — `absent path=…` is the steady-state output
  # on a healthy install (legacy mcpServers.teams entry was already
  # cleaned up or never existed). Logging it on every Claude run paints
  # the operator's audit tail with cosmetic noise that masks real
  # actions. Suppress `absent`/`unchanged` rows; keep `pruned`/`failed`/
  # `skipped` rows because those reflect a real state change or a
  # condition the operator may need to act on.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      "absent path="*|"unchanged path="*)
        continue
        ;;
    esac
    log_line "[legacy-teams-mcp] $line"
  done <<<"$output"

  return "$rc"
}

bridge_run_safe_mode_resume_hint() {
  local mode=""
  local admin_agent=""

  mode="$(bridge_safe_mode_resume_mode "$AGENT")"
  admin_agent="$(bridge_require_admin_agent 2>/dev/null || true)"
  log_line "[safe-mode] booting ${AGENT} with minimal launch"
  log_line "[safe-mode] ignored roster launch_cmd: $(bridge_redact_inline_env_secrets "$(bridge_agent_launch_cmd_raw "$AGENT")")"
  if [[ -n "$(bridge_agent_channels_csv "$AGENT")" ]]; then
    log_line "[safe-mode] suppressed channels: $(bridge_agent_channels_csv "$AGENT")"
  fi
  if [[ -n "$(bridge_agent_effective_dev_channels_csv "$AGENT")" ]]; then
    log_line "[safe-mode] suppressed development channels: $(bridge_agent_effective_dev_channels_csv "$AGENT")"
  fi
  log_line "[safe-mode] skipped project bootstrap and channel plugin loading"
  log_line "[safe-mode] resume strategy: ${mode}"
  if [[ -n "$admin_agent" && "$AGENT" == "$admin_agent" ]]; then
    log_line "[safe-mode] return to normal mode with: agb admin"
  else
    log_line "[safe-mode] return to normal mode with: agent-bridge agent start ${AGENT}"
  fi
}

# Issue 2 (v0.11.0): record a Claude `--resume <stale-id>` rejection.
# Called right after each launch returns, before the ONCE early-exit so
# one-shot runs also record. Heuristic:
#   1. ENGINE == claude, EXIT_CODE != 0, EXIT_CODE != 130|143 (signal exits),
#      AND --resume <token> appears in LAUNCH_CMD.
#   2. Try to extract the rejected session id from the new stderr bytes
#      (slice between $local_err_size_before and $local_err_size_after).
#   3. If stderr did not include a session id (Claude often writes the
#      "No conversation found" hint to the alt-screen TUI, leaving ERRFILE
#      empty), fall back to the --resume token from LAUNCH_CMD when the
#      run was suspiciously short (<= 10s).
#   4. Validate the extracted id, then call quarantine_add +
#      archive_transcript so the next resolver pass excludes it.
#
# All output goes through log_line so the operator sees one line per
# quarantine event; failures here are best-effort and never propagate.
bridge_run_quarantine_rejected_resume() {
  local exit_code="${1:-0}"
  local duration="${2:-0}"
  local launch_cmd="${3:-}"
  local errfile="${4:-}"
  local err_before="${5:-0}"
  local err_after="${6:-0}"
  local rejected_id=""
  local cmd_resume_id=""
  local stderr_slice=""
  local archived_csv=""
  local source=""

  [[ "$ENGINE" == "claude" ]] || return 0
  (( exit_code != 0 )) || return 0
  # Skip clean signal exits (SIGINT/SIGTERM) — those are not resume rejections.
  case "$exit_code" in
    130|143) return 0 ;;
  esac
  [[ -n "$launch_cmd" ]] || return 0

  # Extract --resume <token> from LAUNCH_CMD. Falls back to a regex-based
  # match; UUID-shaped ids are accepted along with any token that survives
  # bridge_resume_session_id_valid downstream.
  cmd_resume_id="$(printf '%s' "$launch_cmd" \
    | grep -oE -- '--resume[[:space:]]+[A-Za-z0-9._-]+' \
    | head -n1 \
    | awk '{print $2}' || true)"
  [[ -n "$cmd_resume_id" ]] || return 0

  # Slice stderr to the bytes the just-finished launch produced. tail -c +N
  # is 1-indexed, so we want N = err_before + 1.
  if [[ -f "$errfile" && "$err_after" =~ ^[0-9]+$ && "$err_before" =~ ^[0-9]+$ ]] \
     && (( err_after > err_before )); then
    stderr_slice="$(tail -c +"$((err_before + 1))" "$errfile" 2>/dev/null \
      | head -c 8192 2>/dev/null || true)"
    if [[ -n "$stderr_slice" ]] \
       && printf '%s' "$stderr_slice" | grep -qE 'No conversation found|session ID'; then
      rejected_id="$(printf '%s' "$stderr_slice" \
        | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
        | head -n1 || true)"
      source="stderr"
    fi
  fi

  if [[ -z "$rejected_id" ]]; then
    # Fallback gate (review #2040): only fire when there's NO new stderr
    # content for this launch. Non-empty stderr that does not match the
    # rejection pattern means the failure is something else (auth, plugin
    # cache, stdin contract, etc.) and the resume id should NOT be
    # quarantined — that would mask the real error and skip a valid
    # session on the next attempt. Whitespace-only stderr is treated as
    # empty for this gate.
    local _stderr_has_content=0
    if [[ -n "$stderr_slice" ]] && [[ -n "${stderr_slice//[[:space:]]/}" ]]; then
      _stderr_has_content=1
    fi
    if (( _stderr_has_content == 0 )) \
       && [[ "$duration" =~ ^[0-9]+$ ]] \
       && (( duration <= 10 )); then
      # Empty/whitespace-only stderr is the live-symptom shape (Claude's
      # TUI alt-screen swallows the rejection message before exit). Treat
      # short-duration EXIT 1 with `--resume <uuid>` as a high-confidence
      # rejection in that case.
      rejected_id="$cmd_resume_id"
      source="launch-cmd"
    fi
  fi

  [[ -n "$rejected_id" ]] || return 0
  bridge_resume_session_id_valid "$rejected_id" || return 0

  if ! bridge_agent_resume_quarantine_add "$AGENT" "$rejected_id" "no-conversation-found" 2>/dev/null; then
    return 0
  fi
  log_line "[quarantine] resume id rejected (exit=${exit_code}, source=${source}, duration=${duration}s) → ${rejected_id}; subsequent launches will skip this transcript"
  archived_csv="$(bridge_agent_resume_quarantine_archive_transcript "$AGENT" "$rejected_id" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
  if [[ -n "$archived_csv" ]]; then
    log_line "[quarantine] archived transcript(s): ${archived_csv}"
  fi
  bridge_audit_log state claude_resume_quarantined "$AGENT" \
    --field session_id="$rejected_id" \
    --field exit_code="$exit_code" \
    --field duration_seconds="$duration" \
    --field source="$source" \
    --field archived="${archived_csv:-}" \
    >/dev/null 2>&1 || true
}

bridge_run_fail_backoff_seconds() {
  local count="$1"
  local csv="${BRIDGE_RUN_FAIL_BACKOFFS_CSV:-5,10,20,40,80}"
  local -a values=()
  local index=0

  IFS=',' read -r -a values <<<"$csv"
  [[ "$count" =~ ^[0-9]+$ ]] || count=1
  index=$((count - 1))
  if (( index < 0 )); then
    index=0
  fi
  if (( index < ${#values[@]} )); then
    printf '%s' "${values[$index]}"
  elif (( ${#values[@]} > 0 )); then
    printf '%s' "${values[$((${#values[@]} - 1))]}"
  else
    printf '%s' "80"
  fi
}

log_line "${AGENT} 에이전트 시작 (engine=${ENGINE}, dir=${WORK_DIR})"
BRIDGE_RUN_ROSTER_SIGNATURE="$(bridge_run_roster_signature)"
if [[ $SAFE_MODE -eq 1 ]]; then
  bridge_run_safe_mode_resume_hint
fi

FAIL_COUNT=0
RESTART_COUNT=0
RAPID_FAIL_COUNT=0
RAPID_FAIL_WINDOW="${BRIDGE_RUN_RAPID_FAIL_WINDOW_SECONDS:-10}"
MAX_RAPID_FAILS="${BRIDGE_RUN_MAX_RAPID_FAILS:-5}"
HEALTHY_RUN_RESET_SECONDS="${BRIDGE_RUN_HEALTHY_RESET_SECONDS:-60}"
# #1520 r4: the proven-keychain-free trust flag was already `unset` at true
# process entry (top of this script, alongside the STEP A credential scrub) —
# value AND export attribute removed BEFORE any fork/re-exec — so no separate
# pre-loop scrub is needed here. The guard reads it with a `:-0` default, and
# the preflight (re)sets it as a process-local var every iteration.
while true; do
  local_launch_cmd_display=""
  local_err_size_before=0
  local_err_size_after=0
  run_started_at=0
  run_ended_at=0
  run_duration=0
  rapid_failure=0
  sleep_seconds=5
  previous_session_id=""
  bridge_run_refresh_roster_if_changed
  export BRIDGE_AGENT_LOOP_RESTART_COUNT="$RESTART_COUNT"
  previous_session_id="$(bridge_agent_session_id "$AGENT")"
  bridge_run_reconcile_next_session_state
  if [[ $SAFE_MODE -eq 1 ]]; then
    LAUNCH_CMD="$(bridge_build_safe_launch_cmd "$AGENT")"
  else
    LAUNCH_CMD="$(bridge_agent_launch_cmd "$AGENT")"
  fi
  [[ -n "$LAUNCH_CMD" ]] || bridge_die "'$AGENT'의 launch command가 비어 있습니다."
  # Issue #1118: when bridge-start.sh resolved the engine binary on the
  # controller side and propagated it via BRIDGE_ENGINE_BIN, rewrite the
  # leading `claude`/`codex` token in LAUNCH_CMD to that absolute path.
  # The rewrite happens AFTER the launch_cmd builders so the existing
  # `--resume`/`--name`/channels logic stays in one place. The helper is a
  # no-op when BRIDGE_ENGINE_BIN is empty or the engine token has already
  # been pinned to an absolute path by an operator override.
  if [[ -n "${BRIDGE_ENGINE_BIN:-}" ]]; then
    LAUNCH_CMD="$(bridge_rewrite_launch_cmd_engine_bin "$LAUNCH_CMD" "$BRIDGE_ENGINE_BIN")"
  fi
  local_launch_cmd_display="$(bridge_redact_inline_env_secrets "$LAUNCH_CMD")"

  if [[ "$ENGINE" == "claude" ]]; then
    bridge_run_export_claude_launch_env
  elif [[ "$ENGINE" == "codex" ]]; then
    bridge_run_export_codex_launch_env
  fi

  if [[ "$ENGINE" == "claude" && $SAFE_MODE -eq 0 ]]; then
    bridge_run_claude_keychain_free_preflight
    # v0.9.7 RC6 (refs #781): channel-required plugin sync failure must
    # block the launch — the agent is being started for that channel
    # and an isolated-UID-unreadable cache directory means MCP servers
    # never surface (which is exactly the silent-failure shape the RC6
    # bug report names). Optional plugin failures are non-fatal and do
    # not flip the helper's exit code, so the launch proceeds normally
    # for them.
    if ! bridge_run_sync_dev_plugin_cache; then
      bridge_audit_log state dev_plugin_cache_blocked_launch "$AGENT" \
        --field reason="channel-required plugin missing or unverified" \
        >/dev/null 2>&1 || true
      log_line "[error] aborting launch: channel-required plugin cache failed for ${AGENT}"
      log_line "[error] repair with: agent-bridge isolation verify --agent ${AGENT}"
      # Exit non-zero so the sudo wrap (bridge-start.sh:447) propagates
      # the failure to the operator. Without this, the loop would
      # continue and the agent would launch missing the very channel it
      # was started for.
      exit 65
    fi
    if ! bridge_run_prune_legacy_teams_mcp; then
      bridge_audit_log state legacy_teams_mcp_prune_failed "$AGENT" \
        --field reason="failed to remove stale mcpServers.teams entry" \
        >/dev/null 2>&1 || true
      log_line "[error] aborting launch: stale Teams MCP cleanup failed for ${AGENT}"
      exit 66
    fi
    bridge_run_ensure_claude_launch_channel_plugins
    bridge_run_schedule_dev_channels_accept "$LAUNCH_CMD"
    bridge_run_schedule_idle_marker_and_inbox_bootstrap "$previous_session_id"
    bridge_ensure_hud_usage_tap "$WORK_DIR" "$LAUNCH_CMD" "$AGENT" >/dev/null 2>&1 || true
  fi

  log_line "실행: ${local_launch_cmd_display}"
  if [[ -f "$ERRFILE" ]]; then
    local_err_size_before="$(wc -c <"$ERRFILE" 2>/dev/null || echo 0)"
  fi
  # v2 isolation: load generic per-agent launch secrets from
  # credentials/launch-secrets.env into the child shell so the child inherits
  # them via export, NEVER via composing into LAUNCH_CMD. Claude OAuth token
  # values deliberately do not use this path; agent-bridge auth claude-token
  # sync writes Claude's .credentials.json file, keeps only a non-secret
  # CLAUDE_CONFIG_DIR pointer here, and scrubs stale CLAUDE_CODE_OAUTH_TOKEN
  # entries from this env file.
  #
  # v0.8.0 T5: BRIDGE_DISABLE_ISOLATION=1 short-circuits the secret-env
  # wrap. Skipping this means the child does NOT see launch secrets
  # placed under credentials/launch-secrets.env — operators using the
  # rollback hatch must inject any required secrets through the
  # controller environment directly. We log once per launch so the
  # boundary drop is visible in agent stderr/logs, not silent.
  _v2_secret_file=""
  if bridge_isolation_disabled_by_env; then
    bridge_warn "BRIDGE_DISABLE_ISOLATION=1 — running '${AGENT}' without v2 isolation (security boundary disabled, secret-env wrap skipped)"
  elif bridge_isolation_v2_active; then
    _v2_secret_file="$(bridge_isolation_v2_agent_secret_env_file "$AGENT" 2>/dev/null || true)"
    [[ -n "$_v2_secret_file" && -f "$_v2_secret_file" ]] || _v2_secret_file=""
  fi
  run_started_at="$(date +%s)"
  if [[ -n "$_v2_secret_file" ]]; then
    # PR-C r2 (codex r1 G-19): the subshell-wrap pattern lives in
    # lib/bridge-isolation-v2.sh as bridge_isolation_v2_exec_with_secret_env
    # so the smoke test exercises the EXACT production code path. The
    # helper sets BRIDGE_ISOLATION_V2_LAST_EXEC_RC to the child's exit
    # code (or calls bridge_die on loader failure).
    #
    # #1470 Phase 2 (Q6): a MANAGED Codex iso agent must launch with the
    # OpenAI-key / Codex-token env vars ABSENT — they were already scrubbed
    # from this process's env at entry, so the iso loader subshell inherits a
    # clean env (no code change needed; this is the default). For the explicit
    # unmanaged opt-out, bridge_run_apply_codex_ambient_env restores them here
    # so the iso loader subshell carries them through. For a managed agent it
    # is a no-op (the vars stay absent).
    bridge_run_apply_codex_ambient_env
    # #1470 Q6 (codex r1 BLOCKING): the v2 secret loader exports arbitrary
    # KEY=VALUE rows from launch-secrets.env immediately before exec, which
    # could re-introduce OPENAI_API_KEY / CODEX_ACCESS_TOKEN into a MANAGED
    # Codex child even after the process-entry scrub. Pass the scrub-key list
    # so the exec helper unsets them INSIDE the loader+exec subshell, AFTER
    # the loader runs. For an explicitly-unmanaged Codex run (or non-Codex),
    # pass nothing so the loader/restore behavior is unchanged.
    _v2_codex_scrub=""
    if [[ "$ENGINE" == "codex" && "${BRIDGE_CODEX_UNMANAGED_AUTH:-0}" != "1" ]]; then
      _v2_codex_scrub="OPENAI_API_KEY CODEX_ACCESS_TOKEN"
    fi
    # #1890: a dynamic vanilla Claude agent must inherit the operator-global
    # ~/.claude, so it must NOT receive a per-agent CLAUDE_CONFIG_DIR from any
    # source. The v2 secret-env loader exports launch-secrets.env rows verbatim,
    # and that file may still carry a (non-secret) CLAUDE_CONFIG_DIR pointer from
    # a prior managed-Claude config. Add it to the post-loader scrub list (mirror
    # of the Codex ambient-key scrub) so the child cannot inherit a private
    # config dir. Static/admin Claude + Codex paths keep their config dir.
    if command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 \
       && bridge_agent_is_dynamic_vanilla_claude "$AGENT"; then
      _v2_codex_scrub="${_v2_codex_scrub:+$_v2_codex_scrub }CLAUDE_CONFIG_DIR"
    fi
    # #1899 Phase-4 BLOCKING: a dynamic vanilla Codex agent must run against
    # the operator-global ~/.codex (the #1899 contract). bridge_run_export_
    # codex_launch_env pins HOME/CODEX_HOME in the PARENT, but this v2 secret-env
    # loader runs AFTER that and exports launch-secrets.env rows verbatim — a
    # stale file may carry a per-agent CODEX_HOME/HOME (the Codex analogue of the
    # #1900 CLAUDE_CONFIG_DIR leak). Scrubbing alone is insufficient here:
    # CODEX_HOME/HOME must be SET to operator values, not merely unset. So scrub
    # them (clear any stale row) AND re-pin the operator values inside the
    # loader+exec subshell, AFTER the loader and BEFORE exec. Static/admin +
    # managed Codex are excluded by the predicate and keep their per-agent
    # CODEX_HOME. CODEX_SQLITE_HOME is left untouched (operator-set only).
    _v2_codex_repin=""
    if [[ "$ENGINE" == "codex" ]] \
       && command -v bridge_agent_is_dynamic_vanilla_codex >/dev/null 2>&1 \
       && bridge_agent_is_dynamic_vanilla_codex "$AGENT"; then
      _v2_repin_home=""
      if command -v bridge_agent_operator_home_dir >/dev/null 2>&1; then
        _v2_repin_home="$(bridge_agent_operator_home_dir 2>/dev/null || true)"
      fi
      if [[ -n "$_v2_repin_home" ]]; then
        _v2_codex_scrub="${_v2_codex_scrub:+$_v2_codex_scrub }HOME CODEX_HOME"
        _v2_codex_repin="$(printf 'HOME=%s\nCODEX_HOME=%s/.codex' "$_v2_repin_home" "$_v2_repin_home")"
      fi
      unset _v2_repin_home
    fi
    BRIDGE_ISOLATION_V2_LAST_EXEC_RC=0
    bridge_isolation_v2_exec_with_secret_env \
      "$_v2_secret_file" "$BRIDGE_BASH_BIN" "$LAUNCH_CMD" "$ERRFILE" "$AGENT" "$_v2_codex_scrub" "$_v2_codex_repin"
    EXIT_CODE="$BRIDGE_ISOLATION_V2_LAST_EXEC_RC"
    unset BRIDGE_ISOLATION_V2_LAST_EXEC_RC _v2_codex_scrub _v2_codex_repin
  else
    # Issue #1520: shared (non v2-secret-env) final launch. For Claude
    # agents this exports the per-agent CLAUDE_CONFIG_DIR so the launched
    # `claude` reads its own <agent-home>/.claude config instead of the
    # operator's global ~/.claude.json. HOME stays the shared/operator home.
    # Codex agents take the same path with no CLAUDE_CONFIG_DIR export.
    if bridge_run_shared_launch "$BRIDGE_BASH_BIN" "$LAUNCH_CMD" "$ERRFILE"; then
      EXIT_CODE=0
    else
      EXIT_CODE=$?
    fi
  fi
  unset _v2_secret_file
  run_ended_at="$(date +%s)"
  if [[ "$run_started_at" =~ ^[0-9]+$ && "$run_ended_at" =~ ^[0-9]+$ ]]; then
    run_duration=$((run_ended_at - run_started_at))
  fi
  if [[ -f "$ERRFILE" ]]; then
    local_err_size_after="$(wc -c <"$ERRFILE" 2>/dev/null || echo 0)"
  fi

  # Issue 2 (v0.11.0): detect a `claude --resume <stale-id>` rejection and
  # quarantine the id so the next resolver pass skips it. Runs BEFORE the
  # ONCE early-exit so one-shot launches also persist the rejection.
  bridge_run_quarantine_rejected_resume \
    "$EXIT_CODE" "$run_duration" "$LAUNCH_CMD" "$ERRFILE" \
    "$local_err_size_before" "$local_err_size_after" || true

  bridge_run_cleanup_mcp_orphans

  if [[ $ONCE -eq 1 ]]; then
    if [[ $local_err_size_after -gt $local_err_size_before ]]; then
      log_line "stderr captured: ${ERRFILE}"
    fi
    log_line "1회 실행 종료 (코드: ${EXIT_CODE})"
    exit "$EXIT_CODE"
  fi

  if [[ $EXIT_CODE -eq 0 ]] && bridge_run_session_attached; then
    if bridge_agent_should_stop_on_attached_clean_exit "$AGENT"; then
      if [[ $FAIL_COUNT -gt 0 ]]; then
        bridge_agent_clear_crash_report "$AGENT"
      fi
      bridge_run_stop_foreground_session
      log_line "정상 종료. admin 온보딩이 아직 완료되지 않았으므로 자동 재시작하지 않습니다. 다시 열려면 'agb admin'을 실행하세요."
      exit 0
    else
      log_line "정상 종료. 온보딩 완료/일반 루프 에이전트이므로 tmux client는 분리하고, 에이전트는 백그라운드에서 계속 재시작합니다."
      bridge_run_detach_attached_clients
    fi
  fi

  if [[ $EXIT_CODE -ne 0 ]]; then
    if [[ "$run_duration" =~ ^[0-9]+$ ]] && [[ "$HEALTHY_RUN_RESET_SECONDS" =~ ^[0-9]+$ ]] && (( run_duration >= HEALTHY_RUN_RESET_SECONDS )); then
      FAIL_COUNT=0
      RAPID_FAIL_COUNT=0
      bridge_agent_clear_crash_report "$AGENT"
    fi
    if [[ $local_err_size_after -gt $local_err_size_before ]]; then
      log_line "stderr captured: ${ERRFILE}"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [[ "$run_duration" =~ ^[0-9]+$ ]] && [[ "$RAPID_FAIL_WINDOW" =~ ^[0-9]+$ ]] && (( run_duration < RAPID_FAIL_WINDOW )); then
      rapid_failure=1
      RAPID_FAIL_COUNT=$((RAPID_FAIL_COUNT + 1))
    else
      RAPID_FAIL_COUNT=0
    fi
    if [[ $FAIL_COUNT -eq 5 || $(( FAIL_COUNT % 10 )) -eq 0 ]]; then
      bridge_agent_write_crash_report "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$local_launch_cmd_display"
      bridge_audit_log daemon crash_loop_detected "$AGENT" \
        --detail engine="$ENGINE" \
        --detail fail_count="$FAIL_COUNT" \
        --detail exit_code="$EXIT_CODE" \
        --detail stderr_file="$ERRFILE"
    fi
    if [[ $rapid_failure -eq 1 && "$RAPID_FAIL_COUNT" =~ ^[0-9]+$ && "$MAX_RAPID_FAILS" =~ ^[0-9]+$ && $RAPID_FAIL_COUNT -ge $MAX_RAPID_FAILS ]]; then
      bridge_agent_write_crash_report "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$local_launch_cmd_display"
      bridge_agent_write_broken_launch_state "$AGENT" "$ENGINE" "$FAIL_COUNT" "$EXIT_CODE" "$ERRFILE" "$local_launch_cmd_display" "$local_err_size_before"
      bridge_audit_log daemon crash_loop_broken "$AGENT" \
        --detail engine="$ENGINE" \
        --detail fail_count="$FAIL_COUNT" \
        --detail exit_code="$EXIT_CODE" \
        --detail rapid_fail_count="$RAPID_FAIL_COUNT" \
        --detail rapid_fail_window="$RAPID_FAIL_WINDOW"
      log_line "[fail] ${RAPID_FAIL_COUNT} consecutive rapid failures under ${RAPID_FAIL_WINDOW}s. Circuit breaker opened."
      log_line "[fail] recovery: agent-bridge agent safe-mode ${AGENT}"
      log_loop_help
      exit 1
    fi
    if [[ $rapid_failure -eq 1 ]]; then
      sleep_seconds="$(bridge_run_fail_backoff_seconds "$RAPID_FAIL_COUNT")"
      log_line "비정상 종료 (코드: ${EXIT_CODE}, 연속실패: ${FAIL_COUNT}회, rapid=${RAPID_FAIL_COUNT}/${MAX_RAPID_FAILS}, 실행시간: ${run_duration}s). ${sleep_seconds}초 후 재시작..."
    else
      log_line "비정상 종료 (코드: ${EXIT_CODE}, 연속실패: ${FAIL_COUNT}회, 실행시간: ${run_duration}s). 5초 후 재시작..."
    fi
    log_loop_help
    RESTART_COUNT=$((RESTART_COUNT + 1))
    if [[ $rapid_failure -eq 1 ]]; then
      sleep "$sleep_seconds"
    elif [[ $FAIL_COUNT -ge 10 ]]; then
      log_line "연속 ${FAIL_COUNT}회 실패. 60초 대기..."
      sleep 60
    else
      sleep 5
    fi
  else
    if [[ $FAIL_COUNT -gt 0 ]]; then
      bridge_agent_clear_crash_report "$AGENT"
      bridge_audit_log daemon crash_loop_recovered "$AGENT" \
        --detail engine="$ENGINE" \
        --detail previous_fail_count="$FAIL_COUNT"
    fi
    FAIL_COUNT=0
    RAPID_FAIL_COUNT=0
    log_line "정상 종료. 5초 후 재시작..."
    log_loop_help
    RESTART_COUNT=$((RESTART_COUNT + 1))
    sleep 5
  fi
done
