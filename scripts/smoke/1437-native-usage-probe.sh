#!/usr/bin/env bash
# scripts/smoke/1437-native-usage-probe.sh — regression for issue #1437
# PRIMARY: native Anthropic OAuth usage probe for headless proactive rotation.
#
# On a headless cron host there is no claude-hud statusLine → no stdin tap →
# no controller .usage-cache.json, so the token-rotation monitor never sees a
# Claude `used_percent` and the OAT is never rotated proactively before the
# account hard-limits. This feature adds a NATIVE source: a direct GET to
# Anthropic's (undocumented) api/oauth/usage endpoint, mapped into the EXACT
# .usage-cache.json shape the existing monitor/rotation path already consumes.
#
# Coverage:
#   PY — scripts/smoke/1437-native-usage-probe-helper.py drives every
#        risk-mitigation + mapping scenario with an INJECTED mock HTTP seam
#        (NO live network call, MOCK tokens only): raw→cache mapping, the real
#        monitor flagging a rotation candidate at threshold, null-five_hour
#        degrade, 429 cooldown/stale, single capped Retry-After retry, cache
#        freshness, token-source priority, user:profile scope guard, and
#        credential safety (token never persisted/returned).
#   S1 — in-source wiring: bridge-usage.sh routes a `probe` command + an
#        embedded pre-monitor refresh through bridge_usage_native_probe.
#   S2 — in-source wiring: bridge-daemon.sh documents the native-probe refresh
#        ahead of the usage monitor read.
#   S3 — credential-safety static check: bridge-usage-probe.py never writes the
#        token into a file/env and only uses it in the Authorization header.
#   S4 — footgun #11: no heredoc-stdin / here-string into a python3 subprocess
#        in the probe helper or the new bridge-usage.sh probe path.

set -euo pipefail

SMOKE_NAME="1437-native-usage-probe"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

PROBE="$REPO_ROOT/bridge-usage-probe.py"
USAGE_SH="$REPO_ROOT/bridge-usage.sh"
DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
HELPER="$SCRIPT_DIR/1437-native-usage-probe-helper.py"

failed=0
fail() {
  echo "  FAIL  $1" >&2
  failed=1
}
ok() { echo "  PASS  $1"; }

# --- PY: the mock-only python harness (the bulk of behavioral coverage) ------
echo "[PY] mock-only probe scenarios (no live network)"
if python3 "$HELPER"; then
  ok "python harness: all probe scenarios pass"
else
  fail "python harness: one or more probe scenarios failed"
fi

# --- S1: bridge-usage.sh wiring ----------------------------------------------
echo "[S1] bridge-usage.sh wires the native probe"
if grep -q 'bridge_usage_native_probe' "$USAGE_SH"; then
  ok "bridge-usage.sh defines/calls bridge_usage_native_probe"
else
  fail "bridge-usage.sh missing bridge_usage_native_probe wiring"
fi
if grep -qE '^\s*probe\)' "$USAGE_SH"; then
  ok "bridge-usage.sh exposes a probe command"
else
  fail "bridge-usage.sh missing probe command arm"
fi
if grep -q 'BRIDGE_USAGE_PROBE_ENABLED' "$USAGE_SH"; then
  ok "bridge-usage.sh gates the probe behind BRIDGE_USAGE_PROBE_ENABLED"
else
  fail "bridge-usage.sh missing BRIDGE_USAGE_PROBE_ENABLED feature flag"
fi

# --- S2: bridge-daemon.sh documents the refresh ahead of the monitor read ----
echo "[S2] bridge-daemon.sh documents native-probe refresh before monitor"
if grep -q '#1437' "$DAEMON_SH" && grep -q 'BRIDGE_USAGE_PROBE_ENABLED' "$DAEMON_SH"; then
  ok "bridge-daemon.sh references #1437 + the probe feature flag"
else
  fail "bridge-daemon.sh missing #1437 native-probe documentation"
fi

# --- S3: credential safety static check --------------------------------------
echo "[S3] credential safety: token only in Authorization header"
# The token must be referenced in _build_headers' Authorization only; assert
# there is no json.dump/write of a structure that includes the raw token, and
# no env-export of the token into a subprocess.
if grep -qE 'f"Bearer \{token\}"' "$PROBE"; then
  ok "token used in the Authorization header"
else
  fail "token Authorization header construction not found"
fi
if grep -qE 'os\.environ\[[^]]*\]\s*=\s*token|env\[[^]]*\]\s*=\s*token' "$PROBE"; then  # noqa: iso-helper-boundary — grep pattern string, not a .env access
  fail "token appears to be exported into an environment variable"
else
  ok "token never assigned into an environment variable"
fi
# The probe module must not spawn a subprocess at all (no env-leak surface).
# Match only actual call/import sites — `import subprocess`, `subprocess.run(`,
# `os.system(`, `os.exec*(` — not the docstring prose that explains *why* there
# is no subprocess.
if grep -nE 'import[[:space:]]+subprocess|subprocess\.[A-Za-z]|os\.system\(|os\.exec[a-z]*\(' "$PROBE"; then
  fail "probe spawns a subprocess (env-leak surface for the OAT)"
else
  ok "probe makes no subprocess call (in-process urllib only)"
fi

# --- S4: footgun #11 — no heredoc-stdin into a python3 subprocess -------------
echo "[S4] footgun #11: probe path invokes python3 by file path (no heredoc-stdin)"
# The probe helper is pure python (no shell). Assert the new
# bridge_usage_native_probe function invokes python3 by FILE PATH and does not
# introduce a redirect-stdin / here-string into a python3 call. We build the
# redirect tokens at runtime (lt="<") so this scanner line itself does not
# contain the literal redirect operators the sister heredoc-ban lint matches on.
lt='<'
redir_pattern="python3[^|]*${lt}${lt}|python3.*${lt}${lt}${lt}"
probe_block="$(awk '/^bridge_usage_native_probe\(\)/{f=1} f{print} /^}/{if(f)exit}' "$USAGE_SH")"
if printf '%s\n' "$probe_block" | grep -qE "$redir_pattern"; then
  fail "bridge_usage_native_probe uses heredoc/here-string into python3"
else
  ok "bridge_usage_native_probe invokes python3 by file path (no heredoc-stdin)"
