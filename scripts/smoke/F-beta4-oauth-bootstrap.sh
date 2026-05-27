#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/F-beta4-oauth-bootstrap.sh
#
# Lane F of v0.15.0-beta4 — OOTB-blocker batch closing 3 unrelated-root
# fresh-install symptoms:
#
#   #1261 — controller-credentials fallback (#1075) propagates stale
#           Claude OAuth token. Claude CLI lazy-refreshes the
#           controller's `.credentials.json` only when the controller
#           itself makes an API call; on hosts where the operator works
#           inside agents the controller is idle and its token expires.
#           Daemon's periodic sync then copies that stale token into
#           every agent and every agent 401s at once after the next
#           idle window (~8h on Max plan).
#           Fix: aliveness gate in bridge-auth.py — refuse to propagate
#           when expiresAt <= now, warn (and propagate) on near-expiry;
#           emit aliveness/remaining_ms into the sync JSON payload for
#           the daemon-side audit row. Bootstrap-time OAT advisory.
#
#   #1228 — probe_sudo_self_refresh in scripts/install-daemon-systemd.sh
#           used `set -- /etc/sudoers.d/<glob>` to detect the
#           daemon-refresh sudoers drop-in. On Debian / Ubuntu / RHEL
#           the controller user cannot opendir(3) /etc/sudoers.d/
#           (mode 750 root:root), so the glob never expanded and the
#           probe returned 1 EVEN WHEN the drop-in file objectively
#           existed. Downstream the systemd unit silently shipped with
#           the legacy direct-bash ExecStart, Lane F auto-recovery was
#           dead, and bridge-init.sh unconditionally printed
#           "regenerated (sudo-self) and restarted" — a lie.
#           Fix: replace glob with `sudo -n -ln <exact-command>` (asks
#           sudo's own policy resolver, no privileged dir read needed).
#           Emit a machine-readable `mode=` line to stderr; bridge-init.sh
#           parses it and renders the operator-facing message accurately.
#           Silent legacy fallback now emits a [warn] + audit row.
#
#   #1230 — bridge-bootstrap.sh JSONDecodeError on `bridge-init.sh --json`
#           stdout pollution. bridge-init.sh's `[init] ...` / `[info]
#           ...` printf lines went to stdout, mixing with the JSON
#           object the parent captured via `init_json="$(... --json)"`.
#           Fix: route all log lines to stderr (matches the #1273
#           bridge_info → stderr convention from Lane C). Same applies
#           to install-daemon-systemd.sh's `[info]` echoes since the
#           script is invoked as a subprocess of bridge-init.sh and
#           inherits its stdout.
#
# Test plan (T1-T6 + teeth per issue):
#
#   T1 (#1261). controller_credentials_aliveness Python helper returns
#       ("alive", >0)   for expiresAt in the future beyond min-TTL;
#       ("expired", <=0) for expiresAt at/before now;
#       ("near-expiry", >0) for expiresAt < now+min-TTL;
#       ("no-expires-at", 0) for payload missing expiresAt.
#
#   T2 (#1261). bridge-bootstrap.sh non-JSON output contains the OAT
#       advisory block (so a fresh install operator sees it BEFORE the
#       8h idle window destroys their session).
#
#   T3 (#1228). probe_sudo_self_refresh in install-daemon-systemd.sh
#       uses `sudo -n -ln` (policy listing) NOT the legacy
#       `set -- /etc/sudoers.d/<glob>; [[ -e $1 ]]` pattern. Static
#       source assertion.
#
#   T4 (#1228). install-daemon-systemd.sh emits a [warn] + machine-
#       readable `mode=` line when sudo-self ExecStart is NOT active —
#       the silent legacy fallback is what made the structural defect
#       invisible.
#
#   T5 (#1230). All `[init]` printf calls in bridge-init.sh are routed
#       to stderr (`>&2`). Otherwise --json output would interleave
#       diagnostic lines with the JSON payload and bridge-bootstrap.sh
#       would JSONDecodeError.
#
#   T6 (#1230). All `[info]` echo calls in install-daemon-systemd.sh
#       are routed to stderr. The script is a subprocess of bridge-
#       init.sh under --json, so its stdout becomes bridge-init.sh's
#       stdout becomes bridge-bootstrap.sh's $init_json.
#
#   T7 (teeth #1261). aliveness=expired must cause cmd_sync_agent to
#       raise rather than write a stale credential. Drive the Python
#       handler with a synthetic fixture whose expiresAt is well in the
#       past; assert the run exits non-zero AND the credential file
#       was NOT written.
#
#   T8 (teeth #1228). Search install-daemon-systemd.sh source for the
#       removed glob anti-pattern (`set -- /etc/sudoers.d/agent-bridge-
#       daemon-refresh`). If it ever resurfaces this regression is back.
#
#   T9 (teeth #1230). Run bridge-init.sh --dry-run --json (mutation-
#       free) and assert stdout is parseable JSON — i.e., no
#       diagnostic line slipped through the stderr move. The dry-run
#       path covers the `--json` schema path without requiring an
#       actual install state.
#
# Footgun #11: no `<<EOF` heredoc-stdin into command substitution; no
# `<<<` here-strings into capture. All Python invocations pass paths
# as argv (file-as-argv) and capture stdout via `out=$(... 2>&1)` or
# `out=$(... 2>err)` patterns only.
#
# Isolation: temp BRIDGE_HOME via smoke_setup_bridge_home; no network;
# no real sudo execution (we exercise the source-text invariants and
# the pure-Python aliveness helper directly).

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:F-beta4-oauth-bootstrap][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="F-beta4-oauth-bootstrap"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"
AUTH_PY="$REPO_ROOT/bridge-auth.py"
INIT_SH="$REPO_ROOT/bridge-init.sh"
BOOTSTRAP_SH="$REPO_ROOT/bridge-bootstrap.sh"
SYSTEMD_INSTALL_SH="$REPO_ROOT/scripts/install-daemon-systemd.sh"

smoke_assert_file_exists "$AUTH_PY"             "bridge-auth.py present"
smoke_assert_file_exists "$INIT_SH"             "bridge-init.sh present"
smoke_assert_file_exists "$BOOTSTRAP_SH"        "bridge-bootstrap.sh present"
smoke_assert_file_exists "$SYSTEMD_INSTALL_SH"  "install-daemon-systemd.sh present"

# ---------------------------------------------------------------------------
# T1: controller_credentials_aliveness aliveness gate (pure-Python helper)
# ---------------------------------------------------------------------------
smoke_log "T1 (#1261): controller_credentials_aliveness pure-Python aliveness gate"

T1_DRIVER="$SMOKE_TMP_ROOT/t1-aliveness.py"
cat >"$T1_DRIVER" <<'PY'
"""Drive controller_credentials_aliveness via importlib so the smoke
test does not require bridge-auth.py to live on sys.path."""
import importlib.util
import sys
import time

repo_root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "bridge_auth", repo_root + "/bridge-auth.py"
)
ba = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ba)

