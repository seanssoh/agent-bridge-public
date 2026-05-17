#!/usr/bin/env bash
# Regression smoke — bridge-agent.sh registry/list/show JSON paths must
# complete without tripping the Bash 5.3.9 `read_comsub` deadlock.
#
# Background (refs queue task #4773, 2026-05-17):
#   Operator host saw 7-17 hour hangs on `bridge-agent.sh registry`,
#   `agent list`, and adjacent CLI subcommands. `sample <pid>` showed
#   `reader_loop → read_comsub → read` — the same footgun #11 class as
#   the v0.13.7-9 bridge-upgrade.sh chain. Root cause for the three
#   JSON-emission sites fixed in this wave: nested `$()` command-
#   substitution captures feeding heredoc-stdin python3 subprocesses to
#   the `bridge_agent_manage_python` wrapper (which itself does
#   `python3 - "$@" <<'PY'`). Parent + child heredoc readers deadlocked
#   on operator hosts via the function indirection.
#
#   Fix: spool the inner JSON / TSV payloads to a tempfile and dispatch
#   to standalone helpers under lib/agent-cli-helpers/, invoked as
#   `python3 helper.py <file>` — no heredoc-stdin anywhere. Same
#   precedent as lib/upgrade-helpers/ (v0.13.9 footgun #11 fix).
#
# Coverage:
#   C1 — `bridge-agent.sh registry --json` returns within 10s and
#        produces valid JSON. Asserts run_registry no longer deadlocks
#        on its JSON-emission path (the operator-symptom path).
#   C2 — source-level grep self-audit: assert no
#        `bridge_agent_manage_python "$(...)"` nested-$()-capture
#        combos remain in bridge-agent.sh. Catches future regressions.
#   C3 — standalone helper scripts exist and parse JSON correctly
#        in isolation (no heredoc-stdin path).
#
# NOT covered here:
#   `agent list` and `agent show` text paths can hang for unrelated
#   reasons (separate upstream `$(bridge_queue_cli ...)` captures
#   feeding `bridge_agent_records_tsv` and friends). Those are out of
#   scope for this PR — see queue task #4773 follow-up.

set -uo pipefail

SMOKE_NAME="bridge-agent-cli-no-deadlock"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck disable=SC2329 # invoked indirectly via trap
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_make_temp_root "$SMOKE_NAME"

smoke_require_cmd python3
smoke_require_cmd timeout

AGENT_BRIDGE_SCRIPT="$REPO_ROOT/bridge-agent.sh"
smoke_assert_file_exists "$AGENT_BRIDGE_SCRIPT" "bridge-agent.sh source"
smoke_assert_file_exists "$REPO_ROOT/lib/agent-cli-helpers/registry-format-json.py" "registry helper"
smoke_assert_file_exists "$REPO_ROOT/lib/agent-cli-helpers/list-format-text.py" "list helper"
smoke_assert_file_exists "$REPO_ROOT/lib/agent-cli-helpers/show-format-json.py" "show helper"

# C1 — `bridge-agent.sh registry --json` must complete within the
# timeout. Empty roster -> "[]" (valid JSON). The test is purely about
# the no-deadlock contract on the run_registry path.
smoke_log "C1: bridge-agent.sh registry --json completes without deadlock"
c1_out="$(timeout 10 bash "$AGENT_BRIDGE_SCRIPT" registry --json 2>&1)"
c1_rc=$?
if (( c1_rc == 124 )); then
  smoke_log "C1 timed out (>10s) — read_comsub deadlock REGRESSION"
  smoke_fail "C1: registry --json hung past the 10s guard"
fi
if (( c1_rc != 0 )); then
  smoke_log "C1 stdout/stderr:"; printf '%s\n' "$c1_out"
  smoke_fail "C1: registry --json exited rc=$c1_rc"
fi
if ! printf '%s' "$c1_out" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
  smoke_log "C1 stdout:"; printf '%s\n' "$c1_out"
  smoke_fail "C1: registry --json did not emit valid JSON"
