#!/usr/bin/env bash
# memory-daily-cron-reconcile smoke — issue #390 PR-3.
#
# Validates the cron-side jsonl reconcile wiring added to
# scripts/memory-daily-harvest.sh. The harvester now calls
# scripts/daily-note-reconcile.py BEFORE invoking bridge-memory.py
# harvest-daily, so the agent's daily note is populated from the most
# recent session jsonl on every cron tick.
#
# We swap BRIDGE_PYTHON for a bash wrapper that intercepts each of:
#   * `current-session-id`       → emits a controlled session_id
#                                   (or empty + rc=1 to simulate "none")
#   * `harvest-daily`             → no-op, records argv
#   * scripts/daily-note-reconcile.py → no-op, records argv, exits with
#                                       a configurable rc
# All other invocations passthrough to a real python3 so JSON parsing of
# `agb show` output still works.
#
# Cases:
#   1  reconcile script missing (older install) → harvester skips reconcile,
#                                                  harvest still runs
#   2  no current session (current-session-id rc=1, empty stdout)
#         → reconcile skipped with stderr breadcrumb; harvest still runs
#   3  session jsonl found, reconcile succeeds
#         → reconcile invoked with --agent + --jsonl; no failure log;
#           harvest still runs
#   4  session jsonl found but reconcile FAILS (exit 2)
#         → harvester logs 'reconcile failed (rc=2)' to stderr; continues
#           to harvest
#   5  isolated agent path (isolation_mode=linux-user, os_user differs)
#         → transcripts-root resolves under $target_home; csi receives
#           --transcripts-home; harvest exec also sees --transcripts-home
#
# Exit 0 if all cases PASS, else 1.

set -u

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
HARVESTER="$REPO_ROOT/scripts/memory-daily-harvest.sh"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0
FAIL_IDS=()

pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAIL_IDS+=("$1"); printf '  [FAIL] %s — %s\n' "$1" "$2"; }
banner() { printf '\n=== case %s — %s ===\n' "$1" "$2"; }

SMOKE_ROOT="$(mktemp -d -t memory-daily-cron-reconcile.XXXXXX)"
trap 'rm -rf "$SMOKE_ROOT" 2>/dev/null || true' EXIT

# -----------------------------------------------------------------------------
# Common stub builders
# -----------------------------------------------------------------------------

# agb-mock: emits the requested agent profile JSON.
make_agb_mock() {
  local out="$1" agent="$2" workdir="$3" home="$4" mode="$5" os_user="$6"
  cat >"$out" <<MOCK
#!/usr/bin/env bash
cat <<'JSON'
{
  "agent": "$agent",
  "workdir": "$workdir",
  "profile": {"home": "$home"},
  "isolation": {"mode": "$mode", "os_user": "$os_user"}
}
JSON
MOCK
  chmod +x "$out"
}

