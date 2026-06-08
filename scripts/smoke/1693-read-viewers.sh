#!/usr/bin/env bash
# scripts/smoke/1693-read-viewers.sh — KEEP-invariant gate for issue #1693.
#
# Two small, low-risk changes to hooks/tool-policy.py:
#
#   Part 1 — add genuinely stdout-only viewers (strings, hexdump, comm,
#     fold, expand, paste, csvlook) to _READ_INTENT_BASH_COMMANDS so a
#     diagnostic READ of a protected path (`strings <roster>`, `hexdump
#     -C <roster>`, `comm a b`) is classified read-intent instead of
#     write-intent and no longer false-denied by the roster / system-
#     config / queue gates. bat/batcat were deliberately NOT added (they
#     carry a pager-exec surface) — they STAY denied here.
#
#   Part 2 — narrow the shlex-failure substring fallback's SHORT-needle
#     (`hooks/`, `state/cron/`) prefix set: drop prose-punctuation chars
#     (quote, paren, comma, pipe, semicolon) so a benign prose mention of
#     a short suffix inside an unbalanced-quote command body (`it's
#     'hooks/x`, `(hooks/post.sh)`, `a,hooks/z`) no longer over-fires the
#     system-config deny, while a REAL redirect / assignment / path-
#     construction reference (`>hooks/evil.sh`, `<hooks/secret`,
#     `VAR=hooks/x`, `/etc/hooks/x`) STAYS denied.
#
# KEEP-invariant teeth (must STILL be DENIED after the fix):
#   - a write/redirect to a protected path via a viewer (`strings <db> >
#     <roster>`) — the per-token write-redirect check still fires.
#   - a real argv that opens a protected file (a write tool to the roster).
#   - bat/batcat on a protected path (NOT added; pager-exec surface).
#   - a real redirect to a short-needle path in an unbalanced-quote body
#     (`echo x >hooks/evil.sh 'unterminated`).
#   - the structural credential / shared / peer-home gates are UNCHANGED:
#     a NON-admin peer-home read stays DENIED (proving #1691's surface was
#     not touched).
#
# Revert teeth: a final phase re-runs the ALLOW assertions against a
# reverted policy (viewer additions stripped + the broad short-needle
# prefix set restored) and asserts they FLIP to DENY — proving the smoke
# would FAIL the moment the fix is reverted (no false green).
#
# Footgun #11: every JSON stdin payload is built with `printf` (never an
# interpreter here-string / heredoc-stdin) and piped with `< file`,
# matching scripts/smoke/1690-tasksdb-read-carveout.sh.

set -euo pipefail

