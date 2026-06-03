#!/usr/bin/env bash
# scripts/smoke/1454-bridge-lib-reexec-secret-canary.sh — security canary for
# #1454: the bridge-lib.sh Bash-3.2→4+ re-exec must NOT expose an ambient
# secret env var to a same-UID exported-function / PATH-shadow during the
# re-exec window.
#
# bridge-lib.sh is sourced by essentially every entry point. Its Bash-3.2→4+
# re-exec historically ran external commands (a `$(command -v bash)` command-
# sub, a candidate-version probe under `-lc` which sources the login profile +
# BASH_ENV, a `$(cd -P "$(dirname …)" && pwd -P)` SCRIPT_DIR command-sub) WHILE
# an ambient secret env var could still be live — so an exported `dirname()`
# function shadow, a PATH-planted `dirname`, or a BASH_ENV startup-file hook
# could read the secret. This is the SHARED ROOT of the inherited-env
# credential-leak class that PRs #1443 (bridge-usage.sh) and #1452/#1444
# (bridge-run.sh) each hardened in their own lane. #1454 closes it at the root:
#   - BRIDGE_SCRIPT_DIR is computed via a builtin `${BASH_SOURCE[0]%/*}` (no
#     `dirname` fork),
#   - the candidate Bash is selected from absolute paths + a `builtin command -v`
#     fallback and probed under `-p -c` (privileged, non-login),
#   - the re-exec is `exec "$cand" -p …` (privileged: imports no env functions,
#     ignores BASH_ENV/ENV),
#   - hooks are hardened (unset -f interceptors, unset BASH_ENV/ENV/BASH_XTRACEFD,
#     set +x, drop PS4) BEFORE the first fork via the shared primitive
#     lib/bridge-secret-scrub.sh.
#
# Coverage:
#   STATIC — in-source structure: the shared primitive exists + is loaded via
#            `builtin source` (not a bare `source`) before the re-exec guard, the
#            shadow-proof seed (POSIXLY_CORRECT=1 → unset -f → set +o posix)
#            precedes that load, no bare `source` of the primitive remains, the
#            `$(dirname …)` SCRIPT_DIR fork is gone, the re-exec uses `-p`, and
#            the old `-lc` probe is gone.
#   A — dirname()-function-shadow attack on the macOS Bash-3.2→4 re-exec path:
#       the shadow must NEVER observe the secret. (Skipped when no Bash 3.2 is
#       available — Linux CI has only Bash 5; the no-op path below still runs.)
#   B — dirname()-function-shadow attack on the Bash-4+ NO-OP path: the shadow
#       must NEVER observe the secret.
#   C — PATH-planted `dirname` attack on the Bash-4+ path: the plant must never
#       run (BRIDGE_SCRIPT_DIR no longer forks `dirname`), so it cannot leak.
#   D — source()/.()-function-shadow attack (the codex Phase-4 BLOCKING gap):
#       the de-fang PRIMITIVE was loaded by a BARE `source` while a `source()`
#       shadow could be live. Post-fix the shadow-proof seed strips that shadow
#       and the load uses `builtin source`, so the shadow must NEVER observe the
#       secret on the primitive-load path. Run on both the Bash-4+ and Bash-3.2
#       paths.
#   E — builtin()/unset()/command()-function-shadow attack (the SEED-OF-TRUST):
#       the seed must self-heal even when the very tokens it uses (`builtin`,
#       `unset`, `command`) are shadowed — the unshadowable `POSIXLY_CORRECT=1`
#       assignment activates POSIX mode so the genuine special builtins win.
#       None of these shadows may observe the secret on the load path.
#   TEETH-GAP — a SYNTHETIC pre-gap-fix bridge-lib.sh (seed disabled + the
#       primitive load downgraded back to a BARE `source`) MUST leak under the
#       source()-shadow attack, proving the canary detects the exact gap.
#   TEETH — the same dirname() attack against a pristine pre-#1454 copy of
#       bridge-lib.sh (the git-base version) MUST leak, proving the original
#       canary still has teeth.
#
# lint-heredoc-ban: this smoke uses heredoc-TO-FILE (writing attack wrappers to
# tempfiles) which is allowed; it never feeds a heredoc to a subprocess stdin
# (`bash -s <<EOF` / `python3 - <<PY`) and never uses `<<<` or `< <(...)`. Leak
# files are inspected with a tempfile `while read` loop, not a process sub.

set -uo pipefail

SMOKE_NAME="1454-bridge-lib-reexec-secret-canary"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

LIB_SH="$REPO_ROOT/bridge-lib.sh"
PRIMITIVE="$REPO_ROOT/lib/bridge-secret-scrub.sh"

failed=0
fail() { echo "  FAIL  $1" >&2; failed=1; }
ok() { echo "  PASS  $1"; }