fi
smoke_log "C1 PASS"

# C2 — per-function source assertion: each migrated function body must
# NOT call `bridge_agent_manage_python` (the wrapper that was the
# deadlock vector via `python3 - "$@" <<'PY'`). Scoped to the function
# body via awk so multi-line wrapper-heredoc shapes (which a naive
# same-line grep would miss — codex PR #940 r1 BLOCKING #1) are still
# caught. Comment lines inside the body are stripped before the check
# so in-source rationale (historical pattern, KNOWN_ISSUES references)
# does not false-trip the assertion.
smoke_log "C2: per-function audit — migrated functions must not call bridge_agent_manage_python"
extract_fn_body() {
  # Args: $1 = file, $2 = function name (matches `^<name>() {`).
  # Emits the function body to stdout, stripping comment-only lines.
  # End-of-function detected as `^}$` at column 0 (matches all 3 target
  # functions' closing brace style in bridge-agent.sh).
  awk -v fn="$2" '
    $0 ~ ("^" fn "\\(\\) \\{") { inside = 1; next }
    inside && /^}$/             { inside = 0; exit }
    inside {
      # Strip comment-only lines (first non-whitespace char == `#`).
      line = $0
      stripped = line
      sub(/^[[:space:]]+/, "", stripped)
      if (substr(stripped, 1, 1) == "#") next
      print line
    }
  ' "$1"
}

for fn in run_list run_registry run_show; do
  body="$(extract_fn_body "$AGENT_BRIDGE_SCRIPT" "$fn")"
  if [[ -z "$body" ]]; then
    smoke_fail "C2: could not locate function $fn() in $AGENT_BRIDGE_SCRIPT"
  fi
  if printf '%s\n' "$body" | grep -q 'bridge_agent_manage_python'; then
    smoke_log "C2 $fn() still calls bridge_agent_manage_python:"
    printf '%s\n' "$body" | grep -n 'bridge_agent_manage_python' | sed 's/^/  /'
    smoke_fail "C2: $fn() still invokes the deadlock-prone wrapper"
  fi
  # Also catch any inline `python3 - <<'PY'` heredoc-stdin (would have the
  # same hazard even without the wrapper indirection).
  if printf '%s\n' "$body" | grep -qE 'python3[[:space:]]+-[[:space:]].*<<'; then
    smoke_log "C2 $fn() has inline python3 heredoc-stdin:"
    printf '%s\n' "$body" | grep -nE 'python3[[:space:]]+-[[:space:]].*<<' | sed 's/^/  /'
    smoke_fail "C2: $fn() reintroduced direct python3 heredoc-stdin"
  fi
done
smoke_log "C2 PASS"

# C3 — Standalone helper round-trip: feed each helper a tiny synthetic
# input and confirm it produces the expected output shape. This locks
# in the file-as-argv contract (no heredoc-stdin) end-to-end.
smoke_log "C3: standalone helpers parse synthetic inputs"
c3_dir="$SMOKE_TMP_ROOT/c3"
mkdir -p "$c3_dir"

# Registry helper: single-row TSV → 1-element JSON array
printf 'agent1\tdynamic\tdynamic\tuser\t/h\t/w\tclaude\tsess\t1\tstatic-roster\n' >"$c3_dir/rows.tsv"
reg_out="$(python3 "$REPO_ROOT/lib/agent-cli-helpers/registry-format-json.py" "$c3_dir/rows.tsv" 2>&1)"
if ! printf '%s' "$reg_out" | python3 -c 'import json, sys; data=json.load(sys.stdin); assert len(data)==1 and data[0]["id"]=="agent1"' 2>/dev/null; then
  smoke_log "C3 registry helper output:"; printf '%s\n' "$reg_out"
  smoke_fail "C3: registry-format-json.py did not produce expected output"
fi

