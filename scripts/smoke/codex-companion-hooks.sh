#!/usr/bin/env bash
# scripts/smoke/codex-companion-hooks.sh — Codex companion-role hooks smoke.
#
# Validates:
# 1. bridge-queue.py validate-companion-body
#    (skip / ok / missing for [plan]/[review] briefs).
# 2. bridge-task.sh create gate: rejects weak codex briefs and accepts
#    when --skip-companion-validate is provided. (Pure shell-layer assertion;
#    avoids spawning a daemon.)
# 3. ensure-codex-hooks installs PreToolUse + Stop output-shape entries
#    alongside the existing SessionStart/Stop/UserPromptSubmit set, and
#    re-running is idempotent.
# 4. status-codex-hooks reports both companion hooks present.
# 5. codex-task-mode-policy.py PreToolUse:
#      - audit-mode allows + writes audit row
#      - block-mode emits decision=block on write outside /tmp/
#      - /tmp/ carve-out remains allowed in block-mode
#      - explicit `implement-permission:` grant in body allowed in block-mode
#      - non-companion title (no [plan]/[review]) → no policy
# 6. codex-review-output-shape.py Stop:
#      - audit-mode allows + writes audit row when missing prefix
#      - block-mode emits decision=block when missing prefix
#      - response starting with `plan-ok` → allowed
#
# This smoke does NOT exercise live Codex CLI delivery — those entries land
# in `~/.codex/hooks.json` only when a real Codex agent is started. The
# integration is covered by smoke #5/#6 by invoking the hook scripts
# directly with a seeded queue DB and synthesized event JSON.

set -euo pipefail

SMOKE_NAME="codex-companion-hooks"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
smoke_require_cmd python3
smoke_require_cmd sqlite3

REPO_ROOT="$SMOKE_REPO_ROOT"
PYTHON_BIN="$(command -v python3)"
HOOKS_DIR="$REPO_ROOT/hooks"

# ---------------------------------------------------------------------------
# Test 1 — bridge-queue.py validate-companion-body
# ---------------------------------------------------------------------------

smoke_log "1. validate-companion-body subcommand"

# 1a. non-companion title → skip
out_json="$(python3 "$REPO_ROOT/bridge-queue.py" validate-companion-body \
  --title "[bug] foo" --body "anything" --format json 2>/dev/null)" || smoke_fail "1a: subcommand failed"
smoke_assert_contains "$out_json" '"status": "skip"' "1a non-companion title"

# 1b. companion title with valid body → ok
valid_body='## Focus checklist
- review the diff

Expected output: plan-ok / needs-more.'
out_json="$(python3 "$REPO_ROOT/bridge-queue.py" validate-companion-body \
  --title "[plan] foo" --body "$valid_body" --format json 2>/dev/null)"
smoke_assert_contains "$out_json" '"status": "ok"' "1b ok"

# 1c. companion title with weak body → missing both
rc=0
out_json="$(python3 "$REPO_ROOT/bridge-queue.py" validate-companion-body \
  --title "[review] x" --body "do this" --format json 2>/dev/null)" || rc=$?
smoke_assert_eq "2" "$rc" "1c rc=2"
smoke_assert_contains "$out_json" '"status": "missing"' "1c missing status"
smoke_assert_contains "$out_json" "focus checklist" "1c missing focus"
smoke_assert_contains "$out_json" "expected output shape" "1c missing output"

# 1d. [review r2] also matches companion prefix
rc=0
python3 "$REPO_ROOT/bridge-queue.py" validate-companion-body \
  --title "[review r2] x" --body "do this" --format json >/dev/null 2>&1 || rc=$?
smoke_assert_eq "2" "$rc" "1d [review r2] rc=2"

# ---------------------------------------------------------------------------
# Test 2 — bridge-task.sh shell-layer create gate
# ---------------------------------------------------------------------------
# Exercises the cmd_create gate in bridge-task.sh end-to-end with a tiny
# isolated roster: a [plan] task to a codex recipient with a weak body must
# die; with --skip-companion-validate must succeed; with the env bypass must
# succeed; a non-codex recipient must skip the gate entirely; a non-companion
# title must skip the gate.

smoke_log "2. bridge-task.sh cmd_create gate"