fi
if printf '%s\n' "$probe_block" | grep -qE 'python3[[:space:]].*bridge-usage-probe\.py'; then
  ok "bridge_usage_native_probe runs bridge-usage-probe.py by file path"
else
  fail "bridge_usage_native_probe does not invoke bridge-usage-probe.py by file path"
fi

# --- end-to-end CLI smoke (offline): probe with no token degrades gracefully --
echo "[E2E] bridge-usage-probe.py CLI degrades cleanly with no token (offline)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-1437.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
# Point at empty registry + credentials so no token resolves and no network is
# attempted. CLAUDE_CODE_OAUTH_TOKEN cleared so the env source is empty too.
out="$(CLAUDE_CODE_OAUTH_TOKEN="" python3 "$PROBE" probe \
  --cache-path "$TMP_DIR/.usage-cache.json" \
  --registry-path "$TMP_DIR/none.json" \
  --credentials-path "$TMP_DIR/none.json" \
  --max-age 0 --json 2>/dev/null)"
rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q '"status": "no-token"'; then
  ok "CLI exits 0 with status=no-token and writes no cache"
else
  fail "CLI did not degrade cleanly (rc=$rc out=$out)"
fi
if [[ ! -f "$TMP_DIR/.usage-cache.json" ]]; then
  ok "no cache fabricated when no token is available"
else
  fail "cache was written despite no token"
fi

# --- DAEMON-PATH E2E (#1437 r2 BLOCKER 1) ------------------------------------
# Drive the ACTUAL `bridge-usage.sh monitor --agents static` daemon path (the
# default the daemon uses at bridge-daemon.sh process_usage_monitor) end-to-end
# with a real roster + a 92% native cache, and assert a rotation candidate
# appears at a 90% threshold. This is the headline #1437 acceptance: the native
# signal must reach rotation in the real wrapper flow, not just the in-process
# helper. We use a HERMETIC HOME + BRIDGE_HOME (delivered per-invocation via
# `env`, so no env leaks into later cases — and no SC2030/SC2031 noise).
#
# Helper: run `bridge-usage.sh monitor --agents static` in a hermetic home and
# return the count of 92% rotation candidates. $1=home; $2=native cache path
# (the file BRIDGE_CLAUDE_USAGE_CACHE points at); $3=agent's own cache path
# (where bridge_usage_resolve_claude_cache_path reads = $HOME/.claude/...). When
# $2 != $3 and $3 is absent we reproduce codex's isolated-agent-absent repro.
run_daemon_monitor_92_count() {
  local home="$1" native_cache="$2" agent_cache="$3"
  local roster="$home/roster.sh"
  mkdir -p "$home/.agent-bridge/state/usage" "$(dirname "$native_cache")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'declare -ag BRIDGE_AGENT_IDS=("probeacc")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_ENGINE=(["probeacc"]="claude")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_SOURCE=(["probeacc"]="static")'
  } >"$roster"
  # Seed the native cache with a 92% five_hour (what the probe would write).
  printf '%s' '{"data":{"planName":"subscription","fiveHour":92.0,"sevenDay":47.5,"fiveHourResetAt":"2026-06-01T18:00:00+00:00","sevenDayResetAt":"2026-06-07T00:00:00+00:00"},"_source":"native-oauth-probe"}' >"$native_cache"
  # Note: $agent_cache (the agent's resolved $HOME/.claude/... cache) is left
  # ABSENT by the caller when reproducing the isolated-agent-absent case.
  local out
  # env-deliver every path so nothing leaks into later cases; probe ENABLED with
  # a huge max-age so it serves the seeded cache and never hits the network.
  #
  # BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT satisfy the v0.8.0 isolation-v2 layout
  # resolver's env-override branch so a hermetic (markerless) test home does not
  # hard-die on Linux ("requires isolation-v2"). macOS short-circuits that check
  # (Linux-only), which is why it is needed here for Linux-CI parity — the
  # classic macOS-pass != Linux-CI footgun. The agent stays NON-isolated
  # (no os_user / isolation request), so its resolved cache path is the
  # controller $HOME/.claude/... cache regardless of layout.
  out="$(env \
    HOME="$home" \
    BRIDGE_HOME="$home/.agent-bridge" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_DATA_ROOT="$home/.agent-bridge" \
    BRIDGE_STATE_DIR="$home/.agent-bridge/state" \
    BRIDGE_USAGE_MONITOR_STATE_FILE="$home/.agent-bridge/state/usage/monitor-state.json" \
    BRIDGE_CLAUDE_TOKEN_REGISTRY="$home/no-registry.json" \
    BRIDGE_ROSTER_FILE="$roster" \
    BRIDGE_ROSTER_LOCAL_FILE="$home/none-local.sh" \
    BRIDGE_CLAUDE_USAGE_CACHE="$native_cache" \
    BRIDGE_USAGE_PROBE_ENABLED=1 \
    BRIDGE_USAGE_PROBE_MAX_AGE=999999 \
    BRIDGE_CLAUDE_TOKEN_ROTATION_PERCENT=90 \
    bash "$USAGE_SH" monitor --agents static --json 2>/dev/null || true)"
  printf '%s' "$out" | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read() or "{}")
except Exception:
    d={}
rc=d.get("rotation_candidates") or []
print(sum(1 for c in rc if c.get("used_percent")==92.0))' 2>/dev/null || printf 0
}

# Case 1: non-isolated agent — its resolved cache IS the native cache (present).
echo "[DAEMON-E2E] bridge-usage.sh monitor --agents static surfaces native 92% rotation candidate"
DAEMON_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agb-1437-daemon.XXXXXX")"
agent_cache1="$DAEMON_HOME/.claude/plugins/claude-hud/.usage-cache.json"
rot_count="$(run_daemon_monitor_92_count "$DAEMON_HOME" "$agent_cache1" "$agent_cache1")"
if [[ "${rot_count:-0}" -ge 1 ]]; then
  ok "real daemon path (bridge-usage.sh monitor --agents static) emits the native 92% rotation candidate at a 90% threshold"
else
  fail "daemon path did NOT surface the native rotation candidate (count=$rot_count)"
fi
rm -rf "$DAEMON_HOME"