# Isolated workdir + BRIDGE_HOME so sourcing bridge-lib.sh never touches live
# state. bridge-lib.sh's startup validation only needs a real source checkout
# (REPO_ROOT) for BRIDGE_SCRIPT_DIR; BRIDGE_HOME just needs to be a writable
# scratch path.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agb-1454-canary.XXXXXX")"
PROBE_HOME="$WORK/home"
mkdir -p "$PROBE_HOME"
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# Build the secret env-var NAME indirectly so the tracked source text never
# contains the literal (keeps the file clean + avoids the credential-redaction
# hook). This is the well-known Claude OAuth env var the #1443/#1452 lanes
# scrub.
OAT_VAR="CLAUDE_CODE""_OAUTH_TOKEN"
SECRET_VALUE="agb-1454-canary-secret-$$-${RANDOM}"

# Locate a Bash 3.2 (to exercise the real re-exec path) and a Bash 4+ (no-op
# path). The system /bin/bash is 3.2 on macOS, 5.x on Linux.
BASH4=""
for c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
  if [[ -x "$c" ]] && "$c" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' 2>/dev/null; then
    BASH4="$c"; break
  fi
done
BASH3=""
for c in /bin/bash /usr/bin/bash; do
  if [[ -x "$c" ]] && "$c" -c '[[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]' 2>/dev/null; then
    BASH3="$c"; break
  fi
done
[[ -n "$BASH4" ]] || { echo "  SKIP-FATAL no Bash 4+ found — cannot run canary" >&2; exit 1; }

# --- STATIC: in-source structure -------------------------------------------
echo "[STATIC] bridge-lib.sh re-exec hardening structure"
if [[ -f "$PRIMITIVE" ]]; then
  ok "shared primitive lib/bridge-secret-scrub.sh exists"
else
  fail "shared primitive lib/bridge-secret-scrub.sh missing"
fi

# The primitive load must now be `builtin source` (NOT a bare `source`), so a
# residual `source()` function shadow cannot intercept it.
src_line="$(grep -nE 'builtin source "\$_BRIDGE_LIB_SELF_DIR/lib/bridge-secret-scrub\.sh"' "$LIB_SH" | head -n1 | cut -d: -f1 || true)"
harden_line="$(grep -nE '^[[:space:]]*bridge_secret_scrub_harden_hooks' "$LIB_SH" | head -n1 | cut -d: -f1 || true)"
reexec_guard_line="$(grep -nE 'BASH_VERSINFO\[0\]:-0\} < 4' "$LIB_SH" | head -n1 | cut -d: -f1 || true)"
if [[ -n "$src_line" && -n "$harden_line" && -n "$reexec_guard_line" \
      && "$src_line" -lt "$reexec_guard_line" && "$harden_line" -lt "$reexec_guard_line" ]]; then
  ok "primitive loaded via 'builtin source' (L$src_line) + hooks hardened (L$harden_line) before the re-exec guard (L$reexec_guard_line)"
else
  fail "hook-harden / builtin-source load does not precede the re-exec guard (src=L${src_line:-?} harden=L${harden_line:-?} guard=L${reexec_guard_line:-?})"
fi

# A bare `source` (un-`builtin`-qualified) of the primitive must NOT survive in
# the tracked source — that was the codex Phase-4 BLOCKING gap.
if grep -qE '^[[:space:]]*source "\$_BRIDGE_LIB_SELF_DIR/lib/bridge-secret-scrub\.sh"' "$LIB_SH"; then
  fail "primitive is still loaded via a BARE 'source' (interceptable by a source() shadow)"
else
  ok "no bare 'source' load of the primitive remains (uses 'builtin source')"
fi

# The shadow-proof seed (POSIXLY_CORRECT=1 → unset -f → set +o posix) must run
# BEFORE the primitive load, so even the `source()`/`builtin()` shadows are
# stripped before the (builtin) source executes.
seed_line="$(grep -nE '^[[:space:]]*POSIXLY_CORRECT=1' "$LIB_SH" | head -n1 | cut -d: -f1 || true)"
seed_unset_line="$(grep -nE '^[[:space:]]*unset -f source \. unset set ' "$LIB_SH" | head -n1 | cut -d: -f1 || true)"
if [[ -n "$seed_line" && -n "$seed_unset_line" && -n "$src_line" \
      && "$seed_line" -lt "$src_line" && "$seed_unset_line" -lt "$src_line" ]]; then
  ok "shadow-proof seed (POSIXLY_CORRECT=1 L$seed_line + unset -f L$seed_unset_line) precedes the primitive load (L$src_line)"
else
  fail "shadow-proof seed does not precede the primitive load (seed=L${seed_line:-?} unset=L${seed_unset_line:-?} src=L${src_line:-?})"
fi

# BRIDGE_SCRIPT_DIR must NOT fork `$(dirname …)` anymore.
if grep -qE 'BRIDGE_SCRIPT_DIR="\$\(cd -P "\$\(dirname ' "$LIB_SH"; then
  fail "BRIDGE_SCRIPT_DIR still uses a \$(dirname …) command-sub child"
