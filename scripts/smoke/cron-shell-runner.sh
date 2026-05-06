#!/usr/bin/env bash
# scripts/smoke/cron-shell-runner.sh — native cron payload.kind=shell smoke.

set -euo pipefail

SMOKE_NAME="cron-shell-runner"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "cron-shell-runner"
export BRIDGE_CRON_STATE_DIR="$BRIDGE_STATE_DIR/cron"
mkdir -p "$BRIDGE_CRON_STATE_DIR/runs" "$BRIDGE_CRON_STATE_DIR/locks" "$BRIDGE_HOME/cron"

CURRENT_USER="$(id -un)"
CURRENT_UID="$(id -u)"
CURRENT_GID="$(id -g)"
JOBS_FILE="$BRIDGE_HOME/cron/jobs.json"
export CURRENT_USER CURRENT_UID CURRENT_GID JOBS_FILE
export BRIDGE_NATIVE_CRON_JOBS_FILE="$JOBS_FILE"
printf '{"format":"agent-bridge-cron-v1","jobs":[]}\n' >"$JOBS_FILE"
cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
bridge_add_agent_id_if_missing "smoke-agent"
BRIDGE_AGENT_DESC["smoke-agent"]="Smoke isolated agent"
BRIDGE_AGENT_ENGINE["smoke-agent"]="claude"
BRIDGE_AGENT_SESSION["smoke-agent"]="smoke-agent"
BRIDGE_AGENT_ISOLATION_MODE["smoke-agent"]="linux-user"
BRIDGE_AGENT_OS_USER["smoke-agent"]="$CURRENT_USER"
EOF

make_script() {
  local name="$1"
  local body="$2"
  local path="$SMOKE_TMP_ROOT/$name"
  printf '%s\n' "$body" >"$path"
  chmod 0755 "$path"
  printf '%s' "$path"
}

write_request() {
  local run_id="$1"
  local job_id="$2"
  local script_path="$3"
  local timeout="${4:-5}"
  local output_cap="${5:-65536}"
  local args_json="${6:-[]}"
  local env_json="${7:-{}}"
  local run_dir="$BRIDGE_CRON_STATE_DIR/runs/$run_id"
  mkdir -p "$run_dir"
  chmod 0700 "$run_dir"
  python3 - "$run_dir/request.json" "$run_id" "$job_id" "$script_path" "$timeout" "$output_cap" "$args_json" "$env_json" <<PY
import json
import os
import sys

request_file, run_id, job_id, script_path, timeout, output_cap, args_json, env_json = sys.argv[1:]
run_dir = os.path.dirname(request_file)
payload = {
    "run_id": run_id,
    "job_id": job_id,
    "job_name": job_id,
    "family": "smoke",
    "source_agent": "smoke-agent",
    "target_agent": "smoke-target",
    "target_engine": "shell",
    "payload_kind": "shell",
    "slot": "manual",
    "dispatch_task_id": 0,
    "created_at": "2026-05-06T00:00:00+00:00",
    "dispatch_body_file": os.path.join(run_dir, "body.md"),
    "payload_file": os.path.join(run_dir, "payload.md"),
    "result_file": os.path.join(run_dir, "result.json"),
    "status_file": os.path.join(run_dir, "status.json"),
    "stdout_log": os.path.join(run_dir, "stdout.log"),
    "stderr_log": os.path.join(run_dir, "stderr.log"),
    "source_file": os.environ["JOBS_FILE"],
    "payload": {
        "kind": "shell",
        "script": script_path,
        "args": json.loads(args_json),
        "env": json.loads(env_json),
        "timeoutSeconds": int(timeout),
        "outputCapBytes": int(output_cap),
    },
    "execution": {
        "run_as_agent": "smoke-agent",
        "os_user": os.environ["CURRENT_USER"],
        "uid": int(os.environ["CURRENT_UID"]),
        "gid": int(os.environ["CURRENT_GID"]),
        "home": os.environ["HOME"],
        "agent_env_file": os.path.join(run_dir, "agent-env.sh"),
        "env_snapshot": {
            "HOME": os.environ["HOME"],
            "PATH": os.environ.get("PATH", ""),
            "USER": os.environ["CURRENT_USER"],
            "LOGNAME": os.environ["CURRENT_USER"],
            "BRIDGE_HOME": os.environ["BRIDGE_HOME"],
            "BRIDGE_STATE_DIR": os.environ["BRIDGE_STATE_DIR"],
            "BRIDGE_SHARED_DIR": os.environ["BRIDGE_SHARED_DIR"],
            "BRIDGE_TASK_DB": os.environ["BRIDGE_TASK_DB"],
            "BRIDGE_CRON_STATE_DIR": os.environ["BRIDGE_CRON_STATE_DIR"],
            "BRIDGE_GATEWAY_PROXY": "0",
            "BRIDGE_CLAUDE_BIN": "/bin/false",
        },
    },
}
with open(request_file, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=True, indent=2)
    fh.write("\n")
os.chmod(request_file, 0o600)
PY
  printf '%s/request.json' "$run_dir"
}