# Roster fixture: one codex agent + one claude agent. Use existing
# scripts/smoke/lib.sh `BRIDGE_ROSTER_FILE` we set up. The roster file is
# sourced by `ensure_roster_loaded`; we need
# `bridge_add_agent_id_if_missing` to register and the BRIDGE_AGENT_ENGINE
# associative array to declare engine.
cat >"$BRIDGE_ROSTER_FILE" <<'ROSTER'
#!/usr/bin/env bash
declare -gA BRIDGE_AGENT_ENGINE BRIDGE_AGENT_DESC BRIDGE_AGENT_SESSION BRIDGE_AGENT_WORKDIR
bridge_add_agent_id_if_missing() {
  local id="$1"
  local found="0"
  local existing
  for existing in "${BRIDGE_AGENT_IDS[@]:-}"; do
    if [[ "$existing" == "$id" ]]; then
      found="1"
      break
    fi
  done
  if [[ "$found" == "0" ]]; then
    BRIDGE_AGENT_IDS+=("$id")
  fi
}
bridge_add_agent_id_if_missing codex-recipient
bridge_add_agent_id_if_missing claude-recipient
BRIDGE_AGENT_ENGINE[codex-recipient]="codex"
BRIDGE_AGENT_ENGINE[claude-recipient]="claude"
BRIDGE_AGENT_DESC[codex-recipient]="Codex companion-role smoke recipient"
BRIDGE_AGENT_DESC[claude-recipient]="Claude smoke recipient"
BRIDGE_AGENT_SESSION[codex-recipient]="codex-recipient"
BRIDGE_AGENT_SESSION[claude-recipient]="claude-recipient"
BRIDGE_AGENT_WORKDIR[codex-recipient]="$BRIDGE_HOME"
BRIDGE_AGENT_WORKDIR[claude-recipient]="$BRIDGE_HOME"
ROSTER

# Initialize tasks DB (cmd_create writes through bridge-queue.py).
python3 "$REPO_ROOT/bridge-queue.py" init >/dev/null 2>&1 \
  || smoke_fail "2: queue init failed"

create_task() {
  local title="$1" body="$2" recipient="${3:-codex-recipient}" extra_arg="${4:-}"
  local cmd=(bash "$REPO_ROOT/bridge-task.sh" create
    --to "$recipient"
    --title "$title"
    --body "$body"
    --from "smoke-actor")
  if [[ -n "$extra_arg" ]]; then
    cmd+=("$extra_arg")
  fi
  "${cmd[@]}" 2>&1
}

# 2a. Weak body → die (rc != 0).
weak_body="just do this please"
rc=0
out_2a="$(create_task "[plan] foo" "$weak_body" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || smoke_fail "2a: expected weak [plan] body to be rejected, got rc=0"
smoke_assert_contains "$out_2a" "task body validation failed" "2a structured rejection"

# 2b. Full body → accept.
full_body=$'## Focus checklist\n- review the diff\n\nExpected output: plan-ok / needs-more.'
rc=0
out_2b="$(create_task "[plan] bar" "$full_body" 2>&1)" || rc=$?
smoke_assert_eq "0" "$rc" "2b full body accepted"

# 2c. Weak body + --skip-companion-validate → accept.
rc=0
out_2c="$(create_task "[plan] baz" "$weak_body" codex-recipient "--skip-companion-validate" 2>&1)" || rc=$?
smoke_assert_eq "0" "$rc" "2c --skip-companion-validate bypass"

# 2d. Weak body + BRIDGE_TASK_SKIP_COMPANION_VALIDATE=1 → accept.
rc=0
out_2d="$(BRIDGE_TASK_SKIP_COMPANION_VALIDATE=1 create_task "[plan] env-bypass" "$weak_body" 2>&1)" || rc=$?
smoke_assert_eq "0" "$rc" "2d env bypass"

# 2e. Weak body + non-codex recipient → accept (no validate).
rc=0
out_2e="$(create_task "[plan] claude-target" "$weak_body" claude-recipient 2>&1)" || rc=$?
smoke_assert_eq "0" "$rc" "2e non-codex recipient skips gate"

# 2f. Non-companion title (no [plan]/[review]) on codex recipient → accept.
rc=0
out_2f="$(create_task "[bug] codex-target" "$weak_body" codex-recipient 2>&1)" || rc=$?
smoke_assert_eq "0" "$rc" "2f non-companion title skips gate"

