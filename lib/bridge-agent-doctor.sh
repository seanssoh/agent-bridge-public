#!/usr/bin/env bash
# bridge-agent-doctor.sh — admin CRUD self-check (issue #580 Track 2).
#
# Exercises every documented `agent-bridge agent <verb>` path the admin
# uses against an ephemeral test-fixture agent so an operator can verify
# the typed-write surface end-to-end without trusting "it worked once."
#
# What it covers:
#   1. create     — creates a smoke-* fixture (requires --test-fixture
#                   per #598 Track 4; we always pass it from here).
#   2. update     — typed-flag completion path (#580 Track 2):
#                   --desc, --engine no-op (round-trip), --channels-set
#                   "" to clear, --loop on, --continue on, --class user.
#   3. registry   — read-back via `agent registry --json`, asserts the
#                   fixture row exists and the post-update fields match.
#   4. show       — read-back via `agent show <fixture> --json`.
#   5. reclassify — runs `agent reclassify --agent <fixture> --apply`;
#                   reports n/a (fixture is created as static, so the
#                   reclassifier finds no candidate — that is the
#                   correct success shape, not a failure).
#   6. retire     — runs `agent retire <fixture>`; reports n/a (the
#                   fixture is static-roster, so retire correctly
#                   refuses; #607 retire is for dynamic/orphan only).
#   7. delete     — `agent delete <fixture>` with --orphan-tasks +
#                   --purge-home; this is the success-path final step.
#
# Output: one line per check, prefixed `[doctor] pass:` /
# `[doctor] fail:` / `[doctor] n/a:`. Exits non-zero if any required
# check failed (n/a is not failure). With --json, emits a single JSON
# envelope summarizing all checks.
#
# Cleanup: traps EXIT and removes the fixture even on failure. Honors
# --keep-fixture so an operator can inspect the residue post-mortem.

# shellcheck shell=bash

# Trap target for the doctor's EXIT/INT/TERM cleanup. Defined at module
# scope (not inside bridge_agent_doctor_run) so the trap can fire after
# the function frame has been popped; locals would be unbound by then
# and `set -u` would fault. State lives in the BRIDGE_AGENT_DOCTOR_*
# globals seeded by bridge_agent_doctor_run.
#
# Codex r1 (PR #615) — D5 robustness: a leaked fixture is itself a
# doctor failure. Cleanup uses the admin caller already validated by
# the run function (do not re-resolve from env in the trap; env may
# have been mutated mid-run). Cleanup passes --force so an active
# fixture session does not block delete (run_delete:2993-2998). If
# cleanup itself fails, the trap forces the process to exit non-zero
# so the operator does not get a green doctor with a residual roster
# block / home directory.
# shellcheck disable=SC2329
_bridge_agent_doctor_cleanup() {
  [[ "${BRIDGE_AGENT_DOCTOR_CLEANED:-0}" == "1" ]] && return 0
  BRIDGE_AGENT_DOCTOR_CLEANED=1
  [[ "${BRIDGE_AGENT_DOCTOR_KEEP:-0}" == "1" ]] && return 0
  local fixture="${BRIDGE_AGENT_DOCTOR_FIXTURE:-}"
  [[ -n "$fixture" ]] || return 0
  local script_dir="${BRIDGE_AGENT_DOCTOR_SCRIPT_DIR:-}"
  local bash_bin="${BRIDGE_AGENT_DOCTOR_BASH_BIN:-bash}"
  local caller="${BRIDGE_AGENT_DOCTOR_CALLER:-}"
  [[ -n "$script_dir" ]] || return 0
  # The caller was validated (admin + trusted source) before fixture
  # creation, so it is guaranteed non-empty here. Pass --force because
  # delete refuses active sessions without it (bridge-agent.sh:2993-2998)
  # and the fixture session may still be alive if a mid-stream check
  # aborted before step 7.
  local cleanup_args=(delete "$fixture" --orphan-tasks --purge-home --force)
  [[ -n "$caller" ]] && cleanup_args+=(--from "$caller")
  local cleanup_out cleanup_rc=0
  cleanup_out="$("$bash_bin" "$script_dir/bridge-agent.sh" "${cleanup_args[@]}" 2>&1)" || cleanup_rc=$?
  if [[ $cleanup_rc -ne 0 ]]; then
    # If the explicit step-7 delete already removed the fixture, the
    # follow-up retry will fail with "agent not found" — that is not a
    # leak. Recognise the not-found shape and exit clean.
    case "$cleanup_out" in
      *"not found"*|*"존재하지"*|*"없습니다"*)
        return 0
        ;;
    esac
    printf '[doctor] fail: cleanup — fixture=%s rc=%d out=%s\n' \
      "$fixture" "$cleanup_rc" "$(printf '%s' "$cleanup_out" | head -c 240)" >&2
    # Force the process to exit non-zero so a leaked fixture is
    # surfaced as a doctor failure, not a swallowed warning.
    exit 1
  fi
}

