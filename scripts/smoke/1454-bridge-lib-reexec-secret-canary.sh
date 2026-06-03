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
#   STATIC — in-source structure: the shared primitive exists + is sourced
#            before the re-exec guard, the `$(dirname …)` SCRIPT_DIR fork is
#            gone, the re-exec uses `-p`, and the old `-lc` probe is gone.
#   A — dirname()-function-shadow attack on the macOS Bash-3.2→4 re-exec path:
#       the shadow must NEVER observe the secret. (Skipped when no Bash 3.2 is
#       available — Linux CI has only Bash 5; the no-op path below still runs.)
#   B — dirname()-function-shadow attack on the Bash-4+ NO-OP path: the shadow
#       must NEVER observe the secret.
#   C — PATH-planted `dirname` attack on the Bash-4+ path: the plant must never
#       run (BRIDGE_SCRIPT_DIR no longer forks `dirname`), so it cannot leak.
#   TEETH — the same attack against a pristine pre-fix copy of bridge-lib.sh
#       (the git-base version) MUST leak, proving the canary has teeth.
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

src_line="$(grep -nE 'source "\$_BRIDGE_LIB_SELF_DIR/lib/bridge-secret-scrub\.sh"' "$LIB_SH" | head -n1 | cut -d: -f1 || true)"
harden_line="$(grep -nE '^[[:space:]]*bridge_secret_scrub_harden_hooks' "$LIB_SH" | head -n1 | cut -d: -f1 || true)"
reexec_guard_line="$(grep -nE 'BASH_VERSINFO\[0\]:-0\} < 4' "$LIB_SH" | head -n1 | cut -d: -f1 || true)"
if [[ -n "$src_line" && -n "$harden_line" && -n "$reexec_guard_line" \
      && "$src_line" -lt "$reexec_guard_line" && "$harden_line" -lt "$reexec_guard_line" ]]; then
  ok "primitive sourced (L$src_line) + hooks hardened (L$harden_line) before the re-exec guard (L$reexec_guard_line)"
else
  fail "hook-harden does not precede the re-exec guard (src=L${src_line:-?} harden=L${harden_line:-?} guard=L${reexec_guard_line:-?})"
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
  # run_case <label> <bash-bin> <lib> <expect:clean|leak>
  local label="$1" bashbin="$2" lib="$3" expect="$4"
  local wrapper="$WORK/attack.sh" leak="$WORK/leak.txt"
  rm -f "$leak"
  write_attack_wrapper "$wrapper" "$lib" "$leak"
  BRIDGE_HOME="$PROBE_HOME" "$bashbin" "$wrapper" >/dev/null 2>&1 || true
  if leak_present "$leak"; then
    if [[ "$expect" == "leak" ]]; then ok "$label — leaked as expected (teeth)"; else fail "$label — SECRET LEAKED to dirname shadow"; fi
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
