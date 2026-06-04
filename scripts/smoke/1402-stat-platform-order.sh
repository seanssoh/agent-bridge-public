#!/usr/bin/env bash
# Issue #1402 regression smoke — `_bridge_rewrite_session_id_in_file`
# (lib/bridge-state.sh) must read the file mode with the canonical
# GNU-first `stat -c '%a' || stat -f '%Lp'` order before chmod'ing the
# rewritten inode, so the rewrite preserves the original mode on GNU/Linux.
#
# Bug: the helper read the mode BSD-first
#   `stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null`.
# On GNU coreutils `stat -f` selects *filesystem* (statvfs) status — NOT
# the file mode — so `stat -f '%Lp' FILE` emits a statvfs blob (or a wrong
# value) and the captured `$mode` is polluted. That polluted string is then
# fed to `chmod "$mode" "$tmp"`, so the atomic rewrite drops the file's
# original mode on Linux (a 0600 overlay snapshot would not round-trip).
# Every other stat site in the repo already uses the GNU-first order; this
# aligns bridge-state.sh to that canonical order.
#
# This smoke is platform-deterministic: it prepends a fake `stat` to $PATH
# that mimics GNU coreutils (the `-f` form emits a statvfs-shaped blob and
# exits non-zero; the `-c '%a'` form returns the clean octal mode). Under
# the FIXED GNU-first order the clean mode wins and the file mode round-trips
# to 0600. Under the pre-fix BSD-first order the `-f` form would have been
# tried first and (had it exited 0 with a blob) polluted the chmod — the
# negative check pins that the fake-GNU `-f` form is genuinely non-clean.

set -u

if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "[smoke:1402-stat-platform-order] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1402-stat-platform-order"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "1402-stat-platform-order"

REPO_ROOT="$SMOKE_REPO_ROOT"

# Source the library functions under test.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

if ! declare -F _bridge_rewrite_session_id_in_file >/dev/null; then
  smoke_fail "_bridge_rewrite_session_id_in_file not defined after sourcing bridge-lib.sh"
fi

# ---------------------------------------------------------------------
# Build a fake `stat` that mimics GNU coreutils, so the test exercises the
# Linux code path deterministically on any host (including macOS, whose
# real BSD `stat -f '%Lp'` would otherwise mask the bug).
#
#   stat -c '%a' FILE  -> clean octal mode, exit 0   (GNU long-bits form)
#   stat -f ... FILE   -> statvfs-shaped blob, exit 1 (GNU filesystem form)
# ---------------------------------------------------------------------
FAKE_BIN="$SMOKE_TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/stat" <<'FAKE'
#!/usr/bin/env bash
# Minimal GNU-coreutils-shaped `stat` stub for the #1402 smoke.
mode="$1"
if [[ "$mode" == "-c" ]]; then
  # GNU long-bits mode form: print the file's low-12-bit octal mode.
  fmt="$2"
  file="$3"
  if [[ "$fmt" != "%a" ]]; then
    echo "fake stat: unexpected -c format '$fmt'" >&2
    exit 64
  fi
  if command python3 - "$file" <<'PY' 2>/dev/null
import os, sys
print(format(os.stat(sys.argv[1]).st_mode & 0o7777, 'o'))
PY
  then
    exit 0
  fi
  exit 1
elif [[ "$mode" == "-f" ]]; then
  # GNU `stat -f` reads FILESYSTEM (statvfs) status, NOT file mode. Emit a
  # statvfs-shaped blob and exit non-zero, exactly the wrong-order trap the
  # BSD-first ordering fell into on Linux.
  printf '  File: "%s"\n    ID: 0 Namelen: 255 Type: ext2/ext3\n' "${*: -1}"
  exit 1
fi
echo "fake stat: unexpected args: $*" >&2
exit 64
FAKE
chmod +x "$FAKE_BIN/stat"