# Case 2: the EXACT codex repro — the agent's own cache is ABSENT (present=false),
# the native cache lives at a DISTINCT path. The additive native source must
# STILL surface the 92% rotation candidate (previously returned snapshots:[]).
echo "[DAEMON-E2E-2] per-agent cache ABSENT + native 92% (the codex repro) still rotates"
DAEMON_HOME2="$(mktemp -d "${TMPDIR:-/tmp}/agb-1437-daemon2.XXXXXX")"
native_cache2="$DAEMON_HOME2/native/.usage-cache.json"
# $agent_cache for case 2 is $HOME/.claude/... which we never create → absent.
rot_count2="$(run_daemon_monitor_92_count "$DAEMON_HOME2" "$native_cache2" "$DAEMON_HOME2/.claude/plugins/claude-hud/.usage-cache.json")"
if [[ "${rot_count2:-0}" -ge 1 ]]; then
  ok "per-agent-absent + native 92% (codex repro) DOES surface the rotation candidate via the additive native source"
else
  fail "per-agent-absent + native path did NOT surface the rotation candidate (count=$rot_count2)"
fi
rm -rf "$DAEMON_HOME2"

# --- INHERITED-ENV LEAK (#1437 r2+r3 BLOCKING) -------------------------------
# Assert the wrapper does NOT leak CLAUDE_CODE_OAUTH_TOKEN into ANY subprocess it
# spawns — EARLY (the roster/session Python helpers run when bridge-lib.sh is
# sourced: sha1-batch.py for cache hashing, resolve-claude-resume-session-id.py)
# OR LATE (the version-sniff `claude` + its `head` child, mktemp/chmod, the
# probe). The r3 fix moves the capture+unset to the TOP of bridge-usage.sh,
# BEFORE `source bridge-lib.sh` — an in-function unset (r2) was too late and
# leaked into those early children. We assert (a) the unset precedes the source
# line, and behavioral canaries for BOTH (b) an EARLY python3 child and (c) the
# LATE version-sniff child.
echo "[ENV-LEAK] DEFINITIVE design (r12): re-exec to Bash 4+ FIRST (builtins only) → token never crosses a re-exec → no forgeable transit; probe gets the token via an inherited fd"
source_line="$(grep -nE '^[[:space:]]*source[[:space:]].*bridge-lib\.sh' "$USAGE_SH" | head -n1 | cut -d: -f1)"
probe_fn="$(awk '/^bridge_usage_native_probe\(\)/{f=1} f{print} /^}/{if(f)exit}' "$USAGE_SH")"
# (a1) The well-known token scrub (unset) must precede `source bridge-lib.sh` so
# bridge-lib's command-sub children (e.g. its dirname) never inherit the token.
unset_line="$(grep -nE '^[[:space:]]*unset CLAUDE_CODE_OAUTH_TOKEN' "$USAGE_SH" | head -n1 | cut -d: -f1)"
if [[ -n "$unset_line" && -n "$source_line" && "$unset_line" -lt "$source_line" ]]; then
  ok "well-known OAT scrub (L$unset_line) precedes 'source bridge-lib.sh' (L$source_line)"
else
  fail "OAT unset (L${unset_line:-?}) does not precede source bridge-lib.sh (L${source_line:-?})"
fi
# (a2) The ambient OAT must be UNSET from the env BEFORE any external command in
# the self-re-exec block — so the candidate-version probe (`"$_bu_cand" -p -c …`)
# and any rm/mktemp/chmod run TOKEN-FREE (no `env -u`, no PATH-planted `env`
# seeing the OAT). Assert the `unset CLAUDE_CODE_OAUTH_TOKEN` precedes the
# self-re-exec candidate-probe line. (`|| true` keeps a no-match grep from
# aborting under set -e -o pipefail.)
unset_tok_line="$(grep -nE '^[[:space:]]*unset CLAUDE_CODE_OAUTH_TOKEN' "$USAGE_SH" | head -n1 | cut -d: -f1 || true)"
candprobe_line="$(grep -nE '"\$_bu_cand" -p? ?-c' "$USAGE_SH" | head -n1 | cut -d: -f1 || true)"
if [[ -n "$unset_tok_line" && -n "$candprobe_line" && "$unset_tok_line" -lt "$candprobe_line" ]]; then
  ok "ambient OAT is unset (L$unset_tok_line) BEFORE the candidate-version probe (L$candprobe_line) — version check runs token-free (no env -u / planted env)"
else
  fail "ambient OAT unset does not precede the candidate-version probe (unset=L${unset_tok_line:-?} probe=L${candprobe_line:-?})"
fi
# (a3) The token DOES ride fd 9 across OUR self-re-exec (Bash 3.2 → 4+), but fd 9
# MUST be CLOSED (`exec 9<&-`) BEFORE `source bridge-lib.sh` so bridge-lib's
# dirname / helper children never inherit a readable token fd. Assert an
# `exec 9<&-` appears AFTER the fd-9 read and BEFORE the source line.
fd9_close_line="$(grep -nE '^[[:space:]]*exec 9<&-' "$USAGE_SH" | head -n1 | cut -d: -f1)"
if [[ -n "$fd9_close_line" && -n "$source_line" && "$fd9_close_line" -lt "$source_line" ]]; then
  ok "fd 9 (self-re-exec token transit) is CLOSED (L$fd9_close_line) before 'source bridge-lib.sh' (L$source_line) — dirname cannot inherit it"
else
  fail "fd 9 is not closed before source bridge-lib.sh (close=L${fd9_close_line:-?} source=L${source_line:-?}) — bridge-lib's dirname could read it"
fi
# The fd-9 transit file must be magic-prefixed (so a caller-preopened fd 9 is
# rejected) and unlinked (no path on disk).
if grep -qE '_BU_FD_MAGIC=' "$USAGE_SH" && grep -qE '== "\$_BU_FD_MAGIC"\*' "$USAGE_SH"; then
  ok "fd-9 transit is magic-prefixed + verified (a caller-preopened fd 9 without the magic is rejected)"
else
  fail "fd-9 transit is not magic-verified — a caller-preopened fd 9 could be read as the token"
fi
if grep -qE '^[[:space:]]*export _BRIDGE_USAGE_OAT_(FILE|TRANSIT|OWNED)=' "$USAGE_SH"; then
  fail "wrapper still EXPORTS a token-or-path transit env var (caller-forgeable)"
