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
"$PYTHON_BIN" - "$REAL_HOOK" "$STRIPPED_HOOK" <<'PY'
import re
import sys

real, out = sys.argv[1], sys.argv[2]
src = open(real, encoding="utf-8").read()

# Stage-A: drop the `shared_suffix_hit` deny block.
a_start = src.find(
    "    # Issue #1709 — prefix-spelling-agnostic Stage-A suffix deny."
)
a_end = src.find(
    "    # Issue #1692 — admin read-intent carve-out for the Bash PEER-HOME",
    a_start if a_start != -1 else 0,
)
if a_start == -1 or a_end == -1 or a_end < a_start:
    sys.stderr.write("could not locate #1709 Stage-A suffix-deny block\n")
    sys.exit(3)
src = src[:a_start] + src[a_end:]

# Stage-B: drop the `peer_suffix_hit` block (between matched_alias assignment
# and the `if matched_alias is None: return None`).
b_start = src.find(
    "    # Issue #1709 — prefix-spelling-agnostic Stage-B peer-home matcher."
)
b_end = src.find("    if matched_alias is None:\n        return None", b_start if b_start != -1 else 0)
if b_start == -1 or b_end == -1 or b_end < b_start:
    sys.stderr.write("could not locate #1709 Stage-B peer-home block\n")
    sys.exit(4)
src = src[:b_start] + src[b_end:]

if "_forbidden_suffix_in_command(\n            text, _peer_forbidden_suffixes" in src \
        or "shared_suffix_hit = _forbidden_suffix_in_command" in src:
    sys.stderr.write("a #1709 suffix-deny call site survived the strip\n")
    sys.exit(5)
open(out, "w", encoding="utf-8").write(src)
PY
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

# ---------------------------------------------------------------------------
# No over-block — legit class=user reads stay ALLOW.
# ---------------------------------------------------------------------------
assert_verdict "own home read"          "cat $ABS/agents/$USER_AGENT/MEMORY.md"          "ALLOW"
assert_verdict "own home \${HOME}"      "cat \${HOME}/.agent-bridge/agents/$USER_AGENT/MEMORY.md" "ALLOW"
assert_verdict "public wiki \${HOME}"   "cat \${HOME}/.agent-bridge/shared/wiki/index.md" "ALLOW"
assert_verdict "repo-style glob"        "cat ./agents/*.md"                              "ALLOW"
assert_verdict "non-forbidden bridge read" "cat \${HOME}/.agent-bridge/state/x.md"       "ALLOW"
assert_verdict "cd-relative public wiki" "cd \$BRIDGE_HOME && cat shared/wiki/index.md"   "ALLOW"
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
