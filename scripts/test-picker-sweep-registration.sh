#!/usr/bin/env bash
# Regression coverage for issue #833 — picker-sweep cron registration is
# decoupled from the host_profile gate.
#
# The post-#809 / #813 install flow gated the auto-registration of the
# picker-sweep bridge-native cron behind `host_profile == server`, so a fresh
# `host_profile=dev` install ended up with no picker-sweep at all. The fix
# moves the gate from registration time to runtime (the cron payload always
# sets `BRIDGE_PICKER_SWEEP_ENABLED=1`, which overrides the runtime
# host_profile=dev default-skip in `scripts/picker-sweep.sh`). This suite
# verifies:
#
#   R1 Dev profile: bridge_init_register_default_picker_sweep registers the
#      picker-sweep cron on a `host_profile=dev` install. Re-running the
#      helper does NOT double-register (idempotent).
#   R2 Server profile: same shape as R1 — no regression in the previously-
#      working host_profile=server path.
#   R3 Manual-run default-skip: with BRIDGE_PICKER_SWEEP_ENABLED unset and
#      host_profile=dev, scripts/picker-sweep.sh exits 0 and writes the
#      operator-friendly skip message to stderr.
#   R4 Manual-run override: with BRIDGE_PICKER_SWEEP_ENABLED=1 the script
#      proceeds past the host_profile gate regardless of profile.
#   R5 Cron payload contract: the registered cron payload includes
#      `BRIDGE_PICKER_SWEEP_ENABLED=1` so cron-fired runs always execute.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

PASS=0
FAIL=0
LAST_DESC=""

step() { LAST_DESC="$*"; }
ok() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$LAST_DESC"; }
err() { FAIL=$((FAIL + 1)); printf '  FAIL: %s — %s\n' "$LAST_DESC" "$*" >&2; }

TMP_ROOT="$(mktemp -d -t agb-picker-sweep-reg-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export BRIDGE_BASH_BIN="${BRIDGE_BASH_BIN:-bash}"

# ---------------------------------------------------------------------------
# Mock agent-bridge CLI. The helper invokes:
#   agent-bridge cron list --json    → must print the current jobs JSON
#   agent-bridge cron create ...     → must append a job record
# The fake CLI persists state in $MOCK_DIR/jobs.json so subsequent calls
# (and the idempotency guard) see prior registrations.
# ---------------------------------------------------------------------------

setup_mock_cli() {
  local mock_dir="$1"
  mkdir -p "$mock_dir"
  local cli="$mock_dir/agent-bridge"
  local jobs="$mock_dir/jobs.json"
  printf '{"jobs": []}\n' > "$jobs"

  cat > "$cli" <<MOCK_CLI
#!/usr/bin/env bash
# Fake agent-bridge CLI for picker-sweep registration regression test.
set -uo pipefail
JOBS_FILE="$jobs"

if [[ "\$1" == "cron" ]]; then
  shift
  case "\$1" in
    list)
      shift
      if [[ "\${1:-}" == "--json" ]]; then
        cat "\$JOBS_FILE"
        exit 0
      fi
      ;;
    create)
      shift
      title=""
      payload=""
      agent=""
      schedule=""
      while [[ \$# -gt 0 ]]; do
        case "\$1" in
          --title) title="\$2"; shift 2 ;;
          --payload) payload="\$2"; shift 2 ;;
          --agent) agent="\$2"; shift 2 ;;
          --schedule) schedule="\$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      python3 - "\$JOBS_FILE" "\$title" "\$payload" "\$agent" "\$schedule" <<'PY'
import json, sys
path, title, payload, agent, schedule = sys.argv[1:6]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
jobs = data.setdefault("jobs", [])
jobs.append({"title": title, "payload": payload, "agent": agent, "schedule": schedule})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
      exit 0
      ;;
  esac
fi
exit 1
MOCK_CLI
  chmod +x "$cli"
  printf '%s' "$cli"
}

count_picker_sweep_jobs() {
  local jobs_file="$1"
  python3 - "$jobs_file" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
jobs = data.get("jobs", [])
print(sum(1 for j in jobs if j.get("title") == "picker-sweep"))
PY
}

