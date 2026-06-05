#!/usr/bin/env bash
# shellcheck shell=bash
# bridge-secret-scrub.sh — shared ambient-secret scrub / transit primitive
# (issue #1454).
#
# THE SHARED ROOT. PRs #1443 (bridge-usage.sh) and #1452/#1444 (bridge-run.sh)
# each re-implemented the same inherited-env credential-hardening dance in their
# own lane: strip exported-function shadows + BASH_ENV/ENV/BASH_XTRACEFD startup
# hooks before any fork, capture the well-known secret env values into
# NON-exported shell vars and scrub them from the environment, re-exec under a
# privileged `bash -p` (privileged mode imports no environment functions and
# ignores BASH_ENV/ENV), and carry the captured values across that re-exec on a
# nonce-gated inherited fd backed by an UNLINKED 0600 file (never a findable
# path, never an env var). This file factors those moves into ONE reusable
# primitive so future consumers stop hand-rolling the dance.
#
# THREAT MODEL (the in-scope window this primitive defends):
#   A same-UID caller that, before invoking a bridge script, exports a Bash
#   FUNCTION named after a command the script invokes unqualified (`export -f
#   dirname`, including the `source`/`.`/`builtin`/`command`/`local` builtins —
#   neutralized via the un-shadowable `POSIXLY_CORRECT=1` seed), or plants such
#   a binary earlier on PATH — any of which would otherwise run IN the script's
#   shell (or a child it forks) WHILE an ambient secret env var is still live,
#   and exfiltrate it. The primitive also `unset`s `BASH_ENV ENV BASH_XTRACEFD`,
#   `set +x`, and `unset PS4` in `harden_hooks` so none of those caller-planted
#   child-startup hooks fire in any subshell/fork the bridge spawns AFTER
#   hardening (the re-exec and every later `$(...)`).
#
#   OUT of scope — the launch-environment-control boundary (consistent with the
#   #1443 ruling). Two related classes are explicitly NOT defended because they
#   execute attacker code BEFORE this primitive's first line can run, and both
#   require the attacker to control the *invoking shell's options/startup* on a
#   token-bearing launch — the same "already controls the launch environment"
#   position as a same-UID attacker who can scrape `/proc`/the filesystem (who
#   already holds the secret):
#     (a) Inherited `SHELLOPTS=xtrace` + a `PS4` carrying a command-substitution:
#         Bash evaluates `PS4` BEFORE the first command of any script, so the
#         `PS4` `$(...)` runs while the secret is live before bridge-lib.sh's
#         first executable line — no pure-Bash code at the bridge-lib.sh root
#         can pre-empt it from inside the script.
#     (b) A DEBUG trap installed by the invoking shell (e.g. via `BASH_ENV` +
#         `set -T`) fires before the seed assignment itself.
#   These are the launch-env-control boundary, not a defect in this primitive;
#   defending them would require trusting the invoking shell's pre-exec state,
#   which is exactly what a same-UID launch-environment attacker controls. The
#   matching boundary still holds: a same-UID attacker who can already
#   arbitrarily scrape the operator's filesystem / `/proc` already holds the
#   secret; nothing this primitive does helps or hurts that case.
#
# CONSUMER CONTRACT (what each helper guarantees / requires):
#
#   bridge_secret_scrub_harden_hooks
#     Neutralizes the caller-controlled child-startup hook classes BEFORE the
#     first fork: `unset -f` the common interceptor command names, `unset
#     BASH_ENV ENV BASH_XTRACEFD`, `set +x`, `unset PS4`. Idempotent, builtin-
#     only, no fork, Bash 3.2-safe. Safe to call unconditionally — it only
#     removes hooks the bridge never legitimately uses, so for normal operation
#     it is a no-op (no observable behavior change). Call this FIRST, before
#     any external command or `$(...)` subshell.
#
#   bridge_secret_scrub_capture <oat_var> <api_var> <auth_var>
#     Moves the three well-known secret VALUES (CLAUDE_CODE_OAUTH_TOKEN,
#     ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN) into the three caller-named
#     shell variables (passed by NAME; the function does NOT export them) and
#     `unset`s the well-known names from the environment, so every subsequent
#     child the caller forks inherits a SECRET-FREE env. Builtin-only, no fork.
#     Returns 0 always. The caller owns the captured values from here on:
#     keep them NON-exported, and either (a) restore them with
#     bridge_secret_scrub_restore after the danger window, or (b) deliver them
#     out-of-band (the transit-fd helpers below) across a re-exec. After
#     calling capture, call bridge_secret_scrub_harden_hooks first if you have
#     not already (the order capture-then-fork must never have a hook live).
#
#   bridge_secret_scrub_restore <oat_var> <api_var> <auth_var>
#     Re-exports the three caller-named values back into the well-known env
#     names IFF non-empty. The inverse of capture, for consumers whose launched
#     child legitimately authenticates from the ambient env (the legacy auth
#     path). Builtin-only, no fork.
#
#   bridge_secret_scrub_open_transit_fd <fd> <nonce_out_var> <name=value>...
#     Stashes NUL-delimited NAME=VALUE records on the given fd, backed by an
#     UNLINKED 0600 tempfile, prefixed by a per-process RANDOM nonce written
#     into <nonce_out_var> (export it for the re-exec'd pass to match). The fd
#     is inherited only by an explicit `exec <bash> -p "$0" "$@"` the caller
#     issues next. Uses HARDCODED-ABSOLUTE mktemp/chmod/rm so a PATH plant
#     cannot run near the live secret. Returns 0 on success, 1 if no tempfile.
#
#   bridge_secret_scrub_read_transit_fd <fd> <expected_nonce> <oat_var> <api_var> <auth_var>
#     In the re-exec'd (privileged) pass: reads the records back from <fd>,
#     validates the first record == <expected_nonce> (a caller-preopened fd
#     with no/forged nonce is rejected — the nonce is generated AFTER any
#     inherited fd is closed, so it is unforgeable), populates the three
#     caller-named vars, and CLOSES <fd>. Call this at the TOP of the re-exec'd
#     pass, BEFORE any `$(...)` subshell, so no child inherits the token fd.
#
#   bridge_secret_scrub_close_fd <fd>
#     Defensively closes a possibly caller-preopened fd (no command — pure
#     redirect) so it is never inherited by a child the caller forks. Brace-
#     grouped so the `2>/dev/null` does not become a permanent stderr redirect.
#
# This module is sourced (on macOS) by bridge-lib.sh BEFORE its Bash-3.2→4+
# re-exec, so every construct here MUST be Bash 3.2-safe (no associative arrays,
# no `${var^^}`, no `mapfile`, no `<<<`, no process substitution). It must not
# `set -e`/`set -u` globally (it is sourced into the caller's options) and must
# not emit output on the success path.

