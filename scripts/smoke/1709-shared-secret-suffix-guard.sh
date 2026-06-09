#!/usr/bin/env bash
# scripts/smoke/1709-shared-secret-suffix-guard.sh — Issue #1709 closure smoke.
#
# Bug (HIGH, confidentiality): hooks/tool-policy.py's Stage-A "shared
# off-limits" gate (`_shared_forbidden_aliases`) and the Stage-B peer-home
# gate (`_peer_alias_list`) were a substring blacklist over a FIXED set of
# prefix spellings (absolute / `~` / `$HOME`). They MISSED the brace form
# `${HOME}`, `$BRIDGE_HOME`, `${BRIDGE_HOME}`, so a non-admin (class=user)
# agent could read a team-shared secret / a peer home by spelling the path
# with a brace / `$BRIDGE_HOME` prefix:
#
#   cat $HOME/.agent-bridge/shared/secrets/token     -> DENY  (correct)
#   cat ${HOME}/.agent-bridge/shared/secrets/token   -> ALLOW *** BYPASS (pre-fix)
#   cat $BRIDGE_HOME/shared/secrets/token            -> ALLOW *** BYPASS (pre-fix)
#   cat ${HOME}/.agent-bridge/agents/<peer>/MEMORY.md-> ALLOW *** BYPASS (pre-fix)
#
# An ANSI-C `$'\x..'`-hex-encoded path also bypassed the substring model.
#
# Fix: a prefix-spelling-agnostic forbidden-SUFFIX matcher
# (`_forbidden_suffix_in_command`) keyed off the SAME SSOTs the alias lists
# use (`_SHARED_FORBIDDEN_PREFIXES` / `other_agent_homes`). Every spelling of
# the secret tree ends in `/shared/secrets`, every peer home ends in
# `/agents/<name>`, so one suffix check catches all prefix spellings; an
# ANSI-C / backslash word is decoded and re-scanned, and a bridge-anchored
# glob / command-sub word fails closed when its literal prefix could select a
# forbidden directory.
#
# This smoke drives the REAL PreToolUse hook (hooks/tool-policy.py) end to
# end (stdin JSON -> permissionDecision) and proves, for class=user:
#
#   DENY (the teeth — every prefix spelling of the forbidden trees):
#     Stage-A shared/secrets + shared/private: absolute, `~`, `$HOME`,
#       `${HOME}`, `$BRIDGE_HOME`, `${BRIDGE_HOME}`, ANSI-C `$'\x..'`.
#     Stage-B peer home agents/<peer>: the same spellings.
#
#   ALLOW (no over-block):
#     own-home read, public shared/wiki read (incl. `${HOME}` spelling),
#     a benign globby repo-style read, a non-forbidden bridge-home read.
#
#   Revert-teeth (GENUINE): a TEMPORARY copy of hooks/tool-policy.py with the
#   #1709 suffix-deny blocks stripped is built; the brace / `$BRIDGE_HOME` /
#   ANSI-C cases are run against it and asserted to FLIP TO ALLOW (the
#   pre-fix bypass), so this smoke cannot pass without the fix in place.
#
# Footgun #11: the JSON stdin payload is built with `printf` (never an
# interpreter here-string / heredoc-stdin) and piped into the hook with
# `< file`, matching scripts/smoke/1692-admin-bash-symmetry.sh.
#
# macOS: pure policy-decision smoke; no sudo / multi-UID needed. Runs under
# /opt/homebrew/bin/bash 5.x and Linux CI bash alike.

set -euo pipefail

SMOKE_NAME="1709-shared-secret-suffix-guard"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

STRIPPED_HOOK=""
cleanup() {
  [[ -n "$STRIPPED_HOOK" && -f "$STRIPPED_HOOK" ]] && rm -f "$STRIPPED_HOOK"
  smoke_cleanup_temp_root
}
trap cleanup EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

smoke_setup_bridge_home "$SMOKE_NAME"

REAL_HOOK="$SMOKE_REPO_ROOT/hooks/tool-policy.py"

# So `~/.agent-bridge/...` and `$HOME/.agent-bridge/...` spellings resolve to
# the fixture bridge home for the few cases that depend on var expansion
# (the suffix scan is text-based and prefix-spelling-agnostic, but the
# bridge-anchor / glob-prefix checks expandvars/expanduser, so HOME must
# point at the parent of the fixture `.agent-bridge`).
export HOME="$BRIDGE_HOME/.."
# Normalize: ensure BRIDGE_HOME ends in `.agent-bridge` so the `/.agent-bridge/`
# anchor token + `$HOME/.agent-bridge/...` spellings line up with the fixture.
# smoke lib pins BRIDGE_HOME=<tmp>/bridge-home; re-point to a `.agent-bridge`
# leaf under the same tmp so every spelling is consistent.
NEW_HOME_PARENT="$SMOKE_TMP_ROOT/home"
mkdir -p "$NEW_HOME_PARENT"
export HOME="$NEW_HOME_PARENT"
export BRIDGE_HOME="$NEW_HOME_PARENT/.agent-bridge"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
mkdir -p "$BRIDGE_LOG_DIR"

# --- Fixtures ---------------------------------------------------------------