else
  ok "wrapper exports NO token-or-path transit env var (no forgeable env transit)"
fi
# (a4) The bridge-private names are unset unconditionally before the source, so a
# caller-injected value of any of them cannot reach bridge-lib.sh's children.
privunset_line="$(grep -nE '^unset _bu_tok _bu_file BRIDGE_USAGE_CAPTURED_OAT env_oat' "$USAGE_SH" | head -n1 | cut -d: -f1)"
if [[ -n "$privunset_line" && -n "$source_line" && "$privunset_line" -lt "$source_line" ]] \
   && grep -qE '_BRIDGE_USAGE_OAT_FILE _BRIDGE_USAGE_OAT_OWNED' "$USAGE_SH"; then
  ok "all bridge-private transit names are unset unconditionally (incl. legacy _BRIDGE_USAGE_OAT_*) before source bridge-lib.sh"
else
  fail "bridge-private transit names are not all unset unconditionally before source bridge-lib.sh"
fi
# (a5) The probe receives the captured token via an INHERITED fd (--token-fd),
# NOT a --token-file <path> (no argv-visible path), on an UNLINKED file. Assert
# the probe fn opens an fd on the token file, unlinks it, and passes --token-fd
# + --no-env-token (and does NOT pass --token-file as the daemon-path delivery).
if printf '%s\n' "$probe_fn" | grep -qE 'exec 8<' \
   && printf '%s\n' "$probe_fn" | grep -q -- '--token-fd' \
   && printf '%s\n' "$probe_fn" | grep -q -- '--no-env-token'; then
  ok "probe receives the OAT via an inherited fd (--token-fd on an unlinked 0600 file) + --no-env-token"
else
  fail "probe does not deliver the token via an inherited fd (--token-fd / exec 8< / --no-env-token missing)"
fi
# The token file backing the probe's fd 8 must be UNLINKED so its path is never
# on disk to find (and is never passed in argv).
if printf '%s\n' "$probe_fn" | awk '/exec 8</{seen=1} seen && /-f -- "\$token_file"/{print "OK"; exit}' | grep -q OK; then
  ok "the probe's fd-8 token file is unlinked (rm) immediately — no path on disk, none in argv"
else
  fail "the probe's fd-8 token file is not unlinked — a findable path remains on disk"
fi
# r12 BLOCKING: rm/mktemp/chmod that run near the live token use HARDCODED
# ABSOLUTE binaries (bound at script top), not PATH resolution, so a planted
# helper on PATH cannot be the one that runs while fd 8 / the 0600 file is live.
if grep -qE '_BU_RM="\$\(_bu_pick /bin/rm' "$USAGE_SH" \
   && printf '%s\n' "$probe_fn" | grep -qE '\$\{_BU_RM:-rm\}'; then
  ok "rm near the live token is bound to a hardcoded-absolute binary (no PATH-planted rm)"
else
  fail "rm near the live token still resolves via PATH (a planted rm could read /dev/fd/8 or the file)"
fi
# (a6) r13 BLOCKING: a caller can export Bash FUNCTIONS named after commands we
# invoke (they run in OUR shell and read non-exported token vars). Assert (i) the
# script `unset -f`s those names at the top (via the special builtin `builtin
# unset -f`, which a function cannot override), and (ii) the version sniff + the
# probe invoke `command claude/head/python3` (function-bypass), not unqualified.
unsetf_line="$(grep -nE '^builtin unset -f ' "$USAGE_SH" | head -n1 | cut -d: -f1)"
# The `builtin unset -f` statement is line-continued across ~3 lines; check the
# command names appear anywhere in that statement (claude/head/python3 are the
# external commands run near the token).
unsetf_names_ok=0
if [[ -n "$unsetf_line" ]]; then
  awk -v start="$unsetf_line" 'NR>=start{buf=buf" "$0} /[^\\]$/ && NR>=start{exit} END{if (buf ~ /claude/ && buf ~ /head/ && buf ~ /python3/ && buf ~ /printf/) print "OK"}' "$USAGE_SH" | grep -q OK && unsetf_names_ok=1
fi
if [[ -n "$unsetf_line" && -n "$source_line" && "$unsetf_line" -lt "$source_line" && "$unsetf_names_ok" -eq 1 ]]; then
  ok "caller-exported functions (claude/head/python3/printf/…) are 'builtin unset -f'd at the top, before source bridge-lib.sh"
else
  fail "the script does not unset -f the right caller-exported command functions at the top (line=${unsetf_line:-?} names_ok=$unsetf_names_ok)"
fi
if printf '%s\n' "$probe_fn" | grep -qE 'command "\$claude_bin" --version' \
   && printf '%s\n' "$probe_fn" | grep -qE 'command head' \
   && printf '%s\n' "$probe_fn" | grep -qE 'command python3'; then
  ok "the version sniff + probe invoke commands FUNCTION-bypassed (command claude/head/python3) near the token"
else
  fail "the version sniff / probe invoke an unqualified command near the token — a caller-exported function could intercept it"
fi
# (a7) r13 PRIMARY defense: `bash -p` (privileged) does NOT import functions from
# the environment, stripping the WHOLE exported-function class in one shot (more
# robust than per-name unset -f, whose unset/builtin could themselves be shadowed).
# Assert the script re-execs under `bash -p` guarded by `$-` (so it runs once),
# BEFORE source bridge-lib.sh.
preexec_line="$(grep -nE 'exec "\$_bu_cand0" -p ' "$USAGE_SH" | head -n1 | cut -d: -f1)"
if [[ -n "$preexec_line" && -n "$source_line" && "$preexec_line" -lt "$source_line" ]] \
   && grep -qE 'case "\$-" in' "$USAGE_SH"; then
  ok "the script re-execs under 'bash -p' (privileged, no env-function import) guarded by \$-, before source bridge-lib.sh"
else
  fail "the script does not re-exec under 'bash -p' — exported functions are not stripped at the root"