# Guard against double-source.
if [[ -n "${_BRIDGE_SECRET_SCRUB_SH_LOADED:-}" ]]; then
  # shellcheck disable=SC2317  # reachable on a second source; shellcheck can't see that
  return 0 2>/dev/null || true
fi
_BRIDGE_SECRET_SCRUB_SH_LOADED=1

# The interceptor command names a same-UID caller could `export -f` to shadow.
# `bash`/`sh` are intentionally OMITTED: this primitive (and bridge-lib.sh) must
# still be able to invoke the candidate Bash by absolute path, and stripping a
# `bash` function here is moot — the re-exec uses an absolute path which can
# never resolve to a function. Keeping `bash`/`sh` out also avoids any surprise
# in callers that legitimately define wrapper functions of those names.
# `set`, `.` (the POSIX `source` synonym), `eval`, `local` and `trap` are all
# included so the shadow-proof seed in bridge_secret_scrub_harden_hooks strips
# them too — a caller can `export -f .` / `export -f set` / `export -f local`
# just as easily as `source` (codex Phase-4 r2 caught a `local()` shadow that
# fired before the original seed, and a `set -T` DEBUG-trap re-install path).
_bridge_secret_scrub_interceptors='exec source . command builtin unset set eval printf read echo mktemp chmod rm cat dirname cd pwd trap export local python3 python uname env claude codex head readlink true false'

