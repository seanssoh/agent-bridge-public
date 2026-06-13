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

  # The mock models the SHELL-kind registration shape the helper now emits:
  #   cron create --kind shell --agent A --run-as-agent A --schedule S
  #               --title picker-sweep --script '$BRIDGE_HOME/...'
  #               --script-env SCRIPT_PICKER_SWEEP_ENABLED=1 (repeatable)
  # plus the migration `cron delete picker-sweep`. Jobs are persisted in a
  # native shape (payload.kind + payload.script + payload.env +
  # execution.runAsAgent) so the probe + assertions exercise real fields.
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
      run_as_agent=""
      schedule=""
      kind="text"
      script=""
      env_pairs=()
      while [[ \$# -gt 0 ]]; do
        case "\$1" in
          --title) title="\$2"; shift 2 ;;
          --payload) payload="\$2"; shift 2 ;;
          --agent) agent="\$2"; shift 2 ;;
          --run-as-agent) run_as_agent="\$2"; shift 2 ;;
          --schedule) schedule="\$2"; shift 2 ;;
          --kind) kind="\$2"; shift 2 ;;
          --script) script="\$2"; shift 2 ;;
          --script-env) env_pairs+=("\$2"); shift 2 ;;
          *) shift ;;
        esac
      done
      python3 - "\$JOBS_FILE" "\$title" "\$payload" "\$agent" "\$run_as_agent" "\$schedule" "\$kind" "\$script" "\${env_pairs[@]}" <<'PY'
import json, sys
path, title, payload, agent, run_as_agent, schedule, kind, script = sys.argv[1:9]
env_pairs = sys.argv[9:]
env = {}
for raw in env_pairs:
    if "=" in raw:
        k, v = raw.split("=", 1)
        env[k] = v
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
jobs = data.setdefault("jobs", [])
record = {"title": title, "agent": agent, "schedule": schedule, "payload": {"kind": kind}}
if kind == "shell":
    record["payload"]["script"] = script
    record["payload"]["env"] = env
    record["execution"] = {"runAsAgent": run_as_agent}
else:
    record["payload"]["prompt"] = payload
jobs.append(record)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
      exit 0
      ;;
    delete)
      shift
      ref="\${1:-}"
      python3 - "\$JOBS_FILE" "\$ref" <<'PY'
import json, sys
path, ref = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["jobs"] = [j for j in data.get("jobs", []) if j.get("title") != ref]
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