json_field() {
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
value = data
for part in sys.argv[2].split("."):
    value = value.get(part)
print(value if value is not None else "")
PY
}

run_runner() {
  python3 "$SMOKE_REPO_ROOT/bridge-cron-runner.py" run --request-file "$1"
}

smoke_t30_schema_and_update() {
  local script_path job_id
  script_path="$(make_script t30.sh '#!/usr/bin/env bash
exit 0')"
  python3 "$SMOKE_REPO_ROOT/bridge-cron.py" native-create \
    --jobs-file "$JOBS_FILE" \
    --agent smoke-agent \
    --schedule '* * * * *' \
    --title shell-smoke \
    --kind shell \
    --script "$script_path" \
    --script-arg alpha \
    --script-env SCRIPT_MODE=smoke \
    --run-as-agent smoke-agent \
    --timeout 7 \
    --output-cap 99 >/dev/null
  job_id="$(python3 - "$JOBS_FILE" <<'PY'
import json, sys
job = json.load(open(sys.argv[1], encoding="utf-8"))["jobs"][0]
assert job["payload"]["kind"] == "shell"
assert job["payload"]["script"].endswith("t30.sh")
assert job["payload"]["args"] == ["alpha"]
assert job["payload"]["env"] == {"SCRIPT_MODE": "smoke"}
assert job["payload"]["timeoutSeconds"] == 7
assert job["payload"]["outputCapBytes"] == 99
assert job["execution"]["runAsAgent"] == "smoke-agent"
print(job["id"])
PY
)"
  python3 "$SMOKE_REPO_ROOT/bridge-cron.py" native-update --jobs-file "$JOBS_FILE" "$job_id" --title shell-smoke-renamed >/dev/null
  smoke_assert_eq "shell" "$(python3 - "$JOBS_FILE" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["jobs"][0]["payload"]["kind"])
PY
)" "cron update preserves shell payload kind"
}

smoke_t35_reject_argv_injection() {
  local script_path
  script_path="$(make_script t35.sh '#!/usr/bin/env bash
exit 0')"
  if python3 "$SMOKE_REPO_ROOT/bridge-cron.py" native-create \
    --jobs-file "$JOBS_FILE" \
    --agent smoke-agent \
    --schedule '* * * * *' \
    --title bad-argv \
    --kind shell \
    --script "$script_path" \
    --script-arg 'ok;rm -rf /' \
    --run-as-agent smoke-agent >/tmp/cron-shell-t35.out 2>&1; then
    smoke_fail "T35 expected argv injection rejection"
  fi
  smoke_assert_contains "$(cat /tmp/cron-shell-t35.out)" "shell metacharacters" "T35 rejection reason"
}