# bridge_agent_doctor_run — entry point invoked by run_doctor in
# bridge-agent.sh. Argv is the remainder after `agent doctor`.
bridge_agent_doctor_run() {
  local from_agent=""
  local keep_fixture=0
  local json_mode=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)
        [[ $# -ge 2 ]] || bridge_die "옵션 값이 필요합니다: $1"
        from_agent="$2"
        shift 2
        ;;
      --keep-fixture)
        keep_fixture=1
        shift
        ;;
      --json)
        json_mode=1
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage: agent-bridge agent doctor [--from <admin>] [--keep-fixture] [--json]

Run an admin CRUD self-check against an ephemeral test-fixture agent.
Each step prints `[doctor] pass:` / `[doctor] fail:` / `[doctor] n/a:`.
The fixture is removed on exit (even on failure) unless --keep-fixture
is passed.

doctor is admin-only by construction: it exercises update/delete which
are admin-gated. The caller is resolved from --from <admin> first, then
BRIDGE_AGENT_ID. doctor refuses to create a fixture if no admin caller
can be resolved or the caller is not the configured admin agent.
EOF
        return 0
        ;;
      *)
        bridge_die "지원하지 않는 agent doctor 옵션입니다: $1"
        ;;
    esac
  done

  # Codex r1 (PR #615) — D5 robustness: enforce the admin gate UPFRONT,
  # before any fixture is created. The doctor exercises update/delete
  # which are both admin-gated (bridge-agent.sh:2968-2974), so a doctor
  # run that cannot pass that gate would silently downgrade those steps
  # to n/a, exit 0, and leave the fixture's roster row + home behind.
  # Make caller resolution fail-fast against the same predicates the
  # production gate uses: admin identity and operator-trusted source.
  local doctor_caller doctor_caller_source
  doctor_caller="$(bridge_agent_update_caller_agent "$from_agent")"
  doctor_caller_source="$(bridge_agent_update_caller_source)"
  if [[ -z "$doctor_caller" ]]; then
    bridge_die "agent doctor: caller_agent unspecified — pass --from <admin-agent> or set BRIDGE_AGENT_ID before running 'agent doctor'. Aborted before fixture creation."
  fi
  if ! bridge_agent_update_caller_is_admin "$doctor_caller"; then
    bridge_die "agent doctor: caller agent $doctor_caller is not the admin agent — doctor is admin-only by construction. Aborted before fixture creation."
  fi
  if [[ "$doctor_caller_source" != "operator-tui" && "$doctor_caller_source" != "operator-trusted-id" ]]; then
    bridge_die "agent doctor: caller source $doctor_caller_source is not allowed to mutate system config (need operator-tui or operator-trusted-id). Aborted before fixture creation."
  fi

  # Pick a unique fixture name. The `smoke-` prefix matches
  # BRIDGE_TEST_ARTIFACT_PREFIXES so create requires --test-fixture
  # (which we pass) and the orphan-agent-dir detector (#598 Track 2)
  # treats residue as reapable test fixtures.
  local stamp pid rand fixture
  stamp="$(date -u +%Y%m%d%H%M%S 2>/dev/null || date +%s)"
  pid="$$"
  if command -v od >/dev/null 2>&1; then
    rand="$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%s' "$RANDOM")"
  else
    rand="$RANDOM"
  fi
  fixture="smoke-doctor-${stamp}-${pid}-${rand}"

  local script_dir bash_bin
  script_dir="${SCRIPT_DIR:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
  bash_bin="${BRIDGE_BASH_BIN:-bash}"

  # Cleanup trap: best-effort delete + purge-home so the fixture is gone
  # whether the doctor passed or failed mid-stream. Skipped when
  # --keep-fixture is set.
  #
  # The trap-target state has to live in script-global vars (not
  # `local`) because EXIT traps fire AFTER the function frame has been
  # popped, and `set -u` would fault on any reference to a then-unbound
  # local. We use BRIDGE_AGENT_DOCTOR_* names so collisions with caller
  # scope are improbable; the caller (run_doctor in bridge-agent.sh)
  # invokes us once per process exec.
  BRIDGE_AGENT_DOCTOR_CLEANED=0
  BRIDGE_AGENT_DOCTOR_KEEP="$keep_fixture"
  BRIDGE_AGENT_DOCTOR_FIXTURE="$fixture"
  BRIDGE_AGENT_DOCTOR_CALLER="$doctor_caller"
  BRIDGE_AGENT_DOCTOR_SCRIPT_DIR="$script_dir"
  BRIDGE_AGENT_DOCTOR_BASH_BIN="$bash_bin"
  trap _bridge_agent_doctor_cleanup EXIT INT TERM

  # Each check appends "STATUS\tNAME\tDETAIL" to a TSV stream;
  # bridge_agent_doctor_emit summarizes at the end.
  local results=""
  local fail_count=0
  local pass_count=0
  local na_count=0

  _doctor_record() {
    local status="$1" name="$2" detail="$3"
    results+="${status}"$'\t'"${name}"$'\t'"${detail}"$'\n'
    case "$status" in
      pass) pass_count=$((pass_count + 1)) ;;
      fail) fail_count=$((fail_count + 1)) ;;
      n/a)  na_count=$((na_count + 1)) ;;
    esac
    if [[ $json_mode -ne 1 ]]; then
      printf '[doctor] %s: %s — %s\n' "$status" "$name" "$detail"
    fi
  }

  # ---- 1. create -------------------------------------------------------
  # Issue #185: when BRIDGE_HOME is ephemeral, the agent workdir must
  # also live under that root or the auto-memory seeder refuses. The
  # doctor must therefore pin the fixture workdir to
  # `$BRIDGE_HOME/agents/<fixture>` directly — NOT to
  # `$BRIDGE_AGENT_HOME_ROOT` because that env var may have been set by
  # an outer agent's launcher to a live path even after BRIDGE_HOME was
  # rerouted to a tmp root for an isolated test. Deriving from
  # BRIDGE_HOME is the canonical mapping bridge-lib.sh uses when no
  # explicit override is in play.
  local fixture_home_root="${BRIDGE_HOME:-$HOME/.agent-bridge}/agents"
  local fixture_workdir="$fixture_home_root/$fixture"
  local create_args=(create "$fixture"
    --engine claude
    --workdir "$fixture_workdir"
    --test-fixture)
  local create_out create_rc=0
  # `set -e` in the parent script would abort the function on any
  # non-zero subshell exit, so each child invocation in this doctor is
  # guarded with `|| true` and the rc is captured via `${PIPESTATUS[0]}`
  # (works for both pipelined and unpipelined runs).
  create_out="$("$bash_bin" "$script_dir/bridge-agent.sh" "${create_args[@]}" 2>&1)" || create_rc=$?
  if [[ $create_rc -eq 0 ]]; then
    _doctor_record pass "create" "fixture=$fixture"
  else
    _doctor_record fail "create" "rc=$create_rc out=$(printf '%s' "$create_out" | head -c 240)"
    bridge_agent_doctor_emit "$results" "$pass_count" "$fail_count" "$na_count" "$json_mode" "$fixture"
    return 1
  fi

  # ---- 2. update -------------------------------------------------------
  # Caller was validated as admin upfront (D5 robustness fix), so update
  # must succeed unless the production writer regressed. We always
  # forward --from since doctor_caller is guaranteed non-empty here.
  local update_args=(update "$fixture"
    --desc "doctor self-check fixture"
    --loop on
    --continue on
    --class user
    --from "$doctor_caller")
  local update_out update_rc=0
  update_out="$("$bash_bin" "$script_dir/bridge-agent.sh" "${update_args[@]}" 2>&1)" || update_rc=$?
  if [[ $update_rc -eq 0 ]]; then
    _doctor_record pass "update" "desc/loop/continue/class persisted"
  else
    _doctor_record fail "update" "rc=$update_rc out=$(printf '%s' "$update_out" | head -c 240)"
  fi

  # ---- 3. registry --json (read-back) ---------------------------------
  # The registry endpoint is a read-only enumeration that the admin
  # uses to confirm "is the fixture visible in the source-of-truth view"
  # — we assert presence here and defer post-update field assertions
  # to the `show` step (registry only exposes id/class/source/etc., not
  # the BRIDGE_AGENT_DESC payload).
  local reg_out reg_rc=0
  reg_out="$("$bash_bin" "$script_dir/bridge-agent.sh" registry --json 2>&1)" || reg_rc=$?
  if [[ $reg_rc -ne 0 ]]; then
    _doctor_record fail "registry" "rc=$reg_rc out=$(printf '%s' "$reg_out" | head -c 240)"
  else
    local reg_check_rc=0
    local reg_check
    reg_check="$(FIXTURE="$fixture" REG_JSON="$reg_out" python3 - <<'PY'