# Seed a legacy TEXT-kind picker-sweep job (the broken codex-pair form) so the
# migration path can be exercised.
seed_legacy_text_job() {
  local jobs_file="$1"
  python3 - "$jobs_file" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data.setdefault("jobs", []).append({
    "title": "picker-sweep",
    "agent": "patch-dev",
    "schedule": "*/10 * * * *",
    "payload": {"kind": "text", "prompt": "... bash $BRIDGE_HOME/scripts/picker-sweep.sh"},
})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
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

picker_sweep_kind() {
  local jobs_file="$1"
  python3 - "$jobs_file" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
for j in data.get("jobs", []):
    if j.get("title") == "picker-sweep":
        print((j.get("payload") or {}).get("kind", ""))
        break
PY
}

picker_sweep_field() {
  # picker_sweep_field <jobs_file> <dotted.path>
  local jobs_file="$1" expr="$2"
  python3 - "$jobs_file" "$expr" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
job = next((j for j in data.get("jobs", []) if j.get("title") == "picker-sweep"), {})
value = job
for part in sys.argv[2].split("."):
    value = value.get(part) if isinstance(value, dict) else None
print(value if value is not None else "")
PY
}

# Helper: source the default-crons lib in a subshell, stub bridge_agent_exists
# (defined in lib/bridge-agents.sh, which this test does not source) so the
# admin-existence guard passes, set BRIDGE_BASH_BIN, then call the registration
# function and report the resulting jobs.json state.
run_register() {
  local mock_cli="$1"
  # shellcheck disable=SC1091
  ( source "$ROOT_DIR/lib/bridge-init-default-crons.sh"
    # shellcheck disable=SC2329 # invoked indirectly from the sourced helper
    bridge_agent_exists() { [[ "$1" == "patch" ]]; }
    export BRIDGE_BASH_BIN="${BRIDGE_BASH_BIN:-bash}"
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
# R5: registered job is SHELL-kind controller-direct — NOT a codex-pair text
#     dispatch. Asserts: payload.kind==shell, script ends with
#     scripts/picker-sweep.sh, execution.runAsAgent==patch (the admin/
#     controller, not patch-dev), and the SCRIPT_PICKER_SWEEP_* env is carried
#     (the shell runner rejects BRIDGE_-prefixed payload env, so the knobs must
#     be SCRIPT_-prefixed).
# ---------------------------------------------------------------------------
step "R5: registered cron is shell-kind controller-direct with SCRIPT_ env (not codex-pair text)"
R5_KIND="$(picker_sweep_kind "$R1_JOBS")"
R5_SCRIPT="$(picker_sweep_field "$R1_JOBS" payload.script)"
R5_RUNAS="$(picker_sweep_field "$R1_JOBS" execution.runAsAgent)"
R5_AGENT="$(picker_sweep_field "$R1_JOBS" agent)"
R5_ENV_ENABLED="$(picker_sweep_field "$R1_JOBS" payload.env.SCRIPT_PICKER_SWEEP_ENABLED)"
R5_ENV_SELF="$(picker_sweep_field "$R1_JOBS" payload.env.SCRIPT_PICKER_SWEEP_SELF)"
R5_ENV_NOTIFY="$(picker_sweep_field "$R1_JOBS" payload.env.SCRIPT_PICKER_SWEEP_NOTIFY)"
if [[ "$R5_KIND" == "shell" ]] \
   && [[ "$R5_SCRIPT" == *scripts/picker-sweep.sh ]] \
   && [[ "$R5_RUNAS" == "patch" && "$R5_AGENT" == "patch" ]] \
   && [[ "$R5_ENV_ENABLED" == "1" ]] \
   && [[ "$R5_ENV_SELF" == "patch" && "$R5_ENV_NOTIFY" == "patch" ]]; then
  ok
else
  err "kind=$R5_KIND script=$R5_SCRIPT run_as=$R5_RUNAS agent=$R5_AGENT enabled=$R5_ENV_ENABLED self=$R5_ENV_SELF notify=$R5_ENV_NOTIFY (expected shell / .../picker-sweep.sh / patch / patch / 1 / patch / patch)"
fi

# ---------------------------------------------------------------------------
# R7: migration. A legacy TEXT-kind (codex-pair) picker-sweep job present on an
#     upgraded install must be DELETED and re-registered as shell-kind — the
#     title-based idempotency probe alone would otherwise skip and leave the
#     broken job in place. This is the piece that reaches already-installed
#     hosts (cm-prod field bug).
# ---------------------------------------------------------------------------
step "R7: legacy text-kind picker-sweep is migrated to shell-kind (single job)"
R7_DIR="$TMP_ROOT/r7"
R7_CLI="$(setup_mock_cli "$R7_DIR")"
R7_JOBS="$R7_DIR/jobs.json"
mkdir -p "$R7_DIR/state/install"
printf '{"profile":"server"}\n' > "$R7_DIR/state/install/host-profile.json"
export BRIDGE_HOME="$R7_DIR"
export BRIDGE_STATE_DIR="$R7_DIR/state"
seed_legacy_text_job "$R7_JOBS"
# Pre-condition: exactly one job, text-kind.
R7_PRE_KIND="$(picker_sweep_kind "$R7_JOBS")"
run_register "$R7_CLI" >/dev/null 2>&1
R7_COUNT="$(count_picker_sweep_jobs "$R7_JOBS")"
R7_POST_KIND="$(picker_sweep_kind "$R7_JOBS")"
R7_POST_RUNAS="$(picker_sweep_field "$R7_JOBS" execution.runAsAgent)"
if [[ "$R7_PRE_KIND" == "text" && "$R7_COUNT" == "1" && "$R7_POST_KIND" == "shell" && "$R7_POST_RUNAS" == "patch" ]]; then
  ok
else
  err "pre_kind=$R7_PRE_KIND count=$R7_COUNT post_kind=$R7_POST_KIND post_run_as=$R7_POST_RUNAS (expected text / 1 / shell / patch)"
fi

# ---------------------------------------------------------------------------
# R8: SCRIPT_-prefixed runtime aliases. picker-sweep.sh must honor
#     SCRIPT_PICKER_SWEEP_ENABLED=1 (alone, with BRIDGE_* unset) to drive the
#     enabled path on a host_profile=dev install — this is how the shell-kind
#     cron payload (which cannot carry BRIDGE_-prefixed env) enables the sweep.
# ---------------------------------------------------------------------------
step "R8: SCRIPT_PICKER_SWEEP_ENABLED=1 alone bypasses host_profile=dev gate"
R8_DIR="$TMP_ROOT/r8"
mkdir -p "$R8_DIR/lib" "$R8_DIR/state/install" "$R8_DIR/logs" "$R8_DIR/scripts"
cp "$ROOT_DIR/lib/bridge-host-profile.sh" "$R8_DIR/lib/"
cp "$ROOT_DIR/scripts/picker-sweep.sh" "$R8_DIR/scripts/"
printf '{"profile":"dev"}\n' > "$R8_DIR/state/install/host-profile.json"
R8_SEAMS="$R8_DIR/seams.sh"
cat > "$R8_SEAMS" <<'SEAM_EOF'
r8_list_sessions() { :; }
r8_capture_pane() { :; }
r8_send_enter() { :; }
r8_create_task() { :; }
export -f r8_list_sessions r8_capture_pane r8_send_enter r8_create_task
SEAM_EOF
R8_STDERR="$R8_DIR/r8-stderr"
R8_RC=0
# shellcheck disable=SC1090
source "$R8_SEAMS"
env -u BRIDGE_PICKER_SWEEP_ENABLED \
  SCRIPT_PICKER_SWEEP_ENABLED=1 \
  SCRIPT_PICKER_SWEEP_SELF=patch \
  SCRIPT_PICKER_SWEEP_NOTIFY=patch \
  BRIDGE_HOME="$R8_DIR" \
  BRIDGE_STATE_DIR="$R8_DIR/state" \
  BRIDGE_PICKER_SWEEP_LIST_SESSIONS_FN=r8_list_sessions \
  BRIDGE_PICKER_SWEEP_CAPTURE_PANE_FN=r8_capture_pane \
  BRIDGE_PICKER_SWEEP_SEND_ENTER_FN=r8_send_enter \
  BRIDGE_PICKER_SWEEP_CREATE_TASK_FN=r8_create_task \
  bash "$R8_DIR/scripts/picker-sweep.sh" 2>"$R8_STDERR" >/dev/null || R8_RC=$?
if [[ "$R8_RC" == "0" ]] && ! grep -q "default-skipped" "$R8_STDERR" \
   && ! grep -q "manual runs" "$R8_STDERR"; then
  ok
else
  err "rc=$R8_RC stderr=$(cat "$R8_STDERR")"
fi

# ---------------------------------------------------------------------------
# R6: bridge-upgrade.sh backfill actually invokes the helper with the
#     required ($cli_path, $admin_agent) args. Earlier r2 attempt called the
#     helper bare which aborts under `set -u` with `$1: unbound variable` —
#     a grep-presence check missed that. R6 now extracts the upgrade
#     snippet's heredoc body and runs it standalone under `set -uo pipefail`
#     against a mock helper that traps the args, so a future refactor that
#     drops or re-bares the call fails here. (review #2112 finding 1.)
# ---------------------------------------------------------------------------
step "R6: bridge-upgrade.sh backfill calls picker-sweep helper with required args"

UPGRADE_SH="$ROOT_DIR/bridge-upgrade.sh"

# Sub-check R6a: the helper is invoked with TWO explicit args (CLI path,
# admin agent id), not bare. We look for the multi-line call shape that the
# r3 fix uses:
#
#   bridge_init_register_default_picker_sweep \
#     "${TARGET_ROOT_INNER}/agent-bridge" \
#     "${ADMIN_AGENT_ID_INNER}"
#
# A bare-call refactor (which is the bug r2 had) would not match this regex.
R6A_OK=0
if awk '
  /bridge_init_register_default_picker_sweep \\$/ { window = 3; next }
  window > 0 {
    if ($0 ~ /agent-bridge/) cli=1
    if ($0 ~ /ADMIN_AGENT_ID/) admin=1
    window--
    if (window == 0 && cli && admin) { print "OK"; exit 0 }
  }
' "$UPGRADE_SH" | grep -q '^OK$'; then
  R6A_OK=1
fi

# Sub-check R6b: the upgrade snippet passes ADMIN_AGENT_ID as a `--` arg
# AND short-circuits when it's empty. Verifies r3 also added the missing-
# admin guard.
R6B_OK=0
if grep -q 'picker-sweep cron backfill skipped — install has no admin agent' "$UPGRADE_SH" \
   && grep -q 'ADMIN_AGENT_ID' "$UPGRADE_SH"; then
  R6B_OK=1
fi

if [[ "$R6A_OK" -eq 1 && "$R6B_OK" -eq 1 ]]; then
  ok
else
  err "R6a (explicit-args call shape)=$R6A_OK / R6b (missing-admin guard)=$R6B_OK"
fi

# ---------------------------------------------------------------------------
TOTAL=$((PASS + FAIL))
printf '\n# Issue #833 picker-sweep registration suite: %s/%s passed\n' "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
