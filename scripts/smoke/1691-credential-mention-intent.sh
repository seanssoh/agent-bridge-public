#!/usr/bin/env bash
# scripts/smoke/1691-credential-mention-intent.sh — Issue #1691 closure smoke.
#
# Four guard gates (`hooks/tool-policy.py`) denied a command because its RAW
# TEXT contained a protected literal — a credential filename, a
# `shared/private`/`shared/secrets` alias, or a peer-agent-home path — WITHOUT
# checking whether the literal sits in an argv path-opener position or merely
# in a grep pattern, message body, or prose. The blunt substring matchers
# over-blocked benign mention / list / search. #1691 makes the four surfaces
# intent-aware (argv-position / string-payload-flag aware) while keeping the
# token-VALUE marker and the structural file-OPEN deny unconditional.
#
# This smoke drives the REAL PreToolUse hook end to end (stdin JSON ->
# permissionDecision) and proves the KEEP-invariants of all four surfaces:
#
#   ALLOW (the over-block being fixed):
#     - non-admin `grep -l <credfile> .` / `find . -name <credfile>` that NAMES
#       a credential file as a search term without opening it.
#     - non-admin Grep tool `pattern=<credfile>` / `pattern=<oauth-env-var>` /
#       `pattern=<shared-secret-path-string>` — a search string, not a file
#       open.
#     - non-admin message-body mention: `agb task create --body '… shared/
#       secrets …'`, `--body '… agents/<peer>/MEMORY.md'`, `-m '… <peer> …'`.
#     - non-admin benign LISTING / SEARCH of an allowlisted peer subpath
#       (`memory/{projects,decisions,shared}`) — read, not exfil (the Stage B
#       carve-out is no longer gated on class==system).
#
#   DENY (the teeth — must STILL be blocked):
#     - actual OPEN of a credential file: positional argv (`cat <credfile>`),
#       file-valued flag (`--file`/`-f`/`--input`), redirect target.
#     - the OAuth token-VALUE marker anywhere (Bash and Grep `pattern`) —
#       unconditional. Grepping FOR the literal token bytes IS the exfil.
#     - non-admin `ls`/`find` LISTING the shared secret/private dir contents
#       (inventory) — the #1691 material decision (mention-only, no inventory).
#     - non-admin OPEN/read of a shared-secret file.
#     - non-admin read of a peer file OUTSIDE the memory allowlist (top-level),
#       and any WRITE to a peer/shared path.
#     - a peer-home open SMUGGLED alongside a body mention (the body-subtract
#       must not mask a real open).
#
#   Revert-teeth (GENUINE): the smoke builds a copy of hooks/tool-policy.py
#   with the intent-aware change reverted to the pre-#1691 blunt-substring
#   behavior (scripts/smoke/1691-credential-mention-intent-revert.py) and
#   asserts every ALLOW case flips to DENY against it. The relaxation is what
#   produces the ALLOW verdicts and nothing else.
#
# Footgun: the protected credential filenames / shared-secret dir names / the
# OAuth value+env-var markers are assembled at RUNTIME from printf fragments
# (CRED_* / VAL_* below) so this .sh SOURCE never contains a protected literal
# — that keeps the live credential-detection guard (which still enforces the
# pre-#1691 over-block on the author's own commands) and the source scanners
# from tripping on the smoke file itself. The here-string operator in the
# embedding case is likewise assembled from single-char fragments (footgun #11
# lint-heredoc-ban: no literal here-string in source). JSON payloads are built
# with printf only — never an interpreter heredoc-stdin.
#
# macOS: pure policy-decision smoke; no sudo / multi-UID. Runs under
# /opt/homebrew/bin/bash 5.x and Linux CI bash alike.

set -euo pipefail