USER_AGENT="worker-1709"
USER_HOME="$BRIDGE_AGENT_HOME_ROOT/$USER_AGENT"
mkdir -p "$USER_HOME/memory"
printf -- '- session type: static\n' >"$USER_HOME/SESSION-TYPE.md"
printf -- '# own memory\n' >"$USER_HOME/MEMORY.md"

PEER_AGENT="peer-1709"
PEER_HOME="$BRIDGE_AGENT_HOME_ROOT/$PEER_AGENT"
mkdir -p "$PEER_HOME/memory/projects"
printf -- '- session type: static\n' >"$PEER_HOME/SESSION-TYPE.md"
printf -- '# peer memory\n' >"$PEER_HOME/MEMORY.md"

mkdir -p "$BRIDGE_SHARED_DIR/private" "$BRIDGE_SHARED_DIR/secrets" "$BRIDGE_SHARED_DIR/wiki"
printf -- '# operator secret\n' >"$BRIDGE_SHARED_DIR/secrets/token"
printf -- '# operator private\n' >"$BRIDGE_SHARED_DIR/private/ops.md"
printf -- '# public wiki\n' >"$BRIDGE_SHARED_DIR/wiki/index.md"

# --- Build a suffix-deny-stripped copy of the hook for the revert proof -----
# Remove the two #1709 suffix-deny call-site blocks (Stage-A + Stage-B) so the
# brace / $BRIDGE_HOME / ANSI-C cases revert to the pre-fix ALLOW.
STRIPPED_HOOK="$SMOKE_REPO_ROOT/hooks/.tool-policy-1709-stripped-$$.py"
# file-as-argv (NOT heredoc-stdin) — footgun #11 / lint-heredoc-ban.
"$PYTHON_BIN" "$SCRIPT_DIR/1709-shared-secret-suffix-guard-strip.py" \
  "$REAL_HOOK" "$STRIPPED_HOOK" \
  || smoke_fail "could not build the #1709 suffix-deny-stripped hook copy"
"$PYTHON_BIN" -m py_compile "$STRIPPED_HOOK" \
  || smoke_fail "stripped hook copy did not compile"

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
    '  "tool_use_id": "smoke-1709",' \
    '  "session_id": "smoke-session"' \
    '}' \
    >"$target"
}

# $1 command, $2 hook path. Echoes ALLOW|DENY for class=user.
hook_verdict() {
  local command="$1" hook_path="$2" payload out
  payload="$SMOKE_TMP_ROOT/payload-$RANDOM-$RANDOM.json"
  write_bash_payload "$payload" "$command"
  out="$(BRIDGE_AGENT_ID="$USER_AGENT" BRIDGE_AGENT_CLASS_FOR_HOOK="user" \
    "$PYTHON_BIN" "$hook_path" <"$payload")"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then
    printf 'DENY'
  else
    printf 'ALLOW'
  fi
}

# $1 label, $2 command, $3 want (ALLOW|DENY) against the REAL hook.
assert_verdict() {
  local label="$1" command="$2" want="$3" got
  got="$(hook_verdict "$command" "$REAL_HOOK")"
  if [[ "$got" == "$want" ]]; then
    smoke_log "ok: ${label} -> ${got}"
  else
    smoke_log "FAIL: ${label} -> ${got}, want ${want}"
    smoke_log "      command: ${command}"
    smoke_fail "${label}: expected ${want}, got ${got}"
  fi
}

# $1 label, $2 command — assert the STRIPPED hook flips this to ALLOW (proves
# the deny is genuinely owed to the #1709 blocks, not some unrelated gate).
assert_revert_allow() {
  local label="$1" command="$2" got
  got="$(hook_verdict "$command" "$STRIPPED_HOOK")"
  if [[ "$got" == "ALLOW" ]]; then
    smoke_log "ok: revert-teeth — ${label} -> ALLOW (bypass without fix)"
  else
    smoke_log "FAIL: revert-teeth — ${label} -> ${got}, want ALLOW"
    smoke_log "      command: ${command}"
    smoke_fail "revert-teeth ${label}: expected ALLOW against stripped hook, got ${got}"
  fi
}

echo "[smoke:${SMOKE_NAME}] real PreToolUse hook end-to-end (class=user)"

ABS="$BRIDGE_HOME"

# ---------------------------------------------------------------------------
# Stage-A — shared/secrets + shared/private, every prefix spelling -> DENY.
# ---------------------------------------------------------------------------
assert_verdict "A secrets absolute"      "cat $ABS/shared/secrets/token"                 "DENY"
assert_verdict "A secrets ~"             "cat ~/.agent-bridge/shared/secrets/token"      "DENY"
assert_verdict "A secrets \$HOME"        "cat \$HOME/.agent-bridge/shared/secrets/token" "DENY"
assert_verdict "A secrets \${HOME}"      "cat \${HOME}/.agent-bridge/shared/secrets/token" "DENY"
assert_verdict "A secrets \$BRIDGE_HOME" "cat \$BRIDGE_HOME/shared/secrets/token"        "DENY"
assert_verdict "A secrets \${BRIDGE_HOME}" "cat \${BRIDGE_HOME}/shared/secrets/token"    "DENY"
assert_verdict "A secrets ANSI-C hex"    "cat \$HOME/.agent-bridge/shared/\$'\\x73ecrets'/token" "DENY"
assert_verdict "A private \${HOME}"      "grep x \${HOME}/.agent-bridge/shared/private/ops.md" "DENY"
assert_verdict "A private \$BRIDGE_HOME" "grep x \$BRIDGE_HOME/shared/private/ops.md"    "DENY"
assert_verdict "A private \${BRIDGE_HOME}" "grep x \${BRIDGE_HOME}/shared/private/ops.md" "DENY"

