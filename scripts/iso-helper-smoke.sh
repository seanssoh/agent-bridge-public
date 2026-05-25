#!/usr/bin/env bash
# scripts/iso-helper-smoke.sh — unit smoke for the `bridge_iso_run` helper.
#
# Exercises the bridge_iso_run public surface in NON-isolated mode (no sudo,
# no real isolated UID). This is the only mode that can run in CI / on
# operator dev hosts without provisioning. The isolated path is exercised
# manually on Linux VM/operator-host with real provisioned agents and is
# covered by the existing live-install acceptance matrix.
#
# Footgun #11: this script must use pipe-only stdin to subprocesses. No
# heredoc-stdin, no here-string, no process-substitution capture.
#
# Exits 0 on full pass, non-zero on any failed test. Each test prints
# `[ok] <name>` or `[FAIL] <name>: <detail>`.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

FAILS=0
TOTAL=0

_pass() { TOTAL=$((TOTAL + 1)); printf '[ok] %s\n' "$1"; }
_fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '[FAIL] %s: %s\n' "$1" "$2" >&2; }

# Set up an isolated BRIDGE_HOME so the helper does not see the operator's
# live install. We do not call any agent-creation path; we only invoke
# bridge_iso_run + agent-bridge iso-run with synthetic --agent values
# whose allowlist roots we control via BRIDGE_ISO_RUN_ALLOWLIST_EXTRA.
TMPDIR_BASE="${TMPDIR:-/tmp}"
SMOKE_DIR="$(mktemp -d "$TMPDIR_BASE/agb-iso-helper-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR" 2>/dev/null' EXIT INT TERM

export BRIDGE_HOME="$SMOKE_DIR/.agent-bridge"
mkdir -p "$BRIDGE_HOME"

# Synthetic allowlist root — every smoke path lives under SMOKE_DIR/sandbox.
# This bypasses the normal per-agent root resolution (which would need a
# fully provisioned agent) and lets us validate the dispatcher + op tables.
SANDBOX="$SMOKE_DIR/sandbox"
mkdir -p "$SANDBOX"
export BRIDGE_ISO_RUN_ALLOWLIST_EXTRA="$SANDBOX"

# Smoke-only synthetic agent name. The non-isolated direct codepath
# accepts any agent label.
AGENT="smoke-iso-agent"

# Source bridge-lib so the helper is available in this shell. The helper
# delegates to bridge_agent_linux_user_isolation_effective which will
# return false (non-isolated), causing the direct codepath to fire.
# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-lib.sh" >/dev/null 2>&1 || {
  printf '[FAIL] source bridge-lib.sh failed\n' >&2
  exit 1
}

if ! declare -F bridge_iso_run >/dev/null 2>&1; then
  printf '[FAIL] bridge_iso_run not loaded after sourcing bridge-lib.sh\n' >&2
  exit 1
fi

# ---- Test: path allowlist gate ---------------------------------------------

# Unsafe path -> rc 40
rc=0
bridge_iso_run --agent "$AGENT" --op stat --path /etc/passwd --test exists \
  >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 40 ]]; then
  _pass "allowlist gate rejects /etc/passwd with rc=40"
else
  _fail "allowlist gate rejects /etc/passwd with rc=40" "got rc=$rc"
fi

# Sandbox path under EXTRA -> rc allowed (file absent -> 30)
rc=0
bridge_iso_run --agent "$AGENT" --op stat --path "$SANDBOX/missing" --test exists \
  >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 30 ]]; then
  _pass "stat exists on absent file returns rc=30"
else
  _fail "stat exists on absent file returns rc=30" "got rc=$rc"
fi

# ---- Test: stat ops --------------------------------------------------------

echo "hello" >"$SANDBOX/present.txt"
rc=0
bridge_iso_run --agent "$AGENT" --op stat --path "$SANDBOX/present.txt" --test exists \
  >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "stat exists on present file returns rc=0"
else
  _fail "stat exists on present file returns rc=0" "got rc=$rc"
fi

rc=0
bridge_iso_run --agent "$AGENT" --op stat --path "$SANDBOX/present.txt" --test file \
  >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "stat file on regular file returns rc=0"
else
  _fail "stat file on regular file returns rc=0" "got rc=$rc"
fi

mkdir -p "$SANDBOX/subdir"
rc=0
bridge_iso_run --agent "$AGENT" --op stat --path "$SANDBOX/subdir" --test dir \
  >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "stat dir on dir returns rc=0"
else
  _fail "stat dir on dir returns rc=0" "got rc=$rc"