# 2g. (D4 r2) Piped stdin must NOT be consumed by the validator. A bypass
# attempt — `echo "[plan] valid body" | agb task create --to <codex>
# --title '[plan] foo'` (no --body / --body-file) — used to pass validation
# (validator read stdin) while the queue stored an empty body. Post-fix the
# validator is invoked with explicit `--body ""` and `</dev/null`, so the
# stored body and the validated body are the same empty string and rc=2.
rc=0
stdin_bypass_out="$(printf '%s' "[plan] valid body" | bash "$REPO_ROOT/bridge-task.sh" create \
  --to codex-recipient \
  --title '[plan] stdin-bypass' \
  --from smoke-actor 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || smoke_fail "2g: expected stdin-piped body to be rejected, got rc=0 / out=${stdin_bypass_out}"
smoke_assert_contains "$stdin_bypass_out" "task body validation failed" "2g stdin not consumed"

# ---------------------------------------------------------------------------
# Test 3 — ensure-codex-hooks adds companion hooks + idempotent
# ---------------------------------------------------------------------------

smoke_log "3. ensure-codex-hooks adds companion hooks"

CODEX_HOOKS_FILE="$SMOKE_TMP_ROOT/codex-hooks.json"
python3 "$REPO_ROOT/bridge-hooks.py" ensure-codex-hooks \
  --bridge-home "$REPO_ROOT" --python-bin "$PYTHON_BIN" \
  --codex-hooks-file "$CODEX_HOOKS_FILE" --format text >/dev/null 2>&1 \
  || smoke_fail "3: ensure-codex-hooks first run failed"

smoke_assert_file_exists "$CODEX_HOOKS_FILE" "3 codex-hooks.json created"

# Verify all 5 hook commands are present.
hooks_content="$(cat "$CODEX_HOOKS_FILE")"
smoke_assert_contains "$hooks_content" "session-start.py" "3 SessionStart wired"
smoke_assert_contains "$hooks_content" "check-inbox.py" "3 Stop inbox wired"
smoke_assert_contains "$hooks_content" "prompt_timestamp.py" "3 prompt timestamp wired"
smoke_assert_contains "$hooks_content" "codex-task-mode-policy.py" "3 PreToolUse companion wired"
smoke_assert_contains "$hooks_content" "codex-review-output-shape.py" "3 Stop output-shape wired"

# Idempotent — second run reports unchanged.
out2="$(python3 "$REPO_ROOT/bridge-hooks.py" ensure-codex-hooks \
  --bridge-home "$REPO_ROOT" --python-bin "$PYTHON_BIN" \
  --codex-hooks-file "$CODEX_HOOKS_FILE" --format shell 2>&1)"
smoke_assert_contains "$out2" "CODEX_HOOK_STATUS=unchanged" "3 idempotent second run"

# ---------------------------------------------------------------------------
# Test 4 — status-codex-hooks reports companion hooks
# ---------------------------------------------------------------------------

smoke_log "4. status-codex-hooks reports companion hooks"

status_out="$(python3 "$REPO_ROOT/bridge-hooks.py" status-codex-hooks \
  --codex-hooks-file "$CODEX_HOOKS_FILE" --format shell 2>&1)"
smoke_assert_contains "$status_out" "CODEX_TASK_MODE_POLICY_HOOK=present" "4 task-mode-policy present"
smoke_assert_contains "$status_out" "CODEX_REVIEW_OUTPUT_SHAPE_HOOK=present" "4 output-shape present"
smoke_assert_contains "$status_out" "CODEX_COMPANION_HOOKS_STATUS=present" "4 companion status"

# ---------------------------------------------------------------------------
# Test 5 — codex-task-mode-policy.py
# ---------------------------------------------------------------------------

smoke_log "5. codex-task-mode-policy.py"

# Seed isolated tasks DB with a [plan] claimed task.
python3 "$REPO_ROOT/bridge-queue.py" init >/dev/null 2>&1 \
  || smoke_fail "5: queue init failed"

# Insert a body file.
BODY_FILE="$SMOKE_TMP_ROOT/plan-body.md"
cat >"$BODY_FILE" <<'EOF'
## Focus checklist
- read the diff

Expected: plan-ok or needs-more.

implement-permission: /tmp/grant-target
EOF