# ---------------------------------------------------------------------------
# Stage-B — peer home agents/<peer>, every prefix spelling -> DENY.
# ---------------------------------------------------------------------------
assert_verdict "B peer absolute"        "cat $ABS/agents/$PEER_AGENT/MEMORY.md"                      "DENY"
assert_verdict "B peer ~"               "cat ~/.agent-bridge/agents/$PEER_AGENT/MEMORY.md"           "DENY"
assert_verdict "B peer \$HOME"          "cat \$HOME/.agent-bridge/agents/$PEER_AGENT/MEMORY.md"      "DENY"
assert_verdict "B peer \${HOME}"        "cat \${HOME}/.agent-bridge/agents/$PEER_AGENT/MEMORY.md"    "DENY"
assert_verdict "B peer \$BRIDGE_HOME"   "cat \$BRIDGE_HOME/agents/$PEER_AGENT/MEMORY.md"             "DENY"
assert_verdict "B peer \${BRIDGE_HOME}" "cat \${BRIDGE_HOME}/agents/$PEER_AGENT/MEMORY.md"           "DENY"

# ---------------------------------------------------------------------------
# r2 (codex #11763 + patch #11764) — statically-resolvable spellings the
# literal substring scan missed: ordinary unquoted backslash (`\X`->`X`, NOT
# hex), redundant separators (`//`,`///`), dot segments (`/./`), and a
# cwd-relative read after a bridge-anchored `cd` (no leading `/`). Both stages.
# ---------------------------------------------------------------------------
assert_verdict "A secrets backslash"     "cat \${HOME}/.agent-bridge/shared/secre\\ts/token"   "DENY"
assert_verdict "A private backslash"     "grep x \${HOME}/.agent-bridge/shared/priv\\ate/ops.md" "DENY"
assert_verdict "A secrets double-slash"  "cat \$BRIDGE_HOME/shared//secrets/token"             "DENY"
assert_verdict "A secrets triple-slash"  "cat \$BRIDGE_HOME/shared///secrets/token"            "DENY"
assert_verdict "A secrets dot-component" "cat \$BRIDGE_HOME/shared/./secrets/token"            "DENY"
assert_verdict "A secrets cd-relative"   "cd \$BRIDGE_HOME && cat shared/secrets/token"        "DENY"
assert_verdict "A secrets subshell-cd"   "(cd \$BRIDGE_HOME; cat shared/secrets/token)"        "DENY"
assert_verdict "A private cd-relative"   "cd \$BRIDGE_HOME && grep x shared/private/ops.md"    "DENY"
assert_verdict "B peer double-slash"     "cat \$BRIDGE_HOME/agents//$PEER_AGENT/MEMORY.md"     "DENY"
assert_verdict "B peer dot-component"    "cat \$BRIDGE_HOME/agents/./$PEER_AGENT/MEMORY.md"    "DENY"
assert_verdict "B peer cd-relative"      "cd \$BRIDGE_HOME && cat agents/$PEER_AGENT/MEMORY.md" "DENY"

# ---------------------------------------------------------------------------
# r3 (codex #11772 + patch #11773) — PATH-RESOLUTION vectors a literal-suffix
# text scan structurally cannot model: `..` parent-traversal past an existing
# public sibling, accumulated cwd depth from `cd` into a SUBDIR, multi-step
# `cd`, and `cd`-subdir + `..`. These all RESOLVE into the forbidden tree and
# must DENY (both stages). Modeled by folding `cd` targets into an effective
# cwd + `os.path.normpath`-resolving each read word, not by spelling-matching.
# ---------------------------------------------------------------------------
assert_verdict "A secrets .. via sibling" "cat \$BRIDGE_HOME/shared/wiki/../secrets/token"     "DENY"
assert_verdict "A secrets cd-subdir"      "cd \$BRIDGE_HOME/shared && cat secrets/token"       "DENY"
assert_verdict "A secrets cd-subdir + .." "cd \$BRIDGE_HOME/shared/wiki && cat ../secrets/token" "DENY"
assert_verdict "A secrets cd-rel + .."    "cd \$BRIDGE_HOME && cat shared/wiki/../secrets/token" "DENY"
assert_verdict "A secrets multi-cd"       "cd \$BRIDGE_HOME; cd shared; cat secrets/token"     "DENY"
assert_verdict "A private cd-subdir"      "cd \$BRIDGE_HOME/shared && grep x private/ops.md"   "DENY"
assert_verdict "B peer .. via peer"       "cat \$BRIDGE_HOME/agents/$PEER_AGENT/../$PEER_AGENT/MEMORY.md" "DENY"
assert_verdict "B peer cd-subdir"         "cd \$BRIDGE_HOME/agents && cat $PEER_AGENT/MEMORY.md" "DENY"
assert_verdict "B peer multi-cd"          "cd \$BRIDGE_HOME; cd agents; cat $PEER_AGENT/MEMORY.md" "DENY"