# Harden the child-startup hook classes before the first fork. Builtin-only.
bridge_secret_scrub_harden_hooks() {
  # SHADOW-PROOF SEED (#1491 / #1454 gap, hardened in Phase-4 r2). `builtin
  # unset -f …` is NOT self-healing: a same-UID caller can `export -f builtin`
  # so that the very `builtin` token is eaten by a `builtin()` function shadow
  # (verified on bash 5.3.9 + macOS /bin/bash 3.2 — a function OUTRANKS the
  # builtin of the same name in command lookup). The one lever a caller cannot
  # intercept is a plain VARIABLE ASSIGNMENT: assigning `POSIXLY_CORRECT=1` turns
  # POSIX mode ON mid-shell, and in POSIX mode the special builtins (`unset`,
  # `set`, `trap`, …) OUTRANK same-named function shadows.
  #
  # The seed therefore uses ONLY: (a) unshadowable assignments, and (b) special
  # builtins invoked AFTER POSIX mode is on. Three subtleties codex Phase-4 r2
  # surfaced, all handled below:
  #   - NO `local`/`declare` before the seed: `local` is itself shadowable, so
  #     reading the prior POSIX state into `local` vars would run a `local()`
  #     shadow with the secret still live. We snapshot into specifically-named
  #     GLOBAL vars via plain assignment (unshadowable) and `unset` them after.
  #   - CLEAR DEBUG/RETURN/ERR traps + functrace BEFORE the strip: a `set -T`
  #     DEBUG trap fires before every simple command and could RE-INSTALL a
  #     shadow AFTER we unset it. Clearing the trap first guarantees nothing
  #     re-shadows post-strip.
  #   - SECOND strip pass in non-POSIX mode: on macOS /bin/bash 3.2, `unset -f .`
  #     does not remove a `.()` function while POSIX mode is on, but does once
  #     it is off.
  # The caller's exact prior POSIX state (POSIXLY_CORRECT set/value + `posix`
  # shopt) is restored at the end — this module is sourced into the caller's
  # option set (see header), so a consumer that legitimately runs under
  # `set -o posix` must be unaffected. Pure-bash, builtin-only, no fork, Bash
  # 3.2-safe, idempotent.
  #
  # Snapshot prior POSIX state via parameter expansion (an unshadowable read)
  # into GLOBALs assigned WITHOUT `local`/`declare` (a plain assignment invokes
  # no function). `$SHELLOPTS` is a bash builtin variable a function cannot
  # intercept.
  _BRIDGE_SCRUB_PC_WAS_SET=0
  _BRIDGE_SCRUB_PC_VAL=""
  _BRIDGE_SCRUB_POSIX_WAS_ON=0
  if [[ -n "${POSIXLY_CORRECT+x}" ]]; then _BRIDGE_SCRUB_PC_WAS_SET=1; _BRIDGE_SCRUB_PC_VAL="$POSIXLY_CORRECT"; fi
  case ":${SHELLOPTS}:" in *:posix:*) _BRIDGE_SCRUB_POSIX_WAS_ON=1 ;; esac

  POSIXLY_CORRECT=1
  # Kill functrace/errtrace + DEBUG/RETURN/ERR traps FIRST so nothing can
  # re-install a shadow after the strip (genuine special builtins in POSIX mode).
  set +T +E 2>/dev/null || true
  trap - DEBUG RETURN ERR 2>/dev/null || true
  # Strip every interceptor function shadow (genuine `unset` in POSIX mode).
  # shellcheck disable=SC2086  # word-split the space-separated name list intentionally
  unset -f $_bridge_secret_scrub_interceptors 2>/dev/null || true
  # Leave POSIX mode UNCONDITIONALLY for the second strip pass (codex Phase-4
  # r2 finding 3): on macOS /bin/bash 3.2, `unset -f .` removes a `.()` function
  # only when POSIX mode is OFF. This second pass must NOT run in the caller's
  # restored mode — if the caller was in POSIX mode the `.()` strip would no-op
  # on 3.2. `unset`/`builtin` here are genuine (their shadows were stripped above
  # and the trap can no longer re-install them).
  set +o posix 2>/dev/null || true
  # shellcheck disable=SC2086  # word-split the space-separated name list intentionally
  builtin unset -f $_bridge_secret_scrub_interceptors 2>/dev/null || builtin true
  # Restore the caller's prior POSIX state EXACTLY, shopt FIRST then the var
  # value LAST (codex Phase-4 r2): on bash 3.2 `set -o posix` rewrites
  # POSIXLY_CORRECT to `y`, so the var must be restored AFTER the shopt to land
  # on the caller's exact prior value.
  if (( _BRIDGE_SCRUB_POSIX_WAS_ON )); then set -o posix 2>/dev/null || true; else set +o posix 2>/dev/null || true; fi
  if (( _BRIDGE_SCRUB_PC_WAS_SET )); then POSIXLY_CORRECT="$_BRIDGE_SCRUB_PC_VAL"; else unset POSIXLY_CORRECT 2>/dev/null || true; fi
  unset _BRIDGE_SCRUB_PC_WAS_SET _BRIDGE_SCRUB_PC_VAL _BRIDGE_SCRUB_POSIX_WAS_ON 2>/dev/null || true
  # BASH_ENV / ENV name a file every non-interactive (resp. POSIX) bash SOURCES
  # at startup; BASH_XTRACEFD redirects `set -x` trace to a caller-chosen fd.
  # The bridge uses none of these — drop them before any child fork.
  builtin unset BASH_ENV ENV BASH_XTRACEFD 2>/dev/null || builtin true
  # Neutralize an inherited `set -x` + malicious PS4 command-substitution (which
  # could capture a still-live secret into the trace stream).
  builtin set +x 2>/dev/null || builtin true
  builtin unset PS4 2>/dev/null || builtin true
  return 0
}

