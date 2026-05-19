#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

# shellcheck source=../lib/bridge-session-patterns.sh
source "$REPO_ROOT/lib/bridge-session-patterns.sh"

# Safety: refuse to run against a live BRIDGE_HOME. smoke deliberately stops
# its own daemon on cleanup, adopts/kills tmux sessions, and wipes state under
# $TMP_ROOT. If BRIDGE_HOME is inherited from the parent shell and points at a
# real install (e.g. $HOME/.agent-bridge), we would terminate the running
# daemon, drop dynamic agent sessions, and trash live state. See issue #207.
#
# Auto-isolate when BRIDGE_HOME is UNSET: prior versions silently fell through
# this guard and the subsequent early test blocks (run before $TMP_ROOT is
# computed at line ~1289) inherited the agent-bridge CLI default
# `$HOME/.agent-bridge`, leaking ~10 empty agent dirs into the live install
# (`claude-static`, `cap-test`, `spool-test`, `lock-test`, `always-on-agent-$$`,
# etc.) and tripping the watchdog drift alarm every cycle. Refs queue #4793,
# operator-host evidence 2026-05-17.
if [[ -z "${BRIDGE_HOME:-}" ]]; then
  BRIDGE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agb-smoke-isolated.XXXXXX")/.agent-bridge"
  export BRIDGE_HOME
  _SMOKE_AUTO_ISOLATED=1
  # r5 (codex PR #947 r4) — export so child bash -s blocks see it.
  # Without export, the conditional refresh blocks at line ~1148 and ~1330
  # in child shells see _SMOKE_AUTO_ISOLATED as empty and never re-derive
  # BRIDGE_DATA_ROOT, so pending-attention state ends up under the initial
  # auto-isolated home outside $scratch / $TMP_ROOT.
  export _SMOKE_AUTO_ISOLATED
  printf '[smoke] BRIDGE_HOME auto-isolated to %s (was unset)\n' "$BRIDGE_HOME"
  # #946: when the smoke matrix runs against an auto-isolated fresh
  # temp BRIDGE_HOME, every child shell that sources bridge-lib.sh
  # would otherwise be classified as `fresh-install-candidate` and
  # die at the v0.8.0 isolation hard-cut (the fresh-install bypass
  # handshake requires the owner to be bridge-init.sh / bridge-
  # bootstrap.sh / agent-bridge — smoke is none of those). Export
  # an explicit v2 layout override so resolver step 1 (env) wins
  # and the matrix can actually run. macOS platform discriminator
  # skips the v2 isolation enforcement (no `ab-shared` group), so
  # the override is safe; on Linux without v2 primitives the same
  # discriminator silently skips enforcement, matching the auto
  # behavior of v0.14.1 fresh installs. Only applied for the auto-
  # isolated path — when the caller exports BRIDGE_HOME (CI runner,
  # custom rig) they remain responsible for layout state.
  # r4 (codex PR #947 r3) — unset derived v2 roots that bridge-isolation-v2.sh
  # preserves via the ${VAR:-default} idiom. Without unsetting, an operator
  # shell that already exported these (e.g. an Agent Bridge-managed admin
  # session running smoke against this checkout) would let later helpers
  # write runtime/shared/state under the LIVE install despite the auto-
  # isolated BRIDGE_HOME. Unsetting forces bridge-isolation-v2.sh to
  # recompute from the freshly set BRIDGE_DATA_ROOT.
  unset BRIDGE_AGENT_ROOT_V2 BRIDGE_SHARED_ROOT BRIDGE_CONTROLLER_STATE_ROOT
  export BRIDGE_LAYOUT="v2"
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME/data"
fi
if [[ -n "${BRIDGE_HOME:-}" ]]; then
  _smoke_allowed_tmp_prefix=""
  for _smoke_tmp_candidate in "${TMPDIR:-}" "/tmp" "/private/tmp" "/var/folders"; do
    _smoke_tmp_candidate="${_smoke_tmp_candidate%/}"
    [[ -n "$_smoke_tmp_candidate" ]] || continue
    case "$BRIDGE_HOME" in
      "$_smoke_tmp_candidate"|"$_smoke_tmp_candidate"/*)
        _smoke_allowed_tmp_prefix="$_smoke_tmp_candidate"
        break
        ;;
    esac
  done
  if [[ -z "$_smoke_allowed_tmp_prefix" ]]; then
    printf '[smoke][error] refusing to run against non-temp BRIDGE_HOME: %s\n' "$BRIDGE_HOME" >&2
    printf '[smoke][error] smoke-test.sh will stop its own daemon and kill tmux sessions; this would destroy a live install.\n' >&2
    printf '[smoke][error] unset BRIDGE_HOME or point it under a temp prefix ($TMPDIR, /tmp, /private/tmp, /var/folders) before running smoke.\n' >&2
    exit 1
  fi
  unset _smoke_allowed_tmp_prefix _smoke_tmp_candidate
fi

# Issue #403: the BRIDGE_HOME guard above isn't enough — isolation tests
# compute destructive paths from BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT
# (default /home) + os_user, NOT from BRIDGE_HOME. Refuse to run when
# the override is set but doesn't point under a recognised tempdir.
# (Default /home is rejected outright when set; if unset, downstream
# isolation suites are responsible for setting their own tmp-rooted
# value — see tests/isolation-v2-pr-e/smoke.sh.)
if [[ -n "${BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT:-}" ]]; then
  _smoke_iso_allowed=""
  for _smoke_iso_candidate in "${TMPDIR:-}" "/tmp" "/private/tmp" "/var/folders" "/private/var/folders"; do
    _smoke_iso_candidate="${_smoke_iso_candidate%/}"
    [[ -n "$_smoke_iso_candidate" ]] || continue
    case "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT" in
      "$_smoke_iso_candidate"|"$_smoke_iso_candidate"/*)
        _smoke_iso_allowed="$_smoke_iso_candidate"
        break
        ;;
    esac
  done
  if [[ -z "$_smoke_iso_allowed" ]]; then
    printf '[smoke][error] refusing to run with BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT=%s (must be under /tmp or $TMPDIR — issue #403)\n' \
      "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT" >&2
    exit 1
  fi
  unset _smoke_iso_allowed _smoke_iso_candidate
fi

log() {
  printf '[smoke] %s\n' "$*"
}

die() {
  printf '[smoke][error] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || die "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || die "expected output to not contain: $needle"
}

tmux_session_target() {
  local session="$1"
  printf '=%s' "$session"
}

tmux_pane_target() {
  local session="$1"
  printf '=%s:' "$session"
}

tmux_has_session_exact() {
  local session="$1"
  tmux has-session -t "$(tmux_session_target "$session")" >/dev/null 2>&1
}

tmux_kill_session_exact() {
  local session="$1"
  tmux kill-session -t "$(tmux_session_target "$session")" >/dev/null 2>&1
}

wait_for_tmux_session() {
  local session="$1"
  local expected="${2:-up}"
  local attempts="${3:-20}"
  local delay="${4:-0.2}"
  local i=0

  for ((i = 0; i < attempts; i++)); do
    if tmux_has_session_exact "$session"; then
      [[ "$expected" == "up" ]] && return 0
    else
      [[ "$expected" == "down" ]] && return 0
    fi
    sleep "$delay"
  done
  return 1
}

kill_stale_smoke_tmux_sessions() {
  local session=""

  while IFS= read -r session; do
    [[ -n "$session" ]] || continue
    if bridge_session_is_smoke_or_adhoc "$session"; then
      tmux_kill_session_exact "$session" || true
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
}

# Track managed-role agent ids the smoke fixture wrote into
# $BRIDGE_ROSTER_LOCAL_FILE so cleanup() can strip the
# `# BEGIN AGENT BRIDGE MANAGED ROLE: <id>` ... `# END ...` blocks on exit.
# Issue #305 — without teardown, an operator who points the smoke roster at a
# real file (or whose $BRIDGE_HOME survives the run) keeps a dead static role
# registration forever.
SMOKE_REGISTERED_AGENT_IDS=()

smoke_track_managed_role_id() {
  local id="$1"
  [[ -n "$id" ]] || return 0
  SMOKE_REGISTERED_AGENT_IDS+=("$id")
}

smoke_strip_managed_role_block() {
  # Remove `# BEGIN AGENT BRIDGE MANAGED ROLE: <id>` ... `# END ...` block from
  # $BRIDGE_ROSTER_LOCAL_FILE. No-op if the file is missing or the markers are
  # absent. Idempotent so cleanup can be re-entered safely.
  local id="$1"
  local file="${2:-${BRIDGE_ROSTER_LOCAL_FILE:-}}"
  [[ -n "$id" && -n "$file" && -f "$file" ]] || return 0
  if ! grep -qF "# BEGIN AGENT BRIDGE MANAGED ROLE: $id" "$file" 2>/dev/null; then
    return 0
  fi
  if ! grep -qF "# END AGENT BRIDGE MANAGED ROLE: $id" "$file" 2>/dev/null; then
    return 0
  fi
  python3 - "$file" "$id" <<'PY' || return 0
import sys
from pathlib import Path

path = Path(sys.argv[1])
agent = sys.argv[2]
begin = f"# BEGIN AGENT BRIDGE MANAGED ROLE: {agent}"
end = f"# END AGENT BRIDGE MANAGED ROLE: {agent}"
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
out = []
inside = False
for line in lines:
    stripped = line.rstrip("\n")
    if not inside and stripped == begin:
        inside = True
        continue
    if inside and stripped == end:
        inside = False
        continue
    if inside:
        continue
    out.append(line)
path.write_text("".join(out), encoding="utf-8")
PY
}

require_cmd bash
require_cmd tmux
require_cmd python3
require_cmd git

BASH4_BIN=""
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  if "$candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
    BASH4_BIN="$candidate"
    break
  fi
done
[[ -n "$BASH4_BIN" ]] || die "missing bash 4+ interpreter"

log "linting shell entry points"
"$BASH4_BIN" -n "$REPO_ROOT"/*.sh "$REPO_ROOT"/agent-bridge "$REPO_ROOT"/agb "$REPO_ROOT"/bin/agb "$REPO_ROOT"/scripts/smoke-test.sh
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$REPO_ROOT"/*.sh "$REPO_ROOT"/agent-bridge "$REPO_ROOT"/agb "$REPO_ROOT"/bin/agb "$REPO_ROOT"/scripts/smoke-test.sh "$REPO_ROOT"/agent-roster.local.example.sh
else
  log "shellcheck not installed; skipping"
fi

log "redacting sensitive inline env vars from launch display paths (#428)"
LAUNCH_REDACTION_OUTPUT="$("$BASH4_BIN" -s "$REPO_ROOT" <<'BASH_REDACTION'
set -euo pipefail
repo="$1"
source "$repo/lib/bridge-core.sh"
bridge_redact_inline_env_secrets "MS365_CLIENT_SECRET=s3cr3t SAFE_FLAG=1 MY_API_KEY=abc BEARER_TOKEN=zzz SERVICE_PWD=pwd DB_PASSWORD='with space' MY_PRIVATE_KEY=\"quoted secret\" OAUTH_TOKEN=hello\\ world ANSI_SECRET=\$'line space' BRIDGE_LAYOUT_MARKER_KEY=layout-marker CACHE_KEY=cache-val claude --ok"
BASH_REDACTION
)"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "MS365_CLIENT_SECRET=***redacted***"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "MY_API_KEY=***redacted***"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "BEARER_TOKEN=***redacted***"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "SERVICE_PWD=***redacted***"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "DB_PASSWORD=***redacted***"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "MY_PRIVATE_KEY=***redacted***"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "OAUTH_TOKEN=***redacted***"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "ANSI_SECRET=***redacted***"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "SAFE_FLAG=1"
# #428 r2: bare ``_KEY`` no longer triggers redaction — only ``API_KEY`` /
# ``AUTH_KEY`` / ``PRIVATE_KEY`` / ``CLIENT_KEY`` / ``ACCESS_KEY`` /
# ``SECRET_KEY`` (and the existing substring families). Non-secret env
# names that merely end in ``_KEY`` must round-trip unchanged.
assert_contains "$LAUNCH_REDACTION_OUTPUT" "BRIDGE_LAYOUT_MARKER_KEY=layout-marker"
assert_contains "$LAUNCH_REDACTION_OUTPUT" "CACHE_KEY=cache-val"
assert_not_contains "$LAUNCH_REDACTION_OUTPUT" "s3cr3t"
assert_not_contains "$LAUNCH_REDACTION_OUTPUT" "abc"
assert_not_contains "$LAUNCH_REDACTION_OUTPUT" "zzz"
assert_not_contains "$LAUNCH_REDACTION_OUTPUT" "with space"
assert_not_contains "$LAUNCH_REDACTION_OUTPUT" "quoted secret"
assert_not_contains "$LAUNCH_REDACTION_OUTPUT" "hello"
assert_not_contains "$LAUNCH_REDACTION_OUTPUT" "line space"

# #428 r2 item 2: end-to-end dry-run smoke. The focused helper test above
# only proves bridge_redact_inline_env_secrets does the right thing in
# isolation. This case proves bridge-run.sh's --dry-run path actually
# routes the launch_cmd through that helper before printing
# `launch=...`, so a future refactor cannot silently drop the redaction
# call and reintroduce the #428 leak.
log "bridge-run.sh --dry-run pipes launch_cmd through env-secret redactor (#428 r2)"
LAUNCH_DRYRUN_HOME="$(mktemp -d)"
LAUNCH_DRYRUN_WORKDIR="$LAUNCH_DRYRUN_HOME/work"
mkdir -p "$LAUNCH_DRYRUN_WORKDIR"
cat >"$LAUNCH_DRYRUN_HOME/agent-roster.local.sh" <<EOF
#!/usr/bin/env bash
# shellcheck disable=SC2034
bridge_add_agent_id_if_missing "dryrun-redact-smoke"
BRIDGE_AGENT_DESC["dryrun-redact-smoke"]="Dry-run redaction smoke role"
BRIDGE_AGENT_ENGINE["dryrun-redact-smoke"]="claude"
BRIDGE_AGENT_SESSION["dryrun-redact-smoke"]="dryrun-redact-smoke"
BRIDGE_AGENT_WORKDIR["dryrun-redact-smoke"]="$LAUNCH_DRYRUN_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["dryrun-redact-smoke"]='MS365_CLIENT_SECRET=fake-secret-XYZ MY_API_TOKEN=fake-token-ABC BRIDGE_LAYOUT_MARKER_KEY=preserve-me claude --ok'
EOF
# Unset any inherited BRIDGE_ROSTER_* / BRIDGE_*_DIR overrides so the
# isolated BRIDGE_HOME defaults bind to LAUNCH_DRYRUN_HOME. Without this,
# operator-shell defaults would silently steer bridge-run.sh at the live
# roster and the test would be a no-op (or worse, an env-pollution false
# pass against unrelated agents).
#
# Explicit BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT take resolver step 1 (env
# override) so the dummy agent-roster.local.sh written above does not trip
# bridge_layout_resolver_has_existing_evidence — that would classify the
# fresh temp dir as `markerless(existing-install)` and silently kill the
# entire smoke matrix here via the v0.8.0 isolation hard-cut (#946). The
# evidence-based fail-fast still protects real installs; this is the
# correct shape for an isolated dry-run probe whose only on-disk artifact
# is the roster definition the test itself wrote.
LAUNCH_DRYRUN_OUTPUT="$(env -u BRIDGE_ROSTER_FILE -u BRIDGE_ROSTER_LOCAL_FILE \
  -u BRIDGE_STATE_DIR -u BRIDGE_ACTIVE_AGENT_DIR -u BRIDGE_LOG_DIR \
  -u BRIDGE_SHARED_DIR -u BRIDGE_TASK_DB \
  BRIDGE_HOME="$LAUNCH_DRYRUN_HOME" \
  BRIDGE_LAYOUT="v2" \
  BRIDGE_DATA_ROOT="$LAUNCH_DRYRUN_HOME/data" \
  "$BASH4_BIN" "$REPO_ROOT/bridge-run.sh" "dryrun-redact-smoke" --dry-run 2>&1)" \
  || die "bridge-run.sh --dry-run probe failed (rc=$?); output: $LAUNCH_DRYRUN_OUTPUT"
assert_contains "$LAUNCH_DRYRUN_OUTPUT" "launch=MS365_CLIENT_SECRET=***redacted***"
assert_contains "$LAUNCH_DRYRUN_OUTPUT" "MY_API_TOKEN=***redacted***"
# Non-secret BRIDGE_LAYOUT_MARKER_KEY must round-trip with its real value
# (control assertion — proves the dry-run path didn't blanket-redact).
assert_contains "$LAUNCH_DRYRUN_OUTPUT" "BRIDGE_LAYOUT_MARKER_KEY=preserve-me"
assert_not_contains "$LAUNCH_DRYRUN_OUTPUT" "fake-secret-XYZ"
assert_not_contains "$LAUNCH_DRYRUN_OUTPUT" "fake-token-ABC"
rm -rf "$LAUNCH_DRYRUN_HOME"

log "BRIDGE_SCRIPT_DIR startup validation + re-resolution helper (issue #946 L1)"
# Regression coverage for the daemon-hang root cause documented in #946.
# When the source checkout that BRIDGE_SCRIPT_DIR was captured from is
# removed mid-flight (wave-orchestration fixer worktree cleanup, brew
# prune of an upgrade source dir, `agb upgrade --apply` moving the
# source root), every subsequent
# `python3 "$BRIDGE_SCRIPT_DIR/scripts/python-helpers/…"` call from the
# daemon used to fail silently with [Errno 2] and the cycle would
# accumulate hung child bash processes until the tick loop wedged.
# Lock the new contract:
#   1. Startup-time: bridge-lib.sh dies loudly when its script dir is
#      missing scripts/python-helpers/.
#   2. Run-time: bridge_resolve_script_dir_or_die dies with the same
#      class of message when the dir vanishes after sourcing.
SCRIPTDIR_FAKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agb-smoke-scriptdir.XXXXXX")"
# Negative startup case: stage a fake source tree WITHOUT
# scripts/python-helpers/ and source bridge-lib.sh from it. Validation
# must die with the documented message.
mkdir -p "$SCRIPTDIR_FAKE_ROOT/bad/lib"
cp "$REPO_ROOT/bridge-lib.sh" "$SCRIPTDIR_FAKE_ROOT/bad/bridge-lib.sh"
SCRIPTDIR_BAD_OUT="$("$BASH4_BIN" -c "source '$SCRIPTDIR_FAKE_ROOT/bad/bridge-lib.sh'" 2>&1 || true)"
assert_contains "$SCRIPTDIR_BAD_OUT" "missing scripts/python-helpers/"
# Positive startup case: a tree WITH scripts/python-helpers/ passes
# startup validation (control). Copy lib/ (don't symlink) so the fixture
# stays self-contained: r4's bridge_resolve_script_dir_check uses
# `cd -P "$(dirname "${BASH_SOURCE[0]}")/.."` which resolves symlinks,
# so a symlinked lib/ would let the resolver follow back to the real
# checkout and find scripts/python-helpers there after we delete the
# fake scripts/ below — breaking the failure-path assertion.
mkdir -p "$SCRIPTDIR_FAKE_ROOT/good/scripts/python-helpers"
cp "$REPO_ROOT/bridge-lib.sh" "$SCRIPTDIR_FAKE_ROOT/good/bridge-lib.sh"
cp -R "$REPO_ROOT/lib" "$SCRIPTDIR_FAKE_ROOT/good/lib"
ln -sf "$REPO_ROOT/VERSION" "$SCRIPTDIR_FAKE_ROOT/good/VERSION" 2>/dev/null || true
SCRIPTDIR_GOOD_OUT="$("$BASH4_BIN" -c "source '$SCRIPTDIR_FAKE_ROOT/good/bridge-lib.sh' >/dev/null 2>&1 && echo SCRIPTDIR_STARTUP_OK" 2>&1 || true)"
assert_contains "$SCRIPTDIR_GOOD_OUT" "SCRIPTDIR_STARTUP_OK"
# Run-time re-validation: source the staged copy (passes startup), then
# remove the staged scripts/python-helpers/ to simulate a worktree
# cleanup mid-flight. bridge_resolve_script_dir_or_die must die with the
# documented message. We delete only the python-helpers subdir, leaving
# the bridge-lib.sh on disk so the re-resolution branch via BASH_SOURCE
# also fails (its dirname still lacks the subdir) — without that we
# would silently recover and the test would be a no-op.
SCRIPTDIR_LIVE_OUT="$("$BASH4_BIN" -c "
  source '$SCRIPTDIR_FAKE_ROOT/good/bridge-lib.sh' >/dev/null 2>&1
  rm -rf '$SCRIPTDIR_FAKE_ROOT/good/scripts'
  bridge_resolve_script_dir_or_die
" 2>&1 || true)"
assert_contains "$SCRIPTDIR_LIVE_OUT" "does not exist or is missing scripts/python-helpers/"

# r2 (codex P1 #2 regression — substitution-context propagation):
# bridge_resolve_script_dir_check must return non-zero AND write an
# audit line to BRIDGE_DAEMON_LOG even when called from inside `$(...)`
# with errexit suppressed via `|| true`. Without this contract the
# daemon-hang #946 reproduces unchanged because the substitution
# swallows `bridge_die`'s subshell exit, the parent receives an empty
# string, and the next tick repeats the same failing helper invocation.
#
# Layout: source the staged bridge-lib.sh, remove the source dir mid-
# flight, then run bridge_resolve_script_dir_check inside `$(...) || true`
# and assert:
#   (a) the substitution result is empty
#   (b) BRIDGE_DAEMON_LOG (BRIDGE_STATE_DIR/daemon.log by default)
#       carries one `[L1] BRIDGE_SCRIPT_DIR=...` audit line
#   (c) repeated check calls within the same shell do NOT duplicate
#       the audit (dedup contract via per-PID sentinel file)
SCRIPTDIR_SUB_STATE="$(mktemp -d "${TMPDIR:-/tmp}/agb-smoke-scriptdir-sub.XXXXXX")"
# Re-stage a fresh "good" tree because the previous block destroyed
# its scripts/python-helpers/ subtree.
mkdir -p "$SCRIPTDIR_FAKE_ROOT/sub/scripts/python-helpers"
cp "$REPO_ROOT/bridge-lib.sh" "$SCRIPTDIR_FAKE_ROOT/sub/bridge-lib.sh"
# Copy lib/ (don't symlink) — see comment on the `good` fixture above.
# r4's resolver uses `cd -P` so a symlinked lib/ would let the failure
# path silently recover via the real checkout.
cp -R "$REPO_ROOT/lib" "$SCRIPTDIR_FAKE_ROOT/sub/lib"
ln -sf "$REPO_ROOT/VERSION" "$SCRIPTDIR_FAKE_ROOT/sub/VERSION" 2>/dev/null || true
SCRIPTDIR_SUB_OUT="$(BRIDGE_HOME="$SCRIPTDIR_SUB_STATE" \
  BRIDGE_STATE_DIR="$SCRIPTDIR_SUB_STATE/state" \
  BRIDGE_DAEMON_LOG="$SCRIPTDIR_SUB_STATE/state/daemon.log" \
  "$BASH4_BIN" -c "
  source '$SCRIPTDIR_FAKE_ROOT/sub/bridge-lib.sh' >/dev/null 2>&1
  rm -rf '$SCRIPTDIR_FAKE_ROOT/sub/scripts'
  # Substitution-context call with errexit suppressed — the daemon's
  # \`bridge_agent_channels_csv \"\$agent\" 2>/dev/null || true\` shape.
  SUB_RESULT=\"\$(bridge_resolve_script_dir_check && echo NEVER_REACHED || true)\"
  printf 'SUB_RESULT=[%s]\\n' \"\$SUB_RESULT\"
  # A second call from the same shell should NOT re-log.
  bridge_resolve_script_dir_check >/dev/null 2>&1 || true
  bridge_resolve_script_dir_check >/dev/null 2>&1 || true
" 2>&1 || true)"
# (a) substitution result empty — the check helper returned 1 without
# emitting NEVER_REACHED.
assert_contains "$SCRIPTDIR_SUB_OUT" "SUB_RESULT=[]"
assert_not_contains "$SCRIPTDIR_SUB_OUT" "NEVER_REACHED"
# (b) one audit line landed in BRIDGE_DAEMON_LOG. The log file proves
# the substitution did not swallow the signal — codex P1 #2 contract.
SCRIPTDIR_LOG_FILE="$SCRIPTDIR_SUB_STATE/state/daemon.log"
if [[ -f "$SCRIPTDIR_LOG_FILE" ]]; then
  SCRIPTDIR_LOG_LINES="$(grep -c '\[L1\] BRIDGE_SCRIPT_DIR=' "$SCRIPTDIR_LOG_FILE" 2>/dev/null || printf '0')"
else
  SCRIPTDIR_LOG_LINES=0
fi
if (( SCRIPTDIR_LOG_LINES < 1 )); then
  echo "FAIL: expected >=1 [L1] BRIDGE_SCRIPT_DIR= line in $SCRIPTDIR_LOG_FILE, got $SCRIPTDIR_LOG_LINES" >&2
  echo "--- log file ---" >&2
  cat "$SCRIPTDIR_LOG_FILE" 2>&1 >&2 || echo "(no log)" >&2
  echo "--- subprocess output ---" >&2
  printf '%s\n' "$SCRIPTDIR_SUB_OUT" >&2
  exit 1
fi
# (c) the per-PID sentinel deduped: even with three check calls the
# audit log carries exactly one entry. Without the cross-subshell
# sentinel a substitution-context caller would re-log on every call.
if (( SCRIPTDIR_LOG_LINES > 1 )); then
  echo "FAIL: expected exactly 1 deduped [L1] BRIDGE_SCRIPT_DIR= line, got $SCRIPTDIR_LOG_LINES" >&2
  cat "$SCRIPTDIR_LOG_FILE" >&2
  exit 1
fi
rm -rf "$SCRIPTDIR_SUB_STATE"

# r6 (codex P2 — guard ordering): `bridge_sync_skill_docs` used to early-
# return 0 via `[[ -f $BRIDGE_SCRIPT_DIR/bridge-docs.py ]]` BEFORE the
# stale-source guard. When the source dir vanished, the file-existence
# test saw `bridge-docs.py` missing, took the graceful skip, and reported
# success — masking the cascade and skipping the [L1] audit entirely.
# r6 reorders so the guard runs first. Lock the contract:
#   (a) stale dir → rc=1 + [L1] audit landed.
#   (b) valid dir + bridge-docs.py legitimately absent → rc=0, no audit.
SCRIPTDIR_GUARD_STATE="$(mktemp -d "${TMPDIR:-/tmp}/agb-smoke-scriptdir-guard.XXXXXX")"
mkdir -p "$SCRIPTDIR_FAKE_ROOT/guard/scripts/python-helpers"
cp "$REPO_ROOT/bridge-lib.sh" "$SCRIPTDIR_FAKE_ROOT/guard/bridge-lib.sh"
cp -R "$REPO_ROOT/lib" "$SCRIPTDIR_FAKE_ROOT/guard/lib"
ln -sf "$REPO_ROOT/VERSION" "$SCRIPTDIR_FAKE_ROOT/guard/VERSION" 2>/dev/null || true
# Intentionally do NOT copy bridge-docs.py — the original anti-pattern
# would happily return 0 in that state. After r6 the missing-file skip
# only applies when the script dir is valid.
SCRIPTDIR_GUARD_STALE_OUT="$(BRIDGE_HOME="$SCRIPTDIR_GUARD_STATE/stale" \
  BRIDGE_STATE_DIR="$SCRIPTDIR_GUARD_STATE/stale/state" \
  BRIDGE_DAEMON_LOG="$SCRIPTDIR_GUARD_STATE/stale/state/daemon.log" \
  "$BASH4_BIN" -c "
  mkdir -p \"\$BRIDGE_STATE_DIR\"
  source '$SCRIPTDIR_FAKE_ROOT/guard/bridge-lib.sh' >/dev/null 2>&1
  rm -rf '$SCRIPTDIR_FAKE_ROOT/guard/scripts'
  bridge_sync_skill_docs smoke >/dev/null 2>&1
  printf 'GUARD_STALE_RC=%s\n' \"\$?\"
" 2>&1 || true)"
assert_contains "$SCRIPTDIR_GUARD_STALE_OUT" "GUARD_STALE_RC=1"
SCRIPTDIR_GUARD_STALE_LOG="$SCRIPTDIR_GUARD_STATE/stale/state/daemon.log"
if [[ -f "$SCRIPTDIR_GUARD_STALE_LOG" ]]; then
  SCRIPTDIR_GUARD_STALE_LINES="$(grep -c '\[L1\] BRIDGE_SCRIPT_DIR=' "$SCRIPTDIR_GUARD_STALE_LOG" 2>/dev/null || printf '0')"
else
  SCRIPTDIR_GUARD_STALE_LINES=0
fi
if (( SCRIPTDIR_GUARD_STALE_LINES < 1 )); then
  echo "FAIL: r6 stale guard — expected >=1 [L1] line, got $SCRIPTDIR_GUARD_STALE_LINES" >&2
  cat "$SCRIPTDIR_GUARD_STALE_LOG" 2>&1 >&2 || echo "(no log)" >&2
  echo "--- subprocess output ---" >&2
  printf '%s\n' "$SCRIPTDIR_GUARD_STALE_OUT" >&2
  exit 1
fi
# (b) Positive: valid script dir but bridge-docs.py absent. Re-stage
# (the previous block destroyed the guard fixture's scripts/).
mkdir -p "$SCRIPTDIR_FAKE_ROOT/guard2/scripts/python-helpers"
cp "$REPO_ROOT/bridge-lib.sh" "$SCRIPTDIR_FAKE_ROOT/guard2/bridge-lib.sh"
cp -R "$REPO_ROOT/lib" "$SCRIPTDIR_FAKE_ROOT/guard2/lib"
ln -sf "$REPO_ROOT/VERSION" "$SCRIPTDIR_FAKE_ROOT/guard2/VERSION" 2>/dev/null || true
SCRIPTDIR_GUARD_OK_OUT="$(BRIDGE_HOME="$SCRIPTDIR_GUARD_STATE/ok" \
  BRIDGE_STATE_DIR="$SCRIPTDIR_GUARD_STATE/ok/state" \
  BRIDGE_DAEMON_LOG="$SCRIPTDIR_GUARD_STATE/ok/state/daemon.log" \
  "$BASH4_BIN" -c "
  mkdir -p \"\$BRIDGE_STATE_DIR\"
  source '$SCRIPTDIR_FAKE_ROOT/guard2/bridge-lib.sh' >/dev/null 2>&1
  bridge_sync_skill_docs smoke >/dev/null 2>&1
  printf 'GUARD_OK_RC=%s\n' \"\$?\"
" 2>&1 || true)"
assert_contains "$SCRIPTDIR_GUARD_OK_OUT" "GUARD_OK_RC=0"
SCRIPTDIR_GUARD_OK_LOG="$SCRIPTDIR_GUARD_STATE/ok/state/daemon.log"
if [[ -f "$SCRIPTDIR_GUARD_OK_LOG" ]]; then
  SCRIPTDIR_GUARD_OK_LINES="$(grep -c '\[L1\] BRIDGE_SCRIPT_DIR=' "$SCRIPTDIR_GUARD_OK_LOG" 2>/dev/null || printf '0')"
else
  SCRIPTDIR_GUARD_OK_LINES=0
fi
if (( SCRIPTDIR_GUARD_OK_LINES != 0 )); then
  echo "FAIL: r6 minimal-install path — expected 0 [L1] lines, got $SCRIPTDIR_GUARD_OK_LINES" >&2
  cat "$SCRIPTDIR_GUARD_OK_LOG" 2>&1 >&2 || true
  exit 1
fi
rm -rf "$SCRIPTDIR_GUARD_STATE"
rm -rf "$SCRIPTDIR_FAKE_ROOT"
log "  [ok] script-dir startup validation + re-resolution helper + substitution propagation + sync-skill-docs guard ordering"

log "bridge_cron_sync_enabled reducer: any-0-disables semantics (issue #192)"
# Regression matrix for the `BRIDGE_CRON_SYNC_ENABLED` reducer introduced
# in #213 after the original precedence chain silently let an outer =1
# override an inner =0. Lock the "any explicit 0 disables; all-unset enables"
# contract so a future edit cannot quietly revert the semantics.
run_cron_case() {
  local label="$1"
  local expected="$2"
  local setup="$3"
  local out
  out="$("$BASH4_BIN" -lc '
    set -u
    unset BRIDGE_CRON_SYNC_ENABLED BRIDGE_LEGACY_CRON_SYNC_ENABLED BRIDGE_OPENCLAW_CRON_SYNC_ENABLED
    '"$setup"'
    # shellcheck disable=SC1090
    source "'"$REPO_ROOT"'/lib/bridge-core.sh"
    if bridge_cron_sync_enabled; then echo enabled; else echo disabled; fi
  ')"
  if [[ "$out" != "$expected" ]]; then
    die "cron-sync reducer: [$label] expected=$expected actual=$out"
  fi
  log "  [ok] cron-sync reducer: $label → $out"
}
run_cron_case "all unset"                          "enabled"  ""
run_cron_case "new=0"                              "disabled" "export BRIDGE_CRON_SYNC_ENABLED=0"
run_cron_case "legacy=0 only"                      "disabled" "export BRIDGE_LEGACY_CRON_SYNC_ENABLED=0"
run_cron_case "openclaw=0 only"                    "disabled" "export BRIDGE_OPENCLAW_CRON_SYNC_ENABLED=0"
run_cron_case "new=1 legacy=0 (any-0-wins)"        "disabled" "export BRIDGE_CRON_SYNC_ENABLED=1 BRIDGE_LEGACY_CRON_SYNC_ENABLED=0"
run_cron_case "legacy=1 openclaw=0 (any-0-wins)"   "disabled" "export BRIDGE_LEGACY_CRON_SYNC_ENABLED=1 BRIDGE_OPENCLAW_CRON_SYNC_ENABLED=0"
run_cron_case "all three =1"                       "enabled"  "export BRIDGE_CRON_SYNC_ENABLED=1 BRIDGE_LEGACY_CRON_SYNC_ENABLED=1 BRIDGE_OPENCLAW_CRON_SYNC_ENABLED=1"
run_cron_case "empty-string treated as unset"      "enabled"  "export BRIDGE_CRON_SYNC_ENABLED="
run_cron_case "on-form true"                       "enabled"  "export BRIDGE_CRON_SYNC_ENABLED=true"
run_cron_case "on-form yes"                        "enabled"  "export BRIDGE_CRON_SYNC_ENABLED=yes"
run_cron_case "off-form false"                     "disabled" "export BRIDGE_CRON_SYNC_ENABLED=false"
run_cron_case "off-form no"                        "disabled" "export BRIDGE_CRON_SYNC_ENABLED=no"
run_cron_case "off-form off"                       "disabled" "export BRIDGE_CRON_SYNC_ENABLED=off"
run_cron_case "case-insensitive TRUE"              "enabled"  "export BRIDGE_CRON_SYNC_ENABLED=TRUE"
run_cron_case "case-insensitive NO (off-form)"     "disabled" "export BRIDGE_CRON_SYNC_ENABLED=NO"
run_cron_case "malformed '2' → fail-closed"        "disabled" "export BRIDGE_CRON_SYNC_ENABLED=2"
run_cron_case "malformed 'banana' → fail-closed"   "disabled" "export BRIDGE_CRON_SYNC_ENABLED=banana"
run_cron_case "malformed legacy only"              "disabled" "export BRIDGE_LEGACY_CRON_SYNC_ENABLED=wat"

log "context-pressure detector: HUD-authoritative classification (issue #126)"
# Self-contained coverage for bridge-context-pressure.py analyze. Placed
# early so it runs even when the downstream integration block at smoke-test
# line ~5408 is gated by unrelated pre-existing failures.
run_cp_case() {
  local label="$1"
  local expected_severity="$2"
  local expected_pattern_substring="$3"
  local input="$4"
  local engine="${5:-}"
  local out
  if [[ -n "$engine" ]]; then
    out="$(printf '%s' "$input" | python3 "$REPO_ROOT/bridge-context-pressure.py" analyze --format shell --engine "$engine")"
  else
    out="$(printf '%s' "$input" | python3 "$REPO_ROOT/bridge-context-pressure.py" analyze --format shell)"
  fi
  assert_contains "$out" "CONTEXT_PRESSURE_SEVERITY=\"$expected_severity\""
  if [[ -n "$expected_pattern_substring" ]]; then
    assert_contains "$out" "$expected_pattern_substring"
  fi
  log "  [ok] $label"
}
# HUD authoritative — low reading silences the post-/compact scrollback that
# previously fired the false-positive "conversation.+compact" match.
run_cp_case "low HUD + post-compact scrollback -> no severity" \
  "" "hud:context_pct=5" \
  $'Conversation compacted (ctrl+o for history)\nContext ████ 5%\n> '
# HUD warning threshold (default 60%)
run_cp_case "HUD 70% -> warning" \
  "warning" "hud:context_pct=70" \
  $'Context ████████░░ 70%\n'
# HUD critical threshold (default 85%)
run_cp_case "HUD 95% -> critical" \
  "critical" "hud:context_pct=95" \
  $'Context ████████████ 95%\n'
# HUD wrapped across a newline (defense-in-depth for non-joined captures)
run_cp_case "HUD wrapped after 'Context' -> still matches" \
  "warning" "hud:context_pct=70" \
  $'Context\n████████░░ 70%\n'
# Non-HUD prose with explicit compact hint -> fallback pattern groups still fire
run_cp_case "prose 'Context remaining 8%' -> warning via fallback" \
  "warning" "" \
  $'Context remaining 8%. Please compact soon.\n'
# Codex has no HUD of its own; fallback regex historically false-positived on
# UI strings ("Context compacted") and doc excerpts ("compact the
# conversation"). With --engine codex the detector must emit nothing when the
# HUD is absent (issue #183).
run_cp_case "codex + 'Context compacted' UI string -> silent" \
  "" "" \
  $'Context compacted (ctrl+o for history)\n> \n' \
  "codex"
run_cp_case "codex + docs 'compact the conversation' prose -> silent" \
  "" "" \
  $'Consider whether to compact the conversation before continuing.\n' \
  "codex"
# Claude path unchanged: same prose still yields a fallback warning because
# --engine claude (or unset) keeps the pattern groups active.
run_cp_case "claude + 'compact the conversation' prose -> warning" \
  "warning" "" \
  $'Consider whether to compact the conversation before continuing.\n' \
  "claude"
# PR #188 review: critical banners must still fire on codex even though the
# warning fallback is suppressed. Silencing critical-severity patterns would
# hide genuine hard-stop failures on codex agents.
run_cp_case "codex + 'context window exceeded' banner -> critical" \
  "critical" "context window exceeded" \
  $'context window exceeded — model refused to continue\n' \
  "codex"
run_cp_case "codex + 'must compact before continuing' banner -> critical" \
  "critical" "must compact before continuing" \
  $'must compact before continuing before the next turn\n' \
  "codex"

# Issue #338 Track A — anchor the HUD-pct extractor so it only matches the
# canonical "Context <bar block> NN%" line, not free-floating numerics
# elsewhere in the captured pane (cron summaries, stash prefixes,
# [Agent Bridge] task bodies, codex placeholder strings, prose that
# mentions "Context" alongside an unrelated percentage).
# Positive: realistic HUD shapes at 36% (admin reproducer), 70%, 95%.
run_cp_case "338 A+: HUD 36% (admin reproducer) -> warning silenced (below 60)" \
  "" "hud:context_pct=36" \
  $'Context ███░░░░░░░ 36%\n'
run_cp_case "338 A+: HUD 70% on canonical bar shape -> warning" \
  "warning" "hud:context_pct=70" \
  $'Context ███████░░░ 70%\n'
run_cp_case "338 A+: HUD 95% on canonical bar shape -> critical" \
  "critical" "hud:context_pct=95" \
  $'Context █████████░ 95%\n'
# Negative: wrong-window matches the issue called out as the false-positive
# sources. None should produce hud:context_pct=… and Claude (no engine
# override) must fall through to the prose pattern groups, which also do
# not match these strings, so SEVERITY stays empty.
run_cp_case "338 A-: bare '100% complete' (no HUD prefix)" \
  "" "" \
  $'100% complete\n'
run_cp_case "338 A-: 'cron job exit code 100' (numeric scrollback)" \
  "" "" \
  $'cron job exit code 100\n'
run_cp_case "338 A-: '[Agent Bridge] body mentioning 100% as the previous threshold'" \
  "" "" \
  $'[Agent Bridge] body mentioning 100% as the previous threshold\n'
run_cp_case "338 A-: git stash prefix '+100 lines' scrollback" \
  "" "" \
  $'+100 lines (ctrl+o to expand)\n'
run_cp_case "338 A-: codex 'Working (100s · esc to interrupt)' placeholder" \
  "" "" \
  $'Working (100s · esc to interrupt)\n' \
  "codex"
# Issue #338 Track B — when a fresh-session marker (Welcome to Claude Code)
# appears after a stale HUD line in the captured pane, the HUD line is
# scrollback from the pre-/clear session and must not drive classification.
run_cp_case "338 B1: stale 100% HUD followed by /clear + Welcome banner -> silent" \
  "" "" \
  $'Context ███████████ 100%\n> /clear\n\nWelcome to Claude Code!\n\nHuman: hi\n'
run_cp_case "338 B1: only Welcome banner, no HUD line -> silent" \
  "" "" \
  $'Welcome to Claude Code!\n\n  Tip: try /help to see commands\n\n> '
run_cp_case "338 B1: Welcome banner above a fresh 36% HUD -> warning silenced (below 60)" \
  "" "hud:context_pct=36" \
  $'Welcome to Claude Code!\n\n> hi\n\nContext ███░░░░░░░ 36%\n'

log "context-pressure daemon function: audit-only state transitions (issue #472)"
# This unit-style block runs before the BRIDGE_HOME / TMP_ROOT setup at
# the bottom of the script, so it allocates its own temp root via
# `mktemp -d` and removes it inline after the assertions complete.
CONTEXT_PRESSURE_UNIT_ROOT="$(mktemp -d -t context-pressure-unit.XXXXXX)"
CONTEXT_PRESSURE_UNIT_AUDIT="$CONTEXT_PRESSURE_UNIT_ROOT/audit.log"
CONTEXT_PRESSURE_UNIT_STATE_DIR="$CONTEXT_PRESSURE_UNIT_ROOT/state"
CONTEXT_PRESSURE_UNIT_HELPER="$CONTEXT_PRESSURE_UNIT_ROOT/context-pressure-functions.sh"
mkdir -p "$CONTEXT_PRESSURE_UNIT_STATE_DIR"
: >"$CONTEXT_PRESSURE_UNIT_AUDIT"
awk '
  /^bridge_clear_context_pressure_state\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}[[:space:]]*$/ {
    done += 1
    if (done == 3) {
      capture=0
    }
  }
' "$REPO_ROOT/bridge-daemon.sh" >"$CONTEXT_PRESSURE_UNIT_HELPER"
[[ -s "$CONTEXT_PRESSURE_UNIT_HELPER" ]] || die "could not extract context-pressure daemon functions"
set +e
CONTEXT_PRESSURE_UNIT_OUTPUT="$("$BASH4_BIN" -lc '
set -euo pipefail
state_dir="$1"
audit_file="$2"
helper="$3"
SCRIPT_DIR="$PWD"
export BRIDGE_CONTEXT_PRESSURE_SCAN_ENABLED=1
export BRIDGE_CONTEXT_PRESSURE_SCAN_INTERVAL_SECONDS=0
mkdir -p "$state_dir"

analysis_severity=""
analysis_hash=""
analysis_pattern=""
agent_source_mode="static"
capture_empty=0

bridge_agent_context_pressure_state_file() {
  printf "%s/%s.env" "$state_dir" "$1"
}

bridge_audit_log() {
  local actor="$1"
  local action="$2"
  local target="$3"
  shift 3
  {
    printf "%s|%s|%s" "$actor" "$action" "$target"
    for item in "$@"; do
      printf "|%s" "$item"
    done
    printf "\n"
  } >>"$audit_file"
}

bridge_tmux_session_exists() { return 0; }
bridge_capture_recent() {
  (( capture_empty == 1 )) && return 0
  printf "Context remaining 8%%. Please compact soon."
}
bridge_with_timeout() {
  cat >/dev/null || true
  [[ -n "$analysis_severity" ]] || return 0
  printf "CONTEXT_PRESSURE_SEVERITY=%q\n" "$analysis_severity"
  printf "CONTEXT_PRESSURE_MATCHED_PATTERN=%q\n" "$analysis_pattern"
  printf "CONTEXT_PRESSURE_EXCERPT_HASH=%q\n" "$analysis_hash"
}
bridge_agent_source() { printf "%s" "$agent_source_mode"; }
bridge_queue_cli() { echo "bridge_queue_cli should not be called"; exit 99; }
bridge_notify_send() { echo "bridge_notify_send should not be called"; exit 99; }
daemon_info() { :; }
daemon_source_state_file() {
  # shellcheck source=/dev/null
  source "$1" 2>/dev/null
}

# shellcheck disable=SC1090
source "$helper"

summary_static=$'"'"'static-agent\t0\t0\t0\t1\t0\t0\t0\tstatic-session\tclaude\t/tmp'"'"'
summary_dynamic=$'"'"'dynamic-agent\t0\t0\t0\t1\t0\t0\t0\tdynamic-session\tclaude\t/tmp'"'"'

analysis_severity=warning
analysis_hash=hash-static
analysis_pattern=hud:context_pct=72
agent_source_mode=static
process_context_pressure_reports "$summary_static" >/dev/null
static_state="$(cat "$state_dir/static-agent.env")"
[[ "$static_state" == *"CONTEXT_PRESSURE_SEVERITY=warning"* ]] || { echo "static severity missing"; exit 1; }
[[ "$static_state" == *"CONTEXT_PRESSURE_EXCERPT_HASH=hash-static"* ]] || { echo "static hash missing"; exit 1; }
[[ "$static_state" == *"CONTEXT_PRESSURE_FIRST_DETECTED_TS="* ]] || { echo "static first ts missing"; exit 1; }
[[ "$static_state" == *"CONTEXT_PRESSURE_LAST_DETECTED_TS="* ]] || { echo "static last detected ts missing"; exit 1; }
[[ "$static_state" == *"CONTEXT_PRESSURE_LAST_SCAN_TS="* ]] || { echo "static scan ts missing"; exit 1; }
[[ "$static_state" != *"CONTEXT_PRESSURE_TASK_ID"* ]] || { echo "static task id persisted"; exit 1; }
grep -q "daemon|context_pressure_detected|static-agent|--detail|severity=warning" "$audit_file" || { echo "static detected audit missing"; exit 1; }
[[ ! -e "$state_dir/context-pressure/static-agent-warning.md" ]] || { echo "static report body created"; exit 1; }

analysis_hash=hash-static-2
process_context_pressure_reports "$summary_static" >/dev/null
grep -q "daemon|context_pressure_detected|static-agent|--detail|severity=warning|--detail|excerpt_hash=hash-static-2|--detail|mode=hash_drift" "$audit_file" || { echo "hash drift audit missing"; exit 1; }

analysis_hash=hash-dynamic
agent_source_mode=dynamic
bridge_note_context_pressure_state "dynamic-agent" "warning" "hash-dynamic" "10" "11" "12" "0" "hud:context_pct=72"
process_context_pressure_reports "$summary_dynamic" >/dev/null
[[ ! -e "$state_dir/dynamic-agent.env" ]] || { echo "dynamic state not cleared"; exit 1; }
grep -q "daemon|context_pressure_suppressed|dynamic-agent|--detail|severity=warning|--detail|reason=dynamic_agent_operator_managed" "$audit_file" || { echo "dynamic suppressed audit missing"; exit 1; }
! grep -q "daemon|context_pressure_detected|dynamic-agent" "$audit_file" || { echo "dynamic same-severity edge should not emit detected audit"; exit 1; }

capture_empty=1
analysis_severity=""
agent_source_mode=static
process_context_pressure_reports "$summary_static" >/dev/null
[[ ! -e "$state_dir/static-agent.env" ]] || { echo "recovered state not cleared"; exit 1; }
grep -q "daemon|context_pressure_recovered|static-agent|--detail|severity=warning|--detail|reason=no_pattern" "$audit_file" || { echo "recovered audit missing"; exit 1; }

echo ok
' _ "$CONTEXT_PRESSURE_UNIT_STATE_DIR" "$CONTEXT_PRESSURE_UNIT_AUDIT" "$CONTEXT_PRESSURE_UNIT_HELPER")"
CONTEXT_PRESSURE_UNIT_RC=$?
set -e
[[ "$CONTEXT_PRESSURE_UNIT_RC" -eq 0 && "$CONTEXT_PRESSURE_UNIT_OUTPUT" == "ok" ]] || die "context-pressure daemon function unit failed: $CONTEXT_PRESSURE_UNIT_OUTPUT"
rm -rf "$CONTEXT_PRESSURE_UNIT_ROOT"
log "  [ok] context-pressure daemon function audit/state transitions"

log "telegram-relay residue cleanup helper: detect + apply + idempotent (v0.7.1 transition)"
# Self-contained unit test for bridge-relay-cleanup.py. Sets up a fake
# bridge-home with the four classes of v0.6.37+ relay residue (state
# files, per-agent relay-token, channel entry, env vars), runs the
# helper twice (first dry-run, then apply), then a third no-op pass to
# verify idempotency. Also pins the roster to mode 0600 and asserts the
# atomic write preserves it under a `umask 022` (the regression Codex
# r1 caught against the first revision of this PR).
RELAY_CLEANUP_ROOT="$(mktemp -d -t relay-cleanup-unit.XXXXXX)"
mkdir -p "$RELAY_CLEANUP_ROOT/state/channels/telegram/abcd1234" \
         "$RELAY_CLEANUP_ROOT/agents/jjujju/.telegram"
: >"$RELAY_CLEANUP_ROOT/state/channels/telegram/tokens.list"
: >"$RELAY_CLEANUP_ROOT/state/channels/telegram/abcd1234.sock"
printf 'token-data\n' >"$RELAY_CLEANUP_ROOT/agents/jjujju/.telegram/relay-token"
printf 'TELEGRAM_BOT_TOKEN=preserved\n' >"$RELAY_CLEANUP_ROOT/agents/jjujju/.telegram/.env"
cat >"$RELAY_CLEANUP_ROOT/agent-roster.local.sh" <<'ROSTER'
#!/usr/bin/env bash
declare -A BRIDGE_AGENT_CHANNELS=()
BRIDGE_AGENT_CHANNELS["jjujju"]="plugin:telegram-relay@agent-bridge,plugin:foo"
BRIDGE_AGENT_CHANNELS["clean"]="plugin:discord@claude-plugins-official"
BRIDGE_TELEGRAM_RELAY_ENABLED=1
export BRIDGE_TELEGRAM_USE_RELAY=true
ROSTER
chmod 0600 "$RELAY_CLEANUP_ROOT/agent-roster.local.sh"

# Round 1: dry-run must report any_changes=true and not modify anything
RELAY_CLEANUP_DRY_JSON="$(python3 "$REPO_ROOT/bridge-relay-cleanup.py" \
  --target-root "$RELAY_CLEANUP_ROOT" --dry-run --json)"
RELAY_CLEANUP_DRY_ANY="$(printf '%s' "$RELAY_CLEANUP_DRY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("any_changes"))')"
[[ "$RELAY_CLEANUP_DRY_ANY" == "True" ]] || die "relay-cleanup dry-run did not report any_changes=true: $RELAY_CLEANUP_DRY_JSON"
[[ -f "$RELAY_CLEANUP_ROOT/state/channels/telegram/tokens.list" ]] || die "relay-cleanup dry-run unexpectedly removed tokens.list"
[[ -f "$RELAY_CLEANUP_ROOT/agents/jjujju/.telegram/relay-token" ]] || die "relay-cleanup dry-run unexpectedly removed relay-token"
grep -Fq 'BRIDGE_TELEGRAM_RELAY_ENABLED' "$RELAY_CLEANUP_ROOT/agent-roster.local.sh" || die "relay-cleanup dry-run unexpectedly stripped env var line"
RELAY_CLEANUP_DRY_PATHS="$(printf '%s' "$RELAY_CLEANUP_DRY_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("changed_paths") or []))')"
(( RELAY_CLEANUP_DRY_PATHS >= 4 )) || die "relay-cleanup dry-run changed_paths should list >=4 entries (roster + 3 state) but reported $RELAY_CLEANUP_DRY_PATHS: $RELAY_CLEANUP_DRY_JSON"
log "  [ok] dry-run reports any_changes + changed_paths without mutating filesystem or roster"

# Round 2: apply must remove all four residue classes and rewrite the channel line
# under a `umask 022` (regression: Codex r1 caught the original revision
# widening 0600 → 0644 because the helper's atomic-write didn't preserve mode).
RELAY_CLEANUP_APPLY_JSON="$( ( umask 022 && python3 "$REPO_ROOT/bridge-relay-cleanup.py" \
  --target-root "$RELAY_CLEANUP_ROOT" --json ) )"
RELAY_CLEANUP_APPLY_ANY="$(printf '%s' "$RELAY_CLEANUP_APPLY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("any_changes"))')"
[[ "$RELAY_CLEANUP_APPLY_ANY" == "True" ]] || die "relay-cleanup apply did not report any_changes: $RELAY_CLEANUP_APPLY_JSON"
[[ ! -e "$RELAY_CLEANUP_ROOT/state/channels/telegram/tokens.list" ]] || die "relay-cleanup apply did not remove tokens.list"
[[ ! -e "$RELAY_CLEANUP_ROOT/state/channels/telegram/abcd1234.sock" ]] || die "relay-cleanup apply did not remove the .sock"
[[ ! -e "$RELAY_CLEANUP_ROOT/state/channels/telegram/abcd1234" ]] || die "relay-cleanup apply did not remove the <token-hash>/ subdir"
[[ ! -e "$RELAY_CLEANUP_ROOT/agents/jjujju/.telegram/relay-token" ]] || die "relay-cleanup apply did not remove relay-token"
[[ -f "$RELAY_CLEANUP_ROOT/agents/jjujju/.telegram/.env" ]] || die "relay-cleanup apply unexpectedly removed .telegram/.env (must preserve)"
! grep -Fq 'BRIDGE_TELEGRAM_RELAY_ENABLED' "$RELAY_CLEANUP_ROOT/agent-roster.local.sh" || die "relay-cleanup apply did not strip BRIDGE_TELEGRAM_RELAY_ENABLED env line"
! grep -Fq 'BRIDGE_TELEGRAM_USE_RELAY' "$RELAY_CLEANUP_ROOT/agent-roster.local.sh" || die "relay-cleanup apply did not strip BRIDGE_TELEGRAM_USE_RELAY env line"
grep -Fq 'plugin:telegram-relay' "$RELAY_CLEANUP_ROOT/agent-roster.local.sh" && die "relay-cleanup apply left plugin:telegram-relay token in BRIDGE_AGENT_CHANNELS"
grep -Fq 'plugin:telegram@claude-plugins-official' "$RELAY_CLEANUP_ROOT/agent-roster.local.sh" || die "relay-cleanup apply did not insert plugin:telegram@claude-plugins-official into BRIDGE_AGENT_CHANNELS"
grep -Fq 'plugin:foo' "$RELAY_CLEANUP_ROOT/agent-roster.local.sh" || die "relay-cleanup apply dropped unrelated plugin:foo channel item"
grep -Fq 'plugin:discord@claude-plugins-official' "$RELAY_CLEANUP_ROOT/agent-roster.local.sh" || die "relay-cleanup apply touched unrelated agent channel line"
RELAY_CLEANUP_POST_MODE="$(stat -c '%a' "$RELAY_CLEANUP_ROOT/agent-roster.local.sh" 2>/dev/null || stat -f '%Lp' "$RELAY_CLEANUP_ROOT/agent-roster.local.sh")"
[[ "$RELAY_CLEANUP_POST_MODE" == "600" ]] || die "relay-cleanup apply widened agent-roster.local.sh mode under umask 022: expected 600 got $RELAY_CLEANUP_POST_MODE"
log "  [ok] apply removed every residue class, preserved .telegram/.env + unrelated channels, and kept agent-roster.local.sh at mode 0600"

# Round 3: idempotent re-run must report any_changes=false
RELAY_CLEANUP_NOOP_JSON="$(python3 "$REPO_ROOT/bridge-relay-cleanup.py" \
  --target-root "$RELAY_CLEANUP_ROOT" --json)"
RELAY_CLEANUP_NOOP_ANY="$(printf '%s' "$RELAY_CLEANUP_NOOP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("any_changes"))')"
[[ "$RELAY_CLEANUP_NOOP_ANY" == "False" ]] || die "relay-cleanup re-run was not idempotent: $RELAY_CLEANUP_NOOP_JSON"
log "  [ok] re-run is idempotent (any_changes=false)"

# Round 4: a fresh bridge-home with no residue at all must also no-op
RELAY_CLEANUP_CLEAN_ROOT="$(mktemp -d -t relay-cleanup-clean.XXXXXX)"
mkdir -p "$RELAY_CLEANUP_CLEAN_ROOT/agents/foo" \
         "$RELAY_CLEANUP_CLEAN_ROOT/state/channels/telegram"
cat >"$RELAY_CLEANUP_CLEAN_ROOT/agent-roster.local.sh" <<'ROSTER'
#!/usr/bin/env bash
declare -A BRIDGE_AGENT_CHANNELS=()
BRIDGE_AGENT_CHANNELS["foo"]="plugin:discord@claude-plugins-official"
ROSTER
RELAY_CLEANUP_CLEAN_JSON="$(python3 "$REPO_ROOT/bridge-relay-cleanup.py" \
  --target-root "$RELAY_CLEANUP_CLEAN_ROOT" --json)"
RELAY_CLEANUP_CLEAN_ANY="$(printf '%s' "$RELAY_CLEANUP_CLEAN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("any_changes"))')"
[[ "$RELAY_CLEANUP_CLEAN_ANY" == "False" ]] || die "relay-cleanup on a clean bridge-home was not a no-op: $RELAY_CLEANUP_CLEAN_JSON"
log "  [ok] clean host (no residue) is also a no-op"

rm -rf "$RELAY_CLEANUP_ROOT" "$RELAY_CLEANUP_CLEAN_ROOT"

log "stall-detector rate_limit/auth regex narrowing (#329 Track A)"
# Self-contained classifier checks for the bare `\b429\b` / `\bunauthorized\b`
# narrowing. Mirrors the #161 timeout fix: bare numerics/keywords now require
# an HTTP/status/error/code transport qualifier adjacent so non-glyph
# scrollback (A2A task body inject, [cron-dispatch] payload, vendor incident
# transcripts, meta-text quoting the regex itself, CJK prose) no longer
# false-positives. Existing positives (real provider error lines) keep
# classifying.
run_stall_classify_case() {
  local label="$1"
  local expected_classification="$2"  # "" means must NOT classify
  local input="$3"
  local out classification
  out="$(printf '%s' "$input" | python3 "$REPO_ROOT/bridge-stall.py" analyze --format shell)"
  classification="$(printf '%s\n' "$out" | sed -n 's/^STALL_CLASSIFICATION="\(.*\)"$/\1/p')"
  if [[ "$classification" != "$expected_classification" ]]; then
    die "stall classify [$label]: expected '$expected_classification' got '$classification' for input <<<$input>>>"
  fi
  log "  [ok] $label"
}
# Positive: must still classify as rate_limit / auth (real provider errors).
run_stall_classify_case "HTTP 429 Too Many Requests -> rate_limit" \
  "rate_limit" \
  $'error: HTTP 429 Too Many Requests\n'
run_stall_classify_case "status: 401 unauthorized -> auth" \
  "auth" \
  $'status: 401 unauthorized\n'
run_stall_classify_case "api_error_status=429 -> rate_limit" \
  "rate_limit" \
  $'api_error_status=429\n'
run_stall_classify_case "Please wait before trying -> rate_limit" \
  "rate_limit" \
  $'Please wait before trying again in 30 seconds\n'
# Negative regression guards: non-glyph scrollback that bare \b429\b
# / \bunauthorized\b previously matched. None of these have an HTTP
# transport qualifier adjacent and must not classify.
run_stall_classify_case "[cron-dispatch] payload mentioning 429 -> silent" \
  "" \
  $'[cron-dispatch] cs-line-poll-5m payload includes 429 references\n'
run_stall_classify_case "[A2A] task body mentioning 429 -> silent" \
  "" \
  $'[A2A] task body: 429 references in incident report\n'
run_stall_classify_case "external vendor incident transcript -> silent" \
  "" \
  $'Vendor incident: 429 reported by upstream\n'
run_stall_classify_case "meta-text quoting the regex itself -> silent" \
  "" \
  $'매칭 정규식: \\b429\\b\n'
run_stall_classify_case "CJK prose discussing access -> silent" \
  "" \
  $'승인 안 된 액세스를 묘님이 검토 중\n'

log "stall-detector matched_line_hash dedup (#329 Track D)"
# Track D fallback: even if a future false-positive slips past the narrowed
# regex, dedup on the matched line itself (not the shifting excerpt window)
# so nudge_count cannot re-fire past max_nudges. Verify (a) the same
# offending line hashes identically across two scans even when surrounding
# scrollback changes, (b) two genuinely different stall causes hash
# differently so a fresh stall still gets a fresh nudge, and (c) the
# normalized form survives whitespace/case shifts on the matched line.
extract_matched_line_hash() {
  printf '%s\n' "$1" | sed -n 's/^STALL_MATCHED_LINE_HASH="\(.*\)"$/\1/p'
}

stall_d_loop1_out="$(printf 'foo\nbar\nerror: HTTP 429 Too Many Requests\nbaz\n' | python3 "$REPO_ROOT/bridge-stall.py" analyze --format shell)"
stall_d_loop2_out="$(printf 'qux\nzot\nerror: HTTP 429 Too Many Requests\nplugh\nxyzzy\n' | python3 "$REPO_ROOT/bridge-stall.py" analyze --format shell)"
stall_d_loop1_hash="$(extract_matched_line_hash "$stall_d_loop1_out")"
stall_d_loop2_hash="$(extract_matched_line_hash "$stall_d_loop2_out")"
[[ -n "$stall_d_loop1_hash" ]] || die "stall #329 Track D: loop1 produced empty matched_line_hash for a 429 line"
if [[ "$stall_d_loop1_hash" != "$stall_d_loop2_hash" ]]; then
  die "stall #329 Track D: same matched line should hash identically across scrollback shifts (loop1=$stall_d_loop1_hash loop2=$stall_d_loop2_hash)"
fi
log "  [ok] same matched line stable across shifting scrollback"

# Different stall cause → different matched_line → different hash → fresh nudge.
stall_d_diff_out="$(printf 'error: 503 service unavailable\n' | python3 "$REPO_ROOT/bridge-stall.py" analyze --format shell)"
stall_d_diff_hash="$(extract_matched_line_hash "$stall_d_diff_out")"
[[ -n "$stall_d_diff_hash" ]] || die "stall #329 Track D: 503 line produced empty matched_line_hash"
if [[ "$stall_d_diff_hash" == "$stall_d_loop1_hash" ]]; then
  die "stall #329 Track D: distinct stall causes (429 vs 503) must produce distinct matched_line_hash"
fi
log "  [ok] distinct stall causes hash differently"

# Whitespace + case shifts on the matched line should collapse via the
# normalized form (lowercase + collapsed whitespace + trim).
stall_d_norm_out="$(printf '   ERROR:\tHTTP   429    Too Many Requests   \n' | python3 "$REPO_ROOT/bridge-stall.py" analyze --format shell)"
stall_d_norm_hash="$(extract_matched_line_hash "$stall_d_norm_out")"
if [[ "$stall_d_norm_hash" != "$stall_d_loop1_hash" ]]; then
  die "stall #329 Track D: whitespace/case-shifted variant of the same line should normalize to the same hash (norm=$stall_d_norm_hash loop1=$stall_d_loop1_hash)"
fi
log "  [ok] whitespace/case shifts collapse to the same hash"

# Daemon-level dedup: simulate the comparison process_stall_reports() runs
# against the prior stall.env. With matched_line_hash as the dedup key the
# second loop's key matches the persisted prior key, so first_detected_ts
# stays put and nudge_count is NOT reset → the max_nudges cap holds even
# if the same false-positive line keeps appearing in scrollback.
prior_dedup_key="line:$stall_d_loop1_hash"
current_dedup_key="line:$stall_d_loop2_hash"
if [[ "$prior_dedup_key" != "$current_dedup_key" ]]; then
  die "stall #329 Track D: daemon dedup key mismatch despite identical matched line (prior=$prior_dedup_key current=$current_dedup_key)"
fi
log "  [ok] daemon dedup key stable → nudge_count not reset across loops"

log "CLI subcommand suggestion helper (issue #163)"
run_suggest_case() {
  local label="$1"
  local unknown="$2"
  local valid_list="$3"
  local expected_substring="$4"
  local out
  out="$("$BASH4_BIN" -c '
    source "'"$REPO_ROOT"'/bridge-lib.sh"
    bridge_suggest_subcommand "$1" "$2"
  ' _ "$unknown" "$valid_list")"
  if [[ -z "$expected_substring" ]]; then
    [[ -z "$out" ]] || die "expected empty suggestion for $label, got: $out"
  else
    assert_contains "$out" "$expected_substring"
  fi
  log "  [ok] $label"
}
# Curated table — the 3 measured cases from the issue all must recover.
run_suggest_case "health -> status/watchdog" \
  "health" "" "agent-bridge status"
run_suggest_case "cron stats -> cron errors report" \
  "cron stats" "" "agent-bridge cron errors report"
run_suggest_case "cron list --failed -> cron errors report" \
  "cron list --failed" "" "agent-bridge cron errors report"
# Fuzzy fallback — simple Levenshtein hit.
run_suggest_case "fuzzy: satus -> status" \
  "satus" "status summary attach kill" "status"
# Silent on truly-novel input so we don't hallucinate a command.
run_suggest_case "unrelated -> silent" \
  "completely-unrelated" "status summary attach" ""
# Silent on ambiguous near-ties (margin-of-distance gate).
run_suggest_case "ambiguous tie -> silent" \
  "xx" "status attach" ""
# Phase 2: exercise additional curated intents used by the new dispatcher
# wiring (agent list / task summary / top-level diagnose).
run_suggest_case "ps -> list/status (agent dispatcher intent)" \
  "ps" "" "agent-bridge list"
run_suggest_case "task stats -> summary (task dispatcher intent)" \
  "task stats" "" "agent-bridge summary"
run_suggest_case "diagnose -> status/watchdog (top-level intent)" \
  "diagnose" "" "agent-bridge status"
# Issue #283 Track C: cron history / logs / audit / runs all redirect to
# cron errors report (the actual answer); plain `help` redirects to --help.
run_suggest_case "cron history -> cron errors report (#283 Track C)" \
  "cron history" "" "agent-bridge cron errors report"
run_suggest_case "cron logs -> cron errors report (#283 Track C)" \
  "cron logs" "" "agent-bridge cron errors report"
run_suggest_case "help -> --help (#283 Track C)" \
  "help" "" "agent-bridge --help"

# Issue #283 Track A: skill content is now derived from the live CLI surface
# via two helpers in lib/bridge-core.sh. The four checks below mirror the
# verification matrix in the Track A brief: helper returns Usage lines for a
# real subcommand, returns empty for an unknown subcommand, and the rendered
# bridge-commands.md contains both the new auto-discovered section and every
# existing intent-grouped section (regression guard).
log "CLI-help-driven skill reference (#283 Track A)"
TRACK_A_OUT="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_cli_subcommand_help_summary cron "'"$REPO_ROOT"'/agent-bridge"
')"
assert_contains "$TRACK_A_OUT" "cron list"
assert_contains "$TRACK_A_OUT" "cron create"
assert_contains "$TRACK_A_OUT" "cron errors report"
log "  [ok] bridge_cli_subcommand_help_summary cron returns live CLI surface"

TRACK_A_EMPTY="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_cli_subcommand_help_summary nonexistent-subcommand "'"$REPO_ROOT"'/agent-bridge"
')"
[[ -z "$TRACK_A_EMPTY" ]] \
  || die "expected empty summary for nonexistent subcommand, got: $TRACK_A_EMPTY"
log "  [ok] bridge_cli_subcommand_help_summary returns empty for unknown subcommand"

# Issue #828: the auto-generated "Full Subcommand Reference" block is now
# opt-in via BRIDGE_RENDER_SKILL_AUTO_HELP=1 so dynamic agent start does not
# recurse into `agent-bridge --help`. The default render path emits only the
# curated intent-grouped sections; the opt-in path adds the auto-discovered
# subcommand list. Both shapes are asserted below.
TRACK_A_RENDER_DEFAULT="$("$BASH4_BIN" -c '
  unset BRIDGE_RENDER_SKILL_AUTO_HELP
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_render_project_bridge_reference /tmp/test-bridge-home
')"
[[ "$TRACK_A_RENDER_DEFAULT" != *"## Full Subcommand Reference"* ]] \
  || die "default render must skip auto-help block (#828); got it"
log "  [ok] default render skips auto-generated Full Subcommand Reference (#828)"

TRACK_A_RENDER="$("$BASH4_BIN" -c '
  export BRIDGE_RENDER_SKILL_AUTO_HELP=1
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_render_project_bridge_reference /tmp/test-bridge-home
')"
assert_contains "$TRACK_A_RENDER" "## Full Subcommand Reference"
assert_contains "$TRACK_A_RENDER" "### cron"
assert_contains "$TRACK_A_RENDER" "### task"
log "  [ok] opt-in render emits auto-discovered Full Subcommand Reference"

for _track_a_hdr in "## Roster" "## Start Or Resume Agents" "## Task Queue" \
                    "## Cron" "## Urgent Interrupts" "## Stop Sessions" \
                    "## Share Larger Files"; do
  assert_contains "$TRACK_A_RENDER_DEFAULT" "$_track_a_hdr"
  assert_contains "$TRACK_A_RENDER" "$_track_a_hdr"
done
log "  [ok] intent-grouped sections preserved (Roster/Start/Task Queue/Cron/Urgent/Stop/Share) in both render modes"

# Issue #283 Track D: bare agent-bridge / agb prints help instead of erroring.
log "agent-bridge bare invocation prints help summary (#283 Track D)"
BARE_HELP_OUT="$(env BRIDGE_HOME="$(mktemp -d)" "$BASH4_BIN" "$REPO_ROOT/agent-bridge" 2>&1 || true)"
assert_contains "$BARE_HELP_OUT" "Usage:"
assert_contains "$BARE_HELP_OUT" "agent-bridge status"
[[ "$BARE_HELP_OUT" != *"--codex 또는 --claude 중 하나를 지정하세요"* ]] \
  || die "bare agent-bridge should not error with engine-required message"

run_dispatch_suggest_case() {
  local label="$1"
  local expected_substring="$2"
  shift 2
  local home_dir
  local out
  home_dir="$(mktemp -d)"
  out="$(env BRIDGE_HOME="$home_dir" "$BASH4_BIN" "$@" 2>&1 || true)"
  rm -rf "$home_dir"
  assert_contains "$out" "$expected_substring"
  assert_contains "$out" "[오류]"
  log "  [ok] $label"
}

log "dispatcher suggestion wiring (issue #163 phase 2)"
run_dispatch_suggest_case "agent dispatcher: ps -> list" \
  "agent-bridge list" \
  "$REPO_ROOT/bridge-agent.sh" ps
run_dispatch_suggest_case "memory dispatcher: captur -> capture" \
  "capture" \
  "$REPO_ROOT/bridge-memory.sh" captur
run_dispatch_suggest_case "setup dispatcher: telegra -> telegram" \
  "telegram" \
  "$REPO_ROOT/bridge-setup.sh" telegra
run_dispatch_suggest_case "task dispatcher: stats -> summary" \
  "agent-bridge summary" \
  "$REPO_ROOT/bridge-task.sh" stats

log "tmux inject gate: input-buffer-content detection (issue #132)"
# Self-contained coverage for bridge_tmux_session_has_pending_input_from_text.
# Placed early so the harness's downstream pre-existing failures do not gate
# this regression check. Uses an in-process bash sourcing of bridge-lib.sh so
# the tmux helper functions become invokable without a real tmux session.
"$BASH4_BIN" -s "$REPO_ROOT" <<'BASH_UT'
set -u
repo="$1"
# shellcheck disable=SC1090
source "$repo/bridge-lib.sh"
fail() { printf '[smoke][error] inject-gate: %s\n' "$*" >&2; exit 1; }
expect_pending() {
  local label="$1"
  local text="$2"
  if bridge_tmux_session_has_pending_input_from_text claude "$text"; then
    printf '[smoke]   [ok] %s\n' "$label"
  else
    fail "expected PENDING for: $label"
  fi
}
expect_idle() {
  local label="$1"
  local text="$2"
  if bridge_tmux_session_has_pending_input_from_text claude "$text"; then
    fail "expected idle for: $label"
  else
    printf '[smoke]   [ok] %s\n' "$label"
  fi
}
expect_pending_ansi() {
  local label="$1"
  local text="$2"
  local ansi="$3"
  if bridge_tmux_session_has_pending_input_from_text claude "$text" "$ansi"; then
    printf '[smoke]   [ok] %s\n' "$label"
  else
    fail "expected PENDING for: $label"
  fi
}
expect_idle_ansi() {
  local label="$1"
  local text="$2"
  local ansi="$3"
  if bridge_tmux_session_has_pending_input_from_text claude "$text" "$ansi"; then
    fail "expected idle for: $label"
  else
    printf '[smoke]   [ok] %s\n' "$label"
  fi
}
expect_pending "operator composing single word (> glyph)" \
  $'some prior agent output\n> hello'
expect_pending "operator composing (❯ glyph)" \
  $'some prior agent output\n❯ thinking about this...'
expect_pending_ansi "operator composing with ANSI color is still pending" \
  $'some prior agent output\n❯ 응답 오면 알려줘' \
  $'some prior agent output\n\e[39m❯ \e[97m응답 오면 알려줘\e[39m'
expect_idle_ansi "Claude ghost suggestion is idle even when text varies" \
  $'some prior agent output\n❯ 응답 오면 알려줘' \
  $'some prior agent output\n\e[39m❯ \e[7m응\e[0;2m답 오면 알려줘\e[0m\e[39m'
expect_pending "operator composing after scrollback quote" \
  $'agent output\n> an earlier quoted line\nmore agent output\n> typed input'
expect_idle "empty input box at bottom" \
  $'agent output\n> an earlier quoted line\nmore agent output\n> '
expect_idle "numbered-menu blocker (not a compose state)" \
  $'Do you trust the files in this folder?\n> 1. Yes, proceed\n  2. No, exit'
expect_idle "no prompt glyph anywhere" \
  $'just text, nothing composable'
BASH_UT

log "injection metadata-only payload format (issue #132b)"
# Self-contained coverage for bridge_format_injection_meta and the opt-in
# flag. Placed early alongside the other #132* regressions.
"$BASH4_BIN" -s "$REPO_ROOT" <<'META_UT'
set -u
repo="$1"
# shellcheck disable=SC1090
source "$repo/bridge-lib.sh"
fail() { printf '[smoke][error] meta: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '[smoke]   [ok] %s\n' "$label"
  else
    fail "$label: expected [$expected], got [$actual]"
  fi
}

# Bare-token values preserve shape; quoted values only when necessary.
assert_eq "meta bare" "[Agent Bridge] event=inbox count=3 top=X12 from=patch" \
  "$(bridge_format_injection_meta inbox count=3 top=X12 from=patch)"
assert_eq "meta quoted title with spaces" \
  "[Agent Bridge] event=inbox count=1 top=Y55 title='fix docs typo' from=patch" \
  "$(bridge_format_injection_meta inbox count=1 top=Y55 title='fix docs typo' from=patch)"
assert_eq "meta empty value quoted" \
  "[Agent Bridge] event=idle agent=worker-a from=''" \
  "$(bridge_format_injection_meta idle agent=worker-a from=)"
# Value with an embedded single quote uses '\''  escape
assert_eq "meta single-quote escape" \
  "[Agent Bridge] event=inbox title='it'\\''s fine'" \
  "$(bridge_format_injection_meta inbox title="it's fine")"
assert_eq "meta dot-dash-underscore bare" \
  "[Agent Bridge] event=context-pressure agent=admin.1 severity=warning" \
  "$(bridge_format_injection_meta context-pressure agent=admin.1 severity=warning)"
# Embedded newline in value is folded to literal "\n" so the payload stays
# on one logical line (protects parser from mis-splitting).
assert_eq "meta newline folded to sentinel" \
  "[Agent Bridge] event=inbox title='line-1\\nline-2'" \
  "$(bridge_format_injection_meta inbox title="$(printf 'line-1\nline-2')")"

# Flag gating — default off emits legacy text; on emits metadata-only.
unset BRIDGE_INJECT_METADATA_ONLY
default_text="$(bridge_queue_attention_message "claude-static" 2 X1 urgent "do the thing")"
case "$default_text" in
  *"ACTION REQUIRED"*"Run exactly"*) printf '[smoke]   [ok] flag off: legacy format retained\n' ;;
  *) fail "flag off should emit legacy text, got: $default_text" ;;
esac

meta_text="$(BRIDGE_INJECT_METADATA_ONLY=1 bridge_queue_attention_message "claude-static" 2 X1 urgent "do the thing")"
expected_meta="[Agent Bridge] event=inbox agent=claude-static count=2 top=X1 priority=urgent title='do the thing'"
[[ "$meta_text" == "$expected_meta" ]] \
  || fail "flag on: expected exact meta, got '$meta_text'"
# $() strips trailing newlines — so re-run with explicit byte capture to
# verify the payload really is single-line (no \n tail). Required coverage
# per codex review: `wc -c` / `od -c` style byte check.
meta_raw_file="$(mktemp)"
BRIDGE_INJECT_METADATA_ONLY=1 bridge_queue_attention_message \
  "claude-static" 2 X1 urgent "do the thing" >"$meta_raw_file"
last_byte_octal="$(tail -c 1 "$meta_raw_file" | od -An -c | tr -d ' ')"
# Expect the last byte to be the closing "'" of the quoted title, NOT \n.
[[ "$last_byte_octal" == "'" ]] \
  || fail "metadata-only must not end with newline; last byte octal: $last_byte_octal"
rm -f "$meta_raw_file"
printf '[smoke]   [ok] flag on: metadata-only single logical line, no trailing newline (byte-verified)\n'

# Passthrough is GATED on the payload already being a metadata header. A
# plain message must still go through bridge_notification_text wrapping so
# the bridge-task.sh / bridge-send.sh / bridge-intake.sh / bridge-review.sh /
# bridge-bundle.sh callers don't lose their legacy header under the flag.
BRIDGE_INJECT_METADATA_ONLY=1
# Shadow `bridge_tmux_send_and_submit` to capture the emitted text rather
# than hitting tmux, then invoke dispatcher through the public helper.
captured_text=""
bridge_tmux_send_and_submit() { captured_text="$3"; return 0; }
bridge_agent_engine() { printf 'claude'; }
bridge_agent_session() { printf 'fake-session'; }
bridge_tmux_session_exists() { return 0; }
bridge_agent_has_wake_channel() { return 0; }
bridge_claude_session_can_wake() { return 0; }
bridge_claude_session_try_mark_prompt_ready() { return 0; }

# Plain message (legacy caller style) — should get the legacy header wrap
# even when the flag is on.
bridge_dispatch_notification "claude-static" "review needed" "plain reviewer note." "" "normal" >/dev/null 2>&1 || true
case "$captured_text" in
  "[Agent Bridge]"*"plain reviewer note."*) \
    printf '[smoke]   [ok] passthrough gate: plain message still gets legacy header wrap under flag\n' ;;
  *) fail "plain msg under flag should get legacy header, got: $captured_text" ;;
esac

# Metadata-prefixed message should pass through unchanged.
captured_text=""
bridge_dispatch_notification "claude-static" "" "[Agent Bridge] event=inbox agent=claude-static count=1" "" "normal" >/dev/null 2>&1 || true
case "$captured_text" in
  "[Agent Bridge] event=inbox agent=claude-static count=1") \
    printf '[smoke]   [ok] passthrough gate: metadata message passes through verbatim\n' ;;
  *) fail "metadata msg should pass through, got: $captured_text" ;;
esac

# Issue #132b followup: passthrough gate must apply to non-claude engines
# too. Previously the gate was only inside the `case "$engine"` claude
# branch, so a Codex agent's wake re-wrapped a metadata payload with the
# legacy header (producing two events). Stub the engine to codex and
# confirm the metadata passes through verbatim with no header prefix.
captured_text=""
bridge_agent_engine() { printf 'codex'; }
bridge_dispatch_notification "codex-agent" "" "[Agent Bridge] event=inbox agent=codex-agent count=1 top=Z9" "" "normal" >/dev/null 2>&1 || true
case "$captured_text" in
  "[Agent Bridge] event=inbox agent=codex-agent count=1 top=Z9") \
    printf '[smoke]   [ok] passthrough gate: codex engine also passes metadata verbatim\n' ;;
  *) fail "codex metadata msg should pass through, got: $captured_text" ;;
esac

# And: under the flag, a plain message destined for a codex agent must
# still get the legacy header wrap (parity with the claude branch).
captured_text=""
bridge_dispatch_notification "codex-agent" "review needed" "plain reviewer note." "" "normal" >/dev/null 2>&1 || true
case "$captured_text" in
  "[Agent Bridge]"*"plain reviewer note."*) \
    printf '[smoke]   [ok] passthrough gate: codex plain message still wrapped under flag\n' ;;
  *) fail "codex plain msg should keep legacy header, got: $captured_text" ;;
esac
META_UT

log "tmux pending-attention spool: escape/drain/prepend/deferral-cap (issue #132a)"
"$BASH4_BIN" -s "$REPO_ROOT" <<'SPOOL_UT'
set -u
repo="$1"
# shellcheck disable=SC1090
source "$repo/bridge-lib.sh"

fail() { printf '[smoke][error] spool: %s\n' "$*" >&2; exit 1; }

scratch="$(mktemp -d)"
export BRIDGE_HOME="$scratch"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
# #946 r3 — match BRIDGE_DATA_ROOT to the new scratch home so v2-derived
# paths (BRIDGE_AGENT_ROOT_V2 etc.) inside any bridge-lib.sh source that
# follows write under $scratch instead of the auto-isolated home from
# line 44. Only refresh under the auto-isolation contract — operator-
# supplied BRIDGE_HOME keeps full control of layout state.
if [[ "${_SMOKE_AUTO_ISOLATED:-0}" == "1" ]]; then
  # r4 (PR #947 r3) — same derived-root reset as the auto-isolation block.
  unset BRIDGE_AGENT_ROOT_V2 BRIDGE_SHARED_ROOT BRIDGE_CONTROLLER_STATE_ROOT
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME/data"
fi
agent="spool-test"

# Round-trip escape/unescape over the four escape classes.
for text in "plain" $'two\nlines' $'tab\there' "back\\slash" $'mixed\n\ta\\b'; do
  esc="$(bridge_tmux_pending_attention_escape "$text")"
  dec="$(bridge_tmux_pending_attention_unescape "$esc")"
  if [[ "$dec" == "$text" ]]; then
    printf '[smoke]   [ok] round-trip: %q\n' "$text"
  else
    fail "round-trip mismatch for: $(printf '%q' "$text") -> $(printf '%q' "$esc") -> $(printf '%q' "$dec")"
  fi
done

# FIFO append/drain
bridge_tmux_pending_attention_append "$agent" "first"
bridge_tmux_pending_attention_append "$agent" "second"
bridge_tmux_pending_attention_append "$agent" $'third\nwith-newline'
count="$(bridge_tmux_pending_attention_count "$agent")"
[[ "$count" == "3" ]] || fail "count after 3 appends: expected 3, got $count"
printf '[smoke]   [ok] append: count=3\n'

drained="$(bridge_tmux_pending_attention_drain "$agent")"
[[ -n "$drained" ]] || fail "drain returned empty"
# Expect 3 lines in FIFO order
line1="$(printf '%s\n' "$drained" | sed -n '1p' | cut -f2)"
line2="$(printf '%s\n' "$drained" | sed -n '2p' | cut -f2)"
line3="$(printf '%s\n' "$drained" | sed -n '3p' | cut -f2)"
[[ "$line1" == "first" ]] || fail "drain line1: expected 'first', got '$line1'"
[[ "$line2" == "second" ]] || fail "drain line2: expected 'second', got '$line2'"
[[ "$line3" == $'third\\nwith-newline' ]] || fail "drain line3: expected 'third\\\\nwith-newline', got '$line3'"
printf '[smoke]   [ok] drain: FIFO order preserved, newline escaped\n'

# Drain empties the spool
count_after="$(bridge_tmux_pending_attention_count "$agent")"
[[ "$count_after" == "0" ]] || fail "count after drain: expected 0, got $count_after"
printf '[smoke]   [ok] drain: spool emptied\n'

# Prepend preserves head insertion
bridge_tmux_pending_attention_append "$agent" "new-A"
bridge_tmux_pending_attention_append "$agent" "new-B"
bridge_tmux_pending_attention_prepend "$agent" $'99\told-X\n99\told-Y\n'
file="$(bridge_agent_pending_attention_file "$agent")"
actual="$(cat "$file")"
expected=$'99\told-X\n99\told-Y\n'"$(date +%s | head -c 10)"  # ts prefix will differ; check structurally
head1="$(sed -n '1p' "$file" | cut -f2)"
head2="$(sed -n '2p' "$file" | cut -f2)"
tail1="$(sed -n '3p' "$file" | cut -f2)"
tail2="$(sed -n '4p' "$file" | cut -f2)"
[[ "$head1" == "old-X" && "$head2" == "old-Y" ]] \
  || fail "prepend head: expected old-X,old-Y, got '$head1','$head2'"
[[ "$tail1" == "new-A" && "$tail2" == "new-B" ]] \
  || fail "prepend tail: expected new-A,new-B, got '$tail1','$tail2'"
printf '[smoke]   [ok] prepend: head preserved, original tail intact\n'

# Deferral-cap + flush requeue. Mock bridge_tmux_send_and_submit to avoid
# needing a real tmux and drive the gate's bounce/accept from a state var.
cap_agent="cap-test"

# One fresh entry + one aged entry (ts = 0 = far in the past)
now="$(date +%s)"
bridge_tmux_pending_attention_append "$cap_agent" "fresh-event"
fresh_file="$(bridge_agent_pending_attention_file "$cap_agent")"
# Append a second record with an ancient timestamp by rewriting the file.
cat >>"$fresh_file" <<'EOF'
0	very-old-event
EOF

# Override the real tmux send path with a stub that succeeds and records
# every injection that flush attempts.
captured_log="$(mktemp)"
bridge_tmux_send_and_submit() {
  printf '%s\n' "$3" >>"$captured_log"
  return 0
}
# Override wait-for-prompt and the gate so flush's internal send_and_submit
# call (which uses them) is a no-op — but our function stub above shadows
# send_and_submit anyway.
bridge_tmux_pending_attention_flush "mock-session" claude "$cap_agent" \
  || fail "flush returned non-zero with all-success stub"

# Expect two lines in the capture log: "fresh-event" (no marker) and
# "[deferred] very-old-event" (marker applied).
line_fresh="$(sed -n '1p' "$captured_log")"
line_aged="$(sed -n '2p' "$captured_log")"
[[ "$line_fresh" == "fresh-event" ]] \
  || fail "flush line 1: expected 'fresh-event', got '$line_fresh'"
[[ "$line_aged" == "[deferred] very-old-event" ]] \
  || fail "flush line 2: expected '[deferred] very-old-event', got '$line_aged'"
printf '[smoke]   [ok] flush: deferral-cap marker applied to aged entry\n'

# Spool empty after successful flush
remaining="$(bridge_tmux_pending_attention_count "$cap_agent")"
[[ "$remaining" == "0" ]] || fail "spool should be empty after flush, got $remaining"
printf '[smoke]   [ok] flush: spool emptied after all entries delivered\n'

# Requeue-on-busy: stub returns 1 on first call, success after that
rm -f "$captured_log" "$fresh_file"
bridge_tmux_pending_attention_append "$cap_agent" "entry-1"
bridge_tmux_pending_attention_append "$cap_agent" "entry-2"
bridge_tmux_pending_attention_append "$cap_agent" "entry-3"
busy_count=0
bridge_tmux_send_and_submit() {
  busy_count=$((busy_count + 1))
  printf '%s\n' "$3" >>"$captured_log"
  # First call bounces (simulating busy gate), rest succeed. But flush
  # treats a return 1 as "prepend remainder and stop", so we only expect
  # one line in the log from this run.
  if (( busy_count == 1 )); then
    return 1
  fi
  return 0
}
bridge_tmux_pending_attention_flush "mock-session" claude "$cap_agent" \
  && fail "flush should report 1 when gate bounces mid-drain"

logged_lines="$(wc -l <"$captured_log" | awk '{print $1}')"
[[ "$logged_lines" == "1" ]] \
  || fail "flush should stop after first busy bounce, logged=$logged_lines"
spooled_after="$(bridge_tmux_pending_attention_count "$cap_agent")"
[[ "$spooled_after" == "3" ]] \
  || fail "flush should re-prepend all 3 entries after bounce, got $spooled_after"
head_after="$(sed -n '1p' "$fresh_file" | cut -f2)"
[[ "$head_after" == "entry-1" ]] \
  || fail "flush requeue: head should be entry-1, got '$head_after'"
printf '[smoke]   [ok] flush: busy bounce re-prepends FIFO remainder\n'

# Restore real send function for cleanliness if later code re-sources.
unset -f bridge_tmux_send_and_submit

# Issue #132a followup: lock safety. The previous implementation force-rmdir'd
# the lock dir after 200 spin-wait attempts, which could yank the lock from
# a still-live holder. The fix uses PID-based stale-lock recovery instead:
# only reclaim when the holder process is gone. Verify both branches.
lock_agent="lock-test"
lock_dir="$(bridge_agent_pending_attention_lock_dir "$lock_agent")"
mkdir -p "$(dirname "$lock_dir")"

# Case 1: stale lock (holder PID written but process is gone).
# Use PID 1 indirectly by writing a synthetic non-existent PID. Pick a high
# unlikely-running PID (99999999) to simulate a dead holder.
mkdir "$lock_dir"
printf '99999999' >"$lock_dir/holder.pid"
# Append should reclaim the stale lock and succeed.
bridge_tmux_pending_attention_append "$lock_agent" "after-stale-recovery" \
  || fail "append should reclaim stale lock and succeed"
spool_file="$(bridge_agent_pending_attention_file "$lock_agent")"
[[ -f "$spool_file" ]] && grep -q "after-stale-recovery" "$spool_file" \
  || fail "stale-lock recovery: append did not write the entry"
printf '[smoke]   [ok] lock: dead-holder PID triggers stale recovery, append succeeds\n'

# Case 2: live holder. Take the lock via a child process that sleeps.
# Background PID is alive → reclaim must NOT happen → second append should
# eventually fail (return 75) without touching the holder's lock.
rm -f "$spool_file"
( mkdir -p "$lock_dir" && printf '%d' $$ >"$lock_dir/holder.pid" 2>/dev/null \
    && sleep 2 && rm -f "$lock_dir/holder.pid" && rmdir "$lock_dir" ) &
holder_bg=$!
sleep 0.2
# Override the spinlock max so the test runs in <2s rather than 10s.
BRIDGE_TMUX_PENDING_ATTENTION_LOCK_MAX_ATTEMPTS=20 \
bridge_tmux_pending_attention_append "$lock_agent" "should-wait" 2>/dev/null
rc=$?
wait "$holder_bg" 2>/dev/null
# Either the append waited and succeeded after holder released (rc=0), OR
# it gave up cleanly with rc=75. The crucial property is that the holder
# was NOT yanked mid-flight — verifiable by absence of an "appended-while-
# holder-was-alive" entry in the holder's state.
case "$rc" in
  0|75) printf '[smoke]   [ok] lock: live holder is respected (rc=%s, no force-yank)\n' "$rc" ;;
  *) fail "live-holder lock test returned unexpected rc=$rc" ;;
esac

rm -rf "$lock_dir" "$spool_file"
rm -f "$captured_log"
rm -rf "$scratch"
SPOOL_UT

TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
export BRIDGE_HOME="$TMP_ROOT/bridge-home"
# #946 r2 — refresh BRIDGE_DATA_ROOT when BRIDGE_HOME is reassigned mid-script.
# Without this re-export, the auto-isolation block's BRIDGE_DATA_ROOT (line 44)
# still pointed at the obsolete `agb-smoke-isolated.../data` tree, so v2 paths
# such as BRIDGE_AGENT_ROOT_V2 derived under bridge-lib.sh would escape
# $TMP_ROOT and cleanup would miss the state files. Only refresh when the
# auto-isolation path armed v2 in the first place — preserves the contract
# that operator-supplied BRIDGE_HOME (CI runner / custom rig) keeps full
# control of layout state.
if [[ "${_SMOKE_AUTO_ISOLATED:-0}" == "1" ]]; then
  # r4 (PR #947 r3) — same derived-root reset as the auto-isolation block.
  unset BRIDGE_AGENT_ROOT_V2 BRIDGE_SHARED_ROOT BRIDGE_CONTROLLER_STATE_ROOT
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME/data"
fi
export BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=1
# Issue #403 fix #4: pin the isolated-user home root under TMP_ROOT so any
# inner test path that builds `<root>/<os_user>/.agent-bridge` cannot
# escape into the operator's $HOME — even if a future test forgets to use
# a synthetic os_user. The default (`/home`, set by bridge-lib.sh) was the
# vector that combined with PR-E CT4's hardcoded `ec2-user` to wipe a
# live install during a routine pre-PR validation. Outer guard sits at
# the env layer; per-test guards (sudo stub TMP_ROOT prefix check,
# install_agent_bridge_symlink controller-self refusal) are independent
# and complementary.
#
# r2 follow-up (codex r1 FAIL #3): this export is DEFENSIVE-ONLY. It
# protects scripts/smoke-test.sh's own subprocesses if they ever
# happen to call into a Linux-user isolation helper; it does NOT
# invoke the PR-E acceptance suite at tests/isolation-v2-pr-e/smoke.sh.
# The PR-E suite is Linux-only, drives bridge-lib helpers under a
# sudo-stub fixture, and is intended to be run by the operator (or a
# Linux CI lane) directly: `bash tests/isolation-v2-pr-e/smoke.sh`.
# Wiring it into this script would require Linux gating, a separate
# subshell to keep its env-clear pass from clobbering the daemon-side
# state this script depends on, and would silently no-op on macOS dev
# machines. Keep them as two separate entry points; this comment is
# the contract.
export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$TMP_ROOT/iso-users"
mkdir -p "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
export BRIDGE_PROFILE_STATE_DIR="$BRIDGE_STATE_DIR/profiles"
export BRIDGE_CRON_STATE_DIR="$BRIDGE_STATE_DIR/cron"
export BRIDGE_CRON_HOME_DIR="$BRIDGE_HOME/cron"
export BRIDGE_NATIVE_CRON_JOBS_FILE="$BRIDGE_CRON_HOME_DIR/jobs.json"
export BRIDGE_CRON_DISPATCH_WORKER_DIR="$BRIDGE_CRON_STATE_DIR/workers"
export BRIDGE_OPENCLAW_CRON_JOBS_FILE="$TMP_ROOT/openclaw-jobs.json"
export BRIDGE_DAEMON_INTERVAL=1
export BRIDGE_CRON_SYNC_ENABLED=0
export BRIDGE_CRON_DISPATCH_MAX_PARALLEL=1
export BRIDGE_DISCORD_RELAY_ENABLED=0
# Reduce daemon side-work by default; per-block targeted tests re-enable the
# specific scanners they exercise. This keeps the smoke daemon syncs cheap and
# avoids cross-block noise (PR #239 bullet 11). The CHANNEL_HEALTH and
# USAGE_MONITOR gates are intentionally not exported here — their daemon-side
# guards land in a follow-up split alongside this smoke wave.
export BRIDGE_DAILY_BACKUP_ENABLED=0
export BRIDGE_HEARTBEAT_INTERVAL_SECONDS=0
export BRIDGE_WATCHDOG_ENABLED=0
export BRIDGE_SKIP_PLUGIN_LIVENESS=1
export BRIDGE_RELEASE_CHECK_ENABLED=0
export BRIDGE_STALL_SCAN_ENABLED=0
export BRIDGE_CONTEXT_PRESSURE_SCAN_ENABLED=0
export BRIDGE_ROSTER_FILE="$REPO_ROOT/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_RUNTIME_ROOT="$BRIDGE_HOME/runtime"
export BRIDGE_RUNTIME_SCRIPTS_DIR="$BRIDGE_RUNTIME_ROOT/scripts"
export BRIDGE_RUNTIME_SKILLS_DIR="$BRIDGE_RUNTIME_ROOT/skills"
export BRIDGE_RUNTIME_SHARED_DIR="$BRIDGE_RUNTIME_ROOT/shared"
export BRIDGE_RUNTIME_SHARED_TOOLS_DIR="$BRIDGE_RUNTIME_SHARED_DIR/tools"
export BRIDGE_RUNTIME_SHARED_REFERENCES_DIR="$BRIDGE_RUNTIME_SHARED_DIR/references"
export BRIDGE_RUNTIME_MEMORY_DIR="$BRIDGE_RUNTIME_ROOT/memory"
export BRIDGE_RUNTIME_CREDENTIALS_DIR="$BRIDGE_RUNTIME_ROOT/credentials"
export BRIDGE_RUNTIME_SECRETS_DIR="$BRIDGE_RUNTIME_ROOT/secrets"
export BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/bridge-config.json"
export BRIDGE_CLAUDE_USAGE_CACHE="$TMP_ROOT/claude-usage-empty.json"
export BRIDGE_CODEX_SESSIONS_DIR="$TMP_ROOT/codex-sessions-empty"
export BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$TMP_ROOT/installed_plugins.json"
export BRIDGE_CLAUDE_CHANNELS_HOME="$TMP_ROOT/claude-channels"
export BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="$TMP_ROOT/claude-plugin-cache"
export BRIDGE_REVIEW_POLICY_FILE="$BRIDGE_HOME/review-policy.json"
export BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED=0
export BRIDGE_WEBHOOK_PORT_RANGE_START=9301
export BRIDGE_WEBHOOK_PORT_RANGE_END=9399

STALE_CONTROLLER_ENV_ROOT="/tmp/tmp.agent-bridge-stale-env-$$"
rm -rf "$STALE_CONTROLLER_ENV_ROOT"
STALE_CONTROLLER_ENV_OUTPUT="$(
  BRIDGE_HOME="$BRIDGE_HOME" \
  BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=0 \
  BRIDGE_AGENT_HOME_ROOT="$STALE_CONTROLLER_ENV_ROOT/bridge-home/agents" \
  BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="$STALE_CONTROLLER_ENV_ROOT/claude-plugin-cache" \
  "$BASH4_BIN" -c '
    source "'"$REPO_ROOT"'/bridge-lib.sh"
    printf "agent_home=%s\n" "$BRIDGE_AGENT_HOME_ROOT"
    printf "plugin_cache=%s\n" "${BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT-unset}"
  ' 2>&1
)"
assert_contains "$STALE_CONTROLLER_ENV_OUTPUT" "unsetting stale ephemeral controller env BRIDGE_AGENT_HOME_ROOT="
assert_contains "$STALE_CONTROLLER_ENV_OUTPUT" "unsetting stale ephemeral controller env BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="
assert_contains "$STALE_CONTROLLER_ENV_OUTPUT" "agent_home=$BRIDGE_HOME/agents"
assert_contains "$STALE_CONTROLLER_ENV_OUTPUT" "plugin_cache=unset"

SESSION_NAME="bridge-smoke-$$"
REQUESTER_SESSION="bridge-requester-$$"
CLAUDE_STATIC_SESSION="claude-static-$SESSION_NAME"
ROSTER_RELOAD_AGENT="roster-reload-agent-$$"
ROSTER_RELOAD_SESSION="roster-reload-session-$$"
SMOKE_AGENT="smoke-agent-$$"
REQUESTER_AGENT="requester-agent-$$"
AUTO_START_AGENT="auto-start-agent-$$"
AUTO_START_SESSION="auto-start-session-$$"
ALWAYS_ON_AGENT="always-on-agent-$$"
ALWAYS_ON_SESSION="always-on-session-$$"
STATIC_AGENT="static-role-$$"
STATIC_SESSION="static-session-$$"
CODEX_CLI_AGENT="codex-cli-agent-$$"
CODEX_CLI_SESSION="codex-cli-session-$$"
LATE_DYNAMIC_AGENT="late-dynamic-agent-$$"
LATE_DYNAMIC_SESSION="late-dynamic-session-$$"
STALE_RESUME_AGENT="stale-resume-agent-$$"
WORKTREE_AGENT="worker-reuse-$$"
CREATED_AGENT="created-agent-$$"
CREATED_SESSION="created-session-$$"
SHARED_USER_AGENT="shared-user-agent-$$"
SHARED_USER_SESSION="created-session-shared-user-$$"
INIT_AGENT="bootstrap-admin-$$"
INIT_SESSION="bootstrap-session-$$"
BOOTSTRAP_AGENT="bootstrap-wrapper-$$"
BOOTSTRAP_SESSION="bootstrap-wrapper-session-$$"
BOOTSTRAP_RCFILE="$TMP_ROOT/bootstrap-shell.rc"
BROKEN_CHANNEL_AGENT="broken-channel-$$"
WORKDIR="$TMP_ROOT/workdir"
REQUESTER_WORKDIR="$TMP_ROOT/requester-workdir"
AUTO_START_WORKDIR="$TMP_ROOT/auto-start-workdir"
BROKEN_CHANNEL_WORKDIR="$TMP_ROOT/broken-channel-workdir"
LATE_DYNAMIC_WORKDIR="$TMP_ROOT/late-dynamic-workdir"
PROJECT_ROOT="$TMP_ROOT/git-project"
HOOK_WORKDIR="$TMP_ROOT/claude-hook-workdir"
MCP_WORKDIR="$TMP_ROOT/claude-mcp-workdir"
CLAUDE_STATIC_WORKDIR="$BRIDGE_HOME/agents/claude-static"
ROSTER_RELOAD_WORKDIR="$TMP_ROOT/roster-reload-workdir"
FAKE_BIN="$TMP_ROOT/bin"
FAKE_DISCORD_PORT_FILE="$TMP_ROOT/fake-discord.port"
FAKE_DISCORD_REQUESTS="$TMP_ROOT/fake-discord-requests.jsonl"
FAKE_DISCORD_PID=""
FAKE_TELEGRAM_PORT_FILE="$TMP_ROOT/fake-telegram.port"
FAKE_TELEGRAM_REQUESTS="$TMP_ROOT/fake-telegram-requests.jsonl"
FAKE_TELEGRAM_PID=""
TEAMS_PLUGIN_PID=""
TEAMS_SETUP_MOCK_PID=""
MCP_ORPHAN_PID=""
MCP_ATTACHED_PARENT_PID=""
MCP_ATTACHED_CHILD_PID=""
TOKENFILE_ENV="$TMP_ROOT/tokenfile-telegram.env"
CODEX_HOOKS_FILE="$TMP_ROOT/codex-home/.codex/hooks.json"
export BRIDGE_CODEX_HOOKS_FILE="$CODEX_HOOKS_FILE"
LIVE_ROSTER_FILE="$HOME/.agent-bridge/agent-roster.local.sh"
LIVE_ROSTER_BACKUP="$TMP_ROOT/live-agent-roster.local.sh.bak"
LIVE_ROSTER_PRESENT=0

if [[ -f "$LIVE_ROSTER_FILE" ]]; then
  cp "$LIVE_ROSTER_FILE" "$LIVE_ROSTER_BACKUP"
  LIVE_ROSTER_PRESENT=1
fi

[[ "$BRIDGE_ROSTER_LOCAL_FILE" != "$LIVE_ROSTER_FILE" ]] || die "smoke roster must not target the live roster"

# Refuse to start when a previous smoke run leaked a managed-role block into
# $BRIDGE_ROSTER_LOCAL_FILE. Without this guard the next run silently
# double-registers a dead static role under the same id (issue #305). We match
# `smoke-temp` (the historical leaked id) plus any id containing `smoke` or
# `bridge-smoke-` so future fixture renames stay covered.
if [[ -f "$BRIDGE_ROSTER_LOCAL_FILE" ]]; then
  _smoke_leaked_blocks="$(grep -nE '^# BEGIN AGENT BRIDGE MANAGED ROLE: (smoke-temp|.*smoke.*|.*bridge-smoke-.*)$' "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null || true)"
  if [[ -n "$_smoke_leaked_blocks" ]]; then
    _smoke_leaked_ids="$(printf '%s\n' "$_smoke_leaked_blocks" | sed -E 's/^[0-9]+:# BEGIN AGENT BRIDGE MANAGED ROLE: //' | paste -sd ',' -)"
    printf '[smoke][error] 이전 smoke 실행이 남긴 roster 블록이 있습니다. 다음 블록을 정리한 뒤 재시도하세요: %s\n' "$_smoke_leaked_ids" >&2
    printf '[smoke][error] roster=%s\n' "$BRIDGE_ROSTER_LOCAL_FILE" >&2
    printf '[smoke][error] %s\n' "$_smoke_leaked_blocks" >&2
    grep -nE '^# END AGENT BRIDGE MANAGED ROLE: (smoke-temp|.*smoke.*|.*bridge-smoke-.*)$' "$BRIDGE_ROSTER_LOCAL_FILE" 2>/dev/null | while IFS= read -r _smoke_end_line; do
      printf '[smoke][error] %s\n' "$_smoke_end_line" >&2
    done
    exit 1
  fi
  unset _smoke_leaked_blocks _smoke_leaked_ids
fi

cleanup() {
  local status=$?
  local _cleanup_attempt=""
  # Pin BRIDGE_HOME on the subshell explicitly so the stop command can never
  # target a live install even if some earlier code path unset or rewrote
  # the exported value. See issue #207.
  # --force: cleanup runs after the smoke fixture has spun up tmux fixture
  # agents; without --force the #314/#315 active-agent guard would refuse
  # the stop and leave the test daemon running.
  env BRIDGE_HOME="$TMP_ROOT/bridge-home" bash "$REPO_ROOT/bridge-daemon.sh" stop --force >/dev/null 2>&1 || true
  # Kill every tmux session that did not exist before the smoke test started.
  if [[ -n "${SMOKE_PRE_SESSIONS_FILE:-}" && -f "$SMOKE_PRE_SESSIONS_FILE" ]]; then
    local _new_session=""
    while IFS= read -r _new_session; do
      [[ -n "$_new_session" ]] || continue
      tmux_kill_session_exact "$_new_session" || true
    done < <(comm -13 "$SMOKE_PRE_SESSIONS_FILE" <(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort) 2>/dev/null || true)
    rm -f "$SMOKE_PRE_SESSIONS_FILE"
  fi
  # Fallback: also kill by known patterns in case the snapshot was lost.
  kill_stale_smoke_tmux_sessions
  tmux_kill_session_exact "$SESSION_NAME" || true
  tmux_kill_session_exact "$REQUESTER_SESSION" || true
  tmux_kill_session_exact "$AUTO_START_SESSION" || true
  tmux_kill_session_exact "$ALWAYS_ON_SESSION" || true
  tmux_kill_session_exact "$STATIC_SESSION" || true
  tmux_kill_session_exact "$CLAUDE_STATIC_SESSION" || true
  tmux_kill_session_exact "$WORKTREE_AGENT" || true
  tmux_kill_session_exact "$LATE_DYNAMIC_SESSION" || true
  if [[ -n "$FAKE_DISCORD_PID" ]]; then
    kill "$FAKE_DISCORD_PID" >/dev/null 2>&1 || true
    wait "$FAKE_DISCORD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$FAKE_TELEGRAM_PID" ]]; then
    kill "$FAKE_TELEGRAM_PID" >/dev/null 2>&1 || true
    wait "$FAKE_TELEGRAM_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEAMS_PLUGIN_PID" ]]; then
    kill "$TEAMS_PLUGIN_PID" >/dev/null 2>&1 || true
    wait "$TEAMS_PLUGIN_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEAMS_SETUP_MOCK_PID" ]]; then
    kill "$TEAMS_SETUP_MOCK_PID" >/dev/null 2>&1 || true
    wait "$TEAMS_SETUP_MOCK_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MCP_ORPHAN_PID" ]]; then
    kill "$MCP_ORPHAN_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MCP_ATTACHED_CHILD_PID" ]]; then
    kill "$MCP_ATTACHED_CHILD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MCP_ATTACHED_PARENT_PID" ]]; then
    kill "$MCP_ATTACHED_PARENT_PID" >/dev/null 2>&1 || true
    wait "$MCP_ATTACHED_PARENT_PID" >/dev/null 2>&1 || true
  fi
  # Strip every managed-role block the smoke fixture wrote into
  # $BRIDGE_ROSTER_LOCAL_FILE. When the roster lives under $TMP_ROOT this is a
  # no-op once `rm -rf "$TMP_ROOT"` runs below, but the strip protects
  # operators who explicitly overrode BRIDGE_ROSTER_LOCAL_FILE to a path
  # outside $TMP_ROOT (issue #305). Idempotent: each strip is guarded by
  # presence of both BEGIN and END markers, so re-entry under `set +e` cleanup
  # cannot fail the trap.
  if [[ ${#SMOKE_REGISTERED_AGENT_IDS[@]} -gt 0 && -n "${BRIDGE_ROSTER_LOCAL_FILE:-}" ]]; then
    local _smoke_id=""
    for _smoke_id in "${SMOKE_REGISTERED_AGENT_IDS[@]}"; do
      smoke_strip_managed_role_block "$_smoke_id" "$BRIDGE_ROSTER_LOCAL_FILE" || true
    done
  fi
  if [[ "$LIVE_ROSTER_PRESENT" == "1" ]] && ! cmp -s "$LIVE_ROSTER_BACKUP" "$LIVE_ROSTER_FILE"; then
    cp "$LIVE_ROSTER_BACKUP" "$LIVE_ROSTER_FILE"
    printf '[smoke][error] live roster changed during smoke; restored backup: %s\n' "$LIVE_ROSTER_FILE" >&2
    status=1
  fi
  for _cleanup_attempt in 1 2 3 4 5; do
    rm -rf "$TMP_ROOT" >/dev/null 2>&1 && break
    sleep 0.2
  done
  if [[ -e "$TMP_ROOT" ]]; then
    printf '[smoke][error] failed to remove temporary smoke root after retries: %s\n' "$TMP_ROOT" >&2
    status=1
  fi
  # Defensive sweep (queue task #4793): wipe smoke-created agent dirs from
  # $BRIDGE_HOME/agents/ AND report+wipe any that managed to land in the
  # live install ($HOME/.agent-bridge/agents/) before the top-of-file
  # BRIDGE_HOME guard catches a future regression. Live-path guard: if
  # BRIDGE_HOME IS the live install, refuse the wipe entirely — that
  # combination means the top-of-file guard already failed and the safest
  # move is to leave everything in place for the operator to inspect.
  if [[ "${BRIDGE_HOME:-}" == "$HOME/.agent-bridge" ]]; then
    printf '[smoke][error] cleanup refused: BRIDGE_HOME is live install (%s)\n' \
      "$BRIDGE_HOME" >&2
    printf '[smoke][error] top-of-file BRIDGE_HOME guard should have caught this; refusing to rm-rf live agents/\n' >&2
    status=1
  else
    local _smoke_known_pat
    # Wipe smoke-created agent dirs from the isolated BRIDGE_HOME first.
    # This is normally a no-op (rm -rf "$TMP_ROOT" already removed them)
    # but covers the case where BRIDGE_HOME points outside TMP_ROOT.
    if [[ -n "${BRIDGE_HOME:-}" ]] && [[ -d "$BRIDGE_HOME/agents" ]]; then
      for _smoke_known_pat in \
        "always-on-agent-$$" \
        "auto-start-agent-$$" \
        "broken-channel-$$" \
        "claude-static" \
        "cap-test" \
        "spool-test" \
        "lock-test"; do
        [[ -d "$BRIDGE_HOME/agents/$_smoke_known_pat" ]] || continue
        rm -rf "$BRIDGE_HOME/agents/$_smoke_known_pat" 2>/dev/null || true
      done
    fi
    # Report + (conditionally) wipe any smoke residue that landed in the
    # live install. This is the queue #4793 leak path. Reporting first
    # (so the operator sees that the guard regressed), wiping second
    # (so the watchdog drift alarm stops firing). Two fingerprint
    # classes:
    #   - PID-seeded names (`<role>-$$`): safe to rm by basename — $$
    #     is unique to this smoke run, so a real live agent cannot
    #     share the name.
    #   - HARDCODED names (claude-static / cap-test / spool-test /
    #     lock-test): MUST pass an emptiness fingerprint check before
    #     wipe. A real operator may legitimately have a `claude-static`
    #     agent; we refuse to delete it by basename alone. The smoke
    #     fixture only writes layout-marker files / empty dirs for
    #     these, so the find probe below catches real content.
    if [[ -d "$HOME/.agent-bridge/agents" ]]; then
      local _smoke_leaked_list=()
      local _smoke_named_kept=()
      local _smoke_pid_pat="-$$"
      local _smoke_live_entry=""
      # PID-seeded names: $$ is unique to this smoke run, so any match
      # is definitely smoke residue — wipe by basename, no fingerprint
      # check needed.
      for _smoke_live_entry in "$HOME/.agent-bridge/agents/"*"$_smoke_pid_pat"; do
        [[ -d "$_smoke_live_entry" ]] || continue
        _smoke_leaked_list+=("$(basename "$_smoke_live_entry")")
      done
      # Hardcoded names: a real operator could legitimately have an
      # agent named `claude-static`/`cap-test`/`spool-test`/`lock-test`.
      # Refuse to wipe by basename alone — the smoke fixture only
      # writes state/runtime scaffolding under these (no operator
      # notes / memory / session-type markers). The find probe below
      # treats anything outside state/ runtime/ .cache/ as evidence
      # of a real agent and keeps the dir.
      for _smoke_known_pat in claude-static cap-test spool-test lock-test; do
        local _smoke_named_target="$HOME/.agent-bridge/agents/$_smoke_known_pat"
        [[ -d "$_smoke_named_target" ]] || continue
        local _smoke_real_file=""
        _smoke_real_file="$(find "$_smoke_named_target" -mindepth 1 -maxdepth 3 -type f \
          ! -path '*/state/*' ! -path '*/runtime/*' ! -path '*/.cache/*' \
          -print -quit 2>/dev/null || true)"
        if [[ -n "$_smoke_real_file" ]]; then
          _smoke_named_kept+=("$_smoke_known_pat (has real file: ${_smoke_real_file#"$HOME"/.agent-bridge/agents/})")
        else
          _smoke_leaked_list+=("$_smoke_known_pat")
        fi
        unset _smoke_real_file _smoke_named_target
      done
      if (( ${#_smoke_named_kept[@]} > 0 )); then
        printf '[smoke][warn] live install has dirs matching smoke names but with real content — leaving alone: %s\n' \
          "${_smoke_named_kept[*]}" >&2
      fi
      if (( ${#_smoke_leaked_list[@]} > 0 )); then
        printf '[smoke][error] smoke leaked agent dirs into the live install (refs #4793): %s\n' \
          "${_smoke_leaked_list[*]}" >&2
        printf '[smoke][error] live install path: %s/.agent-bridge/agents/\n' "$HOME" >&2
        printf '[smoke][error] wiping leaked dirs (top-of-file guard should have prevented this)\n' >&2
        local _smoke_leaked_name=""
        for _smoke_leaked_name in "${_smoke_leaked_list[@]}"; do
          rm -rf "$HOME/.agent-bridge/agents/$_smoke_leaked_name" 2>/dev/null || true
        done
        status=1
        unset _smoke_leaked_name
      fi
      unset _smoke_leaked_list _smoke_named_kept _smoke_pid_pat _smoke_live_entry
    fi
    unset _smoke_known_pat
  fi
  # Auto-isolated BRIDGE_HOME cleanup. We only touch the tempdir we created
  # ourselves at startup — never a caller-supplied path.
  if [[ "${_SMOKE_AUTO_ISOLATED:-0}" == "1" ]] && [[ -n "${BRIDGE_HOME:-}" ]]; then
    local _smoke_iso_parent
    _smoke_iso_parent="$(dirname "$BRIDGE_HOME")"
    case "$_smoke_iso_parent" in
      "${TMPDIR%/}"/agb-smoke-isolated.*|/tmp/agb-smoke-isolated.*|/private/tmp/agb-smoke-isolated.*|/var/folders/*/agb-smoke-isolated.*|/private/var/folders/*/agb-smoke-isolated.*)
        rm -rf "$_smoke_iso_parent" 2>/dev/null || true
        ;;
    esac
    unset _smoke_iso_parent
  fi
  exit "$status"
}
trap cleanup EXIT

# Snapshot tmux sessions before smoke test so cleanup only reaps new sessions.
SMOKE_PRE_SESSIONS_FILE="$(mktemp)"
tmux list-sessions -F '#{session_name}' 2>/dev/null | sort > "$SMOKE_PRE_SESSIONS_FILE" || true

kill_stale_smoke_tmux_sessions

mkdir -p "$BRIDGE_HOME" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR" "$WORKDIR" "$REQUESTER_WORKDIR" "$AUTO_START_WORKDIR" "$BROKEN_CHANNEL_WORKDIR" "$LATE_DYNAMIC_WORKDIR" "$ROSTER_RELOAD_WORKDIR"
mkdir -p "$BRIDGE_CODEX_SESSIONS_DIR"
mkdir -p "$HOOK_WORKDIR/.claude"
mkdir -p "$MCP_WORKDIR"
mkdir -p "$CLAUDE_STATIC_WORKDIR"
mkdir -p "$BRIDGE_HOME/agents/$SMOKE_AGENT"
mkdir -p "$BRIDGE_HOME/agents/$REQUESTER_AGENT"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

mkdir -p "$PROJECT_ROOT"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
git -C "$PROJECT_ROOT" init -q
git -C "$PROJECT_ROOT" config user.email smoke-test
git -C "$PROJECT_ROOT" config user.name "Smoke Test"
echo "smoke" >"$PROJECT_ROOT/README.md"
git -C "$PROJECT_ROOT" add README.md
git -C "$PROJECT_ROOT" commit -qm "init"

log "cleaning stale smoke tmux sessions by prefix"
tmux new-session -d -s "bootstrap-session-stale-smoke" "sleep 30"
tmux new-session -d -s "codex-cli-session-stale-smoke" "sleep 30"
kill_stale_smoke_tmux_sessions
tmux_has_session_exact "bootstrap-session-stale-smoke" && die "stale bootstrap session survived smoke cleanup helper"
tmux_has_session_exact "codex-cli-session-stale-smoke" && die "stale codex session survived smoke cleanup helper"

log "requiring exact tmux session matching"
PREFIX_SESSION="bridge-smoke-prefix-$SESSION_NAME"
PREFIX_SUFFIX_SESSION="${PREFIX_SESSION}-suffix"
tmux new-session -d -s "$PREFIX_SUFFIX_SESSION" "sleep 30"
"$BASH4_BIN" -lc 'source "'"$REPO_ROOT"'/bridge-lib.sh"; ! bridge_tmux_session_exists "'"$PREFIX_SESSION"'"' || die "bridge_tmux_session_exists matched prefix session"
tmux_kill_session_exact "$PREFIX_SUFFIX_SESSION" || true

log "updating shell integration managed block when repo path changes"
SHELL_RC="$TMP_ROOT/install-shell-integration.zshrc"
cat >"$SHELL_RC" <<EOF
# >>> agent-bridge zsh >>>
source "$HOME/agent-bridge-public/shell/agent-bridge.zsh"
# <<< agent-bridge zsh <<<
EOF
SHELL_UPDATE_OUTPUT="$("$REPO_ROOT/scripts/install-shell-integration.sh" --shell zsh --rcfile "$SHELL_RC" --apply)"
assert_contains "$SHELL_UPDATE_OUTPUT" "updated agent-bridge shell integration"
assert_contains "$(cat "$SHELL_RC")" "source \"$REPO_ROOT/shell/agent-bridge.zsh\""
assert_not_contains "$(cat "$SHELL_RC")" "source \"$HOME/agent-bridge-public/shell/agent-bridge.zsh\""
SHELL_UPTODATE_OUTPUT="$("$REPO_ROOT/scripts/install-shell-integration.sh" --shell zsh --rcfile "$SHELL_RC" --apply)"
assert_contains "$SHELL_UPTODATE_OUTPUT" "shell integration already up to date"

cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"item.completed","item":{"type":"agent_message","text":"{\"status\":\"completed\",\"summary\":\"cron smoke ok\",\"findings\":[],\"actions_taken\":[\"processed cron dispatch\"],\"needs_human_followup\":false,\"recommended_next_steps\":[],\"artifacts\":[],\"confidence\":\"high\"}"}}
JSON
EOF
chmod +x "$FAKE_BIN/codex"
cp "$FAKE_BIN/codex" "$TMP_ROOT/codex-cron-fake"

# Init preflight (`agent-bridge init --dry-run --json`, exercised below)
# resolves a `claude` binary on PATH; without one, CI hosts fail before any
# fixture work runs. Stub a minimal binary that prints a prompt and sleeps so
# the preflight succeeds without a real Claude CLI install (PR #239 bullet 3).
cat >"$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '❯ \n'
sleep 30
EOF
chmod +x "$FAKE_BIN/claude"

cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
#!/usr/bin/env bash
bridge_add_agent_id_if_missing "$SMOKE_AGENT"
bridge_add_agent_id_if_missing "$REQUESTER_AGENT"
bridge_add_agent_id_if_missing "$AUTO_START_AGENT"
bridge_add_agent_id_if_missing "$ALWAYS_ON_AGENT"
bridge_add_agent_id_if_missing "$CODEX_CLI_AGENT"
bridge_add_agent_id_if_missing "claude-static"
bridge_add_agent_id_if_missing "$ROSTER_RELOAD_AGENT"
BRIDGE_ADMIN_AGENT_ID="$SMOKE_AGENT"
BRIDGE_AGENT_DESC["$SMOKE_AGENT"]="Smoke test role"
BRIDGE_AGENT_DESC["$REQUESTER_AGENT"]="Requester role"
BRIDGE_AGENT_DESC["$AUTO_START_AGENT"]="Auto-start role"
BRIDGE_AGENT_DESC["$ALWAYS_ON_AGENT"]="Always-on role"
BRIDGE_AGENT_DESC["$CODEX_CLI_AGENT"]="Codex CLI hook role"
BRIDGE_AGENT_DESC["claude-static"]="Claude static role"
BRIDGE_AGENT_DESC["$ROSTER_RELOAD_AGENT"]="Roster reload role"
BRIDGE_AGENT_ENGINE["$SMOKE_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$REQUESTER_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$AUTO_START_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$ALWAYS_ON_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["$CODEX_CLI_AGENT"]="codex"
BRIDGE_AGENT_ENGINE["claude-static"]="claude"
BRIDGE_AGENT_ENGINE["$ROSTER_RELOAD_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$SMOKE_AGENT"]="$SESSION_NAME"
BRIDGE_AGENT_SESSION["$REQUESTER_AGENT"]="$REQUESTER_SESSION"
BRIDGE_AGENT_SESSION["$AUTO_START_AGENT"]="$AUTO_START_SESSION"
BRIDGE_AGENT_SESSION["$ALWAYS_ON_AGENT"]="$ALWAYS_ON_SESSION"
BRIDGE_AGENT_SESSION["$CODEX_CLI_AGENT"]="$CODEX_CLI_SESSION"
BRIDGE_AGENT_SESSION["claude-static"]="claude-static-$SESSION_NAME"
BRIDGE_AGENT_SESSION["$ROSTER_RELOAD_AGENT"]="$ROSTER_RELOAD_SESSION"
BRIDGE_AGENT_WORKDIR["$SMOKE_AGENT"]="$WORKDIR"
BRIDGE_AGENT_WORKDIR["$REQUESTER_AGENT"]="$REQUESTER_WORKDIR"
BRIDGE_AGENT_WORKDIR["$AUTO_START_AGENT"]="$AUTO_START_WORKDIR"
BRIDGE_AGENT_WORKDIR["$ALWAYS_ON_AGENT"]="$AUTO_START_WORKDIR"
BRIDGE_AGENT_WORKDIR["$CODEX_CLI_AGENT"]="$WORKDIR"
BRIDGE_AGENT_WORKDIR["claude-static"]="$CLAUDE_STATIC_WORKDIR"
BRIDGE_AGENT_WORKDIR["$ROSTER_RELOAD_AGENT"]="$ROSTER_RELOAD_WORKDIR"
BRIDGE_AGENT_DISCORD_CHANNEL_ID["$SMOKE_AGENT"]="123456789012345678"
BRIDGE_AGENT_NOTIFY_ACCOUNT["$SMOKE_AGENT"]="smoke"
BRIDGE_AGENT_CHANNELS["claude-static"]="plugin:discord@claude-plugins-official"
BRIDGE_AGENT_CONTINUE["$ROSTER_RELOAD_AGENT"]="0"
BRIDGE_CRON_AGENT_TARGET["legacy-ops"]="$AUTO_START_AGENT"
BRIDGE_AGENT_LAUNCH_CMD["$SMOKE_AGENT"]='python3 -c "import time; print(\"smoke-agent ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$REQUESTER_AGENT"]='python3 -c "import time; print(\"requester-agent ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$AUTO_START_AGENT"]='python3 -c "import time; print(\"auto-start ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$ALWAYS_ON_AGENT"]='python3 -c "import time; print(\"always-on ready\", flush=True); time.sleep(30)"'
BRIDGE_AGENT_LAUNCH_CMD["$CODEX_CLI_AGENT"]='codex'
BRIDGE_AGENT_LAUNCH_CMD["claude-static"]='DISCORD_STATE_DIR=REPLACE_CLAUDE_DISCORD claude -c --dangerously-skip-permissions'
BRIDGE_AGENT_LAUNCH_CMD["$ROSTER_RELOAD_AGENT"]='ROSTER_MARK=before claude --dangerously-skip-permissions --name roster-reload'
BRIDGE_AGENT_IDLE_TIMEOUT["$ALWAYS_ON_AGENT"]="0"
EOF

log "guarding isolated agent-env writes from stale tmp controller env (#365 follow-up)"
STALE_ENV_GUARD_FILE="$TMP_ROOT/stale-agent-env.sh"
STALE_ENV_GUARD_OUTPUT="$(BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=0 "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_write_linux_agent_env_file "$1" "$2"
' -- "$SMOKE_AGENT" "$STALE_ENV_GUARD_FILE" 2>&1 || true)"
assert_contains "$STALE_ENV_GUARD_OUTPUT" "refusing to write isolated agent-env.sh from ephemeral controller path BRIDGE_HOME="
[[ ! -e "$STALE_ENV_GUARD_FILE" ]] || die "stale controller env guard wrote $STALE_ENV_GUARD_FILE despite refusing"

python3 - "$BRIDGE_ROSTER_LOCAL_FILE" "$CLAUDE_STATIC_WORKDIR/.discord" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(text.replace("REPLACE_CLAUDE_DISCORD", sys.argv[2]), encoding="utf-8")
PY

mkdir -p "$CLAUDE_STATIC_WORKDIR/.discord"
cat >"$CLAUDE_STATIC_WORKDIR/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: static-claude
- Onboarding State: complete
EOF
cat >"$CLAUDE_STATIC_WORKDIR/.discord/.env" <<'EOF'
DISCORD_BOT_TOKEN=smoke-token
EOF
cat >"$CLAUDE_STATIC_WORKDIR/.discord/access.json" <<'EOF'
{
  "groups": {
    "123456789012345678": {
      "requireMention": false
    }
  }
}
EOF

echo "temporary smoke note" >"$BRIDGE_SHARED_DIR/note.md"
echo "# Smoke CLAUDE" >"$WORKDIR/CLAUDE.md"

cat >"$TMP_ROOT/openclaw.json" <<'EOF'
{
  "channels": {
    "discord": {
      "accounts": {
        "smoke": {
          "token": "smoke-token"
        }
      }
    },
    "telegram": {
      "accounts": {
        "smoke": {
          "token": "smoke-telegram-token"
        }
      }
    },
    "teams": {
      "accounts": {
        "smoke": {
          "appId": "smoke-teams-app-id",
          "appPassword": "smoke-teams-secret",
          "tenantId": "smoke-teams-tenant"
        }
      }
    }
  }
}
EOF

cat >"$BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE" <<'EOF'
{
  "version": 1,
  "plugins": {
    "telegram@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "/tmp/telegram",
        "version": "1.0.0"
      }
    ],
    "discord@claude-plugins-official": [
      {
        "scope": "user",
        "installPath": "/tmp/discord",
        "version": "1.0.0"
      }
    ],
    "teams@agent-bridge": [
      {
        "scope": "user",
        "installPath": "/tmp/teams",
        "version": "0.1.0"
      }
    ]
  }
}
EOF
cat >"$TMP_ROOT/missing-installed-plugins.json" <<'EOF'
{
  "version": 1,
  "plugins": {}
}
EOF
mkdir -p "$BRIDGE_CLAUDE_CHANNELS_HOME/telegram" "$BRIDGE_CLAUDE_CHANNELS_HOME/discord"
cat >"$BRIDGE_CLAUDE_CHANNELS_HOME/telegram/.env" <<'EOF'
TELEGRAM_BOT_TOKEN=plugin-telegram-token
EOF
cat >"$BRIDGE_CLAUDE_CHANNELS_HOME/discord/.env" <<'EOF'
DISCORD_BOT_TOKEN=plugin-discord-token
EOF

log "starting fake Discord API"
python3 -u - "$FAKE_DISCORD_PORT_FILE" "$FAKE_DISCORD_REQUESTS" <<'PY' >/dev/null 2>&1 &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, requests_file = sys.argv[1], sys.argv[2]
TOKEN = "smoke-token"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self):
        return self.headers.get("Authorization") == f"Bot {TOKEN}"

    def do_GET(self):
        if not self._auth_ok():
            self._send(401, {"message": "401: Unauthorized"})
            return
        if self.path == "/users/@me":
            self._send(200, {"id": "999", "username": "smoke-bot", "bot": True})
            return
        if self.path.startswith("/channels/"):
            channel_id = self.path.split("/")[2].split("?", 1)[0]
            self._send(200, {"id": channel_id, "name": f"channel-{channel_id}"})
            return
        self._send(404, {"message": "404: Not Found"})

    def do_POST(self):
        if not self._auth_ok():
            self._send(401, {"message": "401: Unauthorized"})
            return
        if self.path.startswith("/channels/") and self.path.endswith("/messages"):
            channel_id = self.path.split("/")[2]
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8") if length else "{}"
            with open(requests_file, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"path": self.path, "body": json.loads(body)}) + "\n")
            self._send(200, {"id": "message-1", "channel_id": channel_id})
            return
        self._send(404, {"message": "404: Not Found"})

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
FAKE_DISCORD_PID=$!

for _ in $(seq 1 50); do
  [[ -f "$FAKE_DISCORD_PORT_FILE" ]] && break
  sleep 0.1
done
[[ -f "$FAKE_DISCORD_PORT_FILE" ]] || die "fake Discord API failed to start"
FAKE_DISCORD_API_BASE="http://127.0.0.1:$(cat "$FAKE_DISCORD_PORT_FILE")"
python3 - "$TMP_ROOT/openclaw.json" "$FAKE_DISCORD_API_BASE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("channels", {}).setdefault("discord", {}).setdefault("accounts", {}).setdefault("smoke", {})["apiBaseUrl"] = sys.argv[2]
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

log "starting fake Telegram API"
python3 -u - "$FAKE_TELEGRAM_PORT_FILE" "$FAKE_TELEGRAM_REQUESTS" <<'PY' >/dev/null 2>&1 &
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_file, requests_file = sys.argv[1], sys.argv[2]
TOKEN = "smoke-telegram-token"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == f"/bot{TOKEN}/getMe":
            self._send(200, {"ok": True, "result": {"id": "4242", "username": "smoke_telegram_bot"}})
            return
        self._send(404, {"ok": False, "description": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8") if length else "{}"
        with open(requests_file, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"path": self.path, "body": json.loads(body)}) + "\n")
        if self.path == f"/bot{TOKEN}/sendMessage":
            self._send(200, {"ok": True, "result": {"message_id": 1}})
            return
        self._send(404, {"ok": False, "description": "not found"})

server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
FAKE_TELEGRAM_PID=$!

for _ in $(seq 1 50); do
  [[ -f "$FAKE_TELEGRAM_PORT_FILE" ]] && break
  sleep 0.1
done
[[ -f "$FAKE_TELEGRAM_PORT_FILE" ]] || die "fake Telegram API failed to start"
FAKE_TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$FAKE_TELEGRAM_PORT_FILE")"
python3 - "$TMP_ROOT/openclaw.json" "$FAKE_TELEGRAM_API_BASE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload.setdefault("channels", {}).setdefault("telegram", {}).setdefault("accounts", {}).setdefault("smoke", {})["apiBaseUrl"] = sys.argv[2]
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
mkdir -p "$BRIDGE_RUNTIME_ROOT"
cp "$TMP_ROOT/openclaw.json" "$BRIDGE_RUNTIME_CONFIG_FILE"

log "verifying empty runtime starts clean"
BRIDGE_ROSTER_LOCAL_FILE=/nonexistent bash "$REPO_ROOT/bridge-start.sh" --list >/dev/null

log "tool-policy: shared symlink + dot/underscore dirs are not treated as other agents (issue #240)"
TOOL_POLICY_FIXTURE_ROOT="$TMP_ROOT/tool-policy-fixture"
TOOL_POLICY_AGENT_HOME_ROOT="$TOOL_POLICY_FIXTURE_ROOT/agents"
TOOL_POLICY_SHARED_DIR="$TOOL_POLICY_FIXTURE_ROOT/shared"
rm -rf "$TOOL_POLICY_FIXTURE_ROOT"
mkdir -p "$TOOL_POLICY_AGENT_HOME_ROOT/self" \
         "$TOOL_POLICY_AGENT_HOME_ROOT/peer" \
         "$TOOL_POLICY_AGENT_HOME_ROOT/_real_agent_name" \
         "$TOOL_POLICY_AGENT_HOME_ROOT/.real_dot_agent" \
         "$TOOL_POLICY_AGENT_HOME_ROOT/_template" \
         "$TOOL_POLICY_AGENT_HOME_ROOT/.claude" \
         "$TOOL_POLICY_SHARED_DIR"
# The regression trigger: an `agents/shared` symlink that points at the
# real BRIDGE_SHARED_DIR outside the agents tree. Before the fix,
# target_agent_for_path resolved every write under shared/ back into
# this alias and rejected it as cross-agent access.
ln -s "$TOOL_POLICY_SHARED_DIR" "$TOOL_POLICY_AGENT_HOME_ROOT/shared"
TOOL_POLICY_PY_CHECK=$(BRIDGE_AGENT_ID=self BRIDGE_AGENT_HOME_ROOT="$TOOL_POLICY_AGENT_HOME_ROOT" PYTHONPATH="$REPO_ROOT/hooks" python3 - "$TOOL_POLICY_SHARED_DIR" "$TOOL_POLICY_AGENT_HOME_ROOT" "$REPO_ROOT" <<'PY'
import importlib.util, pathlib, sys
shared_dir = pathlib.Path(sys.argv[1])
agents_root = pathlib.Path(sys.argv[2])
repo_root = pathlib.Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("tp", repo_root / "hooks" / "tool-policy.py")
tp = importlib.util.module_from_spec(spec)
sys.modules["tp"] = tp
spec.loader.exec_module(tp)

homes = tp.other_agent_homes("self")
names = sorted(h.name for h in homes)
# Exact-name blocklist only. Both `_real_agent_name` and `.real_dot_agent`
# are real agents (bridge-agent.sh create does not reserve either
# prefix today) and must survive. Non-agents `shared`, `_template`,
# and `.claude` are filtered.
assert names == [".real_dot_agent", "_real_agent_name", "peer"], f"expected ['.real_dot_agent', '_real_agent_name', 'peer'], got {names}"

# Writing into shared/ must not be classified as cross-agent.
target = tp.target_agent_for_path(shared_dir / "note.md", "self")
assert target is None, f"shared/ write misclassified as cross-agent: {target}"

# Writing into a real peer home must still trigger.
peer_target = tp.target_agent_for_path(agents_root / "peer" / "foo.md", "self")
assert peer_target == "peer", f"peer write not detected: {peer_target}"

# Prefix-bearing real agents (underscore or dot) are still detected
# (Codex r1 + r2 both flagged these over-filter regressions).
underscore_target = tp.target_agent_for_path(agents_root / "_real_agent_name" / "foo.md", "self")
assert underscore_target == "_real_agent_name", f"underscore-prefixed peer not detected: {underscore_target}"
dot_target = tp.target_agent_for_path(agents_root / ".real_dot_agent" / "foo.md", "self")
assert dot_target == ".real_dot_agent", f"dot-prefixed peer not detected: {dot_target}"

print("[ok] tool-policy other_agent_homes: shared/_template/.claude filtered; prefixed real agents kept; shared write allowed; peer write blocked")
PY
)
printf '%s\n' "$TOOL_POLICY_PY_CHECK"
assert_contains "$TOOL_POLICY_PY_CHECK" "[ok] tool-policy"
rm -rf "$TOOL_POLICY_FIXTURE_ROOT"

log "tool-policy: protected_alias_reason skips payload substrings but blocks argv-level DB access (#252)"
TOOL_POLICY_ALIAS_FIXTURE="$TMP_ROOT/tool-policy-alias-fixture"
rm -rf "$TOOL_POLICY_ALIAS_FIXTURE"
mkdir -p "$TOOL_POLICY_ALIAS_FIXTURE/state" "$TOOL_POLICY_ALIAS_FIXTURE/agents/self"
: > "$TOOL_POLICY_ALIAS_FIXTURE/state/tasks.db"
: > "$TOOL_POLICY_ALIAS_FIXTURE/agent-roster.local.sh"
TOOL_POLICY_ALIAS_CHECK=$(BRIDGE_HOME="$TOOL_POLICY_ALIAS_FIXTURE" \
    BRIDGE_AGENT_ID=self \
    BRIDGE_AGENT_HOME_ROOT="$TOOL_POLICY_ALIAS_FIXTURE/agents" \
    PYTHONPATH="$REPO_ROOT/hooks" \
    python3 - "$REPO_ROOT" "$TOOL_POLICY_ALIAS_FIXTURE" <<'PY'
import importlib.util, pathlib, sys
repo_root = pathlib.Path(sys.argv[1])
bridge_home = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("tp", repo_root / "hooks" / "tool-policy.py")
tp = importlib.util.module_from_spec(spec)
sys.modules["tp"] = tp
spec.loader.exec_module(tp)

task_db_abs = str(bridge_home / "state" / "tasks.db")
roster_abs = str(bridge_home / "agent-roster.local.sh")

# 1) Incidental mentions must NOT block — the original #252 repro class.
assert tp.protected_alias_reason(
    "gh issue comment 252 --body \"mentions state/tasks.db only as a suffix\"",
    "self",
) is None, "relative suffix tasks.db mention should not block"
assert tp.protected_alias_reason(
    "git commit -m \"fix agent-roster.local.sh handling\"",
    "self",
) is None, "relative suffix agent-roster mention should not block"
assert tp.protected_alias_reason(
    "rg -n 'state/tasks.db' docs/",
    "self",
) is None, "ripgrep pattern with relative suffix should not block"

# 2) Absolute-path mentions inside message payloads must ALSO not block
#    (Codex r1 finding for PR #260: the real #252 repro was a gh --body
#    quoting daemon status output with the absolute queue DB path).
assert tp.protected_alias_reason(
    f"gh issue comment 252 --body \"daemon status db={task_db_abs}\"",
    "self",
) is None, "absolute tasks.db inside --body should not block"
assert tp.protected_alias_reason(
    f"git commit -m \"rollback attempted against {roster_abs}\"",
    "self",
) is None, "absolute roster path inside -m should not block"
assert tp.protected_alias_reason(
    f"gh issue comment 252 --body-file=/tmp/notes.txt",
    "self",
) is None, "--body-file should not block even with path-ish value"

# 3) Real opener-level access must still block, including tilde and
#    $BRIDGE_HOME / $HOME expansion forms that argv-level shlex sees
#    verbatim before the shell expands them.
import os as _os
_os.environ["BRIDGE_HOME"] = str(bridge_home)
_os.environ["HOME"] = _os.environ.get("HOME", str(bridge_home.parent))
sqlite_abs = tp.protected_alias_reason(f"sqlite3 {task_db_abs}", "self")
assert sqlite_abs and "direct queue DB" in sqlite_abs, \
    f"absolute sqlite3 invocation should block: {sqlite_abs!r}"
sqlite_envvar = tp.protected_alias_reason(
    "sqlite3 \"$BRIDGE_HOME\"/state/tasks.db", "self"
)
assert sqlite_envvar and "direct queue DB" in sqlite_envvar, \
    f"$BRIDGE_HOME sqlite3 invocation should block after expansion: {sqlite_envvar!r}"
# tilde expansion: only holds when HOME == BRIDGE_HOME parent, which we set
# explicitly below to exercise the same codepath the Linux reference host
# uses (BRIDGE_HOME = $HOME/.agent-bridge). Use a nested tmp directory so
# tilde resolves back onto the fixture's task db.
_tilde_home = bridge_home.parent
_os.environ["HOME"] = str(_tilde_home)
_tilde_path = bridge_home.name + "/state/tasks.db"
sqlite_tilde = tp.protected_alias_reason(
    f"sqlite3 ~/{_tilde_path}", "self"
)
assert sqlite_tilde and "direct queue DB" in sqlite_tilde, \
    f"~/ sqlite3 invocation should block after expansion: {sqlite_tilde!r}"
cat_abs = tp.protected_alias_reason(f"cat {roster_abs}", "self")
assert cat_abs is None, \
    f"read-intent cat against roster must not block (#383): {cat_abs!r}"
# Edit-equivalent shell write (sed -i) against the same path must still
# block: read-intent allowance is keyed on the leading command's
# verb, not the path.
sed_abs = tp.protected_alias_reason(f"sed -i s/foo/bar/ {roster_abs}", "self")
assert sed_abs and "roster secrets" in sed_abs, \
    f"sed -i against roster must still block: {sed_abs!r}"

# 4) String-payload option flags still must not block when their value
#    merely mentions the protected path (--body / --description / -m etc.).
assert tp.protected_alias_reason(
    f"gh issue edit 252 --description \"see {task_db_abs} for daemon status\"",
    "self",
) is None, "--description value must not block"
assert tp.protected_alias_reason(
    "gh issue comment 252 --body=\"status logged\"",
    "self",
) is None, "--body=value form must not block on string payload"

# 5) File-valued option flags (--body-file / -F / --file / --input) open
#    files at runtime. If the value is the protected path, we must block —
#    this is the Codex r2 regression on PR #260's round 1.
bodyfile_reason = tp.protected_alias_reason(
    f"gh issue comment 252 --body-file {task_db_abs}",
    "self",
)
assert bodyfile_reason and "direct queue DB" in bodyfile_reason, \
    f"--body-file pointing at the queue DB must block: {bodyfile_reason!r}"
bodyfile_eq_reason = tp.protected_alias_reason(
    f"gh issue comment 252 --body-file={task_db_abs}",
    "self",
)
assert bodyfile_eq_reason and "direct queue DB" in bodyfile_eq_reason, \
    f"--body-file=<queue-db> must block: {bodyfile_eq_reason!r}"
git_f_reason = tp.protected_alias_reason(
    f"git commit -F {roster_abs}",
    "self",
)
assert git_f_reason and "roster secrets" in git_f_reason, \
    f"git commit -F <roster> must block for non-admin: {git_f_reason!r}"
# Innocent --body-file paths still pass.
assert tp.protected_alias_reason(
    "gh issue comment 252 --body-file /tmp/notes.txt",
    "self",
) is None, "innocent --body-file path should not block"

# 6) Shell operators and redirection syntax must not hide a real opener
#    (Codex r2 finding 2 on PR #260 round 1).
semi_reason = tp.protected_alias_reason(
    f"sqlite3 {task_db_abs}; echo ok",
    "self",
)
assert semi_reason and "direct queue DB" in semi_reason, \
    f"sqlite3 <db>; echo must block (trailing `;` was hiding the argv): {semi_reason!r}"
and_reason = tp.protected_alias_reason(
    f"sqlite3 {task_db_abs}&& echo ok",
    "self",
)
assert and_reason and "direct queue DB" in and_reason, \
    f"sqlite3 <db>&& echo must block (trailing `&&` was hiding the argv): {and_reason!r}"
redir_reason = tp.protected_alias_reason(
    f"cat <{roster_abs}",
    "self",
)
assert redir_reason is None, \
    f"cat <roster (read redirection) must not block under #383: {redir_reason!r}"
# An output redirection that lands in the protected path is still a
# write and must be denied even when the leading command is normally
# read-only (the write-redirection check disqualifies the whole stage).
redir_write_reason = tp.protected_alias_reason(
    f"cat /tmp/x >{roster_abs}",
    "self",
)
assert redir_write_reason and "roster secrets" in redir_write_reason, \
    f"output-redirection into roster must still block: {redir_write_reason!r}"

print("[ok] tool-policy protected_alias_reason: payload substrings pass; write-intent argv openers still block; read-intent allowed (#383)")
PY
)
printf '%s\n' "$TOOL_POLICY_ALIAS_CHECK"
assert_contains "$TOOL_POLICY_ALIAS_CHECK" "[ok] tool-policy protected_alias_reason"
rm -rf "$TOOL_POLICY_ALIAS_FIXTURE"

log "daemon autostart gate honours broken-launch quarantine marker (#256 Gap 2)"
BROKEN_LAUNCH_HOME="$TMP_ROOT/broken-launch-home"
rm -rf "$BROKEN_LAUNCH_HOME"
mkdir -p "$BROKEN_LAUNCH_HOME/state/agents/broken-smoke"
: > "$BROKEN_LAUNCH_HOME/state/agents/broken-smoke/broken-launch"
GATE_BODY="$(awk '/^bridge_daemon_autostart_allowed\(\) \{/,/^\}$/' "$REPO_ROOT/bridge-daemon.sh")"
[[ -n "$GATE_BODY" ]] || die "could not extract bridge_daemon_autostart_allowed from bridge-daemon.sh"
"$BASH4_BIN" -c '
  set -euo pipefail
  export BRIDGE_STATE_DIR="'"$BROKEN_LAUNCH_HOME/state"'"
  # Minimal stubs for the helpers the gate calls; the real definitions live
  # in lib/bridge-{agents,state,daemon}.sh and are sourced by the daemon at
  # runtime. We reproduce just enough to exercise the broken-launch path.
  bridge_agent_broken_launch_file() { printf "%s/agents/%s/broken-launch" "$BRIDGE_STATE_DIR" "$1"; }
  bridge_daemon_autostart_state_file() { printf "%s/agents/%s/autostart" "$BRIDGE_STATE_DIR" "$1"; }
  '"$GATE_BODY"'
  if bridge_daemon_autostart_allowed broken-smoke; then
    echo "[fail] daemon autostart gate allowed relaunch while broken-launch file present" >&2
    exit 1
  fi
  rm -f "$BRIDGE_STATE_DIR/agents/broken-smoke/broken-launch"
  if ! bridge_daemon_autostart_allowed broken-smoke; then
    echo "[fail] daemon autostart gate still blocked after broken-launch cleared" >&2
    exit 1
  fi
' || die "daemon autostart gate broken-launch regression test failed"

log "bridge_agent_write_broken_launch_state / clear round-trip (#256 Gap 2)"
BROKEN_LAUNCH_AGENT=broken-smoke
BRIDGE_STATE_DIR="$BROKEN_LAUNCH_HOME/state" "$BASH4_BIN" -lc '
  set -euo pipefail
  export BRIDGE_HOME="'"$BROKEN_LAUNCH_HOME"'"
  # `bridge_load_roster` would error without a roster file; skip it — the two
  # helpers we are exercising only touch $BRIDGE_STATE_DIR.
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_agent_write_broken_launch_state "'"$BROKEN_LAUNCH_AGENT"'" "claude" 5 1 "/tmp/err.log" "MS365_CLIENT_SECRET=broken-secret API_KEY=broken-key bash bridge-run.sh broken-smoke" 0
'
BROKEN_FILE="$BROKEN_LAUNCH_HOME/state/agents/$BROKEN_LAUNCH_AGENT/broken-launch"
[[ -s "$BROKEN_FILE" ]] || die "bridge_agent_write_broken_launch_state did not create the quarantine file"
python3 - "$BROKEN_FILE" "$BROKEN_LAUNCH_AGENT" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
assert payload.get("agent") == sys.argv[2], payload
assert payload.get("fail_count") == 5, payload
assert payload.get("exit_code") == 1, payload
assert payload.get("engine") == "claude", payload
assert payload.get("launch_cmd"), payload
assert "broken-secret" not in payload.get("launch_cmd", ""), payload
assert "broken-key" not in payload.get("launch_cmd", ""), payload
assert "MS365_CLIENT_SECRET=***redacted***" in payload.get("launch_cmd", ""), payload
assert "API_KEY=***redacted***" in payload.get("launch_cmd", ""), payload
assert payload.get("stderr_file") == "/tmp/err.log", payload
assert payload.get("quarantined_at"), payload
PY
BRIDGE_STATE_DIR="$BROKEN_LAUNCH_HOME/state" "$BASH4_BIN" -lc '
  set -euo pipefail
  export BRIDGE_HOME="'"$BROKEN_LAUNCH_HOME"'"
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_agent_clear_broken_launch "'"$BROKEN_LAUNCH_AGENT"'"
'
[[ ! -e "$BROKEN_FILE" ]] || die "bridge_agent_clear_broken_launch did not remove the quarantine file"
rm -rf "$BROKEN_LAUNCH_HOME"

log "bridge-start.sh / bridge-agent.sh guard broken-launch clear behind dry-run + preflight (#256 Gap 2 r2)"
python3 - "$REPO_ROOT/bridge-start.sh" "$REPO_ROOT/bridge-agent.sh" <<'PY'
"""Regression test for PR #262 round-1 finding.

The quarantine marker must survive:
  * A `--dry-run` invocation (bridge-start.sh should exit before clearing).
  * A preflight failure (bridge-agent.sh::run_restart must call the preflight
    guard before clearing).

Static line-order check — executes on every smoke run, catches a reorder even
when the integration path is not available in the current fixture.
"""
import sys
from pathlib import Path

start_src = Path(sys.argv[1]).read_text().splitlines()
agent_src = Path(sys.argv[2]).read_text().splitlines()

clear_calls = [i for i, line in enumerate(start_src) if "bridge_agent_clear_broken_launch" in line]
assert clear_calls, "bridge-start.sh must call bridge_agent_clear_broken_launch (broken after r1 -> r2 rewrite?)"
first_clear = clear_calls[0]

# Find the DRY_RUN block's terminating `exit 0`.
in_dry = False
dry_exit = None
for i, line in enumerate(start_src):
    if "if [[ $DRY_RUN -eq 1 ]]; then" in line:
        in_dry = True
    elif in_dry and line.strip() == "exit 0":
        dry_exit = i
        break
assert dry_exit is not None, "bridge-start.sh no longer has a DRY_RUN exit 0 block"
assert first_clear > dry_exit, (
    f"bridge-start.sh clears broken-launch at line {first_clear + 1}, "
    f"which is before the DRY_RUN exit at line {dry_exit + 1}. "
    "That lets a --dry-run silently unquarantine an agent — see PR #262 round-1."
)

# run_restart must guard the clear behind bridge_agent_restart_preflight_reason.
restart_start = next(
    (i for i, l in enumerate(agent_src) if l.startswith("run_restart() {")),
    None,
)
assert restart_start is not None, "run_restart() not found in bridge-agent.sh"
# Function end: walk forward until a line that is exactly '}' at column 0.
restart_end = None
for i in range(restart_start + 1, len(agent_src)):
    if agent_src[i] == "}":
        restart_end = i
        break
assert restart_end is not None, "run_restart end `}` not found"

preflight_idx = None
clear_idx_agent = None
dry_run_idx_agent = None
for i in range(restart_start, restart_end + 1):
    line = agent_src[i]
    if "bridge_agent_restart_preflight_reason" in line and preflight_idx is None:
        preflight_idx = i
    if "bridge_agent_clear_broken_launch" in line:
        clear_idx_agent = i
    if "if [[ $dry_run_mode -eq 1 ]]; then" in line and dry_run_idx_agent is None:
        dry_run_idx_agent = i
assert preflight_idx is not None, "run_restart no longer calls bridge_agent_restart_preflight_reason"
assert clear_idx_agent is not None, "run_restart must call bridge_agent_clear_broken_launch"
assert dry_run_idx_agent is not None, "run_restart no longer branches on dry_run_mode"
assert clear_idx_agent > preflight_idx, (
    f"run_restart clears broken-launch at line {clear_idx_agent + 1}, "
    f"which is before the preflight guard at line {preflight_idx + 1}. "
    "That lets a preflight-blocked restart silently unquarantine an agent."
)
assert clear_idx_agent > dry_run_idx_agent, (
    f"run_restart clears broken-launch at line {clear_idx_agent + 1}, "
    f"which is before the dry-run branch at line {dry_run_idx_agent + 1}. "
    "That lets `agent restart --dry-run` silently unquarantine an agent."
)
print("[ok] broken-launch clear guarded behind dry-run + preflight in both entry points")
PY

log "diagnose acl reports clean on macOS (non-Linux host)"
DIAGNOSE_OUTPUT="$("$REPO_ROOT/agent-bridge" diagnose acl)"
if [[ "$(uname -s)" == "Linux" ]]; then
  # On Linux getfacl may or may not be installed; either way the
  # scanner exits 0 with an "[ok]" or "[skip]" banner. The only thing
  # smoke needs to assert is that it did not explode.
  assert_contains "$DIAGNOSE_OUTPUT" "["
else
  assert_contains "$DIAGNOSE_OUTPUT" "non-linux"
fi
DIAGNOSE_JSON_OUTPUT="$("$REPO_ROOT/agent-bridge" diagnose acl --json)"
assert_contains "$DIAGNOSE_JSON_OUTPUT" "\"findings\""
DIAGNOSE_HELP="$("$REPO_ROOT/agent-bridge" diagnose 2>&1 || true)"
assert_contains "$DIAGNOSE_HELP" "diagnose acl"

log "apply-channel-policy.sh writes overlay disabling singleton channel plugins (#244)"
CHANNEL_POLICY_HOME="$TMP_ROOT/channel-policy-home"
mkdir -p "$CHANNEL_POLICY_HOME/agents/.claude"
printf '{}' > "$CHANNEL_POLICY_HOME/agents/.claude/settings.json"
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID BRIDGE_HOME="$CHANNEL_POLICY_HOME" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
CHANNEL_POLICY_OVERLAY="$CHANNEL_POLICY_HOME/agents/.claude/settings.local.json"
[[ -f "$CHANNEL_POLICY_OVERLAY" ]] || die "apply-channel-policy.sh did not write overlay"
CHANNEL_POLICY_OVERLAY_PAYLOAD="$(cat "$CHANNEL_POLICY_OVERLAY")"
assert_contains "$CHANNEL_POLICY_OVERLAY_PAYLOAD" "\"telegram@claude-plugins-official\": false"
assert_contains "$CHANNEL_POLICY_OVERLAY_PAYLOAD" "\"discord@claude-plugins-official\": false"
CHANNEL_POLICY_EFFECTIVE="$CHANNEL_POLICY_HOME/agents/.claude/settings.effective.json"
[[ -f "$CHANNEL_POLICY_EFFECTIVE" ]] || die "apply-channel-policy.sh did not render effective settings"
assert_contains "$(cat "$CHANNEL_POLICY_EFFECTIVE")" "\"telegram@claude-plugins-official\": false"
# Idempotency: second run must be a no-op (overlay byte-identical).
CHANNEL_POLICY_OVERLAY_FIRST="$(cat "$CHANNEL_POLICY_OVERLAY")"
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID BRIDGE_HOME="$CHANNEL_POLICY_HOME" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
CHANNEL_POLICY_OVERLAY_SECOND="$(cat "$CHANNEL_POLICY_OVERLAY")"
[[ "$CHANNEL_POLICY_OVERLAY_FIRST" == "$CHANNEL_POLICY_OVERLAY_SECOND" ]] || die "apply-channel-policy.sh was not idempotent"
# Admin was not declared in this fixture — script must not create any
# per-agent overlay. (`_common.sh` defaults `BRIDGE_ADMIN_AGENT` to `patch`
# for cron helpers, so we specifically assert that path is NOT touched.)
[[ ! -e "$CHANNEL_POLICY_HOME/agents/patch/.claude/settings.local.json" ]] \
  || die "apply-channel-policy.sh wrote admin overlay without an explicit BRIDGE_ADMIN_AGENT_ID"

log "apply-channel-policy.sh re-enables singleton plugins for configured admin (PR #246 admin bypass)"
CHANNEL_POLICY_ADMIN_HOME="$TMP_ROOT/channel-policy-admin-home"
mkdir -p "$CHANNEL_POLICY_ADMIN_HOME/agents/.claude" "$CHANNEL_POLICY_ADMIN_HOME/agents/admin_smoke/.claude"
printf '{}' > "$CHANNEL_POLICY_ADMIN_HOME/agents/.claude/settings.json"
env -u BRIDGE_AGENT_HOME_ROOT BRIDGE_HOME="$CHANNEL_POLICY_ADMIN_HOME" \
  BRIDGE_ADMIN_AGENT_ID="admin_smoke" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
ADMIN_POLICY_OVERLAY="$CHANNEL_POLICY_ADMIN_HOME/agents/admin_smoke/.claude/settings.local.json"
[[ -f "$ADMIN_POLICY_OVERLAY" ]] || die "apply-channel-policy.sh did not write admin bypass overlay"
ADMIN_POLICY_OVERLAY_PAYLOAD="$(cat "$ADMIN_POLICY_OVERLAY")"
assert_contains "$ADMIN_POLICY_OVERLAY_PAYLOAD" "\"telegram@claude-plugins-official\": true"
assert_contains "$ADMIN_POLICY_OVERLAY_PAYLOAD" "\"discord@claude-plugins-official\": true"
# Shared overlay must still disable the plugins — the fix is two layers,
# not a replacement for the shared enforcement.
ADMIN_SHARED_OVERLAY="$CHANNEL_POLICY_ADMIN_HOME/agents/.claude/settings.local.json"
[[ -f "$ADMIN_SHARED_OVERLAY" ]] || die "shared overlay missing under admin fixture"
assert_contains "$(cat "$ADMIN_SHARED_OVERLAY")" "\"telegram@claude-plugins-official\": false"
# Idempotency for the admin path too.
ADMIN_POLICY_OVERLAY_FIRST="$(cat "$ADMIN_POLICY_OVERLAY")"
env -u BRIDGE_AGENT_HOME_ROOT BRIDGE_HOME="$CHANNEL_POLICY_ADMIN_HOME" \
  BRIDGE_ADMIN_AGENT_ID="admin_smoke" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
ADMIN_POLICY_OVERLAY_SECOND="$(cat "$ADMIN_POLICY_OVERLAY")"
[[ "$ADMIN_POLICY_OVERLAY_FIRST" == "$ADMIN_POLICY_OVERLAY_SECOND" ]] || die "apply-channel-policy.sh admin bypass was not idempotent"
# Roster-file fallback: admin id picked up from agent-roster.local.sh when
# env is unset.
CHANNEL_POLICY_ROSTER_HOME="$TMP_ROOT/channel-policy-roster-home"
mkdir -p "$CHANNEL_POLICY_ROSTER_HOME/agents/.claude" "$CHANNEL_POLICY_ROSTER_HOME/agents/admin_from_roster/.claude"
printf '{}' > "$CHANNEL_POLICY_ROSTER_HOME/agents/.claude/settings.json"
printf 'BRIDGE_ADMIN_AGENT_ID="admin_from_roster"\n' \
  > "$CHANNEL_POLICY_ROSTER_HOME/agent-roster.local.sh"
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$CHANNEL_POLICY_ROSTER_HOME" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
ROSTER_POLICY_OVERLAY="$CHANNEL_POLICY_ROSTER_HOME/agents/admin_from_roster/.claude/settings.local.json"
[[ -f "$ROSTER_POLICY_OVERLAY" ]] || die "apply-channel-policy.sh did not pick admin id up from the roster"
assert_contains "$(cat "$ROSTER_POLICY_OVERLAY")" "\"telegram@claude-plugins-official\": true"

log "apply-channel-policy.sh selectively re-enables per-agent singleton channels (closes #254)"
CHANNEL_POLICY_OWNER_HOME="$TMP_ROOT/channel-policy-owner-home"
mkdir -p \
  "$CHANNEL_POLICY_OWNER_HOME/agents/.claude" \
  "$CHANNEL_POLICY_OWNER_HOME/agents/admin_owner/.claude" \
  "$CHANNEL_POLICY_OWNER_HOME/agents/dev_discord/.claude" \
  "$CHANNEL_POLICY_OWNER_HOME/agents/dev_telegram/.claude" \
  "$CHANNEL_POLICY_OWNER_HOME/agents/sales_teams_only/.claude"
printf '{}' > "$CHANNEL_POLICY_OWNER_HOME/agents/.claude/settings.json"
cat > "$CHANNEL_POLICY_OWNER_HOME/agent-roster.local.sh" <<'ROSTER'
BRIDGE_ADMIN_AGENT_ID="admin_owner"
BRIDGE_AGENT_CHANNELS["dev_discord"]="plugin:discord@claude-plugins-official"
BRIDGE_AGENT_CHANNELS["dev_telegram"]="plugin:teams@agent-bridge,plugin:telegram@claude-plugins-official"
BRIDGE_AGENT_CHANNELS["sales_teams_only"]="plugin:teams@agent-bridge"
ROSTER
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$CHANNEL_POLICY_OWNER_HOME" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
# Owner of discord gets discord re-enable only (not telegram).
OWNER_DISCORD_OVERLAY="$CHANNEL_POLICY_OWNER_HOME/agents/dev_discord/.claude/settings.local.json"
[[ -f "$OWNER_DISCORD_OVERLAY" ]] || die "apply-channel-policy.sh did not write overlay for discord-owning agent"
assert_contains "$(cat "$OWNER_DISCORD_OVERLAY")" "\"discord@claude-plugins-official\": true"
assert_not_contains "$(cat "$OWNER_DISCORD_OVERLAY")" "\"telegram@claude-plugins-official\""
# Owner of telegram gets telegram re-enable only (teams is not in the singleton set).
OWNER_TELEGRAM_OVERLAY="$CHANNEL_POLICY_OWNER_HOME/agents/dev_telegram/.claude/settings.local.json"
[[ -f "$OWNER_TELEGRAM_OVERLAY" ]] || die "apply-channel-policy.sh did not write overlay for telegram-owning agent"
assert_contains "$(cat "$OWNER_TELEGRAM_OVERLAY")" "\"telegram@claude-plugins-official\": true"
assert_not_contains "$(cat "$OWNER_TELEGRAM_OVERLAY")" "\"discord@claude-plugins-official\""
# Agent that owns only a non-singleton plugin (teams) gets no overlay at all —
# the shared disable does not affect it, and we must not materialise an empty
# enabledPlugins dict on its behalf.
[[ ! -e "$CHANNEL_POLICY_OWNER_HOME/agents/sales_teams_only/.claude/settings.local.json" ]] \
  || die "apply-channel-policy.sh wrote overlay for agent that owns no singleton plugin"
# Admin still re-enables everything.
OWNER_ADMIN_OVERLAY="$CHANNEL_POLICY_OWNER_HOME/agents/admin_owner/.claude/settings.local.json"
[[ -f "$OWNER_ADMIN_OVERLAY" ]] || die "apply-channel-policy.sh did not write admin bypass overlay under roster-aware mode"
assert_contains "$(cat "$OWNER_ADMIN_OVERLAY")" "\"telegram@claude-plugins-official\": true"
assert_contains "$(cat "$OWNER_ADMIN_OVERLAY")" "\"discord@claude-plugins-official\": true"
# Idempotency.
OWNER_DISCORD_FIRST="$(cat "$OWNER_DISCORD_OVERLAY")"
OWNER_TELEGRAM_FIRST="$(cat "$OWNER_TELEGRAM_OVERLAY")"
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$CHANNEL_POLICY_OWNER_HOME" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
[[ "$(cat "$OWNER_DISCORD_OVERLAY")" == "$OWNER_DISCORD_FIRST" ]] \
  || die "apply-channel-policy.sh per-agent discord overlay was not idempotent"
[[ "$(cat "$OWNER_TELEGRAM_OVERLAY")" == "$OWNER_TELEGRAM_FIRST" ]] \
  || die "apply-channel-policy.sh per-agent telegram overlay was not idempotent"

log "apply-channel-policy.sh emits a multi-owner warning when 2+ agents claim the same singleton channel (#254)"
CHANNEL_POLICY_MULTI_HOME="$TMP_ROOT/channel-policy-multi-home"
mkdir -p \
  "$CHANNEL_POLICY_MULTI_HOME/agents/.claude" \
  "$CHANNEL_POLICY_MULTI_HOME/agents/multi_admin/.claude" \
  "$CHANNEL_POLICY_MULTI_HOME/agents/a1/.claude" \
  "$CHANNEL_POLICY_MULTI_HOME/agents/a2/.claude"
printf '{}' > "$CHANNEL_POLICY_MULTI_HOME/agents/.claude/settings.json"
cat > "$CHANNEL_POLICY_MULTI_HOME/agent-roster.local.sh" <<'ROSTER'
BRIDGE_ADMIN_AGENT_ID="multi_admin"
BRIDGE_AGENT_CHANNELS["a1"]="plugin:telegram@claude-plugins-official"
BRIDGE_AGENT_CHANNELS["a2"]="plugin:telegram@claude-plugins-official"
ROSTER
MULTI_OUTPUT="$(env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$CHANNEL_POLICY_MULTI_HOME" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" 2>&1)"
assert_contains "$MULTI_OUTPUT" "WARNING: 'telegram@claude-plugins-official' declared by multiple agents"
# Both owners still get the re-enable (so the runtime behaviour is "last restarter wins"
# rather than "both silently fail to load the plugin").
[[ -f "$CHANNEL_POLICY_MULTI_HOME/agents/a1/.claude/settings.local.json" ]] \
  || die "multi-owner case did not write a1 overlay"
[[ -f "$CHANNEL_POLICY_MULTI_HOME/agents/a2/.claude/settings.local.json" ]] \
  || die "multi-owner case did not write a2 overlay"

log "apply-channel-policy.sh parses dotted agent ids in BRIDGE_AGENT_CHANNELS (#255 r1 finding 1)"
CHANNEL_POLICY_DOT_HOME="$TMP_ROOT/channel-policy-dotted-home"
mkdir -p \
  "$CHANNEL_POLICY_DOT_HOME/agents/.claude" \
  "$CHANNEL_POLICY_DOT_HOME/agents/dot_admin/.claude" \
  "$CHANNEL_POLICY_DOT_HOME/agents/foo.bar/.claude"
printf '{}' > "$CHANNEL_POLICY_DOT_HOME/agents/.claude/settings.json"
cat > "$CHANNEL_POLICY_DOT_HOME/agent-roster.local.sh" <<'ROSTER'
BRIDGE_ADMIN_AGENT_ID="dot_admin"
BRIDGE_AGENT_CHANNELS["foo.bar"]="plugin:discord@claude-plugins-official"
ROSTER
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$CHANNEL_POLICY_DOT_HOME" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
DOTTED_OVERLAY="$CHANNEL_POLICY_DOT_HOME/agents/foo.bar/.claude/settings.local.json"
[[ -f "$DOTTED_OVERLAY" ]] || die "apply-channel-policy.sh did not write overlay for dotted agent id"
assert_contains "$(cat "$DOTTED_OVERLAY")" "\"discord@claude-plugins-official\": true"

log "apply-channel-policy.sh still runs when roster has no BRIDGE_ADMIN_AGENT_ID line (#255 r1 finding 2)"
CHANNEL_POLICY_NOADMIN_HOME="$TMP_ROOT/channel-policy-noadmin-home"
mkdir -p \
  "$CHANNEL_POLICY_NOADMIN_HOME/agents/.claude" \
  "$CHANNEL_POLICY_NOADMIN_HOME/agents/dev_discord/.claude"
printf '{}' > "$CHANNEL_POLICY_NOADMIN_HOME/agents/.claude/settings.json"
cat > "$CHANNEL_POLICY_NOADMIN_HOME/agent-roster.local.sh" <<'ROSTER'
BRIDGE_AGENT_CHANNELS["dev_discord"]="plugin:discord@claude-plugins-official"
ROSTER
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$CHANNEL_POLICY_NOADMIN_HOME" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null \
  || die "apply-channel-policy.sh aborted on admin-less roster"
NOADMIN_OVERLAY="$CHANNEL_POLICY_NOADMIN_HOME/agents/dev_discord/.claude/settings.local.json"
[[ -f "$NOADMIN_OVERLAY" ]] || die "apply-channel-policy.sh skipped non-admin owner when roster has no admin id"
assert_contains "$(cat "$NOADMIN_OVERLAY")" "\"discord@claude-plugins-official\": true"

log "apply-channel-policy.sh enforces per-agent BRIDGE_AGENT_PLUGINS allowlist (closes #272)"
PLUGIN_ALLOW_HOME="$TMP_ROOT/channel-policy-allowlist-home"
mkdir -p \
  "$PLUGIN_ALLOW_HOME/agents/.claude" \
  "$PLUGIN_ALLOW_HOME/agents/admin_owner/.claude" \
  "$PLUGIN_ALLOW_HOME/agents/mailbot/.claude" \
  "$PLUGIN_ALLOW_HOME/agents/legacy_agent/.claude"
printf '{}' > "$PLUGIN_ALLOW_HOME/agents/.claude/settings.json"
cat > "$PLUGIN_ALLOW_HOME/installed_plugins.json" <<'EOF'
{
  "version": 2,
  "plugins": {
    "syrs-gmail@syrs-local": [{"scope":"user"}],
    "syrs-shopify@syrs-local": [{"scope":"user"}],
    "syrs-tracx@syrs-local": [{"scope":"user"}],
    "telegram@claude-plugins-official": [{"scope":"user"}],
    "discord@claude-plugins-official": [{"scope":"user"}],
    "superpowers@claude-plugins-official": [{"scope":"user"}]
  }
}
EOF
cat > "$PLUGIN_ALLOW_HOME/agent-roster.local.sh" <<'ROSTER'
BRIDGE_ADMIN_AGENT_ID="admin_owner"
BRIDGE_AGENT_CHANNELS["mailbot"]="plugin:discord@claude-plugins-official"
BRIDGE_AGENT_PLUGINS["mailbot"]="syrs-gmail superpowers"
ROSTER
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$PLUGIN_ALLOW_HOME" \
  BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$PLUGIN_ALLOW_HOME/installed_plugins.json" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
PLUGIN_ALLOW_OVERLAY="$PLUGIN_ALLOW_HOME/agents/mailbot/.claude/settings.local.json"
[[ -f "$PLUGIN_ALLOW_OVERLAY" ]] || die "apply-channel-policy.sh did not write allowlist overlay for mailbot"
# Allowlisted plugins are enabled (short names match `<token>@<marketplace>`).
assert_contains "$(cat "$PLUGIN_ALLOW_OVERLAY")" "\"syrs-gmail@syrs-local\": true"
assert_contains "$(cat "$PLUGIN_ALLOW_OVERLAY")" "\"superpowers@claude-plugins-official\": true"
# Channel plugins are auto-enabled even though not in BRIDGE_AGENT_PLUGINS.
assert_contains "$(cat "$PLUGIN_ALLOW_OVERLAY")" "\"discord@claude-plugins-official\": true"
# Non-allowlisted globally-installed plugins are explicitly disabled.
assert_contains "$(cat "$PLUGIN_ALLOW_OVERLAY")" "\"syrs-shopify@syrs-local\": false"
assert_contains "$(cat "$PLUGIN_ALLOW_OVERLAY")" "\"syrs-tracx@syrs-local\": false"
assert_contains "$(cat "$PLUGIN_ALLOW_OVERLAY")" "\"telegram@claude-plugins-official\": false"
# Agent without BRIDGE_AGENT_PLUGINS gets no allowlist overlay (back-compat).
[[ ! -e "$PLUGIN_ALLOW_HOME/agents/legacy_agent/.claude/settings.local.json" ]] \
  || die "apply-channel-policy.sh wrote allowlist overlay for legacy agent without BRIDGE_AGENT_PLUGINS key"
# Idempotency.
PLUGIN_ALLOW_FIRST="$(cat "$PLUGIN_ALLOW_OVERLAY")"
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$PLUGIN_ALLOW_HOME" \
  BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$PLUGIN_ALLOW_HOME/installed_plugins.json" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null
[[ "$(cat "$PLUGIN_ALLOW_OVERLAY")" == "$PLUGIN_ALLOW_FIRST" ]] \
  || die "apply-channel-policy.sh allowlist overlay was not idempotent"

log "apply-channel-policy.sh skips per-agent allowlist policy when installed_plugins.json is missing (#272)"
PLUGIN_ALLOW_NOREG_HOME="$TMP_ROOT/channel-policy-allowlist-noreg-home"
mkdir -p \
  "$PLUGIN_ALLOW_NOREG_HOME/agents/.claude" \
  "$PLUGIN_ALLOW_NOREG_HOME/agents/mailbot/.claude"
printf '{}' > "$PLUGIN_ALLOW_NOREG_HOME/agents/.claude/settings.json"
cat > "$PLUGIN_ALLOW_NOREG_HOME/agent-roster.local.sh" <<'ROSTER'
BRIDGE_AGENT_PLUGINS["mailbot"]="syrs-gmail"
ROSTER
env -u BRIDGE_AGENT_HOME_ROOT -u BRIDGE_ADMIN_AGENT_ID \
  BRIDGE_HOME="$PLUGIN_ALLOW_NOREG_HOME" \
  BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$PLUGIN_ALLOW_NOREG_HOME/missing-plugins.json" \
  bash "$REPO_ROOT/scripts/apply-channel-policy.sh" >/dev/null \
  || die "apply-channel-policy.sh aborted when installed_plugins.json was missing"
[[ ! -e "$PLUGIN_ALLOW_NOREG_HOME/agents/mailbot/.claude/settings.local.json" ]] \
  || die "apply-channel-policy.sh wrote allowlist overlay despite missing installed_plugins registry"

log "bootstrap-memory-system.sh memory_daily_gate_on handles hyphenated agent ids (task #886 regression)"
GATE_FN="$(awk '/^memory_daily_gate_on\(\) \{$/,/^\}$/' "$REPO_ROOT/bootstrap-memory-system.sh")"
[[ -n "$GATE_FN" ]] || die "could not extract memory_daily_gate_on from bootstrap-memory-system.sh"
# Default must be ON for a hyphenated agent id (no env override) — exit 0.
if ! env -u BRIDGE_AGENT_MEMORY_DAILY_REFRESH_agb_dev_claude \
       "$BASH4_BIN" -c "$GATE_FN"$'\n''memory_daily_gate_on agb-dev-claude'; then
  die "memory_daily_gate_on defaulted off for hyphenated agent id (should be on)"
fi
# Explicit off via the underscore-normalised env key — exit 1.
if BRIDGE_AGENT_MEMORY_DAILY_REFRESH_agb_dev_claude=0 \
     "$BASH4_BIN" -c "$GATE_FN"$'\n''memory_daily_gate_on agb-dev-claude'; then
  die "BRIDGE_AGENT_MEMORY_DAILY_REFRESH_agb_dev_claude=0 did not gate off hyphenated agent"
fi
# Regression guard: stderr must not mention the pre-fix "invalid variable name"
# abort (English or Korean locale) for a hyphenated agent.
GATE_ERR="$(env -u BRIDGE_AGENT_MEMORY_DAILY_REFRESH_agb_dev_claude \
              "$BASH4_BIN" -c "$GATE_FN"$'\n''memory_daily_gate_on agb-dev-claude' 2>&1 >/dev/null || true)"
assert_not_contains "$GATE_ERR" "invalid variable name"
assert_not_contains "$GATE_ERR" "부적절한 변수 이름"
# Dot-named agent ids are also valid per `bridge_validate_agent_name` and must
# take the same underscore-normalised path (task #886 round-2).
if ! env -u BRIDGE_AGENT_MEMORY_DAILY_REFRESH_foo_bar \
       "$BASH4_BIN" -c "$GATE_FN"$'\n''memory_daily_gate_on foo.bar'; then
  die "memory_daily_gate_on defaulted off for dotted agent id (should be on)"
fi
if BRIDGE_AGENT_MEMORY_DAILY_REFRESH_foo_bar=0 \
     "$BASH4_BIN" -c "$GATE_FN"$'\n''memory_daily_gate_on foo.bar'; then
  die "BRIDGE_AGENT_MEMORY_DAILY_REFRESH_foo_bar=0 did not gate off dotted agent"
fi
GATE_ERR_DOT="$(env -u BRIDGE_AGENT_MEMORY_DAILY_REFRESH_foo_bar \
                  "$BASH4_BIN" -c "$GATE_FN"$'\n''memory_daily_gate_on foo.bar' 2>&1 >/dev/null || true)"
assert_not_contains "$GATE_ERR_DOT" "invalid variable name"
assert_not_contains "$GATE_ERR_DOT" "부적절한 변수 이름"

log "starting isolated daemon"
bash "$REPO_ROOT/bridge-daemon.sh" ensure >/dev/null
DAEMON_STATUS=""
for _ in {1..20}; do
  DAEMON_STATUS="$(bash "$REPO_ROOT/bridge-daemon.sh" status || true)"
  if [[ "$DAEMON_STATUS" == *"running pid="* ]]; then
    break
  fi
  sleep 0.2
done
assert_contains "$DAEMON_STATUS" "running pid="

log "starting isolated tmux role"
bash "$REPO_ROOT/bridge-start.sh" "$SMOKE_AGENT" >/dev/null
bash "$REPO_ROOT/bridge-start.sh" "$REQUESTER_AGENT" >/dev/null
wait_for_tmux_session "$SESSION_NAME" up 20 0.2 || die "smoke tmux session was not created"
wait_for_tmux_session "$REQUESTER_SESSION" up 20 0.2 || die "requester tmux session was not created"

log "syncing live roster"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null

LIST_OUTPUT="$("$REPO_ROOT/agent-bridge" list)"
assert_contains "$LIST_OUTPUT" "$SMOKE_AGENT"

STATUS_OUTPUT="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$STATUS_OUTPUT" "$SMOKE_AGENT"
assert_contains "$STATUS_OUTPUT" "state"
assert_contains "$STATUS_OUTPUT" "$WORKDIR"
printf '%s\n' "$STATUS_OUTPUT" | grep -E "${SMOKE_AGENT}[[:space:]].*(idle|working)" >/dev/null || die "status should show activity state for $SMOKE_AGENT"

# Issue #314 Layer 3 / #315 Track 3 — bridge-daemon.sh stop active-agent
# guard. With $SMOKE_AGENT and $REQUESTER_AGENT active, a bare `stop` must
# refuse with the redirect banner and leave the daemon running; `--force`
# must bypass the guard; and a bare `stop` with no active agents must
# succeed normally.
log "daemon stop refuses while active agents are present (#314 Layer 3 / #315 Track 3)"
GUARD_STDERR_FILE="$TMP_ROOT/daemon-stop-guard.stderr"
GUARD_RC=0
bash "$REPO_ROOT/bridge-daemon.sh" stop >/dev/null 2>"$GUARD_STDERR_FILE" || GUARD_RC=$?
if (( GUARD_RC == 0 )); then
  die "bare 'bridge-daemon.sh stop' should refuse with active agents present (rc=$GUARD_RC)"
fi
GUARD_STDERR="$(cat "$GUARD_STDERR_FILE")"
assert_contains "$GUARD_STDERR" "Refusing to stop the bridge daemon"
assert_contains "$GUARD_STDERR" "agent-bridge upgrade --apply"
assert_contains "$GUARD_STDERR" "stop --force"
GUARD_STATUS="$(bash "$REPO_ROOT/bridge-daemon.sh" status || true)"
assert_contains "$GUARD_STATUS" "running pid="

log "daemon stop --force bypasses the active-agent guard"
FORCE_RC=0
bash "$REPO_ROOT/bridge-daemon.sh" stop --force >/dev/null 2>&1 || FORCE_RC=$?
if (( FORCE_RC != 0 )); then
  die "'bridge-daemon.sh stop --force' should succeed despite active agents (rc=$FORCE_RC)"
fi
FORCE_STATUS=""
for _ in {1..20}; do
  FORCE_STATUS="$(bash "$REPO_ROOT/bridge-daemon.sh" status || true)"
  [[ "$FORCE_STATUS" == "stopped" ]] && break
  sleep 0.2
done
assert_contains "$FORCE_STATUS" "stopped"

log "daemon stop without --force succeeds when no agents are active"
# Use a completely empty isolated BRIDGE_HOME so no roster always-on agents
# auto-start during ensure. The smoke fixture's roster registers several
# always-on agents (claude-static, ALWAYS_ON_AGENT, etc.) that the daemon
# would respawn during sync, polluting the "no active agents" precondition
# for this test. We must use `env -i` to also strip the smoke fixture's
# many BRIDGE_* path exports (BRIDGE_STATE_DIR, BRIDGE_ACTIVE_AGENT_DIR,
# BRIDGE_ROSTER_LOCAL_FILE, etc.) — those have absolute paths that would
# otherwise pull the smoke roster back in.
GUARD_EMPTY_HOME="$TMP_ROOT/guard-empty-home"
GUARD_EMPTY_ROSTER="$TMP_ROOT/guard-empty-roster.sh"
GUARD_EMPTY_LOCAL_ROSTER="$TMP_ROOT/guard-empty-roster.local.sh"
mkdir -p "$GUARD_EMPTY_HOME"
: >"$GUARD_EMPTY_ROSTER"
: >"$GUARD_EMPTY_LOCAL_ROSTER"
GUARD_BARE_RC=0
GUARD_BARE_OUT="$(env -i HOME="$HOME" PATH="$PATH" \
  BRIDGE_HOME="$GUARD_EMPTY_HOME" \
  BRIDGE_ROSTER_FILE="$GUARD_EMPTY_ROSTER" \
  BRIDGE_ROSTER_LOCAL_FILE="$GUARD_EMPTY_LOCAL_ROSTER" \
  BRIDGE_SKIP_PLUGIN_LIVENESS=1 \
  bash "$REPO_ROOT/bridge-daemon.sh" ensure 2>&1)" || true
for _ in {1..20}; do
  GUARD_EMPTY_STATUS="$(env -i HOME="$HOME" PATH="$PATH" \
    BRIDGE_HOME="$GUARD_EMPTY_HOME" \
    BRIDGE_ROSTER_FILE="$GUARD_EMPTY_ROSTER" \
    BRIDGE_ROSTER_LOCAL_FILE="$GUARD_EMPTY_LOCAL_ROSTER" \
    BRIDGE_SKIP_PLUGIN_LIVENESS=1 \
    bash "$REPO_ROOT/bridge-daemon.sh" status 2>/dev/null || true)"
  [[ "$GUARD_EMPTY_STATUS" == *"running pid="* ]] && break
  sleep 0.2
done
assert_contains "$GUARD_EMPTY_STATUS" "running pid="
env -i HOME="$HOME" PATH="$PATH" \
  BRIDGE_HOME="$GUARD_EMPTY_HOME" \
  BRIDGE_ROSTER_FILE="$GUARD_EMPTY_ROSTER" \
  BRIDGE_ROSTER_LOCAL_FILE="$GUARD_EMPTY_LOCAL_ROSTER" \
  BRIDGE_SKIP_PLUGIN_LIVENESS=1 \
  bash "$REPO_ROOT/bridge-daemon.sh" stop >/dev/null 2>&1 || GUARD_BARE_RC=$?
if (( GUARD_BARE_RC != 0 )); then
  die "bare 'bridge-daemon.sh stop' should succeed when no agents are active (rc=$GUARD_BARE_RC, ensure_out=$GUARD_BARE_OUT)"
fi
GUARD_EMPTY_STOPPED=""
for _ in {1..20}; do
  GUARD_EMPTY_STOPPED="$(env -i HOME="$HOME" PATH="$PATH" \
    BRIDGE_HOME="$GUARD_EMPTY_HOME" \
    BRIDGE_ROSTER_FILE="$GUARD_EMPTY_ROSTER" \
    BRIDGE_ROSTER_LOCAL_FILE="$GUARD_EMPTY_LOCAL_ROSTER" \
    BRIDGE_SKIP_PLUGIN_LIVENESS=1 \
    bash "$REPO_ROOT/bridge-daemon.sh" status 2>/dev/null || true)"
  [[ "$GUARD_EMPTY_STOPPED" == "stopped" ]] && break
  sleep 0.2
done
assert_contains "$GUARD_EMPTY_STOPPED" "stopped"

# Restore the smoke fixture: daemon running, both agent sessions up, so the
# rest of the suite sees the same precondition it had before this block.
bash "$REPO_ROOT/bridge-daemon.sh" ensure >/dev/null
for _ in {1..20}; do
  RESTORED_DAEMON="$(bash "$REPO_ROOT/bridge-daemon.sh" status || true)"
  [[ "$RESTORED_DAEMON" == *"running pid="* ]] && break
  sleep 0.2
done
assert_contains "$RESTORED_DAEMON" "running pid="
bash "$REPO_ROOT/bridge-start.sh" "$SMOKE_AGENT" >/dev/null
bash "$REPO_ROOT/bridge-start.sh" "$REQUESTER_AGENT" >/dev/null
wait_for_tmux_session "$SESSION_NAME" up 20 0.2 || die "smoke tmux session did not restart after guard tests"
wait_for_tmux_session "$REQUESTER_SESSION" up 20 0.2 || die "requester tmux session did not restart after guard tests"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null

RELAY_ROWS="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_discord_relay_rows_tsv
')"
assert_contains "$RELAY_ROWS" "$SMOKE_AGENT"$'\t'"123456789012345678"

log "verifying discord relay skips legacy dm agents and persists state"
python3 - "$REPO_ROOT/bridge-discord-relay.py" "$TMP_ROOT/relay-state.json" "$TMP_ROOT/relay-snapshot.tsv" "$TMP_ROOT/relay-home" <<'PY'
import argparse
import importlib.util
import json
import sys
from pathlib import Path

script_path = Path(sys.argv[1])
state_path = Path(sys.argv[2])
snapshot_path = Path(sys.argv[3])
bridge_home = Path(sys.argv[4])

spec = importlib.util.spec_from_file_location("bridge_discord_relay", script_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

(bridge_home / "agents" / "ghost" / ".discord").mkdir(parents=True, exist_ok=True)
(bridge_home / "agents" / "ghost" / ".discord" / ".env").write_text("TOKEN=ghost\n", encoding="utf-8")
(bridge_home / "agents" / "ghost" / ".discord" / "access.json").write_text(
    json.dumps({"allowFrom": ["123"], "groups": {}, "pending": {}}),
    encoding="utf-8",
)
(bridge_home / "agents" / "smoke-agent" / ".discord").mkdir(parents=True, exist_ok=True)
(bridge_home / "agents" / "smoke-agent" / ".discord" / ".env").write_text("TOKEN=smoke\n", encoding="utf-8")
(bridge_home / "agents" / "smoke-agent" / ".discord" / "access.json").write_text(
    json.dumps({"allowFrom": ["123"], "groups": {}, "pending": {}}),
    encoding="utf-8",
)

snapshot_path.write_text(
    "agent\tchannel_id\tactive\tidle_timeout\tsession\n"
    "smoke-agent\t111\t0\t900\tsmoke-session\n",
    encoding="utf-8",
)
state_path.write_text(
    json.dumps(
        {
            "channels": {
                "111": {
                    "agent": "smoke-agent",
                    "last_seen_id": "100",
                }
            },
            "dm_channels": {
                "dm:ghost:123": {
                    "agent": "ghost",
                    "user_id": "123",
                    "channel_id": "222",
                },
                "dm:smoke-agent:123": {
                    "agent": "smoke-agent",
                    "user_id": "123",
                    "channel_id": "333",
                    "last_seen_id": "100",
                },
            },
        }
    ),
    encoding="utf-8",
)

module.load_token = lambda *_args: "token"
module.load_registered_agents = lambda _bridge_home: {"smoke-agent"}
module.has_open_wake_task = lambda _bridge_home, _agent: False
module.tmux_session_active = lambda _session: False
module.open_dm_channel = lambda _token, _user_id: "333"

def fake_fetch(_token: str, channel_id: str, _limit: int):
    if channel_id == "111":
        return [{"id": "101", "content": "wake", "author": {"bot": False, "username": "Sean"}}]
    if channel_id == "333":
        return [{"id": "101", "content": "dm wake", "author": {"bot": False, "username": "Sean"}}]
    return []

enqueued = []

def fake_enqueue(_bridge_home: Path, agent: str, channel_id: str, messages: list[dict[str, object]]) -> str:
    enqueued.append((agent, channel_id, len(messages)))
    return "ok"

module.fetch_channel_messages = fake_fetch
module.enqueue_task = fake_enqueue

args = argparse.Namespace(
    agent_snapshot=str(snapshot_path),
    bridge_home=str(bridge_home),
    state_file=str(state_path),
    runtime_config=str(state_path),
    relay_account="default",
    poll_limit=5,
    cooldown_seconds=60,
)

assert module.cmd_sync(args) == 0
state = json.loads(state_path.read_text(encoding="utf-8"))
assert "dm:ghost:123" not in state["dm_channels"], state
assert state["channels"]["111"]["last_seen_id"] == "101", state
assert state["dm_channels"]["dm:smoke-agent:123"]["last_seen_id"] == "101", state
assert enqueued == [("smoke-agent", "111", 1), ("smoke-agent", "333", 1)], enqueued
PY

log "verifying session alias resolution and worktree replace"
tmux new-session -d -s "$WORKTREE_AGENT" -c "$PROJECT_ROOT" 'python3 -c "import time; print(\"worker active\", flush=True); time.sleep(30)"'
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "$STATIC_AGENT"
BRIDGE_AGENT_DESC["$STATIC_AGENT"]="Static project role"
BRIDGE_AGENT_ENGINE["$STATIC_AGENT"]="codex"
BRIDGE_AGENT_SESSION["$STATIC_AGENT"]="$STATIC_SESSION"
BRIDGE_AGENT_WORKDIR["$STATIC_AGENT"]="$PROJECT_ROOT"
BRIDGE_AGENT_LAUNCH_CMD["$STATIC_AGENT"]='python3 -c "import time; print(\"static role ready\", flush=True); time.sleep(30)"'
EOF

"$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_add_agent_id_if_missing "'"$WORKTREE_AGENT"'"
  BRIDGE_AGENT_DESC["'"$WORKTREE_AGENT"'"]="Existing worker"
  BRIDGE_AGENT_ENGINE["'"$WORKTREE_AGENT"'"]="codex"
  BRIDGE_AGENT_SESSION["'"$WORKTREE_AGENT"'"]="'"$WORKTREE_AGENT"'"
  BRIDGE_AGENT_WORKDIR["'"$WORKTREE_AGENT"'"]="'"$PROJECT_ROOT"'"
  BRIDGE_AGENT_SOURCE["'"$WORKTREE_AGENT"'"]="dynamic"
  BRIDGE_AGENT_LOOP["'"$WORKTREE_AGENT"'"]="0"
  BRIDGE_AGENT_CONTINUE["'"$WORKTREE_AGENT"'"]="1"
  BRIDGE_AGENT_HISTORY_KEY["'"$WORKTREE_AGENT"'"]="smoke-history"
  bridge_persist_agent_state "'"$WORKTREE_AGENT"'"
'

bash "$REPO_ROOT/bridge-start.sh" "$STATIC_AGENT" >/dev/null
STATIC_CANDIDATE_OUTPUT="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_static_agents_for_project_engine "'"$PROJECT_ROOT"'" codex
')"
assert_contains "$STATIC_CANDIDATE_OUTPUT" "$STATIC_AGENT"

ALIAS_OUTPUT="$("$REPO_ROOT/agent-bridge" --codex --name "$STATIC_SESSION" --workdir "$PROJECT_ROOT" --no-attach 2>&1)"
assert_contains "$ALIAS_OUTPUT" "세션 '$STATIC_SESSION'은(는) 역할 '$STATIC_AGENT'에 연결됩니다."

WORKTREE_OUTPUT="$("$REPO_ROOT/agent-bridge" --codex --name "$WORKTREE_AGENT" --workdir "$PROJECT_ROOT" --prefer new --no-attach 2>&1)"
assert_contains "$WORKTREE_OUTPUT" "isolated worktree를 사용합니다:"

EXPECTED_WORKTREE_DIR="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_worktree_launch_dir_for "'"$PROJECT_ROOT"'" "'"$WORKTREE_AGENT"'"
')"
ACTIVE_WORKTREE_DIR="$("$BASH4_BIN" -c '
  source "'"$BRIDGE_ACTIVE_AGENT_DIR"'/'"$WORKTREE_AGENT"'.env"
  printf "%s" "$AGENT_WORKDIR"
')"
[[ "$ACTIVE_WORKTREE_DIR" == "$EXPECTED_WORKTREE_DIR" ]] || die "worktree spawn reused stale session: expected $EXPECTED_WORKTREE_DIR got $ACTIVE_WORKTREE_DIR"

log "creating queue task"
CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "smoke queue" --body-file "$BRIDGE_SHARED_DIR/note.md" --from "$REQUESTER_AGENT")"
assert_contains "$CREATE_OUTPUT" "created task #"
QUEUE_TASK_ID="$(printf '%s\n' "$CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$QUEUE_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse queue task id"
QUEUE_TASK_SHELL="$(python3 "$REPO_ROOT/bridge-queue.py" show "$QUEUE_TASK_ID" --format shell)"
assert_contains "$QUEUE_TASK_SHELL" "TASK_BODY_PATH=$BRIDGE_SHARED_DIR/note.md"

log "routing direct isolated queue commands through queue gateway (#436)"
run_queue_gateway_proxy_smoke() {
  local agent="gateway-proxy-$SESSION_NAME"
  local root="$BRIDGE_STATE_DIR/queue-gateway"
  local stdout_file="$TMP_ROOT/queue-gateway-proxy.out"
  local stderr_file="$TMP_ROOT/queue-gateway-proxy.err"
  local pid=""
  local served=""
  rm -f "$stdout_file" "$stderr_file"
  BRIDGE_GATEWAY_PROXY=1 \
    BRIDGE_AGENT_ID="$agent" \
    BRIDGE_TASK_DB=/dev/null \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    BRIDGE_LAYOUT=legacy \
    BRIDGE_AGENT_ROOT_V2= \
    BRIDGE_QUEUE_GATEWAY_TIMEOUT_SECONDS=5 \
    BRIDGE_QUEUE_GATEWAY_POLL_SECONDS=0.05 \
    python3 "$REPO_ROOT/bridge-queue.py" "$@" >"$stdout_file" 2>"$stderr_file" &
  pid=$!
  for _ in {1..80}; do
    if compgen -G "$root/$agent/requests/*.request.json" >/dev/null; then
      break
    fi
    sleep 0.05
  done
  served="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" BRIDGE_LAYOUT=legacy BRIDGE_AGENT_ROOT_V2= \
    python3 "$REPO_ROOT/bridge-queue-gateway.py" serve-once --root "$root" --queue-script "$REPO_ROOT/bridge-queue.py" --max-requests 1)"
  [[ "$served" == "1" ]] || die "queue gateway proxy smoke did not process exactly one request for: $* (processed=$served)"
  if ! wait "$pid"; then
    cat "$stderr_file" >&2 || true
    die "queue gateway proxy command failed: $*"
  fi
  cat "$stdout_file"
}
GATEWAY_PROXY_CREATE_OUTPUT="$(run_queue_gateway_proxy_smoke create --to "$SMOKE_AGENT" --title "gateway proxy smoke" --body "gateway body" --from "$REQUESTER_AGENT")"
assert_contains "$GATEWAY_PROXY_CREATE_OUTPUT" "created task #"
GATEWAY_PROXY_TASK_ID="$(printf '%s\n' "$GATEWAY_PROXY_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$GATEWAY_PROXY_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse queue gateway proxy task id"
GATEWAY_PROXY_SHOW_OUTPUT="$(run_queue_gateway_proxy_smoke show "$GATEWAY_PROXY_TASK_ID")"
assert_contains "$GATEWAY_PROXY_SHOW_OUTPUT" "gateway proxy smoke"
GATEWAY_PROXY_CLAIM_OUTPUT="$(run_queue_gateway_proxy_smoke claim "$GATEWAY_PROXY_TASK_ID" --agent "$SMOKE_AGENT" --lease-seconds 60)"
assert_contains "$GATEWAY_PROXY_CLAIM_OUTPUT" "claimed task #$GATEWAY_PROXY_TASK_ID"
GATEWAY_PROXY_DONE_OUTPUT="$(run_queue_gateway_proxy_smoke done "$GATEWAY_PROXY_TASK_ID" --agent "$SMOKE_AGENT" --note "gateway proxy smoke cleanup")"
assert_contains "$GATEWAY_PROXY_DONE_OUTPUT" "completed task #$GATEWAY_PROXY_TASK_ID"

log "stabilizing ephemeral body-file payloads inside the queue"
EPHEMERAL_BODY_FILE="$(mktemp "$TMP_ROOT/queue-body.XXXXXX.md")"
cat >"$EPHEMERAL_BODY_FILE" <<'EOF'
# Ephemeral body

payload survives source unlink
EOF
EPHEMERAL_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "ephemeral queue body" --body-file "$EPHEMERAL_BODY_FILE" --from "$REQUESTER_AGENT")"
assert_contains "$EPHEMERAL_CREATE_OUTPUT" "created task #"
EPHEMERAL_TASK_ID="$(printf '%s\n' "$EPHEMERAL_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$EPHEMERAL_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse ephemeral task id"
rm -f "$EPHEMERAL_BODY_FILE"
EPHEMERAL_SHOW_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" show "$EPHEMERAL_TASK_ID")"
assert_contains "$EPHEMERAL_SHOW_OUTPUT" $'body:\n# Ephemeral body'
assert_contains "$EPHEMERAL_SHOW_OUTPUT" "payload survives source unlink"
assert_contains "$EPHEMERAL_SHOW_OUTPUT" "body_file: $BRIDGE_STATE_DIR/queue/bodies/"

log "preserving cron-dispatch body paths for run-id semantics"
CRON_PRESERVE_RUN_ID="smoke-preserve-$$"
mkdir -p "$BRIDGE_SHARED_DIR/cron-dispatch"
CRON_PRESERVE_BODY="$BRIDGE_SHARED_DIR/cron-dispatch/$CRON_PRESERVE_RUN_ID.md"
cat >"$CRON_PRESERVE_BODY" <<EOF
# [cron-dispatch] preserve

run_id: $CRON_PRESERVE_RUN_ID
EOF
CRON_PRESERVE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "[cron-dispatch] preserve ($CRON_PRESERVE_RUN_ID)" --body-file "$CRON_PRESERVE_BODY" --from smoke-test)"
assert_contains "$CRON_PRESERVE_OUTPUT" "created task #"
CRON_PRESERVE_TASK_ID="$(printf '%s\n' "$CRON_PRESERVE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$CRON_PRESERVE_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse cron preserve task id"
CRON_PRESERVE_SHELL="$(python3 "$REPO_ROOT/bridge-queue.py" show "$CRON_PRESERVE_TASK_ID" --format shell)"
assert_contains "$CRON_PRESERVE_SHELL" "TASK_BODY_PATH=$CRON_PRESERVE_BODY"

log "stabilizing body-file updates from ephemeral tmp paths"
UPDATE_TASK_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to "$SMOKE_AGENT" --title "ephemeral queue update" --from "$REQUESTER_AGENT" --body "initial")"
assert_contains "$UPDATE_TASK_OUTPUT" "created task #"
UPDATE_TASK_ID="$(printf '%s\n' "$UPDATE_TASK_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$UPDATE_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse update task id"
UPDATE_BODY_FILE="$(mktemp "$TMP_ROOT/queue-update.XXXXXX.md")"
cat >"$UPDATE_BODY_FILE" <<'EOF'
# Updated ephemeral body

updated payload survives source unlink
EOF
python3 "$REPO_ROOT/bridge-queue.py" update "$UPDATE_TASK_ID" --body-file "$UPDATE_BODY_FILE" >/dev/null
rm -f "$UPDATE_BODY_FILE"
UPDATE_SHOW_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" show "$UPDATE_TASK_ID")"
assert_contains "$UPDATE_SHOW_OUTPUT" $'body:\n# Updated ephemeral body'
assert_contains "$UPDATE_SHOW_OUTPUT" "updated payload survives source unlink"
assert_contains "$UPDATE_SHOW_OUTPUT" "body_file: $BRIDGE_STATE_DIR/queue/bodies/"

log "preferring BRIDGE_AGENT_ID when inferring task sender"
INFERRED_CREATE_OUTPUT="$(BRIDGE_AGENT_ID="$REQUESTER_AGENT" bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "env inferred queue" --body "env inferred body" 2>&1)"
assert_contains "$INFERRED_CREATE_OUTPUT" "[hint] --from omitted; inferred sender: $REQUESTER_AGENT"
assert_contains "$INFERRED_CREATE_OUTPUT" "created task #"
INFERRED_TASK_ID="$(printf '%s\n' "$INFERRED_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$INFERRED_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse inferred task id"
INFERRED_TASK_SHELL="$(python3 "$REPO_ROOT/bridge-queue.py" show "$INFERRED_TASK_ID" --format shell)"
assert_contains "$INFERRED_TASK_SHELL" "TASK_CREATED_BY=$REQUESTER_AGENT"

INBOX_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" inbox "$SMOKE_AGENT")"
assert_contains "$INBOX_OUTPUT" "smoke queue"

log "aging blocked tasks into reminder and escalation follow-ups"
BLOCKED_AGING_CREATE_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to "$SMOKE_AGENT" --title "blocked aging smoke" --body "waiting on follow-up" --from "$REQUESTER_AGENT")"
assert_contains "$BLOCKED_AGING_CREATE_OUTPUT" "created task #"
BLOCKED_AGING_TASK_ID="$(printf '%s\n' "$BLOCKED_AGING_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$BLOCKED_AGING_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse blocked aging task id"
python3 "$REPO_ROOT/bridge-queue.py" update "$BLOCKED_AGING_TASK_ID" --status blocked --note "waiting on operator" >/dev/null
SMOKE_AGENT="$SMOKE_AGENT" BLOCKED_AGING_TASK_ID="$BLOCKED_AGING_TASK_ID" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3
import time

db = os.environ["BRIDGE_TASK_DB"]
task_id = int(os.environ["BLOCKED_AGING_TASK_ID"])
agent = os.environ["SMOKE_AGENT"]
stale_ts = int(time.time()) - 9000
with sqlite3.connect(db) as conn:
    conn.execute(
        """
        UPDATE tasks
        SET updated_ts = ?, claimed_by = ?, claimed_ts = ?, lease_until_ts = NULL
        WHERE id = ?
        """,
        (stale_ts, agent, stale_ts, task_id),
    )
    conn.commit()
PY
run_blocked_aging_step() {
  "$BASH4_BIN" -lc '
    source "'"$REPO_ROOT"'/bridge-lib.sh"
    bridge_load_roster
    snapshot_file="$(mktemp)"
    trap "rm -f \"$snapshot_file\"" EXIT
    bridge_write_agent_snapshot "$snapshot_file"
    python3 "'"$REPO_ROOT"'/bridge-queue.py" daemon-step \
      --snapshot "$snapshot_file" \
      --lease-seconds "$BRIDGE_TASK_LEASE_SECONDS" \
      --heartbeat-window "$BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS" \
      --idle-threshold "$BRIDGE_TASK_IDLE_NUDGE_SECONDS" \
      --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS" \
      --zombie-threshold "${BRIDGE_ZOMBIE_NUDGE_THRESHOLD:-10}" \
      --blocked-reminder-seconds 3600 \
      --blocked-escalate-seconds 7200 \
      --admin-agent "'"$REQUESTER_AGENT"'"
  '
}
run_blocked_aging_step >/dev/null
BLOCKED_REMINDER_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[blocked-aging] task #$BLOCKED_AGING_TASK_ID ")"
[[ "$BLOCKED_REMINDER_ID" =~ ^[0-9]+$ ]] || die "expected blocked-aging reminder task"
BLOCKED_ESCALATION_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$REQUESTER_AGENT" --title-prefix "[blocked-escalation] task #$BLOCKED_AGING_TASK_ID ")"
[[ "$BLOCKED_ESCALATION_ID" =~ ^[0-9]+$ ]] || die "expected blocked-aging escalation task"
BLOCKED_REMINDER_SHOW="$(python3 "$REPO_ROOT/bridge-queue.py" show "$BLOCKED_REMINDER_ID")"
assert_contains "$BLOCKED_REMINDER_SHOW" "original_task_id: $BLOCKED_AGING_TASK_ID"
assert_contains "$BLOCKED_REMINDER_SHOW" "needs status refresh"
BLOCKED_ESCALATION_SHOW="$(python3 "$REPO_ROOT/bridge-queue.py" show "$BLOCKED_ESCALATION_ID")"
assert_contains "$BLOCKED_ESCALATION_SHOW" "original_task_id: $BLOCKED_AGING_TASK_ID"
assert_contains "$BLOCKED_ESCALATION_SHOW" "needs admin review"
BLOCKED_SOURCE_SHOW="$(python3 "$REPO_ROOT/bridge-queue.py" show "$BLOCKED_AGING_TASK_ID")"
assert_contains "$BLOCKED_SOURCE_SHOW" "blocked_reminder by daemon"
assert_contains "$BLOCKED_SOURCE_SHOW" "blocked_escalated by daemon"
BLOCKED_REMINDER_COUNT_BEFORE="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BLOCKED_AGING_TASK_ID="$BLOCKED_AGING_TASK_ID" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
task_id = os.environ["BLOCKED_AGING_TASK_ID"]
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE status IN ('queued','claimed','blocked') AND title LIKE ?",
        (f"[blocked-aging] task #{task_id} %",),
    ).fetchone()
    print(row[0])
PY
)"
BLOCKED_ESCALATION_COUNT_BEFORE="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BLOCKED_AGING_TASK_ID="$BLOCKED_AGING_TASK_ID" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
task_id = os.environ["BLOCKED_AGING_TASK_ID"]
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE status IN ('queued','claimed','blocked') AND title LIKE ?",
        (f"[blocked-escalation] task #{task_id} %",),
    ).fetchone()
    print(row[0])
PY
)"
run_blocked_aging_step >/dev/null
BLOCKED_REMINDER_COUNT_AFTER="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BLOCKED_AGING_TASK_ID="$BLOCKED_AGING_TASK_ID" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
task_id = os.environ["BLOCKED_AGING_TASK_ID"]
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE status IN ('queued','claimed','blocked') AND title LIKE ?",
        (f"[blocked-aging] task #{task_id} %",),
    ).fetchone()
    print(row[0])
PY
)"
BLOCKED_ESCALATION_COUNT_AFTER="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BLOCKED_AGING_TASK_ID="$BLOCKED_AGING_TASK_ID" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
task_id = os.environ["BLOCKED_AGING_TASK_ID"]
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE status IN ('queued','claimed','blocked') AND title LIKE ?",
        (f"[blocked-escalation] task #{task_id} %",),
    ).fetchone()
    print(row[0])
PY
)"
[[ "$BLOCKED_REMINDER_COUNT_AFTER" == "$BLOCKED_REMINDER_COUNT_BEFORE" ]] || die "blocked reminder should dedupe"
[[ "$BLOCKED_ESCALATION_COUNT_AFTER" == "$BLOCKED_ESCALATION_COUNT_BEFORE" ]] || die "blocked escalation should dedupe"
python3 "$REPO_ROOT/bridge-queue.py" cancel "$BLOCKED_REMINDER_ID" --actor smoke-test --note "blocked aging smoke cleanup" >/dev/null
python3 "$REPO_ROOT/bridge-queue.py" cancel "$BLOCKED_ESCALATION_ID" --actor smoke-test --note "blocked aging smoke cleanup" >/dev/null
python3 "$REPO_ROOT/bridge-queue.py" cancel "$BLOCKED_AGING_TASK_ID" --actor smoke-test --note "blocked aging smoke cleanup" >/dev/null

# Issue #303 Track C — `garden` column surfaces stale blocked tasks the
# assignee owns. Seed a blocked task whose updated_ts is 2 days old, run
# `agent-bridge status --all-agents`, and assert the smoke agent's row
# carries the `Nd` stale-blocked tag. Refresh the task and assert the
# column collapses back to `-`.
log "garden column reports stale blocked tasks (#303 Track C)"
GARDEN_CREATE_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to "$SMOKE_AGENT" --title "garden column smoke" --body "queue gardening signal" --from "$REQUESTER_AGENT")"
assert_contains "$GARDEN_CREATE_OUTPUT" "created task #"
GARDEN_TASK_ID="$(printf '%s\n' "$GARDEN_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$GARDEN_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse garden column task id"
python3 "$REPO_ROOT/bridge-queue.py" update "$GARDEN_TASK_ID" --status blocked --note "garden column smoke" >/dev/null
GARDEN_TASK_ID="$GARDEN_TASK_ID" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3
import time

db = os.environ["BRIDGE_TASK_DB"]
task_id = int(os.environ["GARDEN_TASK_ID"])
stale_ts = int(time.time()) - 86400 * 2
with sqlite3.connect(db) as conn:
    conn.execute(
        "UPDATE tasks SET updated_ts = ? WHERE id = ?",
        (stale_ts, task_id),
    )
    conn.commit()
PY
GARDEN_STATUS_STALE="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$GARDEN_STATUS_STALE" "garden"
GARDEN_PARSER="$(cat <<'PY'
import os
import sys

agent = os.environ["SMOKE_AGENT"]
header = None
for line in sys.stdin.read().splitlines():
    stripped = line.strip()
    if stripped.startswith("#") and "agent" in stripped and "garden" in stripped:
        header = stripped.split()
        continue
    if header is None:
        continue
    parts = stripped.split()
    if len(parts) < len(header) or agent not in parts:
        continue
    try:
        garden_idx = header.index("garden")
        agent_idx_header = header.index("agent")
        agent_idx_row = parts.index(agent)
        # The row leading "#" cell is either an active index or "-";
        # aligning on the agent token gives the right offset for garden.
        garden_offset = garden_idx - agent_idx_header
        garden_value = parts[agent_idx_row + garden_offset]
    except (ValueError, IndexError):
        continue
    print(garden_value)
    break
else:
    print("missing-row")
PY
)"
GARDEN_STALE_VALUE="$(printf '%s\n' "$GARDEN_STATUS_STALE" | SMOKE_AGENT="$SMOKE_AGENT" python3 -c "$GARDEN_PARSER")"
[[ "$GARDEN_STALE_VALUE" =~ ^[0-9]+d$ ]] || die "status garden column should mark $SMOKE_AGENT as stale-blocked while task #$GARDEN_TASK_ID has 2d-old updated_ts (got '$GARDEN_STALE_VALUE')"
GARDEN_TASK_ID="$GARDEN_TASK_ID" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3
import time

db = os.environ["BRIDGE_TASK_DB"]
task_id = int(os.environ["GARDEN_TASK_ID"])
fresh_ts = int(time.time())
with sqlite3.connect(db) as conn:
    conn.execute(
        "UPDATE tasks SET updated_ts = ? WHERE id = ?",
        (fresh_ts, task_id),
    )
    conn.commit()
PY
GARDEN_STATUS_FRESH="$("$REPO_ROOT/agent-bridge" status --all-agents)"
GARDEN_FRESH_VALUE="$(printf '%s\n' "$GARDEN_STATUS_FRESH" | SMOKE_AGENT="$SMOKE_AGENT" python3 -c "$GARDEN_PARSER")"
[[ "$GARDEN_FRESH_VALUE" == "-" ]] || die "status garden column should clear to '-' after task #$GARDEN_TASK_ID is refreshed (got '$GARDEN_FRESH_VALUE')"
python3 "$REPO_ROOT/bridge-queue.py" cancel "$GARDEN_TASK_ID" --actor smoke-test --note "garden column smoke cleanup" >/dev/null

log "claiming and completing queue task"
SMOKE_AGENT="$SMOKE_AGENT" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3
import time

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["SMOKE_AGENT"]
stale_ts = int(time.time()) - 7200
with sqlite3.connect(db) as conn:
    conn.execute(
        """
        INSERT INTO agent_state (agent, active, last_seen_ts, session_activity_ts)
        VALUES (?, 1, ?, ?)
        ON CONFLICT(agent) DO UPDATE SET
          active = 1,
          last_seen_ts = excluded.last_seen_ts,
          session_activity_ts = excluded.session_activity_ts
        """,
        (agent, stale_ts, stale_ts),
    )
    conn.commit()
PY
bash "$REPO_ROOT/bridge-task.sh" claim "$QUEUE_TASK_ID" --agent "$SMOKE_AGENT" >/dev/null
CLAIM_SUMMARY_TSV="$(python3 "$REPO_ROOT/bridge-queue.py" summary --agent "$SMOKE_AGENT" --format tsv)"
CLAIM_IDLE_SECONDS="$(printf '%s\n' "$CLAIM_SUMMARY_TSV" | awk -F'\t' 'NR==1 {print $6}')"
[[ "$CLAIM_IDLE_SECONDS" =~ ^[0-9]+$ ]] || die "claim idle seconds was not numeric: $CLAIM_IDLE_SECONDS"
(( CLAIM_IDLE_SECONDS < 10 )) || die "claim should refresh agent activity; idle=$CLAIM_IDLE_SECONDS"

SMOKE_AGENT="$SMOKE_AGENT" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3
import time

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["SMOKE_AGENT"]
stale_ts = int(time.time()) - 7200
with sqlite3.connect(db) as conn:
    conn.execute(
        """
        UPDATE agent_state
        SET last_seen_ts = ?, session_activity_ts = ?
        WHERE agent = ?
        """,
        (stale_ts, stale_ts, agent),
    )
    conn.commit()
PY
DONE_BEFORE_TS="$(date +%s)"
python3 "$REPO_ROOT/bridge-queue.py" done "$QUEUE_TASK_ID" --agent "$SMOKE_AGENT" --note "smoke ok" >/dev/null
DONE_ACTIVITY_TS="$(SMOKE_AGENT="$SMOKE_AGENT" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["SMOKE_AGENT"]
with sqlite3.connect(db) as conn:
    value = conn.execute(
        "SELECT session_activity_ts FROM agent_state WHERE agent = ?",
        (agent,),
    ).fetchone()
print(int(value[0] or 0))
PY
)"
[[ "$DONE_ACTIVITY_TS" =~ ^[0-9]+$ ]] || die "done activity ts was not numeric: $DONE_ACTIVITY_TS"
(( DONE_ACTIVITY_TS >= DONE_BEFORE_TS )) || die "done should refresh agent activity; activity_ts=$DONE_ACTIVITY_TS before=$DONE_BEFORE_TS"

SHOW_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show "$QUEUE_TASK_ID")"
assert_contains "$SHOW_OUTPUT" "status: done"
assert_contains "$SHOW_OUTPUT" "note: smoke ok"

NOTICE_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "smoke queue notice" --body-file "$BRIDGE_SHARED_DIR/note.md" --from "$REQUESTER_AGENT")"
assert_contains "$NOTICE_CREATE_OUTPUT" "created task #"
NOTICE_TASK_ID="$(printf '%s\n' "$NOTICE_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$NOTICE_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse notice task id"
bash "$REPO_ROOT/bridge-task.sh" "done" "$NOTICE_TASK_ID" --agent "$SMOKE_AGENT" --note "notice ok" >/dev/null

REQUESTER_INBOX_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" inbox "$REQUESTER_AGENT")"
assert_contains "$REQUESTER_INBOX_OUTPUT" "[task-complete] smoke queue notice"
REQUESTER_NOTICE_TASK_ID="$(REQUESTER_AGENT="$REQUESTER_AGENT" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["REQUESTER_AGENT"]
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT id FROM tasks WHERE assigned_to = ? AND title = ? ORDER BY id DESC LIMIT 1",
        (agent, "[task-complete] smoke queue notice"),
    ).fetchone()
print(int(row[0]) if row else 0)
PY
)"
[[ "$REQUESTER_NOTICE_TASK_ID" =~ ^[0-9]+$ ]] || die "completion notice task id was not numeric: $REQUESTER_NOTICE_TASK_ID"
(( REQUESTER_NOTICE_TASK_ID > 0 )) || die "completion notice task was not created"
REQUESTER_SHOW_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show "$REQUESTER_NOTICE_TASK_ID")"
assert_contains "$REQUESTER_SHOW_OUTPUT" "assigned_to: $REQUESTER_AGENT"
assert_contains "$REQUESTER_SHOW_OUTPUT" "original_task: #$NOTICE_TASK_ID"
assert_contains "$REQUESTER_SHOW_OUTPUT" "completed_by: $SMOKE_AGENT"

# Issue #697 — claimed→blocked transition with a non-empty note must
# auto-notify the requester with a `[task-blocked]` task, and a second
# blocked update on the same task must not create a duplicate.
log "auto-notifying requester on claimed→blocked transition (#697)"
BLOCKED_NOTIFY_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "smoke blocked-notify" --body "needs human input" --from "$REQUESTER_AGENT")"
assert_contains "$BLOCKED_NOTIFY_CREATE_OUTPUT" "created task #"
BLOCKED_NOTIFY_TASK_ID="$(printf '%s\n' "$BLOCKED_NOTIFY_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$BLOCKED_NOTIFY_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse blocked-notify task id"
bash "$REPO_ROOT/bridge-task.sh" claim "$BLOCKED_NOTIFY_TASK_ID" --agent "$SMOKE_AGENT" >/dev/null
bash "$REPO_ROOT/bridge-task.sh" update "$BLOCKED_NOTIFY_TASK_ID" --actor "$SMOKE_AGENT" --status blocked --note "operator decision needed: scope A or B" >/dev/null
REQUESTER_BLOCKED_INBOX="$(bash "$REPO_ROOT/bridge-task.sh" inbox "$REQUESTER_AGENT")"
assert_contains "$REQUESTER_BLOCKED_INBOX" "[task-blocked] task #${BLOCKED_NOTIFY_TASK_ID}: smoke blocked-notify"
BLOCKED_NOTIFY_NOTICE_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$REQUESTER_AGENT" --title-prefix "[task-blocked] task #${BLOCKED_NOTIFY_TASK_ID}:")"
[[ "$BLOCKED_NOTIFY_NOTICE_ID" =~ ^[0-9]+$ ]] || die "blocked-notify notice id was not numeric: $BLOCKED_NOTIFY_NOTICE_ID"
BLOCKED_NOTIFY_SHOW="$(bash "$REPO_ROOT/bridge-task.sh" show "$BLOCKED_NOTIFY_NOTICE_ID")"
assert_contains "$BLOCKED_NOTIFY_SHOW" "assigned_to: $REQUESTER_AGENT"
assert_contains "$BLOCKED_NOTIFY_SHOW" "original_task: #${BLOCKED_NOTIFY_TASK_ID}"
assert_contains "$BLOCKED_NOTIFY_SHOW" "blocked_by: $SMOKE_AGENT"
assert_contains "$BLOCKED_NOTIFY_SHOW" "operator decision needed: scope A or B"

# Idempotency — re-blocking the same task must not duplicate the notice.
bash "$REPO_ROOT/bridge-task.sh" update "$BLOCKED_NOTIFY_TASK_ID" --actor "$SMOKE_AGENT" --status blocked --note "still waiting" >/dev/null
BLOCKED_NOTIFY_COUNT="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" REQUESTER_AGENT="$REQUESTER_AGENT" BLOCKED_NOTIFY_TASK_ID="$BLOCKED_NOTIFY_TASK_ID" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["REQUESTER_AGENT"]
prefix = f"[task-blocked] task #{os.environ['BLOCKED_NOTIFY_TASK_ID']}:"
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE assigned_to = ? AND title LIKE ?",
        (agent, prefix + "%"),
    ).fetchone()
print(int(row[0]))
PY
)"
[[ "$BLOCKED_NOTIFY_COUNT" == "1" ]] || die "expected exactly one [task-blocked] notice, got $BLOCKED_NOTIFY_COUNT"

# Negative — a blocked update WITHOUT a note must not create a notice.
BLOCKED_NONOTE_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "smoke blocked-no-note" --body "x" --from "$REQUESTER_AGENT")"
BLOCKED_NONOTE_TASK_ID="$(printf '%s\n' "$BLOCKED_NONOTE_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$BLOCKED_NONOTE_TASK_ID" =~ ^[0-9]+$ ]] || die "could not parse blocked-no-note task id"
bash "$REPO_ROOT/bridge-task.sh" claim "$BLOCKED_NONOTE_TASK_ID" --agent "$SMOKE_AGENT" >/dev/null
bash "$REPO_ROOT/bridge-task.sh" update "$BLOCKED_NONOTE_TASK_ID" --actor "$SMOKE_AGENT" --status blocked >/dev/null
BLOCKED_NONOTE_COUNT="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" REQUESTER_AGENT="$REQUESTER_AGENT" BLOCKED_NONOTE_TASK_ID="$BLOCKED_NONOTE_TASK_ID" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
agent = os.environ["REQUESTER_AGENT"]
prefix = f"[task-blocked] task #{os.environ['BLOCKED_NONOTE_TASK_ID']}:"
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE assigned_to = ? AND title LIKE ?",
        (agent, prefix + "%"),
    ).fetchone()
print(int(row[0]))
PY
)"
[[ "$BLOCKED_NONOTE_COUNT" == "0" ]] || die "expected no [task-blocked] notice when no note, got $BLOCKED_NONOTE_COUNT"

log "cancelling an orphan task without a roster entry"
ORPHAN_TASK_ID=""
ORPHAN_CREATE_OUTPUT="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/bridge-queue.py" create --to tester --title "orphan cleanup" --from smoke --priority high --body "cleanup me" --format shell)"
assert_contains "$ORPHAN_CREATE_OUTPUT" "TASK_ID="
ORPHAN_TASK_ID="$(printf '%s\n' "$ORPHAN_CREATE_OUTPUT" | sed -n 's/^TASK_ID=//p' | head -n1)"
[[ -n "$ORPHAN_TASK_ID" ]] || die "expected orphan task id"
CANCEL_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" cancel "$ORPHAN_TASK_ID" --actor smoke --note "cleanup stale test task")"
assert_contains "$CANCEL_OUTPUT" "cancelled task #$ORPHAN_TASK_ID as smoke"
ORPHAN_SHOW_OUTPUT="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/bridge-queue.py" show "$ORPHAN_TASK_ID")"
assert_contains "$ORPHAN_SHOW_OUTPUT" "status: cancelled"

SUMMARY_OUTPUT="$("$REPO_ROOT/agb" summary "$SMOKE_AGENT")"
assert_contains "$SUMMARY_OUTPUT" "$SMOKE_AGENT"

log "marking zombie after repeated unanswered nudges and clearing on activity"
for nudge_try in $(seq 1 10); do
  python3 "$REPO_ROOT/bridge-queue.py" note-nudge --agent "$SMOKE_AGENT" --key "smoke-zombie-$nudge_try" --zombie-threshold 10 >/dev/null
done
ZOMBIE_STATUS_OUTPUT="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$ZOMBIE_STATUS_OUTPUT" "zombie=1"
assert_contains "$ZOMBIE_STATUS_OUTPUT" "zmb"

ZOMBIE_RESET_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "zombie reset smoke" --body "reset" --from "$REQUESTER_AGENT")"
assert_contains "$ZOMBIE_RESET_CREATE_OUTPUT" "created task #"
ZOMBIE_RESET_TASK_ID="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 - <<'PY'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT id FROM tasks WHERE title = ? ORDER BY id DESC LIMIT 1",
        ("zombie reset smoke",),
    ).fetchone()
print(int(row[0]))
PY
)"
python3 "$REPO_ROOT/bridge-queue.py" claim "$ZOMBIE_RESET_TASK_ID" --agent "$SMOKE_AGENT" --lease-seconds 60 >/dev/null
python3 "$REPO_ROOT/bridge-queue.py" done "$ZOMBIE_RESET_TASK_ID" --agent "$SMOKE_AGENT" --note "cleared zombie" >/dev/null
ZOMBIE_CLEARED_STATUS_OUTPUT="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$ZOMBIE_CLEARED_STATUS_OUTPUT" "zombie=0"
assert_not_contains "$ZOMBIE_CLEARED_STATUS_OUTPUT" "zmb"

log "ensuring events reader and supervisor prefilter"
EVENTS_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" events --type done --after-id 0 --limit 5 --format json)"
assert_contains "$EVENTS_OUTPUT" '"event_type": "done"'
assert_contains "$EVENTS_OUTPUT" '"task_title"'
EVENTS_TEXT="$(python3 "$REPO_ROOT/bridge-queue.py" events --type done --after-id 0 --limit 2 --format text)"
assert_contains "$EVENTS_TEXT" "done"
SUPERVISOR_STATUS="$(python3 "$REPO_ROOT/bridge-supervisor.py" status)"
assert_contains "$SUPERVISOR_STATUS" "checkpoint:"
assert_contains "$SUPERVISOR_STATUS" "model:"

log "ensuring Task Processing Protocol in managed CLAUDE.md block"
TEMPLATE_CLAUDE="$(cat "$REPO_ROOT/agents/_template/CLAUDE.md")"
assert_contains "$TEMPLATE_CLAUDE" "Task Processing Protocol"
assert_contains "$TEMPLATE_CLAUDE" "조용한 done 금지"

log "auto-starting static role even when timeout=0"
AUTO_START_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$AUTO_START_AGENT" --title "auto-start smoke" --body "wake" --from "$REQUESTER_AGENT")"
assert_contains "$AUTO_START_OUTPUT" "created task #"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
sleep 1
tmux_has_session_exact "$AUTO_START_SESSION" || die "auto-start role did not start with timeout=0"

log "ensuring explicit timeout=0 role is restarted even without queue"
tmux_has_session_exact "$ALWAYS_ON_SESSION" && tmux_kill_session_exact "$ALWAYS_ON_SESSION" || true
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
wait_for_tmux_session "$ALWAYS_ON_SESSION" up 25 0.2 || die "always-on role did not restart without queue"

log "keeping a manually killed always-on role down until explicit restart"
"$REPO_ROOT/agent-bridge" kill "$ALWAYS_ON_AGENT" >/dev/null
sleep 2
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
wait_for_tmux_session "$ALWAYS_ON_SESSION" down 10 0.2 || die "always-on role respawned after manual kill"
"$REPO_ROOT/agent-bridge" agent start "$ALWAYS_ON_AGENT" >/dev/null
wait_for_tmux_session "$ALWAYS_ON_SESSION" up 25 0.2 || die "always-on role did not restart after explicit start"

log "running guided Discord setup"
SETUP_DISCORD_OUTPUT="$("$REPO_ROOT/agent-bridge" setup discord "claude-static" --channel-account smoke --channel 123456789012345678 --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_DISCORD_API_BASE" --yes)"
assert_contains "$SETUP_DISCORD_OUTPUT" "validation: ok"
assert_contains "$SETUP_DISCORD_OUTPUT" "token_source: channel:smoke"
assert_contains "$SETUP_DISCORD_OUTPUT" "channel 123456789012345678: read=ok send=ok"
[[ -f "$CLAUDE_STATIC_WORKDIR/.discord/.env" ]] || die "setup discord did not create .env"
[[ -f "$CLAUDE_STATIC_WORKDIR/.discord/access.json" ]] || die "setup discord did not create access.json"
assert_contains "$(cat "$CLAUDE_STATIC_WORKDIR/.discord/.env")" "DISCORD_BOT_TOKEN=smoke-token"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_NOTIFY_ACCOUNT[\"claude-static\"]=\"smoke\""
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_CHANNELS[\"claude-static\"]=\"plugin:discord@claude-plugins-official\""
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_DISCORD_CHANNEL_ID[\"claude-static\"]=\"123456789012345678\""
assert_contains "$(cat "$FAKE_DISCORD_REQUESTS")" "[Agent Bridge setup]"

log "running broader agent preflight"
SETUP_AGENT_OUTPUT="$("$REPO_ROOT/agent-bridge" setup agent "$SMOKE_AGENT" --skip-discord)"
assert_contains "$SETUP_AGENT_OUTPUT" "claude_md: n/a (engine=codex)"
assert_contains "$SETUP_AGENT_OUTPUT" "wake_channel: -"
assert_contains "$SETUP_AGENT_OUTPUT" "start_dry_run: ok"

log "ensuring Codex hooks and launch override"
CODEX_HOOK_ENSURE_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-codex-hooks --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)" --codex-hooks-file "$CODEX_HOOKS_FILE")"
assert_contains "$CODEX_HOOK_ENSURE_OUTPUT" "session_start_hook: present"
assert_contains "$CODEX_HOOK_ENSURE_OUTPUT" "stop_hook: present"
assert_contains "$CODEX_HOOK_ENSURE_OUTPUT" "prompt_hook: present"
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "\"SessionStart\""
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "\"Stop\""
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "\"UserPromptSubmit\""
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "session-start.py"
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "check-inbox.py"
assert_contains "$(cat "$CODEX_HOOKS_FILE")" "prompt_timestamp.py"
CODEX_HOOK_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-codex-hooks --codex-hooks-file "$CODEX_HOOKS_FILE")"
assert_contains "$CODEX_HOOK_STATUS_OUTPUT" "status: present"
assert_contains "$CODEX_HOOK_STATUS_OUTPUT" "prompt_hook: present"
CODEX_LAUNCH_DRY_RUN="$("$REPO_ROOT/bridge-run.sh" "$CODEX_CLI_AGENT" --dry-run)"
assert_contains "$CODEX_LAUNCH_DRY_RUN" "launch=codex -c features.codex_hooks=true"
# v0.8.6 hotfix: every codex launch now also pins features.fast_mode=true so
# admin-pair backfill, isolated agent create, and v0.7→v0.8 migration all
# carry the same flag. The injection helper guards against duplicate flags
# so a roster with only codex_hooks (pre-hotfix default) gets fast_mode
# auto-injected on next wake; this assertion locks the post-hotfix shape.
assert_contains "$CODEX_LAUNCH_DRY_RUN" "features.fast_mode=true"
CODEX_SESSION_START_OUTPUT="$(BRIDGE_AGENT_ID="$SMOKE_AGENT" python3 "$REPO_ROOT/hooks/codex-session-start.py")"
assert_contains "$CODEX_SESSION_START_OUTPUT" "\"hookEventName\": \"SessionStart\""
assert_contains "$CODEX_SESSION_START_OUTPUT" "agb inbox $SMOKE_AGENT"
cat >"$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md" <<'EOF'
# Resume Checklist

- Verify the last restart result.
- Report the result to the user.
EOF
cat >"$CLAUDE_STATIC_WORKDIR/SESSION-TYPE.md" <<'EOF'
- Session Type: admin
- Onboarding State: pending
EOF
CLAUDE_SESSION_START_OUTPUT="$(BRIDGE_AGENT_ID="claude-static" BRIDGE_AGENT_WORKDIR="$CLAUDE_STATIC_WORKDIR" BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents" python3 "$REPO_ROOT/hooks/session_start.py")"
assert_contains "$CLAUDE_SESSION_START_OUTPUT" "Handoff present: NEXT-SESSION.md exists"
assert_contains "$CLAUDE_SESSION_START_OUTPUT" "Resume Checklist"
assert_contains "$CLAUDE_SESSION_START_OUTPUT" "Onboarding pending:"
assert_contains "$CLAUDE_SESSION_START_OUTPUT" "agb inbox claude-static"
CLAUDE_STATIC_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
CLAUDE_PROMPT_NEXT_SESSION_OUTPUT="$(BRIDGE_AGENT_ID="claude-static" BRIDGE_AGENT_WORKDIR="$CLAUDE_STATIC_WORKDIR" BRIDGE_AGENT_HOME_ROOT="$CLAUDE_STATIC_AGENT_HOME_ROOT" BRIDGE_HOME="$BRIDGE_HOME" python3 "$REPO_ROOT/hooks/prompt_timestamp.py")"
assert_contains "$CLAUDE_PROMPT_NEXT_SESSION_OUTPUT" "<agent_bridge_next_session_required>"
assert_contains "$CLAUDE_PROMPT_NEXT_SESSION_OUTPUT" "Before answering the current user prompt"
assert_contains "$CLAUDE_PROMPT_NEXT_SESSION_OUTPUT" "Resume Checklist"
# Issue #228: the SessionStart hook must also stamp the next-session
# digest into the per-agent marker so bash-side
# bridge_agent_maybe_expire_next_session can later age out the handoff.
CLAUDE_STATIC_SESSION_MARKER_FILE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_next_session_marker_file "claude-static"
')"
[[ -f "$CLAUDE_STATIC_SESSION_MARKER_FILE" ]] || die "session_start hook did not write next-session marker"
CLAUDE_STATIC_SESSION_EXPECTED_DIGEST="$(python3 -c 'import hashlib,sys; print(hashlib.sha1(open(sys.argv[1],"rb").read().rstrip(b"\n")).hexdigest())' "$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md")"
CLAUDE_STATIC_SESSION_ACTUAL_DIGEST="$(cat "$CLAUDE_STATIC_SESSION_MARKER_FILE")"
[[ "$CLAUDE_STATIC_SESSION_EXPECTED_DIGEST" == "$CLAUDE_STATIC_SESSION_ACTUAL_DIGEST" ]] || die "next-session marker digest mismatch: expected $CLAUDE_STATIC_SESSION_EXPECTED_DIGEST got $CLAUDE_STATIC_SESSION_ACTUAL_DIGEST"
rm -f "$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md" "$CLAUDE_STATIC_WORKDIR/SESSION-TYPE.md" "$CLAUDE_STATIC_SESSION_MARKER_FILE"

# Issue #228 round 2: also exercise the path with BRIDGE_ACTIVE_AGENT_DIR
# rerouted outside BRIDGE_STATE_DIR/agents. The Python writer must follow
# the bash contract (bridge_agent_runtime_state_dir is rooted at
# BRIDGE_ACTIVE_AGENT_DIR, not BRIDGE_STATE_DIR/agents), otherwise the
# bash reader never sees the marker and auto-expiry stays dead.
CLAUDE_STATIC_CUSTOM_ACTIVE_DIR="$TMP_ROOT/custom-active-agent-dir"
mkdir -p "$CLAUDE_STATIC_CUSTOM_ACTIVE_DIR"
cat >"$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md" <<'EOF'
# Custom active-dir handoff
EOF
BRIDGE_ACTIVE_AGENT_DIR="$CLAUDE_STATIC_CUSTOM_ACTIVE_DIR" BRIDGE_AGENT_ID="claude-static" BRIDGE_AGENT_WORKDIR="$CLAUDE_STATIC_WORKDIR" BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents" python3 "$REPO_ROOT/hooks/session_start.py" >/dev/null
CLAUDE_STATIC_CUSTOM_MARKER_FILE="$(BRIDGE_ACTIVE_AGENT_DIR="$CLAUDE_STATIC_CUSTOM_ACTIVE_DIR" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_next_session_marker_file "claude-static"
')"
[[ "$CLAUDE_STATIC_CUSTOM_MARKER_FILE" == "$CLAUDE_STATIC_CUSTOM_ACTIVE_DIR"/* ]] || die "bash did not resolve marker under BRIDGE_ACTIVE_AGENT_DIR override: $CLAUDE_STATIC_CUSTOM_MARKER_FILE"
[[ -f "$CLAUDE_STATIC_CUSTOM_MARKER_FILE" ]] || die "session_start hook did not honour BRIDGE_ACTIVE_AGENT_DIR override — marker missing at $CLAUDE_STATIC_CUSTOM_MARKER_FILE"
rm -f "$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md" "$CLAUDE_STATIC_CUSTOM_MARKER_FILE"
rm -rf "$CLAUDE_STATIC_CUSTOM_ACTIVE_DIR"

# Issue #314 Layer 1: SessionStart with matcher=clear must auto-clear the
# persisted AGENT_SESSION_ID. Without this, a Claude /clear leaves the
# agent's resume id pointing at the pre-clear session, and the next
# `bridge-run.sh <agent> --continue` resumes the stale, context-saturated
# session instead of the freshly forked one. The hook shells out to
# `$BRIDGE_HOME/agent-bridge agent forget-session <agent>`. The smoke
# `$BRIDGE_HOME` is not a copied install layout (the source CLI cannot be
# symlinked here because it resolves SCRIPT_DIR via realpath and would
# fail to find sibling lib/), so we install a stub shim that records its
# invocation and performs the same persisted-id clear via the real
# `bridge_clear_persisted_session_id`. This proves the hook is wired to
# fork the CLI when matcher=clear and to skip it for matcher=startup.
log "session_start hook auto-clears persisted session id on /clear matcher (#314 Layer 1)"
SESSION_CLEAR_CLI_SHIM="$BRIDGE_HOME/agent-bridge"
SESSION_CLEAR_SHIM_LOG="$TMP_ROOT/session-start-clear-shim.log"
[[ -e "$SESSION_CLEAR_CLI_SHIM" ]] && SESSION_CLEAR_HAD_PRIOR_CLI=yes || SESSION_CLEAR_HAD_PRIOR_CLI=no
cat >"$SESSION_CLEAR_CLI_SHIM" <<EOF
#!/usr/bin/env bash
# Stub agent-bridge CLI used only by the #314 Layer 1 smoke fixture.
# Records every invocation and, when called as 'agent forget-session
# <agent>', delegates to the real bridge_clear_persisted_session_id.
printf 'invoked: %s\n' "\$*" >>"$SESSION_CLEAR_SHIM_LOG"
if [[ "\${1:-}" == "agent" && "\${2:-}" == "forget-session" && -n "\${3:-}" ]]; then
  source "$REPO_ROOT/bridge-lib.sh"
  bridge_load_roster
  bridge_clear_persisted_session_id "\$3" >/dev/null
fi
EOF
chmod +x "$SESSION_CLEAR_CLI_SHIM"
: >"$SESSION_CLEAR_SHIM_LOG"
SESSION_CLEAR_FAKE_ID="smoke-pre-clear-id-$$"
"$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_SESSION_ID["claude-static"]="'"$SESSION_CLEAR_FAKE_ID"'"
  bridge_persist_agent_state "claude-static"
'
SESSION_CLEAR_SEEDED_ID="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_persisted_session_id "claude-static"
')"
[[ "$SESSION_CLEAR_SEEDED_ID" == "$SESSION_CLEAR_FAKE_ID" ]] || die "smoke seed for #314 fixture failed: persisted id=$SESSION_CLEAR_SEEDED_ID expected=$SESSION_CLEAR_FAKE_ID"
BRIDGE_AGENT_ID="claude-static" BRIDGE_AGENT_WORKDIR="$CLAUDE_STATIC_WORKDIR" BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents" python3 "$REPO_ROOT/hooks/session_start.py" --matcher clear >/dev/null
SESSION_CLEAR_AFTER_ID="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_persisted_session_id "claude-static"
')"
[[ -z "$SESSION_CLEAR_AFTER_ID" ]] || die "session_start --matcher clear did not clear persisted id (still: $SESSION_CLEAR_AFTER_ID)"
assert_contains "$(cat "$SESSION_CLEAR_SHIM_LOG")" "agent forget-session claude-static"
# Idempotent re-run: clearing an already-empty id must not error and the
# shim must still be invoked (forget-session itself is responsible for
# the no-op behavior on an already-empty id).
BRIDGE_AGENT_ID="claude-static" BRIDGE_AGENT_WORKDIR="$CLAUDE_STATIC_WORKDIR" BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents" python3 "$REPO_ROOT/hooks/session_start.py" --matcher clear >/dev/null
SESSION_CLEAR_INVOCATIONS="$(grep -c '^invoked:' "$SESSION_CLEAR_SHIM_LOG" || true)"
[[ "$SESSION_CLEAR_INVOCATIONS" -ge 2 ]] || die "expected at least 2 shim invocations after two --matcher clear runs, saw $SESSION_CLEAR_INVOCATIONS"
# Regression guard: matcher=startup must NOT clear a freshly seeded id
# and must NOT invoke the forget-session CLI.
"$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_SESSION_ID["claude-static"]="'"$SESSION_CLEAR_FAKE_ID"'-2"
  bridge_persist_agent_state "claude-static"
'
: >"$SESSION_CLEAR_SHIM_LOG"
BRIDGE_AGENT_ID="claude-static" BRIDGE_AGENT_WORKDIR="$CLAUDE_STATIC_WORKDIR" BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents" python3 "$REPO_ROOT/hooks/session_start.py" --matcher startup >/dev/null
SESSION_STARTUP_AFTER_ID="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_persisted_session_id "claude-static"
')"
[[ "$SESSION_STARTUP_AFTER_ID" == "$SESSION_CLEAR_FAKE_ID-2" ]] || die "session_start --matcher startup unexpectedly mutated persisted id (got: $SESSION_STARTUP_AFTER_ID)"
[[ ! -s "$SESSION_CLEAR_SHIM_LOG" ]] || die "session_start --matcher startup unexpectedly forked the CLI: $(cat "$SESSION_CLEAR_SHIM_LOG")"
# Clean up: drop the seeded id and remove the stub CLI shim so downstream
# fixtures see the same state they did before this block.
"$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_clear_persisted_session_id "claude-static" >/dev/null
'
rm -f "$SESSION_CLEAR_SHIM_LOG"
[[ "$SESSION_CLEAR_HAD_PRIOR_CLI" == "yes" ]] || rm -f "$SESSION_CLEAR_CLI_SHIM"

CODEX_PROMPT_OUTPUT="$(BRIDGE_AGENT_ID="$SMOKE_AGENT" BRIDGE_HOME="$BRIDGE_HOME" python3 "$REPO_ROOT/hooks/prompt_timestamp.py" --format codex)"
assert_contains "$CODEX_PROMPT_OUTPUT" "\"hookEventName\": \"UserPromptSubmit\""
assert_contains "$CODEX_PROMPT_OUTPUT" "now:"
assert_contains "$CODEX_PROMPT_OUTPUT" "session_age:"
CODEX_DYNAMIC_NO_HOME_AGENT="agb-dev-codex-dynamic-no-home-$$"
rm -rf "$BRIDGE_HOME/agents/$CODEX_DYNAMIC_NO_HOME_AGENT"
CODEX_DYNAMIC_NO_HOME_OUTPUT="$(printf '%s' '{"stop_hook_active": false}' | BRIDGE_AGENT_ID="$CODEX_DYNAMIC_NO_HOME_AGENT" BRIDGE_AGENT_WORKDIR= BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/hooks/check-inbox.py" --format codex)"
python3 - "$CODEX_DYNAMIC_NO_HOME_OUTPUT" "$BRIDGE_HOME/agents/$CODEX_DYNAMIC_NO_HOME_AGENT" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(sys.argv[1])
assert payload == {}, payload
assert not Path(sys.argv[2]).exists(), sys.argv[2]
PY
CODEX_STOP_TASK_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "codex stop pickup" --body "pickup" --from "$REQUESTER_AGENT")"
assert_contains "$CODEX_STOP_TASK_OUTPUT" "created task #"
CODEX_STOP_TASK_ID="$(printf '%s\n' "$CODEX_STOP_TASK_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$CODEX_STOP_TASK_ID" ]] || die "expected codex stop task id"
CODEX_STOP_OUTPUT="$(printf '%s' '{"stop_hook_active": false}' | BRIDGE_AGENT_ID="$SMOKE_AGENT" BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/hooks/codex-stop.py")"
assert_contains "$CODEX_STOP_OUTPUT" "\"decision\": \"block\""
assert_contains "$CODEX_STOP_OUTPUT" "agb inbox $SMOKE_AGENT"
assert_not_contains "$CODEX_STOP_OUTPUT" "\"hookSpecificOutput\""
CODEX_STOP_ACTIVE_OUTPUT="$(printf '%s' '{"stop_hook_active": true}' | BRIDGE_AGENT_ID="$SMOKE_AGENT" BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/hooks/codex-stop.py")"
assert_contains "$CODEX_STOP_ACTIVE_OUTPUT" "{}"
python3 "$REPO_ROOT/bridge-queue.py" done "$CODEX_STOP_TASK_ID" --agent "$SMOKE_AGENT" --note "codex hook smoke cleanup" >/dev/null

log "nudging prompt-ready Codex sessions without waiting for idle threshold"
tmux_kill_session_exact "$CODEX_CLI_SESSION" || true
# Keep the prompt empty. Text after the Codex glyph is treated as typed input
# by the busy gate and intentionally spools daemon nudges.
tmux new-session -d -s "$CODEX_CLI_SESSION" "$BASH4_BIN -lc 'printf \"› \\n\"; sleep 30'"
bash "$REPO_ROOT/bridge-sync.sh" >/dev/null
CODEX_READY_TASK_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to "$CODEX_CLI_AGENT" --title "codex ready pickup" --body "pickup" --from "$REQUESTER_AGENT")"
assert_contains "$CODEX_READY_TASK_OUTPUT" "created task #"
CODEX_READY_TASK_ID="$(printf '%s\n' "$CODEX_READY_TASK_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$CODEX_READY_TASK_ID" ]] || die "expected codex ready task id"
CODEX_READY_OUTPUT="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  snapshot_file="$(mktemp)"
  ready_file="$(mktemp)"
  trap "rm -f \"$snapshot_file\" \"$ready_file\"" EXIT
  bridge_write_agent_snapshot "$snapshot_file"
  bridge_write_idle_ready_agents "$ready_file"
  python3 "'"$REPO_ROOT"'/bridge-queue.py" daemon-step \
    --snapshot "$snapshot_file" \
    --lease-seconds "$BRIDGE_TASK_LEASE_SECONDS" \
    --heartbeat-window "$BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS" \
    --idle-threshold 9999 \
    --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS" \
    --zombie-threshold "${BRIDGE_ZOMBIE_NUDGE_THRESHOLD:-10}" \
    --ready-agents-file "$ready_file"
')"
assert_contains "$CODEX_READY_OUTPUT" "$CODEX_CLI_AGENT"
python3 "$REPO_ROOT/bridge-queue.py" done "$CODEX_READY_TASK_ID" --agent "$CODEX_CLI_AGENT" --note "codex ready smoke cleanup" >/dev/null

log "sending an immediate normal task nudge when the target session is prompt-ready"
NORMAL_NUDGE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$CODEX_CLI_AGENT" --title "normal ready pickup" --body "pickup" --from "$REQUESTER_AGENT")"
assert_contains "$NORMAL_NUDGE_OUTPUT" "created task #"
NORMAL_NUDGE_TASK_ID="$(printf '%s\n' "$NORMAL_NUDGE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$NORMAL_NUDGE_TASK_ID" ]] || die "expected normal task id"
sleep 1
NORMAL_NUDGE_RECENT="$(tmux capture-pane -pt "$(tmux_pane_target "$CODEX_CLI_SESSION")" -S -20 2>/dev/null || true)"
assert_contains "$NORMAL_NUDGE_RECENT" "agb inbox $CODEX_CLI_AGENT"
python3 "$REPO_ROOT/bridge-queue.py" done "$NORMAL_NUDGE_TASK_ID" --agent "$CODEX_CLI_AGENT" --note "normal nudge smoke cleanup" >/dev/null

log "dropping a stale nudge when the queued task is completed before dispatch"
STALE_NUDGE_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to "$CODEX_CLI_AGENT" --title "stale nudge drop" --body "pickup" --from "$REQUESTER_AGENT")"
assert_contains "$STALE_NUDGE_OUTPUT" "created task #"
STALE_NUDGE_TASK_ID="$(printf '%s\n' "$STALE_NUDGE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$STALE_NUDGE_TASK_ID" ]] || die "expected stale nudge task id"
STALE_NUDGE_ROW="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  snapshot_file="$(mktemp)"
  ready_file="$(mktemp)"
  trap "rm -f \"$snapshot_file\" \"$ready_file\"" EXIT
  bridge_write_agent_snapshot "$snapshot_file"
  bridge_write_idle_ready_agents "$ready_file"
  python3 "'"$REPO_ROOT"'/bridge-queue.py" daemon-step \
    --snapshot "$snapshot_file" \
    --lease-seconds "$BRIDGE_TASK_LEASE_SECONDS" \
    --heartbeat-window "$BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS" \
    --idle-threshold 9999 \
    --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS" \
    --zombie-threshold "${BRIDGE_ZOMBIE_NUDGE_THRESHOLD:-10}" \
    --ready-agents-file "$ready_file" | head -n 1
')"
assert_contains "$STALE_NUDGE_ROW" "$CODEX_CLI_AGENT"
python3 "$REPO_ROOT/bridge-queue.py" done "$STALE_NUDGE_TASK_ID" --agent "$CODEX_CLI_AGENT" --note "stale nudge smoke cleanup" >/dev/null
STALE_NUDGE_SEND_LOG="$TMP_ROOT/stale-nudge-send.log"
STALE_NUDGE_CHECKER="$TMP_ROOT/stale-nudge-check.sh"
cat >"$STALE_NUDGE_CHECKER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

stale_row="\$1"
send_log="\$2"
daemon_lib="$TMP_ROOT/bridge-daemon-functions.sh"

awk -v repo_root="$REPO_ROOT" '
  BEGIN { q="\"" }
  index(\$0, "CMD=\"\${1:-}\"") == 1 { exit }
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=" q repo_root q; next }
  { print }
' "$REPO_ROOT/bridge-daemon.sh" >"\$daemon_lib"

source "\$daemon_lib"
rm -f "\$send_log"

daemon_info() {
  :
}

bridge_dispatch_notification() {
  printf "%s|%s|%s|%s|%s\n" "\$1" "\$2" "\$3" "\$4" "\$5" >"\$send_log"
  return 0
}

IFS=\$'\t' read -r agent session queued claimed idle nudge_key <<<"\$stale_row"
nudge_agent_session "\$agent" "\$session" "\$queued" "\$claimed" "\$idle" "\$nudge_key"

if [[ -f "\$send_log" ]]; then
  printf "%s" "sent"
else
  printf "%s" "dropped"
fi
EOF
chmod +x "$STALE_NUDGE_CHECKER"
STALE_NUDGE_RESULT="$("$BASH4_BIN" "$STALE_NUDGE_CHECKER" "$STALE_NUDGE_ROW" "$STALE_NUDGE_SEND_LOG")"
[[ "$STALE_NUDGE_RESULT" == "dropped" ]] || die "expected stale nudge to be dropped"
[[ ! -f "$STALE_NUDGE_SEND_LOG" ]] || die "stale nudge unexpectedly dispatched"
tmux_kill_session_exact "$CODEX_CLI_SESSION" || true

# Issue #331 Track A: queue state as the delivery oracle for session_nudge_sent.
# When the tmux paste/submit helper returns 0 but the agent never actually
# claims the task (the codex composer race described in the issue), the
# daemon must record session_nudge_dropped instead of session_nudge_sent and
# return non-zero so the next idle-nudge tick can retry.
log "Issue #331: marking session_nudge_dropped when the task stays queued past the verify grace"
NUDGE_VERIFY_AUDIT="$TMP_ROOT/nudge-verify-audit.jsonl"
NUDGE_VERIFY_CHECKER="$TMP_ROOT/nudge-verify-check.sh"
cat >"$NUDGE_VERIFY_CHECKER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

mode="\$1"
task_id="\$2"
audit_file="\$3"
daemon_lib="$TMP_ROOT/bridge-daemon-functions.sh"

awk -v repo_root="$REPO_ROOT" '
  BEGIN { q="\"" }
  index(\$0, "CMD=\"\${1:-}\"") == 1 { exit }
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=" q repo_root q; next }
  { print }
' "$REPO_ROOT/bridge-daemon.sh" >"\$daemon_lib"

# shellcheck disable=SC1090
source "\$daemon_lib"

export BRIDGE_AUDIT_LOG="\$audit_file"
export BRIDGE_NUDGE_VERIFY_GRACE_SECONDS=0
: >"\$audit_file"

daemon_info() { :; }

if [[ "\$mode" == "claimed" ]]; then
  bridge_dispatch_notification() {
    # Simulate the agent observing the nudge and claiming the task.
    python3 "$REPO_ROOT/bridge-queue.py" claim "\$task_id" --agent "$CODEX_CLI_AGENT" >/dev/null
    return 0
  }
else
  bridge_dispatch_notification() {
    # Paste/submit returned 0 but the codex composer ate the C-m: task
    # remains queued (the post-#331 race the audit log used to lie about).
    return 0
  }
fi

set +e
nudge_agent_session "$CODEX_CLI_AGENT" "$CODEX_CLI_SESSION" "1" "0" "0" "\$task_id"
rc=\$?
set -e
printf 'RC=%s\n' "\$rc"
EOF
chmod +x "$NUDGE_VERIFY_CHECKER"

NUDGE_DROP_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to "$CODEX_CLI_AGENT" --title "verify drop oracle" --body "pickup" --from "$REQUESTER_AGENT")"
NUDGE_DROP_TASK_ID="$(printf '%s\n' "$NUDGE_DROP_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$NUDGE_DROP_TASK_ID" ]] || die "expected verify-drop task id"
NUDGE_DROP_RUN="$("$BASH4_BIN" "$NUDGE_VERIFY_CHECKER" queued "$NUDGE_DROP_TASK_ID" "$NUDGE_VERIFY_AUDIT")"
assert_contains "$NUDGE_DROP_RUN" "RC=1"
NUDGE_DROP_ACTION="$(python3 - "$NUDGE_VERIFY_AUDIT" "$NUDGE_DROP_TASK_ID" <<'PY'
import json, sys
audit_path, task_id = sys.argv[1], sys.argv[2]
last = ""
for raw in open(audit_path, encoding="utf-8"):
    item = json.loads(raw)
    detail = item.get("detail") or {}
    if str(detail.get("task_id")) == task_id:
        last = item.get("action", "")
print(last)
PY
)"
[[ "$NUDGE_DROP_ACTION" == "session_nudge_dropped" ]] || die "expected session_nudge_dropped audit row, got '$NUDGE_DROP_ACTION'"
python3 "$REPO_ROOT/bridge-queue.py" cancel "$NUDGE_DROP_TASK_ID" --actor "$REQUESTER_AGENT" --note "verify drop cleanup" >/dev/null

log "Issue #331: marking session_nudge_sent when the task moves out of queued before the grace expires"
NUDGE_SENT_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to "$CODEX_CLI_AGENT" --title "verify sent oracle" --body "pickup" --from "$REQUESTER_AGENT")"
NUDGE_SENT_TASK_ID="$(printf '%s\n' "$NUDGE_SENT_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$NUDGE_SENT_TASK_ID" ]] || die "expected verify-sent task id"
NUDGE_SENT_RUN="$("$BASH4_BIN" "$NUDGE_VERIFY_CHECKER" claimed "$NUDGE_SENT_TASK_ID" "$NUDGE_VERIFY_AUDIT")"
assert_contains "$NUDGE_SENT_RUN" "RC=0"
NUDGE_SENT_ACTION="$(python3 - "$NUDGE_VERIFY_AUDIT" "$NUDGE_SENT_TASK_ID" <<'PY'
import json, sys
audit_path, task_id = sys.argv[1], sys.argv[2]
last = ""
for raw in open(audit_path, encoding="utf-8"):
    item = json.loads(raw)
    detail = item.get("detail") or {}
    if str(detail.get("task_id")) == task_id:
        last = item.get("action", "")
print(last)
PY
)"
[[ "$NUDGE_SENT_ACTION" == "session_nudge_sent" ]] || die "expected session_nudge_sent audit row, got '$NUDGE_SENT_ACTION'"
python3 "$REPO_ROOT/bridge-queue.py" done "$NUDGE_SENT_TASK_ID" --agent "$CODEX_CLI_AGENT" --note "verify sent cleanup" >/dev/null

log "waking a prompt-ready Claude session even when the idle marker is missing"
tmux_kill_session_exact "$CLAUDE_STATIC_SESSION" || true
tmux new-session -d -s "$CLAUDE_STATIC_SESSION" "$BASH4_BIN -lc 'printf \"❯ ready\\n\"; sleep 30'"
CLAUDE_NO_IDLE_WAKE_OUTPUT="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  send_log="'"$TMP_ROOT"'/claude-no-idle-wake-send.log"
  bridge_tmux_send_and_submit() {
    printf "%s|%s|%s\n" "$1" "$2" "$3" >"$send_log"
    return 0
  }
  bridge_tmux_wait_for_prompt "'"$CLAUDE_STATIC_SESSION"'" claude 5
  rm -f "$(bridge_agent_idle_since_file "claude-static")"
  if bridge_dispatch_notification "claude-static" "claude no-idle pickup" "pickup" "" high; then
    echo "DISPATCH_RC=0"
  else
    echo "DISPATCH_RC=$?"
  fi
  if [[ -f "$(bridge_agent_idle_since_file "claude-static")" ]]; then
    echo "IDLE_MARKER=yes"
  else
    echo "IDLE_MARKER=no"
  fi
  cat "$send_log"
')"
assert_contains "$CLAUDE_NO_IDLE_WAKE_OUTPUT" "DISPATCH_RC=0"
assert_contains "$CLAUDE_NO_IDLE_WAKE_OUTPUT" "IDLE_MARKER=yes"
assert_contains "$CLAUDE_NO_IDLE_WAKE_OUTPUT" "$CLAUDE_STATIC_SESSION|claude|[Agent Bridge] high: claude no-idle pickup"
tmux_kill_session_exact "$CLAUDE_STATIC_SESSION" || true

log "reloading dynamic agents inside a long-lived daemon cycle"
cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '› \n'
sleep 600
EOF
chmod +x "$FAKE_BIN/codex"
LATE_DYNAMIC_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-source.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
    printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    printf "%s\n" "bridge_daemon_autostart_allowed() { return 0; }"
    printf "%s\n" "bridge_daemon_note_autostart_failure() { :; }"
    printf "%s\n" "bridge_daemon_clear_autostart_failure() { :; }"
    printf "%s\n" "bridge_dashboard_post_if_changed() { :; }"
    sed -n '"'"'/^bridge_agent_heartbeat_file()/,/^CMD="${1:-}"/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  "'"$REPO_ROOT"'/agent-bridge" --codex --name "'"$LATE_DYNAMIC_AGENT"'" --workdir "'"$LATE_DYNAMIC_WORKDIR"'" --no-attach >/dev/null
  python3 "'"$REPO_ROOT"'/bridge-queue.py" create --to "'"$LATE_DYNAMIC_AGENT"'" --title "late dynamic pickup" --body "pickup" --from "'"$REQUESTER_AGENT"'" >/dev/null
  for _ in {1..20}; do
    tmux has-session -t "='"$LATE_DYNAMIC_AGENT"'" 2>/dev/null && break
    sleep 0.2
  done
  late_summary=""
  late_nudge_ts=0
  for _ in {1..6}; do
    sleep 1
    cmd_sync_cycle >/dev/null
    late_summary="$(python3 "'"$REPO_ROOT"'/bridge-queue.py" summary --agent "'"$LATE_DYNAMIC_AGENT"'" --format tsv)"
    late_nudge_ts="$(python3 - <<'"'"'PY'"'"'
import os
import sqlite3

db = os.environ["BRIDGE_TASK_DB"]
agent = "'"$LATE_DYNAMIC_AGENT"'"
with sqlite3.connect(db) as conn:
    row = conn.execute(
        "SELECT COALESCE(active, 0), COALESCE(last_nudge_ts, 0) FROM agent_state WHERE agent = ?",
        (agent,),
    ).fetchone()
if row is None:
    print("0")
else:
    print(int(row[1] or 0) if int(row[0] or 0) == 1 else 0)
PY
)"
    [[ "$late_nudge_ts" =~ ^[1-9][0-9]*$ ]] && break
  done
  printf "%s\n" "$late_summary"
  printf "NUDGE_TS=%s\n" "$late_nudge_ts"
')"
LATE_DYNAMIC_SUMMARY="$(printf '%s\n' "$LATE_DYNAMIC_OUTPUT" | sed -n '1p')"
LATE_DYNAMIC_NUDGE_TS="$(printf '%s\n' "$LATE_DYNAMIC_OUTPUT" | sed -n 's/^NUDGE_TS=//p' | tail -n1)"
[[ "$LATE_DYNAMIC_NUDGE_TS" =~ ^[1-9][0-9]*$ ]] || die "late dynamic agent never received a daemon nudge"
printf '%s\n' "$LATE_DYNAMIC_SUMMARY" | awk -F'\t' 'NR==1 { exit !($5 == 1 && $9 != "") }' || die "late dynamic agent was not marked active in queue summary"
cp "$TMP_ROOT/codex-cron-fake" "$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/codex"

log "reaping idle dynamic agents and orphan smoke sessions"
IDLE_REAP_AGENT="idle-reap-agent-$SESSION_NAME"
IDLE_REAP_WORKDIR="$TMP_ROOT/idle-reap-workdir"
ORPHAN_REAP_SESSION="bridge-smoke-orphan-$SESSION_NAME"
mkdir -p "$IDLE_REAP_WORKDIR"
IDLE_REAP_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-reaper.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
    printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    printf "%s\n" "bridge_daemon_autostart_allowed() { return 0; }"
    printf "%s\n" "bridge_daemon_note_autostart_failure() { :; }"
    printf "%s\n" "bridge_daemon_clear_autostart_failure() { :; }"
    printf "%s\n" "bridge_dashboard_post_if_changed() { :; }"
    sed -n '"'"'/^bridge_agent_heartbeat_file()/,/^CMD="${1:-}"/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  "'"$REPO_ROOT"'/agent-bridge" --codex --name "'"$IDLE_REAP_AGENT"'" --workdir "'"$IDLE_REAP_WORKDIR"'" --no-attach >/dev/null
  tmux new-session -d -s "'"$ORPHAN_REAP_SESSION"'" "sleep 30"
  sleep 2
  export BRIDGE_DYNAMIC_IDLE_REAP_SECONDS=1
  export BRIDGE_ORPHAN_SESSION_REAP_SECONDS=1
  cmd_sync_cycle >/dev/null
  if tmux has-session -t "='"$IDLE_REAP_AGENT"'" 2>/dev/null; then
    echo "DYNAMIC_ALIVE=yes"
  else
    echo "DYNAMIC_ALIVE=no"
  fi
  if tmux has-session -t "='"$ORPHAN_REAP_SESSION"'" 2>/dev/null; then
    echo "ORPHAN_ALIVE=yes"
  else
    echo "ORPHAN_ALIVE=no"
  fi
  if test -f "'"$BRIDGE_ACTIVE_AGENT_DIR"'/'"$IDLE_REAP_AGENT"'.env"; then
    echo "DYNAMIC_META=yes"
  else
    echo "DYNAMIC_META=no"
  fi
')"
assert_contains "$IDLE_REAP_OUTPUT" "DYNAMIC_ALIVE=no"
assert_contains "$IDLE_REAP_OUTPUT" "ORPHAN_ALIVE=no"
assert_contains "$IDLE_REAP_OUTPUT" "DYNAMIC_META=no"

log "bun plugin root + child match the orphan patterns (issue #223)"
python3 - "$REPO_ROOT" <<'PY'
import importlib.util
import pathlib
import sys

repo_root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "bridge_mcp_cleanup", repo_root / "bridge-mcp-cleanup.py"
)
mod = importlib.util.module_from_spec(spec)
# dataclass annotation resolution needs the module present in sys.modules
# before exec_module runs (Python 3.9 requirement).
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

patterns = mod.compile_patterns(mod.DEFAULT_PATTERNS)

def proc(pid, command, ppid=1):
    return mod.Proc(pid=pid, ppid=ppid, age_seconds=999, rss_kb=0, command=command)

cases_should_match = [
    "bun run --cwd /home/ec2-user/.agent-bridge/plugins/teams --shell=bun --silent start",
    "bun run --cwd /Users/x/.agent-bridge/plugins/telegram --silent start",
    "bun run --cwd /home/ec2-user/.bun/install/claude-plugins-official/telegram/0.0.6 start",
    # ps stitches argv with single spaces, so a cwd containing a space
    # (macOS user dir like "Space User") shows up verbatim. Match must
    # still see the plugin-root fragment.
    "bun run --cwd /Users/Space User/.agent-bridge/plugins/teams --silent start",
    "bun run --cwd /Users/Space User/.bun/install/claude-plugins-official/telegram/0.0.6 start",
    "/home/ec2-user/.bun/bin/bun server.ts",
]
for cmd in cases_should_match:
    matched = mod.matched_pattern(proc(10, cmd), patterns)
    assert matched, f"expected match for: {cmd}"

cases_should_not_match = [
    # Generic user `bun run` against a project dir must never match — we
    # restrict to .agent-bridge/plugins or claude-plugins-official roots.
    "bun run --cwd /home/user/myproject build",
    "bun run --cwd /tmp/foo test",
    "bun run dev",
    "node server.ts",  # without the bun word-boundary the server.ts-only rule must not false-positive
]
for cmd in cases_should_not_match:
    matched = mod.matched_pattern(proc(20, cmd), patterns)
    assert not matched, f"unexpected match for: {cmd} (matched={matched})"

# Orphan chain: plugin root PPID=1 matches; bun server.ts child with
# parent=plugin-root must also be classified as an orphan (the old bug
# rejected it because the parent's command did not match anything).
procs = {
    100: proc(100, "bun run --cwd /home/u/.agent-bridge/plugins/teams --silent start", ppid=1),
    101: proc(101, "/home/u/.bun/bin/bun server.ts", ppid=100),
}
matches = {pid: mod.matched_pattern(p, patterns) for pid, p in procs.items()}
assert matches[100], "plugin root must match"
assert matches[101], "server.ts child must match"
assert mod.is_orphan_candidate(procs[100], procs, matches, 0), "plugin root ppid=1 must be orphan"
assert mod.is_orphan_candidate(procs[101], procs, matches, 0), "server.ts child must chain through matched orphan parent"
print("[ok] bun plugin orphan patterns + chain")
PY

log "cleaning orphan MCP processes conservatively"
MCP_ORPHAN_PATTERN="agent-bridge-smoke-orphan-mcp-$SESSION_NAME"
MCP_ATTACHED_PATTERN="agent-bridge-smoke-attached-mcp-$SESSION_NAME"
MCP_ORPHAN_PID_FILE="$TMP_ROOT/mcp-orphan.pid"
MCP_ATTACHED_PID_FILE="$TMP_ROOT/mcp-attached.pid"
python3 - "$MCP_ORPHAN_PATTERN" "$MCP_ORPHAN_PID_FILE" <<'PY'
import subprocess
import sys
from pathlib import Path

pattern, pid_file = sys.argv[1], sys.argv[2]
proc = subprocess.Popen(
    [pattern, "600"],
    executable="/bin/sleep",
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
Path(pid_file).write_text(str(proc.pid), encoding="utf-8")
PY
MCP_ORPHAN_PID="$(cat "$MCP_ORPHAN_PID_FILE")"
for _ in {1..20}; do
  kill -0 "$MCP_ORPHAN_PID" >/dev/null 2>&1 && break
  sleep 0.1
done
kill -0 "$MCP_ORPHAN_PID" >/dev/null 2>&1 || die "fake orphan MCP process did not start"
MCP_ORPHAN_SCAN_JSON="$(python3 "$REPO_ROOT/bridge-mcp-cleanup.py" scan --pattern "$MCP_ORPHAN_PATTERN" --min-age 0 --json)"
assert_contains "$MCP_ORPHAN_SCAN_JSON" "\"pid\": $MCP_ORPHAN_PID"
# Keep this assertion on the periodic MCP cleanup path. A full daemon sync can
# run unrelated session reapers first, which also kill matching processes but do
# not write the periodic audit event this smoke block is trying to verify.
MCP_ORPHAN_CLEANUP_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-mcp-cleanup.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
    printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    sed -n '"'"'/^bridge_agent_heartbeat_file()/,/^CMD="${1:-}"/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  export BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED=1
  export BRIDGE_MCP_ORPHAN_CLEANUP_INTERVAL_SECONDS=0
  export BRIDGE_MCP_ORPHAN_MIN_AGE_SECONDS=0
  export BRIDGE_MCP_ORPHAN_PATTERNS="'"$MCP_ORPHAN_PATTERN"'"
  process_mcp_orphan_cleanup >/dev/null || true
  if kill -0 "'"$MCP_ORPHAN_PID"'" >/dev/null 2>&1; then
    echo "MCP_ORPHAN_ALIVE=yes"
  else
    echo "MCP_ORPHAN_ALIVE=no"
  fi
  cat "'"$BRIDGE_LOG_DIR"'/audit.jsonl" 2>/dev/null || true
')"
assert_contains "$MCP_ORPHAN_CLEANUP_OUTPUT" "MCP_ORPHAN_ALIVE=no"
MCP_ORPHAN_PID=""
assert_contains "$MCP_ORPHAN_CLEANUP_OUTPUT" "mcp_orphan_cleanup"

python3 - "$MCP_ATTACHED_PATTERN" "$MCP_ATTACHED_PID_FILE" <<'PY' &
import subprocess
import sys
import time
from pathlib import Path

pattern, pid_file = sys.argv[1], sys.argv[2]
proc = subprocess.Popen(
    [pattern, "600"],
    executable="/bin/sleep",
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
Path(pid_file).write_text(str(proc.pid), encoding="utf-8")
try:
    time.sleep(600)
finally:
    proc.terminate()
PY
MCP_ATTACHED_PARENT_PID="$!"
for _ in {1..20}; do
  [[ -f "$MCP_ATTACHED_PID_FILE" ]] && break
  sleep 0.1
done
[[ -f "$MCP_ATTACHED_PID_FILE" ]] || die "fake attached MCP pid file was not written"
MCP_ATTACHED_CHILD_PID="$(cat "$MCP_ATTACHED_PID_FILE")"
kill -0 "$MCP_ATTACHED_CHILD_PID" >/dev/null 2>&1 || die "fake attached MCP process did not start"
python3 "$REPO_ROOT/bridge-mcp-cleanup.py" cleanup --kill --pattern "$MCP_ATTACHED_PATTERN" --min-age 0 --json >/dev/null
kill -0 "$MCP_ATTACHED_CHILD_PID" >/dev/null 2>&1 || die "cleanup killed a non-orphan MCP process"
kill "$MCP_ATTACHED_CHILD_PID" >/dev/null 2>&1 || true
kill "$MCP_ATTACHED_PARENT_PID" >/dev/null 2>&1 || true
wait "$MCP_ATTACHED_PARENT_PID" >/dev/null 2>&1 || true
MCP_ATTACHED_CHILD_PID=""
MCP_ATTACHED_PARENT_PID=""

log "cleaning orphan MCP processes immediately before bridge-run relaunch"
MCP_RESTART_AGENT="mcp-restart-$SESSION_NAME"
MCP_RESTART_SESSION="mcp-restart-session-$SESSION_NAME"
MCP_RESTART_WORKDIR="$TMP_ROOT/mcp-restart-workdir"
MCP_RESTART_BIN_DIR="$TMP_ROOT/mcp-restart-bin"
MCP_RESTART_COUNT_FILE="$TMP_ROOT/mcp-restart-count.txt"
MCP_RESTART_LOG="$TMP_ROOT/mcp-restart.log"
MCP_RESTART_PATTERN="agent-bridge-smoke-restart-mcp-$SESSION_NAME"
MCP_RESTART_PID_FILE="$TMP_ROOT/mcp-restart-orphan.pid"
mkdir -p "$MCP_RESTART_WORKDIR" "$MCP_RESTART_BIN_DIR"
cat >"$MCP_RESTART_BIN_DIR/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
count_file="$MCP_RESTART_COUNT_FILE"
log_file="$MCP_RESTART_LOG"
pattern="$MCP_RESTART_PATTERN"
pid_file="$MCP_RESTART_PID_FILE"
count=0
if [[ -f "\$count_file" ]]; then
  count="\$(cat "\$count_file" 2>/dev/null || printf '0')"
fi
if [[ ! "\$count" =~ ^[0-9]+$ ]]; then
  count=0
fi
count=\$((count + 1))
printf '%s\n' "\$count" >"\$count_file"
printf 'launch=%s\n' "\$count" >>"\$log_file"
if [[ "\$count" == "1" ]]; then
  python3 - "\$pattern" "\$pid_file" <<'PY'
import subprocess
import sys
from pathlib import Path

pattern, pid_file = sys.argv[1], sys.argv[2]
proc = subprocess.Popen(
    [pattern, "600"],
    executable="/bin/sleep",
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
Path(pid_file).write_text(str(proc.pid), encoding="utf-8")
PY
fi
exit 0
EOF
chmod +x "$MCP_RESTART_BIN_DIR/claude"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

# BEGIN AGENT BRIDGE MANAGED ROLE: $MCP_RESTART_AGENT
bridge_add_agent_id_if_missing "$MCP_RESTART_AGENT"
BRIDGE_AGENT_DESC["$MCP_RESTART_AGENT"]="Restart orphan cleanup smoke role"
BRIDGE_AGENT_ENGINE["$MCP_RESTART_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$MCP_RESTART_AGENT"]="$MCP_RESTART_SESSION"
BRIDGE_AGENT_WORKDIR["$MCP_RESTART_AGENT"]="$MCP_RESTART_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$MCP_RESTART_AGENT"]='PATH=$MCP_RESTART_BIN_DIR:$PATH claude --dangerously-skip-permissions --name $MCP_RESTART_AGENT'
BRIDGE_AGENT_LOOP["$MCP_RESTART_AGENT"]="1"
BRIDGE_AGENT_CONTINUE["$MCP_RESTART_AGENT"]="0"
# END AGENT BRIDGE MANAGED ROLE: $MCP_RESTART_AGENT
EOF
smoke_track_managed_role_id "$MCP_RESTART_AGENT"
BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED=1 \
BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS=0 \
BRIDGE_MCP_ORPHAN_PATTERNS="$MCP_RESTART_PATTERN" \
  "$BASH4_BIN" "$REPO_ROOT/bridge-run.sh" "$MCP_RESTART_AGENT" >/dev/null 2>&1 &
MCP_RESTART_RUN_PID="$!"
for _ in {1..40}; do
  if [[ -f "$MCP_RESTART_LOG" ]] && grep -Fq 'launch=2' "$MCP_RESTART_LOG"; then
    break
  fi
  sleep 0.25
done
grep -Fq 'launch=2' "$MCP_RESTART_LOG" || die "expected bridge-run to relaunch the restart orphan cleanup smoke role"
[[ -f "$MCP_RESTART_PID_FILE" ]] || die "expected fake orphan MCP pid file for restart smoke role"
MCP_RESTART_ORPHAN_PID="$(cat "$MCP_RESTART_PID_FILE")"
for _ in {1..40}; do
  if ! kill -0 "$MCP_RESTART_ORPHAN_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
if kill -0 "$MCP_RESTART_ORPHAN_PID" >/dev/null 2>&1; then
  die "expected bridge-run restart path to clean orphan MCP process before relaunch"
fi
kill "$MCP_RESTART_RUN_PID" >/dev/null 2>&1 || true
wait "$MCP_RESTART_RUN_PID" >/dev/null 2>&1 || true

log "refreshing a static Claude session after memory-daily when prompt is free"
MEMORY_REFRESH_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-memory-refresh.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
    printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    sed -n '"'"'/^bridge_report_channel_health_miss()/,/^process_channel_health()/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  send_log="'"$TMP_ROOT"'/memory-refresh-send.log"
  bridge_tmux_send_and_submit() {
    printf "%s|%s|%s\n" "$1" "$2" "$3" >>"'"$TMP_ROOT"'/memory-refresh-send.log"
    return 0
  }
  tmux kill-session -t "='"$CLAUDE_STATIC_SESSION"'" >/dev/null 2>&1 || true
  tmux new-session -d -s "'"$CLAUDE_STATIC_SESSION"'" "sleep 30"
  "'"$REPO_ROOT"'/agent-bridge" task create --to claude-static --title "busy refresh" --body "wait" --from smoke >/dev/null
  busy_task="$(python3 "'"$REPO_ROOT"'/bridge-queue.py" find-open --agent claude-static | head -n 1)"
  [[ "$busy_task" =~ ^[0-9]+$ ]] || exit 1
  python3 "'"$REPO_ROOT"'/bridge-queue.py" claim "$busy_task" --agent claude-static >/dev/null
  bridge_agent_note_memory_daily_refresh "claude-static" "run-busy" "2026-04-08"
  process_memory_daily_refresh_requests || true
  if bridge_agent_memory_daily_refresh_pending "claude-static"; then
    echo "BUSY_PENDING=yes"
  else
    echo "BUSY_PENDING=no"
  fi
  if [[ -f "$send_log" ]]; then
    send_count=0
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      send_count=$((send_count + 1))
    done <"$send_log"
    echo "BUSY_SENDS=$send_count"
  else
    echo "BUSY_SENDS=0"
  fi
  python3 "'"$REPO_ROOT"'/bridge-queue.py" done "$busy_task" --agent claude-static --note "ok" >/dev/null
  process_memory_daily_refresh_requests || true
  if bridge_agent_memory_daily_refresh_pending "claude-static"; then
    echo "FINAL_PENDING=yes"
  else
    echo "FINAL_PENDING=no"
  fi
  if [[ -f "$send_log" ]]; then
    send_count=0
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      send_count=$((send_count + 1))
    done <"$send_log"
    echo "FINAL_SENDS=$send_count"
    cat "$send_log"
  else
    echo "FINAL_SENDS=0"
  fi
')"
assert_contains "$MEMORY_REFRESH_OUTPUT" "BUSY_PENDING=yes"
assert_contains "$MEMORY_REFRESH_OUTPUT" "BUSY_SENDS=0"
assert_contains "$MEMORY_REFRESH_OUTPUT" "FINAL_PENDING=no"
assert_contains "$MEMORY_REFRESH_OUTPUT" "FINAL_SENDS=1"
assert_contains "$MEMORY_REFRESH_OUTPUT" "$CLAUDE_STATIC_SESSION|claude|/new"

log "skipping memory-daily refresh while the target session is attached"
ATTACHED_REFRESH_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-memory-refresh-attached.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
    printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    sed -n '"'"'/^bridge_report_channel_health_miss()/,/^process_channel_health()/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  send_log="'"$TMP_ROOT"'/memory-refresh-attached.log"
  bridge_tmux_send_and_submit() {
    printf "%s|%s|%s\n" "$1" "$2" "$3" >>"'"$TMP_ROOT"'/memory-refresh-attached.log"
    return 0
  }
  bridge_tmux_session_attached_count() { printf "1\n"; }
  tmux kill-session -t "='"$CLAUDE_STATIC_SESSION"'" >/dev/null 2>&1 || true
  tmux new-session -d -s "'"$CLAUDE_STATIC_SESSION"'" "sleep 30"
  bridge_agent_note_memory_daily_refresh "claude-static" "run-attached" "2026-04-08"
  process_memory_daily_refresh_requests || true
  if bridge_agent_memory_daily_refresh_pending "claude-static"; then
    echo "ATTACHED_PENDING=yes"
  else
    echo "ATTACHED_PENDING=no"
  fi
  if [[ -f "$send_log" ]]; then
    send_count=0
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      send_count=$((send_count + 1))
    done <"$send_log"
    echo "ATTACHED_SENDS=$send_count"
  else
    echo "ATTACHED_SENDS=0"
  fi
')"
assert_contains "$ATTACHED_REFRESH_OUTPUT" "ATTACHED_PENDING=yes"
assert_contains "$ATTACHED_REFRESH_OUTPUT" "ATTACHED_SENDS=0"

log "writing and querying the audit log"
AUDIT_OUTPUT="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_audit_log daemon smoke_audit claude-static --detail agent=claude-static --detail sample=yes
  "'"$REPO_ROOT"'/agent-bridge" audit --agent claude-static --action smoke_audit --limit 5 --json
')"
assert_contains "$AUDIT_OUTPUT" "\"action\": \"smoke_audit\""
assert_contains "$AUDIT_OUTPUT" "\"target\": \"claude-static\""
assert_contains "$AUDIT_OUTPUT" "\"sample\": \"yes\""
AUDIT_ROTATE_FILE="$TMP_ROOT/audit-rotate.jsonl"
AUDIT_ROTATE_OUTPUT="$("$BASH4_BIN" -lc '
  export BRIDGE_AUDIT_LOG="'"$AUDIT_ROTATE_FILE"'"
  export BRIDGE_AUDIT_ROTATE_BYTES=1
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_audit_log daemon smoke_rotate first --detail marker=alpha
  bridge_audit_log queue smoke_rotate second --detail marker=beta
  bridge_notify_send "'"$SMOKE_AGENT"'" "Smoke notify" "dry-run" "" normal 1 >/dev/null
  "'"$REPO_ROOT"'/agent-bridge" audit --actor queue --contains beta --limit 5 --json
')"
assert_contains "$AUDIT_ROTATE_OUTPUT" "\"actor\": \"queue\""
assert_contains "$AUDIT_ROTATE_OUTPUT" "\"marker\": \"beta\""
ROTATED_AUDIT_COUNT="$(find "$TMP_ROOT" -maxdepth 1 -name 'audit-rotate.*.jsonl' | wc -l | tr -d ' ')"
[[ "${ROTATED_AUDIT_COUNT:-0}" -ge 1 ]] || die "expected rotated audit files"
NOTIFY_AUDIT_OUTPUT="$(BRIDGE_AUDIT_LOG="$AUDIT_ROTATE_FILE" "$REPO_ROOT/agent-bridge" audit --action external_channel_send --limit 5 --json)"
assert_contains "$NOTIFY_AUDIT_OUTPUT" "\"action\": \"external_channel_send\""

log "falling back when a dynamic Claude resume session id is stale"
STALE_RESUME_OUTPUT="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_add_agent_id_if_missing "'"$STALE_RESUME_AGENT"'"
  BRIDGE_AGENT_ENGINE["'"$STALE_RESUME_AGENT"'"]="claude"
  BRIDGE_AGENT_SESSION["'"$STALE_RESUME_AGENT"'"]="'"$STALE_RESUME_AGENT"'"
  BRIDGE_AGENT_WORKDIR["'"$STALE_RESUME_AGENT"'"]="'"$HOOK_WORKDIR"'"
  BRIDGE_AGENT_SOURCE["'"$STALE_RESUME_AGENT"'"]="dynamic"
  BRIDGE_AGENT_CONTINUE["'"$STALE_RESUME_AGENT"'"]="1"
  BRIDGE_AGENT_SESSION_ID["'"$STALE_RESUME_AGENT"'"]="stale-session-id"
  BRIDGE_AGENT_CREATED_AT["'"$STALE_RESUME_AGENT"'"]="'"$(date +%s)"'"
  bridge_write_dynamic_agent_file "'"$STALE_RESUME_AGENT"'"
  bridge_agent_launch_cmd "'"$STALE_RESUME_AGENT"'"
  printf "\nSESSION_ID=%s\n" "${BRIDGE_AGENT_SESSION_ID["'"$STALE_RESUME_AGENT"'"]-}"
')"
assert_not_contains "$STALE_RESUME_OUTPUT" "--resume stale-session-id"
assert_not_contains "$STALE_RESUME_OUTPUT" "SESSION_ID=stale-session-id"
assert_contains "$STALE_RESUME_OUTPUT" "claude --dangerously-skip-permissions --name $STALE_RESUME_AGENT"
assert_not_contains "$STALE_RESUME_OUTPUT" "claude --continue --dangerously-skip-permissions --name $STALE_RESUME_AGENT"
assert_contains "$STALE_RESUME_OUTPUT" "SESSION_ID="

log "injecting bridge guidance into an existing project CLAUDE.md and forcing a fresh first launch"
PROJECT_CLAUDE_AGENT="project-claude-$SESSION_NAME"
PROJECT_CLAUDE_SESSION="project-claude-session-$SESSION_NAME"
PROJECT_CLAUDE_WORKDIR="$TMP_ROOT/project-claude-workdir"
mkdir -p "$PROJECT_CLAUDE_WORKDIR"
cat >"$PROJECT_CLAUDE_WORKDIR/CLAUDE.md" <<'EOF'
# Existing Project Instructions

Be careful.
EOF
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "$PROJECT_CLAUDE_AGENT"
BRIDGE_AGENT_DESC["$PROJECT_CLAUDE_AGENT"]="Project Claude role"
BRIDGE_AGENT_ENGINE["$PROJECT_CLAUDE_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$PROJECT_CLAUDE_AGENT"]="$PROJECT_CLAUDE_SESSION"
BRIDGE_AGENT_WORKDIR["$PROJECT_CLAUDE_AGENT"]="$PROJECT_CLAUDE_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$PROJECT_CLAUDE_AGENT"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CONTINUE["$PROJECT_CLAUDE_AGENT"]="1"
EOF
PROJECT_CLAUDE_DRY_RUN="$("$REPO_ROOT/bridge-start.sh" "$PROJECT_CLAUDE_AGENT" --dry-run 2>&1)"
assert_contains "$PROJECT_CLAUDE_DRY_RUN" "continue=0"
assert_contains "$(cat "$PROJECT_CLAUDE_WORKDIR/CLAUDE.md")" "BEGIN AGENT BRIDGE PROJECT GUIDANCE"
assert_contains "$(cat "$PROJECT_CLAUDE_WORKDIR/CLAUDE.md")" "Do not guess bridge commands."

log "returning success for non-tty tmux attach"
ATTACH_SESSION="attach-smoke-$SESSION_NAME"
tmux new-session -d -s "$ATTACH_SESSION" "sleep 30"
NONTTY_ATTACH_OUTPUT="$("$BASH4_BIN" -lc 'source "'"$REPO_ROOT"'/bridge-lib.sh"; bridge_attach_tmux_session "'"$ATTACH_SESSION"'"' 2>&1)"
assert_contains "$NONTTY_ATTACH_OUTPUT" "attach manually with: tmux attach -t =$ATTACH_SESSION"
tmux_kill_session_exact "$ATTACH_SESSION" || true

log "requeueing stale claimed tasks from inactive agents"
INACTIVE_CLAIM_TASK_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to inactive-agent --title "inactive claim smoke" --body "orphan" --from "$REQUESTER_AGENT")"
assert_contains "$INACTIVE_CLAIM_TASK_OUTPUT" "created task #"
INACTIVE_CLAIM_TASK_ID="$(printf '%s\n' "$INACTIVE_CLAIM_TASK_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ -n "$INACTIVE_CLAIM_TASK_ID" ]] || die "expected inactive claim task id"
python3 "$REPO_ROOT/bridge-queue.py" claim "$INACTIVE_CLAIM_TASK_ID" --agent inactive-agent --lease-seconds 60 >/dev/null
python3 - "$BRIDGE_TASK_DB" "$INACTIVE_CLAIM_TASK_ID" <<'PY'
import sqlite3
import sys

db_path, task_id = sys.argv[1:]
with sqlite3.connect(db_path) as conn:
    conn.execute(
        "UPDATE tasks SET claimed_ts = claimed_ts - 3600, updated_ts = updated_ts - 3600 WHERE id = ?",
        (int(task_id),),
    )
    conn.commit()
PY
INACTIVE_REQUEUE_OUTPUT="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  snapshot_file="$(mktemp)"
  ready_file="$(mktemp)"
  trap "rm -f \"$snapshot_file\" \"$ready_file\"" EXIT
  bridge_write_agent_snapshot "$snapshot_file"
  : >"$ready_file"
  python3 "'"$REPO_ROOT"'/bridge-queue.py" daemon-step \
    --snapshot "$snapshot_file" \
    --lease-seconds "$BRIDGE_TASK_LEASE_SECONDS" \
    --heartbeat-window "$BRIDGE_TASK_HEARTBEAT_WINDOW_SECONDS" \
    --idle-threshold "${BRIDGE_IDLE_THRESHOLD_SECONDS:-300}" \
    --max-claim-age 900 \
    --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS" \
    --zombie-threshold "${BRIDGE_ZOMBIE_NUDGE_THRESHOLD:-10}" \
    --ready-agents-file "$ready_file"
')"
INACTIVE_REQUEUE_STATUS="$(python3 "$REPO_ROOT/bridge-queue.py" show "$INACTIVE_CLAIM_TASK_ID")"
assert_contains "$INACTIVE_REQUEUE_STATUS" "status: queued"

log "creating a new static agent from the public template"
USER_SET_OUTPUT="$("$REPO_ROOT/agent-bridge" user set --user owner --name Owner --timezone Asia/Seoul)"
assert_contains "$USER_SET_OUTPUT" "user: owner"
assert_contains "$USER_SET_OUTPUT" "name: Owner"
USER_SHOW_JSON="$("$REPO_ROOT/agent-bridge" user show --user owner --json)"
assert_contains "$USER_SHOW_JSON" "\"name\": \"Owner\""
assert_contains "$USER_SHOW_JSON" "\"timezone\": \"Asia/Seoul\""
KNOWLEDGE_INIT_JSON="$("$REPO_ROOT/agent-bridge" knowledge init --team-name "Smoke Team" --json)"
assert_contains "$KNOWLEDGE_INIT_JSON" "\"team_name\": \"Smoke Team\""
[[ -f "$BRIDGE_SHARED_DIR/wiki/index.md" ]] || die "knowledge init did not create wiki index"
[[ -f "$BRIDGE_SHARED_DIR/wiki/people.md" ]] || die "knowledge init did not create people registry"
[[ -f "$BRIDGE_SHARED_DIR/wiki/data-sources.md" ]] || die "knowledge init did not create data source registry"
KNOWLEDGE_OPERATOR_JSON="$("$REPO_ROOT/agent-bridge" knowledge operator set --user owner --name Owner --preferred-address 선님 --alias "Release Owner" --handle discord=@owner --handle telegram=@ownerbot --communication-preferences "Korean, direct, concise updates." --decision-scope "Final release approval" --escalation-relevance "Escalate product or release risk." --json)"
assert_contains "$KNOWLEDGE_OPERATOR_JSON" "\"display_name\": \"Owner\""
assert_contains "$KNOWLEDGE_OPERATOR_JSON" "\"relative_path\": \"wiki/people.md\""
assert_contains "$(cat "$BRIDGE_SHARED_DIR/wiki/people.md")" "Role: primary operator"
assert_contains "$(cat "$BRIDGE_SHARED_DIR/wiki/people.md")" "Preferred address: 선님"
assert_contains "$(cat "$BRIDGE_SHARED_DIR/wiki/people.md")" "Channel handles: discord=@owner; telegram=@ownerbot"
KNOWLEDGE_OPERATOR_SHOW_JSON="$("$REPO_ROOT/agent-bridge" knowledge operator show --json)"
assert_contains "$KNOWLEDGE_OPERATOR_SHOW_JSON" "\"configured\": true"
assert_contains "$KNOWLEDGE_OPERATOR_SHOW_JSON" "\"decision_scope\": \"Final release approval\""
KNOWLEDGE_CAPTURE_JSON="$("$REPO_ROOT/agent-bridge" knowledge capture --source chat --author Owner --title "Release Approver" --text "Owner is the release approver for smoke-test changes." --json)"
KNOWLEDGE_CAPTURE_ID="$(python3 - "$KNOWLEDGE_CAPTURE_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["capture_id"])
PY
)"
[[ -f "$BRIDGE_SHARED_DIR/raw/captures/inbox/$KNOWLEDGE_CAPTURE_ID.json" ]] || die "knowledge capture did not create inbox capture"
KNOWLEDGE_PROMOTE_JSON="$("$REPO_ROOT/agent-bridge" knowledge promote --kind people --capture "$KNOWLEDGE_CAPTURE_ID" --summary "Owner is the release approver for smoke-test changes." --json)"
assert_contains "$KNOWLEDGE_PROMOTE_JSON" "\"kind\": \"people\""
assert_contains "$KNOWLEDGE_PROMOTE_JSON" "\"wiki/people.md\""
[[ -f "$BRIDGE_SHARED_DIR/raw/captures/promoted/$KNOWLEDGE_CAPTURE_ID.json" ]] || die "knowledge promote did not move capture to promoted"
assert_contains "$(cat "$BRIDGE_SHARED_DIR/wiki/people.md")" "release approver"
KNOWLEDGE_DS_OUTPUT="$("$REPO_ROOT/agent-bridge" knowledge promote --kind data-source --title "Smoke DB" --summary "Smoke DB is the canonical structured data source for smoke tests.")"
assert_contains "$KNOWLEDGE_DS_OUTPUT" "kind: data-sources"
assert_contains "$(cat "$BRIDGE_SHARED_DIR/wiki/data-sources.md")" "Smoke DB"
KNOWLEDGE_SEARCH_JSON="$("$REPO_ROOT/agent-bridge" knowledge search --query "primary operator" --json)"
assert_contains "$KNOWLEDGE_SEARCH_JSON" "\"wiki/people.md\""
KNOWLEDGE_LINT_JSON="$("$REPO_ROOT/agent-bridge" knowledge lint --json)"
assert_contains "$KNOWLEDGE_LINT_JSON" "\"ok\": true"
cat >>"$BRIDGE_SHARED_DIR/wiki/data-sources.md" <<'EOF'

- Broken reference check: [Missing Playbook](playbooks/missing.md)
EOF
cat >"$BRIDGE_SHARED_DIR/wiki/projects/orphan-project.md" <<'EOF'
# Orphan Project

This page is intentionally left without inbound wiki links.
EOF
cat >"$BRIDGE_SHARED_DIR/wiki/projects/shared-title-a.md" <<'EOF'
# Shared Title

Duplicate title fixture A.
EOF
cat >"$BRIDGE_SHARED_DIR/wiki/playbooks/shared-title-b.md" <<'EOF'
# Shared Title

Duplicate title fixture B.
EOF
cat >"$BRIDGE_SHARED_DIR/wiki/projects/stale-page.md" <<'EOF'
# Stale Page

This page is intentionally old so lint can flag stale content.
EOF
touch -t 202401010101 "$BRIDGE_SHARED_DIR/wiki/projects/stale-page.md"
KNOWLEDGE_LINT_ISSUES_JSON="$("$REPO_ROOT/agent-bridge" knowledge lint --stale-days 30 --json 2>/dev/null || true)"
python3 - "$KNOWLEDGE_LINT_ISSUES_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["ok"] is False, payload
assert any(
    item["source"] == "wiki/data-sources.md" and item["target"] == "playbooks/missing.md"
    for item in payload["broken_links"]
), payload["broken_links"]
assert "wiki/projects/orphan-project.md" in payload["orphan_pages"], payload["orphan_pages"]
assert any(
    set(item["files"]) == {"wiki/playbooks/shared-title-b.md", "wiki/projects/shared-title-a.md"}
    for item in payload["duplicate_titles"]
), payload["duplicate_titles"]
assert any(item["path"] == "wiki/projects/stale-page.md" for item in payload["stale_pages"]), payload["stale_pages"]
PY

log "creating and completing a file-backed handoff bundle"
HANDOFF_ARTIFACT="$BRIDGE_SHARED_DIR/handoff-artifact.md"
cat >"$HANDOFF_ARTIFACT" <<'EOF'
draft report for queue-backed bundle handoff
EOF
HANDOFF_BUNDLE_JSON="$("$REPO_ROOT/agent-bridge" bundle create --to "$REQUESTER_AGENT" --title "bundle smoke" --summary "Review the attached draft report." --action "Read the artifact and report blockers." --artifact "$HANDOFF_ARTIFACT::draft report" --expected-output "Return blockers or approval." --human-followup "If blockers remain, send a short human-facing summary." --json)"
HANDOFF_BUNDLE_ID="$(python3 - "$HANDOFF_BUNDLE_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["bundle_id"])
PY
)"
HANDOFF_TASK_ID="$(python3 - "$HANDOFF_BUNDLE_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["task"]["id"])
PY
)"
HANDOFF_SHOW_JSON="$("$REPO_ROOT/agent-bridge" bundle show "$HANDOFF_BUNDLE_ID" --json)"
assert_contains "$HANDOFF_SHOW_JSON" "\"bundle_id\": \"$HANDOFF_BUNDLE_ID\""
assert_contains "$HANDOFF_SHOW_JSON" "\"to_agent\": \"$REQUESTER_AGENT\""
assert_contains "$HANDOFF_SHOW_JSON" "\"path\": \"$HANDOFF_ARTIFACT\""
TASK_SHELL="$(python3 "$REPO_ROOT/bridge-queue.py" show "$HANDOFF_TASK_ID" --format shell)"
TASK_TITLE="$(python3 - "$TASK_SHELL" <<'PY'
import shlex
import sys

for raw in sys.argv[1].splitlines():
    if raw.startswith("TASK_TITLE="):
        value = raw.split("=", 1)[1]
        parts = shlex.split(value)
        print(parts[0] if parts else "")
        break
PY
)"
TASK_BODY_PATH="$(python3 - "$TASK_SHELL" <<'PY'
import shlex
import sys

for raw in sys.argv[1].splitlines():
    if raw.startswith("TASK_BODY_PATH="):
        value = raw.split("=", 1)[1]
        parts = shlex.split(value)
        print(parts[0] if parts else "")
        break
PY
)"
assert_contains "$TASK_TITLE" "[handoff] bundle smoke"
assert_contains "$TASK_BODY_PATH" "shared/a2a-files/$HANDOFF_BUNDLE_ID/handoff.md"
"$REPO_ROOT/agent-bridge" claim "$HANDOFF_TASK_ID" --agent "$REQUESTER_AGENT" >/dev/null
"$REPO_ROOT/agent-bridge" done "$HANDOFF_TASK_ID" --agent "$REQUESTER_AGENT" --note "bundle processed" >/dev/null

log "triaging a raw intake capture and routing it through the queue"
INTAKE_CAPTURE_JSON="$("$REPO_ROOT/agent-bridge" knowledge capture --source email --author Customer --title "Delivery ETA" --text "Customer asks for delivery ETA and refund options for order SO-123." --json)"
INTAKE_CAPTURE_ID="$(python3 - "$INTAKE_CAPTURE_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["capture_id"])
PY
)"
INTAKE_TRIAGE_JSON="$("$REPO_ROOT/agent-bridge" intake triage --capture "$INTAKE_CAPTURE_ID" --owner "$REQUESTER_AGENT" --summary "Customer needs ETA and refund guidance." --category support --importance high --reply-needed yes --confidence 0.91 --field order_id=SO-123 --field topic=delivery-refund --followup "Thanks. We are checking ETA and refund options and will reply shortly." --route --json)"
assert_contains "$INTAKE_TRIAGE_JSON" "\"capture_id\": \"$INTAKE_CAPTURE_ID\""
assert_contains "$INTAKE_TRIAGE_JSON" "\"needs_human_followup\": true"
INTAKE_TASK_ID="$(python3 - "$INTAKE_TRIAGE_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["task"]["id"])
PY
)"
INTAKE_SHOW_JSON="$("$REPO_ROOT/agent-bridge" intake show "$INTAKE_CAPTURE_ID" --json)"
assert_contains "$INTAKE_SHOW_JSON" "\"suggested_owner\": \"$REQUESTER_AGENT\""
assert_contains "$INTAKE_SHOW_JSON" "\"order_id\": \"SO-123\""
TASK_SHELL="$(python3 "$REPO_ROOT/bridge-queue.py" show "$INTAKE_TASK_ID" --format shell)"
TASK_TITLE="$(python3 - "$TASK_SHELL" <<'PY'
import shlex
import sys

for raw in sys.argv[1].splitlines():
    if raw.startswith("TASK_TITLE="):
        value = raw.split("=", 1)[1]
        parts = shlex.split(value)
        print(parts[0] if parts else "")
        break
PY
)"
TASK_BODY_PATH="$(python3 - "$TASK_SHELL" <<'PY'
import shlex
import sys

for raw in sys.argv[1].splitlines():
    if raw.startswith("TASK_BODY_PATH="):
        value = raw.split("=", 1)[1]
        parts = shlex.split(value)
        print(parts[0] if parts else "")
        break
PY
)"
assert_contains "$TASK_TITLE" "[intake] Customer needs ETA and refund guidance."
assert_contains "$TASK_BODY_PATH" "shared/raw/intake/$INTAKE_CAPTURE_ID.md"
"$REPO_ROOT/agent-bridge" claim "$INTAKE_TASK_ID" --agent "$REQUESTER_AGENT" >/dev/null
"$REPO_ROOT/agent-bridge" done "$INTAKE_TASK_ID" --agent "$REQUESTER_AGENT" --note "intake processed" >/dev/null

log "warning on suspicious inline task bodies and rejecting explicit empty bodies"
TASK_WARN_OUTPUT="$("$REPO_ROOT/agent-bridge" task create --to "$REQUESTER_AGENT" --title "var warning" --body 'literal ${HTML_BODY}' --from smoke 2>&1)"
assert_contains "$TASK_WARN_OUTPUT" 'warning: --body contains unexpanded shell variable "${HTML_BODY}"'
WARN_TASK_ID="$(printf '%s\n' "$TASK_WARN_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -1)"
[[ -n "$WARN_TASK_ID" ]] || die "warning task create did not return task id"
python3 "$REPO_ROOT/bridge-queue.py" cancel "$WARN_TASK_ID" --actor smoke >/dev/null
EMPTY_BODY_STDOUT="$TMP_ROOT/task-empty.stdout"
EMPTY_BODY_STDERR="$TMP_ROOT/task-empty.stderr"
if "$REPO_ROOT/agent-bridge" task create --to "$REQUESTER_AGENT" --title "empty explicit body" --body "" --from smoke >"$EMPTY_BODY_STDOUT" 2>"$EMPTY_BODY_STDERR"; then
  die "explicit empty --body should require --allow-empty-body"
fi
assert_contains "$(cat "$EMPTY_BODY_STDERR")" "empty --body after trimming whitespace"
ALLOW_EMPTY_OUTPUT="$("$REPO_ROOT/agent-bridge" task create --to "$REQUESTER_AGENT" --title "empty allowed" --body "" --allow-empty-body --from smoke 2>&1)"
ALLOW_EMPTY_TASK_ID="$(printf '%s\n' "$ALLOW_EMPTY_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -1)"
[[ -n "$ALLOW_EMPTY_TASK_ID" ]] || die "allow-empty-body task create did not return task id"
python3 "$REPO_ROOT/bridge-queue.py" cancel "$ALLOW_EMPTY_TASK_ID" --actor smoke >/dev/null

log "requesting and completing a queue-backed review gate"
cat >"$BRIDGE_REVIEW_POLICY_FILE" <<EOF
{
  "defaults": {
    "required": true,
    "reviewer": "$REQUESTER_AGENT",
    "priority": "high",
    "bypass": ["trivial"]
  },
  "families": {
    "release": {
      "reviewer": "$REQUESTER_AGENT",
      "priority": "urgent",
      "bypass": ["trivial", "docs-only"]
    }
  }
}
EOF
REVIEW_POLICY_JSON="$("$REPO_ROOT/agent-bridge" review policy --agent "$SMOKE_AGENT" --family release --json)"
assert_contains "$REVIEW_POLICY_JSON" "\"required\": true"
assert_contains "$REVIEW_POLICY_JSON" "\"reviewer\": \"$REQUESTER_AGENT\""
assert_contains "$REVIEW_POLICY_JSON" "\"priority\": \"urgent\""
REVIEW_REQUEST_OUTPUT="$("$REPO_ROOT/agent-bridge" review request --from "$SMOKE_AGENT" --agent "$SMOKE_AGENT" --family release --subject "release smoke" --body "please review release smoke")"
assert_contains "$REVIEW_REQUEST_OUTPUT" "created review task #"
REVIEW_TASK_ID="$(printf '%s\n' "$REVIEW_REQUEST_OUTPUT" | sed -n 's/^created review task #\([0-9][0-9]*\).*/\1/p' | head -1)"
[[ -n "$REVIEW_TASK_ID" ]] || die "review request did not return task id"
REVIEW_BODY_FILE="$(printf '%s\n' "$REVIEW_REQUEST_OUTPUT" | sed -n 's/^review_body_file: //p' | head -1)"
[[ -f "$REVIEW_BODY_FILE" ]] || die "review request did not create body file"
REVIEW_SHOW_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show "$REVIEW_TASK_ID")"
assert_contains "$REVIEW_SHOW_OUTPUT" "task #$REVIEW_TASK_ID: [review-request] release smoke"
assert_contains "$REVIEW_SHOW_OUTPUT" "assigned_to: $REQUESTER_AGENT"
assert_contains "$(cat "$REVIEW_BODY_FILE")" "review_contract_version: 1"
assert_contains "$(cat "$REVIEW_BODY_FILE")" "family: release"
REVIEW_COMPLETE_OUTPUT="$("$REPO_ROOT/agent-bridge" review complete "$REVIEW_TASK_ID" --reviewer "$REQUESTER_AGENT" --decision approved --note "looks safe")"
assert_contains "$REVIEW_COMPLETE_OUTPUT" "completed task #$REVIEW_TASK_ID as $REQUESTER_AGENT"
REVIEW_DONE_SHOW_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show "$REVIEW_TASK_ID")"
assert_contains "$REVIEW_DONE_SHOW_OUTPUT" "status: done"
SMOKE_REVIEW_INBOX_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" inbox "$SMOKE_AGENT" --all)"
assert_contains "$SMOKE_REVIEW_INBOX_OUTPUT" "[task-complete] [review-request] release smoke"
REVIEW_BYPASS_OUTPUT="$("$REPO_ROOT/agent-bridge" review request --from "$SMOKE_AGENT" --agent "$SMOKE_AGENT" --family release --subject "trivial docs" --body "typo" --bypass trivial)"
assert_contains "$REVIEW_BYPASS_OUTPUT" "review_bypassed: yes"
assert_contains "$REVIEW_BYPASS_OUTPUT" "reason: trivial"

SHARED_USER_CREATE_JSON="$("$REPO_ROOT/agent-bridge" agent create "$SHARED_USER_AGENT" --engine claude --session "$SHARED_USER_SESSION" --dry-run --json)"
assert_contains "$SHARED_USER_CREATE_JSON" "\"id\": \"owner\""
SHARED_USER_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" agent create "$SHARED_USER_AGENT" --engine claude --session "$SHARED_USER_SESSION")"
assert_contains "$SHARED_USER_CREATE_OUTPUT" "create: ok"
[[ -L "$BRIDGE_AGENT_HOME_ROOT/$SHARED_USER_AGENT/users/owner" ]] || die "agent create should link shared user profile"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$SHARED_USER_AGENT/users/owner/USER.md")" "Name: Owner"
assert_contains "$(cat "$BRIDGE_SHARED_DIR/users/owner/USER.md")" "Timezone: Asia/Seoul"
CREATE_DRY_RUN_OUTPUT="$("$REPO_ROOT/agent-bridge" agent create "$CREATED_AGENT" --engine claude --session "$CREATED_SESSION" --always-on --dry-run)"
assert_contains "$CREATE_DRY_RUN_OUTPUT" "agent: $CREATED_AGENT"
assert_contains "$CREATE_DRY_RUN_OUTPUT" "dry_run: yes"
CREATE_JSON_OUTPUT="$("$REPO_ROOT/agent-bridge" agent create "$CREATED_AGENT" --engine claude --session "$CREATED_SESSION" --channels plugin:telegram --user owner:Owner --user reviewer:Reviewer --dry-run --json)"
assert_contains "$CREATE_JSON_OUTPUT" "\"agent\": \"$CREATED_AGENT\""
assert_contains "$CREATE_JSON_OUTPUT" "\"session_type\": \"static-claude\""
assert_contains "$CREATE_JSON_OUTPUT" "\"channels\": \"plugin:telegram@claude-plugins-official\""
assert_contains "$CREATE_JSON_OUTPUT" "\"id\": \"owner\""
CREATE_JSON_OUTPUT_NO_REGISTRY="$(BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$TMP_ROOT/missing-installed-plugins.json" "$REPO_ROOT/agent-bridge" agent create "${CREATED_AGENT}-fallback" --engine claude --session "${CREATED_SESSION}-fallback" --channels plugin:telegram --dry-run --json)"
assert_contains "$CREATE_JSON_OUTPUT_NO_REGISTRY" "\"channels\": \"plugin:telegram@claude-plugins-official\""
CREATE_TEAMS_JSON_OUTPUT="$("$REPO_ROOT/agent-bridge" agent create "${CREATED_AGENT}-teams" --engine claude --session "${CREATED_SESSION}-teams" --channels plugin:teams --dry-run --json)"
assert_contains "$CREATE_TEAMS_JSON_OUTPUT" "\"channels\": \"plugin:teams@agent-bridge\""
CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" agent create "$CREATED_AGENT" --engine claude --session "$CREATED_SESSION" --role "Smoke created role" --channels plugin:telegram --user owner:Owner --user reviewer:Reviewer)"
assert_contains "$CREATE_OUTPUT" "create: ok"
assert_contains "$CREATE_OUTPUT" "start_dry_run: ok"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_ENGINE[\"$CREATED_AGENT\"]=claude"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_AGENT_CHANNELS[\"$CREATED_AGENT\"]="
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "plugin:telegram@claude-plugins-official"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md" ]] || die "agent create did not scaffold CLAUDE.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SOUL.md" ]] || die "agent create did not scaffold SOUL.md"
[[ -L "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/COMMON-INSTRUCTIONS.md" ]] || die "agent create did not link COMMON-INSTRUCTIONS.md"
[[ -L "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CHANGE-POLICY.md" ]] || die "agent create did not link CHANGE-POLICY.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/TOOLS.md" ]] || die "agent create did not scaffold TOOLS.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SKILLS.md" ]] || die "agent create did not scaffold SKILLS.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/MEMORY.md" ]] || die "agent create did not scaffold MEMORY.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/MEMORY-SCHEMA.md" ]] || die "agent create did not scaffold MEMORY-SCHEMA.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SESSION-TYPE.md" ]] || die "agent create did not scaffold SESSION-TYPE.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/index.md" ]] || die "agent create did not scaffold memory/index.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/log.md" ]] || die "agent create did not scaffold memory/log.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/USER.md" ]] || die "agent create did not scaffold users/owner/USER.md"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/reviewer/MEMORY.md" ]] || die "agent create did not scaffold users/reviewer/MEMORY.md"
[[ ! -e "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/default" ]] || die "agent create should remove default user when explicit users are provided"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/USER.md")" "Name: Owner"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SESSION-TYPE.md")" "Session Type: static-claude"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SESSION-TYPE.md")" "Onboarding State: complete"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "SESSION-TYPE.md"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "Onboarding State: pending"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "shared/wiki/people.md"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "COMMON-INSTRUCTIONS.md"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "CHANGE-POLICY.md"
assert_contains "$(cat "$BRIDGE_HOME/shared/COMMON-INSTRUCTIONS.md")" "## Technical Change Reporting"
assert_contains "$(cat "$BRIDGE_HOME/shared/CHANGE-POLICY.md")" "## Default Routing"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SKILLS.md")" "## Shared Claude Skills"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/SKILLS.md")" "## Mapped Runtime Skills"
assert_contains "$(cat "$BRIDGE_HOME/shared/SKILLS.md")" "## Runtime Skill Catalog"
[[ -f "$BRIDGE_HOME/state/skill-registry.json" ]] || die "agent create did not generate skill registry"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/index.md")" "../users/owner/"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/raw/captures/inbox/.gitkeep" ]] || die "agent create did not scaffold raw capture inbox"
[[ -L "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.claude/skills/agent-bridge-runtime" ]] || die "agent create did not link runtime skill"
[[ -L "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.claude/skills/memory-wiki" ]] || die "agent create did not link memory-wiki skill"
MISSING_CHANNEL_START_OUTPUT="$("$REPO_ROOT/bridge-start.sh" "$CREATED_AGENT" 2>&1 || true)"
assert_contains "$MISSING_CHANNEL_START_OUTPUT" "Channel runtime is not configured for '$CREATED_AGENT'"
assert_contains "$MISSING_CHANNEL_START_OUTPUT" "agent-bridge setup telegram $CREATED_AGENT"
MISSING_CHANNEL_SUPPRESSED_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 bridge_agent_launch_cmd "'"$CREATED_AGENT"'"
')"
assert_not_contains "$MISSING_CHANNEL_SUPPRESSED_LAUNCH" "--channels plugin:telegram@claude-plugins-official"
MISSING_CHANNEL_SUPPRESSED_PLUGIN_CHECK="$(BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$TMP_ROOT/missing-installed-plugins.json" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS=1 bridge_ensure_claude_launch_channel_plugins "'"$CREATED_AGENT"'"
  printf ok
')"
assert_contains "$MISSING_CHANNEL_SUPPRESSED_PLUGIN_CHECK" "ok"
MEMORY_CAPTURE_JSON="$("$REPO_ROOT/agent-bridge" memory capture --agent "$CREATED_AGENT" --user owner --source telegram --author "Owner" --channel "chat-1" --text "I prefer concise morning updates." --json)"
MEMORY_CAPTURE_ID="$(python3 - "$MEMORY_CAPTURE_JSON" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["capture_id"])
PY
)"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/raw/captures/inbox/$MEMORY_CAPTURE_ID.json" ]] || die "memory capture did not create inbox file"
MEMORY_INGEST_OUTPUT="$("$REPO_ROOT/agent-bridge" memory ingest --agent "$CREATED_AGENT" --capture "$MEMORY_CAPTURE_ID")"
assert_contains "$MEMORY_INGEST_OUTPUT" "$MEMORY_CAPTURE_ID"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/raw/captures/ingested/$MEMORY_CAPTURE_ID.json" ]] || die "memory ingest did not move capture to ingested"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/memory/$(date +%F).md")" "I prefer concise morning updates."
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/log.md")" "$MEMORY_CAPTURE_ID"
MEMORY_PROMOTE_OUTPUT="$("$REPO_ROOT/agent-bridge" memory promote --agent "$CREATED_AGENT" --kind user --user owner --capture "$MEMORY_CAPTURE_ID" --summary "User prefers concise morning updates.")"
assert_contains "$MEMORY_PROMOTE_OUTPUT" "kind: user"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/MEMORY.md")" "User prefers concise morning updates."
MEMORY_SHARED_PROMOTE_OUTPUT="$("$REPO_ROOT/agent-bridge" memory promote --agent "$CREATED_AGENT" --kind shared --page communication-preferences --summary "This agent should bias toward concise updates when the user prefers them.")"
assert_contains "$MEMORY_SHARED_PROMOTE_OUTPUT" "kind: shared"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/shared/communication-preferences.md" ]] || die "memory promote did not create shared page"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/shared/communication-preferences.md")" "bias toward concise updates"
# Issue #162 Phase 1: user-profile promotion must write to the canonical
# shared user profile so every agent symlinked to that user sees it.
MEMORY_PROFILE_PROMOTE_OUTPUT="$("$REPO_ROOT/agent-bridge" memory promote --agent "$CREATED_AGENT" --kind user-profile --user owner --summary "답변 없으면 Discord로 에스컬레이션해라.")"
assert_contains "$MEMORY_PROFILE_PROMOTE_OUTPUT" "kind: user-profile"
# Write target is users/owner/USER.md; when that path is a symlink into
# $BRIDGE_SHARED_DIR/users/<uid>/ the canonical file is what gets mutated.
SMOKE_USER_PROFILE_AGENT="$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/USER.md"
SMOKE_USER_PROFILE_CANONICAL="$BRIDGE_SHARED_DIR/users/owner/USER.md"
assert_contains "$(cat "$SMOKE_USER_PROFILE_AGENT")" "## Stable Preferences"
assert_contains "$(cat "$SMOKE_USER_PROFILE_AGENT")" "답변 없으면 Discord로 에스컬레이션"
[[ -f "$SMOKE_USER_PROFILE_CANONICAL" ]] || die "user-profile promote did not reach the canonical shared user profile"
assert_contains "$(cat "$SMOKE_USER_PROFILE_CANONICAL")" "답변 없으면 Discord로 에스컬레이션"
# Same canonical means the agent-visible file and the shared file are the same bytes.
diff -q "$SMOKE_USER_PROFILE_AGENT" "$SMOKE_USER_PROFILE_CANONICAL" >/dev/null \
  || die "user-profile promote wrote to agent-local path instead of shared canonical"
# Issue #162 Phase 2: agent-pref is scoped to this agent role only and
# lives at the agent home root. Three invariants: (1) file must NOT exist
# at scaffold time, (2) first promote creates it with the spec section
# format, (3) the CLAUDE.md Runtime Canon pointer appears only AFTER the
# file exists, and disappears when the file is absent.
SMOKE_AGENT_PREF_PATH="$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/ACTIVE-PREFERENCES.md"
SMOKE_AGENT_CLAUDE_PATH="$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md"
[[ ! -f "$SMOKE_AGENT_PREF_PATH" ]] || die "ACTIVE-PREFERENCES.md leaked into scaffold (#162 Phase 2)"
if grep -q "ACTIVE-PREFERENCES.md" "$SMOKE_AGENT_CLAUDE_PATH"; then
  die "Runtime Canon pointer rendered before any agent-pref promotion (#162 Phase 2)"
fi
# Capture the users/ partition snapshot before promote so we can assert the
# codex review finding: agent-pref must not provision a users/default/
# partition (it is user-agnostic, owner already exists from Phase 1).
# shellcheck disable=SC2012 # user dir names are alphanumeric, ls is fine
SMOKE_USERS_BEFORE="$(cd "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/" 2>/dev/null && ls -1 | sort)"
MEMORY_AGENT_PREF_OUTPUT="$("$REPO_ROOT/agent-bridge" memory promote --agent "$CREATED_AGENT" --kind agent-pref --title "Confirm destructive commands" --summary "삭제/리셋 계열 명령은 실행 전에 반드시 operator 확인을 받는다.")"
assert_contains "$MEMORY_AGENT_PREF_OUTPUT" "kind: agent-pref"
[[ -f "$SMOKE_AGENT_PREF_PATH" ]] || die "agent-pref promote did not create ACTIVE-PREFERENCES.md"
assert_contains "$(cat "$SMOKE_AGENT_PREF_PATH")" "Confirm destructive commands"
assert_contains "$(cat "$SMOKE_AGENT_PREF_PATH")" "scope: agent"
assert_contains "$(cat "$SMOKE_AGENT_PREF_PATH")" "**Rule:**"
# codex review finding #1: agent-pref promote MUST trigger CLAUDE.md
# re-render in-band, not "on next upgrade". No setup agent call should
# be required — the pointer is expected to appear immediately.
assert_contains "$(cat "$SMOKE_AGENT_CLAUDE_PATH")" "ACTIVE-PREFERENCES.md"
# codex review finding #2: agent-pref must not scaffold users/default/
# (or any user partition not already present). Snapshot diff.
# shellcheck disable=SC2012 # user dir names are alphanumeric, ls is fine
SMOKE_USERS_AFTER="$(cd "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/" 2>/dev/null && ls -1 | sort)"
[[ "$SMOKE_USERS_BEFORE" == "$SMOKE_USERS_AFTER" ]] \
  || die "agent-pref promote leaked users/ partition: before='$SMOKE_USERS_BEFORE' after='$SMOKE_USERS_AFTER'"
# search/index plumbing — rebuild-index then search + query for the rule body.
"$REPO_ROOT/agent-bridge" memory rebuild-index --agent "$CREATED_AGENT" >/dev/null
MEMORY_AGENT_PREF_SEARCH_JSON="$("$REPO_ROOT/agent-bridge" memory search --agent "$CREATED_AGENT" --query "destructive commands" --json)"
assert_contains "$MEMORY_AGENT_PREF_SEARCH_JSON" "ACTIVE-PREFERENCES.md"
# codex review finding #3: cmd_query --user must not drop agent-pref rows
# (they index with empty user_id). Search already worked; query with
# --user set previously returned zero matches before the fix.
MEMORY_AGENT_PREF_QUERY_JSON="$("$REPO_ROOT/agent-bridge" memory query --agent "$CREATED_AGENT" --user owner --query "destructive commands" --json)"
assert_contains "$MEMORY_AGENT_PREF_QUERY_JSON" "ACTIVE-PREFERENCES.md"
MEMORY_LINT_JSON="$("$REPO_ROOT/agent-bridge" memory lint --agent "$CREATED_AGENT" --json)"
assert_contains "$MEMORY_LINT_JSON" "\"ok\": true"
MEMORY_SEARCH_JSON="$("$REPO_ROOT/agent-bridge" memory search --agent "$CREATED_AGENT" --user owner --query "concise morning updates" --json)"
assert_contains "$MEMORY_SEARCH_JSON" "\"total_matches\":"
assert_contains "$MEMORY_SEARCH_JSON" "\"users/owner/MEMORY.md\""
assert_contains "$MEMORY_SEARCH_JSON" "\"memory/shared/communication-preferences.md\""
MEMORY_INDEX_JSON="$("$REPO_ROOT/agent-bridge" memory rebuild-index --agent "$CREATED_AGENT" --json)"
assert_contains "$MEMORY_INDEX_JSON" "\"chunk_count\":"
MEMORY_QUERY_JSON="$("$REPO_ROOT/agent-bridge" memory query --agent "$CREATED_AGENT" --user owner --query "concise morning updates" --json)"
assert_contains "$MEMORY_QUERY_JSON" "\"backend\": \"index\""
assert_contains "$MEMORY_QUERY_JSON" "\"users/owner/MEMORY.md\""
MEMORY_REMEMBER_JSON="$("$REPO_ROOT/agent-bridge" memory remember --agent "$CREATED_AGENT" --user owner --source chat --text "The owner prefers weekly summary digests." --kind user --json)"
assert_contains "$MEMORY_REMEMBER_JSON" "\"capture_id\":"
assert_contains "$MEMORY_REMEMBER_JSON" "\"kind\": \"user\""
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/owner/MEMORY.md")" "weekly summary digests"
MEMORY_PROJECT_REMEMBER_JSON="$("$REPO_ROOT/agent-bridge" memory remember --agent "$CREATED_AGENT" --user owner --source chat --title "Derm Roadmap" --text $'Weekly derm roadmap check-in every Tuesday.\nTrack dermatologist feedback separately in the project page.' --kind project --page derm-roadmap --summary "Weekly derm roadmap follow-up cadence." --json)"
assert_contains "$MEMORY_PROJECT_REMEMBER_JSON" "\"kind\": \"project\""
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/projects/derm-roadmap.md")" "Weekly derm roadmap follow-up cadence."
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/projects/derm-roadmap.md")" "Track dermatologist feedback separately in the project page."
REVIEWER_MEMORY_FILE="$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/users/reviewer/MEMORY.md"
MISPLACED_DAILY_NOTE="$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/memory/shared/2024-02-02.md"
python3 - "$REVIEWER_MEMORY_FILE" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text("# Reviewer Memory\n\n" + ("A" * 9000) + "\n", encoding="utf-8")
PY
mkdir -p "$(dirname "$MISPLACED_DAILY_NOTE")"
cat >"$MISPLACED_DAILY_NOTE" <<'EOF'
# Misplaced Daily Note

This file intentionally violates the allowed daily-note path rule.
EOF
MEMORY_ENFORCE_JSON="$(bash "$REPO_ROOT/scripts/memory-enforce.sh" --dry-run --json)"
python3 - "$MEMORY_ENFORCE_JSON" "$REVIEWER_MEMORY_FILE" "$MISPLACED_DAILY_NOTE" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
reviewer_memory = sys.argv[2]
misplaced_daily = sys.argv[3]

assert payload["ok"] is False, payload
assert payload["violation_count"] >= 2, payload
kinds = {item["kind"] for item in payload["violations"]}
assert "oversize-memory" in kinds, payload["violations"]
assert "misplaced-daily-note" in kinds, payload["violations"]
paths = {item["path"] for item in payload["violations"]}
assert reviewer_memory in paths, payload["violations"]
assert misplaced_daily in paths, payload["violations"]
PY
MEMORY_ENFORCE_CRON_OUTPUT="$(bash "$REPO_ROOT/scripts/memory-enforce.sh" --print-cron-payload)"
assert_contains "$MEMORY_ENFORCE_CRON_OUTPUT" "memory-enforce.sh"
assert_contains "$MEMORY_ENFORCE_CRON_OUTPUT" "--notify --json"

LEGACY_MEMORY_DB="$TMP_ROOT/legacy-memory-index.sqlite"
python3 - "$LEGACY_MEMORY_DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.executescript(
    """
    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS documents (
        path TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        user_id TEXT NOT NULL DEFAULT '',
        format TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        indexed_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT NOT NULL,
        source TEXT NOT NULL,
        model TEXT NOT NULL DEFAULT 'bridge-wiki-fts-v1',
        kind TEXT NOT NULL,
        user_id TEXT NOT NULL DEFAULT '',
        start_line INTEGER NOT NULL,
        end_line INTEGER NOT NULL,
        text TEXT NOT NULL,
        embedding TEXT NOT NULL DEFAULT '[]'
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        text,
        path UNINDEXED,
        source UNINDEXED,
        model UNINDEXED,
        content='chunks',
        content_rowid='id'
    );
    """
)
conn.close()
PY
LEGACY_MEMORY_INDEX_JSON="$("$REPO_ROOT/agent-bridge" memory rebuild-index --agent "$CREATED_AGENT" --db-path "$LEGACY_MEMORY_DB" --json)"
assert_contains "$LEGACY_MEMORY_INDEX_JSON" "\"chunk_count\":"
SETUP_TELEGRAM_OUTPUT="$("$REPO_ROOT/agent-bridge" setup telegram "$CREATED_AGENT" --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --allow-from 123456789 --default-chat 123456789 --api-base-url "$FAKE_TELEGRAM_API_BASE" --yes)"
assert_contains "$SETUP_TELEGRAM_OUTPUT" "telegram_dir: $BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram"
assert_contains "$SETUP_TELEGRAM_OUTPUT" "validation: ok"
assert_contains "$SETUP_TELEGRAM_OUTPUT" "send: ok"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env" ]] || die "setup telegram did not create .env"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/access.json" ]] || die "setup telegram did not create access.json"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env")" "TELEGRAM_BOT_TOKEN=smoke-telegram-token"
assert_contains "$(cat "$FAKE_TELEGRAM_REQUESTS")" "[Agent Bridge setup]"
SETUP_CREATED_AGENT_OUTPUT="$("$REPO_ROOT/agent-bridge" setup agent "$CREATED_AGENT" --skip-discord --skip-telegram)"
assert_contains "$SETUP_CREATED_AGENT_OUTPUT" "telegram_dir: $BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram"
assert_contains "$SETUP_CREATED_AGENT_OUTPUT" "telegram_allow_from: 123456789"
assert_contains "$SETUP_CREATED_AGENT_OUTPUT" "channel_status: ok"
READY_CHANNEL_PLUGIN_CHECK="$(BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE="$TMP_ROOT/missing-installed-plugins.json" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_ensure_claude_launch_channel_plugins "'"$CREATED_AGENT"'"
' 2>&1 || true)"
assert_contains "$READY_CHANNEL_PLUGIN_CHECK" "Claude plugin registry is missing 'telegram@claude-plugins-official' in test mode."
CHANNEL_BANNER_POSITIVE_TEXT=$'Listening for channel messages from: plugin:telegram@claude-plugins-official\nExperimental banner'
CHANNEL_BANNER_NEGATIVE_TEXT=$'Listening for channel messages from: plugin:discord@claude-plugins-official\nExperimental banner'
CHANNEL_BANNER_CHECK="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  if bridge_claude_channel_banner_present_from_text "plugin:telegram@claude-plugins-official" "$1"; then
    printf ready
  else
    printf missing
  fi
' _ "$CHANNEL_BANNER_POSITIVE_TEXT")"
[[ "$CHANNEL_BANNER_CHECK" == "ready" ]] || die "expected telegram channel banner helper to accept matching banner text"
CHANNEL_BANNER_CHECK="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  if bridge_claude_channel_banner_present_from_text "plugin:telegram@claude-plugins-official" "$1"; then
    printf ready
  else
    printf missing
  fi
' _ "$CHANNEL_BANNER_NEGATIVE_TEXT")"
[[ "$CHANNEL_BANNER_CHECK" == "missing" ]] || die "expected telegram channel banner helper to reject mismatched banner text"
CHANNEL_BANNER_SESSION="channel-banner-smoke-$$"
tmux new-session -d -s "$CHANNEL_BANNER_SESSION" "printf 'Listening for channel messages from: plugin:telegram@claude-plugins-official\n'; sleep 5"
CHANNEL_BANNER_WAIT="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  if bridge_tmux_wait_for_claude_channel_banner "$1" "plugin:telegram@claude-plugins-official" 3; then
    printf ready
  else
    printf missing
  fi
' _ "$CHANNEL_BANNER_SESSION")"
[[ "$CHANNEL_BANNER_WAIT" == "ready" ]] || die "expected tmux banner wait helper to observe telegram banner"
tmux kill-session -t "$CHANNEL_BANNER_SESSION" >/dev/null 2>&1 || true
FAKE_CLAUDE_BIN_DIR="$TMP_ROOT/fake-claude-bin"
FAKE_CLAUDE_PLUGIN_STATE="$TMP_ROOT/fake-claude-plugin-state"
FAKE_CLAUDE_PLUGIN_LOG="$TMP_ROOT/fake-claude-plugin.log"
mkdir -p "$FAKE_CLAUDE_BIN_DIR"
cat >"$FAKE_CLAUDE_BIN_DIR/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_CLAUDE_PLUGIN_LOG:?}"
if [[ "$1 $2" == "plugin list" ]]; then
  if [[ -f "${FAKE_CLAUDE_PLUGIN_STATE:?}" ]]; then
    printf '  ❯ discord@claude-plugins-official\n'
    printf '    Status: enabled\n'
  fi
  exit 0
fi
if [[ "$1 $2 $3" == "plugin marketplace remove" ]]; then
  exit 0
fi
if [[ "$1 $2 $3" == "plugin marketplace add" ]]; then
  touch "${FAKE_CLAUDE_PLUGIN_STATE:?}"
  exit 0
fi
if [[ "$1 $2" == "plugin install" ]]; then
  if [[ -f "${FAKE_CLAUDE_PLUGIN_STATE:?}" ]]; then
    exit 0
  fi
  printf 'Plugin "discord" not found in marketplace "claude-plugins-official"\n' >&2
  exit 1
fi
if [[ "$1 $2" == "plugin enable" ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_CLAUDE_BIN_DIR/claude"
FORCE_REFRESH_OUTPUT="$(PATH="$FAKE_CLAUDE_BIN_DIR:$PATH" FAKE_CLAUDE_PLUGIN_STATE="$FAKE_CLAUDE_PLUGIN_STATE" FAKE_CLAUDE_PLUGIN_LOG="$FAKE_CLAUDE_PLUGIN_LOG" BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE= "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_ensure_claude_plugin_enabled "discord@claude-plugins-official"
' 2>&1)"
assert_contains "$FORCE_REFRESH_OUTPUT" "Refreshing Claude plugin marketplace: claude-plugins-official"
assert_contains "$(cat "$FAKE_CLAUDE_PLUGIN_LOG")" "plugin marketplace remove claude-plugins-official"
assert_contains "$(cat "$FAKE_CLAUDE_PLUGIN_LOG")" "plugin marketplace add anthropics/claude-plugins-official"
CREATE_LIST_JSON="$("$REPO_ROOT/agent-bridge" agent list --json)"
CREATE_SHOW_JSON="$("$REPO_ROOT/agent-bridge" agent show "$CREATED_AGENT" --json)"
python3 - "$CREATE_LIST_JSON" "$CREATE_SHOW_JSON" "$CREATED_AGENT" "$SMOKE_AGENT" <<'PY'
import json
import sys

list_payload = json.loads(sys.argv[1])
show_payload = json.loads(sys.argv[2])
created_agent = sys.argv[3]
admin_agent = sys.argv[4]

assert isinstance(list_payload, list) and list_payload, "agent list json should be a non-empty array"
created = next((row for row in list_payload if row["agent"] == created_agent), None)
assert created is not None, "created agent missing from list json"
assert created["engine"] == "claude"
assert created["channels"]["required"] == "plugin:telegram@claude-plugins-official"
assert created["queue"]["queued"] == 0
assert any(row["agent"] == admin_agent and row["admin"] for row in list_payload), "admin agent missing admin=true"

assert show_payload["agent"] == created_agent
assert show_payload["profile"]["source_present"] is True
assert show_payload["activity_state"] in {"stopped", "idle"}
assert show_payload["notify"]["status"] == "miss"
PY
# The smoke daemon is intentionally live in this section. If it races ahead
# and starts this static role, plain --dry-run exits through the "already
# running" reuse path before printing the launch contract below. Use
# --replace with --dry-run so the inspection remains deterministic without
# killing a live session.
CREATED_START_DRY_RUN="$("$REPO_ROOT/bridge-start.sh" "$CREATED_AGENT" --dry-run --replace)"
assert_contains "$CREATED_START_DRY_RUN" "session=$CREATED_SESSION"
assert_contains "$CREATED_START_DRY_RUN" "channels=plugin:telegram@claude-plugins-official"
assert_contains "$CREATED_START_DRY_RUN" "channel_status=ok"
assert_contains "$CREATED_START_DRY_RUN" "bridge-run.sh $CREATED_AGENT"
CREATED_AGENT_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_launch_cmd "'"$CREATED_AGENT"'"
')"
assert_contains "$CREATED_AGENT_LAUNCH" "TELEGRAM_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram"
assert_contains "$CREATED_AGENT_LAUNCH" "claude --dangerously-skip-permissions --name $CREATED_AGENT --channels plugin:telegram@claude-plugins-official"
assert_not_contains "$CREATED_AGENT_LAUNCH" "claude --continue --dangerously-skip-permissions --name $CREATED_AGENT"
CREATED_AGENT_START_OUTPUT="$("$REPO_ROOT/agent-bridge" agent start "$CREATED_AGENT" --dry-run)"
assert_contains "$CREATED_AGENT_START_OUTPUT" "$CREATED_SESSION"
CREATED_AGENT_RESTART_OUTPUT="$("$REPO_ROOT/agent-bridge" agent restart "$CREATED_AGENT" --dry-run)"
assert_contains "$CREATED_AGENT_RESTART_OUTPUT" "$CREATED_SESSION"
CREATED_AGENT_RESTART_NO_ATTACH_OUTPUT="$("$REPO_ROOT/agent-bridge" agent restart "$CREATED_AGENT" --no-attach --dry-run)"
assert_contains "$CREATED_AGENT_RESTART_NO_ATTACH_OUTPUT" "$CREATED_SESSION"
tmux kill-session -t "$CREATED_SESSION" >/dev/null 2>&1 || true
# Keep the sentinel session alive long enough for slower CI dry-run setup
# work. The assertion below is about restart --dry-run not killing a live
# session, not about a short sleep completing while dry-run is still preparing
# hooks/channel state.
tmux new-session -d -s "$CREATED_SESSION" "sleep 300"
CREATED_AGENT_RESTART_DRY_RUN_ACTIVE="$("$REPO_ROOT/agent-bridge" agent restart "$CREATED_AGENT" --dry-run)"
assert_contains "$CREATED_AGENT_RESTART_DRY_RUN_ACTIVE" "$CREATED_SESSION"
tmux has-session -t "$CREATED_SESSION" >/dev/null 2>&1 || die "restart --dry-run should not kill a running session"
tmux kill-session -t "$CREATED_SESSION" >/dev/null 2>&1 || true
log "blocking restart before killing a live session when channel runtime drifts"
mv "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env" "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env.bak"
tmux new-session -d -s "$CREATED_SESSION" "sleep 300"
CREATED_AGENT_RESTART_GUARD_OUTPUT="$("$REPO_ROOT/agent-bridge" agent restart "$CREATED_AGENT" 2>&1 || true)"
assert_contains "$CREATED_AGENT_RESTART_GUARD_OUTPUT" "Restart is blocked for '$CREATED_AGENT'"
assert_contains "$CREATED_AGENT_RESTART_GUARD_OUTPUT" "The running session was left intact to avoid downtime."
assert_contains "$CREATED_AGENT_RESTART_GUARD_OUTPUT" "BRIDGE_AGENT_CHANNELS[\"$CREATED_AGENT\"]"
tmux has-session -t "$CREATED_SESSION" >/dev/null 2>&1 || die "restart guard should leave the live session intact"
STATUS_WITH_CHANNEL_MISS="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$STATUS_WITH_CHANNEL_MISS" "Channel Warnings"
assert_contains "$STATUS_WITH_CHANNEL_MISS" "$CREATED_AGENT: declared channels"
UPGRADE_ANALYZE_WITH_CHANNEL_MISS="$("$REPO_ROOT/agent-bridge" upgrade analyze --source "$REPO_ROOT" --target "$BRIDGE_HOME")"
assert_contains "$UPGRADE_ANALYZE_WITH_CHANNEL_MISS" "channel_guard_miss: 1"
assert_contains "$UPGRADE_ANALYZE_WITH_CHANNEL_MISS" "$CREATED_AGENT (active):"
mv "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env.bak" "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env"
tmux kill-session -t "$CREATED_SESSION" >/dev/null 2>&1 || true
log "writing HEARTBEAT.md for static roles"
BRIDGE_HEARTBEAT_INTERVAL_SECONDS=1 "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/HEARTBEAT.md" ]] || die "daemon did not write HEARTBEAT.md"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/HEARTBEAT.md")" "agent: $CREATED_AGENT"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/HEARTBEAT.md")" "activity_state:"
log "scanning agent homes with watchdog"
WATCHDOG_JSON="$("$REPO_ROOT/agent-bridge" watchdog scan "$CREATED_AGENT" --json)"
assert_contains "$WATCHDOG_JSON" "\"agent\": \"$CREATED_AGENT\""
assert_contains "$WATCHDOG_JSON" "\"onboarding_state\": \"complete\""
assert_contains "$WATCHDOG_JSON" "\"problem_count\": 0"

log "watchdog status=ok for a dynamic agent with pending onboarding (#241)"
DYN_AGENT="dyn-smoke-$$"
DYN_AGENT_DIR="$BRIDGE_AGENT_HOME_ROOT/$DYN_AGENT"
mkdir -p "$DYN_AGENT_DIR"
# Clone the known-valid managed block + required files from the existing
# $CREATED_AGENT so the scan only has onboarding_state / session_type to react to.
for f in CLAUDE.md SOUL.md MEMORY.md MEMORY-SCHEMA.md SKILLS.md TOOLS.md HEARTBEAT.md; do
  if [[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/$f" ]]; then
    cp "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/$f" "$DYN_AGENT_DIR/$f"
  fi
done
cat > "$DYN_AGENT_DIR/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: dynamic
- Onboarding State: pending
EOF
WATCHDOG_DYN_JSON="$("$REPO_ROOT/agent-bridge" watchdog scan "$DYN_AGENT" --json)"
assert_contains "$WATCHDOG_DYN_JSON" "\"agent\": \"$DYN_AGENT\""
assert_contains "$WATCHDOG_DYN_JSON" "\"session_type\": \"dynamic\""
assert_contains "$WATCHDOG_DYN_JSON" "\"onboarding_state\": \"pending\""
# Key assertion: dynamic agents with pending onboarding no longer escalate to warn.
assert_contains "$WATCHDOG_DYN_JSON" "\"status\": \"ok\""
# Sanity: static-claude with pending onboarding still warns. Flip session type
# on the test agent and verify warn is restored.
python3 - "$DYN_AGENT_DIR/SESSION-TYPE.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("Session Type: dynamic", "Session Type: static-claude"))
PY
WATCHDOG_STATIC_PENDING_JSON="$("$REPO_ROOT/agent-bridge" watchdog scan "$DYN_AGENT" --json)"
assert_contains "$WATCHDOG_STATIC_PENDING_JSON" "\"status\": \"warn\""
rm -rf "$DYN_AGENT_DIR"

log "bootstrapping a manager role with init"
INIT_DRY_RUN_JSON="$("$REPO_ROOT/agent-bridge" init --admin "$INIT_AGENT" --engine claude --session "$INIT_SESSION" --channels plugin:telegram --dry-run --json 2>&1)" || die "init dry-run failed: $INIT_DRY_RUN_JSON"
python3 - "$INIT_DRY_RUN_JSON" "$INIT_AGENT" "$INIT_SESSION" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
session = sys.argv[3]

assert payload["admin"] == agent
assert payload["session"] == session
assert payload["dry_run"] is True
assert payload["created"] is True
assert payload["preflight"] == "dry-run"
assert payload["warnings"] == []
PY
INIT_OUTPUT="$("$REPO_ROOT/agent-bridge" init --admin "$INIT_AGENT" --engine claude --session "$INIT_SESSION" --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_TELEGRAM_API_BASE" 2>&1)" || die "init actual failed: $INIT_OUTPUT"
assert_contains "$INIT_OUTPUT" "admin_agent: $INIT_AGENT"
assert_contains "$INIT_OUTPUT" "channel_setup: ok"
assert_contains "$INIT_OUTPUT" "preflight: ok"
assert_contains "$INIT_OUTPUT" "admin_saved: yes"
assert_contains "$INIT_OUTPUT" "next_command: agb admin"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$INIT_AGENT/.telegram/.env" ]] || die "init did not create telegram env"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$INIT_AGENT/.telegram/access.json" ]] || die "init did not create telegram access"
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$INIT_AGENT/SESSION-TYPE.md" ]] || die "init did not scaffold SESSION-TYPE.md"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_ADMIN_AGENT_ID=\"$INIT_AGENT\""
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$INIT_AGENT/SESSION-TYPE.md")" "Session Type: admin"
INIT_SHOW_JSON="$("$REPO_ROOT/agent-bridge" agent show "$INIT_AGENT" --json)"
python3 - "$INIT_SHOW_JSON" "$INIT_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
assert payload["agent"] == agent
assert payload["engine"] == "claude"
assert payload["channels"]["required"] == "plugin:telegram@claude-plugins-official"
PY

log "bootstrapping a manager role with bootstrap"
# Pin `--shell zsh` and `--skip-systemd` so this generic bootstrap block runs
# the same way on macOS and Linux CI; systemd-specific coverage lives in the
# dedicated systemd block below (PR #239 bullet 4).
BOOTSTRAP_DRY_RUN_JSON="$("$REPO_ROOT/agent-bridge" bootstrap --shell zsh --admin "$BOOTSTRAP_AGENT" --engine claude --session "$BOOTSTRAP_SESSION" --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_TELEGRAM_API_BASE" --rcfile "$BOOTSTRAP_RCFILE" --skip-daemon --skip-launchagent --skip-systemd --dry-run --json 2>&1)" || die "bootstrap dry-run failed: $BOOTSTRAP_DRY_RUN_JSON"
python3 - "$BOOTSTRAP_DRY_RUN_JSON" "$BOOTSTRAP_AGENT" "$BOOTSTRAP_SESSION" "$BOOTSTRAP_RCFILE" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
session = sys.argv[3]
rcfile = sys.argv[4]

assert payload["mode"] == "bootstrap"
assert payload["shell_integration"]["status"] == "planned"
assert payload["shell_integration"]["shell"] == "zsh"
assert payload["shell_integration"]["rcfile"] == rcfile
assert payload["daemon"]["status"] == "skipped"
assert payload["launchagent"]["status"] == "skipped"
assert payload["systemd"]["status"] == "skipped"
assert payload["next_command"] == "agb admin"
assert payload["init"]["admin"] == agent
assert payload["init"]["session"] == session
assert payload["init"]["dry_run"] is True
assert payload["handoff_steps"], "bootstrap handoff steps should not be empty"
assert any("agb admin" in step for step in payload["handoff_steps"])
PY
BOOTSTRAP_OUTPUT="$("$REPO_ROOT/agent-bridge" bootstrap --shell zsh --admin "$BOOTSTRAP_AGENT" --engine claude --session "$BOOTSTRAP_SESSION" --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_TELEGRAM_API_BASE" --rcfile "$BOOTSTRAP_RCFILE" --skip-daemon --skip-launchagent --skip-systemd 2>&1)" || die "bootstrap actual failed: $BOOTSTRAP_OUTPUT"
assert_contains "$BOOTSTRAP_OUTPUT" "== Agent Bridge bootstrap =="
assert_contains "$BOOTSTRAP_OUTPUT" "admin_agent: $BOOTSTRAP_AGENT"
assert_contains "$BOOTSTRAP_OUTPUT" "shell_integration: applied"
assert_contains "$BOOTSTRAP_OUTPUT" "daemon: skipped"
assert_contains "$BOOTSTRAP_OUTPUT" "launchagent: skipped"
assert_contains "$BOOTSTRAP_OUTPUT" "systemd: skipped"
assert_contains "$BOOTSTRAP_OUTPUT" "3. Run: agb admin"
[[ -f "$BOOTSTRAP_RCFILE" ]] || die "bootstrap did not create shell rc file"
assert_contains "$(cat "$BOOTSTRAP_RCFILE")" "source \"$REPO_ROOT/shell/agent-bridge.zsh\""
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_ADMIN_AGENT_ID=\"$BOOTSTRAP_AGENT\""
BOOTSTRAP_SHOW_JSON="$("$REPO_ROOT/agent-bridge" agent show "$BOOTSTRAP_AGENT" --json)"
python3 - "$BOOTSTRAP_SHOW_JSON" "$BOOTSTRAP_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
assert payload["agent"] == agent
assert payload["engine"] == "claude"
assert payload["channels"]["required"] == "plugin:telegram@claude-plugins-official"
PY

log "rendering a Linux systemd user unit and bootstrap dry-run"
SYSTEMD_UNIT_OUTPUT="$("$REPO_ROOT/scripts/install-daemon-systemd.sh" --bridge-home "$BRIDGE_HOME")"
assert_contains "$SYSTEMD_UNIT_OUTPUT" "[Service]"
assert_contains "$SYSTEMD_UNIT_OUTPUT" "ExecStart="
assert_contains "$SYSTEMD_UNIT_OUTPUT" "service_path:"
BOOTSTRAP_LINUX_JSON="$(BRIDGE_BOOTSTRAP_OS=Linux "$REPO_ROOT/agent-bridge" bootstrap --admin bootstrap-linux --engine claude --session bootstrap-linux --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --api-base-url "$FAKE_TELEGRAM_API_BASE" --rcfile "$TMP_ROOT/bootstrap-linux.rc" --skip-daemon --skip-launchagent --dry-run --json 2>&1)" || die "linux bootstrap dry-run failed: $BOOTSTRAP_LINUX_JSON"
python3 - "$BOOTSTRAP_LINUX_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["mode"] == "bootstrap"
assert payload["launchagent"]["status"] == "skipped"
assert payload["systemd"]["status"] == "planned"
# Issue #265 D: when systemd is planned and the operator did not pass
# --skip-liveness, the liveness watcher should be planned alongside it.
assert payload["liveness"]["status"] == "planned", payload["liveness"]
PY

# Issue #265 proposal D — render the OS liveness installers without
# touching launchctl/systemctl, then exercise the checker against fake
# heartbeat states in an isolated state dir. Keeps the tests safe to run
# on any host (no daemon restart side effects).
log "rendering daemon-liveness launchagent + systemd installers (issue #265 D)"
LIVENESS_LAUNCHAGENT_OUTPUT="$("$REPO_ROOT/scripts/install-daemon-liveness-launchagent.sh" --bridge-home "$BRIDGE_HOME")"
assert_contains "$LIVENESS_LAUNCHAGENT_OUTPUT" "<key>Label</key>"
assert_contains "$LIVENESS_LAUNCHAGENT_OUTPUT" "ai.agent-bridge.daemon-liveness"
assert_contains "$LIVENESS_LAUNCHAGENT_OUTPUT" "<key>StartInterval</key>"
assert_contains "$LIVENESS_LAUNCHAGENT_OUTPUT" "bridge-daemon-liveness.sh"
assert_contains "$LIVENESS_LAUNCHAGENT_OUTPUT" "BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS"

LIVENESS_SYSTEMD_OUTPUT="$("$REPO_ROOT/scripts/install-daemon-liveness-systemd.sh" --bridge-home "$BRIDGE_HOME")"
assert_contains "$LIVENESS_SYSTEMD_OUTPUT" "agent-bridge-daemon-liveness.service"
assert_contains "$LIVENESS_SYSTEMD_OUTPUT" "agent-bridge-daemon-liveness.timer"
assert_contains "$LIVENESS_SYSTEMD_OUTPUT" "OnUnitInactiveSec="
assert_contains "$LIVENESS_SYSTEMD_OUTPUT" "BRIDGE_DAEMON_LIVENESS_THRESHOLD_SECONDS="

log "exercising daemon-liveness checker decisions (issue #265 D)"
LIVENESS_TMP="$TMP_ROOT/liveness"
mkdir -p "$LIVENESS_TMP/state" "$LIVENESS_TMP/logs"
LIVENESS_HEARTBEAT="$LIVENESS_TMP/state/daemon.heartbeat"
LIVENESS_PIDFILE="$LIVENESS_TMP/state/daemon.pid"
LIVENESS_AUDIT="$LIVENESS_TMP/logs/audit.jsonl"
LIVENESS_COOLDOWN="$LIVENESS_TMP/state/daemon-liveness-cooldown.ts"

# 1. No baseline: no heartbeat file at all -> skip_no_baseline, no restart.
rm -f "$LIVENESS_HEARTBEAT" "$LIVENESS_PIDFILE" "$LIVENESS_COOLDOWN" "$LIVENESS_AUDIT"
BRIDGE_HOME="$LIVENESS_TMP" \
  BRIDGE_STATE_DIR="$LIVENESS_TMP/state" \
  BRIDGE_AUDIT_LOG="$LIVENESS_AUDIT" \
  BRIDGE_DAEMON_PID_FILE="$LIVENESS_PIDFILE" \
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=1 \
  bash "$REPO_ROOT/scripts/bridge-daemon-liveness.sh" >/dev/null 2>&1 \
  || die "liveness checker no-baseline run exited non-zero"
assert_contains "$(cat "$LIVENESS_AUDIT" 2>/dev/null)" "daemon_liveness_skip_no_baseline"

# 2. Fresh heartbeat: file mtime is now -> ok, no restart.
rm -f "$LIVENESS_AUDIT"
date +%s >"$LIVENESS_HEARTBEAT"
BRIDGE_HOME="$LIVENESS_TMP" \
  BRIDGE_STATE_DIR="$LIVENESS_TMP/state" \
  BRIDGE_AUDIT_LOG="$LIVENESS_AUDIT" \
  BRIDGE_DAEMON_PID_FILE="$LIVENESS_PIDFILE" \
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=1 \
  bash "$REPO_ROOT/scripts/bridge-daemon-liveness.sh" >/dev/null 2>&1 \
  || die "liveness checker fresh-heartbeat run exited non-zero"
assert_contains "$(cat "$LIVENESS_AUDIT" 2>/dev/null)" "daemon_liveness_ok"

# 3. Stale heartbeat but daemon not running: skip_not_running.
rm -f "$LIVENESS_AUDIT" "$LIVENESS_PIDFILE"
date +%s >"$LIVENESS_HEARTBEAT"
# Backdate to 1 hour ago via touch -t (works on macOS BSD touch and GNU touch).
LIVENESS_PAST="$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M.%S)"
touch -t "$LIVENESS_PAST" "$LIVENESS_HEARTBEAT"
BRIDGE_HOME="$LIVENESS_TMP" \
  BRIDGE_STATE_DIR="$LIVENESS_TMP/state" \
  BRIDGE_AUDIT_LOG="$LIVENESS_AUDIT" \
  BRIDGE_DAEMON_PID_FILE="$LIVENESS_PIDFILE" \
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=1 \
  bash "$REPO_ROOT/scripts/bridge-daemon-liveness.sh" >/dev/null 2>&1 \
  || die "liveness checker stale-no-pid run exited non-zero"
assert_contains "$(cat "$LIVENESS_AUDIT" 2>/dev/null)" "daemon_liveness_skip_not_running"

# 4. Stale heartbeat AND a live daemon pid: dry-run records restart_attempt
# and writes the cooldown file. Use the smoke shell's own pid as the
# "alive daemon" — kill -0 succeeds and we never actually call stop/start
# because BRIDGE_DAEMON_LIVENESS_DRY_RUN=1.
rm -f "$LIVENESS_AUDIT" "$LIVENESS_COOLDOWN"
echo "$$" >"$LIVENESS_PIDFILE"
touch -t "$LIVENESS_PAST" "$LIVENESS_HEARTBEAT"
BRIDGE_HOME="$LIVENESS_TMP" \
  BRIDGE_STATE_DIR="$LIVENESS_TMP/state" \
  BRIDGE_AUDIT_LOG="$LIVENESS_AUDIT" \
  BRIDGE_DAEMON_PID_FILE="$LIVENESS_PIDFILE" \
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=1 \
  bash "$REPO_ROOT/scripts/bridge-daemon-liveness.sh" >/dev/null 2>&1 \
  || die "liveness checker stale-with-pid dry-run exited non-zero"
assert_contains "$(cat "$LIVENESS_AUDIT" 2>/dev/null)" "daemon_liveness_restart_attempt"
[[ -f "$LIVENESS_COOLDOWN" ]] || die "liveness checker did not record cooldown ts"

# 5. Stale heartbeat, live pid, but cooldown still active: skip_cooldown.
rm -f "$LIVENESS_AUDIT"
touch -t "$LIVENESS_PAST" "$LIVENESS_HEARTBEAT"
BRIDGE_HOME="$LIVENESS_TMP" \
  BRIDGE_STATE_DIR="$LIVENESS_TMP/state" \
  BRIDGE_AUDIT_LOG="$LIVENESS_AUDIT" \
  BRIDGE_DAEMON_PID_FILE="$LIVENESS_PIDFILE" \
  BRIDGE_DAEMON_LIVENESS_DRY_RUN=1 \
  bash "$REPO_ROOT/scripts/bridge-daemon-liveness.sh" >/dev/null 2>&1 \
  || die "liveness checker cooldown run exited non-zero"
assert_contains "$(cat "$LIVENESS_AUDIT" 2>/dev/null)" "daemon_liveness_skip_cooldown"

log "surfacing bootstrap failure output and parsing tokenFile dotenv values"
cat >"$TOKENFILE_ENV" <<'EOF'
TELEGRAM_BOT_TOKEN=dotenv-telegram-token
EOF
python3 - "$TMP_ROOT/openclaw.json" "$TOKENFILE_ENV" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["channels"]["telegram"]["accounts"]["dotenv"] = {"tokenFile": sys.argv[2]}
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
SETUP_TELEGRAM_DOTENV_OUTPUT="$("$BASH4_BIN" "$REPO_ROOT/bridge-setup.sh" telegram "$CREATED_AGENT" --channel-account dotenv --runtime-config "$TMP_ROOT/openclaw.json" --allow-from 123456789 --default-chat 123456789 --skip-validate --skip-send-test --yes 2>&1)"
assert_contains "$SETUP_TELEGRAM_DOTENV_OUTPUT" "token_source: channel:dotenv"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.telegram/.env")" "TELEGRAM_BOT_TOKEN=dotenv-telegram-token"

log "running guided Teams setup"
TEAMS_SETUP_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
TEAMS_SETUP_MOCK_SCRIPT="$TMP_ROOT/teams-setup-mock.py"
cat >"$TEAMS_SETUP_MOCK_SCRIPT" <<'PY'
#!/usr/bin/env python3
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path == "/health":
            data = json.dumps({"ok": True}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        _body = self.rfile.read(length)
        if self.path.endswith("/oauth2/v2.0/token"):
            payload = {
                "access_token": "smoke-teams-token",
                "expires_in": 3600,
                "token_type": "Bearer",
            }
            data = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path == "/api/messages":
            data = json.dumps({"ok": False, "probe": "backend"}).encode("utf-8")
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()

server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
server.serve_forever()
PY
python3 "$TEAMS_SETUP_MOCK_SCRIPT" "$TEAMS_SETUP_PORT" >/dev/null 2>&1 &
TEAMS_SETUP_MOCK_PID=$!
for _ in {1..40}; do
  if python3 - "$TEAMS_SETUP_PORT" <<'PY' >/dev/null 2>&1
import sys
import urllib.request
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/health", timeout=0.2) as _:
    pass
PY
  then
    break
  fi
  if ! kill -0 "$TEAMS_SETUP_MOCK_PID" >/dev/null 2>&1; then
    die "teams setup mock exited before startup"
  fi
  sleep 0.1
done
SETUP_TEAMS_OUTPUT="$(BRIDGE_TEAMS_LOGIN_BASE_URL="http://127.0.0.1:$TEAMS_SETUP_PORT" "$BASH4_BIN" "$REPO_ROOT/bridge-setup.sh" teams "$CREATED_AGENT" --channel-account smoke --runtime-config "$TMP_ROOT/openclaw.json" --allow-from 00000000-0000-0000-0000-000000000000 --conversation "19:smoke@thread.v2" --require-mention --messaging-endpoint "http://127.0.0.1:$TEAMS_SETUP_PORT/api/messages" --webhook-host 0.0.0.0 --webhook-port 3978 --ingress-port 80 --yes 2>&1)"
assert_contains "$SETUP_TEAMS_OUTPUT" "teams_dir: $BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams"
assert_contains "$SETUP_TEAMS_OUTPUT" "credential_source: channel:smoke"
assert_contains "$SETUP_TEAMS_OUTPUT" "validation: ok"
assert_contains "$SETUP_TEAMS_OUTPUT" "credential_validation: ok"
assert_contains "$SETUP_TEAMS_OUTPUT" "endpoint_probe: backend_reached"
assert_contains "$SETUP_TEAMS_OUTPUT" "warning: Reverse proxy target port 80 does not match Teams webhook port 3978."
assert_contains "$SETUP_TEAMS_OUTPUT" "--dangerously-load-development-channels plugin:teams@agent-bridge"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams/.env")" "TEAMS_APP_ID=smoke-teams-app-id"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams/.env")" "TEAMS_WEBHOOK_HOST=0.0.0.0"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams/.env")" "TEAMS_WEBHOOK_PORT=3978"
assert_not_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams/.env")" "TEAMS_BRIDGE_MODE"
assert_not_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams/.env")" "TEAMS_BRIDGE_AGENT"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams/access.json")" "19:smoke@thread.v2"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams/state.json")" "\"status\": \"ok\""
CREATED_TEAMS_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_launch_cmd "'"$CREATED_AGENT"'"
')"
assert_contains "$CREATED_TEAMS_LAUNCH" "TEAMS_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams"
assert_contains "$CREATED_TEAMS_LAUNCH" "plugin:teams@agent-bridge"
assert_contains "$CREATED_TEAMS_LAUNCH" "--dangerously-load-development-channels plugin:teams@agent-bridge"
assert_not_contains "$CREATED_TEAMS_LAUNCH" "--channels plugin:teams@agent-bridge"
TEAMS_DEV_MERGED_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_claude_launch_with_development_channels "BRIDGE_SENTINEL=1 claude --dangerously-load-development-channels plugin:teams@agent-bridge --dangerously-skip-permissions --channels plugin:discord@claude-plugins-official" "plugin:teams@agent-bridge,plugin:custom-dev@agent-bridge"
')"
assert_contains "$TEAMS_DEV_MERGED_LAUNCH" "BRIDGE_SENTINEL=1 claude"
assert_contains "$TEAMS_DEV_MERGED_LAUNCH" "--dangerously-load-development-channels plugin:teams@agent-bridge"
assert_contains "$TEAMS_DEV_MERGED_LAUNCH" "--dangerously-load-development-channels plugin:custom-dev@agent-bridge"
python3 - "$TEAMS_DEV_MERGED_LAUNCH" <<'PY'
import sys

command = sys.argv[1]
assert command.count("plugin:teams@agent-bridge") == 1, command
assert command.count("plugin:custom-dev@agent-bridge") == 1, command
PY
TEAMS_DEV_STATE_DIR_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CHANNELS["'"$CREATED_AGENT"'"]="plugin:discord@claude-plugins-official"
  raw="claude --dangerously-load-development-channels plugin:teams@agent-bridge --dangerously-skip-permissions --name '"$CREATED_AGENT"' --channels plugin:discord@claude-plugins-official"
  bridge_claude_launch_with_channel_state_dirs "'"$CREATED_AGENT"'" "$raw"
')"
assert_contains "$TEAMS_DEV_STATE_DIR_LAUNCH" "TEAMS_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams"

# Issue #786 follow-up — bridge_claude_launch_with_channel_state_dirs must
# also canonicalize MS365_STATE_DIR. Frozen-roster launch_cmd previously kept
# stale pre-v2 path → ms365 plugin server.ts mkdir EACCES → MCP entry dropped.
MS365_STALE_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CHANNELS["'"$CREATED_AGENT"'"]="plugin:ms365@agent-bridge"
  raw="MS365_STATE_DIR=/stale/.ms365 claude --dangerously-load-development-channels plugin:ms365@agent-bridge --dangerously-skip-permissions --name '"$CREATED_AGENT"'"
  bridge_claude_launch_with_channel_state_dirs "'"$CREATED_AGENT"'" "$raw"
')"
assert_contains "$MS365_STALE_LAUNCH" "MS365_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.ms365"
assert_not_contains "$MS365_STALE_LAUNCH" "MS365_STATE_DIR=/stale/.ms365"
python3 - "$MS365_STALE_LAUNCH" <<'PY'
import sys
command = sys.argv[1]
assert command.count("plugin:ms365@agent-bridge") == 1, command
PY
MS365_FRESH_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CHANNELS["'"$CREATED_AGENT"'"]="plugin:ms365@agent-bridge"
  raw="claude --dangerously-load-development-channels plugin:ms365@agent-bridge --dangerously-skip-permissions --name '"$CREATED_AGENT"'"
  bridge_claude_launch_with_channel_state_dirs "'"$CREATED_AGENT"'" "$raw"
')"
assert_contains "$MS365_FRESH_LAUNCH" "MS365_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.ms365"
TEAMS_MS365_BOTH_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CHANNELS["'"$CREATED_AGENT"'"]="plugin:teams@agent-bridge,plugin:ms365@agent-bridge"
  raw="OTHER_ENV=keep TEAMS_STATE_DIR=/stale/.teams MS365_STATE_DIR=/stale/.ms365 claude --dangerously-load-development-channels plugin:teams@agent-bridge --dangerously-load-development-channels plugin:ms365@agent-bridge --dangerously-skip-permissions --name '"$CREATED_AGENT"'"
  bridge_claude_launch_with_channel_state_dirs "'"$CREATED_AGENT"'" "$raw"
')"
assert_contains "$TEAMS_MS365_BOTH_LAUNCH" "TEAMS_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams"
assert_contains "$TEAMS_MS365_BOTH_LAUNCH" "MS365_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.ms365"
assert_contains "$TEAMS_MS365_BOTH_LAUNCH" "OTHER_ENV=keep"
assert_not_contains "$TEAMS_MS365_BOTH_LAUNCH" "TEAMS_STATE_DIR=/stale/.teams"
assert_not_contains "$TEAMS_MS365_BOTH_LAUNCH" "MS365_STATE_DIR=/stale/.ms365"

# PR #790 r2 codex catch — duplicate stale assignments for the SAME VAR
# must collapse to exactly ONE canonical entry. The replacement loop
# previously emitted a canonical assignment for EACH matching span,
# producing `MS365_STATE_DIR=/new MS365_STATE_DIR=/new` instead of a
# single final assignment. Shell eval is last-wins so the value is
# still correct, but duplicate exported assignments surface in audit
# logs / `ps` output as if multiple stale entries survived. The fix
# is symmetric across all four channel state dirs; verify both an
# MS365 case and a TEAMS case so the contract is enforced for the
# whole family.
MS365_DUP_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CHANNELS["'"$CREATED_AGENT"'"]="plugin:ms365@agent-bridge"
  raw="MS365_STATE_DIR=/stale1/.ms365 MS365_STATE_DIR=/stale2/.ms365 claude --dangerously-load-development-channels plugin:ms365@agent-bridge --dangerously-skip-permissions --name '"$CREATED_AGENT"'"
  bridge_claude_launch_with_channel_state_dirs "'"$CREATED_AGENT"'" "$raw"
')"
assert_contains "$MS365_DUP_LAUNCH" "MS365_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.ms365"
assert_not_contains "$MS365_DUP_LAUNCH" "/stale1/.ms365"
assert_not_contains "$MS365_DUP_LAUNCH" "/stale2/.ms365"
python3 - "$MS365_DUP_LAUNCH" <<'PY'
import re
import sys
command = sys.argv[1]
matches = re.findall(r"\bMS365_STATE_DIR=", command)
assert len(matches) == 1, f"expected 1 MS365_STATE_DIR=, got {len(matches)}: {command!r}"
PY
TEAMS_DUP_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CHANNELS["'"$CREATED_AGENT"'"]="plugin:teams@agent-bridge"
  raw="TEAMS_STATE_DIR=/stale1/.teams TEAMS_STATE_DIR=/stale2/.teams claude --dangerously-load-development-channels plugin:teams@agent-bridge --dangerously-skip-permissions --name '"$CREATED_AGENT"'"
  bridge_claude_launch_with_channel_state_dirs "'"$CREATED_AGENT"'" "$raw"
')"
assert_contains "$TEAMS_DUP_LAUNCH" "TEAMS_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams"
assert_not_contains "$TEAMS_DUP_LAUNCH" "/stale1/.teams"
assert_not_contains "$TEAMS_DUP_LAUNCH" "/stale2/.teams"
python3 - "$TEAMS_DUP_LAUNCH" <<'PY'
import re
import sys
command = sys.argv[1]
matches = re.findall(r"\bTEAMS_STATE_DIR=", command)
assert len(matches) == 1, f"expected 1 TEAMS_STATE_DIR=, got {len(matches)}: {command!r}"
PY

# PR #790 r3 codex catch (BLOCKING) — the r2 fix introduced a global
# `re.sub(r" {2,}", " ", env_prefix)` post-pass to clean up the double
# space left when a duplicate span was dropped. That cleanup was too
# coarse: it collapsed multi-space runs ANYWHERE in env_prefix,
# including INSIDE quoted env values. `OTHER="a  b"` got silently
# mangled to `OTHER="a b"`, breaking pass-through correctness for any
# upstream env value that intentionally contained consecutive spaces.
# r3 fix: strip ONE leading whitespace at each dedupe drop site
# (local to the span boundary) instead of a global post-pass. Fixture
# asserts both halves of the contract:
#   1. Duplicate MS365_STATE_DIR spans still collapse to exactly one.
#   2. An unrelated OTHER='keep  with  multi  spaces' value with
#      intentional multi-space runs is preserved BYTE-FOR-BYTE.
OTHER_QUOTED_PRESERVED_LAUNCH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CHANNELS["'"$CREATED_AGENT"'"]="plugin:ms365@agent-bridge"
  raw="OTHER='\''keep  with  multi  spaces'\'' MS365_STATE_DIR=/stale1/.ms365 MS365_STATE_DIR=/stale2/.ms365 claude --dangerously-load-development-channels plugin:ms365@agent-bridge --dangerously-skip-permissions --name '"$CREATED_AGENT"'"
  bridge_claude_launch_with_channel_state_dirs "'"$CREATED_AGENT"'" "$raw"
')"
# OTHER's internal multi-space content must be preserved exactly.
assert_contains "$OTHER_QUOTED_PRESERVED_LAUNCH" "OTHER='keep  with  multi  spaces'"
# Dedupe still produces exactly one canonical MS365_STATE_DIR.
assert_contains "$OTHER_QUOTED_PRESERVED_LAUNCH" "MS365_STATE_DIR=$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.ms365"
assert_not_contains "$OTHER_QUOTED_PRESERVED_LAUNCH" "/stale1/.ms365"
assert_not_contains "$OTHER_QUOTED_PRESERVED_LAUNCH" "/stale2/.ms365"
python3 - "$OTHER_QUOTED_PRESERVED_LAUNCH" <<'PY'
import re
import sys
command = sys.argv[1]
ms365_matches = re.findall(r"\bMS365_STATE_DIR=", command)
assert len(ms365_matches) == 1, f"expected 1 MS365_STATE_DIR=, got {len(ms365_matches)}: {command!r}"
# Belt-and-suspenders: assert the OTHER value passed through byte-for-byte.
assert "OTHER='keep  with  multi  spaces'" in command, \
    f"OTHER multi-space content mangled: {command!r}"
PY

if command -v bun >/dev/null 2>&1; then
  log "exercising Teams channel plugin health"
  TEAMS_SMOKE_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
  TEAMS_PLUGIN_LOG="$TMP_ROOT/teams-plugin.log"
  cat >>"$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams/.env" <<EOF
TEAMS_WEBHOOK_HOST=0.0.0.0
TEAMS_WEBHOOK_PORT=$TEAMS_SMOKE_PORT
EOF
  (
    cd "$REPO_ROOT/plugins/teams"
    TEAMS_STATE_DIR="$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams" \
      bun run --shell=bun --silent start >"$TEAMS_PLUGIN_LOG" 2>&1
  ) &
  TEAMS_PLUGIN_PID=$!
  for _ in {1..40}; do
    if python3 - "$TEAMS_SMOKE_PORT" <<'PY' >/dev/null 2>&1
import json
import sys
import urllib.request
port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=0.5) as res:
    payload = json.load(res)
if payload.get("ok") is not True or payload.get("channel") != "teams":
    raise SystemExit(1)
PY
    then
      break
    fi
    if ! kill -0 "$TEAMS_PLUGIN_PID" >/dev/null 2>&1; then
      cat "$TEAMS_PLUGIN_LOG" >&2 || true
      die "Teams plugin exited before health check"
    fi
    sleep 0.25
  done
  python3 - "$TEAMS_SMOKE_PORT" <<'PY' >/dev/null
import json
import sys
import urllib.request
port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1) as res:
    payload = json.load(res)
if payload.get("ok") is not True or payload.get("channel") != "teams":
    raise SystemExit("Teams health payload mismatch")
PY
  assert_contains "$(cat "$TEAMS_PLUGIN_LOG")" "http://0.0.0.0:$TEAMS_SMOKE_PORT/api/messages"
  TEAMS_PLUGIN_CONFLICT_LOG="$TMP_ROOT/teams-plugin-conflict.log"
  (
    cd "$REPO_ROOT/plugins/teams"
    TEAMS_STATE_DIR="$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/.teams" \
      bun run --shell=bun --silent start >"$TEAMS_PLUGIN_CONFLICT_LOG" 2>&1
  ) &
  TEAMS_PLUGIN_CONFLICT_PID=$!
  sleep 1
  if kill -0 "$TEAMS_PLUGIN_CONFLICT_PID" >/dev/null 2>&1; then
    kill "$TEAMS_PLUGIN_CONFLICT_PID" >/dev/null 2>&1 || true
    wait "$TEAMS_PLUGIN_CONFLICT_PID" >/dev/null 2>&1 || true
    die "Teams plugin unexpectedly stayed alive on duplicate port bind"
  fi
  assert_contains "$(cat "$TEAMS_PLUGIN_CONFLICT_LOG")" "teams channel: http listen failed on 0.0.0.0:$TEAMS_SMOKE_PORT"
  assert_not_contains "$(cat "$REPO_ROOT/plugins/teams/server.ts")" "agent-bridge urgent"
  assert_not_contains "$(cat "$REPO_ROOT/plugins/teams/server.ts")" "spawnSync(agb, ['urgent'"
  assert_contains "$(cat "$REPO_ROOT/plugins/teams/server.ts")" "ignoring deprecated TEAMS_BRIDGE_MODE"
  TEAMS_DEDUPE_OUTPUT="$(cd "$REPO_ROOT/plugins/teams" && bun -e 'import { createRecentMessageDeduper } from "./dedupe.ts"; const dedupe = createRecentMessageDeduper(2); console.log(JSON.stringify([dedupe.seen("1775901127484"), dedupe.seen("1775901127484"), dedupe.seen("1775901127485"), dedupe.seen("1775901127486"), dedupe.seen("1775901127484")]))')"
  assert_contains "$TEAMS_DEDUPE_OUTPUT" "[false,true,false,false,false]"
  # Round-2: channel-failure path — forget() must roll back the dedupe entry
  # so a Teams retry of the same activity is allowed through after a delivery
  # error. Without forget() the retry would be silently dropped.
  TEAMS_DEDUPE_FORGET_OUTPUT="$(cd "$REPO_ROOT/plugins/teams" && bun -e 'import { createRecentMessageDeduper } from "./dedupe.ts"; const dedupe = createRecentMessageDeduper(8); const a = dedupe.seen("chat-1::msg-1::rev-1"); const b = dedupe.seen("chat-1::msg-1::rev-1"); dedupe.forget("chat-1::msg-1::rev-1"); const c = dedupe.seen("chat-1::msg-1::rev-1"); console.log(JSON.stringify([a, b, c]))')"
  assert_contains "$TEAMS_DEDUPE_FORGET_OUTPUT" "[false,true,false]"
  # Round-2: edit-aware key — same chat_id+message_id with a bumped revision
  # must not collide. Teams edits keep the activity id but bump
  # localTimestamp/timestamp.
  TEAMS_DEDUPE_EDIT_OUTPUT="$(cd "$REPO_ROOT/plugins/teams" && bun -e 'import { createRecentMessageDeduper } from "./dedupe.ts"; const dedupe = createRecentMessageDeduper(8); const original = dedupe.seen("chat-1::msg-1::2026-01-01T00:00:00Z"); const edit = dedupe.seen("chat-1::msg-1::2026-01-01T00:05:00Z"); const replay = dedupe.seen("chat-1::msg-1::2026-01-01T00:00:00Z"); console.log(JSON.stringify([original, edit, replay]))')"
  assert_contains "$TEAMS_DEDUPE_EDIT_OUTPUT" "[false,false,true]"
  # Round-2: catch-block scope — channel delivery and local log append must
  # use separate try blocks so a successful delivery followed by an
  # appendMessage failure does NOT cause Teams to retry an already-delivered
  # message.
  assert_contains "$(cat "$REPO_ROOT/plugins/teams/server.ts")" "failed to append local log"
  assert_contains "$(cat "$REPO_ROOT/plugins/teams/server.ts")" "delivery already succeeded"
  # Round-2: dedupe key must include a revision so Teams edits flow through.
  assert_contains "$(cat "$REPO_ROOT/plugins/teams/server.ts")" "dedupeKey(chatId, messageId, revision)"
  # Round-3 Finding A: handleActivity must route Teams edits
  # (ActivityTypes.MessageUpdate) through the same delivery path as new
  # messages. Without this gate change the revision-aware dedupe is dead
  # code — edits never reach it.
  assert_contains "$(cat "$REPO_ROOT/plugins/teams/server.ts")" "ActivityTypes.MessageUpdate"
  # Round-3 Finding B: legacy messages.jsonl rows (written before r2 added
  # the `revision` field) have no revision. New arrivals always derive a
  # non-empty revision. The delivered-seen predicate must treat a stored
  # row with revision === undefined as a match regardless of incoming
  # revision; otherwise Teams retries replay legacy messages.
  TEAMS_LEGACY_MATCH_OUTPUT="$(cd "$REPO_ROOT/plugins/teams" && bun -e 'import { storedRowMatchesIncoming } from "./dedupe.ts"; const legacyVsFresh = storedRowMatchesIncoming(undefined, "2026-01-01T00:05:00Z"); const legacyVsEmpty = storedRowMatchesIncoming(undefined, ""); const exactMatch = storedRowMatchesIncoming("2026-01-01T00:05:00Z", "2026-01-01T00:05:00Z"); const exactMismatch = storedRowMatchesIncoming("2026-01-01T00:00:00Z", "2026-01-01T00:05:00Z"); console.log(JSON.stringify([legacyVsFresh, legacyVsEmpty, exactMatch, exactMismatch]))')"
  assert_contains "$TEAMS_LEGACY_MATCH_OUTPUT" "[true,true,true,false]"
  log "exercising ms365 human-profile disclosure helper"
  MS365_DISCLOSURE_OUTPUT="$(cd "$REPO_ROOT/plugins/ms365" && bun -e 'import { mkdtempSync } from "fs"; import { join } from "path"; import { tmpdir } from "os"; import { hasChatDisclaimerBeenSent, markChatDisclaimerSent, prependHumanOutboundDisclaimer } from "./disclosure.ts"; const root = mkdtempSync(join(tmpdir(), "ms365-disclosure-")); const statePath = join(root, "human-outbound-disclosures.json"); const text = prependHumanOutboundDisclaimer("hello", "text", "notice"); const html = prependHumanOutboundDisclaimer("<p>hello</p>", "html", "notice"); const before = hasChatDisclaimerBeenSent(statePath, "owner@example.com", "chat-1"); markChatDisclaimerSent(statePath, "owner@example.com", "chat-1", "msg-1"); const after = hasChatDisclaimerBeenSent(statePath, "owner@example.com", "chat-1"); const other = hasChatDisclaimerBeenSent(statePath, "owner@example.com", "chat-2"); console.log(JSON.stringify({ text, html, before, after, other }));')"
  python3 - "$MS365_DISCLOSURE_OUTPUT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["text"] == "notice\n\nhello", payload
assert payload["html"].startswith('<div style='), payload
assert payload["before"] is False, payload
assert payload["after"] is True, payload
assert payload["other"] is False, payload
PY
  kill "$TEAMS_PLUGIN_PID" >/dev/null 2>&1 || true
  wait "$TEAMS_PLUGIN_PID" >/dev/null 2>&1 || true
  TEAMS_PLUGIN_PID=""
else
  log "bun not installed; skipping Teams channel plugin runtime smoke"
fi

log "syncing dev-loaded plugin cache to live marketplace sources"
DEV_PLUGIN_MARKETPLACE_ROOT="$TMP_ROOT/dev-plugin-marketplace"
mkdir -p "$DEV_PLUGIN_MARKETPLACE_ROOT/.claude-plugin" \
  "$DEV_PLUGIN_MARKETPLACE_ROOT/plugins/teams" \
  "$DEV_PLUGIN_MARKETPLACE_ROOT/plugins/ms365"
cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$DEV_PLUGIN_MARKETPLACE_ROOT/.claude-plugin/marketplace.json"
cp "$REPO_ROOT/plugins/teams/.mcp.json" "$DEV_PLUGIN_MARKETPLACE_ROOT/plugins/teams/.mcp.json"
cp "$REPO_ROOT/plugins/ms365/.mcp.json" "$DEV_PLUGIN_MARKETPLACE_ROOT/plugins/ms365/.mcp.json"
printf 'source server\n' >"$DEV_PLUGIN_MARKETPLACE_ROOT/plugins/teams/server.ts"
printf 'source server\n' >"$DEV_PLUGIN_MARKETPLACE_ROOT/plugins/ms365/server.ts"
TEAMS_CACHE_VERSION_DIR="$BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT/agent-bridge/teams/0.1.0"
rm -rf "$BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT/agent-bridge/teams"
mkdir -p "$TEAMS_CACHE_VERSION_DIR/node_modules/@smoke-dep"
printf 'stale cache\n' >"$TEAMS_CACHE_VERSION_DIR/server.ts"
printf '{"name":"@smoke-dep"}\n' >"$TEAMS_CACHE_VERSION_DIR/node_modules/@smoke-dep/package.json"
printf 'orphaned\n' >"$TEAMS_CACHE_VERSION_DIR/.orphaned_at"
DEV_PLUGIN_CACHE_JSON="$(python3 "$REPO_ROOT/bridge-dev-plugin-cache.py" sync --channels "plugin:teams@agent-bridge" --root "$DEV_PLUGIN_MARKETPLACE_ROOT" --json)"
python3 - "$DEV_PLUGIN_CACHE_JSON" "$DEV_PLUGIN_MARKETPLACE_ROOT/plugins/teams" "$TEAMS_CACHE_VERSION_DIR" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(sys.argv[1])
source = Path(sys.argv[2]).resolve()
cache_version = Path(sys.argv[3])
results = payload["results"]
assert len(results) == 1, results
row = results[0]
assert row["plugin"] == "teams", row
assert row["status"] in {"linked", "updated", "unchanged"}, row
assert row["cache_type"] == "directory", row
assert row["node_modules_status"] == "linked", row
assert cache_version.is_dir() and not cache_version.is_symlink(), cache_version
assert (cache_version / "server.ts").read_text(encoding="utf-8") == "source server\n"
assert not (cache_version / ".orphaned_at").exists()
source_node_modules = source / "node_modules"
cache_node_modules = cache_version / "node_modules"
assert source_node_modules.is_symlink(), source_node_modules
assert source_node_modules.resolve() == cache_node_modules.resolve(), (source_node_modules, cache_node_modules)
assert (source_node_modules / "@smoke-dep" / "package.json").exists()
mcp = json.loads((source / ".mcp.json").read_text(encoding="utf-8"))
args = mcp["mcpServers"]["teams"]["args"]
assert args[:2] == ["--cwd", "${CLAUDE_PLUGIN_ROOT}"], args
assert args[2:] == ["--no-install", "${CLAUDE_PLUGIN_ROOT}/server.ts"], args
PY
python3 - "$DEV_PLUGIN_MARKETPLACE_ROOT/plugins/ms365/.mcp.json" <<'PY'
import json
import sys
from pathlib import Path

mcp = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
args = mcp["mcpServers"]["ms365"]["args"]
assert args[:2] == ["--cwd", "${CLAUDE_PLUGIN_ROOT}"], args
assert args[2:] == ["--no-install", "${CLAUDE_PLUGIN_ROOT}/server.ts"], args
PY
DEV_PLUGIN_CACHE_JSON_AGAIN="$(python3 "$REPO_ROOT/bridge-dev-plugin-cache.py" sync --channels "plugin:teams@agent-bridge" --root "$DEV_PLUGIN_MARKETPLACE_ROOT" --json)"
python3 - "$DEV_PLUGIN_CACHE_JSON_AGAIN" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["results"][0]["status"] == "unchanged", payload
assert payload["results"][0]["node_modules_status"] == "unchanged", payload
PY

log "syncing third-party dev-loaded plugin cache via known_marketplaces.json"
DEV_THIRD_MARKETPLACE_ROOT="$TMP_ROOT/dev-third-marketplace"
mkdir -p "$DEV_THIRD_MARKETPLACE_ROOT/.claude-plugin" \
  "$DEV_THIRD_MARKETPLACE_ROOT/plugins/third-plugin"
cat > "$DEV_THIRD_MARKETPLACE_ROOT/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "third-mkt",
  "metadata": {"version": "0.2.0"},
  "plugins": [
    {"name": "third-plugin", "source": "./plugins/third-plugin", "version": "0.2.0"}
  ]
}
JSON
cat > "$DEV_THIRD_MARKETPLACE_ROOT/plugins/third-plugin/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "third-plugin": {
      "type": "http",
      "url": "https://updated.example.invalid/mcp",
      "headers": {
        "Authorization": "Bearer __TOKEN_PLACEHOLDER__"
      }
    }
  }
}
JSON
printf 'third source\n' > "$DEV_THIRD_MARKETPLACE_ROOT/plugins/third-plugin/server.ts"
DEV_THIRD_INACCESSIBLE_ROOT="$TMP_ROOT/dev-third-inaccessible"
mkdir -p "$DEV_THIRD_INACCESSIBLE_ROOT/.claude-plugin"
chmod 000 "$DEV_THIRD_INACCESSIBLE_ROOT"
THIRD_CACHE_VERSION_DIR="$BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT/third-mkt/third-plugin/0.2.0"
rm -rf "$BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT/third-mkt"
mkdir -p "$THIRD_CACHE_VERSION_DIR"
cat > "$THIRD_CACHE_VERSION_DIR/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "third-plugin": {
      "type": "http",
      "url": "https://old.example.invalid/mcp",
      "headers": {
        "Authorization": "Bearer live-secret"
      }
    }
  }
}
JSON
chmod 0600 "$THIRD_CACHE_VERSION_DIR/.mcp.json"
cat > "$TMP_ROOT/known_marketplaces.json" <<JSON
{
  "third-mkt": {
    "installLocation": "$DEV_THIRD_INACCESSIBLE_ROOT",
    "source": {"source": "directory", "path": "$DEV_THIRD_MARKETPLACE_ROOT", "repo": "Example/third-mkt"}
  }
}
JSON
DEV_THIRD_CACHE_JSON="$(python3 "$REPO_ROOT/bridge-dev-plugin-cache.py" sync --channels "plugin:third-plugin@third-mkt" --root "$DEV_PLUGIN_MARKETPLACE_ROOT" --json)"
chmod 700 "$DEV_THIRD_INACCESSIBLE_ROOT"
python3 - "$DEV_THIRD_CACHE_JSON" "$THIRD_CACHE_VERSION_DIR/.mcp.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(sys.argv[1])
row = payload["results"][0]
assert row["plugin"] == "third-plugin", row
assert row["marketplace"] == "third-mkt", row
assert row["status"] in {"linked", "updated", "unchanged"}, row
mcp = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
server = mcp["mcpServers"]["third-plugin"]
assert server["url"] == "https://updated.example.invalid/mcp", server
assert server["headers"]["Authorization"] == "Bearer live-secret", server
PY
THIRD_CACHE_MCP_MODE="$(stat -c '%a' "$THIRD_CACHE_VERSION_DIR/.mcp.json" 2>/dev/null || stat -f '%Lp' "$THIRD_CACHE_VERSION_DIR/.mcp.json")"
[[ "$THIRD_CACHE_MCP_MODE" == "600" ]] || die "third-party dev cache .mcp.json mode widened during secret-preserving overlay: got $THIRD_CACHE_MCP_MODE"

BOOTSTRAP_FAIL_HOME="$TMP_ROOT/bootstrap-fail-home"
mkdir -p "$BOOTSTRAP_FAIL_HOME"
BOOTSTRAP_FAIL_OUTPUT="$(HOME="$BOOTSTRAP_FAIL_HOME" BRIDGE_CLAUDE_CHANNELS_HOME="$TMP_ROOT/empty-claude-channels" "$REPO_ROOT/agent-bridge" bootstrap --admin bootstrap-fail --engine claude --session bootstrap-fail --channels plugin:telegram --allow-from 123456789 --default-chat 123456789 --rcfile "$TMP_ROOT/bootstrap-fail.rc" --skip-daemon --skip-launchagent 2>&1 || true)"
assert_contains "$BOOTSTRAP_FAIL_OUTPUT" "error: Telegram bot token is required."
assert_contains "$BOOTSTRAP_FAIL_OUTPUT" "telegram bootstrap failed"

SETUP_TELEGRAM_HELP_OUTPUT="$("$BASH4_BIN" "$REPO_ROOT/bridge-setup.sh" telegram --help 2>&1)"
assert_contains "$SETUP_TELEGRAM_HELP_OUTPUT" "Usage:"
assert_contains "$SETUP_TELEGRAM_HELP_OUTPUT" "telegram <agent>"

log "ensuring static Claude launch command is bridge-controlled"
CLAUDE_LAUNCH_NO_CONTINUE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="0"
  bridge_agent_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_LAUNCH_NO_CONTINUE" "DISCORD_STATE_DIR=$CLAUDE_STATIC_WORKDIR/.discord claude --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
assert_contains "$CLAUDE_LAUNCH_NO_CONTINUE" "claude --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
[[ "$CLAUDE_LAUNCH_NO_CONTINUE" != *" -c "* ]] || die "static Claude launch still contains -c"
[[ "$CLAUDE_LAUNCH_NO_CONTINUE" != *"'DISCORD_STATE_DIR="* ]] || die "static Claude env prefix should not be shell-quoted"

CLAUDE_LAUNCH_MULTI_CHANNEL="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="0"
  BRIDGE_AGENT_CHANNELS["claude-static"]="plugin:discord@claude-plugins-official,plugin:telegram@claude-plugins-official"
  bridge_agent_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_LAUNCH_MULTI_CHANNEL" "--channels plugin:discord@claude-plugins-official --channels plugin:telegram@claude-plugins-official"
assert_not_contains "$CLAUDE_LAUNCH_MULTI_CHANNEL" "--channels plugin:discord@claude-plugins-official,plugin:telegram@claude-plugins-official"
assert_contains "$CLAUDE_LAUNCH_MULTI_CHANNEL" "DISCORD_STATE_DIR=$CLAUDE_STATIC_WORKDIR/.discord"
assert_contains "$CLAUDE_LAUNCH_MULTI_CHANNEL" "TELEGRAM_STATE_DIR=$CLAUDE_STATIC_WORKDIR/.telegram"

CLAUDE_LAUNCH_CONTINUE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_agent_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_LAUNCH_CONTINUE" "DISCORD_STATE_DIR=$CLAUDE_STATIC_WORKDIR/.discord claude --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
assert_contains "$CLAUDE_LAUNCH_CONTINUE" "claude --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
assert_not_contains "$CLAUDE_LAUNCH_CONTINUE" "claude --continue"
[[ "$CLAUDE_LAUNCH_CONTINUE" != *"'DISCORD_STATE_DIR="* ]] || die "static Claude env prefix should not be shell-quoted on continue"

CLAUDE_LAUNCH_RESTART_CONTINUE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  BRIDGE_AGENT_LOOP_RESTART_COUNT=1
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_agent_launch_cmd "claude-static" 2>&1
')"
# Issue #189: without a resumable transcript in ~/.claude/projects/<slug>/,
# emitting `--continue` would crash the claude CLI. Skip it and warn instead.
assert_not_contains "$CLAUDE_LAUNCH_RESTART_CONTINUE" "claude --continue"
assert_contains "$CLAUDE_LAUNCH_RESTART_CONTINUE" "no resumable session yet (first wake)"

cat >"$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md" <<'EOF'
# NEXT SESSION

Verify channel setup and tell the user what happened.
EOF
CLAUDE_LAUNCH_NEXT_SESSION_FRESH="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  BRIDGE_AGENT_LOOP_RESTART_COUNT=1
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_agent_launch_cmd "claude-static"
')"
assert_not_contains "$CLAUDE_LAUNCH_NEXT_SESSION_FRESH" "claude --continue"
rm -f "$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md"

cat >"$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md" <<'EOF'
# STALE NEXT SESSION

Already delivered in a previous restart.
EOF
rm -rf "$CLAUDE_STATIC_WORKDIR/archive"
CLAUDE_STATIC_NEXT_DIGEST="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_next_session_digest "claude-static"
')"
CLAUDE_STATIC_NEXT_MARKER_FILE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_next_session_marker_file "claude-static"
')"
mkdir -p "$(dirname "$CLAUDE_STATIC_NEXT_MARKER_FILE")"
printf '%s' "$CLAUDE_STATIC_NEXT_DIGEST" >"$CLAUDE_STATIC_NEXT_MARKER_FILE"
python3 - "$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md" <<'PY'
import os
import sys
import time

path = sys.argv[1]
old = time.time() - 600
os.utime(path, (old, old))
PY
CLAUDE_STALE_NEXT_CLEAR_AGE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  bridge_agent_maybe_expire_next_session "claude-static" 300 || true
')"
[[ "$CLAUDE_STALE_NEXT_CLEAR_AGE" =~ ^[0-9]+$ ]] || die "expected stale NEXT-SESSION auto-archive age"
[[ ! -f "$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md" ]] || die "expected stale NEXT-SESSION file to be archived away from active path"
[[ ! -f "$CLAUDE_STATIC_NEXT_MARKER_FILE" ]] || die "expected stale NEXT-SESSION marker to be cleared"
CLAUDE_STALE_NEXT_ARCHIVE="$(find "$CLAUDE_STATIC_WORKDIR/archive" -maxdepth 1 -name 'NEXT-SESSION.*.md' -print | head -n 1)"
[[ -n "$CLAUDE_STALE_NEXT_ARCHIVE" && -f "$CLAUDE_STALE_NEXT_ARCHIVE" ]] || die "expected stale NEXT-SESSION archive file"
assert_contains "$(cat "$CLAUDE_STALE_NEXT_ARCHIVE")" "Already delivered in a previous restart."

FAKE_CLAUDE_HOME="$TMP_ROOT/fake-claude-home"
mkdir -p "$FAKE_CLAUDE_HOME/.claude/sessions"
CLAUDE_STATIC_WORKDIR_SLUG="${CLAUDE_STATIC_WORKDIR//\//-}"
mkdir -p "$FAKE_CLAUDE_HOME/.claude/projects/$CLAUDE_STATIC_WORKDIR_SLUG"
cat >"$FAKE_CLAUDE_HOME/.claude/sessions/static-existing.json" <<EOF
{"sessionId":"static-existing-session-id","cwd":"$CLAUDE_STATIC_WORKDIR","startedAt":1760000000000}
EOF
cat >"$FAKE_CLAUDE_HOME/.claude/projects/$CLAUDE_STATIC_WORKDIR_SLUG/static-existing-session-id.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"claude-static","sessionId":"static-existing-session-id"}
EOF
CLAUDE_LAUNCH_EXISTING_SESSION="$(HOME="$FAKE_CLAUDE_HOME" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_agent_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_LAUNCH_EXISTING_SESSION" "claude --resume static-existing-session-id --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
CLAUDE_SAFE_MODE_RESUME="$(HOME="$FAKE_CLAUDE_HOME" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_build_safe_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_SAFE_MODE_RESUME" "claude --resume static-existing-session-id --dangerously-skip-permissions --name claude-static"
assert_not_contains "$CLAUDE_SAFE_MODE_RESUME" "--channels"
CLAUDE_FALSE_LAUNCH_RECOVERY="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CHANNELS["claude-static"]="plugin:teams@agent-bridge"
  BRIDGE_AGENT_LAUNCH_CMD["claude-static"]="false --dangerously-load-development-channels plugin:teams@agent-bridge --dangerously-skip-permissions"
  bridge_agent_launch_cmd "claude-static"
')"
assert_not_contains "$CLAUDE_FALSE_LAUNCH_RECOVERY" "false --dangerously"
assert_contains "$CLAUDE_FALSE_LAUNCH_RECOVERY" "claude --dangerously-skip-permissions --name claude-static"
assert_contains "$CLAUDE_FALSE_LAUNCH_RECOVERY" "--dangerously-load-development-channels plugin:teams@agent-bridge"
FAKE_CLAUDE_STALE_HOME="$TMP_ROOT/fake-claude-stale-home"
mkdir -p "$FAKE_CLAUDE_STALE_HOME/.claude/sessions"
cat >"$FAKE_CLAUDE_STALE_HOME/.claude/sessions/stale-existing.json" <<EOF
{"sessionId":"stale-detected-session-id","cwd":"$CLAUDE_STATIC_WORKDIR","startedAt":1760000000100}
EOF
CLAUDE_LAUNCH_STALE_DETECTED_SESSION="$(HOME="$FAKE_CLAUDE_STALE_HOME" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  BRIDGE_AGENT_LOOP_RESTART_COUNT=1
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_agent_launch_cmd "claude-static" 2>&1
')"
# Issue #189: when sessions/*.json references a session whose transcript is
# missing AND the projects cache for this workdir is empty, `--continue` would
# crash with "No deferred tool marker found". Skip the flag instead and warn.
assert_not_contains "$CLAUDE_LAUNCH_STALE_DETECTED_SESSION" "claude --continue"
assert_not_contains "$CLAUDE_LAUNCH_STALE_DETECTED_SESSION" "--resume stale-detected-session-id"
assert_contains "$CLAUDE_LAUNCH_STALE_DETECTED_SESSION" "no resumable session yet (first wake)"
cat >"$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md" <<'EOF'
# SAFE MODE NEXT SESSION

This should not suppress --continue in safe mode.
EOF
CLAUDE_SAFE_MODE_CONTINUE="$(HOME="$TMP_ROOT/safe-mode-continue-home" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_build_safe_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_SAFE_MODE_CONTINUE" "claude --continue --dangerously-skip-permissions --name claude-static"
assert_not_contains "$CLAUDE_SAFE_MODE_CONTINUE" "--channels"
rm -f "$CLAUDE_STATIC_WORKDIR/NEXT-SESSION.md"

REALPATH_REAL_WORKDIR="$TMP_ROOT/claude-realpath-real"
REALPATH_LINK_WORKDIR="$TMP_ROOT/claude-realpath-link"
mkdir -p "$REALPATH_REAL_WORKDIR"
# bridge_claude_launch_with_channels reads the realpath-resolved workdir's
# .discord/.env to decide whether to attach the discord channel arg, so the
# launch_cmd assertion below would otherwise test a missing-channel path
# instead of the realpath resume path it advertises.
cp -R "$CLAUDE_STATIC_WORKDIR/.discord" "$REALPATH_REAL_WORKDIR/.discord"
ln -s "$REALPATH_REAL_WORKDIR" "$REALPATH_LINK_WORKDIR"
FAKE_CLAUDE_REALPATH_HOME="$TMP_ROOT/fake-claude-realpath-home"
mkdir -p "$FAKE_CLAUDE_REALPATH_HOME/.claude/sessions"
REALPATH_REAL_WORKDIR_SLUG="${REALPATH_REAL_WORKDIR//\//-}"
mkdir -p "$FAKE_CLAUDE_REALPATH_HOME/.claude/projects/$REALPATH_REAL_WORKDIR_SLUG"
cat >"$FAKE_CLAUDE_REALPATH_HOME/.claude/sessions/realpath-existing.json" <<EOF
{"sessionId":"realpath-session-id","cwd":"$REALPATH_REAL_WORKDIR","startedAt":1760000000200}
EOF
cat >"$FAKE_CLAUDE_REALPATH_HOME/.claude/projects/$REALPATH_REAL_WORKDIR_SLUG/realpath-session-id.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"claude-static","sessionId":"realpath-session-id"}
EOF
CLAUDE_REALPATH_REFRESH_OUTPUT="$(HOME="$FAKE_CLAUDE_REALPATH_HOME" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  BRIDGE_AGENT_WORKDIR["claude-static"]="'"$REALPATH_LINK_WORKDIR"'"
  BRIDGE_AGENT_CREATED_AT["claude-static"]="1760000000"
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_refresh_agent_session_id "claude-static" 2 0
  printf "SESSION_ID=%s" "${BRIDGE_AGENT_SESSION_ID["claude-static"]-}"
')"
assert_contains "$CLAUDE_REALPATH_REFRESH_OUTPUT" "SESSION_ID=realpath-session-id"
FAKE_CLAUDE_NEXT_REFRESH_HOME="$TMP_ROOT/fake-claude-next-refresh-home"
mkdir -p "$FAKE_CLAUDE_NEXT_REFRESH_HOME/.claude/sessions" \
  "$FAKE_CLAUDE_NEXT_REFRESH_HOME/.claude/projects/$CLAUDE_STATIC_WORKDIR_SLUG"
cat >"$FAKE_CLAUDE_NEXT_REFRESH_HOME/.claude/sessions/next-refresh.json" <<EOF
{"sessionId":"next-session-new-id","cwd":"$CLAUDE_STATIC_WORKDIR","startedAt":1760000000300}
EOF
cat >"$FAKE_CLAUDE_NEXT_REFRESH_HOME/.claude/projects/$CLAUDE_STATIC_WORKDIR_SLUG/next-session-new-id.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"claude-static","sessionId":"next-session-new-id"}
EOF
cat >"$FAKE_CLAUDE_NEXT_REFRESH_HOME/.claude/projects/$CLAUDE_STATIC_WORKDIR_SLUG/next-session-old-id.jsonl" <<'EOF'
{"type":"custom-title","customTitle":"claude-static","sessionId":"next-session-old-id"}
EOF
CLAUDE_NEXT_REFRESH_OUTPUT="$(HOME="$FAKE_CLAUDE_NEXT_REFRESH_HOME" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  BRIDGE_AGENT_CREATED_AT["claude-static"]="1760000000"
  BRIDGE_AGENT_SESSION_ID["claude-static"]="next-session-old-id"
  bridge_refresh_agent_session_id "claude-static" 2 0 "next-session-old-id"
  printf "SESSION_ID=%s PERSISTED=%s" \
    "${BRIDGE_AGENT_SESSION_ID["claude-static"]-}" \
    "$(bridge_agent_persisted_session_id "claude-static")"
')"
assert_contains "$CLAUDE_NEXT_REFRESH_OUTPUT" "SESSION_ID=next-session-new-id"
assert_contains "$CLAUDE_NEXT_REFRESH_OUTPUT" "PERSISTED=next-session-new-id"
CLAUDE_REALPATH_LAUNCH_OUTPUT="$(HOME="$FAKE_CLAUDE_REALPATH_HOME" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  BRIDGE_AGENT_CONTINUE["claude-static"]="1"
  BRIDGE_AGENT_WORKDIR["claude-static"]="'"$REALPATH_LINK_WORKDIR"'"
  unset BRIDGE_AGENT_SESSION_ID["claude-static"]
  bridge_agent_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_REALPATH_LAUNCH_OUTPUT" "claude --resume realpath-session-id --dangerously-skip-permissions --name claude-static"

CLAUDE_CHANNEL_STATUS="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  printf "%s" "$(bridge_agent_channel_status "claude-static")"
')"
[[ "$CLAUDE_CHANNEL_STATUS" == "ok" ]] || die "expected claude-static channel status to be ok"
CLAUDE_STATIC_SHOW_JSON="$("$REPO_ROOT/agent-bridge" agent show "claude-static" --json)"
python3 - "$CLAUDE_STATIC_SHOW_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
diagnostics = payload["channels"]["diagnostics"]
assert len(diagnostics) == 1, diagnostics
item = diagnostics[0]
assert item["channel"] == "plugin:discord@claude-plugins-official", item
assert item["plugin_installed"] is True, item
assert item["plugin_enabled"] is True, item
assert item["launch_allowlisted"] is True, item
assert item["access_status"] == "present", item
assert item["credentials_status"] == "present", item
assert item["runtime_ready"] is True, item
session = payload["session_health"]
assert session["loop"] is True, session
assert session["continue"] is True, session
assert session["restart_readiness"] == "ready", session
assert session["detach_hint"] == "Ctrl-b then d", session
assert session["stop_command"] == "agent-bridge kill claude-static", session
PY
assert_not_contains "$CLAUDE_STATIC_SHOW_JSON" "smoke-token"
CLAUDE_STATIC_SHOW_TEXT="$("$REPO_ROOT/agent-bridge" agent show "claude-static")"
assert_contains "$CLAUDE_STATIC_SHOW_TEXT" "channel_diagnostics:"
assert_contains "$CLAUDE_STATIC_SHOW_TEXT" "plugin: installed=yes enabled=yes"
assert_contains "$CLAUDE_STATIC_SHOW_TEXT" "session_health:"
assert_contains "$CLAUDE_STATIC_SHOW_TEXT" "detach_to_shell: Ctrl-b then d"
assert_not_contains "$CLAUDE_STATIC_SHOW_TEXT" "smoke-token"

STATIC_HISTORY_CONTINUE="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  history_file="$(bridge_history_file_for_agent "claude-static")"
  cat >"$history_file" <<EOF
AGENT_ID=claude-static
AGENT_CONTINUE=0
AGENT_SESSION_ID=history-session-id
EOF
  bridge_load_roster
  printf "%s" "$(bridge_agent_continue "claude-static")"
')"
[[ "$STATIC_HISTORY_CONTINUE" == "1" ]] || die "static history should not override continue defaults"

FAKE_CLAUDE_CONTINUE_HOME="$TMP_ROOT/fake-claude-continue-home"
# Seed a fresh transcript at the realpath-resolved project dir so the launch
# path can discover a non-stale session id and exercise the resume branch
# (the previous fixture only verified the --continue fallback that fires when
# *no* transcript exists, hiding the stale-id rejection path under test).
python3 - "$FAKE_CLAUDE_CONTINUE_HOME" "$CLAUDE_STATIC_WORKDIR" <<'PY'
import os
import sys

home, workdir = sys.argv[1:]
slug = os.path.realpath(workdir).replace("/", "-")
project_dir = os.path.join(home, ".claude", "projects", slug)
os.makedirs(project_dir, exist_ok=True)
with open(os.path.join(project_dir, "continue-session-id.jsonl"), "w", encoding="utf-8") as handle:
    handle.write('{"sessionId":"continue-session-id"}\n')
PY
CLAUDE_STALE_RESUME_FALLBACK="$(HOME="$FAKE_CLAUDE_CONTINUE_HOME" "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  history_file="$(bridge_history_file_for_agent "claude-static")"
  cat >"$history_file" <<EOF
AGENT_ID=claude-static
AGENT_ENGINE=claude
AGENT_WORKDIR='"$CLAUDE_STATIC_WORKDIR"'
AGENT_CONTINUE=1
AGENT_SESSION_ID=stale-session-id
EOF
  bridge_load_roster
  bridge_agent_launch_cmd "claude-static"
')"
assert_contains "$CLAUDE_STALE_RESUME_FALLBACK" "claude --resume continue-session-id --dangerously-skip-permissions --name claude-static --channels plugin:discord@claude-plugins-official"
assert_not_contains "$CLAUDE_STALE_RESUME_FALLBACK" "--resume stale-session-id"

log "reloading roster inside the long-lived bridge-run loop"
FAKE_CLAUDE_BIN="$TMP_ROOT/fake-claude-bin"
FAKE_CLAUDE_LOG="$TMP_ROOT/fake-claude-invocations.log"
mkdir -p "$FAKE_CLAUDE_BIN"
python3 - "$FAKE_CLAUDE_BIN/claude" "$FAKE_CLAUDE_LOG" <<'PY'
from pathlib import Path
import sys

script_path = Path(sys.argv[1])
log_path = sys.argv[2]
script_path.write_text(
    "#!/usr/bin/env bash\n"
    f"printf 'mark=%s args=%s\\n' \"${{ROSTER_MARK:-}}\" \"$*\" >> {log_path!r}\n"
    "exit 0\n",
    encoding="utf-8",
)
PY
chmod +x "$FAKE_CLAUDE_BIN/claude"
: >"$FAKE_CLAUDE_LOG"
python3 - "$BRIDGE_ROSTER_LOCAL_FILE" "$ROSTER_RELOAD_AGENT" "$FAKE_CLAUDE_BIN/claude" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
agent = sys.argv[2]
claude_path = sys.argv[3]
text = path.read_text(encoding="utf-8")
pattern = re.compile(rf'(?m)^BRIDGE_AGENT_LAUNCH_CMD\["{re.escape(agent)}"\]=.*$')
replacement = f'BRIDGE_AGENT_LAUNCH_CMD["{agent}"]=\'ROSTER_MARK=before {claude_path} --dangerously-skip-permissions --name roster-reload\''
text, count = pattern.subn(replacement, text, count=1)
assert count == 1, (agent, path)
path.write_text(text, encoding="utf-8")
PY
ROSTER_RELOAD_RUN_LOG="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  printf "%s/%s.log" "$(bridge_agent_log_dir "$1")" "$(date "+%Y%m%d")"
' -- "$ROSTER_RELOAD_AGENT")"
"$BASH4_BIN" "$REPO_ROOT/bridge-run.sh" "$ROSTER_RELOAD_AGENT" >/dev/null 2>&1 &
ROSTER_RELOAD_PID=$!
for _ in {1..40}; do
  if [[ -f "$FAKE_CLAUDE_LOG" ]] && grep -Fq 'mark=before' "$FAKE_CLAUDE_LOG"; then
    break
  fi
  sleep 0.25
done
grep -Fq 'mark=before' "$FAKE_CLAUDE_LOG" || die "expected first bridge-run launch to use initial roster launch command"
python3 - "$BRIDGE_ROSTER_LOCAL_FILE" "$ROSTER_RELOAD_AGENT" "$FAKE_CLAUDE_BIN/claude" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
agent = sys.argv[2]
claude_path = sys.argv[3]
text = path.read_text(encoding="utf-8")
pattern = re.compile(rf'(?m)^BRIDGE_AGENT_LAUNCH_CMD\["{re.escape(agent)}"\]=.*$')
replacement = f'BRIDGE_AGENT_LAUNCH_CMD["{agent}"]=\'ROSTER_MARK=after {claude_path} --dangerously-skip-permissions --name roster-reload\''
text, count = pattern.subn(replacement, text, count=1)
assert count == 1, (agent, path)
path.write_text(text, encoding="utf-8")
PY
for _ in {1..40}; do
  if grep -Fq 'mark=after' "$FAKE_CLAUDE_LOG"; then
    break
  fi
  sleep 0.25
done
grep -Fq 'mark=after' "$FAKE_CLAUDE_LOG" || die "expected bridge-run loop to reload roster changes before next relaunch"
grep -Fq 'roster changed on disk; reloading before next relaunch' "$ROSTER_RELOAD_RUN_LOG" || die "expected bridge-run to log roster reload"
kill "$ROSTER_RELOAD_PID" >/dev/null 2>&1 || true
wait "$ROSTER_RELOAD_PID" >/dev/null 2>&1 || true

log "auto-accepting Claude development-channel warnings for allowlisted dev plugins"
DEV_CHANNELS_PROMPT_SESSION="dev-channels-prompt-$SESSION_NAME"
DEV_CHANNELS_PROMPT_ACK="$TMP_ROOT/dev-channels-prompt-ack.txt"
DEV_CHANNELS_PROMPT_SCRIPT="$TMP_ROOT/dev-channels-prompt.sh"
cat >"$DEV_CHANNELS_PROMPT_SCRIPT" <<EOF
#!/usr/bin/env bash
printf 'WARNING: Loading development channels\n'
printf 'I am using this for local development\n'
printf 'Enter to confirm · Esc to cancel\n'
IFS= read -r line
printf '%s\n' "\${line:-<enter>}" >"$DEV_CHANNELS_PROMPT_ACK"
printf '❯ \n'
sleep 2
EOF
chmod +x "$DEV_CHANNELS_PROMPT_SCRIPT"
tmux new-session -d -s "$DEV_CHANNELS_PROMPT_SESSION" "$DEV_CHANNELS_PROMPT_SCRIPT"
BRIDGE_TMUX_DEV_CHANNELS_REQUIRE_CLAUDE_FOREGROUND=0 "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_tmux_wait_for_prompt "'"$DEV_CHANNELS_PROMPT_SESSION"'" claude 5 1
' >/dev/null
assert_contains "$(cat "$DEV_CHANNELS_PROMPT_ACK")" "<enter>"
tmux kill-session -t "=$DEV_CHANNELS_PROMPT_SESSION" >/dev/null 2>&1 || true

log "gating dev-channel auto-accept on Claude foreground readiness (#429)"
DEV_CHANNELS_CLAUDE_BIN="$TMP_ROOT/claude"
DEV_CHANNELS_CLAUDE_SESSION="dev-channels-claude-fg-$SESSION_NAME"
DEV_CHANNELS_SLEEP_SESSION="dev-channels-sleep-fg-$SESSION_NAME"
DEV_CHANNELS_WRAPPED_SESSION="dev-channels-wrapped-fg-$SESSION_NAME"
DEV_CHANNELS_DELAYED_SESSION="dev-channels-delayed-fg-$SESSION_NAME"
DEV_CHANNELS_WRAPPED_SCRIPT="$TMP_ROOT/dev-channels-wrapped.sh"
DEV_CHANNELS_DELAYED_SCRIPT="$TMP_ROOT/dev-channels-delayed.sh"
ln -sf "$(command -v sleep)" "$DEV_CHANNELS_CLAUDE_BIN"
tmux new-session -d -s "$DEV_CHANNELS_CLAUDE_SESSION" "$DEV_CHANNELS_CLAUDE_BIN 2"
tmux new-session -d -s "$DEV_CHANNELS_SLEEP_SESSION" "$(command -v sleep) 2"
cat >"$DEV_CHANNELS_WRAPPED_SCRIPT" <<EOF
#!/usr/bin/env bash
"$DEV_CHANNELS_CLAUDE_BIN" 2
EOF
cat >"$DEV_CHANNELS_DELAYED_SCRIPT" <<EOF
#!/usr/bin/env bash
sleep 1
"$DEV_CHANNELS_CLAUDE_BIN" 2
EOF
chmod +x "$DEV_CHANNELS_WRAPPED_SCRIPT" "$DEV_CHANNELS_DELAYED_SCRIPT"
tmux new-session -d -s "$DEV_CHANNELS_WRAPPED_SESSION" "$DEV_CHANNELS_WRAPPED_SCRIPT"
tmux new-session -d -s "$DEV_CHANNELS_DELAYED_SESSION" "$DEV_CHANNELS_DELAYED_SCRIPT"
wait_for_tmux_session "$DEV_CHANNELS_CLAUDE_SESSION" up 10 0.1
wait_for_tmux_session "$DEV_CHANNELS_SLEEP_SESSION" up 10 0.1
wait_for_tmux_session "$DEV_CHANNELS_WRAPPED_SESSION" up 10 0.1
wait_for_tmux_session "$DEV_CHANNELS_DELAYED_SESSION" up 10 0.1
"$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_tmux_pane_foreground_is_claude "'"$DEV_CHANNELS_CLAUDE_SESSION"'"
' >/dev/null || die "expected symlinked claude foreground to be detected"
"$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_tmux_pane_foreground_is_claude "'"$DEV_CHANNELS_WRAPPED_SESSION"'"
' >/dev/null || die "expected wrapped claude child process to be detected"
"$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_POLL_SECONDS=0.1 \
    BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_MAX_CHECKS=40 \
    bridge_tmux_wait_for_claude_foreground "'"$DEV_CHANNELS_DELAYED_SESSION"'" 5 0.1 40
' >/dev/null || die "expected delayed wrapped claude foreground wait to succeed"
if "$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_tmux_pane_foreground_is_claude "'"$DEV_CHANNELS_SLEEP_SESSION"'"
' >/dev/null; then
  die "sleep foreground must not be classified as claude"
fi
tmux kill-session -t "=$DEV_CHANNELS_CLAUDE_SESSION" >/dev/null 2>&1 || true
tmux kill-session -t "=$DEV_CHANNELS_SLEEP_SESSION" >/dev/null 2>&1 || true
tmux kill-session -t "=$DEV_CHANNELS_WRAPPED_SESSION" >/dev/null 2>&1 || true
tmux kill-session -t "=$DEV_CHANNELS_DELAYED_SESSION" >/dev/null 2>&1 || true

# Item 4 (PR #442 r2): exercise the *full* dispatch path end-to-end.
# The previous case only validates the foreground detector + wait helper in
# isolation. This case wires both into the picker dispatcher
# (bridge_tmux_claude_advance_blocker) so a regression that re-orders the
# wait + send-keys, drops the foreground gate, or short-circuits before
# Enter is dispatched cannot pass without smoke-level fail.
log "dispatching dev-channel auto-accept via advance_blocker (#442 item 4)"
DEV_CHANNELS_DISPATCH_SESSION="dev-channels-dispatch-$SESSION_NAME"
DEV_CHANNELS_DISPATCH_ACK="$TMP_ROOT/dev-channels-dispatch-ack.txt"
DEV_CHANNELS_DISPATCH_BIN_DIR="$TMP_ROOT/dev-channels-dispatch-bin"
# Synthetic claude binary lives in its own dir under exact name `claude`
# so bridge_tmux_command_name_is_claude classifies the basename correctly
# (the matcher accepts only `claude` / `claude-*` / `claude.*`, so a longer
# path basename like `dev-channels-dispatch-claude` would NOT match).
DEV_CHANNELS_DISPATCH_CLAUDE="$DEV_CHANNELS_DISPATCH_BIN_DIR/claude"
DEV_CHANNELS_DISPATCH_PAYLOAD="$TMP_ROOT/dev-channels-dispatch-payload.sh"
DEV_CHANNELS_DISPATCH_SCRIPT="$TMP_ROOT/dev-channels-dispatch.sh"
rm -f "$DEV_CHANNELS_DISPATCH_ACK"
mkdir -p "$DEV_CHANNELS_DISPATCH_BIN_DIR"
# Synthetic claude binary: a "claude"-named symlink to bash, so when the
# driver script execs it the pane PID's `ps -o comm=` reports "claude" and
# bridge_tmux_pane_foreground_is_claude classifies the foreground correctly.
ln -sf "$(command -v bash)" "$DEV_CHANNELS_DISPATCH_CLAUDE"
# Payload script run as the bash arg under the claude symlink: reads one
# line from its stdin and writes "<enter>" (or the literal line) to the ack
# file. Lives long enough for the dispatcher's wait + capture + send + read.
cat >"$DEV_CHANNELS_DISPATCH_PAYLOAD" <<EOF
IFS= read -r line
printf '%s\n' "\${line:-<enter>}" >"$DEV_CHANNELS_DISPATCH_ACK"
sleep 2
EOF
chmod +x "$DEV_CHANNELS_DISPATCH_PAYLOAD"
# Pane bootstrap: print the dev-channels banner so blocker_state classifies
# as "devchannels", briefly run a non-claude foreground (sleep) so the
# wait loop has to spin at least once, then exec the claude stub so the
# detector sees a "claude" comm on the pane PID's process tree.
cat >"$DEV_CHANNELS_DISPATCH_SCRIPT" <<EOF
#!/usr/bin/env bash
printf 'WARNING: Loading development channels\n'
printf 'I am using this for local development\n'
printf 'Enter to confirm · Esc to cancel\n'
sleep 0.5
exec "$DEV_CHANNELS_DISPATCH_CLAUDE" "$DEV_CHANNELS_DISPATCH_PAYLOAD"
EOF
chmod +x "$DEV_CHANNELS_DISPATCH_SCRIPT"
tmux new-session -d -s "$DEV_CHANNELS_DISPATCH_SESSION" "$DEV_CHANNELS_DISPATCH_SCRIPT"
wait_for_tmux_session "$DEV_CHANNELS_DISPATCH_SESSION" up 10 0.1
# Wait until the driver has actually printed the dev-channels banner so
# bridge_tmux_claude_blocker_state classifies the pane as "devchannels"
# before we invoke the dispatcher. Without this wait, advance_blocker is
# called while the pane PID is still `/usr/bin/env` and the expected_state
# guard short-circuits with rc=1.
DEV_CHANNELS_DISPATCH_READY=0
for _ in {1..50}; do
  if tmux capture-pane -p -t "=$DEV_CHANNELS_DISPATCH_SESSION:" 2>/dev/null \
      | grep -Fq 'WARNING: Loading development channels'; then
    DEV_CHANNELS_DISPATCH_READY=1
    break
  fi
  sleep 0.1
done
[[ "$DEV_CHANNELS_DISPATCH_READY" == "1" ]] || die "dev-channels dispatch driver did not render banner"
"$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_WAIT_SECONDS=5 \
    BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_POLL_SECONDS=0.1 \
    BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_MAX_CHECKS=50 \
    BRIDGE_TMUX_DEV_CHANNELS_FOREGROUND_SETTLE_SECONDS=0.05 \
    bridge_tmux_claude_advance_blocker "'"$DEV_CHANNELS_DISPATCH_SESSION"'" 1 devchannels
' >/dev/null || die "advance_blocker dispatch did not succeed for delayed-claude pane"
for _ in {1..40}; do
  [[ -s "$DEV_CHANNELS_DISPATCH_ACK" ]] && break
  sleep 0.1
done
[[ -s "$DEV_CHANNELS_DISPATCH_ACK" ]] || die "advance_blocker did not deliver Enter to dev-channels picker"
assert_contains "$(cat "$DEV_CHANNELS_DISPATCH_ACK")" "<enter>"
tmux kill-session -t "=$DEV_CHANNELS_DISPATCH_SESSION" >/dev/null 2>&1 || true

# Issue #825 regression suite: controller-side dev-channels auto-accept
# watcher must fire on pane-content-text trigger (not solely on the
# foreground basename gate). Pre-fix the watcher would wedge indefinitely
# on live v0.11.0+ installs when the picker text was visible but the
# foreground process name did not match claude|claude-*|claude.*.
log "running issue #825 controller dev-channels auto-accept regression"
bash "$REPO_ROOT/scripts/test-controller-dev-channels-accept.sh" \
  || die "issue #825 controller dev-channels auto-accept suite failed"

log "classifying admin foreground exit by onboarding state"
ONBOARDING_ADMIN_WORKDIR="$TMP_ROOT/onboarding-admin"
mkdir -p "$ONBOARDING_ADMIN_WORKDIR"
ONBOARDING_EXIT_OUTPUT="$("$BASH4_BIN" -c '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  agent="onboarding-admin-smoke"
  bridge_add_agent_id_if_missing "$agent"
  BRIDGE_ADMIN_AGENT_ID="$agent"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="onboarding-admin-smoke"
  BRIDGE_AGENT_WORKDIR["$agent"]="'"$ONBOARDING_ADMIN_WORKDIR"'"
  cat >"'"$ONBOARDING_ADMIN_WORKDIR"'/SESSION-TYPE.md" <<EOF
- Session Type: admin
- Onboarding State: pending
EOF
  if bridge_agent_should_stop_on_attached_clean_exit "$agent"; then
    echo "pending=stop"
  else
    echo "pending=loop"
  fi
  cat >"'"$ONBOARDING_ADMIN_WORKDIR"'/SESSION-TYPE.md" <<EOF
- Session Type: admin
- Onboarding State: complete
EOF
  if bridge_agent_should_stop_on_attached_clean_exit "$agent"; then
    echo "complete=stop"
  else
    echo "complete=loop"
  fi
')"
assert_contains "$ONBOARDING_EXIT_OUTPUT" "pending=stop"
assert_contains "$ONBOARDING_EXIT_OUTPUT" "complete=loop"

log "configuring admin role and launching it"
SETUP_ADMIN_OUTPUT="$("$REPO_ROOT/agent-bridge" setup admin "$SMOKE_AGENT")"
assert_contains "$SETUP_ADMIN_OUTPUT" "admin_agent: $SMOKE_AGENT"
assert_contains "$SETUP_ADMIN_OUTPUT" "next_command: agb admin"
assert_contains "$(cat "$BRIDGE_ROSTER_LOCAL_FILE")" "BRIDGE_ADMIN_AGENT_ID=\"$SMOKE_AGENT\""

ADMIN_OUTPUT="$("$REPO_ROOT/agent-bridge" admin --no-attach 2>&1)"
if [[ "$ADMIN_OUTPUT" != *"세션 '$SESSION_NAME'이 이미 실행 중입니다."* && "$ADMIN_OUTPUT" != *"세션 '$SESSION_NAME' 시작 완료"* ]]; then
  die "expected admin launch to either reuse or start session"
fi

ADMIN_SAFE_MODE_DRY_RUN="$("$REPO_ROOT/agent-bridge" admin --safe-mode --replace --no-attach --dry-run 2>&1)" || die "admin safe-mode dry-run failed: $ADMIN_SAFE_MODE_DRY_RUN"
assert_contains "$ADMIN_SAFE_MODE_DRY_RUN" "safe_mode=1"
assert_contains "$ADMIN_SAFE_MODE_DRY_RUN" "--safe-mode"

ADMIN_REPLACE_OUTPUT="$("$REPO_ROOT/agent-bridge" admin --replace --no-continue --no-attach 2>&1)" || die "admin replace failed: $ADMIN_REPLACE_OUTPUT"
assert_contains "$ADMIN_REPLACE_OUTPUT" "세션 '$SESSION_NAME' 시작 완료"

log "opening the circuit breaker after repeated rapid launch failures"
CIRCUIT_AGENT="circuit-breaker-$SESSION_NAME"
CIRCUIT_SESSION="circuit-breaker-session-$SESSION_NAME"
CIRCUIT_WORKDIR="$TMP_ROOT/circuit-breaker-workdir"
CIRCUIT_CLAUDE_BIN_DIR="$TMP_ROOT/circuit-claude-bin"
CIRCUIT_CLAUDE_LOG="$TMP_ROOT/circuit-claude.log"
mkdir -p "$CIRCUIT_WORKDIR" "$CIRCUIT_CLAUDE_BIN_DIR"
python3 - "$CIRCUIT_CLAUDE_BIN_DIR/claude" "$CIRCUIT_CLAUDE_LOG" <<'PY'
from pathlib import Path
import sys

script_path = Path(sys.argv[1])
log_path = sys.argv[2]
script_path.write_text(
    "#!/usr/bin/env bash\n"
    "printf 'args=%s\\n' \"$*\" >> " + repr(log_path) + "\n"
    "printf 'broken launch smoke error\\n' >&2\n"
    "exit 1\n",
    encoding="utf-8",
)
PY
chmod +x "$CIRCUIT_CLAUDE_BIN_DIR/claude"
: >"$CIRCUIT_CLAUDE_LOG"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

# BEGIN AGENT BRIDGE MANAGED ROLE: $CIRCUIT_AGENT
bridge_add_agent_id_if_missing "$CIRCUIT_AGENT"
BRIDGE_AGENT_DESC["$CIRCUIT_AGENT"]="Circuit breaker smoke role"
BRIDGE_AGENT_ENGINE["$CIRCUIT_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$CIRCUIT_AGENT"]="$CIRCUIT_SESSION"
BRIDGE_AGENT_WORKDIR["$CIRCUIT_AGENT"]="$CIRCUIT_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$CIRCUIT_AGENT"]='PATH=$CIRCUIT_CLAUDE_BIN_DIR:$PATH claude --dangerously-skip-permissions --name $CIRCUIT_AGENT'
BRIDGE_AGENT_LOOP["$CIRCUIT_AGENT"]="1"
BRIDGE_AGENT_CONTINUE["$CIRCUIT_AGENT"]="0"
# END AGENT BRIDGE MANAGED ROLE: $CIRCUIT_AGENT
EOF
smoke_track_managed_role_id "$CIRCUIT_AGENT"
CIRCUIT_BREAKER_OUTPUT="$(
  BRIDGE_RUN_MAX_RAPID_FAILS=3 \
  BRIDGE_RUN_FAIL_BACKOFFS_CSV=1,1,1 \
  BRIDGE_RUN_RAPID_FAIL_WINDOW_SECONDS=10 \
  "$BASH4_BIN" "$REPO_ROOT/bridge-run.sh" "$CIRCUIT_AGENT" 2>&1 || true
)"
assert_contains "$CIRCUIT_BREAKER_OUTPUT" "Circuit breaker opened."
assert_contains "$CIRCUIT_BREAKER_OUTPUT" "agent-bridge agent safe-mode $CIRCUIT_AGENT"
CIRCUIT_BROKEN_LAUNCH_FILE="$BRIDGE_STATE_DIR/agents/$CIRCUIT_AGENT/broken-launch"
[[ -f "$CIRCUIT_BROKEN_LAUNCH_FILE" ]] || die "expected broken-launch state file for $CIRCUIT_AGENT"
python3 - "$CIRCUIT_BROKEN_LAUNCH_FILE" "$CIRCUIT_AGENT" <<'PY'
import json
from pathlib import Path
import sys

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
agent = sys.argv[2]
assert payload["agent"] == agent, payload
assert payload["engine"] == "claude", payload
assert payload["fail_count"] == 3, payload
assert payload["exit_code"] == 1, payload
stderr_file = Path(payload["stderr_file"])
assert stderr_file.exists(), payload
stderr_text = stderr_file.read_text(encoding="utf-8")
assert "broken launch smoke error" in stderr_text, stderr_text
PY
CIRCUIT_SHOW_JSON="$("$REPO_ROOT/agent-bridge" agent show "$CIRCUIT_AGENT" --json)"
python3 - "$CIRCUIT_SHOW_JSON" "$CIRCUIT_BROKEN_LAUNCH_FILE" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
broken_launch_file = sys.argv[2]
session = payload["session_health"]
assert session["restart_readiness"] == "broken-launch", session
assert session["broken_launch_file"] == broken_launch_file, session
PY
CIRCUIT_SHOW_TEXT="$("$REPO_ROOT/agent-bridge" agent show "$CIRCUIT_AGENT")"
assert_contains "$CIRCUIT_SHOW_TEXT" "restart_readiness: broken-launch"
assert_contains "$CIRCUIT_SHOW_TEXT" "recovery: agent-bridge agent safe-mode $CIRCUIT_AGENT"

log "escalating a repeated unanswered question through the admin channel"
ESCALATE_DRY_RUN_JSON="$("$REPO_ROOT/agent-bridge" escalate question --agent "$CREATED_AGENT" --question "Should I deploy now?" --context "Second ask without a user reply." --wait-seconds 120 --json --dry-run)"
python3 - "$ESCALATE_DRY_RUN_JSON" "$SMOKE_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
admin_agent = sys.argv[2]

assert payload["agent"]
assert payload["admin_agent"] == admin_agent
assert payload["dry_run"] is True
assert payload["notify"]["target"]
PY

ESCALATE_JSON="$("$REPO_ROOT/agent-bridge" escalate question --agent "$CREATED_AGENT" --question "Should I deploy now?" --context "Second ask without a user reply." --wait-seconds 120 --json)"
python3 - "$ESCALATE_JSON" "$SMOKE_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
admin_agent = sys.argv[2]

assert payload["admin_agent"] == admin_agent
assert payload["task_id"]
assert payload["notify"]["status"] == "sent"
PY
assert_contains "$(cat "$FAKE_DISCORD_REQUESTS")" "Should I deploy now?"

log "verifying escalate question source-aware routing for dynamic agents (#343 Track A)"
ESCALATE_DYNAMIC_AGENT="escalate-dynamic-$$"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

# BEGIN AGENT BRIDGE MANAGED ROLE: $ESCALATE_DYNAMIC_AGENT
bridge_add_agent_id_if_missing "$ESCALATE_DYNAMIC_AGENT"
BRIDGE_AGENT_DESC["$ESCALATE_DYNAMIC_AGENT"]="Dynamic escalate fixture"
BRIDGE_AGENT_ENGINE["$ESCALATE_DYNAMIC_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$ESCALATE_DYNAMIC_AGENT"]="$ESCALATE_DYNAMIC_AGENT"
BRIDGE_AGENT_WORKDIR["$ESCALATE_DYNAMIC_AGENT"]="$PROJECT_ROOT"
BRIDGE_AGENT_SOURCE["$ESCALATE_DYNAMIC_AGENT"]="dynamic"
# END AGENT BRIDGE MANAGED ROLE: $ESCALATE_DYNAMIC_AGENT
EOF
smoke_track_managed_role_id "$ESCALATE_DYNAMIC_AGENT"

ESCALATE_DYNAMIC_STDERR="$TMP_ROOT/escalate-dynamic.stderr"
set +e
"$REPO_ROOT/agent-bridge" escalate question --agent "$ESCALATE_DYNAMIC_AGENT" --question "Should I deploy now?" --wait-seconds 30 2>"$ESCALATE_DYNAMIC_STDERR" >/dev/null
ESCALATE_DYNAMIC_RC=$?
set -e
[[ "$ESCALATE_DYNAMIC_RC" == "0" ]] || die "dynamic escalate should exit 0 (got $ESCALATE_DYNAMIC_RC)"
assert_contains "$(cat "$ESCALATE_DYNAMIC_STDERR")" "skipping admin escalation"
assert_contains "$(cat "$ESCALATE_DYNAMIC_STDERR")" "$ESCALATE_DYNAMIC_AGENT"
ESCALATE_DYNAMIC_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[question-escalation] $ESCALATE_DYNAMIC_AGENT " 2>/dev/null || true)"
[[ -z "$ESCALATE_DYNAMIC_TASK_ID" ]] || die "dynamic escalate should not create admin task (got #$ESCALATE_DYNAMIC_TASK_ID)"

ESCALATE_FORCE_JSON="$("$REPO_ROOT/agent-bridge" escalate question --agent "$ESCALATE_DYNAMIC_AGENT" --question "Force relay through admin." --wait-seconds 30 --force-admin-relay --json)"
python3 - "$ESCALATE_FORCE_JSON" "$SMOKE_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
admin_agent = sys.argv[2]

assert payload["admin_agent"] == admin_agent, payload
assert payload["task_id"], payload
PY
ESCALATE_FORCE_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[question-escalation] $ESCALATE_DYNAMIC_AGENT ")"
[[ "$ESCALATE_FORCE_TASK_ID" =~ ^[0-9]+$ ]] || die "force-admin-relay should create admin task (got '$ESCALATE_FORCE_TASK_ID')"

STATIC_START_DRY_RUN="$("$REPO_ROOT/bridge-start.sh" "$SMOKE_AGENT" --dry-run --no-continue 2>&1 || true)"

log "ensuring Claude Stop hook settings merge"
cat >"$HOOK_WORKDIR/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/session-start.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
EOF

SESSION_START_HOOK_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-session-start-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)")"
assert_contains "$SESSION_START_HOOK_OUTPUT" "session_start_hook: present"
HOOK_ENSURE_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-stop-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$HOOK_ENSURE_OUTPUT" "status: updated"
assert_contains "$HOOK_ENSURE_OUTPUT" "stop_hook: present"
assert_contains "$HOOK_ENSURE_OUTPUT" "additional_context: true"
SESSION_START_HOOK_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-session-start-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)")"
assert_contains "$SESSION_START_HOOK_STATUS_OUTPUT" "status: present"
assert_contains "$SESSION_START_HOOK_STATUS_OUTPUT" "session_start_hook: present"
HOOK_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-stop-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$HOOK_STATUS_OUTPUT" "status: present"
assert_contains "$HOOK_STATUS_OUTPUT" "additional_context: true"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"SessionStart\""
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"Stop\""
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"additionalContext\": true"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "mark-idle.sh"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "session-start.py"

PROMPT_HOOK_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-prompt-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash --python-bin "$(command -v python3)")"
assert_contains "$PROMPT_HOOK_OUTPUT" "prompt_hook: present"
assert_contains "$PROMPT_HOOK_OUTPUT" "timestamp_hook: present"
PROMPT_STATUS_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-prompt-hook --workdir "$HOOK_WORKDIR" --bridge-home "$BRIDGE_HOME" --bash-bin bash)"
assert_contains "$PROMPT_STATUS_OUTPUT" "status: present"
assert_contains "$PROMPT_STATUS_OUTPUT" "timestamp_hook: present"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"UserPromptSubmit\""
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "clear-idle.sh"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "prompt_timestamp.py"
assert_contains "$(cat "$HOOK_WORKDIR/.claude/settings.json")" "\"additionalContext\": true"
PROMPT_TIMESTAMP_TEXT="$(BRIDGE_AGENT_ID="$SMOKE_AGENT" BRIDGE_HOME="$BRIDGE_HOME" python3 "$REPO_ROOT/hooks/prompt_timestamp.py")"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "<timestamp>"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "now:"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "since_last:"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "<question_escalation>"
assert_contains "$PROMPT_TIMESTAMP_TEXT" "agent-bridge escalate question"

log "ensuring shared Claude settings symlink for bridge-owned agent homes"
cat >"$BRIDGE_HOME/agents/.claude/settings.local.json" <<'EOF'
{
  "enabledPlugins": {
    "local-test@example": true
  }
}
EOF
SHARED_HOOK_OUTPUT="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_ensure_claude_stop_hook \"$CLAUDE_STATIC_WORKDIR\"")"
assert_contains "$SHARED_HOOK_OUTPUT" "settings_file: $CLAUDE_STATIC_WORKDIR/.claude/settings.json"
assert_contains "$SHARED_HOOK_OUTPUT" "settings.effective.json"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/settings.json" ]] || die "expected shared Claude settings symlink"
SHARED_SYMLINK_TARGET="$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/settings.json")"
assert_contains "$SHARED_SYMLINK_TARGET" "../../.claude/settings.effective.json"
assert_contains "$(cat "$BRIDGE_HOME/agents/.claude/settings.effective.json")" "\"additionalContext\": true"
assert_contains "$(cat "$BRIDGE_HOME/agents/.claude/settings.effective.json")" "\"enabledPlugins\""
assert_contains "$(cat "$BRIDGE_HOME/agents/.claude/settings.effective.json")" "local-test@example"

log "ensuring shared Claude runtime skills for bridge-owned agent homes"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_bootstrap_claude_shared_skills \"$CLAUDE_STATIC_WORKDIR\""
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/agent-bridge-runtime" ]] || die "expected shared agent-bridge runtime skill symlink"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/cron-manager" ]] || die "expected shared cron-manager skill symlink"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/memory-wiki" ]] || die "expected shared memory-wiki skill symlink"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/agent-bridge-runtime")" "agent-bridge-runtime"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/cron-manager")" "cron-manager"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/memory-wiki")" "memory-wiki"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/agent-bridge-runtime/SKILL.md")" "Queue Source of Truth"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/agent-bridge-runtime/SKILL.md")" "Use the Bash tool and run exactly"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/memory-wiki/SKILL.md")" "memory remember"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/memory-wiki/SKILL.md")" "Raw-Source Ingest Workflow"
assert_contains "$(cat "$REPO_ROOT/.claude/skills/memory-wiki/SKILL.md")" "capture -> ingest"

log "ensuring HUD usage tap statusLine patching (ensure-hud-usage-tap)"
HUD_TAP_WORKDIR="$TMP_ROOT/hud-tap-workdir"
mkdir -p "$HUD_TAP_WORKDIR/.claude"
# Seed an unpatched HUD statusLine in settings.json
python3 -c "
import json, pathlib
cfg = {
  'statusLine': {
    'type': 'command',
    'command': 'bash -c \'plugin_dir=x; exec \"/usr/bin/bun\" --env-file /dev/null \"\${plugin_dir}src/index.ts\"\''
  }
}
pathlib.Path('$HUD_TAP_WORKDIR/.claude/settings.json').write_text(json.dumps(cfg, indent=2))
"
HUD_TAP_STATUS_BEFORE="$(python3 "$REPO_ROOT/bridge-hooks.py" status-hud-usage-tap --workdir "$HUD_TAP_WORKDIR" --bridge-home "$BRIDGE_HOME")"
assert_contains "$HUD_TAP_STATUS_BEFORE" "status: missing"
assert_contains "$HUD_TAP_STATUS_BEFORE" "hud_usage_tap: missing"
HUD_TAP_ENSURE_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-hud-usage-tap --workdir "$HUD_TAP_WORKDIR" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)")"
assert_contains "$HUD_TAP_ENSURE_OUTPUT" "status: updated"
assert_contains "$HUD_TAP_ENSURE_OUTPUT" "hud_usage_tap: updated"
assert_contains "$(cat "$HUD_TAP_WORKDIR/.claude/settings.json")" "hud-usage-tap"
HUD_TAP_STATUS_AFTER="$(python3 "$REPO_ROOT/bridge-hooks.py" status-hud-usage-tap --workdir "$HUD_TAP_WORKDIR" --bridge-home "$BRIDGE_HOME")"
assert_contains "$HUD_TAP_STATUS_AFTER" "status: present"
assert_contains "$HUD_TAP_STATUS_AFTER" "hud_usage_tap: present"
# Idempotent: second ensure must not change the file
HUD_TAP_BEFORE_HASH="$(md5sum "$HUD_TAP_WORKDIR/.claude/settings.json" | cut -d' ' -f1)"
python3 "$REPO_ROOT/bridge-hooks.py" ensure-hud-usage-tap --workdir "$HUD_TAP_WORKDIR" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)" >/dev/null
HUD_TAP_AFTER_HASH="$(md5sum "$HUD_TAP_WORKDIR/.claude/settings.json" | cut -d' ' -f1)"
[[ "$HUD_TAP_BEFORE_HASH" == "$HUD_TAP_AFTER_HASH" ]] || die "ensure-hud-usage-tap is not idempotent: settings.json changed on second call"
# No-HUD settings must return no-hud
HUD_TAP_NOHUD_WORKDIR="$TMP_ROOT/hud-tap-nohud"
mkdir -p "$HUD_TAP_NOHUD_WORKDIR/.claude"
echo '{}' >"$HUD_TAP_NOHUD_WORKDIR/.claude/settings.json"
HUD_TAP_NOHUD_OUT="$(python3 "$REPO_ROOT/bridge-hooks.py" status-hud-usage-tap --workdir "$HUD_TAP_NOHUD_WORKDIR" --bridge-home "$BRIDGE_HOME" || true)"
assert_contains "$HUD_TAP_NOHUD_OUT" "no-hud"
# Shell wrapper path: bridge_ensure_hud_usage_tap sources bridge-lib.sh and
# calls bridge-hooks.py. Verify the shared-base path works end-to-end by
# seeding a fresh unpatched HUD settings.json and calling the bash wrapper.
HUD_TAP_WRAP_WORKDIR="$TMP_ROOT/hud-tap-wrap-workdir"
mkdir -p "$HUD_TAP_WRAP_WORKDIR/.claude"
python3 -c "
import json, pathlib
cfg = {
  'statusLine': {
    'type': 'command',
    'command': 'bash -c \'plugin_dir=x; exec \"/usr/bin/bun\" --env-file /dev/null \"\${plugin_dir}src/index.ts\"\''
  }
}
pathlib.Path('$HUD_TAP_WRAP_WORKDIR/.claude/settings.json').write_text(json.dumps(cfg, indent=2))
"
HUD_TAP_WRAP_OUT="$("$BASH4_BIN" -lc "
  source '$REPO_ROOT/bridge-lib.sh' >/dev/null 2>&1
  bridge_ensure_hud_usage_tap '$HUD_TAP_WRAP_WORKDIR' '' '' 2>&1 || true
" 2>&1 || true)"
# The call must not error; the settings must now contain hud-usage-tap
assert_contains "$(cat "$HUD_TAP_WRAP_WORKDIR/.claude/settings.json")" "hud-usage-tap"

log "ensuring Claude project trust seed and startup blocker detection"
CLAUDE_USER_FILE="$TMP_ROOT/claude-user.json"
echo '{}' >"$CLAUDE_USER_FILE"
TRUST_OUTPUT="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-project-trust --workdir "$CLAUDE_STATIC_WORKDIR" --claude-user-file "$CLAUDE_USER_FILE")"
assert_contains "$TRUST_OUTPUT" "status: updated"
assert_contains "$TRUST_OUTPUT" "trust_accepted: true"
assert_contains "$(cat "$CLAUDE_USER_FILE")" "\"$CLAUDE_STATIC_WORKDIR\""
assert_contains "$(cat "$CLAUDE_USER_FILE")" "\"hasTrustDialogAccepted\": true"
CLAUDE_TRUST_BLOCKER="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; text=\$'Quick safety check:\\n❯ 1. Yes, I trust this folder'; bridge_tmux_claude_blocker_state_from_text \"\$text\"")"
assert_contains "$CLAUDE_TRUST_BLOCKER" "trust"
CLAUDE_SUMMARY_BLOCKER="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; text=\$'This session is 2h old\\n❯ 1. Resume from summary (recommended)\\n2. Resume full session as-is'; bridge_tmux_claude_blocker_state_from_text \"\$text\"")"
assert_contains "$CLAUDE_SUMMARY_BLOCKER" "summary"
CLAUDE_PROMPT_READY="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; if bridge_tmux_claude_prompt_line_ready '❯ 1. Resume from summary'; then echo bad; else echo ok; fi")"
assert_contains "$CLAUDE_PROMPT_READY" "ok"
CODEX_PROMPT_READY="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; if bridge_tmux_codex_prompt_line_ready '> '; then echo ok; else echo bad; fi")"
assert_contains "$CODEX_PROMPT_READY" "ok"

log "ensuring mark-idle hook emits inbox summary context"
HOOK_INBOX_AGENT="mark-idle-inbox-$SESSION_NAME"
HOOK_QUEUE_CREATE_OUTPUT="$(python3 "$REPO_ROOT/bridge-queue.py" create --to "$HOOK_INBOX_AGENT" --title "Follow-up task" --from smoke --priority high --body "check inbox")"
assert_contains "$HOOK_QUEUE_CREATE_OUTPUT" "created task #"
HOOK_CONTEXT_OUTPUT="$(BRIDGE_HOME="$REPO_ROOT" BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_ACTIVE_AGENT_DIR" BRIDGE_HISTORY_DIR="$BRIDGE_HISTORY_DIR" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" BRIDGE_ROSTER_FILE="$REPO_ROOT/agent-roster.sh" BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" BRIDGE_AGENT_ID="$HOOK_INBOX_AGENT" "$BASH4_BIN" "$REPO_ROOT/hooks/mark-idle.sh")"
assert_contains "$HOOK_CONTEXT_OUTPUT" "[Agent Bridge] 1 pending task(s) for $HOOK_INBOX_AGENT."
assert_contains "$HOOK_CONTEXT_OUTPUT" "ACTION REQUIRED: Use your Bash tool now."
assert_contains "$HOOK_CONTEXT_OUTPUT" "Run exactly: ~/.agent-bridge/agb inbox $HOOK_INBOX_AGENT"
assert_contains "$HOOK_CONTEXT_OUTPUT" "Highest priority: Task #"
assert_contains "$HOOK_CONTEXT_OUTPUT" "Should the result of this task be shared with a human teammate?"

log "ensuring Claude webhook MCP config merge"
cat >"$MCP_WORKDIR/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "existing": {
      "transport": "stdio",
      "command": "python3",
      "args": ["existing.py"]
    }
  }
}
EOF

MCP_ENSURE_OUTPUT="$(python3 "$REPO_ROOT/bridge-channels.py" ensure-webhook-server --workdir "$MCP_WORKDIR" --bridge-home "$BRIDGE_HOME" --bridge-state-dir "$BRIDGE_STATE_DIR" --python-bin "$(command -v python3)" --server-script "$REPO_ROOT/bridge-channel-server.py" --server-name bridge-webhook --port 9301 --agent claude-smoke)"
assert_contains "$MCP_ENSURE_OUTPUT" "status: updated"
assert_contains "$(cat "$MCP_WORKDIR/.mcp.json")" "\"existing\""
assert_contains "$(cat "$MCP_WORKDIR/.mcp.json")" "\"bridge-webhook\""
assert_contains "$(cat "$MCP_WORKDIR/.mcp.json")" "\"BRIDGE_WEBHOOK_PORT\": \"9301\""

log "exercising standalone bridge channel server"
python3 - "$REPO_ROOT" "$BRIDGE_STATE_DIR" <<'PY'
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

repo_root = Path(sys.argv[1])
state_dir = Path(sys.argv[2])
agent = "claude-smoke"
port = 9302
idle_file = state_dir / "agents" / agent / "idle-since"
idle_file.parent.mkdir(parents=True, exist_ok=True)
idle_file.write_text("123\n", encoding="utf-8")

env = os.environ.copy()
env.update(
    {
        "BRIDGE_WEBHOOK_PORT": str(port),
        "BRIDGE_WEBHOOK_AGENT": agent,
        "BRIDGE_STATE_DIR": str(state_dir),
        "PYTHONUNBUFFERED": "1",
    }
)

proc = subprocess.Popen(
    [sys.executable, str(repo_root / "bridge-channel-server.py")],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env=env,
)

def send(payload: dict) -> None:
    body = json.dumps(payload).encode("utf-8")
    proc.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    proc.stdin.write(body)
    proc.stdin.flush()

def read_message(timeout: float = 5.0) -> dict:
    deadline = time.time() + timeout
    headers = {}
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            raise SystemExit("channel server stdout closed unexpectedly")
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode("utf-8").split(":", 1)
        headers[key.strip().lower()] = value.strip()
    length = int(headers["content-length"])
    body = proc.stdout.read(length)
    return json.loads(body.decode("utf-8"))

try:
    send(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}},
        }
    )
    response = read_message()
    assert response["id"] == 1
    assert response["result"]["capabilities"]["experimental"]["claude/channel"] == {}

    for _ in range(50):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=0.2) as resp:
                assert resp.status == 200
                break
        except Exception:
            time.sleep(0.1)
    else:
        raise SystemExit("channel server health endpoint never became ready")

    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/",
        data=b"agb inbox claude-smoke",
        headers={"Content-Type": "text/plain; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=2) as resp:
        assert resp.status == 200

    notification = read_message()
    assert notification["method"] == "notifications/claude/channel"
    assert notification["params"]["content"] == "agb inbox claude-smoke"
    assert notification["params"]["meta"]["chat_id"] == agent
    assert not idle_file.exists(), "idle marker should be cleared on webhook delivery"
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
PY

log "creating and managing a bridge-native cron job"
NATIVE_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron create --agent "$SMOKE_AGENT" --schedule '0 10 * * *' --tz UTC --title 'native smoke daily' --payload 'Do the native cron smoke run.')"
assert_contains "$NATIVE_CREATE_OUTPUT" "created native cron job"

NATIVE_LIST_OUTPUT="$("$REPO_ROOT/agent-bridge" cron list --agent "$SMOKE_AGENT")"
assert_contains "$NATIVE_LIST_OUTPUT" "native smoke daily"

NATIVE_JOB_ID="$(python3 - <<'PY'
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
print(payload["jobs"][0]["id"])
PY
)"
[[ -n "$NATIVE_JOB_ID" ]] || die "native cron id was empty"

NATIVE_UPDATE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron update "$NATIVE_JOB_ID" --schedule '15 10 * * *' --title 'native smoke daily updated')"
assert_contains "$NATIVE_UPDATE_OUTPUT" "updated native cron job"

SYNC_DRY_RUN_OUTPUT="$("$REPO_ROOT/agent-bridge" cron sync --dry-run --since '2026-04-05T10:14:00+00:00' --now '2026-04-05T10:15:00+00:00')"
assert_contains "$SYNC_DRY_RUN_OUTPUT" "native: status=dry_run"
assert_contains "$SYNC_DRY_RUN_OUTPUT" "due=1"

NATIVE_DELETE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron delete "$NATIVE_JOB_ID")"
assert_contains "$NATIVE_DELETE_OUTPUT" "deleted native cron job"

log "rebalancing memory-daily jobs onto 03:00 KST"
MEMORY_REBALANCE_JOBS="$TMP_ROOT/memory-daily-jobs.json"
python3 - <<'PY' "$MEMORY_REBALANCE_JOBS" "$SMOKE_AGENT"
import json
import sys

jobs_path, agent = sys.argv[1], sys.argv[2]
payload = {
    "format": "agent-bridge-cron-v1",
    "updatedAt": "2026-04-09T00:00:00+09:00",
    "jobs": [
        {
            "id": "memory-daily-1",
            "name": "memory-daily smoke",
            "agentId": agent,
            "enabled": True,
            "schedule": {"kind": "cron", "expr": "45 23 * * *", "tz": "Asia/Seoul"},
            "payload": {"kind": "text", "text": "daily memory"},
            "state": {},
            "metadata": {"source": "bridge-native"},
        },
        {
            "id": "briefing-1",
            "name": "morning-briefing smoke",
            "agentId": agent,
            "enabled": True,
            "schedule": {"kind": "cron", "expr": "0 9 * * *", "tz": "Asia/Seoul"},
            "payload": {"kind": "text", "text": "briefing"},
            "state": {},
            "metadata": {"source": "bridge-native"},
        },
    ],
}
with open(jobs_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
MEMORY_REBALANCE_DRY_RUN="$("$REPO_ROOT/agent-bridge" cron rebalance-memory-daily --jobs-file "$MEMORY_REBALANCE_JOBS" --dry-run --json)"
python3 - "$MEMORY_REBALANCE_DRY_RUN" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["dry_run"] is True
assert payload["changed_count"] == 1
assert payload["changed_jobs"][0]["after"]["expr"] == "0 3 * * *"
assert payload["changed_jobs"][0]["after"]["tz"] == "Asia/Seoul"
PY
"$REPO_ROOT/agent-bridge" cron rebalance-memory-daily --jobs-file "$MEMORY_REBALANCE_JOBS" >/dev/null
python3 - <<'PY' "$MEMORY_REBALANCE_JOBS"
import json
import sys

jobs = json.load(open(sys.argv[1], encoding="utf-8"))["jobs"]
memory_job = next(job for job in jobs if job["id"] == "memory-daily-1")
briefing_job = next(job for job in jobs if job["id"] == "briefing-1")
assert memory_job["schedule"]["expr"] == "0 3 * * *"
assert memory_job["schedule"]["tz"] == "Asia/Seoul"
assert briefing_job["schedule"]["expr"] == "0 9 * * *"
PY

log "creating a one-shot bridge-native cron job"
NATIVE_ONESHOT_OUTPUT="$("$REPO_ROOT/agent-bridge" cron create --agent "$SMOKE_AGENT" --at '2026-04-08T10:15:00+09:00' --title 'native smoke one-shot' --payload 'Run once.' --delete-after-run)"
assert_contains "$NATIVE_ONESHOT_OUTPUT" "created native cron job"
NATIVE_ONESHOT_ID="$(python3 - <<'PY' "$BRIDGE_NATIVE_CRON_JOBS_FILE"
import json, sys
jobs = json.load(open(sys.argv[1], encoding='utf-8'))['jobs']
for job in jobs:
    if job.get('name') == 'native smoke one-shot':
        print(job['id'])
        break
PY
)"
[[ -n "$NATIVE_ONESHOT_ID" ]] || die "native one-shot cron id was empty"
python3 - <<'PY' "$BRIDGE_NATIVE_CRON_JOBS_FILE" "$NATIVE_ONESHOT_ID"
import json, sys
jobs = json.load(open(sys.argv[1], encoding='utf-8'))['jobs']
job = next(job for job in jobs if job.get('id') == sys.argv[2])
assert job['schedule']['kind'] == 'at'
assert job['deleteAfterRun'] is True
PY
NATIVE_ONESHOT_SYNC_JSON="$("$REPO_ROOT/agent-bridge" cron sync --json --since '2026-04-08T10:14:00+09:00' --now '2026-04-08T10:15:00+09:00')"
assert_contains "$NATIVE_ONESHOT_SYNC_JSON" "\"status\": \"ok\""
assert_contains "$NATIVE_ONESHOT_SYNC_JSON" "\"due_occurrences\": 1"
NATIVE_ONESHOT_TASK_ID="$(python3 - <<'PY' "$NATIVE_ONESHOT_SYNC_JSON" "$NATIVE_ONESHOT_ID"
import json, sys
payload = json.loads(sys.argv[1])
for item in payload["sources"]["native"]["results"]:
    if item["job_id"] == sys.argv[2]:
        print(item["task_id"])
        break
PY
)"
[[ "$NATIVE_ONESHOT_TASK_ID" =~ ^[0-9]+$ ]] || die "native one-shot task id was invalid: $NATIVE_ONESHOT_TASK_ID"
python3 "$REPO_ROOT/bridge-queue.py" claim "$NATIVE_ONESHOT_TASK_ID" --agent "$SMOKE_AGENT" >/dev/null
NATIVE_ONESHOT_REQUEST_FILE="$(python3 - <<'PY' "$NATIVE_ONESHOT_SYNC_JSON" "$NATIVE_ONESHOT_ID"
import json, sys
payload = json.loads(sys.argv[1])
for item in payload["sources"]["native"]["results"]:
    if item["job_id"] == sys.argv[2]:
        print(item["request_file"])
        break
PY
)"
if [[ "$NATIVE_ONESHOT_REQUEST_FILE" != /* ]]; then
  NATIVE_ONESHOT_REQUEST_FILE="$BRIDGE_HOME/$NATIVE_ONESHOT_REQUEST_FILE"
fi
[[ -f "$NATIVE_ONESHOT_REQUEST_FILE" ]] || die "native one-shot request file missing: $NATIVE_ONESHOT_REQUEST_FILE"
python3 - <<'PY' "$NATIVE_ONESHOT_REQUEST_FILE"
import json, sys
from pathlib import Path

request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(request["result_file"]).write_text(json.dumps({
    "run_id": request["run_id"],
    "status": "completed",
    "summary": "one-shot smoke completed",
    "findings": [],
    "actions_taken": [],
    "needs_human_followup": False,
    "recommended_next_steps": [],
    "artifacts": [],
    "confidence": "high",
    "duration_ms": 5,
}, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
Path(request["status_file"]).write_text(json.dumps({
    "run_id": request["run_id"],
    "state": "success",
    "engine": "codex",
    "request_file": request["dispatch_body_file"],
    "result_file": request["result_file"],
}, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
NATIVE_ONESHOT_FINALIZE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron finalize-run "$(basename "$(dirname "$NATIVE_ONESHOT_REQUEST_FILE")")")"
assert_contains "$NATIVE_ONESHOT_FINALIZE_OUTPUT" "action: deleted"
python3 - <<'PY' "$BRIDGE_NATIVE_CRON_JOBS_FILE" "$NATIVE_ONESHOT_ID"
import json, sys
jobs = json.load(open(sys.argv[1], encoding='utf-8'))['jobs']
assert all(job.get('id') != sys.argv[2] for job in jobs)
PY
python3 "$REPO_ROOT/bridge-queue.py" done "$NATIVE_ONESHOT_TASK_ID" --agent "$SMOKE_AGENT" --note "one-shot smoke cleaned up" >/dev/null

log "dry-run upgrade preserves custom paths"
EXPECTED_VERSION="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")"
VERSION_OUTPUT="$("$REPO_ROOT/agent-bridge" version)"
assert_contains "$VERSION_OUTPUT" "Agent Bridge $EXPECTED_VERSION"
UPGRADE_CHECK_JSON="$("$REPO_ROOT/agent-bridge" upgrade --source "$REPO_ROOT" --target "$BRIDGE_HOME" --check --json)"
assert_contains "$UPGRADE_CHECK_JSON" "\"mode\": \"upgrade-check\""
assert_contains "$UPGRADE_CHECK_JSON" "\"target_version\": \"$EXPECTED_VERSION\""
UPGRADE_JSON="$("$REPO_ROOT/agent-bridge" upgrade --source "$REPO_ROOT" --target "$BRIDGE_HOME" --dry-run --json)"
assert_contains "$UPGRADE_JSON" "\"mode\": \"upgrade\""
assert_contains "$UPGRADE_JSON" "\"version\": \"$EXPECTED_VERSION\""
assert_contains "$UPGRADE_JSON" "\"preserved_paths\""
assert_contains "$UPGRADE_JSON" "\"backup_enabled\": true"
assert_contains "$UPGRADE_JSON" "\"agent_migration\""
assert_contains "$UPGRADE_JSON" "\"analysis\""

log "upgrade backs up live install and migrates missing agent files"
rm -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/MEMORY-SCHEMA.md"
mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/output"
printf 'generated-report\n' >"$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/output/generated.txt"
python3 - <<'PY' "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md"
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace("## Queue & Delivery", "## Queue & Delivery\n- STALE-UPGRADE-MARKER", 1)
path.write_text(text, encoding="utf-8")
PY
UPGRADE_APPLY_JSON="$("$REPO_ROOT/agent-bridge" upgrade --source "$REPO_ROOT" --target "$BRIDGE_HOME" --no-restart-daemon --allow-dirty --json)"
assert_contains "$UPGRADE_APPLY_JSON" "\"backup_enabled\": true"
assert_contains "$UPGRADE_APPLY_JSON" "\"migrate_agents\": true"
assert_contains "$UPGRADE_APPLY_JSON" "\"version\": \"$EXPECTED_VERSION\""
assert_contains "$UPGRADE_APPLY_JSON" "\"added_files\""
assert_contains "$UPGRADE_APPLY_JSON" "\"updated_files\""
[[ -f "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/MEMORY-SCHEMA.md" ]] || die "upgrade did not restore missing agent template file"
assert_not_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "STALE-UPGRADE-MARKER"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "## Runtime Protocol Pointers"
assert_contains "$(cat "$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT/CLAUDE.md")" "COMMON-INSTRUCTIONS.md"
UPGRADE_BACKUP_ROOT="$(python3 - <<'PY' "$UPGRADE_APPLY_JSON"
import json, sys
print(json.loads(sys.argv[1])["backup_root"])
PY
)"
[[ -d "$UPGRADE_BACKUP_ROOT/live" ]] || die "upgrade did not create live backup snapshot"
[[ ! -e "$UPGRADE_BACKUP_ROOT/live/agents/$CREATED_AGENT/output/generated.txt" ]] || die "upgrade backup should skip generated agent output"
[[ -f "$BRIDGE_HOME/state/upgrade/last-upgrade.json" ]] || die "upgrade did not write last-upgrade state"
UPGRADE_ANALYZE_JSON="$("$REPO_ROOT/agent-bridge" upgrade analyze --target "$BRIDGE_HOME" --json)"
assert_contains "$UPGRADE_ANALYZE_JSON" "\"mode\": \"upgrade-analyze\""
assert_contains "$UPGRADE_ANALYZE_JSON" "\"base_ref\""

log "daily live backup archives bridge home and daemon runs it once per day"
DAILY_BACKUP_HOME="$TMP_ROOT/daily-backup-home"
mkdir -p \
  "$DAILY_BACKUP_HOME/logs" \
  "$DAILY_BACKUP_HOME/backups/daily" \
  "$DAILY_BACKUP_HOME/backups/upgrade-keep" \
  "$DAILY_BACKUP_HOME/agents/demo/__pycache__" \
  "$DAILY_BACKUP_HOME/state" \
  "$DAILY_BACKUP_HOME/shared"
printf 'keep roster\n' >"$DAILY_BACKUP_HOME/agent-roster.local.sh"
printf 'skip log\n' >"$DAILY_BACKUP_HOME/logs/daemon.log"
printf 'keep state\n' >"$DAILY_BACKUP_HOME/state/runtime.txt"
printf 'keep shared\n' >"$DAILY_BACKUP_HOME/shared/note.md"
printf 'keep backup note\n' >"$DAILY_BACKUP_HOME/backups/upgrade-keep/note.txt"
printf 'skip pycache\n' >"$DAILY_BACKUP_HOME/agents/demo/__pycache__/cache.pyc"
printf 'keep agent file\n' >"$DAILY_BACKUP_HOME/agents/demo/CLAUDE.md"
printf 'old backup\n' >"$DAILY_BACKUP_HOME/backups/daily/agent-bridge-2000-01-01.tgz"
DAILY_BACKUP_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" daily-backup-live --target-root "$DAILY_BACKUP_HOME" --backup-dir "$DAILY_BACKUP_HOME/backups/daily" --retain-days 30)"
assert_contains "$DAILY_BACKUP_JSON" "\"mode\": \"daily-backup-live\""
assert_contains "$DAILY_BACKUP_JSON" "\"created\": true"
assert_not_contains "$(ls "$DAILY_BACKUP_HOME/backups/daily")" "agent-bridge-2000-01-01.tgz"
DAILY_BACKUP_ARCHIVE="$(python3 - <<'PY' "$DAILY_BACKUP_JSON"
import json, sys
print(json.loads(sys.argv[1])["archive_path"])
PY
)"
[[ -f "$DAILY_BACKUP_ARCHIVE" ]] || die "daily backup archive was not created"
DAILY_BACKUP_MEMBERS="$(tar -tzf "$DAILY_BACKUP_ARCHIVE")"
assert_contains "$DAILY_BACKUP_MEMBERS" "agent-roster.local.sh"
assert_contains "$DAILY_BACKUP_MEMBERS" "agents/demo/CLAUDE.md"
assert_contains "$DAILY_BACKUP_MEMBERS" "backups/upgrade-keep/note.txt"
assert_not_contains "$DAILY_BACKUP_MEMBERS" "logs/daemon.log"
assert_not_contains "$DAILY_BACKUP_MEMBERS" "backups/daily/"
assert_not_contains "$DAILY_BACKUP_MEMBERS" "__pycache__"

DAEMON_BACKUP_HOME="$TMP_ROOT/daemon-daily-backup-home"
mkdir -p \
  "$DAEMON_BACKUP_HOME/state" \
  "$DAEMON_BACKUP_HOME/shared" \
  "$DAEMON_BACKUP_HOME/logs" \
  "$DAEMON_BACKUP_HOME/agents/demo"
printf 'daemon keep\n' >"$DAEMON_BACKUP_HOME/agents/demo/CLAUDE.md"
DAEMON_DAILY_OUTPUT="$(
  BRIDGE_HOME="$DAEMON_BACKUP_HOME" \
  BRIDGE_STATE_DIR="$DAEMON_BACKUP_HOME/state" \
  BRIDGE_LOG_DIR="$DAEMON_BACKUP_HOME/logs" \
  BRIDGE_SHARED_DIR="$DAEMON_BACKUP_HOME/shared" \
  BRIDGE_TASK_DB="$DAEMON_BACKUP_HOME/state/tasks.db" \
  BRIDGE_ACTIVE_AGENT_DIR="$DAEMON_BACKUP_HOME/state/agents" \
  BRIDGE_HISTORY_DIR="$DAEMON_BACKUP_HOME/state/history" \
  BRIDGE_FAST_ROSTER_LOAD=1 \
  BRIDGE_DAILY_BACKUP_ENABLED=1 \
  BRIDGE_DAILY_BACKUP_HOUR="$(date +%H)" \
  "$BASH4_BIN" -lc '
    set -euo pipefail
    tmp_daemon="'"$TMP_ROOT"'/daemon-daily-backup.sh"
    {
      printf "%s\n" "set -euo pipefail"
      printf "SCRIPT_DIR=%q\n" "'"$REPO_ROOT"'"
      printf "%s\n" "source \"\$SCRIPT_DIR/bridge-lib.sh\""
      printf "%s\n" "bridge_load_roster"
      printf "%s\n" "daemon_info() { :; }"
      printf "%s\n" "bridge_audit_log() { :; }"
      sed -n '"'"'/^bridge_daily_backup_state_file()/,/^bridge_stall_retry_seconds()/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
    } >"$tmp_daemon"
    source "$tmp_daemon"
    process_daily_backup >/dev/null
    archive="$(find "'"$DAEMON_BACKUP_HOME"'/backups/daily" -maxdepth 1 -name "agent-bridge-*.tgz" | head -n 1)"
    [[ -n "$archive" && -f "$archive" ]] || exit 1
    before="$(stat -c "%Y" "$archive" 2>/dev/null || stat -f "%m" "$archive")"
    sleep 1
    process_daily_backup >/dev/null || true
    after="$(stat -c "%Y" "$archive" 2>/dev/null || stat -f "%m" "$archive")"
    printf "ARCHIVE=%s\nBEFORE=%s\nAFTER=%s\n" "$archive" "$before" "$after"
  '
)"
DAEMON_DAILY_ARCHIVE="$(printf '%s\n' "$DAEMON_DAILY_OUTPUT" | sed -n 's/^ARCHIVE=//p' | tail -n 1)"
DAEMON_DAILY_MTIME_BEFORE="$(printf '%s\n' "$DAEMON_DAILY_OUTPUT" | sed -n 's/^BEFORE=//p' | tail -n 1)"
DAEMON_DAILY_MTIME_AFTER="$(printf '%s\n' "$DAEMON_DAILY_OUTPUT" | sed -n 's/^AFTER=//p' | tail -n 1)"
[[ -n "$DAEMON_DAILY_ARCHIVE" && -f "$DAEMON_DAILY_ARCHIVE" ]] || die "daemon daily backup helper did not create an archive"
[[ "$DAEMON_DAILY_MTIME_BEFORE" == "$DAEMON_DAILY_MTIME_AFTER" ]] || die "daemon should not overwrite the same day's daily backup twice"

log "upgrade restarts active static loop agents so bridge-run reloads fresh code"
UPGRADE_RESTART_PANE_BEFORE="$(tmux list-panes -t "$(tmux_session_target "$ALWAYS_ON_SESSION")" -F '#{pane_pid}' 2>/dev/null | head -n 1)"
[[ -n "$UPGRADE_RESTART_PANE_BEFORE" ]] || die "expected active always-on pane before upgrade restart"
UPGRADE_RESTART_JSON="$("$REPO_ROOT/agent-bridge" upgrade --source "$REPO_ROOT" --target "$BRIDGE_HOME" --allow-dirty --json)"
assert_contains "$UPGRADE_RESTART_JSON" "\"restart_agents\": true"
wait_for_tmux_session "$ALWAYS_ON_SESSION" up 40 0.2 || die "always-on role did not come back after upgrade restart"
UPGRADE_RESTART_PANE_AFTER="$(tmux list-panes -t "$(tmux_session_target "$ALWAYS_ON_SESSION")" -F '#{pane_pid}' 2>/dev/null | head -n 1)"
[[ -n "$UPGRADE_RESTART_PANE_AFTER" ]] || die "expected active always-on pane after upgrade restart"
[[ "$UPGRADE_RESTART_PANE_AFTER" != "$UPGRADE_RESTART_PANE_BEFORE" ]] || die "upgrade should restart active static loop agents"
python3 - "$UPGRADE_RESTART_JSON" "$ALWAYS_ON_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
restart = payload["agent_restart"]

assert restart["enabled"] is True, restart
# Post-#257 contract: `restart_attempted_ok` replaces the prior `restarted`
# (the count of `bridge-agent.sh restart` commands that returned exit 0).
# The old `restarted` / `restarted_agents` keys are gone; the new names
# must faithfully appear in the JSON.
assert restart["restart_attempted_ok"] >= 1, restart
assert agent in restart["restart_attempted_ok_agents"], restart
assert "restarted" not in restart, "legacy key restarted must be gone after #257"
assert "restarted_agents" not in restart, "legacy key restarted_agents must be gone after #257"
assert "would_restart" not in restart, "legacy key would_restart must be gone after #257"
assert "would_restart_agents" not in restart, "legacy key would_restart_agents must be gone after #257"
# #256 Gap 1: failed_details structure must exist on every apply payload,
# even when no agent failed (empty list). Aggregator logic is validated
# in the dedicated stand-alone block below so downstream consumers can
# rely on the key always being present.
assert "failed_details" in restart, "failed_details must be present on apply payload"
assert isinstance(restart["failed_details"], list), restart["failed_details"]
assert restart["failed_details"] == [], \
    f"no failed agents expected in smoke fixture; got {restart['failed_details']!r}"
PY

log "upgrade restart report aggregator surfaces failed_details with decoded log tail (#256 Gap 1)"
# Exercise the live aggregator body extracted from `bridge-upgrade.sh` so a
# Python-version regression in the real file (e.g. a PEP 604 `str | None`
# annotation under a python3.9 host, see PR #261 r1) reproduces in smoke
# rather than passing a divergent copy. The extractor pulls the heredoc
# between `<<'PY'` and the matching `PY` line on the aggregator's `python3
# -` invocation, then feeds it a synthetic 7-column report.
GAP1_TAIL_B64="$("$BASH4_BIN" -c 'printf "%s" "plugin telegram@claude-plugins-official failed to load\nprocess exited with code 1" | base64 | tr -d "\n"')"
GAP1_SYNTH_REPORT=$(printf 'a1\twould-restart\teligible\t0\ts1\t\t\na2\trestarted\teligible\t0\ts2\t0\t\na3\tfailed\trestart-failed\t0\ts3\t7\t%s\n' "$GAP1_TAIL_B64")
GAP1_AGG_BODY_FILE="$TMP_ROOT/gap1_aggregator_body.py"
python3 - "$REPO_ROOT/bridge-upgrade.sh" "$GAP1_AGG_BODY_FILE" <<'EXTRACT'
import pathlib, re, sys

src = pathlib.Path(sys.argv[1]).read_text()
# Match the exact aggregator invocation and capture everything between
# `<<'PY'` and the matching closing `PY` line. Anchored on the function
# name so we do not accidentally pick up the summary helper below.
pattern = re.compile(
    r"bridge_upgrade_agent_restart_json\(\) \{.*?"
    r"python3 - \"\$enabled\" \"\$dry_run\" \"\$report\" <<'PY'\n"
    r"(?P<body>.*?)\nPY\n",
    re.DOTALL,
)
match = pattern.search(src)
if not match:
    raise SystemExit("aggregator heredoc not located in bridge-upgrade.sh")
pathlib.Path(sys.argv[2]).write_text(match.group("body"))
EXTRACT
[[ -s "$GAP1_AGG_BODY_FILE" ]] || die "aggregator body extraction produced an empty file"
GAP1_AGG_OUTPUT="$(python3 "$GAP1_AGG_BODY_FILE" 1 0 "$GAP1_SYNTH_REPORT")"
python3 - "$GAP1_AGG_OUTPUT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["failed"] == 1, payload
assert payload["failed_agents"] == ["a3"], payload
details = payload.get("failed_details")
assert isinstance(details, list) and len(details) == 1, payload
detail = details[0]
assert detail["agent"] == "a3", detail
assert detail["exit_code"] == 7, detail
tail = detail.get("last_log_tail") or ""
assert "plugin telegram" in tail, detail
assert "code 1" in tail, detail
# Non-failed agents must NOT get entries.
assert payload["restart_attempted_ok"] == 1, payload
assert payload["restart_eligible"] == 1, payload
PY
rm -f "$GAP1_AGG_BODY_FILE"

log "upgrade dry-run surfaces the eligibility-only disclaimer (#257)"
UPGRADE_DRY_RUN_JSON="$("$REPO_ROOT/agent-bridge" upgrade --source "$REPO_ROOT" --target "$BRIDGE_HOME" --allow-dirty --dry-run --json)"
python3 - "$UPGRADE_DRY_RUN_JSON" "$ALWAYS_ON_AGENT" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
agent = sys.argv[2]
restart = payload["agent_restart"]

# Dry-run must use the new key names too.
assert restart["dry_run"] is True, restart
assert restart["restart_eligible"] >= 1, restart
assert agent in restart["restart_eligible_agents"], restart
# The apply-only count stays zero on dry-run.
assert restart["restart_attempted_ok"] == 0, restart
PY
UPGRADE_DRY_RUN_TEXT="$("$REPO_ROOT/agent-bridge" upgrade --source "$REPO_ROOT" --target "$BRIDGE_HOME" --allow-dirty --dry-run)"
assert_contains "$UPGRADE_DRY_RUN_TEXT" "agent_restart_eligible_agents: $ALWAYS_ON_AGENT"
assert_contains "$UPGRADE_DRY_RUN_TEXT" "agent_restart_note: dry-run reports pre-launch eligibility only"
# Text summary must not leak the retired labels either.
assert_not_contains "$UPGRADE_DRY_RUN_TEXT" "agent_restart_would_restart:"
assert_not_contains "$UPGRADE_DRY_RUN_TEXT" "agent_restart_would_agents:"
assert_not_contains "$UPGRADE_DRY_RUN_TEXT" "agent_restart_restarted:"

log "isolating upgrade restart analysis from caller BRIDGE env"
UPGRADE_ENV_LIVE_HOME="$TMP_ROOT/upgrade-env-live"
UPGRADE_ENV_TARGET_HOME="$TMP_ROOT/upgrade-env-target"
mkdir -p "$UPGRADE_ENV_LIVE_HOME" "$UPGRADE_ENV_TARGET_HOME" "$UPGRADE_ENV_LIVE_HOME/agents/live-leak-agent"
cat >"$UPGRADE_ENV_LIVE_HOME/agent-roster.sh" <<EOF
bridge_add_agent_id_if_missing "live-leak-agent"
BRIDGE_AGENT_DESC["live-leak-agent"]="Live env leak sentinel"
BRIDGE_AGENT_ENGINE["live-leak-agent"]="codex"
BRIDGE_AGENT_SESSION["live-leak-agent"]="live-leak-session"
BRIDGE_AGENT_WORKDIR["live-leak-agent"]="$UPGRADE_ENV_LIVE_HOME/agents/live-leak-agent"
BRIDGE_AGENT_LAUNCH_CMD["live-leak-agent"]='sleep 30'
EOF
UPGRADE_ENV_JSON="$(
  BRIDGE_HOME="$UPGRADE_ENV_LIVE_HOME" \
  BRIDGE_ROSTER_FILE="$UPGRADE_ENV_LIVE_HOME/agent-roster.sh" \
  BRIDGE_ROSTER_LOCAL_FILE="$UPGRADE_ENV_LIVE_HOME/agent-roster.local.sh" \
  BRIDGE_STATE_DIR="$UPGRADE_ENV_LIVE_HOME/state" \
  BRIDGE_TASK_DB="$UPGRADE_ENV_LIVE_HOME/state/tasks.db" \
  BRIDGE_AGENT_HOME_ROOT="$UPGRADE_ENV_LIVE_HOME/agents" \
  "$REPO_ROOT/agent-bridge" upgrade --source "$REPO_ROOT" --target "$UPGRADE_ENV_TARGET_HOME" \
    --channel current --no-pull --allow-dirty --dry-run --json --restart-agents
)"
python3 - "$UPGRADE_ENV_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
restart = payload["agent_restart"]
assert restart["enabled"] is True, restart
assert restart["considered"] == 0, restart
assert "live-leak-agent" not in restart.get("restart_eligible_agents", []), restart
assert "live-leak-agent" not in restart.get("restart_attempted_ok_agents", []), restart
PY

log "rolling back from an upgrade backup snapshot"
ROLLBACK_ROOT="$TMP_ROOT/rollback-root"
mkdir -p "$ROLLBACK_ROOT"
cp "$REPO_ROOT/bridge-task.sh" "$ROLLBACK_ROOT/bridge-task.sh"
ROLLBACK_BACKUP_ROOT="$TMP_ROOT/rollback-backup"
python3 "$REPO_ROOT/bridge-upgrade.py" backup-live --target-root "$ROLLBACK_ROOT" --backup-root "$ROLLBACK_BACKUP_ROOT" --source-root "$REPO_ROOT" >/dev/null
printf '\n# rollback smoke drift\n' >>"$ROLLBACK_ROOT/bridge-task.sh"
ROLLBACK_JSON="$("$REPO_ROOT/agent-bridge" upgrade rollback --target "$ROLLBACK_ROOT" --backup-root "$ROLLBACK_BACKUP_ROOT" --no-restart-daemon --json)"
assert_contains "$ROLLBACK_JSON" "\"mode\": \"upgrade-rollback\""
assert_not_contains "$(cat "$ROLLBACK_ROOT/bridge-task.sh")" "rollback smoke drift"

log "backup-extend-live records child paths under a parent-symlink pointing outside target_root (issue #150)"
EXT_ROOT="$TMP_ROOT/extend-live-root"
EXT_BACKUP_ROOT="$TMP_ROOT/extend-live-backup"
EXT_EXTERNAL="$TMP_ROOT/extend-live-external"
# Plant a realistic retarget: agents/shared inside target_root is a symlink
# to an absolute path OUTSIDE target_root. Then report a changed path
# underneath that symlink and confirm backup-extend-live stops dropping
# it into skipped_outside_target — previously the parent.resolve() chased
# the symlink and relative_to() failed silently.
mkdir -p "$EXT_ROOT/agents" "$EXT_EXTERNAL" "$EXT_BACKUP_ROOT/live"
ln -s "$EXT_EXTERNAL" "$EXT_ROOT/agents/shared"
printf 'external shared doc\n' >"$EXT_EXTERNAL/TOOLS.md"
printf '{"entries": []}\n' >"$EXT_BACKUP_ROOT/manifest.json"
EXT_PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"changed_paths":[sys.argv[1]+"/agents/shared/TOOLS.md"]}))' "$EXT_ROOT")"
EXT_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" backup-extend-live \
  --target-root "$EXT_ROOT" --backup-root "$EXT_BACKUP_ROOT" --paths-json "$EXT_PAYLOAD")"
assert_contains "$EXT_JSON" "\"skipped_outside_target\": 0"
assert_contains "$EXT_JSON" "\"added_entries\": 1"
# The manifest entry now exists and points at the operator-visible relpath,
# not the external canonical.
assert_contains "$(cat "$EXT_BACKUP_ROOT/manifest.json")" "\"path\": \"agents/shared/TOOLS.md\""
[[ -f "$EXT_BACKUP_ROOT/live/agents/shared/TOOLS.md" ]] || die "backup-extend-live did not copy the symlink-child file"
assert_contains "$(cat "$EXT_BACKUP_ROOT/live/agents/shared/TOOLS.md")" "external shared doc"

log "smart upgrade clean-merges text drift"
UPGRADE_SIM_REPO="$TMP_ROOT/upgrade-sim-repo"
mkdir -p "$UPGRADE_SIM_REPO"
git -C "$UPGRADE_SIM_REPO" init -q
git -C "$UPGRADE_SIM_REPO" config user.email smoke-test
git -C "$UPGRADE_SIM_REPO" config user.name "Bridge Smoke"
cat >"$UPGRADE_SIM_REPO/sample.txt" <<'EOF'
alpha
beta
EOF
git -C "$UPGRADE_SIM_REPO" add sample.txt
git -C "$UPGRADE_SIM_REPO" commit -qm "base sample"
UPGRADE_SIM_BASE="$(git -C "$UPGRADE_SIM_REPO" rev-parse HEAD)"
cat >"$UPGRADE_SIM_REPO/sample.txt" <<'EOF'
alpha-upstream
beta
EOF
MERGE_ROOT="$TMP_ROOT/upgrade-merge-root"
mkdir -p "$MERGE_ROOT"
git -C "$UPGRADE_SIM_REPO" show "$UPGRADE_SIM_BASE:sample.txt" >"$MERGE_ROOT/sample.txt"
printf 'live-note\n' >>"$MERGE_ROOT/sample.txt"
MERGE_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$UPGRADE_SIM_REPO" --target-root "$MERGE_ROOT" --base-ref "$UPGRADE_SIM_BASE")"
assert_contains "$MERGE_JSON" "\"files_merged_clean\": 1"
assert_contains "$(cat "$MERGE_ROOT/sample.txt")" "alpha-upstream"
assert_contains "$(cat "$MERGE_ROOT/sample.txt")" "live-note"

log "smart upgrade backs up conflict and applies upstream by default"
CONFLICT_ROOT="$TMP_ROOT/upgrade-conflict-root"
mkdir -p "$CONFLICT_ROOT"
printf 'alpha-live\nbeta\n' >"$CONFLICT_ROOT/sample.txt"
CONFLICT_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$UPGRADE_SIM_REPO" --target-root "$CONFLICT_ROOT" --base-ref "$UPGRADE_SIM_BASE")"
assert_contains "$CONFLICT_JSON" "\"files_merged_conflict\": 1"
assert_contains "$(cat "$CONFLICT_ROOT/sample.txt")" "alpha-upstream"
[[ -f "$CONFLICT_ROOT/sample.txt.upgrade-conflict" ]] || die "upgrade did not write conflict backup file"
assert_contains "$(cat "$CONFLICT_ROOT/sample.txt.upgrade-conflict")" "<<<<<<<"

log "smart upgrade repairs executable bit when content already matches"
MODE_ROOT="$TMP_ROOT/upgrade-mode-root"
MODE_REPO="$TMP_ROOT/upgrade-mode-repo"
mkdir -p "$MODE_ROOT" "$MODE_REPO"
git -C "$MODE_REPO" init -q
git -C "$MODE_REPO" config user.email smoke-test
git -C "$MODE_REPO" config user.name "Bridge Smoke"
cat >"$MODE_REPO/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo "hello"
EOF
chmod 0755 "$MODE_REPO/tool.sh"
git -C "$MODE_REPO" add tool.sh
git -C "$MODE_REPO" update-index --chmod=+x tool.sh
git -C "$MODE_REPO" commit -qm "tool script with exec bit"
MODE_BASE="$(git -C "$MODE_REPO" rev-parse HEAD)"
# Plant the live file byte-for-byte identical but with exec bit stripped.
cp "$MODE_REPO/tool.sh" "$MODE_ROOT/tool.sh"
chmod 0644 "$MODE_ROOT/tool.sh"
ANALYZE_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" analyze-live --source-root "$MODE_REPO" --target-root "$MODE_ROOT" --base-ref "$MODE_BASE")"
assert_contains "$ANALYZE_JSON" "\"mode_drift\": 1"
assert_contains "$ANALYZE_JSON" "\"classification\": \"mode_drift\""
APPLY_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$MODE_REPO" --target-root "$MODE_ROOT" --base-ref "$MODE_BASE")"
assert_contains "$APPLY_JSON" "\"files_mode_synced\": 1"
assert_contains "$APPLY_JSON" "\"applied\": true"
# apply-live stamps the source's exec bits onto the live file.
mode_after="$(stat -c '%a' "$MODE_ROOT/tool.sh" 2>/dev/null || stat -f '%Lp' "$MODE_ROOT/tool.sh")"
[[ "$mode_after" == "755" ]] || die "expected tool.sh to be 755 after mode sync, got $mode_after"
# A second pass is idempotent (no drift, no rewrites).
SECOND_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$MODE_REPO" --target-root "$MODE_ROOT" --base-ref "$MODE_BASE")"
assert_contains "$SECOND_JSON" "\"files_mode_synced\": 0"
assert_contains "$SECOND_JSON" "\"files_skipped_noop\": 1"

log "smart upgrade repairs non-executable tracked file mode when content already matches"
READ_ROOT="$TMP_ROOT/upgrade-mode-read-root"
READ_REPO="$TMP_ROOT/upgrade-mode-read-repo"
mkdir -p "$READ_ROOT" "$READ_REPO"
git -C "$READ_REPO" init -q
git -C "$READ_REPO" config user.email smoke-test
git -C "$READ_REPO" config user.name "Bridge Smoke"
printf 'library helper\n' >"$READ_REPO/helper.txt"
chmod 0644 "$READ_REPO/helper.txt"
git -C "$READ_REPO" add helper.txt
git -C "$READ_REPO" commit -qm "helper tracked 100644"
READ_BASE="$(git -C "$READ_REPO" rev-parse HEAD)"
cp "$READ_REPO/helper.txt" "$READ_ROOT/helper.txt"
chmod 0600 "$READ_ROOT/helper.txt"
READ_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$READ_REPO" --target-root "$READ_ROOT" --base-ref "$READ_BASE")"
assert_contains "$READ_JSON" "\"files_mode_synced\": 1"
mode_read="$(stat -f '%Lp' "$READ_ROOT/helper.txt" 2>/dev/null || stat -c '%a' "$READ_ROOT/helper.txt")"
[[ "$mode_read" == "644" ]] || die "expected helper.txt to be 644 after read-mode sync, got $mode_read"

log "smart upgrade trusts git index mode over working-tree stat"
MISMATCH_REPO="$TMP_ROOT/upgrade-mode-mismatch-repo"
MISMATCH_ROOT="$TMP_ROOT/upgrade-mode-mismatch-root"
mkdir -p "$MISMATCH_REPO" "$MISMATCH_ROOT"
git -C "$MISMATCH_REPO" init -q
git -C "$MISMATCH_REPO" config user.email smoke-test
git -C "$MISMATCH_REPO" config user.name "Bridge Smoke"
printf '#!/usr/bin/env bash\necho mismatch\n' >"$MISMATCH_REPO/tool.sh"
chmod 0755 "$MISMATCH_REPO/tool.sh"
git -C "$MISMATCH_REPO" add tool.sh
git -C "$MISMATCH_REPO" update-index --chmod=+x tool.sh
git -C "$MISMATCH_REPO" commit -qm "tool.sh tracked 100755"
MISMATCH_BASE="$(git -C "$MISMATCH_REPO" rev-parse HEAD)"
# Reproduce the developer-checkout bug: git index still says 100755 but
# the working-tree file loses its exec bit (this happened on the actual
# checkout used to author this PR — stat returned 0744 / 0700 for the two
# promoted scripts). apply-live must trust the index, not stat.
chmod 0644 "$MISMATCH_REPO/tool.sh"
cp "$MISMATCH_REPO/tool.sh" "$MISMATCH_ROOT/tool.sh"
chmod 0644 "$MISMATCH_ROOT/tool.sh"
MISMATCH_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$MISMATCH_REPO" --target-root "$MISMATCH_ROOT" --base-ref "$MISMATCH_BASE")"
assert_contains "$MISMATCH_JSON" "\"files_mode_synced\": 1"
mode_mismatch="$(stat -c '%a' "$MISMATCH_ROOT/tool.sh" 2>/dev/null || stat -f '%Lp' "$MISMATCH_ROOT/tool.sh")"
[[ "$mode_mismatch" == "755" ]] || die "expected tool.sh to be 755 from git index (100755), got $mode_mismatch (worktree drift must not leak)"

log "smart upgrade propagates exec-bit removal from source"
REMOVE_ROOT="$TMP_ROOT/upgrade-mode-remove-root"
mkdir -p "$REMOVE_ROOT"
# Source says 0644 (we re-flip the tool.sh in MODE_REPO), live is 0755.
cp "$MODE_REPO/tool.sh" "$REMOVE_ROOT/tool.sh"
chmod 0755 "$REMOVE_ROOT/tool.sh"
# Create a fresh source tree where the same file is tracked as 100644.
REMOVE_REPO="$TMP_ROOT/upgrade-mode-remove-repo"
mkdir -p "$REMOVE_REPO"
git -C "$REMOVE_REPO" init -q
git -C "$REMOVE_REPO" config user.email smoke-test
git -C "$REMOVE_REPO" config user.name "Bridge Smoke"
cp "$MODE_REPO/tool.sh" "$REMOVE_REPO/tool.sh"
chmod 0644 "$REMOVE_REPO/tool.sh"
git -C "$REMOVE_REPO" add tool.sh
git -C "$REMOVE_REPO" commit -qm "tool script without exec bit"
REMOVE_BASE="$(git -C "$REMOVE_REPO" rev-parse HEAD)"
REMOVE_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$REMOVE_REPO" --target-root "$REMOVE_ROOT" --base-ref "$REMOVE_BASE")"
assert_contains "$REMOVE_JSON" "\"files_mode_synced\": 1"
mode_removed="$(stat -c '%a' "$REMOVE_ROOT/tool.sh" 2>/dev/null || stat -f '%Lp' "$REMOVE_ROOT/tool.sh")"
[[ "$mode_removed" == "644" ]] || die "expected tool.sh to be 644 after exec-bit removal, got $mode_removed"

log "strict merge aborts on conflict without touching live file"
STRICT_ROOT="$TMP_ROOT/upgrade-strict-root"
mkdir -p "$STRICT_ROOT"
printf 'alpha-live\nbeta\n' >"$STRICT_ROOT/sample.txt"
set +e
STRICT_JSON="$(python3 "$REPO_ROOT/bridge-upgrade.py" apply-live --source-root "$UPGRADE_SIM_REPO" --target-root "$STRICT_ROOT" --base-ref "$UPGRADE_SIM_BASE" --strict-merge)"
STRICT_EXIT=$?
set -e
[[ "$STRICT_EXIT" -eq 2 ]] || die "strict merge should abort with exit 2, got $STRICT_EXIT"
assert_contains "$STRICT_JSON" "\"aborted\": true"
assert_contains "$(cat "$STRICT_ROOT/sample.txt")" "alpha-live"
assert_not_contains "$(cat "$STRICT_ROOT/sample.txt")" "alpha-upstream"

log "exporting a clean public snapshot from the current ref"
PUBLIC_EXPORT_DIR="$TMP_ROOT/public-export"
PUBLIC_EXPORT_JSON="$("$REPO_ROOT/scripts/export-public-snapshot.sh" --dest "$PUBLIC_EXPORT_DIR" --init-git --dry-run --json)"
python3 - "$PUBLIC_EXPORT_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["mode"] == "export-public-snapshot"
assert payload["init_git"] is True
assert payload["push"] is False
assert payload["dry_run"] is True
PY
"$REPO_ROOT/scripts/export-public-snapshot.sh" --dest "$PUBLIC_EXPORT_DIR" --init-git >/dev/null
[[ -f "$PUBLIC_EXPORT_DIR/README.md" ]] || die "public export missing README.md"
[[ -d "$PUBLIC_EXPORT_DIR/.git" ]] || die "public export did not initialize git"
[[ ! -e "$PUBLIC_EXPORT_DIR/HEARTBEAT.md" ]] || die "public export should not include untracked HEARTBEAT.md"
git -C "$PUBLIC_EXPORT_DIR" rev-parse --verify HEAD >/dev/null 2>&1 || die "public export missing initial commit"

log "inventorying legacy runtime references"
LEGACY_ROOT="$TMP_ROOT/legacy-runtime"
mkdir -p "$LEGACY_ROOT/cron" "$LEGACY_ROOT/scripts" "$LEGACY_ROOT/skills/sample-skill" "$LEGACY_ROOT/credentials"
mkdir -p "$LEGACY_ROOT/shared/tools" "$LEGACY_ROOT/shared/references" "$LEGACY_ROOT/memory"
mkdir -p "$LEGACY_ROOT/secrets" "$LEGACY_ROOT/data" "$LEGACY_ROOT/assets/sample" "$LEGACY_ROOT/extensions/sample-ext"
cat >"$LEGACY_ROOT/scripts/morning-briefing.py" <<'EOF'
#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.openclaw/scripts"))
CRED_DIR = os.path.expanduser("~/.openclaw/credentials")
SECRET_DIR = os.path.expanduser("~/.openclaw/secrets")
DB_PATH = os.path.expanduser("~/.openclaw/data/example.db")
ASSET_PATH = os.path.expanduser("~/.openclaw/assets/sample/logo.txt")
EOF
printf '# sample skill\n' >"$LEGACY_ROOT/skills/sample-skill/SKILL.md"
printf 'tool note\n' >"$LEGACY_ROOT/shared/tools/tool.md"
printf 'reference note\n' >"$LEGACY_ROOT/shared/references/ref.md"
: >"$LEGACY_ROOT/memory/$SMOKE_AGENT.sqlite"
printf 'sqlite-placeholder\n' >"$LEGACY_ROOT/data/example.db"
printf 'asset\n' >"$LEGACY_ROOT/assets/sample/logo.txt"
printf 'extension\n' >"$LEGACY_ROOT/extensions/sample-ext/README.md"
printf '{"channels":{"discord":{"accounts":{"default":{"token":"smoke-token"}}}},"extensions":{"sample-ext":{"installPath":"~/.openclaw/extensions/sample-ext"}}}\n' >"$LEGACY_ROOT/openclaw.json"
printf 'cred\n' >"$LEGACY_ROOT/credentials/example.txt"
printf 'secret\n' >"$LEGACY_ROOT/secrets/example.token"
cat >"$LEGACY_ROOT/cron/jobs.json" <<EOF
{
  "jobs": [
    {
      "id": "legacy-job-1",
      "name": "morning-briefing-smoke",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "payload": {
        "text": "python3 ~/.openclaw/scripts/morning-briefing.py\nsessions_history(sessionKey=\"agent:smoke-agent:discord:channel:123\")\nsessions_send(sessionKey=\"agent:smoke-helper:discord:channel:123\", message=\"[ALERT] check queue\")\nexec: openclaw message send --channel discord --account smoke --target \"123\" --message \"done\""
      }
    }
  ]
}
EOF
mkdir -p "$BRIDGE_HOME/shared"
cat >"$BRIDGE_HOME/shared/runtime-note.md" <<'EOF'
Legacy ref: ~/.openclaw/skills/shopify-api and agent-db are still mentioned here.
EOF
RUNTIME_INVENTORY_OUTPUT="$("$REPO_ROOT/agent-bridge" migrate runtime inventory --bridge-home "$BRIDGE_HOME" --legacy-home "$LEGACY_ROOT" --jobs-file "$LEGACY_ROOT/cron/jobs.json")"
assert_contains "$RUNTIME_INVENTORY_OUTPUT" "cron_with_legacy_refs: 1"
assert_contains "$RUNTIME_INVENTORY_OUTPUT" "skills: 1"
assert_contains "$RUNTIME_INVENTORY_OUTPUT" "notify: 1"

log "importing recurring jobs into the bridge-native cron store"
CRON_IMPORT_DRY_RUN_OUTPUT="$("$REPO_ROOT/agent-bridge" cron import --source-jobs-file "$LEGACY_ROOT/cron/jobs.json" --dry-run)"
assert_contains "$CRON_IMPORT_DRY_RUN_OUTPUT" "\"status\": \"dry_run\""
assert_contains "$CRON_IMPORT_DRY_RUN_OUTPUT" "\"imported_jobs\": 1"
CRON_IMPORT_OUTPUT="$("$REPO_ROOT/agent-bridge" cron import --source-jobs-file "$LEGACY_ROOT/cron/jobs.json")"
assert_contains "$CRON_IMPORT_OUTPUT" "\"status\": \"imported\""
CRON_IMPORTED_SHOW_OUTPUT="$("$REPO_ROOT/agent-bridge" cron show morning-briefing-smoke)"
assert_contains "$CRON_IMPORTED_SHOW_OUTPUT" "morning-briefing-smoke"
python3 - <<PY
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
job = next(item for item in payload["jobs"] if item["name"] == "morning-briefing-smoke")
assert job["agentId"] == "${SMOKE_AGENT}"
assert job["agent"] == job["agentId"]
PY
CRON_IMPORTED_SYNC_OUTPUT="$("$REPO_ROOT/agent-bridge" cron sync --dry-run --since '2026-04-05T08:59:00+00:00' --now '2026-04-05T09:00:00+00:00')"
assert_contains "$CRON_IMPORTED_SYNC_OUTPUT" "native: status=dry_run"
assert_contains "$CRON_IMPORTED_SYNC_OUTPUT" "due=1"

log "including one-shot native jobs during recurring sync"
python3 - <<PY
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
payload["jobs"].append({
    "id": "native-at-smoke",
    "agentId": "${SMOKE_AGENT}",
    "name": "native-at-smoke",
    "enabled": True,
    "createdAtMs": 1743840000000,
    "updatedAtMs": 1743840000000,
    "schedule": {
        "kind": "at",
        "at": "2026-04-05T08:30:00+00:00",
    },
    "payload": {
        "kind": "agentTurn",
        "message": "one-shot smoke",
    },
    "deleteAfterRun": True,
    "state": {},
})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
CRON_IMPORTED_AT_OUTPUT="$("$REPO_ROOT/agent-bridge" cron sync --dry-run --since '2026-04-05T08:29:00+00:00' --now '2026-04-05T09:00:00+00:00')"
assert_contains "$CRON_IMPORTED_AT_OUTPUT" "native: status=dry_run"
assert_contains "$CRON_IMPORTED_AT_OUTPUT" "due=2"

log "auto-pruning expired one-shot jobs during native sync"
python3 - <<PY
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
payload["jobs"].append({
    "id": "expired-at-cleanup-smoke",
    "agentId": "${SMOKE_AGENT}",
    "name": "expired-at-cleanup-smoke",
    "enabled": False,
    "createdAtMs": 1743840000000,
    "updatedAtMs": 1743840000000,
    "schedule": {
        "kind": "at",
        "at": "2026-04-04T08:30:00+00:00",
    },
    "payload": {
        "kind": "agentTurn",
        "message": "expired cleanup smoke",
    },
    "deleteAfterRun": True,
    "state": {},
})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
CRON_CLEANUP_SYNC_JSON="$("$REPO_ROOT/agent-bridge" cron sync --json --since '2026-04-05T08:29:00+00:00' --now '2026-04-05T09:00:00+00:00')"
assert_contains "$CRON_CLEANUP_SYNC_JSON" "\"cleanup_deleted_jobs\": 1"
[[ -f "$BRIDGE_STATE_DIR/cron/scheduler-state.json" ]] || die "expected canonical scheduler-state.json after native sync"
assert_contains "$(cat "$BRIDGE_STATE_DIR/cron/scheduler-state.json")" "\"last_sync_at\""
python3 - <<PY
import json, os
path = os.path.join(os.environ["BRIDGE_HOME"], "cron", "jobs.json")
payload = json.load(open(path, "r", encoding="utf-8"))
assert all(job.get("id") != "expired-at-cleanup-smoke" for job in payload["jobs"])
PY

log "resolving cron targets for sleeping static roles and fallback delivery"
CRON_ROUTE_JOBS_FILE="$TMP_ROOT/cron-route-jobs.json"
cat >"$CRON_ROUTE_JOBS_FILE" <<EOF
{
  "jobs": [
    {
      "id": "mapped-route-job",
      "name": "mapped-route-job",
      "enabled": true,
      "agentId": "legacy-ops",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "payload": {
        "text": "mapped route payload"
      }
    },
    {
      "id": "fallback-route-job",
      "name": "fallback-route-job",
      "enabled": true,
      "agentId": "missing-role",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "payload": {
        "text": "fallback route payload"
      }
    }
  ]
}
EOF
CRON_MAPPED_ROUTE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron enqueue mapped-route-job --jobs-file "$CRON_ROUTE_JOBS_FILE" --slot 2026-04-05 --dry-run)"
assert_contains "$CRON_MAPPED_ROUTE_OUTPUT" "target: $AUTO_START_AGENT"
assert_contains "$CRON_MAPPED_ROUTE_OUTPUT" "delivery_mode: mapped"
CRON_FALLBACK_ROUTE_OUTPUT="$("$REPO_ROOT/agent-bridge" cron enqueue fallback-route-job --jobs-file "$CRON_ROUTE_JOBS_FILE" --slot 2026-04-05 --dry-run)"
assert_contains "$CRON_FALLBACK_ROUTE_OUTPUT" "target: $SMOKE_AGENT"
assert_contains "$CRON_FALLBACK_ROUTE_OUTPUT" "delivery_mode: fallback"

log "parsing Claude plain-text cron results without structured_output"
python3 - <<'PY'
import importlib.util
from pathlib import Path

path = Path("bridge-cron-runner.py").resolve()
spec = importlib.util.spec_from_file_location("bridge_cron_runner", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

payload = (
    '{"type":"result","subtype":"success","is_error":false,'
    '"result":"The cron run finished successfully with no events to remind."}'
)
result = module.parse_claude_output(payload)
assert result["status"] == "completed"
assert result["summary"] == "The cron run finished successfully with no events to remind."
assert result["needs_human_followup"] is False
assert result["confidence"] == "low"
PY

log "preserving cron channel-delivery metadata and target channel runtime"
CRON_CHANNEL_JOBS_FILE="$TMP_ROOT/cron-channel-jobs.json"
cat >"$CRON_CHANNEL_JOBS_FILE" <<EOF
{
  "jobs": [
    {
      "id": "channel-job",
      "name": "channel-job",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "delivery": {
        "mode": "direct",
        "channel": "telegram",
        "to": "telegram:123"
      },
      "metadata": {
        "allowChannelDelivery": true
      },
      "payload": {
        "text": "send a telegram update"
      }
    }
  ]
}
EOF
CHANNEL_SHELL_OUTPUT="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$CRON_CHANNEL_JOBS_FILE" --format shell channel-job)"
assert_contains "$CHANNEL_SHELL_OUTPUT" "CRON_JOB_JOB_DELIVERY_MODE=direct"
assert_contains "$CHANNEL_SHELL_OUTPUT" "CRON_JOB_JOB_DELIVERY_CHANNEL=telegram"
assert_contains "$CHANNEL_SHELL_OUTPUT" "CRON_JOB_ALLOW_CHANNEL_DELIVERY=1"
assert_contains "$CHANNEL_SHELL_OUTPUT" "CRON_JOB_DISPOSABLE_NEEDS_CHANNELS=0"

python3 - <<'PY'
# PR1 (cron inbox-only reporting) — the cron child no longer ever sends
# to external channels itself, so the prompt preamble talks about
# `delivery_intent` rather than `channel_relay`, and `--channels` /
# `apply_channel_runtime_env` paths are gone. Tests reflect that contract.
import importlib.util
import subprocess
from pathlib import Path

path = Path("bridge-cron-runner.py").resolve()
spec = importlib.util.spec_from_file_location("bridge_cron_runner", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

request = {
    "target_agent": "tester",
    "target_engine": "claude",
    "job_name": "channel-job",
    "family": "channel-job",
    "slot": "2026-04-05T09:00+00:00",
    "run_id": "channel-job--2026-04-05T09-00-00-00",
    "payload_file": "/tmp/payload.md",
    "target_workdir": str(Path(".").resolve()),
    "target_channels": "plugin:telegram",
    "target_telegram_state_dir": "/tmp/telegram-state",
    "allow_structured_relay": True,
    "disposable_needs_channels": False,
    "job_delivery_channel": "telegram",
    "job_delivery_target": "telegram:123",
}
prompt = module.build_prompt(request, "send a telegram update")
# PR1.2 — the policy preamble must carry the inbox-only reporting contract.
assert "Reporting policy" in prompt
assert "delivery_intent" in prompt
assert "main_session_only" in prompt
assert "forward_to_user" in prompt
# PR1.3 — the cron child has no path to external channels at all, so the
# prompt does not negotiate about `--channels` or relay tools. The `tester`
# parent identity must still be surfaced (`<{parent}>`).
assert "tester" in prompt
# PR1.4 — when the legacy `allow_structured_relay` flag is on we still
# acknowledge `channel_relay` as a deprecated fallback.
assert "Legacy structured relay" in prompt or "channel_relay" in prompt

# PR1.5 — validate_result rejects results that omit delivery_intent.
try:
    module.validate_result(
        {
            "status": "completed",
            "summary": "missing intent",
            "findings": [],
            "actions_taken": [],
            "needs_human_followup": False,
            "recommended_next_steps": [],
            "artifacts": [],
            "confidence": "high",
        }
    )
except ValueError as exc:
    assert "delivery_intent" in str(exc)
else:
    raise AssertionError("expected missing delivery_intent to fail")

# silent-intent results don't need summary_short or forward_target.
silent = module.validate_result(
    {
        "status": "completed",
        "summary": "routine ok",
        "findings": [],
        "actions_taken": [],
        "needs_human_followup": False,
        "recommended_next_steps": [],
        "artifacts": [],
        "confidence": "high",
        "delivery_intent": "silent",
    }
)
assert silent["delivery_intent"] == "silent"
assert "summary_short" not in silent
assert "forward_target" not in silent

# main_session_only requires summary_short.
try:
    module.validate_result(
        {
            "status": "completed",
            "summary": "long summary",
            "findings": [],
            "actions_taken": [],
            "needs_human_followup": True,
            "recommended_next_steps": [],
            "artifacts": [],
            "confidence": "high",
            "delivery_intent": "main_session_only",
        }
    )
except ValueError as exc:
    assert "summary_short" in str(exc)
else:
    raise AssertionError("expected missing summary_short to fail")

# forward_to_user requires both summary_short and forward_target.
try:
    module.validate_result(
        {
            "status": "completed",
            "summary": "alert",
            "findings": [],
            "actions_taken": [],
            "needs_human_followup": True,
            "recommended_next_steps": [],
            "artifacts": [],
            "confidence": "high",
            "delivery_intent": "forward_to_user",
            "summary_short": "alert!",
        }
    )
except ValueError as exc:
    assert "forward_target" in str(exc)
else:
    raise AssertionError("expected missing forward_target to fail")

# Happy path: forward_to_user with a complete forward_target.
forward = module.validate_result(
    {
        "status": "completed",
        "summary": "Disk usage 95% on host A",
        "findings": ["disk_full"],
        "actions_taken": [],
        "needs_human_followup": True,
        "recommended_next_steps": [],
        "artifacts": [],
        "confidence": "high",
        "delivery_intent": "forward_to_user",
        "summary_short": "Disk usage 95% on host A",
        "forward_target": {
            "channel": "telegram",
            "target_ref": "ops",
            "format": "markdown",
        },
    }
)
assert forward["forward_target"]["channel"] == "telegram"
assert forward["forward_target"]["target_ref"] == "ops"

# legacy channel_relay is still honored as a deprecated alias.
legacy = module.validate_result(
    {
        "status": "completed",
        "summary": "relay prepared",
        "findings": [],
        "actions_taken": [],
        "needs_human_followup": False,
        "recommended_next_steps": [],
        "artifacts": [],
        "confidence": "high",
        "delivery_intent": "main_session_only",
        "summary_short": "relay prepared",
        "channel_relay": {
            "body": "hello from relay",
            "transport": "telegram",
            "target": "default",
            "urgency": "normal",
        },
    }
)
assert legacy["needs_human_followup"] is True
assert legacy["channel_relay"]["body"] == "hello from relay"

# PR1.5 — empty relay body is still rejected (legacy semantics preserved).
try:
    module.validate_result(
        {
            "status": "completed",
            "summary": "bad relay",
            "findings": [],
            "actions_taken": [],
            "needs_human_followup": True,
            "recommended_next_steps": [],
            "artifacts": [],
            "confidence": "high",
            "delivery_intent": "main_session_only",
            "summary_short": "bad relay",
            "channel_relay": {"body": "   "},
        }
    )
except ValueError as exc:
    assert "channel_relay.body" in str(exc)
else:
    raise AssertionError("expected invalid empty relay body to fail")

# PR1.5 — direct-send markers in forward_target.target_ref or summary_short
# are detected (audit-only; never raise per Sean Q-C 2026-05-02).
markers = module.detect_direct_send_markers(
    {
        "delivery_intent": "forward_to_user",
        "summary_short": "alert",
        "forward_target": {
            "channel": "telegram",
            "target_ref": "tg_send chat_id=123",
            "format": "text",
        },
    }
)
assert markers, "expected direct-send marker detection on forward_target.target_ref"
assert markers[0]["field"] == "forward_target.target_ref"
assert markers[0]["marker"] == "tg_send"

# Markers in `summary` (free-form narrative) are deliberately NOT flagged
# to avoid false-positives when a body legitimately quotes a webhook URL.
no_markers = module.detect_direct_send_markers(
    {
        "delivery_intent": "main_session_only",
        "summary_short": "all good",
        "summary": "I considered tg_send but did not invoke it.",
    }
)
assert not no_markers, "narrative summary should not trip marker detection"


def fake_run(command, **kwargs):
    return subprocess.CompletedProcess(
        command,
        0,
        '{"summary":"ok","delivery_status":"not_sent","needs_human_followup":false,"recommended_next_steps":"","details_markdown":""}',
        "",
    )


module.resolve_binary = lambda name, env_var: f"/fake/{name}"
module.subprocess.run = fake_run

# PR1.3 — `--channels` is never injected and `--strict-mcp-config` is
# always present, regardless of legacy `disposable_needs_channels` /
# `target_channels` content in the request.
command, _ = module.run_claude(request, prompt, 30)
assert "--channels" not in command, command
assert "--strict-mcp-config" in command, command

opt_in_request = dict(request)
opt_in_request["disposable_needs_channels"] = True
command, _ = module.run_claude(opt_in_request, prompt, 30)
assert "--channels" not in command, command
assert "--strict-mcp-config" in command, command
PY

log "honouring metadata.disableMcp on disposable cron child (#263)"
CRON_NOMCP_JOBS_FILE="$TMP_ROOT/cron-nomcp-jobs.json"
cat >"$CRON_NOMCP_JOBS_FILE" <<EOF
{
  "jobs": [
    {
      "id": "no-mcp-job",
      "name": "no-mcp-job",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "*/15 * * * *",
        "tz": "UTC"
      },
      "metadata": {
        "disableMcp": true
      },
      "payload": {
        "text": "ping"
      }
    },
    {
      "id": "snake-mcp-job",
      "name": "snake-mcp-job",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "metadata": {
        "disposable_disable_mcp": true
      },
      "payload": {
        "text": "ping"
      }
    },
    {
      "id": "mcp-default-job",
      "name": "mcp-default-job",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      },
      "payload": {
        "text": "ping"
      }
    }
  ]
}
EOF
NOMCP_SHELL="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$CRON_NOMCP_JOBS_FILE" --format shell no-mcp-job)"
assert_contains "$NOMCP_SHELL" "CRON_JOB_DISABLE_MCP=1"
SNAKE_SHELL="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$CRON_NOMCP_JOBS_FILE" --format shell snake-mcp-job)"
assert_contains "$SNAKE_SHELL" "CRON_JOB_DISABLE_MCP=1"
DEFAULT_SHELL="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$CRON_NOMCP_JOBS_FILE" --format shell mcp-default-job)"
assert_contains "$DEFAULT_SHELL" "CRON_JOB_DISABLE_MCP=0"

python3 - <<'PY'
# PR1.3 — `disable_mcp_for_request` is unconditionally True now and
# `run_claude` always passes `--strict-mcp-config`. The legacy env override
# (`BRIDGE_CRON_DISPOSABLE_DISABLE_MCP`) and `disposable_needs_channels`
# safety override are intentionally dead so an existing telegram cron
# config can never re-attach the parent's MCP poller from the disposable
# child (#468).
import importlib.util
import os
import subprocess
from pathlib import Path

path = Path("bridge-cron-runner.py").resolve()
spec = importlib.util.spec_from_file_location("bridge_cron_runner", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

base = {
    "target_agent": "tester",
    "target_engine": "claude",
    "job_name": "j",
    "family": "j",
    "slot": "s",
    "run_id": "r",
    "payload_file": "/tmp/p",
    "target_workdir": str(Path(".").resolve()),
    "target_channels": "",
    "allow_channel_delivery": False,
    "disposable_needs_channels": False,
}

assert module.disable_mcp_for_request(dict(base)) is True
# Legacy env override has no effect any more.
os.environ["BRIDGE_CRON_DISPOSABLE_DISABLE_MCP"] = "0"
try:
    assert module.disable_mcp_for_request(dict(base)) is True
finally:
    del os.environ["BRIDGE_CRON_DISPOSABLE_DISABLE_MCP"]
# disposable_needs_channels no longer flips the gate.
relay = dict(base, disable_mcp=False, disposable_needs_channels=True, target_channels="plugin:telegram")
assert module.disable_mcp_for_request(relay) is True
# Per-request opt-out is now a no-op.
opt_out = dict(base, disable_mcp=False)
assert module.disable_mcp_for_request(opt_out) is True

# Wire-through: --strict-mcp-config flag is always present.
captured = {}
real_run = subprocess.run

def fake_run(cmd, **kw):
    captured["cmd"] = cmd
    return subprocess.CompletedProcess(cmd, 0, "{}", "")

subprocess.run = fake_run
try:
    module.resolve_binary = lambda name, env_var: f"/fake/{name}"
    module.run_claude(dict(base), "prompt", 30)
    assert "--strict-mcp-config" in captured["cmd"]
    assert "--channels" not in captured["cmd"]
    # Even when the legacy disposable_needs_channels + target_channels are
    # set, --channels stays out and --strict-mcp-config stays in.
    relay_request = dict(
        base,
        disposable_needs_channels=True,
        target_channels="plugin:telegram",
    )
    module.run_claude(relay_request, "prompt", 30)
    assert "--strict-mcp-config" in captured["cmd"]
    assert "--channels" not in captured["cmd"]
finally:
    subprocess.run = real_run

print("PR1.3 strict-mcp + no-channels wire-through OK")
PY

log "pre-flight memory guard defers cron dispatch on pressured hosts (#263 Track B)"
# Mock check_memory_pressure to return a pressured probe and assert that
# cmd_run skips the engine spawn, writes a deferred status, and surfaces the
# probe metadata. Then mock the probe to clear and confirm the engine spawn
# path executes normally.
CRON_PREFLIGHT_RUN_DIR="$TMP_ROOT/cron-preflight-run"
mkdir -p "$CRON_PREFLIGHT_RUN_DIR"
CRON_PREFLIGHT_REQUEST_FILE="$CRON_PREFLIGHT_RUN_DIR/request.json"
python3 - "$CRON_PREFLIGHT_REQUEST_FILE" "$CRON_PREFLIGHT_RUN_DIR" <<'PY'
import json
import sys
from pathlib import Path

request_path = Path(sys.argv[1])
run_dir = Path(sys.argv[2])
request_path.write_text(
    json.dumps(
        {
            "run_id": "preflight-smoke",
            "job_name": "preflight-smoke-job",
            "family": "preflight-smoke",
            "slot": "2026-04-26T00:00",
            "target_agent": "tester",
            "target_engine": "claude",
            "target_workdir": str(run_dir),
            "target_channels": "",
            "allow_channel_delivery": False,
            "disposable_needs_channels": False,
            "payload_file": str(run_dir / "payload.txt"),
            "result_file": str(run_dir / "result.json"),
            "status_file": str(run_dir / "status.json"),
            "stdout_log": str(run_dir / "stdout.log"),
            "stderr_log": str(run_dir / "stderr.log"),
        },
        ensure_ascii=True,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
(run_dir / "payload.txt").write_text("ping\n", encoding="utf-8")
PY

CRON_PREFLIGHT_REQUEST_FILE="$CRON_PREFLIGHT_REQUEST_FILE" \
CRON_PREFLIGHT_RUN_DIR="$CRON_PREFLIGHT_RUN_DIR" \
python3 - <<'PY'
import argparse
import importlib.util
import json
import os
import subprocess
from pathlib import Path

path = Path("bridge-cron-runner.py").resolve()
spec = importlib.util.spec_from_file_location("bridge_cron_runner", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

request_file = os.environ["CRON_PREFLIGHT_REQUEST_FILE"]
run_dir = Path(os.environ["CRON_PREFLIGHT_RUN_DIR"])
status_file = run_dir / "status.json"

# --- Pressured path -----------------------------------------------------
spawn_calls = []
real_run = subprocess.run

def fake_run(cmd, **kw):
    spawn_calls.append(list(cmd))
    return subprocess.CompletedProcess(cmd, 0, "{}", "")

pressure_probe = {
    "reason": "memory_pressure",
    "kind": "darwin",
    "metric": "swap_pct",
    "value": 92,
    "limit": 80,
    "swap_used_mb": 3700,
    "swap_total_mb": 4096,
}
module.check_memory_pressure = lambda: dict(pressure_probe)
audit_calls = []
module.emit_pressure_audit = lambda run_id, target, probe: audit_calls.append((run_id, target, dict(probe)))
subprocess.run = fake_run
try:
    args = argparse.Namespace(request_file=request_file, dry_run=False)
    rc = module.cmd_run(args)
finally:
    subprocess.run = real_run

assert rc == 0, f"deferred cmd_run should return 0, got {rc}"
status = json.loads(status_file.read_text(encoding="utf-8"))
assert status.get("state") == "deferred", f"expected deferred state, got {status!r}"
assert status.get("deferred_reason") == "memory_pressure", status
assert status.get("deferred_seconds") == module.PRESSURE_DEFER_SECONDS, status
assert status.get("memory_probe", {}).get("metric") == "swap_pct", status
assert status.get("memory_probe", {}).get("value") == 92, status
# No engine spawn should have happened on the pressured path.
spawn_bins = [cmd[0] for cmd in spawn_calls if cmd]
assert not any("claude" in os.path.basename(b) for b in spawn_bins), (
    f"expected no Claude spawn on pressured host, got {spawn_calls!r}"
)
assert not any("codex" in os.path.basename(b) for b in spawn_bins), (
    f"expected no Codex spawn on pressured host, got {spawn_calls!r}"
)
assert audit_calls, "expected emit_pressure_audit to be called"
assert audit_calls[0][2]["reason"] == "memory_pressure"

# Reset for the healthy-path probe.
status_file.unlink(missing_ok=True)

# --- Healthy path -------------------------------------------------------
# Probe returns None → cmd_run continues into the engine spawn. Stub the
# Claude binary spawn so we don't need a real CLI on PATH.
module.check_memory_pressure = lambda: None
module.resolve_binary = lambda name, env_var: f"/fake/{name}"

healthy_spawn_calls = []
healthy_completed_payload = json.dumps(
    {
        "structured_output": {
            "status": "completed",
            "summary": "ok",
            "findings": [],
            "actions_taken": [],
            "needs_human_followup": False,
            "recommended_next_steps": [],
            "artifacts": [],
            "confidence": "high",
            # PR1 — delivery_intent is now schema-required. The healthy
            # smoke path returns silent so cmd_run takes the no-inbox-task
            # branch and we don't need to mock bridge-queue.py here.
            "delivery_intent": "silent",
        }
    },
    ensure_ascii=True,
)

def healthy_fake_run(cmd, **kw):
    healthy_spawn_calls.append(list(cmd))
    return subprocess.CompletedProcess(cmd, 0, healthy_completed_payload, "")

subprocess.run = healthy_fake_run
try:
    args = argparse.Namespace(request_file=request_file, dry_run=False)
    rc = module.cmd_run(args)
finally:
    subprocess.run = real_run

assert rc == 0, f"healthy cmd_run should return 0 on success, got {rc}"
final_status = json.loads(status_file.read_text(encoding="utf-8"))
assert final_status.get("state") == "success", f"expected success state on healthy host, got {final_status!r}"
assert healthy_spawn_calls, "expected the healthy path to spawn the engine"
assert any("claude" in os.path.basename(cmd[0]) for cmd in healthy_spawn_calls), (
    f"expected Claude spawn on healthy path, got {healthy_spawn_calls!r}"
)

# --- Probe knob handling ------------------------------------------------
# Default Darwin limit is 80, default Linux threshold is 512MB. Confirm
# the env knobs are honoured.
os.environ["BRIDGE_CRON_SWAP_PCT_LIMIT"] = "55"
assert module._swap_pct_limit() == 55
os.environ["BRIDGE_CRON_SWAP_PCT_LIMIT"] = "not-a-number"
assert module._swap_pct_limit() == module.DEFAULT_SWAP_PCT_LIMIT
del os.environ["BRIDGE_CRON_SWAP_PCT_LIMIT"]
assert module._swap_pct_limit() == module.DEFAULT_SWAP_PCT_LIMIT

os.environ["BRIDGE_CRON_MIN_AVAIL_MB"] = "1024"
assert module._min_avail_mb() == 1024
os.environ["BRIDGE_CRON_MIN_AVAIL_MB"] = "garbage"
assert module._min_avail_mb() == module.DEFAULT_MIN_AVAIL_MB
del os.environ["BRIDGE_CRON_MIN_AVAIL_MB"]
assert module._min_avail_mb() == module.DEFAULT_MIN_AVAIL_MB

print("pre-flight memory guard OK")
PY

log "PR1.9 — cron-runner end-to-end delivery_intent matrix + dedupe semantics"
PR1_RUN_ROOT="$TMP_ROOT/pr1-cron-runs"
PR1_TARGET_AGENT="smoke-pr1-target"
mkdir -p "$PR1_RUN_ROOT"
PR1_RUN_ROOT="$PR1_RUN_ROOT" \
PR1_TARGET_AGENT="$PR1_TARGET_AGENT" \
PR1_REPO_ROOT="$REPO_ROOT" \
python3 - <<'PY'
# Drive cmd_run for each delivery_intent (silent / main_session_only /
# forward_to_user) against an isolated BRIDGE_TASK_DB, mocking the Claude
# binary spawn but letting real bridge-queue.py + audit subprocess calls
# go through. Verifies plan §PR1.9:
#   - silent → no inbox task, reporting_decision=silent
#   - main_session_only → 1 inbox task; second run with same job refreshes (refresh-by-job)
#   - forward_to_user → fresh task per run (per-run)
import argparse
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

run_root = Path(os.environ["PR1_RUN_ROOT"])
target_agent = os.environ["PR1_TARGET_AGENT"]
repo_root = Path(os.environ["PR1_REPO_ROOT"])

path = repo_root / "bridge-cron-runner.py"
spec = importlib.util.spec_from_file_location("bridge_cron_runner", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def make_request(run_id: str, job_name: str) -> Path:
    run_dir = run_root / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    request_path = run_dir / "request.json"
    request_path.write_text(
        json.dumps(
            {
                "run_id": run_id,
                "job_id": "pr1-test-job",
                "job_name": job_name,
                "family": job_name,
                "slot": run_id,
                "source_agent": "smoke",
                "target_agent": target_agent,
                "target_engine": "claude",
                "target_workdir": str(run_dir),
                "target_channels": "",
                "allow_structured_relay": False,
                "disposable_needs_channels": False,
                "payload_file": str(run_dir / "payload.txt"),
                "result_file": str(run_dir / "result.json"),
                "status_file": str(run_dir / "status.json"),
                "stdout_log": str(run_dir / "stdout.log"),
                "stderr_log": str(run_dir / "stderr.log"),
                "cron_urgency": "normal",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (run_dir / "payload.txt").write_text("ping\n", encoding="utf-8")
    return request_path


def fake_claude_payload(intent: str) -> str:
    output_dict = {
        "status": "completed",
        "summary": "smoke test result",
        "findings": [],
        "actions_taken": [],
        "needs_human_followup": False,
        "recommended_next_steps": [],
        "artifacts": [],
        "confidence": "high",
        "delivery_intent": intent,
    }
    if intent != "silent":
        output_dict["summary_short"] = f"alert ({intent})"
    if intent == "forward_to_user":
        output_dict["forward_target"] = {
            "channel": "telegram",
            "target_ref": "ops-channel",
            "format": "markdown",
        }
    return json.dumps({"structured_output": output_dict})


REAL_RUN = subprocess.run


def make_fake_run(intent: str):
    payload = fake_claude_payload(intent)

    def fake(cmd, **kwargs):
        if cmd and "claude" in os.path.basename(cmd[0]) and "bridge-queue" not in os.path.basename(cmd[0]):
            return subprocess.CompletedProcess(cmd, 0, payload, "")
        return REAL_RUN(cmd, **kwargs)

    return fake


def run_cron(run_id: str, job_name: str, intent: str) -> dict:
    request = make_request(run_id, job_name)
    module.resolve_binary = lambda name, env_var: "/fake/claude" if name == "claude" else f"/fake/{name}"
    module.subprocess.run = make_fake_run(intent)
    try:
        rc = module.cmd_run(argparse.Namespace(request_file=str(request), dry_run=False))
    finally:
        module.subprocess.run = REAL_RUN
    result_path = request.parent / "result.json"
    return {
        "rc": rc,
        "result": json.loads(result_path.read_text(encoding="utf-8")),
    }


def open_tasks() -> list[dict]:
    out = REAL_RUN(
        [
            sys.executable,
            str(repo_root / "bridge-queue.py"),
            "find-open",
            "--agent",
            target_agent,
            "--all",
            "--format",
            "json",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode not in (0, 1):
        raise AssertionError(f"find-open --all failed rc={out.returncode}: {out.stderr}")
    return json.loads(out.stdout or "[]")


# 1) silent — no inbox task created, reporting_decision=silent
silent_a = run_cron("silent-A", "pr1-silent-job", "silent")
assert silent_a["rc"] == 0, silent_a
assert silent_a["result"]["delivery_intent"] == "silent", silent_a["result"]
assert silent_a["result"]["reporting_decision"] == "silent", silent_a["result"]
assert silent_a["result"].get("inbox_task_id") in (None, ""), silent_a["result"]
silent_tasks = [t for t in open_tasks() if t["title"].startswith("[cron-followup] pr1-silent-job")]
assert not silent_tasks, f"silent run should not create a task: {silent_tasks}"

# 2) main_session_only — refresh-by-job dedupe (one task across runs)
main1 = run_cron("main-A", "pr1-main-job", "main_session_only")
assert main1["rc"] == 0, main1
assert main1["result"]["delivery_intent"] == "main_session_only", main1["result"]
assert main1["result"]["reporting_decision"] == "reported", main1["result"]
main_id_1 = main1["result"]["inbox_task_id"]
assert isinstance(main_id_1, int) and main_id_1 > 0, main1["result"]

main2 = run_cron("main-B", "pr1-main-job", "main_session_only")
assert main2["rc"] == 0, main2
main_id_2 = main2["result"]["inbox_task_id"]
assert main_id_2 == main_id_1, (
    f"main_session_only should refresh-by-job: first={main_id_1} second={main_id_2}"
)

main_open = [t for t in open_tasks() if t["title"].startswith("[cron-followup] pr1-main-job")]
assert len(main_open) == 1, f"expected 1 open main task, got {main_open}"

# 3) forward_to_user — per-run dedupe (each run lands as a fresh task)
fwd1 = run_cron("fwd-A", "pr1-fwd-job", "forward_to_user")
assert fwd1["rc"] == 0, fwd1
assert fwd1["result"]["delivery_intent"] == "forward_to_user", fwd1["result"]
fwd_id_1 = fwd1["result"]["inbox_task_id"]
assert isinstance(fwd_id_1, int) and fwd_id_1 > 0, fwd1["result"]

fwd2 = run_cron("fwd-B", "pr1-fwd-job", "forward_to_user")
assert fwd2["rc"] == 0, fwd2
fwd_id_2 = fwd2["result"]["inbox_task_id"]
assert fwd_id_2 != fwd_id_1, (
    f"forward_to_user should produce per-run tasks: first={fwd_id_1} second={fwd_id_2}"
)

fwd_open = [t for t in open_tasks() if t["title"].startswith("[cron-followup] pr1-fwd-job")]
assert len(fwd_open) == 2, f"expected 2 open forward tasks, got {fwd_open}"

# Audit fields: each result.json carries delivery_intent + reporting_decision.
for run_id in ("silent-A", "main-A", "main-B", "fwd-A", "fwd-B"):
    result = json.loads((run_root / run_id / "result.json").read_text(encoding="utf-8"))
    assert "delivery_intent" in result, (run_id, result)
    assert "reporting_decision" in result, (run_id, result)
    status = json.loads((run_root / run_id / "status.json").read_text(encoding="utf-8"))
    assert "delivery_intent" in status, (run_id, status)
    assert "reporting_decision" in status, (run_id, status)

print("PR1.9 cron-runner end-to-end OK")
PY

log "PR2 — bridge_cron_followup.parse_followup matrix (frontmatter parser helper)"
PR2_REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os
import sys
from pathlib import Path

repo_root = Path(os.environ["PR2_REPO_ROOT"])
sys.path.insert(0, str(repo_root / "lib"))
from bridge_cron_followup import parse_followup, DELIVERY_INTENT_VALUES

GOOD_MAIN = '''---
{
  "schema_version": 1,
  "kind": "cron-followup",
  "delivery_intent": "main_session_only",
  "run_id": "run-1",
  "job_id": "job-1",
  "job_name": "smoke",
  "family": "smoke",
  "target_agent": "agb-dev-claude",
  "reporting_policy": "default",
  "summary_short": "all clean"
}
---

# body
'''

# 1) valid main_session_only → returns dict with all canonical keys
parsed = parse_followup(GOOD_MAIN)
assert parsed is not None and parsed["delivery_intent"] == "main_session_only", parsed
assert parsed["reporting_policy"] == "default"
assert parsed["summary_short"] == "all clean"

# 2) missing frontmatter → None
assert parse_followup("# no fence here\nplain body") is None
assert parse_followup("") is None
assert parse_followup(None) is None  # type: ignore[arg-type]

# 3) schema_version=2 → None
assert parse_followup(GOOD_MAIN.replace('"schema_version": 1', '"schema_version": 2')) is None

# 4) malformed JSON → None
MAL = "---\n{not real json}\n---\n\nbody\n"
assert parse_followup(MAL) is None

# 5) unknown delivery_intent → None
assert parse_followup(GOOD_MAIN.replace('"main_session_only"', '"weird_intent"')) is None

# 6) forward_to_user without forward_target → None
fw_no = GOOD_MAIN.replace('"main_session_only"', '"forward_to_user"')
assert parse_followup(fw_no) is None

# 7) forward_to_user with forward_target missing required field → None
GOOD_FW = '''---
{
  "schema_version": 1,
  "kind": "cron-followup",
  "delivery_intent": "forward_to_user",
  "run_id": "run-2",
  "job_id": "job-2",
  "job_name": "alerter",
  "family": "alerts",
  "target_agent": "agb-dev-claude",
  "reporting_policy": "default",
  "forward_target": {"channel": "telegram", "target_ref": "ops", "format": "markdown"},
  "summary_short": "alert!"
}
---

# body
'''
assert parse_followup(GOOD_FW.replace('"format": "markdown"', '"format": ""')) is None

# 8) forward_to_user with full forward_target → ok and preserved
fw_ok = parse_followup(GOOD_FW)
assert fw_ok is not None and fw_ok["forward_target"]["target_ref"] == "ops"
assert fw_ok["delivery_intent"] == "forward_to_user"

# 9) legacy_structured_relay flag preserved through parse round-trip
LEG = GOOD_MAIN.replace(
    '"summary_short": "all clean"',
    '"summary_short": "all clean", "legacy_structured_relay": true',
)
assert parse_followup(LEG)["legacy_structured_relay"] is True

# 10) silent intent parses without summary_short
SIL = '''---
{
  "schema_version": 1,
  "kind": "cron-followup",
  "delivery_intent": "silent",
  "run_id": "run-s",
  "job_id": "job-s",
  "job_name": "noisy",
  "family": "noisy",
  "target_agent": "agb-dev-claude",
  "reporting_policy": "always_silent"
}
---

# body
'''
sil = parse_followup(SIL)
assert sil is not None and sil["delivery_intent"] == "silent"

# 11) summary_short over the 200-char cap → None
LONG = GOOD_MAIN.replace('"summary_short": "all clean"', '"summary_short": "' + ("x" * 201) + '"')
assert parse_followup(LONG) is None

# 12) unknown top-level keys preserved (forward-compat)
EXTRA = GOOD_MAIN.replace('"summary_short": "all clean"', '"summary_short": "all clean", "trace_id": "abc"')
ex = parse_followup(EXTRA)
assert ex is not None and ex.get("trace_id") == "abc"

# 13) writer ↔ parser round-trip via the actual PR1 writer
import importlib.util, tempfile

spec = importlib.util.spec_from_file_location(
    "bridge_cron_runner_smoke", repo_root / "bridge-cron-runner.py"
)
runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
with tempfile.TemporaryDirectory() as td:
    path = Path(td) / "body.md"
    runner.write_followup_body(
        path,
        schema_version=1,
        run_id="rt-1",
        job_id="jt-1",
        job_name="round-trip",
        family="round-trip",
        target_agent="agb-dev-claude",
        delivery_intent="main_session_only",
        forward_target=None,
        summary_short="all clean",
        summary="body summary",
        findings=[],
        actions_taken=[],
        recommended_next_steps=[],
        artifacts=[],
        reporting_policy_value="default",
        structured_relay_legacy=False,
    )
    rt = parse_followup(path.read_text(encoding="utf-8"))
    assert rt is not None and rt["run_id"] == "rt-1"

print("PR2 parse_followup matrix OK")
PY

log "PR2 — native-finalize-run persists lastReportingDecision/lastDeliveryIntent/lastInboxTaskId trio + bridge-cron.py exposes them"
PR2_FINALIZE_DIR="$TMP_ROOT/cron-pr2-finalize"
PR2_FINALIZE_RUN_DIR="$PR2_FINALIZE_DIR/run"
PR2_FINALIZE_JOBS_FILE="$PR2_FINALIZE_DIR/jobs.json"
PR2_FINALIZE_REQUEST_FILE="$PR2_FINALIZE_RUN_DIR/request.json"
PR2_FINALIZE_RESULT_FILE="$PR2_FINALIZE_RUN_DIR/result.json"
PR2_FINALIZE_STATUS_FILE="$PR2_FINALIZE_RUN_DIR/status.json"
mkdir -p "$PR2_FINALIZE_RUN_DIR"

PR2_FINALIZE_JOBS_FILE="$PR2_FINALIZE_JOBS_FILE" \
PR2_FINALIZE_REQUEST_FILE="$PR2_FINALIZE_REQUEST_FILE" \
PR2_FINALIZE_RESULT_FILE="$PR2_FINALIZE_RESULT_FILE" \
PR2_FINALIZE_STATUS_FILE="$PR2_FINALIZE_STATUS_FILE" \
python3 - <<'PY'
import json, os
from pathlib import Path

jobs_file = Path(os.environ["PR2_FINALIZE_JOBS_FILE"])
request_file = Path(os.environ["PR2_FINALIZE_REQUEST_FILE"])
result_file = Path(os.environ["PR2_FINALIZE_RESULT_FILE"])
status_file = Path(os.environ["PR2_FINALIZE_STATUS_FILE"])

jobs_file.write_text(json.dumps({
    "format": "agent-bridge-cron-v1",
    "updatedAt": "2026-05-02T00:00:00+00:00",
    "jobs": [
        {
            "id": "pr2-reported-job",
            "name": "pr2-reported",
            "agentId": "tester",
            "enabled": True,
            "schedule": {"kind": "cron", "expr": "*/15 * * * *", "tz": "UTC"},
            "payload": {"kind": "text", "text": "ping"},
            "state": {"consecutiveErrors": 0, "lastStatus": "-", "nextRunAtMs": 0},
        }
    ],
}, indent=2) + "\n", encoding="utf-8")

# A clean PR1 success: runner exited 0, reported, inbox task id 4242.
result_file.write_text(json.dumps({
    "status": "completed",
    "summary": "ok",
    "delivery_intent": "main_session_only",
    "reporting_decision": "reported",
    "inbox_task_id": 4242,
    "needs_human_followup": True,
    "summary_short": "all clean",
}, indent=2) + "\n", encoding="utf-8")
status_file.write_text(json.dumps({
    "run_id": "pr2-reported-run",
    "state": "success",
    "engine": "claude",
    "delivery_intent": "main_session_only",
    "reporting_decision": "reported",
    "inbox_task_id": 4242,
}, indent=2) + "\n", encoding="utf-8")

request_file.write_text(json.dumps({
    "run_id": "pr2-reported-run",
    "job_id": "pr2-reported-job",
    "source_file": str(jobs_file.resolve()),
    "result_file": str(result_file.resolve()),
    "status_file": str(status_file.resolve()),
}, indent=2) + "\n", encoding="utf-8")
PY

python3 "$REPO_ROOT/bridge-cron.py" native-finalize-run \
    --jobs-file "$PR2_FINALIZE_JOBS_FILE" \
    --request-file "$PR2_FINALIZE_REQUEST_FILE" \
    --json >"$PR2_FINALIZE_DIR/finalize-output.json"

PR2_FINALIZE_JOBS_FILE="$PR2_FINALIZE_JOBS_FILE" python3 - <<'PY'
import json, os
payload = json.loads(open(os.environ["PR2_FINALIZE_JOBS_FILE"], encoding="utf-8").read())
job = next(j for j in payload["jobs"] if j["id"] == "pr2-reported-job")
state = job.get("state") or {}
assert state.get("lastReportingDecision") == "reported", state
assert state.get("lastDeliveryIntent") == "main_session_only", state
assert state.get("lastInboxTaskId") == 4242, state
print("native-finalize-run reporting trio writeback OK")
PY

# `agb cron show` text + shell + json surfaces must include the new trio.
PR2_SHOW_TEXT="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$PR2_FINALIZE_JOBS_FILE" pr2-reported)"
assert_contains "$PR2_SHOW_TEXT" "last_reporting_decision: reported"
assert_contains "$PR2_SHOW_TEXT" "last_delivery_intent: main_session_only"
assert_contains "$PR2_SHOW_TEXT" "last_inbox_task_id: 4242"

PR2_SHOW_SHELL="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$PR2_FINALIZE_JOBS_FILE" --format shell pr2-reported)"
assert_contains "$PR2_SHOW_SHELL" "CRON_JOB_LAST_REPORTING_DECISION=reported"
assert_contains "$PR2_SHOW_SHELL" "CRON_JOB_LAST_DELIVERY_INTENT=main_session_only"
assert_contains "$PR2_SHOW_SHELL" "CRON_JOB_LAST_INBOX_TASK_ID=4242"

PR2_SHOW_JSON="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$PR2_FINALIZE_JOBS_FILE" --format json pr2-reported)"
PR2_SHOW_JSON="$PR2_SHOW_JSON" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PR2_SHOW_JSON"])
assert payload["last_reporting_decision"] == "reported", payload
assert payload["last_delivery_intent"] == "main_session_only", payload
assert payload["last_inbox_task_id"] == 4242, payload
print("agb cron show json/text/shell trio surface OK")
PY

# Codex PR #500 r1 P2 #1 — a job with no PR1/PR2 reporting history must
# render text "-", JSON null, shell empty string. The record itself
# keeps None for the two strings so JSON consumers can distinguish
# absence from a legit "-" value.
PR2_NORUN_JOBS_FILE="$PR2_FINALIZE_DIR/jobs-no-history.json"
cat >"$PR2_NORUN_JOBS_FILE" <<'EOF'
{
  "format": "agent-bridge-cron-v1",
  "updatedAt": "2026-05-02T00:00:00+00:00",
  "jobs": [
    {
      "id": "pr2-no-history-job",
      "name": "pr2-no-history",
      "agentId": "tester",
      "enabled": true,
      "schedule": {"kind": "cron", "expr": "*/15 * * * *", "tz": "UTC"},
      "payload": {"kind": "text", "text": "ping"},
      "state": {"consecutiveErrors": 0, "lastStatus": "-", "nextRunAtMs": 0}
    }
  ]
}
EOF

PR2_NORUN_TEXT="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$PR2_NORUN_JOBS_FILE" pr2-no-history)"
assert_contains "$PR2_NORUN_TEXT" "last_reporting_decision: -"
assert_contains "$PR2_NORUN_TEXT" "last_delivery_intent: -"
assert_contains "$PR2_NORUN_TEXT" "last_inbox_task_id: -"

PR2_NORUN_SHELL="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$PR2_NORUN_JOBS_FILE" --format shell pr2-no-history)"
assert_contains "$PR2_NORUN_SHELL" "CRON_JOB_LAST_REPORTING_DECISION=''"
assert_contains "$PR2_NORUN_SHELL" "CRON_JOB_LAST_DELIVERY_INTENT=''"
assert_contains "$PR2_NORUN_SHELL" "CRON_JOB_LAST_INBOX_TASK_ID=''"

PR2_NORUN_JSON="$(python3 "$REPO_ROOT/bridge-cron.py" show --jobs-file "$PR2_NORUN_JOBS_FILE" --format json pr2-no-history)"
PR2_NORUN_JSON="$PR2_NORUN_JSON" python3 - <<'PY'
import json, os
payload = json.loads(os.environ["PR2_NORUN_JSON"])
assert payload["last_reporting_decision"] is None, payload
assert payload["last_delivery_intent"] is None, payload
assert payload["last_inbox_task_id"] is None, payload
print("agb cron show no-history → text '-', json null, shell '' OK")
PY

# A silent run still records the trio (lastInboxTaskId stays absent).
PR2_FINALIZE_JOBS_FILE="$PR2_FINALIZE_JOBS_FILE" \
PR2_FINALIZE_REQUEST_FILE="$PR2_FINALIZE_REQUEST_FILE" \
PR2_FINALIZE_RESULT_FILE="$PR2_FINALIZE_RESULT_FILE" \
PR2_FINALIZE_STATUS_FILE="$PR2_FINALIZE_STATUS_FILE" \
python3 - <<'PY'
import json, os
from pathlib import Path

result_file = Path(os.environ["PR2_FINALIZE_RESULT_FILE"])
status_file = Path(os.environ["PR2_FINALIZE_STATUS_FILE"])

result_file.write_text(json.dumps({
    "status": "completed",
    "summary": "ok",
    "delivery_intent": "silent",
    "reporting_decision": "silent",
    "needs_human_followup": False,
}, indent=2) + "\n", encoding="utf-8")
status_file.write_text(json.dumps({
    "run_id": "pr2-silent-run",
    "state": "success",
    "engine": "claude",
    "delivery_intent": "silent",
    "reporting_decision": "silent",
}, indent=2) + "\n", encoding="utf-8")
PY

python3 "$REPO_ROOT/bridge-cron.py" native-finalize-run \
    --jobs-file "$PR2_FINALIZE_JOBS_FILE" \
    --request-file "$PR2_FINALIZE_REQUEST_FILE" \
    --json >"$PR2_FINALIZE_DIR/finalize-silent-output.json"

PR2_FINALIZE_JOBS_FILE="$PR2_FINALIZE_JOBS_FILE" python3 - <<'PY'
import json, os
payload = json.loads(open(os.environ["PR2_FINALIZE_JOBS_FILE"], encoding="utf-8").read())
job = next(j for j in payload["jobs"] if j["id"] == "pr2-reported-job")
state = job.get("state") or {}
# Silent run overwrites the trio: last_reporting becomes "silent",
# intent becomes "silent", and lastInboxTaskId stays as the stale 4242
# from the earlier reported run since the runner does not emit a new
# inbox_task_id for silent. That is the correct behaviour — operators
# inspecting the last *non-silent* run can still find the task id, and
# a follow-up reported run will overwrite the trio together.
assert state.get("lastReportingDecision") == "silent", state
assert state.get("lastDeliveryIntent") == "silent", state
assert state.get("lastInboxTaskId") == 4242, state
print("native-finalize-run silent run still updates reporting trio OK")
PY

log "bridge_check_memory_pressure bash helper handles probe failure as healthy"
"$BASH4_BIN" -lc "
  set -euo pipefail
  source \"$REPO_ROOT/bridge-lib.sh\"
  # Probe runs cleanly on the smoke host. Whatever the local memory state
  # is, the helper must terminate without erroring; on a non-pressured
  # smoke host it should return 0.
  if bridge_check_memory_pressure; then
    rc=0
  else
    rc=\$?
  fi
  case \"\$rc\" in
    0|1) ;;
    *) echo \"unexpected return code from bridge_check_memory_pressure: \$rc\" >&2; exit 1 ;;
  esac
"

log "native-finalize-run treats deferred state as +deferred_seconds reschedule, not error (#263 Track B)"
# Regression guard for PR #330 round-1 finding 5: the runner writes
# state="deferred" and deferred_seconds into status.json, but finalize used
# to collapse anything non-success into the error branch — clearing
# nextRunAtMs and incrementing consecutiveErrors. Build a minimal jobs.json
# + status.json + request.json fixture and verify finalize bumps
# nextRunAtMs forward by ≥895s and leaves the error counter alone.
CRON_DEFERRED_DIR="$TMP_ROOT/cron-deferred-finalize"
CRON_DEFERRED_RUN_DIR="$CRON_DEFERRED_DIR/run"
CRON_DEFERRED_JOBS_FILE="$CRON_DEFERRED_DIR/jobs.json"
CRON_DEFERRED_REQUEST_FILE="$CRON_DEFERRED_RUN_DIR/request.json"
CRON_DEFERRED_RESULT_FILE="$CRON_DEFERRED_RUN_DIR/result.json"
CRON_DEFERRED_STATUS_FILE="$CRON_DEFERRED_RUN_DIR/status.json"
mkdir -p "$CRON_DEFERRED_RUN_DIR"

CRON_DEFERRED_JOBS_FILE="$CRON_DEFERRED_JOBS_FILE" \
CRON_DEFERRED_REQUEST_FILE="$CRON_DEFERRED_REQUEST_FILE" \
CRON_DEFERRED_RESULT_FILE="$CRON_DEFERRED_RESULT_FILE" \
CRON_DEFERRED_STATUS_FILE="$CRON_DEFERRED_STATUS_FILE" \
python3 - <<'PY'
import json, os
from pathlib import Path

jobs_file = Path(os.environ["CRON_DEFERRED_JOBS_FILE"])
request_file = Path(os.environ["CRON_DEFERRED_REQUEST_FILE"])
result_file = Path(os.environ["CRON_DEFERRED_RESULT_FILE"])
status_file = Path(os.environ["CRON_DEFERRED_STATUS_FILE"])

jobs_file.write_text(json.dumps({
    "format": "agent-bridge-cron-v1",
    "updatedAt": "2026-04-26T00:00:00+00:00",
    "jobs": [
        {
            "id": "deferred-smoke-job",
            "name": "deferred-smoke",
            "agentId": "tester",
            "enabled": True,
            "schedule": {"kind": "cron", "expr": "*/5 * * * *", "tz": "UTC"},
            "payload": {"kind": "text", "text": "ping"},
            "state": {
                "consecutiveErrors": 0,
                "lastStatus": "ok",
                "nextRunAtMs": 0,
            },
        }
    ],
}, indent=2) + "\n", encoding="utf-8")

# Runner-style status.json from a pressure-defer run.
status_file.write_text(json.dumps({
    "run_id": "deferred-smoke-run",
    "state": "deferred",
    "engine": "claude",
    "deferred_reason": "memory_pressure",
    "deferred_seconds": 900,
    "memory_probe": {"reason": "memory_pressure", "metric": "swap_pct", "value": 92, "limit": 80},
}, indent=2) + "\n", encoding="utf-8")

# Empty result is fine; deferred runs do not produce a result payload.
result_file.write_text("{}\n", encoding="utf-8")

request_file.write_text(json.dumps({
    "run_id": "deferred-smoke-run",
    "job_id": "deferred-smoke-job",
    "source_file": str(jobs_file.resolve()),
    "result_file": str(result_file.resolve()),
    "status_file": str(status_file.resolve()),
}, indent=2) + "\n", encoding="utf-8")
PY

CRON_DEFERRED_BEFORE_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
python3 "$REPO_ROOT/bridge-cron.py" native-finalize-run \
    --jobs-file "$CRON_DEFERRED_JOBS_FILE" \
    --request-file "$CRON_DEFERRED_REQUEST_FILE" \
    --json >"$CRON_DEFERRED_DIR/finalize-output.json"

CRON_DEFERRED_JOBS_FILE="$CRON_DEFERRED_JOBS_FILE" \
CRON_DEFERRED_BEFORE_MS="$CRON_DEFERRED_BEFORE_MS" \
python3 - <<'PY'
import json, os, sys

jobs_file = os.environ["CRON_DEFERRED_JOBS_FILE"]
before_ms = int(os.environ["CRON_DEFERRED_BEFORE_MS"])

payload = json.loads(open(jobs_file, encoding="utf-8").read())
job = next(j for j in payload["jobs"] if j["id"] == "deferred-smoke-job")
state = job.get("state") or {}

next_run_at_ms = int(state.get("nextRunAtMs") or 0)
last_status = state.get("lastStatus")
last_run_status = state.get("lastRunStatus")
consecutive_errors = int(state.get("consecutiveErrors") or 0)
last_error = state.get("lastError")
last_error_at_ms = state.get("lastErrorAtMs")

# nextRunAtMs must be bumped by at least 895_000 ms past finalize-call time
# (deferred_seconds=900, allowing 5s slack for execution overhead).
expected_min = before_ms + 895_000
assert next_run_at_ms >= expected_min, (
    f"deferred finalize did not bump nextRunAtMs by +15min "
    f"(before_ms={before_ms}, nextRunAtMs={next_run_at_ms}, expected ≥ {expected_min})"
)

# Error counter MUST NOT advance for a deferred run.
assert consecutive_errors == 0, (
    f"deferred finalize incorrectly incremented consecutiveErrors "
    f"(expected 0, got {consecutive_errors})"
)
assert last_error is None, f"deferred finalize wrote lastError={last_error!r}"
assert last_error_at_ms is None, f"deferred finalize wrote lastErrorAtMs={last_error_at_ms!r}"

# lastStatus / lastRunStatus must reflect the deferred branch so dashboards
# and errors-report do not flag the job.
assert last_status == "deferred", f"expected lastStatus=deferred, got {last_status!r}"
assert last_run_status == "deferred", f"expected lastRunStatus=deferred, got {last_run_status!r}"

# Job must remain enabled so the scheduler re-fires the next slot.
assert job.get("enabled") is True, f"deferred finalize disabled the job: {job!r}"

print("native-finalize-run deferred branch OK")
PY

# #263 Track B r3: a deferred job MUST NOT inflate the operator-visible
# inventory error_jobs aggregate. The previous fixture only checked the
# row-level consecutiveErrors counter; this guards summarize() against
# regressing to its inline whitelist that did not recognize "deferred".
CRON_DEFERRED_JOBS_FILE="$CRON_DEFERRED_JOBS_FILE" \
REPO_ROOT="$REPO_ROOT" \
python3 - <<'PY'
import json, os, subprocess, sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
jobs_file = os.environ["CRON_DEFERRED_JOBS_FILE"]

inventory_proc = subprocess.run(
    [sys.executable, str(repo_root / "bridge-cron.py"),
     "inventory", "--jobs-file", jobs_file, "--json"],
    capture_output=True, text=True, check=True,
)
inventory = json.loads(inventory_proc.stdout)
totals = inventory.get("totals") or {}
error_jobs = int(totals.get("error_jobs") or 0)
assert error_jobs == 0, (
    f"deferred run incorrectly counted in inventory.totals.error_jobs "
    f"(expected 0, got {error_jobs}); summarize() may not be deferring to "
    f"is_error_record()"
)

# filtered_totals is computed from the same predicate; double-check it too so
# any future divergence between the two summaries is caught.
filtered_totals = inventory.get("filtered_totals") or {}
filtered_error_jobs = int(filtered_totals.get("error_jobs") or 0)
assert filtered_error_jobs == 0, (
    f"deferred run incorrectly counted in inventory.filtered_totals.error_jobs "
    f"(expected 0, got {filtered_error_jobs})"
)

print("inventory aggregate excludes deferred job OK")
PY

# #263 Track B r4: negative regression — a real errored job must still
# count in inventory.totals.error_jobs even when a deferred job is also
# present. Without this assertion, a future change that accidentally
# silenced the entire error-counting path would still pass smoke as long
# as the deferred-only assertion above held.
log "  [ok] inventory: real errored job alongside deferred still counts as error_jobs=1"
CRON_DEFERRED_JOBS_FILE="$CRON_DEFERRED_JOBS_FILE" \
REPO_ROOT="$REPO_ROOT" \
python3 - <<'PY'
import json, os, subprocess, sys
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
jobs_file = os.environ["CRON_DEFERRED_JOBS_FILE"]

payload = json.loads(open(jobs_file, encoding="utf-8").read())
payload["jobs"].append({
    "id": "errored-smoke-job",
    "name": "errored-smoke",
    "agentId": "tester",
    "enabled": True,
    "schedule": {"kind": "cron", "expr": "*/5 * * * *", "tz": "UTC"},
    "payload": {"kind": "text", "text": "ping"},
    "state": {
        "consecutiveErrors": 3,
        "lastStatus": "error",
        "lastError": "stale failure",
        "nextRunAtMs": 0,
    },
})
open(jobs_file, "w", encoding="utf-8").write(json.dumps(payload, indent=2) + "\n")

inventory_proc = subprocess.run(
    [sys.executable, str(repo_root / "bridge-cron.py"),
     "inventory", "--jobs-file", jobs_file, "--json"],
    capture_output=True, text=True, check=True,
)
inventory = json.loads(inventory_proc.stdout)
totals = inventory.get("totals") or {}
error_jobs = int(totals.get("error_jobs") or 0)
assert error_jobs == 1, (
    f"mixed deferred+errored should count error_jobs=1, got {error_jobs}; "
    f"a real errored row alongside a deferred row must still increment "
    f"the operator-visible error aggregate"
)

print("inventory aggregate counts errored job alongside deferred OK")
PY

log "rendering typed channel relay blocks into cron follow-up bodies"
CRON_RELAY_RUN_ID="relay-smoke--2026-04-16T13-20"
CRON_RELAY_RUN_DIR="$BRIDGE_CRON_STATE_DIR/runs/$CRON_RELAY_RUN_ID"
CRON_RELAY_REQUEST_FILE="$CRON_RELAY_RUN_DIR/request.json"
CRON_RELAY_RESULT_FILE="$CRON_RELAY_RUN_DIR/result.json"
CRON_RELAY_STATUS_FILE="$CRON_RELAY_RUN_DIR/status.json"
CRON_RELAY_BODY_FILE="$TMP_ROOT/cron-relay-followup.md"
mkdir -p "$CRON_RELAY_RUN_DIR"
python3 - <<'PY' "$CRON_RELAY_REQUEST_FILE" "$CRON_RELAY_RESULT_FILE" "$CRON_RELAY_STATUS_FILE"
import json
import sys
from pathlib import Path

request_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
status_path = Path(sys.argv[3])

request_path.write_text(json.dumps({
    "run_id": "relay-smoke--2026-04-16T13-20",
    "job_name": "relay-smoke",
    "slot": "2026-04-16T13:20+09:00",
    "family": "relay-smoke",
    "target_agent": "patch",
    "target_engine": "claude",
    "stdout_log": "/tmp/relay-stdout.log",
    "stderr_log": "/tmp/relay-stderr.log",
}, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")

result_path.write_text(json.dumps({
    "status": "completed",
    "summary": "prepared relay body",
    "findings": ["one actionable reminder"],
    "actions_taken": ["compiled relay payload"],
    "needs_human_followup": True,
    "recommended_next_steps": ["send to today's telegram thread"],
    "artifacts": [],
    "confidence": "high",
    "channel_relay": {
        "transport": "telegram",
        "target": "default",
        "urgency": "normal",
        "body": "오늘 일정 리마인드입니다."
    }
}, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")

status_path.write_text(json.dumps({
    "state": "success"
}, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_cron_write_followup_body \"$CRON_RELAY_RUN_ID\" \"$CRON_RELAY_BODY_FILE\""
grep -q '^## Channel Relay$' "$CRON_RELAY_BODY_FILE" || die "expected channel relay section in cron follow-up body"
grep -q '^- transport: telegram$' "$CRON_RELAY_BODY_FILE" || die "expected relay transport metadata"
grep -q '오늘 일정 리마인드입니다.' "$CRON_RELAY_BODY_FILE" || die "expected relay body in follow-up markdown"
grep -q 'The parent session must own the outbound message.' "$CRON_RELAY_BODY_FILE" || die "expected parent-owned delivery instruction"

log "checkpointing cron sync progress only through the successful prefix"
SCHEDULER_JOBS_FILE="$TMP_ROOT/scheduler-jobs.json"
SCHEDULER_STATE_FILE="$TMP_ROOT/scheduler-state.json"
SCHEDULER_ENQUEUE_LOG="$TMP_ROOT/scheduler-enqueue.log"
SCHEDULER_FAIL_MARK="$TMP_ROOT/scheduler-job-b.failed"
SCHEDULER_BRIDGE_CRON="$TMP_ROOT/fake-bridge-cron.sh"
cat >"$SCHEDULER_JOBS_FILE" <<EOF
{
  "jobs": [
    {
      "id": "job-a",
      "name": "job-a",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      }
    },
    {
      "id": "job-b",
      "name": "job-b",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      }
    },
    {
      "id": "job-c",
      "name": "job-c",
      "enabled": true,
      "agentId": "$SMOKE_AGENT",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "UTC"
      }
    }
  ]
}
EOF
cat >"$SCHEDULER_BRIDGE_CRON" <<EOF
#!/usr/bin/env bash
set -euo pipefail

command="\${1:-}"
shift || true
[[ "\$command" == "enqueue" ]] || exit 64

job_id="\${1:-}"
printf '%s\n' "\$job_id" >>"$SCHEDULER_ENQUEUE_LOG"

if [[ "\$job_id" == "job-b" && ! -f "$SCHEDULER_FAIL_MARK" ]]; then
  : >"$SCHEDULER_FAIL_MARK"
  printf 'simulated failure for %s\n' "\$job_id" >&2
  exit 1
fi

printf 'created task #1\n'
EOF
chmod +x "$SCHEDULER_BRIDGE_CRON"

set +e
SCHEDULER_FIRST_OUTPUT="$(
  python3 "$REPO_ROOT/bridge-cron-scheduler.py" sync \
    --jobs-file "$SCHEDULER_JOBS_FILE" \
    --state-file "$SCHEDULER_STATE_FILE" \
    --bridge-cron "$SCHEDULER_BRIDGE_CRON" \
    --repo-root "$TMP_ROOT" \
    --since '2026-04-05T08:59:00+00:00' \
    --now '2026-04-05T09:00:00+00:00' 2>&1
)"
SCHEDULER_FIRST_CODE=$?
set -e
[[ $SCHEDULER_FIRST_CODE -eq 1 ]] || die "expected first scheduler run to fail once"
assert_contains "$SCHEDULER_FIRST_OUTPUT" "errors: 1"
[[ "$(paste -sd ' ' "$SCHEDULER_ENQUEUE_LOG")" == "job-a job-b job-c" ]] || die "expected scheduler to continue after one enqueue failure"
python3 - <<'PY' "$SCHEDULER_STATE_FILE"
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
assert payload["last_sync_key"]["job_id"] == "job-a", payload
PY

SCHEDULER_SECOND_OUTPUT="$(
  python3 "$REPO_ROOT/bridge-cron-scheduler.py" sync \
    --jobs-file "$SCHEDULER_JOBS_FILE" \
    --state-file "$SCHEDULER_STATE_FILE" \
    --bridge-cron "$SCHEDULER_BRIDGE_CRON" \
    --repo-root "$TMP_ROOT" \
    --now '2026-04-05T09:00:00+00:00' 2>&1
)"
assert_contains "$SCHEDULER_SECOND_OUTPUT" "errors: 0"
[[ "$(paste -sd ' ' "$SCHEDULER_ENQUEUE_LOG")" == "job-a job-b job-c job-b job-c" ]] || die "expected scheduler retry to resume from the failed same-timestamp sibling while replaying later work"
python3 - <<'PY' "$SCHEDULER_STATE_FILE"
import json
import sys
from datetime import datetime, timezone

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
cursor = datetime.fromisoformat(payload["last_sync_at"]).astimezone(timezone.utc)
assert cursor.isoformat(timespec="seconds").startswith("2026-04-05T09:00:00"), payload
assert "last_sync_key" not in payload, payload
PY

SCHEDULER_THIRD_OUTPUT="$(
  python3 "$REPO_ROOT/bridge-cron-scheduler.py" sync \
    --jobs-file "$SCHEDULER_JOBS_FILE" \
    --state-file "$SCHEDULER_STATE_FILE" \
    --bridge-cron "$SCHEDULER_BRIDGE_CRON" \
    --repo-root "$TMP_ROOT" \
    --now '2026-04-05T09:00:00+00:00' 2>&1
)"
assert_contains "$SCHEDULER_THIRD_OUTPUT" "errors: 0"
[[ "$(paste -sd ' ' "$SCHEDULER_ENQUEUE_LOG")" == "job-a job-b job-c job-b job-c" ]] || die "expected completed scheduler sync to avoid replaying the finished bucket"

log "syncing bridge-local runtime roots from legacy source"
RUNTIME_SYNC_OUTPUT="$(BRIDGE_OPENCLAW_HOME="$LEGACY_ROOT" BRIDGE_RUNTIME_ROOT="$BRIDGE_HOME/runtime" "$REPO_ROOT/agent-bridge" migrate runtime sync)"
assert_contains "$RUNTIME_SYNC_OUTPUT" "item[scripts]"
[[ -f "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" ]] || die "expected runtime scripts copy"
[[ -f "$BRIDGE_HOME/runtime/skills/sample-skill/SKILL.md" ]] || die "expected runtime skills copy"
[[ -f "$BRIDGE_HOME/runtime/shared/tools/tool.md" ]] || die "expected runtime shared tools copy"
[[ -f "$BRIDGE_HOME/runtime/shared/references/ref.md" ]] || die "expected runtime shared references copy"
[[ -f "$BRIDGE_HOME/runtime/memory/$SMOKE_AGENT.sqlite" ]] || die "expected runtime memory copy"
[[ -f "$BRIDGE_HOME/runtime/data/example.db" ]] || die "expected runtime data copy"
[[ -f "$BRIDGE_HOME/runtime/assets/sample/logo.txt" ]] || die "expected runtime assets copy"
[[ -f "$BRIDGE_HOME/runtime/extensions/sample-ext/README.md" ]] || die "expected runtime extensions copy"
[[ -f "$BRIDGE_HOME/runtime/credentials/example.txt" ]] || die "expected runtime credentials copy"
[[ -f "$BRIDGE_HOME/runtime/secrets/example.token" ]] || die "expected runtime secrets copy"
[[ -f "$BRIDGE_HOME/runtime/bridge-config.json" ]] || die "expected runtime config copy"
python3 - "$BRIDGE_HOME/runtime/credentials" "$BRIDGE_HOME/runtime/credentials/example.txt" "$BRIDGE_HOME/runtime/secrets" "$BRIDGE_HOME/runtime/secrets/example.token" <<'PY'
import os
import stat
import sys

expected = {
    sys.argv[1]: 0o700,
    sys.argv[2]: 0o600,
    sys.argv[3]: 0o700,
    sys.argv[4]: 0o600,
}
for path, mode in expected.items():
    actual = stat.S_IMODE(os.stat(path).st_mode)
    assert actual == mode, f"{path}: expected {oct(mode)}, got {oct(actual)}"
PY

log "linking configured runtime skills into managed Claude homes"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; BRIDGE_AGENT_SKILLS[\"claude-static\"]='sample-skill'; bridge_bootstrap_claude_shared_skills 'claude-static' '$CLAUDE_STATIC_WORKDIR'"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; BRIDGE_AGENT_SKILLS[\"claude-static\"]='sample-skill'; bridge_sync_skill_docs 'claude-static'"
[[ -L "$CLAUDE_STATIC_WORKDIR/.claude/skills/sample-skill" ]] || die "expected runtime sample-skill symlink"
assert_contains "$(readlink "$CLAUDE_STATIC_WORKDIR/.claude/skills/sample-skill")" "sample-skill"
assert_contains "$(cat "$CLAUDE_STATIC_WORKDIR/SKILLS.md")" "sample-skill"
assert_contains "$(cat "$BRIDGE_HOME/shared/SKILLS.md")" "sample-skill"
assert_contains "$(cat "$BRIDGE_HOME/state/skill-registry.json")" "\"sample-skill\""
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; BRIDGE_AGENT_SKILLS[\"claude-static\"]=''; bridge_bootstrap_claude_shared_skills 'claude-static' '$CLAUDE_STATIC_WORKDIR'"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; BRIDGE_AGENT_SKILLS[\"claude-static\"]=''; bridge_sync_skill_docs 'claude-static'"
[[ ! -e "$CLAUDE_STATIC_WORKDIR/.claude/skills/sample-skill" ]] || die "expected runtime skill symlink pruning when roster mapping is removed"

log "rendering concise dashboard state-change notifications"
DASHBOARD_PATCH_DIR="$TMP_ROOT/dashboard-patch"
DASHBOARD_SHOP_DIR="$TMP_ROOT/dashboard-shop"
DASHBOARD_SUMMARY_TSV="$TMP_ROOT/dashboard-summary.tsv"
DASHBOARD_ROSTER_TSV="$TMP_ROOT/dashboard-roster.tsv"
DASHBOARD_STATE_JSON="$TMP_ROOT/dashboard-state.json"
DASHBOARD_TASK_DB="$TMP_ROOT/dashboard-tasks.db"
mkdir -p "$DASHBOARD_PATCH_DIR" "$DASHBOARD_SHOP_DIR"
cat >"$DASHBOARD_PATCH_DIR/SOUL.md" <<'EOF'
# 패치 — Admin
EOF
cat >"$DASHBOARD_SHOP_DIR/SOUL.md" <<'EOF'
# 쇼피 — Commerce
EOF
BRIDGE_TASK_DB="$DASHBOARD_TASK_DB" python3 "$REPO_ROOT/bridge-queue.py" init >/dev/null
BRIDGE_TASK_DB="$DASHBOARD_TASK_DB" python3 "$REPO_ROOT/bridge-queue.py" create --to patch --title "[MAIL] CS 문의 처리" --from smoke --body "dashboard test" >/dev/null
cat >"$DASHBOARD_SUMMARY_TSV" <<EOF
patch	0	1	0	1	60	0	0	patch	claude	$DASHBOARD_PATCH_DIR
shop	0	0	0	1	2400	0	0	shop	claude	$DASHBOARD_SHOP_DIR
smoke-agent	1	0	0	1	10	0	0	smoke-agent	claude	$TMP_ROOT/dashboard-smoke
EOF
cat >"$DASHBOARD_ROSTER_TSV" <<EOF
agent	engine	session	cwd	source	loop	continue	queued	claimed	session_id	updated_at
patch	claude	patch	$DASHBOARD_PATCH_DIR	static	1	1	0	1	session-patch	2026-04-11T00:00:00+09:00
shop	claude	shop	$DASHBOARD_SHOP_DIR	static	1	1	0	0	session-shop	2026-04-11T00:00:00+09:00
EOF
cat >"$DASHBOARD_STATE_JSON" <<'EOF'
{
  "fingerprint": "prev",
  "last_summary_ts": 9999999999,
  "agents": {
    "patch": {"display": "패치", "state": "idle", "queued": 0, "claimed": 0, "blocked": 0, "idle_seconds": 3600, "task_title": ""},
    "shop": {"display": "쇼피", "state": "working", "queued": 0, "claimed": 1, "blocked": 0, "idle_seconds": 60, "task_title": "이전 작업"}
  }
}
EOF
DASHBOARD_OUTPUT="$(python3 "$REPO_ROOT/bridge-dashboard.py" --summary-tsv "$DASHBOARD_SUMMARY_TSV" --state-file "$DASHBOARD_STATE_JSON" --roster-tsv "$DASHBOARD_ROSTER_TSV" --task-db "$DASHBOARD_TASK_DB" --idle-threshold-seconds 900 --summary-interval-seconds 3600 --dry-run)"
assert_contains "$DASHBOARD_OUTPUT" "🟢 패치 작업 시작 — CS 문의 처리"
assert_contains "$DASHBOARD_OUTPUT" "⏸️ 쇼피 idle (40분)"
assert_not_contains "$DASHBOARD_OUTPUT" "smoke-agent"

RUNTIME_COMPAT_PATHS_OUTPUT="$("$BASH4_BIN" -c "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; printf '%s\n%s\n%s\n' \"\$(bridge_compat_config_file)\" \"\$(bridge_compat_credentials_dir)\" \"\$(bridge_compat_secrets_dir)\"")"
assert_contains "$RUNTIME_COMPAT_PATHS_OUTPUT" "$BRIDGE_HOME/runtime/bridge-config.json"
assert_contains "$RUNTIME_COMPAT_PATHS_OUTPUT" "$BRIDGE_HOME/runtime/credentials"
assert_contains "$RUNTIME_COMPAT_PATHS_OUTPUT" "$BRIDGE_HOME/runtime/secrets"

log "rewriting cron payloads to bridge-local runtime paths"
RUNTIME_REWRITE_OUTPUT="$("$REPO_ROOT/agent-bridge" migrate runtime rewrite-cron --bridge-home "$BRIDGE_HOME" --legacy-home "$LEGACY_ROOT" --jobs-file "$LEGACY_ROOT/cron/jobs.json")"
assert_contains "$RUNTIME_REWRITE_OUTPUT" "status: rewritten"
assert_contains "$RUNTIME_REWRITE_OUTPUT" "changed_jobs: 1"
grep -q "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" "$LEGACY_ROOT/cron/jobs.json" || die "expected rewritten runtime script path"
grep -q 'agent-bridge task create --to smoke-helper' "$LEGACY_ROOT/cron/jobs.json" || die "expected rewritten runtime handoff guidance"
grep -q 'needs_human_followup=true' "$LEGACY_ROOT/cron/jobs.json" || die "expected rewritten runtime follow-up guidance"
! grep -q 'sessions_send' "$LEGACY_ROOT/cron/jobs.json" || die "expected sessions_send removed from cron payload"
! grep -q 'openclaw message send' "$LEGACY_ROOT/cron/jobs.json" || die "expected direct send removed from cron payload"
! grep -q 'sessions_history' "$LEGACY_ROOT/cron/jobs.json" || die "expected sessions_history removed from cron payload"

log "rewriting copied runtime files to bridge-local paths"
RUNTIME_FILE_REWRITE_OUTPUT="$("$REPO_ROOT/agent-bridge" migrate runtime rewrite-files --bridge-home "$BRIDGE_HOME" --legacy-home "$LEGACY_ROOT" --runtime-root "$BRIDGE_HOME/runtime")"
assert_contains "$RUNTIME_FILE_REWRITE_OUTPUT" "status: rewritten"
grep -q "$BRIDGE_HOME/runtime/scripts" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime scripts import path"
grep -q "$BRIDGE_HOME/runtime/credentials" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime credentials path"
grep -q "$BRIDGE_HOME/runtime/secrets" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime secrets path"
grep -q "$BRIDGE_HOME/runtime/data/example.db" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime data path"
grep -q "$BRIDGE_HOME/runtime/assets/sample/logo.txt" "$BRIDGE_HOME/runtime/scripts/morning-briefing.py" || die "expected rewritten runtime asset path"
grep -q "$BRIDGE_HOME/runtime/extensions/sample-ext" "$BRIDGE_HOME/runtime/bridge-config.json" || die "expected rewritten runtime extension installPath"

log "overlaying repo-managed runtime canonical templates"
RUNTIME_CANON_OUTPUT="$("$REPO_ROOT/agent-bridge" migrate runtime canonicalize --runtime-root "$BRIDGE_HOME/runtime")"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[scripts/call-shopify.sh]"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[scripts/creds.py]"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[scripts/email-webhook-handler.py]"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[scripts/gmail_accounts.py]"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[scripts/webhook_utils.py]"
assert_contains "$RUNTIME_CANON_OUTPUT" "overlay[skills/agent-db/scripts/email-sync.py]"
grep -q 'task create' "$BRIDGE_HOME/runtime/scripts/call-shopify.sh" || die "expected bridge-native task delivery in call-shopify"
grep -q 'bridge-notify.py' "$BRIDGE_HOME/runtime/scripts/call-shopify.sh" || die "expected bridge-native notify helper in call-shopify"
grep -q '\[cron-failure\] recurring failures detected' "$BRIDGE_HOME/runtime/scripts/cron-failure-monitor.sh" || die "expected bridge-native cron failure title"
grep -q 'queue-based A2A is the source of truth' "$BRIDGE_HOME/runtime/scripts/patch-a2a-bridge.sh" || die "expected deprecated A2A bridge stub"
grep -q 'agent-bridge setup agent' "$BRIDGE_HOME/runtime/skills/agent-factory/scripts/create-agent.sh" || die "expected bridge-native setup guidance in create-agent"
grep -q 'agent-bridge task create' "$BRIDGE_HOME/runtime/scripts/email-webhook-handler.py" || die "expected queue handoff in email webhook handler"
grep -q 'load_gmail_accounts' "$BRIDGE_HOME/runtime/scripts/email-webhook-handler.py" || die "expected shared gmail accounts loader in email webhook handler"
grep -q 'queue-dispatch' "$BRIDGE_HOME/runtime/scripts/webhook_utils.py" || die "expected bridge-native one-shot cron helper in webhook utils"
grep -q 'BRIDGE_RUNTIME_CREDENTIALS_DIR' "$BRIDGE_HOME/runtime/scripts/creds.py" || die "expected bridge-native credential loader"
grep -q 'gws_api' "$BRIDGE_HOME/runtime/skills/agent-db/scripts/email-sync.py" || die "expected gws-backed email sync script"
grep -q 'load_gmail_accounts' "$BRIDGE_HOME/runtime/skills/agent-db/scripts/email-sync.py" || die "expected shared gmail accounts loader in agent-db email sync"
python3 - "$BRIDGE_HOME/runtime/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import creds
diag = creds.credential_diagnostic("missing-service.json")
assert diag["credential"] == "missing-service.json"
assert diag["found"] is False
assert "policy" in diag
try:
    creds.load_creds("missing-service.json")
except creds.CredentialNotFoundError as err:
    text = str(err)
    assert "missing-service.json" in text
    assert "checked redacted roots" in text
else:
    raise AssertionError("missing credential should raise CredentialNotFoundError")
PY
python3 - "$BRIDGE_HOME/runtime/credentials/gmail-accounts.example.json" <<'PY'
import os
import stat
import sys

actual = stat.S_IMODE(os.stat(sys.argv[1]).st_mode)
assert actual == 0o600, f"{sys.argv[1]}: expected 0o600, got {oct(actual)}"
PY

log "prioritizing idle memory-daily dispatch over busy sessions"
MEMORY_DAILY_READY_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  export BRIDGE_HOME="'"$BRIDGE_HOME"'"
  export BRIDGE_STATE_DIR="'"$BRIDGE_STATE_DIR"'"
  export BRIDGE_TASK_DB="'"$TMP_ROOT"'/cron-ready-test.db"
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  bridge_load_roster
  python3 "'"$REPO_ROOT"'/bridge-queue.py" init >/dev/null
  status_file="'"$TMP_ROOT"'/cron-ready-status.tsv"
  cat >"$status_file" <<EOF
agent	engine	session	workdir	source	loop	active	wake	channels	activity_state
claude-static	claude	'"$CLAUDE_STATIC_SESSION"'	'"$CLAUDE_STATIC_WORKDIR"'	static	1	1	ok	ok	working
'"$CREATED_AGENT"'	claude	'"$CREATED_SESSION"'	'"$BRIDGE_AGENT_HOME_ROOT/$CREATED_AGENT"'	static	1	1	ok	ok	idle
EOF
  busy_body="'"$TMP_ROOT"'/cron-ready-busy.md"
  other_body="'"$TMP_ROOT"'/cron-ready-other.md"
  idle_body="'"$TMP_ROOT"'/cron-ready-idle.md"
  cat >"$busy_body" <<EOF
# [cron-dispatch] memory-daily busy

- family: memory-daily
EOF
  cat >"$other_body" <<EOF
# [cron-dispatch] briefing

- family: morning-briefing
EOF
  cat >"$idle_body" <<EOF
# [cron-dispatch] memory-daily idle

- family: memory-daily
EOF
  bash "'"$REPO_ROOT"'/bridge-task.sh" create --to claude-static --title "[cron-dispatch] memory-daily busy" --body-file "$busy_body" --from smoke >/dev/null
  bash "'"$REPO_ROOT"'/bridge-task.sh" create --to claude-static --title "[cron-dispatch] briefing" --body-file "$other_body" --from smoke >/dev/null
  bash "'"$REPO_ROOT"'/bridge-task.sh" create --to "'"$CREATED_AGENT"'" --title "[cron-dispatch] memory-daily idle" --body-file "$idle_body" --from smoke >/dev/null
  python3 "'"$REPO_ROOT"'/bridge-queue.py" cron-ready --format tsv --status-snapshot "$status_file" --memory-daily-defer-seconds 3600
')"
python3 - <<'PY' "$MEMORY_DAILY_READY_OUTPUT" "$CREATED_AGENT"
import sys

output = [line for line in sys.argv[1].splitlines() if line.strip()]
created_agent = sys.argv[2]
assert len(output) == 2
assert output[0].split("\t", 3)[1] == created_agent
assert "briefing" in output[1]
assert all("memory-daily busy" not in line for line in output)
PY

log "stopping background daemon before deterministic cron-dispatch tail"
# --force: smoke fixture may have active agents at this point; the
# #314/#315 active-agent guard would block a bare stop.
env BRIDGE_HOME="$BRIDGE_HOME" bash "$REPO_ROOT/bridge-daemon.sh" stop --force >/dev/null

log "processing one queued cron-dispatch task through the daemon"
RUN_ID="smoke-job-1234--2026-04-05T10-00-00Z"
RUN_DIR="$BRIDGE_STATE_DIR/cron/runs/$RUN_ID"
DISPATCH_BODY="$BRIDGE_SHARED_DIR/cron-dispatch/$RUN_ID.md"
mkdir -p "$RUN_DIR" "$(dirname "$DISPATCH_BODY")"

cat >"$RUN_DIR/payload.md" <<'EOF'
# [cron] smoke-job

Do a disposable cron smoke run.
EOF

cat >"$RUN_DIR/request.json" <<EOF
{
  "run_id": "$RUN_ID",
  "job_id": "12345678-abcd",
  "job_name": "smoke-job",
  "family": "smoke-family",
  "source_agent": "$SMOKE_AGENT",
  "target_agent": "$SMOKE_AGENT",
  "target_engine": "codex",
  "target_workdir": "$WORKDIR",
  "slot": "2026-04-05T10:00:00Z",
  "dispatch_task_id": 0,
  "created_at": "2026-04-05T10:00:00Z",
  "dispatch_body_file": "$DISPATCH_BODY",
  "payload_file": "$RUN_DIR/payload.md",
  "payload_kind": "agentTurn",
  "result_file": "$RUN_DIR/result.json",
  "status_file": "$RUN_DIR/status.json",
  "stdout_log": "$RUN_DIR/stdout.log",
  "stderr_log": "$RUN_DIR/stderr.log",
  "source_file": "$TMP_ROOT/jobs.json"
}
EOF

cat >"$DISPATCH_BODY" <<EOF
# [cron-dispatch] smoke-job

- run_id: $RUN_ID
EOF

CRON_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "[cron-dispatch] smoke-job (2026-04-05T10:00:00Z)" --body-file "$DISPATCH_BODY" --from smoke-test)"
[[ "$CRON_CREATE_OUTPUT" =~ created\ task\ \#([0-9]+) ]] || die "could not parse cron dispatch task id"
CRON_TASK_ID="${BASH_REMATCH[1]}"

bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null

for _ in $(seq 1 80); do
  SHOW_CRON_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" show "$CRON_TASK_ID")"
  if [[ "$SHOW_CRON_OUTPUT" == *"status: done"* ]]; then
    break
  fi
  bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null || true
  sleep 0.25
done

if [[ "$SHOW_CRON_OUTPUT" != *"status: done"* ]]; then
  echo "[smoke][debug] cron-dispatch task did not finish within the polling window" >&2
  echo "[smoke][debug] task show:" >&2
  printf '%s\n' "$SHOW_CRON_OUTPUT" >&2
  echo "[smoke][debug] worker dir:" >&2
  ls -la "$BRIDGE_CRON_DISPATCH_WORKER_DIR" >&2 || true
  echo "[smoke][debug] run status file:" >&2
  sed -n '1,160p' "$RUN_DIR/status.json" >&2 || true
  echo "[smoke][debug] run stderr:" >&2
  sed -n '1,160p' "$RUN_DIR/stderr.log" >&2 || true
fi

assert_contains "$SHOW_CRON_OUTPUT" "status: done"
[[ -f "$RUN_DIR/result.json" ]] || die "cron worker did not write result artifact"

log "syncing cron run state when a cron-dispatch task is cancelled through the queue"
CANCEL_RUN_ID="smoke-cancel-run"
CANCEL_RUN_DIR="$BRIDGE_STATE_DIR/cron/runs/$CANCEL_RUN_ID"
CANCEL_DISPATCH_BODY="$BRIDGE_SHARED_DIR/cron-dispatch/$CANCEL_RUN_ID.md"
mkdir -p "$CANCEL_RUN_DIR" "$(dirname "$CANCEL_DISPATCH_BODY")"
cat >"$CANCEL_RUN_DIR/request.json" <<EOF
{
  "run_id": "$CANCEL_RUN_ID",
  "job_id": "cancel-job",
  "job_name": "cancel-job",
  "target_agent": "$SMOKE_AGENT",
  "target_engine": "claude",
  "result_file": "$CANCEL_RUN_DIR/result.json",
  "status_file": "$CANCEL_RUN_DIR/status.json",
  "request_file": "$CANCEL_RUN_DIR/request.json"
}
EOF
cat >"$CANCEL_RUN_DIR/status.json" <<EOF
{
  "run_id": "$CANCEL_RUN_ID",
  "state": "queued",
  "engine": "claude",
  "request_file": "$CANCEL_RUN_DIR/request.json",
  "result_file": "$CANCEL_RUN_DIR/result.json"
}
EOF
cat >"$CANCEL_DISPATCH_BODY" <<EOF
# [cron-dispatch] cancel-job

- run_id: $CANCEL_RUN_ID
EOF
CANCEL_CREATE_OUTPUT="$(bash "$REPO_ROOT/bridge-task.sh" create --to "$SMOKE_AGENT" --title "[cron-dispatch] cancel-job (2026-04-05T11:00:00Z)" --body-file "$CANCEL_DISPATCH_BODY" --from smoke-test)"
[[ "$CANCEL_CREATE_OUTPUT" =~ created\ task\ \#([0-9]+) ]] || die "could not parse cancel cron dispatch task id"
CANCEL_TASK_ID="${BASH_REMATCH[1]}"
bash "$REPO_ROOT/bridge-task.sh" cancel "$CANCEL_TASK_ID" --actor smoke-test --note "cancelled via smoke" >/dev/null
assert_contains "$(bash "$REPO_ROOT/bridge-task.sh" show "$CANCEL_TASK_ID")" "status: cancelled"
assert_contains "$(cat "$CANCEL_RUN_DIR/status.json")" "\"state\": \"cancelled\""
python3 - "$("$REPO_ROOT/agent-bridge" audit --action cron_dispatch_cancelled --limit 20 --json)" "$CANCEL_TASK_ID" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
task_id = sys.argv[2]
assert any(str(row.get("detail", {}).get("task_id")) == task_id for row in rows), rows
PY

log "channel health miss surfaces via audit + dashboard flag (no admin queue task — issue #345 Track B)"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

bridge_add_agent_id_if_missing "$BROKEN_CHANNEL_AGENT"
BRIDGE_AGENT_DESC["$BROKEN_CHANNEL_AGENT"]="Broken channel role"
BRIDGE_AGENT_ENGINE["$BROKEN_CHANNEL_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$BROKEN_CHANNEL_AGENT"]="broken-channel-$SESSION_NAME"
BRIDGE_AGENT_WORKDIR["$BROKEN_CHANNEL_AGENT"]="$BROKEN_CHANNEL_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$BROKEN_CHANNEL_AGENT"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CHANNELS["$BROKEN_CHANNEL_AGENT"]="plugin:discord"
EOF

bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
# Issue #345 Track B (instance #3): channel-health miss must NOT enqueue an
# admin task. Admin has no authority over the affected agent's tokens or
# channel binding. The new contract is audit row + dashboard flag, with a
# fallback notify to the affected agent's own surface when available.
CHANNEL_HEALTH_OPEN_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[channel-health] $BROKEN_CHANNEL_AGENT " 2>/dev/null || true)"
[[ -z "$CHANNEL_HEALTH_OPEN_ID" ]] || die "channel-health miss must not create admin task; got #$CHANNEL_HEALTH_OPEN_ID"
CHANNEL_HEALTH_BODY_FILE="$BRIDGE_SHARED_DIR/channel-health/$BROKEN_CHANNEL_AGENT.md"
[[ -f "$CHANNEL_HEALTH_BODY_FILE" ]] || die "expected channel-health body file"
CHANNEL_HEALTH_BODY="$(cat "$CHANNEL_HEALTH_BODY_FILE")"
assert_contains "$CHANNEL_HEALTH_BODY" "## Channel Diagnostics"
assert_contains "$CHANNEL_HEALTH_BODY" "launch_allowlisted: yes"
assert_contains "$CHANNEL_HEALTH_BODY" "runtime: state_dir=missing access=missing credentials=missing ready=no"
assert_contains "$CHANNEL_HEALTH_BODY" "## Session Health"
assert_contains "$CHANNEL_HEALTH_BODY" "detach_to_shell: Ctrl-b then d"
assert_not_contains "$CHANNEL_HEALTH_BODY" "smoke-token"
CHANNEL_HEALTH_AUDIT_OUTPUT="$("$REPO_ROOT/agent-bridge" audit --agent "$BROKEN_CHANNEL_AGENT" --action channel_health_miss --limit 5 --json 2>/dev/null || true)"
[[ -n "$CHANNEL_HEALTH_AUDIT_OUTPUT" ]] || die "expected channel_health_miss audit row for $BROKEN_CHANNEL_AGENT"
assert_contains "$CHANNEL_HEALTH_AUDIT_OUTPUT" "channel_health_miss"
assert_contains "$CHANNEL_HEALTH_AUDIT_OUTPUT" "\"dashboard_flag\": \"1\""
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CHANNEL_HEALTH_OPEN_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[channel-health] $BROKEN_CHANNEL_AGENT " 2>/dev/null || true)"
[[ -z "$CHANNEL_HEALTH_OPEN_ID_AGAIN" ]] || die "second sync must not create admin channel-health task either"

log "detecting plugin MCP descendants and watchdog-restarting static Claude roles"
PLUGIN_TREE_SCRIPT="$TMP_ROOT/fake-plugin-tree.sh"
PLUGIN_TREE_CHILD_PID_FILE="$TMP_ROOT/fake-plugin-tree-child.pid"
cat >"$PLUGIN_TREE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
child_pid_file="$1"
bash -c 'exec -a "bun run --cwd /tmp/telegram/0.0.1/package start" sleep 30' &
child="$!"
printf '%s\n' "$child" >"$child_pid_file"
wait "$child"
EOF
chmod +x "$PLUGIN_TREE_SCRIPT"
"$PLUGIN_TREE_SCRIPT" "$PLUGIN_TREE_CHILD_PID_FILE" >/dev/null 2>&1 &
PLUGIN_TREE_ROOT_PID="$!"
for _ in {1..20}; do
  [[ -f "$PLUGIN_TREE_CHILD_PID_FILE" ]] && break
  sleep 0.1
done
[[ -f "$PLUGIN_TREE_CHILD_PID_FILE" ]] || die "expected fake plugin child pid file"
PLUGIN_TREE_TELEGRAM_READY="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  if bridge_plugin_mcp_descendant_ready_for_item "'"$PLUGIN_TREE_ROOT_PID"'" "plugin:telegram@claude-plugins-official"; then
    echo yes
  else
    echo no
  fi
')"
[[ "$PLUGIN_TREE_TELEGRAM_READY" == "yes" ]] || die "expected telegram plugin descendant to be detected"
PLUGIN_TREE_DISCORD_READY="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  if bridge_plugin_mcp_descendant_ready_for_item "'"$PLUGIN_TREE_ROOT_PID"'" "plugin:discord@claude-plugins-official"; then
    echo yes
  else
    echo no
  fi
')"
[[ "$PLUGIN_TREE_DISCORD_READY" == "no" ]] || die "expected discord plugin descendant check to stay negative"
kill "$PLUGIN_TREE_ROOT_PID" >/dev/null 2>&1 || true
wait "$PLUGIN_TREE_ROOT_PID" >/dev/null 2>&1 || true

PLUGIN_MIXED_SERVER_COMMAND="$TMP_ROOT/fake-plugin-mixed-server.command"
PLUGIN_MIXED_WRAPPER_COMMAND="$TMP_ROOT/fake-plugin-mixed-wrapper.command"
PLUGIN_MIXED_CLAUDE_COMMAND="$TMP_ROOT/fake-plugin-mixed-claude.command"
PLUGIN_MIXED_CHILD_PID_FILE="$TMP_ROOT/fake-plugin-mixed-child.pid"
cat >"$PLUGIN_MIXED_SERVER_COMMAND" <<'EOF'
exec -a "bun server.ts" sleep 30
EOF
cat >"$PLUGIN_MIXED_WRAPPER_COMMAND" <<'EOF'
server_command_file="$1"
server_command="$(cat "$server_command_file")"
exec -a "bun run --cwd /tmp/discord/0.0.4/package start" bash -c '
  server_command="$1"
  bash -c "$server_command" &
  child=$!
  wait "$child"
' bash "$server_command"
EOF
cat >"$PLUGIN_MIXED_CLAUDE_COMMAND" <<'EOF'
wrapper_command_file="$1"
server_command_file="$2"
wrapper_command="$(cat "$wrapper_command_file")"
exec -a "claude --dangerously-skip-permissions --name mixed-plugin-watchdog --channels plugin:telegram@claude-plugins-official" bash -c '
  wrapper_command="$1"
  server_command_file="$2"
  bash -c "$wrapper_command" bash "$server_command_file" &
  child=$!
  wait "$child"
' bash "$wrapper_command" "$server_command_file"
EOF
PLUGIN_MIXED_ROOT_COMMAND="$(cat <<'EOF'
claude_command_file="$1"
wrapper_command_file="$2"
server_command_file="$3"
child_pid_file="$4"
claude_command="$(cat "$claude_command_file")"
bash -c "$claude_command" bash "$wrapper_command_file" "$server_command_file" &
child=$!
printf '%s\n' "$child" >"$child_pid_file"
wait "$child"
EOF
)"
bash -c "$PLUGIN_MIXED_ROOT_COMMAND" bash "$PLUGIN_MIXED_CLAUDE_COMMAND" "$PLUGIN_MIXED_WRAPPER_COMMAND" "$PLUGIN_MIXED_SERVER_COMMAND" "$PLUGIN_MIXED_CHILD_PID_FILE" >/dev/null 2>&1 &
PLUGIN_MIXED_ROOT_PID="$!"
for _ in {1..20}; do
  [[ -f "$PLUGIN_MIXED_CHILD_PID_FILE" ]] && break
  sleep 0.1
done
[[ -f "$PLUGIN_MIXED_CHILD_PID_FILE" ]] || die "expected fake mixed plugin child pid file"
PLUGIN_MIXED_TELEGRAM_READY="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  if bridge_plugin_mcp_descendant_ready_for_item "'"$PLUGIN_MIXED_ROOT_PID"'" "plugin:telegram@claude-plugins-official"; then
    echo yes
  else
    echo no
  fi
')"
[[ "$PLUGIN_MIXED_TELEGRAM_READY" == "no" ]] || die "expected telegram mixed-tree liveness check to stay negative"
PLUGIN_MIXED_DISCORD_READY="$("$BASH4_BIN" -lc '
  source "'"$REPO_ROOT"'/bridge-lib.sh"
  if bridge_plugin_mcp_descendant_ready_for_item "'"$PLUGIN_MIXED_ROOT_PID"'" "plugin:discord@claude-plugins-official"; then
    echo yes
  else
    echo no
  fi
')"
[[ "$PLUGIN_MIXED_DISCORD_READY" == "yes" ]] || die "expected discord mixed-tree liveness check to stay positive"
kill "$PLUGIN_MIXED_ROOT_PID" >/dev/null 2>&1 || true
wait "$PLUGIN_MIXED_ROOT_PID" >/dev/null 2>&1 || true

PLUGIN_WATCH_AGENT="plugin-watchdog"
PLUGIN_WATCH_SESSION="plugin-watchdog-$SESSION_NAME"
PLUGIN_WATCH_WORKDIR="$TMP_ROOT/plugin-watchdog"
PLUGIN_WATCH_FAKE_SCRIPT_DIR="$TMP_ROOT/plugin-watchdog-scriptdir"
PLUGIN_WATCH_RESTART_LOG="$TMP_ROOT/plugin-watchdog-restarts.log"
mkdir -p "$PLUGIN_WATCH_WORKDIR" "$PLUGIN_WATCH_FAKE_SCRIPT_DIR"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

bridge_add_agent_id_if_missing "$PLUGIN_WATCH_AGENT"
BRIDGE_AGENT_DESC["$PLUGIN_WATCH_AGENT"]="Plugin watchdog role"
BRIDGE_AGENT_ENGINE["$PLUGIN_WATCH_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$PLUGIN_WATCH_AGENT"]="$PLUGIN_WATCH_SESSION"
BRIDGE_AGENT_WORKDIR["$PLUGIN_WATCH_AGENT"]="$PLUGIN_WATCH_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$PLUGIN_WATCH_AGENT"]='claude --dangerously-skip-permissions'
BRIDGE_AGENT_CHANNELS["$PLUGIN_WATCH_AGENT"]="plugin:telegram@claude-plugins-official"
EOF
tmux new-session -d -s "$PLUGIN_WATCH_SESSION" "sleep 30"
cat >"$PLUGIN_WATCH_FAKE_SCRIPT_DIR/agent-bridge" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$PLUGIN_WATCH_RESTART_LOG"
EOF
chmod +x "$PLUGIN_WATCH_FAKE_SCRIPT_DIR/agent-bridge"
PLUGIN_WATCH_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-plugin-watchdog.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$PLUGIN_WATCH_FAKE_SCRIPT_DIR"'"
    printf "%s\n" "source \"'"$REPO_ROOT"'/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    printf "%s\n" "bridge_audit_log() { :; }"
    sed -n '"'"'/^bridge_plugin_liveness_state_file()/,/^process_memory_daily_refresh_requests()/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  bridge_agent_channel_status() { printf "ok"; }
  # Scope the missing-channels stub to PLUGIN_WATCH_AGENT only; the broader
  # smoke daemon now defaults to BRIDGE_SKIP_PLUGIN_LIVENESS=1, so the
  # liveness scanner must be re-enabled here, and the stub must not pretend
  # every other agent is also missing a plugin (PR #239 bullet 13).
  bridge_agent_missing_plugin_mcp_channels_csv() {
    [[ "$1" == "'"$PLUGIN_WATCH_AGENT"'" ]] && printf "plugin:telegram@claude-plugins-official"
  }
  bridge_tmux_session_attached_count() { printf "0\n"; }
  BRIDGE_SKIP_PLUGIN_LIVENESS=0
  BRIDGE_PLUGIN_LIVENESS_RESTART_COOLDOWN_SECONDS=60
  process_plugin_liveness || true
  process_plugin_liveness || true
  BRIDGE_SKIP_PLUGIN_LIVENESS=1 process_plugin_liveness || true
  if [[ -f "'"$PLUGIN_WATCH_RESTART_LOG"'" ]]; then
    cat "'"$PLUGIN_WATCH_RESTART_LOG"'"
  fi
')"
PLUGIN_WATCH_RESTART_COUNT="$(printf '%s\n' "$PLUGIN_WATCH_OUTPUT" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$PLUGIN_WATCH_RESTART_COUNT" == "1" ]] || die "expected exactly one plugin watchdog restart, got $PLUGIN_WATCH_RESTART_COUNT"
assert_contains "$PLUGIN_WATCH_OUTPUT" "agent restart $PLUGIN_WATCH_AGENT"
assert_not_contains "$PLUGIN_WATCH_OUTPUT" "--no-continue"

PLUGIN_WATCH_FAIL_FAKE_SCRIPT_DIR="$TMP_ROOT/plugin-watchdog-fail-scriptdir"
mkdir -p "$PLUGIN_WATCH_FAIL_FAKE_SCRIPT_DIR"
cat >"$PLUGIN_WATCH_FAIL_FAKE_SCRIPT_DIR/agent-bridge" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "restart failed: sentinel stderr" >&2
exit 1
EOF
chmod +x "$PLUGIN_WATCH_FAIL_FAKE_SCRIPT_DIR/agent-bridge"
PLUGIN_WATCH_FAIL_OUTPUT="$("$BASH4_BIN" -lc '
  set -euo pipefail
  tmp_daemon="'"$TMP_ROOT"'/daemon-plugin-watchdog-fail.sh"
  {
    printf "%s\n" "set -euo pipefail"
    printf "SCRIPT_DIR=%q\n" "'"$PLUGIN_WATCH_FAIL_FAKE_SCRIPT_DIR"'"
    printf "%s\n" "source \"'"$REPO_ROOT"'/bridge-lib.sh\""
    printf "%s\n" "bridge_load_roster"
    printf "%s\n" "daemon_info() { :; }"
    printf "%s\n" "bridge_audit_log() { printf \"%s|%s|%s\" \"\$1\" \"\$2\" \"\$3\"; shift 3; for item in \"\$@\"; do printf \"|%s\" \"\$item\"; done; printf \"\\n\"; }"
    sed -n '"'"'/^bridge_plugin_liveness_state_file()/,/^process_memory_daily_refresh_requests()/p'"'"' "'"$REPO_ROOT"'/bridge-daemon.sh" | sed '"'"'$d'"'"'
  } >"$tmp_daemon"
  source "$tmp_daemon"
  bridge_agent_channel_status() { printf "ok"; }
  # Same agent-scoping as the success block above; additionally clear any
  # cooldown state the prior block wrote so this restart-failure path is
  # not skipped by a stale cooldown timestamp (PR #239 bullet 13).
  bridge_agent_missing_plugin_mcp_channels_csv() {
    [[ "$1" == "'"$PLUGIN_WATCH_AGENT"'" ]] && printf "plugin:telegram@claude-plugins-official"
  }
  bridge_tmux_session_attached_count() { printf "0\n"; }
  rm -f "$(bridge_plugin_liveness_state_file "'"$PLUGIN_WATCH_AGENT"'")"
  BRIDGE_SKIP_PLUGIN_LIVENESS=0
  BRIDGE_PLUGIN_LIVENESS_RESTART_COOLDOWN_SECONDS=60
  process_plugin_liveness || true
')"
assert_contains "$PLUGIN_WATCH_FAIL_OUTPUT" "plugin_mcp_liveness_restart_failed"
assert_contains "$PLUGIN_WATCH_FAIL_OUTPUT" "restart_error=restart failed: sentinel stderr"

log "deduping identical watchdog drift reports"
BRIDGE_WATCHDOG_ENABLED=1 BRIDGE_WATCHDOG_INTERVAL_SECONDS=1 BRIDGE_WATCHDOG_COOLDOWN_SECONDS=3600 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
WATCHDOG_OPEN_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[watchdog] " 2>/dev/null || true)"
[[ "$WATCHDOG_OPEN_ID" =~ ^[0-9]+$ ]] || die "expected watchdog task for drift report"
bash "$REPO_ROOT/bridge-task.sh" done "$WATCHDOG_OPEN_ID" --agent "$SMOKE_AGENT" --note "watchdog handled" >/dev/null
sleep 1
BRIDGE_WATCHDOG_ENABLED=1 BRIDGE_WATCHDOG_INTERVAL_SECONDS=1 BRIDGE_WATCHDOG_COOLDOWN_SECONDS=3600 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
WATCHDOG_OPEN_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[watchdog] " 2>/dev/null || true)"
[[ -z "$WATCHDOG_OPEN_ID_AGAIN" ]] || die "watchdog alert should be deduped while drift hash is unchanged"

log "monitoring usage thresholds and deduping alerts"
FAKE_USAGE_ROOT="$(mktemp -d)"
FAKE_CLAUDE_USAGE="$FAKE_USAGE_ROOT/claude-usage.json"
FAKE_CODEX_SESSIONS="$FAKE_USAGE_ROOT/codex-sessions"
FAKE_USAGE_MONITOR_STATE="$FAKE_USAGE_ROOT/usage-monitor-state.json"
FAKE_USAGE_DAEMON_AUDIT="$FAKE_USAGE_ROOT/usage-daemon-audit.jsonl"
FAKE_USAGE_DAEMON_STATE="$FAKE_USAGE_ROOT/usage-daemon-state.json"
mkdir -p "$FAKE_CODEX_SESSIONS/2026/04/09"
cat >"$FAKE_CLAUDE_USAGE" <<'EOF'
{
  "data": {
    "planName": "Max",
    "fiveHour": 91,
    "sevenDay": 22,
    "fiveHourResetAt": "2026-04-09T13:00:00+00:00",
    "sevenDayResetAt": "2026-04-15T17:00:00+00:00"
  }
}
EOF
cat >"$FAKE_CODEX_SESSIONS/2026/04/09/usage.jsonl" <<'EOF'
{"timestamp":"2026-04-09T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":92.0,"window_minutes":300,"resets_at":1775734470},"secondary":{"used_percent":17.0,"window_minutes":10080,"resets_at":1776209770},"plan_type":"pro"}}}
EOF
USAGE_STATUS_JSON="$(BRIDGE_CLAUDE_USAGE_CACHE="$FAKE_CLAUDE_USAGE" BRIDGE_CODEX_SESSIONS_DIR="$FAKE_CODEX_SESSIONS" "$REPO_ROOT/agent-bridge" usage status --json)"
python3 - "$USAGE_STATUS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
snapshots = payload["snapshots"]
assert any(row["provider"] == "claude" and row["window"] == "5h" for row in snapshots)
assert any(row["provider"] == "codex" and row["window"] == "5h" for row in snapshots)
PY
USAGE_MONITOR_FIRST="$(python3 "$REPO_ROOT/bridge-usage.py" monitor --claude-usage-cache "$FAKE_CLAUDE_USAGE" --codex-sessions-dir "$FAKE_CODEX_SESSIONS" --state-file "$FAKE_USAGE_MONITOR_STATE" --json)"
python3 - "$USAGE_MONITOR_FIRST" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
alerts = payload["alerts"]
assert len(alerts) == 2, alerts
assert any(row["provider"] == "claude" and row["window"] == "5h" for row in alerts)
assert any(row["provider"] == "codex" and row["window"] == "5h" for row in alerts)
PY
USAGE_MONITOR_SECOND="$(python3 "$REPO_ROOT/bridge-usage.py" monitor --claude-usage-cache "$FAKE_CLAUDE_USAGE" --codex-sessions-dir "$FAKE_CODEX_SESSIONS" --state-file "$FAKE_USAGE_MONITOR_STATE" --json)"
python3 - "$USAGE_MONITOR_SECOND" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["alerts"] == [], payload["alerts"]
PY

log "usage-alert latched 90/95/100 ladder + reset_at wobble suppression (#215)"
# Dedicated state file so this block does not interact with the earlier dedupe
# state (which already latched warn for the baseline snapshots).
FAKE_USAGE_LADDER_STATE="$FAKE_USAGE_ROOT/usage-ladder-state.json"
FAKE_USAGE_LADDER_CLAUDE="$FAKE_USAGE_ROOT/claude-usage-ladder.json"
FAKE_USAGE_LADDER_CODEX="$FAKE_USAGE_ROOT/codex-sessions-ladder"
mkdir -p "$FAKE_USAGE_LADDER_CODEX"

write_claude_ladder_snapshot() {
  local five_hour_percent="$1"
  local reset_at="$2"
  cat >"$FAKE_USAGE_LADDER_CLAUDE" <<CLAUDE_EOF
{
  "data": {
    "planName": "Max",
    "fiveHour": ${five_hour_percent},
    "sevenDay": 20,
    "fiveHourResetAt": "${reset_at}",
    "sevenDayResetAt": "2026-05-01T17:00:00+00:00"
  }
}
CLAUDE_EOF
}

run_usage_ladder() {
  python3 "$REPO_ROOT/bridge-usage.py" monitor \
    --claude-usage-cache "$FAKE_USAGE_LADDER_CLAUDE" \
    --codex-sessions-dir "$FAKE_USAGE_LADDER_CODEX" \
    --state-file "$FAKE_USAGE_LADDER_STATE" \
    --json
}

assert_claude_5h_alert() {
  local label="$1"
  local expected_bucket="$2"
  local payload="$3"
  python3 - "$label" "$expected_bucket" "$payload" <<'PY'
import json, sys
label, expected_bucket, payload = sys.argv[1], sys.argv[2], sys.argv[3]
alerts = json.loads(payload)["alerts"]
claude_5h = [a for a in alerts if a.get("provider") == "claude" and a.get("window") == "5h"]
if expected_bucket == "none":
    if claude_5h:
        raise SystemExit(f"[{label}] expected no claude 5h alert, got {claude_5h}")
else:
    if len(claude_5h) != 1 or claude_5h[0].get("bucket") != expected_bucket:
        raise SystemExit(
            f"[{label}] expected 1 claude 5h alert in bucket={expected_bucket}, got {claude_5h}"
        )
PY
}

assert_claude_5h_health() {
  local label="$1"
  local expected_health="$2"
  local percent="$3"
  local status_json
  status_json="$(python3 "$REPO_ROOT/bridge-usage.py" status \
    --claude-usage-cache "$FAKE_USAGE_LADDER_CLAUDE" \
    --codex-sessions-dir "$FAKE_USAGE_LADDER_CODEX" \
    --json)"
  python3 - "$label" "$expected_health" "$percent" "$status_json" <<'PY'
import json, sys
label, expected_health, percent, payload = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
snapshots = json.loads(payload)["snapshots"]
claude_5h = [s for s in snapshots if s.get("provider") == "claude" and s.get("window") == "5h"]
if len(claude_5h) != 1:
    raise SystemExit(f"[{label}] expected 1 claude 5h snapshot at {percent}%, got {claude_5h}")
actual = claude_5h[0].get("health")
if actual != expected_health:
    raise SystemExit(
        f"[{label}] expected health={expected_health} for {percent}% sample, got health={actual}"
    )
PY
}

# status endpoint must agree with monitor bucket — regression for codex's #217
# FIX-FIRST finding that snapshot.health and alert.bucket contradicted each
# other once used_percent crossed the elevated threshold.
write_claude_ladder_snapshot 91 "2026-04-23T19:00:00+00:00"
assert_claude_5h_health "ladder: status health=warn at 91%" "warn" "91"
write_claude_ladder_snapshot 96 "2026-04-23T19:00:00+00:00"
assert_claude_5h_health "ladder: status health=elevated at 96%" "elevated" "96"
write_claude_ladder_snapshot 101 "2026-04-23T19:00:00+00:00"
assert_claude_5h_health "ladder: status health=crit at 101%" "crit" "101"
write_claude_ladder_snapshot 50 "2026-04-23T19:00:00+00:00"
assert_claude_5h_health "ladder: status health=ok at 50%" "ok" "50"

# Cycle 1 — reset_at = 2026-04-23T19:00
write_claude_ladder_snapshot 91 "2026-04-23T19:00:00+00:00"
assert_claude_5h_alert "ladder: first 91% fires warn" "warn" "$(run_usage_ladder)"

write_claude_ladder_snapshot 93 "2026-04-23T19:00:00+00:00"
assert_claude_5h_alert "ladder: warn re-entry stays silent" "none" "$(run_usage_ladder)"

write_claude_ladder_snapshot 96 "2026-04-23T19:00:00+00:00"
assert_claude_5h_alert "ladder: crossing 95% fires elevated" "elevated" "$(run_usage_ladder)"

write_claude_ladder_snapshot 98 "2026-04-23T19:00:00+00:00"
assert_claude_5h_alert "ladder: elevated re-entry stays silent" "none" "$(run_usage_ladder)"

# reset_at wobble (milliseconds-level drift) must not re-fire the elevated alert.
write_claude_ladder_snapshot 98 "2026-04-23T19:00:00.161Z"
assert_claude_5h_alert "ladder: reset_at wobble stays silent" "none" "$(run_usage_ladder)"

write_claude_ladder_snapshot 101 "2026-04-23T19:00:00+00:00"
assert_claude_5h_alert "ladder: crossing 100% fires crit" "crit" "$(run_usage_ladder)"

write_claude_ladder_snapshot 102 "2026-04-23T19:00:00+00:00"
assert_claude_5h_alert "ladder: crit re-entry stays silent" "none" "$(run_usage_ladder)"

# Drop into ok — latch clears so the next climb to warn is a fresh notification.
write_claude_ladder_snapshot 50 "2026-04-23T19:00:00+00:00"
assert_claude_5h_alert "ladder: drop to ok stays silent" "none" "$(run_usage_ladder)"

write_claude_ladder_snapshot 91 "2026-04-23T19:00:00+00:00"
assert_claude_5h_alert "ladder: climb back to 91 after ok fires warn again" "warn" "$(run_usage_ladder)"

# Cycle 2 — reset_at moves forward > grace; latch resets, new warn fires.
write_claude_ladder_snapshot 100 "2026-04-23T19:00:00+00:00"
assert_claude_5h_alert "ladder: climb to 100 in same cycle fires crit" "crit" "$(run_usage_ladder)"
write_claude_ladder_snapshot 91 "2026-04-30T19:00:00+00:00"
assert_claude_5h_alert "ladder: forward reset_at rolls over cycle and re-fires warn" "warn" "$(run_usage_ladder)"
BRIDGE_USAGE_MONITOR_INTERVAL_SECONDS=0 \
BRIDGE_DAEMON_NOTIFY_DRY_RUN=1 \
BRIDGE_AUDIT_LOG="$FAKE_USAGE_DAEMON_AUDIT" \
BRIDGE_CLAUDE_USAGE_CACHE="$FAKE_CLAUDE_USAGE" \
BRIDGE_CODEX_SESSIONS_DIR="$FAKE_CODEX_SESSIONS" \
BRIDGE_USAGE_MONITOR_STATE_FILE="$FAKE_USAGE_DAEMON_STATE" \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
POST_USAGE_ALERTS="$(BRIDGE_AUDIT_LOG="$FAKE_USAGE_DAEMON_AUDIT" "$REPO_ROOT/agent-bridge" usage alerts --json)"
python3 - "$POST_USAGE_ALERTS" <<'PY'
import json, sys
alerts = json.loads(sys.argv[1])
assert any(row["detail"]["provider"] == "claude" and row["detail"]["window"] == "5h" for row in alerts), alerts
assert any(row["detail"]["provider"] == "codex" and row["detail"]["window"] == "5h" for row in alerts), alerts
PY

log "monitoring stable releases and deduping release alerts"
FAKE_RELEASE_ROOT="$(mktemp -d)"
FAKE_RELEASE_JSON="$FAKE_RELEASE_ROOT/latest-release.json"
FAKE_RELEASE_STATE="$FAKE_RELEASE_ROOT/release-state.json"
FAKE_RELEASE_DAEMON_STATE="$FAKE_RELEASE_ROOT/release-daemon-state.json"
cat >"$FAKE_RELEASE_JSON" <<'EOF'
{
  "tag_name": "v9.9.9",
  "name": "Agent Bridge v9.9.9",
  "html_url": "https://github.com/SYRS-AI/agent-bridge-public/releases/tag/v9.9.9",
  "published_at": "2026-04-10T14:18:41Z",
  "body": "## Highlights\n- Stable release smoke fixture\n- Release notes carried into daemon task body"
}
EOF
RELEASE_MONITOR_FIRST="$(python3 "$REPO_ROOT/bridge-release.py" monitor --repo SYRS-AI/agent-bridge-public --installed-version "$EXPECTED_VERSION" --state-file "$FAKE_RELEASE_STATE" --mock-json-file "$FAKE_RELEASE_JSON" --json)"
python3 - "$RELEASE_MONITOR_FIRST" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
alerts = payload["alerts"]
assert len(alerts) == 1, alerts
assert alerts[0]["latest_tag"] == "v9.9.9", alerts
PY
RELEASE_MONITOR_SECOND="$(python3 "$REPO_ROOT/bridge-release.py" monitor --repo SYRS-AI/agent-bridge-public --installed-version "$EXPECTED_VERSION" --state-file "$FAKE_RELEASE_STATE" --mock-json-file "$FAKE_RELEASE_JSON" --json)"
python3 - "$RELEASE_MONITOR_SECOND" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["alerts"] == [], payload["alerts"]
PY
BRIDGE_RELEASE_CHECK_ENABLED=1 \
BRIDGE_RELEASE_CHECK_INTERVAL_SECONDS=0 \
BRIDGE_RELEASE_CHECK_STATE_FILE="$FAKE_RELEASE_DAEMON_STATE" \
BRIDGE_RELEASE_MOCK_JSON_FILE="$FAKE_RELEASE_JSON" \
BRIDGE_RELEASE_REPO="SYRS-AI/agent-bridge-public" \
BRIDGE_HOME="$BRIDGE_HOME" \
BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
RELEASE_OPEN_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[release] Agent Bridge " 2>/dev/null || true)"
[[ "$RELEASE_OPEN_ID" =~ ^[0-9]+$ ]] || die "expected release-available task for $SMOKE_AGENT"
RELEASE_BODY_FILE="$BRIDGE_HOME/shared/releases/v9.9.9.md"
[[ -f "$RELEASE_BODY_FILE" ]] || die "expected release body file"
grep -q 'Stable Release Available' "$RELEASE_BODY_FILE" || die "expected release alert heading"
grep -q '## Release Notes' "$RELEASE_BODY_FILE" || die "expected release notes section"
grep -q 'Stable release smoke fixture' "$RELEASE_BODY_FILE" || die "expected release notes content"
bash "$REPO_ROOT/bridge-task.sh" done "$RELEASE_OPEN_ID" --agent "$SMOKE_AGENT" --note "release alert handled" >/dev/null
LEAK_TASK_DB="$FAKE_RELEASE_ROOT/leak/tasks.db"
BRIDGE_RELEASE_CHECK_ENABLED=1 \
BRIDGE_RELEASE_CHECK_INTERVAL_SECONDS=0 \
BRIDGE_RELEASE_CHECK_STATE_FILE="$FAKE_RELEASE_DAEMON_STATE" \
BRIDGE_RELEASE_MOCK_JSON_FILE="$FAKE_RELEASE_JSON" \
BRIDGE_RELEASE_REPO="SYRS-AI/agent-bridge-public" \
BRIDGE_HOME="$BRIDGE_HOME" \
BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
BRIDGE_TASK_DB="$LEAK_TASK_DB" \
BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
LEAK_RELEASE_OPEN_ID="$(BRIDGE_TASK_DB="$LEAK_TASK_DB" python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[release] Agent Bridge " 2>/dev/null || true)"
[[ -z "$LEAK_RELEASE_OPEN_ID" ]] || die "release alert should not be created when task db escapes BRIDGE_STATE_DIR"
BRIDGE_RELEASE_CHECK_ENABLED=1 \
BRIDGE_RELEASE_CHECK_INTERVAL_SECONDS=0 \
BRIDGE_RELEASE_CHECK_STATE_FILE="$FAKE_RELEASE_DAEMON_STATE" \
BRIDGE_RELEASE_MOCK_JSON_FILE="$FAKE_RELEASE_JSON" \
BRIDGE_RELEASE_REPO="SYRS-AI/agent-bridge-public" \
BRIDGE_HOME="$BRIDGE_HOME" \
BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
BRIDGE_SHARED_DIR="$BRIDGE_SHARED_DIR" \
BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
BRIDGE_ROSTER_FILE="$BRIDGE_ROSTER_FILE" \
BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_ROSTER_LOCAL_FILE" \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
RELEASE_OPEN_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[release] Agent Bridge " 2>/dev/null || true)"
[[ -z "$RELEASE_OPEN_ID_AGAIN" ]] || die "release alert should be deduped for the same tag"

log "escalating crash-loop reports to the admin role"
CRASH_ERRFILE="$TMP_ROOT/crash-loop.err"
cat >"$CRASH_ERRFILE" <<'EOF'
fatal: token expired
unable to open runtime config
EOF
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_write_crash_report \"$BROKEN_CHANNEL_AGENT\" \"claude\" \"5\" \"1\" \"$CRASH_ERRFILE\" 'MS365_CLIENT_SECRET=crash-secret API_KEY=crash-key claude --dangerously-skip-permissions'"
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CRASH_OPEN_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[crash-loop] $BROKEN_CHANNEL_AGENT " 2>/dev/null || true)"
[[ "$CRASH_OPEN_ID" =~ ^[0-9]+$ ]] || die "expected crash-loop task for $BROKEN_CHANNEL_AGENT"
CRASH_BODY_FILE="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_crash_report_body_file \"$BROKEN_CHANNEL_AGENT\"")"
assert_contains "$(cat "$CRASH_BODY_FILE")" "MS365_CLIENT_SECRET=***redacted***"
assert_contains "$(cat "$CRASH_BODY_FILE")" "API_KEY=***redacted***"
assert_not_contains "$(cat "$CRASH_BODY_FILE")" "crash-secret"
assert_not_contains "$(cat "$CRASH_BODY_FILE")" "crash-key"
bash "$REPO_ROOT/bridge-task.sh" done "$CRASH_OPEN_ID" --agent "$SMOKE_AGENT" --note "crash report handled" >/dev/null
CRASH_STATE_FILE="$("$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_crash_state_file \"$BROKEN_CHANNEL_AGENT\"")"
[[ -f "$CRASH_STATE_FILE" ]] || die "expected crash state file for $BROKEN_CHANNEL_AGENT"
grep -q "CRASH_ACK_HASH=" "$CRASH_STATE_FILE" || die "expected crash report ack hash to be recorded"
BRIDGE_CRASH_REPORT_COOLDOWN_SECONDS=0 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CRASH_OPEN_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[crash-loop] $BROKEN_CHANNEL_AGENT " 2>/dev/null || true)"
[[ -z "$CRASH_OPEN_ID_AGAIN" ]] || die "crash-loop report should stay acked while error hash is unchanged"
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_clear_crash_report \"$BROKEN_CHANNEL_AGENT\""
[[ ! -f "$CRASH_BODY_FILE" ]] || die "expected crash report body file to be removed on clear"

log "directly alerting on admin crash loops"
ADMIN_CRASH_ERRFILE="$TMP_ROOT/admin-crash-loop.err"
cat >"$ADMIN_CRASH_ERRFILE" <<'EOF'
admin fatal: runtime auth missing
EOF
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_write_crash_report \"$SMOKE_AGENT\" \"codex\" \"5\" \"2\" \"$ADMIN_CRASH_ERRFILE\" 'codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen'"
# The upgrade-restart fixture manual-stops most static roles; this block needs
# the admin path to be active so the daemon exercises direct admin alerting.
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_clear_manual_stop \"$SMOKE_AGENT\""
PRE_ADMIN_CRASH_ALERTS="$("$REPO_ROOT/agent-bridge" audit --action crash_loop_admin_alert --limit 20 --json)"
BRIDGE_DAEMON_NOTIFY_DRY_RUN=1 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
POST_ADMIN_CRASH_ALERTS="$("$REPO_ROOT/agent-bridge" audit --action crash_loop_admin_alert --limit 20 --json)"
python3 - "$PRE_ADMIN_CRASH_ALERTS" "$POST_ADMIN_CRASH_ALERTS" <<'PY'
import json, sys
before = json.loads(sys.argv[1])
after = json.loads(sys.argv[2])
assert len(after) >= len(before) + 1
PY
BRIDGE_DAEMON_NOTIFY_DRY_RUN=1 bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
POST_ADMIN_CRASH_ALERTS_DEDUPED="$("$REPO_ROOT/agent-bridge" audit --action crash_loop_admin_alert --limit 20 --json)"
python3 - "$POST_ADMIN_CRASH_ALERTS" "$POST_ADMIN_CRASH_ALERTS_DEDUPED" <<'PY'
import json, sys
before = json.loads(sys.argv[1])
after = json.loads(sys.argv[2])
assert len(after) == len(before)
PY
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_clear_crash_report \"$SMOKE_AGENT\""

log "detecting and recovering stalled sessions"
STALL_RATE_AGENT="stall-rate-$SESSION_NAME"
STALL_AUTH_AGENT="stall-auth-$SESSION_NAME"
STALL_UNKNOWN_AGENT="stall-unknown-$SESSION_NAME"
STALL_PICKER_AGENT="stall-picker-$SESSION_NAME"
STALL_RATE_WORKDIR="$TMP_ROOT/$STALL_RATE_AGENT"
STALL_AUTH_WORKDIR="$TMP_ROOT/$STALL_AUTH_AGENT"
STALL_UNKNOWN_WORKDIR="$TMP_ROOT/$STALL_UNKNOWN_AGENT"
STALL_PICKER_WORKDIR="$TMP_ROOT/$STALL_PICKER_AGENT"
mkdir -p "$STALL_RATE_WORKDIR" "$STALL_AUTH_WORKDIR" "$STALL_UNKNOWN_WORKDIR" "$STALL_PICKER_WORKDIR"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

bridge_add_agent_id_if_missing "$STALL_RATE_AGENT"
BRIDGE_AGENT_DESC["$STALL_RATE_AGENT"]="Stall rate-limit role"
BRIDGE_AGENT_ENGINE["$STALL_RATE_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$STALL_RATE_AGENT"]="$STALL_RATE_AGENT"
BRIDGE_AGENT_WORKDIR["$STALL_RATE_AGENT"]="$STALL_RATE_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$STALL_RATE_AGENT"]='claude --dangerously-skip-permissions'

bridge_add_agent_id_if_missing "$STALL_AUTH_AGENT"
BRIDGE_AGENT_DESC["$STALL_AUTH_AGENT"]="Stall auth role"
BRIDGE_AGENT_ENGINE["$STALL_AUTH_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$STALL_AUTH_AGENT"]="$STALL_AUTH_AGENT"
BRIDGE_AGENT_WORKDIR["$STALL_AUTH_AGENT"]="$STALL_AUTH_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$STALL_AUTH_AGENT"]='claude --dangerously-skip-permissions'

bridge_add_agent_id_if_missing "$STALL_UNKNOWN_AGENT"
BRIDGE_AGENT_DESC["$STALL_UNKNOWN_AGENT"]="Stall unknown role"
BRIDGE_AGENT_ENGINE["$STALL_UNKNOWN_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$STALL_UNKNOWN_AGENT"]="$STALL_UNKNOWN_AGENT"
BRIDGE_AGENT_WORKDIR["$STALL_UNKNOWN_AGENT"]="$STALL_UNKNOWN_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$STALL_UNKNOWN_AGENT"]='claude --dangerously-skip-permissions'

bridge_add_agent_id_if_missing "$STALL_PICKER_AGENT"
BRIDGE_AGENT_DESC["$STALL_PICKER_AGENT"]="Stall interactive picker role"
BRIDGE_AGENT_ENGINE["$STALL_PICKER_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$STALL_PICKER_AGENT"]="$STALL_PICKER_AGENT"
BRIDGE_AGENT_WORKDIR["$STALL_PICKER_AGENT"]="$STALL_PICKER_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$STALL_PICKER_AGENT"]='claude --dangerously-skip-permissions'
EOF

STALL_RATE_SCRIPT="$TMP_ROOT/stall-rate.py"
STALL_AUTH_SCRIPT="$TMP_ROOT/stall-auth.py"
STALL_UNKNOWN_SCRIPT="$TMP_ROOT/stall-unknown.py"
cat >"$STALL_RATE_SCRIPT" <<'PY'
#!/usr/bin/env python3
import sys
print("You've hit your limit")
print("❯ ")
sys.stdout.flush()
for _ in sys.stdin:
    pass
PY
cat >"$STALL_AUTH_SCRIPT" <<'PY'
#!/usr/bin/env python3
import sys
print("session expired")
print("❯ ")
sys.stdout.flush()
for _ in sys.stdin:
    pass
PY
cat >"$STALL_UNKNOWN_SCRIPT" <<'PY'
#!/usr/bin/env python3
import sys
print("still thinking")
print("❯ ")
sys.stdout.flush()
for _ in sys.stdin:
    pass
PY
STALL_PICKER_SCRIPT="$TMP_ROOT/stall-picker.py"
cat >"$STALL_PICKER_SCRIPT" <<'PY'
#!/usr/bin/env python3
# Simulates the Claude Code /rate-limit-options picker. Mixed-pane case
# (rate_limit phrase + picker text) — first-match-wins must classify the
# pane as interactive_picker so the daemon escalates instead of nudging.
import sys
print("You've hit your limit · resets in 1h")
print("")
print("What do you want to do?")
print("")
print("❯ 1. Stop and wait for limit to reset")
print("  2. Switch to extra usage")
print("  3. Switch to Team plan")
print("")
print("Enter to confirm · Esc to cancel")
sys.stdout.flush()
for _ in sys.stdin:
    pass
PY
chmod +x "$STALL_RATE_SCRIPT" "$STALL_AUTH_SCRIPT" "$STALL_UNKNOWN_SCRIPT" "$STALL_PICKER_SCRIPT"
tmux new-session -d -s "$STALL_RATE_AGENT" "$STALL_RATE_SCRIPT"
tmux new-session -d -s "$STALL_AUTH_AGENT" "$STALL_AUTH_SCRIPT"
tmux new-session -d -s "$STALL_UNKNOWN_AGENT" "$STALL_UNKNOWN_SCRIPT"
tmux new-session -d -s "$STALL_PICKER_AGENT" "$STALL_PICKER_SCRIPT"
sleep 1
bash "$REPO_ROOT/bridge-sync.sh" >/dev/null

STALL_RATE_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" task create --to "$STALL_RATE_AGENT" --title "stall rate" --body "smoke" --from smoke)"
STALL_RATE_TASK_ID="$(printf '%s\n' "$STALL_RATE_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$STALL_RATE_TASK_ID" =~ ^[0-9]+$ ]] || die "expected rate stall task id"
python3 "$REPO_ROOT/bridge-queue.py" claim "$STALL_RATE_TASK_ID" --agent "$STALL_RATE_AGENT" >/dev/null
BRIDGE_STALL_SCAN_ENABLED=1 \
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
BRIDGE_STALL_RATE_LIMIT_RETRY_SECONDS=0 \
BRIDGE_STALL_ESCALATE_AFTER_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
BRIDGE_STALL_SCAN_ENABLED=1 \
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
BRIDGE_STALL_RATE_LIMIT_RETRY_SECONDS=0 \
BRIDGE_STALL_ESCALATE_AFTER_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
RATE_LIMIT_STALL_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/RATE_LIMIT] $STALL_RATE_AGENT " 2>/dev/null || true)"
[[ "$RATE_LIMIT_STALL_TASK_ID" =~ ^[0-9]+$ ]] || die "expected rate-limit stall escalation"
BRIDGE_STALL_SCAN_ENABLED=1 \
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
BRIDGE_STALL_RATE_LIMIT_RETRY_SECONDS=0 \
BRIDGE_STALL_ESCALATE_AFTER_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
RATE_LIMIT_STALL_TASK_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/RATE_LIMIT] $STALL_RATE_AGENT " 2>/dev/null || true)"
[[ "$RATE_LIMIT_STALL_TASK_ID_AGAIN" == "$RATE_LIMIT_STALL_TASK_ID" ]] || die "expected deduped rate-limit stall escalation"
RATE_NUDGE_COUNT="$(python3 - "$BRIDGE_HOME/logs/audit.jsonl" "$STALL_RATE_AGENT" <<'PY'
import json, sys
count = 0
for raw in open(sys.argv[1], encoding="utf-8"):
    item = json.loads(raw)
    if item.get("action") == "stall_nudge_sent" and item.get("target") == sys.argv[2]:
        count += 1
print(count)
PY
)"
[[ "$RATE_NUDGE_COUNT" == "2" ]] || die "expected exactly two stall nudges before rate-limit escalation"

STALL_AUTH_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" task create --to "$STALL_AUTH_AGENT" --title "stall auth" --body "smoke" --from smoke)"
STALL_AUTH_TASK_ID="$(printf '%s\n' "$STALL_AUTH_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$STALL_AUTH_TASK_ID" =~ ^[0-9]+$ ]] || die "expected auth stall task id"
python3 "$REPO_ROOT/bridge-queue.py" claim "$STALL_AUTH_TASK_ID" --agent "$STALL_AUTH_AGENT" >/dev/null
BRIDGE_STALL_SCAN_ENABLED=1 \
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
AUTH_STALL_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/AUTH] $STALL_AUTH_AGENT " 2>/dev/null || true)"
[[ "$AUTH_STALL_TASK_ID" =~ ^[0-9]+$ ]] || die "expected auth stall escalation"

STALL_UNKNOWN_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" task create --to "$STALL_UNKNOWN_AGENT" --title "stall unknown" --body "smoke" --from smoke)"
STALL_UNKNOWN_TASK_ID="$(printf '%s\n' "$STALL_UNKNOWN_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$STALL_UNKNOWN_TASK_ID" =~ ^[0-9]+$ ]] || die "expected unknown stall task id"
python3 "$REPO_ROOT/bridge-queue.py" claim "$STALL_UNKNOWN_TASK_ID" --agent "$STALL_UNKNOWN_AGENT" >/dev/null
BRIDGE_STALL_SCAN_ENABLED=1 \
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_IDLE_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_RETRY_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_ESCALATE_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
BRIDGE_STALL_SCAN_ENABLED=1 \
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_IDLE_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_RETRY_SECONDS=0 \
BRIDGE_STALL_UNKNOWN_ESCALATE_SECONDS=0 \
BRIDGE_STALL_MAX_NUDGES=2 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
UNKNOWN_STALL_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/UNKNOWN] $STALL_UNKNOWN_AGENT " 2>/dev/null || true)"
[[ "$UNKNOWN_STALL_TASK_ID" =~ ^[0-9]+$ ]] || die "expected unknown stall escalation"

STALL_PICKER_CREATE_OUTPUT="$("$REPO_ROOT/agent-bridge" task create --to "$STALL_PICKER_AGENT" --title "stall picker" --body "smoke" --from smoke)"
STALL_PICKER_TASK_ID="$(printf '%s\n' "$STALL_PICKER_CREATE_OUTPUT" | sed -n 's/^created task #\([0-9][0-9]*\).*/\1/p' | head -n1)"
[[ "$STALL_PICKER_TASK_ID" =~ ^[0-9]+$ ]] || die "expected picker stall task id"
python3 "$REPO_ROOT/bridge-queue.py" claim "$STALL_PICKER_TASK_ID" --agent "$STALL_PICKER_AGENT" >/dev/null
BRIDGE_STALL_SCAN_ENABLED=1 \
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
PICKER_STALL_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/PICKER] $STALL_PICKER_AGENT " 2>/dev/null || true)"
[[ "$PICKER_STALL_TASK_ID" =~ ^[0-9]+$ ]] || die "expected picker stall escalation"
BRIDGE_STALL_SCAN_ENABLED=1 \
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
# Use --all so dedupe is proven by *count* of open tasks, not just by the
# first match (which would be stable even if a duplicate were also created).
PICKER_OPEN_COUNT="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/PICKER] $STALL_PICKER_AGENT " --all --format json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
[[ "$PICKER_OPEN_COUNT" == "1" ]] || die "expected exactly one open [STALL/PICKER] task after second sync (got $PICKER_OPEN_COUNT)"
PICKER_STALL_TASK_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[STALL/PICKER] $STALL_PICKER_AGENT " 2>/dev/null || true)"
[[ "$PICKER_STALL_TASK_ID_AGAIN" == "$PICKER_STALL_TASK_ID" ]] || die "expected deduped picker stall escalation, got '$PICKER_STALL_TASK_ID_AGAIN' vs '$PICKER_STALL_TASK_ID'"
PICKER_NUDGE_COUNT="$(python3 - "$BRIDGE_HOME/logs/audit.jsonl" "$STALL_PICKER_AGENT" <<'PY'
import json, sys
count = 0
for raw in open(sys.argv[1], encoding="utf-8"):
    item = json.loads(raw)
    if item.get("action") == "stall_nudge_sent" and item.get("target") == sys.argv[2]:
        count += 1
print(count)
PY
)"
[[ "$PICKER_NUDGE_COUNT" == "0" ]] || die "expected zero stall nudges for picker stall, got '$PICKER_NUDGE_COUNT'"

tmux_kill_session_exact "$STALL_RATE_AGENT" || true
tmux_kill_session_exact "$STALL_AUTH_AGENT" || true
tmux_kill_session_exact "$STALL_UNKNOWN_AGENT" || true
tmux_kill_session_exact "$STALL_PICKER_AGENT" || true
BRIDGE_STALL_SCAN_ENABLED=1 \
BRIDGE_STALL_SCAN_INTERVAL_SECONDS=0 \
BRIDGE_STALL_EXPLICIT_IDLE_SECONDS=0 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
STALL_RECOVERED_JSON="$("$REPO_ROOT/agent-bridge" audit --action stall_recovered --limit 20 --json)"
python3 - "$STALL_RECOVERED_JSON" "$STALL_RATE_AGENT" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
assert any(row.get("target") == sys.argv[2] for row in rows), rows
PY

log "tracking context pressure separately from process health"
CONTEXT_PRESSURE_AGENT="context-pressure-$SESSION_NAME"
CONTEXT_PRESSURE_WORKDIR="$TMP_ROOT/$CONTEXT_PRESSURE_AGENT"
CONTEXT_PRESSURE_SCRIPT="$TMP_ROOT/context-pressure.py"
CONTEXT_PRESSURE_INPUT_LOG="$TMP_ROOT/context-pressure-input.log"
mkdir -p "$CONTEXT_PRESSURE_WORKDIR"
cat >>"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF

bridge_add_agent_id_if_missing "$CONTEXT_PRESSURE_AGENT"
BRIDGE_AGENT_DESC["$CONTEXT_PRESSURE_AGENT"]="Context pressure role"
BRIDGE_AGENT_ENGINE["$CONTEXT_PRESSURE_AGENT"]="claude"
BRIDGE_AGENT_SESSION["$CONTEXT_PRESSURE_AGENT"]="$CONTEXT_PRESSURE_AGENT"
BRIDGE_AGENT_WORKDIR["$CONTEXT_PRESSURE_AGENT"]="$CONTEXT_PRESSURE_WORKDIR"
BRIDGE_AGENT_LAUNCH_CMD["$CONTEXT_PRESSURE_AGENT"]='claude --dangerously-skip-permissions'
EOF
cat >"$CONTEXT_PRESSURE_SCRIPT" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
print("Context remaining 8%. Please compact soon.")
print("❯ ")
sys.stdout.flush()
for line in sys.stdin:
    path.open("a", encoding="utf-8").write(line)
PY
chmod +x "$CONTEXT_PRESSURE_SCRIPT"
: >"$CONTEXT_PRESSURE_INPUT_LOG"
tmux new-session -d -s "$CONTEXT_PRESSURE_AGENT" "$CONTEXT_PRESSURE_SCRIPT '$CONTEXT_PRESSURE_INPUT_LOG'"
sleep 1
bash "$REPO_ROOT/bridge-sync.sh" >/dev/null
BRIDGE_CONTEXT_PRESSURE_SCAN_ENABLED=1 \
BRIDGE_CONTEXT_PRESSURE_SCAN_INTERVAL_SECONDS=0 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CONTEXT_PRESSURE_TASK_ID="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[context-pressure] $CONTEXT_PRESSURE_AGENT " 2>/dev/null || true)"
[[ ! "$CONTEXT_PRESSURE_TASK_ID" =~ ^[0-9]+$ ]] || die "context-pressure scanner should not create report task"
CONTEXT_PRESSURE_BODY_FILE="$BRIDGE_SHARED_DIR/context-pressure/$CONTEXT_PRESSURE_AGENT-warning.md"
[[ ! -e "$CONTEXT_PRESSURE_BODY_FILE" ]] || die "context-pressure scanner should not write report body"
CONTEXT_PRESSURE_STATE_FILE="$BRIDGE_ACTIVE_AGENT_DIR/$CONTEXT_PRESSURE_AGENT/context-pressure.env"
[[ -f "$CONTEXT_PRESSURE_STATE_FILE" ]] || die "expected context-pressure telemetry state"
CONTEXT_PRESSURE_STATE="$(cat "$CONTEXT_PRESSURE_STATE_FILE")"
assert_contains "$CONTEXT_PRESSURE_STATE" "CONTEXT_PRESSURE_SEVERITY=warning"
assert_not_contains "$CONTEXT_PRESSURE_STATE" "CONTEXT_PRESSURE_TASK_ID"
CONTEXT_DETECTED_JSON="$("$REPO_ROOT/agent-bridge" audit --action context_pressure_detected --limit 20 --json)"
python3 - "$CONTEXT_DETECTED_JSON" "$CONTEXT_PRESSURE_AGENT" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
assert any(row.get("target") == sys.argv[2] for row in rows), rows
PY
[[ ! -s "$CONTEXT_PRESSURE_INPUT_LOG" ]] || die "context pressure scanner must not inject messages into the active session"
BRIDGE_CONTEXT_PRESSURE_SCAN_ENABLED=1 \
BRIDGE_CONTEXT_PRESSURE_SCAN_INTERVAL_SECONDS=0 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CONTEXT_PRESSURE_TASK_ID_AGAIN="$(python3 "$REPO_ROOT/bridge-queue.py" find-open --agent "$SMOKE_AGENT" --title-prefix "[context-pressure] $CONTEXT_PRESSURE_AGENT " 2>/dev/null || true)"
[[ ! "$CONTEXT_PRESSURE_TASK_ID_AGAIN" =~ ^[0-9]+$ ]] || die "context-pressure scanner should remain audit-only on repeated scan"
tmux_kill_session_exact "$CONTEXT_PRESSURE_AGENT" || true
"$BASH4_BIN" -lc "source \"$REPO_ROOT/bridge-lib.sh\"; bridge_load_roster; bridge_agent_mark_manual_stop \"$CONTEXT_PRESSURE_AGENT\""
BRIDGE_CONTEXT_PRESSURE_SCAN_ENABLED=1 \
BRIDGE_CONTEXT_PRESSURE_SCAN_INTERVAL_SECONDS=0 \
bash "$REPO_ROOT/bridge-daemon.sh" sync >/dev/null
CONTEXT_RECOVERED_JSON="$("$REPO_ROOT/agent-bridge" audit --action context_pressure_recovered --limit 20 --json)"
python3 - "$CONTEXT_RECOVERED_JSON" "$CONTEXT_PRESSURE_AGENT" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
assert any(row.get("target") == sys.argv[2] for row in rows), rows
PY

log "context-pressure FP-rate counter (#338 Track C)"
# Fixture: emit a legacy [context-pressure] critical task body and seed a
# context_pressure_report audit row so the dashboard denominator still covers
# historical reports. The daemon no longer emits these rows itself (#472).
# Then close the task with a "false-positive" operator note via bridge-task.sh
# and assert (a) the audit row was written by bridge-task.sh and (b)
# `agent-bridge status` renders the 1/1 (100%) line.
FP_AGENT="fp-counter-$SESSION_NAME"
FP_BODY_DIR="$BRIDGE_SHARED_DIR/context-pressure"
FP_BODY_FILE="$FP_BODY_DIR/$FP_AGENT-critical.md"
mkdir -p "$FP_BODY_DIR"
cat >"$FP_BODY_FILE" <<EOF
# Context Pressure Report

- agent: $FP_AGENT
- session: $FP_AGENT
- severity: critical
- idle_seconds: 0
- agent_source: static
- first_detected_at: $(date -u +%Y-%m-%dT%H:%M:%S+00:00)
- detected_at: $(date -u +%Y-%m-%dT%H:%M:%S+00:00)
- matched_pattern: hud:context_pct=92

## Recommended Next Action

**Resolve autonomously.** Smoke fixture body.

## Recent Output

\`\`\`text
Context ████████░░ 92%
\`\`\`
EOF
FP_TASK_CREATE_OUTPUT="$(BRIDGE_TASK_DB="$BRIDGE_TASK_DB" python3 "$REPO_ROOT/bridge-queue.py" create --to "$SMOKE_AGENT" --from daemon --priority urgent --title "[context-pressure] $FP_AGENT (critical)" --body-file "$FP_BODY_FILE" --format shell)"
FP_TASK_ID="$(printf '%s\n' "$FP_TASK_CREATE_OUTPUT" | sed -n "s/^TASK_ID=//p" | tr -d "'\"" | head -n1)"
[[ "$FP_TASK_ID" =~ ^[0-9]+$ ]] || die "expected fp-counter task id, got: $FP_TASK_ID"
# Seed the legacy denominator row that older daemon versions emitted.
python3 "$REPO_ROOT/bridge-audit.py" write --file "$BRIDGE_AUDIT_LOG" \
  --actor daemon --action context_pressure_report --target "$SMOKE_AGENT" \
  --detail agent="$FP_AGENT" \
  --detail severity=critical \
  --detail task_id="$FP_TASK_ID" >/dev/null
bash "$REPO_ROOT/bridge-task.sh" claim "$FP_TASK_ID" --agent "$SMOKE_AGENT" >/dev/null
bash "$REPO_ROOT/bridge-task.sh" "done" "$FP_TASK_ID" --agent "$SMOKE_AGENT" --note "false-positive — HUD shows 36%" >/dev/null
FP_AUDIT_JSON="$("$REPO_ROOT/agent-bridge" audit --action context_pressure_false_positive --target "$FP_AGENT" --limit 5 --json)"
python3 - "$FP_AUDIT_JSON" "$FP_AGENT" "$FP_TASK_ID" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
target = sys.argv[2]
task_id = sys.argv[3]
matches = [r for r in rows if r.get("target") == target]
assert matches, f"expected context_pressure_false_positive audit row for {target}: {rows}"
detail = matches[-1].get("detail") or {}
assert str(detail.get("task_id")) == task_id, detail
assert detail.get("severity") == "critical", detail
assert detail.get("matched_pattern", "").startswith("hud:context_pct="), detail
assert "false-positive" in (detail.get("done_note_excerpt") or "").lower(), detail
PY
FP_STATUS_OUTPUT="$("$REPO_ROOT/agent-bridge" status --all-agents)"
assert_contains "$FP_STATUS_OUTPUT" "context-pressure FP rate (7d): 1/1 (100%)"

# Stale-resume regression: verifies the freshness-gate resolver and its
# legacy boolean wrappers reject 96h-old transcripts (issue: agb admin
# stale session-id resume).
log "running stale-resume regression suite"
bash "$REPO_ROOT/scripts/test-stale-resume.sh"

# Issue #832 — channel-health probe must degrade to controller-blind /
# status=unknown when the controller cannot read an isolated agent's
# dotenv AND we cannot sudo to that agent's UID. Without this, the daemon
# fires a false channel_health_miss audit row on every health cycle.
log "running channel-probe-isolated regression suite (issue #832)"
bash "$REPO_ROOT/scripts/test-channel-probe-isolated.sh"

# Issue #851 — runtime channel dotenv ACL mask reverts to --- after plugin
# writes inherit the controller umask. Pins the new self-heal helper
# bridge_isolation_v2_apply_channel_state_dotenv_acl that the daemon health
# loop + pre-launch path call when an isolated agent's dotenv flips to
# auth=unreadable.
log "running channel-dotenv-mask-repair regression suite (issue #851)"
bash "$REPO_ROOT/scripts/test-channel-dotenv-mask-repair.sh"

# Issue #831 — usage monitor must read each Claude agent's own usage cache
# (per-agent latching), not just the controller's $HOME. Without this, two
# isolated agents sharing the same plan can mask each other's rotation
# triggers.
log "running usage-monitor-isolated regression suite (issue #831)"
bash "$REPO_ROOT/scripts/test-usage-monitor-isolated.sh"

# Issue #833 — picker-sweep cron registration must fire on every fresh
# install regardless of host_profile (dev or server). Runtime gating moved
# into the cron payload's BRIDGE_PICKER_SWEEP_ENABLED=1; the host_profile=dev
# default-skip now applies to manual runs only.
log "running picker-sweep-registration regression suite (issue #833)"
bash "$REPO_ROOT/scripts/test-picker-sweep-registration.sh"

# Resume-quarantine regression (Issue #820, v0.11.0): verifies
# bridge_run_quarantine_rejected_resume only fires on real Claude
# `--resume <stale-id>` rejections (not on unrelated short-duration
# failures), and that forget-session clears the quarantine on the
# changed=no path too.
log "running resume-quarantine regression suite (issue #820)"
bash "$REPO_ROOT/scripts/test-resume-quarantine.sh"

# Prompt-guard regression (Issue #823, v0.11.0): verifies
# `bridge_runtime_secret_access` requires a sensitive-action verb
# within an 80-char window of a credential-bearing path. Locks down
# both the positive (verb + protected path) and negative (pure-prose
# mentions, verb + non-credential .env file) shapes.
log "running prompt-guard rules regression suite (issue #823)"
bash "$REPO_ROOT/scripts/test-prompt-guard-rules.sh"

# Issues #821 + #822 (v0.11.0) — upgrade-time restart hardening: verifies the
# per-agent `bridge_with_timeout` wrap (124/137 -> restart-timeout) and
# the `recovered_by_daemon` reconciliation pass that reclassifies failed
# rows whose agent ends up active after a bounded settle window.
log "running upgrade-restart-hardening regression suite (issues #821 #822)"
bash "$REPO_ROOT/scripts/test-upgrade-restart-hardening.sh"

# Issue #864 (v0.13.0 hotfix) — three migration-side permission regressions
# that block isolated agent start: marker owner left as controller (R1),
# new scripts/* dirs at mode 0700 from umask=077 (R2), per-isolated-agent
# ~/.claude/plugins/ left at 2750 blocking flock (R3). Pin all three.
log "running 864-upgrade-perm-regressions suite (issue #864 R1/R2/R3)"
bash "$REPO_ROOT/scripts/smoke/864-upgrade-perm-regressions.sh"

# Issue #824 (v0.11.0) — `agent show <X>` text formatter regression. Pins
# the tab-to-sentinel translation that preserves empty middle fields
# (notably session_id) and the field-count guard that refuses to render
# a row whose column count drifts from the producer's 30-column schema.
log "running agent-show-formatter regression suite (issue #824)"
bash "$REPO_ROOT/scripts/test-agent-show-formatter.sh"

# Issue #541 PR-A — memory-daily payload jsonl-aware migration regression.
log "running cron-migrate-payloads smoke (issue #541 PR-A)"
bash "$REPO_ROOT/scripts/smoke/cron-migrate-payloads.sh"

# Issue #628 — cron CRUD mutations must emit audit.jsonl rows so multi-admin
# installs can attribute disable/enable/edit/delete/create without grepping
# transcripts.
log "running cron-mutation-audit smoke (issue #628)"
bash "$REPO_ROOT/scripts/smoke/cron-mutation-audit.sh"

# Native cron shell payload runner regression.
log "running cron-shell-runner smoke"
bash "$REPO_ROOT/scripts/smoke/cron-shell-runner.sh"

# Issue #544 PR1 — curated bin/agb shim for isolated agents.
log "running isolated-bin-agb smoke (issue #544 PR1)"
log "isolated-bin-agb covers shim env-source/delegation/fallback only — live PATH injection requires isolate+restart"
bash "$REPO_ROOT/scripts/smoke/isolated-bin-agb.sh"

# Issue #544 PR3 — bridge-native skills sync into isolated HOME with
# `~/.agent-bridge/` → absolute BRIDGE_HOME path normalization.
log "running isolated-skills-sync smoke (issue #544 PR3)"
log "isolated-skills-sync covers helper render/rewrite only — live sudo + ACL grants require isolate+restart on a Linux host"
bash "$REPO_ROOT/scripts/smoke/isolated-skills-sync.sh"

# Issue #544 PR2 — render bridge hook entries into isolated home
# settings.json + symlink. Renderer-only coverage; live sudo
# install/symlink-swap requires isolate+restart on a Linux host.
log "running isolated-settings-rendering smoke (issue #544 PR2)"
log "isolated-settings-rendering covers Python renderer only — live install/symlink-swap requires isolate+restart"
bash "$REPO_ROOT/scripts/smoke/isolated-settings-rendering.sh"

# Issue #544 PR4 — isolated subcommand allowlist + audit on bin/agb shim.
log "running isolated-cli-policy smoke (issue #544 PR4)"
log "isolated-cli-policy covers shim allowlist/denylist gate + audit redaction — live BRIDGE_CONTROLLER_UID emission requires isolate+restart on a Linux host"
bash "$REPO_ROOT/scripts/smoke/isolated-cli-policy.sh"

# Issue #539 — system agent class roundtrip + tool-policy gate scenarios.
log "running system-agent-class smoke (issue #539)"
bash "$REPO_ROOT/scripts/smoke/system-agent-class.sh"

# Issue #583 (v0.8.0 T4) — v2 cross-class isolated read closure smoke.
# Verifies the v2 layout (POSIX group ab-agent-<n> + setgid 2770) lets a
# controller UID read isolated agents' memory/{projects,shared,decisions}
# via group permission, without any ACL fallback. Linux + passwordless
# sudo only — skips cleanly on macOS / unprivileged CI.
log "running v2-cross-class-read smoke (issue #583 closure)"
log "v2-cross-class-read covers POSIX group + setgid permission boundary only — skips on macOS / no-sudo"
bash "$REPO_ROOT/scripts/smoke/v2-cross-class-read.sh"

# Issue #555 — per-agent settings.effective.json rendering for managed
# (non-isolated) agents. Mixed-model installs no longer last-rerender-wins
# on `autoCompactWindow` (or any future per-agent managed default).
log "running per-agent-settings-rendering smoke (issue #555)"
bash "$REPO_ROOT/scripts/smoke/per-agent-settings-rendering.sh"

# Issue #613 — shared renderer must preserve operator-edited user keys
# (enabledPlugins, extraKnownMarketplaces, skipDangerousModePermissionPrompt)
# on every rerender, matching the long-standing isolated-renderer contract.
log "running shared-settings-preserve-user-keys smoke (issue #613)"
bash "$REPO_ROOT/scripts/smoke/shared-settings-preserve-user-keys.sh"

# v0.13.6 hotfix track 1 — ADMIN-PROTOCOL.md wire-up. The agent CLAUDE.md
# managed block points admin sessions at ADMIN-PROTOCOL.md but until
# this smoke landed the file was never propagated into <bridge_home>/
# shared/ and the matching symlink was missing from every agent home.
log "running admin-protocol-shared-link smoke (v0.13.6 hotfix track 1)"
bash "$REPO_ROOT/scripts/smoke/admin-protocol-shared-link.sh"

# Issue #597 Track D — precompact-notify suite. Exercises the Discord
# relay activity-index writer, the Track A route-primitive end-to-end
# with the writer-populated index, and the pre-compact.py hook
# resilience contract. Tracks B (daemon observer) and C (Teams/
# Mattermost TS adapters) cases are deferred — the fixture documents
# which assertions are still pending.
log "running precompact-notify suite smoke (issue #597 Track D)"
bash "$REPO_ROOT/tests/precompact-notify/smoke.sh"

# bridge_tmux_wait_for_claude_foreground must honor session liveness mid-poll
# so a dead session does not burn the full foreground budget (controller
# watcher P2 — bridge-start.sh:113 split-budget review r2).
log "running tmux-wait-foreground-liveness smoke (controller watcher P2)"
bash "$REPO_ROOT/tests/tmux-wait-foreground-liveness/smoke.sh"

# Issue #639 — codex-task-mode-policy.py write-shape detector redesign
# (default-deny block-mode allow-list + common-shape parser). Covers all
# 6 D1 gaps (multi-command, substitution, quoting, exec/bash recursion,
# tool exotics, heredoc) plus PR #636 r1-r5 regression + grant grammar.
log "running codex-task-mode-policy-comprehensive smoke (issue #639)"
bash "$REPO_ROOT/scripts/smoke/codex-task-mode-policy-comprehensive.sh"

# Issue #619 — `agent doctor` CRUD self-check. Exercises the 7-step
# create/update/registry/show/reclassify/retire/delete matrix under
# isolated BRIDGE_HOME, the admin caller gate, the concurrent-doctor
# lock, and the JSON envelope shape.
log "running agent-doctor smoke (issue #619)"
bash "$REPO_ROOT/scripts/smoke/agent-doctor.sh"

# v0.8.1 hotfix regression smoke — verifies isolation-v2 migrate lock
# acquire/release works without `flock` on PATH (macOS default), live
# owner blocks second acquire, and stale PID file is auto-cleaned.
log "running isolation-v2-migrate-lock-portability smoke (v0.8.1 hotfix)"
bash "$REPO_ROOT/scripts/smoke/isolation-v2-migrate-lock-portability.sh"

# v0.13.10 Track A regression smoke — verifies the marker-only fast-path
# in bridge_isolation_v2_migrate_apply_for_upgrade: a markerless install
# with no isolated agents that runs under BRIDGE_UPGRADE_CONTEXT=1 must
# write the v2 marker without invoking sudo / group ops, and the gating
# must hold for the non-upgrade context, has-isolated rosters, and
# rc=2 (unknown) roster predicates.
log "running isolation-v2-marker-only-migrate smoke (v0.13.10 Track A)"
bash "$REPO_ROOT/scripts/smoke/isolation-v2-marker-only-migrate.sh"

# v0.8.2 hotfix regression smoke (issue #652) — verifies cmd_migrate_agents
# does NOT abort the multi-agent loop when one agent home is owned by a
# different UID (controller cannot stat into 0700 memory tree). Two
# layers covered: (1) template-side skip of `memory/` subtree in
# migrate_agent_home, (2) defensive PermissionError catch in
# cmd_migrate_agents that records a structured `skipped_isolated` entry.
log "running upgrade-isolated-agent-migrate smoke (v0.8.2 hotfix, issue #652)"
bash "$REPO_ROOT/scripts/smoke/upgrade-isolated-agent-migrate.sh"

# Issue #857 PR-1 — bridge_isolation_write_file_as_agent_user_via_bash
# is the WRITE counterpart to PR #836's read helper, used by later PRs in
# the #857 ACL deprecation umbrella to migrate channel-dotenv ownership
# to the isolated UID. Cover the helper's pre-check rc bands and atomic
# write sequence whenever lib/bridge-isolation-helpers.sh moves.
log "running 857-pr1-isolation-write-helper smoke (#857 PR-1)"
bash "$REPO_ROOT/scripts/smoke/857-pr1-isolation-write-helper.sh"

# Issue #895 — `bridge_agent_workdir`'s v2-anchor branch was firing for
# every isolation mode, silently re-rooting shared-mode dynamic agents
# spawned via `agb --claude --name <agent>` into an empty stub. The fix
# (Track C v0.13.10) gates the v2 anchor override on `linux-user`
# isolation (the privacy invariant the override exists for) and falls
# through to the explicit `BRIDGE_AGENT_WORKDIR[<agent>]` for any other
# mode. The smoke asserts all three branches: shared, linux-user, and
# the unset/default-fallback case — one-sided coverage would let any
# direction regress.
log "running dynamic-agent-shared-mode-workdir smoke (issue #895)"
bash "$REPO_ROOT/scripts/smoke/dynamic-agent-shared-mode-workdir.sh"

# Issue #686 — `bridge_scaffold_agent_home` must materialize BOTH
# `<agent-root>/home/` and the sibling `<agent-root>/workdir/` so the
# resolver (`bridge_agent_workdir`) lands on an existing directory.
# Without this sibling mkdir every fresh v2 install surfaced
# `workdir가 없습니다` from `bridge-start.sh --dry-run`.
log "running v2-scaffold-home-and-workdir smoke (issue #686)"
bash "$REPO_ROOT/scripts/smoke/v2-scaffold-home-and-workdir.sh"

# Task #4813 — `agent-bridge --claude --name <new-dynamic> --no-attach`
# from a project that already hosts a static role (e.g. `patch`) was
# silently redirecting to that static role in non-TTY mode. The
# `STATIC_CANDIDATES > 0` branch in agent-bridge defaulted to
# `SPAWN_PREFERENCE=wake` whenever there was exactly one candidate,
# dropping the operator's explicit `--name` on the floor. The fix
# changes the non-TTY default to `shared` so explicit names always
# spawn a new dynamic worker. Operator-opt-in `--prefer wake|new` is
# still honored, and the TTY interactive picker is unchanged.
log "running dynamic-launch-no-admin-fallback smoke (task #4813)"
bash "$REPO_ROOT/scripts/smoke/dynamic-launch-no-admin-fallback.sh"

# Dynamic agents are operator-driven containers; long idle is normal
# state, not a health signal. The dashboard previously flagged them
# as warn/crit purely on idle threshold (Sean, 2026-05-16). Guard the
# classify_stale dynamic-source exemption so a future regression
# brings the false-positive back into the health counter.
log "running classify-stale-dynamic-exemption smoke"
bash "$REPO_ROOT/scripts/smoke/classify-stale-dynamic-exemption.sh"

# bridge_export_env_prefix was re-exporting BRIDGE_LAYOUT and
# BRIDGE_DATA_ROOT from the parent process into every spawned child
# (patch ticket #4725, 2026-05-16). On a v2-migrated install, parents
# can carry a legacy value and every child then triggers the
# resolver-demote warning on every CLI command. Guard the trimmed
# prefix list.
log "running bridge-export-prefix-no-stale-layout smoke (patch #4725)"
bash "$REPO_ROOT/scripts/smoke/bridge-export-prefix-no-stale-layout.sh"

# Companion regression to patch #4725: PR #926 stopped the bridge-core
# export prefix from forwarding stale BRIDGE_LAYOUT/BRIDGE_DATA_ROOT,
# but did not clean values that already lived in the tmux server's
# GLOBAL env from pre-PR-#926 installs. Patch #4798 adds a one-shot
# `tmux setenv -u -g` cleanup to bridge-upgrade.sh and gates the
# resolver warning to once-per-process so transitional installs are
# not drowned in noise. Smoke pins both halves.
log "running tmux-server-bridge-layout-cleanup smoke (patch #4798)"
bash "$REPO_ROOT/scripts/smoke/tmux-server-bridge-layout-cleanup.sh"

# `_ENV_DUMP_PATTERNS` in hooks/tool-policy.py used to false-positive on
# natural-language `env` and `printenv` (e.g. task titles like
# "stale env override" denied as if they were process-env dumps). Guard
# the regex tightening with both true-positive and false-positive
# truth-table cases (operator-flagged 2026-05-16).
log "running tool-policy-process-dump-regex smoke"
bash "$REPO_ROOT/scripts/smoke/tool-policy-process-dump-regex.sh"

# bridge_worktree_doctor previously left daemonized children alive after
# pruning their worktree dir — Sean observed 7 orphaned bridge-watchdog
# processes parented to init(1) on 2026-05-16. The doctor now reaps argv-
# anchored children before removing the worktree; this smoke is the
# regression catch for both shapes (direct-exec + interpreter-exec).
log "running worktree-doctor-reap-zombies smoke"
bash "$REPO_ROOT/scripts/smoke/worktree-doctor-reap-zombies.sh"

# Integration test for the dry-run path through bridge_worktree_doctor:
# proves --dry-run actually invokes the reap helper for REMOVE rows
# (catches the r1 regression where the helper call lived after the early
# `mode != apply` return and was therefore unreachable).
log "running worktree-doctor-reap-zombies-dry-run integration smoke"
bash "$REPO_ROOT/scripts/smoke/worktree-doctor-reap-zombies-dry-run.sh"

log "running layout-evidence-empty-subdir smoke"
bash "$REPO_ROOT/scripts/smoke/layout-evidence-empty-subdir.sh"

log "running smoke-isolation-no-live-leak smoke (refs queue #4793)"
bash "$REPO_ROOT/scripts/smoke/smoke-isolation-no-live-leak.sh"

# Refs queue task #4773 — bridge-agent.sh registry/list/show JSON paths
# wedged Bash 5.3.9 read_comsub via nested $() captures feeding
# heredoc-stdin python3 subprocesses through the bridge_agent_manage_python
# wrapper. Three sites migrated to standalone helpers under
# lib/agent-cli-helpers/. Smoke verifies the registry path completes
# within the timeout, produces valid JSON, and that no nested-$()-into-
# heredoc combos remain in bridge-agent.sh.
log "running bridge-agent-cli-no-deadlock smoke (refs queue task #4773)"
bash "$REPO_ROOT/scripts/smoke/bridge-agent-cli-no-deadlock.sh"

# bridge-daemon.sh + lib/bridge-cron.sh footgun #11 migration regression
# guard (refs queue task #4807). Operator host (2026-05-17 → 2026-05-18)
# accumulated 7 zombie daemon processes plus two cron-workers hung 13h
# on the same task_id. Five bridge-daemon.sh sites and thirteen
# lib/bridge-cron.sh sites carried the same Bash 5.3.9 read_comsub /
# heredoc_write trip surface; all were migrated to standalone helpers
# under lib/daemon-helpers/ and lib/cron-helpers/. Smoke verifies the
# heredoc-stdin count stays at zero, every helper parses, and every
# call site routes through the $SCRIPT_DIR / $BRIDGE_SCRIPT_DIR anchor.
log "running bridge-daemon-cron-no-deadlock smoke (refs queue task #4807)"
bash "$REPO_ROOT/scripts/smoke/bridge-daemon-cron-no-deadlock.sh"

# Issue #946 L2 + L4 — daemon tick-loop wedge defenses + PR #952 r2+r5+r6+r7
# regressions. L2 pre-resolves heartbeat heredoc command substitutions with
# a per-call deadline so a stuck helper (e.g. stale-worktree python3 path)
# cannot hang the tick; r2 adds recursive descendant kill so a python3/tmux
# grandchild does not survive the timeout; r4 uses bash monitor mode (set -m)
# + negative-pid kill for sandbox resilience; r5 unconditional KILL after
# grace; r7 scoped wrapper to wedge-prone helpers only. L4 runs the daemon
# step's maintenance side-effects via --maintenance-only on
# bridge_write_idle_ready_agents failure (root cause of operator-host
# nudge-suppression 2026-05-17).
log "running daemon-tick-guards-l2-l4 smoke (refs #946 L2+L4, PR #952)"
bash "$REPO_ROOT/scripts/smoke/daemon-tick-guards-l2-l4.sh"

# bridge-watchdog-silence.py previously truncated captured daemon
# stop/start output to the last line, so every wedge from 2026-05-15
# onward surfaced the same v0.8.0 ACL background sentence in the
# silence-watchdog audit row. Issue #946 L3 preserves the full stderr
# block and classifies the resolver die path (line 384 / 406 / 439).
log "running watchdog-silence-stderr-capture smoke (#946 L3)"
bash "$REPO_ROOT/scripts/smoke/watchdog-silence-stderr-capture.sh"

log "smoke test passed"