# Create + claim the task as a [plan] for an agent.
TEST_AGENT="codex-tester-smoke"
python3 - <<PY
import sqlite3, time
db = "$BRIDGE_TASK_DB"
agent = "$TEST_AGENT"
body_path = "$BODY_FILE"
ts = int(time.time())
with sqlite3.connect(db) as conn:
    conn.execute(
        "INSERT INTO tasks (assigned_to, created_by, status, priority, title, body_path, created_ts, updated_ts, claimed_by, claimed_ts) "
        "VALUES (?, 'smoke', 'claimed', 'normal', '[plan] companion-hook smoke fixture', ?, ?, ?, ?, ?)",
        (agent, body_path, ts, ts, agent, ts),
    )
    conn.commit()
PY

run_hook() {
  local hook_path="$1" event_json="$2" mode_env_name="$3" mode_value="$4"
  printf '%s' "$event_json" | env \
    BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
    BRIDGE_AGENT_ID="$TEST_AGENT" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
    BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
    "$mode_env_name=$mode_value" \
    python3 "$hook_path"
}

# 5a. audit mode (default) allows write outside /tmp + writes audit row.
event_write_outside='{"tool_name":"Edit","tool_input":{"file_path":"/Users/somewhere/foo.py"}}'
audit_log="$BRIDGE_AUDIT_LOG"
mkdir -p "$(dirname "$audit_log")"
: >"$audit_log"
out_audit="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_write_outside" \
  BRIDGE_CODEX_TASK_MODE_POLICY audit)"
smoke_assert_eq "" "$out_audit" "5a audit-mode emits no decision"
smoke_assert_file_exists "$audit_log" "5a audit log present"
smoke_assert_contains "$(cat "$audit_log")" "codex_task_mode_policy.deny" "5a audit row"

# 5b. block mode emits decision=block on write outside /tmp.
out_block="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_write_outside" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_block" '"decision": "block"' "5b block decision"
smoke_assert_contains "$out_block" "[plan]" "5b reason mentions task title"

# 5c. /tmp/ carve-out — block mode allows.
event_tmp='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/scratch.txt"}}'
out_tmp="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_tmp" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_eq "" "$out_tmp" "5c /tmp carve-out (no block)"

# 5d. explicit implement-permission grant — block mode allows.
event_grant='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/grant-target/foo.py"}}'
out_grant="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_grant" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_eq "" "$out_grant" "5d explicit grant (no block)"

# 5d2. inline-body grant (body_text, not body_path). Insert an inline-body
# task whose grant points to a non-/tmp path so the /tmp carve-out cannot
# accidentally pass this case. With body_text honored the write must be
# allowed; without body_text the write would otherwise block.
INLINE_AGENT="codex-inline-body-smoke"
INLINE_GRANT_DIR="$BRIDGE_HOME/inline-grant-target"
python3 - <<PY
import sqlite3, time
db = "$BRIDGE_TASK_DB"
agent = "$INLINE_AGENT"
inline_body = """## Focus checklist
- inline body smoke

implement-permission: $INLINE_GRANT_DIR
"""
ts = int(time.time())
with sqlite3.connect(db) as conn:
    conn.execute(
        "INSERT INTO tasks (assigned_to, created_by, status, priority, title, body_text, body_path, created_ts, updated_ts, claimed_by, claimed_ts) "
        "VALUES (?, 'smoke', 'claimed', 'normal', '[plan] inline body grant', ?, NULL, ?, ?, ?, ?)",
        (agent, inline_body, ts, ts, agent, ts),
    )
    conn.commit()
PY
event_inline_grant='{"tool_name":"Edit","tool_input":{"file_path":"'"$INLINE_GRANT_DIR"'/foo.py"}}'
out_inline="$(printf '%s' "$event_inline_grant" | env \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_ID="$INLINE_AGENT" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
  BRIDGE_CODEX_TASK_MODE_POLICY=block \
  python3 "$HOOKS_DIR/codex-task-mode-policy.py")"
smoke_assert_eq "" "$out_inline" "5d2 inline-body grant non-/tmp (no block)"

# 5d3. same inline-body task but write target outside the granted path —
# must block, confirming the grant parser actually scoped to the grant.
event_inline_outside='{"tool_name":"Edit","tool_input":{"file_path":"/Users/somewhere/elsewhere/foo.py"}}'
out_inline_outside="$(printf '%s' "$event_inline_outside" | env \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_ID="$INLINE_AGENT" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
  BRIDGE_CODEX_TASK_MODE_POLICY=block \
  python3 "$HOOKS_DIR/codex-task-mode-policy.py")"
smoke_assert_contains "$out_inline_outside" '"decision": "block"' "5d3 inline-body grant scoped (outside blocks)"