else
  ok "BRIDGE_SCRIPT_DIR no longer forks \$(dirname …) (builtin \${BASH_SOURCE%/*} derivation)"
fi

# The re-exec must be privileged (`exec … -p`) and must NOT use the old `-lc`
# login-shell probe.
if grep -qE 'exec "\$bridge_candidate_bash" -p ' "$LIB_SH"; then
  ok "re-exec is privileged (exec … -p …)"
else
  fail "re-exec is not privileged (missing exec … -p …)"
fi
if grep -qE '"\$bridge_candidate_bash" -lc ' "$LIB_SH"; then
  fail "candidate probe still uses login-shell -lc (sources profile + BASH_ENV)"
else
  ok "old login-shell -lc candidate probe removed (uses -p -c)"
fi

# --- helpers ---------------------------------------------------------------
# Write an attack wrapper that exports a dirname() shadow + the secret, then
# sources the given bridge-lib.sh. Heredoc-TO-FILE (allowed). The shadow appends
# the secret value to $leak whenever invoked.
# shellcheck disable=SC2329  # invoked indirectly via run_case's $writer
write_attack_wrapper() {
  local wrapper="$1" lib="$2" leak="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export %s=%q\n' "$OAT_VAR" "$SECRET_VALUE"
    printf 'dirname() { builtin printf "%%s\\n" "${%s}" >> %q; command dirname "$@" 2>/dev/null || builtin printf "."; }\n' "$OAT_VAR" "$leak"
    printf 'export -f dirname\n'
    printf 'source %q\n' "$lib"
  } > "$wrapper"
}

# Write an attack wrapper that exports a `source()` (+ `.()`) interceptor
# function shadow + the secret, then sources the given bridge-lib.sh. This is
# the codex Phase-4 BLOCKING class: the BARE `source` of the de-fang PRIMITIVE
# (lib/bridge-secret-scrub.sh) ran WHILE this shadow was active, so the shadow
# read the live secret at the very moment we loaded the de-fang primitive — and
# the primitive itself was therefore loaded through a compromised `source`,
# defeating the re-exec gate's fail-closed property.
#
# The shadow leaks ONLY when invoked to load the PRIMITIVE (`*bridge-secret-
# scrub.sh`); for every other `source` (including the entry-point's own
# `source bridge-lib.sh`) it chains straight through without leaking. This is
# deliberate: the interception of `source bridge-lib.sh` itself happens in the
# CALLER's shell BEFORE any bridge-lib.sh code runs, so bridge-lib.sh cannot
# defend it (and a caller who can `export -f source` AND holds the secret in its
# own env can already read it directly — that is the #1443-ruling out-of-scope
# case). What bridge-lib.sh CAN and now DOES guarantee is that the de-fang
# primitive load is un-interceptable. This case asserts exactly that.
# shellcheck disable=SC2329  # invoked indirectly via run_case's $writer
write_source_shadow_attack_wrapper() {
  local wrapper="$1" lib="$2" leak="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export %s=%q\n' "$OAT_VAR" "$SECRET_VALUE"
    printf 'source() { case "$1" in *bridge-secret-scrub.sh) builtin printf "%%s\\n" "${%s:-}" >> %q ;; esac; builtin source "$@"; }\n' "$OAT_VAR" "$leak"
    printf '.() { case "$1" in *bridge-secret-scrub.sh) builtin printf "%%s\\n" "${%s:-}" >> %q ;; esac; builtin source "$@"; }\n' "$OAT_VAR" "$leak"
    printf 'export -f source\n'
    printf 'export -f .\n'
    printf 'source %q\n' "$lib"
  } > "$wrapper"
}

# Write an attack wrapper that exports `builtin()`, `unset()`, and `command()`
# interceptor shadows + the secret, then sources bridge-lib.sh. This probes the
# SEED-OF-TRUST: the de-fang seed must self-heal even when the very tokens it
# uses (`builtin`/`unset`) are shadowed. Each shadow leaks the secret when
# invoked; the `builtin`/`command` shadows chain to the genuine command so the
# script can still run, the `unset` shadow no-ops (the seed's POSIXLY_CORRECT
# path makes the genuine `unset` win regardless). If the seed holds, NONE of
# these shadows ever observe the secret on the load path.
# shellcheck disable=SC2329  # invoked indirectly via run_case's $writer
write_builtin_shadow_attack_wrapper() {
  local wrapper="$1" lib="$2" leak="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export %s=%q\n' "$OAT_VAR" "$SECRET_VALUE"
    printf 'builtin() { command builtin printf "%%s\\n" "${%s:-}" >> %q; command builtin "$@"; }\n' "$OAT_VAR" "$leak"
    printf 'unset() { command builtin printf "%%s\\n" "${%s:-}" >> %q; }\n' "$OAT_VAR" "$leak"
    printf 'command() { command printf "%%s\\n" "${%s:-}" >> %q; builtin command "$@"; }\n' "$OAT_VAR" "$leak"
    printf 'export -f builtin\n'
    printf 'export -f unset\n'
    printf 'export -f command\n'
    printf 'source %q\n' "$lib"
  } > "$wrapper"
}