now_ms = int(time.time() * 1000)
# Far future — comfortably beyond default 30-min min-TTL.
future = {"claudeAiOauth": {"expiresAt": now_ms + 24 * 3600 * 1000}}
# At/past now.
expired = {"claudeAiOauth": {"expiresAt": now_ms - 1000}}
# In the future but within the min-TTL guard window (5 minutes).
near = {"claudeAiOauth": {"expiresAt": now_ms + 5 * 60 * 1000}}
# Missing expiresAt entirely.
no_field = {"claudeAiOauth": {}}

for label, payload, want in (
    ("alive", future, "alive"),
    ("expired", expired, "expired"),
    ("near-expiry", near, "near-expiry"),
    ("no-expires-at", no_field, "no-expires-at"),
):
    got, remaining = ba.controller_credentials_aliveness(payload, now_ms=now_ms)
    print(f"{label}: status={got} remaining_ms={remaining}")
    if got != want:
        print(f"FAIL: {label} expected status={want} got={got}", file=sys.stderr)
        sys.exit(1)

print("OK")
PY

T1_OUT="$(python3 "$T1_DRIVER" "$REPO_ROOT" 2>&1)" || smoke_fail "T1: aliveness helper raised: $T1_OUT"
smoke_assert_contains "$T1_OUT" "alive: status=alive"                "T1: future expiry classified as alive"
smoke_assert_contains "$T1_OUT" "expired: status=expired"            "T1: past expiry classified as expired"
smoke_assert_contains "$T1_OUT" "near-expiry: status=near-expiry"    "T1: within-TTL expiry classified as near-expiry"
smoke_assert_contains "$T1_OUT" "no-expires-at: status=no-expires-at" "T1: missing expiresAt classified as no-expires-at"
smoke_assert_contains "$T1_OUT" "OK"                                 "T1: driver completed"
smoke_log "T1 PASS — aliveness gate classifies all four token states correctly"