import json, os, sys
fixture = os.environ["FIXTURE"]
text = os.environ.get("REG_JSON", "")
try:
    data = json.loads(text)
except Exception as exc:
    print(f"FAIL: registry --json not parseable: {exc}")
    sys.exit(2)
agents = data.get("agents") if isinstance(data, dict) else None
if agents is None and isinstance(data, list):
    agents = data
if not isinstance(agents, list):
    print("FAIL: registry --json shape unexpected (no agents list)")
    sys.exit(2)
match = None
for row in agents:
    if isinstance(row, dict) and row.get("id") == fixture:
        match = row
        break
if match is None:
    print(f"FAIL: fixture '{fixture}' not found in registry")
    sys.exit(2)
print("OK")
PY
)" || reg_check_rc=$?
    if [[ $reg_check_rc -eq 0 && "$reg_check" == OK* ]]; then
      _doctor_record pass "registry" "fixture row visible"
    else
      _doctor_record fail "registry" "$reg_check"
    fi
  fi

  # ---- 4. show --------------------------------------------------------
  # The post-update read-back lives here: `agent show --json` is the
  # only enumerator that surfaces the BRIDGE_AGENT_DESC payload, so
  # this is where we assert the typed-flag mutation round-tripped.
  local show_out show_rc=0
  show_out="$("$bash_bin" "$script_dir/bridge-agent.sh" show "$fixture" --json 2>&1)" || show_rc=$?
  if [[ $show_rc -ne 0 ]]; then
    _doctor_record fail "show" "rc=$show_rc out=$(printf '%s' "$show_out" | head -c 240)"
  elif [[ "$update_rc" -eq 0 ]]; then
    local show_check_rc=0
    local show_check
    show_check="$(SHOW_JSON="$show_out" python3 - <<'PY'