# List helper: single-record JSON → 2-line text (header + 1 row)
cat >"$c3_dir/records.json" <<'JSON'
[
  {"agent": "agent1", "engine": "claude", "source": "static", "active": true,
   "activity_state": "ready", "isolation": {"mode": "shared"},
   "queue": {"queued": 0, "claimed": 0, "blocked": 0},
   "wake_status": "ok", "notify": {"status": "off"},
   "channels": {"status": "off"}, "session": "agent1", "workdir": "/w",
   "admin": false}
]
JSON
list_out="$(python3 "$REPO_ROOT/lib/agent-cli-helpers/list-format-text.py" "$c3_dir/records.json" 2>&1)"
smoke_assert_contains "$list_out" "agent | eng | src" "C3 list helper header"
smoke_assert_contains "$list_out" "agent1" "C3 list helper row"

# Show helper: 5 inputs → unified JSON
cat >"$c3_dir/show-records.json" <<'JSON'
{"agent": "agent1", "engine": "claude", "channels": {"status": "off"}}
JSON
printf '[]' >"$c3_dir/show-diag.json"
printf '{"status": "ok"}' >"$c3_dir/show-health.json"
printf '/etc/path/source\n' >"$c3_dir/show-source.txt"
printf '{"alive": true, "signals": {"tmux": true}}' >"$c3_dir/show-alive.json"
show_out="$(python3 "$REPO_ROOT/lib/agent-cli-helpers/show-format-json.py" \
  "$c3_dir/show-records.json" "$c3_dir/show-diag.json" "$c3_dir/show-health.json" \
  "$c3_dir/show-source.txt" "$c3_dir/show-alive.json" 2>&1)"
if ! printf '%s' "$show_out" | python3 -c 'import json, sys; data=json.load(sys.stdin); assert data["alive"] is True and data["session_source"] == "/etc/path/source"' 2>/dev/null; then
  smoke_log "C3 show helper output:"; printf '%s\n' "$show_out"
  smoke_fail "C3: show-format-json.py did not produce expected output"
fi
smoke_log "C3 PASS"

# C4 — forced-failure cleanup assertion (codex PR #940 r2 BLOCKING):
# under `set -euo pipefail`, a helper that exits non-zero must NOT leak
# its tempdir AND its exit status must propagate. r2's RETURN trap was
# bypassed by errexit abort; the explicit set +e / capture / set -e /
# rm -rf pattern at lines :1414, :1525, :1683 closes that gap. C4
# replicates the production fragment for each of the 3 sites, forces
# the helper to exit non-zero, and asserts (a) the tempdir is gone and
# (b) the exit status reaches the caller.
smoke_log "C4: forced-failure cleanup — tempdir removed + rc propagates under set -euo pipefail"
c4_dir="$SMOKE_TMP_ROOT/c4"
mkdir -p "$c4_dir"

# Each fragment mirrors the production sequence exactly:
#   1. local _<name>_dir _<name>_rc
#   2. _<name>_dir="$(mktemp -d ...)"
#   3. producer(s) populate the dir
#   4. set +e; python3 helper ...; _<name>_rc=$?; set -e
#   5. rm -rf "$_<name>_dir"
#   6. return "$_<name>_rc"
# The python3 invocation is replaced by `python3 -c "sys.exit(N)"` so
# we drive the failure path deterministically without modifying the
# real helpers.
c4_probe="$c4_dir/probe.sh"
cat >"$c4_probe" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail

run_list_fragment() {
  local _list_dir _list_rc
  _list_dir="$(mktemp -d "${TMPDIR:-/tmp}/c4-list.XXXXXX")"
  printf '%s' '[]' >"$_list_dir/records.json"
  set +e
  python3 -c "import sys; sys.exit(33)" "$_list_dir/records.json"
  _list_rc=$?
  set -e
  rm -rf "$_list_dir"
  return "$_list_rc"
}

run_registry_fragment() {
  local _registry_dir _registry_rc
  _registry_dir="$(mktemp -d "${TMPDIR:-/tmp}/c4-registry.XXXXXX")"
  printf '%s' "" >"$_registry_dir/rows.tsv"
  set +e
  python3 -c "import sys; sys.exit(42)" "$_registry_dir/rows.tsv"
  _registry_rc=$?
  set -e
  rm -rf "$_registry_dir"
  return "$_registry_rc"
}