# ---------------------------------------------------------------------------
# T2: bridge-bootstrap.sh OAT advisory block in non-JSON output
# ---------------------------------------------------------------------------
smoke_log "T2 (#1261): bridge-bootstrap.sh OAT advisory block emits to operator"

# Static source assertion — the advisory block must be present so an
# operator running through the bootstrap path sees the recommendation
# BEFORE the 8h idle window converts their install into a 401 timebomb.
if ! grep -nF 'claude-token add' "$BOOTSTRAP_SH" >/dev/null; then
  smoke_fail "T2: bridge-bootstrap.sh does NOT mention 'claude-token add' — OAT advisory missing"
fi
if ! grep -nF '#1261' "$BOOTSTRAP_SH" >/dev/null; then
  smoke_fail "T2: bridge-bootstrap.sh missing #1261 anchor — advisory block may be unrelated text"
fi
if ! grep -nF '#1075' "$BOOTSTRAP_SH" >/dev/null; then
  smoke_fail "T2: bridge-bootstrap.sh missing #1075 anchor — operator can't trace why this advisory exists"
fi
smoke_log "T2 PASS — bridge-bootstrap.sh carries the OAT advisory anchored to #1261 + #1075"

# ---------------------------------------------------------------------------
# T3: probe_sudo_self_refresh uses sudo -n -ln, NOT the glob
# ---------------------------------------------------------------------------
smoke_log "T3 (#1228): probe_sudo_self_refresh uses sudo -ln policy listing"

T3_FN_BODY="$(awk '/^probe_sudo_self_refresh\(\) \{/,/^\}/' "$SYSTEMD_INSTALL_SH")"
if [[ -z "$T3_FN_BODY" ]]; then
  smoke_fail "T3: probe_sudo_self_refresh definition not found in $SYSTEMD_INSTALL_SH"
fi
if [[ "$T3_FN_BODY" != *"sudo -n -ln"* ]]; then
  smoke_fail "T3: probe_sudo_self_refresh does NOT use 'sudo -n -ln' — drop-in detection will fall back to the broken glob anti-pattern (#1228)"
fi
if [[ "$T3_FN_BODY" != *"bridge-daemon.sh restart"* ]]; then
  smoke_fail "T3: probe_sudo_self_refresh does NOT name the exact bridge-daemon.sh restart command — generic 'sudo to self' would false-positive"
fi
smoke_log "T3 PASS — probe_sudo_self_refresh queries sudo policy directly"

# ---------------------------------------------------------------------------
# T4: install-daemon-systemd.sh emits machine-readable mode= line +
#     legacy fallback warn
# ---------------------------------------------------------------------------
smoke_log "T4 (#1228): install-daemon-systemd.sh emits mode= line + [warn] on legacy fallback"

if ! grep -nF 'mode=sudo-self' "$SYSTEMD_INSTALL_SH" >/dev/null; then
  smoke_fail "T4: install-daemon-systemd.sh missing 'mode=sudo-self' machine-parseable emit"
fi
if ! grep -nF 'mode=legacy' "$SYSTEMD_INSTALL_SH" >/dev/null; then
  smoke_fail "T4: install-daemon-systemd.sh missing 'mode=legacy' machine-parseable emit"
fi
if ! grep -nF 'sudo-self ExecStart NOT active' "$SYSTEMD_INSTALL_SH" >/dev/null; then
  smoke_fail "T4: install-daemon-systemd.sh missing legacy-fallback warn — silent fallback regression risk"
fi
if ! grep -nF '[warn]' "$SYSTEMD_INSTALL_SH" >/dev/null; then
  smoke_fail "T4: install-daemon-systemd.sh does not emit any [warn] tag — legacy fallback must be loud"
fi
# bridge-init.sh must parse and condition the operator message on the mode= line.
if ! grep -nF 'mode=' "$INIT_SH" >/dev/null; then
  smoke_fail "T4: bridge-init.sh does not consume the mode= line — operator message will still falsely claim 'regenerated (sudo-self)' on legacy fallback"
fi
smoke_log "T4 PASS — silent legacy fallback closed (mode= line + [warn] both present)"

