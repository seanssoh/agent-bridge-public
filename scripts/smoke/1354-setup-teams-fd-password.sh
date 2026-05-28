#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1354-setup-teams-fd-password.sh — Issue #1354
# (v0.15.0-beta5-2 Track B).
#
# Pins FD-aware `read_secret_value` ingestion in bridge-setup.py so the
# documented Bash process-substitution shape (`--app-password-file
# <(printf '%s' "$secret")` → `/dev/fd/N`) works as a regression with
# regular-file paths, plus the new `--app-password-stdin` and
# `--client-secret-stdin` first-class flags. Pre-fix, `Path.is_file()`
# returned False for `/dev/fd/63` (a character device) and the wizard
# aborted with `Secret file not found: /dev/fd/63` — see the issue body
# for the patch-side reproducer.
#
# Tests:
#   T1 (root):   teams --app-password-file <(printf '%s' "$SECRET") →
#                wizard reads via FD path, dry-run completes, write_status
#                marker prints. Catches a future patch that re-introduces
#                an is_file/is_regular gate.
#   T2 (regression): teams --app-password-file /path/to/regular-file →
#                still works. Catches an over-restrictive open() with mode
#                that excluded regular files.
#   T3 (stdin): teams --app-password-stdin + piped stdin → wizard reads
#                stdin once and the secret reaches .teams/.env.
#   T4 (fail-loud): teams --app-password-file /nonexistent → fail-loud
#                with a hint that names process-substitution + sudo +
#                tempfile/stdin alternatives. Catches a future patch that
#                drops the rephrased error message.
#   T5 (teeth):  verify read_secret_value no longer routes through
#                `Path.is_file()`. A `grep -E "is_file\\(\\)" bridge-setup.py`
#                within the read_secret_value body must return zero hits.
#                This is the regression detector: if the FD-aware open
#                path gets reverted, this fails immediately even if a
#                future copy of T1/T2 silently regresses.
#
# Footgun #11: every captured subprocess uses `out=$(... 2>&1)`. The FD
# delivery (T1) happens inside a child Bash so the `<(...)` substitution
# is performed in the child shell where it is meaningful. No `<<EOF`
# into a subprocess that owns its own stdin.

if [[ "${BRIDGE_SMOKE_BASH4_REEXEC:-0}" != "1" && "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$_candidate" ]] && "$_candidate" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      BRIDGE_SMOKE_BASH4_REEXEC=1 exec "$_candidate" "$0" "$@"
    fi
  done
  echo "[smoke:1354-setup-teams-fd-password][error] bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
  exit 1
fi

set -uo pipefail

SMOKE_NAME="1354-setup-teams-fd-password"
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
BRIDGE_SETUP_SH="$REPO_ROOT/bridge-setup.sh"
BRIDGE_SETUP_PY="$REPO_ROOT/bridge-setup.py"

smoke_assert_file_exists "$BRIDGE_SETUP_SH" "bridge-setup.sh present"
smoke_assert_file_exists "$BRIDGE_SETUP_PY" "bridge-setup.py present"

# Pick a Bash 4+ interpreter — process substitution shape is a Bash
# extension, so we need a Bash interpreter for T1.
BRIDGE_BASH="${BRIDGE_BASH_BIN:-$(command -v bash)}"
if [[ "$(uname -s 2>/dev/null || printf '')" == "Darwin" ]]; then
  if [[ -x /opt/homebrew/bin/bash ]]; then
    BRIDGE_BASH=/opt/homebrew/bin/bash
  elif [[ -x /usr/local/bin/bash ]]; then
    BRIDGE_BASH=/usr/local/bin/bash
  fi
fi
export BRIDGE_BASH_BIN="$BRIDGE_BASH"