fi
# (a8) r14 BLOCKING: BASH_ENV / ENV startup-file hooks. (i) The script unsets
# BASH_ENV/ENV/BASH_XTRACEFD at the top, AND (ii) every pre-scrub candidate-
# version probe is privileged (`-p`), so a non-interactive child Bash sources no
# caller startup file even before the credential scrub.
if grep -qE '^builtin unset BASH_ENV ENV BASH_XTRACEFD' "$USAGE_SH"; then
  ok "BASH_ENV / ENV / BASH_XTRACEFD are unset at the very top (no caller startup-file hook for child Bash)"
else
  fail "BASH_ENV / ENV are not unset at the top — a caller startup file could run in a child Bash with the credential live"
fi
if grep -qE '"\$_bu_cand0?" -p -c ' "$USAGE_SH" && ! grep -qE '"\$_bu_cand0?" -c ' "$USAGE_SH"; then
  ok "every candidate-version probe is privileged (-p) — sources no BASH_ENV/ENV even pre-scrub"
else
  fail "a candidate-version probe is non-privileged ('bash -c' without -p) — it could source a caller's BASH_ENV with the credential live"
fi

# BEHAVIORAL canary (codex r3 repro): drive the REAL `bash bridge-usage.sh probe`
# with the OAT env var set and BOTH a fake `python3` AND a fake `claude` on PATH
# that each record their inherited environment. Assert the canary appears in
# NEITHER — proving no EARLY roster/session python helper child NOR the LATE
# version-sniff child inherits the token. A non-empty roster (+ session) ensures
# the early sha1-batch/session-resolution helpers actually fire. The fake python3
# also records the probe's argv so we can assert the captured token STILL reaches
# the probe via --token-file (r4: it must survive the Bash-3.2 re-exec).
#
# run_env_leak_canary <driver-bash> <label-suffix>: drives `<driver-bash>
# bridge-usage.sh probe` with the OAT env var set + fake python3/claude, then
# asserts (a) no canary in any python3 child env, (b) no canary in the claude
# child env, (c) the probe received --token-file (delivery survived).
run_env_leak_canary() {
  local driver_bash="$1" label="$2" extra_env="${3:-}"
  local home fakebin dump probe_argv leak_roster canary oat_var cmd real
  local -a inject=()
  # r7: optional adversarial caller-injected env (space-separated VAR=val). Used
  # to assert the well-known OAT is scrubbed even when _BRIDGE_USAGE_OAT_FILE is
  # pre-set, and that a pre-exported _bu_tok is not inherited by any child.
  if [[ -n "$extra_env" ]]; then
    # shellcheck disable=SC2206
    inject=($extra_env)
  fi
  home="$(mktemp -d "${TMPDIR:-/tmp}/agb-1437-env.XXXXXX")"
  fakebin="$home/bin"; mkdir -p "$fakebin"
  dump="$home/all-child-env.dump"
  probe_argv="$home/probe-argv.txt"
  # r5: instrument EVERY external command the startup path may call via command
  # substitution — dirname/readlink (path derivation in bridge-usage.sh +
  # bridge-lib.sh), mktemp/chmod (token-file + temp dirs), head (version-sniff
  # pipeline), python3 (roster/session helpers + the probe), claude (version
  # sniff). Each fake appends its FULL inherited env to a single shared dump,
  # then execs the real binary (or, for claude, emits a version string). The
  # canary token must be ABSENT from the ENTIRE dump — this catches the
  # command-substitution leak class (the transit-env var leaked into `dirname`).
  for cmd in dirname readlink mktemp chmod head python3 claude; do
    real="$(command -v "$cmd" 2>/dev/null || true)"
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf 'printf "===child:%s===\\n" >> %q\n' "$cmd" "$dump"
      printf 'env >> %q\n' "$dump"
      if [[ "$cmd" == "python3" ]]; then
        # Record the probe argv so we can assert --token-file delivery.
        printf '%s %q\n' 'for a in "$@"; do case "$a" in *bridge-usage-probe.py) printf "%s\\n" "$*" >>' "$probe_argv"
        printf '%s\n' ' ;; esac; done'
      fi
      if [[ -n "$real" ]]; then
        printf 'exec %q "$@"\n' "$real"
      else
        printf '%s\n' 'echo "2.1.0 (Claude Code)"'
      fi
    } >"$fakebin/$cmd"
    chmod +x "$fakebin/$cmd"
  done
  # Non-empty roster so bridge_load_roster exercises the early python helpers.
  leak_roster="$home/roster.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'declare -ag BRIDGE_AGENT_IDS=("probeacc")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_ENGINE=(["probeacc"]="claude")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_SOURCE=(["probeacc"]="static")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_SESSION=(["probeacc"]="probeacc-session")'
  } >"$leak_roster"
  canary="LEAK-CANARY-must-not-appear-$$-$RANDOM"
  # Build the OAT env-var NAME indirectly so the tracked source text never
  # contains the literal (clean source + avoids the credential-redaction hook).
  oat_var="CLAUDE_CODE""_OAUTH_TOKEN"
  env "$oat_var=$canary" \
    "${inject[@]+"${inject[@]}"}" \
    HOME="$home" \
    PATH="$fakebin:$PATH" \
    BRIDGE_HOME="$home/.agent-bridge" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_DATA_ROOT="$home/.agent-bridge" \
    BRIDGE_ROSTER_FILE="$leak_roster" \
    BRIDGE_ROSTER_LOCAL_FILE="$home/none-local.sh" \
    BRIDGE_CLAUDE_TOKEN_CHECK_BIN="$fakebin/claude" \
    BRIDGE_CLAUDE_USAGE_CACHE="$home/.usage-cache.json" \
    BRIDGE_CLAUDE_TOKEN_REGISTRY="$home/no-registry.json" \
    BRIDGE_USAGE_PROBE_ENABLED=1 \
    BRIDGE_USAGE_PROBE_MAX_AGE=0 \
    "$driver_bash" "$USAGE_SH" probe --credentials-path "$home/no-cred.json" >/dev/null 2>&1 || true
  # (a) NO instrumented child (dirname/readlink/mktemp/chmod/head/python3/claude)
  # may have the canary token anywhere in its inherited environment.
  if [[ ! -f "$dump" ]]; then
    fail "[$label] no instrumented child recorded — canary did not exercise the startup path"
  elif grep -q "$canary" "$dump"; then
    local leaked
    leaked="$(awk '/^===child:/{n=$0} index($0,"'"$canary"'"){print n}' "$dump" | sort -u | tr '\n' ' ')"
    fail "[$label] OAT leaked into a command-substitution child env: ${leaked:-unknown}"
  else
    local seen
    seen="$(grep -c '^===child:' "$dump")"
    ok "[$label] OAT absent from ALL $seen instrumented child env(s) (incl. dirname/mktemp/python3)"
  fi
  # (a-inject) r9/r11: when the caller pre-EXPORTS a bridge-private var carrying a
  # token-like value (a `*TOKENCANARY*` value via extra_env — possibly combined
  # with a sentinel like _BRIDGE_USAGE_OAT_OWNED=1), that VALUE must be ABSENT
  # from every child env: the bridge-private names are unset unconditionally at
  # the top and are no longer the transit (the token crosses on fd 9). Extract
  # the TOKENCANARY-bearing word from extra_env and scan for its value.
  if [[ -n "$extra_env" && "$extra_env" == *TOKENCANARY* ]]; then
    local inj_word inj_val
    # The TOKENCANARY value may be on any of the (space-separated) injected
    # assignments; pick the word containing TOKENCANARY and take its =value.
    # shellcheck disable=SC2086  # intentional word-split of the space-separated injections
    inj_word="$(printf '%s\n' $extra_env | grep TOKENCANARY | head -n1)"
    inj_val="${inj_word#*=}"
    if [[ -n "$inj_val" ]] && grep -q "$inj_val" "$dump" 2>/dev/null; then
      local w
      w="$(awk '/^===child:/{n=$0} index($0,"'"$inj_val"'"){print n}' "$dump" | sort -u | tr '\n' ' ')"
      fail "[$label] caller-pre-exported bridge-private var leaked its token-value into a child: ${w:-?}"
    else
      ok "[$label] caller-pre-exported bridge-private var's token-value absent from all children (no forgeable transit)"
    fi
  fi
  # (b) The probe must have received --token-fd (r12: inherited fd on an unlinked
  # file; the captured token reached it). This holds even under adversarial
  # bridge-private injections (they are unset at the top + unused).
  if [[ -f "$probe_argv" ]] && grep -q -- '--token-fd' "$probe_argv"; then
    ok "[$label] probe received --token-fd (captured OAT reached the probe via an inherited fd)"
  else
    fail "[$label] probe did NOT receive --token-fd (token delivery lost)"
  fi
  rm -rf "$home"
}