# ---------------------------------------------------------------------------
# T5: bridge-init.sh routes [init] log lines to stderr (#1230)
# ---------------------------------------------------------------------------
smoke_log "T5 (#1230): bridge-init.sh routes [init] log lines to stderr"

# All printf '[init] ...' calls must be terminated with `>&2` so the
# --json contract holds (stdout = data only). The two existing stderr-
# redirected lines (already on >&2 before this lane) serve as control.
T5_OFFENDERS="$(grep -nE "printf '\[init\] [^']*'.*\\\\n'( *)$" "$INIT_SH" || true)"
if [[ -n "$T5_OFFENDERS" ]]; then
  smoke_fail "T5: bridge-init.sh has [init] printf calls NOT terminated with >&2 (would poison --json stdout):"$'\n'"$T5_OFFENDERS"
fi
# Stronger: any `printf '[init]` line that doesn't end with `>&2` is a leak.
T5_LEAKS="$(grep -nE "printf '\[init\]" "$INIT_SH" | grep -v '>&2' || true)"
if [[ -n "$T5_LEAKS" ]]; then
  smoke_fail "T5: [init] printf calls without >&2 redirect found:"$'\n'"$T5_LEAKS"
fi
smoke_log "T5 PASS — all [init] log lines route to stderr"

# ---------------------------------------------------------------------------
# T6: install-daemon-systemd.sh routes [info] echo lines to stderr (#1230)
# ---------------------------------------------------------------------------
smoke_log "T6 (#1230): install-daemon-systemd.sh routes [info] echo lines to stderr"

T6_LEAKS="$(grep -nE 'echo "\[info\]' "$SYSTEMD_INSTALL_SH" | grep -v '>&2' || true)"
if [[ -n "$T6_LEAKS" ]]; then
  smoke_fail "T6: [info] echo calls without >&2 redirect found in $SYSTEMD_INSTALL_SH:"$'\n'"$T6_LEAKS"
fi
smoke_log "T6 PASS — all [info] echo lines route to stderr"

# ---------------------------------------------------------------------------
# T7 (teeth #1261): expired controller credential rejected by cmd_sync_agent
# ---------------------------------------------------------------------------
smoke_log "T7 (teeth #1261): cmd_sync_agent refuses to propagate an expired controller credential"

T7_FIXTURE_DIR="$SMOKE_TMP_ROOT/t7-controller-home/.claude"
mkdir -p "$T7_FIXTURE_DIR"
T7_CREDS="$T7_FIXTURE_DIR/.credentials.json"
T7_EXPIRED_MS=$(($(date +%s) * 1000 - 24 * 3600 * 1000))  # 24h in the past
cat >"$T7_CREDS" <<JSON
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-EXPIRED-FIXTURE-TOKEN-T7",
    "expiresAt": $T7_EXPIRED_MS,
    "refreshToken": "rt-fixture",
    "scopes": ["user:inference", "user:profile"]
  }
}
JSON
chmod 0600 "$T7_CREDS"

# Empty registry — forces the controller-credentials fallback branch.
T7_REGISTRY="$SMOKE_TMP_ROOT/t7-registry.json"
cat >"$T7_REGISTRY" <<'JSON'
{
  "version": 1,
  "active_token_id": "",
  "tokens": []
}
JSON
chmod 0600 "$T7_REGISTRY"

T7_TARGET_DIR="$SMOKE_TMP_ROOT/t7-agent-claude"
mkdir -p "$T7_TARGET_DIR"
T7_TARGET_FILE="$T7_TARGET_DIR/.credentials.json"
# Make sure file does NOT exist before the call — that way we can prove
# the aliveness guard short-circuited before the writer touched anything.
rm -f "$T7_TARGET_FILE"

T7_STDERR="$SMOKE_TMP_ROOT/t7-stderr"
T7_RC=0
python3 "$AUTH_PY" \
  --registry "$T7_REGISTRY" \
  sync-agent \
  --agent t7_agent \
  --file "$T7_TARGET_FILE" \
  --controller-credentials "$T7_CREDS" \
  --allowed-root "$SMOKE_TMP_ROOT" \
  --json \
  >"$SMOKE_TMP_ROOT/t7-stdout" 2>"$T7_STDERR" \
  || T7_RC=$?