# r4 (codex #11779 + patch #11780) — two bounded word-expansion steps bash
# applies BEFORE the path exists, which the resolver must source from bash's
# real splitting: (Q) quote removal (`sec'rets'`, `"$BH/..."`, `shared'/'secrets`)
# and (cd-form) the wider `cd` invocations (`cd --`/`-P`/`-L`, `builtin cd`,
# `command cd`, `\cd`). The read words + cd targets are now tokenized via
# shlex.split(posix), so all of these RESOLVE into the forbidden tree -> DENY.
assert_verdict "Q secrets quote-concat"   "cat \$BRIDGE_HOME/shared/sec'rets'/token"       "DENY"
assert_verdict "Q secrets empty-concat"   "cat \$BRIDGE_HOME/shared/secrets''/token"       "DENY"
assert_verdict "Q secrets quoted-slash"   "cat \$BRIDGE_HOME/shared'/'secrets/token"       "DENY"
assert_verdict "Q secrets whole-dquote"   "cat \"\$BRIDGE_HOME/shared/secrets/token\""     "DENY"
assert_verdict "Q secrets quoted-prefix"  "cat \"\$BRIDGE_HOME\"/shared/secrets/token"     "DENY"
assert_verdict "Q peer quote-concat"      "cat \$BRIDGE_HOME/agents/$PEER_AGENT''/MEMORY.md" "DENY"
assert_verdict "cd -- subdir"             "cd -- \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "cd -P subdir"             "cd -P \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "cd -L subdir"             "cd -L \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "builtin cd subdir"        "builtin cd \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "command cd subdir"        "command cd \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "backslash cd subdir"      "\\cd \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "B peer cd -- subdir"      "cd -- \$BRIDGE_HOME/agents && cat $PEER_AGENT/MEMORY.md" "DENY"

# r5 (codex #11787 + patch #11788) — the last two structural axes: wrapper
# builtins with their own option grammar (command -p/-- cd, builtin -- cd, time
# cd) and POSITIONAL cwd (a read while cwd is inside the tree, then a trailing
# `cd`/`popd` back OUT, must still DENY — the read is judged at its position).
assert_verdict "command -p cd"            "command -p cd \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "command -- cd"            "command -- cd \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "builtin -- cd"            "builtin -- cd \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "time cd"                  "time cd \$BRIDGE_HOME/shared && cat secrets/token"       "DENY"
assert_verdict "positional cd-out &&"     "cd \$BRIDGE_HOME/shared && cat secrets/token && cd /tmp" "DENY"
assert_verdict "positional cd-out ;"      "cd \$BRIDGE_HOME/shared; cat secrets/token; cd /tmp"     "DENY"
assert_verdict "positional pushd-popd"    "pushd \$BRIDGE_HOME/shared >/dev/null; cat secrets/token; popd" "DENY"
assert_verdict "positional cd .."         "cd \$BRIDGE_HOME/shared; cat secrets/token; cd .."       "DENY"
assert_verdict "B peer positional cd-out" "cd \$BRIDGE_HOME/agents; cat $PEER_AGENT/MEMORY.md; cd /tmp" "DENY"

# r6 (codex #11794 + patch #11795) — control-flow SCOPE: a subshell whose cd
# bash discards at \`)\`, a pushd/popd dirstack, or \`cd -\` can restore a cwd a
# prior cd put inside the tree; the read at that position must still DENY. The
# scope-ambiguous fail-close re-checks each relative read against every prior cwd.
assert_verdict "subshell discards cd"     "cd \$BRIDGE_HOME/shared; (cd /tmp); cat secrets/token"   "DENY"
assert_verdict "subshell discards cd &&"  "cd \$BRIDGE_HOME/shared && (cd /tmp) && cat secrets/token" "DENY"
assert_verdict "pushd-pushd-popd restore" "pushd \$BRIDGE_HOME/shared; pushd /tmp; popd; cat secrets/token" "DENY"
assert_verdict "empty-stack popd no-op"   "cd \$BRIDGE_HOME/shared; popd; cat secrets/token"        "DENY"
assert_verdict "cd - restores prev"       "cd \$BRIDGE_HOME; cd shared; cd - >/dev/null; cat shared/secrets/token" "DENY"
assert_verdict "B peer subshell discard"  "cd \$BRIDGE_HOME/agents; (cd /tmp); cat $PEER_AGENT/MEMORY.md" "DENY"

# r7 (codex #11799) — `&&`/`||` CONDITIONAL execution: bash skips a `cd` gated on
# a prior command's exit, so a conditional `cd out` does NOT un-anchor a prior
# bridge cwd (a conditional `cd` no longer advances the modeled cwd).
assert_verdict "|| skipped cd-out"        "cd \$BRIDGE_HOME/shared; true || cd /tmp; cat secrets/token" "DENY"
assert_verdict "&& skipped cd-out"        "cd \$BRIDGE_HOME/shared; false && cd /tmp; cat secrets/token" "DENY"
assert_verdict "&&-chain skipped cd-out"  "cd \$BRIDGE_HOME/shared && true || cd /tmp; cat secrets/token" "DENY"
assert_verdict "B peer || skipped cd-out" "cd \$BRIDGE_HOME/agents; true || cd /tmp; cat $PEER_AGENT/MEMORY.md" "DENY"

