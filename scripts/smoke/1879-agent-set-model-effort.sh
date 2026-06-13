#!/usr/bin/env bash
# scripts/smoke/1879-agent-set-model-effort.sh — issue #1879.
#
# Pins the sanctioned, trust-gated, audited `agent set-model` / `agent
# set-effort` verbs. These are the typed in-session surface an operator-directed
# per-agent model/effort change uses instead of a hand edit of the
# #341-protected agent-roster.local.sh. They route through the EXISTING
# `roster materialize-fields` writer (same #341 trust gate as `config set`,
# same before/after-sha256 system_config_mutation audit row) and add a strict
# allowlist + NO shell-eval of the value (#1738).
#
# Four acceptance assertions (issue #1879):
#   (a) admin+trusted caller writes successfully + a system_config_mutation
#       audit row is recorded;
#   (b) a non-admin / non-trusted caller is REJECTED exactly like `config set`
#       (no write, no audit row);
#   (c) a non-allowlisted model/effort token is REJECTED (no write, no eval);
#   (d) the written value is read back by bridge_agent_model / bridge_agent_effort.
#
# Plus a #1738 spoof-hardening assertion: a shell-metachar payload is rejected
# AND never lands in the roster / never produces an eval side effect.
#
# Caller-source trust is forced via BRIDGE_CALLER_SOURCE=operator-tui (the
# trusted path) / unset (the agent-direct deny path) so the smoke does not
# depend on a real TTY. Per footgun #11 the inline parsing uses
# `python3 -c '<script>' <argv>` (no `<<PY` heredoc-stdin).

set -euo pipefail

SMOKE_NAME="1879-agent-set-model-effort"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd bash

# Trusted caller (operator-tui source) — the sanctioned operator path. The
# operator-tui claim is only honored for a NON-agent process, so we unset
# BRIDGE_AGENT_ID / BRIDGE_ADMIN_AGENT_ID here (#1879 r3): the operator TUI runs
# without an agent session id. Without the unsets this wrapper would inherit a
# leaked BRIDGE_AGENT_ID from a runner that is itself a bridge agent session
# (e.g. when the smoke is run by hand from inside an agent), and the r3 wrapper
# fix would correctly treat the forged claim as a non-admin agent claim and deny
# — env-fragility, not a behavior change. Pinning the env makes the operator
# path deterministic on any runner. stdin from /dev/null so no stray TTY skews
# the source resolution either.
BA() {
  env -u BRIDGE_AGENT_ID -u BRIDGE_ADMIN_AGENT_ID BRIDGE_CALLER_SOURCE="operator-tui" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" "$@" </dev/null
}

# Untrusted caller — no BRIDGE_CALLER_SOURCE override and no admin identity, so
# bridge_agent_update_caller_source() resolves to `agent-direct` (the smoke runs
# with no TTY). Mirrors a non-admin agent session that has not been promoted.
BA_UNTRUSTED() {
  env -u BRIDGE_CALLER_SOURCE -u BRIDGE_AGENT_ID -u BRIDGE_ADMIN_AGENT_ID \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" "$@" </dev/null
}

reset_runtime() {
  rm -rf "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_AGENT_ROOT_V2"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_AGENT_ROOT_V2"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  : >"$BRIDGE_AUDIT_LOG"
}

# Extract a single managed-role field value from the roster file. python3 -c
# argv form (footgun #11). Mirrors 1427-A's roster_field helper.
roster_field() {
  local agent="$1"
  local var="$2"
  python3 -c '
import re, shlex, sys
path, agent, var = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
m = re.search(rf"^# BEGIN AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n(.*?)^# END AGENT BRIDGE MANAGED ROLE: {re.escape(agent)}\n", text, re.M | re.S)
body = m.group(1) if m else ""
fm = re.search(rf"^{re.escape(var)}\[\"{re.escape(agent)}\"\]=(.*)$", body, re.M)
if not fm:
    print("")
else:
    rhs = fm.group(1)
    try:
        parts = shlex.split(rhs)
        print(parts[0] if parts else "")
    except ValueError:
        print(rhs)
' "$BRIDGE_ROSTER_LOCAL_FILE" "$agent" "$var"
}

roster_sha() {
  python3 -c '
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "$BRIDGE_ROSTER_LOCAL_FILE"
}