picker_sweep_payload() {
  local jobs_file="$1"
  python3 - "$jobs_file" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for j in data.get("jobs", []):
    if j.get("title") == "picker-sweep":
        print(j.get("payload", ""))
        break
PY
}

# Helper: source the default-crons lib in a subshell, call the registration
# function, and report the resulting jobs.json state.
run_register() {
  local mock_cli="$1"
  # shellcheck disable=SC1091
  ( source "$ROOT_DIR/lib/bridge-init-default-crons.sh"
    bridge_init_register_default_picker_sweep "$mock_cli" "patch" )
}

# ---------------------------------------------------------------------------
# R1: dev profile — registration must fire, idempotent on re-call.
# ---------------------------------------------------------------------------
step "R1: dev profile registers picker-sweep cron (idempotent)"
R1_DIR="$TMP_ROOT/r1"
R1_CLI="$(setup_mock_cli "$R1_DIR")"
R1_JOBS="$R1_DIR/jobs.json"
# Simulate dev host_profile state.
mkdir -p "$R1_DIR/state/install"
printf '{"profile":"dev"}\n' > "$R1_DIR/state/install/host-profile.json"
export BRIDGE_HOME="$R1_DIR"
export BRIDGE_STATE_DIR="$R1_DIR/state"

run_register "$R1_CLI" >/dev/null 2>&1
R1_COUNT_1="$(count_picker_sweep_jobs "$R1_JOBS")"

run_register "$R1_CLI" >/dev/null 2>&1
R1_COUNT_2="$(count_picker_sweep_jobs "$R1_JOBS")"

if [[ "$R1_COUNT_1" == "1" && "$R1_COUNT_2" == "1" ]]; then
  ok
else
  err "after-1=$R1_COUNT_1 after-2=$R1_COUNT_2 (expected 1 / 1)"
fi

# ---------------------------------------------------------------------------
# R2: server profile — same outcome, no regression on the previously-working
#     path.
# ---------------------------------------------------------------------------
step "R2: server profile registers picker-sweep cron (idempotent)"
R2_DIR="$TMP_ROOT/r2"
R2_CLI="$(setup_mock_cli "$R2_DIR")"
R2_JOBS="$R2_DIR/jobs.json"
mkdir -p "$R2_DIR/state/install"
printf '{"profile":"server"}\n' > "$R2_DIR/state/install/host-profile.json"
export BRIDGE_HOME="$R2_DIR"
export BRIDGE_STATE_DIR="$R2_DIR/state"

run_register "$R2_CLI" >/dev/null 2>&1
R2_COUNT_1="$(count_picker_sweep_jobs "$R2_JOBS")"

run_register "$R2_CLI" >/dev/null 2>&1
R2_COUNT_2="$(count_picker_sweep_jobs "$R2_JOBS")"

if [[ "$R2_COUNT_1" == "1" && "$R2_COUNT_2" == "1" ]]; then
  ok
else
  err "after-1=$R2_COUNT_1 after-2=$R2_COUNT_2 (expected 1 / 1)"
fi

# ---------------------------------------------------------------------------
# R3: manual-run default-skip. BRIDGE_PICKER_SWEEP_ENABLED unset +
#     host_profile=dev → picker-sweep.sh exits 0 with the operator-friendly
#     stderr line.
# ---------------------------------------------------------------------------
step "R3: manual run on host_profile=dev default-skips with friendly stderr"
R3_DIR="$TMP_ROOT/r3"
mkdir -p "$R3_DIR/lib" "$R3_DIR/state/install" "$R3_DIR/logs" "$R3_DIR/scripts"
cp "$ROOT_DIR/lib/bridge-host-profile.sh" "$R3_DIR/lib/"
cp "$ROOT_DIR/scripts/picker-sweep.sh" "$R3_DIR/scripts/"
printf '{"profile":"dev"}\n' > "$R3_DIR/state/install/host-profile.json"