# run_env_leak_canary_butok <driver> <label>: a focused adversarial check that the
# caller pre-EXPORTS _bu_tok=<canary>; the script must strip the export attribute
# so NO child (mktemp/chmod/dirname/…) inherits _bu_tok. Distinct from the main
# canary (which scans for the OAT-env canary) because _bu_tok carries its own.
run_env_leak_canary_butok() {
  local driver_bash="$1" label="$2"
  local home fakebin dump leak_roster canary cmd real
  home="$(mktemp -d "${TMPDIR:-/tmp}/agb-1437-butok.XXXXXX")"
  fakebin="$home/bin"; mkdir -p "$fakebin"
  dump="$home/all-child-env.dump"
  for cmd in dirname readlink mktemp chmod head python3 claude; do
    real="$(command -v "$cmd" 2>/dev/null || true)"
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf 'printf "===child:%s===\\n" >> %q\n' "$cmd" "$dump"
      printf 'env >> %q\n' "$dump"
      if [[ -n "$real" ]]; then printf 'exec %q "$@"\n' "$real"; else printf '%s\n' 'echo "2.1.0 (Claude Code)"'; fi
    } >"$fakebin/$cmd"
    chmod +x "$fakebin/$cmd"
  done
  leak_roster="$home/roster.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'declare -ag BRIDGE_AGENT_IDS=("probeacc")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_ENGINE=(["probeacc"]="claude")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_SOURCE=(["probeacc"]="static")'
  } >"$leak_roster"
  canary="BUTOK-CANARY-must-not-appear-$$-$RANDOM"
  env "_bu_tok=$canary" \
    HOME="$home" \
    PATH="$fakebin:$PATH" \
    BRIDGE_HOME="$home/.agent-bridge" \
    BRIDGE_LAYOUT="v2" \
    BRIDGE_DATA_ROOT="$home/.agent-bridge" \
    BRIDGE_ROSTER_FILE="$leak_roster" \
    BRIDGE_ROSTER_LOCAL_FILE="$home/none-local.sh" \
    BRIDGE_CLAUDE_TOKEN_CHECK_BIN="$fakebin/claude" \
    BRIDGE_CLAUDE_USAGE_CACHE="$home/.usage-cache.json" \
    BRIDGE_CLAUDE_TOKEN_REGISTRY="$home/no-registry.json" \
    BRIDGE_USAGE_PROBE_ENABLED=1 \
    BRIDGE_USAGE_PROBE_MAX_AGE=0 \
    "$driver_bash" "$USAGE_SH" probe --credentials-path "$home/no-cred.json" >/dev/null 2>&1 || true
  if [[ -f "$dump" ]] && grep -q "$canary" "$dump"; then
    local leaked
    leaked="$(awk '/^===child:/{n=$0} index($0,"'"$canary"'"){print n}' "$dump" | sort -u | tr '\n' ' ')"
    fail "[$label] pre-exported _bu_tok inherited by a child env: ${leaked:-unknown}"
  elif [[ -f "$dump" ]]; then
    ok "[$label] pre-exported _bu_tok NOT inherited by any child (export attribute stripped)"
  else
    fail "[$label] no child recorded — adversarial _bu_tok case did not exercise the path"
  fi
  rm -rf "$home"
}