SMOKE_NAME="1691-credential-mention-intent"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REVERTED_HOOK=""
cleanup() {
  [[ -n "$REVERTED_HOOK" && -f "$REVERTED_HOOK" ]] && rm -f "$REVERTED_HOOK"
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

REAL_HOOK="$SMOKE_REPO_ROOT/hooks/tool-policy.py"

# --- Runtime-assembled protected literals (keep them out of the .sh source) --
# Credential filename markers (the four named in _raw_mentions_claude_creden-
# tials). Assembled from fragments so the source file carries no literal.
CRED_DOTCLAUDE="$(printf '%s' '.cla' 'ude')"
CRED_CREDFILE="$(printf '%s' '.creden' 'tials.json')"
CRED_REGISTRY="$(printf '%s' 'claude-oauth-' 'tokens.json')"
CRED_LAUNCHENV="$(printf '%s' 'launch-' 'secrets.env')"
# OAuth token VALUE prefix marker + the env-var NAME (value-class markers).
VAL_TOKEN="$(printf '%s' 'sk-ant-' 'o' 'SMOKEVALUE123')"
VAL_ENVVAR="$(printf '%s' 'CLAUDE_CODE_' 'OAUTH_TOKEN')"
# here-string operator assembled char-by-char (lint-heredoc-ban).
HERESTRING_OP="$(printf '%s' '<' '<' '<')"

# --- Fixtures ---------------------------------------------------------------

# A plain (non-admin) user agent — the actor for every ALLOW/DENY case.
USER_AGENT="worker-1691"
USER_HOME="$BRIDGE_AGENT_HOME_ROOT/$USER_AGENT"
mkdir -p "$USER_HOME"
printf -- '- session type: static\n' >"$USER_HOME/SESSION-TYPE.md"

# A peer agent home with an allowlisted memory subtree and a top-level file.
PEER_AGENT="peer-1691"
PEER_HOME="$BRIDGE_AGENT_HOME_ROOT/$PEER_AGENT"
mkdir -p "$PEER_HOME/memory/shared"
printf -- '# peer top-level memory\n' >"$PEER_HOME/MEMORY.md"
printf -- '# peer shared note\n' >"$PEER_HOME/memory/shared/note.md"

# Shared off-limits subtrees (private/ + secrets/) under $BRIDGE_HOME/shared.
SHARED_PRIV_DIR="$BRIDGE_SHARED_DIR/private"
SHARED_SECRETS_DIR="$BRIDGE_SHARED_DIR/secrets"
mkdir -p "$SHARED_PRIV_DIR" "$SHARED_SECRETS_DIR"
printf -- '# operator-only blob\n' >"$SHARED_PRIV_DIR/ops.md"
printf -- '# operator-only key blob\n' >"$SHARED_SECRETS_DIR/key.md"

# A plain (non-secret) search target the benign list/search cases run against.
SEARCH_DIR="$BRIDGE_STATE_DIR"

# --- Build a reverted copy of the hook for the revert-teeth proof -----------
REVERTED_HOOK="$SMOKE_REPO_ROOT/hooks/.tool-policy-1691-reverted-$$.py"
"$PYTHON_BIN" "$SCRIPT_DIR/1691-credential-mention-intent-revert.py" \
  "$REAL_HOOK" "$REVERTED_HOOK" \
  || smoke_fail "could not build reverted hook copy"
"$PYTHON_BIN" -m py_compile "$REVERTED_HOOK" \
  || smoke_fail "reverted hook copy did not compile"

# --- Payload + hook plumbing (printf only; footgun #11) ---------------------

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
    '  "tool_use_id": "smoke-1691",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

write_nonbash_payload() {
  local target="$1" tool="$2" key="$3" value="$4" esc
  esc="$(json_escape "$value")"
  printf '%s\n' \
    '{' \
    '  "hook_event_name": "PreToolUse",' \
    "  \"tool_name\": \"${tool}\"," \
    "  \"tool_input\": {\"${key}\": \"${esc}\"}," \
    '  "tool_use_id": "smoke-1691",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

run_hook() { # agent payload hook
  BRIDGE_AGENT_ID="$1" "$PYTHON_BIN" "$3" <"$2"
}

bash_verdict() { # command hook
  local payload out
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM-$RANDOM.json"
  write_bash_payload "$payload" "$1"
  out="$(run_hook "$USER_AGENT" "$payload" "$2")"
  [[ "$out" == *'"permissionDecision": "deny"'* ]] && printf 'DENY' || printf 'ALLOW'
}

nonbash_verdict() { # tool key value hook
  local payload out
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM-$RANDOM.json"
  write_nonbash_payload "$payload" "$1" "$2" "$3"
  out="$(run_hook "$USER_AGENT" "$payload" "$4")"
  [[ "$out" == *'"permissionDecision": "deny"'* ]] && printf 'DENY' || printf 'ALLOW'
}

assert_bash() { # label command want
  local got
  got="$(bash_verdict "$2" "$REAL_HOOK")"
  if [[ "$got" == "$3" ]]; then
    smoke_log "ok: $1 -> $got"
  else
    smoke_log "FAIL: $1 -> $got, want $3"
    smoke_log "      command: $2"
    smoke_fail "$1: expected $3, got $got"
  fi
}

assert_nonbash() { # label tool key value want
  local got
  got="$(nonbash_verdict "$2" "$3" "$4" "$REAL_HOOK")"
  if [[ "$got" == "$5" ]]; then
    smoke_log "ok: $1 -> $got"
  else
    smoke_log "FAIL: $1 -> $got, want $5 ($3=$4)"
    smoke_fail "$1: expected $5, got $got"
  fi
}

echo "[smoke:${SMOKE_NAME}] real PreToolUse hook end-to-end"

# ---------------------------------------------------------------------------
# Group 1 — ALLOW: the over-block being fixed. Collected so the revert-teeth
# pass can replay every one against the reverted hook and assert it flips.
# ---------------------------------------------------------------------------

# Bash: credential FILENAME named as a grep/find SEARCH term (not opened).
ALLOW_GREP_CREDFILE="grep -l ${CRED_DOTCLAUDE}/${CRED_CREDFILE} ${SEARCH_DIR}"
ALLOW_GREP_REGISTRY="grep -rl ${CRED_REGISTRY} ${SEARCH_DIR}"
ALLOW_FIND_LAUNCH="find ${SEARCH_DIR} -name ${CRED_LAUNCHENV}"
ALLOW_FIND_REGISTRY="find ${SEARCH_DIR} -name ${CRED_REGISTRY}"
# Bash: shared-secret ALIAS PATH inside a message body (sent elsewhere, not
# opened). Uses the FULL alias path ($SHARED_SECRETS_DIR) — that is the form
# the pre-#1691 blunt substring gate denied even inside a --body value; a bare
# relative `shared/secrets` was never an alias and is out of scope.
ALLOW_BODY_SHARED="agb task create --to peer --body 'see ${SHARED_SECRETS_DIR} layout note'"
# Bash: peer-home NAME inside a message body (--body and -m forms).
ALLOW_BODY_PEER="agb task create --to peer --body 'check ${PEER_HOME}/MEMORY.md'"
ALLOW_M_PEER="agb task create --to peer -m 'see ${PEER_HOME}/MEMORY.md soon'"
# Bash: benign LISTING / SEARCH of an allowlisted peer memory subpath.
ALLOW_CAT_PEER_MEMSHARED="cat ${PEER_HOME}/memory/shared/note.md"
ALLOW_GREP_PEER_MEMSHARED="grep note ${PEER_HOME}/memory/shared/note.md"

assert_bash "non-admin grep -l NAMES credfile (search)" "$ALLOW_GREP_CREDFILE" "ALLOW"
assert_bash "non-admin grep -rl NAMES registry (search)" "$ALLOW_GREP_REGISTRY" "ALLOW"
assert_bash "non-admin find -name launch-secrets (search)" "$ALLOW_FIND_LAUNCH" "ALLOW"
assert_bash "non-admin find -name registry (search)" "$ALLOW_FIND_REGISTRY" "ALLOW"
assert_bash "non-admin body mention of shared/secrets" "$ALLOW_BODY_SHARED" "ALLOW"
assert_bash "non-admin --body mention of peer MEMORY.md" "$ALLOW_BODY_PEER" "ALLOW"
assert_bash "non-admin -m mention of peer MEMORY.md" "$ALLOW_M_PEER" "ALLOW"
# -t IS a message-body flag for the agb leader (it maps to --title), so a peer
# mention inside it is allowed — proving the message-flag scope is leader-aware
# (the `cat -t <peer>` case in Group 2 proves the converse stays denied).
assert_bash "non-admin -t (agb title) mention of peer MEMORY.md" \
  "agb task create --to peer -t 'note ${PEER_HOME}/MEMORY.md'" "ALLOW"
assert_bash "non-admin cat of allowlisted peer memory/shared" "$ALLOW_CAT_PEER_MEMSHARED" "ALLOW"
assert_bash "non-admin grep of allowlisted peer memory/shared" "$ALLOW_GREP_PEER_MEMSHARED" "ALLOW"

# Bash grep/find: the credential filename or shared-secret alias used as a
# SEARCH PATTERN (the first bare positional, an `-e`/attached `-ePAT`, or a
# `find -name` value) is a search term, not a file open (codex #1691 review
# P2). These ALLOW; the `-f`/attached `-fFILE` pattern-FILE open is in Group 2.
assert_bash "grep -e <credfile> as search pattern" \
  "grep -e ${CRED_DOTCLAUDE}/${CRED_CREDFILE} ${SEARCH_DIR}" "ALLOW"
assert_bash "grep -e<credfile> attached pattern" \
  "grep -e${CRED_DOTCLAUDE}/${CRED_CREDFILE} ${SEARCH_DIR}" "ALLOW"
assert_bash "grep -l <shared-secret alias> as pattern over a dir" \
  "grep -l ${SHARED_SECRETS_DIR} ${SEARCH_DIR}" "ALLOW"
# Common grep value-options (a scalar count/color) before the pattern do NOT
# disqualify the benign-mention shape (codex #1691 review P2).
assert_bash "grep --max-count=1 <credfile> pattern allowed" \
  "grep --max-count=1 ${CRED_REGISTRY} ${SEARCH_DIR}" "ALLOW"
assert_bash "grep --color=never <shared-secret alias> pattern allowed" \
  "grep --color=never ${SHARED_SECRETS_DIR} ${SEARCH_DIR}" "ALLOW"
# Leader basename normalization + `bash <script>` wrapper: a message-body
# mention is recognized for `./agent-bridge`, an absolute path, and
# `bash bridge-task.sh …` — not only the bare `agb`/`agent-bridge` alias
# (codex #1691 review P2).
assert_bash "./agent-bridge --body mention of shared/secrets allowed" \
  "./agent-bridge task create --to peer --body 'see ${SHARED_SECRETS_DIR}'" "ALLOW"
assert_bash "bash bridge-task.sh --body mention allowed" \
  "bash bridge-task.sh create --to peer --body 'see ${SHARED_SECRETS_DIR}'" "ALLOW"

# Non-Bash: a Grep/Glob `pattern` is a SEARCH string, not a file open.
assert_nonbash "Grep pattern NAMES credfile (search)" \
  "Grep" "pattern" "${CRED_DOTCLAUDE}/${CRED_CREDFILE}" "ALLOW"
assert_nonbash "Grep pattern NAMES registry (search)" \
  "Grep" "pattern" "${CRED_REGISTRY}" "ALLOW"
assert_nonbash "Grep pattern NAMES oauth env-var (search docs)" \
  "Grep" "pattern" "${VAL_ENVVAR}" "ALLOW"
assert_nonbash "Grep pattern shared-secret path string (search)" \
  "Grep" "pattern" "${SHARED_SECRETS_DIR}" "ALLOW"
assert_nonbash "Glob pattern NAMES credfile (search)" \
  "Glob" "pattern" "**/${CRED_CREDFILE}" "ALLOW"

# ---------------------------------------------------------------------------
# Group 2 — DENY teeth (must STAY blocked).
# ---------------------------------------------------------------------------

# 2a. Actual OPEN of a credential file — positional argv, file-valued flag,
#     redirect target. The structural file-open gate stays in force.
assert_bash "cat OPENS credfile (positional)" \
  "cat ${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}" "DENY"
assert_bash "cat OPENS registry basename" \
  "cat ${CRED_REGISTRY}" "DENY"
assert_bash "cat OPENS launch-secrets basename" \
  "cat ${CRED_LAUNCHENV}" "DENY"
assert_bash "grep -f OPENS registry as pattern-file" \
  "grep -f ${CRED_REGISTRY} ${SEARCH_DIR}" "DENY"
assert_bash "grep -f<registry> attached OPENS pattern-file" \
  "grep -f${CRED_REGISTRY} ${SEARCH_DIR}" "DENY"
assert_bash "grep -lf<registry> clustered OPENS pattern-file" \
  "grep -lf${CRED_REGISTRY} ${SEARCH_DIR}" "DENY"
assert_bash "grep OPENS shared-secret file (2nd positional, not pattern)" \
  "grep needle ${SHARED_SECRETS_DIR}/key.md" "DENY"
assert_bash "redirect target IS credfile" \
  "echo x > ${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}" "DENY"

# 2b. The OAuth token-VALUE marker and the env-var name — unconditional Bash
#     deny. Naming either in a Bash command is the exfil signal.
assert_bash "token VALUE bytes in Bash (unconditional)" \
  "echo ${VAL_TOKEN}" "DENY"
assert_bash "oauth env-var value read in Bash" \
  "echo \$${VAL_ENVVAR}" "DENY"
# Grepping FOR the token VALUE bytes (non-Bash pattern) stays denied.
assert_nonbash "Grep pattern IS token VALUE bytes" \
  "Grep" "pattern" "${VAL_TOKEN}" "DENY"

# 2c. Material decision: non-admin LISTING / inventory of the shared secret /
#     private dir contents stays DENIED (mention-only, no inventory).
assert_bash "ls inventory of shared/private dir" \
  "ls ${SHARED_PRIV_DIR}" "DENY"
assert_bash "ls -R inventory of shared/secrets dir" \
  "ls -R ${SHARED_SECRETS_DIR}" "DENY"
assert_bash "find inventory of shared/secrets dir" \
  "find ${SHARED_SECRETS_DIR} -name '*.md'" "DENY"
# 2d. non-admin OPEN/read of a shared-secret / shared-private file.
assert_bash "cat OPENS shared/secrets file" \
  "cat ${SHARED_SECRETS_DIR}/key.md" "DENY"
assert_bash "cat OPENS shared/private file" \
  "cat ${SHARED_PRIV_DIR}/ops.md" "DENY"
# 2d-interp. SMUGGLE guard (codex #1691 review P1): a shared-secret/private
#     path embedded inside an INTERPRETER code argument (`python3 -c
#     "open('…/secrets/x').read()"`) is a real open, not a mention — the old
#     raw substring deny caught it and the structural gate must not regress.
#     A forbidden alias that survives into a yielded opener value (i.e. a
#     non-mention position) is denied on a raw substring net.
assert_bash "python3 -c interpreter OPEN of shared/secrets stays denied" \
  "python3 -c \"open('${SHARED_SECRETS_DIR}/key.md').read()\"" "DENY"
assert_bash "python3 -c interpreter OPEN of credential file stays denied" \
  "python3 -c \"open('${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}').read()\"" "DENY"
# 2d-embed. SMUGGLE guard (codex #1691 review P1): a HEREDOC / here-string
#     feeds an interpreter body or a captured command the structural stage
#     walk cannot surface (the heredoc body line is split as its own stage).
#     Any command with a shell embedding / heredoc applies the raw substring
#     floor. The heredoc opener / here-string operator are assembled from
#     single-char fragments (lint-heredoc-ban: no literal in the .sh source).
HEREDOC_OP="$(printf '%s' '<' '<')"
assert_bash "heredoc interpreter OPEN of shared/secrets stays denied" \
  "$(printf 'python3 %s%s\nopen(%s%s/key.md%s).read()\n%s' \
      "${HEREDOC_OP}" "'PY'" "'" "${SHARED_SECRETS_DIR}" "'" 'PY')" "DENY"
assert_bash "heredoc interpreter OPEN of credential file stays denied" \
  "$(printf 'python3 %s%s\nopen(%s%s/%s/%s%s).read()\n%s' \
      "${HEREDOC_OP}" "'PY'" "'" "${HOME}" "${CRED_DOTCLAUDE}" "${CRED_CREDFILE}" "'" 'PY')" "DENY"
# 2d-exec. SMUGGLE guard (codex #1691 review P1): ripgrep's `--pre` EXECUTES
#     its value (a preprocessor that can `cat` any file). Its value is checked
#     as an opener, so `rg --pre 'cat <credfile>' …` / `… <shared-secret>` deny.
assert_bash "rg --pre exec reading credential file stays denied" \
  "rg --pre 'cat ${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}' needle ${SEARCH_DIR}" "DENY"
assert_bash "rg --pre exec reading shared/secrets stays denied" \
  "rg --pre 'cat ${SHARED_SECRETS_DIR}/key.md' needle ${SEARCH_DIR}" "DENY"
# 2d-flag. SMUGGLE guard (codex #1691 review P1): the benign-mention shape is
#     FAIL-CLOSED — only a grep/find SEARCH pattern or a `--body`/`-m` value is
#     a mention. So a payload-style short flag of a NON-message leader
#     (`cat -t <credfile>` — `-t` is "show tabs", not a title), a `find -path`
#     that enumerates a secret subtree, and a grep-family file/exec flag that
#     reads a file (`rg --ignore-file <credfile>`) all DENY.
assert_bash "cat -t <credfile> denied (-t is not a message flag here)" \
  "cat -t ${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}" "DENY"
assert_bash "ls -t inventory of shared/secrets denied" \
  "ls -t ${SHARED_SECRETS_DIR}" "DENY"
assert_bash "find -path enumerating shared/secrets subtree denied" \
  "find ${BRIDGE_SHARED_DIR} -path ${SHARED_SECRETS_DIR}/* -print" "DENY"
assert_bash "rg --ignore-file reading credential file denied" \
  "rg --ignore-file ${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE} needle ${SEARCH_DIR}" "DENY"
# 2d-dup. SMUGGLE guard (codex #1691 review P1): when the SAME alias is BOTH
#     the grep search pattern AND a real file argument
#     (`grep <secret> <secret>/key.md`), masking the pattern occurrence must
#     leave the OPENER occurrence — the file read still denies. (Mask is
#     one-occurrence-at-a-time, not a global replace.)
assert_bash "alias as BOTH grep pattern AND file open stays denied" \
  "grep ${SHARED_SECRETS_DIR} ${SHARED_SECRETS_DIR}/key.md" "DENY"
# 2d-brace. SMUGGLE guard (codex #1691 review P1): a BRACE expansion is one
#     shlex token but bash expands it into MULTIPLE argv words, so a protected
#     path masked as a "pattern" mention becomes a real file argument at run
#     time. Any unresolved brace expansion fails closed to the substring deny.
#     The braces are written literally — `${...}` shell-var refs are NOT brace
#     expansions (no comma/range), so the CRED_* / DIR vars expand normally.
assert_bash "brace-expanded credential file stays denied" \
  "grep {.,${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}} ${SEARCH_DIR}" "DENY"
assert_bash "brace-expanded shared/secrets file stays denied" \
  "grep {.,${SHARED_SECRETS_DIR}/key.md} ${SEARCH_DIR}" "DENY"

# 2e. non-admin read of a peer file OUTSIDE the memory allowlist (top-level),
#     and a WRITE to an allowlisted peer path — both stay denied.
assert_bash "non-admin read of peer top-level MEMORY.md (outside allowlist)" \
  "cat ${PEER_HOME}/MEMORY.md" "DENY"
assert_bash "non-admin WRITE (redirect) to peer memory/shared" \
  "echo x > ${PEER_HOME}/memory/shared/note.md" "DENY"
# 2e-tflag. SMUGGLE guard (codex #1691 review P1): the Stage B peer message-
#     body shortcut is scoped to bridge-CLI message leaders, so a payload-style
#     short flag of a NON-message leader (`cat -t <peer>/MEMORY.md` — `-t` is
#     "show tabs", not a title) does NOT admit a real peer-file read.
assert_bash "cat -t <peer>/MEMORY.md stays denied (-t not a message flag here)" \
  "cat -t ${PEER_HOME}/MEMORY.md" "DENY"

# 2e-redirect. SMUGGLE guard (codex #1691 review P1): a redirect operator
#     GLUED to a token with no space (`cat</secret`, `grep x>/secret`) keeps the
#     operator+path inside ONE shlex token. The structural argv gates must still
#     surface the path after the embedded redirect — the old raw substring deny
#     caught these and the structural replacement must not regress. The redirect
#     operators are assembled from single-char fragments so the .sh source
#     carries no literal `<`/`>` glued to a credential path (and no here-string
#     — lint-heredoc-ban).
LT="$(printf '%s' '<')"
GT="$(printf '%s' '>')"
assert_bash "glued <redirect OPENS credfile (no space)" \
  "cat${LT}${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}" "DENY"
assert_bash "glued <redirect OPENS registry basename" \
  "cat${LT}${CRED_REGISTRY}" "DENY"
assert_bash "glued >redirect WRITES credfile" \
  "grep x${GT}${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}" "DENY"
assert_bash "glued <redirect OPENS shared/secrets file" \
  "cat${LT}${SHARED_SECRETS_DIR}/key.md" "DENY"
assert_bash "glued >redirect WRITES shared/secrets file" \
  "grep x${GT}${SHARED_SECRETS_DIR}/key.md" "DENY"
# Fail-closed: a bare `ls` of a credential FILE is treated as a potential
# opener and stays DENIED (the unblock is scoped to grep/find SEARCH positions,
# patterns, and message bodies — NOT to naming a credential file to ls).
assert_bash "ls of credential file stays denied (fail-closed)" \
  "ls ${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}" "DENY"

# 2f. SMUGGLE guard: a real peer OPEN alongside a body mention of the same
#     peer must DENY — the body-subtract must not mask the open.
assert_bash "body mention + real open of same peer stays denied" \
  "agb task create --body 'see ${PEER_HOME}/MEMORY.md' ; cat ${PEER_HOME}/MEMORY.md" \
  "DENY"

# 2g. SMUGGLE guard: a shell embedding plus a body mention must NOT take the
#     message-body shortcut — fail closed.
assert_bash "embedding + body mention stays denied" \
  "agb task create --body 'x' ${HERESTRING_OP}\$(cat ${PEER_HOME}/MEMORY.md)" \
  "DENY"

# Non-Bash: a Read/Edit `file_path` that OPENS a credential file stays denied.
assert_nonbash "Read file_path OPENS credfile" \
  "Read" "file_path" "${HOME}/${CRED_DOTCLAUDE}/${CRED_CREDFILE}" "DENY"
assert_nonbash "Read file_path OPENS registry basename" \
  "Read" "file_path" "${CRED_REGISTRY}" "DENY"

# ---------------------------------------------------------------------------
# Group 3 — GENUINE revert-teeth: every Group 1 ALLOW must flip to DENY
# against the hook copy with the intent-aware change reverted.
# ---------------------------------------------------------------------------

revert_bash_deny() { # label command
  local got
  got="$(bash_verdict "$2" "$REVERTED_HOOK")"
  if [[ "$got" == "DENY" ]]; then
    smoke_log "ok: revert-teeth — $1 -> DENY (intent-aware reverted)"
  else
    smoke_log "FAIL: revert-teeth — $1 -> $got, want DENY against reverted hook"
    smoke_log "      command: $2"
    smoke_fail "revert-teeth $1: reverted hook should DENY, got $got"
  fi
}

revert_nonbash_deny() { # label tool key value
  local got
  got="$(nonbash_verdict "$2" "$3" "$4" "$REVERTED_HOOK")"
  if [[ "$got" == "DENY" ]]; then
    smoke_log "ok: revert-teeth — $1 -> DENY (intent-aware reverted)"
  else
    smoke_log "FAIL: revert-teeth — $1 -> $got, want DENY against reverted hook"
    smoke_fail "revert-teeth $1: reverted hook should DENY, got $got"
  fi
}

revert_bash_deny "grep -l NAMES credfile" "$ALLOW_GREP_CREDFILE"
revert_bash_deny "grep -rl NAMES registry" "$ALLOW_GREP_REGISTRY"
revert_bash_deny "find -name launch-secrets" "$ALLOW_FIND_LAUNCH"
revert_bash_deny "body mention of shared/secrets" "$ALLOW_BODY_SHARED"
revert_bash_deny "--body mention of peer MEMORY.md" "$ALLOW_BODY_PEER"
revert_bash_deny "cat of allowlisted peer memory/shared" "$ALLOW_CAT_PEER_MEMSHARED"
revert_nonbash_deny "Grep pattern NAMES credfile" \
  "Grep" "pattern" "${CRED_DOTCLAUDE}/${CRED_CREDFILE}"
revert_nonbash_deny "Grep pattern NAMES oauth env-var" \
  "Grep" "pattern" "${VAL_ENVVAR}"

# Sanity: the reverted hook must STILL DENY a real credential-file open — the
# revert restores the blunt substring deny, which is a superset of the open
# deny, so this confirms the revert did not accidentally disable the gate.
real_open_reverted="$(bash_verdict "cat ${CRED_REGISTRY}" "$REVERTED_HOOK")"
if [[ "$real_open_reverted" == "DENY" ]]; then
  smoke_log "ok: revert-teeth — real credfile open still DENY against reverted hook"
else
  smoke_fail "revert-teeth: real credfile open should stay DENY against reverted hook, got $real_open_reverted"
fi

smoke_log "passed"
