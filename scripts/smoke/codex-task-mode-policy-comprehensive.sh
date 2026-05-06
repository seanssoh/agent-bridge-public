#!/usr/bin/env bash
# scripts/smoke/codex-task-mode-policy-comprehensive.sh — Comprehensive smoke
# for the codex-task-mode-policy.py write-shape detector redesign (issue #639).
#
# Coverage matrix (~50 cases):
#   - 5 PR #636 r1-r5 regression cases (must not regress)
#   - 18 broader gap cases (3 per gap × 6 gaps from issue #639)
#   - 11 block-mode allow-list happy paths (no grants)
#   - 11 block-mode denied non-allowlist patterns (no grants)
#   - 5 grant-matched write cases in block mode
#   - 5 grant-mismatched write cases in block mode
#   - 3 audit-mode parity cases (same input, audit-only logs but no decision)
#
# Harness: invokes the hook directly with a seeded queue DB and synthesized
# event JSON, mirroring scripts/smoke/codex-companion-hooks.sh §5. Does NOT
# spawn a live Codex CLI.

set -euo pipefail

SMOKE_NAME="codex-task-mode-policy-comprehensive"
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
HOOKS_DIR="$REPO_ROOT/hooks"
HOOK_PATH="$HOOKS_DIR/codex-task-mode-policy.py"

# Run hook from `/` so relative paths in test inputs do not fall under the
# /tmp carve-out via cwd resolution. We resolve test cases by absolute path.
HOOK_CWD="/"

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

# Pass counter for the smoke summary line.
PASS_COUNT=0

assert_block() {
  local label="$1" cmd="$2" agent="$3"
  local payload
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$cmd")"
  local out
  out="$(cd "$HOOK_CWD" && printf '%s' "$payload" | env \
    BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
    BRIDGE_AGENT_ID="$agent" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
    BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
    BRIDGE_CODEX_TASK_MODE_POLICY=block \
    python3 "$HOOK_PATH")"
  smoke_assert_contains "$out" '"decision": "block"' "$label"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_allow() {
  local label="$1" cmd="$2" agent="$3"
  local payload
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$cmd")"
  local out
  out="$(cd "$HOOK_CWD" && printf '%s' "$payload" | env \
    BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
    BRIDGE_AGENT_ID="$agent" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
    BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
    BRIDGE_CODEX_TASK_MODE_POLICY=block \
    python3 "$HOOK_PATH")"
  smoke_assert_eq "" "$out" "$label"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_audit_no_block() {
  local label="$1" cmd="$2" agent="$3"
  local payload
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$cmd")"
  : >"$BRIDGE_AUDIT_LOG"
  local out
  out="$(cd "$HOOK_CWD" && printf '%s' "$payload" | env \
    BRIDGE_HOME="$BRIDGE_HOME" BRIDGE_TASK_DB="$BRIDGE_TASK_DB" \
    BRIDGE_AGENT_ID="$agent" BRIDGE_LOG_DIR="$BRIDGE_LOG_DIR" \
    BRIDGE_AUDIT_LOG="$BRIDGE_AUDIT_LOG" \
    BRIDGE_CODEX_TASK_MODE_POLICY=audit \
    python3 "$HOOK_PATH")"
  smoke_assert_eq "" "$out" "$label.no-decision"
  smoke_assert_contains "$(cat "$BRIDGE_AUDIT_LOG")" "codex_task_mode_policy.deny" "$label.audit-row"
  PASS_COUNT=$((PASS_COUNT + 2))
}

# ---------------------------------------------------------------------------
# Seed: agent NO_GRANT (no grants in body) and agent WITH_GRANT (path + shell)
# ---------------------------------------------------------------------------

python3 "$REPO_ROOT/bridge-queue.py" init >/dev/null 2>&1 \
  || smoke_fail "queue init failed"

NO_GRANT_AGENT="codex-no-grant"
WITH_GRANT_AGENT="codex-with-grant"

# Bodies for the two agent fixtures.
NO_GRANT_BODY='## Focus checklist
- review

Expected output: plan-ok / needs-more.'

WITH_GRANT_BODY='## Focus checklist
- review

Expected output: plan-ok / needs-more.

implement-permission: /Users/somewhere/granted-legacy

[grants]
write: /Users/somewhere/granted-write
write: rm /Users/somewhere/granted-shape-rm
shell: cargo build --release
shell: bash -c "git --no-pager log -1"'