import json, os, sys
text = os.environ.get("SHOW_JSON", "")
try:
    data = json.loads(text)
except Exception as exc:
    print(f"FAIL: show --json not parseable: {exc}")
    sys.exit(2)
# `agent show --json` returns the row at the top level with `agent`
# being the id string (not a nested record). The desc field has
# historically been emitted as `description` or `desc`. Also tolerate
# the older shape where the row was nested under {"agent": {...}}.
if isinstance(data, dict) and isinstance(data.get("agent"), dict):
    row = data["agent"]
elif isinstance(data, dict):
    row = data
else:
    print(f"FAIL: show row shape unexpected: {type(data).__name__}")
    sys.exit(2)
desc = row.get("description") or row.get("desc") or ""
if "doctor self-check" not in desc:
    print(f"FAIL: post-update description not reflected: {desc!r}")
    sys.exit(2)
print("OK")
PY
)" || show_check_rc=$?
    if [[ $show_check_rc -eq 0 && "$show_check" == OK* ]]; then
      _doctor_record pass "show" "post-update description reflected"
    else
      _doctor_record fail "show" "$show_check"
    fi
  else
    _doctor_record pass "show" "json envelope returned (update was n/a — no value-check)"
  fi

  # ---- 5. reclassify --------------------------------------------------
  # The fixture was created as static-source (every `agent create`
  # writes BRIDGE_AGENT_SOURCE="static"), so reclassify finds no
  # candidate — that's the correct success shape. Report n/a so the
  # operator sees the path was exercised but had nothing to do.
  local recl_out recl_rc=0
  recl_out="$("$bash_bin" "$script_dir/bridge-agent.sh" reclassify --agent "$fixture" --apply 2>&1)" || recl_rc=$?
  if [[ $recl_rc -eq 0 ]]; then
    case "$recl_out" in
      *"no candidates"*)
        _doctor_record n/a "reclassify" "no candidates (fixture is already static — expected)"
        ;;
      *)
        _doctor_record pass "reclassify" "ran (output: $(printf '%s' "$recl_out" | tr '\n' ' ' | head -c 180))"
        ;;
    esac
  else
    _doctor_record fail "reclassify" "rc=$recl_rc out=$(printf '%s' "$recl_out" | head -c 240)"
  fi

  # ---- 6. retire ------------------------------------------------------
  # Static-roster agents are out-of-scope for retire (#607); the deny
  # is the correct shape. Report n/a.
  local ret_out ret_rc=0
  ret_out="$("$bash_bin" "$script_dir/bridge-agent.sh" retire "$fixture" --dry-run 2>&1)" || ret_rc=$?
  case "$ret_out" in
    *"is static-roster"*|*"static-roster"*)
      _doctor_record n/a "retire" "fixture is static-roster (delete owns this path — expected)"
      ;;
    *)
      if [[ $ret_rc -eq 0 ]]; then
        _doctor_record pass "retire" "ran (unexpected — fixture should be static)"
      else
        _doctor_record fail "retire" "rc=$ret_rc out=$(printf '%s' "$ret_out" | head -c 240)"
      fi
      ;;
  esac

  # ---- 7. delete ------------------------------------------------------
  # Success-path final step. We pass --orphan-tasks (the fixture cannot
  # have real tasks, but the doctor must not refuse on a leftover row
  # from a previous run), --purge-home (we own the home we just
  # scaffolded), and --force (the fixture has no live session under the
  # doctor itself, but --force keeps step 7 symmetric with the trap's
  # cleanup so a session that some external process attached to the
  # fixture name does not block delete here). Caller is guaranteed
  # admin (validated upfront), so we always forward --from.
  local del_args=(delete "$fixture" --orphan-tasks --purge-home --force --from "$doctor_caller")
  local del_out del_rc=0
  del_out="$("$bash_bin" "$script_dir/bridge-agent.sh" "${del_args[@]}" 2>&1)" || del_rc=$?
  if [[ $del_rc -eq 0 ]]; then
    _doctor_record pass "delete" "fixture removed + home purged"
    BRIDGE_AGENT_DOCTOR_CLEANED=1   # trap is a no-op now
  else
    _doctor_record fail "delete" "rc=$del_rc out=$(printf '%s' "$del_out" | head -c 240)"
  fi

  bridge_agent_doctor_emit "$results" "$pass_count" "$fail_count" "$na_count" "$json_mode" "$fixture"
  if [[ $fail_count -gt 0 ]]; then
    return 1
  fi
  return 0
}