# Count system_config_mutation audit rows whose detail.operation mentions the
# given dimension (e.g. "model=" / "effort="). Empty file → 0. python3 -c argv.
audit_mutation_rows_for() {
  local needle="$1"
  python3 -c '
import json, sys
path, needle = sys.argv[1], sys.argv[2]
n = 0
try:
    fh = open(path, encoding="utf-8")
except FileNotFoundError:
    print(0); sys.exit(0)
for line in fh:
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        continue
    if row.get("action") != "system_config_mutation":
        continue
    detail = row.get("detail") or {}
    op = str(detail.get("operation", ""))
    if needle in op:
        n += 1
print(n)
' "$BRIDGE_AUDIT_LOG" "$needle"
}

# Resolve the launched model/effort through the SAME accessor the launch hot
# path uses (bridge_agent_model / bridge_agent_effort). `bridge-run.sh <a>
# --dry-run` prints the resolved engine launch argv (`launch=...`) the daemon
# would use; for a static Claude agent that line is built by
# lib/bridge-state.sh::bridge_build_static_claude_launch_cmd, which reads the
# materialized model/effort via bridge_agent_model / bridge_agent_effort and
# emits `--model <m>` / `--effort <e>`. So the presence of those flags on the
# launch line proves the written value is read back by the production accessor
# (assertion d) — the same read-back surface 1427-A's T6 uses. Returns the
# launch= line; the caller asserts on the flag tokens.
launch_line() {
  local agent="$1"
  local run_out
  run_out="$(bash "$SMOKE_REPO_ROOT/bridge-run.sh" "$agent" --dry-run </dev/null 2>/dev/null || true)"
  printf '%s\n' "$run_out" | sed -n 's/^launch=//p' | head -n 1
}

