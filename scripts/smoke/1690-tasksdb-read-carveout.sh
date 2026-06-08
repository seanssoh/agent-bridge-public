#!/usr/bin/env bash
# scripts/smoke/1690-tasksdb-read-carveout.sh — KEEP-invariant gate for
# issue #1690 (queue tasks.db direct-READ over-block carve-out).
#
# Before #1690, both protected-path gates for state/tasks.db returned an
# UNCONDITIONAL deny — the one protected path that omitted the
# read_intent carve-out its sibling gates (roster, system-config) all
# have, and it fired BEFORE the admin exemption. A read of the DB *file*
# does not mutate the queue; the "use agb queue commands" rationale is a
# WRITE contract. The fix mirrors the roster gate shape in both
# protected_path_reason (non-Bash) and protected_alias_reason (Bash):
#   if path == task_db_path(): if read_intent: return None  (else deny)
#
# Two layers, matching scripts/smoke/tool-policy-roster-read-classify.sh:
#
#   Layer 1 (classifier unit) — 1690-tasksdb-read-carveout.py asserts the
#     read_intent classification that underpins the carve-out, including
#     the fail-closed teeth (redirect / sink / sqlite3-mutate / sqlite3
#     -readonly / unbalanced-quote all classify write-intent).
#
#   Layer 2 (REAL PreToolUse hook) — this script invokes hooks/tool-
#     policy.py as an actual PreToolUse hook (stdin JSON ->
#     permissionDecision) with BRIDGE_HOME set and a state/tasks.db
#     fixture present, and asserts the end-to-end allow/deny verdict for
#     BOTH Bash payloads AND non-Bash Read/Write payloads.
#
# KEEP-invariant (the 4-gate's core) — after the relaxation, the
# following must STILL be DENIED for every agent:
#   - any write tool targeting tasks.db (Write/Edit non-Bash path)
#   - cat foo > tasks.db / cat foo >> tasks.db (redirect into the DB)
#   - a read whose stdout is redirected to a file sink (cat $db > /tmp/x)
#   - sqlite3 against tasks.db (mutate AND -readonly SELECT — left denied,
#     fail-closed)
#   - an unbalanced/unparseable command (fail-closed on uncertainty)
#
# Revert teeth: a final phase re-runs the read-allow assertions against a
# reverted copy of the policy (the carve-out lines stripped) and asserts
# the read is DENIED there — proving the smoke genuinely exercises the new
# allow and would FAIL if the carve-out were reverted.
#
# Footgun #11: the JSON stdin payload is built with `printf` (never an
# interpreter here-string / heredoc-stdin) and piped into the hook with
# `< file`, matching scripts/smoke/tool-policy-roster-read-classify.sh.

set -euo pipefail