# ---------------------------------------------------------------------
# Sanity — the fake `stat -f` form must NOT return a clean mode (it stands
# in for the GNU statvfs-blob trap). If it ever did, the test would be
# vacuous.
# ---------------------------------------------------------------------
sanity_target="$SMOKE_TMP_ROOT/sanity.env"
: >"$sanity_target"
chmod 0600 "$sanity_target"
fake_f_out="$(PATH="$FAKE_BIN:$PATH" stat -f '%Lp' "$sanity_target" 2>/dev/null || true)"
if [[ "$fake_f_out" == "600" || "$fake_f_out" == "0600" ]]; then
  smoke_fail "sanity: fake GNU 'stat -f' unexpectedly returned a clean mode ('$fake_f_out'); test would be vacuous"
fi
smoke_log "sanity: fake GNU 'stat -f' is non-clean as expected (out='${fake_f_out//$'\n'/ }')"

# ---------------------------------------------------------------------
# T1 — mode preservation under the GNU-shaped stat. Rewrite an active-style
# env file carrying AGENT_SESSION_ID at mode 0600 and assert the rewritten
# file keeps 0600 (the chmod fed clean '600', not a statvfs blob).
# ---------------------------------------------------------------------
test_mode_preserved_gnu_first() {
  smoke_log "T1: mode round-trips through _bridge_rewrite_session_id_in_file under GNU-shaped stat"

  local target="$SMOKE_TMP_ROOT/active.env"
  cat >"$target" <<'ENV'
AGENT_SESSION_ID='abc123'
AGENT_ENGINE='claude'
ENV
  chmod 0600 "$target"

  local before_mode after_mode rc
  before_mode="$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o7777, "o"))' "$target")"
  smoke_assert_eq "600" "$before_mode" "T1 precondition: target starts 0600"

  PATH="$FAKE_BIN:$PATH" _bridge_rewrite_session_id_in_file "someagent" "$target"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    smoke_fail "T1: rewrite returned rc=$rc (expected 0)"
  fi

  after_mode="$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o7777, "o"))' "$target")"
  smoke_assert_eq "600" "$after_mode" "T1: rewritten file mode must round-trip to 0600 (not a statvfs blob)"

  # The session id must actually be cleared (the rewrite did its job).
  local id_line
  id_line="$(grep '^AGENT_SESSION_ID=' "$target" || true)"
  smoke_assert_eq "AGENT_SESSION_ID=''" "$id_line" "T1: AGENT_SESSION_ID cleared in place"
  # Sibling keys survive.
  smoke_assert_contains "$(cat "$target")" "AGENT_ENGINE='claude'" "T1: sibling key AGENT_ENGINE preserved"
}

# ---------------------------------------------------------------------
# T2 — canonical-order guard. The source must read mode GNU-first
# (`stat -c '%a'` BEFORE `stat -f '%Lp'`) so a future refactor cannot
# silently revert to the BSD-first wrong-order class.
# ---------------------------------------------------------------------
test_source_uses_gnu_first_order() {
  smoke_log "T2: bridge-state.sh reads file mode GNU-first (stat -c before stat -f)"

  local state_lib="$REPO_ROOT/lib/bridge-state.sh"
  local c_line f_line
  c_line="$(grep -n "stat -c '%a' \"\$file\"" "$state_lib" | head -n1 | cut -d: -f1 || true)"
  f_line="$(grep -n "stat -f '%Lp' \"\$file\"" "$state_lib" | head -n1 | cut -d: -f1 || true)"

  [[ -n "$c_line" ]] || smoke_fail "T2: expected a \`stat -c '%a' \"\$file\"\` site in bridge-state.sh"
  [[ -n "$f_line" ]] || smoke_fail "T2: expected a \`stat -f '%Lp' \"\$file\"\` site in bridge-state.sh"

  if [[ "$c_line" -ge "$f_line" ]]; then
    smoke_fail "T2: GNU \`stat -c\` (line $c_line) must precede BSD \`stat -f\` (line $f_line) — BSD-first is the #1402 wrong-order class"
  fi
  smoke_log "T2: ok — stat -c at line $c_line precedes stat -f at line $f_line"
}

smoke_run "T1 mode-preserved-gnu-first" test_mode_preserved_gnu_first
smoke_run "T2 source-uses-gnu-first-order" test_source_uses_gnu_first_order

smoke_log "PASS"