create_agent() {
  BA create "$@" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# (a) admin+trusted caller writes successfully + audit row recorded
# (d) the written value is read back by bridge_agent_model / bridge_agent_effort
# ---------------------------------------------------------------------------
test_trusted_write_and_audit_and_readback() {
  reset_runtime
  create_agent t1 --engine claude

  local out
  out="$(BA set-model t1 claude-opus-4-8 2>&1)"
  smoke_assert_contains "$out" "materialize: ok" "set-model reports ok (a: write succeeded)"
  smoke_assert_eq "claude-opus-4-8" "$(roster_field t1 BRIDGE_AGENT_MODEL)" "a: model landed in roster"

  out="$(BA set-effort t1 xhigh 2>&1)"
  smoke_assert_contains "$out" "materialize: ok" "set-effort reports ok (a: write succeeded)"
  smoke_assert_eq "xhigh" "$(roster_field t1 BRIDGE_AGENT_EFFORT)" "a: effort landed in roster"

  # Audit: each mutation recorded a system_config_mutation row naming the dim.
  smoke_assert_eq "1" "$(audit_mutation_rows_for 'model=claude-opus-4-8')" "a: set-model audit row recorded"
  smoke_assert_eq "1" "$(audit_mutation_rows_for 'effort=xhigh')" "a: set-effort audit row recorded"

  # (d) read back through the production launch path (bridge_agent_model /
  # bridge_agent_effort feed the static-Claude launch builder). The resolved
  # launch line must carry both materialized flags.
  local launch
  launch="$(launch_line t1)"
  smoke_assert_contains "$launch" "--model claude-opus-4-8" "d: bridge_agent_model reads back into launch --model"
  smoke_assert_contains "$launch" "--effort xhigh" "d: bridge_agent_effort reads back into launch --effort"
}

# ---------------------------------------------------------------------------
# (b) non-admin / non-trusted caller REJECTED exactly like config set
# ---------------------------------------------------------------------------
test_untrusted_caller_rejected() {
  reset_runtime
  create_agent t2 --engine claude
  local before_sha
  before_sha="$(roster_sha)"

  local rc=0 out
  set +e
  out="$(BA_UNTRUSTED set-model t2 claude-opus-4-8 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "b: expected non-zero exit for agent-direct set-model; out=$out"
  fi
  smoke_assert_contains "$out" "deny" "b: rejection mentions deny"
  smoke_assert_eq "" "$(roster_field t2 BRIDGE_AGENT_MODEL)" "b: no model written for untrusted caller"
  smoke_assert_eq "$before_sha" "$(roster_sha)" "b: roster unchanged after untrusted deny"
  smoke_assert_eq "0" "$(audit_mutation_rows_for 'model=')" "b: no mutation audit row for untrusted deny"

  # Same deny on the effort verb.
  set +e
  out="$(BA_UNTRUSTED set-effort t2 high 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "b: expected non-zero exit for agent-direct set-effort; out=$out"
  fi
  smoke_assert_eq "" "$(roster_field t2 BRIDGE_AGENT_EFFORT)" "b: no effort written for untrusted caller"
}

# ---------------------------------------------------------------------------
# (c) non-allowlisted model/effort token REJECTED (no write, no eval)
# + #1738 spoof hardening: a shell-metachar payload is refused and never lands.
# ---------------------------------------------------------------------------
test_bad_token_rejected_no_eval() {
  reset_runtime
  create_agent t3 --engine claude
  local before_sha
  before_sha="$(roster_sha)"

  # A non-allowlisted effort level.
  local rc=0 out
  set +e
  out="$(BA set-effort t3 turbo 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "c: expected non-zero exit for non-allowlisted effort 'turbo'; out=$out"
  fi
  smoke_assert_contains "$out" "allowlist" "c: effort rejection mentions allowlist"
  smoke_assert_eq "" "$(roster_field t3 BRIDGE_AGENT_EFFORT)" "c: no effort written for bad token"

  # #1738: a shell-metachar / command-substitution payload as a model value.
  # If the value were ever eval'd, this would create the canary file. The
  # allowlist must refuse it with no write and no side effect.
  local canary="$SMOKE_TMP_ROOT/eval-canary-$$"
  rm -f "$canary"
  set +e
  out="$(BA set-model t3 "x\$(touch $canary)" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    smoke_fail "c/#1738: expected non-zero exit for shell-metachar model token; out=$out"
  fi
  smoke_assert_contains "$out" "allowlist" "c/#1738: model rejection mentions allowlist"
  if [[ -e "$canary" ]]; then
    smoke_fail "c/#1738: eval canary file was created — the value was shell-eval'd"
  fi
  smoke_assert_eq "" "$(roster_field t3 BRIDGE_AGENT_MODEL)" "c/#1738: no model written for metachar token"
  smoke_assert_eq "$before_sha" "$(roster_sha)" "c: roster byte-identical after both bad-token rejections"
  smoke_assert_eq "0" "$(audit_mutation_rows_for 'model=')" "c: no mutation audit row for bad token"
}

# ---------------------------------------------------------------------------
# Bonus: --dry-run gates but writes nothing (the sanctioned probe path).
# ---------------------------------------------------------------------------
test_dry_run_no_write() {
  reset_runtime
  create_agent t4 --engine claude
  local before_sha
  before_sha="$(roster_sha)"

  local out
  out="$(BA set-model t4 claude-sonnet-4-5 --dry-run 2>&1)"
  smoke_assert_contains "$out" "dry_run: yes" "dry-run flagged"
  smoke_assert_eq "" "$(roster_field t4 BRIDGE_AGENT_MODEL)" "dry-run wrote no model"
  smoke_assert_eq "$before_sha" "$(roster_sha)" "dry-run roster byte-identical"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  # CI runners ship no engine npm package; `agent create --engine <e>` runs a
  # `command -v <e>` pre-flight that hard-dies otherwise. Seed executable engine
  # stubs + prepend to PATH (the agent-doctor #1397 / 1427-A pattern).
  _stub_engine_dir="$SMOKE_TMP_ROOT/stub-engine-bin"
  mkdir -p "$_stub_engine_dir"
  for _eng in claude codex; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$_stub_engine_dir/$_eng"
    chmod +x "$_stub_engine_dir/$_eng"
  done
  export PATH="$_stub_engine_dir:$PATH"

  smoke_run "trusted write + audit row + accessor read-back (a,d)"  test_trusted_write_and_audit_and_readback
  smoke_run "untrusted / non-admin caller rejected (b)"             test_untrusted_caller_rejected
  smoke_run "bad token rejected, no write, no eval (c,#1738)"       test_bad_token_rejected_no_eval
  smoke_run "--dry-run gates but writes nothing"                    test_dry_run_no_write
  smoke_log "passed"
}

main "$@"
