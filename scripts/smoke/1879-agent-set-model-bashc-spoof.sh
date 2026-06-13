#!/usr/bin/env bash
# scripts/smoke/1879-agent-set-model-bashc-spoof.sh — issue #1879 PR #1887 r3.
#
# Pins the WRAPPER-side close of the `bash -c` trust-boundary bypass that
# survived the r2 argv-visible tool-policy hook gate. The bypass hid the
# roster-writing verb inside a quoted `bash -c '...'` command string — opaque to
# the hook's argv recognizer — while keeping a forged
# `BRIDGE_CALLER_SOURCE=operator-tui` env claim for the child process. On the
# r2 head a NON-admin agent could write any agent's BRIDGE_AGENT_MODEL with rc=0.
#
# The robust close lives in lib/bridge-agent-update.sh
# (bridge_agent_update_caller_source): an agent-authored process carries
# BRIDGE_AGENT_ID, and that env var follows the process into ANY subshell /
# `bash -c` / `eval` / nested spelling. operator-tui / operator-trusted-id are
# OPERATOR sources, never agent sources, so an agent session is resolved by
# IDENTITY only — the admin agent (BRIDGE_AGENT_ID == BRIDGE_ADMIN_AGENT_ID) is
# promoted to operator-trusted-id (#1122), every other agent is agent-direct
# (its forged env claim is ignored), and the operator-tui human path (no
# BRIDGE_AGENT_ID) still honors its claim / TTY.
#
# Assertions:
#   (1) ★the exact `bash -c` bypass from a NON-admin agent context
#       (BRIDGE_AGENT_ID set != admin, forged BRIDGE_CALLER_SOURCE=operator-tui)
#       -> DENY, roster BYTE-IDENTICAL, no model line written, no mutation audit
#       row. The argv-hidden spelling no longer reaches a successful write.
#   (2) every r2 argv spelling from the same non-admin context -> still DENY,
#       roster byte-identical (env-prefix, `env VAR=...`, direct bridge-agent.sh,
#       `;`/`&&` separators) — confirms the wrapper close holds across spellings.
#   (3) admin agent (BRIDGE_AGENT_ID == BRIDGE_ADMIN_AGENT_ID, NO env claim) ->
#       set-model WRITES via the #1122 identity path (the legit #1879 target).
#   (4) operator-tui (NO BRIDGE_AGENT_ID, explicit operator-tui claim) ->
#       set-model WRITES (the legit human operator path).
#
# Per footgun #11 the inline parsing uses `python3 -c '<script>' <argv>` (no
# `<<PY` heredoc-stdin). Caller-source trust is forced via env (not a real TTY).

set -euo pipefail

SMOKE_NAME="1879-agent-set-model-bashc-spoof"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Identity constant for the smoke's admin agent.
ADMIN_AGENT="patch"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd bash

# Trusted operator-tui caller (no agent identity) — used to seed the victim
# agent and to exercise the legit operator path (assertion 4).
BA_OPERATOR() {
  env -u BRIDGE_AGENT_ID -u BRIDGE_ADMIN_AGENT_ID BRIDGE_CALLER_SOURCE="operator-tui" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" "$@" </dev/null
}

# Admin agent caller — identity-trusted via #1122 (BRIDGE_AGENT_ID == admin),
# NO forged BRIDGE_CALLER_SOURCE claim. This is the legit #1879 path
# (assertion 3).
BA_ADMIN() {
  env -u BRIDGE_CALLER_SOURCE \
    BRIDGE_AGENT_ID="$ADMIN_AGENT" BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
    bash "$SMOKE_REPO_ROOT/bridge-agent.sh" "$@" </dev/null
}

reset_runtime() {
  rm -rf "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_AGENT_ROOT_V2"
  mkdir -p "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_AGENT_ROOT_V2"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  : >"$BRIDGE_AUDIT_LOG"
}

# Persist the admin scalar into the roster local file exactly like
# `setup admin` does (bridge_setup_write_local_scalar). On every CLI
# invocation bridge_load_roster unsets the inherited BRIDGE_ADMIN_AGENT_ID
# (bridge-core.sh bridge_reset_roster_maps) and re-derives it by sourcing the
# roster — so the admin-identity trust path (#1122) depends on this line being
# present, NOT on the caller's inherited env. This is the non-forgeable signal
# the r3 fix relies on. python3 -c argv form (footgun #11).
configure_admin() {
  local admin="$1"
  python3 -c '
import re, sys
path, key, value = sys.argv[1], "BRIDGE_ADMIN_AGENT_ID", sys.argv[2]
line = f"{key}=\"{value}\""
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = "#!/usr/bin/env bash\n"
pat = re.compile(rf"(?m)^[ \t]*{re.escape(key)}=.*$")
if pat.search(text):
    text = pat.sub(line, text, count=1)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += line + "\n"
open(path, "w", encoding="utf-8").write(text)
' "$BRIDGE_ROSTER_LOCAL_FILE" "$admin"
}

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

# Seed the isolated runtime: create the victim agent (operator-tui trusted) and
# persist the admin scalar so the #1122 identity path resolves `patch` as admin.
# Order matters: the admin scalar is appended AFTER create so the create's
# roster surgery does not clobber it.
create_victim() {
  BA_OPERATOR create victim --engine claude >/dev/null 2>&1
  configure_admin "$ADMIN_AGENT"
}