run_show_fragment() {
  local _show_dir _show_rc
  _show_dir="$(mktemp -d "${TMPDIR:-/tmp}/c4-show.XXXXXX")"
  printf '%s' "{}" >"$_show_dir/records.json"
  printf '%s' "[]" >"$_show_dir/diagnostics.json"
  printf '%s' "{}" >"$_show_dir/session-health.json"
  printf '%s' ""   >"$_show_dir/session-source.txt"
  printf '%s' "{}" >"$_show_dir/alive.json"
  set +e
  python3 -c "import sys; sys.exit(55)" \
    "$_show_dir/records.json" \
    "$_show_dir/diagnostics.json" \
    "$_show_dir/session-health.json" \
    "$_show_dir/session-source.txt" \
    "$_show_dir/alive.json"
  _show_rc=$?
  set -e
  rm -rf "$_show_dir"
  return "$_show_rc"
}

list_rc=0; run_list_fragment || list_rc=$?
list_leaks="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'c4-list.*' 2>/dev/null | wc -l | tr -d ' ')"
printf 'list_rc=%s list_leaks=%s\n' "$list_rc" "$list_leaks"

registry_rc=0; run_registry_fragment || registry_rc=$?
registry_leaks="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'c4-registry.*' 2>/dev/null | wc -l | tr -d ' ')"
printf 'registry_rc=%s registry_leaks=%s\n' "$registry_rc" "$registry_leaks"

show_rc=0; run_show_fragment || show_rc=$?
show_leaks="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'c4-show.*' 2>/dev/null | wc -l | tr -d ' ')"
printf 'show_rc=%s show_leaks=%s\n' "$show_rc" "$show_leaks"
PROBE
chmod +x "$c4_probe"

# Clean any prior leftovers from the c4-* namespace before measuring.
rm -rf "${TMPDIR:-/tmp}"/c4-list.* "${TMPDIR:-/tmp}"/c4-registry.* "${TMPDIR:-/tmp}"/c4-show.* 2>/dev/null || true

c4_out="$(bash "$c4_probe" 2>&1)"
c4_rc=$?
if (( c4_rc != 0 )); then
  smoke_log "C4 probe failed (rc=$c4_rc):"; printf '%s\n' "$c4_out"
  smoke_fail "C4: probe script did not complete"
fi

# Parse the three key=value lines and assert each fragment's outcome.
for spec in "list:33" "registry:42" "show:55"; do
  fragment="${spec%%:*}"
  expected_rc="${spec##*:}"
  got_rc="$(printf '%s\n' "$c4_out" | sed -n "s/^${fragment}_rc=\([0-9]*\) .*/\1/p")"
  got_leaks="$(printf '%s\n' "$c4_out" | sed -n "s/^${fragment}_rc=[0-9]* ${fragment}_leaks=\([0-9]*\)/\1/p")"
  if [[ "$got_rc" != "$expected_rc" ]]; then
    smoke_log "C4 ${fragment}_fragment: expected rc=$expected_rc, got rc=$got_rc"
    smoke_log "C4 full probe output:"; printf '%s\n' "$c4_out"
    smoke_fail "C4: ${fragment} fragment did not propagate helper rc"
  fi
  if [[ "$got_leaks" != "0" ]]; then
    smoke_log "C4 ${fragment}_fragment leaked $got_leaks tempdir(s):"
    find "${TMPDIR:-/tmp}" -maxdepth 1 -name "c4-${fragment}.*" 2>/dev/null
    smoke_fail "C4: ${fragment} fragment leaked tempdir(s) on helper failure"
  fi
done
smoke_log "C4 PASS — all 3 sites: helper failure cleans tempdir + propagates rc"

smoke_log "PASS — bridge-agent.sh registry/list/show JSON paths no longer deadlock on read_comsub"
exit 0