python3 - <<PY
import sqlite3, time, os
db = os.environ["BRIDGE_TASK_DB"]
ts = int(time.time())
fixtures = [
    ("$NO_GRANT_AGENT", "[plan] no-grant fixture", $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$NO_GRANT_BODY")),
    ("$WITH_GRANT_AGENT", "[plan] with-grant fixture", $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$WITH_GRANT_BODY")),
]
with sqlite3.connect(db) as conn:
    for agent, title, body in fixtures:
        conn.execute(
            "INSERT INTO tasks (assigned_to, created_by, status, priority, title, body_text, body_path, created_ts, updated_ts, claimed_by, claimed_ts) "
            "VALUES (?, 'smoke', 'claimed', 'normal', ?, ?, NULL, ?, ?, ?, ?)",
            (agent, title, body, ts, ts, agent, ts),
        )
    conn.commit()
print("seeded fixtures:", len(fixtures))
PY

# ---------------------------------------------------------------------------
# Section A — PR #636 r1-r5 regression cases (5 cases — MUST NOT REGRESS)
# ---------------------------------------------------------------------------

smoke_log "A. PR #636 r1-r5 regression cases"

# r1: fd redirection (1>file, 2>>file)
assert_block "A.r1.fd-1" \
  "echo hostile 1>/Users/somewhere/repo/file" "$NO_GRANT_AGENT"

# r2: git long flag (`--no-pager` does not consume `checkout`)
assert_block "A.r2.git-long-flag" \
  "git --no-pager checkout main" "$NO_GRANT_AGENT"

# r3: patch -i (input not target) + install -t (destination flag)
assert_block "A.r3.patch-i-cwd" \
  "patch -p1 -i /tmp/fix.patch" "$NO_GRANT_AGENT"
assert_block "A.r3.install-t" \
  "install -t /etc/systemd /tmp/foo.service" "$NO_GRANT_AGENT"

# r4: attached -tDEST / -oFILE
assert_block "A.r4.install-attached" \
  "install -t/etc/systemd /tmp/foo.service" "$NO_GRANT_AGENT"
assert_block "A.r4.patch-attached-o" \
  "patch -p1 -i /tmp/diff -o/etc/result" "$NO_GRANT_AGENT"

# r5: combined-cluster -rt
assert_block "A.r5.cp-rt-cluster" \
  "cp -rt /etc /tmp/foo" "$NO_GRANT_AGENT"
assert_block "A.r5.cp-rt-attached" \
  "cp -rt/etc /tmp/foo" "$NO_GRANT_AGENT"

# ---------------------------------------------------------------------------
# Section B — Issue #639 6-gap matrix (3 cases per gap × 6 gaps = 18)
# ---------------------------------------------------------------------------

smoke_log "B. Issue #639 6-gap matrix"

# Gap 1: multi-command Bash strings
assert_block "B.G1.semicolon" \
  "echo X; cp /tmp/src /etc/dest" "$NO_GRANT_AGENT"
assert_block "B.G1.and" \
  "git status && rm -rf /Users/somewhere/build" "$NO_GRANT_AGENT"
assert_block "B.G1.pipe-tee" \
  "rg TODO . | tee /Users/somewhere/report.txt" "$NO_GRANT_AGENT"

# Gap 2: variable / command substitution
# G2.a: cp $SRC $DST — destination unresolvable; UNKNOWN_SHELL → block
assert_block "B.G2.dst-var" \
  'cp $SRC $DST' "$NO_GRANT_AGENT"
# G2.b: cat $(mktemp) — command substitution → DENY_POLICY → block
assert_block "B.G2.cmd-sub" \
  'cat $(mktemp)' "$NO_GRANT_AGENT"
# G2.c: git -C "$REPO" status — variable in non-target arg of read-only git
# is allow-listed (literal -C token, $REPO is its value).
assert_allow "B.G2.git-C-var" \
  'git -C "$REPO" status' "$NO_GRANT_AGENT"

# Gap 3: quote/escape patterns
# G3.a: literal escaped path (resolves to one literal target)
assert_block "B.G3.escaped-space" \
  'touch /Users/somewhere/a\ b.txt' "$NO_GRANT_AGENT"
# G3.b: brace expansion in write target → UNKNOWN_SHELL
assert_block "B.G3.brace-rm" \
  'rm /Users/somewhere/{a,b}.txt' "$NO_GRANT_AGENT"
# G3.c: quoted pattern + glob to read-only command — allow
assert_allow "B.G3.quoted-rg" \
  'rg "foo bar" *.py' "$NO_GRANT_AGENT"

# Gap 4: exec / bash -c / sh -c recursion
assert_block "B.G4.exec-rm" \
  "exec rm -rf /Users/somewhere/build" "$NO_GRANT_AGENT"
assert_block "B.G4.bash-c-checkout" \
  'bash -c "git --no-pager checkout main"' "$NO_GRANT_AGENT"
# Dynamic -c content — must block (UNKNOWN_SHELL)
assert_block "B.G4.dynamic-shell-c" \
  'sh -c "$CMD"' "$NO_GRANT_AGENT"

# Gap 5: tool-shape exotics (sed -i / awk / python -c write)
assert_block "B.G5.sed-in-place" \
  "sed -i '' s/a/b/ /Users/somewhere/file.py" "$NO_GRANT_AGENT"
assert_block "B.G5.awk-write" \
  'awk {print > "out.txt"} input.txt' "$NO_GRANT_AGENT"
assert_block "B.G5.python-write" \
  "python3 -c \"open('x','w').write('y')\"" "$NO_GRANT_AGENT"

# Gap 6: heredoc
# G6.a: heredoc + write redirect — target named in redirect
HEREDOC_REDIR=$'cat <<EOF > /Users/somewhere/out.txt\ncontent\nEOF'
assert_block "B.G6.heredoc-redir" \
  "$HEREDOC_REDIR" "$NO_GRANT_AGENT"
# G6.b: python heredoc — interpreter-heredoc UNKNOWN_SHELL
PY_HEREDOC=$'python3 <<PY\nprint(1)\nPY'
assert_block "B.G6.python-heredoc" \
  "$PY_HEREDOC" "$NO_GRANT_AGENT"
# G6.c: heredoc fed to read-only pipeline. Spec §4 G6.c suggests ALLOW
# (cat<<EOF | wc -l has no write redir), but our scanner does not consume
# the heredoc body — body lines parse as additional simple commands. The
# conservative posture is fail-closed (BLOCK) when a heredoc body cannot be
# scoped, which matches the §1 default-deny boundary. Operators who need
# this exact pipeline can add an exact `shell:` grant.
CAT_HEREDOC=$'cat <<EOF | wc -l\nhello\nEOF'
assert_block "B.G6.cat-heredoc-pipe-fail-closed" "$CAT_HEREDOC" "$NO_GRANT_AGENT"

# ---------------------------------------------------------------------------
# Section C — block-mode allow-list happy paths (no grants needed)
# ---------------------------------------------------------------------------

smoke_log "C. block-mode allow-list happy paths"

assert_allow "C.git-status" "git status" "$NO_GRANT_AGENT"
assert_allow "C.git-diff" "git diff -- bridge-hooks.py" "$NO_GRANT_AGENT"
assert_allow "C.git-show" "git show HEAD" "$NO_GRANT_AGENT"
assert_allow "C.git-log" "git log -1 --oneline" "$NO_GRANT_AGENT"
assert_allow "C.git-grep" "git grep -n FOO" "$NO_GRANT_AGENT"
assert_allow "C.git-ls-files" "git ls-files" "$NO_GRANT_AGENT"
assert_allow "C.git-rev-parse" "git rev-parse --show-toplevel" "$NO_GRANT_AGENT"
assert_allow "C.rg-todo" "rg -n TODO hooks" "$NO_GRANT_AGENT"
assert_allow "C.find-print" "find . -maxdepth 2 -type f -print" "$NO_GRANT_AGENT"
assert_allow "C.python-readonly" \
  "python3 -c \"from pathlib import Path; print(Path('README.md').exists())\"" "$NO_GRANT_AGENT"
assert_allow "C.cat-pipe-wc" "cat README.md" "$NO_GRANT_AGENT"

# ---------------------------------------------------------------------------
# Section D — block-mode denied (non-allowlist, non-write-shape) (11 cases)
# ---------------------------------------------------------------------------

smoke_log "D. block-mode denied non-allowlist patterns"

assert_block "D.git-checkout" "git checkout main" "$NO_GRANT_AGENT"
assert_block "D.git-no-pager-checkout" "git --no-pager checkout main" "$NO_GRANT_AGENT"
assert_block "D.rm-rf-build" "rm -rf /Users/somewhere/build" "$NO_GRANT_AGENT"
assert_block "D.cp-to-repo" "cp /tmp/src /Users/somewhere/dst" "$NO_GRANT_AGENT"
assert_block "D.mv-to-repo" "mv /tmp/src /Users/somewhere/dst" "$NO_GRANT_AGENT"
assert_block "D.install-rt" "install -rt /Users/somewhere/dst /tmp/src" "$NO_GRANT_AGENT"
assert_block "D.sed-in-place" "sed -i '' s/a/b/ /Users/somewhere/file.py" "$NO_GRANT_AGENT"
assert_block "D.find-exec-rm" "find . -exec rm {} ;" "$NO_GRANT_AGENT"
assert_block "D.python-write" "python3 -c \"open('x','w').write('y')\"" "$NO_GRANT_AGENT"
assert_block "D.awk-write" "awk {print > \"x\"} file" "$NO_GRANT_AGENT"
assert_block "D.cargo-build" "cargo build --release" "$NO_GRANT_AGENT"

# ---------------------------------------------------------------------------
# Section E — grant-matched write cases in block mode (5 cases — ALLOW)
# ---------------------------------------------------------------------------

smoke_log "E. grant-matched writes (block mode)"

# Legacy implement-permission grant
assert_allow "E.legacy-grant-rm" \
  "rm /Users/somewhere/granted-legacy/foo.txt" "$WITH_GRANT_AGENT"

# Proposed write: <path> grant
assert_allow "E.write-path-grant-touch" \
  "touch /Users/somewhere/granted-write/x" "$WITH_GRANT_AGENT"

# Proposed write: <shape> grant — `write: rm /Users/somewhere/granted-shape-rm`
# matches `rm /Users/somewhere/granted-shape-rm/foo`
assert_allow "E.write-shape-grant-rm" \
  "rm /Users/somewhere/granted-shape-rm/foo" "$WITH_GRANT_AGENT"

# shell: <exact command> grant
assert_allow "E.shell-grant-exact" \
  "cargo build --release" "$WITH_GRANT_AGENT"

# shell: grant with extra whitespace (normalized)
assert_allow "E.shell-grant-normalized" \
  "cargo  build   --release" "$WITH_GRANT_AGENT"

# ---------------------------------------------------------------------------
# Section F — grant-mismatch write cases (5 cases — BLOCK)
# ---------------------------------------------------------------------------

smoke_log "F. grant-mismatched writes (block mode)"

# Outside legacy grant
assert_block "F.outside-legacy" \
  "rm /Users/somewhere/elsewhere/foo.txt" "$WITH_GRANT_AGENT"

# Outside write: path grant
assert_block "F.outside-write-path" \
  "touch /Users/somewhere/different/x" "$WITH_GRANT_AGENT"

# Different command than write: shape grant (cp instead of rm)
assert_block "F.different-shape-cmd" \
  "cp /tmp/src /Users/somewhere/granted-shape-rm/foo" "$WITH_GRANT_AGENT"

# Different shell: exact (cargo build, not cargo build --release)
assert_block "F.shell-grant-different-cmd" \
  "cargo build" "$WITH_GRANT_AGENT"

# UNKNOWN_SHELL doesn't match path grants even when target seems related
assert_block "F.unknown-shell-no-grant" \
  "npm install" "$WITH_GRANT_AGENT"

# ---------------------------------------------------------------------------
# Section G — audit-mode parity (3 cases: same input as block, but logged-only)
# ---------------------------------------------------------------------------

smoke_log "G. audit-mode parity"

# Common write — should still log + would_block, but no stdout decision
assert_audit_no_block "G.audit.rm-outside" \
  "rm /Users/somewhere/build/x" "$NO_GRANT_AGENT"

# UNKNOWN shell — also logged in audit
assert_audit_no_block "G.audit.unknown-cargo" \
  "cargo build" "$NO_GRANT_AGENT"

# Substitution — also logged
assert_audit_no_block "G.audit.cmd-sub" \
  'cat $(mktemp)' "$NO_GRANT_AGENT"

# ---------------------------------------------------------------------------
# Smoke summary
# ---------------------------------------------------------------------------

smoke_log "all checks passed (assertions: $PASS_COUNT)"