# 5f. cp /tmp/src /repo/dst — destination is /repo/dst, must block.
event_cp_to_repo='{"tool_name":"Bash","tool_input":{"command":"cp /tmp/source.txt /Users/somewhere/repo/file.txt"}}'
out_cp="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_cp_to_repo" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_cp" '"decision": "block"' "5f cp /tmp -> repo blocks"

# 5g. cp /tmp/src /tmp/dst — both /tmp, must allow.
event_cp_tmp='{"tool_name":"Bash","tool_input":{"command":"cp /tmp/source.txt /tmp/dest.txt"}}'
out_cp_tmp="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_cp_tmp" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_eq "" "$out_cp_tmp" "5g cp /tmp -> /tmp allows"

# 5h. mv source -> repo dest, must block.
event_mv_to_repo='{"tool_name":"Bash","tool_input":{"command":"mv /tmp/source.txt /Users/somewhere/repo/file.txt"}}'
out_mv="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_mv_to_repo" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_mv" '"decision": "block"' "5h mv /tmp -> repo blocks"

# 5i. dd if=/tmp/src of=/repo/dst — dd of= is destination, must block.
event_dd='{"tool_name":"Bash","tool_input":{"command":"dd if=/tmp/source.txt of=/Users/somewhere/repo/file.txt"}}'
out_dd="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_dd" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_dd" '"decision": "block"' "5i dd of=repo blocks"

# 5k. git read-only subcommands — block mode must allow. A [review] task
# cannot work if `git diff`, `git status`, `git show`, `git log`,
# `git grep`, `git ls-files`, `git rev-parse` are blocked.
for sub in "diff -- bridge-hooks.py" "status" "show HEAD" "log -1" \
           "grep -n FOO" "ls-files" "rev-parse HEAD"; do
    event_git_ro="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git $sub\"}}"
    out_git_ro="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_git_ro" \
      BRIDGE_CODEX_TASK_MODE_POLICY block)"
    smoke_assert_eq "" "$out_git_ro" "5k git $sub allowed in block mode"
done

# 5l. git mutating subcommands — block mode must block. These mutate the
# worktree, index, refs, or remote, which is exactly what [plan]/[review]
# read-only contract forbids.
for sub in "checkout -- bridge-hooks.py" "switch main" "restore foo" \
           "reset --hard" "clean -fd" "add foo" "commit -m x" \
           "merge feature" "rebase main" "cherry-pick HEAD" "stash" \
           "apply patch.diff" "revert HEAD" "tag v1" "branch -D foo" \
           "push origin"; do
    event_git_w="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git $sub\"}}"
    out_git_w="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_git_w" \
      BRIDGE_CODEX_TASK_MODE_POLICY block)"
    smoke_assert_contains "$out_git_w" '"decision": "block"' "5l git $sub blocks in block mode"
done

# 5m. git with -C/-c flags before subcommand — must still classify the
# subcommand correctly (skip flag values).
event_git_c_ro='{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo -c color.ui=never status"}}'
out_git_c_ro="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_git_c_ro" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_eq "" "$out_git_c_ro" "5m git -C ... status allowed"

event_git_c_w='{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo checkout main"}}'
out_git_c_w="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_git_c_w" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_git_c_w" '"decision": "block"' "5m git -C ... checkout blocks"

# 5n. (D1 r2) Explicit fd redirections must be classified as writes.
# Pre-fix `_REDIR_RE` only matched plain `>`/`>>`/`&>`/`>&`, so
# `echo X 1>/repo/file` and `echo X 2>/repo/file` slipped through and
# reached the queue. Post-fix the regex catches `<digit>>` / `<digit>>>`.
event_fd1='{"tool_name":"Bash","tool_input":{"command":"echo hostile 1>/Users/somewhere/repo/file"}}'
out_fd1="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_fd1" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_fd1" '"decision": "block"' "5n stdout fd redirection (1>) blocks"

event_fd2='{"tool_name":"Bash","tool_input":{"command":"echo hostile 2>/Users/somewhere/repo/file"}}'
out_fd2="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_fd2" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_fd2" '"decision": "block"' "5n stderr fd redirection (2>) blocks"