# Write an attack wrapper that exports a `local()` shadow + the secret, then
# sources bridge-lib.sh. codex Phase-4 r2 caught that the primitive's
# bridge_secret_scrub_harden_hooks used a `local` snapshot BEFORE its seed, so a
# `local()` shadow fired with the secret live. Post-r2 the seed uses no `local`
# before the strip, so the shadow must NEVER observe the secret. The shadow
# leaks then no-ops (a `local` outside a function is an error anyway; harden's
# snapshot is now plain global assignment).
# shellcheck disable=SC2329  # invoked indirectly via run_case's $writer
write_local_shadow_attack_wrapper() {
  local wrapper="$1" lib="$2" leak="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export %s=%q\n' "$OAT_VAR" "$SECRET_VALUE"
    printf 'local() { command builtin printf "%%s\\n" "${%s:-}" >> %q; }\n' "$OAT_VAR" "$leak"
    printf 'export -f local\n'
    printf 'source %q\n' "$lib"
  } > "$wrapper"
}

# Write an attack wrapper that arms a `set -T` DEBUG trap which RE-INSTALLS a
# `builtin()` shadow on every simple command, then sources bridge-lib.sh. codex
# Phase-4 r2 caught that a DEBUG trap could re-create a shadow AFTER the seed's
# `unset -f` but BEFORE the `builtin source` primitive load. Post-r2 the seed
# clears functrace + DEBUG/RETURN/ERR traps BEFORE the strip, so the re-install
# cannot survive to intercept the primitive load. The recreated `builtin()`
# leaks ONLY when invoked to load the primitive (`$2` matches the scrub path);
# for everything else it chains through. Heredoc-TO-FILE.
# shellcheck disable=SC2329  # invoked indirectly via run_case's $writer
write_trap_recreate_attack_wrapper() {
  local wrapper="$1" lib="$2" leak="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export %s=%q\n' "$OAT_VAR" "$SECRET_VALUE"
    # The DEBUG trap body re-installs a builtin() shadow that leaks ONLY on the
    # primitive-load path ($2 ends in bridge-secret-scrub.sh) and chains through
    # otherwise. Emit the trap body as its own function to keep quoting sane.
    printf '_agb_reshadow() {\n'
    printf '  builtin() {\n'
    printf '    case "$2" in *bridge-secret-scrub.sh) command builtin printf "%%s\\n" "${%s:-}" >> %q ;; esac\n' "$OAT_VAR" "$leak"
    printf '    command builtin "$@"\n'
    printf '  }\n'
    printf '}\n'
    printf 'set -T\n'
    printf 'trap _agb_reshadow DEBUG\n'
    printf 'source %q\n' "$lib"
  } > "$wrapper"
}