# Capture the three well-known secret values into the caller-named vars and
# unset them from the env. Builtin-only, no fork.
bridge_secret_scrub_capture() {
  local _oat_var="${1:-}" _api_var="${2:-}" _auth_var="${3:-}"
  [[ -n "$_oat_var" && -n "$_api_var" && -n "$_auth_var" ]] || return 2
  # Indirect read of the live env values, then unset the env names. The caller
  # vars hold the values; they are NOT exported by this function.
  printf -v "$_oat_var" '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}"
  printf -v "$_api_var" '%s' "${ANTHROPIC_API_KEY:-}"
  printf -v "$_auth_var" '%s' "${ANTHROPIC_AUTH_TOKEN:-}"
  unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
  return 0
}

# ── Codex ambient-key scrub (#1470 Phase 2, Q6) ──────────────────────
# The Codex fleet-sync model delivers the subscription `auth.json` as a
# FILE the `codex` binary reads from CODEX_HOME — NEVER as an ambient env
# var. So for a MANAGED Codex agent the OpenAI-key env var and the Codex-
# access-token env var must be actively REMOVED from the child env before
# the agent process forks (defense against a stale/foreign ambient key
# silently overriding the bridge-delivered file login). These two helpers
# mirror the Claude capture/restore above but for the Codex var names; the
# bridge-run.sh launch path scrubs unconditionally at process entry and
# restores ONLY for an explicitly unmanaged/operator-owned Codex run.
#
# Var names (fleet-credential-design.md §6/Q6): OPENAI_API_KEY (the API-key
# login env override) + CODEX_ACCESS_TOKEN (the subscription access-token
# env override). NEVER logged.
bridge_secret_scrub_capture_codex() {
  local _openai_var="${1:-}" _codex_token_var="${2:-}"
  [[ -n "$_openai_var" && -n "$_codex_token_var" ]] || return 2
  printf -v "$_openai_var" '%s' "${OPENAI_API_KEY:-}"
  printf -v "$_codex_token_var" '%s' "${CODEX_ACCESS_TOKEN:-}"
  unset OPENAI_API_KEY CODEX_ACCESS_TOKEN 2>/dev/null || true
  return 0
}

bridge_secret_scrub_restore_codex() {
  local _openai_var="${1:-}" _codex_token_var="${2:-}"
  [[ -n "$_openai_var" && -n "$_codex_token_var" ]] || return 2
  local _openai="${!_openai_var:-}" _codex_token="${!_codex_token_var:-}"
  [[ -n "$_openai" ]] && export OPENAI_API_KEY="$_openai"
  [[ -n "$_codex_token" ]] && export CODEX_ACCESS_TOKEN="$_codex_token"
  return 0
}

# Restore the three captured values back into the well-known env names (only
# when non-empty). Builtin-only, no fork.
bridge_secret_scrub_restore() {
  local _oat_var="${1:-}" _api_var="${2:-}" _auth_var="${3:-}"
  [[ -n "$_oat_var" && -n "$_api_var" && -n "$_auth_var" ]] || return 2
  local _oat="${!_oat_var:-}" _api="${!_api_var:-}" _auth="${!_auth_var:-}"
  [[ -n "$_oat" ]] && export CLAUDE_CODE_OAUTH_TOKEN="$_oat"
  [[ -n "$_api" ]] && export ANTHROPIC_API_KEY="$_api"
  [[ -n "$_auth" ]] && export ANTHROPIC_AUTH_TOKEN="$_auth"
  return 0
}

# Defensively close a possibly caller-preopened fd before the first child fork.
# Brace-group the redirect so `2>/dev/null` scopes to the close ONLY — a bare
# `exec N<&- 2>/dev/null` (exec with redirections, no command) would make the
# stderr redirect PERMANENT and swallow later diagnostics.
bridge_secret_scrub_close_fd() {
  local _fd="${1:-9}"
  eval "{ exec ${_fd}<&-; } 2>/dev/null" || builtin true
  return 0
}