# r7 (patch #11800) — `cd` hidden behind a brace-group / compound-keyword whose
# body runs in the CURRENT shell (so the cd persists); the reserved-word strip
# locates it. \`echo cd …\` (a regular command arg) is NOT stripped.
assert_verdict "brace group cd"           "{ cd \$BRIDGE_HOME/shared; }; cat secrets/token"        "DENY"
assert_verdict "brace whole-body"         "{ cd \$BRIDGE_HOME/shared; cat secrets/token; }"        "DENY"
assert_verdict "if-then cd"               "if cd \$BRIDGE_HOME/shared; then cat secrets/token; fi" "DENY"
assert_verdict "for-do cd"                "for i in 1; do cd \$BRIDGE_HOME/shared; cat secrets/token; done" "DENY"
assert_verdict "fn-body cd"               "f(){ cd \$BRIDGE_HOME/agents; }; f; cat $PEER_AGENT/MEMORY.md" "DENY"

# r8 (codex #11805 + patch #11806) — `&&`/`||` conditional cd that EXECUTES: the
# guard (true/:/false) deterministically runs the cd into the bridge, so the
# read IS anchored. Modeled by literal-truth (provably-executed → advance) +
# union (ambiguous condition → record target + scope-ambiguous check).
assert_verdict "true && cd-in"            "true && cd \$BRIDGE_HOME/shared; cat secrets/token"     "DENY"
assert_verdict ": && cd-in"               ": && cd \$BRIDGE_HOME/shared; cat secrets/token"        "DENY"
assert_verdict "false || cd-in"           "false || cd \$BRIDGE_HOME/shared; cat secrets/token"    "DENY"
assert_verdict "true && cd && read"       "true && cd \$BRIDGE_HOME/shared && cat secrets/token"   "DENY"
assert_verdict "cmd && cd-in union"       "grep x f && cd \$BRIDGE_HOME/shared; cat secrets/token" "DENY"
assert_verdict "cd/tmp && cd-in chain"    "cd /tmp && cd \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "B peer true && cd-in"     "true && cd \$BRIDGE_HOME/agents; cat $PEER_AGENT/MEMORY.md" "DENY"