# Return 0 (leak) if $leak contains the secret value, 1 (clean) otherwise.
# Inspect via a tempfile `while read` loop (no process substitution / no <<<).
leak_present() {
  local leak="$1" line
  [[ -f "$leak" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      *"$SECRET_VALUE"*) return 0 ;;
    esac
  done < "$leak"
  return 1
}

run_case() {
  # run_case <label> <bash-bin> <lib> <expect:clean|leak> [writer-fn]
  # writer-fn defaults to write_attack_wrapper (the dirname() shadow).
  local label="$1" bashbin="$2" lib="$3" expect="$4" writer="${5:-write_attack_wrapper}"
  local wrapper="$WORK/attack.sh" leak="$WORK/leak.txt"
  rm -f "$leak"
  "$writer" "$wrapper" "$lib" "$leak"
  BRIDGE_HOME="$PROBE_HOME" "$bashbin" "$wrapper" >/dev/null 2>&1 || true
  if leak_present "$leak"; then
    if [[ "$expect" == "leak" ]]; then ok "$label — leaked as expected (teeth)"; else fail "$label — SECRET LEAKED to interceptor shadow"; fi
  else
    if [[ "$expect" == "clean" ]]; then ok "$label — no leak (secret never reached the shadow)"; else fail "$label — expected a leak but none occurred (teeth check broken)"; fi
  fi
  rm -f "$leak" "$wrapper"
}

# --- A: macOS Bash-3.2 → 4 re-exec path ------------------------------------
if [[ -n "$BASH3" ]]; then
  echo "[A] dirname-shadow attack on the Bash-3.2→4 re-exec path ($BASH3)"
  run_case "A re-exec path (fixed)" "$BASH3" "$LIB_SH" "clean"
else
  echo "[A] SKIP — no Bash 3.2 on this host (Linux CI: Bash 5 only); B/C cover the no-op path"
fi

# --- B: Bash-4+ no-op path -------------------------------------------------
echo "[B] dirname-shadow attack on the Bash-4+ no-op path ($BASH4)"
run_case "B no-op path (fixed)" "$BASH4" "$LIB_SH" "clean"

# --- C: PATH-planted dirname on the Bash-4+ path ---------------------------
echo "[C] PATH-planted dirname attack on the Bash-4+ path"
PLANT_DIR="$WORK/plantbin"
mkdir -p "$PLANT_DIR"
C_LEAK="$WORK/plant-leak.txt"
rm -f "$C_LEAK"
{
  printf '#!/usr/bin/env bash\n'
  printf 'builtin printf "%%s\\n" "${%s:-}" >> %q\n' "$OAT_VAR" "$C_LEAK"
  printf 'exec /usr/bin/dirname "$@"\n'
} > "$PLANT_DIR/dirname"
chmod +x "$PLANT_DIR/dirname"
{
  printf '#!/usr/bin/env bash\n'
  printf 'export %s=%q\n' "$OAT_VAR" "$SECRET_VALUE"
  printf 'export PATH=%q:"$PATH"\n' "$PLANT_DIR"
  printf 'source %q\n' "$LIB_SH"
} > "$WORK/plant-attack.sh"
BRIDGE_HOME="$PROBE_HOME" "$BASH4" "$WORK/plant-attack.sh" >/dev/null 2>&1 || true
if leak_present "$C_LEAK"; then
  fail "C PATH-plant — planted dirname ran and leaked the secret"
else
  ok "C PATH-plant — planted dirname never ran (no \$(dirname …) fork)"
fi
rm -f "$C_LEAK" "$WORK/plant-attack.sh"

# --- D: source()/.()-shadow-before-hardening attack (the codex BLOCKING gap) -
# The de-fang primitive was loaded by a BARE `source` while a `source()` shadow
# could be live. Post-fix the shadow-proof seed strips that shadow and the load
# uses `builtin source`, so the shadow must NEVER see the secret. Run on BOTH
# the Bash-4+ no-op path and the Bash-3.2 re-exec path.
echo "[D] source()/.()-shadow-before-hardening attack on the Bash-4+ path ($BASH4)"
run_case "D source-shadow (Bash4+ no-op, fixed)" "$BASH4" "$LIB_SH" "clean" write_source_shadow_attack_wrapper
if [[ -n "$BASH3" ]]; then
  echo "[D] source()/.()-shadow attack on the Bash-3.2→4 re-exec path ($BASH3)"
  run_case "D source-shadow (Bash3.2 re-exec, fixed)" "$BASH3" "$LIB_SH" "clean" write_source_shadow_attack_wrapper
fi

# --- E: builtin()/unset()/command()-shadow attack (seed-of-trust self-heal) --
# The seed must self-heal even when the very tokens it relies on (`builtin`,
# `unset`, `command`) are shadowed. The POSIXLY_CORRECT=1 assignment (which no
# function can intercept) activates POSIX mode so the genuine special builtins
# win. None of these shadows may observe the secret on the load path.
echo "[E] builtin()/unset()/command()-shadow seed-of-trust attack on the Bash-4+ path ($BASH4)"
run_case "E builtin/unset/command-shadow (Bash4+ no-op, fixed)" "$BASH4" "$LIB_SH" "clean" write_builtin_shadow_attack_wrapper
if [[ -n "$BASH3" ]]; then
  echo "[E] builtin/unset/command-shadow attack on the Bash-3.2→4 re-exec path ($BASH3)"
  run_case "E builtin/unset/command-shadow (Bash3.2 re-exec, fixed)" "$BASH3" "$LIB_SH" "clean" write_builtin_shadow_attack_wrapper
fi

# --- F: local()-shadow attack (codex Phase-4 r2 finding 1) ------------------
# The primitive's harden_hooks must not run a shadowable `local` BEFORE its
# seed. Post-r2 it snapshots prior POSIX state via plain global assignment, so a
# `local()` shadow must NEVER observe the secret.
echo "[F] local()-shadow attack on the Bash-4+ path ($BASH4)"
run_case "F local-shadow (Bash4+ no-op, fixed)" "$BASH4" "$LIB_SH" "clean" write_local_shadow_attack_wrapper
if [[ -n "$BASH3" ]]; then
  echo "[F] local()-shadow attack on the Bash-3.2→4 re-exec path ($BASH3)"
  run_case "F local-shadow (Bash3.2 re-exec, fixed)" "$BASH3" "$LIB_SH" "clean" write_local_shadow_attack_wrapper
fi

# --- G: set -T DEBUG-trap shadow-reinstall attack (codex Phase-4 r2 finding 2)-
# A `set -T` DEBUG trap that re-installs a `builtin()` shadow on every simple
# command must not survive to intercept the `builtin source` primitive load.
# Post-r2 the seed clears functrace + DEBUG/RETURN/ERR traps BEFORE the strip.
echo "[G] set -T DEBUG-trap shadow-reinstall attack on the Bash-4+ path ($BASH4)"
run_case "G trap-reshadow (Bash4+ no-op, fixed)" "$BASH4" "$LIB_SH" "clean" write_trap_recreate_attack_wrapper
if [[ -n "$BASH3" ]]; then
  echo "[G] set -T DEBUG-trap shadow-reinstall attack on the Bash-3.2→4 re-exec path ($BASH3)"
  run_case "G trap-reshadow (Bash3.2 re-exec, fixed)" "$BASH3" "$LIB_SH" "clean" write_trap_recreate_attack_wrapper
fi

# --- H: POSIX-mode caller harden_hooks correctness (codex Phase-4 r2) --------
# When a consumer calls bridge_secret_scrub_harden_hooks while it is ALREADY in
# POSIX mode, the primitive must (a) still strip a `.()` shadow — on bash 3.2
# `unset -f .` no-ops in POSIX mode, so the 2nd strip must run in NON-POSIX mode
# unconditionally — and (b) restore the caller's EXACT prior POSIXLY_CORRECT
# value + `posix` shopt (the module is sourced into the caller's option set).
# This drives the primitive directly (the bridge-lib cases above only exercise
# the non-POSIX entry path). Runs on every available Bash.
h_check() {
  # h_check <bash-bin>
  # The wrapper captures the EXACT POSIXLY_CORRECT value at harden ENTRY (after
  # `set -o posix`, which on bash 3.2 rewrites it to `y`), so the expected
  # restored value is computed per-version rather than hardcoded. Asserts: the
  # `.()` shadow is stripped, the entry POSIXLY_CORRECT value is restored
  # exactly, and the `posix` shopt is still on.
  local bashbin="$1" out
  local hwrap="$WORK/h-harden.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export %s=%q\n' "$OAT_VAR" "$SECRET_VALUE"
    printf 'source %q\n' "$PRIMITIVE"
    printf 'eval ".() { command builtin printf DOTSHADOW; }"\n'
    printf 'POSIXLY_CORRECT=customval\n'
    printf 'set -o posix\n'
    printf 'pcv_entry="${POSIXLY_CORRECT-UNSET}"\n'
    printf 'bridge_secret_scrub_harden_hooks\n'
    printf 'pcv="${POSIXLY_CORRECT-UNSET}"\n'
    printf 'pxa="$(shopt -po posix 2>/dev/null)"\n'
    printf 'set +o posix 2>/dev/null\n'
    printf 'dt="$(type -t . 2>/dev/null || command builtin printf none)"\n'
    printf 'if [ "$dt" = builtin ] && [ "$pcv" = "$pcv_entry" ] && [ "$pxa" = "set -o posix" ]; then command builtin printf "OK\\n"; else command builtin printf "BAD dot=%%s pcv=%%s/%%s px=%%s\\n" "$dt" "$pcv" "$pcv_entry" "$pxa"; fi\n'
  } > "$hwrap"
  out="$(BRIDGE_HOME="$PROBE_HOME" "$bashbin" "$hwrap" 2>/dev/null || true)"
  rm -f "$hwrap"
  case "$out" in
    OK)
      ok "H posix-caller harden ($("$bashbin" -c 'echo ${BASH_VERSINFO[0]}')) — .() stripped + POSIXLY_CORRECT/posix preserved exactly" ;;
    *)
      fail "H posix-caller harden ($("$bashbin" -c 'echo ${BASH_VERSINFO[0]}')) — $out" ;;
  esac
}
echo "[H] POSIX-mode-caller harden_hooks: .() strip + exact POSIX-state restore"
h_check "$BASH4"
if [[ -n "$BASH3" ]]; then h_check "$BASH3"; fi