# run_func_attack_canary <driver> <label>: the r13 class. A same-UID caller
# EXPORTS Bash FUNCTIONS named after commands the script invokes (claude / head /
# python3 / printf / env / mktemp / chmod / rm / dirname / readlink / cat). Bash
# resolves an exported function BEFORE an external command and runs it IN OUR
# shell context, so it could read the non-exported token shell vars. Each fn
# dumps the token vars + env + any readable fd 8/9, then delegates to the real
# command. Drive the REAL `<driver> bridge-usage.sh probe` with the OAT canary and
# assert the canary is ABSENT from the dump (the fns are `unset -f`'d at the top
# and every command near the token is `command`/`builtin`/absolute-qualified).
run_func_attack_canary() {
  local driver_bash="$1" label="$2"
  local home dump roster atk canary oat_var fn
  home="$(mktemp -d "${TMPDIR:-/tmp}/agb-1437-fnatk.XXXXXX")"
  dump="$home/dump"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'declare -ag BRIDGE_AGENT_IDS=("a")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_ENGINE=(["a"]="claude")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_SOURCE=(["a"]="static")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_SESSION=(["a"]="s")'
  } >"$home/roster.sh"
  canary="FNATK-CANARY-must-not-appear-$$-$RANDOM"
  oat_var="CLAUDE_CODE""_OAUTH_TOKEN"
  atk="$home/attacker.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    for fn in claude head python3 printf env mktemp chmod rm dirname readlink cat; do
      printf '%s() {\n' "$fn"
      printf '  { builtin printf "FN:%s OAT=[%%s] EO=[%%s] CAP=[%%s]\\n" "${%s:-}" "${env_oat:-}" "${BRIDGE_USAGE_CAPTURED_OAT:-}"; } >> %q 2>/dev/null || true\n' "$fn" "$oat_var" "$dump"
      printf '  { command env; } >> %q 2>/dev/null || true\n' "$dump"
      printf '  { for fd in 8 9; do [ -r /dev/fd/$fd ] && command cat /dev/fd/$fd 2>/dev/null; done; } >> %q 2>/dev/null || true\n' "$dump"
      if [[ "$fn" == claude ]]; then printf '  command echo "2.1.0 (Claude Code)"\n'; else printf '  command %s "$@"\n' "$fn"; fi
      printf '}\n'
      printf 'export -f %s\n' "$fn"
    done
    printf 'exec %q "$USAGE_SH" probe --credentials-path %q\n' "$driver_bash" "$home/nc.json"
  } >"$atk"
  chmod +x "$atk"
  env "$oat_var=$canary" \
    HOME="$home" BRIDGE_HOME="$home/.agent-bridge" BRIDGE_LAYOUT="v2" BRIDGE_DATA_ROOT="$home/.agent-bridge" \
    BRIDGE_ROSTER_FILE="$home/roster.sh" BRIDGE_ROSTER_LOCAL_FILE="$home/none-local.sh" \
    BRIDGE_CLAUDE_USAGE_CACHE="$home/.usage-cache.json" BRIDGE_CLAUDE_TOKEN_REGISTRY="$home/no-registry.json" \
    BRIDGE_USAGE_PROBE_ENABLED=1 BRIDGE_USAGE_PROBE_MAX_AGE=0 \
    USAGE_SH="$USAGE_SH" \
    bash "$atk" >/dev/null 2>&1 || true
  if [[ -f "$dump" ]] && grep -q "$canary" "$dump"; then
    fail "[$label] a caller-exported function SAW the token (env/shell-var/fd leak)"
  else
    ok "[$label] caller-exported functions did NOT see the token ($(grep -c '^FN:' "$dump" 2>/dev/null || echo 0) fn-invocations; unset -f + command/builtin qualified)"
  fi
  rm -rf "$home"
}

# run_bashenv_attack_canary <driver> <label>: the r14 class. A same-UID caller
# sets BASH_ENV / ENV to a startup file. Our EARLY candidate-version probe
# (`"$cand" -c …`) is a non-interactive child Bash that would source BASH_ENV
# BEFORE the credential is scrubbed — so the hook runs inside the probe child
# with the credential in env. The hook here fires ONLY on the version-probe child
# (BASH_EXECUTION_STRING contains BASH_VERSINFO), matching codex's repro, and
# records the OAT. The fix (`unset BASH_ENV ENV` at the top + `-p` on every probe,
# privileged Bash sources no startup file) must keep the canary ABSENT.
run_bashenv_attack_canary() {
  local driver_bash="$1" label="$2"
  local home dump hook canary oat_var
  home="$(mktemp -d "${TMPDIR:-/tmp}/agb-1437-bashenv.XXXXXX")"
  dump="$home/bashenv.dump"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'declare -ag BRIDGE_AGENT_IDS=("a")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_ENGINE=(["a"]="claude")'
    printf '%s\n' 'declare -Ag BRIDGE_AGENT_SOURCE=(["a"]="static")'
  } >"$home/roster.sh"
  canary="BASHENV-CANARY-must-not-appear-$$-$RANDOM"
  oat_var="CLAUDE_CODE""_OAUTH_TOKEN"
  hook="$home/hook.sh"
  {
    printf '%s\n' 'case "${BASH_EXECUTION_STRING:-}" in'
    printf '%s\n' '  *BASH_VERSINFO*)'
    printf '    { command printf "BASHENV-HOOK-RAN OAT=[%%s]\\n" "${%s:-}"; } >> %q 2>/dev/null || true\n' "$oat_var" "$dump"
    printf '%s\n' '    ;;'
    printf '%s\n' 'esac'
  } >"$hook"
  env "$oat_var=$canary" BASH_ENV="$hook" ENV="$hook" \
    HOME="$home" BRIDGE_HOME="$home/.agent-bridge" BRIDGE_LAYOUT="v2" BRIDGE_DATA_ROOT="$home/.agent-bridge" \
    BRIDGE_ROSTER_FILE="$home/roster.sh" BRIDGE_ROSTER_LOCAL_FILE="$home/none-local.sh" \
    BRIDGE_CLAUDE_USAGE_CACHE="$home/.usage-cache.json" BRIDGE_CLAUDE_TOKEN_REGISTRY="$home/no-registry.json" \
    BRIDGE_USAGE_PROBE_ENABLED=1 BRIDGE_USAGE_PROBE_MAX_AGE=0 \
    "$driver_bash" "$USAGE_SH" probe --credentials-path "$home/no-cred.json" >/dev/null 2>&1 || true
  if [[ -f "$dump" ]] && grep -q "$canary" "$dump"; then
    fail "[$label] a BASH_ENV/ENV startup hook captured the token on the version probe"
  else
    ok "[$label] BASH_ENV/ENV startup hook did NOT capture the token ($(grep -c 'BASHENV-HOOK-RAN' "$dump" 2>/dev/null || echo 0) hook-runs; unset + -p on probes)"
  fi
  rm -rf "$home"
}