# 5o. (D1 r2) Long-flag bypass: `git --no-pager checkout main`. Pre-fix
# `--no-pager` was treated as value-taking (next-token consumed), so
# `checkout` was hidden and the call reached "no write subcommand → allow".
# Post-fix the closed allowlist of value-taking long flags excludes
# `--no-pager`, so `checkout` is correctly classified as a mutation.
event_long='{"tool_name":"Bash","tool_input":{"command":"git --no-pager checkout main"}}'
out_long="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_long" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_long" '"decision": "block"' "5o git --no-pager checkout blocks"

# 5p. (D1 r2) Allowlisted value-taking long flags continue to consume
# their value: `git --git-dir=... status` (joined form) and
# `git --git-dir <path> status` (separated form) must both classify
# `status` as the subcommand and remain allowed.
event_gitdir_eq='{"tool_name":"Bash","tool_input":{"command":"git --git-dir=/tmp/repo status"}}'
out_gitdir_eq="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_gitdir_eq" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_eq "" "$out_gitdir_eq" "5p git --git-dir=... status allowed"

event_gitdir_sep='{"tool_name":"Bash","tool_input":{"command":"git --git-dir /tmp/repo status"}}'
out_gitdir_sep="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_gitdir_sep" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_eq "" "$out_gitdir_sep" "5p git --git-dir <path> status allowed"

# 5q. (D1 r3) `patch -p1 -i /tmp/fix.patch`: pre-fix the classifier treated
# `/tmp/fix.patch` as the write target (since `patch` was in the first-arg
# heads set), letting the global /tmp carve-out allow it. But `patch` reads
# the diff from `-i FILE` and writes to files named INSIDE the diff,
# typically into cwd. Post-fix the target is cwd → blocks.
event_patch_in='{"tool_name":"Bash","tool_input":{"command":"patch -p1 -i /tmp/fix.patch"}}'
out_patch_in="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_patch_in" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_patch_in" '"decision": "block"' "5q patch -i /tmp/diff blocks (target is cwd)"

# 5r. (D1 r3) `patch -p1 -i /tmp/diff -o /tmp/out`: `-o <output>` redirects
# the patched result to a single named file. With the output in /tmp the
# carve-out applies and the call is allowed.
event_patch_out='{"tool_name":"Bash","tool_input":{"command":"patch -p1 -i /tmp/diff -o /tmp/out"}}'
out_patch_out="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_patch_out" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_eq "" "$out_patch_out" "5r patch -o /tmp/out allowed (output in /tmp)"

# 5s. (D1 r3) `install -t /etc/systemd /tmp/foo.service`: `-t <dest>` puts
# the destination directory in the FLAG VALUE, not the last positional. Pre-
# fix the classifier walked positionals from the right and returned
# `/tmp/foo.service` (a source) as the write target → false-allowed by /tmp
# carve-out. Post-fix `-t` is consumed and the destination /etc/systemd is
# classified as the target → blocks.
event_install_t_repo='{"tool_name":"Bash","tool_input":{"command":"install -t /etc/systemd /tmp/foo.service"}}'
out_install_t_repo="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_install_t_repo" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_install_t_repo" '"decision": "block"' "5s install -t /etc/... blocks"

# 5t. (D1 r3) `install -t /tmp/dest /etc/foo`: `-t /tmp/dest` is the write
# target. Source comes from /etc but the destination /tmp/dest is in the
# carve-out, so the call is allowed.
event_install_t_tmp='{"tool_name":"Bash","tool_input":{"command":"install -t /tmp/dest /etc/foo"}}'
out_install_t_tmp="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_install_t_tmp" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_eq "" "$out_install_t_tmp" "5t install -t /tmp/dest allowed"

# 5u. (D1 r3) Mirror for cp / mv: `cp -t /etc /tmp/foo` and
# `mv --target-directory=/etc /tmp/foo` must classify the destination
# directory as the write target.
event_cp_t='{"tool_name":"Bash","tool_input":{"command":"cp -t /etc /tmp/foo"}}'
out_cp_t="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_cp_t" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_cp_t" '"decision": "block"' "5u cp -t /etc blocks"

event_mv_long='{"tool_name":"Bash","tool_input":{"command":"mv --target-directory=/etc /tmp/foo"}}'
out_mv_long="$(run_hook "$HOOKS_DIR/codex-task-mode-policy.py" "$event_mv_long" \
  BRIDGE_CODEX_TASK_MODE_POLICY block)"
smoke_assert_contains "$out_mv_long" '"decision": "block"' "5u mv --target-directory=/etc blocks"