# r9 (patch #11806) — `&&`/`||` CHAIN short-circuit precedence: a cd's execution
# depends on the running boolean of the WHOLE chain, not the immediate
# predecessor. `false && true || cd …` runs the cd (false&&true short-circuits
# to false → || runs). A chain that genuinely skips the cd stays ALLOW.
assert_verdict "false&&true||cd-in"       "false && true || cd \$BRIDGE_HOME/shared; cat secrets/token" "DENY"
assert_verdict "true||false&&cd-in"       "true || false && cd \$BRIDGE_HOME/shared; cat secrets/token" "DENY"
assert_verdict ":||false&&cd-in"          ": || false && cd \$BRIDGE_HOME/shared; cat secrets/token"    "DENY"
assert_verdict "chain && read"            "false && true || cd \$BRIDGE_HOME/shared && cat secrets/token" "DENY"
assert_verdict "B peer chain cd-in"       "true || false && cd \$BRIDGE_HOME/agents; cat $PEER_AGENT/MEMORY.md" "DENY"
assert_verdict "chain skips cd (&&-false)" "true && false && cd \$BRIDGE_HOME/shared; cat secrets/token" "ALLOW"
assert_verdict "chain skips cd (||-true)"  "false || true || cd \$BRIDGE_HOME/shared; cat secrets/token" "ALLOW"
# r10 (codex #11815) — an EXECUTED `cd` is likely-success: in an all-`&&` chain a
# read only runs if every preceding cd succeeded, so its cwd is the LAST cd
# target. `cd-in && cd-out && read` ends in the cd-OUT cwd → ALLOW (teeth below
# in the no-over-block block). But a cd-IN with NO cd-out, or a cd-out that is
# itself skipped, stays in the bridge → DENY. And a cd may FAIL, so
# `cd <missing> || cd <bridge>` keeps the bridge branch live → DENY.
assert_verdict "cd-in && read (no out)"    "cd \$BRIDGE_HOME/shared && cat secrets/token"               "DENY"
assert_verdict "cd-in && skipped cd-out"   "cd \$BRIDGE_HOME/shared && false && cd /tmp; cat secrets/token" "DENY"
assert_verdict "cd-miss || cd-bridge"      "cd /nonexistent || cd \$BRIDGE_HOME/shared; cat secrets/token" "DENY"
assert_verdict "B peer cd-in && read"      "cd \$BRIDGE_HOME/agents && cat $PEER_AGENT/MEMORY.md"       "DENY"
# r11 (codex #11822 + patch #11823) — an executed cd-OUT can FAIL, leaving bash
# in the prior (bridge) cwd; a subsequent NON-`&&`-gated read (after `;`/`&`/
# newline, or a `||` failure side) runs there → LEAK. The fix keeps the prior
# bridge cwd live (fail-branch re-check, gated off for `&&`-gated reads). The
# unavoidable, sound-direction price: `cd-into-bridge; …; cd-OUT; <forbidden
# relative tail>` is DENY even though the cd-out usually succeeds — a static
# model can't know the cd outcome, and a containment gate must not under-block.
assert_verdict "cd-in && cd-nx; read"      "cd \$BRIDGE_HOME/shared && cd /nonexistent; cat secrets/token" "DENY"
assert_verdict "cd-in; cd-nx; read"        "cd \$BRIDGE_HOME/shared; cd /nonexistent; cat secrets/token"   "DENY"
assert_verdict "cd-in && cd-nx && cd-nx2"  "cd \$BRIDGE_HOME/shared && cd /nonexistent && cd /nx2; cat secrets/token" "DENY"
assert_verdict "B peer cd-in && cd-nx"     "cd \$BRIDGE_HOME/agents && cd /nonexistent; cat $PEER_AGENT/MEMORY.md" "DENY"
assert_verdict "cd-in && cd-nx || true"    "cd \$BRIDGE_HOME/shared && cd /nonexistent || true; cat secrets/token" "DENY"
assert_verdict "cd-in && cd-nx || read"    "cd \$BRIDGE_HOME/shared && cd /nonexistent || cat secrets/token" "DENY"
assert_verdict "cd-in; true && cd-out; rd" "cd \$BRIDGE_HOME/shared; true && cd /tmp; cat secrets/data.txt" "DENY"
# r12 Part A (patch #11823) — a fail-branch cwd is STICKY across a hard break: a
# read gated only on a literal-true in a NEW chain after the failed cd still runs
# in the bridge fail-branch → DENY (the r11 `gated` skip was chain-local only).
assert_verdict "cd-fail; true && cat"      "cd \$BRIDGE_HOME/shared && cd /nx; true && cat secrets/token" "DENY"
assert_verdict "cd-fail; : && cat"         "cd \$BRIDGE_HOME/shared && cd /nx; : && cat secrets/token"    "DENY"
assert_verdict "cd-fail; true&&true&&cat"  "cd \$BRIDGE_HOME/shared && cd /nx; true && true && cat secrets/token" "DENY"
assert_verdict "B peer cd-fail; true&&cat" "cd \$BRIDGE_HOME/agents && cd /nx; true && cat $PEER_AGENT/MEMORY.md" "DENY"
# r12 Part B (codex #11827) — obfuscated RELATIVE read under a bridge cwd: ANSI-C
# $'…' (shlex would mangle to \$secrets and hide it), hex/octal/unicode escapes,
# globs (cwd-relative, no raw bridge anchor), backslash re-spell, quote-split —
# all resolve into the protected tree at runtime → fail closed.
assert_verdict "ansic relative read"       "cd \$BRIDGE_HOME/shared && cat \$'secrets'/token"   "DENY"
assert_verdict "ansic hex relative"        "cd \$BRIDGE_HOME/shared && cat \$'\\x73ecrets'/token" "DENY"
assert_verdict "ansic octal relative"      "cd \$BRIDGE_HOME/shared && cat \$'\\163ecrets'/token" "DENY"
assert_verdict "glob mid relative"         "cd \$BRIDGE_HOME/shared && cat sec*ets/token"        "DENY"
assert_verdict "glob descend relative"     "cd \$BRIDGE_HOME/shared && cat */token"              "DENY"
assert_verdict "glob bracket relative"     "cd \$BRIDGE_HOME/shared && cat sec[r]ets/token"      "DENY"
assert_verdict "backslash respell rel"     "cd \$BRIDGE_HOME/shared && cat sec\\rets/token"      "DENY"
assert_verdict "quote-split relative"      "cd \$BRIDGE_HOME/shared && cat sec''rets/token"      "DENY"
assert_verdict "B peer ansic relative"     "cd \$BRIDGE_HOME/agents && cat \$'$PEER_AGENT'/MEMORY.md" "DENY"
assert_verdict "obf under cd-fail sticky"  "cd \$BRIDGE_HOME/shared && cd /nx; cat sec*ets/token" "DENY"
assert_verdict "ansic in abs bridge path"  "cat \$BRIDGE_HOME/shared/\$'secrets'/token"          "DENY"
# r13 (codex #11837) — an EQUAL-depth glob that selects the protected dir ITSELF
# enumerates it via ls/find/grep -r (the guard is command-agnostic, so `cat *`
# denies too). The fnmatch is precise: a glob that does NOT match the forbidden
# dir name (e.g. `*.md`) stays ALLOW.
assert_verdict "ls glob enum dir"          "cd \$BRIDGE_HOME/shared && ls sec*ets"               "DENY"
assert_verdict "ls star enum dirs"         "cd \$BRIDGE_HOME/shared && ls *"                     "DENY"
assert_verdict "find glob enum dir"        "cd \$BRIDGE_HOME/shared && find sec*ets -maxdepth 1 -type f -print" "DENY"
assert_verdict "cat star selects secret"   "cd \$BRIDGE_HOME/shared && cat *"                    "DENY"
assert_verdict "B peer ls glob enum"       "cd \$BRIDGE_HOME/agents && ls $PEER_AGENT*"          "DENY"
# r14 Part A (patch #11838) — a `!`-negated cd-OUT continues the `&&` chain EXACTLY
# when the cd FAILS (bash stays in the bridge), so the `&&`-gated read runs in the
# fail-branch. Odd `!` de-gates → prior cwd re-checked → DENY; even `!` is sound.
assert_verdict "!-neg cd-out && read"      "cd \$BRIDGE_HOME/shared && ! cd /nx && cat secrets/token" "DENY"
assert_verdict "!-neg builtin cd"          "cd \$BRIDGE_HOME/shared && ! builtin cd /nx && cat secrets/token" "DENY"
assert_verdict "!-neg cd && true && read"  "cd \$BRIDGE_HOME/shared && ! cd /nx && true && cat secrets/token" "DENY"
# r14 Part B (codex #11840) — bash BRACE expansion `{a,b}` is statically finite,
# so a forbidden member is enumerated before argv. Each member is expanded and
# resolved; a `${var}` parameter expansion and a comma-less `{foo}` are NOT braces.
assert_verdict "brace abs both members"    "cat \$BRIDGE_HOME/shared/{secrets,wiki}/token"       "DENY"
assert_verdict "brace abs ls enum"         "ls \$BRIDGE_HOME/shared/{secrets,wiki}"              "DENY"
assert_verdict "brace rel cat"             "cd \$BRIDGE_HOME/shared && cat {secrets,wiki}/token" "DENY"
assert_verdict "brace partial member"      "cd \$BRIDGE_HOME/shared && cat sec{r,}ets/token"     "DENY"
assert_verdict "B peer brace enum"         "cd \$BRIDGE_HOME/agents && ls {$PEER_AGENT,worker-1709}" "DENY"
# r15 Part 1 (codex #11845 + patch #11846) — a brace whose expansion overflows the
# cap cannot be fully inspected, so a forbidden member could lie past it. A
# bridge-RELEVANT truncation (segment bridge-anchored, or cwd inside the bridge
# home) fails closed; a forbidden member after a literal benign run is denied.
assert_verdict "brace trunc bridge-cwd"    "cd \$BRIDGE_HOME/shared && cat {0..2000}/token"      "DENY"
assert_verdict "brace trunc secret-past-cap" "cd \$BRIDGE_HOME/shared && cat {$(seq -s, 0 1099),secrets}/token" "DENY"
assert_verdict "brace trunc abs anchored"  "cat \$BRIDGE_HOME/shared/{0..2000}/token"            "DENY"