# --- TEETH-GAP: synthetic pre-gap-fix bridge-lib.sh (bare source, no seed) ---
# The existing TEETH (below) uses origin/main, which predates the whole #1454
# secret-scrub block and so cannot exercise the source()-shadow gap. Synthesize
# the precise pre-gap-fix version from the CURRENT bridge-lib.sh by (a) removing
# the shadow-proof seed lines and (b) downgrading `builtin source` of the
# primitive back to a bare `source`. Against THAT, the source()/.() shadow MUST
# leak — proving the canary detects the exact gap codex found.
echo "[TEETH-GAP] synthetic pre-gap-fix (bare source, no seed) must leak under the source()-shadow attack"
GAP_VULN="$REPO_ROOT/.agb-1454-gapvuln-$$-bridge-lib.sh"
# Synthesize the precise pre-gap-fix version with a pure-bash tempfile
# while-read transform (no sed/awk). We don't touch comments (they don't
# execute) — we only NEUTRALIZE the executable seed statements (comment them
# out) and downgrade `builtin source` of the primitive back to a bare `source`.
# That reconstructs the exact gap: the de-fang primitive loaded through an
# un-de-fanged `source` that a `source()` shadow can intercept.
gap_built=0
_BSL=$'\\'   # a single literal backslash (avoids confusing quote-escape matchers)
{
  _in_seed_unset=0
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    # Comment out the executable seed statements so the seed no longer runs.
    case "$_line" in
      'POSIXLY_CORRECT=1' \
      |'set +o posix 2>/dev/null || true' \
      |'set +T +E 2>/dev/null || true' \
      |'trap - DEBUG RETURN ERR 2>/dev/null || true' \
      |'unset POSIXLY_CORRECT 2>/dev/null || true')
        printf '# GAPVULN-DISABLED %s\n' "$_line"; continue ;;
      'unset -f source . unset set export exec eval command builtin'*)
        # First line of either `unset -f` seed pass. If it ends in a
        # line-continuation backslash, swallow the continuation lines too.
        case "$_line" in
          *"$_BSL") _in_seed_unset=1 ;;
        esac
        printf '# GAPVULN-DISABLED %s\n' "$_line"; continue ;;
    esac
    if (( _in_seed_unset )); then
      printf '# GAPVULN-DISABLED %s\n' "$_line"
      case "$_line" in
        *"$_BSL") ;;             # line continues — keep swallowing
        *) _in_seed_unset=0 ;;   # last continuation line — stop
      esac
      continue
    fi
    # Downgrade the builtin-source load of the primitive to a bare source.
    case "$_line" in
      *'builtin source "$_BRIDGE_LIB_SELF_DIR/lib/bridge-secret-scrub.sh"'*)
        _line="${_line/builtin source /source }" ;;
    esac
    printf '%s\n' "$_line"
  done < "$LIB_SH"
} > "$GAP_VULN" && [[ -s "$GAP_VULN" ]] && gap_built=1