# python-mock: bash wrapper that the harvester invokes as $BRIDGE_PYTHON.
# Interposes on three call shapes:
#   1) "$BRIDGE_PYTHON" -c '<inline>'  — JSON parsing in agb show pipeline.
#   2) "$BRIDGE_PYTHON" $BRIDGE_HOME/bridge-memory.py current-session-id ...
#   3) "$BRIDGE_PYTHON" $BRIDGE_HOME/bridge-memory.py harvest-daily ...
#   4) "$BRIDGE_PYTHON" $BRIDGE_HOME/scripts/daily-note-reconcile.py ...
#
# Recorded argv files + the controlled outputs are read from env so the
# wrapper itself stays static.
#
# Env variables consumed:
#   MOCK_CSI_LOG          — path to capture current-session-id argv
#   MOCK_CSI_SESSION_ID   — stdout to emit (empty → exit 1)
#   MOCK_HARVEST_LOG      — path to capture harvest-daily argv
#   MOCK_RECONCILE_LOG    — path to capture daily-note-reconcile.py argv
#   MOCK_RECONCILE_EXIT   — exit code for daily-note-reconcile.py (default 0)
make_python_mock() {
  local out="$1"
  cat >"$out" <<'MOCK'
#!/usr/bin/env bash
# Inline python3 evaluation (e.g. JSON parse) — passthrough.
if [[ "${1:-}" == "-c" ]]; then
  exec /usr/bin/env python3 "$@"
fi

# Otherwise the first arg is a script path. Branch by basename + first
# subcommand argv element where applicable.
script="${1:-}"
shift || true
case "$script" in
  *bridge-memory.py)
    sub="${1:-}"
    case "$sub" in
      current-session-id)
        : "${MOCK_CSI_LOG:?MOCK_CSI_LOG must be set}"
        printf '%s\n' "$@" >"$MOCK_CSI_LOG"
        if [[ -n "${MOCK_CSI_SESSION_ID:-}" ]]; then
          printf '%s\n' "$MOCK_CSI_SESSION_ID"
          exit 0
        fi
        exit 1
        ;;
      harvest-daily)
        : "${MOCK_HARVEST_LOG:?MOCK_HARVEST_LOG must be set}"
        printf '%s\n' "$@" >"$MOCK_HARVEST_LOG"
        exit 0
        ;;
      *)
        echo "[python-mock] unhandled bridge-memory subcommand: $sub" >&2
        exit 2
        ;;
    esac
    ;;
  *daily-note-reconcile.py)
    : "${MOCK_RECONCILE_LOG:?MOCK_RECONCILE_LOG must be set}"
    printf '%s\n' "$@" >"$MOCK_RECONCILE_LOG"
    # Write a marker to the daily-note path so the smoke can assert
    # reconcile actually fired with the right args (codex r1 PR #451
    # item 9 — case 3 was only checking argv, not content).
    if [[ "${MOCK_RECONCILE_EXIT:-0}" == "0" ]]; then
      mock_agent=""
      mock_jsonl=""
      mock_i=1
      mock_args=("$@")
      while (( mock_i <= $# )); do
        case "${mock_args[$((mock_i-1))]}" in
          --agent)
            mock_agent="${mock_args[$mock_i]:-}"
            mock_i=$((mock_i + 2))
            ;;
          --jsonl)
            mock_jsonl="${mock_args[$mock_i]:-}"
            mock_i=$((mock_i + 2))
            ;;
          *)
            mock_i=$((mock_i + 1))
            ;;
        esac
      done
      if [[ -n "$mock_agent" && -n "${BRIDGE_HOME:-}" ]]; then
        mock_today="$(date -u +%Y-%m-%d)"
        mock_note_dir="$BRIDGE_HOME/agents/$mock_agent/memory"
        mkdir -p "$mock_note_dir"
        printf '<!-- reconcile-stub-marker agent=%s jsonl=%s -->\n' \
          "$mock_agent" "$mock_jsonl" >>"$mock_note_dir/$mock_today.md"
      fi
    fi
    exit "${MOCK_RECONCILE_EXIT:-0}"
    ;;
  *)
    # Unknown script — passthrough to real python3 so we don't silently
    # mask unexpected behavior.
    exec /usr/bin/env python3 "$script" "$@"
    ;;
esac
MOCK
  chmod +x "$out"
}

# Materialize an empty session jsonl at the slug-derived path so the
# harvester's [[ -f $jsonl ]] check passes. Slug convention mirrors
# bridge-memory.cmd_current_session_id and the r2 harvester fix: resolve
# the workdir to its canonical absolute path FIRST (Path.resolve() /
# os.path.realpath), then replace BOTH `/` and `.` with `-`. Without the
# realpath step the macOS mktemp `/var/folders/...` path produces a slug
# that doesn't match the harvester's resolved-path slug
# (`/private/var/folders/...`) and the smoke would never find the jsonl.
materialize_session_jsonl() {
  local transcripts_root="$1" workdir="$2" session_id="$3"
  local resolved_workdir
  resolved_workdir="$(/usr/bin/env python3 -c '
import os.path, sys
print(os.path.realpath(sys.argv[1]))
' "$workdir" 2>/dev/null || true)"
  [[ -n "$resolved_workdir" ]] || resolved_workdir="$workdir"
  local slug
  slug="$(printf '%s' "$resolved_workdir" | sed 's:/:-:g; s:\.:-:g')"
  local dir="$transcripts_root/$slug"
  mkdir -p "$dir"
  : >"$dir/$session_id.jsonl"
  printf '%s/%s.jsonl\n' "$dir" "$session_id"
}