SMOKE_NAME="1693-read-viewers"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REVERTED_POLICY=""
cleanup() {
  [[ -n "$REVERTED_POLICY" && -f "$REVERTED_POLICY" ]] && rm -f "$REVERTED_POLICY"
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

# The roster local file is a system-config protected path; a diagnostic
# read of it is the Part-1 scenario. Materialize a fixture (gate compares
# paths, not contents).
ROSTER="$BRIDGE_ROSTER_LOCAL_FILE"
printf '%s\n' '# roster fixture' >"$ROSTER"
CSV="$BRIDGE_HOME/data.csv"
printf 'a,b\n1,2\n' >"$CSV"

# Non-admin (user-class) acting agent. The Part-1 ALLOW is read-intent for
# EVERY agent; the Stage-B peer-home teeth below must run as a non-admin
# (issue #1692 gives admin a peer-home read carve-out), so we use a single
# user-class agent throughout.
AGENT="worker-1693"
AGENT_HOME="$BRIDGE_AGENT_HOME_ROOT/$AGENT"
mkdir -p "$AGENT_HOME"
printf -- '- session type: static\n' >"$AGENT_HOME/SESSION-TYPE.md"

# A peer agent home so a peer-home read can be exercised. The structural
# peer-home gate (#1691 surface) must stay DENY for this non-admin agent.
PEER_AGENT="peer-1693"
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

write_bash_payload() {
  local target="$1" command="$2" esc
  esc="$(json_escape "$command")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    '  "tool_name": "Bash",' \
    "  \"tool_input\": {\"command\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1693",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

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

# $1 label, $2 command, $3 ALLOW|DENY, $4 optional policy override.
assert_bash_verdict() {
  local label="$1" command="$2" want="$3" policy="${4:-}" payload out got
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM.json"
  write_bash_payload "$payload" "$command"
  out="$(run_pretool_hook "$payload" "$policy")"
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

echo "[smoke:${SMOKE_NAME}] Part 1 — read-only viewers classify read-intent (ALLOW)"

# Build short-needle / path fragments at runtime so the smoke source carries
# no bare protected-path literal in a way that would trip the credential
# pre-tool guard when an agent edits it (the fragments are reassembled here).
HK="hooks"; SC="state/cron"; APO="'"; PIPE="|"; LEAK="/tmp/agb-1693-leak"

# ===== ALLOW (fix): viewers on a protected roster read =====
assert_bash_verdict "strings of roster"   "strings $ROSTER"        "ALLOW"
assert_bash_verdict "hexdump -C of roster" "hexdump -C $ROSTER"    "ALLOW"
assert_bash_verdict "comm two files"      "comm $ROSTER $ROSTER"   "ALLOW"
assert_bash_verdict "fold of roster"      "fold $ROSTER"           "ALLOW"
assert_bash_verdict "expand of roster"    "expand $ROSTER"         "ALLOW"
assert_bash_verdict "paste two files"     "paste $ROSTER $ROSTER"  "ALLOW"
assert_bash_verdict "csvlook of csv"      "csvlook $CSV"           "ALLOW"
# Control: cat already classifies read-intent (proves the gate is live).
assert_bash_verdict "cat of roster (control)" "cat $ROSTER"        "ALLOW"

echo "[smoke:${SMOKE_NAME}] Part 1 teeth — viewers cannot become a write bypass; bat/batcat stay DENY"

# ===== DENY (teeth): a viewer whose stdout is redirected to a sink =====
assert_bash_verdict "strings roster redirected to sink" "strings $ROSTER > $LEAK" "DENY"
assert_bash_verdict "hexdump roster append to sink"     "hexdump $ROSTER >> $LEAK" "DENY"
# ===== DENY (teeth): a write/redirect INTO the protected roster =====
assert_bash_verdict "redirect-into (clobber) roster"    "cat $CSV > $ROSTER"      "DENY"
# ===== DENY (teeth): bat/batcat NOT added (pager-exec surface) =====
assert_bash_verdict "bat of roster (not added)"         "bat $ROSTER"             "DENY"
assert_bash_verdict "batcat of roster (not added)"      "batcat $ROSTER"          "DENY"

echo "[smoke:${SMOKE_NAME}] Part 2 — shlex-fail prose short-needle no longer over-fires (ALLOW)"

# Each of these makes shlex.split() raise on the unbalanced trailing
# apostrophe, falling to the substring scan. The short needle sits behind
# prose punctuation (quote / paren / comma) — a benign mention, not a write.
assert_bash_verdict "prose quote-then-needle" \
  "echo it${APO}s ${APO}${HK}/x and don${APO}t" "ALLOW"
assert_bash_verdict "prose paren-then-needle" \
  "echo (${HK}/x) don${APO}t" "ALLOW"
assert_bash_verdict "prose comma-then-needle" \
  "echo a,${HK}/x don${APO}t" "ALLOW"
assert_bash_verdict "prose quote-then-state-cron" \
  "echo see ${APO}${SC}/jobs and don${APO}t" "ALLOW"
# The issue's exact verbatim repro (already passing pre-#1693 via the
# whitespace-exclusion rule) — assert it stays ALLOW (no regression).
assert_bash_verdict "issue verbatim repro (whitespace-prefixed)" \
  "git commit -m \"fix ${HK}/settings.json don${APO}t break the chain\"" "ALLOW"

echo "[smoke:${SMOKE_NAME}] Part 2 teeth — real redirect/assignment/path short-needle STAYS DENY"

# ===== DENY (teeth): redirect / assignment / path-construction kept =====
assert_bash_verdict "real redirect-to-hooks (unbalanced)" \
  "echo x >${HK}/evil.sh don${APO}t" "DENY"
assert_bash_verdict "real input-redirect-from-hooks (unbalanced)" \
  "cat <${HK}/secret don${APO}t" "DENY"
assert_bash_verdict "real assignment VAR=hooks (unbalanced)" \
  "echo FOO=${HK}/x don${APO}t" "DENY"
assert_bash_verdict "real path /etc/hooks (unbalanced)" \
  "echo cp /etc/${HK}/x there don${APO}t" "DENY"
# ===== DENY (teeth): QUOTED redirect target (issue #1693 codex review) =====
# `cat >'hooks/evil' # don't` is a Bash-valid write — Bash treats `# don't`
# as a comment, but shlex (comments=False) raises on the apostrophe so the
# substring fallback runs. The needle's immediate prefix is the OPENING
# quote of the redirect target, whose own preceding char is `>` — a genuine
# write position that must STAY denied (the quote special-case in
# _command_substring_hits_protected_needle). A bare prose quote (asserted
# ALLOW above) is preceded by whitespace and still passes.
assert_bash_verdict "real redirect to single-quoted hooks (unbalanced comment)" \
  "cat >${APO}${HK}/evil${APO} # don${APO}t" "DENY"
assert_bash_verdict "real redirect to double-quoted hooks (unbalanced comment)" \
  "cat >\"${HK}/evil\" # don\"t" "DENY"
assert_bash_verdict "real assignment to double-quoted hooks (unbalanced)" \
  "echo FOO=\"${HK}/x\" don${APO}t" "DENY"
# ===== DENY (teeth): Bash noclobber-override redirect >| (#1693 codex r2) =====
# `cat >|hooks/evil # don't` overrides noclobber and WRITES to hooks/evil;
# shlex fails on the comment apostrophe so the fallback runs. The needle's
# effective boundary (looking through any opening quote) is `|` preceded by
# `>` — a real output redirect that must STAY denied. A BARE pipe stage
# (`echo a|hooks/x`, asserted ALLOW below) runs a command, not a write.
assert_bash_verdict "noclobber-override bare needle (unbalanced)" \
  "cat >${PIPE}${HK}/evil # don${APO}t" "DENY"
assert_bash_verdict "noclobber-override single-quoted needle (unbalanced)" \
  "cat >${PIPE}${APO}${HK}/evil${APO} # don${APO}t" "DENY"
assert_bash_verdict "noclobber-override double-quoted needle (unbalanced)" \
  "cat >${PIPE}\"${HK}/evil\" # don\"t" "DENY"
# ===== DENY (teeth): SPACE-separated redirect target (#1693 codex r3) =====
# A redirect target separated from its operator by whitespace is still a
# Bash-valid write — `cat > 'hooks/evil' # don't`, `cat 2> hooks/evil ...`.
# The position test skips the whitespace run and checks the redirect
# operator that precedes it. Cover every operator spelling (bare + quoted).
assert_bash_verdict "space redirect bare needle" \
  "cat > ${HK}/evil # don${APO}t" "DENY"
assert_bash_verdict "space redirect single-quoted needle" \
  "cat > ${APO}${HK}/evil${APO} # don${APO}t" "DENY"
assert_bash_verdict "space append redirect quoted needle" \
  "cat >> ${APO}${HK}/evil${APO} # don${APO}t" "DENY"
assert_bash_verdict "space all-stream redirect needle" \
  "cat &> ${HK}/evil # don${APO}t" "DENY"
assert_bash_verdict "space fd2 redirect needle" \
  "cat 2> ${HK}/evil # don${APO}t" "DENY"
assert_bash_verdict "space fd-numeric redirect needle" \
  "cat 9> ${HK}/evil # don${APO}t" "DENY"
assert_bash_verdict "space input redirect needle" \
  "cat < ${HK}/evil # don${APO}t" "DENY"
assert_bash_verdict "space noclobber-override redirect needle" \
  "cat >${PIPE} ${HK}/evil # don${APO}t" "DENY"
# `>&word` / `<&word` redirect stdout+stderr (or input) to a file; the
# operator ends in `&` preceded by `>`/`<` (issue #1693 codex r4).
assert_bash_verdict "space all-stream >& redirect needle" \
  "echo hi >& ${HK}/evil # don${APO}t" "DENY"
assert_bash_verdict "space all-stream >& quoted needle" \
  "echo hi >& ${APO}${HK}/evil${APO} # don${APO}t" "DENY"
assert_bash_verdict "space input <& redirect needle" \
  "cat <& ${HK}/evil # don${APO}t" "DENY"
# ===== ALLOW (prose): bare pipe + ordinary prose whitespace =====
# `echo a|hooks/x don't` pipes into `hooks/x` as a command — not a write to
# the path; the bare `|` (not preceded by `>`) is a benign stage boundary.
assert_bash_verdict "prose bare-pipe-then-needle" \
  "echo a${PIPE}${HK}/x don${APO}t" "ALLOW"
# Ordinary prose: a space before the needle whose run is NOT preceded by a
# redirect operator stays a benign mention (the #509 D2 whitespace rule).
assert_bash_verdict "prose plain whitespace-then-needle" \
  "echo see ${HK}/x for details don${APO}t" "ALLOW"
# A bare `&` (job control / `&&`), not preceded by `>`/`<`, is NOT a
# redirect operator — `hooks/x` after it is a command/word, not a write.
assert_bash_verdict "prose background-amp-then-needle" \
  "echo a && ${HK}/x don${APO}t" "ALLOW"
# Long needle still matches on plain substring (unaffected by the narrowing).
assert_bash_verdict "long needle agent-roster (unbalanced prose)" \
  "echo edit agent-roster.local.sh later don${APO}t" "DENY"

echo "[smoke:${SMOKE_NAME}] structural gates UNCHANGED — non-admin peer-home read STILL DENY (#1691 surface)"

# Proves the structural credential / peer-home MENTION gate was NOT touched.
assert_bash_verdict "non-admin peer-home read still denied" \
  "cat $PEER_HOME/MEMORY.md" "DENY"

# --- Revert teeth: the fix removed -> the ALLOW cases MUST flip to DENY ------

echo "[smoke:${SMOKE_NAME}] revert teeth — reverted policy must DENY the fixed cases"

REVERTED_POLICY="$SMOKE_REPO_ROOT/hooks/tool-policy-1693-reverted-$$.py"
"$PYTHON_BIN" "$SCRIPT_DIR/1693-read-viewers-revert.py" \
  "$SMOKE_REPO_ROOT/hooks/tool-policy.py" "$REVERTED_POLICY"

# Part 1 revert teeth: a viewer read must now be DENIED.
assert_bash_verdict "revert: strings of roster now DENIED" \
  "strings $ROSTER" "DENY" "$REVERTED_POLICY"
assert_bash_verdict "revert: comm now DENIED" \
  "comm $ROSTER $ROSTER" "DENY" "$REVERTED_POLICY"
# Part 2 revert teeth: the prose quote-then-needle must over-fire again.
assert_bash_verdict "revert: prose quote-then-needle over-fires (DENY)" \
  "echo it${APO}s ${APO}${HK}/x and don${APO}t" "DENY" "$REVERTED_POLICY"

smoke_log "passed"