# Register a synthetic claude agent in the isolated roster so
# bridge_require_agent / bridge_setup_require_claude_agent don't trip
# before the secret ingestion path is exercised.
{
  printf '#!/usr/bin/env bash\n'
  printf '# shellcheck shell=bash disable=SC2034\n'
  printf 'bridge_add_agent_id_if_missing "fd-test"\n'
  printf 'BRIDGE_AGENT_DESC["fd-test"]="setup teams fd-password smoke target"\n'
  printf 'BRIDGE_AGENT_ENGINE["fd-test"]="claude"\n'
  printf 'BRIDGE_AGENT_SESSION["fd-test"]="fd-test"\n'
  printf 'BRIDGE_AGENT_WORKDIR["fd-test"]="%s"\n' "$BRIDGE_AGENT_HOME_ROOT/fd-test"
} >"$BRIDGE_ROSTER_LOCAL_FILE"

mkdir -p "$BRIDGE_AGENT_HOME_ROOT/fd-test"

EXPECTED_SECRET='super-secret-bot-password-1354'

# ----------------------------------------------------------------------------
# T1: process-substitution FD path — the documented + previously broken shape.
# `<(printf '%s' "$secret")` produces `/dev/fd/N`; before the fix, Path.is_file()
# returned False and the wizard aborted before opening the FD.
# ----------------------------------------------------------------------------
smoke_log "T1: setup teams --app-password-file <(printf ...) → wizard opens /dev/fd/N"
T1_OUT=""
T1_RC=0
# Use a child Bash so the process substitution is interpreted in a shell
# that supports it. The captured stdout/stderr is the bridge-setup
# subprocess output.
T1_OUT="$("$BRIDGE_BASH" -c '
  set -uo pipefail
  export BRIDGE_HOME='"\"$BRIDGE_HOME\""'
  export BRIDGE_STATE_DIR='"\"$BRIDGE_STATE_DIR\""'
  export BRIDGE_LOG_DIR='"\"$BRIDGE_LOG_DIR\""'
  export BRIDGE_SHARED_DIR='"\"$BRIDGE_SHARED_DIR\""'
  export BRIDGE_ACTIVE_AGENT_DIR='"\"$BRIDGE_ACTIVE_AGENT_DIR\""'
  export BRIDGE_AGENT_HOME_ROOT='"\"$BRIDGE_AGENT_HOME_ROOT\""'
  export BRIDGE_ROSTER_LOCAL_FILE='"\"$BRIDGE_ROSTER_LOCAL_FILE\""'
  export BRIDGE_SETUP_WIZARD_SKIP_PROBES=1
  bash '"\"$BRIDGE_SETUP_SH\""' teams fd-test \
    --app-id "test-app-id" \
    --app-password-file <(printf "%s" "'"$EXPECTED_SECRET"'") \
    --tenant-id "test-tenant" \
    --allow-from "user-aad-1" \
    --messaging-endpoint "https://bot.example.com/api/messages" \
    --webhook-host "0.0.0.0" \
    --webhook-port "3978" \
    --skip-validate --skip-send-test \
    --yes --dry-run 2>&1
' 2>&1)" || T1_RC=$?
if (( T1_RC == 0 )); then
  smoke_log "T1 ok: process-substitution FD path accepted (rc=0)"
  # write_status: dry_run is the canonical "wizard ran to completion in
  # dry-run mode" marker.
  smoke_assert_contains "$T1_OUT" "write_status: dry_run" "T1 dry_run marker (wizard ran)"
else
  smoke_fail "T1: FD path setup teams exited rc=$T1_RC; out: $T1_OUT"
fi

# ----------------------------------------------------------------------------
# T2 (regression): plain regular file still works — guard against an
# over-restrictive open path that excluded regulars.
# ----------------------------------------------------------------------------
smoke_log "T2: setup teams --app-password-file /path/to/regular-file → still works"
REGULAR_FILE="$SMOKE_TMP_ROOT/regular-password.txt"
printf '%s' "$EXPECTED_SECRET" >"$REGULAR_FILE"
chmod 0600 "$REGULAR_FILE"
T2_OUT=""
T2_RC=0
T2_OUT="$("$BRIDGE_BASH" "$BRIDGE_SETUP_SH" teams fd-test \
  --app-id "test-app-id" \
  --app-password-file "$REGULAR_FILE" \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "https://bot.example.com/api/messages" \
  --webhook-host "0.0.0.0" \
  --webhook-port "3978" \
  --skip-validate --skip-send-test \
  --yes --dry-run 2>&1)" || T2_RC=$?