# -----------------------------------------------------------------------------
# Case 1 — reconcile script missing → skip silently, harvest still runs
# -----------------------------------------------------------------------------
banner 1 "reconcile script missing → harvester skips reconcile, harvest runs"
C1="$SMOKE_ROOT/c1"
mkdir -p "$C1/bridge-home/scripts" "$C1/workdir" "$C1/home" "$C1/fake-home"
make_agb_mock "$C1/agb-mock" c1-agent "$C1/workdir" "$C1/home" "" ""
make_python_mock "$C1/python-mock"
# bridge-memory.py just needs to exist on disk; the python-mock intercepts
# the invocation by basename.
: >"$C1/bridge-home/bridge-memory.py"
# NO daily-note-reconcile.py at $BRIDGE_HOME/scripts/.

# rc capture: explicit `rc=0` reset + `|| rc=$?` keeps the harvester's exit
# code accurate even if the surrounding script ever toggles `set -e`. The
# old `cmd; rc=$?` form was fragile in the same way as the production fix.
rc=0
env -u CRON_REQUEST_DIR -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT \
    -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_SHARED_ROOT \
    BRIDGE_AGB="$C1/agb-mock" \
    BRIDGE_PYTHON="$C1/python-mock" \
    BRIDGE_HOME="$C1/bridge-home" \
    HOME="$C1/fake-home" \
    MOCK_CSI_LOG="$C1/csi.log" \
    MOCK_CSI_SESSION_ID="sess-c1" \
    MOCK_HARVEST_LOG="$C1/harvest.log" \
    MOCK_RECONCILE_LOG="$C1/reconcile.log" \
    "$HARVESTER" --agent c1-agent \
    >"$C1/stdout" 2>"$C1/stderr" || rc=$?
if [[ $rc -ne 0 ]]; then
  fail 1 "harvest exit rc=$rc; stderr=$(cat "$C1/stderr")"
elif [[ ! -s "$C1/harvest.log" ]]; then
  fail 1 "harvest-daily was not invoked"
elif [[ -e "$C1/csi.log" ]]; then
  # Reconcile fast-paths BEFORE touching current-session-id when the
  # reconcile script is absent. csi.log existing means we paid for an
  # unnecessary subprocess.
  fail 1 "current-session-id was invoked despite missing reconcile script"
elif grep -q "reconcile" "$C1/stderr"; then
  fail 1 "unexpected reconcile breadcrumb on stderr: $(cat "$C1/stderr")"
else
  pass 1
fi

# -----------------------------------------------------------------------------
# Case 2 — no current session → reconcile skipped with stderr breadcrumb
# -----------------------------------------------------------------------------
banner 2 "no current session → reconcile skipped, harvest runs"
C2="$SMOKE_ROOT/c2"
mkdir -p "$C2/bridge-home/scripts" "$C2/workdir" "$C2/home" "$C2/fake-home"
make_agb_mock "$C2/agb-mock" c2-agent "$C2/workdir" "$C2/home" "" ""
make_python_mock "$C2/python-mock"
: >"$C2/bridge-home/bridge-memory.py"
: >"$C2/bridge-home/scripts/daily-note-reconcile.py"

rc=0
env -u CRON_REQUEST_DIR -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT \
    -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_SHARED_ROOT \
    BRIDGE_AGB="$C2/agb-mock" \
    BRIDGE_PYTHON="$C2/python-mock" \
    BRIDGE_HOME="$C2/bridge-home" \
    HOME="$C2/fake-home" \
    MOCK_CSI_LOG="$C2/csi.log" \
    MOCK_CSI_SESSION_ID="" \
    MOCK_HARVEST_LOG="$C2/harvest.log" \
    MOCK_RECONCILE_LOG="$C2/reconcile.log" \
    "$HARVESTER" --agent c2-agent \
    >"$C2/stdout" 2>"$C2/stderr" || rc=$?