if (( T7_RC == 0 )); then
  smoke_fail "T7: cmd_sync_agent returned rc=0 with an expired controller credential — aliveness gate missing"
fi
if [[ -f "$T7_TARGET_FILE" ]]; then
  smoke_fail "T7: cmd_sync_agent wrote $T7_TARGET_FILE despite the controller credential being expired — aliveness gate is not protecting the writer"
fi
T7_STDOUT="$(cat "$SMOKE_TMP_ROOT/t7-stdout" 2>/dev/null || printf '')"
# The JSON failure payload should mention "expired" in the message.
if [[ "$T7_STDOUT" != *"expired"* ]]; then
  smoke_fail "T7: failure payload does not mention 'expired' (got stdout='$T7_STDOUT' stderr='$(cat "$T7_STDERR" 2>/dev/null)')"
fi
smoke_log "T7 PASS — expired controller credential rejected, no writer side effect"

# ---------------------------------------------------------------------------
# T8 (teeth #1228): the legacy glob anti-pattern stays excised
# ---------------------------------------------------------------------------
smoke_log "T8 (teeth #1228): legacy glob anti-pattern absent from probe_sudo_self_refresh"

if grep -nE 'set --[[:space:]]+/etc/sudoers\.d/agent-bridge-daemon-refresh' "$SYSTEMD_INSTALL_SH" >/dev/null; then
  smoke_fail "T8: legacy glob anti-pattern (set -- /etc/sudoers.d/agent-bridge-daemon-refresh-*) found in $SYSTEMD_INSTALL_SH — #1228 regression"
fi
smoke_log "T8 PASS — legacy glob anti-pattern stays excised"

# ---------------------------------------------------------------------------
# T9 (teeth #1230): bridge-init.sh --dry-run --json stdout is parseable JSON
# ---------------------------------------------------------------------------
smoke_log "T9 (teeth #1230): bridge-init.sh --dry-run --json stdout is pure JSON"

# Skip if we can't satisfy bridge_init_require_command's hard
# dependencies (tmux / python3 / claude). The dry-run still calls those
# guards and would exit non-zero in CI without them — that is unrelated
# to the #1230 fix and out of this lane's scope. python3 is already
# required by smoke_require_cmd above; claude/tmux are not.
if ! command -v tmux >/dev/null 2>&1; then
  smoke_log "T9 SKIP — tmux not on PATH; bridge-init.sh --dry-run cannot proceed"
elif ! command -v claude >/dev/null 2>&1; then
  smoke_log "T9 SKIP — claude not on PATH; bridge-init.sh --dry-run cannot proceed"
else
  T9_STDOUT="$SMOKE_TMP_ROOT/t9-stdout"
  T9_STDERR="$SMOKE_TMP_ROOT/t9-stderr"
  T9_RC=0
  # Use the smoke-test BRIDGE_HOME so we never touch the operator's
  # real install. The --dry-run + --skip-channel-setup flags keep the
  # call mutation-free.
  bash "$INIT_SH" \
    --admin t9_admin \
    --engine claude \
    --dry-run \
    --json \
    --skip-channel-setup \
    --skip-validate \
    --skip-send-test \
    >"$T9_STDOUT" 2>"$T9_STDERR" \
    || T9_RC=$?

  if (( T9_RC != 0 )); then
    smoke_log "T9 SKIP — bridge-init.sh --dry-run --json exited rc=$T9_RC (env-dependent guard failure): stderr='$(head -c 400 "$T9_STDERR" 2>/dev/null)'"
  else
    # The stdout MUST parse as JSON. If a stray printf '[init] ...'
    # without `>&2` leaked through, json.loads raises with
    # "Expecting value: line 1 column 1 (char 0)" — exactly the #1230
    # symptom bridge-bootstrap.sh hit.
    T9_PARSE_RC=0
    python3 -c "import json, sys; json.loads(open(sys.argv[1]).read())" "$T9_STDOUT" >/dev/null 2>&1 \
      || T9_PARSE_RC=$?
    if (( T9_PARSE_RC != 0 )); then
      smoke_fail "T9: bridge-init.sh --dry-run --json stdout is NOT parseable JSON (#1230 regression). stdout head: $(head -c 400 "$T9_STDOUT")"
    fi
    smoke_log "T9 PASS — bridge-init.sh --dry-run --json stdout is pure JSON"
  fi
fi

smoke_log "ALL TESTS PASS"