echo "[ENV-LEAK-RUN] default-bash driver (Bash 4+ path)"
run_env_leak_canary "bash" "bash4"
echo "[ENV-LEAK-RUN] r13 exported-function attack (Bash 4+)"
run_func_attack_canary "bash" "bash4-fnatk"
echo "[ENV-LEAK-RUN] r14 BASH_ENV/ENV startup-hook attack (Bash 4+)"
run_bashenv_attack_canary "bash" "bash4-bashenv"
# r7+r10 adversarial-caller hardening: (1) a caller pre-exporting
# _BRIDGE_USAGE_OAT_FILE=<token> must have that INBOUND token-value scrubbed at
# the top so it cannot leak into bridge-lib.sh's dirname command-sub child (and
# the script still creates its OWN file from the real OAT and delivers it);
# (2) a pre-EXPORTED _bu_tok must not be inherited by the mktemp/chmod children.
echo "[ENV-LEAK-RUN] adversarial: caller pre-exports _BRIDGE_USAGE_OAT_FILE=<token>"
run_env_leak_canary "bash" "bash4-adv-oatfile" "_BRIDGE_USAGE_OAT_FILE=OATFILE-TOKENCANARY-$$-$RANDOM"
echo "[ENV-LEAK-RUN] adversarial: caller pre-exports _bu_tok=<canary>"
run_env_leak_canary_butok "bash" "bash4-adv-butok"
# r8: a caller who pre-EXPORTS the capture vars (BRIDGE_USAGE_CAPTURED_OAT /
# env_oat) must not cause the REAL token to leak — the script must strip those
# export attributes (unset / export -n) before writing the captured token. The
# main canary's own OAT canary IS the real token; assert it stays absent even
# with these vars pre-exported (as a harmless marker).
echo "[ENV-LEAK-RUN] adversarial: caller pre-exports BRIDGE_USAGE_CAPTURED_OAT"
run_env_leak_canary "bash" "bash4-adv-captured" "BRIDGE_USAGE_CAPTURED_OAT=TOKENCANARY-cap-$$-$RANDOM"
echo "[ENV-LEAK-RUN] adversarial: caller pre-exports env_oat"
run_env_leak_canary "bash" "bash4-adv-envoat" "env_oat=TOKENCANARY-eo-$$-$RANDOM"
# r11: the EXACT old env-sentinel FORGE that the fd-transit design kills — a
# caller pre-exporting _BRIDGE_USAGE_OAT_OWNED=1 + _BRIDGE_USAGE_OAT_FILE=<token>
# (which on the old design would have bypassed the scrub) must now be HARMLESS:
# the bridge-private names are unset unconditionally and unused, so the token
# canary is absent from every child env.
echo "[ENV-LEAK-RUN] adversarial: OLD env-sentinel forge (_BRIDGE_USAGE_OAT_OWNED=1 + _BRIDGE_USAGE_OAT_FILE=<token>) must be DEAD"
run_env_leak_canary "bash" "bash4-old-forge" "_BRIDGE_USAGE_OAT_OWNED=1 _BRIDGE_USAGE_OAT_FILE=OLDFORGE-TOKENCANARY-$$-$RANDOM"
# r4 regression: drive via macOS Bash 3.2 (if present) so bridge-lib.sh re-execs
# into Bash 4+. A non-exported capture would be DROPPED by that exec (token
# delivery lost) while leaving the env scrubbed — this asserts both the no-leak
# AND the delivery-survives-re-exec invariants on the re-exec path.
bash32=""
for cand in /bin/bash /usr/bin/bash; do
  if [[ -x "$cand" ]] && "$cand" -c '[[ ${BASH_VERSINFO[0]:-9} -lt 4 ]]' 2>/dev/null; then
    bash32="$cand"; break
  fi
done
if [[ -n "$bash32" ]]; then
  echo "[ENV-LEAK-RUN] Bash 3.2 driver ($bash32 → bridge-lib re-exec path)"
  run_env_leak_canary "$bash32" "bash3.2-reexec"
  echo "[ENV-LEAK-RUN] Bash 3.2 adversarial: caller pre-exports _BRIDGE_USAGE_OAT_FILE=<token>"
  run_env_leak_canary "$bash32" "bash3.2-adv-oatfile" "_BRIDGE_USAGE_OAT_FILE=OATFILE-TOKENCANARY-3x-$$-$RANDOM"
  echo "[ENV-LEAK-RUN] Bash 3.2 adversarial: caller pre-exports _bu_tok=<canary>"
  run_env_leak_canary_butok "$bash32" "bash3.2-adv-butok"
  echo "[ENV-LEAK-RUN] Bash 3.2 adversarial: caller pre-exports BRIDGE_USAGE_CAPTURED_OAT"
  run_env_leak_canary "$bash32" "bash3.2-adv-captured" "BRIDGE_USAGE_CAPTURED_OAT=TOKENCANARY-cap3x-$$-$RANDOM"
  echo "[ENV-LEAK-RUN] Bash 3.2 adversarial: caller pre-exports env_oat"
  run_env_leak_canary "$bash32" "bash3.2-adv-envoat" "env_oat=TOKENCANARY-eo3x-$$-$RANDOM"
  echo "[ENV-LEAK-RUN] Bash 3.2 adversarial: OLD env-sentinel forge must be DEAD"
  run_env_leak_canary "$bash32" "bash3.2-old-forge" "_BRIDGE_USAGE_OAT_OWNED=1 _BRIDGE_USAGE_OAT_FILE=OLDFORGE-TOKENCANARY-3x-$$-$RANDOM"
  echo "[ENV-LEAK-RUN] Bash 3.2 r13 exported-function attack"
  run_func_attack_canary "$bash32" "bash3.2-fnatk"
  echo "[ENV-LEAK-RUN] Bash 3.2 r14 BASH_ENV/ENV startup-hook attack"
  run_bashenv_attack_canary "$bash32" "bash3.2-bashenv"
else
  echo "[ENV-LEAK-RUN] no Bash 3.x on this host; re-exec path not exercised here (covered on macOS)"
fi

if [[ "$failed" -ne 0 ]]; then
  echo "[smoke:${SMOKE_NAME}] FAILED"
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] PASS"