# Pick the first existing executable from the candidates (hardcoded-absolute
# binaries near the live secret). `[[ -x ]]` is a builtin (no subprocess).
_bridge_secret_scrub_pick() {
  local _n
  for _n in "$@"; do
    [[ -x "$_n" ]] && { builtin printf '%s' "$_n"; return 0; }
  done
  # Last resort: the bare name (lets the caller's `|| true` paths fail gracefully).
  builtin printf '%s' "${1##*/}"
  return 0
}

# Generate a per-process random nonce. Two independent entropy sources combined
# (SRANDOM is unguessable on Bash 5.1+; $RANDOM/PID/EPOCHSECONDS fall back on
# older Bash) — builtins only, no subprocess, no PATH/function exposure.
bridge_secret_scrub_make_nonce() {
  local _out_var="${1:-}"
  [[ -n "$_out_var" ]] || return 2
  printf -v "$_out_var" '%s' "agb-secret-scrub-v1:${SRANDOM:-}:${RANDOM}${RANDOM}${RANDOM}:${BASHPID:-$$}:${EPOCHSECONDS:-0}"
  return 0
}

# Stash NAME=VALUE records on <fd> behind a per-process nonce. <nonce_out_var>
# receives the nonce (the caller exports it for the re-exec'd pass). Remaining
# args are NAME=VALUE strings. Returns 1 if no tempfile could be created.
bridge_secret_scrub_open_transit_fd() {
  local _fd="${1:-}" _nonce_var="${2:-}"
  [[ -n "$_fd" && -n "$_nonce_var" ]] || return 2
  shift 2
  local _mktemp _chmod _rm _file _nonce _rec
  _mktemp="$(_bridge_secret_scrub_pick /usr/bin/mktemp /bin/mktemp /opt/homebrew/bin/mktemp)"
  _chmod="$(_bridge_secret_scrub_pick /bin/chmod /usr/bin/chmod)"
  _rm="$(_bridge_secret_scrub_pick /bin/rm /usr/bin/rm)"
  bridge_secret_scrub_make_nonce _nonce
  if ! _file="$("$_mktemp" "${TMPDIR:-/tmp}/agb-secret-scrub.XXXXXX" 2>/dev/null)"; then
    return 1
  fi
  "$_chmod" 600 "$_file" 2>/dev/null || true
  {
    builtin printf '%s\0' "$_nonce"
    for _rec in "$@"; do
      builtin printf '%s\0' "$_rec"
    done
  } >"$_file"
  # Brace-group: a bare `exec N<file 2>/dev/null` would make the stderr redirect
  # permanent for the re-exec'd child.
  eval "{ exec ${_fd}<\"\$_file\"; } 2>/dev/null" || { "$_rm" -f -- "$_file" 2>/dev/null || true; return 1; }
  "$_rm" -f -- "$_file" 2>/dev/null || true
  printf -v "$_nonce_var" '%s' "$_nonce"
  return 0
}

# Read records back from <fd>, validating the nonce, into the caller-named vars,
# then CLOSE <fd>. The var-name args correspond to the well-known keys.
bridge_secret_scrub_read_transit_fd() {
  local _fd="${1:-}" _expected="${2:-}" _oat_var="${3:-}" _api_var="${4:-}" _auth_var="${5:-}"
  [[ -n "$_fd" && -n "$_expected" && -n "$_oat_var" && -n "$_api_var" && -n "$_auth_var" ]] || return 2
  local _payload _seen=""
  # Read NUL-delimited records from the inherited fd (builtins only, no fork).
  while IFS= builtin read -r -d '' _payload <&"$_fd"; do
    if [[ -z "$_seen" ]]; then
      # First record must equal the per-process nonce. A caller-preopened fd
      # cannot reproduce it (generated after the inherited fd was closed).
      [[ "$_payload" == "$_expected" ]] && { _seen=1; continue; }
      break
    fi
    case "$_payload" in
      CLAUDE_CODE_OAUTH_TOKEN=*) printf -v "$_oat_var" '%s' "${_payload#*=}" ;;
      ANTHROPIC_API_KEY=*) printf -v "$_api_var" '%s' "${_payload#*=}" ;;
      ANTHROPIC_AUTH_TOKEN=*) printf -v "$_auth_var" '%s' "${_payload#*=}" ;;
    esac
  done
  bridge_secret_scrub_close_fd "$_fd"
  unset _payload _seen
  return 0
}