# 5j. ambiguous claimed task — fail-open with audit row.
AMBIG_AGENT="codex-ambig-smoke"
python3 - <<PY
import sqlite3, time
db = "$BRIDGE_TASK_DB"
agent = "$AMBIG_AGENT"
ts = int(time.time())
with sqlite3.connect(db) as conn:
    for offset in (0, 1):
        conn.execute(
            "INSERT INTO tasks (assigned_to, created_by, status, priority, title, body_text, body_path, created_ts, updated_ts, claimed_by, claimed_ts) "
            "VALUES (?, 'smoke', 'claimed', 'normal', ?, NULL, NULL, ?, ?, ?, ?)",
            (agent, f"[plan] ambig-{offset}", ts + offset, ts + offset, agent, ts + offset),
        )
    conn.commit()
PY
: >"$audit_log"
event_ambig='{"tool_name":"Edit","tool_input":{"file_path":"/Users/somewhere/foo.py"}}'
out_ambig="$(printf '%s' "$event_ambig" | env \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_ID="$AMBIG_AGENT" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
  BRIDGE_CODEX_TASK_MODE_POLICY=block \
  python3 "$HOOKS_DIR/codex-task-mode-policy.py")"
smoke_assert_eq "" "$out_ambig" "5j ambiguous task (no block)"
smoke_assert_contains "$(cat "$audit_log")" "ambiguous_claimed_task" "5j ambig audit row"

# 5e. Non-companion title — no policy (allow even on raw write).
NONCOMP_AGENT="codex-noncompanion-smoke"
python3 - <<PY
import sqlite3, time
db = "$BRIDGE_TASK_DB"
agent = "$NONCOMP_AGENT"
ts = int(time.time())
with sqlite3.connect(db) as conn:
    conn.execute(
        "INSERT INTO tasks (assigned_to, created_by, status, priority, title, body_path, created_ts, updated_ts, claimed_by, claimed_ts) "
        "VALUES (?, 'smoke', 'claimed', 'normal', '[bug] some bug', NULL, ?, ?, ?, ?)",
        (agent, ts, ts, agent, ts),
    )
    conn.commit()
PY
out_noncomp="$(printf '%s' "$event_write_outside" | env \
  BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
  BRIDGE_AGENT_ID="$NONCOMP_AGENT" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
  BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
  BRIDGE_CODEX_TASK_MODE_POLICY=block \
  python3 "$HOOKS_DIR/codex-task-mode-policy.py")"
smoke_assert_eq "" "$out_noncomp" "5e non-companion title (no policy)"

# ---------------------------------------------------------------------------
# Test 6 — codex-review-output-shape.py
# ---------------------------------------------------------------------------

smoke_log "6. codex-review-output-shape.py"

# 6a. Missing prefix in audit mode — no decision, audit row written.
: >"$audit_log"
event_no_prefix='{"last_assistant_message":"looks fine to me, ship it"}'
out_a="$(run_hook "$HOOKS_DIR/codex-review-output-shape.py" "$event_no_prefix" \
  BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE audit)"
smoke_assert_eq "" "$out_a" "6a audit no decision"
smoke_assert_contains "$(cat "$audit_log")" "codex_review_output_shape.deny" "6a audit row"

# 6b. Missing prefix in block mode — decision=block + correction prompt.
out_b="$(run_hook "$HOOKS_DIR/codex-review-output-shape.py" "$event_no_prefix" \
  BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE block)"
smoke_assert_contains "$out_b" '"decision": "block"' "6b block decision"
smoke_assert_contains "$out_b" "plan-ok" "6b correction prompt mentions prefix"
smoke_assert_contains "$out_b" "looks fine" "6b response tail preserved"

# 6c. Valid prefix — allow.
event_ok='{"last_assistant_message":"plan-ok: change is correct"}'
out_c="$(run_hook "$HOOKS_DIR/codex-review-output-shape.py" "$event_ok" \
  BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE block)"
smoke_assert_eq "" "$out_c" "6c valid prefix (no block)"

# 6d. stop_hook_active=true — allow regardless of prefix or mode (recursion guard).
event_active='{"stop_hook_active":true,"last_assistant_message":"looks fine"}'
out_d="$(run_hook "$HOOKS_DIR/codex-review-output-shape.py" "$event_active" \
  BRIDGE_CODEX_OUTPUT_SHAPE_ENFORCE block)"
smoke_assert_eq "" "$out_d" "6d stop_hook_active short-circuits to allow"

smoke_log "all checks passed"