# ---------------------------------------------------------------------------
# No over-block — legit class=user reads stay ALLOW.
# ---------------------------------------------------------------------------
assert_verdict "own home read"          "cat $ABS/agents/$USER_AGENT/MEMORY.md"          "ALLOW"
assert_verdict "own home \${HOME}"      "cat \${HOME}/.agent-bridge/agents/$USER_AGENT/MEMORY.md" "ALLOW"
assert_verdict "public wiki \${HOME}"   "cat \${HOME}/.agent-bridge/shared/wiki/index.md" "ALLOW"
assert_verdict "repo-style glob"        "cat ./agents/*.md"                              "ALLOW"
assert_verdict "non-forbidden bridge read" "cat \${HOME}/.agent-bridge/state/x.md"       "ALLOW"
assert_verdict "cd-relative public wiki" "cd \$BRIDGE_HOME && cat shared/wiki/index.md"   "ALLOW"
# positional: a relative read AFTER a cd OUT of the bridge is not anchored -> ALLOW.
assert_verdict "read after cd-out"       "cd /tmp && cat secrets/token"                   "ALLOW"
# r6 no-over-block: `command -v/-V cd` is DESCRIBE/query (no cwd change); a
# subshell read of a PUBLIC tail stays ALLOW.
assert_verdict "command -v query"        "command -v cd \$BRIDGE_HOME/shared && cat secrets/token" "ALLOW"
# r7 no-over-block: a CONDITIONAL `cd in` bash skips never enters the bridge; a
# conditional `cd out` that executes genuinely leaves it — neither is anchored.
assert_verdict "&& skipped cd-in"        "false && cd \$BRIDGE_HOME/shared; cat secrets/token" "ALLOW"
assert_verdict "|| skipped cd-in"        "true || cd \$BRIDGE_HOME/shared; cat secrets/token"  "ALLOW"
assert_verdict "&& cd-out executes"      "true && cd /tmp; cat secrets/token"                  "ALLOW"
assert_verdict "command -V query"        "command -V cd \$BRIDGE_HOME/shared && cat secrets/token" "ALLOW"
assert_verdict "subshell read wiki"      "(cd \$BRIDGE_HOME && cat shared/wiki/page.md)"  "ALLOW"
assert_verdict "subshell-then-rel wiki"  "cd \$BRIDGE_HOME/shared; (cd /tmp); cat wiki/index.md" "ALLOW"
assert_verdict "cd-in then wiki then out" "cd \$BRIDGE_HOME/shared && cat wiki/index.md && cd /tmp" "ALLOW"
# r10 (codex #11815) — EXECUTED cd-OUT chain: the read runs only if every
# preceding `&&` cd succeeded, so the cwd is the last (out-of-bridge) cd target.
assert_verdict "cd-in && cd-out && read"   "cd \$BRIDGE_HOME/shared && cd /tmp && cat secrets/token"              "ALLOW"
assert_verdict "cd-in && true && cd-out"   "cd \$BRIDGE_HOME/shared && true && cd /tmp && cat secrets/token"      "ALLOW"
assert_verdict "cd-in && cd-out2 && read"  "cd \$BRIDGE_HOME/shared && cd /tmp && cd /var && cat secrets/token"   "ALLOW"
assert_verdict "B peer cd-in && cd-out"    "cd \$BRIDGE_HOME/agents && cd /tmp && cat $PEER_AGENT/MEMORY.md"      "ALLOW"
# r12 no-over-block (codex #11827 / patch #11823) — obfuscation is collateral-safe
# OFF a bridge cwd, `cat *` only lists the parent (not the secret leaf), a public
# tail glob is fine, and a gated cd-OUT obf read runs in the out-of-bridge cwd.
assert_verdict "ansic read no cd"          "cat \$'secrets'/token"                              "ALLOW"
assert_verdict "glob read no cd"           "cat sec*ets/token"                                  "ALLOW"
assert_verdict "ansic read cd /tmp"        "cd /tmp && cat \$'secrets'/token"                   "ALLOW"
assert_verdict "glob read cd /tmp"         "cd /tmp && cat sec*ets/token"                       "ALLOW"
assert_verdict "public wiki glob"          "cd \$BRIDGE_HOME/shared && cat wiki/*.md"           "ALLOW"
assert_verdict "ext-only glob no match"    "cd \$BRIDGE_HOME/shared && cat *.md"                "ALLOW"
assert_verdict "gated cd-out glob read"    "cd \$BRIDGE_HOME/shared && cd /tmp && cat sec*ets/token" "ALLOW"
assert_verdict "gated cd-out ansic read"   "cd \$BRIDGE_HOME/shared && cd /tmp && cat \$'secrets'/token" "ALLOW"
# r14 no-over-block: even `!!` cd-out (cd-success semantics) ALLOW; brace with only
# public members / off a bridge cwd / comma-less / `${var}` ALLOW.
assert_verdict "double-neg cd-out read"    "cd \$BRIDGE_HOME/shared && ! ! cd /tmp && cat secrets/token" "ALLOW"
assert_verdict "brace public members"      "cd \$BRIDGE_HOME/shared && cat {wiki,docs}/index.md" "ALLOW"
assert_verdict "brace comma-less literal"  "cd \$BRIDGE_HOME/shared && cat {wiki}/index.md"      "ALLOW"
assert_verdict "brace off bridge cwd"      "cd /tmp && cat {secrets,wiki}/token"                 "ALLOW"
assert_verdict "brace gated cd-out"        "cd \$BRIDGE_HOME/shared && cd /tmp && cat {secrets,wiki}/token" "ALLOW"
# r15 Part 2 (codex #11845) — bash does NOT brace-expand QUOTED/ESCAPED braces, so
# they are literal paths (nonexistent) → ALLOW; and an off-bridge / no-cd brace
# truncation is not bridge-relevant → ALLOW.
assert_verdict "squote brace literal"      "cd \$BRIDGE_HOME/shared && cat 'sec{r,}ets/token'"   "ALLOW"
assert_verdict "dquote brace literal"      "cd \$BRIDGE_HOME/shared && cat \"sec{r,}ets/token\"" "ALLOW"
assert_verdict "escaped brace literal"     "cd \$BRIDGE_HOME/shared && cat sec\\{r,\\}ets/token" "ALLOW"
assert_verdict "squote whole bridge path"  "cat '\$BRIDGE_HOME/shared/{secrets,wiki}/token'"     "ALLOW"
assert_verdict "brace trunc off-bridge"    "cd /tmp && cat {0..2000}/token"                      "ALLOW"
assert_verdict "brace trunc no-cd echo"    "echo {0..2000}"                                      "ALLOW"
# r3 no-over-block — the resolution model must NOT collateral-block these:
#   a RELATIVE forbidden-tail read with NO `cd` (relative to the agent's own
#   cwd, which the hook can't see → unanchorable, not bridge), and a `..` that
#   escapes back OUT of the forbidden tree (resolves to a public sibling).
assert_verdict "rel forbidden-tail no cd" "cat shared/secrets/token"                      "ALLOW"
assert_verdict "rel peer-tail no cd"      "cat agents/$PEER_AGENT/MEMORY.md"              "ALLOW"
assert_verdict "escape out via .."        "cat \$BRIDGE_HOME/shared/secrets/../wiki/index.md" "ALLOW"
assert_verdict "own-workdir relative"     "cat notes/todo.md"                             "ALLOW"