smoke_t32_success_silent() {
  local script_path request result status
  script_path="$(make_script t32.sh '#!/usr/bin/env bash
exit 0')"
  request="$(write_request t32-run t32-job "$script_path")"
  run_runner "$request" >/dev/null
  result="${request%/*}/result.json"
  status="${request%/*}/status.json"
  smoke_assert_eq "success" "$(json_field "$status" state)" "T32 status success"
  smoke_assert_eq "success" "$(json_field "$result" status)" "T32 result success"
  smoke_assert_eq "silent" "$(json_field "$result" reporting_decision)" "T32 silent reporting"
  smoke_assert_eq "" "$(cat "${request%/*}/stdout.log")" "T32 empty stdout"
}

smoke_t31_uid_drop_access_contract() {
  local script_path request out marker
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  mkdir -p "$BRIDGE_STATE_DIR/agents/smoke-agent"
  printf 'shared-ok\n' >"$BRIDGE_SHARED_DIR/t31.txt"
  marker="$BRIDGE_STATE_DIR/agents/smoke-agent/t31.marker"
  script_path="$(make_script t31.sh "#!/usr/bin/env bash
set -euo pipefail
test -r \"\$HOME\"
grep -q shared-ok \"\$BRIDGE_SHARED_DIR/t31.txt\"
printf state-ok >\"$marker\"
python3 \"$SMOKE_REPO_ROOT/bridge-queue.py\" create --to worker-a --from cron-shell --priority normal --title t31-gateway --body t31 --format shell >/dev/null
printf T31PASS")"
  request="$(write_request t31-run t31-job "$script_path")"
  run_runner "$request" >/dev/null
  smoke_assert_eq "state-ok" "$(cat "$marker")" "T31 agent state write"
  smoke_assert_contains "$(cat "${request%/*}/stdout.log")" "T31PASS" "T31 script completed access probes"
  out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" inbox --agent worker-a)"
  smoke_assert_contains "$out" "t31-gateway" "T31 queue access through script"
}

smoke_t33_script_can_create_queue_task() {
  local script_path request out
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null
  script_path="$(make_script t33.sh "#!/usr/bin/env bash
python3 \"$SMOKE_REPO_ROOT/bridge-queue.py\" create --to worker-a --from cron-shell --priority normal --title shell-created --body shell-body --format shell")"
  request="$(write_request t33-run t33-job "$script_path")"
  run_runner "$request" >/dev/null
  out="$(python3 "$SMOKE_REPO_ROOT/bridge-queue.py" inbox --agent worker-a)"
  smoke_assert_contains "$out" "shell-created" "T33 script-created task reached inbox"
}

smoke_t34_timeout_killpg() {
  local script_path request status result
  script_path="$(make_script t34.sh '#!/usr/bin/env bash
sleep 30')"
  request="$(write_request t34-run t34-job "$script_path" 1)"
  if run_runner "$request" >/tmp/cron-shell-t34.out 2>&1; then
    smoke_fail "T34 expected timeout exit"
  fi
  status="${request%/*}/status.json"
  result="${request%/*}/result.json"
  smoke_assert_eq "timed_out" "$(json_field "$status" state)" "T34 status timed_out"
  smoke_assert_contains "$(json_field "$result" runner_error)" "timed out after 1s" "T34 timeout result"
}

smoke_t36_output_cap() {
  local script_path request result
  script_path="$(make_script t36.sh '#!/usr/bin/env bash
printf "%080d\n" 1')"
  request="$(write_request t36-run t36-job "$script_path" 5 16)"
  run_runner "$request" >/dev/null
  result="${request%/*}/result.json"
  smoke_assert_eq "True" "$(json_field "$result" stdout_truncated)" "T36 stdout truncated flag"
  smoke_assert_contains "$(cat "${request%/*}/stdout.log")" "output truncated" "T36 truncation marker"
}

smoke_t37_no_model_child() {
  local script_path request status
  script_path="$(make_script t37.sh '#!/usr/bin/env bash
echo no-model-needed')"
  request="$(write_request t37-run t37-job "$script_path")"
  run_runner "$request" >/dev/null
  status="${request%/*}/status.json"
  smoke_assert_eq "success" "$(json_field "$status" state)" "T37 succeeds despite BRIDGE_CLAUDE_BIN=/bin/false"
}

smoke_t38_lock_held_success() {
  local script_path request_a request_b out_b status_a status_b
  script_path="$(make_script t38.sh '#!/usr/bin/env bash
sleep 2')"
  request_a="$(write_request t38-run-a t38-job "$script_path" 5)"
  request_b="$(write_request t38-run-b t38-job "$script_path" 5)"
  run_runner "$request_a" >/tmp/cron-shell-t38-a.out 2>&1 &
  local pid
  pid=$!
  sleep 0.3
  out_b="$(run_runner "$request_b")"
  wait "$pid"
  status_a="${request_a%/*}/status.json"
  status_b="${request_b%/*}/status.json"
  smoke_assert_eq "success" "$(json_field "$status_a" state)" "T38 first run success"
  smoke_assert_contains "$out_b" "lock_held" "T38 second run lock-held"
  smoke_assert_eq "success" "$(json_field "$status_b" state)" "T38 lock-held status success"
}

smoke_t39_tamper_rejected() {
  local script_path request status
  script_path="$(make_script t39.sh '#!/usr/bin/env bash
exit 0')"
  request="$(write_request t39-run t39-job "$script_path")"
  chmod 0770 "${request%/*}"
  if run_runner "$request" >/tmp/cron-shell-t39.out 2>&1; then
    smoke_fail "T39 expected tamper rejection"
  fi
  status="${request%/*}/status.json"
  smoke_assert_eq "error" "$(json_field "$status" state)" "T39 chmod tamper status error"
  smoke_assert_eq "request_artifact_tampered" "$(json_field "$status" runner_error)" "T39 chmod tamper runner_error"

  if command -v setfacl >/dev/null 2>&1; then
    request="$(write_request t39-acl-run t39-acl-job "$script_path")"
    setfacl -m "u:${CURRENT_USER}:rwX" "${request%/*}"
    if run_runner "$request" >/tmp/cron-shell-t39-acl.out 2>&1; then
      smoke_fail "T39 expected ACL tamper rejection"
    fi
    smoke_assert_eq "request_artifact_tampered" "$(json_field "${request%/*}/status.json" runner_error)" "T39 ACL tamper runner_error"
  else
    smoke_skip "T39 ACL write exposure" "setfacl not available"
  fi
}

smoke_t39b_invalid_json_tamper_terminal() {
  local run_dir request status out
  run_dir="$BRIDGE_CRON_STATE_DIR/runs/t39b-run"
  mkdir -p "$run_dir"
  request="$run_dir/request.json"
  printf '{not-json\n' >"$request"
  chmod 0770 "$run_dir"
  chmod 0660 "$request"
  if run_runner "$request" >/tmp/cron-shell-t39b.out 2>&1; then
    smoke_fail "T39b expected invalid JSON/tamper rejection"
  fi
  out="$(cat /tmp/cron-shell-t39b.out)"
  smoke_assert_not_contains "$out" "Traceback" "T39b no traceback"
  status="$run_dir/status.json"
  smoke_assert_eq "error" "$(json_field "$status" state)" "T39b status error"
  smoke_assert_eq "request_artifact_tampered" "$(json_field "$status" runner_error)" "T39b terminal runner_error"
}

smoke_t39c_update_revalidates_shell_script() {
  local script_path job_id out
  if [[ "$(id -u)" == "0" ]]; then
    smoke_skip "T39c root-owned script rejection" "current uid is root"
    return 0
  fi
  script_path="$(make_script t39c.sh '#!/usr/bin/env bash
exit 0')"
  python3 "$SMOKE_REPO_ROOT/bridge-cron.py" native-create \
    --jobs-file "$JOBS_FILE" \
    --agent smoke-agent \
    --schedule '* * * * *' \
    --title shell-update-validate \
    --kind shell \
    --script "$script_path" \
    --run-as-agent smoke-agent >/dev/null
  job_id="$(python3 - "$JOBS_FILE" <<'PY'
import json, sys
jobs = json.load(open(sys.argv[1], encoding="utf-8"))["jobs"]
print(next(job["id"] for job in jobs if job["name"] == "shell-update-validate"))
PY
)"
  if bash "$SMOKE_REPO_ROOT/bridge-cron.sh" update "$job_id" --script /bin/true >/tmp/cron-shell-t39c-root.out 2>&1; then
    smoke_fail "T39c expected root-owned script update rejection"
  fi
  out="$(cat /tmp/cron-shell-t39c-root.out)"
  smoke_assert_contains "$out" "owner must be controller uid or run-as uid" "T39c root-owned script rejection reason"

  chmod 0775 "$script_path"
  if bash "$SMOKE_REPO_ROOT/bridge-cron.sh" update "$job_id" --schedule '*/5 * * * *' >/tmp/cron-shell-t39c-mode.out 2>&1; then
    smoke_fail "T39c expected existing unsafe script revalidation rejection"
  fi
  out="$(cat /tmp/cron-shell-t39c-mode.out)"
  smoke_assert_contains "$out" "must not be group/other writable" "T39c existing script mode rejection reason"
}

smoke_t39d_validation_failure_terminal() {
  local script_path request status result out
  script_path="$(make_script t39d.sh '#!/usr/bin/env bash
exit 0')"
  request="$(write_request t39d-run t39d-job "$script_path")"
  chmod 0775 "$script_path"
  if run_runner "$request" >/tmp/cron-shell-t39d.out 2>&1; then
    smoke_fail "T39d expected script validation failure"
  fi
  out="$(cat /tmp/cron-shell-t39d.out)"
  smoke_assert_not_contains "$out" "Traceback" "T39d no traceback"
  status="${request%/*}/status.json"
  result="${request%/*}/result.json"
  smoke_assert_eq "error" "$(json_field "$status" state)" "T39d status error"
  smoke_assert_contains "$(json_field "$status" runner_error)" "script_validation_failed:" "T39d status runner_error"
  smoke_assert_eq "error" "$(json_field "$result" status)" "T39d result error"

  script_path="$(make_script t39d-env.sh '#!/usr/bin/env bash
exit 0')"
  request="$(write_request t39d-env-run t39d-env-job "$script_path")"
  python3 - "$request" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["payload"]["env"] = {"BRIDGE_HOME": "override"}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=True, indent=2)
    fh.write("\n")
PY
  if run_runner "$request" >/tmp/cron-shell-t39d-env.out 2>&1; then
    smoke_fail "T39d expected protected env validation failure"
  fi
  out="$(cat /tmp/cron-shell-t39d-env.out)"
  smoke_assert_not_contains "$out" "Traceback" "T39d env no traceback"
  status="${request%/*}/status.json"
  smoke_assert_contains "$(json_field "$status" runner_error)" "script_validation_failed:" "T39d env terminal runner_error"
}

smoke_run "T30 schema + update preservation" smoke_t30_schema_and_update
smoke_run "T35 argv injection rejection" smoke_t35_reject_argv_injection
smoke_run "T31 UID-drop access contract" smoke_t31_uid_drop_access_contract
smoke_run "T32 silent success" smoke_t32_success_silent
smoke_run "T33 script creates queue task" smoke_t33_script_can_create_queue_task
smoke_run "T34 timeout killpg" smoke_t34_timeout_killpg
smoke_run "T36 output cap" smoke_t36_output_cap
smoke_run "T37 no Claude/Codex child" smoke_t37_no_model_child
smoke_run "T38 lock contention is silent success" smoke_t38_lock_held_success
smoke_run "T39 tamper rejection" smoke_t39_tamper_rejected
smoke_run "T39b invalid JSON tamper writes terminal status" smoke_t39b_invalid_json_tamper_terminal
smoke_run "T39c update revalidates shell script" smoke_t39c_update_revalidates_shell_script
smoke_run "T39d validation failure writes terminal status" smoke_t39d_validation_failure_terminal

smoke_log "all cron shell runner checks passed"