SMOKE_NAME="1690-tasksdb-read-carveout"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# The reverted-policy copy MUST live inside the real hooks/ dir so its
# sibling-import of `bridge_hook_common` and its `ROOT = __file__.parent.
# parent` guard-module lookup resolve exactly like the shipped policy
# (the policy resolves both relative to its own __file__). A temp-dir copy
# would ModuleNotFoundError. We use a unique name and remove it on EXIT.
REVERTED_POLICY=""
cleanup() {
  [[ -n "$REVERTED_POLICY" && -f "$REVERTED_POLICY" ]] && rm -f "$REVERTED_POLICY"
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

# --- Layer 1: classifier unit assertions ------------------------------------

echo "[smoke:${SMOKE_NAME}] layer 1 — read_intent classifier + sqlite3 teeth"
"$PYTHON_BIN" "$SCRIPT_DIR/1690-tasksdb-read-carveout.py"

# --- Layer 2: real PreToolUse hook end-to-end -------------------------------

smoke_setup_bridge_home "$SMOKE_NAME"

# task_db_path() == bridge_home_dir()/state/tasks.db. Materialize a fixture
# so the read targets a real file (the gate compares paths, not contents).
TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
printf '%s' 'SQLite format 3' >"$TASK_DB"

# Admin agent — the #1690 scenario was admin `patch` reading the DB. The
# carve-out is read-intent for EVERY agent (no admin bypass), but using an
# admin agent also proves the read no longer fires before the (admin)
# exemption line. is_admin_agent() honors SESSION-TYPE.md == admin.
AGENT="patch-1690"
AGENT_HOME="$BRIDGE_AGENT_HOME_ROOT/$AGENT"
mkdir -p "$AGENT_HOME"
printf -- '- session type: admin\n' >"$AGENT_HOME/SESSION-TYPE.md"

# Issue #1690 r2 (codex Phase-4): sibling-gate ordering fixtures. A
# forbidden shared/secrets path and a peer-agent home, so a read-intent
# command that names BOTH tasks.db AND a forbidden path can be exercised
# end-to-end. The tasks.db read-intent carve-out must NOT short-circuit
# the later Stage A (shared/secrets) / Stage B (peer-home) deny gates.
SECRETS_FILE="$BRIDGE_SHARED_DIR/secrets/token.txt"
mkdir -p "$BRIDGE_SHARED_DIR/secrets" "$BRIDGE_SHARED_DIR/private"
printf '%s' 'secret-token' >"$SECRETS_FILE"
PRIVATE_FILE="$BRIDGE_SHARED_DIR/private/notes.md"
printf '%s' 'private' >"$PRIVATE_FILE"
# A peer agent home so _peer_alias_list("$AGENT") includes it; a read-
# intent command naming tasks.db + this peer home must stay denied.
PEER_AGENT="peer-1690"
PEER_HOME="$BRIDGE_AGENT_HOME_ROOT/$PEER_AGENT"
mkdir -p "$PEER_HOME"
printf -- '- session type: static\n' >"$PEER_HOME/SESSION-TYPE.md"

# JSON-escape a string for embedding in the payload.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Write a PreToolUse Bash payload. $1 target file, $2 command.
write_bash_payload() {
  local target="$1" command="$2" esc
  esc="$(json_escape "$command")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1690",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

# Write a PreToolUse non-Bash payload (Read/Glob/Write/Edit). $1 target
# file, $2 tool_name, $3 file_path.
write_path_payload() {
  local target="$1" tool="$2" fpath="$3" esc
  esc="$(json_escape "$fpath")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    "  \"tool_name\": \"${tool}\"," \
    "  \"tool_input\": {\"file_path\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1690",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

# $1 payload file, $2 optional policy path override.
run_pretool_hook() {
  local payload_file="$1"
  local policy="${2:-$SMOKE_REPO_ROOT/hooks/tool-policy.py}"
  BRIDGE_AGENT_ID="$AGENT" \
    "$PYTHON_BIN" "$policy" <"$payload_file"
}

verdict_of() {
  local out="$1"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then
    printf 'DENY'
  else
    printf 'ALLOW'
  fi
}

# Assert a Bash command's verdict. $1 label, $2 command, $3 ALLOW|DENY.
assert_bash_verdict() {
  local label="$1" command="$2" want="$3" payload out got
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM.json"
  write_bash_payload "$payload" "$command"
  out="$(run_pretool_hook "$payload")"
  got="$(verdict_of "$out")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      command: ${command}"
    smoke_log "      hook output: ${out:-<empty>}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

# Assert a non-Bash tool's verdict. $1 label, $2 tool, $3 path, $4 verdict.
assert_path_verdict() {
  local label="$1" tool="$2" fpath="$3" want="$4" payload out got
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM.json"
  write_path_payload "$payload" "$tool" "$fpath"
  out="$(run_pretool_hook "$payload")"
  got="$(verdict_of "$out")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      tool: ${tool} path: ${fpath}"
    smoke_log "      hook output: ${out:-<empty>}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

echo "[smoke:${SMOKE_NAME}] layer 2 — real PreToolUse hook end-to-end"

# ===== ALLOW: read-intent of the DB file =====
assert_bash_verdict "bash cat (read) of tasks.db"   "cat $TASK_DB"   "ALLOW"
assert_bash_verdict "bash ls -l (read) of tasks.db" "ls -l $TASK_DB" "ALLOW"
assert_bash_verdict "bash stat (read) of tasks.db"  "stat $TASK_DB"  "ALLOW"
assert_bash_verdict "bash file (read) of tasks.db"  "file $TASK_DB"  "ALLOW"
assert_path_verdict "non-bash Read of tasks.db"     "Read" "$TASK_DB" "ALLOW"

# ===== DENY (teeth): write tools target the DB =====
assert_path_verdict "non-bash Write to tasks.db" "Write"  "$TASK_DB" "DENY"
assert_path_verdict "non-bash Edit of tasks.db"  "Edit"   "$TASK_DB" "DENY"

# ===== DENY (teeth): output redirection into the DB =====
assert_bash_verdict "bash redirect-into (clobber) tasks.db" "cat /etc/hostname > $TASK_DB"  "DENY"
assert_bash_verdict "bash redirect-append tasks.db"         "echo x >> $TASK_DB"            "DENY"

# ===== DENY (teeth): read whose stdout is redirected to a file sink =====
assert_bash_verdict "bash read-of-db redirected to sink"     "cat $TASK_DB > /tmp/leak"   "DENY"
assert_bash_verdict "bash read-of-db numeric-fd sink"        "cat $TASK_DB 1>/tmp/leak"   "DENY"
assert_bash_verdict "bash read-of-db tee sink"               "cat $TASK_DB | tee /tmp/leak" "DENY"

# ===== DENY (teeth): sqlite3 stays denied (NOT unblocked, fail-closed) =====
assert_bash_verdict "bash sqlite3 UPDATE on tasks.db"        "sqlite3 $TASK_DB 'UPDATE tasks SET status=1'" "DENY"
assert_bash_verdict "bash sqlite3 DELETE on tasks.db"        "sqlite3 $TASK_DB 'DELETE FROM tasks'"         "DENY"
assert_bash_verdict "bash sqlite3 INSERT on tasks.db"        "sqlite3 $TASK_DB 'INSERT INTO tasks VALUES (1)'" "DENY"
assert_bash_verdict "bash sqlite3 .schema on tasks.db"       "sqlite3 $TASK_DB '.schema'"                   "DENY"
assert_bash_verdict "bash sqlite3 .dump redirected"          "sqlite3 $TASK_DB '.dump' > /tmp/dump.sql"     "DENY"
assert_bash_verdict "bash sqlite3 .backup on tasks.db"       "sqlite3 $TASK_DB '.backup /tmp/bk.db'"        "DENY"
assert_bash_verdict "bash sqlite3 -readonly SELECT on tasks.db" "sqlite3 -readonly $TASK_DB 'SELECT id FROM tasks'" "DENY"

# ===== DENY (teeth): awk in-program write/exec/pipe (issue #1690) =====
# awk is on the read-intent set but its program body can write/exfil with
# NO shell `>` token. Codex direction-review found `awk '{print>"…"}' $db`
# riding the carve-out. These MUST stay DENIED; a plain awk read ALLOWs.
assert_bash_verdict "bash awk in-program write to sink" "awk '{print>\"/tmp/leak\"}' $TASK_DB" "DENY"
assert_bash_verdict "bash awk in-program append to sink" "awk '{print >> \"/tmp/leak\"}' $TASK_DB" "DENY"
assert_bash_verdict "bash awk pipe to command"          "awk '{print | \"cmd\"}' $TASK_DB"   "DENY"
assert_bash_verdict "bash awk system() exec"            "awk 'BEGIN{system(\"cp $TASK_DB /tmp/copy\")}' $TASK_DB" "DENY"
assert_bash_verdict "bash awk -i inplace"               "awk -i inplace '{print}' $TASK_DB"  "DENY"
# r2 patch/codex sweep: gawk external program/extension loaders + glued -i
assert_bash_verdict "bash awk --include load"           "awk --include=/tmp/evil.awk '{print}' $TASK_DB" "DENY"
assert_bash_verdict "bash awk -l extension load"        "awk -l /tmp/evil_ext '{print}' $TASK_DB" "DENY"
assert_bash_verdict "bash awk @include"                 "awk @include /tmp/evil.awk $TASK_DB" "DENY"
assert_bash_verdict "bash awk -iinplace glued"          "awk -iinplace '{print}' $TASK_DB"   "DENY"
assert_bash_verdict "bash awk -E exec program"          "awk -E /tmp/evil.awk $TASK_DB"      "DENY"
assert_bash_verdict "bash awk -o pretty-print write"    "awk -o /tmp/o.awk '{print}' $TASK_DB" "DENY"
assert_bash_verdict "bash awk -p profile write"         "awk -p /tmp/prof '{print}' $TASK_DB" "DENY"
assert_bash_verdict "bash awk --dump-variables write"   "awk --dump-variables=/tmp/o '{print}' $TASK_DB" "DENY"
assert_bash_verdict "bash awk -W meta-flag"             "awk -W exec=/tmp/x $TASK_DB"        "DENY"
assert_bash_verdict "bash awk unknown flag (fail-closed)" "awk --some-future-flag '{print}' $TASK_DB" "DENY"
assert_bash_verdict "bash awk --sandbox read (allowed)" "awk --sandbox '{print \$1}' $TASK_DB" "ALLOW"
assert_bash_verdict "bash yq --in-place write"          "yq --in-place . $TASK_DB"           "DENY"
assert_bash_verdict "bash awk plain read (allowed)"     "awk '{print \$2}' $TASK_DB"         "ALLOW"
assert_bash_verdict "bash awk -F: read (allowed)"       "awk -F: '{print \$1}' $TASK_DB"     "ALLOW"

# ===== DENY (teeth): other read leaders with named-output/exec (issue #1690) =====
# sort -o / less -o / xxd outfile / view -c 'w!' / rg --pre / yq -i all
# write/exfil/RCE with NO shell `>` token. Codex re-review found these.
assert_bash_verdict "bash sort -o output file"   "sort -o /tmp/leak $TASK_DB"           "DENY"
assert_bash_verdict "bash less -o log file"      "less -o /tmp/leak $TASK_DB"           "DENY"
assert_bash_verdict "bash less -k lesskey loader" "less -k /tmp/evil.lesskey $TASK_DB"   "DENY"
assert_bash_verdict "bash less --lesskey-context" "less --lesskey-context=stuff $TASK_DB" "DENY"
assert_bash_verdict "bash xxd output positional" "xxd $TASK_DB /tmp/leak"               "DENY"
assert_bash_verdict "bash xxd bare-name output"  "xxd $TASK_DB leak"                    "DENY"
assert_bash_verdict "bash view ex :w write"      "view -c 'w! /tmp/leak' -c 'qa!' $TASK_DB" "DENY"
assert_bash_verdict "bash rg --pre RCE"          "rg --pre sh . $TASK_DB"               "DENY"
assert_bash_verdict "bash yq -i in-place write"  "yq -i . $TASK_DB"                     "DENY"
# round-3 residuals: pager +cmd startup + sort --compress-program RCE
assert_bash_verdict "bash view +cmd ex write"    "view '+w! /tmp/leak' $TASK_DB"        "DENY"
assert_bash_verdict "bash less +!shell"          "less '+!cp $TASK_DB /tmp/leak' $TASK_DB" "DENY"
assert_bash_verdict "bash more +!shell"          "more '+!cp $TASK_DB /tmp/leak' $TASK_DB" "DENY"
assert_bash_verdict "bash sort --compress-program RCE" "sort --compress-program=sh $TASK_DB" "DENY"
assert_bash_verdict "bash sort -n read (allowed)" "sort -n $TASK_DB"                    "ALLOW"
assert_bash_verdict "bash xxd lone read (allowed)" "xxd -s 0 -l 64 $TASK_DB"            "ALLOW"
assert_bash_verdict "bash more lone read (allowed)" "more $TASK_DB"                     "ALLOW"
# r2 patch adversarial review: uniq 2nd-positional output, view startup-file
assert_bash_verdict "bash uniq output positional" "uniq $TASK_DB /tmp/leak"             "DENY"
assert_bash_verdict "bash uniq -c output positional" "uniq -c $TASK_DB /tmp/leak"       "DENY"
assert_bash_verdict "bash uniq lone read (allowed)" "uniq $TASK_DB"                     "ALLOW"
assert_bash_verdict "bash uniq -f flag-value read (allowed)" "uniq -f 2 $TASK_DB"       "ALLOW"
assert_bash_verdict "bash view -u vimrc startup"  "view -u /tmp/evil.vim $TASK_DB"      "DENY"
assert_bash_verdict "bash view -i shada startup"  "view -i /tmp/x.shada $TASK_DB"       "DENY"
assert_bash_verdict "bash view -U gvimrc startup" "view -U /tmp/g.vim $TASK_DB"         "DENY"
assert_bash_verdict "bash view --startuptime write" "view --startuptime /tmp/out $TASK_DB" "DENY"
assert_bash_verdict "bash view -V verbose-to-file" "view -V1/tmp/out $TASK_DB"          "DENY"
assert_bash_verdict "bash view unknown flag (fail-closed)" "view --some-future-flag $TASK_DB" "DENY"
assert_bash_verdict "bash view -R readonly (allowed)" "view -R $TASK_DB"                "ALLOW"
assert_bash_verdict "bash view lone read (allowed)" "view $TASK_DB"                     "ALLOW"
# quoted-flag bypass: shell-quoted flags must still DENY (quote-strip)
assert_bash_verdict "bash view quoted -c flag"    "view \"-c\" \"w!/tmp/leak\" $TASK_DB" "DENY"
assert_bash_verdict "bash awk quoted -f flag"     "awk \"-f\" /tmp/x.awk $TASK_DB"      "DENY"
assert_bash_verdict "bash find quoted -exec flag" "find $TASK_DB \"-exec\" cp x {} ;"   "DENY"
assert_bash_verdict "bash xxd quoted flag-value (allowed)" "xxd \"-s\" 0 $TASK_DB"      "ALLOW"
# round-4 residuals: awk -f program-file, yq -s split-exp, env-exec prefix
assert_bash_verdict "bash awk -f program file"   "awk -f /tmp/evil.awk $TASK_DB"        "DENY"
assert_bash_verdict "bash yq -s split-exp write" "yq -s /tmp/leak . $TASK_DB"           "DENY"
assert_bash_verdict "bash PAGER= env exec"       "PAGER=sh less $TASK_DB"               "DENY"
assert_bash_verdict "bash LD_PRELOAD= injection" "LD_PRELOAD=/tmp/x.so cat $TASK_DB"    "DENY"
assert_bash_verdict "bash benign LC_ALL prefix (allowed)" "LC_ALL=C cat $TASK_DB"       "ALLOW"
# round-5 residual: adjacent-quote split hides awk system() from the scan
assert_bash_verdict "bash awk quote-split system()" "awk 'BEGIN{syst''em(\"id\")}' $TASK_DB" "DENY"
# round-6 residual: shell embedding ($()/backtick/procsub) runs a command
# before the visible read leader.
assert_bash_verdict "bash cmd-subst exfil"       "cat $TASK_DB \$(cp $TASK_DB sink)"    "DENY"
assert_bash_verdict "bash backtick exfil"        "cat \`cp $TASK_DB sink\` $TASK_DB"    "DENY"
assert_bash_verdict "bash process-subst exfil"   "cat <(cp $TASK_DB sink)"             "DENY"

# ===== DENY (teeth): sibling-gate ordering (issue #1690 r2 — codex Phase-4) =====
# The tasks.db read-intent carve-out lifts ONLY the tasks.db-specific deny;
# it must NOT short-circuit the later Stage A (shared/secrets, shared/
# private) and Stage B (peer-home) deny gates. A read-intent command that
# names BOTH tasks.db AND a forbidden path must still be DENIED.
assert_bash_verdict "bash tasks.db + shared/secrets (read-intent)" \
  "cat $TASK_DB $SECRETS_FILE" "DENY"
assert_bash_verdict "bash shared/secrets + tasks.db (order swapped)" \
  "cat $SECRETS_FILE $TASK_DB" "DENY"
assert_bash_verdict "bash tasks.db + shared/private (read-intent)" \
  "cat $TASK_DB $PRIVATE_FILE" "DENY"
assert_bash_verdict "bash tasks.db + peer-home (read-intent)" \
  "cat $TASK_DB $PEER_HOME/MEMORY.md" "DENY"
# Controls: the carve-out still works for tasks.db ALONE, and the forbidden
# path alone is still denied (proving the deny is not a tasks.db artifact).
assert_bash_verdict "bash tasks.db alone still ALLOWED" "cat $TASK_DB" "ALLOW"
assert_bash_verdict "bash shared/secrets alone still DENIED" "cat $SECRETS_FILE" "DENY"

# ===== DENY (teeth): mutators / fail-closed on unparseable =====
assert_bash_verdict "bash rm tasks.db"             "rm $TASK_DB"              "DENY"
assert_bash_verdict "bash unbalanced-quote command" "cat $TASK_DB ' | tee /tmp/leak" "DENY"

# --- Revert teeth: the read-allow MUST be DENIED with the carve-out gone -----
#
# Strip the two `if read_intent: return None` carve-out lines that this PR
# adds to the tasks.db branches, then re-assert the read case against the
# reverted policy. It MUST be DENIED there — proving the smoke genuinely
# exercises the new allow and would FAIL the moment the carve-out is
# reverted (no false green if the fix is removed).

echo "[smoke:${SMOKE_NAME}] revert teeth — reverted policy must DENY the read"

REVERTED_POLICY="$SMOKE_REPO_ROOT/hooks/tool-policy-1690-reverted-$$.py"
# Remove ONLY the `if read_intent: return None` carve-out lines that this
# PR adds to the two tasks.db branches, then re-test. The revert helper is
# a standalone script (footgun #11 — no interpreter heredoc-stdin).
"$PYTHON_BIN" "$SCRIPT_DIR/1690-tasksdb-read-carveout-revert.py" \
  "$SMOKE_REPO_ROOT/hooks/tool-policy.py" "$REVERTED_POLICY"

# Sanity: the revert helper must have actually removed the carve-out.
if ! "$PYTHON_BIN" -c '
import sys
src = open(sys.argv[1]).read()
# The reverted file must still contain the tasks.db deny but NOT a
# read_intent carve-out immediately guarding it.
sys.exit(0 if "direct queue DB access is blocked" in src else 3)
' "$REVERTED_POLICY"; then
  smoke_fail "revert helper produced an unexpected policy (deny string missing)"
fi

# Bash read of the DB must now be DENIED under the reverted policy.
revert_payload="$SMOKE_TMP_ROOT/payload-revert-bash.json"
write_bash_payload "$revert_payload" "cat $TASK_DB"
revert_out="$(run_pretool_hook "$revert_payload" "$REVERTED_POLICY")"
revert_got="$(verdict_of "$revert_out")"
if [[ "$revert_got" == "DENY" ]]; then
  smoke_log "ok: revert teeth (bash) — reverted policy DENIES the read"
else
  smoke_log "FAIL: revert teeth (bash) — reverted policy returned ${revert_got}, want DENY"
  smoke_log "      this means the smoke would NOT catch a reverted carve-out"
  smoke_fail "revert teeth (bash): expected DENY, got ${revert_got}"
fi

# Non-Bash Read of the DB must also be DENIED under the reverted policy.
revert_payload_read="$SMOKE_TMP_ROOT/payload-revert-read.json"
write_path_payload "$revert_payload_read" "Read" "$TASK_DB"
revert_out_read="$(run_pretool_hook "$revert_payload_read" "$REVERTED_POLICY")"
revert_got_read="$(verdict_of "$revert_out_read")"
if [[ "$revert_got_read" == "DENY" ]]; then
  smoke_log "ok: revert teeth (non-bash Read) — reverted policy DENIES the read"
else
  smoke_log "FAIL: revert teeth (non-bash Read) — reverted policy returned ${revert_got_read}, want DENY"
  smoke_fail "revert teeth (Read): expected DENY, got ${revert_got_read}"
fi

smoke_log "passed"