export BRIDGE_SETUP_WIZARD_SKIP_PROBES=1
if (( T2_RC == 0 )); then
  smoke_log "T2 ok: regular-file path accepted (rc=0)"
  smoke_assert_contains "$T2_OUT" "write_status: dry_run" "T2 dry_run marker (regression)"
else
  smoke_fail "T2: regular-file setup teams exited rc=$T2_RC; out: $T2_OUT"
fi

# ----------------------------------------------------------------------------
# T3 (stdin): --app-password-stdin reads the secret once from stdin.
# Portable across sudo-subshell wrappers, unlike `<(...)`.
# ----------------------------------------------------------------------------
smoke_log "T3: setup teams --app-password-stdin + piped stdin → wizard reads stdin"
T3_OUT=""
T3_RC=0
T3_OUT="$(printf '%s' "$EXPECTED_SECRET" | "$BRIDGE_BASH" "$BRIDGE_SETUP_SH" teams fd-test \
  --app-id "test-app-id" \
  --app-password-stdin \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "https://bot.example.com/api/messages" \
  --webhook-host "0.0.0.0" \
  --webhook-port "3978" \
  --skip-validate --skip-send-test \
  --yes --dry-run 2>&1)" || T3_RC=$?
if (( T3_RC == 0 )); then
  smoke_log "T3 ok: --app-password-stdin accepted (rc=0)"
  smoke_assert_contains "$T3_OUT" "write_status: dry_run" "T3 dry_run marker (stdin path)"
else
  smoke_fail "T3: --app-password-stdin setup teams exited rc=$T3_RC; out: $T3_OUT"
fi

# ----------------------------------------------------------------------------
# T4 (fail-loud): nonexistent file path must surface a hint that names
# the process-substitution + sudo interaction and the alternatives.
# ----------------------------------------------------------------------------
smoke_log "T4: setup teams --app-password-file /nonexistent → fail-loud with hint"
T4_OUT=""
T4_RC=0
T4_OUT="$("$BRIDGE_BASH" "$BRIDGE_SETUP_SH" teams fd-test \
  --app-id "test-app-id" \
  --app-password-file "/nonexistent/path/that/cannot/be/opened" \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "https://bot.example.com/api/messages" \
  --webhook-host "0.0.0.0" \
  --webhook-port "3978" \
  --skip-validate --skip-send-test \
  --yes --dry-run 2>&1)" || T4_RC=$?
if (( T4_RC != 0 )); then
  smoke_log "T4 ok: nonexistent file path failed loudly (rc=$T4_RC)"
  # The error message must name --app-password-file (the flag the
  # operator passed) and either --app-password-stdin or regular-file as
  # the alternative. Pre-fix it said only "Secret file not found".
  smoke_assert_contains "$T4_OUT" "--app-password-file" "T4 error names the flag the operator passed"
  smoke_assert_contains "$T4_OUT" "--app-password-stdin" "T4 error names --app-password-stdin alternative"
else
  smoke_fail "T4: nonexistent file path unexpectedly exited 0; out: $T4_OUT"
fi

# ----------------------------------------------------------------------------
# T5 (teeth): regression detector. read_secret_value must not gate on
# Path.is_file() anymore — that was the exact bug. A grep over the body
# of the function for the literal `is_file()` keeps a future revert
# honest.
# ----------------------------------------------------------------------------
smoke_log "T5 (teeth): read_secret_value body no longer routes through is_file()"
T5_RC=0
T5_OUT="$(python3 - "$BRIDGE_SETUP_PY" <<'PY' 2>&1
import ast, sys
path = sys.argv[1]
src = open(path, "r", encoding="utf-8").read()
tree = ast.parse(src)
fn = None
for node in ast.walk(tree):
    if isinstance(node, ast.FunctionDef) and node.name == "read_secret_value":
        fn = node
        break