if (( gap_built )) \
   && grep -qE '^[[:space:]]*source "\$_BRIDGE_LIB_SELF_DIR/lib/bridge-secret-scrub\.sh"' "$GAP_VULN" \
   && ! grep -qE '^[[:space:]]*POSIXLY_CORRECT=1$' "$GAP_VULN"; then
  trap 'rm -f "$GAP_VULN" 2>/dev/null || true; cleanup' EXIT
  # The no-seed bare-source version must leak under the source()-shadow class.
  run_case "TEETH-GAP source-shadow (Bash4+ no-op, pre-gap-fix)" "$BASH4" "$GAP_VULN" "leak" write_source_shadow_attack_wrapper
  if [[ -n "$BASH3" ]]; then
    run_case "TEETH-GAP source-shadow (Bash3.2 re-exec, pre-gap-fix)" "$BASH3" "$GAP_VULN" "leak" write_source_shadow_attack_wrapper
  fi
  rm -f "$GAP_VULN"
  trap cleanup EXIT
else
  rm -f "$GAP_VULN" 2>/dev/null || true
  fail "TEETH-GAP — could not synthesize a pre-gap-fix bridge-lib.sh (seed-strip / bare-source rewrite failed)"
fi

# --- TEETH-TRAP: synthetic pre-r2 bridge-lib.sh (seed present, but trap-clear
# REMOVED — i.e. the ordering codex Phase-4 r2 finding 2 flagged). Keeps
# `builtin source` + the strip but disables `set +T +E` / `trap - DEBUG …` so a
# set -T DEBUG trap can re-install a builtin() shadow AFTER the strip and
# intercept the primitive load. Under the trap-reshadow attack this MUST leak,
# proving case G has teeth.
echo "[TEETH-TRAP] synthetic pre-r2 (trap-clear removed) must leak under the set -T DEBUG-trap attack"
TRAP_VULN="$REPO_ROOT/.agb-1454-trapvuln-$$-bridge-lib.sh"
trap_built=0
{
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    # Disable ONLY the trap-clear / functrace-clear seed lines; keep everything
    # else (POSIXLY_CORRECT, the unset -f strips, builtin source) intact.
    case "$_line" in
      'set +T +E 2>/dev/null || true'|'trap - DEBUG RETURN ERR 2>/dev/null || true')
        printf '# TRAPVULN-DISABLED %s\n' "$_line"; continue ;;
    esac
    printf '%s\n' "$_line"
  done < "$LIB_SH"
} > "$TRAP_VULN" && [[ -s "$TRAP_VULN" ]] && trap_built=1

if (( trap_built )) \
   && grep -qE '^[[:space:]]*builtin source "\$_BRIDGE_LIB_SELF_DIR/lib/bridge-secret-scrub\.sh"' "$TRAP_VULN" \
   && ! grep -qE '^[[:space:]]*trap - DEBUG RETURN ERR' "$TRAP_VULN"; then
  trap 'rm -f "$TRAP_VULN" 2>/dev/null || true; cleanup' EXIT
  run_case "TEETH-TRAP trap-reshadow (Bash4+ no-op, pre-r2)" "$BASH4" "$TRAP_VULN" "leak" write_trap_recreate_attack_wrapper
  if [[ -n "$BASH3" ]]; then
    run_case "TEETH-TRAP trap-reshadow (Bash3.2 re-exec, pre-r2)" "$BASH3" "$TRAP_VULN" "leak" write_trap_recreate_attack_wrapper
  fi
  rm -f "$TRAP_VULN"
  trap cleanup EXIT