if [[ $rc -ne 0 ]]; then
  fail 2 "harvest exit rc=$rc; stderr=$(cat "$C2/stderr")"
elif [[ ! -s "$C2/harvest.log" ]]; then
  fail 2 "harvest-daily was not invoked"
elif [[ -e "$C2/reconcile.log" ]]; then
  fail 2 "reconcile was invoked despite no current-session-id"
elif ! grep -q "no current session for agent=c2-agent" "$C2/stderr"; then
  fail 2 "expected 'no current session for agent=c2-agent' in stderr; got: $(cat "$C2/stderr")"
elif [[ ! -s "$C2/csi.log" ]]; then
  fail 2 "current-session-id was not invoked"
else
  pass 2
fi

# -----------------------------------------------------------------------------
# Case 3 — session jsonl found, reconcile succeeds
# -----------------------------------------------------------------------------
banner 3 "session jsonl resolves + reconcile rc=0 → reconcile invoked, no error log"
C3="$SMOKE_ROOT/c3"
mkdir -p "$C3/bridge-home/scripts" "$C3/workdir" "$C3/home" "$C3/fake-home"
make_agb_mock "$C3/agb-mock" c3-agent "$C3/workdir" "$C3/home" "" ""
make_python_mock "$C3/python-mock"
: >"$C3/bridge-home/bridge-memory.py"
: >"$C3/bridge-home/scripts/daily-note-reconcile.py"

C3_JSONL="$(materialize_session_jsonl "$C3/fake-home/.claude/projects" \
  "$C3/workdir" "sess-c3")"

rc=0
env -u CRON_REQUEST_DIR -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT \
    -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_SHARED_ROOT \
    BRIDGE_AGB="$C3/agb-mock" \
    BRIDGE_PYTHON="$C3/python-mock" \
    BRIDGE_HOME="$C3/bridge-home" \
    HOME="$C3/fake-home" \
    MOCK_CSI_LOG="$C3/csi.log" \
    MOCK_CSI_SESSION_ID="sess-c3" \
    MOCK_HARVEST_LOG="$C3/harvest.log" \
    MOCK_RECONCILE_LOG="$C3/reconcile.log" \
    MOCK_RECONCILE_EXIT="0" \
    "$HARVESTER" --agent c3-agent \
    >"$C3/stdout" 2>"$C3/stderr" || rc=$?
if [[ $rc -ne 0 ]]; then
  fail 3 "harvest exit rc=$rc; stderr=$(cat "$C3/stderr")"
elif [[ ! -s "$C3/harvest.log" ]]; then
  fail 3 "harvest-daily was not invoked"
elif [[ ! -s "$C3/reconcile.log" ]]; then
  fail 3 "reconcile was not invoked"