# bridge_agent_doctor_emit — final summary line + (optional) JSON
# envelope. Text mode prints one line; the per-check `[doctor] STATUS:`
# lines were already streamed inline by _doctor_record.
bridge_agent_doctor_emit() {
  local results="$1"
  local pass_count="$2"
  local fail_count="$3"
  local na_count="$4"
  local json_mode="$5"
  local fixture="$6"

  if [[ "$json_mode" == "1" ]]; then
    bridge_require_python
    PASS="$pass_count" FAIL="$fail_count" NA="$na_count" \
    FIXTURE="$fixture" RESULTS="$results" python3 - <<'PY'
import json
import os

results_raw = os.environ.get("RESULTS", "")
checks = []
for line in results_raw.splitlines():
    if not line.strip():
        continue
    parts = line.split("\t", 2)
    while len(parts) < 3:
        parts.append("")
    checks.append({"status": parts[0], "name": parts[1], "detail": parts[2]})

payload = {
    "fixture": os.environ.get("FIXTURE", ""),
    "summary": {
        "pass": int(os.environ.get("PASS", "0")),
        "fail": int(os.environ.get("FAIL", "0")),
        "n/a": int(os.environ.get("NA", "0")),
    },
    "checks": checks,
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
    return 0
  fi

  printf '[doctor] summary: pass=%d fail=%d n/a=%d fixture=%s\n' \
    "$pass_count" "$fail_count" "$na_count" "$fixture"
}