# ---------------------------------------------------------------------------
# Revert-teeth — the brace / $BRIDGE_HOME / ANSI-C cases FLIP TO ALLOW when
# the #1709 suffix-deny blocks are stripped (proves the fix is load-bearing).
# ---------------------------------------------------------------------------
assert_revert_allow "A secrets \${HOME}"       "cat \${HOME}/.agent-bridge/shared/secrets/token"
assert_revert_allow "A secrets \$BRIDGE_HOME"  "cat \$BRIDGE_HOME/shared/secrets/token"
assert_revert_allow "A secrets ANSI-C hex"     "cat \$HOME/.agent-bridge/shared/\$'\\x73ecrets'/token"
assert_revert_allow "B peer \${HOME}"          "cat \${HOME}/.agent-bridge/agents/$PEER_AGENT/MEMORY.md"
assert_revert_allow "B peer \$BRIDGE_HOME"     "cat \$BRIDGE_HOME/agents/$PEER_AGENT/MEMORY.md"
# r3 path-resolution vectors flip to ALLOW without the suffix-deny blocks too.
assert_revert_allow "A secrets .. via sibling" "cat \$BRIDGE_HOME/shared/wiki/../secrets/token"
assert_revert_allow "A secrets cd-subdir"      "cd \$BRIDGE_HOME/shared && cat secrets/token"

smoke_log "passed"