else
  reconcile_argv="$(tr '\n' ' ' <"$C3/reconcile.log")"
  case " $reconcile_argv " in
    *" --agent c3-agent "*" --jsonl $C3_JSONL "*) reconcile_args_ok="yes" ;;
    *" --agent c3-agent --jsonl $C3_JSONL "*) reconcile_args_ok="yes" ;;
    *) reconcile_args_ok="no" ;;
  esac
  if [[ "$reconcile_args_ok" != "yes" ]]; then
    fail 3 "reconcile argv missing --agent/--jsonl; got: $reconcile_argv"
  elif grep -q "reconcile failed" "$C3/stderr"; then
    fail 3 "unexpected reconcile-failure breadcrumb on stderr: $(cat "$C3/stderr")"
  else
    csi_argv="$(tr '\n' ' ' <"$C3/csi.log")"
    # Confirm current-session-id was passed --home pointing at workdir
    # (NOT the agent profile home) — that's the wrap-up.md convention and
    # is load-bearing for slug derivation.
    case " $csi_argv " in
      *" --home $C3/workdir "*) c3_csi_ok="yes" ;;
      *) c3_csi_ok="no" ;;
    esac
    # Verify the daily-note file exists + contains the reconcile stub
    # marker — proves the harvester wired the reconcile invocation through
    # to a writer (codex r1 PR #451 item 9 — content verify, not just
    # argv).
    C3_NOTE="$C3/bridge-home/agents/c3-agent/memory/$(date -u +%Y-%m-%d).md"
    if [[ "$c3_csi_ok" != "yes" ]]; then
      fail 3 "current-session-id --home should be workdir; got: $csi_argv"
    elif [[ ! -f "$C3_NOTE" ]]; then
      fail 3 "daily note missing at $C3_NOTE — reconcile stub didn't write marker"
    elif ! grep -q "reconcile-stub-marker agent=c3-agent" "$C3_NOTE"; then
      fail 3 "daily note marker missing at $C3_NOTE — content: $(cat "$C3_NOTE")"
    elif ! grep -q "jsonl=" "$C3_NOTE"; then
      # codex r2 PR #451: verify the jsonl arg landed in the marker too,
      # not just the agent field. Confirms reconcile was invoked with the
      # right --jsonl <path> argument from the harvester's slug derivation.
      fail 3 "daily note marker missing jsonl= field — content: $(cat "$C3_NOTE")"
    else
      pass 3
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Case 4 — session jsonl found but reconcile fails → log + continue
# -----------------------------------------------------------------------------
banner 4 "reconcile rc=2 → 'reconcile failed (rc=2)' on stderr, harvest continues"
C4="$SMOKE_ROOT/c4"
mkdir -p "$C4/bridge-home/scripts" "$C4/workdir" "$C4/home" "$C4/fake-home"
make_agb_mock "$C4/agb-mock" c4-agent "$C4/workdir" "$C4/home" "" ""
make_python_mock "$C4/python-mock"
: >"$C4/bridge-home/bridge-memory.py"
: >"$C4/bridge-home/scripts/daily-note-reconcile.py"

C4_JSONL="$(materialize_session_jsonl "$C4/fake-home/.claude/projects" \
  "$C4/workdir" "sess-c4")"
[[ -f "$C4_JSONL" ]] || fail 4 "fixture jsonl not materialized at $C4_JSONL"

rc=0
env -u CRON_REQUEST_DIR -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT \
    -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_SHARED_ROOT \
    BRIDGE_AGB="$C4/agb-mock" \
    BRIDGE_PYTHON="$C4/python-mock" \
    BRIDGE_HOME="$C4/bridge-home" \
    HOME="$C4/fake-home" \
    MOCK_CSI_LOG="$C4/csi.log" \
    MOCK_CSI_SESSION_ID="sess-c4" \
    MOCK_HARVEST_LOG="$C4/harvest.log" \
    MOCK_RECONCILE_LOG="$C4/reconcile.log" \
    MOCK_RECONCILE_EXIT="2" \
    "$HARVESTER" --agent c4-agent \
    >"$C4/stdout" 2>"$C4/stderr" || rc=$?
if [[ $rc -ne 0 ]]; then
  fail 4 "harvest exit rc=$rc despite best-effort contract; stderr=$(cat "$C4/stderr")"
elif [[ ! -s "$C4/harvest.log" ]]; then
  fail 4 "harvest-daily was not invoked after reconcile failure"
elif [[ ! -s "$C4/reconcile.log" ]]; then
  fail 4 "reconcile was not invoked"
elif ! grep -q "reconcile failed (rc=2) for agent=c4-agent" "$C4/stderr"; then
  fail 4 "expected 'reconcile failed (rc=2) for agent=c4-agent' on stderr; got: $(cat "$C4/stderr")"
else
  pass 4
fi

# -----------------------------------------------------------------------------
# Case 5 — isolated agent path → transcripts-root resolves under $target_home
# -----------------------------------------------------------------------------
banner 5 "isolation_mode=linux-user → --transcripts-home on csi + isolated transcripts root"
C5="$SMOKE_ROOT/c5"
mkdir -p "$C5/bridge-home/scripts" "$C5/workdir" "$C5/home" "$C5/fake-home"
ISO_USER="ghost-smoke-pr3"
ISO_HOME_ROOT="$C5/iso-root"
ISO_TARGET_HOME="$ISO_HOME_ROOT/$ISO_USER"
mkdir -p "$ISO_TARGET_HOME/.claude/projects"