# Run an attacker spelling under a NON-admin agent context and assert it is
# denied with NO write. The attacker carries BRIDGE_AGENT_ID=attacker (!=
# admin) and forges BRIDGE_CALLER_SOURCE=operator-tui; the spelling is passed
# as a single `bash -c` payload so the env claim and BRIDGE_AGENT_ID follow the
# process into the nested shell. We capture the roster sha around the attempt
# and assert byte-identity + no model line + no mutation audit row.
assert_attacker_denied() {
  local label="$1"
  local payload="$2"
  local before_sha after_sha rc out
  before_sha="$(roster_sha)"

  set +e
  out="$(
    env BRIDGE_AGENT_ID="attacker" BRIDGE_ADMIN_AGENT_ID="$ADMIN_AGENT" \
      BRIDGE_CALLER_SOURCE="operator-tui" \
      bash -c "$payload" </dev/null 2>&1
  )"
  rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    smoke_fail "$label: expected non-zero exit (attacker write must be denied); rc=0 out=$out"
  fi
  after_sha="$(roster_sha)"
  smoke_assert_eq "$before_sha" "$after_sha" "$label: roster BYTE-IDENTICAL after attacker deny"
  smoke_assert_eq "" "$(roster_field victim BRIDGE_AGENT_MODEL)" "$label: no model written for attacker"
}

# ---------------------------------------------------------------------------
# (1) ★the exact bash -c bypass from a non-admin agent context -> DENY
# ---------------------------------------------------------------------------
test_bashc_bypass_denied() {
  reset_runtime
  create_victim

  # The verbatim bypass from the brief: hide the roster-writing verb inside a
  # `bash -c '...'` string while the forged BRIDGE_CALLER_SOURCE=operator-tui +
  # BRIDGE_AGENT_ID=attacker ride along to the child.
  assert_attacker_denied "bash -c bypass" \
    "bash '$SMOKE_REPO_ROOT/bridge-agent.sh' set-model victim claude-opus-4-8"

  smoke_assert_eq "0" "$(audit_mutation_rows_for 'model=claude-opus-4-8')" \
    "bash -c bypass: no mutation audit row for attacker write"
}

# ---------------------------------------------------------------------------
# (2) every r2 argv spelling from the same non-admin context -> still DENY
# ---------------------------------------------------------------------------
test_argv_spellings_denied() {
  reset_runtime
  create_victim

  # Direct env-prefix on bridge-agent.sh (no nested bash -c).
  assert_attacker_denied "env-prefix direct" \
    "bash '$SMOKE_REPO_ROOT/bridge-agent.sh' set-model victim claude-opus-4-8"

  # `env VAR=...` form re-asserting the claim inside the nested shell.
  assert_attacker_denied "env VAR= form" \
    "env BRIDGE_CALLER_SOURCE=operator-tui bash '$SMOKE_REPO_ROOT/bridge-agent.sh' set-model victim claude-opus-4-8"

  # Separator-chained spelling.
  assert_attacker_denied "separator-chained" \
    "true && bash '$SMOKE_REPO_ROOT/bridge-agent.sh' set-model victim claude-opus-4-8"

  # set-effort dimension, same close.
  assert_attacker_denied "set-effort dimension" \
    "bash '$SMOKE_REPO_ROOT/bridge-agent.sh' set-effort victim xhigh"

  smoke_assert_eq "0" "$(audit_mutation_rows_for 'model=')" \
    "argv spellings: no model mutation audit row"
  smoke_assert_eq "0" "$(audit_mutation_rows_for 'effort=')" \
    "argv spellings: no effort mutation audit row"
}

# ---------------------------------------------------------------------------
# (3) admin agent (identity path) -> set-model WRITES (legit #1879 target)
# ---------------------------------------------------------------------------
test_admin_identity_writes() {
  reset_runtime
  create_victim

  local out
  out="$(BA_ADMIN set-model victim claude-opus-4-8 2>&1)"
  smoke_assert_contains "$out" "materialize: ok" "admin identity: set-model writes (no env claim, #1122 path)"
  smoke_assert_eq "claude-opus-4-8" "$(roster_field victim BRIDGE_AGENT_MODEL)" \
    "admin identity: model landed in roster"
  smoke_assert_eq "1" "$(audit_mutation_rows_for 'model=claude-opus-4-8')" \
    "admin identity: mutation audit row recorded"
}

# ---------------------------------------------------------------------------
# (4) operator-tui (no BRIDGE_AGENT_ID) -> set-model WRITES (legit human path)
# ---------------------------------------------------------------------------
test_operator_tui_writes() {
  reset_runtime
  create_victim

  local out
  out="$(BA_OPERATOR set-model victim claude-sonnet-4-5 2>&1)"
  smoke_assert_contains "$out" "materialize: ok" "operator-tui: set-model writes (explicit claim, no agent id)"
  smoke_assert_eq "claude-sonnet-4-5" "$(roster_field victim BRIDGE_AGENT_MODEL)" \
    "operator-tui: model landed in roster"
}

main() {
  smoke_setup_bridge_home "$SMOKE_NAME"
  # CI runners ship no engine npm package; seed executable engine stubs (the
  # agent-doctor #1397 / 1427-A pattern) so `agent create --engine claude`'s
  # `command -v claude` pre-flight passes.
  _stub_engine_dir="$SMOKE_TMP_ROOT/stub-engine-bin"
  mkdir -p "$_stub_engine_dir"
  for _eng in claude codex; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$_stub_engine_dir/$_eng"
    chmod +x "$_stub_engine_dir/$_eng"
  done
  export PATH="$_stub_engine_dir:$PATH"

  smoke_run "bash -c bypass from non-admin agent -> DENY + byte-identical (1)" test_bashc_bypass_denied
  smoke_run "all r2 argv spellings -> DENY + byte-identical (2)"               test_argv_spellings_denied
  smoke_run "admin agent identity path -> WRITES (3)"                          test_admin_identity_writes
  smoke_run "operator-tui (no agent id) -> WRITES (4)"                         test_operator_tui_writes
  smoke_log "passed"
}

main "$@"