# Run with a clean env: must NOT inherit BRIDGE_PICKER_SWEEP_ENABLED from
# parent test shell.
R3_STDERR="$R3_DIR/r3-stderr"
R3_RC=0
env -u BRIDGE_PICKER_SWEEP_ENABLED \
  BRIDGE_HOME="$R3_DIR" \
  BRIDGE_STATE_DIR="$R3_DIR/state" \
  bash "$R3_DIR/scripts/picker-sweep.sh" 2>"$R3_STDERR" >/dev/null || R3_RC=$?

if [[ "$R3_RC" == "0" ]] && grep -q "host_profile=dev" "$R3_STDERR" \
   && grep -q "BRIDGE_PICKER_SWEEP_ENABLED=1" "$R3_STDERR" \
   && grep -q "manual runs" "$R3_STDERR"; then
  ok
else
  err "rc=$R3_RC stderr=$(cat "$R3_STDERR")"
fi

# ---------------------------------------------------------------------------
# R4: manual-run override. BRIDGE_PICKER_SWEEP_ENABLED=1 → script proceeds
#     past the host_profile gate. We assert by checking that the dev-skip
#     stderr message is absent and the rc is 0 (with no tmux installed the
#     sweep simply finds no sessions to process and exits clean).
# ---------------------------------------------------------------------------
step "R4: manual run with BRIDGE_PICKER_SWEEP_ENABLED=1 bypasses host_profile gate"
R4_DIR="$TMP_ROOT/r4"
mkdir -p "$R4_DIR/lib" "$R4_DIR/state/install" "$R4_DIR/logs" "$R4_DIR/scripts"
cp "$ROOT_DIR/lib/bridge-host-profile.sh" "$R4_DIR/lib/"
cp "$ROOT_DIR/scripts/picker-sweep.sh" "$R4_DIR/scripts/"
printf '{"profile":"dev"}\n' > "$R4_DIR/state/install/host-profile.json"

# Mock the tmux/queue seams so the sweep doesn't hit a real tmux server.
R4_SEAMS="$R4_DIR/seams.sh"
cat > "$R4_SEAMS" <<'SEAM_EOF'
r4_list_sessions() { :; }
r4_capture_pane() { :; }
r4_send_enter() { :; }
r4_create_task() { :; }
export -f r4_list_sessions r4_capture_pane r4_send_enter r4_create_task
SEAM_EOF

R4_STDERR="$R4_DIR/r4-stderr"
R4_RC=0
# shellcheck disable=SC1090
source "$R4_SEAMS"
BRIDGE_PICKER_SWEEP_ENABLED=1 \
  BRIDGE_HOME="$R4_DIR" \
  BRIDGE_STATE_DIR="$R4_DIR/state" \
  BRIDGE_PICKER_SWEEP_LIST_SESSIONS_FN=r4_list_sessions \
  BRIDGE_PICKER_SWEEP_CAPTURE_PANE_FN=r4_capture_pane \
  BRIDGE_PICKER_SWEEP_SEND_ENTER_FN=r4_send_enter \
  BRIDGE_PICKER_SWEEP_CREATE_TASK_FN=r4_create_task \
  bash "$R4_DIR/scripts/picker-sweep.sh" 2>"$R4_STDERR" >/dev/null || R4_RC=$?

if [[ "$R4_RC" == "0" ]] && ! grep -q "default-skipped" "$R4_STDERR" \
   && ! grep -q "manual runs" "$R4_STDERR"; then
  ok
else
  err "rc=$R4_RC stderr=$(cat "$R4_STDERR")"
fi

# ---------------------------------------------------------------------------
# R5: cron payload check. Registered job's payload must include
#     BRIDGE_PICKER_SWEEP_ENABLED=1 (so cron-fired runs always execute,
#     regardless of host_profile).
# ---------------------------------------------------------------------------
step "R5: registered cron payload sets BRIDGE_PICKER_SWEEP_ENABLED=1"
R5_PAYLOAD="$(picker_sweep_payload "$R1_JOBS")"
if printf '%s' "$R5_PAYLOAD" | grep -q "BRIDGE_PICKER_SWEEP_ENABLED=1"; then
  ok
else
  err "payload missing flag: '$R5_PAYLOAD'"
fi

# ---------------------------------------------------------------------------
TOTAL=$((PASS + FAIL))
printf '\n# Issue #833 picker-sweep registration suite: %s/%s passed\n' "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