make_agb_mock "$C5/agb-mock" c5-agent "$C5/workdir" "$C5/home" \
  "linux-user" "$ISO_USER"
make_python_mock "$C5/python-mock"
: >"$C5/bridge-home/bridge-memory.py"
: >"$C5/bridge-home/scripts/daily-note-reconcile.py"

# Materialize the session jsonl under the ISOLATED transcripts root so the
# harvester's [[ -f $jsonl ]] check uses the target_home branch.
C5_JSONL="$(materialize_session_jsonl "$ISO_TARGET_HOME/.claude/projects" \
  "$C5/workdir" "sess-c5")"
[[ -f "$C5_JSONL" ]] || fail 5 "fixture jsonl not materialized at $C5_JSONL"

# Place a deliberately-empty transcripts root under fake-HOME so we can prove
# the harvester did NOT fall back to $HOME — the jsonl is only present under
# $target_home/.claude/projects.
mkdir -p "$C5/fake-home/.claude/projects"

rc=0
env -u CRON_REQUEST_DIR -u BRIDGE_LAYOUT -u BRIDGE_DATA_ROOT \
    -u BRIDGE_AGENT_ROOT_V2 -u BRIDGE_SHARED_ROOT \
    BRIDGE_AGB="$C5/agb-mock" \
    BRIDGE_PYTHON="$C5/python-mock" \
    BRIDGE_HOME="$C5/bridge-home" \
    BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="$ISO_HOME_ROOT" \
    HOME="$C5/fake-home" \
    MOCK_CSI_LOG="$C5/csi.log" \
    MOCK_CSI_SESSION_ID="sess-c5" \
    MOCK_HARVEST_LOG="$C5/harvest.log" \
    MOCK_RECONCILE_LOG="$C5/reconcile.log" \
    MOCK_RECONCILE_EXIT="0" \
    "$HARVESTER" --agent c5-agent \
    >"$C5/stdout" 2>"$C5/stderr" || rc=$?

if [[ $rc -ne 0 ]]; then
  fail 5 "harvest exit rc=$rc; stderr=$(cat "$C5/stderr")"
elif [[ ! -s "$C5/csi.log" ]]; then
  fail 5 "current-session-id was not invoked"
elif [[ ! -s "$C5/reconcile.log" ]]; then
  fail 5 "reconcile was not invoked under isolation"
else
  csi_argv="$(tr '\n' ' ' <"$C5/csi.log")"
  reconcile_argv="$(tr '\n' ' ' <"$C5/reconcile.log")"
  case " $csi_argv " in
    *" --transcripts-home $ISO_TARGET_HOME "*) has_th="yes" ;;
    *) has_th="no" ;;
  esac
  case " $reconcile_argv " in
    *" --jsonl $C5_JSONL "*) jsonl_ok="yes" ;;
    *) jsonl_ok="no" ;;
  esac
  if [[ "$has_th" == "yes" && "$jsonl_ok" == "yes" ]]; then
    # Confirm the harvest-daily branch also ran (isolation-aware exec) so
    # we know the lifted target_home didn't break existing wiring.
    harvest_argv="$(tr '\n' ' ' <"$C5/harvest.log")"
    case " $harvest_argv " in
      *" --transcripts-home $ISO_TARGET_HOME "*) harvest_th_ok="yes" ;;
      *) harvest_th_ok="no" ;;
    esac
    if [[ "$harvest_th_ok" == "yes" ]]; then
      pass 5
    else
      fail 5 "harvest argv lost --transcripts-home; got: $harvest_argv"
    fi
  else
    fail 5 "csi --transcripts-home=$has_th, reconcile --jsonl=$jsonl_ok; csi_argv=$csi_argv reconcile_argv=$reconcile_argv"
  fi
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n=== summary: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'FAILED: %s\n' "${FAIL_IDS[*]}"
  exit 1
fi
exit 0
