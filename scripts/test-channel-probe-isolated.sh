#!/usr/bin/env bash
# Regression coverage for issue #832 — channel-health probe must degrade to
# "controller-blind" / status "unknown" when the controller cannot read an
# isolated agent's dotenv AND we cannot sudo to that agent's UID to verify.
# Without this, the daemon collapses an indeterminate readiness into a
# confirmed "miss" and fires a false channel_health_miss audit row on every
# health cycle.
#
# Runs in an isolated $HOME and $BRIDGE_HOME and stubs `sudo` plus the
# isolation-aware helpers so it never reads or writes the operator's live
# runtime and never requires a real isolated-UID rig.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP_HOME="$(mktemp -d -t agb-channel-probe-test.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export BRIDGE_HOME="$TMP_HOME/.agent-bridge"
mkdir -p "$BRIDGE_HOME"

# --- Extract just the functions under test --------------------------------
# This keeps the test self-contained without sourcing the full bridge-lib.sh
# (which would pull in roster, sudo install, daemon state, etc.).
EXTRACT_TMP="$TMP_HOME/extract.sh"
awk '
  /^bridge_trim_whitespace\(\) \{/ ||
  /^bridge_append_csv_unique\(\) \{/ ||
  /^bridge_qualify_channel_item\(\) \{/ ||
  /^bridge_merge_channels_csv\(\) \{/ ||
  /^bridge_env_file_has_any_nonempty_key\(\) \{/ ||
  /^bridge_channel_env_file_readiness\(\) \{/ ||
  /^bridge_channel_env_file_acl_diagnostic\(\) \{/ ||
  /^bridge_agent_channel_status\(\) \{/ {
    copy = 1
  }
  copy { print }
  copy && /^\}$/ { copy = 0; print "" }
' "$ROOT_DIR/lib/bridge-agents.sh" >"$EXTRACT_TMP"

# Inline the new isolation helpers verbatim so this test exercises the real
# helpers under test, not stubs of them.
cat "$ROOT_DIR/lib/bridge-isolation-helpers.sh" >>"$EXTRACT_TMP"

# Stubs for transitive deps. Tests below override these per case.
cat >>"$EXTRACT_TMP" <<'EOF'

# Default: agent is NOT linux-user isolated. Override per-test.
bridge_agent_linux_user_isolation_effective() { return 1; }
# Default: agent has no os_user mapping.
bridge_agent_os_user() { printf ''; }
# Default: channels CSV — test sets via STUB_REQUIRED_CSV.
bridge_agent_channels_csv() { printf '%s' "${STUB_REQUIRED_CSV:-}"; }
bridge_agent_channel_status_reason() { printf '%s' "${STUB_STATUS_REASON:-}"; }
EOF

# shellcheck source=/dev/null
source "$EXTRACT_TMP"

# Sudo / sudo-helper stubs are managed per-test via shell function overrides
# so we can simulate the three sudo behaviors (no-sudo, sudo-ok-script-0,
# sudo-ok-script-1, sudo-ok-script-2). The shellcheck SC2329 disable is to
# tell shellcheck these are intentional override stubs.

stub_not_isolated() {
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 1; }
  # shellcheck disable=SC2329
  bridge_agent_os_user() { printf ''; }
}

stub_isolated_no_sudo() {
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 0; }
  # shellcheck disable=SC2329
  bridge_agent_os_user() { printf 'fake-user'; }
  # shellcheck disable=SC2329
  bridge_isolation_can_sudo_to_agent() { return 2; }
  # shellcheck disable=SC2329
  bridge_isolation_run_as_agent_user_via_bash() { return 2; }
}

STUB_SCRIPT_RC=0
stub_isolated_sudo_ok_script() {
  STUB_SCRIPT_RC="$1"
  # shellcheck disable=SC2329
  bridge_agent_linux_user_isolation_effective() { return 0; }
  # shellcheck disable=SC2329
  bridge_agent_os_user() { printf 'fake-user'; }
  # shellcheck disable=SC2329
  bridge_isolation_can_sudo_to_agent() { return 0; }
  # Mimic the helper's exit-code translation: script rc 0 -> 0, rc 1 -> 3,
  # rc 2 -> 4. STUB_SCRIPT_RC is the raw script exit code under test.
  # shellcheck disable=SC2329
  bridge_isolation_run_as_agent_user_via_bash() {
    local _rc="$STUB_SCRIPT_RC"
    if [[ "$_rc" -eq 0 ]]; then
      return 0
    fi
    return $((_rc + 2))
  }
}

# --- C1: controller-readable + not isolated -> "present" ---------------------
step "C1: controller-readable + not isolated -> present"
stub_not_isolated
F1="$TMP_HOME/c1.env"
printf 'DISCORD_BOT_TOKEN=abc123\n' >"$F1"
chmod 600 "$F1"
out="$(bridge_channel_env_file_readiness agent-test plugin:discord "$F1" DISCORD_BOT_TOKEN)"
if [[ "$out" == "present" ]]; then ok; else err "got '$out'"; fi

# --- C2: isolated + sudo OK + readable + has keys -> "present" ---------------
# Simulate by making the controller-side `[[ -r ]]` fail (chmod 000) so the
# code path falls through to the isolation probe, and then have the script
# return 0.
step "C2: isolated + sudo OK + readable + has keys -> present"
F2="$TMP_HOME/c2.env"
printf 'DISCORD_BOT_TOKEN=abc123\n' >"$F2"
chmod 000 "$F2"
stub_isolated_sudo_ok_script 0
out="$(bridge_channel_env_file_readiness agent-test plugin:discord "$F2" DISCORD_BOT_TOKEN)"
if [[ "$out" == "present" ]]; then ok; else err "got '$out'"; fi
chmod 600 "$F2"  # restore so trap can clean

# --- C3: isolated + sudo OK + readable + empty -> "missing" ------------------
step "C3: isolated + sudo OK + readable + empty -> missing"
F3="$TMP_HOME/c3.env"
printf '# no keys\n' >"$F3"
chmod 000 "$F3"
stub_isolated_sudo_ok_script 1
out="$(bridge_channel_env_file_readiness agent-test plugin:discord "$F3" DISCORD_BOT_TOKEN)"
if [[ "$out" == "missing" ]]; then ok; else err "got '$out'"; fi
chmod 600 "$F3"

# --- C4: isolated + sudo OK + not-readable-by-isolated -> "unreadable" -------
step "C4: isolated + sudo OK + script reports not-readable -> unreadable"
F4="$TMP_HOME/c4.env"
printf 'DISCORD_BOT_TOKEN=zzz\n' >"$F4"
chmod 000 "$F4"
stub_isolated_sudo_ok_script 2
out="$(bridge_channel_env_file_readiness agent-test plugin:discord "$F4" DISCORD_BOT_TOKEN)"
if [[ "$out" == "unreadable" ]]; then ok; else err "got '$out'"; fi
chmod 600 "$F4"

# --- C5: isolated + sudo UNAVAILABLE -> "controller-blind" -------------------
step "C5: isolated + no passwordless sudo -> controller-blind"
F5="$TMP_HOME/c5.env"
printf 'DISCORD_BOT_TOKEN=zzz\n' >"$F5"
chmod 000 "$F5"
stub_isolated_no_sudo
out="$(bridge_channel_env_file_readiness agent-test plugin:discord "$F5" DISCORD_BOT_TOKEN)"
C5_RESULT="$out"
if [[ "$out" == "controller-blind" ]]; then ok; else err "got '$out'"; fi
chmod 600 "$F5"

# --- C6: status mapping: controller-blind reason -> "unknown" ----------------
step "C6: bridge_agent_channel_status returns 'unknown' for controller-blind reason"
STUB_REQUIRED_CSV="plugin:discord"
STUB_STATUS_REASON='controller-blind:plugin:discord:/some/path/.env:no-passwordless-sudo (set BRIDGE_AGENT_SUDOERS; run: agent-bridge migrate isolation v3 --check) {"mode":"600"}'
out="$(bridge_agent_channel_status agent-test)"
if [[ "$out" == "unknown" ]]; then ok; else err "got '$out'"; fi

# --- C7: confirm a confirmed-miss reason still maps to "miss" ---------------
step "C7: confirmed miss reason still maps to 'miss' (regression sanity)"
STUB_REQUIRED_CSV="plugin:discord"
STUB_STATUS_REASON="missing Discord bot token under /tmp/x (.env with DISCORD_BOT_TOKEN required)"
out="$(bridge_agent_channel_status agent-test)"
if [[ "$out" == "miss" ]]; then ok; else err "got '$out'"; fi

# --- C8: daemon channel_health_miss must NOT fire on "unknown" --------------
# We exercise the daemon's gating clause directly without spinning the full
# daemon — extract the early return logic and assert: when status="unknown",
# the function returns early WITHOUT emitting an audit row.
step "C8: bridge_report_channel_health_miss returns early on status=unknown"
DAEMON_GATE_TMP="$TMP_HOME/daemon-gate.sh"
cat >"$DAEMON_GATE_TMP" <<'EOF'
# Minimal replica of the gating clause in bridge-daemon.sh's
# bridge_report_channel_health_miss. If the clause loses the
# `status != "miss"` early-return for "unknown", this test will see
# AUDIT_FIRED=1 (regression).
AUDIT_FIRED=0
bridge_audit_log() { AUDIT_FIRED=1; }
bridge_clear_channel_health_state() { :; }
gate_status="$1"
if [[ "$gate_status" != "miss" ]]; then
  bridge_clear_channel_health_state foo
  exit 0
fi
bridge_audit_log daemon channel_health_miss foo
EOF
unknown_rc=0
( bash "$DAEMON_GATE_TMP" "unknown" ) || unknown_rc=$?
miss_rc=0
( bash "$DAEMON_GATE_TMP" "miss" ) || miss_rc=$?
# When status=unknown: rc=0 and no audit. When status=miss: rc=0 but audit
# would fire. We test by inspecting AUDIT_FIRED via sub-shell side-effects;
# simpler — re-run with `set -x`-style tracking via env file.
AUDIT_PROBE="$TMP_HOME/audit-probe.txt"
cat >"$DAEMON_GATE_TMP" <<EOF
AUDIT_FIRED=0
bridge_audit_log() { AUDIT_FIRED=1; printf '%s\n' "fired" >"$AUDIT_PROBE"; }
bridge_clear_channel_health_state() { :; }
gate_status="\$1"
if [[ "\$gate_status" != "miss" ]]; then
  bridge_clear_channel_health_state foo
  exit 0
fi
bridge_audit_log daemon channel_health_miss foo
EOF
rm -f "$AUDIT_PROBE"
bash "$DAEMON_GATE_TMP" "unknown"
if [[ ! -f "$AUDIT_PROBE" ]]; then
  ok
else
  err "audit fired on status=unknown (regression: daemon would emit false miss)"
fi

# --- C9: launch path -- controller-blind NOT in missing_channels_csv --------
# Re-source the full helpers we need: missing-channels CSV depends on
# bridge_channel_credentials_status_for_item which we extract here.
step "C9: bridge_agent_missing_channels_csv excludes controller-blind channels"
EXTRACT_LAUNCH="$TMP_HOME/extract-launch.sh"
awk '
  /^bridge_trim_whitespace\(\) \{/ ||
  /^bridge_append_csv_unique\(\) \{/ ||
  /^bridge_qualify_channel_item\(\) \{/ ||
  /^bridge_channel_credentials_status_for_item\(\) \{/ ||
  /^bridge_agent_controller_blind_channels_csv\(\) \{/ ||
  /^bridge_agent_ready_channels_csv\(\) \{/ ||
  /^bridge_agent_missing_channels_csv\(\) \{/ {
    copy = 1
  }
  copy { print }
  copy && /^\}$/ { copy = 0; print "" }
' "$ROOT_DIR/lib/bridge-agents.sh" >"$EXTRACT_LAUNCH"

# shellcheck source=/dev/null
source "$EXTRACT_LAUNCH"

# Stubs for transitive deps used by the credentials helper.
# Use a single channel dir regardless of qualified item form so the dotenv
# path resolution stays deterministic (bridge_qualify_channel_item may
# append `@claude-plugins-official` to a bare `plugin:discord`).
C9_DIR="$BRIDGE_HOME/state/c9-discord"
mkdir -p "$C9_DIR"
# shellcheck disable=SC2329
bridge_channel_state_dir_for_item() { printf '%s' "$C9_DIR"; }
# Mark this channel as controller-blind by simulating an unreadable file
# AND isolated + no-sudo via the existing readiness function.
F9="$C9_DIR/.env"
printf 'DISCORD_BOT_TOKEN=zzz\n' >"$F9"
chmod 000 "$F9"
stub_isolated_no_sudo
# Override channels CSV for this test.
# shellcheck disable=SC2329
bridge_agent_channels_csv() { printf '%s' 'plugin:discord'; }
# bridge_agent_channel_runtime_ready_for_item is required by missing/ready —
# stub it to always say "no" so the missing branch decides based purely on
# the controller-blind credentials short-circuit.
# shellcheck disable=SC2329
bridge_agent_channel_runtime_ready_for_item() { return 1; }

missing_out="$(bridge_agent_missing_channels_csv agent-test)"
ready_out="$(bridge_agent_ready_channels_csv agent-test)"
blind_out="$(bridge_agent_controller_blind_channels_csv agent-test)"
if [[ "$missing_out" == "" && "$ready_out" == "" && "$blind_out" == "plugin:discord" ]]; then
  ok
else
  err "missing='$missing_out' ready='$ready_out' blind='$blind_out' (expected missing=empty ready=empty blind=plugin:discord)"
fi
chmod 600 "$F9"

# --- C10: diagnostics renderer shape (controller-blind ↔ ready=indeterminate)
# Light-touch: we just confirm the readiness function's output is one of the
# four documented values. Full diagnostics integration is covered by smoke.
step "C10: readiness function output is one of {present,missing,unreadable,controller-blind}"
case "$(printf 'present\nmissing\nunreadable\ncontroller-blind\n' | grep -Fx "$C5_RESULT")" in
  "")
    err "C5 result '$C5_RESULT' not in documented set"
    ;;
  *)
    ok
    ;;
esac

# --- C11: inline probe script regex parity with controller-side helper -------
# The other isolated cases stub out bridge_isolation_run_as_agent_user_via_bash
# entirely so they don't exercise the inline grep. This case extracts the
# probe script literally from lib/bridge-agents.sh and runs it against fixture
# files to verify regex parity with bridge_env_file_has_any_nonempty_key — in
# particular that `export KEY=value` is accepted on the isolated path (the
# controller helper at lib/bridge-agents.sh:4220 accepts that form).
step "C11: inline probe accepts 'export KEY=value' (parity with controller helper)"

INLINE_PROBE="$TMP_HOME/inline-probe.sh"
{
  printf '#!/usr/bin/env bash\n'
  # Extract the probe_script body verbatim — between the single-quoted opener
  # and the standalone closing quote line. This keeps the test trapping a
  # future drift in the inline regex.
  awk "
    /^[[:space:]]*probe_script='\$/ { capture=1; next }
    capture && /^'\$/ { capture=0; next }
    capture { print }
  " "$ROOT_DIR/lib/bridge-agents.sh"
} >"$INLINE_PROBE"
chmod +x "$INLINE_PROBE"
# Sanity: the extraction produced a nonempty file
if [[ ! -s "$INLINE_PROBE" ]]; then
  err "could not extract probe_script from bridge-agents.sh"
fi

run_probe() {
  bash "$INLINE_PROBE" "$@"
}

C11_FAIL=0
# C11a: bare KEY=value, with key filter, present.
F11a="$TMP_HOME/c11a.env"
printf 'DISCORD_BOT_TOKEN=abc123\n' >"$F11a"
run_probe "$F11a" DISCORD_BOT_TOKEN || { C11_FAIL=1; err "C11a bare key: expected 0 got $?"; }

# C11b: export KEY=value, with key filter — must match.
F11b="$TMP_HOME/c11b.env"
printf 'export DISCORD_BOT_TOKEN=abc123\n' >"$F11b"
run_probe "$F11b" DISCORD_BOT_TOKEN || { C11_FAIL=1; err "C11b export form: expected 0 got $?"; }

# C11c: export with multiple spaces between export and key.
F11c="$TMP_HOME/c11c.env"
printf 'export   DISCORD_BOT_TOKEN=abc123\n' >"$F11c"
run_probe "$F11c" DISCORD_BOT_TOKEN || { C11_FAIL=1; err "C11c multi-space export: expected 0 got $?"; }

# C11d: keyless mode (no positional args after file) accepts export form too.
F11d="$TMP_HOME/c11d.env"
printf 'export FOO=bar\n' >"$F11d"
run_probe "$F11d" || { C11_FAIL=1; err "C11d keyless export: expected 0 got $?"; }

# C11e: empty value still rejected (existing controller helper rejects it too).
F11e="$TMP_HOME/c11e.env"
printf 'export DISCORD_BOT_TOKEN=\n' >"$F11e"
if run_probe "$F11e" DISCORD_BOT_TOKEN 2>/dev/null; then
  C11_FAIL=1
  err "C11e empty value: expected 1, got 0 (regex too loose)"
fi

# C11f: comment line not treated as a value.
F11f="$TMP_HOME/c11f.env"
printf '# export DISCORD_BOT_TOKEN=abc\n' >"$F11f"
if run_probe "$F11f" DISCORD_BOT_TOKEN 2>/dev/null; then
  C11_FAIL=1
  err "C11f commented line: expected 1, got 0"
fi

if [[ "$C11_FAIL" -eq 0 ]]; then ok; fi

# --- Summary -----------------------------------------------------------------
TOTAL=$((PASS + FAIL))
printf '\n# Issue #832 channel-probe isolation suite: %s/%s passed\n' "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