fi

# ---- Test: read-file -------------------------------------------------------

content="$(bridge_iso_run --agent "$AGENT" --op read-file --path "$SANDBOX/present.txt" 2>/dev/null)"
rc=$?
if [[ "$rc" -eq 0 && "$content" == "hello" ]]; then
  _pass "read-file returns file contents"
else
  _fail "read-file returns file contents" "rc=$rc content=$content"
fi

# Absent file -> rc 30
rc=0
bridge_iso_run --agent "$AGENT" --op read-file --path "$SANDBOX/nope.txt" \
  >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 30 ]]; then
  _pass "read-file on absent returns rc=30"
else
  _fail "read-file on absent returns rc=30" "got rc=$rc"
fi

# ---- Test: env-has-any-key -------------------------------------------------

cat >"$SANDBOX/test.env" <<EOF_ENV
# header comment
EMPTY=
HAS_VAL=something
EOF_ENV

rc=0
bridge_iso_run --agent "$AGENT" --op env-has-any-key --path "$SANDBOX/test.env" \
  --key HAS_VAL >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "env-has-any-key matches HAS_VAL"
else
  _fail "env-has-any-key matches HAS_VAL" "got rc=$rc"
fi

rc=0
bridge_iso_run --agent "$AGENT" --op env-has-any-key --path "$SANDBOX/test.env" \
  --key EMPTY >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 31 ]]; then
  _pass "env-has-any-key returns rc=31 on EMPTY= (no value)"
else
  _fail "env-has-any-key returns rc=31 on EMPTY=" "got rc=$rc"
fi

rc=0
bridge_iso_run --agent "$AGENT" --op env-has-any-key --path "$SANDBOX/test.env" \
  --key NONEXISTENT >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 31 ]]; then
  _pass "env-has-any-key returns rc=31 on missing key"
else
  _fail "env-has-any-key returns rc=31 on missing key" "got rc=$rc"
fi

# ---- Test: read-env-key ----------------------------------------------------

val="$(bridge_iso_run --agent "$AGENT" --op read-env-key --path "$SANDBOX/test.env" \
  --key HAS_VAL 2>/dev/null)"
rc=$?
if [[ "$rc" -eq 0 && "$val" == "something" ]]; then
  _pass "read-env-key returns value"
else
  _fail "read-env-key returns value" "rc=$rc val=$val"
fi

# ---- Test: atomic-write via pipe-only stdin --------------------------------

# Stream content via printf | bridge_iso_run --stdin (which becomes the
# helper's stdin). The helper delegates to
# bridge_isolation_write_file_as_agent_user_via_bash on isolated paths;
# on non-isolated paths it uses _bridge_iso_run_atomic_write_direct.
# Both shapes read stdin via `cat -`.
printf 'atomic-payload\n' | bridge_iso_run --agent "$AGENT" --op atomic-write \
  --path "$SANDBOX/atomic.out" --mode 0644 >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then
  if [[ -f "$SANDBOX/atomic.out" ]] && [[ "$(cat "$SANDBOX/atomic.out")" == "atomic-payload" ]]; then
    _pass "atomic-write writes payload via pipe stdin"
  else
    _fail "atomic-write writes payload via pipe stdin" "file missing or mismatched"
  fi
else
  _fail "atomic-write writes payload via pipe stdin" "rc=$rc"
fi

# Atomic-write into a missing parent dir -> rc 5
printf 'x\n' | bridge_iso_run --agent "$AGENT" --op atomic-write \
  --path "$SANDBOX/missing-parent/x.txt" --mode 0644 >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 5 ]]; then
  _pass "atomic-write rejects missing parent dir with rc=5"
else
  _fail "atomic-write rejects missing parent dir with rc=5" "got rc=$rc"
fi

# ---- Test: mkdir-p ---------------------------------------------------------

rc=0
bridge_iso_run --agent "$AGENT" --op mkdir-p --path "$SANDBOX/new-dir/nested" \
  --mode 0750 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 && -d "$SANDBOX/new-dir/nested" ]]; then
  _pass "mkdir-p creates nested dir"
else
  _fail "mkdir-p creates nested dir" "rc=$rc"
fi

# ---- Test: rename ----------------------------------------------------------

echo "renaming" >"$SANDBOX/rename-src"
rc=0
bridge_iso_run --agent "$AGENT" --op rename --from "$SANDBOX/rename-src" \
  --to "$SANDBOX/rename-dst" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 && -f "$SANDBOX/rename-dst" && ! -f "$SANDBOX/rename-src" ]]; then
  _pass "rename moves file"