if fn is None:
    print("ERROR: cannot locate read_secret_value function")
    sys.exit(2)
# Walk the AST body — does any expression call `Path.is_file()` /
# `path.is_file()` as a gating check? Comments and docstrings are not
# in the AST, so this scan is clean.
hits = []
for node in ast.walk(fn):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        if node.func.attr == "is_file":
            hits.append(ast.unparse(node))
if hits:
    print("FOUND is_file() call(s) in read_secret_value AST:")
    for h in hits:
        print("  " + h)
    sys.exit(1)
print("read_secret_value AST has no is_file() gate")
PY
)" || T5_RC=$?
if (( T5_RC == 0 )); then
  smoke_log "T5 ok: $T5_OUT"
else
  smoke_fail "T5: read_secret_value still gates on is_file() — would re-break FD path. Output: $T5_OUT"
fi

# ----------------------------------------------------------------------------
# T6 (R2 — codex r1 BLOCKING #1): `--app-password-file` and
# `--app-password-stdin` are mutually exclusive at argparse level. Passing
# both must exit non-zero with an argparse error (not silently prefer
# stdin and drop the file value).
# ----------------------------------------------------------------------------
smoke_log "T6 (R2): --app-password-file + --app-password-stdin must fail-loud (mutex)"
REGULAR_FILE_FOR_MUTEX="$SMOKE_TMP_ROOT/mutex-regular.txt"
printf '%s' "file-value-should-not-be-picked" >"$REGULAR_FILE_FOR_MUTEX"
chmod 0600 "$REGULAR_FILE_FOR_MUTEX"
T6_OUT=""
T6_RC=0
T6_OUT="$(printf '%s' "stdin-value" | "$BRIDGE_BASH" "$BRIDGE_SETUP_SH" teams fd-test \
  --app-id "test-app-id" \
  --app-password-file "$REGULAR_FILE_FOR_MUTEX" \
  --app-password-stdin \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "https://bot.example.com/api/messages" \
  --webhook-host "0.0.0.0" \
  --webhook-port "3978" \
  --skip-validate --skip-send-test \
  --yes --dry-run 2>&1)" || T6_RC=$?
if (( T6_RC != 0 )); then
  smoke_log "T6 ok: both flags rejected (rc=$T6_RC)"
  # argparse mutex error message includes the second flag listed as
  # "not allowed with" the first. Either ordering of the flag names is
  # acceptable; we only assert that argparse's mutex shape fired.
  smoke_assert_contains "$T6_OUT" "not allowed with" "T6 argparse mutex error surfaced"
else
  smoke_fail "T6: passing both --app-password-file and --app-password-stdin should fail; out: $T6_OUT"
fi

# ----------------------------------------------------------------------------
# T7 (R2 — codex r1 BLOCKING #1, ms365): same mutex shape for
# `--client-secret-file` + `--client-secret-stdin` in the ms365 subcommand.
# Mirror T6 to catch a future divergence where one subcommand keeps the
# mutex and the other drops it.
# ----------------------------------------------------------------------------
smoke_log "T7 (R2): --client-secret-file + --client-secret-stdin must fail-loud (mutex)"
T7_RC=0
T7_OUT="$(printf '%s' "stdin-value" | "$BRIDGE_BASH" "$BRIDGE_SETUP_SH" ms365 fd-test \
  --redirect-uri "https://bot.example.com/auth/callback" \
  --tenant-id "test-tenant" \
  --client-id "test-client" \
  --client-secret-file "$REGULAR_FILE_FOR_MUTEX" \
  --client-secret-stdin \
  --default-upn "user@example.com" \
  --default-scopes "openid profile" \
  --yes --dry-run 2>&1)" || T7_RC=$?
if (( T7_RC != 0 )); then
  smoke_log "T7 ok: both ms365 secret flags rejected (rc=$T7_RC)"
  smoke_assert_contains "$T7_OUT" "not allowed with" "T7 ms365 argparse mutex error surfaced"
else
  smoke_fail "T7: passing both --client-secret-file and --client-secret-stdin should fail; out: $T7_OUT"