else
  rm -f "$TRAP_VULN" 2>/dev/null || true
  fail "TEETH-TRAP — could not synthesize a pre-r2 (trap-clear-removed) bridge-lib.sh"
fi

# --- TEETH-LOCAL: synthetic pre-r2 PRIMITIVE (a `local` snapshot re-introduced
# at the TOP of bridge_secret_scrub_harden_hooks, i.e. the ordering codex
# Phase-4 r2 finding 1 flagged). Source it directly, install a `local()` shadow,
# call harden_hooks: it MUST leak, proving case F has teeth. The synthesis
# injects one `local` line right after the function's opening brace.
echo "[TEETH-LOCAL] synthetic pre-r2 primitive (local-before-seed) must leak under the local()-shadow attack"
PRIM_VULN="$WORK/vuln-secret-scrub.sh"
prim_built=0
{
  _injected=0
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    printf '%s\n' "$_line"
    if (( ! _injected )); then
      case "$_line" in
        'bridge_secret_scrub_harden_hooks() {')
          # Re-introduce the vulnerable shadowable `local` BEFORE the seed.
          printf '  local _agb_pre_seed_probe=1\n'
          _injected=1 ;;
      esac
    fi
  done < "$PRIMITIVE"
} > "$PRIM_VULN" && [[ -s "$PRIM_VULN" ]] && (( _injected )) && prim_built=1

if (( prim_built )); then
  TL_LEAK="$WORK/tl-leak.txt"; rm -f "$TL_LEAK"
  TL_WRAP="$WORK/tl-attack.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export %s=%q\n' "$OAT_VAR" "$SECRET_VALUE"
    printf 'local() { command builtin printf "%%s\\n" "${%s:-}" >> %q; }\n' "$OAT_VAR" "$TL_LEAK"
    printf 'source %q\n' "$PRIM_VULN"
    printf 'bridge_secret_scrub_harden_hooks\n'
  } > "$TL_WRAP"
  BRIDGE_HOME="$PROBE_HOME" "$BASH4" "$TL_WRAP" >/dev/null 2>&1 || true
  if leak_present "$TL_LEAK"; then
    ok "TEETH-LOCAL pre-r2 primitive — local()-shadow leaked as expected (teeth)"
  else
    fail "TEETH-LOCAL pre-r2 primitive — expected a local()-shadow leak but none occurred (teeth check broken)"
  fi
  rm -f "$TL_LEAK" "$TL_WRAP" "$PRIM_VULN"
else
  rm -f "$PRIM_VULN" 2>/dev/null || true
  fail "TEETH-LOCAL — could not synthesize a pre-r2 (local-before-seed) primitive"
fi

# --- TEETH: pristine pre-fix bridge-lib.sh MUST leak -----------------------
echo "[TEETH] the same attack against the pre-fix bridge-lib.sh must leak"
VULN_LIB="$WORK/vuln-bridge-lib.sh"
got_base=0
# Prefer the git base (origin/main or the merge-base) copy of bridge-lib.sh.
if git -C "$REPO_ROOT" show "origin/main:bridge-lib.sh" > "$VULN_LIB" 2>/dev/null && [[ -s "$VULN_LIB" ]]; then
  got_base=1
elif base_sha="$(git -C "$REPO_ROOT" merge-base HEAD origin/main 2>/dev/null)" && [[ -n "$base_sha" ]] \
     && git -C "$REPO_ROOT" show "$base_sha:bridge-lib.sh" > "$VULN_LIB" 2>/dev/null && [[ -s "$VULN_LIB" ]]; then
  got_base=1
fi
if (( got_base )); then
  # The vuln copy lives in $WORK, not the repo root, so its self-dir resolves to
  # $WORK and it won't find lib/bridge-secret-scrub.sh — which is correct: the
  # pre-fix version never had the primitive. But it needs the rest of the source
  # tree for startup validation, so point BRIDGE_SCRIPT_DIR resolution at the
  # real tree by copying the vuln file INTO the repo root under a temp name.
  VULN_IN_TREE="$REPO_ROOT/.agb-1454-vuln-$$-bridge-lib.sh"
  cp "$VULN_LIB" "$VULN_IN_TREE"
  # Strip the trap so a stray copy is cleaned even on early exit.
  trap 'rm -f "$VULN_IN_TREE" 2>/dev/null || true; cleanup' EXIT
  run_case "TEETH pre-fix (Bash4+ no-op)" "$BASH4" "$VULN_IN_TREE" "leak"
  if [[ -n "$BASH3" ]]; then
    run_case "TEETH pre-fix (Bash3.2 re-exec)" "$BASH3" "$VULN_IN_TREE" "leak"
  fi
  rm -f "$VULN_IN_TREE"
  trap cleanup EXIT
else
  echo "  SKIP  TEETH — could not obtain a pre-fix bridge-lib.sh (no origin/main); A/B/C still assert the fix"
fi

if (( failed )); then
  echo "[smoke:${SMOKE_NAME}] FAILED"
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] OK"
exit 0