else
  _fail "rename moves file" "rc=$rc"
fi

# Rename source absent -> rc 30
rc=0
bridge_iso_run --agent "$AGENT" --op rename --from "$SANDBOX/nope-src" \
  --to "$SANDBOX/nope-dst" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 30 ]]; then
  _pass "rename returns rc=30 on absent source"
else
  _fail "rename returns rc=30 on absent source" "got rc=$rc"
fi

# ---- Test: publish-root-file (non-isolated direct codepath) ----------------

# In non-isolated mode the publish-root-file op falls through to a
# controller-side atomic-write (no chown). Validate it writes the file.
printf 'pub-payload\n' | bridge_iso_run --agent "$AGENT" --op publish-root-file \
  --path "$SANDBOX/published.json" --mode 0644 --group-agent "$AGENT" >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 && -f "$SANDBOX/published.json" ]]; then
  _pass "publish-root-file writes payload (non-isolated direct)"
else
  _fail "publish-root-file writes payload (non-isolated direct)" "rc=$rc"
fi

# ---- Test: publish-root-symlink (non-isolated) -----------------------------

rc=0
bridge_iso_run --agent "$AGENT" --op publish-root-symlink \
  --link "$SANDBOX/link-out" --target "$SANDBOX/published.json" \
  --group-agent "$AGENT" >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 && -L "$SANDBOX/link-out" ]]; then
  _pass "publish-root-symlink creates symlink"
else
  _fail "publish-root-symlink creates symlink" "rc=$rc"
fi

# ---- Test: agent-bridge iso-run CLI shim -----------------------------------

# Validate the CLI dispatch token works. Same op as above but via the
# external command (subprocess shape — what bridge_iso_paths.iso_run uses).
"$REPO_ROOT/agent-bridge" iso-run --agent "$AGENT" --op stat \
  --path "$SANDBOX/present.txt" --test exists >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "agent-bridge iso-run CLI shim works (stat)"
else
  _fail "agent-bridge iso-run CLI shim works (stat)" "rc=$rc"
fi

# ---- Test: Python adapter ---------------------------------------------------

# Validate lib/bridge_iso_paths.py:iso_run dispatches correctly to the CLI.
python3 - "$REPO_ROOT" "$SANDBOX" "$AGENT" <<'PY_SMOKE'
import sys
from pathlib import Path

repo_root = sys.argv[1]
sandbox = sys.argv[2]
agent = sys.argv[3]
sys.path.insert(0, str(Path(repo_root) / "lib"))

from bridge_iso_paths import iso_run  # noqa

# Stat the file we wrote earlier.
result = iso_run(agent, "stat", path=f"{sandbox}/present.txt", test="exists")
if result.returncode != 0:
    print(f"py-smoke: stat exists FAIL rc={result.returncode}", file=sys.stderr)
    sys.exit(1)

# Read it back.
result = iso_run(agent, "read-file", path=f"{sandbox}/present.txt")
if result.returncode != 0 or result.stdout.strip() != "hello":
    print(f"py-smoke: read-file FAIL rc={result.returncode} out={result.stdout!r}", file=sys.stderr)
    sys.exit(1)

# Write via stdin.
result = iso_run(
    agent, "atomic-write",
    path=f"{sandbox}/py-write.out", mode="0644", stdin="py-payload\n",
)
if result.returncode != 0:
    print(f"py-smoke: atomic-write FAIL rc={result.returncode} stderr={result.stderr!r}", file=sys.stderr)
    sys.exit(1)
written = Path(f"{sandbox}/py-write.out").read_text()
if written != "py-payload\n":
    print(f"py-smoke: payload mismatch {written!r}", file=sys.stderr)
    sys.exit(1)

# Unsafe path → 40.
result = iso_run(agent, "stat", path="/etc/passwd", test="exists")
if result.returncode != 40:
    print(f"py-smoke: unsafe path FAIL rc={result.returncode}", file=sys.stderr)
    sys.exit(1)

print("py-smoke: OK")
PY_SMOKE
rc=$?
if [[ "$rc" -eq 0 ]]; then
  _pass "Python adapter (bridge_iso_paths.iso_run) round-trip"
else
  _fail "Python adapter (bridge_iso_paths.iso_run) round-trip" "rc=$rc"
fi

# ---- Summary ----------------------------------------------------------------

printf '\n[summary] %d/%d tests passed\n' $((TOTAL - FAILS)) "$TOTAL"
if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
exit 0