fi

# ----------------------------------------------------------------------------
# T8 (R2 — codex r1 BLOCKING #2): handler-level `.strip()` no longer
# undoes read_secret_value's single-newline contract. AST teeth: scan
# `cmd_teams` and `cmd_ms365` function bodies and assert NO `.strip()`
# is invoked on an expression that includes a `*_arg` name (the
# read_secret_value return). Pre-R2 the offenders were `str(app_password_arg
# or ...).strip()` (teams) and `(client_secret_arg or ...).strip()`
# (ms365); the R2 fix splits both into a guarded if/else.
# ----------------------------------------------------------------------------
smoke_log "T8 (R2 teeth): no handler-level .strip() on secret-arg expressions"
T8_RC=0
T8_OUT="$(python3 - "$BRIDGE_SETUP_PY" <<'PY' 2>&1
import ast, sys
path = sys.argv[1]
src = open(path, "r", encoding="utf-8").read()
tree = ast.parse(src)

def names_in(node):
    return {n.id for n in ast.walk(node) if isinstance(n, ast.Name)}

violations = []
for fn in ast.walk(tree):
    if not isinstance(fn, ast.FunctionDef):
        continue
    if fn.name not in ("cmd_teams", "cmd_ms365"):
        continue
    for call in ast.walk(fn):
        if not isinstance(call, ast.Call):
            continue
        func = call.func
        if not isinstance(func, ast.Attribute):
            continue
        if func.attr != "strip":
            continue
        # Look at the receiver expression — does it reference a
        # *_arg name that comes from read_secret_value?
        recv_names = names_in(func.value)
        if "app_password_arg" in recv_names or "client_secret_arg" in recv_names:
            try:
                rendered = ast.unparse(call)
            except AttributeError:
                rendered = "<call>"
            violations.append(f"{fn.name}: {rendered}")

if violations:
    print("FOUND .strip() on secret-arg expression(s) (would undo read_secret_value newline contract):")
    for v in violations:
        print("  " + v)
    sys.exit(1)
print("cmd_teams / cmd_ms365 handler bodies have no .strip() on *_arg expressions")
PY
)" || T8_RC=$?
if (( T8_RC == 0 )); then
  smoke_log "T8 ok: $T8_OUT"
else
  smoke_fail "T8: handler-level .strip() on secret arg would silently truncate secrets. Output: $T8_OUT"
fi

# ----------------------------------------------------------------------------
# T9 (R2 — codex r2 review): argparse mutex must fire even with the
# explicit empty-string file value. Before R2, `default=""` made
# argparse treat `--app-password-file ''` as a no-op (equivalent to not
# passing the flag), so the mutex group missed `--app-password-file ''
# --app-password-stdin` and the wizard silently preferred stdin. R2
# switches to `default=None` so argparse properly tracks "user passed"
# vs "default."
# ----------------------------------------------------------------------------
smoke_log "T9 (R2): empty-string --app-password-file + --app-password-stdin must still fail-loud"
T9_RC=0
T9_OUT="$(printf '%s' "stdin-value" | "$BRIDGE_BASH" "$BRIDGE_SETUP_SH" teams fd-test \
  --app-id "test-app-id" \
  --app-password-file "" \
  --app-password-stdin \
  --tenant-id "test-tenant" \
  --allow-from "user-aad-1" \
  --messaging-endpoint "https://bot.example.com/api/messages" \
  --webhook-host "0.0.0.0" \
  --webhook-port "3978" \
  --skip-validate --skip-send-test \
  --yes --dry-run 2>&1)" || T9_RC=$?
if (( T9_RC != 0 )); then
  smoke_log "T9 ok: empty-string file value still triggers mutex (rc=$T9_RC)"
  smoke_assert_contains "$T9_OUT" "not allowed with" "T9 argparse mutex error fires on empty-string file value"
else
  smoke_fail "T9: --app-password-file '' --app-password-stdin must fail-loud (argparse default=None contract); out: $T9_OUT"
fi

smoke_log "all tests PASS"
